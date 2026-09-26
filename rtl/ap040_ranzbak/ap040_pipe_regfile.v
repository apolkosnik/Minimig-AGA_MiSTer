//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_pipe_regfile.v - D0-D7, A0-A6, USP, ISP, MSP (Minimig plan M1)     //
//                                                                          //
// Physical register numbers (ap040_pipe_pkg.sv): 0-7 D0-D7, 8-14 A0-A6,    //
// 16 USP, 17 ISP, 18 MSP.  (15, "A7 as written", is resolved to one of the  //
// three stack pointers before it gets here; reading it returns 0.)         //
//                                                                          //
// Three write ports, all committed by WB in the same clock:                //
//   w0  the instruction's result                                           //
//   u1  the destination EA's (An)+/-(An) update                             //
//   u0  the source EA's update, or a sequenced stack-pointer write          //
// Priority when two name the same register: w0 > u1 > u0 (MOVEA (A0)+,A0   //
// loads A0, the increment is lost; MOVE (A0)+,(A0)+ -- EA-calc already     //
// folded the two updates into u1).                                        //
//                                                                          //
// Six asynchronous read ports (EA-calc 4, EA-fetch 2), each with the       //
// write-through of all three write ports, so an instruction reading a      //
// register in the clock its producer commits sees the new value.          //
//                                                                          //
// The arrays keep the names dreg/areg/usp/isp/msp the milestone benches    //
// poke hierarchically.                                                     //
//--------------------------------------------------------------------------//

module ap040_pipe_regfile
(
	input             clk,
	input             ce,
	input             nreset,

	input             w0_we, input [4:0] w0_r, input [31:0] w0_d,
	input             u1_we, input [4:0] u1_r, input [31:0] u1_d,
	input             u0_we, input [4:0] u0_r, input [31:0] u0_d,

	input       [4:0] ra0, ra1, ra2, ra3, ra4, ra5, ra6, ra7,
	output     [31:0] rd0, rd1, rd2, rd3, rd4, rd5, rd6, rd7,

	output     [31:0] usp_q,
	output     [31:0] isp_q,
	output     [31:0] msp_q,

	output     [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3,
	output     [31:0] dbg_d4, dbg_d5, dbg_d6, dbg_d7,
	output     [31:0] dbg_a0
);

reg [31:0] dreg [0:7];
reg [31:0] areg [0:6];
reg [31:0] usp;
reg [31:0] isp;
reg [31:0] msp;

// Read ports as direct expressions, not a function: a function that reads
// the arrays breaks continuous-assignment sensitivity in Icarus (the
// milestone-2 note, still true).  The 32 registers' flat view is built once.
wire [31:0] flat [0:31];
genvar g;
generate
	for (g = 0; g < 8; g = g + 1) begin : gd assign flat[g] = dreg[g]; end
	for (g = 0; g < 7; g = g + 1) begin : ga assign flat[8 + g] = areg[g]; end
	for (g = 19; g < 32; g = g + 1) begin : gz assign flat[g] = 32'd0; end
endgenerate
assign flat[15] = 32'd0;
assign flat[16] = usp;
assign flat[17] = isp;
assign flat[18] = msp;

`define AP040_RF_RD(ra) ((w0_we && w0_r == (ra)) ? w0_d : (u1_we && u1_r == (ra)) ? u1_d : \
                         (u0_we && u0_r == (ra)) ? u0_d : flat[(ra)])
assign rd0 = `AP040_RF_RD(ra0);
assign rd1 = `AP040_RF_RD(ra1);
assign rd2 = `AP040_RF_RD(ra2);
assign rd3 = `AP040_RF_RD(ra3);
assign rd4 = `AP040_RF_RD(ra4);
assign rd5 = `AP040_RF_RD(ra5);
assign rd6 = `AP040_RF_RD(ra6);
assign rd7 = `AP040_RF_RD(ra7);
`undef AP040_RF_RD

task automatic wr(input [4:0] r, input [31:0] v);
	if (r[4:3] == 2'b00)                      dreg[r[2:0]] <= v;
	else if (r[4:3] == 2'b01 && r[2:0] != 7)  areg[r[2:0]] <= v;
	else if (r == 5'd16)                      usp <= v;
	else if (r == 5'd17)                      isp <= v;
	else if (r == 5'd18)                      msp <= v;
endtask

integer i;
always @(posedge clk) begin
	if (!nreset) begin
		for (i = 0; i < 8; i = i + 1) dreg[i] <= 0;
		for (i = 0; i < 7; i = i + 1) areg[i] <= 0;
		usp <= 0;
		isp <= 0;
		msp <= 0;
	end else if (ce) begin
		// lowest priority first: the later nonblocking write wins
		if (u0_we) wr(u0_r, u0_d);
		if (u1_we) wr(u1_r, u1_d);
		if (w0_we) wr(w0_r, w0_d);
	end
end

assign usp_q = usp;
assign isp_q = isp;
assign msp_q = msp;

assign dbg_d0 = dreg[0];
assign dbg_d1 = dreg[1];
assign dbg_d2 = dreg[2];
assign dbg_d3 = dreg[3];
assign dbg_d4 = dreg[4];
assign dbg_d5 = dreg[5];
assign dbg_d6 = dreg[6];
assign dbg_d7 = dreg[7];
assign dbg_a0 = areg[0];

endmodule
