//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// tb_ap040_decode.v - dump S_DECODE's decision for every 16-bit opcode    //
//                                                                          //
// Stage B0/B1 of the pipeline program (AP040_PIPELINE_B0.md section 4):    //
// the classifier and control store that replace the S_DECODE case are    //
// built against ground truth, and this bench produces it.  Every opcode   //
// 0000-FFFF is placed at the reset PC with three zero extension words and //
// fed through the REAL fetch and decode path of the core, in supervisor   //
// mode as it comes out of reset; the cycle after S_DECODE the registers  //
// the decision landed in are written out, one line per opcode:           //
//                                                                          //
//   op state p_src p_dst p_sreg p_dreg alu_op op_size exec_kind p_rmw     //
//   p_wbsup imm_n r_imm_ret ea_mode ea_rn r_ea_ret exc_vec                 //
//                                                                          //
// state is the state S_DECODE went to (S_IMMF 8 = fetch imm_n extension  //
// words then r_imm_ret; S_EA_DISP 11 = EA of mode/rn then r_ea_ret;       //
// S_PIPE_START 20 = the operand pipe; S_EXC0 34 with exc_vec = an         //
// exception was raised at decode: 4 illegal, 8 privilege, 10 A-line, 11   //
// F-line; anything else = an instruction-specific state).  The core is    //
// reset between opcodes so no execution side effect leaks into the next. //
//                                                                          //
// Usage: build with Verilator (run_tests_vl.sh does not include this; it  //
// is a tool, not a regression leg), run with +out=<file>; then            //
// tests/ap040/pipe_ctrl.py <file> summarises the classes.                  //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_ap040_decode;

reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;

wire        mem_req, mem_write, mem_instr;
wire  [1:0] mem_size;
wire [31:0] mem_addr, mem_wdata;
wire  [2:0] mem_fc;
reg         mem_ack = 0;
reg  [31:0] mem_rdata = 0;
wire        pt_req, pf_req, cinv_req;

ap040_core #(
	.AP040_HAS_MMU(1),
	.AP040_HAS_FPU(1),
	.AP040_ENABLE_CACHE(1),
	.AP040_FAST_SIM(0)
) dut (
	.clk(clk), .nreset(nreset), .ce(1'b1),
	.mem_req(mem_req), .mem_write(mem_write), .mem_instr(mem_instr),
	.mem_size(mem_size), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
	.mem_fc(mem_fc), .mem_ack(mem_ack), .mem_rdata(mem_rdata),
	.mem_flt(1'b0),
	.post_busy(1'b0), .post_err(1'b0),
	.tc_out(), .urp_out(), .srp_out(),
	.itt0_out(), .itt1_out(), .dtt0_out(), .dtt1_out(),
	.pt_req(pt_req), .pt_write(), .pt_addr(), .pt_fc(),
	.pt_done(pt_req), .pt_mmusr(32'd0),
	.pf_req(pf_req), .pf_mode(), .pf_addr(), .pf_fc(), .pf_done(pf_req),
	.cinv_req(cinv_req), .cinv_ic(), .cinv_dc(), .cinv_done(cinv_req),
	.ipl(3'b111), .ipl_autovector(1'b1), .berr(1'b0),
	.nmi_ack_toggle(),
	.nresetout(), .cacr_out(), .vbr_out(),
	.debug_busy(), .debug_fault(), .debug_halted(),
	.debug_status(), .debug_status2()
);

// flat 32 KB memory on the core's own port, one-cycle acknowledge
reg [15:0] mem [0:16383];
always @(posedge clk) begin
	mem_ack <= 0;
	if (mem_req && !mem_ack) begin
		mem_ack <= 1;
		case (mem_size)
			2'd0: mem_rdata <= {24'd0, mem_addr[0] ? mem[mem_addr[14:1]][7:0]
			                                       : mem[mem_addr[14:1]][15:8]};
			2'd1: mem_rdata <= {16'd0, mem[mem_addr[14:1]]};
			default: mem_rdata <= {mem[mem_addr[14:1]], mem[mem_addr[14:1] + 1'b1]};
		endcase
		if (mem_write) begin
			case (mem_size)
				2'd0: if (mem_addr[0]) mem[mem_addr[14:1]][7:0]  = mem_wdata[7:0];
				      else             mem[mem_addr[14:1]][15:8] = mem_wdata[7:0];
				2'd1: mem[mem_addr[14:1]] = mem_wdata[15:0];
				default: begin
					mem[mem_addr[14:1]]        = mem_wdata[31:16];
					mem[mem_addr[14:1] + 1'b1] = mem_wdata[15:0];
				end
			endcase
		end
	end
end

integer fd, op, i, guard;
reg     dec_seen, dec_cap;
reg [1023:0] out_name;
// +user: the opcode runs in USER mode -- a "move.w #0,sr" precedes it
// and the capture is the SECOND S_DECODE.  A supervisor pass cannot show
// the privilege violations, which are one control-word bit.
reg     user_mode = 0;
integer dec_skip;

always @(posedge clk) begin
	dec_cap <= 0;
	if (!nreset) begin
		dec_seen <= 0;
		dec_skip <= user_mode ? 1 : 0;
	end
	else if (!dec_seen && dut.state == 8'd4) begin
		if (dec_skip != 0) dec_skip <= dec_skip - 1;
		else begin
			dec_seen <= 1;
			dec_cap  <= 1;      // the decision is visible next cycle
		end
	end
end

initial begin
	user_mode = $test$plusargs("user");
	if (!$value$plusargs("out=%s", out_name)) out_name = "build_vl/decode.txt";
	fd = $fopen(out_name, "w");
	for (op = 0; op < 65536; op = op + 1) begin
		// image: vectors, the opcode with zero extension words at $1000
		// (after a mode switch in the user pass), every exception vector
		// at $2000 (NOPs), stack at $4000
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h0000;
		mem[0] = 16'h0000; mem[1] = 16'h4000;     // ISP
		mem[2] = 16'h0000; mem[3] = 16'h1000;     // PC
		for (i = 2; i < 256; i = i + 1) begin
			mem[2*i] = 16'h0000; mem[2*i+1] = 16'h2000;
		end
		if (user_mode) begin
			mem[16'h1000 >> 1] = 16'h46FC;        // move.w #0,sr
			mem[16'h1002 >> 1] = 16'h0000;
			mem[16'h1004 >> 1] = op[15:0];
			for (i = 1; i < 8; i = i + 1) mem[(16'h1004 >> 1) + i] = 16'h0000;
		end
		else begin
			mem[16'h1000 >> 1] = op[15:0];
			for (i = 1; i < 8; i = i + 1) mem[(16'h1000 >> 1) + i] = 16'h0000;
		end
		for (i = 0; i < 16; i = i + 1) mem[(16'h2000 >> 1) + i] = 16'h4E71;

		nreset = 0;
		repeat (4) @(posedge clk);
		nreset = 1;
		guard = 0;
		while (!dec_cap && guard < 400) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (!dec_cap)
			$fwrite(fd, "%04x -1\n", op);
		else
			$fwrite(fd, "%04x %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
			        op, dut.state, dut.p_src, dut.p_dst, dut.p_sreg, dut.p_dreg,
			        dut.alu_op, dut.op_size, dut.exec_kind, dut.p_rmw, dut.p_wbsup,
			        dut.imm_n, dut.r_imm_ret, dut.ea_mode, dut.ea_rn, dut.r_ea_ret,
			        dut.exc_vec);
		@(posedge clk);
	end
	$fclose(fd);
	$display("decode dump written: %0s", out_name);
	$finish;
end

endmodule
