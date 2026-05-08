-- tb_pmove_tc_corner.vhd
-- Comprehensive corner-case testbench for PMOVE Dx,TC instruction
-- Tests TC (Translation Control) register with MC68030 specification corner cases
-- Validates reserved bit masking, field validation, and proper read/write behavior
--
-- MC68030 TC Register format (32 bits):
--   Bit 31: E (Enable)
--   Bits 30-26: Reserved (must be 0)
--   Bit 25: SRE (Supervisor Root Enable)
--   Bit 24: FCL (Function Code Lookup)
--   Bits 23-20: PS (Page Size) - MUST be 8-15 for valid config
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

entity tb_pmove_tc_corner is
end tb_pmove_tc_corner;

architecture behavior of tb_pmove_tc_corner is

  

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
  -- With SRE: PS=12, SRE=1, IS=4, TIA=4, TIB=4, TIC=4, TID=4
  constant TC_4KB_SRE : std_logic_vector(31 downto 0) := x"82C44444";
  -- With FCL: PS=12, FCL=1, IS=4, TIA=4, TIB=4, TIC=4, TID=4
  constant TC_4KB_FCL : std_logic_vector(31 downto 0) := x"81C44444";
  -- With SRE+FCL: PS=12, SRE=1, FCL=1, IS=4, TIA=4, TIB=4, TIC=4, TID=4
  constant TC_4KB_SRE_FCL : std_logic_vector(31 downto 0) := x"83C44444";

