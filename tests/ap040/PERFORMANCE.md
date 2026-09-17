# AP040 performance branch: 40 MHz 68040 target

Branch: `ap040-40mhz`. Baseline: `a48b5c30` (the previously validated
working-tree configuration, following upstream merge `b004dbd9`).

**The 40 MHz 68040 performance target is not yet achieved.** The hardware
configuration still clocks the CPU at approximately 28 MHz. Higher CPU rates
below are functional simulations, not timing-closed FPGA configurations.
A matching real-machine benchmark/result is needed to establish parity.

## Enabled optimizations

* Read decoded register operands directly during setup, removing the extra
  register-index copy and operand-read state.
* Start simple indirect/postincrement/predecrement address handling without an
  extra dispatch state. Architectural address updates and fault rollback use
  the existing path.
* Consume a resident next opcode when a simple register operation completes.
  Trace and interrupt checks still precede dispatch; A7, SR and complex
  completions retain their writeback barrier.
* Pair MMU sweep data with its actual BRAM read address. The BRAM runs while
  CPU enables are paused; the old sweep could inspect a different row after
  an enable gap and miss a page flush.
* Drain all four controller burst beats for uncached reads. An early CPU
  acknowledgement no longer allows another read to consume the old burst's
  remaining words.
* Factor the late chipset-idle signal out of the CD DMA address-class muxes.
  All 17 outputs matched the original arbiter across 100,000 randomized
  Verilator cycles. Explicit buffer cells give the retained CD DMA word
  propagation delay without adding a bus cycle. The 0.25 ns minimum-delay
  requirement tightens hold timing relative to the baseline constraints.

## Measured core throughput

Verilator 5.052; freshly assembled, self-checking programs; internal caches
enabled. These are elapsed simulation clock counts, including startup and
verification. They are not scores from a physical Amiga.

| Workload | Baseline, phase 0 | Optimized, phase 0 | Throughput increase |
|---|---:|---:|---:|
| `bench_alu`: 65,536 dependent ALU operations | 330,846 | 200,190 | 65.3% |
| `bench_loop`: cached loads, adds and branches | 325,895 | 262,367 | 24.2% |

With variable external wait states (phases 1 and 2), the ALU benchmark changes
from 331,608 to 200,952 cycles; the load/branch benchmark changes from 326,673
to 263,145. The ALU workload includes a Python-checkable recurrence and checks
both final registers, so reading stale operands cannot produce a false win.

## Cycles per instruction (2026-09-12)

The board runs XSysInfo's Dhrystone at 5,350 with 3.04 MIPS on a 28 MHz
core clock: about nine clocks per instruction, where a real 68040 spends
about one.  That, not the clock, is the gap (0.64x an A3000/030 at 25 MHz,
0.16x an A4000/040 at 25 MHz), so the work moved from the clock to the
cycle count.  Two measurement tools exist for it:

* `tb_ap040_program.v +prof` prints a per-state cycle histogram of the core
  (the S_DECODE count is the instruction count) and the cache hit rates;
  `+memlat` adds latency histograms per access class.  `run_verilator.py`
  passes both for every program.
* `c/dhry.c` is Dhrystone 2.1 compiled with vbcc (`-O2 -speed -cpu=68040`),
  linked flat behind `c/start.s`, self-checking against the published final
  values, 200 runs.  `build_tests.sh` and `run_verilator.py` build it like
  the assembled programs (`--program dhry`).

Core bench, phase 0, 200 Dhrystone runs (129,778 instructions):

| Cache store policy | Cycles | CPI | D-cache hits | Data read avg |
|---|---:|---:|---:|---:|
| invalidate-on-write (before) | 1,481,317 | 11.4 | 76% | 8.9 clocks |
| update-on-hit (ap040_cache, now) | 1,185,604 | 9.1 | 99.9% | 2.0 clocks |

Where those 1,185,604 clocks went, before the steps below (state, share):
S_MWR 22% (28,100 stores at 6.2 clocks each: the write-through crosses the
16-bit bus before the core is acknowledged), S_MRD 16% (42,690 loads at about
4.3: a 2-clock hit plus the issue and completion states), S_DECODE 11%,
S_FETCH 10%, S_PIPE_START and S_EXEC 8% each, the EA and operand states about
15%.  S_PIPE_START is gone in the current core; the rest still holds.

The first change, write-through with update-on-hit instead of
invalidate-on-write, removed a fifth of the Dhrystone cycles: every store
used to clear its whole 4-way set, so the loads after a struct assignment,
a string copy or a stack push missed again at 31 clocks each.

The second set is the memory port.  Data transfers are issued from the
calling state when the port is free and the two operand returns finish on
the acknowledge (a cached load went from six states to four between the
operand-read state and execute); the cache hands the whole line over with
every instruction fetch and the queue takes up to eight words of it, with
the fill engine waiting for four words of room before a speculative fetch
(fetch requests per 200 Dhrystone runs: 146,424 -> 65,771).

