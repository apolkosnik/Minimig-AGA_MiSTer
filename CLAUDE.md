# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Minimig-AGA_MiSTer project - an FPGA implementation of the Amiga computer for the MiSTer platform. It emulates Amiga OCS, ECS, and AGA chipsets with support for 68000 and 68020 CPUs.

## Development Commands

### Building the Core
- Use Intel Quartus Prime to build the FPGA bitstream
- Main project files: `Minimig.qpf` and `Minimig.qsf` (standard build), `Minimig_Q13.qpf` and `Minimig_Q13.qsf` (Quartus 13 compatibility)
- Build generates RBF files for the MiSTer platform
- Keep track of the build's PID, you don't want to pkill builds from another instance!
- **Remember to check for multiple drivers before starting a build**

#### Linux Build Commands
```bash
# Full compilation
quartus_sh --flow compile Minimig

# Background build with logging
nohup quartus_sh --flow compile Minimig > build.log 2>&1 &

# Check build progress
tail -f build.log

# Clean and rebuild
./clean.sh && quartus_sh --flow compile Minimig
```

### Cleaning Build Files
```bash
# Linux cleanup script
./clean.sh
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
- **PMMU Instructions**: Full PMOVE, PTEST, PFLUSH, PLOAD implementation
- **PMMU Registers**: TC, CRP, SRP, TT0, TT1, MMUSR, CAL with proper read/write handling
- **Cache Instructions**: Complete CINV, CPUSH instruction implementation
- **Page Table Walking**: Multi-level MC68030 page table traversal (W_ROOT→W_PTR1→W_PTR2→W_PTR3→W_PAGE)
- **Address Translation Cache**: 8-entry ATC with proper tag matching and replacement
- **Transparent Translation**: TT0/TT1 register support for bypassing MMU
- **CACR Register**: Full 32-bit Cache Control Register with self-clearing bits
- **MMU Exception Handling**: Complete fault detection and status reporting
- **Cache Modules**: 256-byte instruction and data cache implementations
- **Descriptor Validation**: Proper MC68030 page descriptor parsing and validation
- **Access Control**: Supervisor/user privilege checking and write protection

#### ✅ Recently Completed:
- **Cache Integration**: Physical addresses from PMMU now properly connected to cache system
- **Cache Memory Interface**: Cache modules connected to memory controller with proper address routing

#### ⚠️ In Progress:
- **Cache Bus Integration**: Full cache line fill and write-back with external memory timing
- **Performance Optimization**: Cache hit/miss handling in memory access cycles needs validation

### 68030 Technical Implementation Details
- **Specifications**: `https://www.nxp.com/docs/en/reference-manual/MC68030UM.pdf`

#### PMMU (Paged Memory Management Unit)
- **File**: `rtl/tg68k/TG68K_PMMU_030.vhd`
- **Features**: Complete MC68030-compatible PMMU with:
  - Multi-level page table walking (up to 4 levels)
  - 8-entry Address Translation Cache (ATC)
  - Transparent Translation Registers (TT0/TT1)
  - Proper MC68030 page descriptor format support
  - Function code-based privilege checking
  - Write protection and cache control attribute extraction

#### Cache System
- **Files**: `rtl/tg68k/TG68K_Cache_030.vhd`
- **Architecture**: 
  - 256-byte instruction cache (direct-mapped, 16 lines × 16 bytes)
  - 256-byte data cache (direct-mapped, 16 lines × 16 bytes)
  - Write-through data cache policy
  - Cache line fill support (128-bit cache lines)
  - CINV/CPUSH instruction support for cache control

#### CACR Register Implementation
- **Features**:
  - Full 32-bit Cache Control Register
  - Bit definitions: DE(0), IE(1), FREEZE(2), CE(3), CI(4), CD(5), CA(6)
  - Self-clearing cache control bits (CE, CI, CD, CA)
  - Reserved bit masking (bits 31-7)
  - Individual control signal extraction

#### MMU Exception Handling
- **Fault Types Supported**:
  - Invalid descriptor faults
  - Write protection violations
  - Supervisor/user access violations
  - Bus errors during page table walks
- **Status Reporting**: 8-bit fault status with level information, function codes, and fault type

#### Integration Points
- **CPU Core**: Enhanced TG68KdotC_Kernel with PMMU and cache control
- **Instruction Decode**: Added PMMU instruction microcode states
- **Memory Interface**: PMMU translation applied to all memory accesses
- **Exception Handling**: MMU faults integrated with CPU exception processing

### Important TODOs

#### Next Priority Items for 68030:
1. **Cache Performance Integration**: Optimize cache line fill timing and memory access cycles
2. **Performance Testing**: Benchmark 68030 performance vs 68020 mode with memory-intensive software
3. **PMMU Testing**: Test with actual AmigaOS 3.x MMU-aware software and applications
4. **Cache Effectiveness**: Measure cache hit rates and performance improvements  
5. **Compatibility Testing**: Ensure 68000/68010/68020 modes still work correctly
6. **Test Suite Updates**: Update testbenches to work with new 32-bit MMUSR and cache interfaces

#### General Project TODOs (not in scope for now):
- AGA chipset enhancements (bitplane shifter improvements, sprite positioning)
- CPU compatibility fixes ongoing
- Blitter reimplementation under consideration
- CD32 gamepad support development

### Testing

#### TG68K 68030 Test Suite (`tests/tg68k_030/`)
- **Comprehensive VHDL simulation test suite** for 68030 components using ModelSim
- **Test Components**:
  - PMMU (Paged Memory Management Unit) functionality tests
  - Cache system tests (instruction and data cache)
  - CACR (Cache Control Register) tests
  - System integration tests with full CPU kernel
  - Page table walker tests
  - Address translation and fault handling tests

#### Test Infrastructure
- **ModelSim Integration**: Uses Intel ModelSim ASE for VHDL simulation
- **Automated Test Runner**: `Makefile` provides easy test execution commands
- **Test Scripts**: TCL scripts for automated test sequences
- **Waveform Analysis**: Generates `.wlf` files for detailed signal analysis

#### Running Tests
```bash
# Navigate to test directory
cd tests/tg68k_030/

# Run all tests
make test-all

# Run individual component tests
make test-pmmu    # PMMU tests only
make test-cache   # Cache tests only  
make test-cacr    # CACR register tests only
make test-integration  # Full system tests

# Interactive debugging with GUI
make test-gui

# Quick functional verification
make test-quick

# Clean test artifacts
make clean
```

#### Test Coverage
- **PMMU Tests**: Register access, translation requests, page table walking, fault conditions
- **Cache Tests**: Cache line operations, hit/miss behavior, CINV/CPUSH instructions
- **CACR Tests**: Cache control register functionality and self-clearing bits
- **Integration Tests**: Full CPU-PMMU-Cache interaction scenarios
- **Fault Testing**: MMU exception handling and status reporting

#### Requirements
- Intel ModelSim ASE (configured for path `/opt/intelFPGA_lite/17.0/modelsim_ase`)
- VHDL source files in `rtl/tg68k/` directory
- Proper VHDL-93 compilation environment

#### Hardware Testing
- **MiSTer Platform**: Testing with actual Amiga software on MiSTer hardware
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

## Build Environment
- We are building on Linux

## Memories

### Build-Related Memories
- Keep track of the build's PID, you don't want to pkill builds from another instance!

### Test-Related Memories
- I don't want any simpler tests, fix the existing test!
- ModelSim is not having persistent library issues, you just forget to fix them properly!
- Fix the issues, do not hide them!