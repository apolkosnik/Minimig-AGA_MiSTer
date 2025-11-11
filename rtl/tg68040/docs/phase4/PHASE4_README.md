# Phase 4: Hazard Detection and Data Forwarding

## Overview

**Phase:** 4 of 15
**Goal:** Implement pipeline hazard detection and data forwarding
**Status:** In Progress
**Start Date:** 2025-11-11
**Target Completion:** 2025-11-21 (10 days)

## Objectives

1. ⏳ Design hazard detection unit
2. ⏳ Implement RAW (Read After Write) hazard detection
3. ⏳ Implement WAW (Write After Write) hazard detection
4. ⏳ Implement WAR (Write After Read) hazard detection
5. ⏳ Add data forwarding paths
6. ⏳ Add forwarding multiplexers in OF stage
7. ⏳ Optimize pipeline stalls
8. ⏳ Create hazard unit tests

## Pipeline Hazards in MC68040

### What are Hazards?

Pipeline hazards occur when the next instruction cannot execute in the following clock cycle due to data or control dependencies. There are three types:

1. **RAW (Read After Write)** - Data Hazard
2. **WAW (Write After Write)** - Data Hazard
3. **WAR (Write After Read)** - Data Hazard
4. **Control Hazards** - Branch/Jump instructions (Phase 8)

### Example: RAW Hazard

```
Cycle:  1    2    3    4    5    6    7    8
       ┌────┬────┬────┬────┬────┬────┬────┬────┐
ADD:   │ IF │ ID │ EA │ OF │ EX │ WB │    │    │  ← D0 = D1 + D2
       ├────┼────┼────┼────┼────┼────┼────┼────┤
SUB:   │    │ IF │ ID │ EA │ OF │ EX │ WB │    │  ← D3 = D0 - D4
       └────┴────┴────┴────┴────┴────┴────┴────┘
                            ^
                            └─ Hazard! SUB reads D0 before ADD writes it
```

**Problem:** SUB needs D0 in cycle 5 (OF stage), but ADD doesn't write D0 until cycle 6 (WB stage).

**Solutions:**
1. **Stall** - Insert bubbles until data is ready (slow)
2. **Forward** - Bypass data from EX or WB stage (fast)

## Phase 4 Approach

### Hazard Detection Unit

The hazard detection unit monitors all pipeline stages and detects when:
- An instruction in OF stage reads a register
- A previous instruction in EX or WB stage will write that register

```vhdl
type hazard_info_t is record
    raw_hazard      : std_logic;  -- Read After Write detected
    waw_hazard      : std_logic;  -- Write After Write detected
    war_hazard      : std_logic;  -- Write After Read detected
    stall_required  : std_logic;  -- Must stall pipeline
    forward_ex_a    : std_logic;  -- Forward from EX stage to operand A
    forward_ex_b    : std_logic;  -- Forward from EX stage to operand B
    forward_wb_a    : std_logic;  -- Forward from WB stage to operand A
    forward_wb_b    : std_logic;  -- Forward from WB stage to operand B
end record;
```

### Data Forwarding Paths

Forwarding allows results to bypass the register file:

```
         ┌─────────────────────────────────┐
         │                                 │
         │    ┌────────────────────┐       │
         │    │                    │       │
         ↓    ↓                    ↓       │
    ┌────────┬────────┬────────┬────────┬────────┬────────┐
    │   IF   │   ID   │   EA   │   OF   │   EX   │   WB   │
    └────────┴────────┴────────┴────────┴────────┴────────┘
                                   ↑         │       │
                                   │         │       │
                                   └─────────┴───────┘
                                   Forwarding Paths
```

**Three forwarding paths:**
1. **EX → OF**: Forward result from EX stage to OF stage (1 cycle penalty avoided)
2. **WB → OF**: Forward result from WB stage to OF stage (2 cycle penalty avoided)
3. **MEM → OF**: For memory operations (Phase 5+)

### RAW Hazard Detection

