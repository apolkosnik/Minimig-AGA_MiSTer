# Phase 12: Instruction Set Completion

## Overview

**Phase:** 12 of 15
**Goal:** Implement comprehensive MC68040 instruction set
**Status:** Planning
**Dependencies:** Phases 1-11 (all complete)
**Estimated Duration:** 3-4 sessions

---

## Current Status

### Currently Implemented Instructions

Based on Phase 3 baseline and subsequent additions:

1. **No Operation:**
   - `NOP` (0x4E71) - No operation

2. **Arithmetic (Basic):**
   - `ADD Dn,Dn` (0xDxxx) - Register-to-register add
   - `SUB Dn,Dn` (0x9xxx) - Register-to-register subtract

3. **Data Movement (Basic):**
   - `MOVE` (0x1xxx, 0x2xxx, 0x3xxx) - Register direct only, simplified

4. **Exception Handling:**
   - `RTE` (0x4E73) - Return from exception (Phase 11D)

5. **Floating Point (Stub):**
   - F-line instructions (0xFxxx) - Stub FADD only

6. **Miscellaneous:**
   - 0x4xxx opcodes - Treated as miscellaneous (RTS stub)

7. **Exception-Triggering:**
   - Line A (0xAxxx) - Illegal instruction exception
   - `ILLEGAL` (0x4AFC) - Illegal instruction
   - Privileged instructions in user mode

### Current Limitations

- **Very limited instruction set** (~5 instructions implemented)
- **No addressing modes** beyond register direct
- **No multiply/divide implementation**
- **No bit manipulation**
- **No shift/rotate**
- **No proper branch instructions**
- **No stack operations** (LINK/UNLK)
- **No extended moves** (MOVEA, MOVEQ, MOVEM, LEA, PEA)

---

## Implementation Strategy

### Phase 12A: Arithmetic and Logical Operations

**Goal:** Implement core ALU operations

**Instructions to Implement:**
1. `AND` - Logical AND (0xCxxx)
2. `OR` - Logical OR (0x8xxx)
3. `EOR` - Logical Exclusive OR (0xBxxx)
4. `NOT` - Logical complement (0x4600)
5. `NEG` - Negate (0x4400)
6. `NEGX` - Negate with extend (0x4000)
7. `CLR` - Clear operand (0x4200)
8. `TST` - Test operand (0x4A00)
9. `CMP` - Compare (0xBxxx)
10. `CMPA` - Compare address (0xBxC0/0xBxC8)
11. `CMPI` - Compare immediate (0x0C00)
12. `ADDA` - Add to address register (0xDxC0/0xDxC8)
13. `SUBA` - Subtract from address register (0x9xC0/0x9xC8)

**CCR Updates:**
- Properly set N (negative), Z (zero), V (overflow), C (carry), X (extend)
- Implement overflow detection
- Implement carry/borrow propagation

**Estimated Lines:** ~200 lines

---

### Phase 12B: Shift and Rotate Operations

**Goal:** Implement shift/rotate instructions

**Instructions to Implement:**
1. `ASL` - Arithmetic shift left (0xE100-0xE1FF)
2. `ASR` - Arithmetic shift right (0xE000-0xE0FF)
3. `LSL` - Logical shift left (0xE108-0xE1FF)
4. `LSR` - Logical shift right (0xE008-0xE0FF)
5. `ROL` - Rotate left (0xE118-0xE1FF)
6. `ROR` - Rotate right (0xE018-0xE0FF)
7. `ROXL` - Rotate left with extend (0xE110-0xE1FF)
8. `ROXR` - Rotate right with extend (0xE010-0xE0FF)

**Features:**
- Register shifts (Dn)
- Memory shifts (single bit)
- Immediate shift counts (1-8)
- Register shift counts (Dn)
- CCR updates (N, Z, V=0, C, X)

**Estimated Lines:** ~250 lines

---

### Phase 12C: Multiply and Divide Operations

**Goal:** Implement multiply/divide with proper timing

**Instructions to Implement:**
1. `MULU` - Unsigned multiply 16×16→32 (0xC0C0)
2. `MULS` - Signed multiply 16×16→32 (0xC1C0)
3. `DIVU` - Unsigned divide 32÷16→16r16 (0x80C0)
4. `DIVS` - Signed divide 32÷16→16r16 (0x81C0)

**Features:**
- Multi-cycle execution (divide: ~40 cycles, multiply: ~30 cycles)
- Overflow detection
- Divide by zero exception (already detected in Phase 11B)
- Proper CCR updates

**Estimated Lines:** ~300 lines (multiply: ~100, divide: ~200)

---

