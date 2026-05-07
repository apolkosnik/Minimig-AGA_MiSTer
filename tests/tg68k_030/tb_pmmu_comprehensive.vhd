-- tb_pmmu_comprehensive.vhd
-- End-to-end PMMU coverage that targets areas the other benches don't reach:
--   F. Fault MMUSR bit encoding + fault_addr/fc/rw latching
--   L. Long-format (DT=11) descriptors
--   M. Limit checking at boundary indices (L/U=0 and L/U=1)
--   T. TTR matching nuances: FC mask, RWM bit, CI output
--   A. Attribute accumulation (WP across levels, M-bit with WP)
--
-- Not re-doing what other maintained benches already cover:
--   * PMOVE / PTEST / PFLUSH / PLOAD EA-mode sweeps (tb_*_all_modes.vhd)
--   * PS sweep / SRE / early-term arithmetic (tb_pmmu_early_term_remap.vhd)
--   * Indirect descriptors (tb_indirect_descriptor.vhd)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_pmmu_comprehensive is
end tb_pmmu_comprehensive;

architecture tb of tb_pmmu_comprehensive is
  signal clk          : std_logic := '0';
  signal nreset       : std_logic := '0';
  constant CLK_PERIOD : time := 10 ns;
  signal test_running : boolean := true;

  signal reg_we   : std_logic := '0';
  signal reg_re   : std_logic := '0';
  signal reg_sel  : std_logic_vector(4 downto 0) := (others => '0');
  signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rdat : std_logic_vector(31 downto 0);
  signal reg_part : std_logic := '0';
  signal reg_fd   : std_logic := '0';

  signal ptest_req  : std_logic := '0';
  signal pflush_req : std_logic := '0';
  signal pload_req  : std_logic := '0';
  signal pmmu_fc    : std_logic_vector(2 downto 0) := "000";
  signal pmmu_addr  : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');

  signal req          : std_logic := '0';
  signal is_insn      : std_logic := '0';
  signal rw           : std_logic := '1';
  signal fc           : std_logic_vector(2 downto 0) := "101";
  signal addr_log     : std_logic_vector(31 downto 0) := (others => '0');
  signal addr_phys    : std_logic_vector(31 downto 0);
  signal cache_inhibit: std_logic;
  signal write_protect: std_logic;
  signal fault        : std_logic;
  signal fault_status : std_logic_vector(31 downto 0);
  signal fault_addr   : std_logic_vector(31 downto 0);
  signal fault_fc     : std_logic_vector(2 downto 0);
  signal fault_rw     : std_logic;
  signal fault_is_insn: std_logic;
  signal tc_enable    : std_logic;

  signal mem_req  : std_logic;
  signal mem_we   : std_logic;
  signal mem_addr : std_logic_vector(31 downto 0);
  signal mem_wdat : std_logic_vector(31 downto 0);
  signal mem_ack  : std_logic := '0';
  signal mem_berr : std_logic := '0';
  signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
  signal busy     : std_logic;

  signal mmu_config_err : std_logic;
  signal mmu_config_ack : std_logic := '0';
  signal ptest_desc_addr : std_logic_vector(31 downto 0);

  type mem_t is array(0 to 16383) of std_logic_vector(31 downto 0);
  -- pt must be a shared variable (not a signal): both mem_sim (for walker
  -- U/M-bit writebacks) and test_proc (for descriptor setup) need to write
  -- to it.  A signal with two drivers resolves per-bit and produces 'X' on
  -- any differing-bit overlap, which makes descriptors look invalid (DT='X').
  shared variable pt : mem_t := (others => (others => '0'));

  -- Injectable bus-error: fire BERR on the Nth walker access.  -1 = disabled.
  signal berr_on_nth : integer := -1;
  signal berr_seen   : integer := 0;

  -- Writeback capture: record the walker's U/M-bit descriptor writebacks so
  -- tests can assert the exact bits the walker set.
  signal wb_count   : integer := 0;
  signal wb_last_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal wb_last_data : std_logic_vector(31 downto 0) := (others => '0');

  signal errors : integer := 0;
  signal checks : integer := 0;

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

  function hex4(v : std_logic_vector) return string is
    constant h : string := "0123456789ABCDEF";
    variable vv : std_logic_vector(15 downto 0) := v;
    variable r  : string(1 to 4);
  begin
    for i in 0 to 3 loop
      r(i+1) := h(to_integer(unsigned(vv(15-4*i downto 12-4*i))) + 1);
    end loop;
    return r;
  end function;

