//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 82)                 //
//                                                                          //
// ap040_pipe_bus16.v - the pipelined core on the 16-bit Minimig bus        //
//                                                                          //
// The third pairing of ap040_pipe_cpu.v, and the first that speaks a bus   //
// something outside this repo already talks: CPU -> ap040_pipe_membus.v   //
// (port B through the data memory unit, ap040_pipe_dmu.v; both ports       //
// translated through ap040_pipe_mmu.v) ->                                  //
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
wire [15:0] l1_rdata_a, l1_rdata_a2;
wire  [1:0] l1_size_b;
wire        l1_req_a, l1_rvalid_a, l1_rd_b, l1_rvalid_b, l1_wren_b;
wire        l1_wr_busy_w;   // the CPU's: see ap040_pipe_membus.v
wire        l1_sup_b, l1_sup_a;
wire        l1_inval_a;
wire        l1_rflt_a, l1_rflt_a_bus, l1_rflt_b, l1_wflt, l1_flt_bus, l1_flt_ma, l1_wr_sync;
wire [31:0] mmu_tc, mmu_urp, mmu_srp, mmu_itt0, mmu_itt1, mmu_dtt0, mmu_dtt1;
wire        l1_idle, l1_quiet, l1_wr_drop, pt_req, pt_write, pt_done, pf_req, pf_done;
wire [31:0] pt_addr, pt_mmusr, pf_addr;
wire  [2:0] pt_fc, pf_fc;
wire  [1:0] pf_mode;
wire        l1_fc_ovr;
wire  [2:0] l1_fc_val;

// the MMU's two translation ports: instruction (the bus controller's
// stream), data (the DMU)
wire        i_req, i_sup, i_pass, i_flt, ip_sup, ip_hit;
wire [31:0] i_addr, i_pa, ip_addr, ip_pa;
wire        d_req, d_write, d_acc, d_sup, d_pass, d_flt;
wire [31:0] d_addr, d_pa;
wire        dmu_wr_pend;

// the bus controller's port B, physical, from the DMU
wire [31:0] bb_addr, bb_la, bb_wdata, bb_q, bb_rx_addr;
wire  [1:0] bb_size, bb_rx_size;
wire        bb_rd, bb_wr, bb_sup, bb_fc_ovr, bb_rvalid, bb_wr_busy_w, bb_rflt, bb_flt_bus, bb_flt_ma, bb_idle;
wire        bb_rx;
wire  [2:0] bb_fc_val, bb_rx_fc;

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
	.l1_rdata_a(l1_rdata_a), .l1_rdata_a2(l1_rdata_a2), .l1_rvalid_a(l1_rvalid_a),

	.l1_addr_b (l1_addr_b), .l1_rd_b (l1_rd_b), .l1_wren_b (l1_wren_b),
	.l1_sup_b  (l1_sup_b), .l1_sup_a (l1_sup_a),
	.l1_size_b (l1_size_b),   .l1_data_b(l1_data_b),
	.l1_wr_busy(l1_wr_busy_w), .l1_q_b (l1_q_b), .l1_rvalid_b(l1_rvalid_b),
	.l1_inval_a(l1_inval_a),
	.l1_rflt_a(l1_rflt_a), .l1_rflt_a_bus(l1_rflt_a_bus), .l1_rflt_b(l1_rflt_b), .l1_wflt(l1_wflt), .l1_flt_bus(l1_flt_bus),
	.l1_flt_ma(l1_flt_ma), .l1_wr_sync(l1_wr_sync),
	.l1_idle (l1_idle), .l1_quiet (l1_quiet), .l1_wr_drop (l1_wr_drop), .pt_req (pt_req), .pt_write (pt_write), .pt_addr (pt_addr), .pt_fc (pt_fc),
	.pt_done (pt_done), .pt_mmusr (pt_mmusr), .pf_req (pf_req), .pf_mode (pf_mode), .pf_addr (pf_addr),
	.pf_fc (pf_fc), .pf_done (pf_done),
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

