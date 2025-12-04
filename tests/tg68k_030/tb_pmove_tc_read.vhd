-- tb_pmove_tc_read.vhd
-- Comprehensive corner-case testbench for PMOVE TC,Dx instruction (read direction)
-- Tests reading TC (Translation Control) register back to data register
-- Validates that TC register reads correctly reflect written values and masking

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_pmove_tc_read is
end tb_pmove_tc_read;

architecture behavior of tb_pmove_tc_read is

  -- Component Declaration for TG68K_PMMU_030
  component TG68K_PMMU_030
    port(
      clk            : in  std_logic;
      nreset         : in  std_logic;
      reg_we         : in  std_logic;
      reg_re         : in  std_logic;
      reg_sel        : in  std_logic_vector(4 downto 0);
      reg_wdat       : in  std_logic_vector(31 downto 0);
      reg_rdat       : out std_logic_vector(31 downto 0);
      reg_part       : in  std_logic;
      reg_fd         : in  std_logic;
      ptest_req      : in  std_logic;
      pflush_req     : in  std_logic;
      pload_req      : in  std_logic;
      pmmu_fc        : in  std_logic_vector(2 downto 0);
      pmmu_addr      : in  std_logic_vector(31 downto 0);
      pmmu_brief     : in  std_logic_vector(15 downto 0);
      req            : in  std_logic;
      is_insn        : in  std_logic;
      rw             : in  std_logic;
      fc             : in  std_logic_vector(2 downto 0);
      addr_log       : in  std_logic_vector(31 downto 0);
      addr_phys      : out std_logic_vector(31 downto 0);
      cache_inhibit  : out std_logic;
      write_protect  : out std_logic;
      fault          : out std_logic;
      fault_status   : out std_logic_vector(31 downto 0);
      tc_enable      : out std_logic;
      mem_req        : buffer std_logic;
      mem_addr       : out std_logic_vector(31 downto 0);
      mem_ack        : in  std_logic;
      mem_rdat       : in  std_logic_vector(31 downto 0);
      busy           : out std_logic
    );
  end component;

  -- Clock and reset
  constant clk_period : time := 10 ns;
  signal clk : std_logic := '0';
  signal nreset : std_logic := '0';
  signal test_failed : boolean := false;

  -- PMMU register interface
  signal reg_we   : std_logic := '0';
  signal reg_re   : std_logic := '0';
  signal reg_sel : std_logic_vector(4 downto 0) := x"2";
  signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rdat : std_logic_vector(31 downto 0);
  signal reg_part : std_logic := '0';
  signal reg_fd   : std_logic := '0';

  -- PMMU instruction interface
  signal ptest_req  : std_logic := '0';
  signal pflush_req : std_logic := '0';
  signal pload_req  : std_logic := '0';
  signal pmmu_fc    : std_logic_vector(2 downto 0) := "000";
  signal pmmu_addr  : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');

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
  signal mem_req  : std_logic;
  signal mem_addr : std_logic_vector(31 downto 0);
  signal mem_ack  : std_logic := '0';
  signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
  signal busy     : std_logic;

