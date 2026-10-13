// a2065_ddram_arbiter: a command the slave stalls stays presented until the
// slave accepts it (Avalon: address, burst count, read/write and write data
// hold while waitrequest is asserted), even when the priority master (m0)
// asks meanwhile; m0's command follows once it is taken.  Also: an idle
// master sees the slave's waitrequest, and read data goes to its owner.
`timescale 1ns/1ps
module tb_arb_stall;
reg clk = 0; always #5 clk = ~clk;
reg rst = 1, m0_read = 0, m1_read = 0, m1_write = 0, stall = 1;
reg rvalid = 0;
wire [28:0] s_address;
wire  [7:0] s_burstcount;
wire        s_read, s_write, m0_wait, m1_wait, m0_rv, m1_rv;
integer errors = 0;
a2065_ddram_arbiter dut (
	.clk(clk), .rst(rst),
	.m0_address(29'h111), .m0_burstcount(8'd2), .m0_read(m0_read), .m0_readdata(), .m0_readdatavalid(m0_rv),
	.m0_writedata(64'd0), .m0_byteenable(8'hff), .m0_write(1'b0), .m0_waitrequest(m0_wait),
	.m1_address(29'h222), .m1_burstcount(8'd1), .m1_read(m1_read), .m1_readdata(), .m1_readdatavalid(m1_rv),
	.m1_writedata(64'h5555), .m1_byteenable(8'h0f), .m1_write(m1_write), .m1_waitrequest(m1_wait),
	.s_address(s_address), .s_burstcount(s_burstcount), .s_read(s_read), .s_readdata(64'd0),
	.s_readdatavalid(rvalid), .s_writedata(), .s_byteenable(), .s_write(s_write), .s_waitrequest(stall));
task chk(input c, input string what);
	if (!c) begin errors = errors + 1; $display("FAIL: %s (t=%0t)", what, $time); end
endtask
initial begin
	repeat (2) @(negedge clk); rst = 0;
	// m1 presents a read; the slave stalls it
	m1_read = 1;
	@(posedge clk); #1;
	chk(s_read && s_address == 29'h222 && s_burstcount == 8'd1, "m1's read presented");
	chk(m1_wait, "m1 waits while the slave stalls");
	// m0 asks while m1's command is stalled: m1's command stays
	@(negedge clk); m0_read = 1;
	repeat (3) begin
		@(posedge clk); #1;
		chk(s_read && s_address == 29'h222 && s_burstcount == 8'd1, "m1's stalled read stays presented when m0 asks");
		chk(m0_wait, "m0 waits for m1's stalled command");
	end
	// the slave takes it: m1 sees its acceptance, then its data
	@(negedge clk); stall = 0;
	#1 chk(!m1_wait, "m1's read accepted");
	@(posedge clk); @(negedge clk); m1_read = 0;
	#1 chk(m0_wait, "m0 waits for m1's read data");
	rvalid = 1; #1 chk(m1_rv && !m0_rv, "read data goes to m1");
	@(posedge clk); @(negedge clk); rvalid = 0;
	// now m0's command
	#1 chk(s_read && s_address == 29'h111 && s_burstcount == 8'd2 && !m0_wait, "m0's read follows");
	@(posedge clk); @(negedge clk); m0_read = 0;
	// its two beats of data
	rvalid = 1; #1 chk(m0_rv && !m1_rv, "read data goes to m0");
	@(posedge clk); @(posedge clk); @(negedge clk); rvalid = 0;
	// a stalled write holds its data too
	stall = 1; m1_write = 1;
	@(posedge clk); @(negedge clk); m0_read = 1;
	@(posedge clk); #1 chk(s_write && !s_read && s_address == 29'h222, "m1's stalled write stays presented");
	@(negedge clk); stall = 0; @(posedge clk); @(negedge clk); m1_write = 0;
	#1 chk(s_read && s_address == 29'h111, "m0 after the write");
	if (errors == 0) $display("PASS tb_arb_stall"); else $display("FAIL tb_arb_stall: %0d", errors);
	$finish;
end
initial begin #5000; $display("FAIL tb_arb_stall: timeout"); $finish; end
endmodule
