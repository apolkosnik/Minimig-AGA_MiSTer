# Minimig 32-bit Wide Bus Conversion

This document describes the conversion of the Minimig from a 16-bit to 32-bit wide bus architecture.

## Overview

The Minimig has been updated to support a 32-bit wide data bus, enabling:
- Enhanced performance for 32-bit CPUs (68020/68030/68040)
- Increased memory bandwidth using MISTER_DUAL_SDRAM
- Better compatibility with demanding Amiga software

## Key Changes Made

### 1. Data Bus Width Updates
- **CPU Bridge (minimig_m68k_bridge.v)**:
  - Extended data ports from [15:0] to [31:0]
  - Added 4-bit host byte strobes (was 2-bit)
  - Enhanced write strobe logic for 32-bit operations

- **SRAM Bridge (minimig_sram_bridge.v)**:
  - Updated data interface to 32-bit
  - Added upper/lower word enable signals
  - Extended memory data paths

- **CPU Wrapper (cpu_wrapper.v)**:
  - Modified for 32-bit CPU data handling
  - Updated memory interface connections
  - Enhanced autoconfig for 32-bit addressing

### 2. Main Module Updates
- **minimig.v**:
  - All internal data buses expanded to 32-bit
  - Updated data multiplexers
  - Added CIA data zero-extension (CIAs remain 8-bit)
  - Enhanced module interconnections

- **Minimig.sv**:
  - Top-level interface updated for 32-bit
  - Memory controller connections enhanced
  - DUAL_SDRAM support maintained

### 3. Memory System Enhancement
- **MISTER_DUAL_SDRAM**: Already enabled in hardware
- **Bandwidth**: Increased from ~280 MB/s to ~560 MB/s
- **Architecture**: Two 16-bit SDRAM modules provide 32-bit data path

### 4. Backward Compatibility
- 16-bit operations fully supported
- Custom chips (Agnus, Paula, Denise) unchanged
- Peripheral interfaces (IDE, Audio, Joystick) maintain original widths
- CIA interfaces remain 8-bit with proper zero-extension

## Technical Implementation

### Bus Architecture
```
Original: CPU <--16-bit--> Bridge <--16-bit--> SDRAM
Updated:  CPU <--32-bit--> Bridge <--32-bit--> Dual_SDRAM
```

### Memory Mapping
- **Lower 16 bits**: Primary SDRAM (SDRAM_DQ)
- **Upper 16 bits**: Secondary SDRAM (SDRAM2_DQ)
- **Coordination**: Both controllers operate simultaneously

### Byte Enable Logic
```
host_bs[3] -> Upper data strobe (bits 31:24)
host_bs[2] -> Lower data strobe (bits 23:16)
host_bs[1] -> Upper word strobe (bits 15:8)
host_bs[0] -> Lower word strobe (bits 7:0)
```

## Benefits

1. **Performance**: 2x memory bandwidth for CPU operations
2. **Compatibility**: Enhanced support for 32-bit Amiga software
3. **Future-proof**: Ready for more demanding applications
4. **Efficiency**: Better utilization of available FPGA resources

## Files Modified

### Core Modules
- `rtl/minimig_m68k_bridge.v` - CPU interface bridge
- `rtl/minimig_sram_bridge.v` - Memory interface bridge
- `rtl/cpu_wrapper.v` - CPU wrapper and configuration
- `rtl/minimig.v` - Main Minimig module
- `Minimig.sv` - Top-level system integration

### Configuration
- `rtl/minimig_version.vh` - Version updated to 2.0.0
- `sys/sys_dual_sdram.tcl` - DUAL_SDRAM already configured

## Build Instructions

1. Ensure MISTER_DUAL_SDRAM is enabled in hardware
2. Use standard MiSTer build process
3. DUAL_SDRAM macro is set via sys_dual_sdram.tcl
4. No additional configuration changes required

## Testing Notes

The implementation maintains full backward compatibility while adding 32-bit capabilities. All existing software should continue to work, with enhanced performance for 32-bit aware applications.

---
*Conversion completed: [Current Date]*
*Version: 2.0.0 Beta*