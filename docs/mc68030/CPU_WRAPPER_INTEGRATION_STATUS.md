# CPU Wrapper Integration Status

**Date**: 2025-11-11
**Phase**: 11 - Build System Complete, Integration Pending
**Critical Finding**: F-line support exists but is NOT active in cpu_wrapper.v

---

## Executive Summary

### The Integration Gap 🔴

**Problem**: TG68KdotC_Kernel has F-line interface ports (added in Phase 10), but cpu_wrapper.v does NOT connect them.

**Impact**:
- F-line instructions (PMOVE, PFLUSH, PTEST) still **trap as illegal**
- MC68030-specific functionality is **not active**
- Build system includes TG68K030 files, but they are **never instantiated**

**Status**: Build system ready ✅, Runtime integration incomplete ❌

---

## Current Architecture Analysis

### What cpu_wrapper.v Currently Does

**File**: `rtl/cpu_wrapper.v`

**CPU Instantiations**:
1. **fx68k** (cpu_inst_o) - 68000-only core for cpucfg=00
2. **TG68KdotC_Kernel** (cpu_inst_p) - 68000/68010/68020/68030 for cpucfg=01/10/11

**Selection Logic** (lines 140-181):
```verilog
always @* begin
    if(cpucfg[1:0]) begin
        // Use TG68KdotC_Kernel
        cpu_dout = cpu_dout_p;
        cpu_addr = cpu_addr_p;
        ...
    end
    else begin
        // Use fx68k
        cpu_dout = cpu_dout_o;
        cpu_addr = {cpu_addr_o,1'b0};
        ...
    end
end
```

### TG68KdotC_Kernel Instantiation (Lines 194-224)

```verilog
TG68KdotC_Kernel
#(
    .sr_read(2),
    .vbr_stackframe(2),
    .extaddr_mode(2),
    .mul_mode(2),
    .div_mode(2),
    .bitfield(2)
)
cpu_inst_p
(
    .clk(clk),
    .nreset(reset),
    .clkena_in(~cpu_req | chipready | ramready | fastchip_ready),
    .data_in(cpu_din),
    .ipl(cpu_ipl),
    .ipl_autovector(1),
    .regin_out(),
    .addr_out(cpu_addr_p),
    .data_write(cpu_dout_p),
    .nwr(wr_p),
    .nuds(uds_p),
    .nlds(lds_p),
    .nresetout(reset_out_p),
    .longword(longword),
    .cpu(cpucfg),
    .busstate(cpustate_p),
    .cacr_out(cacr_p),
    .vbr_out(vbr_p)
    // ❌ MISSING: fline_is_mmu, fline_is_pmove, fline_is_pflush, fline_is_ptest
    // ❌ MISSING: fline_exec_req, fline_exec_done
);
```

**Critical Issue**: F-line interface ports NOT connected!

### Phase 10 Added F-Line Ports to TG68KdotC_Kernel

**File**: `rtl/tg68k/TG68KdotC_Kernel.vhd` (lines 142-148)

```vhdl
-- MC68030 F-line MMU instruction interface (for external decoder/executor)
fline_is_mmu      : in std_logic:='0';      -- Recognized MMU instruction
fline_is_pmove    : in std_logic:='0';      -- PMOVE detected
fline_is_pflush   : in std_logic:='0';      -- PFLUSH detected
fline_is_ptest    : in std_logic:='0';      -- PTEST detected
fline_exec_req    : out std_logic;          -- Request external F-line execution
fline_exec_done   : in std_logic:='0'       -- F-line execution complete
```

**Default Values**: All inputs default to '0'

**Behavior**: Without connection, F-line instructions trap (fline_is_mmu='0')

---

## What TG68K030 Provides

### TG68K030 Architecture

**File**: `rtl/tg68k030/TG68K030.vhd`

**TG68K030 is a complete MC68030 system** that includes:

