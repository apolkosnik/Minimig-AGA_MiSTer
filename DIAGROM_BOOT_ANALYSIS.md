# DiagROM boot failure — confirmed chip-bus read timing defect

Analysis updated 2026-09-12 after the hardware report of no serial output and the power LED remaining low. Source baseline: `2a2da8b6`.

## Root cause

`rtl/cpu_wrapper.v`, `g_sync_chip`, sampled `chip_dout` on the rising `ph1` event at the same time it released the chip-bus strobes. The production `minimig_m68k_bridge` asserts DTACK before its read-data latch updates. That latch updates later, on a clk_sys edge with `!c1 && c3 && enable`. The fast wrapper therefore captured the previous transfer's data.

This corrupts the reset vectors before DiagROM executes its first instruction. With the local DiagROM V2.0 image:

| Address | Required word | Original fast-wrapper result (Verilator) |
| --- | --- | --- |
| `$000000` | `$1114` | `$0000` |
| `$000002` | `$4447` | `$1114` |
| `$000004` | `$00F8` | `$4447` |
| `$000006` | `$00D6` | `$00F8` |

The resulting PC is **`$444700F8` instead of `$00F800D6`**. The CPU continues fetching outside the intended ROM, so the early CIA writes and serial initialization never occur. This reproduces a mechanism consistent with the reported hardware symptoms; confirmation on the user's board still requires a rebuilt FPGA image.

In the diagnostic trace, the first completion is selected at 7675 ns; the bridge does not latch `$1114` until 7700 ns. The CPU consumes the wrapper's stale `$0000` at 7725 ns. These times are simulation times at the bench's 100/25 MHz clocks, not physical board measurements.

## Fix

The fast chip state machine still releases AS/UDS/LDS on the original phase, preserving the downstream write-strobe timing. It records a pending sample, then captures `chip_dout` and raises `chipready` on the following `ph2`, after the bridge latch has settled. Reset and bus-error abort clear the pending sample.

Only the fast chip-bus completion path changes. The legacy path and accelerated RAM path retain their existing behavior. This adds half a chip-clock period before CPU completion, rather than treating DTACK as proof that read data is already latched.

## Evidence and regression

- Original fast-wrapper RTL plus production `amiga_clk` and `minimig_m68k_bridge`: DiagROM V2.0 fails, no serial writes, wrong reset PC as above.
- Legacy wrapper plus the same bridge and ROM: correct reset fetch and startup serial writes.
- Fixed fast wrapper plus the same bridge and ROM: correct reset fetch and startup serial writes (first eight writes observed).
- New self-contained `tests/ap040/tb_cpu_wrapper_boot_bridge.v`: checks all four reset-vector words and requires actual downstream CIA DDR/PRA and SERDAT writes from a small embedded test program. No DiagROM file is needed.
- New test against the original RTL: fails on reset word 0 (`xxxx` instead of `$1114` in Icarus; its uninitialized bridge latch exposes the defect directly).
- Existing divide-four wrapper regressions also pass: integer (44,844 cycles), exceptions (163,644), MMU (1,355,768) and FPU (634,744). These use the existing assembled test images; only the simulator was rebuilt.
- Fixed RTL: **80 cases pass** across legacy mode and fast dividers 1/2/4, ten fast-clock phase offsets and two arbitration modes. The normal test runner includes 32 representative cases.

Diagnostic logs and temporary real-ROM bench are under `/tmp/ap040-diag-bridge/`: `trace.log`, `legacy.log`, `fixed.log`, `bench.v`, and the per-case sweep logs. The real-ROM bench includes CIA VPA/ECLK acknowledgement and observes bridge writes, but uses behavioral ROM storage and stubs other peripherals. It proves startup register writes, not a complete DiagROM menu or a physical UART waveform.

## Why the earlier analysis missed it

Both the existing direct DiagROM bench and the initial temporary wrapper bench supplied memory data immediately and did not instantiate the production read-data latch. They allowed the too-early sample to pass. The existing `tb_cpu_wrapper_chip_bridge.v` used the legacy wrapper by default and was absent from `run_tests.sh`.

