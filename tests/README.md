# Minimig-AGA MiSTer — Test Suite

This directory holds the verification infrastructure for the 68030 CPU/PMMU work
in `rtl/tg68k/`. The only thing here right now is the ModelSim regression suite
under [tg68k_030/](tg68k_030/) — the old AmigaOS-side detection workaround
programs (`test_exception_numbers.c`, `improved_mmu_detect.c`, `mmu_funcs.asm`,
`MMU_DETECTION_ISSUE.md`) have been removed; their functionality is now covered
by the simulation testbenches and by booting a real Kickstart in-sim.

## Layout

- [tg68k_030/](tg68k_030/) — VHDL testbenches + Makefile driving ModelSim (Intel
  FPGA Standard Edition 17.0, `vsim`/`vcom`/`vlib`). 114 testbenches, 127+ make
  targets. Helper Python scripts build cputest memory images and audit
  divider/divexact corner cases.

## Running tests

All commands run from [tests/tg68k_030/](tests/tg68k_030/):

```sh
make help                 # list every target with one-line descriptions
make test-regression      # MC68030 regression suite (recommended smoke test)
make test-mmu-instruction-suite  # PMOVE/PFLUSH/PTEST/PLOAD + addressing modes
make test-fault           # MMU/bus/address fault frames + RTE recovery
make test-arch-suite      # RTE/ABCD/CHK/MOVES/MOVEC/CPSAVE architectural cover
make test-lockup-all      # Walker timeout, bus conflict, cache fill, ATC race
```

ModelSim path is hard-coded to `/opt/intelFPGA_lite/17.0/modelsim_ase` in the
Makefile — edit `MODELSIM_PATH` if your install lives elsewhere.

## Coverage areas

The testbenches in [tg68k_030/](tg68k_030/) are grouped roughly as:

| Area | Representative targets |
|------|------------------------|
| PMMU registers & encoding | `test-pmmu-reg`, `test-pmove-tc`, `test-pmove-all-modes`, `test-pmove-multiple-regs`, `test-pmove-pc-all-regs` |
| Page table walker / ATC | `test-pmmu-walker`, `test-pmmu-atc`, `test-pmmu-early-term-remap`, `test-indirect-descriptor` |
| MMU instructions | `test-pflush-all-modes`, `test-ptest-all-modes`, `test-pload-all-modes`, `test-mmu-instruction-suite` |
| Fault frames / RTE | `test-mmu-fetch-fault-frame`, `test-mmu-user-data-fault-recovery`, `test-berr-frame`, `test-addr-error-pmmu`, `test-rte-formats` |
| Trace exceptions | `test-group2-t0-trace`, `test-group2-t1-trace`, `test-chk-stacked-trace`, `test-trace-post-rte-user` |
| MOVEC / MOVES / CACR | `test-movec-cacr`, `test-movec-illegal`, `test-moves-validation`, `test-cacr` |
| BCD / CHK / branch corner cases | `test-abcd`, `test-abcd-mbit`, `test-chk-long-odd-addr`, `test-branch-odd-addr` |
| Cputest replay | `test-basic-cputest`, `test-basic-cputest-exact`, `test-basic-chk2-cputest-entry`, `test-basic-jmp-cputest-entry` |
| Lockup / race | `test-lockup-walker-timeout`, `test-lockup-bus-conflict`, `test-lockup-cache-fill`, `test-lockup-atc-handshake`, `test-lockup-mem-ack-race` |
| ROM / library boot | `test-amiga-sequence`, `test-mmu-library-detect`, `test-68030-library`, `test-whichamiga`, `test-diagrom` |

## Current PMMU-regression status (as of 2026-05-12)

Four previously-failing PMMU tests are tracked as the headline regression set:

| Test | Status |
|------|--------|
| `test-pmmu-atc` | passing (7 sub-tests, 0 errors) |
| `test-pmove-tt0-read` | passing (PMOVE TT0,Dx reads, 0 errors) |
| `test-pmove-multiple-regs` | passing (TT0/TT1/TC distinct readback, 0 errors) |
| `test-mmu-user-data-fault-recovery` | passing on the most recent re-run; intermittent failure observed earlier in the day showing `df=$4E714E71` in the diag dump (handler reaching the marker write but not the subsequent BSET/MOVE.L). Re-run if it flakes. |

The headline cputest CHK.L / CHK2.L failure (supervisor-mode lockup with
`A7=USP-6`) is still reproducible locally via
[`tb_trace_post_rte_user.vhd`](tg68k_030/tb_trace_post_rte_user.vhd) TEST 4
(CHK.L + ILLEGAL with T0=1). The RTL fix in the Group 1 + T0 trace stack path
is still pending — a speculative SVmode-update relocation was tried and reverted
because it did not help.

## Conventions

- Testbenches are pure VHDL with no Unicode/emoji and no "simplified" mock
  variants — they instantiate the real `TG68KdotC_Kernel`, `TG68K_PMMU_030`,
  and (where relevant) `cpu_wrapper`.
- Each Makefile target either depends on `setup` (full library compile) or
  `compile` (incremental). `setup` is the safe default after pulling new RTL.
- ModelSim work directories (`work*/`, `transcript`, `vsim.wlf`,
  `mc68030_regression_results.log`) are scratch and may be deleted between
  runs; they regenerate automatically.

## Reporting failures

When a testbench fails, attach:

1. The `make test-...` invocation and its full stdout (the `## Error:` / `## Note: DIAG:` lines are usually decisive).
2. The branch / SHA being tested (`git rev-parse --short HEAD`).
3. Any RTL changes still in your working tree (`git status -s rtl/tg68k`).
4. The testbench source if you modified it locally.
