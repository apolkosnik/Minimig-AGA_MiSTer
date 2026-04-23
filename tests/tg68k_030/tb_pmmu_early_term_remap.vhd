-- tb_pmmu_early_term_remap.vhd
-- Focused reproducer for the claimed PFA mis-calculation on early-termination
-- descriptors whose TA ≠ logical super-page base (non-identity remap).
--
-- Configuration mirrors WhichAmiga: PS=13 (8 KB), TIA=4, TIB=7, TIC=8, TID=0.
-- Root entry 13 (covering logical $D0000000–$DFFFFFFF, 256 MB super-page) is
-- a short-format page descriptor with TA=$00000000 -- this remaps the entire
-- $D0xxxxxx region onto physical $00xxxxxx.
--
-- The bench walks several PS-sized pages within that super-page and checks
-- that each produces a distinct PS-sized ATC entry with the correct PFA
-- (PFA = TA + unused_LPA_bits, per MC68030 UM §9.5.3.1).
--
-- A second case adds an identity-mapped root entry 10 at logical $A0xxxxxx to
-- confirm intra-super-page offsets still resolve when TA ≠ 0.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_pmmu_early_term_remap is
end tb_pmmu_early_term_remap;

architecture tb of tb_pmmu_early_term_remap is
  signal clk           : std_logic := '0';
  signal nreset        : std_logic := '0';
  constant CLK_PERIOD  : time := 10 ns;
  signal test_running  : boolean := true;

  -- Register port
  signal reg_we        : std_logic := '0';
  signal reg_re        : std_logic := '0';
  signal reg_sel       : std_logic_vector(4 downto 0) := (others => '0');
  signal reg_wdat      : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rdat      : std_logic_vector(31 downto 0);
  signal reg_part      : std_logic := '0';
  signal reg_fd        : std_logic := '0';

  signal ptest_req     : std_logic := '0';
  signal pflush_req    : std_logic := '0';
  signal pload_req     : std_logic := '0';
  signal pmmu_fc       : std_logic_vector(2 downto 0) := "000";
  signal pmmu_addr     : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_brief    : std_logic_vector(15 downto 0) := (others => '0');

  -- Translation request
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

  -- Walker bus
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

  -- Backing store for the 64-entry short-format root table at $00006000.
  -- Only 16 are meaningful (TIA=4) but we size for safety.
  type mem_t is array(0 to 8191) of std_logic_vector(31 downto 0);
  signal page_table : mem_t := (others => (others => '0'));

  signal errors : integer := 0;

  function hex8(v : std_logic_vector) return string is
    constant h : string := "0123456789ABCDEF";
    variable vv : std_logic_vector(31 downto 0) := v;
    variable r  : string(1 to 8);
  begin
    for i in 0 to 7 loop
      r(i+1) := h(to_integer(unsigned(vv(31-4*i downto 28-4*i))) + 1);
    end loop;
    return r;
  end function;

  procedure pass(msg : string) is
  begin
    report "[PASS] " & msg severity note;
  end procedure;

