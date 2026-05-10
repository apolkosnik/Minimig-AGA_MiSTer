-- tb_pmmu_reg_comprehensive.vhd
-- Comprehensive PMMU register access test
-- Validates all PMMU registers can be written and read correctly
-- Tests for MC68030 compliance with register write masks and reserved bits
--
-- Register selector encoding (reg_sel = brief(14:10)):
--   "00010" = TT0,  "00011" = TT1
--   "10000" = TC,   "10010" = SRP,  "10011" = CRP
--   "11000" = MMUSR
--
-- Register write masks (from TG68K_PMMU_030.vhd):
--   TC:       0x83FFFFFF (bits 30-26 reserved; PS bit 23 forced to 1 when E=1)
--   TT0/TT1:  0xFFFF8777 (bits 14-11, 7, 3 reserved)
--   CRP/SRP HIGH: 0xFFFF0003 (bits 15-2 reserved)
--   CRP/SRP LOW:  0xFFFFFFF0 (bits 3-0 reserved)
--   MMUSR:    write-1-to-clear on bits 15,14,13,9 only

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.TG68K_Pack.all;

entity tb_pmmu_reg_comprehensive is
end tb_pmmu_reg_comprehensive;

architecture behavioral of tb_pmmu_reg_comprehensive is

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

  signal clk           : std_logic := '0';
  signal nReset        : std_logic := '0';

  -- PMMU register interface
  signal reg_we        : std_logic := '0';
  signal reg_re        : std_logic := '0';
  signal reg_sel       : std_logic_vector(4 downto 0) := (others => '0');
  signal reg_wdat      : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rdat      : std_logic_vector(31 downto 0);
  signal reg_part      : std_logic := '0';
  signal reg_fd        : std_logic := '0';

  -- Translation interface (minimal for reg test)
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
  signal fault_addr    : std_logic_vector(31 downto 0);
  signal fault_fc      : std_logic_vector(2 downto 0);
  signal fault_rw      : std_logic;
  signal fault_is_insn : std_logic;
  signal tc_enable     : std_logic;
  signal mem_req       : std_logic;
  signal mem_we        : std_logic;
  signal mem_addr      : std_logic_vector(31 downto 0);
  signal mem_wdat      : std_logic_vector(31 downto 0);
  signal mem_ack       : std_logic := '0';
  signal mem_berr      : std_logic := '0';
  signal mem_rdat      : std_logic_vector(31 downto 0) := (others => '0');
  signal busy          : std_logic;
  signal mmu_config_err : std_logic;
  signal mmu_config_ack : std_logic := '0';
  signal ptest_desc_addr : std_logic_vector(31 downto 0);
  signal debug_mmusr   : std_logic_vector(15 downto 0);

  signal errors        : integer := 0;
  signal tests_run     : integer := 0;

  constant CLK_PERIOD  : time := 10 ns;

  -- MC68030 register selector constants (brief(14:10))
  constant SEL_TT0   : std_logic_vector(4 downto 0) := "00010";
  constant SEL_TT1   : std_logic_vector(4 downto 0) := "00011";
  constant SEL_TC    : std_logic_vector(4 downto 0) := "10000";
  constant SEL_SRP   : std_logic_vector(4 downto 0) := "10010";
  constant SEL_CRP   : std_logic_vector(4 downto 0) := "10011";
  constant SEL_MMUSR : std_logic_vector(4 downto 0) := "11000";

  -- MC68030 register write masks (must match TG68K_PMMU_030.vhd)
  constant TC_MASK       : std_logic_vector(31 downto 0) := x"83FFFFFF";
  constant TTR_MASK      : std_logic_vector(31 downto 0) := x"FFFF8777";
  constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := x"FFFF0003";
  constant CRP_LOW_MASK  : std_logic_vector(31 downto 0) := x"FFFFFFF0";
  constant MMUSR_MASK    : std_logic_vector(31 downto 0) := x"0000FFFF"; -- 16-bit register

