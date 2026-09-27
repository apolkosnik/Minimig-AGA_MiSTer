# Full-system timing repair — 2026-09-27

The full-system seed-4 build passes all reported constrained timing checks
at the existing clock frequencies. The RBF, reports and source hashes are
saved below. Hardware testing remains outstanding.

## Build scope

This is the default `Minimig` project in this workspace, based on `eefc5367`.
It selects the sequential `ap040_tg68k_compat` core: `AP040_PIPE_CORE` is not
defined. It is not a timing result for the separately synthesized pipelined
CPU or an integrated pipelined-core image.

The CPU, memory-controller and HDMI clocks remain approximately 28.38 MHz,
113.5 MHz and 148.54 MHz. No PLL setting, SDC exception or clock period was
changed. `Minimig.qsf` now selects fitter seed 4, replacing baseline seed 2.
Quartus 17.0.2 was run outside the sandbox.

## RTL changes

- `rtl/cpu_wrapper.v`: in the default `FAST_CLOCK=0` configuration, capture
  RAM ready and read data together on the rising CPU edge. The CPU-side
  enable and data logic then have a full CPU period, instead of receiving
  a late controller response directly. `ramconsumed` follows consumption
  of this captured response, so the controller cannot release a response
  before the CPU reads it. Each RAM response gains one CPU clock before
  consumption. The `FAST_CLOCK=1` path is unchanged.
- `rtl/ap040/ap040_fpu.v` and `rtl/ap040/ap040_cache.v`: mark `ce` as the
  dedicated register enable with Quartus's `direct_enable` attribute. This
  is a synthesis mapping hint with no behavioral change.
- `sys/ascal.vhd`: register the polyphase sum before saturation, using the
  existing next-stage output selection to retain the original pixel
  latency. Split the RGB maximum across the existing C3/C4 stages, shorten
  horizontal accumulator feedback by reassociating its modular arithmetic,
  and move the increment out of the line/frame boundary comparisons. Move
  the final horizontal divider step into its existing fraction delay stage,
  retaining the matching divisor. Split vertical line-edge comparison and
  pixel selection across the existing C8/C9 stages. Arithmetic,
  rounding/truncation, pixel latency and clock-enable behavior are preserved.
- `sys/sys_top.v`: add a matched HDMI output stage for RGB, HS, VS and DE.
  All four gain one pixel clock (about 6.7 ns); their relative alignment
  and pixel throughput remain unchanged. Disable shift-register-to-RAM
  inference on the RGB stages so they remain physical flip-flops.

## Fitted results

The final full compile completed successfully at 02:39 EDT on 2026-09-27
for Cyclone V `5CSEBA6U23I7`. The following comparison uses the same four
standard timing corners in the baseline and final compile reports:

| Clock domain | Baseline setup slack | Final setup slack | Final hold slack |
| --- | ---: | ---: | ---: |
| CPU, approximately 28.38 MHz | −0.864 ns | +0.493 ns | +0.098 ns |
| Memory controller, approximately 113.5 MHz | +0.219 ns | +0.546 ns | +0.038 ns |
| HDMI, approximately 148.54 MHz | −0.546 ns | +0.236 ns | +0.038 ns |

All 160 standard summary entries pass: setup, hold, recovery, removal and
minimum pulse width, with zero total negative slack in every entry. A
separate detailed TimeQuest run also checked setup and hold in all eight
available slow/fast models at −40, 0, 85 and 100 °C. All pass. Including
these additional models, the memory-controller setup minimum is +0.500 ns
at the slow 85 °C corner; CPU and HDMI minima remain +0.493 and +0.236 ns.
The minimum hold slack across the eight models is +0.038 ns.

Quartus still reports the existing incomplete setup/hold constraints.
These results cover paths constrained by the existing SDC; they do not
establish timing for unconstrained paths. No timing exceptions were added
or relaxed to obtain these results.

| Resource | Baseline | Final | Change |
| --- | ---: | ---: | ---: |
| ALMs, of 41,910 | 39,758 | 39,610 (94.51%) | −148 |
| Registers | 36,053 | 36,248 | +195 |
| RAM blocks | 293 | 293 | 0 |
| Block-memory bits | 2,085,992 | 2,086,016 | +24 |
| DSP blocks | 75 | 75 | 0 |
| PLLs | 3 | 3 | 0 |

## Build artifact and evidence

- [Passing RBF](output_files/Minimig-ap040-pipelined-eefc5367-20260927_022129-seed4.rbf),
  4,027,932 bytes; SHA-256:
  `73cf3a4bf0979fb39b8521879c9ebe533cf013d171cc4715b4169b3268ca900b`.
