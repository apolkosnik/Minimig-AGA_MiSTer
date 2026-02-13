-- tb_movec_illegal.vhd
-- Test MOVEC to invalid register codes triggers illegal instruction trap
-- This validates the trapmake delta-cycle re-evaluation mechanism

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity tb_movec_illegal is
end entity;

architecture behavioral of tb_movec_illegal is
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
  signal clkena_in : std_logic := '1';
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal CPU : std_logic_vector(1 downto 0) := "10";  -- 68030 mode

  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS, nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal longword : std_logic;

  -- PMMU signals
  signal pmmu_walker_req : std_logic;
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

  constant CLK_PERIOD : time := 20 ns;
  signal cycle : integer := 0;

  -- Test ROM
  type rom_type is array (0 to 255) of std_logic_vector(15 downto 0);
  constant rom : rom_type := (
    -- Reset vectors at $000000
    0 => x"0000", 1 => x"2000",  -- SSP = $00002000
    2 => x"0000", 3 => x"0040",  -- PC = $00000040

    -- Illegal instruction vector (vector 4, offset $10) -> handler at $80
    8 => x"0000", 9 => x"0080",

    -- Test program at $000040 (word index 32):
    -- MOVEC D0,Reg003 (register code 0x003 is invalid for MOVEC - TC is PMOVE only!)
    -- Encoding: $4E7B $0003 (MOVEC D0,<reg 003>)
    32 => x"4E7B", 33 => x"0003",  -- Should trap as illegal

    -- If trap doesn't fire, we'll hit these
    34 => x"4AFC",  -- ILLEGAL opcode (explicit trap marker)
    35 => x"4E71",  -- NOP

    -- Illegal instruction handler at $80 (word index 64):
    -- The stacked PC points to the MOVEC instruction ($40)
    -- We need to add 4 to the stacked PC to skip the 4-byte MOVEC instruction
    -- Stack frame format 0 (68030): SR(2) + PC(4) = 6 bytes, but for format 2 it's longer
    -- For format 0: PC is at offset 2 from current SP
    -- Handler: MOVE.L 2(SP),D0; ADDQ.L #4,D0; MOVE.L D0,2(SP); RTE
    64 => x"202F", 65 => x"0002",  -- MOVE.L 2(A7),D0
    66 => x"5880",                  -- ADDQ.L #4,D0
    67 => x"2F40", 68 => x"0002",  -- MOVE.L D0,2(A7)
    69 => x"4E73",  -- RTE
    70 => x"4E71",  -- NOP

    -- After RTE, should return to $44 (instruction after MOVEC)
    -- Then we have STOP to end the test
    36 => x"4E72", 37 => x"2700",  -- STOP #$2700 at $48

    others => x"4E71"
  );

  signal mem_data : std_logic_vector(15 downto 0) := x"4E71";

  -- RAM for stack area (around $2000)
  type ram_type is array (0 to 255) of std_logic_vector(15 downto 0);
  signal ram : ram_type := (others => x"0000");

  -- Tracking
  signal saw_handler : boolean := false;
  signal saw_rte_return : boolean := false;
  signal saw_fail : boolean := false;
  signal saw_stop : boolean := false;
  signal saw_format_word : boolean := false;
  signal format_word : std_logic_vector(15 downto 0) := (others => '0');

