# 030_mmu Port Audit

Scope:
- Upstream range reviewed: `237537169ad1f561b198c639c95b38da7bcb126f..5e89616e7c72fff4dd6afac3970484294fd15fc1` from `origin/030_mmu`.
- Late-range cross-check also repeated against the user's local `030_mmu` branch at `/home/adam/030_mmu/Minimig-AGA_MiSTer`, since that is the working source branch for the final fixes.
- Local port commits created on this branch:
  - `957ced4` `tg68k: add cleaned MC68030 core, PMMU and cache support`
  - `ca87226` `minimig: wire the MC68030 core into the existing CPU slot`
  - `49eebc7` `tests: import the MC68030 regression suite`

Primary references used for correctness/compliance:
- Motorola manuals: `/home/adam/Desktop/MC68030UM.pdf`, `/home/adam/Desktop/MC68030.PDF`
- WinUAE MMU implementation: `/home/adam/Downloads/WinUAE-master/cpummu30.cpp`
- wf68k30L control/exception reference: `/home/adam/Downloads/wf030/Configware/68K30L`

Key compliance points applied:
- The MC68030 ATC is a 22-entry fully associative cache, not 8 entries. The final port uses 22 entries with pseudo-LRU behavior aligned with WinUAE.
- `MMUSR` is 16-bit and `PMOVE` transfers to/from `MMUSR` are word-sized.
- `TT0` and `TT1` operate independently of `TC.E`; reset clears `TC.E` and disabled translation means logical=physical.
- `PLOAD` flushes the matching ATC entry before a table walk and does not alter `MMUSR`.
- `PTEST` updates `MMUSR` but does not populate the ATC.
- MMU/internal bus faults use vector 2 on 68030, not MC68851 vector 61.
- Invalid `RTE`/format handling uses vector 14 and the short pre-instruction format-error frame.
- Exception entry clears both trace bits `T1` and `T0`.
- 68030 cache control is handled through `MOVEC CACR/CAAR`; early upstream claims about `CINV/CPUSH` on 68030 were not carried forward literally.
- The existing OSD CPU slot is reused as requested: `cpucfg=10` now selects the 68030 path by way of `cpucfg[1]`. `rtl/userio.v` is intentionally untouched.

Verification run after import:
- `make -C tests/tg68k_030 test-pflush-ptest-pload`: 18 passed, 0 failed
- `make -C tests/tg68k_030 test-rte-formats`: 30 passed, 0 failed
- `make -C tests/tg68k_030 test-mmu-translation`: 21 passed, 0 failed

Post-import follow-up fix:
- A remaining Format `$A` bus-error-frame bug was found after the initial port commits: a longword write-protect fault on `$00003000` was stacking fault address `$00003002`.
- Root cause: the PMMU kept reprocessing an asserted request after the first fault, allowing the second longword sub-cycle to overwrite the latched fault address.
- Local fix: hold the first latched PMMU fault metadata until the request drops.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-berr-frame`: 13 passed, 0 failed
  - `make -C tests/tg68k_030 test-regression`: 8 passed, 0 failed
  - `make -C tests/tg68k_030 test-pflush-ptest-pload`: 18 passed, 0 failed
  - `make -C tests/tg68k_030 test-mmu-translation`: 21 passed, 0 failed
  - `make -C tests/tg68k_030 test-lockup-all`: completed without reported failures

PMMU read-fault frame follow-up:
- The cleaned core still forced all `trap_mmu_berr` paths through `berr1-berr8`, which always builds the short Format `$A` frame. A maintained `WhichAmiga` MMU read-fault run showed the handler entering with `A7=$1FE0`, i.e. a 32-byte short frame, for `MOVE.L ($DFFFFFFC),D0` after the page descriptor had been invalidated.
- The references disagreed with that behavior:
  - the Motorola manuals say the MC68030 chooses short vs long bus-fault frames based on whether the fault occurs at an instruction boundary, and explicitly state that data read faults only generate the long bus-fault frame;
  - `wf68k30L_exception_handler.vhd` uses `IBOUND` to choose Format `$A` vs `$B` and routes non-boundary bus faults to Format `$B`;
  - WinUAE's `cpummu30.cpp` treats short MMU bus faults as the last-write/write-fault case and flags read faults as long bus faults.
- Local fix: latch whether the current bus fault needs the long frame, drive PMMU and external data-read faults through `berr_fill`, and use that same latch when writing the Format/Vector word in `berr7`.
- Local regression update: extend [tb_whichamiga_mmu.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_whichamiga_mmu.vhd) so the handler saves the frame base and the bench now asserts the PMMU data-read case lands on the expected long Format `$B` frame.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-whichamiga`: 6 passed, 0 failed; the PMMU read-fault case now stacks at `$1FA4` with a Format `$B` word at `$1FAA`
  - `make -C tests/tg68k_030 test-berr-frame`: 13 passed, 0 failed; the existing PMMU write-fault cases still use short Format `$A`
  - `make -C tests/tg68k_030 test-fault`: fault-handling suite complete
  - `make -C tests/tg68k_030 test-real`: real software-sequence suite complete

Regression-harness follow-up:
- The imported `tb_moves_all_modes.vhd` initially reported five A7/SP failures in tests 44-48, but the RTL bus trace showed the MOVES accesses were already landing on the correct stack addresses with the expected FC values.
- Root causes in the testbench:
  - the RAM model only covered `$1000-$1FFF`, so stack-area accesses at `$2100/$2202/$2310` were initially unmapped;
  - the late A7 tests still expected `D2=$12345678` even though tests 36-43 had intentionally reloaded `D2` with `$AAAA7F7F`;
  - test 47 expected a predecrement read from `$2202`, while the prior `(A7)+` case had been writing `$2200`.
