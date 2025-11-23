//------------------------------------------------------------------------------
// MC68060 Branch Prediction Unit
// Simple 4-entry branch target cache with 2-bit saturating counter
//------------------------------------------------------------------------------

module MC68060_BranchUnit
(
    input  wire        clk,
    input  wire        nreset,

    input  wire [31:0] pc,
    input  wire [15:0] instr,

    output reg         branch_taken,
    output reg  [31:0] branch_target,
    output reg         branch_valid
);

// Branch Target Cache (4 entries)
localparam BTC_ENTRIES = 4;

reg [31:0] btc_pc [0:BTC_ENTRIES-1];
reg [31:0] btc_target [0:BTC_ENTRIES-1];
reg [1:0]  btc_counter [0:BTC_ENTRIES-1];  // 2-bit saturating counter
reg        btc_valid [0:BTC_ENTRIES-1];

// Detect branch instructions
wire is_bra = (instr[15:12] == 4'h6) && (instr[11:8] == 4'h0);  // BRA
wire is_bcc = (instr[15:12] == 4'h6) && (instr[11:8] != 4'h0);  // Bcc
wire is_branch = is_bra || is_bcc;

// Extract branch displacement (simplified - only handles short branches)
wire [7:0] displacement = instr[7:0];
wire [31:0] branch_dest = pc + {{24{displacement[7]}}, displacement};

// Search BTC for matching entry
integer i;
reg [1:0] btc_hit_index;
reg btc_hit;

always @(*) begin
    btc_hit = 1'b0;
    btc_hit_index = 2'd0;
    for (i = 0; i < BTC_ENTRIES; i = i + 1) begin
        if (btc_valid[i] && (btc_pc[i] == pc)) begin
            btc_hit = 1'b1;
            btc_hit_index = i[1:0];
        end
    end
end

// Prediction logic
always @(*) begin
    if (is_bra) begin
        // Unconditional branch - always taken
        branch_taken = 1'b1;
        branch_target = branch_dest;
        branch_valid = 1'b1;
    end else if (is_bcc && btc_hit) begin
        // Conditional branch - use 2-bit counter prediction
        branch_taken = (btc_counter[btc_hit_index] >= 2'd2);
        branch_target = btc_target[btc_hit_index];
        branch_valid = 1'b1;
    end else begin
        // Not a branch or not in BTC
        branch_taken = 1'b0;
        branch_target = pc + 32'd2;
        branch_valid = 1'b0;
    end
end

// BTC update logic
reg [1:0] replace_index;

always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        for (i = 0; i < BTC_ENTRIES; i = i + 1) begin
            btc_pc[i] <= 32'h0;
            btc_target[i] <= 32'h0;
            btc_counter[i] <= 2'b01;  // Weakly not-taken
            btc_valid[i] <= 1'b0;
        end
        replace_index <= 2'd0;
    end else begin
        if (is_branch) begin
            if (btc_hit) begin
                // Update existing entry
                if (is_bcc) begin
                    // Update prediction counter (simplified - assumes actual outcome)
                    // In real implementation, this would be updated during writeback
                    if (btc_counter[btc_hit_index] < 2'd3) begin
                        btc_counter[btc_hit_index] <= btc_counter[btc_hit_index] + 1'd1;
                    end
                end
            end else begin
                // Allocate new entry (round-robin replacement)
                btc_pc[replace_index] <= pc;
                btc_target[replace_index] <= branch_dest;
                btc_counter[replace_index] <= is_bra ? 2'b11 : 2'b10;  // Taken or weakly taken
                btc_valid[replace_index] <= 1'b1;
                replace_index <= replace_index + 1'd1;
            end
        end
    end
end

endmodule
