//------------------------------------------------------------------------------
// MC68060 Instruction Fetch Unit
// Handles instruction prefetch with branch prediction support
//------------------------------------------------------------------------------

module MC68060_FetchUnit
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    input  wire [31:0] pc_in,
    input  wire        branch_taken,
    input  wire [31:0] branch_target,

    input  wire        icache_enable,
    input  wire        icache_hit,

    output reg  [31:0] mem_addr,
    input  wire [15:0] mem_data,
    input  wire        mem_ready,

    output reg  [15:0] instr_out,
    output reg  [31:0] pc_out,
    output reg         valid_out
);

reg [31:0] fetch_pc;
reg        fetch_pending;

always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        fetch_pc <= 32'h0;
        fetch_pending <= 1'b0;
        valid_out <= 1'b0;
        instr_out <= 16'h0;
        pc_out <= 32'h0;
        mem_addr <= 32'h0;
    end else if (enable) begin
        // Handle branch taken
        if (branch_taken) begin
            fetch_pc <= branch_target;
            fetch_pending <= 1'b1;
            valid_out <= 1'b0;
        end else if (!fetch_pending) begin
            fetch_pc <= pc_in;
            fetch_pending <= 1'b1;
            mem_addr <= pc_in;
        end

        // Capture fetched instruction
        if (fetch_pending && mem_ready) begin
            instr_out <= mem_data;
            pc_out <= fetch_pc;
            valid_out <= 1'b1;
            fetch_pending <= 1'b0;
        end else begin
            valid_out <= 1'b0;
        end
    end
end

endmodule