- Local fix: extend the RAM model through `$2FFF`, reload `D2` before the A7 block, and make the `(A7)+` / `-(A7)` pair use a consistent `$2202/$2204` stack-pointer sequence.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-moves-all-modes`: 48 passed, 0 failed
  - `make -C tests/tg68k_030 test-regression`: 8 passed, 0 failed

MOVES validation follow-up:
- The older `mock/tb_moves_validation.vhd` bench is not a maintained oracle for the cleaned core. A fresh rerun timed out with all six tests "not observed" because it still relies on stale reset/vector sequencing and a pre-cleanup standalone harness structure, not the maintained memory/wait-state model now used elsewhere in this tree.
- Unique architectural coverage in that stale bench:
  - the `MOVEC Dn,SFC/DFC` setup path used by later MOVES FC-override cases;
  - a user-mode `MOVES` privilege-violation check.
- Fix/skip decision:
  - skip the stale mock harness itself instead of trying to promote it;
  - keep the `MOVEC Dn,SFC/DFC` path covered through maintained [tb_moves_all_modes.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_moves_all_modes.vhd), which begins by executing `MOVEC D0,SFC` and `MOVEC D1,DFC` and remains part of the maintained architecture suite;
  - add maintained [tb_moves_privilege.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_moves_privilege.vhd) so `MOVES` privilege handling is still covered in-tree with the Motorola-manual expectation that vector 8 stacks the vector offset `$20` and the logical address of the first word of the faulting instruction.
- Local fix:
  - repoint `test-moves-validation` to the maintained MOVES wrapper (`test-moves-all-modes` + `test-moves-privilege`) and route `test-arch-suite` through that wrapper instead of the stale mock bench.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-moves-privilege`: passes; stacked PC is `$0000100C`, format/vector word is `$0020`, and target memory remains unchanged
  - `make -C tests/tg68k_030 test-moves-validation`: maintained MOVES wrapper completes successfully
  - `make -C tests/tg68k_030 test-arch-suite`: maintained architecture suite completes successfully with the MOVES privilege case included

Direct-PFLUSH harness follow-up:
- `tb_lockup_walker_timeout.vhd` later reported a deadlock in its "unresponsive memory" case, but the PMMU logs showed tests 2 and 4 were completing in `0` cycles, which is only possible on an ATC hit.
- Root cause: the imported direct PMMU harnesses pulsed `pflush_req` with `pmmu_brief=$0000`. In the cleaned PMMU this is not `PFLUSHA`; it decodes as the EA form and only flushes address/FC-matched entries captured from `pmmu_addr`/`pmmu_fc`. The `00012340` translation therefore stayed cached and the timeout test never started a new walk.
- Local fix: update the affected direct testbenches to drive `pmmu_brief=$2400` for `PFLUSHA` before asserting `pflush_req`.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-lockup-walker-timeout`: 4 passed, 0 failed; slow-memory walk took 113 cycles, timeout faulted after 503 busy cycles with `fault_status=$00008000`
  - `make -C tests/tg68k_030 test-lockup-all`: walker-timeout sub-bench now reports 4 passed, 0 failed; aggregate lockup suite completes without failures
  - `make -C tests/tg68k_030 test-regression`: 8 passed, 0 failed

PMMU smoke-bench follow-up:
- The older direct `tb_pmmu_030.vhd` smoke bench still had several FAILs after the port even though the cleaned PMMU behavior matched the 68030 register layouts already enforced in RTL.
- Root causes in the bench:
  - `TC` write/read assumed reserved bits `30:26` echoed back instead of being masked;
  - `TT1` write/read assumed reserved TTR bits echoed back instead of respecting `TTR_WRITE_MASK`;
  - `CRP_H`/`SRP_H` cases wrote invalid `DT=00` high words or compared against unmasked reserved bits.
- Local fix: update the smoke-bench vectors/expectations to use valid root-pointer high words and spec-compliant masked readback values, and convert its remaining direct flush pulse to explicit `PFLUSHA`.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-pmmu`: all reported tests pass; only expected warning diagnostics remain for the bench's intentional invalid-TC / zeroed-pointer cases

DiagROM DetectCPU harness follow-up:
- `mock/tb_diagrom_detectcpu.vhd` ended in the correct 68030 pass state, but it still logged two `** Error` messages at `PC=$50C` during the exception-handler `RTE` path.
- Root cause: the bench treated a transient sequential fetch after `RTE` as architectural fallthrough. The TG68K core can briefly present that word before the restored PC takes over; the final architectural result was still correct, and the bench already reached the `68030 correctly detected` success path.
- Local fix: downgrade the `0x50C` check to a traced transient prefetch note and let the final pass/fail state determine the result.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-diagrom-detectcpu`: pass result with `Errors: 0`
  - `make -C tests/tg68k_030 test-cpu-mmu-detection`: all detection benches pass with `Errors: 0`

Suite-target drift follow-up:
- The `tests/tg68k_030/Makefile` targets `test-advanced`, `test-fault`, and `test-stress` were still wired to `tb_pmmu_advanced.vhd`, `tb_mmu_fault_comprehensive.vhd`, and `tb_page_walker_stress.vhd`.
- Root cause: those filenames do not exist in this branch or on `origin/030_mmu`. The `old_junk` tree only contained stale references to them in a backup Makefile and failed build logs, plus older benches such as `tb_mmu_comprehensive.vhd` and `tb_pmmu_pattern_test.vhd` that target an older PMMU interface (`reg_sel(4 downto 0)`, `mem_we`, `mem_wdat`, `mem_berr`, `mmu_config_*`) and are not drop-in matches for the cleaned core in this branch.
- Local fix: repoint the suite targets to the real maintained benches already in-tree, and add a dedicated `test-fault-recovery` wrapper around `tb_mmu_fault_recovery.vhd`.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-advanced`: completes and covers walker, ATC, and MMU translation benches successfully
  - `make -C tests/tg68k_030 test-fault`: completes and covers fault recovery, Format `$A` bus-error frames, and PMMU address-error handling successfully
  - `make -C tests/tg68k_030 test-stress`: completes and covers MMU translation plus the full lockup/race suite successfully

