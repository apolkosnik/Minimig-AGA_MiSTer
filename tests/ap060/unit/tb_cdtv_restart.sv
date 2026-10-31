// cdtv_bridge with chipdma_arb: a DMA stopped while chipdma_arb holds its
// request, then restarted at another address.  The arbiter acknowledges the
// request it took whatever the bridge does meanwhile; that acknowledge
// belongs to the stopped transfer.  The restarted one must wait for it and
// then write each of its bytes at its own address (the bug: the stale
// acknowledge advanced the new transfer, so its first destination byte was
// never written).  Then, after a reset, an uninterrupted transfer as a
// control.  chipdma_arb's DDR3 side answers after 200 clocks.
`timescale 1ns/1ps
module tb_cdtv_restart;
reg clk = 0; always #5 clk = ~clk;
reg reset = 1, sel = 0, rd = 0, hwr = 0, lwr = 0;
reg [23:1] addr = 0;
reg [15:0] din = 0;
reg uio_sec = 0, uio_wr = 0;
reg [15:0] uio_din = 0;
wire req, we, ack, arm;
wire [31:0] baddr;
wire  [7:0] wbyte;
integer errors = 0;

cdtv_bridge cdtv (
	.clk(clk), .reset(reset), .sel(sel), .selack(), .addr(addr), .din(din), .dout(), .rd(rd), .hwr(hwr), .lwr(lwr),
	.cdtv_irq(), .cdda_volume(), .cdda_volume_valid(), .uio_cs(1'b0), .uio_cs_sec(uio_sec), .uio_cs_stch(1'b0),
	.uio_cs_nvr(1'b0), .uio_cs_card(1'b0), .uio_wr(uio_wr), .uio_rd(1'b0), .uio_din(uio_din), .uio_dout(), .uio_req(),
	.nvr_addr(), .nvr_dout(8'd0), .nvr_load_din(), .nvr_load_we(), .nvr_clear_dirty(),
	.card_addr(), .card_dout(8'd0), .card_load_din(), .card_load_we(), .card_clear_dirty(),
	.subq_push(1'b0), .subq_byte(8'd0), .sten_pulse_ext(1'b0), .scor_pulse(1'b0), .sbcp_pulse(1'b0),
	.cdtv_dma_req(req), .cdtv_dma_we(we), .cdtv_dma_baddr(baddr), .cdtv_dma_wbyte(wbyte), .cdtv_dma_ack(ack),
	.cdtv_dma_arm(arm));

reg [1:0] phase = 0;
always @(posedge clk) phase <= phase + 2'd1;
wire        dcs, dwe, dl, du;
wire [28:1] da;
wire [15:0] dw;
reg         dack = 0;
chipdma_arb arb (
	.clk(clk), .reset(reset), .c_7m(phase == 2'd0),
	.chip_in_addr(24'd0), .chip_in_l(1'b1), .chip_in_u(1'b1), .chip_in_rw(1'b1), .chip_in_dma(1'b1), .chip_in_wr(16'd0),
	.akiko_dma_req(1'b0), .akiko_dma_we(1'b0), .akiko_dma_baddr(24'd0), .akiko_dma_wbyte(8'd0), .akiko_dma_rbyte(),
	.akiko_dma_ack(), .akiko_arm(),
	.cdtv_dma_req(req), .cdtv_dma_we(we), .cdtv_dma_baddr(baddr), .cdtv_dma_wbyte(wbyte), .cdtv_dma_rbyte(),
	.cdtv_dma_ack(ack), .cdtv_arm(arm),
	.chip_out_addr(), .chip_out_l(), .chip_out_u(), .chip_out_rw(), .chip_out_dma(), .chip_out_wr(), .chip_in_rd(16'd0),
	.z2ram_ena(1'b1), .z3ram_base0(5'd0), .z3ram_ena0(1'b0), .z3ram_base1(4'd0), .z3ram_ena1(1'b0),
	.ddr_out_addr(da), .ddr_out_l(dl), .ddr_out_u(du), .ddr_out_we(dwe), .ddr_out_cs(dcs), .ddr_out_wr(dw),
	.ddr_in_ack(dack), .ddr_in_rd(16'd0));

// the Zorro II RAM: the bytes at $200000 (old) and $201000 (new)
reg [7:0] oldbuf [0:1], newbuf [0:1];
integer   delay = 0, commits = 0, stray = 0;
always @(posedge clk) begin
	if (!dcs) begin
		dack <= 0; delay <= 0;
	end else if (!dack) begin
		delay <= delay + 1;
		if (delay == 200) begin
			dack <= 1; commits <= commits + 1;
			$display("commit %h upper=%b lower=%b data=%h", {da, 1'b0}, !du, !dl, dw);
			if (da[22:1] == 22'h100000) begin
				if (!du) oldbuf[0] <= dw[15:8];
				if (!dl) oldbuf[1] <= dw[7:0];
			end else if (da[22:1] == 22'h100800) begin
				if (!du) newbuf[0] <= dw[15:8];
				if (!dl) newbuf[1] <= dw[7:0];
			end else
				stray <= stray + 1;
		end
	end
end

task chk(input c, input string what);
	if (!c) begin errors = errors + 1; $display("FAIL: %s (t=%0t)", what, $time); end
endtask
task wr(input [15:0] off, input [15:0] data);
	@(negedge clk); sel = 1; addr = {8'd0, off[15:1]}; din = data; hwr = 1; lwr = 1;
	@(negedge clk); sel = 0; hwr = 0; lwr = 0;
endtask
task push(input [15:0] data);           // a byte into the sector FIFO
	@(negedge clk); uio_sec = 1; uio_wr = 1; uio_din = data;
	@(negedge clk); uio_wr = 0;
	repeat (3) @(negedge clk); uio_sec = 0;
endtask
task start(input [15:0] acr_lo);        // ACR = $20xxxx, WTC = 1 word, DMA start
	wr('h84, 'h20); wr('h86, acr_lo); wr('h80, 0); wr('h82, 1); wr('he0, 0);
endtask
task clear;
	oldbuf[0] = 8'hee; oldbuf[1] = 8'hee; newbuf[0] = 8'hee; newbuf[1] = 8'hee;
	commits = 0; stray = 0;
endtask

initial begin
	clear;
	repeat (5) @(negedge clk); reset = 0;
	push(16'h00aa); push(16'h00bb); push(16'h00cc); push(16'h00dd);
	// a transfer to $200000, stopped while the arbiter holds its first byte,
	// restarted at $201000
	start(16'h0000);
	wait (dcs);
	wr('he2, 0);
	start(16'h1000);
	wait (cdtv.wtc == 0);
	repeat (8) @(negedge clk);
	$display("restart: old=%h%h new=%h%h commits=%0d", oldbuf[0], oldbuf[1], newbuf[0], newbuf[1], commits);
	chk(oldbuf[0] == 8'haa && oldbuf[1] == 8'hee, "the stopped transfer: only its byte taken by the arbiter");
	chk(newbuf[0] != 8'hee, "the restarted transfer wrote its first byte");
	chk(newbuf[1] != 8'hee, "the restarted transfer wrote its second byte");
	// the byte the stopped transfer had not counted is still the FIFO's head
	chk(newbuf[0] == 8'haa && newbuf[1] == 8'hbb, "the restarted transfer: the FIFO's bytes in order");
	chk(commits == 3 && stray == 0, "three DDR3 writes, at the two buffers only");

	// control: after a reset, one transfer uninterrupted
	@(negedge clk); reset = 1; clear;
	repeat (5) @(negedge clk); reset = 0;
	push(16'h0011); push(16'h0022);
	start(16'h0000);
	wait (cdtv.wtc == 0);
	repeat (8) @(negedge clk);
	$display("control: old=%h%h new=%h%h commits=%0d", oldbuf[0], oldbuf[1], newbuf[0], newbuf[1], commits);
	chk(oldbuf[0] == 8'h11 && oldbuf[1] == 8'h22, "uninterrupted transfer");
	chk(newbuf[0] == 8'hee && newbuf[1] == 8'hee && commits == 2 && stray == 0, "uninterrupted: nothing else written");

	if (errors == 0) $display("PASS tb_cdtv_restart"); else $display("FAIL tb_cdtv_restart: %0d", errors);
	$finish;
end
initial begin #200000; $display("FAIL tb_cdtv_restart: timeout"); $finish; end
endmodule
