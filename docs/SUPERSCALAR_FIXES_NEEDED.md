# FX68K Superscalar - Issues and Fixes Needed

## Critical Issues (Must Fix Before Testing)

### 1. ❌ Branch Logic Uninitialized
**File:** fx68k_superscalar.sv:62-64
**Issue:** Variables declared but never assigned
```systemverilog
logic branch_taken;
logic [31:0] branch_target;
```
**Impact:** PC fetch logic uses undefined values, core won't boot

**Fix:**
```systemverilog
// Add branch resolution logic
always_ff @(posedge clk) begin
    if (reset) begin
        branch_taken <= 1'b0;
        branch_target <= 32'h0;
    end else begin
        // Check ROB head for branch misprediction
        if (reorder_buffer[rob_head].valid &&
            reorder_buffer[rob_head].complete &&
            reorder_buffer[rob_head].inst.uop_type == UOPTYPE_BRANCH) begin
            branch_taken <= reorder_buffer[rob_head].exception; // Misprediction flag
            branch_target <= reorder_buffer[rob_head].result;   // Actual target
        end else begin
            branch_taken <= 1'b0;
        end
    end
end
```

### 2. ❌ Scoreboard Never Updated
**File:** fx68k_superscalar.sv:201-236
**Issue:** Scoreboard is read but never written
```systemverilog
function logic check_operand_ready(logic [3:0] reg_id, logic is_areg);
    // Reads scoreboard.ready but scoreboard never gets updated!
```

**Fix:** Add scoreboard update logic:
```systemverilog
// Update scoreboard on instruction decode
always_ff @(posedge clk) begin
    if (reset) begin
        for (int i = 0; i < 8; i++) begin
            data_reg_scoreboard[i] <= '{valid: 1'b0, producer: '0, ready: 1'b1};
            addr_reg_scoreboard[i] <= '{valid: 1'b0, producer: '0, ready: 1'b1};
        end
    end else begin
        // Mark destination registers as busy when instruction allocated to ROB
        if (decoded[0].valid && decoded[0].dest_reg != 0) begin
            if (decoded[0].dest_is_areg)
                addr_reg_scoreboard[decoded[0].dest_reg[2:0]] <=
                    '{valid: 1'b1, producer: rob_tail, ready: 1'b0};
            else
                data_reg_scoreboard[decoded[0].dest_reg[2:0]] <=
                    '{valid: 1'b1, producer: rob_tail, ready: 1'b0};
        end

        // Mark registers ready when ROB commits
        if (reorder_buffer[rob_head].valid && reorder_buffer[rob_head].complete) begin
            if (reorder_buffer[rob_head].inst.dest_reg != 0) begin
                if (reorder_buffer[rob_head].inst.dest_is_areg)
                    addr_reg_scoreboard[reorder_buffer[rob_head].inst.dest_reg[2:0]].ready <= 1'b1;
                else
                    data_reg_scoreboard[reorder_buffer[rob_head].inst.dest_reg[2:0]].ready <= 1'b1;
            end
        end
    end
end
```

### 3. ❌ Missing ROB ID Tracking
**File:** fx68k_superscalar.sv:157-163
**Issue:** Execution units don't know which ROB entry they're working on
```systemverilog
logic [ROB_ENTRIES-1:0] eu_rob_id[NUM_EXEC_UNITS]; // Declared but never assigned!
```

**Fix:** Track ROB ID on issue:
```systemverilog
// In issue logic
always_ff @(posedge clk) begin
    if (can_issue[0] && issue_to_eu[0] == EU_ALU0) begin
        eu_rob_id[EU_ALU0] <= inst_queue[iq_head].rob_id;
    end
end

// Update ALU module interface to accept rob_id
module fx68k_ss_alu(
    // ... existing ports ...
    input [ROB_ENTRIES-1:0] rob_id_in,
    output logic [ROB_ENTRIES-1:0] rob_id_out
);
    // Latch rob_id and output when complete
    always_ff @(posedge clk) begin
        if (issue) rob_id_out <= rob_id_in;
    end
endmodule
```

