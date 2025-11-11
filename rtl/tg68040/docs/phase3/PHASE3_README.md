# Phase 3: Pipeline Foundation

## Overview

**Phase:** 3 of 15
**Goal:** Implement the 6-stage MC68040 pipeline foundation
**Status:** In Progress
**Start Date:** 2025-11-11
**Target Completion:** 2025-11-21 (10 days)

## Objectives

1. ⏳ Design pipeline register structure for 6 stages
2. ⏳ Implement basic pipeline stages (IF, ID, EA, OF, EX, WB)
3. ⏳ Create instruction flow control without hazards
4. ⏳ Add pipeline flush mechanism
5. ⏳ Create pipeline visualization and testing

## MC68040 Pipeline Architecture

### Pipeline Stages

The MC68040 uses a 6-stage pipeline for improved instruction throughput:

```
┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐
│   IF   │ → │   ID   │ → │   EA   │ → │   OF   │ → │   EX   │ → │   WB   │
│ Instr  │   │ Instr  │   │  Eff   │   │ Operand│   │ Execute│   │ Write  │
│ Fetch  │   │ Decode │   │ Addr   │   │  Fetch │   │        │   │  Back  │
└────────┘   └────────┘   └────────┘   └────────┘   └────────┘   └────────┘
     ↑
     └────────────────── I-Cache (Phase 5-7) ──────────────────────────┘
```

**Stage 1: IF (Instruction Fetch)**
- Fetch instruction from I-cache (or memory)
- Update program counter
- Handle branch target fetch
- Detect instruction fetch exceptions

**Stage 2: ID (Instruction Decode)**
- Decode opcode and addressing modes
- Determine instruction type
- Read instruction-specific fields
- Check for illegal instructions

**Stage 3: EA (Effective Address)**
- Calculate effective addresses for operands
- Handle indexed addressing modes
- Process address register indirect modes
- Compute displacement + index

**Stage 4: OF (Operand Fetch)**
- Fetch source operands from memory/registers
- Handle D-cache access (future)
- Read register file
- Fetch immediate data

**Stage 5: EX (Execute)**
- Perform arithmetic/logical operations
- Execute special instructions (MOVE16, etc.)
- Generate condition codes
- Detect execution exceptions

**Stage 6: WB (Write Back)**
- Write results to registers
- Write results to memory
- Update flags
- Commit architectural state

### Pipeline Registers

Between each stage, pipeline registers hold the instruction state:

```
PC → [IF/ID] → Opcode → [ID/EA] → EA → [EA/OF] → Data → [OF/EX] → Result → [EX/WB] → Done
```

## Phase 3 Approach

### Simplifications for Phase 3

To build incrementally, Phase 3 implements a **basic pipeline without hazard detection**:

1. **No Hazard Handling** - Assume no data or control hazards (Phase 4)
2. **Simple Instructions Only** - Single-cycle operations initially
3. **No Caching** - Direct memory access (caches in Phase 5-7)
4. **Sequential Flow** - No branches initially, or flush on branch
5. **Register File Stall** - Simple register read/write timing

### Phase 3A: Pipeline Register Structure (Days 1-2)

**Deliverables:**
- Pipeline register definitions
- Stage state records
- Control signal propagation

