-- BUG #95: PMOVE Memory EA PC Increment Test
-- Tests that PMOVE TT0,(4,A0) advances PC by 6 bytes (not 8)
--
-- Test case from BUILD_343_SUMMARY.md:
--   $0: PMOVE TT0,(4,A0)  ; 6 bytes: opcode + extension + displacement
--   $6: NOP               ; Should execute HERE
--   $8: ILLEGAL           ; NOT here (that would be +8 bug)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.TG68K_Pack.all;

entity tb_bug95_pmove_ea_pc is
end tb_bug95_pmove_ea_pc;

architecture behavior of tb_bug95_pmove_ea_pc is

  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal clkena_in : std_logic;  -- Computed from pmmu_walker_req!
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal CPU : std_logic_vector(1 downto 0) := "10";  -- 68030 with PMMU (reworked from 68020)
  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS : std_logic;
  signal nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal nResetOut : std_logic;
  signal FC : std_logic_vector(2 downto 0);

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

  -- Debug signals to monitor CPU state
  signal debug_SVmode : std_logic;
  signal debug_preSVmode : std_logic;
  signal debug_FlagsSR_S : std_logic;
  signal debug_setopcode : std_logic;

  type mem_array is array (0 to 4095) of std_logic_vector(15 downto 0);

  -- Initialize memory with test program at address $100
  function init_memory return mem_array is
    variable result : mem_array := (others => x"4E71");
  begin
    -- Reset vectors (must NOT be overwritten!)
    result(0) := x"0000";  -- SSP high
    result(1) := x"1000";  -- SSP low = $00001000
    result(2) := x"0000";  -- PC high
    result(3) := x"0100";  -- PC low = $00000100 (test program address)

    -- Exception vectors ($8-$3FF, word addresses 4-511) - all point to exception handler at $200
    for i in 4 to 511 loop
      if (i mod 2) = 0 then
        result(i) := x"0000";    -- Exception vector high word
      else
        result(i) := x"0200";    -- Exception vector low word = $200
      end if;
    end loop;

    -- Exception handler at $200 (word address 256): infinite loop
    result(256) := x"60FE";  -- $200: BRA.S -2 (infinite loop)

    -- Test program starts at $100 (word address 128)
    -- BUG #95 TEST: PMOVE with memory EA mode PC increment

    -- Setup: Initialize A0 to point to a valid memory location
    result(128) := x"207C";  -- $100: MOVEA.L #$00001000,A0 (opcode)
    result(129) := x"0000";  -- $102: (immediate data high word)
    result(130) := x"1000";  -- $104: (immediate data low word)

    -- CRITICAL TEST: PMOVE TT0,(4,A0) - 6 bytes total
    result(131) := x"F028";  -- $106: PMOVE TT0,(d16,A0) opcode
    result(132) := x"0A00";  -- $108: TT0 register selector
    result(133) := x"0004";  -- $10A: displacement = +4

    -- PC should be $10C after PMOVE (6-byte increment from $106)
    result(134) := x"4E71";  -- $10C: NOP <- CORRECT if BUG #95 is FIXED
    result(135) := x"60FE";  -- $10E: BRA.S -2 (infinite loop = SUCCESS)

    -- PC should NOT be $10E (8-byte increment would skip the NOP)
    result(136) := x"4AFC";  -- $110: ILLEGAL <- WRONG if BUG #95 exists

    return result;
  end function;

  signal mem : mem_array := init_memory;

  constant CLK_PERIOD : time := 20 ns;
  signal test_done : boolean := false;
  signal nop_executed : boolean := false;
  signal illegal_executed : boolean := false;

  -- PMMU register file simulation (TG68K_PMMU_030 reads these)
  type pmmu_regs_t is array(0 to 31) of std_logic_vector(31 downto 0);
  signal pmmu_regs : pmmu_regs_t := (others => (others => '0'));
  signal pmmu_reg_rdat : std_logic_vector(31 downto 0) := (others => '0');

