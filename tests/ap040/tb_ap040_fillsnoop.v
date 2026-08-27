// tb_ap040_fillsnoop.v -- directed bench for ap040_ucache's snoop guard on
// the 32-bit fast-fill path (C_FFILL / C_FWR / C_TAGW).
//
// The invariant under test: a snoop strobe that touches the ROW of a line
// being filled through the fast port must prevent that line from being
// TAGGED, because a chipset DMA write may have changed memory after the
// controller's burst read it.  The acked datum itself is allowed to be the
// pre-snoop value -- the same policy the 16-bit fill path has always had --
// but the CACHED copy must be dropped, so the next read refetches.
//
// Four sequences, each against the REAL ap040_ucache:
//   1  snoop into the fill's row during C_FFILL (waiting on the bridge)
//        -> next read of the same line must MISS and see fresh data
//   2  control: identical fill, no snoop -> next read must HIT and never
//        touch the fill port (proves 1 is not passing vacuously)
//   3  snoop into the fill's row during C_FWR (line write-back window)
//        -> next read must MISS
//   4  snoop into a DIFFERENT row mid-fill -> next read must still HIT
//        (proves the guard does not over-invalidate)
//
// The fill model implements ap040_fill_cdc's s-side contract: f_done is a
// LEVEL raised some cycles after f_req and held until f_req drops, with
// f_line stable from f_done onward.

`include "ap040_defs.svh"

module tb_ap040_fillsnoop;

reg clk = 0;
always #5 clk = ~clk;

reg nreset = 0;

// slave side
reg         c_req = 0;
reg  [31:0] c_addr = 0;
wire        c_ack;
wire [31:0] c_rdata;

// master side must stay quiet: every read in this bench is fast-fill
wire        m_req;
reg         m_ack = 0;

// fast fill port
wire        f_req;
wire [31:0] f_addr;
wire  [1:0] f_bsel;
reg         f_ok = 1;
reg [127:0] f_line = 0;
reg         f_done = 0;

// snoop
reg         s_stb = 0;
reg  [31:0] s_addr = 0;

integer errors = 0;

ap040_ucache dut (
	.clk(clk), .nreset(nreset), .ce(1'b1),
	.ie(1'b1), .de(1'b1),
	.cinv_req(1'b0), .cinv_ic(1'b0), .cinv_dc(1'b0), .cinv_done(),
	.c_req(c_req), .c_write(1'b0), .c_instr(1'b0),
	.c_size(`AP040_SZ_L), .c_addr(c_addr), .c_wdata(32'd0),
	.c_fc(3'b001), .c_nocache(1'b0),
	.c_ack(c_ack), .c_rdata(c_rdata),
	.m_req(m_req), .m_write(), .m_instr(), .m_size(), .m_addr(),
	.m_wdata(), .m_fc(), .m_ack(m_ack), .m_rdata(32'd0), .m_err(1'b0),
	.f_req(f_req), .f_addr(f_addr), .f_bsel(f_bsel), .f_instr(),
	.f_busy(), .f_ok(f_ok), .f_line(f_line), .f_done(f_done),
	.s_stb(s_stb), .s_addr(s_addr)
);

// the 16-bit adapter must never be engaged by these reads
always @(posedge clk) if (nreset && m_req) begin
	errors = errors + 1;
	$display("FAIL: m_req rose -- a fast-fill read fell back to the adapter");
end

// fill service model (ap040_fill_cdc s-side contract).  fill_count says how
// many fills the port has served, which is how the tests distinguish a HIT
// (no new fill) from a MISS (one more fill).
integer fill_count = 0;
integer fill_delay = 6;
reg [127:0] fill_next = 0;
integer fd;
always @(posedge clk) begin
	if (!nreset) f_done <= 0;
	else begin
		if (!f_req) f_done <= 0;
		else if (!f_done) begin
			fd = 0;
			while (fd < fill_delay) begin
				@(posedge clk);
				fd = fd + 1;
			end
			f_line <= fill_next;
			f_done <= 1;
			fill_count = fill_count + 1;
		end
	end
end

task read_long;
	input  [31:0] a;
	output [31:0] d;
	integer guard;
	begin
		@(posedge clk);
		c_addr <= a;
		c_req  <= 1;
		guard = 0;
		@(posedge clk);
		while (!c_ack && guard < 200) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (!c_ack) begin
			errors = errors + 1;
			$display("FAIL: read of %h timed out", a);
		end
		d = c_rdata;
		c_req <= 0;
		@(posedge clk);
		@(posedge clk);
	end
endtask

