-- tb_pmmu_early_term_remap.vhd
-- Focused PMMU testbench for:
--   * early-termination PFA arithmetic with non-identity TA
--   * page-size sweep (PS=8..15)
--   * multi-level walks vs. early termination
--   * Linux m68k 68030 SRE=1 root-pointer routing
--   * PFLUSHA / TC-rewrite ATC invalidation
--   * TC=0 / invalid-TC fallback behavior

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_pmmu_early_term_remap is
end tb_pmmu_early_term_remap;

architecture tb of tb_pmmu_early_term_remap is
  signal clk            : std_logic := '0';
  signal nreset         : std_logic := '0';
  constant CLK_PERIOD   : time := 10 ns;
  signal test_running   : boolean := true;

  -- Register port
  signal reg_we         : std_logic := '0';
  signal reg_re         : std_logic := '0';
  signal reg_sel        : std_logic_vector(4 downto 0) := (others => '0');
  signal reg_wdat       : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rdat       : std_logic_vector(31 downto 0);
  signal reg_part       : std_logic := '0';
  signal reg_fd         : std_logic := '0';

  signal ptest_req      : std_logic := '0';
  signal pflush_req     : std_logic := '0';
  signal pload_req      : std_logic := '0';
  signal pmmu_fc        : std_logic_vector(2 downto 0) := "000";
  signal pmmu_addr      : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_brief     : std_logic_vector(15 downto 0) := (others => '0');

  -- Translation request
  signal req            : std_logic := '0';
  signal is_insn        : std_logic := '0';
  signal rw             : std_logic := '1';
  signal fc             : std_logic_vector(2 downto 0) := "101";
  signal addr_log       : std_logic_vector(31 downto 0) := (others => '0');
  signal addr_phys      : std_logic_vector(31 downto 0);
  signal cache_inhibit  : std_logic;
  signal write_protect  : std_logic;
  signal fault          : std_logic;
  signal fault_status   : std_logic_vector(31 downto 0);
  signal fault_addr     : std_logic_vector(31 downto 0);
  signal fault_fc       : std_logic_vector(2 downto 0);
  signal fault_rw       : std_logic;
  signal fault_is_insn  : std_logic;
  signal tc_enable      : std_logic;

  -- Walker bus
  signal mem_req        : std_logic;
  signal mem_we         : std_logic;
  signal mem_addr       : std_logic_vector(31 downto 0);
  signal mem_wdat       : std_logic_vector(31 downto 0);
  signal mem_ack        : std_logic := '0';
  signal mem_berr       : std_logic := '0';
  signal mem_rdat       : std_logic_vector(31 downto 0) := (others => '0');
  signal busy           : std_logic;

  signal mmu_config_err : std_logic;
  signal mmu_config_ack : std_logic := '0';
  signal ptest_desc_addr : std_logic_vector(31 downto 0);

  type mem_t is array(0 to 8191) of std_logic_vector(31 downto 0);
  signal page_table : mem_t := (others => (others => '0'));

  signal errors : integer := 0;

  function hex8(v : std_logic_vector) return string is
    constant h : string := "0123456789ABCDEF";
    variable vv : std_logic_vector(31 downto 0) := v;
    variable r  : string(1 to 8);
  begin
    for i in 0 to 7 loop
      r(i + 1) := h(to_integer(unsigned(vv(31 - 4 * i downto 28 - 4 * i))) + 1);
    end loop;
    return r;
  end function;

