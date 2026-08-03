//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_alu.v - integer ALU: arithmetic, logic, BCD, single-bit shift      //
// primitives and bit operations, with MC68040 CCR semantics                //
//                                                                          //
// Conventions:                                                             //
//  - a is the source operand, b is the destination operand                 //
//    (68k "OP src,dst" computes dst = dst OP src, i.e. result = b OP a)    //
//  - operands are used in the low bits according to size; the result is    //
//    returned in the low bits, upper bits zero (the core merges by size)   //
//  - flags are {X,N,Z,V,C}                                                 //
//  - shifts/rotates are single-bit primitives; the core iterates them so   //
//    per-step X/C/V accumulate exactly like the hardware                   //
//  - for bit operations, a holds the pre-masked bit number                 //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_alu
(
	input       [5:0] op,
	input       [1:0] size,       // AP040_SZ_B/W/L
	input      [31:0] a,
	input      [31:0] b,
	input       [4:0] flags_in,   // {X,N,Z,V,C}
	output reg [31:0] result,
	output reg  [4:0] flags_out
);

wire f_x = flags_in[4];
wire f_z = flags_in[2];

// size-dependent views
wire [5:0]  nbits = (size == `AP040_SZ_B) ? 6'd8 : (size == `AP040_SZ_W) ? 6'd16 : 6'd32;
wire [31:0] szmask = (size == `AP040_SZ_B) ? 32'h0000_00FF :
                     (size == `AP040_SZ_W) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
wire [31:0] am = a & szmask;
wire [31:0] bm = b & szmask;
wire        a_msb = (size == `AP040_SZ_B) ? a[7]  : (size == `AP040_SZ_W) ? a[15] : a[31];
wire        b_msb = (size == `AP040_SZ_B) ? b[7]  : (size == `AP040_SZ_W) ? b[15] : b[31];

function res_msb;
	input [31:0] r;
	begin
		res_msb = (size == `AP040_SZ_B) ? r[7] : (size == `AP040_SZ_W) ? r[15] : r[31];
	end
endfunction

