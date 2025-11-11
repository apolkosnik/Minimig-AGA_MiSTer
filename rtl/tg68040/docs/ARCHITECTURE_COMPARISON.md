# MC68040 vs MC68020 vs TG68K Architecture Comparison

## Executive Summary

This document provides a detailed comparison between the MC68040, MC68020, and the current TG68K implementation to guide the development of TG68040.

## Processor Generations

```
MC68000 (1979) → MC68010 (1982) → MC68020 (1984) → MC68030 (1987) → MC68040 (1990)
     ↓                ↓                  ↓                                    ↓
  TG68K          TG68K              TG68K                              TG68040 (target)
  (mode 00)      (mode 01)          (mode 11)                          (mode 10)
```

## Core Architecture

### Registers

| Feature | MC68020 | MC68040 | TG68K | TG68040 Target |
|---------|---------|---------|-------|----------------|
| Data Registers | D0-D7 (32-bit) | D0-D7 (32-bit) | ✓ | ✓ |
| Address Registers | A0-A7 (32-bit) | A0-A7 (32-bit) | ✓ | ✓ |
| Program Counter | 32-bit | 32-bit | ✓ | ✓ |
| Status Register | 16-bit | 16-bit | ✓ | ✓ |
| Vector Base Reg | VBR | VBR | ✓ | ✓ |
| Cache Control | CACR (16-bit) | CACR (32-bit) | Stub | Full implementation |
| FP Registers | External (68882) | FP0-FP7 (80-bit) | None | Full implementation |
| FP Control | External | FPCR, FPSR, FPIAR | None | Full implementation |
| MMU Registers | External (68851) | TC, DTT0/1, ITT0/1, etc. | None | Full implementation |

### Control Registers (MOVEC accessible)

**TG68K Current:**
- SFC (Source Function Code)
- DFC (Destination Function Code)
- USP (User Stack Pointer)
- VBR (Vector Base Register)
- CACR (Cache Control - stub)

**TG68040 Additional:**
- TC (Translation Control)
- ITT0, ITT1 (Instruction Transparent Translation)
- DTT0, DTT1 (Data Transparent Translation)
- MMUSR (MMU Status Register)
- URP (User Root Pointer)
- SRP (Supervisor Root Pointer)

## Pipeline Architecture

### MC68020 Pipeline (3 stages)
```
┌──────────┐     ┌──────────┐     ┌──────────┐
│  Fetch   │ --> │  Decode  │ --> │ Execute  │
└──────────┘     └──────────┘     └──────────┘
```

### MC68040 Pipeline (6 stages)
```
┌────┐   ┌────┐   ┌────┐   ┌────┐   ┌────┐   ┌────┐
│ IF │-->│ ID │-->│ EA │-->│ OF │-->│ EX │-->│ WB │
└────┘   └────┘   └────┘   └────┘   └────┘   └────┘
  ↑
  └────────────── Instruction Cache ────────────────┘
```

**Pipeline Stages:**
- **IF** (Instruction Fetch): Fetch from I-cache
- **ID** (Instruction Decode): Decode opcode
- **EA** (Effective Address): Calculate operand addresses
- **OF** (Operand Fetch): Fetch operands from D-cache/registers
- **EX** (Execute): Perform operation
- **WB** (Write Back): Write results

### TG68K Current
- Micro-coded execution (no true pipeline)
- State machine based
- Variable cycle count per instruction

### TG68040 Target
- 6-stage pipeline (as above)
- Hardware hazard detection and forwarding
- Branch prediction (simple predict-not-taken initially)
- ~4x throughput improvement at same frequency

## Memory Hierarchy

### Cache Organization

| Aspect | MC68020 | MC68040 | TG68K | TG68040 Target |
|--------|---------|---------|-------|----------------|
| I-Cache | External only | 4KB, 4-way set assoc | None | 4KB, direct-mapped (initially) |
| D-Cache | External only | 4KB, 4-way set assoc | None | 4KB, direct-mapped (initially) |
| Line Size | N/A | 16 bytes | N/A | 16 bytes |
| Write Policy | N/A | Write-back | N/A | Write-through (initially) |
| Replacement | N/A | LRU | N/A | Simple (round-robin) |

**68040 Cache Features:**
- Physically indexed, physically tagged
- Cache coherency support via bus snooping
- Per-line valid and dirty bits
- Push and invalidate operations

### Memory Management

| Feature | MC68020 | MC68040 | TG68K | TG68040 Target |
|---------|---------|---------|-------|----------------|
| MMU | External 68851 | Dual integrated | None | Dual integrated |
| Page Size | 256B-32KB | 4KB, 8KB | N/A | 4KB |
| TLB Entries | N/A | 64 (I) + 64 (D) | N/A | 16+16 (initially) |
| Protection | 3-level | 2-level (S/U) | None | 2-level |
| Transparent Xlate | No | Yes (ITT/DTT) | No | Yes |

