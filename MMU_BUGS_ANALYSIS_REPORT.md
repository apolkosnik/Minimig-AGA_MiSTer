# MC68030 MMU Implementation - Bug Analysis Report

**Date**: 2025-11-18
**Branch**: 030_mmu
**Analyzer**: Claude Code

## Executive Summary

Comprehensive analysis of the MC68030 PMMU implementation in the TG68K core has revealed **2 CRITICAL BUGS** that affect long-format descriptor handling and page attribute extraction. These bugs would cause MMU failures when using 64-bit descriptors and incorrect Modified bit reporting to the OS.

---

## Critical Bugs Found

### 🔴 CRITICAL BUG #1: Long-Format Descriptor LOW Word Address Calculation Error

**Severity**: CRITICAL
**Impact**: Complete MMU failure for long-format (64-bit) descriptors
**File**: `rtl/tg68k/TG68K_PMMU_030.vhd`
**Lines**: 1836, 1935, 2041, 2131

#### Problem Description

The page table walker uses a local variable `desc_addr` to calculate descriptor addresses. In VHDL, process variables **do not persist across clock cycles**. The code calculates `desc_addr` in states W_ROOT, W_PTR1, W_PTR2, and W_PTR3, then attempts to use it in the corresponding *_LOW states (W_ROOT_LOW, W_PTR1_LOW, etc.) to read the LOW word at `desc_addr + 4`.

However, since `desc_addr` is a variable declared in the process (line 1615), it does NOT persist when the FSM transitions to the *_LOW state in the next clock cycle. This causes the LOW word to be read from an **undefined/uninitialized address**, leading to incorrect descriptor processing.

#### Affected Code

**Variable Declaration** (line 1615):
```vhdl
variable desc_addr : std_logic_vector(31 downto 0);
```

**Example - W_ROOT state** (lines 1754-1755, 1769):
```vhdl
when W_ROOT =>
  desc_addr := walk_addr(31 downto 4) & "0000";
  desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
  ...
  if mem_req = '0' then
    mem_req <= '1';
    mem_addr <= desc_addr;  -- Signal mem_addr gets the address
```

**Example - W_ROOT_LOW state** (lines 1836-1837):
```vhdl
when W_ROOT_LOW =>
  if mem_req = '0' then
    mem_req <= '1';
    mem_addr <= std_logic_vector(unsigned(desc_addr) + 4);  -- ❌ BUG: desc_addr is uninitialized!
    report "W_ROOT_LOW: Reading LOW word at addr=0x" & slv_to_hstring(std_logic_vector(unsigned(desc_addr) + 4)) severity note;
```

**All Affected Locations**:
- Line 1836: `W_ROOT_LOW` - reads LOW word of root descriptor
- Line 1935: `W_PTR1_LOW` - reads LOW word of level 1 descriptor
- Line 2041: `W_PTR2_LOW` - reads LOW word of level 2 descriptor
- Line 2131: `W_PTR3_LOW` - reads LOW word of level 3 descriptor

#### Root Cause Analysis

1. **W_ROOT state (clock cycle N)**:
   - Variable `desc_addr` is calculated
   - Signal `mem_addr` is assigned `desc_addr` value
   - FSM transitions to `W_ROOT_LOW`

2. **W_ROOT_LOW state (clock cycle N+1)**:
   - Process executes from beginning
   - Variable `desc_addr` is re-declared (uninitialized)
   - Code tries to use `desc_addr + 4` ❌ **UNDEFINED VALUE**
   - Signal `mem_addr` still contains the descriptor address from previous cycle ✓

#### Proposed Fix

Replace `desc_addr + 4` with `mem_addr + 4` in all *_LOW states, since `mem_addr` is a **signal** that persists across clock cycles.

**W_ROOT_LOW** (line 1836):
```vhdl
-- BEFORE (BUGGY):
mem_addr <= std_logic_vector(unsigned(desc_addr) + 4);

-- AFTER (FIXED):
mem_addr <= std_logic_vector(unsigned(mem_addr) + 4);
```