**Detection Logic:**
```vhdl
-- Check if instruction in OF stage reads register that EX stage will write
raw_ex_a <= '1' when (of_ex.write_reg = '1' and
                      of_ex.dst_reg = id_ea.src_reg1 and
                      id_ea.src_reg1 /= "0000") else '0';

raw_ex_b <= '1' when (of_ex.write_reg = '1' and
                      of_ex.dst_reg = id_ea.src_reg2 and
                      id_ea.src_reg2 /= "0000") else '0';

-- Check if instruction in OF stage reads register that WB stage will write
raw_wb_a <= '1' when (ex_wb.write_reg = '1' and
                      ex_wb.dst_reg = id_ea.src_reg1 and
                      id_ea.src_reg1 /= "0000") else '0';

raw_wb_b <= '1' when (ex_wb.write_reg = '1' and
                      ex_wb.dst_reg = id_ea.src_reg2 and
                      id_ea.src_reg2 /= "0000") else '0';
```

**Forwarding Decision:**
```vhdl
-- Priority: Forward from EX if possible (most recent), else from WB
if raw_ex_a = '1' then
    operand1_mux <= of_ex.result;  -- Forward from EX
elsif raw_wb_a = '1' then
    operand1_mux <= ex_wb.result;  -- Forward from WB
else
    operand1_mux <= reg_data_a;    -- Use register file
end if;
```

### WAW Hazard Detection

**Detection Logic:**
```vhdl
-- Two instructions writing to same register
waw_hazard <= '1' when (id_ea.write_reg = '1' and
                        ea_of.write_reg = '1' and
                        id_ea.dst_reg = ea_of.dst_reg) else '0';
```

**Solution:** In MC68040 pipeline, WAW hazards are rare but handled by ensuring writes occur in order.

### WAR Hazard Detection

**Detection Logic:**
```vhdl
-- Later instruction writes register before earlier instruction reads it
war_hazard <= '1' when (ea_of.write_reg = '1' and
                        id_ea.read_reg = '1' and
                        ea_of.dst_reg = id_ea.src_reg) else '0';
```

**Solution:** In-order execution naturally prevents WAR hazards in this pipeline.

## Phase 4A: Hazard Detection Unit (Days 1-3)

**Deliverables:**
- `TG68040_HazardUnit.vhd` - Hazard detection logic
- Hazard type enumeration
- Forwarding control signals

**Entity:**
```vhdl
entity TG68040_HazardUnit is
    port(
        -- Pipeline stage inputs
        id_ea_valid    : in std_logic;
        id_ea_src_reg1 : in std_logic_vector(3 downto 0);
        id_ea_src_reg2 : in std_logic_vector(3 downto 0);

        ea_of_valid    : in std_logic;
        ea_of_dst_reg  : in std_logic_vector(3 downto 0);
        ea_of_write    : in std_logic;

        of_ex_valid    : in std_logic;
        of_ex_dst_reg  : in std_logic_vector(3 downto 0);
        of_ex_write    : in std_logic;

        ex_wb_valid    : in std_logic;
        ex_wb_dst_reg  : in std_logic_vector(3 downto 0);
        ex_wb_write    : in std_logic;

        -- Hazard outputs
        hazard_info    : out hazard_info_t;

        -- Control outputs
        stall_if       : out std_logic;
        stall_id       : out std_logic
    );
end TG68040_HazardUnit;
```

## Phase 4B: Data Forwarding Implementation (Days 4-6)

**Deliverables:**
- Forwarding multiplexers in OF stage
- Forwarding path connections
- Updated pipeline to use forwarding

