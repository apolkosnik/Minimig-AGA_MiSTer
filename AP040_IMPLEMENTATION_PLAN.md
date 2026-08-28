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

STATUS 2026-08-18 (third state, ENABLED -- supersedes the 2026-08-16
revert note that stood here).  AP040_ENABLE_CACHE(1) ships
(cpu_wrapper.v), timing-clean, with the external cpu_cache_new
instances ALSO keeping their storage (CPU_CACHE 1) -- the two are
complementary, not alternatives: the internal cache eats the external
round trip, the controller caches eat the SDRAM latency behind it.
Both reasons for the 08-16 revert were fixed, not argued away:

  * snoop loss while clkena frozen (the CDC objection): the cache's
    snoop port is free-running and ce-independent (audit 5.1-5.3
    fixes), covered by tb_ap040_cache_snoop T1 exactly in the
    frozen-clkena window;
  * "measured SLOWER on hardware": true only for straight-line
    miss-heavy code, which is what the regression programs are.  On
    loop code (bench_loop.s under +prof) the internal cache is 1.41x
    faster on a zero-latency bus, 2.27x on a latent one, and makes the
    CPU nearly immune to bus latency.

The timing blocker found on the way matters more than the parameter:
ap040_cache forwarded c_req to c_ack combinationally through pass_active
in C_IDLE, putting the whole MMU/adapter handshake in one clk_28 cycle;
clk_28 collapsed to -4.988 the moment the cache was enabled.  Fixed by
registering the pass (pass_active = C_PASS only).  The paragraphs below
describe the enable experiment and are kept for the area measurements,
which remain valid.

Getting there was an area problem, and the measurements are worth
keeping because two of the three obvious moves were wrong:

  halve cpu_cache_new           frees BLOCK RAM, which was never the
                                constraint (31% used), and almost no
                                ALMs -- the storage was already M10K and
                                the tag comparators widen as the index
                                shrinks.  Reverted.
  valid/LRU into the tag row,   made the design BIGGER, 98% -> 104%.
  inferred array                A second write port written as its own
                                always block does not match Quartus's
                                dual-port template: ctag stopped
                                inferring and became ~6300 flops.
  valid/LRU into the tag row,   worked.  Instantiate the project's
  rtl/bram.vhd dpram            true-dual-port wrapper (the one
                                cpu_cache_new already uses) instead of
                                relying on inference.

Final fit, all clocks met:

  no internal cache, external caches on   39,508 ALMs (94%)  +0.281 ns
  internal cache only, block-RAM tags     38,899 ALMs (93%)  +0.118 ns

So the internal cache now costs 609 ALMs LESS than the external caches
it replaced, against the +1,759 it cost before this work.

Correction to an earlier version of this section: ap040_cache DOES have
a snoop port now (s_stb/s_addr), and the cacheable windows include chip
RAM because of it (ap040_tg68k_compat.v wires sdram_ctrl's chipset-write
snoop through cpu_wrapper).  That is the machinery whose CDC drops
events while clkena is frozen -- one of the two reasons for the revert
above, and one of the audited latent bugs.

### P2. Single-clock-domain migration (28MHz -> clk_114 + 4:1 clock enable)

Move cpu_wrapper + core onto clk_114 with a ce, multicycle-4 constraints on
ce-qualified paths.  No speed change yet; eliminates the entire CDC/phase
contract class (cyc kill, ph1/ph2 catching, level-ack consumption) that
produced the ghost-transaction bug.  After P2, sim and silicon see identical
cycle relationships, which P3+ depend on for debuggability.

### P2 SCOPED against the code (2026-08-24), and it is the critical path

X2.2b stage 2 was costed and deferred behind P2 (see X2.2b above): the cheap
route it wanted -- multiplexing a second lookup onto spare ce phases -- needs
spare ce phases, and today `ce` is cpu_wrapper's stall enable, not a 4:1
divider.  P2 is what creates them.  Note the ordering that follows, because
it is easy to get backwards: AREA does not gate P2.  Area gates the
DUPLICATION route for stage 2, and P2 removes the need for that route
entirely, so P2 comes first and the area question may never need answering.

What P2 actually touches, read rather than assumed:

  * Minimig.sv: cpu_wrapper is instantiated with .clk(clk_sys) (line ~348).
    That becomes clk_114 plus a 4:1 enable.  cpu_ph1/cpu_ph2 are ALREADY
    generated on clk_114, so they stop being a crossing and become plain
    same-domain signals.
  * cpu_wrapper.v: clkena_in = ~cpu_req | bus_complete | bus_berr gains the
    4:1 term.  The harder part is the chip stage machine, which is
    `always @(negedge clk, negedge reset)` and samples ph1n/ph2n registered
    off the opposite edge -- a negedge machine at 4:1 on a 114MHz clock is
    not the same shape, and this is the piece to design rather than port.
  * ram_cs_guard exists ONLY for the level-ack consumption contract across
    the phase relationship (read its header: the TG68K-era `cyc` marker
    guessed the consumption edge from the PLL phase and starved the CPU at
    half the alignments).  After P2 that contract is same-domain and the
    module should be re-derived or deleted, not carried over.
  * Minimig.sdc:36-37 is the clk_sys -> clk_114 multicycle 2/1 exception.
    It goes away for the CPU paths, replaced by multicycle 4 on the
    ce-qualified paths inside clk_114.  Minimig.sdc:4-5 (cpu_inst -> ram)
    wants re-deriving against the new relationship at the same time.
  * tests: tb_cpu_wrapper_chip's CPU_PHASE parameter sweeps the four PLL
    edge alignments.  After P2 there is one alignment, so the sweep
    collapses -- which is the point, and is the cleanest confirmation that
    the CDC contract class is gone.

The payoff is not speed.  It is that the entire phase-contract class
disappears: cyc kill, ph1/ph2 catching, level-ack consumption.  That class
has cost more debugging time in this campaign than any other single thing --
ram_cs_guard's own header documents a serve/kill loop that missed every
sample edge at half the alignments -- and after P2 sim and silicon see
identical cycle relationships, which P3+ need to be debuggable at all.

### P2: the chip-bus timing contract, MEASURED 2026-08-26

The one piece of P2 that needs designing rather than porting is the chip
stage machine: it is `always @(negedge clk, negedge reset)` testing ph1n/ph2n,
which are registered off the opposite edge, and it does not keep its shape at
4:1 on a 114MHz clock -- `if (ph1n)` would fire for four consecutive cycles
instead of one.  So the contract it keeps today was measured rather than
inferred, by logging clk_114 cycle numbers in tb_cpu_wrapper_chip:

    div:      0    3    4    6    8    b    c    e
    clk_sys   ^         ^         ^         ^          (posedge at div[1:0]=0)
    ph2            ^         .                         (rise div=3, act div=6)
    ph1                                 ^         .    (rise div=b, act div=e)

  ph1 and ph2 each rise exactly ONE clk_114 cycle before a clk_sys posedge.
  That posedge samples them into ph1n/ph2n.  The negedge machine then acts
  TWO clk_114 cycles later still -- at div=e for ph1, div=6 for ph2.

  Both act phases are therefore `div[1:0] == 2'b10`, i.e. the CPU clock
  enable delayed by two clk_114 cycles.

That gives an exact transformation, with no new timing relationship invented:

  * cpu_wrapper takes clk = clk_114 plus `ce`, true 1 cycle in 4 at the
    phase where clk_sys posedges today (div[1:0] == 0; Minimig.sv already
    computes exactly this as `cyc`).
  * clkena_in becomes `ce & (~cpu_req | bus_complete | bus_berr)` -- the
    existing stall term, gated by the enable.
  * ph1n/ph2n register on `ce`, which is what "posedge clk_sys" meant.
  * the stage machine moves from `negedge clk` to `posedge clk_114`
    qualified by `ce` delayed two cycles, still testing ph1n/ph2n.  Do NOT
    keep it on a negedge: at 114MHz that is a 4.4ns half-cycle path.

  Everything else in the module is already posedge-clk and becomes
  ce-qualified in the ordinary way.

Then the cleanup P2 exists for: ram_cs_guard's entire reason to exist is the
cross-phase level-ack contract (its header documents a serve/kill loop that
missed every sample edge at half the PLL alignments), and after this it is
same-domain and should be re-derived or deleted rather than carried over.
Minimig.sdc:36-37's clk_sys -> clk_114 exception is replaced by multicycle 4
on the ce-qualified paths, and Minimig.sdc:4-5 re-derived against the new
relationship.

Verification available without hardware: tb_cpu_wrapper_chip runs the whole
directed suite over the 7MHz chip path, tb_sdram_turbo and tb_dualram_turbo
cover the RAM side, and all three sweep CPU_PHASE today.  After P2 there is
one alignment, so the sweep collapsing is itself the evidence the contract
class is gone.  The final gate is still a NetBSD boot: this is the seam where
a half-cycle error desynchronises the chip bus and nothing boots at all.

### X2.7 AREA: measured 2026-08-24, and it is the CORE, not the periphery

From the last fit, ALMs needed by hierarchy:

    sys_top                          38238   (91% of 41910)
      emu                            30982
        cpu_wrapper                  21349
          ap040_tg68k_compat         21179
            ap040_core               19997   <- 52% of the whole design
              ap040_fpu               5336
              ap040_alu               1536
            ap040_mmu                  736
        minimig (the whole chipset)   4809
      ascal                           2107

  So the core's own FSM/decode -- 19997 less the FPU and ALU -- is about
  13100 ALMs, 34% of the entire design, and the whole Amiga chipset is less
  than a quarter of it.  Any area program is a CORE program; trimming the
  periphery cannot reach it.

  Where it plausibly goes: 57 DISTINCT Add instances are referenced inside
  ap040_core in the fit report's timing nodes alone (plus 24 Selector, 13
  Mux).  A 68k needs a handful of adders; 57 is one inferred per use site
  across the big case, never shared because the operands come from
  different registers in mutually exclusive states.  Sharing them is not
  free -- one adder means a wide operand mux -- so the honest first step is
  to group by operand class (address+displacement, PC+n, stack adjust) and
  cost ONE group before touching the rest.

  Not scheduled: P2 first.  If stage 2 becomes a multiplexing change, the
  area budget is not on the critical path at all.

### Where the cycles actually go (measured 2026-08-16)

Profiling every cycle of t_integer by core state (scratch instrumentation
on tb_ap040_program, `dut.core.state` histogram with a stall column):

    S_FETCH        8798  (1680 stalled)   39.6%
    S_IMMF         6959  ( 904 stalled)   31.3%
    S_MRD          1779  ( 365 stalled)    8.0%
    S_DECODE        904                    4.1%
    S_EXEC + PIPE  2360                   10.6%

The machine is FETCH-bound, not execute-bound: 71% of cycles fetch
instruction and immediate words, and only 2584 of those 15757 are memory
stalls -- the rest is one request/ack handshake per 16-bit word.  Worth
keeping in mind when weighing execute-side work: the barrel shifter and
DSP multiply/divide, real as they are, address the ~15% slice.

Taken since, on that same benchmark (23750 -> 20106 cycles, -15.3%):

  2-cycle cache hit          23750 -> 22214   one data RAM per way, so
                                              the tag compare picks among
                                              words already read
  longword instruction fetch 22214 -> 20586   aligned fetches take both
                                              words, odd one buffered in
                                              the existing epf queue
  1-cycle prefetched immed.  20586 -> 20106   consume a queued word in
                                              the cycle S_IMMF would have
                                              spent issuing

What remains in S_FETCH is the cache's own two-cycle hit latency, which
no peephole reaches: the fetch has to be ISSUED while the previous
instruction still executes.  That is P3 below.  The concrete obstacle is
that the core has a single memory request port shared with data
accesses, so a speculative fetch must arbitrate against S_MRD/S_MWR and
must not fault -- restricting prefetch to the current page makes the
fault question go away, the same argument that makes the aligned
longword fetch safe.

### Re-measured 2026-08-20, after the caches and the fetch queue landed

The fetch-bound picture above is the PRE-queue machine.  With the fetch
queue and the internal caches shipping, t_integer redistributes but does
not get much cheaper, and the reason matters for what to build next:

    S_FETCH       6019  (1239 stalled)  34.0%
    S_IMMF        3006  ( 598 stalled)  17.0%
    S_MRD         2539  ( 547 stalled)  14.4%
    S_MWR         1257  ( 284 stalled)   7.1%
    S_DECODE       994  (  76 stalled)   5.6%
    S_EXEC         700  (  93 stalled)   4.0%
    S_PIPE_*      1911  ( 178 stalled)  10.8%

  17686 cycles total, 3098 of them stalled on the bus -- 17.5%.
  So 82.5% of all cycles are the FSM walking states with memory
  ALREADY ANSWERED.  The machine is no longer fetch-bound in the
  memory sense; it is sequencer-bound.

