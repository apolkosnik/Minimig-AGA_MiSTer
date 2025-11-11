# MC68030 PMOVE Instruction Specification

## Document Purpose

This document specifies the PMOVE (Privileged Move) instruction used to access MMU control registers in the MC68030.

## Overview

**PMOVE** is a privileged instruction that moves data between MMU control registers and memory or general-purpose registers.

| Aspect | Details |
|--------|---------|
| **Mnemonic** | PMOVE, PMOVEFD |
| **Privilege** | Supervisor only |
| **Introduced** | MC68851 PMMU (external), integrated in MC68030 |
| **Purpose** | Access MMU control registers (TC, TT0, TT1, CRP, SRP, MMUSR) |
| **Sizes** | Word (16-bit), Long (32-bit), Quad (64-bit) depending on register |

## Instruction Format

PMOVE has a two-word minimum format with an optional extension word.

### First Word (Opcode)
```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 1   1   1   1   0   0   0   0   0   0 │   Mode    │  Register │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
 \___________F-line (1111)____________/
```

- **Bits 15-6**: `1111000000` (F-line opcode, coprocessor format)
- **Bits 5-3**: Effective address mode
- **Bits 2-0**: Effective address register

### Second Word (Extension)
```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 0   1   0 │ FD│   0   0   0   │ R/W │    MMU Register Code      │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
     CP-ID    │                   │
              │                   └─ Direction: 0=from reg, 1=to reg
              └───────────────────── FD bit (Flush Disable)
```

- **Bits 15-13**: `010` - Coprocessor ID for MMU
- **Bit 12**: **FD** (Flush Disable) - for PMOVEFD variant
- **Bits 11-9**: `000` (reserved)
- **Bit 8**: **R/W** - Direction
  - 0 = Memory/Register → MMU register (write to MMU)
  - 1 = MMU register → Memory/Register (read from MMU)
- **Bits 7-0**: MMU register select code

## MMU Register Codes

| Code | Register | Size | Access |
|------|----------|------|--------|
| 0x00 | TC | 32-bit (Long) | R/W |
| 0x02 | SRP | 64-bit (Quad) | R/W |
| 0x03 | CRP | 64-bit (Quad) | R/W |
| 0x10 | TT0 | 32-bit (Long) | R/W |
| 0x11 | TT1 | 32-bit (Long) | R/W |
| 0x18 | MMUSR | 16-bit (Word) | R/W |

**Note**: Some codes differ from MC68851 for compatibility with MC68040.

## Syntax

```assembly
PMOVE   <mmu_reg>,<ea>        ; Read MMU register to effective address
PMOVE   <ea>,<mmu_reg>        ; Write effective address to MMU register
PMOVEFD <mmu_reg>,<ea>        ; Read with flush disable
PMOVEFD <ea>,<mmu_reg>        ; Write with flush disable
```

### Examples

```assembly
; Write to TC
PMOVE   D0,TC                 ; Move D0 to TC
PMOVE   #$80808000,TC         ; Immediate to TC (with extension word)
PMOVE   (A0),TC               ; Memory to TC

; Read from TC
PMOVE   TC,D0                 ; Move TC to D0
PMOVE   TC,(A0)               ; Move TC to memory
PMOVE   TC,-(SP)              ; Push TC on stack

; 64-bit registers (CRP, SRP)
PMOVE   CRP,D0                ; Error: D0 is 32-bit, CRP is 64-bit
PMOVE   CRP,(A0)              ; OK: Move CRP (8 bytes) to memory at A0
PMOVE   (A0),CRP              ; OK: Load CRP from memory at A0

; TT0/TT1
PMOVE   #$FF000000,TT0        ; Set TT0 for I/O region
PMOVE   TT1,-(SP)             ; Save TT1

; MMUSR
PMOVE   MMUSR,D0              ; Read MMU status
```

## Effective Addressing Modes

### Allowed for PMOVE Source (when writing to MMU)

| Mode | Addressing | Allowed | Notes |
|------|------------|---------|-------|
| Dn | Data register direct | ✅ Yes | 32-bit only (not for CRP/SRP) |
| An | Address register direct | ❌ No | - |
| (An) | Address register indirect | ✅ Yes | All sizes |
| (An)+ | Postincrement | ✅ Yes | All sizes |
| -(An) | Predecrement | ✅ Yes | All sizes |
| (d16,An) | With displacement | ✅ Yes | All sizes |
| (d8,An,Xn) | With index | ✅ Yes | All sizes |
| (xxx).W | Absolute short | ✅ Yes | All sizes |
| (xxx).L | Absolute long | ✅ Yes | All sizes |
| (d16,PC) | PC with displacement | ✅ Yes | All sizes |
| (d8,PC,Xn) | PC with index | ✅ Yes | All sizes |
| #<data> | Immediate | ✅ Yes | All sizes |

### Allowed for PMOVE Destination (when reading from MMU)

