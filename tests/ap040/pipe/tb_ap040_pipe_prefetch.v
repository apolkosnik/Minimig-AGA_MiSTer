//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (2026-09-24: prefetch)         //
//                                                                          //
// tb_ap040_pipe_prefetch.v - the bus bridge's instruction stream buffer    //
//                                                                          //
// ap040_pipe_membus.v fetches aligned longwords into a four-entry window   //
// ahead of the fetch unit. On ap040_pipe_sys.v, through a memory that      //
// answers in 1 to 8 cycles:                                                //
//   a DIVU.W holds EX while the fetch unit and the window run ahead; the //
//     MOVE.W behind it patches a MOVEQ seven words on, which by then is   //
//     in the window but not in the pipe: the patched value must run -- a  //
//     store into the window empties it, and goes out before the refetch  //
//   a DBF loop with a load in it: data reads between prefetches           //
//   BRA.B +6 inside the window, over three poison MOVEQ #-1,D4            //
//   BRA.W to $4A2, past the window and into the middle of a longword      //
//   MOVE #$0000,SR, then an instruction that must be fetched with the     //
//     user-program function code: the window was filled as supervisor,    //
//     and a change of privilege empties it                                 //
// D5 $55, D6 $66, D7 $77; D3 4 (the loop ran four times), D2 $FFFF; D1    //
// the loaded $CAFEF00D; D4 0; D0 $23; SR $0000.                            //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps
`include "ap040_pipe_defs.svh"

module tb_ap040_pipe_prefetch;

localparam PROG_WORDS      = 160;
localparam [31:0] PC_RESET = 32'h0000_0400;
localparam integer MEM_WORDS = 32768;

reg clk = 0;
reg nreset = 0;
reg ce = 1;

always #5 clk = ~clk;

`ifdef AP040_PIPE_CE_RANDOM
reg [15:0] ce_lfsr = 16'hACE1;
always @(negedge clk) if (nreset) begin
	ce_lfsr <= {ce_lfsr[14:0], ce_lfsr[15] ^ ce_lfsr[13] ^ ce_lfsr[12] ^ ce_lfsr[10]};
	ce      <= ce_lfsr[0];
