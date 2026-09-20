//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 81)                 //
//                                                                          //
// ap040_pipe_membus.v - the two CPU memory ports onto one bus transaction  //
//                                                                          //
// CPU side: ap040_pipe_l1.v's protocol exactly, so ap040_pipe_cpu.v cannot //
// tell which of the two it is attached to -- byte addresses, a request and //
// a return per port, one outstanding read on port B, writes posted behind  //
// wr_busy.                                                                 //
//                                                                          //
// Bus side: rtl/ap040/ap040_core.v's own external port, verbatim, so that  //
// ap040_bus16_adapter.v and the TG68K-shaped wrapper around it can be      //
// attached without reshaping anything: mem_req is held until mem_ack,      //
// mem_ack is a single-cycle pulse with mem_rdata valid, and the requester  //
// drops mem_req in the ack cycle. One transaction at a time; this module   //
// leaves one idle cycle between them rather than holding mem_req high      //
// across a new address, which is what that adapter's "one stable bus       //
// request at a time" contract asks for.                                    //
//                                                                          //
// Ordering: a posted write goes out BEFORE any read that is waiting. The   //
// L1 array answers a read from its write buffer when the two collide;      //
// draining first gets the same answer from memory and needs no forwarding  //
// path here. Reads then beat fetches, because a fetch can always be        //
// re-issued and a load cannot.                                             //
//                                                                          //
// Port A restarts: a redirect can change address_a while a fetch is on the //
// bus. That transaction cannot be recalled, so its result is discarded and //
// the new address re-issued -- the CPU never sees the stale word, which is //
// the same guarantee ap040_pipe_l1.v gives by restarting its port A.       //
//                                                                          //
// Transaction sizes: a fetch is a Word, a data read is always a Longword   //
// (port B's contract), and a write is sized from be_b -- 1111 Long, 1100   //
// Word, 0110 Word at an odd address, 1000 Byte at the even address, 0100   //
// Byte at the odd one. Those five are the only patterns                    //
// ap040_ea_fetch.v's st_be and ap040_execute.v's ex_st_be produce.         //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_membus
(
	input             clk,
	input             nreset,

	// ---- CPU side: ap040_pipe_l1.v's port protocol ----
	input      [31:0] address_a,
	input             en_a,
	output reg [15:0] q_a,
	output reg        rvalid_a,

	input      [31:0] address_b,
	input      [31:0] data_b,
	input             wren_b,
	input       [3:0] be_b,
	input             rd_b,
	output            wr_busy,
	output reg [31:0] q_b,
	output reg        rvalid_b,

	// The supervisor bit, for the function code alone.
	input             sup,

	// ---- bus side: ap040_core.v's external memory port ----
	output reg        mem_req,
	output reg        mem_write,
	output reg        mem_instr,
	output reg  [1:0] mem_size,
	output reg [31:0] mem_addr,
	output reg [31:0] mem_wdata,
	output reg  [2:0] mem_fc,
	input             mem_ack,
	input      [31:0] mem_rdata
);

localparam [1:0] WHO_A = 2'd0, WHO_BR = 2'd1, WHO_BW = 2'd2;

reg        busy;        // a transaction is on the bus
reg  [1:0] who;         // whose it is
reg [31:0] cur_addr_a;  // the address the in-flight FETCH was started for

reg        a_pend;      // a fetch is wanted and has not been returned
reg [31:0] a_addr;
reg        b_pend;      // a data read is wanted and has not been returned
reg [31:0] b_addr;
reg        w_pend;      // a write has been accepted and has not been sent
reg [31:0] w_addr, w_data;
reg  [1:0] w_size;

// The requester must hold its write until this drops -- as with the array's
// one-entry buffer, the write is accepted the cycle wr_busy is low.
assign wr_busy = w_pend;

