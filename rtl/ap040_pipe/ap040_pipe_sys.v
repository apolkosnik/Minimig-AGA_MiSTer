//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 81)                 //
//                                                                          //
// ap040_pipe_sys.v - the CPU on a bus instead of an array                  //
//                                                                          //
// The second of the two pairings ap040_pipe_cpu.v supports:                //
// ap040_pipe_core.v puts the array behind it for the milestone benches,    //
// this puts ap040_pipe_membus.v and a real memory port behind it. Nothing  //
// in the CPU differs between them.                                         //
//                                                                          //
// The port below is rtl/ap040/ap040_core.v's, so the next step is          //
// ap040_bus16_adapter.v underneath this without touching either side.      //
//                                                                          //
// One consequence of the CPU emitting byte addresses (milestone 81) shows  //
// up here and not in ap040_pipe_core.v: the exception vector table is at   //
// its architectural place, vector n at byte 4n, rather than aliased into   //
// the array's window the way every tb_ap040_pipe_*.v sees it (word index   //
// 3584 + 2n, which is 4n - PC_RESET wrapped). VBR is still not consulted   //
// for the fetch itself -- that is unchanged, and unrelated.                //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_sys
#(
	parameter [31:0] PC_RESET   = 32'h0000_0400,
	parameter         PROG_WORDS = 10
)
(
	input  clk,
	input  nreset,
	input  ce,

	output        mem_req,
	output        mem_write,
	output        mem_instr,
	output  [1:0] mem_size,
	output [31:0] mem_addr,
	output [31:0] mem_wdata,
	output  [2:0] mem_fc,
	input         mem_ack,
	input  [31:0] mem_rdata,

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

ap040_pipe_cpu #(
	.PC_RESET  (PC_RESET),
	.PROG_WORDS(PROG_WORDS)
) u_cpu
(
	.clk (clk), .nreset (nreset), .ce (ce),

	.l1_addr_a (l1_addr_a), .l1_req_a (l1_req_a),
	.l1_rdata_a(l1_rdata_a), .l1_rvalid_a(l1_rvalid_a),

	.l1_addr_b (l1_addr_b), .l1_rd_b (l1_rd_b), .l1_wren_b (l1_wren_b),
	.l1_size_b (l1_size_b),   .l1_data_b(l1_data_b),
	.l1_wr_busy(l1_wr_busy), .l1_q_b (l1_q_b), .l1_rvalid_b(l1_rvalid_b),

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

	.sup      (dbg_sr[13]),

	.mem_req  (mem_req),  .mem_write(mem_write), .mem_instr(mem_instr),
	.mem_size (mem_size), .mem_addr (mem_addr),  .mem_wdata(mem_wdata),
	.mem_fc   (mem_fc),   .mem_ack  (mem_ack),   .mem_rdata(mem_rdata)
);

endmodule