// The data memory unit (doc_AP040_PIPELINE_CACHES.md, stage A): port B's
// logical addresses translated through the MMU's data port, physical ones
// handed to the bus controller. Port A's stream is translated by the bus
// controller itself until the instruction memory unit comes with its cache
// (stage B): see ap040_pipe_membus.v's header.
ap040_pipe_dmu u_dmu
(
	.clk (clk), .nreset (nreset),
	.xlat (l1_wr_sync), .tc_e (mmu_tc[15]), .tc_p (mmu_tc[14]),
	.c_addr (l1_addr_b), .c_rd (l1_rd_b), .c_wr (l1_wren_b), .c_size (l1_size_b), .c_wdata (l1_data_b),
	.c_sup (l1_sup_b), .c_fc_ovr (l1_fc_ovr), .c_fc_val (l1_fc_val), .c_wr_drop (l1_wr_drop),
	.c_q (l1_q_b), .c_rvalid (l1_rvalid_b), .c_wr_busy_w (l1_wr_busy_w), .c_rflt (l1_rflt_b),
	.c_wflt (l1_wflt), .c_flt_bus (l1_flt_bus), .c_flt_ma (l1_flt_ma), .c_idle (l1_idle),
	.wr_pend (dmu_wr_pend),
	.d_req (d_req), .d_write (d_write), .d_acc (d_acc), .d_addr (d_addr), .d_sup (d_sup),
	.d_pass (d_pass), .d_flt (d_flt), .d_pa (d_pa),
	.m_addr (bb_addr), .m_la (bb_la), .m_rd (bb_rd), .m_wr (bb_wr), .m_size (bb_size), .m_wdata (bb_wdata),
	.m_sup (bb_sup), .m_fc_ovr (bb_fc_ovr), .m_fc_val (bb_fc_val),
	.m_rx (bb_rx), .m_rx_addr (bb_rx_addr), .m_rx_size (bb_rx_size), .m_rx_fc (bb_rx_fc),
	.m_q (bb_q), .m_rvalid (bb_rvalid), .m_wr_busy_w (bb_wr_busy_w), .m_rflt (bb_rflt),
	.m_flt_bus (bb_flt_bus), .m_flt_ma (bb_flt_ma), .m_idle (bb_idle)
);