**Data Structure:**
```vhdl
-- IF/ID Pipeline Register
type if_id_reg_t is record
    valid       : std_logic;
    pc          : std_logic_vector(31 downto 0);
    instruction : std_logic_vector(15 downto 0);
    exception   : std_logic;
end record;

-- ID/EA Pipeline Register
type id_ea_reg_t is record
    valid       : std_logic;
    pc          : std_logic_vector(31 downto 0);
    opcode      : std_logic_vector(15 downto 0);
    instr_type  : instr_type_t;
    src_reg     : std_logic_vector(3 downto 0);
    dst_reg     : std_logic_vector(3 downto 0);
    immediate   : std_logic_vector(31 downto 0);
    exception   : std_logic;
end record;

-- EA/OF Pipeline Register
type ea_of_reg_t is record
    valid       : std_logic;
    pc          : std_logic_vector(31 downto 0);
    instr_type  : instr_type_t;
    ea_addr     : std_logic_vector(31 downto 0);
    dst_reg     : std_logic_vector(3 downto 0);
    exception   : std_logic;
end record;

-- OF/EX Pipeline Register
type of_ex_reg_t is record
    valid       : std_logic;
    pc          : std_logic_vector(31 downto 0);
    instr_type  : instr_type_t;
    operand1    : std_logic_vector(31 downto 0);
    operand2    : std_logic_vector(31 downto 0);
    dst_reg     : std_logic_vector(3 downto 0);
    exception   : std_logic;
end record;

-- EX/WB Pipeline Register
type ex_wb_reg_t is record
    valid       : std_logic;
    pc          : std_logic_vector(31 downto 0);
    result      : std_logic_vector(31 downto 0);
    dst_reg     : std_logic_vector(3 downto 0);
    write_en    : std_logic;
    flags       : std_logic_vector(7 downto 0);
    exception   : std_logic;
end record;
```

### Phase 3B: Stage Implementation (Days 3-6)

**IF Stage:**
```vhdl
-- Instruction Fetch
process(clk)
begin
    if rising_edge(clk) then
        if flush = '1' then
            if_id.valid <= '0';
        elsif stall = '0' then
            if_id.valid <= '1';
            if_id.pc <= pc;
            if_id.instruction <= instruction_memory(pc);
            pc <= pc + 2;  -- Simple increment
        end if;
    end if;
end process;
```

**ID Stage:**
```vhdl
-- Instruction Decode
process(clk)
begin
    if rising_edge(clk) then
        if flush = '1' then
            id_ea.valid <= '0';
        elsif stall = '0' then
            id_ea.valid <= if_id.valid;
            id_ea.pc <= if_id.pc;
            id_ea.opcode <= if_id.instruction;
            -- Decode instruction type
            decode_instruction(if_id.instruction, id_ea.instr_type);
        end if;
    end if;
end process;
```

**EA Stage:**
```vhdl
-- Effective Address Calculation
process(clk)
begin
    if rising_edge(clk) then
        if flush = '1' then
            ea_of.valid <= '0';
        elsif stall = '0' then
            ea_of.valid <= id_ea.valid;
            ea_of.pc <= id_ea.pc;
            -- Calculate effective address
            calculate_ea(id_ea, ea_of.ea_addr);
        end if;
    end if;
end process;
```

**OF Stage:**
```vhdl
-- Operand Fetch
process(clk)
begin
    if rising_edge(clk) then
        if flush = '1' then
            of_ex.valid <= '0';
        elsif stall = '0' then
            of_ex.valid <= ea_of.valid;
            -- Fetch operands from registers or memory
            fetch_operands(ea_of, of_ex.operand1, of_ex.operand2);
        end if;
    end if;
end process;
```

**EX Stage:**
```vhdl
-- Execute
process(clk)
begin
    if rising_edge(clk) then
        if flush = '1' then
            ex_wb.valid <= '0';
        elsif stall = '0' then
            ex_wb.valid <= of_ex.valid;
            -- Execute operation
            execute_operation(of_ex, ex_wb.result, ex_wb.flags);
        end if;
    end if;
end process;
```

**WB Stage:**
```vhdl
-- Write Back
process(clk)
begin
    if rising_edge(clk) then
        if ex_wb.valid = '1' and ex_wb.write_en = '1' then
            -- Write to register file
            register_file(ex_wb.dst_reg) <= ex_wb.result;
        end if;
    end if;
end process;
```

### Phase 3C: Pipeline Control (Days 7-8)

**Stall Control:**
- Stall when memory not ready
- Stall when register file busy
- Propagate stall backwards through pipeline

**Flush Control:**
- Flush on branch taken
- Flush on exception
- Clear valid bits in all pipeline registers

