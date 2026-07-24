# CPU / MMU / Memory / Cache Review — 2026-07-23

Four-way deep review of the 68030+PMMU port: `rtl/cpu_wrapper.v` (walker, bus mux,
handshakes), `rtl/tg68k/TG68K_PMMU_030.vhd`, the 030 L1 cache
(`TG68K_Cache_030.vhd` + `TG68K_CacheCtrl_030.vhd` + `Minimig.sv` fill FSM), the
L2 (`cpu_cache_new.v`), and the recently-touched regions of
`TG68KdotC_Kernel.vhd`. All findings below were re-verified against current file
contents; line numbers refer to the working tree as of this date.

Numbering continues the repo convention from BUG #446.

**Working-tree diff verdict:** the uncommitted `cpu_wrapper.v` refactor
(declaration hoisting, `wire x = ...` → `assign`, `ipl_autovector(1'b1)`) is
behavior-neutral, including the `USE_68030_CACHE==0` branch. Safe to commit as-is.

**Key context:** BUG #454 (the "CACHE BISECT EXPERIMENT" tie-off of
`cacr_ie/cacr_de`) currently forces the entire 030 L1 cache off. Findings marked
**[latent]** are masked by it today and go live the moment it is reverted. They
must be fixed BEFORE re-enabling the cache.

---

## CRITICAL

### BUG #447 — Walker fast-RAM data corrupted by stale CPU address attributes  [FIXED 2026-07-23]
- **Where:** `rtl/cpu_wrapper.v:257-258` (`ramdat` RTG byte-swap), `:210`
  (`ramshared = sel_dd`), `:255-256` (`ramdin` swap is walker-gated only via
  `walker_fast_ram && walker_writing`; the `sel_rtg` else-arm still applies to
  the mux input selection).
- **Defect:** During a table walk, `bus_addr = pmmu_addr_phys_p` = the PMMU's
  *stale* last-completed translation. `ramaddr`, `ramlds/ramuds`, and the write
  data are walker-gated, but `ramdat`'s byte-swap and `ramshared` are decoded
  from the stale address.
- **Failure:** MMU on + RTG/P96 active: CPU touches framebuffer
  (`$02xxxxxx`), next access ATC-misses, walker fetches a descriptor from Z2/Z3
  RAM → stale `sel_rtg=1` halfword-swaps the descriptor → garbage translation or
  spurious MMU fault. Stale `sel_dd=1` similarly routes walker read data and U/M
  write-back through the DDR-shared byte-swap path (`Minimig.sv:562`,
  `ddram_ctrl.v:122/123/451`).
- **Fix:** Gate the attribute decodes with the walker: derive `sel_rtg`/`sel_dd`
  effects on `ramdat`/`ramshared` (and `ramdin` swap arm) from
  `walker_fast_ram ? walker_ramaddr-based decode (never RTG/DD) : bus_addr
  decode`. Simplest: `assign ramdat = (sel_rtg & ~walker_fast_ram) ? swap :
  ramdout;` and `assign ramshared = sel_dd & ~walker_fast_ram;`.

### BUG #448 — RTE MMU-softfix TST commit clobbers D5/A5  [FIXED 2026-07-23]
- **Where:** whitelist `rtl/tg68k/TG68KdotC_Kernel.vhd:1797-1807`
  (`rte_mmu_fix_is_tst` accepted as CCR-only); commit block `:2302-2321` has no
  `rte_mmu_fix_is_tst` guard.
- **Defect:** TST's opcode bits are decoded as MOVE fields at commit.
  Verified decode: TST.B → bits(8:6)="000" → MOVE-to-Dn arm → writes D5(7:0);
  TST.W → "001" → MOVEA arm → writes sign-extended garbage to **A5**;
  TST.L → "010" → falls into the else (MOVE-to-Dn) arm → writes all of D5.
- **Failure:** Enforcer/MuForce probe `TST.x (EA)` on a guarded page; handler
  fills DIB, clears DF, RTE → CCR correct but D5/A5 silently trashed. This is
  the exact use case the TST support was added for.
