# TG68K FPU Quick Reference Card

## 🚀 Getting Started

### Enable FPU
```vhdl
TG68K_INSTANCE: TG68K
generic map(
    CPU => "11",          -- 68020+ required  
    FPU_Enable => 1       -- Enable FPU
)
```

### Basic Assembly Usage
```assembly
; Load constants
fmove.s #1.0,fp0      ; Load 1.0 into FP0
fmove.s #2.5,fp1      ; Load 2.5 into FP1

; Basic arithmetic  
fadd.x fp1,fp0        ; FP0 = FP0 + FP1 = 3.5
fsub.x fp1,fp0        ; FP0 = FP0 - FP1
fmul.x fp1,fp0        ; FP0 = FP0 * FP1  
fdiv.x fp1,fp0        ; FP0 = FP0 / FP1

; Store result
fmove.s fp0,(a0)      ; Store to memory
```

## 📋 Instruction Reference

### Data Movement
| Instruction | Format | Description |
|-------------|---------|-------------|
| `FMOVE` | `.B/.W/.L/.S/.D/.X` | Move floating-point data |
| `FMOVEM` | - | Move multiple FP registers |

### Arithmetic Operations  
| Instruction | Description | Cycles* |
|-------------|-------------|---------|
| `FADD` | Floating add | 4-8 |
| `FSUB` | Floating subtract | 4-8 |
| `FMUL` | Floating multiply | 6-12 |
| `FDIV` | Floating divide | 12-24 |
| `FABS` | Absolute value | 2-4 |
| `FNEG` | Negate | 2-4 |
| `FSQRT` | Square root | 16-32 |

### Comparison
| Instruction | Description |
|-------------|-------------|
| `FCMP` | Compare floating-point |
| `FTST` | Test against zero |

### Transcendental Functions
| Instruction | Description | Cycles* |
|-------------|-------------|---------|
| `FSIN` | Sine | 32-64 |
| `FCOS` | Cosine | 32-64 |
| `FTAN` | Tangent | 32-64 |
| `FATAN` | Arc tangent | 32-64 |
| `FLOGN` | Natural log | 32-64 |
| `FETOX` | e^x | 32-64 |

*Approximate cycle counts

## 🎯 Data Formats

### IEEE 754 Formats
| Format | Size | Range | Precision |
|--------|------|-------|-----------|
| Single | 32-bit | ±1.4×10⁻⁴⁵ to ±3.4×10³⁸ | ~7 digits |
| Double | 64-bit | ±4.9×10⁻³²⁴ to ±1.8×10³⁰⁸ | ~15 digits |
| Extended | 80-bit | ±3.4×10⁻⁴⁹³² to ±1.2×10⁴⁹³² | ~19 digits |

### Format Suffixes
- `.B` - Byte (8-bit integer)
- `.W` - Word (16-bit integer)  
- `.L` - Long (32-bit integer)
- `.S` - Single precision (32-bit float)
- `.D` - Double precision (64-bit float)
- `.X` - Extended precision (80-bit float)

## 🏗️ Register File

### FP Registers
- **FP0-FP7**: 8 registers, 80-bit each
- **Internal format**: IEEE extended precision
- **Usage**: General purpose floating-point storage

### Control Registers
- **FPCR**: Floating-Point Control Register
- **FPSR**: Floating-Point Status Register  
- **FPIAR**: Floating-Point Instruction Address Register

## ⚠️ Exception Handling

### Exception Types
| Code | Name | Description |
|------|------|-------------|
| `$05` | Division by Zero | Divide finite by zero |
| `$0C` | Unimplemented | Unsupported operation |
| `$10` | Illegal Instruction | Invalid F-line opcode |

### Status Flags
- **N**: Negative result
- **Z**: Zero result  
- **V**: Overflow occurred
- **C**: Carry/borrow occurred
- **X**: Extend flag

## 🔧 Programming Tips

### Performance Optimization
```assembly
; ✅ Good: Use extended precision internally
fmove.s (a0),fp0      ; Load single
fadd.x fp1,fp0        ; Compute in extended  
fmove.s fp0,(a1)      ; Store single

; ❌ Avoid: Unnecessary conversions
fmove.s (a0),fp0      ; Load single
fmove.d fp0,fp1       ; Convert to double
fadd.d fp1,fp0        ; Compute in double
fmove.s fp0,(a1)      ; Convert back to single
```

### Register Usage
```assembly
; ✅ Good: Keep working values in registers
fmove.s #3.14159,fp7  ; Load π once
fmul.x fp7,fp0        ; Use from register
fmul.x fp7,fp1        ; Reuse

; ❌ Avoid: Repeated memory loads  
fmul.s #3.14159,fp0   ; Load π from memory
fmul.s #3.14159,fp1   ; Load π again
```

### Error Handling
```assembly
; Check for exceptions after critical operations
fdiv.x fp1,fp0        ; Potential divide by zero
; (FPU sets exception flags automatically)
; CPU trap handler can check FPSR for details
```

## 🧪 Testing

### Basic Verification
```assembly
; Test basic arithmetic
fmove.s #1.0,fp0      ; Load 1.0
fmove.s #2.0,fp1      ; Load 2.0  
fadd.x fp1,fp0        ; Should give 3.0
fcmp.s #3.0,fp0       ; Compare with expected
; Check condition codes for equality
```

### Exception Testing
```assembly
; Test division by zero
fmove.s #1.0,fp0      ; Load 1.0
fmove.s #0.0,fp1      ; Load 0.0
fdiv.x fp1,fp0        ; Should generate exception
; Exception handler should be called
```

## 📚 Common Patterns

### Vector Operations
```assembly
; Process array of floats
lea array_start,a0
lea array_end,a1
loop:
    fmove.s (a0)+,fp0     ; Load element
    fabs.x fp0            ; Take absolute value
    fmove.s fp0,-4(a0)    ; Store back
    cmpa.l a1,a0          ; Check end
    blt.s loop            ; Continue if not done
```

### Math Library Function
```assembly
; Calculate distance: sqrt(x² + y²)
distance:
    fmove.s d0,fp0        ; Load x
    fmul.x fp0,fp0        ; x²
    fmove.s d1,fp1        ; Load y  
    fmul.x fp1,fp1        ; y²
    fadd.x fp1,fp0        ; x² + y²
    fsqrt.x fp0           ; √(x² + y²)
    fmove.s fp0,d0        ; Return result
    rts
```

### Matrix Multiplication Element
```assembly
; C[i][j] = A[i][k] * B[k][j] (single element)
matrix_mul_element:
    fmove.s #0.0,fp0      ; Initialize sum
    moveq #0,d0           ; k = 0
loop:
    ; Load A[i][k] and B[k][j], multiply, add to sum
    fmove.s A(a0,d0.w*4),fp1   ; A[i][k]
    fmul.s B(a1,d0.w*4),fp1    ; * B[k][j]  
    fadd.x fp1,fp0             ; Add to sum
    addq.w #1,d0               ; k++
    cmp.w #SIZE,d0             ; Check bound
    blt.s loop                 ; Continue
    fmove.s fp0,C(a2)          ; Store C[i][j]
    rts
```

---
*TG68K FPU Quick Reference v1.0*  
*For complete documentation, see TG68K_FPU_Documentation.md*