1. **TG68KdotC_Kernel instance** (base CPU core)
2. **F-line Decoders** (PMOVE, PFLUSH, PTEST)
3. **F-line Executors** (PMOVE, PFLUSH, PTEST)
4. **MMU Registers** (TC, TT0, TT1, CRP, SRP, MMUSR)
5. **Cache Registers** (CACR, CAAR)
6. **ATC** (Address Translation Cache, 22 entries)
7. **MMU Translation** (Transparent translation, table walk)
8. **Instruction Cache** (256 bytes, 4-way)
9. **Data Cache** (256 bytes, 4-way)
10. **Memory Controller** (with burst support)
11. **Bus Arbiter**

**Integration**: TG68K030 instantiates TG68KdotC_Kernel internally and wires up all F-line components.

### TG68K030 Interface

**Port Signature** (simplified):

```vhdl
entity TG68K030 is
    port(
        clk, reset, clkena    : in  std_logic;
        cpucfg                : in  std_logic_vector(1 downto 0);

        -- 32-bit external bus
        addr                  : out std_logic_vector(31 downto 0);
        data_read             : in  std_logic_vector(31 downto 0);
        data_write            : out std_logic_vector(31 downto 0);
        as, uds, lds, rw      : out std_logic;
        dtack                 : in  std_logic;
        busstate              : out std_logic_vector(1 downto 0);
        fc                    : out std_logic_vector(2 downto 0);

        -- MC68030-specific
        burst                 : out std_logic;
        siz                   : out std_logic_vector(1 downto 0);

        -- Interrupts
        ipl                   : in  std_logic_vector(2 downto 0);

        -- Cache control
        cache_inhibit         : in std_logic;

        -- Debug
        cpu_state             : out std_logic_vector(5 downto 0)
    );
end entity;
```

**Key Differences from TG68KdotC_Kernel**:
- ✅ 32-bit data paths (vs 16-bit)
- ✅ Burst and size signals
- ✅ Simplified interface (no F-line ports exposed - handled internally)
- ❌ No CACR_out, VBR_out exposed
- ❌ No longword signal
- ❌ Different signal polarities (active high vs active low)

---

## Integration Options

### Option 1: Use TG68K030 Wrapper (Recommended)

**Approach**: Replace TG68KdotC_Kernel instantiation with TG68K030 in cpu_wrapper.v

**Advantages**:
- ✅ Complete MC68030 functionality
- ✅ F-line instructions work automatically
- ✅ MMU, caches, burst mode available
- ✅ Clean architecture
- ✅ All components properly integrated

**Challenges**:
- ⚠️ Interface changes required (32-bit vs 16-bit data)
- ⚠️ New signals (burst, siz) need to be handled
- ⚠️ Signal conversions needed (active high/low)
- ⚠️ CACR_out, VBR_out not directly available
- ⚠️ Moderate complexity

**Compatibility**:
- Could be selected only when cpucfg=11 (68030 mode)
- cpucfg=00/01/10 continue using existing cores

### Option 2: Manual F-Line Integration (Not Recommended)

**Approach**: Instantiate F-line decoders/executors separately in cpu_wrapper.v and wire to TG68KdotC_Kernel

**Advantages**:
- ✅ Minimal interface changes
- ✅ Keeps 16-bit data paths

**Challenges**:
- ❌ Duplicates TG68K030 integration work
- ❌ Complex wiring (100+ signals)
- ❌ MMU/cache components need separate instantiation
- ❌ Maintenance burden (changes in two places)
- ❌ High complexity

**Recommendation**: Don't do this - use TG68K030 instead

### Option 3: Hybrid Approach

**Approach**: Use TG68KdotC_Kernel for cpucfg=00/01/10, TG68K030 for cpucfg=11

**Implementation**:
```verilog
// Three CPU instances
fx68k         cpu_inst_o;      // cpucfg=00 (68000)
TG68KdotC_Kernel cpu_inst_p;   // cpucfg=01/10 (68010/68020)
TG68K030      cpu_inst_030;    // cpucfg=11 (68030)

// Three-way mux
always @* begin
    case(cpucfg)
        2'b00: begin
            // fx68k outputs
        end
        2'b01, 2'b10: begin
            // TG68KdotC_Kernel outputs
        end
        2'b11: begin
            // TG68K030 outputs
        end
    endcase
end
```

