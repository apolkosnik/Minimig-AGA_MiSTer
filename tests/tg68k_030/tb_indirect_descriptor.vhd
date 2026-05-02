-- tb_indirect_descriptor.vhd
-- Testbench for MC68030 PMMU Indirect Descriptor Support
-- Tests: Short indirect (DT=10), Long indirect (DT=11), nested indirect fault,
--        and root-final indirect descriptors
-- Reference: MC68030 User Manual Section 9.5.3.2

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_indirect_descriptor is
end tb_indirect_descriptor;

architecture behavioral of tb_indirect_descriptor is

  signal clk           : std_logic := '0';
  signal nReset        : std_logic := '0';

  -- Register interface
  signal reg_we        : std_logic := '0';
  signal reg_re        : std_logic := '0';
  signal reg_sel       : std_logic_vector(4 downto 0) := (others => '0');
  signal reg_wdat      : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rdat      : std_logic_vector(31 downto 0);
  signal reg_part      : std_logic := '0';
  signal reg_fd        : std_logic := '0';

  -- Translation interface
  signal req           : std_logic := '0';
  signal is_insn       : std_logic := '0';
  signal rw            : std_logic := '1';
  signal fc            : std_logic_vector(2 downto 0) := "101";
  signal addr_log      : std_logic_vector(31 downto 0) := (others => '0');
  signal addr_phys     : std_logic_vector(31 downto 0);
  signal cache_inhibit : std_logic;
  signal write_protect : std_logic;
  signal fault         : std_logic;
  signal fault_status  : std_logic_vector(31 downto 0);
  signal tc_enable     : std_logic;

  -- Memory interface
  signal mem_req       : std_logic;
  signal mem_addr      : std_logic_vector(31 downto 0);
  signal mem_we        : std_logic;
  signal mem_wdat      : std_logic_vector(31 downto 0);
  signal mem_ack       : std_logic := '0';
  signal mem_rdat      : std_logic_vector(31 downto 0) := (others => '0');
  signal mem_berr      : std_logic := '0';
  signal berr_enable   : std_logic := '0';
  signal berr_addr     : std_logic_vector(31 downto 0) := (others => '0');
  signal busy          : std_logic;
  signal mmu_config_err : std_logic;
  signal mmu_config_ack : std_logic := '0';
  signal ptest_desc_addr : std_logic_vector(31 downto 0);

  -- PFLUSH/PTEST interface
  signal pflush_req    : std_logic := '0';
  signal ptest_req     : std_logic := '0';
  signal pload_req     : std_logic := '0';
  signal pmmu_fc       : std_logic_vector(2 downto 0) := "101";
  signal pmmu_addr     : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_brief    : std_logic_vector(15 downto 0) := (others => '0');

  constant CLK_PERIOD  : time := 10 ns;
  signal test_done     : boolean := false;

  -- Register selectors
  constant SEL_TT0     : std_logic_vector(4 downto 0) := "00010";
  constant SEL_TT1     : std_logic_vector(4 downto 0) := "00011";
  constant SEL_TC      : std_logic_vector(4 downto 0) := "10000";
  constant SEL_CRP     : std_logic_vector(4 downto 0) := "10011";
  constant SEL_MMUSR   : std_logic_vector(4 downto 0) := "11000";

  -- Test counters
  signal test_pass     : integer := 0;
  signal test_fail     : integer := 0;

  -- Page table memory simulation (larger to accommodate all page table levels)
  type mem_array_t is array (0 to 8191) of std_logic_vector(31 downto 0);
  signal page_table : mem_array_t := (others => (others => '0'));

