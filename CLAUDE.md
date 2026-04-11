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
make test-moves-validation   # MOVES validation testbench
make test-moves-all-modes    # MOVES with all addressing modes
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

### Test Directory Structure
- `tests/tg68k_030/` - Main test directory with primary testbenches (`tb_*.vhd`)
- `tests/tg68k_030/mock/` - Bug-specific and exploratory testbenches (older, may need updates)

## Code Architecture

### Top-Level Structure
- `Minimig.sv`: MiSTer framework integration layer
- `rtl/minimig.v`: Core Amiga implementation entry point
- `sys/sys_top.v`: MiSTer system-specific hardware interface

### CPU Subsystem (68030 Focus)
- `rtl/tg68k/TG68KdotC_Kernel.vhd`: Main CPU core (~6900 lines) with PMMU and cache control
- `rtl/tg68k/TG68K_PMMU_030.vhd`: Complete MC68030-compatible PMMU (~3200 lines)
- `rtl/tg68k/TG68K_Cache_030.vhd`: 256-byte instruction and data caches
- `rtl/tg68k/TG68K_ALU.vhd`: Arithmetic/Logic Unit (used by Kernel for all ALU operations)
- `rtl/tg68k/TG68K_Pack.vhd`: Package definitions, constants, `micro_states` enum, `exec`/`set` bit indices
- `rtl/cpu_wrapper.v`: CPU integration wrapper (USE_68030_CACHE=1)

**VHDL Compilation Order** (dependency chain - must compile in this order):
`TG68K_Pack.vhd` -> `TG68K_ALU.vhd` -> `TG68K_PMMU_030.vhd` -> `TG68K_Cache_030.vhd` -> `TG68KdotC_Kernel.vhd` -> testbenches

### TG68KdotC_Kernel Architecture
The Kernel is organized as ~17 concurrent PROCESS blocks. The most important ones:
- **Main state machine process** (~line 2046): Clocked process containing `CASE state`, `CASE micro_state`, instruction decode (`decodeOPC`), and `setopcode`/`setexecOPC` phases. This is where most instruction behavior is defined.
- **Instruction decode combinational** (~line 2640): Large combinational process handling opcode decoding, setting `setstate`, `setexec`, `next_micro_state` based on current opcode/state.
- **Register file process** (~line 1292): Register read/write multiplexing.
- **Data path processes** (~lines 1344, 1404, 1469): Write-back destination selection (`RDindex_A`), source register selection (`RDindex_B`).
- **Address calculation** (~line 1740): EA displacement and brief extension word address computation.

### Key Signals
- `state` - main 2-bit state machine ("00"=idle/decode, "01"=execute, "10"=memory addr, "11"=memory data)
- `micro_state` - sub-state enum (idle, nop, ld_nn, st_nn, pmove_decode, pmove_mem_to_mmu_hi/lo, etc.)
- `exec` / `set` - execution flags vectors (bit indices defined as constants in TG68K_Pack.vhd)
- `setstate` / `setexec` - next state/exec assignments (combinational, latched on `clkena_lw`)
- `opcode` - current instruction word (latched from `last_opc_read` at `setopcode` time)
- `last_opc_read` - most recent word fetched from instruction stream
- `brief` - extension word (latched from `last_opc_read` during getbrief)
- `memmask` - memory operation type mask
- `clkena_lw` - main clock enable (gated by wait states)
- `clkena_in` - external clock enable input

### Memory and Cache Integration
- Cache fill state machine in `Minimig.sv` handles 8-word sequential reads
- PMMU walker memory arbiter manages bus access between CPU, cache, and page table walks
- Cache-inhibit signals from PMMU properly connected and honored

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

### PMOVE Instruction
PMOVE transfers data between memory/registers and PMMU registers. All PMMU instructions share the F-line opcode space (`F0xx`), differentiated by the extension word.

**Opcode**: `1111 0000 00EE EAAA` where EEE=EA mode, AAA=EA register
**Extension word** (bits 15-13 dispatch instruction type):
```
Bits 15-13: Instruction type
              000 = PMOVE/PMOVEFD (TT0/TT1)
              001 = PFLUSH (12:10=001) / PLOAD (12:10=000)
              010 = PMOVE/PMOVEFD (TC/SRP/CRP)
              011 = PMOVE (MMUSR)
              100 = PTEST
Bits 14-10: P-register selector
              00010=TT0, 00011=TT1, 10000=TC, 10010=SRP, 10011=CRP, 11000=MMUSR
Bit 9:      Direction (RW): 0=write to MMU (EA->MMU), 1=read from MMU (MMU->EA)
Bit 8:      FD (flush disable) - PMOVEFD variant when set
```

