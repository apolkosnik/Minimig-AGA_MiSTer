//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_core.v - execution unit: instruction pipe, decoder, sequencer,     //
// exception processing, coprocessor interface, MMU instructions            //
//                                                                          //
// The sequencer is a state machine whose states are in core/ap030_states   //
// .vh and whose bodies are in the core/ap030_*.vh includes.  Every data    //
// access goes through one wait state (S_DWAIT) with a recorded destination //
// and return state, which is also what makes an instruction resumable      //
// after a bus fault: the format $B frame carries the resume state and the  //
// temporaries, RTE restores them (UM 8.2, 8.4).                            //
//                                                                          //
// The instruction pipe holds up to six words; the first two are the        //
// MC68030's stages C and B for the fault frames, so stage C = the word at  //
// scan_pc and stage B = the word at scan_pc + 2 (UM 8.2).                  //
//--------------------------------------------------------------------------//

`include "ap030_defs.svh"

module ap030_core
(
	input             clk,
	input             rst,

	// ---- data port (ap030_memsys) ---------------------------------------
	output reg        d_stb,
	output reg [31:0] d_addr,
	output reg  [1:0] d_size,
	output reg        d_rw,
	output reg        d_rmc,
	output reg        d_rmc_last,
	output reg        d_rmc_release,
	output reg        d_iack,
	output reg        d_nocache,    // this read bypasses the data cache (system option, see ap030_top)
	input             nmi_vec_nocache,
	output reg  [2:0] d_fc,
	output reg [31:0] d_wdata,
	input             d_ack,
	input      [31:0] d_rdata,
	input             d_fault,
	input             d_avec,
	input             d_iack_berr,
	input             d_late_fault,
	input             d_wpend,
	input      [31:0] f_addr,
	input       [2:0] f_fc,
	input       [1:0] f_size,
	input             f_rw,
	input             f_rm,
	input      [31:0] f_dob,
	input       [2:0] f_got,
	input      [31:0] f_partial,

	// ---- instruction port ------------------------------------------------
	output reg        i_stb,
	output reg [31:0] i_addr,
	output reg  [2:0] i_fc,
	input             i_ready,      // the memory system can take another fetch
	input             i_ack,
	input      [31:0] i_data,
	input             i_fault,

	// ---- MMU instructions and registers --------------------------------
	output reg        op_req,
	output reg  [2:0] op_kind,
	output reg  [2:0] op_level,
	output reg [31:0] op_la,
	output reg  [2:0] op_fc,
	output reg  [2:0] op_fcmask,
	input             op_done,
	input      [31:0] op_desc_addr,
	output reg        reg_we,
	output reg  [2:0] reg_sel,
	output reg [31:0] reg_wdata_hi,
	output reg [31:0] reg_wdata_lo,
	output reg        reg_fd,
	input             cfg_err,
	input      [31:0] tc,
	input      [31:0] srp_hi, srp_lo, crp_hi, crp_lo,
	input      [31:0] tt0, tt1,
	input      [15:0] mmusr,
	input             bus_quiet,

	// ---- cache control -----------------------------------------------------
	output reg [31:0] cacr,
	output reg        cacr_ci,
	output reg        cacr_cei,
	output reg        cacr_cd,
	output reg        cacr_ced,
	output      [7:2] caar_idx,

	// ---- pins --------------------------------------------------------------
	input       [2:0] ipl_n,
	output            ipend_n,
	output reg        reset_drive,   // RESET instruction: drive the RESET pin low
	output            status_n,
	output            refill_n,
	output            halted,

	output     [31:0] dbg_pc,
	output     [15:0] dbg_sr,
	output      [7:0] dbg_state,
	output reg        dbg_inst,     // pulse: an instruction was dispatched (statistics)
	output     [31:0] dbg_vbr       // VBR (system glue: NMI vector address)
);

`include "core/ap030_states.vh"

//---------------------------------------------------------------------------
// architectural state
//---------------------------------------------------------------------------
reg [15:0] sr;
reg [31:0] vbr;
assign dbg_vbr = vbr;
reg [31:0] caar;
reg  [2:0] sfc, dfc;
wire       sr_s = sr[`SR_S];
wire       sr_m = sr[`SR_M];
wire [2:0] fc_data = sr_s ? `FC_SUPER_DATA : `FC_USER_DATA;
wire [2:0] fc_prog = sr_s ? `FC_SUPER_PROG : `FC_USER_PROG;
assign caar_idx = caar[7:2];

