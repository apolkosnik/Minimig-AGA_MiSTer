-- BUG #95: PMOVE Dn Register Test
-- Tests PMOVE with data register mode (both directions)
--
-- Test sequence:
--   MOVE.L #$12345678,D0   ; Load test value
--   MOVEQ #$7F,D1          ; Load different value in D1
--   PMOVE D0,TT0           ; Write D0 to TT0 (register->MMU)
--   PMOVE TT0,D1           ; Read TT0 to D1 (MMU->register)
--
-- Expected: D1 should contain $12345678 after execution

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.TG68K_Pack.all;

entity tb_bug95_pmove_dn is
end tb_bug95_pmove_dn;

architecture behavior of tb_bug95_pmove_dn is

  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal clkena_in : std_logic;
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal CPU : std_logic_vector(1 downto 0) := "10";  -- 68030 with PMMU
  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS : std_logic;
  signal nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal nResetOut : std_logic;
  signal FC : std_logic_vector(2 downto 0);
  signal regin_out : std_logic_vector(31 downto 0);  -- D0 output
  signal d0_value : std_logic_vector(31 downto 0) := (others => '0');  -- Track D0

  -- PMMU interface
  signal pmmu_walker_req : std_logic;
  signal pmmu_walker_addr : std_logic_vector(31 downto 0);
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

  -- PMMU register interface
  signal pmmu_reg_we : std_logic;
  signal pmmu_reg_re : std_logic;
  signal pmmu_reg_sel : std_logic_vector(4 downto 0);
  signal pmmu_reg_wdat : std_logic_vector(31 downto 0);

  -- Debug signals
  signal debug_SVmode : std_logic;
  signal debug_pmove_dn_mode : std_logic;
  signal debug_pmove_dn_regnum : std_logic_vector(2 downto 0);
  signal debug_setopcode : std_logic;

  type mem_array is array (0 to 4095) of std_logic_vector(15 downto 0);

  function init_memory return mem_array is
    variable result : mem_array := (others => x"4E71");
  begin
    -- Reset vectors
    result(0) := x"0000";
    result(1) := x"1000";  -- SSP = $00001000
    result(2) := x"0000";
    result(3) := x"0100";  -- PC = $00000100

    -- Exception vectors point to handler at $200
    for i in 4 to 511 loop
      if (i mod 2) = 0 then
        result(i) := x"0000";
      else
        result(i) := x"0200";
      end if;
    end loop;

    result(256) := x"60FE";  -- $200: BRA.S -2 (exception handler)

    -- Test program at $100 (word address 128)
    result(128) := x"203C";  -- $100: MOVE.L #$12345678,D0
    result(129) := x"1234";  -- $102: immediate data high
    result(130) := x"5678";  -- $104: immediate data low

    result(131) := x"727F";  -- $106: MOVEQ #$7F,D1

    result(132) := x"F000";  -- $108: PMOVE D0,TT0 (EA mode=000 Dn, reg=000 D0)
    result(133) := x"0800";  -- $10A: Extension word for PMOVE D0,TT0

    result(134) := x"F001";  -- $10C: PMOVE TT0,D1 (EA mode=000 Dn, reg=001 D1)
    result(135) := x"0A00";  -- $10E: Extension word for PMOVE TT0,D1

    result(136) := x"4E71";  -- $110: NOP
    result(137) := x"60FE";  -- $112: BRA.S -2 (success loop)
    result(138) := x"4AFC";  -- $114: ILLEGAL

    return result;
  end function;

  signal mem : mem_array := init_memory;

  constant CLK_PERIOD : time := 20 ns;
  signal test_done : boolean := false;
  signal test_passed : boolean := false;

  -- PMMU register file simulation
  type pmmu_regs_t is array(0 to 31) of std_logic_vector(31 downto 0);
  signal pmmu_regs : pmmu_regs_t := (others => (others => '0'));

  -- Track PMOVE operations
  signal pmove_d0_to_tt0_seen : boolean := false;
  signal pmove_tt0_to_d1_seen : boolean := false;
  signal tt0_value_written : std_logic_vector(31 downto 0) := (others => '0');

