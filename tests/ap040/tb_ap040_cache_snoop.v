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
//   T10 (X3.2) a store that hits a resident data line updates it in
//             place: the read after it returns the stored value with NO
//             bus read (the bench counts memory reads), byte and word
//             lanes merge, a store to a non-resident line does not
//             allocate, a misaligned store still invalidates, and a
//             snoop swept across the store window leaves the value
//             readable and a later DMA write visible.
//
// Every test reprograms memory behind the cache and requires the next
// read to return the NEW value: a stale cached longword is the failure
// signature throughout (T10 adds the opposite direction: a value that
// must be served WITHOUT going to memory).

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
reg  [1:0]  mem_lat = 2'd2;   // cycles before m_ack; 0 models a
                              // downstream controller-cache HIT, which is
                              // how fast this port can really answer
reg         m_ack = 0;
reg  [31:0] m_rdata = 0;
reg         m_err = 0;

reg         s_stb = 0;
reg  [31:0] s_addr = 0;

// POST=0 is the negative control for T11: every store synchronous,
// which must FAIL the posted-store checks.
parameter   POST = 1;
wire        post_busy, post_err;

reg         snoop_storm = 0;
reg         s_stb_storm = 0;
// free-running chipset snoop traffic on its own driver: port B is taken
// every other cycle, which is what blitter/copper/display DMA looks like
// to this cache.  ORed into the DUT input so the snoop task keeps its own.
always @(negedge clk) begin
	if (snoop_storm) s_stb_storm <= ~s_stb_storm;
	else             s_stb_storm <= 1'b0;
end

ap040_cache #(.POST_STORES(POST)) dut
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.post_busy(post_busy), .post_err(post_err),
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
	.s_stb(s_stb | s_stb_storm), .s_addr(s_stb_storm ? 32'h0000_C300 : s_addr)
);

integer errors = 0;

//---------------------------------------------------------------------------
// flat memory with a 2-cycle grant: enough latency that fill beats and
// their ack cycles are deterministic for the sweep offsets below
//---------------------------------------------------------------------------
reg [31:0] mem [0:16383];   // 64KB
reg  [1:0] mlat = 0;
integer    m_read_count = 0; // memory reads served: a hit issues none
// bus order: every acknowledged transfer takes the next sequence number,
// so "the read reached memory after the store" is a comparison
integer    bus_seq = 0;
integer    last_wr_seq = -1;
integer    last_rd_seq = -1;
reg        post_err_seen = 0;
always @(posedge clk) if (post_err) post_err_seen = 1;

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
		if (mlat != mem_lat) mlat <= mlat + 1'd1;
		else begin
			mlat <= 0;
			if (err_hit) begin
				m_err <= 1;
				err_count = err_count + 1;
			end
			else begin
				m_ack <= 1;
				if (m_write) begin
					// big-endian lanes, the adapter's view of a store
					case (m_size)
						2'd0: case (m_addr[1:0])
							2'd0: mem[m_addr[15:2]][31:24] <= m_wdata[7:0];
							2'd1: mem[m_addr[15:2]][23:16] <= m_wdata[7:0];
							2'd2: mem[m_addr[15:2]][15:8]  <= m_wdata[7:0];
							default: mem[m_addr[15:2]][7:0] <= m_wdata[7:0];
						endcase
						2'd1: if (m_addr[1]) mem[m_addr[15:2]][15:0]  <= m_wdata[15:0];
						      else           mem[m_addr[15:2]][31:16] <= m_wdata[15:0];
						default: mem[m_addr[15:2]] <= m_wdata;
					endcase
					last_wr_seq = bus_seq;
					bus_seq = bus_seq + 1;
				end
				else begin
					m_rdata <= mem[m_addr[15:2]];
					m_read_count = m_read_count + 1;
					last_rd_seq = bus_seq;
					bus_seq = bus_seq + 1;
				end
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