- [Final timing summary](output_files/timing-fix-20260927/final.sta.summary)
  and [fitter summary](output_files/timing-fix-20260927/final.fit.summary).
- [Machine-readable result and source hashes](output_files/timing-fix-20260927/final-result.json).
- [Detailed eight-model paths](output_files/timing-fix-20260927/final-paths/).

The winning build ran in `/tmp/ap040-timing-seed4`, an isolated copy of the
working sources. After adopting seed 4 here, every tracked file matched
that build workspace byte for byte. The manifest records the base commit
`eefc5367421a49978815d2872ab8f9d3c590ec68` and hashes of the modified source
and configuration; the RBF includes the uncommitted timing changes.

Use the named RBF and `final.*` reports above. The shared
`output_files/Minimig.rbf` retains the previous image, and the main
workspace's bare `Minimig.*` reports/database belong to the earlier seed-3
fit. They are not the final seed-4 result. A new build with the current
`Minimig.qsf` will use seed 4.

Baseline reports, candidate source hashes, patches and regression evidence
are also retained under `output_files/timing-fix-20260927/`.

## Functional validation

- RAM response regressions: 17 passing MMU/FPU program runs across SDRAM,
  SDRAM plus DDR, all four CPU phases, both controller read-pipeline
  settings, and cache-bypass cases. Interrupt testing runs at the bench's
  supported interrupt phase (phase 3); other phases cover memory traffic.
- Boot bridge: 16 passing phase/arbitration runs across legacy clocking
  and `FAST_CLOCK=1, CORE_DIV=4`.
- FPU execution, frame and resume programs: six passing runs across the
  legacy and fast-clock configurations.
- Cache snoop and posted-store checks: five passing test legs, including
  an injected DMA corruption control that must fail.
- Scaler: all 524,288 possible 19-bit sums in three channels, continuous
  and stalled pipelines, plus all 16,777,216 RGB combinations for the
  maximum selector. Also all 16,777,216 12-bit counter/total combinations
  and 1,327,104 horizontal accumulator/geometry cases. This checks the
  datapath and its latency, not a full video frame.
- Retimed horizontal fraction and vertical edge selection: 100,000 cycles
  against frozen original production RTL, covering `FRAC=4..8`, all
  12-bit divisor values, geometry changes and pixel-enable gaps.
- HDMI: 10,000 cycles each for normal and `MISTER_DEBUG_NOHDMI` builds,
  including mode changes. The actual output block is compared with the
  original behavior delayed by exactly one clock.
- Full scaler VHDL analysis and `git diff --check` passed.

The dual-memory bench's direct cache-seeding selftest now waits for an
active cache-clear sweep to finish, matching the SDRAM-only bench. The
extra CPU response latency exposed this existing test setup race; the
rerun logged the active sweep and passed the unchanged snoop assertions.

The new focused checks can be reproduced with:

```sh
python3 tests/ap040/check_ascal_poly_timing.py --work /tmp/ap040-scaler-check
python3 tests/ap040/check_hdmi_output_pipeline.py --work /tmp/ap040-hdmi-check
python3 tests/ap040/check_ascal_stage_timing.py --work /tmp/ap040-stage-check
```

## Measured simulation performance cost

The RAM boundary adds one CPU clock per external 16-bit response.
Internal execution and internal cache hits retain their existing clocks.
The following matched simulations use the same compiled 200-iteration
Dhrystone 2.1 binary, including startup and final value validation:

| Instruction fetch configuration | Before: clk113 cycles | After: clk113 cycles | Runtime increase |
| --- | ---: | ---: | ---: |
| Uncached chip-memory fetches | 5,698,239 | 6,706,975 | 17.70% |
| Internally cached fetches | 3,181,375 | 3,207,519 | 0.82% |

These are simulation cycle counts, not board Dhrystones/s or DMIPS. Both
cases use `tb_sdram_turbo` with `CPU_PHASE=3`, `READ_PIPE=0`, `CPU_CACHE=1`,
`FAST_CLOCK=0`, and periodic controller-cache invalidation. The cached
case sets `CACHE_ALLOW_ALL=1` to permit internal instruction caching in
the chip address window; it is not a DDR Fast RAM model. The reference
uses the original `cpu_wrapper.v` from `eefc5367` with the same other RTL.

Results and matching binary SHA-256 hashes are recorded in
`output_files/timing-fix-20260927/performance.json`.

## Hardware validation

No board has been programmed as part of this change. Boot, RAM stress,
FPU software, video modes and real board performance remain to be checked
on hardware with the named seed-4 RBF.
