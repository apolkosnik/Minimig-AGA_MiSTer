//--------------------------------------------------------------------------//
// ap040_pipe_tg68k_compat.v - the pipelined core behind the reference      //
// wrapper's ports (Minimig plan M5).  Made from lib/AP68040 (e2-fixes      //
// 530fc72) rtl/ap040_tg68k_compat.v by replacing its core and MMU          //
// instances; the cache, the 16-bit adapter, the watchdog and every tie are //
// the reference's, and so are the lifted files in this directory.          //
//--------------------------------------------------------------------------//
//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_tg68k_compat.v - top-level adapter presenting a TG68K-like port    //
// set to cpu_wrapper.v (see AP040_IMPLEMENTATION_PLAN.md section 4)        //
//                                                                          //
// The MMU/walker/cache sideband ports exist so the wrapper interface is    //
// stable across the milestones; with the MMU and caches still disabled     //
// they are tied to their idle values and the physical address equals the   //
// logical address.                                                         //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_pipe_tg68k_compat
#(
	parameter AP040_HAS_MMU      = 1,
	parameter AP040_HAS_FPU      = 1,
	// plan M11.1: register EA-fetch's redirect.  Default 0 = as built for the
	// gate image; 1 costs one clock on RTS/RTD/RTR, a memory-indirect JMP/JSR
	// and a wrongly guessed Bcc/DBcc, and takes the memory acknowledge off the
	// path that fans out into IF's prefetch queue.
	parameter AP040_REDIR_REG    = 1,
	parameter AP040_ENABLE_CACHE = 1,
	parameter AP040_FAST_SIM     = 0,
	// X3.3 A2b-1: stores to cacheable pages are acknowledged early and
	// drained by the cache.  0 is the synchronous-store A/B reference.
	parameter AP040_POST_STORES  = 1,
	// X3.4 A1: line fills over the fill channel when fill_ena says the
	// wrapper serves it.  0 is the adapter-only A/B reference.
	parameter AP040_FILL_CHANNEL = 1,
	// MinimigAGA_TC64 Stage E2: 0 leaves the 16-bit adapter out and brings the
	// cache's 32-bit master channel out on m_*, for a wrapper that owns the bus.
	parameter AP040_BUS16        = 1,
	// Plan M14 (AP68040-pipelined): the pipelined instruction read path --
	// IF's fetches are looked up in a read-only copy of the I-cache bank and
	// answered the clock after they issue, without the shared port.  Needs
	// AP040_ENABLE_CACHE; 0 is the shared-port A/B reference.
	parameter AP040_IFP          = 1
)
(
	input         clk,
	input         nreset,
	input         clkena_in,

	// Physical cacheability windows for the internal caches when no MMU
	// translation supplies CM attributes: only configured fast RAM may be
	// cached (chip RAM is chipset-DMA-written and never snooped here; IO
	// and unconfigured space must never be cached).  cache_allow_all
	// bypasses the windows for flat simulation environments.
	input         cache_allow_all,
	// chipset/DMA write snoop, already in this clock domain
	input         cache_snoop_stb,
	input  [31:0] cache_snoop_addr,
	input         cache_z2_ena,
	input   [4:0] cache_z3_base0,
	input         cache_z3_ena0,
	input   [3:0] cache_z3_base1,
	input         cache_z3_ena1,
	input  [15:0] data_in,
	input  [2:0]  ipl,
	input         ipl_autovector,
	input         berr,

	output [31:0] addr_out,
	output [15:0] data_write,
	output        nwr,
	output        nuds,
	output        nlds,
	output [1:0]  busstate,
	output        longword,
	output        nresetout,
	output [2:0]  fc,
	output        nmi_ack_toggle,
	// Line-fill channel to the wrapper (plan X3.4, A1).  The wrapper says
	// which cacheable windows the channel serves: the Zorro windows live
	// in DDR3 (fill_ena_zorro, always once ddram_ctrl has its port), the
	// chip window in the SDRAM (fill_ena_chip, dual-SDRAM builds only).
	// A fill outside a served window takes the adapter path as before.
	// A request carries the physical line address; the answer is the
	// whole line under a level-held ack, or a level-held error.
	input         fill_ena_zorro,
	input         fill_ena_chip,
	output        fill_req,
	output [31:4] fill_addr,
	input [127:0] fill_data,
	input         fill_ack,
	input         fill_err,
	// Cache-maintenance event for systems that compile out ap040_cache and
	// use an external cache on the TG68K bus instead.
	output        cache_maint_req,
	output        cache_maint_ic,
	output        cache_maint_dc,

	output [31:0] mmu_addr_log,
	output [31:0] mmu_addr_phys,
	output        mmu_cache_inhibit,

	output        walker_req,
	output        walker_we,
	output [31:0] walker_addr,
	output [31:0] walker_wdat,
	input         walker_ack,
	input  [31:0] walker_data,
	input         walker_berr,

	output        cache_req,
	output [31:0] cache_addr,
	input  [15:0] cache_data,
	input         cache_ack,
	output        cache_burst,
	output [2:0]  cache_burst_len,
	output [28:1] cache_ramaddr,

	output [31:0] cacr_out,
	output [31:0] vbr_out,
	output        debug_busy,
	output        debug_fault,
	output        debug_halted,
	output [255:0] debug_status,
	output [127:0] debug_status2,

	// Raw 32-bit master channel, for a wrapper that owns the bus itself
	// (AP040_BUS16 = 0).  With the adapter in place these still mirror it.
	output        m_req,
	output        m_write,
	output        m_instr,
	output [1:0]  m_size,
	output [31:0] m_addr,
	output [31:0] m_wdata,
	output [2:0]  m_fc,
	input         m_ack,
	input  [31:0] m_rdata
);

