# AP040 MC68040 Implementation Plan

This plan defines a Verilog MC68040-compatible CPU implementation for this
tree, located under `rtl/ap040`.  The first integration target is the existing
Minimig CPU wrapper interface used by TG68K, not a cycle-accurate replica of
the physical MC68040 pin bus at the top level.

## 1. Current Integration Contract

The current high-performance CPU path is `rtl/cpu_wrapper.v` instantiating
`TG68KdotC_Kernel` directly.  The wrapper exposes a narrow, 68k-like CPU
contract to the rest of Minimig:

- Clock/reset:
  - `clk`
  - active-low CPU reset input currently named `reset` at the kernel instance
  - `reset_out`/`nresetout` for RESET instruction side effects
- CPU progress:
  - `clkena_in` is the only retire/advance enable
  - `cpu_clkena_in` is asserted by the wrapper on idle, selected-bus ready,
    cache hit, PMMU fault, walker timeout, or reset
- External memory bus shape:
  - `addr_out[31:0]`
  - `data_in[15:0]`
  - `data_write[15:0]`
  - `nWr`, `nUDS`, `nLDS`
  - `busstate[1:0]`: `00` fetch, `01` idle, `10` data read, `11` data write
  - `longword`
  - `FC[2:0]`
- Memory targets in `cpu_wrapper.v`:
  - legacy chip/Gary bus: 16-bit data, `chip_addr[23:1]`, `chip_as`,
    `chip_uds`, `chip_lds`, `chip_rw`, `chip_dtack`
  - SDR/DDR/RTG RAM path: 16-bit data, `ramaddr[28:1]`, `ramuds`, `ramlds`,
    `ramready`
  - fastchip path: 16-bit data, `fastchip_selack`, `fastchip_ready`
- Existing 68030 PMMU/cache sideband:
  - logical/physical address outputs: `pmmu_addr_log`, `pmmu_addr_phys`
  - cache inhibit attribute: `pmmu_cache_inhibit`
  - walker request channel: `pmmu_walker_req`, `pmmu_walker_we`,
    `pmmu_walker_addr`, `pmmu_walker_wdat`, `pmmu_walker_ack`,
    `pmmu_walker_data`, `pmmu_walker_berr`
  - cache control/fill: `cache_req`, `cache_addr`, `cache_data`,
    `cache_ack`, `cache_burst`, `cache_burst_len`, `cache_ramaddr`,
    `cache_hit`, `cache_miss`

AP040 must either drive that same contract or provide a small compatibility
adapter that does.  The first implementation should use the adapter approach
so the internal AP040 core can have a clean 32-bit request/response memory
interface while the adapter performs existing 16-bit Minimig bus sequencing.

## 2. Scope and Compatibility Target

Build a synthesizable Verilog MC68040-compatible core with parameters for:

- `AP040_HAS_MMU = 1`
- `AP040_HAS_FPU = 0/1`
- `AP040_ENABLE_CACHE = 0/1`
- `AP040_FAST_SIM = 0/1`

The practical bring-up target should be LC040-class first:

- full 68040 integer unit behavior
- 040 MMU and 040 exception model
- no hardware FPU initially
- F-line/unimplemented floating-point handling compatible with the selected
  LC040/040 mode

Full MC68040 mode comes after LC040 boots reliably and adds the 040 FPU/FPSP
exception behavior.

## 3. Directory Layout

Create the implementation under `rtl/ap040`:

- `ap040.qip`
  - Quartus include file for all AP040 RTL.
- `ap040_defs.svh`
  - common enums, sizes, exception numbers, transfer modifiers, frame formats.
- `ap040_tg68k_compat.v`
  - top-level adapter with a TG68K-like port list for `cpu_wrapper.v`.
- `ap040_core.v`
  - CPU core top: front end, decode, execute, memory units, exceptions.
- `ap040_regfile.v`
  - D0-D7, A0-A7/USP/ISP/MSP, PC, SR/CCR, supervisor control registers.
- `ap040_decode.v`
  - instruction decode and legality classification.
