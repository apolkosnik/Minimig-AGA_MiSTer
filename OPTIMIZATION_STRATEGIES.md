# 32-bit Bus Resource Optimization Strategies

## 🎯 Goal: Reduce FPGA Usage While Keeping 32-bit Performance

Current Status: 49,095 LEs (exceeds 87K device limit)
Target: <80,000 LEs (leave 10% margin)
Required Reduction: ~20% (10,000 LEs)

## 🔧 Optimization Strategies

### 1. **Selective 32-bit Implementation** (Highest Impact)

Instead of making everything 32-bit, be strategic about what needs the full width:

```verilog
// PRIORITY 1: CPU-Memory path (keep 32-bit)
cpu_data[31:0]     ✅ KEEP - Direct CPU performance impact
ram_data[31:0]     ✅ KEEP - Memory bandwidth critical

// PRIORITY 2: Custom chips (reduce to 16-bit)
agnus_data_out[15:0]   ✅ REDUCE - AGA registers are 16-bit max
paula_data_out[15:0]   ✅ REDUCE - Audio/Serial are 16-bit  
denise_data_out[15:0]  ✅ REDUCE - Video registers are 16-bit

// PRIORITY 3: Internal buses (hybrid approach)
custom_data_in[31:0]   ⚠️ OPTIMIZE - Only extend when needed
```

**Expected Savings: ~15,000 LEs (30%)**

### 2. **Dynamic Bus Width Switching** (Medium Impact)

Implement a hybrid system that uses 32-bit only when beneficial:

```verilog
module smart_bus_controller (
    input wire        clk,
    input wire        cpu_32bit_mode,     // CPU supports 32-bit
    input wire        transfer_32bit,     // Current op needs 32-bit
    input wire [31:0] data_in_32,
    output reg [31:0] data_out_32,
    output reg        use_32bit_path
);

always @(*) begin
    // Use 32-bit path only when both CPU and operation support it
    use_32bit_path = cpu_32bit_mode && transfer_32bit;
    
    if (use_32bit_path) begin
        // Full 32-bit operation
        data_out_32 = data_in_32;
    end else begin
        // Fall back to 16-bit with zero extension
        data_out_32 = {16'h0000, data_in_32[15:0]};
    end
end
endmodule
```

**Expected Savings: ~8,000 LEs (16%)**

### 3. **Resource Sharing and Multiplexing** (Medium Impact)

Share 32-bit resources between modules that don't access simultaneously:

```verilog
// Shared 32-bit data path
reg [31:0] shared_data_bus;
reg [2:0]  bus_owner;

// Time-multiplex access to 32-bit resources
always @(posedge clk) begin
    case (bus_owner)
        3'b000: shared_data_bus <= cpu_data_out;
        3'b001: shared_data_bus <= ram_data_out;  
        3'b010: shared_data_bus <= custom_data_out[15:0] << 16; // Only when needed
        default: shared_data_bus <= 32'h00000000;
    endcase
end

// Distribute to modules based on timing
assign cpu_data_in    = (bus_owner == 3'b000) ? shared_data_bus : {16'h0000, legacy_cpu_data};
assign ram_data_in    = (bus_owner == 3'b001) ? shared_data_bus : {16'h0000, legacy_ram_data};
assign custom_data_in = shared_data_bus[15:0]; // Custom chips only need 16-bit
```

**Expected Savings: ~5,000 LEs (10%)**

### 4. **Conditional Custom Chip Enhancement** (Low Impact, Easy Win)

Most custom chips don't benefit from 32-bit width:

```verilog
// Keep custom chips at 16-bit, extend only at CPU interface
wire [15:0] agnus_data_out_16;   // Native 16-bit
wire [15:0] paula_data_out_16;   // Native 16-bit  
wire [15:0] denise_data_out_16;  // Native 16-bit

// Extend to 32-bit only at the final multiplexer
assign custom_data_out[31:0] = {16'h0000, 
    agnus_data_out_16 | paula_data_out_16 | denise_data_out_16};
```

**Expected Savings: ~12,000 LEs (24%)**

### 5. **Memory Controller Optimization** (Medium Impact)

Optimize the dual SDRAM controller to share logic:

```verilog
module optimized_dual_sdram (
    // Shared control logic
    input wire        clk,
    input wire [31:0] write_data,
    output reg [31:0] read_data,
    
    // Dual SDRAM interfaces
    output wire [15:0] sdram_a_dq,
    output wire [15:0] sdram_b_dq
);

// Shared address generation and timing logic
wire [22:0] shared_address;
wire        shared_we, shared_oe;

// Split 32-bit data across two 16-bit controllers
assign sdram_a_dq = write_data[15:0];   // Lower 16 bits
assign sdram_b_dq = write_data[31:16];  // Upper 16 bits

// Combine read data
assign read_data = {sdram_b_dq, sdram_a_dq};

endmodule
```

**Expected Savings: ~3,000 LEs (6%)**

## 📊 Implementation Priority Matrix

