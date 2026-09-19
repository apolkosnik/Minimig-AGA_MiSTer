# Selective MacQuadra AP68040 ports

Source: [MacQuadra800_MiSTer AP68040](https://github.com/danifunker/MacQuadra800_MiSTer/tree/defef04c7273c1b14c7e1536729fbd8055818176/rtl/ap68040),
commit `defef04c7273c1b14c7e1536729fbd8055818176`. Implemented and measured
2026-09-19 in the integrated `rtl/ap040` sequencer.

## Changes

- Keep the most recent instruction and data ATC hits. Each copy includes
  permissions, nonresident status, cache mode and the modified bit. Reset,
  ATC writes, maintenance and TC changes invalidate the copies. Capture is
  gated by the local core enable so these registers remain in the timing
  constraints' tick-gated class.
- Consume available extension words during decode; decrement and resolve
  DBcc in its first completion state; retire eligible memory-source ALU
  operations when the read completes. Existing error priority, sized
  writeback, flags, interrupt/trace entry and A7 barriers still apply.
  Extension consumption and fetch redirects each use one shared control
  block, with combinational task arguments, to avoid duplicating their
  queue and address logic at every instruction's call site.
- Retain one 32-byte instruction sector and seed four queued words on a
  matching redirect. Only acknowledged **internal I-cache** responses may
  populate it. CACR alone cannot qualify a fetch because chip RAM, I/O and
  MMU cache-inhibited mappings can bypass the cache while CACR.IE is set.
  Architectural fetch flushes invalidate the sector. Speculative fetches
  outside it do not evict it.
- Accept index-suppressed full-extension I/IS encodings 101, 110 and 111,
  following the linked project's [Quadra 800 captures](https://github.com/danifunker/MacQuadra800_MiSTer/blob/defef04c7273c1b14c7e1536729fbd8055818176/docs/ap68040-memind-reserved.md).
  Other reserved-extension checks remain.

The local partial-write permission checks, MMU sweep pairing across enable
gaps, FPU register bypass and independent core/bus enables are preserved.
Cache geometry remains 4 KiB instruction plus 4 KiB data. The larger caches,
address-hint interface, whole-line delivery, single-cycle data hits and broad
decode lookahead from the source project are outside this port.

## Performance

Verilator 5.052, the local `tb_ap040_program` bench, posting disabled,
identical program images before and after. All three bus-latency phases
pass their program checks. The original executable was retained before
editing RTL; these are elapsed simulation clocks, not FPGA measurements.

| Program | Phase | Before | After | Fewer cycles |
|---|---|---:|---:|---:|
| `bench_loop` | 0 | 196,943 | 145,954 | 25.9% |
| `bench_loop` | 1 and 2, each | 197,721 | 146,732 | 25.8% |
| `dhry` | 0 | 890,120 | 865,525 | 2.8% |
| `dhry` | 1 and 2, each | 1,016,823 | 992,228 | 2.4% |

For context, the linked core takes 68,353 / 69,151 / 69,151 clocks on the
same loop image with posting disabled and its native cache geometry. This
bounded port does not bring the local sequencer to performance parity.

## Regressions

The complete Verilator suite passes **57/57 legs**, including the negative
controls that must fail. The partial-write restart matrix passes **688/688
cases** (344 each with posting off/on), each over three bus-latency phases.
Both final core configurations pass all 16 programs. The complete suite was
rebuilt after sharing the fetch-control blocks; all 16 programs retain their
exact earlier cycle counts in both posting modes.

`asm/t_fastpaths.s` covers sized load writeback, flags, load/use dependencies,
postincrement aliasing, DBcc register/CCR behavior, a page-crossing immediate,
the three indirect encodings, branch-buffer invalidation and uncached
self-modifying code. It is included in both program build runners.

`tb_ap040_atc_reuse.v` checks immediate same-page reuse after idle gaps,
separate instruction/data copies, modified-bit walks, PFLUSH replacement,
write/supervisor protection, cache inhibition, nonresident entries and
4 KiB/8 KiB page-size changes. The suite runs it with CE_DIV=1 and 4.

Two deliberate broken variants were built in the generated-artifact
directory: disabling ATC reuse fails its latency checks; removing the
I-cache qualification fails `t_fastpaths` case 26 in all three phases.
The original core fails the new indirect-encoding checks via the illegal
instruction handler. These controls confirm that the tests exercise the
changed behavior.

Reproduce the complete suite (requires the existing assembler and compiler):

```sh
PATH=/opt/amiga-cc/vbcc/bin:$PATH python3 tests/ap040/run_verilator_suite.py \
  --work output_files/macquadra-port/regression --jobs 8
```

Generated measurements and logs are under `output_files/macquadra-port/`:
`ap040-comparison-bench/` contains the baseline, `shared-suite/` contains the
final posted/unposted programs and integration/restart/unit matrix, and
`controls/` contains the negative controls. `fit-shared/` is the isolated
Quartus project snapshot for the shared-control implementation. `fit/`
preserves the initial failed fit (4,246 LABs required, 4,191 available),
which prompted the control-sharing change.
