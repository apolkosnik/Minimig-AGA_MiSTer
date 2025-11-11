# Phase 13: F-Line Memory Interface Design

**Goal**: Enable PMOVE instructions with memory effective addresses

**Status**: Design phase
**Date**: 2025-11-11

---

## Problem Statement

Currently, PMOVE only supports register-to-register operations:

```assembly
PMOVE TC,D0      ; ✅ Works - register EA
PMOVE D0,TC      ; ✅ Works - register EA
PMOVE TC,(A0)    ; ❌ Fails - memory EA (address not available)
PMOVE (A0),TC    ; ❌ Fails - memory EA (data not available)
```

### Current Architecture Gap

The TG68KdotC_Kernel F-line interface (added in Phase 10) provides:

```vhdl
-- F-line interface in TG68KdotC_Kernel
fline_is_mmu     : in  std_logic;   -- MMU instruction detected
fline_is_pmove   : in  std_logic;   -- PMOVE detected
fline_is_pflush  : in  std_logic;   -- PFLUSH detected
fline_is_ptest   : in  std_logic;   -- PTEST detected
fline_exec_req   : out std_logic;   -- Request execution
fline_exec_done  : in  std_logic;   -- Execution complete
```

**Missing**:
- Effective address output
- Memory data access
- Bus control for memory operations

### Current Stub in cpu_wrapper.v

```verilog
// PMOVE Executor (lines 636-667)
TG68K030_PMOVE_Execute pmove_exec
(
    // ... other ports ...
    .mem_addr(32'h00000000),        // ❌ Hardcoded!
    .mem_data_in(32'h00000000),     // ❌ Hardcoded!
    .mem_data_out(),                // ❌ Unconnected
    .mem_read(),                    // ❌ Unconnected
    .mem_write(),                   // ❌ Unconnected
    .mem_size(),                    // ❌ Unconnected
    .mem_ready(stub_mem_ready),     // ❌ Always ready (1'b1)
    // ...
);
```

---

## Design Options

### Option 1: Enhance F-Line Interface ⭐ (Recommended for Phase 13)

**Approach**: Add EA and memory access ports to TG68KdotC_Kernel's F-line interface

**Changes Required**:

#### 1.1 Modify TG68KdotC_Kernel Entity

```vhdl
-- rtl/tg68k/TG68KdotC_Kernel.vhd
-- Add to port list (after line 148):

-- MC68030 F-line MMU instruction interface
    fline_is_mmu        : in  std_logic:='0';
    fline_is_pmove      : in  std_logic:='0';
    fline_is_pflush     : in  std_logic:='0';
    fline_is_ptest      : in  std_logic:='0';
    fline_exec_req      : out std_logic;
    fline_exec_done     : in  std_logic:='0';

    -- NEW: F-line memory interface
    fline_ea            : out std_logic_vector(31 downto 0);  -- Effective address
    fline_ea_valid      : out std_logic;                       -- EA calculated and valid
    fline_mem_req       : in  std_logic:='0';                  -- F-line requests memory access
    fline_mem_write     : in  std_logic:='0';                  -- 0=read, 1=write
    fline_mem_size      : in  std_logic_vector(1 downto 0):="00";  -- Transfer size
    fline_mem_dataout   : in  std_logic_vector(63 downto 0):=(others=>'0');  -- Data to write
    fline_mem_datain    : out std_logic_vector(63 downto 0);  -- Data read
    fline_mem_done      : out std_logic                        -- Memory operation complete
);
```

#### 1.2 Modify TG68KdotC_Kernel Implementation

In the `fline_exec1` state (around line 4012):

```vhdl
WHEN fline_exec1 =>
    -- MC68030 F-line MMU instruction execution
    -- External decoder/executor handles the instruction

    -- NEW: Provide EA to F-line executor
    fline_ea <= memaddr;           -- Current effective address
    fline_ea_valid <= '1';         -- Mark as valid

    -- NEW: Handle memory requests from F-line executor
    IF fline_mem_req = '1' THEN
        -- F-line executor needs memory access
        IF fline_mem_write = '1' THEN
            -- Write to memory
            memaddr <= fline_ea;
            data_write <= fline_mem_dataout(15 downto 0);  -- or appropriate slice
            setstate <= "01";  -- Write state
            -- Handle multi-word transfers based on fline_mem_size
        ELSE
            -- Read from memory
            memaddr <= fline_ea;
            setstate <= "10";  -- Read state
        END IF;
    ELSIF fline_exec_done = '1' THEN
        -- F-line execution complete
        next_micro_state <= idle;
        set_exec := '1';
    END IF;
```

#### 1.3 Update cpu_wrapper.v