**Two execution paths**:

1. **Dn mode** (`opcode(5:3)="000"`): Register-to-register transfer, no memory access
   - Write to MMU (`brief(9)=0`): `set_exec(pmmu_wr)`, micro -> `idle` (32-bit) or `pmove_dn_hi` (64-bit CRP/SRP)
   - Read from MMU (`brief(9)=1`): `set(pmmu_rd)`, micro -> `pmmu_dn_read_wait` (32-bit) or `pmove_dn_hi` (64-bit)

2. **Memory EA modes**: Uses EA builder, then PMOVE-specific micro-states
   - Write to MMU (`brief(9)=0`): EA build -> `pmove_mem_to_mmu_hi` (-> `pmove_mem_to_mmu_lo` for 64-bit)
   - Read from MMU (`brief(9)=1`): EA build -> `pmove_mmu_to_mem_hi` (-> `pmove_mmu_to_mem_lo` for 64-bit)
   - EA routing: simple modes (An)/(An)+/-(An) go direct; (d16,An) -> `ld_dAn1`; (d8,An,Xn) -> `ld_AnXn1`; absolute -> `ld_nn`

**Key implementation details**:
- Uses `pmmu_brief` (latched copy of `brief`) for stable values throughout F-line execution
- Uses `fline_opcode_latch` instead of `opcode` for EA mode checks (opcode may be prefetched ahead)
- Register selector must be latched at proper clock phase to avoid races
- MMUSR uses `datatype="01"` (word/16-bit); all others use `datatype="10"` (long/32-bit)
- 64-bit registers (CRP/SRP) require two bus cycles with `reg_part` tracking high/low word
- `set(longaktion)` required for 32-bit memory transfers (not MMUSR)
- `set(presub)`/`set(pmmu_dbl)` needed for -(An) mode with 64-bit registers

