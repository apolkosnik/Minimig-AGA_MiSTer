# BUG #15: preSVmode Not Synchronized on SR Restore (RTE/MOVE to SR)

## Discovery Date: 2025-10-13 16:05
## Reported By: ChatGPT Analysis

## Severity: CRITICAL - MMU Privilege Checking Broken

This bug causes user-mode tasks to execute their first instruction with stale supervisor privileges, allowing PMMU instructions to execute without privilege violation.

## Problem

When the Status Register (SR) is restored via:
1. **RTE** (Return from Exception) - `exec(directSR)='1'`
2. **MOVE to SR** - `exec(to_SR)='1'`

The `preSVmode` signal is **NOT updated** to match the new SR(5) bit (supervisor flag).

## Location

**File**: `rtl/tg68k/TG68KdotC_Kernel.vhd`

**Lines 1678-1689**:
```vhdl
IF exec(directSR)='1' OR set_stop='1' THEN
    FlagsSR <= data_read(15 downto 8);
END IF;
IF interrupt='1' AND trap_interrupt='1' THEN
    FlagsSR(2 downto 0) <=rIPL_nr;
END IF;
IF exec(to_SR)='1' THEN
    FlagsSR(7 downto 0) <= SRin;  --SR
    fc_internal(2) <= SRin(5);
ELSIF exec(update_FC)='1' THEN
    fc_internal(2) <= FlagsSR(5);
END IF;
```

**Problem**: `preSVmode` is never updated when SR is loaded!

## Impact

### Privilege Violation Window

1. Task executes in supervisor mode
2. Exception occurs, saves SR with S=1
3. Exception handler changes to user mode (S=0)
4. RTE restores SR with S=0
5. **BUG**: `preSVmode` still = '1' (stale supervisor state)
6. First instruction after RTE: `SVmode` set from old `preSVmode` = '1'
7. **Result**: First instruction executes with supervisor privilege!
8. PMMU instructions don't trap, user code can execute privileged operations

### GetMMUType() Failure

AmigaOS `GetMMUType()` detection:
```c
// Detect MMU by trying to read TC register
int GetMMUType() {
    int d0 = -1;
    asm("PMOVE TC,d0");  // Should trap in user mode
    return d0;           // Returns -1 if MMU absent
}
```

**With Bug**:
- PMOVE executes without trap (stale supervisor privilege)
- Reads TC successfully
- Returns -1 anyway (not updated)
- **OS concludes**: No MMU present!

## Root Cause Analysis

Looking at lines 1667-1671, `preSVmode` is only updated when `set(changeMode)='1'`:
```vhdl
IF set(changeMode)='1' THEN
    preSVmode <= NOT preSVmode;
    FlagsSR(5) <= NOT preSVmode;
    fc_internal(2) <= NOT preSVmode;
END IF;
```

But when SR is loaded directly (RTE/MOVE to SR), `set(changeMode)` is **NOT set**, so `preSVmode` remains stale.

## The Fix Required

When SR is loaded, `preSVmode` must be synchronized with SR(5):

### Fix Location: Lines 1678-1689

**BEFORE (BROKEN)**:
```vhdl
IF exec(directSR)='1' OR set_stop='1' THEN
    FlagsSR <= data_read(15 downto 8);
END IF;
IF interrupt='1' AND trap_interrupt='1' THEN
    FlagsSR(2 downto 0) <=rIPL_nr;
END IF;
IF exec(to_SR)='1' THEN
    FlagsSR(7 downto 0) <= SRin;  --SR
    fc_internal(2) <= SRin(5);
ELSIF exec(update_FC)='1' THEN
    fc_internal(2) <= FlagsSR(5);
END IF;
```

**AFTER (FIXED)**:
```vhdl
IF exec(directSR)='1' OR set_stop='1' THEN
    FlagsSR <= data_read(15 downto 8);
    preSVmode <= data_read(13);  -- ✅ Sync preSVmode with SR(5)
END IF;
IF interrupt='1' AND trap_interrupt='1' THEN
    FlagsSR(2 downto 0) <=rIPL_nr;
END IF;
IF exec(to_SR)='1' THEN
    FlagsSR(7 downto 0) <= SRin;  --SR
    fc_internal(2) <= SRin(5);
    preSVmode <= SRin(5);  -- ✅ Sync preSVmode with SR(5)
ELSIF exec(update_FC)='1' THEN
    fc_internal(2) <= FlagsSR(5);
END IF;
```

## Test Case

### Before Fix - Privilege Violation Window

```assembly
    ; Running in supervisor mode
    MOVE.L  #TestHandler,$80    ; Install trap handler

    ; Switch to user mode
    ANDI.W  #$DFFF,SR          ; Clear S bit

    ; Generate exception (returns to supervisor)
    TRAP    #0

TestHandler:
    ; Exception handler (supervisor mode)
    ; Change return SR to user mode
    ANDI.W  #$DFFF,(SP)        ; Clear S bit in saved SR
    RTE                         ; Return to user mode

    ; ❌ BUG: Next instruction executes with stale supervisor privilege!
    PMOVE   TC,D0               ; Should TRAP but doesn't!
    ; D0 contains TC value (privilege violation missed)
```

### After Fix - Correct Behavior

```assembly
    ; Same setup...
    RTE                         ; Return to user mode

    ; ✅ FIXED: preSVmode synchronized with SR(5)
    PMOVE   TC,D0               ; ✅ CORRECTLY TRAPS (privilege violation)
    ; Exception handler invoked
```

## Related Code

### SVmode Update Logic (Lines 1655-1661)
```vhdl
IF setopcode='1' THEN
    make_trace <= FlagsSR(7);
    IF set(changeMode)='1' THEN
        SVmode <= NOT SVmode;
    ELSE
        SVmode <= preSVmode;  -- ❌ Uses stale preSVmode after SR restore!
    END IF;
END IF;
```

This is where the stale `preSVmode` causes the first instruction to run with wrong privilege.

## Test Strategy

1. Write supervisor mode code that:
   - Generates exception
   - Exception handler changes return SR to user mode
   - Returns via RTE
   - Attempts PMOVE instruction

2. **Expected (with fix)**: PMOVE traps with privilege violation
3. **Broken (without fix)**: PMOVE executes successfully

## AmigaOS Compatibility

This fix is **CRITICAL** for AmigaOS 3.x:
- GetMMUType() detection will work correctly
- User-mode programs cannot bypass MMU protection
- Proper privilege separation enforced

## Files to Modify

1. `rtl/tg68k/TG68KdotC_Kernel.vhd` - Lines 1678-1689 (add preSVmode updates)

## Testing Required

1. ✅ Compile test
2. ✅ Privilege violation test (PMOVE in user mode should trap)
3. ✅ RTE privilege transition test
4. ✅ MOVE to SR privilege transition test
5. ✅ GetMMUType() detection (should return 68030, not -1)

## Priority

**CRITICAL** - This completely breaks MMU privilege checking and OS-level MMU detection.

## Status

- **Identified**: 2025-10-13 16:05
- **Fix Prepared**: Pending implementation
- **Testing**: Pending