// Two reads with NO request-low cycle between them.  cpu_read above
// drops c_req and idles a cycle after each access, which lets a pending
// CI invalidate land before the next request is looked up -- so it can
// never expose an FSM that accepts while the invalidate is still owed.
task cpu_read_btb;
	input  [31:0] a1;
	input         ci1;
	input  [31:0] a2;
	output [31:0] o1;
	output [31:0] o2;
	integer guard;
	begin
		@(negedge clk);
		c_req = 1; c_write = 0; c_size = 2'b10; c_addr = a1; c_nocache = ci1;
		guard = 0;
		while (!(c_ack && ce) && guard < 200) begin
			@(posedge clk); guard = guard + 1;
		end
		if (guard >= 200) begin
			$display("FAIL: btb first read timeout at %h", a1);
			errors = errors + 1;
		end
		o1 = c_rdata;
		// present the next access immediately: c_req never falls
		@(negedge clk);
		c_addr = a2; c_nocache = 0;
		@(posedge clk);
		guard = 0;
		while (!(c_ack && ce) && guard < 200) begin
			@(posedge clk); guard = guard + 1;
		end
		if (guard >= 200) begin
			$display("FAIL: btb second read timeout at %h", a2);
			errors = errors + 1;
		end
		o2 = c_rdata;
		@(negedge clk);
		c_req = 0;
		@(posedge clk);
	end
endtask

// A cache-inhibited read that HITS, immediately followed by a WRITE.
// store_inv asserts combinationally while a write waits in C_IDLE and it
// blocks ci_inv; if the FSM also refuses to accept while ci_inv_pend is
// set, the write and the invalidate block each other forever.
task cpu_ci_read_then_write;
	input [31:0] a;
	input [31:0] wa;
	integer guard;
	begin
		@(negedge clk);
		c_req = 1; c_write = 0; c_size = 2'b10; c_addr = a; c_nocache = 1;
		guard = 0;
		while (!(c_ack && ce) && guard < 200) begin
			@(posedge clk); guard = guard + 1;
		end
		if (guard >= 200) begin
			$display("FAIL: CI read never completed");
			errors = errors + 1;
		end
		// present the store with no idle gap
		@(negedge clk);
		c_nocache = 0; c_write = 1; c_addr = wa; c_wdata = 32'hDEAD_5170;
		guard = 0;
		while (!(c_ack && ce) && guard < 300) begin
			@(posedge clk); guard = guard + 1;
		end
		if (guard >= 300) begin
			$display("FAIL: DEADLOCK -- store after a cache-inhibited hit never completed");
			errors = errors + 1;
		end
		@(negedge clk);
		c_req = 0; c_write = 0;
		repeat (3) @(posedge clk);
	end
endtask

// A store of the given size (0 byte, 1 word, 2 long), data right-aligned
// the way the core presents it.
task cpu_write_sz;
	input [31:0] a;
	input [31:0] d;
	input  [1:0] sz;
	integer guard;
	begin
		@(negedge clk);
		c_req = 1; c_write = 1; c_size = sz; c_addr = a; c_wdata = d;
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
		c_req = 0; c_write = 0; c_size = 2'b10;
		@(posedge clk);
	end
endtask

// A store that also reports whether the cache acknowledged it BEFORE
// memory did: the posted-store signature.  Both acknowledges are sampled
// with the same one-cycle skew, so a synchronous store (c_ack forwarded
// from m_ack) reports 0 and a posted one reports 1.
task cpu_write_watch;
	input  [31:0] a;
	input  [31:0] d;
	input   [1:0] sz;
	output        ack_first;
	integer guard;
	reg macked;
	begin
		@(negedge clk);
		c_req = 1; c_write = 1; c_size = sz; c_addr = a; c_wdata = d;
		guard = 0; macked = 0;
		while (!(c_ack && ce) && guard < 200) begin
			@(posedge clk);
			guard = guard + 1;
			if (m_ack) macked = 1;
		end
		if (guard >= 200) begin
			$display("FAIL: watched write timeout at %h", a);
			errors = errors + 1;
		end
		ack_first = !macked && !m_ack;
		@(negedge clk);
		c_req = 0; c_write = 0; c_size = 2'b10;
		@(posedge clk);
	end
endtask

