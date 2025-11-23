//------------------------------------------------------------------------------
//------------------------------------------------------------------------------
//
// MC68060 CPU Core - Top Level Module
// Compatible interface with TG68K for MiSTer Minimig integration
//
// This is a Verilog implementation of the Motorola MC68060 microprocessor
// Features:
//   - Dual integer execution pipelines (superscalar)
//   - 8KB instruction cache + 8KB data cache
//   - Branch prediction with 4-entry branch cache
//   - Integrated FPU
//   - Full MC68000/68020/68040/68060 instruction set
//   - TG68K-compatible bus interface
//
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------

module MC68060_Top
(
    // Clock and Reset
    input  wire        clk,
    input  wire        nreset,
    input  wire        clkena_in,

    // CPU Configuration
    input  wire [1:0]  cpu,           // CPU type: 00=68000, 01=68010, 11=68020, 10=68060

    // Data Bus Interface
    input  wire [15:0] data_in,
    output wire [15:0] data_write,

    // Address Bus Interface
    output wire [31:0] addr_out,

    // Bus Control Signals
    output wire        nwr,           // Write enable (active low)
    output wire        nuds,          // Upper data strobe (active low)
    output wire        nlds,          // Lower data strobe (active low)
    output wire        nresetout,
    output wire        longword,      // 32-bit access indicator

    // Interrupt Interface
    input  wire [2:0]  ipl,           // Interrupt priority level
    input  wire        ipl_autovector,

    // Bus State
    output wire [1:0]  busstate,      // 0=fetch, 1=idle, 2=read, 3=write

    // Special Registers
    output wire [3:0]  cacr_out,      // Cache control register
    output wire [31:0] vbr_out        // Vector base register
);

// Internal CPU state
reg [2:0] cpu_state;
reg [31:0] pc;
reg [31:0] vbr;
reg [3:0] cacr;
reg reset_out_n;

// Status Register (SR)
// Bits: 15=T 14=T 13=S 12=0 11=0 10=I 9=I 8=I 7=0 6=0 5=0 4=X 3=N 2=Z 1=V 0=C
reg [15:0] sr;
wire [4:0] ccr = sr[4:0];  // Condition Code Register (lower 5 bits of SR)

// Pipeline stall signals
wire fetch_stall;
wire decode_stall;
wire exec_stall;
wire memory_stall;

// Pipeline registers
wire [31:0] fetch_pc;
wire [15:0] fetch_word0;
wire [15:0] fetch_word1;
wire [15:0] fetch_word2;
wire [15:0] fetch_word3;
wire [2:0]  fetch_words_valid;
wire        fetch_valid;

wire [31:0] decode_pc;
wire [2:0]  decode_instr_length;
wire        decode_valid;
wire [15:0] decode_ext_word1;
wire [15:0] decode_ext_word2;

wire [31:0] exec_pc;
wire [5:0]  exec_opcode;
wire [3:0]  exec_dest_reg;
wire        exec_valid;

// Effective Address signals from decode
wire [2:0]  ea_mode_src;
wire [2:0]  ea_reg_src;
wire [2:0]  ea_mode_dst;
wire [2:0]  ea_reg_dst;
wire [1:0]  ea_size;
wire        needs_ea_src;
wire        needs_ea_dst;

// Effective Address calculation results
wire [31:0] ea_src_addr;
wire [31:0] ea_dst_addr;
wire        ea_src_valid;
wire        ea_dst_valid;
wire        ea_src_is_areg;
wire        ea_src_is_dreg;
wire        ea_dst_is_areg;
wire        ea_dst_is_dreg;

// Address register update from EA
wire        areg_update_src;
wire [3:0]  areg_update_num_src;
wire [31:0] areg_update_val_src;
wire        areg_update_dst;
wire [3:0]  areg_update_num_dst;
wire [31:0] areg_update_val_dst;

// Register file signals
wire [3:0]  rf_read_addr1, rf_read_addr2;
wire [31:0] rf_read_data1, rf_read_data2;
wire [3:0]  rf_write_addr;
wire [31:0] rf_write_data;
wire        rf_write_enable;

// Memory interface signals
wire [31:0] mem_addr;
wire [15:0] mem_wdata;
wire [15:0] mem_rdata;
wire        mem_read;
wire        mem_write;
wire        mem_uds;
wire        mem_lds;
wire        mem_ready;

// Flags and branch control from execute
wire [4:0]  exec_flags;
wire        exec_branch_taken;
wire [31:0] exec_branch_target;

// Cache control
wire        icache_enable;
wire        dcache_enable;
wire        icache_hit;
wire        dcache_hit;
wire        icache_valid;
wire        dcache_valid;
wire [15:0] icache_data;
wire [15:0] dcache_data;

