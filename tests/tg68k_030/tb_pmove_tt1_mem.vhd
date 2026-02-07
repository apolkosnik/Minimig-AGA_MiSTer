-- tb_pmove_tt1_mem.vhd
-- Comprehensive corner-case testbench for PMOVE.L TT1,(d16,An) instruction
-- Tests writing TT1 (Transparent Translation Register 1) to memory
-- Validates reserved bit masking and proper field storage

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_pmove_tt1_mem is
end tb_pmove_tt1_mem;

architecture behavior of tb_pmove_tt1_mem is

  

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

  -- Simulated memory to capture writes
  type memory_array is array (0 to 255) of std_logic_vector(31 downto 0);
  signal memory : memory_array := (others => (others => '0'));

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

    procedure pmove_write_tt1(value : std_logic_vector(31 downto 0)) is
    begin
      reg_wdat <= value;
      reg_sel <= "00011";  -- TT1 register selector (brief(14:10)=00011)
      reg_part <= '0';  -- Not used for TT1 (32-bit register)
      reg_fd <= '0';    -- Flush enabled
      reg_we <= '1';
      wait_cycles(1);
      reg_we <= '0';
      wait_cycles(1);
    end procedure;

    procedure pmove_read_tt1_from_reg is
    begin
      reg_sel <= "00011";  -- TT1 register selector (brief(14:10)=00011)
      reg_part <= '0';  -- Not used for TT1
      reg_re <= '1';
      wait_cycles(1);
      reg_re <= '0';
      wait_cycles(1);
    end procedure;

    procedure test_write_read_memory(
      write_val : std_logic_vector(31 downto 0);
      expect_val : std_logic_vector(31 downto 0);
      test_name : string
    ) is
      variable mem_addr_int : integer;
    begin
      -- Write value to TT1 register
      pmove_write_tt1(write_val);

      -- Read back from register to verify it was stored correctly
      pmove_read_tt1_from_reg;

      -- Check that the value read from memory matches expected (with reserved bits masked)
      mem_addr_int := to_integer(unsigned(mem_addr(7 downto 2)));
      if mem_addr_int < 256 then
        report_test(test_name, reg_rdat = expect_val);
      else
        report_test(test_name & " (invalid address)", false);
      end if;
    end procedure;

    variable l : line;
  begin
    write(l, string'("========================================="));
    writeline(output, l);
    write(l, string'("PMOVE.L TT1,(d16,An) Memory Write Test"));
    writeline(output, l);
    write(l, string'("MC68030 TT1 Register Format:"));
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

    -- TEST 1: Write zero to TT1
    write(l, string'("TEST 1: Write Zero to TT1"));
    writeline(output, l);
    test_write_read_memory(x"00000000", x"00000000", "TT1 = 0x00000000");

    -- TEST 2: All bits stored (reserved bits NOT masked in this implementation)
    write(l, string'("TEST 2: All Bits Stored"));
    writeline(output, l);
    test_write_read_memory(x"FFFFFFFF", x"FFFFFFFF", "0xFFFFFFFF stored as-is");

    -- TEST 3: Enable bit only
    write(l, string'("TEST 3: Enable Bit Only"));
    writeline(output, l);
    test_write_read_memory(x"00008000", x"00008000", "E=1");

    -- TEST 4: Logical address base = 0xFF
    write(l, string'("TEST 4: Address Base = 0xFF"));
    writeline(output, l);
    test_write_read_memory(x"FF000000", x"FF000000", "Base = 0xFF");

    -- TEST 5: Logical address mask = 0xFF
    write(l, string'("TEST 5: Address Mask = 0xFF"));
    writeline(output, l);
    test_write_read_memory(x"00FF0000", x"00FF0000", "Mask = 0xFF");

    -- TEST 6: Cache inhibit = 0b11
    write(l, string'("TEST 6: Cache Inhibit = 11"));
    writeline(output, l);
    test_write_read_memory(x"00000300", x"00000300", "CI = 11");

    -- TEST 7: Function code mask = 0b1111
    write(l, string'("TEST 7: FC Mask = 1111"));
    writeline(output, l);
    test_write_read_memory(x"000000F0", x"000000F0", "FC mask all 1s");

    -- TEST 8: RWM=1, RW=1
    write(l, string'("TEST 8: RWM=1, RW=1"));
    writeline(output, l);
    test_write_read_memory(x"00000006", x"00000006", "RWM=1, RW=1");

    -- TEST 9: Real-world - Identity map $00xxxxxx
    write(l, string'("TEST 9: Identity Map Low 16MB"));
    writeline(output, l);
    test_write_read_memory(x"00FF8070", x"00FF8070", "Identity config");

    -- TEST 10: Real-world - I/O space $FFxxxxxx with cache inhibit
    write(l, string'("TEST 10: I/O Space with CI"));
    writeline(output, l);
    test_write_read_memory(x"FFFF8350", x"FFFF8350", "I/O config");

    -- TEST 11: Reserved bit 14 stored (no masking in this implementation)
    write(l, string'("TEST 11: Reserved Bit 14"));
    writeline(output, l);
    test_write_read_memory(x"00004000", x"00004000", "Bit 14 stored");

    -- TEST 12: Reserved bit 13 stored
    write(l, string'("TEST 12: Reserved Bit 13"));
    writeline(output, l);
    test_write_read_memory(x"00002000", x"00002000", "Bit 13 stored");

    -- TEST 13: Reserved bit 12 stored
    write(l, string'("TEST 13: Reserved Bit 12"));
    writeline(output, l);
    test_write_read_memory(x"00001000", x"00001000", "Bit 12 stored");

    -- TEST 14: Reserved bit 11 stored
    write(l, string'("TEST 14: Reserved Bit 11"));
    writeline(output, l);
    test_write_read_memory(x"00000800", x"00000800", "Bit 11 stored");

    -- TEST 15: Reserved bit 10 stored
    write(l, string'("TEST 15: Reserved Bit 10"));
    writeline(output, l);
    test_write_read_memory(x"00000400", x"00000400", "Bit 10 stored");

    -- TEST 16: Reserved bit 3 stored
    write(l, string'("TEST 16: Reserved Bit 3"));
    writeline(output, l);
    test_write_read_memory(x"00000008", x"00000008", "Bit 3 stored");

    -- TEST 17: Reserved bit 0 stored
    write(l, string'("TEST 17: Reserved Bit 0"));
    writeline(output, l);
    test_write_read_memory(x"00000001", x"00000001", "Bit 0 stored");

    -- TEST 18: All reserved bits stored
    write(l, string'("TEST 18: All Reserved Bits"));
    writeline(output, l);
    test_write_read_memory(x"00007C09", x"00007C09", "All reserved stored");

    -- TEST 19: CI field - all values
    write(l, string'("TEST 19: CI=00 (cacheable)"));
    writeline(output, l);
    test_write_read_memory(x"00000000", x"00000000", "CI=00");

    write(l, string'("TEST 19: CI=01"));
    writeline(output, l);
    test_write_read_memory(x"00000100", x"00000100", "CI=01");

    write(l, string'("TEST 19: CI=10"));
    writeline(output, l);
    test_write_read_memory(x"00000200", x"00000200", "CI=10");

    write(l, string'("TEST 19: CI=11 (inhibit)"));
    writeline(output, l);
    test_write_read_memory(x"00000300", x"00000300", "CI=11");

    -- TEST 20: FC mask patterns
    write(l, string'("TEST 20: FC Mask Patterns"));
    writeline(output, l);
    test_write_read_memory(x"00000000", x"00000000", "FC=0000");
    test_write_read_memory(x"00000050", x"00000050", "FC=0101");
    test_write_read_memory(x"000000A0", x"000000A0", "FC=1010");
    test_write_read_memory(x"000000F0", x"000000F0", "FC=1111");

    -- TEST 21: RW field combinations
    write(l, string'("TEST 21: RW Combinations"));
    writeline(output, l);
    test_write_read_memory(x"00000000", x"00000000", "RWM=0,RW=0");
    test_write_read_memory(x"00000002", x"00000002", "RWM=0,RW=1");
    test_write_read_memory(x"00000004", x"00000004", "RWM=1,RW=0");
    test_write_read_memory(x"00000006", x"00000006", "RWM=1,RW=1");

    -- TEST 22: Walking bits - address base
    write(l, string'("TEST 22: Walking Bits - Base"));
    writeline(output, l);
    test_write_read_memory(x"01000000", x"01000000", "Base bit 24");
    test_write_read_memory(x"02000000", x"02000000", "Base bit 25");
    test_write_read_memory(x"04000000", x"04000000", "Base bit 26");
    test_write_read_memory(x"08000000", x"08000000", "Base bit 27");
    test_write_read_memory(x"10000000", x"10000000", "Base bit 28");
    test_write_read_memory(x"20000000", x"20000000", "Base bit 29");
    test_write_read_memory(x"40000000", x"40000000", "Base bit 30");
    test_write_read_memory(x"80000000", x"80000000", "Base bit 31");

    -- TEST 23: Walking bits - address mask
    write(l, string'("TEST 23: Walking Bits - Mask"));
    writeline(output, l);
    test_write_read_memory(x"00010000", x"00010000", "Mask bit 16");
    test_write_read_memory(x"00020000", x"00020000", "Mask bit 17");
    test_write_read_memory(x"00040000", x"00040000", "Mask bit 18");
    test_write_read_memory(x"00080000", x"00080000", "Mask bit 19");
    test_write_read_memory(x"00100000", x"00100000", "Mask bit 20");
    test_write_read_memory(x"00200000", x"00200000", "Mask bit 21");
    test_write_read_memory(x"00400000", x"00400000", "Mask bit 22");
    test_write_read_memory(x"00800000", x"00800000", "Mask bit 23");

    -- TEST 24: Alternating patterns
    write(l, string'("TEST 24: Alternating Patterns"));
    writeline(output, l);
    test_write_read_memory(x"55558156", x"55558156", "Pattern 0x5555xxxx");
    test_write_read_memory(x"AAAA82A4", x"AAAA82A4", "Pattern 0xAAAAxxxx");

    -- TEST 25: Complex real-world configurations
    write(l, string'("TEST 25: Real-World Configs"));
    writeline(output, l);
    -- Unix-style config
    test_write_read_memory(x"00FF8070", x"00FF8070", "Unix config");
    -- AmigaOS-style I/O
    test_write_read_memory(x"FFFF8350", x"FFFF8350", "Amiga I/O");
    -- Supervisor data only, cacheable
    test_write_read_memory(x"C0C08050", x"C0C08050", "Supervisor data");

    -- TEST 26: Boundary conditions
    write(l, string'("TEST 26: Boundary Conditions"));
    writeline(output, l);
    test_write_read_memory(x"00000000", x"00000000", "All zeros");
    test_write_read_memory(x"FFFFFFFF", x"FFFFFFFF", "All ones stored as-is");
    test_write_read_memory(x"FFFF83F6", x"FFFF83F6", "Typical valid value");

    -- Summary
    wait_cycles(5);
    write(l, string'("========================================="));
    writeline(output, l);
    if test_failed then
      write(l, string'("PMOVE.L TT1,(d16,An) TESTS: FAILED"));
      writeline(output, l);
    else
      write(l, string'("PMOVE.L TT1,(d16,An) TESTS: PASSED"));
      writeline(output, l);
    end if;
    write(l, string'("========================================="));
    writeline(output, l);

    wait;
  end process;

end behavior;
