# TG68K030 - MC68030 Processor Core

This directory contains the MC68030 processor implementation based on the TG68K core.

## Overview

The TG68K030 is an FPGA implementation of the Motorola MC68030 32-bit microprocessor, designed to replace the 68020 mode in the Minimig-AGA MiSTer core.

## Architecture

The MC68030 adds several key features over the MC68020:

- **On-chip MMU**: Memory Management Unit with Address Translation Cache (ATC)
- **On-chip Caches**: 256-byte instruction cache and 256-byte data cache
- **New Instructions**: PFLUSH, PTEST, PMOVE for MMU control
- **Enhanced Bus**: Burst mode support and dynamic bus sizing

## Files

### Core Files (To be created)
- `TG68K030_Kernel.vhd` - Main processor kernel (based on TG68KdotC_Kernel)
- `TG68K030_MMU.vhd` - Memory Management Unit
- `TG68K030_ICache.vhd` - Instruction cache
- `TG68K030_DCache.vhd` - Data cache
- `TG68K030_ATC.vhd` - Address Translation Cache
- `TG68K030_Pack.vhd` - Package definitions and constants

### Support Files
- `TG68K030.qip` - Quartus IP project file
- Build and compilation scripts

## Development Status

Current phase: **Phase 1 - Project Setup**

### Completed
- ✅ Directory structure created
- ✅ Implementation plan documented
- ✅ Architecture analysis

### In Progress
- 🔄 Documentation framework
- 🔄 Verification framework

### Planned
- ⏳ Register implementation (Phase 2)
- ⏳ MMU instructions (Phase 3)
- ⏳ Cache implementation (Phase 4)
- ⏳ MMU logic (Phase 5)
- ⏳ Bus enhancements (Phase 6)
- ⏳ System integration (Phase 7)

## Usage

The TG68K030 will be instantiated in `cpu_wrapper.v` when cpucfg is set to 68020 mode:

```verilog
TG68K030_Kernel #(
    .sr_read(2),
    .vbr_stackframe(2),
    .extaddr_mode(2),
    .mul_mode(2),
    .div_mode(2),
    .bitfield(2),
    .mmu_enable(2),        // New: MMU support
    .cache_enable(2)       // New: Cache support
) cpu_inst_030
(
    .clk(clk),
    .nreset(reset),
    // ... standard 68K signals ...
    // New MC68030 signals will be added
);
```

## Configuration Options

The implementation supports configurable features via VHDL generics:

- `mmu_enable`: 0=no MMU, 1=full MMU, 2=switchable
- `cache_enable`: 0=no cache, 1=caches enabled, 2=switchable
- `burst_mode`: 0=no burst, 1=burst enabled, 2=switchable

## Testing

See `/tests/mc68030/` for testbenches and verification scripts.

## Documentation

Detailed documentation is available in `/docs/mc68030/`:
- Implementation plan
- Register specifications
- Instruction details
- Cache and MMU design documents

## References

- MC68030 User's Manual (Motorola/NXP)
- TG68K source code (base implementation)
- Amiga Hardware Reference Manual

## License

This implementation maintains the GNU Lesser General Public License v3 from the original TG68K core.

## Contributors

- Original TG68K: Tobias Gubener
- MC68030 Implementation: [Your contributions here]

