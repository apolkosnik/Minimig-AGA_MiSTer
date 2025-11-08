# TG68K 32-Bit Implementation Status

## Summary

I've analyzed the `32bit_wide` branch and begun recreating a similar 32-bit wide architecture from master, using the TG68K CPU instead of WF68K30L. The initial infrastructure has been committed to branch `claude/recreate-32bit-wide-011CUutRanFkxP8Pncv6SQZk`.

## What Was Completed

### ✅ Phase 1: Core Infrastructure (DONE)

1. **Configuration System**
   - Created `rtl/minimig_config.vh` with `MINIMIG_TG68K_32BIT` define
   - Defined data width and byte enable constants
   - Enables conditional compilation for 32-bit mode

2. **TG68K 32-Bit Wrapper**
   - Created `rtl/tg68k/TG68K_32bit_wrapper.vhd`
   - Wraps the existing 16-bit TG68K core with 32-bit interface
   - Key features:
     - 32-bit data_in/data_write ports
     - 4 byte enables (nBE[3:0]) active-low
     - Intelligent data routing based on address and transfer size
     - Handles aligned/misaligned accesses
     - Leverages TG68K's existing longword support

3. **Build Integration**
   - Updated `rtl/tg68k/TG68K.qip` to include the new wrapper
   - Wrapper will be compiled with the rest of TG68K files

4. **Documentation**
   - Created comprehensive `TG68K_32BIT_IMPLEMENTATION_PLAN.md`
   - Detailed architecture comparison with 32bit_wide branch
   - Component-by-component modification plan
   - Testing strategy and compatibility notes

## What Remains To Be Done

### Phase 2: CPU Integration Layer (TODO)

**File: `rtl/cpu_wrapper.v`**
- Expand `cpucfg` from [1:0] to [2:0] to support 32-bit mode (value 3'b100)
- Widen data buses:
  - `chip_addr`: [23:1] → [31:1]
  - `chip_din/chip_dout`: [15:0] → [31:0]
  - `ramdin/ramdout`: [15:0] → [31:0]
- Add `chip_be[3:0]` for byte enables
- Instantiate `TG68K_32bit_wrapper` when in 32-bit mode
- Route 32-bit data through the CPU wrapper

### Phase 3: Bridge Layer (TODO)

**File: `rtl/minimig_m68k_bridge.v`**
- Widen address bus: [23:1] → [31:1]
- Widen data buses: [15:0] → [31:0]
- Add `_be[3:0]` input for byte enables
- Generate 4 independent byte write strobes:
  - `byte3_wr` (bits 31:24)
  - `byte2_wr` (bits 23:16)
  - `byte1_wr` (bits 15:8)
  - `byte0_wr` (bits 7:0)
- Update host interface to 32-bit
- Maintain backward compatibility with 16-bit custom chips

### Phase 4: Top-Level Integration (TODO)

**File: `rtl/minimig.v`**
- Include `minimig_config.vh`
- Widen CPU data paths:
  - `cpu_data_in`: [15:0] → [31:0]
  - `cpu_data_out`: [15:0] → [31:0]
  - `ram_data_in`: [15:0] → [31:0]
  - `ram_data_out`: [15:0] → [31:0]
- Keep custom chip interfaces at 16-bit (no change)
- Update gary multiplexer for 32-bit CPU data
- Add conditional compilation based on `MINIMIG_TG68K_32BIT`

### Phase 5: Memory Controllers (TODO)

**Files: `rtl/sdram_ctrl.v`, `rtl/ddram_ctrl.v`**
- Widen CPU data interface to 32-bit
- Add 4-byte enable support
- Keep chipset interface at 16-bit
- Optimize for 32-bit aligned burst transfers
- Handle byte enables for partial writes

### Phase 6: Testing & Validation (TODO)
- Syntax check all modified files
- Build RTL
- Functional simulation
- FPGA build and testing
- Benchmark comparison with 32bit_wide branch

## Technical Architecture

### The Wrapper Approach

Instead of modifying the 4000+ line TG68KdotC_Kernel directly (risky and error-prone), I created a wrapper that:

1. **Accepts 32-bit external interface** while keeping TG68K's proven 16-bit internals
2. **Generates byte enables** from TG68K's UDS/LDS + longword signals
3. **Routes data intelligently:**
   - Aligned 32-bit: Uses address bit 1 to select which 16-bit half to access first
   - Word accesses: Routes to correct 16-bit half based on address[1]
   - Byte accesses: Routes to correct byte based on address[1:0]

### Byte Enable Encoding

```
For 32-bit aligned longword (addr[1:0] = 00):
  nBE = 4'b0000 (all bytes enabled)

For word at upper address (addr[1] = 0):
  nBE = 4'b0011 (bits 31:16)

For word at lower address (addr[1] = 1):
  nBE = 4'b1100 (bits 15:0)

For bytes:
  addr[1:0] = 00: nBE = 4'b0001 (byte 0, bits 7:0)
  addr[1:0] = 01: nBE = 4'b0010 (byte 1, bits 15:8)
  addr[1:0] = 10: nBE = 4'b0100 (byte 2, bits 23:16)
  addr[1:0] = 11: nBE = 4'b1000 (byte 3, bits 31:24)
```

## Key Differences from 32bit_wide Branch

| Aspect | 32bit_wide (WF68K30L) | Our Approach (TG68K 32-bit) |
|--------|----------------------|----------------------------|
| CPU Core | WF68K30L (native 32-bit) | TG68K (16-bit with wrapper) |
| Data Path | Fully 32-bit internal | 32-bit external, 16-bit internal |
| Complexity | Removed TG68K entirely | Keeps TG68K, adds wrapper |
| Compatibility | WF68K30L only | All existing TG68K modes + 32-bit |
| Performance | Best (native 32-bit) | Good (wrapper overhead minimal) |

## Benefits of This Approach

1. **Proven TG68K Core**: Keeps the stable, well-tested TG68K kernel unchanged
2. **Incremental Migration**: Can develop/test wrapper independently
3. **Backward Compatible**: All existing 16-bit modes still work
4. **Lower Risk**: Wrapper bugs don't affect core CPU logic
5. **Maintainable**: Clear separation between 16-bit core and 32-bit interface

## Next Steps

To complete the implementation:

1. Modify `cpu_wrapper.v` to integrate the 32-bit wrapper
2. Update `minimig_m68k_bridge.v` for 32-bit + byte enables
3. Widen `minimig.v` data paths with conditional compilation
4. Update memory controllers for 32-bit support
5. Build and test the complete system

## Files Modified So Far

```
✅ rtl/minimig_config.vh (NEW)
✅ rtl/tg68k/TG68K_32bit_wrapper.vhd (NEW)
✅ rtl/tg68k/TG68K.qip (MODIFIED)
✅ TG68K_32BIT_IMPLEMENTATION_PLAN.md (NEW)
✅ IMPLEMENTATION_STATUS.md (NEW)
```

## Estimated Remaining Work

- **Phase 2 (CPU Integration)**: ~2-3 hours
- **Phase 3 (Bridge Layer)**: ~1-2 hours
- **Phase 4 (Top-Level)**: ~2-3 hours
- **Phase 5 (Memory Controllers)**: ~3-4 hours
- **Phase 6 (Testing)**: ~4-6 hours
- **Total**: ~12-18 hours of focused development work

## References

- Branch: `claude/recreate-32bit-wide-011CUutRanFkxP8Pncv6SQZk`
- Comparison branch: `origin/32bit_wide`
- Base: `master`
- Commit: 146bbf5 "Initial 32-bit wide bus infrastructure for TG68K CPU"

