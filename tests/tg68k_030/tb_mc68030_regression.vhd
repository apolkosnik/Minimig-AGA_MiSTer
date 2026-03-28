-- tb_mc68030_regression.vhd
-- MC68030 PMMU Regression Test Suite
-- Validates all critical MC68030 compatibility fixes

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_mc68030_regression is
end tb_mc68030_regression;

architecture behavior of tb_mc68030_regression is

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
      mem_we         : out std_logic;
      mem_addr       : out std_logic_vector(31 downto 0);
      mem_wdat       : out std_logic_vector(31 downto 0);
      mem_ack        : in  std_logic;
      mem_berr       : in  std_logic;
      mem_rdat       : in  std_logic_vector(31 downto 0);
      busy           : out std_logic;
      mmu_config_err : out std_logic;
      mmu_config_ack : in  std_logic
    );
  end component;

  constant clk_period : time := 10 ns;

  signal clk : std_logic := '0';
  signal nreset : std_logic := '0';
  signal reg_we : std_logic := '0';
  signal reg_re : std_logic := '0';
  signal reg_sel : std_logic_vector(4 downto 0) := (others => '0');
  signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rdat : std_logic_vector(31 downto 0);
  signal reg_part : std_logic := '0';
  signal reg_fd : std_logic := '0';
  signal ptest_req : std_logic := '0';
  signal pflush_req : std_logic := '0';
  signal pload_req : std_logic := '0';
  signal pmmu_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal pmmu_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');
  signal req : std_logic := '0';
  signal is_insn : std_logic := '0';
  signal rw : std_logic := '0';
  signal fc : std_logic_vector(2 downto 0) := (others => '0');
  signal addr_log : std_logic_vector(31 downto 0) := (others => '0');
  signal addr_phys : std_logic_vector(31 downto 0);
  signal cache_inhibit : std_logic;
  signal write_protect : std_logic;
  signal fault : std_logic;
  signal fault_status : std_logic_vector(31 downto 0);
  signal tc_enable : std_logic;
  signal mem_req : std_logic;
  signal mem_we : std_logic;
  signal mem_addr : std_logic_vector(31 downto 0);
  signal mem_wdat : std_logic_vector(31 downto 0);
  signal mem_ack : std_logic := '0';
  signal mem_berr : std_logic := '0';
  signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
  signal busy : std_logic;
  signal mmu_config_err : std_logic;
  signal mmu_config_ack : std_logic := '0';
  signal test_running : boolean := true;

