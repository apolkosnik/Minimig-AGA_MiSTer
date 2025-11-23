//------------------------------------------------------------------------------
// MC68060 Instruction Decode Unit
// Decodes MC68000/68060 instructions into micro-operations
//------------------------------------------------------------------------------

module MC68060_DecodeUnit
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    // Multi-word instruction input
    input  wire [15:0] instr_word0,    // Opcode word
    input  wire [15:0] instr_word1,    // Extension word 1
    input  wire [15:0] instr_word2,    // Extension word 2
    input  wire [15:0] instr_word3,    // Extension word 3
    input  wire [2:0]  words_available,// How many words available
    input  wire [31:0] pc_in,
    input  wire        valid_in,

    output reg  [3:0]  rf_raddr1,
    output reg  [3:0]  rf_raddr2,
    input  wire [31:0] rf_rdata1,
    input  wire [31:0] rf_rdata2,

    output reg  [5:0]  opcode_out,
    output reg  [3:0]  dest_reg_out,   // Destination register for writeback
    output reg  [31:0] pc_out,
    output reg         valid_out,
    output reg  [2:0]  instr_length,   // Instruction length in words (1-5)

    // Effective Address information
    output reg  [2:0]  ea_mode_src,    // Source EA mode
    output reg  [2:0]  ea_reg_src,     // Source EA register
    output reg  [2:0]  ea_mode_dst,    // Destination EA mode
    output reg  [2:0]  ea_reg_dst,     // Destination EA register
    output reg  [1:0]  ea_size,        // Operand size: 00=byte, 01=word, 10=long
    output reg         needs_ea_src,   // Source needs EA calculation
    output reg         needs_ea_dst,   // Destination needs EA calculation

    // Extension words for EA calculation
    output reg  [15:0] ext_word1,      // First extension word
    output reg  [15:0] ext_word2       // Second extension word
);

// Instruction format fields (from opcode word)
wire [3:0]  instr_op = instr_word0[15:12];
wire [2:0]  instr_reg = instr_word0[11:9];
wire [2:0]  instr_mode = instr_word0[5:3];
wire [2:0]  instr_ea = instr_word0[2:0];
wire [1:0]  instr_size = instr_word0[7:6];

