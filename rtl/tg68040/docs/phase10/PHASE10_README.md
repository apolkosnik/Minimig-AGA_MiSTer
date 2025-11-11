# Phase 10: Floating Point Unit (FPU)

## Overview

**Phase:** 10 of 15
**Goal:** Implement MC68040 Floating Point Unit for IEEE 754 floating-point arithmetic
**Complexity:** High
**Estimated Effort:** 3-4 sessions

## MC68040 FPU Architecture

The MC68040 includes an integrated Floating Point Unit (FPU) that supports IEEE 754 single, double, and extended precision floating-point arithmetic.

### FPU Features

**Data Formats:**
- Single Precision (32-bit): 1 sign, 8 exponent, 23 mantissa
- Double Precision (64-bit): 1 sign, 11 exponent, 52 mantissa
- Extended Precision (80-bit): 1 sign, 15 exponent, 64 mantissa (explicit integer bit)

**Register File:**
- 8 floating-point data registers (FP0-FP7), 80-bit extended precision
- FPIAR: FP Instruction Address Register (32-bit)
- FPSR: FP Status Register (32-bit)
- FPCR: FP Control Register (32-bit)

**Arithmetic Operations:**
- FADD, FSUB, FMUL, FDIV
- FSQRT, FABS, FNEG
- FMOVE (various formats)
- FCMP, FTST

**Transcendental Functions:**
- FSIN, FCOS, FTAN
- FASIN, FACOS, FATAN
- FSINH, FCOSH, FTANH
- FLOG10, FLOG2, FLOGN, FLOGNP1
- FETOX, FETOXM1, FTWOTOX, FTENTOX

**Rounding Modes:**
- Round to nearest (default)
- Round toward zero
- Round toward +infinity
- Round toward -infinity

**Exception Handling:**
- Inexact
- Divide by zero
- Underflow
- Overflow
- Invalid operation
- Denormalized input

## Implementation Strategy

### Phase 10A: FPU Package and Register File

**Goal:** Create FPU types and register file

**Components:**
1. **TG68040_FPU_Pack.vhd** - FPU package
   - Floating-point data types
   - FP register types
   - Status/control register types
   - Exception types
   - Utility functions (pack/unpack, classify)

2. **TG68040_FPU_RegFile.vhd** - FP register file
   - 8 x 80-bit FP registers (FP0-FP7)
   - 2 read ports, 1 write port
   - Register read/write logic

**Deliverables:**
- FPU package with types (~400 lines)
- FP register file (~200 lines)
- Register file unit tests (~150 lines)

### Phase 10B: Basic FPU Datapath

**Goal:** Implement basic FP arithmetic operations

**Components:**
1. **TG68040_FPU_Add.vhd** - FP adder/subtractor
   - Alignment of operands
   - Addition/subtraction
   - Normalization
   - Rounding
   - Exception detection

2. **TG68040_FPU_Mul.vhd** - FP multiplier
   - Mantissa multiplication
   - Exponent addition
   - Normalization
   - Rounding
   - Exception detection

3. **TG68040_FPU_Div.vhd** - FP divider
   - Non-restoring division
   - Exponent subtraction
   - Normalization
   - Rounding
   - Exception detection

**Deliverables:**
- FP adder (~300 lines)
- FP multiplier (~300 lines)
- FP divider (~400 lines)
- Arithmetic unit tests (~300 lines)

### Phase 10C: FPU Control and Pipeline Integration

**Goal:** Integrate FPU with main pipeline

**Components:**
1. **TG68040_FPU.vhd** - Complete FPU unit
   - Register file instance
   - Arithmetic units (add, mul, div)
   - Control logic
   - Exception handling
   - Result multiplexing

2. **Pipeline Integration**
   - Extend pipeline for FP operations
   - FP instruction decode
   - FP execution stage(s)
   - FP writeback
   - Exception handling integration

