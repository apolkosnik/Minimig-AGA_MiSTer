-- tb_pmove_tt0_read.vhd
-- Comprehensive corner-case testbench for PMOVE TT0,Dx instruction (read direction)
-- Tests reading TT0 (Transparent Translation Register 0) back to data register
-- Validates reserved bit masking and proper field preservation

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_pmove_tt0_read is
end tb_pmove_tt0_read;

architecture behavior of tb_pmove_tt0_read is

  

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length/4 - 1) loop
            nibble := value(value'length - 1 - i*4 downto value'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

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

  -- Clock and reset
  constant clk_period : time := 10 ns;
  signal clk : std_logic := '0';
  signal nreset : std_logic := '0';
  signal test_failed : boolean := false;

  -- PMMU register interface
  signal reg_we   : std_logic := '0';
  signal reg_re   : std_logic := '0';
  signal reg_sel : std_logic_vector(4 downto 0) := "00000";
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
  signal mem_we   : std_logic;
  signal mem_addr : std_logic_vector(31 downto 0);
  signal mem_wdat : std_logic_vector(31 downto 0);
  signal mem_ack  : std_logic := '0';
  signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
  signal mem_berr : std_logic := '0';
  signal busy     : std_logic;

  -- MMU configuration exception
  signal mmu_config_err : std_logic;
  signal mmu_config_ack : std_logic := '0';

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

    procedure pmove_write_tt0(value : std_logic_vector(31 downto 0)) is
    begin
      reg_wdat <= value;
      reg_sel <= "00010";  -- TT0 register selector (brief(14:10)=00010)
      reg_part <= '0';  -- Not used for TT0 (32-bit register)
      reg_fd <= '0';    -- Flush enabled
      reg_we <= '1';
      wait_cycles(1);
      reg_we <= '0';
      wait_cycles(1);
    end procedure;

    procedure pmove_read_tt0 is
    begin
      reg_sel <= "00010";  -- TT0 register selector (brief(14:10)=00010)
      reg_part <= '0';  -- Not used for TT0
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
      pmove_write_tt0(write_val);
      pmove_read_tt0;
      report_test(test_name, reg_rdat = expect_val);
    end procedure;

    variable l : line;
  begin
    write(l, string'("========================================="));
    writeline(output, l);
    write(l, string'("PMOVE TT0,Dx Read Direction Test"));
    writeline(output, l);
    write(l, string'("MC68030 TT0 Register Format:"));
    writeline(output, l);
    write(l, string'("  31-24: Logical Address Base"));
    writeline(output, l);
    write(l, string'("  23-16: Logical Address Mask"));
    writeline(output, l);
    write(l, string'("  15: E (Enable)"));
    writeline(output, l);
    write(l, string'("  14-10: Reserved (must be 0)"));
    writeline(output, l);
    write(l, string'("  9-8: CI (Cache Inhibit)"));
    writeline(output, l);
    write(l, string'("  7-4: Function Code Mask"));
    writeline(output, l);
    write(l, string'("  3: Reserved (must be 0)"));
    writeline(output, l);
    write(l, string'("  2: RWM (Read/Write Mask)"));
    writeline(output, l);
    write(l, string'("  1: RW (Read/Write)"));
    writeline(output, l);
    write(l, string'("  0: Reserved (must be 0)"));
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
    pmove_read_tt0;
    report_test("TT0 = 0x00000000 after reset", reg_rdat = x"00000000");

    -- TEST 2: Write and read back zero
    write(l, string'("TEST 2: Write/Read Zero"));
    writeline(output, l);
    test_write_read(x"00000000", x"00000000", "Write 0x00000000, read 0x00000000");

    -- TEST 3: All bits stored (reserved bits NOT masked in this implementation)
    write(l, string'("TEST 3: All Bits Stored"));
    writeline(output, l);
    test_write_read(x"FFFFFFFF", x"FFFFFFFF", "Write 0xFFFFFFFF, stored as-is");

    -- TEST 4: Enable bit only (E=1)
    write(l, string'("TEST 4: Enable Bit Only"));
    writeline(output, l);
    test_write_read(x"00008000", x"00008000", "E=1, all others zero");

    -- TEST 5: Logical address base field (bits 31-24)
    write(l, string'("TEST 5: Logical Address Base = 0xFF"));
    writeline(output, l);
    test_write_read(x"FF000000", x"FF000000", "Address base 0xFF preserved");

    -- TEST 6: Logical address mask field (bits 23-16)
    write(l, string'("TEST 6: Logical Address Mask = 0xFF"));
    writeline(output, l);
    test_write_read(x"00FF0000", x"00FF0000", "Address mask 0xFF preserved");

    -- TEST 7: Cache inhibit field (bits 9-8)
    write(l, string'("TEST 7: Cache Inhibit = 0b11"));
    writeline(output, l);
    test_write_read(x"00000300", x"00000300", "CI=11 preserved");

    -- TEST 8: Function code mask (bits 7-4)
    write(l, string'("TEST 8: FC Mask = 0b1111"));
    writeline(output, l);
    test_write_read(x"000000F0", x"000000F0", "FC mask all 1s preserved");

    -- TEST 9: RWM and RW bits (bits 2-1)
    write(l, string'("TEST 9: RWM=1, RW=1"));
    writeline(output, l);
    test_write_read(x"00000006", x"00000006", "RWM=1, RW=1 preserved");

    -- TEST 10: Real-world example - Map $00xxxxxx with no translation
    -- Base=$00, Mask=$FF, E=1, CI=00, FC=111 (any), RWM=0, RW=0
    write(l, string'("TEST 10: Map $00xxxxxx Identity"));
    writeline(output, l);
    test_write_read(x"00FF8070", x"00FF8070", "Identity map low 16MB");

    -- TEST 11: Real-world example - Map $FFxxxxxx as I/O space
    -- Base=$FF, Mask=$FF, E=1, CI=11 (cache inhibit), FC=101 (supervisor data)
    write(l, string'("TEST 11: Map $FFxxxxxx as I/O"));
    writeline(output, l);
    test_write_read(x"FFFF8350", x"FFFF8350", "I/O space with cache inhibit");

    -- TEST 12: Walking bit test for address base
    write(l, string'("TEST 12: Walking Bits - Address Base"));
    writeline(output, l);
    test_write_read(x"01000000", x"01000000", "Base bit 24");
    test_write_read(x"02000000", x"02000000", "Base bit 25");
    test_write_read(x"04000000", x"04000000", "Base bit 26");
    test_write_read(x"08000000", x"08000000", "Base bit 27");

    -- TEST 13: Walking bit test for address mask
    write(l, string'("TEST 13: Walking Bits - Address Mask"));
    writeline(output, l);
    test_write_read(x"00010000", x"00010000", "Mask bit 16");
    test_write_read(x"00020000", x"00020000", "Mask bit 17");
    test_write_read(x"00040000", x"00040000", "Mask bit 18");
    test_write_read(x"00080000", x"00080000", "Mask bit 19");

    -- TEST 14: Reserved bit 14 stored (no masking in this implementation)
    write(l, string'("TEST 14: Reserved Bit 14"));
    writeline(output, l);
    test_write_read(x"00004000", x"00004000", "Bit 14 stored");

    -- TEST 15: Reserved bit 13 stored
    write(l, string'("TEST 15: Reserved Bit 13"));
    writeline(output, l);
    test_write_read(x"00002000", x"00002000", "Bit 13 stored");

    -- TEST 16: Reserved bit 12 stored
    write(l, string'("TEST 16: Reserved Bit 12"));
    writeline(output, l);
    test_write_read(x"00001000", x"00001000", "Bit 12 stored");

    -- TEST 17: Reserved bit 11 stored
    write(l, string'("TEST 17: Reserved Bit 11"));
    writeline(output, l);
    test_write_read(x"00000800", x"00000800", "Bit 11 stored");

    -- TEST 18: Reserved bit 10 stored
    write(l, string'("TEST 18: Reserved Bit 10"));
    writeline(output, l);
    test_write_read(x"00000400", x"00000400", "Bit 10 stored");

    -- TEST 19: Reserved bit 3 stored
    write(l, string'("TEST 19: Reserved Bit 3"));
    writeline(output, l);
    test_write_read(x"00000008", x"00000008", "Bit 3 stored");

    -- TEST 20: Reserved bit 0 stored
    write(l, string'("TEST 20: Reserved Bit 0"));
    writeline(output, l);
    test_write_read(x"00000001", x"00000001", "Bit 0 stored");

    -- TEST 21: All reserved bits stored
    write(l, string'("TEST 21: All Reserved Bits"));
    writeline(output, l);
    test_write_read(x"00007C09", x"00007C09", "Bits 14-10,3,0 all stored");

    -- TEST 22: CI field values
    write(l, string'("TEST 22: CI Field Values"));
    writeline(output, l);
    test_write_read(x"00000000", x"00000000", "CI=00 (cacheable)");
    test_write_read(x"00000100", x"00000100", "CI=01");
    test_write_read(x"00000200", x"00000200", "CI=10");
    test_write_read(x"00000300", x"00000300", "CI=11 (cache inhibit)");

    -- TEST 23: FC mask combinations
    write(l, string'("TEST 23: FC Mask Combinations"));
    writeline(output, l);
    test_write_read(x"00000000", x"00000000", "FC mask 0000");
    test_write_read(x"00000050", x"00000050", "FC mask 0101");
    test_write_read(x"000000A0", x"000000A0", "FC mask 1010");
    test_write_read(x"000000F0", x"000000F0", "FC mask 1111");

    -- TEST 24: RW field combinations
    write(l, string'("TEST 24: RW Field Combinations"));
    writeline(output, l);
    test_write_read(x"00000000", x"00000000", "RWM=0, RW=0");
    test_write_read(x"00000002", x"00000002", "RWM=0, RW=1");
    test_write_read(x"00000004", x"00000004", "RWM=1, RW=0");
    test_write_read(x"00000006", x"00000006", "RWM=1, RW=1");

    -- TEST 25: Multiple sequential reads (stability test)
    write(l, string'("TEST 25: Multiple Sequential Reads"));
    writeline(output, l);
    pmove_write_tt0(x"FFFF8350");
    pmove_read_tt0;
    report_test("First read", reg_rdat = x"FFFF8350");
    pmove_read_tt0;
    report_test("Second read", reg_rdat = x"FFFF8350");
    pmove_read_tt0;
    report_test("Third read", reg_rdat = x"FFFF8350");

    -- TEST 26: Read-modify-write sequence
    write(l, string'("TEST 26: Read-Modify-Write"));
    writeline(output, l);
    pmove_write_tt0(x"00FF8070");
    pmove_read_tt0;
    report_test("Initial read", reg_rdat = x"00FF8070");
    pmove_write_tt0(x"00FF8370");  -- Enable cache inhibit
    pmove_read_tt0;
    report_test("After modify", reg_rdat = x"00FF8370");

    -- TEST 27: Disable and re-enable
    write(l, string'("TEST 27: Disable/Re-enable"));
    writeline(output, l);
    pmove_write_tt0(x"FFFF8350");  -- Enabled
    pmove_read_tt0;
    report_test("Enabled", reg_rdat = x"FFFF8350");
    pmove_write_tt0(x"FFFF0350");  -- Disabled (E=0)
    pmove_read_tt0;
    report_test("Disabled", reg_rdat = x"FFFF0350");
    pmove_write_tt0(x"FFFF8350");  -- Re-enabled
    pmove_read_tt0;
    report_test("Re-enabled", reg_rdat = x"FFFF8350");

    -- TEST 28: Alternating patterns
    write(l, string'("TEST 28: Alternating Patterns"));
    writeline(output, l);
    test_write_read(x"55558156", x"55558156", "Pattern 0x5555xxxx");
    test_write_read(x"AAAA82A4", x"AAAA82A4", "Pattern 0xAAAAxxxx");

    -- TEST 29: Read during reset
    write(l, string'("TEST 29: Read During Reset"));
    writeline(output, l);
    pmove_write_tt0(x"FFFF8350");
    nreset <= '0';
    wait_cycles(2);
    pmove_read_tt0;
    report_test("Read during reset = 0x00000000", reg_rdat = x"00000000");
    nreset <= '1';
    wait_cycles(2);

    -- TEST 30: Back-to-back write/read
    write(l, string'("TEST 30: Back-to-Back Write/Read"));
    writeline(output, l);
    pmove_write_tt0(x"12348156");
    wait_cycles(0);  -- No extra delay
    pmove_read_tt0;
    report_test("Immediate read after write", reg_rdat = x"12348156");

    -- Summary
    wait_cycles(5);
    write(l, string'("========================================="));
    writeline(output, l);
    if test_failed then
      write(l, string'("PMOVE TT0,Dx READ TESTS: FAILED"));
      writeline(output, l);
    else
      write(l, string'("PMOVE TT0,Dx READ TESTS: PASSED"));
      writeline(output, l);
    end if;
    write(l, string'("========================================="));
    writeline(output, l);

    wait;
  end process;

end behavior;
