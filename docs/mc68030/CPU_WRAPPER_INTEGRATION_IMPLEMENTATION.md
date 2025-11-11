# CPU Wrapper Integration - Implementation Guide

**Date**: 2025-11-11
**Phase**: 11.5 - Runtime Integration
**Status**: Implementation-ready code templates
**Approach**: Minimal F-Line Integration (Simplified Option 2)

---

## Overview

This document provides **ready-to-use code** for integrating MC68030 F-line support into `cpu_wrapper.v`.

**Goal**: Wire F-line decoders and executors to TG68KdotC_Kernel so PMOVE/PFLUSH/PTEST execute instead of trapping.

**Approach**: Add minimal VHDL components to cpu_wrapper.v (Verilog can instantiate VHDL in Quartus)

---

## Implementation Steps

### Step 1: Add F-Line Signals to cpu_wrapper.v

Add these signals after line 138 in `rtl/cpu_wrapper.v`:

```verilog
//========================================
// MC68030 F-line MMU instruction support
//========================================

// F-line decoder outputs
wire fline_is_mmu;
wire fline_is_pmove;
wire fline_is_pflush;
wire fline_is_ptest;
wire fline_exec_req;
wire fline_exec_done;

// PMOVE decoder outputs
wire pmove_is_pmove;
wire pmove_is_pmovefd;
wire pmove_direction;
wire [7:0] pmove_reg_code;
wire [2:0] pmove_ea_mode;
wire [2:0] pmove_ea_reg;
wire [1:0] pmove_size;
wire pmove_sel_tc;
wire pmove_sel_tt0;
wire pmove_sel_tt1;
wire pmove_sel_crp;
wire pmove_sel_srp;
wire pmove_sel_mmusr;

// PFLUSH decoder outputs
wire pflush_is_pflush;
wire [1:0] pflush_mode;
wire [2:0] pflush_fc;

// PTEST decoder outputs
wire ptest_is_ptest;
wire [2:0] ptest_level;
wire [2:0] ptest_fc;
wire ptest_rw;
wire [2:0] ptest_return_reg;

// Executor control
wire pmove_start;
wire pmove_done;
wire pmove_busy;
wire pflush_start;
wire pflush_done;
wire pflush_busy;
wire ptest_start;
wire ptest_done;
wire ptest_busy;

// MMU register interface
wire mmu_reg_read;
wire mmu_reg_write;
wire [3:0] mmu_reg_addr;
wire [1:0] mmu_reg_size;
wire [63:0] mmu_data_in_64;
wire [63:0] mmu_data_out_64;

// MMU register outputs
wire [31:0] tc_reg;
wire [31:0] tt0_reg;
wire [31:0] tt1_reg;
wire [63:0] crp_reg;
wire [63:0] srp_reg;
wire [15:0] mmusr_reg;

// Opcode capture
reg [15:0] fline_opcode;
reg [15:0] fline_extension;
reg fline_opcode_valid;

// Supervisor mode detection
wire cpu_supervisor;
assign cpu_supervisor = (cpustate_p == 2'b01); // Fetch = supervisor

// Stub signals
wire stub_mem_ready;
wire stub_atc_inv_ack;
wire stub_walk_done;

assign stub_mem_ready = 1'b1;
assign stub_atc_inv_ack = 1'b1;
assign stub_walk_done = 1'b1;
```

### Step 2: Modify TG68KdotC_Kernel Instantiation

Update the TG68KdotC_Kernel instantiation (around line 203) to connect F-line ports:

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
    .vbr_out(vbr_p),

    // MC68030 F-line interface (NEW)
    .fline_is_mmu(fline_is_mmu & cpucfg[1]),      // Only enable if cpucfg != 00
    .fline_is_pmove(fline_is_pmove & cpucfg[1]),
    .fline_is_pflush(fline_is_pflush & cpucfg[1]),
    .fline_is_ptest(fline_is_ptest & cpucfg[1]),
    .fline_exec_req(fline_exec_req),
    .fline_exec_done(fline_exec_done)
);
```

### Step 3: Add Opcode Capture Logic

Add after the cpu_wrapper mux logic (around line 287):

```verilog
//========================================
// MC68030 F-line opcode capture
//========================================