### 4. ❌ Memory Interface Broken
**File:** fx68k_superscalar.sv:14-20
**Issue:** Memory signals declared but never driven
```systemverilog
output logic read_req,    // Never assigned!
output logic write_req,   // Never assigned!
input data_valid,         // Never checked!
```

**Fix:** Needs LSU implementation (see below)

### 5. ❌ Bus Adapter Data Capture Bug
**File:** fx68k_wrapper_ss.sv:289
**Issue:** Captures data during WRITE instead of READ
```systemverilog
S4: begin
    if (~DTACKn || ~VPAn) begin
        state <= S6;
        if (~eRWn) begin  // BUG: eRWn=0 means WRITE, not READ!
            ss_data_in <= iEdb;
```

**Fix:**
```systemverilog
if (eRWn) begin  // eRWn=1 means READ
    ss_data_in <= iEdb;
end
```

## High Priority Issues

### 6. ⚠️ D0 Register Blocked
**File:** fx68k_superscalar.sv:172-180
**Issue:** Cannot write to D0 or A0
```systemverilog
if (reorder_buffer[rob_head].inst.dest_reg != 0) begin
    // This prevents writing to register 0!
```

**Fix:**
```systemverilog
// Remove the check - all registers including 0 should be writable
write_reg(
    reorder_buffer[rob_head].inst.dest_reg,
    reorder_buffer[rob_head].inst.dest_is_areg,
    reorder_buffer[rob_head].result
);
```

### 7. ⚠️ Missing Execution Units
**File:** fx68k_superscalar.sv:149-165
**Issue:** AGU and LSU declared but not implemented

**Fix:** Implement missing units:

**AGU (Address Generation Unit):**
```systemverilog
module fx68k_ss_agu(
    input clk, reset,
    input issue,
    input decoded_inst_t inst,
    input [31:0] base_addr,
    input [31:0] index,
    output logic busy,
    output logic complete,
    output logic [31:0] result
);
    always_ff @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            complete <= 1'b0;
            result <= 32'h0;
        end else if (issue) begin
            // Calculate effective address
            // Basic: base + index + displacement
            result <= base_addr + index + {{16{inst.immediate[15]}}, inst.immediate};
            busy <= 1'b1;
            complete <= 1'b1; // AGU is single-cycle
        end else begin
            busy <= 1'b0;
            complete <= 1'b0;
        end
    end
endmodule
```

**LSU (Load-Store Unit):**
```systemverilog
module fx68k_ss_lsu(
    input clk, reset,
    input issue,
    input decoded_inst_t inst,
    input [31:0] address,
    input [31:0] store_data,

    // Memory interface
    output logic [23:1] mem_addr,
    output logic [15:0] mem_data_out,
    input [15:0] mem_data_in,
    output logic mem_read_req,
    output logic mem_write_req,
    input mem_data_valid,

    output logic busy,
    output logic complete,
    output logic [31:0] result
);
    typedef enum logic [1:0] {
        IDLE, REQUEST, WAIT, DONE
    } lsu_state_t;

    lsu_state_t state;

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            busy <= 1'b0;
            complete <= 1'b0;
            mem_read_req <= 1'b0;
            mem_write_req <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    complete <= 1'b0;
                    if (issue) begin
                        state <= REQUEST;
                        busy <= 1'b1;
                        mem_addr <= address[23:1];
                        if (inst.uop_type == UOPTYPE_LOAD) begin
                            mem_read_req <= 1'b1;
                        end else begin // STORE
                            mem_write_req <= 1'b1;
                            mem_data_out <= store_data[15:0];
                        end
                    end
                end

                REQUEST: begin
                    state <= WAIT;
                    mem_read_req <= 1'b0;
                    mem_write_req <= 1'b0;
                end

                WAIT: begin
                    if (mem_data_valid) begin
                        if (inst.uop_type == UOPTYPE_LOAD)
                            result <= {16'h0, mem_data_in};
                        state <= DONE;
                    end
                end

                DONE: begin
                    complete <= 1'b1;
                    busy <= 1'b0;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
```

### 8. ⚠️ Incomplete Dual-Issue
**File:** fx68k_superscalar.sv:133-148
**Issue:** Only issues 1 instruction/cycle

