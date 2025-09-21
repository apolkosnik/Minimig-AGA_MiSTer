# TG68K FPU Testing Guide

## Quick Start

To run the complete validation suite:

```bash
cd /path/to/Minimig-AGA_MiSTer/rtl/tg68k
vsim -c -do run_validation_suite.do
```

## Individual Tests

### 1. CPU Reset and Basic Functionality
```bash
vsim -c -do run_simple_debug.do
```
**Purpose**: Validates CPU reset sequence, memory interface, and basic execution  
**Expected**: CPU loads reset vectors, jumps to $1000, executes instructions

### 2. FPU Opcode Processing
```bash  
vsim -c -do run_final_fpu_test.do
```
**Purpose**: Tests specific FPU opcodes F325, F225E0FF, F225BC00, F21D9C00, F21DD0FF, F35D  
**Expected**: F-line instruction detection, FPU decoder activation

### 3. Quick FPU Validation
```bash
vsim -c -do short_fpu_test.do
```
**Purpose**: Fast validation of FPU functionality  
**Expected**: "F35D DEBUG: F-line instruction detected" messages

## Interpreting Results

### ✅ Success Indicators
- `DEBUG: Instruction fetch at PC=4096` - CPU reaches test program
- `F35D DEBUG: F-line instruction detected` - FPU opcodes being processed  
- `FPU2 DEBUG: opcode bits 8:6 = 'X''X''X'` - FPU decoder active
- Minimal `skipFetch` warnings - skipFetch fixes working

### ❌ Failure Indicators  
- CPU stuck at PC=0 - Reset sequence failed
- No F-line detection messages - FPU not responding
- Excessive skipFetch warnings - Fixes not applied
- Compilation errors - VHDL compatibility issues

## Troubleshooting

### Issue: CPU Stuck at Reset
**Symptoms**: All instruction fetches at PC=0  
**Solution**: Verify combinatorial memory model (not clocked)

### Issue: No FPU Activity  
**Symptoms**: No F-line debug messages  
**Solution**: Check FPU_Enable generic is set to 1

### Issue: Compilation Errors
**Symptoms**: VHDL syntax or compatibility errors  
**Solution**: Ensure VHDL-2008 mode (`-2008` flag)

### Issue: ModelSim Warnings
**Symptoms**: "Design size exceeds capacity" warnings  
**Solution**: Normal for large design - does not affect functionality

## Test File Descriptions

| File | Purpose | Key Features |
|------|---------|--------------|
| `simple_cpu_debug.vhd` | Basic CPU validation | Reset sequence, memory interface |
| `final_fpu_opcode_test.vhd` | FPU opcode testing | F-line detection, specific opcodes |
| `test_fpu_opcodes_fixed.vhd` | Advanced FPU testing | Execution monitoring, state tracking |

## Hardware Deployment

After successful validation:

1. Copy `Minimig_FTST_Fixed_20250810_213553.rbf` to MiSTer SD card
2. Rename to `Minimig.rbf` in `_Computer` folder  
3. Test with problematic sequence that previously caused skipFetch issues
4. Verify FTST.B D1 followed by move instruction executes correctly

## Expected Hardware Behavior

With the validated RBF file, the following sequence should execute without infinite loops:

```assembly
move.l a7,a1      ; Execute normally
move.l a7,a2      ; Execute normally  
ftst.b d1         ; Execute FPU test
move.l a7,a3      ; Should NOT be skipped (was previously skipped)
fsave -(a7)       ; Execute normally
move.l a2,d3      ; Execute normally
```

## Validation Checklist

- [ ] CPU reset sequence loads proper vectors
- [ ] CPU jumps to test program at $1000
- [ ] F-line instructions are detected  
- [ ] FPU decoder processes opcodes
- [ ] skipFetch warnings are minimal
- [ ] All 6 requested opcodes show F-line activity
- [ ] Hardware RBF file is ready for deployment

## Support

For issues or questions about FPU validation:

1. Check `FPU_VALIDATION_SUITE.md` for detailed results
2. Review `BUILD_SUMMARY_FTST_FIXED.md` for fix documentation
3. Examine `FTST_SKIPFETCH_FIX_SUMMARY.md` for technical details
4. Run validation suite to reproduce issues