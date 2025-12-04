# TG68K Register Reference

This document contains detailed register specifications for the TG68K 68030 implementation.

## Control Registers (Accessible via MOVEC)

### CACR - Cache Control Register (0x002) - 32-bit
**Current Implementation** (`rtl/tg68k/TG68KdotC_Kernel.vhd`):
```
Bit 0 (EI): Instruction Cache Enable
Bit 1 (FI): Cache Freeze (inhibit replacement)
Bit 2 (CEI): Clear Entry in Instruction Cache
Bit 3 (CI): Clear Instruction Cache (self-clearing)
Bit 4 (IBE): Instruction Burst Enable
Bit 5: Reserved (reads 0)
Bit 6: Reserved (reads 0)
Bit 7: Reserved (reads 0)
Bit 8 (ED): Data Cache Enable
Bit 9 (FD): Data Cache Freeze (used by AmigaOS for 68030 detection)
Bit 10 (CED): Clear Entry in Data Cache
Bit 11 (CD): Clear Data Cache
Bit 12 (DBE): Data Burst Enable
Bit 13 (WA): Write Allocate
Bits 31-14: Reserved (should read as 0, writes ignored)
```

**Cache Control Logic**:
- Command bits (3-2, 11-10) are self-clearing and never stored
- Enable/freeze bits (1-0, 9-8) are sticky until explicitly changed
- Reserved bits (31-14, 7-5) are read as 0

### VBR - Vector Base Register (0x801) - 32-bit
```
Bits 31-0: Vector table base address (must be on 4-byte boundary)
```

### SFC - Source Function Code (0x000) - 3-bit
```
Bits 2-0: Function code for source operand of MOVES instruction
```

### DFC - Destination Function Code (0x001) - 3-bit
```
Bits 2-0: Function code for destination operand of MOVES instruction
```

### CAAR - Cache Address Access Register (0x802) - 32-bit
```
Bits 31-8: Cache Function Address
Bits 7-2: INDEX
Bits 1-0: Always 0
```

### USP - User Stack Pointer (0x800) - 32-bit
**Note**: Currently NULL operation in implementation
```
Bits 31-0: User mode stack pointer
```

### MSP - Master Stack Pointer (0x803) - 32-bit
**Note**: Currently NULL operation in implementation
```
Bits 31-0: Master mode stack pointer (68020+)
```

### ISP - Interrupt Stack Pointer (0x804) - 32-bit
**Note**: Currently NULL operation in implementation
```
Bits 31-0: Interrupt mode stack pointer (68020+)
```

## PMMU Registers (Accessible via PMOVE only)

### TC - Translation Control Register - 32-bit
**Register Select**: 0x0 (`rtl/tg68k/TG68K_PMMU_030.vhd`)
```
Bit 31 (E):      Enable MMU translation
Bit 30-26:       Reserved (forced to 0)
Bit 25 (SRE):    Supervisor Root Enable
Bit 24 (FCL):    Function Code Lookup
Bits 23-20 (PS): Page Size (4KB pages = 0000)
Bits 19-16 (IS): Initial Shift
Bits 15-12 (TIA): Table Index A field size
Bits 11-8 (TIB):  Table Index B field size
Bits 7-4 (TIC):   Table Index C field size
Bits 3-0 (TID):   Table Index D field size
```

#### TC - Page Size (PS) field
```
Page Size (PS) - 4-bit field specifies the system page size:
1000: 256 bytes
1001: 512 bytes
1010: 1K bytes
1011: 2K bytes
1100: 4K bytes
1101: 8K bytes
1110: 16K bytes
1111: 32K bytes

All other bit combinations are reserved by Motorola for future use; an
attempt to load other values into this field of the TC register causes an MMU configuration exception.
```

### CRP - CPU Root Pointer - 64-bit
**Register Select**: 0x1 (requires reg_part for high/low)
**Description**: Specifies the root table pointer used when CPU is in User mode

