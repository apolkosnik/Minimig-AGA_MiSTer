# BUG #13: CRP/SRP HIGH Word Mask Incorrectly Clears Bit 31 (L/U Flag)

## Discovery Date: 2025-10-13 13:40

## Severity: HIGH

Bit 31 (Lower/Upper limit mode flag) of CRP/SRP HIGH word is being masked to 0, preventing proper limit checking configuration.

## Location

**File**: `rtl/tg68k/TG68K_PMMU_030.vhd`

**Line 90**:
```vhdl
constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := "01111111111111110000000000000001"; -- 0x7FFF0001
--                                                         ^
--                                                         Bit 31 is '0' - WRONG!
```

**Usage sites**:
- Line 777: `CRP_H <= (reg_wdat and CRP_HIGH_MASK);`
- Line 792: `SRP_H <= (reg_wdat and CRP_HIGH_MASK);`

## Problem

The mask constant has bit 31 set to '0', which causes the L/U flag to always be cleared during CRP/SRP HIGH word writes.

### MC68030 CRP/SRP HIGH Word Format (bits 63-32)

Per MC68030 User's Manual section 9.3.1:

```
Bit 63 (31 in HIGH word): L/U - Lower or Upper limit mode
Bits 62-48 (30-16):       LIMIT - Table index limit value
Bits 47-33 (15-1):        Reserved (should be forced to 0)
Bit 32 (0):               DT - Descriptor Type
```

**Required mask**: Preserve bits 31,30-16,0 = `0xFFFF0001`

**Current mask**: Preserves bits 30-16,0 only = `0x7FFF0001`

## Impact

1. **L/U flag always reads as 0**: Software cannot configure upper limit mode
2. **Limit checking broken**: Lower limit mode (L/U=0) always used, regardless of software configuration
3. **MC68030 incompatibility**: Software expecting upper limit checking will fail
4. **AmigaOS 3.x impact**: May affect MMU table setup if OS uses upper limit mode

## Test Evidence

From `tb_pmmu_reg_rw_lockup.vhd` test results:

```
** Note:   Writing CRP_H = 0xABCD0002
** Note:   Read CRP_H value: 0x2BCD0000
** Error:   FAIL: CRP_H mismatch, expected 0xABCDxxxx, got 0x2BCD0000
```

Analysis:
- Written:  `0xABCD0002` = `1010 1011 1100 1101 0000 0000 0000 0010`
- Read:     `0x2BCD0000` = `0010 1011 1100 1101 0000 0000 0000 0000`
- Bit 31:   `1` → `0` (LOST!)
- Bits 3-0: `0010` → `0000` (correctly masked as reserved)

## Fix

### Change Required

**Line 90**:
```vhdl
-- OLD (WRONG):
constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := "01111111111111110000000000000001"; -- 0x7FFF0001

-- NEW (CORRECT):
constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := "11111111111111110000000000000001"; -- 0xFFFF0001
--                                                         ^
--                                                         Bit 31 now '1' - preserves L/U flag
```

### Verification After Fix

Expected test result after fix:
```
Write CRP_H: 0xABCD0002
Read CRP_H:  0xABCD0000  (bit 1 cleared as reserved, bit 31 preserved)
```

## Related Bugs

This bug is similar to:
- **BUG #5**: CRP/SRP format was backwards (FIXED)
- **BUG #2**: Root pointer limit checking was broken (FIXED)

This is likely a remnant from the initial CRP/SRP format confusion.

## Testing Required After Fix

1. Run `tb_pmmu_reg_rw_lockup.vhd` - should show CRP_H preserves bit 31
2. Test limit checking with L/U=0 (lower limit mode)
3. Test limit checking with L/U=1 (upper limit mode)
4. Verify no side effects on other CRP/SRP operations

## Documentation References

- **MC68030 User's Manual**: Section 9.3.1 "Root Pointer Descriptors"
- **Previous fix**: `CRP_SRP_FORMAT_FIX.md`

## Build Status

- **Not yet fixed**: Awaiting confirmation to proceed
- **Compilation**: Should compile cleanly (single constant change)
- **Estimated fix time**: < 1 minute

## Related Files

- `rtl/tg68k/TG68K_PMMU_030.vhd` - Line 90 (constant definition)
- `rtl/tg68k/TG68K_PMMU_030.vhd` - Lines 777, 792 (usage sites)
- `tests/tg68k_030/tb_pmmu_reg_rw_lockup.vhd` - Test that discovered bug
- `LOCKUP_DIAGNOSTIC_RESULTS.md` - Diagnostic session results

## Recommendation

**PRIORITY**: Fix this bug immediately after resolving the user-reported lockup issue. This is a data integrity bug that affects MMU functionality but does not cause the lockup.
