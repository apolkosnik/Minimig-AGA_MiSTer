-- BUG #95 (SUPERSEDED): PMOVE Dn Register Test
-- Originally verified PMOVE D0,TT0 / PMOVE TT0,D1 executed as a register
-- transfer. Cross-checked against WinUAE's mmu_op30_invea() (cpummu30.cpp),
-- which rejects Dn/An/(An)+/-(An)/immediate/PC-relative EA modes for EVERY
-- MMU register uniformly - the EA mode alone determines legality, with no
-- register-specific carve-out. TG68KdotC_Kernel.vhd's PMOVE decode was
-- updated to match: Dn is now illegal for ALL MMU registers (previously it
-- was permitted for TC/TT0/TT1/MMUSR and only rejected for CRP/SRP).
-- This test now verifies the CORRECT (WinUAE-matching) behavior: PMOVE
-- D0,TT0 must trap as an illegal F-line instruction (vector 11), not
-- execute a register transfer.
--
-- Test sequence:
--   MOVE.L #$12345678,D0   ; Load test value
--   MOVEQ #$7F,D1          ; Load different value in D1
--   PMOVE D0,TT0           ; Dn EA mode - MUST trap illegal (vector 11)
--   PMOVE TT0,D1           ; Not reached if the trap above fires correctly
--
-- Expected: debug_trap_1111 pulses at the PMOVE D0,TT0 instruction; the
-- CPU must NOT reach the $110 NOP / $112 success loop, and TT0 must never
-- be written.

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
  signal pmmu_walker_berr : std_logic := '0';

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
  signal debug_trap_1111 : std_logic;

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
  signal illegal_trap_seen : boolean := false;
  signal success_loop_reached : boolean := false;

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
      pmmu_walker_berr => pmmu_walker_berr,
      debug_SVmode => debug_SVmode,
      debug_preSVmode => open,
      debug_FlagsSR_S => open,
      debug_changeMode => open,
      debug_setopcode => debug_setopcode,
      debug_exec_directSR => open,
      debug_exec_to_SR => open,
      debug_pmove_dn_mode => debug_pmove_dn_mode,
      debug_pmove_dn_regnum => debug_pmove_dn_regnum,
      debug_trap_1111 => debug_trap_1111
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

      -- Monitor the illegal-F-line trap: this is the signal that MUST fire
      -- for PMOVE D0,TT0 now that Dn is uniformly illegal for all MMU
      -- registers (matching WinUAE's mmu_op30_invea()).
      if debug_trap_1111 = '1' and not illegal_trap_seen then
        illegal_trap_seen <= true;
        report "DEBUG: debug_trap_1111 asserted - illegal F-line trap fired";
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
            report "UNEXPECTED: reached the post-PMOVE success loop at $112";
            report "  This means PMOVE D0,TT0 executed instead of trapping -";
            report "  Dn must be illegal for ALL MMU registers (WinUAE parity).";
            report "========================================";
            success_loop_reached <= true;
          when 16#200# =>
            report "========================================";
            report "EXPECTED: CPU took the illegal-instruction exception at $200";
            report "========================================";
            test_passed <= true;
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
    report "BUG #95 (SUPERSEDED) PMOVE Dn TEST - WinUAE parity";
    report "Test sequence:";
    report "  MOVE.L #$12345678,D0";
    report "  MOVEQ #$7F,D1";
    report "  PMOVE D0,TT0  (Dn EA mode - must trap illegal, vector 11)";
    report "  PMOVE TT0,D1  (not reached if the trap fires correctly)";
    report "Expected: debug_trap_1111 fires, CPU reaches $200 handler,";
    report "TT0 is never written, success loop at $112 is NOT reached.";
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
    report "  debug_trap_1111 fired: " & boolean'image(illegal_trap_seen);
    report "  Reached $200 (exception handler): " & boolean'image(test_passed);
    report "  Reached $112 (success loop, should NOT happen): " & boolean'image(success_loop_reached);
    report "  TT0 written (should NOT happen): " & boolean'image(pmove_d0_to_tt0_seen);

    if illegal_trap_seen and test_passed and not success_loop_reached and not pmove_d0_to_tt0_seen then
      report "TEST PASSED: PMOVE D0,TT0 correctly traps as illegal (WinUAE parity)!";
    else
      if not illegal_trap_seen then
        report "  debug_trap_1111 never asserted";
      end if;
      if success_loop_reached then
        report "  CPU reached the post-PMOVE success loop instead of trapping";
      end if;
      if pmove_d0_to_tt0_seen then
        report "  TT0 was written - the illegal instruction executed anyway";
      end if;
      report "========================================";
      assert false report "TEST FAILED: PMOVE D0,TT0 did not trap as expected" severity failure;
    end if;
    report "========================================";

    test_done <= true;
    wait;
  end process;

end behavior;