// A write's true byte address and right-aligned data, from the lane mask.
wire [31:0] addr_b_even = {address_b[31:1], 1'b0};
// 0110 is a Word at an ODD address (milestone 85), which goes out as a Word
// transaction there: ap040_bus16_adapter.v splits an odd word into two byte
// cycles, so nothing below has to know.
wire [31:0] wr_addr = (be_b == 4'b0100 || be_b == 4'b0110) ? (addr_b_even + 32'd1)
                                                           : addr_b_even;
wire  [1:0] wr_size = (be_b == 4'b1111) ? `AP040_SZ_L :
                      (be_b == 4'b1100 || be_b == 4'b0110) ? `AP040_SZ_W : `AP040_SZ_B;
wire [31:0] wr_data = (be_b == 4'b1111) ? data_b :
                      (be_b == 4'b1100) ? {16'd0, data_b[31:16]} :
                      (be_b == 4'b0110) ? {16'd0, data_b[23:8]}  :
                      (be_b == 4'b1000) ? {24'd0, data_b[31:24]}
                                        : {24'd0, data_b[23:16]};

function [2:0] fc_of;
	input is_instr;
	begin
		fc_of = sup ? (is_instr ? `AP040_FC_SUPER_PROG : `AP040_FC_SUPER_DATA)
		            : (is_instr ? `AP040_FC_USER_PROG  : `AP040_FC_USER_DATA);
	end
endfunction

always @(posedge clk) begin
	if (!nreset) begin
		busy <= 1'b0; who <= WHO_A; cur_addr_a <= 32'd0;
		a_pend <= 1'b0; b_pend <= 1'b0; w_pend <= 1'b0;
		a_addr <= 32'd0; b_addr <= 32'd0;
		w_addr <= 32'd0; w_data <= 32'd0; w_size <= `AP040_SZ_L;
		rvalid_a <= 1'b0; rvalid_b <= 1'b0;
		q_a <= 16'd0; q_b <= 32'd0;
		mem_req <= 1'b0; mem_write <= 1'b0; mem_instr <= 1'b0;
		mem_size <= `AP040_SZ_L; mem_addr <= 32'd0; mem_wdata <= 32'd0;
		mem_fc <= `AP040_FC_SUPER_PROG;
	end else begin
		// ---- new requests ----
		if (en_a) begin
			a_addr   <= {address_a[31:1], 1'b0};
			a_pend   <= 1'b1;
			rvalid_a <= 1'b0;
		end
		if (rd_b) begin
			b_addr   <= addr_b_even;
			b_pend   <= 1'b1;
			rvalid_b <= 1'b0;
		end
		if (wren_b && !w_pend) begin
			w_addr <= wr_addr;
			w_data <= wr_data;
			w_size <= wr_size;
			w_pend <= 1'b1;
		end

		// ---- the bus ----
		if (busy) begin
			if (mem_ack) begin
				busy    <= 1'b0;
				mem_req <= 1'b0;   // dropped in the ack cycle, per the contract
				case (who)
				WHO_A: begin
					// ...unless a redirect moved the fetch while it was out.
					// a_addr may already be the NEW address, in which case
					// this word belongs to nobody and a_pend stays set.
					if (cur_addr_a == a_addr) begin
						q_a      <= mem_rdata[15:0];
						rvalid_a <= 1'b1;
						a_pend   <= 1'b0;
					end
				end
				WHO_BR: begin
					q_b      <= mem_rdata;
					rvalid_b <= 1'b1;
					b_pend   <= 1'b0;
				end
				default: w_pend <= 1'b0;   // WHO_BW
				endcase
			end
		end else if (w_pend && !(wren_b && !w_pend)) begin
			busy      <= 1'b1;  who <= WHO_BW;
			mem_req   <= 1'b1;  mem_write <= 1'b1;  mem_instr <= 1'b0;
			mem_size  <= w_size; mem_addr <= w_addr; mem_wdata <= w_data;
			mem_fc    <= fc_of(1'b0);
		end else if (b_pend) begin
			busy      <= 1'b1;  who <= WHO_BR;
			mem_req   <= 1'b1;  mem_write <= 1'b0;  mem_instr <= 1'b0;
			mem_size  <= `AP040_SZ_L; mem_addr <= b_addr;
			mem_fc    <= fc_of(1'b0);
		end else if (a_pend) begin
			busy       <= 1'b1;  who <= WHO_A;
			cur_addr_a <= a_addr;
			mem_req    <= 1'b1;  mem_write <= 1'b0;  mem_instr <= 1'b1;
			mem_size   <= `AP040_SZ_W; mem_addr <= a_addr;
			mem_fc     <= fc_of(1'b1);
		end
	end
end

endmodule
