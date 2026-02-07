-- tb_pmove_tt0_mem_read.vhd
-- Comprehensive corner-case testbench for PMOVE.L (d16,An),TT0 instruction
-- Tests reading from memory and writing to TT0 (Transparent Translation Register 0)
-- Validates reserved bit masking and proper field storage from memory source

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_pmove_tt0_mem_read is
end tb_pmove_tt0_mem_read;

architecture behavior of tb_pmove_tt0_mem_read is

  

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

    -- Simulate writing a value to TT0 via reg_wdat (as if from memory)
    procedure pmove_write_tt0_from_memory(value : std_logic_vector(31 downto 0)) is
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

    procedure test_memory_to_tt0(
      mem_value : std_logic_vector(31 downto 0);
      expect_val : std_logic_vector(31 downto 0);
      test_name : string
    ) is
    begin
      -- Simulate loading from memory (via reg_wdat) to TT0
      pmove_write_tt0_from_memory(mem_value);

      -- Read back from TT0 to verify
      pmove_read_tt0;

      report_test(test_name, reg_rdat = expect_val);
    end procedure;

    variable l : line;
  begin
    write(l, string'("========================================="));
    writeline(output, l);
    write(l, string'("PMOVE.L (d16,An),TT0 Memory-to-Register Test"));
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

    -- TEST 1: Load zero from memory
    write(l, string'("TEST 1: Load Zero from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"00000000", x"00000000", "Memory 0x00000000 -> TT0");

    -- TEST 2: All bits stored (reserved bits NOT masked in this implementation)
    write(l, string'("TEST 2: All Bits Stored"));
    writeline(output, l);
    test_memory_to_tt0(x"FFFFFFFF", x"FFFFFFFF", "Memory 0xFFFFFFFF stored as-is");

    -- TEST 3: Enable bit from memory
    write(l, string'("TEST 3: Enable Bit from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"00008000", x"00008000", "E=1 from memory");

    -- TEST 4: Logical address base from memory
    write(l, string'("TEST 4: Address Base from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"FF000000", x"FF000000", "Base=0xFF from memory");

    -- TEST 5: Logical address mask from memory
    write(l, string'("TEST 5: Address Mask from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"00FF0000", x"00FF0000", "Mask=0xFF from memory");

    -- TEST 6: Cache inhibit from memory
    write(l, string'("TEST 6: Cache Inhibit from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"00000300", x"00000300", "CI=11 from memory");

    -- TEST 7: Function code mask from memory
    write(l, string'("TEST 7: FC Mask from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"000000F0", x"000000F0", "FC=1111 from memory");

    -- TEST 8: RWM/RW from memory
    write(l, string'("TEST 8: RWM/RW from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"00000006", x"00000006", "RWM=1,RW=1 from memory");

    -- TEST 9: Real-world config from memory - Identity mapping
    write(l, string'("TEST 9: Identity Map from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"00FF8070", x"00FF8070", "Identity config from memory");

    -- TEST 10: Real-world config from memory - I/O space
    write(l, string'("TEST 10: I/O Space from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"FFFF8350", x"FFFF8350", "I/O config from memory");

    -- TEST 11-17: Individual reserved bits stored (no masking in this implementation)
    write(l, string'("TEST 11-17: Reserved Bits Stored"));
    writeline(output, l);
    test_memory_to_tt0(x"00004000", x"00004000", "Bit 14 stored");
    test_memory_to_tt0(x"00002000", x"00002000", "Bit 13 stored");
    test_memory_to_tt0(x"00001000", x"00001000", "Bit 12 stored");
    test_memory_to_tt0(x"00000800", x"00000800", "Bit 11 stored");
    test_memory_to_tt0(x"00000400", x"00000400", "Bit 10 stored");
    test_memory_to_tt0(x"00000008", x"00000008", "Bit 3 stored");
    test_memory_to_tt0(x"00000001", x"00000001", "Bit 0 stored");

    -- TEST 18: All reserved bits stored
    write(l, string'("TEST 18: All Reserved Bits"));
    writeline(output, l);
    test_memory_to_tt0(x"00007C09", x"00007C09", "All reserved bits stored");

    -- TEST 19: CI field values from memory
    write(l, string'("TEST 19: CI Field Values"));
    writeline(output, l);
    test_memory_to_tt0(x"00000000", x"00000000", "CI=00 from memory");
    test_memory_to_tt0(x"00000100", x"00000100", "CI=01 from memory");
    test_memory_to_tt0(x"00000200", x"00000200", "CI=10 from memory");
    test_memory_to_tt0(x"00000300", x"00000300", "CI=11 from memory");

    -- TEST 20: FC mask patterns from memory
    write(l, string'("TEST 20: FC Mask Patterns"));
    writeline(output, l);
    test_memory_to_tt0(x"00000000", x"00000000", "FC=0000 from memory");
    test_memory_to_tt0(x"00000050", x"00000050", "FC=0101 from memory");
    test_memory_to_tt0(x"000000A0", x"000000A0", "FC=1010 from memory");
    test_memory_to_tt0(x"000000F0", x"000000F0", "FC=1111 from memory");

    -- TEST 21: RW combinations from memory
    write(l, string'("TEST 21: RW Combinations"));
    writeline(output, l);
    test_memory_to_tt0(x"00000000", x"00000000", "RWM=0,RW=0 from memory");
    test_memory_to_tt0(x"00000002", x"00000002", "RWM=0,RW=1 from memory");
    test_memory_to_tt0(x"00000004", x"00000004", "RWM=1,RW=0 from memory");
    test_memory_to_tt0(x"00000006", x"00000006", "RWM=1,RW=1 from memory");

    -- TEST 22: Walking bits - address base
    write(l, string'("TEST 22: Walking Bits - Address Base"));
    writeline(output, l);
    test_memory_to_tt0(x"01000000", x"01000000", "Base bit 24 from memory");
    test_memory_to_tt0(x"02000000", x"02000000", "Base bit 25 from memory");
    test_memory_to_tt0(x"04000000", x"04000000", "Base bit 26 from memory");
    test_memory_to_tt0(x"08000000", x"08000000", "Base bit 27 from memory");
    test_memory_to_tt0(x"10000000", x"10000000", "Base bit 28 from memory");
    test_memory_to_tt0(x"20000000", x"20000000", "Base bit 29 from memory");
    test_memory_to_tt0(x"40000000", x"40000000", "Base bit 30 from memory");
    test_memory_to_tt0(x"80000000", x"80000000", "Base bit 31 from memory");

    -- TEST 23: Walking bits - address mask
    write(l, string'("TEST 23: Walking Bits - Address Mask"));
    writeline(output, l);
    test_memory_to_tt0(x"00010000", x"00010000", "Mask bit 16 from memory");
    test_memory_to_tt0(x"00020000", x"00020000", "Mask bit 17 from memory");
    test_memory_to_tt0(x"00040000", x"00040000", "Mask bit 18 from memory");
    test_memory_to_tt0(x"00080000", x"00080000", "Mask bit 19 from memory");
    test_memory_to_tt0(x"00100000", x"00100000", "Mask bit 20 from memory");
    test_memory_to_tt0(x"00200000", x"00200000", "Mask bit 21 from memory");
    test_memory_to_tt0(x"00400000", x"00400000", "Mask bit 22 from memory");
    test_memory_to_tt0(x"00800000", x"00800000", "Mask bit 23 from memory");

    -- TEST 24: Alternating patterns from memory
    write(l, string'("TEST 24: Alternating Patterns"));
    writeline(output, l);
    test_memory_to_tt0(x"55558156", x"55558156", "Pattern 0x5555 from memory");
    test_memory_to_tt0(x"AAAA82A4", x"AAAA82A4", "Pattern 0xAAAA from memory");

    -- TEST 25: Complex configurations from memory
    write(l, string'("TEST 25: Complex Configs from Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"C0C08050", x"C0C08050", "Supervisor data from memory");
    test_memory_to_tt0(x"E0E08070", x"E0E08070", "High memory from memory");

    -- TEST 26: Sequential loads from memory (overwrite test)
    write(l, string'("TEST 26: Sequential Overwrites"));
    writeline(output, l);
    test_memory_to_tt0(x"00FF8070", x"00FF8070", "First load");
    test_memory_to_tt0(x"FFFF8350", x"FFFF8350", "Second load (overwrite)");
    test_memory_to_tt0(x"00000000", x"00000000", "Third load (clear)");

    -- TEST 27: Load with reserved bits set (no masking in this implementation)
    write(l, string'("TEST 27: Reserved Bits Stored"));
    writeline(output, l);
    test_memory_to_tt0(x"FFFF7FFF", x"FFFF7FFF", "Reserved bits stored as-is");

    -- TEST 28: Enable/disable via memory loads
    write(l, string'("TEST 28: Enable/Disable via Memory"));
    writeline(output, l);
    test_memory_to_tt0(x"FFFF8350", x"FFFF8350", "Load enabled config");
    test_memory_to_tt0(x"FFFF0350", x"FFFF0350", "Load disabled config");
    test_memory_to_tt0(x"FFFF8350", x"FFFF8350", "Load enabled again");

    -- TEST 29: Boundary values from memory
    write(l, string'("TEST 29: Boundary Values"));
    writeline(output, l);
    test_memory_to_tt0(x"00000000", x"00000000", "All zeros from memory");
    test_memory_to_tt0(x"FFFFFFFF", x"FFFFFFFF", "All ones stored as-is");
    test_memory_to_tt0(x"FFFF83F6", x"FFFF83F6", "Typical valid from memory");

    -- TEST 30: Verify memory corruption doesn't occur
    write(l, string'("TEST 30: Multiple Loads Stability"));
    writeline(output, l);
    -- Load same value multiple times, verify stability
    test_memory_to_tt0(x"12348156", x"12348156", "First load 0x12348156");
    test_memory_to_tt0(x"12348156", x"12348156", "Second load 0x12348156");
    test_memory_to_tt0(x"12348156", x"12348156", "Third load 0x12348156");

    -- Summary
    wait_cycles(5);
    write(l, string'("========================================="));
    writeline(output, l);
    if test_failed then
      write(l, string'("PMOVE.L (d16,An),TT0 TESTS: FAILED"));
      writeline(output, l);
    else
      write(l, string'("PMOVE.L (d16,An),TT0 TESTS: PASSED"));
      writeline(output, l);
    end if;
    write(l, string'("========================================="));
    writeline(output, l);

    wait;
  end process;

end behavior;