### Phase 12D: Branch and Control Flow

**Goal:** Implement proper branch instructions

**Instructions to Implement:**
1. `Bcc` - Conditional branch (0x6xxx)
   - BRA, BSR, BHI, BLS, BCC, BCS, BNE, BEQ, BVC, BVS, BPL, BMI, BGE, BLT, BGT, BLE
2. `DBcc` - Decrement and branch conditionally (0x50C8-0x5FC8)
3. `Scc` - Set according to condition (0x50C0-0x5FC0)
4. `BRA` - Branch always (0x6000)
5. `BSR` - Branch to subroutine (0x6100)

**Features:**
- 8-bit and 16-bit displacements
- Condition code evaluation (already in Phase 8)
- PC-relative addressing
- Integration with branch prediction unit (Phase 8)

**Estimated Lines:** ~150 lines

---

### Phase 12E: Control Flow (JMP/JSR/RTS)

**Goal:** Implement subroutine and jump instructions

**Instructions to Implement:**
1. `JMP` - Jump (0x4EC0)
2. `JSR` - Jump to subroutine (0x4E80)
3. `RTS` - Return from subroutine (0x4E75)
4. `RTR` - Return and restore condition codes (0x4E77)

**Features:**
- Address register indirect: (An)
- Address register indirect with displacement: d(An)
- Absolute addressing: abs.W, abs.L
- PC-relative: d(PC)
- Stack pointer operations (JSR pushes PC, RTS pops PC)

**Estimated Lines:** ~100 lines

---

### Phase 12F: Extended Data Movement

**Goal:** Implement advanced move instructions

**Instructions to Implement:**
1. `MOVEA` - Move to address register (0x2xxx/0x3xxx)
2. `MOVEQ` - Move quick (sign-extend 8-bit immediate) (0x7xxx)
3. `MOVEM` - Move multiple registers (0x4880/0x4C80)
4. `LEA` - Load effective address (0x41C0)
5. `PEA` - Push effective address (0x4840)
6. `EXG` - Exchange registers (0xC100)
7. `SWAP` - Swap register halves (0x4840)
8. `EXT` - Sign extend (0x4880/0x48C0)

**Features:**
- Multiple addressing modes
- Register masks for MOVEM
- Stack operations for PEA
- Word/long operand sizes

**Estimated Lines:** ~250 lines

---

### Phase 12G: Bit Manipulation

**Goal:** Implement bit manipulation instructions

**Instructions to Implement:**
1. `BTST` - Test bit (0x0100/0x0800)
2. `BSET` - Set bit (0x01C0/0x08C0)
3. `BCLR` - Clear bit (0x0180/0x0880)
4. `BCHG` - Change bit (0x0140/0x0840)