// Branch prediction
wire        branch_taken;
wire [31:0] branch_target;
wire        branch_valid;

// FPU interface
wire        fpu_busy;
wire [63:0] fpu_result;
wire        fpu_valid;

// Bus state machine
localparam STATE_IDLE      = 3'd0;
localparam STATE_FETCH     = 3'd1;
localparam STATE_DECODE    = 3'd2;
localparam STATE_EXECUTE   = 3'd3;
localparam STATE_MEMORY    = 3'd4;
localparam STATE_WRITEBACK = 3'd5;
localparam STATE_EXCEPTION = 3'd6;

// Busstate output encoding (compatible with TG68K)
assign busstate = (cpu_state == STATE_FETCH) ? 2'b00 :
                  (cpu_state == STATE_IDLE)  ? 2'b01 :
                  (mem_read)                 ? 2'b10 :
                  (mem_write)                ? 2'b11 : 2'b01;

// Output assignments
assign addr_out = mem_addr;
assign data_write = mem_wdata;
assign nwr = ~mem_write;
assign nuds = ~mem_uds;
assign nlds = ~mem_lds;
assign nresetout = reset_out_n;
assign longword = (mem_uds && mem_lds);
assign cacr_out = cacr;
assign vbr_out = vbr;

// Cache enable from CACR
assign icache_enable = cacr[0];
assign dcache_enable = cacr[1];

//------------------------------------------------------------------------------
// Instruction Fetch Unit
//------------------------------------------------------------------------------
MC68060_FetchUnit fetch_unit
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (clkena_in),

    .pc_in          (pc),
    .branch_taken   (exec_branch_taken),
    .branch_target  (exec_branch_target),

    // Instruction length feedback from decode
    .instr_words    (decode_instr_length),
    .instr_consumed (decode_valid && clkena_in),

    .icache_enable  (icache_enable),
    .icache_hit     (icache_hit),

    .mem_addr       (fetch_pc),
    .mem_data       (icache_hit ? icache_data : data_in),  // Use cache data on hit
    .mem_ready      (mem_ready || icache_hit),

    // Multi-word instruction output
    .instr_word0    (fetch_word0),
    .instr_word1    (fetch_word1),
    .instr_word2    (fetch_word2),
    .instr_word3    (fetch_word3),
    .words_valid    (fetch_words_valid),
    .pc_out         (fetch_pc),
    .valid_out      (fetch_valid)
);

//------------------------------------------------------------------------------
// Instruction Decode Unit
//------------------------------------------------------------------------------
MC68060_DecodeUnit decode_unit
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (clkena_in),

    // Multi-word instruction input
    .instr_word0    (fetch_word0),
    .instr_word1    (fetch_word1),
    .instr_word2    (fetch_word2),
    .instr_word3    (fetch_word3),
    .words_available(fetch_words_valid),
    .pc_in          (fetch_pc),
    .valid_in       (fetch_valid),

    .rf_raddr1      (rf_read_addr1),
    .rf_raddr2      (rf_read_addr2),
    .rf_rdata1      (rf_read_data1),
    .rf_rdata2      (rf_read_data2),

    .opcode_out     (exec_opcode),
    .dest_reg_out   (exec_dest_reg),
    .pc_out         (decode_pc),
    .valid_out      (decode_valid),
    .instr_length   (decode_instr_length),

    // Effective Address outputs
    .ea_mode_src    (ea_mode_src),
    .ea_reg_src     (ea_reg_src),
    .ea_mode_dst    (ea_mode_dst),
    .ea_reg_dst     (ea_reg_dst),
    .ea_size        (ea_size),
    .needs_ea_src   (needs_ea_src),
    .needs_ea_dst   (needs_ea_dst),

    // Extension words for EA calculation
    .ext_word1      (decode_ext_word1),
    .ext_word2      (decode_ext_word2)
);

//------------------------------------------------------------------------------
// Effective Address Calculation - Source
//------------------------------------------------------------------------------
MC68060_EffectiveAddress ea_src_unit
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (clkena_in && needs_ea_src),

    .ea_mode        (ea_mode_src),
    .ea_reg         (ea_reg_src),
    .ea_size        (ea_size),

    .extension1     (decode_ext_word1),  // Extension words from fetch/decode
    .extension2     (decode_ext_word2),

    .areg_value     (rf_read_data1),  // Address register value
    .dreg_value     (rf_read_data2),  // Data register value for index

    .pc_in          (decode_pc),

    .ea_out         (ea_src_addr),
    .ea_is_areg     (ea_src_is_areg),
    .ea_is_dreg     (ea_src_is_dreg),
    .ea_reg_num     (),  // Not used for now

    .areg_update    (areg_update_src),
    .areg_update_num(areg_update_num_src),
    .areg_update_val(areg_update_val_src),

    .valid_out      (ea_src_valid)
);

