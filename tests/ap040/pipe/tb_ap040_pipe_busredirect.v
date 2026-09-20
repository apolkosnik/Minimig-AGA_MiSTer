//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 92: a redirect      //
// that lands on an acknowledgement)                                        //
//                                                                          //
// tb_ap040_pipe_busredirect.v - ap040_pipe_membus.v on its own             //
//                                                                          //
// Driven directly rather than through the core, for the same reason        //
// tb_ap040_pipe_l1_wbuf.v drives the array directly: the event under test  //
// is a COINCIDENCE, and the only way to test a coincidence is to create    //
// it. Reaching it through a program means waiting for a mispredict to land //
// on the exact cycle a fetch is acknowledged, which depends on the memory  //
// latency of the day.                                                      //
//                                                                          //
// Instruction fetch is restartable. A new en_a abandons whatever was in    //
// flight and asks for the new address, which is what the array does and    //
// what ap040_inst_fetch.v assumes when a branch redirects it.              //
//                                                                          //
// The wrapper meant to handle that -- it compares the in-flight address    //
// against a_addr and drops the word if they differ. The comparison cannot  //
// see a redirect accepted in the SAME cycle, because a_addr is written     //
// with a non-blocking assignment earlier in the same block and still reads //
// as the OLD address there. So the branch is taken, the obsolete word is   //
// published as valid, and a_pend is cleared -- which also cancels the      //
// request for the new address that the redirect had just set up.           //
//                                                                          //
// The fetch stage then runs the wrong opcode and never asks for the right  //
// one.                                                                     //
//                                                                          //
// Three phases:                                                            //
//                                                                          //
//   1. A plain fetch of $400: request, acknowledge, and the word must      //
//      arrive. This is the control -- it proves the coincidence in phase 2 //
//      is what makes the difference, not the sequence in general.          //
//   2. Request $400, then in the cycle the bus acknowledges it, assert     //
//      en_a for $800. The word for $400 must NOT become valid, and $800    //
//      must go out on the bus afterwards.                                  //
//   3. A back-to-back sequential fetch, which is the pattern that must     //
//      keep working: rvalid_a is a register, so the fetch stage sees it    //
//      the cycle AFTER the acknowledgement and issues its next request     //
//      then. Acknowledgement and request never coincide in that flow, and  //
//      if a fix suppressed them together every sequential fetch would be   //
//      thrown away.                                                        //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

`include "ap040_pipe_defs.svh"

module tb_ap040_pipe_busredirect;

reg clk = 0;
reg nreset = 0;
always #5 clk = ~clk;

reg  [31:0] address_a = 32'd0;
reg         en_a      = 1'b0;
wire [15:0] q_a;
wire        rvalid_a;

reg  [31:0] address_b = 32'd0;
reg  [31:0] data_b    = 32'd0;
reg         wren_b    = 1'b0;
reg   [1:0] size_b    = `AP040_SZ_L;
reg         rd_b      = 1'b0;
wire        wr_busy;
wire [31:0] q_b;
wire        rvalid_b;

wire        mem_req, mem_write, mem_instr;
wire  [1:0] mem_size;
wire [31:0] mem_addr, mem_wdata;
wire  [2:0] mem_fc;
reg         mem_ack   = 1'b0;
reg  [31:0] mem_rdata = 32'd0;

