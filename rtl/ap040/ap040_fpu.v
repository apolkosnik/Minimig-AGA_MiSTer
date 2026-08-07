//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_fpu.v - on-chip FPU (milestone H)                                  //
//                                                                          //
// Programming model: FP0-FP7 in extended precision (96-bit memory image,   //
// 80 significant bits), FPCR (mode + exception enables), FPSR (condition   //
// codes, quotient, exception and accrued bytes), FPIAR.                    //
//                                                                          //
// Implemented hardware subset: data movement and B/W/L/S/D/X conversion,  //
// FABS/FNEG/FTST/FCMP, and iterative FADD/FSUB/FMUL/FDIV/FSQRT with FPCR   //
// precision/rounding, FPSR status/accrual, signaling NaNs and enabled      //
// arithmetic-exception vectors. Single/double stores generate gradual      //
// underflow; unsupported denormal/unnormal inputs take vector 11.          //
//                                                                          //
// Transcendentals, packed decimal, FMOVECR and the remaining software      //
// subset assert `unimp`, following the 68040 FPSP route. FSAVE BUSY/UNIMP  //
// state frames remain a documented integration gap.                       //
//                                                                          //
// The core owns instruction decode, effective addresses and memory         //
// transfers; operands arrive left-aligned in a 96-bit window. FMOVEM       //
// traffic uses the raw register port (fm_*), architecturally exact bits    //
// with no condition code or rounding side effects.                         //
//                                                                          //
// All state advances only when ce is high (clkena discipline).             //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_fpu
(
	input             clk,
	input             nreset,
	input             ce,

	// command port: pulse req with the fields valid; done pulses on
	// completion, unimp pulses instead when the op is not in hardware
	input             req,
	input       [2:0] op_class,    // extension word [15:13]
	input       [6:0] opmode,      // extension word [6:0]
	input       [2:0] src_fmt,     // extension word [12:10] (opclass 2/3)
	input       [2:0] src_r,       // FPm
	input       [2:0] dst_r,       // FPn
	input      [95:0] din,         // memory operand, left aligned
	output reg        done,
	output reg        unimp,       // unimplemented instruction -> vector 11
	output reg        unsupp,      // unsupported data type -> vector 55
	output reg        exc_req,       // enabled arithmetic exception
	output reg [7:0]  exc_vec,
	output reg [95:0] dout,        // store result, left aligned

	output      [3:0] fpcc,        // FPSR condition codes {N,Z,I,NAN}

	// control registers (FMOVE/FMOVEM of FPCR/FPSR/FPIAR run in the core)
	input       [1:0] cr_sel,      // 0 FPIAR, 1 FPSR, 2 FPCR
	input             cr_we,
	input      [31:0] cr_wdata,
	output     [31:0] cr_rdata,
	input             bsun_req,     // signaling conditional on unordered
	output            bsun_enable,

	// FPIAR update on dispatch of an FP instruction (core provides PC)
	input             ia_we,
	input      [31:0] ia_wdata,

	// raw register port for FMOVEM (X format image, no side effects)
	input       [2:0] fm_sel,
	input             fm_we,
	input      [95:0] fm_wdata,
	output     [95:0] fm_rdata,

	// FSAVE/FRESTORE state
	output reg        fpu_used,    // 0: NULL frame, 1: IDLE frame
	input             fp_reset     // FRESTORE of a NULL frame
);

//---------------------------------------------------------------------------
// architectural state
//---------------------------------------------------------------------------

// FP registers as the 80 significant bits: {sign, exp[14:0], man[63:0]}
reg        fr_s [0:7];
reg [14:0] fr_e [0:7];
reg [63:0] fr_m [0:7];

reg [31:0] fpcr;                  // [15:8] enables, [7:6] prec, [5:4] rnd
reg [31:0] fpsr;                  // [27:24] cc, [23:16] quot, [15:8] exc, [7:3] aexc
reg [31:0] fpiar;

assign fpcc = fpsr[27:24];        // {N, Z, I, NAN}

wire [1:0] rnd_mode = fpcr[5:4];  // 00 RN, 01 RZ, 10 RM, 11 RP

