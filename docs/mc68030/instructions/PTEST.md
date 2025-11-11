# MC68030 PTEST Instruction Specification

## Document Purpose

This document specifies the PTEST (Test a Logical Address) instruction used to test MMU address translation without causing exceptions or modifying memory.

---

## Overview

**PTEST** is a privileged instruction that performs MMU address translation (table walk) without actually accessing the final memory location. It's primarily used for debugging MMU configurations and determining if a memory access would succeed.

### Basic Information

| Property | Value |
|----------|-------|
| **Mnemonic** | PTEST |
| **Privilege** | Supervisor only |
| **Opcode** | F-line (coprocessor instruction) |
| **Format** | F-line + extension word |
| **Introduced** | MC68020 (enhanced in MC68030) |
| **Execution Time** | Variable (depends on table levels) |

---

## Instruction Formats

PTEST has two main variants based on access level:

### 1. PTEST - Test Address Translation

```assembly
PTEST  #<function_code>,<ea>,#<level>         ; Test translation to specific level
PTEST  #<function_code>,<ea>,#<level>,A<n>    ; Test and return descriptor address
```

**Encoding:**
```
First Word (Opcode):    1111 0000 00mm mrrr    (0xF0xx + EA mode/reg)
Extension Word:         100R RRRR LLLL LF FFX
                        R = return register (An), L = level, F = FC, X = R/W
```

---

## Function Code Values

| FC | Binary | Address Space |
|----|--------|---------------|
| 0 | 000 | (Undefined) |
| 1 | 001 | User Data |
| 2 | 010 | User Program |
| 3 | 011 | (Undefined) |
| 4 | 100 | (Undefined) |
| 5 | 101 | Supervisor Data |
| 6 | 110 | Supervisor Program |
| 7 | 111 | CPU Space |

---

## Access Levels

The level parameter specifies how deep into the page table tree to walk:

| Level | Description | MC68030 Usage |
|-------|-------------|---------------|
| 0 | Stop at root pointer (CRP/SRP) | Check if root pointer valid |
| 1 | Stop after first table lookup | A-level table descriptor |
| 2 | Stop after second table lookup | B-level table descriptor |
| 3 | Stop after third table lookup | C-level page descriptor |
| 4 | Stop after fourth table lookup | (Not used in MC68030 3-level tables) |
| 5 | Stop after fifth table lookup | (Not used in MC68030) |
| 6 | Stop after sixth table lookup | (Not used in MC68030) |
| 7 | Stop at final page descriptor | Complete translation |

**Note:** MC68030 typically uses 3-level tables (levels 0-3), but hardware supports up to 7 levels for compatibility.

---

## Instruction Format Details

### First Word (Opcode)

```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 1   1   1   1   0   0   0   0   0   0  EA-mode   EA-register │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
  F-line prefix (0xF0xx)                  └──── Effective Address
```

- **Bits 15-6:** `1111000000` - F-line coprocessor opcode
- **Bits 5-3:** EA mode
- **Bits 2-0:** EA register

---

### Extension Word

```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 1   0   0   R   A   A   A  Lv Lv Lv  FC FC FC  R/W  0   0   0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
  └─────┬─────┘   │ └───┬───┘ └──┬──┘ └──┬──┘  │   Reserved
    MMU CP      Return  Level   FC    Access
    (100b)       An    (0-7)   (0-7)  (R=0/W=1)
```

- **Bits 15-13:** `100` - PTEST coprocessor subfunction
- **Bit 12:** R - Return register enable (1 = store descriptor address in An)
- **Bits 11-9:** Return register number (An, 0-7) if R=1
- **Bits 8-6:** Level (0-7)
- **Bits 5-3:** Function code (0-7)
- **Bit 2:** R/W - Access type (0=read, 1=write)
- **Bits 1-0:** Reserved (must be 0)

---

## MMUSR (MMU Status Register) Results