**Fix:**
```systemverilog
// Enhanced issue logic for dual-issue
always_comb begin
    can_issue[0] = 1'b0;
    can_issue[1] = 1'b0;
    issue_to_eu[0] = 0;
    issue_to_eu[1] = 0;

    integer found = 0;

    // Scan IQ for up to 2 ready instructions
    for (int i = 0; i < IQ_ENTRIES && found < 2; i++) begin
        if (inst_queue[i].valid &&
            inst_queue[i].src1_ready &&
            inst_queue[i].src2_ready &&
            !eu_busy[inst_queue[i].inst.exec_unit]) begin

            can_issue[found] = 1'b1;
            issue_to_eu[found] = inst_queue[i].inst.exec_unit;
            found++;

            // Mark EU as busy for second issue check
            eu_busy[inst_queue[i].inst.exec_unit] = 1'b1;
        end
    end
end
```

### 9. ⚠️ Second Instruction ROB Allocation
**File:** fx68k_superscalar.sv:105-124
**Issue:** Second instruction added to IQ but no ROB entry

**Fix:**
```systemverilog
// Allocate ROB entries for both decoded instructions
if (decoded[0].valid && rob_count < ROB_ENTRIES) begin
    reorder_buffer[rob_tail] <= '{
        valid: 1'b1,
        complete: 1'b0,
        pc: decoded[0].pc,
        inst: decoded[0],
        result: 32'h0,
        ccr_result: 8'h0,
        exception: 1'b0,
        exception_vector: 4'h0
    };
    rob_tail <= rob_tail + 1;
    rob_count <= rob_count + 1;
end

// ADD: Second instruction ROB allocation
if (decoded[1].valid && rob_count < (ROB_ENTRIES - 1)) begin
    reorder_buffer[rob_tail + 1] <= '{
        valid: 1'b1,
        complete: 1'b0,
        pc: decoded[1].pc,
        inst: decoded[1],
        result: 32'h0,
        ccr_result: 8'h0,
        exception: 1'b0,
        exception_vector: 4'h0
    };
    rob_tail <= rob_tail + 2;  // Increment by 2!
    rob_count <= rob_count + 2;
end
```

### 10. ⚠️ EU Busy Signals Not Connected
**File:** fx68k_superscalar.sv:57
**Issue:** `eu_busy` read but ALU modules don't set it

**Fix:** Connect busy signals:
```systemverilog
// In execution unit instantiation
fx68k_ss_alu alu0 (
    // ... existing ports ...
    .busy(eu_busy[EU_ALU0]),  // Connect to array element
    // ...
);
```

### 11. ⚠️ Incomplete Instruction Decoder
**File:** fx68k_superscalar.sv:284-323
**Issue:** Only ~5 instruction types decoded

**Fix:** Needs comprehensive decoder implementation (see detailed fix below)

### 12. ⚠️ Config Parameters Unused
**File:** fx68k_config.svh vs fx68k_superscalar.sv
**Issue:** Config defines ROB_SIZE=8 but hardcoded in module

**Fix:**
```systemverilog
// In fx68k_superscalar.sv, use parameters from config
`include "fx68k_config.svh"

`ifdef FX68K_SUPERSCALAR
    localparam ROB_ENTRIES = `SS_ROB_SIZE;
    localparam IQ_ENTRIES = `SS_IQ_SIZE;
    localparam NUM_EXEC_UNITS = `SS_NUM_EU;
`else
    // Defaults
    localparam ROB_ENTRIES = 8;
    localparam IQ_ENTRIES = 8;
    localparam NUM_EXEC_UNITS = 4;
`endif
```

## Medium Priority Issues

### 13. 📝 No Operand Bypass
**Impact:** Dependent instructions stall unnecessarily

**Fix:** Add forwarding network:
```systemverilog
// Operand forwarding logic
function logic [31:0] get_operand(logic [3:0] reg_id, logic is_areg);
    // Check if any in-flight instruction will produce this register
    for (int i = 0; i < ROB_ENTRIES; i++) begin
        if (reorder_buffer[i].valid &&
            reorder_buffer[i].complete &&
            reorder_buffer[i].inst.dest_reg == reg_id &&
            reorder_buffer[i].inst.dest_is_areg == is_areg) begin
            return reorder_buffer[i].result; // Forward from ROB
        end
    end
    // No forwarding, read from register file
    return read_reg(reg_id, is_areg);
