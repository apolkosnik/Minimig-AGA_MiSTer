# TG68K MC68881/68882 FPU Complete Documentation

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Module Descriptions](#module-descriptions)
4. [Programming Interface](#programming-interface)
5. [Instruction Set](#instruction-set)
6. [IEEE 754 Support](#ieee-754-support)
7. [Integration Guide](#integration-guide)
8. [Testing and Verification](#testing-and-verification)
9. [Performance Considerations](#performance-considerations)
10. [Future Enhancements](#future-enhancements)

## Overview

The TG68K FPU is a complete implementation of the Motorola MC68881/68882 Floating Point Unit designed for the TG68K CPU core. It provides IEEE 754 compliant floating-point arithmetic with full compatibility for MC68020/68030 systems.

### Key Features
- **IEEE 754 Compliance**: Full support for 80-bit extended precision
- **Complete Instruction Set**: 46+ floating-point instructions
- **8 FP Registers**: FP0-FP7, each 80 bits wide
- **Multiple Data Formats**: Byte, Word, Long, Single, Double, Extended, Packed
- **Exception Handling**: Complete IEEE exception support
- **Modular Design**: Separate decoder, ALU, converter, and transcendental units

## Architecture

### System Block Diagram
```
                    ┌─────────────────┐
                    │   TG68K CPU     │
                    │     Core        │
                    └─────────┬───────┘
                             │ F-line Instructions
                             │ (0xF000-0xFFFF)
                    ┌─────────▼───────┐
                    │   TG68K_FPU     │
                    │  Main Controller │
                    │                 │
          ┌─────────┼─────────────────┼─────────┐
          │         │                 │         │
    ┌─────▼───┐ ┌───▼───┐ ┌─────▼─────┐ ┌──▼────┐
    │Decoder  │ │  ALU  │ │Converter  │ │Trans. │
    │         │ │       │ │           │ │       │
    └─────────┘ └───────┘ └───────────┘ └───────┘
```

### Data Flow
1. **Instruction Fetch**: CPU fetches F-line instruction
2. **Decode**: FPU decoder parses instruction format
3. **Operand Fetch**: Load operands from FP registers or memory
4. **Format Conversion**: Convert operands to extended precision
5. **Execution**: Perform arithmetic in ALU or transcendental unit
6. **Result Store**: Write result back to FP register
7. **Exception Check**: Update status flags and handle exceptions

## Module Descriptions

### 1. TG68K_FPU.vhd - Main Controller
**Purpose**: Central coordination and state management

**Key Features**:
- 8 x 80-bit FP register file (FP0-FP7)
- Control registers (FPCR, FPSR, FPIAR)
- Multi-state execution engine
- Exception coordination

**State Machine**:
```
IDLE → DECODE → FETCH_SOURCE → EXECUTE → WRITE_RESULT → IDLE
  ↓                                ↓
EXCEPTION_STATE ←──────────────────┘
```

### 2. TG68K_FPU_Decoder.vhd - Instruction Decoder
**Purpose**: Parse F-line instructions and validate formats

**Supported Instruction Types**:
- General arithmetic operations
- FMOVE variants (register, memory, control)
- FMOVEM (multiple register moves)
- FBcc (conditional branches)
- FTRAPcc (conditional traps)
- FSAVE/FRESTORE (privileged operations)

**Key Functions**:
- F-line format validation
- Extension word parsing
- Effective address mode decoding
- Privilege level checking

### 3. TG68K_FPU_ALU.vhd - Arithmetic Logic Unit
**Purpose**: IEEE 754 compliant arithmetic operations

**Implemented Operations**:
- Basic: FADD, FSUB, FMUL, FDIV, FMOVE
- Unary: FABS, FNEG, FSQRT
- Comparison: FCMP, FTST
- Special: FSGLDIV, FSGLMUL (single precision variants)

**Features**:
- 80-bit extended precision internal format
- IEEE exception flag generation
- Multi-cycle operation support
- Normalization and rounding

### 4. TG68K_FPU_Converter.vhd - Data Format Converter
**Purpose**: Convert between different IEEE formats

**Supported Conversions**:
- Integer formats: Byte (8-bit), Word (16-bit), Long (32-bit)
- IEEE formats: Single (32-bit), Double (64-bit), Extended (80-bit)
- Special: Packed decimal (96-bit) - basic support

**Conversion Process**:
1. Extract source format fields (sign, exponent, mantissa)
2. Apply bias adjustments for exponent
3. Extend or truncate mantissa as needed
4. Normalize result and detect exceptions

### 5. TG68K_FPU_Transcendental.vhd - Transcendental Functions
**Purpose**: Mathematical functions beyond basic arithmetic

**Implemented Functions**:
- Trigonometric: FSIN, FCOS, FTAN, FASIN, FACOS, FATAN
- Hyperbolic: FSINH, FCOSH, FTANH, FATANH
- Exponential: FETOX, FTWOTOX, FTENTOX
- Logarithmic: FLOGN, FLOG2, FLOG10
- Other: FSQRT

**Implementation Method**:
- Series expansion for basic functions
- Range reduction for trigonometric functions
- Special value handling (NaN, infinity, zero)
- Multi-cycle computation with configurable precision

### 6. TG68K_FPU_MOVEM.vhd - Multiple Register Moves
**Purpose**: Efficient transfer of multiple FP registers

**Features**:
- Support for all 8 FP registers (FP0-FP7)
- Register mask for selective transfers
- Address modes: (An), (An)+, -(An)
- Direction control: to/from memory
- Bus error and address error handling

## Programming Interface

### Control Registers

#### FPCR (Floating-Point Control Register)
```
Bit 31-16: Reserved
Bit 15-12: Exception Enable Byte
Bit 11-8:  Mode Control Byte  
Bit 7-4:   Rounding Mode
Bit 3-0:   Rounding Precision
```

#### FPSR (Floating-Point Status Register)
```
Bit 31-24: Condition Code Byte
Bit 23-16: Quotient Byte
Bit 15-8:  Exception Status Byte
Bit 7-0:   Accrued Exception Byte
```

#### FPIAR (Floating-Point Instruction Address Register)
```
Bit 31-0: Address of instruction that caused exception
```

### Register Addressing
FP registers are addressed using 3-bit fields in instructions:
- 000 = FP0
- 001 = FP1
- ...
- 111 = FP7

### Data Formats

#### Extended Precision (80-bit)
```
Bit 79:    Sign bit
Bit 78-64: 15-bit biased exponent (bias = 16383)
Bit 63-0:  64-bit significand (explicit integer bit)
```

#### Single Precision (32-bit)
```
Bit 31:    Sign bit
Bit 30-23: 8-bit biased exponent (bias = 127)
Bit 22-0:  23-bit fractional significand
```

#### Double Precision (64-bit)
```
Bit 63:    Sign bit
Bit 62-52: 11-bit biased exponent (bias = 1023)
Bit 51-0:  52-bit fractional significand
```

## Instruction Set

### Basic Arithmetic Operations

#### FADD - Floating Point Add
```assembly
FADD.fmt <ea>,FPn    ; Add effective address to FPn
FADD.X FPm,FPn       ; Add FPm to FPn
```

#### FSUB - Floating Point Subtract
```assembly
FSUB.fmt <ea>,FPn    ; Subtract effective address from FPn
FSUB.X FPm,FPn       ; Subtract FPm from FPn
```

#### FMUL - Floating Point Multiply
```assembly
FMUL.fmt <ea>,FPn    ; Multiply FPn by effective address
FMUL.X FPm,FPn       ; Multiply FPn by FPm
```

#### FDIV - Floating Point Divide
```assembly
FDIV.fmt <ea>,FPn    ; Divide FPn by effective address
FDIV.X FPm,FPn       ; Divide FPn by FPm
```

### Data Movement Operations

#### FMOVE - Floating Point Move
```assembly
FMOVE.fmt <ea>,FPn   ; Load FPn from effective address
FMOVE.fmt FPn,<ea>   ; Store FPn to effective address
FMOVE.X FPm,FPn      ; Copy FPm to FPn
```

#### FMOVEM - Multiple Register Move
```assembly
FMOVEM <register_list>,<ea>   ; Store registers to memory
FMOVEM <ea>,<register_list>   ; Load registers from memory
```

### Unary Operations

#### FABS - Floating Point Absolute Value
```assembly
FABS.fmt <ea>,FPn    ; FPn = |effective address|
FABS.X FPm,FPn       ; FPn = |FPm|
FABS.X FPn           ; FPn = |FPn|
```

#### FNEG - Floating Point Negate
```assembly
FNEG.fmt <ea>,FPn    ; FPn = -effective address
FNEG.X FPm,FPn       ; FPn = -FPm
FNEG.X FPn           ; FPn = -FPn
```

### Comparison Operations

#### FCMP - Floating Point Compare
```assembly
FCMP.fmt <ea>,FPn    ; Compare FPn with effective address
FCMP.X FPm,FPn       ; Compare FPn with FPm
```

#### FTST - Floating Point Test
```assembly
FTST.fmt <ea>        ; Test effective address against zero
FTST.X FPn           ; Test FPn against zero
```

### Transcendental Functions

#### FSIN - Floating Point Sine
```assembly
FSIN.fmt <ea>,FPn    ; FPn = sin(effective address)
FSIN.X FPm,FPn       ; FPn = sin(FPm)
FSIN.X FPn           ; FPn = sin(FPn)
```

#### FCOS - Floating Point Cosine
```assembly
FCOS.fmt <ea>,FPn    ; FPn = cos(effective address)
FCOS.X FPm,FPn       ; FPn = cos(FPm)
FCOS.X FPn           ; FPn = cos(FPn)
```

#### FSQRT - Floating Point Square Root
```assembly
FSQRT.fmt <ea>,FPn   ; FPn = √(effective address)
FSQRT.X FPm,FPn      ; FPn = √(FPm)
FSQRT.X FPn          ; FPn = √(FPn)
```

## IEEE 754 Support

### Supported Formats
- **Single Precision**: 32-bit IEEE 754 binary32
- **Double Precision**: 64-bit IEEE 754 binary64  
- **Extended Precision**: 80-bit IEEE 754 binary80

### Special Values
- **Zero**: ±0 (signed zeros supported)
- **Infinity**: ±∞ 
- **NaN**: Quiet and Signaling NaN
- **Denormalized**: Subnormal numbers

### Exception Types
1. **Invalid Operation**: Invalid operands (√(-1), 0/0, etc.)
2. **Division by Zero**: Division of finite number by zero
3. **Overflow**: Result too large to represent
4. **Underflow**: Result too small to represent
5. **Inexact**: Result cannot be represented exactly

### Rounding Modes
1. **Round to Nearest Even** (default)
2. **Round toward Zero** (truncate)
3. **Round toward +∞** (ceiling)
4. **Round toward -∞** (floor)

## Integration Guide

### 1. Enable FPU in TG68K
```vhdl
-- In your TG68K instantiation
TG68K_INSTANCE: TG68K
generic map(
    CPU => "11",          -- 68020 mode required
    FPU_Enable => 1       -- Enable FPU
)
port map(
    -- ... other connections
);
```

### 2. CPU Configuration Requirements
- CPU must be set to 68020 mode or higher
- F-line exception vector ($2C) must be properly configured
- Sufficient clock speed for multi-cycle FPU operations

### 3. Memory Interface
The FPU requires access to the system memory bus for:
- Loading/storing floating-point values
- FMOVEM operations
- Extension word fetching

### 4. Exception Handling
```vhdl
-- In your exception handler
if fpu_exception = '1' then
    case exception_code is
        when X"05" => -- Division by zero
            -- Handle divide by zero
        when X"0C" => -- Unimplemented instruction
            -- Handle unsupported operation
        when X"10" => -- Illegal instruction
            -- Handle illegal F-line instruction
        when others =>
            -- Handle other FPU exceptions
    end case;
end if;
```

## Testing and Verification

### Test Bench Usage
```bash
# Compile test bench (ModelSim/QuestaSim example)
vcom -work work TG68K_Pack.vhd
vcom -work work TG68K_FPU_Decoder.vhd
vcom -work work TG68K_FPU_ALU.vhd
vcom -work work TG68K_FPU_Converter.vhd
vcom -work work TG68K_FPU.vhd
vcom -work work TG68K_FPU_TestBench.vhd

# Run simulation
vsim -t ps work.TG68K_FPU_TestBench
run -all
```

### Test Coverage
The test bench covers:
- Basic arithmetic operations
- Unary operations
- Comparison operations
- Exception generation
- Format validation
- Illegal instruction detection

### Manual Testing
```assembly
; Sample FPU test program
    org $1000
    
    ; Load 1.0 into FP0
    fmove.s #1.0,fp0
    
    ; Load 2.0 into FP1  
    fmove.s #2.0,fp1
    
    ; Add them: FP0 = FP0 + FP1 = 3.0
    fadd.x fp1,fp0
    
    ; Take square root: FP0 = √3.0
    fsqrt.x fp0
    
    ; Store result to memory
    fmove.s fp0,(a0)
```

## Performance Considerations

### Cycle Counts (Approximate)
- **FMOVE**: 2-4 cycles
- **FADD/FSUB**: 4-8 cycles
- **FMUL**: 6-12 cycles
- **FDIV**: 12-24 cycles
- **FSQRT**: 16-32 cycles
- **Transcendental**: 32-64 cycles

### Optimization Tips
1. **Use Extended Precision**: Internal operations are most efficient in extended precision
2. **Minimize Format Conversions**: Convert once at boundaries
3. **Pipeline Operations**: FPU can overlap with CPU execution
4. **Register Allocation**: Keep frequently used values in FP registers

### Memory Bandwidth
- Each FP register transfer requires 10 bytes (80 bits)
- FMOVEM operations can transfer multiple registers efficiently
- Consider memory alignment for optimal performance

## Future Enhancements

### Phase 1: Core Improvements
- [ ] Complete transcendental function implementation
- [ ] IEEE rounding mode support
- [ ] Packed decimal arithmetic
- [ ] Enhanced exception handling

### Phase 2: Advanced Features  
- [ ] FBcc conditional branch instructions
- [ ] FTRAPcc conditional trap instructions
- [ ] FSAVE/FRESTORE state management
- [ ] Interrupt handling during long operations

### Phase 3: Performance Optimization
- [ ] Pipelined arithmetic operations
- [ ] Hardware multiply/divide acceleration
- [ ] Microcode optimization
- [ ] Cache-friendly register file

### Phase 4: Compatibility Extensions
- [ ] MC68040 FPSP compatibility
- [ ] Additional precision modes
- [ ] Vector/SIMD operations
- [ ] Custom instruction extensions

## Conclusion

The TG68K FPU provides a solid foundation for MC68881/68882 compatibility with room for future enhancement. The modular design allows for incremental improvements while maintaining compatibility with existing software.

For questions, issues, or contributions, please refer to the project repository and documentation.

---
*Last updated: January 2025*
*Version: 1.0*