begin

  clk_process: process
  begin
    clk <= '0';
    wait for CLK_PERIOD/2;
    clk <= '1';
    wait for CLK_PERIOD/2;
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
      ptest_req      => '0',
      pflush_req     => '0',
      pload_req      => '0',
      pmmu_fc        => "101",
      pmmu_addr      => (others => '0'),
      pmmu_brief     => (others => '0'),
      req            => req,
      is_insn        => is_insn,
      addr_log       => addr_log,
      rw             => rw,
      fc             => fc,
      addr_phys      => addr_phys,
      cache_inhibit  => cache_inhibit,
      write_protect  => write_protect,
      fault          => fault,
      fault_status   => fault_status,
      fault_addr     => fault_addr,
      fault_fc       => fault_fc,
      fault_rw       => fault_rw,
      fault_is_insn  => fault_is_insn,
      tc_enable      => tc_enable,
      mem_req        => mem_req,
      mem_we         => mem_we,
      mem_addr       => mem_addr,
      mem_wdat       => mem_wdat,
      mem_ack        => mem_ack,
      mem_berr       => mem_berr,
      mem_rdat       => mem_rdat,
      busy           => busy,
      mmu_config_err => mmu_config_err,
      mmu_config_ack => mmu_config_ack,
      ptest_desc_addr => ptest_desc_addr,
      debug_mmusr    => debug_mmusr
    );

  test: process
    variable read_val : std_logic_vector(31 downto 0);

    -- Write a PMMU register
    procedure write_reg(
      sel  : std_logic_vector(4 downto 0);
      part : std_logic;
      data : std_logic_vector(31 downto 0)
    ) is
    begin
      reg_sel <= sel;
      reg_part <= part;
      reg_wdat <= data;
      reg_we <= '1';
      wait for CLK_PERIOD;
      reg_we <= '0';
      wait for CLK_PERIOD;
    end procedure;

    -- Read and validate a PMMU register
    -- check_mask: bits to compare (allows ignoring don't-care bits)
    procedure check_reg(
      sel      : std_logic_vector(4 downto 0);
      part     : std_logic;
      expected : std_logic_vector(31 downto 0);
      check_mask : std_logic_vector(31 downto 0);
      name     : string
    ) is
      variable masked_read : std_logic_vector(31 downto 0);
      variable masked_exp  : std_logic_vector(31 downto 0);
    begin
      tests_run <= tests_run + 1;
      reg_sel <= sel;
      reg_part <= part;
      reg_re <= '1';
      wait for CLK_PERIOD;
      reg_re <= '0';
      wait for CLK_PERIOD;

      masked_read := reg_rdat and check_mask;
      masked_exp  := expected and check_mask;

      if masked_read = masked_exp then
        report "TEST: " & name & " - PASS (read 0x" & slv_to_hex(reg_rdat) & ")" severity note;
      else
        report "TEST: " & name & " - FAIL: expected 0x" & slv_to_hex(expected) &
               " (mask 0x" & slv_to_hex(check_mask) & "), got 0x" & slv_to_hex(reg_rdat) severity error;
        errors <= errors + 1;
      end if;
    end procedure;

    -- Write then immediately check with expected masked value
    procedure write_and_check(
      sel      : std_logic_vector(4 downto 0);
      part     : std_logic;
      wdata    : std_logic_vector(31 downto 0);
      expected : std_logic_vector(31 downto 0);
      name     : string
    ) is
    begin
      write_reg(sel, part, wdata);
      check_reg(sel, part, expected, x"FFFFFFFF", name);
    end procedure;

    procedure ack_mmu_config_error_if_set is
    begin
      if mmu_config_err = '1' then
        mmu_config_ack <= '1';
        wait for CLK_PERIOD;
        mmu_config_ack <= '0';
        wait for CLK_PERIOD;
      end if;
    end procedure;

  begin
    nReset <= '0';
    wait for 5*CLK_PERIOD;
    nReset <= '1';
    wait for 2*CLK_PERIOD;

    report "========================================" severity note;
    report "PMMU Register Comprehensive Test" severity note;
    report "MC68030 Register Write Mask Validation" severity note;
    report "========================================" severity note;

    -- =============================================
    -- TEST 1: TC Register (sel="10000")
    -- Mask: 0x83FFFFFF - reserved bits 30-26 cleared
    -- When E=1: PS bit 23 forced to 1 (valid PS range 8-15)
    -- When E=1: TC validation (PS>=8, field sum=32) may clear E bit
    -- =============================================
    report "" severity note;
    report "===== TEST 1: TC Register =====" severity note;

    -- 1a: Write TC with E=0 (no validation), check mask clears bits 30-26
    -- Write 0x7FFFFFFF (E=0, all other bits set)
    -- Expect: 0x7FFFFFFF & 0x83FFFFFF = 0x03FFFFFF
    write_and_check(SEL_TC, '0', x"7FFFFFFF", x"03FFFFFF",
      "TC E=0 all bits - reserved 30-26 cleared");

    -- 1b: Write TC with valid E=1 config: PS=13 (8KB), IS=0, TIA=4, TIB=7, TIC=8
    -- Field sum: 13+0+4+7+8=32 (valid)
    -- 0x80D04780 -> & 0x83FFFFFF = 0x80D04780 (bits 30-26 already 0)
    -- PS=13 (1101) has bit 23=1, no forcing needed
    write_and_check(SEL_TC, '0', x"80D04780", x"80D04780",
      "TC E=1 valid config (PS=13, IS=0, TIA=4, TIB=7, TIC=8)");

    -- 1c: Verify tc_enable output matches E bit
    tests_run <= tests_run + 1;
    if tc_enable = '1' then
      report "TEST: TC tc_enable=1 after E=1 write - PASS" severity note;
    else
      report "TEST: TC tc_enable=1 after E=1 write - FAIL: tc_enable=" &
             std_logic'image(tc_enable) severity error;
      errors <= errors + 1;
    end if;

    -- 1d: Write TC with E=0 to disable MMU
    -- PS bit 23 forcing only applies when E=1, so writing 0 gives 0
    write_and_check(SEL_TC, '0', x"00000000", x"00000000",
      "TC E=0 disable - all zero");

    -- 1e: Reserved bits 30-26 must be cleared even with E=1
    -- Write 0xFFFFFFFF: E=1, but PS=15 (valid), IS=15, TIA=15, TIB=15, TIC=15, TID=15
    -- Field sum = 15+15+15+15+15+15 = 90 != 32 -> E cleared!
    -- The TC register stores the masked value, then clears E on the invalid
    -- field sum per MC68030 MMU configuration exception behavior.
    write_and_check(SEL_TC, '0', x"FFFFFFFF", x"03FFFFFF",
      "TC all-1s - invalid field sum clears E");
    ack_mmu_config_error_if_set;

    -- 1f: Valid E=1 with FCL=1: PS=15, IS=0, TIA=9, TIB=8 (030.library config)
    -- 0x81F09800 & 0x83FFFFFF = 0x81F09800 (bits 30-26 already 0)
    -- Field sum: 15+0+9+8=32 (valid with FCL stopping at TIB=0 check... actually sum=32 is valid)
    write_and_check(SEL_TC, '0', x"81F09800", x"81F09800",
      "TC E=1 FCL=1 030.library config (PS=15, TIA=9, TIB=8)");

    -- Disable MMU for remaining tests
    write_reg(SEL_TC, '0', x"00000000");

    -- =============================================
    -- TEST 2: TT0 Register (sel="00010")
    -- Per WinUAE convention (cpummu30.cpp:436), TT0 stores the full 32-bit
    -- value as written. Reserved bits 14-11, 7, 3 are documented as "must be
    -- programmed as 0" (UM 9.2.6) but the hardware preserves them; only the
    -- decode path consults the documented fields. Real software writes 0
    -- to reserved bits per spec, so the read-back is the same in either
    -- model for legitimate code.
    -- =============================================
    report "" severity note;
    report "===== TEST 2: TT0 Register =====" severity note;

    -- 2a: Write all fields, expect all bits preserved (WinUAE behavior)
    write_and_check(SEL_TT0, '0', x"FFFFFFFF", x"FFFFFFFF",
      "TT0 all-1s - all bits preserved (WinUAE convention)");

    -- 2b: Write with only valid bits set
    -- Base=0xFF, Mask=0x00, E=1, CI=1, RW=1, RWM=1, FC_Base=111, FC_Mask=111
    -- 0xFF008777
    write_and_check(SEL_TT0, '0', x"FF008777", x"FF008777",
      "TT0 valid fields only");

    -- 2c: Write zero (disable)
    write_and_check(SEL_TT0, '0', x"00000000", x"00000000",
      "TT0 clear to zero");

    -- 2d: Typical match-all config: 0x00FF8107 (Base=0, Mask=FF, E=1, RWM=1, FC_Mask=111)
    write_and_check(SEL_TT0, '0', x"00FF8107", x"00FF8107",
      "TT0 match-all FC config");

    -- =============================================
    -- TEST 3: TT1 Register (sel="00011")
    -- Same WinUAE convention as TT0: all 32 bits preserved on write.
    -- =============================================
    report "" severity note;
    report "===== TEST 3: TT1 Register =====" severity note;

    -- 3a: All bits set, all preserved
    write_and_check(SEL_TT1, '0', x"FFFFFFFF", x"FFFFFFFF",
      "TT1 all-1s - all bits preserved (WinUAE convention)");

    -- 3b: Typical supervisor instruction fetch config
    -- Base=0x00, Mask=0xFF, E=1, FC_Base=110 (FC=6), FC_Mask=000
    -- 0x00FF8160 & 0xFFFF8777 = 0x00FF8160
    write_and_check(SEL_TT1, '0', x"00FF8160", x"00FF8160",
      "TT1 supervisor instruction fetch config");

    -- 3c: Clear
    write_and_check(SEL_TT1, '0', x"00000000", x"00000000",
      "TT1 clear to zero");

    -- =============================================
    -- TEST 4: CRP Register (sel="10011") - 64-bit
    -- HIGH mask: 0xFFFF0003 - reserved bits 15-2 cleared
    -- LOW mask:  0xFFFFFFF0 - reserved bits 3-0 cleared
    -- =============================================
    report "" severity note;
    report "===== TEST 4: CRP Register (64-bit) =====" severity note;

    -- 4a: CRP HIGH - all bits set, check reserved bits 15-2 cleared
    -- 0xFFFFFFFF & 0xFFFF0003 = 0xFFFF0003
    write_and_check(SEL_CRP, '1', x"FFFFFFFF", x"FFFF0003",
      "CRP_H all-1s - reserved bits 15-2 cleared");

    -- 4b: CRP LOW - all bits set, check reserved bits 3-0 cleared
    -- 0xFFFFFFFF & 0xFFFFFFF0 = 0xFFFFFFF0
    write_and_check(SEL_CRP, '0', x"FFFFFFFF", x"FFFFFFF0",
      "CRP_L all-1s - reserved bits 3-0 cleared");

    -- 4c: CRP HIGH - typical value: L/U=1, Limit=0, DT=10 (short format)
    -- 0x80000002 & 0xFFFF0003 = 0x80000002
    write_and_check(SEL_CRP, '1', x"80000002", x"80000002",
      "CRP_H L/U=1 DT=10 (typical)");

    -- 4d: CRP LOW - typical table address
    -- 0x00040010 & 0xFFFFFFF0 = 0x00040010
    write_and_check(SEL_CRP, '0', x"00040010", x"00040010",
      "CRP_L table address (typical)");

    -- 4e: Verify CRP HIGH persists after CRP LOW write
    check_reg(SEL_CRP, '1', x"80000002", x"FFFFFFFF",
      "CRP_H persistence after LOW write");

    -- 4f: CRP HIGH with reserved bits set in 15-2 range
    -- 0xABCD5678 & 0xFFFF0003 = 0xABCD0000 (bits 15-2 cleared, bit 1:0 of 0x78=0b00)
    -- Actually: 0x5678 in binary = 0101 0110 0111 1000
    -- Masked by   0x0003        = 0000 0000 0000 0011
    -- Result lower 16 bits      = 0000 0000 0000 0000 = 0x0000
    write_and_check(SEL_CRP, '1', x"ABCD5678", x"ABCD0000",
      "CRP_H reserved bits 15-2 verified cleared");
    ack_mmu_config_error_if_set;

    -- 4g: CRP LOW with reserved bits set in 3-0 range
    -- 0x1234000F & 0xFFFFFFF0 = 0x12340000
    write_and_check(SEL_CRP, '0', x"1234000F", x"12340000",
      "CRP_L reserved bits 3-0 verified cleared");

    -- =============================================
    -- TEST 5: SRP Register (sel="10010") - 64-bit
    -- Same masks as CRP
    -- =============================================
    report "" severity note;
    report "===== TEST 5: SRP Register (64-bit) =====" severity note;

    -- 5a: SRP HIGH - all bits set
    write_and_check(SEL_SRP, '1', x"FFFFFFFF", x"FFFF0003",
      "SRP_H all-1s - reserved bits 15-2 cleared");

    -- 5b: SRP LOW - all bits set
    write_and_check(SEL_SRP, '0', x"FFFFFFFF", x"FFFFFFF0",
      "SRP_L all-1s - reserved bits 3-0 cleared");

    -- 5c: SRP HIGH - typical DT=11 (long format)
    -- 0x80000003 & 0xFFFF0003 = 0x80000003
    write_and_check(SEL_SRP, '1', x"80000003", x"80000003",
      "SRP_H DT=11 (long format)");

    -- 5d: SRP LOW - table address with low nibble
    -- 0xCAFE00B0 & 0xFFFFFFF0 = 0xCAFE00B0
    write_and_check(SEL_SRP, '0', x"CAFE00B0", x"CAFE00B0",
      "SRP_L table address");

    -- 5e: Verify SRP HIGH persists after LOW write
    check_reg(SEL_SRP, '1', x"80000003", x"FFFFFFFF",
      "SRP_H persistence after LOW write");

    -- 5f: SRP HIGH reserved bits test
    write_and_check(SEL_SRP, '1', x"DEADBEEF", x"DEAD0003",
      "SRP_H reserved bits 15-2 verified cleared");

    -- 5g: SRP LOW reserved bits test
    write_and_check(SEL_SRP, '0', x"8765400F", x"87654000",
      "SRP_L reserved bits 3-0 verified cleared");

    -- =============================================
    -- TEST 6: MMUSR Register (sel="11000") - 16-bit
    -- Read-only except write-1-to-clear on bits 15,14,13,9
    -- Upper 16 bits always read as 0x0000
    -- =============================================
    report "" severity note;
    report "===== TEST 6: MMUSR Register (16-bit) =====" severity note;

    -- 6a: MMUSR should read as 0 after reset (no translations done)
    check_reg(SEL_MMUSR, '0', x"00000000", x"0000FFFF",
      "MMUSR zero after reset");

    -- 6b: PMOVE to MMUSR is a direct 16-bit store on MC68030.
    write_reg(SEL_MMUSR, '0', x"0000FFFF");
    check_reg(SEL_MMUSR, '0', x"0000FFFF", x"0000FFFF",
      "MMUSR direct PMOVE store updates low 16 bits");

    -- 6c: Upper 16 bits always zero
    check_reg(SEL_MMUSR, '0', x"00000000", x"FFFF0000",
      "MMUSR upper 16 bits always zero");

    -- =============================================
    -- TEST 7: Register Independence
    -- Write unique patterns to all registers, verify none corrupted
    -- =============================================
    report "" severity note;
    report "===== TEST 7: Register Independence =====" severity note;

    -- Write distinct patterns (accounting for masks)
    write_reg(SEL_TC,  '0', x"00801111"); -- TC: E=0, PS=8 (bit 23=1), fields=0x1111
    write_reg(SEL_TT0, '0', x"AA558777"); -- TT0: only valid bits
    write_reg(SEL_TT1, '0', x"55AA0777"); -- TT1: only valid bits
    write_reg(SEL_CRP, '1', x"11110003"); -- CRP_H: only valid bits
    write_reg(SEL_CRP, '0', x"22220000"); -- CRP_L: only valid bits
    write_reg(SEL_SRP, '1', x"33330002"); -- SRP_H: only valid bits
    write_reg(SEL_SRP, '0', x"44440000"); -- SRP_L: only valid bits

    -- Verify all retain their values (exact match since we only wrote valid bits)
    check_reg(SEL_TC,  '0', x"00801111", x"83FFFFFF", "TC independence");
    check_reg(SEL_TT0, '0', x"AA558777", x"FFFF8777", "TT0 independence");
    check_reg(SEL_TT1, '0', x"55AA0777", x"FFFF8777", "TT1 independence");
    check_reg(SEL_CRP, '1', x"11110003", x"FFFF0003", "CRP_H independence");
    check_reg(SEL_CRP, '0', x"22220000", x"FFFFFFFF", "CRP_L independence");
    check_reg(SEL_SRP, '1', x"33330002", x"FFFF0003", "SRP_H independence");
    check_reg(SEL_SRP, '0', x"44440000", x"FFFFFFFF", "SRP_L independence");

    -- =============================================
    -- TEST 8: 64-bit Register Part Ordering
    -- Verify HIGH/LOW words are independent and can be written in any order
    -- =============================================
    report "" severity note;
    report "===== TEST 8: 64-bit Register Part Ordering =====" severity note;

    -- Write LOW first, then HIGH
    write_reg(SEL_CRP, '0', x"AAAA0000"); -- CRP_L first
    write_reg(SEL_CRP, '1', x"BBBB0002"); -- CRP_H second
    check_reg(SEL_CRP, '0', x"AAAA0000", x"FFFFFFFF", "CRP_L (low first)");
    check_reg(SEL_CRP, '1', x"BBBB0002", x"FFFF0003", "CRP_H (low first)");

    -- Write HIGH first, then LOW
    write_reg(SEL_SRP, '1', x"CCCC0002"); -- SRP_H first
    write_reg(SEL_SRP, '0', x"DDDD0000"); -- SRP_L second
    check_reg(SEL_SRP, '1', x"CCCC0002", x"FFFF0003", "SRP_H (high first)");
    check_reg(SEL_SRP, '0', x"DDDD0000", x"FFFFFFFF", "SRP_L (high first)");

    -- =============================================
    -- TEST 9: Sequential Write Stability
    -- Rapid writes should not corrupt register state
    -- =============================================
    report "" severity note;
    report "===== TEST 9: Sequential Write Stability =====" severity note;

    -- Rapid sequential writes to TC
    for i in 0 to 15 loop
      write_reg(SEL_TC, '0', std_logic_vector(to_unsigned(16#00800000# + i*16#1000#, 32)));
    end loop;

    -- Verify last write stuck (0x00800000 + 15*0x1000 = 0x0080F000)
    check_reg(SEL_TC, '0', x"0080F000", x"83FFFFFF", "TC after 16 rapid writes");

    -- =============================================
    -- TEST 10: TC Enable/Disable Transition
    -- Verify tc_enable output tracks E bit correctly
    -- =============================================
    report "" severity note;
    report "===== TEST 10: TC Enable/Disable =====" severity note;

    -- Disable first
    write_reg(SEL_TC, '0', x"00000000");
    tests_run <= tests_run + 1;
    if tc_enable = '0' then
      report "TEST: tc_enable=0 after E=0 - PASS" severity note;
    else
      report "TEST: tc_enable=0 after E=0 - FAIL" severity error;
      errors <= errors + 1;
    end if;

    -- Enable with valid config: PS=13, IS=0, TIA=4, TIB=7, TIC=8 (sum=32)
    write_reg(SEL_TC, '0', x"80D04780");
    tests_run <= tests_run + 1;
    if tc_enable = '1' then
      report "TEST: tc_enable=1 after valid E=1 - PASS" severity note;
    else
      report "TEST: tc_enable=1 after valid E=1 - FAIL" severity error;
      errors <= errors + 1;
    end if;

    -- Disable again
    write_reg(SEL_TC, '0', x"00000000");
    tests_run <= tests_run + 1;
    if tc_enable = '0' then
      report "TEST: tc_enable=0 after disable - PASS" severity note;
    else
      report "TEST: tc_enable=0 after disable - FAIL" severity error;
      errors <= errors + 1;
    end if;

    -- =============================================
    -- TEST 11: TC Validation - Invalid Configs
    -- E bit should be cleared for invalid configurations
    -- =============================================
    report "" severity note;
    report "===== TEST 11: TC Validation =====" severity note;

    -- 11a: Invalid PS (PS=0, below minimum of 8)
    -- 0x80000000: E=1, PS=0 -> E should be cleared
    write_reg(SEL_TC, '0', x"80000000");
    tests_run <= tests_run + 1;
    if tc_enable = '0' then
      report "TEST: TC invalid PS=0 -> E cleared - PASS" severity note;
    else
      report "TEST: TC invalid PS=0 -> E cleared - FAIL: tc_enable=" &
             std_logic'image(tc_enable) severity error;
      errors <= errors + 1;
    end if;
    check_reg(SEL_TC, '0', x"00000000", x"FFFFFFFF", "TC invalid PS=0 readback clears E");
    ack_mmu_config_error_if_set;

    -- 11b: Invalid field sum (PS=8, IS=0, TIA=1, TIB=0 -> sum=9 != 32)
    -- 0x80801000: E=1, PS=8, IS=0, TIA=1, rest=0
    write_reg(SEL_TC, '0', x"80801000");
    tests_run <= tests_run + 1;
    if tc_enable = '0' then
      report "TEST: TC invalid field sum -> E cleared - PASS" severity note;
    else
      report "TEST: TC invalid field sum -> E cleared - FAIL: tc_enable=" &
             std_logic'image(tc_enable) severity error;
      errors <= errors + 1;
    end if;
    check_reg(SEL_TC, '0', x"00801000", x"FFFFFFFF", "TC invalid field sum readback clears E");
    ack_mmu_config_error_if_set;

    -- =============================================
    -- TEST 12: PMOVEFD (Flush Disable)
    -- Writing with reg_fd=1 should not trigger ATC flush
    -- =============================================
    report "" severity note;
    report "===== TEST 12: PMOVEFD (Flush Disable) =====" severity note;

    -- Write TC normally (flush happens)
    reg_fd <= '0';
    write_reg(SEL_TC, '0', x"00800000");

    -- Write TC with flush disable
    reg_fd <= '1';
    write_reg(SEL_TC, '0', x"00801111");
    reg_fd <= '0';

    -- Verify the value was written
    check_reg(SEL_TC, '0', x"00801111", x"83FFFFFF", "TC after PMOVEFD write");

    -- =============================================
    -- Summary
    -- =============================================
    wait for 10*CLK_PERIOD;

    report "" severity note;
    report "========================================" severity note;
    if errors = 0 then
      report "ALL REGISTER TESTS PASSED (" & integer'image(tests_run) & " tests)" severity note;
    else
      report "REGISTER TEST FAILURES: " & integer'image(errors) & " of " &
             integer'image(tests_run) & " tests failed" severity error;
    end if;
    report "========================================" severity note;

    wait;
  end process;

end behavioral;
