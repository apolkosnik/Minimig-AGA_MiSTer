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
    input  wire [3:0]  dest_reg_in,
    input  wire [31:0] pc_in,
    input  wire        valid_in,

    input  wire [31:0] operand1,
    input  wire [31:0] operand2,
    input  wire [1:0]  operand_size,   // 00=byte, 01=word, 10=long

    // Effective Address inputs
    input  wire [31:0] ea_src,         // Calculated source EA
    input  wire [31:0] ea_dst,         // Calculated destination EA
    input  wire        ea_valid_src,   // Source EA is valid
    input  wire        ea_valid_dst,   // Destination EA is valid

    output reg  [31:0] result_out,
    output reg  [3:0]  write_addr,
    output reg         write_enable,

    output reg  [31:0] mem_addr,
    output reg  [15:0] mem_wdata,
    input  wire [15:0] mem_rdata,      // Memory read data
    output reg         mem_read,
    output reg         mem_write,
    output reg         mem_uds,
    output reg         mem_lds,

    // Stack pointer access (A7 = register 15)
    input  wire [31:0] stack_pointer,  // Current value of A7
    output reg  [31:0] stack_ptr_out,  // New value for A7
    output reg         stack_ptr_write, // Update A7

    input  wire        fpu_busy,

    output reg  [4:0]  flags_out,     // Flags for SR update (X, N, Z, V, C)
    output reg         branch_taken,   // Branch was taken
    output reg  [31:0] branch_target,  // Branch target address

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

// ALU signals
wire [31:0] alu_result;
wire [4:0]  alu_flags;

// Multi-cycle operation state for JSR/RTS
reg [1:0]  jsr_rts_state;   // 0=idle, 1=first, 2=second, 3=third
reg [31:0] saved_pc;         // Saved PC for JSR
reg [31:0] return_addr;      // Return address being read for RTS
reg [5:0]  saved_opcode;     // Remember which operation we're doing

localparam MULTI_IDLE   = 2'd0;
localparam MULTI_FIRST  = 2'd1;
localparam MULTI_SECOND = 2'd2;
localparam MULTI_THIRD  = 2'd3;

// Instantiate ALU
MC68060_ALU alu
(
    .clk        (clk),
    .nreset     (nreset),
    .enable     (enable),

    .opcode     (opcode_in),
    .operand1   (operand1),
    .operand2   (operand2),
    .size       (operand_size),

    .result     (alu_result),
    .flags      (alu_flags)    // {N, Z, V, C, X}
);

