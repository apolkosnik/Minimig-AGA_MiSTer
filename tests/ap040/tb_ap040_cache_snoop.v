// tb_ap040_cache_snoop.v -- directed bench for ap040_cache's snoop and
// port-B arbitration paths (audit findings 5.1-5.3).  These are exactly
// the paths with no other coverage: every other bench ties s_stb low.
//
// The bench drives the cache DIRECTLY: a flat memory model with a fixed
// read latency sits on the m_* side, the c_* side is exercised with
// read/write tasks, ce can be held low for chosen windows, and snoops
// are single-clk pulses INDEPENDENT of ce -- the shape cpu_wrapper's
// snoop CDC actually delivers.
//
//   T1 (5.1)  a snoop landing in a ce-frozen window must still
//             invalidate: the following read of changed memory must
//             miss and refetch.
//   T2 (5.2a) a snoop hitting the set of an in-flight fill must not be
//             undone by the fill's tag writeback, and the snooped way
//             must not be revalidated with stale data.  Swept across
//             the whole fill window.
//   T3 (5.2c) a snoop in the same cycle a lookup is accepted must not
//             let that lookup serve the killed line.  Swept.
//   T4 (5.3)  a snoop displacing a line-crossing store's invalidates
//             must not lose either set.  Swept.
//   T5 (5.4)  a bus error during a line fill (or a passed access) must
//             abandon the transfer instead of re-issuing it forever,
//             must not validate the partly-filled line, and must leave
//             the cache able to serve the exception handler's own
//             accesses.  The error is swept across all four beats.
//
// Every test reprograms memory behind the cache and requires the next
// read to return the NEW value: a stale cached longword is the failure
// signature throughout.

