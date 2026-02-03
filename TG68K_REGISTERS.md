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
Bits 2-0: Function code used for MOVES <ea>,Rn read operations
```

### DFC - Destination Function Code (0x001) - 3-bit
```
Bits 2-0: Function code used for MOVES Rn,<ea> write operations
```

### MOVES Instruction (Opcode 0x0E__)
**Encoding**: `0000 1110 ssEE EAAA` where ss=size (00=byte, 01=word, 10=long), EEE=EA mode, AAA=EA register
**Extension Word**:
```
Bit 15:     D/A flag (0=Data register, 1=Address register)
Bits 14-12: Register number (0-7)
Bit 11:     Direction (dr)
              0 = EA -> Rn (memory read using SFC)
              1 = Rn -> EA (memory write using DFC)
Bits 10-0:  Reserved (must be 0)
```
**Micro-states**: `moves0` (latch extension word, set up EA) -> `moves1` (perform bus access with FC override)
**Key signals**: `moves_direction` (latched `brief(11)`), `moves_reg` (latched `brief(15:12)`), `moves_bus_pending` (maintains FC override during bus cycle), `moves_writeback_pending` (defers register write for reads)
**Legal EA modes**: (An), (An)+, -(An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L
**Illegal EA modes**: Dn, An, PC-relative, Immediate (trap as illegal instruction)
**Privilege**: Supervisor-only; user mode triggers privilege violation exception

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
**P-Register Select**: `10000` (0x10) - extension word bits 14:10
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
**P-Register Select**: `10011` (0x13) - extension word bits 14:10 (requires reg_part for high/low)
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
**P-Register Select**: `10010` (0x12) - extension word bits 14:10 (requires reg_part for high/low)
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
**P-Register Select**: `00010` (0x02) - extension word bits 14:10

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
**P-Register Select**: `00011` (0x03) - extension word bits 14:10
```
Same format as TT0
```

### MMUSR - MMU Status Register - 16-bit
**P-Register Select**: `11000` (0x18) - extension word bits 14:10
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
**P-Register Select**: 0x6 (not used)
```
N/A
```

## PMMU Instruction Access
**Note**: PMMU registers (TC, TT0, TT1, MMUSR) attempted to be accessed via MOVEC
will trigger illegal instruction exceptions per MC68030 specification. Use PMOVE instead.

### PMOVE Instruction (Opcode F0xx - F-Line)
All PMMU instructions share the F-line opcode space, differentiated by the extension word.

**Opcode**: `1111 0000 00EE EAAA` where EEE=EA mode, AAA=EA register
**Extension Word**:
```
Bits 15-13: Instruction type dispatch
              000 = PMOVE/PMOVEFD (TT0/TT1)
              001 = PFLUSH (bits 12:10=001) / PLOAD (bits 12:10=000)
              010 = PMOVE/PMOVEFD (TC/SRP/CRP)
              011 = PMOVE (MMUSR)
              100 = PTEST
Bits 14-10: P-register selector (5-bit)
              00010 = TT0    (group 000)
              00011 = TT1    (group 000)
              10000 = TC     (group 010)
              10010 = SRP    (group 010)
              10011 = CRP    (group 010)
              11000 = MMUSR  (group 011)
Bit 9:      Direction (RW)
              0 = Write to MMU register (EA -> MMU)
              1 = Read from MMU register (MMU -> EA)