**Advantages**:
- ✅ No regression for existing modes
- ✅ Full 68030 support when selected
- ✅ Clean separation of functionality

**Challenges**:
- ⚠️ Interface adapter needed for TG68K030
- ⚠️ Three CPU instances (resource usage)
- ⚠️ Mux complexity

---

## Interface Adaptation Requirements

### Signal Mapping: TG68K030 → cpu_wrapper.v

| TG68K030 Port | Type | cpu_wrapper Expected | Conversion Needed |
|---------------|------|---------------------|-------------------|
| **Data Bus** | | | |
| data_read[31:0] | Input | cpu_din[15:0] | ⚠️ 32→16 bit adapter |
| data_write[31:0] | Output | cpu_dout[15:0] | ⚠️ 32→16 bit adapter |
| **Address Bus** | | | |
| addr[31:0] | Output | cpu_addr[31:0] | ✅ Direct |
| **Control Signals** | | | |
| as | Output | chip_as (inverted) | ⚠️ Invert |
| uds | Output | chip_uds (inverted) | ⚠️ Invert |
| lds | Output | chip_lds (inverted) | ⚠️ Invert |
| rw | Output | chip_rw (inverted) | ⚠️ Invert |
| dtack | Input | chip_dtack (inverted) | ⚠️ Invert |
| busstate[1:0] | Output | cpustate[1:0] | ✅ Direct |
| fc[2:0] | Output | (not used) | ✅ Can add |
| **MC68030-Specific** | | | |
| burst | Output | (new) | ⚠️ Add to interface |
| siz[1:0] | Output | (new) | ⚠️ Add to interface |
| **Missing from TG68K030** | | | |
| (none) | | cacr_out[3:0] | ❌ Not exposed |
| (none) | | vbr_out[31:0] | ❌ Not exposed |
| (none) | | longword | ❌ Not exposed |
| (none) | | reset_out | ✅ Could add |

**32-bit to 16-bit Data Adapter**:

The main challenge is data bus width. TG68K030 uses 32-bit, but the Amiga chipset uses 16-bit.

**Possible Solutions**:
1. **Two-cycle adapter**: Split 32-bit transfers into two 16-bit cycles
2. **Use only lower 16 bits**: Ignore upper 16 bits (limits functionality)
3. **Modify system**: Upgrade to 32-bit data paths (major change)

**Recommendation**: Use two-cycle adapter for now.

---

## Current Status Summary

### What Works ✅
- TG68KdotC_Kernel compiles with F-line interface
- TG68K030 wrapper compiles successfully
- All MC68030 component files in build system
- Build system configured for Quartus synthesis

### What Doesn't Work ❌
- **F-line instructions trap** (decoders not instantiated)
- **TG68K030 not used** (cpu_wrapper uses TG68KdotC_Kernel)
- **MC68030 features inactive** (MMU, caches not instantiated)
- **No runtime MC68030 support** (despite cpucfg=11 option)

### Required for Full MC68030 Support
1. ❌ Instantiate TG68K030 in cpu_wrapper.v
2. ❌ Add interface adapter (32-bit ↔ 16-bit data)
3. ❌ Add burst signal handling
4. ❌ Update mux logic for three-way CPU selection
5. ❌ Test on hardware

---

## Recommended Integration Plan

### Phase 11.5: CPU Wrapper Integration (Future Work)

**Goal**: Integrate TG68K030 into cpu_wrapper.v for full MC68030 support

**Steps**:

1. **Create Interface Adapter** (1-2 hours)
   - 32-bit to 16-bit data bus converter
   - Signal polarity conversions
   - Burst mode handler

2. **Modify cpu_wrapper.v** (2-3 hours)
   - Add TG68K030 instantiation
   - Add three-way mux (fx68k / TG68KdotC_Kernel / TG68K030)
   - Wire up adapter

3. **Update Minimig Top-Level** (1 hour)
   - Add burst and siz signal routing (if needed)
   - Update OSD for 68030 mode selection

4. **Test and Debug** (3-5 hours)
   - Synthesis testing
   - Hardware validation
   - Regression testing (68000/68010/68020 modes)