- **Fix:** Guard the register-commit block:
  `IF rte_mmu_fix_commit = '1' AND rte_mmu_fix_is_tst = '0' THEN ...`.
  Add a regression tb: softfix-complete TST.B/W/L, assert D5/A5 unchanged, CCR
  updated.

### BUG #449 — D-cache byte-store at addr%4==3 uses wrong strobe → line never updated  [FIXED 2026-07-24]
- **Where:** `rtl/tg68k/TG68K_CacheCtrl_030.vhd:190-193` (`d_cache_be` "others"
  arm: `(not uds_n) & "000"`).
- **Defect:** A 68k byte access to an odd address asserts only LDS; the "11"
  (addr%4==3) byte-enable is taken from UDS, so it is never active.
- **Failure:** `MOVE.B D0,(3,A0)` to a D-cache-resident line updates memory but
  not the line; subsequent `MOVE.B (3,A0),D1` read-hit returns the stale byte.
  Every 4th byte address affected.
- **Fix:** Use `not lds_n` for the "11" arm — and fix the target lane together
  with BUG #450 (see below for the consistent layout).

### BUG #450 — D-cache odd-address byte read-hits return the even sibling byte  [FIXED 2026-07-24]
- **Where:** `rtl/tg68k/TG68K_CacheCtrl_030.vhd:210-213` (read mux "01" returns
  `d_cache_data_out(15 downto 8)`, "11" returns `(31 downto 24)`).
- **Defect:** The fill layout (word0 → line bits 15:0; bus big-endian: even byte
  = bits 15:8, odd byte = bits 7:0) and the write path (`d_cache_data_in` "01"
  arm → bits 7:0) put byte1 at line bits 7:0 and byte3 at bits 23:16. The read
  mux disagrees.
- **Failure:** Any odd-address byte read that hits the D-cache returns the even
  sibling's value (TG68 extracts bus bits 7:0 for odd addresses).