Bit 8:      FD (Flush Disable) - PMOVEFD variant when set
Bits 7-0:   Reserved (must be 0)
```

**Transfer sizes**:
- TC, TT0, TT1: 32-bit (longword, `datatype="10"`)
- CRP, SRP: 64-bit (two longword bus cycles, high word first via `reg_part`)
- MMUSR: 16-bit (word, `datatype="01"`)

**Execution paths** (in `TG68KdotC_Kernel.vhd`):

| EA Mode | Write to MMU (RW=0) | Read from MMU (RW=1) |
| :--- | :--- | :--- |
| Dn | `set_exec(pmmu_wr)` -> `idle` or `pmove_dn_hi` (64-bit) | `set(pmmu_rd)` -> `pmmu_dn_read_wait` or `pmove_dn_hi` (64-bit) |
| (An), (An)+, -(An) | EA direct -> `pmove_mem_to_mmu_hi` | `set_exec(pmmu_rd)` -> `pmove_mmu_to_mem_hi` |
| (d16,An) | EA build -> `ld_dAn1` -> `pmove_mem_to_mmu_hi` | EA build -> `ld_dAn1` -> `pmove_mmu_to_mem_hi` |
| (d8,An,Xn) | EA build -> `ld_AnXn1` -> `pmove_mem_to_mmu_hi` | EA build -> `ld_AnXn1` -> `pmove_mmu_to_mem_hi` |
| (xxx).W, (xxx).L | EA build -> `ld_nn` -> `pmove_mem_to_mmu_hi` | `set_exec(pmmu_rd)` -> `pmove_mmu_to_mem_hi` |

For 64-bit registers (CRP/SRP), `_hi` states chain to `_lo` states for the second longword.

**Key implementation signals**:
- `pmmu_brief` - latched copy of `brief`, stable throughout F-line execution (brief itself gets overwritten by EA extension words)
- `fline_opcode_latch` - latched copy of `opcode` for EA mode checks (opcode may advance to next instruction during execution)
- `pmmu_reg_sel_int` - combinational register selector from `pmmu_brief(14:10)`
- `pmmu_reg_we_d` / `pmmu_reg_re_d` - registered write/read enables gated by `pmmu_reg_sel_valid`
- `reg_part` - tracks high ('1') vs low ('0') word for 64-bit CRP/SRP transfers
- `set(longaktion)` - required for 32-bit memory transfers (not set for MMUSR)
- `set(presub)` / `set(pmmu_dbl)` - needed for -(An) mode with 64-bit registers

### PMOVE Error Handling (Enhanced MC68030 Compliance)
- **Privilege Violation**: PMOVE instructions require supervisor mode (SVmode='1')
  - User mode attempts generate privilege violation exception (trap_priv)
- **Invalid Register**: Unsupported register selectors generate illegal instruction exception (trap_illegal)
- **Address Alignment**: Memory EA operations enforce proper alignment
  - 16-bit register (MMUSR): 2-byte alignment required
  - 32-bit registers (TC, TT0, TT1): 4-byte alignment required
  - 64-bit registers (CRP, SRP): 8-byte alignment recommended
  - Misaligned access triggers address error exception
- **Reserved Bits**: Write operations to reserved register bits are masked or ignored

## Exception Stack Frames

### Exception Vector Table (Key Implemented Vectors)

| Vector | Offset | Exception | Frame Format | Trap Signal |
|--------|--------|-----------|-------------|-------------|
| 2 | $008 | Bus Error | $A (16-word) | `trap_berr` |
| 3 | $00C | Address Error | $0 (4-word) | `trap_addr_error` |
| 4 | $010 | Illegal Instruction | $0 (4-word) | `trap_illegal` |
| 5 | $014 | Zero Divide | $2 (6-word) | `set_Z_error` |
| 6 | $018 | CHK/CHK2 | $2 (6-word) | `exec(trap_chk)` |
| 7 | $01C | TRAPV/TRAPcc | $2 (6-word) | `trap_trapv` |
| 8 | $020 | Privilege Violation | $0 (4-word) | `trap_priv` |
| 9 | $024 | Trace | $2 (6-word) | `trap_trace` |
| 10 | $028 | 1010 Emulator | $0 (4-word) | `trap_1010` |
| 11 | $02C | 1111 Emulator (F-line) | $0 (4-word) | `trap_1111` |
| 14 | $038 | Format Error | $0 (4-word) | `trap_format_error` |
| 24-31 | $060-$07C | Interrupts (Level 1-7) | $0 (4-word) | `trap_interrupt` |
| 32-47 | $080-$0BC | TRAP #0-#15 | $0 (4-word) | `trap_trap` |
| 56 | $0E0 | MMU Configuration | $0 (4-word) | `trap_mmu_config` |
| 61 | $0F4 | MMU Bus Error | $A (16-word) | `trap_mmu_berr` |

All vectors are offset from VBR (Vector Base Register). Vector address = VBR + offset.

### Stack Frame Format $0 - Four-Word Frame (8 bytes)
Used by most exceptions (privilege violation, illegal instruction, interrupts, TRAP #n, F-line, etc.)
```
Offset  Size  Content
$00     word  Status Register (SR)
$02     long  Program Counter (PC)
$06     word  Format/Vector Word: [15:12]=0000, [11:0]=vector offset
```

### Stack Frame Format $1 - Throwaway Frame (8 bytes)
Same layout as Format $0 but marked as "throwaway" for interrupt return.
```
Offset  Size  Content
$00     word  Status Register (SR)
$02     long  Program Counter (PC)
$06     word  Format/Vector Word: [15:12]=0001, [11:0]=vector offset
```

### Stack Frame Format $2 - Six-Word Frame (12 bytes)
Used by CHK, CHK2, cpTRAPcc, TRAPV, Trace, Zero Divide, MMU Configuration exceptions.
```
Offset  Size  Content
$00     word  Status Register (SR)
$02     long  Program Counter (PC)
$06     word  Format/Vector Word: [15:12]=0010, [11:0]=vector offset
$08     long  Instruction Address (address of faulting instruction)
```
Generated via `trap00` micro-state path when `cpu(1)='1'` and condition is TRAPV/CHK/Div0.

### Stack Frame Format $9 - Coprocessor Mid-Instruction Frame (20 bytes)
```
Offset  Size  Content
$00     word  Status Register (SR)
$02     long  Program Counter (PC)
$06     word  Format/Vector Word: [15:12]=1001, [11:0]=vector offset
$08     long  Instruction Address
$0C     long  Internal Registers (4 words)
```

### Stack Frame Format $A - Short Bus Fault Frame (32 bytes)
Generated by `berr1`..`berr8` micro-states for Bus Error (vector 2) and MMU Bus Error (vector 61).

```
Offset  Size  Content                              Pushed By  Data Source
$00     word  Status Register (SR)                 berr8      trap_SR & Flags
$02     word  Program Counter Hi                   berr8      TG68_PC(31:16)
$04     word  Program Counter Lo                   berr7      TG68_PC(15:0)
$06     word  Format ($A) / Vector Offset          berr7      "1010" & trap_vector(11:0)
$08     word  Internal Register (stub)             berr6      0x0000
$0A     word  Special Status Word (SSW) (stub)     berr6      0x0000
$0C     word  Instruction Pipe Stage B             berr5      opcode(15:0)
$0E     word  Instruction Pipe Stage C             berr5      last_opc_read(15:0)
$10     word  Fault Address Hi                     berr4      addr(31:16)
$12     word  Fault Address Lo                     berr4      addr(15:0)
$14     long  Internal Registers (stub)            berr3      0x00000000
$18     long  Data Output Buffer                   berr2      data_write_tmp
$1C     long  Internal Registers (stub)            berr1      0x00000000
```

**Push order**: berr1 pushes $1C (highest offset), berr8 pushes $00 (lowest offset / top of stack).

**SSW (Special Status Word)**: Currently stubbed as zero. MC68030 spec defines:
```
Bit 10 (DF): Data Fault
Bit 9 (RM):  Rerun/Modified flag
Bit 8 (RW):  Read/Write (1=read, 0=write)
Bits 6-4:    Function Code at fault time
Bits 3-0:    Reserved
```

### Stack Frame Format $B - Long Bus Fault Frame (92 bytes)
46 words total. Same initial layout as Format $A with additional internal state. Supported by RTE for unwinding (21 extra longwords discarded via `rte5` loop) but not currently generated by this implementation.

### Bus Error State Machine Detail

Entry condition: `interrupt='1' AND trap_berr='1' AND cpu(1)='1'` -> `next_micro_state <= berr1`

All berr states share: `setstate <= "11"` (write), `set(presub) <= '1'` (pre-decrement A7), `datatype <= "10"` (longword).

After berr8: `set_vectoraddr <= '1'`, `set(directPC) <= '1'`, `set(direct_delta) <= '1'` loads exception handler address from vector table (VBR + trap_vector).

### RTE Format Decoding

RTE reads the format/vector word during `rte2`/`rte3` and latches it into `rte_format_word`. In `rte4`, bits 15-12 select the unwinding path:

| `rte_format_word(15:12)` | Format | Action in rte4 | `rot_cnt` |
|--------------------------|--------|----------------|-----------|
| `"0000"` | $0 | Done (-> nop) | - |
| `"0001"` | $1 | Done (-> nop) | - |
| `"0010"` | $2 | Read 1 more longword (-> rte5) | 1 |
| `"1001"` | $9 | Read 3 more longwords (-> rte5) | 3 |
| `"1010"` | $A | Read 6 more longwords (-> rte5) | 6 |
| `"1011"` | $B | Read 21 more longwords (-> rte5) | 21 |
| Others | - | Format Error (vector 14) | - |

The `rte5` state loops: each iteration reads one longword from the stack (post-increment A7), decrements `rot_cnt`, and exits to `nop` when `rot_cnt` reaches 1.

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
