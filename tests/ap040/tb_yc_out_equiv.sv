// tb_yc_out_equiv.sv -- cycle-exact equivalence of sys/yc_out.sv against the
// frozen ref/yc_out_ref.sv (the module before its chroma sine lookups were
// registered a stage ahead of the DSP multiply).  Both instances see the same
// clock and stimulus; every output must agree on every clock, through NTSC
// and PAL, CVBS on and off, sync/de line patterns, random video, and phases
// in which PAL_EN and CVBS flip mid-stream (exercising PAL_FLIP and the
// burst path).  Any mismatch is a failure.
//
// +break_skew feeds the live module its video one clock late: a control that
// must FAIL, proving the comparison sees a one-cycle difference (the very
// thing the registered lookup could have introduced).
`timescale 1ns/1ps
module tb_yc_out_equiv;
reg clk = 0;
always #4.4 clk = ~clk;

reg  [39:0] phase_inc = 40'd0;
reg         pal_en = 0, cvbs = 0;
reg  [16:0] cburst_range = {7'd40, 10'd240};
reg         hsync = 0, vsync = 0, csync = 0, de = 0;
reg  [23:0] din = 24'd0;

wire [23:0] dout_n, dout_r;
reg  [23:0] din_late = 24'd0;
always @(posedge clk) din_late <= din;
wire        break_skew = $test$plusargs("break_skew");
wire [23:0] din_new = break_skew ? din_late : din;
wire        hs_n, vs_n, cs_n, de_n, hs_r, vs_r, cs_r, de_r;

yc_out dut_new (
	.clk(clk), .PHASE_INC(phase_inc), .PAL_EN(pal_en), .CVBS(cvbs),
	.COLORBURST_RANGE(cburst_range), .hsync(hsync), .vsync(vsync), .csync(csync),
	.de(de), .din(din_new), .dout(dout_n),
	.hsync_o(hs_n), .vsync_o(vs_n), .csync_o(cs_n), .de_o(de_n));

yc_out_ref dut_ref (
	.clk(clk), .PHASE_INC(phase_inc), .PAL_EN(pal_en), .CVBS(cvbs),
	.COLORBURST_RANGE(cburst_range), .hsync(hsync), .vsync(vsync), .csync(csync),
	.de(de), .din(din), .dout(dout_r),
	.hsync_o(hs_r), .vsync_o(vs_r), .csync_o(cs_r), .de_o(de_r));

// line/frame pattern: 1820 clocks per line (4x a 455-clock 28 MHz line is
// not the point -- what matters is hsync pulses, a de window and vsync
// every few lines, so the burst counter and PAL_FLIP both run)
integer col = 0, line = 0;
always @(posedge clk) begin
	col <= (col == 1819) ? 0 : col + 1;
	if (col == 1819) line <= (line == 7) ? 0 : line + 1;
	hsync <= (col < 120);
	vsync <= (line == 0) && (col < 900);
	csync <= (col < 120) || ((line == 0) && (col < 900));
	de    <= (col >= 300) && (col < 1740) && (line != 0);
	din   <= $urandom;
end

integer errors = 0, cycles = 0, phase = 0;
always @(posedge clk) begin
	cycles <= cycles + 1;
	if (dout_n !== dout_r || hs_n !== hs_r || vs_n !== vs_r || cs_n !== cs_r || de_n !== de_r) begin
		errors <= errors + 1;
		if (errors < 10)
			$display("FAIL: phase %0d cycle %0d: new dout=%h hs=%b vs=%b cs=%b de=%b  ref dout=%h hs=%b vs=%b cs=%b de=%b",
			         phase, cycles, dout_n, hs_n, vs_n, cs_n, de_n, dout_r, hs_r, vs_r, cs_r, de_r);
	end
end

// NTSC and PAL subcarrier increments at 113.44 MHz: f_sc / f_clk * 2^40
localparam [39:0] INC_NTSC = 40'd34690400000;
localparam [39:0] INC_PAL  = 40'd42960900000;
task run_phase(input integer n, input [39:0] inc, input p, input c, input integer ncyc);
	begin
		phase = n; phase_inc = inc; pal_en = p; cvbs = c;
		repeat (ncyc) @(posedge clk);
	end
endtask

integer k;
initial begin
	repeat (4) @(posedge clk);
	run_phase(1, INC_NTSC, 0, 0, 60000);
	run_phase(2, INC_NTSC, 0, 1, 60000);
	run_phase(3, INC_PAL,  1, 0, 60000);
	run_phase(4, INC_PAL,  1, 1, 60000);
	// flip standards and outputs mid-stream, at arbitrary points in a line
	for (k = 0; k < 40; k = k + 1)
		run_phase(5, (k[0] ? INC_PAL : INC_NTSC), k[1], k[2], 1000 + 37 * k);
	run_phase(6, 40'd12345678901, 1, 1, 30000);
	if (errors == 0) $display("ALL TESTS PASSED (%0d cycles compared)", cycles);
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end
endmodule
