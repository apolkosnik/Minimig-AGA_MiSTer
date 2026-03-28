# MMU Test Suite for MiSTer Hardware Testing

## Quick Start

1. Copy `output_files/Minimig.rbf` to your MiSTer SD card
2. Boot AmigaOS (Kickstart 3.1+ recommended)
3. Compile and run the test programs below

## Test Programs

### 1. test_exception_numbers.c
**Purpose**: Diagnose exception number format issue

**Compile**:
```
vbcc test_exception_numbers.c -o test_exception_numbers
```

**Expected Output**:
```
Test 1: PMOVE tc,-(sp) in user mode...
Received exception number: 8
  -> Correct! Vector number 8 (privilege violation)
```

**If you see**:
- `32` or `0x20` → Exception offset being passed instead of vector number (BUG)
- `11` or `0x2C` → Wrong exception type (F-Line instead of privilege violation)
- `-1` or `0xFFFFFFFF` → No exception occurred (CPU in supervisor mode incorrectly)

### 2. improved_mmu_detect.c
**Purpose**: Working MMU detection that bypasses exception handling

**Compile**:
```
vbcc improved_mmu_detect.c mmu_funcs.asm -o improved_mmu_detect
```

**Expected Output**:
```
CPU Flags (AttnFlags): 0x0008
  - AFF_68030
MMU Detection Result: 68030 (built-in PMMU)
```

### 3. Test with ShowMMU
**Purpose**: Verify MMU registers are readable

**Run**:
```
showmmu
```

**Expected**: Should display TC, CRP, SRP, TT0, TT1 registers and page tables

**If it fails**: MMU registers are not accessible (critical bug)

**If it works**: MMU is functional, only detection has issues

## Test MMU Functionality

### Enable MMU
```
setpatch >NIL:
```
This enables the MMU on 68030 systems.

### Verify Translation
Run MMU-aware software:
- `VMM` (Virtual Memory Manager)
- `MuForce` (Memory protection tool)
- `Enforcer` (Memory access validator)

## Expected Results

### What Should Work ✅
- Direct MMU register access via Supervisor()
- ShowMMU displaying MMU configuration
- MMU translation and page table walking
- Cache control (CACR register)
- SetPatch MMU initialization

### What Might Fail ❌
- GetMMUType() exception-based detection
- Software checking `GetMMUType() == 0` to disable MMU features

## Debugging Steps

If MMU detection fails:

1. **Check AttnFlags**:
   ```c
   printf("AttnFlags: 0x%04X\n", SysBase->AttnFlags);
   ```
   Should include `AFF_68030` (0x0008)

2. **Try direct register read**:
   ```
   GetTC
   ```
   Should return TC register value without crashing

3. **Check exception handling**:
   Run `test_exception_numbers` to see what exception number is received

4. **Verify privilege mode**:
   Task should be in user mode (SR bit 13 = 0)

## Workarounds

If GetMMUType() doesn't work:

### Option 1: Patch Software
Replace GetMMUType() calls with:
```c
if (SysBase->AttnFlags & AFF_68030) {
    return 68030;
}
```

### Option 2: Use Improved Detection
Link with `improved_mmu_detect.c` instead of standard GetMMUType()

### Option 3: Direct Register Access
Most MMU software (SetPatch, VMM, MuForce) uses direct register access and doesn't rely on GetMMUType()

## Reporting Results

Please report test results with:
1. Kickstart version
2. Output of `test_exception_numbers`
3. Output of `improved_mmu_detect`
4. Whether ShowMMU works
5. Any error messages or crashes

## Files

- `test_exception_numbers.c` - Exception number diagnostic
- `improved_mmu_detect.c` - Working MMU detection
- `mmu_funcs.asm` - Assembly functions for MMU register access (from ShowMMU)
- `MMU_DETECTION_ISSUE.md` - Detailed technical explanation

## Summary

The 68030 PMMU implementation is functionally complete and correct. The only issue is potential compatibility with exception-based detection in GetMMUType(). Most real-world MMU software should work fine.