| Step | Dhrystone cycles | CPI | bench_loop |
|---|---:|---:|---:|
| baseline (invalidate-on-write) | 1,481,317 | 11.4 | 262,367 |
| cache update-on-hit | 1,185,604 | 9.1 | 262,367 |
| + early issue, returns on the ack | 1,093,219 | 8.4 | 261,111 |
| + direct dispatch from every safe completion | 1,047,235 | 8.1 | 260,855 |
| + operands read in the execute state | 1,005,444 | 7.7 | 260,855 |

With the real controllers and their phase relation to the CPU the same
runs went 6,794,495 -> 6,140,447 clk_114 on the SDRAM bench and
6,087,359 -> 5,942,175 on the dual-RAM bench, measured from the cache
step onward.  The corpus (run_cputest.py, v20 data040) stays at 1,265/1,911
with the identical fail set through every step.

The third step is the instruction end: the successor is dispatched from
the completing cycle itself whenever its opcode is resident, for every
completion that does not write A7 or the USP shadow in that cycle (the
decoder reads those a cycle before the register file commits; every other
writeback is visible to the operand read two cycles on), and a store that
ends its instruction dispatches from its acknowledge instead of S_NEXT.
This used to be limited to register-destination ALU results and MOVEQ.

The fourth step removes the operand state entirely.  S_EXEC is entered
straight from decode and reads the register file itself at the decoded
operand indices; only a memory operand or a non-register destination takes
the operand states, which return to S_EXEC with the values captured.  A
dependent ALU operation went from three clocks to two (`bench_alu`
200,102 -> 134,412).

## Area

The device is full, and two of these steps had to be reshaped to fit it.
The fit of the second step needed 4,199 of the 4,191 LABs available.  Two
synthesis variants located the cost: issuing data transfers from the
calling state accounted for 986 ALMs and the line-wide fetch's consumer
for 27, though removing the feature outright gives back 506.  The
tasks, each with its own copy of the port guard, the page-crossing compare,
the function code and the address and data path.  Recording the request in
one-cycle carriers and issuing it from a single block below the state
machine is cycle-for-cycle identical and costs nothing:

| Tree | ALMs (synthesis estimate) |
|---|---:|
| issue inlined at 73 sites | 41,144 |
| early issue removed altogether | 40,158 |
| issue from one block | 40,152 |
| line-wide fetch also removed (now) | 39,646 |

Synthesising every committed step gives the whole picture.  The baseline is
the last bitstream that met timing, and it had 0.091 ns of slack:

| Step | ALMs | Dhrystone clocks |
|---|---:|---:|
| baseline (last flashable) | 38,649 | 1,481,317 |
| cache update-on-hit | 38,635 | 1,185,604 |
| port work, issue inlined at 73 sites | 40,875 | 1,047,235 |
| controller cache READ restructure | 40,838 | 1,047,235 |
| direct dispatch | 41,392 | 989,635 |
| operand read + one issue block | 40,152 | 952,927 |
| line-wide fetch removed | 39,646 | 1,005,444 |

The cache step, the largest single win, is free.  A build of the
40,152-ALM tree fits at 98% of the device and then misses setup by
2.058 ns -- not on the CPU, but on the chipset's Agnus-to-SDRAM address
path, which the router cannot keep short at that occupancy.  Minimig.sdc
now also gives the beam counter's display-configuration registers the
budget they actually have: agnus_beamcounter writes them only when
software writes the matching custom register, never per beam tick, and
they were 86 of the design's 100 worst paths.

A line-wide instruction fetch was tried alongside these steps and then
removed.  The cache held its data in sixteen {way, word} RAMs so the hit
way's whole line sat on the RAM outputs, handed it over with every
acknowledge, and the queue took up to eight words per port transaction:
fetch requests per run fell from 146,424 to 65,771 and the program from
1,093,219 to 1,047,235 clocks.  It cost 506 ALMs for 5.5% of the cycles,
the worst ratio of the set, on a device with no room to spare.  The
READ_PIPE parameter it gave tb_sdram_turbo and tb_dualram_turbo stays
(default FAST_CLOCK, as Minimig.sv keyed it).