// Clock enable for everything above the bus adapter (plan X3.3, A2b-0).
// cpu_wrapper's clkena_in is the BUS WAIT: idle, or a qualified
// completion, or a bus error.  The adapter must keep it -- its outputs
// change only on the wrapper's qualified edges and its 16-bit sub-cycle
// sequencing is written against them.  The core, MMU and cache do not
// need it: each of their FSMs polls its acknowledge, and every signal
// that crosses from the adapter or the walker bridge (mem_ack, berr,
// c_flt, walker s_ack) was already written so that a gated consumer
// could not miss it, so a free-running one cannot either.  Gating them
// froze the whole stack for the length of every external transaction,
// which is what made a posted store worthless: the core would take one
// step and stand still until the store's last half had landed.  With a
// free enable, work that needs no port -- a released FPU op, a multiply,
// the fetch queue's bookkeeping -- proceeds during the wait.  This is
// the seed of P2's divider; a 4:1 enable on clk_114 drives the same
// wire later.
//
// MinimigAGA_TC64 DIVERGES FROM UPSTREAM HERE: re-gated to clkena_in.
// The paragraph above holds only where clkena_in is a PURE bus wait, as
// it is in the MiSTer cpu_wrapper.v ("~cpu_req | bus_complete |
// bus_berr", high on every idle cycle).  This project's wrapper --
// rtl/soc/TG68K.vhd, signal clkena -- ANDs that bus wait with the SDRAM
// controller's enaWRreg, so the enable is high on only 5 of every 16
// clk_114 phases.  ap040_bus16_adapter clears mem_ack inside "else if
// (clkena_in)", so under a duty-cycled enable the acknowledge is not a
// one-clock pulse: it stays asserted for the whole three- or four-cycle
// phase gap.  A gated cache samples it exactly once; a FREE-RUNNING
// cache reads the stale level as the acknowledge of the NEXT request and
// the machine desyncs at once.  Measured both ways on the core's own
// bench with clkena_in gated to those phases: free-running fails
// t_integer test 67 and runs away to pc=ffff6708, re-gated passes the
// whole suite.  Freeing the core here is a later stage, together with
// the multicycle island in fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc,
// which assumes every kernel register holds for at least three cycles.
wire        ce_core = clkena_in;

// core to MMU
wire        mem_req;
wire        mem_write;
wire        mem_instr;
wire  [1:0] mem_size;
wire [31:0] mem_addr;
wire [31:0] mem_wdata;
wire  [2:0] mem_fc;
wire        mem_ack;
wire [31:0] mem_rdata;
wire        mem_flt_mmu;
// Core-side stall watchdog.  Every prior watchdog counts a DOWNSTREAM
// request (CPU port, walker port), so a transaction lost between the
// core and those ports -- or a wedge in the clock-enable machinery the
// downstream layers are gated by -- stalls the core forever with every
// watchdog blind: the live NetBSD freeze shows exactly that (identical
// silent halt across three memory-path-hardened builds, no fault frame
// ever stacked).  This one watches the CORE's own held request on the
// free-running clock (a clkena wedge cannot stop the count) and injects
// an access error through the same mem_flt input the MMU uses; the
// well-tested fault path then reports it.  2^21 cycles at 28 MHz is
// ~75 ms -- beyond every legitimate stall including all downstream
// timeout chains.  If a freeze persists with no fault reported even
// with this armed, the core is not holding a request at all: a
// clock-enable or internal-FSM wedge, which is itself the decisive
// diagnostic.
wire        core_stall_flt;
ap040_bus_timeout #(.COUNTER_BITS(21)) core_stall_watchdog (
	.clk(clk),
	.nreset(nreset),
	.req(mem_req),
	.complete(mem_ack | mem_flt_mmu),
	.berr(core_stall_flt)
);
// (the reference core samples berr itself while it holds a request: mem_err
// = mem_req && (mem_flt | berr); here it reaches the core as an access error)
wire        mem_flt = mem_flt_mmu | core_stall_flt | berr;