**Deliverables:**
- Complete FPU unit (~500 lines)
- Pipeline modifications (~200 lines)
- Integration tests (~200 lines)

### Phase 10D: Advanced FP Operations (Future)

**Goal:** Add transcendental functions and optimizations

**Components:**
- Square root (CORDIC or Newton-Raphson)
- Transcendental functions (using lookup tables + CORDIC)
- Fused multiply-add (FMAC)
- Denormal number support
- Performance optimizations

**Note:** This phase is optional and can be deferred.

## FPU Data Types

### Floating-Point Number Representation

**Extended Precision (80-bit) - Internal Format:**
```
Bit 79: Sign (S)
Bits 78-64: Exponent (15 bits, biased by 16383)
Bit 63: Integer bit (J) - explicit in extended precision
Bits 62-0: Mantissa/Fraction (63 bits)
```

**Double Precision (64-bit):**
```
Bit 63: Sign
Bits 62-52: Exponent (11 bits, biased by 1023)
Bits 51-0: Mantissa (52 bits, implicit integer bit)
```

**Single Precision (32-bit):**
```
Bit 31: Sign
Bits 30-23: Exponent (8 bits, biased by 127)
Bits 22-0: Mantissa (23 bits, implicit integer bit)
```

### Special Values

**Zero:**
- Exponent = 0, Mantissa = 0
- Can be +0 or -0 (sign bit distinguishes)

**Infinity:**
- Exponent = all 1s, Mantissa = 0
- Can be +∞ or -∞

**NaN (Not a Number):**
- Exponent = all 1s, Mantissa ≠ 0
- Quiet NaN: Most significant mantissa bit = 1
- Signaling NaN: Most significant mantissa bit = 0

**Denormalized Numbers:**
- Exponent = 0, Mantissa ≠ 0
- Used for gradual underflow

## FPU Package Types

```vhdl
-- Extended precision FP number (internal format)
type fp_extended_t is record
    sign     : std_logic;                      -- Sign bit
    exponent : std_logic_vector(14 downto 0);  -- 15-bit exponent (biased)
    integer_bit : std_logic;                   -- Explicit integer bit (J)
    mantissa : std_logic_vector(62 downto 0);  -- 63-bit mantissa
end record;

-- FP number class
type fp_class_t is (
    FP_ZERO,           -- Zero (+0 or -0)
    FP_DENORMAL,       -- Denormalized number
    FP_NORMAL,         -- Normal number
    FP_INFINITY,       -- Infinity (+∞ or -∞)
    FP_QNAN,           -- Quiet NaN
    FP_SNAN            -- Signaling NaN
);

-- FP exception flags
type fp_exception_t is record
    inexact        : std_logic;  -- Inexact result
    divide_by_zero : std_logic;  -- Division by zero
    underflow      : std_logic;  -- Underflow
    overflow       : std_logic;  -- Overflow
    invalid_op     : std_logic;  -- Invalid operation (NaN)
    denormal_input : std_logic;  -- Denormalized input
end record;

-- FP rounding mode
type fp_rounding_t is (
    ROUND_NEAREST,     -- Round to nearest (default)
    ROUND_ZERO,        -- Round toward zero (truncate)
    ROUND_PLUS_INF,    -- Round toward +infinity
    ROUND_MINUS_INF    -- Round toward -infinity
);

-- FPSR Status Register
type fpsr_register_t is record
    exception_status : fp_exception_t;   -- Exception status bits
    accrued_exception : fp_exception_t;  -- Accrued exceptions
    quotient         : std_logic_vector(6 downto 0);  -- Quotient bits
    condition_codes  : std_logic_vector(3 downto 0);  -- N, Z, I, NaN
end record;

-- FPCR Control Register
type fpcr_register_t is record
    rounding_mode     : fp_rounding_t;           -- Rounding mode
    rounding_precision : std_logic_vector(1 downto 0);  -- 00=ext, 01=single, 10=double
    exception_enable   : fp_exception_t;         -- Exception enable bits
end record;

-- FP operation type
type fp_operation_t is (
    FP_OP_NOP,
    FP_OP_ADD,
    FP_OP_SUB,
    FP_OP_MUL,
    FP_OP_DIV,
    FP_OP_SQRT,
    FP_OP_ABS,
    FP_OP_NEG,
    FP_OP_MOVE,
    FP_OP_CMP,
    FP_OP_TST
);
```