**MC68030 Root Pointer Format**:
```
+------------------------------------------------+
| ROOT POINTER (CRP/SRP)                         |
+-----+--------+---------------------------------+
| Bit | Length | Contents                        |
+-----+--------+---------------------------------+
| 00  |   04   | Reserved (must be 0)            |
| 04  |   28   | TableA Address (upper 28 bits)  |
| 32  |   02   | Descriptor Type (DT)            |
| 34  |   14   | Reserved (must be 0)            |
| 48  |   15   | Limit                           |
| 63  |   01   | L/U (Lower/Upper limit)         |
+-----+--------+---------------------------------+

HIGH (63-32):
  Bit 63 (L/U): Lower or Upper limit flag
  Bits 62-48 (LIMIT): Maximum or minimum value for indexing TableA
  Bits 47-34: Reserved (forced to 0)
  Bits 33-32 (DT): Descriptor Type (2 bits)
    00 = INVALID (causes MMU exception)
    01 = PAGE DESCRIPTOR (early termination, transparent translation)
    10 = VALID 4 BYTE (TableA uses short 4-byte entries)
    11 = VALID 8 BYTE (TableA uses long 8-byte entries)

LOW (31-0):
  Bits 31-4: TableA Address (upper 28 bits)
  Bits 3-0: Reserved (forced to 0)
```

**TableA Address**: Only upper 28 bits specified, so TableA must be aligned to 16-byte boundary

**Limit Usage**:
- When L/U=1: Limit specifies unsigned upper limit for table index
- When L/U=0: Limit specifies unsigned lower limit for table index
- To disable limit checking:
  - L/U=0, LIMIT=0x7FFF (no lower limit)
  - L/U=1, LIMIT=0x0000 (no upper limit)

**Special Cases**:
- DT=01, TableA Address=0: Transparent translation of entire memory space
- Limit field can reduce TableA size by limiting valid index range

### SRP - Supervisor Root Pointer - 64-bit
**Register Select**: 0x2 (requires reg_part for high/low)
**Description**: Specifies the root table pointer used when CPU is in Supervisor mode
```
Same format as CRP - provides separate page tables for supervisor mode
```

### SHORT-FORMAT TABLE DESCRIPTOR - 32-bit
```
Bits 31-4: Table Address
Bit 3 (U):
Bit 2 (WP):
Bits 1-0 (DT): Descriptor Type
```

### LONG-FORMAT TABLE DESCRIPTOR - 2*32-bit
```
HIGH:
  Bit 31 (L/U): Lower or Upper
  Bits 30-16 (LIMIT):
  Bits 15-10: Reserved (forced to 1)
  Bit 9: Reserved (forced to 0)
  Bit 8 (S):
  Bits 7-4: Reserved (forced to 0)
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-4: Table Address
  Bits 3-0 (UNUSED): forced to 0
```

### SHORT-FORMAT EARLY TERMINATION PAGE DESCRIPTOR - 32-bit
```
Bits 31-8: Page Address
Bit 7: Unused (forced to 0)
Bit 6 (CI):
Bit 5:Unused (forced to 0)
Bit 4 (M):
Bit 3 (U):
Bit 2 (WP):
Bits 1-0 (DT): Descriptor Type
```

### LONG-FORMAT EARLY TERMINATION PAGE DESCRIPTOR - 2*32-bit
```
HIGH:
  Bit 31 (L/U): Lower or Upper
  Bits 30-16 (LIMIT):
  Bits 15-10: Reserved (forced to 1)
  Bit 9: Reserved (forced to 0)
  Bit 8 (S):
  Bit 7: Reserved (forced to 0)
  Bit 6 (CI):
  Bit 5:Unused (forced to 0)
  Bit 4 (M):
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-8: Page Address
  Bits 7-0 (UNUSED): forced to 0
```

### LONG-FORMAT PAGE DESCRIPTOR - 2*32-bit
```
HIGH:
  Bits 31-16: Unused (forced to 0)
  Bits 15-10: Reserved (forced to 1)
  Bit 9: Reserved (forced to 0)
  Bit 8 (S):
  Bit 7: Reserved (forced to 0)
  Bit 6 (CI):
  Bit 5:Unused (forced to 0)
  Bit 4 (M):
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-8: Page Address
  Bits 7-0 (UNUSED): forced to 0
```