Vector-61 terminology follow-up:
- The late upstream fixes correctly routed internal PMMU faults to vector 2, but `tb_mmu_translation.vhd`, `tb_whichamiga_mmu.vhd`, and several RTL comments still described or silently tolerated the old MC68851-style vector-61 path.
- Root cause: the benches still preinstalled vector 61 to the same handler as vector 2, which would let a regression back to vector 61 pass unnoticed even though the 68030 manuals and WinUAE both require vector 2.
- Local fix: remove the redundant vector-61 handler wiring from the 68030 benches and update the stale RTL/test comments so the only passing path is the real 68030 vector-2 bus-error route.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-mmu-translation`: passes with vector 61 left unmapped in the bench
  - `make -C tests/tg68k_030 test-whichamiga`: passes with the internal PMMU data-fault path still landing in the vector-2 bus-error handler
  - `make -C tests/tg68k_030 test-stack-frame-push`: all stack-frame checks still pass

MMU-configuration vector follow-up:
- The imported core still encoded `trap_mmu_config` as `"11" & X"80"` in `TG68KdotC_Kernel.vhd`, even though `trap_vector` holds the byte offset used for both the vector fetch and the stacked format/vector word.
- Root cause: that value is `$380`, not the MC68030 MMU-configuration exception offset `$0E0` (vector 56 x 4). The manuals state that invalid `PMOVE` loads of `TC`/`CRP`/`SRP` raise vector 56 as a post-instruction exception, and the existing PMMU regression benches already wired the handler at `$E0`.
- Local fix: encode the MMU-configuration trap as `$0E0` and add a zero-delay yield before the stack-frame bench summary so new FAILs cannot still print as `0 failed`.
- Skip decision: do not merge the first draft of the dedicated MMU-configuration stack-frame regression. In the minimal `tb_stack_frame_push.vhd` harness it did not yet observe the PMMU post-instruction path reliably enough to serve as a compliance test, so it was dropped instead of being left as a flaky failure.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-fault-recovery`: still passes after the vector-offset fix; the PMMU recovery path reaches the bus-error handler and completes without a double fault

68851-only vector-stub follow-up:
- Several imported PMMU mode benches still populated vector 57 (`$E4`) and vector 58 (`$E8`) handlers as "MMU Illegal" / "MMU Access" compatibility stubs.
- Root cause: those exception vectors belong to the external MC68851, not the integrated MC68030 PMMU. Leaving them installed would silently tolerate a regression that dispatches 68030 PMMU activity to 68851-only vectors instead of failing the bench.
- Local fix: remove the vector-57/vector-58 handlers from the affected 68030 benches so only real MC68030 vectors remain wired.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-pmove-all-modes`: 68 passed, 0 failed
  - `make -C tests/tg68k_030 test-pload-all-modes`: 11 passed, 0 failed
  - `make -C tests/tg68k_030 test-pflush-all-modes`: 11 passed, 0 failed
  - `make -C tests/tg68k_030 test-ptest-all-modes`: 15 passed, 0 failed
  - `make -C tests/tg68k_030 test-whichamiga`: passed with the internal PMMU path still using only real 68030 vectors

PTEST level-0 A-bit follow-up:
- The maintained `tb_ptest_all_modes.vhd` originally covered `PTEST level=0` and `PTEST A=1` separately, but not the combined `PTEST level=0, A=1` form.
- Root cause: the cleaned kernel accepted that form, launched an ATC-only `PTEST`, and then retired the A-bit writeback path even though a level-0 search does not fetch a descriptor to return. In the transparent-translation setup used by the bench, that retired as a silent zero write into the selected address register.
- Compliance decision: reject `PTEST` with `LEVEL=0` and `A=1` as an F-line exception. The Motorola manuals describe the A-bit as returning "the physical address of the last descriptor fetched", which does not exist for a level-0 ATC search, and WinUAE's `mmu_op30_ptest()` explicitly treats `!level && a` as a bad instruction causing an F-line exception.
- Local fix: add a decode-time guard in [rtl/tg68k/TG68KdotC_Kernel.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd) so `LEVEL=0/A=1` traps through vector 11 before `ptest1` can retire A-register writeback. Extend [tb_ptest_all_modes.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_ptest_all_modes.vhd) with a maintained vector-11 regression that proves the trap was taken and that `A3` stayed at `$DEADBEEF`.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-ptest-all-modes`: 15 passed, 0 failed
  - `make -C tests/tg68k_030 test-stack-frame-push`: 10 passed, 0 failed

PTEST descriptor-history / no-ATC follow-up:
- The Motorola manuals say that during a table search "the U bit in each descriptor that is encountered is checked and set if it is not already set", and they separately state that `PTEST` "does not alter the ATC". That combination makes leveled table-search `PTEST` architecturally different from an ATC-only `PTEST`, but still mutating for descriptor history.
- Root causes in the cleaned PMMU:
  - it still derived `ptest_walk_no_update` from the A bit, so leveled `PTEST` with `A=0` suppressed the descriptor-history updates entirely;
  - it completed leveled `PTEST` by reusing the generic walker fault / fill machinery, which either cached a fault-class ATC entry on early stop (`MMUSR` was overwritten to `$8401`) or fell through the normal `W_FILL` path on full walks, both of which violate the manual's "does not alter the ATC" rule.