The prior report's conclusion that no CPU integration defect had been reproduced is superseded by this result. The problem is in the CPU-to-chipset bus timing, not a demonstrated instruction decoder or arithmetic defect.

A low LED signal by itself must be interpreted with its polarity: `minimig.v` inverts CIA `_led` into `pwr_led`, and the framework applies further LED control. The corrupted reset PC is independent evidence; the diagnosis does not depend on interpreting LED polarity.

## FPGA image and timing evidence

Minimum emu-domain slack extracted across timing tables in each build log:

| Build start / commit | Minimum reported emu slack |
| --- | ---: |
| 13:09:06 / a6144508 | -1.319 ns |
| 13:58:32 / 0db34c9c | -1.252 ns |
| 14:19:48 / 3edd9a98 | -0.012 ns |
| 14:38:33 / 2a2da8b6 | +0.072 ns |

For the latest build, slow/hot setup slack is +0.125 ns on emu PLL counter 0 and +0.293 ns on counter 1. Negative setup slack remains in the HDMI domain (-0.399 ns hot, -0.597 ns cold); that alone does not establish a CPU execution failure. Positive reported CPU slack also does not independently prove the multicycle assumptions in `Minimig.sdc` correct.

The following files are not identical:

- `output_files/Minimig.rbf`: 3,939,728 bytes; SHA-256 `f9baef0447a212403e50f349d36e01f51fccf2f80fd44f9aa59d1549a68528f6`.
- `output_files/Minimig-ap040-40mhz-2a2da8b6-20260912_143833.rbf`: 3,977,880 bytes; SHA-256 `e2b89fbdb2cf5dfe505c365bd402b2329eb42b7527598f195cde233626005955`.

`build.sh` preserves/restores the shared filename on non-mainline branches. Its timestamp therefore cannot establish that it contains the latest compiled CPU. The build script also records earlier DiagROM failures after timing-blocked images were selected; that is repository history, not confirmation of which image is failing now.

## Hardware status

No FPGA build or deployment was performed for this fix. Existing RBFs still contain the original implementation. Synthesis/timing closure and boot on the real board remain to be verified with a rebuilt image; the simulation results do not claim hardware confirmation.

## Second defect (found after the first fix still did not boot): chip-bus writes acknowledged but never latched

With the read fix above in the image, the board still showed no LED, no colour and no serial.  An on-screen probe of the first eight completed CPU bus cycles after reset (drawn into the picture; MiSTer `echo screenshot > /dev/MiSTer_cmd`) showed the reset vectors and the first fetches correct over the chip bus and the CPU cycling at chip-bus rate with no stall and no bus error -- so the loss was downstream of the CPU.  DiagROM's first I/O are CIA-A byte writes (`$BFE200` DDRA, `$BFE001` PRA = power LED).

`minimig_m68k_bridge` drives its write strobes only while its registered `l_as` and `l_dtack` are both low (`enable = ~l_as & ~l_dtack & ~cck`), and the CIA latches a write on the `clk7_en`-qualified clk_sys edge after `l_dtack` falls, sampling `l_as` as registered one edge earlier.  The fast chip machine released AS at the ph1 after DTACK, about 20 ns before that preceding edge (`+trace_cia`: release 19525, edge 19545, latch edge 19585), so `l_as` was already high and nothing was latched.  The legacy machine releases on the edge itself.

Fix: `g_sync_chip` releases AS/UDS/LDS/RW four fast clocks after that ph1 (`release_dly`), ~2 clocks past the edge in every phase of the bench's sweep and ~2 clocks later than the legacy release; the read sample stays at the following ph2.

Proof: `tests/ap040/tb_cpu_wrapper_boot_bridge.v` now instantiates the real `rtl/ciaa.v` (and `cia_*.v`) behind the bridge and asserts on the CIA's *latched* DDRA/PRA at the pass point.  The strobe-only check passed with the defect in place; the latched-state check fails on the old fast machine and passes 32/32 (fast dividers 4/2/1, legacy, phase and arbitration sweeps) with the fix.  Cost: unchanged from the read fix alone (+1.3..3.4% on the all-chip-bus bench, 0% on the SDRAM path).

