//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_ea_calc.v - <ea> calculate stage (rewritten for Minimig plan M1)   //
//                                                                          //
// Computes both effective addresses of the instruction in one clock:      //
//   EA = base + bd + Xn*scale     (memory indirect: the pointer address,   //
//                                   and what EA-fetch adds to the pointer) //
// and the (An)+ / -(An) updates (step = operand size, A7 byte = 2).  The   //
// destination EA sees the source EA's update of the same register (MOVE   //
// (A0)+,(A0)+, CMPM, ADDX -(A0),-(A0)).                                    //
//                                                                          //
// Registers: four read ports (src base, src index, dst base, dst index).   //
// A7 is resolved to USP/ISP/MSP here from the architectural SR.  Values    //
// still in flight are forwarded from the instructions ahead:               //
//   an (An)+/-(An) update  -> its value is known (computed here) -> forward //
//   a result (w0)          -> not known until EX -> stall this stage until  //
//                             it is in WB, where the regfile write-through  //
//                             supplies it                                  //
// Youngest producer wins.  A serialising instruction in EA-fetch stalls    //
// this stage (it may write registers in ways the pending-write bookkeeping //
// does not describe: stack pointers, SR).                                  //
//                                                                          //
// The An update is NOT written here: it travels with the instruction and   //
// commits in WB (plan M1: never earlier), so a fault in EA-fetch leaves    //
// the register untouched.                                                  //
//                                                                          //
// Coding rule (Icarus): combinational logic is pure functions of their     //
// arguments, assigned with assign -- see ap040_decode.v.                   //
//--------------------------------------------------------------------------//

module ap040_ea_calc
	import ap040_pipe_pkg::*;
#(
	// 1: the FPU is present, so CL_FPU can occur (plan M10.1)
	parameter HAS_FPU = 0
)
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // EA-fetch cannot accept this cycle
	input             flush,

	input             id_valid,
	input  id_t       id_i,

	input      [15:0] sr_in,      // architectural SR (WB write-through)

	// register reads
	output      [4:0] ra_sb, ra_si, ra_db, ra_di,
	input      [31:0] rd_sb, rd_si, rd_db, rd_di,

	// pending writes of the instructions ahead
	input             p_eaf_v,    // EA-fetch stage
	input  eac_t      p_eaf,
	input             p_eaf_blk,  // EA-fetch holds a serialising/sequenced instruction
	input             p_ex_v,     // execute stage
	input             p_ex_w0_v,
	input       [4:0] p_ex_w0_r,
	input             p_ex_u0_v, input [4:0] p_ex_u0_r, input [31:0] p_ex_u0_val,
	input             p_ex_u1_v, input [4:0] p_ex_u1_r, input [31:0] p_ex_u1_val,

	input             p_ex_store, // EX holds a store that has not reached memory

	output            ea_stall,   // to ID

	// the early read (first memory read of the instruction moving to EA-fetch)
	output            early_v,
	output rdreq_t    early,

	// JMP/JSR redirect from this stage
	output            eac_redir_v,
	output     [31:0] eac_redir_pc,

	output reg        eac_valid,
	output eac_t      eac_o
);

wire s_bit = sr_in[13];
wire m_bit = sr_in[12];

// resolved register numbers
wire [4:0] r_sb = resolve_sp(id_i.src.reg_n, s_bit, m_bit);
wire [4:0] r_si = resolve_sp(id_i.src.idx_reg, s_bit, m_bit);
wire [4:0] r_db = resolve_sp(id_i.dst.reg_n, s_bit, m_bit);
wire [4:0] r_di = resolve_sp(id_i.dst.idx_reg, s_bit, m_bit);

assign ra_sb = r_sb; assign ra_si = r_si; assign ra_db = r_db; assign ra_di = r_di;

// which registers this instruction reads in this stage
wire use_sb = (id_i.src.kind == EK_MEM) && id_i.src.base_en;
wire use_si = (id_i.src.kind == EK_MEM) && id_i.src.idx_en;
wire use_db = (id_i.dst.kind == EK_MEM) && id_i.dst.base_en;
wire use_di = (id_i.dst.kind == EK_MEM) && id_i.dst.idx_en;