Same as source, **except**:
- ❌ Immediate mode not allowed (can't write to immediate)
- ❌ PC-relative modes not allowed (can't write to PC-relative)

**Valid for destination**:
- ✅ Data register direct (Dn)
- ✅ All memory addressing modes
- ❌ Immediate
- ❌ PC-relative

## Operation

### PMOVE from Memory to MMU Register
```
1. Decode instruction
2. Check privilege (supervisor mode)
3. Calculate effective address
4. Read data from EA (word/long/quad depending on register)
5. Write data to MMU register
6. If FD=0 and register is CRP/SRP: flush ATC
```

### PMOVE from MMU Register to Memory
```
1. Decode instruction
2. Check privilege (supervisor mode)
3. Read data from MMU register
4. Calculate effective address
5. Write data to EA (word/long/quad depending on register)
6. If FD=0 and register is CRP/SRP: flush ATC
```

## PMOVEFD (Flush Disable)

When the **FD bit is set** (PMOVEFD):
- Prevents automatic ATC flush on CRP/SRP write
- Useful when updating multiple MMU registers atomically
- Programmer must explicitly PFLUSH after updates

**Without FD** (normal PMOVE):
```assembly
PMOVE   (A0),CRP              ; CRP updated, ATC automatically flushed
```

**With FD** (PMOVEFD):
```assembly
PMOVEFD (A0),CRP              ; CRP updated, ATC NOT flushed
PMOVEFD (A1),SRP              ; SRP updated, ATC NOT flushed
PFLUSH                        ; Manually flush ATC
```

## Data Sizes by Register

| Register | Size | Bytes | Words | Format |
|----------|------|-------|-------|--------|
| TC | Long | 4 | 2 | Single longword |
| TT0 | Long | 4 | 2 | Single longword |
| TT1 | Long | 4 | 2 | Single longword |
| MMUSR | Word | 2 | 1 | Single word |
| CRP | Quad | 8 | 4 | Two longwords (upper, lower) |
| SRP | Quad | 8 | 4 | Two longwords (upper, lower) |

### Memory Format for 64-bit Registers

CRP and SRP are stored in memory as two consecutive longwords:

```
Address+0:  Upper longword (descriptor type, limit)
Address+4:  Lower longword (physical address)
```

Example:
```assembly
CRP_TABLE:
    DC.L    $80000000          ; Upper: DT=10 (short table), limit=0
    DC.L    $00100000          ; Lower: Address=$00100000

    PMOVE   CRP_TABLE,CRP      ; Load both longwords
```

## Privilege and Exceptions

### Privilege Violation
PMOVE is **supervisor only**. Executing in user mode causes:
- **Exception**: Privilege Violation (Vector 8)
- **Stack Frame**: Exception stack frame pushed
- **PC**: Points to PMOVE instruction

### Illegal Instruction
Invalid register codes or addressing modes cause:
- **Exception**: Illegal Instruction (Vector 4)

### Address Error
Misaligned access causes:
- **Exception**: Address Error (Vector 3)
- **Note**: CRP/SRP must be even-aligned (not quad-aligned)

## Timing

Approximate cycle counts (MC68030):

| Operation | Cycles | Notes |
|-----------|--------|-------|
| PMOVE Dn,<reg> | 6-8 | Register to MMU |
| PMOVE (An),<reg> | 10-12 | Memory to MMU |
| PMOVE <reg>,Dn | 6-8 | MMU to register |
| PMOVE <reg>,(An) | 10-12 | MMU to memory |
| With CRP/SRP flush | +20-40 | If ATC flush triggered |

**Note**: Exact timing depends on cache state and memory speed.

## Implementation Notes for TG68K030

### Decoding PMOVE

1. **Recognize F-line opcode**: `1111 0000 00xx xxxx`
2. **Check extension word**: Bits 15-13 = `010` (MMU coprocessor)
3. **Extract fields**:
   - FD bit (bit 12)
   - Direction (bit 8): 0=write to MMU, 1=read from MMU
   - Register code (bits 7-0)
   - EA mode and register (first word bits 5-0)

### State Machine

```
PMOVE_DECODE:
    - Verify supervisor mode
    - Extract register code
    - Extract EA mode
    - Determine data size (word/long/quad)
    - Go to PMOVE_READ or PMOVE_WRITE

PMOVE_READ (from memory to MMU):
    - Calculate effective address
    - Read data (word/long/quad)
    - Write to MMU register module
    - If CRP/SRP and FD=0: trigger ATC flush
    - Done

PMOVE_WRITE (from MMU to memory):
    - Read from MMU register module
    - Calculate effective address
    - Write data (word/long/quad)
    - If CRP/SRP and FD=0: trigger ATC flush
    - Done
```

### Integration with MMU Register Module

Connect PMOVE decoder to TG68K030_MMU_Registers:

```vhdl
-- PMOVE execution
pmove_active <= '1' when executing_pmove else '0';

-- Register select based on PMOVE register code
reg_addr <= pmove_reg_code(3 downto 0);

-- Size determination
reg_size <= "01" when pmove_reg_code = REG_CRP or pmove_reg_code = REG_SRP
            else "00";  -- Long/word

-- Direction
mmu_reg_write <= pmove_active and (not pmove_direction);
mmu_reg_read  <= pmove_active and pmove_direction;

-- Data path
mmu_data_in <= ea_data;  -- From effective address
ea_data_out <= mmu_data_out;  -- To effective address
```

### Register Code Mapping

```vhdl
-- Map PMOVE codes to register addresses
case pmove_reg_code is
    when x"00" => reg_addr <= "0000";  -- TC
    when x"02" => reg_addr <= "0101";  -- SRP
    when x"03" => reg_addr <= "0100";  -- CRP
    when x"10" => reg_addr <= "0010";  -- TT0
    when x"11" => reg_addr <= "0011";  -- TT1
    when x"18" => reg_addr <= "0110";  -- MMUSR
    when others => illegal_instruction <= '1';
end case;
```

## Differences from MC68851 (External PMMU)

The MC68030 integrated MMU has some differences from the external MC68851:

| Feature | MC68851 | MC68030 |
|---------|---------|---------|
| Register codes | Different | Slightly different codes |
| PSR register | Yes | No (replaced by MMUSR) |
| PCSR register | Yes | No |
| BAD/BAC registers | Yes | No |
| Long format tables | Yes | Yes (but simpler) |
| Short format tables | Yes | Yes |

**Note**: MC68030 is designed for forward compatibility with MC68040, so some codes match MC68040 rather than MC68851.

## Examples

### Example 1: Enable MMU
```assembly
; Set up TC to enable MMU with 4KB pages
MOVE.L  #$80A08000,D0       ; E=1, PS=10, IS=10, TIA=8
PMOVE   D0,TC               ; Write to TC
```

### Example 2: Setup Transparent Translation
```assembly
; Map I/O space 0xFF000000-0xFFFFFFFF
MOVE.L  #$FF00FF07,D0       ; Base=$FF00, Mask=$FF, E=1, CI=1
PMOVE   D0,TT0              ; Write to TT0
```

### Example 3: Load Page Tables
```assembly
; Set CRP to point to page tables
LEA     PAGE_ROOT,A0        ; Root table at PAGE_ROOT
MOVE.L  #$80000000,(A0)     ; Upper: DT=10 (short table)
MOVE.L  #$00100000,4(A0)    ; Lower: Address=$00100000
PMOVE   (A0),CRP            ; Load CRP (8 bytes), flush ATC
```

### Example 4: Save/Restore MMU State
```assembly
; Save MMU state
    LEA     MMU_SAVE,A0
    PMOVE   TC,(A0)+        ; Save TC (4 bytes)
    PMOVE   TT0,(A0)+       ; Save TT0 (4 bytes)
    PMOVE   TT1,(A0)+       ; Save TT1 (4 bytes)
    PMOVE   CRP,(A0)+       ; Save CRP (8 bytes)
    PMOVE   SRP,(A0)+       ; Save SRP (8 bytes)

; Restore MMU state
    LEA     MMU_SAVE,A0
    PMOVEFD (A0)+,TC        ; Restore TC, no flush
    PMOVEFD (A0)+,TT0       ; Restore TT0, no flush
    PMOVEFD (A0)+,TT1       ; Restore TT1, no flush
    PMOVEFD (A0)+,CRP       ; Restore CRP, no flush
    PMOVEFD (A0)+,SRP       ; Restore SRP, no flush
    PFLUSH                  ; Now flush ATC once
```

### Example 5: Check MMU Status
```assembly
; After PTEST, read MMUSR
    PTEST   (A0)            ; Test address translation
    PMOVE   MMUSR,D0        ; Read status
    BTST    #5,D0           ; Check R bit (resident)
    BNE     page_present    ; Page is resident
```

## Testing Requirements

### Unit Tests
- Decode all valid PMOVE variants
- Test all MMU register codes
- Test all effective addressing modes
- Verify privilege checking
- Test word/long/quad sizes
- Test PMOVEFD (flush disable)
- Test illegal combinations

### Integration Tests
- PMOVE writes to MMU register module
- PMOVE reads from MMU register module
- Effective address calculation correct
- Data transfer (word/long/quad) correct
- ATC flush triggered (when appropriate)
- Exception handling (privilege, illegal, address error)

### Compliance Tests
- Match MC68030 hardware behavior
- Timing (approximate)
- Exception priorities

## Summary

PMOVE is essential for:
- ✅ Configuring MMU (TC, TT0, TT1)
- ✅ Setting page table pointers (CRP, SRP)
- ✅ Reading MMU status (MMUSR)
- ✅ Saving/restoring MMU state
- ✅ Operating system memory management

Implementation requires:
1. F-line opcode decoder
2. Privilege checking
3. Register code decoder
4. Effective address calculation
5. Data size handling (word/long/quad)
6. Integration with MMU register module
7. Optional ATC flush trigger

## References

- MC68030 User's Manual, Section 9: Instruction Descriptions
- MC68030 User's Manual, Section 6: Memory Management Unit
- MC68851 PMMU User's Manual (for background)
- MC68040 User's Manual (for code compatibility)

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created PMOVE instruction specification |