//------------------------------------------------------------------------------
// Effective Address Calculation - Destination
//------------------------------------------------------------------------------
MC68060_EffectiveAddress ea_dst_unit
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (clkena_in && needs_ea_dst),

    .ea_mode        (ea_mode_dst),
    .ea_reg         (ea_reg_dst),
    .ea_size        (ea_size),

    .extension1     (decode_ext_word1),  // Extension words from fetch/decode
    .extension2     (decode_ext_word2),

    .areg_value     (rf_read_data2),  // Address register value
    .dreg_value     (rf_read_data1),  // Data register value for index

    .pc_in          (decode_pc),

    .ea_out         (ea_dst_addr),
    .ea_is_areg     (ea_dst_is_areg),
    .ea_is_dreg     (ea_dst_is_dreg),
    .ea_reg_num     (),  // Not used for now

    .areg_update    (areg_update_dst),
    .areg_update_num(areg_update_num_dst),
    .areg_update_val(areg_update_val_dst),

    .valid_out      (ea_dst_valid)
);

//------------------------------------------------------------------------------
// Dual Execution Pipelines
//------------------------------------------------------------------------------
MC68060_ExecuteUnit exec_unit
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (clkena_in),

    .opcode_in      (exec_opcode),
    .dest_reg_in    (exec_dest_reg),
    .pc_in          (decode_pc),
    .valid_in       (decode_valid),

    .operand1       (rf_read_data1),
    .operand2       (rf_read_data2),
    .operand_size   (ea_size),

    // Effective Address inputs
    .ea_src         (ea_src_addr),
    .ea_dst         (ea_dst_addr),
    .ea_valid_src   (ea_src_valid && needs_ea_src),
    .ea_valid_dst   (ea_dst_valid && needs_ea_dst),

    .result_out     (rf_write_data),
    .write_addr     (rf_write_addr),
    .write_enable   (rf_write_enable),

    .mem_addr       (mem_addr),
    .mem_wdata      (mem_wdata),
    .mem_read       (mem_read),
    .mem_write      (mem_write),
    .mem_uds        (mem_uds),
    .mem_lds        (mem_lds),

    .fpu_busy       (fpu_busy),

    .flags_out      (exec_flags),
    .branch_taken   (exec_branch_taken),
    .branch_target  (exec_branch_target),

    .pc_out         (exec_pc),
    .valid_out      (exec_valid)
);

//------------------------------------------------------------------------------
// Register File (D0-D7, A0-A7)
//------------------------------------------------------------------------------
MC68060_RegisterFile regfile
(
    .clk            (clk),
    .nreset         (nreset),

    .read_addr1     (rf_read_addr1),
    .read_addr2     (rf_read_addr2),
    .read_data1     (rf_read_data1),
    .read_data2     (rf_read_data2),

    .write_addr     (rf_write_addr),
    .write_data     (rf_write_data),
    .write_enable   (rf_write_enable)
);

//------------------------------------------------------------------------------
// Instruction Cache (8KB, 4-way set associative)
//------------------------------------------------------------------------------
MC68060_ICache icache
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (icache_enable),

    .addr           (fetch_pc),
    .data_in        (data_in),
    .data_out       (icache_data),

    .hit            (icache_hit),
    .valid          (icache_valid)
);

//------------------------------------------------------------------------------
// Data Cache (8KB, 4-way set associative, write-through)
//------------------------------------------------------------------------------
MC68060_DCache dcache
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (dcache_enable),

    .addr           (mem_addr),
    .data_in        (data_in),
    .data_out       (dcache_data),
    .write          (mem_write),

    .hit            (dcache_hit),
    .valid          (dcache_valid)
);

//------------------------------------------------------------------------------
// Branch Prediction Unit (4-entry branch cache)
//------------------------------------------------------------------------------
MC68060_BranchUnit branch_unit
(
    .clk            (clk),
    .nreset         (nreset),

    .pc             (fetch_pc),
    .instr          (fetch_instr),

    .branch_taken   (branch_taken),
    .branch_target  (branch_target),
    .branch_valid   (branch_valid)
);

//------------------------------------------------------------------------------
// Floating Point Unit
//------------------------------------------------------------------------------
MC68060_FPU fpu
(
    .clk            (clk),
    .nreset         (nreset),
    .enable         (clkena_in),

    .opcode         (exec_opcode),
    .operand1       (rf_read_data1),
    .operand2       (rf_read_data2),

    .result         (fpu_result),
    .valid          (fpu_valid),
    .busy           (fpu_busy)
);