begin

  -- Instantiate PMMU
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
    write(l, string'("Using valid TC configurations (PS=8-15)"));
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

    -- TEST 2: Valid 4KB page config (E=1, PS=12)
    write(l, string'("TEST 2: Valid 4KB Page Config (E=1, PS=12)"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    pmove_read_tc;
    report_test("Write/Read 0x80C44444", reg_rdat = TC_4KB_VALID);
    report_test("TC Enable = 1", tc_enable = '1');

    -- TEST 3: Valid 8KB page config
    write(l, string'("TEST 3: Valid 8KB Page Config (E=1, PS=13)"));
    writeline(output, l);
    pmove_write_tc(TC_8KB_VALID);
    pmove_read_tc;
    report_test("Write/Read 0x80D44443", reg_rdat = TC_8KB_VALID);
    report_test("TC Enable = 1", tc_enable = '1');

    -- TEST 4: Valid 256B page config (smallest valid)
    write(l, string'("TEST 4: Valid 256B Page Config (E=1, PS=8)"));
    writeline(output, l);
    pmove_write_tc(TC_256B_VALID);
    pmove_read_tc;
    report_test("Write/Read 0x80808880", reg_rdat = TC_256B_VALID);
    report_test("PS=8 (256 bytes)", reg_rdat(23 downto 20) = "1000");

    -- TEST 5: Valid 32KB page config (largest valid)
    write(l, string'("TEST 5: Valid 32KB Page Config (E=1, PS=15)"));
    writeline(output, l);
    pmove_write_tc(TC_32KB_VALID);
    pmove_read_tc;
    report_test("Write/Read 0x80F44441", reg_rdat = TC_32KB_VALID);
    report_test("PS=15 (32KB)", reg_rdat(23 downto 20) = "1111");

    -- TEST 6: SRE bit (Supervisor Root Enable) with valid config
    write(l, string'("TEST 6: SRE Bit with Valid Config"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_SRE);
    pmove_read_tc;
    report_test("Write/Read with SRE=1", reg_rdat = TC_4KB_SRE);
    report_test("SRE bit set", reg_rdat(25) = '1');

    -- TEST 7: FCL bit (Function Code Lookup) with valid config
    write(l, string'("TEST 7: FCL Bit with Valid Config"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_FCL);
    pmove_read_tc;
    report_test("Write/Read with FCL=1", reg_rdat = TC_4KB_FCL);
    report_test("FCL bit set", reg_rdat(24) = '1');

    -- TEST 8: SRE + FCL combined
    write(l, string'("TEST 8: SRE + FCL Combined"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_SRE_FCL);
    pmove_read_tc;
    report_test("Write/Read with SRE=1, FCL=1", reg_rdat = TC_4KB_SRE_FCL);
    report_test("E=1, SRE=1, FCL=1", reg_rdat(31) = '1' and reg_rdat(25) = '1' and reg_rdat(24) = '1');

    -- TEST 9: Reserved bits behavior (bits 30-26)
    -- MC68030 TC reserved bits read back as zero.
    write(l, string'("TEST 9: Reserved Bits Masked"));
    writeline(output, l);
    -- Write all 1s but with valid PS=12 config
    pmove_write_tc(x"FFC44444");  -- All reserved bits set, PS=12, valid field sum
    pmove_read_tc;
    report_test("Reserved bits masked to zero", reg_rdat = x"83C44444");

    -- TEST 10: IS field verification
    write(l, string'("TEST 10: IS Field (Initial Shift)"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    pmove_read_tc;
    report_test("IS=4 stored", reg_rdat(19 downto 16) = "0100");

    -- TEST 11: TIA field verification
    write(l, string'("TEST 11: TIA Field"));
    writeline(output, l);
    pmove_read_tc;
    report_test("TIA=4 stored", reg_rdat(15 downto 12) = "0100");

    -- TEST 12: TIB field verification
    write(l, string'("TEST 12: TIB Field"));
    writeline(output, l);
    pmove_read_tc;
    report_test("TIB=4 stored", reg_rdat(11 downto 8) = "0100");

    -- TEST 13: TIC field verification
    write(l, string'("TEST 13: TIC Field"));
    writeline(output, l);
    pmove_read_tc;
    report_test("TIC=4 stored", reg_rdat(7 downto 4) = "0100");

    -- TEST 14: TID field verification
    write(l, string'("TEST 14: TID Field"));
    writeline(output, l);
    pmove_read_tc;
    report_test("TID=4 stored", reg_rdat(3 downto 0) = "0100");

    -- TEST 15: Overwrite previous value
    write(l, string'("TEST 15: Overwrite Previous Value"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    pmove_read_tc;
    report_test("First write (4KB)", reg_rdat = TC_4KB_VALID);
    pmove_write_tc(TC_8KB_VALID);
    pmove_read_tc;
    report_test("Overwrite with 8KB config", reg_rdat = TC_8KB_VALID);

    -- TEST 16: Disable after enable
    write(l, string'("TEST 16: Disable After Enable"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    pmove_read_tc;
    report_test("MMU enabled", tc_enable = '1');
    pmove_write_tc(x"00000000");
    pmove_read_tc;
    report_test("MMU disabled", tc_enable = '0');

    -- TEST 17: Reset clears TC register
    write(l, string'("TEST 17: Reset Behavior"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_SRE_FCL);
    nreset <= '0';
    wait_cycles(5);
    nreset <= '1';
    wait_cycles(2);
    pmove_read_tc;
    report_test("Reset clears TC", reg_rdat = x"00000000");

    -- TEST 18: Write during reset (should be ignored)
    write(l, string'("TEST 18: Write During Reset"));
    writeline(output, l);
    nreset <= '0';
    wait_cycles(2);
    pmove_write_tc(TC_4KB_VALID);
    nreset <= '1';
    wait_cycles(2);
    pmove_read_tc;
    report_test("Write during reset ignored", reg_rdat = x"00000000");

    -- TEST 19: PMOVEFD - Write without flushing ATC
    write(l, string'("TEST 19: PMOVEFD (Flush Disable)"));
    writeline(output, l);
    pmove_write_tc(TC_4KB_VALID);
    reg_wdat <= TC_8KB_VALID;
    reg_sel <= "10000";  -- TC register
    reg_part <= '0';
    reg_fd <= '1';  -- Flush disable
    reg_we <= '1';
    wait_cycles(1);
    reg_we <= '0';
    wait_cycles(1);
    pmove_read_tc;
    report_test("PMOVEFD write stored", reg_rdat = TC_8KB_VALID);

    -- TEST 20: Alternating enable/disable with valid config
    write(l, string'("TEST 20: Alternating Enable/Disable"));
    writeline(output, l);
    for i in 1 to 3 loop
      pmove_write_tc(TC_4KB_VALID);
      pmove_read_tc;
      report_test("Enable iteration " & integer'image(i), tc_enable = '1');
      pmove_write_tc(x"00000000");
      pmove_read_tc;
      report_test("Disable iteration " & integer'image(i), tc_enable = '0');
    end loop;

    -- TEST 21: Invalid PS (PS=0-7) should clear E bit
    write(l, string'("TEST 21: Invalid PS Rejected (PS=0)"));
    writeline(output, l);
    pmove_write_tc(x"80000000");  -- E=1 but PS=0 (invalid)
    pmove_read_tc;
    report_test("E bit cleared for invalid PS", reg_rdat(31) = '0');
    report_test("MMU stays disabled", tc_enable = '0');

    -- TEST 22: Invalid field sum should clear E bit
    write(l, string'("TEST 22: Invalid Field Sum Rejected"));
    writeline(output, l);
    -- PS=12, IS=15, TIA=15, TIB=15, TIC=15, TID=15 = 12+15+15+15+15+15 = 87 (invalid, != 32)
    pmove_write_tc(x"80CFFFFF");
    pmove_read_tc;
    report_test("E bit cleared for invalid sum", reg_rdat(31) = '0');

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