After PTEST execution, the MMUSR register contains the result:

```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ B   L   S   W   I   M   G   Txx C   R   0   0   0   0   0   0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

### MMUSR Bit Definitions

| Bit | Name | Description |
|-----|------|-------------|
| 15 | **B** | Bus Error - Translation would cause bus error |
| 14 | **L** | Limit Violation - Table limit exceeded |
| 13 | **S** | Supervisor Violation - Supervisor-only page accessed in user mode |
| 12 | **W** | Write Protect - Write to read-only page |
| 11 | **I** | Invalid - Page descriptor marked invalid |
| 10 | **M** | Modified - Page has been written to |
| 9 | **G** | Gate - Descriptor is a gate (not used in MC68030) |
| 8-7 | **T** | Transparent - Translation used transparent register (TT0/TT1) |
| 6 | **C** | ATC Hit - Translation found in ATC cache |
| 5 | **R** | Resident - Page is resident (opposite of paged out) |
| 4-0 | - | Reserved (read as 0) |

---

## Usage Examples

### Example 1: Test if Address is Accessible

```assembly
; Check if user can read from address
LEA     test_addr,A0
PTEST   #1,(A0),#7     ; FC=1 (user data), level=7 (complete)
PMOVE   MMUSR,D0       ; Get result
BTST    #15,D0         ; Check B (bus error) bit
BNE     .not_accessible
; Address is accessible
```

**Use Case:** Operating system checking if user memory address is valid before copying data.

---

### Example 2: Get Page Descriptor Address

```assembly
; Find where page descriptor is stored
LEA     page_addr,A0
PTEST   #5,(A0),#7,A1  ; FC=5 (super data), store descriptor in A1
; A1 now contains address of page descriptor
MOVE.L  (A1),D0        ; Read actual page descriptor
```

**Use Case:** Debugger or diagnostic tool examining page table structure.

---

### Example 3: Check Write Permission

```assembly
; Test if page is writable
LEA     buffer,A0
PTEST.W #1,(A0),#7     ; .W = write access test
PMOVE   MMUSR,D0
BTST    #12,D0         ; Check W (write protect) bit
BNE     .read_only
; Page is writable
```

**Use Case:** Virtual memory manager checking page protection before allowing write.

---

### Example 4: Walk Page Tables Level by Level

```assembly
; Examine each level of translation
LEA     virt_addr,A0

; Level 1 (A-table)
PTEST   #5,(A0),#1,A1
MOVE.L  (A1),D0        ; A-table descriptor

; Level 2 (B-table)
PTEST   #5,(A0),#2,A2
MOVE.L  (A2),D1        ; B-table descriptor

; Level 3 (C-table/page)
PTEST   #5,(A0),#3,A3
MOVE.L  (A3),D2        ; Page descriptor

; Check results in MMUSR after each level
```

**Use Case:** Detailed MMU debugging, examining translation at each step.

---

## Operation Details

### PTEST Execution Flow

```
1. Decode instruction (get FC, EA, level, return register)
2. Calculate effective address
3. Select root pointer (CRP or SRP based on FC)
4. Perform table walk:
   a. Start at root pointer
   b. For each level up to specified level:
      - Read table descriptor
      - Check for invalid/limit violations
      - Follow pointer to next table
   c. Stop at specified level or on error
5. Update MMUSR with results
6. If return register specified:
      Store descriptor address in An
7. Check ATC for this translation
8. Set MMUSR.C if found in ATC
```

---

## MMUSR Status Interpretation

### Success (Translation Valid)

```
MMUSR = 0x0000  (all zero)
  or
