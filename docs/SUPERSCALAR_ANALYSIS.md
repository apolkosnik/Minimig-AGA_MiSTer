# FX68K Superscalar Architecture Analysis

## Current Architecture Overview

### FX68K Core Characteristics
- **Type**: Microcoded CISC processor (Motorola 68000 compatible)
- **Microcode**: 1024-entry microrom + 336-entry nanorom
- **Pipeline**: 5 T-states (T0, T1, T2, T3, T4)
- **Bus Cycles**: S0, S2, S4, S6 states
- **Execution**: Sequential, single instruction at a time
- **ALU**: Single fx68kAlu module
- **Register File**: 18 registers (8 data, 8 address, USP, SSP, DT)
- **Design Goal**: Cycle-accurate reproduction of original 68000 timing

### Current Pipeline Stages

```
T0 → T1 → T2 → T3 → T4
│     │     │     │     │
│     │     │     │     └─ Latch microcode/nanocode
│     │     │     └─────── Execute operations, update registers
│     │     └──────────── Process bus interconnections
│     └─────────────────── Register first-level mux
└──────────────────────── Reset/initialization state
```

### Execution Flow
1. **Instruction Fetch** (via IRC register)
2. **Microcode Decode** (uaddrDecode PLA)
3. **Nanocode Execution** (sequential microcode steps)
4. **ALU Operation** (single ALU processes one operation per cycle)
5. **Register Writeback** (T3)

### Key Bottlenecks for Superscalar Conversion

1. **Microcoded Control**: Sequential by nature, cannot issue multiple µops in parallel
2. **Single ALU**: Only one arithmetic/logic operation per cycle
3. **Single Bus Structure**: Shared buses prevent parallel data movement
4. **Cycle-Accurate Timing**: Design constraint prevents optimization
5. **No Dependency Analysis**: No hardware to detect instruction independence

## Superscalar Architecture Design

### WARNING: Breaking Compatibility
**Converting to superscalar will BREAK cycle-accurate compatibility with original 68000.**
This means Amiga software that depends on exact timing will fail.

### Proposed Superscalar Features

#### 1. Dual-Issue Architecture
- Fetch and decode 2 instructions per cycle
- Issue up to 2 µops to execution units simultaneously
- Requires instruction buffer and decode logic

#### 2. Multiple Execution Units
```
┌─────────────────────────────────────────┐
│         Instruction Fetch Unit          │
│         (2 instructions/cycle)          │
└────────────┬───────────────────────────┘
             │
┌────────────▼───────────────────────────┐
│         Dual Decode Units               │
│      (Decode 2 instructions)            │
└────────────┬───────────────────────────┘
             │
┌────────────▼───────────────────────────┐
│      Instruction Queue (8 entries)      │
│      Dependency Analysis               │
└─┬────────┬──────────┬──────────┬──────┘
  │        │          │          │
  ▼        ▼          ▼          ▼
┌───┐   ┌───┐      ┌───┐      ┌───┐
│ALU│   │ALU│      │AGU│      │LSU│
│ 0 │   │ 1 │      │   │      │   │
└─┬─┘   └─┬─┘      └─┬─┘      └─┬─┘
  │       │          │          │
  └───────┴──────────┴──────────┘
             │
      ┌──────▼──────┐
      │   Reorder   │
      │   Buffer    │
      │ (8 entries) │
      └──────┬──────┘
             │
      ┌──────▼──────┐
      │   Commit    │
      │   Stage     │
      └─────────────┘
```

**Execution Units:**
- **ALU0**: Integer arithmetic, logic operations
- **ALU1**: Integer arithmetic, logic operations (duplicate)
- **AGU**: Address Generation Unit (LEA, address calculations)
- **LSU**: Load-Store Unit (memory operations)

#### 3. Dependency Detection Hardware

**Register Scoreboard:**
```systemverilog
typedef struct {
    logic valid;
    logic [4:0] producer_id;  // Which ROB entry will produce this
    logic ready;
} reg_status_t;

reg_status_t data_reg_status[8];  // D0-D7
reg_status_t addr_reg_status[8];  // A0-A7
```