- `ap040_ea.v`
  - 68020+ effective-address calculation, including memory indirect modes.
- `ap040_alu.v`
  - integer ALU, shifter, bitfield, BCD, CAS/CAS2/TAS support.
- `ap040_muldiv.v`
  - signed/unsigned 32-bit multiply/divide and 64-bit forms.
- `ap040_sequencer.v`
  - micro-op issue/commit, exception priority, restart control.
- `ap040_frontend.v`
  - PC sequencing, prefetch, branch redirect, instruction fault deferral.
- `ap040_mem_unit.v`
  - internal 32-bit memory request builder for byte/word/long/line/MOVE16.
- `ap040_bus16_adapter.v`
  - converts internal 32-bit AP040 transfers to the current 16-bit bus contract.
- `ap040_mmu.v`
  - split instruction/data MMU top.
- `ap040_ttr.v`
  - ITT0/ITT1/DTT0/DTT1 matching and attribute generation.
- `ap040_atc.v`
  - 64-entry, four-way I/D ATCs.
- `ap040_tablewalk.v`
  - 040 three-level descriptor walk, indirect descriptors, history-bit updates.
- `ap040_cache_ctrl.v`
  - CACR, CINV, CPUSH, cache mode selection, serialization.
- `ap040_icache.v`
  - 4 KiB physical instruction cache.
- `ap040_dcache.v`
  - 4 KiB physical data cache with valid/dirty longword state.
- `ap040_writeback.v`
  - pending writeback queue used by copyback/cache-push/access-error frames.
- `ap040_exception.v`
  - exception priority, stack-frame creation, RTE validation/unwind.
- `ap040_access_error.v`
  - format $7 access-error frame fields, SSW, writeback slots, RTE restart.
- `ap040_fpu_stub.v`
  - LC040/early bring-up F-line behavior.
- `ap040_fpu.v`
  - later full MC68040 FPU implementation or integration wrapper.
- `ap040_debug.v`
  - stable debug/status vector for SignalTap and testbenches.

Create tests under `tests/ap040` rather than mixing 040-specific expectations
into `tests/tg68k_030`.

## 4. Top-Level AP040 Interface

`ap040_tg68k_compat.v` should present a TG68K-compatible port set to
`cpu_wrapper.v`:

```verilog
module ap040_tg68k_compat (
    input         clk,
    input         nreset,
    input         clkena_in,
    input  [15:0] data_in,
    input  [2:0]  ipl,
    input         ipl_autovector,
    input         berr,

    output [31:0] addr_out,
    output [15:0] data_write,
    output        nwr,
    output        nuds,
    output        nlds,
    output [1:0]  busstate,
    output        longword,
    output        nresetout,
    output [2:0]  fc,

    output [31:0] mmu_addr_log,
    output [31:0] mmu_addr_phys,
    output        mmu_cache_inhibit,

    output        walker_req,
    output        walker_we,
    output [31:0] walker_addr,
    output [31:0] walker_wdat,
    input         walker_ack,
    input  [31:0] walker_data,
    input         walker_berr,

    output        cache_req,
    output [31:0] cache_addr,
    input  [15:0] cache_data,
    input         cache_ack,
    output        cache_burst,
    output [2:0]  cache_burst_len,
    output [28:1] cache_ramaddr,

    output [31:0] cacr_out,
    output [31:0] vbr_out,
    output        debug_busy,
    output        debug_fault,
    output        debug_halted,
    output [255:0] debug_status
);
```

Internally, AP040 should not be limited to this port shape.  The core should use
a 32-bit internal memory transaction:

```verilog
typedef struct packed {
    logic        valid;
    logic        write;
    logic        instr;
    logic        locked;
    logic        lock_end;
    logic        serialized;
    logic        move16;
    logic        line;
    logic [1:0]  size;       // byte, word, long, line
    logic [31:0] log_addr;
    logic [31:0] phys_addr;
    logic [31:0] wdata;
    logic [3:0]  byte_en;
    logic [2:0]  fc;
    logic [1:0]  tt;
    logic [2:0]  tm;
    logic [1:0]  cache_mode;
} ap040_mem_req_t;
```

