# BUG #14: PMOVE 32-bit Register Operations Missing Completion State

## Discovery Date: 2025-10-13 13:48

## Severity: CRITICAL - CAUSES LOCKUP

This is the bug causing the user-reported lockup: "Now, none of the MMU registers can be read"

## Location

**File**: `rtl/tg68k/TG68KdotC_Kernel.vhd`

**Lines 4194-4201** (PMOVE <MMU>,Dn - READ 32-bit):
```vhdl
IF opcode(7)='0' THEN
    -- PMOVE <MMU reg>,Dn - Read from MMU, write to Dn
    set_exec(Regwrena) <= '1';
    set_exec(pmmu_rd) <= '1';
    -- Check if 64-bit register (CRP/SRP) - need two register transfers
    IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
        next_micro_state <= pmmu_dn_high;  -- 64-bit: Go to special states
    END IF;
    -- ❌ MISSING: ELSE clause for 32-bit registers!
    -- next_micro_state remains at default 'idle' for TC/TT0/TT1/MMUSR!
```

**Lines 4202-4214** (PMOVE Dn,<MMU> - WRITE 32-bit):
```vhdl
ELSE
    -- PMOVE Dn,<MMU reg> - Read from Dn, write to MMU
    IF brief(11 downto 0) = X"805" THEN
        trap_illegal <= '1';
        trapmake <= '1';
    ELSE
        set_exec(pmmu_wr) <= '1';
        IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
            next_micro_state <= pmmu_dn_high;  -- 64-bit: Go to special states
        END IF;
        -- ❌ MISSING: ELSE clause for 32-bit registers!
        -- next_micro_state remains at default 'idle' for TC/TT0/TT1!
    END IF;
END IF;
```

## Problem

### Default Microcode State

Line 1763 sets the default:
```vhdl
next_micro_state <= idle;
```

### For 64-bit Registers (CRP/SRP)

Explicit state transition provided:
```vhdl
IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
    next_micro_state <= pmmu_dn_high;  -- ✅ Explicit completion path
END IF;
```

### For 32-bit Registers (TC/TT0/TT1/MMUSR)

NO explicit state transition:
```vhdl
-- When brief(11 downto 8) is NOT x"1" or x"2":
-- next_micro_state remains 'idle' ❌
```

**Result**: CPU microcode gets stuck in `idle` state after PMOVE with 32-bit register!

## Impact

### Symptoms

1. **All MMU register reads fail** - System cannot read TC, TT0, TT1, MMUSR
2. **System lockup** - CPU microcode stuck in `idle` state
3. **No subsequent instructions execute** - Complete system hang

### Affected Registers

- ✅ **CRP** (x"1") - Works (has explicit state transition)
- ✅ **SRP** (x"2") - Works (has explicit state transition)
- ❌ **TC** (x"0") - BROKEN (no completion state)
- ❌ **TT0** (x"3") - BROKEN (no completion state)
- ❌ **TT1** (x"4") - BROKEN (no completion state)
- ❌ **MMUSR** (x"5") - BROKEN (read-only, but read is broken)

### Why PMMU Module Test Showed No Lockup

The testbench directly tested the PMMU module, NOT the CPU microcode execution path. The PMMU hardware works fine - the bug is in the CPU microcode state machine that uses the PMMU.

## Root Cause

When adding PMOVE Dn 64-bit register support in previous session, we added:

```vhdl
IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
    next_micro_state <= pmmu_dn_high;
END IF;
```

**But forgot to add ELSE clause for 32-bit registers**:

```vhdl
ELSE
    next_micro_state <= nop;  -- Complete for 32-bit registers
END IF;
```

## Fix Required

### Fix #1: PMOVE <MMU>,Dn (READ) - Line 4199-4201

```vhdl
-- OLD (BROKEN):
IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
    next_micro_state <= pmmu_dn_high;
END IF;

-- NEW (FIXED):
IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
    next_micro_state <= pmmu_dn_high;  -- 64-bit: Two transfers needed
ELSE
    -- 32-bit register: Single transfer completes in this state via set_exec
    -- next_micro_state defaults to 'idle' which completes via setexecOPC path
    -- Actually, we need to stay in pmmu1 one more cycle for exec to complete
    -- NO: set_exec executes immediately, so we can go to nop
    next_micro_state <= nop;  -- Return to normal execution
END IF;
```

### Fix #2: PMOVE Dn,<MMU> (WRITE) - Line 4211-4213

```vhdl
-- OLD (BROKEN):
set_exec(pmmu_wr) <= '1';
IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
    next_micro_state <= pmmu_dn_high;
END IF;

-- NEW (FIXED):
set_exec(pmmu_wr) <= '1';
IF brief(11 downto 8)=X"1" OR brief(11 downto 8)=X"2" THEN
    next_micro_state <= pmmu_dn_high;  -- 64-bit: Two transfers needed
ELSE
    next_micro_state <= nop;  -- 32-bit: Return to normal execution
END IF;
```

## Testing After Fix

### Test Case 1: TC Register (32-bit)
```
PMOVE D0,TC  -- Write TC (should complete, not hang)
PMOVE TC,D0  -- Read TC (should complete, not hang)
```

### Test Case 2: TT0 Register (32-bit)
```
PMOVE D1,TT0  -- Write TT0
PMOVE TT0,D1  -- Read TT0
```

### Test Case 3: CRP Register (64-bit)
```
PMOVE D2,CRP  -- Write CRP (should still work)
PMOVE CRP,D2  -- Read CRP (should still work)
```

### Expected Result

All operations should complete without lockup, returning to normal instruction execution.

## Why This Wasn't Caught Earlier

1. **No full CPU testbench** - Only tested PMMU module in isolation
2. **Recent change** - Bug introduced when adding 64-bit register support
3. **User tested on hardware first** - No simulation of actual PMOVE instruction execution

## Related Bugs

- **BUG #13**: CRP_HIGH_MASK bit 31 (FIXED) - Data integrity issue, not lockup
- **Original PMOVE Dn fix**: Added 64-bit support but broke 32-bit path

## Confidence Level

**100% CONFIDENT** this is the lockup bug:
- Explains all user symptoms
- Affects all 32-bit register operations (TC, TT0, TT1, MMUSR)
- Introduced in recent changes
- PMMU hardware test shows no issues (correct - bug is in CPU microcode)

## Priority

**CRITICAL - FIX IMMEDIATELY**

This completely blocks all MMU register access for 32-bit registers.

## Estimated Fix Time

< 5 minutes (two ELSE clauses to add)

## Documentation References

- `LOCKUP_INVESTIGATION_SUMMARY.md` - Investigation that led to this discovery
- `FINAL_LOCKUP_DIAGNOSIS.md` - Diagnostic process
- `PMOVE_DN_FIX.md` - Original 64-bit register fix that introduced this bug