Apply the same fix to:
- **W_PTR1_LOW** (line 1935)
- **W_PTR2_LOW** (line 2041)
- **W_PTR3_LOW** (line 2131)

#### Verification Test Case

```vhdl
-- Test long-format descriptors (DT=11)
-- Configure CRP with long-format root pointer
-- Create page tables with 64-bit descriptors
-- Attempt address translation
-- Expected: Should read LOW word from correct address (base+4)
-- Actual (with bug): Reads from undefined address, causes MMU fault
```

---

### 🔴 CRITICAL BUG #2: Page Descriptor Modified Bit Read from Wrong Position

**Severity**: CRITICAL
**Impact**: Incorrect Modified bit in MMUSR, wrong cache/TLB behavior
**File**: `rtl/tg68k/TG68K_PMMU_030.vhd`
**Line**: 2229

#### Problem Description

According to MC68030 specification, page descriptor attribute bits are:
- **Bit 6**: CI (Cache Inhibit) / U0
- **Bit 5**: G (Global)
- **Bit 4**: U (Used/Accessed/Referenced)
- **Bit 3**: M (Modified/Dirty)
- **Bit 2**: WP (Write Protected)

The code incorrectly reads **bit 4** (Used bit) and treats it as the **Modified** bit, when it should read **bit 3**.

#### Affected Code

**W_PAGE state** (lines 2227-2230):
```vhdl
-- Extract attributes - bit positions are same in both formats
walk_attr(3) <= NOT get_supervisor_bit(walk_desc_high, walk_desc_is_long); -- User accessible ✓
walk_attr(2) <= walk_desc_high(6); -- Cache inhibit (CI) ✓ CORRECT
walk_attr(1) <= walk_desc_high(4); -- Modified (M)     ❌ WRONG! Reading U (Used) bit
walk_attr(0) <= walk_desc_high(2); -- Write protect (WP) ✓ CORRECT
```

#### MC68030 Page Descriptor Format

**Short Format (DT=01)**:
```
Bits 31-8:  Page Frame Address
Bit 7:      U1 (User-defined attribute 1)
Bit 6:      U0/CI (Cache Inhibit)         ← Code reads this correctly
Bit 5:      G (Global)
Bit 4:      U (Used/Accessed)             ← Code INCORRECTLY reads as Modified!
Bit 3:      M (Modified/Dirty)            ← Code should read THIS as Modified!
Bit 2:      WP (Write Protected)          ← Code reads this correctly
Bits 1-0:   DT (Descriptor Type) = 01
```

**Long Format HIGH Word (DT=11)** - Same bit positions:
```
Bits 31-9:  Reserved
Bit 8:      S (Supervisor)
Bit 7:      U1
Bit 6:      U0/CI                         ← Code reads this correctly
Bit 5:      G
Bit 4:      U (Used)                      ← Code INCORRECTLY reads as Modified!
Bit 3:      M (Modified)                  ← Code should read THIS as Modified!
Bit 2:      WP                            ← Code reads this correctly
Bits 1-0:   DT = 11
```

#### Impact Analysis

1. **MMUSR Register**: Modified bit reported incorrectly to software
   - PTEST instruction will report wrong M bit
   - Operating system page fault handlers receive incorrect information

2. **Cache Behavior**: Modified bit used for writeback decisions
   - May cause data loss if pages marked dirty when they're not
   - May cause unnecessary writebacks

3. **Page Table Updates**: Modified bit should trigger descriptor updates
   - Incorrect tracking of which pages have been modified

#### Proposed Fix

Change line 2229 to read bit 3 instead of bit 4:

```vhdl
-- BEFORE (BUGGY):
walk_attr(1) <= walk_desc_high(4); -- Modified (M)

-- AFTER (FIXED):
walk_attr(1) <= walk_desc_high(3); -- Modified (M) - correct bit position per MC68030 spec
```

#### Additional Note