**Features:**
- Register bit number (Dn)
- Immediate bit number (#<data>)
- Memory and register operands
- Z flag update

**Estimated Lines:** ~150 lines

---

### Phase 12H: Stack and Link Operations

**Goal:** Implement stack frame operations

**Instructions to Implement:**
1. `LINK` - Link and allocate (0x4E50)
2. `UNLK` - Unlink (0x4E58)
3. `PEA` - Push effective address (covered in 12F)
4. Stack-relative addressing modes

**Features:**
- Frame pointer operations
- Stack frame creation/destruction
- Support for local variables

**Estimated Lines:** ~80 lines

---

### Phase 12I: Addressing Modes

**Goal:** Implement comprehensive addressing mode support

**Addressing Modes to Implement:**
1. Data register direct: Dn (already implemented)
2. Address register direct: An (partial)
3. Address register indirect: (An)
4. Address register indirect with postincrement: (An)+
5. Address register indirect with predecrement: -(An)
6. Address register indirect with displacement: d(An)
7. Address register indirect with index: d(An,Xi)
8. Absolute short: xxx.W
9. Absolute long: xxx.L
10. Program counter with displacement: d(PC)
11. Program counter with index: d(PC,Xi)
12. Immediate: #<data>

**Implementation Approach:**
- Create addressing mode decode logic
- Implement EA calculation unit
- Add multi-cycle EA calculation where needed
- Integrate with existing EA pipeline stage

**Estimated Lines:** ~400 lines (comprehensive addressing mode support)

---

## Testing Strategy

### Phase 12 Testing Approach

For each sub-phase, create test cases:

1. **Instruction Decode Tests:**
   - Verify opcode patterns correctly decoded
   - Test all addressing mode combinations

2. **Execution Tests:**
   - Test with various operand values
   - Verify CCR flags correctly set
   - Test boundary conditions (overflow, underflow, zero, negative)

3. **Integration Tests:**
   - Test instruction sequences
   - Verify hazard detection works with new instructions
   - Test exception behavior (divide by zero, privilege violations)

4. **Performance Tests:**
   - Measure CPI for instruction mixes
   - Verify multi-cycle instructions take expected cycles

---

## Implementation Priority

### Recommended Order

1. **Phase 12A** - Arithmetic/Logical (fundamental ALU operations)
2. **Phase 12D** - Branch/Control Flow (needed for programs)
3. **Phase 12F** - Extended Move (MOVEQ especially useful)
4. **Phase 12C** - Multiply/Divide (complex but important)
5. **Phase 12E** - JMP/JSR/RTS (subroutine support)
6. **Phase 12B** - Shift/Rotate (bit operations)
7. **Phase 12G** - Bit Manipulation (specialized)
8. **Phase 12H** - Stack/Link (frame pointers)
9. **Phase 12I** - Addressing Modes (comprehensive, toucheseverything)

### Alternative: Minimal Viable Instruction Set (MVIS)

For faster progress to a working system, implement in this order:
1. MOVEQ (quick immediate moves)
2. CMP/TST (comparisons for branches)
3. Bcc (conditional branches)
4. JSR/RTS (subroutines)
5. Basic arithmetic (AND, OR, NOT already have ADD/SUB)
6. Basic addressing modes: (An), (An)+, -(An), d(An)

This would give a minimally functional processor for simple programs.

---

## Code Statistics Estimates

### Per Sub-Phase

| Sub-Phase | Lines | Description |
|-----------|-------|-------------|
| 12A | 200 | Arithmetic/Logical operations |
| 12B | 250 | Shift/Rotate operations |
| 12C | 300 | Multiply/Divide |
| 12D | 150 | Branch instructions |
| 12E | 100 | JMP/JSR/RTS |
| 12F | 250 | Extended moves |
| 12G | 150 | Bit manipulation |
| 12H | 80 | Stack/Link |
| 12I | 400 | Addressing modes |
| **Total** | **1,880** | **Full instruction set** |

### MVIS (Minimal Viable)

| Component | Lines | Description |
|-----------|-------|-------------|
| Basic ALU ops | 100 | AND, OR, NOT, CMP, TST |
| MOVEQ | 20 | Quick immediate move |
| Bcc | 80 | Conditional branches |
| JSR/RTS | 60 | Subroutines |
| Basic addr modes | 150 | (An), (An)+, -(An), d(An) |
| **Total** | **410** | **Minimal viable** |

---

## Integration Notes

### Files to Modify

1. **TG68040_Pipeline.vhd** - ID stage decode logic
2. **TG68040_Pack.vhd** - Instruction type enumeration
3. **TG68040_Pipeline_Regs.vhd** - Pipeline register fields (if needed)
4. **Create: TG68040_ALU.vhd** - Dedicated ALU unit
5. **Create: TG68040_Multiply.vhd** - Multiply unit
6. **Create: TG68040_Divide.vhd** - Divide unit (real implementation)
7. **Create: TG68040_EA_Calc.vhd** - EA calculation unit

### Dependencies

- **Phase 4** (Hazard Detection) - Must work with new instructions
- **Phase 8** (Branch Prediction) - Integrate with Bcc/JMP/JSR
- **Phase 11** (Exceptions) - Divide by zero, privilege violations

---

## Performance Impact

### Expected CPI Changes

**Current CPI:** ~1.5 (baseline with stubs)

**After Phase 12:**
- Simple ALU ops: 1 cycle
- Shift/Rotate: 1 cycle (register), 2 cycles (memory)
- Multiply: ~30 cycles
- Divide: ~40 cycles
- Branch taken: ~3 cycles (with prediction)
- Branch mispredicted: ~6 cycles
- Load/Store: 1-2 cycles (cache hit)

**Expected CPI:** ~1.3-1.5 (with real instruction mix)

---

## Next Steps

### Immediate Action (Phase 12A Start)

1. Create TG68040_ALU.vhd with dedicated ALU unit
2. Expand ID stage decode logic for Phase 12A instructions
3. Implement arithmetic/logical operations in EX stage
4. Create tests for Phase 12A instructions

### Following Actions

Progress through sub-phases in priority order, testing each thoroughly before moving to next.

---

## References

- MC68040 User's Manual, Chapter 4: Instruction Set
- MC68040 User's Manual, Appendix A: Instruction Format Summary
- MC68000 Family Programmer's Reference Manual

---

**Document Version:** 1.0
**Date Created:** 2025-11-11
**Phase Status:** Planning
**Author:** Claude AI (Anthropic)