## Instruction Set

### Integer Instructions

**Fully Compatible:**
- All 68000/68010/68020 instructions supported by TG68K
- Same opcodes, same behavior

**New in 68040:**
- `MOVE16` - 16-byte block move (cache line sized)
- `CINV` - Cache invalidate
- `CPUSH` - Cache push

**Removed in 68040:**
- `CALLM`, `RTM` - Module call/return (also not in TG68K)

### Floating Point Instructions

**MC68020 with 68882:**
- External coprocessor
- Full IEEE 754 support
- Transcendental functions (FSIN, FCOS, FTAN, FATAN, etc.)
- 46 FPU instructions total

**MC68040 Integrated FPU:**
- Subset of 68882 instruction set
- 35 instructions in hardware
- Transcendental functions via software emulation (F-line trap)
- Same register model (FP0-FP7)

**TG68K:**
- No FPU support

**TG68040 Target:**
- Hardware implementation of 35 core FPU instructions
- F-line emulation trap for transcendentals
- Full IEEE 754 single/double/extended precision

### FPU Instructions by Category

**Arithmetic (Hardware in 68040):**
- FADD, FSUB, FMUL, FDIV
- FSQRT, FABS, FNEG
- FREM, FMOD, FSCALE
- FSGLDIV, FSGLMUL

**Comparison (Hardware):**
- FCMP, FTST

**Move (Hardware):**
- FMOVE, FMOVEM, FMOVECR

**Conditional (Hardware):**
- FBcc, FDBcc, FScc, FTRAPcc

**Not in 68040 Hardware (need emulation):**
- FSIN, FCOS, FTAN
- FASIN, FACOS, FATAN, FATANH
- FSINH, FCOSH, FTANH
- FETOX, FETOXM1, FTWOTOX, FTENTOX
- FLOG10, FLOG2, FLOGN, FLOGNP1

## Bus Interface

### Signal Comparison

**MC68020:**
```
Address Bus:    A31-A0 (32-bit)
Data Bus:       D31-D0 (32-bit, dynamic sizing to 8/16/32)
Function Code:  FC2-FC0
Async Control:  AS, DS, R/W, DBEN, DSACK0-1
Bus Arbitration: BR, BG, BGACK
Interrupts:     IPL2-IPL0
```

**MC68040:**
```
Address Bus:    A31-A0 (32-bit)
Data Bus:       D31-D0 (32-bit, fixed)
Transfer Type:  TT1-TT0 (replaces FC)
Sync Control:   TS, TA, TEA, TIP
Transfer Mode:  TM2-TM0
Size:           SIZ1-SIZ0
Bus Lock:       LOCKE
Cache Snoop:    MI, SC1-SC0
Interrupts:     IPL2-IPL0
```

**TG68K:**
```
Address Bus:    ADDR(31:0)
Data Bus:       DATA(15:0) - 16-bit only!
Function Code:  FC(2:0)
Async Control:  AS, UDS, LDS, RW, DTACK
Interrupts:     IPL(2:0)
Sync Support:   E, VPA, VMA (6800 peripheral)
```

**TG68040 Target:**
- Extend data bus to 32-bit: DATA(31:0)
- Add synchronous bus support
- Add burst transfer support
- Add bus snooping for cache coherency
- Maintain backward compatibility mode for 16-bit bus

### Bus Cycles

| Aspect | MC68020 | MC68040 | TG68K | TG68040 |
|--------|---------|---------|-------|---------|
| Type | Asynchronous | Synchronous | Async | Sync + Async mode |
| Min Cycles | 2 clocks | 2 clocks | 4 clocks | 2 clocks (sync) |
| Bus Width | 8/16/32 dynamic | 32-bit fixed | 16-bit | 32-bit (16 compat) |
| Burst | No | Yes | No | Yes |
| Lock | Yes | Yes | No | Yes |

## Performance Characteristics

### Instruction Timing (typical examples)

| Instruction | MC68020 | MC68040 | Improvement |
|-------------|---------|---------|-------------|
| MOVE.L Dn,Dm | 2 | 1 | 2x |
| ADD.L Dn,Dm | 2 | 1 | 2x |
| MULU.L | 44 | 3-5 | ~10x |
| DIVU.L | 56 | 40-44 | ~1.3x |
| DBRA (not taken) | 4 | 2 | 2x |
| JMP (An) | 4 | 1 | 4x |

### Overall Performance
- **68040 vs 68020:** ~4x at same clock frequency (25 MHz)
- **TG68K current:** ~0.5-0.7x of real 68020 (estimated)
- **TG68040 target:** 2-3x TG68K 68020 mode at same clock

## Implementation Complexity

### TG68K Current (68020 mode)

**Estimated Resources:**
- ~8,000 Logic Elements
- ~2 KB memory (register file, misc)
- No DSP blocks
- ~50 MHz max frequency (depends on FPGA)

