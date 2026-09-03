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
	always #5 clk = ~clk;          // 113 MHz domain (ddram_ctrl sysclk)
	reg clk28 = 0;
	always #20 clk28 = ~clk28;     // 28 MHz domain (MMU / walker s-side)
	reg reset_n = 0;

	// walker stimulus enters on the 28 MHz side of the REAL clock-domain
	// bridge (ap040_walker_cdc), exactly as the MMU's requests do on
	// hardware; the bridge's m side feeds ddram_ctrl at 113 MHz.  Driving
	// the controller directly would skip the CDC handshake entirely.
	reg         walker_req = 0;
	reg         walker_we = 0;
	reg  [28:2] walker_addr = 0;
	reg  [31:0] walker_wdata = 0;
	wire        walker_ack;
	wire [31:0] walker_rdata;
	wire        walker_berr_s;

	wire        mw_req, mw_we, mw_ddr;
	wire [28:2] mw_addr;
	wire [31:0] mw_wdata;
	wire        mw_ack;
	wire [31:0] mw_rdata;

	// walker watchdog between the CDC m side and the controller, wired as
	// in Minimig.sv: a transaction the controller never answers completes
	// as a bus error instead of stalling the MMU (and the CPU) forever.
	wire mw_wd_berr;
	ap040_bus_timeout #(.COUNTER_BITS(16)) walker_timeout (
		.clk(clk), .nreset(reset_n),
		.req(mw_req), .complete(mw_ack), .berr(mw_wd_berr)
	);

	ap040_walker_cdc walker_cdc (
		.s_clk(clk28), .s_reset_n(reset_n),
		.s_req(walker_req), .s_we(walker_we), .s_addr(walker_addr),
		.s_wdata(walker_wdata), .s_ddr(1'b1), .s_bad(1'b0),
		.s_ack(walker_ack), .s_rdata(walker_rdata), .s_berr(walker_berr_s),
		.m_clk(clk), .m_reset_n(reset_n),
		.m_req(mw_req), .m_we(mw_we), .m_addr(mw_addr), .m_wdata(mw_wdata),
		.m_ddr(mw_ddr), .m_ack(mw_ack), .m_rdata(mw_rdata), .m_berr(mw_wd_berr)
	);

	// AP040 line-fill channel (plan X3.4, A1-1): the cache's request
	// enters on the 28 MHz side of the REAL bridge (ap040_fill_cdc), the
	// bridge's m side feeds ddram_ctrl's fill port at 113 MHz, and the
	// line comes back as one 128-bit payload.  The watchdog in front of
	// the controller is wired as Minimig.sv will wire it: a fill the
	// controller never answers ends as an error, not a hang.
	reg         fill_req = 0;
	reg  [28:4] fill_addr = 0;
	wire        fill_ack;
	wire [127:0] fill_data;
	wire        fill_err;
	wire        mf_req, mf_ddr;
	wire [28:4] mf_addr;
	wire        mf_strb, mf_ack;
	wire [31:0] mf_dat;
	wire        mf_wd_berr;
	ap040_bus_timeout #(.COUNTER_BITS(16)) fill_timeout (
		.clk(clk), .nreset(reset_n),
		.req(mf_req), .complete(mf_ack), .berr(mf_wd_berr)
	);
	ap040_fill_cdc fill_cdc (
		.s_clk(clk28), .s_reset_n(reset_n),
		.s_req(fill_req), .s_addr(fill_addr), .s_ddr(1'b1), .s_bad(1'b0),
		.s_ack(fill_ack), .s_data(fill_data), .s_err(fill_err),
		.m_clk(clk), .m_reset_n(reset_n),
		.m_req(mf_req), .m_addr(mf_addr), .m_ddr(mf_ddr),
		.m_strb(mf_strb), .m_dat(mf_dat), .m_ack(mf_ack), .m_berr(mf_wd_berr)
	);

	// CPU cache port -- exercises the OTHER DDR3 read consumer (cache line
	// fill, ddram_ctrl state 1) under the same contention.  A cache fill
	// that never completes hangs the CPU exactly as the live NetBSD stall.
	reg  [28:1] cpuAddr = 0;
	reg         cpuCS = 0;
	reg  [1:0]  cpustate = 0;
	reg         cpuL = 1, cpuU = 1;
	reg  [15:0] cpuWR = 0;
	wire [15:0] cpuRD;
	wire        ramready;

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

	reg        cache_inhibit = 0;   // MMU CI bit, driven per access
	reg [15:0] ci_a, ci_b;

	// Two CPU reads with the SHORTEST possible gap -- cpuCS low for a
	// single cycle -- which is what the core does between consecutive
	// loads, and the window in which a no-allocate fill's stranded beats
	// are still being delivered by the real controller.
	task cpu_read_tight;
		input [28:1] addr1;
		input        ci1;
		input [28:1] addr2;
		output [15:0] v1;
		output [15:0] v2;
		integer guard;
		begin
			@(negedge clk);
			cache_inhibit = ci1;
			cpuAddr = addr1; cpuL = 0; cpuU = 0; cpustate = 0; cpuCS = 1;
			guard = 0;
			while (!ramready && guard < 200000) begin
				@(posedge clk); guard = guard + 1;
			end
			v1 = cpuRD;
			@(negedge clk);
			cpuCS = 0; cache_inhibit = 0;
			@(negedge clk);
			cpuAddr = addr2; cpuCS = 1;
			guard = 0;
			while (!ramready && guard < 200000) begin
				@(posedge clk); guard = guard + 1;
			end
			v2 = cpuRD;
			@(negedge clk);
			cpuCS = 0; cpustate = 0; cpuL = 1; cpuU = 1;
			repeat (2) @(posedge clk);
		end
	endtask

	ddram_ctrl #(.CPU_CACHE(1)) dut (
		.sysclk(clk), .reset_n(reset_n), .cache_rst(1'b1),
		.cache_inhibit(cache_inhibit), .cpu_cache_ctrl(4'b0011),
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
		.cpuAddr(cpuAddr), .cpuCS(cpuCS), .cpustate(cpustate),
		.cpuL(cpuL), .cpuU(cpuU), .cpuWR(cpuWR), .cpuRD(cpuRD),
		.ramshared(1'b0), .ramready(ramready),
		.fill_req(mf_req), .fill_addr(mf_addr),
		.fill_strb(mf_strb), .fill_dat(mf_dat), .fill_ack(mf_ack),
		.walker_req(mw_req), .walker_we(mw_we),
		.walker_addr(mw_addr), .walker_wdata(mw_wdata),
		.walker_ack(mw_ack), .walker_rdata(mw_rdata)
	);

	//----------------------------------------------------------------------
	// Avalon-MM DDR3 slave model.  64-bit words, one 8 KB window backed by a
	// small array.  Read latency and waitrequest are programmable so the
	// bench can slide the slave's timing under the walker/arbiter handshake.
	//----------------------------------------------------------------------
	reg [63:0] ddr_mem [0:1023];       // 8 KB modelled at {addr[12:3]}
	integer    rd_lat = 4;             // cycles from accepted read to valid
	reg        busy_pattern = 0;       // 1 = waitrequest toggles every cycle
	reg        slave_wedged = 0;       // 1 = accepted reads held, not returned
	reg        drop_next = 0;          // drop exactly one accepted read
	reg        wedge_seen = 0;         // latched: phase 10 has begun
	reg [15:0] ref16, got16;           // phase 15 reference and result
	reg [1:0]  held_v = 0;             // held reads awaiting release (queue)
	reg [63:0] held_dat = 0;
	reg [63:0] held_dat1 = 0;

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
		// accept a read command this cycle?  A wedged slave HOLDS the
		// response (models a beat delayed beyond the watchdog) and
		// releases it when unwedged -- the transient-hang shape.
		if (slave_wedged || drop_next) wedge_seen <= 1'b1;
		if (ddram_rd && !ddram_busy && drop_next) begin
			drop_next <= 1'b0;   // response lost forever: nothing scheduled
		end
		else if (ddram_rd && !ddram_busy && slave_wedged) begin
			if (!held_v[0]) begin
				held_v[0] <= 1'b1;
				held_dat  <= ddr_mem[ddram_addr[12:3]];
			end
			else begin
				held_v[1] <= 1'b1;
				held_dat1 <= ddr_mem[ddram_addr[12:3]];
			end
		end
		if (held_v[0] && !slave_wedged) begin
			held_v[0]      <= held_v[1];
			held_dat       <= held_dat1;
			held_v[1]      <= 1'b0;
			rr_v[rd_lat]   <= 1'b1;
			rr_dat[rd_lat] <= held_dat;
		end
		if (ddram_rd && !ddram_busy && !slave_wedged && !drop_next) begin
			rr_v[rd_lat]   <= 1'b1;
			rr_dat[rd_lat] <= ddr_mem[ddram_addr[12:3]];
			// outstanding-read accounting: the arbiter promises only one
			// read burst is ever in flight.  If a second read is accepted
			// while one is still outstanding, the single-slave model would
			// corrupt -- and the arbiter contract is broken.
			outstanding <= outstanding + 1;
			// phase 10 deliberately abandons a transaction whose response
			// arrives late; the one-in-flight bookkeeping does not apply
			// from that point on (the check has done its job for the
			// contention phases 1-9)
			if (outstanding != 0 && !wedge_seen) begin
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
	// the halfword a CPU cache fill must hand back for a given word address
	function [15:0] expect_cpu;
		input [28:1] a;
		reg [63:0] w;
		begin
			w = ddr_mem[a >> 2];
			expect_cpu = w[47:32];   // == the ddr_mem index for this pattern
		end
	endfunction

	function [31:0] expect_word;
		input [28:2] a;
		reg [63:0] w;
		begin
			w = ddr_mem[a[15:6]];
			expect_word = a[2] ? {w[47:32], w[63:48]}
			                   : {w[15:0],  w[31:16]};
		end
	endfunction

	// the 16-byte line the fill channel must hand back for a line address:
	// two consecutive 64-bit words, each split into two longwords in 68k
	// byte order exactly as expect_word does for the walker
	// The slave model indexes ddr_mem[ddram_addr[12:3]], i.e. by byte
	// address bits [15:6], so the two 64-bit words of one line land on
	// the SAME entry here -- the model is coarse on purpose (see
	// expect_word).  The channel must return that entry twice, each
	// half split as the walker splits it.
	function [127:0] expect_line;
		input [28:4] a;
		reg [63:0] w;
		begin
			w = ddr_mem[a[15:6]];
			expect_line = {w[15:0], w[31:16], w[47:32], w[63:48],
			               w[15:0], w[31:16], w[47:32], w[63:48]};
		end
	endfunction

	integer fill_cyc;
	integer fill_cyc_min = 99999;
	integer fill_cyc_max = 0;
	task fill_line;
		input [28:4] addr;
		reg [127:0] expl;
		begin
			@(negedge clk28);
			fill_addr = addr; fill_req = 1;
			guard = 0;
			while (!fill_ack && guard < 40000) begin
				@(posedge clk28); guard = guard + 1;
			end
			fill_cyc = guard;
			if (!fill_ack) begin
				$display("FAIL: fill timeout addr=%h (bridge m_req=%b)",
				         {addr,4'h0}, mf_req);
				errors = errors + 1;
			end
			else if (fill_err) begin
				$display("FAIL: fill addr=%h unexpected error", {addr,4'h0});
				errors = errors + 1;
			end
			else begin
				expl = expect_line(addr);
				if (fill_data !== expl) begin
					$display("FAIL: fill addr=%h got=%h exp=%h",
					         {addr,4'h0}, fill_data, expl);
					errors = errors + 1;
				end
				if (fill_cyc < fill_cyc_min) fill_cyc_min = fill_cyc;
				if (fill_cyc > fill_cyc_max) fill_cyc_max = fill_cyc;
			end
			@(negedge clk28);
			fill_req = 0;
			repeat (3) @(posedge clk28);
		end
	endtask

	// a fill that must complete as an ERROR (lost response, watchdog)
	task fill_line_berr;
		input [28:4] addr;
		begin
			@(negedge clk28);
			fill_addr = addr; fill_req = 1;
			guard = 0;
			while (!fill_ack && guard < 90000) begin
				@(posedge clk28); guard = guard + 1;
			end
			if (!fill_ack) begin
				$display("FAIL: lost-response fill never completed at all (no error either)");
				errors = errors + 1;
			end
			else if (!fill_err) begin
				$display("FAIL: lost-response fill completed WITHOUT an error");
				errors = errors + 1;
			end
			@(negedge clk28);
			fill_req = 0;
			repeat (3) @(posedge clk28);
		end
	endtask

	task walker_read;
		input [28:2] addr;
		begin
			@(negedge clk28);
			walker_we = 0; walker_addr = addr; walker_req = 1;
			guard = 0;
			while (!walker_ack && guard < 40000) begin
				@(posedge clk28); guard = guard + 1;
			end
			if (!walker_ack) begin
				$display("FAIL: walker read timeout addr=%h walker_busy=%b",
				         {addr,2'b00}, dut.walker_busy);
				errors = errors + 1;
			end
			else if (walker_berr_s) begin
				$display("FAIL: walker read addr=%h unexpected BERR",
				         {addr,2'b00});
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
			@(negedge clk28);
			walker_req = 0;
			repeat (3) @(posedge clk28);
		end
	endtask

	// walker WRITE (M/U-bit writeback path, ddram_ctrl states 5-13 with the
	// cache snoop) -- pmap_enter's faulting writes set M/U on DDR3 PTEs, so
	// this path runs under exactly the contention that froze NetBSD.
	task walker_write;
		input [28:2] addr;
		input [31:0] data;
		begin
			@(negedge clk28);
			walker_we = 1; walker_addr = addr; walker_wdata = data;
			walker_req = 1;
			guard = 0;
			while (!walker_ack && guard < 40000) begin
				@(posedge clk28); guard = guard + 1;
			end
			if (!walker_ack) begin
				$display("FAIL: walker WRITE timeout addr=%h walker_busy=%b",
				         {addr,2'b00}, dut.walker_busy);
				errors = errors + 1;
			end
			@(negedge clk28);
			walker_req = 0; walker_we = 0;
			repeat (3) @(posedge clk28);
		end
	endtask

	// a walker WRITE that must complete as a BUS ERROR (watchdog case)
	task walker_write_berr;
		input [28:2] addr;
		input [31:0] data;
		begin
			@(negedge clk28);
			walker_we = 1; walker_addr = addr; walker_wdata = data;
			walker_req = 1;
			guard = 0;
			while (!walker_ack && guard < 40000) begin
				@(posedge clk28); guard = guard + 1;
			end
			if (!walker_ack || !walker_berr_s) begin
				$display("FAIL: backpressured write did not bus-error (ack=%b berr=%b)",
				         walker_ack, walker_berr_s);
				errors = errors + 1;
			end
			@(negedge clk28);
			walker_req = 0; walker_we = 0;
			repeat (3) @(posedge clk28);
		end
	endtask

	// a walker read that must complete as a BUS ERROR (watchdog case)
	task walker_read_berr;
		input [28:2] addr;
		begin
			@(negedge clk28);
			walker_we = 0; walker_addr = addr; walker_req = 1;
			guard = 0;
			while (!walker_ack && guard < 40000) begin
				@(posedge clk28); guard = guard + 1;
			end
			if (!walker_ack) begin
				$display("FAIL: wedged walk neither acked nor bus-errored");
				errors = errors + 1;
			end
			else if (!walker_berr_s) begin
				$display("FAIL: wedged walk completed without berr");
				errors = errors + 1;
			end
			@(negedge clk28);
			walker_req = 0;
			repeat (3) @(posedge clk28);
		end
	endtask

	// drive one CPU cache read (ifetch) and wait for it to complete.  On a
	// miss this runs the ddram_ctrl cache-fill path (state 1) through the
	// arbiter, the same path NetBSD's kernel code fetch from DDR3 uses.
	task cpu_read;
		input [28:1] addr;
		begin
			@(negedge clk);
			cpuAddr = addr; cpuL = 0; cpuU = 0; cpustate = 0; cpuCS = 1;
			guard = 0;
			while (!ramready && guard < 200000) begin
				@(posedge clk); guard = guard + 1;
			end
			if (!ramready) begin
				$display("FAIL: CPU cache read timeout addr=%h", {addr,1'b0});
				errors = errors + 1;
			end
			@(negedge clk);
			cpuCS = 0; cpustate = 0; cpuL = 1; cpuU = 1;
			repeat (2) @(posedge clk);
		end
	endtask

	// cpu_read that also returns the halfword the cache handed back --
	// phase 15 compares a fill that raced an orphan beat against a clean
	// reference fill of the same pattern word.
	task cpu_read_val;
		input [28:1] addr;
		output [15:0] val;
		begin
			@(negedge clk);
			cpuAddr = addr; cpuL = 0; cpuU = 0; cpustate = 0; cpuCS = 1;
			guard = 0;
			while (!ramready && guard < 200000) begin
				@(posedge clk); guard = guard + 1;
			end
			if (!ramready) begin
				$display("FAIL: CPU cache read timeout addr=%h", {addr,1'b0});
				errors = errors + 1;
			end
			val = cpuRD;
			@(negedge clk);
			cpuCS = 0; cpustate = 0; cpuL = 1; cpuU = 1;
			repeat (2) @(posedge clk);
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
	reg m1_wr_turn = 0;
	always @(posedge clk) begin
		if (!reset_n || !m1_on) begin
			mem2_read <= 0; mem2_burstcount <= 0; m1_state <= 0; m1_gap <= 0;
		end
		else begin
			case (m1_state)
				0: begin   // issue: alternate read and single-beat write,
					   // as the a2065 mailbox does (CSR poll reads + command
					   // writes), always burstcount 1, hold until accepted
					mem2_address    <= 29'h20 + ((mem2_address + 8) & 29'hFF);
					mem2_burstcount <= 1;
					if (m1_wr_turn) begin
						mem2_writedata  <= 64'hA2065_DEAD_0000 + mem2_address;
						mem2_byteenable <= 8'hFF;
						mem2_write      <= 1;
					end
					else mem2_read <= 1;
					m1_wr_turn <= ~m1_wr_turn;
					m1_state   <= 1;
				end
				1: if (!mem2_waitrequest) begin   // command accepted
					mem2_read  <= 0;
					mem2_write <= 0;
					m1_state   <= mem2_write ? 3 : 2;  // writes need no data
				end
				2: if (mem2_readdatavalid) begin  // read data returned
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

		// 7) CPU cache fills under a2065 contention, then interleaved
		//    with walker reads -- the full pmap_enter contention shape
		//    (kernel code fetch + table walk + ethernet DMA on one DDR
		//    port).  Sweep latency and stutter so a dropped readdatavalid
		//    on the cache path (state 1) or an arbitration deadlock would
		//    hang the CPU read here.
		$display("PHASE 7: cache fills under m1 contention");
		m1_on = 1;
		repeat (20) @(posedge clk);
		cpu_read(28'h000100);
		cpu_read(28'h000180);
		cpu_read(28'h000200);
		rd_lat = 10; busy_pattern = 1;
		cpu_read(28'h000280);
		cpu_read(28'h000300);
		busy_pattern = 0; rd_lat = 4;
		m1_on = 0;

		$display("PHASE 8: cache + walker + m1 interleaved, latency+stutter");
		rd_lat = 8; busy_pattern = 1; m1_on = 1;
		repeat (20) @(posedge clk);
		cpu_read(28'h000400);
		walker_read(27'h0000900);
		cpu_read(28'h000480);
		walker_read(27'h0000940);
		cpu_read(28'h000500);
		walker_read(27'h0000980);
		busy_pattern = 0; rd_lat = 4; m1_on = 0;

		// 9) walker WRITES (M/U writeback) under a2065 contention with
		//    latency + stutter, interleaved with walker reads and cache
		//    fills -- the exact DDR3 traffic mix pmap_enter generates.
		$display("PHASE 9: walker writes + reads + cache + m1, latency+stutter");
		rd_lat = 7; busy_pattern = 1; m1_on = 1;
		repeat (20) @(posedge clk);
		walker_write(27'h0000A00, 32'h1111_2223);
		walker_read (27'h0000A00);
		cpu_read(28'h000600);
		walker_write(27'h0000A40, 32'h4444_5556);
		walker_read (27'h0000A40);
		walker_write(27'h0000A80, 32'h7777_8889);
		cpu_read(28'h000680);
		walker_read (27'h0000A80);
		busy_pattern = 0; rd_lat = 4; m1_on = 0;

		// 11) LOST walker response, NO quiescence: the response vanishes;
		//     the walker walk bus-errors at the (production-ordered) outer
		//     watchdog, by which time the controller abort, the arbiter
		//     abandonment, and the quarantine decay have already freed the
		//     port -- so the bus-error exception's own memory traffic (here
		//     the immediately following reads) is served, not double-
		//     faulted.  Reads issued DURING the quarantine stall in
		//     waitrequest until it lifts and then complete correctly; they
		//     are never mis-completed with another burst's data.
		$display("PHASE 11: lost walker response, no quiescence");
		drop_next = 1;
		walker_read_berr(27'h0000450);
		cpu_read(28'h000700);            // immediately: stalls, then works
		walker_read(27'h0000450);
		cpu_read(28'h000740);

		// 12) LOST CPU cache fill: the fill's response vanishes.  The
		//     controller aborts state 1, the still-held cache_req retries,
		//     the quarantine holds the retry until decay, and the read
		//     completes with CORRECT data -- the retry's response must not
		//     be swallowed (the repeating timeout->swallow->timeout loop
		//     the first quarantine design allowed).
		$display("PHASE 12: lost CPU fill recovers by retry");
		drop_next = 1;
		cpu_read(28'h000780);
		walker_read(27'h0000480);

		// 13) LOST a2065 read followed by CPU traffic.  The real mailbox
		//     has no timeout and stays wedged waiting for its data -- but
		//     the ARBITER must abandon the burst so the CPU keeps running
		//     (le0 dies, the machine lives).  m1 stops driving after the
		//     loss, as the real mailbox would.
		$display("PHASE 13: lost a2065 read, CPU unaffected");
		m1_on = 1;
		repeat (30) @(posedge clk);
		drop_next = 1;                   // next accepted read (m1's) lost
		repeat (200) @(posedge clk);
		m1_on = 0;                       // mailbox wedged: stops requesting
		cpu_read(28'h0007C0);
		walker_read(27'h00004C0);

		// 14) permanently backpressured walker WRITE: the command can
		//     never be accepted; the state-5 escape withdraws it (no late
		//     acceptance bypassing the snoop sequence) and the walker
		//     watchdog reports the walk.  The port then works again.
		$display("PHASE 14: permanent write backpressure");
		force ddram_busy = 1'b1;
		walker_write_berr(27'h0000500, 32'h5A5A_0001);
		if (ddram_we) begin
			$display("FAIL: abandoned walker write still asserted");
			errors = errors + 1;
		end
		release ddram_busy;
		repeat (200) @(posedge clk);
		walker_read(27'h0000440);
		cpu_read(28'h000600);

		// 10) wedged slave: read data never returns (the hang class the
		//     readdatavalid fix removed, induced deliberately).  The
		//     watchdog must complete the walk as a bus error -- the MMU
		//     reports a failed table search instead of freezing the CPU --
		//     and the path must recover for the next well-behaved walk.
		$display("PHASE 10: wedged slave -> watchdog berr, then recovery");
		slave_wedged = 1;
		walker_read_berr(27'h0000440);   // held past the watchdog: berr
		slave_wedged = 0;                // the late data now arrives; the
		repeat (60) @(posedge clk);      // completed-but-abandoned response
		walker_read(27'h0000440);        // must not corrupt the next walk

		// 15) late response after a controller abort.  A read the slave
		//     ACCEPTED but answers only after ddram_ctrl's rdwait abort
		//     owes a beat nobody is waiting for.  Before the drain it was
		//     consumed as the NEXT read's data: one cache line filled with
		//     the previous read's bytes -- the tc_windup a2 panic, where a
		//     movem restore popped a shifted longword into the timehands
		//     pointer.  The drain must swallow the orphan and hold new
		//     reads off until the pipe is clean.
		// 15) late beat in the timeout-epoch skew window.  ddram_ctrl's
		//     rdwait counts from COMMAND ISSUE; the arbiter's resp_wait
		//     counts from SLAVE ACCEPTANCE.  When waitrequest stretches
		//     (DDR3 under ARM-side contention does), the controller
		//     aborts thousands of cycles before the arbiter would
		//     quarantine -- a response landing in that window is forwarded
		//     by the live arbiter and was consumed as the NEXT read's
		//     data: one fill of the neighbouring word, the tc_windup a2
		//     panic.  The controller-side drain must swallow the orphan
		//     and hold new reads until the pipe is clean.
		// 15) late beat inside the timeout-epoch skew window.  ddram_ctrl's
		//     rdwait counts from COMMAND ISSUE; the arbiter's resp_wait
		//     counts from SLAVE ACCEPTANCE.  Stretched waitrequest (DDR3
		//     under ARM-side contention) separates the two epochs, so the
		//     controller abandons a read thousands of cycles before the
		//     arbiter would quarantine its response.  That response is
		//     still forwarded, and with nothing tracking it, the NEXT read
		//     consumed it as its own data: a cache line filled from the
		//     neighbouring address.  One such fill under a movem restore
		//     pops a shifted longword into a register -- the tc_windup a2
		//     panic, where the kernel's timehands pointer became a user
		//     address.  The controller must account for an accepted read
		//     and drain the orphan before admitting another.
		$display("PHASE 15: late beat in the timeout-epoch skew window");
		cpu_read_val(28'h0000600, got16);  // formula self-check on a clean
		if (got16 !== expect_cpu(28'h0000600)) begin
			$display("FAIL: phase 15 reference model wrong: got=%h exp=%h",
			         got16, expect_cpu(28'h0000600));
			errors = errors + 1;
		end
		slave_wedged = 1;
		@(negedge clk28);
		walker_we = 0; walker_addr = 27'h0000520; walker_req = 1;
		wait (dut.walker_busy === 1'b1);   // dispatched: rdwait counting
		force ddram_busy = 1'b1;           // acceptance held off, so the
		repeat (3000) @(posedge clk);      // arbiter's epoch lags by 3000
		release ddram_busy;                // accepted; the wedge holds data
		repeat (13600) @(posedge clk);     // controller abort (2^14 from
		                                   // issue) has now fired, while
		                                   // the arbiter is still live
		rd_lat = 4;
		slave_wedged = 0;                  // the orphan beat is in flight
		cpu_read_val(28'h0000700, got16);  // the victim fill races it
		ref16 = expect_cpu(28'h0000700);
		if (got16 !== ref16) begin
			$display("FAIL: post-abort orphan aliased the next fill: got=%h exp=%h",
			         got16, ref16);
			errors = errors + 1;
		end
		guard = 0;                         // retire the bus-errored walk
		while (!walker_ack && guard < 90000) begin
			@(posedge clk28); guard = guard + 1;
		end
		@(negedge clk28); walker_req = 0;
		repeat (200) @(posedge clk);
		walker_read(27'h0000540);          // and the pipe is clean again

		// 16) a cache-inhibited (no-allocate) fill must not strand the
		//     rest of its line.  ddram_ctrl answers every cache_req with
		//     four beats from one 64-bit word; a cache that takes beat 1
		//     and leaves lets the NEXT fill adopt a leftover as its own
		//     data.  On an instruction fetch that is a garbage opcode --
		//     NetBSD died with trap type 2 (T_ILLINST) at pc=00002276.
		//     Run against the REAL controller so the beats are real.
		$display("PHASE 16: no-allocate fill must not strand its line");
		cpu_read_tight(28'h0002200, 1'b1, 28'h0004400, ci_a, ci_b);
		if (ci_b === ci_a) begin
			$display("FAIL: read after a no-allocate fill returned the first line's word (%h)",
			         ci_b);
			errors = errors + 1;
		end
		$display("  (inhibited=%h next=%h)", ci_a, ci_b);

		// 17) the line-fill channel (plan X3.4, A1-1): whole lines through
		//     the real bridge and ddram_ctrl's fill port, quiet and under
		//     every contention shape the walker phases use, then a lost
		//     response that must end as an error and leave the port clean.
		$display("PHASE 17: line-fill channel");
		rd_lat = 4; busy_pattern = 0; m1_on = 0;
		repeat (20) @(posedge clk);
		fill_line(25'h0000080);            // quiet
		fill_line(25'h0000090);
		fill_line(25'h00000C0);
		$display("  fill latency, quiet bus: %0d clk28 cycles request->ack", fill_cyc);
		rd_lat = 12;                       // high latency
		fill_line(25'h0000100);
		rd_lat = 4;
		busy_pattern = 1;                  // waitrequest stutter
		fill_line(25'h0000140);
		fill_line(25'h0000150);
		busy_pattern = 0;
		m1_on = 1;                         // a2065 contention
		repeat (20) @(posedge clk);
		fill_line(25'h0000180);
		walker_read(27'h0000A00);
		fill_line(25'h00001C0);
		cpu_read(28'h000200);
		fill_line(25'h0000200);
		rd_lat = 8; busy_pattern = 1;      // everything at once
		fill_line(25'h0000240);
		walker_read(27'h0000A40);
		fill_line(25'h0000280);
		cpu_read(28'h000280);
		fill_line(25'h00002C0);
		busy_pattern = 0; rd_lat = 4; m1_on = 0;
		$display("  fill latency over the phase: min %0d max %0d clk28 cycles",
		         fill_cyc_min, fill_cyc_max);

		// a lost response: the controller abandons the fill by its
		// read-wait watchdog, the bridge-side watchdog reports the
		// error, and the next fill and walker read are served correctly
		drop_next = 1;
		fill_line_berr(25'h0000300);
		fill_line(25'h0000300);
		walker_read(27'h0000C00);
		fill_line(25'h0000340);

		if (errors == 0) $display("ALL TESTS PASSED");
		else $display("TEST FAILED with %0d errors", errors);
		$finish;
	end

	// global watchdog: a walker hang would otherwise spin to $finish never
	initial begin
		#20_000_000;
		$display("FAIL: global timeout -- walker never completed");
		$finish;
	end

endmodule
