# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Minimig-AGA_MiSTer project - an FPGA implementation of the Amiga computer for the MiSTer platform. It emulates Amiga OCS, ECS, and AGA chipsets with support for 68000, 68010, 68020, and 68030 CPUs. Active development is focused on 68030 CPU implementation with full PMMU and cache support.

## Development Commands

### Building the Core
- Use Intel Quartus Prime to build the FPGA bitstream
- Main project files: `Minimig.qpf` and `Minimig.qsf` (standard build), `Minimig_Q13.qpf` and `Minimig_Q13.qsf` (Quartus 13 compatibility, not currently used)
- Build generates RBF files for the MiSTer platform
- Keep track of the build's PID, you don't want to pkill builds from another instance!
- create and run regression tests and correctness tests before building the rbf
- Check if the process is there with ps instead of trying to kill it right away
- Never convert the existing SOF to RBF!
- **Remember to check for multiple drivers issues before starting a build**

#### Linux Build Commands
```bash
# Full compilation
quartus_sh --flow compile Minimig

# Background build with logging
nohup quartus_sh --flow compile Minimig > build.log 2>&1 &

# Check build progress
tail -f build.log

# Clean and rebuild
rm -rf db/ incremental_db/ output_files/ && quartus_sh --flow compile Minimig
```

### Cleaning Build Files
```bash
# Remove all build artifacts
rm -rf db/ incremental_db/ output_files/ simulation/ greybox_tmp/
rm -f build_id.v *.rpt *.done *.summary *.smsg *.pin *.sof *.pof *.rbf
```
Note: No clean.sh script exists in the repository root.

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

#### ⚠️ In Progress:
- **Cache Integration**: Cache component declared but not fully connected to memory system

#### ❌ Still Missing:
- **Cache Memory Interface**: Cache fill/writeback integration with existing memory timing
- **Cache Bus Integration**: Full cache line fill and write-back with external memory
- **Performance Optimization**: Cache hit/miss handling in memory access cycles

### 68030 Technical Implementation Details
- **Specifications**: `/home/adam/Desktop/MC68030UM.pdf`


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
  - Bit definitions: EI(0), FI(1), CEI(2), CI(3), IBE(4), ED(8), FD(9), CED(10), CD(11), DBE(12), WA(13)
  - Self-clearing cache control bits (CEI, CI, CD, CED)
  - Reserved bit masking (bits 31-14,7-5)
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
1. **Cache Memory Integration**: Connect cache modules to memory controller for actual cache line fills
2. **Performance Testing**: Benchmark 68030 performance vs 68020 mode with memory-intensive software
3. **PMMU Testing**: Test with actual AmigaOS 3.x MMU-aware software and applications
4. **Cache Effectiveness**: Measure cache hit rates and performance improvements
5. **Compatibility Testing**: Ensure 68000/68010/68020 modes still work correctly

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

# Run comprehensive test suite
make test-all            # All basic tests
make test-regression     # MC68030 compliance tests

# Component-specific tests
make test-pmmu          # PMMU functionality
make test-cache         # Cache operations
make test-cacr          # CACR register
make test-pmove-tc      # PMOVE TC operations
make test-integration   # Full system tests

# Debug with GUI
make test-gui           # Interactive ModelSim

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
- Alternatively, iverilog is available

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
2. Run ModelSim tests: `cd tests/tg68k_030 && make test-regression`
3. Update version in `rtl/minimig_version.vh` if needed
4. Build using Quartus Prime: `quartus_sh --flow compile Minimig`
5. Test generated RBF file on MiSTer hardware
6. Verify functionality with Amiga software

## Build Environment
- We are building on Linux

## Memories
- check if the process is there with ps instead of trying to kill it right away

### Build-Related Memories
- Keep track of the build's PID, you don't want to pkill builds from another instance!

### Test-Related Memories
- I don't want any simpler tests, fix the existing test!

## TG68K Register Reference

### Control Registers (Accessible via MOVEC)

