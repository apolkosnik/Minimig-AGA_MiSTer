# CRITICAL BUG #4: PMOVE "SZ" Bit Does Not Exist in MC68030

**Date**: 2025-11-18
**Severity**: CRITICAL
**Impact**: Incorrect instruction decoding, illegal instruction traps where none should occur
**File**: `rtl/tg68k/TG68KdotC_Kernel.vhd`

---

## Problem Description

The code incorrectly treats `brief(8)` as an "SZ" (size) bit for PMOVE instructions, allowing programmers to specify `.L` (longword) or `.D` (doubleword) transfers. **This bit field does not exist in the MC68030 PMOVE instruction format.**

According to MC68030 specification, PMOVE register transfers have **IMPLICIT size** determined by which P-register is being accessed, not by any size field in the extension word.

---

## MC68030 Specification

### PMOVE Extension Word Format

```
Bits 15-13: Format field (000, 010, 110 for different register groups)
Bits 14-10: P-register number
Bit 9:      Direction (0=to control register, 1=from control register)
Bits 8-0:   Mode-dependent fields (NOT a size selector!)
```

### Register Sizes (IMPLICIT, NOT PROGRAMMABLE)

| Register | P-Reg Selector | Size | Notes |
|----------|----------------|------|-------|
| TC       | 10000          | 32-bit | Always longword |
| CRP      | 10011          | 64-bit | Always double-longword |
| SRP      | 10010          | 64-bit | Always double-longword |
| TT0      | 00010          | 32-bit | Always longword |
| TT1      | 00011          | 32-bit | Always longword |
| MMUSR    | 11000          | 16-bit | Always word (zero-extended to 32-bit) |

**Key Point**: You cannot write `PMOVE.L CRP,D0` or `PMOVE.D TC,D0`. The assembler syntax is just `PMOVE CRP,D0`, and the size is implicit from the register.

---

## Buggy Code Analysis

### Location 1: Lines 4515-4520 (Illegal Instruction Check)

```vhdl
-- BUG #6 FIX: Validate SZ bit (brief(8)) - .D (SZ=1) only valid for CRP/SRP
ELSIF brief(8) = '1' AND NOT (brief(14 downto 10) = "10010" OR brief(14 downto 10) = "10011") THEN
    -- Illegal: .D (doubleword) on TC/TT0/TT1/MMUSR
    -- MC68030 spec: SZ=1 (.D) only valid for CRP (10011) and SRP (10010)
    trap_illegal <= '1';
    trapmake <= '1';
```

**Problem**: This traps as illegal any PMOVE to TC/TT0/TT1/MMUSR where bit 8 happens to be '1'. But bit 8 is NOT a size field! It may be legitimately '1' for other purposes (addressing mode, FC field in PMOVEFD, etc.).

### Location 2: Lines 4539-4551 (Dn Mode Size Selection)

```vhdl
-- BUG #6 FIX: Check SZ bit for dual-word transfer, not just register type
-- MC68030 spec: .D (SZ=1) means 64-bit transfer (CRP/SRP only, validated above)
--              .L (SZ=0) means 32-bit transfer (all registers)
IF brief(8) = '1' THEN
    -- .D (doubleword) - need second Dn transfer (only CRP/SRP reach here)
    next_micro_state <= pmmu_dn_high;
ELSE
    -- .L (longword) - single 32-bit transfer
    next_micro_state <= idle;
END IF;
```

**Problem**: The code uses `brief(8)` to determine if a second Dn register should be accessed. This is WRONG. The decision should be based on the P-register selector (`brief(14 downto 10)`), NOT bit 8.

**Consequence**:
- If you do `PMOVE TC,D0` and bit 8 happens to be '1', the code tries to read a second longword from D1 (wrong!)
- If you do `PMOVE CRP,D0` and bit 8 happens to be '0', the code only reads one longword (wrong! CRP is 64-bit!)

### Location 3: Lines 4669-4680 (Memory EA Mode - CORRECT!)

```vhdl
WHEN pmmu2 =>
    set_exec(pmmu_wr) <= '1';
    -- If CRP/SRP (64-bit), advance EA and read low part
    IF (brief(14 downto 10)="10010" OR brief(14 downto 10)="10011") THEN  -- SRP or CRP
        set(mem_addsub) <= '1';
        ...
```

**This is CORRECT!** For memory EA mode, the code properly determines 64-bit vs 32-bit by checking the **register selector**, not bit 8.

---

## Inconsistency

The code has **TWO DIFFERENT METHODS** for determining transfer size:

| Mode | Size Determination | Correct? |
|------|-------------------|----------|
| Memory EA | Uses register selector (bits 14-10) | ✅ CORRECT |
| Dn register | Uses brief(8) as "SZ" bit | ❌ WRONG |

This inconsistency proves brief(8) is NOT a real size field - if it were, both code paths would use it!

---

## What is Bit 8 Actually Used For?