## FPU Utility Functions

```vhdl
-- Pack extended precision to 80-bit std_logic_vector
function pack_fp_extended(fp : fp_extended_t) return std_logic_vector;

-- Unpack 80-bit std_logic_vector to extended precision
function unpack_fp_extended(data : std_logic_vector(79 downto 0)) return fp_extended_t;

-- Convert single precision to extended precision
function single_to_extended(data : std_logic_vector(31 downto 0)) return fp_extended_t;

-- Convert double precision to extended precision
function double_to_extended(data : std_logic_vector(63 downto 0)) return fp_extended_t;

-- Convert extended precision to single precision
function extended_to_single(fp : fp_extended_t; rounding : fp_rounding_t) return std_logic_vector;

-- Convert extended precision to double precision
function extended_to_double(fp : fp_extended_t; rounding : fp_rounding_t) return std_logic_vector;

-- Classify FP number
function classify_fp(fp : fp_extended_t) return fp_class_t;

-- Check if FP number is zero
function is_fp_zero(fp : fp_extended_t) return boolean;

-- Check if FP number is NaN
function is_fp_nan(fp : fp_extended_t) return boolean;

-- Check if FP number is infinity
function is_fp_inf(fp : fp_extended_t) return boolean;

-- Check if FP number is denormalized
function is_fp_denormal(fp : fp_extended_t) return boolean;

-- Normalize FP number (shift mantissa, adjust exponent)
function normalize_fp(fp : fp_extended_t) return fp_extended_t;

-- Apply rounding to FP result
function round_fp(fp : fp_extended_t; guard, round_bit, sticky : std_logic; mode : fp_rounding_t) return fp_extended_t;
```

## FP Addition/Subtraction Algorithm

**Inputs:** A, B (extended precision), operation (ADD/SUB)
**Output:** Result (extended precision), exceptions

**Steps:**

1. **Unpack Operands:**
   - Extract sign, exponent, mantissa from A and B
   - Classify A and B (zero, denormal, normal, infinity, NaN)

2. **Handle Special Cases:**
   - If A or B is NaN → result is NaN
   - If A = +∞ and B = -∞ (or vice versa for ADD) → invalid operation (NaN)
   - If A or B is ∞ → result is ∞ (with proper sign)
   - If A and B are zero → result is zero (sign depends on rounding mode)

3. **Align Operands:**
   - Compare exponents: diff = exp_a - exp_b
   - If diff > 0: shift B right by diff bits, use exp_a
   - If diff < 0: shift A right by |diff| bits, use exp_b
   - If diff = 0: no shift needed

4. **Add/Subtract Mantissas:**
   - If signs are same: add mantissas
   - If signs are different: subtract mantissas (effective subtraction)
   - Keep guard, round, and sticky bits for accurate rounding

5. **Normalize Result:**
   - If result has overflow (carry out): shift right 1 bit, increment exponent
   - If result has leading zeros: shift left until normalized, decrement exponent
   - Check for exponent overflow (result too large → infinity)
   - Check for exponent underflow (result too small → denormal or zero)

6. **Round Result:**
   - Apply rounding mode (nearest, zero, +inf, -inf)
   - Use guard, round, sticky bits to determine rounding
   - May cause another normalization step if rounding creates overflow

7. **Pack Result:**
   - Assemble sign, exponent, mantissa into result
   - Set exception flags (inexact, overflow, underflow)

## FP Multiplication Algorithm

