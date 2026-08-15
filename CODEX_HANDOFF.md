# Handoff: AP040 cputest chip-RAM corruption investigation

## RESOLVED 2026-08-15: the two cputest failures are DATA ARTIFACTS.
## AP040 produces the correct 68040 result.  See the update below.

## Claude update: 2026-08-15 (final), .dat decode -- cputest generator bug

Ground truth from the user's own FABS.X data files (DATA_VERSION 20,
2020-era), decoded with tests/ap040/decode_cputest_dat.py and replayed
with tests/ap040/replay_cputest_dat.py:

1. The failing test (setup #178 in 0001.dat, runtime testcnt 1788 =
   displayed 1789) is fabs.x ([0]),fp3 with the operand at $401b.  Its
   setup does NOT write the pointer at absolute 0.
2. The test before it (#177) rewrites mem[0]: old=0000401d NEW=0000401b.
3. cputest's RUNTIME (main.c) records every setup CT_MEMWRITE and
   REVERTS it at the end of the test (restoreahist), so when #178 runs,
   mem[0] has been restored to 0000401d.
4. cputest's GENERATOR (cputest.cpp) resets its access history per test
   WITHOUT undoing it (ahcnt_current = 0), so its memory model keeps
   mem[0]=0000401b and it computed #178's expected FP3 from $401b.
5. Under the runtime's actual memory, the CORRECT result of #178 is the
   extended window at $401d: se=401c (the pad bytes of the $401b
   operand), mantissa d82c00000000 + the untouched lmem bytes df00 =
   401c-d82c00000000df00 -- BYTE-FOR-BYTE what AP040 returned, on every
   build, both cache settings, forever.  A real 68040 would "fail" this
   test identically.
6. FADD.P ([D0.w*8]) decodes to the same family: frame EA 80090AA1 =
   reverted mem[0] (8009xxxx-era value) + $AA0.  (Verifiable the same
   way by pulling the FADD.P directory and replaying.)

The mismatch only bites when a test depends on memory it does not itself
rewrite, one test after that memory was rewritten -- which is why only
these two tests fail out of the whole suite, deterministically.

Remedy: regenerate cputest data with a current WinUAE, or treat these
two failures as known-phantom for v20-era data.

Everything real found during the hunt remains fixed and validated:
ram_cs_guard consumption-keyed redesign (48/48 phase sweeps, deployed
RBF sha 2b4040af...), walker snoop contract, dual-controller bench,
pointer-rewrite and harness-replica tests, .dat decode tooling.

## Claude update: 2026-08-15 (later), ram_cs_guard consumption redesign

### The +datasplit sweep completed the diagonal and root-caused the wedge

With data routed through both controllers, the sweep hangs extended to
(0,0) and (3,3): the ENTIRE (CYC-CPU) mod 4 == 0 diagonal wedges.  Traced
with registered-only views (+gt in tb_dualram_turbo): the guard's re-arm
loop (serve -> cyc-kill -> re-arm -> serve) is phase-locked at 4 clk_114
per round at these alignments, so ramready is low at EVERY clk28 sample
point -- a livelock.  No cyc-phase-marker kill can be correct at every
PLL alignment: the marker can precede every real consumption edge.

### Redesign: consumption-keyed, age-qualified deselect

- rtl/cpu_wrapper.v: new output `ramconsumed` -- registered strobe, one
  CPU clock wide: the CPU sampled ramready for an active RAM request on
  the previous clk_sys edge (the actual level-ack consumption event).
- rtl/ram_cs_guard.v: kill keyed on that strobe's RISE, qualified by
  `ready_age >= 4` (ack continuously high since before the consumption
  edge = the consumed, stale ack; a younger ack is a FRESH serve of the
  next sub-cycle and must not be killed -- killing it re-serves every
  transfer and cost ~5-10x wall clock in the first attempt).  killed
  re-arms when the ack visibly drops, which manufactures the CS gap the
  level-ack protocol needs.  `cyc` is no longer a guard input (Minimig.sv
  keeps generating it for fastchip only).
- Minimig.sv wires wrapper.ramconsumed -> guard.ram_consumed.
- Former livelock combo (0,0)+datasplit now passes at full speed
  (445823 cycles vs 444031 healthy baseline).
Validation complete: full regression green and ALL THREE 16-phase sweeps
(tb_sdram_turbo, tb_dualram_turbo plain, tb_dualram_turbo +datasplit)
pass 48/48 -- the first all-green sweep since the phase investigation
began, diagonal included.  CYC_PHASE is now a dead parameter in the
benches (retained only to prove alignment-independence).

Build: SEED 9 missed clk_114 by -0.138 (violator = the long-standing
cpu_cache_new dtram->cpu_dat_r read-hit cone, NOT the new guard; checked
via quartus_sta path extraction).  SEED 10 (now in Minimig.qsf) closes
everything: clk_114 +0.153, hdmi +0.195, 0 errors.  RBF deployed to
/media/fat/Minimig-040_20260815.rbf, sha256
2b4040afd0ab637cb17f8ab4e44e072db3286157af6ff9b93841693c19bafdbe
(= output_files/Minimig.rbf).  NOT loaded remotely -- the user loads it.

Next: load the new RBF, rerun cputest basicfpu FABS.X (and FADD.P).  If
it still fails, copy data/68040_basicfpu/FABS.X/*.dat.gz (and the cputest
binary) from the Amiga volume onto the FAT partition so the .dat decode
and the exact 1788x16-rounds -> restore -> 1789 replication can proceed.

If hardware's fixed alignment sits at or near the critical diagonal, the
OLD kill logic (build 41's one-cycle kill and the interim latch/re-arm
variants) could mis-pair level acks with sub-cycles rather than hang --
the shape of the FABS.X/FADD.P stale-half signature.  A rebuild with this
guard is therefore worth a hardware retest of cputest FABS.X even before
the .dat ground-truth work.

## Claude update: 2026-08-15, probe clean, harness replica in sim, dat files needed

### ptrfabs result: ALL ZERO -- the minimal sequence is correct on hardware

150000 hardware iterations of rewrite-pointer -> fabs.x ([0]) -> verify
(interrupts off/on, static control) all pass.  The corruption REQUIRES
cputest's context.  Also corrected a misreading: in cputest's "Registers
before" dump a '*' means "this register was correctly MODIFIED by the
test" (out_regs in cputest/main.c; mismatches are '!'), so the starred
FP3/FPIAR before test 1789 were NORMAL -- no pre-test divergence existed.

### What cputest actually does between tests (from WinUAE sources)

- main.c tomem(): memory setup/restore writes are BYTE-wise C stores
  (so the pointer longword at 0 is rewritten as four move.b's, or
  compiler-merged), and restoreahist() undoes test writes byte-wise in
  reverse.  FABS.X got=4023-window differs from expected by ONE BYTE at
  address 3 (21 vs 23); FADD.P frame EA by one WORD at 0-1 (8009).
- asm.S execute_testfpu: before EVERY test: fmovem.x mem,fp0-fp7 (96
  bytes, images include NaN/-0/pseudo-denormals), fmove.l ->fpiar/fpcr/
  fpsr, movec USP/MSP, movem.l all integer regs, RTE into the USER-mode
  test block; the test block tail is fnop + illegal (captured).
- Each test runs 16 rounds ("(0/16)"); the failing round is 0, but the
  PREVIOUS test's 16 rounds (operand presumably 2 lower in the walk) ran
  immediately before.

### Sim: full harness replica added and green everywhere

t_fpu tests 279-284: byte-wise pointer rewrite (tomem order), fmovem.x
reload of the EXACT 8-register image from the failing screenshot, FPIAR
canary/FPCR/FPSR loads, movem.l of the captured integer file, RTE into a
user-mode block (fabs.x ([0]) + fnop + trap #0 back).  Passes on every
bench.  tb_dualram_turbo gained +datasplit: DATA routed by address like
the real machine (vector page + $3600-37FF scratch + $F0xx control ports
= chip/sdram; code, stack, register images, exception frames = Z3/ddram).
Full t_fpu green under +datasplit as well (13-phase sweep result below or
in scratchpad sweep_ds).

### Current status of the mystery

Hardware fails test 1789 deterministically in full cputest context; every
sim replication of that context passes, and the minimal on-hardware probe
passes.  The unexplored deltas, in order of value:
1. GROUND TRUTH: pull data/68040_basicfpu/FABS.X/*.dat.gz and the cputest
   binary from the SD (board was offline at last attempt -- needs power).
   Decode the .dat (parser = cputest/main.c restore functions) to get the
   REAL neighbor tests 1786-1789: pointer values, register images, memory
   deltas, SR rounds; disassemble the binary's tomem to see byte vs word
   stores.  Then replicate the exact 1788(x16 rounds)+restore+1789
   sequence in sim.
2. The 16-round loop per test (SR/CCR/FPCR variants) and the result
   capture (fmovem/movem STORES through Z3) between rounds.
3. Real chipset DMA burst patterns (display fetch blocks vs the bench's
   alternating-CCK reads).

## Claude update: 2026-08-13 (day), A/B results, oracle check, standalone probe

### Hardware A/B result: D-Cache does NOT matter

On a freshly built RBF (with the ram_cs_guard fix), MiSTer System->D-Cache
ON and OFF both fail FABS.X BYTE-IDENTICALLY (photo confirmed: same
401c-d82c00000000df00, same E11=1280 E55=16).  dcache_d re-samples live at
~cpu_req, so the toggle was effective.  Two disjoint memory routes with
different timing producing identical wrong bytes ELIMINATES the memory
fabric (sdram/ddram/cache/guard) as the cause.  The fault is in the layer
both routes share: ap040_core EA/operand engine or the bus16 adapter --
or it requires cputest's carried-in context.

### Oracle check: FABS.X of a pseudo-denormal does NOT trap vector 55

WinUAE softfloat-specialize.h: floatx80_is_denormal AND _is_unnormal both
require the explicit integer bit CLEAR.  The failing operand (exp 0000,
bit63 SET, mantissa b6ba...) is neither -> executed directly, no v55, on
both the reference and AP040 (ap040_fpu.v unsupported_x agrees).  So the
wrong FP3 comes from the CPU's own pointer/operand fetch, not a handler.
Unified decode of both hardware failures:
  FABS.X: mem[0] pointer read as 0000_4023 (LOW half stale)
  FADD.P: mem[0] pointer read as 8009_0001 (HIGH half stale), EA=+D0*8
i.e. the just-rewritten pointer longword at absolute 0 delivers one stale
16-bit half to the EA engine.  (FADD.P being packed DOES trap v55; its
frame EA faithfully reports the bad pointer arithmetic.)

### Sim now covers the exact cputest sequence -- and passes everywhere

t_fpu.s tests 265-278 (new): rewrite the pointer at 0 and IMMEDIATELY
dereference with the exact encodings (F236 4998 95D1 / F231 4CA2 0795),
alternating pointer values that differ in one half; plus an integer
([0]) control and an alternating-EA packed/v55 frame-EA loop.  Full
run_tests.sh green on every bench: flat (latency sweeps), real chip
bridge + DMA, sdram turbo, dual-controller.  The modeled paths execute
the sequence correctly at every modeled fidelity.

### Standalone hardware probe: tests/ap040/hw/ptrfabs.s

Since sim is exhausted at current fidelity, the next decisive datum comes
from hardware WITHOUT cputest's context.  hw/ptrfabs is an AmigaOS
executable (assembled with vasm -Fhunkexe, 852 bytes) already copied to
the board at /media/fat/ptrfabs (md5 d23bd96a7bbae859217361ccc91a9bf8).
It runs 50000 iterations x three phases of the exact sequence against an
operand image in AllocMem'd CHIP RAM:
  A: interrupts Disabled, pointer rewritten before every dereference
  B: interrupts ENABLED,  pointer rewritten before every dereference
  C: interrupts Disabled, pointer static (control)
Prints "A:<fails> B:<fails> C:<fails> F:<first bad 12 bytes>".
Decision tree:
  B>0, A=C=0  -> mid-instruction interrupt interaction in the core
  A,B>0       -> rewrite-then-dereference breaks core-side, context-free
  all zero    -> the failure needs cputest's carried-in state; note the
                 screenshot's "Registers before" already shows FP3 and
                 FPIAR mismatches (*70b4-..., *ffffffff) -- AP040 had
                 diverged BEFORE test 1789; find the first diverging test
                 in FABS.X/0001.dat and replicate ITS preceding state.

## Claude update: 2026-08-13 (night), phase sweeps, guard fix, dual-controller bench

### Reinterpretation of the failure signature (important)

The `got` value in the 2026-08-13 screenshot decodes EXACTLY as the extended
operand at $4023, including the pad word: se=401c is $4023-4024, mantissa
d82c00000000df00 is $4027-402E.  So the EA itself was $4023: the memory-
indirect POINTER longword at absolute 0 read back 00004023 -- plausibly the
PREVIOUS test's pointer value -- instead of the just-written 00004021.  The
FADD.P failure (first pointer word stale 8009, second correct) is the same
signature on word 0.  Unified statement of the bug:

    A 16-bit word freshly written to chip RAM reads back its previous
    contents through the turbo data path.

This is why only these two cputest cases fail: they are the only ones whose
pointer/operand chain lives in chip RAM and is REWRITTEN immediately before
each use.  t_fpu tests 245-248 replicate the encodings but write the pointer
once, so they cannot see it.  A focused test program (see next steps) should
mimic cputest exactly: rewrite the pointer at 0, immediately dereference
([0]), loop with alternating values.

### 16-phase sweeps reproduced a real defect (and it is now fixed)

Recreated the CYC_PHASE x CPU_PHASE sweep (16 combos, DMA contention on).
On the tree as of this morning: 8/16 combos DEADLOCK at boot, rule
(CYC-CPU) mod 4 in {0,3}.  Mechanism traced cycle-by-cycle: the level-held
ready of a consumed request is still high 1-2 clk113 after the consumption
edge; when cyc lands in that tail, ram_cs_guard latched ram_killed and only
cleared it on !ram_sel -- but the 28MHz side can move seamlessly from a
consumed request into the next one without dropping ram_sel, so the kill
never re-armed and the new request starved forever.

Fix applied to rtl/ram_cs_guard.v: re-arm when ram_ready falls, not only
when ram_sel falls.  The CS gap that clears the controller's stale level-ack
is still manufactured; the request is then re-served fresh.  Validated:
full regression green, both sweeps improve 8 fails -> 3, no combo regressed.

RD_DELAY (SDRAM model read latency) is NOT a useful sweep axis: it shifts
whole chip-clock beats, i.e. models CL3 against a controller hard-wired for
CL2, and everything hangs.  Real hardware cannot sit at a different beat
alignment without a timing violation, and timing-clean build 41 also failed.

### Dual-controller co-sim exists now: tb_dualram_turbo.v

tests/ap040/tb_dualram_turbo.v is fidelity gap #1 from the list below made
real: cpu_wrapper + the REAL sdram_ctrl (chip data) + the REAL ddram_ctrl
with its own cpu_cache_new (instruction fetches in a Z3-style window) + the
combinational ready/data/CS muxes of Minimig.sv, one shared ram_cs_guard,
behavioral SDR SDRAM and DDR3/Avalon models backed by one coherent image.
Full t_fpu passes at the default phases; it is wired into run_tests.sh.
Model contract learned the hard way: the HPS bridge never presents
DDRAM_DOUT_READY during a DDRAM_BUSY cycle -- ddram_ctrl samples ready only
while ~busy -- so a model that violates that wedges the fetch path.
The +bt_lo/+bt_hi plusargs dump a per-cycle routing-layer trace.

The dual sweep shows the SAME 8-hang pattern as the single-controller sweep
(pre-fix) and the same 3 residual fails (post-fix): the cross-controller mux
structure adds no new failure at this fidelity and produces no corruption.

### Open items, in order

1. Residual sweep fails at (cyc,cpu) = (1,1), (1,2), (2,2) on BOTH benches:
   a DIFFERENT wedge -- the core parks in a memory-wait state (state 10,
   pc=$406 running clr.w absolute writes) while the wrapper shows the RAM
   bus idle (ram_sel=0), i.e. an ack was consumed out of step between the
   bus16 adapter and the core, not a guard starvation.  All three were
   already failing before the guard fix (strict improvement, no regression).
   May be an UNPHYSICAL TB alignment: ph1/ph2 are div-locked at 2/10 while
   clk28 sweeps, and the real PLL guarantees a straddling alignment.
   Root-cause with a core/adapter-level trace before drawing conclusions.
2. Write the pointer-rewrite test program (t_ptrchase): loop { move.l Pn,
   $0; fabs.x ([0]),fpN; verify }, alternating Pn between two odd chip
   addresses with distinct extended values; also a move.w-to-$2-only
   variant.  Run through tb_sdram_turbo/tb_dualram_turbo across phases and
   with the external-cache force ON and OFF (the tb ORs 4'b0011 into
   cpu_cache_ctrl; parameterize that to model the Amiga-menu-caches-off
   configuration cputest actually ran under).
3. The MiSTer System -> D-Cache OFF A/B on hardware remains the decisive
   experiment for the turbo-vs-legacy route (see Codex update below).
4. After the A/B: rebuild with the guard fix (production RTL changed!) and
   retest FABS.X on hardware.  The guard fix removes a proven lurking
   deadlock but on the evidence so far it is NOT expected to cure the +2:
   the failing RBF contains the latch guard, whose failure mode is a hang,
   not corruption, so hardware sits at a non-kill alignment.

Sweep runner recipes (scratchpad is temporary; recreate freely): compile
tb_sdram_turbo / tb_dualram_turbo per run_tests.sh but with
-P <tb>.CYC_PHASE=N -P <tb>.CPU_PHASE=M, run with +prog=build/t_fpu.hex,
classify PASS / "program reports failure" (= corruption, never yet seen in
sim) / else HANG.  16 combos, ~6 parallel vvp jobs, ~15 min wall.

## Codex update: 2026-08-13, cache-control clarification and uncached-path test

### What the newest hardware failure is

`PXL_20260813_025718463.jpg` is the same deterministic failure documented
below, not a new FABS arithmetic error:

```
f236 4998 95d1    fabs.x ([0]),fp3
expected 0000-b6bad82c00000000
got      401c-d82c00000000df00
```

The pointer at absolute zero resolves to the odd chip-RAM operand at $4021.
The returned FP value is exactly the valid 12-byte extended source window
starting at $4023 instead: sign/exponent comes from the pad word $401c,
and the mantissa is shifted through the trailing $df00.  This remains a
precise +2-byte source-window error below the FABS arithmetic operation.

### There are three different "cache off" controls

Do not infer the physical route from the Amiga boot menu:

1. `cpu_wrapper.v` compiles AP040's internal cache out with
   `AP040_ENABLE_CACHE(0)`.
2. The Amiga boot menu clears the emulated 68040 CACR I/D enable bits.  Those
   become `cpu_cacr` and feed `cpu_cache_new.cpu_cache_ctrl`.  With CACR D=0,
   `cpu_cache_new` does not hit or fill its data cache, but it still performs
   a one-word SDRAM miss/bypass transaction.
3. MiSTer Main's **System / D-Cache** setting is CPU configuration bit $10.
   It reaches `cachecfg_pre[2] -> cachecfg[2] -> cpu_wrapper.dcache_d` and
   selects whether data accesses to chip RAM use the fast SDRAM fabric at all:

   ```verilog
   cchip = turbochip_d & (!cpustate | dcache_d);
   ```

The user clarified that caches were disabled in the **Amiga boot menu**.
That proves CACR caching was disabled, but it does **not** select the legacy
7-MHz chip bus.  The external `sdram_ctrl/cpu_cache_new` bypass path remains
selected when MiSTer D-Cache is on.

Read-only MiSTer inspection found `/media/fat/config/Minimig.cfg` byte 5150
is `$13`: CPU selection `$03` plus MiSTer D-Cache bit `$10`.  The config file
mtime is 2026-08-11 22:21 and the core was loaded 2026-08-12 23:04, so the
core definitely booted with the turbo data route selected.  Main can change
the value live without immediately rewriting the config file, but the user
did not mean that menu; they meant CACR in the Amiga boot menu.

### Exact running build

```
/media/fat/MiSTer /media/fat/Minimig-040_20260812.rbf
SHA256 dfa1e2e54eb54bebb8203dd4d850d9a5ef3b3406d4ff69409d87d18b4651fcf1
size   3835920
load   2026-08-12 23:04:56 -0400
```

This equals the current `output_files/Minimig.rbf`.  It is not fully
timing-clean: clk_114 setup slack is -0.033 ns, clk_sys is +0.765 ns, and
HDMI is -0.491 ns.  The clk_114 miss is relevant to the selected SDRAM path,
although the older timing-clean build 41 also reproduced the corruption, so
timing alone does not explain the longstanding deterministic +2 result.

### New simulation work

Two diagnostics were added/expanded; neither changes production RTL:

* `tests/ap040/tb_cpu_wrapper_chip.v` now models separate phase-locked
  114/28-MHz clocks instead of deriving ph1/ph2 in the CPU clock domain.
  The full `t_fpu.hex`, including the exact FABS.X encoding and byte image,
  passes all four PLL phase alignments both with an always-ready target and
  with delayed grants.
* `tests/ap040/tb_cpu_wrapper_chip_bridge.v` is new and includes the actual
  production `amiga_clk.v` and `minimig_m68k_bridge.v`, not a behavioral
  replacement.  It covers registered addresses, latched read data, CCK,
  DTACK, and deterministic DMA ownership stalls.  The full FPU suite passes
  all four clk_114 phases: 319022 clk_sys cycles each, `ALL TESTS PASSED`.

These tests force `cachecfg=0`, so they validate the actual legacy chip-bus
route.  They do not exonerate the turbo SDRAM bypass path that hardware was
using.  The existing `tb_sdram_turbo` still passes, meaning the remaining
failure depends on hardware behavior not reproduced by its SDRAM model or on
the current fit.

### Correct next experiment and investigation target

The highest-value hardware A/B is to disable **MiSTer System / D-Cache**
(not only Amiga CACR), then immediately rerun this FABS.X corpus case.  Save
the Minimig configuration or verify the live toggle before reloading the
core, since the saved byte is currently `$13` and reload re-enables the
turbo route.

* If FABS.X passes with MiSTer D-Cache off, concentrate on
  `ram_cs_guard -> sdram_ctrl -> cpu_cache_new` in its CACR-disabled
  one-word miss/bypass path.  Capture `ram_sel`, `ram_cs`, `ram_ready1`,
  `cpu_sm_state`, `sdr_read_req/ack`, live/latched address, and returned word.
* If it still fails, the new production-bridge simulation is insufficient;
  capture `t_a`, `m_addr_r`, `fp_n`, `cpu_addr_p`, `chip_addr`, `chipready`,
  and `chipdout_i` on FPGA to locate where the +2 first appears.

No new production RTL fix was made from this update.  Earlier cache and
chip-bus explanations were explicitly rejected when they conflicted with
the observed control setting; do not patch either path without reproducing
the bad address/data boundary or obtaining the FPGA trace.

Date: 2026-08-07 ~23:00 EDT. Tree: branch `ap040`, HEAD `e7faeb9`, plus
uncommitted work (see `git status`). All AP040 CPU-side FPU/frame fixes are
done and regression-green; what remains is ONE deterministic platform-level
data-corruption bug, plus an in-flight simulation campaign to reproduce it.

## The bug (unresolved)

Two cputest failures on real hardware, both memory-indirect EAs whose
pointer/operand live in CHIP RAM (all other cputest data lives in Z3 fast
at 0x42000000, which is why only these fail):

1. `FABS.X ([0]),fp3` (basicfpu, test 1789, encoding f236 4998 95d1):
   pointer at absolute 0 -> operand at ODD chip address 0x4021.
   Expected FP3 0000-b6bad82c00000000, got 401c-d82c00000000df00 — the
   12-byte read window shifted +2 bytes (se from 0x4023, mantissa from
   0x4027, trailing df 00 pulled in). Byte-identical across THREE
   different builds/fits.
2. `FADD.P ([]d0.w*8),fp1` (test 6081, f231 4ca2 0795): pointer long at
   absolute 0 = 00000001; frame EA expected 00000aa1, got 80090aa1 — the
   FIRST word of the two-word pointer read returned stale data (8009),
   second word correct. Also byte-identical across builds.

Both failures are v55 datatype-fault or FP3-value mismatches ONLY —
frames, PC, FPSR, exception counts (E11/E55) all match otherwise.

## Hard facts established (do not re-litigate)

- Board provenance is verified via ssh (root@mister / default password
  "1", host 192.168.21.188): the running core's RBF path appears in
  `ps | grep MiSTer` (e.g. `/media/fat/Minimig-040_041_20260805.rbf`),
  `/tmp/CORENAME` mtime = core load time, and md5 was compared against
  `output_files/Minimig.rbf`. Build 41 (all timing met) WAS running when
  the failures reproduced. Earlier "still failing" screenshots were from
  stale bitstreams — ALWAYS verify provenance first (this bit us twice).
- Timing is exonerated: build 41 meets ALL clocks (emu clk_114 +0.158,
  clk_sys +0.481, pll_hdmi +0.126). Builds 37/39/40 had setup violations
  on sdram_ctrl's sd_cas/sd_ras/sd_addr[7]; the fix (real, keep it) was
  removing the redundant raw `walker_req` term from `walker_grant` in
  rtl/sdram_ctrl.v — the registered `walker_req_q` alone suffices
  (level-held handshake; see comment in the file).
- Deterministic byte-identical corruption across fits = LOGIC, not
  timing/analog.
- Clock topology (Minimig.sv): clk_114 = PLL out0 (113.5MHz) runs
  sdram_ctrl/ddram_ctrl/cpu_cache_new and the ph1/ph2 generator;
  clk_sys = PLL out1 (28.7MHz) runs cpu_wrapper + the AP040 CPU.
  Phase-locked 4:1, alignment unknown from RTL (PLL phase).
- Board config decoded (scp /media/fat/config/Minimig.cfg, struct from
  Main_MiSTer support/minimig/minimig_config.h; file size 7268 confirms
  layout: memory@1038=0xc3, chipset@1039=0x18, cpu@5150=0x13): 68040,
  dcache ON, chip 2MB. CRITICALLY minimig.v:436 FORCES turbo chipram on
  post-boot: `assign cachecfg = {cachecfg_pre[2], ~ovl, ~ovl}` — so the
  failing chip reads ALWAYS go through cpu_cache_new + sdram_ctrl, never
  the 7MHz chip bus.

## What already passes in simulation (current tree)

All via tests/ap040/run_tests.sh (green end-to-end) plus standalone:
1. tb_ap040_program phases 0/1 (flat memory, latency sweeps) — includes
   t_fpu tests 245-248 which replicate the EXACT ([0]) encoding, odd
   operand address, and screenshot byte layout (a +2 window would
   reproduce the exact observed wrong value 401c-d82c00000000df00).
2. tb_ap040_program phase 2 — models cpu_cache_new's level-ack semantics
   (ack+captured data held until sampled bus idle; zero-gap requests get
   served stale data). PASSES: the bus16 adapter never issues zero-gap
   transitions (its 16:02 sub-cycle-gap fix + mem_ack idle).
3. tb_cpu_wrapper_chip — real cpu_wrapper 7MHz chip stage machine
   (ph1/ph2, mixed pos/negedge), whole t_fpu over the chip bus. PASSES.
4. tb_sdram_turbo — cpu_wrapper@28MHz + sdram_ctrl + cpu_cache_new@113MHz
   + behavioral SDR SDRAM (CL2/BL4 read, write-burst-single per mode word
   A9=1), phase-locked 4:1, whole t_fpu through the turbo path. PASSES
   without the ram_cs interposer; also passes with it at several phase
   alignments (see below).

## Prime suspect (mechanism, partially tested)

Minimig.sv line ~255:
```
ram_cs <= ~(ram_ready & cyc & cpu_type) & ram_sel;   // registered @clk_114
cyc    <= !div[1:0];  // div: 16-counter synced to c1 rising (div <= 3)
```
This TG68K-era "early CS kill" drops the cache's cpuCS one cycle after
ready meets the `cyc` phase marker, then RE-ASSERTS it while the 28MHz
side still holds ram_sel — potentially spawning a ghost second cache
transaction. cpu_cache_new's FILL states do NOT check cpu_cs (only
IDLE/WAIT/WB do; cpu_ack clears ONLY on !cpu_cs — line ~463), so a ghost
fill's SDRAM burst (8-16 clk_114) outlives the adapter's 1x28MHz
inter-sub-cycle idle (4 clk_114) and its late level-ack can complete the
NEXT sub-cycle with the PREVIOUS address's data. That is exactly the +2
window (b/w/b odd-long splits) and the stale first pointer word.
TG68K never hit this because its ready-consumption phase matched the cyc
contract by construction; AP040's compat adapter may consume at a
different 28MHz phase.

Status of testing this: tb_sdram_turbo has the interposer with two sweep
parameters — CYC_PHASE (cyc alignment, 0-3) and CPU_PHASE (28MHz edge
placement within div[1:0], 0-3) — plus periodic alternating-CCK chipset
DMA contention (display DMA is periodic, which is what would keep the
hardware corruption byte-stable). A 16-combo sweep was IN FLIGHT at
handoff time; partial results: CYC=0 x CPU={0,1,2} PASS with DMA (note
CYC=0 deadlocks at boot WITHOUT DMA — contention shifts the effective
phases). Earlier "all 16 WALLCLOCK" sweep rounds were VOID — a TB
declaration-order bug made every compile fail silently; fixed (dma regs
moved above the instance; compile existence now checked in the script).

Sweep runner: scratchpad/sweep16d.sh; results in
scratchpad/sweep_results.txt (scratchpad =
/tmp/claude-1000/-home-adam-ap040-Minimig-AGA-MiSTer/<session>/scratchpad
— TEMPORARY; recreate from the recipes below if gone).

## If the sweep reproduces a failure

Fix candidate (verify against ALL 16 combos + full regression):
kill-latch in Minimig.sv — once killed, stay killed until ram_sel drops:
```
reg ram_killed;
always @(posedge clk_114) begin
    if (~ram_sel) ram_killed <= 0;
    else if (ram_ready & cyc & cpu_type) ram_killed <= 1;
    ram_cs <= ~(ram_ready & cyc & cpu_type) & ~ram_killed & ram_sel;
end
```
Also consider guarding cpu_cache_new's FILL1 ack with cpu_cs and/or an
address-match (fill address vs live cpu_adr) — but beware: the SDRAM
slot address is latched at grant (state 0), the cache's cpu_adr is live.

## If the sweep is all-green

Next fidelity gaps, in order:
1. SECOND controller: on hardware, code fetches (0x42xxxxxx Z3) go
   through ddram_ctrl (its own cpu_cache_new instance) while chip data
   goes through sdram_ctrl; Minimig.sv muxes ready/data combinationally
   by zram_sel = |ram_addr[28:26] and gates cpuCS per-controller
   (~zram_sel&ram_cs / zram_sel&ram_cs). Model both + the mux flips.
2. c1-sync detail: div resets to 3 on c1 rising; c1/c3 come from minimig
   at clk_sys. The relative phase of (28MHz edge, cyc, c_7m/sdram_state)
   has more structure than the 4x4 sweep captures if c1 isn't div-locked
   the way assumed.
3. Real dtack/slot contention shapes (my DMA model is synthetic).
4. On-hardware experiments: deploy an instrumented build (e.g. latch the
   first N chip-read addresses+data into spare registers readable via
   some port) — expensive but decisive.

## Test/verification infrastructure (all in tests/ap040/)

- run_tests.sh — full suite; MUST stay green. Includes tb_wrapchip
  (chip-bus co-sim of t_fpu) and regenerates cpu_wrapper_sim.v via
  hoist_decls.py.
- hoist_decls.py — makes iverilog-legal copies of Quartus-tolerated
  Verilog (top-level declarations hoisted above first use). Needed for
  rtl/cpu_wrapper.v.
- sdram_ctrl sim copy: iverilog also rejects its `inout reg sd_data`.
  Recipe (python): change port to `inout [15:0] sd_data`, insert
  `reg [15:0] sd_data_r; assign sd_data = sd_data_r;` after the port
  list, rename the 3 procedural `sd_data <=` to `sd_data_r <=`.
- sim_dpram.v — generic dpram model (extracted from tb_cpu_cache_new.v;
  do not compile both in one iverilog invocation: duplicate module).
- tb_sdram_turbo.v — the turbo-path co-sim with CYC_PHASE/CPU_PHASE
  params and the ram_cs interposer + periodic DMA. Compile:
  `iverilog -g2012 -I rtl/ap040 -s tb_sdram_turbo -P tb_sdram_turbo.CYC_PHASE=N
   -P tb_sdram_turbo.CPU_PHASE=M -o out.vvp tests/ap040/tb_sdram_turbo.v
   <cpu_wrapper_sim.v> <sdram_ctrl_sim.v> rtl/cpu_cache_new.v
   tests/ap040/sim_dpram.v rtl/ap040/ap040_bus_timeout.v <ap040 stack>`
  then `vvp out.vvp +prog=tests/ap040/build/t_fpu.hex` (~2-8 min).
- t_fpu.s tests 241-248: memory-indirect FP EAs incl. the exact failing
  encodings. Tests 249-253: chained FPU benchmark loop + inf saturation.

## Board access / deploy

- `ssh root@mister` (192.168.21.188), password "1" (no key auth; use
  SSH_ASKPASS trick or sshpass). RBFs deployed to
  /media/fat/Minimig-040_NNN_20260805.rbf (NNN = build number).
- Verify what's running: `ps | grep MiSTer` shows the loaded RBF path;
  md5sum against output_files/Minimig.rbf. NEVER trust a screenshot's
  provenance without this check.
- Do NOT load/reboot cores remotely without asking — the user may be
  mid-session.

## Build procedure

- `quartus_sh --flow compile Minimig` in repo root (Quartus 17.0,
  revision "Minimig", NOT Minimig_Q13). ~10 min. Track your own PID;
  other Quartus instances may belong to other sessions.
- ALWAYS check the log's "Info (332119)" slack table: emu-clock
  violations are FUNCTIONAL bugs (SDRAM command pins!); pll_hdmi is
  display-only. Current SEED 1 in Minimig.qsf closes everything.
- Run tests/ap040/run_tests.sh BEFORE building. Never convert SOF->RBF.
- Checksum rtl before/after builds (stale-source builds bit us).

## Standing user rules

- No simplified/mock tests; fix the real ones. Test the ACTUAL RTL.
- No emojis in .v/.s/test files.
- Full Quartus compiles only. Track build PIDs.
- WinUAE (/home/adam/WinUAE) is the FPU/CPU oracle (SOFTFLOAT_68K branch
  of softfloat.cpp!); Musashi is weak; 68881-fpga is 6888x-architecture
  (normalize-before-arithmetic, 1-exp underflow shift) — NOT 040 rules.
- Session memory (Claude-specific but content is valid):
  ~/.claude/projects/-home-adam-ap040-Minimig-AGA-MiSTer/memory/
  winuae-undefined-flag-oracle.md holds the full FPU/MMU/frame rulebook.

## CPU-side status (done, for context)

AP040 FPU/exception fixes all regression-proven and in build 41:
pseudo-denormal arithmetic (raw exponent, er<0 tiny threshold,
shift=-er), uniform format-$3 vector-55 frames (EA=0 for register/
immediate sources), FABS/FNEG blanket INEX2 with reserved precision
rounding as double, bus16 adapter sub-cycle idle gap, FSGL semantics,
FCMP corners, FMOVEM quirks, trace/frame machinery. E11/E55 counters on
hardware match expectations; thousands of v55 frames compare clean.