endfunction
```

### 14. 📝 No Exception Handling
**File:** fx68k_superscalar.sv:172-180
**Issue:** ROB exception field never processed

**Fix:**
```systemverilog
// In commit stage
if (reorder_buffer[rob_head].valid && reorder_buffer[rob_head].complete) begin
    if (reorder_buffer[rob_head].exception) begin
        // Flush pipeline
        for (int i = 0; i < IQ_ENTRIES; i++)
            inst_queue[i].valid <= 1'b0;
        for (int i = 0; i < ROB_ENTRIES; i++)
            reorder_buffer[i].valid <= 1'b0;

        // Jump to exception vector
        branch_taken <= 1'b1;
        branch_target <= {28'h0, reorder_buffer[rob_head].exception_vector} << 2;
    end
    // ... normal commit ...
end
```

### 15. 📝 Performance Counters Broken
**File:** fx68k_wrapper_ss.sv:84-98
**Issue:** inst_count never incremented

**Fix:**
```systemverilog
// In wrapper, connect to commit stage
logic inst_committed;
assign inst_committed = ss_core.reorder_buffer[ss_core.rob_head].valid &&
                        ss_core.reorder_buffer[ss_core.rob_head].complete;

always_ff @(posedge clk) begin
    if (inst_committed) begin
        inst_count <= inst_count + 1;
    end
end
```

## Low Priority (Enhancements)

### 16. Register File Initialization
**Issue:** Registers start with undefined values

**Fix:**
```systemverilog
always_ff @(posedge clk) begin
    if (reset) begin
        for (int i = 0; i < 8; i++) begin
            data_regs[i] <= 32'h0;
            addr_regs[i] <= 32'h0;
        end
        usp <= 32'h0;
        ssp <= 32'h0;
        sr <= 16'h2700; // Supervisor mode, interrupts disabled
    end
    // ... rest of logic
end
```

### 17. Cache Implementation Missing
**Issue:** Config mentions cache but not implemented

**Fix:** Add simple direct-mapped cache:
```systemverilog
module simple_cache #(
    parameter SIZE = 4096,
    parameter LINE_SIZE = 32
)(
    input clk, reset,
    input [23:0] addr,
    input [15:0] data_in,
    output logic [15:0] data_out,
    input read_req,
    output logic hit,
    output logic miss
);
    // Cache implementation here
endmodule
```

### 18. Branch Predictor Missing
**Issue:** Static prediction mentioned but not implemented

**Fix:** Add simple BTB:
```systemverilog
module branch_predictor(
    input clk, reset,
    input [31:0] pc,
    input is_branch,
    output logic predict_taken,
    output logic [31:0] predict_target,

    // Update on resolution
    input update,
    input [31:0] update_pc,
    input actual_taken,
    input [31:0] actual_target
);
    // 64-entry BTB
    logic [31:0] btb_target[64];
    logic btb_valid[64];

    wire [5:0] index = pc[7:2];

    always_comb begin
        predict_taken = btb_valid[index] && is_branch;
        predict_target = btb_target[index];
    end

    always_ff @(posedge clk) begin
        if (update) begin
            btb_target[update_pc[7:2]] <= actual_target;
            btb_valid[update_pc[7:2]] <= actual_taken;
        end
    end
endmodule
```

## Summary

**Must Fix Before Simulation:**
- Issues 1-5 (Critical)

**Must Fix Before Functional Testing:**
- Issues 6-12 (High Priority)

**Should Fix For Performance:**
- Issues 13-15 (Medium Priority)

**Can Fix Later:**
- Issues 16-18 (Low Priority)

## Estimated Fix Time

- Critical fixes: 4-6 hours
- High priority: 8-12 hours
- Medium priority: 4-6 hours
- Low priority: 4-8 hours

**Total: 20-32 hours of development**

## Testing Strategy

1. **Unit Tests**: Test each execution unit in isolation
2. **Integration Tests**: Test issue/execute/commit pipeline
3. **Instruction Tests**: Run all 68000 instructions
4. **Benchmark Tests**: Dhrystone, etc.
5. **Compatibility Tests**: Run actual Amiga software