#### CACR - Cache Control Register (0x002) - 32-bit
**Current Implementation** (`rtl/tg68k/TG68KdotC_Kernel.vhd`):
```
Bit 0 (EI): Instruction Cache Enable
Bit 1 (FI): Cache Freeze (inhibit replacement)
Bit 2 (CEI): Clear Entry in Instruction Cache
Bit 3 (CI): Clear Instruction Cache (self-clearing)
Bit 4 (IBE): Instruction Burst Enable
Bit 5: Reserved (reads 0)
Bit 6: Reserved (reads 0)
Bit 7: Reserved (reads 0)
Bit 8 (ED): Data Cache Enable
Bit 9 (FD): Data Cache Freeze (used by AmigaOS for 68030 detection)
Bit 10 (CED): Clear Entry in Data Cache
Bit 11 (CD): Clear Data Cache
Bit 12 (DBE): Data Burst Enable
Bit 13 (WA): Write Allocate
Bits 31-14: Reserved (should read as 0, writes ignored)
```

**Cache Control Logic**:
- Command bits (3-2, 11-10) are self-clearing and never stored
- Enable/freeze bits (1-0, 9-8) are sticky until explicitly changed
- Reserved bits (31-14, 7-5) are read as 0

#### VBR - Vector Base Register (0x801) - 32-bit
```
Bits 31-0: Vector table base address (must be on 4-byte boundary)
```

#### SFC - Source Function Code (0x000) - 3-bit
```
Bits 2-0: Function code for source operand of MOVES instruction
```

#### DFC - Destination Function Code (0x001) - 3-bit
```
Bits 2-0: Function code for destination operand of MOVES instruction
```

#### CAAR - Cache Address Access Register (0x802) - 32-bit
```
Bits 31-8: Cache Function Address
Bits 7-2: INDEX
Bits 1-0: Always 0
```

#### USP - User Stack Pointer (0x800) - 32-bit
**Note**: Currently NULL operation in implementation
```
Bits 31-0: User mode stack pointer
```

#### MSP - Master Stack Pointer (0x803) - 32-bit
**Note**: Currently NULL operation in implementation
```
Bits 31-0: Master mode stack pointer (68020+)
```

#### ISP - Interrupt Stack Pointer (0x804) - 32-bit
**Note**: Currently NULL operation in implementation
```
Bits 31-0: Interrupt mode stack pointer (68020+)
```

### PMMU Registers (Accessible via PMOVE only)

#### TC - Translation Control Register - 32-bit
**Register Select**: 0x0 (`rtl/tg68k/TG68K_PMMU_030.vhd`)
```
Bit 31 (E):      Enable MMU translation
Bit 30-26:       Reserved (forced to 0)
Bit 25 (SRE):    Supervisor Root Enable
Bit 24 (FCL):    Function Code Lookup
Bits 23-20 (PS): Page Size (4KB pages = 0000)
Bits 19-16 (IS): Initial Shift
Bits 15-12 (TIA): Table Index A field size
Bits 11-8 (TIB):  Table Index B field size
Bits 7-4 (TIC):   Table Index C field size
Bits 3-0 (TID):   Table Index D field size
```

##### TC - Page Size (PS) field
```
Page Size (PS) - 4-bit field specifies the system page size:
1000: 256 bytes
1001: 512 bytes
1010: 1K bytes
1011: 2K bytes
1100: 4K bytes
1101: 8K bytes
1110: 16K bytes
1111: 32K bytes

All other bit combinations are reserved by Motorola for future use; an
attempt to load other values into this field of the TC register causes an MMU configuration exception. 
```

#### CRP - CPU Root Pointer - 64-bit
**Register Select**: 0x1 (requires reg_part for high/low)
```
HIGH (63-32):
  Bit 63 (LU): Lower or Upper Page Range
  Bits 62-48 (LIMIT): Limit on Table Index for This Table address
  Bits 47-33: Reserved (forced to 0)
  Bits 32 (DT): Descriptor Type


LOW (31-0):
  Bits 31-16: Table Address (PA31 - PA16)
  Bits 15-4: Table Address (PA15 - PA4)
  Bits 3-0: Reserved (forced to 0)
```

