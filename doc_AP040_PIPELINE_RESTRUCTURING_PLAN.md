# AP040 pipeline restructuring plan

Status: planned; implementation has not started. Created 2026-09-24 from the
instruction restructuring review of `dbccaa6f` plus its working-tree changes.

Improve instruction throughput by removing unnecessary dependencies and memory
accesses, distributing work across pipeline stages, and allowing independent
operations to overlap. Preserve architectural results, exception/restart
behavior, clock-enable handling, and the 40 MHz implementation target.

This is the current performance work plan; the original
[implementation plan](doc_AP040_PIPELINE_PLAN.md) remains the feature history.
Use `rtl/ap040_pipe/` and `tests/ap040/` as the active paths. The sequential
reference lives in `rtl/ap040/`; retain its identity when making comparisons.

## Baseline and measurement rules

The review ran 60 primary sequences and 12 dependency/follow-up sequences in
two memory configurations: 144 focused simulations. Each sampled 96 steady
instruction/block intervals. These establish throughput, not complete ISA
correctness. Local memory means the behavioral array; bus means the shared
32-bit interface with zero added waits. Neither is a production cache-hit or
16-bit board measurement.

| Workload | Local CPI | Bus CPI |
|---|---:|---:|
| Register ADD, EXG, LSL, MULU.W | 1 | 1.5 |
| Repeated MOVE.L (A0),D1 | 3 | 6 |
| Loads alternating D1/D3 destinations | 2 | 5.5 |
| Passing CHK.W checking the same register | 2 | 2 |
| Passing CHK.W alternating checked registers | 1 | 1.5 |
| MOVE.L D1,(A0) | 2 | 5 |
| CLR.L (A0), ST (A0) | 4 | 8.5 |
| Register read-only / modifying bitfields | 9 / 10 | 9 / 10 |
| Eight-register MOVEM.L load / store | 19 / 18 | 43 / 34 |
| MOVE16 (A0)+,(A1)+ | 18 | 35 |
| Register FMOVE.X | 9 | 9 |
| Two-register FMOVEM.X load / store | 36 / 30 | 54 / 34 |
| MULU.L / DIVU.L | 3 / 11 | 3 / 11 |
| MOVE.L immediate / LEA displacement | 3 / 2 | 4.5 / 3 |

Starting evidence is in `/tmp/ap040-pipeline-structure/` (review, harness,
assembly, JSON results, logs and source hashes). Preserve the useful evidence
in the repository during phase 0 so this plan does not depend on temporary
files surviving. The current microbenchmarks use simple operand values;
extend dependency and operand coverage before setting workload expectations.

The September 24 archived standalone fit reports 16,271 CPU-hierarchy ALMs,
7,440 registers and 17 DSPs; its complete test top uses 17,475 ALMs and reaches
40.43 MHz. It predates the current working changes. Establish a fresh baseline
before attributing area or timing changes to this work. Compare like-for-like
tops, parameters, constraints, tool versions and fitter seeds.

## Delivery order

| Phase | Deliverable | Depends on |
|---|---|---|
| 0 | Reproducible baseline and fault/handshake coverage | Current tree |
| 1 | Operand-specific hazards and actual write dependencies | 0 baseline |
| 2 | Write-only memory CLR and Scc | 1; relevant write-handshake fixes |
| 3 | Shorter bitfield sequencing | 1 |
| 4 | Explicit instruction metadata and a real operand/address stage | 1–3 |
| 5 | Ordered memory request/response engine and streamed transfers | 4; relevant fault fixes |
| 6 | Staged bitfields, thinner FPU dispatch, staged long multiply | 4; 5 for memory forms |
| 7 | Optional divide overlap with ordered completion | 6; measured workload benefit |
| 8 | Wider instruction assembly and integration qualification | Explicit hazards from 4; final unit interfaces |

Land each independently testable change separately. Phase 6's execution units
can be delivered individually. Investigate instruction-word delivery earlier,
but do not remove gather spacing until its hidden hazard assumptions are gone.

## Phase 0 — Make the baseline reproducible

