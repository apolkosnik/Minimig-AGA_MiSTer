//------------------------------------------------------------------------------
// MC68060 Execution Unit
// Dual integer execution pipelines with forwarding
//------------------------------------------------------------------------------

module MC68060_ExecuteUnit
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    input  wire [5:0]  opcode_in,
    input  wire [31:0] pc_in,
    input  wire        valid_in,

    input  wire [31:0] operand1,
    input  wire [31:0] operand2,

    output reg  [31:0] result_out,
    output reg  [2:0]  write_addr,
    output reg         write_enable,

    output reg  [31:0] mem_addr,
    output reg  [15:0] mem_wdata,
    output reg         mem_read,
    output reg         mem_write,
    output reg         mem_uds,
    output reg         mem_lds,

    input  wire        fpu_busy,

    output reg  [31:0] pc_out,
    output reg         valid_out
);

// Opcode definitions (must match DecodeUnit)
localparam OP_NOP     = 6'd0;
localparam OP_MOVE    = 6'd1;
localparam OP_ADD     = 6'd2;
localparam OP_SUB     = 6'd3;
localparam OP_AND     = 6'd4;
localparam OP_OR      = 6'd5;
localparam OP_EOR     = 6'd6;
localparam OP_CMP     = 6'd7;
localparam OP_BRA     = 6'd8;
localparam OP_BCC     = 6'd9;
localparam OP_JMP     = 6'd10;
localparam OP_JSR     = 6'd11;
localparam OP_RTS     = 6'd12;
localparam OP_LEA     = 6'd13;
localparam OP_MULU    = 6'd14;
localparam OP_MULS    = 6'd15;
localparam OP_DIVU    = 6'd16;
localparam OP_DIVS    = 6'd17;
localparam OP_LSL     = 6'd18;
localparam OP_LSR     = 6'd19;
localparam OP_ASL     = 6'd20;
localparam OP_ASR     = 6'd21;
localparam OP_ROL     = 6'd22;
localparam OP_ROR     = 6'd23;

// ALU signals
wire [31:0] alu_result;
wire [4:0]  alu_flags;

// Instantiate ALU
MC68060_ALU alu
(
    .clk        (clk),
    .nreset     (nreset),
    .enable     (enable),

    .opcode     (opcode_in),
    .operand1   (operand1),
    .operand2   (operand2),

    .result     (alu_result),
    .flags      (alu_flags)    // {N, Z, V, C, X}
);

// Execute pipeline
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        result_out <= 32'h0;
        write_addr <= 3'd0;
        write_enable <= 1'b0;
        mem_addr <= 32'h0;
        mem_wdata <= 16'h0;
        mem_read <= 1'b0;
        mem_write <= 1'b0;
        mem_uds <= 1'b0;
        mem_lds <= 1'b0;
        pc_out <= 32'h0;
        valid_out <= 1'b0;
    end else if (enable && valid_in) begin
        pc_out <= pc_in;
        valid_out <= 1'b1;
        mem_read <= 1'b0;
        mem_write <= 1'b0;

        case (opcode_in)
            OP_NOP: begin
                write_enable <= 1'b0;
            end

            OP_MOVE: begin
                result_out <= operand1;
                write_enable <= 1'b1;
            end

            OP_ADD: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_SUB: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_AND: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_OR: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_EOR: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_CMP: begin
                // CMP doesn't write back, only sets flags
                write_enable <= 1'b0;
            end

            OP_LEA: begin
                result_out <= operand1;  // Effective address
                write_enable <= 1'b1;
            end

            OP_MULU: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_MULS: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_DIVU: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_DIVS: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_LSL, OP_LSR, OP_ASL, OP_ASR, OP_ROL, OP_ROR: begin
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            default: begin
                write_enable <= 1'b0;
            end
        endcase
    end else begin
        valid_out <= 1'b0;
        write_enable <= 1'b0;
    end
end

endmodule