The adapter then maps this to the existing 16-bit `data_in/data_write` and
`nUDS/nLDS` bus.  This is essential because a real MC68040 has a 32-bit
synchronous bus, while the current Minimig fabric is mostly 16-bit.

## 5. CPU Wrapper Integration

Add AP040 as a third CPU path in `rtl/cpu_wrapper.v`:

- keep the existing fx68k path for 68000-class operation
- keep the existing TG68K path for 68030 mode
- add AP040 behind a new select, preferably `cpucfg == 2'b11`

The wrapper mux should select these AP040 outputs:

- `cpu_addr`
- `cpu_dout`
- `cpustate`
- `wr`
- `uds_in`
- `lds_in`
- `reset_out`
- `vbr`
- `cacr`
- `pmmu_addr_phys`
- `pmmu_cache_inhibit`
- walker and cache signals

Do not initially remove the current TG68K 68030 path.  AP040 needs to be a
parallel path until it can boot the same ROMs and pass 040-specific regression
tests.

## 6. Execution Model

The implementation should be restartable and precise first, fast second.

Initial microarchitecture:

- single-issue integer core
- 32-bit internal datapath
- decoupled prefetch/front-end FIFO
- effective-address stage
- execute stage
- memory stage
- writeback/commit stage
- precise exception boundary at commit

This does not need to model the exact six-stage 040 pipeline cycle-for-cycle.
It must model architectural side effects, exception priority, restart behavior,
and bus-visible ordering well enough for AmigaOS, NetBSD, and self-tests.

Minimum integer instruction set for bring-up:

- all 68000 integer/base instructions
- 68010: VBR, SFC/DFC, MOVEC, MOVES, BKPT, RTD where applicable
- 68020/030/040 common: 32-bit addressing modes, full extension words,
  bitfields, CHK2/CMP2, CAS/CAS2, PACK/UNPK, TRAPcc, 32-bit MUL/DIV,
  LINK.L, EXTB.L
- 040-specific or 040-relevant: MOVE16, CINV, CPUSH, 040 MOVEC register set,
  PFLUSH/PTEST semantics

Illegal/reserved opcodes must be classified early.  Undefined 030 PMMU
instructions that are not valid on 040 must generate the correct F-line or
illegal behavior for the selected CPU mode.

## 7. Register and Control Model

Implement the MC68040 supervisor register set:

- `SFC`, `DFC`
- `VBR`
- `CACR`
- `URP`, `SRP`
- `TC`/`TCR`
- `DTT0`, `DTT1`
- `ITT0`, `ITT1`
- `MMUSR`
- `USP`, `ISP`, `MSP`

Important 040 differences from the current 030 work:

- root pointers are 32-bit `URP` and `SRP`, not 68030 CRP/SRP descriptor pairs
- transparent translation registers are split by instruction/data
- valid RTE stack formats are different: MC68040 uses `$0`, `$1`, `$2`, `$3`,
  `$7`; LC040/EC040 variants also use `$4`
- 68030 bus-fault formats `$9`, `$A`, `$B` are not valid MC68040 frames

The MOVEC decoder should be table-driven and independently tested so control
register aliasing errors cannot corrupt MMU state.

## 8. Memory, Bus, and Alignment

The AP040 internal memory unit should create aligned 32-bit transfers and let
`ap040_bus16_adapter.v` split them into the existing 16-bit cycles:

- byte access: one 16-bit bus cycle with one strobe active
- word access: one 16-bit bus cycle, or two cycles if odd and noncacheable
- long access: two 16-bit bus cycles, or three/four for noncacheable misaligned
  cases
- line access: four longwords, eight 16-bit cycles through the current fabric
- MOVE16: four longword reads and four longword writes, with restart metadata
- cache push: one longword or one line, with access-error metadata

The adapter must guarantee:

- no write reaches memory before translation, protection, and cache mode are
  resolved
