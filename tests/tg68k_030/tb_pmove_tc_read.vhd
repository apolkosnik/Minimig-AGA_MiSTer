-- tb_pmove_tc_read.vhd
-- Comprehensive corner-case testbench for PMOVE TC,Dx instruction (read direction)
-- Tests reading TC (Translation Control) register back to data register
-- Validates that TC register reads correctly reflect written values
--
-- MC68030 TC Register format (32 bits):
--   Bit 31: E (Enable)
--   Bits 30-26: Reserved (must be 0)
--   Bit 25: SRE (Supervisor Root Enable)
--   Bit 24: FCL (Function Code Lookup)
--   Bits 23-20: PS (Page Size) - MUST be 8-15 for valid config when E=1
--   Bits 19-16: IS (Initial Shift)
--   Bits 15-12: TIA (Table Index A)
--   Bits 11-8: TIB (Table Index B)
--   Bits 7-4: TIC (Table Index C)
--   Bits 3-0: TID (Table Index D)
--
-- Valid configuration: IS + TIA + TIB + TIC + TID + PS = 32
-- PS values: 8=256B, 9=512B, 10=1KB, 11=2KB, 12=4KB, 13=8KB, 14=16KB, 15=32KB

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_pmove_tc_read is
end tb_pmove_tc_read;