**Inputs:** A, B (extended precision)
**Output:** Result (extended precision), exceptions

**Steps:**

1. **Unpack and Classify:** Same as addition

2. **Handle Special Cases:**
   - If A or B is NaN → result is NaN
   - If A or B is ∞ and other is 0 → invalid operation (NaN)
   - If A or B is ∞ → result is ∞ (sign = XOR of signs)
   - If A or B is zero → result is zero (sign = XOR of signs)

3. **Multiply Mantissas:**
   - Multiply A.mantissa × B.mantissa (64-bit × 64-bit → 128-bit product)
   - Add implicit integer bits if normal numbers

4. **Add Exponents:**
   - result_exp = A.exp + B.exp - bias
   - Check for exponent overflow/underflow

5. **Normalize:** Same as addition

6. **Round:** Same as addition

7. **Pack Result:** Same as addition

## FP Division Algorithm

**Inputs:** A (dividend), B (divisor) (extended precision)
**Output:** Result (extended precision), exceptions

**Steps:**

1. **Unpack and Classify:** Same as addition

2. **Handle Special Cases:**
   - If A or B is NaN → result is NaN
   - If A and B are both ∞ or both 0 → invalid operation (NaN)
   - If B is 0 and A ≠ 0 → divide by zero exception, result is ∞
   - If A is 0 → result is 0
   - If A is ∞ → result is ∞
   - If B is ∞ → result is 0

3. **Divide Mantissas:**
   - Use non-restoring division or SRT division
   - Divide A.mantissa / B.mantissa
   - Generate quotient and remainder

4. **Subtract Exponents:**
   - result_exp = A.exp - B.exp + bias
   - Check for exponent overflow/underflow

5. **Normalize:** Same as addition

6. **Round:** Same as addition

7. **Pack Result:** Same as addition

## Pipeline Integration

### FPU Execution Pipeline

The FPU operates in parallel with the integer pipeline:

```
Integer Pipeline: IF → ID → EA → OF → EX → WB
                                    ↓
FPU Pipeline:                      FP-DECODE → FP-EX1 → FP-EX2 → FP-EX3 → FP-WB
```

**FP-DECODE:** Decode FP instruction, read FP registers
**FP-EX1:** Align operands, handle special cases
**FP-EX2:** Perform arithmetic operation
**FP-EX3:** Normalize and round result
**FP-WB:** Write back to FP register file

**Latencies:**
- FADD/FSUB: 3 cycles (EX1 + EX2 + EX3)
- FMUL: 3 cycles
- FDIV: 20+ cycles (iterative division)
- FSQRT: 25+ cycles (iterative square root)

**Pipeline Coordination:**
- FP instructions detected in ID stage
- Integer pipeline stalls if FP result needed
- FP pipeline can operate independently for FP-to-FP operations

## Implementation Plan

### Phase 10A: Package and Register File (Session 1)

1. Create `TG68040_FPU_Pack.vhd`:
   - Define FP data types (extended, double, single)
   - Define FP register types (FPSR, FPCR)
   - Define exception and rounding types
   - Implement utility functions (pack/unpack, classify)

2. Create `TG68040_FPU_RegFile.vhd`:
   - 8 x 80-bit register array
   - 2 read ports (operand A, operand B)
   - 1 write port (result)
   - Combinational read, registered write

3. Create `test_FPU_RegFile.vhd`:
   - Test register read/write
   - Test simultaneous read and write
   - Test all 8 registers

### Phase 10B: Arithmetic Units (Session 2)

1. Create `TG68040_FPU_Add.vhd`:
   - Implement FP addition/subtraction
   - Support all special cases (NaN, inf, zero)
   - 3-stage pipelined (align, add, normalize)
   - Rounding support

2. Create `TG68040_FPU_Mul.vhd`:
   - Implement FP multiplication
   - 3-stage pipelined (multiply, normalize, round)