MMUSR = 0x0040  (bit 6 = ATC hit)
```

Translation succeeded, no errors. Access would succeed.

---

### Common Error Conditions

**Bus Error (MMUSR.B = 1, bit 15)**
- Invalid table descriptor
- Table pointer points to non-existent memory
- Would cause bus error on real access

**Invalid Page (MMUSR.I = 1, bit 11)**
- Page descriptor marked as invalid
- Page not mapped
- Would cause page fault exception

**Write Protect (MMUSR.W = 1, bit 12)**
- Page is read-only
- Write access test failed
- Would cause write protection exception

**Supervisor Violation (MMUSR.S = 1, bit 13)**
- Supervisor-only page
- User mode access test failed
- Would cause privilege violation

**Limit Violation (MMUSR.L = 1, bit 14)**
- Table index exceeds limit field
- Invalid address for table size
- Would cause limit violation exception

---

## Transparent Translation

If the address matches a transparent translation register (TT0 or TT1), PTEST will indicate this:

```
MMUSR.T = 01  (TT0 matched)
MMUSR.T = 10  (TT1 matched)
MMUSR.T = 11  (Both matched - TT0 takes precedence)
```

**Behavior:** No table walk performed, MMUSR updated immediately.

---

## ATC Interaction

PTEST checks the ATC before performing table walk:

```
IF translation found in ATC THEN
    MMUSR.C = 1  (ATC hit)
    Use cached translation (fast)
ELSE
    MMUSR.C = 0  (ATC miss)
    Perform table walk (slower)
END IF
```

**Note:** PTEST does **not** load translations into ATC. It only reads from ATC, doesn't update it.

---

## Effective Addressing Modes

PTEST supports memory addressing modes:

| Mode | Description | Example |
|------|-------------|---------|
| 010 | Address register indirect | `PTEST #1,(A0),#7` |
| 101 | Address register indirect with displacement | `PTEST #1,100(A0),#7` |
| 110 | Address register indirect with index | `PTEST #1,10(A0,D0.L),#7` |
| 111/000 | Absolute short | `PTEST #1,$4000.W,#7` |
| 111/001 | Absolute long | `PTEST #1,$80000.L,#7` |
| 111/010 | PC with displacement | `PTEST #1,label(PC),#7` |
| 111/011 | PC with index | `PTEST #1,label(PC,D0.L),#7` |

**Not Supported:**
- Data register direct
- Address register direct
- Immediate
- Post-increment/pre-decrement

---

## Privilege and Exceptions

### Privilege

**PTEST is supervisor-only.** User mode execution causes privilege violation:

```
EXCEPTION: Privilege Violation (Vector $20)
```

---

### PTEST Does NOT Cause Exceptions

**Key Feature:** PTEST never causes MMU-related exceptions, even if translation would fail:

- ❌ No bus error (even if descriptor invalid)
- ❌ No page fault (even if page invalid)
- ❌ No write protect exception
- ❌ No supervisor violation exception

**Instead:** All error conditions are reported in MMUSR, allowing software to examine them safely.

---

## Timing

| Operation | Cycles (Typical) |
|-----------|------------------|
| ATC hit | 2-3 cycles |
| Table walk (1 level) | 5-7 cycles |
| Table walk (2 levels) | 8-12 cycles |
| Table walk (3 levels) | 12-18 cycles |
| Transparent translation | 1-2 cycles |

**Note:** Timing depends on memory speed and cache hits.

---

## Use Cases

### 1. Operating System Memory Access Validation

```assembly
; Before accessing user memory, check if accessible
check_user_addr:
    PTEST   #1,(A0),#7     ; User data, complete translation
    PMOVE   MMUSR,D0
    BTST    #15,D0         ; Bus error?
    BNE     .invalid
    BTST    #11,D0         ; Invalid page?
    BNE     .invalid
    ; Address is valid
    RTS
.invalid:
    ; Handle invalid address
    RTS
```

---

### 2. Virtual Memory Manager

