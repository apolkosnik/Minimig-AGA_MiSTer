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
