# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Minimig-AGA_MiSTer project - an FPGA implementation of the Amiga computer for the MiSTer platform. It emulates Amiga OCS, ECS, and AGA chipsets with support for 68000, 68010, 68020, and 68030 CPUs.

**Active Development**: The `030_mmu` branch contains ongoing 68030 CPU implementation with full PMMU and cache support. The `MiSTer` branch is the main/stable branch.

## Critical Rules

### Coding Guidelines
- Do NOT use emojis in tests, testbenches, .vhd, or .v files
- Do NOT use unicode characters in VHDL/Verilog code
- Do NOT create simplified/fake tests - test the ACTUAL implementation
- Do NOT create separate .md files for documentation - keep notes minimal
- Tests and testbenches belong in `tests/` folder, not in the project root

### Testing Requirements
- Run regression tests BEFORE building RBF - do it right the first time
- Use the actual TG68KdotC_Kernel and TG68K_PMMU_030 modules, not mock versions
- Verify register sizes match MC68030 spec (e.g., MMUSR is 16-bit, not 32-bit)
- Read the actual implementation before making assumptions
- Fix broken tests properly - do not hide issues with simpler tests

### Build Management
- Keep track of build PIDs - don't pkill builds from other instances
- Check if a process exists with `ps` before attempting to kill it
- NEVER manually convert SOF to RBF - always run full Quartus compile
- Check for multiple driver issues before starting a build (see Pre-Build Checks below)

### Git and Code Safety
- **ALWAYS ask permission** before running `git checkout`, `git revert`, or any destructive git command
- Use `git diff` or `git show` to review changes before suggesting reversions
- Create backups of modified files before making significant changes: `cp file.vhd file.vhd.backup`
- If reverting a fix, explain why and get explicit approval first
- Use `git stash` to safely preserve work-in-progress changes

### Pre-Build Checks
```bash
# Check for multiple driver issues in VHDL before building
grep -n "multiple drivers" output_files/*.rpt 2>/dev/null || echo "No previous build"

# Syntax check without full build
cd tests/tg68k_030 && make syntax-check

# Check that the build PID file matches a running process
cat .current_build_pid 2>/dev/null && ps -p $(cat .current_build_pid) || echo "No active build"
```

## Development Commands

### Building the Core
```bash
# Full compilation (outputs to output_files/Minimig.rbf and Minimig.sof)
/opt/intelFPGA_lite/17.0/quartus/bin/quartus_sh --flow compile Minimig

# Background build with logging
nohup /opt/intelFPGA_lite/17.0/quartus/bin/quartus_sh --flow compile Minimig > build.log 2>&1 &
echo $! > .current_build_pid  # Track PID to avoid killing other instances

# Check build progress
tail -f build.log

# Clean build artifacts
rm -rf db/ incremental_db/ output_files/ simulation/ greybox_tmp/
```

### Running Tests
```bash
cd tests/tg68k_030/

# See all available test targets
make help

# Recommended: Run regression tests first
make test-regression     # MC68030 compliance tests
make validate            # Full compliance validation with pass/fail summary

# Component-specific tests
make test-pmmu           # PMMU functionality
make test-cache          # Cache operations
make test-cacr           # CACR register
make test-pmove-tc       # PMOVE TC operations
make test-diagnostic     # PMMU diagnostic tests (quick sanity check)
make test-moves          # MOVES instruction FC handling
make test-rte-formats    # RTE stack frame formats (0,1,2,9,A,B)
make test-mmu-instruction-suite  # Complete MMU instruction test suite

# Run all comprehensive tests
make test-comprehensive  # ALL enhanced tests including advanced/fault/stress

# Interactive debugging with waveforms
make test-gui            # Opens ModelSim GUI for step-through debugging

# Direct ModelSim commands
/opt/intelFPGA_lite/17.0/modelsim_ase/linuxaloem/vcom -93 <file.vhd>
/opt/intelFPGA_lite/17.0/modelsim_ase/linuxaloem/vsim -c -do "run -all; quit" <testbench>

# Run a single specific testbench manually
cd tests/tg68k_030 && make setup
vsim -c -do "run 50us; quit" tb_<testbench_name>
```

## Code Architecture

### Top-Level Structure
- `Minimig.sv`: MiSTer framework integration layer
- `rtl/minimig.v`: Core Amiga implementation entry point
- `sys/sys_top.v`: MiSTer system-specific hardware interface

### CPU Subsystem (68030 Focus)
- `rtl/tg68k/TG68KdotC_Kernel.vhd`: Main CPU core (~9000 lines) with PMMU and cache control
- `rtl/tg68k/TG68K_PMMU_030.vhd`: Complete MC68030-compatible PMMU (~4000 lines)
- `rtl/tg68k/TG68K_Cache_030.vhd`: 256-byte instruction and data caches
- `rtl/tg68k/TG68K_Pack.vhd`: Package definitions and constants
- `rtl/cpu_wrapper.v`: CPU integration wrapper (USE_68030_CACHE=1)

### TG68KdotC_Kernel Key Signals
- `state` - main state machine (idle, addr, data, etc.)
- `exec` - instruction execution flags vector
- `setstate` / `setexec` - next state/exec assignments (combinational)
- `opcode` / `last_opc_read` - current instruction word
- `brief` / `last_opc_read` - extension word handling
- `memmask` - memory operation type mask
- `clkena_lw` - main clock enable (gated by wait states)
- `clkena_in` - external clock enable input