begin

  -- CRITICAL: Gate CPU clock enable with PMMU walker request
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
      regin_out => open,
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
      debug_preSVmode => debug_preSVmode,
      debug_FlagsSR_S => debug_FlagsSR_S,
      debug_changeMode => open,
      debug_setopcode => debug_setopcode,
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

  -- Memory read - COMBINATIONAL for immediate response (CRITICAL FIX!)
  mem_read: process(addr_out, busstate)
    variable addr_idx : integer;
  begin
    if busstate /= "11" then  -- Read on any non-write state
      addr_idx := to_integer(unsigned(addr_out(13 downto 1)));
      if addr_idx < 4096 then
        data_in <= mem(addr_idx);
      else
        data_in <= x"4E71";  -- NOP for out of range
      end if;
    end if;
  end process;

  -- Memory write and debug - CLOCKED
  mem_write: process(clk)
    variable addr_idx : integer;
    variable debug_count : integer := 0;
  begin
    if rising_edge(clk) then
      if clkena_in = '1' then
        addr_idx := to_integer(unsigned(addr_out(13 downto 1)));

        -- Debug: Show all busstate transitions INCLUDING WRITES
        if debug_count < 100 then
          report "MEM_IF: busstate=" & integer'image(to_integer(unsigned(busstate))) &
                 " addr=$" & integer'image(to_integer(unsigned(addr_out(15 downto 0)))) &
                 " nWr=" & std_logic'image(nWr) &
                 " FC=" & integer'image(to_integer(unsigned(FC))) &
                 " data_in=$" & integer'image(to_integer(unsigned(data_in)));
          debug_count := debug_count + 1;
        end if;

        -- Write to memory
        if busstate = "11" and nWr = '0' and addr_idx < 4096 then
          if nUDS = '0' and nLDS = '0' then
            mem(addr_idx) <= data_write;
          elsif nUDS = '0' then
            mem(addr_idx)(15 downto 8) <= data_write(15 downto 8);
          elsif nLDS = '0' then
            mem(addr_idx)(7 downto 0) <= data_write(7 downto 0);
          end if;
        end if;
      end if;
    end if;
  end process;


  -- Monitor PMMU walker activity
  pmmu_monitor: process(clk)
  begin
    if rising_edge(clk) then
      if pmmu_walker_req = '1' then
        report "PMMU WALKER REQ: addr=$" & integer'image(to_integer(unsigned(pmmu_walker_addr(15 downto 0))));
      end if;
    end if;
  end process;

  -- Track instruction execution
  track: process(clk)
  begin
    if rising_edge(clk) then
      if busstate = "00" then  -- Instruction fetch (busstate "00"=fetch, "01"=idle!)
        report "FETCH @ $" & integer'image(to_integer(unsigned(addr_out(15 downto 0)))) &
               " DATA=$" & integer'image(to_integer(unsigned(data_in))) &
               " FC=" & integer'image(to_integer(unsigned(FC))) &
               " SVmode=" & std_logic'image(debug_SVmode) &
               " SR_S=" & std_logic'image(debug_FlagsSR_S);

        case to_integer(unsigned(addr_out(15 downto 0))) is
          when 16#100# =>
            report "  -> Fetching MOVEA.L #$00001000,A0 at $100";
          when 16#106# =>
            report "  -> Fetching PMOVE TT0,(4,A0) at $106";
          when 16#10C# =>
            report "========================================";
            report "SUCCESS: PC = $10C - BUG #95 FIX WORKS!";
            report "PMOVE correctly advanced PC by 6 bytes";
            report "========================================";
            nop_executed <= true;
          when 16#10E# =>
            report "  -> Fetching BRA.S (infinite loop) at $10E - Test complete";
          when 16#110# =>
            report "========================================";
            report "FAILURE: PC = $110 - BUG #95 STILL PRESENT!";
            report "PMOVE incorrectly advanced PC by 8 bytes instead of 6";
            report "========================================";
            illegal_executed <= true;
          when 16#200# =>
            report "========================================";
            report "EXCEPTION: CPU jumped to exception handler at $200";
            report "CPU took an exception during test execution!";
            report "========================================";
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  stim_proc: process
  begin
    -- Reset CPU
    nReset <= '0';
    wait for 100 ns;

    -- Debug: Verify memory initialization
    report "MEM INIT CHECK: mem(0)=$" & integer'image(to_integer(unsigned(mem(0)))) & " (expect 0 = SSP high)";
    report "MEM INIT CHECK: mem(3)=$" & integer'image(to_integer(unsigned(mem(3)))) & " (expect 256 = PC=$100)";
    report "MEM INIT CHECK: mem(128)=$" & integer'image(to_integer(unsigned(mem(128)))) & " (expect 8316 = MOVEA.L opcode)";
    report "MEM INIT CHECK: mem(131)=$" & integer'image(to_integer(unsigned(mem(131)))) & " (expect 61480 = PMOVE TT0,(d16,A0))";
    report "MEM INIT CHECK: mem(134)=$" & integer'image(to_integer(unsigned(mem(134)))) & " (expect 20081 = NOP at $10C)";

    nReset <= '1';

    report "========================================";
    report "BUG #95 PMOVE PC INCREMENT TEST";
    report "Test program:";
    report "  $100: MOVEA.L #$1000,A0";
    report "  $106: PMOVE TT0,(4,A0)  ; 6 bytes total";
    report "  $10C: NOP               ; CORRECT (6-byte increment)";
    report "  $10E: BRA.S *           ; Success loop";
    report "  $110: ILLEGAL           ; WRONG (8-byte increment)";
    report "Expected: PC advances to $10C after PMOVE (not $110)";
    report "========================================";

    -- Wait for test completion (check flags every 100ns)
    for i in 1 to 200 loop
      wait for 100 ns;
      if nop_executed or illegal_executed then
        exit;
      end if;
    end loop;

    if nop_executed then
      report "========================================";
      report "TEST PASSED: BUG #95 FIX WORKS!";
      report "========================================";
    elsif illegal_executed then
      report "========================================";
      report "TEST FAILED: BUG #95 STILL PRESENT!";
      report "========================================";
      assert false report "BUG #95 verification failed" severity failure;
    else
      report "========================================";
      report "TEST INCONCLUSIVE: Did not reach test point";
      report "========================================";
      assert false report "Test did not complete" severity warning;
    end if;

    test_done <= true;
    wait;
  end process;

  -- PMMU register file handler - simulate register reads/writes
  pmmu_regs_handler: process(clk)
    variable reg_idx : integer;
  begin
    if rising_edge(clk) then
      reg_idx := to_integer(unsigned(pmmu_reg_sel));

      -- Handle PMMU register writes
      if pmmu_reg_we = '1' and reg_idx < 32 then
        pmmu_regs(reg_idx) <= pmmu_reg_wdat;
        report "PMMU REG WRITE: reg[" & integer'image(reg_idx) & "] = $" &
               integer'image(to_integer(unsigned(pmmu_reg_wdat)));
      end if;

      -- Handle PMMU register reads
      if pmmu_reg_re = '1' and reg_idx < 32 then
        pmmu_reg_rdat <= pmmu_regs(reg_idx);
        report "PMMU REG READ: reg[" & integer'image(reg_idx) & "] = $" &
               integer'image(to_integer(unsigned(pmmu_regs(reg_idx))));
      end if;
    end if;
  end process;

  -- PMMU walker response - immediately acknowledge with invalid descriptor
  pmmu_walker_response: process(clk)
  begin
    if rising_edge(clk) then
      if pmmu_walker_req = '1' then
        pmmu_walker_ack <= '1';
        pmmu_walker_data <= X"00000000";  -- Invalid descriptor (MMU disabled)
      else
        pmmu_walker_ack <= '0';
      end if;
    end if;
  end process;

end behavior;