begin
  clk_gen : process
  begin
    while test_running loop
      clk <= '0'; wait for CLK_PERIOD/2;
      clk <= '1'; wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  uut : entity work.TG68K_PMMU_030
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

  -- Memory model with optional Nth-access BERR injection
  mem_sim : process(clk)
    variable idx : integer;
  begin
    if rising_edge(clk) then
      if nreset = '0' then
        mem_ack  <= '0';
        mem_rdat <= (others => '0');
        mem_berr <= '0';
      else
        mem_berr <= '0';
        if mem_req = '1' and mem_ack = '0' then
          berr_seen <= berr_seen + 1;
          if berr_on_nth >= 0 and berr_seen = berr_on_nth then
            mem_berr <= '1';
            mem_ack  <= '1';
            mem_rdat <= (others => '0');
          else
            idx := to_integer(unsigned(mem_addr(15 downto 2)));
            if mem_we = '1' then
              -- Walker descriptor writeback (U / M bit update).
              if idx < 16384 then
                pt(idx) := mem_wdat;
              end if;
              wb_count     <= wb_count + 1;
              wb_last_addr <= mem_addr;
              wb_last_data <= mem_wdat;
            else
              if idx < 16384 then
                mem_rdat <= pt(idx);
              else
                mem_rdat <= (others => '0');
              end if;
            end if;
            mem_ack <= '1';
          end if;
        elsif mem_req = '0' then
          mem_ack <= '0';
        end if;
      end if;
    end if;
  end process;

  test_proc : process
    --------------------------------------------------------------------
    -- Helpers
    --------------------------------------------------------------------
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

    -- Issue a translate request; wait for busy=0 or fault=1; optionally check
    -- expected PFA.  When expect_fault=true, expect fault=1 with given MMUSR
    -- bit(s) set; PFA is ignored.
    procedure probe(
      tname : string;
      log   : std_logic_vector(31 downto 0);
      use_fc: std_logic_vector(2 downto 0);
      use_rw: std_logic;   -- '1'=read '0'=write
      expect_phys   : std_logic_vector(31 downto 0);
      expect_fault  : boolean;
      expect_mmusr  : std_logic_vector(15 downto 0) := (others => '0');
      mmusr_mask    : std_logic_vector(15 downto 0) := (others => '0')
    ) is
      variable masked_mmusr : std_logic_vector(15 downto 0);
    begin
      wait until rising_edge(clk);
      addr_log <= log;
      fc <= use_fc;
      is_insn <= '0';
      rw <= use_rw;
      req <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      for i in 0 to 400 loop
        exit when busy = '0' or fault = '1';
        wait until rising_edge(clk); wait for 1 ns;
      end loop;
      wait until rising_edge(clk); wait for 1 ns;
      req <= '0';

      checks <= checks + 1;
      if expect_fault then
        if fault /= '1' then
          errors <= errors + 1;
          report "[FAIL] " & tname & ": expected fault, got phys=0x" & hex8(addr_phys)
            severity error;
        else
          -- MMUSR is in fault_status lower 16 bits
          masked_mmusr := fault_status(15 downto 0) and mmusr_mask;
          if masked_mmusr /= (expect_mmusr and mmusr_mask) then
            errors <= errors + 1;
            report "[FAIL] " & tname & ": MMUSR mismatch want=0x" &
                   hex4(expect_mmusr and mmusr_mask) & " got=0x" & hex4(masked_mmusr) &
                   " full_status=0x" & hex8(fault_status)
              severity error;
          else
            report "[PASS] " & tname & ": fault MMUSR=0x" & hex4(fault_status(15 downto 0))
              severity note;
          end if;
        end if;
      else
        if fault = '1' then
          errors <= errors + 1;
          report "[FAIL] " & tname & ": unexpected fault, status=0x" & hex8(fault_status)
            severity error;
        elsif addr_phys /= expect_phys then
          errors <= errors + 1;
          report "[FAIL] " & tname & ": want=0x" & hex8(expect_phys) & " got=0x" & hex8(addr_phys)
            severity error;
        else
          report "[PASS] " & tname & ": phys=0x" & hex8(addr_phys)
            severity note;
        end if;
      end if;
      for i in 0 to 4 loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure ack_config_error is
    begin
      wait until rising_edge(clk);
      mmu_config_ack <= '1';
      wait until rising_edge(clk);
      mmu_config_ack <= '0';
      wait for 50 ns;
    end procedure;

    procedure pflusha is
    begin
      wait until rising_edge(clk);
      pmmu_brief <= x"2400";  -- brief[12:10] = "001" => PFLUSHA
      pflush_req <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      wait until rising_edge(clk); wait for 1 ns;
      pflush_req <= '0';
      pmmu_brief <= x"0000";
      wait for 300 ns;
    end procedure;

    -- Masks:  B(15) L(14) S(13) rsvd(12) W(11) I(10) M(9) rsvd(8:7) T(6) rsvd(5:3) N(2:0)
    constant MMUSR_B : std_logic_vector(15 downto 0) := x"8000";
    constant MMUSR_L : std_logic_vector(15 downto 0) := x"4000";
    constant MMUSR_S : std_logic_vector(15 downto 0) := x"2000";
    constant MMUSR_W : std_logic_vector(15 downto 0) := x"0800";
    constant MMUSR_I : std_logic_vector(15 downto 0) := x"0400";

    variable walks_before : integer;
    variable walks_after  : integer;
    variable log_addr     : std_logic_vector(31 downto 0);
    variable want_phys    : std_logic_vector(31 downto 0);
    variable wb_snap      : integer;
    variable wb_snap_data : std_logic_vector(31 downto 0);

  begin
    nreset <= '0';
    wait for 100 ns;
    nreset <= '1';
    wait for 100 ns;

    report "==== tb_pmmu_comprehensive ====" severity note;

    ---------------------------------------------------------------
    -- COMMON SETUP: simple 2-level short-format tree.
    -- TC: PS=12 TIA=10 TIB=10 TIC=0 TID=0  sum=32  -> $80C0AA00
    -- CRP: short-format table at $00001000, L/U=0, LIMIT=$7FFF, DT=10 -> $7FFF0002 / $00001000
    -- Root table at $1000: entries describe the level-1 table or early-term pages.
    ---------------------------------------------------------------
    write_reg("10000", x"80C0AA00", '0');
    write_reg("10011", x"7FFF0002", '1');
    write_reg("10011", x"00001000", '0');
    write_reg("10010", x"7FFF0002", '1');
    write_reg("10010", x"00001000", '0');
    wait for 50 ns;

    ---------------------------------------------------------------
    -- PHASE F: Fault MMUSR bit encoding
    --
    -- F1: mid-walk DT=00 (invalid) at level 0 (root entry). Logical $01000000
    --     has TIA = bits[31:22] = 4.  Root entry 4 left as DT=00 (zero default).
    ---------------------------------------------------------------
    -- Default zeroed descriptor at root entry 4 = DT=00.  Trigger the fault.
    probe("F1 root-DT=00 @ $01000000", x"01000000", "101", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);
    -- fault_addr should latch the faulting logical address.
    if fault_addr /= x"01000000" then
      errors <= errors + 1;
      report "[FAIL] F1-latch: fault_addr=0x" & hex8(fault_addr) severity error;
    else
      checks <= checks + 1;
      report "[PASS] F1-latch: fault_addr=0x" & hex8(fault_addr) severity note;
    end if;

    -- F2: mid-walk DT=00 at level 1.  Root entry 8 points to a level-1 table
    --     at $00002000, but that table's entry 3 is zero (DT=00).
    --     Logical $02003000 has TIA=8, TIB=3 -> hits the zero entry.
    pt(1024 + 8) := x"00002002";   -- root[8]: table ptr to $2000, DT=10
    -- level-1 entry 3 stays zero (default DT=00)
    wait for 20 ns;
    pflusha;
    probe("F2 level-1 DT=00 @ $02003000", x"02003000", "101", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);

    -- F3: write to write-protected (WP=1) page.  Install identity page with WP bit set.
    --     Descriptor = $04000065  (TA=$04000000, CI=1, rsvd=1, WP=1 bit2, DT=01)
    --     Actually $65 = 0110 0101: bit6 CI=1, bit5 rsvd=1, bit4 M=0, bit3 U=0, bit2 WP=1, bits1:0 DT=01
    pt(1024 + 16) := x"04000065";   -- root[16], logical $04xxxxxx->$04xxxxxx WP=1
    wait for 20 ns;
    pflusha;
    -- Read should succeed (WP doesn't block reads)
    probe("F3a WP=1 read  @ $04001000", x"04001000", "101", '1',
          x"04001000", false);
    -- Write must fault
    probe("F3b WP=1 write @ $04001000", x"04001000", "101", '0',
          (others => '0'), true, MMUSR_W, MMUSR_W);

    -- F4: user (FC=001) access to supervisor-only (S=1) page.  Short-format
    --     descriptors have no S bit, so use a LONG-format page descriptor.
    --     Long descriptor 8-byte: HIGH word has S at bit 8.
    --     HIGH: $00000101 (DT=01, bit 8 S=1)  (bit1:0=01, bit8=1)
    --     LOW : $05000000 (physical base)
    --
    --     First, convert root entry 20 (logical $05xxxxxx) to DT=11 (long table).
    --     Actually simpler: install a long-format page descriptor via the
    --     parent having DT=11 stride.
    --     To keep this bench simple, build a long TABLE at root[20] that points
    --     into a long sub-table whose only entry is an S=1 early-term page.
    --
    --     Skipping: long-format S-violation is covered by Phase L below.
    --     For F4, set walker to fail on supervisor-violation via a short-format
    --     page descriptor with WP+S is unsupported.  Move on.

    -- F5: bus error during walk.  Set up a 2-level walk where the ROOT
    -- descriptor is a valid table pointer and the level-1 access hits BERR.
    -- Address $02000000 goes: root[8] (valid table ptr from F2) → level-1[0]
    -- (which we'll inject BERR on).  This removes ambiguity: the walker has
    -- valid descriptor data for the root and only the second mem access
    -- returns BERR.
    pt(1024 + 8) := x"00002002";  -- root[8] valid table ptr @ $2000 (reuse from F2)
    -- level-1 entry 0 at $2000+0*4: we'd like it to be a valid page but the
    -- BERR injection short-circuits the fetch before the data matters.
    pt(2048 + 0) := x"0A000061";  -- valid short-format page if BERR weren't firing
    wait for 20 ns;
    pflusha;
    wait until rising_edge(clk);
    -- Fire BERR on the very next walker access after now. With default zero
    -- level-1 entries previously untouched and our new setup fresh, the fresh
    -- walk will produce exactly two mem reads (root + level-1).  Arm on
    -- berr_seen+2 so BERR fires on the level-1 read.
    berr_on_nth <= berr_seen + 2;
    wait until rising_edge(clk);
    probe("F5 walker BERR  @ $02000000", x"02000000", "101", '1',
          (others => '0'), true, MMUSR_B, MMUSR_B);
    berr_on_nth <= -1;
    pflusha;

    -- F6: fault_fc latch
    if fault_fc /= "101" then
      errors <= errors + 1;
      report "[FAIL] F6 fault_fc=0x" & integer'image(to_integer(unsigned(fault_fc)))
        severity error;
    else
      checks <= checks + 1;
      report "[PASS] F6 fault_fc latched supervisor=101" severity note;
    end if;

    ---------------------------------------------------------------
    -- PHASE L: Long-format (DT=11) descriptors
    --
    -- Rebuild root with DT=11 so every entry is 8 bytes.
    -- CRP long-format: L/U[31], Limit[30:16], rsvd[15:2], DT[1:0]=11
    -- For no-limit long root: $7FFF0003.  LOW = table address.
    ---------------------------------------------------------------
    pflusha;
    write_reg("10011", x"7FFF0003", '1');    -- CRP_H with DT=11
    write_reg("10011", x"00003000", '0');    -- CRP_L: long root table at $3000
    write_reg("10010", x"7FFF0003", '1');    -- SRP_H
    write_reg("10010", x"00003000", '0');    -- SRP_L
    wait for 50 ns;

    -- Long-format root table entries are 8 bytes each (HIGH + LOW).
    -- With TC as before (PS=12, TIA=10, TIB=10), root entry index 2 is at
    -- byte offset $3000 + 2*8 = $3010 -> pt index 3074 (HIGH) and 3075 (LOW).
    --
    -- L1: long-format early-term page descriptor at root entry 2.
    --     HIGH = DT=01 (page), bit 6 CI=1, L/U=0 LIMIT=$7FFF (no limit
    --            check) -- without this the walker checks TIB index against
    --            zero and faults for any non-zero TIB.
    --     LOW  = physical base = $30000000
    pt(3072 + 2*2)     := x"7FFF0041";  -- entry 2 HIGH at $3010
    pt(3072 + 2*2 + 1) := x"30000000";  -- entry 2 LOW  at $3014
    wait for 20 ns;
    pflusha;
    -- Effective shift at root for this config: PS+TIB+TIC+TID = 12+10+0+0 = 22
    -- So each root entry covers 4 MB. Entry 2 covers $00800000-$00BFFFFF logically.
    -- Wait -- with DT=11 at root, each entry is 8 bytes so stride×index multiplies
    -- by 8, but the logical address partition is unchanged: TIA still takes the
    -- top 10 bits.  Logical $00800000 is TIA index 2.  -> PFA = $30000000.
    probe("L1 long early-term @ $00800000", x"00800000", "101", '1',
          x"30000000", false);
    probe("L1 long early-term @ $00801234", x"00801234", "101", '1',
          x"30001234", false);

    -- L1b: cache_inhibit should follow descriptor CI bit on the previous probe.
    if cache_inhibit /= '1' then
      errors <= errors + 1;
      report "[FAIL] L1b: cache_inhibit=0 (expected 1 from long-format CI)"
        severity error;
    else
      checks <= checks + 1;
      report "[PASS] L1b: cache_inhibit=1 from long CI bit" severity note;
    end if;

    -- L2: long-format table descriptor with short-format page underneath
    --     Root entry 3 HIGH: DT=11 (long table), no limit (L/U=0, LIMIT=$7FFF)
    --      -> $7FFF0003
    --     Root entry 3 LOW: second-level table at $00004000
    --     Second-level table has short-format entries (DT=10 parent means short
    --     children)...  Actually with parent DT=11, children are 8-byte long.
    --     So the second level must also be long-format.
    pt(3072 + 3*2)     := x"7FFF0003";  -- entry 3 HIGH: long table, no limit
    pt(3072 + 3*2 + 1) := x"00004000";  -- entry 3 LOW:  table at $4000

    -- Level-1 long-format table at $4000, 1024 entries × 8 bytes each.
    -- Logical $00C02000 -> TIA=3 (bits[31:22]=3), TIB=2 (bits[21:12]=2).
    -- Level-1 entry 2 at $4000 + 2*8 = $4010.  pt index = $4010/4 = 4100.
    -- Install a long-format early-term page: HIGH=DT=01, LOW=TA=$40000000.
    pt(4096 + 2*2)     := x"00000001";  -- HIGH: DT=01, no attrs
    pt(4096 + 2*2 + 1) := x"40000000";  -- LOW: phys base
    wait for 20 ns;
    pflusha;
    probe("L2 long->long page @ $00C02000", x"00C02000", "101", '1',
          x"40000000", false);
    probe("L2 long->long page @ $00C02ABC", x"00C02ABC", "101", '1',
          x"40000ABC", false);

    -- L3: long-format with S bit (supervisor-only violation).
    --     Root entry 4 HIGH: DT=01 early-term long page with S bit (bit 8) set
    --     S-violation: user (FC=001) access should fault with MMUSR.S=1
    pt(3072 + 4*2)     := x"7FFF0101";  -- L/U=0 LIMIT=$7FFF, S=1 (bit 8), DT=01
    pt(3072 + 4*2 + 1) := x"50000000";  -- TA=$50000000
    wait for 20 ns;
    pflusha;
    -- Supervisor (FC=101) should still succeed
    probe("L3a sup->S=1 page @ $01000000", x"01000000", "101", '1',
          x"50000000", false);
    -- User (FC=001) should fault with MMUSR.S=1
    pflusha;
    probe("L3b usr->S=1 page @ $01000000", x"01000000", "001", '1',
          (others => '0'), true, MMUSR_S, MMUSR_S);

    ---------------------------------------------------------------
    -- PHASE M: Limit checking (long-format only -- short has no limit)
    ---------------------------------------------------------------
    -- Reuse long root.  Root entry 5 is a long TABLE with limit.
    -- L/U=0 UPPER limit: index <= LIMIT is valid, index > LIMIT faults.
    -- Install entry 5 HIGH with L/U=0, LIMIT=3.
    --   HIGH = $0003_0003   (L/U=0, LIMIT=3, rsvd=0, DT=11)
    pt(3072 + 5*2)     := x"00030003";
    pt(3072 + 5*2 + 1) := x"00005000";   -- level-1 table at $5000
    -- Populate level-1 table entries 0..3 with valid long early-term pages.
    -- Each entry is 8 bytes. Entry i at $5000 + i*8.
    for i in 0 to 3 loop
      pt(5120 + i*2)     := x"00000001";                              -- HIGH DT=01
      pt(5120 + i*2 + 1) := std_logic_vector(to_unsigned(16#60000000# + i*16#100000#, 32));  -- TA=$60000000+i*1MB
    end loop;
    wait for 20 ns;
    pflusha;

    -- Address encoding with TC PS=12 TIA=10 TIB=10: bits[31:22]=TIA, bits[21:12]=TIB.
    -- TIA=5 super-page base = (5 << 22) = $01400000.  TIB=i bit-offset = (i << 12).
    --
    -- Logical $01400000 -> TIA=5, TIB=0.  Index 0 at L/U=0 LIMIT=3 is valid.
    probe("M1 L/U=0 idx=0 @ $01400000", x"01400000", "101", '1',
          x"60000000", false);
    pflusha;
    -- Logical $01403000 -> TIA=5, TIB=3.  Index 3 == LIMIT=3, still valid.
    probe("M2 L/U=0 idx=3 @ $01403000", x"01403000", "101", '1',
          x"60300000", false);
    pflusha;
    -- Logical $01404000 -> TIA=5, TIB=4.  Index 4 > LIMIT=3 -> L violation.
    probe("M3 L/U=0 idx=4 fault", x"01404000", "101", '1',
          (others => '0'), true, MMUSR_L, MMUSR_L);

    -- L/U=1 LOWER limit: index >= LIMIT is valid, index < LIMIT faults.
    --   HIGH = $80030003  (L/U=1, LIMIT=3, DT=11)
    pt(3072 + 6*2)     := x"80030003";
    pt(3072 + 6*2 + 1) := x"00005000";   -- reuse same level-1 table
    wait for 20 ns;
    pflusha;
    -- TIA=6 super-page base = (6 << 22) = $01800000.
    -- Logical $01803000 -> TIA=6, TIB=3 (= LIMIT, valid).
    probe("M4 L/U=1 idx=3 @ $01803000", x"01803000", "101", '1',
          x"60300000", false);
    pflusha;
    -- Logical $01802000 -> TIA=6, TIB=2 (< LIMIT=3, fault).
    probe("M5 L/U=1 idx=2 fault", x"01802000", "101", '1',
          (others => '0'), true, MMUSR_L, MMUSR_L);

    ---------------------------------------------------------------
    -- PHASE T: TTR matching nuances.
    -- Disable main MMU by writing TC with E=0, but keep TTRs live.
    -- Actually TC.E=0 disables table translation but TTRs still operate.
    ---------------------------------------------------------------
    -- T1: TT0 with address base $80, mask $FF for logical match $80xxxxxx only
    --     Fields: addr_base[31:24] | addr_mask[23:16] | E[15] | CI[10] | RW[9] | RWM[8] | FC_base[6:4] | FC_mask[2:0]
    --     For match on $80xxxxxx: base=$80, mask=$00 (exact)
    --     E=1, CI=0, RW ignored (RWM=1), FC mask=111 (any FC)
    --     TT0 = 8000_8007  (wait -- layout: [31:24]=80, [23:16]=00, [15]=E=1, [10]=CI=0,
    --            [9]=RW=0, [8]=RWM=1, [6:4]=000, [2:0]=111)
    --     TT0 = 1000_0000 0000_0000 1000_0001 0000_0111
    --         = 80008107
    write_reg("00010", x"80008107", '0');
    wait for 20 ns;
    pflusha;
    -- Access within $80xxxxxx range with any FC
    probe("T1 TTR0 sup @ $80001234", x"80001234", "101", '1', x"80001234", false);
    probe("T1 TTR0 usr @ $80001234", x"80001234", "001", '1', x"80001234", false);
    -- Access outside $80 range should NOT match TT0 -> falls through to table walk
    -- Root entry 32 ($82000000 / TIA=32) is unconfigured -> fault
    pflusha;
    probe("T1 non-match $82000000", x"82000000", "101", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);

    -- T2: TT0 with FC mask limiting to supervisor only
    --     FC base=101 (supervisor data), FC mask=000 (exact FC)
    --     TT0 = 8000_8150  (bits[6:4]=101, bits[2:0]=000)
    --     = 1000_0000 0000_0000 1000_0001 0101_0000 = 80008150
    write_reg("00010", x"80008150", '0');
    wait for 20 ns;
    pflusha;
    probe("T2 TTR0 sup match  @ $80001000", x"80001000", "101", '1', x"80001000", false);
    pflusha;
    -- user (FC=001) does NOT match (FC mask=000, exact required)
    probe("T2 TTR0 usr no-match @ $80001000", x"80001000", "001", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);

    -- T3: RWM=0 means match only one direction.
    --     TT0 with RWM=0, RW=1 (reads only), no FC mask
    --     TT0 = 8000_8207 = 1000_0000 0000_0000 1000_0010 0000_0111
    write_reg("00010", x"80008207", '0');
    wait for 20 ns;
    pflusha;
    probe("T3 RWM=0 RW=1 read  @ $80001000", x"80001000", "101", '1', x"80001000", false);
    pflusha;
    -- write doesn't match (TTR says reads only), falls through to walk -> fault
    probe("T3 RWM=0 RW=1 write @ $80001000", x"80001000", "101", '0',
          (others => '0'), true, MMUSR_I, MMUSR_I);

    -- T4: TTR with CI=1 -> cache_inhibit output asserts
    --     TT0 = 80008507 (RWM=1, CI=1 at bit 10, FC mask=111)
    --     bit 10 = CI, so byte 1 bit 2 = 1.  $85 = 1000 0101.
    --     = 1000_0000 0000_0000 1000_0101 0000_0111 = 80008507
    write_reg("00010", x"80008507", '0');
    wait for 20 ns;
    pflusha;
    probe("T4 TTR0 CI=1 @ $80001000", x"80001000", "101", '1', x"80001000", false);
    if cache_inhibit /= '1' then
      errors <= errors + 1;
      report "[FAIL] T4 cache_inhibit=0 (expected 1 from TTR CI)"
        severity error;
    else
      checks <= checks + 1;
      report "[PASS] T4 TTR CI=1 -> cache_inhibit=1" severity note;
    end if;

    -- Disable TT0 before moving on
    write_reg("00010", x"00000000", '0');
    wait for 50 ns;

    ---------------------------------------------------------------
    -- PHASE A: Attribute accumulation
    --
    -- A1: WP in parent table descriptor propagates to child page (BUG #438).
    --     Build: root entry 7 (long table) HIGH with WP=1, points to a
    --     level-1 table whose entry 0 is a page with WP=0.  Write must fault.
    --
    -- Root long-format table descriptor HIGH:
    --   L/U=0, LIMIT=7FFF, rsvd=0, WP=1 (bit 2), DT=11
    --   $7FFF_0007
    ---------------------------------------------------------------
    pt(3072 + 7*2)     := x"7FFF0007";   -- long table with WP=1
    pt(3072 + 7*2 + 1) := x"00007000";   -- table at $7000
    -- Level-1 entry 0: long early-term page at TA=$70000000, WP=0 (clean page)
    pt(7168 + 0*2)     := x"00000001";   -- HIGH DT=01, no attrs
    pt(7168 + 0*2 + 1) := x"70000000";   -- LOW TA
    wait for 20 ns;
    pflusha;
    -- Logical $01C00000 -> TIA=7, TIB=0.  Read OK.
    probe("A1a WP-accum read   @ $01C00000", x"01C00000", "101", '1',
          x"70000000", false);
    pflusha;
    -- Write must fault even though leaf page has WP=0, because parent had WP=1.
    probe("A1b WP-accum write  @ $01C00000", x"01C00000", "101", '0',
          (others => '0'), true, MMUSR_W, MMUSR_W);

    -- A2 check: the helper output also sets write_protect on a clean read
    -- (cached WP bit on ATC entry).
    pflusha;
    probe("A2a prime read", x"01C00000", "101", '1', x"70000000", false);
    if write_protect /= '1' then
      errors <= errors + 1;
      report "[FAIL] A2a write_protect=0 (expected 1 from accumulated WP)"
        severity error;
    else
      checks <= checks + 1;
      report "[PASS] A2a write_protect asserted from accumulated parent WP" severity note;
    end if;

    -- A3: Once a supervisor violation has been detected at an earlier
    -- long-format table descriptor, WinUAE keeps walking but suppresses U-bit
    -- writeback for later descriptors too.  This uses a 3-level long tree so
    -- the second table descriptor is reached after the parent S violation.
    write_reg("10000", x"80C0A910", '0');      -- PS=12, TIA=10, TIB=9, TIC=1
    wait for 50 ns;
    pt(3072 + 8*2)      := x"7FFF0103";  -- root[8]: long table, S=1, U=0
    pt(3072 + 8*2 + 1)  := x"00008000";  -- -> L1 table
    pt(8192 + 0*2)      := x"7FFF0003";  -- L1[0]: long table, S=0, U=0
    pt(8192 + 0*2 + 1)  := x"00009000";  -- -> L2 table
    pt(9216 + 0*2)      := x"00000001";  -- L2[0]: page
    pt(9216 + 0*2 + 1)  := x"80000000";  -- TA=$80000000
    wait for 40 ns;
    pflusha;
    wb_snap := wb_count;
    probe("A3 accumulated S suppresses later U writeback", x"02000000", "001", '1',
          (others => '0'), true, MMUSR_S, MMUSR_S);
    wait for 100 ns;
    checks <= checks + 1;
    if (wb_count - wb_snap) /= 0 then
      errors <= errors + 1;
      report "[FAIL] A3 expected 0 U writebacks after accumulated S violation, got " &
             integer'image(wb_count - wb_snap) & " last=0x" & hex8(wb_last_data)
        severity error;
    else
      report "[PASS] A3 accumulated supervisor violation suppressed descriptor U writeback"
        severity note;
    end if;

    ---------------------------------------------------------------
    -- PHASE R: ATC replacement under pressure.
    -- ATC has 22 entries.  We fill 22, then access 8 more (total 30 distinct
    -- PS-sized pages).  After eviction the oldest 8 entries are gone, but
    -- every re-access must still produce the CORRECT PFA because the walker
    -- can re-walk on ATC miss.  If pseudo-LRU mismanages eviction we'd see
    -- wrong PFAs.
    --
    -- Reset to short-format CRP and simple 2-level TC.
    ---------------------------------------------------------------
    pflusha;
    write_reg("10011", x"7FFF0002", '1');      -- CRP_H short-format
    write_reg("10011", x"00001000", '0');      -- CRP_L = $1000
    write_reg("10010", x"7FFF0002", '1');      -- SRP_H
    write_reg("10010", x"00001000", '0');      -- SRP_L = $1000
    write_reg("10000", x"80C0AA00", '0');      -- TC: PS=12 TIA=10 TIB=10
    wait for 100 ns;
    pflusha;

    -- Root entry 25 = early-term page at $40000000 (remap super-page).
    -- Covers logical $06400000..$067FFFFF (4 MB) to physical $40000000..$403FFFFF.
    pt(1024 + 25) := x"40000061";
    wait for 20 ns;
    pflusha;

    -- Access 30 distinct 4 KB pages within the super-page.
    -- Logical $06400000 + i*$1000 -> expected PFA $40000000 + i*$1000.
    for i in 0 to 29 loop
      log_addr  := std_logic_vector(to_unsigned(16#06400000# + i*16#1000#, 32));
      want_phys := std_logic_vector(to_unsigned(16#40000000# + i*16#1000#, 32));
      probe("R fill i=" & integer'image(i), log_addr, "101", '1',
            want_phys, false);
    end loop;

    -- Re-access entry 0 (almost certainly evicted) and entry 29 (most recent,
    -- should still be cached or fresh re-walk).  Both must produce correct PFA.
    probe("R re-access evicted i=0",  x"06400000", "101", '1', x"40000000", false);
    probe("R re-access recent  i=29", x"0641D000", "101", '1', x"4001D000", false);
    -- Mid-range probe
    probe("R re-access mid     i=15", x"0640F000", "101", '1', x"4000F000", false);

    ---------------------------------------------------------------
    -- PHASE S: Sticky fault replay via cached ATC fault entry (BUG #436).
    --
    -- First access to an invalid descriptor faults and the walker caches the
    -- fault in the ATC.  A second access to the same logical page should
    -- replay the cached fault WITHOUT re-walking (no increase in mem_req
    -- count).  PFLUSHA should clear the sticky entry so a third access
    -- re-walks.
    ---------------------------------------------------------------
    pflusha;

    -- Logical $07800000 -> TIA=30.  Root entry 30 is default zero -> DT=00.
    -- First access: walker runs, faults, caches sticky fault ATC entry.
    walks_before := berr_seen;
    probe("S first fault @ $07800000", x"07800000", "101", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);
    walks_after := berr_seen;
    checks <= checks + 1;
    if walks_after = walks_before then
      errors <= errors + 1;
      report "[FAIL] S1 expected walker activity on first fault" severity error;
    else
      report "[PASS] S1 first fault triggered walker (" &
             integer'image(walks_after - walks_before) & " mem accesses)"
        severity note;
    end if;

    -- Second access: should hit sticky fault cache, no new walker activity.
    walks_before := berr_seen;
    probe("S replay fault @ $07800000", x"07800000", "101", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);
    walks_after := berr_seen;
    checks <= checks + 1;
    if walks_after /= walks_before then
      errors <= errors + 1;
      report "[FAIL] S2 sticky fault re-walked (" &
             integer'image(walks_after - walks_before) & " mem accesses; expected 0)"
        severity error;
    else
      report "[PASS] S2 sticky fault replayed from ATC (no walker activity)"
        severity note;
    end if;

    -- PFLUSHA + re-access should re-walk.
    pflusha;
    walks_before := berr_seen;
    probe("S post-flush fault @ $07800000", x"07800000", "101", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);
    checks <= checks + 1;
    if berr_seen = walks_before then
      errors <= errors + 1;
      report "[FAIL] S3 post-PFLUSHA access did not re-walk"
        severity error;
    else
      report "[PASS] S3 PFLUSHA cleared sticky fault, next access re-walked"
        severity note;
    end if;

    ---------------------------------------------------------------
    -- PHASE X: FCL=1 (function-code lookup) as the implicit first level.
    --
    -- TC = $81C04880 : E=1 SRE=0 FCL=1 PS=12 IS=0 TIA=4 TIB=8 TIC=8 TID=0
    -- Sum: PS(12) + TIA(4) + TIB(8) + TIC(8) + TID(0) = 32  (field-sum check
    -- does NOT count FC bits — the 3 FC bits are separate from logical addr).
    -- With FCL=1, the root table is indexed by FC (8 entries, 4 bytes each
    -- in short-format).  Root at $1000.
    --
    -- Effective shift for early-term at level 0 (FC): PS + TIA+TIB+TIC+TID
    --   = 12+4+8+8+0 = 32 bits -> whole 4 GB collapses per FC root entry.
    --   This exercises the align_addr(x, 32)=0 path in the walker, which
    --   collapses super-page base to zero and yields PFA = TA + log_addr.
    ---------------------------------------------------------------
    pflusha;
    write_reg("10000", x"81C04880", '0');   -- TC with FCL=1
    wait for 100 ns;
    pflusha;

    -- Root[5] (FC=101 supervisor data) = early-term page, remap to $40000000.
    -- (TAs stay below $80000000 to avoid VHDL signed-integer overflow in
    -- test arithmetic.)  Clear residual entries from earlier phases.
    for i in 0 to 7 loop
      pt(1024 + i) := (others => '0');
    end loop;
    pt(1024 + 5) := x"40000061";   -- FC=101 root entry, TA=$40000000
    wait for 20 ns;
    pflusha;

    -- Supervisor-data access goes through FC=101 root entry 5.
    -- Logical $12345678 with FC=101:
    --   super-page base = $12345678 & ~((2^29)-1) = $00000000
    --   offset = $12345000
    --   PFA (4 KB page) = $40000000 + $12345000 = $52345000
    --   PFA for byte $12345678 = $52345678
    probe("X FCL=1 FC=sup-data @ $12345678", x"12345678", "101", '1',
          x"52345678", false);

    -- FC=001 (user data) maps to root entry 1 which is zero -> fault.
    pflusha;
    probe("X FCL=1 FC=usr-data fault", x"12345678", "001", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);

    -- FC=110 (supervisor program) maps to root entry 6 which is zero -> fault.
    pflusha;
    probe("X FCL=1 FC=sup-prog fault", x"12345678", "110", '1',
          (others => '0'), true, MMUSR_I, MMUSR_I);

    -- Populate root[6] (sup prog) with a different remap to prove FC separately
    -- selects the entry.  Use TA=$30000000 so PFA = $30000000 + $12345000 = $42345000.
    pt(1024 + 6) := x"30000061";
    wait for 20 ns;
    pflusha;
    probe("X FCL=1 FC=sup-prog @ $12345678", x"12345678", "110", '1',
          x"42345678", false);

    -- PHASE X2: WinUAE parity for root-pointer early termination with FCL=1.
    -- In cpummu30.cpp, early-termination limit checks are skipped when the
    -- descriptor is the root pointer itself and TC.FCL is enabled:
    --   if (descr_num || !(tc_030&TC_ENABLE_FCL)) { limit check ... }
    -- The upper limit below is intentionally zero.  Without the WinUAE guard,
    -- FC=101 would be treated as index 5 and would fault with L/I instead of
    -- translating through the root-pointer page descriptor.
    pflusha;
    write_reg("10011", x"00000001", '1');   -- CRP_H: root DT=01, upper limit 0
    write_reg("10011", x"10000000", '0');   -- CRP_L: long page descriptor TA
    write_reg("10000", x"81C04880", '0');   -- TC with FCL=1
    wait for 100 ns;
    pflusha;
    probe("X2 FCL root early-term skips limit", x"12345678", "101", '1',
          x"22345678", false);

    ---------------------------------------------------------------
    -- PHASE U: verify the walker actually writes U=1 (bit 3) back into
    -- descriptors that had U=0 before the walk.  Matches WinUAE behavior
    -- in cpummu30.cpp:  descr[0] |= DESCR_U; desc_put_long(addr, descr);
    ---------------------------------------------------------------
    pflusha;
    wait for 40 ns;

    -- Fresh 2-level setup: CRP (short) at $1000 -> TC $80C0AA00 (PS=12 TIA=10 TIB=10)
    write_reg("10011", x"7FFF0002", '1');
    write_reg("10011", x"00001000", '0');
    write_reg("10010", x"7FFF0002", '1');
    write_reg("10010", x"00001000", '0');
    write_reg("10000", x"80C0AA00", '0');
    wait for 100 ns;
    pflusha;

    -- Root entry 40: table descriptor at $00005000, DT=10, U=0, WP=0.
    -- Descriptor format: [31:4]=addr=$00005000 >>4 = $00000500, [3]=U=0,
    -- [2]=WP=0, [1:0]=DT=10  ->  $00005002.
    pt(1024 + 40) := x"00005002";

    -- Level-2 table at $00005000; one page descriptor with M=0, U=0, WP=0.
    -- Short-format page: [31:8]=phys, [7:4]=rsvd=0, [3]=U, [2]=WP, [1:0]=DT=01.
    -- Use phys base $45678000 -> descriptor $45678001.
    pt(5120 + 0) := x"45678001";   -- $5000/4 = 5120
    wait for 40 ns;
    pflusha;
    wait for 40 ns;

    -- Access logical $0A000000 -> TIA=40 (bits[31:22]=40=$28 => $0A000000),
    -- TIB=0 (bits[21:12]=0), offset=0  ->  walks root[40] then level-2 entry 0.
    -- Expected PFA: $45678000.
    wb_snap := wb_count;
    probe("U walk w/ U=0 tables @ $0A000000", x"0A000000", "101", '1',
          x"45678000", false);
    wait for 100 ns;

    -- Verify at least one writeback was issued during the walk, and the last
    -- writeback descriptor has bit 3 (U) set.  Walker writes U for the root
    -- table descriptor (level 0) and also U for the leaf page (level 1) on read.
    checks <= checks + 1;
    if (wb_count - wb_snap) = 0 then
      errors <= errors + 1;
      report "[FAIL] U1 expected >=1 descriptor writeback, got 0"
        severity error;
    elsif wb_last_data(3) /= '1' then
      errors <= errors + 1;
      report "[FAIL] U1 last writeback data=0x" & hex8(wb_last_data) &
             " -- U bit (3) not set"
        severity error;
    else
      report "[PASS] U1 walker wrote U=1 back (" &
             integer'image(wb_count - wb_snap) & " writebacks, last data=0x" &
             hex8(wb_last_data) & ")"
        severity note;
    end if;

    -- Re-access same page: U is now already set in both descriptors, so no
    -- further writeback should occur.
    pflusha;   -- ATC only; descriptors in memory stay as written
    wait for 40 ns;
    wb_snap := wb_count;
    probe("U walk w/ U=1 tables @ $0A000000", x"0A000000", "101", '1',
          x"45678000", false);
    wait for 100 ns;
    checks <= checks + 1;
    if (wb_count - wb_snap) /= 0 then
      errors <= errors + 1;
      report "[FAIL] U2 expected 0 writebacks when U already set, got " &
             integer'image(wb_count - wb_snap)
        severity error;
    else
      report "[PASS] U2 no writeback when U already set (walker skipped update)"
        severity note;
    end if;

    ---------------------------------------------------------------
    -- PHASE V: M-bit writeback matrix.
    --   V1. Write access to WP=0 page  -> M=1 (bit 4) written back
    --   V2. Read  access to WP=0 page  -> M stays 0, no M-bit writeback
    --   V3. Write access to WP=1 page  -> WP fault, no M=1 writeback
    -- Table already set up from Phase U.  Use separate TIB indices so each
    -- case operates on a fresh page descriptor.
    ---------------------------------------------------------------

    -- V1: page descriptor at TIB=1 (logical $0A001000), M=0, U=0, WP=0
    pt(5120 + 1) := x"12341001";   -- phys=$12341000, DT=01
    wait for 40 ns;
    pflusha;
    wait for 40 ns;

    -- Write access — expect PFA and writeback with both U and M set.
    wb_snap := wb_count;
    probe("V1 write WP=0 @ $0A001000", x"0A001000", "101", '0',
          x"12341000", false);
    wait for 100 ns;

    checks <= checks + 1;
    if (wb_count - wb_snap) = 0 then
      errors <= errors + 1;
      report "[FAIL] V1 write to WP=0 produced no descriptor writeback"
        severity error;
    elsif wb_last_data(4) /= '1' or wb_last_data(3) /= '1' then
      errors <= errors + 1;
      report "[FAIL] V1 writeback data=0x" & hex8(wb_last_data) &
             " -- expected both M(4) and U(3) set"
        severity error;
    else
      report "[PASS] V1 write writes M=1 U=1 (" & integer'image(wb_count - wb_snap) &
             " writebacks, last=0x" & hex8(wb_last_data) & ")"
        severity note;
    end if;

    -- V2: page descriptor at TIB=2, fresh M=0, U=0, WP=0.
    pt(5120 + 2) := x"23452001";   -- phys=$23452000
    wait for 40 ns;
    pflusha;
    wait for 40 ns;

    -- READ access — walker should write U=1 but NOT M=1.
    wb_snap := wb_count;
    probe("V2 read  WP=0 @ $0A002000", x"0A002000", "101", '1',
          x"23452000", false);
    wait for 100 ns;

    checks <= checks + 1;
    if (wb_count - wb_snap) = 0 then
      errors <= errors + 1;
      report "[FAIL] V2 read produced no writeback (expected U=1)"
        severity error;
    elsif wb_last_data(4) = '1' then
      errors <= errors + 1;
      report "[FAIL] V2 read wrote back M=1 (data=0x" & hex8(wb_last_data) &
             ") -- M must only be set on writes"
        severity error;
    elsif wb_last_data(3) /= '1' then
      errors <= errors + 1;
      report "[FAIL] V2 read writeback data=0x" & hex8(wb_last_data) &
             " -- U bit should be set"
        severity error;
    else
      report "[PASS] V2 read writes U=1 M=0 (data=0x" &
             hex8(wb_last_data) & ")"
        severity note;
    end if;

    -- V3: page descriptor at TIB=3, M=0, U=0, WP=1.
    -- $7X... with WP bit set (bit 2) -> $34563005.
    pt(5120 + 3) := x"34563005";   -- phys=$34563000, WP=1, DT=01
    wait for 40 ns;
    pflusha;
    wait for 40 ns;

    -- Write to WP page — expect fault (MMUSR.W=1) and NO M-bit writeback.
    wb_snap := wb_count;
    probe("V3 write WP=1 @ $0A003000", x"0A003000", "101", '0',
          (others => '0'), true, MMUSR_W, MMUSR_W);
    wait for 100 ns;

    -- Walker *may* still have written U (access happened) but MUST NOT
    -- have written M=1.  Check the last writeback for M=0.
    checks <= checks + 1;
    if (wb_count - wb_snap) /= 0 and wb_last_data(4) = '1' then
      errors <= errors + 1;
      report "[FAIL] V3 write-to-WP set M=1 (data=0x" & hex8(wb_last_data) &
             ") -- violates BUG #437 / WinUAE parity"
        severity error;
    else
      report "[PASS] V3 write-to-WP did not set M (" &
             integer'image(wb_count - wb_snap) & " writebacks, last=0x" &
             hex8(wb_last_data) & ")"
        severity note;
    end if;

    ---------------------------------------------------------------
    -- Summary
    ---------------------------------------------------------------
    wait for 500 ns;
    report "==== tb_pmmu_comprehensive summary ====" severity note;
    report "checks=" & integer'image(checks) & "  errors=" & integer'image(errors)
      severity note;
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
