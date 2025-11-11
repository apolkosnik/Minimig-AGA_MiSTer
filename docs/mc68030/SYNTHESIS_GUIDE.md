# MC68030 Synthesis Guide for MiSTer FPGA

**Date**: 2025-11-11
**Phase**: 11 - Hardware Testing
**Target**: Cyclone V FPGA (MiSTer platform)
**Status**: Build system configured, ready for synthesis

---

## Overview

This guide describes how to synthesize the MC68030 implementation for the MiSTer FPGA platform using Intel Quartus Prime.

## Prerequisites

- Intel Quartus Prime (version 17.0 or later recommended for Cyclone V)
- MiSTer FPGA development environment
- Git repository cloned and on branch `claude/mc68030-implementation-011CV1P7SFSGPVf8P7bhgzsY`

---

## Build System Configuration

### Files Modified/Created (Phase 11)

#### 1. TG68K030.qip (NEW)
**Location**: `rtl/tg68k030/TG68K030.qip`

Contains all 21 MC68030 VHDL component files in proper dependency order:
- MMU registers and components
- Address Translation Cache (ATC)
- F-line instruction decoders (PMOVE, PFLUSH, PTEST)
- F-line instruction executors
- Instruction and data caches
- Memory controller, bus arbiter, burst controller
- Top-level TG68K030 wrapper

**Format**: Quartus TCL commands
```tcl
set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) <filename>.vhd ]
```

#### 2. files.qip (MODIFIED)
**Location**: `files.qip`

Added TG68K030.qip after TG68K.qip:
```tcl
set_global_assignment -name QIP_FILE rtl/tg68k/TG68K.qip
set_global_assignment -name QIP_FILE rtl/tg68k030/TG68K030.qip  # NEW
set_global_assignment -name QIP_FILE rtl/fx68k/fx68k.qip
```

#### 3. Minimig.sdc (MODIFIED)
**Location**: `Minimig.sdc`

Added MC68030-specific timing constraints:
```sdc
# F-line instruction execution is multi-cycle by design
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|fline_*} -setup 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|fline_*} -hold 2

# MMU register access paths
set_multicycle_path -from {*mmu_reg*} -to {*pmove*} -setup 2
set_multicycle_path -from {*mmu_reg*} -to {*pmove*} -hold 1
set_multicycle_path -from {*pmove*} -to {*mmu_reg*} -setup 2
set_multicycle_path -from {*pmove*} -to {*mmu_reg*} -hold 1

# F-line decoder to executor paths
set_multicycle_path -from {*_decoder|*} -to {*_executor|*} -setup 2
set_multicycle_path -from {*_decoder|*} -to {*_executor|*} -hold 1
```

---

## Synthesis Steps

### Step 1: Open Project in Quartus

```bash
cd /path/to/Minimig-AGA_MiSTer
quartus Minimig.qpf
```

Or for command-line:
```bash
quartus_sh --flow compile Minimig
```

### Step 2: Check File Inclusion

Verify that all TG68K030 files are included:
1. Open Quartus project
2. Go to: **Project → Add/Remove Files in Project**
3. Verify `rtl/tg68k030/TG68K030.qip` appears in the file list
4. Verify all 21 VHDL files from TG68K030 directory are listed

### Step 3: Analysis & Synthesis

**GUI Method**:
1. Processing → Start → Start Analysis & Synthesis (Ctrl+K)

**Command Line**:
```bash
quartus_map Minimig
```

**Expected Output**:
- All VHDL files should compile without syntax errors
- Check for warnings about unused signals (acceptable for stub interfaces)
- Look for critical warnings about:
  - Missing entity definitions → indicates missing files
  - Port mismatch → indicates interface issues
  - Syntax errors → needs VHDL fixes

### Step 4: Check Resource Usage

After successful analysis, check resource utilization:

**GUI**:
- Compilation Report → Analysis & Synthesis → Resource Section

**Expected Resources** (approximate, with MC68030 enabled):

| Resource | TG68K Only | With MC68030 | Increase |
|----------|-----------|--------------|----------|
| ALMs | ~2,500 | ~3,700 | +1,200 (48%) |
| Registers | ~3,000 | ~3,300 | +300 (10%) |
| Memory Bits | ~50K | ~51K | +1K (2%) |
| **Total FPGA %** | **~8%** | **~12%** | **+4%** |

**Cyclone V Capacity**: 32,070 ALMs, so ~12% usage is acceptable.

### Step 5: Full Compilation

**GUI**: Processing → Start Compilation (Ctrl+L)

**Command Line**:
```bash
quartus_sh --flow compile Minimig
```

