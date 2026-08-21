//--------------------------------------------------------------------------//
// DDR walker-READ regression                                               //
//                                                                          //
// The existing DDR walker bench ties DDRAM_DOUT_READY low and only drives  //
// writes and the cache snoop.  The table-walker READ path -- ddram_ctrl    //
// state 14 waiting on ram_dout_ready through the two-master arbiter -- has  //
// never been simulated, yet it is the exact path NetBSD's descriptor       //
// fetches take: its page tables live in Z3_1 (DDR3), so every table walk   //
// sets walker_ddr and reads through this controller.  AmigaOS runs from    //
// SDRAM and never exercises it.  This bench drives walker reads with a      //
// realistic Avalon DDR3 slave (variable latency, waitrequest) and forces   //
// the contention NetBSD produces: the a2065 Ethernet DMA on the arbiter's   //
// second master (le0 is attached and polling) and CPU cache fills, both     //
// competing with walker reads for the single DDR port.                      //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_ddram_walker_read;
	reg clk = 0;
	always #5 clk = ~clk;
	reg reset_n = 0;

	// walker port
	reg         walker_req = 0;
	reg         walker_we = 0;
	reg  [28:2] walker_addr = 0;
	reg  [31:0] walker_wdata = 0;
	wire        walker_ack;
	wire [31:0] walker_rdata;

	// a2065 second master (m1)
	reg  [28:0] mem2_address = 0;
	reg   [7:0] mem2_burstcount = 0;
	reg         mem2_read = 0;
	wire [63:0] mem2_readdata;
	wire        mem2_readdatavalid;
	reg  [63:0] mem2_writedata = 0;
	reg   [7:0] mem2_byteenable = 0;
	reg         mem2_write = 0;
	wire        mem2_waitrequest;

	// DDR3 slave wires
	wire        ddram_clk;
	wire        ddram_rd, ddram_we;
	wire [7:0]  ddram_burstcnt;
	wire [28:0] ddram_addr;
	wire [63:0] ddram_din;
	wire [7:0]  ddram_be;
	reg  [63:0] ddram_dout = 0;
	reg         ddram_dout_ready = 0;
	reg         ddram_busy = 0;

	ddram_ctrl #(.CPU_CACHE(1)) dut (
		.sysclk(clk), .reset_n(reset_n), .cache_rst(1'b1),
		.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0011),
		.DDRAM_CLK(ddram_clk), .DDRAM_BUSY(ddram_busy),
		.DDRAM_BURSTCNT(ddram_burstcnt), .DDRAM_ADDR(ddram_addr),
		.DDRAM_DOUT(ddram_dout), .DDRAM_DOUT_READY(ddram_dout_ready),
		.DDRAM_RD(ddram_rd), .DDRAM_DIN(ddram_din),
		.DDRAM_BE(ddram_be), .DDRAM_WE(ddram_we),
		.mem2_address(mem2_address), .mem2_burstcount(mem2_burstcount),
		.mem2_read(mem2_read), .mem2_readdata(mem2_readdata),
		.mem2_readdatavalid(mem2_readdatavalid),
		.mem2_writedata(mem2_writedata), .mem2_byteenable(mem2_byteenable),
		.mem2_write(mem2_write), .mem2_waitrequest(mem2_waitrequest),
		.cpuAddr(28'd0), .cpuCS(1'b0), .cpustate(2'b00),
		.cpuL(1'b1), .cpuU(1'b1), .cpuWR(16'd0), .cpuRD(),
		.ramshared(1'b0), .ramready(),
		.walker_req(walker_req), .walker_we(walker_we),
		.walker_addr(walker_addr), .walker_wdata(walker_wdata),
		.walker_ack(walker_ack), .walker_rdata(walker_rdata)
	);

	//----------------------------------------------------------------------
	// Avalon-MM DDR3 slave model.  64-bit words, one 8 KB window backed by a
	// small array.  Read latency and waitrequest are programmable so the
	// bench can slide the slave's timing under the walker/arbiter handshake.
	//----------------------------------------------------------------------
	reg [63:0] ddr_mem [0:1023];       // 8 KB modelled at {addr[12:3]}
	integer    rd_lat = 4;             // cycles from accepted read to valid
	reg        busy_pattern = 0;       // 1 = waitrequest toggles every cycle

	// waitrequest: either always ready, or a one-cycle-on/off stutter to
	// exercise held commands
	reg busy_tgl = 0;
	always @(posedge clk) busy_tgl <= ~busy_tgl;
	always @(*) ddram_busy = busy_pattern ? busy_tgl : 1'b0;

	integer errors = 0;
	integer guard;
	integer outstanding = 0;

	// read-return pipeline: when a read is accepted (rd asserted and not
	// waited), schedule readdatavalid rd_lat cycles later with the data at
	// the issued address.  A tiny shift register models the latency.
	reg [63:0] rr_dat [0:15];
	reg [15:0] rr_v = 0;
	integer i;
	always @(posedge clk) begin
		ddram_dout_ready <= rr_v[0];
		ddram_dout       <= rr_dat[0];
		for (i = 0; i < 15; i = i + 1) begin
			rr_v[i]   <= rr_v[i+1];
			rr_dat[i] <= rr_dat[i+1];
		end
		rr_v[15]   <= 1'b0;
		// accept a read command this cycle?
		if (ddram_rd && !ddram_busy) begin
			rr_v[rd_lat]   <= 1'b1;
			rr_dat[rd_lat] <= ddr_mem[ddram_addr[12:3]];
			// outstanding-read accounting: the arbiter promises only one
			// read burst is ever in flight.  If a second read is accepted
			// while one is still outstanding, the single-slave model would
			// corrupt -- and the arbiter contract is broken.
			outstanding <= outstanding + 1;
			if (outstanding != 0) begin
				$display("FAIL: two DDR reads in flight (arbiter let a second start) t=%0t addr=%h",
				         $time, ddram_addr);
				errors = errors + 1;
			end
		end
		if (ddram_dout_ready) outstanding <= outstanding - (ddram_rd && !ddram_busy ? 0 : 1);
		// writes land immediately when accepted
		if (ddram_we && !ddram_busy) begin
			for (i = 0; i < 8; i = i + 1)
				if (ddram_be[i]) ddr_mem[ddram_addr[12:3]][i*8 +: 8] <= ddram_din[i*8 +: 8];
		end
	end

	reg [31:0] got, exp_v;

	// expected walker read result for a descriptor word at byte address
	// {addr,2'b00}: ddram_ctrl swaps the 16-bit halves of the selected
	// 32-bit lane out of the 64-bit word (see state 14).
	// mirror the DUT exactly: it forms ddram_addr = {3'b001, a[28:3]} and
	// the slave indexes ddr_mem[ddram_addr[12:3]] == ddr_mem[a[15:6]].
	// a[2] then selects the 32-bit half, with the 16-bit swap of state 14.
	function [31:0] expect_word;
		input [28:2] a;
		reg [63:0] w;
		begin
			w = ddr_mem[a[15:6]];
			expect_word = a[2] ? {w[47:32], w[63:48]}
			                   : {w[15:0],  w[31:16]};
		end
	endfunction

	task walker_read;
		input [28:2] addr;
		begin
			@(negedge clk);
			walker_we = 0; walker_addr = addr; walker_req = 1;
			guard = 0;
			while (!walker_ack && guard < 500) begin
				@(posedge clk); guard = guard + 1;
			end
			if (!walker_ack) begin
				$display("FAIL: walker read timeout addr=%h walker_busy=%b",
				         {addr,2'b00}, dut.walker_busy);
				errors = errors + 1;
			end
			else begin
				got = walker_rdata; exp_v = expect_word(addr);
				if (got !== exp_v) begin
					$display("FAIL: walker read addr=%h got=%h exp_v=%h",
					         {addr,2'b00}, got, exp_v);
					errors = errors + 1;
				end
			end
			@(negedge clk);
			walker_req = 0;
			repeat (3) @(posedge clk);
		end
	endtask

	// background a2065 traffic on m1: single-beat reads at a low rate, the
	// steady descriptor-ring poll a live le0 performs.  Runs concurrently
	// with the walker so the arbiter must interleave the two masters.
	// realistic a2065: issue ONE single-beat read, wait for its data, then
	// (after a short idle gap) issue the next.  Never more than one m1 read
	// outstanding -- the real lance polls this way.
	reg m1_on = 0;
	reg [1:0] m1_state = 0;
	reg [3:0] m1_gap = 0;
	always @(posedge clk) begin
		if (!reset_n || !m1_on) begin
			mem2_read <= 0; mem2_burstcount <= 0; m1_state <= 0; m1_gap <= 0;
		end
		else begin
			case (m1_state)
				0: begin   // issue
					mem2_address    <= 29'h20 + ((mem2_address + 8) & 29'hFF);
					mem2_burstcount <= 1;
					mem2_read       <= 1;
					m1_state        <= 1;
				end
				1: if (!mem2_waitrequest) begin   // command accepted
					mem2_read <= 0;
					m1_state  <= 2;
				end
				2: if (mem2_readdatavalid) begin  // data returned
					m1_gap   <= 3;
					m1_state <= 3;
				end
				3: if (m1_gap == 0) m1_state <= 0;
				   else m1_gap <= m1_gap - 1'b1;
			endcase
		end
	end

	integer t;
	initial begin
		for (t = 0; t < 1024; t = t + 1)
			ddr_mem[t] = {32'hC0DE0000 + t, 32'h1000_0000 + (t << 3)};

		repeat (5) @(posedge clk);
		reset_n = 1;
		guard = 0;
		while (!dut.cpu_cache.cache_init_done && guard < 600) begin
			@(posedge clk); guard = guard + 1;
		end
		if (!dut.cpu_cache.cache_init_done) begin
			$display("FAIL: cache init timeout"); errors = errors + 1;
		end

		// 1) a plain walker read, quiescent slave
		walker_read(27'h0000400);
		walker_read(27'h0000404);   // odd 32-bit lane within the 64-bit word

		// 2) back-to-back walker reads, no gap for the arbiter to relax
		walker_read(27'h0000800);
		walker_read(27'h0000804);
		walker_read(27'h0000808);

		// 3) higher read latency: the slave returns data long after the
		//    command is accepted, so state 14 must wait through the gap
		rd_lat = 12;
		walker_read(27'h0000C00);
		walker_read(27'h0000C40);
		rd_lat = 4;

		// 4) waitrequest stutter: the slave holds the read command off for
		//    a cycle at a time, so ram_rd must persist as a level
		busy_pattern = 1;
		walker_read(27'h0001000);
		walker_read(27'h0001044);
		busy_pattern = 0;

		// 5a) m1 contention alone (default latency, no stutter)
		$display("PHASE 5a: m1 only");
		m1_on = 1;
		repeat (20) @(posedge clk);
		walker_read(27'h0001400);
		walker_read(27'h0001404);
		walker_read(27'h0001800);
		m1_on = 0;

		// 5b) stutter alone (no m1)
		$display("PHASE 5b: stutter only");
		busy_pattern = 1;
		walker_read(27'h0001840);
		walker_read(27'h0001C00);
		busy_pattern = 0;

		// 5c) high latency alone (no m1)
		$display("PHASE 5c: latency only");
		rd_lat = 12;
		walker_read(27'h0001C44);
		walker_read(27'h0000480);
		rd_lat = 4;

		// 5d) stutter + m1
		$display("PHASE 5d: stutter + m1");
		busy_pattern = 1; m1_on = 1;
		repeat (20) @(posedge clk);
		walker_read(27'h00004C0);
		walker_read(27'h0000500);
		busy_pattern = 0; m1_on = 0;

		// 5e) latency + m1
		$display("PHASE 5e: latency + m1");
		rd_lat = 12; m1_on = 1;
		repeat (20) @(posedge clk);
		walker_read(27'h0000540);
		walker_read(27'h0000580);
		rd_lat = 4; m1_on = 0;

		// 5f) latency + stutter + m1 (the original failing combination)
		$display("PHASE 5f: latency + stutter + m1");
		rd_lat = 9; busy_pattern = 1; m1_on = 1;
		repeat (20) @(posedge clk);
		walker_read(27'h00005C0);
		walker_read(27'h0000600);
		busy_pattern = 0; rd_lat = 4; m1_on = 0;

		if (errors == 0) $display("ALL TESTS PASSED");
		else $display("TEST FAILED with %0d errors", errors);
		$finish;
	end

	// global watchdog: a walker hang would otherwise spin to $finish never
	initial begin
		#500000;
		$display("FAIL: global timeout -- walker never completed");
		$finish;
	end

endmodule
