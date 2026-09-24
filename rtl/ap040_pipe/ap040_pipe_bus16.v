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

	.mem_req  (mem_req),  .mem_write(mem_write), .mem_instr(mem_instr),
	.mem_size (mem_size), .mem_addr (mem_addr),  .mem_wdata(mem_wdata),
	.mem_fc   (mem_fc),   .mem_ack  (mem_ack),   .mem_rdata(mem_rdata)
);

ap040_bus16_adapter u_bus16
(
	.clk (clk), .nreset (nreset), .clkena_in (clkena_in),

	.mem_req  (mem_req),  .mem_berr (berr),     .mem_write(mem_write),
	.mem_instr(mem_instr), .mem_size(mem_size), .mem_addr (mem_addr),
	.mem_wdata(mem_wdata), .mem_fc  (mem_fc),
	.mem_ack  (mem_ack),   .mem_rdata(mem_rdata),

	.data_in   (data_in),   .addr_out(addr_out), .data_write(data_write),
	.nwr       (nwr),       .nuds    (nuds),     .nlds      (nlds),
	.busstate  (busstate),  .longword(longword), .fc        (fc)
);

endmodule
