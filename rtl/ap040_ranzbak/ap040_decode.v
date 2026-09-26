//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_decode.v - ID stage (rewritten for Minimig plan M1)                //
//                                                                          //
// Gathers an instruction's words from IF one per clock into a word buffer, //
// and emits the instruction as one id_t once its length is known and every //
// word is present:                                                         //
//   opcode, then "pre" words (immediate data, MOVEC selector, branch        //
//   displacement), then the source EA's extension words, then the          //
//   destination EA's.  The length of a brief/full-format EA is only known  //
//   once its first extension word is in (full format: base and outer       //
//   displacement sizes), so the length is re-evaluated as words arrive.    //
// Up to two words are taken per clock from IF's queue, so an instruction  //
// of one or two words is emitted in the clock it arrives.                  //
//                                                                          //
// Both EAs are normalised to ea_t (ap040_pipe_pkg.sv); PC-relative modes   //
// fold the extension word's address into bd here.                          //
//                                                                          //
// Branch guess: Bcc/BRA/BSR redirect IF to the target the clock they are  //
// emitted (guess taken), exactly as the milestone-4 design; EX recovers.  //
//                                                                          //
// Legality: an opcode this decoder does not implement, or an EA mode the   //
// instruction does not allow, becomes CL_EXC vector 4 with length 1 (the  //
// stacked PC is the opcode's own address, so the length does not matter). //
// $Axxx -> vector 10, $Fxxx -> vector 11 (no FPU/MMU decode yet).          //
//                                                                          //
// M68000PRM section 2 (EA modes, extension word formats), section 4 per    //
// instruction, section 8 opcode map.                                       //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_decode
	import ap040_pipe_pkg::*;
#(
	// 1: a full MC68040 with the FPU.  0 (the LC040 build): every well-formed
	parameter HAS_FPU = 0
)
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // EA-calc cannot accept this cycle
	input             flush,      // redirect from EX: abandon everything

	// the head of IF's prefetch queue: up to two words
	input             q_v0,
	input             q_v1,
	input      [31:0] q_pc0,
	input      [15:0] q_w0,
	input      [15:0] q_w1,
	input             q_e0,         // poisoned words (their fetch faulted, M6)
	input             q_e1,
	input      [31:0] pf_addr,      // the faulted fetch
	input             pf_long,
	input             pf_atc,

	output      [1:0] consume,    // words taken from the queue this clock
	output      [1:0] consume_nf, // the same, as if `flush` were low (IF's room check, timing)

	output            id_redirect_valid,
	output     [31:0] id_redirect_pc,

	output reg        id_valid,
	output id_t       id_o,
	output     [31:0] g_lo, g_hi,   // words gathered for the next instruction (SMC check)
	output            g_v
);


//------------------------------------------------------------------ helpers

// extension words an EA needs.  ext0 = its first extension word, valid when
// have0; need0 is returned when the answer depends on an ext0 we do not yet
// have.  bad = reserved full-format encoding.
typedef struct packed { logic [3:0] n; logic need0; logic bad; } elen_t;

// A floating-point instruction's immediate operand is sized by the source
// specifier in its extension word, not by the integer size field (PRM, the
// "Source Specifier field" paragraph that every FP instruction page carries,
// e.g. FABS).  Words in the instruction stream:
function automatic logic [3:0] fp_imm_words(input logic [2:0] spec);
	case (spec)
		3'b000: return 4'd2;   // long-word integer
		3'b001: return 4'd2;   // single precision
		3'b010: return 4'd6;   // extended precision
		3'b011: return 4'd6;   // packed decimal (the 040's unsupported type: still sized)
		3'b100: return 4'd1;   // word integer
		3'b101: return 4'd4;   // double precision
		3'b110: return 4'd1;   // byte integer (the low half of one word)
		default: return 4'd0;  // 111: FMOVECR as a source -- no EA at all
	endcase
endfunction

// The same operand as it sits in MEMORY, in bytes.  It differs from
// fp_imm_words above for the byte integer only: in the instruction stream it
// occupies a whole word (the operand is its low half), in memory one byte.
function automatic logic [4:0] fp_bytes(input logic [2:0] spec);
	case (spec)
		3'b000: return 5'd4;    // long-word integer
		3'b001: return 5'd4;    // single precision
		3'b010: return 5'd12;   // extended precision
		3'b011: return 5'd12;   // packed decimal
		3'b100: return 5'd2;    // word integer
		3'b101: return 5'd8;    // double precision
		3'b110: return 5'd1;    // byte integer
		default: return 5'd0;   // 111: FMOVECR -- no operand
	endcase
endfunction