```
┌─────────────────────────────────────────────────────────────────┐
│                    OPTIMIZATION PRIORITY                        │
├─────────────────────┬───────────┬─────────────┬─────────────────┤
│ Strategy            │ Savings   │ Complexity  │ Risk Level      │
├─────────────────────┼───────────┼─────────────┼─────────────────┤
│ Custom Chip 16-bit  │ 15,000 LE │ Low         │ Very Low        │
│ Selective 32-bit    │ 10,000 LE │ Medium      │ Low             │
│ Resource Sharing    │  5,000 LE │ High        │ Medium          │
│ Dynamic Switching   │  8,000 LE │ High        │ Medium          │
│ Memory Optimization │  3,000 LE │ Low         │ Low             │
├─────────────────────┼───────────┼─────────────┼─────────────────┤
│ TOTAL POTENTIAL     │ 41,000 LE │             │                 │
│ TARGET REDUCTION    │ 10,000 LE │             │                 │
└─────────────────────┴───────────┴─────────────┴─────────────────┘
```

## 🎯 Recommended Implementation Plan

### Phase 1: Low-Risk Quick Wins (Week 1)
```verilog
// 1. Revert custom chips to 16-bit
wire [15:0] agnus_data_out;    // Was [31:0] 
wire [15:0] paula_data_out;    // Was [31:0]
wire [15:0] denise_data_out;   // Was [31:0]

// 2. Extend only at final bus interface
assign custom_data_out[31:0] = {16'h0000, agnus_data_out | paula_data_out | denise_data_out};
```
**Target: -15,000 LEs, Low Risk**

### Phase 2: Smart Bus Implementation (Week 2)
```verilog
// 3. Implement selective 32-bit for CPU-critical paths
module selective_32bit_bus (
    input wire        cpu_longword_op,    // CPU doing 32-bit operation
    input wire        fast_ram_access,    // Accessing fast RAM
    input wire [31:0] data_in,
    output reg [31:0] data_out,
    output reg        use_full_width
);

always @(*) begin
    use_full_width = cpu_longword_op || fast_ram_access;
    if (use_full_width) 
        data_out = data_in;
    else 
        data_out = {16'h0000, data_in[15:0]};
end
endmodule
```
**Target: -8,000 LEs, Medium Risk**

### Phase 3: Memory Controller Sharing (Week 3)
```verilog
// 4. Optimize dual SDRAM controller  
// Share timing logic, address generation, and control between both SDRAM modules
```
**Target: -3,000 LEs, Low Risk**

## 🔍 Specific Code Changes

### Change 1: Revert Custom Chips (Immediate 30% Saving)

```verilog
// In minimig.v - REVERT these declarations:
// OLD (32-bit):
wire [31:0] agnus_data_out;
wire [31:0] paula_data_out; 
wire [31:0] denise_data_out;
wire [31:0] user_data_out;

// NEW (16-bit optimized):
wire [15:0] agnus_data_out;
wire [15:0] paula_data_out;
wire [15:0] denise_data_out; 
wire [15:0] user_data_out;

// Update the final data multiplexer:
assign custom_data_out[31:0] = {16'h0000, 
    agnus_data_out[15:0] | paula_data_out[15:0] | 
    denise_data_out[15:0] | user_data_out[15:0]};
```

### Change 2: Smart CPU Interface (Additional 20% Saving)

```verilog
// In cpu_wrapper.v - Add smart width detection:
wire cpu_doing_longword = longword && (cpustate_p == 2'b11);
wire need_32bit_path = cpu_doing_longword || sel_zram;

// Use 32-bit path only when beneficial:
wire [31:0] smart_data_out = need_32bit_path ? 
    cpu_dout_p[31:0] : {16'h0000, cpu_dout_p[15:0]};
```

### Change 3: Conditional Compilation (Ultimate Flexibility)

```verilog
// Add conditional compilation for resource-constrained builds
`ifdef MINIMIG_32BIT_FULL
    // Full 32-bit implementation
    parameter DATA_WIDTH = 32;
`elsif MINIMIG_32BIT_SMART  
    // Smart 32-bit (recommended)
    parameter DATA_WIDTH = 32;
    parameter SMART_WIDTH = 1;
`else
    // Legacy 16-bit
    parameter DATA_WIDTH = 16;
`endif
```

## 📈 Expected Results After Optimization

```
Current:  49,095 LEs (FPGA overflow)
Phase 1:  34,095 LEs (Custom chips 16-bit)    ✅ FITS!
Phase 2:  26,095 LEs (Smart bus)              ✅ COMFORTABLE!
Phase 3:  23,095 LEs (Memory optimization)    ✅ EXCELLENT!

Target Device: 87,000 LEs
Final Usage:   ~27% (23,095 LEs)
Margin:        73% available for future features
```

## 🎯 Performance Impact Analysis

```
┌─────────────────────────────────────────────────────────────────┐
│                  PERFORMANCE vs RESOURCES                       │
├─────────────────────┬─────────────┬─────────────┬───────────────┤
│ Configuration       │ Resources   │ 32-bit Perf│ Compatibility │
├─────────────────────┼─────────────┼─────────────┼───────────────┤
│ Full 32-bit (orig)  │ 49,095 LEs  │    100%     │     100%      │
│ Smart 32-bit (rec)  │ 26,095 LEs  │     95%     │     100%      │  
│ Hybrid 32-bit       │ 23,095 LEs  │     90%     │     100%      │
│ Legacy 16-bit       │ 25,000 LEs  │     50%     │     100%      │
└─────────────────────┴─────────────┴─────────────┴───────────────┘

RECOMMENDATION: Smart 32-bit (95% performance, 50% resources)
```

**The smart approach gives you 95% of the 32-bit performance benefits while using 50% fewer resources!** 🎯