- stale ready pulses cannot complete a different transfer
- instruction-prefetch faults are held/deferred and discarded on branch redirect
  when the prefetched word is not consumed
- locked transfers remain indivisible at the core/adapter boundary
- table-search writes for history bits cannot be interleaved with CPU writes

The current wrapper has already accumulated fixes for stale SDRAM ready,
walker ownership, and translated physical routing.  Reuse those lessons, but
do not embed new 040 semantics in ad hoc wrapper gates.  The AP040 adapter
should emit a single, stable bus request at a time and consume exactly one
qualified completion.

## 9. MMU Plan

Implement the 040 MMU as two parallel instances:

- instruction MMU
- data MMU

Each MMU contains:

- two transparent translation registers
- 64-entry four-way ATC
- 4 KiB or 8 KiB page support
- supervisor/user root selection through `SRP`/`URP`
- write-protect, supervisor-only, global, user attribute, modified, resident,
  and cache-mode attributes
- MMUSR result generation for PTEST

Table walk requirements:

- three-level table structure
- optional indirect descriptors
- invalid/nonresident descriptor handling
- bus error during table search handling
- automatic history-bit maintenance
- locked read-modify-write behavior for descriptor updates
- table-search accesses marked distinctly from normal data/instruction accesses

Do not try to reuse `TG68K_PMMU_030.vhd` directly.  Its tests and some walker
arbitration concepts are useful, but the 040 register model, descriptors,
exception frames, instruction/data split, and restart model are different
enough that reuse would hide correctness bugs.

## 10. Cache Plan

Bring-up should proceed in three cache levels:

1. Cache-disabled correctness
   - CACR exists
   - CINV/CPUSH decode correctly
   - all accesses go to memory
   - page cache-mode bits still affect serialization/cache-inhibit output

2. Write-through instruction/data caches
   - 4 KiB instruction cache
   - 4 KiB data cache
   - 64 sets, four ways, 16-byte lines
   - physical tags
   - line fill support through the existing 16-bit external fabric
   - instruction cache invalidation for self-modifying code

3. Copyback data cache
   - per-longword dirty bits
   - replacement push buffer
   - CPUSH line/page/all
   - access-error frame writeback slots for failed pushes
   - snoop model stubbed or fully implemented depending on MiSTer DMA needs

For DE10-Nano, copyback is a correctness trap.  Do not enable copyback by
default until format `$7` access-error frames and writeback completion are
proven in simulation.

## 11. Exception and Restart Plan

Implement exception handling early, before MMU/caches are feature-complete.

Required frame formats:

- format `$0`: four-word normal frame
- format `$1`: throwaway frame
- format `$2`: six-word frame
- format `$3`: floating-point post-instruction frame for full 040 mode
- format `$4`: LC040/EC040 unimplemented floating-point frame when selected
- format `$7`: access-error frame, 30 words

Access-error handling is the main correctness risk.  The frame must capture:

- stacked SR and PC
- vector offset
- effective address when continuation bits require it
- SSW fields: continuation flags, misaligned access, ATC fault, locked transfer,
  read/write, size, transfer type, transfer modifier
- fault address
- up to three writeback status/address/data slots
- push data for cache push faults

Restart rules to enforce:

- data access faults abort the current instruction and restart from the correct
  instruction context after RTE
- instruction prefetch faults are deferred until the prefetched word is consumed
- discarded branch-path prefetch faults must not generate access-error frames
- MOVEM continuation must use the effective address saved in the format `$7`
  frame when required
- RTE from format `$7` must pop exactly 30 words and process continuation bits
- a fault during access-error/address-error/reset exception stacking or RTE
  frame restoration halts the CPU as a double bus fault

This project should explicitly avoid repeating the existing 030 restart bug
class: do not use a single "restart all PMMU faults" path for both data faults
and instruction prefetch faults.

## 12. FPU Strategy

Use staged FPU support:

1. `AP040_HAS_FPU=0`
   - LC040-compatible mode
   - F-line handling and format `$4` behavior where applicable
   - enough to boot integer-only systems and OS configurations that install
     software floating-point support