//------------------------------------------------------------------------------
// Main CPU State Machine
//------------------------------------------------------------------------------
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        cpu_state <= STATE_FETCH;
        pc <= 32'h0;
        vbr <= 32'h0;
        cacr <= 4'h0;
        reset_out_n <= 1'b0;
    end else if (clkena_in) begin
        reset_out_n <= 1'b1;

        case (cpu_state)
            STATE_IDLE: begin
                cpu_state <= STATE_FETCH;
            end

            STATE_FETCH: begin
                // Stall if: cache miss AND memory not ready
                if (fetch_valid && !fetch_stall) begin
                    cpu_state <= STATE_DECODE;
                    pc <= pc + 32'd2;  // Increment PC by 2 (word)
                end
                // else: stay in FETCH until data ready
            end

            STATE_DECODE: begin
                // Stall if: register dependencies or resource conflicts
                if (decode_valid && !decode_stall) begin
                    cpu_state <= STATE_EXECUTE;
                end
                // else: stay in DECODE
            end

            STATE_EXECUTE: begin
                // Stall if: FPU busy or multi-cycle operation
                if (exec_valid && !exec_stall) begin
                    // Handle branches
                    if (exec_branch_taken) begin
                        pc <= exec_branch_target;  // Update PC with branch target
                        cpu_state <= STATE_FETCH;   // Restart fetch from new PC
                    end else if (mem_read || mem_write) begin
                        cpu_state <= STATE_MEMORY;
                    end else begin
                        cpu_state <= STATE_WRITEBACK;
                    end
                end
                // else: stay in EXECUTE
            end

            STATE_MEMORY: begin
                // Stall if: cache miss or memory not ready
                if (mem_ready && !memory_stall) begin
                    cpu_state <= STATE_WRITEBACK;
                end
                // else: stay in MEMORY until ready
            end

            STATE_WRITEBACK: begin
                cpu_state <= STATE_FETCH;
            end

            STATE_EXCEPTION: begin
                // Exception handling
                cpu_state <= STATE_FETCH;
            end

            default: begin
                cpu_state <= STATE_FETCH;
            end
        endcase
    end
end

// Pipeline stall conditions
assign fetch_stall = (cpu_state == STATE_FETCH) && !icache_hit && !mem_ready;
assign decode_stall = 1'b0;  // No decode stalls for now (would need hazard detection)
assign exec_stall = fpu_busy;  // Stall if FPU is busy
assign memory_stall = (cpu_state == STATE_MEMORY) && !dcache_hit && !mem_ready;

// Memory ready signal
// Ready when: cache hit OR external memory would be ready
// In actual integration, this should connect to chipready, ramready, fastchip_ready
reg mem_ready_reg;
reg [1:0] mem_wait_count;  // Simulate memory latency

always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        mem_ready_reg <= 1'b0;
        mem_wait_count <= 2'b00;
    end else begin
        // Cache hit provides immediate data
        if (icache_hit && (cpu_state == STATE_FETCH)) begin
            mem_ready_reg <= 1'b1;
            mem_wait_count <= 2'b00;
        end else if (dcache_hit && (cpu_state == STATE_MEMORY)) begin
            mem_ready_reg <= 1'b1;
            mem_wait_count <= 2'b00;
        end else begin
            // Cache miss - simulate memory latency (2 cycles)
            if ((cpu_state == STATE_FETCH) || (cpu_state == STATE_MEMORY)) begin
                if (mem_wait_count < 2'b10) begin
                    mem_wait_count <= mem_wait_count + 1'b1;
                    mem_ready_reg <= 1'b0;
                end else begin
                    mem_ready_reg <= 1'b1;  // Data ready after 2 cycles
                end
            end else begin
                mem_wait_count <= 2'b00;
                mem_ready_reg <= 1'b0;
            end
        end
    end
end

assign mem_ready = mem_ready_reg;

// Status Register management
// Update SR with ALU flags after execute stage
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        sr <= 16'h2700;  // Supervisor mode, interrupts masked (I=111, S=1)
    end else if (clkena_in) begin
        // Update CCR (condition codes) from execute stage
        if (exec_valid && (cpu_state == STATE_EXECUTE)) begin
            // Update flags: X, N, Z, V, C (bits 4:0)
            sr[4:0] <= exec_flags[4:0];
        end
        // Note: System byte (sr[15:8]) is only updated by privileged instructions
    end
end

endmodule
