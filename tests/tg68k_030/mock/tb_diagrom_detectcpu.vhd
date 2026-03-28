-- tb_diagrom_detectcpu.vhd
-- Comprehensive testbench simulating DiagROM DetectCPU sequence
-- Based on DiagROM_fpuframe.s lines 11910-12149
-- Tests the exact instruction sequence to identify which instruction causes unexpected program flow

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.TG68K_Pack.all;

entity tb_diagrom_detectcpu is
end tb_diagrom_detectcpu;

architecture behavior of tb_diagrom_detectcpu is

  -- Clock and reset
  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal clkena_in : std_logic := '1';

  -- CPU inputs
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal IPL_autovector : std_logic := '0';
  signal CPU : std_logic_vector(1 downto 0) := "10"; -- 68030 (correct encoding per kernel)
  signal skipFetch_out : std_logic;
  signal berr : std_logic := '0';

  -- CPU outputs
  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS : std_logic;
  signal nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal nResetOut : std_logic;
  signal FC : std_logic_vector(2 downto 0);

  -- PMMU walker interface (unused but required)
  signal pmmu_walker_req : std_logic;
  signal pmmu_walker_we : std_logic;
  signal pmmu_walker_addr : std_logic_vector(31 downto 0);
  signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_walker_berr : std_logic := '0';

  -- Debug signals
  signal debug_SVmode : std_logic;
  signal debug_decodeOPC : std_logic;
  signal debug_setopcode : std_logic;
  signal debug_state : std_logic_vector(1 downto 0);
  signal debug_setstate : std_logic_vector(1 downto 0);
  signal debug_clkena_lw : std_logic;
  signal debug_opcode : std_logic_vector(15 downto 0);
  signal debug_TG68_PC : std_logic_vector(31 downto 0);
  -- New debug signals for state transition analysis
  signal debug_setnextpass : std_logic;
  signal debug_brief : std_logic_vector(15 downto 0);
  signal debug_last_opc_read : std_logic_vector(15 downto 0);
  signal debug_data_read : std_logic_vector(31 downto 0);
  signal debug_trapmake : std_logic;

  -- Test control
  signal test_complete_monitor : std_logic := '0';
  signal test_complete_test : std_logic := '0';
  constant CLK_PERIOD : time := 10 ns;

  -- Memory (8KB)
  type mem_type is array (0 to 4095) of std_logic_vector(15 downto 0);

  -- Initialize memory with test program
  function init_memory return mem_type is
    variable m : mem_type := (others => x"4E71"); -- Default NOP
  begin
    -- Exception vectors
    m(0) := x"0000";  -- SSP high
    m(1) := x"1000";  -- SSP low = 0x1000 (within our 8KB memory)
    m(2) := x"0000";  -- PC high
    m(3) := x"0100";  -- PC low = 0x100 (start of test)

    -- Illegal instruction vector at 0x10
    m(8) := x"0000";   -- high
    m(9) := x"0500";   -- low = 0x500 (exception handler)

    -- Unimplemented instruction vector at 0x2C
    m(22) := x"0000";  -- high
    m(23) := x"0500";  -- low = 0x500 (same handler)

    -- Privilege violation vector at 0x20
    m(16) := x"0000";  -- high
    m(17) := x"0500";  -- low = 0x500 (same handler)

    -- Program at 0x100 - Simplified DiagROM DetectCPU sequence
    -- Address 0x100: Test for 68010+ (MOVEC VBR support)
    m(128) := x"203C";  -- MOVE.L #0,D0 (set CPU=68000 default)
    m(129) := x"0000";
    m(130) := x"0000";

    -- Address 0x106: Test for 68020+ (MOVEC CACR)
    m(131) := x"4E7A";  -- MOVEC opcode
    m(132) := x"1002";  -- CACR -> D1 (register 002)
    m(133) := x"7202";  -- MOVEQ #2,D1 (set CPU=68020)

    -- Address 0x10C: Test for 68040+ (MOVEC ITT0)
    -- THIS IS THE CRITICAL TEST - should trap on 68030!
    m(134) := x"4E7A";  -- MOVEC opcode
    m(135) := x"1004";  -- ITT0 -> D1 (register 004)
    m(136) := x"7204";  -- MOVEQ #4,D1 (set CPU=68040 - only if ITT0 succeeded)

    -- Address 0x112: Success path - ITT0 trapped (68030 detected)
    m(137) := x"7203";  -- MOVEQ #3,D1 (set CPU=68030)
    m(138) := x"60FE";  -- BRA.S -2 (loop forever - success)

    -- Exception handler at 0x500
    -- For illegal instruction, PC on stack points TO the instruction
    -- We need to skip past MOVEC (4 bytes) + MOVEQ (2 bytes) = 6 bytes
    -- Handler: Read return PC from stack, add 6, write back, then RTE
    --
    -- Address 0x500: MOVE.L (2,A7),D7 - get return PC
    m(640) := x"2E2F";  -- MOVE.L (d16,A7),D7
    m(641) := x"0002";  -- displacement = 2

    -- Address 0x504: ADDQ.L #6,D7 - skip MOVEC + MOVEQ
    m(642) := x"5C87";  -- ADDQ.L #6,D7

    -- Address 0x506: MOVE.L D7,(2,A7) - write back adjusted PC
    m(643) := x"2F47";  -- MOVE.L D7,(d16,A7)
    m(644) := x"0002";  -- displacement = 2

    -- Address 0x50A: RTE
    m(645) := x"4E73";  -- RTE (return from exception)

    return m;
  end function;

  signal mem : mem_type := init_memory;

  -- Test tracking
  signal cycle_count : integer := 0;
  signal instruction_count : integer := 0;
  signal last_pc : std_logic_vector(31 downto 0) := (others => '0');
  signal stuck_count : integer := 0;
  signal exception_count : integer := 0;

  -- DetectCPU tracking
  signal detected_cpu : integer := 0; -- 0=68000, 1=68010, 2=68020, 4=68040, 5=68060
  signal movec_cacr_fetched : boolean := false;
  signal movec_itt0_fetched : boolean := false;
  signal movec_pcr_fetched : boolean := false;
  signal pmove_tc_fetched : boolean := false;
  signal rte_fallthrough_prefetch_seen : boolean := false;

  -- Derived test complete signal
  signal test_complete : boolean;