2. FPSP-compatible trap behavior
   - generate the stack frames expected by 040 floating-point emulation packages
   - validate FPIAR/FPCR/FPSR visibility before implementing arithmetic

3. Hardware FPU subset
   - single/double add, sub, mul, div, sqrt, compare, move/convert
   - unsupported data types/instructions trap into FPSP-compatible handlers

Full MC68040 mode should not be advertised until the FPU exception model is
validated.  A fast LC040 is more useful than a partial 040 that mis-stacks FPU
traps.

## 13. Verification Plan

Create `tests/ap040` with small, deterministic tests first:

- reset vector fetch and initial SR/PC/stack state
- bus adapter byte/word/long/misaligned transfer sequencing
- all valid stack frame formats and RTE pop lengths
- invalid RTE format exception
- user/supervisor stack switching with M-bit and throwaway frames
- MOVEC register read/write matrix
- CINV/CPUSH decode and privilege checks
- MOVE16 alignment and restart behavior
- instruction prefetch fault deferral and branch discard
- data page fault restart for read, write, RMW, MOVEM, and MOVE16
- translated exception stacking with supervisor stack page walks
- table-search bus error
- descriptor history-bit update
- PTEST/MMUSR status cases
- PFLUSH global/nonglobal and I/D ATC selection
- cache disabled, write-through, and copyback variants

Then add differential and system-level tests:

- run generated cputest-style integer instruction corpus against a reference
  emulator
- compare architectural state after each instruction, not cycle counts
- port the existing `tests/tg68k_030` MMU scenarios to 040 expected frames
- run DiagROM and Kickstart boot traces with MMU off
- run AmigaOS with 040.library/MMU disabled
- run AmigaOS with 040 MMU enabled
- run NetBSD or another demand-paged OS only after translated exception stacking
  and format `$7` RTE are passing

Every failing board build must have a corresponding simulation reproducer
before large RTL changes are made.

## 14. Timing and FPGA Constraints

The DE10-Nano target makes timing a first-order design constraint:

- avoid a monolithic decode/EA/ALU/regfile combinational path
- register memory request outputs before they enter `cpu_wrapper.v`
- keep the external bus adapter one-hot or simple encoded state
- keep ATC lookup combinational only if timing closes; otherwise pipeline it and
  stall the core
- use inferred/block RAM for caches and ATCs where practical
- keep debug/SignalTap vectors registered
- do not add fanout from the regfile write-enable path into debug or MMU logic

Acceptance criteria for each milestone:

- clean Verilator or simulator compile
- targeted tests pass
- no uncontrolled latches
- Quartus compile still meets timing at the configured CPU clock
- worst negative slack is treated as a functional risk, not a build nuisance

## 15. Bring-Up Milestones

### Milestone A: Skeleton and wrapper selection

- add `rtl/ap040/ap040.qip`
- add `ap040_tg68k_compat.v` stub
- instantiate AP040 in `cpu_wrapper.v` under `cpucfg == 2'b11`
- hold AP040 in reset or idle by default
- prove existing 68000/68030 paths are unchanged

Exit gate: current TG68K tests and existing build still pass.

### Milestone B: Reset and bus smoke test

- implement reset exception vector fetch
- fetch first instruction word
- implement NOP, BRA, MOVEQ, MOVE.L immediate/register basics
- implement 16-bit adapter reads/writes

Exit gate: tiny ROM program reaches a known memory write in simulation.

### Milestone C: Integer ISA baseline

- implement enough integer instructions to run existing basic cputest corpus
- implement full SR/CCR behavior
- implement exceptions `$0/$1/$2`
- implement interrupts/autovectors

Exit gate: 68020/030 integer corpus passes with MMU/cache/FPU disabled.

### Milestone D: 040 control registers and cache maintenance decode

- implement MOVEC 040 register map
- implement CACR, CINV, CPUSH as no-op maintenance operations while caches are
  disabled
- implement PFLUSH/PTEST decode path
- illegal/privilege behavior is correct