- [x] Record HEAD, working diff and RTL hashes; preserve existing user changes.
  Done: `run_pipe_perf.py` records HEAD and whether `rtl/` is dirty in every result; the restructuring review's own tree was preserved as bundle 10's WIP commits.
- [x] Turn the temporary performance probes into a maintained runner, assembly
  cases and machine-readable results under `tests/ap040/`. Include dependencies,
  bus transaction counts and architectural checks alongside timing. Reject
  missing images, missing measurements and unexpected exceptions.
  Done: `tests/ap040/run_pipe_perf.py` + `perf/tb_ap040_pipe_perf.v`, 77 cases (the review's 60, its probes, the write-only shapes); retirement, port-B read/write and bus-transaction counts; a missing image, missing measurement, exception or wrong retirement count fails the case; `perf/baseline.json` with `--check`.
- [ ] Measure instruction latency, initiation interval, instruction words,
  accepted reads/writes and stall reasons separately. Treat paired sequences as
  blocks and normalize their CPI explicitly.
  Partly: initiation interval, instruction words, reads/writes and the stall holds are recorded; dependent latency is measured only by the paired probes (`data_to_store`, `address_to_load`, `mul_four_alu`, ...), not as its own column.
- [x] Reproduce the review-16 write acceptance loss during `ce=0` and FPU operand
  fault/exception-port ownership defects. Add focused regressions and fix them
  before changing the affected handshake or adding concurrency. Temporary
  experiments in `/tmp/ap040-review16/` are evidence, not qualified fixes.
  Done: both fixed in bundle 10 (86f69b53): the write receipt and the FPU sequencer stopped by an access fault; `tb_ap040_pipe_wrreceipt_bus16.v` and `_fpufault_bus16.v` fail without them.
- [x] Record current `t_mmu` and `t_bitfield_mmu` failures by case/phase. The
  program runner's overall PASS currently excludes failures in its OPEN list.
  Keep these visible and require resolution before final integration sign-off;
  unrelated gaps need not block phase 1's local improvements.
  Done: none remain: bundle 10 made all fifteen programs required, passing all three phases on both suites.
- [x] Capture a fresh standalone fit with the existing 25 ns constraints.
  Done: 476cc5d3: 17,595 ALMs, 40.41 MHz, +0.251 ns at 25 ns.

Exit: repeatable results for the actual working sources, explicit known gaps,
and durable regressions for acceptance/fault ownership. No performance claim
may rely on reducing the amount of architectural work completed.

## Phase 1 — Describe the operands each instruction actually consumes

Primary files: `ap040_decode.v`, `ap040_ea_calc.v`, `ap040_ea_fetch.v`,
`ap040_execute.v`, `ap040_pipe_cpu.v` in `rtl/ap040_pipe/`.

- [ ] Classify operand roles: EA base/index, ALU source, old destination,
  store data, CCR, early trap operand and auxiliary result destinations.
  Implement the minimum explicit metadata needed; do not introduce another
  broad instruction-family approximation.
  Partly: the address views' consumers are enumerated in `ap040_ea_fetch.v` (`addr_use_a`/`addr_use_b`); no general operand-role metadata yet.
- [ ] Qualify forwarding/hazard producer matches with actual write enables,
  including conditional, second-port and banked-stack writes.
  Partly: CHK's match is qualified by `eaf_writes_reg`; the other producer matches are not yet reviewed.
- [x] Restrict `addr_hz` to inputs consumed by address/early-verdict logic.
  An overwritten load destination is not an address input. Handle store-data
  forwarding independently from base/index readiness.
  Done: `addr_hz` holds only a port whose address view feeds an address or a verdict: a load's destination (port B) and a plain store's data (port A) no longer wait. Repeated MOVE.L (A0),D1: 3 -> 2 local cycles.
- [x] Correct CHK's destination match so a preceding CHK that writes no GPR
  cannot create a false GPR dependency.
  Done: repeated passing CHK: 2 -> 1 local cycle.
- [x] Preserve real change/use stalls where a long EX result would otherwise
  enter the AGU or exception decision in the same cycle.
  Done: the base, index, push, memory-to-memory destination and every verdict operand still hold on a long forward (`address_to_load` unchanged at 4).

Validation: repeated and alternating load destinations; ALU-to-store-data
versus ALU-to-address; passing and trapping CHK; EX/WB forwarding; dual writes;
A7 banking; a producer stalled by memory/divide; random CE and flush.

Exit targets: repeated ordinary loads reach **2 local CPI**; repeated passing
CHK reaches **1 local CPI**; no extra bubble for a store-data-only dependency
when that value can be forwarded safely. Register ADD/EXG/shift/MUL.W remain
at 1 local CPI. These are implementation targets, not completed improvements.

## Phase 2 — Give memory CLR and Scc write-only paths

Primary files: decode, EA-fetch, execute and CPU memory-port arbitration.

- [x] Decode CLR memory as a sized zero store with CLR's CCR result.
  Done: `id_st_only`: CLR leaves EA-fetch with no read and EX stores it as it stores a read-modify-write; flags from EX's CLR.
- [x] Decode Scc memory as a sized predicate store using the correct CCR
  producer; preserve CCR itself.
  Done: same path; EX's condition reads the forwarded CCR as before.
- [x] Remove destination reads in direct and extension-word addressing forms.
  Preserve the genuine read-modify-write paths used by other instructions.
  Done: direct, displacement, indexed and absolute forms (decode's `held_st_only` for the gathered ones); 0 reads in every write-only case of the perf runner.
- [x] Carry the store address, privilege/function code, An update and fault
  context explicitly. Do not commit flags/address changes too early on faults.
  Done: the EX store's address, size, An step and fault path (EX abandons and refetches, EA-fetch takes the owed fault) are the read-modify-write's; `t_fault_edges.s` 30-37 refuses and restarts CLR and ST (A0)+ on both cores; `tb_ap040_pipe_wronly_bus16.v` checks zero reads, one store per operation, every byte of a read-sensitive window, flags, A7's byte step and a wrong-path CLR.

The Motorola programmer's reference manual identifies preliminary reads for
CLR and Scc as MC68000/MC68008 behavior (CLR p. 4-74; Scc p. 4-173). The
sequential implementation is useful for architectural comparison but must not
force an unnecessary read into this 68040 path.

Validation: byte/word/long CLR; all Scc conditions; immediate flag producers;
all supported EAs; A7 byte steps; adjacent-byte preservation; read-sensitive
device model; write faults, MMU rejection, CE pauses and wrong-path squash.
Count operand reads separately from instruction fetch and page-table walks:
there must be **zero destination reads and one accepted logical store**.
Physical beat counts must match access size/alignment on the 16-bit adapter.

Exit target: simple stable-condition cases reach ordinary-store throughput,
initially **at most 2 local CPI**, versus the measured 4. Confirm the reduction
in real bus transactions as well as CPI.

## Phase 3 — Remove redundant bitfield preparation cycles

Primary files: decode and EA-fetch; use existing `bitfield` and `bitmem` benches.

- [x] Supply immediate offset/width together, retaining width-zero-as-32 rules.
  Done: both are taken at the sequencer's start and the port-C phases are skipped; width 0 still means 32.
- [ ] Gather dynamic operands according to actual register-port availability;
  preserve overlaps among field operand, offset, width and BFINS source.
- [x] Rotate register operands directly into the aligned window, bypassing the
  register form's zero-shift `BF_S1` copy.
  Done: the rotation loads the S2 input directly; register forms 9/10 -> 6/7 local cycles.
- [ ] Separate read-only result generation from modifying merge/writeback work.
  Retain timing stages around variable rotate/shift/mask/leading-zero logic.
- [ ] Reuse preparation for memory forms without widening their access spans.

Validation: all eight opcodes; immediate/dynamic offset and width; widths 1/32;
register wrap; negative memory offsets; one-to-five-byte spans; source/destination
aliasing; flags; byte preservation; fault on each transfer; CE pauses/flush.

Exit targets for immediate register forms: read-only **at most 7 local CPI**
(baseline 9), modifying **at most 8** (baseline 10). Dynamic and memory forms
must not regress. This phase shortens the existing sequencer; it does not yet
claim an overlapping bitfield execution unit.

## Phase 4 — Establish stage and completion ownership

Approach taken (2026-09-24), each step behaviour-neutral until its check has
run over every suite and the corpus:

1. A conservative write set per instruction (`ap040_ea_fetch.v` `wr_mask`,
   from the instruction's fields) and a Verilator check at every register
   write port -- WB's two, EX's early An step, EA-fetch's MOVEM port, the
   stack-pointer banks -- that the set covered it. (Found at once: DBcc's
   counter is decided in EX and was in no field; MOVEM's last load lands
   after the MOVEM has left EA-fetch.)
2. EA-calculate forms the address of the simple loads, read-modify-writes
   and plain stores ((An), (An)+, -(An), (d16,An), absolute) from a fourth
   register-file port and EX's An step, when neither instruction ahead may
   still change the base; EA-fetch asserts every address it forms equals it.
3. EA-calculate holds such an instruction until its base is resolvable (EX's
   forward admitted, into a register), and EA-fetch uses the registered
   address for it alone.
4. The same for pushes, RTS/RTE pops and the indexed forms. Only when every
   L1 address source is a register does the adder leave the L1 address path
   -- the bus16 top's timing (33.43 -> 35.84 MHz so far) and phase 5's base.

Steps 1 and 2 are in: both suites, fast and with a random clock enable and
the slow L1, ran with neither check firing.

Step 3 is in, and step 4 in part. EA-calculate takes the base from the
youngest producer: the instruction ahead's (An)+/-(An) step (formed there a
cycle earlier, a register, and its only write to that register), EX's
result (taken only in a cycle EX advances, so it is final, and only into a
register), EX's An step, or the register file. It waits for anything else:
another write from the instruction ahead, a write EX makes that is not
forwarded, a MOVEM load still landing. EA-fetch uses the registered address
and An value for (An), (An)+, -(An), (d16,An), (d16,PC) and absolute loads,
read-modify-writes, CLR/Scc and stores, displacement stores included; its
own views remain only to check them (`agu:`), and an invariant checks that
no such instruction reaches EA-fetch without its address. The waits moved
rather than grew: the 77 perf cases are unchanged, cycle for cycle. The
core top fits at 43.33 MHz (+1.921 ns at 25 ns, 18,355 ALMs, +654 for the
fourth port and the stage) with EA-calculate in none of the 40 worst paths.
`t_agu.s` puts an access straight behind the producer of its base from each
source, on both cores.

Two things the checks could not see, found by a mutation that should have
cost cycles and did not. EA-fetch still forms, correctly, any address it is
not given, so an instruction the stage wrongly passes over fails nothing:
the classification took MOVE from SR/CCR's CCR bit -- opcode bit 9, decoded
for every instruction -- as a MOVE from SR, and every access with bit 9 set
(any load into D1, D3, D5 or D7, among others) had been going the old way.
The perf harness now counts the instructions that leave EA-fetch with an
address from EA-calculate, and `--check` fails a case that has fewer than
its baseline. And a MOVEM load whose beat faulted left its read marked
outstanding through the exception: since `l1_rvalid_b` is a level, every
read after it -- the vector, then the handler's own loads -- was written
into the faulted beat's register until the next flush, which a handler
could see, though the restart then reloaded it. `t_fault_edges.s` 38-45
check the handler's view on both cores; the MOVEM port now only ever
writes for the MOVEM in EA-fetch, which the write-set check holds, and so
EA-calculate needs no wait of its own for a MOVEM's last load.

Left for later, on the evidence of the fits: pushes, pops, the indexed and
full-format forms and the sequencers' starting addresses. The L1 address
adders are not what limits either top -- the core's worst path is EX's
result into EA-fetch's operand registers, and bus16's is EA-fetch's
sequencer selects into membus's prefetch-window snoop, which phase 5's
request storage removes -- so moving them buys structure, not time. They
move when phase 5 wants every request's address from a register.

Primary files: CPU, decode, EA-calculate, EA-fetch, execute and register file.

- [ ] Define a documented instruction metadata bundle compatible with the
  existing Verilog/Quartus flow: PC/next PC, operation, operand roles, size,
  destinations, CCR effects, privilege/function code, An updates, memory
  attributes and exception/restart context.
- [ ] Specify valid/ready, acceptance, response, completion, squash and CE
  behavior. Retain acknowledgements until consumed; accepted transactions
  must complete or fault exactly once.
- [ ] Move operand read and address arithmetic into EA-calculate incrementally:
  simple EAs and LEA, then indexed/full-format forms and secondary addresses.
  Register addresses before the memory stage. Adjust forwarding/read ports as
  needed rather than merely moving the adder into an earlier file.
- [ ] Preserve MOVE source-update-before-destination-EA semantics and genuine
  memory-indirect pointer dependencies.
- [ ] Give faults and completions a single instruction owner. Track partial
  progress for operations such as MOVEM; do not assume every instruction can
  delay all architectural effects until its final beat.
- [ ] Replace hazards that currently rely on gather bubbles, including port C
  and control-register dependencies, with explicit checks.

Exit: architectural and bus-event equivalence for the migrated paths, except
the intentional removed CLR/Scc reads; no new combinational
EX-result-to-AGU-to-memory path; no simple-ALU throughput regression. Keep
single-issue, ordered architectural completion as the initial design.

## Phase 5 — Stream ordered memory work

Progress (2026-09-24): the local targets below are met -- eight-register
MOVEM load 19 -> 12 cycles, store 18 -> 11, MOVE16 18 -> 12 -- with no case
slower. A run of loads now issues each next read in the cycle the last one's
data arrives (MOVEM, MOVEP, CHK2/CMP2's two bounds, CAS2's two operands);
the L1 model's write buffer takes a new write in the cycle it drains the
last one, so a run of stores is one per cycle; and MOVE16 reads its line
into a four-longword buffer back to back and then writes it, the sequential
core's own order. FMOVEM's reads are the FPU wrapper's microcoded read
subroutine and wait for 6B.

The bus16 top meets 40 MHz: 41.05 MHz, +0.642 ns at 25 ns (from 35.84 MHz,
-2.900 at d1373fc6, and 38.52, -0.959 with phase 4's step 3). Two changes.
membus's write snoop no longer works out which of two longwords a write
reaches: it takes both -- a rare extra refetch -- which took the write's
size and an adder off the worst path (EX's SR forward, the stack bank, the
address arithmetic, the snoop, pf_base). And a combinational loop that had
always been in the RTL -- EX's read-modify-write waits on wr_busy, which
membus formed from wren_b, which EA-fetch formed from its stalls, which EX
formed; Verilator's UNOPTFLAT on stall_self -- was synthesized as one for
the first time (22 nodes, a 17.7 ns LOOP element, 26 MHz). The CPU only
reads wr_busy while it presents a write, so membus now gives it wr_busy_w,
the same with wren_b taken as set; the loop is gone from both tools.


A plain load now leaves EA-fetch in the cycle its read goes out (lx): EX
takes the data from the port as it arrives, holds until then, and owns its
fault, which is abandoned and owed like a refused store's; port B is the
load's until its data is in, so nothing younger reaches memory first. A
plain load is one cycle rather than two locally (5.5 -> 5.0 on the zero-wait
bus, 8.5 -> 8.0 with two wait states, 13.0 -> 12.5 with five), and two
independent loads in a row are 2 rather than 4. The same for a read-modify-
write was built and measured and is not in: locally 4 -> 3, but on the bus
the store is then accepted in the cycle the read returns, which is the cycle
membus would have used for a prefetch -- it takes none in a write's accept
cycle, so a fetch can never overtake the write (d1373fc6) -- and RMW-then-ALU
lost a cycle at every wait count (9 -> 10, 15 -> 16, 24 -> 25). It waits for
a membus that can decide the prefetch against a registered write.

The corpus found the one thing no bench had: MOVE <memory>,SR and
MOVE <memory>,CCR, which decode marks as the ORI/ANDI-to-SR kind
(is_immsr) and EX writes from eaf_operand_a -- sent on this way, they
wrote the status register from a stale operand (MV2SR.B/.W in Basic,
Default and IRQ). They wait for their data in EA-fetch as before, and
t_agu.s 76-80 now have them.

Primary files: EA-fetch, `ap040_pipe_membus.v`, `ap040_pipe_l1.v`, bus16 and CPU;
include the FPU wrapper when moving its memory operations.

- [ ] Introduce bounded request/response storage with explicit per-beat owner,
  address, size, register destination, final-beat and restart information.
  Support response consumption and next-request acceptance without an empty
  bookkeeping cycle when the downstream memory can sustain it.
- [x] Allow store-buffer consumption and replacement in the same clock when
  legal (the L1 model; membus's bus is one transaction at a time). Preserve byte overlap, ordering, function codes and fault attribution.
- [ ] Feed MOVEM, paired memory operations, CHK2/CMP2 and FMOVEM through this
  engine. Do not expand all their transfer helpers into separate global stalls.
- [x] Give MOVE16 a small line buffer and consecutive-transfer path. Only use
  bursts where the downstream interface and memory attributes permit them.
- [ ] Keep device/strongly ordered accesses conservative. Preserve MOVEP's
  spaced byte transactions, bitfield boundaries, and CAS/CAS2 atomic ownership.

Validation: faults on every beat, aliased base/destination registers, identical
MOVE16 lines, cache-inhibited/device accesses, page crossings, pending writes,
snoops/self-modifying code, interrupts, CE pauses and reset/flush while busy.
Compare partial progress and physical transaction logs, not just final RAM.

Provisional local-memory targets with a one-beat-per-cycle-capable interface:
eight-register MOVEM load **at most 12 cycles**, store **at most 11**, and
MOVE16 **at most 12**. Confirm these budgets against the finalized interface
before implementation. Report bus-limited throughput separately; additional
queue entries cannot increase a serial external bus's transfer capacity.

## Phase 6 — Make execution units accept prepared operations

Deliver these as separate changes, preserving ordered completion.

### 6A. Register bitfields

- [ ] Move the phase-3 field datapath into staged execution with valid bits,
  operand/result metadata, forwarding and explicit dependency handling.
- [ ] Share it with memory bitfields through phase 5's operand-window path.
- [ ] Measure dependent latency separately from independent initiation rate.
  Aim to accept independent prepared register operations every cycle; the
  current word-at-a-time decoder may still limit instruction-level throughput.

### 6B. FPU dispatch and transfers

- [ ] Decode static FPU command class and operand requirements once. Launch a
  prepared command when operands, engine acceptance and deferred-exception
  ordering permit, without repeating general dispatch/decode helper states.
- [ ] Preserve the existing `fpu_bg` release of register-destination arithmetic.
  Keep deferred exceptions, FPSR/FPIAR updates and save/restore semantics.
- [ ] Route FMOVE/FMOVEM memory operands through phase 5; retain a dedicated
  serial path for architectural state save/restore and complex exceptions.

Target: register FMOVE falls below 9 CPI, initially aiming for **at most 7**;
FMOVEM loses transfer-helper bubbles. Validate `fpudual`, exception frames,
resume behavior and faulted operands before claiming improved FP throughput.
Operand-sensitive arithmetic timing needs representative finite/special values.

### 6C. Long multiply

- [ ] Replace `mul_wait` as a global EX hold with a staged multiplier request
  and result path; carry both possible destinations and CCR metadata.
- [ ] Preserve signed/unsigned, 32/64-bit result, register-alias and An-update
  behavior, including memory forms that produce three register effects.

Target: independent prepared operations can enter the multiplier each cycle;
register MUL.L instruction throughput approaches the current decoder's
**2 local CPI** supply limit. Keep MUL.W's existing 1-CPI path. Fit the design
before accepting additional DSPs, registers or bypass muxes.

## Phase 7 — Consider overlapping iterative division

Proceed when workload measurements justify the completion machinery and area.

- [ ] Retain an iterative divider initially; give it captured operands,
  destination/flag metadata and a tagged completion slot.
- [ ] Allow independent younger arithmetic to execute only with explicit
  dependency tracking and bounded ordered result storage. A scoreboard alone
  cannot preserve register/CCR order or exception precision.
- [ ] Prevent younger stores and irreversible state changes from passing an
  unresolved older operation. Specify interrupt, trace, flush and multi-result
  behavior before enabling overlap.

Validation: signed/unsigned word and long division; zero/overflow; dependent
consumers; CCR readers/writers; remainder aliases; memory-source faults; CE
pauses; younger exceptions; queue-full backpressure.

Exit: DIVU.L plus four independent-GPR ADDs takes **fewer than the baseline
15 local cycles**, with architectural CCR and completion order unchanged.
Do not assume fully pipelining/unrolling the divider is the best area tradeoff.

## Phase 8 — Improve instruction assembly and qualify integration

- [ ] Add wider word delivery/buffering, length/predecode information and
  assembled instruction packets. Start with common two-word forms, then long
  immediates and full-format/FPU extensions. A queue alone cannot exceed its
  sustained input-word bandwidth.
- [ ] Test producer/consumer adjacency previously hidden by gather cycles:
  indexed EAs, dynamic bitfields, MOVES function codes, MOVEC and stack banks.
- [ ] Preserve instruction-fetch faults, PC-relative bases, branch prediction,
  discarded extensions, page boundaries and self-modifying-code invalidation.
- [ ] Profile calls/returns and CAS2 before later target/return prediction or
  operand-gather optimization. Keep these outside the initial implementation.
- [ ] Run representative programs on the actual bus16/MMU/cache integration,
  resolve outstanding integration failures, and complete a full-system fit.

Exit: common multiword instructions improve when instruction supply is
available; 1-CPI register operations remain unaffected; real-system workloads
improve without correctness or timing regressions. Preserve explicit drains
for translation changes, exceptions/RTE and cache-control ordering.

## Validation and fit gates

For each focused change, run affected instruction benches in ordinary mode and
with random CE/slow memory. Include mixed sequences that exercise forwarding,
faults and interactions rather than only isolated instructions. Broaden to the
full suite/corpus at stage-interface and milestone boundaries.

Existing runner examples (select names relevant to the phase):

```sh
python3 tests/ap040/run_pipe_verilator.py --only move_mem,chk,bitfield,bitmem --work tests/ap040/build/restructure-directed
python3 tests/ap040/run_pipe_verilator.py --only cepause,storeonce,rmwsup,rmwfc,fpudual,smcdual,fxdual,irqdual --ce-random --slow-l1 --work tests/ap040/build/restructure-interactions
python3 tests/ap040/run_pipe_verilator.py --only program --ce-random --work tests/ap040/build/restructure-programs
```

Inspect every OPEN program result independently of the aggregate exit status.
Use `tests/ap040/run_cputest.py --core pipe` with the relevant instruction
groups and the installed corpus; compare architectural results against a
recorded reference revision. Bus semantics with deliberate corrections, such
as CLR/Scc, also require manual-grounded transaction expectations.

Run the standalone `tests/ap040/pipe_synth/run.sh` with a **new, dedicated work
directory for each checkpoint**: the existing script deletes its argument
directory before building. Fit after changes to forwarding, AGU placement,
bitfield logic, functional units or memory interfaces. Record CPU hierarchy
and whole-top ALMs, registers, RAM, DSPs, worst paths and all-corner timing.
Do not relax the 25 ns constraint to accept a performance optimization.

Each implementation change must report:

- Architectural/transaction checks and remaining known failures.
- Before/after CPI, dependent latency and independent initiation interval.
- Changes to instruction/data bus traffic and stall causes.
- Area/timing deltas when the datapath/interface changed; explain any increase
  against its measured benefit. No arbitrary full-system area estimate from a
  standalone CPU fit.

Final completion requires the targeted throughput gains, resolved relevant
fault/restart gaps, normal and stressed regressions, affected corpus coverage,
and timing closure within the FPGA's full-system capacity. Hardware speedup
remains unclaimed until measured on a qualified image.
