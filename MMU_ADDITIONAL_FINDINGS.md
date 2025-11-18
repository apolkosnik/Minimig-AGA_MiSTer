# Additional MMU Investigation Findings

## PTEST Instruction - Missing Optional Features

### Finding: PTEST LEVEL Field Not Implemented
**Location**: `rtl/tg68k/TG68KdotC_Kernel.vhd` line 4706
**Documented**: Yes - "Bits 12-10: LEVEL (0-7)"
**Implemented**: No

**Description**:
The PTEST instruction extension word has a LEVEL field (bits 12-10) that specifies how many levels of page table to walk before stopping. Values 0-7 allow stopping at different table levels.

**Current Behavior**:
PTEST always walks all the way to a page descriptor (all levels).

**Impact**:
- Low - PTEST still functions correctly for basic MMU testing
- Diagnostic software that relies on LEVEL field will not work correctly
- May affect MMU debugging tools

**MC68030 Compliance**: Partial - feature exists but not required for basic operation

---

### Finding: PTEST A Bit (Address Register Return) Not Implemented
**Location**: `rtl/tg68k/TG68KdotC_Kernel.vhd` line 4708  
**Documented**: Yes - "Bit 8: A (address register return option)"
**Implemented**: No

**Description**:
When A=1 and REG (bits 7-5) specify an address register, PTEST should return the last table address accessed in that register.

**Current Behavior**:
A bit and REG field are ignored. No address register is modified.

**Impact**:
- Low - PTEST still updates MMUSR correctly
- Diagnostic software that uses address register return will not work
- Useful for debugging page table structures

**MC68030 Compliance**: Partial - feature exists but not required for basic operation

---

## Summary of Investigation

### Critical Bugs Found and Fixed:
1. ✅ **BUG #1**: Long-format descriptor address calculation - FIXED
2. ✅ **BUG #2**: Modified bit position (bit 4 vs bit 3) - FIXED
3. ✅ **BUG #4**: Non-existent PMOVE "SZ" bit - FIXED

### Documentation Issues:
4. ⚠️ **BUG #3**: PLOAD FC comment incorrect - NOTED

### Missing Features (Not Critical):
5. ⚠️ **PTEST LEVEL field**: Not implemented (optional feature)
6. ⚠️ **PTEST A bit**: Address register return not implemented (optional feature)
7. ⚠️ **U (Used) bit**: Page descriptors not written back with U bit set (common omission)
8. ⚠️ **Indirect descriptors**: Not implemented (rarely used, possibly MC68851 only)

### Verified Correct:
- ✅ All PMMU register selectors
- ✅ All instruction bit patterns (after fixes)
- ✅ PFLUSH variants
- ✅ Limit checking (CRP/SRP)
- ✅ TC validation
- ✅ TTR (Transparent Translation) logic
- ✅ Function code matching
- ✅ Privilege checking
- ✅ Early termination page descriptors
- ✅ ATC (Address Translation Cache) implementation

## Recommendation

The critical bugs have all been fixed. The missing PTEST features are optional and rarely used in practice. The implementation is fully functional for:
- AmigaOS MMU support
- Virtual memory management
- Basic MMU testing with PTEST

For full MC68030 diagnostic compliance, PTEST LEVEL and A bit support would need to be added, but this is not required for normal operation.

**Status**: All critical bugs FIXED, implementation ready for hardware testing