3. Create stub for `TG68040_FPU_Div.vhd`:
   - Stub that returns zero (full implementation future)

4. Create `test_FPU_Arith.vhd`:
   - Test FP addition (positive, negative, zero)
   - Test FP subtraction
   - Test FP multiplication
   - Test special cases (NaN, infinity)

### Phase 10C: FPU Unit and Integration (Session 3)

1. Create `TG68040_FPU.vhd`:
   - Instantiate register file
   - Instantiate arithmetic units
   - Control logic (operation selection)
   - Exception handling
   - Result multiplexing

2. Modify `TG68040_Pipeline.vhd`:
   - Add FPU component declaration
   - Add FPU signals
   - Instantiate FPU
   - Add FP instruction decode
   - Add FP writeback path
   - Handle FP exceptions

3. Create `test_FPU_Integration.vhd`:
   - Test FP operations through pipeline
   - Test FP register file access
   - Test exception handling

## Testing Strategy

### Unit Tests

**Register File:**
- Read/write all registers
- Simultaneous read and write
- 80-bit data integrity

**Addition:**
- 1.0 + 1.0 = 2.0
- 1.5 + 2.5 = 4.0
- -1.0 + 1.0 = 0.0
- Large + small (alignment test)
- Infinity handling
- NaN propagation

**Multiplication:**
- 2.0 × 3.0 = 6.0
- 0.5 × 0.5 = 0.25
- -1.0 × -1.0 = 1.0
- Infinity × finite = infinity
- 0 × infinity = NaN

### Integration Tests

**Simple FP Program:**
```assembly
FMOVE.S #1.5, FP0     ; Load 1.5
FMOVE.S #2.5, FP1     ; Load 2.5
FADD.X FP1, FP0       ; FP0 = 1.5 + 2.5 = 4.0
FMUL.S #2.0, FP0      ; FP0 = 4.0 × 2.0 = 8.0
```

## Performance Targets

**Throughput:**
- 1 FP operation per 3 cycles (fully pipelined add/mul)
- Division/square root are iterative (lower throughput)

**Latency:**
- FADD/FSUB: 3 cycles
- FMUL: 3 cycles
- FDIV: 20+ cycles (stub: 1 cycle with zero result)
- FSQRT: 25+ cycles (future)

## Future Enhancements (Phase 10D+)

**High Priority:**
- Full FP division implementation (non-restoring divider)
- FP square root (CORDIC or Newton-Raphson)
- Denormalized number support
- Complete exception handling

**Medium Priority:**
- Fused multiply-add (FMAC)
- Transcendental functions (sin, cos, log, exp using CORDIC + LUT)
- Format conversion optimizations

**Low Priority:**
- Extended precision mode (80-bit internal, 80-bit result)
- Faster division (SRT-4 or higher radix)
- Speculative FP execution

## References

- MC68040 User's Manual, Chapter 3: Floating-Point Unit
- IEEE 754-1985 Standard for Binary Floating-Point Arithmetic
- "Computer Arithmetic Algorithms" by Israel Koren
- "Digital Arithmetic" by Ercegovac and Lang

## Acceptance Criteria

**Phase 10A:**
- ✅ FPU package compiles successfully
- ✅ All FP types defined
- ✅ Utility functions implemented
- ✅ Register file functional
- ✅ Register file tests pass

**Phase 10B:**
- ✅ FP adder functional
- ✅ FP multiplier functional
- ✅ Special cases handled (NaN, infinity, zero)
- ✅ Rounding modes supported
- ✅ Arithmetic tests pass

**Phase 10C:**
- ✅ FPU unit integrated with pipeline
- ✅ FP instructions execute correctly
- ✅ FP register writeback works
- ✅ Simple FP programs run successfully
- ✅ Integration tests pass

---

**Document Version:** 1.0 (Initial Planning)
**Date:** 2025-11-11
**Author:** Claude AI (Anthropic)
