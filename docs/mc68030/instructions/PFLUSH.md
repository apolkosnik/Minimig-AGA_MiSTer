# MC68030 PFLUSH Instruction Specification

## Document Purpose

This document specifies the PFLUSH (Purge entry in Address Translation Cache) instruction used to invalidate entries in the MC68030's ATC (Address Translation Cache).

---

## Overview

**PFLUSH** is a privileged instruction that invalidates (flushes) entries in the ATC. The ATC caches address translations from the MMU page tables, and PFLUSH allows software to ensure translations are reloaded after page table modifications.

### Basic Information

| Property | Value |
|----------|-------|
| **Mnemonic** | PFLUSH |
| **Privilege** | Supervisor only |
| **Opcode** | F-line (coprocessor instruction) |
| **Format** | F-line + extension word |
| **Introduced** | MC68030 (not in 68020) |
| **Execution Time** | 1-4 cycles (depends on mode) |

---

## Instruction Formats

PFLUSH has three main variants:

### 1. PFLUSHA - Flush All Entries

```assembly
PFLUSHA              ; Flush entire ATC (all 22 entries)
```

**Encoding:**
```
First Word (Opcode):    1111 0000 0000 0000    (0xF000)
Extension Word:         0010 0100 0000 0000    (0x2400)
```

**Operation:** Invalidates all 22 ATC entries. Use after major page table reorganization or when switching address spaces.

---

### 2. PFLUSH FC - Flush by Function Code

```assembly
PFLUSH  #<function_code>    ; Flush all entries matching FC
```

**Encoding:**
```
First Word (Opcode):    1111 0000 0000 0000    (0xF000)
Extension Word:         0010 0000 000f ff00    (0x2000 + FC << 8)
                        where fff = function code (3 bits)
```

**Operation:** Invalidates all ATC entries where the cached function code matches the specified FC value (0-7).

**Use Cases:**
- Flush all user space entries (FC=1 or 2)
- Flush all supervisor space entries (FC=5 or 6)
- Selective invalidation based on address space

---

### 3. PFLUSH FC,EA - Flush Specific Address

```assembly
PFLUSH  #<function_code>,<ea>    ; Flush entry for specific FC+address
```

**Encoding:**
```
First Word (Opcode):    1111 0000 00mm mrrr    (0xF000 + EA mode/reg)
Extension Word:         0011 0000 000f ff00    (0x3000 + FC << 8)
                        where mmm = EA mode, rrr = EA register, fff = FC
```

**Operation:** Invalidates the single ATC entry matching both the function code and effective address. Most precise form of flush.

**Use Cases:**
- Flush specific page after modification
- Minimal disruption to ATC contents
- Debugging specific translation issues

---

## Function Code Values

The function code (FC) specifies which address space to flush:

| FC | Binary | Address Space | Usage |
|----|--------|---------------|-------|
| 0 | 000 | (Undefined) | Reserved |
| 1 | 001 | User Data | Flush user data translations |
| 2 | 010 | User Program | Flush user code translations |
| 3 | 011 | (Undefined) | Reserved |
| 4 | 100 | (Undefined) | Reserved |
| 5 | 101 | Supervisor Data | Flush supervisor data |
| 6 | 110 | Supervisor Program | Flush supervisor code |
| 7 | 111 | CPU Space | Flush CPU space (rare) |

**Common Values:**
- **#1** - User data space
- **#5** - Supervisor data space

---

## Instruction Format Details

### First Word (Opcode)

```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 1   1   1   1   0   0   0   0   0   0  EA-mode   EA-register │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
  F-line prefix (0xF0xx)                    └─ Only for EA form
```

- **Bits 15-6:** `1111000000` - F-line coprocessor opcode
- **Bits 5-3:** EA mode (only for PFLUSH with EA)
- **Bits 2-0:** EA register (only for PFLUSH with EA)

For PFLUSHA and PFLUSH FC (no EA), the entire first word is `0xF000`.

---

### Extension Word

```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 0   0   1   0  Mod  0   0   0   0   0   0  FC2 FC1 FC0  0   0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
  └─────┬─────┘   │                         └────┬────┘
    MMU CP ID   Mode                       Function Code

Mode field (bits 13-11):
  000 = Reserved
  001 = PFLUSH FC,EA (0x3xxx)
  010 = PFLUSH FC     (0x2xxx)
  100 = PFLUSHA       (0x24xx)
```

- **Bits 15-13:** `010` - MMU coprocessor ID
- **Bits 12-11:** Mode bits
  - `00` = PFLUSHA
  - `01` = PFLUSH FC,EA
  - `10` = PFLUSH FC
- **Bits 10-5:** Reserved (must be 0)
- **Bits 4-2:** Function code (FC2, FC1, FC0)
- **Bits 1-0:** Reserved (must be 0)

---

## Effective Addressing Modes

For **PFLUSH FC,EA**, the following EA modes are supported:

| Mode | Description | Example |
|------|-------------|---------|
| 010 | Address register indirect | `PFLUSH #1,(A0)` |
| 101 | Address register indirect with displacement | `PFLUSH #1,100(A0)` |
| 110 | Address register indirect with index | `PFLUSH #1,10(A0,D0.L)` |
| 111/000 | Absolute short | `PFLUSH #1,$4000.W` |
| 111/001 | Absolute long | `PFLUSH #1,$00080000.L` |
| 111/010 | PC with displacement | `PFLUSH #1,label(PC)` |
| 111/011 | PC with index | `PFLUSH #1,label(PC,D0.L)` |

**Not Supported:**
- Data register direct (Dn)
- Address register direct (An)
- Immediate (#imm)
- Post-increment/pre-decrement

---

## Usage Examples

### Example 1: Flush Entire ATC

```assembly
; After major page table reorganization
PFLUSHA                 ; Flush all 22 ATC entries
```

**Use Case:** Switching between completely different address spaces, or after rebuilding entire page table tree.

---

### Example 2: Flush User Space

```assembly
; After modifying user page tables
MOVE.L  #1,D0          ; Function code 1 = user data
PFLUSH  #1             ; Flush all user data translations
```

**Use Case:** Operating system modified user memory mappings and needs to ensure ATC doesn't have stale entries.

---

### Example 3: Flush Specific Page

```assembly
; After modifying single page table entry
LEA     user_page,A0   ; Address of modified page
PFLUSH  #1,(A0)        ; Flush only that specific page translation
```

**Use Case:** Changed protection or mapping for a single page. Most efficient - only affects one ATC entry.

---

### Example 4: Flush Supervisor Code Space

```assembly
; After loading new supervisor code
PFLUSH  #6             ; Flush supervisor program space
```

**Use Case:** JIT compiler or dynamic code loading in supervisor mode.

---

## Operation Details

### PFLUSHA Operation

```
1. Invalidate all 22 ATC entries
2. Next access to any address will cause ATC miss
3. MMU will perform table walk to refill ATC
4. Execution time: ~4 cycles
```

**Side Effects:**
- Entire ATC becomes empty
- Next 22 memory accesses may be slower (table walks)
- No effect on page tables in memory

---

### PFLUSH FC Operation

```
1. Scan all 22 ATC entries
2. For each entry:
   IF entry.function_code == specified_FC THEN
       Invalidate entry
   END IF
3. Execution time: ~2-3 cycles
```

**Side Effects:**
- Only entries matching FC are invalidated
- Other entries remain cached
- Faster than PFLUSHA if only one address space modified

---

### PFLUSH FC,EA Operation

```
1. Calculate effective address
2. Extract page number from address (bits 31-8 for 256-byte pages)
3. Search ATC for entry matching both FC and page number
4. If found:
      Invalidate that single entry
   Else:
      No operation (entry not in ATC)
5. Execution time: ~1-2 cycles
```

**Side Effects:**
- At most one entry invalidated
- Minimal impact on ATC performance
- Preferred method when only one page changed

---

## Privilege and Exceptions

### Privilege

**PFLUSH is supervisor-only.** Executing in user mode causes:

```
EXCEPTION: Privilege Violation (Vector $20)
```

**Privilege Check:**
```
IF SR.S = 0 THEN
    TRAP #PrivilegeViolation
END IF
```

---

### Illegal Instruction

Invalid forms of PFLUSH cause illegal instruction exception:

**Causes:**
- Invalid mode bits in extension word
- Reserved bits not zero
- Invalid EA mode for PFLUSH FC,EA
- Function code > 7 (impossible with 3 bits, but check anyway)

---

## Timing

| Variant | Best Case | Typical | Worst Case |
|---------|-----------|---------|------------|
| PFLUSHA | 4 cycles | 4 cycles | 4 cycles |
| PFLUSH FC | 2 cycles | 2 cycles | 3 cycles |
| PFLUSH FC,EA | 1 cycle | 2 cycles | 3 cycles |

**Notes:**
- Timing includes EA calculation for FC,EA form
- No memory access required (internal operation only)
- Does NOT wait for pending bus cycles

---

## Interaction with Other Instructions

### PFLUSH + PMOVE

Typical sequence when modifying MMU registers:

```assembly
; Modify TC register
LEA     new_tc,A0
PMOVE   (A0),TC        ; Load new translation control
PFLUSHA                ; Flush ATC (new page size/format)
```

**Why:** Changing TC (page size, table levels) makes existing ATC entries invalid.

---

### PFLUSH + Page Table Modification

```assembly
; Modify page table entry
MOVE.L  #new_pte,A0    ; Address of page table entry
MOVE.L  #new_value,(A0) ; Update PTE
PFLUSH  #1,page_addr   ; Flush ATC for that page
```

**Why:** ATC caches page table lookups. After modifying PTE, flush corresponding ATC entry.

---

### PFLUSH + MOVES

```assembly
; Safely access user memory
MOVEC   #1,DFC         ; Set DFC to user data
LEA     user_addr,A0
MOVES.L (A0),D0        ; Read from user space
; No PFLUSH needed - MOVES doesn't use ATC (?) - check manual
```

**Note:** MOVES may or may not use ATC depending on implementation. Check MC68030 manual for details.

---

## Implementation in TG68K030

### Required Components

1. **PFLUSH Decoder** (similar to PMOVE decoder)
   - Detect F-line opcode
   - Decode extension word (mode bits, FC)
   - Validate privilege
   - Extract EA for FC,EA form

2. **ATC Flush Logic**
   - Iterate over 22 ATC entries
   - Match by FC (for PFLUSH FC)
   - Match by FC+address (for PFLUSH FC,EA)
   - Invalidate matched entries

3. **Integration**
   - Add to instruction decoder
   - Connect to ATC module
   - Exception handling (privilege, illegal)

---

## Pseudo-VHDL Interface

```vhdl
entity TG68K030_PFLUSH_Decoder is
    port(
        opcode          : in  std_logic_vector(15 downto 0);
        extension       : in  std_logic_vector(15 downto 0);
        opcode_valid    : in  std_logic;
        supervisor      : in  std_logic;

        is_pflush       : out std_logic;
        pflush_mode     : out std_logic_vector(1 downto 0);  -- 00=A, 01=FC,EA, 10=FC
        pflush_fc       : out std_logic_vector(2 downto 0);
        pflush_ea_mode  : out std_logic_vector(2 downto 0);
        pflush_ea_reg   : out std_logic_vector(2 downto 0);

        illegal_instr   : out std_logic;
        priv_violation  : out std_logic
    );
end entity;

entity TG68K030_PFLUSH_Execute is
    port(
        pflush_start    : in  std_logic;
        pflush_mode     : in  std_logic_vector(1 downto 0);
        pflush_fc       : in  std_logic_vector(2 downto 0);
        ea_addr         : in  std_logic_vector(31 downto 0);

        atc_invalidate  : out std_logic;
        atc_inv_mode    : out std_logic_vector(1 downto 0);  -- Match mode
        atc_inv_fc      : out std_logic_vector(2 downto 0);
        atc_inv_addr    : out std_logic_vector(31 downto 0);

        pflush_done     : out std_logic
    );
end entity;
```

---

## Comparison with Other Processors

### MC68020

**Not available.** MC68020 has no PFLUSH instruction.

- No ATC in 68020
- No equivalent instruction
- Page table modifications don't need flushing

---

### MC68030

**Three forms:**
- PFLUSHA
- PFLUSH FC
- PFLUSH FC,EA

**22-entry ATC** requires explicit flushing.

---

### MC68040

**Enhanced PFLUSH:**
- Same three basic forms
- Additional PFLUSHN (don't flush global pages)
- Larger ATC (64 entries)
- Separate instruction and data ATCs

---

## AmigaOS Usage

### Typical Usage

```assembly
; AmigaOS mmu.library typically uses:
PFLUSHA                ; After major remapping

; For single page modifications:
PFLUSH  #1,page_addr   ; User data page changed
```

### Enforcer Tool

The Enforcer memory debugging tool for Amiga uses PFLUSH to:
1. Set up protected pages
2. Catch illegal memory access
3. Flush ATC after changing protection

---

## Testing Requirements

### Unit Tests

1. **Decode Tests**
   - PFLUSHA detection
   - PFLUSH FC detection
   - PFLUSH FC,EA detection
   - Invalid mode detection
   - Privilege checking

2. **Execution Tests**
   - PFLUSHA invalidates all entries
   - PFLUSH FC matches function code
   - PFLUSH FC,EA matches both FC and address
   - Proper ATC interface signaling

3. **Edge Cases**
   - All FC values (0-7)
   - All supported EA modes
   - Reserved bit handling

---

## Implementation Checklist

- [ ] Create PFLUSH decoder module
- [ ] Decode PFLUSHA (mode=00)
- [ ] Decode PFLUSH FC (mode=10)
- [ ] Decode PFLUSH FC,EA (mode=01)
- [ ] Extract function code (3 bits)
- [ ] EA mode support
- [ ] Create PFLUSH executor
- [ ] Interface to ATC (invalidate entries)
- [ ] Privilege checking
- [ ] Create unit tests
- [ ] Test all three modes
- [ ] Integration with TG68K030

---

## Summary

### What PFLUSH Does ✅
- Invalidates ATC entries (cached address translations)
- Three modes: all, by FC, by FC+address
- Supervisor-only privilege
- Fast execution (1-4 cycles)

### When to Use PFLUSH
- After modifying page tables
- After loading new MMU registers (TC, CRP, SRP, TT0, TT1)
- When switching address spaces
- After changing memory protection

### Integration Points
- F-line instruction decoder
- ATC module (invalidation interface)
- Exception handling (privilege, illegal)
- EA calculation (for FC,EA mode)

---

## References

- MC68030 User's Manual, Section 6 (MMU)
- MC68030 User's Manual, Section 9 (Instruction Set)
- MC68030 User's Manual, Section 6.2.5 (PFLUSH description)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created PFLUSH specification |
