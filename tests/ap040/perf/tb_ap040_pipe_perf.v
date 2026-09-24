//--------------------------------------------------------------------------//
// AP040_PIPE - instruction throughput bench (restructuring plan, phase 0)  //
//                                                                          //
// tb_ap040_pipe_perf.v - steady-state cycles per instruction block         //
//                                                                          //
// The program is 128 copies of one block (one or more instructions,        //
// +stride words each) and then BRA.S *. The bench measures the cycles      //
// from the 16th block's first instruction completing to the 112th's: 96    //
// steady intervals, after the warm-up. Built two ways:                      //
//   (default)          ap040_pipe_core.v, the local behavioural L1         //
//   AP040_PERF_BUS     ap040_pipe_sys.v, membus on a 32-bit port with      //
//                      +wait=N cycles before each acknowledge              //
// The registers start from fixed values (D1 27, D2 3, D3 8, A0 $1000,      //
// A1 $1800, A4 $1800, A5 $2000, SR $2700) set before the first fetch, so   //
// every case's operands are the same run to run.                           //
//                                                                          //
// Reported, and checked by run_pipe_perf.py:                               //
//   RESULT  cycles over the 96 intervals                                   //
//   COUNT   instructions retired in them (must be 96 x the block's),       //
//           port-B reads issued and writes accepted, and on the bus the    //
//           fetch, read and write transactions                             //
//   STALL   cycles each hold was up in them (they overlap; not exclusive)  //
//   EXC     exceptions taken anywhere in the run (must be 0)               //
// It is a throughput probe, not a correctness test: the dual and program   //
// benches judge results.                                                   //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps
`include "ap040_pipe_defs.svh"

module tb_ap040_pipe_perf;

reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;

reg [1023:0] prog;
integer stride = 1, wait_n = 0, delay_count = 0;
integer i, k, n;
integer cycles = 0, first = -1, last = -1, seen = 0;
reg [15:0] words [0:4095];
reg  [7:0] memory [0:8191];

`ifdef AP040_PERF_BUS
wire [31:0] addr, wdata;
wire  [1:0] sz;
wire        req, wr, instr;
reg         ack = 0;
reg  [31:0] rdata = 0;
ap040_pipe_sys #(.PROG_WORDS(2000)) dut
(
	.clk (clk), .nreset (nreset), .ce (1'b1), .irq_lvl (3'd0),
	.mem_req (req), .mem_write (wr), .mem_instr (instr), .mem_size (sz), .mem_addr (addr),
	.mem_wdata (wdata), .mem_ack (ack), .mem_rdata (rdata)
);
`else
ap040_pipe_core #(.PROG_WORDS(2000)) dut (.clk (clk), .nreset (nreset), .ce (1'b1), .irq_lvl (3'd0));
`endif

// An instruction completes as it leaves EX into WB, once (exe_fresh).
wire        boundary = dut.u_cpu.exe_valid && dut.u_cpu.exe_fresh;
wire [31:0] op_pc    = dut.u_cpu.exe_pc;
wire        in_win   = nreset && (first >= 0) && (last < 0);

integer w_mem = 0, w_addr = 0, w_port = 0, w_bf = 0, w_mvm = 0, w_fp = 0, w_mul = 0, w_div = 0;
integer retired = 0, rd_b = 0, wr_b = 0, bus_f = 0, bus_r = 0, bus_w = 0, excs = 0;
reg     exc_q = 0;
always @(posedge clk) begin
	if (in_win) begin
		w_mem  = w_mem  + (dut.u_cpu.u_eaf.mem_issue || (dut.u_cpu.u_eaf.mem_pending && !dut.u_cpu.u_eaf.l1_rvalid_b));
		w_addr = w_addr + dut.u_cpu.u_eaf.addr_hz;
		w_port = w_port + dut.u_cpu.u_eaf.port_taken;
		w_bf   = w_bf   + dut.u_cpu.u_eaf.bf_stall;
		w_mvm  = w_mvm  + dut.u_cpu.u_eaf.mvm_stall;
		w_fp   = w_fp   + dut.u_cpu.u_eaf.fp_stall;
		w_mul  = w_mul  + dut.u_cpu.u_ex.mul_wait;
		w_div  = w_div  + dut.u_cpu.u_ex.div_wait;
		rd_b   = rd_b   + dut.u_cpu.l1_rd_b;
		wr_b   = wr_b   + (dut.u_cpu.l1_wren_b && !dut.u_cpu.l1_wr_busy);
		retired = retired + boundary;