// MMU to cache
wire        mm_req, mm_write, mm_instr;
wire  [1:0] mm_size;
wire [31:0] mm_addr, mm_wdata;
wire  [2:0] mm_fc;
wire        mm_ack, mm_nocache;
wire [31:0] mm_rdata;

// cache to bus adapter
wire        b_req, b_write, b_instr;
wire  [1:0] b_size;
wire [31:0] b_addr, b_wdata;
wire  [2:0] b_fc;
wire        b_ack;
wire [31:0] b_rdata;

// CINV sideband
wire        cinv_req, cinv_ic, cinv_dc, cinv_done;   // CINV/CPUSH (M8)

// posted-store sideband from the cache (A2b-1)
wire        post_busy, post_err;

// control registers and PTEST/PFLUSH sideband
wire [31:0] w_tc, w_urp, w_srp, w_itt0, w_itt1, w_dtt0, w_dtt1;
wire        pt_req, pt_write, pt_done;
wire [31:0] pt_addr, pt_mmusr;
wire  [2:0] pt_fcw;
wire        pf_req, pf_done;
wire  [1:0] pf_mode;
wire [31:0] pf_addr;
wire  [2:0] pf_fcw;

// The pipelined core (Minimig plan M5) in place of lib/AP68040's
// ap040_core.  The MMU sits between the core and the cache (M7); CINV is
// not requested.  The FPU (M10.1) sits beside it, as the MMU does.
wire        core_st_err;
// the core's FPU port group (plan M10.1).  With AP040_HAS_FPU = 0, which is
// what the Minimig build uses, nothing decodes to CL_FPU, fp_req stays low
// and g_nofpu's constants are exact rather than merely safe.
wire        fp_req, fp_done, fp_accepted, fp_unimp, fp_unsupp, fp_ia_we, fp_exc_req;
wire  [7:0] fp_exc_vec;
wire        fp_cr_we;
wire  [1:0] fp_cr_sel;
wire [31:0] fp_cr_wdata, fp_cr_rdata;
wire        fp_fm_we;
wire  [2:0] fp_fm_sel;
wire [95:0] fp_fm_wdata, fp_fm_rdata;
wire        fp_used, fp_frst, fp_fridle, fp_bsun_en, fp_bsun_req;
wire  [3:0] fp_fpcc;
wire        fp_st_unimp, fp_st_wbte15, fp_fsave_ack, fp_fr_unimp, fp_fr_wbte15;
wire [15:0] fp_st_cmd1, fp_st_cmd3, fp_fr_cmd1, fp_fr_cmd3;
wire  [2:0] fp_st_stag, fp_st_dtag, fp_st_flags, fp_st_grs;
wire  [2:0] fp_fr_stag, fp_fr_dtag, fp_fr_flags, fp_fr_grs;
wire [95:0] fp_st_fpt, fp_st_et, fp_fr_fpt, fp_fr_et;
wire        fp_st_busy, fp_fr_busy, fp_fr_et15, fp_fr_fpt15, fp_fr_resume;
wire [95:0] fp_st_wbt, fp_fr_wbt;
wire [31:0] fp_st_fpiar, fp_fr_fpiar;
wire  [7:0] fp_fr_cusavepc;
wire        fp_pcap, fp_fr_e1pend;
wire  [7:0] fp_cur_vec;
wire  [2:0] fp_op_class, fp_src_fmt, fp_src_r, fp_dst_r;
wire  [6:0] fp_opmode;
wire [95:0] fp_din, fp_dout;
wire [31:0] fp_ia_wdata;
wire [31:0] c_dbg_pc, c_dbg_d0, c_dbg_d1, c_dbg_d2, c_dbg_a0, c_dbg_sp, c_dbg_usp, c_dbg_isp;
wire [15:0] c_dbg_sr;
wire        c_dbg_halted;

// the instruction read path (plan M14): see the g_cache block
localparam IFP_ON = (AP040_IFP != 0) && (AP040_ENABLE_CACHE != 0);
wire        ifp_req, ifp_s, ifp_hit, ifp_try;
wire [31:0] ifp_addr, ifp_data;
// the data read path (plan M14 step 3)
wire        dfp_req, dfp_hit;
wire [31:0] dfp_addr, dfp_data;
wire  [1:0] dfp_size;
wire  [2:0] dfp_fc;

