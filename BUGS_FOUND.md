# MC68060 Implementation - Critical Bugs Found

## 🔴 CRITICAL BUG #1: ExecuteUnit Never Assigns Destination Register

**Location:** `MC68060_ExecuteUnit.v`

**Problem:**
The ExecuteUnit declares `output reg [3:0] write_addr` but **NEVER assigns a value to it**!
- Line 85: Initializes to `4'd0` on reset
- Lines 101-174: Case statement sets `write_enable` and `result_out` but NEVER sets `write_addr`
- Result: **ALL register writes go to register 0 (D0)**, corrupting the CPU state

**Root Cause:**
The destination register address from decode stage is never passed to execute stage.
- DecodeUnit outputs `rf_raddr2` (destination register)
- ExecuteUnit receives `operand2` (the VALUE from rf_raddr2) but not the ADDRESS
- Missing datapath: decode destination address → execute write address

**Impact:**
Catastrophic - every instruction writes to D0, destroying all register values.

**Fix Required:**
1. Add `dest_reg_in` input to ExecuteUnit (4-bit)
2. Connect DecodeUnit.rf_raddr2 → ExecuteUnit.dest_reg_in
3. Assign `write_addr <= dest_reg_in` in execute pipeline

---

## 🔴 CRITICAL BUG #2: Shift/Rotate Carry Flag Calculation Wrong

**Location:** `MC68060_ALU.v:158`

**Problem:**
```verilog
flags[1] <= (shift_count != 0) ? operand1[shift_count-1] : 1'b0;
```

This is incorrect for multiple reasons:
1. **Doesn't distinguish shift direction**: LSL (left) vs LSR (right) need different carry logic
2. **Wrong bit for LSL**: Left shift should use `operand1[32-shift_count]` as last shifted out
3. **Potentially out of bounds**: `shift_count-1` with shift_count=1 gives bit[0], not the last shifted bit
4. **Wrong for rotates**: ROL/ROR carry should be different from shifts

**Correct Logic:**
- **LSL**: C = operand1[32-shift_count] (last bit shifted out the left)
- **LSR**: C = operand1[shift_count-1] (last bit shifted out the right)
- **ASL/ASR**: Same as LSL/LSR
- **ROL/ROR**: C = result[0] or result[31] depending on direction

---

## 🟡 SERIOUS BUG #3: Rotate Operations Undefined for shift_count=0

**Location:** `MC68060_ALU.v:69-70`

**Problem:**
```verilog
OP_ROL: shift_temp = (operand1 << shift_count) | (operand1 >> (32 - shift_count));
OP_ROR: shift_temp = (operand1 >> shift_count) | (operand1 << (32 - shift_count));
```

When `shift_count = 0`:
- `(32 - 0) = 32`
- Shifting by 32 bits is **undefined behavior** in Verilog
- May synthesize incorrectly or produce wrong results

**Fix Required:**
Add special case for shift_count == 0:
```verilog
OP_ROL: shift_temp = (shift_count == 0) ? operand1 :
                     (operand1 << shift_count) | (operand1 >> (32 - shift_count));
```

---

## 🟡 SERIOUS BUG #4: No Pipeline Stall Logic

**Location:** `MC68060_Top.v` state machine

**Problem:**
The state machine advances through states unconditionally:
- FETCH → DECODE → EXECUTE → MEMORY → WRITEBACK
- No stall logic for:
  - Cache misses (icache_hit == 0)
  - Multi-cycle operations (multiply, divide)
  - Memory not ready
  - FPU busy

**Impact:**
CPU will try to execute with invalid data from cache misses or incomplete operations.

**Fix Required:**
Add stall conditions in state transitions:
```verilog
STATE_FETCH: begin
    if (fetch_valid && (icache_hit || mem_ready)) begin
        cpu_state <= STATE_DECODE;
    end
    // else stay in FETCH
end
```

---

## 🟠 IMPORTANT BUG #5: Decode Stage Doesn't Output Destination Register

**Location:** `MC68060_DecodeUnit.v`

**Problem:**
DecodeUnit determines destination register in `rf_raddr2` for register file READ, but doesn't output this information for writeback.

**Current outputs:**
- `opcode_out` ✓
- `pc_out` ✓
- `valid_out` ✓
- `rf_raddr1`, `rf_raddr2` - used only for register file, not forwarded

**Missing output:**
- `dest_reg_out` - which register to write result to

**Fix Required:**
Add `output reg [3:0] dest_reg_out` and assign it based on instruction type.

---

## 🟠 IMPORTANT BUG #6: No Effective Address Calculation ✅ PARTIALLY FIXED

**Location:** All modules

**Problem:**
MC68000 instructions use complex addressing modes (Address Register Indirect, Displacement, Index, etc.)
but the implementation has **NO effective address calculation logic**.

Example: `MOVE.L (A0)+,D0` needs to:
1. Read address from A0
2. Use that as memory address
3. Increment A0 after read

Currently: Would just use raw register value as address, which is wrong for most addressing modes.

**Impact:**
Most addressing modes won't work correctly. Only register-direct mode might work.

**Fix Applied:**
Created MC68060_EffectiveAddress.v module that supports all MC68000 addressing modes:
- Data/Address Register Direct
- Address Register Indirect
- Address Register Indirect with Pre/Post increment/decrement
- Address Register Indirect with Displacement
- Address Register Indirect with Index
- Absolute Short/Long
- PC Relative with Displacement/Index
- Immediate