`timescale 1ns/1ps

module tb_ap040_cache_snoop;

reg clk = 0;
always #5 clk = ~clk;

reg nreset = 0;
reg ce_run = 1;          // when 0, ce is forced low (frozen window)
wire ce = ce_run;

reg         cinv_req = 0;
reg         cinv_ic = 0, cinv_dc = 0;
wire        cinv_done;

reg         c_req = 0, c_write = 0, c_instr = 0, c_nocache = 0;
reg  [1:0]  c_size = 0;
reg  [31:0] c_addr = 0, c_wdata = 0;
wire        c_ack;
wire [31:0] c_rdata;

wire        m_req, m_write, m_instr;
wire  [1:0] m_size;
wire [31:0] m_addr, m_wdata;
reg         m_ack = 0;
reg  [31:0] m_rdata = 0;
reg         m_err = 0;

reg         s_stb = 0;
reg  [31:0] s_addr = 0;

ap040_cache dut
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.ie(1'b1), .de(1'b1),
	.cinv_req(cinv_req), .cinv_ic(cinv_ic), .cinv_dc(cinv_dc),
	.cinv_done(cinv_done),
	.c_req(c_req), .c_write(c_write), .c_instr(c_instr),
	.c_size(c_size), .c_addr(c_addr), .c_wdata(c_wdata),
	.c_fc(3'd5), .c_nocache(c_nocache),
	.c_ack(c_ack), .c_rdata(c_rdata),
	.m_req(m_req), .m_write(m_write), .m_instr(m_instr),
	.m_size(m_size), .m_addr(m_addr), .m_wdata(m_wdata),
	.m_fc(), .m_ack(m_ack), .m_rdata(m_rdata), .m_err(m_err),
	.s_stb(s_stb), .s_addr(s_addr)
);

integer errors = 0;

//---------------------------------------------------------------------------
// flat memory with a 2-cycle grant: enough latency that fill beats and
// their ack cycles are deterministic for the sweep offsets below
//---------------------------------------------------------------------------
reg [31:0] mem [0:16383];   // 64KB
reg  [1:0] mlat = 0;

// Fault injection: while err_arm is set, an access whose address matches
// err_addr (line-aligned, beat selected by err_beat) reports a bus error
// the way ap040_bus16_adapter does -- m_err for one qualified cycle and
// NO m_ack, ever, for that transfer.
reg         err_arm = 0;
reg  [31:0] err_addr = 0;
reg  [1:0]  err_beat = 0;
integer     err_count = 0;
wire        err_hit = err_arm && m_req &&
                      (m_addr[31:4] == err_addr[31:4]) &&
                      (m_addr[3:2] == err_beat);

always @(posedge clk) begin
	m_ack <= 0;
	m_err <= 0;
	if (m_req && ce) begin
		if (mlat != 2'd2) mlat <= mlat + 1'd1;
		else begin
			mlat <= 0;
			if (err_hit) begin
				m_err <= 1;
				err_count = err_count + 1;
			end
			else begin
				m_ack <= 1;
				if (m_write) begin
					// longword stores only in this bench
					mem[m_addr[15:2]] <= m_wdata;
				end
				else m_rdata <= mem[m_addr[15:2]];
			end
		end
	end
	else mlat <= 0;
end

//---------------------------------------------------------------------------
// helpers
//---------------------------------------------------------------------------
task cpu_read;
	input  [31:0] a;
	output [31:0] d;
	integer guard;
	begin
		@(negedge clk);
		c_req = 1; c_write = 0; c_size = 2'b10; c_addr = a;
		guard = 0;
		while (!(c_ack && ce) && guard < 200) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (guard >= 200) begin
			$display("FAIL: read timeout at %h", a);
			errors = errors + 1;
		end
		d = c_rdata;
		@(negedge clk);
		c_req = 0;
		@(posedge clk);
	end
endtask

task cpu_write;
	input [31:0] a;
	input [31:0] d;
	integer guard;
	begin
		@(negedge clk);
		c_req = 1; c_write = 1; c_size = 2'b10; c_addr = a; c_wdata = d;
		guard = 0;
		while (!(c_ack && ce) && guard < 200) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (guard >= 200) begin
			$display("FAIL: write timeout at %h", a);
			errors = errors + 1;
		end
		@(negedge clk);
		c_req = 0; c_write = 0;
		@(posedge clk);
	end
endtask

// A faulting access, driven the way the core drives one: c_req is held
// until the bus error is seen (the core samples berr on the same
// qualified edge), then dropped as the core enters exception processing.
// Returns with the cache expected to be idle again.
task cpu_access_berr;
	input [31:0] a;
	input        wr;
	integer guard;
	begin
		@(negedge clk);
		c_req = 1; c_write = wr; c_size = 2'b10; c_addr = a;
		c_wdata = 32'hBADD_0BAD;
		guard = 0;
		while (!(m_err && ce) && guard < 300) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (guard >= 300) begin
			$display("FAIL: no bus error reported for %h", a);
			errors = errors + 1;
		end
		@(negedge clk);
		c_req = 0; c_write = 0;
		@(posedge clk);
	end
endtask

// After a fault the cache must stop driving the bus: no master request
// may survive more than a couple of cycles once the core has withdrawn.
task expect_bus_idle;
	input integer tno;
	integer guard;
	begin
		guard = 0;
		while (m_req && guard < 40) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (m_req) begin
			$display("FAIL test %0d: cache still driving m_req after a bus error (livelock)",
			         tno);
			errors = errors + 1;
		end
	end
endtask

task snoop;   // one free-running clk pulse, regardless of ce
	input [31:0] a;
	begin
		@(negedge clk);
		s_stb = 1; s_addr = a;
		@(negedge clk);
		s_stb = 0;
	end
endtask

task expect_read;
	input [31:0] a;
	input [31:0] v;
	input integer tno;
	reg [31:0] d;
	begin
		cpu_read(a, d);
		if (d !== v) begin
			$display("FAIL test %0d: read %h got %h expected %h",
			         tno, a, d, v);
			errors = errors + 1;
		end
	end
endtask

integer i, off;
integer guard5;
reg [31:0] d;

initial begin
	for (i = 0; i < 16384; i = i + 1) mem[i] = 32'h1111_0000 + i;
	repeat (4) @(negedge clk);
	nreset = 1;
	// let the reset sweep finish
	repeat (200) @(posedge clk);

	//------------------------------------------------------------------
	// T1 (5.1): snoop during a frozen ce window
	//------------------------------------------------------------------
	expect_read(32'h0000_1000, mem[32'h1000>>2], 1);  // warm the line
	mem[32'h1000>>2] = 32'hAAAA_0001;                 // DMA changes memory
	ce_run = 0;                                       // clkena frozen
	repeat (3) @(negedge clk);
	snoop(32'h0000_1000);                             // arrives mid-freeze
	repeat (3) @(negedge clk);
	ce_run = 1;
	expect_read(32'h0000_1000, 32'hAAAA_0001, 1);     // must refetch

	//------------------------------------------------------------------
	// T2 (5.2a): snoop the set of an in-flight fill, swept across the
	// whole fill.  Line X (way already valid) is the snoop's target;
	// line Y (same set) is being filled.
	//------------------------------------------------------------------
	for (off = 0; off < 24; off = off + 1) begin
		cinv_req = 1; cinv_ic = 1; cinv_dc = 1;
		@(negedge clk);
		while (!cinv_done) @(posedge clk);
		cinv_req = 0;
		@(negedge clk);

		expect_read(32'h0000_2000, mem[32'h2000>>2], 2);  // X valid
		mem[32'h2000>>2] = 32'hBBBB_0000 + off;           // X changes in memory

		// start the fill of Y and snoop X's set mid-flight
		fork
			expect_read(32'h0000_3000, mem[32'h3000>>2], 2);  // Y: same set
			begin
				repeat (off + 1) @(negedge clk);
				snoop(32'h0000_2000);
			end
		join

		expect_read(32'h0000_2000, 32'hBBBB_0000 + off, 2);   // X must refetch
	end

	//------------------------------------------------------------------
	// T3 (5.2c): snoop in the acceptance cycle of a would-be hit, swept.
	// The concurrent read may legally serve either value (the snoop is
	// unordered against it); the assertion is that the snoop's
	// invalidate survives the collision: the NEXT read must refetch.
	// (The silicon-only half of 5.2c -- mixed-port DONT_CARE producing
	// garbage tags and a false hit on a wrong way -- is not observable
	// under iverilog's deterministic old-data model; the force-miss fix
	// covers it by construction.)
	//------------------------------------------------------------------
	for (off = 0; off < 6; off = off + 1) begin
		expect_read(32'h0000_4000, mem[32'h4000>>2], 3);  // warm
		mem[32'h4000>>2] = 32'hCCCC_0000 + off;
		fork
			cpu_read(32'h0000_4000, d);   // either value is legal here
			begin
				repeat (off) @(negedge clk);
				snoop(32'h0000_4000);
			end
		join
		expect_read(32'h0000_4000, 32'hCCCC_0000 + off, 3);
	end

	//------------------------------------------------------------------
	// T4 (5.3): a line-crossing store's two set invalidates vs a snoop,
	// swept across the acceptance/pass window
	//------------------------------------------------------------------
	for (off = 0; off < 8; off = off + 1) begin
		expect_read(32'h0000_5008, mem[32'h5008>>2], 4);  // set A line
		expect_read(32'h0000_5010, mem[32'h5010>>2], 4);  // set B line
		// the store crosses from set A's line into set B's
		fork
			begin
				@(negedge clk);
				c_req = 1; c_write = 1; c_size = 2'b10;
				c_addr = 32'h0000_500E; c_wdata = 32'hDD00_0000 + off;
				while (!(c_ack && ce)) @(posedge clk);
				@(negedge clk);
				c_req = 0; c_write = 0;
				@(posedge clk);
			end
			begin
				repeat (off) @(negedge clk);
				snoop(32'h0000_5300);   // unrelated address, same bank
			end
		join
		// both lines the store touched must have been invalidated:
		// change them in memory and require refetches
		mem[32'h5008>>2] = 32'hEEEE_0000 + off;
		mem[32'h5010>>2] = 32'hFFFF_0000 + off;
		expect_read(32'h0000_5008, 32'hEEEE_0000 + off, 4);
		expect_read(32'h0000_5010, 32'hFFFF_0000 + off, 4);
	end

	//------------------------------------------------------------------
	// T5 (5.4): bus error during a fill, swept across the beats.  The
	// faulting line must be abandoned (no re-issue, no validation), and
	// the cache must keep serving -- an exception handler runs next.
	//------------------------------------------------------------------
	for (off = 0; off < 4; off = off + 1) begin
		// level-held request, exactly as the core drives it: the FSM
		// takes it when it next reaches C_IDLE, and a cache wedged by a
		// mishandled bus error simply never gets there
		cinv_req = 1; cinv_ic = 1; cinv_dc = 1;
		@(negedge clk);
		guard5 = 0;
		while (!cinv_done && guard5 < 4000) begin
			@(posedge clk);
			guard5 = guard5 + 1;
		end
		cinv_req = 0;
		if (guard5 >= 4000) begin
			$display("FAIL test 5: cache wedged after a bus error (beat %0d): CINV never completes",
			         off);
			errors = errors + 1;
			off = 4;   // no point sweeping a wedged cache
		end
		repeat (200) @(posedge clk);

		err_arm = 1;
		err_addr = 32'h0000_6000;
		err_beat = off[1:0];
		err_count = 0;
		cpu_access_berr(32'h0000_6004, 1'b0);
		err_arm = 0;
		expect_bus_idle(5);
		if (err_count > 2) begin
			$display("FAIL test 5: faulting fill re-issued %0d times (beat %0d)",
			         err_count, off);
			errors = errors + 1;
		end

		// the handler's own accesses must work, and the abandoned line
		// must NOT have been validated: memory changes underneath it
		// and the refetch has to see the new contents
		mem[32'h6004>>2] = 32'h5EED_0000 + off;
		mem[32'h6008>>2] = 32'h5EED_1000 + off;
		expect_read(32'h0000_7000, mem[32'h7000>>2], 5);
		expect_read(32'h0000_6004, 32'h5EED_0000 + off, 5);
		expect_read(32'h0000_6008, 32'h5EED_1000 + off, 5);
	end

	// T5b: the same for a passed (write-through) access -- the store
	// faults, the cache must release the bus and stay usable
	err_arm = 1;
	err_addr = 32'h0000_6800;
	err_beat = 2'd0;
	err_count = 0;
	cpu_access_berr(32'h0000_6800, 1'b1);
	err_arm = 0;
	expect_bus_idle(5);
	expect_read(32'h0000_7100, mem[32'h7100>>2], 5);

	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end

initial begin
	#4000000;
	$display("FAIL: global timeout");
	$finish;
end

endmodule
