# Phase 14: Full MMU Integration - Planning Document

**Status**: Planning
**Date**: 2025-11-11
**Estimated Effort**: 20-30 hours
**Estimated Completion**: 3% of overall project
**Prerequisites**: Phase 13 complete ✅

---

## Executive Summary

Phase 14 represents the final major development phase of the MC68030 implementation. This phase will integrate the full TG68K030 wrapper, activate MMU address translation, enable caches, and implement burst mode transfers. Upon completion, the MC68030 will be **99% functionally complete**, with only hardware validation (Phase 15) remaining.

**Key Goal**: Transform the MC68030 from "F-line instructions work" to "full MMU with address translation and caches operational".

---

## Current Status (Post Phase 13)

### What Works ✅
- F-line instruction decoding (PMOVE, PFLUSH, PTEST)
- PMOVE execution (all addressing modes, memory operations)
- PFLUSH execution (ATC invalidation)
- MMU control registers (all 6 registers accessible)
- ATC invalidation interface
- Build system integration

### What Doesn't Work ❌
- MMU address translation (virtual → physical)
- ATC lookup during memory access
- Table walking on ATC miss
- Instruction cache
- Data cache
- Burst mode transfers
- PTEST complete functionality

### Architecture Gap

Currently, the system uses TG68KdotC_Kernel directly with external F-line components bolted on via cpu_wrapper.v. This works for F-line instructions but doesn't activate the full MMU/cache infrastructure.

**Current Data Path**:
```
TG68KdotC_Kernel ──► Memory
        │
        └──► F-line decoders/executors (external)
```

**Phase 14 Target Data Path**:
```
TG68K030 Wrapper ──► MMU ──► ATC lookup ──► Memory
        │                 │
        │                 └──► Table Walker (on miss)
        │
        ├──► I-Cache ──► TG68KdotC_Kernel
        ├──► D-Cache
        └──► F-line components (integrated)
```

---

## Phase 14 Objectives

1. **Integrate TG68K030 Wrapper** as primary CPU interface
2. **Activate MMU Translation** for all memory accesses
3. **Enable ATC Lookup** in memory path
4. **Implement Table Walker** for ATC miss handling
5. **Activate Instruction Cache** (4KB, 4-way set associative)
6. **Activate Data Cache** (4KB, 4-way set associative)
7. **Implement Burst Transfers** for cache fills
8. **Complete PTEST Functionality**

---

## Implementation Strategy

### Option 1: Full TG68K030 Wrapper Integration (Recommended)

**Approach**: Replace TG68KdotC_Kernel instantiation with TG68K030 wrapper in cpu_wrapper.v

**Advantages**:
- ✅ Clean architecture
- ✅ All features activated at once
- ✅ Proper data bus width handling (16-bit ↔ 32-bit)
- ✅ Complete implementation

**Disadvantages**:
- ⚠️ Cannot test incrementally
- ⚠️ Requires data bus adapter (16-bit Minimig ↔ 32-bit TG68K030)
- ⚠️ Significant integration effort upfront

**Estimated Effort**: 20-25 hours

### Option 2: Incremental Integration (Not Recommended)

**Approach**: Add MMU translation layer between TG68KdotC_Kernel and memory

**Advantages**:
- ✅ Can test incrementally
- ✅ Smaller changes per step

**Disadvantages**:
- ❌ Complex intermediate states
- ❌ Duplicate code with TG68K030 wrapper
- ❌ Harder to debug
- ❌ More total effort

**Estimated Effort**: 30-35 hours

**Recommendation**: Use Option 1 (Full TG68K030 Wrapper Integration)

---

## Detailed Implementation Plan

### Step 1: Data Bus Adapter Design (4-5 hours)

**Problem**: MiSTer Minimig uses 16-bit data bus, TG68K030 wrapper expects 32-bit bus.

**Solution**: Create bus width adapter module.

#### TG68K030_Bus_Adapter.v

