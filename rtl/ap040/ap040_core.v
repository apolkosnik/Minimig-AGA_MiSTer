//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_core.v - CPU core: fetch, decode, execute, exceptions              //
//                                                                          //
// Milestone C scope (see AP040_IMPLEMENTATION_PLAN.md):                    //
//  - 68000 base integer set, 68010 (MOVEC/MOVES/RTD/MOVE from CCR),        //
//    68020+ pieces: full extension word EAs incl. memory indirect,         //
//    LINK.L, EXTB.L, TST/CMPI/BTST on PC-relative and immediate,           //
//    32-bit MUL/DIV including 64-bit forms, TRAPcc, RTD                    //
//  - MC68040 MOVEC register set (MMU registers stored, used at milestone   //
//    E), CINV/CPUSH/PFLUSH/PTEST decode with privilege checks (no-ops      //
//    while caches/MMU are disabled), MOVE16                                //
//  - exceptions: formats $0/$1/$2, RTE with format validation and $1       //
//    throwaway continuation, autovectored interrupts with M-bit master/    //
//    interrupt stack switching, STOP, TRAP/TRAPV/CHK/divide-by-zero,       //
//    illegal/A-line/F-line/privilege/format error, address error on odd    //
//    control flow targets                                                  //
//                                                                          //
// Known gaps, all documented in tests/ap040/README:                        //
//  - bitfields, CAS/CAS2, CHK2/CMP2 take an illegal-instruction trap       //
//  - trace exceptions are not generated (T bits are stored only)           //
//  - TAS is not bus-locked; berr input is ignored (no format $7 yet)       //
//  - interrupts are always autovectored (wrapper ties ipl_autovector=1)    //
//                                                                          //
// The whole core advances only when ce (clkena_in) is high.                //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_core
#(
	parameter AP040_HAS_MMU      = 1,
	parameter AP040_HAS_FPU      = 0,
	parameter AP040_ENABLE_CACHE = 0,
	parameter AP040_FAST_SIM     = 0
)
(
	input             clk,
	input             nreset,
	input             ce,

	// internal memory transaction to ap040_bus16_adapter
	output reg        mem_req,
	output reg        mem_write,
	output reg        mem_instr,
	output reg  [1:0] mem_size,
	output reg [31:0] mem_addr,
	output reg [31:0] mem_wdata,
	output      [2:0] mem_fc,
	input             mem_ack,
	input      [31:0] mem_rdata,

	input       [2:0] ipl,
	input             ipl_autovector,
	input             berr,

	output            nresetout,
	output     [31:0] cacr_out,
	output     [31:0] vbr_out,

	output            debug_busy,
	output            debug_fault,
	output            debug_halted,
	output    [255:0] debug_status
);

//---------------------------------------------------------------------------
// architectural state
//---------------------------------------------------------------------------

reg [31:0] pc;          // next word to fetch from the instruction stream
reg [31:0] pc_i;        // address of the current instruction
reg [15:0] sr;
reg [31:0] vbr;
reg [31:0] cacr;
reg  [2:0] sfc, dfc;
reg [31:0] tc;          // 040 TC (E/P bits stored, used at milestone E)
reg [31:0] itt0, itt1, dtt0, dtt1;
reg [31:0] mmusr;
reg [31:0] urp, srp;
reg [15:0] ir;

wire sr_s = sr[`AP040_SR_S];
wire sr_m = sr[`AP040_SR_M];

assign vbr_out  = vbr;
assign cacr_out = cacr;

// interrupt input synchronization (active low pins, must be stable for two
// consecutive samples like the real part)
reg [2:0] ipl_s1, ipl_s2;
reg [2:0] irq_lvl;
reg       nmi_arm;
always @(posedge clk) begin
	if (!nreset) begin
		ipl_s1 <= 3'b111;
		ipl_s2 <= 3'b111;
		irq_lvl <= 3'd0;
	end
	else begin
		ipl_s1 <= ipl;
		ipl_s2 <= ipl_s1;
		if (ipl_s1 == ipl_s2) irq_lvl <= ~ipl_s2;
	end
end

