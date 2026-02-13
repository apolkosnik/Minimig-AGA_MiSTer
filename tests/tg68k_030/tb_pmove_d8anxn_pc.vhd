-- tb_pmove_d8anxn_pc.vhd
-- Test PC increment for PMOVE (d8,An,Xn),TC and PMOVE TC,(d8,An,Xn) instructions
-- Both should be 6-byte instructions: opcode(2) + PMOVE extension(2) + brief extension(2)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity tb_pmove_d8anxn_pc is
end tb_pmove_d8anxn_pc;

architecture behavioral of tb_pmove_d8anxn_pc is
  -- Helper function to convert std_logic_vector to hex string
  function slv_to_hex(v : std_logic_vector) return string is
    constant hex_chars : string := "0123456789ABCDEF";
    variable result : string(1 to v'length/4);
    variable nibble : integer;
  begin
    for i in 0 to v'length/4-1 loop
      nibble := to_integer(unsigned(v(v'length-1-i*4 downto v'length-4-i*4)));
      result(i+1) := hex_chars(nibble+1);
    end loop;
    return result;
  end function;

  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal clkena_in : std_logic := '0';
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal CPU : std_logic_vector(1 downto 0) := "11";  -- 68030

  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS, nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal FC : std_logic_vector(2 downto 0);
  signal longword : std_logic;

  signal pmmu_reg_we : std_logic;
  signal pmmu_reg_re : std_logic;
  signal pmmu_reg_sel : std_logic_vector(4 downto 0);
  signal debug_setopcode : std_logic;

  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

  constant CLK_PERIOD : time := 20 ns;
  signal cycle : integer := 0;

  type bus_state_type is (BUS_IDLE, BUS_WAIT1, BUS_ACK, BUS_LONG_WAIT1, BUS_LONG_ACK);
  signal bus_fsm : bus_state_type := BUS_IDLE;

  -- Memory layout:
  -- $0000-$00FF: Reset vectors and code
  -- $1000+: Stack
  -- $3000+: Data area for PMOVE source/dest
  --
  -- Test sequence:
  -- $40: LEA $3000,A0     (6 bytes: 41F9 0000 3000) - base address
  -- $46: MOVEQ #4,D0      (2 bytes: 7004) - index value
  -- $48: PMOVE (4,A0,D0.W),TC  (6 bytes: F030 4000 0004) - memory to TC
  --      EA = A0 + D0.W + 4 = $3000 + 4 + 4 = $3008
  -- $4E: NOP              (should be at $48+6=$4E)
  -- $50: PMOVE TC,(4,A0,D0.W)  (6 bytes: F030 4200 0004) - TC to memory
  -- $56: NOP              (should be at $50+6=$56)

  type rom_type is array (0 to 127) of std_logic_vector(15 downto 0);
  signal rom : rom_type := (
    -- Reset vectors at $0
    0 => x"0000", 1 => x"1000",  -- SSP = $00001000
    2 => x"0000", 3 => x"0040",  -- PC = $00000040

    -- $40: LEA $3000.L,A0  (41F9 0000 3000)
    32 => x"41F9", 33 => x"0000", 34 => x"3000",

    -- $46: MOVEQ #4,D0  (7004)
    35 => x"7004",

    -- $48: PMOVE (4,A0,D0.W),TC  (F030 4000 0004)
    -- F030 = 1111 0000 0011 0000 = F-line, EA mode 110 (d8,An,Xn), reg A0
    -- 4000 = TC register, direction=0 (write TO MMU)
    -- 0004 = brief extension: D0.W with displacement 4
    --        bits 15: D/A=0 (D0), bits 14-12: reg=000, bit 11: W/L=0 (word)
    --        bits 10-8: scale=000 (x1), bits 7-0: disp=04
    36 => x"F030", 37 => x"4000", 38 => x"0004",

    -- $4E: NOP (expected next PC after 6-byte PMOVE)
    39 => x"4E71",

    -- $50: PMOVE TC,(4,A0,D0.W)  (F030 4200 0004)
    -- 4200 = TC register, direction=1 (read FROM MMU to memory)
    40 => x"F030", 41 => x"4200", 42 => x"0004",

    -- $56: NOP (expected next PC after 6-byte PMOVE)
    43 => x"4E71",

    -- $58: NOP (continue)
    44 => x"4E71",

    others => x"4E71"
  );

  type ram_type is array (0 to 255) of std_logic_vector(15 downto 0);
  signal stack_ram : ram_type := (others => x"0000");

  -- Data at $3000+ (for PMOVE source/dest)
  signal data_ram : ram_type := (
    -- Test value $AABBCCDD at $3008 (A0+D0+4 = $3000+4+4)
    0 => x"DEAD",  -- $3000
    1 => x"BEEF",  -- $3002
    2 => x"CAFE",  -- $3004
    3 => x"BABE",  -- $3006
    4 => x"AABB",  -- $3008 (high word of TC value)
    5 => x"CCDD",  -- $300A (low word of TC value)
    others => x"DEAD"
  );

  signal mem_data : std_logic_vector(15 downto 0) := x"4E71";
  signal latched_data : std_logic_vector(15 downto 0) := x"4E71";
  signal test_done : boolean := false;

  -- PC tracking for PMOVE (4,A0,D0.W),TC
  signal saw_fetch_48 : boolean := false;  -- PMOVE opcode
  signal saw_fetch_4A : boolean := false;  -- PMOVE extension
  signal saw_fetch_4C : boolean := false;  -- Brief extension word
  signal saw_fetch_4E : boolean := false;  -- NOP (CORRECT - $48+6=$4E)

  -- PC tracking for PMOVE TC,(4,A0,D0.W)
  signal saw_fetch_50 : boolean := false;  -- PMOVE opcode
  signal saw_fetch_52 : boolean := false;  -- PMOVE extension
  signal saw_fetch_54 : boolean := false;  -- Brief extension word
  signal saw_fetch_56 : boolean := false;  -- NOP (CORRECT - $50+6=$56)

  signal saw_fetch_58 : boolean := false;  -- After tests

begin

  clk <= not clk after CLK_PERIOD/2;

  UUT: entity work.TG68KdotC_Kernel
    port map(
      clk => clk,
      nReset => nReset,
      clkena_in => clkena_in,
      data_in => data_in,
      IPL => IPL,
      IPL_autovector => '0',
      berr => '0',
      CPU => CPU,
      addr_out => addr_out,
      data_write => data_write,
      nWr => nWr,
      nUDS => nUDS,
      nLDS => nLDS,
      busstate => busstate,
      longword => longword,
      nResetOut => open,
      FC => FC,
      clr_berr => open,
      skipFetch => open,
      regin_out => open,
      CACR_out => open,
      VBR_out => open,
      cache_inv_req => open,
      cache_op_scope => open,
      cache_op_cache => open,
      cacr_ie => open,
      cacr_de => open,
      cacr_ifreeze => open,
      cacr_dfreeze => open,
      cacr_ibe => open,
      cacr_dbe => open,
      cacr_wa => open,
      pmmu_reg_we => pmmu_reg_we,
      pmmu_reg_re => pmmu_reg_re,
      pmmu_reg_sel => pmmu_reg_sel,
      pmmu_reg_wdat => open,
      pmmu_reg_part => open,
      pmmu_addr_log => open,
      pmmu_addr_phys => open,
      pmmu_cache_inhibit => open,
      cache_op_addr => open,
      pmmu_walker_req => open,
      pmmu_walker_we => open,
      pmmu_walker_addr => open,
      pmmu_walker_wdat => open,
      pmmu_walker_ack => pmmu_walker_ack,
      pmmu_walker_data => pmmu_walker_data,
      pmmu_walker_berr => '0',
      debug_SVmode => open,
      debug_preSVmode => open,
      debug_FlagsSR_S => open,
      debug_changeMode => open,
      debug_setopcode => debug_setopcode
    );

  -- Memory read logic - use lower 24 bits for address decoding
  process(addr_out)
    variable idx : integer;
    variable addr_low24 : std_logic_vector(23 downto 0);
  begin
    mem_data <= x"4E71";  -- Default NOP
    addr_low24 := addr_out(23 downto 0);

    if addr_low24(23 downto 8) = x"0000" then
      idx := to_integer(unsigned(addr_low24(7 downto 1)));
      if idx < 128 then
        mem_data <= rom(idx);
      end if;
    elsif addr_low24(23 downto 12) = x"001" then
      idx := to_integer(unsigned(addr_low24(8 downto 1)));
      if idx < 256 then
        mem_data <= stack_ram(idx);
      end if;
    elsif addr_low24(23 downto 12) = x"003" then
      idx := to_integer(unsigned(addr_low24(8 downto 1)));
      if idx < 256 then
        mem_data <= data_ram(idx);
      end if;
    end if;
  end process;

  -- Bus timing FSM
  process(clk)
  begin
    if rising_edge(clk) then
      if nReset = '0' then
        bus_fsm <= BUS_IDLE;
        clkena_in <= '0';
        data_in <= x"4E71";
        latched_data <= x"4E71";
      else
        case bus_fsm is
          when BUS_IDLE =>
            if busstate /= "01" then
              bus_fsm <= BUS_WAIT1;
              clkena_in <= '0';
              latched_data <= mem_data;
              data_in <= mem_data;
            else
              clkena_in <= '1';
              data_in <= mem_data;
            end if;

          when BUS_WAIT1 =>
            bus_fsm <= BUS_ACK;
            clkena_in <= '0';
            data_in <= latched_data;

          when BUS_ACK =>
            if longword = '1' then
              bus_fsm <= BUS_LONG_WAIT1;
              clkena_in <= '1';
            else
              bus_fsm <= BUS_IDLE;
              clkena_in <= '1';
            end if;
            data_in <= latched_data;

          when BUS_LONG_WAIT1 =>
            bus_fsm <= BUS_LONG_ACK;
            clkena_in <= '0';
            latched_data <= mem_data;
            data_in <= mem_data;

          when BUS_LONG_ACK =>
            bus_fsm <= BUS_IDLE;
            clkena_in <= '1';
            data_in <= latched_data;
        end case;
      end if;
    end if;
  end process;

  -- Memory write handling - use lower 24 bits for address decoding
  process(clk)
    variable idx : integer;
    variable addr_low24 : std_logic_vector(23 downto 0);
  begin
    if rising_edge(clk) then
      if nWr = '0' and clkena_in = '1' then
        addr_low24 := addr_out(23 downto 0);
        if addr_low24(23 downto 12) = x"001" then
          idx := to_integer(unsigned(addr_low24(8 downto 1)));
          if idx < 256 then
            stack_ram(idx) <= data_write;
          end if;
        elsif addr_low24(23 downto 12) = x"003" then
          idx := to_integer(unsigned(addr_low24(8 downto 1)));
          if idx < 256 then
            data_ram(idx) <= data_write;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Cycle counter and fetch tracker
  process(clk)
  begin
    if rising_edge(clk) then
      if nReset = '0' then
        cycle <= 0;
      else
        cycle <= cycle + 1;

        if busstate = "00" then
          case addr_out(7 downto 0) is
            when x"40" => report "CYCLE " & integer'image(cycle) & ": Fetch $40 - LEA opcode";
            when x"46" => report "CYCLE " & integer'image(cycle) & ": Fetch $46 - MOVEQ #4,D0";
            when x"48" =>
              saw_fetch_48 <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $48 - PMOVE (4,A0,D0.W),TC opcode (F030)";
            when x"4A" =>
              saw_fetch_4A <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $4A - PMOVE extension (4000)";
            when x"4C" =>
              saw_fetch_4C <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $4C - Brief extension (0004)";
            when x"4E" =>
              saw_fetch_4E <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $4E - NOP (CORRECT: $48+6=$4E)";
            when x"50" =>
              saw_fetch_50 <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $50 - PMOVE TC,(4,A0,D0.W) opcode (F030)";
            when x"52" =>
              saw_fetch_52 <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $52 - PMOVE extension (4200)";
            when x"54" =>
              saw_fetch_54 <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $54 - Brief extension (0004)";
            when x"56" =>
              saw_fetch_56 <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $56 - NOP (CORRECT: $50+6=$56)";
            when x"58" =>
              saw_fetch_58 <= true;
              report "CYCLE " & integer'image(cycle) & ": Fetch $58 - continuing";
            when others =>
              if addr_out(31 downto 8) = x"000000" and addr_out(7 downto 0) >= x"40" and addr_out(7 downto 0) <= x"60" then
                report "CYCLE " & integer'image(cycle) & ": Fetch at $" & slv_to_hex(addr_out(7 downto 0));
              end if;
          end case;
        end if;
      end if;
    end if;
  end process;

  -- Test control
  test_proc: process
  begin
    report "=== PMOVE (d8,An,Xn) PC Increment Test ===";
    report "Test 1: PMOVE (4,A0,D0.W),TC at $48 (6 bytes: F030 4000 0004) -> next PC should be $4E";
    report "Test 2: PMOVE TC,(4,A0,D0.W) at $50 (6 bytes: F030 4200 0004) -> next PC should be $56";

    wait for 100 ns;
    nReset <= '1';

    wait for 80 us;

    report "========================================";
    report "PMOVE (4,A0,D0.W),TC PC Increment Results:";
    report "  Fetched $48 (opcode):      " & boolean'image(saw_fetch_48);
    report "  Fetched $4A (PMOVE ext):   " & boolean'image(saw_fetch_4A);
    report "  Fetched $4C (brief ext):   " & boolean'image(saw_fetch_4C);
    report "  Fetched $4E (next instr):  " & boolean'image(saw_fetch_4E);
    if saw_fetch_4E then
      report "  PASS: PC correctly incremented by 6 ($48 -> $4E)";
    else
      report "  FAIL: PC did not reach $4E after PMOVE (4,A0,D0.W),TC";
    end if;

    report "----------------------------------------";
    report "PMOVE TC,(4,A0,D0.W) PC Increment Results:";
    report "  Fetched $50 (opcode):      " & boolean'image(saw_fetch_50);
    report "  Fetched $52 (PMOVE ext):   " & boolean'image(saw_fetch_52);
    report "  Fetched $54 (brief ext):   " & boolean'image(saw_fetch_54);
    report "  Fetched $56 (next instr):  " & boolean'image(saw_fetch_56);
    if saw_fetch_56 then
      report "  PASS: PC correctly incremented by 6 ($50 -> $56)";
    else
      report "  FAIL: PC did not reach $56 after PMOVE TC,(4,A0,D0.W)";
    end if;

    report "========================================";
    if saw_fetch_4E and saw_fetch_56 then
      report "ALL TESTS PASSED - PC increment correct for both PMOVE (d8,An,Xn) directions";
    else
      report "SOME TESTS FAILED - PC increment issues detected";
    end if;
    report "========================================";

    test_done <= true;
    wait;
  end process;

end behavioral;