// The MMU (2026-09-25): rtl/ap040/ap040_mmu.v's rules and ATC with a
// translation port for each memory port (ap040_pipe_mmu.v), no longer below
// the bus controller. Its walker waits while a write the DMU accepted has
// still to reach memory.
ap040_pipe_mmu u_mmu
(
	.clk (clk), .nreset (nreset),
	.tc (mmu_tc), .urp (mmu_urp), .srp (mmu_srp),
	.itt0 (mmu_itt0), .itt1 (mmu_itt1), .dtt0 (mmu_dtt0), .dtt1 (mmu_dtt1),
	.i_req (i_req), .i_addr (i_addr), .i_sup (i_sup), .i_pass (i_pass), .i_flt (i_flt), .i_pa (i_pa), .i_cm (),
	.ip_addr (ip_addr), .ip_sup (ip_sup), .ip_hit (ip_hit), .ip_pa (ip_pa),
	.d_req (d_req), .d_write (d_write), .d_acc (d_acc), .d_addr (d_addr), .d_sup (d_sup),
	.d_pass (d_pass), .d_flt (d_flt), .d_pa (d_pa), .d_cm (),
	.pt_req (pt_req), .pt_write (pt_write), .pt_access (1'b0), .pt_addr (pt_addr), .pt_fc (pt_fc),
	.pt_done (pt_done), .pt_mmusr (pt_mmusr),
	.pf_req (pf_req), .pf_mode (pf_mode), .pf_addr (pf_addr), .pf_fc (pf_fc), .pf_done (pf_done),
	.walk_hold (dmu_wr_pend),
	.walker_req (walker_req), .walker_we (walker_we), .walker_addr (walker_addr),
	.walker_wdat (walker_wdat), .walker_ack (walker_ack), .walker_data (walker_data),
	.walker_berr (walker_berr)
);

// The instruction memory unit: port A's prefetch window, and the fetch's
// translation through the MMU's instruction port (TC.E).
wire        f_req, f_sup, f_free, f_ack, f_flt, f_flt_bus, f_w_accept;
wire [31:0] f_addr;
wire [29:0] f_w_sla;
ap040_pipe_imu u_imu
(
	.clk (clk), .nreset (nreset),
	.address_a(l1_addr_a), .en_a (l1_req_a),
	.q_a      (l1_rdata_a), .q_a2 (l1_rdata_a2), .rvalid_a(l1_rvalid_a),
	.rflt_a   (l1_rflt_a), .rflt_a_bus (l1_rflt_a_bus),
	.sup      (l1_sup_a), .pf_inval (l1_inval_a), .quiesce (l1_quiet),
	.pf_xlat  (mmu_tc[15]), .x_req (i_req), .x_addr (i_addr), .x_sup (i_sup),
	.x_pass   (i_pass), .x_flt (i_flt), .x_pa (i_pa),
	.pk_addr  (ip_addr), .pk_sup (ip_sup), .pk_hit (ip_hit), .pk_pa (ip_pa),
	.f_req    (f_req), .f_addr (f_addr), .f_sup (f_sup), .f_free (f_free),
	.f_ack    (f_ack), .f_rdata (mem_rdata), .f_flt (f_flt), .f_flt_bus (f_flt_bus),
	.w_accept (f_w_accept), .w_sla (f_w_sla)
);

ap040_pipe_membus u_bus
(
	.clk (clk), .nreset (nreset),

	.f_req    (f_req), .f_addr (f_addr), .f_sup (f_sup), .f_free (f_free),
	.f_ack    (f_ack), .f_flt (f_flt), .f_flt_bus (f_flt_bus),
	.w_accept (f_w_accept), .w_sla (f_w_sla),

	.address_b(bb_addr), .la_b(bb_la), .data_b(bb_wdata), .wren_b(bb_wr),
	.size_b   (bb_size),   .rd_b  (bb_rd),
	.wr_busy  (), .wr_busy_w(bb_wr_busy_w), .q_b  (bb_q), .rvalid_b(bb_rvalid),

	.sup_b    (bb_sup),
	.fc_ovr   (bb_fc_ovr), .fc_ovr_val(bb_fc_val),

	.mem_req  (mem_req),  .mem_write(mem_write), .mem_instr(mem_instr),
	.mem_size (mem_size), .mem_addr (mem_addr),  .mem_wdata(mem_wdata),
	.mem_fc   (mem_fc),   .mem_ack  (mem_ack),   .mem_rdata(mem_rdata),
	// Everything arriving here has been translated: the only refusal left
	// is a physical bus error, which ends the sub-cycle the adapter is
	// running, on the enable it aborts on. A request has passed as soon as
	// it is on the port, and no write is tentative any more -- the DMU held
	// each one until its translation passed.
	.mem_flt  (berr && clkena_in && mem_req),
	.mem_flt_bus(berr && clkena_in && mem_req),
	.mem_pass (mem_req),
	.wr_sync  (1'b0),
	.rflt_b   (bb_rflt), .wflt (), .flt_bus (bb_flt_bus),
	.idle     (bb_idle), .wr_drop (1'b0),
	// The DMU splits a transfer that crosses a page and probes nothing here.
	.xlat_e   (1'b0), .xlat_p (1'b0),
	.pb_req   (), .pb_addr (), .pb_fc (), .pb_done (1'b0), .pb_mmusr (32'd0),
	.flt_ma   (bb_flt_ma),
	// the DMU's translated reads
	.rx (bb_rx), .rx_addr (bb_rx_addr), .rx_size (bb_rx_size), .rx_fc (bb_rx_fc)
);

ap040_bus16_adapter u_bus16
(
	.clk (clk), .nreset (nreset), .clkena_in (clkena_in),

	.mem_req  (mem_req),   .mem_berr (berr),     .mem_write(mem_write),
	.mem_instr(mem_instr), .mem_size(mem_size),  .mem_addr (mem_addr),
	.mem_wdata(mem_wdata), .mem_fc  (mem_fc),
	.mem_ack  (mem_ack),   .mem_rdata(mem_rdata),

	.data_in   (data_in),   .addr_out(addr_out), .data_write(data_write),
	.nwr       (nwr),       .nuds    (nuds),     .nlds      (nlds),
	.busstate  (busstate),  .longword(longword), .fc        (fc)
);

endmodule