//---------------------------------------------------------------------------
// register file
//---------------------------------------------------------------------------
reg         rf_we;
reg   [3:0] rf_waddr;
reg   [1:0] rf_wact;           // A7 at issue: 0 USP, 1 ISP, 2 MSP
reg  [31:0] rf_wdata;
reg   [3:0] ra_a, ra_b, ra_c;
wire [31:0] rf_a, rf_b, rf_c;
wire  [3:0] ra_d, ra_e;        // dispatch ports: source and destination registers of the next instruction
wire [31:0] rf_d, rf_e;
reg         sp_we;
reg   [1:0] sp_sel;
reg  [31:0] sp_wdata;
wire [31:0] usp_q, isp_q, msp_q;

ap030_regfile rf (
	.clk(clk), .rst(rst), .sr_s(sr_s), .sr_m(sr_m),
	.we(rf_we), .waddr(rf_waddr), .wact(rf_wact), .wdata(rf_wdata),
	.raddr_a(ra_a), .rdata_a(rf_a), .raddr_b(ra_b), .rdata_b(rf_b), .raddr_c(ra_c), .rdata_c(rf_c),
	.raddr_d(ra_d), .rdata_d(rf_d), .raddr_e(ra_e), .rdata_e(rf_e),
	.sp_we(sp_we), .sp_sel(sp_sel), .sp_wdata(sp_wdata),
	.usp_q(usp_q), .isp_q(isp_q), .msp_q(msp_q)
);

