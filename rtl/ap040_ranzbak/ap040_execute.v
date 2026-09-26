//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_execute.v - EX stage (rewritten for Minimig plan M1)               //
//                                                                          //
// One micro-op per clock.  Computes the ALU result and flags, merges a     //
// byte/word result into its Dn, sign-extends a MOVEA.W, resolves branches  //
// (ID guessed taken: a not-taken Bcc/DBcc redirects to next_pc), and      //
// redirects for JMP/JSR/RTS/RTE/MOVE-to-SR/exception entry.  The redirect  //
// flushes IF/ID/EA-calc/EA-fetch.  Results go to the WB register (wb_t);  //
// WB commits them at the end of its clock.                                 //
//                                                                          //
// Forwarding: the result register value (w0) and the An updates of the    //
// micro-op in this stage are offered to EA-fetch combinationally.          //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_execute
	import ap040_pipe_pkg::*;
#(
	// 1: the FPU is present, so CL_FPU can occur (plan M10.1).  With 0 it
	// cannot, and the arm below folds away -- which matters, because this
	// stage's result mux sits on the EA-fetch -> IF redirect path that M11.1
	// exists to keep short.
	parameter HAS_FPU = 0
)
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // WB cannot accept
	input             wb_drop,    // WB's store faulted (M6): its micro-op is gone
	input             in_drop,    // WB's self-modifying-code refetch: this micro-op does not go to WB

	input             eaf_valid,
	input  ex_t       x,

	input       [4:0] ccr_in,     // CCR with the WB write-through
	input      [15:0] sr_in,      // SR with the WB write-through
	input      [31:0] sfc_in, dfc_in, cacr_in, vbr_in,
	input      [31:0] tc_in, itt0_in, itt1_in, dtt0_in, dtt1_in, mmusr_in, urp_in, srp_in,

	output            ex_stall,

	// forwarding
	output            fw_w0_v,
	output      [4:0] fw_w0_r,
	output     [31:0] fw_w0_val,

	output            fw_ccr_v,
	output      [4:0] fw_ccr,
	output            fw_st_v,
	output     [31:0] fw_st_addr,
	output      [1:0] fw_st_size,
	output     [31:0] fw_st_data,

	output            ex_redirect,
	output     [31:0] ex_redirect_pc,
	output            ex_redirect_s,   // the S bit after this micro-op (IF's fetch FC)

	output reg        exe_valid,
	output wb_t       exe_o
);

