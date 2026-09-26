// tb_ap040_rz_muldiv.v -- ranzbak's EX stage with ap040-pipelined's multiply
// and divide, against upstream's (tests/ap040/ranzbak_ref/): the unit
// ranzbak validated on the WinUAE cputest corpus.
//
// Both EX stages run the same MUL/DIV micro-ops, each fed by its own driver
// that holds a micro-op while its stage stalls, as EA-fetch does. Every WB
// record each produces, and each forward (register, CCR, store, redirect)
// in the clock its micro-op retires, must be identical and in the same
// order. The micro-ops:
//   1. every form -- MULU/MULS .W, .L 32 and 64-bit, DIVU/DIVS .W, .L 32
//      and 64-bit dividend -- over every pair of edge operands;
//   2. divides whose quotient is built to sit on each overflow boundary
//      (16-bit and 32-bit, signed and unsigned), with every remainder sign;
//   3. random forms and operands, the other micro-op fields random too.
// Divides by zero are included: EA-fetch marks them (cc) and EX only clears
// C. The new stage's occupancy is checked per form: a word multiply one
// clock, a long multiply two, a divide ten.
//
// +ce_random: the clock enable is random (both stages see the same one).
// +n=<count>: random micro-ops in part 3 (default 200000).
`timescale 1ns/1ps
`include "ap040_pipe_defs.svh"

module tb_ap040_rz_muldiv;
import ap040_pipe_pkg::*;

reg clk = 0;
reg nreset = 0;
reg ce = 1;
always #5 clk = ~clk;

localparam integer NMAX = 262144;
ex_t        ops  [0:NMAX-1];
reg   [4:0] ccrs [0:NMAX-1];
reg   [2:0] form [0:NMAX-1];   // 0 MUL.W 1 MUL.L32 2 MUL.L64 3 DIV.W 4 DIV.L32 5 DIV.L64
integer     n_ops = 0;

// one EX stage and its driver per side: index 0 the new, 1 upstream's
reg         v   [0:1];
ex_t        x   [0:1];
reg   [4:0] cin [0:1];
integer     ix  [0:1];
integer     occ [0:1];          // clocks the current micro-op has been held
wire        stall   [0:1];
wire        exe_v   [0:1];
wire wb_t   exe_o   [0:1];
wire        fw_w0_v [0:1];  wire [4:0] fw_w0_r [0:1];  wire [31:0] fw_w0_val [0:1];
wire        fw_ccr_v[0:1];  wire [4:0] fw_ccr  [0:1];
wire        fw_st_v [0:1];  wire [31:0] fw_st_addr [0:1];  wire [1:0] fw_st_size [0:1];
wire [31:0] fw_st_data [0:1];
wire        redir   [0:1];  wire [31:0] redir_pc [0:1];  wire redir_s [0:1];