Per-instruction cost, measured directly with the $F108 cycle-stamp port
(tests/ap040/hw/fptime.s and the cpi/hit/width probes), caches enabled:

    nop                       5.7 cycles     real 68040: ~1
    addq.l #1,Dn              7.2            real 68040: ~1
    add.l Dn,Dn               8.1            real 68040: ~1
    move.l Dn,Dn              8.1            real 68040: ~1
    move.l (An),Dn  (cached) 17.6            real 68040: ~1-2
    move.l Dn,(An)           20.1            real 68040: ~1 (copyback)
    longword vs word access    +3            real 68040: 0

  FPU, same method: FMOVE.X 9.1, FMUL.X 11.1, FADD.X 13.0,
  FSQRT.X 15.8, FDIV.X 33.0.  The FPU is within 2-3x of silicon; the
  integer core is 7-8x.  That asymmetry is why the performance program
  is an INTEGER program.

  Measurement gotcha, learned the hard way: the 68040 comes out of reset
  with both caches DISABLED until software writes CACR.  A probe that
  does not set CACR ($8000_8000: DE bit 31, IE bit 15) measures the
  uncached machine and will show cold and warm passes costing the same.

### What the A4000 does, and what it means here (2026-08-20)

Read against the A4000 Rev B schematics (sheets 3, 4, 7, 11, 14, 15),
because the real machine solves exactly the 32-bit/16-bit problem X2.1
and X2.2 are circling.

  * It never narrows the CPU.  Two TERMINATION protocols coexist:
    _STERM (synchronous, 32-bit, burst-capable) driven by RAMSEY for
    Fast RAM, and _DSACK1/_DSACK0 (asynchronous, with the responding
    device encoding its own port width) for ROM, IDE and Zorro.  The
    68040's dynamic bus sizing splits the transfer per device.  A
    16-bit device makes THAT access 16-bit; Fast RAM stays 32-bit.
  * Burst line fill is _CBREQ/_CBACK: four longwords, 16 bytes, one
    cache line -- and only on the fast path.  This maps 1:1 onto the
    X2.1 fill port, which is already the right shape.
  * BRIDGETTE (sheet 7) is a width/direction BRIDGE, not a narrower:
    PD(0:31) on the CPU side, CD(0:31) on the chip side, with CDIR,
    _CLATCH and separate half enables _COEH/_COEL.  A second half of
    the same part does the Zorro side (sheet 14).
  * The chip bus itself is 32 bits: chip RAM is an x32 SIMM on
    DRD(31:0).  Only the legacy chips are narrow -- Alice and Paula sit
    on DRD(15:0), while Lisa (CSG 4203) takes D0..D31.  AGA widened the
    DISPLAY FETCH and left the rest at 16.
  * The 32-bit chip bus uses four byte strobes (_UUDS/_UMDS/_LMDS/
    _LLDS) rather than issuing two 16-bit cycles.
  * Gary drives _CIIN so chipset/register space is never cached.

  Where AP040 departs, and what it costs:

    ap040_bus16_adapter narrows EVERYTHING -- its own header says
    "long: two word cycles when even".  Fast RAM included.  The X2.1
    32-bit path is read-only line fill; cpuWR and the write buffer stay
    16-bit.  Measured penalty: +3 cycles per longword access.  And
    write-through-with-invalidate means a store kills its own line, so
    the next read of it refills, where the A4000's 68040 would have
    absorbed the store in the cache.

  Consequence for the plan: the device-split above is the model to copy
  (X2.1b on the store side, below), but it is worth ~3 cycles per
  longword store against a 8-cycle register add.  It does not reorder
  the program: the sequencer is the dominant cost and X2.3 stays first.

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
- F_DIVL: 3 restoring bits/cycle (three cascaded compare-subtracts,
  66 = 3 x 22): integer bit + 22 iterations: ~74 -> ~24 cycles.  (This
  section originally recorded the 2-bit/cycle intermediate step; the
  follow-up headroom item below was taken the same day and the RTL is
  the 3-bit form.)
- F_SQRTL: 3 result digits/cycle (later trials fold the earlier digits
  into the partial root combinationally): ~73 -> ~24 cycles.
- Follow-up headroom REALIZED: the 3-per-cycle forms above met timing;
  further widening was not attempted, the returns are shrinking.

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

============================================================================
# Part X2: AP040X2 -- superscalar, 32-bit dual-SDRAM, toward 114 MHz
============================================================================

Branch: ap040x2 (worktree /home/adam/ap040/ap040x2), base 809b9558 +
the validated AP040 core and test infrastructure as of ap040@37591618.
fx68k/tg68k are removed.  This part supersedes P2-P5 above on this
branch; the ap040 branch stays the stable single-issue line.

## X2.0 Target and how it is measured

Match or beat a real 25 MHz MC68040 on sustained integer and FPU code.
The 040 at 25 MHz retires at best 1 instruction/cycle from its caches
(~18-21 host MIPS); its FPU sustains ~3.5 MFLOPS.  The bar, measured on
this fabric:

  T1  cycle-count parity: >= 25 M retired instructions/sec sustained on
      cache-resident integer code (t_integer-style mix).
  T2  memory parity: a cache-line fill in <= 8 core cycles (real 040:
      burst 4 longwords over a 32-bit bus in 4+ bus clocks).
  T3  FPU: pipelined FMUL/FADD throughput >= 1 op / 8 core cycles.

The profiling that motivates the shape (measured on AP040, t_integer):
fetch is 71% of cycles, execute ~15%.  A superscalar back end without a
transformed front end and memory path is pointless -- the order of work
below follows from that number.

  REVISED 2026-08-20, after the caches and the fetch queue shipped.
  That 71% was the pre-queue machine.  Re-measured (section 19), fetch
  is 51% and the decisive number is different: only 17.5% of cycles are
  bus stalls, so 82.5% are the FSM walking states with memory already
  answered.  Per-instruction: 8.1 cycles for add.l Dn,Dn, 17.6 for a
  CACHED longword load, 20.1 for a store, against ~1 on real silicon.
  The bar in T1 is therefore 7-8x away and the gap is SEQUENCER, not
  memory.  X2.3 moves first; the remaining width work (X2.1c) is worth
  ~3 cycles per longword access and is sized accordingly.

## X2.1 Memory: DUAL_SDRAM as a native 32-bit bus  [FIRST -- everything
     else keys on it]