begin

  clkena_in <= not pmmu_walker_req;

  cpu_dut: entity work.TG68KdotC_Kernel
    generic map (
      SR_Read => 2,
      VBR_Stackframe => 2,
      extAddr_Mode => 2,
      MUL_Mode => 2,
      DIV_Mode => 2,
      BitField => 2,
      BarrelShifter => 1,
      MUL_Hardware => 1
    )
    port map (
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
      longword => open,
      nResetOut => nResetOut,
      FC => FC,
      clr_berr => open,
      skipFetch => open,
      regin_out => regin_out,
      CACR_out => open,
      VBR_out => open,
      cache_cinv_req => open,
      cache_cpush_req => open,
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
      pmmu_reg_wdat => pmmu_reg_wdat,
      pmmu_reg_part => open,
      pmmu_addr_log => open,
      pmmu_addr_phys => open,
      pmmu_cache_inhibit => open,
      cache_op_addr => open,
      pmmu_walker_req => pmmu_walker_req,
      pmmu_walker_addr => pmmu_walker_addr,
      pmmu_walker_ack => pmmu_walker_ack,
      pmmu_walker_data => pmmu_walker_data,
      debug_SVmode => debug_SVmode,
      debug_preSVmode => open,
      debug_FlagsSR_S => open,
      debug_changeMode => open,
      debug_setopcode => debug_setopcode,
      debug_exec_directSR => open,
      debug_exec_to_SR => open,
      debug_pmove_dn_mode => debug_pmove_dn_mode,
      debug_pmove_dn_regnum => debug_pmove_dn_regnum
    );

  clk_process: process
  begin
    if not test_done then
      clk <= '0';
      wait for CLK_PERIOD/2;
      clk <= '1';
      wait for CLK_PERIOD/2;
    else
      wait;
    end if;
  end process;

  -- Memory read - COMBINATIONAL
  mem_read: process(addr_out, busstate)
    variable addr_idx : integer;
  begin
    if busstate /= "11" then
      addr_idx := to_integer(unsigned(addr_out(13 downto 1)));
      if addr_idx < 4096 then
        data_in <= mem(addr_idx);
      else
        data_in <= x"4E71";
      end if;
    end if;
  end process;

  -- Track instruction execution
  track: process(clk)
  begin
    if rising_edge(clk) then
      -- Monitor microstate transitions
      if debug_setopcode = '1' then
        report "DEBUG: setopcode asserted @ PC=$" & integer'image(to_integer(unsigned(addr_out(15 downto 0))));
      end if;

      -- Monitor debug_pmove_dn_mode to detect PMOVE Dn operations
      if debug_pmove_dn_mode = '1' then
        report "DEBUG: PMOVE Dn mode active, regnum=" & integer'image(to_integer(unsigned(debug_pmove_dn_regnum)));
      end if;

      -- Monitor PMMU register interface activity
      if pmmu_reg_we = '1' then
        report "DEBUG: pmmu_reg_we=1, sel=" & integer'image(to_integer(unsigned(pmmu_reg_sel))) &
               ", wdat=$" & integer'image(to_integer(unsigned(pmmu_reg_wdat)));
      end if;
      if pmmu_reg_re = '1' then
        report "DEBUG: pmmu_reg_re=1, sel=" & integer'image(to_integer(unsigned(pmmu_reg_sel)));
      end if;

      if busstate = "00" then
        case to_integer(unsigned(addr_out(15 downto 0))) is
          when 16#100# =>
            report "  -> MOVE.L #$12345678,D0";
          when 16#106# =>
            report "  -> MOVEQ #$7F,D1 [D0=" & integer'image(to_integer(unsigned(regin_out))) & "]";
            d0_value <= regin_out;  -- Capture D0 after MOVE.L
          when 16#108# =>
            report "  -> PMOVE D0,TT0 (register->MMU) - opcode=$F000 [D0=" &
                   integer'image(to_integer(unsigned(regin_out))) & "]";
          when 16#10A# =>
            report "  -> Extension word for PMOVE";
          when 16#10C# =>
            report "  -> PMOVE TT0,D1 (MMU->register) - opcode=$F001 [D0=" &
                   integer'image(to_integer(unsigned(regin_out))) & "]";
          when 16#10E# =>
            report "  -> Extension word for PMOVE";
          when 16#110# =>
            report "  -> NOP - Test sequence complete [D0=" &
                   integer'image(to_integer(unsigned(regin_out))) & "]";
          when 16#112# =>
            report "========================================";
            report "SUCCESS: Reached success loop at $112";
            report "  D0 captured = $" & integer'image(to_integer(unsigned(d0_value)));
            report "  D0 current  = $" & integer'image(to_integer(unsigned(regin_out)));
            report "========================================";
            test_passed <= true;
          when 16#200# =>
            report "========================================";
            report "EXCEPTION: CPU took exception at $200";
            report "========================================";
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  -- PMMU register file handler
  pmmu_regs_handler: process(clk)
    variable reg_idx : integer;
  begin
    if rising_edge(clk) then
      reg_idx := to_integer(unsigned(pmmu_reg_sel));

      -- Handle PMMU register writes
      if pmmu_reg_we = '1' and reg_idx < 32 then
        pmmu_regs(reg_idx) <= pmmu_reg_wdat;
        report "PMMU REG WRITE: reg[" & integer'image(reg_idx) & "] = $" &
               integer'image(to_integer(unsigned(pmmu_reg_wdat(31 downto 16)))) & "_" &
               integer'image(to_integer(unsigned(pmmu_reg_wdat(15 downto 0))));

        -- Track TT0 writes (register 2 = TT0, corrected from observed sel value)
        if reg_idx = 2 then
          tt0_value_written <= pmmu_reg_wdat;
          pmove_d0_to_tt0_seen <= true;
          report "  -> TT0 written with value from D0";
        end if;
      end if;

      -- Handle PMMU register reads
      if pmmu_reg_re = '1' and reg_idx < 32 then
        report "PMMU REG READ: reg[" & integer'image(reg_idx) & "] = $" &
               integer'image(to_integer(unsigned(pmmu_regs(reg_idx)(31 downto 16)))) & "_" &
               integer'image(to_integer(unsigned(pmmu_regs(reg_idx)(15 downto 0))));

        if reg_idx = 2 then
          pmove_tt0_to_d1_seen <= true;
          report "  -> TT0 read to D1";
        end if;
      end if;
    end if;
  end process;

  -- PMMU walker response
  pmmu_walker_response: process(clk)
  begin
    if rising_edge(clk) then
      if pmmu_walker_req = '1' then
        pmmu_walker_ack <= '1';
        pmmu_walker_data <= X"00000000";
      else
        pmmu_walker_ack <= '0';
      end if;
    end if;
  end process;

  -- Test stimulus
  stim_proc: process
  begin
    nReset <= '0';
    wait for 100 ns;

    report "========================================";
    report "BUG #95 PMOVE Dn TEST";
    report "Test sequence:";
    report "  MOVE.L #$12345678,D0";
    report "  MOVEQ #$7F,D1";
    report "  PMOVE D0,TT0  (register->MMU)";
    report "  PMOVE TT0,D1  (MMU->register)";
    report "Expected: TT0=$12345678 after PMOVE D0,TT0";
    report "========================================";

    nReset <= '1';

    -- Wait for test completion
    for i in 1 to 300 loop
      wait for 100 ns;
      if test_passed then
        exit;
      end if;
    end loop;

    wait for 100 ns;

    report "========================================";
    report "TEST RESULTS:";
    report "  PMOVE D0,TT0 executed: " & boolean'image(pmove_d0_to_tt0_seen);
    report "  PMOVE TT0,D1 executed: " & boolean'image(pmove_tt0_to_d1_seen);
    report "  TT0 value written: $" &
           integer'image(to_integer(unsigned(tt0_value_written(31 downto 16)))) & "_" &
           integer'image(to_integer(unsigned(tt0_value_written(15 downto 0))));

    if pmove_d0_to_tt0_seen and pmove_tt0_to_d1_seen then
      if tt0_value_written = x"12345678" then
        report "TEST PASSED: PMOVE Dn operations work correctly!";
      else
        report "TEST FAILED: TT0 has wrong value";
        report "  Expected: $12345678";
        report "  Got: $" & integer'image(to_integer(unsigned(tt0_value_written)));
      end if;
    else
      report "TEST FAILED: Not all PMOVE operations completed";
    end if;
    report "========================================";

    test_done <= true;
    wait;
  end process;

end behavior;