begin

  -- Instantiate PMMU module
  uut: TG68K_PMMU_030
    port map (
      clk => clk,
      nreset => nreset,
      reg_we => reg_we,
      reg_re => reg_re,
      reg_sel => reg_sel,
      reg_wdat => reg_wdat,
      reg_rdat => reg_rdat,
      reg_part => reg_part,
      reg_fd => reg_fd,
      ptest_req => ptest_req,
      pflush_req => pflush_req,
      pload_req => pload_req,
      pmmu_fc => pmmu_fc,
      pmmu_addr => pmmu_addr,
      pmmu_brief => pmmu_brief,
      req => req,
      is_insn => is_insn,
      rw => rw,
      fc => fc,
      addr_log => addr_log,
      addr_phys => addr_phys,
      cache_inhibit => cache_inhibit,
      write_protect => write_protect,
      fault => fault,
      fault_status => fault_status,
      tc_enable => tc_enable,
      mem_req => mem_req,
      mem_addr => mem_addr,
      mem_ack => mem_ack,
      mem_rdat => mem_rdat,
      busy => busy
    );

  -- Clock generation
  clk_process: process
  begin
    clk <= '0';
    wait for clk_period/2;
    clk <= '1';
    wait for clk_period/2;
  end process;

  -- Test stimulus
  stim_proc: process
    -- Helper procedures
    procedure wait_cycles(count : integer) is
    begin
      for i in 1 to count loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure report_test(name : string; pass : boolean) is
      variable l : line;
    begin
      write(l, string'("  TEST: "));
      write(l, name);
      if pass then
        write(l, string'(" - PASS"));
      else
        write(l, string'(" - FAIL"));
        test_failed <= true;
      end if;
      writeline(output, l);
    end procedure;

    procedure pmove_write_tc(value : std_logic_vector(31 downto 0)) is
    begin
      reg_wdat <= value;
      reg_sel <= x"2";  -- TC register selector
      reg_part <= '0';  -- Not used for TC (32-bit register)
      reg_fd <= '0';    -- Flush enabled
      reg_we <= '1';
      wait_cycles(1);
      reg_we <= '0';
      wait_cycles(1);
    end procedure;

    procedure pmove_read_tc is
    begin
      reg_sel <= x"2";  -- TC register selector
      reg_part <= '0';  -- Not used for TC
      reg_re <= '1';
      wait_cycles(1);
      reg_re <= '0';
      wait_cycles(1);
    end procedure;

    procedure test_write_read(
      write_val : std_logic_vector(31 downto 0);
      expect_val : std_logic_vector(31 downto 0);
      test_name : string
    ) is
    begin
      pmove_write_tc(write_val);
      pmove_read_tc;
      report_test(test_name, reg_rdat = expect_val);
    end procedure;

    variable l : line;
  begin
    write(l, string'("========================================="));
    writeline(output, l);
    write(l, string'("PMOVE TC,Dx Read Direction Test"));
    writeline(output, l);
    write(l, string'("========================================="));
    writeline(output, l);

    -- Reset
    nreset <= '0';
    wait_cycles(5);
    nreset <= '1';
    wait_cycles(2);

    -- TEST 1: Read after reset (should be all zeros)
    write(l, string'("TEST 1: Read After Reset"));
    writeline(output, l);
    pmove_read_tc;
    report_test("TC = 0x00000000 after reset", reg_rdat = x"00000000");

    -- TEST 2: Write and read back zero
    write(l, string'("TEST 2: Write/Read Zero"));
    writeline(output, l);
    test_write_read(x"00000000", x"00000000", "Write 0x00000000, read 0x00000000");

    -- TEST 3: Write and read back enable bit only
    write(l, string'("TEST 3: Enable Bit Only"));
    writeline(output, l);
    test_write_read(x"80000000", x"80000000", "Write 0x80000000, read 0x80000000");

    -- TEST 4: Reserved bits masked on read
    write(l, string'("TEST 4: Reserved Bits Masked"));
    writeline(output, l);
    test_write_read(x"FFFFFFFF", x"83FFFFFF", "Write 0xFFFFFFFF, read 0x83FFFFFF (bits 30-26 cleared)");

    -- TEST 5: SRE bit preserved
    write(l, string'("TEST 5: SRE Bit Preserved"));
    writeline(output, l);
    test_write_read(x"82000000", x"82000000", "Write 0x82000000 (E+SRE), read back correctly");

    -- TEST 6: FCL bit preserved
    write(l, string'("TEST 6: FCL Bit Preserved"));
    writeline(output, l);
    test_write_read(x"81000000", x"81000000", "Write 0x81000000 (E+FCL), read back correctly");

    -- TEST 7: E + SRE + FCL all set
    write(l, string'("TEST 7: E + SRE + FCL"));
    writeline(output, l);
    test_write_read(x"83000000", x"83000000", "Write 0x83000000 (E+SRE+FCL), read back correctly");

    -- TEST 8: Page Size field (PS=0, 256-byte pages)
    write(l, string'("TEST 8: Page Size = 0"));
    writeline(output, l);
    test_write_read(x"80000000", x"80000000", "PS=0 preserved");

    -- TEST 9: Page Size field (PS=7, 32KB pages, max valid)
    write(l, string'("TEST 9: Page Size = 7"));
    writeline(output, l);
    test_write_read(x"80700000", x"80700000", "PS=7 preserved");

    -- TEST 10: Page Size field (PS=15, invalid but stored)
    write(l, string'("TEST 10: Page Size = 15 (Invalid)"));
    writeline(output, l);
    test_write_read(x"80F00000", x"80F00000", "PS=15 stored as-is");

    -- TEST 11: Initial Shift field (IS=8, common value)
    write(l, string'("TEST 11: Initial Shift = 8"));
    writeline(output, l);
    test_write_read(x"80080000", x"80080000", "IS=8 preserved");

    -- TEST 12: Initial Shift field (IS=15, maximum)
    write(l, string'("TEST 12: Initial Shift = 15"));
    writeline(output, l);
    test_write_read(x"800F0000", x"800F0000", "IS=15 preserved");

    -- TEST 13: TIA field (Table Index A)
    write(l, string'("TEST 13: TIA = 7"));
    writeline(output, l);
    test_write_read(x"80007000", x"80007000", "TIA=7 preserved");

    -- TEST 14: TIB field (Table Index B)
    write(l, string'("TEST 14: TIB = 7"));
    writeline(output, l);
    test_write_read(x"80000700", x"80000700", "TIB=7 preserved");

    -- TEST 15: TIC field (Table Index C)
    write(l, string'("TEST 15: TIC = 6"));
    writeline(output, l);
    test_write_read(x"80000060", x"80000060", "TIC=6 preserved");

    -- TEST 16: TID field (Table Index D)
    write(l, string'("TEST 16: TID = 4"));
    writeline(output, l);
    test_write_read(x"80000004", x"80000004", "TID=4 preserved");

    -- TEST 17: Standard 4KB page configuration (real-world example)
    -- E=1, PS=0, IS=8, TIA=7, TIB=7, TIC=6, TID=4
    write(l, string'("TEST 17: Standard 4KB Config"));
    writeline(output, l);
    test_write_read(x"80087764", x"80087764", "4KB page config preserved");

    -- TEST 18: 8KB page configuration
    -- E=1, PS=1, IS=8, TIA=7, TIB=7, TIC=5, TID=4
    write(l, string'("TEST 18: 8KB Page Config"));
    writeline(output, l);
    test_write_read(x"80187754", x"80187754", "8KB page config preserved");

    -- TEST 19: All table index fields at maximum (15)
    write(l, string'("TEST 19: All TI Fields = 15"));
    writeline(output, l);
    test_write_read(x"8000FFFF", x"8000FFFF", "All TI=15 preserved");

    -- TEST 20: Complex configuration with all control bits
    write(l, string'("TEST 20: Complex Config"));
    writeline(output, l);
    test_write_read(x"83F87764", x"83F87764", "E+SRE+FCL+PS=15+IS=8+TIA=7+TIB=7+TIC=6+TID=4");

    -- TEST 21: Multiple sequential reads (value should be stable)
    write(l, string'("TEST 21: Multiple Sequential Reads"));
    writeline(output, l);
    pmove_write_tc(x"80087764");
    pmove_read_tc;
    report_test("First read = 0x80087764", reg_rdat = x"80087764");
    pmove_read_tc;
    report_test("Second read = 0x80087764", reg_rdat = x"80087764");
    pmove_read_tc;
    report_test("Third read = 0x80087764", reg_rdat = x"80087764");

    -- TEST 22: Read-modify-write sequence
    write(l, string'("TEST 22: Read-Modify-Write Sequence"));
    writeline(output, l);
    pmove_write_tc(x"80087764");
    pmove_read_tc;
    report_test("Initial read = 0x80087764", reg_rdat = x"80087764");
    -- Modify: change to 8KB pages (PS=1)
    pmove_write_tc(x"80187764");
    pmove_read_tc;
    report_test("After modify = 0x80187764", reg_rdat = x"80187764");

    -- TEST 23: Reserved bits always read as zero (even if somehow set)
    write(l, string'("TEST 23: Reserved Bits Always Zero"));
    writeline(output, l);
    pmove_write_tc(x"FC000000");  -- Try to set reserved bits (bits 31-26)
    pmove_read_tc;
    report_test("Reserved bits cleared", reg_rdat(30 downto 26) = "00000");
    report_test("E=1 preserved, others zero", reg_rdat = x"80000000");

    -- TEST 24: Alternating patterns
    write(l, string'("TEST 24: Alternating Bit Patterns"));
    writeline(output, l);
    test_write_read(x"80555555", x"80555555", "Pattern 0x80555555");
    test_write_read(x"802AAAAA", x"802AAAAA", "Pattern 0x802AAAAA");

    -- TEST 25: Single bit walking test (verify no bit crosstalk)
    write(l, string'("TEST 25: Walking Bit Test"));
    writeline(output, l);
    test_write_read(x"80000001", x"80000001", "Bit 0 only");
    test_write_read(x"80000002", x"80000002", "Bit 1 only");
    test_write_read(x"80000004", x"80000004", "Bit 2 only");
    test_write_read(x"80000008", x"80000008", "Bit 3 only");

    -- TEST 26: Edge case - disable MMU and verify read
    write(l, string'("TEST 26: Disable MMU"));
    writeline(output, l);
    pmove_write_tc(x"80087764");  -- Enable
    pmove_read_tc;
    report_test("MMU enabled, TC=0x80087764", reg_rdat = x"80087764");
    pmove_write_tc(x"00087764");  -- Disable (E=0)
    pmove_read_tc;
    report_test("MMU disabled, TC=0x00087764", reg_rdat = x"00087764");

    -- TEST 27: Read during reset (should return zeros)
    write(l, string'("TEST 27: Read During Reset"));
    writeline(output, l);
    pmove_write_tc(x"80087764");
    nreset <= '0';
    wait_cycles(2);
    pmove_read_tc;
    report_test("Read during reset = 0x00000000", reg_rdat = x"00000000");
    nreset <= '1';
    wait_cycles(2);

    -- TEST 28: Read immediately after write (no extra delay)
    write(l, string'("TEST 28: Back-to-Back Write/Read"));
    writeline(output, l);
    pmove_write_tc(x"83087764");
    wait_cycles(0);  -- No extra delay
    pmove_read_tc;
    report_test("Immediate read after write", reg_rdat = x"83087764");

    -- TEST 29: Boundary values for all fields
    write(l, string'("TEST 29: Boundary Values"));
    writeline(output, l);
    test_write_read(x"83FFFFFF", x"83FFFFFF", "All fields at maximum");
    test_write_read(x"80000000", x"80000000", "All fields at minimum (except E)");

    -- TEST 30: Real-world MC68030 configurations
    write(l, string'("TEST 30: Real-World Configs"));
    writeline(output, l);
    -- Unix System V/68030 typical config: 4KB pages
    test_write_read(x"80087764", x"80087764", "Unix SysV config");
    -- AmigaOS 68030 config (if MMU were used): 8KB pages
    test_write_read(x"80187754", x"80187754", "AmigaOS-style config");

    -- Summary
    wait_cycles(5);
    write(l, string'("========================================="));
    writeline(output, l);
    if test_failed then
      write(l, string'("PMOVE TC,Dx READ TESTS: FAILED"));
      writeline(output, l);
    else
      write(l, string'("PMOVE TC,Dx READ TESTS: PASSED"));
      writeline(output, l);
    end if;
    write(l, string'("========================================="));
    writeline(output, l);

    wait;
  end process;

end behavior;