```assembly
; Check if page needs to be swapped in
vm_check_page:
    PTEST   #5,(A0),#7     ; Supervisor data
    PMOVE   MMUSR,D0
    BTST    #11,D0         ; Invalid (paged out)?
    BNE     .swap_in
    BTST    #10,D0         ; Modified?
    BNE     .needs_writeback
    RTS
.swap_in:
    ; Load page from disk
    BSR     load_page
    RTS
.needs_writeback:
    ; Page has been modified
    BSR     mark_dirty
    RTS
```

---

### 3. MMU Debugger

```assembly
; Print page table walk
debug_translation:
    LEA     addr,A0

    ; Level 1
    PTEST   #5,(A0),#1,A1
    BSR     print_descriptor

    ; Level 2
    PTEST   #5,(A0),#2,A2
    BSR     print_descriptor

    ; Level 3
    PTEST   #5,(A0),#3,A3
    BSR     print_descriptor

    ; Final MMUSR
    PMOVE   MMUSR,D0
    BSR     print_mmusr
    RTS
```

---

### 4. Memory Protection Tester

```assembly
; Test if address is writable by user
test_user_write:
    LEA     test_addr,A0
    PTEST.W #1,(A0),#7     ; User data, write access
    PMOVE   MMUSR,D0

    MOVE.W  D0,-(SP)       ; Save MMUSR
    BTST    #12,D0         ; Write protect?
    BNE     .read_only
    BTST    #13,D0         ; Supervisor only?
    BNE     .privileged
    BTST    #11,D0         ; Invalid?
    BNE     .unmapped

    MOVE.W  (SP)+,D0
    ; All checks passed, user can write
    MOVEQ   #0,D0
    RTS

.read_only:
    MOVE.W  (SP)+,D0
    MOVEQ   #-1,D0         ; Write protected
    RTS
.privileged:
    MOVE.W  (SP)+,D0
    MOVEQ   #-2,D0         ; Supervisor only
    RTS
.unmapped:
    MOVE.W  (SP)+,D0
    MOVEQ   #-3,D0         ; Not mapped
    RTS
```

---

## Implementation in TG68K030

### Required Components

1. **PTEST Decoder**
   - Detect F-line opcode with PTEST subfunction (100)
   - Extract level, FC, return register
   - Validate privilege

2. **PTEST Executor**
   - Perform table walk to specified level
   - Update MMUSR with results
   - Store descriptor address in An if requested
   - Check ATC for existing translation

3. **Integration**
   - Connect to MMU table walk logic
   - Connect to ATC lookup
   - Update MMUSR register
   - No exception generation

---

## Pseudo-VHDL Interface

```vhdl
entity TG68K030_PTEST_Decoder is
    port(
        opcode          : in  std_logic_vector(15 downto 0);
        extension       : in  std_logic_vector(15 downto 0);
        opcode_valid    : in  std_logic;
        supervisor      : in  std_logic;

        is_ptest        : out std_logic;
        ptest_level     : out std_logic_vector(2 downto 0);  -- 0-7
        ptest_fc        : out std_logic_vector(2 downto 0);  -- Function code
        ptest_rw        : out std_logic;                      -- 0=read, 1=write
        ptest_return_reg_en : out std_logic;                  -- Return descriptor address
        ptest_return_reg    : out std_logic_vector(2 downto 0); -- An register number
        ptest_ea_mode   : out std_logic_vector(2 downto 0);
        ptest_ea_reg    : out std_logic_vector(2 downto 0);

        illegal_instr   : out std_logic;
        priv_violation  : out std_logic
    );
end entity;

entity TG68K030_PTEST_Execute is
    port(
        ptest_start     : in  std_logic;
        ptest_level     : in  std_logic_vector(2 downto 0);
        ptest_fc        : in  std_logic_vector(2 downto 0);
        ptest_rw        : in  std_logic;
        ea_addr         : in  std_logic_vector(31 downto 0);

        mmu_walk_req    : out std_logic;                      -- Request table walk
        mmu_walk_level  : out std_logic_vector(2 downto 0);
        mmu_walk_fc     : out std_logic_vector(2 downto 0);
        mmu_walk_addr   : out std_logic_vector(31 downto 0);
        mmu_walk_done   : in  std_logic;
        mmu_walk_result : in  std_logic_vector(15 downto 0); -- MMUSR result
        mmu_desc_addr   : in  std_logic_vector(31 downto 0); -- Descriptor address

        mmusr_update    : out std_logic;                      -- Update MMUSR
        mmusr_data      : out std_logic_vector(15 downto 0); -- New MMUSR value

        return_reg_write : out std_logic;                     -- Write to An
        return_reg_data  : out std_logic_vector(31 downto 0); -- Descriptor address

        ptest_done      : out std_logic
    );
end entity;
```