always @(posedge clk) begin
    if (~reset | ~reset_out) begin
        fline_opcode <= 16'h0000;
        fline_extension <= 16'h0000;
        fline_opcode_valid <= 1'b0;
    end
    else if (cpucfg[1]) begin  // Only in 68010/68020/68030 modes
        if (cpustate == 2'b00) begin  // Instruction fetch
            fline_opcode <= cpu_dout_p;
            fline_opcode_valid <= 1'b1;
        end
        else if (fline_exec_req && fline_opcode_valid) begin
            fline_extension <= cpu_dout_p;
        end
    end
end
```

### Step 4: Add VHDL Component Declarations

Add after the fx68k instantiation (around line 267):

```verilog
//========================================
// MC68030 F-line Component Instantiations
//========================================

// Conditional compilation: only include if cpucfg supports 68030
generate
    if (1) begin : mc68030_fline_support

        //----------------------------------
        // PMOVE Decoder
        //----------------------------------
        TG68K030_PMOVE_Decoder pmove_decoder
        (
            .clk(clk),
            .reset(~reset),
            .opcode(fline_opcode),
            .extension(fline_extension),
            .opcode_valid(fline_opcode_valid),
            .supervisor(cpu_supervisor),
            .is_pmove(pmove_is_pmove),
            .is_pmovefd(pmove_is_pmovefd),
            .pmove_direction(pmove_direction),
            .pmove_reg_code(pmove_reg_code),
            .pmove_ea_mode(pmove_ea_mode),
            .pmove_ea_reg(pmove_ea_reg),
            .pmove_size(pmove_size),
            .pmove_sel_tc(pmove_sel_tc),
            .pmove_sel_tt0(pmove_sel_tt0),
            .pmove_sel_tt1(pmove_sel_tt1),
            .pmove_sel_crp(pmove_sel_crp),
            .pmove_sel_srp(pmove_sel_srp),
            .pmove_sel_mmusr(pmove_sel_mmusr),
            .illegal_instr(),
            .priv_violation()
        );

        //----------------------------------
        // PFLUSH Decoder
        //----------------------------------
        TG68K030_PFLUSH_Decoder pflush_decoder
        (
            .clk(clk),
            .reset(~reset),
            .opcode(fline_opcode),
            .extension(fline_extension),
            .opcode_valid(fline_opcode_valid),
            .supervisor(cpu_supervisor),
            .is_pflush(pflush_is_pflush),
            .pflush_mode(pflush_mode),
            .pflush_fc(pflush_fc),
            .illegal_instr(),
            .priv_violation()
        );

        //----------------------------------
        // PTEST Decoder
        //----------------------------------
        TG68K030_PTEST_Decoder ptest_decoder
        (
            .clk(clk),
            .reset(~reset),
            .opcode(fline_opcode),
            .extension(fline_extension),
            .opcode_valid(fline_opcode_valid),
            .supervisor(cpu_supervisor),
            .is_ptest(ptest_is_ptest),
            .ptest_level(ptest_level),
            .ptest_fc(ptest_fc),
            .ptest_rw(ptest_rw),
            .ptest_return_reg(ptest_return_reg),
            .illegal_instr(),
            .priv_violation()
        );

        //----------------------------------
        // Combine decoder outputs
        //----------------------------------
        assign fline_is_pmove = pmove_is_pmove;
        assign fline_is_pflush = pflush_is_pflush;
        assign fline_is_ptest = ptest_is_ptest;
        assign fline_is_mmu = pmove_is_pmove | pflush_is_pflush | ptest_is_ptest;

        //----------------------------------
        // MMU Registers
        //----------------------------------
        TG68K030_MMU_Registers mmu_regs
        (
            .clk(clk),
            .reset(~reset),
            .supervisor(cpu_supervisor),
            .reg_addr(mmu_reg_addr),
            .reg_write(mmu_reg_write),
            .reg_read(mmu_reg_read),
            .reg_size(mmu_reg_size),
            .data_in(mmu_data_out_64),    // From executor
            .data_out(mmu_data_in_64),    // To executor
            .tc_out(tc_reg),
            .tt0_out(tt0_reg),
            .tt1_out(tt1_reg),
            .crp_out(crp_reg),
            .srp_out(srp_reg),
            .mmusr_out(mmusr_reg)
        );

        //----------------------------------
        // PMOVE Executor
        //----------------------------------
        TG68K030_PMOVE_Execute pmove_exec
        (
            .clk(clk),
            .reset(~reset),
            .pmove_start(pmove_start),
            .pmove_direction(pmove_direction),
            .pmove_fd(pmove_is_pmovefd),
            .pmove_size(pmove_size),
            .pmove_sel_tc(pmove_sel_tc),
            .pmove_sel_tt0(pmove_sel_tt0),
            .pmove_sel_tt1(pmove_sel_tt1),
            .pmove_sel_crp(pmove_sel_crp),
            .pmove_sel_srp(pmove_sel_srp),
            .pmove_sel_mmusr(pmove_sel_mmusr),
            .mem_addr(32'h00000000),      // TODO: Connect EA
            .mem_data_in(32'h00000000),
            .mem_data_out(),
            .mem_read(),
            .mem_write(),
            .mem_size(),
            .mem_ready(stub_mem_ready),
            .mmu_data_in(mmu_data_in_64),
            .mmu_data_out(mmu_data_out_64),
            .mmu_reg_addr(mmu_reg_addr),
            .mmu_read(mmu_reg_read),
            .mmu_write(mmu_reg_write),
            .mmu_size(mmu_reg_size),
            .atc_flush(),
            .atc_flush_all(),
            .pmove_done(pmove_done),
            .pmove_busy(pmove_busy)
        );

        //----------------------------------
        // PFLUSH Executor (Stub)
        //----------------------------------
        TG68K030_PFLUSH_Execute pflush_exec
        (
            .clk(clk),
            .reset(~reset),
            .pflush_start(pflush_start),
            .pflush_mode(pflush_mode),
            .pflush_fc(pflush_fc),
            .atc_inv_addr(32'h00000000),
            .atc_inv_req(),
            .atc_inv_ack(stub_atc_inv_ack),
            .pflush_done(pflush_done),
            .pflush_busy(pflush_busy)
        );

        //----------------------------------
        // PTEST Executor (Stub)
        //----------------------------------
        TG68K030_PTEST_Execute ptest_exec
        (
            .clk(clk),
            .reset(~reset),
            .ptest_start(ptest_start),
            .ptest_level(ptest_level),
            .ptest_fc(ptest_fc),
            .ptest_rw(ptest_rw),
            .test_addr(32'h00000000),
            .atc_hit(),
            .atc_entry(),
            .walk_start(),
            .walk_done(stub_walk_done),
            .walk_result(16'h0000),
            .mmusr_update(),
            .mmusr_value(),
            .return_reg(ptest_return_reg),
            .return_value(),
            .return_write(),
            .ptest_done(ptest_done),
            .ptest_busy(ptest_busy)
        );

        //----------------------------------
        // Execution Coordinator
        //----------------------------------
        reg pmove_start_r;
        reg pflush_start_r;
        reg ptest_start_r;
        reg fline_exec_done_r;

        always @(posedge clk) begin
            if (~reset) begin
                pmove_start_r <= 1'b0;
                pflush_start_r <= 1'b0;
                ptest_start_r <= 1'b0;
                fline_exec_done_r <= 1'b0;
            end
            else if (fline_exec_req && !fline_exec_done_r) begin
                // Start appropriate executor
                if (fline_is_pmove && !pmove_busy) begin
                    pmove_start_r <= 1'b1;
                end
                else if (fline_is_pflush && !pflush_busy) begin
                    pflush_start_r <= 1'b1;
                end
                else if (fline_is_ptest && !ptest_busy) begin
                    ptest_start_r <= 1'b1;
                end

                // Signal completion when executor done
                fline_exec_done_r <= pmove_done | pflush_done | ptest_done;
            end
            else begin
                pmove_start_r <= 1'b0;
                pflush_start_r <= 1'b0;
                ptest_start_r <= 1'b0;
                fline_exec_done_r <= 1'b0;
            end
        end

        assign pmove_start = pmove_start_r;
        assign pflush_start = pflush_start_r;
        assign ptest_start = ptest_start_r;
        assign fline_exec_done = fline_exec_done_r;

    end  // mc68030_fline_support
    else begin : no_fline_support
        // Tie off signals if not enabled
        assign fline_is_mmu = 1'b0;
        assign fline_is_pmove = 1'b0;
        assign fline_is_pflush = 1'b0;
        assign fline_is_ptest = 1'b0;
        assign fline_exec_done = 1'b0;
    end
endgenerate
```

---

## Testing After Integration

### Synthesis Test

```bash
quartus_map Minimig
```

**Expected**:
- ✅ All VHDL components found
- ✅ Signals properly connected
- ✅ No port mismatch errors
- ⚠️ Warnings about unused signals (stub interfaces) - OK

### Functional Test (on MiSTer)

1. **Set cpucfg=11** (68030 mode)
2. **Run PMOVE test**:
```assembly
    PMOVE  TC,D0      ; Should execute, not trap
    RTS
```
3. **Expected**: No illegal instruction exception

---

## Integration Checklist

- [ ] Add F-line signal declarations
- [ ] Update TG68KdotC_Kernel instantiation with F-line ports
- [ ] Add opcode capture logic
- [ ] Add VHDL component instantiations (decoders, executors, registers)
- [ ] Add execution coordinator logic
- [ ] Compile with Quartus
- [ ] Check synthesis report for errors
- [ ] Test on MiSTer hardware

---

## Estimated Code Changes

| File | Lines Added | Lines Modified |
|------|-------------|----------------|
| cpu_wrapper.v | ~350 | ~10 |
| **Total** | **~360 lines** | |

---

## Expected Resource Impact

| Resource | Before | After | Increase |
|----------|--------|-------|----------|
| ALMs | ~2,500 | ~3,200 | +700 (~28%) |
| Registers | ~3,000 | ~3,200 | +200 (~7%) |
| **FPGA %** | **~8%** | **~10%** | **+2%** |

Still well within Cyclone V capacity (32,070 ALMs).

---

## Known Limitations After Integration

Even after this integration:

- ✅ PMOVE register access works (TC, TT0, TT1, CRP, SRP, MMUSR)
- ⚠️ PMOVE memory EA operations don't work (mem interface stub)
- ⚠️ PFLUSH recognized but doesn't flush ATC (stub)
- ⚠️ PTEST recognized but doesn't perform translation (stub)
- ❌ MMU translation not active (requires full TG68K030 wrapper)
- ❌ Caches not active
- ❌ Burst mode not available

**But**: F-line instructions will execute instead of trapping!

---

## Next Steps After Integration

1. **Test PMOVE** register access functionality
2. **Connect EA calculation** for PMOVE memory operations
3. **Connect ATC** invalidation for PFLUSH
4. **Connect table walker** for PTEST
5. **Full TG68K030 integration** for MMU/caches/burst

---

## Troubleshooting

### Error: Can't find entity "TG68K030_PMOVE_Decoder"

**Solution**: Verify `TG68K030.qip` is included in `files.qip` (should be after commit 83fa6a1)

### Error: Port mismatch on TG68KdotC_Kernel

**Solution**: Verify TG68KdotC_Kernel has F-line ports (modified in Phase 10)

### Warning: Signal 'stub_mem_ready' always 1

**Solution**: Expected - these are stub signals for incomplete interfaces

---

## Summary

This implementation adds **minimal MC68030 F-line support** to cpu_wrapper.v:

**Adds**:
- F-line decoder instantiations (PMOVE, PFLUSH, PTEST)
- F-line executor instantiations
- MMU register module
- Execution coordinator
- ~350 lines of Verilog

**Enables**:
- ✅ PMOVE instruction execution
- ✅ PFLUSH instruction recognition
- ✅ PTEST instruction recognition
- ✅ MMU register access via PMOVE

**Still Missing** (for future work):
- Memory interface for EA-based PMOVE
- ATC integration for PFLUSH
- Table walker for PTEST
- Full MMU translation

**Effort**: 2-3 hours to implement + 1-2 hours to test

---

*Document Version*: 1.0
*Ready for Implementation*: Yes ✅
*Tested*: No (requires Quartus)
