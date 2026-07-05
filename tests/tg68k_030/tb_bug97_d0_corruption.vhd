-- BUG #97 (SUPERSEDED): PMOVE Dn WRITE corrupts source register D0
-- Originally verified D0 kept its value across a PMOVE D0,TT0 that executed
-- normally as a register transfer. Cross-checked against WinUAE's
-- mmu_op30_invea() (cpummu30.cpp), which rejects Dn for EVERY MMU register
-- uniformly - TG68KdotC_Kernel.vhd's PMOVE decode now matches: Dn is illegal
-- for all MMU registers (see tb_bug95_pmove_dn.vhd). PMOVE D0,TT0 no longer
-- executes at all; it traps as an illegal F-line instruction (vector 11).
--
-- This test now verifies the narrower, still-meaningful claim: an illegal
-- instruction must have NO side effects before it traps. D0 must be
-- unchanged both at the PMOVE and after the CPU reaches the exception
-- handler - i.e. the illegal-instruction path itself must not corrupt the
-- register file on its way to trapping.
--
-- Test sequence:
--   MOVE.L #$12345678,D0   ; Load test value
--   PMOVE D0,TT0           ; Dn EA mode - must trap illegal (vector 11)
--                          ; D0 must still be $12345678 at the handler
--
-- Expected: debug_trap_1111 pulses, CPU reaches the $200 handler, and D0
-- is unchanged at that point.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.TG68K_Pack.all;

entity tb_bug97_d0_corruption is
end tb_bug97_d0_corruption;