// Execute pipeline
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        result_out <= 32'h0;
        write_addr <= 4'd0;
        write_enable <= 1'b0;
        mem_addr <= 32'h0;
        mem_wdata <= 16'h0;
        mem_read <= 1'b0;
        mem_write <= 1'b0;
        mem_uds <= 1'b0;
        mem_lds <= 1'b0;
        stack_ptr_out <= 32'h0;
        stack_ptr_write <= 1'b0;
        flags_out <= 5'h0;
        branch_taken <= 1'b0;
        branch_target <= 32'h0;
        pc_out <= 32'h0;
        valid_out <= 1'b0;
        jsr_rts_state <= MULTI_IDLE;
        saved_pc <= 32'h0;
        return_addr <= 32'h0;
        saved_opcode <= 6'd0;
    end else if (enable) begin

        // Handle multi-cycle JSR/RTS operations
        if (jsr_rts_state != MULTI_IDLE) begin
            // Default: clear control signals
            mem_read <= 1'b0;
            mem_write <= 1'b0;
            branch_taken <= 1'b0;
            stack_ptr_write <= 1'b0;
            write_enable <= 1'b0;

            case (saved_opcode)
                OP_JSR, OP_BSR: begin
                    case (jsr_rts_state)
                        MULTI_FIRST: begin
                            // First cycle: write high word of return address
                            mem_addr <= stack_pointer - 32'd2;
                            mem_write <= 1'b1;
                            mem_wdata <= saved_pc[31:16];  // High word
                            mem_uds <= 1'b1;
                            mem_lds <= 1'b1;
                            jsr_rts_state <= MULTI_SECOND;
                            valid_out <= 1'b0;  // Not done yet
                        end

                        MULTI_SECOND: begin
                            // Second cycle: write low word and complete
                            mem_addr <= stack_pointer - 32'd4;
                            mem_write <= 1'b1;
                            mem_wdata <= saved_pc[15:0];   // Low word
                            mem_uds <= 1'b1;
                            mem_lds <= 1'b1;

                            // Complete the JSR - branch to target
                            branch_taken <= 1'b1;
                            branch_target <= return_addr;  // Reusing return_addr to save target

                            jsr_rts_state <= MULTI_IDLE;
                            valid_out <= 1'b1;
                        end

                        default: jsr_rts_state <= MULTI_IDLE;
                    endcase
                end

                OP_RTS: begin
                    case (jsr_rts_state)
                        MULTI_FIRST: begin
                            // First cycle: read low word of return address from [SP]
                            mem_addr <= stack_pointer;
                            mem_read <= 1'b1;
                            mem_uds <= 1'b1;
                            mem_lds <= 1'b1;
                            jsr_rts_state <= MULTI_SECOND;
                            valid_out <= 1'b0;  // Not done yet
                        end

                        MULTI_SECOND: begin
                            // Second cycle: latch low word, read high word from [SP+2]
                            return_addr[15:0] <= mem_rdata;  // Low word from previous read

                            mem_addr <= stack_pointer + 32'd2;
                            mem_read <= 1'b1;
                            mem_uds <= 1'b1;
                            mem_lds <= 1'b1;

                            jsr_rts_state <= MULTI_THIRD;
                            valid_out <= 1'b0;  // Still not done
                        end

                        MULTI_THIRD: begin
                            // Third cycle: latch high word and complete
                            return_addr[31:16] <= mem_rdata;  // High word from second read

                            // Complete the RTS - branch to return address
                            branch_taken <= 1'b1;
                            branch_target <= {mem_rdata, return_addr[15:0]};

                            jsr_rts_state <= MULTI_IDLE;
                            valid_out <= 1'b1;  // Done!
                        end

                        default: jsr_rts_state <= MULTI_IDLE;
                    endcase
                end

                default: jsr_rts_state <= MULTI_IDLE;
            endcase
        end

        // Normal single-cycle operations
        else if (valid_in) begin
        pc_out <= pc_in;
        valid_out <= 1'b1;
        mem_read <= 1'b0;
        mem_write <= 1'b0;
        branch_taken <= 1'b0;
        stack_ptr_write <= 1'b0;      // Default: don't update stack pointer
        write_addr <= dest_reg_in;    // Always set destination register
        flags_out <= alu_flags;        // Propagate ALU flags

        case (opcode_in)
            OP_NOP: begin
                write_enable <= 1'b0;
            end

            OP_MOVE: begin
                // MOVE instruction
                if (ea_valid_src) begin
                    // Source is memory - need to read from ea_src
                    mem_addr <= ea_src;
                    mem_read <= 1'b1;
                    mem_uds <= 1'b1;
                    mem_lds <= 1'b1;
                    result_out <= operand1;  // Will be updated in memory stage
                end else begin
                    // Source is register - use operand1 directly
                    result_out <= operand1;
                end

                if (ea_valid_dst) begin
                    // Destination is memory - need to write to ea_dst
                    mem_addr <= ea_dst;
                    mem_write <= 1'b1;
                    mem_wdata <= operand1[15:0];
                    mem_uds <= 1'b1;
                    mem_lds <= 1'b1;
                    write_enable <= 1'b0;  // No register write
                end else begin
                    // Destination is register - write to register file
                    write_enable <= 1'b1;
                end
            end

            OP_ADD: begin
                if (ea_valid_src) begin
                    // Source is memory - read from EA
                    mem_addr <= ea_src;
                    mem_read <= 1'b1;
                    mem_uds <= 1'b1;
                    mem_lds <= 1'b1;
                end
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_SUB: begin
                if (ea_valid_src) begin
                    // Source is memory - read from EA
                    mem_addr <= ea_src;
                    mem_read <= 1'b1;
                    mem_uds <= 1'b1;
                    mem_lds <= 1'b1;
                end
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_AND: begin
                if (ea_valid_src) begin
                    // Source is memory - read from EA
                    mem_addr <= ea_src;
                    mem_read <= 1'b1;
                    mem_uds <= 1'b1;
                    mem_lds <= 1'b1;
                end
                result_out <= alu_result;
                write_enable <= 1'b1;
            end

            OP_OR: begin
                if (ea_valid_src) begin
                    // Source is memory - read from EA
                    mem_addr <= ea_src;
                    mem_read <= 1'b1;
                    mem_uds <= 1'b1;
                    mem_lds <= 1'b1;
                end
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

            OP_BRA: begin
                // Unconditional branch
                branch_taken <= 1'b1;
                branch_target <= pc_in + {{24{operand1[7]}}, operand1[7:0]};  // Sign-extended 8-bit displacement
                write_enable <= 1'b0;
            end

            OP_BCC: begin
                // Conditional branch - check condition codes
                // For now, simplified: just implement BNE (Branch if Not Equal)
                // Real implementation would check operand1 for condition code
                if (alu_flags[3] == 1'b0) begin  // Z flag == 0 (not equal)
                    branch_taken <= 1'b1;
                    branch_target <= pc_in + {{24{operand1[7]}}, operand1[7:0]};
                end else begin
                    branch_taken <= 1'b0;
                end
                write_enable <= 1'b0;
            end

            OP_JMP: begin
                // Jump to address in operand1
                branch_taken <= 1'b1;
                branch_target <= operand1;
                write_enable <= 1'b0;
            end

            OP_JSR: begin
                // Jump to subroutine - save return address on stack
                // This is a multi-cycle operation:
                // Cycle 1: Write high word of PC to [SP-2]
                // Cycle 2: Write low word of PC to [SP-4], decrement SP, branch

                // Update stack pointer
                stack_ptr_out <= stack_pointer - 32'd4;
                stack_ptr_write <= 1'b1;

                // Save PC and target for multi-cycle operation
                saved_pc <= pc_in;
                return_addr <= ea_src;  // Save target address
                saved_opcode <= OP_JSR;

                // Start multi-cycle operation
                jsr_rts_state <= MULTI_FIRST;
                write_enable <= 1'b0;
                valid_out <= 1'b0;  // Not done yet
            end

            OP_RTS: begin
                // Return from subroutine - restore return address from stack
                // This is a multi-cycle operation:
                // Cycle 1: Read high word of return address from [SP]
                // Cycle 2: Read low word from [SP+2], increment SP, branch

                // Update stack pointer
                stack_ptr_out <= stack_pointer + 32'd4;
                stack_ptr_write <= 1'b1;

                // Save opcode for multi-cycle operation
                saved_opcode <= OP_RTS;

                // Start multi-cycle operation
                jsr_rts_state <= MULTI_FIRST;
                write_enable <= 1'b0;
                valid_out <= 1'b0;  // Not done yet
            end

            OP_BSR: begin
                // Branch to subroutine - save return address and branch
                // Similar to JSR but uses PC-relative addressing
                // This is a multi-cycle operation:
                // Cycle 1: Write high word of PC to [SP-2]
                // Cycle 2: Write low word of PC to [SP-4], decrement SP, branch to PC+disp

                // Update stack pointer
                stack_ptr_out <= stack_pointer - 32'd4;
                stack_ptr_write <= 1'b1;

                // Save PC and calculate target (PC + displacement from operand1)
                saved_pc <= pc_in;
                return_addr <= pc_in + operand1;  // PC-relative branch target
                saved_opcode <= OP_BSR;

                // Start multi-cycle operation (reuses JSR logic)
                jsr_rts_state <= MULTI_FIRST;
                write_enable <= 1'b0;
                valid_out <= 1'b0;  // Not done yet
            end

            OP_LEA: begin
                // LEA - Load Effective Address
                // Result is the calculated EA itself, not the value at that address
                result_out <= ea_src;
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

            OP_CLR: begin
                // Clear - set destination to 0
                result_out <= 32'h0;
                write_enable <= 1'b1;
                flags_out <= 5'b01000;  // N=0, Z=1, V=0, C=0, X unchanged
            end

            OP_NEG: begin
                // Negate - 0 - operand
                result_out <= alu_result;
                write_enable <= 1'b1;
                flags_out <= alu_flags;
            end

            OP_NOT: begin
                // Logical NOT - 1's complement
                result_out <= alu_result;
                write_enable <= 1'b1;
                flags_out <= alu_flags;
            end

            OP_TST: begin
                // Test - set flags only, no write
                write_enable <= 1'b0;
                flags_out <= alu_flags;
            end

            OP_LINK: begin
                // LINK An,#disp - Create stack frame
                // operand1 = SP, operand2 = An value, ea_src = displacement
                // 1. Push An onto stack
                // 2. Copy SP to An
                // 3. Add displacement to SP

                // For simplicity, doing this in one cycle (should be multi-cycle)
                // Push An onto stack
                mem_addr <= stack_pointer - 32'd4;
                mem_write <= 1'b1;
                mem_wdata <= operand2[15:0];  // Write An (low word)
                mem_uds <= 1'b1;
                mem_lds <= 1'b1;

                // Update An to point to old SP
                result_out <= stack_pointer;
                write_enable <= 1'b1;

                // Update SP = SP - 4 + displacement (from operand2 high bits or separate input)
                stack_ptr_out <= stack_pointer - 32'd4 + {{16{operand2[31]}}, operand2[31:16]};
                stack_ptr_write <= 1'b1;
            end

            OP_UNLK: begin
                // UNLK An - Destroy stack frame
                // operand1 = SP, operand2 = An value
                // 1. Copy An to SP
                // 2. Pop An from stack

                // Read An from stack
                mem_addr <= operand2;  // An value is the frame pointer
                mem_read <= 1'b1;
                mem_uds <= 1'b1;
                mem_lds <= 1'b1;

                // Restore SP from An
                stack_ptr_out <= operand2 + 32'd4;  // An + 4 (after pop)
                stack_ptr_write <= 1'b1;

                // Restore An from stack (would need mem_rdata in real implementation)
                result_out <= mem_rdata;  // Restore An value
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
