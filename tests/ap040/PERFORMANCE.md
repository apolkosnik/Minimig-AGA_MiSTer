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

Where the remaining 1,185,604 clocks go (state, share): S_MWR 22% (28,100
stores at 6.2 clocks each: the write-through crosses the 16-bit bus before the
core is acknowledged), S_MRD 16% (42,690 loads at about 4.3: a 2-clock hit
plus the issue and completion states), S_DECODE 11%, S_FETCH 10%,
S_PIPE_START and S_EXEC 8% each, the EA and operand states about 15%.  The
`bench_loop` inner loop shows the same shape without any misses: a cached
`move.l (a0)+,d0` costs eleven states, `add.l d0,d2` four and a taken `dbra`
six, twenty-one clocks for three instructions.

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
200,102 -> 134,722).

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

Use Verilator; the legacy `run_tests.sh` invokes Icarus and is not used here.
All generated files and bounded subprocess logs go under `--work`.

The whole regression in one command (every program bench preset and every
self-checking unit bench, negative controls inverted; only the snoop bench's
X-poison legs stay with Icarus because they need four-state simulation):

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
* Timing summary: `output_files/Minimig.sta.summary`.

Cycle counts and the full corpus comparison are also recorded in
[`performance_40mhz.json`](performance_40mhz.json).
