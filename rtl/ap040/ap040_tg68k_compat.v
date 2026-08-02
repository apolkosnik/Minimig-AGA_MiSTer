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

wire        mem_req;
wire        mem_write;
wire        mem_instr;
wire  [1:0] mem_size;
wire [31:0] mem_addr;
wire [31:0] mem_wdata;
wire  [2:0] mem_fc;
wire        mem_ack;
wire [31:0] mem_rdata;

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

ap040_bus16_adapter bus16 (
	.clk(clk),
	.nreset(nreset),
	.clkena_in(clkena_in),

	.mem_req(mem_req),
	.mem_write(mem_write),
	.mem_instr(mem_instr),
	.mem_size(mem_size),
	.mem_addr(mem_addr),
	.mem_wdata(mem_wdata),
	.mem_fc(mem_fc),
	.mem_ack(mem_ack),
	.mem_rdata(mem_rdata),

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

// MMU disabled: physical equals logical, nothing is cache inhibited yet
assign mmu_addr_log      = mem_addr;
assign mmu_addr_phys     = mem_addr;
assign mmu_cache_inhibit = 1'b0;

// table walker idle until the 040 MMU lands (milestone E)
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