assign cr_rdata = (cr_sel == 2'd0) ? fpiar :
                  (cr_sel == 2'd1) ? fpsr : fpcr;
assign bsun_enable = fpcr[15];

// raw FMOVEM image: X format memory layout {s, e, 16'b0, m}
assign fm_rdata = {fr_s[fm_sel], fr_e[fm_sel], 16'd0, fr_m[fm_sel]};

//---------------------------------------------------------------------------
// unpacked working format
//   value = (-1)^s * man * 2^(exp-16383), man[63] = integer bit
//   tag: 00 number (normalized here), 01 zero, 10 infinity, 11 NaN
//---------------------------------------------------------------------------

localparam T_NUM  = 2'd0;
localparam T_ZERO = 2'd1;
localparam T_INF  = 2'd2;
localparam T_NAN  = 2'd3;

// {s, e[16:0], m[63:0], t[1:0]} = 84 bits
function [83:0] unpack_x;
	input        s;
	input [14:0] e;
	input [63:0] m;
	reg    [1:0] t;
	begin
		if (e == 15'h7FFF) t = (m[62:0] != 63'd0) ? T_NAN : T_INF;
		else if (m == 64'd0) t = T_ZERO;
		else t = T_NUM;   // unnormals arrive here and are normalized below
		unpack_x = {s, {2'd0, e}, m, t};
	end
endfunction

// Only TRUE denormals (zero exponent, integer bit clear, nonzero
// fraction) and true unnormals (nonzero finite exponent, integer bit
// clear, nonzero mantissa) take the unimplemented-data-type route.
// PSEUDO-DENORMALS -- zero exponent with the integer bit SET -- are
// legal operands the hardware computes with directly, using the RAW
// exponent field (floatx80_is_denormal requires the integer bit clear;
// hardware cputest FDIV/FDADD with $0000-8xxx operands executes).
// Unnormal ZEROS (nonzero exponent, mantissa zero) behave as zeros.
function unsupported_x;
	input [14:0] e;
	input [63:0] m;
	begin
		unsupported_x = ((e == 15'd0) && !m[63] && (m[62:0] != 0)) ||
		                ((e != 15'd0) && (e != 15'h7FFF) && !m[63] &&
		                 (m != 64'd0));
	end
endfunction

function is_snan_x;
	input [14:0] e;
	input [63:0] m;
	begin
		is_snan_x = (e == 15'h7FFF) && (m[62:0] != 63'd0) && !m[62];
	end
endfunction

// count leading zeros of a 64-bit value (fixed encoder, no shifters)
function [6:0] clz64;
	input [63:0] v;
	integer i;
	begin
		clz64 = 7'd64;
		for (i = 0; i < 64; i = i + 1)
			if (v[i]) clz64 = 7'd63 - i[6:0];
	end
endfunction

//---------------------------------------------------------------------------
// FSM
//---------------------------------------------------------------------------

localparam F_IDLE  = 4'd0;
localparam F_SRC   = 4'd1;   // classify/convert the memory operand
localparam F_NORM  = 4'd2;   // normalize integer or denormal sources
localparam F_EXEC  = 4'd3;   // move/abs/neg/tst/cmp/arith dispatch
localparam F_WB    = 4'd4;   // register writeback + condition codes
localparam F_SHR   = 4'd5;   // staged right shift for integer stores
localparam F_PACKI = 4'd6;   // integer store rounding and assembly
localparam F_BIN   = 4'd7;   // binary op specials and setup
localparam F_ADDX  = 4'd9;   // mantissa add/subtract
localparam F_MULT  = 4'd10;  // multiply loop
localparam F_DIVL  = 4'd11;  // divide loop
localparam F_SQRTL = 4'd12;  // square root loop
localparam F_NORM2 = 4'd13;  // post-operation normalize
localparam F_ROUND = 4'd14;  // precision rounding and range checks
localparam F_PACKS = 4'd15;  // denormal single/double store packing
localparam F_UNFL  = 5'd16;  // gradual underflow at single/double precision

reg  [4:0] fst;
reg  [2:0] r_fmt, r_dst;
reg        r_src_x;         // source operand arrived in extended format
reg        r_ae7;           // accrued-IOP before this instruction (fault backout)
reg  [6:0] r_op;
reg [95:0] r_din;

// operand/result in working format
reg         a_s;
reg  [16:0] a_e;
reg  [63:0] a_m;
reg   [1:0] a_t;

// staged shifter: mantissa with 3 rounding bits {G,R,S}, count up to 127
reg [66:0] sh_v;              // {m[63:0], G, R, S}
reg  [6:0] sh_cnt;

// second (destination) operand and arithmetic scratch
reg         b_s;
reg  [16:0] b_e;
reg  [63:0] b_m;
reg   [1:0] b_t;
reg   [2:0] grs;              // result rounding bits before F_ROUND
reg         eff_sub;          // effective magnitude subtract
reg  [64:0] acc_hi;           // multiply accumulator high / divide remainder
reg  [63:0] acc_lo;           // multiply accumulator low / dividend feed
reg  [66:0] qv;               // divide quotient / sqrt root
reg  [68:0] srem;             // sqrt remainder
reg [131:0] srad;             // sqrt radicand feed
reg   [6:0] loop_n;
reg   [3:0] op_kind;          // 0 none, 1 add, 2 mul, 3 div, 4 sqrt
reg   [4:0] sh_ret;           // staged shifter return state
reg   [1:0] r_pr;             // rounding precision latched for F_UNFL
reg signed [17:0] e_w;        // working exponent (wrap safe)

// integer store bookkeeping
reg        pk_neg;
reg  [1:0] pk_isz;            // 0 byte, 1 word, 2 long

// hardware subset at this stage: move/abs/neg/tst/cmp families
function op_in_hw;
	input [6:0] op;
	begin
		case (op)
			7'h00, 7'h40, 7'h44,          // FMOVE, FSMOVE, FDMOVE
			7'h18, 7'h58, 7'h5C,          // FABS, FSABS, FDABS
			7'h1A, 7'h5A, 7'h5E,          // FNEG, FSNEG, FDNEG
			7'h38, 7'h3A,                 // FCMP, FTST
			7'h22, 7'h62, 7'h66,          // FADD, FSADD, FDADD
			7'h28, 7'h68, 7'h6C,          // FSUB, FSSUB, FDSUB
			7'h23, 7'h27, 7'h63, 7'h67,   // FMUL, FSGLMUL, FSMUL, FDMUL
			7'h20, 7'h24, 7'h60, 7'h64,   // FDIV, FSGLDIV, FSDIV, FDDIV
			7'h04, 7'h41, 7'h45:          // FSQRT, FSSQRT, FDSQRT
				op_in_hw = 1;
			default:
				op_in_hw = 0;
		endcase
	end
endfunction

// result precision for an opmode: 0 extended (per FPCR), 1 single, 2 double
function [1:0] prec_of;
	input [6:0] op;
	begin
		if (op == 7'h24 || op == 7'h27) prec_of = 2'd1;   // FSGLDIV/FSGLMUL
		else if (op >= 7'h40) prec_of = op[2] ? 2'd2 : 2'd1;
		// FPCR rounding precision: 00 extended, 01 single, 10 double, and
		// the reserved encoding 11 rounds as double (softfloat's 68k glue
		// falls through its default into the double case, and hardware
		// cputest agrees).
		else prec_of = (fpcr[7:6] == 2'b01) ? 2'd1 :
		               (fpcr[7:6] == 2'b00) ? 2'd0 : 2'd2;
	end
endfunction

// FABS and FNEG round their result to the selected precision but do not
// report it as inexact WHEN THE SOURCE IS ALREADY EXTENDED.  The PRM's
// FABS and FNEG pages list INEX2 as "Cleared" with no qualifying
// condition, but hardware cputest is narrower than that:
//   fabs.x fp1,fp0  FPCR $D0  rounds to double, expects FPSR $00000000
//   fabs.d (a0),fp2 FPCR $40  rounds to single, expects FPSR $00000208
// Both roundings discard bits, so the discriminator is the source format,
// not the instruction alone: a source that needs converting runs through
// the rounder normally, while an extended source is pure sign handling.
// Callers must therefore qualify this with r_src_x.  FMOVE is not exempt
// at all (its page sets INEX2 "if <fmt> is L, D, or X").
function op_no_inex;
	input [6:0] op;
	begin
		op_no_inex = (op == 7'h18) || (op == 7'h58) || (op == 7'h5C) ||
		             (op == 7'h1A) || (op == 7'h5A) || (op == 7'h5E);
	end
endfunction

// FSGLMUL and FSGLDIV round the significand to single precision but keep
// the EXTENDED exponent range: they go through roundSigAndPackFloatx80,
// which has no expOffset, unlike the roundAndPackFloatx80 used by every
// FPCR-precision and FS/FD operation.  Their overflow saturation value is
// the full all-ones mantissa at the extended maximum, again unlike the
// masked significand roundAndPackFloatx80 produces.
function op_sgl;
	input [6:0] op;
	begin
		op_sgl = (op == 7'h24) || (op == 7'h27);
	end
endfunction

// IEEE round-up decision from {lsb, G, R|S} and sign
function round_up;
	input       lsb, g, rs;
	input       sign;
	begin
		case (rnd_mode)
			2'b00:   round_up = g && (rs || lsb);   // nearest even
			2'b01:   round_up = 1'b0;               // toward zero
			2'b10:   round_up = sign && (g || rs);  // toward minus
			default: round_up = !sign && (g || rs); // toward plus
		endcase
	end
endfunction

// Highest-priority enabled FPSR exception, matching the architectural
// vector assignment.  Input bit 7 is BSUN and bit 0 is INEX1.
function [7:0] fp_exception_vector;
	input [7:0] ex;
	begin
		if      (ex[7]) fp_exception_vector = `AP040_VEC_FP_BSUN;
		else if (ex[6]) fp_exception_vector = `AP040_VEC_FP_SNAN;
		else if (ex[5]) fp_exception_vector = `AP040_VEC_FP_OPERR;
		else if (ex[4]) fp_exception_vector = `AP040_VEC_FP_OVFL;
		else if (ex[3]) fp_exception_vector = `AP040_VEC_FP_UNFL;
		else if (ex[2]) fp_exception_vector = `AP040_VEC_FP_DZ;
		else             fp_exception_vector = `AP040_VEC_FP_INEX;
	end
endfunction

integer k;

always @(posedge clk) begin
	if (!nreset) begin
		fst <= F_IDLE;
		done <= 0; unimp <= 0; unsupp <= 0; exc_req <= 0; exc_vec <= 0;
		fpcr <= 0; fpsr <= 0; fpiar <= 0;
		fpu_used <= 0;
		dout <= 0;
		r_fmt <= 0; r_dst <= 0; r_op <= 0; r_din <= 0;
		r_src_x <= 0; r_ae7 <= 0;
		a_s <= 0; a_e <= 0; a_m <= 0; a_t <= 0;
		sh_v <= 0; sh_cnt <= 0;
		pk_neg <= 0; pk_isz <= 0;
		b_s <= 0; b_e <= 0; b_m <= 0; b_t <= 0;
		grs <= 0; eff_sub <= 0; acc_hi <= 0; acc_lo <= 0;
		qv <= 0; srem <= 0; srad <= 0; loop_n <= 0; op_kind <= 0;
		sh_ret <= F_PACKI; e_w <= 0; r_pr <= 0;
		for (k = 0; k < 8; k = k + 1) begin
			fr_s[k] <= 0; fr_e[k] <= 0; fr_m[k] <= 0;
		end
	end
	else if (ce) begin
		done <= 0;
		unimp <= 0;
		unsupp <= 0;
		exc_req <= 0;

		// side ports, independent of the FSM
		if (cr_we) begin
			case (cr_sel)
				2'd0: fpiar <= cr_wdata;
				2'd1: fpsr <= cr_wdata & 32'h0FFF_FFF8;
				// 68040 FPCR keeps bits 15:0 (WinUAE fpcr_mask = 0xffff for
				// the 040; only 6888x/060 mask the low nibble)
				default: fpcr <= cr_wdata & 32'h0000_FFFF;
			endcase
			fpu_used <= 1;
		end
		if (ia_we) fpiar <= ia_wdata;
		if (bsun_req) begin
			fpsr[15] <= 1;
			fpsr[7] <= 1;
			fpu_used <= 1;
		end
		if (fm_we) begin
			fr_s[fm_sel] <= fm_wdata[95];
			fr_e[fm_sel] <= fm_wdata[94:80];
			fr_m[fm_sel] <= fm_wdata[63:0];
			fpu_used <= 1;
		end
		if (fp_reset) begin
			fpcr <= 0; fpsr <= 0; fpiar <= 0;
			fpu_used <= 0;
		end

		case (fst)
			F_IDLE: if (req) begin
				// FPSR exception status is per instruction.  The accrued
				// exception byte is intentionally retained until software
				// writes FPSR.  FMOVECR (opclass 010 fmt 7) faults before
				// WinUAE's fpsr_clear_status runs, so it must leave the
				// exception byte untouched; nonexisting opmodes never reach
				// the FPU at all (classified in the core).
				if (!(op_class == 3'b010 && src_fmt == 3'd7))
					fpsr[15:8] <= 8'd0;
				r_fmt <= src_fmt;
				r_src_x <= (op_class == 3'b000) || (src_fmt == 3'd2);
				r_ae7 <= fpsr[7];
				r_dst <= dst_r;
				r_op <= opmode;
				r_din <= din;
				if (op_class == 3'b011) begin
					// FMOVE FPn,<ea>: packed decimal and denormal/unnormal
					// register contents are unsupported data types
					if (src_fmt == 3'd3 || src_fmt == 3'd7) unsupp <= 1;
					else if (unsupported_x(fr_e[src_r], fr_m[src_r])) unsupp <= 1;
					else begin
						{a_s, a_e, a_m, a_t} <=
							unpack_x(fr_s[src_r], fr_e[src_r], fr_m[src_r]);
						fst <= F_SRC;   // F_SRC routes stores via r_op = STORE
						r_op <= 7'h7F;  // internal: store
					end
				end
				else if (!op_in_hw(opmode)) unimp <= 1;
				else if (op_class == 3'b000) begin
					if (unsupported_x(fr_e[src_r], fr_m[src_r])) begin
						unsupp <= 1;
					end
					else begin
					{a_s, a_e, a_m, a_t} <=
						unpack_x(fr_s[src_r], fr_e[src_r], fr_m[src_r]);
					fst <= F_EXEC;
					end
				end
				else begin
					// opclass 010, memory source: packed decimal (fmt 3) is
					// an unsupported data type, FMOVECR (fmt 7) is an
					// unimplemented instruction
					if (src_fmt == 3'd3) unsupp <= 1;
					else if (src_fmt == 3'd7) unimp <= 1;
					else begin
						a_t <= T_NUM;   // provisional; F_SRC classifies
						fst <= F_SRC;
					end
				end
			end

			F_SRC: begin : f_src
				if (r_op == 7'h7F) begin : f_store
					// register store: X is raw; S/D pack directly (fixed
					// rounding bit positions); B/W/L go through the shifter
					case (r_fmt)
						3'd2: begin
							dout <= {a_s, a_e[14:0], 16'd0, a_m};
							done <= 1; fpu_used <= 1; fst <= F_IDLE;
						end
						3'd1: begin : pk_s
							reg [24:0] mr;
							reg [16:0] eun;
							reg signed [17:0] sE, den_sh;
							reg inx, tomax;
							if (a_t != T_NUM) begin
								// NaN payload passes through commonNaN form:
								// the quiet bit is FORCED in the output and a
								// signaling source raises SNAN
								dout <= (a_t == T_ZERO) ? {a_s, 95'd0} :
								        (a_t == T_INF)  ? {a_s, 8'hFF, 23'd0, 64'd0} :
								                          {a_s, 8'hFF,
								                           a_m[62:40] | 23'h400000, 64'd0};
								if (a_t == T_NAN && !a_m[62]) begin
									fpsr[14] <= 1;
									fpsr[7]  <= 1;
								end
								done <= 1; fpu_used <= 1; fst <= F_IDLE;
							end
							else begin
								sE = $signed({1'b0, a_e}) - 18'sd16383;
								if (sE < -18'sd126) begin
									// Shift into the IEEE single denormal range, retaining
									// G/R/S for the selected rounding mode.
									den_sh = -18'sd126 - sE;
									sh_v <= {a_m, 3'd0};
									sh_cnt <= (den_sh > 18'sd127) ? 7'd127 : den_sh[6:0];
									sh_ret <= F_PACKS;
									fst <= F_SHR;
								end
								else begin
								mr = {1'b0, a_m[63:40]} +
								     {24'd0, round_up(a_m[40], a_m[39],
								                      (a_m[38:0] != 0), a_s)};
								inx = a_m[39:0] != 0;
								eun = a_e + {16'd0, mr[24]};       // renorm on carry
								if (mr[24]) mr = {1'b0, 1'b1, 23'd0};
								if ($signed({1'b0, eun}) - 18'sd16383 > 18'sd127) begin
									tomax = (rnd_mode == 2'b01) ||
									        (rnd_mode == 2'b10 && !a_s) ||
									        (rnd_mode == 2'b11 && a_s);
									dout <= tomax ? {a_s, 8'hFE, 23'h7FFFFF, 64'd0} :
									                 {a_s, 8'hFF, 23'd0, 64'd0};
									fpsr[12] <= 1; fpsr[6] <= 1;
									fpsr[9] <= 1;  fpsr[3] <= 1;
								end
								else begin : pk_s_enc
									reg [16:0] enc;
									enc = eun - 17'd16256;   // -16383 +127
									dout <= {a_s, enc[7:0], mr[22:0], 64'd0};
									if (inx) begin fpsr[9] <= 1; fpsr[3] <= 1; end
								end
								done <= 1; fpu_used <= 1; fst <= F_IDLE;
								end
							end
						end
						3'd5: begin : pk_d
							reg [53:0] mr;
							reg [16:0] eun;
							reg signed [17:0] sE, den_sh;
							reg inx, tomax;
							if (a_t != T_NUM) begin
								dout <= (a_t == T_ZERO) ? {a_s, 95'd0} :
								        (a_t == T_INF)  ? {a_s, 11'h7FF, 52'd0, 32'd0} :
								                          {a_s, 11'h7FF,
								                           a_m[62:11] | 52'h8_0000_0000_0000,
								                           32'd0};
								if (a_t == T_NAN && !a_m[62]) begin
									fpsr[14] <= 1;
									fpsr[7]  <= 1;
								end
								done <= 1; fpu_used <= 1; fst <= F_IDLE;
							end
							else begin
								sE = $signed({1'b0, a_e}) - 18'sd16383;
								if (sE < -18'sd1022) begin
									den_sh = -18'sd1022 - sE;
									sh_v <= {a_m, 3'd0};
									sh_cnt <= (den_sh > 18'sd127) ? 7'd127 : den_sh[6:0];
									sh_ret <= F_PACKS;
									fst <= F_SHR;
								end
								else begin
								mr = {1'b0, a_m[63:11]} +
								     {53'd0, round_up(a_m[11], a_m[10],
								                      (a_m[9:0] != 0), a_s)};
								inx = a_m[10:0] != 0;
								eun = a_e + {16'd0, mr[53]};
								if (mr[53]) mr = {1'b0, 1'b1, 52'd0};
								if ($signed({1'b0, eun}) - 18'sd16383 > 18'sd1023) begin
									tomax = (rnd_mode == 2'b01) ||
									        (rnd_mode == 2'b10 && !a_s) ||
									        (rnd_mode == 2'b11 && a_s);
									dout <= tomax ? {a_s, 11'h7FE, 52'hFFFFFFFFFFFFF, 32'd0} :
									                 {a_s, 11'h7FF, 52'd0, 32'd0};
									fpsr[12] <= 1; fpsr[6] <= 1;
									fpsr[9] <= 1;  fpsr[3] <= 1;
								end
								else begin : pk_d_enc
									reg [16:0] enc;
									enc = eun - 17'd15360;   // -16383 +1023
									dout <= {a_s, enc[10:0], mr[51:0], 32'd0};
									if (inx) begin fpsr[9] <= 1; fpsr[3] <= 1; end
								end
								done <= 1; fpu_used <= 1; fst <= F_IDLE;
								end
							end
						end
						default: begin : pk_i
							// B/W/L: shift the mantissa so the integer part
							// lands in sh_v[66:3]; E = a_e - 16383 is the
							// position of the integer bit
							reg signed [17:0] sE;
							reg [63:0] qm;
							pk_isz <= (r_fmt == 3'd0) ? 2'd2 :
							          (r_fmt == 3'd4) ? 2'd1 : 2'd0;
							pk_neg <= a_s;
							sE = $signed({1'b0, a_e}) - 18'sd16383;
							qm = a_m | 64'h4000_0000_0000_0000;
							if (a_t == T_ZERO) begin
								sh_v <= 0; sh_cnt <= 0; fst <= F_PACKI;
							end
							else if (a_t == T_NAN) begin
								// floatx80_to_int32/16/8: the QUIETED NaN's
								// top payload bits are stored; OPERR is only
								// raised for an already-quiet NaN, a
								// signaling one raises SNAN instead
								dout <= {(r_fmt == 3'd0) ? qm[63:32] :
								         (r_fmt == 3'd4) ? {qm[63:48], 16'd0} :
								                           {qm[63:56], 24'd0}, 64'd0};
								if (!a_m[62]) begin
									fpsr[14] <= 1;
									fpsr[7]  <= 1;
								end
								else begin
									fpsr[13] <= 1;
									fpsr[7]  <= 1;
								end
								done <= 1; fpu_used <= 1; fst <= F_IDLE;
							end
							else if (a_t == T_INF || sE > 18'sd62) begin
								// infinity or far out of range: OPERR with
								// sign-dependent saturation
								sh_v <= 67'h7FFFFFFFFFFFFFFFF;
								sh_cnt <= 7'd127;   // marker
								fst <= F_PACKI;
							end
							else if (sE < -18'sd1) begin
								sh_v <= {64'd0, 1'b0, 1'b0, 1'b1};  // sticky only
								sh_cnt <= 0; fst <= F_PACKI;
							end
							else begin
								sh_v <= {a_m, 3'd0};
								sh_cnt <= 7'd63 - sE[6:0];
								sh_ret <= F_PACKI;
								fst <= F_SHR;
							end
						end
					endcase
				end
				else begin : f_load
					// memory operand to working format
					case (r_fmt)
						3'd0: begin : cv_l
							a_s <= r_din[95];
							a_t <= (r_din[95:64] == 32'd0) ? T_ZERO : T_NUM;
							a_m <= {(r_din[95] ? (32'd0 - r_din[95:64])
							                   : r_din[95:64]), 32'd0};
							a_e <= 17'd16383 + 17'd31;   // integer bit at 63
							fst <= F_NORM;
						end
						3'd4: begin : cv_w
							a_s <= r_din[95];
							a_t <= (r_din[95:80] == 16'd0) ? T_ZERO : T_NUM;
							a_m <= {(r_din[95] ? (16'd0 - r_din[95:80])
							                   : r_din[95:80]), 48'd0};
							a_e <= 17'd16383 + 17'd15;
							fst <= F_NORM;
						end
						3'd6: begin : cv_b
							a_s <= r_din[95];
							a_t <= (r_din[95:88] == 8'd0) ? T_ZERO : T_NUM;
							a_m <= {(r_din[95] ? (8'd0 - r_din[95:88])
							                   : r_din[95:88]), 56'd0};
							a_e <= 17'd16383 + 17'd7;
							fst <= F_NORM;
						end
						3'd1: begin : cv_s
							a_s <= r_din[95];
							if (r_din[94:87] == 8'hFF) begin
								a_t <= (r_din[86:64] != 0) ? T_NAN : T_INF;
								a_e <= 17'h07FFF;
								// 68040 extended NaNs are unnormal: preserve the
								// source payload and leave the explicit integer bit clear.
								// (The quiet bit is bit 62 and is set below for an
								// SNaN.)  Infinity is canonicalized during writeback.
								a_m <= {1'b0, r_din[86:64], 40'd0};
								fst <= F_EXEC;
							end
							else if (r_din[94:87] == 8'd0) begin
								if (r_din[86:64] != 0) begin
									// denormalized single: an unsupported
									// data type (vector 55), not an
									// unimplemented instruction
									unsupp <= 1;
									fst <= F_IDLE;
								end
								else begin
									a_t <= T_ZERO;
									a_m <= 0;
									a_e <= 0;
									fst <= F_EXEC;
								end
							end
							else begin
								a_t <= T_NUM;
								a_e <= {9'd0, r_din[94:87]} + 17'd16256; // -127+16383
								a_m <= {1'b1, r_din[86:64], 40'd0};
								fst <= F_EXEC;
							end
						end
						3'd5: begin : cv_d
							a_s <= r_din[95];
							if (r_din[94:84] == 11'h7FF) begin
								a_t <= (r_din[83:32] != 0) ? T_NAN : T_INF;
								a_e <= 17'h07FFF;
								// Match the 68040 NaN encoding: bit 63 remains clear;
								// only the payload (and, when needed, quiet bit 62) is
								// carried into the extended significand.
								a_m <= {1'b0, r_din[83:32], 11'd0};
								fst <= F_EXEC;
							end
							else if (r_din[94:84] == 11'd0) begin
								if (r_din[83:32] != 0) begin
									// denormalized double: likewise the
									// data type trap, vector 55
									unsupp <= 1;
									fst <= F_IDLE;
								end
								else begin
									a_t <= T_ZERO;
									a_m <= 0;
									a_e <= 0;
									fst <= F_EXEC;
								end
							end
							else begin
								a_t <= T_NUM;
								a_e <= {6'd0, r_din[94:84]} + 17'd15360; // -1023+16383
								a_m <= {1'b1, r_din[83:32], 11'd0};
								fst <= F_EXEC;
							end
						end
						default: begin : cv_x
							if (unsupported_x(r_din[94:80], r_din[63:0])) begin
								unsupp <= 1;
								fst <= F_IDLE;
							end
							else begin
								{a_s, a_e, a_m, a_t} <=
									unpack_x(r_din[95], r_din[94:80], r_din[63:0]);
								fst <= F_NORM;
							end
						end
					endcase
				end
			end

			F_NORM: begin : f_norm
				reg [6:0] lz;
				lz = clz64(a_m);
				if (a_t != T_NUM) fst <= F_EXEC;
				else if (a_m == 64'd0) begin
					a_t <= T_ZERO; a_e <= 0;
					fst <= F_EXEC;
				end
				else begin
					a_m <= a_m << lz;
					a_e <= a_e - {10'd0, lz};
					fst <= F_EXEC;
				end
			end

			F_EXEC: begin
				// FCMP evaluates its destination without passing through
				// F_BIN, so its unsupported-datatype check lives here -- and
				// it must precede the SNaN bookkeeping: the datatype fault
				// is taken before the arithmetic ever inspects a NaN, so the
				// status byte stays clean.
				if (r_op == 7'h38 &&
				    unsupported_x(fr_e[r_dst], fr_m[r_dst])) begin
					unsupp <= 1;
					fst <= F_IDLE;
				end
				else begin
				// Quiet signaling NaNs after recording SNAN.  Source and
				// FCMP destination checks occur before result dispatch so an
				// enabled SNAN is observed in F_WB and inhibits writeback.
				if (a_t == T_NAN && !a_m[62]) begin
					a_m[62] <= 1;
					fpsr[14] <= 1;
					fpsr[7] <= 1;
				end
				if (r_op == 7'h38 &&
				    is_snan_x(fr_e[r_dst], fr_m[r_dst])) begin
					fpsr[14] <= 1;
					fpsr[7] <= 1;
				end
				case (r_op)
					7'h18, 7'h58, 7'h5C:
						if (a_t != T_NAN) a_s <= 0;                       // FABS
					7'h1A, 7'h5A, 7'h5E:
						if (a_t != T_NAN) a_s <= ~a_s;                    // FNEG
					default: ;
				endcase
				grs <= 3'd0;
				e_w <= $signed({1'b0, a_e});
				case (r_op)
					7'h38, 7'h3A: fst <= F_WB;               // FCMP/FTST
					7'h00, 7'h40, 7'h44,
					7'h18, 7'h58, 7'h5C,
					7'h1A, 7'h5A, 7'h5E: fst <= F_ROUND;     // move class
					7'h04, 7'h41, 7'h45: begin               // FSQRT
						op_kind <= 4'd4;
						fst <= F_BIN;
					end
					default: begin : ex_bin
						{b_s, b_e, b_m, b_t} <=
							unpack_x(fr_s[r_dst], fr_e[r_dst], fr_m[r_dst]);
						op_kind <= (r_op == 7'h23 || r_op == 7'h27 ||
						            r_op == 7'h63 || r_op == 7'h67) ? 4'd2 :
						           (r_op == 7'h20 || r_op == 7'h24 ||
						            r_op == 7'h60 || r_op == 7'h64) ? 4'd3 : 4'd1;
						fst <= F_BIN;
					end
				endcase
				end
			end

			F_BIN: begin : f_bin
				reg        s_a;
				// FSUB family: fold the source sign
				s_a = (op_kind == 4'd1 &&
				       (r_op == 7'h28 || r_op == 7'h68 || r_op == 7'h6C))
				      ? ~a_s : a_s;
				if (op_kind != 4'd4 &&
				    unsupported_x(b_e[14:0], b_m)) begin
					// The destination datatype fault is taken with a clean
					// status byte: undo the source-SNaN record F_EXEC made a
					// cycle earlier (the exception byte was zeroed at
					// dispatch; r_ae7 holds the prior accrued-IOP bit)
					fpsr[14] <= 0;
					fpsr[7]  <= r_ae7;
					unsupp <= 1;
					fst <= F_IDLE;
				end
				else begin
				if (op_kind != 4'd4 && b_t == T_NAN && !b_m[62]) begin
					fpsr[14] <= 1;
					fpsr[7] <= 1;
					b_m[62] <= 1;
				end
				if (a_t == T_NAN || (op_kind != 4'd4 && b_t == T_NAN)) begin
					// NaN propagation, destination NaN preferred
					if (op_kind != 4'd4 && b_t == T_NAN) begin
						a_s <= b_s;
						a_e <= b_e;
						a_m <= b_m | 64'h4000_0000_0000_0000;
					end
					else a_m <= a_m | 64'h4000_0000_0000_0000;
					a_t <= T_NAN;
					fst <= F_WB;
				end
				else case (op_kind)
					4'd4: begin : bin_sqrt
						if (a_t == T_ZERO) fst <= F_WB;         // sqrt(+-0)=+-0
						else if (a_s) begin
							// negative: operand error, POSITIVE default NaN
							// (floatx80_default_nan has the sign bit clear)
							a_t <= T_NAN;
							a_s <= 0;
							a_m <= 64'hFFFF_FFFF_FFFF_FFFF;
							a_e <= 17'h07FFF;
							fpsr[13] <= 1;
							fpsr[7] <= 1;
							fst <= F_WB;
						end
						else if (a_t == T_INF) fst <= F_WB;
						else begin : sq_go
							reg signed [17:0] sE;
							sE = $signed({1'b0, a_e}) - 18'sd16383;
							e_w <= (sE >>> 1) + 18'sd16383;
							if (a_m == 64'h8000_0000_0000_0000 && !sE[0]) begin
								// Exact square root of an even power of two.
								grs <= 0;
								fst <= F_ROUND;
							end
							else begin
								srad <= sE[0] ? {a_m, 1'b0, 67'd0}
								              : {1'b0, a_m, 67'd0};
								srem <= 0;
								qv <= 0;
								loop_n <= 0;
								fst <= F_SQRTL;
							end
						end
					end
					4'd1: begin : bin_add
						if (a_t == T_INF || b_t == T_INF) begin
							if (a_t == T_INF && b_t == T_INF &&
							    s_a != b_s) begin
								a_t <= T_NAN;      // inf - inf: default NaN
								a_s <= 0;
								a_m <= 64'hFFFF_FFFF_FFFF_FFFF;
								a_e <= 17'h07FFF;
								fpsr[13] <= 1;
								fpsr[7] <= 1;
							end
							else begin
								// both-inf same sign returns the DEST operand
								// raw (68040 has addsub_swap_inf clear); a
								// lone infinity keeps its own mantissa bits
								a_s <= (a_t == T_INF && b_t != T_INF) ? s_a : b_s;
								a_m <= (b_t == T_INF) ? b_m : a_m;
								a_t <= T_INF;
							end
							fst <= F_WB;
						end
						else if (a_t == T_ZERO && b_t == T_ZERO) begin
							a_s <= (s_a == b_s) ? s_a : (rnd_mode == 2'b10);
							a_t <= T_ZERO;
							fst <= F_WB;
						end
						else if (a_t == T_ZERO) begin
							a_s <= b_s;
							a_e <= b_e;
							a_m <= b_m;
							a_t <= T_NUM;
							e_w <= $signed({1'b0, b_e});
							fst <= F_ROUND;
						end
						else if (b_t == T_ZERO) begin
							a_s <= s_a;
							e_w <= $signed({1'b0, a_e});
							fst <= F_ROUND;
						end
						else begin : bin_addnum
							reg        aswap;
							reg [16:0] d;
							aswap = (a_e > b_e) ||
							        (a_e == b_e && a_m > b_m);
							eff_sub <= (s_a != b_s);
							if (aswap) begin
								b_s <= s_a; b_e <= a_e; b_m <= a_m;
								a_s <= b_s; a_e <= b_e; a_m <= b_m;
								d = a_e - b_e;
								e_w <= $signed({1'b0, a_e});
							end
							else begin
								a_s <= s_a;
								d = b_e - a_e;
								e_w <= $signed({1'b0, b_e});
							end
							sh_v <= {aswap ? b_m : a_m, 3'd0};
							sh_cnt <= (d > 17'd66) ? 7'd67 : d[6:0];
							sh_ret <= F_ADDX;
							fst <= F_SHR;
						end
					end
					4'd2: begin : bin_mul
						reg [63:0] am_eff, bm_eff;
						am_eff = (r_op == 7'h27) ?
						         (a_m & 64'hFFFF_FF00_0000_0000) : a_m;
						bm_eff = (r_op == 7'h27) ?
						         (b_m & 64'hFFFF_FF00_0000_0000) : b_m;
						// Latch chopped operands before testing the fast path.  The
						// old code used nonblocking masks and then immediately
						// tested the unmasked values, bypassing the chop.
						a_m <= am_eff;
						b_m <= bm_eff;
						// FSGLMUL chops both mantissas to single precision
						// before multiplying (the result is single rounded)
						if (a_t == T_INF || b_t == T_INF) begin
							if (a_t == T_ZERO || b_t == T_ZERO) begin
								a_t <= T_NAN;      // 0 * inf: default NaN
								a_s <= 0;
								a_m <= 64'hFFFF_FFFF_FFFF_FFFF;
								a_e <= 17'h07FFF;
								fpsr[13] <= 1;
								fpsr[7] <= 1;
							end
							else begin
								// pass-through infinity keeps the raw
								// mantissa of the winning operand (dest
								// first, matching floatx80_mul's order)
								a_t <= T_INF;
								a_s <= a_s ^ b_s;
								a_m <= (b_t == T_INF) ? b_m : a_m;
							end
							fst <= F_WB;
						end
						else if (a_t == T_ZERO || b_t == T_ZERO) begin
							a_t <= T_ZERO;
							a_s <= a_s ^ b_s;
							fst <= F_WB;
						end
						else begin
							a_s <= a_s ^ b_s;
							e_w <= $signed({1'b0, a_e}) +
							       $signed({1'b0, b_e}) - 18'sd16383;
							if (am_eff == 64'h8000_0000_0000_0000 ||
							    bm_eff == 64'h8000_0000_0000_0000) begin
								// Multiplication by an exact power of two only changes
								// sign/exponent and needs no iterative multiply.
								a_m <= (am_eff == 64'h8000_0000_0000_0000) ? bm_eff : am_eff;
								grs <= 0;
								fst <= F_ROUND;
							end
							else begin
								acc_hi <= 0;
								acc_lo <= 0;
								loop_n <= 0;
								fst <= F_MULT;
							end
						end
					end
					default: begin : bin_div
						// FSGLDIV divides the FULL-width mantissas and only
						// rounds the quotient to single precision: unlike
						// FSGLMUL there is no operand chop (floatx80_sgldiv
						// has no aSig/bSig masking).
						reg [63:0] am_eff, bm_eff;
						am_eff = a_m;
						bm_eff = b_m;
						// FPn = FPn / source (b = dividend, a = divisor).
						// Special-case order follows floatx80_div: the
						// dividend-infinity case comes BEFORE the divisor-zero
						// check, so inf/0 is a clean infinity with NO DZ.
						// 0/0 and inf/inf produce the default NaN: positive
						// sign, all-ones mantissa (floatx80_default_nan).
						if (a_t == T_INF && b_t == T_INF) begin
							a_t <= T_NAN;
							a_s <= 0;
							a_m <= 64'hFFFF_FFFF_FFFF_FFFF;
							a_e <= 17'h07FFF;
							fpsr[13] <= 1;
							fpsr[7] <= 1;
							fst <= F_WB;
						end
						else if (a_t == T_ZERO && b_t == T_ZERO) begin
							a_t <= T_NAN;
							a_s <= 0;
							a_m <= 64'hFFFF_FFFF_FFFF_FFFF;
							a_e <= 17'h07FFF;
							fpsr[13] <= 1;
							fpsr[7] <= 1;
							fst <= F_WB;
						end
						else if (b_t == T_INF) begin
							// dividend infinity passes through with its raw
							// mantissa bits (the 040 does not clear the
							// integer bit; that is 68060 behaviour)
							a_t <= T_INF;
							a_s <= a_s ^ b_s;
							a_m <= b_m;
							fst <= F_WB;
						end
						else if (a_t == T_ZERO) begin
							// finite dividend / zero: DZ + created infinity
							// (all-zero mantissa, floatx80_default_infinity)
							a_t <= T_INF;
							a_s <= a_s ^ b_s;
							a_m <= 64'd0;
							fpsr[10] <= 1;
							fpsr[4] <= 1;
							fst <= F_WB;
						end
						else if (b_t == T_ZERO || a_t == T_INF) begin
							a_t <= T_ZERO;
							a_s <= a_s ^ b_s;
							fst <= F_WB;
						end
						else begin
							a_s <= a_s ^ b_s;
							e_w <= $signed({1'b0, b_e}) -
							       $signed({1'b0, a_e}) + 18'sd16383;
							if (am_eff == 64'h8000_0000_0000_0000 || bm_eff == am_eff) begin
								// Division by a power of two, or equal normalized
								// significands, is exact after exponent adjustment.
								a_m <= (am_eff == 64'h8000_0000_0000_0000) ? bm_eff :
								       64'h8000_0000_0000_0000;
								grs <= 0;
								fst <= F_ROUND;
							end
							else begin
								// remainder = dividend (chopped for FSGLDIV,
								// which the b_m write below cannot supply yet)
								acc_hi <= {1'b0, bm_eff};
								qv <= 0;
								loop_n <= 0;
								fst <= F_DIVL;
							end
						end
					end
				endcase
				end
			end

			F_ADDX: begin : f_addx
				reg [67:0] sum;
				reg [66:0] diff;
				if (!eff_sub) begin
					sum = {1'b0, b_m, 3'd0} + {1'b0, sh_v};
					if (sum[67]) begin
						a_m <= sum[67:4];
						grs <= {sum[3], sum[2], sum[1] | sum[0]};
						e_w <= e_w + 18'sd1;
					end
					else begin
						a_m <= sum[66:3];
						grs <= sum[2:0];
					end
					a_s <= b_s;
					a_t <= T_NUM;
					fst <= F_ROUND;
				end
				else begin
					diff = {b_m, 3'd0} - sh_v;
					if (diff == 67'd0) begin
						a_t <= T_ZERO;
						a_s <= (rnd_mode == 2'b10);
						fst <= F_WB;
					end
					else begin
						a_s <= b_s;
						a_t <= T_NUM;
						acc_hi <= {1'b0, diff[66:3]};
						grs <= diff[2:0];
						fst <= F_NORM2;
					end
				end
			end

			F_NORM2: begin : f_norm2
				reg [6:0]  lz;
				reg [66:0] v;
				lz = clz64(acc_hi[63:0]);
				v = {acc_hi[63:0], grs};
				if (acc_hi[63:0] == 64'd0 && grs == 3'd0) begin
					a_t <= T_ZERO;
					fst <= F_WB;
				end
				else if (lz == 7'd64) begin
					a_m <= {grs, 61'd0};
					grs <= 0;
					e_w <= e_w - 18'sd64;
					fst <= F_ROUND;
				end
				else begin
					v = v << lz;
					a_m <= v[66:3];
					grs <= v[2:0];
					e_w <= e_w - {11'd0, lz};
					fst <= F_ROUND;
				end
			end

			F_MULT: begin : f_mult
				reg [65:0] t;
				if (loop_n == 7'd32) begin : mul_fin
					reg [127:0] pd;
					pd = {acc_hi[63:0], acc_lo};
					if (pd[127]) begin
						a_m <= pd[127:64];
						grs <= {pd[63], pd[62], (pd[61:0] != 0)};
						e_w <= e_w + 18'sd1;
					end
					else begin
						a_m <= pd[126:63];
						grs <= {pd[62], pd[61], (pd[60:0] != 0)};
					end
					a_t <= T_NUM;
					fst <= F_ROUND;
				end
				else begin
					// Unsigned radix-4 shift/add: consume two multiplier
					// bits per cycle, then shift the combined accumulator by 2.
					case (a_m[1:0])
						2'd0: t = {1'b0, acc_hi};
						2'd1: t = {1'b0, acc_hi} + {2'b0, b_m};
						2'd2: t = {1'b0, acc_hi} + {1'b0, b_m, 1'b0};
						default:
							t = {1'b0, acc_hi} + {2'b0, b_m} +
							    {1'b0, b_m, 1'b0};
					endcase
					acc_hi <= {1'b0, t[65:2]};
					acc_lo <= {t[1:0], acc_lo[63:2]};
					a_m <= {2'b0, a_m[63:2]};
					loop_n <= loop_n + 7'd1;
				end
			end

			F_DIVL: begin : f_divl
				reg [64:0] r2;
				if (loop_n == 7'd67) begin
					if (qv[66]) begin
						a_m <= qv[66:3];
						grs <= {qv[2], qv[1], qv[0] | (acc_hi != 65'd0)};
					end
					else begin
						a_m <= qv[65:2];
						grs <= {qv[1], qv[0], (acc_hi != 65'd0)};
						e_w <= e_w - 18'sd1;
					end
					a_t <= T_NUM;
					fst <= F_ROUND;
				end
				else begin
					// integer quotient bit compares unshifted; fraction
					// bits shift the remainder left, zeros entering
					r2 = (loop_n == 7'd0) ? acc_hi : {acc_hi[63:0], 1'b0};
					if (r2 >= {1'b0, a_m}) begin
						acc_hi <= r2 - {1'b0, a_m};
						qv <= {qv[65:0], 1'b1};
					end
					else begin
						acc_hi <= r2;
						qv <= {qv[65:0], 1'b0};
					end
					loop_n <= loop_n + 7'd1;
				end
			end

			F_SQRTL: begin : f_sqrtl
				reg [68:0] r2;
				reg [68:0] trial;
				if (loop_n == 7'd66) begin
					a_m <= qv[65:2];
					grs <= {qv[1], qv[0], (srem != 69'd0)};
					a_t <= T_NUM;
					fst <= F_ROUND;
				end
				else begin
					r2 = {srem[66:0], srad[131:130]};
					trial = {1'b0, qv[65:0], 2'b01};
					srad <= {srad[129:0], 2'b00};
					if (r2 >= trial) begin
						srem <= r2 - trial;
						qv <= {qv[65:0], 1'b1};
					end
					else begin
						srem <= r2;
						qv <= {qv[65:0], 1'b0};
					end
					loop_n <= loop_n + 7'd1;
				end
			end

			F_ROUND: begin : f_round
				reg [64:0] mr;
				reg        inx, up, ovf, unf, tomax;
				reg [1:0]  pr;
				reg signed [17:0] er, emin, emax;
				pr = prec_of(r_op);
				if (a_t != T_NUM) fst <= F_WB;
				else begin
					case (pr)
						2'd1: begin
							up = round_up(a_m[40], a_m[39],
							              (a_m[38:0] != 0) || (grs != 0), a_s);
							inx = (a_m[39:0] != 0) || (grs != 0);
							mr = {1'b0, a_m & 64'hFFFF_FF00_0000_0000} +
							     (up ? 65'h100_0000_0000 : 65'd0);
						end
						2'd2: begin
							up = round_up(a_m[11], a_m[10],
							              (a_m[9:0] != 0) || (grs != 0), a_s);
							inx = (a_m[10:0] != 0) || (grs != 0);
							mr = {1'b0, a_m & 64'hFFFF_FFFF_FFFF_F800} +
							     (up ? 65'h800 : 65'd0);
						end
						default: begin
							up = round_up(a_m[0], grs[2], grs[1:0] != 0, a_s);
							inx = (grs != 0);
							mr = {1'b0, a_m} + (up ? 65'd1 : 65'd0);
						end
					endcase
					er = e_w + (mr[64] ? 18'sd1 : 18'sd0);
					if (mr[64]) mr = {2'b01, 63'd0};
					// Range control: the rounding precision narrows the
					// exponent range as well as the significand (softfloat's
					// SOFTFLOAT_68K roundAndPackFloatx80 expOffset, 0x3F80
					// single / 0x3C00 double), EXCEPT for FSGLMUL/FSGLDIV,
					// which round through roundSigAndPackFloatx80 and keep
					// the extended range.
					// Extended (and the sgl class) use the RAW exponent
					// convention: a working exponent of ZERO still packs as
					// a normal result with exponent field 0 (the
					// pseudo-denormal encoding) and no flags; tininess only
					// starts below that, shifting by -er (softfloat probes:
					// (0001-8000)/2 -> 0000-8000 clean, /4 -> 0000-4000
					// UNFL, 2^-16380*2^-13 -> 0000-0020.. shift 10).
					emax = op_sgl(r_op) ? 18'sd32766 :
					       (pr == 2'd1) ? 18'sd16510 :
					       (pr == 2'd2) ? 18'sd17406 : 18'sd32766;
					emin = op_sgl(r_op) ? 18'sd0 :
					       (pr == 2'd1) ? 18'sd16257 :
					       (pr == 2'd2) ? 18'sd15361 : 18'sd0;
					ovf = (er > emax);
					unf = (er < emin);
					if (ovf) begin
						fpsr[12] <= 1;              // OVFL
						fpsr[6]  <= 1;              // accrued OVFL
						fpsr[3]  <= 1;              // accrued INEX (from OVFL)
						// INEX2 itself only reports actually-discarded bits
						// (roundAndPackFloatx80 raises inexact on overflow
						// only when zSig0 & roundMask is nonzero)
						if (inx) fpsr[9] <= 1;
						tomax = (rnd_mode == 2'b01) ||
						        (rnd_mode == 2'b10 && !a_s) ||
						        (rnd_mode == 2'b11 && a_s);
						if (tomax) begin
							a_e <= emax[16:0];
							a_m <= op_sgl(r_op) ? 64'hFFFF_FFFF_FFFF_FFFF :
							       (pr == 2'd1) ? 64'hFFFF_FF00_0000_0000 :
							       (pr == 2'd2) ? 64'hFFFF_FFFF_FFFF_F800 :
							                      64'hFFFF_FFFF_FFFF_FFFF;
						end
						else begin
							a_t <= T_INF;
							a_m <= 64'd0;   // created infinity: all-zero
						end
						fst <= F_WB;
					end
					else if (unf) begin : f_unf
						// Gradual underflow.  At single or double rounding
						// precision the result is only subnormal with respect
						// to that precision, so it still fits the extended
						// format as a normal number: shift the significand
						// down to the precision's minimum exponent, round
						// there, and renormalize in F_UNFL.  A result below
						// the extended minimum exponent would need the
						// denormalized encoding (and a signed working
						// exponent throughout), which this implementation
						// does not have; those flush to zero.
						reg signed [17:0] extra;
						extra = emin - er;
						fpsr[11] <= 1;              // UNFL status (tiny)
						// accrued UNFL is only recorded when the result is
						// ALSO inexact (updateaccrued: UNFL && INEX2); the
						// deep-flush is always inexact, the F_UNFL path
						// decides for itself
						if (extra > 18'sd66) begin
							fpsr[9] <= 1;           // INEX2
							fpsr[3] <= 1;
							fpsr[5] <= 1;           // accrued UNFL
							a_t <= T_ZERO;
							fst <= F_WB;
						end
						else begin
							sh_v <= {a_m, grs};
							sh_cnt <= extra[6:0];
							e_w <= emin;
							r_pr <= pr;
							sh_ret <= F_UNFL;
							fst <= F_SHR;
						end
					end
					else begin
						if (inx && !(op_no_inex(r_op) && r_src_x)) begin
							fpsr[9] <= 1;
							fpsr[3] <= 1;
						end
						a_m <= mr[63:0];
						a_e <= er[16:0];
						fst <= F_WB;
					end
				end
			end

			F_WB: begin : f_wb
				reg        n, z, nan;
				reg        ds, dz, gt, eq, dbig;
				reg [83:0] du;
				if (|(fpsr[15:8] & fpcr[15:8])) begin
					// Enabled exceptions suppress architectural destination
					// writeback.  The core builds the normal arithmetic-
					// exception stack frame for the selected vector.
					exc_req <= 1;
					exc_vec <= fp_exception_vector(fpsr[15:8] & fpcr[15:8]);
					fpu_used <= 1;
					fst <= F_IDLE;
				end
				else if (r_op == 7'h38) begin : f_cmp
					// FCMP: condition codes from FPn - source
					du = unpack_x(fr_s[r_dst], fr_e[r_dst], fr_m[r_dst]);
					ds = du[83];
					dz = (du[1:0] == T_ZERO);
					nan = (a_t == T_NAN) || (du[1:0] == T_NAN);
					n = 0; z = 0;
					if (nan) begin
						// cmp_signed_nan (68040): the propagated NaN keeps
						// its sign and N reports it; the destination NaN is
						// preferred, matching propagateFloatx80NaN(a, b)
						n = (du[1:0] == T_NAN) ? ds : a_s;
					end
					else begin
						eq = (dz && a_t == T_ZERO) ||
						     (du[1:0] == a_t && ds == a_s && du[1:0] != T_ZERO &&
						      (du[1:0] == T_INF ||
						       (du[82:66] == a_e && du[65:2] == a_m)));
						if (eq) begin
							z = 1;
							// equal ZEROS and equal INFINITIES report the
							// destination sign in N; equal finite values
							// compare as +0 (floatx80_cmp packs (0,0,0)),
							// so N stays clear even for two negatives
							n = (dz || du[1:0] == T_INF) ? ds : 1'b0;
						end
						else begin
							if (dz)                 gt = a_s;
							else if (a_t == T_ZERO) gt = !ds;
							else if (ds != a_s)     gt = !ds;
							else begin
								if (du[1:0] == T_INF)     dbig = 1;
								else if (a_t == T_INF)    dbig = 0;
								else dbig = ({du[82:66], du[65:2]} > {a_e, a_m});
								gt = ds ? !dbig : dbig;
							end
							n = !gt;
						end
					end
					fpsr[27:24] <= {n, z, 1'b0, nan};
				end
				else if (r_op == 7'h3A) begin
					// FTST
					fpsr[27:24] <= {a_s,
					                (a_t == T_ZERO),
					                (a_t == T_INF),
					                (a_t == T_NAN)};
				end
				else begin
					// writeback with condition codes, canonical encodings
					// for the special classes
					fr_s[r_dst] <= a_s;
					fr_e[r_dst] <= (a_t == T_ZERO) ? 15'd0 :
					               (a_t == T_INF || a_t == T_NAN) ? 15'h7FFF :
					                                                a_e[14:0];
					// Infinity keeps whatever mantissa the operation left
					// in a_m: created infinities carry all-zero bits and
					// pass-through infinities keep the operand's raw image
					// (inf_clear_intbit is a 68060 flag, not 68040).
					fr_m[r_dst] <= (a_t == T_ZERO) ? 64'd0 : a_m;
					fpsr[27:24] <= {a_s,
					                (a_t == T_ZERO),
					                (a_t == T_INF),
					                (a_t == T_NAN)};
				end
				fpu_used <= 1;
				if (!(|(fpsr[15:8] & fpcr[15:8]))) done <= 1;
				fst <= F_IDLE;
			end

			F_SHR: begin : f_shr
				// staged right shift with sticky collection
				reg [6:0] step;
				if (sh_cnt == 0) fst <= sh_ret;
				else begin
					step = (sh_cnt >= 7'd32) ? 7'd32 :
					       (sh_cnt >= 7'd16) ? 7'd16 :
					       (sh_cnt >= 7'd8)  ? 7'd8  :
					       (sh_cnt >= 7'd4)  ? 7'd4  :
					       (sh_cnt >= 7'd2)  ? 7'd2  : 7'd1;
					// new {int[66:3], G, R, S}: value shifted by the step,
					// G/R from the top shifted-out bits, S ORs the rest
					case (step)
						7'd32: sh_v <= {32'd0, sh_v[66:35], sh_v[34], sh_v[33],
						                (sh_v[32:0] != 0)};
						7'd16: sh_v <= {16'd0, sh_v[66:19], sh_v[18], sh_v[17],
						                (sh_v[16:0] != 0)};
						7'd8:  sh_v <= {8'd0, sh_v[66:11], sh_v[10], sh_v[9],
						                (sh_v[8:0] != 0)};
						7'd4:  sh_v <= {4'd0, sh_v[66:7], sh_v[6], sh_v[5],
						                (sh_v[4:0] != 0)};
						7'd2:  sh_v <= {2'd0, sh_v[66:5], sh_v[4], sh_v[3],
						                (sh_v[2:0] != 0)};
						default: sh_v <= {1'd0, sh_v[66:4], sh_v[3], sh_v[2],
						                  (sh_v[1:0] != 0)};
					endcase
					sh_cnt <= sh_cnt - step;
				end
			end

			F_PACKI: begin : f_packi
				// round and range check the integer store
				reg  [64:0] iv;
				reg signed [64:0] sv;
				reg         ovf;
				if (sh_cnt == 7'd127) begin
					// infinity / far out of range: OPERR, saturating to the
					// SIGN-DEPENDENT extreme (roundAndPackInt32/16/8)
					fpsr[13] <= 1;                       // OPERR
					fpsr[7]  <= 1;                       // accrued IOP
					dout <= {(pk_isz == 2'd2) ? (pk_neg ? 32'h8000_0000 : 32'h7FFF_FFFF) :
					         (pk_isz == 2'd1) ? (pk_neg ? {16'h8000, 16'd0} : {16'h7FFF, 16'd0}) :
					                            (pk_neg ? {8'h80, 24'd0} : {8'h7F, 24'd0}), 64'd0};
				end
				else begin
					iv = {1'b0, sh_v[66:3]} +
					     {64'd0, round_up(sh_v[3], sh_v[2],
					                      (sh_v[1:0] != 0), pk_neg)};
					if (pk_neg) iv = 65'd0 - iv;
					sv = $signed(iv);
					case (pk_isz)
						2'd2: ovf = (sv > 65'sd2147483647) ||
						            (sv < -65'sd2147483648);
						2'd1: ovf = (sv > 65'sd32767) || (sv < -65'sd32768);
						default: ovf = (sv > 65'sd127) || (sv < -65'sd128);
					endcase
					if (ovf) begin
						fpsr[13] <= 1;                   // OPERR
						fpsr[7]  <= 1;
						dout <= {(pk_isz == 2'd2) ? (pk_neg ? 32'h8000_0000 : 32'h7FFF_FFFF) :
						         (pk_isz == 2'd1) ? (pk_neg ? {16'h8000, 16'd0} : {16'h7FFF, 16'd0}) :
						                            (pk_neg ? {8'h80, 24'd0} : {8'h7F, 24'd0}), 64'd0};
					end
					else begin
						dout <= {(pk_isz == 2'd2) ? iv[31:0] :
						         (pk_isz == 2'd1) ? {iv[15:0], 16'd0} :
						                            {iv[7:0], 24'd0}, 64'd0};
						if (sh_v[2:0] != 0) begin
							fpsr[9] <= 1;                // INEX2
							fpsr[3] <= 1;                // accrued INEX
						end
					end
				end
				done <= 1;
				fpu_used <= 1;
				fst <= F_IDLE;
			end

			F_UNFL: begin : f_unfl
				// Round the shifted significand at the boundary of the
				// rounding precision.  e_w holds that precision's minimum
				// exponent, which the shift in F_SHR has already scaled the
				// significand to.
				reg [64:0] mr;
				reg        up, inx2;
				if (r_pr == 2'd0) begin
					up = round_up(sh_v[3], sh_v[2],
					              (sh_v[1:0] != 0), a_s);
					inx2 = (sh_v[2:0] != 0);
					mr = {1'b0, sh_v[66:3]} + (up ? 65'd1 : 65'd0);
				end
				else if (r_pr == 2'd1) begin
					up = round_up(sh_v[43], sh_v[42],
					              (sh_v[41:0] != 0), a_s);
					inx2 = (sh_v[42:0] != 0);
					mr = {1'b0, sh_v[66:3] & 64'hFFFF_FF00_0000_0000} +
					     (up ? 65'h100_0000_0000 : 65'd0);
				end
				else begin
					up = round_up(sh_v[14], sh_v[13],
					              (sh_v[12:0] != 0), a_s);
					inx2 = (sh_v[13:0] != 0);
					mr = {1'b0, sh_v[66:3] & 64'hFFFF_FFFF_FFFF_F800} +
					     (up ? 65'h800 : 65'd0);
				end
				if (inx2) begin
					fpsr[9] <= 1;                   // INEX2
					fpsr[3] <= 1;
					fpsr[5] <= 1;                   // accrued UNFL (UNFL&&INEX2)
				end
				// At extended precision the result is subnormal for the
				// destination format itself, so it takes the denormalized
				// encoding: exponent field zero with the integer bit clear.
				// At single or double precision the result is subnormal only
				// with respect to that precision and keeps that precision's
				// minimum exponent, matching softfloat's packFloatx80 of
				// (expOffset + 1).  Rounding that carries into the integer
				// bit has reached the next exponent up either way.
				if (mr[64]) begin
					a_m <= 64'h8000_0000_0000_0000;
					a_e <= e_w[16:0] + 17'd1;
					fst <= F_WB;
				end
				else if (mr[63:0] == 64'd0) begin
					a_t <= T_ZERO;
					fst <= F_WB;
				end
				else begin
					a_m <= mr[63:0];
					a_e <= (mr[63] || e_w != 18'sd1) ? e_w[16:0] : 17'd0;
					fst <= F_WB;
				end
			end

			F_PACKS: begin : f_packs
				// Finish a single/double denormal after the staged shift.
				// A carry from the fraction becomes the minimum normal.
				reg [24:0] ms;
				reg [53:0] md;
				reg inx, tiny;
				if (r_fmt == 3'd1) begin
					inx = sh_v[42:0] != 0;
					ms = {1'b0, sh_v[66:43]} +
					     {24'd0, round_up(sh_v[43], sh_v[42],
					                      sh_v[41:0] != 0, a_s)};
					tiny = !ms[23];
					dout <= {a_s, 7'd0, ms[23], ms[22:0], 64'd0};
				end
				else begin
					inx = sh_v[13:0] != 0;
					md = {1'b0, sh_v[66:14]} +
					     {53'd0, round_up(sh_v[14], sh_v[13],
					                      sh_v[12:0] != 0, a_s)};
					tiny = !md[52];
					dout <= {a_s, 10'd0, md[52], md[51:0], 32'd0};
				end
				if (inx) begin
					fpsr[9] <= 1;                 // INEX2
					fpsr[3] <= 1;                 // accrued INEX
					if (tiny) begin
						fpsr[11] <= 1;            // UNFL
						fpsr[5] <= 1;             // accrued UNFL
					end
				end
				done <= 1;
				fpu_used <= 1;
				fst <= F_IDLE;
			end

			default: fst <= F_IDLE;
		endcase
	end
end

endmodule