wire irq_pend = (irq_lvl == 3'd7 && nmi_arm) ||
                (irq_lvl != 3'd0 && irq_lvl > sr[10:8]);

wire unused_in = ipl_autovector | berr;

//---------------------------------------------------------------------------
// register file
//---------------------------------------------------------------------------

reg         rf_we;
reg   [3:0] rf_waddr;
reg  [31:0] rf_wdata;
reg   [3:0] rr_a;
reg   [3:0] rr_b;
wire [31:0] rf_rdata_a;
wire [31:0] rf_rdata_b;
reg         aux_we;
reg   [1:0] aux_sel;
reg  [31:0] aux_wdata;
wire [31:0] usp_q, isp_q, msp_q;
wire [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_a0, dbg_a7;

ap040_regfile regfile
(
	.clk(clk), .ce(ce), .nreset(nreset),
	.sr_s(sr_s), .sr_m(sr_m),
	.we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata),
	.raddr_a(rr_a), .rdata_a(rf_rdata_a),
	.raddr_b(rr_b), .rdata_b(rf_rdata_b),
	.aux_we(aux_we), .aux_sel(aux_sel), .aux_wdata(aux_wdata),
	.usp_q(usp_q), .isp_q(isp_q), .msp_q(msp_q),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2),
	.dbg_a0(dbg_a0), .dbg_a7(dbg_a7)
);

//---------------------------------------------------------------------------
// ALU and multiply/divide
//---------------------------------------------------------------------------

reg   [5:0] alu_op;
reg   [1:0] op_size;
reg  [31:0] src_val, dst_val;
reg  [31:0] sh_val;
reg   [4:0] sh_fl;
reg   [6:0] state;
wire [31:0] alu_res;
wire  [4:0] alu_fl;

localparam S_SHIFT = 7'd29;   // forward declaration for the alu_b mux

wire alu_is_bitop = (alu_op >= `AP040_ALU_BTST) && (alu_op <= `AP040_ALU_BSET);
reg         p_sextw;
reg         p_dst_mem_bit;    // bit op destination is memory (modulo 8)

wire [31:0] alu_a = alu_is_bitop ? (p_dst_mem_bit ? {29'd0, src_val[2:0]}
                                                  : {27'd0, src_val[4:0]}) :
                    p_sextw      ? {{16{src_val[15]}}, src_val[15:0]} : src_val;
wire [31:0] alu_b = (state == S_SHIFT) ? sh_val : dst_val;
wire  [4:0] alu_fin = (state == S_SHIFT) ? sh_fl : sr[4:0];

ap040_alu alu
(
	.op(alu_op), .size(op_size),
	.a(alu_a), .b(alu_b),
	.flags_in(alu_fin),
	.result(alu_res), .flags_out(alu_fl)
);

reg         md_start, md_isdiv, md_sign;
reg  [31:0] md_a, md_hi, md_lo;
wire        md_done, md_ovf;
wire [31:0] md_rhi, md_rlo;

ap040_muldiv muldiv
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.start(md_start), .is_div(md_isdiv), .sign_op(md_sign),
	.op_a(md_a), .op_hi(md_hi), .op_lo(md_lo),
	.done(md_done), .res_hi(md_rhi), .res_lo(md_rlo), .ovf(md_ovf)
);

//---------------------------------------------------------------------------
// states
//---------------------------------------------------------------------------

localparam S_START       = 7'd0;
localparam S_BOOT0       = 7'd1;
localparam S_BOOT1       = 7'd2;
localparam S_FETCH       = 7'd3;
localparam S_DECODE      = 7'd4;
localparam S_NEXT        = 7'd5;
localparam S_HALT        = 7'd6;
localparam S_STOPPED     = 7'd7;
localparam S_IMMF        = 7'd8;
localparam S_MRD         = 7'd9;
localparam S_MWR         = 7'd10;
localparam S_EA_DISP     = 7'd11;
localparam S_EA_BASE     = 7'd12;
localparam S_EA_D16      = 7'd13;
localparam S_EA_EXTW     = 7'd14;
localparam S_EA_EXTW2    = 7'd15;
localparam S_EA_BD       = 7'd16;
localparam S_EA_MIND     = 7'd17;
localparam S_EA_OD       = 7'd18;
localparam S_EA_ABS      = 7'd19;
localparam S_PIPE_START  = 7'd20;
localparam S_PIPE_SREG   = 7'd21;
localparam S_PIPE_SRD    = 7'd22;
localparam S_PIPE_SDONE  = 7'd23;
localparam S_PIPE_DST    = 7'd24;
localparam S_PIPE_DREG   = 7'd25;
localparam S_PIPE_DEA    = 7'd26;
localparam S_PIPE_DDONE  = 7'd27;
localparam S_EXEC        = 7'd28;
// S_SHIFT = 29 declared above
localparam S_MD_WAIT     = 7'd30;
localparam S_MD_WB2      = 7'd31;
localparam S_MDL_RDR     = 7'd32;
localparam S_MDL_GO      = 7'd33;
localparam S_EXC0        = 7'd34;
localparam S_EXC1        = 7'd35;
localparam S_EXC2        = 7'd36;
localparam S_EXC3        = 7'd37;
localparam S_EXC4        = 7'd38;
localparam S_EXC5        = 7'd39;
localparam S_EXC6        = 7'd40;
localparam S_EXC_VEC     = 7'd41;
localparam S_EXC_JMP     = 7'd42;
localparam S_RTE_SR      = 7'd43;
localparam S_RTE_PC      = 7'd44;
localparam S_RTE_FMT     = 7'd45;
localparam S_RTE_FIN     = 7'd46;
localparam S_RTE_FIN2    = 7'd47;
localparam S_RET1        = 7'd48;
localparam S_RET2        = 7'd49;
localparam S_RET3        = 7'd50;
localparam S_BCC_EXT     = 7'd51;
localparam S_BSR_PUSH    = 7'd52;
localparam S_DBCC1       = 7'd53;
localparam S_DBCC2       = 7'd54;
localparam S_JMP1        = 7'd55;
localparam S_JSR1        = 7'd56;
localparam S_JSR2        = 7'd57;
localparam S_LEA1        = 7'd58;
localparam S_PEA1        = 7'd59;
localparam S_PEA2        = 7'd60;
localparam S_LINK1       = 7'd61;
localparam S_LINK2       = 7'd62;
localparam S_LINK3       = 7'd63;
localparam S_LINK4       = 7'd64;
localparam S_UNLK1       = 7'd65;
localparam S_UNLK2       = 7'd66;
localparam S_UNLK3       = 7'd67;
localparam S_MOVEM_SET   = 7'd68;
localparam S_MOVEM_SET2  = 7'd69;
localparam S_MOVEM_LOOP  = 7'd70;
localparam S_MOVEM_RD    = 7'd71;
localparam S_MOVEM_WR    = 7'd72;
localparam S_MOVEM_LD    = 7'd73;
localparam S_MOVEP1      = 7'd74;
localparam S_MOVEP2      = 7'd75;
localparam S_MOVEP_WR    = 7'd76;
localparam S_MOVEP_RD    = 7'd77;
localparam S_EXG1        = 7'd78;
localparam S_EXG2        = 7'd79;
localparam S_USP1        = 7'd80;
localparam S_MOVEC1      = 7'd81;
localparam S_MOVEC2      = 7'd82;
localparam S_MOVES1      = 7'd83;
localparam S_MOVES2      = 7'd84;
localparam S_MOVES_WR    = 7'd85;
localparam S_MOVES_RD    = 7'd86;
localparam S_PTEST1      = 7'd87;
localparam S_RESET_HOLD  = 7'd88;
localparam S_M16_SRC     = 7'd89;
localparam S_M16_DST     = 7'd90;
localparam S_M16_DST2    = 7'd91;
localparam S_M16_RD      = 7'd92;
localparam S_M16_RD2     = 7'd93;
localparam S_M16_WR      = 7'd94;
localparam S_M16_WR2     = 7'd95;
localparam S_M16_INC     = 7'd96;
localparam S_M16_INC2    = 7'd97;
localparam S_SROP        = 7'd98;
localparam S_SHIFT_WB    = 7'd99;
localparam S_TRAPCC      = 7'd100;
localparam S_STOP_LD     = 7'd101;
localparam S_MOVEM_EA    = 7'd102;
localparam S_MDL_RDQ     = 7'd103;
localparam S_MDL_EXT     = 7'd104;

// exec kinds
localparam EK_ALU     = 4'd0;
localparam EK_SHIFT   = 4'd1;
localparam EK_MD_W    = 4'd2;   // word multiply/divide
localparam EK_MD_L    = 4'd3;   // long multiply/divide (extension in x_ext)
localparam EK_CHK     = 4'd4;
localparam EK_SCC     = 4'd5;
localparam EK_PACK    = 4'd6;
localparam EK_UNPK    = 4'd7;

// src/dst kinds
localparam SK_NONE = 3'd0;
localparam SK_REG  = 3'd1;
localparam SK_IMM  = 3'd2;
localparam SK_MEM  = 3'd3;
localparam SK_IMPL = 3'd4;   // src_val preloaded at decode

localparam DK_NONE = 3'd0;
localparam DK_REG  = 3'd1;
localparam DK_MEM  = 3'd2;
localparam DK_SR   = 3'd3;
localparam DK_CCR  = 3'd4;

// ret_kind for RTS/RTR/RTD
localparam RK_RTS = 2'd0;
localparam RK_RTR = 2'd1;
localparam RK_RTD = 2'd2;

//---------------------------------------------------------------------------
// control registers of the execution engine
//---------------------------------------------------------------------------

reg  [6:0] r_imm_ret, r_ea_ret, r_m_ret;
reg  [1:0] imm_n;
reg        if_issued, m_issued;
reg [31:0] imm;
reg [31:0] x_ext;              // saved copy of imm (survives EA fetches)

reg        m_wr;
reg  [1:0] m_size;
reg [31:0] m_addr_r, m_wdat, m_val;

reg  [2:0] ea_mode;
reg  [2:0] ea_rn;
reg  [1:0] ea_size;
reg        ea_pcmode;
reg [31:0] ea_pcb;
reg [15:0] extw;
reg [31:0] ea_base_v, ea_idx_v, ea_mind;
reg        ea_post, ea_odl, ea_absl;
reg [31:0] ea_addr;

reg  [2:0] p_src, p_dst;
reg  [3:0] p_sreg, p_dreg;
reg  [1:0] p_ssize, p_dsize;
reg        p_rmw, p_wbsup, p_flags;
reg  [3:0] exec_kind;
reg  [2:0] src_mode_r, src_rn_r, dst_mode_r, dst_rn_r;
reg [31:0] dst_addr;

reg  [5:0] sh_cnt;
reg        sh_vacc;
reg        sh_rox;
reg        sh_any;

reg  [7:0] exc_vec;
reg  [3:0] exc_fmt;
reg [31:0] exc_spc, exc_addr, exc_sp;
reg        exc_is_irq, exc_pass2;
reg [15:0] sr_saved;
reg  [2:0] irq_lvl_l;

reg [15:0] rte_sr;
reg [31:0] rte_pc;

reg  [1:0] ret_kind;
reg [31:0] br_base, br_tgt;
reg        br_long;

reg [15:0] mm_mask;
reg        mm_dir;             // 1 = mem to reg
reg        mm_predec, mm_postinc;
reg  [1:0] mm_size;
reg [31:0] mm_addr, mm_init_an;
reg  [3:0] mm_reg;

reg  [2:0] mp_cnt, mp_idx;     // byte counts: 2 for word, 4 for long
reg        mp_dir;             // 1 = reg to mem
reg [31:0] mp_addr, mp_val;

reg [31:0] t_a, t_b;
reg  [1:0] srop_kind;          // 0 OR, 1 AND, 2 EOR
reg        srop_sr;            // to SR (else CCR)

reg        mvc_dir;            // 1 = general to control
reg        fc_ovr_v;
reg  [2:0] fc_ovr;

reg  [2:0] m16_form;
reg  [2:0] m16_dst_rn;
reg [31:0] m16_src, m16_dst, m16_an;
reg  [1:0] m16_idx;
reg [31:0] m16buf [0:3];
reg        m16_rd_done;

reg  [7:0] rst_cnt;
reg        fault_r;
reg  [2:0] fc_r;

assign mem_fc    = fc_r;
assign nresetout = (state != S_RESET_HOLD);

//---------------------------------------------------------------------------
// decode helpers (combinational, from ir)
//---------------------------------------------------------------------------

wire [3:0] ir_hi     = ir[15:12];
wire [2:0] d_reg9    = ir[11:9];
wire [2:0] d_op8_6   = ir[8:6];
wire [2:0] d_mode    = ir[5:3];
wire [2:0] d_rn      = ir[2:0];

// MOVE sizes: 01=B 11=W 10=L
wire [1:0] move_size = (ir[13:12] == 2'b01) ? `AP040_SZ_B :
                       (ir[13:12] == 2'b11) ? `AP040_SZ_W : `AP040_SZ_L;
wire [1:0] std_size  = ir[7:6];   // 00=B 01=W 10=L

wire ea_is_imm     = (d_mode == 3'b111) && (d_rn == 3'b100);

function [31:0] sxw;
	input [15:0] v;
	begin sxw = {{16{v[15]}}, v}; end
endfunction

function [31:0] sxb;
	input [7:0] v;
	begin sxb = {{24{v[7]}}, v}; end
endfunction

function [31:0] merge_sz;
	input [31:0] old;
	input [31:0] v;
	input [1:0] size;
	begin
		case (size)
			`AP040_SZ_B: merge_sz = {old[31:8],  v[7:0]};
			`AP040_SZ_W: merge_sz = {old[31:16], v[15:0]};
			default:     merge_sz = v;
		endcase
	end
endfunction

function [31:0] an_adj;
	input [2:0] regn;
	input [1:0] size;
	begin
		if (size == `AP040_SZ_B && regn == 3'd7) an_adj = 32'd2;
		else an_adj = {29'd0, (size == `AP040_SZ_B) ? 3'd1 :
		                      (size == `AP040_SZ_W) ? 3'd2 : 3'd4};
	end
endfunction

function cond_true;
	input [3:0] cond;
	begin
		case (cond)
			4'h0: cond_true = 1;
			4'h1: cond_true = 0;
			4'h2: cond_true = !sr[0] && !sr[2];
			4'h3: cond_true =  sr[0] ||  sr[2];
			4'h4: cond_true = !sr[0];
			4'h5: cond_true =  sr[0];
			4'h6: cond_true = !sr[2];
			4'h7: cond_true =  sr[2];
			4'h8: cond_true = !sr[1];
			4'h9: cond_true =  sr[1];
			4'hA: cond_true = !sr[3];
			4'hB: cond_true =  sr[3];
			4'hC: cond_true =  sr[3] ==  sr[1];
			4'hD: cond_true =  sr[3] !=  sr[1];
			4'hE: cond_true = !sr[2] && (sr[3] == sr[1]);
			default: cond_true = sr[2] || (sr[3] != sr[1]);
		endcase
	end
endfunction

function [3:0] ffs16;
	input [15:0] m;
	integer k;
	begin
		ffs16 = 4'd0;
		for (k = 15; k >= 0; k = k - 1)
			if (m[k]) ffs16 = k[3:0];
	end
endfunction

// MOVEC control register read mux
function [31:0] movec_rd;
	input [11:0] code;
	begin
		case (code)
			12'h000: movec_rd = {29'd0, sfc};
			12'h001: movec_rd = {29'd0, dfc};
			12'h002: movec_rd = cacr;
			12'h003: movec_rd = tc;
			12'h004: movec_rd = itt0;
			12'h005: movec_rd = itt1;
			12'h006: movec_rd = dtt0;
			12'h007: movec_rd = dtt1;
			12'h800: movec_rd = usp_q;
			12'h801: movec_rd = vbr;
			12'h803: movec_rd = msp_q;
			12'h804: movec_rd = isp_q;
			12'h805: movec_rd = mmusr;
			12'h806: movec_rd = urp;
			12'h807: movec_rd = srp;
			default: movec_rd = 32'd0;
		endcase
	end
endfunction

function movec_valid;
	input [11:0] code;
	begin
		case (code)
			12'h000, 12'h001, 12'h002, 12'h003, 12'h004, 12'h005, 12'h006,
			12'h007, 12'h800, 12'h801, 12'h803, 12'h804, 12'h805, 12'h806,
			12'h807: movec_valid = 1;
			default: movec_valid = 0;
		endcase
	end
endfunction

//---------------------------------------------------------------------------
// micro operation tasks (all nonblocking assignments)
//---------------------------------------------------------------------------

task issue_ifetch;
	input [31:0] a;
	begin
		mem_req <= 1; mem_write <= 0; mem_instr <= 1;
		mem_size <= `AP040_SZ_W; mem_addr <= a;
		fc_r <= sr_s ? `AP040_FC_SUPER_PROG : `AP040_FC_USER_PROG;
	end
endtask

task rfw;
	input [3:0] a;
	input [31:0] d;
	begin
		rf_we <= 1; rf_waddr <= a; rf_wdata <= d;
	end
endtask

task immf;
	input [1:0] n;
	input [6:0] ret;
	begin
		imm_n <= n; imm <= 0; if_issued <= 0;
		r_imm_ret <= ret; state <= S_IMMF;
	end
endtask

task mrd;
	input [31:0] a;
	input [1:0] size;
	input [6:0] ret;
	begin
		m_addr_r <= a; m_size <= size; m_wr <= 0; m_issued <= 0;
		r_m_ret <= ret; state <= S_MRD;
	end
endtask

task mwr;
	input [31:0] a;
	input [1:0] size;
	input [31:0] d;
	input [6:0] ret;
	begin
		m_addr_r <= a; m_size <= size; m_wdat <= d; m_wr <= 1; m_issued <= 0;
		r_m_ret <= ret; state <= S_MWR;
	end
endtask

task ea_start;
	input [2:0] mode;
	input [2:0] rn;
	input [1:0] size;
	input [6:0] ret;
	begin
		ea_mode <= mode; ea_rn <= rn; ea_size <= size;
		ea_pcmode <= 0; ea_pcb <= pc;
		r_ea_ret <= ret; state <= S_EA_DISP;
	end
endtask

task exc;
	input [7:0] vec;
	input [3:0] fmt;
	input [31:0] spc;
	input [31:0] addr;
	begin
		exc_vec <= vec; exc_fmt <= fmt; exc_spc <= spc; exc_addr <= addr;
		exc_is_irq <= 0; exc_pass2 <= 0;
		mem_req <= 0;
		state <= S_EXC0;
	end
endtask

task fetch_next;
	begin
		fc_ovr_v <= 0;
		if (irq_pend) begin
			exc_vec <= `AP040_VEC_AUTOVEC + {5'd0, irq_lvl};
			exc_fmt <= 0; exc_spc <= pc; exc_addr <= 0;
			exc_is_irq <= 1; exc_pass2 <= 0;
			irq_lvl_l <= irq_lvl;
			state <= S_EXC0;
		end
		else begin
			issue_ifetch(pc);
			pc_i <= pc;
			state <= S_FETCH;
		end
	end
endtask

task go_illegal;
	begin
		exc(`AP040_VEC_ILLEGAL, 4'd0, pc_i, 32'd0);
	end
endtask

task go_priv;
	begin
		exc(`AP040_VEC_PRIV, 4'd0, pc_i, 32'd0);
	end
endtask

// jump to a control flow target with odd address check
task go_pc;
	input [31:0] t;
	begin
		if (t[0]) exc(`AP040_VEC_ADDRERR, 4'd2, pc_i, t);
		else begin
			pc <= t;
			fc_ovr_v <= 0;
			if (irq_pend) begin
				exc_vec <= `AP040_VEC_AUTOVEC + {5'd0, irq_lvl};
				exc_fmt <= 0; exc_spc <= t; exc_addr <= 0;
				exc_is_irq <= 1; exc_pass2 <= 0;
				irq_lvl_l <= irq_lvl;
				state <= S_EXC0;
			end
			else begin
				issue_ifetch(t);
				pc_i <= t;
				state <= S_FETCH;
			end
		end
	end
endtask

task pipe_go;
	begin
		state <= S_PIPE_START;
	end
endtask

//---------------------------------------------------------------------------
// main state machine
//---------------------------------------------------------------------------

integer li;

always @(posedge clk) begin
	if (!nreset) begin
		state <= S_START;
		pc <= 0; pc_i <= 0;
		sr <= `AP040_SR_RESET;
		vbr <= 0; cacr <= 0;
		sfc <= 0; dfc <= 0; tc <= 0;
		itt0 <= 0; itt1 <= 0; dtt0 <= 0; dtt1 <= 0;
		mmusr <= 0; urp <= 0; srp <= 0;
		ir <= 0;
		mem_req <= 0; mem_write <= 0; mem_instr <= 0;
		mem_size <= `AP040_SZ_W; mem_addr <= 0; mem_wdata <= 0;
		fc_r <= `AP040_FC_SUPER_DATA;
		rf_we <= 0; rf_waddr <= 0; rf_wdata <= 0;
		rr_a <= 0; rr_b <= 0;
		aux_we <= 0; aux_sel <= 0; aux_wdata <= 0;
		md_start <= 0; md_isdiv <= 0; md_sign <= 0;
		md_a <= 0; md_hi <= 0; md_lo <= 0;
		alu_op <= 0; op_size <= 0;
		src_val <= 0; dst_val <= 0; dst_addr <= 0;
		sh_val <= 0; sh_fl <= 0; sh_cnt <= 0; sh_vacc <= 0; sh_rox <= 0;
		sh_any <= 0;
		r_imm_ret <= 0; r_ea_ret <= 0; r_m_ret <= 0;
		imm_n <= 0; if_issued <= 0; m_issued <= 0; imm <= 0; x_ext <= 0;
		m_wr <= 0; m_size <= 0; m_addr_r <= 0; m_wdat <= 0; m_val <= 0;
		ea_mode <= 0; ea_rn <= 0; ea_size <= 0;
		ea_pcmode <= 0; ea_pcb <= 0; extw <= 0;
		ea_base_v <= 0; ea_idx_v <= 0; ea_mind <= 0;
		ea_post <= 0; ea_odl <= 0; ea_absl <= 0; ea_addr <= 0;
		p_src <= 0; p_dst <= 0; p_sreg <= 0; p_dreg <= 0;
		p_ssize <= 0; p_dsize <= 0;
		p_rmw <= 0; p_wbsup <= 0; p_flags <= 0; p_sextw <= 0;
		p_dst_mem_bit <= 0;
		exec_kind <= EK_ALU;
		src_mode_r <= 0; src_rn_r <= 0; dst_mode_r <= 0; dst_rn_r <= 0;
		exc_vec <= 0; exc_fmt <= 0; exc_spc <= 0; exc_addr <= 0; exc_sp <= 0;
		exc_is_irq <= 0; exc_pass2 <= 0; sr_saved <= 0; irq_lvl_l <= 0;
		rte_sr <= 0; rte_pc <= 0; ret_kind <= 0;
		br_base <= 0; br_tgt <= 0; br_long <= 0;
		mm_mask <= 0; mm_dir <= 0; mm_predec <= 0; mm_postinc <= 0;
		mm_size <= 0; mm_addr <= 0; mm_init_an <= 0; mm_reg <= 0;
		mp_cnt <= 0; mp_idx <= 0; mp_dir <= 0; mp_addr <= 0; mp_val <= 0;
		t_a <= 0; t_b <= 0; srop_kind <= 0; srop_sr <= 0;
		mvc_dir <= 0; fc_ovr_v <= 0; fc_ovr <= 0;
		m16_form <= 0; m16_dst_rn <= 0; m16_src <= 0; m16_dst <= 0;
		m16_an <= 0; m16_idx <= 0; m16_rd_done <= 0;
		for (li = 0; li < 4; li = li + 1) m16buf[li] <= 0;
		rst_cnt <= 0;
		fault_r <= 0;
		nmi_arm <= 0;
	end
	else if (ce) begin
		rf_we <= 0;
		aux_we <= 0;
		md_start <= 0;
		if (mem_ack) mem_req <= 0;
		if (irq_lvl != 3'd7) nmi_arm <= 1;

		case (state)
			//------------------------------------------------------------ boot
			S_START: begin
				m_addr_r <= `AP040_VEC_RESET_ISP; m_size <= `AP040_SZ_L;
				m_wr <= 0; m_issued <= 0; r_m_ret <= S_BOOT0;
				state <= S_MRD;
			end

			S_BOOT0: begin
				rfw(4'd15, m_val);
				mrd(`AP040_VEC_RESET_PC, `AP040_SZ_L, S_BOOT1);
			end

			S_BOOT1: begin
				if (m_val[0]) begin fault_r <= 1; state <= S_HALT; end
				else begin
					pc <= m_val; pc_i <= m_val;
					issue_ifetch(m_val);
					state <= S_FETCH;
				end
			end

			//----------------------------------------------------------- fetch
			S_FETCH: if (mem_ack) begin
				ir <= mem_rdata[15:0];
				pc <= pc + 32'd2;
				// per-instruction defaults
				p_src <= SK_NONE; p_dst <= DK_NONE;
				p_rmw <= 0; p_wbsup <= 0; p_flags <= 1; p_sextw <= 0;
				p_dst_mem_bit <= 0;
				exec_kind <= EK_ALU;
				fc_ovr_v <= 0;
				state <= S_DECODE;
			end

			//------------------------------------------------- generic helpers
			S_NEXT: fetch_next;

			S_IMMF: begin
				if (!if_issued) begin
					issue_ifetch(pc);
					if_issued <= 1;
				end
				else if (mem_ack) begin
					imm <= {imm[15:0], mem_rdata[15:0]};
					pc <= pc + 32'd2;
					if_issued <= 0;
					if (imm_n == 2'd1) state <= r_imm_ret;
					else imm_n <= imm_n - 2'd1;
				end
			end

			S_MRD: begin
				if (!m_issued) begin
					mem_req <= 1; mem_write <= 0; mem_instr <= 0;
					mem_size <= m_size; mem_addr <= m_addr_r;
					fc_r <= fc_ovr_v ? fc_ovr :
					        (sr_s ? `AP040_FC_SUPER_DATA : `AP040_FC_USER_DATA);
					m_issued <= 1;
				end
				else if (mem_ack) begin
					m_val <= mem_rdata;
					state <= r_m_ret;
				end
			end

			S_MWR: begin
				if (!m_issued) begin
					mem_req <= 1; mem_write <= 1; mem_instr <= 0;
					mem_size <= m_size; mem_addr <= m_addr_r;
					mem_wdata <= m_wdat;
					fc_r <= fc_ovr_v ? fc_ovr :
					        (sr_s ? `AP040_FC_SUPER_DATA : `AP040_FC_USER_DATA);
					m_issued <= 1;
				end
				else if (mem_ack) begin
					state <= r_m_ret;
				end
			end

			//------------------------------------------------------- EA engine
			S_EA_DISP: begin
				case (ea_mode)
					3'b010, 3'b011, 3'b100: begin
						rr_a <= {1'b1, ea_rn};
						state <= S_EA_BASE;
					end
					3'b101: begin
						rr_a <= {1'b1, ea_rn};
						immf(2'd1, S_EA_D16);
					end
					3'b110: begin
						rr_a <= {1'b1, ea_rn};
						immf(2'd1, S_EA_EXTW);
					end
					default: begin // 111
						case (ea_rn)
							3'b000: begin ea_absl <= 0; immf(2'd1, S_EA_ABS); end
							3'b001: begin ea_absl <= 1; immf(2'd2, S_EA_ABS); end
							3'b010: begin ea_pcmode <= 1; immf(2'd1, S_EA_D16); end
							3'b011: begin ea_pcmode <= 1; immf(2'd1, S_EA_EXTW); end
							default: go_illegal;
						endcase
					end
				endcase
			end

			S_EA_BASE: begin
				case (ea_mode)
					3'b010: ea_addr <= rf_rdata_a;
					3'b011: begin
						ea_addr <= rf_rdata_a;
						rfw({1'b1, ea_rn}, rf_rdata_a + an_adj(ea_rn, ea_size));
					end
					default: begin // 100
						ea_addr <= rf_rdata_a - an_adj(ea_rn, ea_size);
						rfw({1'b1, ea_rn}, rf_rdata_a - an_adj(ea_rn, ea_size));
					end
				endcase
				state <= r_ea_ret;
			end

			S_EA_D16: begin
				ea_addr <= (ea_pcmode ? ea_pcb : rf_rdata_a) + sxw(imm[15:0]);
				state <= r_ea_ret;
			end

			S_EA_EXTW: begin
				extw <= imm[15:0];
				rr_b <= {imm[15], imm[14:12]};
				ea_base_v <= ea_pcmode ? ea_pcb : rf_rdata_a;
				state <= S_EA_EXTW2;
			end

			S_EA_EXTW2: begin : ea_extw2
				reg [31:0] idx;
				idx = extw[11] ? rf_rdata_b : sxw(rf_rdata_b[15:0]);
				idx = idx << extw[10:9];
				if (!extw[8]) begin
					ea_addr <= ea_base_v + idx + sxb(extw[7:0]);
					state <= r_ea_ret;
				end
				else if (extw[5:4] == 2'b00 || extw[3] ||
				         extw[2:0] == 3'b100 || (extw[6] && extw[2])) begin
					go_illegal;
				end
				else begin
					ea_base_v <= extw[7] ? 32'd0 : ea_base_v;
					ea_idx_v  <= extw[6] ? 32'd0 : idx;
					ea_post   <= extw[2];
					ea_odl    <= (extw[1:0] == 2'b11);
					if (extw[5:4] == 2'b01) begin
						imm <= 0;
						state <= S_EA_BD;
					end
					else immf((extw[5:4] == 2'b10) ? 2'd1 : 2'd2, S_EA_BD);
				end
			end

			S_EA_BD: begin : ea_bd
				reg [31:0] bd;
				bd = (extw[5:4] == 2'b01) ? 32'd0 :
				     (extw[5:4] == 2'b10) ? sxw(imm[15:0]) : imm;
				if (extw[2:0] == 3'b000) begin
					ea_addr <= ea_base_v + ea_idx_v + bd;
					state <= r_ea_ret;
				end
				else begin
					// memory indirect: pre-indexed adds the index before the
					// indirection, post-indexed after
					mrd(ea_base_v + bd + (ea_post ? 32'd0 : ea_idx_v),
					    `AP040_SZ_L, S_EA_MIND);
				end
			end

			S_EA_MIND: begin
				ea_mind <= m_val;
				case (extw[1:0])
					2'b01: begin
						ea_addr <= m_val + (ea_post ? ea_idx_v : 32'd0);
						state <= r_ea_ret;
					end
					2'b10: immf(2'd1, S_EA_OD);
					default: immf(2'd2, S_EA_OD);
				endcase
			end

			S_EA_OD: begin
				ea_addr <= ea_mind + (ea_post ? ea_idx_v : 32'd0) +
				           (ea_odl ? imm : sxw(imm[15:0]));
				state <= r_ea_ret;
			end

			S_EA_ABS: begin
				ea_addr <= ea_absl ? imm : sxw(imm[15:0]);
				state <= r_ea_ret;
			end

			//------------------------------------------------ operand pipeline
			S_PIPE_START: begin
				// x_ext keeps a decode-time immediate through EA fetches;
				// for long MUL/DIV it was already captured in S_MDL_EXT
				if (exec_kind != EK_MD_L) x_ext <= imm;
				case (p_src)
					SK_MEM: ea_start(src_mode_r, src_rn_r, p_ssize, S_PIPE_SRD);
					SK_REG: begin rr_a <= p_sreg; state <= S_PIPE_SREG; end
					SK_IMM: begin src_val <= imm; state <= S_PIPE_DST; end
					default: state <= S_PIPE_DST;
				endcase
			end

			S_PIPE_SRD:   mrd(ea_addr, p_ssize, S_PIPE_SDONE);
			S_PIPE_SDONE: begin src_val <= m_val; state <= S_PIPE_DST; end
			S_PIPE_SREG:  begin src_val <= rf_rdata_a; state <= S_PIPE_DST; end

			S_PIPE_DST: begin
				case (p_dst)
					DK_MEM: ea_start(dst_mode_r, dst_rn_r, p_dsize, S_PIPE_DEA);
					DK_REG: begin rr_b <= p_dreg; state <= S_PIPE_DREG; end
					default: state <= S_EXEC;
				endcase
			end

			S_PIPE_DEA: begin
				dst_addr <= ea_addr;
				if (p_rmw) mrd(ea_addr, p_dsize, S_PIPE_DDONE);
				else state <= S_EXEC;
			end

			S_PIPE_DDONE: begin dst_val <= m_val; state <= S_EXEC; end
			S_PIPE_DREG:  begin dst_val <= rf_rdata_b; state <= S_EXEC; end

			//-------------------------------------------------------- execute
			S_EXEC: begin
				case (exec_kind)
					EK_SHIFT: begin
						sh_val <= dst_val;
						sh_fl <= sr[4:0];
						sh_vacc <= 0;
						sh_any <= 0;
						sh_cnt <= (p_src == SK_NONE) ? 6'd1 : src_val[5:0];
						state <= S_SHIFT;
					end

					EK_MD_W: begin
						if (md_isdiv && src_val[15:0] == 16'd0)
							exc(`AP040_VEC_DIVZERO, 4'd2, pc, pc_i);
						else begin
							md_a  <= md_sign ? sxw(src_val[15:0]) : {16'd0, src_val[15:0]};
							md_hi <= md_sign ? {32{dst_val[31]}} : 32'd0;
							md_lo <= md_isdiv ? dst_val
							         : (md_sign ? sxw(dst_val[15:0]) : {16'd0, dst_val[15:0]});
							md_start <= 1;
							state <= S_MD_WAIT;
						end
					end

					EK_MD_L: begin
						// stage the read of Dl/Dq named in the extension word
						md_sign <= x_ext[11];
						rr_b <= {1'b0, x_ext[14:12]};
						state <= S_MDL_RDQ;
					end

					EK_CHK: begin : ek_chk
						reg signed [31:0] v, bound;
						v = (op_size == `AP040_SZ_W) ? $signed(sxw(dst_val[15:0]))
						                             : $signed(dst_val);
						bound = (op_size == `AP040_SZ_W) ? $signed(sxw(src_val[15:0]))
						                                 : $signed(src_val);
						if (v < 0) begin
							sr[3] <= 1;
							exc(`AP040_VEC_CHK, 4'd2, pc, pc_i);
						end
						else if (v > bound) begin
							sr[3] <= 0;
							exc(`AP040_VEC_CHK, 4'd2, pc, pc_i);
						end
						else fetch_next;
					end

					EK_SCC: begin : ek_scc
						reg [31:0] r;
						r = {24'd0, {8{cond_true(ir[11:8])}}};
						if (p_dst == DK_REG) begin
							rfw(p_dreg, merge_sz(dst_val, r, `AP040_SZ_B));
							fetch_next;
						end
						else mwr(dst_addr, `AP040_SZ_B, r, S_NEXT);
					end

					EK_PACK: begin : ek_pack
						reg [15:0] v;
						v = src_val[15:0] + x_ext[15:0];
						if (p_dst == DK_REG) begin
							rfw(p_dreg, merge_sz(dst_val, {24'd0, v[11:8], v[3:0]}, `AP040_SZ_B));
							fetch_next;
						end
						else mwr(dst_addr, `AP040_SZ_B, {24'd0, v[11:8], v[3:0]}, S_NEXT);
					end

					EK_UNPK: begin : ek_unpk
						reg [15:0] v;
						v = {4'd0, src_val[7:4], 4'd0, src_val[3:0]} + x_ext[15:0];
						if (p_dst == DK_REG) begin
							rfw(p_dreg, merge_sz(dst_val, {16'd0, v}, `AP040_SZ_W));
							fetch_next;
						end
						else mwr(dst_addr, `AP040_SZ_W, {16'd0, v}, S_NEXT);
					end

					default: begin // EK_ALU
						if (p_flags) sr[4:0] <= alu_fl;
						if (p_wbsup) fetch_next;
						else case (p_dst)
							DK_MEM: mwr(dst_addr, p_dsize, alu_res, S_NEXT);
							DK_REG: begin
								if (p_dreg[3])
									rfw(p_dreg, alu_res);
								else
									rfw(p_dreg, merge_sz(dst_val, alu_res, op_size));
								fetch_next;
							end
							DK_SR:  begin sr <= alu_res[15:0] & `AP040_SR_MASK; fetch_next; end
							DK_CCR: begin sr[4:0] <= alu_res[4:0]; fetch_next; end
							default: fetch_next;
						endcase
					end
				endcase
			end

			//--------------------------------------------------------- shifts
			S_SHIFT: begin
				if (sh_cnt == 6'd0) begin
					sr[4] <= sh_fl[4];
					sr[3] <= (op_size == `AP040_SZ_B) ? sh_val[7] :
					         (op_size == `AP040_SZ_W) ? sh_val[15] : sh_val[31];
					sr[2] <= ((sh_val & ((op_size == `AP040_SZ_B) ? 32'hFF :
					          (op_size == `AP040_SZ_W) ? 32'hFFFF : 32'hFFFFFFFF)) == 0);
					sr[1] <= sh_vacc;
					// zero count: C=0 for shifts/rotates, C=X for ROXx
					sr[0] <= sh_any ? sh_fl[0] : (sh_rox ? sh_fl[4] : 1'b0);
					state <= S_SHIFT_WB;
				end
				else begin
					sh_val <= alu_res;
					sh_fl <= alu_fl;
					sh_vacc <= sh_vacc | alu_fl[1];
					sh_any <= 1;
					sh_cnt <= sh_cnt - 6'd1;
				end
			end

			S_SHIFT_WB: begin
				if (p_dst == DK_REG) begin
					rfw(p_dreg, merge_sz(dst_val, sh_val, op_size));
					fetch_next;
				end
				else mwr(dst_addr, p_dsize, sh_val, S_NEXT);
			end

			//------------------------------------------------ multiply/divide
			S_MDL_EXT: begin
				x_ext <= imm;
				if (p_src == SK_IMM) immf(2'd2, S_PIPE_START);
				else state <= S_PIPE_START;
			end

			S_MDL_RDQ: begin
				// rf_rdata_b is Dl (multiply) or Dq (divide low dividend)
				if (md_isdiv && src_val == 32'd0)
					exc(`AP040_VEC_DIVZERO, 4'd2, pc, pc_i);
				else if (md_isdiv && x_ext[10]) begin
					dst_val <= rf_rdata_b;
					rr_a <= {1'b0, x_ext[2:0]};   // Dr holds the high dividend
					state <= S_MDL_RDR;
				end
				else begin
					md_a  <= src_val;
					md_hi <= md_isdiv ? (x_ext[11] ? {32{rf_rdata_b[31]}} : 32'd0) : 32'd0;
					md_lo <= rf_rdata_b;
					md_start <= 1;
					state <= S_MD_WAIT;
				end
			end

			S_MDL_RDR: begin
				md_a  <= src_val;
				md_hi <= rf_rdata_a;
				md_lo <= dst_val;
				md_start <= 1;
				state <= S_MD_WAIT;
			end

			S_MD_WAIT: if (md_done) begin
				if (exec_kind == EK_MD_W) begin
					if (md_isdiv) begin : mdw_div
						reg ovf_w;
						ovf_w = md_ovf |
						        (md_sign ? (($signed(md_rlo) > 32'sd32767) ||
						                    ($signed(md_rlo) < -32'sd32768))
						                 : (md_rlo > 32'h0000_FFFF));
						if (ovf_w) begin
							sr[1] <= 1; sr[0] <= 0;
							fetch_next;
						end
						else begin
							rfw(p_dreg, {md_rhi[15:0], md_rlo[15:0]});
							sr[3] <= md_rlo[15];
							sr[2] <= (md_rlo[15:0] == 16'd0);
							sr[1] <= 0; sr[0] <= 0;
							fetch_next;
						end
					end
					else begin
						rfw(p_dreg, md_rlo);
						sr[3] <= md_rlo[31];
						sr[2] <= (md_rlo == 32'd0);
						sr[1] <= 0; sr[0] <= 0;
						fetch_next;
					end
				end
				else begin // EK_MD_L
					if (md_isdiv) begin
						if (md_ovf && x_ext[10]) begin
							sr[1] <= 1; sr[0] <= 0;
							fetch_next;
						end
						else begin
							rfw({1'b0, x_ext[14:12]}, md_rlo);  // quotient to Dq
							sr[3] <= md_rlo[31];
							sr[2] <= (md_rlo == 32'd0);
							sr[1] <= (x_ext[10] ? 1'b0 : md_ovf);
							sr[0] <= 0;
							if (x_ext[2:0] != x_ext[14:12]) state <= S_MD_WB2;
							else fetch_next;
						end
					end
					else begin
						rfw({1'b0, x_ext[14:12]}, md_rlo);  // low product to Dl
						if (x_ext[10]) begin
							sr[3] <= md_rhi[31];
							sr[2] <= (md_rhi == 32'd0) && (md_rlo == 32'd0);
							sr[1] <= 0; sr[0] <= 0;
							state <= S_MD_WB2;
						end
						else begin
							sr[3] <= md_rlo[31];
							sr[2] <= (md_rlo == 32'd0);
							sr[1] <= (x_ext[11] ? (md_rhi != {32{md_rlo[31]}})
							                    : (md_rhi != 32'd0));
							sr[0] <= 0;
							fetch_next;
						end
					end
				end
			end

			S_MD_WB2: begin
				rfw({1'b0, x_ext[2:0]}, md_rhi);   // remainder to Dr / high to Dh
				fetch_next;
			end

			//------------------------------------------------------ exceptions
			S_EXC0: begin
				sr_saved <= sr;
				sr[13] <= 1;
				sr[15:14] <= 2'b00;
				if (exc_is_irq) begin
					sr[10:8] <= irq_lvl_l;
					if (irq_lvl_l == 3'd7) nmi_arm <= 0;
				end
				state <= S_EXC1;
			end

			S_EXC1: begin
				exc_sp <= dbg_a7 - ((exc_fmt == 4'd2) ? 32'd12 : 32'd8);
				mwr(dbg_a7 - ((exc_fmt == 4'd2) ? 32'd12 : 32'd8),
				    `AP040_SZ_W, {16'd0, sr_saved}, S_EXC2);
			end

			S_EXC2: mwr(exc_sp + 32'd2, `AP040_SZ_L, exc_spc, S_EXC3);

			S_EXC3: mwr(exc_sp + 32'd6, `AP040_SZ_W,
			            {16'd0, exc_fmt, 2'b00, exc_vec, 2'b00},
			            (exc_fmt == 4'd2) ? S_EXC4 : S_EXC5);

			S_EXC4: mwr(exc_sp + 32'd8, `AP040_SZ_L, exc_addr, S_EXC5);

			S_EXC5: begin
				// this A7 write commits on the next ce edge, while SR.M is
				// still set for the master stack case
				rfw(4'd15, exc_sp);
				if (exc_is_irq && sr[12] && !exc_pass2) state <= S_EXC6;
				else state <= S_EXC_VEC;
			end

			S_EXC6: begin
				// interrupt with M set: clear M and build a format $1
				// throwaway frame on the interrupt stack. The SR copy in
				// the throwaway keeps M set so that RTE's format $1
				// continuation switches back to the master stack where
				// the real frame lives.
				sr[12] <= 0;
				sr_saved <= sr;
				exc_fmt <= 4'd1;
				exc_pass2 <= 1;
				state <= S_EXC1;
			end

			S_EXC_VEC: mrd(vbr + {22'd0, exc_vec, 2'b00}, `AP040_SZ_L, S_EXC_JMP);

			S_EXC_JMP: begin
				if (m_val[0]) begin
					// odd handler address during exception processing:
					// treat as double fault and halt
					fault_r <= 1;
					state <= S_HALT;
				end
				else begin
					pc <= m_val;
					pc_i <= m_val;
					issue_ifetch(m_val);
					state <= S_FETCH;
				end
			end

			//------------------------------------------------------------- RTE
			S_RTE_SR:  mrd(dbg_a7, `AP040_SZ_W, S_RTE_PC);
			S_RTE_PC:  begin rte_sr <= m_val[15:0]; mrd(dbg_a7 + 32'd2, `AP040_SZ_L, S_RTE_FMT); end
			S_RTE_FMT: begin rte_pc <= m_val; mrd(dbg_a7 + 32'd6, `AP040_SZ_W, S_RTE_FIN); end

			S_RTE_FIN: begin
				case (m_val[15:12])
					4'd0, 4'd1: begin
						rfw(4'd15, dbg_a7 + 32'd8);
						ret_kind <= {1'b0, m_val[12]};  // reuse: bit0 = again
						state <= S_RTE_FIN2;
					end
					4'd2, 4'd3: begin
						rfw(4'd15, dbg_a7 + 32'd12);
						ret_kind <= 2'b00;
						state <= S_RTE_FIN2;
					end
					4'd4: begin
						rfw(4'd15, dbg_a7 + 32'd16);
						ret_kind <= 2'b00;
						state <= S_RTE_FIN2;
					end
					default: exc(`AP040_VEC_FMTERR, 4'd0, pc_i, 32'd0);
				endcase
			end

			S_RTE_FIN2: begin
				sr <= rte_sr & `AP040_SR_MASK;
				if (ret_kind[0]) state <= S_RTE_SR;   // format $1: continue
				else if (rte_pc[0]) exc(`AP040_VEC_ADDRERR, 4'd2, pc_i, rte_pc);
				else begin
					pc <= rte_pc;
					pc_i <= rte_pc;
					issue_ifetch(rte_pc);
					state <= S_FETCH;
				end
			end

			//------------------------------------------------ RTS / RTR / RTD
			S_RET1: begin
				if (ret_kind == RK_RTR) mrd(dbg_a7, `AP040_SZ_W, S_RET2);
				else mrd(dbg_a7, `AP040_SZ_L, S_RET2);
			end

			S_RET2: begin
				case (ret_kind)
					RK_RTR: begin
						sr[4:0] <= m_val[4:0];
						mrd(dbg_a7 + 32'd2, `AP040_SZ_L, S_RET3);
					end
					RK_RTD: begin
						rfw(4'd15, dbg_a7 + 32'd4 + sxw(imm[15:0]));
						go_pc(m_val);
					end
					default: begin
						rfw(4'd15, dbg_a7 + 32'd4);
						go_pc(m_val);
					end
				endcase
			end

			S_RET3: begin
				rfw(4'd15, dbg_a7 + 32'd6);
				go_pc(m_val);
			end

			//------------------------------------------------------- branches
			S_BCC_EXT: begin : bcc_ext
				reg [31:0] tgt;
				tgt = br_base + (br_long ? imm : sxw(imm[15:0]));
				if (ir[11:8] == 4'h1) begin
					br_tgt <= tgt;
					mwr(dbg_a7 - 32'd4, `AP040_SZ_L, pc, S_BSR_PUSH);
				end
				else if (cond_true(ir[11:8])) go_pc(tgt);
				else fetch_next;
			end

			S_BSR_PUSH: begin
				rfw(4'd15, dbg_a7 - 32'd4);
				go_pc(br_tgt);
			end

			S_DBCC1: begin
				if (cond_true(ir[11:8])) fetch_next;
				else begin
					rr_a <= {1'b0, d_rn};
					state <= S_DBCC2;
				end
			end

			S_DBCC2: begin : dbcc2
				reg [15:0] w;
				w = rf_rdata_a[15:0] - 16'd1;
				rfw({1'b0, d_rn}, {rf_rdata_a[31:16], w});
				if (w != 16'hFFFF) go_pc(br_base + sxw(imm[15:0]));
				else fetch_next;
			end

			//------------------------------------------- jumps and stack frame
			S_JMP1: go_pc(ea_addr);

			S_JSR1: begin
				br_tgt <= ea_addr;
				mwr(dbg_a7 - 32'd4, `AP040_SZ_L, pc, S_JSR2);
			end

			S_JSR2: begin
				rfw(4'd15, dbg_a7 - 32'd4);
				go_pc(br_tgt);
			end

			S_LEA1: begin
				rfw({1'b1, d_reg9}, ea_addr);
				fetch_next;
			end

			S_PEA1: mwr(dbg_a7 - 32'd4, `AP040_SZ_L, ea_addr, S_PEA2);

			S_PEA2: begin
				rfw(4'd15, dbg_a7 - 32'd4);
				fetch_next;
			end

			S_LINK1: begin
				rr_a <= {1'b1, d_rn};
				state <= S_LINK2;
			end

			S_LINK2: begin : link2
				reg [31:0] spn;
				spn = dbg_a7 - 32'd4;
				t_a <= spn;
				mwr(spn, `AP040_SZ_L, (d_rn == 3'd7) ? spn : rf_rdata_a, S_LINK3);
			end

			S_LINK3: begin
				rfw({1'b1, d_rn}, t_a);
				state <= S_LINK4;
			end

			S_LINK4: begin
				rfw(4'd15, t_a + (br_long ? imm : sxw(imm[15:0])));
				fetch_next;
			end

			S_UNLK1: begin
				t_a <= rf_rdata_a;
				mrd(rf_rdata_a, `AP040_SZ_L, S_UNLK2);
			end

			S_UNLK2: begin
				rfw(4'd15, t_a + 32'd4);
				state <= S_UNLK3;
			end

			S_UNLK3: begin
				rfw({1'b1, d_rn}, m_val);
				fetch_next;
			end

			//---------------------------------------------------------- MOVEM
			S_MOVEM_SET: begin
				mm_mask <= imm[15:0];
				if (mm_predec || mm_postinc) begin
					rr_a <= {1'b1, d_rn};
					state <= S_MOVEM_SET2;
				end
				else ea_start(d_mode, d_rn, mm_size, S_MOVEM_EA);
			end

			S_MOVEM_SET2: begin
				mm_addr <= rf_rdata_a;
				mm_init_an <= rf_rdata_a;
				state <= S_MOVEM_LOOP;
			end

			S_MOVEM_EA: begin
				mm_addr <= ea_addr;
				state <= S_MOVEM_LOOP;
			end

			S_MOVEM_LOOP: begin
				if (mm_mask == 16'd0) begin
					if (mm_predec || mm_postinc)
						rfw({1'b1, d_rn}, mm_addr);
					fetch_next;
				end
				else begin : movem_step
					reg [3:0] bit_i;
					bit_i = ffs16(mm_mask);
					mm_mask <= mm_mask & ~(16'd1 << bit_i);
					if (mm_predec) begin
						mm_reg <= 4'd15 - bit_i;
						mm_addr <= mm_addr - ((mm_size == `AP040_SZ_L) ? 32'd4 : 32'd2);
						rr_a <= 4'd15 - bit_i;
						state <= S_MOVEM_RD;
					end
					else begin
						mm_reg <= bit_i;
						if (mm_dir) mrd(mm_addr, mm_size, S_MOVEM_LD);
						else begin
							rr_a <= bit_i;
							state <= S_MOVEM_RD;
						end
					end
				end
			end

			S_MOVEM_RD: begin : movem_rd
				reg [31:0] v;
				v = (mm_predec && mm_reg == {1'b1, d_rn}) ? mm_init_an : rf_rdata_a;
				if (mm_predec) mwr(mm_addr, mm_size, v, S_MOVEM_LOOP);
				else begin
					mwr(mm_addr, mm_size, v, S_MOVEM_LOOP);
					mm_addr <= mm_addr + ((mm_size == `AP040_SZ_L) ? 32'd4 : 32'd2);
				end
			end

			S_MOVEM_LD: begin
				rfw(mm_reg, (mm_size == `AP040_SZ_W) ? sxw(m_val[15:0]) : m_val);
				mm_addr <= mm_addr + ((mm_size == `AP040_SZ_L) ? 32'd4 : 32'd2);
				state <= S_MOVEM_LOOP;
			end

			//---------------------------------------------------------- MOVEP
			S_MOVEP1: begin
				rr_a <= {1'b1, d_rn};
				rr_b <= {1'b0, d_reg9};
				state <= S_MOVEP2;
			end

			S_MOVEP2: begin
				mp_addr <= rf_rdata_a + sxw(imm[15:0]);
				mp_val <= rf_rdata_b;
				mp_idx <= 0;
				if (mp_dir) state <= S_MOVEP_WR;
				else state <= S_MOVEP_RD;
			end

			S_MOVEP_WR: begin
				if (mp_idx == mp_cnt) fetch_next;
				else begin : movep_wr
					reg [7:0] byv;
					case ({mp_cnt[2], mp_idx[1:0]})
						{1'b1, 2'd0}: byv = mp_val[31:24];
						{1'b1, 2'd1}: byv = mp_val[23:16];
						{1'b1, 2'd2}: byv = mp_val[15:8];
						{1'b1, 2'd3}: byv = mp_val[7:0];
						{1'b0, 2'd0}: byv = mp_val[15:8];
						default:      byv = mp_val[7:0];
					endcase
					mp_idx <= mp_idx + 3'd1;
					mwr(mp_addr + {28'd0, mp_idx[1:0], 1'b0}, `AP040_SZ_B,
					    {24'd0, byv}, S_MOVEP_WR);
				end
			end

			S_MOVEP_RD: begin
				if (mp_idx != 0) begin
					mp_val <= {mp_val[23:0], m_val[7:0]};
				end
				if (mp_idx == mp_cnt) begin : movep_fin
					reg [31:0] nv;
					nv = {mp_val[23:0], m_val[7:0]};
					if (mp_cnt[2]) rfw({1'b0, d_reg9}, nv);
					else rfw({1'b0, d_reg9}, {rf_rdata_b[31:16], nv[15:0]});
					fetch_next;
				end
				else begin
					mp_idx <= mp_idx + 3'd1;
					mrd(mp_addr + {28'd0, mp_idx[1:0], 1'b0}, `AP040_SZ_B, S_MOVEP_RD);
				end
			end

			//----------------------------------------------------- EXG / misc
			S_EXG1: begin
				t_a <= rf_rdata_a;
				rfw(rr_a, rf_rdata_b);
				state <= S_EXG2;
			end

			S_EXG2: begin
				rfw(rr_b, t_a);
				fetch_next;
			end

			S_USP1: begin
				aux_we <= 1; aux_sel <= 2'd0; aux_wdata <= rf_rdata_a;
				fetch_next;
			end

			//---------------------------------------------------------- MOVEC
			S_MOVEC1: begin
				if (!movec_valid(imm[11:0])) go_illegal;
				else if (mvc_dir) begin
					rr_a <= {imm[15], imm[14:12]};
					state <= S_MOVEC2;
				end
				else begin
					rfw({imm[15], imm[14:12]}, movec_rd(imm[11:0]));
					fetch_next;
				end
			end

			S_MOVEC2: begin
				case (imm[11:0])
					12'h000: sfc <= rf_rdata_a[2:0];
					12'h001: dfc <= rf_rdata_a[2:0];
					12'h002: cacr <= rf_rdata_a & 32'h8000_8000;
					12'h003: tc <= rf_rdata_a & 32'h0000_C000;
					12'h004: itt0 <= rf_rdata_a & 32'hFFFF_E364;
					12'h005: itt1 <= rf_rdata_a & 32'hFFFF_E364;
					12'h006: dtt0 <= rf_rdata_a & 32'hFFFF_E364;
					12'h007: dtt1 <= rf_rdata_a & 32'hFFFF_E364;
					12'h800: begin aux_we <= 1; aux_sel <= 2'd0; aux_wdata <= rf_rdata_a; end
					12'h801: vbr <= rf_rdata_a;
					12'h803: begin aux_we <= 1; aux_sel <= 2'd2; aux_wdata <= rf_rdata_a; end
					12'h804: begin aux_we <= 1; aux_sel <= 2'd1; aux_wdata <= rf_rdata_a; end
					12'h805: mmusr <= rf_rdata_a;
					12'h806: urp <= rf_rdata_a & 32'hFFFF_FE00;
					default: srp <= rf_rdata_a & 32'hFFFF_FE00;
				endcase
				fetch_next;
			end

			//---------------------------------------------------------- MOVES
			S_MOVES1: begin
				x_ext <= imm;
				ea_start(d_mode, d_rn, op_size, S_MOVES2);
			end

			S_MOVES2: begin
				if (x_ext[11]) begin
					rr_a <= {x_ext[15], x_ext[14:12]};
					state <= S_MOVES_WR;
				end
				else begin
					rr_b <= {x_ext[15], x_ext[14:12]};   // old value for merge
					fc_ovr_v <= 1; fc_ovr <= sfc;
					mrd(ea_addr, op_size, S_MOVES_RD);
				end
			end

			S_MOVES_WR: begin
				fc_ovr_v <= 1; fc_ovr <= dfc;
				mwr(ea_addr, op_size, rf_rdata_a, S_NEXT);
			end

			S_MOVES_RD: begin
				if (x_ext[15])
					rfw({x_ext[15], x_ext[14:12]},
					    (op_size == `AP040_SZ_W) ? sxw(m_val[15:0]) :
					    (op_size == `AP040_SZ_B) ? sxb(m_val[7:0]) : m_val);
				else
					rfw({x_ext[15], x_ext[14:12]},
					    merge_sz(rf_rdata_b, m_val, op_size));
				fetch_next;
			end

			//------------------------------------------------- PTEST / RESET
			S_PTEST1: begin
				// MMU disabled: transparent translation, resident
				mmusr <= (rf_rdata_a & 32'hFFFF_F000) | 32'h0000_0001;
				fetch_next;
			end

			S_RESET_HOLD: begin
				if (rst_cnt == 8'd0) fetch_next;
				else rst_cnt <= rst_cnt - 8'd1;
			end

			//--------------------------------------------------------- MOVE16
			S_M16_SRC: begin
				if (m16_form == 3'd4) m16_dst_rn <= imm[14:12];
				rr_a <= {1'b1, d_rn};
				state <= S_M16_DST;
			end

			S_M16_DST: begin
				m16_an <= rf_rdata_a;
				case (m16_form)
					3'd0, 3'd2: begin  // (An)[+] to abs
						m16_src <= rf_rdata_a & 32'hFFFF_FFF0;
						m16_dst <= imm & 32'hFFFF_FFF0;
					end
					3'd1, 3'd3: begin  // abs to (An)[+]
						m16_src <= imm & 32'hFFFF_FFF0;
						m16_dst <= rf_rdata_a & 32'hFFFF_FFF0;
					end
					default: begin     // (Ax)+ to (Ay)+
						m16_src <= rf_rdata_a & 32'hFFFF_FFF0;
						rr_b <= {1'b1, m16_dst_rn};
					end
				endcase
				state <= (m16_form == 3'd4) ? S_M16_DST2 : S_M16_RD;
				m16_idx <= 0;
				m16_rd_done <= 0;
			end

			S_M16_DST2: begin
				m16_dst <= rf_rdata_b & 32'hFFFF_FFF0;
				t_b <= rf_rdata_b;
				state <= S_M16_RD;
			end

			S_M16_RD: mrd(m16_src + {28'd0, m16_idx, 2'b00}, `AP040_SZ_L, S_M16_RD2);

			S_M16_RD2: begin
				m16buf[m16_idx] <= m_val;
				if (m16_idx == 2'd3) begin
					m16_idx <= 0;
					state <= S_M16_WR;
				end
				else begin
					m16_idx <= m16_idx + 2'd1;
					state <= S_M16_RD;
				end
			end

			S_M16_WR: mwr(m16_dst + {28'd0, m16_idx, 2'b00}, `AP040_SZ_L,
			              m16buf[m16_idx], S_M16_WR2);

			S_M16_WR2: begin
				if (m16_idx == 2'd3) state <= S_M16_INC;
				else begin
					m16_idx <= m16_idx + 2'd1;
					state <= S_M16_WR;
				end
			end

			S_M16_INC: begin
				case (m16_form)
					3'd0, 3'd1: begin  // (An)+ forms
						rfw({1'b1, d_rn}, m16_an + 32'd16);
						fetch_next;
					end
					3'd4: begin
						rfw({1'b1, d_rn}, m16_an + 32'd16);
						if (m16_dst_rn != d_rn) state <= S_M16_INC2;
						else fetch_next;
					end
					default: fetch_next;
				endcase
			end

			S_M16_INC2: begin
				rfw({1'b1, m16_dst_rn}, t_b + 32'd16);
				fetch_next;
			end

			//----------------------------------------- immediate to CCR / SR
			S_SROP: begin : srop
				reg [15:0] nv;
				case (srop_kind)
					2'd0: nv = sr | imm[15:0];
					2'd1: nv = sr & imm[15:0];
					default: nv = sr ^ imm[15:0];
				endcase
				if (srop_sr) sr <= nv & `AP040_SR_MASK;
				else sr[4:0] <= nv[4:0];
				fetch_next;
			end

			//---------------------------------------------------------- decode
			S_DECODE: begin
				case (ir_hi)
					//-------------------------------------------- 0x0: bit/imm
					4'h0: begin
						if (ir[8] && d_mode == 3'b001) begin
							// MOVEP
							mp_dir <= ir[7];
							mp_cnt <= ir[6] ? 3'd4 : 3'd2;
							immf(2'd1, S_MOVEP1);
						end
						else if (ir[8]) begin
							// dynamic bit op, bit number in Dn
							alu_op <= `AP040_ALU_BTST + {4'd0, ir[7:6]};
							p_src <= SK_REG; p_sreg <= {1'b0, d_reg9};
							if (d_mode == 3'b000) begin
								op_size <= `AP040_SZ_L;
								p_dsize <= `AP040_SZ_L;
								p_dst <= DK_REG; p_dreg <= {1'b0, d_rn};
							end
							else begin
								op_size <= `AP040_SZ_B;
								p_dsize <= `AP040_SZ_B;
								p_dst <= DK_MEM;
								p_dst_mem_bit <= 1;
								dst_mode_r <= d_mode; dst_rn_r <= d_rn;
								p_rmw <= 1;
							end
							if (ir[7:6] == 2'b00) p_wbsup <= 1; // BTST
							pipe_go;
						end
						else if (d_reg9 == 3'b100) begin
							// static bit op, bit number in extension word
							// (checked before the size=11 group: BSET is 00xx11)
							alu_op <= `AP040_ALU_BTST + {4'd0, ir[7:6]};
							p_src <= SK_IMM;
							if (d_mode == 3'b000) begin
								op_size <= `AP040_SZ_L;
								p_dsize <= `AP040_SZ_L;
								p_dst <= DK_REG; p_dreg <= {1'b0, d_rn};
							end
							else begin
								op_size <= `AP040_SZ_B;
								p_dsize <= `AP040_SZ_B;
								p_dst <= DK_MEM;
								p_dst_mem_bit <= 1;
								dst_mode_r <= d_mode; dst_rn_r <= d_rn;
								p_rmw <= 1;
							end
							if (ir[7:6] == 2'b00) p_wbsup <= 1;
							immf(2'd1, S_PIPE_START);
						end
						else if (d_reg9 == 3'b111 && std_size != 2'b11) begin
							// MOVES (0000 1110 11 is CAS.L, not implemented)
							if (!sr_s) go_priv;
							else if (d_mode < 3'b010 || ea_is_imm) go_illegal;
							else begin
								op_size <= std_size;
								immf(2'd1, S_MOVES1);
							end
						end
						else if (std_size == 2'b11) begin
							// CAS / CAS2 / CHK2 / CMP2: not implemented yet
							go_illegal;
						end
						else begin
							// ORI/ANDI/SUBI/ADDI/EORI/CMPI
							if (ea_is_imm && (d_reg9 == 3'b000 || d_reg9 == 3'b001 || d_reg9 == 3'b101)) begin
								// to CCR (byte) or SR (word, privileged)
								if (std_size == 2'b01 && !sr_s) go_priv;
								else if (std_size > 2'b01) go_illegal;
								else begin
									srop_kind <= (d_reg9 == 3'b000) ? 2'd0 :
									             (d_reg9 == 3'b001) ? 2'd1 : 2'd2;
									srop_sr <= (std_size == 2'b01);
									immf(2'd1, S_SROP);
								end
							end
							else if (d_mode == 3'b001) go_illegal;
							else begin
								case (d_reg9)
									3'b000: alu_op <= `AP040_ALU_OR;
									3'b001: alu_op <= `AP040_ALU_AND;
									3'b010: alu_op <= `AP040_ALU_SUB;
									3'b011: alu_op <= `AP040_ALU_ADD;
									3'b101: alu_op <= `AP040_ALU_EOR;
									default: alu_op <= `AP040_ALU_CMP;
								endcase
								if (d_reg9 == 3'b110) p_wbsup <= 1; // CMPI
								op_size <= std_size;
								p_ssize <= std_size; p_dsize <= std_size;
								p_src <= SK_IMM;
								if (d_mode == 3'b000) begin
									p_dst <= DK_REG; p_dreg <= {1'b0, d_rn};
								end
								else begin
									p_dst <= DK_MEM; p_rmw <= 1;
									dst_mode_r <= d_mode; dst_rn_r <= d_rn;
								end
								immf((std_size == `AP040_SZ_L) ? 2'd2 : 2'd1, S_PIPE_START);
							end
						end
					end

					//------------------------------------------- 0x1-0x3: MOVE
					4'h1, 4'h2, 4'h3: begin
						if (move_size == `AP040_SZ_B &&
						    (d_mode == 3'b001 || d_op8_6 == 3'b001)) go_illegal;
						else if (d_op8_6 == 3'b111 && d_reg9 > 3'b001) go_illegal;
						else begin
							alu_op <= `AP040_ALU_MOVE;
							op_size <= move_size;
							p_ssize <= move_size; p_dsize <= move_size;
							// source
							if (d_mode == 3'b000 || d_mode == 3'b001) begin
								p_src <= SK_REG; p_sreg <= {d_mode[0], d_rn};
							end
							else if (ea_is_imm) p_src <= SK_IMM;
							else begin
								p_src <= SK_MEM;
								src_mode_r <= d_mode; src_rn_r <= d_rn;
							end
							// destination
							if (d_op8_6 == 3'b000) begin
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
							end
							else if (d_op8_6 == 3'b001) begin
								// MOVEA: full register, no flags, word sexts
								p_dst <= DK_REG; p_dreg <= {1'b1, d_reg9};
								p_flags <= 0;
								if (move_size == `AP040_SZ_W) p_sextw <= 1;
								op_size <= `AP040_SZ_L;
							end
							else begin
								p_dst <= DK_MEM;
								dst_mode_r <= d_op8_6; dst_rn_r <= d_reg9;
							end
							if (ea_is_imm)
								immf((move_size == `AP040_SZ_L) ? 2'd2 : 2'd1, S_PIPE_START);
							else pipe_go;
						end
					end

					//------------------------------------------------ 0x4: misc
					4'h4: begin
						if (ir[11:0] == 12'hAFC) go_illegal;   // ILLEGAL
						else if (d_op8_6 == 3'b111) begin
							if (d_mode == 3'b000) begin
								if (d_reg9 == 3'b100) begin
									// EXTB.L
									alu_op <= `AP040_ALU_EXTB;
									op_size <= `AP040_SZ_L;
									p_dst <= DK_REG; p_dreg <= {1'b0, d_rn};
									pipe_go;
								end
								else go_illegal;
							end
							else if (d_mode == 3'b001 || (d_mode == 3'b011) ||
							         (d_mode == 3'b100) || ea_is_imm) go_illegal;
							else ea_start(d_mode, d_rn, `AP040_SZ_L, S_LEA1); // LEA
						end
						else if (d_op8_6 == 3'b110) begin
							// CHK.W
							exec_kind <= EK_CHK;
							op_size <= `AP040_SZ_W;
							p_ssize <= `AP040_SZ_W;
							if (d_mode == 3'b001) go_illegal;
							else begin
								if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; end
								else if (ea_is_imm) p_src <= SK_IMM;
								else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; end
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
								if (ea_is_imm) immf(2'd1, S_PIPE_START);
								else pipe_go;
							end
						end
						else if (d_op8_6 == 3'b100 &&
						         !(ir[11:9] == 3'b100 && d_mode == 3'b001)) begin
							// CHK.L (0100 ddd 100; 0100 100 000 001 rrr is LINK.L)
							exec_kind <= EK_CHK;
							op_size <= `AP040_SZ_L;
							p_ssize <= `AP040_SZ_L;
							if (d_mode == 3'b001) go_illegal;
							else begin
								if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; end
								else if (ea_is_imm) p_src <= SK_IMM;
								else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; end
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
								if (ea_is_imm) immf(2'd2, S_PIPE_START);
								else pipe_go;
							end
						end
						else case (ir[11:9])
							3'b000: begin
								if (d_op8_6 == 3'b011) begin
									// MOVE from SR (privileged on 68010+)
									if (!sr_s) go_priv;
									else begin
										p_src <= SK_IMPL; src_val <= {16'd0, sr};
										alu_op <= `AP040_ALU_MOVE;
										op_size <= `AP040_SZ_W;
										p_dsize <= `AP040_SZ_W;
										p_flags <= 0;
										if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
										else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
										else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
									end
								end
								else begin
									// NEGX
									alu_op <= `AP040_ALU_NEGX;
									op_size <= std_size;
									p_dsize <= std_size;
									p_rmw <= 1;
									if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
									else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
									else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
								end
							end

							3'b001: begin
								if (d_op8_6 == 3'b011) begin
									// MOVE from CCR
									p_src <= SK_IMPL; src_val <= {27'd0, sr[4:0]};
									alu_op <= `AP040_ALU_MOVE;
									op_size <= `AP040_SZ_W;
									p_dsize <= `AP040_SZ_W;
									p_flags <= 0;
									if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
									else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
									else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
								end
								else begin
									// CLR (pure write on 68040)
									alu_op <= `AP040_ALU_CLR;
									op_size <= std_size;
									p_dsize <= std_size;
									if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
									else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
									else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
								end
							end

							3'b010: begin
								if (d_op8_6 == 3'b011) begin
									// MOVE to CCR
									alu_op <= `AP040_ALU_MOVE;
									op_size <= `AP040_SZ_W;
									p_ssize <= `AP040_SZ_W;
									p_flags <= 0;
									p_dst <= DK_CCR;
									if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; pipe_go; end
									else if (d_mode == 3'b001) go_illegal;
									else if (ea_is_imm) begin p_src <= SK_IMM; immf(2'd1, S_PIPE_START); end
									else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
								end
								else begin
									// NEG
									alu_op <= `AP040_ALU_NEG;
									op_size <= std_size;
									p_dsize <= std_size;
									p_rmw <= 1;
									if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
									else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
									else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
								end
							end

							3'b011: begin
								if (d_op8_6 == 3'b011) begin
									// MOVE to SR (privileged)
									if (!sr_s) go_priv;
									else begin
										alu_op <= `AP040_ALU_MOVE;
										op_size <= `AP040_SZ_W;
										p_ssize <= `AP040_SZ_W;
										p_flags <= 0;
										p_dst <= DK_SR;
										if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; pipe_go; end
										else if (d_mode == 3'b001) go_illegal;
										else if (ea_is_imm) begin p_src <= SK_IMM; immf(2'd1, S_PIPE_START); end
										else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
									end
								end
								else begin
									// NOT
									alu_op <= `AP040_ALU_NOT;
									op_size <= std_size;
									p_dsize <= std_size;
									p_rmw <= 1;
									if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
									else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
									else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
								end
							end

							3'b100: case (d_op8_6[1:0])
								2'b00: begin
									if (d_mode == 3'b001) begin
										// LINK.L An,#bd32
										br_long <= 1;
										immf(2'd2, S_LINK1);
									end
									else begin
										// NBCD
										alu_op <= `AP040_ALU_NBCD;
										op_size <= `AP040_SZ_B;
										p_dsize <= `AP040_SZ_B;
										p_rmw <= 1;
										if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
										else if (ea_is_imm) go_illegal;
										else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
									end
								end
								2'b01: begin
									if (d_mode == 3'b000) begin
										// SWAP
										alu_op <= `AP040_ALU_SWAP;
										op_size <= `AP040_SZ_L;
										p_dst <= DK_REG; p_dreg <= {1'b0, d_rn};
										pipe_go;
									end
									else if (d_mode == 3'b001) go_illegal; // BKPT
									else if (d_mode == 3'b011 || d_mode == 3'b100 || ea_is_imm) go_illegal;
									else ea_start(d_mode, d_rn, `AP040_SZ_L, S_PEA1); // PEA
								end
								default: begin
									if (d_mode == 3'b000) begin
										// EXT.W / EXT.L
										alu_op <= `AP040_ALU_EXT;
										op_size <= d_op8_6[0] ? `AP040_SZ_L : `AP040_SZ_W;
										p_dst <= DK_REG; p_dreg <= {1'b0, d_rn};
										pipe_go;
									end
									else begin
										// MOVEM registers to memory
										mm_dir <= 0;
										mm_size <= d_op8_6[0] ? `AP040_SZ_L : `AP040_SZ_W;
										mm_predec <= (d_mode == 3'b100);
										mm_postinc <= 0;
										if (d_mode == 3'b011 || d_mode < 3'b010 || ea_is_imm ||
										    (d_mode == 3'b111 && d_rn > 3'b001)) go_illegal;
										else immf(2'd1, S_MOVEM_SET);
									end
								end
							endcase

							3'b101: begin
								if (d_op8_6 == 3'b011) begin
									// TAS (not bus locked yet)
									alu_op <= `AP040_ALU_TAS;
									op_size <= `AP040_SZ_B;
									p_dsize <= `AP040_SZ_B;
									p_rmw <= 1;
									if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
									else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
									else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
								end
								else begin
									// TST (An/imm/PC modes allowed on 020+)
									alu_op <= `AP040_ALU_TST;
									op_size <= std_size;
									p_ssize <= std_size;
									p_wbsup <= 1;
									if (d_mode == 3'b000 || d_mode == 3'b001) begin
										if (d_mode == 3'b001 && std_size == `AP040_SZ_B) go_illegal;
										else begin
											p_src <= SK_REG; p_sreg <= {d_mode[0], d_rn};
											pipe_go;
										end
									end
									else if (ea_is_imm) begin
										p_src <= SK_IMM;
										immf((std_size == `AP040_SZ_L) ? 2'd2 : 2'd1, S_PIPE_START);
									end
									else begin
										p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn;
										pipe_go;
									end
								end
							end

							3'b110: begin
								if (!d_op8_6[1]) begin
									// MULx.L / DIVx.L with extension word
									exec_kind <= EK_MD_L;
									md_isdiv <= d_op8_6[0];
									op_size <= `AP040_SZ_L;
									p_ssize <= `AP040_SZ_L;
									if (d_mode == 3'b001) go_illegal;
									else begin
										if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; end
										else if (ea_is_imm) p_src <= SK_IMM;
										else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; end
										// extension word first, then any immediate
										immf(2'd1, S_MDL_EXT);
									end
								end
								else begin
									// MOVEM memory to registers
									mm_dir <= 1;
									mm_size <= d_op8_6[0] ? `AP040_SZ_L : `AP040_SZ_W;
									mm_predec <= 0;
									mm_postinc <= (d_mode == 3'b011);
									if (d_mode == 3'b100 || d_mode < 3'b010 || ea_is_imm) go_illegal;
									else immf(2'd1, S_MOVEM_SET);
								end
							end

							default: begin // 3'b111
								if (d_op8_6 == 3'b010) begin
									// JSR
									if (d_mode < 3'b010 || d_mode == 3'b011 ||
									    d_mode == 3'b100 || ea_is_imm) go_illegal;
									else ea_start(d_mode, d_rn, `AP040_SZ_L, S_JSR1);
								end
								else if (d_op8_6 == 3'b011) begin
									// JMP
									if (d_mode < 3'b010 || d_mode == 3'b011 ||
									    d_mode == 3'b100 || ea_is_imm) go_illegal;
									else ea_start(d_mode, d_rn, `AP040_SZ_L, S_JMP1);
								end
								else if (d_op8_6 == 3'b001) begin
									casez (ir[5:0])
										6'b00????: exc(`AP040_VEC_TRAP + {4'd0, ir[3:0]}, 4'd0, pc, 32'd0);
										6'b010???: begin br_long <= 0; immf(2'd1, S_LINK1); end // LINK.W
										6'b011???: begin rr_a <= {1'b1, d_rn}; state <= S_UNLK1; end
										6'b100???: begin // MOVE An,USP
											if (!sr_s) go_priv;
											else begin rr_a <= {1'b1, d_rn}; state <= S_USP1; end
										end
										6'b101???: begin // MOVE USP,An
											if (!sr_s) go_priv;
											else begin rfw({1'b1, d_rn}, usp_q); fetch_next; end
										end
										6'b110000: begin // RESET
											if (!sr_s) go_priv;
											else begin rst_cnt <= 8'd127; state <= S_RESET_HOLD; end
										end
										6'b110001: fetch_next;   // NOP
										6'b110010: begin // STOP
											if (!sr_s) go_priv;
											else immf(2'd1, S_STOP_LD);
										end
										6'b110011: begin // RTE
											if (!sr_s) go_priv;
											else state <= S_RTE_SR;
										end
										6'b110100: begin ret_kind <= RK_RTD; immf(2'd1, S_RET1); end
										6'b110101: begin ret_kind <= RK_RTS; state <= S_RET1; end
										6'b110110: begin // TRAPV
											if (sr[1]) exc(`AP040_VEC_TRAPCC, 4'd2, pc, pc_i);
											else fetch_next;
										end
										6'b110111: begin ret_kind <= RK_RTR; state <= S_RET1; end
										6'b111010, 6'b111011: begin // MOVEC
											if (!sr_s) go_priv;
											else begin
												mvc_dir <= ir[0];
												immf(2'd1, S_MOVEC1);
											end
										end
										default: go_illegal;
									endcase
								end
								else go_illegal;
							end
						endcase
					end

					//------------------------------ 0x5: ADDQ/SUBQ/Scc/DBcc
					4'h5: begin
						if (ir[7:6] == 2'b11) begin
							if (d_mode == 3'b001) begin
								// DBcc
								br_base <= pc;
								immf(2'd1, S_DBCC1);
							end
							else if (d_mode == 3'b111 && d_rn >= 3'b010 && d_rn <= 3'b100) begin
								// TRAPcc (optional operand words are consumed
								// but otherwise ignored)
								if (d_rn == 3'b010)
									immf(2'd1, cond_true(ir[11:8]) ? S_TRAPCC : S_NEXT);
								else if (d_rn == 3'b011)
									immf(2'd2, cond_true(ir[11:8]) ? S_TRAPCC : S_NEXT);
								else begin
									if (cond_true(ir[11:8]))
										exc(`AP040_VEC_TRAPCC, 4'd2, pc, pc_i);
									else fetch_next;
								end
							end
							else begin
								// Scc
								exec_kind <= EK_SCC;
								op_size <= `AP040_SZ_B;
								p_dsize <= `AP040_SZ_B;
								p_flags <= 0;
								if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
								else if (d_mode == 3'b001 || ea_is_imm) go_illegal;
								else begin p_dst <= DK_MEM; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
							end
						end
						else begin
							// ADDQ/SUBQ
							alu_op <= ir[8] ? `AP040_ALU_SUB : `AP040_ALU_ADD;
							p_src <= SK_IMPL;
							src_val <= {28'd0, (d_reg9 == 3'd0) ? 4'd8 : {1'b0, d_reg9}};
							if (d_mode == 3'b001) begin
								// to An: whole register, no flags, any size but byte
								if (std_size == `AP040_SZ_B) go_illegal;
								else begin
									op_size <= `AP040_SZ_L;
									p_dst <= DK_REG; p_dreg <= {1'b1, d_rn};
									p_flags <= 0;
									pipe_go;
								end
							end
							else begin
								op_size <= std_size;
								p_dsize <= std_size;
								if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
								else if (ea_is_imm) go_illegal;
								else begin p_dst <= DK_MEM; p_rmw <= 1; dst_mode_r <= d_mode; dst_rn_r <= d_rn; pipe_go; end
							end
						end
					end

					//---------------------------------------- 0x6: Bcc/BSR/BRA
					4'h6: begin
						if (ir[7:0] == 8'h00 || ir[7:0] == 8'hFF) begin
							br_base <= pc;
							br_long <= (ir[7:0] == 8'hFF);
							immf((ir[7:0] == 8'hFF) ? 2'd2 : 2'd1, S_BCC_EXT);
						end
						else if (ir[11:8] == 4'h1) begin
							// BSR.B
							br_tgt <= pc + sxb(ir[7:0]);
							mwr(dbg_a7 - 32'd4, `AP040_SZ_L, pc, S_BSR_PUSH);
						end
						else if (cond_true(ir[11:8])) go_pc(pc + sxb(ir[7:0]));
						else fetch_next;
					end

					//------------------------------------------- 0x7: MOVEQ
					4'h7: begin
						if (ir[8]) go_illegal;
						else begin
							rfw({1'b0, d_reg9}, sxb(ir[7:0]));
							sr[3] <= ir[7];
							sr[2] <= (ir[7:0] == 8'd0);
							sr[1] <= 0; sr[0] <= 0;
							fetch_next;
						end
					end

					//------------------------------------- 0x8: OR/DIV/SBCD
					4'h8: begin
						if (d_op8_6 == 3'b011 || d_op8_6 == 3'b111) begin
							// DIVU.W / DIVS.W
							exec_kind <= EK_MD_W;
							md_isdiv <= 1;
							md_sign <= d_op8_6[2];
							op_size <= `AP040_SZ_W;
							p_ssize <= `AP040_SZ_W;
							p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
							if (d_mode == 3'b001) go_illegal;
							else if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; pipe_go; end
							else if (ea_is_imm) begin p_src <= SK_IMM; immf(2'd1, S_PIPE_START); end
							else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
						end
						else if (ir[8] && d_mode[2:1] == 2'b00) begin
							case (d_op8_6[1:0])
								2'b00: begin
									// SBCD
									alu_op <= `AP040_ALU_SBCD;
									op_size <= `AP040_SZ_B;
									p_ssize <= `AP040_SZ_B; p_dsize <= `AP040_SZ_B;
									if (!d_mode[0]) begin
										p_src <= SK_REG; p_sreg <= {1'b0, d_rn};
										p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
									end
									else begin
										p_src <= SK_MEM; src_mode_r <= 3'b100; src_rn_r <= d_rn;
										p_dst <= DK_MEM; dst_mode_r <= 3'b100; dst_rn_r <= d_reg9;
										p_rmw <= 1;
									end
									pipe_go;
								end
								2'b01: begin
									// PACK
									exec_kind <= EK_PACK;
									p_flags <= 0;
									p_ssize <= `AP040_SZ_W; p_dsize <= `AP040_SZ_B;
									if (!d_mode[0]) begin
										p_src <= SK_REG; p_sreg <= {1'b0, d_rn};
										p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
									end
									else begin
										p_src <= SK_MEM; src_mode_r <= 3'b100; src_rn_r <= d_rn;
										p_dst <= DK_MEM; dst_mode_r <= 3'b100; dst_rn_r <= d_reg9;
									end
									immf(2'd1, S_PIPE_START);
								end
								2'b10: begin
									// UNPK
									exec_kind <= EK_UNPK;
									p_flags <= 0;
									p_ssize <= `AP040_SZ_B; p_dsize <= `AP040_SZ_W;
									if (!d_mode[0]) begin
										p_src <= SK_REG; p_sreg <= {1'b0, d_rn};
										p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
									end
									else begin
										p_src <= SK_MEM; src_mode_r <= 3'b100; src_rn_r <= d_rn;
										p_dst <= DK_MEM; dst_mode_r <= 3'b100; dst_rn_r <= d_reg9;
									end
									immf(2'd1, S_PIPE_START);
								end
								default: go_illegal;
							endcase
						end
						else begin
							// OR
							alu_op <= `AP040_ALU_OR;
							op_size <= std_size;
							p_ssize <= std_size; p_dsize <= std_size;
							if (!ir[8]) begin
								// <ea> OR Dn -> Dn
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
								if (d_mode == 3'b001) go_illegal;
								else if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; pipe_go; end
								else if (ea_is_imm) begin p_src <= SK_IMM; immf((std_size == `AP040_SZ_L) ? 2'd2 : 2'd1, S_PIPE_START); end
								else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
							end
							else begin
								// Dn OR <ea> -> <ea>
								p_src <= SK_REG; p_sreg <= {1'b0, d_reg9};
								p_dst <= DK_MEM; p_rmw <= 1;
								dst_mode_r <= d_mode; dst_rn_r <= d_rn;
								if (d_mode < 3'b010 || ea_is_imm) go_illegal;
								else pipe_go;
							end
						end
					end

					//------------------------------------ 0x9/0xD: SUB/ADD
					4'h9, 4'hD: begin : dec_addsub
						reg is_add;
						is_add = (ir_hi == 4'hD);
						if (d_op8_6 == 3'b011 || d_op8_6 == 3'b111) begin
							// ADDA/SUBA
							alu_op <= is_add ? `AP040_ALU_ADD : `AP040_ALU_SUB;
							op_size <= `AP040_SZ_L;
							p_ssize <= d_op8_6[2] ? `AP040_SZ_L : `AP040_SZ_W;
							p_sextw <= !d_op8_6[2];
							p_flags <= 0;
							p_dst <= DK_REG; p_dreg <= {1'b1, d_reg9};
							if (d_mode == 3'b000 || d_mode == 3'b001) begin
								p_src <= SK_REG; p_sreg <= {d_mode[0], d_rn}; pipe_go;
							end
							else if (ea_is_imm) begin
								p_src <= SK_IMM;
								immf(d_op8_6[2] ? 2'd2 : 2'd1, S_PIPE_START);
							end
							else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
						end
						else if (ir[8] && d_mode[2:1] == 2'b00 && std_size != 2'b11) begin
							// ADDX/SUBX
							alu_op <= is_add ? `AP040_ALU_ADDX : `AP040_ALU_SUBX;
							op_size <= std_size;
							p_ssize <= std_size; p_dsize <= std_size;
							if (!d_mode[0]) begin
								p_src <= SK_REG; p_sreg <= {1'b0, d_rn};
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
							end
							else begin
								p_src <= SK_MEM; src_mode_r <= 3'b100; src_rn_r <= d_rn;
								p_dst <= DK_MEM; dst_mode_r <= 3'b100; dst_rn_r <= d_reg9;
								p_rmw <= 1;
							end
							pipe_go;
						end
						else begin
							alu_op <= is_add ? `AP040_ALU_ADD : `AP040_ALU_SUB;
							op_size <= std_size;
							p_ssize <= std_size; p_dsize <= std_size;
							if (!ir[8]) begin
								// <ea> op Dn -> Dn
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
								if (d_mode == 3'b001 && std_size == `AP040_SZ_B) go_illegal;
								else if (d_mode == 3'b000 || d_mode == 3'b001) begin
									p_src <= SK_REG; p_sreg <= {d_mode[0], d_rn}; pipe_go;
								end
								else if (ea_is_imm) begin p_src <= SK_IMM; immf((std_size == `AP040_SZ_L) ? 2'd2 : 2'd1, S_PIPE_START); end
								else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
							end
							else begin
								// Dn op <ea> -> <ea>
								p_src <= SK_REG; p_sreg <= {1'b0, d_reg9};
								p_dst <= DK_MEM; p_rmw <= 1;
								dst_mode_r <= d_mode; dst_rn_r <= d_rn;
								if (d_mode < 3'b010 || ea_is_imm) go_illegal;
								else pipe_go;
							end
						end
					end

					//---------------------------------------------- 0xA: A-line
					4'hA: exc(`AP040_VEC_ALINE, 4'd0, pc_i, 32'd0);

					//---------------------------------- 0xB: CMP/CMPA/EOR/CMPM
					4'hB: begin
						if (d_op8_6 == 3'b011 || d_op8_6 == 3'b111) begin
							// CMPA
							alu_op <= `AP040_ALU_CMP;
							op_size <= `AP040_SZ_L;
							p_ssize <= d_op8_6[2] ? `AP040_SZ_L : `AP040_SZ_W;
							p_sextw <= !d_op8_6[2];
							p_wbsup <= 1;
							p_dst <= DK_REG; p_dreg <= {1'b1, d_reg9};
							if (d_mode == 3'b000 || d_mode == 3'b001) begin
								p_src <= SK_REG; p_sreg <= {d_mode[0], d_rn}; pipe_go;
							end
							else if (ea_is_imm) begin
								p_src <= SK_IMM;
								immf(d_op8_6[2] ? 2'd2 : 2'd1, S_PIPE_START);
							end
							else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
						end
						else if (!ir[8]) begin
							// CMP <ea>,Dn
							alu_op <= `AP040_ALU_CMP;
							op_size <= std_size;
							p_ssize <= std_size;
							p_wbsup <= 1;
							p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
							if (d_mode == 3'b001 && std_size == `AP040_SZ_B) go_illegal;
							else if (d_mode == 3'b000 || d_mode == 3'b001) begin
								p_src <= SK_REG; p_sreg <= {d_mode[0], d_rn}; pipe_go;
							end
							else if (ea_is_imm) begin p_src <= SK_IMM; immf((std_size == `AP040_SZ_L) ? 2'd2 : 2'd1, S_PIPE_START); end
							else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
						end
						else if (d_mode == 3'b001) begin
							// CMPM (Ay)+,(Ax)+
							alu_op <= `AP040_ALU_CMP;
							op_size <= std_size;
							p_ssize <= std_size; p_dsize <= std_size;
							p_wbsup <= 1;
							p_src <= SK_MEM; src_mode_r <= 3'b011; src_rn_r <= d_rn;
							p_dst <= DK_MEM; dst_mode_r <= 3'b011; dst_rn_r <= d_reg9;
							p_rmw <= 1;
							pipe_go;
						end
						else begin
							// EOR Dn,<ea>
							alu_op <= `AP040_ALU_EOR;
							op_size <= std_size;
							p_dsize <= std_size;
							p_src <= SK_REG; p_sreg <= {1'b0, d_reg9};
							if (d_mode == 3'b000) begin p_dst <= DK_REG; p_dreg <= {1'b0, d_rn}; pipe_go; end
							else if (ea_is_imm) go_illegal;
							else begin
								p_dst <= DK_MEM; p_rmw <= 1;
								dst_mode_r <= d_mode; dst_rn_r <= d_rn;
								pipe_go;
							end
						end
					end

					//------------------------------------ 0xC: AND/MUL/EXG
					4'hC: begin
						if (d_op8_6 == 3'b011 || d_op8_6 == 3'b111) begin
							// MULU.W / MULS.W
							exec_kind <= EK_MD_W;
							md_isdiv <= 0;
							md_sign <= d_op8_6[2];
							op_size <= `AP040_SZ_W;
							p_ssize <= `AP040_SZ_W;
							p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
							if (d_mode == 3'b001) go_illegal;
							else if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; pipe_go; end
							else if (ea_is_imm) begin p_src <= SK_IMM; immf(2'd1, S_PIPE_START); end
							else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
						end
						else if (ir[8] && d_op8_6[1:0] == 2'b00 && d_mode[2:1] == 2'b00) begin
							// ABCD
							alu_op <= `AP040_ALU_ABCD;
							op_size <= `AP040_SZ_B;
							p_ssize <= `AP040_SZ_B; p_dsize <= `AP040_SZ_B;
							if (!d_mode[0]) begin
								p_src <= SK_REG; p_sreg <= {1'b0, d_rn};
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
							end
							else begin
								p_src <= SK_MEM; src_mode_r <= 3'b100; src_rn_r <= d_rn;
								p_dst <= DK_MEM; dst_mode_r <= 3'b100; dst_rn_r <= d_reg9;
								p_rmw <= 1;
							end
							pipe_go;
						end
						else if (ir[8] && (d_op8_6[1:0] == 2'b01) && d_mode[2:1] == 2'b00) begin
							// EXG Dn,Dn (mode 000) / EXG An,An (mode 001)
							rr_a <= {d_mode[0], d_reg9};
							rr_b <= {d_mode[0], d_rn};
							state <= S_EXG1;
						end
						else if (ir[8] && d_op8_6[1:0] == 2'b10 && d_mode == 3'b001) begin
							// EXG Dn,An
							rr_a <= {1'b0, d_reg9};
							rr_b <= {1'b1, d_rn};
							state <= S_EXG1;
						end
						else begin
							// AND
							alu_op <= `AP040_ALU_AND;
							op_size <= std_size;
							p_ssize <= std_size; p_dsize <= std_size;
							if (!ir[8]) begin
								p_dst <= DK_REG; p_dreg <= {1'b0, d_reg9};
								if (d_mode == 3'b001) go_illegal;
								else if (d_mode == 3'b000) begin p_src <= SK_REG; p_sreg <= {1'b0, d_rn}; pipe_go; end
								else if (ea_is_imm) begin p_src <= SK_IMM; immf((std_size == `AP040_SZ_L) ? 2'd2 : 2'd1, S_PIPE_START); end
								else begin p_src <= SK_MEM; src_mode_r <= d_mode; src_rn_r <= d_rn; pipe_go; end
							end
							else begin
								p_src <= SK_REG; p_sreg <= {1'b0, d_reg9};
								p_dst <= DK_MEM; p_rmw <= 1;
								dst_mode_r <= d_mode; dst_rn_r <= d_rn;
								if (d_mode < 3'b010 || ea_is_imm) go_illegal;
								else pipe_go;
							end
						end
					end

					//---------------------------------------- 0xE: shifts
					4'hE: begin
						if (ir[7:6] == 2'b11) begin
							if (ir[11]) go_illegal;   // bitfields not implemented
							else begin
								// memory shift by one, word
								exec_kind <= EK_SHIFT;
								sh_rox <= (ir[10:9] == 2'b10);
								case (ir[10:9])
									2'b00: alu_op <= ir[8] ? `AP040_ALU_ASL1 : `AP040_ALU_ASR1;
									2'b01: alu_op <= ir[8] ? `AP040_ALU_LSL1 : `AP040_ALU_LSR1;
									2'b10: alu_op <= ir[8] ? `AP040_ALU_ROXL1 : `AP040_ALU_ROXR1;
									default: alu_op <= ir[8] ? `AP040_ALU_ROL1 : `AP040_ALU_ROR1;
								endcase
								op_size <= `AP040_SZ_W;
								p_dsize <= `AP040_SZ_W;
								p_src <= SK_NONE;   // count of one
								p_rmw <= 1;
								if (d_mode < 3'b010 || ea_is_imm) go_illegal;
								else begin
									p_dst <= DK_MEM;
									dst_mode_r <= d_mode; dst_rn_r <= d_rn;
									pipe_go;
								end
							end
						end
						else begin
							// register shift
							exec_kind <= EK_SHIFT;
							sh_rox <= (ir[4:3] == 2'b10);
							case (ir[4:3])
								2'b00: alu_op <= ir[8] ? `AP040_ALU_ASL1 : `AP040_ALU_ASR1;
								2'b01: alu_op <= ir[8] ? `AP040_ALU_LSL1 : `AP040_ALU_LSR1;
								2'b10: alu_op <= ir[8] ? `AP040_ALU_ROXL1 : `AP040_ALU_ROXR1;
								default: alu_op <= ir[8] ? `AP040_ALU_ROL1 : `AP040_ALU_ROR1;
							endcase
							op_size <= std_size;
							p_dst <= DK_REG; p_dreg <= {1'b0, d_rn};
							if (ir[5]) begin
								p_src <= SK_REG; p_sreg <= {1'b0, d_reg9};
							end
							else begin
								p_src <= SK_IMPL;
								src_val <= {26'd0, (d_reg9 == 3'd0) ? 6'd8 : {3'd0, d_reg9}};
							end
							pipe_go;
						end
					end

					//------------------------------------------ 0xF: 040 group
					default: begin
						if (ir[11:8] == 4'h4) begin
							// CINV/CPUSH: privileged cache maintenance, no-op
							// while the caches are disabled
							if (!sr_s) go_priv;
							else if (ir[4:3] == 2'b00) go_illegal;
							else fetch_next;
						end
						else if (ir[11:8] == 4'h5) begin
							if (ir[7:5] == 3'b000) begin
								// PFLUSH group: ATC arrives with milestone E
								if (!sr_s) go_priv;
								else fetch_next;
							end
							else if (ir[7:6] == 2'b01) begin
								// PTEST
								if (!sr_s) go_priv;
								else begin
									rr_a <= {1'b1, d_rn};
									state <= S_PTEST1;
								end
							end
							else exc(`AP040_VEC_FLINE, 4'd0, pc_i, 32'd0);
						end
						else if (ir[11:8] == 4'h6 && ir[7:5] == 3'b000) begin
							// MOVE16 with absolute long operand
							m16_form <= {1'b0, ir[4:3]};
							immf(2'd2, S_M16_SRC);
						end
						else if (ir[11:8] == 4'h6 && ir[7:3] == 5'b00100) begin
							// MOVE16 (Ax)+,(Ay)+
							m16_form <= 3'd4;
							immf(2'd1, S_M16_SRC);
						end
						else exc(`AP040_VEC_FLINE, 4'd0, pc_i, 32'd0);
					end
				endcase
			end

			//------------------------------------------------------- stopped
			S_STOP_LD: begin
				sr <= imm[15:0] & `AP040_SR_MASK;
				state <= S_STOPPED;
			end

			S_STOPPED: begin
				if (irq_pend) begin
					exc_vec <= `AP040_VEC_AUTOVEC + {5'd0, irq_lvl};
					exc_fmt <= 0; exc_spc <= pc; exc_addr <= 0;
					exc_is_irq <= 1; exc_pass2 <= 0;
					irq_lvl_l <= irq_lvl;
					state <= S_EXC0;
				end
			end

			//------------------------------------------------------- TRAPcc
			S_TRAPCC: exc(`AP040_VEC_TRAPCC, 4'd2, pc, pc_i);

			//--------------------------------------------------------- halted
			S_HALT: ;

			default: begin
				fault_r <= 1;
				state <= S_HALT;
			end
		endcase
	end
end

//---------------------------------------------------------------------------
// debug/status
//---------------------------------------------------------------------------

assign debug_busy   = mem_req;
assign debug_fault  = fault_r;
assign debug_halted = (state == S_HALT);

assign debug_status = {
	16'hA040,                    // [255:240] magic
	7'd0, unused_in,             // [239:232]
	fault_r, state,              // [231:224]
	dbg_a0,                      // [223:192]
	dbg_d2,                      // [191:160]
	dbg_d1,                      // [159:128]
	dbg_d0,                      // [127:96]
	dbg_a7,                      // [95:64]
	ir,                          // [63:48]
	sr,                          // [47:32]
	pc                           // [31:0]
};

endmodule
