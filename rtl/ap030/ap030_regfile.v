//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_regfile.v - D0-D7, A0-A6 and the three stack pointers              //
//                                                                          //
// Index 0..7 = D0..D7, 8..14 = A0..A6, 15 = A7 (USP/ISP/MSP by SR.S/SR.M). //
// Three combinational read ports, one write port (full 32 bits; the core   //
// merges byte and word results), direct access to the stack pointers for   //
// MOVE USP / MOVEC and the exception logic.                                //
//--------------------------------------------------------------------------//

module ap030_regfile
(
	input             clk,
	input             rst,
	input             sr_s,
	input             sr_m,

	input             we,
	input       [3:0] waddr,
	input       [1:0] wact,        // for waddr 15: the stack pointer A7 was when the write was issued
	input      [31:0] wdata,

	input       [3:0] raddr_a,
	output     [31:0] rdata_a,
	input       [3:0] raddr_b,
	output     [31:0] rdata_b,
	input       [3:0] raddr_c,
	output     [31:0] rdata_c,
	// dispatch ports: the operands of the instruction being dispatched
	// (separate, so the decoder is not in the paths of the other ports)
	input       [3:0] raddr_d,
	output     [31:0] rdata_d,
	input       [3:0] raddr_e,
	output     [31:0] rdata_e,

	// stack pointers not selected by SR (MOVE USP, MOVEC, RTE stack switch)
	input             sp_we,
	input       [1:0] sp_sel,      // 0 USP 1 ISP 2 MSP
	input      [31:0] sp_wdata,
	output     [31:0] usp_q,
	output     [31:0] isp_q,
	output     [31:0] msp_q
);

reg [31:0] r [0:14];
reg [31:0] usp, isp, msp;

wire [1:0] act = !sr_s ? 2'd0 : (sr_m ? 2'd2 : 2'd1);
wire [31:0] a7 = (act == 2'd0) ? usp : (act == 2'd1) ? isp : msp;

// a write is visible to reads in the same clock it is applied, so a value
// written by one state can be read by the next without a hazard
function [31:0] rd;
	input [3:0] i;
	begin
		// a pending A7 write is forwarded only to reads of the same stack pointer
		if (we && waddr == i && (i != 4'd15 || wact == act)) rd = wdata;
		else rd = (i == 4'd15) ? a7 : r[i];
	end
endfunction

assign rdata_a = rd(raddr_a);
assign rdata_b = rd(raddr_b);
assign rdata_c = rd(raddr_c);
assign rdata_d = rd(raddr_d);
assign rdata_e = rd(raddr_e);
assign usp_q = usp;
assign isp_q = isp;
assign msp_q = msp;

integer i;
always @(posedge clk) begin
	if (rst) begin
		for (i = 0; i < 15; i = i + 1) r[i] <= 32'd0;
		usp <= 32'd0; isp <= 32'd0; msp <= 32'd0;
	end else begin
		if (we) begin
			if (waddr == 4'd15) begin
				// the stack pointer selected when the write was issued: an RTE
				// pops its frame in the same clock it loads a new S/M
				case (wact)
					2'd0: usp <= wdata;
					2'd1: isp <= wdata;
					default: msp <= wdata;
				endcase
			end else r[waddr] <= wdata;
		end
		if (sp_we) begin
			case (sp_sel)
				2'd0: usp <= sp_wdata;
				2'd1: isp <= sp_wdata;
				default: msp <= sp_wdata;
			endcase
		end
	end
end

endmodule