//--------------------------------------------------------------- MUL/DIV
// The reference's multiply/divide unit, run for the micro-op in EX; EX
// holds (ex_stall) until it is done.  Operand setup and flag/overflow rules
// follow the reference (ap040_core.v EK_MD_W / S_MDL_RDQ / S_MD_WAIT, all
// validated on the cputest corpus).  imm4 = {64-bit, long, signed, divide}.
wire        md_div  = x.imm4[0];
wire        md_sgn  = x.imm4[1];
wire        md_long = x.imm4[2];
wire        md_64   = x.imm4[3];
wire        md_uop  = eaf_valid && (x.cls == CL_MULDIV) && !x.cc;   // (cc: divide by zero)
reg         md_busy;
wire        md_done;
wire [31:0] md_rhi, md_rlo;
wire        md_ovf;
wire        md_start = md_uop && !md_busy;
wire [31:0] md_a  = md_long ? x.a : (md_sgn ? sext16(x.a[15:0]) : {16'd0, x.a[15:0]});
wire [31:0] md_hi = !md_div ? 32'd0 :
                    (md_long && md_64) ? x.c :
                    (md_sgn ? {32{x.b[31]}} : 32'd0);
wire [31:0] md_lo = (md_div || md_long) ? x.b : (md_sgn ? sext16(x.b[15:0]) : {16'd0, x.b[15:0]});

ap040_pipe_muldiv u_md
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.start(md_start), .is_div(md_div), .sign_op(md_sgn),
	.op_a(md_a), .op_hi(md_hi), .op_lo(md_lo),
	.done(md_done), .res_hi(md_rhi), .res_lo(md_rlo), .ovf(md_ovf)
);

always @(posedge clk) begin
	if (!nreset) md_busy <= 1'b0;
	else if (ce) begin
		if (md_start) md_busy <= 1'b1;
		else if (md_done) md_busy <= 1'b0;
	end
end

// EX holds while a MUL/DIV runs: from its start until the clock its result is there
wire md_wait = md_uop && !(md_busy && md_done);
assign ex_stall = stall_in || md_wait;

wire [31:0] alu_result;
wire  [4:0] alu_flags;

// An destination (MOVEA ADDA SUBA CMPA ADDQ/SUBQ to An): the operation is a
// 32-bit one on the sign-extended word source (PRM ADDA 4-7 / CMPA 4-77).
// Bit ops: the bit number is mod 32 for Dn, mod 8 for a memory byte.
wire        an_dst = (x.dk == DK_REG) && (x.dr[4:3] != 2'b00);
// (a byte into An: MOVES.B <ea>,An sign-extends, PRM 6-24)
wire [31:0] alu_a  = (an_dst && x.size == SZ_W) ? sext16(x.a[15:0]) :
                     (an_dst && x.size == SZ_B) ? sext8(x.a[7:0]) :
                     (x.cls == CL_BIT) ? ((x.size == SZ_B) ? {29'd0, x.a[2:0]} : {27'd0, x.a[4:0]}) :
                     x.a;
wire  [1:0] alu_sz = an_dst ? SZ_L : x.size;
// shift count: #1-8, Dn mod 64, or 1 (memory); 0 is handled below
wire  [5:0] sh_cnt = x.a[5:0];
// (never name a package constant inside a port connection: Icarus makes an
// implicit net of an identifier it meets there before the wildcard import
// resolves it -- CL_SHIFT came out as 'z' and no shift ever happened)
wire  [5:0] alu_cnt = (x.cls == CL_SHIFT) ? sh_cnt : 6'd1;

ap040_pipe_alu alu
(
	.op        (x.alu),
	.size      (alu_sz),
	.shcnt     (alu_cnt),
	.a         (alu_a),
	.b         (x.b),
	.flags_in  (ccr_in),
	.result    (alu_result),
	.flags_out (alu_flags)
);

// shift/rotate by zero: value unchanged, X kept, N Z from it, V=0, C=0
// (C=X for ROXL/ROXR) -- reference S_SHIFT with sh_cnt == 0
wire        sh_rox  = (x.alu == `AP040_ALU_ROXL1) || (x.alu == `AP040_ALU_ROXR1);
wire [31:0] sh_bm   = x.b & szmask(x.size);
wire        sh_n0   = (x.size == SZ_B) ? x.b[7] : (x.size == SZ_W) ? x.b[15] : x.b[31];
wire  [4:0] sh_f0   = {ccr_in[4], sh_n0, (sh_bm == 32'd0), 1'b0, sh_rox ? ccr_in[4] : 1'b0};

// CHK: N = the value's sign; C only on a trap, for these sign cases; Z V X
// kept (reference EK_CHK, "cputest 68040_default reference on hardware")
function automatic logic signed [31:0] sgn(input logic [31:0] v, input logic [1:0] sz);
	return (sz == SZ_B) ? $signed(sext8(v[7:0])) : (sz == SZ_W) ? $signed(sext16(v[15:0])) : $signed(v);
endfunction
wire signed [31:0] chk_v = sgn(x.b, x.size);
wire signed [31:0] chk_b = sgn(x.a, x.size);
wire        chk_trap = (chk_v < 0) || (chk_v > chk_b);
wire        chk_c    = chk_trap && ((chk_v < 0 && chk_b >= 0) || (chk_b >= 0 && chk_v >= chk_b) ||
                                    (chk_v < 0 && chk_b < chk_v));
// CHK2/CMP2: Z = equal to a bound, C = out of bounds (reference S_CHK2_D)
wire signed [31:0] c2_rn = (x.dr[4:3] != 2'b00) ? $signed(x.b) : sgn(x.b, x.size);
wire signed [31:0] c2_lb = sgn(x.a, x.size);
wire signed [31:0] c2_ub = sgn(x.c, x.size);
wire        c2_oob = (c2_lb <= c2_ub) ? (c2_rn < c2_lb || c2_rn > c2_ub) : (c2_rn < c2_lb && c2_rn > c2_ub);

// PACK / UNPK (PRM 4-157 / 4-190)
wire [15:0] pk_t   = x.a[15:0] + x.c[15:0];
wire [31:0] pk_res = {24'd0, pk_t[11:8], pk_t[3:0]};
wire [31:0] up_res = {16'd0, 4'd0, x.a[7:4], 4'd0, x.a[3:0]} + {16'd0, x.c[15:0]};

wire cond = cond_true(x.cond, ccr_in);

// MOVE from SR / CCR: the SR as the instructions ahead left it
wire [31:0] sr_word = x.ccr_only ? {27'd0, ccr_in} : {16'd0, sr_in[15:5], ccr_in};

// DBcc
wire [15:0] dbcc_dec   = x.b[15:0] - 16'd1;
wire        dbcc_taken = !cond && (dbcc_dec != 16'hFFFF);

function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] v, input logic [1:0] sz);
	case (sz)
		SZ_B:    return {old[31:8], v[7:0]};
		SZ_W:    return {old[31:16], v[15:0]};
		default: return v;
	endcase
endfunction

logic [31:0] creg_rd;
always @* begin
	case (x.creg_sel)
		CR_SFC:  creg_rd = sfc_in;
		CR_DFC:  creg_rd = dfc_in;
		CR_CACR: creg_rd = cacr_in;
		CR_VBR:  creg_rd = vbr_in;
		CR_TC:   creg_rd = tc_in;
		CR_ITT0: creg_rd = itt0_in;
		CR_ITT1: creg_rd = itt1_in;
		CR_DTT0: creg_rd = dtt0_in;
		CR_DTT1: creg_rd = dtt1_in;
		CR_MMUSR: creg_rd = mmusr_in;
		CR_URP:  creg_rd = urp_in;
		CR_SRP:  creg_rd = srp_in;
		default: creg_rd = x.a;          // USP/ISP/MSP: EA-fetch read the register
	endcase
end

wb_t w;
logic redir;
logic [31:0] redir_pc;
always @* begin
	w = '0;
	w.pc = x.pc; w.last = x.last;
	w.w0_r = R_NONE; w.u0_r = R_NONE; w.u1_r = R_NONE;
	w.u0_v = x.u0_v; w.u0_r = x.u0_r; w.u0_val = x.u0_val;
	w.u1_v = x.u1_v; w.u1_r = x.u1_r; w.u1_val = x.u1_val;
	w.st_v = x.st_v; w.st_addr = x.st_addr; w.st_data = x.st_data; w.st_size = x.st_size;
	w.st_rb = x.st_rb; w.st_fc = x.st_fc; w.stf = x.stf;
	w.sr_v = x.sr_v; w.sr_val = x.sr_val;
	w.exc  = x.exc;  w.exc_sp = x.sp_val; w.irq = x.irq;
	// a sequenced stack-pointer write goes out on the u0 port
	if (x.sp_v) begin w.u0_v = 1'b1; w.u0_r = x.sp_r; w.u0_val = x.sp_val; end
	redir = x.redirect; redir_pc = x.target;
	case (x.cls)
		CL_ALU: begin
			w.ccr_v = x.wr_ccr; w.ccr_val = alu_flags;
			if (x.nowrite) ;                  // CMP CMPA CMPM CMPI TST
			else if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr;
				w.w0_val = an_dst ? alu_result : merge(x.b, alu_result, x.size);
			end else if (x.dk == DK_MEM) begin
				w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = alu_result; w.st_size = x.size;
			end
		end
		CL_CCROP: begin                   // ANDI/ORI/EORI #,CCR
			w.ccr_v = 1'b1;
			w.ccr_val = (x.alu == `AP040_ALU_AND) ? (ccr_in & x.a[4:0]) :
			            (x.alu == `AP040_ALU_OR)  ? (ccr_in | x.a[4:0]) : (ccr_in ^ x.a[4:0]);
		end
		CL_SROP: begin                    // ANDI/ORI/EORI #,SR (EA-fetch set the redirect)
			w.sr_v = 1'b1;
			w.sr_val = ((x.alu == `AP040_ALU_AND) ? (sr_in & x.a[15:0]) :
			            (x.alu == `AP040_ALU_OR)  ? (sr_in | x.a[15:0]) : (sr_in ^ x.a[15:0])) & `AP040_SR_MASK;
		end
		CL_PEA, CL_LINK: begin            // push the EA / An
			w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = x.a; w.st_size = SZ_L;
		end
		CL_LEA, CL_UNLK: begin
			w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = x.a;
		end
		CL_RTR, CL_MOVE2CCR: begin
			w.ccr_v = 1'b1; w.ccr_val = x.a[4:0];
		end
		CL_MOVEFSR: begin                 // MOVE SR/CCR,<ea>: a word, the CCR untouched
			if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = merge(x.b, sr_word, SZ_W);
			end else if (x.dk == DK_MEM) begin
				w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = sr_word; w.st_size = SZ_W;
			end
		end
		CL_EXG: begin                     // Rx <- Ry here; Ry <- Rx came as u0
			w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = x.b;
		end
		//-------------------------------------------------------- M3
		CL_SHIFT, CL_BIT: begin
			w.ccr_v = 1'b1;
			w.ccr_val = (x.cls == CL_SHIFT && sh_cnt == 6'd0) ? sh_f0 : alu_flags;
			if (x.nowrite) ;              // BTST
			else if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr;
				w.w0_val = merge(x.b, (x.cls == CL_SHIFT && sh_cnt == 6'd0) ? x.b : alu_result, x.size);
			end else if (x.dk == DK_MEM) begin
				w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = alu_result; w.st_size = x.size;
			end
		end
		CL_MOVEM: begin                   // EA-fetch built it: a load's register, or a store (x.st_*)
			if (x.dk == DK_REG) begin w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = x.c; end
		end
		// (M10.1) a floating-point instruction: EA-fetch ran the unit and put
		// its result, already right-aligned by size, in x.c.  Nothing here
		// touches the CCR -- the FP condition codes live in the FPSR.
		CL_FPU: if (HAS_FPU != 0) begin
			if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = merge(x.b, x.c, x.size);
			end else if (x.dk == DK_MEM) begin
				w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = x.c; w.st_size = x.size;
			end
		end
		CL_CAS2: begin                    // EA-fetch decided it; flags from x.b - x.a
			if (x.wr_ccr) begin w.ccr_v = 1'b1; w.ccr_val = alu_flags; end
			if (x.dk == DK_REG) begin w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = x.c; end
		end
		CL_BF: begin                      // EA-fetch evaluated it; stores come in x.st_*
			if (x.wr_ccr) begin w.ccr_v = 1'b1; w.ccr_val = {ccr_in[4], x.a[3:2], 2'b00}; end
			if (x.dk == DK_REG) begin w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = x.c; end
		end
		CL_CHK: begin
			w.ccr_v = 1'b1; w.ccr_val = {ccr_in[4], (chk_v < 0), ccr_in[2], ccr_in[1], chk_c};
		end
		CL_CHK2: begin
			w.ccr_v = 1'b1;
			w.ccr_val = {ccr_in[4], ccr_in[3], (c2_rn == c2_lb) || (c2_rn == c2_ub), ccr_in[1], c2_oob};
		end
		CL_PACK, CL_UNPK: begin           // no flags
			if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr;
				w.w0_val = (x.cls == CL_PACK) ? merge(x.b, pk_res, SZ_B) : merge(x.b, up_res, SZ_W);
			end else if (x.dk == DK_MEM) begin
				w.st_v = 1'b1; w.st_addr = x.daddr;
				w.st_data = (x.cls == CL_PACK) ? pk_res : up_res;
				w.st_size = (x.cls == CL_PACK) ? SZ_B : SZ_W;
			end
		end
		CL_CAS: begin                     // equal: Du -> <ea>; else <ea> -> Dc
			w.ccr_v = 1'b1; w.ccr_val = alu_flags;   // CMP <ea> - Dc
			// Timing: which ports write must not depend on the compare (it is
			// forwarded to EA-fetch).  So Dc is always written (with itself
			// when equal) and there is always a store: Du when equal, else the
			// M68040's write-back of the value read (M68040UM 7.4.5 p. 7-26).
			w.w0_v = 1'b1; w.w0_r = x.dr;                 // x.dr = Dc
			// x.cc: EA-fetch's equality (the same as the compare's Z)
			w.w0_val = x.cc ? x.a : merge(x.a, x.b, x.size);
			w.st_v = 1'b1; w.st_addr = x.daddr; w.st_size = x.size;
			w.st_data = (x.cc ? x.c : x.b) & szmask(x.size);
			w.st_rb = !x.cc;
		end
		CL_MULDIV: begin
			if (x.cc) begin               // divide by zero: C cleared, then vector 5
				w.ccr_v = 1'b1; w.ccr_val = {ccr_in[4:1], 1'b0};
			end else if (!md_long) begin
				if (md_div) begin : mdw_div
					logic ovf_w;
					ovf_w = md_ovf | (md_sgn ? (($signed(md_rlo) > 32'sd32767) || ($signed(md_rlo) < -32'sd32768))
					                         : (md_rlo > 32'h0000_FFFF));
					w.ccr_v = 1'b1;
					// (overflow: Dq rewritten with itself -- the write ports do not
					// depend on the result, which is forwarded)
					w.w0_v = 1'b1; w.w0_r = x.dr;
					if (ovf_w) begin w.ccr_val = {ccr_in[4:2], 1'b1, 1'b0}; w.w0_val = x.b; end
					else begin
						w.w0_val = {md_rhi[15:0], md_rlo[15:0]};
						w.ccr_val = {ccr_in[4], md_rlo[15], (md_rlo[15:0] == 16'd0), 2'b00};
					end
				end else begin
					w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = md_rlo;
					w.ccr_v = 1'b1; w.ccr_val = {ccr_in[4], md_rlo[31], (md_rlo == 32'd0), 2'b00};
				end
			end else if (md_div) begin
				// 68040 divide overflow: V=1 C=0, N Z and the registers unchanged
				w.ccr_v = 1'b1;
				w.w0_v = 1'b1; w.w0_r = x.dr;
				if (x.dr2 != x.dr) begin w.u1_v = 1'b1; w.u1_r = x.dr2; end
				if (md_ovf) begin                    // registers rewritten with themselves
					w.ccr_val = {ccr_in[4:2], 1'b1, 1'b0};
					w.w0_val = x.b; w.u1_val = x.c;
				end else begin
					w.w0_val = md_rlo;                   // quotient -> Dq
					w.ccr_val = {ccr_in[4], md_rlo[31], (md_rlo == 32'd0), 2'b00};
					w.u1_val = md_rhi;
				end
			end else begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = md_rlo;               // low product -> Dl
				w.ccr_v = 1'b1;
				if (md_64) begin
					w.ccr_val = {ccr_in[4], md_rhi[31], (md_rhi == 32'd0) && (md_rlo == 32'd0), 2'b00};
					// the 68040 writes Dh before Dl: Dh == Dl keeps the LOW half
					if (x.dr2 != x.dr) begin w.u1_v = 1'b1; w.u1_r = x.dr2; w.u1_val = md_rhi; end
				end else
					w.ccr_val = {ccr_in[4], md_rlo[31], (md_rlo == 32'd0),
					             md_sgn ? (md_rhi != {32{md_rlo[31]}}) : (md_rhi != 32'd0), 1'b0};
			end
		end
		CL_BCC: begin
			redir = 1'b0;            // resolved (and redirected) in EA-fetch
		end
		CL_BSR, CL_JSR: begin
			w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = x.next_pc; w.st_size = SZ_L;
		end
		CL_DBCC: begin               // the branch was resolved in EA-fetch; EX decrements
			if (!x.cc) begin w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = {x.b[31:16], dbcc_dec}; end
			redir = 1'b0;
		end
		CL_SCC: begin                     // Scc: Dn byte, or a byte store (no read on the 68040)
			if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = {x.b[31:8], {8{cond}}};
			end else if (x.dk == DK_MEM) begin
				w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = {24'd0, {8{cond}}}; w.st_size = SZ_B;
			end
		end
		CL_MOVE2SR: begin
			w.sr_v = 1'b1; w.sr_val = x.a[15:0] & `AP040_SR_MASK;
		end
		CL_MOVEC: begin
			if (!x.creg_to) begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = creg_rd;
			end else if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = x.a;     // Rn -> USP/ISP/MSP
			end else begin
				w.creg_v = 1'b1; w.creg_sel = x.creg_sel; w.creg_val = x.a;
			end
		end
		default: ;
	endcase
end

// this micro-op's store, for EA-fetch's store-to-load forwarding
assign fw_st_v    = eaf_valid && w.st_v;
assign fw_st_addr = w.st_addr;
assign fw_st_size = w.st_size;
assign fw_st_data = w.st_data;

// the CCR this micro-op leaves, for EA-fetch's branch resolution
assign fw_ccr_v  = eaf_valid && (w.ccr_v || w.sr_v);
assign fw_ccr    = w.sr_v ? w.sr_val[4:0] : w.ccr_val;

assign fw_w0_v   = eaf_valid && w.w0_v;
assign fw_w0_r   = w.w0_r;
assign fw_w0_val = w.w0_val;

// The redirect goes out in the micro-op's first clock here, whether or not WB
// holds an older store (timing: st_done -- the memory's acknowledge -- must
// not reach IF's fetch address; the gate build's clk_114 -> clk_38 path,
// M7), and only once: ex_rdone remembers it while WB holds this micro-op
// here.  EA-fetch keeps its output register (this micro-op) through its own
// redirect's flush (keep_out, core).  An older store that faults squashes
// this micro-op anyway, and its exception redirects IF again.
reg  ex_rdone;
assign ex_redirect    = eaf_valid && redir && !ex_rdone;
always @(posedge clk)
	if (!nreset) ex_rdone <= 1'b0;
	else if (ce) ex_rdone <= eaf_valid && stall_in && !wb_drop && (ex_rdone || (redir && !ex_rdone));
assign ex_redirect_pc = redir_pc;
assign ex_redirect_s  = w.sr_v ? w.sr_val[13] : sr_in[13];


always @(posedge clk) begin
	if (!nreset) begin
		exe_valid <= 1'b0;
		exe_o     <= '0;
	end else if (ce && wb_drop) begin
		exe_valid <= 1'b0;
	end else if (ce && !stall_in) begin
		// a MUL/DIV still running sends a bubble to WB
		exe_valid <= eaf_valid && !md_wait && !in_drop;
		if (eaf_valid && !md_wait) exe_o <= w;
	end
end

endmodule