### SHORT-FORMAT INVALID DESCRIPTOR - 32-bit
```
Bits 31-2: Unused (forced to 0)
Bits 1-0 (DT): Descriptor Type
```

### LONG-FORMAT INVALID DESCRIPTOR - 2*32-bit
```
HIGH:
  Bits 31-2: Unused (forced to 0)
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-0: Unused (forced to 0)
```

### SHORT-FORMAT INDIRECT DESCRIPTOR - 32-bit
```
Bits 31-2 (DESCRIPTOR ADDRESS):
Bits 1-0 (DT): Descriptor Type
```

### LONG-FORMAT INDIRECT DESCRIPTOR - 2*32-bit
```
HIGH:
  Bits 31-2: Unused (forced to 0)
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-2 (DESCRIPTOR ADDRESS):
  Bits 1-0 (UN):
```

### TT0 - Transparent Translation Register 0 - 32-bit
**Register Select**: 0x3

#### MC68030 TTR format
```
Bits 31-24: Logical Address Base
Bits 23-16: Logical Address Mask
Bit 15 (E):  Enable
Bits 14-11: Reserved (forced to 0)
Bits 10 (CI): Cache Inhibit
Bit 9 (RW):   Read/Write
Bit 8 (RWM):  Read/Write Mask
Bit 7:       Reserved (forced to 0)
Bits 6-4:    Function Code Base
Bit 3:       Reserved (forced to 0)
Bits 2-0:    Function Code Mask
```

### TT1 - Transparent Translation Register 1 - 32-bit
**Register Select**: 0x4
```
Same format as TT0
```

### MMUSR - MMU Status Register - 16-bit
**Register Select**: 0x5
```
Bit 15 (B):  Bus Error [READ-ONLY]
Bit 14 (L):  Limit Violation [READ-ONLY]
Bit 13 (S):  Supervisor-Only [READ-ONLY]
Bit 12:      Reserved (forced to 0)
Bit 11 (W): Write Protected [READ-ONLY]
Bit 10 (I):  Invalid [READ-ONLY]
Bit 9 (M):   Modified [WRITE-1-TO-CLEAR]
Bits 8-7:    Reserved (forced to 0)
Bit 6 (T):   Transparent Access [READ-ONLY]
Bits 5-3:    Reserved (forced to 0)
Bits 2-0 (N):    Number of Levels [READ-ONLY]
```

**Write Semantics**: Per MC68030 specification, MMUSR is mostly read-only. Only the Modified bit (9) supports write-1-to-clear operation. All other bits are updated by MMU hardware only.

### CAL - Current Access Level - Not implemented in 68030
**Register Select**: 0x6
```
N/A
```

## PMMU Instruction Access
**Note**: PMMU registers (TC, TT0, TT1, MMUSR) attempted to be accessed via MOVEC
will trigger illegal instruction exceptions per MC68030 specification. Use PMOVE instead.

### PMOVE Error Handling (Enhanced MC68030 Compliance)
- **Privilege Violation**: PMOVE instructions require supervisor mode (SVmode='1')
  - User mode attempts generate privilege violation exception (trap_priv)
- **Invalid Register**: Unsupported register selectors generate illegal instruction exception (trap_illegal)
- **Address Alignment**: Memory EA operations enforce proper alignment
  - 32-bit registers (TC, TT0, TT1, MMUSR): 4-byte alignment required
  - 64-bit registers (CRP, SRP): 8-byte alignment recommended
  - Misaligned access triggers address error exception
- **Reserved Bits**: Write operations to reserved register bits are masked or ignored

## Cache Control Instruction Integration
```verilog
// From TG68KdotC_Kernel.vhd lines 533-536:
  cache_cinv_req  <= '1' when (exec(cache_cinv) = '1' or
                                CACR(2) = '1' or CACR(3) = '1' or CACR(10) = '1' or CACR(11) = '1') else '0';
  cache_cpush_req <= '1' when exec(cache_cpush) = '1' else '0';
```