Exit gate: MOVEC/CINV/CPUSH/PTEST/PFLUSH tests pass.

### Milestone E: 040 MMU, no cache

- implement TTRs
- implement I/D ATCs
- implement table walker and descriptor history updates
- implement PTEST/MMUSR
- implement PFLUSH variants
- implement data and instruction access faults

Exit gate: translated data faults, instruction faults, table-search faults,
and translated exception stacking pass.

### Milestone F: Format `$7` access-error restart

- implement full format `$7` stack generation
- implement RTE format `$7` restore
- implement MOVEM continuation and writeback slots
- implement branch-discarded prefetch fault suppression

Exit gate: NetBSD-style handler can fix a PTE, execute PFLUSH, RTE unchanged,
and resume all tested fault shapes.

### Milestone G: Caches

- implement I-cache and write-through D-cache
- implement line fills through the 16-bit adapter
- implement CINV
- implement copyback D-cache and CPUSH
- implement push/access-error writeback fields

Exit gate: cache-on boot is stable and copyback-specific fault tests pass.

### Milestone H: LC040/040 FPU behavior

- implement LC040 unimplemented FPU trap path
- implement FPSP-compatible stack behavior
- optionally implement hardware FPU subset

Exit gate: 040.library/FPSP tests pass, and the CPU can run with the selected
FPU mode without mis-stacking exceptions.

### Milestone I: DE10-Nano validation

- add SignalTap status vector for AP040 state, PC, SR, bus request, MMU fault,
  access-error frame state, ATC miss/walk state, cache push state
- compile with AP040 selected
- confirm reset, Kickstart, DiagROM, AmigaOS, MMU enable, and NetBSD milestones

Exit gate: reproducible boot with timing closed and no untriaged sim/hardware
divergence.

## 16. Non-Goals for the First Pass

- cycle-accurate MC68040 external pin timing
- physical 32-bit data bus exposed directly to the existing Minimig memory
  system
- multiprocessing bus snoop intervention unless required by MiSTer DMA behavior
- exact six-stage pipeline timing
- full hardware FPU before LC040-class MMU/cache correctness
- replacing TG68K before AP040 is independently proven

## 17. Main Risks

- Format `$7` access-error frames are easy to make superficially plausible and
  still wrong.  Treat them as a central design item.
- Instruction prefetch faults must be deferred/discarded correctly.  A unified
  "restart every fault" mechanism will break branch and page-boundary cases.
- Copyback cache makes bus-error recovery much harder because dirty push state
  becomes architectural.
- The current external fabric is 16-bit.  A careless 32-bit adapter can create
  duplicate peripheral reads/writes or stale-ready completions.
- Timing closure will fail if ATC lookup, cache tag compare, bus request
  generation, and regfile writeback are allowed to become one combinational
  path.

## 18. Recommended First Patch Set

The first AP040 patch should contain only:

- `rtl/ap040/ap040.qip`
- `rtl/ap040/ap040_defs.svh`
- `rtl/ap040/ap040_tg68k_compat.v`
- `rtl/ap040/ap040_core.v` as a reset/idle skeleton
- a `cpu_wrapper.v` optional instantiation guarded so existing modes are
  unchanged
- one `tests/ap040/tb_ap040_reset.v` smoke test

Do not start by porting the existing 030 MMU.  Start with a clean AP040 shell,
prove the wrapper boundary, and then add architectural features behind tests.

## 19. Performance Program: Pipelining, Multi-Issue (added 2026-08-09)

Requested: pipelining + superscalar/multi-issue.  This section stages it so
each step keeps the cputest-proven semantics testable.  The current core is a
sequential multi-cycle FSM; every stage below is a re-architecture step, not
a bolt-on, and the ordering is chosen by measured ROI per unit of risk.

### P0. Prerequisites (gating everything)

- The chip-RAM ghost-transaction fix (ram_cs_guard) verified on hardware with
  a timing-clean fit.  No pipeline work while the memory fabric is unproven:
  every new failure would be unattributable.
