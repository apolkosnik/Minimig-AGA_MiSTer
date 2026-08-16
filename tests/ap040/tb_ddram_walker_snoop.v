//--------------------------------------------------------------------------//
// DDR walker-write/cache-snoop regression                                  //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_ddram_walker_snoop;
	reg clk = 0;
	always #5 clk = ~clk;

	reg reset_n = 0;
	reg walker_req = 0;
	reg walker_we = 0;
	reg [28:2] walker_addr = 0;
	reg [31:0] walker_wdata = 0;
	wire walker_ack;
	wire [31:0] walker_rdata;
	wire ddram_clk;
	wire [7:0] ddram_burstcnt;
	wire [28:0] ddram_addr;
	wire ddram_rd, ddram_we;
	wire [63:0] ddram_din;
	wire [7:0] ddram_be;
	integer errors = 0;
	integer timeout;

	ddram_ctrl dut (
		.sysclk(clk), .reset_n(reset_n), .cache_rst(1'b1),
		.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0011),
		.DDRAM_CLK(ddram_clk), .DDRAM_BUSY(1'b0),
		.DDRAM_BURSTCNT(ddram_burstcnt), .DDRAM_ADDR(ddram_addr),
		.DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD(ddram_rd), .DDRAM_DIN(ddram_din),
		.DDRAM_BE(ddram_be), .DDRAM_WE(ddram_we),
		.mem2_address(29'd0), .mem2_burstcount(8'd0),
		.mem2_read(1'b0), .mem2_readdata(), .mem2_readdatavalid(),
		.mem2_writedata(64'd0), .mem2_byteenable(8'd0),
		.mem2_write(1'b0), .mem2_waitrequest(),
		.cpuAddr(28'd0), .cpuCS(1'b0), .cpustate(2'b00),
		.cpuL(1'b1), .cpuU(1'b1), .cpuWR(16'd0), .cpuRD(),
		.ramshared(1'b0), .ramready(),
		.walker_req(walker_req), .walker_we(walker_we),
		.walker_addr(walker_addr), .walker_wdata(walker_wdata),
		.walker_ack(walker_ack), .walker_rdata(walker_rdata)
	);

	initial begin
		repeat (5) @(posedge clk);
		reset_n = 1;
		timeout = 0;
		while (!dut.cpu_cache.cache_init_done && timeout < 400) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		if (!dut.cpu_cache.cache_init_done) begin
			$display("FAIL: cache initialization timeout");
			errors = errors + 1;
		end

		// Descriptor byte address $00001c00: tag 3, set $80, words
		// $200/$201 in the 1Kx16 cache data RAMs.
		dut.cpu_cache.itram.mem[8'h80] = (40'h1 << 38) | 18'h00003;
		dut.cpu_cache.dtram.mem[8'h80] = (40'h1 << 38) | 18'h00003;
		dut.cpu_cache.idram0.ram_u.mem[10'h200] = 8'h00;
		dut.cpu_cache.idram0.ram_l.mem[10'h200] = 8'h00;
		dut.cpu_cache.idram0.ram_u.mem[10'h201] = 8'h00;
		dut.cpu_cache.idram0.ram_l.mem[10'h201] = 8'h01;
		dut.cpu_cache.ddram0.ram_u.mem[10'h200] = 8'h00;
		dut.cpu_cache.ddram0.ram_l.mem[10'h200] = 8'h00;
		dut.cpu_cache.ddram0.ram_u.mem[10'h201] = 8'h00;
		dut.cpu_cache.ddram0.ram_l.mem[10'h201] = 8'h01;

		@(negedge clk);
		walker_addr = 27'h0000700;
		walker_wdata = 32'h12340019;
		walker_we = 1;
		walker_req = 1;
		timeout = 0;
		while (!walker_ack && timeout < 100) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		#1;
		if (timeout == 100) begin
			$display("FAIL: DDR walker write timeout busy=%b snoop=%b low=%b we=%b ddrwe=%b",
			         dut.walker_busy, dut.walker_snoop,
			         dut.walker_snoop_low, dut.ram_we, ddram_we);
			errors = errors + 1;
		end
		walker_req = 0;

		if ({dut.cpu_cache.idram0.ram_u.mem[10'h200],
		     dut.cpu_cache.idram0.ram_l.mem[10'h200],
		     dut.cpu_cache.idram0.ram_u.mem[10'h201],
		     dut.cpu_cache.idram0.ram_l.mem[10'h201]} !== 32'h12340019) begin
			$display("FAIL: DDR walker I-cache snoop: %h%h%h%h",
			         dut.cpu_cache.idram0.ram_u.mem[10'h200],
			         dut.cpu_cache.idram0.ram_l.mem[10'h200],
			         dut.cpu_cache.idram0.ram_u.mem[10'h201],
			         dut.cpu_cache.idram0.ram_l.mem[10'h201]);
			errors = errors + 1;
		end
		if ({dut.cpu_cache.ddram0.ram_u.mem[10'h200],
		     dut.cpu_cache.ddram0.ram_l.mem[10'h200],
		     dut.cpu_cache.ddram0.ram_u.mem[10'h201],
		     dut.cpu_cache.ddram0.ram_l.mem[10'h201]} !== 32'h12340019) begin
			$display("FAIL: DDR walker D-cache snoop: %h%h%h%h",
			         dut.cpu_cache.ddram0.ram_u.mem[10'h200],
			         dut.cpu_cache.ddram0.ram_l.mem[10'h200],
			         dut.cpu_cache.ddram0.ram_u.mem[10'h201],
			         dut.cpu_cache.ddram0.ram_l.mem[10'h201]);
			errors = errors + 1;
		end

		if (errors == 0) $display("ALL TESTS PASSED");
		else             $display("TEST FAILED with %0d errors", errors);
		$finish;
	end
endmodule
