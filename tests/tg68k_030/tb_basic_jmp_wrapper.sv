`timescale 1ns/1ps

module tb_basic_jmp_wrapper;

localparam int LOW_BASE      = 32'h0000_0000;
localparam int LOW_BYTES     = 32'h0000_8000;
localparam int LOW_WORDS     = LOW_BYTES / 2;
localparam int HIGH0_BASE    = 32'h4200_0000;
localparam int HIGH0_BYTES   = 32'h000A_0000;
localparam int HIGH0_WORDS   = HIGH0_BYTES / 2;
localparam int OPC_BASE      = 32'h4205_0000;
localparam int OPC_BYTES     = 32'h0000_1000;
localparam int OPC_WORDS     = OPC_BYTES / 2;
localparam int BOOT_BASE     = 32'h4300_4000;
localparam int BOOT_BYTES    = 32'h0000_1000;
localparam int BOOT_WORDS    = BOOT_BYTES / 2;
localparam int BOOT_PC       = BOOT_BASE;
localparam int BOOT_STACK    = BOOT_BASE + BOOT_BYTES - 32'h40;

localparam int ISP_VALUE      = 32'h4200_07C0;
localparam int MSP_VALUE      = 32'h4200_0840;
localparam int JMP_FRAME_START = ISP_VALUE - 32'd8;
localparam int TRACE_VEC_ADDR = 32'h0000_1900;
localparam int EXC4_VEC_ADDR  = 32'h0000_18A0;
localparam int EXC6_VEC_ADDR  = 32'h0000_18C0;
localparam int EXC11_VEC_ADDR = 32'h0000_1940;
localparam int RESULT_TRACE_SP = 32'h4200_0F00;
localparam int RESULT_EXC4_SP  = 32'h4200_0F04;
localparam int RESULT_EXC6_SP  = 32'h4200_0F08;
localparam int RESULT_EXC11_SP = 32'h4200_0F0C;

localparam int CPUTEST020_VBR_BASE          = BOOT_BASE + 32'h0000_0B00;
localparam int CPUTEST020_TABLE_BASE        = BOOT_BASE + 32'h0000_0D00;
localparam int CPUTEST020_DEFAULT_HANDLER   = BOOT_BASE + 32'h0000_0C90;
localparam int CPUTEST020_EXC4_HANDLER      = BOOT_BASE + 32'h0000_0CA4;
localparam int CPUTEST020_EXC6_HANDLER      = BOOT_BASE + 32'h0000_0CB8;
localparam int CPUTEST020_TRACE_HANDLER     = BOOT_BASE + 32'h0000_0CCC;
localparam int CPUTEST020_EXC11_HANDLER     = BOOT_BASE + 32'h0000_0CD8;
localparam int CPUTEST020_JMP_ENTRY_PC      = BOOT_BASE + 32'h0000_0200;
localparam int CPUTEST020_HARNESS_RETURN_SP = BOOT_STACK - 32'd4;

localparam int JMP_USP_VALUE = 32'h4200_03FE;
localparam int LOW_OLD_ADDR_B = 32'h0000_008B;
localparam int LOW_OLD_ADDR_W = 32'h0000_008C;
localparam int HIGH_OLD_ADDR_B = 32'h4204_FEFF;
localparam int TARGET_PATCH_ADDR = 32'h4200_69B0;
localparam int TARGET_PATCH_ADDR_R43 = 32'h4200_3880;

reg clk = 1'b0;
reg reset_n = 1'b0;
wire reset = reset_n;
reg ph1 = 1'b0;
reg ph2 = 1'b1;

reg  [1:0] cpucfg = 2'b10;
reg  [2:0] fastramcfg = 3'b000;
reg  [2:0] cachecfg = 3'b000;
reg        bootrom = 1'b0;

wire [23:1] chip_addr;
reg  [15:0] chip_dout;
wire [15:0] chip_din;
wire        chip_as;
wire        chip_uds;
wire        chip_lds;
wire        chip_rw;
reg         chip_dtack = 1'b1;
reg   [2:0] chip_ipl = 3'b111;
reg         chip_dtack_armed = 1'b0;
reg         chip_cycle_active = 1'b0;
reg  [15:0] chip_dout_hold = 16'h4E71;
integer     trace_boot = 0;
reg [31:0]  last_trace_pc = 32'hFFFF_FFFF;

reg  [15:0] fastchip_dout = 16'h0000;
wire        fastchip_sel;
wire        fastchip_lds;
wire        fastchip_uds;
wire        fastchip_rnw;
wire        fastchip_lw;
reg         fastchip_selack = 1'b0;
wire        fastchip_ready = fastchip_selack;

wire        ramsel;
wire [28:1] ramaddr;
wire [15:0] ramdin;
reg  [15:0] ramdout;
wire        ramready = ramsel;
wire        ramlds;
wire        ramuds;
wire        ramshared;

wire        toccata_ena;
wire  [7:0] toccata_base;
wire  [1:0] cpustate;
wire [31:0] cacr;
wire [31:0] nmi_addr;
wire        cache_req;
wire [31:0] cache_addr;
reg  [15:0] cache_data = 16'h0000;
reg         cache_ack = 1'b0;
wire        cache_burst;
wire [2:0]  cache_burst_len;
wire [28:1] cache_ramaddr;
wire [6:0]  debug_fmt_err;
wire        walker_active_out;
wire        walker_writing_out;

reg [15:0] low_mem      [0:LOW_WORDS-1];
reg [15:0] low_mem_base [0:LOW_WORDS-1];
reg [15:0] high0_mem      [0:HIGH0_WORDS-1];
reg [15:0] high0_mem_base [0:HIGH0_WORDS-1];
reg [15:0] opc_mem      [0:OPC_WORDS-1];
reg [15:0] opc_mem_base [0:OPC_WORDS-1];
reg [15:0] boot_mem      [0:BOOT_WORDS-1];
reg [15:0] boot_mem_base [0:BOOT_WORDS-1];
reg [31:0] saved_reset_ssp = 32'h0000_0000;
reg [31:0] saved_reset_pc  = 32'h0000_0000;
reg        trace_handler_seen = 1'b0;
reg        first_trace_frame_valid = 1'b0;
reg [15:0] first_trace_frame_sr = 16'h0000;
reg [31:0] first_trace_frame_pc = 32'h0000_0000;
reg [31:0] trace_sp_slv = 32'h0000_0000;

cpu_wrapper #(.USE_68030_CACHE(1)) dut (
    .reset(reset),
    .reset_out(),
    .clk(clk),
    .ph1(ph1),
    .ph2(ph2),
    .cpucfg(cpucfg),
    .fastramcfg(fastramcfg),
    .cachecfg(cachecfg),
    .bootrom(bootrom),
    .chip_addr(chip_addr),
    .chip_dout(chip_dout),
    .chip_din(chip_din),
    .chip_as(chip_as),
    .chip_uds(chip_uds),
    .chip_lds(chip_lds),
    .chip_rw(chip_rw),
    .chip_dtack(chip_dtack),
    .chip_ipl(chip_ipl),
    .fastchip_dout(fastchip_dout),
    .fastchip_sel(fastchip_sel),
    .fastchip_lds(fastchip_lds),
    .fastchip_uds(fastchip_uds),
    .fastchip_rnw(fastchip_rnw),
    .fastchip_lw(fastchip_lw),
    .fastchip_selack(fastchip_selack),
    .fastchip_ready(fastchip_ready),
    .ramsel(ramsel),
    .ramaddr(ramaddr),
    .ramdin(ramdin),
    .ramdout(ramdout),
    .ramready(ramready),
    .ramlds(ramlds),
    .ramuds(ramuds),
    .ramshared(ramshared),
    .toccata_ena(toccata_ena),
    .toccata_base(toccata_base),
    .cpustate(cpustate),
    .cacr(cacr),
    .nmi_addr(nmi_addr),
    .cache_req(cache_req),
    .cache_addr(cache_addr),
    .cache_data(cache_data),
    .cache_ack(cache_ack),
    .cache_burst(cache_burst),
    .cache_burst_len(cache_burst_len),
    .cache_ramaddr(cache_ramaddr),
    .debug_fmt_err(debug_fmt_err),
    .walker_active_out(walker_active_out),
    .walker_writing_out(walker_writing_out)
);

always #5 clk = ~clk;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        ph1 <= 1'b0;
        ph2 <= 1'b1;
    end else begin
        ph1 <= ~ph1;
        ph2 <= ~ph2;
    end
end

function automatic integer high0_index(input integer addr);
begin
    high0_index = (addr - HIGH0_BASE) >> 1;
end
endfunction

function automatic integer opc_index(input integer addr);
begin
    opc_index = (addr - OPC_BASE) >> 1;
end
endfunction

function automatic integer boot_index(input integer addr);
begin
    boot_index = (addr - BOOT_BASE) >> 1;
end
endfunction

function automatic [7:0] read_byte_phys(input integer addr);
    integer base_addr;
    reg [15:0] word_val;
begin
    base_addr = addr & ~1;
    if (base_addr >= LOW_BASE && base_addr < LOW_BASE + LOW_BYTES)
        word_val = low_mem[(base_addr - LOW_BASE) >> 1];
    else if (base_addr >= OPC_BASE && base_addr < OPC_BASE + OPC_BYTES)
        word_val = opc_mem[opc_index(base_addr)];
    else if (base_addr >= HIGH0_BASE && base_addr < HIGH0_BASE + HIGH0_BYTES)
        word_val = high0_mem[high0_index(base_addr)];
    else if (base_addr >= BOOT_BASE && base_addr < BOOT_BASE + BOOT_BYTES)
        word_val = boot_mem[boot_index(base_addr)];
    else
        word_val = 16'h4E71;

    if (addr[0] == 1'b0)
        read_byte_phys = word_val[15:8];
    else
        read_byte_phys = word_val[7:0];
end
endfunction

function automatic [15:0] read_word_phys(input integer addr);
begin
    read_word_phys = {read_byte_phys(addr), read_byte_phys(addr + 1)};
end
endfunction

function automatic [15:0] read_bus_word_phys(input integer addr, input bit uds_n, input bit lds_n);
    integer base_addr;
begin
    base_addr = addr & ~1;
    if (!uds_n && !lds_n)
        read_bus_word_phys = {read_byte_phys(base_addr), read_byte_phys(base_addr + 1)};
    else if (!uds_n)
        read_bus_word_phys = {read_byte_phys(base_addr), 8'h00};
    else if (!lds_n)
        read_bus_word_phys = {8'h00, read_byte_phys(base_addr + 1)};
    else
        read_bus_word_phys = 16'hFFFF;
end
endfunction

function automatic [31:0] read_long_phys(input integer addr);
begin
    read_long_phys = {read_word_phys(addr), read_word_phys(addr + 2)};
end
endfunction

task automatic write_byte_phys(input integer addr, input [7:0] value);
    integer base_addr;
    reg [15:0] word_val;
begin
    base_addr = addr & ~1;
    word_val = read_word_phys(base_addr);
    if (addr[0] == 1'b0)
        word_val = {value, word_val[7:0]};
    else
        word_val = {word_val[15:8], value};

    if (base_addr >= LOW_BASE && base_addr < LOW_BASE + LOW_BYTES)
        low_mem[(base_addr - LOW_BASE) >> 1] = word_val;
    else if (base_addr >= OPC_BASE && base_addr < OPC_BASE + OPC_BYTES)
        opc_mem[opc_index(base_addr)] = word_val;
    else if (base_addr >= HIGH0_BASE && base_addr < HIGH0_BASE + HIGH0_BYTES)
        high0_mem[high0_index(base_addr)] = word_val;
    else if (base_addr >= BOOT_BASE && base_addr < BOOT_BASE + BOOT_BYTES)
        boot_mem[boot_index(base_addr)] = word_val;
end
endtask

task automatic write_word_phys(input integer addr, input [15:0] value);
begin
    write_byte_phys(addr, value[15:8]);
    write_byte_phys(addr + 1, value[7:0]);
end
endtask

task automatic write_long_phys(input integer addr, input [31:0] value);
begin
    write_word_phys(addr, value[31:16]);
    write_word_phys(addr + 2, value[15:0]);
end
endtask

task automatic emit_word(ref integer pc, input [15:0] value);
begin
    write_word_phys(pc, value);
    if (pc >= BOOT_BASE && pc < BOOT_BASE + BOOT_BYTES)
        boot_mem_base[boot_index(pc)] = value;
    pc = pc + 2;
end
endtask

task automatic emit_long(ref integer pc, input [31:0] value);
begin
    emit_word(pc, value[31:16]);
    emit_word(pc, value[15:0]);
end
endtask

task automatic emit_movel_imm_dn(ref integer pc, input integer regnum, input [31:0] value);
begin
    emit_word(pc, 16'h203C + (regnum * 16'h0200));
    emit_long(pc, value);
end
endtask

task automatic emit_movea_imm_an(ref integer pc, input integer regnum, input [31:0] value);
begin
    emit_word(pc, 16'h207C + (regnum * 16'h0200));
    emit_long(pc, value);
end
endtask

task automatic emit_jsr_abs(ref integer pc, input [31:0] value);
begin
    emit_word(pc, 16'h4EB9);
    emit_long(pc, value);
end
endtask

task automatic emit_movec_reg_to_ctrl(ref integer pc, input integer regsel, input integer ctrlsel);
begin
    emit_word(pc, 16'h4E7B);
    emit_word(pc, regsel * 16'h1000 + ctrlsel);
end
endtask

task automatic emit_set_usp_msp(ref integer pc, input [31:0] usp_value);
begin
    emit_movel_imm_dn(pc, 7, usp_value);
    emit_movec_reg_to_ctrl(pc, 7, 16'h0800);
    emit_movel_imm_dn(pc, 7, MSP_VALUE);
    emit_movec_reg_to_ctrl(pc, 7, 16'h0803);
end
endtask

task automatic write_bsr_s(input integer addr, input integer target);
    integer disp8;
begin
    disp8 = target - (addr + 2);
    if (disp8 < -128 || disp8 > 127) begin
        $display("FAIL: BSR.S target out of range addr=%08x target=%08x", addr, target);
        $finish(1);
    end
    write_word_phys(addr, {8'h61, disp8[7:0]});
end
endtask

task automatic load_word_image(input string filename);
    integer fd;
    integer code;
    integer addr;
    integer word;
    integer idx;
begin
    fd = $fopen(filename, "r");
    if (fd == 0) begin
        $display("FAIL: unable to open memory image %s", filename);
        $finish;
    end

    while (!$feof(fd)) begin
        code = $fscanf(fd, "%h %h\n", addr, word);
        if (code != 2)
            continue;

        if (addr >= LOW_BASE && addr < LOW_BASE + LOW_BYTES) begin
            idx = (addr - LOW_BASE) >> 1;
            low_mem_base[idx] = word[15:0];
        end else if (addr >= OPC_BASE && addr < OPC_BASE + OPC_BYTES) begin
            idx = opc_index(addr);
            opc_mem_base[idx] = word[15:0];
        end else if (addr >= HIGH0_BASE && addr < HIGH0_BASE + HIGH0_BYTES) begin
            idx = high0_index(addr);
            high0_mem_base[idx] = word[15:0];
        end else if (addr >= BOOT_BASE && addr < BOOT_BASE + BOOT_BYTES) begin
            idx = boot_index(addr);
            boot_mem_base[idx] = word[15:0];
        end
    end

    $fclose(fd);
end
endtask

task automatic load_mem_files;
begin
    for (int i = 0; i < LOW_WORDS; i++)
        low_mem_base[i] = 16'h0000;
    for (int i = 0; i < HIGH0_WORDS; i++)
        high0_mem_base[i] = 16'h0000;
    for (int i = 0; i < OPC_WORDS; i++)
        opc_mem_base[i] = 16'h0000;
    for (int i = 0; i < BOOT_WORDS; i++)
        boot_mem_base[i] = 16'h0000;

    load_word_image("data/cputest_basic_lmem.mem");
    load_word_image("data/cputest_basic_sparse.mem");

    for (int i = 0; i < LOW_WORDS; i++)
        low_mem[i] = low_mem_base[i];
    for (int i = 0; i < HIGH0_WORDS; i++)
        high0_mem[i] = high0_mem_base[i];
    for (int i = 0; i < OPC_WORDS; i++) begin
        opc_mem[i] = 16'h4E71;
        opc_mem_base[i] = 16'h4E71;
    end
    for (int i = 0; i < BOOT_WORDS; i++) begin
        boot_mem[i] = 16'h4E71;
        boot_mem_base[i] = 16'h4E71;
    end
end
endtask

task automatic install_cputest020_handler(input integer handler_addr, input [31:0] result_addr);
    integer pc;
begin
    pc = handler_addr;
    emit_word(pc, 16'h4FEF);
    emit_word(pc, 16'h0004);
    emit_word(pc, 16'h23CF);
    emit_long(pc, result_addr);
    emit_movea_imm_an(pc, 7, CPUTEST020_HARNESS_RETURN_SP);
    emit_word(pc, 16'h4E75);
end
endtask

task automatic install_cputest020_trace_handler;
    integer pc;
begin
    pc = CPUTEST020_TRACE_HANDLER;
    emit_word(pc, 16'h4FEF);
    emit_word(pc, 16'h0004);
    emit_word(pc, 16'h23CF);
    emit_long(pc, RESULT_TRACE_SP);
    emit_word(pc, 16'h4E73);
end
endtask

task automatic install_cputest020_exception_table;
    integer vector;
    integer entry_addr;
begin
    for (vector = 2; vector <= 63; vector = vector + 1) begin
        entry_addr = CPUTEST020_TABLE_BASE + ((vector - 2) * 2);
        case (vector)
            4: begin
                write_long_phys(CPUTEST020_VBR_BASE + vector * 4, entry_addr);
                write_bsr_s(entry_addr, CPUTEST020_EXC4_HANDLER);
            end
            6: begin
                write_long_phys(CPUTEST020_VBR_BASE + vector * 4, entry_addr);
                write_bsr_s(entry_addr, CPUTEST020_EXC6_HANDLER);
            end
            8: begin
                write_long_phys(CPUTEST020_VBR_BASE + vector * 4, entry_addr);
                write_bsr_s(entry_addr, CPUTEST020_DEFAULT_HANDLER);
            end
            9: begin
                write_long_phys(CPUTEST020_VBR_BASE + vector * 4, entry_addr);
                write_bsr_s(entry_addr, CPUTEST020_TRACE_HANDLER);
            end
            11: begin
                write_long_phys(CPUTEST020_VBR_BASE + vector * 4, entry_addr);
                write_bsr_s(entry_addr, CPUTEST020_EXC11_HANDLER);
            end
            default: begin
                write_long_phys(CPUTEST020_VBR_BASE + vector * 4, CPUTEST020_DEFAULT_HANDLER);
            end
        endcase
    end

    install_cputest020_handler(CPUTEST020_DEFAULT_HANDLER, RESULT_EXC4_SP);
    install_cputest020_handler(CPUTEST020_EXC4_HANDLER, RESULT_EXC4_SP);
    install_cputest020_handler(CPUTEST020_EXC6_HANDLER, RESULT_EXC6_SP);
    install_cputest020_trace_handler();
    install_cputest020_handler(CPUTEST020_EXC11_HANDLER, RESULT_EXC11_SP);
end
endtask

task automatic install_cputest020_boot(input [31:0] entry_pc);
    integer pc;
begin
    pc = BOOT_PC;
    emit_movea_imm_an(pc, 0, CPUTEST020_VBR_BASE);
    emit_movec_reg_to_ctrl(pc, 8, 16'h0801);
    emit_jsr_abs(pc, entry_pc);
    emit_word(pc, 16'h4E72);
    emit_word(pc, 16'h2700);
end
endtask

task automatic build_common_boot(ref integer pc, input [31:0] usp_value, input [31:0] frame_start);
begin
    emit_set_usp_msp(pc, usp_value);
    emit_movea_imm_an(pc, 0, 32'h0000_0000);
    emit_movea_imm_an(pc, 7, frame_start);
end
endtask

task automatic install_jmp_cputest020_boot(input [15:0] sr_value);
    integer pc;
begin
    install_cputest020_boot(CPUTEST020_JMP_ENTRY_PC);
    pc = CPUTEST020_JMP_ENTRY_PC;
    build_common_boot(pc, JMP_USP_VALUE, JMP_FRAME_START);
    emit_movel_imm_dn(pc, 0, 32'h0000_00B2);
    emit_word(pc, 16'h7200);
    emit_movel_imm_dn(pc, 2, 32'hFFFF_FD7F);
    emit_movel_imm_dn(pc, 3, 32'h0FFF_DF70);
    emit_movel_imm_dn(pc, 4, 32'h87FF_F0C1);
    emit_movel_imm_dn(pc, 5, 32'h8002_8282);
    emit_movel_imm_dn(pc, 6, 32'h0008_0808);
    emit_movel_imm_dn(pc, 7, 32'hAAAA_AAAA);
    emit_movea_imm_an(pc, 1, 32'h0000_008B);
    emit_movea_imm_an(pc, 2, 32'h0000_8014);
    emit_movea_imm_an(pc, 3, 32'h0000_FFFF);
    emit_movea_imm_an(pc, 4, 32'h7FFF_FF3A);
    emit_movea_imm_an(pc, 5, 32'h0FFF_FFF0);
    emit_movea_imm_an(pc, 6, 32'h4204_FEFF);
    emit_movea_imm_an(pc, 7, JMP_FRAME_START);
    emit_word(pc, 16'h4E73);

    write_word_phys(JMP_FRAME_START, sr_value);
    write_long_phys(JMP_FRAME_START + 2, OPC_BASE);
    write_word_phys(JMP_FRAME_START + 6, 16'h0000);

    write_word_phys(OPC_BASE + 32'h00, 16'h4EEF);
    write_word_phys(OPC_BASE + 32'h02, 16'h65B2);
    write_word_phys(OPC_BASE + 32'h04, 16'h4F04);
    write_word_phys(OPC_BASE + 32'h06, 16'h6100);
    write_word_phys(OPC_BASE + 32'h08, 16'h0000);
    write_word_phys(OPC_BASE + 32'h0A, 16'hA69C);
    write_word_phys(OPC_BASE + 32'h0C, 16'h00A3);
    write_word_phys(OPC_BASE + 32'h0E, 16'hB100);
    write_long_phys(TARGET_PATCH_ADDR, 32'h4AFC_2048);
    write_word_phys(32'h4204_FEF8, 16'hFF00);
    write_word_phys(32'h4204_FEFA, 16'h0000);
    write_word_phys(32'h4204_FEFC, 16'hB200);
    write_word_phys(32'h4204_FEFE, 16'h0010);
end
endtask

task automatic install_jmp_record43_boot(input [15:0] sr_value);
    integer pc;
begin
    install_cputest020_boot(CPUTEST020_JMP_ENTRY_PC);
    pc = CPUTEST020_JMP_ENTRY_PC;
    build_common_boot(pc, JMP_USP_VALUE, JMP_FRAME_START);
    emit_movel_imm_dn(pc, 0, 32'h0000_00B2);
    emit_word(pc, 16'h7200);
    emit_movel_imm_dn(pc, 2, 32'hFFFF_FD7F);
    emit_movel_imm_dn(pc, 3, 32'h0FFF_DF70);
    emit_movel_imm_dn(pc, 4, 32'h87FF_F0C1);
    emit_movel_imm_dn(pc, 5, 32'h8002_8282);
    emit_movel_imm_dn(pc, 6, 32'h0008_0808);
    emit_movel_imm_dn(pc, 7, 32'hAAAA_AAAA);
    emit_movea_imm_an(pc, 1, 32'h0000_008B);
    emit_movea_imm_an(pc, 2, 32'h0000_8014);
    emit_movea_imm_an(pc, 3, 32'h0000_FFFF);
    emit_movea_imm_an(pc, 4, 32'h7FFF_FF3A);
    emit_movea_imm_an(pc, 5, 32'h0FFF_FFF0);
    emit_movea_imm_an(pc, 6, 32'h4204_FEFF);
    emit_movea_imm_an(pc, 7, 32'h4200_03FE);
    emit_word(pc, 16'h4E73);

    write_word_phys(JMP_FRAME_START, sr_value);
    write_long_phys(JMP_FRAME_START + 2, OPC_BASE);
    write_word_phys(JMP_FRAME_START + 6, 16'h0000);

    write_word_phys(OPC_BASE + 32'h00, 16'h4EEF);
    write_word_phys(OPC_BASE + 32'h02, 16'h3482);
    write_word_phys(OPC_BASE + 32'h04, 16'h2048);
    write_word_phys(OPC_BASE + 32'h06, 16'h4AFC);
    write_long_phys(TARGET_PATCH_ADDR_R43, 32'h4AFC_2048);
end
endtask

task automatic set_reset_vectors;
begin
    write_long_phys(32'h0, BOOT_STACK);
    write_long_phys(32'h4, BOOT_PC);
    low_mem_base[0] = BOOT_STACK[31:16];
    low_mem_base[1] = BOOT_STACK[15:0];
    low_mem_base[2] = BOOT_PC[31:16];
    low_mem_base[3] = BOOT_PC[15:0];
end
endtask

task automatic init_common_cputest020;
begin
    load_mem_files();
    saved_reset_ssp = read_long_phys(32'h0);
    saved_reset_pc  = read_long_phys(32'h4);
    set_reset_vectors();
    install_cputest020_exception_table();
    write_long_phys(RESULT_TRACE_SP, 32'h0000_0000);
    write_long_phys(RESULT_EXC4_SP, 32'h0000_0000);
    write_long_phys(RESULT_EXC6_SP, 32'h0000_0000);
    write_long_phys(RESULT_EXC11_SP, 32'h0000_0000);
end
endtask

task automatic prepare_case(input [15:0] sr_value,
                            input bit preload_record18_lowmem,
                            input bit prime_expected_old_values);
begin
    init_common_cputest020();
    trace_handler_seen = 1'b0;
    first_trace_frame_valid = 1'b0;
    first_trace_frame_sr = 16'h0000;
    first_trace_frame_pc = 32'h0000_0000;
    install_jmp_cputest020_boot(sr_value);
    if (preload_record18_lowmem) begin
        write_word_phys(32'h0000_008A, 16'h4AFC);
        write_word_phys(32'h0000_008C, 16'h2048);
    end
    if (prime_expected_old_values) begin
        write_byte_phys(LOW_OLD_ADDR_B, 8'hFC);
        write_word_phys(LOW_OLD_ADDR_W, 16'h2048);
        write_byte_phys(HIGH_OLD_ADDR_B, 8'h54);
    end
end
endtask

task automatic prepare_case_record43(input [15:0] sr_value);
begin
    init_common_cputest020();
    trace_handler_seen = 1'b0;
    first_trace_frame_valid = 1'b0;
    first_trace_frame_sr = 16'h0000;
    first_trace_frame_pc = 32'h0000_0000;
    install_jmp_record43_boot(sr_value);
end
endtask

task automatic do_reset;
begin
    reset_n = 1'b0;
    repeat (20) @(posedge clk);
    reset_n = 1'b1;
end
endtask

task automatic restore_low_vectors;
begin
    repeat (40) @(posedge clk);
    write_long_phys(32'h0, saved_reset_ssp);
    write_long_phys(32'h4, saved_reset_pc);
end
endtask

task automatic run_case;
    integer cyc;
begin
    do_reset();
    restore_low_vectors();
    write_long_phys(RESULT_TRACE_SP, 32'h0000_0000);
    write_long_phys(RESULT_EXC4_SP, 32'h0000_0000);
    write_long_phys(RESULT_EXC6_SP, 32'h0000_0000);
    write_long_phys(RESULT_EXC11_SP, 32'h0000_0000);
    for (cyc = 0; cyc < 200000; cyc = cyc + 1) begin
        @(posedge clk);
        if (read_long_phys(RESULT_EXC11_SP) != 32'h0000_0000)
            return;
    end
    $display("FAIL: timeout waiting for RESULT_EXC11_SP, pc=%08x trace=%08x exc4=%08x exc6=%08x exc11=%08x",
             dut.kernel_TG68_PC_p, read_long_phys(RESULT_TRACE_SP), read_long_phys(RESULT_EXC4_SP),
             read_long_phys(RESULT_EXC6_SP), read_long_phys(RESULT_EXC11_SP));
    $finish(1);
end
endtask

task automatic check_case(input string name, input [15:0] expected_sr, input bit expect_trace);
    reg [7:0] low_b;
    reg [15:0] low_w;
    reg [7:0] high_b;
    reg [31:0] trace_sp;
    reg [31:0] exc11_sp;
    reg [15:0] trace_sr;
    reg [31:0] trace_pc;
begin
    low_b = read_byte_phys(LOW_OLD_ADDR_B);
    low_w = read_word_phys(LOW_OLD_ADDR_W);
    high_b = read_byte_phys(HIGH_OLD_ADDR_B);
    trace_sp = read_long_phys(RESULT_TRACE_SP);
    exc11_sp = read_long_phys(RESULT_EXC11_SP);
    if (first_trace_frame_valid) begin
        trace_sr = first_trace_frame_sr;
        trace_pc = first_trace_frame_pc;
    end else begin
        trace_sr = read_word_phys(trace_sp);
        trace_pc = read_long_phys(trace_sp + 2);
    end

    if (exc11_sp == 32'h0000_0000) begin
        $display("FAIL %s: missed exception 11 handler", name);
        $finish(1);
    end
    if (expect_trace && trace_sp == 32'h0000_0000) begin
        $display("FAIL %s: missed trace handler", name);
        $finish(1);
    end
    if (!expect_trace && trace_sp != 32'h0000_0000) begin
        $display("FAIL %s: unexpected trace handler sp=%08x", name, trace_sp);
        $finish(1);
    end
    if (expect_trace && trace_sr !== expected_sr) begin
        $display("FAIL %s: trace SR=%04x expected %04x", name, trace_sr, expected_sr);
        $finish(1);
    end
    if (expect_trace && trace_pc !== 32'h4200_6D72) begin
        $display("FAIL %s: trace PC=%08x expected 42006D72", name, trace_pc);
        $finish(1);
    end
    if (low_b !== 8'hFD || low_w !== 16'hEB48 || high_b !== 8'h75) begin
        $display("FAIL %s: low_b=%02x low_w=%04x high_b=%02x expected FD/EB48/75",
                 name, low_b, low_w, high_b);
        $finish(1);
    end
    $display("PASS %s: trace=%0d exc11_sp=%08x trace_sr=%04x trace_pc=%08x low_b=%02x low_w=%04x high_b=%02x",
             name, expect_trace, exc11_sp, trace_sr, trace_pc, low_b, low_w, high_b);
end
endtask

task automatic check_case_record43(input string name,
                                   input [15:0] expected_exc6_sr,
                                   input bit expect_trace,
                                   input [15:0] expected_trace_sr,
                                   input [31:0] expected_trace_pc);
    reg [31:0] trace_sp;
    reg [31:0] exc6_sp;
    reg [15:0] trace_sr;
    reg [31:0] trace_pc;
    reg [15:0] exc6_sr;
begin
    trace_sp = read_long_phys(RESULT_TRACE_SP);
    exc6_sp = read_long_phys(RESULT_EXC6_SP);
    exc6_sr = read_word_phys(exc6_sp);
    if (first_trace_frame_valid) begin
        trace_sr = first_trace_frame_sr;
        trace_pc = first_trace_frame_pc;
    end else begin
        trace_sr = read_word_phys(trace_sp);
        trace_pc = read_long_phys(trace_sp + 2);
    end

    if (exc6_sp == 32'h0000_0000) begin
        $display("FAIL %s: missed exception 6 handler", name);
        $finish(1);
    end
    if (exc6_sr !== expected_exc6_sr) begin
        $display("FAIL %s: exception 6 stacked SR=%04x expected %04x", name, exc6_sr, expected_exc6_sr);
        $finish(1);
    end
    if (expect_trace && trace_sp == 32'h0000_0000) begin
        $display("FAIL %s: missed trace handler", name);
        $finish(1);
    end
    if (!expect_trace && trace_sp != 32'h0000_0000) begin
        $display("FAIL %s: unexpected trace handler sp=%08x", name, trace_sp);
        $finish(1);
    end
    if (expect_trace && trace_sr !== expected_trace_sr) begin
        $display("FAIL %s: trace SR=%04x expected %04x", name, trace_sr, expected_trace_sr);
        $finish(1);
    end
    if (expect_trace && trace_pc !== expected_trace_pc) begin
        $display("FAIL %s: trace PC=%08x expected %08x", name, trace_pc, expected_trace_pc);
        $finish(1);
    end
    $display("PASS %s: exc6_sp=%08x exc6_sr=%04x trace=%0d trace_sr=%04x trace_pc=%08x",
             name, exc6_sp, exc6_sr, expect_trace, trace_sr, trace_pc);
end
endtask

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        chip_dtack <= 1'b1;
        chip_dtack_armed <= 1'b0;
        chip_cycle_active <= 1'b0;
        chip_dout_hold <= 16'h4E71;
    end else if (!chip_cycle_active && !ramsel && !dut.cpu_ready_qualified && dut.bus_addr < LOW_BYTES) begin
        chip_cycle_active <= 1'b1;
        chip_dout_hold <= read_word_phys(dut.bus_addr);
        chip_dtack <= 1'b0;
        chip_dtack_armed <= 1'b1;
    end else if (chip_as) begin
        chip_dtack <= 1'b1;
        chip_dtack_armed <= 1'b0;
        chip_cycle_active <= 1'b0;
    end else if (!chip_dtack_armed) begin
        if (!chip_cycle_active) begin
            chip_cycle_active <= 1'b1;
            if ({8'h00, chip_addr, 1'b0} < LOW_BYTES)
                chip_dout_hold <= read_bus_word_phys({8'h00, chip_addr, 1'b0}, chip_uds, chip_lds);
            else
                chip_dout_hold <= 16'h4E71;
        end
        chip_dtack <= 1'b1;
        chip_dtack_armed <= 1'b1;
    end else begin
        chip_dtack <= 1'b0;
    end
end

always @* begin
    chip_dout = chip_cycle_active ? chip_dout_hold : 16'h4E71;
    if (!ramsel && !fastchip_selack && dut.bus_addr < LOW_BYTES)
        chip_dout = read_bus_word_phys(dut.bus_addr, chip_uds, chip_lds);
    else if (!chip_cycle_active && ({8'h00, chip_addr, 1'b0} < LOW_BYTES))
        chip_dout = read_bus_word_phys({8'h00, chip_addr, 1'b0}, chip_uds, chip_lds);
end

always @* begin
    ramdout = 16'h4E71;
    if (ramsel)
        ramdout = read_bus_word_phys(dut.bus_addr, ramuds, ramlds);
end

always @(posedge clk) begin
    if (trace_boot != 0 && reset_n && $time <= 4000 && dut.kernel_TG68_PC_p !== last_trace_pc) begin
        $display("TRACE t=%0t pc=%08x op=%04x state=%0d ms=%0d bus=%08x readyq=%0d ramsel=%0d ramaddr=%08x chip_addr=%06x chip_data=%04x chip_stage=%0d chip_as=%0d dtack=%0d",
                 $time, dut.kernel_TG68_PC_p, dut.kernel_opcode_p, cpustate, dut.kernel_micro_state_p,
                 dut.bus_addr, dut.cpu_ready_qualified, ramsel, ramaddr, chip_addr, dut.chip_data,
                 dut.chip_stage, chip_as, chip_dtack);
        last_trace_pc <= dut.kernel_TG68_PC_p;
    end
end

always @(posedge clk) begin
    cache_ack <= 1'b0;
    if (cache_req) begin
        cache_ack <= 1'b1;
        cache_data <= 16'h4E71;
    end

    if (ramsel && cpustate == 2'b11) begin
        if (reset_n && dut.kernel_micro_state_p == 56 && !first_trace_frame_valid &&
            dut.bus_addr >= (ISP_VALUE - 32'h0000_0100) && dut.bus_addr < (MSP_VALUE + 32'h0000_0100)) begin
            first_trace_frame_sr <= ramdin;
            first_trace_frame_pc <= read_long_phys(dut.bus_addr + 2);
            first_trace_frame_valid <= 1'b1;
        end
        if (!ramuds)
            write_byte_phys(dut.bus_addr & ~1, ramdin[15:8]);
        if (!ramlds)
            write_byte_phys((dut.bus_addr & ~1) + 1, ramdin[7:0]);
    end
    if (!chip_as && !chip_rw) begin
        if (!chip_uds)
            write_byte_phys({8'h00, chip_addr, 1'b0}, chip_din[15:8]);
        if (!chip_lds)
            write_byte_phys({8'h00, chip_addr, 1'b0} + 1, chip_din[7:0]);
    end
    if (reset_n && cpustate == 2'b11) begin
        if (dut.bus_addr == RESULT_TRACE_SP)
            trace_handler_seen <= 1'b1;
        if ((dut.bus_addr == RESULT_TRACE_SP + 2) && !first_trace_frame_valid) begin
            trace_sp_slv = {read_word_phys(RESULT_TRACE_SP), ramdin};
            if (trace_sp_slv[31:16] != 16'h0000 && trace_sp_slv[15:0] != 16'h0000) begin
                first_trace_frame_sr <= read_word_phys(trace_sp_slv);
                first_trace_frame_pc <= read_long_phys(trace_sp_slv + 2);
                first_trace_frame_valid <= 1'b1;
            end
        end
    end
end

initial begin
    void'($value$plusargs("TRACE_BOOT=%d", trace_boot));
    force dut.z3ram_ena0 = 1'b1;
    force dut.z3ram_base0 = 5'd8;
    force dut.z3ram_ena1 = 1'b0;
    force dut.z2ram_ena = 1'b0;
    force dut.ac_memcard = 3'b000;
    force dut.ac_toccata = 1'b0;

    prepare_case(16'h2000, 1'b0, 1'b1);
    run_case();
    check_case("JMP record37 group1 wrapper", 16'h2000, 1'b0);

    prepare_case(16'h6000, 1'b0, 1'b1);
    run_case();
    check_case("JMP record37 group3 wrapper", 16'h6000, 1'b1);

    prepare_case(16'hA000, 1'b0, 1'b1);
    run_case();
    check_case("JMP record37 group5 wrapper", 16'hA000, 1'b1);

    prepare_case(16'hE000, 1'b0, 1'b1);
    run_case();
    check_case("JMP record37 group7 wrapper", 16'hE000, 1'b1);

    prepare_case(16'h2000, 1'b1, 1'b0);
    run_case();
    check_case("JMP record18-lowmem group1 wrapper", 16'h2000, 1'b0);

    prepare_case(16'h6000, 1'b1, 1'b0);
    run_case();
    check_case("JMP record18-lowmem group3 wrapper", 16'h6000, 1'b1);

    prepare_case_record43(16'h2000);
    run_case();
    check_case_record43("JMP record43 group1 wrapper", 16'h2011, 1'b0, 16'h0000, 32'h0000_0000);

    prepare_case_record43(16'h6000);
    run_case();
    check_case_record43("JMP record43 group3 wrapper", 16'h6011, 1'b1, 16'h6000, 32'h4200_3C42);

    $display("RESULT: 8 PASSED, 0 FAILED");
    $finish;
end

endmodule