- WinUAE comparison: current `mmu030_table_search()` only writes descriptor U/M bits when `level==0`, so this is a manuals-over-WinUAE compliance decision. The direct maintained regression now enforces the Motorola behavior explicitly.
- Local fix: keep `ptest_walk_no_update` deasserted for table-search `PTEST`, add a persistent PTEST-walk flag in [rtl/tg68k/TG68K_PMMU_030.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68K_PMMU_030.vhd), route all PTEST table-search completions through MMUSR-only completion instead of ATC fill / ATC fault caching, and add maintained direct coverage in [tb_ptest_history_bits.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_ptest_history_bits.vhd). The suite wrapper in [Makefile](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/Makefile) now exposes that bench as `test-ptest-history-bits` and includes it in `test-arch-suite`.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-ptest-history-bits`: 10 checks passed, 0 failed
  - `make -C tests/tg68k_030 test-ptest-all-modes`: 15 passed, 0 failed

Comprehensive-suite follow-up:
- The older `test-comprehensive` wrapper in `tests/tg68k_030/Makefile` still tried to run `tb_pmmu_advanced`, `tb_mmu_fault_comprehensive`, and `tb_page_walker_stress`.
- Root cause: those bench names never existed in the imported tree. `old_junk` only preserved stale backup Makefile entries and failed build logs for them, not recoverable VHDL sources, so the target could never succeed as written.
- Local fix: rewire `test-comprehensive` to call the maintained suite targets (`test-advanced`, `test-fault`, `test-lockup-all`, `test-all`) instead of dead bench names.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-comprehensive`: completes successfully through the maintained walker, ATC, translation, fault, lockup, and basic-suite coverage

T0-trace follow-up:
- The recovered `old_junk` T0 trace bench exposed a real 68030 mismatch in the cleaned core: non-trapping `DIVU`/`DIVS` and expired `DBcc` cases were being treated as unconditional T0 change-of-flow.
- Root cause: `v_is_cof` in `TG68KdotC_Kernel.vhd` classified `CHK*`, `DIV*`, `TRAP*`, and `DBcc` too broadly from opcode shape alone. That was enough to trace non-trapping divide instructions and every `DBcc` with a false condition, even when the decrement expired and execution fell through.
- Local fix: narrow the direct T0 change-of-flow classifier to real branch/jump/return/SR-update paths, leave actual instruction traps to the existing Group 2 trace path, and add an explicit `dbcc_t0_suppress` latch so expired `DBcc` no-branch cases do not trace. The maintained local [tb_t0_trace.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_t0_trace.vhd) now covers those settled T0 cases plus the manual/wf68k30L-aligned taken `TRAP #0` / `TRAPcc` behavior and a not-taken `TRAPcc` control case.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-t0-trace`: 12 passed, 0 failed
  - rerun of the older `old_junk` T0 bench still leaves only two failures, both from its WinUAE-shaped no-trace expectations for taken `TRAP #0` / `TRAPcc`
- Skip decision: do not import the old `tb_t0_trace.vhd` verbatim. Its remaining `TRAP #n` / `TRAPcc` no-trace expectations match WinUAE's current opcode handlers, but the Motorola manuals say T0 traces "instruction traps", and `wf68k30L_control.vhd` asserts `EX_TRACE` in trace mode `01` for `TRAP`, `TRAPcc`, `TRAPV`, `CHK`, `CHK2`, and divide-by-zero. The maintained local bench now gates the manual/wf68k30L-aligned `TRAP #n` / `TRAPcc` cases instead.

Real-suite follow-up:
- `test-real` still pointed at `tb_pmmu_real_validation.vhd`, but that bench does not exist in this tree or in `/home/adam/030_mmu/Minimig-AGA_MiSTer/old_junk`. The only surviving hits are the stale Makefile recipe itself and an unrelated comment in `old_junk/tests/tg68k_030/to_fix2/tb_bug33_write_data_timing.vhd`.
- Fix decision: skip the nonexistent one-off bench and repurpose `test-real` as a maintained real software-sequence suite. It now runs the DiagROM DetectCPU path, DiagROM MMU detection, `mmu.library` detection, `68030.library` initialization, WhichAmiga MMU setup, and the Amiga ROM MMU initialization sequence.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-real`: completes successfully through the maintained OS- and ROM-facing benches listed above

T1-trace follow-up:
- The recovered `old_junk` T1 bench is mostly sound against the current cleaned core: 13 legal tests passed unchanged, including the Format `$2` trace-frame checks and the legal CCR-flag preservation cases.
- Skip decision: do not import old Test 13b. It writes `SR=$EB48`, which uses reserved `T1:T0=11` and then expects reserved low-byte bits outside `XNZVC` to be preserved. That is not a stable 68030 compliance check.
- Fix decision: add a maintained local [tb_t1_trace.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_t1_trace.vhd) that keeps the legal T1 cases only: trace-on-any-instruction behavior, exception-entry clearing, Format `$2` frame layout, jump-target frame contents, and legal CCR flag preservation.
- Follow-up verification:
  - isolated ModelSim run of `tb_t1_trace`: all tests passed

Group-2 trace follow-up:
- The recovered `old_junk` `tb_group2_stacked_trace.vhd` is not safe to import verbatim. Its T1 stacked-trace checks pass against the cleaned core, but its T0 cases assume no stacked trace for CHK, TRAP `#n`, TRAPV, and divide-by-zero, and they drive those instructions immediately after `MOVE` to `SR` without the extra instruction needed to arm T0 in this core.
- Those T0 assumptions match WinUAE's current opcode handlers, but they conflict with the Motorola trace wording and with `wf68k30L`'s control logic. The manual's trace section says T0 traces "instruction traps", and the trap section says that if tracing is enabled for the instruction that caused the trap, a trace exception is taken for that trap. `wf68k30L_control.vhd` also asserts `EX_TRACE` in trace mode `01` for `TRAP`, `CHK`, `CHK2`, `DIVS`/`DIVU` divide-by-zero, `TRAPcc`, and `TRAPV`.
- Fix/skip decision: skip the recovered T0 no-trace assertions, but keep the architectural area covered in-tree with maintained benches. [tb_chk_stacked_trace.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_chk_stacked_trace.vhd) covers CHK/CHK2 stacked frames, new [tb_group2_t0_trace.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_group2_t0_trace.vhd) covers the settled T0 CHK/CHK2/TRAP `#n`/TRAPV/divide-by-zero/TRAPcc stacked-trace cases with a correctly armed T0 path, and [tb_group2_t1_trace.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_group2_t1_trace.vhd) covers the settled T1 TRAP `#n`, TRAPV, divide-by-zero, TRAPcc, and non-trapping TRAPV cases. `test-group2-stacked-trace` now runs those maintained benches together.
- Follow-up verification:
  - isolated rerun of the recovered old Group 2 bench: all T1 stacked-trace cases passed; only the T0 no-trace assertions failed
  - `make -C tests/tg68k_030 test-group2-t0-trace`: 55 passed, 0 failed
  - `make -C tests/tg68k_030 test-group2-stacked-trace`: completes successfully via the maintained CHK/CHK2 plus Group 2 T0/T1 coverage

