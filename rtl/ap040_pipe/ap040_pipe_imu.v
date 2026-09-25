//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (2026-09-25)                   //
//                                                                          //
// ap040_pipe_imu.v - the instruction memory unit                           //
//                                                                          //
// Between the fetch stage's port A and the bus controller                  //
// (ap040_pipe_membus.v), as the MC68040's IMU sits between its instruction //
// fetch and its bus controller (MC68040UM Figure 4-1). Stage B of          //
// doc_AP040_PIPELINE_CACHES.md, step 1: the prefetch window, moved here    //
// from the bus controller unchanged; the instruction cache joins it in the //
// next step, as the source of the window's reads.                          //
//                                                                          //
// CPU side: ap040_pipe_l1.v's port-A protocol exactly -- a request, a      //
// return with a valid that holds as a level until the next request, and a  //
// new request abandoning one in flight.                                    //
//                                                                          //
// The prefetch stream (2026-09-24). Fetching one word per transaction, and //
// only once the previous word had been handed over, held the pipeline to 4 //
// cycles per instruction on a zero-wait bus where the sequential core ran  //
// at 2. Fetches are aligned longwords into a four-entry window that runs   //
// ahead of the fetch unit whenever the bus has nothing else to do. A       //
// request inside the window is answered the next cycle -- the timing the   //
// L1 array's port A gives, so ap040_inst_fetch.v issues back to back --    //
// and the window slides forward to it. A request for the longword in       //
// flight waits for it; anything else is a redirect: the window is emptied, //
// the read in flight is discarded when it returns, and the stream restarts //
// at the new address. A CPU write that touches the window or the read in   //
// flight empties it, and the bus controller sends writes before the        //
// refetch, so a store into the instruction stream is fetched. A change of  //
// privilege does the same, so every word carries its own function code.    //
//                                                                          //
// Restarts: a redirect can change the request while a read is on the bus.  //
// That transaction cannot be recalled, so its result is discarded and the  //
// new address read -- the fetch unit never sees the stale word.            //
//                                                                          //
// Translation (caches stage A). The window is logical. With pages mapped   //
// (pf_xlat) each read the stream wants is translated through the MMU's     //
// instruction port (x_*) from this unit's own register before it goes to   //
// the bus -- never while holding the bus: the table walker may be waiting  //
// for a write the bus controller has still to send -- and a prefetch in    //
// the page the port translated last goes out in its own cycle through the  //
// MMU's peek (pk_*). The translation of a read the window no longer wants  //
// is seen through and then discarded.                                      //
//                                                                          //
// The bus controller runs a fetch the cycle this unit asks (f_req) if its  //
// bus is free for one (f_free) -- nothing on it, no write or read waiting: //
// writes and reads beat fetches, since a fetch can always be re-issued and //
// a load cannot -- and answers it with f_ack or f_flt. It also tells this  //
// unit of every write it takes (w_accept) and where the program wrote     //
// (w_sla), for the window's snoop.                                         //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_imu
(
	input             clk,
	input             nreset,

	// ---- the fetch stage (port A) ----
	input      [31:0] address_a,
	input             en_a,
	output reg [15:0] q_a,
	output reg [15:0] q_a2,     // the word after q_a, when address_a[1] was 0 (phase 8)
	output reg        rvalid_a,
	// with rvalid_a: the fetch faulted. The word handed over is then $4AFC,
	// ILLEGAL -- one word, no redirect, no gather -- so decode needs nothing
	// of the faulted fetch's stale data; rflt_a_bus says the fault was a
	// physical bus error rather than the MMU's.
	output reg        rflt_a,
	output reg        rflt_a_bus,
	// The supervisor bit, for the function code alone.
	input             sup,
	// CINV/CPUSH: empty the window. The refetch that follows arrives in the
	// same cycle and must go to memory, not to what the window held.
	input             pf_inval,
	// Start no fetch: the MMU's registers or ATC are about to change, and a
	// fetch must be translated wholly before or wholly after.
	input             quiesce,

	// ---- translation ----
	input             pf_xlat,      // translate each stream read first (TC.E)
	output            x_req,        // ap040_pipe_mmu.v's instruction port
	output     [31:0] x_addr,
	output            x_sup,
	input             x_pass,
	input             x_flt,
	input      [31:0] x_pa,
	// ...and the MMU's peek (ip_*) at the stream's next longword, so a
	// prefetch in the page translated last goes on the bus in its own cycle
	output     [31:0] pk_addr,
	output            pk_sup,
	input             pk_hit,
	input      [31:0] pk_pa,

	// ---- the bus controller ----
	output            f_req,        // a fetch, now, if the bus is free for it
	output     [31:0] f_addr,       // physical
	output            f_sup,
	input             f_free,       // the bus is free for a fetch this cycle
	input             f_ack,        // the fetch on the bus is answered...
	input      [31:0] f_rdata,
	input             f_flt,        // ...or faulted
	input             f_flt_bus,    // ...with a physical bus error
	input             w_accept,     // a write is taken this cycle
	input      [29:0] w_sla         // the logical longword of the write taken last
);