ap040_execute #(.HAS_FPU(1)) dut (
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(1'b0), .wb_drop(1'b0), .in_drop(1'b0),
	.eaf_valid(v[0]), .x(x[0]), .ccr_in(cin[0]), .sr_in(16'h2700),
	.sfc_in(32'd0), .dfc_in(32'd0), .cacr_in(32'd0), .vbr_in(32'd0),
	.tc_in(32'd0), .itt0_in(32'd0), .itt1_in(32'd0), .dtt0_in(32'd0), .dtt1_in(32'd0),
	.mmusr_in(32'd0), .urp_in(32'd0), .srp_in(32'd0),
	.ex_stall(stall[0]),
	.fw_w0_v(fw_w0_v[0]), .fw_w0_r(fw_w0_r[0]), .fw_w0_val(fw_w0_val[0]),
	.fw_ccr_v(fw_ccr_v[0]), .fw_ccr(fw_ccr[0]),
	.fw_st_v(fw_st_v[0]), .fw_st_addr(fw_st_addr[0]), .fw_st_size(fw_st_size[0]), .fw_st_data(fw_st_data[0]),
	.ex_redirect(redir[0]), .ex_redirect_pc(redir_pc[0]), .ex_redirect_s(redir_s[0]),
	.exe_valid(exe_v[0]), .exe_o(exe_o[0])
);

ap040_execute_ref #(.HAS_FPU(1)) ref_ex (
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(1'b0), .wb_drop(1'b0), .in_drop(1'b0),
	.eaf_valid(v[1]), .x(x[1]), .ccr_in(cin[1]), .sr_in(16'h2700),
	.sfc_in(32'd0), .dfc_in(32'd0), .cacr_in(32'd0), .vbr_in(32'd0),
	.tc_in(32'd0), .itt0_in(32'd0), .itt1_in(32'd0), .dtt0_in(32'd0), .dtt1_in(32'd0),
	.mmusr_in(32'd0), .urp_in(32'd0), .srp_in(32'd0),
	.ex_stall(stall[1]),
	.fw_w0_v(fw_w0_v[1]), .fw_w0_r(fw_w0_r[1]), .fw_w0_val(fw_w0_val[1]),
	.fw_ccr_v(fw_ccr_v[1]), .fw_ccr(fw_ccr[1]),
	.fw_st_v(fw_st_v[1]), .fw_st_addr(fw_st_addr[1]), .fw_st_size(fw_st_size[1]), .fw_st_data(fw_st_data[1]),
	.ex_redirect(redir[1]), .ex_redirect_pc(redir_pc[1]), .ex_redirect_s(redir_s[1]),
	.exe_valid(exe_v[1]), .exe_o(exe_o[1])
);

//---------------------------------------------------------------- the micro-ops
localparam integer NEDGE = 20;
reg [31:0] edge_v [0:NEDGE-1];
initial begin
	edge_v[0]  = 32'h0000_0000; edge_v[1]  = 32'h0000_0001; edge_v[2]  = 32'h0000_0002;
	edge_v[3]  = 32'h0000_0003; edge_v[4]  = 32'h0000_007F; edge_v[5]  = 32'h0000_0080;
	edge_v[6]  = 32'h0000_7FFF; edge_v[7]  = 32'h0000_8000; edge_v[8]  = 32'h0000_FFFF;
	edge_v[9]  = 32'h0001_0000; edge_v[10] = 32'h7FFF_FFFF; edge_v[11] = 32'h8000_0000;
	edge_v[12] = 32'h8000_0001; edge_v[13] = 32'hFFFF_FFFF; edge_v[14] = 32'hFFFF_FFFE;
	edge_v[15] = 32'hFFFF_8000; edge_v[16] = 32'hFFFF_7FFF; edge_v[17] = 32'h1234_5678;
	edge_v[18] = 32'hFFFE_0000; edge_v[19] = 32'h0000_0005;
end

function automatic [31:0] rnd_op();
	return ($urandom % 3 == 0) ? edge_v[$urandom % NEDGE] : $urandom;
endfunction

// A micro-op of form f with signedness s: the other fields random (they
// pass through EX unchanged, on both sides).
function automatic ex_t mk(input [2:0] f, input s, input [31:0] a, input [31:0] b, input [31:0] c,
                           input [2:0] dr, input [2:0] dr2);
	ex_t o;
	logic [$bits(ex_t)-1:0] bits;
	integer k;
	for (k = 0; k < $bits(ex_t); k = k + 32) bits[k +: 32] = $urandom;
	o = bits;
	o.cls  = CL_MULDIV;
	o.imm4 = {(f == 3'd2 || f == 3'd5), (f == 3'd1 || f == 3'd2 || f == 3'd4 || f == 3'd5), s, (f >= 3'd3)};
	o.size = (f == 3'd0 || f == 3'd3) ? SZ_W : SZ_L;
	o.a = a; o.b = b; o.c = c;
	o.dr  = {2'b00, dr};
	o.dr2 = {2'b00, dr2};
	// EA-fetch's divide-by-zero mark: the divisor is the source, a
	o.cc  = (f >= 3'd3) && ((f == 3'd3) ? (a[15:0] == 16'd0) : (a == 32'd0));
	return o;
endfunction

task automatic add(input [2:0] f, input s, input [31:0] a, input [31:0] b, input [31:0] c);
	reg [2:0] r1, r2;
	r1 = $urandom; r2 = ($urandom % 4 == 0) ? r1 : $urandom;
	ops[n_ops]  = mk(f, s, a, b, c, r1, r2);
	ccrs[n_ops] = $urandom;
	form[n_ops] = f;
	n_ops = n_ops + 1;
endtask

integer   n_rand, i, j, k, f, s, q, rr;
reg [63:0] dvd, qv, dsr64;
reg [31:0] dsr;
initial begin
	if (!$value$plusargs("n=%d", n_rand)) n_rand = 200000;
	// 1. every form, every pair of edge operands (and, for the 64-bit
	//    divide, a few high dividends)
	for (f = 0; f < 6; f = f + 1)
		for (s = 0; s < 2; s = s + 1)
			for (i = 0; i < NEDGE; i = i + 1)
				for (j = 0; j < NEDGE; j = j + 1)
					if (f == 5)
						for (k = 0; k < 4; k = k + 1)
							add(f, s, edge_v[i], edge_v[j], edge_v[(i * 7 + j * 3 + k * 5) % NEDGE]);
					else
						add(f, s, edge_v[i], edge_v[j], edge_v[(i + j) % NEDGE]);
	// 2. divides built on the overflow boundaries: dividend = q * divisor + r
	for (k = 0; k < 4000; k = k + 1) begin
		f = 3 + ($urandom % 3);
		s = $urandom % 2;
		dsr = rnd_op();
		if (f == 3) dsr = {16'd0, dsr[15:0]} | 32'd1;
		if (dsr == 0) dsr = 32'd7;
		case ($urandom % 12)
			0: qv = 64'h0000_0000_0000_7FFF;  1: qv = 64'h0000_0000_0000_8000;
			2: qv = 64'h0000_0000_0000_FFFF;  3: qv = 64'h0000_0000_0001_0000;
			4: qv = 64'hFFFF_FFFF_FFFF_8000;  5: qv = 64'hFFFF_FFFF_FFFF_7FFF;
			6: qv = 64'h0000_0000_7FFF_FFFF;  7: qv = 64'h0000_0000_8000_0000;
			8: qv = 64'h0000_0000_FFFF_FFFF;  9: qv = 64'h0000_0001_0000_0000;
			10: qv = 64'hFFFF_FFFF_8000_0000; default: qv = 64'hFFFF_FFFF_7FFF_FFFF;
		endcase
		// the divisor as the form takes it: a word one sign- or zero-extended
		dsr64 = (f == 3) ? (s ? {{48{dsr[15]}}, dsr[15:0]} : {48'd0, dsr[15:0]})
		                 : (s ? {{32{dsr[31]}}, dsr} : {32'd0, dsr});
		dvd = qv * dsr64;
		rr = $urandom % 3;
		if (rr == 1) dvd = dvd + 64'd1;
		if (rr == 2) dvd = dvd - 64'd1;
		if (f == 5) add(f, s, dsr, dvd[31:0], dvd[63:32]);
		else        add(f, s, dsr, dvd[31:0], $urandom);
	end
	// 3. random
	for (k = 0; k < n_rand && n_ops < NMAX; k = k + 1)
		add($urandom % 6, $urandom % 2, rnd_op(), rnd_op(), rnd_op());
	$display("%0d micro-ops", n_ops);
end

//---------------------------------------------------------------- drivers
// A micro-op is presented until its stage takes it (ce, not stalled); a
// bubble of 0-2 clocks sometimes follows, the same for both sides.
reg   [1:0] gap [0:NMAX-1];
initial for (k = 0; k < NMAX; k = k + 1) gap[k] = ($urandom % 4 == 0) ? ($urandom % 3) : 2'd0;
integer bub [0:1];
integer occ_sum [0:1][0:5];
integer occ_min [0:5], occ_max [0:5];
integer errors = 0;
genvar g;
generate for (g = 0; g < 2; g = g + 1) begin : drv
	always @(posedge clk) begin
		if (!nreset) begin
			v[g] <= 1'b0; ix[g] <= 0; occ[g] <= 0; bub[g] <= 0;
		end else if (ce) begin
			if (v[g] && !stall[g]) begin
				// taken this clock: its occupancy, then the next (after its gap)
				occ_sum[g][form[ix[g]]] = occ_sum[g][form[ix[g]]] + occ[g] + 1;
				if (g == 0 && !ops[ix[g]].cc) begin
					if (occ[g] + 1 < occ_min[form[ix[g]]]) occ_min[form[ix[g]]] = occ[g] + 1;
					if (occ[g] + 1 > occ_max[form[ix[g]]]) occ_max[form[ix[g]]] = occ[g] + 1;
				end
				occ[g] <= 0;
				if (gap[ix[g]] != 0) begin v[g] <= 1'b0; bub[g] <= gap[ix[g]] - 1; end
				else if (ix[g] + 1 < n_ops) begin x[g] <= ops[ix[g] + 1]; cin[g] <= ccrs[ix[g] + 1]; end
				else v[g] <= 1'b0;
				ix[g] <= ix[g] + 1;
			end else if (v[g]) begin
				occ[g] <= occ[g] + 1;
			end else if (bub[g] != 0) begin
				bub[g] <= bub[g] - 1;
			end else if (ix[g] < n_ops) begin
				v[g] <= 1'b1; x[g] <= ops[ix[g]]; cin[g] <= ccrs[ix[g]];
			end
		end
	end
end endgenerate

//---------------------------------------------------------------- comparison
// Each side's WB records and retiring-clock forwards, in order.
localparam integer FW = 1 + 5 + 32 + 1 + 5 + 1 + 32 + 2 + 32 + 1 + 32 + 1;
wb_t              rec [0:1][0:NMAX-1];
reg  [FW-1:0]     fwd [0:1][0:NMAX-1];
integer           nrec [0:1];
integer           nfwd [0:1];
integer           cmp_r = 0, cmp_f = 0;
generate for (g = 0; g < 2; g = g + 1) begin : col
	always @(posedge clk) if (nreset && ce) begin
		if (exe_v[g]) begin rec[g][nrec[g]] = exe_o[g]; nrec[g] = nrec[g] + 1; end
		if (v[g] && !stall[g]) begin
			fwd[g][nfwd[g]] = {fw_w0_v[g], fw_w0_r[g], fw_w0_val[g], fw_ccr_v[g], fw_ccr[g],
			                   fw_st_v[g], fw_st_addr[g], fw_st_size[g], fw_st_data[g],
			                   redir[g], redir_pc[g], redir_s[g]};
			nfwd[g] = nfwd[g] + 1;
		end
	end
end endgenerate

task automatic show(input integer m);
	ex_t o;
	o = ops[m];
	$display("    micro-op %0d: form %0d imm4 %b a %h b %h c %h dr %0d dr2 %0d cc %b ccr %b",
	         m, form[m], o.imm4, o.a, o.b, o.c, o.dr, o.dr2, o.cc, ccrs[m]);
endtask

always @(posedge clk) begin
	while (cmp_r < nrec[0] && cmp_r < nrec[1]) begin
		if (rec[0][cmp_r] !== rec[1][cmp_r]) begin
			errors = errors + 1;
			if (errors <= 10) begin
				$display("FAIL: WB record %0d differs", cmp_r);
				show(cmp_r);
				$display("    new: w0 %b %0d %h  u1 %b %0d %h  ccr %b %b", rec[0][cmp_r].w0_v, rec[0][cmp_r].w0_r,
				         rec[0][cmp_r].w0_val, rec[0][cmp_r].u1_v, rec[0][cmp_r].u1_r, rec[0][cmp_r].u1_val,
				         rec[0][cmp_r].ccr_v, rec[0][cmp_r].ccr_val);
				$display("    ref: w0 %b %0d %h  u1 %b %0d %h  ccr %b %b", rec[1][cmp_r].w0_v, rec[1][cmp_r].w0_r,
				         rec[1][cmp_r].w0_val, rec[1][cmp_r].u1_v, rec[1][cmp_r].u1_r, rec[1][cmp_r].u1_val,
				         rec[1][cmp_r].ccr_v, rec[1][cmp_r].ccr_val);
			end
		end
		cmp_r = cmp_r + 1;
	end
	while (cmp_f < nfwd[0] && cmp_f < nfwd[1]) begin
		if (fwd[0][cmp_f] !== fwd[1][cmp_f]) begin
			errors = errors + 1;
			if (errors <= 10) begin
				$display("FAIL: the forwards of micro-op %0d differ: new %h ref %h", cmp_f, fwd[0][cmp_f], fwd[1][cmp_f]);
				show(cmp_f);
			end
		end
		cmp_f = cmp_f + 1;
	end
end

//---------------------------------------------------------------- run
reg ce_random;
always @(posedge clk) if (ce_random) ce <= ($urandom % 3 != 0);
integer t;
initial begin
	ce_random = $test$plusargs("ce_random");
	nrec[0] = 0; nrec[1] = 0; nfwd[0] = 0; nfwd[1] = 0;
	for (k = 0; k < 6; k = k + 1) begin
		occ_sum[0][k] = 0; occ_sum[1][k] = 0; occ_min[k] = 1000; occ_max[k] = 0;
	end
	repeat (4) @(posedge clk);
	nreset = 1'b1;
	t = 0;
	while ((ix[0] < n_ops || ix[1] < n_ops || v[0] || v[1]) && t < 40 * NMAX) begin
		@(posedge clk); t = t + 1;
	end
	repeat (8) @(posedge clk);
	if (ix[0] != n_ops || ix[1] != n_ops) begin
		errors = errors + 1;
		$display("FAIL: timeout: new took %0d of %0d micro-ops, ref %0d", ix[0], n_ops, ix[1]);
	end
	if (nrec[0] != n_ops || nrec[1] != n_ops || nfwd[0] != n_ops || nfwd[1] != n_ops) begin
		errors = errors + 1;
		$display("FAIL: %0d micro-ops, but WB records %0d/%0d and retirements %0d/%0d (new/ref)",
		         n_ops, nrec[0], nrec[1], nfwd[0], nfwd[1]);
	end
	// the new stage's occupancy, in ce clocks, divides by zero aside
	if (occ_min[0] != 1 || occ_max[0] != 1) begin
		errors = errors + 1; $display("FAIL: a word multiply held EX %0d-%0d clocks, not 1", occ_min[0], occ_max[0]);
	end
	for (k = 1; k < 3; k = k + 1)
		if (occ_min[k] != 2 || occ_max[k] != 2) begin
			errors = errors + 1; $display("FAIL: a long multiply (form %0d) held EX %0d-%0d clocks, not 2", k, occ_min[k], occ_max[k]);
		end
	for (k = 3; k < 6; k = k + 1)
		if (occ_min[k] != 10 || occ_max[k] != 10) begin
			errors = errors + 1; $display("FAIL: a divide (form %0d) held EX %0d-%0d clocks, not 10", k, occ_min[k], occ_max[k]);
		end
	$display("EX clocks per form, new vs upstream (MUL.W MUL.L MUL.L64 DIV.W DIV.L DIV.L64):");
	$display("    new      %0d %0d %0d %0d %0d %0d", occ_sum[0][0], occ_sum[0][1], occ_sum[0][2], occ_sum[0][3], occ_sum[0][4], occ_sum[0][5]);
	$display("    upstream %0d %0d %0d %0d %0d %0d", occ_sum[1][0], occ_sum[1][1], occ_sum[1][2], occ_sum[1][3], occ_sum[1][4], occ_sum[1][5]);
	$display("%0d micro-ops compared, %0d WB records, %0d retirements", n_ops, cmp_r, cmp_f);
	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