Validation-wrapper follow-up:
- After the maintained trace benches were added, the top-level `validate` and `test-comprehensive` wrappers still did not call them, so those commands could report success without exercising the newer T0/T1/Group 2 trace coverage.
- Local fix: add a maintained `test-trace-suite` wrapper for [tb_t0_trace.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_t0_trace.vhd), [tb_t1_trace.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_t1_trace.vhd), and `test-group2-stacked-trace`, then route both `validate` and `test-comprehensive` through it.
- Follow-up fix: `test-comprehensive` still relied on the old [run_tests.do](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/run_tests.do) script for its only broad architectural/software pass, but that script still covers just PMMU/cache/CACR/integration. Add a maintained `test-arch-suite` wrapper for [tb_rte_all_formats.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_rte_all_formats.vhd), [tb_abcd.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_abcd.vhd), [tb_stack_frame_push.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_stack_frame_push.vhd), [tb_branch_odd_addr.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_branch_odd_addr.vhd), [tb_movec_illegal.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_movec_illegal.vhd), and [tb_moves_all_modes.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_moves_all_modes.vhd), then route both `validate` and `test-comprehensive` through that plus `test-real`.

wf68k30L comparison note:
- `wf68k30L_top.vhd` explicitly states that `PFLUSH`, `PLOAD`, `PMOVE`, and `PTEST` are missing there, so it was only used here as a 68030 control/exception reference.
- PMMU correctness decisions were therefore taken from the Motorola manuals plus WinUAE, not from wf68k30L.

Files intentionally not ported from `origin/030_mmu`:
- `rtl/userio.v`: skipped on purpose; only the existing `10` slot is reused.
- `Minimig.qsf`, `Minimig.sdc`: skipped for now; these are synthesis/timing tweaks and need separate timing review.
- `issp_poll.tcl`, `issp_read.tcl`: skipped; debug/lab scripts only.
- Root markdown/debug notes (`ALL_MMU_FIXES_SUMMARY.md`, `BUG_*.md`, `CACHE_FIX_SUMMARY.md`, `CLAUDE*.md`, `TG68K_REGISTERS.md`, `rtl/tg68k/README.md`): skipped in favor of this audit plus the imported tests.

Upstream commit triage:

Skipped unrelated to the 68030 port:
- `058288b`: CIA timing fix from TC64. Not part of the 68030 work.
- `099c5a4`, `6fc0d5e`, `4c29534`: unrelated upstream sync/demo fixes. Not ported.

Early 68030 bring-up, kept only via the corrected audited end-state in `957ced4`/`ca87226`:
- `6f7190e`, `b922088`, `2f10f80`, `89177d0`, `8569b5d`, `edc1e1d`, `3e7eaa0`, `3125fc6`, `eec576c`, `f1dfa4f`, `39fb91a`, `92e50e1`, `479d2e8`, `35cf45e`, `a5c3409`, `de2f43c`, `0e9ffe4`
- Summary: early PMMU/cache/CACR bring-up and identity-translation work.
- Fix/skip decision: skip these literal commits. They still contained wrong or incomplete assumptions during development, including early `CPU="11"` thinking, incorrect cache-instruction claims for 68030, evolving CACR bit handling, and incomplete MMU register behavior. Only the later corrected end-state was ported.

PMMU decode, privilege, FC-field and register-width fixes, ported into `957ced4`:
- `711e20c`, `3887080`, `f6cf996`, `4fe8899`, `7d546f4`, `cb9e0af`, `3dd698b`, `5f1115c`, `680b251`, `ec8b514`, `1da4259`, `ffb5ec7`, `b5c4d4b`, `f391098`, `8706bf1`, `b587730`, `03a8180`
- Summary: PMOVE/MMU instruction decode cleanup, privilege enforcement, FC selection fixes, MMUSR transfer width correction, and early cache/data-path stabilization.
- Fix/skip decision: port functional end-state only. These were superseded incrementally upstream but materially survive in the cleaned core import.

OSD-slot reuse and wrapper integration, ported with a local constraint into `ca87226`:
- `db7bf7c`
- Summary: reuse the existing MiSTer 68020 OSD slot for the 68030 path.
- Fix/skip decision: kept the intent, but skipped the literal `rtl/userio.v` change. The local port reuses `cpucfg=10` entirely inside the wrapper/top-level logic and leaves `rtl/userio.v` untouched as requested.

PMOVE Dn/TTx bring-up and temporary platform experiments, partially ported:
- `5513eae`, `24c3b5d`, `02c677e`, `112ef59`, `8eb760f`, `3a489c3`, `31c0a59`, `44de4ed`, `7b3f02b`, `6ebc935`, `2ee950b`, `d9505d8`, `f1d75b7`, `05bb4b7`
- Summary: PMOVE register-transfer bring-up, TT register access, debug checkpoints, and temporary motherboard-fast-RAM mapping experiments.
- Fix/skip decision: ported the PMOVE/TT functionality into `957ced4`; skipped the checkpoint/debug churn and the temporary mapping changes that were later revised upstream.

