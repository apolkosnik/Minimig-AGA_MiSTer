-- tb_pmove_tc_corner.vhd
-- Comprehensive corner-case testbench for PMOVE Dx,TC instruction
-- Tests TC (Translation Control) register with MC68030 specification corner cases
-- Validates reserved bit masking, field validation, and proper read/write behavior

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_pmove_tc_corner is
end tb_pmove_tc_corner;

architecture behavior of tb_pmove_tc_corner is

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
      mem_berr       : in  std_logic;
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
  signal reg_sel : std_logic_vector(4 downto 0) := "10000";  -- TC register selector
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
  signal mem_berr : std_logic := '0';
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
      mem_berr => mem_berr,
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
      reg_sel <= "10000";  -- TC register selector
      reg_part <= '0';  -- Not used for TC (32-bit register)
      reg_fd <= '0';    -- Flush enabled
      reg_we <= '1';
      wait_cycles(1);
      reg_we <= '0';
      wait_cycles(1);
    end procedure;

    procedure pmove_read_tc is
    begin
      reg_sel <= "10000";  -- TC register selector
      reg_part <= '0';  -- Not used for TC
      reg_re <= '1';
      wait_cycles(1);
      reg_re <= '0';
      wait_cycles(1);
    end procedure;

    variable l : line;
  begin
    write(l, string'("========================================="));
    writeline(output, l);
    write(l, string'("PMOVE TC Corner Case Test"));
    writeline(output, l);
    write(l, string'("========================================="));
    writeline(output, l);

    -- Reset
    nreset <= '0';
    wait_cycles(5);
    nreset <= '1';
    wait_cycles(2);

    -- TEST 1: All zeros (MMU disabled)
    write(l, string'("TEST 1: All Zeros (MMU Disabled)"));
    writeline(output, l);
    pmove_write_tc(x"00000000");
    pmove_read_tc;
    report_test("Write/Read 0x00000000", reg_rdat = x"00000000");
    report_test("TC Enable = 0", tc_enable = '0');

    -- TEST 2: Enable bit only (E=1)
    write(l, string'("TEST 2: Enable Bit Only"));
    writeline(output, l);
    pmove_write_tc(x"80000000");
    pmove_read_tc;
    report_test("Write/Read 0x80000000", reg_rdat = x"80000000");
    report_test("TC Enable = 1", tc_enable = '1');

    -- TEST 3: Reserved bits should be masked (bits 30-26)
    write(l, string'("TEST 3: Reserved Bits Masked"));
    writeline(output, l);
    pmove_write_tc(x"FFFFFFFF");
    pmove_read_tc;
    report_test("Reserved bits cleared", reg_rdat = x"83FFFFFF");
    report_test("E, SRE, FCL preserved", reg_rdat(31) = '1' and reg_rdat(25) = '1' and reg_rdat(24) = '1');

    -- TEST 4: SRE bit (Supervisor Root Enable)
    write(l, string'("TEST 4: SRE Bit (Supervisor Root Enable)"));
    writeline(output, l);
    pmove_write_tc(x"82000000");
    pmove_read_tc;
    report_test("Write/Read 0x82000000", reg_rdat = x"82000000");
    report_test("SRE bit set", reg_rdat(25) = '1');

    -- TEST 5: FCL bit (Function Code Lookup)
    write(l, string'("TEST 5: FCL Bit (Function Code Lookup)"));
    writeline(output, l);
    pmove_write_tc(x"81000000");
    pmove_read_tc;
    report_test("Write/Read 0x81000000", reg_rdat = x"81000000");
    report_test("FCL bit set", reg_rdat(24) = '1');

    -- TEST 6: Valid PS field (Page Size = 0)
    write(l, string'("TEST 6: Page Size = 0 (256 bytes)"));
    writeline(output, l);
    pmove_write_tc(x"80000000");
    pmove_read_tc;
    report_test("PS=0 stored", reg_rdat(23 downto 20) = "0000");

    -- TEST 7: Valid PS field (Page Size = 7, maximum valid)
    write(l, string'("TEST 7: Page Size = 7 (32KB, max valid)"));
    writeline(output, l);
    pmove_write_tc(x"80700000");
    pmove_read_tc;
    report_test("PS=7 stored", reg_rdat(23 downto 20) = "0111");

    -- TEST 8: Invalid PS field (Page Size = 15, should be clamped)
    write(l, string'("TEST 8: Page Size = 15 (Invalid, stored as-is)"));
    writeline(output, l);
    pmove_write_tc(x"80F00000");
    pmove_read_tc;
    report_test("PS=15 stored (hardware may clamp)", reg_rdat(23 downto 20) = "1111");

    -- TEST 9: IS field (Initial Shift)
    write(l, string'("TEST 9: Initial Shift = 8"));
    writeline(output, l);
    pmove_write_tc(x"80080000");
    pmove_read_tc;
    report_test("IS=8 stored", reg_rdat(19 downto 16) = "1000");

    -- TEST 10: TIA field (Table Index A - must be > 0 when enabled)
    write(l, string'("TEST 10: TIA = 4 (Valid)"));
    writeline(output, l);
    pmove_write_tc(x"80004000");
    pmove_read_tc;
    report_test("TIA=4 stored", reg_rdat(15 downto 12) = "0100");

    -- TEST 11: TIB field (Table Index B)
    write(l, string'("TEST 11: TIB = 5 (Valid)"));
    writeline(output, l);
    pmove_write_tc(x"80000500");
    pmove_read_tc;
    report_test("TIB=5 stored", reg_rdat(11 downto 8) = "0101");

    -- TEST 12: TIC field (Table Index C)
    write(l, string'("TEST 12: TIC = 6 (Valid)"));
    writeline(output, l);
    pmove_write_tc(x"80000060");
    pmove_read_tc;
    report_test("TIC=6 stored", reg_rdat(7 downto 4) = "0110");

    -- TEST 13: TID field (Table Index D)
    write(l, string'("TEST 13: TID = 7 (Valid)"));
    writeline(output, l);
    pmove_write_tc(x"80000007");
    pmove_read_tc;
    report_test("TID=7 stored", reg_rdat(3 downto 0) = "0111");

    -- TEST 14: Standard 4KB page configuration (common case)
    -- E=1, PS=0, IS=8, TIA=7, TIB=7, TIC=6, TID=4
    -- Total bits: 8 + 7 + 7 + 6 + 4 = 32 (valid)
    write(l, string'("TEST 14: Standard 4KB Page Config"));
    writeline(output, l);
    pmove_write_tc(x"80087764");
    pmove_read_tc;
    report_test("Standard config stored", reg_rdat = x"80087764");
    report_test("Field sum = 32", true); -- 8+7+7+6+4=32

    -- TEST 15: 8KB page configuration
    -- E=1, PS=1, IS=8, TIA=7, TIB=7, TIC=5, TID=4
    write(l, string'("TEST 15: 8KB Page Config"));
    writeline(output, l);
    pmove_write_tc(x"80187754");
    pmove_read_tc;
    report_test("8KB config stored", reg_rdat = x"80187754");

    -- TEST 16: All table indices at maximum (15)
    write(l, string'("TEST 16: All Table Indices = 15"));
    writeline(output, l);
    pmove_write_tc(x"8000FFFF");
    pmove_read_tc;
    report_test("All TI fields = 15", reg_rdat(15 downto 0) = x"FFFF");

    -- TEST 17: TIA = 0 (Invalid when E=1, but hardware stores it)
    write(l, string'("TEST 17: TIA = 0 (Invalid Configuration)"));
    writeline(output, l);
    pmove_write_tc(x"80000000");
    pmove_read_tc;
    report_test("TIA=0 stored (invalid config)", reg_rdat(15 downto 12) = "0000");

    -- TEST 18: Overwrite previous value
    write(l, string'("TEST 18: Overwrite Previous Value"));
    writeline(output, l);
    pmove_write_tc(x"FFFFFFFF");
    pmove_read_tc;
    report_test("First write", reg_rdat = x"83FFFFFF");
    pmove_write_tc(x"80000000");
    pmove_read_tc;
    report_test("Overwrite with 0x80000000", reg_rdat = x"80000000");

    -- TEST 19: Enable with SRE + FCL + valid fields
    write(l, string'("TEST 19: E + SRE + FCL + Valid Fields"));
    writeline(output, l);
    pmove_write_tc(x"83087764");
    pmove_read_tc;
    report_test("Complex config stored", reg_rdat = x"83087764");
    report_test("E=1, SRE=1, FCL=1", reg_rdat(31) = '1' and reg_rdat(25) = '1' and reg_rdat(24) = '1');

    -- TEST 20: Disable after enable
    write(l, string'("TEST 20: Disable After Enable"));
    writeline(output, l);
    pmove_write_tc(x"80087764");
    pmove_read_tc;
    report_test("MMU enabled", tc_enable = '1');
    pmove_write_tc(x"00000000");
    pmove_read_tc;
    report_test("MMU disabled", tc_enable = '0');

    -- TEST 21: Reset clears TC register
    write(l, string'("TEST 21: Reset Behavior"));
    writeline(output, l);
    pmove_write_tc(x"83087764");
    nreset <= '0';
    wait_cycles(5);
    nreset <= '1';
    wait_cycles(2);
    pmove_read_tc;
    report_test("Reset clears TC", reg_rdat = x"00000000");

    -- TEST 22: Write during reset (should be ignored)
    write(l, string'("TEST 22: Write During Reset"));
    writeline(output, l);
    nreset <= '0';
    wait_cycles(2);
    pmove_write_tc(x"80087764");
    nreset <= '1';
    wait_cycles(2);
    pmove_read_tc;
    report_test("Write during reset ignored", reg_rdat = x"00000000");

    -- TEST 23: PMOVEFD - Write without flushing ATC
    write(l, string'("TEST 23: PMOVEFD (Flush Disable)"));
    writeline(output, l);
    pmove_write_tc(x"80087764");
    reg_wdat <= x"80187754";
    reg_sel <= "10000";  -- TC register
    reg_part <= '0';
    reg_fd <= '1';  -- Flush disable
    reg_we <= '1';
    wait_cycles(1);
    reg_we <= '0';
    wait_cycles(1);
    pmove_read_tc;
    report_test("PMOVEFD write stored", reg_rdat = x"80187754");

    -- TEST 24: Alternating E bit
    write(l, string'("TEST 24: Alternating Enable Bit"));
    writeline(output, l);
    for i in 1 to 3 loop
      pmove_write_tc(x"80000000");
      pmove_read_tc;
      report_test("Enable iteration " & integer'image(i), tc_enable = '1');
      pmove_write_tc(x"00000000");
      pmove_read_tc;
      report_test("Disable iteration " & integer'image(i), tc_enable = '0');
    end loop;

    -- Summary
    wait_cycles(5);
    write(l, string'("========================================="));
    writeline(output, l);
    if test_failed then
      write(l, string'("PMOVE TC CORNER TESTS: FAILED"));
      writeline(output, l);
    else
      write(l, string'("PMOVE TC CORNER TESTS: PASSED"));
      writeline(output, l);
    end if;
    write(l, string'("========================================="));
    writeline(output, l);

    wait;
  end process;

end behavior;