The next targets, by weight: stores (S_MWR is still a fifth of the time:
posting the write and letting the successor run needs the access-error
frame to describe a completed instruction, as the 68040's format $7 does),
and S_FETCH after taken branches (the redirect's two-cycle fetch).

### Re-measured on f53c044b0 (2026-09-17): stores are the whole story

Core bench, Dhrystone phase 0, `+prof +memlat`: **1,005,444 cycles for
129,779 instructions, CPI 7.75** (9.1 when the CPI section above was
written).  Where it goes now:

| state | cycles | share | of which stalled |
|---|---:|---:|---:|
| `S_MWR` | 221,414 | **22.0 %** | 22 % |
| `S_MRD` | 163,255 | 16.2 % | 0 % |
| `S_EXEC` | 134,489 | 13.4 % | 0 % |
| `S_DECODE` | 129,766 | 12.9 % | 0 % |
| `S_FETCH` | 100,137 | 10.0 % | 0 % |

and the access histograms say why:

    ifetch     n=133,340  avg 2.0   (133,227 of them exactly 2)
    dataread   n= 42,690  avg 2.0   ( 42,652 exactly 2)
    datawrite  n= 28,100  avg 6.2   ( 21,438 at 7, 6,662 at 4)

Caches are 99 % on both sides.  Reads and fetches have reached the floor the
cache can give -- 2 cycles, every time.  **Writes cost three times a read**,
28,100 of them, about 174,000 of the 221,414 cycles in `S_MWR`, which is
17 % of the whole program.  Nothing else is close.

The cause is structural rather than a stall: the cache is write-through, so
every store crosses the 16-bit bus adapter -- a longword is two bus
transactions -- and the core waits for completion before it is acknowledged.
A read at 99 % hit rate never reaches the bus at all, which is the entire
difference between 2.0 and 6.2.

Two numbers from the plan are now stale and should not be used to choose the
next step.  `X2.3` says 44 % of `S_MRD`/`S_MWR` cycles wait behind an
outstanding instruction fetch; measured here it is **5 %** (21,957 of
384,669), so the shared-port problem it names is solved.  `X2.1` (32-bit
DUAL_SDRAM) is marked FIRST on the strength of a fetch path that was 9.2
cycles and is now 2.0.

So the next step is posting the store, and the cost of doing it is the
exception model: a posted store that faults is imprecise, and this core's
format $7 deliberately keeps WB3S clear because it restarts rather than
completes.  The cheap route is to post only where the platform guarantees no
bus error -- the `c_post_ok` input Alan's cache carries, driven from the
address decode, with `sdram_ctrl`'s existing write buffer to drain into.  The
complete route is the WB1/WB2/WB3 frame, which `880b81c` moved toward by
stacking the MOVEM EA.

Expected: 6.2 -> ~2 cycles on 28,100 stores is ~118,000 cycles, 11.7 % of
Dhrystone, CPI 7.75 -> ~6.8.  After that the profile points at the dispatch
floor -- `S_DECODE` is one cycle per instruction and `S_EXEC` 13.4 % -- which
is X2.3's forwarding and scoreboard work, not memory.

Area is no longer the constraint X2.7 assumed: 38,750 ALMs (92 %) with
+0.460 setup leaves ~3,160 free, so this fits without the `cpu_cache_new`
and `bus16` removals that budget was funded by.

## The boot that was never a boot (2026-09-17)

`f53c044b0` runs, and GuardianAngel does not lock the machine up, which puts
real MMU work through the `880b81c` conformance changes.

Two days of hardware results before it were void, and the reason is worth
writing down because no amount of RTL work would have found it.  Four images
failed to reach Workbench with four different symptoms -- no boot, stuck in
the startup-sequence, Exec's idle loop, a yellow screen after reset -- and
each was bisected against RTL.  The baseline the whole bisect rested on,
`74317588` "boots and runs NetBSD at 6,615 Dhrystones", was a measurement
from 13 September that nobody had re-run.  When it was finally re-flashed it
did not reach Workbench either.

The machine's Minimig config had been changed at 22:42 that evening, after
`74317588` was built at 17:29:

| | ROM | HDF0 |
|---|---|---|
| `Minimig.cfg.bak-ap040`, 14:01 | `A1200.47.115.rom` | `A4000_CF_20221112.img` |
| `Minimig.cfg`, 22:42 onward | `DiagROMFPU.ROM` | `netbsdamiga92.hdf` |

A diagnostic ROM and a NetBSD filesystem.  Nothing reaches Workbench from
there, on any core, which is also why the symptoms wandered: they were never
core failures.  Exec idling with no task ready is exactly what a ROM that is
not booting a Workbench volume looks like from HRTmon.

**Re-run the known-good image before bisecting a hardware symptom.**  It
costs one flash and it is the only thing that distinguishes "this change
broke it" from "the bench changed".

### What survived the void

The simulation work stands on its own, because none of it depended on a boot:

* Instruction semantics are IDENTICAL across `74317588`, `0ba8f7c0e` and
  HEAD -- the WinUAE 68040 corpus, 3,801 slices, the same 25 pre-existing
  failures on all three, byte-identical sets.  Whatever the images were
  doing, they were not decoding differently.
* The corpus forces `cacr = 0` and `tc = 0` (`tb_dat_replay.v`), so it is
  blind to caching and translation.  That is its standing limitation and it
  is why the 46-leg suite and the corpus can both be green while a cached
  path is wrong.

### Three harness defects the corpus found

All three were in `tb_dat_replay.v`, all invisible to the suite, and all of
the same shape -- a backdoor reaching at storage rather than through the path
the core uses:

* It preloaded `fr_s/fr_e/fr_m`, which became simulation mirrors when the FP
  register file moved into MLABs.  Every FPU slice had been running with its
  operands left at the reset NaN and comparing against the same, since that
  register file landed.  `FABS.X` wanted 1.0 and got the default NaN.
* It captured the integer registers from the bank, past the one-cycle
  hold-and-bypass, so it missed whichever write was still in flight -- which
  is reliably an instruction's LAST write.  36 PackedFPU slices failed with
  `A register: expected 438fff0c got 438fff00`, the `(A6)+` update on
  `FABS.P` simply not visible yet.  Bisected to the commit that added the
  bypass, with its parent clean: the RTL was right, the observer was not.
* It referenced `regfile.dreg/areg` after those became banks, which at least
  failed to compile and said so.

### no_rw_check, in both register files

`ramstyle = "MLAB, no_rw_check"` does not promise the accesses never
coincide.  It says the read data is UNDEFINED when they do, and asks the
fitter not to spend logic defending against it.  Both register files
violated that constantly -- 612 cycles in `t_integer` for the integer file,
1,329 in `t_fpu` for the FP one, the first of those a write to FP0 with both
read ports on FP0 -- and no simulation here can see it, because Verilator
models the array exactly.

The fix is not to drop the attribute.  Without it Quartus will not infer an
MLAB at all: the fit reported `ALMs used for memory 0.0`, both mirrored banks
in flip-flops, 1,172 registers and 673 ALMs against the plain array's 576 and
459 -- worse than doing nothing.  The fix is to hold the write one enabled
cycle and answer a read of the pending address from the held data, so the
undefined datum is discarded and the attribute becomes honest.  Verified by
counting: coincidences 1329, uncovered 0.

## Experimental clock interface (parked)

`cpu_wrapper.FAST_CLOCK=1` accepts the memory clock, with `CORE_DIV=4`, `2`
or `1`. `clk_peripheral` remains the original 28 MHz clock. The chip-bus FSM
uses phase edges; RAM consumption has a synchronous select/acknowledge
handoff; RTG/IDE/Akiko completion crosses from the peripheral clock through
a retained acknowledgement. Peripheral writes are accepted on that clock
before the fast CPU can retire them.

The corresponding test benches enable `ram_cs_guard.SAME_CLOCK` and connect
the walker bridge to the CPU clock. **Minimig.sv does not enable this mode.**
Connecting the core to 114 MHz requires real timing closure, including the
free-running BRAM lookup/snoop logic and the peripheral crossings. Applying
a blanket four-cycle timing exception would incorrectly relax those paths.

Functional runs pass at divide four, two and one. Coverage includes:

* Integer, exception, MMU and FPU programs through the real chip/RTG blocks,
  with DMA wait slots, turbo chip RAM, RAM latency variations, and different
  peripheral clock phases.
* Integer/MMU/FPU through SDRAM at divide two.
* Integer/MMU/FPU through the combined SDRAM/DDR model at divide one;
  MMU/FPU at divide four.

The SDRAM/dual-memory benches do not implement the exception suite's full
interrupt-injection interface. Run `t_exceptions` in the core/chip benches.

## Regression evidence

* Core integer, exceptions, MMU, cache, FPU and both benchmarks pass; the
  original six programs pass all three bus-latency phases.
* Production clock configuration passes chip-bus integer/exception/MMU/FPU,
  SDRAM integer/MMU/FPU, and combined SDRAM/DDR integer/MMU/FPU tests.
* The controller-cache unit regression passes. Its new early-restart case
  fails with 24 errors against the baseline controller and passes after the
  burst-drain fix.
* Reset, double fault, walker CDC, bus-gap and bus-timeout unit checks use
  Verilator as well.
* Full v20 corpus A/B: **1,265/1,911 pass and 646 fail in both versions**;
  no timeouts or harness errors. Every slice's status and reported mismatch
  lines are identical. This is regression equivalence, not a clean corpus
  result; the older success counts elsewhere in the repository do not
  describe the current baseline. An additional 494-slice integer sample
  comparison also has identical results.

## Reproduce

Verilator, and nothing else -- the project no longer carries a second
simulator.  All generated files and bounded subprocess logs go under
`--work`.

The whole regression in one command (every program bench preset and every
self-checking unit bench, negative controls inverted):

```sh
python3 tests/ap040/run_verilator_suite.py --work /tmp/ap040-suite
```

Individual benches:

```sh
python3 tests/ap040/run_verilator.py --work /tmp/ap040-core
python3 tests/ap040/run_verilator.py --bench cache-unit --work /tmp/ap040-cache
python3 tests/ap040/check_chipdma_equivalence.py --work /tmp/ap040-dma
python3 tests/ap040/run_verilator.py --bench chip --work /tmp/ap040-chip
python3 tests/ap040/run_verilator.py --bench sdram --param CPU_PHASE=3 \
  --param CPU_CACHE=0 --param MAX_CYCLES=6000000 --work /tmp/ap040-sdram
python3 tests/ap040/run_verilator.py --bench dualram \
  --param CPU_PHASE=3 --param CPU_CACHE=0 --param MAX_CYCLES=6000000 \
  --work /tmp/ap040-dualram
python3 tests/ap040/run_verilator.py --bench chip --param FAST_CLOCK=1 \
  --param CORE_DIV=1 --param TURBO_CHIP=1 --param RAM_LAT=0 \
  --param DTACK_MODE=1 --work /tmp/ap040-chip-fast
python3 tests/ap040/run_cputest.py /path/to/v20/data040.zip \
  --simulator verilator --full --jobs 12 --build-jobs 8 --timeout 120 \
  --work /tmp/ap040-corpus
```

## Remaining work toward 40 MHz 68040 parity

The first fitter run still limits the CPU clock to about 28.9 MHz; its
critical internal path runs from instruction decode to exception-format
selection. Retiming that logic and other long paths is necessary before
activating a higher CPU clock. The shared fetch/data port, branch refill
cost, and narrow external bus remain additional throughput limits. The
dependent integer benchmark is about three clocks per operation; at
114 MHz that would approach 38 million operations per second, but this is
an extrapolation, not demonstrated board performance or universal 040 parity.

Scaler and shadowmask sources match the pre-optimization baseline. The
scaler-specific synthesis assignments, HDMI fitter uncertainty override,
and subsequent fitter-seed experiments have been reverted. CPU and DMA
optimizations remain enabled, with seed 1 and all-corner timing analysis.
The replacement RBF was built from `07ed97cf` on 2026-09-07 at 19:05 EDT
using Quartus Prime 17.0 Lite (zero compilation errors, 152 warnings).
The scaler/video reversion is included in this artifact.

**This RBF is not timing closed.** Across the four timing corners, HDMI setup
slack is -0.474 ns at 100 C and -0.360 ns at -40 C in the slow model. The
other 158 summary entries are nonnegative; worst hold slack is +0.072 ns.
TimeQuest also reports that setup/hold requirements are not fully constrained.
No further scaler or HDMI timing changes were made. Board testing has not
been performed.

* RBF: `output_files/Minimig.rbf` (3,939,728 bytes).
* SHA-256: `f9baef0447a212403e50f349d36e01f51fccf2f80fd44f9aa59d1549a68528f6`.
* Build log: `build_20260907_184915.log`.

That section is a record of the 2026-09-07 build and nothing in it tracks
the current tree: `output_files/` is overwritten by every build, so the
timing summary there belongs to whatever was built last, not to the RBF
named above.  For where the branch stands now see "Timing, and what is not
closed" below.

Cycle counts and the full corpus comparison are also recorded in
[`performance_40mhz.json`](performance_40mhz.json).

## Timing

`74317588` meets the build gate: `setup emu (CPU) +0.097`, no negative emu
row in any corner, and it is the first bitstream of this CPU work to do so.
The cycle figures above remain **simulation results** -- the gate is a
timing result, not a hardware one, and nothing below has been run on a
board.

The design's limiting path was never in the CPU: it is the chipset's DMA
address reaching the SDRAM controller through agnus, gary, the bank mapper,
the SRAM bridge and the DMA arbiter, all of it combinational.  Its budget is
a true two clk_114 cycles, 17.616 ns, because Agnus's clk7_en registers
change on the same clk_28 edge on which c1 rises, the controller detects
that rise one cycle later and the RAS state captures one cycle after that.
At -0.796 ns it was 38 of the 40 worst paths in the design.

What closed it, in the order the fits said to do it, with each figure the
one that fit measured:

* **The bank mapper's chip select, two LUT levels to one** (`177d4cd7`):
  `bank[5]` is `chip3|chip2|chip1|chip0` and `chip0` carries a four-term CPU
  qualifier, so flattened it is eight inputs.  Keeping the qualifier as its
  own node makes it five.  Worth 2.14 ns on the worst path.
* **Not keeping anything else** (`dd699822`): the same commit preserved two
  more nodes to reach the pins and gave all of it back -- `arb_drive_chip`
  cost 0.767 ns as a serial stage with a fanout of 111, `ram1|chip_row`
  another 1.398.  A shared node between the chipset and an I/O register has
  its inputs in the controller's cluster and its output at the pin, so the
  fitter places it with its inputs and the address pays for the trip twice.
  Removing both, and folding sd_addr's whole select into one LUT per bit,
  took this family to +0.280 and out of the sixty worst paths.
* **The pin registers' feedback holds** (`9eb85051`, `74317588`): every
  SDRAM pin register was written from several places and held in between,
  and a hold needs the register's own output back at its input.  The fitter
  duplicated `sd_cas` and placed the copies far apart:
  `sd_cas~_Duplicate_1 -> sd_cas` was the worst path in the design at
  -2.314 ns.  Every condition that drives the command pins falls on an even
  slot state, so the enable is exactly `~sdram_state[0]` -- literal once
  each pin is written from one place.  -2.314 to -0.496 and 873 ALMs, then
  the rest of the pin group to +0.097.

Slack moves by about two nanoseconds between fits of nearly identical logic:
-0.796, -1.653, -0.230, -2.314, -0.496, +0.097 across the six above.  Say
what that is and is not.  Each figure is a *different* source state, so it
measures the fitter's sensitivity to change, not run-to-run noise -- the same
source was never built twice, so nothing here measures reproducibility.
Several families sit within about two nanoseconds of each other and which one
surfaces as worst moves with placement, so a claimed gain of a few hundred
picoseconds cannot be established from one build.  A change of worst-path
*identity*, or of ALM count, can.

Two attempts to buy margin, both reverted:

* Unpacking SDRAM_A[11] and A[12] from their pin registers passed the gate
  at +0.188 ns and did not boot.  `sta/sdram_io.tcl`, written for this,
  showed those two bits arriving 3.9 ns and 12.7 ns later than the eleven
  that stayed packed, whose arrivals span under 0.5 ns -- latched stale on
  a 17.6 ns memory cycle.  Internal timing had said nothing about
  it: the project has no `set_output_delay` on the SDRAM at all.
* Clocking `sd_addr` on the falling edge, with the enables delayed a state,
  to give the chipset 2.5 cycles.  A multicycle counts capture edges, and
  for a falling-edge destination those are the falling edges, so the
  `setup 2` covering the rest of ram1 meant 1.5 cycles; `setup 3` is the
  2.5 the hardware provides, and with it the chipset path reaches
  +3.946 ns at a 22.020 ns relationship.  But the binding constraint then
  moves inside the controller: its own delayed enables are written on the
  rising edge and consumed on the immediately following falling edge, so
  `walker_cas2_go_d`, `init_go_d` and the slot-type select really do have
  half a cycle (4.404 ns) and miss by about 2.8.  Those are an RTL problem,
  not a constraint one, and the chipset exception must not be extended to
  cover them.

`sta/sdram_io.tcl` bounds the spread of arrivals across the address pins,
which is what catches a bit stepping out of line with the rest.  A small
spread is bounded relative skew and nothing more: it is not proof of
absence of skew, and it says nothing about absolute setup and hold against
the forwarded clock, because the generated clock's parity is not pinned.
Calibrate it against the command pins, whose centring is known, before
trusting any absolute figure from it.

On `74317588` all twenty pins of the interface -- thirteen address, two
bank, three command, two mask -- arrive within 0.773 ns of each other, the
address bits alone within 0.525 ns.  Read that as the check passing, not as
margin: the absolute figures it prints, around -5.3 to -6.1 ns, are the
unpinned parity, not a violation.  The comparison that matters is with the
reverted unpacking, which put two bits 3.9 ns and 12.7 ns behind the rest.

### Margin

`d41be2fd` passes by 0.423 ns at 96% of the device, from `74317588`'s
0.097 ns at 98%.

What bought it was one parameter.  `74317588` bound in the Slow -40C corner
on `ram1|cpu_cache|cpu_ack`, with four of the tightest twelve emu paths
ending there: the controller cache deciding a hit combinationally from the
tag RAM's output, three LUT levels and then 2.012 ns of route.
`cpu_cache_new` has had the registered form behind `CACHE_READ_PIPE` all
along; the shipping build simply had it off, and the benches default it to
`FAST_CLOCK`, so the tested core and the built core disagreed about it.
Turning it on removed `cpu_ack` from the tightest paths entirely and gave
back 823 ALMs.

It had been marked P2-only because dualram's `t_mmu` leg failed with it under
the legacy clocking.  That was mis-attributed: the leg fails with the
parameter off, and fails on `6ea3997d`, before any of this work.  See the
open item below.

The binding corner moved with it, from Slow -40C to Slow 100C, which is its
own evidence that the cold-corner bottleneck is gone.  What binds now is the
chipset address path again -- `bc1|hpos[6] -> ram1|sd_addr[12]`, +0.423, with
`sd_addr[11]` and `[12]` taking most of the tightest ten -- so the next
margin, if it is wanted, comes from the same place the first two nanoseconds
did.

`sdram_rp1` and `dualram_rp1` now cover the shipping configuration, because
nothing did before.

Three things this result is not.  The registered hit compare changes when a
read completes, so it can change execution time with identical CPU RTL:
re-measured, `dhry` on the sdram bench is 6,169,503 clk_114 cycles with the
pipe off and 6,169,503 with it on, bit-identical, while `t_mmu` moves by 256
cycles, which is how the parameter is shown to be taking effect at all.  So
the 6,615 Dhrystones should hold, but that is a simulation argument and the
hardware figure is unverified.  The corner moving from Slow -40C to Slow
100C is consistent with a changed bottleneck, not proof of one; the evidence
for why is the acknowledge-path reports, where `cpu_ack` goes from four of
the tightest twelve emu paths to absent.  And four times the slack is four
times the headroom, not four times the reliability.

### Closed: dualram + t_mmu, and what it was

It was the bench, and the first bad transaction says so rather than the fix
passing saying so.  At t=7073660 the CPU requested $00F004 as an instruction
fetch; `want_ddr` and `sel_ddr` were both 1, so `ddram_ctrl` owned it; it
acknowledged (`ack_ddr=1`, `ack_chip=0`) and returned `0000` while the shared
image held `702b`.  The word's last write was by the **chip** model at
t=6936996, taking it from `0000` to `702b` -- 137 us earlier, through a
controller the fetch never consulted.

The cause is the bench routing data by address and fetches by cycle type.
Those agree everywhere except its own port window at $F000 and up, which
`data_chip` sends to the chip side; a word written there as data and then
executed reads back pre-write.  A real machine routes both by address and
has no such window.  Neither controller misbehaved and the MMU is not
implicated.

Pre-existing: `6ea3997d`, before any of this work, reproduces the same first
transaction -- same address, routing, acknowledgement ownership, returned
word and chip-side provenance -- differing only in timestamps.

The write-provenance arrays stay in the bench.  STALE-I alone says a fetch
disagreed with the image; it does not say which of the controller, the
routing or the image is at fault.  `t_mmu` now runs on both dualram legs of
the suite and `run_tests.sh` has `mmu_dualram`, because the reason this sat
undetected is that nothing ran it.

### Coverage after removing the second simulator

The don't-care family was **five legs across two builds**: three positive
(`cache_snoop_x`, `cache_snoop_ce4`, `cache_snoop_ce4_accw`) and two negative
controls (`cache_snoop_x_neg_accw`, `cache_snoop_ce4_neg_lkw`).  A sixth
snoop leg, `cache_snoop`, was built without the define and was already
duplicated under Verilator.  All three positives ported, and the suite adds
two more positive variants of its own.

**One control is restored.**  `sim_dpram` now takes a directed row from the
bench: the tag the lookup is asking for, valid, in a way that does not hold
the line, with a marker word behind every way.  Acting on a collided row then
hits the wrong way and returns its word, which `expect_read` catches.  That
reproduces `cache_snoop_x_ce4_neg_lkw` exactly.

**The other came back too**, and it took two steps.  `cache_snoop_x_neg_accw`
is the divide-1 acceptance control.  The first attempt (T12) populates four
lines in one set, injects a collided row carrying their four tags with the way
associations rotated, triggers the suspect fill and rereads them -- attacking
the writeback route, since `tags_next` and `val_next` are built from `tag_q`.
That found nothing, in every combination of the three guards, and a trace
(`+trace_wb`) says why only in part: of 8 writeback attempts while the row was
armed, 6 were blocked by `fill_snooped` and 2 wrote, so that guard is real and
does act -- but blinding it as well still produces nothing, because the
permuted row does not carry the requesting line's tag, so the lookup misses
and refills from a row since re-read clean.  T12 stays as a positive
regression over that route.

The term is load-bearing on the **lookup** route, and the reason nothing had
shown it is stimulus, not mechanism.  T3 already sweeps a snoop across the
acceptance window, but its concurrent read is deliberately unchecked -- the
snoop is unordered against it, so either value is legal there -- so the one
read that could expose the collision was the one the bench ignored.  T13
checks it: either value is legal, a **third** is not.  With the term blinded
it returns `1111_2154`, a neighbouring line's word, against an old value of
`1111_2854` and a new one of `1313_0000`.  Concrete wrong data, not X.

The full documented matrix now reproduces in two state:

| | divide 1 | divide 4 |
|---|---|---|
| guard intact | pass | pass |
| `+inj_acc_whole` | **fail** | pass |
| `+inj_look_whole` | pass | **fail** |
| `+inj_acc_settle` | n/a | pass |

`+inj_fillguard` is retained as a diagnostic: it blinds the writeback guard
(`tag_we`'s `!fill_snooped && !snoop_fill_row`) so overlapping protection can
be told apart from a redundant term.  It is simulation-only and no production
guard changed.

Two weaker poisons were tried first and are recorded because they show what
does not work: the bitwise inverse of the row, and a deterministic LFSR mixed
with the address.  Both left **both** controls passing -- a random word
misses, and a miss is safe.  The LFSR remains the default for instances the
bench does not direct; it samples particular collision values and does not
demonstrate tolerance of every row.

A separate guard assertion was written and removed.  It flagged any request
whose row a snoop touched anywhere in the window, which is not the contract:
the row is re-read every cycle, so a snoop landing before the last re-read
the compare sees is harmless -- which is why `+inj_look_whole` is safe at
divide 1, and the assertion failed there.  Narrowing it to "the compare used
a collided row" converges on the RTL's own expression and proves nothing.
The end-to-end data check is the contract test.

### What the cputest corpus does not cover

`tb_dat_replay` forces `cacr = 0` and `tc = 0` -- and the TTRs, both root
pointers and MMUSR with them -- before every slice.  So the corpus runs with
**both caches disabled and the MMU off**.

That matters because "the corpus fail set is identical" has been the main
evidence behind every step of this work, and for two subsystems it is
vacuous:

* **The cache rewrite.**  Write-through update-on-hit is the single largest
  behavioural change here and worth a fifth of Dhrystone.  The corpus cannot
  see it at all.  Its coverage is `t_cache.s`, which runs untranslated, and
  `tb_ap040_cache_snoop`.
* **Anything translated.**  Page faults, restart under paging, the format `$7`
  frame in anger.  The corpus's own access-error group passes 32/32, but with
  `tc = 0` those are bus errors, not page faults.

This is not hypothetical.  It hid a real regression: sizing the bitfield
memory read by its span (`8e73b9b74`) changed which reads the cache serves,
because `ap040_cache` accepts only an access inside one aligned longword and
a longword at an arbitrary address is refused three times in four.  The
corpus was clean, the 46-leg suite was clean, the directed page-boundary test
passed, and NetBSD's `rcorder` died on SIGABRT.  `e6c584e67` restricts the
narrowing to the page-crossing case, which is measured byte-identical to the
known-good core: every program on the core bench retires in the same cycle
count as `74317588`, `t_mmu` included.

What would close the gap is a directed test that runs cached **and**
translated -- a cached access through a mapped page, a remap or protection
change, a flush, then the access again -- plus a corpus mode that leaves the
caches on.  Neither exists.

### Still unverified: the hardware release checks

Everything above is simulation and timing.  The image to test is
`Minimig-ap040-40mhz-e6c584e67-20260914_001715.rbf`, md5
`62308e019bbf5ff351ad842421ce6fd0`.  It meets the gate at +0.247 ns worst emu
setup in any corner, at 96% of the device, and its design is identical to
HEAD -- the commits after it touch only notes and tests.

It is the bitfield read narrowed to the page-crossing case, on top of the
reverted `CACHE_READ_PIPE`.  Outside a page end it is byte-identical to
`74317588`, which runs NetBSD: every program on the core bench retires in
exactly that core's cycle count, `t_mmu` included.

Two images before it are worth keeping straight.  `8e73b9b74` sized every
bitfield read and met the gate at +0.445, and NetBSD's `rcorder` died on it.
`d41be2fd` carried `CACHE_READ_PIPE` and did not boot at all.  Neither should
be flashed again.

1. **Repeated cold boots.**  Power-cycle, not core reload, several times.
   One boot is what `d079808a` had, and an earlier fit of the same RTL at
   the same slack showed corrupted display DMA instead.
2. **Display and DMA activity.**  Something that moves bitplane and sprite
   DMA for a while; the failure mode this design has shown is the chipset's
   address to the SDRAM, which appears as corrupted display rather than a
   hang.
3. **Both I/O identifications.**  `tools/amiga/ioprobe.c` (build line in its
   README) prints every individual read behind XSysInfo's Clock and Gary
   lines.  Run it on this image and on a known-good core with the same ROM,
   OSD settings and Workbench, and diff.  The two lines differ from the
   5350-Dhrystone baseline and nothing in the RTL diff explains it: the
   modules that serve those probes -- `gayle.v`, `fastchip.v`, `gary.v`,
   `minimig_m68k_bridge.v` -- are untouched since then, and the legacy chip
   machine differs only in an interrupt reset value.
4. **Dhrystone on this exact image.**  6,615 is `74317588`'s measurement.
   Simulation says the read pipe costs nothing (`dhry` is 6,169,503 clk_114
   either way, bit-identical), so the expectation is unchanged -- but an
   expectation is not a measurement.

### Measured on f53c044b0 (2026-09-17)

XSysInfo 0.10.0 on OS 3.2.3 / ROM 47.115 / Workbench 47.5 / SetPatch 47.10,
Picasso96, 2 MB chip and 256 MB fast:

| | |
|---|---:|
| Dhrystones | **6,531** |
| MIPS / MFLOPS | 3.71 / 2.83 |
| CHIP / FAST / ROM | 5.00 / 7.06 / 8.40 MB/s |

and the identification lines that were the open question read **Clock OKI
MSM6242B** and **Gary rev GAYLE 80** -- neither is the `Clock NOT FOUND` /
`Gary rev A1000` pair that check was written for, so the anomaly is not
present on this image.  `ioprobe` is still the rigorous form of that check.

Dhrystone is 6,531 against 74317588's 6,615, and the two are NOT comparable:
this run has **MMU 68040 (IN USE)**, because GuardianAngel is loaded, so every
access is translated.  The 6,615 figure was taken with translation off.  A
clean comparison needs Dhrystone run twice on this image, with and without
GuardianAngel; -1.3 % WITH the MMU active is consistent with no CPU
regression at all.

There is also no reason to expect a gain.  Everything this branch did to the
core after 880b81c was cycle-for-cycle identical -- the exception carriers,
the FPU normalize sharing, both register-file MLABs -- and was spent on area,
not cycles: 41,080 ALMs to 38,750, 98 % to 92 %, with setup going -0.627 to
+0.460.  The one change that could move Dhrystone either way is the bitfield
read sized by span, which alters what the data cache accepts: `fits_long`
takes any byte, a word only when even and a longword only when aligned, so
sizing the read turned most bitfield accesses from bypassing into cacheable.