- The tree committed.  All performance work happens behind fresh commits.
- RESURRECT THE CPUTEST DAT-REPLAY SIM HARNESS (shelved 2026-08-02, resume
  notes in the session memory file).  Photographed gurus are not a viable
  regression loop for pipeline hazards; replaying the full cputest datasets
  against the verilated/iverilog core in CI is the only way a pipelined core
  keeps 040 semantics.  This is the single most important item in the section.

### P1. Enable the internal I/D caches (biggest real-world win, least risk)

AP040_ENABLE_CACHE is 0 in the Minimig build; ap040_cache.v exists and the
Minimig fabric relies on cpu_cache_new in the RAM controllers instead.  An
on-die cache removes the ~10-30 cycle external round trip per access, which
dominates real software far more than CPI does.  Work: enable, size to fit
M10K budget, wire CINV/CPUSH (already decoded), snoop/inhibit correctly
(chip RAM + MMIO must stay uncached via TTR/MMU CM bits and the existing
cache_inhibit plumbing), then full regression + cputest replay.  Expected
gain: large on fast-RAM working sets; zero architectural risk to exception
semantics.

### P2. Single-clock-domain migration (28MHz -> clk_114 + 4:1 clock enable)

Move cpu_wrapper + core onto clk_114 with a ce, multicycle-4 constraints on
ce-qualified paths.  No speed change yet; eliminates the entire CDC/phase
contract class (cyc kill, ph1/ph2 catching, level-ack consumption) that
produced the ghost-transaction bug.  After P2, sim and silicon see identical
cycle relationships, which P3+ depend on for debuggability.

### P3. Overlapped sequencer (in-FSM pipelining, ~1.5-2x CPI on reg ops)

The core already has three semi-independent engines: prefetch queue, EA/
memory unit, exec/writeback.  Decouple them so instruction N+1 fetch/decode/
EA-calc overlaps instruction N execute/WB, with a small scoreboard for
register and CCR hazards.  Keep the restart exception model: an instruction
still commits atomically at WB, faults still restart it, format $7 semantics
unchanged.  This is the last stage that preserves the current verification
story mostly intact.

### P4. True pipelined IU (040-style six stage)

IF / ID / EA-calc / EA-fetch / EX / WB with a store buffer.  At this point
the format $7 writeback slots (WB1-WB3) become REAL microarchitecture (they
exist on silicon because the 040 pipelines stores), interrupt/trace sampling
points move, and precise-exception logic replaces the restart shortcut in
places.  Months of work; only viable with the dat-replay harness as a nightly
gate.  Frequency step to ce=2:1 (56.75MHz) belongs here, after the known
>17.6ns cones (exc_addr capture, MMU translate->fault, F_ROUND) are split.

### P5. Superscalar / dual issue

This is 68060-class microarchitecture (pOEP/sOEP pairing rules, dual EA
ports or issue restrictions, register scoreboarding across two lanes) -- the
real 68040 is single-issue, so P5 makes the core behave like a faster-than-
040 hybrid.  Ship it as an optional turbo mode: cputest is generated for a
68040 model, so a dual-issue core must still present 040-visible semantics
(instruction boundaries for traces/interrupts, serialization on CCR-visible
pairs).  Pairing legality tables come from the 68060 UM; the win on in-order
68k code is typically ~1.3-1.6x CPI, i.e. LESS than P1 or the P4 clock step.
Do it last.

### Expected cumulative effect (rough, workload-dependent)

- P1 caches: 1.5-3x on fast-RAM code (chip-bus code unchanged)
- P3 overlap: 1.3-1.8x CPI on top
- P4 + 56MHz: up to ~2x more on compute kernels
- P5 dual issue: ~1.3-1.5x on top, compute-bound only
Chip-RAM-bound code (most OCS-era software) is paced by the 7MHz bus slots
and gains almost nothing from any of this; the wins are for fast-RAM
system/FPU/RTG workloads.

## 20. FPU Acceleration (added 2026-08-15)