function res_zero;
	input [31:0] r;
	begin
		res_zero = ((r & szmask) == 32'd0);
	end
endfunction

// shared adder/subtractor with carry out per size
wire [32:0] add_full  = {1'b0, bm} + {1'b0, am};
wire [32:0] addx_full = {1'b0, bm} + {1'b0, am} + {32'd0, f_x};
wire [32:0] sub_full  = {1'b0, bm} - {1'b0, am};
wire [32:0] subx_full = {1'b0, bm} - {1'b0, am} - {32'd0, f_x};

function carry_of;
	input [32:0] r;
	begin
		carry_of = (size == `AP040_SZ_B) ? (r[8] ^ 1'b0) : (size == `AP040_SZ_W) ? r[16] : r[32];
	end
endfunction

// carry out of the sized MSB position for byte/word needs the sized bit
wire add_c  = (size == `AP040_SZ_B) ? add_full[8]  : (size == `AP040_SZ_W) ? add_full[16]  : add_full[32];
wire addx_c = (size == `AP040_SZ_B) ? addx_full[8] : (size == `AP040_SZ_W) ? addx_full[16] : addx_full[32];
wire sub_c  = (size == `AP040_SZ_B) ? sub_full[8]  : (size == `AP040_SZ_W) ? sub_full[16]  : sub_full[32];
wire subx_c = (size == `AP040_SZ_B) ? subx_full[8] : (size == `AP040_SZ_W) ? subx_full[16] : subx_full[32];

wire add_r_msb  = res_msb(add_full[31:0]);
wire addx_r_msb = res_msb(addx_full[31:0]);
wire sub_r_msb  = res_msb(sub_full[31:0]);
wire subx_r_msb = res_msb(subx_full[31:0]);

wire add_v  = (a_msb == b_msb) && (add_r_msb  != a_msb);
wire addx_v = (a_msb == b_msb) && (addx_r_msb != a_msb);
wire sub_v  = (a_msb != b_msb) && (sub_r_msb  == a_msb);
wire subx_v = (a_msb != b_msb) && (subx_r_msb == a_msb);

// BCD helpers (byte only). The decimal corrections are applied to the
// whole byte so a +/-6 low-nibble adjust ripples binary into the high
// nibble, and the carry comes from the corrected value above bit 3.
// This matches real hardware for non-BCD digit inputs (cputest
// 68040_default: abcd.b $FF+$FF+0 = $64 with C set, not $54).
wire [4:0] bcd_al   = {1'b0, b[3:0]} + {1'b0, a[3:0]} + {4'd0, f_x};
wire [9:0] bcd_asum = {2'd0, b[7:0]} + {2'd0, a[7:0]} + {9'd0, f_x}
                    + ((bcd_al > 5'd9) ? 10'd6 : 10'd0);
wire       bcd_ac   = ((bcd_asum & 10'h3F0) > 10'h090);
wire [9:0] bcd_ares = bcd_asum + (bcd_ac ? 10'h060 : 10'd0);

// SBCD: b - a - X; the $60 adjust keys off the uncorrected byte borrow,
// the carry flag off the borrow after the low-nibble correction
wire       bcd_slb  = ({1'b0, b[3:0]} < ({1'b0, a[3:0]} + {4'd0, f_x}));
wire [9:0] bcd_sraw = {2'd0, b[7:0]} - {2'd0, a[7:0]} - {9'd0, f_x};
wire [9:0] bcd_scor = bcd_sraw - (bcd_slb ? 10'd6 : 10'd0);
wire [9:0] bcd_sres = bcd_scor - (bcd_sraw[9] ? 10'h060 : 10'd0);
wire       bcd_sc   = bcd_scor[9];

// NBCD: 0 - b - X (the SBCD datapath with a zero destination; b is the
// pipeline dst operand -- single-operand ops must not touch port a,
// which still holds the previous instruction's source)
wire       nbc_lb   = (b[3:0] != 4'd0) | f_x;
wire [9:0] nbc_raw  = 10'd0 - {2'd0, b[7:0]} - {9'd0, f_x};
wire [9:0] nbc_cor  = nbc_raw - (nbc_lb ? 10'd6 : 10'd0);
wire [9:0] nbc_res  = nbc_cor - (nbc_raw[9] ? 10'h060 : 10'd0);
wire       nbc_c    = nbc_cor[9];

// single-bit shift/rotate primitives on the sized value bm
wire sh_msb  = b_msb;
wire sh_msb2 = (size == `AP040_SZ_B) ? b[6] : (size == `AP040_SZ_W) ? b[14] : b[30];
wire sh_lsb  = b[0];

wire [31:0] shl_r  = (bm << 1) & szmask;
wire [31:0] shr_l  = bm >> 1;
wire [31:0] asr_r  = shr_l | (sh_msb ? ((szmask >> 1) ^ szmask) : 32'd0);  // sign fill
wire [31:0] rol_r  = shl_r | {31'd0, sh_msb};
wire [31:0] ror_r  = shr_l | (sh_lsb ? (szmask ^ (szmask >> 1)) : 32'd0); // lsb to msb
wire [31:0] roxl_r = shl_r | {31'd0, f_x};
wire [31:0] roxr_r = shr_l | (f_x ? (szmask ^ (szmask >> 1)) : 32'd0);

// bit operations: bit number in a (pre-masked by the core: mod 32 or mod 8)
wire [31:0] bit_mask = 32'd1 << a[4:0];
wire        bit_set  = |(b & bit_mask);

// shared intermediate results
wire [31:0] negx_res = (32'd0 - bm - {31'd0, f_x}) & szmask;
wire [31:0] ext_res  = (size == `AP040_SZ_W) ? {16'd0, {8{b[7]}}, b[7:0]}
                                             : {{16{b[15]}}, b[15:0]};

always @* begin
	result    = 32'd0;
	flags_out = flags_in;

	case (op)
		`AP040_ALU_MOVE, `AP040_ALU_TST: begin
			result = am;
			flags_out = {f_x, res_msb(am), res_zero(am), 1'b0, 1'b0};
		end

		`AP040_ALU_ADD: begin
			result = add_full[31:0] & szmask;
			flags_out = {add_c, add_r_msb, res_zero(add_full[31:0]), add_v, add_c};
		end

		`AP040_ALU_ADDX: begin
			result = addx_full[31:0] & szmask;
			flags_out = {addx_c, addx_r_msb, f_z & res_zero(addx_full[31:0]), addx_v, addx_c};
		end

		`AP040_ALU_SUB: begin
			result = sub_full[31:0] & szmask;
			flags_out = {sub_c, sub_r_msb, res_zero(sub_full[31:0]), sub_v, sub_c};
		end

		`AP040_ALU_SUBX: begin
			result = subx_full[31:0] & szmask;
			flags_out = {subx_c, subx_r_msb, f_z & res_zero(subx_full[31:0]), subx_v, subx_c};
		end

		`AP040_ALU_CMP: begin
			result = bm;   // destination unchanged
			flags_out = {f_x, sub_r_msb, res_zero(sub_full[31:0]), sub_v, sub_c};
		end

		`AP040_ALU_AND: begin
			result = bm & am;
			flags_out = {f_x, res_msb(bm & am), res_zero(bm & am), 1'b0, 1'b0};
		end

		`AP040_ALU_OR: begin
			result = bm | am;
			flags_out = {f_x, res_msb(bm | am), res_zero(bm | am), 1'b0, 1'b0};
		end

		`AP040_ALU_EOR: begin
			result = bm ^ am;
			flags_out = {f_x, res_msb(bm ^ am), res_zero(bm ^ am), 1'b0, 1'b0};
		end

		`AP040_ALU_NOT: begin
			result = (~bm) & szmask;
			flags_out = {f_x, res_msb(~bm), res_zero(~bm), 1'b0, 1'b0};
		end

		`AP040_ALU_NEG: begin
			// 0 - b
			result = (32'd0 - bm) & szmask;
			flags_out = {|bm ? 1'b1 : 1'b0,
			             res_msb(32'd0 - bm),
			             res_zero(32'd0 - bm),
			             res_msb(bm) & res_msb(32'd0 - bm),
			             |bm ? 1'b1 : 1'b0};
		end

		`AP040_ALU_NEGX: begin
			// 0 - b - X
			result = negx_res;
			flags_out = {(|bm | f_x),
			             res_msb(negx_res),
			             f_z & res_zero(negx_res),
			             res_msb(bm) & res_msb(negx_res),
			             (|bm | f_x)};
		end

		`AP040_ALU_CLR: begin
			result = 32'd0;
			flags_out = {f_x, 1'b0, 1'b1, 1'b0, 1'b0};
		end

		`AP040_ALU_EXT: begin
			// size W: byte to word; size L: word to long
			result = ext_res;
			flags_out = {f_x, res_msb(ext_res), res_zero(ext_res), 1'b0, 1'b0};
		end

		`AP040_ALU_EXTB: begin
			result = {{24{b[7]}}, b[7:0]};
			flags_out = {f_x, b[7], (b[7:0] == 8'd0), 1'b0, 1'b0};
		end

		`AP040_ALU_SWAP: begin
			result = {b[15:0], b[31:16]};
			flags_out = {f_x, b[15], (b == 32'd0), 1'b0, 1'b0};
		end

		`AP040_ALU_TAS: begin
			result = {24'd0, 1'b1, b[6:0]};
			flags_out = {f_x, b[7], (b[7:0] == 8'd0), 1'b0, 1'b0};
		end

		// BCD: on the real 68040 the architecturally undefined N and V
		// flags are left unchanged (verified with cputest 68040_default
		// reference data on hardware); X/C carry out, Z is sticky
		`AP040_ALU_ABCD: begin
			result = {24'd0, bcd_ares[7:0]};
			flags_out = {bcd_ac, flags_in[3], f_z & (bcd_ares[7:0] == 8'd0), flags_in[1], bcd_ac};
		end

		`AP040_ALU_SBCD: begin
			result = {24'd0, bcd_sres[7:0]};
			flags_out = {bcd_sc, flags_in[3], f_z & (bcd_sres[7:0] == 8'd0), flags_in[1], bcd_sc};
		end

		`AP040_ALU_NBCD: begin
			result = {24'd0, nbc_res[7:0]};
			flags_out = {nbc_c, flags_in[3], f_z & (nbc_res[7:0] == 8'd0), flags_in[1], nbc_c};
		end

		`AP040_ALU_ASL1: begin
			result = shl_r;
			// V accumulates in the core across steps
			flags_out = {sh_msb, res_msb(shl_r), res_zero(shl_r), sh_msb ^ sh_msb2, sh_msb};
		end

		`AP040_ALU_LSL1: begin
			result = shl_r;
			flags_out = {sh_msb, res_msb(shl_r), res_zero(shl_r), 1'b0, sh_msb};
		end

		`AP040_ALU_ASR1: begin
			result = asr_r;
			flags_out = {sh_lsb, res_msb(asr_r), res_zero(asr_r), 1'b0, sh_lsb};
		end

		`AP040_ALU_LSR1: begin
			result = shr_l;
			flags_out = {sh_lsb, res_msb(shr_l), res_zero(shr_l), 1'b0, sh_lsb};
		end

		`AP040_ALU_ROL1: begin
			result = rol_r;
			flags_out = {f_x, res_msb(rol_r), res_zero(rol_r), 1'b0, sh_msb};
		end

		`AP040_ALU_ROR1: begin
			result = ror_r;
			flags_out = {f_x, res_msb(ror_r), res_zero(ror_r), 1'b0, sh_lsb};
		end

		`AP040_ALU_ROXL1: begin
			result = roxl_r;
			flags_out = {sh_msb, res_msb(roxl_r), res_zero(roxl_r), 1'b0, sh_msb};
		end

		`AP040_ALU_ROXR1: begin
			result = roxr_r;
			flags_out = {sh_lsb, res_msb(roxr_r), res_zero(roxr_r), 1'b0, sh_lsb};
		end

		`AP040_ALU_BTST: begin
			result = bm;
			flags_out = {f_x, flags_in[3], ~bit_set, flags_in[1], flags_in[0]};
		end

		`AP040_ALU_BCHG: begin
			result = (bm ^ bit_mask) & szmask;
			flags_out = {f_x, flags_in[3], ~bit_set, flags_in[1], flags_in[0]};
		end

		`AP040_ALU_BCLR: begin
			result = bm & ~bit_mask;
			flags_out = {f_x, flags_in[3], ~bit_set, flags_in[1], flags_in[0]};
		end

		`AP040_ALU_BSET: begin
			result = (bm | bit_mask) & szmask;
			flags_out = {f_x, flags_in[3], ~bit_set, flags_in[1], flags_in[0]};
		end

		default: begin
			result = bm;
			flags_out = flags_in;
		end
	endcase
end

endmodule
