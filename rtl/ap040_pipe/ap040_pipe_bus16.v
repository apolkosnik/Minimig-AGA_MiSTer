//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 82)                 //
//                                                                          //
// ap040_pipe_bus16.v - the pipelined core on the 16-bit Minimig bus        //
//                                                                          //
// The third pairing of ap040_pipe_cpu.v, and the first that speaks a bus   //
// something outside this repo already talks: CPU -> ap040_pipe_membus.v -> //
// rtl/ap040/ap040_bus16_adapter.v, which is the FSM core's own adapter,    //
// instantiated here unmodified. It converts one 32-bit transaction into    //
// the 16-bit sub-cycles cpu_wrapper.v expects -- a Long into two word      //
// cycles when even, a byte/word/byte when odd -- with an idle cycle        //
// sampled between sub-cycles.                                              //
//                                                                          //
// Two enables, and they are not the same thing. `ce` advances the CPU,     //
// which stalls on its own when memory has not answered. `clkena_in`        //
// advances the BUS, and is the host's: exactly one qualified pulse         //
// completes one 16-bit sub-cycle. rtl/ap040/ap040_tg68k_compat.v hands the //
// FSM core one enable for both because that core has no internal           //
// concurrency to keep running while a transfer is outstanding; this one    //
// does, which is the point of it.                                          //
//                                                                          //
// mem_berr is tied off here. A bus error needs the access-error frame      //
// (format $7) that this core does not build yet -- deferred with the       //
// mechanism it needs, like the throwaway frame, rather than half-wired.    //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_bus16
#(
	parameter [31:0] PC_RESET   = 32'h0000_0400,
	parameter         PROG_WORDS = 10,
	parameter         RESET_VECTORS = 0   // see ap040_pipe_cpu.v
)
(
	input  clk,
	input  nreset,
	input  ce,           // advances the CPU
	input  [2:0] irq_lvl,   // the requested interrupt level, active high; 0 none
	input  clkena_in,    // advances the bus: one pulse per 16-bit sub-cycle
	input  berr,         // a physical bus error on the current sub-cycle
	// The MMU's table walker has its own physical longword port, as
	// rtl/ap040/ap040_tg68k_compat.v's does: descriptor traffic never
	// crosses the 16-bit CPU bus.
	output        walker_req,
	output        walker_we,
	output [31:0] walker_addr,
	output [31:0] walker_wdat,
	input         walker_ack,
	input  [31:0] walker_data,
	input         walker_berr,

	input  [15:0] data_in,
	output [31:0] addr_out,
	output [15:0] data_write,
	output        nwr,
	output        nuds,
	output        nlds,
	output  [1:0] busstate,
	output        longword,
	output  [2:0] fc,

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
	output [31:0] dbg_commits
);

wire [31:0] l1_addr_a, l1_addr_b, l1_data_b, l1_q_b;
wire [15:0] l1_rdata_a;
wire  [1:0] l1_size_b;
wire        l1_req_a, l1_rvalid_a, l1_rd_b, l1_rvalid_b, l1_wren_b, l1_wr_busy;
wire        l1_sup_b, l1_sup_a;
wire        l1_inval_a;
wire        l1_rflt_a, l1_rflt_b, l1_wflt, l1_flt_bus, l1_wr_sync;
wire [31:0] mmu_tc, mmu_urp, mmu_srp, mmu_itt0, mmu_itt1, mmu_dtt0, mmu_dtt1;
wire        mmu_flt;
wire        mm_req, mm_write, mm_instr, mm_ack;
wire  [1:0] mm_size;
wire [31:0] mm_addr, mm_wdata, mm_rdata;
wire  [2:0] mm_fc;
wire        l1_fc_ovr;
wire  [2:0] l1_fc_val;

wire        mem_req, mem_write, mem_instr, mem_ack;
wire  [1:0] mem_size;
wire [31:0] mem_addr, mem_wdata, mem_rdata;
wire  [2:0] mem_fc;

ap040_pipe_cpu #(
	.PC_RESET  (PC_RESET),
	.PROG_WORDS(PROG_WORDS),
	.RESET_VECTORS(RESET_VECTORS)
) u_cpu
(
	.clk (clk), .nreset (nreset), .ce (ce), .irq_lvl (irq_lvl),

	.l1_addr_a (l1_addr_a), .l1_req_a (l1_req_a),
	.l1_rdata_a(l1_rdata_a), .l1_rvalid_a(l1_rvalid_a),

	.l1_addr_b (l1_addr_b), .l1_rd_b (l1_rd_b), .l1_wren_b (l1_wren_b),
	.l1_sup_b  (l1_sup_b), .l1_sup_a (l1_sup_a),
	.l1_size_b (l1_size_b),   .l1_data_b(l1_data_b),
	.l1_wr_busy(l1_wr_busy), .l1_q_b (l1_q_b), .l1_rvalid_b(l1_rvalid_b),
	.l1_inval_a(l1_inval_a),
	.l1_rflt_a(l1_rflt_a), .l1_rflt_b(l1_rflt_b), .l1_wflt(l1_wflt), .l1_flt_bus(l1_flt_bus),
	.l1_wr_sync(l1_wr_sync),
	.mmu_tc(mmu_tc), .mmu_urp(mmu_urp), .mmu_srp(mmu_srp), .mmu_itt0(mmu_itt0), .mmu_itt1(mmu_itt1),
	.mmu_dtt0(mmu_dtt0), .mmu_dtt1(mmu_dtt1),
	.l1_fc_ovr (l1_fc_ovr), .l1_fc_val (l1_fc_val),

	.dbg_if_valid (dbg_if_valid),  .dbg_if_pc (dbg_if_pc),
	.dbg_id_valid (dbg_id_valid),  .dbg_id_pc (dbg_id_pc),
	.dbg_eac_valid(dbg_eac_valid), .dbg_eac_pc(dbg_eac_pc),
	.dbg_eaf_valid(dbg_eaf_valid), .dbg_eaf_pc(dbg_eaf_pc),
	.dbg_ex_valid (dbg_ex_valid),  .dbg_ex_pc (dbg_ex_pc),
	.dbg_wb_valid (dbg_wb_valid),  .dbg_wb_pc (dbg_wb_pc),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7),
	.dbg_ccr(dbg_ccr), .dbg_sr(dbg_sr), .dbg_commits(dbg_commits)
);

