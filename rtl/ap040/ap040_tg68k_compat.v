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

module ap040_tg68k_compat
#(
	parameter AP040_HAS_MMU      = 1,
	parameter AP040_HAS_FPU      = 0,
	parameter AP040_ENABLE_CACHE = 0,
	parameter AP040_FAST_SIM     = 0
)
(
	input         clk,
	input         nreset,
	input         clkena_in,
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
	output [255:0] debug_status
);

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
wire        mem_flt;

// MMU to bus adapter
wire        b_req, b_write, b_instr;
wire  [1:0] b_size;
wire [31:0] b_addr, b_wdata;
wire  [2:0] b_fc;
wire        b_ack;
wire [31:0] b_rdata;

// control registers and PTEST/PFLUSH sideband
wire [31:0] w_tc, w_urp, w_srp, w_itt0, w_itt1, w_dtt0, w_dtt1;
wire        pt_req, pt_write, pt_done;
wire [31:0] pt_addr, pt_mmusr;
wire  [2:0] pt_fcw;
wire        pf_req, pf_done;
wire  [1:0] pf_mode;
wire [31:0] pf_addr;

ap040_core #(
	.AP040_HAS_MMU(AP040_HAS_MMU),
	.AP040_HAS_FPU(AP040_HAS_FPU),
	.AP040_ENABLE_CACHE(AP040_ENABLE_CACHE),
	.AP040_FAST_SIM(AP040_FAST_SIM)
) core (
	.clk(clk),
	.nreset(nreset),
	.ce(clkena_in),

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

	.tc_out(w_tc),
	.urp_out(w_urp),
	.srp_out(w_srp),
	.itt0_out(w_itt0),
	.itt1_out(w_itt1),
	.dtt0_out(w_dtt0),
	.dtt1_out(w_dtt1),
	.pt_req(pt_req),
	.pt_write(pt_write),
	.pt_addr(pt_addr),
	.pt_fc(pt_fcw),
	.pt_done(pt_done),
	.pt_mmusr(pt_mmusr),
	.pf_req(pf_req),
	.pf_mode(pf_mode),
	.pf_addr(pf_addr),
	.pf_done(pf_done),

	.ipl(ipl),
	.ipl_autovector(ipl_autovector),
	.berr(berr),

	.nresetout(nresetout),
	.cacr_out(cacr_out),
	.vbr_out(vbr_out),

	.debug_busy(debug_busy),
	.debug_fault(debug_fault),
	.debug_halted(debug_halted),
	.debug_status(debug_status)
);

ap040_mmu mmu (
	.clk(clk),
	.nreset(nreset),
	.ce(clkena_in),

	.tc(w_tc),
	.urp(w_urp),
	.srp(w_srp),
	.itt0(w_itt0),
	.itt1(w_itt1),
	.dtt0(w_dtt0),
	.dtt1(w_dtt1),

	.c_req(mem_req),
	.c_write(mem_write),
	.c_instr(mem_instr),
	.c_size(mem_size),
	.c_addr(mem_addr),
	.c_wdata(mem_wdata),
	.c_fc(mem_fc),
	.c_ack(mem_ack),
	.c_rdata(mem_rdata),
	.c_flt(mem_flt),

	.pt_req(pt_req),
	.pt_write(pt_write),
	.pt_addr(pt_addr),
	.pt_fc(pt_fcw),
	.pt_done(pt_done),
	.pt_mmusr(pt_mmusr),

	.pf_req(pf_req),
	.pf_mode(pf_mode),
	.pf_addr(pf_addr),
	.pf_done(pf_done),

	.m_req(b_req),
	.m_write(b_write),
	.m_instr(b_instr),
	.m_size(b_size),
	.m_addr(b_addr),
	.m_wdata(b_wdata),
	.m_fc(b_fc),
	.m_ack(b_ack),
	.m_rdata(b_rdata),

	.phys_addr(mmu_addr_phys),
	.cache_inhibit(mmu_cache_inhibit)
);

ap040_bus16_adapter bus16 (
	.clk(clk),
	.nreset(nreset),
	.clkena_in(clkena_in),

	.mem_req(b_req),
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

assign mmu_addr_log = mem_addr;

// the table walker runs through the normal bus path; the dedicated walker
// channel of the wrapper contract stays idle
assign walker_req  = 1'b0;
assign walker_we   = 1'b0;
assign walker_addr = 32'd0;
assign walker_wdat = 32'd0;

// external cache/burst interface idle until milestone G
assign cache_req       = 1'b0;
assign cache_addr      = 32'd0;
assign cache_burst     = 1'b0;
assign cache_burst_len = 3'd0;
assign cache_ramaddr   = 28'd0;

// unused sideband inputs, referenced to keep lint quiet
wire unused_sideband = walker_ack | walker_berr | cache_ack |
                       (|walker_data) | (|cache_data);

endmodule