**Control Signals:**
```vhdl
signal stall_if : std_logic;  -- Stall IF stage
signal stall_id : std_logic;  -- Stall ID stage
signal stall_ea : std_logic;  -- Stall EA stage
signal stall_of : std_logic;  -- Stall OF stage
signal stall_ex : std_logic;  -- Stall EX stage

signal flush_if : std_logic;  -- Flush IF stage
signal flush_id : std_logic;  -- Flush ID stage
signal flush_ea : std_logic;  -- Flush EA stage
signal flush_of : std_logic;  -- Flush OF stage
signal flush_ex : std_logic;  -- Flush EX stage
```

### Phase 3D: Testing (Days 9-10)

**Unit Tests:**
1. Pipeline register transfer tests
2. Single instruction through pipeline
3. Multiple sequential instructions
4. Pipeline flush test
5. Pipeline stall test

**Visualization:**
- Waveform showing instruction flow
- Pipeline stage occupancy display
- Timing diagram generation

## Deliverables

### Source Files

| File | Status | Description |
|------|--------|-------------|
| `TG68040_Pipeline.vhd` | ⏳ Planned | Top-level pipeline controller |
| `TG68040_Pipeline_Regs.vhd` | ⏳ Planned | Pipeline register definitions |
| `TG68040_IF_Stage.vhd` | ⏳ Planned | Instruction fetch stage |
| `TG68040_ID_Stage.vhd` | ⏳ Planned | Instruction decode stage |
| `TG68040_EA_Stage.vhd` | ⏳ Planned | Effective address stage |
| `TG68040_OF_Stage.vhd` | ⏳ Planned | Operand fetch stage |
| `TG68040_EX_Stage.vhd` | ⏳ Planned | Execute stage |
| `TG68040_WB_Stage.vhd` | ⏳ Planned | Write-back stage |

### Test Files

| File | Status | Description |
|------|--------|-------------|
| `test_Pipeline_Regs.vhd` | ⏳ Planned | Pipeline register tests |
| `test_Pipeline_Flow.vhd` | ⏳ Planned | Instruction flow tests |
| `test_Pipeline_Control.vhd` | ⏳ Planned | Stall/flush tests |

### Documentation

| Document | Status | Description |
|----------|--------|-------------|
| PHASE3_README.md | ✅ Complete | This file |
| PIPELINE_SPEC.md | ⏳ Planned | Detailed pipeline specification |
| TIMING_DIAGRAMS.md | ⏳ Planned | Pipeline timing analysis |
| PHASE3_SUMMARY.md | ⏳ Planned | Phase 3 completion report |

## Pipeline Timing Example

### Simple ADD Instruction Flow

```
Cycle:  1    2    3    4    5    6    7    8    9
       ┌────┬────┬────┬────┬────┬────┬────┬────┬────┐
ADD 1: │ IF │ ID │ EA │ OF │ EX │ WB │    │    │    │ ← Instruction 1
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
ADD 2: │    │ IF │ ID │ EA │ OF │ EX │ WB │    │    │ ← Instruction 2
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
ADD 3: │    │    │ IF │ ID │ EA │ OF │ EX │ WB │    │ ← Instruction 3
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
ADD 4: │    │    │    │ IF │ ID │ EA │ OF │ EX │ WB │ ← Instruction 4
       └────┴────┴────┴────┴────┴────┴────┴────┴────┘

Throughput: 1 instruction completes per cycle (after fill)
Latency: 6 cycles per instruction
Pipeline efficiency: 100% (no stalls or hazards)
```

### Branch Instruction with Flush