begin
  clk_gen : process
  begin
    while test_running loop
      clk <= '0';
      wait for CLK_PERIOD / 2;
      clk <= '1';
      wait for CLK_PERIOD / 2;
    end loop;
    wait;
  end process;

  uut : entity work.TG68K_PMMU_030
    port map(
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
      fault_addr => fault_addr,
      fault_fc => fault_fc,
      fault_rw => fault_rw,
      fault_is_insn => fault_is_insn,
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
      mmu_config_ack => mmu_config_ack,
      ptest_desc_addr => ptest_desc_addr
    );

  mem_sim : process(clk)
    variable idx : integer;
  begin
    if rising_edge(clk) then
      if nreset = '0' then
        mem_ack  <= '0';
        mem_rdat <= (others => '0');
      else
        if mem_req = '1' and mem_ack = '0' then
          idx := to_integer(unsigned(mem_addr(14 downto 2)));
          if idx < 8192 then
            mem_rdat <= page_table(idx);
          else
            mem_rdat <= (others => '0');
          end if;
          mem_ack <= '1';
        elsif mem_req = '0' then
          mem_ack <= '0';
        end if;
      end if;
    end if;
  end process;

  test_proc : process
    procedure write_reg(
      sel  : std_logic_vector(4 downto 0);
      data : std_logic_vector(31 downto 0);
      part : std_logic
    ) is
    begin
      wait until rising_edge(clk);
      reg_sel  <= sel;
      reg_wdat <= data;
      reg_part <= part;
      reg_we   <= '1';
      wait until rising_edge(clk);
      reg_we <= '0';
      wait until rising_edge(clk);
    end procedure;

    procedure translate_and_check_fc(
      tname       : string;
      log         : std_logic_vector(31 downto 0);
      want        : std_logic_vector(31 downto 0);
      fc_val      : std_logic_vector(2 downto 0);
      is_insn_val : std_logic;
      rw_val      : std_logic
    ) is
    begin
      wait until rising_edge(clk);
      addr_log <= log;
      fc       <= fc_val;
      is_insn  <= is_insn_val;
      rw       <= rw_val;
      req      <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;

      for i in 0 to 200 loop
        exit when busy = '0' or fault = '1';
        wait until rising_edge(clk);
        wait for 1 ns;
      end loop;

      wait until rising_edge(clk);
      wait for 1 ns;
      req <= '0';

      if fault = '1' then
        errors <= errors + 1;
        report "[FAIL] " & tname & " -- unexpected fault, status=0x" & hex8(fault_status)
          severity error;
      elsif addr_phys /= want then
        errors <= errors + 1;
        report "[FAIL] " & tname &
               " -- log=0x" & hex8(log) &
               " want=0x" & hex8(want) &
               " got=0x" & hex8(addr_phys)
          severity error;
      else
        report "[PASS] " & tname &
               " -- log=0x" & hex8(log) &
               " phys=0x" & hex8(addr_phys)
          severity note;
      end if;

      for i in 0 to 4 loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure translate_and_check(
      tname : string;
      log   : std_logic_vector(31 downto 0);
      want  : std_logic_vector(31 downto 0)
    ) is
    begin
      translate_and_check_fc(tname, log, want, "101", '0', '1');
    end procedure;

    procedure translate_and_expect_fault(
      tname : string;
      log   : std_logic_vector(31 downto 0)
    ) is
    begin
      wait until rising_edge(clk);
      addr_log <= log;
      fc       <= "101";
      is_insn  <= '0';
      rw       <= '1';
      req      <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;

      for i in 0 to 200 loop
        exit when busy = '0' or fault = '1';
        wait until rising_edge(clk);
        wait for 1 ns;
      end loop;

      wait until rising_edge(clk);
      wait for 1 ns;
      req <= '0';

      if fault = '1' then
        report "[PASS] " & tname &
               " -- log=0x" & hex8(log) &
               " fault_status=0x" & hex8(fault_status)
          severity note;
      else
        errors <= errors + 1;
        report "[FAIL] " & tname &
               " -- expected fault, got phys=0x" & hex8(addr_phys)
          severity error;
      end if;

      for i in 0 to 4 loop
        wait until rising_edge(clk);
      end loop;
    end procedure;
  begin
    nreset <= '0';
    wait for 100 ns;
    nreset <= '1';
    wait for 100 ns;

    report "=== tb_pmmu_early_term_remap ===" severity note;

    -- Phase A: WhichAmiga-style early-termination setup
    -- TC=$80D04780 : E=1 SRE=0 FCL=0 PS=13 TIA=4 TIB=7 TIC=8 TID=0
    -- CRP -> $00006000, short-format root
    page_table(6144 + 0)  <= x"00000061";
    page_table(6144 + 10) <= x"A0000061";
    page_table(6144 + 13) <= x"00000061";
    page_table(6144 + 14) <= x"50000061";
    wait for 20 ns;

    write_reg("10000", x"80D04780", '0');
    write_reg("10011", x"7FFF0002", '1');
    write_reg("10011", x"00006000", '0');
    wait for 100 ns;

    -- Phase B: identity early-term entry
    translate_and_check("A-identity @ $A0000000", x"A0000000", x"A0000000");
    translate_and_check("A-identity @ $A0001234", x"A0001234", x"A0001234");
    translate_and_check("A-identity @ $A1234567", x"A1234567", x"A1234567");

    -- Phase C: non-identity remap with TA=0
    translate_and_check("D-remap @ $D0001234", x"D0001234", x"00001234");
    translate_and_check("D-remap @ $D0003000", x"D0003000", x"00003000");
    translate_and_check("D-remap @ $D0123456", x"D0123456", x"00123456");
    translate_and_check("D-remap @ $DFFFEFFF", x"DFFFEFFF", x"0FFFEFFF");

    -- Phase D: non-identity remap with non-zero TA
    translate_and_check("E-remap @ $E0001234", x"E0001234", x"50001234");
    translate_and_check("E-remap @ $E5ABCDEF", x"E5ABCDEF", x"55ABCDEF");

    -- Phase F: 4 KB pages and remap arithmetic at PS=12
    page_table(6144 + 11) <= x"B0000061";
    page_table(6144 + 12) <= x"80000061";
    wait for 20 ns;

    write_reg("10000", x"80C04880", '0');
    wait for 100 ns;

    translate_and_check("4KB-identity @ $B0000000", x"B0000000", x"B0000000");
    translate_and_check("4KB-identity @ $B0001000", x"B0001000", x"B0001000");
    translate_and_check("4KB-identity @ $B0002000", x"B0002000", x"B0002000");
    translate_and_check("4KB-identity @ $B00012AB", x"B00012AB", x"B00012AB");
    translate_and_check("4KB-identity @ $B1234567", x"B1234567", x"B1234567");

    translate_and_check("4KB-remap @ $C0000000", x"C0000000", x"80000000");
    translate_and_check("4KB-remap @ $C0000FFF", x"C0000FFF", x"80000FFF");
    translate_and_check("4KB-remap @ $C0001000", x"C0001000", x"80001000");
    translate_and_check("4KB-remap @ $C0100000", x"C0100000", x"80100000");
    translate_and_check("4KB-remap @ $CFFFEFFF", x"CFFFEFFF", x"8FFFEFFF");

    -- Phase G: valid MC68030 page-size sweep (PS=8..15)
    page_table(6144 + 0) <= x"90000061";
    wait for 20 ns;

    write_reg("10000", x"80804884", '0');
    wait for 100 ns;
    translate_and_check("PS=8  @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=8  @ $00000100", x"00000100", x"90000100");
    translate_and_check("PS=8  @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    write_reg("10000", x"80904883", '0');
    wait for 100 ns;
    translate_and_check("PS=9  @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=9  @ $00000200", x"00000200", x"90000200");
    translate_and_check("PS=9  @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    write_reg("10000", x"80A04882", '0');
    wait for 100 ns;
    translate_and_check("PS=10 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=10 @ $00000400", x"00000400", x"90000400");
    translate_and_check("PS=10 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    page_table(6144 + 0) <= x"90000361";
    wait for 20 ns;
    write_reg("10000", x"80A04882", '0');
    wait for 100 ns;
    translate_and_check("PS=10 masks PD low bits @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=10 masks PD low bits @ $00000340", x"00000340", x"90000340");
    page_table(6144 + 0) <= x"90000061";
    wait for 20 ns;

    write_reg("10000", x"80B04881", '0');
    wait for 100 ns;
    translate_and_check("PS=11 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=11 @ $00000800", x"00000800", x"90000800");
    translate_and_check("PS=11 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    write_reg("10000", x"80C04880", '0');
    wait for 100 ns;
    translate_and_check("PS=12 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=12 @ $00001000", x"00001000", x"90001000");
    translate_and_check("PS=12 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    write_reg("10000", x"80D04780", '0');
    wait for 100 ns;
    translate_and_check("PS=13 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=13 @ $00002000", x"00002000", x"90002000");
    translate_and_check("PS=13 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    write_reg("10000", x"80E04770", '0');
    wait for 100 ns;
    translate_and_check("PS=14 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=14 @ $00004000", x"00004000", x"90004000");
    translate_and_check("PS=14 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    write_reg("10000", x"80F04670", '0');
    wait for 100 ns;
    translate_and_check("PS=15 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=15 @ $00008000", x"00008000", x"90008000");
    translate_and_check("PS=15 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- Phase H: multi-level walk coverage
    page_table(6144 + 0) <= x"00007002";
    page_table(7168 + 0) <= x"00000061";
    page_table(7168 + 1) <= x"00001061";
    page_table(7168 + 2) <= x"00002061";
    page_table(7168 + 10) <= x"00800061";
    wait for 20 ns;

    write_reg("10000", x"80C0AA00", '0');
    wait for 100 ns;

    translate_and_check("2-lvl identity @ $00000234", x"00000234", x"00000234");
    translate_and_check("2-lvl identity @ $000012AB", x"000012AB", x"000012AB");
    translate_and_check("2-lvl identity @ $00002ABC", x"00002ABC", x"00002ABC");
    translate_and_check("2-lvl remap   @ $0000A000", x"0000A000", x"00800000");
    translate_and_check("2-lvl remap   @ $0000A5A5", x"0000A5A5", x"008005A5");

    -- Phase I: Linux 68030 SRE=1 routing with separate CRP/SRP roots
    page_table(6144 + 0) <= x"00000061";
    page_table(4096 + 0) <= x"70000061";
    wait for 20 ns;

    write_reg("10000", x"82C07760", '0');
    write_reg("10011", x"7FFF0002", '1');
    write_reg("10011", x"00006000", '0');
    write_reg("10010", x"7FFF0002", '1');
    write_reg("10010", x"00004000", '0');
    wait for 100 ns;

    translate_and_check("SRE sup-data @ $01234000", x"01234000", x"71234000");
    translate_and_check("SRE sup-data @ $01FFE000", x"01FFE000", x"71FFE000");
    translate_and_check_fc("SRE user-data @ $01234000", x"01234000", x"01234000", "001", '0', '1');

    -- Phase J: Linux 32 MB early-term geometry
    page_table(6144 + 1) <= x"50000061";
    page_table(4096 + 1) <= x"50000061";
    wait for 20 ns;

    translate_and_check("Linux32M @ $02000000", x"02000000", x"50000000");
    translate_and_check("Linux32M @ $02000FFF", x"02000FFF", x"50000FFF");
    translate_and_check("Linux32M @ $02001000", x"02001000", x"50001000");
    translate_and_check("Linux32M @ $02100000", x"02100000", x"50100000");
    translate_and_check("Linux32M @ $03FFE000", x"03FFE000", x"51FFE000");
    translate_and_check("Linux32M @ $03FFF000", x"03FFF000", x"51FFF000");

    -- Phase K: ATC invalidation via PFLUSHA and TC rewrite
    translate_and_check("PFLUSHA pre     @ $02123000", x"02123000", x"50123000");

    page_table(6144 + 1) <= x"60000061";
    page_table(4096 + 1) <= x"60000061";
    wait for 40 ns;
    translate_and_check("PFLUSHA stale   @ $02123000", x"02123000", x"50123000");

    wait until rising_edge(clk);
    pmmu_brief <= x"2400";
    pmmu_addr  <= (others => '0');
    pmmu_fc    <= "000";
    pflush_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    pflush_req <= '0';
    pmmu_brief <= x"0000";
    wait for 300 ns;

    translate_and_check("PFLUSHA post    @ $02123000", x"02123000", x"60123000");

    page_table(6144 + 1) <= x"20000061";
    page_table(4096 + 1) <= x"20000061";
    wait for 40 ns;

    write_reg("10000", x"82C07760", '0');
    wait for 200 ns;
    translate_and_check("TC-flush post   @ $02123000", x"02123000", x"20123000");

    -- Phase L: root-pointer early-termination limit handling
    -- TC=$80C8A200 : E=1 SRE=0 FCL=0 PS=12 IS=8 TIA=10 TIB=2
    -- Root pointer is DT=01 (page descriptor) with upper LIMIT=1.
    -- The limit must apply to TIA, not TIB.
    write_reg("10011", x"00010001", '1');
    write_reg("10011", x"90000000", '0');
    write_reg("10000", x"80C8A200", '0');
    wait for 100 ns;

    translate_and_check("RootPtr limit pass (TIA=0,TIB=3)", x"00003000", x"90003000");
    translate_and_expect_fault("RootPtr limit fault (TIA=2,TIB=0)", x"00008000");

    -- MC68030 UM root-pointer DT=01: limit check applies regardless of FCL.
    write_reg("10000", x"81C8A200", '0');
    wait for 100 ns;
    translate_and_expect_fault("RootPtr FCL still checks limit", x"00008000");

    -- Phase M: invalid TIA=0 image is rejected and falls back to identity
    page_table(6144 + 0) <= x"00000061";
    wait for 20 ns;

    wait until rising_edge(clk);
    mmu_config_ack <= '1';
    wait until rising_edge(clk);
    mmu_config_ack <= '0';
    wait for 20 ns;

    write_reg("10011", x"7FFF0002", '1');
    write_reg("10011", x"00006000", '0');
    write_reg("10000", x"80800888", '0');
    wait for 100 ns;

    translate_and_check("TIA0 disabled-MMU @ $12345678", x"12345678", x"12345678");
    translate_and_check("TIA0 disabled-MMU @ $DEADBEEF", x"DEADBEEF", x"DEADBEEF");
    translate_and_check("TIA0 disabled-MMU @ $00000000", x"00000000", x"00000000");

    wait for 200 ns;

    if errors = 0 then
      report "=== RESULT: PASS (0 failures) ===" severity note;
    else
      report "=== RESULT: FAIL (" & integer'image(errors) & " failures) ===" severity error;
    end if;

    test_running <= false;
    wait;
  end process;

end architecture;
