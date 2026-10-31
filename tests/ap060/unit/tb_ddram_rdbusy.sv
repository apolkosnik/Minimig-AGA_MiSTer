// ddram_ctrl: read data is taken whenever readdatavalid is high -- Avalon
// lets the slave return it while it holds waitrequest for a new command.
// A DMA read and a CPU cache-line read, each answered once with waitrequest
// low and once with it high, must complete with the right data.
`timescale 1ns/1ps
module tb_ddram_rdbusy;
reg clk = 0; always #5 clk = ~clk;
reg nrst = 0, busy = 0, valid = 0, dma_cs = 0, cpu_cs = 0;
reg [63:0] dout = 64'h123456789abcdef0;
reg [28:1] cpu_a = 28'h8000004;
wire rd, ack, rdy;
wire [15:0] dma_d, cpu_d;
wire [28:0] addr;
wire        coh;                   // (DMA reads only: the coherence answer looped back)
integer errors = 0;
ddram_ctrl dut (
	.sysclk(clk), .reset_n(nrst), .cache_rst(nrst), .cache_inhibit(1'b0),
	.cpu_cache_ctrl(4'b0001), .dcache_sw_en(1'b1),
	.DDRAM_CLK(), .DDRAM_BUSY(busy), .DDRAM_BURSTCNT(), .DDRAM_ADDR(addr), .DDRAM_DOUT(dout),
	.DDRAM_DOUT_READY(valid), .DDRAM_RD(rd), .DDRAM_DIN(), .DDRAM_BE(), .DDRAM_WE(),
	.mem2_address(29'd0), .mem2_burstcount(8'd1), .mem2_read(1'b0), .mem2_readdata(),
	.mem2_readdatavalid(), .mem2_writedata(64'd0), .mem2_byteenable(8'd0), .mem2_write(1'b0),
	.mem2_waitrequest(),
	.cpuAddr(cpu_a), .cpuCS(cpu_cs), .cpustate(2'd2), .cpuL(1'b0), .cpuU(1'b0), .cpuWR(16'd0),
	.cpuRD(cpu_d), .ramshared(1'b0), .ramready(rdy),
	.dmaAddr(28'h8000000), .dmaCS(dma_cs), .dmaWE(1'b0), .dmaL(1'b0), .dmaU(1'b0), .dmaWR(16'd0),
	.dmaRD(dma_d), .dmaACK(ack), .dma_coh_req(coh), .dma_coh_ack(coh),
	.fr_q_done(8'd0), .fr_q_pend(5'd0));
task chk(input c, input string what);
	if (!c) begin errors = errors + 1; $display("FAIL: %s (t=%0t)", what, $time); end
endtask
// answer the read the controller issues, with waitrequest w as the data comes
task answer(input w);
	begin
		wait (rd); @(posedge clk); #1;
		repeat (3) @(negedge clk);
		busy = w; valid = 1;
		@(negedge clk); valid = 0; busy = 0;
	end
endtask
integer w;
initial begin
	repeat (4) @(negedge clk); nrst = 1;
	for (w = 0; w < 2; w = w + 1) begin
		repeat (4) @(negedge clk);
		dma_cs = 1;
		answer(w);
		repeat (30) @(negedge clk);
		chk(ack && dma_d == 16'hdef0, $sformatf("DMA read with waitrequest %0d at its data", w));
		dma_cs = 0;
		repeat (10) @(negedge clk);
	end
	// a CPU read: a cache line fill (after the controller cache's tag sweep)
	wait (dut.cpu_cache.cache_init_done);
	dout = 64'h1111222256783333;
	for (w = 0; w < 2; w = w + 1) begin
		@(negedge clk); cpu_cs = 1;
		fork
			answer(w);
			begin : wr
				repeat (60) begin @(posedge clk); if (rdy) disable wr; end
			end
		join
		@(posedge clk); #1;
		chk(rdy && cpu_d == dout[16 * cpu_a[2:1] +: 16],
		    $sformatf("CPU read with waitrequest %0d at its data: %h", w, cpu_d));
		@(negedge clk); cpu_cs = 0;
		repeat (20) @(negedge clk);
		dout  = 64'h4444555566667777;    // a second line, at another address
		cpu_a = cpu_a + 28'h100;
	end
	if (errors == 0) $display("PASS tb_ddram_rdbusy"); else $display("FAIL tb_ddram_rdbusy: %0d", errors);
	$finish;
end
initial begin #400000; $display("FAIL tb_ddram_rdbusy: timeout"); $finish; end
endmodule
