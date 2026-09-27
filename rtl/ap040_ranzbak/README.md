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
* Multiply and divide are ap040-pipelined's (`ap040_pipe_muldiv.v`,
  `ap040_execute.v`): the word multiply is a 16x16 product in EX's own
  clock; a long multiply's product is registered in its first clock (two
  in EX); a divide is 32 restoring steps, four a clock, after a check of
  the high dividend word for overflow (ten in EX). Upstream's unit took
  four clocks for every multiply and about twenty for a divide.
  `tests/ap040/ranzbak_ref/` keeps upstream's EX and unit, which
  `tb_ap040_rz_muldiv.v` runs beside these.
* FPU effective addresses, to the FSM core's (`ap040-40mhz`) behaviour:
  memory-indirect operands are sequenced in every FP form (EA-fetch
  reads the pointer in P_START, before P_FPU; upstream decoded them to
  the format-$4 frame); a packed store into Dn is the vector-55 datatype
  fault; an opclass 011 store never takes the FPSP route on a rejected
  EA, nor does a packed Dn source; and a PC-relative FMOVE destination
  is the F-line instead of a store. A store's enabled arithmetic
  exception is delivered post-instruction (format $3, the destination's
  EA or 0 for Dn): an integer store's SNAN/OPERR writes nothing, every
  other store writes its default result first; upstream completed the
  store and dropped the trap. `t_fpu.s` tests 298-306 and 666-717.
* Interrupts, from `t_fpu.s`'s IRQ sweep across a released FDIV (EA-fetch):
  an armed request now holds the instruction at P_START -- no micro-op, no
  MOVEM start -- until it is taken in front of it, the shape the trace
  hold already had; upstream held only the phase entries and the reads,
  and a run of one-clock instructions kept EX/WB busy so the request
  starved until the next serialising instruction. It is not armed while a
  CM continuation is pending and no instruction is present, so the resumed
  MOVEM still runs first (`t_movem_restart.s` case 7). And the unit's
  background events -- a released operation's `done`, its enabled
  exception, a restored frame's re-arm -- are taken in every clock: they
  sat in the non-flush branch, and a `done` landing on an exception
  entry's redirect clock was dropped, leaving the next FP instruction
  waiting for ever. `tests/ap040/tb_cpu_wrapper_chip_bridge.v` now has the
  program benches' IPL injector ($F110/$F148/$F160) and upstream's
  boundary-latency rule, so the sweep runs on the production bench.
* FP0-FP7 in an MLAB register file (`compat/ap040_fpu.v`): the FSM core's
  `ap040_fp_regfile` -- two flow-through read views, one write port held a
  clock in front of the RAM, an 8-bit validity mask in place of resetting
  the 640 data bits -- brought over unchanged. Upstream kept the registers
  as flip-flop arrays with three 80-bit read muxes; the fit was at 98 % of
  the ALMs and missing setup on chipset paths by 0.02-0.11 ns. The arrays
  remain as simulation mirrors. Cycle-identical on every FPU program.