In MC68030 PMOVE, bit 8 has different meanings depending on context:

1. **PMOVEFD (Flush Disable)**: Part of the mode field (bits 9-8 = "00" identifies PMOVEFD)
2. **Memory EA addressing**: Part of the EA extension (not a size field)
3. **Dn mode**: Should be reserved/ignored (NOT a size field)

---

## Correct Implementation

The size determination should ALWAYS be based on the P-register selector:

```vhdl
-- CORRECT: Determine transfer size from P-register selector
signal is_64bit_register : std_logic;

is_64bit_register <= '1' when (brief(14 downto 10) = "10010" OR  -- SRP
                               brief(14 downto 10) = "10011")     -- CRP
                     else '0';

-- Then use is_64bit_register for BOTH Dn and memory EA modes:
IF is_64bit_register = '1' THEN
    -- 64-bit transfer (CRP/SRP only)
    next_micro_state <= pmmu_dn_high;  -- For Dn mode
ELSE
    -- 32-bit transfer (TC, TT0, TT1, MMUSR)
    next_micro_state <= idle;
END IF;
```

---

## Impact Assessment

### Current Behavior (BUGGY)

1. **Line 4516 illegal check**: May incorrectly trap legal PMOVE instructions if bit 8 is '1'
2. **Line 4542 Dn mode**:
   - `PMOVE TC,D0` with bit8=1 → incorrectly reads D1 as well
   - `PMOVE CRP,D0` with bit8=0 → incorrectly reads only D0 (misses D1!)

### Correct Behavior

- Ignore bit 8 entirely for size determination
- Use register selector bits 14-10 to determine size
- CRP/SRP always do 64-bit transfer (HIGH then LOW)
- TC/TT0/TT1/MMUSR always do 32-bit transfer

---

## Test Case to Expose Bug

```assembly
; Test 1: PMOVE TC,D0 where extension word has bit 8 set
; Extension word: 0x2100 (bits: 0010 0001 0000 0000)
; Bits 14-10 = 10000 (TC register)
; Bit 9 = 1 (read from MMU to Dn)
; Bit 8 = 0
; This should do 32-bit transfer to D0 only

; Test 2: What if bit 8 were 1?
; Extension word: 0x2180 (bits: 0010 0001 1000 0000)
; Buggy code would try to read D1 as well (WRONG!)
; Correct code would ignore bit 8 and still read only D0

; Test 3: PMOVE CRP,D0
; Extension word: 0x4D00 (bits: 0100 1101 0000 0000)
; Bits 14-10 = 10011 (CRP register)
; Bit 9 = 1 (read from MMU)
; Bit 8 = 0
; Buggy code would read only D0 (WRONG! CRP is 64-bit!)
; Correct code would read D0 then D1 regardless of bit 8
```

---

## Required Fixes

### Fix 1: Remove Illegal Instruction Check (Lines 4515-4520)

**DELETE** this entire check:
```vhdl
ELSIF brief(8) = '1' AND NOT (brief(14 downto 10) = "10010" OR brief(14 downto 10) = "10011") THEN
    -- Illegal: .D (doubleword) on TC/TT0/TT1/MMUSR
    trap_illegal <= '1';
    trapmake <= '1';
```

This check is based on a false premise (that bit 8 is a size selector). Delete it entirely.

### Fix 2: Use Register Selector for Dn Mode (Lines 4539-4551)

**BEFORE (BUGGY)**:
```vhdl
IF brief(8) = '1' THEN
    next_micro_state <= pmmu_dn_high;
ELSE
    next_micro_state <= idle;
END IF;
```

**AFTER (FIXED)**:
```vhdl
-- Determine transfer size from P-register selector, NOT from brief(8)
IF (brief(14 downto 10) = "10010" OR brief(14 downto 10) = "10011") THEN
    -- 64-bit transfer for CRP/SRP (register selector determines size)
    next_micro_state <= pmmu_dn_high;
ELSE
    -- 32-bit transfer for TC/TT0/TT1/MMUSR
    next_micro_state <= idle;
END IF;
```

### Fix 3: Update Comments

Remove all references to "SZ bit", ".D", ".L" size specifiers, and "brief(8) as size selector".

---

## References

- **MC68030 User's Manual**, Section 9.8: PMOVE instruction format
- **M68000 Family Programmer's Reference Manual**, PMOVE instruction description

The MC68030 specification explicitly shows PMOVE extension word format with NO size field. The register size is always implicit.

---

## Conclusion

The code incorrectly invents an "SZ" size field at bit 8 of the PMOVE extension word. This field **does not exist in MC68030**. The register transfer size is **always implicit** based on which P-register is accessed:

- CRP, SRP: Always 64-bit
- TC, TT0, TT1, MMUSR: Always 32-bit

**Priority**: CRITICAL - Fix immediately
**Risk**: HIGH - Incorrect instruction decoding, potential data corruption
