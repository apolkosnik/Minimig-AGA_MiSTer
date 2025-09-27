// Smart Bus Controller for Resource-Optimized 32-bit Implementation
// Uses 32-bit buses only when beneficial, falls back to 16-bit otherwise

module smart_bus_controller
(
    input         clk,
    input         reset,
    
    // CPU interface signals
    input  [31:0] cpu_addr,
    input  [1:0]  cpu_state,    // 0=fetch, 1=idle, 2=read, 3=write
    input         cpu_longword, // CPU supports/requests 32-bit operation
    input  [1:0]  cpu_config,   // CPU type configuration
    
    // Memory access characteristics
    input         chip_ram_access,
    input         fast_ram_access,
    input         rtg_access,
    input         zorro_access,
    
    // Data paths
    input  [31:0] data_in,
    output [31:0] data_out,
    
    // Control outputs
    output reg    use_32bit_path,
    output reg    use_dual_sdram,
    output reg    optimize_bandwidth
);

// CPU capability detection
wire cpu_68020_plus = |cpu_config[1:0]; // Non-zero means 68020+
wire cpu_supports_32bit = cpu_68020_plus && cpu_longword;

// Memory access type analysis
wire needs_high_bandwidth = fast_ram_access || rtg_access || zorro_access;
wire large_sequential_access = (cpu_state == 2'b10 || cpu_state == 2'b11) && cpu_longword;

// Smart 32-bit path decision logic
always @(posedge clk) begin
    if (reset) begin
        use_32bit_path <= 1'b0;
        use_dual_sdram <= 1'b0;  
        optimize_bandwidth <= 1'b0;
    end
    else begin
        // Use 32-bit path when:
        // 1. CPU supports 32-bit AND accessing fast memory
        // 2. Large data transfers regardless of memory type
        // 3. RTG or graphics operations
        use_32bit_path <= (cpu_supports_32bit && needs_high_bandwidth) ||
                         large_sequential_access ||
                         rtg_access;
        
        // Use dual SDRAM for 32-bit operations
        use_dual_sdram <= use_32bit_path;
        
        // Optimize bandwidth for performance-critical operations
        optimize_bandwidth <= use_32bit_path && needs_high_bandwidth;
    end
end

// Data routing with smart width selection
reg [31:0] processed_data;
always @(*) begin
    if (use_32bit_path) begin
        // Full 32-bit operation
        processed_data = data_in;
    end
`ifdef CHIPRAM_32BIT
    else if (!cpu_supports_32bit) begin
        // 16-bit operation with zero extension  
        processed_data = {16'h0000, data_in[15:0]};
`else
    else if (chip_ram_access || (!cpu_supports_32bit)) begin
        // 16-bit operation with zero extension
        processed_data = {16'h0000, data_in[15:0]};
`endif
    end
    else begin
        // Hybrid mode: 24-bit addressing with 16-bit data
        processed_data = {8'h00, data_in[23:0]};
    end
end

assign data_out = processed_data;

// Debug/monitoring outputs (can be optimized away in release)
`ifdef SMART_BUS_DEBUG
reg [31:0] operation_counter;
reg [15:0] bit32_operations;
reg [15:0] bit16_operations;

always @(posedge clk) begin
    if (reset) begin
        operation_counter <= 0;
        bit32_operations <= 0;
        bit16_operations <= 0;
    end
    else if (cpu_state != 2'b01) begin // Not idle
        operation_counter <= operation_counter + 1;
        if (use_32bit_path)
            bit32_operations <= bit32_operations + 1;
        else
            bit16_operations <= bit16_operations + 1;
    end
end
`endif

endmodule