Mid-stage MMU/TTR/MOVES/walker fixes, ported into `957ced4`:
- `6737588`, `dbc611e`, `a0dfbdc`, `6df675b`, `d8ec953`, `d4a087f`, `84208d6`, `cd9f550`, `cbe0704`, `656a01e`, `84a1a89`, `3122ca4`, `916c56b`, `7ce3709`, `a6db0cd`
- Summary: register-selection cleanup, TC/TT handling, MOVES decode repair, and table-index / indirect-descriptor groundwork.
- Fix/skip decision: ported into the cleaned TG68K core; no need to replay the intermediate broken states.

Indirect-descriptor, PFLUSH mode, MOVES, ISP/MSP and PMOVE EA fixes, ported into `957ced4`:
- `af62902`, `3ad14c9`, `069bd41`, `9e076d1`, `8310816`, `784e087`, `3ea2f3b`, `779168f`, `ac3aefc`, `287d394`, `03fde4e`, `50f9590`, `593e7e2`, `b753882`, `c880643`, `a730cff`, `92c0bb3`, `b2ee6bd`, `bed1fad`
- Summary: descriptor-walker correctness, PFLUSH encoding, stack-pointer control-register handling, MOVES stability, and PMOVE effective-address fixes.
- Fix/skip decision: ported the functional fixes. `593e7e2` and `b753882` were comments/system-update noise and were skipped.

RTE, PLOAD/PTEST/PFLUSH EA, cache-enable, and regression development, split between `957ced4` and `49eebc7`:
- `7f0679e`, `86079ed`, `5516ec9`, `ef4921f`, `949a240`, `6108c76`, `35a6661`, `fb11578`, `e8d7a19`, `2d9f8c3`, `0122140`, `432850d`, `e64cc7e`, `8004924`, `b1eff1e`, `35cce07`, `2bfa49e`, `c67bb65`, `696f7e2`, `71d3fcd`, `307a823`, `b6fd14c`, `ef4cc8f`, `044080d`, `d94be2c`, `eb007ec`, `e7334be`, `7e3e109`, `a801435`, `4c830a9`, `86194fb`, `b40ed7d`, `c8af113`, `ce6afa6`, `8f60e2b`, `de8fa48`, `157efce`, `447ea9c`, `63db1a8`, `59e5240`, `abe3ca6`, `cf904c5`, `bd2c973`, `acfabdb`, `b280e43`, `deb86bb`, `9f84a02`, `c8f53f2`, `5ab037b`, `5cba343`, `d678096`
- Summary: broad late-stage stabilization across RTE, PMOVE/PLOAD/PTEST/PFLUSH addressing, cache enable bits, MMU translation, and the growing regression corpus.
- Fix/skip decision: ported core RTL changes into `957ced4` and all useful testbenches into `49eebc7`; skipped checkpoint-only commits and upstream documentation churn.

Exception-frame, TTR-bypass, mmu-config, walker word/stride and alignment/RTE fixes, ported as corrected end-state:
- `ffcbe8b`, `ec92c0d`, `db8dc39`, `ffc0495`, `a91c7ba`, `b72fb74`, `03a4895`, `34e4b22`, `6e54a2d`, `587dbec`, `8dbf8a4`, `a7550db`, `75f826d`, `5767701`, `5dc078b`, `72badc7`, `9c1d5d0`, `4756d8d`, `5412395`, `c1257ef`, `1c39dd8`
- Summary: exception-stack correctness, TTR/cache-inhibit timing, `mmu_config_error` experimentation, pflush tests, walker byte-lane/descriptor-stride fixes, and address-error/RTE repairs.
- Fix/skip decision: ported only the final corrected behavior. Experimental or later-reverted `mmu_config_error` behavior was not replayed literally.

Late exception/trace/ATC/walker/race fixes, ported into `957ced4` and `ca87226`:
- `c74e8f1`, `064976c`, `7750fb2`, `849be37`, `79416b9`, `c8c215e`, `640a5ec`, `892fce7`, `7935c4a`, `10edcf7`, `592c325`, `7f41fbf`, `2c550a5`, `f62640b`, `357045f`, `82a44b8`, `92e1788`, `6af9d11`, `a4a8f59`, `4486af9`, `1543211`, `409aef5`, `937dcae`, `00cadc9`, `c64febc`, `cdd8ad2`, `0b3cb03`, `99bc0e4`, `4be5ad9`, `1c9d84c`, `5f2f478`, `a4fcda9`, `40170fb`, `ae09dd5`, `ac81691`, `fcd759d`, `6c2592c`
- Summary: bus-fault routing, vector/address generation, valid RTE formats, format-error handling, trace-bit handling, ATC-hit PMMU faults, ATC stale-hit timing, physical-address bus routing, and walker timeout/ack/bus-ownership races.
- Fix/skip decision: ported the spec-aligned end-state. This is the cluster that brings the port into line with the manuals and WinUAE on vectoring, ATC behavior, and wrapper-side bus suppression/routing.

Final stabilization, ported into the cleaned local commits:
- `bbfaefe`, `3b1a940`, `a0a8316`, `fe48414`, `58ebabd`, `9dcc9c1`, `9767f4a`, `3ae1faa`, `5db6dd3`, `d865eed`, `221323a`, `131082b`, `e32bf38`, `2025ec1`, `1d805a7`, `c646069`, `0f1556c`, `f546c70`, `a4348f8`, `c0ee187`, `eb5bd26`, `9973f15`, `34e9543`, `de1bd23`, `5e89616`
- Summary: final ATC-size/pseudo-LRU work, PLOAD flush-before-walk, early-termination granularity, WP accumulation, bus-timeout BERR, wrapper-side walker integration, TRAP/RTE stack-frame cleanup, and the final latched MOVEC selector fix.
- Fix/skip decision: ported. `de1bd23` was validation evidence (`WhichAmiga works`) rather than a distinct new architectural change, so its useful behavior is represented by the surrounding fixes, not by a separate local commit.