- **Fix (with #449, one consistent lane map):**
  byte0→15:8, byte1→7:0, byte2→31:24, byte3→23:16.
  - `d_cache_data_in`: "01" arm OK (7:0); "11" arm must target 23:16
    (`x"00" & cpu_data_write(7:0) & x"0000"` shape).
  - `d_cache_be`: "01" → bit0 (`not lds_n`), "11" → bit2 (`not lds_n`).
  - read mux: "01" → `d_cache_data_out(7 downto 0)`, "11" → `(23 downto 16)`.
  - Re-derive the "00"/"10" word arms against the same layout (they are
    currently consistent) and add a tb sweeping all 4 byte offsets × R/W × hit.

### BUG #451 — Fill owner/address race can commit D-line data into the I-cache  [FIXED 2026-07-24]
- **Where:** `Minimig.sv:606-618` (fill address latched at grant) vs
  `rtl/tg68k/TG68K_CacheCtrl_030.vhd:277-285` (`fill_owner_i`/`fill_addr_latched`
  latched at first `cache_ack`), with `cache_addr_int` re-prioritizing I over D
  (`:226-228`).
- **Failure:** D-miss fill granted; CPU (already released) I-misses before the
  first ack → CacheCtrl marks the fill I-owned and commits the D-address data
  fetched by Minimig into the I-cache under the I tag → wrong instructions
  cached and executed.
- **Fix:** Latch owner + fill address in CacheCtrl at the same event Minimig
  uses (fill grant / `fill_start`), not at first ack; ignore the other cache's
  miss request while a fill is in flight (hold `cache_addr_int` stable from the
  latched owner).

### BUG #452 — CacheCtrl/Minimig fill word counters can desynchronize  [FIXED 2026-07-24]
- **Where:** `rtl/tg68k/TG68K_CacheCtrl_030.vhd:243-246, 258-259` (`fill_start`
  path requires `cache_req_int`, gated by `~pmmu_busy`/`~pmmu_walker_req` while
  `fill_active=0`) vs `Minimig.sv:594-648` (independent word counter, gated only
  by `walker_active_cpu`).
- **Failure:** `pmmu_busy` pulses (next access's ATC-miss gap) on the same cycle
  the first `ram_ready` ack arrives → CacheCtrl misses word 0 while Minimig
  counts it → line assembled shifted by one 16-bit word, completion steals words
  from the next fill, corrupt line marked valid.
- **Fix:** Single source of truth for fill progress: either CacheCtrl counts
  acks unconditionally once `fill_active` is set (decouple from
  `cache_req_int`'s pmmu gating), or Minimig exports its word counter and
  CacheCtrl consumes it. Add an assertion tb pulsing `pmmu_busy` at every offset
  around the first ack.

### BUG #453 — CACR $0808 (CacheClearU) drops the D-cache invalidate  [FIXED 2026-07-24]
- **Where:** priority encoder `rtl/tg68k/TG68KdotC_Kernel.vhd:1123-1145` (emits
  one op, CI wins) + self-clear `:9806-9810` (wipes all four clear bits at next
  `clkena_lw`).
- **Failure:** One MOVEC writing CACR with CI+CD set (exactly what AmigaOS
  `CacheClearU()` issues on 030) invalidates only the I-cache; the D-invalidate
  is silently dropped → stale D-cache data survives OS cache flushes (post-DMA
  loads, page remaps).
- **Fix:** Either clear only the bit whose op was emitted (leaving CD pending
  for the next cycle, encoder then emits it), or widen the op interface to carry
  I+D simultaneously. The pending-bit approach is smaller and keeps the
  handshake unchanged. Cover CEI+CED combination too.

---

## MAJOR

### BUG #454 — "CACHE BISECT EXPERIMENT" ships with the 030 cache force-disabled  [FIXED 2026-07-24 — CACHE RE-ENABLED]
- **Where:** `rtl/cpu_wrapper.v:3606-3611` — `.cacr_ie(1'b0), .cacr_de(1'b0)`.
- **Defect:** Committed experiment; CACR EI/ED writes have no effect, L1 never
  hits or fills in any current build.
- **Fix:** Revert to `.cacr_ie(cacr_ie), .cacr_de(cacr_de)` — but only at
  Phase 4 (after #449-#453, #455, #457 are fixed), since it unmasks them.

### BUG #455 — Shared-IO window ($00DD4xxx) reads can hit/allocate stale cache tags  [FIXED 2026-07-24]
- **Where:** kernel suppresses `pmmu_req` for the window
  (`TG68KdotC_Kernel.vhd:1197-1205`), so `pmmu_addr_phys_p` is stale there;
  `TG68K_CacheCtrl_030.vhd:171-182` indexes/allocates by `pmmu_addr_phys`;
  `cache_hit` outranks `ramsel` in `cpu_din` (`cpu_wrapper.v:338`).
- **Failure:** With TC.E=1, a window read can return a cached line belonging to
  the previous access's physical address, and window data can be allocated
  under that stale tag, poisoning it.
- **Fix:** Force cache-bypass + no-allocate for window accesses: qualify
  CacheCtrl lookup/fill with `~pmmu_shared_io_log` (export the window decode to
  the cache controller, or fold it into `fill_inhibit` and the hit qualifier).

### BUG #456 — fastchip not gated by pmmu_suppress_bus; stale acks complete beats  [FIXED 2026-07-23]
- **Where:** `rtl/cpu_wrapper.v:414` (`fastchip_sel = cpu_req &
  !pmmu_addr_phys_p[31:24] & ~walker_active`), `:2503` (`cpu_ready_qualified`
  ORs `fastchip_selack & fastchip_ready` unconditionally).
- **Failure:** During pmmu busy/fault windows `pmmu_addr_phys_p` is stale;
  fastchip decodes level-sensitively (`fastchip.v:69,83-89`) → spurious write
  strobes to a stale IDE/Akiko address corrupt device state; a stale
  `selack & ready` can complete an unrelated CPU beat with invalid `cpu_din`.
- **Fix:** `fastchip_sel &= ~pmmu_suppress_bus`; in `cpu_ready_qualified`,
  qualify the fastchip term with `fastchip_sel` (current-cycle decode), not just
  `selack`.

### BUG #457 — clkena/beat_valid accept cache_hit that cpu_din won't deliver  [FIXED 2026-07-23]
- **Where:** `rtl/cpu_wrapper.v:2507,2517` (release on bare
  `USE_68030_CACHE & cache_hit`) vs `:338` (`cpu_din` cache arm additionally
  requires `~walker_active & ~pmmu_fault_p`).
- **Failure:** In the walk-tail window (walker still in WALKER_DONE after
  `pmmu_busy` dropped), a hit releases the beat but `cpu_din` serves
  `chip_data`/`ramdat` → CPU consumes wrong data as a "cache hit".
- **Fix:** Use one shared qualifier: `wire cache_hit_valid = USE_68030_CACHE &
  cache_hit & ~walker_active & ~pmmu_fault_p;` in `cpu_clkena_in`,
  `cpu_beat_valid`, and the `cpu_din` mux.

### BUG #458 — Second-opcode-word fetch (MOVEM mask etc.) consumes force-completed beats  [OPEN — deeper than diagnosed]
- **Where:** `rtl/tg68k/TG68KdotC_Kernel.vhd:10077` (`sndOPC <= data_read` at
  decodeOPC, no `beat_valid` gate); `insn_fetch_consumer` (`:1644-1657`) has no
  term for the decodeOPC/get_2ndOPC fetch; MOVEM decode `:6202-6209`.
- **Failure:** MOVEM opcode is the last word of a mapped page, mask word on an
  unmapped page: fault force-releases the beat, sndOPC latches garbage, fault is
  classified consumer-less (no restart/rollback/squash) → MOVEM runs to
  completion storing a garbage register set before the deferred bus error;
  RTE resumes after the corruption. Also feeds DIVx.L, MULx.L, CAS2, bitfields.
- **Fix:** Add the decodeOPC/get_2ndOPC fetch to `insn_fetch_consumer` coverage
  (or gate the `sndOPC` latch on `beat_valid` and hold the micro-state until a
  valid beat), so the fault takes the restart path before any side effect.
- **2026-07-23 update (reproducer built, fix attempt failed):**
  `tests/tg68k_030/tb_movem_mask_pagefault.vhd` (make target marked
  KNOWN-FAILING) places `MOVEM.L D0-D2,-(A6)` as the last word of a mapped 1K
  page with the mask on an invalid page. Result: **double-bus-fault HALT** —
  the deferred mask-word bus error dispatches (`trap_berr=1`,
  `berr_exception_active=1`) while MOVEM's own store beats keep executing;
  the first store's walk then re-faults into HALT_CTX_A. Identical with and
  without a `set(get_2ndOPC)` term in `insn_fetch_consumer`, so the missing
  consumer classification is NOT the (only) root cause: the deferred-dispatch
  path fails to squash/preempt the in-flight instruction's data beats at all.
  Needs a dedicated investigation of the deferred berr dispatch vs. microcode
  sequencing (likely the same machinery gap for DIVx.L/MULx.L/CAS2/bitfields).

### BUG #459 — RTE SR pop / STOP SR load ungated by beat_valid; SR-high never rolled back  [FIXED 2026-07-23]
- **Where:** `TG68KdotC_Kernel.vhd:5092-5093` (`FlagsSR <= data_read(15:8)`),
  `:5062-5064` (`SVmode <= data_read(13)`), `:4815-4817` (`trap_SR <=
  data_read(15:8)`); restart rollback restores only the 8-bit CCR shadow.
- **Failure:** Parasitic fault-released beat while the RTE SR word is in flight
  (id12-class; `directpc_retry_hold` covers only `exec(directPC)`) loads garbage
  S/M/IPL/T into FlagsSR and a garbage SR into the bus-error frame; handler RTE
  then restores garbage SR (e.g. S=0 → A7 swaps to USP) instead of restarting.
- **Fix:** Extend the retry-hold mechanism to `exec(directSR)` beats (same shape
  as `directpc_retry_hold`), gate `trap_SR` capture on `beat_valid`, and widen
  the restart shadow to full SR (or snapshot FlagsSR at fault-fire).

### BUG #460 — Format $A/$B frame-word latches at rte5 unqualified  [FIXED 2026-07-23]
- **Where:** `TG68KdotC_Kernel.vhd:2111-2133`
  (`rte_mmu_fix_ssw/faddr/opcode/input_buffer`), `:2169-2185`
  (`rte_fmt_a_state1/ssw/fault_addr/data_out`) — bare `clkena_lw`, no
  `beat_valid`, unlike the hardened `rte_format_word` at `:1910-1916`.
- **Failure:** Parasitic fault-released pop during a $B-frame RTE (the FBRD/T27
  shape) garbage-fills the words driving DIB substitution (`:4514-4517`) or the
  $A replay decision → wrong data silently injected into the re-executed access,
  or a replay write aimed by garbage SSW/fault-address.
- **Fix:** Apply the same `beat_valid`-qualified capture (or the
  `rte_format_word` retry-hold pattern) to every rte5 pop latch.

### BUG #461 — rte_mmu_fix_len wrong for 68020 full-format extensions  [FIXED 2026-07-23]
- **Where:** `TG68KdotC_Kernel.vhd:1812-1815` (hard-coded 1 ext word for modes
  110 / 111-011) with whitelist `:1789-1796`.
- **Failure:** Software-completed `MOVE.L (bd16,An,Xn),Dn` (full-format, 2+ ext
  words) resumes at PC+4 — inside its own displacement — and executes garbage;
  memory-indirect forms are also semantically wrong for single-DIB completion.
- **Fix:** Conservative: veto modes 110 and 111-011 from the whitelist (the
  frame doesn't expose the extension word to check bit 8). Brief-format-only
  support remains for the common cases.

### BUG #462 — L2 (cpu_cache_new) not updated by walker U/M descriptor writes  [FIXED 2026-07-24]
- **Where:** `rtl/cpu_cache_new.v:303-306` (write-hit update gated by
  `!cache_inhibit`); `Minimig.sv:482` (`ram_cache_inhibit = walker_active |
  pmmu_CI`). Instantiated in `sdram_ctrl.v:143` and `ddram_ctrl.v:318`.
- **Failure:** OS reads a page-table longword (cacheably) → L2 allocates;
  walker sets U/M in memory (walker_active=1 → no snoop-update) → OS re-reads
  the stale descriptor from L2 and can write back U/M=0 (lost update). Same for
  any CI-mapped write to a previously-allocated line.
- **Fix:** On an inhibited write, still *invalidate* a matching L2 line (update
  not required, invalidate is safe and cheap): drop the `!cache_inhibit` gate
  on the tag-match invalidate path while keeping it on allocate.

### BUG #463 — PMMU index math counts TI fields after the first zero  [LIVE, low likelihood]
- **Where:** `rtl/tg68k/TG68K_PMMU_030.vhd:708-710` (`get_table_index`),
  `:1104-1127` (`calc_effective_page_shift`) vs `tc_total_bits` `:864-875`
  (correctly stops at first zero, per UM §9.7.4 / "NOTE 1").
- **Failure:** Spec-legal TC (e.g. E=1, PS=12, IS=0, TIA=8, TIB=12, TIC=0,
  TID=5) passes validation, but the ghost TID=5 shifts every level's index →
  walker reads the wrong root/pointer entries → silent mistranslation. WinUAE
  (top-down shifts, stops at first zero TI) diverges from this RTL.
- **Fix:** Zero out `tc_idx_bits(n)` for all fields after the first zero at TC
  decode time (`:1604-1611`) so index math, page-shift, and total-bits all agree
  — one-point fix, no per-consumer changes.

---

## MINOR

### BUG #464 — WALKER_READ_HIGH / WALKER_WRITE_HIGH lack timeout & req-drop escapes  [FIXED 2026-07-23]
- `rtl/cpu_wrapper.v:4021-4030, 4166-4176`: both loop on `walker_mem_ready`
  high, increment `walker_timeout_cnt` but never compare against
  `WALKER_TIMEOUT_LIMIT`, and never check `~pmmu_walker_req_p` (BUG #419
  escape). A stuck-high ready or PMMU-side timeout parks `walker_active=1`
  forever → hard hang (CPU completion blocked) instead of BERR. Fix: replicate
  the escape clauses from the LOW-phase states.

### BUG #465 — One-clock untranslated window after `PMOVE ...,TC` (E=1)
- `TG68K_PMMU_030.vhd:1387` (valid flag set at write edge) vs `:1250-1282`
  (validation one cycle later), `:1585`, `:4876-4878`;
  `TG68KdotC_Kernel.vhd:1200`. For 1 clk the MMU acts disabled (identity, no
  busy). Mitigated by real-030 enable-code conventions; fix by asserting busy
  for the validation cycle after a TC write with E=1.

### BUG #466 — Dead "ATC combinational bypass" block
- `TG68K_PMMU_030.vhd:1153-1193`: outputs (`atc_*_comb`) never consumed; burns a
  22-way compare tree and contradicts its own comment. Delete (or wire into the
  output muxes deliberately — deletion recommended).

### BUG #467 — STOP/to_SR M-swap alias flag vs A7 swap use different S qualifiers  [FIXED 2026-07-23]
- `TG68KdotC_Kernel.vhd:1966` (`FlagsSR(5)`) vs `:2340,:9797` (`preSVmode`).
  Disagreement window can desync `a7_is_msp` from the actual A7/shadow exchange,
  corrupting later MOVEC $803/$804 aliasing. Fix: use one qualifier
  (`preSVmode`) at all three sites; same asymmetry pre-exists for
  `exec(to_SR)` (`:1959` vs `:2330`).

### BUG #468 — CACR freeze set mid-fill still commits the in-flight line  [FIXED 2026-07-24]
- `TG68K_Cache_030.vhd:202-204,343-345` vs `:149-154,237-242`: freeze cancels
  the fill request, but the in-flight CacheCtrl fill still raises `fill_valid`
  and commits, replacing an entry while frozen. Fix: gate line commit on the
  freeze bit for the owning cache.

### BUG #469 — CACR WA (write-allocate) accepted but unimplemented
- `TG68K_Cache_030.vhd`: `cacr_wa` port never read. Functionally conservative
  (write misses never allocate); document as a fidelity gap or implement 030 WA
  semantics (invalidate on write miss with WA=0 per UM 6.1.2 nuances).

### BUG #470 — Audit-doc drift
- `MMU_AUDIT.md` still claims illegal PMOVE reg_sel → vector 56 (code now
  F-line traps, per UM 9.6); the PTEST-sets-U-bits decision text predates the
  `6fd63e0` revert ("PTEST modifies no descriptor bits", PRM p.603);
  PFLUSHAN row in §3 remains wrong (self-noted in §13.2). Update both audit
  docs after the fixes above land, and record BUG #447-#469 dispositions.

---

# FIX PLAN

Ordering principle: live-path corruption first, then bus-integrity, then the
kernel fault-restart hardening, then the cache-re-enable track (fix everything
the bisect experiment masks, then revert it), then fidelity/cleanup. Each phase
is independently commitable and regression-gated.

## Phase 1 — Live data-corruption fixes (small, surgical)  ✅ DONE 2026-07-23
Both fixes landed with regressions `test-walker-stale-rtg` and
`test-rte-mmu-fix-tst`, each verified to FAIL pre-fix and PASS post-fix.
`test-fault-recovery` and `test-mmu-badfeed-softfix` pass. Note: the
`test-cpu-wrapper-pmmu` scenarios 3+4/5 failures and `tb_pmmu_comprehensive`
F6 fault_fc failure are PRE-EXISTING on the baseline (verified by stash +
re-run) — they predate Phase 1 and belong to the in-progress scenario-5
rework / a PMMU FC-reporting issue respectively.
1. **#447** walker `ramdat`/`ramshared`/`ramdin` attribute gating
   (`cpu_wrapper.v`).
2. **#448** `rte_mmu_fix_is_tst` guard on the register-commit block
   (`TG68KdotC_Kernel.vhd`).
- **Verify:** new tb `tb_walker_rtg_stale_swap.v` (prime `addr_phys_reg` with an
  RTG/DD address, force ATC miss to Z3 tables, assert descriptor read
  unswapped + U/M write-back path); new tb `tb_rte_mmu_fix_tst.vhd`
  (softfix-complete TST.B/W/L → D5/A5 unchanged, CCR correct; MOVE/MOVEA arms
  unregressed). Run existing `test-cpu-wrapper-pmmu`,
  `test-mmu-fault-recovery`, `test-pmmu-comprehensive` targets.

## Phase 2 — Bus-integrity majors (wrapper)  ✅ DONE 2026-07-23
All three landed in one commit. tb_walker_stale_rtg gained Scenario 2 (stuck-
high ready in READ_HIGH → walker must escape; verified to hang with the
escapes neutered) and a standing fastchip-suppress invariant. Note: the walker
escape normally fires via the PMMU's ~500-cycle internal watchdog (req drop),
not the wrapper's 2048-cycle limit — the #464 fix makes READ/WRITE_HIGH honor
both. #457 is protective-only until the BUG #454 revert re-enables the cache.
3. **#456** gate `fastchip_sel` with `~pmmu_suppress_bus`; qualify the fastchip
   ready term with `fastchip_sel`.
4. **#457** shared `cache_hit_valid` qualifier for clkena/beat_valid/cpu_din.
5. **#464** timeout + req-drop escapes in WALKER_*_HIGH states.
- **Verify:** extend `tb_cpu_wrapper_pmmu.v` with (a) IDE-write-then-fault
  sequence asserting no spurious fastchip strobes, (b) stuck-ready in
  READ_HIGH asserting BERR within `WALKER_TIMEOUT_LIMIT`. Full wrapper suite.

## Phase 3 — Kernel fault-restart hardening  ✅ DONE 2026-07-23 (except #458 — OPEN)
#459/#460/#461/#467 landed in one commit; 26-target suite, 22 pass. #458
turned out deeper than diagnosed: the tb_movem_mask_pagefault reproducer
double-fault-halts identically with and without the insn_fetch_consumer
term — the deferred berr dispatch fails to squash the in-flight
instruction's store beats. Reproducer kept as a KNOWN-FAILING target; needs
a dedicated deferred-dispatch/squash investigation (also covers DIVx.L/
MULx.L/CAS2/bitfields). Two MORE pre-existing failures found while running
the wider suite (fail identically on baseline): test-mmu-badfeed-fault-frame
(SSW $0141 vs expected $0341) and test-stack-frame-push (MMU-config frame
format/vector). Neither is caused by Phases 1-3.
6. **#458** decodeOPC second-word fetch → `insn_fetch_consumer` coverage
   (restartable, no side effects on faulting mask/ext words).
7. **#459** `directSR` retry-hold + `beat_valid` on `trap_SR`; full-SR restart
   shadow.
8. **#460** `beat_valid`-qualified rte5 frame-word latches ($A and $B paths).
9. **#461** veto full-format-capable EA modes from the softfix whitelist.
10. **#467** unify M-swap supervisor qualifier on `preSVmode`.
- **Verify:** new tbs: `tb_movem_mask_pagefault.vhd` (MOVEM straddling an
  unmapped page → clean restart, register set intact),
  `tb_rte_sr_pop_parasitic_fault.vhd` (id12 shape on the SR word),
  extend `tb_mmu_fetch_fault_frame` / `tb_mmu_fault_recovery` for the $A/$B
  latch paths. Re-run the full `tests/tg68k_030` regression (all
  `test-mmu-*`, `test-addr-error-*`, record37 repro).

## Phase 4 — Cache re-enable track  ✅ DONE 2026-07-24 — L1 CACHE IS LIVE
All seven fixes + the #454 revert landed in one commit. New benches:
`test-cache030-unit` (17 checks; pre-fix baseline fails 11) and
`test-cacr-clearu` (real-kernel MOVEC op-stream; baseline drops CD/CED).
Bench development exposed and closed a completion-window re-arm race in the
new request-lock design itself. Note: `tb_movec_cacr_corner` tests a stale
COPY of the kernel's CACR logic (still models the old clear-all behavior) —
worth retiring or pointing at the real kernel.
**REMAINING FOR PHASE 4 SIGN-OFF: the hardware soak** — build an RBF from
b8ba7a2 or later, boot WB3.1 + SetPatch (caches ON for the first time since
the bisect), run cputest + benchmarks, compare against the cache-off
baseline.
11. **#449 + #450** one consistent D-cache byte-lane map (write data, byte
    enables, read mux) — single commit.
12. **#451** fill owner/address latched at grant; other cache's miss held off
    during fill.
13. **#452** single fill-progress counter (decouple CacheCtrl ack counting from
    pmmu gating).
14. **#453** CACR multi-op: pending-bit clear so CI+CD / CEI+CED both execute.
15. **#455** shared-IO window excluded from cache lookup/allocate.
16. **#468** freeze gates line commit.
17. **#454** revert the bisect experiment (`cacr_ie/cacr_de` reconnected).
- **Verify:** new `tb_cache030_bytelanes.vhd` (4 offsets × size × R/W × hit/miss
  sweep with self-checking memory model); `tb_cache030_fill_race.vhd` (I-miss
  injected between D-fill grant and first ack; pmmu_busy pulse sweep across the
  first ack); `tb_cacr_clearu.vhd` (CACR $0808/$0404 → both caches invalidated).
  Then hardware soak: build RBF, boot WB3.1 + SetPatch (caches ON), run cputest
  basic suite + Lightwave/LHA benchmarks, verify no regression vs the
  cache-off bisect baseline.

## Phase 5 — L2 coherency  ✅ DONE 2026-07-24
Exposure refined during verification: ddram_ctrl already snooped every CPU
write (DDR path was coherent); sdram_ctrl snoops the CHIP port only, so
SDRAM-backed fast RAM was the real exposure. Fixed inside cpu_cache_new
(invalidate-on-inhibited-write-hit) for both instances; unit bench
test-l2-inhibit-snoop fails 4/4 on baseline, passes post-fix.
18. **#462** `cpu_cache_new`: tag-match invalidate on inhibited/walker writes
    (keep allocate gated).
- **Verify:** new `tb_l2_walker_um_snoop.v` at the sdram/ddram_ctrl level: read
  descriptor cacheably, walker U/M write, re-read → fresh value. Existing
  `tb_mmu_pte_coherency.v` should also cover this — extend it to L2 if it
  doesn't.

## Phase 6 — PMMU fidelity + cleanup
19. **#463** zero trailing TI fields at TC decode (single-point fix).
20. **#465** hold busy through the TC-validation cycle.
21. **#466** delete the dead ATC bypass block.
22. **#469** document (or implement) CACR WA.
- **Verify:** extend `tb_pmmu_comprehensive`/`tb_pmmu_all_modes_test` with a
  trailing-nonzero-TI config (TIA=8,TIB=12,TIC=0,TID=5) asserting UM-correct
  indices; PMOVE-TC-then-immediate-fetch timing test for #465. Cross-check
  against WinUAE `cpummu30.cpp` behavior where applicable.

## Phase 7 — Documentation
23. **#470** refresh `MMU_AUDIT.md` / `030_MMU_PORT_AUDIT.md`: fix the vector-56
    and PTEST-U-bit drift, correct the PFLUSHAN row, and append a
    BUG #447-#469 disposition table referencing this file.

## Cross-cutting regression gate (every phase)
- `make -C tests/tg68k_030` full suite (all existing `test-*` targets must
  pass).
- Quartus timing-clean build (`Minimig.qsf`), no new warnings in the touched
  hierarchies.
- Keep the working-tree declaration-hoist refactor as its own commit before
  Phase 1 (it is verified behavior-neutral and the testbench already depends on
  the new probe paths).

## Reviewed and found sound (no action)
Walker low/high word pairing & big-endian assembly; `walker_ramaddr` vs
`ramaddr_comb` encoding agreement; BUG #405/#419/#422/#424/#439 guards;
PMMU req/ack/berr handshake (race-free); BUG #409/#410/#414/#415/#416/#421/
#428/#435/#437/#438 fixes verified present; cpSAVE/cpRESTORE
privilege-before-EA ordering; STOP MSP/ISP swap direction & atomicity;
stage-C SSW gating consistency; fill tag/index latching (#131/#132);
chip/CIA/ROM never L1-cacheable; walker data never accepted as fill data
(#427); `cpu_cache_new` tag width & snoop port (except #462); autoconfig
chain/reset; leveled-PTEST/PLOAD TTR interaction, PFLUSH mask polarity,
MMUSR.N/B semantics (all UM-conformant).
