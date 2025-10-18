# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **Minimig-AGA_MiSTer** - a port of the Minimig (Mini Amiga) core to the MiSTer FPGA platform. It implements a complete Amiga computer in hardware, emulating OCS/ECS/AGA chipsets with support for 68000 and 68020 CPUs. The project is written primarily in Verilog/VHDL for Intel/Altera FPGAs (Cyclone V) and targets Quartus 17.0.2.

## Build System

### Building the FPGA Core

The project uses Intel Quartus Prime for synthesis:

```bash
# Full synthesis and compilation (generates both SOF and RBF files)
quartus_sh --flow compile Minimig

# Alternative Q13 variant (for specific MiSTer builds)
quartus_sh --flow compile Minimig_Q13
```

**IMPORTANT Build Rules:**
- Always run full Quartus compilation to generate RBF files - NEVER manually convert SOF to RBF
- Old SOF files don't contain latest fixes, so always rebuild from source
- Keep track of build PIDs to avoid killing builds from other Quartus instances
- The build generates output in `output_files/` directory

### Testing with ModelSim

ModelSim is available at `/opt/intelFPGA_lite/17.0/modelsim_ase/linuxaloem/vsim`

**Test Guidelines (CRITICAL):**
- Run tests BEFORE building RBF files
- Test the ACTUAL implementation, not simplified/fake versions
- When testing hardware registers or features, use the real modules (e.g., TG68KdotC_Kernel, TG68K_PMMU_030)
- Verify register sizes match MC68030 specifications
- Check actual register select encodings from the code
- Don't create mock testbenches - test real hardware logic
- Example testbenches are in `rtl/fpga-toccata/sim/toccata/`

### File Management

- Project files: `Minimig.qpf`, `Minimig.qsf` (main project), `Minimig_Q13.qpf`, `Minimig_Q13.qsf` (Q13 variant)
- Source file list: `files.qip` - **DO NOT add files via Quartus GUI**, edit this file manually
- Build configuration: `sys/sys.tcl`, `sys/sys_analog.tcl`
- Timing constraints: `Minimig.sdc`

## Architecture

### High-Level Structure

The design follows the original Amiga architecture with MiSTer adaptations:

```
Minimig.sv (top module: emu)
├── hps_io (MiSTer HPS interface)
├── pll (clock generation: 28MHz, 114MHz)
├── cpu_wrapper (68K CPU interface and bus control)
│   ├── TG68K (68000/68020 CPU core in VHDL)
│   └── fx68k (alternative 68000 core)
├── minimig (Amiga chipset core)
│   ├── agnus (memory controller, DMA, blitter, copper)
│   ├── denise (video output, sprites, playfields)
│   ├── paula (audio, floppy, UART, interrupts)
│   ├── gary (address decoding)
│   └── gayle (IDE interface)
├── sdram_ctrl (ChipRAM/SlowRAM on SDRAM)
├── ddram_ctrl (FastRAM on DDR3)
├── fastchip (high-performance peripherals for 68020)
│   ├── rtg (RTG graphics for Picasso96)
│   └── ide (fast IDE controller)
└── sys/* (MiSTer framework)
```

### Key Modules

**CPU Subsystem:**
- `cpu_wrapper.v`: Bus interface between CPU cores and Amiga chipset, handles FastRAM/ChipRAM routing
- `rtl/tg68k/TG68KdotC_Kernel.vhd`: Main 68000/68020 CPU implementation
- `rtl/fx68k/fx68k.sv`: Alternative cycle-accurate 68000 core
- `cpu_cache_new.v`: CPU cache for 68020 mode

**Chipset (all in `rtl/`):**
- `minimig.v`: Main Amiga core top-level, connects all custom chips
- `agnus*.v`: Memory controller and DMA engines (bitplane, sprite, blitter, copper, audio, disk)
- `denise*.v`: Video generator (bitplanes, sprites, color table, HAM mode)
- `paula*.v`: Audio (4-channel), floppy controller, UART, interrupt controller
- `gary.v`: Address decoder for chipset
- `gayle.v`: IDE controller interface
- `ciaa.v`, `ciab.v`: CIA timer/IO chips

**Memory Controllers:**
- `sdram_ctrl.v`: SDRAM controller for ChipRAM (0-2MB) and SlowRAM (0-1.5MB)
- `ddram_ctrl.v`: DDR3 controller for FastRAM (0-384MB) via MiSTer DDR3

