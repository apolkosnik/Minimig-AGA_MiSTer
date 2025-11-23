//------------------------------------------------------------------------------
// MC68060 Instruction Fetch Unit
// Handles multi-word instruction prefetch with branch prediction support
//------------------------------------------------------------------------------

module MC68060_FetchUnit
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    input  wire [31:0] pc_in,
    input  wire        branch_taken,
    input  wire [31:0] branch_target,

    // Instruction length feedback from decode
    input  wire [2:0]  instr_words,    // How many words in current instruction (1-5)
    input  wire        instr_consumed, // Instruction was consumed by decode

    input  wire        icache_enable,
    input  wire        icache_hit,

    output reg  [31:0] mem_addr,
    input  wire [15:0] mem_data,
    input  wire        mem_ready,

    // Multi-word instruction output
    output reg  [15:0] instr_word0,    // Opcode word (always valid)
    output reg  [15:0] instr_word1,    // Extension word 1
    output reg  [15:0] instr_word2,    // Extension word 2
    output reg  [15:0] instr_word3,    // Extension word 3
    output reg  [2:0]  words_valid,    // How many words are valid (1-4)
    output reg  [31:0] pc_out,
    output reg         valid_out
);

// Prefetch buffer - holds up to 4 words
reg [15:0] prefetch_buffer[0:3];
reg [2:0]  buffer_count;           // How many valid words in buffer (0-4)
reg [31:0] buffer_pc;              // PC of first word in buffer
reg [1:0]  fetch_state;
reg [31:0] next_fetch_addr;

localparam FETCH_IDLE   = 2'd0;
localparam FETCH_WORD   = 2'd1;
localparam FETCH_WAIT   = 2'd2;

always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        prefetch_buffer[0] <= 16'h0;
        prefetch_buffer[1] <= 16'h0;
        prefetch_buffer[2] <= 16'h0;
        prefetch_buffer[3] <= 16'h0;
        buffer_count <= 3'd0;
        buffer_pc <= 32'h0;
        fetch_state <= FETCH_IDLE;
        next_fetch_addr <= 32'h0;
        valid_out <= 1'b0;
        instr_word0 <= 16'h0;
        instr_word1 <= 16'h0;
        instr_word2 <= 16'h0;
        instr_word3 <= 16'h0;
        words_valid <= 3'd0;
        pc_out <= 32'h0;
        mem_addr <= 32'h0;
    end else if (enable) begin

        // Handle branch - flush prefetch buffer
        if (branch_taken) begin
            buffer_count <= 3'd0;
            buffer_pc <= branch_target;
            next_fetch_addr <= branch_target;
            fetch_state <= FETCH_IDLE;
            valid_out <= 1'b0;
        end

        // Handle instruction consumption - remove consumed words from buffer
        else if (instr_consumed && valid_out) begin
            // Shift buffer by instr_words positions
            case (instr_words)
                3'd1: begin
                    prefetch_buffer[0] <= prefetch_buffer[1];
                    prefetch_buffer[1] <= prefetch_buffer[2];
                    prefetch_buffer[2] <= prefetch_buffer[3];
                    prefetch_buffer[3] <= 16'h0;
                    buffer_count <= (buffer_count > 3'd1) ? (buffer_count - 3'd1) : 3'd0;
                    buffer_pc <= buffer_pc + 32'd2;  // PC advances by 2 bytes per word
                end
                3'd2: begin
                    prefetch_buffer[0] <= prefetch_buffer[2];
                    prefetch_buffer[1] <= prefetch_buffer[3];
                    prefetch_buffer[2] <= 16'h0;
                    prefetch_buffer[3] <= 16'h0;
                    buffer_count <= (buffer_count > 3'd2) ? (buffer_count - 3'd2) : 3'd0;
                    buffer_pc <= buffer_pc + 32'd4;
                end
                3'd3: begin
                    prefetch_buffer[0] <= prefetch_buffer[3];
                    prefetch_buffer[1] <= 16'h0;
                    prefetch_buffer[2] <= 16'h0;
                    prefetch_buffer[3] <= 16'h0;
                    buffer_count <= (buffer_count > 3'd3) ? (buffer_count - 3'd3) : 3'd0;
                    buffer_pc <= buffer_pc + 32'd6;
                end
                default: begin
                    // instr_words >= 4
                    prefetch_buffer[0] <= 16'h0;
                    prefetch_buffer[1] <= 16'h0;
                    prefetch_buffer[2] <= 16'h0;
                    prefetch_buffer[3] <= 16'h0;
                    buffer_count <= 3'd0;
                    buffer_pc <= buffer_pc + {29'd0, instr_words} * 32'd2;
                end
            endcase
        end

        // Prefetch state machine - keep buffer full
        case (fetch_state)
            FETCH_IDLE: begin
                if (buffer_count < 3'd4) begin
                    // Need to fetch more words
                    if (buffer_count == 3'd0) begin
                        // Buffer empty - start from pc_in or buffer_pc
                        next_fetch_addr <= (branch_taken) ? branch_target :
                                          (buffer_count == 3'd0 && !valid_out) ? pc_in : buffer_pc;
                    end else begin
                        // Buffer has some words - fetch next word after last valid word
                        next_fetch_addr <= buffer_pc + {29'd0, buffer_count} * 32'd2;
                    end
                    mem_addr <= next_fetch_addr;
                    fetch_state <= FETCH_WORD;
                end
            end

            FETCH_WORD: begin
                fetch_state <= FETCH_WAIT;
            end

            FETCH_WAIT: begin
                if (mem_ready) begin
                    // Store fetched word in buffer
                    if (buffer_count < 3'd4) begin
                        prefetch_buffer[buffer_count] <= mem_data;
                        buffer_count <= buffer_count + 3'd1;
                    end
                    fetch_state <= FETCH_IDLE;
                end
            end

            default: fetch_state <= FETCH_IDLE;
        endcase

        // Output current instruction words from buffer
        if (buffer_count > 3'd0) begin
            instr_word0 <= prefetch_buffer[0];
            instr_word1 <= (buffer_count > 3'd1) ? prefetch_buffer[1] : 16'h0;
            instr_word2 <= (buffer_count > 3'd2) ? prefetch_buffer[2] : 16'h0;
            instr_word3 <= (buffer_count > 3'd3) ? prefetch_buffer[3] : 16'h0;
            words_valid <= buffer_count;
            pc_out <= buffer_pc;
            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end
end

endmodule