end
`endif

wire        mem_req, mem_write, mem_instr;
wire  [1:0] mem_size;
wire [31:0] mem_addr, mem_wdata;
wire  [2:0] mem_fc;
reg         mem_ack;
reg  [31:0] mem_rdata;

wire        dbg_if_valid,  dbg_id_valid,  dbg_eac_valid;
wire        dbg_eaf_valid, dbg_ex_valid,  dbg_wb_valid;
wire [31:0] dbg_if_pc,     dbg_id_pc,     dbg_eac_pc;
wire [31:0] dbg_eaf_pc,    dbg_ex_pc,     dbg_wb_pc;
wire [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5, dbg_d6, dbg_d7;
wire  [4:0] dbg_ccr;
wire [15:0] dbg_sr;
wire [31:0] dbg_commits;

ap040_pipe_sys #(
	.PC_RESET  (PC_RESET),
	.PROG_WORDS(PROG_WORDS)
) dut
(
	.clk (clk), .nreset (nreset), .ce (ce),
	.mem_req (mem_req), .mem_write(mem_write), .mem_instr(mem_instr),
	.mem_size(mem_size), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
	.mem_fc  (mem_fc),   .mem_ack (mem_ack),  .mem_rdata(mem_rdata),
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

// The memory: word storage, big endian, 1 to 8 cycles from a fixed seed.
reg [15:0] mem [0:MEM_WORDS-1];
integer i;
reg [15:0] lfsr;
reg  [2:0] delay;
reg        active;
wire [31:0] widx = mem_addr >> 1;
reg  [2:0] fc_last [0:MEM_WORDS/2-1];   // the function code each longword was last fetched with

always @(posedge clk) begin
	if (!nreset) begin
		active <= 1'b0; mem_ack <= 1'b0; delay <= 3'd0; lfsr <= 16'hBEEF;
	end else begin
		mem_ack <= 1'b0;
		if (!active && mem_req && !mem_ack) begin
			active <= 1'b1;
			delay  <= lfsr[2:0];
			lfsr   <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
			if (mem_instr) fc_last[mem_addr >> 2] = mem_fc;
		end else if (active) begin
			if (delay == 3'd0) begin
				active  <= 1'b0;
				mem_ack <= 1'b1;
				if (mem_write) begin
					case (mem_size)
					`AP040_SZ_L: begin
						mem[widx]     <= mem_wdata[31:16];
						mem[widx + 1] <= mem_wdata[15:0];
					end
					`AP040_SZ_W: mem[widx] <= mem_wdata[15:0];
					default: begin
						if (mem_addr[0]) mem[widx][7:0]  <= mem_wdata[7:0];
						else             mem[widx][15:8] <= mem_wdata[7:0];
					end
					endcase
					mem_rdata <= 32'h0;
				end else begin
					case (mem_size)
					`AP040_SZ_L: mem_rdata <= {mem[widx], mem[widx + 1]};
					`AP040_SZ_W: mem_rdata <= {16'd0, mem[widx]};
					default:     mem_rdata <= {24'd0, mem_addr[0] ? mem[widx][7:0]
					                                              : mem[widx][15:8]};
					endcase
				end
			end else
				delay <= delay - 3'd1;
		end
	end
end

integer errors = 0;

task check32;
	input string  what;
	input [31:0]  got, want;
	begin
		if (got !== want) begin
			errors = errors + 1;
			$display("FAIL: %0s = %h, expected %h", what, got, want);
		end
	end
endtask

task poke;
	input [31:0] addr;
	input [15:0] word;
	begin mem[addr >> 1] = word; end
endtask

initial begin
	for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = `AP040_OP_NOP;
	for (i = 0; i < MEM_WORDS / 2; i = i + 1) fc_last[i] = 3'd0;
	for (i = 32'h043A; i < 32'h04A2; i = i + 2) poke(i, 16'h78FF);   // poison up to the far target

	poke(32'h0400, 16'h7064);                                   // $400 MOVEQ #100,D0
	poke(32'h0402, 16'h80FC);  poke(32'h0404, 16'h0007);        // $402 DIVU.W #7,D0: EX held while the front end fills
	poke(32'h0406, 16'h31FC);  poke(32'h0408, 16'h7A55);  poke(32'h040A, 16'h0418); // $406 MOVE.W #$7A55,$0418.W  patch: MOVEQ #$55,D5
	poke(32'h040C, 16'h4E71);                                   // $40C NOP
	poke(32'h040E, 16'h4E71);                                   // $40E NOP
	poke(32'h0410, 16'h4E71);                                   // $410 NOP
	poke(32'h0412, 16'h4E71);                                   // $412 NOP
	poke(32'h0414, 16'h4E71);                                   // $414 NOP
	poke(32'h0416, 16'h4E71);                                   // $416 NOP
	poke(32'h0418, 16'h7A11);                                   // $418 MOVEQ #$11,D5  (patched): in the window, not yet in the pipe
	poke(32'h041A, 16'h7C66);                                   // $41A MOVEQ #$66,D6
	poke(32'h041C, 16'h7E77);                                   // $41C MOVEQ #$77,D7
	poke(32'h041E, 16'h4E71);                                   // $41E NOP
	poke(32'h0420, 16'h7403);                                   // $420 MOVEQ #3,D2                loop counter
	poke(32'h0422, 16'h7600);                                   // $422 MOVEQ #0,D3
	poke(32'h0424, 16'h5283);                                   // $424 ADDQ.L #1,D3
	poke(32'h0426, 16'h2238);  poke(32'h0428, 16'h0800);        // $426 MOVE.L $0800.W,D1          a load in the loop
	poke(32'h042A, 16'h51CA);  poke(32'h042C, 16'hFFF8);        // $42A DBF D2,loop
	poke(32'h042E, 16'h6006);                                   // $42E BRA.B +6                   inside the window
	poke(32'h0430, 16'h78FF);                                   // $430 MOVEQ #-1,D4               poison
	poke(32'h0432, 16'h78FF);                                   // $432 poison
	poke(32'h0434, 16'h78FF);                                   // $434 poison
	poke(32'h0436, 16'h6000);  poke(32'h0438, 16'h006A);        // $436 BRA.W far                  past it, mid-longword
	poke(32'h04A2, 16'h7022);                                        // $4A2 MOVEQ #$22,D0            the far target
	poke(32'h04A4, 16'h46FC);                                        // $4A4 MOVE #$0000,SR           user mode
	poke(32'h04A6, 16'h0000);
	poke(32'h04A8, 16'h5280);                                        // $4A8 ADDQ.L #1,D0             fetched as user program
	poke(32'h04AA, 16'h60FE);                                        // $4AA BRA.B -2

	poke(32'h0800, 16'hCAFE); poke(32'h0802, 16'hF00D);
end

initial begin
	nreset = 0;
	repeat (2) @(posedge clk);
	nreset = 1;
	@(posedge clk);
	dut.u_cpu.u_regfile.isp = 32'h0000_0600;

	repeat ((PROG_WORDS + 4000) * `AP040_PIPE_WAIT_SCALE) @(posedge clk);

	check32("D5 (patched MOVEQ)", dbg_d5, 32'h0000_0055);
	check32("D6", dbg_d6, 32'h0000_0066);
	check32("D7", dbg_d7, 32'h0000_0077);
	check32("D3 (loop iterations)", dbg_d3, 32'h0000_0004);
	check32("D2 (DBF counter)", dbg_d2, 32'h0000_FFFF);
	check32("D1 (the load)", dbg_d1, 32'hCAFE_F00D);
	check32("D4 (poison never ran)", dbg_d4, 32'h0000_0000);
	check32("D0 (far target, then user mode)", dbg_d0, 32'h0000_0023);
	check32("SR", {16'd0, dbg_sr}, 32'h0000_0000);
	check32("function code $4A8 was fetched with", {29'd0, fc_last[32'h04A8 >> 2]}, {29'd0, `AP040_FC_USER_PROG});

	if (errors == 0)
		$display("ALL TESTS PASSED");
	else
		$display("%0d CHECK(S) FAILED", errors);

	$finish;
end

endmodule