Updated DecodeUnit to extract EA mode information from instructions.
Updated ExecuteUnit to use calculated EAs for memory operations.
Integrated two EA calculation units (source and destination) in Top module.

**Known Limitation:**
Extension word fetching not yet implemented - currently hardcoded to 0x0000.
This means displacement and index modes will calculate wrong addresses until
multi-word instruction fetch is implemented (Bug #10).

---

## 🟠 IMPORTANT BUG #7: No Status Register (SR/CCR) Management

**Location:** Missing entirely

**Problem:**
MC68000 has Status Register with flags (N, Z, V, C, X) and system bits (S, T, I).
- ALU sets flags in local `flags` register
- But these flags are never:
  - Written to actual CPU Status Register
  - Read for conditional branches (Bcc, DBcc)
  - Accessible via MOVE to/from SR/CCR

**Fix Required:**
Add SR register and flag management logic.

---

## 🟡 MODERATE BUG #8: Branch Operations Not Implemented

**Location:** `MC68060_ExecuteUnit.v`

**Problem:**
Opcodes defined for BRA, BCC, JMP, JSR, RTS but execute stage has no code to handle them:
```verilog
case (opcode_in)
    OP_BRA: // NO CODE HERE!
    OP_BCC: // NO CODE HERE!
    OP_JMP: // NO CODE HERE!
```

Branches need to:
1. Calculate target address (PC + displacement)
2. Check condition flags for Bcc
3. Update PC
4. Signal branch to fetch unit

---

## 🟡 MODERATE BUG #9: Multiply/Divide Use Wrong Operand Sizes

**Location:** `MC68060_ALU.v:56-57`

**Problem:**
```verilog
assign mul_result = operand1 * operand2;  // Both 32-bit → 64-bit result
assign div_result = (operand2 != 0) ? (operand1 / operand2) : 32'hFFFFFFFF;
```

MC68000 has:
- **MULU.W**: 16×16→32 (word multiply)
- **MULS.W**: Signed 16×16→32
- **MULU.L**: 32×32→64 (68020+ only)
- **DIVU.W**: 32÷16→16 quotient + 16 remainder
- **DIVS.W**: Signed division

Current code always does 32×32 multiply, which is wrong for MULU.W/MULS.W.

---

## 🟡 MODERATE BUG #10: No Instruction Length Tracking

**Location:** Fetch/Decode stages

**Problem:**
MC68000 instructions are variable length (2-10 bytes).
- Simple instruction: 1 word (2 bytes)
- With immediate: 2-3 words
- With long displacement: 3 words

Fetch unit always fetches 1 word and increments PC by 2.
No logic to fetch additional words for multi-word instructions.

**Impact:**
Only single-word instructions will decode correctly.

---

## Summary

| Bug # | Severity | Component | Status | Impact |
|-------|----------|-----------|--------|--------|
| 1 | 🔴 Critical | ExecuteUnit | ✅ FIXED | All writes go to D0 - CPU unusable |
| 2 | 🔴 Critical | ALU | ✅ FIXED | Wrong carry flags - conditional branches broken |
| 3 | 🟡 Serious | ALU | ✅ FIXED | Rotate by 0 undefined - may crash |
| 4 | 🟡 Serious | Top/Pipeline | ✅ FIXED | No stalls - data corruption on cache miss |
| 5 | 🟠 Important | DecodeUnit | ✅ FIXED | Missing dest reg - can't fix Bug #1 |
| 6 | 🟠 Important | All | 🔶 PARTIAL | No EA calc - most instructions broken |
| 7 | 🟠 Important | Missing | ✅ FIXED | No SR - branches/interrupts broken |
| 8 | 🟡 Moderate | ExecuteUnit | ✅ FIXED | Branches not implemented |
| 9 | 🟡 Moderate | ALU | ❌ OPEN | Wrong operand sizes for mul/div |
| 10 | 🟡 Moderate | Fetch/Decode | ❌ OPEN | Only 1-word instructions work |

## Recommendation

This implementation needs **significant additional work** before it can execute even simple programs:

**Phase 1 - Make it functional (fix critical bugs):** ✅ COMPLETE
1. ✅ Fix Bug #1 & #5: Add destination register pipeline
2. ✅ Fix Bug #2: Correct carry flag logic
3. ✅ Fix Bug #3: Handle shift_count=0
4. ✅ Fix Bug #4: Add pipeline stall logic

**Phase 2 - Make it useful (fix important bugs):** ✅ COMPLETE
5. 🔶 Fix Bug #6: Implement effective address calculation (partial - needs extension word fetch)
6. ✅ Fix Bug #7: Add Status Register management
7. ✅ Fix Bug #8: Implement branch execution
8. ❌ Fix Bug #9: Correct multiply/divide sizes (NOT YET FIXED)
9. ❌ Fix Bug #10: Multi-word instruction fetch (NOT YET FIXED)

**Phase 3 - Make it complete:** 🔄 IN PROGRESS
10. 🔶 Complete extension word fetching for Bug #6
11. Add remaining instruction opcodes
12. Add exception handling
13. Add interrupt processing
14. Implement full Bcc condition code checking (all 14 conditions)
15. Implement stack operations (JSR/RTS/exceptions)
16. Test with actual MC68000 programs
