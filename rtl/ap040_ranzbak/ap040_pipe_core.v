//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_pipe_core.v - top level (rewritten for Minimig plan M1)            //
//                                                                          //
//   IF -> ID -> EA-calc -> EA-fetch -> EX -> WB                            //
//                                                                          //
// WB is the commit point: the EX output register (exe_o, wb_t) is applied  //
// at the end of its clock -- register writes (three ports), CCR/SR,        //
// control registers, and the store (L1 port W).  Everything before WB is  //
// speculative and is thrown away by EX's redirect (flush of IF, ID,        //
// EA-calc, EA-fetch).  ap040_writeback.v is a one-clock-later valid/pc     //
// copy of retiring instructions, for the benches' debug taps.              //
//                                                                          //
// Parameters:                                                              //
//   PC_RESET, PROG_WORDS, L1_AW   as the milestone benches use them        //
//   RESET_FROM_VECTORS = 1: at reset EA-fetch loads ISP from (0) and PC    //
//     from (4) and IF starts there (the 68040).  0: IF starts at PC_RESET  //
//     with ISP = 0 (the milestone benches, which poke ISP).                //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_core
	import ap040_pipe_pkg::*;
#(
	parameter [31:0] PC_RESET           = 32'h0000_0400,
	parameter         PROG_WORDS         = 10,
	parameter         L1_AW              = 12,
	parameter         RESET_FROM_VECTORS = 0,
	// 0: the L1 test substrate (the milestone benches); 1: the memory port
	// mem_* through the bus controller (plan M5, the Minimig wrapper)
	parameter         BUS                = 0,
	// CAS2 Dc1 = Dc2 on a failed compare: 0 the 68040's order (operand 2), 1 the 020/030's
	parameter         CAS2_DC_ORDER_020  = 0,
	// BUS = 1: 0 synchronous stores (precise access errors, M6), 1 posted (fatal errors)
	parameter         STORE_POST         = 0,
	// 1: RTE treats format $4 as a format error (a full 68040; the FPU is M10)
	parameter         HAS_FPU            = 0,
	// plan M11.1: register EA-fetch's redirect (one clock on RTS/RTD/RTR, a
	// memory-indirect JMP/JSR and a wrongly guessed Bcc/DBcc, in exchange for
	// taking the memory acknowledge off the path into IF's prefetch queue)
	parameter         REDIR_REG          = 1,
	// 1: the interrupt inputs are live (the wrapper); 0: tied off (the L1
	// benches leave ipl unconnected)
	parameter         IRQ                = 0,
	// 1: the cache maintenance port is live (the wrapper answers cinv_done);
	// 0: CINV/CPUSH complete at once (the L1 benches have no cache)
	parameter         CINV               = 0,
	// plan M14 (BUS = 1): IF's fetch is offered to the wrapper's instruction
	// read path first (ifp_*): a hit is answered the clock after the request,
	// without the shared port; a miss goes to the BCU's fetch slot as before
	parameter         IFP                = 0,
	// plan M14 step 3 (BUS = 1): EA-fetch's data reads are offered to the
	// wrapper's data read path (dfp_*) as well; a hit is answered the clock
	// after the request, a miss goes out of the BCU's slot as before
	parameter         DFP                = 0,
	// (BUS = 1, STORE_POST = 0) register the synchronous store's completion
	// (ap040_pipe_bcu DONE_REG): one clock per store, and the memory
	// acknowledge no longer reaches the stall chain (PLAN M14 / Q23)
	parameter         STDONE_REG         = 1
)
(
	input  clk,
	input  nreset,
	input  ce,

	output        dbg_if_valid,  output [31:0] dbg_if_pc,
	output        dbg_id_valid,  output [31:0] dbg_id_pc,
	output        dbg_eac_valid, output [31:0] dbg_eac_pc,
	output        dbg_eaf_valid, output [31:0] dbg_eaf_pc,
	output        dbg_ex_valid,  output [31:0] dbg_ex_pc,
	output        dbg_wb_valid,  output [31:0] dbg_wb_pc,
	output [31:0] dbg_d0, output [31:0] dbg_d1, output [31:0] dbg_d2, output [31:0] dbg_d3,
	output [31:0] dbg_d4, output [31:0] dbg_d5, output [31:0] dbg_d6, output [31:0] dbg_d7,
	output  [4:0] dbg_ccr,
	output [15:0] dbg_sr,

	// memory port (BUS = 1): the reference core's mem_* contract
	output        mem_req,
	output        mem_write,
	output        mem_instr,
	output  [1:0] mem_size,
	output [31:0] mem_addr,
	output [31:0] mem_wdata,
	output  [2:0] mem_fc,
	input         mem_ack,
	input  [31:0] mem_rdata,
	input         mem_flt,
	input         mem_atc,       // (with mem_flt) an MMU fault, not a bus error (M7; 0 until then)
	output        bus_st_err,    // a posted store bus-errored (fatal)

	// status for the wrapper (cacr_out/vbr_out, debug_status)
	output [31:0] cacr_q,
	output [31:0] vbr_q,
	output [31:0] dbg_a0,
	output [31:0] dbg_sp,        // the A7 the SR selects
	output [31:0] dbg_usp,
	output [31:0] dbg_isp,
	output        dbg_halted,    // double fault
	// the MMU (M7): its registers, and the PTEST/PFLUSH sideband (the
	// reference core's ports; tie pt_done/pf_done high without an MMU)
	output [31:0] tc_q, urp_q, srp_q, itt0_q, itt1_q, dtt0_q, dtt1_q,
	output        pt_req,
	output        pt_write,
	output [31:0] pt_addr,
	output  [2:0] pt_fc,
	input         pt_done,
	input  [31:0] pt_mmusr,
	output        pf_req,
	output  [1:0] pf_mode,
	output [31:0] pf_addr,
	output  [2:0] pf_fc,
	input         pf_done,
	// interrupts, STOP, RESET (plan M9 subset): active-low IPL pins, the NMI
	// acknowledge toggle (lib/AP68040 ap040_core.v), reset out, stopped
	input   [2:0] ipl,
	output        nmi_ack_toggle,
	output        nresetout,
	output        dbg_stopped,
	// cache maintenance (M8): CINV/CPUSH to the wrapper's cache and to the
	// external banks (TG68K.vhd's cache_maint_*)
	output        cinv_req,
	output        cinv_ic,
	output        cinv_dc,
	input         cinv_done,
	// the FPU (plan M10.1): instantiated OUTSIDE the core, as the MMU is.
	// Pulse request / pulse done; `accepted` releases the instruction and
	// lets the operation finish in the background.  With HAS_FPU = 0 nothing
	// decodes to CL_FPU, fp_req is never raised and the whole group folds
	// away; the wrapper ties the inputs off.
	output        fp_req,
	output  [2:0] fp_op_class,
	output  [6:0] fp_opmode,
	output  [2:0] fp_src_fmt,
	output  [2:0] fp_src_r,
	output  [2:0] fp_dst_r,
	output [95:0] fp_din,
	output        fp_ia_we,
	output [31:0] fp_ia_wdata,
	output  [1:0] fp_cr_sel,
	output        fp_cr_we,
	output [31:0] fp_cr_wdata,
	input  [31:0] fp_cr_rdata,
	output  [2:0] fp_fm_sel,
	output        fp_fm_we,
	output [95:0] fp_fm_wdata,
	input  [95:0] fp_fm_rdata,
	input   [3:0] fp_fpcc,
	input         fp_bsun_en,
	output        fp_bsun_req,
	input         fp_used,
	output        fp_frst,
	output        fp_fridle,
	input         fp_st_unimp,
	input  [15:0] fp_st_cmd1,
	input  [15:0] fp_st_cmd3,
	input   [2:0] fp_st_stag,
	input   [2:0] fp_st_dtag,
	input   [2:0] fp_st_flags,
	input   [2:0] fp_st_grs,
	input         fp_st_wbte15,
	input  [95:0] fp_st_fpt,
	input  [95:0] fp_st_et,
	output        fp_fsave_ack,
	output        fp_fr_unimp,
	output [15:0] fp_fr_cmd1,
	output [15:0] fp_fr_cmd3,
	output  [2:0] fp_fr_stag,
	output  [2:0] fp_fr_dtag,
	output  [2:0] fp_fr_flags,
	output  [2:0] fp_fr_grs,
	output        fp_fr_wbte15,
	output [95:0] fp_fr_fpt,
	output [95:0] fp_fr_et,
	input         fp_st_busy,       // (M10 remainder) the $4160 BUSY frame
	input  [95:0] fp_st_wbt,
	input  [31:0] fp_st_fpiar,
	output        fp_fr_busy,
	output [95:0] fp_fr_wbt,
	output [31:0] fp_fr_fpiar,
	output  [7:0] fp_fr_cusavepc,
	output        fp_fr_et15,
	output        fp_fr_fpt15,
	input         fp_fr_resume,
	output        fp_pcap,          // (M10 remainder) the deferred exception's frame
	input         fp_fr_e1pend,
	input   [7:0] fp_cur_vec,
	input         fp_done,
	input         fp_accepted,
	input         fp_unimp,
	input         fp_unsupp,
	input         fp_exc_req,
	input   [7:0] fp_exc_vec,
	input  [95:0] fp_dout,
	// the instruction read path (plan M14, IFP = 1): every fetch IF issues at
	// an enabled clock edge (ifp_req includes ce), its address and S bit.
	// The wrapper looks each one up; the clock after it ifp_hit says the read
	// path has the longword (ifp_data).  ifp_try (a REGISTER in the wrapper:
	// whether the previous fetch's address could be served by the read path)
	// decides whether a new fetch waits for that answer or goes straight to
	// the shared port as before.  Tie ifp_hit and ifp_try low with IFP = 0.
	output        ifp_req,
	output [31:0] ifp_addr,
	output        ifp_s,
	input         ifp_try,
	input         ifp_hit,
	input  [31:0] ifp_data,
	// the data read path (plan M14 step 3, DFP = 1): every read EA-fetch
	// issues at an enabled edge (dfp_req), its address, size and function
	// code; the clock after it dfp_hit says the path holds the operand
	// (dfp_data, right-aligned as a completed read).  The core takes the
	// answer only if no store older than the read was in flight in either
	// clock (the BCU's own rule for letting a read go).  Tie dfp_hit low
	// with DFP = 0.
	output        dfp_req,
	output [31:0] dfp_addr,
	output  [1:0] dfp_size,
	output  [2:0] dfp_fc,
	input         dfp_hit,
	input  [31:0] dfp_data
);