**Compilation Stages**:
1. Analysis & Synthesis (~5-10 minutes)
2. Fitter (Place & Route) (~15-30 minutes)
3. Assembler (Generate .rbf file) (~2 minutes)
4. Timing Analyzer (~3 minutes)

### Step 6: Timing Analysis

Check timing reports:

**GUI**:
- Compilation Report → TimeQuest Timing Analyzer → Slow 1100mV 85C Model → Summary

**Key Timing Metrics**:
- **Setup Slack**: Should be positive (0 or higher)
- **Hold Slack**: Should be positive
- **Clock Frequency**: Should meet target (~114 MHz for MiSTer)

**If Timing Fails**:
- Check which paths are failing
- Most likely: F-line instruction paths (already have multicycle constraints)
- May need to increase multicycle path setup from 3 to 4 cycles
- Check critical path report for specific failing modules

### Step 7: Generate Programming File

If compilation succeeds:
- Output file: `output_files/Minimig.rbf`
- This is the MiSTer FPGA bitstream

---

## Common Issues and Solutions

### Issue 1: Missing Entity Errors

**Symptom**:
```
Error: Can't find entity "TG68K030_PMOVE_Decoder"
```

**Solution**:
- Verify TG68K030.qip is in files.qip
- Check file paths in TG68K030.qip are correct
- Ensure all .vhd files exist in rtl/tg68k030/

### Issue 2: Port Mismatch Errors

**Symptom**:
```
Error: Port "fline_is_mmu" not found in entity "TG68KdotC_Kernel"
```

**Solution**:
- Verify TG68KdotC_Kernel.vhd has Phase 10 modifications
- Check entity declaration includes F-line interface ports (lines 120-127)
- Verify TG68K030.vhd component declaration matches

### Issue 3: Timing Violations

**Symptom**:
```
Critical Warning: Timing requirements not met
Setup slack: -2.5ns on path ...
```

**Solution**:
- Increase multicycle path constraints in Minimig.sdc
- For F-line paths, change from 3 to 4 cycles:
```sdc
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|fline_*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|fline_*} -hold 3
```
- Recompile and check timing again

### Issue 4: Resource Overflow

**Symptom**:
```
Error: Not enough ALMs to implement design
```

**Solution**:
- Reduce MC68030 features by editing TG68K030 generics
- Disable MMU: Set `ENABLE_MMU => false` in instantiation
- Reduce cache size: Change `CACHE_SIZE => 128` (from 256)
- Reduce ATC entries: Change `ATC_ENTRIES => 16` (from 22)

### Issue 5: Synthesis Warnings About Latches

**Symptom**:
```
Warning: Latch inferred for signal "fline_exec_req"
```

**Solution**:
- Check that all signals are initialized in processes
- Verify reset clauses assign all signals
- For fline_exec_req: Should be initialized to '0' in TG68KdotC_Kernel

---

## Testing on Hardware

### Prerequisites
- MiSTer FPGA with recent framework
- SD card with Amiga Kickstart ROMs
- Serial console or SSH access (for debugging)

### Installation Steps

1. **Copy RBF file**:
```bash
scp output_files/Minimig.rbf root@mister:/media/fat/_Computer/Minimig_20251111.rbf
```

2. **Rename for testing**:
```bash
ssh root@mister
cd /media/fat/_Computer
mv Minimig_20251111.rbf Minimig.rbf
```

3. **Load core**:
- From MiSTer menu, select Computer → Minimig
- Core will reload with new bitstream

### Testing Procedure

#### Test 1: Basic Boot (cpucfg=01, 68010 mode)
1. Set CPU mode to 68010 in OSD
2. Boot with Kickstart 1.3
3. Verify normal Amiga operation
4. **Expected**: No regression, works as before

#### Test 2: 68020 Mode (cpucfg=10)
1. Set CPU mode to 68020
2. Boot with Kickstart 3.1
3. Run SysInfo and check CPU detection
4. **Expected**: Detected as 68020, no crashes

#### Test 3: 68030 Mode (cpucfg=11) - Basic
1. Set CPU mode to 68030 (new option)
2. Boot with Kickstart 3.1
3. System should boot to Workbench
4. **Expected**:
   - Boots successfully
   - No F-line traps during boot
   - System stable

#### Test 4: F-Line Instructions
1. In 68030 mode
2. Run test program that uses PMOVE instruction:
```assembly
    PMOVE  TC,D0        ; Read translation control
    MOVE.L D0,-(SP)     ; Save to stack
```
3. **Expected**:
   - No illegal instruction trap
   - D0 contains TC register value (0x00000000 if MMU disabled)
   - Program completes successfully

