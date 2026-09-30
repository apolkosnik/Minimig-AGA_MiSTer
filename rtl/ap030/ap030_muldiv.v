//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_muldiv.v - multiply and divide unit                                //
//                                                                          //
// MUL: 32x32 -> 64, signed or unsigned, one registered product             //
// DIV: 64/32 -> 32-bit quotient and remainder, restoring, four bits per     //
//      clock; ovf when the true quotient does not fit in 32 bits.  Signed  //
//      quotients truncate toward zero and the remainder takes the sign of   //
//      the dividend.                                                        //
// The core detects divide by zero and applies the 16-bit range checks of    //
// the word forms.                                                          //
//--------------------------------------------------------------------------//

module ap030_muldiv
(
	input             clk,
	input             rst,
	input             start,
	input             is_div,
	input             sign_op,
	input      [31:0] op_a,        // multiplier / divisor
	input      [31:0] op_hi,       // dividend high
	input      [31:0] op_lo,       // multiplicand / dividend low
	output reg        done,
	output reg [31:0] res_hi,      // product high / remainder
	output reg [31:0] res_lo,      // product low / quotient
	output reg        ovf
);

reg        running, div_r, neg_q, neg_r;
reg  [4:0] count;
reg [31:0] den, mcand;
reg [63:0] prod;
reg [96:0] acc;

wire [31:0] abs_a = (sign_op && op_a[31]) ? (32'd0 - op_a) : op_a;
wire [63:0] dvd   = {op_hi, op_lo};
wire [63:0] abs_d = (sign_op && op_hi[31]) ? (64'd0 - dvd) : dvd;
wire [31:0] abs_m = (sign_op && op_lo[31]) ? (32'd0 - op_lo) : op_lo;

function [96:0] div_step;
	input [96:0] a;
	input [31:0] d;
	reg   [96:0] sh;
	reg   [33:0] t;
	begin
		sh = {a[95:0], 1'b0};
		t  = {1'b0, sh[96:64]} - {2'b00, d};
		if (!t[33]) div_step = {t[32:0], sh[63:1], 1'b1};
		else        div_step = sh;
	end
endfunction

wire [96:0] div4  = div_step(div_step(div_step(div_step(acc, den), den), den), den);
wire [63:0] q_raw = div_r ? acc[63:0] : prod;
wire [31:0] r_raw = acc[95:64];

always @(posedge clk) begin
	if (rst) begin
		running <= 1'b0; done <= 1'b0; div_r <= 1'b0; neg_q <= 1'b0; neg_r <= 1'b0;
		count <= 5'd0; den <= 32'd0; mcand <= 32'd0; prod <= 64'd0; acc <= 97'd0;
		res_hi <= 32'd0; res_lo <= 32'd0; ovf <= 1'b0;
	end else begin
		done <= 1'b0;
		if (start) begin
			div_r <= is_div; running <= 1'b1; ovf <= 1'b0;
			den <= abs_a;
			if (is_div) begin
				acc <= {33'd0, abs_d};
				count <= 5'd16;
				neg_q <= sign_op && (op_hi[31] ^ op_a[31]);
				neg_r <= sign_op && op_hi[31];
			end else begin
				mcand <= abs_m;
				count <= 5'd1;
				neg_q <= sign_op && (op_a[31] ^ op_lo[31]) && (op_a != 0) && (op_lo != 0);
				neg_r <= 1'b0;
			end
		end else if (running) begin
			if (count != 0) begin
				count <= count - 5'd1;
				if (div_r) acc <= div4;
				else prod <= mcand * den;
			end else begin
				running <= 1'b0;
				done <= 1'b1;
				if (div_r) begin
					res_lo <= neg_q ? (32'd0 - q_raw[31:0]) : q_raw[31:0];
					res_hi <= neg_r ? (32'd0 - r_raw) : r_raw;
					ovf <= (|q_raw[63:32]) |
					       (sign_op & (neg_q ? (q_raw[31:0] > 32'h8000_0000) : q_raw[31]));
				end else begin
					res_lo <= neg_q ? (32'd0 - q_raw[31:0]) : q_raw[31:0];
					res_hi <= neg_q ? (~q_raw[63:32] + {31'd0, (q_raw[31:0] == 32'd0)}) : q_raw[63:32];
					ovf <= 1'b0;
				end
			end
		end
	end
end

endmodule
