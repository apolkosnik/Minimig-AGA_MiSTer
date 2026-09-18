# CPU audit prompted by Elysium and Deformations

Audited on 2026-09-18. Two posted-write synchronization defects reproduced
in simulation. Neither has yet been tied to an instruction trace from the
reported demos. The running image, failing parts, cold-boot reproducibility,
and cache/MMU settings were not supplied, so this is not a diagnosis of the
two demos or a claim that their graphics corruption is explained.

Scope: CPU interrupt entry/return, posted stores, cache maintenance, MMU
cache attributes, bus adapter/enables, and DMA snoop paths, supported by
the existing ISA/MMU/FPU tests. This is not an exhaustive ISA or chipset
audit. No production RTL was edited, no Quartus build was started, and no
image was flashed.

The checkout is `dc982258b` with pre-existing staged changes in
`rtl/ap040/ap040_cache.v` and `tests/ap040/tb_ap040_cache_snoop.v`. Those
changes were preserved. `git diff 33e173e22 -- rtl` is empty: the audited
working-tree RTL is the deployed baseline, not the parked four-entry queue.

## 1. High priority: NOP does not synchronize the posted write buffer

At [ap040_core.v:5666](rtl/ap040/ap040_core.v#L5666), NOP immediately calls
`fetch_next`. The core has no input telling it that the cache is still
draining a write. Production [cpu_wrapper.v:372](rtl/cpu_wrapper.v#L372)
lets the core execute during that drain.

Repro: enable I/D caches; run code and a word-aligned stack in configured
Fast RAM; request two level-2 interrupts. The handler increments a register,
clears a synthetic interrupt device, executes NOP, then RTE. The clear is
delayed on the external bus. The first invocation warms the handler and
stack. With SP = 2 modulo 4, RTE's stacked PC is longword-aligned and its
frame reads can hit in cache. On the second invocation, NOP and RTE execute
before the clear lands; RTE accepts the old asserted interrupt again.
The program observes **three entries for two requests**.

This reproduces in all three handshake phases with delays of 32, 64, 128,
and 200 bench clocks. Zero added delay passes. Disabling posting passes.
A diagnostic-only core copy that waits for the drain at NOP also passes.
SP = 0 modulo 4 masked the issue in the preliminary probe: the unaligned
PC read bypassed the cache and implicitly waited for the drain.

The NOP behavior violates the bus synchronization requirement in
[MC68040 User's Manual, section 7.7, printed page 7-44](https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf#page=186).
The no-NOP version is not used as evidence of an architectural defect.
Cache-inhibited serialized mode does not by itself make every write wait
for completion; section 7.7 describes its ordering restriction on reads.

An extra interrupt can disturb frame counters and demo part sequencing.
That is a plausible connection, not an observed trace of either demo.

## 2. High priority: cache maintenance can complete before an earlier write

[ap040_cache.v:653](rtl/ap040/ap040_cache.v#L653) enters the invalidate sweep
without checking `sb_v`. At [line 828](rtl/ap040/ap040_cache.v#L828), it raises
`cinv_done` after the sweep regardless of whether the posted write landed.
The core consumes that completion at
[ap040_core.v:3700](rtl/ap040/ap040_core.v#L3700). CINV and CPUSH share this
path because the cache is write-through.

Replacing the probe's NOP with either `cinva dc` or `cpusha dc` reproduces
`cinv_done && post_drain` at delays 128 and 200, in all three handshake
phases. A monitor stops each run on that condition; these runs do not
claim to observe subsequent graphics corruption. Delays 0, 32 and 64
pass. Disabling posting, or making a diagnostic cache copy wait for the
drain before starting maintenance, passes every tested delay.

The maintenance timing/ordering rules account for pending writes and
prefetches in [MC68040 User's Manual, section 10.3, printed page 10-8](https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf#page=299).
Write-through removes dirty-line writebacks, but an acknowledged store
still sitting in this buffer has not reached memory. Maintenance cannot
treat that store as already globally complete.

## 3. Coverage gap: core_post does not model production drain overlap

[tb_ap040_program.v:65](tests/ap040/tb_ap040_program.v#L65) stops its enable
during a bus wait, and [line 153](tests/ap040/tb_ap040_program.v#L153) connects
that same enable to both core and adapter. The suite's `core_post` entry
changes only `POST_STORES=1`. It therefore does not test the production
split where the core continues while a posted write waits on the bus.

Restoring the original shared enable in the new probe makes **all 15
cases pass on the defective RTL**. This directly establishes the blind
spot. The wrapper-based benches do have the real split; their passing
results do not cover this combination of warmed Fast RAM code/stack,
stack alignment, delayed interrupt-clear write, and synchronization.

## Reproduction and results

Run:

```sh
python3 tests/ap040/audit_posted_ordering.py --work /tmp/ap040-posted-order-audit --jobs 4
```

The runner creates temporary bench/RTL copies; production files remain
untouched. It uses [t_posted_irq_audit.s](tests/ap040/asm/t_posted_irq_audit.s).
The device at `$00dff110` is a synthetic interrupt latch, **not** a model
of the actual Amiga register at that address. Fast RAM is backed by the
bench's flat memory through an explicit address alias. The diagnostic
NOP control uses a hierarchical reference and is not a production fix.

Each case runs three handshake phases. There are five delays per instruction.

| Configuration | NOP cases | CINVA cases | CPUSHA cases |
|---|---:|---:|---:|
| Baseline, production-style split enables | 1/5 pass | 3/5 pass | 3/5 pass |
| Posting disabled | 5/5 pass | 5/5 pass | 5/5 pass |
| Temporary drain-wait controls | 5/5 pass | 5/5 pass | 5/5 pass |
| Original core bench shared enable | 5/5 pass | 5/5 pass | 5/5 pass |

Logs and structured results: `/tmp/ap040-posted-order-audit/`.
The runner records observed failures; it is an audit tool, not yet a
regression-suite entry that requires all production cases to pass.

Existing verification also ran:

- Posted snoop/real-memory DMA checks, divide-1/divide-4 collision checks,
  their must-fail controls, bus-gap and bus-timeout tests: 9/9 legs passed.
- Core tests: all 14 assembly programs passed both with and without
  posting. Dhrystone initially failed to compile because `vbccm68k` was
  absent from PATH; rerunning Dhrystone with the toolchain directory on
  PATH passed in both configurations. This was an environment failure,
  not a CPU test failure.
- Fast-clock divide-4 wrapper: all seven selected programs passed
  (`t_integer`, `t_exceptions`, `t_mmu`, `t_fpu`, `t_moves_fc`,
  `t_movem_restart`, `t_atcprobe`).

No new DMA stale-data failure was found in these checks. They do not run
the demos, the complete chipset, or the real snoop CDC with every DMA
arbitration schedule. The full cputest corpus was not rerun for this audit.

Recommended next change: implement a proper core-visible drain completion
contract for NOP, and interlock cache maintenance with pending stores;
turn these repros into regression gates using production enable behavior.
Then validate on the named demos with a timing-clean image, recording the
exact image, failing part, cache/MMU setup, and cold-boot behavior. No
timing or performance claim can be made for the temporary controls.