`ifdef AP040_PERF_BUS
		if (req && ack) begin
			if (instr)   bus_f = bus_f + 1;
			else if (wr) bus_w = bus_w + 1;
			else         bus_r = bus_r + 1;
		end
`endif
	end
	exc_q <= dut.u_cpu.u_eaf.exc_go;
	if (nreset && dut.u_cpu.u_eaf.exc_go && !exc_q) excs = excs + 1;
end

`ifdef AP040_PERF_BUS
// The 32-bit port: right-aligned by size both ways, the program at $400.
always @(posedge clk) begin
	ack <= 1'b0;
	if (nreset && req && !ack) begin
		if (delay_count < wait_n) delay_count <= delay_count + 1;
		else begin
			delay_count <= 0;
			ack <= 1'b1;
			n = (sz == `AP040_SZ_B) ? 1 : (sz == `AP040_SZ_W) ? 2 : 4;
			if (wr) begin
				for (k = 0; k < n; k = k + 1) memory[(addr + k) & 8191] <= wdata >> ((n - k - 1) * 8);
			end else
				rdata <= (n == 1) ? {24'd0, memory[addr & 8191]} :
				         (n == 2) ? {16'd0, memory[addr & 8191], memory[(addr + 1) & 8191]} :
				                    {memory[addr & 8191], memory[(addr + 1) & 8191],
				                     memory[(addr + 2) & 8191], memory[(addr + 3) & 8191]};
		end
	end
end
`endif

// Block boundaries: the first instruction of blocks 16 and 112.
always @(posedge clk)
	if (nreset) begin
		cycles = cycles + 1;
		if (boundary && op_pc >= 32'h400 + 16*stride*2 && op_pc <= 32'h400 + 112*stride*2 &&
		    ((op_pc - 32'h400) % (stride*2) == 0)) begin
			if (op_pc == 32'h400 + 16*stride*2)  first = cycles;
			if (op_pc == 32'h400 + 112*stride*2) last  = cycles;
			seen = seen + 1;
		end
	end

initial begin
	if (!$value$plusargs("stride=%d", stride)) $fatal(1, "missing +stride");
	if (!$value$plusargs("prog=%s", prog))     $fatal(1, "missing +prog");
	if ($value$plusargs("wait=%d", wait_n)) begin end
	for (i = 0; i < 4096; i = i + 1) words[i] = 16'h4E71;
	$readmemh(prog, words, 0, 128*stride);
	if (words[128*stride] !== 16'h60FE) $fatal(1, "the image does not end in BRA.S * after 128 blocks of %0d words", stride);
	for (i = 0; i < 8192; i = i + 1) memory[i] = 8'h00;
	for (i = 0; i < 128*stride + 1; i = i + 1) begin
		memory[(i*2 + 1024) & 8191] = words[i][15:8];
		memory[(i*2 + 1025) & 8191] = words[i][7:0];
	end
	#1;
`ifndef AP040_PERF_BUS
	for (i = 0; i < 4096; i = i + 1) dut.u_l1.mem[i] = words[i];
	for (i = 1536; i < 3584; i = i + 1) dut.u_l1.mem[i] = 16'h0000;   // the data, $1000-$23FF
`endif
	repeat (3) @(negedge clk);
	nreset = 1;
	dut.u_cpu.sr = 16'h2700;
	dut.u_cpu.u_regfile.dreg[1] = 27;
	dut.u_cpu.u_regfile.dreg[2] = 3;
	dut.u_cpu.u_regfile.dreg[3] = 8;
	dut.u_cpu.u_regfile.areg[0] = 32'h1000;
	dut.u_cpu.u_regfile.areg[1] = 32'h1800;
	dut.u_cpu.u_regfile.areg[4] = 32'h1800;
	dut.u_cpu.u_regfile.areg[5] = 32'h2000;
	for (i = 0; i < 60000 && last < 0; i = i + 1) @(negedge clk);
	repeat (20) @(negedge clk);
	if (first < 0 || last < 0 || seen != 97)
		$display("FAIL: first=%0d last=%0d boundaries=%0d (want 97)", first, last, seen);
	else
		$display("RESULT cycles=%0d intervals=96", last - first);
	$display("COUNT retired=%0d rd=%0d wr=%0d bus_fetch=%0d bus_read=%0d bus_write=%0d",
	         retired, rd_b, wr_b, bus_f, bus_r, bus_w);
	$display("STALL mem=%0d addr=%0d port=%0d bf=%0d movem=%0d fp=%0d mul=%0d div=%0d",
	         w_mem, w_addr, w_port, w_bf, w_mvm, w_fp, w_mul, w_div);
	$display("EXC %0d", excs);
	$finish;
end

endmodule