The io-board slot gives a second 16-bit SDRAM.  Driven in lockstep with
the primary (same clock, same command, same address; each carries one
half of the longword) the pair is one 32-bit SDRAM: a 4-longword line is
one ACTIVE + 4-beat burst instead of the 8+2 the 16-bit path needs.

  - sdram32_ctrl: new controller instantiating the proven sdram_ctrl
    command engine once, data path doubled.  SDRAM_* carries D[15:0],
    SDRAM2_* carries D[31:16].  Same slot/refresh discipline as today.
  - sys/ already has the ports and sys_dual_sdram.tcl for the pins; the
    build gains a DUAL_SDRAM=1 qsf macro.  Boards without the second
    module fall back to the 16-bit path at half fill rate (runtime
    detectable: probe pattern on SDRAM2 at init; config error out).
  - Chipset traffic keeps its 16-bit port SHAPE, slot and cycle timing
    (proven byte/cycle-identical against sdram_ctrl in tb_sdram32) --
    but NOT "primary chip only": in a lockstep pair the even word of
    every longword lives in chip 2, so a chipset write lands in the
    lane its addr[1] selects.  The original wording was tried and is
    physically wrong (measured: CPU reads the stale half of everything
    Agnus writes).
  - Io-board reality: sys_dual_sdram.tcl routes no DQM to SDRAM2, so
    lane masking uses nCS across the WHOLE slot including ACTIVE
    (masking only the write leaves the secondary's row open against
    the primary's auto-precharge -- illegal on the next ACTIVE).
    BYTE masking within the secondary lane (corrected 2026-08-16):
    the SDRAM modules short DQMH/DQML to A12/A11 -- the same
    convention sdram_ctrl already serves with its
    sd_addr[12:11] <= cas_dqm write-CAS mirror -- so the secondary's
    byte masks travel on sd2_addr[12:11], which diverges from the
    lockstep copy for exactly the write-CAS hold window (sd2_a_dqm in
    sdram32_ctrl).  The sd2_dqm output is a phantom on this board.
    Before this fix every secondary-lane 16-bit write reached the
    chip with A12/A11 = 2'b11 and was dropped whole; tb_sdram32 now
    models the module short (dqm from addr[12:11]) and is wired into
    run_tests.sh.  Caveat: a secondary module with REAL (unshorted)
    DQM routing would need read-modify-write instead; the plan
    assumes the standard shorted modules.
  - CDC: none new.  The controller stays on clk_114; the CPU-side
    handshake is unchanged in protocol, doubled in width.

Deliverable gate MET (44572b32): lockstep command identity checked
every cycle, chipset port byte/cycle-identical against sdram_ctrl on
shared stimulus, and all three deliberate breaks (lane swap, lockstep
break, primary-only chipset writes) caught with thousands of errors.
Measured: slot grant -> 4th beat = 15 clk_114 = 4 core cycles at ce=4
(T2 gate is <= 8 core cycles; met with margin).  The 16-bit fallback
measures 31 for the same line.  Note 15 clk_114 is the FLOOR for this
command engine (tRCD 2 + CL 4 + 3 beats*2 + capture 3) -- a raw
"8 clk_114" reading of the gate is physically impossible and was a
spec error, not a shortfall.

### X2.1c Store side: byte lanes on the 32-bit bus  [added 2026-08-20]

X2.1/X2.1b widened READS only: the fill port is a 32-bit read-only line
fill, while cpuWR and the write buffer stay 16-bit, so a longword store
is still two lane-masked slots.  The A4000 shows the alternative it
should have been all along (see the schematic reading in section 19):
the real machine puts FOUR BYTE STROBES on a 32-bit bus rather than
issuing two narrower cycles, and reserves narrow transfers for the
devices that are actually narrow.

  - extend sdram32_ctrl's write path to accept a 32-bit datum with four
    byte enables, the direct analogue of _UUDS/_UMDS/_LMDS/_LLDS
  - route CPU stores to fast RAM through it; keep ap040_bus16_adapter
    for chip RAM, chipset and IO, which is BRIDGETTE's split
  - the adapter stays the fallback for DUAL_SDRAM=0 builds

  Gate: longword store cost drops by the measured 3-cycle split penalty
  with no change to chipset timing (the 16-bit chipset contract is the
  one thing X2.1 must never disturb -- byte/cycle identity against
  sdram_ctrl on shared stimulus, as X2.1 already proves).

  Honest sizing: 3 cycles against a 20-cycle store and an 8-cycle
  register add.  Worth doing, not worth doing FIRST.  X2.3 is first.

## X2.2 Fetch front end: decouple and widen  [the 71%]

  - 32-bit fetch through the new bus; fetch QUEUE (4 longwords) filled
    autonomously whenever the bus is idle, drained by decode.  The
    existing epf machinery is the seed of this queue; it becomes
    free-running instead of exception-only.
  - Prefetch never crosses a page (reuses the aligned-fetch fault
    argument); flow change flushes the queue (mechanism exists).
  - Gate: S_FETCH+S_IMMF occupancy on t_integer drops below 20% (from
    71%) with the suite and corpus untouched.

MEASURED 2026-08-17 (tb_ap040_program +prof, the tb_prof X2.8 asks
for; t_integer phase 0): the free-running queue lands 17236 cycles,
down from 20106 after the peephole round and 23750 at the section-19
baseline (-27% cumulative), suite and corpus untouched.  Occupancy is
51% (8865/17236; was 66% by the same metric), of which only 1799
cycles are bus-wait stalls -- BUT the 20% gate as written is
structurally unreachable by any queue: decode folds into S_FETCH's pop
cycle (S_DECODE holds only 976 cycles), so one S_FETCH cycle per
instruction plus one S_IMMF cycle per immediate word are irreducible
in the multi-cycle FSM, and those actives alone are ~41% of the total.
Like X2.1's "8 clk_114" reading, the number was a spec error: fetch
occupancy below 20% requires fetch to OVERLAP execute, which is
X2.3's definition.  X2.2's gate is re-scoped to what it measures:
wall clock (met: -14% from the queue alone) and fetch-state bus-wait
stalls (met: 1799, from 2584 on a 27% larger total); the <20%
occupancy line moves to X2.3's exit criteria.

### X2.2b DECOUPLE THE PORTS -- design, grounded 2026-08-20

Motivated by measurement, not principle: +memlat shows 44% of
S_MRD/S_MWR cycles (56-57% with a latent bus) pass with an instruction
fetch outstanding, and the data access itself is only 2 cycles once it
gets the port.  Roughly 3 of the 7.6 cycles a cached load spends in
S_MRD are waiting for a fill it has nothing to do with.  A real 68040
runs the two independently; we serialize them on one request port.

What the code actually allows, checked rather than assumed:

  * MMU: `assign c_ack = m_ack` -- it is a TRANSLATION stage, not a
    latency stage.  An ATC or TTR hit rewrites the address
    combinationally and forwards; the acknowledge comes from the cache.
    So a second requester needs a second ATC lookup path and a second
    TTR compare (combinational, cheap), NOT a second MMU.
  * Cache: single c_req/c_ack with c_instr selecting the bank via
    a_row = {c_instr, a_set}.  The two banks are already separate
    storage; what is shared is the REQUEST PATH and the tag RAM ports
    (A = lookup, B = invalidate).  A second concurrent lookup needs a
    third tag port -- so either duplicated tag storage per bank (area,
    and X2.7 says the budget is tight) or lookups time-multiplexed on
    alternate ce phases.  The core runs at ce=4, so the cache has spare
    cycles; multiplexing is the cheaper bet and should be costed first.
  * Core: one mem_req/m_issued pair, and S_MRD's own `!m_issued &&
    epf_pend` arm is the stall being measured.

Staged so each stage is gateable on its own:

  1. Split the core's port BOOKKEEPING into an instruction channel and a
     data channel (separate issue/pending/ack tracking) while still
     serializing at the MMU.  No speedup yet -- the gate is that nothing
     changes: suite, corpus and all three differentials identical, and
     +memlat's port-wait percentage UNMOVED.  This is the risky part
     (fault attribution, restart, lk_cyc, epf_pend) done with no
     performance variable in play.
  2. Let a data HIT proceed while an instruction fill is in flight.
     This is where the win lands, because data reads hit 767 times out
     of 770.  Gate: port-wait percentage falls, cached load moves toward
     ~12 cycles, everything else unchanged.
  3. Full concurrency with bus arbitration for two misses.  Smaller
     incremental win; only worth it if stage 2 leaves measurable wait.

### X2.2b stage 1 SHIPPED (2026-08-24): channel-qualified acknowledge

The port already tags its transaction: mem_instr says which channel owns it,
and aerr_start builds the fault frame from it.  What was NOT explicit was the
ACKNOWLEDGE.  A data state reaches its ack branch only when m_issued, and
m_issued can only be set while !epf_pend, so an acknowledge was attributed by
CONSTRUCTION -- and that construction is exactly the serialization stage 2
removes.  Left alone, the change that adds concurrency would also be the
change that first makes an ack ambiguous.

So the qualification lands first, while the stall still guarantees the
answer: d_ack/i_ack/d_err/i_err, and all 14 consumers routed to their own
channel -- the four transfer states and the store-into-queue-window flush to
the data channel, the queue forward, the fill engine's ack and fault, and the
architectural four-longword exception prefetch to the instruction channel.
Three uses stay port-level and become the arbiter's business in stage 2: the
two "is the port free?" tests and the shared request deassert.

Gate, as specified -- nothing changes:
  * directed suite: all 51 leg logs BIT-IDENTICAL to the pre-change
    baseline, cycle counts included.  Timing identity, not just pass/fail.
  * v24 corpus AE: 38/38, RTE/RTR odd-PC address errors included.
  * v24 corpus ODD_EXC: exactly 13 failures, the documented generator
    artifacts -- the instruction-channel fault path is untouched.

Stage 2 (a data HIT proceeds while an instruction fill is in flight) is now
a change to the ISSUE rule alone; the acknowledge side is already correct.

### EARLY RESTART: two of three blockers fixed, the third is MMU concurrency

Chased this properly.  Early restart -- ack the core when ITS longword lands,
finish the line behind it -- is the largest cheap win left (fills are 85% of
fetch latency, fetch is 57.9% of all cycles, and sequential fetch enters a
line at beat 0, so the common miss would cost one beat instead of four).
Three things blocked it.  Two are now fixed and LANDED, because both were
latent bugs that early restart merely exposed:

  1. m_instr and m_fc were driven from the LIVE c_instr/c_fc.  Safe only
     while the core could not issue during a fill; released early, a new
     request swings busstate between FETCH and READ inside one adapter
     transaction and changes the function code under it.  Now registered at
     acceptance (r_instr/r_fc).

  2. tag_ridx was the LIVE a_row, so C_TAGW composed the fill's tag
     writeback from whatever row the CORE was addressing.  With the core
     blocked those were always the same row and it worked by accident;
     released early, the fill's tag is written into a DIFFERENT set's row
     image -- corrupting that set and validating a line never filled.  This
     was the wild-address failure (t_integer to 22222220).  tag_ridx is now
     pinned to r_row while a fill is in flight; the row DATA still comes
     live, which is what the snoop/sweep hazard actually required.

  3. NOT FIXED: releasing the core mid-fill lets the MMU start a table walk
     concurrently with the fill.  The bench's walker/CPU exclusivity
     assertion fires on this, and that assertion IS stricter than hardware
     (sdram_ctrl has a dedicated walker port and arbitrates internally).
     But relaxing it to model the arbitration does not make the test pass:
     t_mmu then takes a real access fault during exception processing and
     double-faults (pc=146c, ir=f518, mem_flt=1).  So there is a genuine
     MMU-side interaction, not just a bench limit, and it was not chased to
     ground.

Next attempt starts at (3): find why a walk concurrent with a fill faults.
The two fixes above are already in and are worth having on their own -- (2)
especially, since it is a real corruption path that only stayed dormant
because the core happened to be blocked.

### EARLY RESTART: tried, reverted, and what it actually needs (2026-08-27)

Before the width work, tried the cheap attack on the same 31 cycles: ack the
core the moment ITS longword lands and finish the line behind it.  The cache
already captures the requested beat (fill_hold) and then waits out the
remaining three for no benefit to that access.  Sequential fetch enters a
line at beat 0, so this should turn the common fetch miss from four beats of
latency into one -- against fills being 85% of fetch latency and fetch 57.9%
of all cycles, easily the largest cheap win available.

It does not work as a local change, and the failures say why.

  * FOUND A LATENT BUG, KEPT THE FIX: the cache drove m_instr and m_fc from
    the LIVE c_instr/c_fc, which was only safe because the core could not
    issue anything while a fill ran.  Released early, a new request swings
    busstate between FETCH and READ inside one adapter transaction and
    changes the function code under it.  They are now registered at
    acceptance (r_instr/r_fc) and used while fill_active.  This is worth
    having on its own and is retained.
  * STILL FAILS AFTER THAT FIX: t_integer runs off to a wild address and
    t_mmu trips the bench's walker/CPU-bus exclusivity check.  The second is
    a bench modelling limit rather than a hardware rule -- sdram_ctrl has a
    DEDICATED walker port (walker_req/walker_we/walker_addr) separate from
    the CPU port and arbitrates internally, and the bench's single memory
    model cannot serve both -- but the first is a real defect and was not
    chased to ground.

So early restart needs, at minimum: the bench's walker model taught to
arbitrate rather than assert, and the wild-address failure understood.  It
is NOT a cache-local change; releasing the core mid-fill lets it start
traffic the rest of the system was built assuming could not exist.  Recorded
in the module at the fill loop so the next attempt starts from here rather
than rediscovering it.

Sizing is unchanged and still favours it if it can be made to work: it
attacks the same 85% the width work does, for far less integration.

### THE TWO LEVERS SIZED (2026-08-27): width 21.9%, level-ack gap 8.7%

Ran the probe the section below asks for (+qprof ADLAT line: adapter phase
occupancy).  t_integer, phase 0, 16650 cycles:

    adapter waiting for completion   5850   35.1% of ALL cycles
    adapter in subcycle_gap          1444    8.7%
    adapter busy, total              7294   43.8%

So the level-acknowledge gap is REAL but it is not the bulk: 19.8% of
adapter-busy time.  Sizing the two candidate changes against the whole
program rather than against each other:

    remove the gap (P2's level-ack cleanup)      up to  8.7%
    halve the sub-cycle count (32-bit transfers) up to 21.9%

Width wins, and by more than the ratio suggests, because halving the
sub-cycle count halves BOTH buckets -- fewer sub-cycles means proportionally
fewer gaps.  The gap removal is worth having afterwards, not instead.

CAUTION ON A NUMBER I NEARLY REPORTED: a fourth bucket, "core has mem_req
while the adapter is inactive", came out at 45.1% of all cycles and looked
like a stalled adapter.  It is not.  The adapter's mem_req comes from the
CACHE's m_req (ap040_tg68k_compat line 411, b_req), not the core's, so that
bucket is simply every cycle a request is being served INSIDE the MMU and
cache -- hits, and the cache FSM -- and never reaches the bus.  It is the
cache doing its job, not a stall.  Recorded because the mislabelled version
would have sent the next investigation at the core-to-cache path.

### WHAT THE 31-CYCLE FILL IS MADE OF (2026-08-27), and why X2.1c is misnamed

Chased the fill cost one level further, because "make it 32-bit" assumes the
cost is transfer WIDTH and it is not.

  * The 32-bit burst fill path X2.1 describes DOES NOT EXIST in this tree.
    ap040_tg68k_compat ties cache_req/cache_burst/cache_burst_len to zero,
    still marked "idle until milestone G".  Every fill goes through
    ap040_bus16_adapter as eight 16-bit sub-cycles.
  * At ZERO modelled memory latency (+prof phase 0) a 16-byte fill still
    costs 31 cycles -- about 3.9 cycles per 16-bit sub-cycle.  So the fill
    is not waiting on memory at all.
  * The adapter's own header says where the 3.9 goes: "split transfers
    insert a sampled IDLE cycle between sub-cycles.  The Minimig RAM/cache
    controllers return a level acknowledge and do not accept a new address
    until their chip-select drops."

So the fill cost is eight repetitions of (request, level-ack, mandated idle),
and the tax is the LEVEL-ACKNOWLEDGE CONTRACT, not the bus width.  Two
consequences:

  1. Widening to 32 bits halves the sub-cycle COUNT and would roughly halve
     the fill -- worth having, but it treats the symptom.  The physical
     Minimig ram port is 16 bits wide (ramdout[15:0]), so this is not a
     small change: it needs the burst/cache port that is currently tied off,
     or a widened controller interface.
  2. The per-sub-cycle idle is the same level-ack contract that
     ram_cs_guard exists to police and that P2 was going to delete.  P2 was
     shelved as infrastructure with no direct payoff; this says it has one,
     and that the two efforts are the same effort seen from opposite ends.

Recommended next measurement before either: instrument the adapter to count
cycles per sub-cycle by phase (request, ack-wait, idle).  If the idle is one
cycle of four, removing it is a 25% fill win with no width change; if the
handshake itself is the bulk, only width helps.  That is a probe, not a
build, and it decides between two large changes.

### CORRECTION: the queue starves on FILL LATENCY, not port contention

The section below concluded that the shared port starves the fetch queue and
that the unified cache's second lookup port was therefore the top priority.
That was WRONG, and a gate-attribution probe (+qprof, QBLK line) says so
directly.  Sampling only the cycles where the queue is empty AND the fill
engine is armed -- i.e. where a fill is genuinely wanted:

    want=9636   pend=9209 (95.6%)   port=91 (0.9%)   dstate=11   ea=34
                                    page=0  lk=8     other=283

In 95.6% of those cycles a fetch is ALREADY IN FLIGHT.  The engine is not
waiting for the port; it has issued and is waiting for the answer.  Port
contention accounts for 0.9%.  A second lookup port would have bought
essentially nothing here, and building it first would have been a large
change aimed at the wrong thing.

+memlat says what the wait actually is:

    ifetch  n=1274  avg 9.5  max 31
        921 at  2 cyc   (72%)  cache hits
        326 at 31 cyc   (26%)  line fills
    time:   hits 1842 cyc (15%)   FILLS 10106 cyc (85%)

The 25% miss rate is STRUCTURAL and not worth attacking: a 16-byte line is
eight words, a request takes one longword, so sequential code is necessarily
one miss and three hits per line.  The target is the 31-CYCLE FILL, which is
26% of fetches and 85% of all fetch latency.

A 16-byte fill over the 16-bit bus adapter is eight word transfers.  That
puts the next move squarely on X2.1c -- the 32-bit width work this document
has been deferring behind sequencer work -- and NOT on cache concurrency,
sequencer overlap or a deeper pipeline.  Halving the transfer count would
take fetch from 9.5 to roughly 5.8 cycles average, and fetch is 57.9% of all
cycles.

Sequence of wrong turns worth remembering, because each was cheap to test
and expensive to have built:
  1. "the EA gate starves it"      -- tested, made bench_loop 11.6% worse
  2. "the shared port starves it"  -- 0.9% of blocked cycles
  3. fill latency                  -- 85% of fetch time.  Measure first.

### THE QUEUE IS STARVING: 90% of S_FETCH runs on an EMPTY queue (2026-08-27)

Re-profiled t_integer with the unified cache in place (16650 cycles, down
from 17686 with the split cache), and the bottleneck has MOVED:

                    split cache      unified
    S_FETCH            34.0%          38.5%
    S_IMMF             17.0%          19.5%
    S_MRD              14.4%          10.0%
    S_MWR               7.1%           7.2%
    bus stalls         17.5%          16.4%

The data side got faster, so the fetch side now dominates outright:
S_FETCH + S_IMMF are 57.9% of every cycle, and only 16.4% of all cycles are
stalled on the bus at all.

The +qprof probe (fetch-queue occupancy, new in tb_ap040_program) says why:

    dry_at_fetch = 90%     -- 90% of S_FETCH cycles have epf_count == 0
    occupancy 0  = 9968    -- the queue is EMPTY for 60% of all cycles

So S_FETCH is not costing pop cycles with words available.  The queue is
STARVING.  That distinguishes the two candidate fixes decisively: this needs
fetch BANDWIDTH, not a deeper pipeline.

Tested and REVERTED, so it is not retried: removing the fill engine's
`!ea_state` gate.  It moved t_integer 16650 -> 16628 (noise) and the dry
rate 90% -> 89%, while making bench_loop 11.6% WORSE (325896 -> 363704).
The gate earns its keep exactly as its comment claims; it is not what
starves the queue.

What starves it is the SHARED PORT: the fill engine also requires
`!mem_req && !mem_ack` and `state != S_MRD/S_MWR/S_MRD_B/S_MWR_B`, so it
only fills when the core is quiet AND the port is idle.  With data accesses
and EA computation occupying much of the time, those slots are rare.

That is precisely what the unified cache's SECOND PHASE removes -- a second
lookup port serving an instruction fetch while a data access proceeds.  The
proposal's remaining phase is now the measured top priority, ahead of P3:
P3 overlaps execution with fetch, but there is nothing to overlap while the
queue is empty 60% of the time.

### UNIFIED L1 ON HARDWARE (2026-08-27): +12.9% Dhrystones, streaming flat

xsysinfo 0.9.0, same board, cd033533 against b9013c2a:

    Dhrystones     4674 -> 5277    +12.9%
    chip     5.17 -> 5.19 MB/s     +0.4%  (noise)
    fast     6.66 -> 6.64 MB/s     -0.3%  (noise)
    ROM      8.23 -> 8.26 MB/s     +0.4%  (noise)

    versus TG68K-020: 4.47x slower -> 3.96x slower

Attribution, carefully, because only one of the two predicted wins is
actually visible in these numbers:

  * STREAMING FLAT WAS PREDICTED AND CONFIRMED.  The fill path did not
    change, so bandwidth should not have moved, and it did not (0.4% either
    way is below the measurement's resolution).  Worth stating because it
    is the control: had bandwidth moved, something unintended would have.

  * THE +12.9% IS THE STORE-MERGE WIN, essentially alone.  The bypass
    retirement only ever applied below $200000 -- cache_chip is
    mm_addr[31:21] == 0 -- so code resident in FAST RAM never took the
    bypass and gains nothing from retiring it.  If xsysinfo's Dhrystone
    runs from fast RAM, which is the normal case for a Workbench tool with
    fast RAM present, then the entire 12.9% comes from stores no longer
    invalidating their set.  That is consistent with bw_probe block 8's
    -49% on a pure RMW loop diluted across Dhrystone's instruction mix.

  * THE 24-34% CHIP-WINDOW WIN IS THEREFORE STILL UNMEASURED.  It applies
    to chip-RAM-resident code -- demos, OCS-era software, anything that
    runs from the low 2MB.  Nothing in an xsysinfo run exercises it.  The
    test that would: a chip-RAM demo (Phenomena Enigma is the one whose
    breakage motivated the bypass in the first place), or a Dhrystone
    forced to load low.

So the honest position is one win confirmed at 12.9%, one control
confirmed flat, and the larger predicted win untested rather than absent.

### UNIFIED L1 BUILT AND MEASURED (2026-08-27): both predicted wins banked

ap040_ucache.v replaces ap040_cache.v behind the same interface: 128 sets x
4 ways x 16B unified -- the same 8KB and the same array shapes as the split
cache, so the storage cost is zero.  Stores that fit one aligned longword
merge into the hitting way (byte-enable writes); misaligned stores keep the
old invalidate path; snoops reach every line, so the chip-window I-fetch
bypass is retired in the same change.  All five paid-for hazard fixes are
carried forward and documented in the module header.

bw_probe, chip bench TURBO=1, clk_114 counts, against the shipped split
cache:

                          split+bypass   unified     win
    movem reads (cold)        105780      71184     -33%
    movem reads (warm)         99320      65716     -34%
    move.l x8 reads           155684     118048     -24%
    movem writes              129024      95412     -26%
    RMW one line              173124      87444     -49%
    streaming read            (n/a)      492764     unchanged vs scratch

  Blocks 1-4 land BYTE-IDENTICAL to the scratch bypass-off measurement, so
  the bypass retirement banked in full.  RMW halves: ~14 cycles per access
  against ~36 -- the store-merge path working.  Streaming is unchanged, as
  expected: the fill path did not move.

  t_cache test 3 now pins the new contract (SMC coherent without CINV, a
  deliberate deviation from real 040 silicon, argued in the module header).
  Full regression green on the first complete run, every leg.

  Still open from the proposal: the SECOND lookup port (simultaneous I+D)
  -- that is the replicated-tag phase and needs the core-side channel
  split (X2.2b stage 2's issue rule).  This change deliberately shipped
  the coherence and store-merge wins first, which needed no core changes.

### Streaming and RMW measured; UNIFIED DUAL-PORT L1 proposed (2026-08-27)

Clean numbers (code L1-cached via scratch bypass-off, clk_sys):

                                 TURBO=1     TURBO=0 (raw 7MHz bus)
    streaming read /long            20.0        54.0
    streaming write /long           15.8        42.0
    RMW one line (2R+2W) /iter     143.3       401.1
    warm re-read /long              10.7

  * The raw 7MHz bus (54 cyc/long) is NOT what hardware chip does (22):
    on the board, chip fills take the turbo/controller path.  The bench
    turbo figure (20) brackets hardware chip (22) and fast (17); precise
    attribution of the remaining 22-vs-17 needs tb_dualram_turbo (it has
    BOTH real controllers) with the $F108 stamp ported to it -- the
    difference is a controller-path property (SDRAM+cache vs DDR3, fill
    efficiency), not a core property.  Not yet done.
  * RMW is the scandal: 143 clk_sys for 2 reads + 2 writes of ONE resident
    line, ~36 cyc per access against 10.7 warm -- the whole-set store
    invalidation forces a full refill after every store.  This is the
    counters-and-linked-structures pattern ordinary code does constantly.

### PROPOSAL: unified dual-port L1 (suggested by Adam, 2026-08-27)

FPGA block RAM is true-dual-port, and RAM is the cheap resource here (250 of
553 M10K used) while ALMs are the scarce one (91%).  A unified L1 exploits
that:

  * I-fetch and data lookup SIMULTANEOUSLY: tag array replicated (standard
    FPGA trick for a third port -- both copies written identically, each
    copy serves one read port), data array likewise.  Costs block RAM and a
    second compare (modest ALMs), not a second cache.  This is X2.2b stage
    2's concurrency without the duplication problem that deferred it --
    and without P2, since it is enable-ratio-agnostic.
  * SELF-MODIFYING CODE WORKS BY CONSTRUCTION: one storage means a store
    hits the same line an I-fetch reads.  The Enigma bypass (measured cost:
    25-34% of all chip-window execution) retires without building a
    separate I-bank invalidation path.  The store-vs-queue window stays
    handled by the existing fetch-queue flush.
  * The whole-set store invalidation can die in the same redesign: with a
    second tag read port, a store can invalidate (or update) its matching
    WAY via read-modify-write instead of zeroing the row -- fixing the
    36-cyc RMW pattern above.
  * MMU: concurrent I+D lookups need two ATC/TTR compares; the ATC RAM
    replicates in block RAM like the tags, the TTR compares are
    combinational.  Same trick, same cheap resource.
  * 040 semantics: CINV IC/DC selectivity becomes over-invalidation on a
    unified cache -- correctness-safe under write-through.
  * Risk: I/D set contention.  Mitigate with more sets: doubling to 8KB
    costs only block RAM, which is 55% free.

This SUPERSEDES both "I-bank invalidation path" (previous highest-value
item) and X2.2b stage 2 as separate efforts: one redesign delivers the
measured 25-34% bypass win, the stage-2 concurrency win (~3 cyc/load), and
the RMW fix, for block RAM plus modest ALMs.  It is the successor to
ap040_cache, to be built as such -- not patched in.

### Chip-window cost DECOMPOSED (2026-08-27): the I-fetch bypass is 25-34%

Measured with a new $F108-stamped bandwidth probe (asm/bw_probe.s) on the
chip bench under TURBO_CHIP=1, which the xsysinfo figures below validate as
the hardware configuration (bench warm movem: 16.2 clk_sys per longword;
hardware fast RAM: 17.0).  Same probe with the 192d82ce chip-window I-fetch
bypass disabled in a scratch build:

                                bypass ON    bypass OFF
    movem reads (warm)           97.0         64.2  clk_sys/iter   -34%
    movem reads (cold)          103.3         69.5                 -33%
    move.l x8 reads             152.0        115.3                 -24%
    movem writes                126.0         93.2                 -26%

    warm movem per longword      16.2         10.7

So when CODE runs from the chip window, the bypass -- every instruction
fetch going to the memory port instead of the L1 I bank -- costs a quarter
to a third of ALL execution.  That is the price of the Enigma fix, now
quantified.  It does NOT explain the xsysinfo chip-vs-fast delta if
xsysinfo's code sits in fast RAM (only its data buffer is in chip); the
likely account of that 22-vs-17 is chip DATA taking the 7MHz bus rather
than the turbo path, which is an OSD cachecfg question before it is a core
question.

Consequence: the bypass was the correct emergency fix and is the wrong
permanent one.  The real fix was named in the original commit -- the I bank
has no invalidation path.  Give it one (snoop the I bank the way the D bank
already is, plus store-to-line invalidation covering the SMC case) and the
bypass can be retired, recovering 25-34% on all chip-window code: demos,
games, anything OCS-era.  That is now the highest-value single change in
the performance program, ahead of P3, because it is localized and its win
is measured rather than estimated.

### THE NUMBER THAT MATTERS: 4.5x slower than the core it replaces (2026-08-27)

First hardware measurement against the incumbent, xsysinfo 0.9.0 on the same
board, b9013c2a (65cfcf7f) versus the stock TG68K-020 core:

                        TG68K-020    AP040     ratio
    Dhrystones             20911       4674    4.47x slower
    chip   MB/s            24.21       5.17    4.7x
    fast   MB/s            19.91       6.66    3.0x
    ROM    MB/s            24.44       8.23    3.0x

Converted to cycles per longword at 28.375MHz, which is the form that maps
onto everything else in this document:

                        TG68K-020    AP040
    chip                   4.7 cyc   22.0 cyc
    fast                   5.7 cyc   17.0 cyc
    ROM                    4.6 cyc   13.8 cyc

Three things follow, and the first one is why this entry exists.

1. THE BENCH PROFILING IS VALIDATED.  17.0 cycles per fast-RAM longword
   derived from hardware bandwidth against 17.6 measured in simulation for
   move.l (An),Dn cached.  Every per-instruction figure in "Where the cycles
   actually go" can now be trusted as describing the board, not the model.

2. THE MACHINE IS SEQUENCER-BOUND, CONFIRMED FROM OUTSIDE.  Dhrystones are
   4.47x off while memory is 3.0x off, so the excess is in instruction
   execution rather than in the memory path.  That is the same conclusion the
   state histogram reached from the inside -- 82.5% of cycles walking states
   with memory already answered -- arrived at independently.  It is the
   argument for P3/X2.3 ahead of the width work in X2.1c.

3. CHIP RAM IS DISPROPORTIONATELY BAD: 22.0 cycles against fast RAM's 17.0,
   where the 020 core is FASTER on chip than on fast (4.7 vs 5.7).  Whatever
   costs the extra 5 cycles is specific to the chip window and does not
   appear in the fast path.  Candidates, in the order worth testing: the
   whole-set store invalidation, the snoop traffic chip RAM attracts that
   fast RAM does not, and the chip-window I-fetch bypass added in 192d82ce.
   None of these has been measured on the board; this is a lead, not a
   finding.

Context for expectations: the plan already put the integer core at 7-8x off
real 68040 silicon, so being 4.5x off a mature 020 core is consistent rather
than surprising.  It is recorded here because "slower than the core it
replaces" is the number a user actually experiences, and no amount of
cycle-accuracy work substitutes for closing it.

### X2.2b stage 1 CONFIRMED ON HARDWARE (2026-08-27)

The b9013c2a bitstream boots.  That carries stage 1's channel-qualified
acknowledge, so the refactor is validated on silicon and not merely
cycle-identical in simulation -- which matters, because stage 2 changes the
issue rule on top of exactly this acknowledge logic and would otherwise be
building on an unproven base.

Also confirmed by the same boot: baf20e99 (Akiko priority over the RTG
window) and 192d82ce (the chip-window I-fetch bypass, already known good).

NOT yet confirmed on hardware, being the only RTL on ap040x2 above that
bitstream: 12cf17f5, the ATC sweep read/judge fix.  It is behaviourally
neutral under the current stall enable -- full regression green with cycle
counts unchanged -- so the risk is low, but it has not booted and should not
be described as though it has.

### X2.2b stage 2 COSTED (2026-08-24): it must follow P2, not precede it

The staging above offered two routes for the second lookup and preferred
one: "either duplicated tag storage per bank (area, and X2.7 says the budget
is tight) or lookups time-multiplexed on alternate ce phases.  The core runs
at ce=4, so the cache has spare cycles; multiplexing is the cheaper bet and
should be costed first."  Costed:

**The cheap route does not exist yet.**  The core does NOT run at ce=4 today.
`ce` is cpu_wrapper's `clkena_in = ~cpu_req | bus_complete | bus_berr` -- a
STALL enable on clk_sys, high whenever the core is not waiting on a
transaction, not a 4:1 phase.  The 4:1 enable is P2 (28MHz -> clk_114 + 4:1
clock enable), which has not been done.  There are no spare ce phases to
multiplex a second lookup into.

**The remaining route is duplication, and ALMs are the binding constraint.**
A second concurrent lookup needs a second ATC lookup path and TTR compare in
the MMU, a second tag comparator set, hit mux and request state in the cache,
and a second read port on the data arrays.  Measured against the last fit:

    Logic utilization    38,238 / 41,910 ALMs   91%
    Total RAM blocks        250 /    553        45%
    Worst setup slack     -0.517 (pll_hdmi; clk_114 and clk_sys close)

  The RAM half is affordable.  cdata0..3 are 512x32 simple-dual-port
  (one read address, one write address), ~2 M10K each; a true-dual-port
  x32 needs parallel halves because TDP caps the per-port width, so call
  it +8 blocks against 303 spare.  Nothing there is a problem.

  The ALM half is the problem.  At 91% with a domain already failing
  setup, adding two lookup datapaths is the wrong shape of change.

**Consequence: stage 2 moves after P2.**  P2 is what turns the second lookup
from a DUPLICATION problem (expensive in ALMs, unaffordable at 91%) into a
MULTIPLEXING problem (nearly free in ALMs, which is what the staging assumed
in the first place).  Doing stage 2 first buys ~3 of the 20.1 cycles a cached
load spends, at the cost of the area budget and on a design that already
misses timing -- and then P2 would have made it cheap anyway.

Stage 1 (channel-qualified acknowledge) is unaffected and already shipped:
it is pure bookkeeping, costs nothing, and is exactly the part that wants to
be settled before either route is taken.

Hazards that must be argued explicitly, not discovered:
  * a store followed by a fetch of the same line -- the queue-vs-store
    snoop (3.2) must still see stores with two channels live;
  * fault attribution: an access error on the instruction channel must
    stack the fetch's address and the data channel's must stack its
    own, with the restart model unchanged;
  * locked RMW: lk_cyc indivisibility must survive an independent fetch
    channel (this is exactly what 3.1 fixed for the single port);
  * exception_prefetch still requires no queue fetch outstanding -- the
    bench invariant added for 3.5 covers it and must stay green;
  * CINV/CPUSH sweeps versus concurrent lookups on the other bank.

## X2.3 Pipeline: 040-style stages on one clock domain

IF | ID | EA | MEM | EX | WB, ce-based single clock (clk_114 with ce=4
initially -- same frequency as today, structure first, speed second).
The restart exception model is kept until X2.6: an instruction commits
at WB or restarts whole; format $7 stays synthetic.  Forwarding EX->EA
and WB->EX; scoreboard on Dn/An/CCR (the "collapse staging + add
forwarding" item -- it lives INSIDE this stage structure, not bolted to
the old FSM).

  Gate: >= 1 instruction/2 ce on reg-reg streams (t_integer chkl-free
  inner blocks), suite + corpus green.

### X2.3 step 2 SHIPPED (2026-08-20): memory source, same collapse

The EA is finished by the time the source read issues, so port B is free
during the read: point it at a register destination at S_PIPE_SRD and
both operands land together when the read returns.  S_PIPE_SDONE ->
S_PIPE_DST -> S_PIPE_DREG becomes S_PIPE_SDONE -> S_EXEC.

    move.l (An),Dn (cached)   17.6 -> 15.6 cycles

  Gated: suite green, corpus 3776/3801 failing set unchanged, integer
  15/15, FP 8/8, MMU 8/8.

### X2.3 NEXT TARGET, measured: S_MRD is 37.7% of a load

Profiled with +prof over 768 cached longword loads (20.1 cyc/load before
step 2):

    S_MRD         5832  37.7%   (only 682 stalled -- 12%)
    S_FETCH       1196   7.7%
    S_PIPE_START  1161   7.5%
    S_DECODE      1037   6.7%
    S_EXEC        1033   6.7%
    S_PIPE_SRD     864   5.6%
    S_EA_DISP      777   5.0%
    S_EA_BASE      768   5.0%
    S_PIPE_SDONE   768   5.0%   <- step 2 removed the DST/DREG pair here

  S_MRD costs 7.6 cycles per load and is WAITING ON THE BUS for only 12%
  of them.  The other 88% is the core/MMU/cache request-acknowledge
  round trip on a HIT -- the audit's "2-cycle cache hit" describes the
  cache array, not the path around it.  That path, not the staging, is
  where the next several cycles per load live, and it is the same round
  trip the 5.7-cycle nop floor pays on every instruction fetch.

  MEASURED 2026-08-20 with the new +memlat instrument, and the answer
  was NOT the handshake:

    data read   n=770  avg 2.2 cycles  (767 of them exactly 2)
    data write  n=5    avg 4.0
    ifetch      n=539  avg 9.2, max 31+, with 133 in the 31+ bucket

  The cache round trip is already 2 cycles for data.  What S_MRD is
  actually doing is WAITING FOR THE SHARED MEMORY PORT: 44% of
  S_MRD/S_MWR cycles in phase 0 and 56-57% in the latent-bus phases are
  spent with a fetch outstanding (!m_issued && epf_pend).  The fetches
  it waits behind are largely 31+ cycle line fills, i.e. real cold
  misses, not gratuitous prefetch.

  HYPOTHESIS TESTED AND WRONG, recorded so it is not retried:
  suppressing speculative fetch issue while an effective address is
  being computed (all S_EA_*, S_PIPE_SRD, S_PIPE_DEA) changed nothing --
  load cost 4039 vs 4036 cycles, port wait 44%/57% unchanged.  The
  blocking fetch is issued BEFORE the EA states, so gating on them is
  too late.  Reverted.

  The real fix is architectural and already named: X2.2's DECOUPLING.
  The cache has separate I and D banks, but the core has ONE request
  port to the MMU, so an instruction line fill and a data access
  serialize.  A real 68040 runs them independently.  Until the fetch
  port is separate, ~half of every data access's wait is a fill it has
  nothing to do with -- and no FSM-level change reaches it.

### X2.3a PREREQUISITE: de-fragilize the timing-dependent tests
     [added 2026-08-20, found by attempting X2.3 step 1]

X2.3 changes instruction timing by design.  Several t_exceptions tests
are written against the CURRENT timing and fail when it moves -- and
they fail for the BASELINE core too, which is how this was established
rather than assumed: removing ONE nop from the withdrawal sweep breaks
the unmodified core (test 142).  Any pipeline work will trip these
before it can be judged on correctness, so they have to be made robust
FIRST or every X2.3 step will land in a false failure.

The fragile pattern is a fixed sweep hoping a coincidence lands inside
it:
  * test 142 sweeps an IPL delay 2..12 into a traced RTS and requires
    at least one delay to land trace and interrupt together;
  * test 143 does the same into a traced divide;
  * the withdrawal sweep pads with a fixed number of nops;
  * test 139 needs the fetch queue to run AHEAD during a DIVU so the
    faulting fetch is SPECULATIVE (fault deferred and discarded).  If
    the fetch instead becomes a DEMAND fetch it faults for real, which
    is correct behavior and a test failure at the same time.

Task: rewrite these to search a range derived at RUNTIME, or to assert
the invariant directly rather than by hitting a cycle coincidence.  The
architectural rules they exist to protect are already enforced
independently by tb_ap040_program's always-on invariants (phantom
interrupt, mask qualification, exception_prefetch/epf_pend), and those
did NOT fire during the X2.3 experiment -- only the coincidence-hunting
assertions did.

### X2.3 step 1 SHIPPED after X2.3a (2026-08-20)

Both regfile read ports are independent and combinational, so a
register source and a register destination can be read in ONE cycle
instead of walking S_PIPE_SREG then S_PIPE_DST then S_PIPE_DREG.
Measured with the $F108 stamp port:

    add.l Dn,Dn     8.1 -> 6.1 cycles
    move.l Dn,Dn    8.1 -> 6.1
    addq.l #1,Dn    7.2 -> 6.2
    nop             unchanged (no operand staging)

  25% on the register-op class for a ~20 line change, and it is the
  first concrete piece of the "collapse staging + add forwarding" item.
  Held back until X2.3a had made the fragile tests say something real,
  then gated properly: directed suite green, v24 corpus 3776/3801 with
  the failing set unchanged, integer differential 15/15 vs qemu, FP
  10/10 and MMU 10/10 vs the WinUAE oracles.

  X2.3a paid for itself immediately.  The t_exceptions failure was NOT
  the coincidence sweeps at all -- widening those changed nothing.  It
  was test 139, and the handler-identity stamp added by X2.3a named it
  in one run (h_buserr, id 13) instead of an anonymous shared "test 98".
  The fault address then gave the mechanism outright: armed $0F56,
  delivered $0F54, stacked PC $0F52.  $0F54 is the DIVU's own extension
  word, and the queue fetches ALIGNED LONGWORDS -- so a DEMAND fetch at
  $0F54 spans $0F54..$0F57 and covers the armed word.  The DIVU sat at
  $0F52, straddling two longwords, so the word the test wanted reached
  only speculatively was pulled in by a demand fetch instead.  The test
  premise held by accident of layout.  Fixed with cnop so the DIVU
  occupies a longword alone and t139_x starts its own: now structural,
  and BOTH cores pass.  No RTL was changed to make it pass.

## X2.4 Dual issue (68060-style pOEP/sOEP)

Second ALU pipe fed by the same decoder; issue rules after the 68060:
pOEP takes anything, sOEP takes reg-reg/imm-reg ALU ops with no EA unit
need, no CCR read of the same-cycle pOEP result, no pairing across
flow control or privileged ops.  Memory, shifts>1, mul/div, FPU stay
single-issue in pOEP.  This is bounded: the pairing table is ~40 rows
of the 68060 UM's table 10-1 reduced to what AP040X2 executes natively.

  Gate: pairing rate >= 30% on t_integer, zero behavior change when
  sOEP is compile-disabled (AP040X2_DUAL=0 must bit-match AP040X2_DUAL=1
  with pairing suppressed -- that equivalence run is the regression).

## X2.5 FPU pipelining

The F0/F1 work gave single-op latencies (FMUL ~5, FDIV ~20, FSQRT ~21
at ce).  X2 pipelines FMUL/FADD to initiation interval 1 ce (3-stage),
keeps FDIV/FSQRT iterative but overlapped (fpu_bg already proves the
scoreboard).  Gate: T3.

## X2.6 Frequency: 57 MHz (ce=2), then 114 MHz native

Only after X2.3-X2.5 hold at ce=4.  57 first: the known >17.6 ns cones
(exc_addr capture, MMU translate->fault, F_ROUND, now the 4-way hit mux)
get registered splits; STA drives the list.  114 native requires the
MEM stage to tolerate 1-cycle SDRAM CAS variance -- that is the point
where the restart model gets re-examined (real WB1-WB3).  T1 falls out
at 57 MHz already if X2.3's CPI gate held: 57M * 0.5 IPC > 25M * 1.0.

## X2.7 Area budget (honest numbers from the ap040 branch fits)

MEASURED 2026-08-17: the X2.2 queue plus the audit-fix program took the
tree from 39,645 ALMs (95%, committed HEAD) to 42,067 -- OVER the
41,910-ALM device.  Recovered by the "MMU pruning" item below, executed
as storage conversion rather than feature removal: the ATC's 128 x 45b
payload (5.7K flops + the 4-way mux fabric, the single largest ALM sink)
moved into one 180x32 bram.vhd dpram row per {bank, set}.  Validity and
round-robin stay in flops, so PFLUSHA, warm-reset retention and the
lookup guard remain single-cycle; enabled translation pays a one-clock
lookup pipe (TC.E=0 and TTR hits stay combinational -- the common
configuration pays nothing); PFLUSH page/nonglobal variants and the
PTEST pre-flush became a ~34-cycle row sweep.  Result: 37,170 ALMs
(89%), clk_114/clk_sys met, and ~4.7K ALMs of headroom for X2.3-X2.5.

Current: core 10.0K + MMU 5.6K + FPU 4.5K ALMs, system total 94%.
X2 adds: fetch queue (+0.3K), pipeline regs/forwarding (+1.5K), second
ALU pipe + pairing (+1.5K), sdram32 datapath (+0.5K) ~= +4K => does NOT
fit beside everything at 41.9K.  Funded by: cpu_cache_new out (-0.8K,
the internal cache with the 32-bit fill path replaces it FOR REAL this
time -- the fill tax that killed it was the 16-bit bus, X2.1 removes
exactly that), bus16 adapter out (-0.4K), MMU pruning of the never-used
5.6K -> target 3.5K (srp/urp tables share one walker datapath).  Net
target: <= 95% with dual issue, <= 92% without.  If the fitter says
otherwise, X2.4 is the item that yields (it is compile-optional by
construction).

## X2.8 Verification invariants (non-negotiable, learned the hard way)

  - run_tests.sh green at every commit; corpus slices for any touched
    instruction class; full corpus before any RBF.
  - Every pipeline hazard fix ships with a directed test THAT FAILS on
    the pre-fix RTL (a test never seen to fail proves nothing).
  - Hardware measurements outrank every simulation and every test I
    wrote (see 2026-08-16: the internal cache "win" that measured
    slower than no cache; the RTE deferral reverted against its own
    correct fix).
  - Cycle claims come from the tb_prof state histogram, not estimates.
    Per-instruction claims come from the $F108 cycle-stamp port with
    CACR ENABLED -- the 68040 resets with both caches off, and a probe
    that forgets to set $8000_8000 measures the uncached machine.
  - Correctness claims are checked against WinUAE's OWN code, executed,
    not read (added 2026-08-20).  tests/ap040/diff carries two oracles
    built for this:
      fp_oracle.cpp    links WinUAE's softfloat and answers with the
                       same floatx80_* calls fpp_softfloat.cpp makes;
                       run_fpops.sh compares AP040 op by op.
      mmu_oracle.cpp   links WinUAE's cpummu.cpp behind ~37 stubs and
                       drives its public mmu_op_real PTEST path;
                       run_mmuops.sh compares MMUSR probe by probe.
    Standing results: FP 25 seeds x 96 ops all match (one architectural
    class remains -- extended-precision underflow flushes to zero where
    softfloat builds the denormal the FPSP would); MMU 25 seeds x 48
    probes all match, bit for bit.  qemu remains available but is the
    WEAKER oracle: it raises neither OPERR nor INEX2 on FP-to-integer
    conversions and gets the NaN result wrong.
  - A differential that finds a "CPU bug" is guilty until the HARNESS is
    cleared.  Every divergence chased on 2026-08-20 was harness-side:
    an inverted PTEST R/W bit, an FPSR read after a store that clears
    it, operands pre-rounded by the FMOVE that loaded them, a program
    grown into its own result window, and a result page whose M bit the
    program set itself.

## The walker-ack blind window (2026-08-27)

Early restart's third blocker turned out not to be an MMU logic bug at all,
and not the "walk concurrent with a fill faults" that the symptom suggested.

The symptom was a double fault: `pc=146c ir=f518 mem_flt=1 prev_state=10
in_exc=1`, with `aer_fa=146c` (the address of the PFLUSHA whose own fetch
faulted) while `m_addr_r=33c4` (the exception frame write that faulted
second).  A cycle trace of the window shows what actually happens:

    [47629205000] st=3 addr=0000146c ack=0 | wst=1 wact=1 | wreq=1 wack=0 armed=0
    ...  42 ms of simulated time, unchanged  ...
    [89572215000] st=10 addr=000033c4 ack=0 flt=1 | wst=1 wact=1 | wreq=1 wack=0

`walker_req` is asserted and never acknowledged.  The walk never completes,
the frame write stalls behind it, and the bus watchdog eventually fires --
which the core, already in exception processing, takes as a second fault.
The fault was the watchdog, not a translation error, which is why every
theory that started from "the walk faulted" went nowhere.

ROOT CAUSE.  A protocol mismatch, latent in the shipping core:

  - sdram_ctrl, sdram32_ctrl and ddram_ctrl all default `walker_ack` low
    and raise it for exactly one clk cycle.
  - The MMU's walk state machine advances only under `ce`.
  - cpu_wrapper.v:267 drives `.clkena_in(~cpu_req | bus_complete | bus_berr)`
    -- ce is low for the WHOLE of an outstanding CPU bus access.

So a walk that overlaps a bus access has a multi-cycle blind window in which
a one-cycle ack is lost outright.  Today no walk can overlap one, because the
core cannot run while an access is outstanding, so the mismatch is dormant.
It is the first thing any change that lets the core run during a fill hits.

Worth noting where the contract already existed: ap040_walker_cdc level-holds
its `s_ack` until the MMU drops `s_req`, and its comment names this exact
hazard.  But the CDC is only in the benches that cross clock domains -- the
shipping design (cpu_wrapper.v:476) wires the walker port straight through,
so the MMU has to provide the hold for itself.

FIX.  Latch `walker_ack`/`walker_berr`/`walker_data` and hold them until
`walker_req` drops.  Since `walker_req` is `w_active && w_issued` and
`w_issued` is cleared by `walk_ack`, the hold releases exactly when the walk
consumes it and can never be read as the next descriptor's response.  The
live signals are still taken when they coincide with a ce cycle, so a walk
that is not shadowed by a bus access costs exactly what it did before -- the
fix is free in the common case.

With it in place, early restart passes the full regression.  Blockers 1 and 2
(live `m_instr`/`m_fc`, live `tag_ridx` during fill) were already fixed and
landed separately as 111e855d and 864ea1ac; this is blocker 3.

The fix lands on its own, ahead of any decision about early restart, because
it is a real deviation from what the memory controllers actually drive.

### Early restart: worth 5% on the streaming regime (2026-08-27)

CORRECTION.  An earlier version of this section concluded from bench_loop
that early restart was worth 0.036% and was blocked by cpu_wrapper's
clkena_in gating.  Both halves were wrong and the section is replaced.

bench_loop cannot measure fill work.  Its own profile says so:

    PROF phase 2: 326674 cycles, summed "stalled" column ~1089  = 0.33%
    ADLAT gap=453  wait=3422   (of ~979k cycles over three phases)

A benchmark that spends 0.33% of its cycles stalled on the bus cannot
measure a change to the fill path.  The -116 cycle delta measured there was
noise around zero, not a small win, and it must not be used to rank
memory-hierarchy work.  The clkena_in story built on top of it does not
survive either: busstate is the ap040's external bus state and clkena_in
releases on bus_complete, so an earlier ack does release the core sooner --
which the measurement below confirms directly.

MEASURED on bw_probe under tb_cpu_wrapper_chip with TURBO_CHIP=1, which is
the realistic path (real fastchip/rtg/akiko/gayle/ide, ram_cs_guard):

    tag   block                          base      early     delta
    0011  movem reads, code in window    71184     71132     -0.07%
    0021  same, code relocated out       65716     65708     -0.01%
    0031  move.l (a0)+ reads            118048    118032     -0.01%
    0041  movem writes                   95412     95404     -0.01%
    0051  STREAMING reads 32KB          492764    468076     -5.01%
    0061  streaming reads, warmed       492716    468052     -5.00%
    0071  streaming WRITES              389384    389376     -0.00%
    0081  RMW of one line                87444     87420     -0.03%
    ----  whole chip-bus run            453784    441400     -2.73%

Blocks 5 and 6 sweep 32KB with movem.l so every line is a miss -- the
xsysinfo regime that produces the hardware MB/s figures.  That is where the
5% lands, and it is the number that matters.  Block 7 shows nothing because
a streaming write never needs the critical word back, which is the right
signature for this change and a check that the 5% is real rather than drift.

WHAT IS AND IS NOT IMPLEMENTED.  The landed version is the safe subset:

  - acks the critical longword as soon as its beat returns; fill_acked
    suppresses the later C_TAGW ack so the core is never acked twice
  - the tag is still written only at C_TAGW, so the line stays INVALID
    until every beat has arrived
  - cst stays in C_FILL for the whole line, so a second miss waits rather
    than colliding with the background fill

Not yet done, and the next increment: start the fill at the REQUESTED beat
and wrap, instead of always at beat 0.  Note the ceiling on that here is
modest for this particular probe -- bw5/bw6 walk forward with movem.l from
a 32-byte-aligned base, so the first touch of each line is already at
offset 0 and beat 0 is already the critical beat.  It pays on non-zero
first touches (backward walks, unaligned bases, data structures entered
mid-line), so it needs a probe with those before its own win can be
claimed.

Two bugs this exercise exposed on the way -- live m_instr/m_fc, and a live
tag_ridx during fill -- were real latent defects and landed separately as
111e855d and 864ea1ac.  The walker-ack blind window (4ae61485) was the third.

### Critical word first: 11.1% when a line is entered at its last beat

Early restart alone still fetched beat 0 first, so a miss that wanted beat 3
waited the whole line before its ack.  Wrapping the fill -- start at the
requested beat, wrap, stop when the next beat would be the start -- makes the
critical beat always the FIRST one.

Nothing downstream had to change.  Each beat is an independent 32-bit request
that the adapter splits into two word cycles, so there is no burst order for
the controller to care about and the wrap is free.

Measuring it needed a new probe.  Every existing bw_probe block enters each
line at offset 0, where beat 0 is already critical and CWF has nothing to
recover -- and indeed the whole run was unchanged (441400 -> 441396).  Blocks
9 and 10 were added for this: block 9 touches offset 12 of every line first
(critical beat 3), block 10 is the identical loop at offset 0 as its control.

    block                          beat-0     wrapped    delta
    9   enters line at offset 12   443352     393944     -11.13%
    10  enters line at offset 0    394272     394256     -0.00%

The control matters as much as the result: CWF doing nothing on block 10 is
what says the 11% on block 9 is the mechanism and not drift.  Note also that
443352 vs 394272 is the penalty mid-line entry used to carry -- 12.4% -- and
wrapping removes essentially all of it.

Real code sits between the two blocks: branch targets, struct fields and
stack frames enter lines at arbitrary offsets.  For a uniform entry offset
the mean saving is about half the block-9 figure.

Together with early restart (5.0% on the streaming blocks) this completes
item 1.  Remaining from the sequence, unchanged in order:

  2. remove the forced inter-word idle cycle   (measured 8.7% of cycles)
  3. real 32-bit fill path                     (est. up to 22%)
  4. instrument CHIP's extra ~5 clocks/long
  5. core sequencing (82.5% of cycles are FSM progression, not bus stalls)

### Items 2 and 3: what each actually requires (surveyed 2026-08-27)

ITEM 2 -- the forced inter-word idle cycle.

The gap is real and is required by the module the adapter comment names.
cpu_cache_new's CPU-side state machine returns to IDLE only on !cpu_cs
(cpu_cache_new.v:396, :399, :467) and clears cpu_ack only on !cpu_cs
(:583).  So the adapter cannot change addr_out under a held ack, exactly as
ap040_bus16_adapter.v:193 says.

What makes this tractable: cpu_cache_new is instantiated INSIDE sdram_ctrl,
sdram32_ctrl and ddram_ctrl, and this tree is AP040-only -- there is no
fx68k or tg68k left to keep compatible.  The AP040 adapter is its only
client, so its CPU-side contract can be changed outright rather than
extended with a compatibility mode.  The work is a pulse-ack/back-to-back
contract in cpu_cache_new, removal of the adapter's subcycle_gap, and a
matching pass over ram_cs_guard.

ITEM 3 -- the 32-bit fill path.  Much further along than assumed.

sdram32_ctrl ALREADY HAS the port, with a documented contract
(sdram32_ctrl.v:194-202):

    // 32-bit cache line fill port (16 byte line, 4 longword beats).
    // fill_req is level held until fill_ack; fill_addr must stay stable
    // while it is asserted.  fill_strb pulses once per delivered longword,
    // beats ascending within the line, and fill_ack pulses with the last.

and tb_sdram32.v already exercises it in both dual and single-SDRAM modes
(tb_sdram32.v:350, :426).  The build uses this controller:
Minimig.sv:475 instantiates sdram32_ctrl #(.CPU_CACHE(1), .DUAL_SDRAM(1)).

The missing half is entirely on the client side.  Minimig.sv:507 ties
fill_req to 1'b0 and leaves fill_strb/fill_ack unconnected, and the
placeholders that would carry it -- cache_burst / cache_burst_len -- are
tied off in ap040_tg68k_compat.v:441 and unconnected at cpu_wrapper.v:310.
So the work is: drive the port from ap040_ucache's fill loop and route it
through those two placeholders to the top level.  The hard part (SDRAM burst
scheduling, dual-lane assembly) is written and covered.

INTERACTION TO SETTLE FIRST.  The port delivers "beats ascending within the
line".  Critical word first needs to start at an arbitrary beat, so
connecting the port as it stands would give up the 11.1% measured on
mid-line entry in exchange for width.  SDRAM bursts take a start column
natively, so extending the port with a start-beat is the natural fix and
should be decided before the client is written rather than after.

ddram_ctrl and sdram_ctrl have no equivalent port, so a fill-port client has
to keep the 16-bit path as its fallback for those targets.

## Item 3 implemented: the 32-bit fill path (2026-08-27)

The client side of sdram32_ctrl's line fill port now exists end to end:
ap040_ucache -> ap040_tg68k_compat -> cpu_wrapper -> ap040_fill_cdc ->
Minimig.sv -> ram1.  Scoped to CHIP RAM (fill_ok in cpu_wrapper), the
worst-measured region; kick RAM is the natural follow-up, FAST needs the
port added to ddram_ctrl first.

THE DISCOVERY THAT SHAPED IT.  cpu_wrapper runs on clk_sys (28MHz) while
sdram32_ctrl runs on clk_114 -- the fill port CROSSES CLOCK DOMAINS, and its
single-clk_114 strobes are physically unsamplable from the CPU domain (most
fall between its clock edges; the ce gating sits on top of that).  The first
attempt wired the port straight through and hung exactly the way the
walker-ack blind window hung.  Two structural fixes came out of it:

  - ap040_fill_cdc: toggle-handshake bridge modeled line by line on
    ap040_walker_cdc, including the s-side reset crossed into the m domain.
    It collects the whole burst m-side, indexed by each strobe's named beat,
    and presents the COMPLETE line to the cache with s_done LEVEL-HELD until
    the cache drops its request -- the same contract, for the same reason.
    The cache consumes the line from a buffer, so the burst order never
    reaches it at all.

  - f_busy: the cache exports "internal work in flight that no external bus
    level will ever advance" (C_FFILL wait, C_FWR line write-back, C_TAGW),
    and cpu_wrapper ORs it into clkena_in.  Without it the fast fill
    deadlocks: clkena_in = ~cpu_req | bus_complete never rises because no
    16-bit bus activity exists to raise bus_complete.

CACHE SIDE.  New states: C_FFILL (request + wait on the bridge) and C_FWR
(stream the buffered line into the way RAM, one longword per ce cycle).
Early restart is preserved -- the core is acked with its critical longword
the cycle f_done is seen, and the line writes back BEHIND the ack.  CWF is
preserved -- f_bsel asks the controller to burst-start at the critical beat.
The tag still writes only at C_TAGW and cst is held through the fill, so the
invariants (line invalid until complete, second miss waits) carry over.

MEASURED, bw_probe on tb_cpu_wrapper_chip TURBO_CHIP=1, RAM_LAT=3, with the
real ap040_fill_cdc in the bench:

    tag   block                       16b+CWF    32-bit     delta
    0051  streaming reads 32KB        468076     328132     -29.9%
    0061  streaming, warmed           468052     328092     -29.9%
    0071  streaming WRITES            389376     389248      -0.0%
    0091  mid-line entry (beat 3)     393944     287080     -27.1%
    00a1  same loop, beat 0           394256     287028     -27.2%

Against the original pre-early-restart baseline, streaming reads are
492764 -> 328132 = -33.4%.  Writes unchanged is the expected signature: the
port is read-only by design (stores keep the 16-bit write-through path).

COVERAGE NOTES, honest ones:
  - tb_sdram32 exercises the controller half against the real SDRAM model,
    all four critical beats, with a negative control (a controller made to
    ignore fill_bsel fails 8 checks with the exact rotation predicted).
  - tb_cpu_wrapper_chip runs the real CDC + cache + cpu_wrapper against a
    bench model of the port; t_integer/t_mmu/t_exceptions/t_fpu pass over
    it under TURBO_CHIP.
  - NOT COVERED: the real sdram32_ctrl and the real CDC in the SAME bench
    (tb_sdram32 drives the port directly; the chip bench uses a model), and
    a chipset DMA write snooping a line mid-fast-fill (the chip bench ties
    snoop_tgl off).  Both are RBF-risk items to keep in mind; the snoop
    guard logic is shared with the slow fill via any_fill, which bounds the
    exposure.
  - t_cache "fails" on the chip bench because that bench has no POKEREG
    port; it never ran there (tb_prog leg only).  Pre-existing, not new.

### The fill port on sdram_ctrl -- because the hardware runs the SINGLE build

A check of the build config stopped the first RBF attempt: Minimig.qsf uses
sys_analog.tcl with MISTER_DUAL_SDRAM commented out, and the build logs of
the RBFs measured on hardware confirm the macro was never defined.  The
user's board runs plain sdram_ctrl -- where the fill path just landed was
dormant.  (The dual-SDRAM variant trades the analog VGA pins for the second
module; sdram32_ctrl refuses boards without it via dual_ok.)

So sdram_ctrl now carries the same port, implemented as sdram32_ctrl's
16-bit mode verbatim: two 4-word half bursts per line, the critical half
first (fill_bsel[1]; bsel[0] ignored), fill_slot released at state 12 so the
second half pre-arbitrates in the same CCK.  PRE_FILL is lowest arbitration
priority; the burst words are taken from sdata_reg_q at states 9/11/13/15,
one state after the CPU_READCACHE strobes, paired into longwords.

COVERAGE CLOSED.  tb_sdram_turbo now carries the REAL stack end to end --
cpu_wrapper -> ap040_fill_cdc -> sdram_ctrl, the exact configuration the
single-SDRAM build ships -- in both CPU_PHASE variants, and the regression
runs t_integer/t_mmu/t_fpu/t_exceptions over it.  The FILL_AVAIL bench
parameter rebuilds with the path off, which is the A/B knob and the proof of
engagement:

    t_integer, tb_sdram_turbo (real sdram_ctrl, real CDC):
        FILL_AVAIL=0   73087 cycles
        FILL_AVAIL=1   62143 cycles     -15.0%

A 15% gain on a general-purpose program (not a streaming probe) over the
real controller is the number that predicts hardware.

The last coverage gap is now closed too: tb_ap040_fillsnoop is a directed
bench against the real ap040_ucache proving that a snoop into the fill's row
during C_FFILL or C_FWR prevents the line from being TAGGED (the re-read
misses and refetches fresh data), with two controls -- a clean fill's
re-read HITS, and a snoop to a different row does not de-tag.  It runs as
the fillsnoop regression leg.

### RBF built: timing IMPROVED, and the CPU is not the critical path

  output_files/Minimig-ap040x2-4273daf3-20260827_133123.rbf
  (also left at output_files/Minimig.rbf -- this is the mainline branch)

Its RTL is identical to HEAD: the only commit after it, 994751ce, touches
tests and this document.

    Quartus 17.0.2, 5CSEBA6U23I7, 0 errors, elapsed 00:14:08

                        cd033533 (boots)   this build
    setup slack             -0.290           +0.023
    hold slack               0.167            0.238
    ALMs                    38,238 (91%)    38,522 (92%)
    RAM blocks                   --          258 (47%)

Two things worth keeping:

  - the build that currently runs on the user's board was failing setup by
    0.290ns and booted anyway.  This one CLOSES, with TNS 0.000 on every
    clock, so the fill path and its CDC did not cost timing -- they bought
    some.  ~+284 ALMs against the 38,238 the plan last recorded, inside the
    "<= 92% without dual issue" gate in the sizing section.

  - the worst path is pll_hdmi's counter, not the CPU.  The two emu|pll
    domains (clk_114 and clk_sys) sit at +0.108 and +0.835.  Whatever the
    next timing fight is, it is not in this core.

What this bitstream carries, none of it yet hardware-tested: the walker-ack
hold (4ae61485), early restart (494903c7), critical word first (714a7e50),
and the 32-bit fill path on BOTH controllers (bcd8a7f9, 4273daf3).

The single number to watch on hardware is xsysinfo's CHIP figure: 5.19 MB/s
before, and the real-stack simulation says a general-purpose program spends
15% fewer cycles.  ROM should move too (kick RAM is served by the same
controller but is NOT yet in fill_ok's window -- that is the next increment
and deliberately not in this build).

## Hardware result: the fill path is inert, and WHY reorders everything

    xsysinfo            before      after     TG68K-020
    Dhrystones           5277       5307        20911
    chip  MB/s           5.19       5.19        24.21
    fast  MB/s           6.64       7.09        19.91
    rom   MB/s           8.26       8.24        24.44

CHIP -- the region fill_ok was scoped to -- did not move by a single digit,
while FAST moved +6.8% and is served by ddram_ctrl, which has no fill port
at all.  That is the prediction exactly inverted, and the cause is in
ap040_tg68k_compat.v:380:

    .c_nocache(mm_nocache | ~cache_allow)

with the comment forty lines above it saying what mm_nocache does on a real
machine: "On a real 040 Amiga this cannot happen because 68040.library marks
chip RAM noncacheable through the MMU; with the MMU off, nothing does."

Decode cache_win per region and all three numbers fall out:

  CHIP $000000-1FFFFF  in cache_win (cache_chip), but 68040.library marks it
                       cache-inhibited -> mm_nocache -> bypass -> NO L1 fill
  ROM  $F80000+        addr[23:21]=111 fails cache_chip AND the z2ram term
                       (23 ^ |[22:21] = 1^1 = 0) -> never cacheable at all
  FAST Z2/Z3           cacheable, and the OS marks it so -> fills happen

So on hardware the L1 fills FAST and nothing else.  Early restart and
critical word first are what moved FAST by 6.8%; the 32-bit fill path,
scoped to chip RAM, never runs.

THE METHOD ERROR, because it is the second of its kind.  bw_probe measured
-30% and tb_sdram_turbo -15% because BOTH benches run with the MMU off, so
mm_nocache is 0 and chip RAM is cacheable there.  The measurement was real
for the bench and meaningless for the machine -- exactly like measuring
early restart on bench_loop, which spends 0.33% of its cycles on the bus.
A performance bench has to be checked for whether it reproduces the
CACHEABILITY the shipping software establishes, not just the timing.

WHAT THIS REORDERS

  1. Point the fill path at FAST, which needs the port on ddram_ctrl.  That
     is cheap in an unexpected way: ram_dout is ALREADY 64 bits (one DDR3
     read = 8 bytes = half a line) and ddram_ctrl currently slices it into
     four 16-bit beats at states 1-4.  A line is two DDR3 reads; the wide
     data is already in hand and is being thrown away.

  2. Item 2 (the inter-word idle gap) is worth MORE than the 8.7% estimate,
     not less.  Chip and ROM are uncached on hardware, so every one of their
     accesses is a bare 16-bit adapter cycle and pays the gap on every
     subcycle.  It is the only lever that touches chip and ROM at all.

  3. Chip RAM's 5.19 MB/s is not a cache problem and never was.  Nothing in
     the cache can reach it while the OS marks it cache-inhibited -- which
     it does for a good reason (the I-bank staleness that crashed Enigma).

CONFIRMATION STILL OWED: the chip-RAM half of this is inferred from the code
and fits the data, but has not been observed on the machine.  showmmu will
say directly whether $000000-$1FFFFF reads as CacheInhibit -- the same tool
that settled the RTG question.  Worth doing before building on it.

## The NetBSD regression: a per-page PFLUSH that flushed the wrong row

NetBSD stopped booting several builds ago -- before the fill path, before
early restart, before the unified L1.  It was 12cf17f5, which changed the
ATC sweep and shipped with NO test able to see what it broke.

MECHANISM.  The ATC RAM's port A read free-runs on clk while the walker
state machine advances on ce, so WHICH row q_a carries at a ce edge depends
on the ce ratio:

    stall enable (1:1, the shipping build)   q_a = mem[previous count]
    4:1 (P2)                                 q_a = mem[current count],
                                             the address having been held
                                             for four clocks

12cf17f5 shadowed the DATA through an extra ce-gated register to fix the 4:1
case.  That made 4:1 right and made 1:1 -- the build that ships -- wrong by
exactly one row.  A per-page PFLUSH then cleared a NEIGHBOURING ATC entry
and left the named page's stale translation resident.

Which is invisible to AmigaOS and fatal to NetBSD.  A pmap unmaps pages with
the page form of PFLUSH constantly; 68040.library leans on PFLUSHA.  A
kernel that unmaps a page and keeps translating it is exactly the freeze
signature this core has been chased around before.

THE TEST GAP, which is the real lesson.  Every PFLUSH in t_mmu was a
PFLUSHA -- twenty of them.  PFLUSHA clears every row REGARDLESS OF TAG, so
it passes whatever row the sweep judges.  The entire suite was structurally
incapable of seeing a row-addressing error in the sweep, and 12cf17f5 went
in green.  Tests 201-204 close it: two pages made resident, BOTH descriptors
remapped, exactly ONE flushed -- the flushed page must show its remap
(catches judging the wrong row) and the other must stay stale (catches
flushing more than was asked).  Test 203 fails on the pre-fix RTL.

FIX.  Pipe the ADDRESS through the same one-clock free-running delay the RAM
puts the data through, and judge with that.  Data and address then leave the
same pipeline, so they agree by construction at ANY ce ratio -- 1:1 and 4:1
both, rather than trading one for the other.  P2 keeps what 12cf17f5 was
reaching for without the shipping build paying for it.

WHAT THIS SAYS ABOUT THE OTHER CHANGES.  It exonerates them: the fill path is
inert on hardware (chip RAM is cache-inhibited), and early restart and CWF
are what moved FAST +6.8%.  NetBSD broke earlier and for an unrelated reason.

### Known deviation found while chasing the above: walker writes are not
### snooped into the L1, and structurally cannot be

The table walker updates U and M bits by writing the descriptor through its
own dedicated port.  Those writes are snooped into cpu_cache_new inside the
controllers (sdram_ctrl and ddram_ctrl both drive .snoop_act(walker_snoop)),
but NOT into the AP040's L1: the L1's snoop comes from chip_snoop_tgl, the
chipset DMA snoop.

It could not be routed there as things stand even if one wanted to.
cpu_wrapper takes snoop_adr as [24:1] and presents it to the cache as
{7'd0, snoop_adr, 1'b0} (cpu_wrapper.v:118, :261), so the snoop path can
only express the low 24 bits of address space.  Z3 and DDR3 descriptors live
above that and have no representation.

Consequence: a page-table word the CPU has read (and so cached) goes stale
in the L1 when the walker sets its U or M bit.  A kernel that reads PTEs
back to decide whether a page is dirty can therefore see M clear on a page
the walker has already marked modified.

NOT the boot regression -- it predates the unified L1, and NetBSD booted on
-021b with the same hole -- and it is recorded here rather than fixed
because widening the snoop path is a cpu_wrapper interface change.  But it
is squarely on NetBSD's path (it is the only OS here that walks DDR3) and
belongs on the conformance backlog next to the other audited deviations.

## Core CPI work, session of 2026-08-27: -17% measured, method recorded

INSTRUMENTATION (kept, in-tree): asm/bench_cpi.s times 4096 copies of each
instruction class between $F108 stamps; tb_ap040_program +strace=<hextag>
prints the state walk right after that stamp.  Together they turn "the core
is slow" into a named list of states with cycle counts on each.

BASELINE per-class cost (phase 0, caches on, everything hits):

    class                    clk    state walk
    nop / moveq / bra.s     2.77
    add.l d2,d3             5.52    FETCH DECODE PIPE_START PIPE_REGS EXEC
    lea 4(a0),a0            6.97
    move.l (a0),d3 hit     12.52    ... EA_DISP EA_BASE SRD MRD*4 SDONE EXEC
    move.l d3,(a0)         19.71    8 front states + S_MWR*11
    add/load mix            9.02

Three landed changes (bf74faa4, 08ef7682, + the SREG fold):

 1. Cache hits ack COMBINATIONALLY from C_LOOK (tag_q/data_hit are already
    registered at accept; nothing needed the extra edge).  Every hit -- data
    and fetch-queue refills both -- got one cycle back.  Taken branches
    went 2.77 -> 2.09 on this alone.
 2. ea_start dispatches (An)/(An)+/-(An) straight to S_EA_BASE.
 3. Operand bypass (X2.4): register-destination ops go PIPE_START -> EXEC
    with src_eff/dst_eff muxing the regfile ports (or m_val) into the ALU
    and the EXEC body; EXEC's top commits them so chained states see
    registered values.  Also folds SDONE for reg-destination loads, and
    S_PIPE_SREG's capture into S_PIPE_DST for stores.

AFTER:

    class                   before   after
    nop                      2.77     2.46
    add.l d2,d3              5.52     4.39
    move.l d2,d3             5.52     4.39
    move.l (a0),d3 hit      12.52     9.40
    move.l d3,(a0)          19.71    17.52
    bra.s taken              2.77     2.09
    dependent add chain      5.51     4.39   (bypass has no forwarding cost)
    bench_cpi total                  -16.8%
    bw_probe move.l block            -24.3%

WHAT IS LEFT, in value order:

 a. THE STORE PATH: 17.5 clk, of which ~11 are S_MWR waiting out the
    write-through handshake.  The fix is a posted store (accept + ack, drain
    behind), but that is a FAULT-CONTRACT decision, not a state fold:
    t_exceptions relies on precise write bus errors, and a posted store's
    late m_err has nowhere precise to land on a restart-model core.  Options:
    post only after MMU translation (MMU faults stay precise; only the bus
    timeout goes imprecise, and that already halts), or a 68040-style
    writeback frame, which the compat contract currently forbids.  Decide
    before implementing.
 b. Store front end: PIPE_START could point port B at the source data for a
    pure store (port B is free when dst is memory) and run the EA
    immediately -- folds PIPE_DST/PIPE_DEA, walk 8 -> ~5 front cycles.
 c. DECODE -> PIPE_START fold needs decode-time p_* threading (pipe_go is
    blind; the p_* are same-cycle NBAs).  Worth ~1 clk on everything.
 d. S_MRD hit is now 3 cycles (req reg, accept, comb-hit).  Getting to 2
    needs the tag read issued from the REQUEST cycle (index from c_addr
    while still in C_IDLE) -- the RAM read is already synchronous-1-cycle,
    so accept+lookup could overlap with a bypassable tag index mux.

## The 6-stage pipeline question, and register renaming (asked 2026-08-27)

Short answer: the 6-stage IN-ORDER pipeline is the right destination and the
work is already climbing toward it stage by stage; register renaming is the
wrong tool for this core on this device, and the case is quantitative.

WHAT RENAMING WOULD BUY HERE: elimination of WAR/WAW hazards so that
multiple in-flight instructions can write the same architectural register.
That pays on a wide OOO machine.  The AP040 is single-issue, and today's
measured cycle budget contains essentially zero WAR/WAW stall: the cycles go
to state-walk serialization (4.39 clk ALU ops), the memory path (8.5 load /
16.4 store), and the 16-bit bus.  Renaming attacks a cost this core does not
yet pay.  Amdahl says: nothing, until CPI is near 1 and issue width is >1.

WHAT IT WOULD COST:
  - A physical regfile with more read ports (replication on this fabric),
    a map table, and checkpoint/rollback.  The restart exception model
    already needed ONE shadow-register rollback (the A7 shadow), and that
    machinery produced the NetBSD silent-freeze root cause (2035c49d).  A
    renamed core is that hazard class multiplied across every register.
  - Precise faults on a renamed machine mean a ROB and retirement -- a
    re-verification of the entire conformance corpus against a new
    micro-architecture.
  - Area: the device is at 92%, and X2.7's honest budget shows even
    dual-issue (+4K) only fits by funded removals.  Renaming does not fit.
  - The 68040 itself has no renaming; nothing in the 68k line does.  The
    conformance oracles (cputest, WinUAE) encode in-order timing-visible
    behaviour the tests can see.

THE LADDER ALREADY BEING CLIMBED maps onto the real 68040's six stages:

    IA/IF   fetch queue                          done (X2.2)
    D       decode-ahead during EXEC             NEXT BIG ITEM (below)
    EAC     ea_start folds                       partly done today
    EAF     operand bypass + mrd/mwr pre-issue   done today
    EX      single-cycle ALU                     done
    (WB)    posted stores                        next, fault-contract first

Session cumulative (bench_cpi, phase 0): 300062 -> 239334 cycles, -20.2%.
    add.l 5.52->4.39   load hit 12.52->8.52   store 19.71->16.40
    bra.s 2.77->2.09   floor 2.77->2.46

DECODE-AHEAD, the D stage, is where the next factor lives: run the decoder
over the queue head DURING the current instruction's EXEC/terminal state and
latch p_* so the next instruction enters at its first useful state.  ALU ops
4.39 -> ~2.5, floor -> ~1.5.  Prerequisite: the decoder (the giant S_DECODE
case) must become a standalone combinational block with registered outputs
-- an extraction, mechanical but large, and the single biggest remaining
step.  After it, the 6-stage shape exists in all but name; 57 MHz (X2.6)
then covers the remaining gap to TG68K rather than renaming.

### Posted stores landed; the fault question answered itself

The gate that preserves every precise-fault test: post ONLY a store that
HITS a resident line.  A write miss -- all I/O, all first-touch, and both of
t_exceptions' injected write bus errors, which target $F140 and no cached
line ever covers -- still completes synchronously.  A write hit is acked at
the tag compare and drains from latched registers (r_addr/r_size/r_wdat/
r_sfc) while the core runs; the next memory access naturally interlocks on
cst != C_IDLE, so ordering needs no new machinery.  tag_ridx holds the
store's row during the drain so the merge decision still compares the right
tags after the core moves on.

The drain exposed one real bug the old synchronous path had been masking:
the merge wrote st_place(c_wdata, ...) -- LIVE data, correct only because
the core used to hold it through the wait.  Under posting, MOVEM's next
store was already on the bus at merge time and the line took the wrong
register (t_integer test 94, seven legs red).  The merge now uses r_wdat.

    move.l d3,(a0)   16.40 -> 12.46   (back-to-back; drain-limited)
    bench_cpi        -25.6% cumulative for the session

Late bus error on a posted store: swallowed, documented at the declaration.
Only reachable as a hardware timeout on resident-line RAM, i.e. a machine
already dying; a real 68040 would deliver a writeback fault frame, which
the compat contract forbids advertising.

### Verilator is now the program-bench runner

run_tests.sh verilates tb_ap040_program when verilator is installed (~30x
faster than vvp with identical results on all five programs) and falls back
to the vvp build otherwise.  Both simulators stay buildable on purpose: the
two have caught DIFFERENT bug classes before (the sdram-turbo 2-state
tristate artifact was verilator-specific; the function/array sensitivity
hazard was iverilog-specific).  Full regression wall time: ~8min -> 54s,
now dominated by the iverilog multi-bench legs -- convert those next if the
loop needs to get tighter still.

### The queue-hot fetch fold: the D stage arrives

fetch_next now pops the next instruction word itself when the queue already
holds it (epf_ready_pc) and enters S_DECODE directly -- S_FETCH would have
spent a cycle discovering exactly this.  The pop logic lives in ONE task
(pop_decode) shared with S_FETCH so the two cannot drift, and the fold
falls back to S_FETCH for every case that state handles specially:
exception-entry refills, a change-of-flow T0 trace waiting at the target,
a queue error, and the queue-dry/forwarding cases.

    class              before    after
    nop / moveq         2.46      2.09
    add.l d2,d3         4.39      3.45
    move.l (a0),d3      8.52      7.40
    move.l d3,(a0)     11.09     10.77
    lea 4(a0),a0        6.78      5.72
    add/load mix        6.40      5.46
    bench_cpi total    -13.2%, session cumulative -37.0%

The fold surfaced a MONITOR error, not a core bug: the TB required every
instruction-fetch bus cycle during in_exc to carry FC6.  That was only ever
true while the core could not run detached from its bus traffic.  A
background line fill of USER code (early restart) legally streams its
remaining beats with FC2 while the core stacks an exception frame -- the
fill's FC was latched at issue and is correct.  The monitor now judges only
cycles serving the core's own current request (matched by longword
address), which is the actual contract: handler opcodes FC6, frames and
vectors FC5.  Real leaks still match the qualifier and still fail.

### FDIV/FSQRT at six digits per cycle

Same cascade shape as the integer divider's doubling: FDIV 22+1 rounds ->
11+1, FSQRT 22 -> 11.  t_fpu bit-exact in all three phases (the
WinUAE-oracle battery is the arbiter); program-level only -301 cycles
because t_fpu is an exception battery, not a divide benchmark -- the win is
per-operation.  Timing carries the same caveat as the integer divider.

## Acceleration series status (end of 2026-08-27)

NINE RTL commits sit unbuilt on ap040x2 (2f789d09 through 67e3b5b2): the
f_busy fix, CPI works 1-7, the page-walk cache and the FPU radix doubling.
Session-cumulative on bench_cpi: -37%.  None of it has seen the fitter, and
the last build attempt failed clk_114 setup at -0.114 BEFORE most of this
logic existed -- assume the next build is a timing fight, with the comb hit
ack (hit_now feeding c_ack) and the two doubled dividers as the likely new
critical paths.  If the divider cascades fail, halve them back or register
the midpoint; if hit_now fails, the fallback is re-registering the ack (one
cycle back on loads, everything else stands).

Codex owns ap040_muldiv.v (division); its WIP is checkpointed at 0b4e2dc6
and further edits ride uncommitted in the tree.  Coordinate before building.

Remaining CPI ladder: decode-during-EXEC (needs the decoder extraction),
32-bit writes (stores are drain-limited at 10.77), branch redirect cost
(2.09 floor), Verilator conversion of the multi-bench legs.

### CPI work 8: the dispatch fused into S_DECODE -- S_PIPE_START retired
### from the common path

The +prof histogram after works 1-7 put S_PIPE_START at 15% of ALL cycles
(28,468 of 188,925) -- the largest remaining foldable block, spent waiting
for the p_* operand plan to register.  The dispatch now runs in the DECODE
cycle itself: one pipe_dispatch task takes the twelve operand-plan values
as ARGUMENTS, S_PIPE_START passes the registered p_* (still reached by the
19 S_IMMF extension-word returns), and pipe_go passes same-cycle blocking
mirrors (bd_*) that every operand write in S_DECODE also updates -- 363
writes rewritten by script, seeded from the registered values at the top of
the always block so partial overrides dispatch on the pop defaults.

    class              before    after     session start
    add.l d2,d3         3.45      2.46         5.52
    move.l (a0),d3      7.40      6.77        12.52
    move.l d3,(a0)     10.77     10.46        19.71
    bench_cpi total    -10.3%              cumulative -43.5%

A register ALU op now costs what a NOP cost at the session start.
