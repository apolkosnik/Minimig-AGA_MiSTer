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
// Transaction sizes: data accesses carry the CPU's own size and address,  //
// at whatever alignment, and the adapter below splits them (milestone 86). //
//                                                                          //
// Instruction prefetch (2026-09-24). Fetching one Word per transaction,    //
// and only once the previous word had been handed over, held the pipeline  //
// to 4 cycles per instruction on a zero-wait bus where the sequential core //
// ran at 2. Fetches are now aligned longwords into a four-entry stream     //
// buffer that runs ahead of the fetch unit whenever the bus has nothing    //
// else to do. A request inside the buffered window is answered the next   //
// cycle -- the timing the L1 array's port A gives, so ap040_inst_fetch.v   //
// issues back to back -- and the window slides forward to it. A request    //
// for the longword on the bus waits for it; anything else is a redirect:   //
// the window is emptied, the read in flight is discarded when it returns,  //
// and the stream restarts at the new address. A CPU write that touches the //
// window or the read in flight empties it, and writes go out before the   //
// refetch, so a store into the instruction stream is fetched. A change of  //
// privilege does the same, so every word carries its own function code.   //
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
	input      [31:0] data_b,      // right-aligned by size_b
	input             wren_b,
	input       [1:0] size_b,
	input             rd_b,
	output            wr_busy,
	output reg [31:0] q_b,
	output reg        rvalid_b,

	// The supervisor bit, for the function code alone. Two of them: port A
	// is the instruction fetch's and port B is the data access's OWN, which
	// an exception entry forces supervisor whatever the status register
	// still says (milestone 92).
	input             sup,
	input             sup_b,
	// CINV/CPUSH: empty the window. The refetch that follows arrives in the
	// same cycle and must go to memory, not to what the window held.
	input             pf_inval,

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

reg        a_pend;      // a fetch is wanted and has not been returned
reg [31:0] a_addr;

// The prefetch stream. Entry i holds the longword whose address bits [3:2]
// are i; the window is pf_cnt longwords from pf_base, never more than four,
// so no two of them share an entry and nothing is ever shifted. The next
// longword to fetch -- and the one on the bus, if pf_out -- is always
// pf_base + 4 * pf_cnt: sliding the window forward adds to the one what it
// takes from the other.
localparam [2:0] PF_N = 3'd4;
reg [31:0] pf_q [0:3];
reg [29:0] pf_base;     // longword address
reg  [2:0] pf_cnt;
reg        pf_out;      // a prefetch read is on the bus
reg        pf_kill;     // ...for a window since emptied: drop it when it returns
reg        pf_sup;      // the privilege the stream was fetched under
reg        pf_live;     // the fetch unit has asked for something since reset
reg        b_pend;      // a data read is wanted and has not been returned
reg [31:0] b_addr;
reg  [1:0] b_size;
reg        w_pend;      // a write has been accepted and has not been sent
reg [31:0] w_addr, w_data;
reg  [1:0] w_size;
// Captured WITH each request, not read when the transaction is finally
// sent: a posted write can sit here across the very commit that changes the
// privilege, and would then go out under the wrong one.
reg        a_sup, b_sup, w_sup;

// The requester must hold its write until this drops -- as with the array's
// one-entry buffer, the write is accepted the cycle wr_busy is low.
assign wr_busy = w_pend;

// Port B is sized (milestone 86), so address, size and data go out as they
// arrive: ap040_bus16_adapter.v splits whatever alignment they have.
function [2:0] fc_of;
	input is_instr;
	input priv;
	begin
		fc_of = priv ? (is_instr ? `AP040_FC_SUPER_PROG : `AP040_FC_SUPER_DATA)
		             : (is_instr ? `AP040_FC_USER_PROG  : `AP040_FC_USER_DATA);
	end
endfunction