```verilog
// Add new F-line interface signals
wire [31:0] fline_ea;
wire fline_ea_valid;
wire fline_mem_req;
wire fline_mem_write;
wire [1:0] fline_mem_size;
wire [63:0] fline_mem_dataout;
wire [63:0] fline_mem_datain;
wire fline_mem_done;

// Connect to TG68KdotC_Kernel
TG68KdotC_Kernel cpu_inst_p
(
    // ... existing ports ...
    .fline_is_mmu(fline_is_mmu & cpucfg[1]),
    .fline_is_pmove(fline_is_pmove & cpucfg[1]),
    .fline_is_pflush(fline_is_pflush & cpucfg[1]),
    .fline_is_ptest(fline_is_ptest & cpucfg[1]),
    .fline_exec_req(fline_exec_req),
    .fline_exec_done(fline_exec_done),

    // NEW: Memory interface
    .fline_ea(fline_ea),
    .fline_ea_valid(fline_ea_valid),
    .fline_mem_req(fline_mem_req),
    .fline_mem_write(fline_mem_write),
    .fline_mem_size(fline_mem_size),
    .fline_mem_dataout(fline_mem_dataout),
    .fline_mem_datain(fline_mem_datain),
    .fline_mem_done(fline_mem_done)
);

// Connect to PMOVE executor
TG68K030_PMOVE_Execute pmove_exec
(
    // ... existing ports ...
    .mem_addr(fline_ea),              // ✅ From TG68K EA calculation
    .mem_data_in(fline_mem_datain),   // ✅ From TG68K memory read
    .mem_data_out(fline_mem_dataout), // ✅ To TG68K memory write
    .mem_read(pmove_mem_read),        // ✅ Connected
    .mem_write(pmove_mem_write),      // ✅ Connected
    .mem_size(pmove_mem_size),        // ✅ Connected
    .mem_ready(fline_mem_done),       // ✅ From TG68K
    // ...
);

// Memory request combiner
assign fline_mem_req = pmove_mem_read | pmove_mem_write |
                       pflush_mem_read | pflush_mem_write |
                       ptest_mem_read | ptest_mem_write;
assign fline_mem_write = pmove_mem_write | pflush_mem_write | ptest_mem_write;
assign fline_mem_size = pmove_mem_size;  // Priority: PMOVE
```

**Advantages**:
- ✅ Cleanest architectural solution
- ✅ Provides full memory access to F-line instructions
- ✅ Reuses TG68K's existing EA calculation
- ✅ Minimal code duplication

**Disadvantages**:
- ⚠️ Requires modifying TG68KdotC_Kernel (but minimal changes)
- ⚠️ Adds ~8 ports to TG68KdotC_Kernel entity

**Effort**: 6-8 hours

---

### Option 2: Simple EA Calculator (Quick & Dirty)

**Approach**: Implement standalone EA calculator for common modes only

**Changes Required**:

Create `TG68K030_Simple_EA_Calc.vhd` that handles:
- Dn, An (register direct) - already works
- (An) (address register indirect)
- (An)+ (postincrement)
- -(An) (predecrement)
- d16(An) (displacement)

**Advantages**:
- ✅ No changes to TG68KdotC_Kernel
- ✅ Quick implementation

**Disadvantages**:
- ❌ Code duplication (EA calculation logic already exists in TG68K)
- ❌ Limited addressing modes
- ❌ May not match TG68K's EA timing exactly
- ❌ Doesn't integrate with TG68K's memory bus

**Effort**: 4-5 hours

**Not recommended** - partial solution, tech debt

---

### Option 3: Use TG68K030 Wrapper (Phase 14)

**Approach**: Integrate full TG68K030 wrapper which handles all of this

**Status**: Deferred to Phase 14

The TG68K030 wrapper was designed to:
- Wrap TG68KdotC_Kernel completely
- Provide 32-bit memory interface
- Handle all F-line EA calculations
- Manage MMU, caches, and burst mode

**Advantages**:
- ✅ Complete solution
- ✅ Handles all MC68030 features
- ✅ Proper architecture

**Disadvantages**:
- ❌ Requires data bus adapter (16-bit TG68K ↔ 32-bit wrapper)
- ❌ Major integration effort
- ❌ Can't test incrementally

**Effort**: 20-30 hours (full Phase 14)

---

## Recommended Approach: Option 1

**Phase 13 Plan**: Enhance F-Line Interface

### Implementation Steps

1. **Modify TG68KdotC_Kernel.vhd** (2 hours)
   - Add 8 new ports to entity
   - Implement EA export in fline_exec1 state
   - Implement memory request handler