```verilog
module TG68K030_Bus_Adapter
(
    input clk,
    input reset,

    // 32-bit side (TG68K030 wrapper)
    input [31:0] cpu_addr_32,
    input [31:0] cpu_dout_32,
    output reg [31:0] cpu_din_32,
    input cpu_write_32,
    input cpu_read_32,
    input [1:0] cpu_size,  // 00=byte, 01=word, 10=long
    output reg cpu_ready_32,

    // 16-bit side (Minimig system)
    output reg [31:0] sys_addr_16,
    output reg [15:0] sys_dout_16,
    input [15:0] sys_din_16,
    output reg sys_write_16,
    output reg sys_read_16,
    output reg sys_uds,
    output reg sys_lds,
    input sys_ready_16
);

    // State machine for 32-bit transfers
    // Breaks 32-bit operations into 2x16-bit operations

    // Implementation details TBD

endmodule
```

**Tasks**:
1. Design state machine for long word transfers
2. Handle byte/word/long size properly
3. Manage UDS/LDS strobes for 16-bit bus
4. Buffer upper/lower 16-bit data
5. Test with simulation

### Step 2: TG68K030 Wrapper Instantiation (3-4 hours)

**Task**: Replace TG68KdotC_Kernel with TG68K030 wrapper in cpu_wrapper.v

#### Current (Phase 13):
```verilog
TG68KdotC_Kernel cpu_inst_p
(
    .clk(clk),
    .data_in(cpu_din),          // 16-bit
    .data_write(cpu_dout_p),    // 16-bit
    .addr_out(cpu_addr_p),      // 32-bit
    // ...
);
```

#### Target (Phase 14):
```verilog
// Bus adapter
TG68K030_Bus_Adapter bus_adapter
(
    .clk(clk),
    .reset(~reset),
    // 32-bit CPU side
    .cpu_addr_32(cpu_addr_32),
    .cpu_dout_32(cpu_dout_32),
    .cpu_din_32(cpu_din_32),
    .cpu_write_32(cpu_write),
    .cpu_read_32(cpu_read),
    .cpu_size(cpu_size),
    .cpu_ready_32(cpu_ready),
    // 16-bit system side
    .sys_addr_16(cpu_addr_p),
    .sys_dout_16(cpu_dout_p),
    .sys_din_16(cpu_din),
    .sys_write_16(cpu_write_p),
    .sys_read_16(cpu_read_p),
    .sys_uds(uds_p),
    .sys_lds(lds_p),
    .sys_ready_16(cpu_ready_16)
);

// TG68K030 wrapper
TG68K030 cpu_inst_030
(
    .clk(clk),
    .reset_n(reset),

    // 32-bit memory interface
    .mem_addr(cpu_addr_32),
    .mem_data_out(cpu_dout_32),
    .mem_data_in(cpu_din_32),
    .mem_write(cpu_write),
    .mem_read(cpu_read),
    .mem_size(cpu_size),
    .mem_ready(cpu_ready),

    // Control
    .ipl(cpu_ipl),
    .ipl_autovector(1'b1),
    .cpu_config(cpucfg),

    // Status outputs
    .busstate(cpustate_p),
    .fc(fc_p),
    .cacr_out(cacr_p),
    .vbr_out(vbr_p)
);
```

**Tasks**:
1. Create bus adapter module
2. Modify cpu_wrapper.v to use TG68K030
3. Connect all control signals
4. Handle cpucfg selection (keep 68000/68010/68020 modes)
5. Test basic operation

### Step 3: MMU Configuration (2-3 hours)

**Task**: Set up MMU for transparent translation (1:1 mapping initially)

#### Initial MMU Setup

For initial testing, use transparent translation (no actual translation):

```assembly
; Disable MMU translation initially
MOVE.L  #$00000000,D0
PMOVE   D0,TC           ; TC.E = 0 (MMU disabled)

; Set up transparent translation for all memory
MOVE.L  #$0000FF00,D0   ; Enable transparent, all addresses
PMOVE   D0,TT0
PMOVE   D0,TT1
```

This allows testing the wrapper integration without complex page tables.

**Tasks**:
1. Document default MMU configuration
2. Create test program for MMU activation
3. Test transparent translation mode
4. Verify no address translation occurs

### Step 4: ATC Integration with Memory Path (4-5 hours)