begin

  uut: TG68K_PMMU_030 port map (
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
    mem_we => mem_we,
    mem_addr => mem_addr,
    mem_wdat => mem_wdat,
    mem_ack => mem_ack,
    mem_berr => mem_berr,
    mem_rdat => mem_rdat,
    busy => busy,
    mmu_config_err => mmu_config_err,
    mmu_config_ack => mmu_config_ack
  );

  clk_process :process
  begin
    while test_running loop
      clk <= '0';
      wait for clk_period/2;
      clk <= '1';
      wait for clk_period/2;
    end loop;
    wait;
  end process;

  stim_proc: process
    variable l : line;
    variable tests_passed : integer := 0;
    variable tests_failed : integer := 0;

    procedure report_test(test_name: string; passed: boolean) is
      variable ll : line;
    begin
      write(ll, string'("  "));
      write(ll, test_name);
      write(ll, string'(": "));
      if passed then
        write(ll, string'("PASS"));
        tests_passed := tests_passed + 1;
      else
        write(ll, string'("FAIL"));
        tests_failed := tests_failed + 1;
      end if;
      writeline(output, ll);
    end procedure;

  begin
    write(l, string'("========================================"));
    writeline(output, l);
    write(l, string'("MC68030 PMMU REGRESSION TEST SUITE"));
    writeline(output, l);
    write(l, string'("========================================"));
    writeline(output, l);

    wait for clk_period;
    nreset <= '1';
    wait for clk_period * 2;

    write(l, string'(""));
    writeline(output, l);
    write(l, string'("TEST GROUP 1: Register Access"));
    writeline(output, l);

    reg_sel <= "10000";
    reg_wdat <= x"03808000";
    reg_we <= '1';
    wait for clk_period;
    reg_we <= '0';
    wait for clk_period;
    reg_re <= '1';
    wait for clk_period;
    report_test("TC Write/Read", reg_rdat(25 downto 24) = "11");
    reg_re <= '0';
    wait for clk_period;

    reg_sel <= "00010";
    reg_wdat <= x"FF008777";
    reg_we <= '1';
    wait for clk_period;
    reg_we <= '0';
    wait for clk_period;
    reg_re <= '1';
    wait for clk_period;
    report_test("TT0 Write/Read", reg_rdat(31 downto 16) = x"FF00" and reg_rdat(15) = '1');
    reg_re <= '0';
    wait for clk_period;

    reg_sel <= "00011";
    reg_wdat <= x"AA008777";
    reg_we <= '1';
    wait for clk_period;
    reg_we <= '0';
    wait for clk_period;
    reg_re <= '1';
    wait for clk_period;
    report_test("TT1 Write/Read", reg_rdat(31 downto 16) = x"AA00" and reg_rdat(15) = '1');
    reg_re <= '0';
    wait for clk_period;

    reg_sel <= "10011";
    reg_wdat <= x"00000003";
    reg_part <= '1';
    reg_we <= '1';
    wait for clk_period;
    reg_we <= '0';
    wait for clk_period;
    reg_wdat <= x"12345670";
    reg_part <= '0';
    reg_we <= '1';
    wait for clk_period;
    reg_we <= '0';
    wait for clk_period;
    reg_re <= '1';
    reg_part <= '1';
    wait for clk_period;
    report_test("CRP High Write/Read", reg_rdat(1 downto 0) = "11");
    reg_part <= '0';
    wait for clk_period;
    report_test("CRP Low Write/Read", reg_rdat(31 downto 4) = x"1234567");
    reg_re <= '0';
    wait for clk_period;

    write(l, string'(""));
    writeline(output, l);
    write(l, string'("TEST GROUP 2: Translation"));
    writeline(output, l);

    addr_log <= x"12345678";
    fc <= "101";
    req <= '1';
    wait for clk_period;
    report_test("Identity Translation", addr_phys = x"12345678" and fault = '0');
    req <= '0';
    wait for clk_period;

    write(l, string'(""));
    writeline(output, l);
    write(l, string'("TEST GROUP 3: PMMU Instructions"));
    writeline(output, l);

    ptest_req <= '1';
    pmmu_fc <= "101";
    pmmu_addr <= x"AAAA5555";
    wait for clk_period * 2;
    ptest_req <= '0';
    report_test("PTEST Execution", fault = '0');
    wait for clk_period;

    pmmu_brief <= x"2400";  -- PFLUSHA
    pflush_req <= '1';
    pmmu_fc <= "101";
    pmmu_addr <= x"BBBB6666";
    wait for clk_period * 2;
    pflush_req <= '0';
    pmmu_brief <= (others => '0');
    report_test("PFLUSH Execution", fault = '0');
    wait for clk_period;

    write(l, string'(""));
    writeline(output, l);
    write(l, string'("========================================"));
    writeline(output, l);
    write(l, string'("REGRESSION TEST SUMMARY"));
    writeline(output, l);
    write(l, string'("========================================"));
    writeline(output, l);
    write(l, string'("Tests Passed: "));
    write(l, tests_passed);
    writeline(output, l);
    write(l, string'("Tests Failed: "));
    write(l, tests_failed);
    writeline(output, l);

    if tests_failed = 0 then
      write(l, string'(""));
      writeline(output, l);
      write(l, string'("ALL REGRESSION TESTS PASSED"));
      writeline(output, l);
    else
      write(l, string'(""));
      writeline(output, l);
      write(l, string'("REGRESSION FAILURES DETECTED"));
      writeline(output, l);
    end if;

    test_running <= false;
    wait;
  end process;

end behavior;