2. **Update cpu_wrapper.v** (2 hours)
   - Add new signal declarations
   - Connect new ports to TG68KdotC_Kernel
   - Wire PMOVE executor to new interface
   - Remove stub connections

3. **Test Register Modes** (1 hour)
   - Verify existing register operations still work
   - Test with `PMOVE TC,D0`, `PMOVE D0,TC`

4. **Test Memory Modes** (2-3 hours)
   - Test `PMOVE TC,(A0)`
   - Test `PMOVE (A0),TC`
   - Test `PMOVE TC,-(A7)` (stack operations)
   - Test `PMOVE (A7)+,TC`
   - Test with 64-bit registers (CRP, SRP)

5. **Documentation** (1 hour)
   - Update PMOVE.md
   - Update PROJECT_STATUS_FINAL.md
   - Create test results document

**Total Effort**: 8-10 hours

---

## Testing Strategy

### Test Program 1: Memory Write

```assembly
; test_pmove_memwrite.asm
; Write TC register to memory

    MOVE.L  #$12345678,D0
    PMOVE   D0,TC              ; Load TC with test value

    LEA     test_buffer,A0
    PMOVE   TC,(A0)            ; Write TC to memory

    ; Verify
    MOVE.L  (A0),D1            ; Read back
    CMP.L   D0,D1              ; Should match
    BNE     error

    RTS

test_buffer:
    DC.L    0                  ; Buffer for TC value

error:
    ILLEGAL
```

### Test Program 2: Memory Read

```assembly
; test_pmove_memread.asm
; Read TC register from memory

test_value:
    DC.L    $87654321          ; Test value in memory

start:
    LEA     test_value,A0
    PMOVE   (A0),TC            ; Load TC from memory

    PMOVE   TC,D0              ; Read back
    MOVE.L  (A0),D1            ; Compare with original
    CMP.L   D0,D1              ; Should match
    BNE     error

    RTS

error:
    ILLEGAL
```

### Test Program 3: Stack Operations

```assembly
; test_pmove_stack.asm
; Test PMOVE with stack addressing

start:
    MOVE.L  #$11111111,D0
    MOVE.L  #$22222222,D1

    ; Push CRP to stack
    PMOVE   D0-D1,CRP          ; Load CRP with test values
    PMOVE   CRP,-(A7)          ; Push to stack (8 bytes)

    ; Pop back
    PMOVE   (A7)+,CRP          ; Pop from stack

    ; Verify
    PMOVE   CRP,D2-D3
    CMP.L   D0,D2
    BNE     error
    CMP.L   D1,D3
    BNE     error

    RTS

error:
    ILLEGAL
```

---

## Success Criteria

Phase 13 is complete when:

- ✅ F-line interface enhanced with EA and memory ports
- ✅ PMOVE supports all standard addressing modes
- ✅ Memory read operations work (`PMOVE (An),TC`)
- ✅ Memory write operations work (`PMOVE TC,(An)`)
- ✅ Stack operations work (`PMOVE TC,-(A7)`)
- ✅ 64-bit register operations work with memory
- ✅ All test programs pass
- ✅ No regression in existing register operations

---

## Impact on Other F-Line Instructions

Once the enhanced interface is implemented:

### PFLUSH Benefits
- Can use memory EA for address specification
- Currently stubbed, but interface ready

### PTEST Benefits
- Can specify test address via memory EA
- Can write result to memory
- Currently stubbed, but interface ready

---

## File Modifications Summary

| File | Changes | Lines |
|------|---------|-------|
| `rtl/tg68k/TG68KdotC_Kernel.vhd` | Add 8 ports, modify fline_exec1 | +30 |
| `rtl/cpu_wrapper.v` | Connect new interface | +15 |
| **Total** | | **~45 lines** |

---

## Risk Assessment

**Low Risk**:
- Changes are localized to F-line interface
- Existing TG68K operation unaffected (new ports have defaults)
- Can test incrementally

**Mitigation**:
- Keep existing register operations working first
- Add memory support incrementally
- Test each addressing mode individually

---

## Next Steps

1. **Review this design** - Ensure approach is sound
2. **Implement TG68KdotC_Kernel changes** - Add new ports
3. **Update cpu_wrapper.v** - Wire new interface
4. **Test incrementally** - Register modes first, then memory
5. **Document results** - Update project status

---

## References

- MC68030 User's Manual, Section 6.3 (PMOVE instruction)
- TG68KdotC_Kernel.vhd, fline_exec1 state (line 4012)
- cpu_wrapper.v, PMOVE executor (line 636)
- docs/mc68030/instructions/PMOVE.md

---

**Status**: Design complete, ready for implementation
**Estimated Completion**: 94% → 96% (Phase 13)