**Task**: Connect ATC lookup to memory access path

#### Memory Access Flow

```
Memory Request
    │
    ├──► MMU Enabled?
    │       │
    │       NO──► Pass-through (physical = virtual)
    │       │
    │       YES──► Check Transparent Translation
    │               │
    │               Match──► Use transparent (no ATC lookup)
    │               │
    │               No Match──► ATC Lookup
    │                           │
    │                           Hit──► Use cached translation
    │                           │
    │                           Miss──► Table Walk
    │                                   │
    │                                   └──► Load ATC entry
```

**Implementation in TG68K030_MMU_Controller.vhd**:

Already implemented! Just needs activation.

**Tasks**:
1. Verify ATC lookup logic in TG68K030_MMU_Controller
2. Connect lookup interface (currently stubbed in cpu_wrapper.v)
3. Test ATC hit path
4. Measure timing impact

### Step 5: Table Walker Implementation (6-8 hours)

**Task**: Implement table walking for ATC misses

#### MC68030 Page Table Structure

```
Root Pointer (CRP/SRP)
    │
    ├──► Early Termination? ──YES──► Direct mapping
    │
    NO──► Level A Table
             │
             ├──► Descriptor ──► Level B Table (if 4-level)
                                     │
                                     └──► Descriptor ──► Level C Table
                                                            │
                                                            └──► Page Descriptor
```

#### Table Walker State Machine

**States**:
1. IDLE - Waiting for lookup miss
2. READ_ROOT - Read root pointer
3. READ_LEVEL_A - Read first level table
4. READ_LEVEL_B - Read second level (if needed)
5. READ_LEVEL_C - Read third level (if needed)
6. LOAD_ATC - Load resulting entry into ATC
7. DONE - Signal completion

**Implementation** (already exists in TG68K030_Table_Walker.vhd):

```vhdl
-- Component already implemented!
-- Located at: rtl/tg68k030/TG68K030_Table_Walker.vhd
-- Status: Complete, needs integration testing
```

**Tasks**:
1. Review existing table walker implementation
2. Connect to MMU controller
3. Connect memory bus for table reads
4. Test with simple page tables
5. Test with 2-level, 3-level, 4-level structures
6. Handle table walk exceptions

### Step 6: Cache Activation (4-5 hours)

**Task**: Enable instruction and data caches

#### Cache Configuration

**Instruction Cache**:
- 4KB total size
- 4-way set associative
- 16-byte lines (4 long words)
- LRU replacement
- Already implemented in TG68K030_Instruction_Cache.vhd

**Data Cache**:
- 4KB total size
- 4-way set associative
- 16-byte lines
- Write-through policy
- Already implemented in TG68K030_Data_Cache.vhd

#### Cache Control via CACR

```
CACR bits:
  [0] = Enable Instruction Cache
  [1] = Freeze Instruction Cache
  [8] = Enable Data Cache
  [9] = Freeze Data Cache
  [11] = Write Allocate
```

**Tasks**:
1. Verify cache implementations
2. Connect cache enable signals to CACR
3. Test cache hit/miss scenarios
4. Measure performance improvement
5. Test cache flush operations

### Step 7: Burst Mode Implementation (2-3 hours)

**Task**: Implement burst transfers for cache line fills

#### Burst Transfer Protocol

**Cache Line Fill** (4 long words = 16 bytes):
```
Burst Request
    │
    ├──► Request 4 consecutive long words
    │
    ├──► Word 0 (base address)
    ├──► Word 1 (base + 4)
    ├──► Word 2 (base + 8)
    └──► Word 3 (base + 12)

Total: 4 cycles (vs 16 cycles for individual transfers)
```

**Implementation** (exists in TG68K030_Burst_Controller.vhd):

```vhdl
-- Component already implemented!
-- Located at: rtl/tg68k030/TG68K030_Burst_Controller.vhd
-- Status: Complete, needs MiSTer bus integration
```

**Tasks**:
1. Review burst controller implementation
2. Connect to memory controller
3. Connect to cache line fill logic
4. Test burst transfers
5. Measure performance improvement

