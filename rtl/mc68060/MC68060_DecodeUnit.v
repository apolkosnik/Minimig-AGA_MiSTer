//------------------------------------------------------------------------------
// MC68060 Instruction Decode Unit
// Decodes MC68000/68060 instructions into micro-operations
//------------------------------------------------------------------------------

module MC68060_DecodeUnit
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    input  wire [15:0] instr_in,
    input  wire [31:0] pc_in,
    input  wire        valid_in,

    output reg  [2:0]  rf_raddr1,
    output reg  [2:0]  rf_raddr2,
    input  wire [31:0] rf_rdata1,
    input  wire [31:0] rf_rdata2,

    output reg  [5:0]  opcode_out,
    output reg  [31:0] pc_out,
    output reg         valid_out
);

// Instruction format fields
wire [3:0]  instr_op = instr_in[15:12];
wire [2:0]  instr_reg = instr_in[11:9];
wire [2:0]  instr_mode = instr_in[5:3];
wire [2:0]  instr_ea = instr_in[2:0];
wire [1:0]  instr_size = instr_in[7:6];

// Decoded opcode types
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

always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        opcode_out <= OP_NOP;
        pc_out <= 32'h0;
        valid_out <= 1'b0;
        rf_raddr1 <= 3'd0;
        rf_raddr2 <= 3'd0;
    end else if (enable && valid_in) begin
        pc_out <= pc_in;
        valid_out <= 1'b1;

        // Decode instruction based on high nibble
        case (instr_op)
            4'h0: begin
                // ORI, ANDI, SUBI, ADDI, BTST, BCHG, BCLR, BSET, MOVEP, etc.
                if (instr_in[11:8] == 4'h0) begin
                    opcode_out <= OP_OR;  // ORI
                end else if (instr_in[11:8] == 4'h2) begin
                    opcode_out <= OP_AND; // ANDI
                end else begin
                    opcode_out <= OP_NOP;
                end
                rf_raddr1 <= instr_ea;
                rf_raddr2 <= 3'd0;
            end

            4'h1, 4'h2, 4'h3: begin
                // MOVE instructions
                opcode_out <= OP_MOVE;
                rf_raddr1 <= instr_ea;      // Source
                rf_raddr2 <= instr_reg;     // Destination
            end

            4'h4: begin
                // Miscellaneous: NEGX, CLR, NEG, NOT, EXT, NBCD, SWAP, PEA, MOVEM, LEA, CHK, etc.
                if (instr_in[11:9] == 3'b111 && instr_in[7:6] == 2'b01) begin
                    opcode_out <= OP_LEA;
                    rf_raddr1 <= instr_ea;
                    rf_raddr2 <= instr_reg;
                end else begin
                    opcode_out <= OP_NOP;
                    rf_raddr1 <= instr_ea;
                    rf_raddr2 <= 3'd0;
                end
            end

            4'h5: begin
                // ADDQ, SUBQ, Scc, DBcc
                if (instr_in[7:6] == 2'b11) begin
                    opcode_out <= OP_NOP;  // DBcc
                end else if (instr_in[8]) begin
                    opcode_out <= OP_SUB;  // SUBQ
                end else begin
                    opcode_out <= OP_ADD;  // ADDQ
                end
                rf_raddr1 <= instr_ea;
                rf_raddr2 <= 3'd0;
            end

            4'h6: begin
                // Bcc, BSR, BRA
                if (instr_in[11:8] == 4'h0) begin
                    opcode_out <= OP_BRA;
                end else begin
                    opcode_out <= OP_BCC;
                end
                rf_raddr1 <= 3'd0;
                rf_raddr2 <= 3'd0;
            end

            4'h7: begin
                // MOVEQ
                opcode_out <= OP_MOVE;
                rf_raddr1 <= 3'd0;
                rf_raddr2 <= instr_reg;
            end

            4'h8: begin
                // OR, DIV, SBCD
                if (instr_in[7:6] == 2'b11) begin
                    opcode_out <= OP_DIVU;
                end else begin
                    opcode_out <= OP_OR;
                end
                rf_raddr1 <= instr_ea;
                rf_raddr2 <= instr_reg;
            end

            4'h9, 4'hD: begin
                // SUB, SUBX, SUBA
                opcode_out <= OP_SUB;
                rf_raddr1 <= instr_ea;
                rf_raddr2 <= instr_reg;
            end

            4'hB: begin
                // CMP, CMPM, EOR
                if (instr_in[8:6] == 3'b100) begin
                    opcode_out <= OP_EOR;
                end else begin
                    opcode_out <= OP_CMP;
                end
                rf_raddr1 <= instr_ea;
                rf_raddr2 <= instr_reg;
            end

            4'hC: begin
                // AND, MUL, ABCD, EXG
                if (instr_in[7:6] == 2'b11) begin
                    opcode_out <= OP_MULU;
                end else begin
                    opcode_out <= OP_AND;
                end
                rf_raddr1 <= instr_ea;
                rf_raddr2 <= instr_reg;
            end

            4'hE: begin
                // Shift/Rotate instructions
                case (instr_in[4:3])
                    2'b00: opcode_out <= OP_ASR;
                    2'b01: opcode_out <= OP_LSR;
                    2'b10: opcode_out <= OP_ROR;
                    2'b11: opcode_out <= OP_ROR;  // ROXR
                endcase
                rf_raddr1 <= instr_ea;
                rf_raddr2 <= instr_reg;
            end

            default: begin
                opcode_out <= OP_NOP;
                rf_raddr1 <= 3'd0;
                rf_raddr2 <= 3'd0;
            end
        endcase
    end else begin
        valid_out <= 1'b0;
    end
end

endmodule
