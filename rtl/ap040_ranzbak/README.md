# Ranzbak AP68040-pipelined for MiSTer

Vendored from https://github.com/ranzbak/AP68040-pipelined at
`9efe490d1a56f6db36cee82186a6f0ab314dd0c5`, on branch
`ap040-ranzbak-muldiv`, whose platform base is the card branch
`ap040-40mhz` at `b6afbda0`. `upstream.json` records the SHA-256 of every
imported file as upstream has it; the upstream license is in `LICENSE`.

The integration below was first made, uncommitted, in the `ap040-ranzbak`
worktree (platform base `dbccaa6f`). The platform files it changes --
`files.qip`, `rtl/cpu_wrapper.v` and the two bridge benches -- are
byte-identical on `b6afbda0`, so it applies here unchanged.

## Integration

`files.qip` selects `ap040_ranzbak.qip` instead of the sequential AP040 QIP:
this branch builds ranzbak's core in place of the FSM core, not beside it
(several module names are shared). The package compiles before the other
sources, all as SystemVerilog. The production `rtl/bram.vhd` supplies the
Intel RAM primitive; upstream's simulation DPRAM model is not imported.

The CPU runs on `clk_sys` (nominal 28.375160 MHz), with the existing 16-bit
memory bus, the physical MMU table-walk channel, DMA snoops and the RAM
controllers' caches. Its MMU, FPU, 4 KB I-cache and 4 KB D-cache, posted
writes and separate instruction/data read lookup paths are enabled. The
optional 128-bit line-fill channel is disabled, its inputs tied off: this
platform does not connect it.

Local RTL changes to upstream:

* Quartus 17 syntax: `wire some_type_t name = expression` split into a typed
  declaration and a continuous assignment; the pipeline record member
  `last` renamed `final_uop`. Mechanical.
* `compat/ap040_pipe_tg68k_compat.v`: a `bus_clkena_in` input drives the
  16-bit adapter; `clkena_in` (the core, MMU and cache) is the core tick,
  their own handshakes stalling them during memory waits. The upstream
  arrangement gated all of it with the bus-qualified enable, which put the
  RAM acknowledge on the pipeline's enable network and failed timing in
  the first full fit. The adapter clears its acknowledge on the next idle
  tick, so the pipeline consumes each acknowledge once. Both enables share
  the tick grid. `post_drain` exposes the cache's `post_busy`.
* `rtl/cpu_wrapper.v` instantiates that wrapper and ties the unused
  interfaces off.
* The multiply/divide unit and EX's use of it follow ap040-pipelined's
  (their own commit).

The `FAST_CLOCK` timing exceptions in Minimig.sdc were written for the
sequential core and are not validated for this one; this build uses the
default `FAST_CLOCK=0`.

## Simulation

Verilator, with vasm/vbcc for the programs:

```sh
python3 tests/ap040/run_ranzbak.py --bench boot --work <dir>
python3 tests/ap040/run_ranzbak.py --bench chip --work <dir> --param DBR_MODE=1 --program t_integer,dhry
python3 tests/ap040/run_ranzbak.py --bench chip --work <dir> --param DBR_MODE=1 --param CACHE_ALLOW_ALL=1 --require-overlap --program t_integer,dhry
```

The boot bench uses production `amiga_clk`, `minimig_m68k_bridge` and CIA-A,
over four clock phases and two arbitration modes. The chip bench runs
through the production bridge with simulated chipset arbitration, checks
each program's result, asserts that a stalled bus transfer holds still,
and counts core progress while posted writes wait for the bus.
`CACHE_ALLOW_ALL` is a simulation-only override that lets low-RAM test code
hit the instruction cache.

Simulation and static timing are not a hardware boot test.