// This cycle's view of the window, with a prefetch that returns now already
// in it -- a request in the same cycle must see it.
wire        pf_ack     = busy && mem_ack && (who == WHO_A);
wire        pf_app     = pf_ack && !pf_kill;
wire [29:0] pf_next    = pf_base + {27'd0, pf_cnt};
wire  [2:0] pf_cnt1    = pf_cnt + {2'd0, pf_app};
function [31:0] pf_word1;   // entry i, including the longword arriving now
	input [1:0] i;
	begin
		pf_word1 = (pf_app && (i == pf_next[1:0])) ? mem_rdata : pf_q[i];
	end
endfunction
wire [29:0] req_lw     = address_a[31:2];
wire [29:0] req_k      = req_lw - pf_base;
// ...and not from a longword a write accepted this same cycle touches: the
// window's copy is stale by then, and a refetch the write itself caused
// (a store onto an instruction already fetched behind it) asks for exactly
// that longword in exactly that cycle. It then misses, and queues behind the
// write. (w_lo/w_hi are declared below; the tools take either order.)
wire        req_wr     = w_accept && ((w_lo == req_lw) || (w_hi == req_lw));
wire        req_hit    = !pf_inval && !req_wr && (req_k < {27'd0, pf_cnt1}) && (sup == pf_sup);
wire [31:0] req_long   = pf_word1(req_lw[1:0]);
// ...or the one still on the bus, which it will wait for.
wire        req_onbus  = pf_out && !pf_ack && !pf_kill && (req_lw == pf_next) && (sup == pf_sup);
// A pending request whose longword arrives now. It always is the one: a
// miss restarts the window AT the requested longword with nothing in it, so
// the first fill to join -- after any write empties it again -- is that
// longword. (An address compare here could never be false.)
wire        pend_fill  = a_pend && pf_app;
// A write accepted this cycle that touches the window or the read in flight.
wire [29:0] w_lo       = address_b[31:2];
wire [29:0] w_hi       = w_lo + {29'd0, (size_b == `AP040_SZ_L) && (address_b[1:0] != 2'd0)} +
                         {29'd0, (size_b == `AP040_SZ_W) && (address_b[1:0] == 2'd3)};
wire        w_accept   = wren_b && !w_pend;
// Distances into the window, modular like req_k: a window can span the top
// of the address space, and ordered compares against pf_base + 4 missed
// every write into one that did (review 15: a stream from $FFFFFFF8 kept
// stale words at $FFFFFFFC and at $00000000). Either longword a write
// touches can be the one inside. The read in flight is always at
// pf_base + pf_cnt with pf_cnt at most three -- one goes out only while
// pf_cnt_aft < PF_N -- so the window's four longwords are the whole range.
wire [29:0] w_klo      = w_lo - pf_base;
wire [29:0] w_khi      = w_hi - pf_base;
wire        w_hits_pf  = w_accept && ((w_klo < {27'd0, PF_N}) || (w_khi < {27'd0, PF_N}));
// What the next prefetch would be once this cycle's request is applied. A
// hit leaves base + count where it was; a miss starts the new stream, which
// can go out in the same cycle. Keeping prefetch out of every request cycle
// instead refilled the window only once the fetch unit had drained it --
// 2.5 cycles per instruction on the zero-wait bus rather than the bus's own
// rate.
wire [29:0] pf_issue_lw = (en_a && !req_hit) ? req_lw : pf_next;
wire  [2:0] pf_cnt_aft  = !en_a ? pf_cnt1 : req_hit ? (pf_cnt1 - req_k[2:0]) : 3'd0;
wire        pf_issue_sp = (en_a && !req_hit) ? sup : pf_sup;

always @(posedge clk) begin
	if (!nreset) begin
		busy <= 1'b0; who <= WHO_A;
		pf_base <= 30'd0; pf_cnt <= 3'd0; pf_out <= 1'b0; pf_kill <= 1'b0; pf_sup <= 1'b1;
		pf_live <= 1'b0;
		pf_q[0] <= 32'd0; pf_q[1] <= 32'd0; pf_q[2] <= 32'd0; pf_q[3] <= 32'd0;
		a_pend <= 1'b0; b_pend <= 1'b0; w_pend <= 1'b0;
		a_addr <= 32'd0; b_addr <= 32'd0; b_size <= `AP040_SZ_L;
		a_sup <= 1'b1; b_sup <= 1'b1; w_sup <= 1'b1;
		w_addr <= 32'd0; w_data <= 32'd0; w_size <= `AP040_SZ_L;
		rvalid_a <= 1'b0; rvalid_b <= 1'b0;
		q_a <= 16'd0; q_b <= 32'd0;
		mem_req <= 1'b0; mem_write <= 1'b0; mem_instr <= 1'b0;
		mem_size <= `AP040_SZ_L; mem_addr <= 32'd0; mem_wdata <= 32'd0;
		mem_fc <= `AP040_FC_SUPER_PROG;
	end else begin
		// ---- the prefetch stream ----
		// A prefetch arriving for the live window joins it.
		if (pf_ack) begin
			pf_out <= 1'b0;
			if (pf_kill) pf_kill <= 1'b0;
			else begin
				pf_q[pf_next[1:0]] <= mem_rdata;
				pf_cnt <= pf_cnt1;
			end
		end
		if (en_a) begin
			pf_live <= 1'b1;
			a_addr <= {address_a[31:1], 1'b0};
			a_sup  <= sup;
			if (req_hit) begin
				// Buffered: answered next cycle, and the window starts here.
				q_a      <= address_a[1] ? req_long[15:0] : req_long[31:16];
				rvalid_a <= 1'b1;
				a_pend   <= 1'b0;
				pf_base  <= req_lw;
				pf_cnt   <= pf_cnt1 - req_k[2:0];
			end else begin
				rvalid_a <= 1'b0;
				a_pend   <= 1'b1;
				pf_base  <= req_lw;
				pf_cnt   <= 3'd0;
				pf_sup   <= sup;
				// On the bus and still wanted: it lands at the new base. Any
				// other read in flight belongs to the old window.
				if (pf_out && !pf_ack && !req_onbus) pf_kill <= 1'b1;
			end
		end else if (pend_fill) begin
			q_a      <= a_addr[1] ? mem_rdata[15:0] : mem_rdata[31:16];
			rvalid_a <= 1'b1;
			a_pend   <= 1'b0;
		end
		// A write into the window, or into the read in flight, empties it;
		// what was pending is fetched again, after the write.
		if (w_hits_pf || pf_inval) begin
			pf_cnt <= 3'd0;
			if (pf_out && !pf_ack) pf_kill <= 1'b1;
			if (en_a && req_hit) pf_base <= req_lw + 30'd1;   // the word just served is gone past
		end
		if (rd_b) begin
			b_addr   <= address_b;
			b_size   <= size_b;
			b_sup    <= sup_b;
			b_pend   <= 1'b1;
			rvalid_b <= 1'b0;
		end
		if (wren_b && !w_pend) begin
			w_addr <= address_b;
			w_data <= data_b;
			w_size <= size_b;
			w_sup  <= sup_b;
			w_pend <= 1'b1;
		end

		// ---- the bus ----
		if (busy) begin
			if (mem_ack) begin
				busy    <= 1'b0;
				mem_req <= 1'b0;   // dropped in the ack cycle, per the contract
				case (who)
				WHO_A: ;   // the prefetch stream, above
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
			mem_fc    <= fc_of(1'b0, w_sup);
		end else if (b_pend) begin
			busy      <= 1'b1;  who <= WHO_BR;
			mem_req   <= 1'b1;  mem_write <= 1'b0;  mem_instr <= 1'b0;
			mem_size  <= b_size; mem_addr <= b_addr;
			mem_fc    <= fc_of(1'b0, b_sup);
		end else if ((pf_live || en_a) && !pf_out && (pf_cnt_aft < PF_N) && !w_hits_pf && !pf_inval) begin
			// The next longword of the stream, as the window stands after
			// this cycle's request. Not before the first request (review 15):
			// pf_base is zero out of reset, and a read of $0 the fetch unit
			// never asked for went out while ce held the core -- one the
			// reset PC's fetch then queued behind, for ever if $0 never
			// acknowledges.
			busy       <= 1'b1;  who <= WHO_A;
			pf_out     <= 1'b1;
			mem_req    <= 1'b1;  mem_write <= 1'b0;  mem_instr <= 1'b1;
			mem_size   <= `AP040_SZ_L; mem_addr <= {pf_issue_lw, 2'b00};
			mem_fc     <= fc_of(1'b1, pf_issue_sp);
		end
	end
end

endmodule