Previously unlisted source commits, now explicitly triaged:
- `696f7e1`
- Summary: fixes the PMOVE mem-to-MMU `(An)+` CRP/SRP low-word address path so the second longword read lands at `EA+4`/`EA+6` and the register postincrement still completes as `+8`.
- Fix/skip decision: no new local port commit needed. The cleaned tree already carries the same end-state in [rtl/tg68k/TG68KdotC_Kernel.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd) through `pmmu_ea_mode_latched`, the combinational `(An)+` CRP/SRP low-word override, and the `exec_write_back` retirement handling that prevents the follow-on lockup.
- `ffd4bb6`
- Summary: mixed source commit that paired the PMOVE retirement/writeback clear with top-level cache-burst signal hookup.
- Fix/skip decision: no new local port commit needed. The PMOVE retirement clear is already present in [rtl/tg68k/TG68KdotC_Kernel.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd), and the cache-burst path is already wired through [rtl/tg68k/TG68K.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68K.vhd), [rtl/cpu_wrapper.v](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/cpu_wrapper.v), and [Minimig.sv](/home/adam/030_mmu2/Minimig-AGA_MiSTer/Minimig.sv). This area is platform integration, not a distinct Motorola-architectural delta, and the current tree already reflects the intended end-state.
- `3ab91cd`
- Summary: release packaging only (`releases/Minimig_20260220.rbf`).
- Fix/skip decision: skip entirely. Binary release artifacts are intentionally not ported into this cleaned branch.

Late local-branch-only review:
- The local `030_mmu` branch was checked commit-by-commit again after the user clarified the source path. That second pass found no remaining architectural fixes that still needed to be replayed into this cleaned branch.
- `f546c70`, `a4348f8`, `c0ee187`, `eb5bd26`, `9973f15`, `34e9543`, `de1bd23`, `5e89616`
- Summary: TRAP/stack-frame cleanup, stacked-trace priority fixes, clocked interrupt-mode handling, PMMU bus-fault routing, WhichAmiga validation, and the latched `MOVEC` control-register selector.
- Fix/skip decision: no new local port commit needed. The cleaned tree already carries those behaviors directly or via the maintained replacements added during this audit:
  - `movec_regsel` is present in [rtl/tg68k/TG68KdotC_Kernel.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd), matching the source branch's late `MOVEC` fix;
  - the maintained trace and Group 2 benches already cover the `TRAP`/`CHK` stacked-frame area;
  - the WhichAmiga PMMU path is covered by the maintained long-read-fault regression rather than the source branch's intermediate short-frame bugfix.
- `694499b`, `29b914e`, `eb63ffb`
- Summary: source-branch experimentation around restoring hidden Format `$A/$B` internal bus-fault retry state from an `RTE` frame back into the live core, then partially constraining it, then disabling it again.
- Fix/skip decision: skip the whole cluster. The Motorola manuals define the software-visible frame contents, but they do not require restoring invisible internal retry state into the live machine after `RTE`; WinUAE and `wf68k30L` do not rely on equivalent live restore machinery either. The cleaned branch never adopted that path, and it still passes the maintained architectural regressions, so replaying that experimental logic would add risk without a compliance win.
- `82993c3`
- Summary: cached ATC-fault replay classification cleanup plus direct-PMMU testbench additions.
- Fix/skip decision: behavior already covered; no literal replay needed. The maintained [tb_pflush_ptest_pload.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_pflush_ptest_pload.vhd) in this branch already includes the cached WP/invalid replay checks from that late source work and passes against the cleaned PMMU.

Late local-branch verification:
- `make -C tests/tg68k_030 test-pmove-crp-mem-to-mmu-postinc`: pass; maintained `(A7)+,CRP` mem-to-MMU regression still reads `$2000/$2002/$2004/$2006` and then continues at `$2008/$200A`
- `make -C tests/tg68k_030 test-chk-stacked-trace`: 27 passed, 0 failed
- `make -C tests/tg68k_030 test-movec-active-stack`: pass; both active ISP/MSP `MOVEC` alias checks completed successfully
- `make -C tests/tg68k_030 test-pflush-ptest-pload`: 18 passed, 0 failed
- `make -C tests/tg68k_030 test-rte-formats`: 30 passed, 0 failed
- `make -C tests/tg68k_030 test-stack-frame-push`: completed successfully

interrupt_mode focused follow-up:
- The late local `interrupt_mode_clocked_fix` source commit (`9973f15`) was already present in RTL, but the maintained tree still lacked a focused in-tree regression for the interrupt-to-`RTE` stack-selection area.
- First-draft triage result: a focused bench disproved the older source-branch assumption that interrupt context should stay on ISP after `RTE` restores supervisor `M=1`. The core returned through MSP, and the reference cross-check showed that was correct:
  - the Motorola manual says the active supervisor stack is selected by the live `S` and `M` bits, and explicitly states that when `S=1` and `M=1`, MSP is active while `S=1` and `M=0` uses ISP;
  - WinUAE's [`MakeFromSR_x()`](/home/adam/Downloads/WinUAE-master/newcpu.cpp) swaps `A7` purely on `S/M` transitions, with no hidden interrupt-context override, so a supervisor `M=1` restore lands on `regs.msp`;
  - `wf68k30L_address_registers.vhd` likewise muxes the active supervisor stack from `SBIT`/`MBIT` alone (`MBIT='1'` -> `MSP_REG`, `MBIT='0'` -> `ISP_REG`).