// Function to calculate instruction length based on EA mode
function [2:0] calc_ea_length;
    input [2:0] mode;
    input [2:0] reg_field;
    input [1:0] size;
    begin
        case (mode)
            3'b000, 3'b001:  calc_ea_length = 3'd0;  // Dn, An - no extension
            3'b010, 3'b011, 3'b100:  calc_ea_length = 3'd0;  // (An), (An)+, -(An) - no extension
            3'b101:  calc_ea_length = 3'd1;  // d16(An) - 1 extension word
            3'b110:  calc_ea_length = 3'd1;  // d8(An,Xn) - 1 extension word (brief format)
            3'b111: begin
                case (reg_field)
                    3'b000:  calc_ea_length = 3'd1;  // xxx.W - 1 extension word
                    3'b001:  calc_ea_length = 3'd2;  // xxx.L - 2 extension words
                    3'b010:  calc_ea_length = 3'd1;  // d16(PC) - 1 extension word
                    3'b011:  calc_ea_length = 3'd1;  // d8(PC,Xn) - 1 extension word
                    3'b100: begin
                        // Immediate - size dependent
                        calc_ea_length = (size == 2'b10) ? 3'd2 : 3'd1;  // Long=2, Byte/Word=1
                    end
                    default: calc_ea_length = 3'd0;
                endcase
            end
            default: calc_ea_length = 3'd0;
        endcase
    end
endfunction

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
localparam OP_BSR     = 6'd24;
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
localparam OP_CLR     = 6'd25;
localparam OP_NEG     = 6'd26;
localparam OP_NOT     = 6'd27;
localparam OP_TST     = 6'd28;
localparam OP_LINK    = 6'd29;
localparam OP_UNLK    = 6'd30;

always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        opcode_out <= OP_NOP;
        dest_reg_out <= 4'd0;
        pc_out <= 32'h0;
        valid_out <= 1'b0;
        instr_length <= 3'd1;
        rf_raddr1 <= 4'd0;
        rf_raddr2 <= 4'd0;
        ea_mode_src <= 3'b000;
        ea_reg_src <= 3'b000;
        ea_mode_dst <= 3'b000;
        ea_reg_dst <= 3'b000;
        ea_size <= 2'b10;
        needs_ea_src <= 1'b0;
        needs_ea_dst <= 1'b0;
        ext_word1 <= 16'h0;
        ext_word2 <= 16'h0;
    end else if (enable && valid_in) begin
        pc_out <= pc_in;
        valid_out <= 1'b1;

        // Default: no EA calculation needed, instruction is 1 word
        needs_ea_src <= 1'b0;
        needs_ea_dst <= 1'b0;
        ea_size <= instr_size;  // Get size from instruction
        instr_length <= 3'd1;   // Default to 1-word instruction
        ext_word1 <= instr_word1;
        ext_word2 <= instr_word2;

        // Decode instruction based on high nibble
        case (instr_op)
            4'h0: begin
                // ORI, ANDI, SUBI, ADDI, BTST, BCHG, BCLR, BSET, MOVEP, etc.
                if (instr_word0[11:8] == 4'h0) begin
                    opcode_out <= OP_OR;  // ORI
                end else if (instr_word0[11:8] == 4'h2) begin
                    opcode_out <= OP_AND; // ANDI
                end else begin
                    opcode_out <= OP_NOP;
                end
                rf_raddr1 <= {1'b0, instr_ea};
                rf_raddr2 <= {1'b0, instr_ea};  // Destination is same as source for these
                dest_reg_out <= {1'b0, instr_ea};
                // Length: 1 + immediate data + EA extension
                instr_length <= 3'd1 + ((instr_size == 2'b10) ? 3'd2 : 3'd1) +
                               calc_ea_length(instr_mode, instr_ea, instr_size);
            end

            4'h1, 4'h2, 4'h3: begin
                // MOVE instructions
                opcode_out <= OP_MOVE;
                rf_raddr1 <= {1'b0, instr_ea};      // Source
                rf_raddr2 <= {1'b0, instr_reg};     // Destination
                dest_reg_out <= {1'b0, instr_reg}; // Write to destination register

                // Extract EA information
                ea_mode_src <= instr_mode;          // Source EA mode
                ea_reg_src <= instr_ea;             // Source EA register
                ea_mode_dst <= instr_word0[8:6];    // Destination EA mode (rearranged in MOVE)
                ea_reg_dst <= instr_reg;            // Destination EA register

                // Determine if EA calculation is needed (not register direct)
                needs_ea_src <= (instr_mode != 3'b000);  // Not data register direct
                needs_ea_dst <= (instr_word0[8:6] != 3'b000);

                // Calculate instruction length: 1 + src_ea_words + dst_ea_words
                instr_length <= 3'd1 +
                               calc_ea_length(instr_mode, instr_ea, instr_size) +
                               calc_ea_length(instr_word0[8:6], instr_reg, instr_size);
            end

            4'h4: begin
                // Miscellaneous: NEGX, CLR, NEG, NOT, EXT, NBCD, SWAP, PEA, MOVEM, LEA, CHK, JSR, RTS, etc.
                if (instr_word0[11:9] == 3'b111 && instr_word0[7:6] == 2'b01) begin
                    opcode_out <= OP_LEA;
                    rf_raddr1 <= {1'b0, instr_ea};
                    rf_raddr2 <= {1'b0, instr_reg};
                    dest_reg_out <= {1'b0, instr_reg};  // LEA writes to address register

                    // LEA always needs EA calculation
                    ea_mode_src <= instr_mode;
                    ea_reg_src <= instr_ea;
                    needs_ea_src <= 1'b1;

                    // Length: 1 + EA extension words
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end else if (instr_word0[11:6] == 6'b111010) begin
                    // JSR: 0100 1110 10 xxx xxx
                    opcode_out <= OP_JSR;
                    rf_raddr1 <= 4'd15;  // Read A7 (stack pointer) for use in execute
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= 4'd0;  // JSR doesn't write to a register directly

                    // JSR needs EA calculation for target address
                    ea_mode_src <= instr_mode;
                    ea_reg_src <= instr_ea;
                    needs_ea_src <= 1'b1;

                    // Length: 1 + EA extension words
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end else if (instr_word0 == 16'h4E75) begin
                    // RTS: 0100 1110 0111 0101
                    opcode_out <= OP_RTS;
                    rf_raddr1 <= 4'd15;  // Read A7 (stack pointer)
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= 4'd0;  // RTS doesn't write to a register
                    instr_length <= 3'd1;   // RTS is always 1 word
                end else if (instr_word0[15:3] == 13'b0100_1110_0101_0) begin
                    // LINK: 0100 1110 0101 0xxx
                    opcode_out <= OP_LINK;
                    rf_raddr1 <= 4'd15;              // Read A7 (stack pointer)
                    rf_raddr2 <= {1'b1, instr_word0[2:0]};  // Read An
                    dest_reg_out <= {1'b1, instr_word0[2:0]};  // Write to An
                    instr_length <= 3'd2;   // LINK has displacement word
                end else if (instr_word0[15:3] == 13'b0100_1110_0101_1) begin
                    // UNLK: 0100 1110 0101 1xxx
                    opcode_out <= OP_UNLK;
                    rf_raddr1 <= 4'd15;              // Read A7 (stack pointer)
                    rf_raddr2 <= {1'b1, instr_word0[2:0]};  // Read An
                    dest_reg_out <= {1'b1, instr_word0[2:0]};  // Write to An
                    instr_length <= 3'd1;   // UNLK is 1 word
                end else if (instr_word0[11:8] == 4'h2) begin
                    // CLR: 0100 0010 xx xxxxxx
                    opcode_out <= OP_CLR;
                    rf_raddr1 <= {1'b0, instr_ea};
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= {1'b0, instr_ea};  // CLR writes to EA
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end else if (instr_word0[11:8] == 4'h4) begin
                    // NEG: 0100 0100 xx xxxxxx
                    opcode_out <= OP_NEG;
                    rf_raddr1 <= {1'b0, instr_ea};
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= {1'b0, instr_ea};  // NEG writes to EA
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end else if (instr_word0[11:8] == 4'h6) begin
                    // NOT: 0100 0110 xx xxxxxx
                    opcode_out <= OP_NOT;
                    rf_raddr1 <= {1'b0, instr_ea};
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= {1'b0, instr_ea};  // NOT writes to EA
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end else if (instr_word0[11:8] == 4'hA) begin
                    // TST: 0100 1010 xx xxxxxx
                    opcode_out <= OP_TST;
                    rf_raddr1 <= {1'b0, instr_ea};
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= 4'd0;  // TST doesn't write
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end else begin
                    opcode_out <= OP_NOP;
                    rf_raddr1 <= {1'b0, instr_ea};
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= 4'd0;
                    instr_length <= 3'd1;
                end
            end

            4'h5: begin
                // ADDQ, SUBQ, Scc, DBcc
                if (instr_word0[7:6] == 2'b11) begin
                    opcode_out <= OP_NOP;  // DBcc
                    dest_reg_out <= 4'd0;
                    instr_length <= 3'd2;  // DBcc has displacement word
                end else if (instr_word0[8]) begin
                    opcode_out <= OP_SUB;  // SUBQ
                    dest_reg_out <= {1'b0, instr_ea};  // Destination
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end else begin
                    opcode_out <= OP_ADD;  // ADDQ
                    dest_reg_out <= {1'b0, instr_ea};  // Destination
                    instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
                end
                rf_raddr1 <= {1'b0, instr_ea};
                rf_raddr2 <= {1'b0, instr_ea};
            end

            4'h6: begin
                // Bcc, BSR, BRA
                if (instr_word0[11:8] == 4'h0) begin
                    opcode_out <= OP_BRA;
                    rf_raddr1 <= 4'd0;
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= 4'd0;
                end else if (instr_word0[11:8] == 4'h1) begin
                    opcode_out <= OP_BSR;  // Branch to Subroutine
                    rf_raddr1 <= 4'd15;    // Read A7 (stack pointer)
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= 4'd0;
                end else begin
                    opcode_out <= OP_BCC;
                    rf_raddr1 <= 4'd0;
                    rf_raddr2 <= 4'd0;
                    dest_reg_out <= instr_word0[11:8];  // Pass condition code in dest_reg
                end
                // Branch: 1 word if 8-bit displacement, 2 words if 16-bit displacement
                instr_length <= (instr_word0[7:0] == 8'h00) ? 3'd2 : 3'd1;
            end

            4'h7: begin
                // MOVEQ
                opcode_out <= OP_MOVE;
                rf_raddr1 <= 4'd0;
                rf_raddr2 <= {1'b0, instr_reg};
                dest_reg_out <= {1'b0, instr_reg};  // MOVEQ writes to data register
                instr_length <= 3'd1;  // MOVEQ is always 1 word
            end

            4'h8: begin
                // OR, DIV, SBCD
                if (instr_word0[7:6] == 2'b11) begin
                    opcode_out <= OP_DIVU;
                end else begin
                    opcode_out <= OP_OR;
                end
                rf_raddr1 <= {1'b0, instr_ea};
                rf_raddr2 <= {1'b0, instr_reg};
                dest_reg_out <= {1'b0, instr_reg};  // Write to register

                // EA information for source operand
                ea_mode_src <= instr_mode;
                ea_reg_src <= instr_ea;
                needs_ea_src <= (instr_mode != 3'b000) && (instr_mode != 3'b001);

                // Length: 1 + EA extension words
                instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
            end

            4'h9, 4'hD: begin
                // SUB, SUBX, SUBA
                opcode_out <= OP_SUB;
                rf_raddr1 <= {1'b0, instr_ea};
                rf_raddr2 <= {1'b0, instr_reg};
                dest_reg_out <= {1'b0, instr_reg};  // Write to register

                // EA information for source operand
                ea_mode_src <= instr_mode;
                ea_reg_src <= instr_ea;
                needs_ea_src <= (instr_mode != 3'b000) && (instr_mode != 3'b001);  // Not Dn/An direct

                // Length: 1 + EA extension words
                instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
            end

            4'hB: begin
                // CMP, CMPM, EOR
                if (instr_word0[8:6] == 3'b100) begin
                    opcode_out <= OP_EOR;
                    dest_reg_out <= {1'b0, instr_ea};  // EOR writes to EA
                end else begin
                    opcode_out <= OP_CMP;
                    dest_reg_out <= 4'd0;  // CMP doesn't write
                end
                rf_raddr1 <= {1'b0, instr_ea};
                rf_raddr2 <= {1'b0, instr_reg};

                // Length: 1 + EA extension words
                instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
            end

            4'hC: begin
                // AND, MUL, ABCD, EXG
                if (instr_word0[7:6] == 2'b11) begin
                    opcode_out <= OP_MULU;
                end else begin
                    opcode_out <= OP_AND;
                end
                rf_raddr1 <= {1'b0, instr_ea};
                rf_raddr2 <= {1'b0, instr_reg};
                dest_reg_out <= {1'b0, instr_reg};  // Write to register

                // EA information for source operand
                ea_mode_src <= instr_mode;
                ea_reg_src <= instr_ea;
                needs_ea_src <= (instr_mode != 3'b000) && (instr_mode != 3'b001);

                // Length: 1 + EA extension words
                instr_length <= 3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size);
            end

            4'hE: begin
                // Shift/Rotate instructions
                case (instr_word0[4:3])
                    2'b00: opcode_out <= OP_ASR;
                    2'b01: opcode_out <= OP_LSR;
                    2'b10: opcode_out <= OP_ROR;
                    2'b11: opcode_out <= OP_ROR;  // ROXR
                endcase
                rf_raddr1 <= {1'b0, instr_ea};
                rf_raddr2 <= {1'b0, instr_reg};
                dest_reg_out <= {1'b0, instr_ea};  // Shift writes to EA

                // Length: 1 + EA extension words (for memory shifts only)
                instr_length <= (instr_word0[7:6] == 2'b11) ?
                                3'd1 + calc_ea_length(instr_mode, instr_ea, instr_size) : 3'd1;
            end

            default: begin
                opcode_out <= OP_NOP;
                rf_raddr1 <= 4'd0;
                rf_raddr2 <= 4'd0;
                dest_reg_out <= 4'd0;
                instr_length <= 3'd1;
            end
        endcase
    end else begin
        valid_out <= 1'b0;
    end
end

endmodule