architecture behavior of tb_bug97_d0_corruption is

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
  signal regin_out : std_logic_vector(31 downto 0);  -- Direct D0 access

  -- PMMU interface
  signal pmmu_walker_req : std_logic;
  signal pmmu_walker_addr : std_logic_vector(31 downto 0);
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_walker_berr : std_logic := '0';
  signal debug_trap_1111 : std_logic;

  -- PMMU register interface
  signal pmmu_reg_we : std_logic;
  signal pmmu_reg_re : std_logic;
  signal pmmu_reg_sel : std_logic_vector(4 downto 0);
  signal pmmu_reg_wdat : std_logic_vector(31 downto 0);

  type mem_array is array (0 to 4095) of std_logic_vector(15 downto 0);

  function init_memory return mem_array is
    variable result : mem_array := (others => x"4E71");
  begin
    -- Reset vectors
    result(0) := x"0000";
    result(1) := x"1000";  -- SSP = $00001000
    result(2) := x"0000";
    result(3) := x"0100";  -- PC = $00000100

    -- Exception vectors point to handler at $200 (illegal F-line = vector 11
    -- lands here too, same as every other vector)
    for i in 4 to 511 loop
      if (i mod 2) = 0 then
        result(i) := x"0000";
      else
        result(i) := x"0200";
      end if;
    end loop;

    -- $200: MOVE.L D0,$0900.L - unambiguous D0 marker store (regin_out is a
    -- multiplexed register-file output that reflects whatever register the
    -- microcode currently addresses, not always D0 - it cannot be trusted to
    -- read D0 during exception-handling bus activity, so store D0 to memory
    -- explicitly instead and observe the write directly).
    result(256) := x"23C0";  -- $200: MOVE.L D0,$0900.L
    result(257) := x"0000";
    result(258) := x"0900";
    result(259) := x"60FE";  -- $206: BRA.S -2 (loop)

    -- Test program at $100
    result(128) := x"203C";  -- $100: MOVE.L #$12345678,D0
    result(129) := x"1234";  -- $102: immediate data high
    result(130) := x"5678";  -- $104: immediate data low

    result(131) := x"F000";  -- $106: PMOVE D0,TT0 - must trap illegal now
    result(132) := x"0800";  -- $108: Extension word for PMOVE D0,TT0

    result(133) := x"4E71";  -- $10A: NOP (NOT reached if the trap fires)
    result(134) := x"4E71";  -- $10C: NOP
    result(135) := x"60FE";  -- $10E: BRA.S -2 (should NOT be reached)

    return result;
  end function;

  signal mem : mem_array := init_memory;

  constant CLK_PERIOD : time := 20 ns;
  signal test_done : boolean := false;
  signal d0_at_handler : std_logic_vector(31 downto 0) := (others => '0');
  signal illegal_trap_seen : boolean := false;
  signal handler_reached : boolean := false;
  signal success_loop_reached : boolean := false;
  signal d0_marker_seen : boolean := false;

  -- PMMU register file simulation
  type pmmu_regs_t is array(0 to 31) of std_logic_vector(31 downto 0);
  signal pmmu_regs : pmmu_regs_t := (others => (others => '0'));

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
      debug_SVmode => open,
      debug_preSVmode => open,
      debug_FlagsSR_S => open,
      debug_changeMode => open,
      debug_setopcode => open,
      debug_exec_directSR => open,
      debug_exec_to_SR => open,
      debug_pmove_dn_mode => open,
      debug_pmove_dn_regnum => open,
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

  -- Watch for the handler's MOVE.L D0,$0900.L write - the only reliable way
  -- to read D0's true value, since regin_out is a multiplexed register-file
  -- output that reflects whatever register the microcode currently
  -- addresses, not always D0 (it cannot be trusted during exception-entry
  -- bus activity, which reads/writes other internal registers too).
  mem_write_monitor: process(clk)
    variable addr_idx : integer;
  begin
    if rising_edge(clk) then
      if busstate = "11" and nWr = '0' then
        addr_idx := to_integer(unsigned(addr_out(13 downto 1)));
        if addr_idx = 16#0900#/2 and not d0_marker_seen then
          d0_marker_seen <= true;
          d0_at_handler(31 downto 16) <= data_write;
          report "  -> D0 marker store: high word = $" & integer'image(to_integer(unsigned(data_write)));
        elsif addr_idx = 16#0900#/2 + 1 and d0_marker_seen then
          d0_at_handler(15 downto 0) <= data_write;
          report "  -> D0 marker store: low word = $" & integer'image(to_integer(unsigned(data_write)));
        end if;
      end if;
    end if;
  end process;

  -- Track D0 value via CPU internal register file access
  -- We monitor regin_out when D0 is being accessed
  track: process(clk)
  begin
    if rising_edge(clk) then
      if debug_trap_1111 = '1' and not illegal_trap_seen then
        illegal_trap_seen <= true;
        report "DEBUG: debug_trap_1111 asserted - illegal F-line trap fired";
      end if;

      if busstate = "00" then
        case to_integer(unsigned(addr_out(15 downto 0))) is
          when 16#100# =>
            report "  -> MOVE.L #$12345678,D0";
          when 16#106# =>
            report "  -> PMOVE D0,TT0 (must trap illegal)";
          when 16#10A# | 16#10E# =>
            report "UNEXPECTED: reached $" & integer'image(to_integer(unsigned(addr_out(15 downto 0)))) &
                   " - PMOVE D0,TT0 executed instead of trapping";
            success_loop_reached <= true;
          when 16#200# =>
            if not handler_reached then
              handler_reached <= true;
              report "  -> Reached $200 handler, storing D0 to $0900 for verification";
            end if;
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

      if pmmu_reg_we = '1' and reg_idx < 32 then
        pmmu_regs(reg_idx) <= pmmu_reg_wdat;
        report "PMMU REG WRITE: reg[" & integer'image(reg_idx) & "] = $" &
               integer'image(to_integer(unsigned(pmmu_reg_wdat)));
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
    report "BUG #97 (SUPERSEDED) D0 CORRUPTION TEST - WinUAE parity";
    report "Test: PMOVE D0,TT0 must trap illegal AND leave D0 unchanged";
    report "========================================";

    nReset <= '1';

    -- Wait for test completion
    for i in 1 to 300 loop
      wait for 100 ns;
      if d0_marker_seen then
        exit;
      end if;
    end loop;

    wait for 200 ns;

    report "========================================";
    report "FINAL RESULTS:";
    report "  debug_trap_1111 fired: " & boolean'image(illegal_trap_seen);
    report "  Reached $200 handler: " & boolean'image(handler_reached);
    report "  D0 marker stored: " & boolean'image(d0_marker_seen);
    report "  Reached post-PMOVE fallthrough (should NOT happen): " & boolean'image(success_loop_reached);
    report "  D0 at handler = $" & integer'image(to_integer(unsigned(d0_at_handler)));

    if illegal_trap_seen and handler_reached and d0_marker_seen and not success_loop_reached
       and d0_at_handler = x"12345678" then
      report "TEST PASSED: PMOVE D0,TT0 traps illegal and D0 is not corrupted!";
    else
      if not illegal_trap_seen then
        report "  debug_trap_1111 never asserted";
      end if;
      if not d0_marker_seen then
        report "  D0 marker was never stored - handler did not complete";
      end if;
      if success_loop_reached then
        report "  CPU executed past the illegal PMOVE instead of trapping";
      end if;
      if d0_marker_seen and d0_at_handler /= x"12345678" then
        report "  D0 corrupted: $" & integer'image(to_integer(unsigned(d0_at_handler)));
      end if;
      report "========================================";
      assert false report "TEST FAILED: PMOVE D0,TT0 did not trap cleanly" severity failure;
    end if;
    report "========================================";

    test_done <= true;
    wait;
  end process;

end behavior;