#### SRP - Supervisor Root Pointer - 64-bit
**Register Select**: 0x2 (requires reg_part for high/low)
```
Same format as CRP - provides separate page tables for supervisor mode
```
#### SHORT-FORMAT TABLE DESCRIPTOR - 32-bit
  Bits 31-4: Table Address
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type 

#### LONG-FORMAT TABLE DESCRIPTOR - 2*32-bit
HIGH:
  Bit 31 (L/U): Lower or Upper
  Bits 30-16 (LIMIT):
  Bits 15-10: Reserved (forced to 1)
  Bit 9: Reserved (forced to 0)
  Bit 8 (S):
  Bits 7-4: Reserved (forced to 0)
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-4: Table Address
  Bits 3-0 (UNUSED): forced to 0


#### SHORT-FORMAT EARLY TERMINATION PAGE DESCRIPTOR - 32-bit
  Bits 31-8: Page Address
  Bit 7: Unused (forced to 0)
  Bit 6 (CI):
  Bit 5:Unused (forced to 0)
  Bit 4 (M):
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type


#### LONG-FORMAT EARLY TERMINATION PAGE DESCRIPTOR - 2*32-bit
HIGH:
  Bit 31 (L/U): Lower or Upper
  Bits 30-16 (LIMIT):
  Bits 15-10: Reserved (forced to 1)
  Bit 9: Reserved (forced to 0)
  Bit 8 (S):
  Bit 7: Reserved (forced to 0)
  Bit 6 (CI):
  Bit 5:Unused (forced to 0)
  Bit 4 (M):
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-8: Page Address
  Bits 7-0 (UNUSED): forced to 0

#### LONG-FORMAT PAGE DESCRIPTOR - 2*32-bit
HIGH:
  Bits 31-16: Unused (forced to 0)
  Bits 15-10: Reserved (forced to 1)
  Bit 9: Reserved (forced to 0)
  Bit 8 (S):
  Bit 7: Reserved (forced to 0)
  Bit 6 (CI):
  Bit 5:Unused (forced to 0)
  Bit 4 (M):
  Bit 3 (U):
  Bit 2 (WP):
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-8: Page Address
  Bits 7-0 (UNUSED): forced to 0

#### SHORT-FORMAT INVALID DESCRIPTOR - 32-bit
  Bits 31-2: Unused (forced to 0)
  Bits 1-0 (DT): Descriptor Type

#### LONG-FORMAT INVALID DESCRIPTOR - 2*32-bit
HIGH:
  Bits 31-2: Unused (forced to 0)
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-0: Unused (forced to 0)

#### SHORT-FORMAT INDIRECT DESCRIPTOR - 32-bit
  Bits 31-2 (DESCRIPTOR ADDRESS):
  Bits 1-0 (DT): Descriptor Type

#### LONG-FORMAT IDIRECT DESCRIPTOR - 2*32-bit
HIGH:
  Bits 31-2: Unused (forced to 0)
  Bits 1-0 (DT): Descriptor Type
LOW:
  Bits 31-2 (DESCRIPTOR ADDRESS):
  Bits 1-0 (UN):


#### TT0 - Transparent Translation Register 0 - 32-bit
##### MC68030 TTR format
**Register Select**: 0x3
```
Bits 31-24: Logical Address Base
Bits 23-16: Logical Address Mask
Bit 15 (E):  Enable
Bits 14-11: Reserved
Bits 10 (CI): Cache Inhibit
Bit 9 (RW):   Read/Write
Bit 8 (RWM):  Read/Write Mask
Bit 7:       Reserved (forced to 0)
Bits 6-4:    Function Code Base
Bit 3:       Reserved (forced to 0)
Bits 2-0:    Function Code Mask
```