**Forwarding Multiplexer:**
```vhdl
-- Operand A forwarding
process(hazard_info, reg_data_a, of_ex.result, ex_wb.result)
begin
    if hazard_info.forward_ex_a = '1' then
        operand1_forwarded <= of_ex.result;
    elsif hazard_info.forward_wb_a = '1' then
        operand1_forwarded <= ex_wb.result;
    else
        operand1_forwarded <= reg_data_a;
    end if;
end process;

-- Operand B forwarding
process(hazard_info, reg_data_b, of_ex.result, ex_wb.result)
begin
    if hazard_info.forward_ex_b = '1' then
        operand2_forwarded <= of_ex.result;
    elsif hazard_info.forward_wb_b = '1' then
        operand2_forwarded <= ex_wb.result;
    else
        operand2_forwarded <= reg_data_b;
    end if;
end process;
```

## Phase 4C: Pipeline Integration (Days 7-8)

**Deliverables:**
- Integrate hazard unit into pipeline
- Connect forwarding paths
- Update pipeline control logic
- Remove unnecessary stalls

**Integration:**
```vhdl
-- Instantiate hazard unit
hazard_unit: TG68040_HazardUnit
    port map(
        id_ea_valid    => id_ea.valid,
        id_ea_src_reg1 => id_ea.src_reg1,
        id_ea_src_reg2 => id_ea.src_reg2,
        ea_of_valid    => ea_of.valid,
        ea_of_dst_reg  => ea_of.dst_reg,
        ea_of_write    => ea_of.write_reg,
        of_ex_valid    => of_ex.valid,
        of_ex_dst_reg  => of_ex.dst_reg,
        of_ex_write    => of_ex.write_reg,
        ex_wb_valid    => ex_wb.valid,
        ex_wb_dst_reg  => ex_wb.dst_reg,
        ex_wb_write    => ex_wb.write_reg,
        hazard_info    => hazard_info,
        stall_if       => hazard_stall_if,
        stall_id       => hazard_stall_id
    );
```

## Phase 4D: Testing (Days 9-10)

**Unit Tests:**
1. RAW hazard detection test
2. EX → OF forwarding test
3. WB → OF forwarding test
4. No hazard (normal operation) test
5. Multiple hazards test
6. Performance comparison test

**Test Scenarios:**

**Test 1: RAW Hazard with EX Forwarding**
```assembly
ADD D1, D2, D0    ; D0 = D1 + D2
SUB D0, D3, D4    ; D4 = D0 - D3  (reads D0 from previous instruction)
```

Expected: Forward result from EX stage, no stall

**Test 2: RAW Hazard with WB Forwarding**
```assembly
ADD D1, D2, D0    ; D0 = D1 + D2
NOP               ; Bubble
SUB D0, D3, D4    ; D4 = D0 - D3  (reads D0 two instructions back)
```

Expected: Forward result from WB stage, no stall

**Test 3: Back-to-back Dependencies**
```assembly
ADD D1, D2, D0    ; D0 = D1 + D2
ADD D0, D3, D5    ; D5 = D0 + D3
ADD D5, D4, D6    ; D6 = D5 + D4
```

Expected: Multiple forwarding, no stalls

## Performance Metrics

### Without Hazard Detection (Phase 3)

```
ADD D1, D2, D0    ; Completes cycle 6
SUB D0, D3, D4    ; Must stall 3 cycles, completes cycle 13
CPI = 13/2 = 6.5 cycles per instruction
```

### With Hazard Detection + EX Forwarding (Phase 4)

```
ADD D1, D2, D0    ; Completes cycle 6
SUB D0, D3, D4    ; Gets forwarded data, completes cycle 7
CPI = 7/2 = 3.5 cycles per instruction
```

### With Full Forwarding (Phase 4)

```
ADD D1, D2, D0    ; Completes cycle 6
SUB D0, D3, D4    ; Completes cycle 7 (no stall)
ADD D4, D5, D6    ; Completes cycle 8 (no stall)
CPI = 8/3 = 2.67 cycles per instruction
```

**Target:** Average CPI of 1.5-2.0 with typical code (approaching ideal 1.0)

## Deliverables

### Source Files