---

## Comparison with Other Processors

### MC68020

**Basic PTEST:**
- Same instruction format
- 3-level page tables
- MMUSR update

---

### MC68030

**Enhanced PTEST:**
- Same as 68020
- Faster ATC lookup (22 entries vs 68020's 64)
- Transparent translation check (TT0/TT1)

---

### MC68040

**PTEST Variants:**
- PTESTR (read test)
- PTESTW (write test)
- Separate I/D MMUs
- Larger ATC

---

## AmigaOS Usage

### mmu.library

AmigaOS mmu.library uses PTEST for:

```c
// Check if address is accessible
BOOL IsAddressValid(void *addr) {
    // Assembly: PTEST #1,(addr),#7
    // Check MMUSR for errors
    return (mmusr & 0x8800) == 0; // No bus error or invalid
}

// Get page attributes
ULONG GetPageProtection(void *addr) {
    // PTEST and check MMUSR.W (write protect)
    // PTEST and check MMUSR.S (supervisor)
    return protection_flags;
}
```

### Enforcer Tool

Enforcer uses PTEST to:
1. Validate memory access before setting protection
2. Check if access would cause exception
3. Debug memory management issues

---

## Testing Requirements

### Unit Tests

1. **Decode Tests**
   - PTEST detection
   - Level extraction (0-7)
   - Function code extraction
   - Return register enable
   - R/W bit extraction
   - Privilege checking

2. **Execution Tests**
   - Table walk to each level (0-7)
   - MMUSR update with various conditions
   - Return register write
   - ATC hit detection
   - Transparent translation detection

3. **Edge Cases**
   - All levels (0-7)
   - All function codes (0-7)
   - Read and write tests
   - With and without return register

---

## Implementation Checklist

- [ ] Create PTEST decoder module
- [ ] Decode PTEST subfunction (bits 15-13 = 100)
- [ ] Extract level (3 bits, 0-7)
- [ ] Extract FC (3 bits)
- [ ] Extract R/W bit
- [ ] Extract return register enable and number
- [ ] Create PTEST executor
- [ ] Interface to MMU table walk logic
- [ ] Update MMUSR with results
- [ ] Store descriptor address in An if requested
- [ ] Check ATC for cached translation
- [ ] Create unit tests
- [ ] Test all levels and function codes
- [ ] Integration with TG68K030

---

## Summary

### What PTEST Does ✅
- Tests MMU address translation without side effects
- Walks page tables to specified level
- Updates MMUSR with translation results
- Optionally returns descriptor address
- Never causes exceptions (safe testing)

### When to Use PTEST
- Validating memory addresses before access
- Debugging MMU configurations
- Virtual memory management
- Memory protection verification
- Page table inspection

### Integration Points
- F-line instruction decoder
- MMU table walk logic
- ATC lookup
- MMUSR register
- Return register (An) write

---

## References

- MC68030 User's Manual, Section 6 (MMU)
- MC68030 User's Manual, Section 9 (Instruction Set)
- MC68030 User's Manual, Section 6.2.6 (PTEST description)
- MC68030 User's Manual, Section 6.1.6 (MMUSR register)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created PTEST specification |