// Wait until a posted store has reached memory.  A test that inspects
// memory behind a store, or changes memory "underneath" it, must call
// this first: the acknowledge no longer means the write has landed.
task drain;
	integer guard;
	begin
		guard = 0;
		while (post_busy && guard < 300) begin
			@(posedge clk); guard = guard + 1;
		end
		if (post_busy) begin
			$display("FAIL: posted store never drained");
			errors = errors + 1;
		end
		repeat (2) @(posedge clk);
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
integer rd0;
reg     ackfirst;
reg [31:0] d;
reg [31:0] d2;

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

	//------------------------------------------------------------------
	// T6 (5.4b): an aborted fill must not leave the line it was EVICTING
	// hitting over the dead fill's data.  T5 above cannot see this: it
	// invalidates the whole cache first, so the victim way is empty and
	// the abandoned beats really are unreachable.  Here the row is fully
	// populated first, exactly as it is in a running system, so the
	// refill's beats land on top of a live line whose tag and valid bit
	// survive the abort.  In NetBSD terms: a user miss bus-errors
	// mid-fill and the next supervisor hit on that row is served kernel
	// tag over user data -- the tc_windup panic, where the timehands
	// pointer came back as a user address.
	// row = addr[9:4], so these five addresses share one row and the
	// fifth fill must evict one of the four primed ways.
	expect_read(32'h0000_8000, mem[32'h8000>>2], 6);
	expect_read(32'h0000_8400, mem[32'h8400>>2], 6);
	expect_read(32'h0000_8800, mem[32'h8800>>2], 6);
	expect_read(32'h0000_8C00, mem[32'h8C00>>2], 6);

	err_arm = 1;
	err_addr = 32'h0000_9000;
	err_beat = 2'd2;          // beats 0 and 1 land before the error
	err_count = 0;
	cpu_access_berr(32'h0000_9000, 1'b0);
	err_arm = 0;
	expect_bus_idle(6);

	// every primed line must still read its OWN data (or miss and refetch
	// it); none may be served the aborted fill's beats
	expect_read(32'h0000_8000, mem[32'h8000>>2], 6);
	expect_read(32'h0000_8004, mem[32'h8004>>2], 6);
	expect_read(32'h0000_8400, mem[32'h8400>>2], 6);
	expect_read(32'h0000_8404, mem[32'h8404>>2], 6);
	expect_read(32'h0000_8800, mem[32'h8800>>2], 6);
	expect_read(32'h0000_8804, mem[32'h8804>>2], 6);
	expect_read(32'h0000_8C00, mem[32'h8C00>>2], 6);
	expect_read(32'h0000_8C04, mem[32'h8C04>>2], 6);

	//------------------------------------------------------------------
	// T7: a cache-inhibited read that HITS a resident line must
	// invalidate it as it bypasses (WinUAE dcache040: hit under
	// CACHE_DISABLE_MMU -> push+invalidate, then the uncached access).
	// Retaining the line let PRE-DMA data hit again once the mapping
	// turned cacheable -- the value below comes back A instead of C on
	// the old cache, with no bus request.
	//------------------------------------------------------------------
	expect_read(32'h0000_A000, mem[32'hA000>>2], 7);  // prime: value A
	mem[32'hA000>>2] = 32'hD11A_0002;                 // DMA writes B
	c_nocache = 1;
	expect_read(32'h0000_A000, 32'hD11A_0002, 7);     // CI read: memory B,
	c_nocache = 0;                                    // and the line dies
	mem[32'hA000>>2] = 32'hD11A_0003;                 // DMA writes C
	expect_read(32'h0000_A000, 32'hD11A_0003, 7);     // must MISS: value C

	//------------------------------------------------------------------
	// T8: back-to-back CI-then-cacheable reads with NO request-low cycle,
	// under a port-B stealing snoop swept across the completion.
	//
	// This does NOT currently discriminate: it passes whether or not the
	// FSM holds acceptance while a CI invalidate is owed, because
	// ci_inv_pend is raised on the first cycle of C_PASS and the access
	// runs to m_ack, so the invalidate always lands during the memory
	// latency.  It is kept because it is the only coverage of the no-gap
	// request path, and it would catch a future change that raised the
	// pending invalidate later (at completion rather than at lookup),
	// which is exactly when the window would become real.
	//------------------------------------------------------------------
	// A snoop must be stealing port B as the CI access completes,
	// otherwise the invalidate lands in the very cycle the FSM returns
	// to C_IDLE and the window never opens.  Sweep the snoop across the
	// completion so at least one offset collides.
	for (off = 0; off < 8; off = off + 1) begin
		cinv_req = 1; cinv_ic = 1; cinv_dc = 1;
		@(negedge clk);
		guard5 = 0;
		while (!cinv_done && guard5 < 4000) begin
			@(posedge clk); guard5 = guard5 + 1;
		end
		cinv_req = 0;
		repeat (20) @(posedge clk);

		mem[32'hB000>>2] = 32'hB77B_0000 + off;
		expect_read(32'h0000_B000, mem[32'hB000>>2], 8);   // prime
		mem[32'hB000>>2] = 32'hB77B_0080 + off;            // DMA changes it
		fork
			cpu_read_btb(32'h0000_B000, 1'b1, 32'h0000_B000, d, d2);
			begin
				repeat (off) @(negedge clk);
				snoop(32'h0000_C300);   // unrelated row, steals port B
			end
		join
		if (d2 !== 32'hB77B_0080 + off) begin
			$display("FAIL test 8 (snoop offset %0d): back-to-back cacheable read got %h (stale line) expected %h",
			         off, d2, 32'hB77B_0080 + off);
			errors = errors + 1;
			off = 8;
		end
	end
	d = 32'hB77B_0080;   // silence the unused-check below
	d2 = 32'hB77B_0080;

	//------------------------------------------------------------------
	// T9: a store issued right after a cache-inhibited HIT must complete.
	// The CI hit owes a row invalidate; a waiting store asserts store_inv
	// combinationally, which blocks that invalidate.  If acceptance is
	// also held while the invalidate is owed, the two block each other
	// and the CPU wedges -- programs hang or loop forever.
	//------------------------------------------------------------------
	// Chipset DMA snoops CONSTANTLY on a real Amiga (blitter, copper,
	// display), and a snoop owns port B whenever it fires -- so the CI
	// invalidate cannot land during the bypassed access the way it does
	// in a quiet bench.  Drive that traffic while the pair runs.
	// Run it at BOTH memory speeds.  With three cycles of latency the
	// invalidate always lands during C_PASS and the hazard is invisible;
	// a downstream cache hit answers in one, which is when the CI
	// invalidate is still owed as the store arrives.
	expect_read(32'h0000_D000, mem[32'hD000>>2], 9);   // prime the line
	snoop_storm = 1;
	cpu_ci_read_then_write(32'h0000_D000, 32'h0000_D400);
	snoop_storm = 0;
	repeat (6) @(posedge clk);

	mem_lat = 2'd0;                                    // controller-cache hit
	expect_read(32'h0000_D800, mem[32'hD800>>2], 9);   // prime
	snoop_storm = 1;
	cpu_ci_read_then_write(32'h0000_D800, 32'h0000_DC00);
	snoop_storm = 0;
	mem_lat = 2'd2;
	repeat (6) @(posedge clk);

	//------------------------------------------------------------------
	// T10 (plan X3.2): a store that HITS a resident data line updates
	// the line in place.  Write-through, no write-allocate -- but no
	// eviction either: MC68040UM section 7, a write hit updates the
	// cache line and always goes to memory.  The old cache cleared the
	// whole row on every store, so each store to cached data cost the
	// next load a full refill.
	//
	// The read after the store returns the stored value under BOTH
	// models (write-through keeps memory right); what discriminates is
	// that it must issue NO bus read.  The bench counts memory reads.
	// On the pre-change cache the row was invalidated and the read
	// refills: FAIL.
	//
	// Swept over both memory speeds: with the controller-hit latency
	// the memory acknowledge lands in the cycle the merge is decided.
	//------------------------------------------------------------------
	for (off = 0; off < 2; off = off + 1) begin
		mem_lat = off[0] ? 2'd0 : 2'd2;
		cinv_req = 1; cinv_ic = 1; cinv_dc = 1;
		@(negedge clk);
		while (!cinv_done) @(posedge clk);
		cinv_req = 0;
		repeat (20) @(posedge clk);

		// long store into a resident line
		expect_read(32'h0000_E000, mem[32'hE000>>2], 10);
		cpu_write_sz(32'h0000_E004, 32'hCAFE_1234, 2'd2);
		drain;
		if (mem[32'hE004>>2] !== 32'hCAFE_1234) begin
			$display("FAIL test 10 (lat %0d): write-through lost the store, memory holds %h",
			         mem_lat, mem[32'hE004>>2]);
			errors = errors + 1;
		end
		rd0 = m_read_count;
		expect_read(32'h0000_E004, 32'hCAFE_1234, 10);
		if (m_read_count != rd0) begin
			$display("FAIL test 10 (lat %0d): long store evicted its line -- the read after it refilled (%0d bus reads)",
			         mem_lat, m_read_count - rd0);
			errors = errors + 1;
		end

		// byte lane 1 and the low word: the merge must keep the other
		// lanes.  Memory is the reference -- the adapter model merges
		// lanes the same way the real bus does.
		cpu_write_sz(32'h0000_E009, 32'h0000_00A5, 2'd0);
		drain;
		rd0 = m_read_count;
		expect_read(32'h0000_E008, mem[32'hE008>>2], 10);
		if (m_read_count != rd0) begin
			$display("FAIL test 10 (lat %0d): byte store evicted its line", mem_lat);
			errors = errors + 1;
		end
		cpu_write_sz(32'h0000_E00A, 32'h0000_BEEF, 2'd1);
		drain;
		rd0 = m_read_count;
		expect_read(32'h0000_E008, mem[32'hE008>>2], 10);
		if (m_read_count != rd0) begin
			$display("FAIL test 10 (lat %0d): word store evicted its line", mem_lat);
			errors = errors + 1;
		end
		if (mem[32'hE008>>2][23:16] !== 8'hA5 || mem[32'hE008>>2][15:0] !== 16'hBEEF) begin
			$display("FAIL test 10 (lat %0d): lane merge reference wrong: memory %h",
			         mem_lat, mem[32'hE008>>2]);
			errors = errors + 1;
		end

		// no write-allocate: a store to a line that is NOT resident must
		// not bring it in, so the read after it is a genuine refill
		cpu_write_sz(32'h0000_E404, 32'h0E40_0000 + off, 2'd2);
		rd0 = m_read_count;
		expect_read(32'h0000_E404, 32'h0E40_0000 + off, 10);
		if (m_read_count == rd0) begin
			$display("FAIL test 10 (lat %0d): store to a non-resident line allocated it", mem_lat);
			errors = errors + 1;
		end

		// a misaligned store keeps the invalidate path: the line it
		// touches must be gone (memory changes underneath, refetch)
		expect_read(32'h0000_E800, mem[32'hE800>>2], 10);
		cpu_write_sz(32'h0000_E802, 32'h5A5A_A5A5, 2'd2);   // long at +2
		drain;
		mem[32'hE800>>2] = 32'h0E80_0000 + off;
		mem[32'hE804>>2] = 32'h0E84_0000 + off;
		expect_read(32'h0000_E800, 32'h0E80_0000 + off, 10);
		expect_read(32'h0000_E804, 32'h0E84_0000 + off, 10);
	end
	mem_lat = 2'd2;

	// T10b: a snoop swept across the store's acceptance and merge
	// window, first on ANOTHER line of the same row (port B writes the
	// row the lookup is reading), then on the store's own line.  The
	// stored value must read back either way, and a DMA write that
	// follows, announced by its snoop, must be visible.
	for (off = 0; off < 10; off = off + 1) begin
		expect_read(32'h0000_F000, mem[32'hF000>>2], 10);
		expect_read(32'h0000_F400, mem[32'hF400>>2], 10);   // same row
		fork
			cpu_write_sz(32'h0000_F004, 32'hF0F0_0000 + off, 2'd2);
			begin
				repeat (off) @(negedge clk);
				snoop(off[0] ? 32'h0000_F000 : 32'h0000_F400);
			end
		join
		expect_read(32'h0000_F004, 32'hF0F0_0000 + off, 10);
		expect_read(32'h0000_F400, mem[32'hF400>>2], 10);
		drain;
		mem[32'hF004>>2] = 32'hD3A0_0000 + off;
		snoop(32'h0000_F000);
		expect_read(32'h0000_F004, 32'hD3A0_0000 + off, 10);
	end

	// T10c: the same store under constant chipset traffic, both speeds
	snoop_storm = 1;
	expect_read(32'h0000_F800, mem[32'hF800>>2], 10);
	cpu_write_sz(32'h0000_F808, 32'hF8F8_F8F8, 2'd2);
	expect_read(32'h0000_F808, 32'hF8F8_F8F8, 10);
	mem_lat = 2'd0;
	cpu_write_sz(32'h0000_F80C, 32'hF80C_F80C, 2'd2);
	expect_read(32'h0000_F80C, 32'hF80C_F80C, 10);
	snoop_storm = 0;
	mem_lat = 2'd2;
	repeat (6) @(posedge clk);

	//------------------------------------------------------------------
	// T11 (plan X3.3, A2b-1): a store to a cacheable page is
	// acknowledged before memory has taken it and drains from a latched
	// copy.  POST=0 (the bench parameter) is the negative control: every
	// store synchronous, and T11a must fail.
	//------------------------------------------------------------------
	// T11a: early acknowledge, then the drain lands the value -- at both
	// memory speeds
	for (off = 0; off < 2; off = off + 1) begin
		mem_lat = off[0] ? 2'd0 : 2'd2;
		cpu_write_watch(32'h0000_1F00, 32'h11A0_0000 + off, 2'd2, ackfirst);
		if (!ackfirst) begin
			$display("FAIL test 11 (lat %0d): store was not acknowledged before memory took it (not posted)",
			         mem_lat);
			errors = errors + 1;
		end
		guard5 = 0;
		while (post_busy && guard5 < 300) begin
			@(posedge clk); guard5 = guard5 + 1;
		end
		if (post_busy) begin
			$display("FAIL test 11 (lat %0d): posted store never drained", mem_lat);
			errors = errors + 1;
		end
		if (mem[32'h1F00>>2] !== 32'h11A0_0000 + off) begin
			$display("FAIL test 11 (lat %0d): drained value %h expected %h",
			         mem_lat, mem[32'h1F00>>2], 32'h11A0_0000 + off);
			errors = errors + 1;
		end
	end
	mem_lat = 2'd2;

	// T11b: ordering.  A read presented right behind a posted store to
	// a different, non-resident line must reach memory AFTER the store.
	cpu_write_sz(32'h0000_1F40, 32'h11B0_1F40, 2'd2);
	expect_read(32'h0000_1F80, mem[32'h1F80>>2], 11);
	if (!(last_wr_seq >= 0 && last_rd_seq > last_wr_seq)) begin
		$display("FAIL test 11: a read overtook the posted store on the bus (wr seq %0d, rd seq %0d)",
		         last_wr_seq, last_rd_seq);
		errors = errors + 1;
	end
	if (mem[32'h1F40>>2] !== 32'h11B0_1F40) begin
		$display("FAIL test 11: posted store lost: memory %h", mem[32'h1F40>>2]);
		errors = errors + 1;
	end

	// T11c: read after write to the SAME word of a resident line: the
	// merged line serves it once the drain is over, with no bus read
	expect_read(32'h0000_1FC0, mem[32'h1FC0>>2], 11);
	cpu_write_sz(32'h0000_1FC4, 32'h11C0_1FC4, 2'd2);
	rd0 = m_read_count;
	expect_read(32'h0000_1FC4, 32'h11C0_1FC4, 11);
	if (m_read_count != rd0) begin
		$display("FAIL test 11: read after a posted store to a resident line refilled it");
		errors = errors + 1;
	end

	// T11d: a cache-inhibited store is NOT posted: IO writes complete
	// before the next instruction, as they must
	c_nocache = 1;
	cpu_write_watch(32'h0000_1E00, 32'h11D0_1E00, 2'd2, ackfirst);
	c_nocache = 0;
	if (ackfirst) begin
		$display("FAIL test 11: cache-inhibited store was posted");
		errors = errors + 1;
	end

	// T11e: a bus error on the drain arrives after the core was
	// acknowledged: it must be reported as post_err, and the cache must
	// release the bus and stay usable
	err_arm = 1;
	err_addr = 32'h0000_1E80;
	err_beat = 2'd0;
	err_count = 0;
	post_err_seen = 0;
	cpu_write_sz(32'h0000_1E80, 32'hBAD0_1E80, 2'd2);
	guard5 = 0;
	while (!post_err_seen && guard5 < 300) begin
		@(posedge clk); guard5 = guard5 + 1;
	end
	err_arm = 0;
	if (!post_err_seen) begin
		$display("FAIL test 11: bus error on a posted store was not reported (post_err)");
		errors = errors + 1;
	end
	expect_bus_idle(11);
	expect_read(32'h0000_7100, mem[32'h7100>>2], 11);

	// T11f: posted stores under constant chipset traffic, both speeds,
	// then the values read back through the merged lines
	expect_read(32'h0000_1D00, mem[32'h1D00>>2], 11);
	snoop_storm = 1;
	for (off = 0; off < 6; off = off + 1) begin
		mem_lat = off[0] ? 2'd0 : 2'd2;
		cpu_write_sz(32'h0000_1D00 + {off[2:0], 2'b00}, 32'h11F0_0000 + off, 2'd2);
	end
	snoop_storm = 0;
	mem_lat = 2'd2;
	for (off = 0; off < 6; off = off + 1)
		expect_read(32'h0000_1D00 + {off[2:0], 2'b00}, 32'h11F0_0000 + off, 11);
	repeat (6) @(posedge clk);

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