**Total Estimated Effort**: 7-11 hours

---

## Alternative: Minimal F-Line Support

### Quick Integration (Without TG68K030 Wrapper)

If full integration is too complex for now, we could add minimal F-line support:

**Approach**: Wire F-line components directly to TG68KdotC_Kernel in cpu_wrapper.v

**What to Add**:
```verilog
// F-line decoder signals
wire fline_is_mmu, fline_is_pmove, fline_is_pflush, fline_is_ptest;
wire fline_exec_req, fline_exec_done;

// Instantiate decoders (copy from TG68K030.vhd)
TG68K030_PMOVE_Decoder pmove_decoder(...);
TG68K030_PFLUSH_Decoder pflush_decoder(...);
TG68K030_PTEST_Decoder ptest_decoder(...);

// Instantiate executors (copy from TG68K030.vhd)
TG68K030_PMOVE_Execute pmove_exec(...);
TG68K030_PFLUSH_Execute pflush_exec(...);
TG68K030_PTEST_Execute ptest_exec(...);

// Instantiate MMU registers
TG68K030_MMU_Registers mmu_regs(...);

// Wire to TG68KdotC_Kernel
TG68KdotC_Kernel cpu_inst_p
(
    ...
    .fline_is_mmu(fline_is_mmu),
    .fline_is_pmove(fline_is_pmove),
    .fline_is_pflush(fline_is_pflush),
    .fline_is_ptest(fline_is_ptest),
    .fline_exec_req(fline_exec_req),
    .fline_exec_done(fline_exec_done)
);
```

**Effort**: ~100 lines of Verilog, 2-3 hours

**Advantages**:
- ✅ F-line instructions work
- ✅ PMOVE fully functional
- ✅ Minimal interface changes

**Limitations**:
- ❌ No MMU translation (just register access)
- ❌ No caches
- ❌ No burst mode
- ❌ Duplicates TG68K030 integration

---

## Testing Without Integration

### Current Testing Capability

**Without cpu_wrapper integration**, we can still test:

1. **VHDL Syntax**: Quartus synthesis ✅
2. **Resource Usage**: Compilation reports ✅
3. **Timing Analysis**: SDC constraints ✅

**Cannot test**:
1. ❌ F-line instruction execution
2. ❌ PMOVE functionality
3. ❌ MMU register access
4. ❌ System stability with MC68030

### Workaround for Testing

**Option**: Create standalone testbench

```vhdl
-- Test harness for TG68K030
entity TG68K030_testbench is
end entity;

architecture tb of TG68K030_testbench is
    -- Instantiate TG68K030
    -- Provide stimulus
    -- Check responses
end architecture;
```

**Benefit**: Can validate TG68K030 in isolation without cpu_wrapper changes

---

## Recommendations

### Short-Term (Current Session)
1. ✅ Document integration gap (this document)
2. ✅ Mark as known limitation
3. ✅ Proceed with build system testing (synthesis)

### Medium-Term (Next Session/Phase)
1. ⏳ Implement Option 3 (Hybrid Approach)
2. ⏳ Create 32-bit to 16-bit data adapter
3. ⏳ Integrate TG68K030 for cpucfg=11 only
4. ⏳ Test on MiSTer hardware

### Long-Term (Future Enhancement)
1. ⏳ Upgrade system to native 32-bit data paths
2. ⏳ Implement burst mode support throughout
3. ⏳ Optimize for MC68030 performance

---

## Conclusion

**Critical Finding**: The MC68030 implementation is **architecturally complete** but **not integrated into the runtime system**.

**Impact**:
- Build system works ✅
- Files compile ✅
- F-line execution doesn't work ❌ (not wired up)

**Path Forward**:
- **Option A**: Proceed with synthesis testing (validates compilation)
- **Option B**: Implement cpu_wrapper integration (enables runtime testing)

**Recommendation**: Document as Phase 11.5 future work, proceed with build system testing for now.

---

**Document Version**: 1.0
**Status**: Integration gap identified and documented
**Next Action**: Decide on integration approach