//--------------------------------------------------------------- stage wires
// (declared before the bus controller's generate block uses them)
wire        fw_st_v;
wire [31:0] fw_st_addr, fw_st_data;
wire  [1:0] fw_st_size;
wire        q_v0, q_v1;  wire [31:0] q_pc0;  wire [15:0] q_w0, q_w1;  wire [1:0] id_consume, id_consume_nf;
// self-modifying code: the code the stages younger than EX hold
wire [31:0] if_q_lo, if_q_hi, id_g_lo, id_g_hi;
wire        id_g_v, smc_hit, wb_smc;
wire        id_valid;  id_t id_o;
wire        eac_valid; eac_t eac_o;
wire        eaf_valid; ex_t eaf_o;
wire        exe_valid; wb_t exe_o;
wire        wb_valid;  wire [31:0] wb_pc;

wire ea_stall, eaf_stall, ex_stall;
wire eaf_blk, eaf_halted;

wire        id_redirect_valid;
wire [31:0] id_redirect_pc;
wire        ex_redirect;
wire [31:0] ex_redirect_pc;
wire        ex_redirect_s;
wire        f_s;
wire        eac_redir_v, eaf_redir_v;
wire        eaf_redir_soon;   // (REDIR_REG) hold IF for the gap clock
wire [31:0] eac_redir_pc, eaf_redir_pc;
// Redirects, oldest first: EX (not-taken branch, RTE, MOVE to SR, exception
// entry), EA-fetch (RTS, memory-indirect JMP/JSR), EA-calc (JMP/JSR), ID
// (guessed-taken Bcc/BSR/DBcc).  Each flushes the stages in front of it.
// (WB's self-modifying-code refetch is older than all of them, and squashes
// EX's micro-op too)
wire ex_redir_q = ex_redirect && !wb_smc;
wire flush     = ex_redir_q || wb_smc;                                   // EA-fetch
wire flush_eac = ex_redir_q || wb_smc || eaf_redir_v;                    // EA-calc
wire flush_id  = ex_redir_q || wb_smc || eaf_redir_v || eac_redir_v;     // ID
wire        redirect_valid = wb_smc || ex_redirect || eaf_redir_v || eac_redir_v || id_redirect_valid;
wire [31:0] redirect_pc    = wb_smc ? exe_o.stf.npc :
                             ex_redirect ? ex_redirect_pc :
                             eaf_redir_v ? eaf_redir_pc :
                             eac_redir_v ? eac_redir_pc : id_redirect_pc;

