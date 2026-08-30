// Copyright 2021 Alexey Melnikov
//
// This file is part of Minimig
//
// Minimig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// Minimig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http:// www.gnu.org/licenses/>.
//
//----------------------------------------------------------------------------------  

module fastchip
(
	input         clk,
	input         cyc,
	input         clk_sys,

	input         reset,

	input         sel,
	output        sel_ack, // 1 when fast chip is used instead of legacy chip
	output        ready,

	input  [23:0] addr,
	input  [15:0] din,
	output [15:0] dout,
	input         lds,
	input         uds,
	input         rnw,

	//RTG framebuffer control
	output        rtg_ena,
	output [11:0] rtg_hsize,
	output [11:0] rtg_vsize,
	output [4:0]  rtg_format,
	output [31:0] rtg_base,
	output [13:0] rtg_stride,
	output        rtg_pal_clk,
	output [23:0] rtg_pal_dw,
	input  [23:0] rtg_pal_dr,
	output [7:0]  rtg_pal_a,
	output        rtg_pal_wr,

	// Gayle/IDE frontend.  One shared gayle sits in Minimig.sv because
	// only one of the two frontends is ever decoding (ide_ena & ide_fast
	// here, ide_ena & ~ide_fast in gary), so a second copy was 369 ALMs
	// and 32 M10Ks of pure duplicate.
	input         ide_ena,
	output        gayle_sel_ide,
	output        gayle_sel_gayle,
	output        gayle_rd,
	output        gayle_wr,
	input  [15:0] gayle_dout,
	input         gayle_nrdy
);

assign sel_ack = sel_akiko  | sel_ide   | sel_rtg   | sel_gayle;
assign ready   = sel_akiko  | ide_ready | rtg_ready;
assign dout    = akiko_dout | ide_dout  | rtg_dout;

wire        sel_akiko = sel && (addr[23:8] == 'hB800);
wire [15:0] akiko_dout;

akiko akiko
(
	.clk(clk_sys),
	.cs(sel_akiko && !addr[7:6]),
	.rd(rnw),
	.wr(~rnw & (lds|uds)),
	.addr(addr[5:1]),
	.din(din),
	.dout(akiko_dout)
);

wire sel_ide   = ide_ena && sel && addr[23:16] ==  8'b1101_1010;       //IDE registers at $DA0000 - $DAFFFF	
wire sel_gayle = ide_ena && sel && addr[23:12] == 12'b1101_1110_0001;  //GAYLE registers at $DE1000 - $DE1FFF

reg ide_ack;
always @(posedge clk_sys) ide_ack <= (sel_ide | sel_gayle);

wire ide_ready = ide_ack & (sel_ide | sel_gayle) & ~(ide_nrdy & rnw);

// the shared gayle in Minimig.sv answers with these; its addr/data_in and
// longword come straight off the same top-level chip bus this block sees.
wire [15:0] ide_dout = gayle_dout;
wire        ide_nrdy = gayle_nrdy;

assign gayle_sel_ide   = sel_ide;
assign gayle_sel_gayle = sel_gayle;
assign gayle_rd        = rnw & uds;
assign gayle_wr        = ~rnw & uds;

// Akiko ($B800xx) sits INSIDE the RTG window ($B80000-$B80FFF), so both
// decodes fire in the overlap and dout/ready are wired-OR
// (dout = akiko_dout | ide_dout | rtg_dout).  Upstream gives Akiko
// priority; match it.  This affects the CD32 Akiko range rather than
// RTG's own registers (control at $B80200+, palette at $B80800+), but it
// is a real divergence from upstream and free to correct.
wire        sel_rtg = sel && !sel_akiko && (addr[23:12] == 'hB80);
wire [15:0] rtg_dout;
wire        rtg_ready;

rtg rtg
(
	.clk(clk_sys),
	.reset(reset),

	.aen(sel_rtg),
	.ready(rtg_ready),
	.rd(rnw),
	.wr(~rnw & (lds|uds)),
	.rs(addr[11:1]),
	.data_in(din),
	.data_out(rtg_dout),
	.ena(rtg_ena),
	.hsize(rtg_hsize),
	.vsize(rtg_vsize),
	.format(rtg_format),
	.base(rtg_base),
	.stride(rtg_stride),
	.pal_clk(rtg_pal_clk),
	.pal_dw(rtg_pal_dw),
	.pal_dr(rtg_pal_dr),
	.pal_a(rtg_pal_a),
	.pal_wr(rtg_pal_wr)
);

endmodule
