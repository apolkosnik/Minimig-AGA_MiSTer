// Shared SDRAM Controller for Resource-Optimized 32-bit Implementation
// Consolidates control logic for single/dual SDRAM configurations

module shared_sdram_controller
(
    input         clk,
    input         reset,
    
    // Configuration
    input         dual_sdram_enable,  // From smart bus controller
    input         use_32bit_path,     // From smart bus controller
    
    // CPU/Memory interface
    input  [31:0] data_in,
    output [31:0] data_out,
    input  [23:1] addr_in,
    input         read_enable,
    input         write_enable,
    input  [3:0]  byte_enables,  // 4-bit for 32-bit access
    
    // Primary SDRAM interface (always present)
    output [12:0] sdram_a_addr,
    output  [1:0] sdram_a_ba,
    output        sdram_a_cas_n,
    output        sdram_a_ras_n,
    output        sdram_a_we_n,
    output        sdram_a_cs_n,
    output        sdram_a_cke,
    output        sdram_a_dqm_h,
    output        sdram_a_dqm_l,
    inout  [15:0] sdram_a_dq,
    
    // Secondary SDRAM interface (dual SDRAM only)
    output [12:0] sdram_b_addr,
    output  [1:0] sdram_b_ba,
    output        sdram_b_cas_n,
    output        sdram_b_ras_n,
    output        sdram_b_we_n,
    output        sdram_b_cs_n,
    output        sdram_b_cke,
    output        sdram_b_dqm_h,
    output        sdram_b_dqm_l,
    inout  [15:0] sdram_b_dq,
    
    // Status/control
    output        ready,
    output        data_valid
);

// Shared control signals - same for both SDRAM modules
wire [12:0] shared_addr = addr_in[23:11];
wire  [1:0] shared_ba   = addr_in[10:9];
wire        shared_cas_n, shared_ras_n, shared_we_n;
wire        shared_cke, shared_cs_n;

// Data path multiplexing
wire [15:0] data_low  = data_in[15:0];
wire [15:0] data_high = data_in[31:16];

// Byte enable processing
wire        access_low  = |byte_enables[1:0];  // Lower 16 bits needed
wire        access_high = |byte_enables[3:2];  // Upper 16 bits needed

// SDRAM state machine (shared logic)
reg [2:0] state;
reg [3:0] refresh_counter;
reg       data_ready;

localparam IDLE       = 3'b000;
localparam ACTIVATE   = 3'b001;
localparam READ_WRITE = 3'b010;
localparam PRECHARGE  = 3'b011;
localparam REFRESH    = 3'b100;

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        refresh_counter <= 0;
        data_ready <= 0;
    end
    else begin
        case (state)
            IDLE: begin
                data_ready <= 0;
                if (refresh_counter == 0) begin
                    state <= REFRESH;
                    refresh_counter <= 15; // Reset refresh counter
                end
                else if (read_enable || write_enable) begin
                    state <= ACTIVATE;
                    refresh_counter <= refresh_counter - 1;
                end
            end
            
            ACTIVATE: begin
                state <= READ_WRITE;
            end
            
            READ_WRITE: begin
                data_ready <= read_enable;
                state <= PRECHARGE;
            end
            
            PRECHARGE: begin
                data_ready <= 0;
                state <= IDLE;
            end
            
            REFRESH: begin
                state <= IDLE;
            end
        endcase
    end
end

// Generate control signals
assign shared_cas_n = ~(state == READ_WRITE);
assign shared_ras_n = ~(state == ACTIVATE || state == REFRESH);
assign shared_we_n  = ~(write_enable && state == READ_WRITE);
assign shared_cs_n  = (state == IDLE);
assign shared_cke   = ~reset;

// Primary SDRAM (lower 16 bits) - always connected
assign sdram_a_addr  = shared_addr;
assign sdram_a_ba    = shared_ba;
assign sdram_a_cas_n = shared_cas_n;
assign sdram_a_ras_n = shared_ras_n;
assign sdram_a_we_n  = shared_we_n;
assign sdram_a_cs_n  = shared_cs_n || (dual_sdram_enable && !access_low);
assign sdram_a_cke   = shared_cke;
assign sdram_a_dqm_h = ~byte_enables[1];
assign sdram_a_dqm_l = ~byte_enables[0];
assign sdram_a_dq    = write_enable ? data_low : 16'hzzzz;

// Secondary SDRAM (upper 16 bits) - only when dual SDRAM enabled
assign sdram_b_addr  = dual_sdram_enable ? shared_addr  : 13'h0;
assign sdram_b_ba    = dual_sdram_enable ? shared_ba    : 2'b00;
assign sdram_b_cas_n = dual_sdram_enable ? shared_cas_n : 1'b1;
assign sdram_b_ras_n = dual_sdram_enable ? shared_ras_n : 1'b1;
assign sdram_b_we_n  = dual_sdram_enable ? shared_we_n  : 1'b1;
assign sdram_b_cs_n  = dual_sdram_enable ? (shared_cs_n || !access_high) : 1'b1;
assign sdram_b_cke   = dual_sdram_enable ? shared_cke   : 1'b0;
assign sdram_b_dqm_h = dual_sdram_enable ? ~byte_enables[3] : 1'b1;
assign sdram_b_dqm_l = dual_sdram_enable ? ~byte_enables[2] : 1'b1;
assign sdram_b_dq    = (dual_sdram_enable && write_enable) ? data_high : 16'hzzzz;

// Data output assembly
assign data_out = dual_sdram_enable ? {sdram_b_dq, sdram_a_dq} : 
                                     {16'h0000, sdram_a_dq};

// Status outputs
assign ready      = (state == IDLE);
assign data_valid = data_ready;

// Resource optimization: Use same timing parameters
// This saves significant logic compared to separate controllers
parameter tRP  = 3;  // Precharge time
parameter tRCD = 3;  // RAS to CAS delay
parameter tRC  = 9;  // Row cycle time

endmodule