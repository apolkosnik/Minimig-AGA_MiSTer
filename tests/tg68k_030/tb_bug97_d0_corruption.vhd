-- BUG #97: PMOVE Dn WRITE corrupts source register D0
-- Verifies that D0 is NOT corrupted after PMOVE D0,TT0
--
-- Test sequence:
--   MOVE.L #$12345678,D0   ; Load test value
--   PMOVE D0,TT0           ; Write D0 to TT0 (should NOT corrupt D0!)
--   NOP                    ; D0 should still be $12345678
--
-- Expected: D0 = $12345678 after PMOVE (not corrupted)

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

    -- Test program at $100
    result(128) := x"203C";  -- $100: MOVE.L #$12345678,D0
    result(129) := x"1234";  -- $102: immediate data high
    result(130) := x"5678";  -- $104: immediate data low

    result(131) := x"F000";  -- $106: PMOVE D0,TT0 (should NOT corrupt D0!)
    result(132) := x"0800";  -- $108: Extension word for PMOVE D0,TT0

    result(133) := x"4E71";  -- $10A: NOP
    result(134) := x"4E71";  -- $10C: NOP
    result(135) := x"60FE";  -- $10E: BRA.S -2 (success loop)

    return result;
  end function;

  signal mem : mem_array := init_memory;

  constant CLK_PERIOD : time := 20 ns;
  signal test_done : boolean := false;
  signal d0_after_move : std_logic_vector(31 downto 0) := (others => '0');
  signal d0_after_pmove : std_logic_vector(31 downto 0) := (others => '0');

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
      debug_SVmode => open,
      debug_preSVmode => open,
      debug_FlagsSR_S => open,
      debug_changeMode => open,
      debug_setopcode => open,
      debug_exec_directSR => open,
      debug_exec_to_SR => open,
      debug_pmove_dn_mode => open,
      debug_pmove_dn_regnum => open
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

  -- Track D0 value via CPU internal register file access
  -- We monitor regin_out when D0 is being accessed
  track: process(clk)
  begin
    if rising_edge(clk) then
      if busstate = "00" then
        case to_integer(unsigned(addr_out(15 downto 0))) is
          when 16#100# =>
            report "  -> MOVE.L #$12345678,D0";
          when 16#106# =>
            -- Capture D0 after MOVE.L completes
            d0_after_move <= regin_out;
            report "  -> PMOVE D0,TT0 - D0 before=" & integer'image(to_integer(unsigned(regin_out)));
          when 16#10A# =>
            -- Capture D0 after PMOVE completes
            d0_after_pmove <= regin_out;
            report "  -> NOP - D0 after PMOVE=" & integer'image(to_integer(unsigned(regin_out)));
          when 16#10E# =>
            report "========================================";
            report "D0 TEST RESULTS:";
            report "  D0 after MOVE.L  = $" & integer'image(to_integer(unsigned(d0_after_move)));
            report "  D0 after PMOVE   = $" & integer'image(to_integer(unsigned(d0_after_pmove)));
            report "  Expected         = $305419896 ($12345678)";

            if d0_after_pmove = x"12345678" then
              report "TEST PASSED: D0 NOT corrupted!";
            else
              report "TEST FAILED: D0 CORRUPTED!";
              report "  Corruption = $" & integer'image(to_integer(unsigned(d0_after_pmove)));
            end if;
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
    report "BUG #97 D0 CORRUPTION TEST";
    report "Test: Verify D0 is NOT corrupted by PMOVE D0,TT0";
    report "========================================";

    nReset <= '1';

    -- Wait for test completion
    for i in 1 to 200 loop
      wait for 100 ns;
    end loop;

    test_done <= true;
    wait;
  end process;

end behavior;
