# TG68K 32-Bit Wide Bus Implementation Plan

## Overview
This document outlines the plan to recreate a 32-bit wide architecture similar to the `32bit_wide` branch, but using the TG68K CPU instead of WF68K30L.

## Architecture Comparison

### 32bit_wide Branch (WF68K30L)
- Uses WF68K30L core with native 32-bit data bus
- 32-bit data paths throughout
- 4 byte enable signals (BE3:0)
- Single-cycle 32-bit aligned transfers
- Removed from that branch: TG68K support

### Our Approach (TG68K 32-bit)
- Keep TG68K core (proven, stable)
- Widen data interface from 16-bit to 32-bit
- Add 32-bit wrapper around TG68K
- Generate 4 byte enables from UDS/LDS + longword signal
- Leverage TG68K's existing longword support

## Key Components to Modify

### 1. TG68K CPU Layer
**Files:**
- `rtl/tg68k/TG68K_32bit_wrapper.vhd` (NEW) ✓ Created
- `rtl/tg68k/TG68K.qip` (update to include wrapper)

**Changes:**
- Wrapper accepts 32-bit data_in
- Wrapper outputs 32-bit data_write
- Generates 4 byte enables (nBE[3:0]) from core's nUDS/nLDS + longword
- Handles data routing between 32-bit external and 16-bit internal TG68K
- Optimizes aligned 32-bit transfers

### 2. CPU Wrapper Layer
**Files:**
- `rtl/cpu_wrapper.v`

**Changes:**
- Widen cpucfg from [1:0] to [2:0] to add 32-bit TG68K mode
- Add 32-bit data paths (chip_din, chip_dout: 31:0)
- Add chip_be[3:0] for byte enables
- Update ramdin/ramdout to 32-bit
- Instantiate TG68K_32bit_wrapper when cpucfg == 3'b100
- Route 32-bit data through the system

### 3. Bridge Layer
**Files:**
- `rtl/minimig_m68k_bridge.v`

**Changes:**
- Widen address bus from [23:1] to [31:1]
- Widen data buses from 16-bit to 32-bit
- Add 4 byte enable inputs (_be[3:0])
- Generate 4 independent byte write strobes
- Update host interface to 32-bit

### 4. Top Level Integration
**Files:**
- `rtl/minimig.v`

**Changes:**
- Add conditional compilation (`MINIMIG_TG68K_32BIT`)
- Widen CPU data buses (cpu_data_in, cpu_data_out: 31:0)
- Widen RAM interfaces (ram_data_in, ram_data_out: 31:0)
- Keep custom chip interfaces at 16-bit (no change needed)
- Update gary multiplexer for 32-bit

### 5. Memory Controllers
**Files:**
- `rtl/sdram_ctrl.v`
- `rtl/ddram_ctrl.v`

**Changes:**
- Widen CPU data interface to 32-bit
- Add byte enable support (4 bytes)
- Keep chip interface at 16-bit
- Optimize burst transfers for 32-bit CPU accesses

### 6. Configuration
**Files:**
- `rtl/minimig_config.vh` (NEW) ✓ Created

**Defines:**
```verilog
`define MINIMIG_TG68K_32BIT    // Enable 32-bit mode
`define TG68K_DATA_WIDTH 32    // Data bus width
`define TG68K_BYTE_ENABLES 4   // Number of byte enables
```

## Implementation Strategy

### Phase 1: Core CPU Changes ✓
1. [x] Create configuration header (minimig_config.vh)
2. [x] Create TG68K 32-bit wrapper (TG68K_32bit_wrapper.vhd)
3. [ ] Update TG68K.qip to include wrapper
4. [ ] Test wrapper in isolation

### Phase 2: Infrastructure Changes
5. [ ] Modify cpu_wrapper.v for 32-bit support
6. [ ] Update minimig_m68k_bridge.v for 32-bit
7. [ ] Widen minimig.v data paths
8. [ ] Update memory controllers

### Phase 3: Integration
9. [ ] Connect all 32-bit data paths
10. [ ] Add byte enable routing
11. [ ] Update build scripts
12. [ ] Build and test

### Phase 4: Optimization
13. [ ] Optimize aligned 32-bit transfers
14. [ ] Add burst mode support
15. [ ] Performance testing
16. [ ] Compare with 32bit_wide branch

## Technical Details

### Byte Enable Mapping
```
nBE[3] - Bits 31:24 (byte 3)
nBE[2] - Bits 23:16 (byte 2)
nBE[1] - Bits 15:8  (byte 1)
nBE[0] - Bits 7:0   (byte 0)
```

### Data Bus Layout
```
31:24 - Byte 3 (MSB)
23:16 - Byte 2
15:8  - Byte 1
7:0   - Byte 0 (LSB)
```

### Transfer Types
- **Longword (32-bit):** All 4 bytes, nBE = 4'b0000
- **Word (16-bit):** 2 bytes based on address[1]
  - addr[1]=0: nBE = 4'b0011 (upper word)
  - addr[1]=1: nBE = 4'b1100 (lower word)
- **Byte (8-bit):** 1 byte based on address[1:0]
  - addr[1:0]=00: nBE = 4'b0001
  - addr[1:0]=01: nBE = 4'b0010
  - addr[1:0]=10: nBE = 4'b0100
  - addr[1:0]=11: nBE = 4'b1000

### CPU Configuration (cpucfg)
```
3'b000 - FX68K (16-bit)
3'b001 - TG68K 68000 (16-bit)
3'b010 - TG68K 68010 (16-bit)
3'b011 - TG68K 68020 (16-bit)
3'b100 - TG68K 32-bit mode (NEW)
```

## Compatibility

### Backwards Compatibility
- Existing 16-bit modes unchanged
- Custom chips remain 16-bit
- Kickstart ROM interface unchanged
- Autoconfig mechanism unchanged

### Performance Benefits
- 2x memory bandwidth for aligned longword accesses
- Reduced bus cycles for 32-bit operations
- Better cache line fills
- Improved performance for 68020+ code using longword ops

## Testing Plan

1. **Unit Tests:**
   - TG68K wrapper byte enable generation
   - Data routing for different access sizes
   - Aligned vs misaligned transfers

2. **Integration Tests:**
   - Boot to Workbench
   - Run SysInfo to verify CPU recognition
   - Memory tests (aligned/misaligned)
   - Benchmark tests (SysSpeed, etc.)

3. **Regression Tests:**
   - Existing games and demos
   - WHDLoad compatibility
   - Network stack (if applicable)

## Known Limitations

1. TG68K core is fundamentally 16-bit internally
   - Wrapper provides 32-bit interface
   - Internal operations still 16-bit
   - Performance gain mainly from reduced bus cycles

2. Misaligned 32-bit accesses still multi-cycle

3. Custom chips remain 16-bit (by design)

## Future Enhancements

1. Optimize TG68K core internals for true 32-bit data path
2. Add cache line burst mode
3. Implement write combining
4. Add performance counters

## References

- Original TG68K by Tobias Gubener
- 32bit_wide branch with WF68K30L
- MC68020 User's Manual (Motorola)
- Minimig AGA documentation

