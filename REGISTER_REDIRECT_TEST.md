# Ethernet Register Redirection Test Plan

## Test Objective
Verify that ethernet register access (0xEA0C00-0xEA0C3F) is successfully redirected to DDR3 shared memory instead of causing system lockups.

## Pre-Test Checks
- [x] Build completed successfully with 0 errors  
- [x] RBF file generated
- [ ] System boots without lockups
- [ ] Ethernet appears in autoconfig

## Basic Functionality Tests

### Test 1: System Stability
**Goal:** Verify no lockups occur with new implementation
- [ ] Boot MiSTer with new RBF
- [ ] Access Workbench/AmigaOS
- [ ] No system freezes or lockups
- [ ] Mouse operates normally (no jumpiness)

### Test 2: Address Mapping Verification  
**Goal:** Confirm sel_ethernet_shm triggers for register space
- [ ] Check debug output: No "WARNING: sel_ethernet active without sel_ethernet_shm"
- [ ] Register access triggers sel_ethernet_shm = true
- [ ] Address translation works: 0xEA0C00 → 0xEA1004

### Test 3: Basic Register Access
**Goal:** Verify register reads/writes work without lockups
- [ ] Read CR register (0xEA0C00) - should not lockup
- [ ] Write CR register (0xEA0C00) - should not lockup  
- [ ] Read back value matches written value
- [ ] Multiple register accesses work reliably

### Test 4: Data Port Access
**Goal:** Verify data port redirection works
- [ ] Access data port (0xEA0C40) - should not lockup
- [ ] Data port access triggers sel_ethernet_shm
- [ ] No bus conflicts or system issues

## Expected Behavior Changes

### Before (Old Implementation):
- Register access triggers `sel_ethernet` only
- Ethernet module handles requests directly  
- Caused bus conflicts with DDR controller
- System lockups and jumpy mouse

### After (New Implementation):
- Register access triggers `sel_ethernet_shm` 
- CPU wrapper redirects to shared memory (0xEA1004+)
- Memory controller handles DDR3 access
- No bus conflicts, stable operation

## Address Mapping Verification

| Amiga Address | Function | DDR3 Address | Notes |
|---------------|----------|--------------|-------|
| 0xEA0C00 | CR Register | 0x28EA1004 | Command Register |
| 0xEA0C04 | Register 1 | 0x28EA1005 | Page-dependent |
| 0xEA0C1C | ISR Register | 0x28EA101C | Interrupt Status |
| 0xEA0C3C | IMR Register | 0x28EA103C | Interrupt Mask |
| 0xEA0C40 | Data Port | 0x28EA3000+ | NE2000 Memory |

## Debug Output to Monitor

### Success Indicators:
- No "WARNING: sel_ethernet active without sel_ethernet_shm" messages
- Address mapping debug shows correct translations
- DTACK signals work properly (no timeouts)

### Failure Indicators:  
- System lockups during register access
- Warning messages about sel_ethernet without sel_ethernet_shm
- Bus timeouts or CPU exceptions
- Mouse pointer becomes jumpy

## Test Tools

### Manual Testing:
1. **ethernet_register_test.c** - Amiga-side register access test
2. **HPS memory monitor** - Check DDR3 for register changes
3. **System observation** - Stability and responsiveness

### Simulation Testing:
1. **tb_register_redirect_test.v** - Verilog testbench  
2. **run_redirect_test.sh** - Simulation script

## Success Criteria

✅ **Primary Goals:**
- [ ] No system lockups during ethernet register access
- [ ] Register reads/writes complete successfully  
- [ ] sel_ethernet_shm handles all ethernet address space
- [ ] Address translation works correctly

✅ **Secondary Goals:**  
- [ ] HPS can monitor register changes in DDR3
- [ ] Bidirectional communication possible
- [ ] Foundation ready for network implementation

## Next Steps After Success

1. **HPS Integration:** Implement HPS-side code to monitor shared memory
2. **NE2000 Emulation:** Add proper NE2000 register behavior  
3. **Network Testing:** Implement packet transmission/reception
4. **Driver Compatibility:** Test with Amiga ethernet drivers

## Troubleshooting

### If Test Fails:
1. Check address mapping logic in cpu_wrapper.v
2. Verify sel_ethernet_shm coverage  
3. Check ethernet module DTACK behavior
4. Review DDR3 memory controller conflicts
5. Examine debug output for clues

### Common Issues:
- **Still locks up:** Address mapping may be incorrect
- **Registers don't work:** DTACK timing or data path issues  
- **Warning messages:** sel_ethernet still active somehow
- **Inconsistent behavior:** Timing or race conditions