### Step 8: PTEST Complete Implementation (2-3 hours)

**Task**: Connect PTEST to table walker for translation testing

#### PTEST Functionality

```assembly
PTEST  #FC,<ea>,#level,An
```

Performs translation of `<ea>` using function code `FC`, up to `level` depth, and stores result in `An` (or MMUSR).

**Implementation Flow**:
1. PTEST instruction decoded
2. Trigger table walk with test parameters
3. Don't load result into ATC
4. Store translation result in return register
5. Update MMUSR with status

**Tasks**:
1. Modify PTEST executor to trigger table walk
2. Add "test mode" to table walker (don't load ATC)
3. Implement result return to register
4. Update MMUSR with translation status
5. Test PTEST instruction

### Step 9: Integration Testing (3-4 hours)

**Task**: Comprehensive testing of all Phase 14 features

**Test Suite**:

1. **MMU Translation Test**
```assembly
; Set up simple 1:1 page table
; Enable MMU
; Verify addresses translate correctly
```

2. **ATC Test**
```assembly
; Perform several accesses to same page
; Verify ATC hits
; PFLUSH page
; Verify ATC miss after flush
```

3. **Cache Test**
```assembly
; Disable caches
; Time memory access
; Enable caches
; Time memory access
; Verify speed improvement
```

4. **PTEST Test**
```assembly
; Set up page tables
; PTEST various addresses
; Verify results match expected translations
```

**Tasks**:
1. Create comprehensive test programs
2. Run tests in simulation (if available)
3. Document test results
4. Fix any bugs discovered
5. Performance benchmarking

---

## Technical Challenges

### Challenge 1: Data Bus Width Mismatch

**Issue**: TG68K030 is 32-bit, MiSTer Minimig is 16-bit

**Solution**: Bus width adapter with state machine for long word transfers

**Complexity**: Medium
**Risk**: Low (well-understood problem)

### Challenge 2: Timing Closure

**Issue**: Adding MMU/cache may impact timing

**Solution**:
- Pipeline critical paths
- Use multicycle path constraints
- Optimize ATC lookup timing

**Complexity**: Medium-High
**Risk**: Medium

### Challenge 3: Debugging Without Hardware

**Issue**: Can't fully test without MiSTer hardware

**Solution**:
- Extensive code review
- Simulation where possible
- Staged integration with fallback modes

**Complexity**: Medium
**Risk**: Medium

### Challenge 4: Cache Coherency

**Issue**: Data cache write-through vs write-back

**Solution**: Use write-through initially (simpler, safer)

**Complexity**: Low
**Risk**: Low

---

## Testing Strategy

### Level 1: Component Testing (Per Step)

Test each component as integrated:
- Bus adapter: Test 16/32-bit conversions
- MMU: Test transparent translation
- ATC: Test lookup hit/miss
- Table walker: Test with known page tables
- Caches: Test hit/miss/flush
- Burst: Test multi-word transfers

### Level 2: Integration Testing

Test combinations:
- MMU + ATC
- MMU + ATC + Table Walker
- MMU + Caches
- All together

### Level 3: System Testing (Phase 15)

Test on real MiSTer hardware:
- Boot Amiga OS
- Run MMU-aware software
- Performance benchmarks
- Stability tests

---

## Success Criteria

Phase 14 is complete when:

- ✅ TG68K030 wrapper integrated as primary CPU
- ✅ MMU address translation operational
- ✅ ATC lookup working (hit path)
- ✅ Table walker functional (ATC miss handling)
- ✅ Instruction cache activated
- ✅ Data cache activated
- ✅ Burst mode transfers working
- ✅ PTEST complete functionality
- ✅ All test programs pass
- ✅ No regressions in 68000/68010/68020 modes
- ✅ Ready for hardware testing (Phase 15)

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|---------|------------|
| Timing fails | Medium | High | Multicycle constraints, pipelining |
| Bus adapter bugs | Low | Medium | Thorough testing, simulation |
| Cache coherency | Low | High | Use write-through, extensive testing |
| Table walker bugs | Medium | High | Test with known page tables first |
| Resource overflow | Low | Medium | Monitor synthesis reports |
| Debug difficulty | High | Medium | Add debug signals, staged integration |

---

## Resource Requirements

### Development Time

| Task | Estimated Hours |
|------|----------------|
| Bus adapter design | 4-5 |
| Wrapper instantiation | 3-4 |
| MMU configuration | 2-3 |
| ATC integration | 4-5 |
| Table walker | 6-8 |
| Cache activation | 4-5 |
| Burst mode | 2-3 |
| PTEST completion | 2-3 |
| Integration testing | 3-4 |
| **Total** | **30-40 hours** |

### Hardware Requirements

- MiSTer FPGA (for Phase 15 validation)
- Quartus Prime (for synthesis)
- ModelSim/QuestaSim (optional, for simulation)

### FPGA Resources

| Component | ALMs | Memory | Estimate |
|-----------|------|--------|----------|
| Current (Phase 13) | 3,200 | 51KB | 10% |
| + Bus adapter | +100 | - | +0.3% |
| + MMU active | +200 | - | +0.6% |
| + Caches active | +800 | +8KB | +2.5% |
| **Total Phase 14** | **~4,300** | **59KB** | **~13%** |

**Status**: Well within Cyclone V capacity ✅

---

## Documentation Deliverables

1. **PHASE14_COMPLETION_STATUS.md** - Implementation summary
2. **BUS_ADAPTER_DESIGN.md** - Bus width adapter documentation
3. **MMU_ACTIVATION_GUIDE.md** - How to configure and use MMU
4. **CACHE_PERFORMANCE.md** - Cache performance analysis
5. **TEST_RESULTS.md** - Comprehensive test results

---

## Dependencies

### Prerequisites (Must Be Complete)
- ✅ Phase 13 complete
- ✅ All F-line instructions functional
- ✅ ATC invalidation working
- ✅ Build system ready

### External Dependencies
- Quartus Prime (for synthesis)
- MiSTer FPGA hardware (for Phase 15 validation)

### Code Dependencies
All components already implemented:
- ✅ TG68K030.vhd (wrapper)
- ✅ TG68K030_MMU_Controller.vhd
- ✅ TG68K030_ATC.vhd
- ✅ TG68K030_Table_Walker.vhd
- ✅ TG68K030_Instruction_Cache.vhd
- ✅ TG68K030_Data_Cache.vhd
- ✅ TG68K030_Burst_Controller.vhd
- ✅ TG68K030_Memory_Controller.vhd

**All VHDL components exist! Just need integration!**

---

## Timeline Estimate

### Optimistic (20 hours)
- 1 weekend of focused work
- No major issues
- Everything works first try

### Realistic (30 hours)
- 2-3 weekends of work
- Normal debugging
- Some iteration required

### Pessimistic (40 hours)
- 3-4 weekends of work
- Significant debugging
- Timing issues, rework required

**Recommended Estimate**: 30 hours (realistic)

---

## Next Steps

1. **Review TG68K030 wrapper implementation**
   - Read TG68K030.vhd
   - Understand interface requirements
   - Identify integration points

2. **Design bus width adapter**
   - Create state machine
   - Handle all transfer sizes
   - Plan testing approach

3. **Begin Step 1: Bus Adapter**
   - Implement adapter module
   - Test with simulation
   - Prepare for wrapper integration

---

## Conclusion

Phase 14 represents the final major development milestone for the MC68030 implementation. While substantial, this phase primarily involves **integration of existing components** rather than new development. All major VHDL components (MMU, ATC, caches, table walker) are already implemented and tested in isolation.

**Key Insight**: The hard work is done - Phase 14 is about connecting the pieces!

Upon completion of Phase 14:
- MC68030 will be **99% functionally complete**
- Only hardware validation (Phase 15) will remain
- Full MMU, caches, and burst mode will be operational
- Ready for real-world Amiga OS testing

**Estimated Project Completion After Phase 14**: 99%
**Remaining Work**: Phase 15 (Hardware Validation) - 1%

---

**Status**: Ready to begin implementation
**Next**: Review TG68K030.vhd and design bus adapter