//--------------------------------------------------------------- commit (WB)
// (BUS: a store waits in WB while the posted-store buffer is full)
wire sb_full, sb_busy;
wire pmmu_busy;             // a PTEST/PFLUSH owns the MMU (EA-fetch): IF holds off
wire irq_req;               // a level above the mask (or an NMI edge) is pending
wire [2:0] irq_lvl;
// The acknowledge toggles when the interrupt's exception micro-op commits:
// the same edge writes the new mask, as the reference's S_EXC0 does, so the
// sampler's held level cannot be re-latched against the old mask
reg  irq_ack_t, nmi_ack_t;
wire eaf_stopped, eaf_rsto;
// A held micro-op keeps writing its registers, CCR/SR and control registers
// (the same values each clock -- nothing younger can pass it), so the stages
// in front see them through the register file's write-through as usual;
// only its store and its retirement wait (retire).
// synchronous stores (BUS, STORE_POST = 0): WB holds until memory has
// the store; an access error on it drops the micro-op (its register writes
// stand) and EA-fetch takes vector 2 (M6)
wire st_done, st_ferr, st_fatc, st_fma;
wire wb_fault = exe_valid && exe_o.st_v && st_ferr;
wire wb_hold  = exe_valid && exe_o.st_v && ((BUS != 0 && STORE_POST == 0) ? !st_done : sb_full);
wire commit   = exe_valid;
// (a fault on the last micro-op: the instruction is complete, its write pending in WB1)
// (a faulted store retires only on an instruction's last micro-op, and never
// for MOVEM: its fault restarts the instruction with CM set, M68040UM 8.4.6.7)
wire retire   = exe_valid && !wb_hold && !(wb_fault && (!exe_o.last || exe_o.stf.cm));

reg [15:0] sr;
reg [31:0] vbr;
reg  [2:0] sfc, dfc;
reg [31:0] cacr;
// MMU registers: stored with the reference's write masks (lib/AP68040
// ap040_core.v S_MOVEC2); they drive the MMU outside (M7)
reg [31:0] tc, itt0, itt1, dtt0, dtt1, mmusr, urp, srp;