* FPIAR: a rejected FP source effective address (An, a double or packed
  Dn) records it before its F-line, as WinUAE's 68040 does (`regs.fpiar =
  pc` ahead of the operand fetch); upstream wrote FPIAR only with a command
  to the unit. The conditionals -- FScc, FDBcc, FTRAPcc, FBcc -- leave it
  alone, as do a rejected store destination, FNOP, FMOVEM, the
  control-register moves and FSAVE. This diverges from the FSM core, which
  has FScc/FDBcc/FTRAPcc write FPIAR: the 68040 cputest corpus fails every
  such round on it ("FPIAR expected ffffffff"), and WinUAE's fpuop_scc /
  fpuop_dbcc never touch FPIAR, fpuop_trapcc / fpuop_bcc only on a 68060.
  `t_fpu.s` tests 718-730.
* A T0 change-of-flow trace is taken at the target's boundary whatever the
  target is: an ILLEGAL or F-line there executes after the trace handler
  returns. Upstream's `tr_yield` dropped a T0-only trace when the target
  raised its own exception (an old reading of the FSM core's
  `flow_t0_pend`, which the FSM core has since dropped); the cputest
  corpus branches every T0 round into its terminating ILLEGAL and records
  vector 9 -- 700 FBcc/FDBcc rounds failed "expected 9 got 4". `t_fpu.s`
  tests 742-750.
* FScc into memory (`ap040_decode.v`, `ap040_ea_fetch.v`): decode carried
  the EA as source AND destination, so EA-calc computed the destination
  from the source's stepped register -- MOVE (An)+,(An)+ -- and the byte
  went to An+1 with An stepped twice; and the generic store-beat counter
  overrode FScc's own `fp_k <= 3`, so the byte went out three more times.
  Both upstream's; found by cputest Basic/FScc. `t_fpu.s` tests 731-736.
* FMOVEM with an empty register list, static or dynamic, load or store,
  transfers nothing and leaves An alone (WinUAE's fmovem2fpp/fmovem2mem
  with list 0). Upstream walked one register: `mv_bit()` of a zero mask
  names one, and decode gives a dynamic list one register's step. Found
  by cputest Basic/FPP. `t_fpu.s` tests 737-741.
* A packed store with a dynamic k-factor (format 111) is twelve bytes like
  the static one, so its (An)+ step across the datatype fault is 12, as
  the static form's and the FSM core's; `fp_bytes(111)` is FMOVECR's zero
  and upstream fell to the size rule, four. (WinUAE leaves An unchanged
  on that fault; both cores step, as `t_fpu.s` test 329 requires -- the
  040 FPSP writes the packed result through the frame's EA and never
  adjusts An, so the hardware must.)

The `FAST_CLOCK` timing exceptions in Minimig.sdc were written for the
sequential core and are not validated for this one; this build uses the
default `FAST_CLOCK=0`.

## Simulation

Verilator, with vasm/vbcc for the programs:

```sh
python3 tests/ap040/run_ranzbak.py --bench boot --work <dir>
python3 tests/ap040/run_ranzbak.py --bench chip --work <dir> --param DBR_MODE=1 --program t_integer,dhry
python3 tests/ap040/run_ranzbak.py --bench chip --work <dir> --param DBR_MODE=1 --param CACHE_ALLOW_ALL=1 --require-overlap --program t_integer,dhry
python3 tests/ap040/run_ranzbak.py --bench muldiv --work <dir>
python3 tests/ap040/run_ranzbak.py --bench compat --work <dir>
```

The compat bench is upstream's `tb_ap040_pipe_compat.v` on the core behind
its reference-compatible wrapper, with upstream's interrupt, instruction-read
and MMU programs (`tests/ap040/asm/*_pipe.s`) beside this tree's. It has the
cycle-exact IPL injector and the boundary-latency rule ("qualified request
not taken at the next boundary"), and it is the bench that reproduces the
two interrupt defects `t_fpu.s`'s IRQ sweep found; the chip bench samples
IPL on the wrapper's stage grid and does not reach them. Its default program
set is `DEFAULT_PROGRAMS["compat"]` in the runner; `t_atcprobe`,
`t_exceptions`, `t_mmu` and `t_posted_irq_audit` need bench features it does
not model and run on the chip bench.

The muldiv bench runs EX with this multiply/divide beside upstream's, the
same MUL/DIV micro-ops through both (every form over edge operands,
quotients on each overflow boundary, random), and requires identical WB
records and forwards; it also checks the new stage's clocks per form.

The boot bench uses production `amiga_clk`, `minimig_m68k_bridge` and CIA-A,
over four clock phases and two arbitration modes. The chip bench runs
through the production bridge with simulated chipset arbitration, checks
each program's result, asserts that a stalled bus transfer holds still,
and counts core progress while posted writes wait for the bus.
`CACHE_ALLOW_ALL` is a simulation-only override that lets low-RAM test code
hit the instruction cache.

The cputest replay bench for this core is `tests/ap040/tb_dat_replay_pipe.v`
(`tests/ap040/tb_dat_replay.v` transformed: the FSM's S_EXC0 / S_EXC_JMP keys
become the exception entry's latch clock and its final micro-op's WB
commit -- the clock SR and the stack pointer change; freezing a round on
the dispatch clock two earlier read the frame through the user SP):

```sh
python3 tests/ap040/run_cputest.py /path/to/data_040_fpu.zip --full --jobs 12 --work <dir>
```

`--core fsm` runs the FSM bench against `rtl/ap040` for the oracle. On the
68040 FPU dataset of 2026-09-26 (1520 slices) this core matches the FSM
core round for round on every slice, with these WinUAE expectations still
unmet by both (Basic/Default FPP, and FBcc for the FSM core only):
opmodes $78-$7F stack the PC after the extension word in their vector-4
frame; FMOVE.B/W/L FPn,<ea> integer overflow is a non-maskable OPERR
(vector 52) on the 68040; FMOVEM.L <ea>,<no control register> is a no-op;
fmove.p FPn,(An)+'s datatype fault leaves An unchanged (see above); and
the FSM core misses BSUN on FBcc's non-aware predicates and writes FPIAR
on FScc/FDBcc/FTRAPcc, which this core has right. The MOVE16/MMUOP030
records' FPCR/FPSR/FPIAR mismatches are the bench not re-injecting FP
state for integer records.

Simulation and static timing are not a hardware boot test.
