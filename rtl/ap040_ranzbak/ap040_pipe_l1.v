//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_pipe_l1.v - unified memory stand-in (rewritten for Minimig plan M1) //
//                                                                          //
// The test substrate the pipeline runs on until M5 puts the real bus       //
// behind it (then this file goes).  2**AW 16-bit words; a byte address a   //
// maps to word (a - PC_RESET) >> 1 (wrapped to the array), the convention  //
// every milestone bench pokes mem[] with.                                  //
//                                                                          //
//   port A  instruction fetch: word index in, the two words at index and   //
//           index+1 out one clock later (32 bits, IF's two words a clock),  //
//           held while en_a is low                                         //
//   port R  data read: rd_req (one clock) with byte address and size       //
//           B/W/L; rd_ack and the right-aligned data one clock later.  Any //
//           alignment: an odd word or long is assembled from its bytes (the //
//           real 040 bus splits it; M68040UM 7.3, p. 7-6 -- this model does //
//           it in one access)                                              //
//   port W  data write: wr_req with byte address, size, right-aligned      //
//           data; written at the clock edge.  wr_ready is always 1 here.   //
//           A read requested in the clock of a write sees the write        //
//           (write first), as WB's store is older than EA-fetch's load.    //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_l1
#(
	parameter AW = 12,                      // word address width
	parameter DW = 16,
	parameter [31:0] PC_RESET = 32'h0000_0400
)
(
	input                clock,
	input                nreset,

	input      [AW-1:0]  address_a,
	input                en_a,
	output reg [31:0]    q_a,

	input                rd_req,
	input       [31:0]   rd_addr,
	input        [1:0]   rd_size,
	output reg           rd_ack,
	output reg  [31:0]   rd_data,

	input                wr_req,
	input       [31:0]   wr_addr,
	input        [1:0]   wr_size,
	input       [31:0]   wr_data,
	output               wr_ready
);

reg [DW-1:0] mem [0:(1<<AW)-1];
integer i;
initial for (i = 0; i < (1<<AW); i = i + 1) mem[i] = `AP040_OP_NOP;

assign wr_ready = 1'b1;

function automatic [AW-1:0] widx(input [31:0] a);
	reg [31:0] t;
	begin
		t = (a - PC_RESET) >> 1;
		widx = t[AW-1:0];
	end
endfunction

function automatic [7:0] rbyte(input [31:0] a);
	reg [15:0] w;
	begin
		w = mem[widx(a)];
		rbyte = a[0] ? w[7:0] : w[15:8];
	end
endfunction

function automatic [2:0] nbytes(input [1:0] sz);
	nbytes = (sz == 2'd0) ? 3'd1 : (sz == 2'd1) ? 3'd2 : 3'd4;
endfunction

reg  [31:0] rv;
reg  [31:0] ba;
reg  [15:0] w;
reg   [7:0] b;
integer     k, n;

`ifdef SYNTHESIS
// A test substrate, never part of a synthesised design: with BUS = 1 nothing
// drives it, and its variable-length byte loops do not synthesise.
always @(posedge clock) begin
	q_a <= 32'd0; rd_ack <= 1'b0; rd_data <= 32'd0;
end
`else
always @(posedge clock) begin
	if (en_a) q_a <= {mem[address_a], mem[address_a + 1'b1]};
	if (!nreset) begin
		rd_ack <= 1'b0;
	end else begin
		// write first (blocking, so the read below sees it)
		if (wr_req) begin
			n = nbytes(wr_size);
			for (k = 0; k < n; k = k + 1) begin
				ba = wr_addr + k;
				b  = wr_data >> (8 * (n - 1 - k));
				w  = mem[widx(ba)];
				if (ba[0]) w[7:0] = b; else w[15:8] = b;
				mem[widx(ba)] = w;
			end
		end
		rd_ack <= rd_req;
		if (rd_req) begin
			n = nbytes(rd_size);
			rv = 32'd0;
			for (k = 0; k < n; k = k + 1)
				rv = (rv << 8) | rbyte(rd_addr + k);
			rd_data <= rv;
		end
	end
end
`endif

endmodule