**Legal EA modes**: Dn, (An), (An)+, -(An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L
**Illegal EA modes**: An, PC-relative, immediate (triggers F-line exception)
**Privilege**: Supervisor-only; user mode triggers privilege violation

### MOVES Instruction
MOVES (Move Address Space) transfers data between a general register and a memory location using SFC/DFC function codes instead of the normal FC. Supervisor-only instruction.

**Extension word format** (second word after opcode `0x0E__`):
```
Bit 15:     D/A (0=data register, 1=address register)
Bits 14-12: Register number (0-7)
Bit 11:     Direction (0=EA->Rn read using SFC, 1=Rn->EA write using DFC)
Bits 10-0:  Reserved (zeros)
```

**Micro-states**: `moves0` (address setup, latches extension word fields) -> `moves1` (bus access with FC override)

**Key latched signals** (latched in `moves0` because `brief` gets overwritten by EA extension words):
- `moves_direction` - from `brief(11)`: selects SFC (read) vs DFC (write)
- `moves_reg` - from `brief(15:12)`: D/A flag + register number
- `moves_bus_pending` - stays active during bus cycle to maintain FC override
- `moves_writeback_pending` - defers register write for mem->CPU until bus data available
- `moves_ea_areg`, `moves_ea_regnum` - latched EA register info for address calculation

**FC override** (~line 878): When `micro_state=moves1` or `moves_bus_pending='1'`, the FC output is driven from SFC (reads) or DFC (writes) instead of the normal `fc_internal`.

**Addressing modes**: Same as PMOVE - all memory alterable modes. Illegal: An direct, PC-relative, immediate.

### Exceptions, Traps, and RTE

#### Exception Priority
At instruction boundary (`setinterrupt` time), exception sources are dispatched in priority order:
1. **Trace** (`make_trace='1'`) - highest priority, sets `trap_trace`
2. **Bus Error** (`make_berr='1'`) - sets `trap_berr` (vector 2) or `trap_mmu_berr` (vector 61)
3. **External Interrupt** - lowest of the three, sets `trap_interrupt` with `IPL_vec`

Bus error always takes precedence over pending interrupts, ensuring the correct Format $A frame is pushed instead of a Format $0 interrupt frame.

#### Bus Error Exception (Format $A)
MC68030 mode (`cpu(1)='1'`) generates a Format $A (Short Bus Fault, 16-word/32-byte) stack frame via `berr1`..`berr8` micro-states (~line 5355). Each state pushes one longword onto the supervisor stack using pre-decrement:

| State | Stack Offset | Data Pushed | Source |
|-------|-------------|-------------|--------|
| berr1 | $1C-$1F | Internal registers (stub) | `0x00000000` |
| berr2 | $18-$1B | Data output buffer | `data_write_tmp` |
| berr3 | $14-$17 | Internal registers (stub) | `0x00000000` |
| berr4 | $10-$13 | Fault address | `addr` (CPU address at fault time) |
| berr5 | $0C-$0F | Instruction pipeline | `opcode & last_opc_read(15:0)` |
| berr6 | $08-$0B | SSW + internal (stub) | `0x00000000` (SSW not yet implemented) |
| berr7 | $04-$07 | PC Lo + Format/Vector | `TG68_PC(15:0) & "1010" & trap_vector(11:0)` |
| berr8 | $00-$03 | SR + PC Hi | `(trap_SR & Flags) & TG68_PC(31:16)` |

After berr8, `set_vectoraddr`/`set(directPC)` loads the exception handler address from the vector table.

**MMU bus error**: When PMMU detects a fault with the B-bit set (`pmmu_fault_stat(15)='1'`), `trap_mmu_berr` is set instead of `trap_berr`, routing to vector 61 ($F4) instead of vector 2 ($08). Both use the same Format $A frame.

**Key signals**: `trap_berr`, `trap_mmu_berr`, `make_berr`, `make_mmu_berr`, `trap_vector`, `clr_berr`

#### RTE (Return from Exception)
RTE (~line 3897) pops exception stack frames with format-dependent unwinding:

**Micro-states**: `rte1` (read PC longword) -> `rte2` (read SR word + initiate format word read) -> `rte3` (wait for format word, capture into `rte_format_word`) -> `rte4` (decode format, set up unwind) -> `rte5` (loop to discard remaining words)

**Format decoding** in rte4 (~line 5465) via `rte_format_word(15 downto 12)`:

| Format | Frame Size | Extra Reads in rte5 | Use Case |
|--------|-----------|---------------------|----------|
| $0 | 4 words (8 bytes) | none | Most exceptions |
| $1 | 4 words (8 bytes) | none | Throwaway (interrupt return) |
| $2 | 6 words (12 bytes) | 1 longword (`rot_cnt=1`) | CHK, TRAPV, Trace, Div0, MMU config |
| $9 | 10 words (20 bytes) | 3 longwords (`rot_cnt=3`) | Coprocessor mid-instruction |
| $A | 16 words (32 bytes) | 6 longwords (`rot_cnt=6`) | Short bus fault |
| $B | 46 words (92 bytes) | 21 longwords (`rot_cnt=21`) | Long bus fault |
| Other | - | - | Format Error exception (vector 14) |

The `rte5` state loops, reading and discarding one longword per iteration while decrementing `rot_cnt`, until `rot_cnt` reaches 1.

**Key signals**: `rte_format_word` (latched format/vector word), `rot_cnt` (remaining longwords to discard), `trap_format_error` (invalid format detection)

#### Exception Trap Signals
| Signal | Vector | Trigger |
|--------|--------|---------|
| `trap_berr` | 2 ($08) | External BERR or PMMU fault (non-MMU) |
| `trap_mmu_berr` | 61 ($F4) | PMMU fault with B-bit set |
| `trap_addr_error` | 3 ($0C) | Misaligned memory access |
| `trap_illegal` | 4 ($10) | Illegal/undefined opcode |
| `trap_priv` | 8 ($20) | Supervisor instruction in user mode |
| `trap_trace` | 9 ($24) | Trace mode single-step |
| `trap_1010` | 10 ($28) | A-line emulator |
| `trap_1111` | 11 ($2C) | F-line emulator |
| `trap_format_error` | 14 ($38) | Invalid RTE stack frame format |
| `trap_mmu_config` | 56 ($E0) | Invalid TC page size |
| `trap_interrupt` | 24-31 | External interrupt (IPL level) |
| `trap_trap` | 32-47 | TRAP #n instruction |

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

See [TG68K_REGISTERS.md](TG68K_REGISTERS.md) for detailed specifications of all control registers, PMMU registers, page descriptor formats, and PMOVE addressing modes.

Key quick facts:
- PMOVE uses `pmmu_brief(14:10)` (5 bits) for P-register selection, dispatched by `brief(15:13)`:
  - `"000"` group: TT0=`"00010"`, TT1=`"00011"`
  - `"010"` group: TC=`"10000"`, SRP=`"10010"`, CRP=`"10011"`
  - `"011"` group: MMUSR=`"11000"`
- Register sizes: TC/TT0/TT1=32-bit, CRP/SRP=64-bit, MMUSR=16-bit
- PMOVE addressing: Control Alterable modes only (no PC-relative, no immediate, no An direct)
- PMOVE works like MOVE but with MMU registers - same EA calculation, memory timing, and bus cycles