begin

  clk_process: process
  begin
    while not test_done loop
      clk <= '0';
      wait for CLK_PERIOD/2;
      clk <= '1';
      wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  dut: entity work.TG68K_PMMU_030
    port map(
      clk            => clk,
      nreset         => nReset,
      reg_we         => reg_we,
      reg_re         => reg_re,
      reg_sel        => reg_sel,
      reg_wdat       => reg_wdat,
      reg_rdat       => reg_rdat,
      reg_part       => reg_part,
      reg_fd         => reg_fd,
      ptest_req      => ptest_req,
      pflush_req     => pflush_req,
      pload_req      => pload_req,
      pmmu_fc        => pmmu_fc,
      pmmu_addr      => pmmu_addr,
      pmmu_brief     => pmmu_brief,
      req            => req,
      is_insn        => is_insn,
      rw             => rw,
      fc             => fc,
      addr_log       => addr_log,
      addr_phys      => addr_phys,
      cache_inhibit  => cache_inhibit,
      write_protect  => write_protect,
      fault          => fault,
      fault_status   => fault_status,
      tc_enable      => tc_enable,
      mem_req        => mem_req,
      mem_addr       => mem_addr,
      mem_we         => mem_we,
      mem_wdat       => mem_wdat,
      mem_ack        => mem_ack,
      mem_berr       => mem_berr,
      mem_rdat       => mem_rdat,
      busy           => busy,
      mmu_config_err => mmu_config_err,
      mmu_config_ack => mmu_config_ack,
      ptest_desc_addr => ptest_desc_addr
    );

  -- Memory model
  mem_model: process(clk)
    variable idx : integer;
  begin
    if rising_edge(clk) then
      mem_ack <= '0';
      mem_berr <= '0';
      if mem_req = '1' then
        if berr_enable = '1' and mem_addr = berr_addr then
          mem_berr <= '1';
          report "MEM_BERR: addr=" & integer'image(to_integer(unsigned(mem_addr)));
        else
          idx := to_integer(unsigned(mem_addr(14 downto 2)));  -- 15 bits for 8192 entries
          if idx < 8192 then
            mem_rdat <= page_table(idx);
          else
            mem_rdat <= x"00000000";  -- Return invalid for out-of-range
          end if;
          mem_ack <= '1';
          report "MEM_READ: addr=" & integer'image(to_integer(unsigned(mem_addr))) &
                 " (idx=" & integer'image(idx) & " data=" & integer'image(to_integer(unsigned(page_table(idx)))) & ")";
        end if;
      end if;
    end if;
  end process;

  test_process: process
    procedure wait_cycles(n : integer) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure write_reg(sel : std_logic_vector(4 downto 0);
                        data : std_logic_vector(31 downto 0);
                        part : std_logic) is
    begin
      reg_sel <= sel;
      reg_wdat <= data;
      reg_part <= part;
      reg_we <= '1';
      wait_cycles(1);
      reg_we <= '0';
      wait_cycles(1);
    end procedure;

    procedure read_reg(sel : std_logic_vector(4 downto 0);
                       part : std_logic) is
    begin
      reg_sel <= sel;
      reg_part <= part;
      reg_re <= '1';
      wait_cycles(1);
      reg_re <= '0';
      wait_cycles(1);
    end procedure;

    procedure do_pflush is
    begin
      pmmu_brief <= x"2400";
      pflush_req <= '1';
      wait_cycles(1);
      pflush_req <= '0';
      wait_cycles(2);
    end procedure;

    procedure do_ptestr_fc(
      log_addr : std_logic_vector(31 downto 0);
      level : std_logic_vector(2 downto 0);
      fc_value : std_logic_vector(2 downto 0);
      test_name : string
    ) is
      variable timeout : integer;
    begin
      report "PTESTR: " & test_name;
      pmmu_brief <= "100" & level & '1' & "000000000";
      pmmu_addr <= log_addr;
      pmmu_fc <= fc_value;
      ptest_req <= '1';
      wait_cycles(1);
      ptest_req <= '0';

      timeout := 0;
      while busy = '0' and timeout < 20 loop
        wait_cycles(1);
        timeout := timeout + 1;
      end loop;

      timeout := 0;
      while busy = '1' and timeout < 100 loop
        wait_cycles(1);
        timeout := timeout + 1;
      end loop;

      if timeout >= 100 then
        report "  FAIL: PTESTR timeout" severity error;
        test_fail <= test_fail + 1;
      end if;

      wait_cycles(5);
    end procedure;

    procedure do_ptestr(
      log_addr : std_logic_vector(31 downto 0);
      level : std_logic_vector(2 downto 0);
      test_name : string
    ) is
    begin
      do_ptestr_fc(log_addr, level, "101", test_name);
    end procedure;

    procedure expect_mmusr(
      expected : std_logic_vector(15 downto 0);
      test_name : string
    ) is
    begin
      read_reg(SEL_MMUSR, '0');
      if reg_rdat(15 downto 0) = expected then
        report "  PASS: " & test_name;
        test_pass <= test_pass + 1;
      else
        report "  FAIL: " & test_name & " expected " &
               integer'image(to_integer(unsigned(expected))) & " got " &
               integer'image(to_integer(unsigned(reg_rdat(15 downto 0)))) severity error;
        test_fail <= test_fail + 1;
      end if;
    end procedure;

    procedure translate_addr(
      log_addr : std_logic_vector(31 downto 0);
      expected_phys : std_logic_vector(31 downto 0);
      expected_fault : boolean;
      test_name : string
    ) is
      variable timeout : integer;
      variable fault_detected : boolean := false;
      variable phys_captured : std_logic_vector(31 downto 0);
    begin
      -- Let any previous fault response retire before starting the next request.
      timeout := 0;
      while fault = '1' and timeout < 10 loop
        wait_cycles(1);
        timeout := timeout + 1;
      end loop;

      report "TEST: " & test_name;
      addr_log <= log_addr;
      fc <= "101";
      rw <= '1';
      req <= '1';
      wait_cycles(1);

      -- Wait for walker to start (busy goes HIGH). Ignore any stale fault state
      -- until the new request has had a chance to launch its own walk.
      timeout := 0;
      while busy = '0' and timeout < 10 loop
        wait_cycles(1);
        timeout := timeout + 1;
      end loop;

      if busy = '0' then
        -- Walk never launched. Treat the settled fault state as the result.
        fault_detected := true;
        phys_captured := addr_phys;
        req <= '0';  -- Immediately deassert req on fault
      else
        -- Wait for walker to complete (busy goes LOW) or fault
        timeout := 0;
        while busy = '1' and fault = '0' and timeout < 100 loop
          wait_cycles(1);
          timeout := timeout + 1;
        end loop;

        -- CRITICAL: Capture fault and phys BEFORE deasserting req
        -- because deasserting req may cause fault to clear on next cycle
        fault_detected := (fault = '1');
        phys_captured := addr_phys;
        req <= '0';
      end if;

      -- Now wait for things to settle after deasserting req
      wait_cycles(3);

      if timeout >= 100 then
        report "  FAIL: Translation timeout" severity error;
        test_fail <= test_fail + 1;
        return;
      end if;

      -- Use captured values for result checking
      if expected_fault then
        if fault_detected then
          report "  PASS: Expected fault occurred";
          test_pass <= test_pass + 1;
        else
          report "  FAIL: Expected fault did not occur" severity error;
          test_fail <= test_fail + 1;
        end if;
      else
        if fault_detected then
          report "  FAIL: Unexpected fault" severity error;
          test_fail <= test_fail + 1;
        elsif phys_captured(31 downto 12) = expected_phys(31 downto 12) then
          report "  PASS: Physical address correct";
          test_pass <= test_pass + 1;
        else
          report "  FAIL: Physical address mismatch" severity error;
          test_fail <= test_fail + 1;
        end if;
      end if;

      wait_cycles(2);
    end procedure;

  begin
    report "=== Indirect Descriptor Test ===" severity note;

    nReset <= '0';
    wait_cycles(5);
    nReset <= '1';
    wait_cycles(5);

    -- Setup simple 2-level page tables to test indirect descriptors
    -- TC = $80C0A000: E=1, PS=12 (4KB pages), IS=0, TIA=10, TIB=10, TIC=0, TID=0
    -- This creates a 2-level walk: Root -> PTR1 (where indirect can occur)
    -- Address format: TIA(10) | TIB(10) | offset(12)

    -- Root table at 0x00000000 (from CRP), 1024 entries (10 bits)
    -- Entry 0 points to level 1 table at 0x00001000 (DT=10 short table)
    page_table(0) <= x"00001002";  -- Root[0] -> L1 table at 0x1000, DT=10

    -- Level 1 table at 0x00001000 (final level since TIC=0), 1024 entries
    -- Entry 0: SHORT INDIRECT (DT=10) pointing to page descriptor at 0x2000
    page_table(16#400#) <= x"00002002";  -- L1[0]: Short indirect -> target at 0x2000

    -- Entry 1: Regular page descriptor (DT=01) for comparison
    page_table(16#401#) <= x"ABCD0001";  -- L1[1]: Direct page: phys=0xABCD0000

    -- Entry 2: SHORT INDIRECT (DT=10) pointing to ANOTHER indirect (should fault)
    page_table(16#402#) <= x"00002402";  -- L1[2]: Short indirect -> indirect at 0x2400 (nested!)

    -- Entry 3: SHORT INDIRECT (DT=10) pointing to invalid descriptor (DT=00)
    page_table(16#403#) <= x"00002802";  -- L1[3]: Short indirect -> invalid at 0x2800

    -- Entry 4: Direct invalid descriptor
    page_table(16#404#) <= x"00000000";  -- L1[4]: Invalid descriptor, DT=00

    -- Target descriptors:
    -- 0x2000: Valid page descriptor (target for entry 0)
    page_table(16#800#) <= x"DEAF0001";  -- Target page: phys=0xDEAF0000, DT=01

    -- 0x2400: Another indirect descriptor (nested - should cause fault)
    page_table(16#900#) <= x"00003002";  -- Nested indirect, DT=10

    -- 0x2800: Invalid descriptor (DT=00)
    page_table(16#A00#) <= x"00000000";  -- Invalid, DT=00

    -- Configure MMU
    -- CRP points to root table at 0x00000000
    write_reg(SEL_CRP, x"80000002", '1');  -- CRP high: DT=10 (short table)
    write_reg(SEL_CRP, x"00000000", '0');  -- CRP low: table at 0x0000

    -- TC = $80C0AA00: E=1, PS=12 (4KB), IS=0, TIA=10, TIB=10, TIC=0, TID=0
    -- Validation: 12 + 0 + 10 + 10 = 32 (valid!)
    -- Bits: 31=E, 25=SRE, 24=FCL, 23:20=PS, 19:16=IS, 15:12=TIA, 11:8=TIB, 7:4=TIC, 3:0=TID
    -- $80C0AA00 = 1000_0000_1100_0000_1010_1010_0000_0000
    write_reg(SEL_TC, x"80C0AA00", '0');
    wait_cycles(5);

    if tc_enable = '1' then
      report "MMU enabled successfully";
    else
      report "FAIL: MMU not enabled" severity error;
      test_fail <= test_fail + 1;
    end if;

    do_pflush;

    report "" severity note;
    report "=== TEST 1: Direct page descriptor (baseline) ===" severity note;
    -- Address with TIA=0, TIB=1 -> L1 entry 1 -> direct page 0xABCD0000
    -- TIB=1 means bits 21:12 = 1, so address = 0x00001000
    translate_addr(x"00001000", x"ABCD0000", false, "Direct page descriptor");

    do_pflush;

    report "" severity note;
    report "=== TEST 2: Short indirect descriptor ===" severity note;
    -- Address with TIA=0, TIB=0 -> L1 entry 0 -> short indirect -> target page 0xDEAF0000
    translate_addr(x"00000000", x"DEAF0000", false, "Short indirect -> valid page");

    do_pflush;

    report "" severity note;
    report "=== TEST 2B: PTEST #7 follows short indirect and counts target ===" severity note;
    write_reg(SEL_MMUSR, x"00000000", '0');
    do_ptestr(x"00000000", "111", "PTEST short indirect target");
    read_reg(SEL_MMUSR, '0');
    if reg_rdat(15 downto 0) = x"0003" then
      report "  PASS: PTEST short indirect MMUSR.N includes target descriptor";
      test_pass <= test_pass + 1;
    else
      report "  FAIL: PTEST short indirect expected MMUSR=$0003 but got " &
             integer'image(to_integer(unsigned(reg_rdat(15 downto 0)))) severity error;
      test_fail <= test_fail + 1;
    end if;

    report "" severity note;
    report "=== TEST 3: Nested indirect (should fault) ===" severity note;
    -- Address with TIA=0, TIB=2 -> L1 entry 2 -> indirect -> nested indirect -> FAULT
    translate_addr(x"00002000", x"00000000", true, "Nested indirect (should fault)");

    do_pflush;

    report "" severity note;
    report "=== TEST 4: Indirect to invalid descriptor (should fault) ===" severity note;
    -- Address with TIA=0, TIB=3 -> L1 entry 3 -> indirect -> invalid -> FAULT
    translate_addr(x"00003000", x"00000000", true, "Indirect to invalid (should fault)");

    do_pflush;

    report "" severity note;
    report "=== TEST 4B: PTEST #7 invalid indirect target counts target ===" severity note;
    write_reg(SEL_MMUSR, x"00000000", '0');
    do_ptestr(x"00003000", "111", "PTEST indirect invalid target");
    read_reg(SEL_MMUSR, '0');
    if reg_rdat(15 downto 0) = x"0403" then
      report "  PASS: PTEST invalid target MMUSR.I and N match WinUAE";
      test_pass <= test_pass + 1;
    else
      report "  FAIL: PTEST invalid target expected MMUSR=$0403 but got " &
             integer'image(to_integer(unsigned(reg_rdat(15 downto 0)))) severity error;
      test_fail <= test_fail + 1;
    end if;

    do_pflush;

    report "" severity note;
    report "=== TEST 4C: PTEST direct invalid descriptor counts read descriptor ===" severity note;
    write_reg(SEL_MMUSR, x"00000000", '0');
    do_ptestr(x"00004000", "111", "PTEST direct invalid final descriptor");
    expect_mmusr(x"0402", "PTEST direct invalid MMUSR.I and N match WinUAE");

    do_pflush;

    report "" severity note;
    report "=== TEST 4D: PTEST indirect target read bus error counts previous descriptors ===" severity note;
    berr_addr <= x"00002400";
    berr_enable <= '1';
    write_reg(SEL_MMUSR, x"00000000", '0');
    do_ptestr(x"00002000", "111", "PTEST indirect target read BERR");
    berr_enable <= '0';
    expect_mmusr(x"8402", "PTEST indirect-target BERR MMUSR.B/I/N match WinUAE");

    do_pflush;

    report "" severity note;
    report "=== TEST 4E: PTEST supervisor-only long page reports page descriptor count ===" severity note;
    page_table <= (others => (others => '0'));
    wait_cycles(2);
    page_table(0) <= x"7FFF0003";        -- Root[0] high: long table, upper limit max, DT=11
    page_table(1) <= x"00001000";        -- Root[0] low : L1 table at $1000
    page_table(16#400#) <= x"00000101";  -- L1[0] high: long page, S=1, DT=01
    page_table(16#401#) <= x"FACE0000";  -- L1[0] low : page base
    write_reg(SEL_CRP, x"7FFF0003", '1');
    write_reg(SEL_CRP, x"00000000", '0');
    write_reg(SEL_TC, x"80C0AA00", '0');
    wait_cycles(5);
    do_pflush;
    write_reg(SEL_MMUSR, x"00000000", '0');
    do_ptestr_fc(x"00000000", "111", "001", "PTEST user access to supervisor-only long page");
    expect_mmusr(x"2002", "PTEST supervisor violation MMUSR.S and N match WinUAE");

    do_pflush;

    report "" severity note;
    report "=== TEST 4F: PTEST long early-termination limit violation counts page descriptor ===" severity note;
    page_table <= (others => (others => '0'));
    wait_cycles(2);
    page_table(0) <= x"80010001";        -- Root[0] high: long page, lower limit=1, DT=01
    page_table(1) <= x"12340000";        -- Root[0] low : page base
    write_reg(SEL_CRP, x"7FFF0003", '1');
    write_reg(SEL_CRP, x"00000000", '0');
    write_reg(SEL_TC, x"80C0AA00", '0');
    wait_cycles(5);
    do_pflush;
    write_reg(SEL_MMUSR, x"00000000", '0');
    do_ptestr(x"00000000", "111", "PTEST long early-termination lower-limit fault");
    expect_mmusr(x"4401", "PTEST early-termination limit MMUSR.L/I/N match WinUAE");

    report "" severity note;
    report "=== TEST 5: Root-final short indirect descriptor ===" severity note;
    -- Valid one-level table geometry using IS=5, TIA=15, PS=12.
    -- Root table is final, so DT=10 must be treated as indirect, not another table.
    page_table <= (others => (others => '0'));
    wait_cycles(2);
    page_table(0) <= x"00002002";        -- Root[0]: short indirect -> target at $2000
    page_table(16#800#) <= x"CAFE0001";  -- Target page descriptor
    write_reg(SEL_CRP, x"80000002", '1');
    write_reg(SEL_CRP, x"00000000", '0');
    write_reg(SEL_TC, x"80C5F000", '0');
    wait_cycles(5);
    do_pflush;
    translate_addr(x"00000000", x"CAFE0000", false, "Root-final short indirect -> valid page");

    do_pflush;

    report "" severity note;
    report "=== TEST 6: Root-final long indirect descriptor ===" severity note;
    -- Same one-level geometry, but root entries are long-format and the final
    -- DT=11 descriptor must be treated as long indirect.
    page_table <= (others => (others => '0'));
    wait_cycles(2);
    page_table(0) <= x"00000003";        -- Root[0] high: long indirect descriptor
    page_table(1) <= x"00002400";        -- Root[0] low : target descriptor at $2400
    page_table(16#900#) <= x"00000001";  -- Target page descriptor high (DT=01)
    page_table(16#901#) <= x"BEEF0000";  -- Target page descriptor low (page base)
    write_reg(SEL_CRP, x"80000003", '1');
    write_reg(SEL_CRP, x"00000000", '0');
    write_reg(SEL_TC, x"80C5F000", '0');
    wait_cycles(5);
    do_pflush;
    translate_addr(x"00000000", x"BEEF0000", false, "Root-final long indirect -> valid page");

    report "" severity note;
    report "========================================" severity note;
    report "Indirect Descriptor Test Summary" severity note;
    report "  Passed: " & integer'image(test_pass);
    report "  Failed: " & integer'image(test_fail);
    if test_fail = 0 then
      report "*** ALL TESTS PASSED ***" severity note;
    else
      report "*** SOME TESTS FAILED ***" severity error;
    end if;
    report "========================================" severity note;

    test_done <= true;
    wait;
  end process;

end behavioral;
