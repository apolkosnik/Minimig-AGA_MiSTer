# MC68030 MMU Instruction Clean Implementation Plan

## Executive Summary

The current MMU instruction implementation in the 030_mmu branch has accumulated numerous bug fixes and patches, making it difficult to maintain and understand. This document outlines a plan for a clean, well-documented reimplementation.

## Current Status (as of 2025-11-11)

### Issues with Current Implementation
1. **Code Complexity**: Over 50 documented bug fixes (BUG #6, #7, #9, #12, #13, #20, #21, #22, #30, #53, etc.)
2. **Maintainability**: Nested conditionals and special cases make logic hard to follow
3. **Documentation**: Extensive comments describing fixes rather than clean logic
4. **Status**: Latest commit message "still broken, at least partially"
5. **File Size**: TG68KdotC_Kernel.vhd is 5,249 lines with complex state machine

### What Has Been Completed

#### 1. Specification Documents Created ✅
- `docs/MMU_INSTRUCTION_SPEC.md` - Complete MC68030 instruction specifications
- `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd` - Clean replacement code sections
- `docs/MMU_CLEAN_IMPLEMENTATION_PLAN.md` - This document

#### 2. Clean Decoder Module Created ✅
- `rtl/tg68k/TG68K_MMU_Instructions.vhd` - Standalone decoder (alternative approach)

#### 3. Microstate Enumeration Updated ✅
- `rtl/tg68k/TG68K_Pack.vhd` - Added 11 new MMU-specific states:
  - `mmu_decode` - Initial MMU instruction decode
  - `mmu_pmove` - PMOVE execution
  - `mmu_pmove_dn_low_wr` - PMOVE Dn 64-bit low word write
  - `mmu_pmove_dn_low_rd` - PMOVE Dn 64-bit low word read
  - `mmu_pmove_mem_rd` - PMOVE memory read high word
  - `mmu_pmove_mem_rd_low` - PMOVE memory read low word
  - `mmu_pmove_mem_wr` - PMOVE memory write high word
  - `mmu_pmove_mem_wr_low` - PMOVE memory write low word
  - `mmu_ptest` - PTEST execution
  - `mmu_pflush` - PFLUSH execution
  - `mmu_pload` - PLOAD execution

#### 4. Feature Branch Created ✅
- Branch: `claude/fix-mmu-instructions-011CV2tkV23AnEMMHqvdxm3B`
- Based on: `030_mmu` branch

## Implementation Approach

### Option A: Incremental Replacement (Recommended)
Replace sections of the existing code one instruction at a time:

1. **Phase 1**: Replace F-line decode entry point (lines 3618-3742 in kernel)
2. **Phase 2**: Implement PMOVE states (simplest, most used)
3. **Phase 3**: Implement PTEST states
4. **Phase 4**: Implement PFLUSH states
5. **Phase 5**: Implement PLOAD states
6. **Phase 6**: Remove old pmmu1/pmmu2/etc. states
7. **Phase 7**: Test and validate

**Advantages**:
- Lower risk - one instruction at a time
- Can test incrementally
- Easier to debug
- Can keep parts of old code that work

**Disadvantages**:
- Takes longer
- May have transition period with mixed code styles

### Option B: Complete Rewrite
Replace all MMU instruction handling at once:

1. **Phase 1**: Backup current implementation
2. **Phase 2**: Remove all existing MMU code
3. **Phase 3**: Insert all clean code sections
4. **Phase 4**: Comprehensive testing

**Advantages**:
- Cleanest result
- No mixed code styles
- Fresh start

**Disadvantages**:
- Higher risk
- Harder to debug if issues arise
- More code changes at once

## Detailed Implementation Steps (Option A - Recommended)

### Step 1: Add Signal Declarations

Add to TG68KdotC_Kernel.vhd signal declaration section:

```vhdl
-- MMU instruction decode signals (clean implementation)
signal mmu_reg_sel_clean    : std_logic_vector(4 downto 0);
signal mmu_direction       : std_logic;  -- 0=to MMU, 1=from MMU
signal mmu_size_64bit      : std_logic;  -- '1' for 64-bit (CRP/SRP)
signal mmu_fc_decoded      : std_logic_vector(2 downto 0);
```

### Step 2: Replace F-Line Decode

**Location**: Lines ~3618-3742 in TG68KdotC_Kernel.vhd

**Current Code**: Starts with `WHEN "1111" =>`

**Replace With**: Code from `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd` Section 2

**Key Changes**:
- Simpler privilege check
- Direct dispatch to `mmu_decode` state
- Remove complex nested conditionals
- Clean separation of PMMU vs other F-line instructions

### Step 3: Add MMU Decode State

**Location**: After existing micro_state CASE states

**Add**: Section 3 from `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd`

**Features**:
- Clear instruction type detection
- Proper register selector validation
- Clean EA mode checking
- Direct dispatch to instruction-specific states

### Step 4: Implement PMOVE States

**Location**: After `mmu_decode` state

**Add**: Sections 4 from `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd`

**States Implemented**:
1. `mmu_pmove` - Main PMOVE logic
2. `mmu_pmove_dn_low_wr` - Write LOW word (64-bit)
3. `mmu_pmove_dn_low_rd` - Read LOW word (64-bit)
4. `mmu_pmove_mem_rd` - Read from memory HIGH word
5. `mmu_pmove_mem_rd_low` - Read from memory LOW word
6. `mmu_pmove_mem_wr` - Write to memory HIGH word
7. `mmu_pmove_mem_wr_low` - Write to memory LOW word

**Logic**:
- Direction from `brief(9)`
- Size from `brief(8)`
- Register selector from `brief(14:10)`
- Separate paths for Dn vs memory modes
- Clean handling of 32-bit vs 64-bit transfers

### Step 5: Implement PTEST State

**Add**: Section 5 from `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd`

**Features**:
- Build EA for test address
- Signal PMMU module with `pmmu_ptest_req`
- Pass FC, address, and brief word
- PMMU updates MMUSR automatically

### Step 6: Implement PFLUSH State

**Add**: Section 6 from `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd`

**Features**:
- Handle PFLUSHA/PFLUSHAN (no EA)
- Handle PFLUSH with EA
- Signal PMMU module with `pmmu_pflush_req`

### Step 7: Implement PLOAD State

**Add**: Section 7 from `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd`

**Features**:
- Build EA for address
- Signal PMMU module with `pmmu_pload_req`
- PMMU performs page table walk

### Step 8: Add FC Decode Logic

**Location**: Combinatorial section of kernel

**Add**: Section 8 from `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd`

**Purpose**: Decode function code for PTEST/PFLUSH/PLOAD

### Step 9: Remove Old Code

Once new implementation is tested and working:

1. Remove old `pmmu1` state (lines ~4461-4656)
2. Remove old `pmmu1_wait`, `pmmu2`, `pmmu3`, `pmmu4`, `pmmu5` states
3. Remove old `pmmu_dn_high`, `pmmu_dn_low` states
4. Remove old `ptest1`, `pflush1`, `pload1` states
5. Clean up unused signals
6. Remove BUG #xx comments

### Step 10: Testing

#### Unit Tests
For each instruction:
1. Test all register types
2. Test both directions (where applicable)
3. Test Dn and memory modes
4. Test 32-bit and 64-bit transfers
5. Test privilege violations
6. Test illegal EA modes

#### Integration Tests
1. Run existing test suite in `tests/tg68k_030/`
2. Test with actual AmigaOS code
3. Verify no regressions in other instructions
4. Performance testing

#### Validation Checklist
- [ ] PMOVE TC works (32-bit, Dn and memory)
- [ ] PMOVE TT0/TT1 works (32-bit, Dn and memory)
- [ ] PMOVE CRP/SRP works (64-bit, Dn and memory)
- [ ] PMOVE MMUSR works (16-bit, read-only)
- [ ] PMOVEFD works
- [ ] PTEST works (both R and W variants)
- [ ] PTEST with An return works
- [ ] PFLUSHA/PFLUSHAN works
- [ ] PFLUSH with FC/EA works
- [ ] PLOAD works (both R and W variants)
- [ ] All privilege violations detected
- [ ] All illegal EAs rejected
- [ ] No state machine lockups
- [ ] Proper cycle counts

## Code Quality Standards

### Documentation
- Every state must have a clear comment explaining its purpose
- Complex logic must have inline explanations
- No "BUG #xx FIX" comments - just write it correctly

### Readability
- Maximum nesting depth: 3 levels
- Use meaningful signal names
- Group related logic together
- Consistent indentation

### Maintainability
- One responsibility per state
- Clear state transitions
- Minimal conditional complexity
- Easy to trace execution flow

## Expected Benefits

1. **Reliability**: Clean logic without accumulated patches
2. **Maintainability**: Easy to understand and modify
3. **Performance**: Optimized state machine
4. **Documentation**: Self-documenting code structure
5. **Testing**: Easier to validate each component
6. **Future**: Foundation for additional 68030 features

## Files Modified

1. `rtl/tg68k/TG68K_Pack.vhd` - Microstate enumeration
2. `rtl/tg68k/TG68KdotC_Kernel.vhd` - Main implementation (pending)
3. `rtl/tg68k/TG68K_PMMU_030.vhd` - No changes needed (interface compatible)

## Files Created

1. `docs/MMU_INSTRUCTION_SPEC.md` - Specification
2. `docs/MMU_INSTRUCTION_CLEAN_IMPL.vhd` - Clean code sections
3. `docs/MMU_CLEAN_IMPLEMENTATION_PLAN.md` - This document
4. `rtl/tg68k/TG68K_MMU_Instructions.vhd` - Optional standalone decoder

## Timeline Estimate

### Minimal Implementation (Option A, Incremental)
- Step 1-2 (Setup): 1 hour
- Step 3-4 (PMOVE): 2-3 hours
- Step 5-7 (PTEST/PFLUSH/PLOAD): 2 hours
- Step 8-9 (Cleanup): 1 hour
- Step 10 (Testing): 3-4 hours
- **Total**: 9-11 hours

### Complete Rewrite (Option B)
- Planning and backup: 1 hour
- Implementation: 6-8 hours
- Testing and debugging: 4-6 hours
- **Total**: 11-15 hours

## Risk Mitigation

1. **Keep backup**: Maintain 030_mmu branch as-is
2. **Incremental testing**: Test each phase before proceeding
3. **Version control**: Commit after each successful phase
4. **Rollback plan**: Can revert to previous commit if needed
5. **Documentation**: Keep detailed notes of changes

## Success Criteria

1. ✅ All MMU instructions decode correctly
2. ✅ All legal EA modes work
3. ✅ All illegal conditions generate proper exceptions
4. ✅ No state machine lockups or hangs
5. ✅ All existing tests pass
6. ✅ Code is clean and well-documented
7. ✅ Performance is equal or better than current implementation
8. ✅ Can boot AmigaOS with MMU enabled

## Next Steps

1. **Review this plan** - Ensure approach is sound
2. **Choose option** - Incremental (A) or Complete Rewrite (B)
3. **Start implementation** - Begin with Step 1 of chosen option
4. **Test frequently** - Validate each phase
5. **Document progress** - Update this file with status
6. **Commit regularly** - Save progress to git

## Contact

For questions or issues during implementation, refer to:
- MC68030 User's Manual: https://www.nxp.com/docs/en/reference-manual/MC68030UM.pdf
- MC680x0 Reference: https://amigasourcecodepreservation.gitlab.io/mc680x0-reference/
- TG68K documentation in repository