// forwarding: returns {stall, hit, value}
function automatic logic [33:0] fwd(input logic [4:0] r, input logic [31:0] rf,
                                    input logic ev, input eac_t e,
                                    input logic xv, input logic xw0v, input logic [4:0] xw0r,
                                    input logic xu0v, input logic [4:0] xu0r, input logic [31:0] xu0d,
                                    input logic xu1v, input logic [4:0] xu1r, input logic [31:0] xu1d);
	// EA-fetch stage (youngest)
	if (ev && e.w0_v && e.w0_r == r) return {1'b1, 1'b0, 32'd0};
	if (ev && e.w1_v && e.w1_r == r) return {1'b1, 1'b0, 32'd0};
	if (ev && e.u1_v && e.u1_r == r) return {1'b0, 1'b1, e.u1_val};
	if (ev && e.u0_v && e.u0_r == r) return {1'b0, 1'b1, e.u0_val};
	// execute stage
	if (xv && xw0v && xw0r == r) return {1'b1, 1'b0, 32'd0};
	if (xv && xu1v && xu1r == r) return {1'b0, 1'b1, xu1d};
	if (xv && xu0v && xu0r == r) return {1'b0, 1'b1, xu0d};
	// register file (WB write-through inside it)
	return {1'b0, 1'b0, rf};
endfunction

wire [33:0] f_sb = fwd(r_sb, rd_sb, p_eaf_v, p_eaf, p_ex_v, p_ex_w0_v, p_ex_w0_r,
                       p_ex_u0_v, p_ex_u0_r, p_ex_u0_val, p_ex_u1_v, p_ex_u1_r, p_ex_u1_val);
wire [33:0] f_si = fwd(r_si, rd_si, p_eaf_v, p_eaf, p_ex_v, p_ex_w0_v, p_ex_w0_r,
                       p_ex_u0_v, p_ex_u0_r, p_ex_u0_val, p_ex_u1_v, p_ex_u1_r, p_ex_u1_val);
wire [33:0] f_db = fwd(r_db, rd_db, p_eaf_v, p_eaf, p_ex_v, p_ex_w0_v, p_ex_w0_r,
                       p_ex_u0_v, p_ex_u0_r, p_ex_u0_val, p_ex_u1_v, p_ex_u1_r, p_ex_u1_val);
wire [33:0] f_di = fwd(r_di, rd_di, p_eaf_v, p_eaf, p_ex_v, p_ex_w0_v, p_ex_w0_r,
                       p_ex_u0_v, p_ex_u0_r, p_ex_u0_val, p_ex_u1_v, p_ex_u1_r, p_ex_u1_val);

wire hazard = id_valid && (p_eaf_blk ||
                           (use_sb && f_sb[33]) || (use_si && f_si[33]) ||
                           (use_db && f_db[33]) || (use_di && f_di[33]));

assign ea_stall = stall_in || hazard;

function automatic logic [31:0] step(input logic [1:0] sz, input logic [4:0] r);
	if (sz == SZ_B) return (r == R_USP || r == R_ISP || r == R_MSP) ? 32'd2 : 32'd1;
	return (sz == SZ_W) ? 32'd2 : 32'd4;
endfunction

function automatic logic [31:0] scaled(input logic [31:0] v, input logic l, input logic [1:0] sc);
	logic [31:0] x;
	x = l ? v : sext16(v[15:0]);
	return x << sc;
endfunction

// one EA: {ea, add (memory indirect), new An value, update?}
typedef struct packed { logic [31:0] ea; logic [31:0] add; logic [31:0] nv; logic upd; } eares_t;

// nb != 0 overrides the step with an explicit byte count: a floating-point
// operand is 1, 2, 4, 8 or 12 bytes and the (An)+/-(An) update is by the
// WHOLE operand, once (lib/AP68040 S_FPU_AN's fp_nb).  The A7 byte rule still
// applies to the one-byte form.  (M10.2) a control-register list steps by four
// per register, (M10.4) an FMOVEM list by twelve -- up to 96, which is why the
// count is seven bits and not five.
function automatic eares_t eacomp(input ea_t e, input logic [1:0] sz, input logic [4:0] rb,
                                  input logic [31:0] base_v, input logic [31:0] idx_v,
                                  input logic [31:0] nb);
	eares_t r;
	logic [31:0] base, idx, st;
	base  = e.base_en ? base_v : 32'd0;
	idx   = e.idx_en ? scaled(idx_v, e.idx_l, e.scale) : 32'd0;
	st    = (nb == 32'd0) ? step(sz, rb) :
	        ((nb == 32'd1) && (rb == R_USP || rb == R_ISP || rb == R_MSP)) ? 32'd2 : nb;
	r.upd = (e.kind == EK_MEM) && (e.upd != UPD_NONE);
	r.nv  = (e.upd == UPD_PRE) ? base - st : base + st;
	r.add = 32'd0;
	case (e.mi)
		MI_PRE:  begin r.ea = base + e.bd + idx; r.add = e.od; end
		MI_POST: begin r.ea = base + e.bd;       r.add = e.od + idx; end
		default: r.ea = (e.upd == UPD_PRE) ? r.nv : base + e.bd + idx;
	endcase
	return r;
endfunction

// (M10.1(b)) With HAS_FPU = 0 nothing decodes to CL_FPU, so this folds to a
// constant zero and the step is the size rule exactly as before -- the
// comparison must not survive into the LC040 build, because `nb` becomes a
// mux in the address computation.
wire [31:0] fp_step = ((HAS_FPU != 0) && (id_i.cls == CL_FPU)) ? {25'd0, id_i.imm[6:0]} : 32'd0;
wire eares_t sres = eacomp(id_i.src, id_i.size, r_sb, f_sb[31:0], f_si[31:0], fp_step);
// the destination sees the source's update of the same register
wire [31:0]  db_v = (sres.upd && r_sb == r_db) ? sres.nv : f_db[31:0];
wire [31:0]  di_v = (sres.upd && r_sb == r_di) ? sres.nv : f_di[31:0];
wire eares_t dres = eacomp(id_i.dst, id_i.size2, r_db, db_v, di_v, fp_step);   // size2: PACK/UNPK

// the result register this instruction will write (w0), for the stages behind
function automatic logic w0_of(input id_t i);
	case (i.cls)
		CL_ALU:  return (i.dst.kind == EK_DREG || i.dst.kind == EK_AREG) && !i.nowrite;
		CL_DBCC: return 1'b1;
		CL_SCC, CL_MOVEFSR, CL_PACK, CL_UNPK: return i.dst.kind == EK_DREG;
		CL_SHIFT, CL_BIT: return i.dst.kind == EK_DREG && !i.nowrite;
		CL_MULDIV, CL_CAS, CL_CAS2: return 1'b1;
		// BFEXTU/BFEXTS/BFFFO write Dn (w0_r moved below); CHG/CLR/SET/INS a field register
		CL_BF: return (i.alu[2:0] == 3'd1 || i.alu[2:0] == 3'd3 || i.alu[2:0] == 3'd5) ||
		              (i.dst.kind == EK_DREG && i.alu[2:0] != 3'd0);
		CL_LEA, CL_UNLK, CL_EXG: return 1'b1;
		CL_MOVEC: return !i.imm[4] || i.imm[3:0] == CR_USP || i.imm[3:0] == CR_ISP || i.imm[3:0] == CR_MSP;
		default: return 1'b0;
	endcase
endfunction

function automatic eac_t mk(input id_t i, input eares_t s, input eares_t d,
                            input logic [4:0] rsb, input logic [4:0] rdb, input logic sb, input logic mb);
	eac_t o;
	o = '0;
	o.i      = i;
	o.src_ea = s.ea;  o.src_add = s.add;
	o.dst_ea = d.ea;  o.dst_add = d.add;
	o.src_r  = rsb;
	o.dst_r  = rdb;
	o.u0_v   = s.upd;  o.u0_r = rsb; o.u0_val = s.nv;
	o.u1_v   = d.upd;  o.u1_r = rdb; o.u1_val = d.nv;
	// the source's own update of a register the destination also updates
	// is superseded (the destination was computed from it)
	if (s.upd && d.upd && rsb == rdb) o.u0_v = 1'b0;
	o.w0_v   = w0_of(i);
	o.redirected = (i.cls == CL_JMP || i.cls == CL_JSR) && i.src.mi == MI_NONE && !s.ea[0];
	o.w0_r   = rdb;
	case (i.cls)
		CL_BF: if (i.alu[2:0] == 3'd1 || i.alu[2:0] == 3'd3 || i.alu[2:0] == 3'd5) o.w0_r = rsb;
		// CAS2: Dc1 (w0) and Dc2 (w1) are written when a compare fails
		CL_CAS2: begin
			o.w0_r = {2'b00, i.ext[2:0]};
			o.w1_v = 1'b1; o.w1_r = {2'b00, i.ext2[2:0]};
		end
		// LINK An,#d: An <- SP-4 (u0), SP <- SP-4+d (u1, wins if An is A7)
		CL_LINK: begin
			o.u0_v = 1'b1; o.u0_r = rsb; o.u0_val = d.nv;
			o.u1_val = d.nv + i.imm;
		end
		// UNLK An: SP <- An+4 (u1); An <- (An) (w0, wins if An is A7)
		CL_UNLK: begin
			o.u1_v = 1'b1; o.u1_r = resolve_sp(R_A7L, sb, mb); o.u1_val = s.ea + 32'd4;
		end
		// RTD #d: SP <- SP+4+d
		CL_RTD: o.u0_val = s.nv + i.imm;
		// RTR: SP <- SP+6 (CCR word and PC long read from (SP) and 2(SP))
		CL_RTR: begin
			o.u1_v = 1'b1; o.u1_r = resolve_sp(R_A7L, sb, mb); o.u1_val = s.ea + 32'd6;
		end
		// CAS: Dc (the source register) may be written with the memory value
		CL_CAS: o.w0_r = rsb;
		// MUL.L 64 / DIV.L with Dr != Dq: a second result register
		CL_MULDIV: if (i.imm[2] && i.reg_c != rdb && (i.imm[0] || i.imm[3])) begin
			o.w1_v = 1'b1; o.w1_r = i.reg_c;
		end
		// EXG Rx,Ry: Rx <- Ry (w0), Ry <- Rx (w1; EA-fetch knows its value)
		CL_EXG: begin
			o.w0_r = rsb;
			o.w1_v = 1'b1; o.w1_r = rdb;
		end
		default: ;
	endcase
	if (i.cls == CL_MOVEC)
		o.w0_r = !i.imm[4] ? resolve_sp(i.src.reg_n, sb, mb) :
		         (i.imm[3:0] == CR_USP) ? R_USP : (i.imm[3:0] == CR_ISP) ? R_ISP : R_MSP;
	return o;
endfunction

wire eac_t o = mk(id_i, sres, dres, r_sb, r_db, s_bit, m_bit);

// Early read: issued in the clock the instruction moves into EA-fetch, so
// its answer arrives with it (an operand load then costs EA-fetch one clock,
// M68040UM 10.1 p. 10-3: "one clock in the <ea> fetch stage for each memory
// access").  Not while an older store has yet to reach memory: the one in
// EA-fetch (it stores two clocks later) or the one in EX.
assign early   = first_rd(id_i, sres.ea, dres.ea);
// JMP/JSR: the target is this stage's source EA, so IF is redirected from
// here (a memory-indirect target waits for EA-fetch; an odd one takes the
// address error there, no redirect).  M68040UM 10.6 p. 10-20: JMP (An)
// <ea> calculate 3, execute 2L+1.
assign eac_redir_v  = id_valid && !hazard && !stall_in && !flush && o.redirected;
assign eac_redir_pc = sres.ea;

// (older stores are merged into the answer in EA-fetch, so no store hazard here)
assign early_v = id_valid && !hazard && !stall_in && !flush;

always @(posedge clk) begin
	if (!nreset) begin
		eac_valid <= 1'b0;
		eac_o     <= '0;
	end else if (ce) begin
		if (flush) begin
			eac_valid <= 1'b0;
		end else if (!stall_in) begin
			eac_valid <= id_valid && !hazard;
			if (id_valid && !hazard) eac_o <= o;
		end
	end
end

endmodule