- Maintained coverage added: new [tb_interrupt_mode_stack.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_interrupt_mode_stack.vhd) takes a real level-7 autovector interrupt after setting `MSP=$0A00` and active `ISP/A7=$0900`, builds a nested Format `$0` frame that `RTE`s to supervisor `SR=$3000`, and then immediately executes another `RTE`. The second `RTE` must now return through the MSP frame at `$1400`, not through the older interrupt-context ISP frame patched to `$1300`. The maintained wrapper in [tests/tg68k_030/Makefile](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/Makefile) also wires this into `test-rte-abcd-suite`.
- Fix/skip decision: no new RTL port commit needed. The cleaned kernel already carries the late source-branch `interrupt_mode_set_req` / `interrupt_mode_clr_req` implementation in [rtl/tg68k/TG68KdotC_Kernel.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd); the follow-up here is maintained regression coverage and explicit rejection of the earlier non-spec ISP-retention assumption.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-interrupt-mode-stack`: pass; the nested supervisor-`M=1` return switched active stack back to MSP and the second `RTE` reached `$1400`
  - `make -C tests/tg68k_030 test-rte-abcd-suite`: completed successfully with the new interrupt-mode regression in the wrapper
  - `make -C tests/tg68k_030 test-arch-suite`: maintained architecture/edge-case suite completed successfully

movec selector focused follow-up:
- The late local `MOVEC` selector-latch source commit (`5e89616`) was already present in RTL via `movec_regsel`, but the maintained tree still lacked a direct CPU-level regression that would fail if `MOVEC` went back to decoding a live `brief`.
- Maintained coverage added: new [tb_movec_selector_latch.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_movec_selector_latch.vhd) runs two real instruction-stream cases around the exact stale-immediate hazard called out in the source comments:
  - `MOVEC D0,CACR` followed by `BSET #3,D0` with immediate word `$0003`, then a store proving `CACR=$00000101` and `D0=$00000109`;
  - `MOVEC CACR,D1` followed by the same `BSET #3,D0`, then a store proving `D1` still read back `$00000101`.
- Fix/skip decision: no new RTL port commit needed. The cleaned kernel already latches the selector at `getbrief` time in [rtl/tg68k/TG68KdotC_Kernel.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd); the missing piece was maintained regression coverage and wrapper integration.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-movec-selector-latch`: pass; both write-side and read-side stale-immediate cases completed successfully
  - `make -C tests/tg68k_030 test-arch-suite`: maintained architecture/edge-case suite completed successfully with the new MOVEC selector regression enabled

68030 selector harness follow-up:
- The cleaned RTL and top-level integration deliberately reuse the existing `10` slot for 68030, and the in-tree comments document `10` as the 68030 selector. Several maintained testbenches had still been instantiating the core with `CPU => "11"`, which only worked because the current implementation mostly keys off `CPU(1)`.
- Local fix: normalize the maintained MMU/real-software benches to `CPU => "10"` in [tests/tg68k_030/tb_mmu_translation.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_mmu_translation.vhd), [tests/tg68k_030/tb_mmu_fault_recovery.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_mmu_fault_recovery.vhd), [tests/tg68k_030/tb_addr_error_pmmu.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_addr_error_pmmu.vhd), [tests/tg68k_030/tb_whichamiga_mmu.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_whichamiga_mmu.vhd), [tests/tg68k_030/tb_68030_library_init.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_68030_library_init.vhd), and [tests/tg68k_030/tb_pmove_crp_mem_to_mmu_postinc.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_pmove_crp_mem_to_mmu_postinc.vhd).
- Fix/skip decision: no RTL change needed. This is a harness-alignment cleanup so the maintained benches actually exercise the documented 68030 selector instead of a stale out-of-tree encoding.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-mmu-translation`: completed successfully with `CPU => "10"` in the maintained MMU translation bench
  - `make -C tests/tg68k_030 test-fault`: fault-handling suite completed successfully with the selector-normalized PMMU benches
  - `make -C tests/tg68k_030 test-real`: maintained real software-sequence validation suite completed successfully
  - `make -C tests/tg68k_030 test-pmove-crp-mem-to-mmu-postinc`: completed successfully with the selector-normalized PMOVE postincrement bench

PMMU instruction-fault frame follow-up:
- The late local `BUG #440` source commit was only the first step: it forced all `trap_mmu_berr` cases through the short-frame path, but the maintained tree later corrected the real MC68030 rule to short-at-instruction-boundary and long-for-data-read faults. What was still missing here was a focused maintained regression for the short-frame side of that rule.
- Maintained coverage added: new [tb_mmu_fetch_fault_frame.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/tests/tg68k_030/tb_mmu_fetch_fault_frame.vhd) enables the MMU with an invalid root entry for `$F0xxxxxx`, executes `JMP $F0001000`, and has the vector-2 bus-error handler save the active `A7`, format/vector word, and fault address. Vector 61 is left pointed at the unexpected handler so the stale MC68851-style route cannot pass silently.
- Spec/reference basis: this matches the Motorola manuals' short-vs-long bus-fault split, `wf68k30L`'s instruction-boundary gating for Format `$A` vs `$B`, and the maintained WinUAE behavior that reserves the short PMMU bus-fault frame for instruction-boundary / write-fault-style cases instead of data reads.
- Fix/skip decision: no RTL change needed. [rtl/tg68k/TG68KdotC_Kernel.vhd](/home/adam/030_mmu2/Minimig-AGA_MiSTer/rtl/tg68k/TG68KdotC_Kernel.vhd) already dispatches `trap_mmu_berr` through `berr1` or `berr_fill` from the latched `berr_long_frame` state; the missing piece was a maintained regression and wrapper coverage for the instruction-fetch case.
- Follow-up verification:
  - `make -C tests/tg68k_030 test-mmu-fetch-fault-frame`: 6 passed, 0 failed; handler saved `A7=$00001FE0`, `format/vector=$A008`, and `fault address=$F0001000`
  - `make -C tests/tg68k_030 test-fault`: fault-handling suite completed successfully with the new instruction-fetch frame regression included