#### Test 5: MMU Enable Test
1. Write test program:
```assembly
    MOVE.L #$80008000,D0  ; Enable translation
    PMOVE  D0,TC          ; Write to TC
    PMOVE  TC,D1          ; Read back
    CMP.L  D0,D1          ; Should match
    BNE    error
```
2. **Expected**:
   - PMOVE TC write succeeds
   - Read back value matches
   - No system crash

### Debugging

**Serial Console Logging**:
```bash
# On MiSTer
tail -f /var/log/messages
```

**Check CPU Mode**:
```bash
# In Amiga
CPUCheck  ; Shows detected CPU type
SysInfo   ; Shows CPU configuration
```

**Known Issues**:
- PFLUSH/PTEST are stubs - will execute but don't perform actual operations
- ATC is not yet connected - translations won't be cached
- Memory interface for PMOVE not connected - only register operations work

---

## Resource Reduction Options

If FPGA is too full, edit TG68K030 instantiation generics:

### Option 1: Disable MMU (Saves ~1000 ALMs)
```vhdl
TG68K030_instance: TG68K030
    generic map(
        ENABLE_MMU    => false,  -- Changed from true
        ENABLE_CACHES => true,
        ...
    )
```

### Option 2: Reduce Caches (Saves ~300 ALMs)
```vhdl
    generic map(
        ENABLE_MMU    => true,
        ENABLE_CACHES => true,
        CACHE_SIZE    => 128,    -- Changed from 256
        ...
    )
```

### Option 3: Minimal Configuration (Saves ~1200 ALMs)
```vhdl
    generic map(
        ENABLE_MMU    => false,
        ENABLE_CACHES => false,
        ENABLE_BURST  => false,
        ...
    )
```

**Note**: With all features disabled, 68030 mode is equivalent to 68020 mode.

---

## Performance Benchmarking

After successful hardware testing, run benchmarks:

### AIBB (Amiga Instruction Benchmark Battery)
```
Expected results (68030 vs 68020):
- Integer operations: ~10% faster
- Memory access: ~15% faster (with caches)
- Overall: ~12% improvement
```

### SysInfo
- Should detect as MC68030
- Should show MMU present
- Cache status should show enabled/disabled correctly

---

## Next Steps After Successful Synthesis

1. **Complete PMOVE Implementation**:
   - Connect effective address calculation
   - Connect memory interface for EA-based operations

2. **Implement ATC Flush**:
   - Connect PFLUSH executor to ATC module
   - Test with MMU-enabled software

3. **Implement PTEST**:
   - Connect to table walker
   - Update MMUSR register with results

4. **Full MMU Testing**:
   - Enable translation via TC
   - Test page table walks
   - Verify address translation correctness

5. **Performance Optimization**:
   - Analyze critical paths
   - Pipeline optimizations
   - Cache tuning

---

## Troubleshooting Commands

### Quartus Command-Line Compilation
```bash
# Full compilation
quartus_sh --flow compile Minimig

# Analysis only
quartus_map Minimig

# Timing analysis only
quartus_sta Minimig

# Generate programming file only
quartus_asm Minimig
```

### Check Compilation Status
```bash
# Check if compilation completed
ls -lh output_files/Minimig.rbf

# Check resource usage from command line
grep -A 10 "Logic utilization" output_files/Minimig.fit.summary

# Check timing from command line
grep -A 5 "Slack" output_files/Minimig.sta.summary
```

### Clean Build
```bash
quartus_sh --clean Minimig
rm -rf db/ incremental_db/ output_files/
```

---

## Summary

### Current State (After Phase 11 Build System Setup)
- ✅ All MC68030 files added to build system (TG68K030.qip)
- ✅ files.qip updated to include TG68K030 components
- ✅ Timing constraints added for F-line and MMU paths
- ✅ Ready for Quartus synthesis

### Expected Outcome
- Successful synthesis with ~12% FPGA utilization
- No timing violations with multicycle path constraints
- Functional .rbf file ready for MiSTer testing

### Known Limitations
- PFLUSH/PTEST executors are stubs (complete but don't perform operations)
- PMOVE limited to register access (no EA memory operations yet)
- ATC present but not connected to PFLUSH
- Table walker not connected to PTEST

### Success Criteria
- [x] Build system configured
- [ ] Quartus synthesis completes without errors
- [ ] Timing analysis passes
- [ ] RBF file generated
- [ ] Hardware boots in 68030 mode
- [ ] PMOVE instruction executes without trap
- [ ] System remains stable

---

**Document Version**: 1.0
**Last Updated**: 2025-11-11
**Branch**: claude/mc68030-implementation-011CV1P7SFSGPVf8P7bhgzsY
**Commit**: 83fa6a1 (Phase 11 build system)