**Code Size:**
- TG68K.vhd: ~300 lines
- TG68KdotC_Kernel.vhd: ~3,500 lines
- TG68K_ALU.vhd: ~1,500 lines
- TG68K_Pack.vhd: ~200 lines
- **Total:** ~5,500 lines VHDL

### TG68040 Target Estimate

**Estimated Resources:**
- ~15,000-20,000 Logic Elements (2.5x increase)
- ~50 KB memory (caches + TLBs + misc)
- ~10-20 DSP blocks (FPU operations)
- ~40-50 MHz max frequency

**Estimated Code Size:**
- Existing TG68K code: ~5,500 lines (with modifications)
- Cache subsystem: ~1,500 lines
- MMU subsystem: ~2,000 lines
- FPU subsystem: ~3,000 lines
- Pipeline control: ~1,000 lines
- New bus interface: ~500 lines
- **Total:** ~13,500 lines VHDL (2.5x increase)

## Feature Priority Matrix

### Must Have (Phase 1-2)
- ✓ CPU mode selection (68040 vs 68020/010/000)
- ✓ New control registers (CACR, TC, ITT/DTT)
- ✓ MOVE16 instruction
- ✓ Basic cache structure

### Should Have (Phase 3-9)
- ✓ 6-stage pipeline
- ✓ Instruction and data caches (working)
- ✓ Basic MMU with address translation
- ✓ Memory protection
- ✓ Transparent translation

### Could Have (Phase 10-12)
- ✓ Basic FPU (FADD, FSUB, FMUL, FDIV, FSQRT)
- ✓ FPU exception handling
- ✓ Transcendental emulation hooks
- ~ 4-way set associative caches (start with direct-mapped)

### Nice to Have (Phase 13+)
- ~ Write-back caches (start with write-through)
- ~ Branch prediction (start with predict-not-taken)
- ~ Bus snooping (for multi-processor, may not be needed)
- ~ Power management features

## Compatibility Considerations

### Software Compatibility

**Amiga OS Requirements:**
- Kickstart 3.1+ expects 68040 features
- 68040.library needs real FPU
- Virtual memory requires working MMU
- Cache-aware software expects cache control

**Testing Software:**
- SysInfo: CPU detection and features
- WhichAmiga: CPU type identification
- 68040.library test programs
- FPSP (FP Software Package) for transcendentals

### Hardware Compatibility

**MiSTer Platform:**
- FPGA: Cyclone V (DE10-Nano) - has enough resources
- Memory: DDR3 - fast enough for 68040 timing
- Bus interface: Needs adaptation for wider data bus

## Design Decisions

### 1. Cache Organization
**Decision:** Start with direct-mapped, upgrade to 4-way later
**Rationale:** Simpler implementation, good enough for first version

### 2. Write Policy
**Decision:** Start with write-through, add write-back later
**Rationale:** Easier cache coherency, simpler logic

### 3. TLB Size
**Decision:** 16 entries per TLB (vs 64 in real 68040)
**Rationale:** Resource constraints, likely sufficient for Amiga workloads

### 4. FPU Implementation
**Decision:** Hardware for core operations, software for transcendentals
**Rationale:** Matches real 68040, transcendentals rarely used

### 5. Bus Interface
**Decision:** Support both 32-bit and 16-bit modes
**Rationale:** Backward compatibility with existing Minimig infrastructure

### 6. Pipeline Depth
**Decision:** Full 6-stage pipeline from the start
**Rationale:** Core architectural feature, affects everything

## Migration Path from TG68K

### Code Reuse

**Can Reuse (~70%):**
- Register file structure
- Basic ALU operations
- Instruction decoder (with extensions)
- Bus state machine (adapted)
- Exception handling (extended)

**Must Rewrite (~30%):**
- Execution model (micro-code → pipeline)
- Memory interface (add caches)
- Control logic (hazard detection)
- Timing generation

### Incremental Approach

1. **Keep TG68K working** - don't break existing modes
2. **Add 68040 mode gradually** - new CPU mode, initially acts like 68020
3. **Layer features** - each phase adds capabilities
4. **Maintain testability** - each phase independently verifiable
5. **Document differences** - clear notes on TG68040 vs real 68040

## Known Limitations (Acceptable)

1. **TLB smaller than original** (16 vs 64 entries)
2. **Simpler cache** (direct-mapped vs 4-way initially)
3. **No bus snooping** (single processor only)
4. **Slower FPU** (multi-cycle vs single-cycle for some ops)
5. **No power management** (not relevant for FPGA)

## References

1. **MC68040UM/AD** - MC68040 User's Manual, Motorola
2. **M68000PM/AD** - M68000 Family Programmer's Reference Manual
3. **TG68K Source** - Existing implementation by Tobias Gubener
4. **IEEE 754** - Floating Point Standard
5. **Minimig Documentation** - MiSTer Minimig-AGA core docs

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1 | 2025-11-11 | Claude AI | Initial architecture comparison |

