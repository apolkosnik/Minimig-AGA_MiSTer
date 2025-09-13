# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Minimig-AGA_MiSTer project - an FPGA implementation of the Amiga computer for the MiSTer platform. It emulates Amiga OCS, ECS, and AGA chipsets with support for 68000 and 68020 CPUs.

## Development Commands

### Building the Core
- Use Intel Quartus Prime to build the FPGA bitstream
- Main project files: `Minimig.qpf` and `Minimig.qsf` (standard build), `Minimig_Q13.qpf` and `Minimig_Q13.qsf` (Quartus 13 compatibility)
- Build generates RBF files for the MiSTer platform

### Cleaning Build Files
```bash
# Windows batch file for cleanup
clean.bat
```
Removes all generated build files including db/, incremental_db/, output_files/, simulation directories, and temporary files.

### Build System
- Uses Intel Quartus Prime for FPGA synthesis
- TCL scripts in `sys/` directory handle build automation:
  - `build_id.tcl`: Generates build timestamp and CDF files
  - `sys.tcl`: Main system configuration
- Build ID is automatically generated and embedded in `build_id.v`

## Code Architecture

### Top-Level Structure
- `Minimig.sv`: MiSTer framework integration layer
- `rtl/minimig.v`: Core Amiga implementation entry point
- `sys/sys_top.v`: MiSTer system-specific hardware interface

### Major Components

#### CPU Subsystem
- `rtl/tg68k/`: TG68K CPU core (VHDL-based)
  - Supports 68000, 68010, and 68020 architectures
  - Memory management unit (PMMU) for 68030 features
- `rtl/cpu_wrapper.v`: CPU integration wrapper
- `rtl/cpu_cache_new.v`: CPU cache implementation

#### Chipset Components
- `rtl/agnus.v` + `rtl/agnus_*.v`: Graphics DMA and memory management
  - Bitplane DMA, sprite DMA, blitter, copper
- `rtl/denise.v` + `rtl/denise_*.v`: Video output and graphics generation
  - Bitplane rendering, sprites, collision detection, color tables
- `rtl/paula.v` + `rtl/paula_*.v`: Audio and I/O management
  - 4-channel audio, UART, floppy controller, interrupt controller
- `rtl/ciaa.v` / `rtl/ciab.v`: Complex Interface Adapters (I/O ports and timers)
- `rtl/gary.v`: Memory controller and address decoding
- `rtl/gayle.v`: IDE interface controller

#### Memory Subsystem
- `rtl/sdram_ctrl.v`: SDRAM controller for main memory
- `rtl/minimig_bankmapper.v`: Memory bank mapping
- `rtl/minimig_sram_bridge.v`: SRAM interface bridge

#### Peripheral Support
- `rtl/ide.v`: IDE/ATA disk interface
- `rtl/rtg.v`: RTG (Retargetable Graphics) support for high-resolution modes
- `rtl/akiko.v`: CD32 Akiko chip emulation
- `rtl/fastchip.v`: Fast memory acceleration
- `rtl/fpga-toccata/`: Toccata sound card emulation

### System Integration (`sys/` directory)
- Hardware abstraction layer for MiSTer platform
- Video output processing (scandoubler, scaler, OSD)
- Audio processing and output
- HPS (Hard Processor System) interface
- DDR3 memory controller
- USB and network interfaces

## Key Development Notes

### Current Branch Status
- Working on branch `030` (68030 development)
- Major 68030 implementation work completed:
  - Updated CPU parameter encoding (CPU="11" now = 68030)
  - Added PMMU instruction support (PMOVE, PTEST, PFLUSH, PLOAD)
  - Added cache control instruction framework (CINV, CPUSH)
  - Created basic cache module structure

### 68030 Implementation Status
#### ✅ Completed Features:
- **CPU Mode Encoding**: Updated to support 68030 as CPU="11"
- **PMMU Instructions**: PMOVE, PTEST, PFLUSH, PLOAD instruction decoding
- **PMMU Registers**: TC, CRP, SRP, TT0, TT1, MMUSR, CAL registers
- **Cache Instructions**: CINV, CPUSH instruction decoding
- **Basic Cache Module**: 256-byte I-cache and D-cache structure

#### ⚠️ In Progress:
- **PMMU Translation**: Currently identity mapping only
- **Cache Integration**: Module created but not fully integrated
- **Memory System**: Cache/PMMU integration with memory controller

#### ❌ Still Missing:
- **Real Page Table Walking**: PMMU needs actual translation logic
- **Cache Memory Integration**: Cache fill/writeback with memory system
- **Enhanced CACR**: Full 32-bit CACR implementation
- **MMU Exception Handling**: Proper fault generation and handling

### Important TODOs (from TODO file)
- AGA chipset enhancements (bitplane shifter improvements, sprite positioning)
- CPU compatibility fixes ongoing
- Blitter reimplementation under consideration
- CD32 gamepad support development

### Testing
- No automated test suite - testing typically done with actual Amiga software
- Use Amiga Kickstart ROMs and software for validation
- Test with various OCS/ECS/AGA software configurations
- **68030 Testing**: Requires 68030-aware software for validation

## File Organization Conventions
- Verilog files use `.v` extension
- VHDL files use `.vhd` extension
- Quartus IP files use `.qip` extension
- Memory initialization files use `.mem` extension
- Configuration uses `.vh` for Verilog headers

## Development Workflow
1. Make changes to RTL files in `rtl/` directory
2. Update version in `rtl/minimig_version.vh` if needed
3. Build using Quartus Prime
4. Test generated RBF file on MiSTer hardware
5. Verify functionality with Amiga software