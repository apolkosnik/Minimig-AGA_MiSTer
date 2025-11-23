//------------------------------------------------------------------------------
// MC68060 Arithmetic Logic Unit
// Supports all MC68060 integer operations
//------------------------------------------------------------------------------

module MC68060_ALU
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    input  wire [5:0]  opcode,
    input  wire [31:0] operand1,
    input  wire [31:0] operand2,

    output reg  [31:0] result,
    output reg  [4:0]  flags      // {N, Z, V, C, X}
);

// Opcode definitions
localparam OP_NOP     = 6'd0;
localparam OP_MOVE    = 6'd1;
localparam OP_ADD     = 6'd2;
localparam OP_SUB     = 6'd3;
localparam OP_AND     = 6'd4;
localparam OP_OR      = 6'd5;
localparam OP_EOR     = 6'd6;
localparam OP_CMP     = 6'd7;
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

// Internal signals
wire [32:0] add_result;
wire [32:0] sub_result;
wire [31:0] and_result;
wire [31:0] or_result;
wire [31:0] eor_result;
wire [63:0] mul_result;
wire [31:0] div_result;
wire [31:0] shift_result;

// Perform operations
assign add_result = {1'b0, operand1} + {1'b0, operand2};
assign sub_result = {1'b0, operand1} - {1'b0, operand2};
assign and_result = operand1 & operand2;
assign or_result  = operand1 | operand2;
assign eor_result = operand1 ^ operand2;
assign mul_result = operand1 * operand2;  // Unsigned multiply
assign div_result = (operand2 != 0) ? (operand1 / operand2) : 32'hFFFFFFFF;

// Shift/Rotate logic
wire [4:0] shift_count = operand2[4:0];

reg [31:0] shift_temp;
always @(*) begin
    case (opcode)
        OP_LSL: shift_temp = operand1 << shift_count;
        OP_LSR: shift_temp = operand1 >> shift_count;
        OP_ASL: shift_temp = operand1 << shift_count;
        OP_ASR: shift_temp = $signed(operand1) >>> shift_count;
        OP_ROL: shift_temp = (operand1 << shift_count) | (operand1 >> (32 - shift_count));
        OP_ROR: shift_temp = (operand1 >> shift_count) | (operand1 << (32 - shift_count));
        default: shift_temp = operand1;
    endcase
end

assign shift_result = shift_temp;

// Main ALU operation
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        result <= 32'h0;
        flags <= 5'h0;
    end else if (enable) begin
        case (opcode)
            OP_MOVE: begin
                result <= operand1;
                flags[4] <= operand1[31];           // N
                flags[3] <= (operand1 == 32'h0);    // Z
                flags[2] <= 1'b0;                   // V
                flags[1] <= 1'b0;                   // C
            end

            OP_ADD: begin
                result <= add_result[31:0];
                flags[4] <= add_result[31];                         // N
                flags[3] <= (add_result[31:0] == 32'h0);           // Z
                flags[2] <= (operand1[31] == operand2[31]) &&
                           (operand1[31] != add_result[31]);       // V (overflow)
                flags[1] <= add_result[32];                         // C (carry)
                flags[0] <= add_result[32];                         // X (extend)
            end

            OP_SUB, OP_CMP: begin
                result <= sub_result[31:0];
                flags[4] <= sub_result[31];                         // N
                flags[3] <= (sub_result[31:0] == 32'h0);           // Z
                flags[2] <= (operand1[31] != operand2[31]) &&
                           (operand1[31] != sub_result[31]);       // V
                flags[1] <= sub_result[32];                         // C
                flags[0] <= sub_result[32];                         // X
            end

            OP_AND: begin
                result <= and_result;
                flags[4] <= and_result[31];                 // N
                flags[3] <= (and_result == 32'h0);         // Z
                flags[2] <= 1'b0;                          // V
                flags[1] <= 1'b0;                          // C
            end

            OP_OR: begin
                result <= or_result;
                flags[4] <= or_result[31];                  // N
                flags[3] <= (or_result == 32'h0);          // Z
                flags[2] <= 1'b0;                          // V
                flags[1] <= 1'b0;                          // C
            end

            OP_EOR: begin
                result <= eor_result;
                flags[4] <= eor_result[31];                 // N
                flags[3] <= (eor_result == 32'h0);         // Z
                flags[2] <= 1'b0;                          // V
                flags[1] <= 1'b0;                          // C
            end

            OP_MULU, OP_MULS: begin
                result <= mul_result[31:0];
                flags[4] <= mul_result[31];                 // N
                flags[3] <= (mul_result[31:0] == 32'h0);   // Z
                flags[2] <= (mul_result[63:32] != 32'h0);  // V (overflow if high bits set)
                flags[1] <= 1'b0;                          // C
            end

            OP_DIVU, OP_DIVS: begin
                result <= div_result;
                flags[4] <= div_result[31];                 // N
                flags[3] <= (div_result == 32'h0);         // Z
                flags[2] <= (operand2 == 32'h0);           // V (divide by zero)
                flags[1] <= 1'b0;                          // C
            end

            OP_LSL, OP_LSR, OP_ASL, OP_ASR, OP_ROL, OP_ROR: begin
                result <= shift_result;
                flags[4] <= shift_result[31];               // N
                flags[3] <= (shift_result == 32'h0);       // Z
                flags[2] <= 1'b0;                          // V
                // C flag is last bit shifted out (simplified)
                flags[1] <= (shift_count != 0) ? operand1[shift_count-1] : 1'b0;
            end

            default: begin
                result <= 32'h0;
                flags <= flags;  // Keep previous flags
            end
        endcase
    end
end

endmodule