ap040_pipe_core #(
	.PC_RESET(32'h0000_0000),
	.PROG_WORDS(32'h7FFF_FFFF),
	.L1_AW(2),
	.RESET_FROM_VECTORS(1),
	.BUS(1),
	.HAS_FPU(AP040_HAS_FPU), .REDIR_REG(AP040_REDIR_REG),
	.IRQ(1),
	.CINV(1),
	.IFP(IFP_ON ? 1 : 0),
	.DFP(IFP_ON ? 1 : 0)
) core (
	.clk(clk),
	.nreset(nreset),
	.ce(ce_core),

	.dbg_if_valid(), .dbg_if_pc(), .dbg_id_valid(), .dbg_id_pc(),
	.dbg_eac_valid(), .dbg_eac_pc(), .dbg_eaf_valid(), .dbg_eaf_pc(),
	.dbg_ex_valid(), .dbg_ex_pc(), .dbg_wb_valid(), .dbg_wb_pc(c_dbg_pc),
	.dbg_d0(c_dbg_d0), .dbg_d1(c_dbg_d1), .dbg_d2(c_dbg_d2), .dbg_d3(),
	.dbg_d4(), .dbg_d5(), .dbg_d6(), .dbg_d7(),
	.dbg_ccr(), .dbg_sr(c_dbg_sr),

	.mem_req(mem_req),
	.mem_write(mem_write),
	.mem_instr(mem_instr),
	.mem_size(mem_size),
	.mem_addr(mem_addr),
	.mem_wdata(mem_wdata),
	.mem_fc(mem_fc),
	.mem_ack(mem_ack),
	.mem_rdata(mem_rdata),
	.mem_flt(mem_flt),
	.mem_atc(mem_flt_mmu),
	.bus_st_err(core_st_err),

	.cacr_q(cacr_out),
	.vbr_q(vbr_out),
	.dbg_a0(c_dbg_a0), .dbg_sp(c_dbg_sp), .dbg_usp(c_dbg_usp), .dbg_isp(c_dbg_isp),
	.dbg_halted(c_dbg_halted),
	.tc_q(w_tc), .urp_q(w_urp), .srp_q(w_srp),
	.itt0_q(w_itt0), .itt1_q(w_itt1), .dtt0_q(w_dtt0), .dtt1_q(w_dtt1),
	.pt_req(pt_req), .pt_write(pt_write), .pt_addr(pt_addr), .pt_fc(pt_fcw),
	.pt_done(pt_done), .pt_mmusr(pt_mmusr),
	.pf_req(pf_req), .pf_mode(pf_mode), .pf_addr(pf_addr), .pf_fc(pf_fcw), .pf_done(pf_done),
	.ipl(ipl), .nmi_ack_toggle(nmi_ack_toggle), .nresetout(nresetout), .dbg_stopped(),
	.cinv_req(cinv_req), .cinv_ic(cinv_ic), .cinv_dc(cinv_dc), .cinv_done(cinv_done),
	// the FPU port group (plan M10.1 step 3): the unit is instantiated below
	// under AP040_HAS_FPU, the way the MMU is.
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
	.ifp_req(ifp_req), .ifp_addr(ifp_addr), .ifp_s(ifp_s),
	.ifp_try(ifp_try), .ifp_hit(ifp_hit), .ifp_data(ifp_data),
	.dfp_req(dfp_req), .dfp_addr(dfp_addr), .dfp_size(dfp_size), .dfp_fc(dfp_fc),
	.dfp_hit(dfp_hit), .dfp_data(dfp_data)
);

// the FPU (M10.1 step 3): lifted from the reference unchanged (02ebcee),
// driven by EA-fetch's P_FPU request.  The ports this step does not use yet
// are tied off in the include, which the program bench includes too, so the
// simulated unit and the synthesised one are the same instance.
wire fp_ce = ce_core;
generate if (AP040_HAS_FPU != 0) begin : g_fpu
`include "ap040_fpu_tie.vh"
end else begin : g_nofpu
	assign fp_done = 1'b0, fp_accepted = 1'b0, fp_unimp = 1'b0, fp_unsupp = 1'b0;
	assign fp_dout = 96'd0;
	assign fp_cr_rdata = 32'd0;
	assign fp_exc_req = 1'b0, fp_exc_vec = 8'd0;
	assign fp_fm_rdata = 96'd0;
	assign fp_used = 1'b0;
assign fp_fpcc = 4'd0, fp_bsun_en = 1'b0;
	assign fp_st_unimp = 1'b0, fp_st_wbte15 = 1'b0;
	assign fp_st_cmd1 = 16'd0, fp_st_cmd3 = 16'd0;
	assign fp_st_stag = 3'd0, fp_st_dtag = 3'd0, fp_st_flags = 3'd0, fp_st_grs = 3'd0;
	assign fp_st_fpt = 96'd0, fp_st_et = 96'd0;
	assign fp_st_busy = 1'b0, fp_st_wbt = 96'd0, fp_st_fpiar = 32'd0, fp_fr_resume = 1'b0;
	assign fp_fr_e1pend = 1'b0, fp_cur_vec = 8'd0;
end endgenerate

// the MMU (M7): lifted from the reference as it is, wired as the reference
// compat wires it -- the core's request port is its c_* side, the cache
// its m_* side; PTEST/PFLUSH come from EA-fetch.  AP040_HAS_MMU = 0: a
// straight connection (physical = logical), PTEST/PFLUSH answered at once.
// the MMU's instruction-side translation for the read path (plan M14)
wire        ifp_tok, ifp_tci;
wire [31:0] ifp_pa;
wire        dfp_tok, dfp_tci;
wire [31:0] dfp_pa;

generate if (AP040_HAS_MMU != 0) begin : g_mmu
ap040_mmu #(.IFP(IFP_ON ? 1 : 0)) mmu (
	.clk(clk),
	.nreset(nreset),
	.ce(ce_core),
	.tc(w_tc), .urp(w_urp), .srp(w_srp),
	.itt0(w_itt0), .itt1(w_itt1), .dtt0(w_dtt0), .dtt1(w_dtt1),
	.c_req(mem_req), .c_write(mem_write), .c_instr(mem_instr), .c_size(mem_size),
	.c_addr(mem_addr), .c_wdata(mem_wdata), .c_fc(mem_fc),
	.walk_hold(post_busy),
	.c_ack(mem_ack), .c_rdata(mem_rdata), .c_flt(mem_flt_mmu),
	.pt_req(pt_req), .pt_write(pt_write), .pt_addr(pt_addr), .pt_fc(pt_fcw),
	.pt_done(pt_done), .pt_mmusr(pt_mmusr),
	.pf_req(pf_req), .pf_mode(pf_mode), .pf_addr(pf_addr), .pf_fc(pf_fcw), .pf_done(pf_done),
	.m_req(mm_req), .m_write(mm_write), .m_instr(mm_instr), .m_size(mm_size),
	.m_addr(mm_addr), .m_wdata(mm_wdata), .m_fc(mm_fc), .m_ack(mm_ack), .m_rdata(mm_rdata),
	.walker_req(walker_req), .walker_we(walker_we), .walker_addr(walker_addr),
	.walker_wdat(walker_wdat), .walker_ack(walker_ack), .walker_data(walker_data),
	.walker_berr(walker_berr),
	.phys_addr(mmu_addr_phys), .cache_inhibit(mmu_cache_inhibit), .m_nocache(mm_nocache),
	.ifp_en(ifp_req), .ifp_addr(ifp_addr), .ifp_s(ifp_s),
	.ifp_ok(ifp_tok), .ifp_pa(ifp_pa), .ifp_ci(ifp_tci),
	.dfp_en(dfp_req), .dfp_addr(dfp_addr), .dfp_fc(dfp_fc),
	.dfp_ok(dfp_tok), .dfp_pa(dfp_pa), .dfp_ci(dfp_tci)
);
end else begin : g_nommu
// no MMU: the read path's translation is the identity
reg [31:0] ifp_la_q;
always @(posedge clk) if (ce_core && ifp_req) ifp_la_q <= ifp_addr;
assign ifp_tok = 1'b1;
assign ifp_pa  = ifp_la_q;
assign ifp_tci = 1'b0;
reg [31:0] dfp_la_q;
reg        dfp_dsp_q;
always @(posedge clk) if (ce_core && dfp_req) begin
	dfp_la_q  <= dfp_addr;
	dfp_dsp_q <= (dfp_fc == 3'd1) || (dfp_fc == 3'd5);
end
assign dfp_tok = dfp_dsp_q;
assign dfp_pa  = dfp_la_q;
assign dfp_tci = 1'b0;
assign mm_req    = mem_req;
assign mm_write  = mem_write;
assign mm_instr  = mem_instr;
assign mm_size   = mem_size;
assign mm_addr   = mem_addr;
assign mm_wdata  = mem_wdata;
assign mm_fc     = mem_fc;
assign mm_nocache = 1'b0;
assign mem_ack   = mm_ack;
assign mem_rdata = mm_rdata;
assign mem_flt_mmu = 1'b0;
assign walker_req  = 1'b0;
assign walker_we   = 1'b0;
assign walker_addr = 32'd0;
assign walker_wdat = 32'd0;
assign mmu_addr_phys     = mem_addr;
assign mmu_cache_inhibit = 1'b0;
assign pt_done = 1'b1; assign pt_mmusr = 32'd0; assign pf_done = 1'b1;
end endgenerate

assign debug_busy     = mem_req;
assign debug_fault    = core_stall_flt | core_st_err | post_err;
assign debug_halted   = c_dbg_halted;
// the reference's layout (TG68K.vhd slices it): {16'hA040, 6'd0, fault, 0,
// state[7:0], a0, d2, d1, d0, a7, ir, sr, pc}
assign debug_status  = {16'hA040, 6'd0, debug_fault, 1'b0, 8'd0, c_dbg_a0, c_dbg_d2, c_dbg_d1, c_dbg_d0,
                        c_dbg_sp, 16'd0, c_dbg_sr, c_dbg_pc};
assign debug_status2 = {32'd0, c_dbg_usp, c_dbg_isp, 16'd0, 8'd0, 5'd0, 1'b0, debug_fault, 1'b0};

// The MMU's table walker writes U/M bits into page descriptors over its
// own port, behind the data cache.  Nothing else invalidates those lines,
// so a descriptor the CPU had previously read AS DATA would go stale --
// the last coherence hole once the internal caches are enabled (audit
// 5.5).  The walker sits inside this module, so the invalidate is
// generated here rather than plumbed through the SoC: its address is
// already physical, and the cache is physically tagged.
//
// The chipset pulse arrives from a CDC edge detector and cannot be held,
// so it wins the port; the walker's own invalidate waits at most a cycle.
// A second walker write cannot arrive that fast (each is a full memory
// transaction), so one pending slot is enough.
reg         wsnp_pend;
reg  [31:0] wsnp_addr;
reg         walker_wr_d;
wire        walker_wr_edge = (walker_req & walker_we) & ~walker_wr_d;

always @(posedge clk) begin
	if (!nreset) begin
		walker_wr_d <= 1'b0;
		wsnp_pend   <= 1'b0;
		wsnp_addr   <= 32'd0;
	end
	else begin
		walker_wr_d <= walker_req & walker_we;
		if (walker_wr_edge) begin
			wsnp_pend <= 1'b1;
			wsnp_addr <= walker_addr;
		end
		else if (wsnp_pend && !cache_snoop_stb)
			wsnp_pend <= 1'b0;      // issued on the port this cycle
	end
end

wire        snp_stb  = cache_snoop_stb | wsnp_pend;
wire [31:0] snp_addr = cache_snoop_stb ? cache_snoop_addr : wsnp_addr;

generate
if (AP040_ENABLE_CACHE != 0) begin : g_cache
	// With the snoop port wired up, chip RAM is cacheable too: a chipset
	// write invalidates the line before the CPU can see stale data.  ROM
	// and IO stay out (nothing snoops those, and IO must never be cached).
	//
	// DATA ONLY.  The snoop invalidate reaches just the D bank
	// (ap040_cache port B writes row {1'b0, set}, and store_inv
	// likewise), so the sentence above was never true of the I-cache:
	// code written into chip RAM by the blitter, trackdisk DMA, or a CPU
	// decruncher stayed stale in the I bank, and A500-era programs that
	// predate caches never CINV.  Phenomena's Enigma crashed exactly
	// here -- it runs with the internal caches forced off and fails with
	// them on, from the first commit that enabled them.  On a real 040
	// Amiga this cannot happen because 68040.library marks chip RAM
	// noncacheable through the MMU; with the MMU off, nothing does.
	// So instruction fetches from the chip window bypass the cache, and
	// only the snooped D side caches chip RAM.  cache_allow_all (the
	// benches' everything-cacheable mode; production ties it 0) keeps
	// the bypass out of simulation programs, which run at low addresses
	// and would otherwise lose all I-cache coverage.
	wire cache_chip = (mm_addr[31:21] == 11'd0);          // $000000-$1fffff
	wire cache_win =
		((mm_addr[31:27] == cache_z3_base0) && cache_z3_ena0) ||
		((mm_addr[31:28] == cache_z3_base1) && cache_z3_ena1) ||
		(!mm_addr[31:24] && (mm_addr[23] ^ |mm_addr[22:21]) && cache_z2_ena) ||
		cache_chip;
	wire cache_allow = cache_allow_all | cache_win;

	// The instruction read path (plan M14).  The core launches a lookup
	// with every fetch it issues (ifp_req includes the clock enable): the
	// cache's read-only copy of the I bank reads the set (virtually indexed:
	// the index bits lie inside the page offset) and the MMU's copy of the
	// instruction ATC translates, both in the same edge; the clock after it
	// the wrapper allows a FAST answer only where the slow path would find
	// the same line in the same bank and hand it back unchanged:
	//   * CACR.IE at the launch (the cache's own `ie`);
	//   * a translation the MMU can give without its request port: TC.E = 0,
	//     an ITT0/ITT1 hit, or an instruction-ATC hit the fetch's S bit may
	//     use (ifp_tok), and not cache-inhibited (ifp_tci = CM[1]);
	//   * the PHYSICAL address in the instruction-cacheable window -- the
	//     same formula as c_nocache below for an instruction fetch:
	//     cache_allow_all, or a configured window that is not chip RAM;
	//   * the cache's tag compare against that physical address.
	// Everything else goes the slow way and is answered as before.
	// The windows, as the read paths use them: registered here.  They are
	// autoconfig state (the chipset clock's domain, set once at boot), and
	// straight into the data path's hit decision they made a dll_28 ->
	// clk_38 path of 20 logic levels ending at the BCU's request registers.
	reg  [4:0] w_z3b0;
	reg  [3:0] w_z3b1;
	reg        w_z3e0, w_z3e1, w_z2e;
	always @(posedge clk) begin
		w_z3b0 <= cache_z3_base0; w_z3e0 <= cache_z3_ena0;
		w_z3b1 <= cache_z3_base1; w_z3e1 <= cache_z3_ena1;
		w_z2e  <= cache_z2_ena;
	end
	reg  ifp_ie_q;
	always @(posedge clk)
		if (!nreset) ifp_ie_q <= 1'b0;
		else if (ce_core) ifp_ie_q <= ifp_req && cacr_out[15];
	wire ia_chip  = (ifp_pa[31:21] == 11'd0);
	wire ia_win   =
		((ifp_pa[31:27] == w_z3b0) && w_z3e0) ||
		((ifp_pa[31:28] == w_z3b1) && w_z3e1) ||
		(!ifp_pa[31:24] && (ifp_pa[23] ^ |ifp_pa[22:21]) && w_z2e);
	wire ia_ok    = ifp_ie_q && ifp_tok && !ifp_tci &&
	                (cache_allow_all || (ia_win && !ia_chip));
	wire ifp_thit;
	assign ifp_hit = IFP_ON && ia_ok && ifp_thit;
	// ifp_try: whether the LAST fetch looked up could have been served here
	// (everything but the tag compare).  The next fetch waits for the read
	// path only then; code outside it (ROM, chip RAM, IE off) keeps going
	// straight to the shared port.  Learned from every fetch, since every
	// fetch is looked up.
	reg  ifp_try_q, ifp_launched;
	always @(posedge clk)
		if (!nreset) begin ifp_try_q <= 1'b0; ifp_launched <= 1'b0; end
		else if (ce_core) begin
			ifp_launched <= ifp_req;
			if (ifp_launched) ifp_try_q <= ia_ok;
		end
	assign ifp_try = IFP_ON && ifp_try_q;

	// The data read path (plan M14 step 3): the same for EA-fetch's reads.
	// A fast answer is allowed where the slow path would HIT the data bank
	// and return the same bytes: CACR.DE, a read that fits one aligned
	// longword (the cache's fits_long), a data space, a translation the MMU
	// gives without its request port (not cache-inhibited), and the physical
	// address in the data-cacheable window (chip RAM included: the D side is
	// snooped).  The core adds the store-order rule.
	reg  dfp_ok_q;
	always @(posedge clk)
		if (!nreset) dfp_ok_q <= 1'b0;
		else if (ce_core) dfp_ok_q <= dfp_req && cacr_out[31] &&
			((dfp_size == `AP040_SZ_B) ||
			 (dfp_size == `AP040_SZ_W && !dfp_addr[0]) ||
			 (dfp_size == `AP040_SZ_L && dfp_addr[1:0] == 2'b00));
	wire da_win =
		((dfp_pa[31:27] == w_z3b0) && w_z3e0) ||
		((dfp_pa[31:28] == w_z3b1) && w_z3e1) ||
		(!dfp_pa[31:24] && (dfp_pa[23] ^ |dfp_pa[22:21]) && w_z2e) ||
		(dfp_pa[31:21] == 11'd0);
	wire dfp_thit;
	assign dfp_hit = IFP_ON && dfp_ok_q && dfp_tok && !dfp_tci &&
	                 (cache_allow_all || da_win) && dfp_thit;

	ap040_cache #(
		.POST_STORES(AP040_POST_STORES),
		.FILL_CHANNEL(AP040_FILL_CHANNEL),
		.IFP(IFP_ON ? 1 : 0)
	) cache (
		.clk(clk),
		.nreset(nreset),
		.ce(ce_core),
		// the channel serves the cacheable windows the wrapper names;
		// cache_allow_all (the benches) counts as the Zorro capability
		.fill_ok((fill_ena_zorro & (cache_win & ~cache_chip | cache_allow_all)) |
		         (fill_ena_chip & cache_chip)),
		.fill_req(fill_req),
		.fill_addr(fill_addr),
		.fill_data(fill_data),
		.fill_ack(fill_ack),
		.fill_err(fill_err),

		.ie(cacr_out[15]),
		.de(cacr_out[31]),

		.cinv_req(cinv_req),
		.cinv_ic(cinv_ic),
		.cinv_dc(cinv_dc),
		.cinv_done(cinv_done),

		.c_req(mm_req),
		.c_write(mm_write),
		.c_instr(mm_instr),
		.c_size(mm_size),
		.c_addr(mm_addr),
		.c_wdata(mm_wdata),
		.c_fc(mm_fc),
		.c_nocache(mm_nocache | ~cache_allow |
		           (mm_instr & cache_chip & ~cache_allow_all)),
		.s_stb(snp_stb),
		.s_addr(snp_addr),
		.c_ack(mm_ack),
		.c_rdata(mm_rdata),

		.m_req(b_req),
		.m_write(b_write),
		.m_instr(b_instr),
		.m_size(b_size),
		.m_addr(b_addr),
		.m_wdata(b_wdata),
		.m_fc(b_fc),
		.m_ack(b_ack),
		.m_rdata(b_rdata),
		.m_err(berr),
		.post_busy(post_busy),
		.post_err(post_err),
		.ifp_en(ifp_req),
		.ifp_addr(ifp_addr),
		.ifp_ptag(ifp_pa[31:10]),
		.ifp_thit(ifp_thit),
		.ifp_rdata(ifp_data),
		.dfp_en(dfp_req),
		.dfp_addr(dfp_addr),
		.dfp_size(dfp_size),
		.dfp_ptag(dfp_pa[31:10]),
		.dfp_thit(dfp_thit),
		.dfp_rdata(dfp_data)
	);
end
else begin : g_nocache
	// no internal caches: the MMU talks straight to the bus adapter and
	// CINV/CPUSH complete immediately (a 68040 whose caches never fill).
	// The Minimig build uses this and relies on cpu_cache_new in the RAM
	// controllers, which also snoops chipset DMA writes.
	assign b_req    = mm_req;
	assign b_write  = mm_write;
	assign b_instr  = mm_instr;
	assign b_size   = mm_size;
	assign b_addr   = mm_addr;
	assign b_wdata  = mm_wdata;
	assign b_fc     = mm_fc;
	assign mm_ack   = b_ack;
	assign mm_rdata = b_rdata;
	assign cinv_done = 1'b1;
	assign ifp_hit   = 1'b0;    // no cache, no instruction read path
	assign ifp_try   = 1'b0;
	assign dfp_hit   = 1'b0;
	assign dfp_data  = 32'd0;
	wire unused_dfp = dfp_req | (|dfp_addr) | (|dfp_size) | (|dfp_fc);
	assign ifp_data  = 32'd0;
	wire unused_ifp = ifp_req | ifp_s | (|ifp_addr);
	assign post_busy = 1'b0;    // no cache, no buffer: stores are synchronous
	assign post_err  = 1'b0;
	assign fill_req  = 1'b0;    // no cache, no line fills
	assign fill_addr = 28'd0;
	wire unused_fill = fill_ena_zorro | fill_ena_chip | fill_ack | fill_err |
	                   (|fill_data);
	wire unused_nc = mm_nocache | cinv_req | cinv_ic | cinv_dc |
	                 (|cacr_out);
end
endgenerate

assign m_req   = b_req;
assign m_write = b_write;
assign m_instr = b_instr;
assign m_size  = b_size;
assign m_addr  = b_addr;
assign m_wdata = b_wdata;
assign m_fc    = b_fc;

generate
if (AP040_BUS16 != 0) begin : g_bus16
ap040_bus16_adapter bus16 (
	.clk(clk),
	.nreset(nreset),
	.clkena_in(clkena_in),

	.mem_req(b_req),
	.mem_berr(berr),
	.mem_write(b_write),
	.mem_instr(b_instr),
	.mem_size(b_size),
	.mem_addr(b_addr),
	.mem_wdata(b_wdata),
	.mem_fc(b_fc),
	.mem_ack(b_ack),
	.mem_rdata(b_rdata),

	.data_in(data_in),
	.addr_out(addr_out),
	.data_write(data_write),
	.nwr(nwr),
	.nuds(nuds),
	.nlds(nlds),
	.busstate(busstate),
	.longword(longword),
	.fc(fc)
);
wire unused_m = m_ack | (|m_rdata);
end
else begin : g_nobus16
assign b_ack      = m_ack;
assign b_rdata    = m_rdata;
assign addr_out   = 32'd0;
assign data_write = 16'd0;
assign nwr        = 1'b1;
assign nuds       = 1'b1;
assign nlds       = 1'b1;
assign busstate   = `AP040_BUS_IDLE;
assign longword   = 1'b0;
assign fc         = 3'd0;
wire unused_d = |data_in;
end
endgenerate

assign mmu_addr_log = mem_addr;
assign cache_maint_req = cinv_req;
assign cache_maint_ic  = cinv_ic;
assign cache_maint_dc  = cinv_dc;

// external cache/burst interface idle until milestone G
assign cache_req       = 1'b0;
assign cache_addr      = 32'd0;
assign cache_burst     = 1'b0;
assign cache_burst_len = 3'd0;
assign cache_ramaddr   = 28'd0;

// unused sideband inputs, referenced to keep lint quiet
wire unused_sideband = cache_ack | (|cache_data);

endmodule