architecture behavior of tb_pmove_tc_read is

  

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
      mem_addr       : out std_logic_vector(31 downto 0);
      mem_ack        : in  std_logic;
      mem_rdat       : in  std_logic_vector(31 downto 0);
      mem_berr       : in  std_logic;
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
  signal mmu_config_err : std_logic;
  signal mmu_config_ack : std_logic := '0';

  -- Valid TC configurations (PS must be 8-15, field sum = 32)
  -- 4KB pages: PS=12, IS=4, TIA=4, TIB=4, TIC=4, TID=4 (4+4+4+4+4+12=32)
  constant TC_4KB_VALID : std_logic_vector(31 downto 0) := x"80C44444";
  -- 8KB pages: PS=13, IS=4, TIA=4, TIB=4, TIC=4, TID=3 (4+4+4+4+3+13=32)
  constant TC_8KB_VALID : std_logic_vector(31 downto 0) := x"80D44443";
  -- 256B pages: PS=8, IS=0, TIA=8, TIB=8, TIC=8, TID=0 (0+8+8+8+0+8=32)
  constant TC_256B_VALID : std_logic_vector(31 downto 0) := x"80808880";
  -- 32KB pages: PS=15, IS=4, TIA=4, TIB=4, TIC=4, TID=1 (4+4+4+4+1+15=32)
  constant TC_32KB_VALID : std_logic_vector(31 downto 0) := x"80F44441";
  -- With SRE: PS=12, SRE=1
  constant TC_4KB_SRE : std_logic_vector(31 downto 0) := x"82C44444";
  -- With FCL: PS=12, FCL=1
  constant TC_4KB_FCL : std_logic_vector(31 downto 0) := x"81C44444";
  -- With SRE+FCL: PS=12, SRE=1, FCL=1
  constant TC_4KB_SRE_FCL : std_logic_vector(31 downto 0) := x"83C44444";

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

    procedure pmove_write_tc(value : std_logic_vector(31 downto 0)) is
    begin
      reg_wdat <= value;
      reg_sel <= "10000";  -- TC register
      reg_part <= '0';
      reg_fd <= '0';
      reg_we <= '1';
      wait_cycles(1);
      reg_we <= '0';
      wait_cycles(1);
    end procedure;

    procedure pmove_read_tc is
    begin
      reg_sel <= "10000";  -- TC register
      reg_part <= '0';
      reg_re <= '1';
      wait_cycles(1);
      reg_re <= '0';
      wait_cycles(1);
    end procedure;

    procedure ack_mmu_config_error is
    begin
      mmu_config_ack <= '1';
      wait_cycles(1);
      mmu_config_ack <= '0';
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
    write(l, string'("Using valid TC configurations (PS=8-15)"));
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

    -- TEST 2: Write and read back zero (MMU disabled)
    write(l, string'("TEST 2: Write/Read Zero (MMU Disabled)"));
    writeline(output, l);
    test_write_read(x"00000000", x"00000000", "Write 0x00000000, read 0x00000000");

    -- TEST 3: Valid 4KB config write/read
    write(l, string'("TEST 3: Valid 4KB Config"));
    writeline(output, l);
    test_write_read(TC_4KB_VALID, TC_4KB_VALID, "Write/read 0x80C44444");

    -- TEST 4: Valid 8KB config write/read
    write(l, string'("TEST 4: Valid 8KB Config"));
    writeline(output, l);
    test_write_read(TC_8KB_VALID, TC_8KB_VALID, "Write/read 0x80D44443");

    -- TEST 5: Valid 256B config (smallest page)
    write(l, string'("TEST 5: Valid 256B Config (PS=8)"));
    writeline(output, l);
    test_write_read(TC_256B_VALID, TC_256B_VALID, "Write/read 0x80808880");

    -- TEST 6: Valid 32KB config (largest page)
    write(l, string'("TEST 6: Valid 32KB Config (PS=15)"));
    writeline(output, l);
    test_write_read(TC_32KB_VALID, TC_32KB_VALID, "Write/read 0x80F44441");

    -- TEST 7: SRE bit preserved
    write(l, string'("TEST 7: SRE Bit Preserved"));
    writeline(output, l);
    test_write_read(TC_4KB_SRE, TC_4KB_SRE, "Write/read with SRE=1");

    -- TEST 8: FCL bit preserved
    write(l, string'("TEST 8: FCL Bit Preserved"));
    writeline(output, l);
    test_write_read(TC_4KB_FCL, TC_4KB_FCL, "Write/read with FCL=1");

    -- TEST 9: E + SRE + FCL all set
    write(l, string'("TEST 9: E + SRE + FCL"));
    writeline(output, l);
    test_write_read(TC_4KB_SRE_FCL, TC_4KB_SRE_FCL, "Write/read with E+SRE+FCL");

    -- TEST 10: Multiple sequential reads (value should be stable)
    write(l, string'("TEST 10: Multiple Sequential Reads"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    pmove_read_tc;
    report_test("First read", reg_rdat = TC_4KB_VALID);
    pmove_read_tc;
    report_test("Second read", reg_rdat = TC_4KB_VALID);
    pmove_read_tc;
    report_test("Third read", reg_rdat = TC_4KB_VALID);

    -- TEST 11: Read-modify-write sequence
    write(l, string'("TEST 11: Read-Modify-Write Sequence"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    pmove_read_tc;
    report_test("Initial read (4KB)", reg_rdat = TC_4KB_VALID);
    pmove_write_tc(TC_8KB_VALID);
    pmove_read_tc;
    report_test("After modify (8KB)", reg_rdat = TC_8KB_VALID);

    -- TEST 12: Reserved bits masked to zero
    write(l, string'("TEST 12: Reserved Bits Masked"));
    writeline(output, l);
    -- Write with reserved bits set but valid PS=12
    pmove_write_tc(x"FFC44444");
    pmove_read_tc;
    report_test("Reserved bits masked to zero", reg_rdat = x"83C44444");

    -- TEST 13: Disable after enable
    write(l, string'("TEST 13: Disable After Enable"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    pmove_read_tc;
    report_test("MMU enabled", reg_rdat = TC_4KB_VALID and tc_enable = '1');
    pmove_write_tc(x"00C44444");  -- Same config but E=0
    pmove_read_tc;
    report_test("MMU disabled, config preserved", reg_rdat = x"00C44444" and tc_enable = '0');

    -- TEST 14: Read during reset
    write(l, string'("TEST 14: Read During Reset"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    nreset <= '0';
    wait_cycles(2);
    pmove_read_tc;
    report_test("Read during reset = 0x00000000", reg_rdat = x"00000000");
    nreset <= '1';
    wait_cycles(2);

    -- TEST 15: Back-to-back write/read
    write(l, string'("TEST 15: Back-to-Back Write/Read"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_SRE_FCL);
    pmove_read_tc;
    report_test("Immediate read after write", reg_rdat = TC_4KB_SRE_FCL);

    -- TEST 16: Invalid PS rejected (E bit cleared)
    write(l, string'("TEST 16: Invalid PS Rejected"));
    writeline(output, l);
    pmove_write_tc(x"80000000");  -- PS=0 is invalid
    pmove_read_tc;
    report_test("E cleared for invalid PS", reg_rdat(31) = '0');
    report_test("MMU configuration exception latched", mmu_config_err = '1');
    ack_mmu_config_error;
    report_test("MMU configuration exception acknowledged", mmu_config_err = '0');

    -- TEST 17: Field isolation - verify PS field
    write(l, string'("TEST 17: PS Field Verification"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);  -- PS=12
    pmove_read_tc;
    report_test("PS=12 (4KB)", reg_rdat(23 downto 20) = "1100");
    pmove_write_tc(TC_8KB_VALID);  -- PS=13
    pmove_read_tc;
    report_test("PS=13 (8KB)", reg_rdat(23 downto 20) = "1101");

    -- TEST 18: Field isolation - verify IS field
    write(l, string'("TEST 18: IS Field Verification"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);  -- IS=4
    pmove_read_tc;
    report_test("IS=4", reg_rdat(19 downto 16) = "0100");

    -- TEST 19: Field isolation - verify TI fields
    write(l, string'("TEST 19: TI Fields Verification"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);  -- All TI=4
    pmove_read_tc;
    report_test("TIA=4", reg_rdat(15 downto 12) = "0100");
    report_test("TIB=4", reg_rdat(11 downto 8) = "0100");
    report_test("TIC=4", reg_rdat(7 downto 4) = "0100");
    report_test("TID=4", reg_rdat(3 downto 0) = "0100");

    -- TEST 20: tc_enable output tracks E bit
    write(l, string'("TEST 20: tc_enable Output"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    wait_cycles(1);
    report_test("tc_enable=1 when E=1", tc_enable = '1');
    pmove_write_tc(x"00000000");
    wait_cycles(1);
    report_test("tc_enable=0 when E=0", tc_enable = '0');

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