### Memory and Cache Integration
- Cache fill state machine in `Minimig.sv` handles 8-word sequential reads
- PMMU walker memory arbiter manages bus access between CPU, cache, and page table walks
- Cache-inhibit signals from PMMU properly connected and honored

### Amiga Chipset (for reference)
- `rtl/agnus*.v`: Graphics DMA (bitplane, sprite, blitter, copper)
- `rtl/denise*.v`: Video output and rendering
- `rtl/paula*.v`: Audio and I/O (4-channel audio, UART, floppy, interrupts)
- `rtl/ciaa.v`, `rtl/ciab.v`: Complex Interface Adapters
- `rtl/gary.v`, `rtl/gayle.v`: Memory controller and IDE interface

## 68030 Implementation

### Key Features
- CPU="11" encoding for 68030 mode
- Full PMMU: PMOVE, PTEST, PFLUSH, PLOAD instructions
- PMMU Registers: TC, CRP, SRP, TT0, TT1, MMUSR with proper read/write
- Multi-level page table walking (W_ROOT->W_PTR1->W_PTR2->W_PTR3->W_PAGE)
- 8-entry Address Translation Cache (ATC)
- Transparent Translation Registers (TT0/TT1)
- CACR with self-clearing bits: EI(0), FI(1), CEI(2), CI(3), IBE(4), ED(8), FD(9), CED(10), CD(11), DBE(12), WA(13)
- Cache: 256-byte I-cache + D-cache (direct-mapped, 16 lines x 16 bytes, PIPT)
- Burst mode when CACR IBE/DBE bits enabled
- MMU exception handling for invalid descriptors, write protection, privilege violations

### PMMU State Machine
The page walker uses states defined in TG68K_PMMU_030.vhd:
- `W_IDLE` - waiting for translation request
- `W_ROOT` - reading root pointer from CRP/SRP
- `W_PTR1..W_PTR3` - reading table descriptors
- `W_PAGE` - final page descriptor lookup
- `W_DONE` - translation complete, result in ATC

### Critical Implementation Notes
- PMOVE uses `brief(11:8)` for register selection (not opcode bits)
- Register selector must be latched at proper clock phase to avoid races
- Memory-to-MMU vs MMU-to-memory paths have different timing requirements
- 64-bit registers (CRP/SRP) require two bus cycles with `reg_part` tracking high/low word

### Specifications
- MC68030 User Manual: `/home/adam/Desktop/MC68030UM.pdf` (primary reference for PMMU, cache, instruction timing)
- Online Reference: `https://amigasourcecodepreservation.gitlab.io/mc680x0-reference/`

## Development Workflow

1. Make changes to RTL files in `rtl/` directory
2. Run ModelSim tests: `cd tests/tg68k_030 && make test-regression`
3. Check for multiple driver issues in VHDL
4. Build using Quartus: `quartus_sh --flow compile Minimig`
5. Test generated RBF file on MiSTer hardware
6. Verify functionality with Amiga software

## Common Debugging Patterns

### Signal Timing Issues
When debugging PMMU or cache timing issues, check these signals in order:
1. `clkena_lw` / `clkena_in` - clock enable gating
2. `setstate` / `setexec` - state machine transitions
3. `state` / `exec` - current execution state
4. `memmask` - memory operation mask

### VHDL Signal Assignment Debugging
```bash
# Check for multiple drivers (causes synthesis failure)
grep -n "multiple drivers" output_files/*.rpt

# Find all assignments to a signal
grep -n "signal_name\s*<=" rtl/tg68k/TG68KdotC_Kernel.vhd

# Check signal sensitivity lists
grep -B5 "process" rtl/tg68k/TG68KdotC_Kernel.vhd | grep -A5 "signal_name"
```

### When Tests Pass But Hardware Fails
- Check if test uses actual clock enable conditions (`clkena_lw`, `clkena_in`)
- Verify test simulates proper memory wait states
- Ensure test exercises the exact instruction sequence from hardware
- Check FC (function code) values match expected user/supervisor mode

## TG68K Register Reference

See [TG68K_REGISTERS.md](TG68K_REGISTERS.md) for detailed specifications:
- Control Registers (CACR, VBR, SFC, DFC, CAAR, USP, MSP, ISP)
- PMMU Registers (TC, CRP, SRP, TT0, TT1, MMUSR)
- Page descriptor formats (short/long format table, page, invalid, indirect)
- PMOVE addressing modes (Control Alterable only - no PC-relative or immediate)

### Understanding PMOVE Instructions
PMOVE instructions work like MOVE but with MMU registers. Think of them as equivalent:
```
PMOVE TC,(A7)      ~  MOVE.L D0,(A7)      ; Write 32-bit TC to memory at A7
PMOVE (A7),TC      ~  MOVE.L (A7),D0      ; Read 32-bit from memory to TC
PMOVE CRP,(A7)     ~  two MOVE.L ops      ; Write 64-bit CRP to memory (two longwords)
PMOVE TT0,(d16,A5) ~  MOVE.L D0,(d16,A5)  ; Write 32-bit TT0 with displacement
PMOVE MMUSR,(A7)   ~  MOVE.W D0,(A7)      ; Write 16-bit MMUSR to memory
```
The EA calculation, memory access timing, and addressing modes follow the same patterns as MOVE.
