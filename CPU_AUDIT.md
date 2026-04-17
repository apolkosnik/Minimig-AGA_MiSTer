# TG68K CPU/MMU Deep Audit Report

## Scope
This pass audited the active 68030 path in this tree by reading the live RTL and maintained bench inventory, then reconciling that against the older audit notes.

- Active CPU/MMU RTL reviewed: `rtl/cpu_wrapper.v` (2196 lines), `rtl/tg68k/TG68K.vhd` (795), `rtl/tg68k/TG68KdotC_Kernel.vhd` (8817), `rtl/tg68k/TG68K_ALU.vhd` (1789), `rtl/tg68k/TG68K_PMMU_030.vhd` (4141), `rtl/tg68k/TG68K_Cache_030.vhd` (373), plus `rtl/tg68k/TG68K_Pack.vhd` (205).
- Test inventory reviewed: `110` VHDL benches under `tests/tg68k_030`, totaling `74,701` lines.
- Technical-debt signal in active CPU/MMU RTL: `631` `BUG #` comments total:
  - kernel `372`
  - PMMU `170`
  - wrapper `73`
  - cache `9`
  - ALU `6`
  - pack `1`
- This was a static audit pass only. I did not rerun ModelSim in this update.

## Executive Summary
The 68030 port is real and feature-rich, but it is not a clean monolithic CPU core. It is a mixed-language system made of:

- a heavily patched TG68K kernel
- a separate PMMU implementation
- a separate simplified cache block
- a Verilog wrapper that supplies the actual system-level correctness for bus suppression, physical-address routing, cache fills, walker arbitration, and timeout recovery

The most important architectural conclusion from this pass is that the true Minimig 68030 implementation lives in `cpu_wrapper.v` plus `TG68KdotC_Kernel.vhd`, not in `rtl/tg68k/TG68K.vhd` alone. Any audit or test that looks only at the standalone `TG68K` wrapper will miss the real MMU/cache integration path.

## Implementation Topology

### 1. Real hardware integration path
- `rtl/cpu_wrapper.v` is the system integration point.
- It instantiates `TG68KdotC_Kernel` directly (`cpu_inst_p`) and separately instantiates `TG68K_Cache_030`.
- It owns:
  - `clkena_in` gating around PMMU busy/fault/walker activity
  - physical-address bus routing (`bus_addr` uses `pmmu_addr_phys_p` in 68030 mode)
  - PMMU walker bus ownership and timeout recovery
  - SDRAM/cache fill arbitration
  - Fast RAM/chip RAM walker special cases

### 2. Standalone `TG68K.vhd`
- `rtl/tg68k/TG68K.vhd` is an alternate wrapper, not the live Minimig integration path.
- Its internal kernel instantiation leaves the PMMU register interface open and ties the walker ports off (`pmmu_reg_* => open`, `pmmu_walker_* => open/'0'` around lines 428-446).
- In this tree, the only direct consumer of that wrapper is `tests/tg68k_030/tb_integration_test.vhd`.
- Practical implication: `TG68K.vhd` is useful as a bench-facing top, but it is not sufficient for auditing real hardware behavior.

### 3. Kernel responsibilities
- `rtl/tg68k/TG68KdotC_Kernel.vhd` contains:
  - instruction decode / micro-state engine
  - register file and stack-mode handling
  - MOVEC and MOVES handling
  - PMOVE/PTEST/PFLUSH/PLOAD sequencing
  - exception and stack-frame construction
  - PMMU instruction-side plumbing
- This remains the densest risk area in the design because opcode lifetime, PC lifetime, and exception lifetime all overlap here.

### 4. PMMU responsibilities
- `rtl/tg68k/TG68K_PMMU_030.vhd` contains:
  - TC / CRP / SRP / TT0 / TT1 / MMUSR register state
  - ATC storage and replacement policy
  - table walker FSM
  - transparent translation logic
  - MMUSR / fault / configuration-exception generation
  - PTEST / PLOAD / PFLUSH behavior
  - descriptor history writeback (U/M bits)

### 5. Cache responsibilities
- `rtl/tg68k/TG68K_Cache_030.vhd` is a standalone cache block with:
  - 256-byte instruction cache
  - 256-byte data cache
  - direct-mapped organization
  - 16-byte lines
  - physically indexed / physically tagged lookups
  - CACR-driven invalidation and fill control

## Implemented Structures, Instructions, and Features