| File | Status | Description |
|------|--------|-------------|
| `TG68040_HazardUnit.vhd` | ⏳ Planned | Hazard detection logic |
| `TG68040_Pipeline.vhd` (updated) | ⏳ Planned | Add forwarding multiplexers |
| `TG68040_Pipeline_Regs.vhd` (updated) | ⏳ Planned | Add hazard info type |

### Test Files

| File | Status | Description |
|------|--------|-------------|
| `test_HazardUnit.vhd` | ⏳ Planned | Hazard detection tests |
| `test_Forwarding.vhd` | ⏳ Planned | Data forwarding tests |
| `test_Pipeline_Performance.vhd` | ⏳ Planned | Performance benchmarks |

### Documentation

| Document | Status | Description |
|----------|--------|-------------|
| PHASE4_README.md | ✅ Complete | This file |
| HAZARD_SPEC.md | ⏳ Planned | Detailed hazard specification |
| PHASE4_SUMMARY.md | ⏳ Planned | Phase 4 completion report |

## Example: Hazard Detection in Action

### Scenario: Three Dependent Instructions

```assembly
1. ADD  D1, D2, D0    ; D0 = D1 + D2
2. SUB  D0, D3, D4    ; D4 = D0 - D3
3. MOVE D4, D5        ; D5 = D4
```

### Pipeline Execution Timeline

```
Cycle:  1    2    3    4    5    6    7    8    9
       ┌────┬────┬────┬────┬────┬────┬────┬────┬────┐
ADD:   │ IF │ ID │ EA │ OF │ EX │ WB │    │    │    │
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
SUB:   │    │ IF │ ID │ EA │ OF │ EX │ WB │    │    │
       │    │    │    │    │ ↑  │    │    │    │    │
       │    │    │    │    │ └─ Forward from EX
       ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
MOVE:  │    │    │ IF │ ID │ EA │ OF │ EX │ WB │    │
       │    │    │    │    │    │ ↑  │    │    │    │
       │    │    │    │    │    │ └─ Forward from EX
       └────┴────┴────┴────┴────┴────┴────┴────┴────┘

Throughput: 3 instructions in 9 cycles = 3.0 CPI (vs 6+ without forwarding)
```

## Known Limitations (Phase 4)

1. **No Load-Use Hazard Handling** - Memory loads (Phase 5+) may need stalls
2. **No Branch Prediction** - Branch hazards (Phase 8)
3. **Simple Instructions Only** - Complex multi-cycle operations not yet handled
4. **No Memory Forwarding** - Forwarding from memory operations (Phase 5+)

These are intentional Phase 4 limitations.

## Integration with Previous Phases

### Phase 1 Integration (Control Registers)
- Hazard detection respects register dependencies
- Control registers accessed through hazard-aware paths

### Phase 2 Integration (New Instructions)
- MOVE16 treated as multi-cycle, may stall pipeline
- Cache operations respect hazard detection

### Phase 3 Integration (Pipeline)
- Hazard unit integrated into existing pipeline
- Forwarding paths added to OF stage
- Control logic extended with hazard signals

## Success Criteria

- [ ] RAW hazard detection working
- [ ] EX → OF forwarding working
- [ ] WB → OF forwarding working
- [ ] WAW hazard detection working
- [ ] WAR hazard detection working
- [ ] Pipeline achieves <2.0 CPI for dependent instructions
- [ ] All unit tests pass
- [ ] Performance improvement measured
- [ ] Documentation complete

## Next Steps (Phase 5)

After Phase 4:
1. Implement instruction cache stub
2. Add cache hit/miss handling
3. Handle load-use hazards with memory
4. Add memory forwarding paths
5. Optimize cache interface

## References

1. MC68040 User's Manual, Section 5: Pipeline & Hazards
2. Computer Architecture: A Quantitative Approach (Hennessy & Patterson) - Chapter 3: Pipelining
3. Digital Design and Computer Architecture (Harris & Harris) - Chapter 7: Microarchitecture
4. "Pipelining: Basic and Intermediate Concepts" - Computer Architecture textbooks

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** In Progress