#### TT1 - Transparent Translation Register 1 - 32-bit
**Register Select**: 0x4
```
Same format as TT0
```

#### MMUSR - MMU Status Register - 16-bit
**Register Select**: 0x5
```
Bit 15 (B):  Bus Error [READ-ONLY]
Bit 14 (L):  Limit Violation [READ-ONLY]
Bit 13 (S):  Supervisor-Only [READ-ONLY]
Bit 12:      Reserved (forced to 0)
Bit 11 (W): Write Protected [READ-ONLY]
Bit 10 (I):  Invalid [READ-ONLY]
Bit 9 (M):   Modified [WRITE-1-TO-CLEAR]
Bits 8-7:    Reserved (forced to 0)
Bit 6 (T):   Transparent Access [READ-ONLY]
Bits 5-3:    Reserved (forced to 0)
Bits 2-0 (N):    Number of Levels [READ-ONLY]
```

**Write Semantics**: Per MC68030 specification, MMUSR is mostly read-only. Only the Modified bit (9) supports write-1-to-clear operation. All other bits are updated by MMU hardware only.

#### CAL - Current Access Level - Not implemented in 68030
**Register Select**: 0x6
```
N/A
```

### PMMU Instruction Access
**Note**: PMMU registers (TC, TT0, TT1, MMUSR) attempted to be accessed via MOVEC
will trigger illegal instruction exceptions per MC68030 specification. Use PMOVE instead.

#### PMOVE Error Handling (Enhanced MC68030 Compliance)
- **Privilege Violation**: PMOVE instructions require supervisor mode (SVmode='1')
  - User mode attempts generate privilege violation exception (trap_priv)
- **Invalid Register**: Unsupported register selectors generate illegal instruction exception (trap_illegal)
- **Address Alignment**: Memory EA operations enforce proper alignment
  - 32-bit registers (TC, TT0, TT1, MMUSR): 4-byte alignment required
  - 64-bit registers (CRP, SRP): 8-byte alignment recommended
  - Misaligned access triggers address error exception
- **Reserved Bits**: Write operations to reserved register bits are masked or ignored

### Cache Control Instruction Integration
```verilog
// From TG68KdotC_Kernel.vhd lines 533-536:
  cache_cinv_req  <= '1' when (exec(cache_cinv) = '1' or 
                                CACR(2) = '1' or CACR(3) = '1' or CACR(10) = '1' or CACR(11) = '1') else '0';
  cache_cpush_req <= '1' when exec(cache_cpush) = '1' else '0';
```
### Coprocessor Primitives and their functions
```
**Processor Synchronization:
- Busy with Current Instruction
- Proceed with Next Instruction If No Trace
- Service Interrupts and Requery If Trace Enabled
- Proceed with Execution, Condition True/False
**Instruction Manipulation:
- Transfer Operation Word
- Transfer Words from Instruction Stream
**Exception Handling:
- Take Privilege Violation If S Bit Not Set
- Take Pre-Instruction Exception
- Take Mid-Instruction Exception
- Take Post-Instruction Exception
**General Operand Transfer:
- Evaluate and Pass (ea)
- Evaluate (ea) and Transfer Data
- Write to Previously Evaluated (ea)
- Take Address and Transfer Data
- Transfer to/from Top of Stack
**Register Transfer:
- Transfer CPU Register
- Transfer CPU Control Register
- Transfer Multiple CPU Registers
- Transfer Multiple Coprocessor Registers
- Transfer CPU SR and/or ScanPC
```
### MC68030 PFLUSH, PLOAD, PMOVE, PTEST Valid Addressing Modes
```
The following are supported for both source and destination:
(An) Mode:010 Register:An
(d16,An) Mode: 101 Register:An
(d8,An,Xn) Mode: 110 Register:An
(bd,An,Xn) Mode: 110 Register:An
([bd,An,Xn],od) Mode: 110 Register:An
([bd,An],Xn,od) Mode: 110 Register:An
xxx.W Mode: 111 Register:000
xxx.L Mode:111 Register:001
```
