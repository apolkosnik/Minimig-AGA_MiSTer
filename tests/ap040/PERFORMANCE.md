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

**One is unresolved**, and absent rather than passing:
`cache_snoop_x_neg_accw`, the divide-1 acceptance control.  T12 in the bench
is the directed attempt on it, and it is a legitimate one: a don't-care word
may be any bit pattern, including tags that later requests match, so building
the row out of them tests whether corruption can become observable rather
than restricting the model.  Four lines are populated in one set with
distinct data, a collided row carrying their four tags with the way
associations rotated is injected, the suspect fill is triggered, and the four
are reread.

It finds nothing.  The experiment demonstrably fires -- 8 collisions with the
permuted row, one of them on an acceptance cycle -- and the four lines read
back correctly with the term blinded, identically to the intact run.  A
candidate explanation is in `ap040_cache.v` line 439: `tag_we` is gated by
`!fill_snooped && !snoop_fill_row`, so the writeback is protected
independently of the lookup guard, and a collided row cannot reach the tag
RAM by this route whether or not the acceptance term is blinded.

That leaves the term **neither proven necessary nor proven redundant**.  The
other candidates are stimulus this experiment does not reach, or the original
four-state failure having been simulation pessimism -- an X-induced failure
is conservative, not by itself a concrete hardware failure.

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

### Still unverified

Meeting the gate is not booting.  On hardware, none of this has been shown:
repeated cold boots, display-DMA stress, the I/O identities `tools/amiga`
probes, or that the speed survives any of it.  The last measured hardware
figure remains 6,615 Dhrystones from `d079808a`, a build that did **not**
meet timing.