ap040_pipe_membus dut (
	.clk(clk), .nreset(nreset),
	.address_a(address_a), .en_a(en_a), .q_a(q_a), .rvalid_a(rvalid_a),
	.address_b(address_b), .data_b(data_b), .wren_b(wren_b),
	.size_b(size_b), .rd_b(rd_b), .wr_busy(wr_busy),
	.q_b(q_b), .rvalid_b(rvalid_b),
	.sup(1'b1),
	.mem_req(mem_req), .mem_write(mem_write), .mem_instr(mem_instr),
	.mem_size(mem_size), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
	.mem_fc(mem_fc),
	.mem_ack(mem_ack), .mem_rdata(mem_rdata)
);

integer errors = 0;

// The word each address answers with, so a wrong word names its own address.
function [15:0] word_at;
	input [31:0] a;
	begin
		word_at = (a == 32'h0000_0400) ? 16'h4444 :
		          (a == 32'h0000_0800) ? 16'h8888 :
		          (a == 32'h0000_0402) ? 16'h4402 : 16'hDEAD;
	end
endfunction

task step; begin @(posedge clk); #1; end endtask

initial begin
	nreset = 0;
	repeat (2) @(posedge clk);
	#1 nreset = 1;
	step;

	// ---------------------------------------------- phase 1: a plain fetch
	en_a = 1'b1; address_a = 32'h0000_0400;
	step;
	en_a = 1'b0;
	// The request reaches the bus on the cycle after it is accepted.
	while (!mem_req) step;
	if (mem_addr !== 32'h0000_0400 || !mem_instr) begin
		errors = errors + 1;
		$display("FAIL: phase 1 put %h on the bus (instr=%b), expected 00000400 as a fetch", mem_addr, mem_instr);
	end
	mem_ack = 1'b1; mem_rdata = {16'h0000, word_at(mem_addr)};
	step;
	mem_ack = 1'b0;
	if (!rvalid_a || q_a !== 16'h4444) begin
		errors = errors + 1;
		$display("FAIL: phase 1 delivered rvalid=%b q=%h, expected 1 and 4444", rvalid_a, q_a);
	end
	step;

	// ------------------------------- phase 2: a redirect ON the acknowledge
	en_a = 1'b1; address_a = 32'h0000_0400;
	step;
	en_a = 1'b0;
	while (!mem_req) step;
	if (mem_addr !== 32'h0000_0400) begin
		errors = errors + 1;
		$display("FAIL: phase 2 put %h on the bus, expected 00000400", mem_addr);
	end
	// The coincidence: acknowledge $400 while accepting a redirect to $800.
	mem_ack = 1'b1; mem_rdata = {16'h0000, word_at(mem_addr)};
	en_a = 1'b1; address_a = 32'h0000_0800;
	step;
	mem_ack = 1'b0; en_a = 1'b0;
	if (rvalid_a) begin
		errors = errors + 1;
		$display("FAIL: the abandoned fetch of $0400 was published as valid (q = %h) although a redirect to $0800 was accepted in the same cycle",
		         q_a);
	end
	// ...and the redirect must still be wanted.
	while (!mem_req) begin
		step;
		if (mem_req === 1'b0) begin end
	end
	if (mem_addr !== 32'h0000_0800) begin
		errors = errors + 1;
		$display("FAIL: after the redirect the bus asked for %h, expected 00000800", mem_addr);
	end
	mem_ack = 1'b1; mem_rdata = {16'h0000, word_at(mem_addr)};
	step;
	mem_ack = 1'b0;
	if (!rvalid_a || q_a !== 16'h8888) begin
		errors = errors + 1;
		$display("FAIL: the redirected fetch delivered rvalid=%b q=%h, expected 1 and 8888", rvalid_a, q_a);
	end
	step;

	// --------------------------- phase 3: the ordinary back-to-back pattern
	en_a = 1'b1; address_a = 32'h0000_0400;
	step;
	en_a = 1'b0;
	while (!mem_req) step;
	mem_ack = 1'b1; mem_rdata = {16'h0000, word_at(mem_addr)};
	step;
	mem_ack = 1'b0;
	if (!rvalid_a || q_a !== 16'h4444) begin
		errors = errors + 1;
		$display("FAIL: phase 3's first word came back as rvalid=%b q=%h, expected 1 and 4444", rvalid_a, q_a);
	end
	// The next request goes out in the cycle rvalid_a is SEEN, which is the
	// cycle after the acknowledgement -- never the same one.
	en_a = 1'b1; address_a = 32'h0000_0402;
	step;
	en_a = 1'b0;
	while (!mem_req) step;
	if (mem_addr !== 32'h0000_0402) begin
		errors = errors + 1;
		$display("FAIL: phase 3's second request asked for %h, expected 00000402", mem_addr);
	end
	mem_ack = 1'b1; mem_rdata = {16'h0000, word_at(mem_addr)};
	step;
	mem_ack = 1'b0;
	if (!rvalid_a || q_a !== 16'h4402) begin
		errors = errors + 1;
		$display("FAIL: phase 3's second word came back as rvalid=%b q=%h, expected 1 and 4402 -- a sequential fetch must not be discarded",
		         rvalid_a, q_a);
	end

	if (errors == 0)
		$display("ALL TESTS PASSED");
	else
		$display("%0d CHECK(S) FAILED", errors);

	$finish;
end

// A stuck run should say so rather than hang the suite.
initial begin
	#200000;
	$display("FAIL: timed out");
	$finish;
end

endmodule