```
Cycle:  1    2    3    4    5    6    7    8    9
       ┌────┬────┬────┬────┬────┬────┬────┬────┬────┐
BRA:   │ IF │ ID │ EA │ OF │ EX │ WB │    │    │    │ ← Branch taken
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
ADD 1: │    │ IF │ ID │ EA │ OF │ XX │    │    │    │ ← Flushed
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
ADD 2: │    │    │ IF │ ID │ EA │ XX │    │    │    │ ← Flushed
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
ADD 3: │    │    │    │ IF │ ID │ XX │    │    │    │ ← Flushed
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
ADD 4: │    │    │    │    │ IF │ XX │    │    │    │ ← Flushed
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
TGT:   │    │    │    │    │    │ IF │ ID │ EA │ OF │ ← Branch target
       └────┴────┴────┴────┴────┴────┴────┴────┴────┘

Branch penalty: 5 cycles (instructions in pipeline flushed)
```

## Testing Strategy

### Test 1: Pipeline Register Propagation
```vhdl
-- Insert NOP through pipeline
-- Verify each stage receives valid data
-- Check pipeline register contents at each cycle
```

### Test 2: Sequential Instructions
```vhdl
-- Load 4 ADD instructions
-- Verify overlapped execution
-- Check results appear in order
-- Measure throughput (should be 1 per cycle after fill)
```

### Test 3: Pipeline Flush
```vhdl
-- Execute branch instruction
-- Verify all following instructions flushed
-- Check pipeline empties correctly
-- Verify branch target fetched
```

### Test 4: Pipeline Stall
```vhdl
-- Trigger memory not ready
-- Verify pipeline stalls correctly
-- Check no instructions lost
-- Verify resume after stall clears
```

## Performance Metrics

### Target Performance

| Metric | Target | Notes |
|--------|--------|-------|
| CPI (Cycles Per Instruction) | 1.0 | After pipeline fill, no hazards |
| Pipeline Fill Time | 5 cycles | First instruction takes 6 cycles total |
| Branch Penalty | 5 cycles | Instructions in pipeline flushed |
| Stall Overhead | 1 cycle | Per stall condition |
| Throughput | 1 instr/cycle | Steady state |

### Compared to TG68K

| Aspect | TG68K | TG68040 (Phase 3) | Improvement |
|--------|-------|-------------------|-------------|
| Architecture | Microcode | 6-stage pipeline | Modern |
| CPI Average | ~4-8 | ~1.0 (ideal) | 4-8x |
| Branch Handling | Immediate | 5-cycle penalty | Different |
| Parallelism | Sequential | Overlapped | Yes |

## Known Limitations (Phase 3)

1. **No Hazard Detection** - RAW/WAW/WAR hazards not handled (Phase 4)
2. **No Forwarding** - Data forwarding not implemented (Phase 4)
3. **Simple Instructions** - Complex multi-cycle ops not fully pipelined
4. **No Branch Prediction** - All branches flush pipeline
5. **No Caching** - Direct memory access (Phase 5-7)

These are intentional Phase 3 limitations.

## Integration with Previous Phases

### Phase 1 Integration (Control Registers)
- Pipeline uses register file from Phase 1
- CACR controls pipeline behavior
- VBR used for exception handling

### Phase 2 Integration (New Instructions)
- MOVE16 executes in EX stage (multi-cycle)
- Cache ops trigger pipeline flush
- Instruction types from Phase 2 decoded in ID

## Success Criteria

- [ ] Pipeline registers transfer data correctly
- [ ] Single instruction completes in 6 cycles
- [ ] Multiple instructions overlap correctly
- [ ] Pipeline achieves 1 instruction/cycle throughput
- [ ] Flush mechanism works
- [ ] Stall mechanism works
- [ ] All unit tests pass
- [ ] Timing diagrams generated
- [ ] Documentation complete

## Next Steps (Phase 4)

After Phase 3:
1. Add hazard detection logic
2. Implement data forwarding paths
3. Handle RAW/WAW/WAR hazards
4. Optimize pipeline stalls
5. Add hazard unit tests

## References

1. MC68040 User's Manual, Section 5: Pipeline
2. Computer Architecture: A Quantitative Approach (Hennessy & Patterson)
3. TG68K microcode implementation
4. Digital Design and Computer Architecture (Harris & Harris)

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** In Progress
