`timescale 1ns / 1ps

module gary_ethernet_decode_tb;

reg  [23:1] cpu_address_in;
reg  [20:1] dma_address_in;
wire [23:1] ram_address_out;
reg  [15:0] cpu_data_out;
wire [15:0] cpu_data_in;
reg  [15:0] custom_data_out;
wire [15:0] custom_data_in;
reg  [15:0] ram_data_out;
wire [15:0] ram_data_in;
reg         a1k;
reg         bootrom;
reg         clk;
reg         reset;
reg         cpu_rd;
reg         cpu_hwr;
reg         cpu_lwr;
reg         cpu_hlt;
reg         ovl;
reg         dbr;
reg         dbwe;
wire        dbs;
wire        xbs;
reg  [3:0]  memory_config;
reg         ecs;
reg         hdc_ena;
reg         toccata_ena;
reg  [7:0]  toccata_base;
reg         ethernet_ena;
reg  [7:0]  ethernet_base;
wire        ram_rd;
wire        ram_hwr;
wire        ram_lwr;
wire        sel_reg;
wire [3:0]  sel_chip;
wire [2:0]  sel_slow;
wire        sel_kick;
wire        sel_kick1mb;
wire        sel_kick256kmirror;
wire        sel_cia;
wire        sel_cia_a;
wire        sel_cia_b;
wire        sel_rtg;
wire        sel_rtc;
wire        sel_ide;
wire        sel_gayle;
wire        sel_toccata;
wire        sel_ethernet;
wire        rom_readonly;

gary dut (
    .cpu_address_in(cpu_address_in),
    .dma_address_in(dma_address_in),
    .ram_address_out(ram_address_out),
    .cpu_data_out(cpu_data_out),
    .cpu_data_in(cpu_data_in),
    .custom_data_out(custom_data_out),
    .custom_data_in(custom_data_in),
    .ram_data_out(ram_data_out),
    .ram_data_in(ram_data_in),
    .a1k(a1k),
    .bootrom(bootrom),
    .clk(clk),
    .reset(reset),
    .cpu_rd(cpu_rd),
    .cpu_hwr(cpu_hwr),
    .cpu_lwr(cpu_lwr),
    .cpu_hlt(cpu_hlt),
    .ovl(ovl),
    .dbr(dbr),
    .dbwe(dbwe),
    .dbs(dbs),
    .xbs(xbs),
    .memory_config(memory_config),
    .ecs(ecs),
    .hdc_ena(hdc_ena),
    .toccata_ena(toccata_ena),
    .toccata_base(toccata_base),
    .ethernet_ena(ethernet_ena),
    .ethernet_base(ethernet_base),
    .ram_rd(ram_rd),
    .ram_hwr(ram_hwr),
    .ram_lwr(ram_lwr),
    .sel_reg(sel_reg),
    .sel_chip(sel_chip),
    .sel_slow(sel_slow),
    .sel_kick(sel_kick),
    .sel_kick1mb(sel_kick1mb),
    .sel_kick256kmirror(sel_kick256kmirror),
    .sel_cia(sel_cia),
    .sel_cia_a(sel_cia_a),
    .sel_cia_b(sel_cia_b),
    .sel_rtg(sel_rtg),
    .sel_rtc(sel_rtc),
    .sel_ide(sel_ide),
    .sel_gayle(sel_gayle),
    .sel_toccata(sel_toccata),
    .sel_ethernet(sel_ethernet),
    .rom_readonly(rom_readonly)
);

task check_sel;
    input [23:0] byte_addr;
    input        expected;
    input [255:0] label;
    begin
        cpu_address_in = byte_addr[23:1];
        #1;
        if (sel_ethernet !== expected) begin
            $display("FAIL: %0s addr=%06x expected sel_ethernet=%0d got=%0d",
                     label, byte_addr, expected, sel_ethernet);
            $fatal(1);
        end
    end
endtask

initial begin
    cpu_address_in = 23'h000000;
    dma_address_in = 20'h00000;
    cpu_data_out = 16'h0000;
    custom_data_out = 16'h0000;
    ram_data_out = 16'h0000;
    a1k = 1'b0;
    bootrom = 1'b0;
    clk = 1'b0;
    reset = 1'b0;
    cpu_rd = 1'b1;
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_hlt = 1'b0;
    ovl = 1'b0;
    dbr = 1'b0;
    dbwe = 1'b0;
    memory_config = 4'h0;
    ecs = 1'b0;
    hdc_ena = 1'b0;
    toccata_ena = 1'b0;
    toccata_base = 8'hE9;
    ethernet_ena = 1'b1;
    ethernet_base = 8'hEA;

    check_sel(24'hEA0000, 1'b1, "ethernet aperture first word");
    check_sel(24'hEA0BFE, 1'b1, "ethernet aperture before RTL8019 register window");
    check_sel(24'hEA0C00, 1'b1, "RTL8019 register first word");
    check_sel(24'hEA0C3E, 1'b1, "RTL8019 register last word");
    check_sel(24'hEA0C40, 1'b1, "RTL8019 data port first word");
    check_sel(24'hEA0C5E, 1'b1, "RTL8019 data port last word");
    check_sel(24'hEA0C60, 1'b1, "RTL8019 debug/reset first word");
    check_sel(24'hEA0C7E, 1'b1, "RTL8019 debug/reset last word");
    check_sel(24'hEA0C80, 1'b1, "ethernet aperture after RTL8019 debug/reset window");
    check_sel(24'hEA0620, 1'b1, "ethernet aperture old data-port misdecode window");
    check_sel(24'hEA0630, 1'b1, "ethernet aperture old debug-port misdecode window");
    check_sel(24'hEA1800, 1'b1, "ethernet mailbox aperture address");
    check_sel(24'hEAFFFE, 1'b1, "ethernet aperture last word");
    check_sel(24'hEB0C00, 1'b0, "wrong ethernet base");

    ethernet_ena = 1'b0;
    check_sel(24'hEA0C00, 1'b0, "ethernet disabled");

    $display("PASS: gary_ethernet_decode_tb completed");
    $finish;
end

endmodule
