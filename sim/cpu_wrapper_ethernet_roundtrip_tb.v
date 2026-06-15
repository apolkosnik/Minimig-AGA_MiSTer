`timescale 1ns / 1ps

module TG68KdotC_Kernel
#(
    parameter sr_read = 0,
    parameter vbr_stackframe = 0,
    parameter extaddr_mode = 0,
    parameter mul_mode = 0,
    parameter div_mode = 0,
    parameter bitfield = 0
)
(
    input         clk,
    input         nreset,
    input         clkena_in,
    input  [15:0] data_in,
    input  [2:0]  ipl,
    input         ipl_autovector,
    output        regin_out,
    output reg [31:0] addr_out,
    output reg [15:0] data_write,
    output reg        nwr,
    output reg        nuds,
    output reg        nlds,
    output reg        nresetout,
    output reg        longword,
    input  [1:0]  cpu,
    output reg [1:0]  busstate,
    output reg [3:0]  cacr_out,
    output reg [31:0] vbr_out
);
    assign regin_out = 1'b0;

    initial begin
        addr_out = 32'h00000000;
        data_write = 16'h0000;
        nwr = 1'b1;
        nuds = 1'b1;
        nlds = 1'b1;
        nresetout = 1'b1;
        longword = 1'b0;
        busstate = 2'b01;
        cacr_out = 4'h0;
        vbr_out = 32'h00000000;
    end
endmodule

module fx68k
(
    input         clk,
    input         enPhi1,
    input         enPhi2,
    input         extReset,
    input         pwrUp,
    output        oRESETn,
    input         HALTn,
    output        eRWn,
    output        ASn,
    output        LDSn,
    output        UDSn,
    input         DTACKn,
    output        FC0,
    output        FC1,
    output        FC2,
    input         VPAn,
    input         BERRn,
    input         BRn,
    input         BGACKn,
    input         IPL0n,
    input         IPL1n,
    input         IPL2n,
    input  [15:0] iEdb,
    output [15:0] oEdb,
    output [23:1] eab
);
    assign oRESETn = 1'b1;
    assign eRWn = 1'b1;
    assign ASn = 1'b1;
    assign LDSn = 1'b1;
    assign UDSn = 1'b1;
    assign FC0 = 1'b1;
    assign FC1 = 1'b1;
    assign FC2 = 1'b1;
    assign oEdb = 16'h0000;
    assign eab = 23'h000000;
endmodule

module cpu_wrapper_ethernet_roundtrip_tb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg [3:0] div = 4'h0;
reg       ph1 = 1'b0;
reg       ph2 = 1'b0;
always @(posedge clk) begin
    div <= div + 4'h1;
    ph1 <= 1'b0;
    ph2 <= 1'b0;
    if (div[1] && !div[0]) begin
        case (div[3:2])
            2'd0: ph2 <= 1'b1;
            2'd2: ph1 <= 1'b1;
            default: begin
                ph1 <= 1'b0;
                ph2 <= 1'b0;
            end
        endcase
    end
end

wire clk7_en;
wire clk7n_en;
wire c1;
wire c3;
wire cck;
wire [9:0] eclk;
reg reset_n = 1'b0;

amiga_clk clocks (
    .clk_28(clk),
    .clk7_en(clk7_en),
    .clk7n_en(clk7n_en),
    .c1(c1),
    .c3(c3),
    .cck(cck),
    .eclk(eclk),
    .reset_n(reset_n)
);

wire [23:1] chip_addr;
wire [15:0] chip_dout;
wire [15:0] chip_din;
wire        chip_as;
wire        chip_uds;
wire        chip_lds;
wire        chip_rw;
wire        chip_dtack;
wire [2:0]  chip_ipl = 3'b111;

wire        ethernet_ena;
wire [7:0]  ethernet_base;
wire        sel_ethernet_shm;
wire        sel_ethernet;
wire        cpu_wrap_eth_irq;

cpu_wrapper cpu_wrap (
    .reset(reset_n),
    .reset_out(),
    .clk(clk),
    .ph1(ph1),
    .ph2(ph2),
    .cpucfg(2'b01),
    .fastramcfg(3'b000),
    .cachecfg(3'b000),
    .bootrom(1'b0),
    .chip_addr(chip_addr),
    .chip_dout(chip_dout),
    .chip_din(chip_din),
    .chip_as(chip_as),
    .chip_uds(chip_uds),
    .chip_lds(chip_lds),
    .chip_rw(chip_rw),
    .chip_dtack(chip_dtack),
    .chip_ipl(chip_ipl),
    .fastchip_dout(16'h0000),
    .fastchip_sel(),
    .fastchip_lds(),
    .fastchip_uds(),
    .fastchip_rnw(),
    .fastchip_lw(),
    .fastchip_selack(1'b0),
    .fastchip_ready(1'b0),
    .ramsel(),
    .ramaddr(),
    .ramdin(),
    .ramdout(16'h0000),
    .ramready(1'b1),
    .ramlds(),
    .ramuds(),
    .ramshared(),
    .toccata_ena(),
    .toccata_base(),
    .sel_ethernet(sel_ethernet),
    .ethernet_cfg_ena(1'b1),
    .ethernet_ena(ethernet_ena),
    .ethernet_base(ethernet_base),
    .sel_ethernet_shm(sel_ethernet_shm),
    .eth_irq(cpu_wrap_eth_irq),
    .cpustate(),
    .cacr(),
    .nmi_addr()
);

wire        bridge_cpu_rd;
wire        bridge_cpu_hwr;
wire        bridge_cpu_lwr;
wire        bridge_rd_cyc;
wire [23:1] bridge_cpu_address_out;
wire [15:0] bridge_cpu_data_out;
wire [15:0] bridge_cpu_data_in;
wire        bridge_dtack_internal_n;
wire        dtack_eth_n;
reg         dtack_eth_aligned_n = 1'b1;
wire        dbs;
wire        xbs;
wire        bls;

minimig_m68k_bridge bridge (
    .clk(clk),
    .clk7_en(clk7_en),
    .clk7n_en(clk7n_en),
    .c1(c1),
    .c3(c3),
    .eclk(eclk),
    .vpa(1'b0),
    .dbr(1'b0),
    .dbs(dbs),
    .xbs(xbs),
    .nrdy(1'b0),
    .bls(bls),
    .cck(cck),
    .memory_config(4'h0),
    ._as(chip_as),
    ._lds(chip_lds),
    ._uds(chip_uds),
    .r_w(chip_rw),
    ._dtack(bridge_dtack_internal_n),
    .rd(bridge_cpu_rd),
    .hwr(bridge_cpu_hwr),
    .lwr(bridge_cpu_lwr),
    .address(chip_addr),
    .address_out(bridge_cpu_address_out),
    .data(chip_dout),
    .cpudatain(chip_din),
    .data_out(bridge_cpu_data_out),
    .data_in(bridge_cpu_data_in),
    .rd_cyc(bridge_rd_cyc),
    ._cpu_reset(1'b1),
    .cpu_halt(1'b0),
    .host_cs(1'b0),
    .host_adr(23'h000000),
    .host_we(1'b0),
    .host_bs(2'b00),
    .host_wdat(16'h0000),
    .host_rdat(),
    .host_ack()
);

wire [15:0] gary_data_out;
wire [15:0] ethernet_data_out;

gary gary_inst (
    .cpu_address_in(bridge_cpu_address_out),
    .dma_address_in(20'h00000),
    .ram_address_out(),
    .cpu_data_out(bridge_cpu_data_out),
    .cpu_data_in(gary_data_out),
    .custom_data_out(16'h0000),
    .custom_data_in(),
    .ram_data_out(16'h0000),
    .ram_data_in(),
    .a1k(1'b0),
    .bootrom(1'b0),
    .clk(clk),
    .reset(!reset_n),
    .cpu_rd(bridge_cpu_rd),
    .cpu_hwr(bridge_cpu_hwr),
    .cpu_lwr(bridge_cpu_lwr),
    .cpu_hlt(1'b0),
    .ovl(1'b0),
    .dbr(1'b0),
    .dbwe(1'b0),
    .dbs(dbs),
    .xbs(xbs),
    .memory_config(4'h0),
    .ecs(1'b0),
    .hdc_ena(1'b0),
    .toccata_ena(1'b0),
    .toccata_base(8'hE9),
    .ethernet_ena(ethernet_ena),
    .ethernet_base(ethernet_base),
    .ram_rd(),
    .ram_hwr(),
    .ram_lwr(),
    .sel_reg(),
    .sel_chip(),
    .sel_slow(),
    .sel_kick(),
    .sel_kick1mb(),
    .sel_kick256kmirror(),
    .sel_cia(),
    .sel_cia_a(),
    .sel_cia_b(),
    .sel_rtg(),
    .sel_rtc(),
    .sel_ide(),
    .sel_gayle(),
    .sel_toccata(),
    .sel_ethernet(sel_ethernet),
    .rom_readonly()
);

ethernet_interface ethernet_inst (
    .clk(clk),
    .reset(!reset_n),
    .cpu_addr(bridge_cpu_address_out[15:1]),
    .cpu_data_in(bridge_cpu_data_out),
    .cpu_data_out(ethernet_data_out),
    .cpu_rd(bridge_cpu_rd),
    .cpu_hwr(bridge_cpu_hwr),
    .cpu_lwr(bridge_cpu_lwr),
    .cpu_as(chip_as),
    .cpu_uds(chip_uds),
    .cpu_lds(chip_lds),
    .sel_ethernet_shm(sel_ethernet_shm),
    .sel_ethernet(sel_ethernet),
    .eth_dma_ready(1'b0),
    .eth_dma_rdata(16'h0000),
    .eth_dma_rdata64(64'h0),
    .eth_dma_req(),
    .eth_dma_write(),
    .eth_dma_addr(),
    .eth_dma_wdata(),
    .eth_dma_wide(),
    .eth_dma_wdata64(),
    .eth_dma_uds(),
    .eth_dma_lds(),
    .eth_irq(),
    .dtack_eth(dtack_eth_n)
);

always @(posedge clk) begin
    if (chip_as || !sel_ethernet) begin
        dtack_eth_aligned_n <= 1'b1;
    end else if (!dtack_eth_n && !c1 && c3) begin
        dtack_eth_aligned_n <= 1'b0;
    end
end

assign chip_dtack = sel_ethernet ? dtack_eth_aligned_n : bridge_dtack_internal_n;
assign bridge_cpu_data_in = gary_data_out | ethernet_data_out;

task automatic wait_posedges;
    input integer count;
    integer i;
    begin
        for (i = 0; i < count; i = i + 1) begin
            @(posedge clk);
            #1;
        end
    end
endtask

task automatic cpu_release;
    begin
        force cpu_wrap.cpu_inst_p.busstate = 2'b01;
        force cpu_wrap.cpu_inst_p.nwr = 1'b1;
        force cpu_wrap.cpu_inst_p.nuds = 1'b1;
        force cpu_wrap.cpu_inst_p.nlds = 1'b1;
    end
endtask

task automatic cpu_read_expect;
    input [31:0] byte_addr;
    input [15:0] expected;
    input [255:0] label;
    integer cycles;
    begin
        force cpu_wrap.cpu_inst_p.addr_out = byte_addr;
        force cpu_wrap.cpu_inst_p.data_write = 16'h0000;
        force cpu_wrap.cpu_inst_p.nwr = 1'b1;
        force cpu_wrap.cpu_inst_p.nuds = 1'b0;
        force cpu_wrap.cpu_inst_p.nlds = 1'b0;
        force cpu_wrap.cpu_inst_p.longword = 1'b0;
        force cpu_wrap.cpu_inst_p.busstate = 2'b10;
        #1;

        cycles = 0;
        while (!cpu_wrap.cpu_clkena && cycles < 220) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (!cpu_wrap.cpu_clkena) begin
            $display("FAIL: %0s timed out waiting for cpu_wrapper CPU enable", label);
            $fatal(1);
        end

        if (cpu_wrap.cpu_din !== expected) begin
            $display("FAIL: %0s cpu_din expected %04x got %04x chipdout_i=%04x chip_dout=%04x eth_out=%04x chip_dtack=%b remote=%04x count=%04x dprd=%04x",
                     label, expected, cpu_wrap.cpu_din, cpu_wrap.chipdout_i,
                     chip_dout, ethernet_data_out, chip_dtack,
                     ethernet_inst.remote_dma_addr, ethernet_inst.remote_byte_count,
                     ethernet_inst.data_port_read_data);
            $fatal(1);
        end

        cpu_release();
        wait_posedges(10);
    end
endtask

task automatic cpu_write_high_byte;
    input [31:0] byte_addr;
    input [7:0]  value;
    input [255:0] label;
    integer cycles;
    begin
        force cpu_wrap.cpu_inst_p.addr_out = byte_addr;
        force cpu_wrap.cpu_inst_p.data_write = {value, 8'h00};
        force cpu_wrap.cpu_inst_p.nwr = 1'b0;
        force cpu_wrap.cpu_inst_p.nuds = 1'b0;
        force cpu_wrap.cpu_inst_p.nlds = 1'b1;
        force cpu_wrap.cpu_inst_p.longword = 1'b0;
        force cpu_wrap.cpu_inst_p.busstate = 2'b11;
        #1;

        cycles = 0;
        while (!cpu_wrap.cpu_clkena && cycles < 220) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (!cpu_wrap.cpu_clkena) begin
            $display("FAIL: %0s timed out waiting for cpu_wrapper CPU enable", label);
            $fatal(1);
        end

        cpu_release();
        wait_posedges(10);
end
endtask

task automatic cpu_read_unused_card_space_expect_dummy;
    input [31:0] byte_addr;
    input [255:0] label;
    integer cycles;
    begin
        force cpu_wrap.cpu_inst_p.addr_out = byte_addr;
        force cpu_wrap.cpu_inst_p.data_write = 16'h0000;
        force cpu_wrap.cpu_inst_p.nwr = 1'b1;
        force cpu_wrap.cpu_inst_p.nuds = 1'b0;
        force cpu_wrap.cpu_inst_p.nlds = 1'b0;
        force cpu_wrap.cpu_inst_p.longword = 1'b0;
        force cpu_wrap.cpu_inst_p.busstate = 2'b10;
        #1;

        if (!cpu_wrap.sel_ethernet_card_cpu) begin
            $display("FAIL: %0s did not select Ethernet card wait-state path", label);
            $fatal(1);
        end

        cycles = 0;
        while (!cpu_wrap.cpu_clkena && cycles < 220) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (!cpu_wrap.cpu_clkena) begin
            $display("FAIL: %0s timed out waiting for dummy Ethernet aperture DTACK", label);
            $fatal(1);
        end

        if (cpu_wrap.cpu_din !== 16'hFFFF) begin
            $display("FAIL: %0s dummy Ethernet aperture read expected FFFF got %04x",
                     label, cpu_wrap.cpu_din);
            $fatal(1);
        end

        cpu_release();
        wait_posedges(10);
end
endtask

task automatic cpu_read_mailbox_marker_is_not_ram;
    input [31:0] byte_addr;
    input [255:0] label;
    integer cycles;
    begin
        force cpu_wrap.cpu_inst_p.addr_out = byte_addr;
        force cpu_wrap.cpu_inst_p.data_write = 16'h0000;
        force cpu_wrap.cpu_inst_p.nwr = 1'b1;
        force cpu_wrap.cpu_inst_p.nuds = 1'b0;
        force cpu_wrap.cpu_inst_p.nlds = 1'b0;
        force cpu_wrap.cpu_inst_p.longword = 1'b0;
        force cpu_wrap.cpu_inst_p.busstate = 2'b10;
        #1;

        if (!cpu_wrap.sel_ethernet_shm) begin
            $display("FAIL: %0s should still mark the Ethernet mailbox window", label);
            $fatal(1);
        end

        if (cpu_wrap.ramsel || cpu_wrap.ramshared) begin
            $display("FAIL: %0s incorrectly routed mailbox marker to CPU RAM path", label);
            $fatal(1);
        end

        if (!cpu_wrap.sel_ethernet_card_cpu) begin
            $display("FAIL: %0s did not select Ethernet card wait-state path", label);
            $fatal(1);
        end

        cycles = 0;
        while (!cpu_wrap.cpu_clkena && cycles < 220) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (!cpu_wrap.cpu_clkena) begin
            $display("FAIL: %0s timed out waiting for dummy mailbox DTACK", label);
            $fatal(1);
        end

        if (cpu_wrap.cpu_din !== 16'hFFFF) begin
            $display("FAIL: %0s CPU-visible mailbox dummy read expected FFFF got %04x",
                     label, cpu_wrap.cpu_din);
            $fatal(1);
        end

        cpu_release();
        wait_posedges(10);
    end
endtask

initial begin
    force cpu_wrap.cpu_inst_p.nresetout = 1'b1;
    force cpu_wrap.cpu_inst_p.cacr_out = 4'h0;
    force cpu_wrap.cpu_inst_p.vbr_out = 32'h00000000;
    force cpu_wrap.cpu_inst_p.addr_out = 32'h00000000;
    force cpu_wrap.cpu_inst_p.data_write = 16'h0000;
    force cpu_wrap.cpu_inst_p.nwr = 1'b1;
    force cpu_wrap.cpu_inst_p.nuds = 1'b1;
    force cpu_wrap.cpu_inst_p.nlds = 1'b1;
    force cpu_wrap.cpu_inst_p.longword = 1'b0;
    force cpu_wrap.cpu_inst_p.busstate = 2'b01;

    wait_posedges(12);
    reset_n = 1'b1;
    wait_posedges(20);
    force cpu_wrap.ac_ethernet = 1'b0;
    force cpu_wrap.ethernet_base = 8'hEA;

    cpu_read_unused_card_space_expect_dummy(32'h00EA0000, "EA0000 dummy card read");
    cpu_read_mailbox_marker_is_not_ram(32'h00EA1000, "EA1000 mailbox marker read");
    cpu_read_expect(32'h00EA0C28, 16'h5050, "cpu_wrapper RTL8019 ID0 read");
    cpu_read_expect(32'h00EA0C2C, 16'h7070, "cpu_wrapper RTL8019 ID1 read");
    $display("PASS: cpu_wrapper_ethernet_roundtrip_tb completed");
    $finish;
end

endmodule