ap040_pipe_membus u_bus
(
	.clk (clk), .nreset (nreset),

	.address_a(l1_addr_a), .en_a (l1_req_a),
	.q_a      (l1_rdata_a), .rvalid_a(l1_rvalid_a),

	.address_b(l1_addr_b), .data_b(l1_data_b), .wren_b(l1_wren_b),
	.size_b   (l1_size_b),   .rd_b  (l1_rd_b),
	.wr_busy  (l1_wr_busy), .q_b  (l1_q_b), .rvalid_b(l1_rvalid_b),

	.sup      (l1_sup_a),
	.sup_b    (l1_sup_b),
	.pf_inval (l1_inval_a),
	.fc_ovr   (l1_fc_ovr), .fc_ovr_val(l1_fc_val),

	.mem_req  (mem_req),  .mem_write(mem_write), .mem_instr(mem_instr),
	.mem_size (mem_size), .mem_addr (mem_addr),  .mem_wdata(mem_wdata),
	.mem_fc   (mem_fc),   .mem_ack  (mem_ack),   .mem_rdata(mem_rdata),
	// a physical bus error ends the sub-cycle the adapter is running, on the
	// enable it aborts on
	.mem_flt  (mmu_flt || (berr && clkena_in && mem_req)),
	.mem_flt_bus(!mmu_flt && berr && clkena_in && mem_req),
	.mem_pass (mm_req),
	.wr_sync  (l1_wr_sync),
	.rflt_a   (l1_rflt_a), .rflt_b (l1_rflt_b), .wflt (l1_wflt), .flt_bus (l1_flt_bus)
);

// The MMU (2026-09-24): rtl/ap040/ap040_mmu.v, the sequential core's own,
// unmodified, on the external memory port membus drives -- which is the
// port the sequential core drives it from. ce is 1: membus runs every
// clock, and the MMU's one-cycle fault pulse must be one membus cycle.
ap040_mmu u_mmu
(
	.clk (clk), .nreset (nreset), .ce (1'b1),
	.tc (mmu_tc), .urp (mmu_urp), .srp (mmu_srp),
	.itt0 (mmu_itt0), .itt1 (mmu_itt1), .dtt0 (mmu_dtt0), .dtt1 (mmu_dtt1),
	.c_req (mem_req), .c_write (mem_write), .c_instr (mem_instr), .c_size (mem_size),
	.c_addr (mem_addr), .c_wdata (mem_wdata), .c_fc (mem_fc),
	.c_ack (mem_ack), .c_rdata (mem_rdata), .c_flt (mmu_flt),
	.pt_req (1'b0), .pt_write (1'b0), .pt_access (1'b0), .pt_addr (32'd0), .pt_fc (3'd0),
	.pt_done (), .pt_mmusr (),
	.pf_req (1'b0), .pf_mode (2'd0), .pf_addr (32'd0), .pf_fc (3'd0), .pf_done (),
	.m_req (mm_req), .m_write (mm_write), .m_instr (mm_instr), .m_size (mm_size),
	.m_addr (mm_addr), .m_wdata (mm_wdata), .m_fc (mm_fc),
	.m_ack (mm_ack), .m_rdata (mm_rdata),
	.walker_req (walker_req), .walker_we (walker_we), .walker_addr (walker_addr),
	.walker_wdat (walker_wdat), .walker_ack (walker_ack), .walker_data (walker_data),
	.walker_berr (walker_berr),
	.phys_addr (), .cache_inhibit (), .m_nocache ()
);

ap040_bus16_adapter u_bus16
(
	.clk (clk), .nreset (nreset), .clkena_in (clkena_in),

	.mem_req  (mm_req),   .mem_berr (berr),     .mem_write(mm_write),
	.mem_instr(mm_instr),  .mem_size(mm_size),  .mem_addr (mm_addr),
	.mem_wdata(mm_wdata),  .mem_fc  (mm_fc),
	.mem_ack  (mm_ack),    .mem_rdata(mm_rdata),

	.data_in   (data_in),   .addr_out(addr_out), .data_write(data_write),
	.nwr       (nwr),       .nuds    (nuds),     .nlds      (nlds),
	.busstate  (busstate),  .longword(longword), .fc        (fc)
);

endmodule