**MiSTer Integration:**
- `hps_ext.v`: Extended HPS interface for IDE and other peripherals
- `sys/sys_top.v`: MiSTer system framework wrapper
- Video processing: scandoubler, frame buffer support, RTG output

### Memory Architecture

- **ChipRAM** (0x000000-0x1FFFFF): Accessible by CPU and custom chips, on SDRAM
- **SlowRAM** (0xC00000-0xD7FFFF): Standard expansion, on SDRAM
- **FastRAM** (0x40000000+): 68020 only, on DDR3 via `ddram_ctrl`
- **Kickstart ROM**: Mirrored at 0xF80000-0xFFFFFF (bootrom mode) or 0xFC0000-0xFFFFFF
- **Custom chip registers**: 0xDFF000-0xDFFFFFF

### Clock Domains

- `clk_sys` (28.6875 MHz): Main Amiga clock domain
- `clk_114` (114.75 MHz): CPU and memory controller clock (4x Amiga clock)
- `CLK_VIDEO`: Video output clock
- `CLK_AUDIO` (24.576 MHz): Audio output clock
- Clock enables: `clk7_en`, `clk7n_en` for 7MHz peripherals

## Development Workflow

### Code Style Rules

**VHDL/Verilog Files (.vhd, .v, .sv):**
- No emojis or unicode characters in HDL source files
- No emojis in testbenches or test files
- Follow existing indentation and naming conventions

**Testing:**
- Always run tests before building final RBF
- Fix test failures properly - don't create simplified passing tests
- ModelSim library issues are usually due to improper fixes, not persistent problems
- Test against actual hardware specifications (e.g., MC68030 User's Manual for CPU features)

### Common Tasks

**Adding New HDL Files:**
1. Place file in appropriate `rtl/` subdirectory
2. Manually add to `files.qip` or relevant `.qip` file
3. Never use Quartus GUI to add files (it corrupts project structure)

**Modifying CPU Core:**
- Main CPU kernel: `rtl/tg68k/TG68KdotC_Kernel.vhd` (VHDL)
- CPU wrapper/bus interface: `rtl/cpu_wrapper.v`
- Cache: `rtl/cpu_cache_new.v`
- For CPU changes, verify against 68000/68020/68030 programmer's reference manuals

**Modifying Chipset:**
- Agnus (DMA): `rtl/agnus*.v` files
- Denise (video): `rtl/denise*.v` files
- Paula (audio/floppy): `rtl/paula*.v` files
- Refer to Amiga Hardware Reference Manual for register specifications

**Creating Testbenches:**
- Place in appropriate module directory under `sim/` or `testbench/`
- Use SystemVerilog for new testbenches (see `rtl/fpga-toccata/sim/toccata/` for examples)
- Instantiate actual modules being tested, not simplified versions
- Include timeout safety: `#N $fatal(1, "Simulation timeout")`

## Important Notes

### Known Issues (from TODO)
- AGA bitplane shifter has edge cases with high-res scrolling
- Sprite positioning at 35ns resolution needs verification
- CPU compatibility ongoing - some instruction edge cases and stack frames
- Blitter may need reimplementation for better compatibility

### Git Workflow
- Main development branch: `MiSTer`
- Recent commits show CIA timer fixes and specification documentation improvements

### External Dependencies
- Quartus 17.0.2 Standard Edition at `/opt/intelFPGA_lite/17.0/quartus/`
- ModelSim ASE at `/opt/intelFPGA_lite/17.0/modelsim_ase/`
- MiSTer framework in `sys/` subdirectory

### Reference Documentation
- Amiga Hardware Reference Manual (for custom chip registers)
- MC68000/68020/68030 User's Manual (for CPU instruction set)
- MiSTer FPGA Wiki (for platform-specific features)

## Feature Support

**Implemented:**
- OCS/ECS/AGA chipset variants
- 68000 and 68020 CPU cores
- 0.5MB-2MB ChipRAM, 0-1.5MB SlowRAM, 0-384MB FastRAM
- 1-4 floppy drives with turbo mode
- Up to 4 IDE devices, CDROM support
- RTG graphics (Picasso96)
- Serial/shared folder/MIDI support
- Akiko (CD32 chunky-to-planar)

**In Progress:**
- Full AGA compatibility edge cases
- CPU instruction compatibility
- CD32 gamepad emulation
