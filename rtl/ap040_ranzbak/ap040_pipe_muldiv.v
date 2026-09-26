//--------------------------------------------------------------------------//
// AP040_PIPE - ap040_pipe_muldiv.v: the long multiply and the divides      //
//                                                                          //
// Upstream forked the reference core's iterative unit (apolkosnik/AP68040  //
// rtl/ap040_muldiv.v): every multiply four clocks in EX, every divide      //
// twenty. This is ap040-pipelined's EX multiplier and divider             //
// (rtl/ap040_pipe/ap040_execute.v) behind the same ports:                  //
//                                                                          //
// MUL: 32x32 -> 64, unsigned or signed. The product is registered in the   //
//      clock start is taken, from the operands as they arrive, and done    //
//      follows: two clocks in EX. The word multiply does not come here --  //
//      ap040_execute.v forms it itself, in one.                            //
// DIV: 64/32 -> q32,r32, unsigned or signed, restoring, on magnitudes.     //
//      A quotient that needs more than 32 bits has a high dividend word    //
//      not below the divisor; that is checked at the start, so 32 steps    //
//      are enough, not 64: eight rounds of four. The last round forms the  //
//      signed results, and done follows it: ten clocks in EX, the same     //
//      as ap040-pipelined's divider.                                       //
//      ovf when the quotient does not fit 32 bits (signed: the magnitude   //
//      may reach 2^31 only when negative). The quotient truncates toward   //
//      zero; the remainder takes the DIVIDEND's sign.                      //
//                                                                          //
// The core detects divide by zero (it never starts one) and applies the    //
// word forms' 16-bit range checks. All state advances only when ce is     //
// high.                                                                    //
//--------------------------------------------------------------------------//

module ap040_pipe_muldiv
(
	input             clk,
	input             nreset,
	input             ce,

	input             start,       // one ce cycle pulse
	input             is_div,
	input             sign_op,
	input      [31:0] op_a,        // multiplier / divisor
	input      [31:0] op_hi,       // dividend high (div only)
	input      [31:0] op_lo,       // multiplicand / dividend low

	output reg        done,        // one ce cycle pulse
	output reg [31:0] res_hi,      // product high / remainder
	output reg [31:0] res_lo,      // product low / quotient
	output reg        ovf
);

// Four restoring steps a round, as ap040-pipelined's DIV_STEP: the chained
// compare-subtracts stay inside this unit's registers.
localparam integer DIV_STEP = 4;
localparam [3:0]   DIV_ROUNDS = 32 / DIV_STEP;
function [64:0] div_steps;   // {remainder[32:0], dividend/quotient[31:0]}
	input [32:0] rem;
	input [31:0] dvd;
	input [31:0] dsr;
	integer k;
	reg   [32:0] r, sh;
	reg   [31:0] d;
	begin
		r = rem; d = dvd;
		for (k = 0; k < DIV_STEP; k = k + 1) begin
			sh = {r[31:0], d[31]};
			if (sh >= {1'b0, dsr}) begin
				r = sh - {1'b0, dsr};
				d = {d[30:0], 1'b1};
			end else begin
				r = sh;
				d = {d[30:0], 1'b0};
			end
		end
		div_steps = {r, d};
	end
endfunction

// Divide: magnitudes at the start. The remainder starts from the dividend's
// high half; if that is not below the divisor the quotient cannot fit 32
// bits, which is the overflow, caught before the steps.
wire        dvd_neg = sign_op && op_hi[31];
wire        dsr_neg = sign_op && op_a[31];
wire [63:0] dvd_mag = dvd_neg ? (~{op_hi, op_lo} + 64'd1) : {op_hi, op_lo};
wire [31:0] dsr_mag = dsr_neg ? (~op_a + 32'd1) : op_a;

// Multiply: one DSP product of the operands as they arrive, signed or not.
wire [65:0] mul_c = $signed({sign_op && op_a[31], op_a}) * $signed({sign_op && op_lo[31], op_lo});

reg        running;
reg  [3:0] count;                 // rounds left
reg [32:0] div_rem;
reg [31:0] div_dvd;               // shifts left; its low bits collect the quotient
reg [31:0] div_dsr;
reg        div_qneg, div_rneg, div_sgn, div_pre;

wire [64:0] div_next = div_steps(div_rem, div_dvd, div_dsr);
wire [31:0] q_mag    = div_next[31:0];
wire [31:0] r_mag    = div_next[63:32];

always @(posedge clk) begin
	if (!nreset) begin
		running  <= 1'b0;
		done     <= 1'b0;
		count    <= 4'd0;
		div_rem  <= 33'd0;
		div_dvd  <= 32'd0;
		div_dsr  <= 32'd0;
		div_qneg <= 1'b0;
		div_rneg <= 1'b0;
		div_sgn  <= 1'b0;
		div_pre  <= 1'b0;
		res_hi   <= 32'd0;
		res_lo   <= 32'd0;
		ovf      <= 1'b0;
	end
	else if (ce) begin
		done <= 1'b0;
		if (start && !is_div) begin
			res_lo <= mul_c[31:0];
			res_hi <= mul_c[63:32];
			ovf    <= 1'b0;
			done   <= 1'b1;
		end
		else if (start) begin
			running  <= 1'b1;
			count    <= DIV_ROUNDS;
			div_rem  <= {1'b0, dvd_mag[63:32]};
			div_dvd  <= dvd_mag[31:0];
			div_dsr  <= dsr_mag;
			div_qneg <= dvd_neg ^ dsr_neg;
			div_rneg <= dvd_neg;
			div_sgn  <= sign_op;
			div_pre  <= (dvd_mag[63:32] >= dsr_mag);
		end
		else if (running) begin
			div_rem <= div_next[64:32];
			div_dvd <= div_next[31:0];
			count   <= count - 4'd1;
			if (count == 4'd1) begin
				running <= 1'b0;
				done    <= 1'b1;
				res_lo  <= div_qneg ? (~q_mag + 32'd1) : q_mag;
				res_hi  <= div_rneg ? (~r_mag + 32'd1) : r_mag;
				ovf     <= div_pre || (div_sgn && (div_qneg ? (q_mag > 32'h8000_0000) : q_mag[31]));
			end
		end
	end
end

endmodule
