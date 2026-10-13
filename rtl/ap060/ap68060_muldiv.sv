//--------------------------------------------------------------------------//
// AP68060 - pipelined MC68040                                            //
//                                                                          //
// ap68060_muldiv.sv - iterative multiply and divide (from AP040's          //
// ap040_muldiv.v, which the cputest corpus validated)                       //
//                                                                          //
// MUL: 32x32 -> 64, signed or unsigned, one registered DSP product        //
// DIV: 32/32 -> q32,r32 restoring, 2 bits per cycle (the 68060 has no     //
//      64-bit dividend: those forms trap); ovf for the one signed quotient //
//      that does not fit, -2^31 / -1.  Signed quotients truncate toward    //
//      zero, the remainder takes the dividend's sign.                       //
// kill abandons a running operation (pipeline flush).                       //
//--------------------------------------------------------------------------//

module ap68060_muldiv
(
	input             clk,
	input             nreset,
	input             kill,

	input             start,
	input             is_div,
	input             sign_op,
	input      [31:0] op_a,        // multiplier / divisor
	input      [31:0] op_lo,       // multiplicand / dividend

	output            busy,
	output reg        done,        // one cycle pulse
	output reg [31:0] res_hi,      // product high / remainder
	output reg [31:0] res_lo,      // product low / quotient
	output reg        ovf
);

reg        running;
reg        div_r;
reg        neg_q;                 // negate quotient / product
reg        neg_r;                 // negate remainder
reg  [6:0] count;
reg [31:0] den;                   // divisor / multiplier (absolute)
reg [31:0] mcand;                 // multiplicand (absolute)
reg [63:0] prod;                  // registered DSP product
reg [64:0] acc;                   // divide: remainder [64:32], dividend/quotient [31:0]

// absolute values for signed operations
wire [31:0] abs_a  = (sign_op && op_a[31]) ? (32'd0 - op_a) : op_a;
wire [31:0] abs_m  = (sign_op && op_lo[31]) ? (32'd0 - op_lo) : op_lo;   // also |dividend|

// divide: DSTEPS cascaded restoring steps per cycle (2: 32 bits in 16
// rounds, the 68060's own DIVU.L takes 38 clocks),
// each exactly one former one-bit iteration; the divisor is an explicit
// argument so the function stays pure (module-level variables read from
// inside a function are unreliable in continuous assignments under iverilog)
function [64:0] div_step;
	input [64:0] a;
	input [31:0] d;
	reg   [64:0] sh;
	reg   [33:0] t;
	begin
		sh = {a[63:0], 1'b0};
		t  = {1'b0, sh[64:32]} - {2'b00, d};
		if (!t[33]) div_step = {t[32:0], sh[31:1], 1'b1};
		else        div_step = sh;
	end
endfunction

localparam int DSTEPS = 2;
wire [64:0] div4 = (DSTEPS == 4) ? div_step(div_step(div_step(div_step(acc, den), den), den), den)
                                 : div_step(div_step(acc, den), den);

wire [63:0] q_raw = div_r ? {32'd0, acc[31:0]} : prod;
wire [31:0] r_raw = acc[63:32];

always @(posedge clk) begin
	if (!nreset) begin
		running <= 0;
		done    <= 0;
		div_r   <= 0;
		neg_q   <= 0;
		neg_r   <= 0;
		count   <= 0;
		den     <= 0;
		mcand   <= 0;
		prod    <= 0;
		acc     <= 0;
		res_hi  <= 0;
		res_lo  <= 0;
		ovf     <= 0;
	end
	else if (kill) begin
		running <= 1'b0;
		done    <= 1'b0;
	end
	else begin
		done <= 0;

		if (start) begin
			div_r   <= is_div;
			running <= 1;
			ovf     <= 0;
			if (is_div) begin
				den   <= abs_a;
				acc   <= {33'd0, abs_m};
				count <= 7'(32 / DSTEPS);
				neg_q <= sign_op && (op_lo[31] ^ op_a[31]);
				neg_r <= sign_op && op_lo[31];
			end
			else begin
				den   <= abs_a;
				mcand <= abs_m;
				count <= 7'd1;
				neg_q <= sign_op && (op_a[31] ^ op_lo[31]) && (op_a != 0) && (op_lo != 0);
				neg_r <= 0;
			end
		end
		else if (running) begin
			if (count != 0) begin
				count <= count - 7'd1;
				if (div_r) begin
					acc <= div4;
				end
				else begin
					// one registered 32x32 DSP-tree product, exactly the
					// value the former 32-cycle shift-add loop accumulated
					prod <= mcand * den;
				end
			end
			else begin
				running <= 1'b0;
				done    <= 1'b1;
				if (div_r) begin
					res_lo <= neg_q ? (32'd0 - q_raw[31:0]) : q_raw[31:0];
					res_hi <= neg_r ? (32'd0 - r_raw) : r_raw;
					ovf    <= sign_op & !neg_q & q_raw[31];
				end
				else begin
					res_lo <= neg_q ? (32'd0 - q_raw[31:0]) : q_raw[31:0];
					res_hi <= neg_q ? (~q_raw[63:32] + {31'd0, (q_raw[31:0] == 32'd0)})
					                : q_raw[63:32];
					ovf    <= 0;
				end
			end
		end
	end
end

assign busy = running;

endmodule