begin
  -- ---------------- Clock ----------------
  clk_gen: process
  begin
    while test_running loop
      clk <= '0'; wait for CLK_PERIOD/2;
      clk <= '1'; wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  -- ---------------- PMMU DUT ----------------
  uut: entity work.TG68K_PMMU_030
    port map(
      clk => clk, nreset => nreset,
      reg_we => reg_we, reg_re => reg_re, reg_sel => reg_sel,
      reg_wdat => reg_wdat, reg_rdat => reg_rdat,
      reg_part => reg_part, reg_fd => reg_fd,
      ptest_req => ptest_req, pflush_req => pflush_req, pload_req => pload_req,
      pmmu_fc => pmmu_fc, pmmu_addr => pmmu_addr, pmmu_brief => pmmu_brief,
      req => req, is_insn => is_insn, rw => rw, fc => fc,
      addr_log => addr_log, addr_phys => addr_phys,
      cache_inhibit => cache_inhibit, write_protect => write_protect,
      fault => fault, fault_status => fault_status,
      fault_addr => fault_addr, fault_fc => fault_fc,
      fault_rw => fault_rw, fault_is_insn => fault_is_insn,
      tc_enable => tc_enable,
      mem_req => mem_req, mem_we => mem_we, mem_addr => mem_addr,
      mem_wdat => mem_wdat, mem_ack => mem_ack, mem_berr => mem_berr,
      mem_rdat => mem_rdat, busy => busy,
      mmu_config_err => mmu_config_err, mmu_config_ack => mmu_config_ack,
      ptest_desc_addr => ptest_desc_addr
    );

  -- ---------------- Memory model ----------------
  mem_sim : process(clk)
    variable idx : integer;
  begin
    if rising_edge(clk) then
      if nreset = '0' then
        mem_ack  <= '0';
        mem_rdat <= (others => '0');
      else
        if mem_req = '1' and mem_ack = '0' then
          -- mem_addr is byte-address; page_table is longword-addressed
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

  -- ---------------- Test driver ----------------
  test_proc : process
    -- Expected PFA for every request we drive, computed per MC68030 spec:
    --   PFA = descriptor_TA + (logical_addr & (super_mask AND NOT page_mask))
    -- where super_mask = bits below effective_shift, page_mask = bits below PS.
    procedure write_reg(sel : std_logic_vector(4 downto 0);
                        data : std_logic_vector(31 downto 0);
                        part : std_logic) is
    begin
      wait until rising_edge(clk);
      reg_sel <= sel; reg_wdat <= data; reg_part <= part; reg_we <= '1';
      wait until rising_edge(clk);
      reg_we <= '0';
      wait until rising_edge(clk);
    end procedure;

    procedure translate_and_check(
      tname : string;
      log   : std_logic_vector(31 downto 0);
      want  : std_logic_vector(31 downto 0)
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
      -- wait for the translation to settle (busy goes low or fault fires)
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
      -- brief pause between requests to let busy/atc settle
      for i in 0 to 4 loop wait until rising_edge(clk); end loop;
    end procedure;

  begin
    nreset <= '0';
    wait for 100 ns;
    nreset <= '1';
    wait for 100 ns;

    report "=== tb_pmmu_early_term_remap ===" severity note;

    -- ------------------------------------------------------------
    -- Phase A: set up the WhichAmiga config
    --   TC = $80D04780 : E=1 SRE=0 FCL=0 PS=13 IS=0 TIA=4 TIB=7 TIC=8 TID=0
    --   CRP at $6000   : DT=10 short-format
    --
    -- Root entries (at $6000, 4 bytes each, 16 entries):
    --   Entry 10 ($A0xxxxxx): $A0000061 -- identity map
    --   Entry 13 ($D0xxxxxx): $00000061 -- REMAP to $00xxxxxx
    --   Entry 14 ($E0xxxxxx): $50000061 -- REMAP to $50xxxxxx (arbitrary)
    -- $61 = CI=1, rsvd=1, M=0, U=0, WP=0, DT=01 (short-format page desc)
    -- ------------------------------------------------------------

    -- Root table lives at $00006000 → idx = $6000/4 = 6144
    -- Entry i at $6000+i*4 → idx 6144+i
    page_table(6144 + 0)  <= x"00000061";  -- $00xxxxxx identity
    page_table(6144 + 10) <= x"A0000061";  -- $A0xxxxxx identity
    page_table(6144 + 13) <= x"00000061";  -- $D0xxxxxx → $00xxxxxx REMAP
    page_table(6144 + 14) <= x"50000061";  -- $E0xxxxxx → $50xxxxxx REMAP
    wait for 20 ns;

    -- Program TC and CRP
    write_reg("10000", x"80D04780", '0');                       -- TC
    write_reg("10011", x"7FFF0002", '1');                       -- CRP_H : L/U=0, LIMIT=$7FFF, DT=10
    write_reg("10011", x"00006000", '0');                       -- CRP_L : table @ $00006000
    wait for 100 ns;

    -- ------------------------------------------------------------
    -- Phase B: Sanity -- identity entry $A0xxxxxx
    -- ------------------------------------------------------------
    translate_and_check("A-identity @ $A0000000", x"A0000000", x"A0000000");
    translate_and_check("A-identity @ $A0001234", x"A0001234", x"A0001234");
    translate_and_check("A-identity @ $A1234567", x"A1234567", x"A1234567");

    -- ------------------------------------------------------------
    -- Phase C: Non-identity remap $D0xxxxxx → $00xxxxxx
    -- Each distinct 8 KB page within the 256 MB super-page should get its
    -- own ATC entry with PFA = TA($00000000) + unused_LPA_bits.
    --   $D0001234 → $00001234
    --   $D0003000 → $00003000
    --   $D0123456 → $00123456
    --   $DFFFEFFF → $0FFFEFFF    (top of the super-page)
    -- ------------------------------------------------------------
    translate_and_check("D-remap @ $D0001234", x"D0001234", x"00001234");
    translate_and_check("D-remap @ $D0003000", x"D0003000", x"00003000");
    translate_and_check("D-remap @ $D0123456", x"D0123456", x"00123456");
    translate_and_check("D-remap @ $DFFFEFFF", x"DFFFEFFF", x"0FFFEFFF");

    -- ------------------------------------------------------------
    -- Phase D: Non-identity remap $E0xxxxxx → $50xxxxxx (TA != 0)
    -- Verifies that the TA-plus-offset formula works when TA is non-zero.
    --   $E0001234 → $50001234
    --   $E5ABCDEF → $55ABCDEF
    -- ------------------------------------------------------------
    translate_and_check("E-remap @ $E0001234", x"E0001234", x"50001234");
    translate_and_check("E-remap @ $E5ABCDEF", x"E5ABCDEF", x"55ABCDEF");

    -- ------------------------------------------------------------
    -- Phase F: 4 KB pages (PS=12). Re-program TC and root table, then verify
    -- that:
    --   F1. ATC entries are 4 KB (PS=12) granularity — back-to-back accesses
    --       at $B0001000 and $B0002000 must produce different ATC entries;
    --   F2. Early-termination PFA arithmetic holds at PS=12 for identity and
    --       remapped super-pages;
    --   F3. A 1 MB-aligned offset within a 256 MB super-page still resolves
    --       to the correct 4 KB PFA.
    --
    -- TC = $80C04880 : E=1 SRE=0 FCL=0 PS=12 IS=0 TIA=4 TIB=8 TIC=8 TID=0
    -- sum = 12+4+8+8+0 = 32.  effective_shift at root = 12+8+8+0 = 28
    -- (256 MB super-page, 4 KB leaf pages).
    --
    -- Root entries reused:
    --   Entry 11 ($B0xxxxxx): $B0000061 -- identity
    --   Entry 12 ($C0xxxxxx): $80000061 -- REMAP to $80xxxxxx (TA != 0)
    -- ------------------------------------------------------------
    page_table(6144 + 11) <= x"B0000061";    -- $B0xxxxxx identity
    page_table(6144 + 12) <= x"80000061";    -- $C0xxxxxx -> $80xxxxxx REMAP
    wait for 20 ns;

    write_reg("10000", x"80C04880", '0');   -- TC with PS=12
    -- CRP unchanged; only TC changed.  xlat_cfg_seq bumps on TC write.
    wait for 100 ns;

    -- F1/F2: identity 4 KB super-page, three distinct 4 KB pages within it.
    translate_and_check("4KB-identity @ $B0000000", x"B0000000", x"B0000000");
    translate_and_check("4KB-identity @ $B0001000", x"B0001000", x"B0001000");
    translate_and_check("4KB-identity @ $B0002000", x"B0002000", x"B0002000");
    translate_and_check("4KB-identity @ $B00012AB", x"B00012AB", x"B00012AB");
    translate_and_check("4KB-identity @ $B1234567", x"B1234567", x"B1234567");

    -- F3: remapped super-page, TA != 0, several offsets.
    translate_and_check("4KB-remap @ $C0000000",    x"C0000000", x"80000000");
    translate_and_check("4KB-remap @ $C0000FFF",    x"C0000FFF", x"80000FFF");
    translate_and_check("4KB-remap @ $C0001000",    x"C0001000", x"80001000");
    translate_and_check("4KB-remap @ $C0100000",    x"C0100000", x"80100000");
    translate_and_check("4KB-remap @ $CFFFEFFF",    x"CFFFEFFF", x"8FFFEFFF");

    -- ------------------------------------------------------------
    -- Phase G: Sweep every valid MC68030 page size (PS=8..15 → 256B..32KB).
    -- For each PS we:
    --   1. Rewrite root entry 0 as a short-format early-term page descriptor
    --      with TA=$90000000 (remap, non-zero TA).
    --   2. Program TC with the matching field layout so PS+TIA+TIB+TIC+TID=32.
    --      All configs use TIA=4 (16 root entries) and TID filling in as
    --      needed; effective_shift at root is always 28 (256 MB super-page).
    --   3. Translate three addresses:
    --        a. $00000000   -> $90000000            (super-page base)
    --        b. (1 << PS)   -> $90000000 + (1<<PS)  (second PS-page — proves
    --                                                 distinct ATC entries)
    --        c. $00ABCDEF   -> $90ABCDEF            (arbitrary offset within
    --                                                 the super-page)
    -- Each TC write raises atc_flush_req (no PMOVEFD used) so prior entries
    -- from the previous PS don't leak.
    -- ------------------------------------------------------------

    -- PS=8 (256 B) : TIA=4 TIB=8 TIC=8 TID=4
    page_table(6144 + 0) <= x"90000061";
    wait for 20 ns;
    write_reg("10000", x"80804884", '0');
    wait for 100 ns;
    translate_and_check("PS=8  @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=8  @ $00000100", x"00000100", x"90000100");
    translate_and_check("PS=8  @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- PS=9 (512 B) : TIA=4 TIB=8 TIC=8 TID=3
    page_table(6144 + 0) <= x"90000061";
    wait for 20 ns;
    write_reg("10000", x"80904883", '0');
    wait for 100 ns;
    translate_and_check("PS=9  @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=9  @ $00000200", x"00000200", x"90000200");
    translate_and_check("PS=9  @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- PS=10 (1 KB) : TIA=4 TIB=8 TIC=8 TID=2
    write_reg("10000", x"80A04882", '0');
    wait for 100 ns;
    translate_and_check("PS=10 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=10 @ $00000400", x"00000400", x"90000400");
    translate_and_check("PS=10 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- PS=11 (2 KB) : TIA=4 TIB=8 TIC=8 TID=1
    write_reg("10000", x"80B04881", '0');
    wait for 100 ns;
    translate_and_check("PS=11 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=11 @ $00000800", x"00000800", x"90000800");
    translate_and_check("PS=11 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- PS=12 (4 KB) : TIA=4 TIB=8 TIC=8 TID=0  (redundant w/ Phase F for coverage)
    write_reg("10000", x"80C04880", '0');
    wait for 100 ns;
    translate_and_check("PS=12 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=12 @ $00001000", x"00001000", x"90001000");
    translate_and_check("PS=12 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- PS=13 (8 KB) : TIA=4 TIB=7 TIC=8 TID=0
    write_reg("10000", x"80D04780", '0');
    wait for 100 ns;
    translate_and_check("PS=13 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=13 @ $00002000", x"00002000", x"90002000");
    translate_and_check("PS=13 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- PS=14 (16 KB) : TIA=4 TIB=7 TIC=7 TID=0
    write_reg("10000", x"80E04770", '0');
    wait for 100 ns;
    translate_and_check("PS=14 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=14 @ $00004000", x"00004000", x"90004000");
    translate_and_check("PS=14 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- PS=15 (32 KB) : TIA=4 TIB=6 TIC=7 TID=0
    write_reg("10000", x"80F04670", '0');
    wait for 100 ns;
    translate_and_check("PS=15 @ $00000000", x"00000000", x"90000000");
    translate_and_check("PS=15 @ $00008000", x"00008000", x"90008000");
    translate_and_check("PS=15 @ $00ABCDEF", x"00ABCDEF", x"90ABCDEF");

    -- ------------------------------------------------------------
    -- Phase H: Multi-level walks (no early termination).  Early-term tests
    -- only exercise the W_ROOT -> W_PAGE path; a real OS uses multi-level
    -- tables so the walker descends through W_PTR1 / W_PTR2 before reaching
    -- a DT=01 leaf.  Configuration:
    --   TC = $80C0A800 : E=1 PS=12 TIA=10 TIB=10 TIC=0 TID=0
    --   CRP unchanged (root table still @ $00006000, short-format DT=10)
    --   Root entry 0 = $00007002  -> DT=10 (table pointer, second level @ $7000)
    --   Second-level table at $7000 has 3 leaf entries covering the first
    --   three 4 KB pages of logical $00000xxx range.
    --
    -- Address decomposition (PS=12, TIA=10, TIB=10):
    --   [31:22] = TIA index (10 bits)
    --   [21:12] = TIB index (10 bits)
    --   [11:0]  = page offset
    -- Logical $00000xxx -> TIA=0, TIB=0..2, offset=lowest 12 bits.
    -- ------------------------------------------------------------

    -- Install root entry 0 as a short-format TABLE descriptor (DT=10)
    -- Descriptor bits: [31:4] = table address, [3]=U, [2]=WP, [1:0]=DT=10
    -- $00007002 = address $00007000, DT=10
    page_table(6144 + 0) <= x"00007002";
    -- Clear root entry 0 alias from prior phases (we reuse idx 0 which was a
    -- page descriptor in earlier phases; no other aliases).

    -- Second-level table at $00007000; three entries, each identity-mapped.
    -- Entry 0: logical [$00000000..$00000FFF]  -> physical $00000000, DT=01
    -- Entry 1: logical [$00001000..$00001FFF]  -> physical $00001000
    -- Entry 2: logical [$00002000..$00002FFF]  -> physical $00002000
    -- Each $61 = CI=1, rsvd=1, M=0, U=0, WP=0, DT=01 (short-format page desc)
    page_table(7168 + 0) <= x"00000061";  -- $7000/4 = 7168
    page_table(7168 + 1) <= x"00001061";  -- $7004
    page_table(7168 + 2) <= x"00002061";  -- $7008
    -- Entry 10 for a further-away test: logical [$0000A000..$0000AFFF] -> phys $00800000
    page_table(7168 + 10) <= x"00800061"; -- $7028 -- REMAP
    wait for 20 ns;

    -- Program TC: PS=12, TIA=10, TIB=10, TIC=0, TID=0  →  $80C0AA00
    -- Binary: 1_00000_00_1100_0000_1010_1010_0000_0000
    -- (Check: sum = 12+10+10+0+0 = 32; any other TIB would fail tc_total_bits()
    --  and raise mmu_config_error, making tests fall through as identity.)
    write_reg("10000", x"80C0AA00", '0');
    wait for 100 ns;

    -- Three descents that walk to W_PTR1 and then hit a page descriptor.
    translate_and_check("2-lvl identity @ $00000234", x"00000234", x"00000234");
    translate_and_check("2-lvl identity @ $000012AB", x"000012AB", x"000012AB");
    translate_and_check("2-lvl identity @ $00002ABC", x"00002ABC", x"00002ABC");

    -- Second-level entry 10 is a remap, proving PFA uses the leaf descriptor's
    -- TA (not a super-page base).  Logical $0000A000..$0000AFFF → $00800xxx.
    translate_and_check("2-lvl remap   @ $0000A000", x"0000A000", x"00800000");
    translate_and_check("2-lvl remap   @ $0000A5A5", x"0000A5A5", x"008005A5");

    -- ------------------------------------------------------------
    -- Phase I: Linux m68k SRE=1 routing.  Real Linux arch/m68k/kernel/head.S
    -- programs TC=$82C07760 (E=1, SRE=1, PS=12, TIA=7, TIB=7, TIC=6) so that
    -- supervisor fetches use SRP and user fetches use CRP.  This phase points
    -- SRP and CRP at DIFFERENT root tables so the two paths produce different
    -- PFAs for the same logical address, proving the SRE-driven selection
    -- works in the walker.
    --
    --   CRP -> root table at $00006000 (reused): identity-map $00xxxxxx -> $00xxxxxx
    --   SRP -> root table at $00008000 (new):    remap     $00xxxxxx -> $70xxxxxx
    --
    -- User access (FC=001 = user data):        should follow CRP -> identity
    -- Supervisor access (FC=101 = super data): should follow SRP -> remap
    -- Each root uses short-format early-term DT=01 at entry 0 (32 MB super-page
    -- per TIA=7 entry).
    -- ------------------------------------------------------------

    -- CRP root table: reuse idx 0 with identity early-term descriptor
    page_table(6144 + 0) <= x"00000061";   -- identity $00xxxxxx

    -- SRP root table at $00008000 → page_table index $8000/4 = 8192... but our
    -- array is size 8192, so index 8192 is out of range. Use $00005000 instead
    -- (idx 5120) — still in chip-RAM space, just different from $6000.
    -- Correction: put SRP root at $00004000 (idx 4096).
    page_table(4096 + 0) <= x"70000061";   -- SRP entry 0: $00xxxxxx -> $70xxxxxx
    wait for 20 ns;

    -- Program TC with SRE=1 (Linux's exact value)
    write_reg("10000", x"82C07760", '0');

    -- Point CRP at $00006000 (user root) and SRP at $00004000 (supervisor root)
    write_reg("10011", x"7FFF0002", '1');   -- CRP_H
    write_reg("10011", x"00006000", '0');   -- CRP_L = $6000
    write_reg("10010", x"7FFF0002", '1');   -- SRP_H
    write_reg("10010", x"00004000", '0');   -- SRP_L = $4000
    wait for 100 ns;

    -- Test: user FC=001 should go through CRP (identity)
    --       supervisor FC=101 should go through SRP (remap)
    --
    -- Addresses MUST land inside root entry 0 (bits[31:25]=0, i.e. the 32 MB
    -- window $00000000..$01FFFFFF).  Earlier draft used $0FFFE000 which is
    -- in entry 7 — unconfigured in both roots, so it faulted.
    --
    -- The translate_and_check helper hardcodes fc<="101" (supervisor data), so
    -- we inline a user-FC case below by setting fc before calling req.
    translate_and_check("SRE sup-data @ $01234000", x"01234000", x"71234000");
    translate_and_check("SRE sup-data @ $01FFE000", x"01FFE000", x"71FFE000");

    -- User-FC variant: drive fc="001" directly and repeat the probe.
    wait until rising_edge(clk);
    fc <= "001"; is_insn <= '0'; rw <= '1';
    addr_log <= x"01234000"; req <= '1';
    wait until rising_edge(clk);
    for i in 0 to 200 loop
      exit when busy = '0' or fault = '1';
      wait until rising_edge(clk);
    end loop;
    wait until rising_edge(clk);
    req <= '0';
    if fault = '1' then
      errors <= errors + 1;
      report "[FAIL] SRE user-data @ $01234000 -- fault" severity error;
    elsif addr_phys /= x"01234000" then
      errors <= errors + 1;
      report "[FAIL] SRE user-data @ $01234000 -- want=0x01234000 got=0x" &
             integer'image(to_integer(unsigned(addr_phys))) severity error;
    else
      report "[PASS] SRE user-data @ $01234000 -- phys=0x" &
             integer'image(to_integer(unsigned(addr_phys))) severity note;
    end if;
    for i in 0 to 4 loop wait until rising_edge(clk); end loop;
    -- restore fc for subsequent helper calls
    fc <= "101";

    -- ------------------------------------------------------------
    -- Phase J: Linux 32 MB early-term geometry (effective_shift=25).
    -- Still using TC=$82C07760 from Phase I.  Root TIA=7 means 128 entries,
    -- each covering 2^(12+6+7) = 2^25 = 32 MB.  Multiple PS-sized accesses
    -- inside a single super-page must create separate 4 KB ATC entries with
    -- correct PFAs.
    --
    -- Set CRP root entry 1 = $50000061  → $02000000–$03FFFFFF logical maps to
    -- $50000000–$51FFFFFF physical.
    -- ------------------------------------------------------------
    -- Because TC has SRE=1 and our helper uses FC=101 (supervisor data),
    -- translations route through SRP, so we must also populate the SRP root.
    page_table(6144 + 1) <= x"50000061";   -- CRP root entry 1 (user view)
    page_table(4096 + 1) <= x"50000061";   -- SRP root entry 1 (supervisor view)
    wait for 20 ns;

    translate_and_check("Linux32M @ $02000000", x"02000000", x"50000000"); -- base
    translate_and_check("Linux32M @ $02000FFF", x"02000FFF", x"50000FFF"); -- end of first 4KB page
    translate_and_check("Linux32M @ $02001000", x"02001000", x"50001000"); -- next 4KB page
    translate_and_check("Linux32M @ $02100000", x"02100000", x"50100000"); -- 1 MB in
    translate_and_check("Linux32M @ $03FFE000", x"03FFE000", x"51FFE000"); -- upper end
    translate_and_check("Linux32M @ $03FFF000", x"03FFF000", x"51FFF000"); -- top of 32 MB

    -- ------------------------------------------------------------
    -- Phase K: explicit PFLUSHA via the pflush_req port.  Verify the ATC
    -- flush actually invalidates entries so a subsequent translation re-walks
    -- the (now-modified) page tables.  This is what Linux's `pflusha`
    -- instruction after TC/SRP changes relies on.
    --
    -- Procedure:
    --   1. Translate $02123000 — produces $50123000 (filled into ATC).
    --   2. Modify CRP root entry 1 in memory: $50000061 -> $60000061.
    --      Without a flush the ATC still has the old translation.
    --   3. Translate $02123000 again WITHOUT flushing — should still give
    --      $50123000 (stale ATC hit — this is the expected behaviour).
    --   4. Issue PFLUSHA via pflush_req with pflush_mode="00100".
    --   5. Translate $02123000 — walker re-reads the descriptor and now
    --      yields $60123000.
    -- ------------------------------------------------------------

    -- Step 1: prime the ATC
    translate_and_check("PFLUSHA pre     @ $02123000", x"02123000", x"50123000");

    -- Step 2: mutate the descriptor without PFLUSH (ATC still has old PFA).
    -- Update SRP root (where supervisor-FC walks go) since helper uses FC=101.
    page_table(6144 + 1) <= x"60000061";   -- user view (CRP)
    page_table(4096 + 1) <= x"60000061";   -- supervisor view (SRP)
    wait for 40 ns;

    -- Step 3: re-translate without flush — must hit the stale ATC entry
    translate_and_check("PFLUSHA stale   @ $02123000", x"02123000", x"50123000");

    -- Step 4: issue PFLUSHA.  Brief-word encoding (per PMMU at line ~4098):
    --   pflush_mode = brief[12:10] = "001"  -> PFLUSHA variant
    -- Brief $2400 has bit 10 set and bit 13 set — bit 13 is ignored by the
    -- PMMU decode, so brief[12:10]="001" matches the PFLUSHA arm.
    wait until rising_edge(clk);
    pmmu_brief <= x"2400";  -- same encoding as kernel PFLUSHA opcode F000/2400
    pmmu_addr  <= (others => '0');
    pmmu_fc    <= "000";
    pflush_req <= '1';
    wait until rising_edge(clk);  -- cycle 1: PMMU captures, sets pflush_clear_atc
    wait until rising_edge(clk);  -- cycle 2: flush dispatches when wstate=IDLE
    pflush_req <= '0';
    pmmu_brief <= x"0000";
    wait for 300 ns;  -- let flush settle

    report "[DEBUG] pre-post: page_table(6145)=0x" & hex8(page_table(6145)) &
           " page_table(4097)=0x" & hex8(page_table(4097)) severity note;
    translate_and_check("PFLUSHA post    @ $02123000", x"02123000", x"60123000");

    -- Secondary verification: force an ATC flush via TC rewrite.  Use $20000061
    -- (small TA) to avoid signed-integer overflow when helpers format it.
    page_table(6144 + 1) <= x"20000061";
    page_table(4096 + 1) <= x"20000061";
    wait for 40 ns;
    report "[DEBUG] pre-TC-rewrite: page_table(6145)=0x" & hex8(page_table(6145)) &
           " page_table(4097)=0x" & hex8(page_table(4097)) severity note;
    write_reg("10000", x"82C07760", '0');
    wait for 200 ns;
    report "[DEBUG] pre-TC-flush-post: page_table(6145)=0x" & hex8(page_table(6145)) &
           " page_table(4097)=0x" & hex8(page_table(4097)) severity note;
    translate_and_check("TC-flush post   @ $02123000", x"02123000", x"20123000");

    -- ------------------------------------------------------------
    -- Phase E: Attempt the degenerate TIA=0 config that would, in theory,
    -- make calc_effective_page_shift() return 32 and exercise the
    -- align_addr(x, 32) = 0 branch.
    --
    -- RESULT: the spec-mandated field-sum check (MC68030 UM 9.7.2) rejects
    -- any TC with a leading-zero TI field because tc_total_bits() stops
    -- summing at the first zero, so PS+TIA+... = 8+0 = 8 != 32. That raises
    -- mmu_config_error, which (BUG #445) sticks, clamps tc_en to 0, and
    -- falls translation back to identity.
    --
    -- So: effective_shift=32 is architecturally unreachable with a valid
    -- TC. The tests below confirm identity fallback works, but are NOT
    -- exercising the walker's PFA path. Documenting to prevent future
    -- confusion.
    -- ------------------------------------------------------------
    -- Install root entry 0 as an early-term identity page descriptor
    page_table(6144 + 0) <= x"00000061";
    wait for 20 ns;
    -- Write new TC directly. We know mmu_config_error may be stuck from earlier;
    -- pulse mmu_config_ack to clear it before changing TC, mimicking the kernel's
    -- vector-56 handshake (BUG #445).
    wait until rising_edge(clk);
    mmu_config_ack <= '1';
    wait until rising_edge(clk);
    mmu_config_ack <= '0';
    wait for 20 ns;
    write_reg("10011", x"7FFF0002", '1');   -- CRP_H again
    write_reg("10011", x"00006000", '0');   -- CRP_L
    write_reg("10000", x"80800888", '0');   -- TC with TIA=0, sum=32
    wait for 100 ns;

    -- With effective_shift=32, the entire 4 GB range collapses onto
    -- physical via TA=0 -> identity. Any address should map to itself.
    -- Note: these pass only because MMU is disabled via mmu_config_error.
    translate_and_check("TIA0 disabled-MMU @ $12345678", x"12345678", x"12345678");
    translate_and_check("TIA0 disabled-MMU @ $DEADBEEF", x"DEADBEEF", x"DEADBEEF");
    translate_and_check("TIA0 disabled-MMU @ $00000000", x"00000000", x"00000000");

    wait for 200 ns;

    if errors = 0 then
      report "=== RESULT: PASS (0 failures) ===" severity note;
    else
      report "=== RESULT: FAIL (" & integer'image(errors) & " failures) ==="
        severity error;
    end if;
    test_running <= false;
    wait;
  end process;

end architecture;