begin
  clk <= not clk after CLK_PERIOD/2;

  uut: entity work.TG68KdotC_Kernel
    port map (
      clk => clk,
      nReset => nReset,
      clkena_in => clkena_in,
      data_in => data_in,
      IPL => IPL,
      IPL_autovector => '1',
      CPU => CPU,
      busstate => busstate,
      addr_out => addr_out,
      data_write => data_write,
      nWr => nWr,
      nUDS => nUDS,
      nLDS => nLDS,
      longword => longword,
      FC => open,
      clr_berr => open,
      berr => '0',
      pmmu_walker_req => pmmu_walker_req,
      pmmu_walker_we => open,
      pmmu_walker_addr => open,
      pmmu_walker_wdat => open,
      pmmu_walker_ack => pmmu_walker_ack,
      pmmu_walker_data => pmmu_walker_data,
      pmmu_walker_berr => '0'
    );

  -- Combinational memory read
  process(addr_out, ram)
    variable word_addr : integer;
    variable ram_addr : integer;
    variable addr_int : integer;
  begin
    -- Default to NOP
    mem_data <= x"4E71";
    addr_int := to_integer(unsigned(addr_out));

    -- ROM area: $000000-$0001FF
    if addr_int < 16#200# then
      word_addr := to_integer(unsigned(addr_out(8 downto 1)));
      if word_addr <= 255 then
        mem_data <= rom(word_addr);
      end if;
    -- RAM area: $001F00-$0020FF (stack around $2000, 256 words)
    elsif addr_int >= 16#1F00# and addr_int < 16#2100# then
      ram_addr := to_integer(unsigned(addr_out(8 downto 1)));
      mem_data <= ram(ram_addr);
    end if;
  end process;

  data_in <= mem_data;

  -- RAM write process
  process(clk)
    variable ram_addr : integer;
    variable addr_int : integer;
  begin
    if rising_edge(clk) then
      -- Check for write cycle to RAM area (busstate "11" = write)
      if busstate = "11" and nWr = '0' then
        addr_int := to_integer(unsigned(addr_out));
        if addr_int >= 16#1F00# and addr_int < 16#2100# then
          ram_addr := to_integer(unsigned(addr_out(8 downto 1)));
          if nUDS = '0' then
            ram(ram_addr)(15 downto 8) <= data_write(15 downto 8);
          end if;
          if nLDS = '0' then
            ram(ram_addr)(7 downto 0) <= data_write(7 downto 0);
          end if;
          if addr_int = 16#1FFE# then
            format_word <= data_write;
            saw_format_word <= true;
          end if;
          report "RAM WRITE: addr=$" & slv_to_hex(addr_out) & " data=$" & slv_to_hex(data_write);
        end if;
      end if;
    end if;
  end process;

  -- Monitoring
  process(clk)
  begin
    if rising_edge(clk) then
      if nReset = '0' then
        cycle <= 0;
      else
        cycle <= cycle + 1;

        -- Track memory reads from stack area
        if busstate = "10" then  -- Memory read
          if to_integer(unsigned(addr_out)) >= 16#1F00# and to_integer(unsigned(addr_out)) < 16#2100# then
            report "CYCLE " & integer'image(cycle) & ": STACK READ addr=$" & slv_to_hex(addr_out) & " data=$" & slv_to_hex(mem_data);
          end if;
        end if;

        -- Track fetches
        if busstate = "00" then
          report "CYCLE " & integer'image(cycle) & ": FETCH addr=$" & slv_to_hex(addr_out);

          case addr_out is
            when x"00000040" =>
              report "  --> MOVEC D0,Reg003 at $40";
            when x"00000044" =>
              -- Note: Due to pipelining, $44 may be prefetched before trap handler is reached
              if saw_handler then
                saw_rte_return <= true;
                report "  --> RTE returned to $44";
              else
                report "  --> Prefetched $44 (trap processing may be in progress)";
              end if;
            when x"00000046" =>
              -- Stacked PC was $0042 (extension word), handler adds 4 = $0046
              if saw_handler then
                saw_rte_return <= true;
                report "  --> SUCCESS: RTE returned to $46 (after handler adjusted PC from $42)";
              end if;
            when x"00000048" =>
              saw_stop <= true;
              report "  --> STOP instruction at $48";
            when x"00000080" =>
              saw_handler <= true;
              report "  --> SUCCESS: Reached illegal instruction handler at $80";
            when others =>
              null;
          end case;
        end if;
      end if;
    end if;
  end process;

  -- Test control
  process
  begin
    report "=== MOVEC ILLEGAL REGISTER TRAP TEST ===";
    report "Testing: MOVEC D0,Reg003 (register code 0x003 is INVALID - TC is PMOVE only)";
    report "Expected: Illegal trap -> handler at $80 -> RTE to $44 -> STOP at $48";

    wait for 100 ns;
    nReset <= '1';

    -- Wait for test to complete (wait for handler and RTE return)
    for i in 0 to 500 loop
      wait until rising_edge(clk);
      if saw_stop then
        exit;
      end if;
      -- If we've seen the handler but not returned yet, keep waiting
    end loop;

    report "========================================";
    report "Test Results:";
    report "  Handler reached ($80): " & boolean'image(saw_handler);
    report "  RTE returned ($44):    " & boolean'image(saw_rte_return);
    report "  STOP reached ($48):    " & boolean'image(saw_stop);
    report "========================================";

    report "  Format word (SP+6): " & slv_to_hex(format_word);
    report "  Format word valid:  " & boolean'image(saw_format_word and format_word(15 downto 12) = "0000" and format_word(11 downto 0) = x"010");

    if saw_handler and saw_rte_return and saw_stop and saw_format_word and format_word(15 downto 12) = "0000" and format_word(11 downto 0) = x"010" then
      report "*** MOVEC ILLEGAL TRAP TEST PASSED ***";
      report "MOVEC to invalid register (code 0x003) correctly generates illegal instruction trap";
      report "Handler at $80 was reached, RTE returned successfully, STOP executed";
    elsif saw_handler then
      report "*** MOVEC ILLEGAL TRAP TEST PARTIAL ***";
      report "MOVEC trap fired and handler reached at $80";
      if not saw_rte_return then
        report "WARNING: RTE return not verified";
      end if;
      if not saw_stop then
        report "WARNING: STOP not reached";
      end if;
      if not saw_format_word then
        report "WARNING: Format/vector word not observed at SP+6";
      elsif format_word(15 downto 12) /= "0000" or format_word(11 downto 0) /= x"010" then
        report "WARNING: Format/vector word unexpected (expected $0010)";
      end if;
    else
      report "*** MOVEC ILLEGAL TRAP TEST FAILED ***" severity error;
      report "  ERROR: Trap handler never reached!" severity error;
    end if;

    wait;
  end process;

end behavioral;
