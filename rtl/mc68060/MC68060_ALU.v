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
    input  wire [1:0]  size,        // 00=byte, 01=word, 10=long

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
wire [31:0] shift_result;

// Perform basic operations
assign add_result = {1'b0, operand1} + {1'b0, operand2};
assign sub_result = {1'b0, operand1} - {1'b0, operand2};
assign and_result = operand1 & operand2;
assign or_result  = operand1 | operand2;
assign eor_result = operand1 ^ operand2;

// Multiply/Divide operations (size-dependent)
reg [31:0] mul_result;
reg [31:0] div_result;
reg [31:0] div_remainder;

always @(*) begin
    // Default values
    mul_result = 32'h0;
    div_result = 32'hFFFFFFFF;
    div_remainder = 32'h0;

    case (opcode)
        OP_MULU: begin
            // Unsigned multiply
            if (size == 2'b01) begin
                // MULU.W: 16×16 → 32
                mul_result = operand1[15:0] * operand2[15:0];
            end else begin
                // MULU.L: 32×32 → 64 (only return low 32 bits for now)
                mul_result = operand1 * operand2;
            end
        end

        OP_MULS: begin
            // Signed multiply
            if (size == 2'b01) begin
                // MULS.W: signed 16×16 → 32
                mul_result = $signed(operand1[15:0]) * $signed(operand2[15:0]);
            end else begin
                // MULS.L: signed 32×32 → 64 (only return low 32 bits for now)
                mul_result = $signed(operand1) * $signed(operand2);
            end
        end

        OP_DIVU: begin
            // Unsigned divide
            if (operand2 != 32'h0) begin
                if (size == 2'b01) begin
                    // DIVU.W: 32÷16 → quotient(16) + remainder(16)
                    if (operand2[15:0] != 16'h0) begin
                        div_result[15:0] = operand1 / operand2[15:0];     // Quotient in low word
                        div_remainder[15:0] = operand1 % operand2[15:0];  // Remainder
                        div_result[31:16] = div_remainder[15:0];          // Pack remainder in high word
                    end else begin
                        div_result = 32'hFFFFFFFF;  // Division by zero
                    end
                end else begin
                    // DIVU.L: 32÷32 (MC68020+)
                    div_result = operand1 / operand2;
                end
            end else begin
                div_result = 32'hFFFFFFFF;  // Division by zero
            end
        end

        OP_DIVS: begin
            // Signed divide
            if (operand2 != 32'h0) begin
                if (size == 2'b01) begin
                    // DIVS.W: signed 32÷16 → quotient(16) + remainder(16)
                    if (operand2[15:0] != 16'h0) begin
                        div_result[15:0] = $signed(operand1) / $signed(operand2[15:0]);
                        div_remainder[15:0] = $signed(operand1) % $signed(operand2[15:0]);
                        div_result[31:16] = div_remainder[15:0];
                    end else begin
                        div_result = 32'hFFFFFFFF;  // Division by zero
                    end
                end else begin
                    // DIVS.L: signed 32÷32 (MC68020+)
                    div_result = $signed(operand1) / $signed(operand2);
                end
            end else begin
                div_result = 32'hFFFFFFFF;  // Division by zero
            end
        end

        default: begin
            mul_result = 32'h0;
            div_result = 32'h0;
        end
    endcase
end

// Shift/Rotate logic
wire [4:0] shift_count = operand2[4:0];

reg [31:0] shift_temp;
reg shift_carry;  // Carry flag for shift operations

always @(*) begin
    shift_temp = operand1;
    shift_carry = 1'b0;

    case (opcode)
        OP_LSL: begin
            if (shift_count == 0) begin
                shift_temp = operand1;
                shift_carry = 1'b0;
            end else begin
                shift_temp = operand1 << shift_count;
                shift_carry = operand1[32 - shift_count];  // Last bit shifted out
            end
        end

        OP_LSR: begin
            if (shift_count == 0) begin
                shift_temp = operand1;
                shift_carry = 1'b0;
            end else begin
                shift_temp = operand1 >> shift_count;
                shift_carry = operand1[shift_count - 1];  // Last bit shifted out
            end
        end

        OP_ASL: begin
            if (shift_count == 0) begin
                shift_temp = operand1;
                shift_carry = 1'b0;
            end else begin
                shift_temp = operand1 << shift_count;
                shift_carry = operand1[32 - shift_count];
            end
        end

        OP_ASR: begin
            if (shift_count == 0) begin
                shift_temp = operand1;
                shift_carry = 1'b0;
            end else begin
                shift_temp = $signed(operand1) >>> shift_count;
                shift_carry = operand1[shift_count - 1];
            end
        end

        OP_ROL: begin
            if (shift_count == 0) begin
                shift_temp = operand1;
                shift_carry = 1'b0;
            end else begin
                shift_temp = (operand1 << shift_count) | (operand1 >> (32 - shift_count));
                shift_carry = operand1[32 - shift_count];  // Bit rotated out
            end
        end

        OP_ROR: begin
            if (shift_count == 0) begin
                shift_temp = operand1;
                shift_carry = 1'b0;
            end else begin
                shift_temp = (operand1 >> shift_count) | (operand1 << (32 - shift_count));
                shift_carry = operand1[shift_count - 1];  // Bit rotated out
            end
        end

        default: begin
            shift_temp = operand1;
            shift_carry = 1'b0;
        end
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
                result <= mul_result;
                flags[4] <= mul_result[31];                 // N
                flags[3] <= (mul_result == 32'h0);         // Z
                flags[2] <= 1'b0;                          // V (cleared for multiply)
                flags[1] <= 1'b0;                          // C (cleared for multiply)
                flags[0] <= 1'b0;                          // X (not affected)
            end

            OP_DIVU, OP_DIVS: begin
                result <= div_result;
                flags[4] <= div_result[15];                 // N (based on quotient, low word)
                flags[3] <= (div_result[15:0] == 16'h0);   // Z (based on quotient)
                flags[2] <= (operand2 == 32'h0) || (operand2[15:0] == 16'h0);  // V (divide by zero)
                flags[1] <= 1'b0;                          // C (cleared for divide)
                flags[0] <= 1'b0;                          // X (not affected)
            end

            OP_LSL, OP_LSR, OP_ASL, OP_ASR, OP_ROL, OP_ROR: begin
                result <= shift_result;
                flags[4] <= shift_result[31];               // N
                flags[3] <= (shift_result == 32'h0);       // Z
                flags[2] <= 1'b0;                          // V
                flags[1] <= shift_carry;                    // C - properly calculated per operation
                flags[0] <= shift_carry;                    // X - extend flag same as carry
            end

            default: begin
                result <= 32'h0;
                flags <= flags;  // Keep previous flags
            end
        endcase
    end
end

endmodule