### Register file, prefetch, state machine (concrete)
- Register file: `RF_ARRAY` (D0–D7, A0–A7), sequentially clocked, write-enabled via `Regwrena_now`/`WR_AReg`/`rf_source_addrd`/`rf_dest_addr` ([TG68KdotC_Kernel.vhd:349-1880](rtl/tg68k/TG68KdotC_Kernel.vhd#L349-L1880)). A7 byte-op +2 correction is implicit fall-through in ALU ([TG68K_ALU.vhd:642-663](rtl/tg68k/TG68K_ALU.vhd#L642-L663)), not a guarded branch.
- Prefetch: single-word pseudo-queue `last_opc_read` updated only on read cycles (`state="10"`) ([Kernel:3351](rtl/tg68k/TG68KdotC_Kernel.vhd#L3351)); shadow `fline_opcode_latch` ([Kernel:639](rtl/tg68k/TG68KdotC_Kernel.vhd#L639)) for F-line / MOVES extension-word paths. No 2-word queue.
- Micro-state enum: [TG68K_Pack.vhd:28-39](rtl/tg68k/TG68K_Pack.vhd#L28-L39). `idle`/`nop` have no explicit `when` handlers; they rely on combinational defaults `setstate <= "00"` ([Kernel:3862](rtl/tg68k/TG68KdotC_Kernel.vhd#L3862)) and `next_micro_state <= idle` ([Kernel:3940](rtl/tg68k/TG68KdotC_Kernel.vhd#L3940)). No assertions guard this.
- PC-write paths (three, ELSIF priority, no hardware arbiter): `writePC` ([Kernel:2149](rtl/tg68k/TG68KdotC_Kernel.vhd#L2149)), `writePC_add` ([Kernel:2164](rtl/tg68k/TG68KdotC_Kernel.vhd#L2164)), `directPC` ([Kernel:2948](rtl/tg68k/TG68KdotC_Kernel.vhd#L2948)).

### CPU / architectural features present
- 68030 mode is enabled through `CPU(1)` / `cpucfg[1]`.
- Long multiply/divide, extended addressing, bitfield support, VBR stack frames, and MSP/ISP handling are wired through the kernel generics and 68030-mode decode paths.
- MOVEC support is limited to the implemented control-register subset:
  - `SFC`, `DFC`, `CACR`, `CAAR`, `USP`, `VBR`, `MSP`, `ISP`
- MOVES support is present, including SFC/DFC-based FC override paths and dedicated regression benches.
- RTE support includes multiple frame types, M-bit stack switching, and special recovery logic for MMU long-frame restore cases.

### Instruction coverage (decoder / micro-state inventory)

| Class | Status | Concrete anchor |
|---|---|---|
| MOVES | Full | SFC/DFC override + F-line context latch ([Kernel:442-459,1171-1312](rtl/tg68k/TG68KdotC_Kernel.vhd#L442-L459)) |
| MOVEC | Partial (whitelist) | SFC/DFC/CACR/CAAR/USP/VBR/MSP/ISP only; PMMU regs deliberately trap ([Kernel:movec1](rtl/tg68k/TG68KdotC_Kernel.vhd#L2998)) |
| MOVEP | Full | Odd-byte memory-register |
| CAS / CAS2 | Full (software atomic) | `cas1..cas28` RMW micro-states ([Kernel:4290](rtl/tg68k/TG68KdotC_Kernel.vhd#L4290)); no hardware bus lock |
| CHK2 / CMP2 | Full, patched | **BUG #444** ([ALU:1471-1476](rtl/tg68k/TG68K_ALU.vhd#L1471-L1476)): bit-15 test fixed via `exe_opcode(10:9)` size override |
| BFxxx | Full | BFEXTU/S, BFINS, BFTST, BFCHG, BFCLR, BFSET, BFFFO |
| PACK / UNPK | Full | `pack1..pack3` |
| TRAPcc | Full | Condition in opcode[3:0] ([Kernel:5297](rtl/tg68k/TG68KdotC_Kernel.vhd#L5297)) |
| MULS/U.L, DIVS/U.L | Full, flags unverified | DIVU.L/DIVS.L overflow paths clear C ([ALU:1411-1425](rtl/tg68k/TG68K_ALU.vhd#L1411-L1425)); prior HW regression reverted one fix |
| LINK.L / UNLK | Full | `link1/2`, `unlink1/2` |
| PFLUSH / PLOAD / PTEST / PMOVE | Full | See §PMMU |
| BKPT | **Stub** | Decoded as nop; no vector-12 trap ([Kernel:4942](rtl/tg68k/TG68KdotC_Kernel.vhd#L4942)) |
| CALLM / RTM | **Missing** | `-- to do 68020` ([Pack:80-81](rtl/tg68k/TG68K_Pack.vhd#L80-L81)); no ILLEGAL stub either |
| F-line (FPU) | **Stub** | Dispatches vector 11 Unimplemented ([Kernel:5818-5856,5982-5994,7023](rtl/tg68k/TG68KdotC_Kernel.vhd#L5818-L5856)); no FP hardware |
| MOVE16 | **Absent** | Neither decoder nor burst engine |

### PMMU walker, ATC, and fault details (concrete)
- Walker states `W_ROOT`, `W_PTR1..4` ([TG68K_PMMU_030.vhd:2295-3305](rtl/tg68k/TG68K_PMMU_030.vhd#L2295-L3305)). Root/parent DT (descriptor type bits 1:0) selects stride — **BUG #409** ([PMMU:304,2295,2328,2419,2618,2852,3093,3305](rtl/tg68k/TG68K_PMMU_030.vhd#L304)).
- WP accumulates across every descriptor level — **BUG #438** ([PMMU:2515,2531,2745,2765,2986,3006,3199,3218,3305](rtl/tg68k/TG68K_PMMU_030.vhd#L2515)); M-bit writeback requires WP=0 per WinUAE — **BUG #437** ([PMMU:3557,3664](rtl/tg68k/TG68K_PMMU_030.vhd#L3557)).
- ATC: 22 entries (`ATC_ENTRIES` [PMMU:191](rtl/tg68k/TG68K_PMMU_030.vhd#L191)), LRU with sticky fault entries; per-entry valid/fault_status/page_shift/descriptor_address. Stale `addr_phys_reg` window gated by `busy` — **BUG #416** ([PMMU:144-150,4039](rtl/tg68k/TG68K_PMMU_030.vhd#L144-L150)). Write-hit skips entries with M=0 unless WP=1 — **BUG #410** ([PMMU:1547](rtl/tg68k/TG68K_PMMU_030.vhd#L1547)).
- TTR combinational bypass `ttr_match_comb` ([PMMU:138-143](rtl/tg68k/TG68K_PMMU_030.vhd#L138-L143)) uses actual `rw` — **BUG #421** ([PMMU:4030](rtl/tg68k/TG68K_PMMU_030.vhd#L4030)).
- Faulting logical addr + FC/RW captured at fault time — **BUG #414/#415** ([PMMU:41-42,164-165,1349-1350,1614-1615,2000-2001,2037-2038](rtl/tg68k/TG68K_PMMU_030.vhd#L41-L42)).
- PTEST level from brief[12:10] — **BUG #413** ([PMMU:271,4097](rtl/tg68k/TG68K_PMMU_030.vhd#L271)). PLOAD does not update MMUSR (gated on `ptest_walk_pending='1'`).
- Bus-error stacking: Format $B for all read faults (inst+data), Format $A only for mid-instruction write faults. `berr_external_rw/fc` latched at first BERR fire — **BUG #431/#433b/#434** ([Kernel:544,546,548,3135,3143-3144,3325-3327,3348](rtl/tg68k/TG68KdotC_Kernel.vhd#L3135)). Vector 2 used for internal PMMU berr too — **BUG #435** ([PMMU:2385](rtl/tg68k/TG68K_PMMU_030.vhd#L2385)). `exe_pc` must come from `data_read` not TG68_PC — **BUG #439** ([Kernel:2324,3552,3558](rtl/tg68k/TG68KdotC_Kernel.vhd#L2324)).
- PMOVE implementation: pmove_decode, pmove_mem_to_mmu_hi/lo, pmove_mmu_to_mem_hi/lo, pmove_dn_hi/lo ([Pack:35-36](rtl/tg68k/TG68K_Pack.vhd#L35-L36)). Simplified Dn capture via `pmove_dn_mode`/`pmove_dn_regnum` — **BUG #70** ([PMMU:181](rtl/tg68k/TG68K_PMMU_030.vhd#L181)); 64-bit CRP/SRP via `pmmu_addr_inc`/`pmmu_dbl` ([Pack:144-145](rtl/tg68k/TG68K_Pack.vhd#L144-L145)); **BUG #53** retired an old 2-stage pipeline ([PMMU:650](rtl/tg68k/TG68K_PMMU_030.vhd#L650)).

### Cache details (concrete)
[TG68K_Cache_030.vhd](rtl/tg68k/TG68K_Cache_030.vhd):

| Param | Value |
|---|---|
| Size | 256 B each (I and D) |
| Lines | 16 |
| Line size | 16 B (4 longwords) |
| Associativity | direct-mapped |
| Index | paddr[7:4] |
| Tag | paddr[31:8] (24 bits) |

CACR bits: IE/DE/IFREEZE/DFREEZE/WA ([Cache:16-20](rtl/tg68k/TG68K_Cache_030.vhd#L16-L20)). Latch index/tag at miss and reuse at fill-complete; one outstanding fill per cache — **BUG #131/#132** ([Cache:98-100,139,182,246](rtl/tg68k/TG68K_Cache_030.vhd#L98-L100)). Cache-inhibit honored via PMMU `cacheable=0` ([Cache:209-220,359-370](rtl/tg68k/TG68K_Cache_030.vhd#L209-L220)). Page-invalidate path `cache_op_scope="01"` is unreachable from the kernel (kernel only drives 00/10).

### PMMU feature set present
- Implemented PMMU register surface:
  - `TC`
  - `TT0`
  - `TT1`
  - `CRP`
  - `SRP`
  - `MMUSR`
- Implemented PMMU instructions:
  - `PMOVE`
  - `PTEST`
  - `PLOAD`
  - `PFLUSH`
- Translation features present:
  - transparent translation via `TT0`/`TT1`
  - translation enable via `TC`
  - `22`-entry ATC (`ATC_ENTRIES := 22`)
  - multi-level walks including `W_PTR4` for 5-level cases
  - indirect descriptor support
  - early termination support
  - limit checking
  - descriptor `U/M` history writeback
  - MMU configuration exception path (vector 56)
  - internal PMMU fault path routed as vector 2 bus-error handling

### Cache feature set present
- Separate instruction and data caches
- CACR bits exported and used for:
  - enable
  - freeze
  - invalidate
  - instruction/data burst enable
  - write allocate
- Fill logic is coordinated by `cpu_wrapper.v`, not by the cache block in isolation.

### Explicitly unimplemented or simplified
- `CAL`, `VAL`, `SCC`, and `AC` are explicitly noted as not implemented in `TG68K_PMMU_030.vhd`.
- PMMU registers are treated as `PMOVE`-only by the kernel; `MOVEC` access to PMMU registers is intentionally illegal.
- The cache block is a functional simplified model, not a cycle-accurate recreation of a physical 68030 cache subsystem.

## Critical Architectural Observations

### 1. Opcode/prefetch lifetime is still patch-driven
The kernel still relies on `last_opc_read` plus special-case shadow latches such as `fline_opcode_latch`. That is a clear sign that instruction lifetime is not modeled as a first-class queue abstraction. PMMU and MOVES paths repeatedly work around this by latching extra context early.

### 2. Wrapper-level arbitration is part of correctness, not just integration glue
`cpu_wrapper.v` is doing architectural work:

- suppressing CPU bus requests while PMMU translation is pending/faulted
- switching region decode to physical addresses
- arbitrating walker ownership of chip/Fast RAM paths
- preventing cache fill / walker / stale-ready races
- unblocking the CPU after walker timeout or bus-fault paths

This means direct-kernel benches are necessary but not sufficient for proving real-system correctness.

### 3. Exception/stack behavior is heavily repaired in-place
The kernel has substantial bespoke machinery for:

- dual-frame interrupt/RTE handling
- MSP/ISP shadow synchronization
- MMU long-frame restore assist (`rte_mmu_fix_*`)
- short-vs-long bus-fault frame selection
- PMMU-specific bus-fault metadata capture

Functionally this is good coverage, but architecturally it means exception handling is one of the highest-risk maintenance zones.

### 4. The cache is intentionally simple and decoupled from several real-system concerns
The cache block is small, direct-mapped, and easy to reason about, but much of the subtle behavior lives outside it:

- fill ordering
- memory arbitration
- walker interaction
- write-hit wait behavior
- suppressing stale data during walker ownership

So the cache cannot be audited in isolation either.

## New Findings From This Audit

### 1. `TG68K.vhd` is not the real 68030 integration path
This is the single biggest structural finding of this pass.

- `cpu_wrapper.v` directly instantiates `TG68KdotC_Kernel` and `TG68K_Cache_030`.
- `TG68K.vhd` leaves PMMU register ports open and walker ports disconnected.
- `tb_integration_test.vhd` therefore exercises a wrapper that is materially less integrated than the real Minimig hardware path.

Impact:
- Any future audit, simulation, or refactor that treats `TG68K.vhd` as the system source of truth is likely to miss bugs in walker arbitration, bus suppression, cache-fill ordering, and physical-address routing.

### 2. PMMU comments and stale bench collateral still describe an older design
There is visible drift between comments/tests and the live implementation.

- `TG68K_PMMU_030.vhd` header still says "8-entry ATC" at the top of the file, but the implementation uses `ATC_ENTRIES := 22`.
- The PMMU header comment also says `TC`/`TT0`/`TT1`/`MMUSR` are MOVEC-accessible, but the live kernel whitelist in `movec1` only allows `SFC/DFC/CACR/CAAR/USP/VBR/MSP/ISP` and deliberately traps PMMU-register `MOVEC`.
- `tests/tg68k_030/tb_movec_pmmu.vhd` still assumes MOVEC access to `TC/TT0/TT1/SRP/CRP/MMUSR` and even sets `cpu_mode := "11"`, which is outside the documented `00/01/10` encoding.
- That bench is not wired into the maintained Makefile targets.

Impact:
- Source comments are not reliable enough to use as architecture truth without checking the executable paths.
- There is stale test collateral that can mislead future bring-up or regressions.

### 3. The implemented PMMU register surface is intentionally incomplete
The live PMMU focuses on the register set that the Amiga/68030 software path actually needs.

- Present: `TC`, `TT0`, `TT1`, `CRP`, `SRP`, `MMUSR`
- Absent: `CAL`, `VAL`, `SCC`, `AC`

Impact:
- Common Amiga MMU flows should be fine.
- Broader "complete 68030 PMMU register file" expectations are not met by this tree and should not be documented as if they are.

### 4. Cache page-invalidate logic exists but is currently dead from the kernel side
`TG68K_Cache_030.vhd` implements a `cache_op_scope = "01"` page invalidate path using a hard-coded 4KB page mask, but the kernel only ever drives:

- `"00"` for line operations
- `"10"` for all-cache operations

There is no kernel path that emits `"01"`.

Impact:
- This is not an immediate functional bug, but it is dead/unverified logic and a documentation hazard.
- If someone later tries to wire page invalidation into the kernel, they will inherit code that has not been exercised by the live command path.

### 5. The bench suite is broad, but the real wrapper remains a verification blind spot
The in-tree maintained suite is strong on functional breadth:

- PMMU functional coverage
- fault recovery and frame construction
- lockup/race regressions
- trace/stack-frame behavior
- real software-sequence emulation

But no maintained bench instantiates the actual `cpu_wrapper.v` integration. Several benches explicitly emulate `cpu_wrapper`-style gating or bus arbitration instead.

Impact:
- The biggest remaining blind spot is wrapper-level behavior under full integration:
  - walker vs cache fill
  - chip/fast/SDRAM bus selection from translated addresses
  - stale-ready suppression
  - timeout recovery

## Top-numbered BUG # hot spots (kernel / PMMU / ALU)

| # | File:line | Summary |
|---|---|---|
| 443 | [Kernel:2162,2182,2208](rtl/tg68k/TG68KdotC_Kernel.vhd#L2162) | Trap vector +2 vs stacked trace frames; guard on `trap_trace='0'` |
| 439 | [Kernel:2324,3552,3558](rtl/tg68k/TG68KdotC_Kernel.vhd#L2324) | `exe_pc <= data_read` (not stale TG68_PC) |
| 438 | [PMMU:2515,…,3305](rtl/tg68k/TG68K_PMMU_030.vhd#L2515) | WP accumulation across levels |
| 437 | [PMMU:3557,3664](rtl/tg68k/TG68K_PMMU_030.vhd#L3557) | M-bit writeback requires WP=0 |
| 436 | [PMMU:1960,3822](rtl/tg68k/TG68K_PMMU_030.vhd#L1960) | ATC berr-flag handling |
| 435 | [PMMU:2385](rtl/tg68k/TG68K_PMMU_030.vhd#L2385) | Vector 2 for internal PMMU berr |
| 434/433b/431 | [Kernel:544,546,548,3135,3143-3144,3325-3327,3348](rtl/tg68k/TG68KdotC_Kernel.vhd#L3135) | Latch addr/rw/fc/size at first BERR fire |
| 428 | [PMMU:4048](rtl/tg68k/TG68K_PMMU_030.vhd#L4048) | `fault_reg='1'` ⇒ translation "done" |
| 421 | [PMMU:4030](rtl/tg68k/TG68K_PMMU_030.vhd#L4030) | ttr_check uses actual `rw` |
| 416 | [PMMU:144-150,4039](rtl/tg68k/TG68K_PMMU_030.vhd#L144-L150) | Stale `addr_phys_reg` window gated by `busy` |
| 444 | [ALU:1471-1476](rtl/tg68k/TG68K_ALU.vhd#L1471-L1476) | CHK2/CMP2 bit-15 sign fixup |
| 397 | [ALU:72-74](rtl/tg68k/TG68K_ALU.vhd#L72-L74) | CCR restore on RTE format error |

## Re-confirmed non-issues
- `BS_X` vs `bs_X` ([ALU:1404](rtl/tg68k/TG68K_ALU.vhd#L1404)): VHDL identifiers are case-insensitive.
- `berr_long_frame` read→$B / write→$A polarity ([Kernel:3235](rtl/tg68k/TG68KdotC_Kernel.vhd#L3235)) matches MC68030UM §8.5.5.
- PMMU `ld_nn` pass-1 guard asymmetric to CPU `ld_nn` — correct (only PMMU has the 2-pass (xxx).L walker sequence).

## Additional architectural risks (line-cited)
- **PCbase leak** ([Kernel:3582](rtl/tg68k/TG68KdotC_Kernel.vhd#L3582)): cleared only on `setstate(1)='1' AND state(1)='0'`; exception-interrupted PC-relative can leak PCbase into next EA.
- **last_opc_read write-cycle stall** ([Kernel:3351](rtl/tg68k/TG68KdotC_Kernel.vhd#L3351)): updated only on read state; stale `last_data_read` window during multi-word MOVES/CAS write-then-fetch.
- **rte_saved_mbit race** ([Kernel:4087](rtl/tg68k/TG68KdotC_Kernel.vhd#L4087)): `interrupt_mode='1' OR rte_saved_mbit='0'` against directSR+changeMode in the same cycle.
- **Three HALT_CTX branches** ([Kernel:3135,3181,3211](rtl/tg68k/TG68KdotC_Kernel.vhd#L3135)) with overlapping conditions — historical uncertainty about double-fault trigger path.
- **EA-builder PC slip** ([Kernel:4050](rtl/tg68k/TG68KdotC_Kernel.vhd#L4050)): JMP/JSR d16,An does extra PC advance during `ld_dAn1`, partially masked by later `ea_to_pc`.
- **skipFetch is wrapper-only**: suppresses external AS but kernel PC still advances ([Kernel:2948](rtl/tg68k/TG68KdotC_Kernel.vhd#L2948)) — direct-kernel benches see no effect.

## Highest-Leverage Follow-Ups

1. Add a true wrapper-level simulation harness around `cpu_wrapper.v` for at least one maintained PMMU/cache/walker stress target.
2. Treat `cpu_wrapper.v` as part of the CPU/MMU architecture in all future audits and regressions; do not audit `TG68K.vhd` alone.
3. Clean up stale PMMU metadata:
   - fix the PMMU header comment (`8-entry` vs `22-entry`)
   - document that PMMU registers are `PMOVE`-only in the live kernel
   - either remove or explicitly mark `tb_movec_pmmu.vhd` as stale/non-maintained
4. Replace the ad-hoc opcode lifetime patches with a real prefetch/opcode queue abstraction if larger CPU work continues.
5. Keep the PMMU/cache/walker interaction surface small: most high-severity bugs in this tree have come from cross-module timing, not isolated logic errors.

## Test Posture
The maintained test suite is substantial and much healthier than the old short audit suggested:

- `110` bench files are present under `tests/tg68k_030`
- the Makefile organizes maintained coverage into:
  - PMMU functional
  - fault handling
  - lockup/race
  - trace
  - architecture/edge cases
  - real software-sequence validation

The key limitation is not breadth, but where the breadth stops: most benches validate the kernel/PMMU behavior directly, while the real Minimig integration responsibilities still live one layer up in `cpu_wrapper.v`.
