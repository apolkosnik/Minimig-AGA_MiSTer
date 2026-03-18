`timescale 1ns / 1ps

module ethernet_tb;

reg clk;
reg reset;

reg [15:1] cpu_addr;
reg [15:0] cpu_data_in;
wire [15:0] cpu_data_out;
reg cpu_rd;
reg cpu_hwr;
reg cpu_lwr;
reg cpu_as;
reg cpu_uds;
reg cpu_lds;

reg sel_ethernet_shm;
reg sel_ethernet;
reg [7:0] ethernet_base;
reg        eth_dma_ready;
reg [15:0] eth_dma_rdata;

wire eth_irq;
wire dtack_eth;
wire        eth_dma_req;
wire        eth_dma_write;
wire [15:1] eth_dma_addr;
wire [15:0] eth_dma_wdata;
wire        eth_dma_uds;
wire        eth_dma_lds;
integer     timeout_cycles;

ethernet_interface dut (
    .clk(clk),
    .reset(reset),
    .cpu_addr(cpu_addr),
    .cpu_data_in(cpu_data_in),
    .cpu_data_out(cpu_data_out),
    .cpu_rd(cpu_rd),
    .cpu_hwr(cpu_hwr),
    .cpu_lwr(cpu_lwr),
    .cpu_as(cpu_as),
    .cpu_uds(cpu_uds),
    .cpu_lds(cpu_lds),
    .sel_ethernet_shm(sel_ethernet_shm),
    .sel_ethernet(sel_ethernet),
    .eth_dma_ready(eth_dma_ready),
    .eth_dma_rdata(eth_dma_rdata),
    .eth_dma_req(eth_dma_req),
    .eth_dma_write(eth_dma_write),
    .eth_dma_addr(eth_dma_addr),
    .eth_dma_wdata(eth_dma_wdata),
    .eth_dma_uds(eth_dma_uds),
    .eth_dma_lds(eth_dma_lds),
    .eth_irq(eth_irq),
    .dtack_eth(dtack_eth)
);

always #5 clk = ~clk;

task automatic write_high_reg;
    input [14:0] word_offset;
    input [7:0] value;
    begin
        @(negedge clk);
        cpu_addr = word_offset;
        cpu_data_in = {value, 8'h00};
        sel_ethernet = 1'b1;
        cpu_hwr = 1'b1;
        cpu_lwr = 1'b0;
        cpu_as = 1'b0;
        cpu_uds = 1'b0;
        cpu_lds = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cpu_hwr = 1'b0;
        cpu_lwr = 1'b0;
        cpu_as = 1'b1;
        cpu_uds = 1'b1;
        cpu_lds = 1'b1;
        sel_ethernet = 1'b0;
        cpu_data_in = 16'h0000;
    end
endtask

task automatic write_low_reg;
    input [14:0] word_offset;
    input [7:0] value;
    begin
        @(negedge clk);
        cpu_addr = word_offset;
        cpu_data_in = {8'h00, value};
        sel_ethernet = 1'b1;
        cpu_hwr = 1'b0;
        cpu_lwr = 1'b1;
        cpu_as = 1'b0;
        cpu_uds = 1'b1;
        cpu_lds = 1'b0;
        @(posedge clk);
        @(negedge clk);
        cpu_hwr = 1'b0;
        cpu_lwr = 1'b0;
        cpu_as = 1'b1;
        cpu_uds = 1'b1;
        cpu_lds = 1'b1;
        sel_ethernet = 1'b0;
        cpu_data_in = 16'h0000;
    end
endtask

task automatic complete_dma;
    input [15:0] read_data;
    begin
        @(negedge clk);
        eth_dma_rdata = read_data;
        eth_dma_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        eth_dma_ready = 1'b0;
        eth_dma_rdata = 16'h0000;
    end
endtask

task automatic expect_dma_request;
    input        expected_write;
    input [14:0] expected_addr;
    input [15:0] expected_wdata;
    input        check_wdata;
    input [255:0] label;
    integer timeout;
    begin
        timeout = 0;
        while (!eth_dma_req && (timeout < 256)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!eth_dma_req) begin
            $display("FAIL: %0s timed out waiting for DMA request", label);
            $fatal(1);
        end
        #1;
        if (eth_dma_write !== expected_write) begin
            $display("FAIL: %0s expected write=%0d got %0d", label, expected_write, eth_dma_write);
            $fatal(1);
        end
        if (eth_dma_addr !== expected_addr) begin
            $display("FAIL: %0s expected addr=0x%04x got 0x%04x", label, expected_addr, eth_dma_addr);
            $fatal(1);
        end
        if (check_wdata && (eth_dma_wdata !== expected_wdata)) begin
            $display("FAIL: %0s expected wdata=0x%04x got 0x%04x", label, expected_wdata, eth_dma_wdata);
            $fatal(1);
        end
    end
endtask

task automatic expect_dma_request_filtered;
    input        expected_write;
    input [14:0] expected_addr;
    input [15:0] expected_wdata;
    input        check_wdata;
    input [255:0] label;
    integer timeout;
    reg matched;
    begin
        timeout = 0;
        matched = 1'b0;
        while (!matched && (timeout < 512)) begin
            while (!eth_dma_req && (timeout < 512)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!eth_dma_req) begin
                $display("FAIL: %0s timed out waiting for DMA request", label);
                $fatal(1);
            end
            #1;
            if ((eth_dma_write === expected_write) &&
                (eth_dma_addr === expected_addr) &&
                (!check_wdata || (eth_dma_wdata === expected_wdata))) begin
                matched = 1'b1;
            end else begin
                complete_dma(16'h0000);
            end
        end
        if (!matched) begin
            $display("FAIL: %0s did not observe expected DMA request", label);
            $fatal(1);
        end
    end
endtask

task automatic read_reg_expect;
    input [14:0] word_offset;
    input [15:0] expected;
    input [255:0] label;
    begin
        @(negedge clk);
        cpu_addr = word_offset;
        sel_ethernet = 1'b1;
        cpu_rd = 1'b1;
        cpu_as = 1'b0;
        cpu_uds = 1'b0;
        cpu_lds = 1'b0;
        @(posedge clk);
        #1;
        if (cpu_data_out !== expected) begin
            $display("FAIL: %0s expected 0x%04x got 0x%04x", label, expected, cpu_data_out);
            $fatal(1);
        end
        @(negedge clk);
        cpu_rd = 1'b0;
        cpu_as = 1'b1;
        cpu_uds = 1'b1;
        cpu_lds = 1'b1;
        sel_ethernet = 1'b0;
    end
endtask

task automatic read_reg_expect_low;
    input [14:0] word_offset;
    input [15:0] expected;
    input [255:0] label;
    begin
        @(negedge clk);
        cpu_addr = word_offset;
        sel_ethernet = 1'b1;
        cpu_rd = 1'b1;
        cpu_as = 1'b0;
        cpu_uds = 1'b1;
        cpu_lds = 1'b0;
        @(posedge clk);
        #1;
        if (cpu_data_out !== expected) begin
            $display("FAIL: %0s expected 0x%04x got 0x%04x", label, expected, cpu_data_out);
            $fatal(1);
        end
        @(negedge clk);
        cpu_rd = 1'b0;
        cpu_as = 1'b1;
        cpu_lds = 1'b1;
        sel_ethernet = 1'b0;
    end
endtask

task automatic read_data_port_expect;
    input [14:0] word_offset;
    input [15:0] expected;
    input [255:0] label;
    begin
        @(negedge clk);
        cpu_addr = word_offset;
        sel_ethernet = 1'b1;
        cpu_rd = 1'b1;
        cpu_as = 1'b0;
        cpu_uds = 1'b0;
        cpu_lds = 1'b0;
        @(posedge clk);
        #1;
        if (cpu_data_out !== expected) begin
            $display("FAIL: %0s expected 0x%04x got 0x%04x", label, expected, cpu_data_out);
            $fatal(1);
        end
        @(negedge clk);
        cpu_rd = 1'b0;
        cpu_as = 1'b1;
        cpu_uds = 1'b1;
        cpu_lds = 1'b1;
        sel_ethernet = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    cpu_addr = 15'h0;
    cpu_data_in = 16'h0000;
    cpu_rd = 1'b0;
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet_shm = 1'b0;
    sel_ethernet = 1'b0;
    eth_dma_ready = 1'b0;
    eth_dma_rdata = 16'h0000;

    repeat (2) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    read_reg_expect(15'h0600, 16'h2121, "reset CR");
    read_reg_expect(15'h0602, 16'h0000, "page0 CLDA0 reset");
    read_reg_expect(15'h0604, 16'h0000, "page0 CLDA1 reset");
    read_reg_expect(15'h060a, 16'h0000, "page0 NCR reset");
    read_reg_expect(15'h060c, 16'h0000, "page0 FIFO reset");
    read_reg_expect(15'h061a, 16'h0000, "page0 CNTR0 reset");
    read_reg_expect(15'h061c, 16'h0000, "page0 CNTR1 reset");
    read_reg_expect(15'h061e, 16'h0000, "page0 CNTR2 reset");
    read_reg_expect_low(15'h0614, 16'h0050, "ID0 is visible on lower byte lane");
    read_reg_expect_low(15'h0616, 16'h0070, "ID1 is visible on lower byte lane");

    write_high_reg(15'h0618, 8'h20);
    if (dut.rx_poll_enabled !== 1'b1) begin
        $display("FAIL: RCR write should arm rx_poll_enabled even while stopped");
        $fatal(1);
    end
    if (dut.shm_sync_enabled !== 1'b0) begin
        $display("FAIL: RCR write while stopped should not start shared-memory sync");
        $fatal(1);
    end
    dut.rx_poll_enabled = 1'b0;
    dut.shm_sync_enabled = 1'b0;
    dut.bg_state = 5'd0;
    dut.bg_dma_inflight = 1'b0;
    dut.eth_dma_req = 1'b0;

    write_high_reg(15'h0600, 8'h22);
    write_high_reg(15'h0618, 8'h20);
    if (dut.shm_sync_enabled !== 1'b0) begin
        $display("FAIL: RCR write while started should not start shared-memory sync");
        $fatal(1);
    end
    if (dut.bg_poll_counter !== 8'h00) begin
        $display("FAIL: RCR write should not perturb bg_poll_counter, got 0x%02x", dut.bg_poll_counter);
        $fatal(1);
    end
    write_high_reg(15'h0600, 8'h21);
    dut.rx_poll_enabled = 1'b0;

    write_high_reg(15'h0600, 8'h02);
    write_high_reg(15'h061c, 8'h01);
    write_high_reg(15'h063e, 8'hA5);
    if (dut.cr_register !== 8'h02) begin
        $display("FAIL: reset port write should not reset CR, got 0x%02x", dut.cr_register);
        $fatal(1);
    end
    if (dut.dcr_register !== 8'h81) begin
        $display("FAIL: reset port write should not reset DCR, got 0x%02x", dut.dcr_register);
        $fatal(1);
    end
    read_reg_expect(15'h063e, 16'hA5A5, "reset port returns latched write value");
    if (dut.cr_register !== 8'h21) begin
        $display("FAIL: reset port should restore CR to 0x21, got 0x%02x", dut.cr_register);
        $fatal(1);
    end
    if (dut.dcr_register !== 8'h80) begin
        $display("FAIL: reset port should clear DCR, got 0x%02x", dut.dcr_register);
        $fatal(1);
    end
    if (dut.isr_register !== 8'h80) begin
        $display("FAIL: reset port should set ISR.RST, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    write_high_reg(15'h060e, 8'h80);
    if (dut.isr_register !== 8'h00) begin
        $display("FAIL: ISR clear should clear reset status, got 0x%02x", dut.isr_register);
        $fatal(1);
    end

    // Match the xsurftest 16-bit RAM probe sequence:
    // write reset port, read reset port, mirror the read value back, then
    // program RCR/DCR/PSTART/PSTOP, arm remote DMA write, stream 16 words
    // through the aliased data port, and poll for ISR.RDC.
    write_high_reg(15'h063e, 8'h00);
    if (dut.cr_register !== 8'h21) begin
        $display("FAIL: xsurftest reset-port write should not reset CR, got 0x%02x", dut.cr_register);
        $fatal(1);
    end
    read_reg_expect(15'h063e, 16'h0000, "xsurftest reset-port read");
    write_high_reg(15'h063e, 8'h00);
    write_high_reg(15'h0600, 8'h21);
    write_high_reg(15'h0618, 8'h20);
    write_high_reg(15'h061c, 8'h49);
    write_high_reg(15'h0602, 8'h40);
    write_high_reg(15'h0604, 8'h80);
    write_high_reg(15'h0600, 8'h22);
    write_high_reg(15'h060e, 8'h40);
    write_high_reg(15'h0614, 8'h20);
    write_high_reg(15'h0616, 8'h00);
    write_high_reg(15'h0610, 8'h00);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0600, 8'h12);
    dut.shm_sync_enabled = 1'b1;
    dut.bg_sync_slot = 6'd0;

    for (timeout_cycles = 0; timeout_cycles < 16; timeout_cycles = timeout_cycles + 1) begin
        @(negedge clk);
        cpu_addr = 15'h0620;
        cpu_data_in = 16'h4100 + timeout_cycles;
        sel_ethernet = 1'b1;
        cpu_hwr = 1'b1;
        cpu_lwr = 1'b1;
        cpu_as = 1'b0;
        cpu_uds = 1'b0;
        cpu_lds = 1'b0;
        @(posedge clk);
        #1;
        if (!eth_dma_req || !eth_dma_write) begin
            $display("FAIL: xsurftest data port write %0d should issue DMA write request", timeout_cycles);
            $fatal(1);
        end
        if (eth_dma_addr !== (15'h1800 + timeout_cycles[14:0])) begin
            $display("FAIL: xsurftest data port write %0d expected DMA addr 0x%04x got 0x%04x",
                     timeout_cycles, (15'h1800 + timeout_cycles[14:0]), eth_dma_addr);
            $fatal(1);
        end
        if (eth_dma_wdata !== (16'h4100 + timeout_cycles[15:0])) begin
            $display("FAIL: xsurftest data port write %0d expected DMA data 0x%04x got 0x%04x",
                     timeout_cycles, (16'h4100 + timeout_cycles[15:0]), eth_dma_wdata);
            $fatal(1);
        end
        complete_dma(16'h0000);
        @(negedge clk);
        cpu_hwr = 1'b0;
        cpu_lwr = 1'b0;
        cpu_as = 1'b1;
        cpu_uds = 1'b1;
        cpu_lds = 1'b1;
        sel_ethernet = 1'b0;
        cpu_data_in = 16'h0000;
        @(posedge clk);
    end

    if (dut.remote_dma_addr !== 16'h4020) begin
        $display("FAIL: xsurftest sequence should advance remote_dma_addr to 0x4020, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    if (dut.remote_byte_count !== 16'h0000) begin
        $display("FAIL: xsurftest sequence should drain remote_byte_count to 0, got 0x%04x", dut.remote_byte_count);
        $fatal(1);
    end
    if ((dut.isr_register & 8'h40) == 8'h00) begin
        $display("FAIL: xsurftest sequence should set ISR.RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    write_high_reg(15'h060e, 8'h40);
    dut.shm_sync_enabled = 1'b0;
    dut.bg_state = 5'd0;
    dut.bg_dma_inflight = 1'b0;
    dut.eth_dma_req = 1'b0;

    // A completed data-port write must hold its completion until the current
    // bus cycle releases, but it must not relaunch the same word while the
    // old write strobe is still asserted.
    write_high_reg(15'h0610, 8'h20);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h04);
    write_high_reg(15'h0616, 8'h00);
    write_high_reg(15'h0600, 8'h12);

    @(negedge clk);
    cpu_addr = 15'h0620;
    cpu_data_in = 16'h1122;
    sel_ethernet = 1'b1;
    cpu_hwr = 1'b1;
    cpu_lwr = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (!eth_dma_req || !eth_dma_write || eth_dma_addr !== 15'h1810) begin
        $display("FAIL: first back-to-back write should issue DMA request at 0x1810");
        $fatal(1);
    end
    complete_dma(16'h0000);
    @(posedge clk);
    #1;
    if (dtack_eth !== 1'b0) begin
        $display("FAIL: completed write should keep dtack asserted until the bus cycle ends");
        $fatal(1);
    end
    if (eth_dma_req !== 1'b0) begin
        $display("FAIL: completed write must not relaunch DMA before bus release");
        $fatal(1);
    end

    @(negedge clk);
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    @(posedge clk);
    @(negedge clk);
    cpu_addr = 15'h0620;
    cpu_data_in = 16'h3344;
    sel_ethernet = 1'b1;
    cpu_hwr = 1'b1;
    cpu_lwr = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (dtack_eth !== 1'b1) begin
        $display("FAIL: second write must wait for its own DMA completion");
        $fatal(1);
    end
    if (!eth_dma_req || !eth_dma_write || eth_dma_addr !== 15'h1811) begin
        $display("FAIL: second write should issue DMA request at 0x1811");
        $fatal(1);
    end
    complete_dma(16'h0000);
    @(negedge clk);
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    @(posedge clk);
    if (dut.remote_dma_addr !== 16'h4024) begin
        $display("FAIL: consecutive writes should advance remote_dma_addr to 0x4024, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    if (dut.remote_byte_count !== 16'h0000) begin
        $display("FAIL: consecutive writes should drain remote_byte_count to 0, got 0x%04x", dut.remote_byte_count);
        $fatal(1);
    end
    if ((dut.isr_register & 8'h40) == 8'h00) begin
        $display("FAIL: consecutive writes should set ISR.RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    write_high_reg(15'h060e, 8'h40);

    write_high_reg(15'h0600, 8'h40);
    read_reg_expect(15'h0600, 16'h4040, "CR write preserves stop/start bits");

    write_high_reg(15'h0600, 8'h02);
    read_reg_expect(15'h0600, 16'h0202, "CR returns to page 0");

    write_high_reg(15'h0610, 8'h34);
    write_high_reg(15'h0612, 8'h12);
    if (dut.remote_dma_addr !== 16'h1234) begin
        $display("FAIL: remote_dma_addr expected 0x1234 got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    read_reg_expect(15'h0610, 16'h3434, "CRDA0 reflects RSAR0");
    read_reg_expect(15'h0612, 16'h1212, "CRDA1 reflects RSAR1");

    write_low_reg(15'h0610, 8'h78);
    write_low_reg(15'h0612, 8'h56);
    if (dut.remote_dma_addr !== 16'h5678) begin
        $display("FAIL: lower-byte lane writes should update remote_dma_addr to 0x5678, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    read_reg_expect_low(15'h0610, 16'h0078, "CRDA0 is readable on lower byte lane");
    read_reg_expect_low(15'h0612, 16'h0056, "CRDA1 is readable on lower byte lane");

    write_high_reg(15'h0614, 8'h78);
    write_high_reg(15'h0616, 8'h56);
    if (dut.remote_byte_count !== 16'h5678) begin
        $display("FAIL: remote_byte_count expected 0x5678 got 0x%04x", dut.remote_byte_count);
        $fatal(1);
    end

    write_high_reg(15'h061c, 8'h01);
    if (dut.dcr_word_mode !== 1'b1) begin
        $display("FAIL: dcr_word_mode expected 1 got %0d", dut.dcr_word_mode);
        $fatal(1);
    end

    write_high_reg(15'h0610, 8'h00);
    write_high_reg(15'h0612, 8'h00);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);
    read_data_port_expect(15'h0620, 16'h5252, "station PROM word 0");
    if (eth_dma_req !== 1'b0) begin
        $display("FAIL: station PROM reads should not issue external DMA");
        $fatal(1);
    end
    if (dut.remote_dma_addr !== 16'h0002) begin
        $display("FAIL: station PROM read should advance remote_dma_addr to 0x0002, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    if ((dut.isr_register & 8'h40) == 8'h00) begin
        $display("FAIL: station PROM read should set RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    write_high_reg(15'h060e, 8'h40);

    write_high_reg(15'h0610, 8'h00);
    write_high_reg(15'h0612, 8'h00);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);

    @(negedge clk);
    cpu_addr = 15'h0620;
    cpu_data_in = 16'hA55A;
    sel_ethernet = 1'b1;
    cpu_hwr = 1'b1;
    cpu_lwr = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (eth_dma_req !== 1'b0) begin
        $display("FAIL: station PROM shadow write should not issue external DMA");
        $fatal(1);
    end
    @(negedge clk);
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    @(posedge clk);
    if (dut.remote_dma_addr !== 16'h0002) begin
        $display("FAIL: station PROM shadow write should advance remote_dma_addr to 0x0002, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    if ((dut.isr_register & 8'h40) == 8'h00) begin
        $display("FAIL: station PROM shadow write should set RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    write_high_reg(15'h060e, 8'h40);

    write_high_reg(15'h0610, 8'h00);
    write_high_reg(15'h0612, 8'h00);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);
    read_data_port_expect(15'h0620, 16'hA55A, "station PROM shadow write is readable");
    write_high_reg(15'h060e, 8'h40);

    write_high_reg(15'h0610, 8'h10);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);

    @(negedge clk);
    cpu_addr = 15'h0620;
    cpu_data_in = 16'hBEEF;
    sel_ethernet = 1'b1;
    cpu_hwr = 1'b1;
    cpu_lwr = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (!eth_dma_req || !eth_dma_write) begin
        $display("FAIL: data port write should issue DMA write request");
        $fatal(1);
    end
    if (eth_dma_addr !== 15'h1808) begin
        $display("FAIL: data port write DMA address expected 0x1808 got 0x%04x", eth_dma_addr);
        $fatal(1);
    end
    if (eth_dma_wdata !== 16'hBEEF) begin
        $display("FAIL: data port write DMA data expected 0xBEEF got 0x%04x", eth_dma_wdata);
        $fatal(1);
    end
    if (dtack_eth !== 1'b1) begin
        $display("FAIL: dtack should stay inactive until DMA completes");
        $fatal(1);
    end
    complete_dma(16'h0000);
    @(negedge clk);
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    @(posedge clk);

    if (dut.remote_dma_addr !== 16'h4012) begin
        $display("FAIL: data port write should advance remote_dma_addr to 0x4012, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    if (dut.remote_byte_count !== 16'h0000) begin
        $display("FAIL: data port write should drain remote_byte_count to 0, got 0x%04x", dut.remote_byte_count);
        $fatal(1);
    end
    if ((dut.isr_register & 8'h40) == 8'h00) begin
        $display("FAIL: data port completion should set RDC in ISR, got 0x%02x", dut.isr_register);
        $fatal(1);
    end

    write_high_reg(15'h0610, 8'h14);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);

    @(negedge clk);
    cpu_addr = 15'h0621;
    cpu_data_in = 16'hA55A;
    sel_ethernet = 1'b1;
    cpu_hwr = 1'b1;
    cpu_lwr = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (!eth_dma_req || !eth_dma_write) begin
        $display("FAIL: data port alias write should issue DMA write request");
        $fatal(1);
    end
    if (eth_dma_addr !== 15'h180a) begin
        $display("FAIL: data port alias write DMA address expected 0x180a got 0x%04x", eth_dma_addr);
        $fatal(1);
    end
    if (eth_dma_wdata !== 16'hA55A) begin
        $display("FAIL: data port alias write DMA data expected 0xA55A got 0x%04x", eth_dma_wdata);
        $fatal(1);
    end
    complete_dma(16'h0000);
    @(negedge clk);
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    @(posedge clk);

    if (dut.remote_dma_addr !== 16'h4016) begin
        $display("FAIL: data port alias write should advance remote_dma_addr to 0x4016, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end

    write_high_reg(15'h061c, 8'h03);
    write_high_reg(15'h0610, 8'h18);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);

    @(negedge clk);
    cpu_addr = 15'h0620;
    cpu_data_in = 16'hCAFE;
    sel_ethernet = 1'b1;
    cpu_hwr = 1'b1;
    cpu_lwr = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (!eth_dma_req || !eth_dma_write) begin
        $display("FAIL: BOS data port write should issue DMA write request");
        $fatal(1);
    end
    if (eth_dma_wdata !== 16'hFECA) begin
        $display("FAIL: BOS data port write should swap bytes, got 0x%04x", eth_dma_wdata);
        $fatal(1);
    end
    complete_dma(16'h0000);
    @(negedge clk);
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    @(posedge clk);

    write_high_reg(15'h0610, 8'h18);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);

    @(negedge clk);
    cpu_addr = 15'h0620;
    sel_ethernet = 1'b1;
    cpu_rd = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (!eth_dma_req || eth_dma_write) begin
        $display("FAIL: BOS data port read should issue DMA read request");
        $fatal(1);
    end
    complete_dma(16'hFECA);
    @(posedge clk);
    #1;
    if (cpu_data_out !== 16'hCAFE) begin
        $display("FAIL: BOS data port read should swap bytes back, got 0x%04x", cpu_data_out);
        $fatal(1);
    end
    @(negedge clk);
    cpu_rd = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    write_high_reg(15'h060e, 8'h40);
    write_high_reg(15'h061c, 8'h01);

    write_high_reg(15'h0610, 8'h20);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);

    @(negedge clk);
    cpu_addr = 15'h0620;
    sel_ethernet = 1'b1;
    cpu_rd = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    @(posedge clk);
    #1;
    if (!eth_dma_req || eth_dma_write) begin
        $display("FAIL: data port read should issue DMA read request");
        $fatal(1);
    end
    if (eth_dma_addr !== 15'h1810) begin
        $display("FAIL: data port read DMA address expected 0x1810 got 0x%04x", eth_dma_addr);
        $fatal(1);
    end
    complete_dma(16'hCAFE);
    @(posedge clk);
    #1;
    if (cpu_data_out !== 16'hCAFE) begin
        $display("FAIL: data port read expected 0xCAFE got 0x%04x", cpu_data_out);
        $fatal(1);
    end
    @(negedge clk);
    cpu_rd = 1'b0;
    cpu_as = 1'b1;
    sel_ethernet = 1'b0;

    write_high_reg(15'h060e, 8'h40);
    if (dut.isr_register !== 8'h00) begin
        $display("FAIL: ISR clear should clear RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end

    write_high_reg(15'h0610, 8'h30);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);

    @(negedge clk);
    cpu_addr = 15'h0620;
    sel_ethernet = 1'b1;
    cpu_rd = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    timeout_cycles = 0;
    while ((dtack_eth !== 1'b0) && (timeout_cycles < 700)) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
    end
    #1;
    if (dtack_eth !== 1'b0) begin
        $display("FAIL: data port read without DMA ready should time out instead of hanging (cycles=%0d req=%0d wait_ctr=%0d rd_pend=%0d wr_pend=%0d done=%0d bg_inflight=%0d bg_state=%0d sticky=0x%04x)",
                 timeout_cycles, eth_dma_req, dut.eth_dma_wait_counter, dut.data_port_read_pending,
                 dut.data_port_write_pending, dut.data_port_transfer_done, dut.bg_dma_inflight,
                 dut.bg_state, dut.debug_sticky_flags);
        $fatal(1);
    end
    if (cpu_data_out !== 16'hFFFF) begin
        $display("FAIL: timed-out word read should return 0xFFFF, got 0x%04x", cpu_data_out);
        $fatal(1);
    end
    if (eth_dma_req !== 1'b0) begin
        $display("FAIL: timed-out data port read should clear eth_dma_req");
        $fatal(1);
    end
    if (dut.remote_dma_addr !== 16'h4032) begin
        $display("FAIL: timed-out read should advance remote_dma_addr to 0x4032, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    if (dut.remote_byte_count !== 16'h0000) begin
        $display("FAIL: timed-out read should drain remote_byte_count to 0, got 0x%04x", dut.remote_byte_count);
        $fatal(1);
    end
    if ((dut.isr_register & 8'h40) == 8'h00) begin
        $display("FAIL: timed-out read should still complete remote DMA and set RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    if (!dut.debug_sticky_flags[15]) begin
        $display("FAIL: timed-out read should latch the DMA-timeout sticky flag");
        $fatal(1);
    end
    @(negedge clk);
    cpu_rd = 1'b0;
    cpu_as = 1'b1;
    sel_ethernet = 1'b0;

    write_high_reg(15'h060e, 8'h40);
    if (dut.isr_register !== 8'h00) begin
        $display("FAIL: ISR clear should clear timed-out RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end

    write_high_reg(15'h0610, 8'h34);
    write_high_reg(15'h0612, 8'h40);
    write_high_reg(15'h0614, 8'h02);
    write_high_reg(15'h0616, 8'h00);
    write_high_reg(15'h0600, 8'h12);

    @(negedge clk);
    cpu_addr = 15'h0620;
    cpu_data_in = 16'hDEAD;
    sel_ethernet = 1'b1;
    cpu_hwr = 1'b1;
    cpu_lwr = 1'b1;
    cpu_as = 1'b0;
    cpu_uds = 1'b0;
    cpu_lds = 1'b0;
    @(posedge clk);
    #1;
    if (!eth_dma_req || !dut.data_port_write_pending) begin
        $display("FAIL: timed-out write setup should leave a pending DMA write");
        $fatal(1);
    end
    @(negedge clk);
    cpu_hwr = 1'b0;
    cpu_lwr = 1'b0;
    cpu_as = 1'b1;
    cpu_uds = 1'b1;
    cpu_lds = 1'b1;
    sel_ethernet = 1'b0;
    cpu_data_in = 16'h0000;
    timeout_cycles = 0;
    while ((eth_dma_req !== 1'b0) && (timeout_cycles < 700)) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
    end
    #1;
    if (eth_dma_req !== 1'b0) begin
        $display("FAIL: timed-out write should eventually clear eth_dma_req");
        $fatal(1);
    end
    if (dut.remote_dma_addr !== 16'h4036) begin
        $display("FAIL: timed-out write should advance remote_dma_addr to 0x4036, got 0x%04x", dut.remote_dma_addr);
        $fatal(1);
    end
    if (dut.remote_byte_count !== 16'h0000) begin
        $display("FAIL: timed-out write should drain remote_byte_count to 0, got 0x%04x", dut.remote_byte_count);
        $fatal(1);
    end
    if ((dut.isr_register & 8'h40) == 8'h00) begin
        $display("FAIL: timed-out write should still complete remote DMA and set RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    if (dut.data_port_write_pending !== 1'b0) begin
        $display("FAIL: timed-out write should clear the pending write state");
        $fatal(1);
    end
    if (!dut.debug_sticky_flags[15]) begin
        $display("FAIL: timed-out write should latch the DMA-timeout sticky flag");
        $fatal(1);
    end
    write_high_reg(15'h060e, 8'h40);
    if (dut.isr_register !== 8'h00) begin
        $display("FAIL: ISR clear should clear timed-out write RDC, got 0x%02x", dut.isr_register);
        $fatal(1);
    end

    write_high_reg(15'h0618, 8'h11);
    write_high_reg(15'h061a, 8'h22);
    write_high_reg(15'h061c, 8'h49);
    write_high_reg(15'h061e, 8'h33);

    write_high_reg(15'h0600, 8'h80);
    read_reg_expect(15'h0602, 16'h4040, "page2 PSTART readback");
    read_reg_expect(15'h0604, 16'h8080, "page2 PSTOP readback");
    read_reg_expect(15'h0618, 16'h1111, "page2 RCR readback");
    read_reg_expect(15'h061a, 16'h2222, "page2 TCR readback");
    read_reg_expect(15'h061c, 16'hC9C9, "page2 DCR readback");
    read_reg_expect(15'h061e, 16'h3333, "page2 IMR readback");

    write_high_reg(15'h0600, 8'hC0);
    read_reg_expect(15'h0602, 16'h0000, "page3 9346CR default");
    read_reg_expect(15'h0606, 16'h0000, "page3 CONFIG0 default");
    read_reg_expect(15'h0608, 16'h8080, "page3 CONFIG1 default");
    read_reg_expect(15'h060a, 16'h4040, "page3 CONFIG2 default");
    read_reg_expect(15'h060c, 16'h4040, "page3 CONFIG3 default");
    read_reg_expect(15'h061c, 16'h5050, "page3 ID0 readback");
    read_reg_expect(15'h061e, 16'h7070, "page3 ID1 readback");

    write_high_reg(15'h0606, 8'hFF);
    write_high_reg(15'h0608, 8'h00);
    write_high_reg(15'h060a, 8'hE0);
    write_high_reg(15'h060c, 8'h06);
    read_reg_expect(15'h0606, 16'h0000, "page3 CONFIG0 ignores writes while 9346CR is locked");
    read_reg_expect(15'h0608, 16'h8080, "page3 CONFIG1 ignores writes while 9346CR is locked");
    read_reg_expect(15'h060a, 16'h4040, "page3 CONFIG2 ignores writes while 9346CR is locked");
    read_reg_expect(15'h060c, 16'h4040, "page3 CONFIG3 ignores writes while 9346CR is locked");

    write_high_reg(15'h0602, 8'hC0);
    read_reg_expect(15'h0602, 16'hC0C0, "page3 9346CR enables config writes");
    write_high_reg(15'h0606, 8'hFF);
    write_high_reg(15'h0608, 8'h00);
    write_high_reg(15'h060a, 8'hE0);
    write_high_reg(15'h060c, 8'h06);
    read_reg_expect(15'h0606, 16'hC0C0, "page3 CONFIG0 only updates writable bits");
    read_reg_expect(15'h0608, 16'h0000, "page3 CONFIG1 updates IRQEN when unlocked");
    read_reg_expect(15'h060a, 16'hE0E0, "page3 CONFIG2 only updates writable bits");
    read_reg_expect(15'h060c, 16'h4646, "page3 CONFIG3 only updates writable bits");

    write_high_reg(15'h0600, 8'h02);
    dut.rx_poll_enabled = 1'b0;
    dut.shm_sync_enabled = 1'b0;
    dut.bg_state = 5'd0;
    dut.bg_dma_inflight = 1'b0;
    dut.bg_polling_rx_flags = 1'b0;
    dut.bg_clear_rx_avail = 1'b0;
    dut.eth_dma_req = 1'b0;

    write_high_reg(15'h0600, 8'h40);
    write_high_reg(15'h0602, 8'h12);
    write_high_reg(15'h0604, 8'h34);
    write_high_reg(15'h060e, 8'h4A);
    write_high_reg(15'h0610, 8'hAA);
    read_reg_expect(15'h0602, 16'h1212, "page1 PAR0 stores written value");
    read_reg_expect(15'h0604, 16'h3434, "page1 PAR1 stores written value");
    read_reg_expect(15'h060e, 16'h4A4A, "page1 CURR stores written value");
    read_reg_expect(15'h0610, 16'hAAAA, "page1 MAR0 stores written value");

    write_high_reg(15'h0600, 8'h02);
    write_high_reg(15'h0602, 8'h48);
    write_high_reg(15'h0604, 8'h4C);
    write_high_reg(15'h0606, 8'h48);
    write_high_reg(15'h0608, 8'h49);
    write_high_reg(15'h060a, 8'h20);
    write_high_reg(15'h060c, 8'h00);
    write_high_reg(15'h061e, 8'h02);

    write_high_reg(15'h0600, 8'h06);
    repeat (2) @(posedge clk);
    #1;
    if (dut.tsr_register !== 8'h01) begin
        $display("FAIL: TSR should report PTX after transmit, got 0x%02x", dut.tsr_register);
        $fatal(1);
    end
    if (dut.isr_register !== 8'h02) begin
        $display("FAIL: ISR should report PTX after transmit, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    if (eth_irq !== 1'b1) begin
        $display("FAIL: eth_irq should assert for enabled PTX");
        $fatal(1);
    end
    read_reg_expect(15'h0608, 16'h0101, "page0 TSR reports transmit success");
    read_reg_expect(15'h060e, 16'h0202, "page0 ISR reports PTX");
    read_reg_expect(15'h0600, 16'h0202, "CR clears TXP after completion");
    dut.bg_state = 5'd0;
    dut.bg_dma_inflight = 1'b0;
    dut.bg_polling_rx_flags = 1'b0;
    dut.bg_clear_rx_avail = 1'b0;
    dut.eth_dma_req = 1'b0;
    dut.mirrored_fpga_flags = 16'h0000;

    expect_dma_request_filtered(1'b0, 15'h0800, 16'h0000, 1'b0, "TX handshake reads CTRL_FLAGS before publish");
    complete_dma(16'h0000);
    expect_dma_request_filtered(1'b1, 15'h0800, 16'h2A00, 1'b1, "TX handshake publishes TX_REQ|IRQ|ENABLED");
    complete_dma(16'h0000);
    expect_dma_request_filtered(1'b0, 15'h0800, 16'h0000, 1'b0, "TX handshake polls for HPS acknowledgement");
    complete_dma(16'h2800);
    repeat (2) @(posedge clk);
    #1;
    if (dut.tx_request_pending !== 1'b0) begin
        $display("FAIL: TX handshake should clear tx_request_pending after HPS ack");
        $fatal(1);
    end

    write_high_reg(15'h060e, 8'h02);
    @(posedge clk);
    #1;
    if (dut.isr_register !== 8'h00) begin
        $display("FAIL: ISR clear should clear PTX, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    if (eth_irq !== 1'b0) begin
        $display("FAIL: eth_irq should deassert after clearing PTX");
        $fatal(1);
    end

    write_high_reg(15'h0600, 8'h40);
    write_high_reg(15'h060e, 8'h49);
    write_high_reg(15'h0600, 8'h02);
    write_high_reg(15'h0618, 8'h01);
    write_high_reg(15'h061a, 8'h02);
    write_high_reg(15'h061e, 8'h03);

    write_high_reg(15'h0600, 8'h06);
    repeat (2) @(posedge clk);
    #1;
    if (dut.isr_register !== 8'h03) begin
        $display("FAIL: loopback transmit should set PTX|PRX, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    if (dut.rsr_register !== 8'h01) begin
        $display("FAIL: loopback receive should set RSR PRX, got 0x%02x", dut.rsr_register);
        $fatal(1);
    end
    if (dut.bnry_register !== 8'h49) begin
        $display("FAIL: loopback receive should move BNRY to previous CURR, got 0x%02x", dut.bnry_register);
        $fatal(1);
    end
    write_high_reg(15'h0600, 8'h40);
    read_reg_expect(15'h060e, 16'h4A4A, "loopback receive advances CURR");
    write_high_reg(15'h0600, 8'h02);
    read_reg_expect(15'h0618, 16'h0101, "page0 RSR reports loopback receive");

    write_high_reg(15'h060e, 8'h03);
    @(posedge clk);
    #1;
    if (dut.isr_register !== 8'h00) begin
        $display("FAIL: ISR clear should clear loopback PTX|PRX, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    dut.tx_request_pending = 1'b0;
    dut.mirrored_fpga_flags = 16'h0000;

    write_high_reg(15'h0602, 8'h40);
    write_high_reg(15'h0604, 8'h80);
    write_high_reg(15'h0606, 8'h40);
    write_high_reg(15'h0618, 8'h00);
    write_high_reg(15'h061a, 8'h00);
    write_high_reg(15'h061e, 8'h01);
    write_high_reg(15'h0600, 8'h40);
    write_high_reg(15'h060e, 8'h41);
    write_high_reg(15'h0600, 8'h02);
    dut.shm_sync_enabled = 1'b0;
    dut.mirrored_fpga_flags = dut.fpga_owned_flags;
    dut.bg_state = 5'd0;
    dut.bg_dma_inflight = 1'b0;
    dut.bg_polling_rx_flags = 1'b0;
    dut.bg_clear_rx_avail = 1'b0;
    dut.bg_poll_counter = 8'h00;
    dut.eth_dma_req = 1'b0;

    expect_dma_request_filtered(1'b0, 15'h0800, 16'h0000, 1'b0, "RX poll reads CTRL_FLAGS");
    complete_dma(16'h0400);

    expect_dma_request_filtered(1'b0, 15'h1601, 16'h0000, 1'b0, "RX poll reads packet length");
    complete_dma(16'h0200);

    expect_dma_request_filtered(1'b1, 15'h1880, 16'h0142, 1'b1, "RX injection writes NE2000 header word 0");
    complete_dma(16'h0000);

    expect_dma_request_filtered(1'b1, 15'h1881, 16'h0600, 1'b1, "RX injection writes NE2000 header word 1");
    complete_dma(16'h0000);

    expect_dma_request_filtered(1'b0, 15'h1300, 16'h0000, 1'b0, "RX injection reads RX buffer payload");
    complete_dma(16'hA1B2);

    expect_dma_request_filtered(1'b1, 15'h1882, 16'hA1B2, 1'b1, "RX injection writes payload into NE memory");
    complete_dma(16'h0000);

    expect_dma_request_filtered(1'b1, 15'h0800, 16'h2800, 1'b1, "RX injection clears RX_AVAIL");
    complete_dma(16'h0000);

    repeat (2) @(posedge clk);
    #1;
    if (dut.rsr_register !== 8'h01) begin
        $display("FAIL: HPS RX injection should set RSR PRX, got 0x%02x", dut.rsr_register);
        $fatal(1);
    end
    if (dut.isr_register !== 8'h01) begin
        $display("FAIL: HPS RX injection should set ISR PRX, got 0x%02x", dut.isr_register);
        $fatal(1);
    end
    if (dut.curr_register !== 8'h42) begin
        $display("FAIL: HPS RX injection should advance CURR to 0x42, got 0x%02x", dut.curr_register);
        $fatal(1);
    end
    if (eth_irq !== 1'b1) begin
        $display("FAIL: HPS RX injection should assert eth_irq for enabled PRX");
        $fatal(1);
    end
    read_reg_expect(15'h060e, 16'h0101, "page0 ISR reports HPS RX PRX");
    write_high_reg(15'h0600, 8'h40);
    read_reg_expect(15'h060e, 16'h4242, "page1 CURR reflects HPS RX advance");
    write_high_reg(15'h0600, 8'h02);
    read_reg_expect(15'h0618, 16'h0101, "page0 RSR reports HPS RX receive");

    dut.shm_sync_enabled = 1'b1;
    dut.mirrored_fpga_flags = dut.fpga_owned_flags;
    expect_dma_request_filtered(1'b1, 15'h0830, 16'h0042, 1'b1, "shared CURR mirror write");
    complete_dma(16'h0000);

    $display("PASS: ethernet_tb completed");
    $finish;
end

endmodule