// (M10.2) The control-register list of opclass 100/101: extension bits 12, 11
// and 10 select FPCR, FPSR and FPIAR, an EMPTY list means FPIAR alone (WinUAE,
// and lib/AP68040's fp_crm arm), and the transfer is one longword per selected
// register in FPCR, FPSR, FPIAR order at ascending addresses.  So the list
// decides the instruction's LENGTH when the operand is an immediate, and the
// (An)+ / -(An) step in every case.  This is true whether or not an FPU
// exists, which is why it is not gated on HAS_FPU: an LC040's format $4 frame
// stacks the PC of the NEXT instruction.
function automatic logic [2:0] fp_cr_n(input logic [2:0] sel);
	if (sel == 3'd0) return 3'd1;     // an empty list is FPIAR
	return {2'd0, sel[2]} + {2'd0, sel[1]} + {2'd0, sel[0]};
endfunction

// (M10.6) The opmodes THIS unit implements in hardware, copied from
// `ap040_fpu.v`'s op_in_hw so decode and the unit cannot disagree.  It is
// needed in the decoder because the 68040 reports an FPSP-emulated opmode as
// an UNIMPLEMENTED instruction even when its effective address is illegal --
// WinUAE runs fault_if_unimplemented_680x0 before it rejects a Dn or An
// source, and lib/AP68040's t_fpu.s test 326 (`fint.x a1,fp1`) pins it.  A
// hardware opmode with the same EA stays a plain format $0 F-line.
function automatic logic fp_op_hw(input logic [6:0] op);
	case (op)
		7'h00, 7'h40, 7'h44,          // FMOVE, FSMOVE, FDMOVE
		7'h18, 7'h58, 7'h5C,          // FABS, FSABS, FDABS
		7'h1A, 7'h5A, 7'h5E,          // FNEG, FSNEG, FDNEG
		7'h38, 7'h3A,                 // FCMP, FTST
		7'h22, 7'h62, 7'h66,          // FADD, FSADD, FDADD
		7'h28, 7'h68, 7'h6C,          // FSUB, FSSUB, FDSUB
		7'h23, 7'h27, 7'h63, 7'h67,   // FMUL, FSGLMUL, FSMUL, FDMUL
		7'h20, 7'h24, 7'h60, 7'h64,   // FDIV, FSGLDIV, FSDIV, FDDIV
		7'h04, 7'h41, 7'h45: return 1'b1;   // FSQRT, FSSQRT, FDSQRT
		default: return 1'b0;
	endcase
endfunction

// An FP opmode that no 68040 implements.  1 = the encoding is not a floating-
// point instruction at all and takes the ordinary F-line (vector 11, format
// $0); 2 = $78..$7F, which take the ILLEGAL vector 4; 0 = a real FP opmode.
// Ported verbatim from lib/AP68040 rtl/ap040_core.v:1299-1319, whose table is
// the reference core's and is what WinUAE's fault_if_nonexisting_opmode
// checks before it asks whether an FPU is present (PLAN.md D18).
function automatic logic [1:0] fp_opmode_class(input logic [6:0] om);
	case (om)
		7'h05, 7'h07, 7'h0B, 7'h13, 7'h17, 7'h1B,
		7'h29, 7'h2A, 7'h2B, 7'h2C, 7'h2D, 7'h2E, 7'h2F,
		7'h39, 7'h3B, 7'h3C, 7'h3D, 7'h3E, 7'h3F,
		7'h42, 7'h43, 7'h46, 7'h47,
		7'h48, 7'h49, 7'h4A, 7'h4B, 7'h4C, 7'h4D, 7'h4E, 7'h4F,
		7'h50, 7'h51, 7'h52, 7'h53, 7'h54, 7'h55, 7'h56, 7'h57,
		7'h59, 7'h5B, 7'h5D, 7'h5F,
		7'h61, 7'h65, 7'h69, 7'h6A, 7'h6B, 7'h6D, 7'h6E, 7'h6F,
		7'h70, 7'h71, 7'h72, 7'h73, 7'h74, 7'h75, 7'h76, 7'h77:
			return 2'd1;
		7'h78, 7'h79, 7'h7A, 7'h7B, 7'h7C, 7'h7D, 7'h7E, 7'h7F:
			return 2'd2;
		default:
			return 2'd0;
	endcase
endfunction

// fpw != 0 overrides the length of a mode 7 / register 4 (#imm) operand with
// that many words: the FP sizes above.  Every other mode's length is the same
// for integer and floating-point operands.
function automatic elen_t ea_len(input logic [2:0] m, input logic [2:0] r, input logic [1:0] sz,
                                 input logic [15:0] ext0, input logic have0, input logic [3:0] fpw);
	logic full;
	int bdw, odw, n;
	logic need0, bad;
	elen_t e;
	need0 = 1'b0; bad = 1'b0; n = 0;
	full = 1'b0;
	case (m)
		3'd5: n = 1;
		3'd6: full = 1'b1;
		3'd7: case (r)
			3'd0: n = 1;
			3'd1: n = 2;
			3'd2: n = 1;
			3'd3: full = 1'b1;
			3'd4: n = (fpw != 4'd0) ? int'(fpw) : ((sz == SZ_L) ? 2 : 1);
			default: n = 0;
		endcase
		default: n = 0;
	endcase
	if (full) begin
		if (!have0) begin
			need0 = 1'b1; n = 1;
		end else if (!ext0[8]) begin
			n = 1;
		end else begin
			bdw = (ext0[5:4] == 2'd3) ? 2 : (ext0[5:4] == 2'd2) ? 1 : 0;
			if (ext0[5:4] == 2'd0 || ext0[3]) bad = 1'b1;
			odw = 0;
			if (!ext0[6]) begin
				case (ext0[2:0])
					3'd2, 3'd6: odw = 1;
					3'd3, 3'd7: odw = 2;
					3'd4: bad = 1'b1;
					default: odw = 0;
				endcase
			end else begin
				case (ext0[2:0])
					3'd2: odw = 1;
					3'd3: odw = 2;
					3'd0, 3'd1: odw = 0;
					default: bad = 1'b1;
				endcase
			end
			n = 1 + bdw + odw;
		end
	end
	e.n = n[3:0]; e.need0 = need0; e.bad = bad;
	return e;
endfunction

// Build an ea_t for mode/reg with its extension words w[k0..], the first
// of which sits at address wpc (the PC-relative base).
function automatic ea_t ea_build(input logic [2:0] m, input logic [2:0] r, input logic [1:0] sz,
                                 input logic [10:0][15:0] w, input int k0, input logic [31:0] wpc);
	ea_t e;
	logic [15:0] x;
	int k;
	logic [31:0] bd, od;
	e = '0;
	e.mode = m; e.mreg = r;
	e.reg_n = {2'b01, r};          // An by default (8 + r)
	e.idx_reg = R_NONE;
	x = w[k0];
	case (m)
		3'd0: begin e.kind = EK_DREG; e.reg_n = {2'b00, r}; end
		3'd1: begin e.kind = EK_AREG; end
		3'd2: begin e.kind = EK_MEM; e.base_en = 1'b1; end
		3'd3: begin e.kind = EK_MEM; e.base_en = 1'b1; e.upd = UPD_POST; end
		3'd4: begin e.kind = EK_MEM; e.base_en = 1'b1; e.upd = UPD_PRE; end
		3'd5: begin e.kind = EK_MEM; e.base_en = 1'b1; e.bd = sext16(x); end
		3'd7: begin
			e.kind = EK_MEM;
			case (r)
				3'd0: e.bd = sext16(x);
				3'd1: e.bd = {x, w[k0 + 1]};
				3'd2: e.bd = wpc + sext16(x);
				3'd4: begin
					e.kind = EK_IMM;
					e.bd = (sz == SZ_L) ? {x, w[k0 + 1]} : (sz == SZ_W) ? {16'd0, x} : {24'd0, x[7:0]};
				end
				default: ;   // 3: indexed PC, below
			endcase
		end
		default: ;
	endcase
	if (m == 3'd6 || (m == 3'd7 && r == 3'd3)) begin
		e.kind = EK_MEM;
		e.base_en = (m == 3'd6);
		e.idx_en = 1'b1;
		e.idx_reg = {1'b0, x[15], x[14:12]};
		e.idx_l = x[11];
		e.scale = x[10:9];
		if (!x[8]) begin
			e.bd = sext8(x[7:0]) + ((m == 3'd7) ? wpc : 32'd0);
		end else begin
			k = k0 + 1;
			bd = 32'd0;
			if (x[5:4] == 2'd2) begin bd = sext16(w[k]); k = k + 1; end
			else if (x[5:4] == 2'd3) begin bd = {w[k], w[k + 1]}; k = k + 2; end
			if (x[7]) e.base_en = 1'b0;                  // BS: base suppressed
			else if (m == 3'd7) bd = bd + wpc;           // PC base (not suppressed)
			if (x[6]) e.idx_en = 1'b0;                   // IS: index suppressed
			e.bd = bd;
			od = 32'd0;
			if (x[1:0] == 2'd2) od = sext16(w[k]);
			else if (x[1:0] == 2'd3) od = {w[k], w[k + 1]};
			e.od = od;
			if (x[2:0] != 3'd0) e.mi = (!x[6] && x[2]) ? MI_POST : MI_PRE;
		end
	end
	return e;
endfunction

// EA class checks (PRM table 2-4): data / memory / control / alterable
function automatic logic ea_ok(input logic [2:0] m, input logic [2:0] r,
                               input logic data, input logic mem, input logic ctl, input logic alt);
	logic is_dn, is_an, is_imm, is_pcrel, valid;
	is_dn = (m == 3'd0); is_an = (m == 3'd1);
	is_imm = (m == 3'd7 && r == 3'd4);
	is_pcrel = (m == 3'd7 && (r == 3'd2 || r == 3'd3));
	valid = (m != 3'd7) || (r <= 3'd4);
	if (!valid) return 1'b0;
	if (data && is_an) return 1'b0;
	if (mem && (is_dn || is_an)) return 1'b0;
	if (ctl && (is_dn || is_an || is_imm || m == 3'd3 || m == 3'd4)) return 1'b0;
	if (alt && (is_imm || is_pcrel)) return 1'b0;
	return 1'b1;
endfunction

//--------------------------------------------------------------- shape

// instruction forms (what decf builds)
localparam [5:0]
	F_ILL = 6'd0,  F_MOVE = 6'd1,  F_MOVEQ = 6'd2, F_BCC = 6'd3,  F_DBCC = 6'd4,
	F_SCC = 6'd5,  F_JMP = 6'd6,   F_JSR = 6'd7,   F_TRAP = 6'd8, F_MOVE2SR = 6'd9,
	F_MOVEC = 6'd10, F_NOP = 6'd11, F_RTE = 6'd12, F_RTS = 6'd13, F_IMM = 6'd14,
	F_IMMCCR = 6'd15, F_IMMSR = 6'd16, F_UNARY = 6'd17, F_CLR = 6'd18, F_TST = 6'd19,
	F_EXT = 6'd20, F_SWAP = 6'd21, F_PEA = 6'd22, F_LEA = 6'd23, F_LINK = 6'd24,
	F_UNLK = 6'd25, F_RTD = 6'd26, F_RTR = 6'd27, F_MOVEFCCR = 6'd28, F_MOVEFSR = 6'd29,
	F_MOVE2CCR = 6'd30, F_ADDQ = 6'd31, F_EA_DN = 6'd32, F_DN_EA = 6'd33, F_ADDA = 6'd34,
	F_ADDX = 6'd35, F_CMPM = 6'd36, F_EXG = 6'd37,
	F_BITD = 6'd38, F_BITS = 6'd39, F_CAS = 6'd40, F_CAS2 = 6'd41, F_CHK2 = 6'd42,
	F_CHK = 6'd43, F_TAS = 6'd44, F_NBCD = 6'd45, F_MDW = 6'd46, F_MDL = 6'd47,
	F_TRAPCC = 6'd48, F_BCD = 6'd49, F_PACK = 6'd50, F_UNPK = 6'd51, F_SHR = 6'd52,
	F_SHM = 6'd53, F_BF = 6'd54, F_MOVEM = 6'd55, F_MOVEUSP = 6'd56, F_MOVEP = 6'd57, F_MOVE16 = 6'd58, F_MOVES = 6'd59, F_CINV = 6'd60, F_PMMU = 6'd61, F_STOP = 6'd62, F_RESET = 6'd63;
// M10.0: the coprocessor-id-1 (floating-point) space.  Wider than the rest,
// which is why shape_t's form field is 7 bits.
localparam [6:0] F_FP = 7'd64;

// What an opcode word implies about the words that follow it.
typedef struct packed {
	logic       ok;        // implemented and legal as far as the opcode word says
	logic [6:0] form;
	logic [5:0] alu;
	logic [1:0] npre;      // words before the EAs
	logic       has_src;
	logic [2:0] sm, sr;    // source EA mode/reg
	logic       has_dst;
	logic [2:0] dm, dr;    // destination EA mode/reg
	logic [1:0] sz;        // operand size (sizes #imm and the EA length)
	logic [3:0] fpw;       // (F_FP) an immediate operand's width in words, 0 = the integer rule
	logic       need_x1;   // the shape depends on the extension word, which is not in the view yet
} shape_t;

// the ALU op of the two-operand groups
function automatic logic [5:0] grp_alu(input logic [3:0] g, input logic eor);
	case (g)
		4'h8: return `AP040_ALU_OR;
		4'h9: return `AP040_ALU_SUB;
		4'hB: return eor ? `AP040_ALU_EOR : `AP040_ALU_CMP;
		4'hC: return `AP040_ALU_AND;
		default: return `AP040_ALU_ADD;   // D
	endcase
endfunction

// shift/rotate ALU op from the type field and the direction bit
function automatic logic [5:0] shift_alu(input logic [1:0] t, input logic left);
	case (t)
		2'b00:   return left ? `AP040_ALU_ASL1  : `AP040_ALU_ASR1;
		2'b01:   return left ? `AP040_ALU_LSL1  : `AP040_ALU_LSR1;
		2'b10:   return left ? `AP040_ALU_ROXL1 : `AP040_ALU_ROXR1;
		default: return left ? `AP040_ALU_ROL1  : `AP040_ALU_ROR1;
	endcase
endfunction

function automatic shape_t shape(input logic [15:0] op, input logic [15:0] x1, input logic have_x1);
	shape_t s;
	logic [1:0] ss;
	logic an_ok;
	s = '0;
	s.sm = op[5:3]; s.sr = op[2:0];
	s.dm = op[5:3]; s.dr = op[2:0];
	s.sz = SZ_L;
	ss = op[7:6];
	casez (op)
		//------------------------------------------------ group 0: immediates
		16'h003C, 16'h023C, 16'h0A3C: begin      // ORI/ANDI/EORI #,CCR
			s.ok = 1'b1; s.form = F_IMMCCR; s.npre = 2'd1; s.sz = SZ_B;
			s.alu = (op[11:9] == 3'd0) ? `AP040_ALU_OR : (op[11:9] == 3'd1) ? `AP040_ALU_AND : `AP040_ALU_EOR;
		end
		16'h007C, 16'h027C, 16'h0A7C: begin      // ORI/ANDI/EORI #,SR
			s.ok = 1'b1; s.form = F_IMMSR; s.npre = 2'd1; s.sz = SZ_W;
			s.alu = (op[11:9] == 3'd0) ? `AP040_ALU_OR : (op[11:9] == 3'd1) ? `AP040_ALU_AND : `AP040_ALU_EOR;
		end
		16'b0000_1000_11??_????: begin           // BSET #,<ea> (before CAS: 0000 1ss0 11, ss=00 is BSET)
			s.form = F_BITS; s.npre = 2'd1; s.has_dst = 1'b1;
			s.sz = (s.dm == 3'd0) ? SZ_L : SZ_B; s.alu = `AP040_ALU_BSET;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0000_1110_0???_????, 16'b0000_1110_10??_????: begin   // MOVES <memory alterable> (before CAS)
			s.form = F_MOVES; s.npre = 2'd1; s.sz = op[7:6]; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
		end
		16'b0000_1??0_1111_1100: begin           // CAS2 (W/L): two extension words
			s.form = F_CAS2; s.npre = 2'd2; s.alu = `AP040_ALU_CMP;
			s.sz = op[9] ? SZ_L : SZ_W;
			s.ok = op[10];                        // 10 word, 11 long (no byte form)
		end
		16'b0000_1??0_11??_????: begin           // CAS Dc,Du,<memory alterable>
			s.form = F_CAS; s.npre = 2'd1; s.has_dst = 1'b1; s.alu = `AP040_ALU_CMP;
			s.sz = (op[10:9] == 2'b01) ? SZ_B : (op[10:9] == 2'b10) ? SZ_W : SZ_L;
			s.ok = (op[10:9] != 2'b00) && ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
		end
		16'b0000_0??0_11??_????: begin           // CHK2 / CMP2 <control>,Rn
			s.form = F_CHK2; s.npre = 2'd1; s.has_src = 1'b1;
			s.sz = op[10:9];
			s.ok = (op[10:9] != 2'b11) && ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0000_1000_????_????: begin           // BTST/BCHG/BCLR/BSET #,<ea>
			s.form = F_BITS; s.npre = 2'd1; s.has_dst = 1'b1;
			s.sz = (s.dm == 3'd0) ? SZ_L : SZ_B;
			s.alu = (op[7:6] == 2'd0) ? `AP040_ALU_BTST : (op[7:6] == 2'd1) ? `AP040_ALU_BCHG :
			        (op[7:6] == 2'd2) ? `AP040_ALU_BCLR : `AP040_ALU_BSET;
			// BTST #,<ea>: data except #imm (PC relative allowed); the others data alterable
			s.ok = (op[7:6] == 2'd0) ? (ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b0) && !(s.dm == 3'd7 && s.dr == 3'd4))
			                         : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0000_???1_??00_1???: begin           // MOVEP: the displacement word is the only extension
			s.ok = 1'b1; s.form = F_MOVEP; s.npre = 2'd1; s.sz = op[6] ? SZ_L : SZ_W;
		end
		16'b0000_???1_????_????: begin           // BTST/BCHG/BCLR/BSET Dn,<ea>
			s.form = F_BITD; s.has_dst = 1'b1;
			s.sz = (s.dm == 3'd0) ? SZ_L : SZ_B;
			s.alu = (op[7:6] == 2'd0) ? `AP040_ALU_BTST : (op[7:6] == 2'd1) ? `AP040_ALU_BCHG :
			        (op[7:6] == 2'd2) ? `AP040_ALU_BCLR : `AP040_ALU_BSET;
			// BTST Dn,<ea>: any data EA incl. #imm and PC relative
			s.ok = (op[7:6] == 2'd0) ? ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b0)
			                         : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0000_???0_????_????: begin           // ORI ANDI SUBI ADDI EORI CMPI #,<ea>
			if (ss != 2'b11 && op[11:9] != 3'd4 && op[11:9] != 3'd7) begin
				s.form = F_IMM; s.sz = ss; s.npre = (ss == SZ_L) ? 2'd2 : 2'd1; s.has_dst = 1'b1;
				case (op[11:9])
					3'd0: s.alu = `AP040_ALU_OR;   3'd1: s.alu = `AP040_ALU_AND;
					3'd2: s.alu = `AP040_ALU_SUB;  3'd3: s.alu = `AP040_ALU_ADD;
					3'd5: s.alu = `AP040_ALU_EOR;  default: s.alu = `AP040_ALU_CMP;
				endcase
				// CMPI: data EA, PC-relative allowed (68020+); the others data alterable
				s.ok = (op[11:9] == 3'd6) ? (ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b0) && !(s.dm == 3'd7 && s.dr == 3'd4))
				                          : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
			end
		end
		//------------------------------------------------ MOVE / MOVEA
		16'b0001_????_????_????, 16'b0010_????_????_????, 16'b0011_????_????_????: begin
			s.form = F_MOVE; s.alu = `AP040_ALU_MOVE;
			s.sz = (op[13:12] == 2'b01) ? SZ_B : (op[13:12] == 2'b11) ? SZ_W : SZ_L;
			s.has_src = 1'b1; s.has_dst = 1'b1;
			s.dm = op[8:6]; s.dr = op[11:9];
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0) &&
			       !(s.sz == SZ_B && s.sm == 3'd1) &&
			       ((s.dm == 3'd1) ? (s.sz != SZ_B) : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1));
		end
		//------------------------------------------------ group 4
		16'b0100_0000_11??_????: begin           // MOVE SR,<ea>
			s.form = F_MOVEFSR; s.sz = SZ_W; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_0010_11??_????: begin           // MOVE CCR,<ea>
			s.form = F_MOVEFCCR; s.sz = SZ_W; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_0100_11??_????: begin           // MOVE <ea>,CCR
			s.form = F_MOVE2CCR; s.sz = SZ_W; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b0100_0110_11??_????: begin           // MOVE <ea>,SR
			s.form = F_MOVE2SR; s.sz = SZ_W; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b0100_0000_????_????, 16'b0100_0100_????_????, 16'b0100_0110_????_????: begin  // NEGX NEG NOT
			s.form = F_UNARY; s.sz = ss; s.has_dst = 1'b1;
			s.alu = (op[10:9] == 2'b00) ? `AP040_ALU_NEGX : (op[10:9] == 2'b10) ? `AP040_ALU_NEG : `AP040_ALU_NOT;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_0010_????_????: begin           // CLR
			s.form = F_CLR; s.sz = ss; s.has_dst = 1'b1; s.alu = `AP040_ALU_CLR;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_1000_0000_1???: begin s.ok = 1'b1; s.form = F_LINK; s.npre = 2'd2; end  // LINK.L
		16'b0100_1000_0100_0???: begin s.ok = 1'b1; s.form = F_SWAP; s.alu = `AP040_ALU_SWAP; end
		16'b0100_1000_01??_????: begin           // PEA <ctl>
			s.form = F_PEA; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0100_1000_1000_0???: begin s.ok = 1'b1; s.form = F_EXT; s.sz = SZ_W; s.alu = `AP040_ALU_EXT; end
		16'b0100_1000_1100_0???: begin s.ok = 1'b1; s.form = F_EXT; s.sz = SZ_L; s.alu = `AP040_ALU_EXT; end
		// MOVEM (after EXT, which is its Dn mode): mask word first, then the EA
		16'b0100_1000_1???_????: begin           // MOVEM regs,<ctl alterable> / -(An)
			s.form = F_MOVEM; s.npre = 2'd1; s.has_dst = 1'b1; s.sz = op[6] ? SZ_L : SZ_W;
			s.ok = (s.dm == 3'd4) || (s.dm != 3'd3 && ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b1, 1'b1));
		end
		16'b0100_1100_1???_????: begin           // MOVEM <ctl> / (An)+,regs
			s.form = F_MOVEM; s.npre = 2'd1; s.has_src = 1'b1; s.sz = op[6] ? SZ_L : SZ_W;
			s.ok = (s.sm == 3'd3) || (s.sm != 3'd4 && ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0));
		end
		16'b0100_1001_1100_0???: begin s.ok = 1'b1; s.form = F_EXT; s.sz = SZ_L; s.alu = `AP040_ALU_EXTB; end
		16'h4AFC: s.ok = 1'b0;                   // ILLEGAL (vector 4)
		16'b0100_1010_11??_????: begin           // TAS <data alterable>
			s.form = F_TAS; s.sz = SZ_B; s.has_dst = 1'b1; s.alu = `AP040_ALU_TAS;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_1000_00??_????: begin           // NBCD <data alterable> (mode 001 = LINK.L, above)
			s.form = F_NBCD; s.sz = SZ_B; s.has_dst = 1'b1; s.alu = `AP040_ALU_NBCD;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_1100_00??_????, 16'b0100_1100_01??_????: begin   // MUL.L / DIV.L <data>
			s.form = F_MDL; s.npre = 2'd1; s.has_src = 1'b1; s.sz = SZ_L;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b0100_???1_10??_????, 16'b0100_???1_00??_????: begin   // CHK.W / CHK.L <data>,Dn
			s.form = F_CHK; s.has_src = 1'b1; s.sz = op[7] ? SZ_W : SZ_L;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'h4E76: begin s.ok = 1'b1; s.form = F_TRAPCC; end    // TRAPV
		16'b0100_1010_????_????: begin           // TST <ea> (68020+: An for W/L, #imm, PC relative)
			s.form = F_TST; s.sz = ss; s.has_src = 1'b1; s.alu = `AP040_ALU_TST;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0) && !(ss == SZ_B && s.sm == 3'd1);
		end
		16'b0100_???1_11??_????: begin           // LEA <ctl>,An
			s.form = F_LEA; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0100_1110_0101_0???: begin s.ok = 1'b1; s.form = F_LINK; s.npre = 2'd1; end  // LINK.W
		16'b0100_1110_0101_1???: begin s.ok = 1'b1; s.form = F_UNLK; end
		16'h4E74: begin s.ok = 1'b1; s.form = F_RTD; s.npre = 2'd1; end
		16'h4E77: begin s.ok = 1'b1; s.form = F_RTR; end
		16'b0100_1110_11??_????, 16'b0100_1110_10??_????: begin   // JMP / JSR <ctl>
			s.form = op[6] ? F_JMP : F_JSR; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0100_1110_0100_????: begin s.ok = 1'b1; s.form = F_TRAP; end
		16'b0100_1110_0111_101?: begin s.ok = 1'b1; s.form = F_MOVEC; s.npre = 2'd1; end
		16'b0100_1110_0110_????: begin s.ok = 1'b1; s.form = F_MOVEUSP; end   // MOVE An,USP / USP,An
		// CINV/CPUSH (scope 01 line, 10 page, 11 all): a privileged, serialising
		// no-op until M8 connects them to the caches (t_integer.s needs CINVA)
		// PFLUSHN (An) / PFLUSH (An) / PFLUSHAN / PFLUSHA; PTESTW (An) $F548, PTESTR (An)
		// $F568 -- the rest of the $F5 quadrant is F-line (M68040UM 3.7, lib/AP68040)
		16'b1111_0101_000?_????, 16'b1111_0101_0100_1???, 16'b1111_0101_0110_1???: begin
			s.ok = 1'b1; s.form = F_PMMU;
		end
		16'b1111_0100_???0_1???, 16'b1111_0100_???1_0???, 16'b1111_0100_???1_1???: begin
			s.ok = 1'b1; s.form = F_CINV;
		end
		//---------------------------------------- line F, coprocessor id 1: the FPU
		// With AP040_HAS_FPU = 0 every one of these is an UNIMPLEMENTED
		// floating-point instruction and takes vector 11 -- but it is decoded to
		// its full LENGTH and its effective address all the same, because the
		// MC68LC040's eight-word format $4 frame stacks the PC of the NEXT
		// instruction and the calculated effective address (M68040UM Appendix
		// A.5.2, Table 12-1).  Plan M10.0; decf turns F_FP into the exception.
		16'b1111_0010_00??_????: begin            // general: FMOVE, arithmetic, FMOVEM, FMOVECR
			s.ok = 1'b1; s.form = F_FP; s.npre = 2'd1;
			if (!have_x1) s.need_x1 = 1'b1;
			else if (x1[15:13] == 3'b010 && x1[12:10] != 3'b111) begin
				s.has_src = 1'b1; s.fpw = fp_imm_words(x1[12:10]);   // <ea>{fmt} -> FPn
			end else if (x1[15:13] == 3'b011) begin
				s.has_src = 1'b1; s.fpw = fp_imm_words(x1[12:10]);   // FPn -> <ea>{fmt}
			end else if (x1[15:14] == 2'b10) begin
				// opclass 100/101: FMOVE(M) to and from the control registers.
				// An immediate source is one longword PER SELECTED REGISTER
				// (lib/AP68040 S_FPU_CRI), so the list decides the length --
				// with fpw left at 0 an `FMOVEM.L #x,FPCR/FPSR` would be sized
				// as one longword and the next PC would be two words short.
				s.has_src = 1'b1;
				s.fpw = {1'b0, fp_cr_n(x1[12:10])} << 1;
			end else if (x1[15]) begin
				// opclass 110/111, the FP register lists: an effective address
				// too (their immediate form is not a legal encoding)
				s.has_src = 1'b1;
			end
			// x1[15:13] = 000 (FPm -> FPn), 001 (undefined opclass) and
			// 010 with specifier 111 (FMOVECR) have no effective address
		end
		16'b1111_0010_01??_????: begin            // FScc / FDBcc / FTRAPcc
			s.ok = 1'b1; s.form = F_FP; s.npre = 2'd1;
			if (op[5:3] == 3'b001)                       s.npre = 2'd2;   // FDBcc: + displacement
			else if (op[5:0] == 6'b111_010)              s.npre = 2'd2;   // FTRAPcc.W
			else if (op[5:0] == 6'b111_011)              s.npre = 2'd3;   // FTRAPcc.L
			else if (op[5:0] == 6'b111_100)              s.npre = 2'd1;   // FTRAPcc
			else                                         s.has_src = 1'b1; // FScc <ea>
		end
		16'b1111_0010_10??_????: begin s.ok = 1'b1; s.form = F_FP; s.npre = 2'd1; end   // FBcc.W
		16'b1111_0010_11??_????: begin s.ok = 1'b1; s.form = F_FP; s.npre = 2'd2; end   // FBcc.L
		16'b1111_0011_00??_????, 16'b1111_0011_01??_????: begin                          // FSAVE / FRESTORE
			s.ok = 1'b1; s.form = F_FP; s.has_src = 1'b1;
		end
		16'b1111_0110_0010_0???: begin s.ok = 1'b1; s.form = F_MOVE16; s.npre = 2'd1; s.sz = SZ_L; end  // (Ax)+,(Ay)+
		16'b1111_0110_000?_????: begin s.ok = 1'b1; s.form = F_MOVE16; s.npre = 2'd2; s.sz = SZ_L; end  // abs.L forms
		16'h4E71: begin s.ok = 1'b1; s.form = F_NOP; end
		16'h4E70: begin s.ok = 1'b1; s.form = F_RESET; end
		16'h4E72: begin s.ok = 1'b1; s.form = F_STOP; s.npre = 2'd1; end
		16'h4E73: begin s.ok = 1'b1; s.form = F_RTE; end
		16'h4E75: begin s.ok = 1'b1; s.form = F_RTS; end
		//------------------------------------------------ group 5
		16'b0101_????_1100_1???: begin s.ok = 1'b1; s.form = F_DBCC; s.npre = 2'd1; end
		16'b0101_????_1111_1010: begin s.ok = 1'b1; s.form = F_TRAPCC; s.npre = 2'd1; end   // TRAPcc.W
		16'b0101_????_1111_1011: begin s.ok = 1'b1; s.form = F_TRAPCC; s.npre = 2'd2; end   // TRAPcc.L
		16'b0101_????_1111_1100: begin s.ok = 1'b1; s.form = F_TRAPCC; end                 // TRAPcc
		16'b0101_????_11??_????: begin           // Scc <data alterable>
			s.form = F_SCC; s.sz = SZ_B; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0101_????_????_????: begin           // ADDQ / SUBQ #,<alterable>
			s.form = F_ADDQ; s.sz = ss; s.has_dst = 1'b1;
			s.alu = op[8] ? `AP040_ALU_SUB : `AP040_ALU_ADD;
			s.ok = ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b0, 1'b1) && !(ss == SZ_B && s.dm == 3'd1);
		end
		//------------------------------------------------ Bcc / MOVEQ
		16'b0110_????_????_????: begin
			s.ok = 1'b1; s.form = F_BCC;
			s.npre = (op[7:0] == 8'h00) ? 2'd1 : (op[7:0] == 8'hFF) ? 2'd2 : 2'd0;
		end
		16'b0111_???0_????_????: begin s.ok = 1'b1; s.form = F_MOVEQ; end
		//------------------------------------------------ two-operand groups 8 9 B C D
		16'b1100_???1_0100_0???, 16'b1100_???1_0100_1???, 16'b1100_???1_1000_1???: begin
			s.ok = 1'b1; s.form = F_EXG;
		end
		16'b1001_????_11??_????, 16'b1011_????_11??_????, 16'b1101_????_11??_????: begin  // SUBA CMPA ADDA
			s.form = F_ADDA; s.sz = op[8] ? SZ_L : SZ_W; s.has_src = 1'b1;
			s.alu = grp_alu(op[15:12], 1'b0);
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0);
		end
		16'b1011_???1_??00_1???: begin           // CMPM (Ay)+,(Ax)+
			s.form = F_CMPM; s.sz = ss; s.ok = (ss != 2'b11); s.alu = `AP040_ALU_CMP;
		end
		16'b1001_???1_??00_????, 16'b1101_???1_??00_????: begin   // SUBX / ADDX (register or -(An))
			s.form = F_ADDX; s.sz = ss; s.ok = (ss != 2'b11);
			s.alu = op[14] ? `AP040_ALU_ADDX : `AP040_ALU_SUBX;
		end
		16'b1000_???0_11??_????, 16'b1000_???1_11??_????,
		16'b1100_???0_11??_????, 16'b1100_???1_11??_????: begin   // DIVU/DIVS.W, MULU/MULS.W <data>,Dn
			s.form = F_MDW; s.has_src = 1'b1; s.sz = SZ_W;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b1000_???1_0000_????, 16'b1100_???1_0000_????: begin   // SBCD / ABCD (Dy,Dx or -(Ay),-(Ax))
			s.ok = 1'b1; s.form = F_BCD; s.sz = SZ_B;
			s.alu = op[14] ? `AP040_ALU_ABCD : `AP040_ALU_SBCD;
		end
		16'b1000_???1_0100_????: begin s.ok = 1'b1; s.form = F_PACK; s.npre = 2'd1; end
		16'b1000_???1_1000_????: begin s.ok = 1'b1; s.form = F_UNPK; s.npre = 2'd1; end
		16'b1000_???1_??00_????, 16'b1100_???1_??00_????: s.ok = 1'b0;  // reserved
		16'b1000_????_????_????, 16'b1001_????_????_????, 16'b1011_????_????_????,
		16'b1100_????_????_????, 16'b1101_????_????_????: begin
			if (ss != 2'b11) begin
				s.sz = ss;
				if (!op[8] || op[15:12] == 4'hB && !op[8]) begin      // <ea>,Dn
					s.form = F_EA_DN; s.has_src = 1'b1;
					s.alu = grp_alu(op[15:12], 1'b0);
					an_ok = (op[15:12] == 4'h9 || op[15:12] == 4'hB || op[15:12] == 4'hD) && ss != SZ_B;
					s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0) && (s.sm != 3'd1 || an_ok);
				end else begin                  // Dn,<ea>  (EOR: data alterable incl. Dn)
					s.form = F_DN_EA; s.has_dst = 1'b1;
					s.alu = grp_alu(op[15:12], 1'b1);
					s.ok = (op[15:12] == 4'hB) ? ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1)
					                           : ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
				end
			end
		end
		//------------------------------------------------ group E: shifts, bitfields
		16'b1110_1???_11??_????: begin           // bitfields: extension word first
			s.form = F_BF; s.npre = 2'd1; s.has_dst = 1'b1; s.sz = SZ_L;
			// Dn or a control EA; CHG/CLR/SET/INS need it alterable (no PC relative)
			s.ok = (s.dm == 3'd0) ||
			       ((op[8] == 1'b0 && op[10:9] != 2'b00) || op[10:8] == 3'b110 || op[10:8] == 3'b111 ?
			        ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b1, 1'b1) :
			        ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b1, 1'b0));
		end
		16'b1110_0???_11??_????: begin           // memory shift/rotate by one, word
			s.form = F_SHM; s.sz = SZ_W; s.has_dst = 1'b1;
			s.alu = shift_alu(op[10:9], op[8]);
			s.ok = ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
		end
		16'b1110_????_????_????: begin           // register shift/rotate
			s.ok = 1'b1; s.form = F_SHR; s.sz = ss;
			s.alu = shift_alu(op[4:3], op[8]);
		end
		default: s.ok = 1'b0;
	endcase
	return s;
endfunction

//--------------------------------------------------------------- gather
//
// Combinational logic here is written as PURE functions (every input an
// argument) assigned with assign: Icarus derives a continuous assignment's
// sensitivity from the arguments only, and an always block that calls a
// function while reading a variable it writes can re-trigger itself forever
// (found on the first run of this file).

reg [10:0][15:0] wbuf;     // words gathered so far (word 0 = opcode)
reg        [3:0] wcnt;     // how many
reg       [10:0] werr;     // which are poisoned
reg       [31:0] g_pc;     // address of word 0

// the buffer as it will be with the incoming word appended
function automatic logic [10:0][15:0] view(input logic [10:0][15:0] wb, input logic [3:0] n,
                                           input logic [1:0] tk, input logic [15:0] w0,
                                           input logic [15:0] w1);
	logic [10:0][15:0] v;
	v = wb;
	if (tk >= 2'd1 && n <= 4'd10) v[n] = w0;
	if (tk == 2'd2 && n <= 4'd9)  v[n + 1] = w1;
	return v;
endfunction

// words available this clock (the queue hands them out in order)
wire        [1:0] avail  = q_v0 ? (q_v1 ? 2'd2 : 2'd1) : 2'd0;
wire        [3:0] vcnt   = wcnt + {2'd0, avail};
wire [10:0][15:0] vbuf   = view(wbuf, wcnt, avail, q_w0, q_w1);
function automatic logic [10:0] view_e(input logic [10:0] we, input logic [3:0] n, input logic [1:0] tk,
                                       input logic e0, input logic e1);
	logic [10:0] v;
	v = we;
	if (tk >= 2'd1 && n <= 4'd10) v[n] = e0;
	if (tk == 2'd2 && n <= 4'd9)  v[n + 1] = e1;
	return v;
endfunction
wire       [10:0] verr   = view_e(werr, wcnt, avail, q_e0, q_e1);
wire       [31:0] vpc    = (wcnt == 4'd0) ? q_pc0 : g_pc;

// total length of the instruction in the view, if known
typedef struct packed {
	shape_t      sh;
	logic [4:0]  tot;      // total words needed (valid when !more)
	logic        more;     // need at least one more word before tot is known
	logic        ea_bad;
} len_t;

function automatic len_t lenf(input logic [10:0][15:0] vb, input logic [3:0] vc);
	len_t l; elen_t e; int k;
	l = '0;
	l.sh = shape(vb[0], vb[1], vc > 4'd1);
	k = 1 + l.sh.npre;
	// an FP opcode is sized by its extension word: wait for it (M10.0)
	if (l.sh.need_x1) l.more = 1'b1;
	if (l.sh.ok && l.sh.has_src && !l.more) begin
		e = ea_len(l.sh.sm, l.sh.sr, l.sh.sz, vb[k], (vc > k), l.sh.fpw);
		if (e.need0) l.more = 1'b1;
		l.ea_bad = l.ea_bad | e.bad;
		k = k + e.n;
	end
	if (l.sh.ok && l.sh.has_dst && !l.more) begin
		e = ea_len(l.sh.dm, l.sh.dr, l.sh.sz, vb[k], (vc > k), 4'd0);
		if (e.need0) l.more = 1'b1;
		l.ea_bad = l.ea_bad | e.bad;
		k = k + e.n;
	end
	l.tot = l.sh.ok ? k[4:0] : 5'd1;
	return l;
endfunction

wire len_t   ln  = lenf(vbuf, vcnt);
wire shape_t sh  = ln.sh;
wire [4:0]   tot = ln.tot;
wire complete = (vcnt != 4'd0) && !ln.more && ({1'b0, vcnt} >= tot);

//--------------------------------------------------------------- decode

function automatic ea_t ea_reg(input logic [2:0] kind, input logic [4:0] r);
	ea_t e;
	e = '0; e.kind = kind; e.reg_n = r; e.idx_reg = R_NONE;
	e.mode = (kind == EK_AREG) ? 3'd1 : 3'd0; e.mreg = r[2:0];
	return e;
endfunction

function automatic ea_t ea_imm(input logic [31:0] v);
	ea_t e;
	e = '0; e.kind = EK_IMM; e.bd = v; e.reg_n = R_NONE; e.idx_reg = R_NONE;
	e.mode = 3'd7; e.mreg = 3'd4;
	return e;
endfunction

// (An) / (An)+ / -(An) / (d,An) on A7, for the implied stack operands
function automatic ea_t ea_sp(input logic [1:0] upd, input logic [31:0] disp);
	ea_t e;
	e = '0; e.kind = EK_MEM; e.base_en = 1'b1; e.reg_n = R_A7L; e.upd = upd; e.bd = disp;
	e.idx_reg = R_NONE;
	e.mode = (upd == UPD_PRE) ? 3'd4 : (upd == UPD_POST) ? 3'd3 : 3'd2; e.mreg = 3'd7;
	return e;
endfunction

// (M9.T) The non-branch instructions the MC68040 counts as changes of flow
// for T0 tracing, because they synchronise or refill the instruction
// pipeline.  COPIED VERBATIM from the reference core's `t0_special`
// (lib/AP68040 rtl/ap040_core.v), comments and all, for the same reason the
// FPSP opmode list is copied in D22: two hand-written copies of a list this
// arbitrary will disagree eventually, and the reference's is the one that was
// narrowed against hardware.  gencpu marks these with trace_t0_68040_only().
// Taken branches and returns are NOT here -- they are known from the class --
// and FDBcc / the FMOVEM store forms set the bit in their own decode arms,
// the way the reference sets `t0_force`.
function automatic logic t0_special(input logic [15:0] op);
	return
	    op == 16'h007c || op == 16'h027c || op == 16'h0a7c ||  // to SR
	    op == 16'h4e71 ||                                      // NOP
	    // STOP is absent: it makes its own T0 decision (the changed-bits
	    // rule, in EA-fetch).
	    op == 16'h4e7b ||                                      // MOVEC to CR
	    (op & 16'hfff8) == 16'h4e60 ||                         // MOVE An,USP
	    // MOVE USP,An ($4E68-F) does not trace: gencpu marks only
	    // i_MVR2USP with trace_t0_68040_only, the same on-silicon
	    // narrowing hardware already proved for MOVEC ($4E7B only).
	    (op & 16'hffc0) == 16'h46c0 ||                         // MOVE to SR
	    (op[15:12] == 4'h0 && op[11:8] == 4'he &&
	     op[7:6] != 2'b11) ||                                  // MOVES
	    (op[15:12] == 4'h0 && op[11] && !op[8] && op[7:6] == 2'b11 &&
	     op[10:9] != 2'b00) ||                                 // CAS/CAS2
	    // op[8] discriminates CAS ($0AC0/$0CC0/$0EC0, clear) from the
	    // dynamic bit ops BSET Dn,<ea> for D5-D7 ($0Bxx/$0Dxx/$0Fxx,
	    // set): hardware cputest basic/all failed BSET.B D5,(A6)
	    // under T0 with a phantom trace before the bit was added.
	    op[15:8] == 8'hf4 || op[15:8] == 8'hf5 ||              // CINV/CPUSH/PFLUSH/PTEST
	    op[15:8] == 8'hf3;                                     // FSAVE/FRESTORE
endfunction

function automatic id_t decf(input logic [10:0][15:0] vbuf, input logic [31:0] vpc,
                             input shape_t sh, input logic [4:0] tot_w, input logic ea_bad);
	id_t d;
	int tot;
	logic [15:0] op, x1;
	logic [31:0] ipre;
	logic        s2set;        // the destination EA has its own size (size2)
	logic [1:0]  s2;
	int ks, kd; elen_t e;
	logic fsave_ok, frest_ok;   // the coprocessor-id-1 state instructions' legal EA modes
	logic fp_ireg;              // (M10.1) an FP format that fits in a data register
	logic [15:0] fpw0;          // ... and the first word of an FP immediate
	logic [2:0] fp_crsel;       // (M10.2) the control-register list, FPCR/FPSR/FPIAR
	logic fp_crmulti;           // ... more than one of them
	logic [2:0] fp_crn;         // ... how many
	logic fp_crbad;             // ... and an effective address the rules reject
	logic fp_mvst;              // (M10.4) FMOVEM: registers -> memory
	logic fp_mvbad;             // ... an effective address the 68040 rejects
	logic [3:0] fp_mvn;         // ... how many registers the list selects
	tot = tot_w;
	op = vbuf[0];
	x1 = vbuf[1];
	d = '0;
	fp_ireg = 1'b0; fpw0 = 16'd0;
	fp_crsel = 3'd0; fp_crmulti = 1'b0; fp_crn = 3'd0; fp_crbad = 1'b0;
	fp_mvst = 1'b0; fp_mvbad = 1'b0; fp_mvn = 4'd0;
	s2set = 1'b0; s2 = SZ_L;
	d.reg_c = R_NONE;
	d.reg_d = R_NONE;
	d.pc = vpc;
	d.next_pc = vpc + 32'(2 * tot);
	d.opcode = op;
	d.ext = x1;
	d.size = sh.sz;
	d.alu = sh.alu;
	d.cond = op[11:8];
	d.src.idx_reg = R_NONE; d.dst.idx_reg = R_NONE;
	// FSAVE: control alterable or -(An).  FRESTORE: control or (An)+.
	fsave_ok = (op[5:3] == 3'd2) || (op[5:3] == 3'd4) || (op[5:3] == 3'd5) || (op[5:3] == 3'd6) ||
	           (op[5:3] == 3'd7 && op[2:0] <= 3'd1);
	frest_ok = (op[5:3] == 3'd2) || (op[5:3] == 3'd3) || (op[5:3] == 3'd5) || (op[5:3] == 3'd6) ||
	           (op[5:3] == 3'd7 && op[2:0] <= 3'd3);
	d.src.reg_n = R_NONE; d.dst.reg_n = R_NONE;
	// the pre-EA immediate (B: low byte of word 1, W: word 1, L: words 1-2)
	ipre = (sh.sz == SZ_L) ? {x1, vbuf[2]} : (sh.sz == SZ_W) ? {16'd0, x1} : {24'd0, x1[7:0]};
	// EA words
	ks = 1 + sh.npre;
	e = ea_len(sh.sm, sh.sr, sh.sz, vbuf[ks], 1'b1, sh.fpw);
	kd = ks + (sh.has_src ? int'(e.n) : 0);
	if (sh.has_src) d.src = ea_build(sh.sm, sh.sr, sh.sz, vbuf, ks, vpc + 32'(2 * ks));
	if (sh.has_dst) d.dst = ea_build(sh.dm, sh.dr, sh.sz, vbuf, kd, vpc + 32'(2 * kd));
	d.cls = CL_EXC; d.exc_vec = 8'd4;           // default: illegal
	if (op[15:12] == 4'hA) d.exc_vec = 8'd10;   // A-line
	if (op[15:12] == 4'hF) d.exc_vec = 8'd11;   // F-line (no FPU yet)
	if (sh.ok && !ea_bad) begin
		case (sh.form)
			F_MOVE: begin
				d.cls = CL_ALU;
				d.wr_ccr = (sh.dm != 3'd1);         // MOVEA leaves the CCR alone
			end
			F_MOVEQ: begin
				d.cls = CL_ALU; d.alu = `AP040_ALU_MOVE; d.size = SZ_L; d.wr_ccr = 1'b1;
				d.src = ea_imm(sext8(op[7:0]));
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
			end
			F_IMM: begin                        // #imm,<ea>; CMPI writes nothing
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_imm(ipre);
				d.nowrite = (sh.alu == `AP040_ALU_CMP);
			end
			F_IMMCCR: begin d.cls = CL_CCROP; d.src = ea_imm({24'd0, x1[7:0]}); end
			F_IMMSR:  begin d.cls = CL_SROP; d.priv = 1'b1; d.serialize = 1'b1; d.src = ea_imm({16'd0, x1}); end
			F_UNARY: begin d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1; end
			F_CLR:   begin d.cls = CL_ALU; d.wr_ccr = 1'b1; end   // a pure write on the 68040
			F_TST:   begin d.cls = CL_ALU; d.wr_ccr = 1'b1; d.nowrite = 1'b1; end
			F_EXT, F_SWAP: begin
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]});
			end
			F_PEA: begin
				d.cls = CL_PEA; d.size = SZ_L;
				d.dst = ea_sp(UPD_PRE, 32'd0);
			end
			F_LEA: begin
				d.cls = CL_LEA; d.size = SZ_L;
				d.dst = ea_reg(EK_AREG, {2'b01, op[11:9]});
			end
			F_LINK: begin                       // push An, An = SP, SP += d
				d.cls = CL_LINK; d.size = SZ_L;
				d.imm = (op[15:8] == 8'h48) ? {x1, vbuf[2]} : sext16(x1);
				d.src = ea_reg(EK_AREG, {2'b01, op[2:0]});
				d.dst = ea_sp(UPD_PRE, 32'd0);
			end
			F_UNLK: begin                       // SP = An + 4, An = (An)
				d.cls = CL_UNLK; d.size = SZ_L;
				d.src = '0; d.src.kind = EK_MEM; d.src.base_en = 1'b1; d.src.reg_n = {2'b01, op[2:0]};
				d.src.idx_reg = R_NONE; d.src.mode = 3'd2; d.src.mreg = op[2:0];
				d.dst = ea_reg(EK_AREG, {2'b01, op[2:0]});
			end
			F_RTS: begin d.cls = CL_RTS; d.size = SZ_L; d.src = ea_sp(UPD_POST, 32'd0); end
			F_RTD: begin
				d.cls = CL_RTD; d.size = SZ_L; d.src = ea_sp(UPD_POST, 32'd0);
				d.imm = sext16(x1);
			end
			F_RTR: begin                        // CCR from (SP), PC from 2(SP), SP += 6
				d.cls = CL_RTR; d.size = SZ_W; d.src = ea_sp(UPD_NONE, 32'd0);
				s2set = 1'b1; s2 = SZ_L;         // the PC at 2(SP) is a long
				d.dst = ea_sp(UPD_NONE, 32'd2); d.rmw = 1'b1;
			end
			F_MOVEFCCR: begin d.cls = CL_MOVEFSR; d.ccr_only = 1'b1; end
			F_MOVEFSR:  begin d.cls = CL_MOVEFSR; d.priv = 1'b1; end
			F_MOVE2CCR: d.cls = CL_MOVE2CCR;
			F_MOVE2SR:  begin d.cls = CL_MOVE2SR; d.priv = 1'b1; d.serialize = 1'b1; end
			F_ADDQ: begin                       // #1-8; to An: long, no CCR
				d.cls = CL_ALU; d.rmw = 1'b1;
				d.src = ea_imm({28'd0, (op[11:9] == 3'd0), op[11:9]});
				d.wr_ccr = (sh.dm != 3'd1);
				if (sh.dm == 3'd1) d.size = SZ_L;
			end
			F_EA_DN: begin                      // <ea>,Dn; CMP writes nothing
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				d.nowrite = (sh.alu == `AP040_ALU_CMP);
			end
			F_DN_EA: begin                      // Dn,<ea>
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_reg(EK_DREG, {2'b00, op[11:9]});
			end
			F_ADDA: begin                       // ADDA/SUBA: no CCR; CMPA: CCR only
				d.cls = CL_ALU; d.rmw = 1'b1;
				d.dst = ea_reg(EK_AREG, {2'b01, op[11:9]});
				d.wr_ccr  = (sh.alu == `AP040_ALU_CMP);
				d.nowrite = (sh.alu == `AP040_ALU_CMP);
			end
			F_ADDX: begin                       // Dy,Dx or -(Ay),-(Ax)
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				if (!op[3]) begin
					d.src = ea_reg(EK_DREG, {2'b00, op[2:0]});
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.src = ea_build(3'd4, op[2:0], sh.sz, vbuf, 1, vpc);
					d.dst = ea_build(3'd4, op[11:9], sh.sz, vbuf, 1, vpc);
				end
			end
			F_CMPM: begin                       // (Ay)+,(Ax)+
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1; d.nowrite = 1'b1;
				d.src = ea_build(3'd3, op[2:0], sh.sz, vbuf, 1, vpc);
				d.dst = ea_build(3'd3, op[11:9], sh.sz, vbuf, 1, vpc);
			end
			F_EXG: begin
				d.cls = CL_EXG; d.size = SZ_L;
				case (op[7:3])
					5'b01000: begin d.src = ea_reg(EK_DREG, {2'b00, op[11:9]}); d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]}); end
					5'b01001: begin d.src = ea_reg(EK_AREG, {2'b01, op[11:9]}); d.dst = ea_reg(EK_AREG, {2'b01, op[2:0]}); end
					default:  begin d.src = ea_reg(EK_DREG, {2'b00, op[11:9]}); d.dst = ea_reg(EK_AREG, {2'b01, op[2:0]}); end
				endcase
			end
			//-------------------------------------------- M3
			F_BITD, F_BITS: begin               // bit number from Dn or #; mod 32 (Dn) / 8 (memory) in EX
				d.cls = CL_BIT; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = (sh.form == F_BITD) ? ea_reg(EK_DREG, {2'b00, op[11:9]}) : ea_imm({24'd0, x1[7:0]});
				d.nowrite = (sh.alu == `AP040_ALU_BTST);
			end
			F_CAS: begin                        // CAS Dc,Du,<ea>: Dc = src, Du = reg_c
				d.cls = CL_CAS; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_reg(EK_DREG, {2'b00, x1[2:0]});
				d.reg_c = {2'b00, x1[8:6]};
			end
			F_CHK2: begin                       // bounds at <ea>, <ea>+size; Rn from the ext word
				d.cls = CL_CHK2; d.wr_ccr = 1'b1; d.nowrite = 1'b1;
				d.dst = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
			end
			F_CHK: begin                        // bound = src, Dn = dst (read only)
				d.cls = CL_CHK; d.wr_ccr = 1'b1; d.nowrite = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
			end
			F_TAS, F_NBCD: begin d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1; end
			F_MDW: begin                        // 16 x 16 -> 32, 32 / 16 -> 16r:16q
				d.cls = CL_MULDIV; d.wr_ccr = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				d.imm[0] = !op[14];             // divide (group 8)
				d.imm[1] = op[8];               // signed
			end
			F_MDL: begin                        // MUL.L / DIV.L: Dl/Dq in ext 14:12, Dh/Dr in 2:0
				d.cls = CL_MULDIV; d.wr_ccr = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, x1[14:12]});
				d.reg_c = {2'b00, x1[2:0]};
				d.imm[0] = op[6];               // divide
				d.imm[1] = x1[11];              // signed
				d.imm[2] = 1'b1;                // long form
				d.imm[3] = x1[10];              // 64-bit (Dh:Dl product / Dr:Dq dividend)
			end
			F_TRAPCC: begin
				d.cls = CL_TRAPCC;
				if (op == 16'h4E76) d.cond = 4'h9;   // TRAPV: V set
			end
			F_BCD: begin                        // ABCD/SBCD Dy,Dx or -(Ay),-(Ax)
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				if (!op[3]) begin
					d.src = ea_reg(EK_DREG, {2'b00, op[2:0]});
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.src = ea_build(3'd4, op[2:0], SZ_B, vbuf, 1, vpc);
					d.dst = ea_build(3'd4, op[11:9], SZ_B, vbuf, 1, vpc);
				end
			end
			F_PACK, F_UNPK: begin               // Dy,Dx,#adj or -(Ay),-(Ax),#adj
				d.cls = (sh.form == F_PACK) ? CL_PACK : CL_UNPK;
				d.imm = {16'd0, x1};
				d.size = (sh.form == F_PACK) ? SZ_W : SZ_B;    // the source
				s2set = 1'b1; s2 = (sh.form == F_PACK) ? SZ_B : SZ_W;   // the destination
				if (!op[3]) begin
					d.src = ea_reg(EK_DREG, {2'b00, op[2:0]});
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.src = ea_build(3'd4, op[2:0], d.size, vbuf, 1, vpc);
					d.dst = ea_build(3'd4, op[11:9], s2, vbuf, 1, vpc);
				end
			end
			F_SHR: begin                        // count #1-8 or Dn (mod 64), Dn destination
				d.cls = CL_SHIFT; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = op[5] ? ea_reg(EK_DREG, {2'b00, op[11:9]}) : ea_imm({28'd0, (op[11:9] == 3'd0), op[11:9]});
				d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]});
			end
			F_MOVE16: begin                     // run by the MOVEM sequencer: imm[2] = MOVE16
				// imm[3]/imm[4]: the source / destination register is postincremented by 16
				d.cls = CL_MOVEM; d.size = SZ_L;
				if (op[5]) begin                  // MOVE16 (Ax)+,(Ay)+
					d.imm = {27'd0, 1'b1, 1'b1, 1'b1, 2'b00};
					d.src = ea_reg(EK_MEM, {2'b01, op[2:0]}); d.src.base_en = 1'b1; d.src.mode = 3'd2;
					d.dst = ea_reg(EK_MEM, {2'b01, x1[14:12]}); d.dst.base_en = 1'b1; d.dst.mode = 3'd2;
				end else begin
					// opmode 00 (Ay)+ -> abs, 01 abs -> (Ay)+, 10 (Ay) -> abs, 11 abs -> (Ay)
					d.imm = {27'd0, (op[4:3] == 2'b01), (op[4:3] == 2'b00), 1'b1, 2'b00};
					if (op[3]) begin
						d.src = ea_imm({x1, vbuf[2]}); d.src.kind = EK_MEM;
						d.dst = ea_reg(EK_MEM, {2'b01, op[2:0]}); d.dst.base_en = 1'b1; d.dst.mode = 3'd2;
					end else begin
						d.src = ea_reg(EK_MEM, {2'b01, op[2:0]}); d.src.base_en = 1'b1; d.src.mode = 3'd2;
						d.dst = ea_imm({x1, vbuf[2]}); d.dst.kind = EK_MEM;
					end
				end
			end
			F_MOVEP: begin                      // run by the MOVEM sequencer: imm[1] = MOVEP
				d.cls = CL_MOVEM; d.imm = {30'd0, 1'b1, !op[7]};
				d.ext = op[6] ? 16'h000F : 16'h0003;   // 4 or 2 bytes
				if (!op[7]) begin
					d.src = ea_build(3'd5, op[2:0], SZ_B, vbuf, 1, vpc + 32'd2);
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.dst = ea_build(3'd5, op[2:0], SZ_B, vbuf, 1, vpc + 32'd2);
					d.src = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end
			end
			F_MOVEM: begin                      // imm[0]: memory to registers; ext = the mask
				d.cls = CL_MOVEM; d.imm = {31'd0, op[10]};
			end
			F_CAS2: begin                       // CAS2 Dc1:Dc2,Du1:Du2,(Rn1):(Rn2)
				d.cls = CL_CAS2; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.ext2 = vbuf[2];
				d.src = ea_reg(EK_MEM, {1'b0, x1[15], x1[14:12]});             // (Rn1)
				d.src.base_en = 1'b1; d.src.mode = 3'd2;
				d.dst = ea_reg(EK_MEM, {1'b0, vbuf[2][15], vbuf[2][14:12]});   // (Rn2)
				d.dst.base_en = 1'b1; d.dst.mode = 3'd2;
				d.reg_c = {2'b00, x1[8:6]};                                    // Du1
				d.reg_d = {2'b00, vbuf[2][8:6]};                               // Du2
			end
			F_BF: begin                         // field at Dn or <ea>; ext: Dn, Do/offset, Dw/width
				d.cls = CL_BF; d.wr_ccr = 1'b1;
				d.alu = {3'd0, op[10:8]};         // 0 TST 1 EXTU 2 CHG 3 EXTS 4 CLR 5 FFO 6 SET 7 INS
				d.src = ea_reg(EK_DREG, {2'b00, x1[14:12]});   // INS source / EXTU EXTS FFO destination
				d.reg_c = x1[11] ? {2'b00, x1[8:6]} : R_NONE;  // offset in Dn
				d.reg_d = x1[5]  ? {2'b00, x1[2:0]} : R_NONE;  // width in Dn
			end
			F_SHM: begin                        // <ea> by one, word
				d.cls = CL_SHIFT; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_imm(32'd1);
			end
			F_BCC: begin                        // Bcc / BRA / BSR
				d.cls = (op[11:8] == 4'h1) ? CL_BSR : CL_BCC;
				d.btarget = vpc + 32'd2 + ((op[7:0] == 8'h00) ? sext16(x1) :
				                           (op[7:0] == 8'hFF) ? {x1, vbuf[2]} : sext8(op[7:0]));
				if (op[11:8] == 4'h1) begin      // BSR: the push is a store to -(A7)
					d.size = SZ_L;
					d.dst = ea_sp(UPD_PRE, 32'd0);
				end
			end
			F_DBCC: begin
				d.cls = CL_DBCC; d.size = SZ_W;
				d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]});
				d.btarget = vpc + 32'd2 + sext16(x1);
			end
			F_SCC: d.cls = CL_SCC;
			F_JMP: begin d.cls = CL_JMP; d.size = SZ_L; end
			F_JSR: begin                        // JSR: the push is a store to -(A7)
				d.cls = CL_JSR; d.size = SZ_L;
				d.dst = ea_sp(UPD_PRE, 32'd0);
			end
			F_TRAP: begin d.cls = CL_EXC; d.exc_vec = 8'd32 + {4'd0, op[3:0]}; d.exc_next = 1'b1; end
			F_MOVEC: begin
				d.cls = CL_MOVEC; d.priv = 1'b1; d.serialize = 1'b1;
				case (x1[11:0])
					12'h000: d.imm[3:0] = CR_SFC;
					12'h001: d.imm[3:0] = CR_DFC;
					12'h002: d.imm[3:0] = CR_CACR;
					12'h801: d.imm[3:0] = CR_VBR;
					12'h800: d.imm[3:0] = CR_USP;
					12'h804: d.imm[3:0] = CR_ISP;
					12'h803: d.imm[3:0] = CR_MSP;
					// the MMU registers are accepted and stored before M7 (plan M4:
					// 68040.library probes them); M68040UM 3.1, PRM MOVEC 4-138
					12'h003: d.imm[3:0] = CR_TC;
					12'h004: d.imm[3:0] = CR_ITT0;
					12'h005: d.imm[3:0] = CR_ITT1;
					12'h006: d.imm[3:0] = CR_DTT0;
					12'h007: d.imm[3:0] = CR_DTT1;
					12'h805: d.imm[3:0] = CR_MMUSR;
					12'h806: d.imm[3:0] = CR_URP;
					12'h807: d.imm[3:0] = CR_SRP;
					default: d.imm[3:0] = CR_BAD;
				endcase
				d.imm[4] = op[0];                // 1 = Rn -> Rc
				d.src = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
				// an unknown selector is illegal -- in supervisor mode; MOVEC is
				// privileged first (user mode: vector 8 for every selector,
				// cputest MOVEC2; EA-fetch checks priv before CL_EXC)
				if (d.imm[3:0] == CR_BAD) begin
					d.cls = CL_EXC; d.exc_vec = 8'd4;
				end
			end
			// CINV / CPUSH (M68040UM 4.5, p. 4-11): privileged, serialising;
			// the caches here are write-through (nothing dirty), so a push
			// invalidates exactly as an invalidate does -- the reference does
			// the same.  imm[1] = instruction cache, imm[0] = data cache
			// (ir[7]/ir[6]); the scope field (ir[4:3]) is widened to ALL,
			// which is safe, and 00 is not a CINV encoding at all (shape():
			// it falls through to the F-line trap, as M68040UM 4.5 requires)
			F_FP: begin
				// Coprocessor id 1 with no FPU: the MC68LC040 configuration.
				// Which frame this gets is PLAN.md divergence D18:
				//   * a well-formed floating-point instruction -> vector 11
				//     with the eight-word FORMAT $4 frame, the PC of the next
				//     instruction, the calculated effective address and the
				//     faulted instruction's own PC (M68040UM Appendix A.5.2,
				//     Table 12-1);
				//   * the reserved opclass (x1[15:13] = 001), and an opmode in
				//     fp_opmode_class()'s F-line class -> vector 11 with the
				//     ordinary format $0 frame and the instruction's own PC:
				//     the encoding is rejected BEFORE the FPU is asked about;
				//   * an opmode in $78..$7F -> vector 4.
				// A coprocessor id that is not 1 never reaches here: it is not
				// an F_FP shape and keeps the format $0 default above.
				d.cls = CL_EXC; d.exc_vec = 8'd11; d.exc_fmt = 4'd4; d.exc_next = 1'b1;
				// FSAVE and FRESTORE are privileged, and the privilege violation
				// comes FIRST: in user mode they take vector 8 and never reach the
				// F-line at all (M68040UM 8.2.5; WinUAE does the same, PLAN.md D18).
				// EA-fetch checks i.priv before it looks at CL_EXC, so this is all
				// it takes.
				// ... but only when the ENCODING is a real FSAVE/FRESTORE.  A
				// malformed one is an F-line first and is not privileged at all:
				// the cputest corpus sweeps $F300 and $F301 (FSAVE with a data
				// register as its operand) in USER mode and expects vector 11,
				// not the privilege violation.  So encoding, then privilege,
				// then the FPU.
				// FSAVE takes control-alterable or -(An); FRESTORE takes control
				// or (An)+ (PC-relative included).  M68000PRM, and lib/AP68040's
				// own cpid-1 arms.
				d.priv = (op[8:6] == 3'b100 && fsave_ok) || (op[8:6] == 3'b101 && frest_ok);
				if (op[8:6] == 3'b000) begin
					if (x1[15:13] == 3'b001) begin
						d.exc_fmt = 4'd0; d.exc_next = 1'b0;         // reserved opclass
					end else if (x1[15:13] == 3'b000 ||
					             (x1[15:13] == 3'b010 && x1[12:10] != 3'b111)) begin
						// the opmode field means something only for these two
						// (x1[15:13] = 010 with specifier 111 is FMOVECR, whose
						// low bits are a ROM offset)
						case (fp_opmode_class(x1[6:0]))
							2'd1: begin d.exc_fmt = 4'd0; d.exc_next = 1'b0; end
							// Opmodes $78-$7F are the ILLEGAL vector on a 68040
							// that HAS an FPU (lib/AP68040's go_illegal, and
							// WinUAE's fault_if_unimplemented_680x0, whose own
							// comment is "Unexpected, isn't it?!").  With NO FPU
							// they are just another F-line: the cputest corpus
							// says so and it is the hardware-validated oracle --
							// Basic/ILLEGAL slice 0007, opcode F23D 4AFC (opmode
							// $7C), expects vector 11 with the instruction's own
							// PC.  Getting this wrong cost that slice, and the
							// full-group replay is what found it.
							2'd2: begin
								d.exc_fmt = 4'd0; d.exc_next = 1'b0;
								if (HAS_FPU != 0) d.exc_vec = 8'd4;
							end
							default: ;
						endcase
					end
				end
				// Mode 7 registers 5, 6 and 7 are reserved for EVERY coprocessor
				// command, so a primary word carrying one is a malformed
				// encoding and takes the plain F-line -- format $0, own PC --
				// whatever its extension word says.  The reference rejects them
				// "before fetching an extension word" (ap040_core.v, the cpid-1
				// arms), and the cputest corpus agrees: Basic/ILLEGAL slice 0007
				// sweeps $F27D and $F27E and expects vector 11 with the
				// instruction's own PC.  (This overrides the opclass decision
				// above; FSAVE/FRESTORE keep their privilege check, which is
				// older still.)
				if ((op[5:3] == 3'b111 && op[2:0] > 3'b100 &&
				     (op[8:6] == 3'b000 || op[8:6] == 3'b001)) ||
				    (op[8:6] == 3'b100 && !fsave_ok) ||
				    (op[8:6] == 3'b101 && !frest_ok)) begin
					d.exc_vec = 8'd11; d.exc_fmt = 4'd0; d.exc_next = 1'b0;
				end
				// ---------------------------------------- plan M10.8
				// FBcc / FScc / FDBcc / FTRAPcc: the floating-point conditional
				// predicates.  The condition is evaluated in EA-fetch from the
				// unit's `fpcc`, which is why these decode to CL_FPU like
				// everything else that has to wait for a released operation --
				// reading `fpcc` while one is in flight is the DATA hazard
				// M10.1(c) named, and the serialise + fp_bg wait is what makes
				// it safe.  The displacement rides `imm`, which no FP class
				// with a branch also uses for a step.
				if (HAS_FPU != 0 && d.cls == CL_EXC && d.exc_fmt == 4'd4) begin
					if (op[8:6] == 3'b010) begin                  // FBcc.W
						d.cls = CL_FPU;
						d.imm = {{16{vbuf[1][15]}}, vbuf[1]};
					end else if (op[8:6] == 3'b011) begin         // FBcc.L
						d.cls = CL_FPU;
						d.imm = {vbuf[1], vbuf[2]};
					end else if (op[8:6] == 3'b001) begin
						if (op[5:3] == 3'b001) begin              // FDBcc Dn,disp
							d.cls = CL_FPU;
							d.t0sync = 1'b1;   // (M9.T) every FDBcc is T0-traced on the 040
							d.imm = {{16{vbuf[2][15]}}, vbuf[2]};
							d.src = ea_reg(EK_DREG, {2'b00, op[2:0]});
						end else if (op[5:0] == 6'b111_010 ||
						             op[5:0] == 6'b111_011 ||
						             op[5:0] == 6'b111_100) begin // FTRAPcc
							d.cls = CL_FPU;
						end else if (d.src.kind == EK_DREG ||
						             (d.src.kind == EK_MEM && d.src.mi == MI_NONE &&
						              !(sh.sm == 3'd7 && sh.sr[1]))) begin
							// FScc <ea>: a data-alterable byte destination
							d.cls  = CL_FPU;
							d.size = SZ_B;
							d.dst  = d.src;
						end else begin
							// an immediate or PC-relative FScc destination is
							// the ordinary F-line (lib/AP68040 S_FSCC0)
							d.exc_fmt = 4'd0; d.exc_next = 1'b0;
						end
					end
					if (d.cls == CL_FPU) d.serialize = 1'b1;
				end
				// ---------------------------------------- plan M10.5
				// FSAVE and FRESTORE with an FPU: the state frames.  Only the
				// one-longword NULL and IDLE frames are sequenced here (the
				// $4130 and $4160 payloads are M10.5's recorded gap), so the
				// (An)+ / -(An) step is four and the ordinary decoded byte
				// count still carries it.  The privilege check above is older
				// than this and stays; a malformed EA has already been turned
				// into the plain F-line by the block above it.
				if (HAS_FPU != 0 && d.cls == CL_EXC && d.exc_fmt == 4'd4 &&
				    ((op[8:6] == 3'b100 && fsave_ok) || (op[8:6] == 3'b101 && frest_ok)) &&
				    d.src.kind == EK_MEM && d.src.mi == MI_NONE) begin
					d.cls      = CL_FPU;
					d.size     = SZ_L;
					d.imm[6:0] = 7'd4;
					if (op[8:6] == 3'b100) d.dst = d.src;   // FSAVE writes
				end
				// ---------------------------------------- plan M10.1(a)
				// With an FPU a WELL-FORMED cpid-1 instruction of the subset
				// this core executes becomes CL_FPU instead of the exception.
				// `exc_fmt == 4` is exactly "well formed" here: D18's rows 2-4
				// have already pushed every malformed encoding down to format
				// $0 or vector 4, so this reads the one bit that already says
				// the encoding is a real floating-point instruction.
				//
				// M10.1 step 1 takes the REGISTER-operand forms only -- the
				// ones that need no bus access -- because the 96-bit memory
				// operand path is step (b).  Everything else keeps the format
				// $4 frame it has today, which is right for the LC040 build
				// that ships and incomplete for a build with an FPU; no
				// HAS_FPU = 1 image exists yet and (b) closes it.
				//   opclass 000  FPm -> FPn         (no EA at all)
				//   opclass 010  Dn  -> FPn  {B,W,L,S}
				//   opclass 011  FPn -> Dn   {B,W,L,S}
				// An extended, packed or double operand in a data register is
				// an illegal EA on a 68040 and stays the F-line.
				if (HAS_FPU != 0 && d.cls == CL_EXC && d.exc_fmt == 4'd4 &&
				    op[8:6] == 3'b000) begin
					// (A memory-INDIRECT effective address is excluded: its
					// pointer fetch would have to happen before the operand
					// beats, and EA-fetch's FP phase does not sequence that
					// yet.  Such an encoding keeps M10.0's format $4 frame,
					// which is a functional gap with an FPU -- recorded in
					// PLAN.md M10.1 -- on a form no compiler emits.)
					// a source/destination format that fits in a data register:
					// B, W, L and single.  Extended, packed and double in Dn
					// are illegal effective addresses on a 68040 and stay the
					// F-line.
					fp_ireg = (x1[12:10] == 3'b000) || (x1[12:10] == 3'b001) ||
					          (x1[12:10] == 3'b100) || (x1[12:10] == 3'b110);
					if (x1[15:13] == 3'b000) begin
						d.cls = CL_FPU; d.size = SZ_L;
					end else if (x1[15:13] == 3'b010 &&
					             ((d.src.kind == EK_DREG && fp_ireg) ||
					              (d.src.kind == EK_MEM && d.src.mi == MI_NONE) ||
					              d.src.kind == EK_IMM ||
					              x1[12:10] == 3'b111)) begin
						// (M10.7) specifier 111 is FMOVECR, which has no
						// effective address at all.  It goes to the unit rather
						// than being faked here, because the unit answers
						// `unimp` AND captures the state frame a following
						// FSAVE must extract -- which is exactly what
						// `t_fpu.s` test 44 checks.
						d.cls = CL_FPU;
					end else if (x1[15:13] == 3'b011 &&
					             ((d.src.kind == EK_DREG && fp_ireg) ||
					              (d.src.kind == EK_MEM && d.src.mi == MI_NONE))) begin
						// opclass 011's EA is the DESTINATION: the core waits
						// for `done` and writes the FPU's result into it
						d.cls = CL_FPU;
						d.dst  = d.src;
					end
					// (M10.2) opclass 100/101: FMOVE(M).L between the
					// effective address and FPCR/FPSR/FPIAR, one longword per
					// selected register in FPCR, FPSR, FPIAR order at ascending
					// addresses.  The legality rules are lib/AP68040's fp_crm
					// arm, which is the rule-2 source here (PLAN.md D20):
					//   Dn   a single register only;
					//   An   FPIAR only;
					//   #imm a SOURCE only (an immediate destination is
					//        malformed), and it may carry several registers;
					//   PC-relative: a source only, as for every store.
					// An empty list is FPIAR, not a no-op.
					else if (x1[15:14] == 2'b10) begin
						d.t0sync   = x1[13];   // (M9.T) control registers TO memory
						fp_crsel   = (x1[12:10] == 3'd0) ? 3'b001 : x1[12:10];
						fp_crn     = fp_cr_n(x1[12:10]);
						fp_crmulti = (fp_crn != 3'd1);
						fp_crbad   = (d.src.kind == EK_DREG && fp_crmulti) ||
						             (d.src.kind == EK_AREG && fp_crsel != 3'b001) ||
						             (d.src.kind == EK_IMM  && x1[13]) ||
						             (d.src.kind == EK_MEM  && x1[13] &&
						              sh.sm == 3'd7 && (sh.sr == 3'd2 || sh.sr == 3'd3));
						if (!fp_crbad && (d.src.kind == EK_DREG || d.src.kind == EK_AREG ||
						                  d.src.kind == EK_IMM ||
						                  (d.src.kind == EK_MEM && d.src.mi == MI_NONE))) begin
							d.cls  = CL_FPU;
							d.size = SZ_L;
							if (x1[13]) d.dst = d.src;   // FPcr -> <ea>
						end else if (fp_crbad) begin
							// an ILLEGAL effective address for this form is the
							// ordinary F-line -- format $0 with the instruction's
							// own PC, not M10.0's format $4 (lib/AP68040's fp_crm
							// arm calls go_fp_fline; PLAN.md D20).  Only with an
							// FPU: with HAS_FPU = 0 nothing has looked at the EA
							// and WinUAE's LC040 path gives every well-formed
							// cpid-1 opcode the format $4 frame (D18).
							d.exc_fmt = 4'd0; d.exc_next = 1'b0;
						end
						// ... and a LEGAL one this core does not sequence -- a
						// memory-indirect EA -- keeps the format $4 frame it has
						// today, which is M10.1's recorded gap and not this rule.
					end
					// (M10.6) An effective address the 68040 REJECTS for an
					// opclass 010 or 011 instruction is the ordinary F-line --
					// vector 11 with format $0 and the instruction's own PC --
					// and not M10.0's format $4 (PLAN.md D22).  `t_fpu.s` is
					// the oracle and it names the cputest rounds: an address
					// register is never a legal floating-point source or
					// destination, and a data register holds only the formats
					// that fit in it.  A LEGAL address this core does not
					// sequence (memory indirect) keeps format $4, which is the
					// separate, recorded gap.
					else if ((x1[15:13] == 3'b010 &&
					          (d.src.kind == EK_AREG ||
					           (d.src.kind == EK_DREG && !fp_ireg))) ||
					         (x1[15:13] == 3'b011 &&
					          (d.src.kind == EK_AREG ||
					           d.src.kind == EK_IMM ||
					           (sh.sm == 3'd7 && sh.sr[1]) ||
					           (d.src.kind == EK_DREG && !fp_ireg &&
					            x1[12:10] != 3'b011)))) begin
						// (packed into a data register is the DATATYPE fault,
						// vector 55, not the F-line -- it keeps format $4 for
						// now and is recorded with the rest of M10.6)
						if (fp_op_hw(x1[6:0])) begin
							d.exc_fmt = 4'd0; d.exc_next = 1'b0;
						end else begin
							// an FPSP-emulated opmode reports as UNIMPLEMENTED
							// whatever its effective address is: vector 11,
							// format $2, the NEXT instruction's PC, and the
							// address field is the faulting PC because there is
							// no addressable operand (D19's shape)
							d.exc_fmt = 4'd2; d.exc_next = 1'b1;
						end
					end
					// (M10.4) opclass 110/111: FMOVEM of the floating-point
					// registers, twelve bytes each.  The 68040's effective-
					// address rules, from lib/AP68040's fp_mvm arm, which cites
					// WinUAE fmovem2mem for them (PLAN.md D21): Dn, An and an
					// immediate are F-line in both directions; a STORE rejects
					// (An)+ and the PC-relative modes; a LOAD rejects -(An).
					// The register order and the within-register long order are
					// EA-fetch's problem, not the decoder's.
					else if (x1[15:14] == 2'b11) begin
						d.t0sync = x1[13];     // (M9.T) an FMOVEM STORE
						fp_mvst  = x1[13];
						fp_mvn   = {3'd0, x1[7]} + {3'd0, x1[6]} + {3'd0, x1[5]} +
						           {3'd0, x1[4]} + {3'd0, x1[3]} + {3'd0, x1[2]} +
						           {3'd0, x1[1]} + {3'd0, x1[0]};
						fp_mvbad = (sh.sm < 3'd2) || (sh.sm == 3'd7 && sh.sr == 3'd4) ||
						           (fp_mvst && (sh.sm == 3'd3 ||
						                        (sh.sm == 3'd7 && sh.sr[1]))) ||
						           (!fp_mvst && sh.sm == 3'd4);
						if (fp_mvbad) begin
							d.exc_fmt = 4'd0; d.exc_next = 1'b0;
						end
						// (M10.9) A DYNAMIC list takes its mask from a data
						// register named by x1[6:4], so the count -- and with it
						// the (An)+ / -(An) step -- is not known until the
						// instruction runs.  `reg_c` carries the register to
						// EA-fetch, which reads it on op_c, and the step goes
						// through the an_ov hook M10.7 built for exactly this.
						else if (d.src.kind == EK_MEM && d.src.mi == MI_NONE) begin
							d.cls  = CL_FPU;
							d.size = SZ_L;
							if (x1[11]) d.reg_c = {2'b00, x1[6:4]};
							if (fp_mvst) d.dst = d.src;
						end
					end
					if (d.cls == CL_FPU && x1[15:14] == 2'b11) begin
						// twelve bytes per selected register -- up to 96, which
						// is why the explicit step is seven bits wide
						// A static list's step is known here.  A DYNAMIC one's is
						// not, and it is given ONE register's worth rather than
						// zero: `nb == 0` means "use the size rule" in eacomp,
						// not "do not step", so zero would silently step by four.
						// EA-fetch adds the remaining 12 x (n-1) through an_ov.
						d.imm[6:0] = x1[11] ? 7'd12
						                    : {fp_mvn, 3'd0} + {1'b0, fp_mvn, 2'd0};   // 8n + 4n
						d.size = SZ_L;
					end else if (d.cls == CL_FPU && x1[15:14] == 2'b10) begin
						// the (An)+ / -(An) step and the beat count: one
						// longword per selected control register
						d.imm[4:0] = {fp_crn, 2'b00};
						d.size = SZ_L;
					end else if (d.cls == CL_FPU && x1[15:13] != 3'b000) begin
						// the operand's length, which is also the (An)+/-(An)
						// step (lib/AP68040 S_FPU_AN: fp_nb, with the A7 byte
						// rule), and the micro-op size for the 1/2/4-byte forms
						d.imm[4:0] = fp_bytes(x1[12:10]);
						d.size = (x1[12:10] == 3'b100) ? SZ_W : (x1[12:10] == 3'b110) ? SZ_B : SZ_L;
					end else if (d.cls == CL_FPU) begin
						d.imm[4:0] = 5'd0;
					end
				end
				// The source EA is kept ONLY for a format $4 frame, which
				// stacks it (EA-calc computes the address, EA-fetch takes it
				// from there and no operand is ever read; D18: the field is 0
				// whenever there is no memory operand -- a register, FMOVECR,
				// FBcc, FTRAPcc, and an immediate source, NOT the address of
				// the immediate data), or for a CL_FPU instruction whose
				// source operand it is.
				// (M10.1(b)) an immediate source is already in the decoder's
				// word buffer: the 68040 takes it from its prefetch, never
				// with a data read (lib/AP68040 S_FPU_IMM).  ks is the index
				// of the first EA word, and the operand is LEFT aligned in the
				// unit's 96-bit window -- the byte form's operand is the LOW
				// half of its one word.
				if (d.cls == CL_FPU && d.src.kind == EK_IMM && x1[15:14] == 2'b10) begin
					// (M10.2) an immediate control-register list: one longword
					// per register, in the same FPCR/FPSR/FPIAR order, taken
					// from the instruction stream (lib/AP68040 S_FPU_CRI)
					d.fpimm = {vbuf[ks], vbuf[ks+1], vbuf[ks+2],
					           vbuf[ks+3], vbuf[ks+4], vbuf[ks+5]};
				end else if (d.cls == CL_FPU && d.src.kind == EK_IMM) begin
					fpw0 = vbuf[ks];
					case (x1[12:10])
						3'b110:  d.fpimm = {fpw0[7:0], 88'd0};
						3'b100:  d.fpimm = {vbuf[ks], 80'd0};
						3'b101:  d.fpimm = {vbuf[ks], vbuf[ks+1], vbuf[ks+2], vbuf[ks+3], 32'd0};
						3'b010,
						3'b011:  d.fpimm = {vbuf[ks], vbuf[ks+1], vbuf[ks+2],
						                    vbuf[ks+3], vbuf[ks+4], vbuf[ks+5]};
						default: d.fpimm = {vbuf[ks], vbuf[ks+1], 64'd0};
					endcase
				end
				if (d.cls == CL_FPU) begin
					// An FP instruction SERIALISES: it waits in EA-fetch until
					// everything older has committed before the request goes
					// out.  The reason is not throughput but safety -- once the
					// unit has the command it has changed architectural state,
					// and a redirect by an older instruction (a taken branch
					// resolved in EX, a MOVE-to-SR, an exception) would flush
					// this stage and leave that state behind.  With nothing
					// older in EX or WB there is no such redirect.  It costs
					// the drain, not the background release: after `accepted`
					// the instruction leaves and integer work runs on.  M11
					// can trade it for a flush-aware abort if it is worth it.
					d.serialize = 1'b1;
					if (!((op[8:6] == 3'b000 && d.ext[15:13] == 3'b010) ||
					      (op[8:6] == 3'b000 && d.ext[15] && !d.ext[13]) ||
					      (op[8:6] == 3'b101) ||
					      (op[8:6] == 3'b001))) begin
						// the EA is the SOURCE for opclass 010, for a move INTO
						// the unit -- the control registers (100) and the FP
						// register list (110) -- and for FRESTORE, which reads
						// the frame; everywhere else it is the destination, or
						// there is none, and src is cleared.  (FSAVE/FRESTORE
						// carry no FP extension word, so `ext` must not be read
						// for them: hence the op[8:6] qualification.)
						d.src = '0; d.src.reg_n = R_NONE; d.src.idx_reg = R_NONE;
					end
				end else if (d.exc_fmt != 4'd4 || d.src.kind != EK_MEM) begin
					d.src = '0; d.src.reg_n = R_NONE; d.src.idx_reg = R_NONE;
				end
			end
			F_CINV: begin
				d.cls = CL_CINV; d.priv = 1'b1; d.serialize = 1'b1;
				d.imm = {30'd0, op[7], op[6]};
			end
			F_PMMU: begin                       // imm: [3] PTEST, [2] PTESTW, [1:0] PFLUSH mode
				d.cls = CL_PMMU; d.priv = 1'b1; d.serialize = 1'b1;
				d.imm = {28'd0, op[6], !op[5], op[4:3]};
				d.src = ea_reg(EK_AREG, {2'b01, op[2:0]});
			end
			F_MOVES: begin                      // a MOVE in the SFC/DFC space, no flags (PRM 6-24)
				d.cls = CL_ALU; d.alu = `AP040_ALU_MOVE; d.priv = 1'b1; d.serialize = 1'b1;
				if (x1[11]) begin                 // Rn -> <ea> [DFC]
					d.src = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
					d.fcsel = 2'd2;
				end else begin                    // <ea> [SFC] -> Rn (An: sign-extended)
					d.src = d.dst;
					d.dst = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
					d.fcsel = 2'd1;
				end
			end
			F_MOVEUSP: begin                    // as MOVEC USP (PRM MOVE USP 6-21: privileged)
				d.cls = CL_MOVEC; d.priv = 1'b1; d.serialize = 1'b1;
				d.imm[3:0] = CR_USP; d.imm[4] = !op[3];
				d.src = ea_reg(EK_AREG, {2'b01, op[2:0]});
			end
			// STOP #<data>: privileged, the SR is loaded and the processor stops
			// until an interrupt (or reset); RESET: privileged, RSTO for 512
			// clocks (M68040UM 7.x, PRM 4-? STOP/RESET).  Both serialise.
			F_STOP:  begin d.cls = CL_STOP;  d.priv = 1'b1; d.serialize = 1'b1; d.imm = {16'd0, x1}; end
			F_RESET: begin d.cls = CL_RSTO;  d.priv = 1'b1; d.serialize = 1'b1; end
			F_NOP: d.cls = CL_NOP;   // (waits for posted stores in EA-fetch: sync_busy)
			F_RTE: begin d.cls = CL_RTE; d.priv = 1'b1; d.serialize = 1'b1; end
			default: ;
		endcase
	end
	// Branches to an odd address take the address error here, before any
	// part of them executes: Bcc whether or not the condition holds, BSR
	// before its push, DBcc before the condition and the decrement
	// (M68040UM 8.2.2, p. 8-8: "This includes the case of a conditional
	// branch instruction with an odd branch offset that is not taken";
	// reference ap040_core.v finish_bcc / S_BCC_EXT / S_DBCC1).  Format $2,
	// stacked PC = the branch, address = the target with A0 cleared.
	if ((d.cls == CL_BCC || d.cls == CL_BSR || d.cls == CL_DBCC) && d.btarget[0]) begin
		d.cls = CL_EXC; d.exc_vec = 8'd3; d.exc_fmt = 4'd2; d.exc_next = 1'b0;
		d.exc_addr = {d.btarget[31:1], 1'b0};
		d.dst = '0; d.dst.idx_reg = R_NONE; d.dst.reg_n = R_NONE;
	end
	// an illegal instruction is one word long for PC purposes
	if (d.cls == CL_EXC && !d.exc_next && d.exc_fmt == 4'd0) d.next_pc = vpc + 32'd2;
	if (d.cls == CL_EXC) d.serialize = 1'b1;
	d.size2 = s2set ? s2 : d.size;
	// (M9.T) the T0 synchronisation list.  An instruction that is not
	// executed as itself -- an illegal/F-line/privilege entry -- is not a
	// synchronisation point: it is an exception, and exception entry clears
	// the trace anyway.
	if (d.cls != CL_EXC) d.t0sync = d.t0sync || t0_special(d.opcode);
	return d;
endfunction

wire id_t d0 = decf(vbuf, vpc, sh, tot, ln.ea_bad);

// A word the instruction needs came from a fetch that faulted (M6): the
// instruction becomes an access error (vector 2, format $7, PC = its first
// word) -- raised only now that it is reached, never for a prefetch past a
// branch (M68040UM 8.2.1).  The words needed: the opcode, then as many as
// the length decode asks for among those present.
function automatic logic [10:0] upto(input logic [4:0] n);
	return (n >= 5'd11) ? 11'h7FF : ((11'd1 << n) - 11'd1);
endfunction
wire [4:0] have_n = ln.more ? {1'b0, vcnt} : (({1'b0, vcnt} < tot) ? {1'b0, vcnt} : tot);
wire       fbad   = (vcnt != 4'd0) && ((verr & upto(have_n)) != 11'd0);
function automatic id_t ifault(input id_t x, input logic [31:0] pc, input logic [31:0] fa,
                               input logic lng, input logic atc);
	id_t f;
	f = x;
	f.cls = CL_EXC; f.exc_vec = 8'd2; f.exc_fmt = 4'd7; f.exc_next = 1'b0; f.exc_addr = fa;
	f.size = lng ? SZ_L : SZ_W; f.imm = {31'd0, atc};
	f.priv = 1'b0; f.serialize = 1'b0;
	f.src.kind = EK_NONE; f.dst.kind = EK_NONE;
	return f;
endfunction
wire id_t d = fbad ? ifault(d0, vpc, pf_addr, pf_long, pf_atc) : d0;

// the code gathered here (self-modifying-code check in the core)
assign g_lo = g_pc;
assign g_hi = g_pc + {27'd0, wcnt, 1'b0};
assign g_v  = (wcnt != 4'd0);

//--------------------------------------------------------------- emit

wire done_i = complete || fbad;
wire emit = done_i && !flush && !stall_in;

// words taken: on emit, only this instruction's (the next one's first word
// may be the second word offered); while gathering, all of them; nothing
// while EA-calc is stalled
wire [4:0] need = tot - {1'b0, wcnt};
assign consume = (flush || stall_in) ? 2'd0 :
                 fbad ? avail : complete ? need[1:0] : avail;
// (timing) `consume` without the flush term.  ID is flushed only by a
// redirect (the core's flush_id is a subset of redirect_valid), and IF
// ignores consume under a redirect wherever it uses this one -- its room
// check and qpc -- so EA-calc's redirect (and through it the acknowledge ->
// WB hold -> EA-fetch stall chain) need not reach IF's request through ID.
assign consume_nf = stall_in ? 2'd0 :
                    fbad ? avail : complete ? need[1:0] : avail;

// guess taken: Bcc/BRA/BSR redirect IF the clock they are emitted
assign id_redirect_valid = emit && (d.cls == CL_BCC || d.cls == CL_BSR || d.cls == CL_DBCC);
assign id_redirect_pc    = d.btarget;

always @(posedge clk) begin
	if (!nreset) begin
		id_valid <= 1'b0;
		id_o     <= '0;
		wbuf     <= '0;
		wcnt     <= 4'd0;
		werr     <= 11'd0;
		g_pc     <= 32'd0;
	end else if (ce) begin
		if (flush) begin
			id_valid <= 1'b0;
			wcnt     <= 4'd0;
			werr     <= 11'd0;
		end else if (!stall_in) begin
			if (done_i) begin
				id_valid <= 1'b1;
				id_o     <= d;
				wcnt     <= 4'd0;
				werr     <= 11'd0;
			end else begin
				id_valid <= 1'b0;
				if (avail != 2'd0) begin
					wbuf <= vbuf;
					werr <= verr;
					if (wcnt == 4'd0) g_pc <= q_pc0;
					wcnt <= vcnt;
				end
			end
		end
	end
end

endmodule