**Data Hazard Types:**
- **RAW (Read After Write)**: True dependency, must stall
- **WAR (Write After Read)**: Anti-dependency, can be solved with renaming
- **WAW (Write After Write)**: Output dependency, can be solved with renaming

#### 4. Reorder Buffer (ROB)
- 8-entry circular buffer
- Tracks in-flight instructions
- Ensures in-order commit
- Handles precise exceptions

```systemverilog
typedef struct {
    logic valid;
    logic [15:0] pc;
    logic complete;
    logic exception;
    logic [3:0] dest_reg;
    logic dest_is_areg;
    logic [31:0] result;
    logic [7:0] ccr_result;
} rob_entry_t;

rob_entry_t reorder_buffer[8];
```

#### 5. Instruction Issue Logic

**Issue Conditions:**
- Structural hazard: Execution unit available
- Data hazard: Operands ready (no RAW hazard)
- ROB slot: Space in reorder buffer

**Issue Algorithm:**
```
for each instruction in queue:
    if (execution_unit_free &&
        operands_ready &&
        rob_space_available):
        issue_to_execution_unit()
        update_scoreboard()
        allocate_rob_entry()
```

### Performance Estimates

**Theoretical IPC (Instructions Per Cycle):**
- Current FX68K: ~0.2-0.4 IPC (due to microcode overhead)
- Superscalar Target: 1.2-1.6 IPC

**Speedup Factors:**
- Integer operations: 2-3x faster
- Address calculations: 2x faster
- Memory operations: 1.5x faster (still limited by memory bandwidth)
- Overall: ~2x average speedup

### Implementation Challenges

#### 1. Microcode Elimination
- Remove microcode entirely
- Replace with hardwired decode logic
- Each instruction becomes 1-3 µops

#### 2. Bus Structure
- Current: Single shared bus
- Required: Multiple buses (2x data, 2x address)
- Register file: Multi-ported (4R/2W minimum)

#### 3. Memory System
- Current: Single memory port
- Required: Split I-cache and D-cache
- L1 cache: 4KB I-cache + 4KB D-cache
- Cache coherency protocol

#### 4. Exception Handling
- Must maintain precise exceptions
- ROB commits in-order
- Flush pipeline on exception

#### 5. Branch Prediction
- Static prediction: Backward branches taken
- Branch target buffer: 64 entries
- Flush penalty: 2-4 cycles

### Resource Requirements

**Logic Elements (Estimated):**
- Current FX68K: ~5,100 LEs
- Superscalar Version: ~15,000 LEs (3x increase)

**Memory:**
- Current: ~5KB RAM
- Superscalar: ~12KB RAM (I-cache + D-cache + ROB)

**Clock Speed:**
- Current: ~40 MHz typical
- Superscalar: ~30 MHz (more complex logic)

### Compatibility Impact

**BREAKS:**
- ❌ Cycle-accurate timing
- ❌ Instruction execution order visibility
- ❌ Timing-dependent software
- ❌ Hardware register timing

**PRESERVES:**
- ✓ Instruction set compatibility
- ✓ Functional behavior
- ✓ Exception model (with precise exceptions)
- ✓ Memory model

### Alternative: Soft Superscalar

A less invasive approach:
1. Keep microcode architecture
2. Add 2nd execution unit for independent µops
3. Limited out-of-order execution within µop sequence
4. Maintain cycle-accurate mode via configuration

**Advantages:**
- Partial speedup (1.3-1.5x)
- Maintains compatibility mode
- Smaller resource increase (~8,000 LEs)

**Disadvantages:**
- Limited parallelism
- Still microcoded overhead
- Complex control logic

## Conclusion

Converting FX68K to superscalar requires:
1. Complete architectural redesign
2. 3x resource increase
3. Loss of cycle-accurate compatibility
4. Estimated 2x performance gain

**Recommendation:**
- For Amiga compatibility: Keep current design
- For performance: Implement soft superscalar with compatibility mode
- For maximum performance: Full superscalar redesign (new core)