Measured shape of the problem (fitted numbers, 28.7 MHz effective, fully
blocking): FABS/FNEG/FTST/FCMP 4-7 cycles, FADD/FSUB 8-14, FMUL ~39,
FDIV ~74, FSQRT ~73; 6581 ALUTs, 1799 registers, zero DSP blocks.

### F0. Arithmetic cores (DONE 2026-08-15, bit-exact by construction)

- F_MULT: the 32-cycle serial radix-4 loop replaced by ONE registered
  64x64 DSP-tree product (`mul_pd <= a_m * b_m`; 34.8 ns budget closes a
  Cyclone V cascade comfortably).  F_MULT is now 2 states: ~39 -> ~8
  cycles total, and the serial accumulator ALUTs become DSP blocks.
  A separate single/FSGL fast path (once proposed) is REDUNDANT: the full
  multiplier already serves every format at the same latency.
- F_DIVL: 2 restoring bits/cycle (two cascaded 65-bit compare-subtracts);
  integer bit + 33 pair-iterations: ~74 -> ~41 cycles.
- F_SQRTL: 2 result digits/cycle (second trial folds the first digit into
  the partial root combinationally): ~73 -> ~40 cycles.
- Follow-up headroom: 3 bits/cycle divide (66 = 3x22) and sqrt cut ~10
  more cycles each if the subtract cascade still meets timing; measure
  first, the returns are shrinking.

### F1. Non-blocking S_FPU_GO (DONE 2026-08-15)

Implemented as designed below: ap040_fpu exports `accepted` (state past
every unimp/unsupp decision, including the late F_EXEC/F_BIN destination
checks); S_FPU_GO releases register-destination arithmetic and the core
continues; a one-deep scoreboard gates S_FPU_DEC, the FPSR-reading
predicates (S_FBCC/S_FSCC0), FSAVE/FRESTORE and S_EXC0; enabled
arithmetic exceptions from a released op deliver pre-instruction at the
next FPU dispatch (FPSP model).  t_fpu 285-289 cover overlap and
deferred-trap delivery; 68/71 gained their architecturally required
FNOPs.  Full suite green; 365-slice FPU corpus identical to baseline.
Design notes kept for reference:

Let the core continue fetching/executing integer instructions while the
FPU computes, stalling only on the next FPU instruction, an FPU register
consumer (FMOVE/FMOVEM read), or FSAVE/exception boundaries.  This is what
the real 68040 does; its architecture is already visible here in the
E-bit/pending-exception frame machinery.  Requirements:
- a one-deep FPU scoreboard (busy + destination register + pending
  exception state);
- exception model care: an FPU exception raised after completion must
  stack the format-$0/$2/$3 frames with the ORIGINAL FPU PC (FPIAR path
  already holds it) -- cputest's E11/E55 corpora are the regression;
- FNOP and FSAVE become synchronization points (both already decode).
Prerequisite: the cputest dat-replay harness from P0 (section 19), since
interrupt/trace interactions with a busy FPU are exactly the corner
photographed gurus cannot regress.

### F2. Wide operand path

Extended operands are three 32-bit reads = six 16-bit bus transactions
before execution.  Options, cheapest first: (a) let the FPU operand
fetch use the walker-style 32-bit port to the RAM controllers for
non-chip addresses; (b) a 64-bit burst port shared with a future P1
cache line fill.  Saves ~10-20 cycles per memory-operand FPU op on
fast RAM; nothing for chip RAM (7 MHz bus is the floor there).

### F3. FPU at 57/114 MHz

Run the FPU FSM on clk_114 with a 4:1 enable handshake to the core.
Multiplies the F0 iteration savings by up to 4 for div/sqrt, but crosses
the ce-gated clocking contract (section 14) and re-opens CDC review for
fpu_req/fpu_done/exception strobes.  Only worth it after F1: while the
core blocks, wall-clock per op is what matters and F0 already cut the
long poles 2-5x.

Ordering: F0 (done) -> F1 -> F2 -> F3, with P1 caches (section 19)
interleaved by ROI: for mixed real-world FPU code the caches likely beat
everything except F1.