// A request held over a write's accept cycle. Writes are snooped a cycle
// after they are accepted, from w_sla -- the write's LOGICAL address, as the
// window is -- never from the address the CPU is presenting (2026-09-25):
// that address is EA-fetch's latest signal, and every compare the window
// made against it ran on into pf_base, q_a and the fill -- the bus16 top's
// worst path, reached from each of EA-fetch's address sources in turn as the
// others were taken off it. In the accept cycle itself no fetch is answered,
// neither from the window nor by a fill arriving: the request is kept
// (a_dfr) and answered in the snoop cycle, from the window if the write
// missed it, or fetched again after the write if it did not. A fill that
// arrives meanwhile joins the window, and the snoop empties it if it was
// stale.
reg        a_pend;      // a fetch is wanted and has not been returned
reg [31:0] a_addr;
reg        a_sup;
reg        a_dfr;       // a request held over a write's accept cycle
reg        w_snoop;     // a write was accepted last cycle: snoop it now

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
reg        pf_stop;     // a speculative prefetch faulted: no more until a new request
// The read on the bus went out FOR a request -- the fetch unit's miss --
// rather than ahead of one. Only such a read's fault is the fetch unit's:
// a request that finds its longword already on the bus as a prefetch has
// it re-issued if that prefetch faults, as the 68040 re-runs a faulted
// prefetch at the point the word is needed (t_exceptions.s tests 138-141).
reg        pf_dem;
// The stream's next read, being translated (pf_xlat): pf_out is set, the bus
// is not taken. It holds the MMU's instruction port at the same address
// until the translation passes or faults, as the MMU requires. After a
// fault the port is down for at least the next cycle, which is what the
// walker waits for (W_DROP): a new translation needs pf_out clear, and that
// clears only at the fault's own edge.
reg        xl_on, xl_sp;
reg [29:0] xl_lw;
assign     x_req  = xl_on;
assign     x_addr = {xl_lw, 2'b00};
assign     x_sup  = xl_sp;

// This cycle's view of the window, with a prefetch that returns now already
// in it -- a request in the same cycle must see it.
wire        pf_ack     = f_ack;
// A fill landing in a write's accept cycle joins the window like any other;
// it is not handed to the fetch waiting for it then (see a_dfr), and the
// snoop a cycle later empties the window if the write reached it -- the old
// instruction behind a store that rewrote it (tb_ap040_pipe_smcdual.v).
wire        pf_app     = pf_ack && !pf_kill;
wire [29:0] pf_next    = pf_base + {27'd0, pf_cnt};
wire  [2:0] pf_cnt1    = pf_cnt + {2'd0, pf_app};
function [31:0] pf_word1;   // entry i, including the longword arriving now
	input [1:0] i;
	begin
		pf_word1 = (pf_app && (i == pf_next[1:0])) ? f_rdata : pf_q[i];
	end
endfunction
wire [29:0] req_lw     = address_a[31:2];
wire [29:0] req_k      = req_lw - pf_base;
// Not in a write's accept cycle (the request is held, a_dfr), nor from a
// window the snoop is emptying this cycle.
wire        req_hit    = !pf_inval && !w_accept && !w_hits_pf && (req_k < {27'd0, pf_cnt1}) && (sup == pf_sup);
wire [31:0] req_long   = pf_word1(req_lw[1:0]);
// ...or the one still on the bus, which it will wait for.
wire        req_onbus  = pf_out && !pf_ack && !pf_kill && (req_lw == pf_next) && (sup == pf_sup);
// A pending request whose longword arrives now. It always is the one: a
// miss restarts the window AT the requested longword with nothing in it, so
// the first fill to join -- after any write empties it again -- is that
// longword. (An address compare here could never be false.)
wire        pend_fill  = a_pend && !a_dfr && pf_app && !w_accept && !w_hits_pf;
// The held request, in the snoop cycle: from the window, or a miss.
wire [29:0] a_lw       = a_addr[31:2];
wire [29:0] dfr_k      = a_lw - pf_base;
wire        dfr_hit    = !pf_inval && !w_hits_pf && (dfr_k < {27'd0, pf_cnt1}) && (a_sup == pf_sup);
wire [31:0] dfr_long   = pf_word1(a_lw[1:0]);
wire        dfr_onbus  = pf_out && !pf_ack && !pf_kill && (a_lw == pf_next) && (a_sup == pf_sup);
// The write accepted last cycle, snooped now from its registered address.
// Its bytes lie in its own longword and at most the next, and it is taken
// to touch both, whatever its size and alignment (restructuring plan, phase
// 5): too much only empties the window once more than it had to, and a
// write next to the instruction stream is rare.
wire [29:0] w_lo       = w_sla;
// Distances into the window, modular like req_k: a window can span the top
// of the address space, and ordered compares against pf_base + 4 missed
// every write into one that did (review 15: a stream from $FFFFFFF8 kept
// stale words at $FFFFFFFC and at $00000000). Either longword a write
// touches can be the one inside -- w_lo + 1 is inside exactly when w_lo is
// the longword below pf_base. The read in flight is always at pf_base +
// pf_cnt with pf_cnt at most three -- one goes out only while pf_cnt_aft <
// PF_N -- so the window's four longwords are the whole range.
wire [29:0] w_klo      = w_lo - pf_base;
wire        w_hits_pf  = w_snoop && ((w_klo < {27'd0, PF_N}) || (w_klo == 30'h3FFF_FFFF));
// What the next prefetch would be once this cycle's request is applied. A
// hit leaves base + count where it was; a miss starts the new stream, which
// can go out in the same cycle. Keeping prefetch out of every request cycle
// instead refilled the window only once the fetch unit had drained it --
// 2.5 cycles per instruction on the zero-wait bus rather than the bus's own
// rate.
wire [29:0] pf_issue_lw = (en_a && !req_hit) ? req_lw : pf_next;
wire  [2:0] pf_cnt_aft  = !en_a ? pf_cnt1 : req_hit ? (pf_cnt1 - req_k[2:0]) : 3'd0;
wire        pf_issue_sp = (en_a && !req_hit) ? sup : pf_sup;
// The stream's read translated and still wanted: it takes the bus when
// nothing comes first.
wire        xl_go       = xl_on && x_pass && !pf_kill;
// The next longword of the stream, as the window stands after this cycle's
// request. Not in a cycle a write is accepted: whether that write lands in
// the window is a thirty-bit compare on an address the CPU has only just
// formed, and deciding the bus on it was the bus16 top's worst path (-4.913
// ns at 25 ns); the write goes first next cycle anyway. Not before the first
// request (review 15): pf_base is zero out of reset, and a read of $0 the
// fetch unit never asked for went out while ce held the core -- one the
// reset PC's fetch then queued behind, for ever if $0 never acknowledges.
// Untranslated it goes on the bus when nothing comes first; translated
// (pf_xlat) its translation starts at once.
// Nor in the cycle a write's snoop empties the window: the next longword
// was pf_base + pf_cnt before it and is pf_base after, and one read for the
// first landed as the second (2026-09-25). The bus controller's own read
// never went -- the write is still waiting there, so the bus is not free --
// but a translation started for it (from caches stage A).
wire        pf_new      = (pf_live || en_a) && !pf_out && (pf_cnt_aft < PF_N) && !w_accept && !a_dfr &&
                          !pf_inval && !w_hits_pf && (!pf_stop || en_a) && !quiesce;
// Translated, a prefetch -- the stream's next longword, not a request that
// missed -- in the page the MMU's instruction port translated last needs no
// translation of its own: it goes on the bus now, like an untranslated one.
assign      pk_addr     = {pf_next, 2'b00};
assign      pk_sup      = pf_sup;
wire        pf_direct   = !pf_xlat || (pk_hit && !(en_a && !req_hit));

// The fetch this unit asks the bus controller for: the stream's read once
// translated, or its next read now. (Never both: a read being translated
// holds pf_out, and a new one needs it clear.)
assign f_req  = xl_go || (pf_new && pf_direct);
assign f_addr = xl_go ? {x_pa[31:2], 2'b00} : pf_xlat ? {pk_pa[31:2], 2'b00} : {pf_issue_lw, 2'b00};
assign f_sup  = xl_go ? xl_sp : pf_issue_sp;

always @(posedge clk) begin
	if (!nreset) begin
		pf_base <= 30'd0; pf_cnt <= 3'd0; pf_out <= 1'b0; pf_kill <= 1'b0; pf_sup <= 1'b1;
		pf_live <= 1'b0; pf_stop <= 1'b0; pf_dem <= 1'b0;
		xl_on <= 1'b0; xl_sp <= 1'b1; xl_lw <= 30'd0;
		rflt_a <= 1'b0; rflt_a_bus <= 1'b0;
		pf_q[0] <= 32'd0; pf_q[1] <= 32'd0; pf_q[2] <= 32'd0; pf_q[3] <= 32'd0;
		a_pend <= 1'b0; a_dfr <= 1'b0; w_snoop <= 1'b0;
		a_addr <= 32'd0; a_sup <= 1'b1;
		rvalid_a <= 1'b0;
		q_a <= 16'd0; q_a2 <= 16'd0;
	end else begin
		w_snoop <= w_accept;
		// ---- the prefetch stream ----
		// A prefetch arriving for the live window joins it.
		if (pf_ack) begin
			pf_out <= 1'b0;
			if (pf_kill) pf_kill <= 1'b0;
			else begin
				pf_q[pf_next[1:0]] <= f_rdata;
				pf_cnt <= pf_cnt1;
			end
		end
		if (en_a) begin
			pf_live <= 1'b1;
			pf_stop <= 1'b0;
			a_addr <= {address_a[31:1], 1'b0};
			a_sup  <= sup;
			a_dfr  <= w_accept;
			if (w_accept) begin
				// Held over the write's accept cycle; the window is untouched.
				rvalid_a <= 1'b0;
				a_pend   <= 1'b1;
			end else if (req_hit) begin
				// Buffered: answered next cycle, and the window starts here.
				q_a      <= address_a[1] ? req_long[15:0] : req_long[31:16];
				q_a2     <= req_long[15:0];
				rvalid_a <= 1'b1;
				rflt_a   <= 1'b0;
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
		end else if (a_dfr) begin
			// The snoop cycle: the held request, from the window or missed.
			a_dfr <= 1'b0;
			if (dfr_hit) begin
				q_a      <= a_addr[1] ? dfr_long[15:0] : dfr_long[31:16];
				q_a2     <= dfr_long[15:0];
				rvalid_a <= 1'b1;
				rflt_a   <= 1'b0;
				a_pend   <= 1'b0;
				pf_base  <= a_lw;
				pf_cnt   <= pf_cnt1 - dfr_k[2:0];
			end else begin
				pf_base  <= a_lw;
				pf_cnt   <= 3'd0;
				pf_sup   <= a_sup;
				// As for a request answered at once: the read on the bus is
				// kept when it is the longword asked for (phase 8 -- the
				// fetch's queue asks in a write's accept cycle often, and
				// killing it here fetched every instruction longword twice
				// behind a read-modify-write).
				if (pf_out && !pf_ack && !dfr_onbus) pf_kill <= 1'b1;
			end
		end else if (a_pend && pf_app && w_accept) begin
			// A pending fetch's fill in a write's accept cycle: it joins the
			// window, and the fetch is answered from there next cycle.
			a_dfr <= 1'b1;
		end else if (pend_fill) begin
			q_a      <= a_addr[1] ? f_rdata[15:0] : f_rdata[31:16];
			q_a2     <= f_rdata[15:0];
			rvalid_a <= 1'b1;
			rflt_a   <= 1'b0;
			a_pend   <= 1'b0;
		end
		// A write into the window, or into the read in flight, empties it;
		// what was pending is fetched again, after the write.
		if (w_hits_pf || pf_inval) begin
			pf_cnt <= 3'd0;
			if (pf_out && !pf_ack) pf_kill <= 1'b1;
		end

		// ---- the fetch on the bus ----
		if (f_flt) begin
			// Refused, or a physical bus error. A demand fetch gets the fault
			// with its valid; a speculative prefetch stops the stream -- the
			// fetch unit asking for that longword later restarts it, and
			// faults then, so a fault is only ever raised on a word the
			// program needs. A request that joined a prefetch already on the
			// bus is not a demand yet: it stays pending, and the read goes
			// out again for it. Nothing is left in flight to kill, whoever
			// wanted it; a request arriving now supersedes the stream the
			// fault belonged to.
			pf_out  <= 1'b0;
			pf_kill <= 1'b0;
			if (!pf_kill && !en_a) begin
				if (a_pend && pf_dem) begin
					q_a        <= 16'h4AFC;
					q_a2       <= 16'h4AFC;
					rvalid_a   <= 1'b1;
					rflt_a     <= 1'b1;
					rflt_a_bus <= f_flt_bus;
					a_pend     <= 1'b0;
					pf_stop    <= 1'b1;
				end else if (!a_pend) pf_stop <= 1'b1;
			end
		end else if (f_free && xl_go) begin
			// the stream's read, translated, on the bus
			xl_on <= 1'b0;
		end else if (f_free && pf_new && pf_direct) begin
			pf_out <= 1'b1;
			pf_dem <= en_a ? !req_hit : a_pend;
		end
		// Otherwise translated first, from this register (see the header) --
		// whatever the bus is doing, so the translation overlaps it.
		if (pf_new && pf_xlat && !(pf_direct && f_free)) begin
			pf_out <= 1'b1;
			pf_dem <= en_a ? !req_hit : a_pend;
			xl_on  <= 1'b1;  xl_lw <= pf_issue_lw;  xl_sp <= pf_issue_sp;
		end
		// The stream's translation ends. Passed but no longer wanted (the
		// window moved on while it ran): dropped, nothing having gone out.
		// Refused: as a fetch the MMU refused on the bus was -- the fetch
		// unit's demand gets $4AFC and the fault, a speculative read stops
		// the stream.
		if (xl_on && x_pass && pf_kill) begin
			xl_on   <= 1'b0;
			pf_out  <= 1'b0;
			pf_kill <= 1'b0;
		end
		if (xl_on && x_flt) begin
			xl_on   <= 1'b0;
			pf_out  <= 1'b0;
			pf_kill <= 1'b0;
			if (!pf_kill && !en_a) begin
				if (a_pend && pf_dem) begin
					q_a        <= 16'h4AFC;
					q_a2       <= 16'h4AFC;
					rvalid_a   <= 1'b1;
					rflt_a     <= 1'b1;
					rflt_a_bus <= 1'b0;
					a_pend     <= 1'b0;
					pf_stop    <= 1'b1;
				end else if (!a_pend) pf_stop <= 1'b1;
			end
		end
	end
end

endmodule