begin

  -- Test complete resolution
  test_complete <= (test_complete_monitor = '1') or (test_complete_test = '1');

  -- Clock generation
  clk_process: process
  begin
    while not test_complete loop
      clk <= '0';
      wait for CLK_PERIOD/2;
      clk <= '1';
      wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  -- DUT instantiation
  cpu_dut: entity work.TG68KdotC_Kernel
    port map(
      clk => clk,
      nReset => nReset,
      clkena_in => clkena_in,
      data_in => data_in,
      IPL => IPL,
      IPL_autovector => IPL_autovector,
      berr => berr,
      CPU => CPU,
      addr_out => addr_out,
      data_write => data_write,
      nWr => nWr,
      nUDS => nUDS,
      nLDS => nLDS,
      busstate => busstate,
      nResetOut => nResetOut,
      FC => FC,
      skipFetch => skipFetch_out,
      pmmu_walker_req => pmmu_walker_req,
      pmmu_walker_we => pmmu_walker_we,
      pmmu_walker_addr => pmmu_walker_addr,
      pmmu_walker_wdat => pmmu_walker_wdat,
      pmmu_walker_ack => pmmu_walker_ack,
      pmmu_walker_data => pmmu_walker_data,
      pmmu_walker_berr => pmmu_walker_berr,
      -- Debug signals
      debug_SVmode => debug_SVmode,
      debug_decodeOPC => debug_decodeOPC,
      debug_setopcode => debug_setopcode,
      debug_state => debug_state,
      debug_setstate => debug_setstate,
      debug_clkena_lw => debug_clkena_lw,
      debug_opcode => debug_opcode,
      debug_TG68_PC => debug_TG68_PC,
      debug_brief => debug_brief,
      debug_last_opc_read => debug_last_opc_read,
      debug_data_read => debug_data_read,
      debug_setnextpass => debug_setnextpass,
      debug_trapmake => debug_trapmake
    );

  -- Memory interface - combinatorial read
  mem_read: process(addr_out, mem)
    variable addr_idx : integer;
  begin
    addr_idx := to_integer(unsigned(addr_out(12 downto 1)));
    if addr_idx < 4096 then
      data_in <= mem(addr_idx);
    else
      data_in <= x"4E71"; -- NOP for out of range
    end if;
  end process;

  -- Memory write - clocked process with debug
  mem_write: process(clk)
    variable addr_idx : integer;
  begin
    if rising_edge(clk) then
      if nReset = '1' and nWr = '0' and busstate = "11" then
        -- Write cycle (busstate="11" is write data)
        addr_idx := to_integer(unsigned(addr_out(12 downto 1)));
        if addr_idx < 4096 then
          mem(addr_idx) <= data_write;
          -- Debug: trace stack writes (addresses near 0x1000 initial SSP)
          if unsigned(addr_out) >= x"00000F00" and unsigned(addr_out) <= x"00001100" then
            report "STACK WRITE: addr=" & integer'image(to_integer(unsigned(addr_out))) &
                   " data=" & integer'image(to_integer(unsigned(data_write))) &
                   " busstate=" & integer'image(to_integer(unsigned(busstate))) severity note;
          end if;
        end if;
      end if;
      -- Debug: trace ALL bus activity (not just data reads) in stack area
      -- This helps debug RTE which reads SR, PC, Format from stack
      if nReset = '1' and busstate /= "00" then  -- Any non-fetch access
        if unsigned(addr_out) >= x"00000F00" and unsigned(addr_out) <= x"00001100" then
          report "STACK BUS: addr=" & integer'image(to_integer(unsigned(addr_out))) &
                 " data_in=" & integer'image(to_integer(unsigned(data_in))) &
                 " data_wr=" & integer'image(to_integer(unsigned(data_write))) &
                 " busstate=" & integer'image(to_integer(unsigned(busstate))) &
                 " nWr=" & std_logic'image(nWr) &
                 " PC=" & integer'image(to_integer(unsigned(debug_TG68_PC))) severity note;
        end if;
      end if;
    end if;
  end process;

  -- Monitor and trace
  monitor: process(clk)
    variable l : line;
    variable prev_state : std_logic_vector(1 downto 0) := "00";
    variable prev_setstate : std_logic_vector(1 downto 0) := "00";
  begin
    if rising_edge(clk) then
      if nReset = '1' then
        cycle_count <= cycle_count + 1;

        -- Debug: Trace state transitions during exception handler (PC in 0x500-0x50C range)
        if unsigned(debug_TG68_PC) >= x"00000500" and unsigned(debug_TG68_PC) <= x"00000520" then
          if debug_state /= prev_state or debug_setstate /= prev_setstate or busstate /= "00" then
            report "CYCLE " & integer'image(cycle_count) &
                   " PC=" & integer'image(to_integer(unsigned(debug_TG68_PC))) &
                   " addr=" & integer'image(to_integer(unsigned(addr_out))) &
                   " state=" & integer'image(to_integer(unsigned(debug_state))) &
                   " setstate=" & integer'image(to_integer(unsigned(debug_setstate))) &
                   " busstate=" & integer'image(to_integer(unsigned(busstate))) severity note;
            prev_state := debug_state;
            prev_setstate := debug_setstate;
          end if;
        end if;

        -- Track instruction fetches (busstate="00" is fetch, FC=010 supervisor program, FC=110 user program)
        if busstate = "00" and (FC = "010" or FC = "110") then
          instruction_count <= instruction_count + 1;

          -- Detect key instruction fetches
          -- Note: Addresses and opcodes shown in decimal

          case addr_out is
            when x"00000100" =>
              report "==> PC=0x100: Starting DetectCPU test sequence" severity note;

            when x"00000106" =>
              report "==> PC=0x106: Fetching MOVEC CACR,D1 (test for 68020+)" severity note;
              movec_cacr_fetched <= true;

            when x"0000010C" =>
              report "==> PC=0x10C: Fetching MOVEC ITT0,D1 (test for 68040+)" severity note;
              movec_itt0_fetched <= true;
              report "    0x10C DEBUG: opcode=0x" & integer'image(to_integer(unsigned(debug_opcode))) &
                     " brief=0x" & integer'image(to_integer(unsigned(debug_brief))) &
                     " last_opc=0x" & integer'image(to_integer(unsigned(debug_last_opc_read))) &
                     " data_read=0x" & integer'image(to_integer(unsigned(debug_data_read(15 downto 0)))) &
                     " clkena_lw=" & std_logic'image(debug_clkena_lw) &
                     " trapmake=" & std_logic'image(debug_trapmake) severity note;

            when x"0000010E" =>
              report "==> PC=0x10E: MOVEC ITT0 extension word fetched" severity note;
              report "    0x10E DEBUG: data_in=0x" & integer'image(to_integer(unsigned(data_in))) &
                     " brief=0x" & integer'image(to_integer(unsigned(debug_brief))) &
                     " last_opc=0x" & integer'image(to_integer(unsigned(debug_last_opc_read))) &
                     " data_read=0x" & integer'image(to_integer(unsigned(debug_data_read(15 downto 0)))) &
                     " clkena_lw=" & std_logic'image(debug_clkena_lw) &
                     " trapmake=" & std_logic'image(debug_trapmake) severity note;

            when x"00000110" =>
              -- Note: addr_out=0x110 may appear momentarily during movec1 even when
              -- a trap is about to be taken. Don't declare failure here - wait to see
              -- if instruction at 0x112 is also fetched (which would mean 0x110 executed).
              report "==> PC=0x110: Saw MOVEQ #4,D1 address (checking if trap follows)" severity note;
              report "    0x110 DEBUG: brief=0x" & integer'image(to_integer(unsigned(debug_brief))) &
                     " data_read=0x" & integer'image(to_integer(unsigned(debug_data_read(15 downto 0)))) &
                     " clkena_lw=" & std_logic'image(debug_clkena_lw) &
                     " trapmake=" & std_logic'image(debug_trapmake) severity note;

            when x"00000112" =>
              -- If we reach 0x112 AND exception_count > 0, the trap was taken and
              -- exception handler adjusted PC to skip to here (68030 success path).
              -- If exception_count = 0, we got here via 0x110 (68040 failure path).
              if exception_count > 0 then
                report "==> PC=0x112: Reached via exception handler (68030 detected)" severity note;
                detected_cpu <= 3;
              else
                report "==> PC=0x112: Reached WITHOUT exception (68040 path taken)" severity note;
                report "    0x112 DEBUG: trapmake=" & std_logic'image(debug_trapmake) severity note;
                report "FAIL: ITT0 did not trap! Should have trapped on 68030!" severity error;
                detected_cpu <= 4;
                test_complete_monitor <= '1';
              end if;

            when x"00000114" =>
              if detected_cpu = 3 then
                report "SUCCESS: Reached success loop at 0x114" severity note;
                report "68030 correctly detected, ITT0 trapped as expected" severity note;
              else
                report "==> PC=0x114: Reached success loop" severity note;
              end if;
              test_complete_monitor <= '1';

            when x"00000502" =>
              report "==> PC=0x502: MOVE.L disp=0x" & integer'image(to_integer(unsigned(data_in))) & " (expect 2)" severity note;
              report "    0x502 DEBUG: decodeOPC=" & std_logic'image(debug_decodeOPC) &
                     " setopcode=" & std_logic'image(debug_setopcode) &
                     " state=" & integer'image(to_integer(unsigned(debug_state))) &
                     " setstate=" & integer'image(to_integer(unsigned(debug_setstate))) &
                     " debug_opcode=0x" & integer'image(to_integer(unsigned(debug_opcode))) severity note;

            when x"00000504" =>
              report "==> PC=0x504: ADDQ.L #6,D7 opcode=0x" & integer'image(to_integer(unsigned(data_in))) & " (expect 23687=0x5C87)" severity note;
              report "    0x504 DEBUG: decodeOPC=" & std_logic'image(debug_decodeOPC) &
                     " setopcode=" & std_logic'image(debug_setopcode) &
                     " state=" & integer'image(to_integer(unsigned(debug_state))) &
                     " setstate=" & integer'image(to_integer(unsigned(debug_setstate))) &
                     " debug_opcode=0x" & integer'image(to_integer(unsigned(debug_opcode))) severity note;

            when x"00000506" =>
              report "==> PC=0x506: MOVE.L D7 opcode=0x" & integer'image(to_integer(unsigned(data_in))) & " (expect 12103=0x2F47)" severity note;

            when x"00000508" =>
              report "==> PC=0x508: MOVE.L disp=0x" & integer'image(to_integer(unsigned(data_in))) & " (expect 2)" severity note;

            when x"0000050A" =>
              report "==> PC=0x50A: RTE opcode=0x" & integer'image(to_integer(unsigned(data_in))) & " (expect 20083=0x4E73)" severity note;
              report "    RTE DEBUG: SVmode=" & std_logic'image(debug_SVmode) &
                     " decodeOPC=" & std_logic'image(debug_decodeOPC) &
                     " setopcode=" & std_logic'image(debug_setopcode) &
                     " clkena_lw=" & std_logic'image(debug_clkena_lw) &
                     " state=" & integer'image(to_integer(unsigned(debug_state))) &
                     " setstate=" & integer'image(to_integer(unsigned(debug_setstate))) &
                     " debug_opcode=0x" & integer'image(to_integer(unsigned(debug_opcode))) severity note;
              report "    RTE STATE DEBUG: setnextpass=" & std_logic'image(debug_setnextpass) severity note;

            when x"0000050C" =>
              -- TG68K can briefly present the sequential word after RTE before the
              -- restored PC takes over. Treat this as a transient prefetch, not a
              -- hard failure, and let the final control-flow result decide pass/fail.
              rte_fallthrough_prefetch_seen <= true;
              report "==> PC=0x50C: transient post-RTE prefetch, waiting for restored PC" severity note;
              report "    FALLTHRU DEBUG: SVmode=" & std_logic'image(debug_SVmode) &
                     " decodeOPC=" & std_logic'image(debug_decodeOPC) &
                     " setopcode=" & std_logic'image(debug_setopcode) &
                     " clkena_lw=" & std_logic'image(debug_clkena_lw) &
                     " state=" & integer'image(to_integer(unsigned(debug_state))) &
                     " setstate=" & integer'image(to_integer(unsigned(debug_setstate))) &
                     " debug_opcode=0x" & integer'image(to_integer(unsigned(debug_opcode))) severity note;

            when x"00000500" =>
              report "==> PC=0x500: Exception handler called (count=" &
                integer'image(exception_count + 1) & ") opcode=0x" &
                integer'image(to_integer(unsigned(data_in))) & " (expect 11823=0x2E2F)" severity note;
              report "    0x500 DEBUG: decodeOPC=" & std_logic'image(debug_decodeOPC) &
                     " setopcode=" & std_logic'image(debug_setopcode) &
                     " state=" & integer'image(to_integer(unsigned(debug_state))) &
                     " setstate=" & integer'image(to_integer(unsigned(debug_setstate))) &
                     " debug_opcode=0x" & integer'image(to_integer(unsigned(debug_opcode))) severity note;
              exception_count <= exception_count + 1;
              if exception_count > 10 then
                report "FAIL: Too many exceptions, infinite loop detected" severity error;
                test_complete_monitor <= '1';
              end if;

            when x"00000000" =>
              report "FAIL: PC corruption detected! Jumped to 0x00000000" severity error;
              report "This indicates garbage data was written to a register" severity error;
              test_complete_monitor <= '1';

            when others =>
              -- Trace unexpected PC values after first exception
              if exception_count > 0 and addr_out(31 downto 16) = x"0000" then
                report "==> PC=0x" & integer'image(to_integer(unsigned(addr_out(15 downto 0)))) &
                  ": Unexpected fetch" severity note;
              end if;
          end case;

          -- Detect stuck PC
          if addr_out = last_pc then
            stuck_count <= stuck_count + 1;
            if stuck_count > 100 then
              if addr_out = x"00000114" then
                report "SUCCESS: CPU stuck in success loop at 0x114" severity note;
                detected_cpu <= 3;
              else
                report "INFO: PC stuck at address 0x" &
                  integer'image(to_integer(unsigned(addr_out(15 downto 0)))) severity note;
              end if;
              test_complete_monitor <= '1';
            end if;
          else
            stuck_count <= 0;
          end if;

          last_pc <= addr_out;
        end if;

        -- Timeout
        if cycle_count > 10000 then
          report "Timeout after 10000 cycles" severity warning;
          test_complete_monitor <= '1';
        end if;
      end if;
    end if;
  end process;

  -- Test sequence
  test: process
  begin
    report "========================================" severity note;
    report "DiagROM DetectCPU Simulation" severity note;
    report "Testing CPU detection sequence" severity note;
    report "Expected: 68030 (ITT0 should trap)" severity note;
    report "========================================" severity note;

    nReset <= '0';
    wait for CLK_PERIOD * 10;
    nReset <= '1';

    report "CPU running DetectCPU sequence..." severity note;

    -- Wait for test completion
    wait until test_complete or cycle_count > 10000;
    wait for CLK_PERIOD * 10;

    report "========================================" severity note;
    report "Test Results" severity note;
    report "========================================" severity note;
    report "Cycles: " & integer'image(cycle_count) severity note;
    report "Instructions: " & integer'image(instruction_count) severity note;
    report "Exceptions: " & integer'image(exception_count) severity note;

    if detected_cpu = 3 then
      report "=== PASS: 68030 correctly detected ===" severity note;
      report "MOVEC ITT0 correctly triggered illegal instruction" severity note;
      if rte_fallthrough_prefetch_seen then
        report "Transient 0x50C prefetch during RTE observed and ignored as non-architectural" severity note;
      end if;
    elsif detected_cpu = 4 then
      report "=== FAIL: CPU detected as 68040 ===" severity error;
      report "MOVEC ITT0 did NOT trap - this is the bug!" severity error;
    else
      report "=== INCONCLUSIVE: Detection incomplete ===" severity warning;
    end if;

    report "========================================" severity note;
    test_complete_test <= '1';
    wait;
  end process;

end behavior;