The code does not extract or track the **U (Used/Accessed)** bit at bit 4. According to MC68030 specification, this bit should be set by the MMU when a page is accessed. This is not strictly a bug (some MMU implementations don't track the U bit), but it's a deviation from full MC68030 compliance.

For full compliance, consider:
```vhdl
walk_attr(3) <= NOT get_supervisor_bit(walk_desc_high, walk_desc_is_long); -- User accessible
walk_attr(2) <= walk_desc_high(6); -- Cache inhibit (CI)
walk_attr(1) <= walk_desc_high(4); -- Used (U) - tracked but may not be writable
walk_attr(0) <= walk_desc_high(3); -- Modified (M) - correct position
-- OR use a separate signal for WP since it's checked separately
```

#### Verification Test Case

```vhdl
-- Create page descriptor with M=1, U=0 at bits 3:4
-- Descriptor = 0xXXXXXX08 (bit 3 set, bit 4 clear)
-- Execute PTEST to trigger translation
-- Check MMUSR bit 9 (Modified bit)
-- Expected: MMUSR(9) = '1' (Modified bit set)
-- Actual (with bug): MMUSR(9) = '0' (reads U bit instead)
```

---

## Previously Fixed Bugs (Already in Code)

The following bugs have been identified and fixed in previous sessions:

1. **BUG #12**: Register write priority - `elsif` blocking MMUSR updates
2. **BUG #13**: CRP/SRP HIGH mask clearing bit 31 (L/U flag)
3. **BUG #14**: PMOVE 32-bit register missing completion state (lockup)
4. **BUG #15**: preSVmode not synchronized on SR restore (privilege violation)
5. **BUG #16**: Edge detection for PMOVE register access (multi-cycle writes)
6. **BUG #17**: PTEST/PLOAD R/W from brief(9) interpretation
7. **BUG #48**: TC validation before write to prevent lockup

---

## Recommendations

### Immediate Action Required

1. **Fix BUG #1**: Replace `desc_addr` with `mem_addr` in all *_LOW states
   - This is critical for long-format descriptor support
   - Without this fix, any use of 64-bit descriptors will fail

2. **Fix BUG #2**: Change bit position from 4 to 3 for Modified bit extraction
   - Critical for correct MMUSR reporting
   - Impacts OS page fault handling and cache coherency

### Testing Strategy

1. **Long Format Descriptor Test**:
   - Create test with CRP/SRP containing long-format root pointers (DT=11)
   - Configure page tables with 64-bit table and page descriptors
   - Verify descriptor addresses are read correctly (base, base+4)
   - Check physical address translation is correct

2. **Modified Bit Test**:
   - Create page descriptor with M=1, U=0
   - Execute PTEST instruction
   - Verify MMUSR reports M bit correctly
   - Test write access triggers M bit setting

3. **Regression Testing**:
   - Re-run all existing test suites
   - Verify no new failures introduced by fixes

### Hardware Testing

After fixes are applied:
1. Test with AmigaOS 3.x which may use long-format descriptors
2. Verify PTEST instruction in supervisor mode
3. Test page fault handling with correct Modified bit

---

## Files Requiring Modification

1. **rtl/tg68k/TG68K_PMMU_030.vhd**:
   - Line 1836: W_ROOT_LOW descriptor address calculation
   - Line 1935: W_PTR1_LOW descriptor address calculation
   - Line 2041: W_PTR2_LOW descriptor address calculation
   - Line 2131: W_PTR3_LOW descriptor address calculation
   - Line 2229: Modified bit extraction from descriptor

---

## References

- MC68030 User's Manual (Motorola/NXP)
- Section 9: Memory Management Unit
- Section 9.2.7: MMUSR Register Format
- Section 9.3: Descriptor Formats (Table and Page)

---

## Conclusion

Both bugs are critical and must be fixed before the MMU implementation can be considered complete and MC68030-compliant:

- **BUG #1** prevents long-format descriptors from working at all
- **BUG #2** causes incorrect Modified bit reporting throughout the system

The fixes are straightforward but essential for correct MMU operation.

**Status**: BUGS IDENTIFIED - FIXES REQUIRED
**Priority**: CRITICAL
**Risk**: HIGH - System instability with long descriptors, incorrect page tracking