## Coprocessor Primitives and their functions
```
**Processor Synchronization:
- Busy with Current Instruction
- Proceed with Next Instruction If No Trace
- Service Interrupts and Requery If Trace Enabled
- Proceed with Execution, Condition True/False
**Instruction Manipulation:
- Transfer Operation Word
- Transfer Words from Instruction Stream
**Exception Handling:
- Take Privilege Violation If S Bit Not Set
- Take Pre-Instruction Exception
- Take Mid-Instruction Exception
- Take Post-Instruction Exception
**General Operand Transfer:
- Evaluate and Pass (ea)
- Evaluate (ea) and Transfer Data
- Write to Previously Evaluated (ea)
- Take Address and Transfer Data
- Transfer to/from Top of Stack
**Register Transfer:
- Transfer CPU Register
- Transfer CPU Control Register
- Transfer Multiple CPU Registers
- Transfer Multiple Coprocessor Registers
- Transfer CPU SR and/or ScanPC
```

## MC68030 PFLUSH, PLOAD, PMOVE, PTEST Valid Addressing Modes

The valid addressing modes for the MMU instructions on the MC68030-which include `PFLUSH`, `PFLUSHA`, `PLOAD`, `PMOVE`, and `PTEST`-are strictly limited to **Control Alterable Addressing Modes**.

If any other addressing mode is used for an MMU instruction, the MC68030 initiates F-line emulator exception processing.

The Control Alterable Addressing Modes are those that are both designated as "Control" (used for control-related operations, including supervisor/MMU tasks) and "Alterable" (can be written to).

### Valid Addressing Modes for MC68030 MMU Instructions

The following addressing modes fall into the Control Alterable category supported by the MMU instructions:

| Addressing Mode Type | Assembler Syntax | Notes |
| :--- | :--- | :--- |
| **Data Register Direct** | `Dn` | Used by instructions like `PMOVE` for register transfer |
| **Address Register Indirect** | `(An)` | A mode classified as Control Alterable |
| **Address Register Indirect with Predecrement** | `-(An)` | A mode classified as Control Alterable |
| **Address Register Indirect with Displacement** | `(d16,An)` | A mode classified as Control Alterable |
| **Indexed Addressing Modes** | `(d8,An,Xn)`, `(bd,An,Xn)`, `([bd,An],Xn,od)`, `([bd,An,Xn],od)` | All forms of Address Register Indirect with Index and Memory Indirect modes are considered Control Alterable |
| **Absolute Short Addressing Mode** | `(xxx).W` | A mode classified as Control Alterable |
| **Absolute Long Addressing Mode** | `(xxx).L` | A mode classified as Control Alterable |

### Context for MMU Operations

1.  **PMOVE:** This instruction transfers data between a CPU register or memory location and one of the six MMU registers (CRP, SRP, TC, TT0, TT1, MMUSR). When transferring to or from a CPU register (e.g., `Dn`), the Data Register Direct mode (`Dn`) is utilized.
2.  **PFLUSH and PTEST:** Although the full set of Control Alterable modes applies, for `PFLUSH <ea>` and `PTEST <ea>`, the function is primarily to retrieve a logical address from memory or a register to search the Address Translation Cache (ATC) or tables. The addressing modes used for these operands must adhere to the Control Addressing Modes, which largely overlaps with the Control Alterable set when acting as a source.
3.  **Excluded Modes:** Certain addressing modes common in general CPU instructions are excluded due to the strict "Control Alterable" requirement:
    *   Address Register Direct (`An`)
    *   Address Register Indirect with Postincrement (`(An)+`)
    *   Program Counter (PC) relative modes (e.g., `(d16,PC)`, `(d8,PC,Xn)`, and PC memory indirect modes), because these are categorized as "Control" but **not** "Alterable".
    *   Immediate Data (`#<data>`), which is neither Control nor Alterable.