always @(posedge clk) begin
	if (!nreset) begin
		sr   <= `AP040_SR_RESET;
		vbr  <= 32'h0;
		sfc  <= 3'h0;
		dfc  <= 3'h0;
		cacr <= 32'h0;
		tc <= 32'h0; itt0 <= 32'h0; itt1 <= 32'h0; dtt0 <= 32'h0; dtt1 <= 32'h0;
		mmusr <= 32'h0; urp <= 32'h0; srp <= 32'h0;
	end else if (ce && commit) begin
		if (exe_o.sr_v)       sr <= exe_o.sr_val;
		else if (exe_o.ccr_v) sr[4:0] <= exe_o.ccr_val;
		if (exe_o.creg_v) begin
			case (exe_o.creg_sel)
				CR_SFC:  sfc  <= exe_o.creg_val[2:0];
				CR_DFC:  dfc  <= exe_o.creg_val[2:0];
				CR_CACR: cacr <= exe_o.creg_val & 32'h8000_8000;
				CR_VBR:  vbr  <= exe_o.creg_val;
				CR_TC:   tc   <= exe_o.creg_val & 32'h0000_C000;
				CR_ITT0: itt0 <= exe_o.creg_val & 32'hFFFF_E364;
				CR_ITT1: itt1 <= exe_o.creg_val & 32'hFFFF_E364;
				CR_DTT0: dtt0 <= exe_o.creg_val & 32'hFFFF_E364;
				CR_DTT1: dtt1 <= exe_o.creg_val & 32'hFFFF_E364;
				CR_MMUSR: mmusr <= exe_o.creg_val;
				CR_URP:  urp  <= exe_o.creg_val & 32'hFFFF_FE00;
				CR_SRP:  srp  <= exe_o.creg_val & 32'hFFFF_FE00;
				default: ;
			endcase
		end
	end
end

//--------------------------------------------------------------- interrupts
// The reference core's IPL sampler, lifted (lib/AP68040 ap040_core.v, the
// "interrupt input synchronization" block): two coherent samples, level 7
// edge-armed and acknowledged by toggle, a mask-qualified level 1-6 held
// against a later mask raise until acknowledged, tracked down when the
// device withdraws.  Interrupts are autovectored (the wrapper's
// ipl_autovector is ignored, as the reference).  sr is the committed SR:
// EA-fetch takes an interrupt only with nothing older in flight.
generate if (IRQ != 0) begin : g_irq
reg [2:0] ipl_s1, ipl_s2;
reg [2:0] irq_lvl_r;
reg [2:0] irq_hold_lvl;
reg       irq_ack_d, nmi_ack_d, nmi_arm;
always @(posedge clk) begin
	if (!nreset) begin
		ipl_s1 <= 3'b111; ipl_s2 <= 3'b111;
		irq_lvl_r <= 3'd0; irq_hold_lvl <= 3'd0;
		irq_ack_d <= 1'b0; nmi_ack_d <= 1'b0; nmi_arm <= 1'b0;
	end else begin
		ipl_s1 <= ipl;
		ipl_s2 <= ipl_s1;
		if (ipl_s1 == ipl_s2) begin
			irq_lvl_r <= ~ipl_s2;
			if (~ipl_s2 != 3'd7) nmi_arm <= 1'b1;
		end
		irq_ack_d <= irq_ack_t;
		if (irq_ack_t != irq_ack_d)
			irq_hold_lvl <= 3'd0;
		else if (irq_hold_lvl > irq_lvl_r)
			irq_hold_lvl <= (irq_lvl_r > sr[10:8]) ? irq_lvl_r : 3'd0;
		else if (irq_lvl_r != 3'd0 && irq_lvl_r != 3'd7 &&
		         irq_lvl_r > sr[10:8] && irq_lvl_r > irq_hold_lvl)
			irq_hold_lvl <= irq_lvl_r;
		nmi_ack_d <= nmi_ack_t;
		if (nmi_ack_t != nmi_ack_d) nmi_arm <= 1'b0;
	end
end
wire [2:0] irq_lvl_live = (ipl_s1 == ipl_s2) ? ~ipl_s2 : irq_lvl_r;
// (an acknowledge still in flight -- toggled, not yet seen by the sampler --
// is not a new request)
wire       ack_busy = (irq_ack_t != irq_ack_d) || (nmi_ack_t != nmi_ack_d);
wire       nmi_pend = irq_lvl_live == 3'd7 && nmi_arm;
wire       irq_live = irq_lvl_live != 3'd0 && irq_lvl_live != 3'd7 && irq_lvl_live > sr[10:8];
assign irq_lvl = nmi_pend ? 3'd7 :
                 (irq_live && irq_lvl_live > irq_hold_lvl) ? irq_lvl_live : irq_hold_lvl;
assign irq_req = !ack_busy && (nmi_pend || irq_live || irq_hold_lvl != 3'd0);
end else begin : g_noirq
assign irq_req = 1'b0;
assign irq_lvl = 3'd0;
end endgenerate
always @(posedge clk)
	if (!nreset) begin irq_ack_t <= 1'b0; nmi_ack_t <= 1'b0; end
	else if (ce && retire && exe_o.irq) begin
		if (exe_o.sr_val[10:8] == 3'd7) nmi_ack_t <= !nmi_ack_t;
		else irq_ack_t <= !irq_ack_t;
	end
assign nmi_ack_toggle = nmi_ack_t;
assign nresetout      = !eaf_rsto;
assign dbg_stopped    = eaf_stopped;

// the SR as the stages in front see it: WB's commit written through
wire [15:0] sr_now = (commit && exe_o.sr_v)  ? exe_o.sr_val :
                     (commit && exe_o.ccr_v) ? {sr[15:5], exe_o.ccr_val} : sr;

assign dbg_ccr = sr[4:0];
assign cacr_q  = cacr;
assign tc_q = tc; assign urp_q = urp; assign srp_q = srp;
assign itt0_q = itt0; assign itt1_q = itt1; assign dtt0_q = dtt0; assign dtt1_q = dtt1;
assign pt_fc = dfc; assign pf_fc = dfc;     // PTEST/PFLUSH: DFC (M68040UM 3.7)
assign vbr_q   = vbr;
assign dbg_usp = usp_q;
assign dbg_isp = isp_q;
assign dbg_sp  = !sr[13] ? usp_q : sr[12] ? msp_q : isp_q;
assign dbg_halted = eaf_halted;
assign dbg_sr  = sr;

//--------------------------------------------------------------- register file
wire        d_rd_err, d_rd_atc, d_rd_ma;   // the read's access error (bus mode)
wire  [2:0] d_rd_fc;    // data read function code (the MMU's c_fc in M7; benches read it)
wire [4:0]  ra_sb, ra_si, ra_db, ra_di, ra_a, ra_b, ra_c, ra_d;
wire [31:0] rd_sb, rd_si, rd_db, rd_di, rd_a, rd_b, rd_c, rd_d;
wire [31:0] usp_q, isp_q, msp_q;

ap040_pipe_regfile u_regfile
(
	.clk(clk), .ce(ce), .nreset(nreset),
	.w0_we(commit && exe_o.w0_v), .w0_r(exe_o.w0_r), .w0_d(exe_o.w0_val),
	.u1_we(commit && exe_o.u1_v), .u1_r(exe_o.u1_r), .u1_d(exe_o.u1_val),
	.u0_we(commit && exe_o.u0_v), .u0_r(exe_o.u0_r), .u0_d(exe_o.u0_val),
	.ra0(ra_sb), .ra1(ra_si), .ra2(ra_db), .ra3(ra_di), .ra4(ra_a), .ra5(ra_b), .ra6(ra_c), .ra7(ra_d),
	.rd0(rd_sb), .rd1(rd_si), .rd2(rd_db), .rd3(rd_di), .rd4(rd_a), .rd5(rd_b), .rd6(rd_c), .rd7(rd_d),
	.usp_q(usp_q), .isp_q(isp_q), .msp_q(msp_q),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7),
	.dbg_a0(dbg_a0)
);

//--------------------------------------------------------------- memory
wire [L1_AW-1:0] l1_addr_a;
wire             l1_en_a;
wire      [31:0] l1_rdata_a;
wire             d_rd_req, d_rd_ack;
wire      [31:0] d_rd_addr, d_rd_data;
wire       [1:0] d_rd_size;
wire             d_wr_ready;

// The L1 test substrate stays instantiated (the benches poke dut.u_l1.mem);
// with BUS = 1 nothing reads it and synthesis removes it.
wire        f_req, f_long, f_gnt, f_ack, f_err, f_atc;
wire        q_e0, q_e1, iff_long, iff_atc;   // IF's faulted fetch (M6)
wire [31:0] iff_addr;
wire [31:0] f_addr, f_data;
wire        l1_rd_ack;
wire [31:0] l1_rd_data;
ap040_pipe_l1 #(
	.AW(L1_AW), .DW(16), .PC_RESET(PC_RESET)
) u_l1
(
	.clock     (clk),
	.nreset    (nreset),
	.address_a (l1_addr_a),
	.en_a      (l1_en_a),
	.q_a       (l1_rdata_a),
	.rd_req    ((BUS == 0) && d_rd_req),
	.rd_addr   (d_rd_addr),
	.rd_size   (d_rd_size),
	.rd_ack    (l1_rd_ack),
	.rd_data   (l1_rd_data),
	.wr_req    ((BUS == 0) && ce && commit && exe_o.st_v),
	.wr_addr   (exe_o.st_addr),
	.wr_size   (exe_o.st_size),
	.wr_data   (exe_o.st_data),
	.wr_ready  (d_wr_ready)
);

wire older_store = eaf_valid && (eaf_o.st_v || eaf_o.dk == DK_MEM ||
                                 eaf_o.cls == CL_BSR || eaf_o.cls == CL_JSR);

generate if (BUS == 0) begin : g_l1
	// fetches always granted, answered the next clock
	reg f_ack_r;
	always @(posedge clk) if (!nreset) f_ack_r <= 1'b0; else f_ack_r <= f_req;
	assign f_gnt = 1'b1;
	assign f_ack = f_ack_r;
	assign f_data = l1_rdata_a;
	assign l1_addr_a = (f_addr - PC_RESET) >> 1;
	assign l1_en_a   = f_req;
	assign d_rd_ack  = l1_rd_ack;
	assign d_rd_data = l1_rd_data;
	assign sb_full = 1'b0; assign sb_busy = 1'b0;
	assign st_done = 1'b0; assign st_ferr = 1'b0; assign st_fatc = 1'b0; assign st_fma = 1'b0;
	assign mem_req = 1'b0; assign mem_write = 1'b0; assign mem_instr = 1'b0; assign mem_size = 2'd0;
	assign mem_addr = 32'd0; assign mem_wdata = 32'd0; assign mem_fc = 3'd0; assign bus_st_err = 1'b0;
	assign d_rd_err = 1'b0; assign d_rd_atc = 1'b0; assign d_rd_ma = 1'b0;
	assign f_err = 1'b0; assign f_atc = 1'b0;
	assign ifp_req = 1'b0; assign ifp_addr = 32'd0; assign ifp_s = 1'b0;
	wire unused_ifp_l1 = ifp_hit | ifp_try | (|ifp_data) | dfp_hit | (|dfp_data);
	assign dfp_req = 1'b0; assign dfp_addr = 32'd0; assign dfp_size = 2'd0; assign dfp_fc = 3'd0;
end else begin : g_bus

	assign l1_addr_a = '0;
	assign l1_en_a   = 1'b0;

	// The data read path (plan M14 step 3).  Every read EA-fetch issues is
	// looked up (dfp_req); the clock after it the answer is taken -- the
	// BCU's slot is then answered and never goes on the port -- only if no
	// store older than the read was in flight in the issuing clock (dfp_q1)
	// or now: the rule the BCU applies before letting a read go, checked in
	// both clocks because a store entering EX in the issuing clock is seen
	// only in the next.  Anything else goes out of the slot as before, with
	// no clock lost.
	wire d_rd_fast;
	wire st_quiet = !(older_store || (exe_valid && exe_o.st_v)) && !(mem_req && mem_write);
	if (DFP != 0) begin : g_dfp
		reg dfp_look, dfp_q1;
		always @(posedge clk)
			if (!nreset) begin dfp_look <= 1'b0; dfp_q1 <= 1'b0; end
			else if (ce) begin dfp_look <= d_rd_req; dfp_q1 <= st_quiet; end
		assign d_rd_fast = dfp_look && dfp_q1 && st_quiet && dfp_hit;
		assign dfp_req  = d_rd_req && ce;
		assign dfp_addr = d_rd_addr;
		assign dfp_size = d_rd_size;
		assign dfp_fc   = d_rd_fc;
	end else begin : g_nodfp
		assign d_rd_fast = 1'b0;
		assign dfp_req  = 1'b0;
		assign dfp_addr = 32'd0;
		assign dfp_size = 2'd0;
		assign dfp_fc   = 3'd0;
		wire unused_dfp = dfp_hit | st_quiet;
	end

	// The BCU's fetch slot (b_f_*): IF's own request with IFP = 0; with
	// IFP = 1 only the fetches the instruction read path missed.
	wire        b_f_req, b_f_long, b_f_s, b_f_gnt, b_f_ack, b_f_err, b_f_atc;
	wire [31:0] b_f_addr, b_f_data;
	if (IFP != 0) begin : g_ifp
		// plan M14.  IF keeps its contract -- one fetch outstanding, the
		// next may issue in the clock the previous one answers.  The wrapper
		// looks EVERY fetch up (ifp_req is f_req, which includes ce).  When
		// ifp_try says the stream is in memory the read path serves, the
		// request is granted at once and answered the next clock by the read
		// path (ifp_hit); if it misses, it goes to the BCU's fetch slot in
		// that same clock (or, not granted, from the latched request after
		// it).  When ifp_try is low -- code the path cannot serve: ROM, chip
		// RAM, a disabled or inhibited cache -- the request goes to the BCU
		// directly, exactly as without the path, so that code pays nothing.
		// A fast answer is never an access error: whatever could fault goes
		// the slow way.  ifp_try is a register (the previous fetch's
		// verdict), so no address decode sits on IF's request path.
		reg        ifp_look;           // a lookup IF waits for answers this clock
		reg        ifp_mreq;           // a missed fetch waits for the BCU's grant
		reg        ifp_minfl;          // a fetch is on the BCU
		reg [31:0] ifp_a;
		reg        ifp_l, ifp_sv;
		wire       fast   = ifp_look && ifp_hit;
		wire       miss   = ifp_look && !ifp_hit;
		wire       direct = f_req && !ifp_try;           // straight to the port
		wire       held   = ifp_look || ifp_mreq;        // the latched request
		assign f_gnt  = direct ? b_f_gnt : f_req;
		assign f_ack  = fast || (ifp_minfl && b_f_ack);
		// a word fetch (IF asks for one word only at an address = 2 mod 4)
		// is answered right-aligned on top, as the BCU does
		assign f_data = fast ? (ifp_l ? ifp_data : {ifp_data[15:0], 16'h4E71}) : b_f_data;
		assign f_err  = !fast && b_f_err;
		assign f_atc  = !fast && b_f_atc;
		assign b_f_req  = direct || miss || ifp_mreq;
		assign b_f_addr = held ? ifp_a  : f_addr;
		assign b_f_long = held ? ifp_l  : f_long;
		assign b_f_s    = held ? ifp_sv : f_s;
		assign ifp_req  = f_req;
		assign ifp_addr = f_addr;
		assign ifp_s    = f_s;
		always @(posedge clk) begin
			if (!nreset) begin
				ifp_look <= 1'b0; ifp_mreq <= 1'b0; ifp_minfl <= 1'b0;
				ifp_a <= 32'd0; ifp_l <= 1'b0; ifp_sv <= 1'b1;
			end else if (ce) begin
				ifp_look <= f_req && ifp_try;
				if (f_req && ifp_try) begin ifp_a <= f_addr; ifp_l <= f_long; ifp_sv <= f_s; end
				// (IF issues nothing while a lookup it waits for misses)
				if ((miss || ifp_mreq) && b_f_gnt) ifp_mreq <= 1'b0;
				else if (miss)                      ifp_mreq <= 1'b1;
				if (b_f_req && b_f_gnt)             ifp_minfl <= 1'b1;
				else if (ifp_minfl && b_f_ack)      ifp_minfl <= 1'b0;
			end
		end
	end else begin : g_noifp
		assign b_f_req  = f_req;
		assign b_f_addr = f_addr;
		assign b_f_long = f_long;
		assign b_f_s    = f_s;
		assign f_gnt    = b_f_gnt;
		assign f_ack    = b_f_ack;
		assign f_data   = b_f_data;
		assign f_err    = b_f_err;
		assign f_atc    = b_f_atc;
		assign ifp_req  = 1'b0;
		assign ifp_addr = 32'd0;
		assign ifp_s    = 1'b0;
		wire unused_ifp = ifp_hit | ifp_try | (|ifp_data);
	end
	ap040_pipe_bcu #(.POST(STORE_POST), .DONE_REG(STDONE_REG)) u_bcu
	(
		.clk(clk), .nreset(nreset), .ce(ce),
		.st_v(STORE_POST ? (ce && retire && exe_o.st_v) : (exe_valid && exe_o.st_v)),
		.st_addr(exe_o.st_addr), .st_size(exe_o.st_size),
		.st_data(exe_o.st_data), .st_fc(exe_o.st_fc), .st_rb(exe_o.st_rb), .mem_rb(),
		.sb_full(sb_full), .sb_busy(sb_busy), .st_done(st_done), .st_ferr(st_ferr), .st_fatc(st_fatc), .st_fma(st_fma),
		.older_st(older_store || (exe_valid && exe_o.st_v)),   // (registered state only: timing)
		.rd_req(d_rd_req), .rd_addr(d_rd_addr), .rd_size(d_rd_size), .rd_fc(d_rd_fc),
		.rd_ack(d_rd_ack), .rd_data(d_rd_data), .rd_err(d_rd_err),
		.rd_fast(d_rd_fast), .rd_fast_data(dfp_data),
		.f_req(b_f_req), .f_addr(b_f_addr), .f_long(b_f_long), .f_fc(b_f_s ? 3'd6 : 3'd2),
		.f_gnt(b_f_gnt), .f_ack(b_f_ack), .f_data(b_f_data), .f_err(b_f_err),
		.st_err(bus_st_err),
		.mem_req(mem_req), .mem_write(mem_write), .mem_instr(mem_instr), .mem_size(mem_size),
		.mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_fc(mem_fc),
		.mem_ack(mem_ack), .mem_rdata(mem_rdata), .mem_flt(mem_flt), .mem_atc(mem_atc),
		.rd_atc(d_rd_atc), .rd_ma(d_rd_ma), .f_atc(b_f_atc),
		.tc_e(tc[15]), .tc_p(tc[14])
	);
end endgenerate

//--------------------------------------------------------------- stages
ap040_inst_fetch #(
	.PC_RESET(PC_RESET), .PROG_WORDS(PROG_WORDS), .L1_AW(L1_AW),
	.FETCH_AT_RESET(RESET_FROM_VECTORS ? 0 : 1), .LONG_ANY(BUS ? 0 : 1)
) u_if
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.redirect_valid(redirect_valid), .redirect_pc(redirect_pc), .redirect_hold(wb_smc && BUS == 0),
	.redirect_s((ex_redirect && !wb_smc) ? ex_redirect_s : sr_now[13]), .f_s(f_s),
	.q_lo(if_q_lo), .q_hi(if_q_hi),
	.consume(id_consume), .consume_nf(id_consume_nf), .fetch_hold(pmmu_busy || eaf_redir_soon),
	.f_req(f_req), .f_addr(f_addr), .f_long(f_long), .f_gnt(f_gnt), .f_ack(f_ack), .f_data(f_data),
	.f_err(f_err), .f_atc(f_atc),
	.q_e0(q_e0), .q_e1(q_e1), .pf_addr(iff_addr), .pf_long(iff_long), .pf_atc(iff_atc),
	.q_v0(q_v0), .q_v1(q_v1), .q_pc0(q_pc0), .q_w0(q_w0), .q_w1(q_w1)
);

ap040_decode #(.HAS_FPU(HAS_FPU)) u_id
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(ea_stall), .flush(flush_id),
	.q_v0(q_v0), .q_v1(q_v1), .q_pc0(q_pc0), .q_w0(q_w0), .q_w1(q_w1),
	.q_e0(q_e0), .q_e1(q_e1), .pf_addr(iff_addr), .pf_long(iff_long), .pf_atc(iff_atc),
	.consume(id_consume), .consume_nf(id_consume_nf),
	.id_redirect_valid(id_redirect_valid), .id_redirect_pc(id_redirect_pc),
	.id_valid(id_valid), .id_o(id_o), .g_lo(id_g_lo), .g_hi(id_g_hi), .g_v(id_g_v)
);

wire older_busy  = eaf_valid || exe_valid || sb_busy;   // (serialising waits for posted stores too)
// (older_store is declared above, before the bus controller uses it)
wire    early_v;
rdreq_t early_rd;

// EX-stage pending writes for EA-calc
wire        fw_w0_v;
wire  [4:0] fw_w0_r;
wire [31:0] fw_w0_val;
wire        fw_ccr_v;
wire  [4:0] fw_ccr;
wire ex_w0_pend = eaf_valid && (eaf_o.dk == DK_REG || eaf_o.cls == CL_DBCC || eaf_o.cls == CL_SCC);

ap040_ea_calc #(.HAS_FPU(HAS_FPU)) u_eac
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(eaf_stall), .flush(flush_eac),
	.id_valid(id_valid), .id_i(id_o),
	.sr_in(sr_now),
	.ra_sb(ra_sb), .ra_si(ra_si), .ra_db(ra_db), .ra_di(ra_di),
	.rd_sb(rd_sb), .rd_si(rd_si), .rd_db(rd_db), .rd_di(rd_di),
	.p_eaf_v(eac_valid), .p_eaf(eac_o), .p_eaf_blk(eaf_blk),
	.p_ex_v(eaf_valid),
	.p_ex_w0_v(ex_w0_pend), .p_ex_w0_r(eaf_o.dr),
	.p_ex_u0_v(eaf_o.u0_v || eaf_o.sp_v), .p_ex_u0_r(eaf_o.sp_v ? eaf_o.sp_r : eaf_o.u0_r),
	.p_ex_u0_val(eaf_o.sp_v ? eaf_o.sp_val : eaf_o.u0_val),
	.p_ex_u1_v(eaf_o.u1_v), .p_ex_u1_r(eaf_o.u1_r), .p_ex_u1_val(eaf_o.u1_val),
	.p_ex_store(older_store),
	.ea_stall(ea_stall),
	.early_v(early_v), .early(early_rd),
	.eac_redir_v(eac_redir_v), .eac_redir_pc(eac_redir_pc),
	.eac_valid(eac_valid), .eac_o(eac_o)
);



ap040_ea_fetch #(.STFWD(BUS ? 0 : 1), .CAS2_DC_ORDER_020(CAS2_DC_ORDER_020), .HAS_FPU(HAS_FPU), .REDIR_REG(REDIR_REG),
                 .MM_TAIL(BUS ? 1 : 0)) u_eaf
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(ex_stall), .flush(flush),
	.keep_out(ex_redir_q && ex_stall),
	.eac_valid(eac_valid), .eac_i(eac_o),
	.sr_in(sr_now), .vbr_in(vbr), .sfc_in(sfc), .dfc_in(dfc),
	.older_busy(older_busy), .older_store(older_store),
	.sync_busy((BUS != 0) && (sb_busy || fw_st_v || (exe_valid && exe_o.st_v))),
	.reset_seq(RESET_FROM_VECTORS != 0),
	.early_v(early_v), .early(early_rd),
	.ra_a(ra_a), .ra_b(ra_b), .ra_c(ra_c), .ra_d(ra_d), .rd_a(rd_a), .rd_b(rd_b), .rd_c(rd_c), .rd_d(rd_d),
	.ex_w0_v(fw_w0_v), .ex_w0_r(fw_w0_r), .ex_w0_val(fw_w0_val),
	.ex_u0_v(eaf_valid && (eaf_o.u0_v || eaf_o.sp_v)), .ex_u0_r(eaf_o.sp_v ? eaf_o.sp_r : eaf_o.u0_r),
	.ex_u0_val(eaf_o.sp_v ? eaf_o.sp_val : eaf_o.u0_val),
	.ex_u1_v(eaf_valid && eaf_o.u1_v), .ex_u1_r(eaf_o.u1_r), .ex_u1_val(eaf_o.u1_val),
	.ex_ccr_v(fw_ccr_v), .ex_ccr(fw_ccr),
	.rd_req(d_rd_req), .rd_addr(d_rd_addr), .rd_size(d_rd_size), .rd_fc(d_rd_fc),
	.rd_ack(d_rd_ack), .rd_data_raw(d_rd_data),
	.rd_err(d_rd_err), .rd_atc(d_rd_atc), .rd_ma(d_rd_ma), .bus_wdata(mem_wdata),
	.pt_req(pt_req), .pt_write(pt_write), .pt_addr(pt_addr), .pt_done(pt_done), .pt_mmusr(pt_mmusr),
	.pf_req(pf_req), .pf_mode(pf_mode), .pf_addr(pf_addr), .pf_done(pf_done),
	.bus_idle(BUS == 0 || (!mem_req && !sb_busy)), .pmmu_busy(pmmu_busy),
	.fp_req(fp_req), .fp_op_class(fp_op_class), .fp_opmode(fp_opmode),
	.fp_src_fmt(fp_src_fmt), .fp_src_r(fp_src_r), .fp_dst_r(fp_dst_r), .fp_din(fp_din),
	.fp_ia_we(fp_ia_we), .fp_ia_wdata(fp_ia_wdata),
	.fp_cr_sel(fp_cr_sel), .fp_cr_we(fp_cr_we), .fp_cr_wdata(fp_cr_wdata), .fp_cr_rdata(fp_cr_rdata),
	.fp_fm_sel(fp_fm_sel), .fp_fm_we(fp_fm_we), .fp_fm_wdata(fp_fm_wdata), .fp_fm_rdata(fp_fm_rdata),
	.fp_fpcc(fp_fpcc), .fp_bsun_en(fp_bsun_en), .fp_bsun_req(fp_bsun_req),
	.fp_used(fp_used), .fp_frst(fp_frst), .fp_fridle(fp_fridle),
	.fp_st_unimp(fp_st_unimp), .fp_st_cmd1(fp_st_cmd1), .fp_st_cmd3(fp_st_cmd3),
	.fp_st_stag(fp_st_stag), .fp_st_dtag(fp_st_dtag), .fp_st_flags(fp_st_flags),
	.fp_st_grs(fp_st_grs), .fp_st_wbte15(fp_st_wbte15),
	.fp_st_fpt(fp_st_fpt), .fp_st_et(fp_st_et),
	.fp_fsave_ack(fp_fsave_ack), .fp_fr_unimp(fp_fr_unimp),
	.fp_fr_cmd1(fp_fr_cmd1), .fp_fr_cmd3(fp_fr_cmd3),
	.fp_fr_stag(fp_fr_stag), .fp_fr_dtag(fp_fr_dtag), .fp_fr_flags(fp_fr_flags),
	.fp_fr_grs(fp_fr_grs), .fp_fr_wbte15(fp_fr_wbte15),
	.fp_fr_fpt(fp_fr_fpt), .fp_fr_et(fp_fr_et),
	.fp_st_busy(fp_st_busy), .fp_st_wbt(fp_st_wbt), .fp_st_fpiar(fp_st_fpiar),
	.fp_fr_busy(fp_fr_busy), .fp_fr_wbt(fp_fr_wbt), .fp_fr_fpiar(fp_fr_fpiar),
	.fp_fr_cusavepc(fp_fr_cusavepc), .fp_fr_et15(fp_fr_et15), .fp_fr_fpt15(fp_fr_fpt15),
	.fp_fr_resume(fp_fr_resume),
	.fp_pcap(fp_pcap), .fp_fr_e1pend(fp_fr_e1pend), .fp_cur_vec(fp_cur_vec),
	.fp_done(fp_done), .fp_accepted(fp_accepted), .fp_unimp(fp_unimp), .fp_unsupp(fp_unsupp),
	.fp_exc_req(fp_exc_req), .fp_exc_vec(fp_exc_vec),
	.fp_dout(fp_dout),
	.wb_fault(ce && wb_fault), .wb_fatm(st_fatc), .wb_fma(st_fma),
	.wb_st_a(exe_o.st_addr), .wb_st_s(exe_o.st_size), .wb_st_d(exe_o.st_data), .wb_st_f(exe_o.st_fc),
	.wb_last(exe_o.last), .wb_stf(exe_o.stf),
	.wb_st_v(retire && exe_o.st_v), .wb_st_addr(exe_o.st_addr), .wb_st_size(exe_o.st_size), .wb_st_data(exe_o.st_data),
	.ex_st_v(fw_st_v), .ex_st_addr(fw_st_addr), .ex_st_size(fw_st_size), .ex_st_data(fw_st_data),
	.eaf_stall(eaf_stall), .eaf_blk(eaf_blk),
	.eaf_valid(eaf_valid), .eaf_o(eaf_o),
	.halted(eaf_halted),
	.irq_req(irq_req), .irq_lvl(irq_lvl),
	.stopped(eaf_stopped), .rsto(eaf_rsto),
	.cinv_req(cinv_req), .cinv_ic(cinv_ic), .cinv_dc(cinv_dc),
	.cinv_done((CINV != 0) ? cinv_done : 1'b1),
	.eaf_redir_v(eaf_redir_v), .eaf_redir_pc(eaf_redir_pc), .eaf_redir_soon(eaf_redir_soon)
);

// Self-modifying code (t_integer.s "store into the fetch queue", PLAN D10):
// WB's store against every younger instruction's code -- EX's micro-op's
// (another instruction's), EA-fetch's, ID's output, the words ID has
// gathered, IF's queue and fetch in flight.  On the instruction's last
// micro-op (a hit on an earlier one waits in smc_pend) WB redirects to the
// instruction's architectural next PC and squashes everything younger,
// EX's micro-op included.  In WB, on registered state, not in EX (timing).
// On the bus the store is in memory by then (synchronous stores); on the
// L1 substrate it lands at this edge, so IF fetches a clock later.
function automatic logic ovl(input logic [31:0] a, input logic [1:0] sz, input logic v,
                             input logic [31:0] lo, input logic [31:0] hi);
	logic [31:0] e;
	e = a + ((sz == SZ_B) ? 32'd1 : (sz == SZ_W) ? 32'd2 : 32'd4);
	return v && (a < hi) && (lo < e);
endfunction
assign smc_hit = exe_valid && exe_o.st_v && !exe_o.stf.exc &&
                 (ovl(exe_o.st_addr, exe_o.st_size, eaf_valid && eaf_o.pc != exe_o.pc, eaf_o.pc, eaf_o.next_pc) ||
                  ovl(exe_o.st_addr, exe_o.st_size, eac_valid, eac_o.i.pc, eac_o.i.next_pc) ||
                  ovl(exe_o.st_addr, exe_o.st_size, id_valid, id_o.pc, id_o.next_pc) ||
                  ovl(exe_o.st_addr, exe_o.st_size, id_g_v, id_g_lo, id_g_hi) ||
                  ovl(exe_o.st_addr, exe_o.st_size, 1'b1, if_q_lo, if_q_hi));
// The refetch goes out in the store's first clock in WB, not when memory
// acknowledges it (timing: the acknowledge must not reach IF's fetch address,
// the gate build's clk_114 -> clk_38 path), once (smc_fired while WB holds
// the store).  On the bus IF's fetch cannot pass the store: the controller
// sends a store first.  EX's micro-op is squashed through EA-fetch's flush
// and in_drop; a store that then faults takes its exception as usual.
reg  smc_pend;
reg  smc_fired;
assign wb_smc = exe_valid && exe_o.last && (smc_hit || smc_pend) && !smc_fired && ce;
always @(posedge clk)
	if (!nreset) smc_fired <= 1'b0;
	else if (ce) smc_fired <= exe_valid && wb_hold && !wb_fault && (smc_fired || wb_smc);
always @(posedge clk)
	if (!nreset) smc_pend <= 1'b0;
	else if (ce && retire) smc_pend <= !exe_o.last && (smc_pend || smc_hit);

ap040_execute #(.HAS_FPU(HAS_FPU)) u_ex
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(wb_hold), .wb_drop(wb_fault), .in_drop(wb_smc),
	.eaf_valid(eaf_valid), .x(eaf_o),
	.ccr_in(sr_now[4:0]), .sr_in(sr_now),
	.sfc_in({29'd0, sfc}), .dfc_in({29'd0, dfc}), .cacr_in(cacr), .vbr_in(vbr),
	.tc_in(tc), .itt0_in(itt0), .itt1_in(itt1), .dtt0_in(dtt0), .dtt1_in(dtt1),
	.mmusr_in(mmusr), .urp_in(urp), .srp_in(srp),
	.ex_stall(ex_stall),
	.fw_w0_v(fw_w0_v), .fw_w0_r(fw_w0_r), .fw_w0_val(fw_w0_val),
	.fw_ccr_v(fw_ccr_v), .fw_ccr(fw_ccr),
	.fw_st_v(fw_st_v), .fw_st_addr(fw_st_addr), .fw_st_size(fw_st_size), .fw_st_data(fw_st_data),
	.ex_redirect(ex_redirect), .ex_redirect_pc(ex_redirect_pc), .ex_redirect_s(ex_redirect_s),
	.exe_valid(exe_valid), .exe_o(exe_o)
);

ap040_writeback u_wb
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(1'b0),
	.exe_valid(retire && exe_o.last), .exe_pc(exe_o.pc),
	.wb_stall(), .wb_valid(wb_valid), .wb_pc(wb_pc)
);

assign dbg_if_valid  = q_v0;      assign dbg_if_pc  = q_pc0;
assign dbg_id_valid  = id_valid;  assign dbg_id_pc  = id_o.pc;
assign dbg_eac_valid = eac_valid; assign dbg_eac_pc = eac_o.i.pc;
assign dbg_eaf_valid = eaf_valid; assign dbg_eaf_pc = eaf_o.pc;
assign dbg_ex_valid  = exe_valid; assign dbg_ex_pc  = exe_o.pc;
assign dbg_wb_valid  = wb_valid;  assign dbg_wb_pc  = wb_pc;

endmodule