task snoop_pulse;
	input [31:0] a;
	begin
		@(posedge clk);
		s_addr <= a;
		s_stb  <= 1;
		@(posedge clk);
		s_stb  <= 0;
	end
endtask

// wait until the DUT enters a given state, with a guard
task wait_state;
	input [3:0] st;
	integer guard;
	begin
		guard = 0;
		while (dut.cst != st && guard < 200) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (dut.cst != st) begin
			errors = errors + 1;
			$display("FAIL: never reached cst=%0d (cst=%0d)", st, dut.cst);
		end
	end
endtask

reg [31:0] rd;
integer fills_before;

initial begin
	repeat (4) @(posedge clk);
	nreset = 1;
	repeat (4) @(posedge clk);

	//------------------------------------------------ 1: snoop in C_FFILL
	// slow fill service so the snoop lands while the cache waits
	fill_delay = 12;
	fill_next  = 128'hDDDD3333_DDDD2222_DDDD1111_DDDD0000;
	fork
		begin
			read_long(32'h0000_1230, rd);
		end
		begin
			wait_state(4'd8);            // C_FFILL
			repeat (2) @(posedge clk);
			snoop_pulse(32'h0000_1238);  // same line, different longword
		end
	join
	if (rd !== 32'hDDDD0000) begin
		errors = errors + 1;
		$display("FAIL 1a: acked datum %h, expected DDDD0000", rd);
	end
	// the re-read must MISS: the snooped fill must not have been tagged
	fill_delay   = 2;
	fill_next    = 128'hEEEE3333_EEEE2222_EEEE1111_EEEE0000;
	fills_before = fill_count;
	read_long(32'h0000_1230, rd);
	if (fill_count != fills_before + 1) begin
		errors = errors + 1;
		$display("FAIL 1b: snooped line was tagged (re-read hit, %0d fills)",
		         fill_count - fills_before);
	end
	if (rd !== 32'hEEEE0000) begin
		errors = errors + 1;
		$display("FAIL 1c: re-read datum %h, expected EEEE0000", rd);
	end

	//------------------------------------------------ 2: control, no snoop
	fill_delay = 6;
	fill_next  = 128'hAAAA3333_AAAA2222_AAAA1111_AAAA0000;
	read_long(32'h0000_2230, rd);
	if (rd !== 32'hAAAA0000) begin
		errors = errors + 1;
		$display("FAIL 2a: acked datum %h, expected AAAA0000", rd);
	end
	fills_before = fill_count;
	read_long(32'h0000_2234, rd);
	if (fill_count != fills_before) begin
		errors = errors + 1;
		$display("FAIL 2b: clean line was NOT tagged (re-read missed)");
	end
	if (rd !== 32'hAAAA1111) begin
		errors = errors + 1;
		$display("FAIL 2c: hit datum %h, expected AAAA1111", rd);
	end

	//------------------------------------------------ 3: snoop in C_FWR
	fill_delay = 6;
	fill_next  = 128'hBBBB3333_BBBB2222_BBBB1111_BBBB0000;
	fork
		begin
			read_long(32'h0000_3230, rd);
		end
		begin
			wait_state(4'd9);            // C_FWR
			snoop_pulse(32'h0000_3234);
		end
	join
	fill_delay   = 2;
	fill_next    = 128'hCCCC3333_CCCC2222_CCCC1111_CCCC0000;
	fills_before = fill_count;
	read_long(32'h0000_3230, rd);
	if (fill_count != fills_before + 1) begin
		errors = errors + 1;
		$display("FAIL 3: line snooped in C_FWR was tagged (re-read hit)");
	end

	//------------------------------------- 4: snoop a DIFFERENT row mid-fill
	fill_delay = 12;
	fill_next  = 128'h99993333_99992222_99991111_99990000;
	fork
		begin
			read_long(32'h0000_4230, rd);
		end
		begin
			wait_state(4'd8);
			repeat (2) @(posedge clk);
			snoop_pulse(32'h0000_5630);  // different set entirely
		end
	join
	fills_before = fill_count;
	read_long(32'h0000_4234, rd);
	if (fill_count != fills_before) begin
		errors = errors + 1;
		$display("FAIL 4a: unrelated snoop de-tagged the fill (re-read missed)");
	end
	if (rd !== 32'h99991111) begin
		errors = errors + 1;
		$display("FAIL 4b: hit datum %h, expected 99991111", rd);
	end

	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end

initial begin
	#400000;
	$display("FAIL: global timeout");
	$display("TEST FAILED with %0d errors", errors + 1);
	$finish;
end

endmodule