//---------------------------------------------------------------------------
// ALU and multiply/divide
//---------------------------------------------------------------------------
reg   [5:0] alu_op;
reg   [1:0] alu_size;
reg   [5:0] alu_cnt;
reg  [31:0] alu_a, alu_b;
wire [31:0] alu_r;
// ALU operand selection per state (see ap030_exec.vh)
`define ALU_SET(op_, sz_, a_, b_, cnt_) begin alu_op = op_; alu_size = sz_; alu_a = a_; alu_b = b_; alu_cnt = cnt_; end
wire  [4:0] alu_f;
ap030_alu alu (.clk(clk), .op(alu_op), .size(alu_size), .shcnt(alu_cnt), .a(alu_a), .b(alu_b),
               .flags_in(sr[4:0]), .result(alu_r), .flags_out(alu_f));

reg         md_start, md_div, md_sign;
reg  [31:0] md_a, md_hi, md_lo;
wire        md_done, md_ovf;
wire [31:0] md_rhi, md_rlo;
ap030_muldiv md (.clk(clk), .rst(rst), .start(md_start), .is_div(md_div), .sign_op(md_sign),
                 .op_a(md_a), .op_hi(md_hi), .op_lo(md_lo), .done(md_done), .res_hi(md_rhi),
                 .res_lo(md_rlo), .ovf(md_ovf));

//---------------------------------------------------------------------------
// instruction pipe
//---------------------------------------------------------------------------
reg [15:0] pq [0:5];
reg  [5:0] pq_v, pq_f;
reg  [2:0] pq_n;
reg [31:0] scan_pc;        // address of pq[0] (stage C)
reg [31:0] fetch_pc;       // next longword to request
reg        fetch_skip;     // discard the first word of the next fetched longword
reg  [1:0] fetch_out;      // fetches outstanding (they return in order, two at most)
reg  [1:0] fetch_disc;     // the first of them belong to a flushed stream
reg        fetch_hold;     // no prefetching (halt, stop, refill of a bad address)
reg        refill_p;       // REFILL pulse (posedge)
// per-clock pipe commands from the sequencer
reg  [1:0] pop_n;
reg        flush_req;
reg [31:0] flush_pc;
reg        pipe_load;      // RTE: preload stages C/B from the frame
reg [15:0] pipe_c, pipe_b;
reg        pipe_c_v, pipe_b_v;

wire        w0_v  = pq_v[0];
wire        w1_v  = pq_v[1];
wire        w0_f  = pq_f[0];
wire        w1_f  = pq_f[1];
wire [15:0] w0    = pq[0];
wire [15:0] w1    = pq[1];
wire        have2 = pq_v[0] & pq_v[1];

//---------------------------------------------------------------------------
// interrupt synchronizer (UM 8.1.9: two consecutive falling-edge samples)
//---------------------------------------------------------------------------
reg [2:0] ipl_s1, ipl_s2;
always @(negedge clk) begin
	ipl_s1 <= ~ipl_n;
	ipl_s2 <= ipl_s1;
end
reg [2:0] irq_lvl;         // recognized level
reg       nmi_edge;        // a transition to level 7 has not been serviced
reg       irq_taken7;      // pulse from the sequencer: level 7 accepted
always @(posedge clk) begin
	if (rst) begin irq_lvl <= 3'd0; nmi_edge <= 1'b0; end
	else begin
		if (ipl_s1 == ipl_s2) begin
			if (ipl_s2 == 3'd7 && irq_lvl != 3'd7) nmi_edge <= 1'b1;
			irq_lvl <= ipl_s2;
		end
		if (irq_taken7) nmi_edge <= 1'b0;
	end
end
wire irq_pend = (irq_lvl > sr[10:8]) || (irq_lvl == 3'd7 && nmi_edge);
reg  ipend_r;
assign ipend_n = ~ipend_r;

//---------------------------------------------------------------------------
// sequencer registers
//---------------------------------------------------------------------------
reg  [7:0] state;
reg [15:0] ir;             // operation word
reg [15:0] ext;            // second word (bitfield, MUL/DIV, CAS, CHK2, MOVES, MOVEC, MMU, coprocessor)
reg [31:0] pc_i;           // address of the current instruction
reg [31:0] ea, ea2;        // effective addresses
reg [31:0] src, dst, imm, tmp, tmp2, tmp3;
reg  [7:0] cnt;
reg  [7:0] sub;
reg [15:0] mm_mask;
reg        ea_pc;          // the EA is PC-relative: its reads are program references (UM 2.4)
reg        ea_sel;         // 0: EA from ir[5:0], 1: MOVE destination from ir[11:6]
reg  [7:0] ea_ret;         // state after the EA calculation
reg  [7:0] imm_ret;
reg        imm_tgt;        // 0: src, 1: dst
reg  [3:0] dw_dst;
reg  [7:0] dw_ret;
reg  [3:0] dw_reg;
reg        tr_t1, tr_t0;   // trace bits at the start of the instruction
reg        flow;           // the instruction changed the program flow (T0 trace)
reg        trace_pend;
reg        late_fault_pend;
reg        stopped;
reg        halted_r;
reg [31:0] fr [0:22];      // RTE frame image (23 longwords)
// frame words as wires (bit selects of a function result are not Verilog-2001)
wire [15:0] frw [0:45];
genvar gi;
generate for (gi = 0; gi < 46; gi = gi + 1) begin : g_frw
	assign frw[gi] = (gi % 2) ? fr[gi / 2][15:0] : fr[gi / 2][31:16];
end endgenerate
// exception bookkeeping
reg  [7:0] exc_vec;
reg  [3:0] exc_fmt;
reg [31:0] exc_pc;         // PC field
reg [31:0] exc_ia;         // instruction address field (formats 2, 9) / fault address
reg [15:0] exc_sr;
reg [15:0] exc_ssw;
reg  [3:0] exc_rk;         // resume kind
reg  [7:0] exc_rs;         // resume state
reg  [7:0] exc_cnt;        // cnt, dw_dst and dw_ret at the fault: the frame push
reg  [3:0] exc_dw_dst;     // loop itself uses them, so the frame takes the copies
reg  [7:0] exc_dw_ret;
reg        exc_is_irq;
reg        exc_is_reset;
reg        exc_busfault;   // processing a bus/address error: another fault halts
reg        exc_throw;      // building the throwaway frame
reg [31:0] exc_sp;         // frame base
reg  [5:0] exc_len;        // frame length in longwords
reg  [2:0] exc_ilvl;
reg [15:0] exc_stage_c, exc_stage_b;
reg [31:0] exc_baddr;
reg [31:0] exc_fa, exc_dob, exc_dib;
reg  [2:0] exc_got;
reg [31:0] exc_partial;
reg  [2:0] rte_kind;
reg        trace_after_exc;
// coprocessor
reg  [2:0] cp_id;
reg [15:0] cp_resp;
reg        cp_cond;        // conditional category instruction
reg  [7:0] cp_len;
reg  [7:0] cp_pos;
reg        cp_dr;
reg        cp_ca;
reg        cp_pcbit;
reg        cp_trace_wait;  // trace pending: wait for null CA=0 PF=1
reg [31:0] cp_base;        // CIR base address
reg  [3:0] cp_kind;        // instruction category for the resume
// RESET instruction counter
reg  [9:0] rst_cnt;
// STATUS
reg  [1:0] status_cnt;
reg        status_p;
// bypass of a register write being applied in the dispatch clock
reg        byp_we;
reg  [3:0] byp_reg;
reg [31:0] byp_data;
reg        stream_fault_pend;
reg [31:0] dbg_pc_r;
// generic-path controls latched at dispatch
reg  [5:0] g_alu;
reg  [1:0] g_size;
reg  [1:0] g_srck, g_dstk;
reg  [3:0] g_dreg;
reg  [3:0] g_sreg;         // source register (the states use the latched fields, not the decoder)
reg        sh_wait;        // a shift/rotate result needs the registered shifter's extra clock
wire       g_alu_shift = (g_alu >= `ALU_ASL) && (g_alu <= `ALU_ROXR);
reg        g_flags, g_wb, g_sext, g_bitop, g_shift, g_move_mem, g_dstrd;
reg  [7:0] nx;
reg        rte_fake;       // RTE with DF clear on a read: deliver the DIB as the data
reg [31:0] rte_fake_data;
reg        rerun_merge;    // a rerun read completes a partially read operand
reg        exc_active;     // exception processing in progress
reg        cpu_flt_ill;    // a bus error on this CPU-space cycle is an illegal instruction (BKPT)
reg        cpu_flt_fline;  // ... is an F-line exception (first coprocessor access)
reg        iack_pc_i;      // interrupt frame carries the instruction address (Busy primitive)

// interrupt processing in progress (masks IPEND)
wire exc_is_irq_active = (state == S_EXC0 || state == S_EXC1 || state == S_EXC2 || state == S_EXC3 || state == S_IACK) && exc_is_irq;
assign halted = halted_r;
assign dbg_pc = pc_i;
assign dbg_sr = sr;
assign dbg_state = state;

//---------------------------------------------------------------------------
// decoder: from the word about to be dispatched, or from ir afterwards
//---------------------------------------------------------------------------
wire        at_dispatch = (state == S_FETCH) || (state == S_GEN_EXEC);
wire [15:0] dw = at_dispatch ? w0 : ir;
`include "core/ap030_decode.vh"

//---------------------------------------------------------------------------
// helpers
//---------------------------------------------------------------------------
function [31:0] sext8;  input [7:0] v;  begin sext8 = {{24{v[7]}}, v}; end endfunction
function [31:0] sext16; input [15:0] v; begin sext16 = {{16{v[15]}}, v}; end endfunction

// condition codes (PRM 3.3)
function cc_true;
	input [3:0] c;
	input [4:0] f;   // {X,N,Z,V,C}
	reg n, z, v, cf;
	begin
		n = f[3]; z = f[2]; v = f[1]; cf = f[0];
		case (c)
			4'h0: cc_true = 1'b1;
			4'h1: cc_true = 1'b0;
			4'h2: cc_true = !cf & !z;
			4'h3: cc_true = cf | z;
			4'h4: cc_true = !cf;
			4'h5: cc_true = cf;
			4'h6: cc_true = !z;
			4'h7: cc_true = z;
			4'h8: cc_true = !v;
			4'h9: cc_true = v;
			4'hA: cc_true = !n;
			4'hB: cc_true = n;
			4'hC: cc_true = (n == v);
			4'hD: cc_true = (n != v);
			4'hE: cc_true = (n == v) & !z;
			default: cc_true = (n != v) | z;
		endcase
	end
endfunction

// merge a sized result into a register value
function [31:0] merge;
	input [31:0] old; input [31:0] r; input [1:0] sz;
	begin
		case (sz)
			`SZ_B: merge = {old[31:8], r[7:0]};
			`SZ_W: merge = {old[31:16], r[15:0]};
			default: merge = r;
		endcase
	end
endfunction

function [31:0] sext_sz;
	input [31:0] v; input [1:0] sz;
	begin
		case (sz)
			`SZ_B: sext_sz = sext8(v[7:0]);
			`SZ_W: sext_sz = sext16(v[15:0]);
			default: sext_sz = v;
		endcase
	end
endfunction

// CHK2/CMP2 N and V: undefined in the PRM; the MC68020/030 values as
// tabulated by WinUAE setchk2undefinedflags (bounds and value are signed,
// sign-extended to 32 bits; the differences wrap)
function [1:0] chk2_nv;           // {N, V}
	input [31:0] lower, upper, val;
	reg n, v;
	reg ln, un, vn;
	reg [31:0] lv, uv, vl;
	begin
		n = 1'b0; v = 1'b0;
		ln = lower[31]; un = upper[31]; vn = val[31];
		lv = lower - val; uv = upper - val; vl = val - lower;
		if (val == lower || val == upper) ;
		else if (ln && !un) begin
			if ($signed(val) < $signed(lower)) n = 1'b1;
			if (!vn && $signed(val) < $signed(upper)) n = 1'b1;
			if (!vn && !lv[31]) begin
				v = 1'b1; n = ($signed(val) > $signed(upper));
			end
		end else if (!ln && un) begin
			if (!vn) n = 1'b1;
			if ($signed(val) > $signed(upper)) n = 1'b1;
			if ($signed(val) > $signed(lower) && !uv[31]) begin v = 1'b1; n = 1'b0; end
		end else if (!ln && !un && $signed(lower) > $signed(upper)) begin
			if ($signed(val) > $signed(upper) && $signed(val) < $signed(lower)) n = 1'b1;
			if (vn && lv[31]) v = 1'b1;
			if (vn && !lv[31]) n = 1'b1;
		end else if (!ln && !un) begin
			if (!vn && $signed(val) < $signed(lower)) n = 1'b1;
			if ($signed(val) > $signed(upper)) n = 1'b1;
			if (vn && uv[31]) begin v = 1'b1; n = 1'b1; end
		end else if ($signed(lower) > $signed(upper)) begin
			if (!vn) n = 1'b1;
			if ($signed(val) > $signed(upper) && $signed(val) < $signed(lower)) n = 1'b1;
			if (!vn && vl[31]) begin n = 1'b0; v = 1'b1; end
		end else begin
			if ($signed(val) < $signed(lower)) n = 1'b1;
			if (vn && $signed(val) > $signed(upper)) n = 1'b1;
			if (!vn && vl[31]) begin n = 1'b1; v = 1'b1; end
		end
		chk2_nv = {n, v};
	end
endfunction

function [31:0] size_bytes;
	input [1:0] sz; input a7;
	begin
		case (sz)
			`SZ_B: size_bytes = a7 ? 32'd2 : 32'd1;
			`SZ_W: size_bytes = 32'd2;
			default: size_bytes = 32'd4;
		endcase
	end
endfunction

// index register value with scale for brief/full extension words
function [31:0] index_val;
	input [31:0] xn; input [15:0] xw;
	reg [31:0] v;
	begin
		v = xw[11] ? xn : sext16(xn[15:0]);
		index_val = v << xw[10:9];
	end
endfunction

// the EA engine runs after dispatch: its fields come from ir, so that the
// dispatch multiplexer (dw) is not in the register read and address paths
wire [2:0] ea_mode = ea_sel ? ir[8:6]  : ir[5:3];
wire [2:0] ea_regn = ea_sel ? ir[11:9] : ir[2:0];
wire       ea_pcrel = !ea_sel && (ir[5:3] == 3'b111) && (ir[2:1] == 2'b01);

//---------------------------------------------------------------------------
// register read port selection
//---------------------------------------------------------------------------
always @* begin
	ra_a = {1'b1, ea_regn};       // EA base register by default
	ra_b = g_dreg;                // destination register of the current instruction
	ra_c = 4'd15;                 // A7
	case (state)
		S_EA, S_EA_FULL: ra_c = {w0[15], w0[14:12]};          // index register
		S_MOVEM1, S_MOVEM2, S_MOVEM3, S_MOVEM4, S_MOVEM_LAST, S_CPREGS, S_CPREGS2, S_CP9: ra_a = cnt[3:0];
		S_MOVEC, S_MOVES0, S_MOVES1, S_CHK2_2, S_CHK2_3, S_CHK2_4: ra_a = {ext[15], ext[14:12]};
		S_CAS0, S_CAS1, S_CAS1B, S_CAS_WR: begin ra_a = {1'b0, ext[2:0]}; ra_b = {1'b0, ext[8:6]}; end
		S_CAS2_0, S_CAS2_1, S_CAS2_2, S_CAS2_3, S_CAS2_4, S_CAS2_4B, S_CAS2_5, S_CAS2_5B, S_CAS2_6, S_CAS2_7, S_CAS2_8: begin
			ra_a = tmp3[16] ? {1'b0, tmp3[2:0]} : {1'b0, ext[2:0]};
			ra_b = tmp3[16] ? {1'b0, tmp3[8:6]} : {1'b0, ext[8:6]};
			ra_c = tmp3[16] ? {tmp3[15], tmp3[14:12]} : {ext[15], ext[14:12]};
		end
		S_BF0: begin ra_a = {1'b0, ext[14:12]}; ra_b = {1'b0, ext[8:6]}; ra_c = {1'b0, ext[2:0]}; end
		S_BF1, S_BF2, S_BF3, S_BF4, S_BF5, S_BFWR: begin ra_a = {1'b0, ext[14:12]}; ra_b = {1'b0, ir[2:0]}; end
		S_MULDIV0, S_MULDIV1, S_MULDIV2, S_MULDIVW: begin ra_a = {1'b0, ext[14:12]}; ra_b = {1'b0, ext[2:0]}; end
		S_EXG, S_EXG2: begin
			ra_a = {ir[7:3] == 5'b01001, ir[11:9]};
			ra_b = {ir[7:3] != 5'b01000, ir[2:0]};
		end
		S_PACK, S_PACK2, S_PACK3: begin ra_a = {ir[3], ir[2:0]}; ra_b = {ir[3], ir[11:9]}; end
		S_LINK, S_LINK2, S_LINK3, S_UNLK, S_UNLK2, S_UNLK3, S_MOVE_USP: ra_a = {1'b1, ir[2:0]};
		S_MOVEP0, S_MOVEP1, S_MOVEP2, S_MOVEP3: begin ra_a = {1'b1, ir[2:0]}; ra_b = {1'b0, ir[11:9]}; end
		S_DBCC, S_CPDBCC, S_CPDBCC2: ra_a = {1'b0, ir[2:0]};
		S_CP2, S_CP3, S_CP4, S_CP5, S_CP6, S_CP7, S_CP8, S_CP10, S_CPREG, S_CPCTRL, S_CPCTRL2, S_CPTOS, S_CPEAX,
		S_CPXFER, S_CPXFER2, S_CPXFER3, S_CPMULT, S_CPMULT2, S_CPMULT3,
		S_CPSAVE0, S_CPSAVE1, S_CPREST0, S_CPREST1: begin
			ra_a = {cp_resp[3], cp_resp[2:0]};   // single register transfer
			ra_b = {1'b1, ir[2:0]};              // An of the effective address
		end
		S_CPXEA: begin
			ra_a = {cp_resp[3], cp_resp[2:0]};
			ra_b = {1'b1, ir[2:0]};              // An direct or the address register of the EA
			ra_c = {1'b0, ir[2:0]};              // Dn direct
		end
		S_PMMU0, S_PLOAD, S_PFLUSH2, S_PTEST, S_PTEST2, S_PFLUSH, S_PMOVE_RD, S_PMOVE_RD2, S_PMOVE_RD3, S_PMOVE_WR, S_PMOVE_WR2, S_PMOVE_FIN: begin
			ra_a = {1'b0, ext[2:0]};          // Dn holding the function code
			ra_b = {1'b1, ext[7:5]};          // An for the PTEST result
		end
		default: ;
	endcase
end

//---------------------------------------------------------------------------
// STATUS / REFILL (asserted from falling edges, UM 12.7.1)
//---------------------------------------------------------------------------
reg status_n_r, refill_n_r;
always @(negedge clk) begin
	status_n_r <= rst ? 1'b1 : ~(status_p | halted_r);
	refill_n_r <= rst ? 1'b1 : ~refill_p;
end
assign status_n = status_n_r;
assign refill_n = refill_n_r;

//---------------------------------------------------------------------------
// exception frame word generator (UM 8.4)
//---------------------------------------------------------------------------
`include "core/ap030_frame.vh"

//---------------------------------------------------------------------------
// tasks and helper functions
//---------------------------------------------------------------------------
`include "core/ap030_funcs.vh"
`include "core/ap030_tasks.vh"

// the dispatch reads the operands of the instruction being decoded
assign ra_d = dc_sreg;
assign ra_e = dc_dreg;

//---------------------------------------------------------------------------
// ALU operand selection
//---------------------------------------------------------------------------
always @* begin
	`ALU_SET(g_alu, g_size,
	         g_sext ? sext_sz(src, g_size) :
	         (g_bitop ? ((g_dstk == DK_REG) ? {27'd0, src[4:0]} : {29'd0, src[2:0]}) : src),
	         dst, src[5:0])
	case (state)
		S_MOVE_WR: `ALU_SET(`ALU_MOVE, g_size, src, dst, 6'd0)
		S_PACK3:   `ALU_SET(g_alu, g_size, src, dst, 6'd0)
		S_TAS2:    `ALU_SET(`ALU_TAS, `SZ_B, src, dst, 6'd0)
		S_CAS1:    `ALU_SET(`ALU_CMP, g_size, rf_a, dst, 6'd0)
		S_CAS2_4:  `ALU_SET(`ALU_CMP, g_size, rf_a, src, 6'd0)
		S_CAS2_5:  `ALU_SET(`ALU_CMP, g_size, rf_a, dst, 6'd0)
		default: ;
	endcase
end

//---------------------------------------------------------------------------
// the sequencer
//---------------------------------------------------------------------------
integer k;
always @(posedge clk) begin
	// per-clock defaults
	pop_n = 2'd0;
	flush_req = 1'b0;
	flush_pc = 32'd0;
	pipe_load = 1'b0;
	byp_we = 1'b0;
	byp_reg = 4'd0;
	byp_data = 32'd0;
	rf_we <= 1'b0;
	sp_we <= 1'b0;
	d_stb <= 1'b0;
	d_rmc_release <= 1'b0;
	i_stb <= 1'b0;
	op_req <= 1'b0;
	dbg_inst <= 1'b0;
	reg_we <= 1'b0;
	cacr_ci <= 1'b0; cacr_cei <= 1'b0; cacr_cd <= 1'b0; cacr_ced <= 1'b0;
	md_start <= 1'b0;
	irq_taken7 <= 1'b0;
	refill_p <= 1'b0;
	status_p <= (status_cnt != 2'd0);
	if (status_cnt != 2'd0) status_cnt <= status_cnt - 2'd1;

	if (rst) begin
		state <= S_RESET0;
		sr <= `SR_RESET;
		vbr <= 32'd0;
		cacr <= 32'd0;
		caar <= 32'd0;
		sfc <= 3'd0; dfc <= 3'd0;
		pq_v <= 6'd0; pq_f <= 6'd0; pq_n <= 3'd0;
		scan_pc <= 32'd0; fetch_pc <= 32'd0; fetch_skip <= 1'b0; fetch_out <= 2'd0;
		fetch_disc <= 2'd0; fetch_hold <= 1'b1;
		trace_pend <= 1'b0; late_fault_pend <= 1'b0; stream_fault_pend <= 1'b0;
		stopped <= 1'b0; halted_r <= 1'b0;
		reset_drive <= 1'b0; rst_cnt <= 10'd0;
		ipend_r <= 1'b0;
		exc_busfault <= 1'b1;          // faults during the reset sequence halt (UM 8.1.1)
		exc_is_reset <= 1'b1;
		exc_is_irq <= 1'b0; exc_throw <= 1'b0;
		trace_after_exc <= 1'b0;
		cp_trace_wait <= 1'b0;
		status_cnt <= 2'd3;
		d_addr <= 32'd0; d_size <= 2'd0; d_rw <= 1'b1; d_rmc <= 1'b0; d_rmc_last <= 1'b0; d_iack <= 1'b0;
		d_nocache <= 1'b0;
		d_fc <= 3'd0; d_wdata <= 32'd0;
		i_addr <= 32'd0; i_fc <= 3'd0;
		ir <= 16'd0; ext <= 16'd0; pc_i <= 32'd0; ea <= 32'd0; ea2 <= 32'd0;
		src <= 32'd0; dst <= 32'd0; imm <= 32'd0; tmp <= 32'd0; tmp2 <= 32'd0; tmp3 <= 32'd0;
		cnt <= 8'd0; sub <= 8'd0; mm_mask <= 16'd0; ea_sel <= 1'b0; ea_pc <= 1'b0; ea_ret <= S_FETCH; imm_ret <= S_FETCH;
		imm_tgt <= 1'b0; dw_dst <= DW_NONE; dw_ret <= S_FETCH; dw_reg <= 4'd0;
		tr_t1 <= 1'b0; tr_t0 <= 1'b0; flow <= 1'b0;
		exc_vec <= 8'd0; exc_fmt <= 4'd0; exc_pc <= 32'd0; exc_ia <= 32'd0; exc_sr <= 16'd0; exc_ssw <= 16'd0;
		exc_rk <= 4'd0; exc_rs <= 8'd0; exc_sp <= 32'd0; exc_len <= 6'd0; exc_ilvl <= 3'd0;
		exc_cnt <= 8'd0; exc_dw_dst <= 4'd0; exc_dw_ret <= 8'd0;
		exc_stage_c <= 16'd0; exc_stage_b <= 16'd0; exc_baddr <= 32'd0; exc_fa <= 32'd0; exc_dob <= 32'd0;
		exc_dib <= 32'd0; exc_got <= 3'd0; exc_partial <= 32'd0; rte_kind <= 3'd0;
		g_alu <= 6'd0; g_size <= 2'd0; g_srck <= 2'd0; g_dstk <= 2'd0; g_dreg <= 4'd0; g_sreg <= 4'd0; g_flags <= 1'b0; g_wb <= 1'b0;
		sh_wait <= 1'b0;
		g_sext <= 1'b0; g_bitop <= 1'b0; g_shift <= 1'b0; g_move_mem <= 1'b0; g_dstrd <= 1'b0; nx <= S_FETCH;
		rte_fake <= 1'b0; rte_fake_data <= 32'd0; rerun_merge <= 1'b0; exc_active <= 1'b0;
		cpu_flt_ill <= 1'b0; cpu_flt_fline <= 1'b0; iack_pc_i <= 1'b0;
		cp_id <= 3'd0; cp_resp <= 16'd0; cp_cond <= 1'b0; cp_len <= 8'd0; cp_pos <= 8'd0; cp_dr <= 1'b0;
		cp_ca <= 1'b0; cp_pcbit <= 1'b0; cp_base <= 32'd0; cp_kind <= 4'd0;
		md_div <= 1'b0; md_sign <= 1'b0; md_a <= 32'd0; md_hi <= 32'd0; md_lo <= 32'd0;
		op_kind <= 3'd0; op_level <= 3'd0; op_la <= 32'd0; op_fc <= 3'd0; op_fcmask <= 3'd0;
		reg_sel <= 3'd0; reg_wdata_hi <= 32'd0; reg_wdata_lo <= 32'd0; reg_fd <= 1'b0;
		rf_waddr <= 4'd0; rf_wact <= 2'd1; rf_wdata <= 32'd0; sp_sel <= 2'd0; sp_wdata <= 32'd0;
	end else begin
		//---------------------------------------------------------- events from the memory system
		if (d_late_fault) begin
			// a posted write failed: taken at the next safe point (UM 8.1.2)
			late_fault_pend <= 1'b1;
			exc_fa <= f_addr; exc_dob <= f_dob;
			exc_ssw <= {4'd0, 3'b000, 1'b1, f_rm, f_rw, f_size, 1'b0, f_fc};   // DF RM RW SIZE 0 FC
		end
		ipend_r <= irq_pend && !exc_is_irq_active;

		//---------------------------------------------------------- the states
		`include "core/ap030_exec.vh"

		//---------------------------------------------------------- double bus fault
		// a frame write of a bus/address error exception failed on the bus
		// (posted writes report late): the processor halts (UM 8.1.2, 7.5.4)
		if (d_late_fault && exc_active && exc_busfault) begin
			late_fault_pend <= 1'b0;
			halted_r <= 1'b1;
			state <= S_HALT;
		end

		//---------------------------------------------------------- prefetch and pipe maintenance
		if (flush_req) begin
			pq_v <= 6'd0; pq_f <= 6'd0; pq_n <= 3'd0;
			scan_pc <= flush_pc;
			fetch_pc <= {flush_pc[31:2], 2'b00};
			fetch_skip <= flush_pc[1];
			// whatever is still outstanding belongs to the old stream
			fetch_out <= fetch_out - {1'b0, i_ack | i_fault};
			fetch_disc <= fetch_out - {1'b0, i_ack | i_fault};
			refill_p <= 1'b1;
		end else if (pipe_load) begin
			// RTE: stages C and B from the frame, fetching resumes behind them
			begin : pipe_preload
				reg [31:0] resume_fetch;
				resume_fetch = flush_pc + (pipe_c_v ? (pipe_b_v ? 32'd4 : 32'd2) : 32'd0);
				pq[0] <= pipe_c; pq[1] <= pipe_b;
				pq_v <= {4'd0, pipe_b_v & pipe_c_v, pipe_c_v};
				pq_f <= 6'd0;
				pq_n <= pipe_c_v ? (pipe_b_v ? 3'd2 : 3'd1) : 3'd0;
				scan_pc <= flush_pc;
				fetch_pc <= {resume_fetch[31:2], 2'b00};
				fetch_skip <= resume_fetch[1];
			end
			fetch_out <= fetch_out - {1'b0, i_ack | i_fault};
			fetch_disc <= fetch_out - {1'b0, i_ack | i_fault};
			refill_p <= 1'b1;
		end else begin
			// pop, then append the fetched words, then issue the next fetch
			begin : pipe_update
				reg [15:0] nq [0:5];
				reg [5:0] nv, nf;
				reg [2:0] nn;
				reg ret, disc_now;
				reg [1:0] out_after, disc_after, live;
				integer j;
				ret = i_ack | i_fault;                    // a fetch returns this clock
				disc_now = ret && (fetch_disc != 2'd0);   // ... from a flushed stream
				out_after = fetch_out - {1'b0, ret};
				disc_after = fetch_disc - {1'b0, disc_now};
				live = out_after - disc_after;            // fetches that will still append words
				for (j = 0; j < 6; j = j + 1) begin nq[j] = pq[j]; nv[j] = pq_v[j]; nf[j] = pq_f[j]; end
				nn = pq_n;
				if (pop_n != 0) begin
					for (j = 0; j < 6; j = j + 1) begin
						if (j + pop_n < 6) begin nq[j] = pq[j + pop_n]; nv[j] = pq_v[j + pop_n]; nf[j] = pq_f[j + pop_n]; end
						else begin nq[j] = 16'd0; nv[j] = 1'b0; nf[j] = 1'b0; end
					end
					nn = pq_n - pop_n;
					scan_pc <= scan_pc + {29'd0, pop_n, 1'b0};
				end
				if (ret && !disc_now) begin
					if (!fetch_skip) begin
						nq[nn] = i_data[31:16]; nv[nn] = 1'b1; nf[nn] = i_fault; nn = nn + 3'd1;
					end
					nq[nn] = i_data[15:0]; nv[nn] = 1'b1; nf[nn] = i_fault; nn = nn + 3'd1;
					fetch_skip <= 1'b0;
				end
				for (j = 0; j < 6; j = j + 1) begin pq[j] <= nq[j]; pq_v[j] <= nv[j]; pq_f[j] <= nf[j]; end
				pq_n <= nn;
				fetch_disc <= disc_after;
				// another longword when the queue has room for everything in flight
				// and the memory system can take it (two fetches at most)
				if (out_after != 2'd2 && i_ready && !halted_r && !fetch_hold && (nn + {live, 1'b0} <= 3'd4)) begin
					i_stb <= 1'b1;
					i_addr <= fetch_pc;
					i_fc <= fc_prog;
					fetch_pc <= fetch_pc + 32'd4;
					fetch_out <= out_after + 2'd1;
				end else fetch_out <= out_after;
			end
		end
	end
end

endmodule
