`timescale 1ns / 1ps

module minimig_ethernet_roundtrip_tb;

reg clk = 1'b0;
always #5 clk = ~clk;
reg verbose;

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

reg  [23:1] cpu_address;
wire [15:0] cpu_data;
reg  [15:0] cpudata_in;
reg         cpu_as_n;
reg         cpu_uds_n;
reg         cpu_lds_n;
reg         cpu_r_w;
wire        dtack_internal_n;
wire        dtack_cpu_n;
wire        cpu_rd;
wire        cpu_hwr;
wire        cpu_lwr;
wire        rd_cyc;
wire [23:1] cpu_address_out;
wire [15:0] cpu_data_out;
wire [15:0] cpu_data_in;

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
    ._as(cpu_as_n),
    ._lds(cpu_lds_n),
    ._uds(cpu_uds_n),
    .r_w(cpu_r_w),
    ._dtack(dtack_internal_n),
    .rd(cpu_rd),
    .hwr(cpu_hwr),
    .lwr(cpu_lwr),
    .address(cpu_address),
    .address_out(cpu_address_out),
    .data(cpu_data),
    .cpudatain(cpudata_in),
    .data_out(cpu_data_out),
    .data_in(cpu_data_in),
    .rd_cyc(rd_cyc),
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

wire [23:1] ram_address_out;
wire [15:0] gary_data_out;
wire [15:0] custom_data_in;
wire [15:0] ram_data_in;
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

gary gary_inst (
    .cpu_address_in(cpu_address_out),
    .dma_address_in(20'h00000),
    .ram_address_out(ram_address_out),
    .cpu_data_out(cpu_data_out),
    .cpu_data_in(gary_data_out),
    .custom_data_out(16'h0000),
    .custom_data_in(custom_data_in),
    .ram_data_out(16'h0000),
    .ram_data_in(ram_data_in),
    .a1k(1'b0),
    .bootrom(1'b0),
    .clk(clk),
    .reset(!reset_n),
    .cpu_rd(cpu_rd),
    .cpu_hwr(cpu_hwr),
    .cpu_lwr(cpu_lwr),
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
    .ethernet_ena(1'b1),
    .ethernet_base(8'hEA),
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

wire [15:0] ethernet_data_out;
wire        dtack_eth_n;
reg         dtack_eth_aligned_n = 1'b1;
wire        sel_ethernet_shm = sel_ethernet && (cpu_address_out[15:12] >= 4'h1);
reg         eth_dma_ready = 1'b0;
reg [15:0] eth_dma_rdata = 16'h0000;
wire        eth_dma_req;

ethernet_interface ethernet_inst (
    .clk(clk),
    .reset(!reset_n),
    .cpu_addr(cpu_address_out[15:1]),
    .cpu_data_in(cpu_data_out),
    .cpu_data_out(ethernet_data_out),
    .cpu_rd(cpu_rd),
    .cpu_hwr(cpu_hwr),
    .cpu_lwr(cpu_lwr),
    .cpu_as(cpu_as_n),
    .cpu_uds(cpu_uds_n),
    .cpu_lds(cpu_lds_n),
    .sel_ethernet_shm(sel_ethernet_shm),
    .sel_ethernet(sel_ethernet),
    .eth_dma_ready(eth_dma_ready),
    .eth_dma_rdata(eth_dma_rdata),
    .eth_dma_req(eth_dma_req),
    .eth_dma_write(),
    .eth_dma_addr(),
    .eth_dma_wdata(),
    .eth_dma_uds(),
    .eth_dma_lds(),
    .eth_irq(),
    .dtack_eth(dtack_eth_n)
);

always @(posedge clk) begin
    eth_dma_ready <= eth_dma_req;
    eth_dma_rdata <= 16'h0000;
end

always @(posedge clk) begin
    if (cpu_as_n || !sel_ethernet) begin
        dtack_eth_aligned_n <= 1'b1;
    end else if (!dtack_eth_n && !c1 && c3) begin
        dtack_eth_aligned_n <= 1'b0;
    end
end

assign dtack_cpu_n = sel_ethernet ? dtack_eth_aligned_n : dtack_internal_n;
assign cpu_data_in = gary_data_out | ethernet_data_out;

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

task automatic cpu_read_word_expect;
    input [23:0] byte_addr;
    input [15:0] expected_nonzero;
    input [255:0] label;
    integer cycles;
    begin
        cpu_address = byte_addr[23:1];
        cpu_r_w = 1'b1;
        cpu_uds_n = 1'b0;
        cpu_lds_n = 1'b0;
        wait_posedges(2);
        cpu_as_n = 1'b0;

        cycles = 0;
        while (dtack_cpu_n && cycles < 80) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            if (verbose) begin
                $display("TRACE %0s cyc=%0d c1c3cck=%b%b%b en=%b ldata=%04x as=%b int_dtack=%b eth_dtack=%b cpu_dtack=%b rd=%b sel=%b addr=%06x eth_out=%04x data_in=%04x cpu_data=%04x",
                         label, cycles, c1, c3, cck, bridge.enable, bridge.ldata_in,
                         cpu_as_n, dtack_internal_n, dtack_eth_n, dtack_cpu_n, cpu_rd,
                         sel_ethernet, {cpu_address_out, 1'b0}, ethernet_data_out,
                         cpu_data_in, cpu_data);
            end
        end

        if (dtack_cpu_n) begin
            $display("FAIL: %0s timed out waiting for CPU DTACK", label);
            $fatal(1);
        end

        if (verbose) begin
            $display("SAMPLE %0s cpu_data=%04x eth_out=%04x data_in=%04x int_dtack=%b eth_dtack=%b",
                     label, cpu_data, ethernet_data_out, cpu_data_in,
                     dtack_internal_n, dtack_eth_n);
        end

        if (ethernet_data_out !== expected_nonzero) begin
            $display("FAIL: %0s ethernet module expected %04x got %04x",
                     label, expected_nonzero, ethernet_data_out);
            $fatal(1);
        end

        if (cpu_data !== expected_nonzero) begin
            $display("FAIL: %0s bridge CPU data expected %04x got %04x",
                     label, expected_nonzero, cpu_data);
            $fatal(1);
        end

        cpu_as_n = 1'b1;
        cpu_uds_n = 1'b1;
        cpu_lds_n = 1'b1;
        wait_posedges(8);
    end
endtask

task automatic cpu_write_high_byte;
    input [23:0] byte_addr;
    input [7:0]  value;
    input [255:0] label;
    integer cycles;
    begin
        cpu_address = byte_addr[23:1];
        cpudata_in = {value, 8'h00};
        cpu_r_w = 1'b0;
        cpu_uds_n = 1'b0;
        cpu_lds_n = 1'b1;
        wait_posedges(2);
        cpu_as_n = 1'b0;

        cycles = 0;
        while (dtack_cpu_n && cycles < 80) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            if (verbose) begin
                $display("TRACE %0s cyc=%0d c1c3cck=%b%b%b int_dtack=%b eth_dtack=%b cpu_dtack=%b hwr=%b sel=%b addr=%06x din=%04x",
                         label, cycles, c1, c3, cck, dtack_internal_n,
                         dtack_eth_n, dtack_cpu_n, cpu_hwr, sel_ethernet,
                         {cpu_address_out, 1'b0}, cpu_data_out);
            end
        end

        if (dtack_cpu_n) begin
            $display("FAIL: %0s timed out waiting for CPU DTACK", label);
            $fatal(1);
        end

        cpu_as_n = 1'b1;
        cpu_uds_n = 1'b1;
        cpu_lds_n = 1'b1;
        cpu_r_w = 1'b1;
        wait_posedges(8);
    end
endtask

initial begin
    verbose = $test$plusargs("trace");
    cpu_address = 23'h000000;
    cpudata_in = 16'h0000;
    cpu_as_n = 1'b1;
    cpu_uds_n = 1'b1;
    cpu_lds_n = 1'b1;
    cpu_r_w = 1'b1;

    wait_posedges(8);
    reset_n = 1'b1;
    wait_posedges(16);

    cpu_read_word_expect(24'hEA0000, 16'hFFFF, "ethernet unused aperture dummy read");
    cpu_read_word_expect(24'hEA1000, 16'hFFFF, "ethernet mailbox aperture dummy read");
    cpu_read_word_expect(24'hEA0C28, 16'h5050, "RTL8019 ID0 word read");
    cpu_read_word_expect(24'hEA0C2C, 16'h7070, "RTL8019 ID1 word read");
    cpu_write_high_byte(24'hEA0C38, 8'h01, "DCR word mode write");
    cpu_write_high_byte(24'hEA0C20, 8'h00, "RSAR0 station PROM write");
    cpu_write_high_byte(24'hEA0C24, 8'h00, "RSAR1 station PROM write");
    cpu_write_high_byte(24'hEA0C28, 8'h02, "RBCR0 station PROM write");
    cpu_write_high_byte(24'hEA0C2C, 8'h00, "RBCR1 station PROM write");
    cpu_read_word_expect(24'hEA0C40, 16'h5252, "RTL8019 data port station PROM read");

    $display("PASS: minimig_ethernet_roundtrip_tb completed");
    $finish;
end

endmodule
