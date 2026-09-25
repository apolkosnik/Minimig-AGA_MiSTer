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
//                                                                          //
// Translation (2026-09-25, caches stage A). On the 16-bit top the MMU is   //
// no longer below this unit. Port B's accesses arrive translated, from the //
// DMU (ap040_pipe_dmu.v); a translated read may take the bus in the cycle  //
// it arrives (rx_*). Port A keeps its window, logical as it always was,    //
// and with pages mapped (pf_xlat) each read the stream wants is translated //
// through the MMU's instruction port (x_*) from this unit's own register   //
// before it takes the bus -- never while holding it: the table walker may  //
// be waiting for a write this unit has still to send. The translation of   //
// a read the window no longer wants is seen through and then discarded.    //
// The instruction memory unit takes the fetch's translation over with its  //
// cache (stage B).                                                         //
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
	output reg [15:0] q_a2,     // the word after q_a, when address_a[1] was 0 (phase 8)
	output reg        rvalid_a,

	input      [31:0] address_b,
	input      [31:0] data_b,      // right-aligned by size_b
	input             wren_b,
	input       [1:0] size_b,
	input             rd_b,
	output            wr_busy,
	// wr_busy for a write being presented: the same, with wren_b taken as
	// set. It is all the CPU ever asks -- it looks at wr_busy only while it
	// presents a write -- and it does not depend on wren_b, which the CPU
	// forms from its stalls, which EX forms from wr_busy (a read-modify-
	// write's store waits on it): the loop Quartus found at the bus16 top,
	// 22 nodes and 17.7 ns, and Verilator's UNOPTFLAT on stall_self.
	output            wr_busy_w,
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
	// MOVES: the function code of this port-B access, in place of sup_b's.
	input             fc_ovr,
	input       [2:0] fc_ovr_val,

	// ---- bus side: ap040_core.v's external memory port ----
	output reg        mem_req,
	output reg        mem_write,
	output reg        mem_instr,
	output reg  [1:0] mem_size,
	output reg [31:0] mem_addr,
	output reg [31:0] mem_wdata,
	output reg  [2:0] mem_fc,
	input             mem_ack,
	input      [31:0] mem_rdata,

	// ---- access faults (2026-09-24) ----
	// The transaction on the bus faulted: the MMU refused it (a one-cycle
	// pulse; the request is consumed) or the bus answered with a physical
	// bus error (mem_flt_bus, which the adapter has already aborted on).
	input             mem_flt,
	input             mem_flt_bus,
	// The MMU forwarded the transaction on the bus: its translation passed.
	input             mem_pass,
	// Translation can refuse a data write (TC.E, or a data TTR enabled):
	// a write is then TENTATIVE until it passes, and wr_busy holds the
	// storing instruction until it does, so a refusal is precise.
	input             wr_sync,
	// with rvalid_a: the fetch faulted. The word handed over is then $4AFC,
	// ILLEGAL -- one word, no redirect, no gather -- so decode needs nothing
	// of the faulted fetch's stale data; rflt_a_bus says the fault was a
	// physical bus error rather than the MMU's.
	output reg        rflt_a,
	output reg        rflt_a_bus,
	output reg        rflt_b,       // with rvalid_b: the read faulted
	output            wflt,         // the tentative write being presented faulted (held until withdrawn)
	output            idle,         // nothing on the bus, posted or waiting
	// Start no fetch: the MMU's registers or ATC are about to change, and a
	// fetch must be translated wholly before or wholly after. Writes and
	// reads still go -- they are the older instructions', which must finish
	// under the old translation.
	input             quiesce,
	// The requester has withdrawn its write, in a cycle it ran: the refusal
	// has been seen. Not !wren_b, which the CPU gates with its ce -- a strobe
	// left up through a disabled cycle is a write accepted twice (milestone
	// 92) -- so a refusal cleared when wren_b dropped was gone after the
	// first disabled cycle, before the CPU had looked, and the write went
	// out again: re-refused by the MMU, and lost for good after a one-shot
	// bus error.
	input             wr_drop,
	// Transfers that cross a page (2026-09-24). The MMU translates one
	// address per transaction, so with translation on a transfer spanning
	// two pages goes out a byte at a time, each through its own page, and a
	// read's bytes are assembled; a fault past the boundary reports MA
	// (flt_ma). A write is first probed on both pages -- the MMU's PTEST
	// sideband as an access check (pb_*) -- and written only if both allow
	// it: ap040_core.v's check_write, so a refused one has written nothing
	// (an RMW restarted over a half-written operand would compute from it).
	input             xlat_e,       // TC.E
	input             xlat_p,       // TC.P: 8K pages
	output reg        pb_req,
	output reg [31:0] pb_addr,
	output     [2:0]  pb_fc,
	input             pb_done,
	input      [31:0] pb_mmusr,
	output reg        flt_ma,
	output reg        flt_bus,      // ...a physical bus error, not the MMU

	// ---- the stream's translation (see the header) ----
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

	// ---- a translated read (the DMU's): on the bus in its own cycle when
	// the bus is free and no write is waiting, else held as rd_b holds one
	input             rx,
	input      [31:0] rx_addr,
	input       [1:0] rx_size,
	input       [2:0] rx_fc
);

localparam [1:0] WHO_A = 2'd0, WHO_BR = 2'd1, WHO_BW = 2'd2;

reg        busy;        // a transaction is on the bus
reg  [1:0] who;         // whose it is

reg        a_pend;      // a fetch is wanted and has not been returned
reg [31:0] a_addr;
// Writes are snooped a cycle after they are accepted, from w_addr, never from
// the address the CPU is presenting (2026-09-25): that address is EA-fetch's
// latest signal, and every compare the window made against it ran on into
// pf_base, q_a and the fill -- the bus16 top's worst path, reached from each
// of EA-fetch's address sources in turn as the others were taken off it. In
// the accept cycle itself no fetch is answered, neither from the window nor
// by a fill arriving: the request is kept (a_dfr) and answered in the snoop
// cycle, from the window if the write missed it, or fetched again after the
// write if it did not. A fill that arrives meanwhile joins the window, and
// the snoop empties it if it was stale.
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
reg        w_tent;      // the pending write has not passed translation yet
reg        w_block;     // a tentative write faulted: take no write until the strobe drops
// A tentative write passed while its requester was not presenting it (review
// 16). The pass frees wr_busy for one clock, and the CPU, under ce, may not
// be looking that clock: its instruction then went on waiting, the write
// drained, and the strobe it still held was taken as a new write -- one
// MOVE.L posted twice, which RAM forgives and a device register does not.
// The receipt keeps the acceptance until the CPU next presents its write,
// which is that same write: nothing can take the storing instruction away
// while it waits for this (it is the oldest there is, EX and WB having
// drained past it), so the strobe it shows next is the one that passed.
reg        w_receipt;
// A crossing transfer's bytes: which is next, and the last one's index.
reg        b_x, w_x;
reg  [1:0] b_bi, b_last, w_bi, w_last;
reg [23:0] b_acc;       // the bytes read so far, right-aligned
reg  [1:0] w_pb;        // the write's probe: page 1, page 2, or done (0)
reg        b_pend;      // a data read is wanted and has not been returned
reg [31:0] b_addr;
reg  [1:0] b_size;
reg        w_pend;      // a write has been accepted and has not been sent
reg [31:0] w_addr, w_data;
reg  [1:0] w_size;
// Captured WITH each request, not read when the transaction is finally
// sent: a posted write can sit here across the very commit that changes the
// privilege, and would then go out under the wrong one.
reg        a_sup;
reg  [2:0] b_fc, w_fc;

// The requester must hold its write until this drops -- as with the array's
// one-entry buffer, the write is accepted the cycle wr_busy is low.
// A tentative write is not accepted when it is latched but when it passes:
// busy in the cycle it first appears, busy until then, and free for the one
// cycle the MMU forwards it -- the storing instruction's acceptance.
// The page geometry, and whether a transfer of n bytes at an address
// crosses out of its page.
wire [12:0] pg_mask   = xlat_p ? 13'h1FFF : 13'h0FFF;
wire [31:0] pg_mask32 = {19'd0, pg_mask};
function crosses;
	input [31:0] a;
	input  [1:0] sz;
	input [12:0] mask;
	begin
		crosses = ({1'b0, a[12:0] & mask} + ((sz == `AP040_SZ_L) ? 14'd4 : (sz == `AP040_SZ_W) ? 14'd2 : 14'd1)) >
		          ({1'b0, mask} + 14'd1);
	end
endfunction
function [1:0] last_of;   // the transfer's last byte index
	input [1:0] sz;
	begin
		last_of = (sz == `AP040_SZ_L) ? 2'd3 : (sz == `AP040_SZ_W) ? 2'd1 : 2'd0;
	end
endfunction
wire        pb_fail    = !pb_mmusr[0] || pb_mmusr[11] || pb_mmusr[2] || (!w_fc[2] && pb_mmusr[7]);
wire        pb_pass2   = w_pend && w_x && (w_pb == 2'd2) && pb_req && pb_done && !pb_fail;
assign      pb_fc      = w_fc;
wire  [1:0] w_bk       = w_last - w_bi;              // byte k of the operand, from the top
wire  [7:0] w_byte     = w_data[{w_bk, 3'b000} +: 8];
// A crossing write is accepted when its second probe passes: from there on
// it is posted like any other, and its bytes cannot be refused.
wire   w_pass_now = w_pend && w_tent && ((busy && (who == WHO_BW) && mem_pass) || pb_pass2);
assign wr_busy = w_block || (!w_receipt && (w_pend ? !w_pass_now : (wr_sync && wren_b)));
assign wr_busy_w = w_block || (!w_receipt && (w_pend ? !w_pass_now : wr_sync));
// The refusal is a level, not the one-clock pulse the MMU gives: the CPU
// runs under ce and may not be looking that clock.
assign wflt    = w_block;
assign idle    = !busy && !w_pend && !b_pend;

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
		pf_word1 = (pf_app && (i == pf_next[1:0])) ? mem_rdata : pf_q[i];
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
wire [29:0] w_lo       = w_addr[31:2];
wire        w_accept   = wren_b && !w_pend && !w_block && !w_receipt;
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
wire        pf_new      = (pf_live || en_a) && !pf_out && (pf_cnt_aft < PF_N) && !w_accept && !a_dfr &&
                          !pf_inval && (!pf_stop || en_a) && !quiesce;
// Translated, a prefetch -- the stream's next longword, not a request that
// missed -- in the page the MMU's instruction port translated last needs no
// translation of its own: it goes on the bus now, like an untranslated one.
assign      pk_addr     = {pf_next, 2'b00};
assign      pk_sup      = pf_sup;
wire        pf_direct   = !pf_xlat || (pk_hit && !(en_a && !req_hit));
// the chain below reaches the stream this cycle
wire        pf_bus_free = !busy && !(w_pend && w_x && (w_pb != 2'd0)) && !(w_pend && !(wren_b && !w_pend)) &&
                          !(b_pend || rx) && !xl_go;

always @(posedge clk) begin
	if (!nreset) begin
		busy <= 1'b0; who <= WHO_A;
		pf_base <= 30'd0; pf_cnt <= 3'd0; pf_out <= 1'b0; pf_kill <= 1'b0; pf_sup <= 1'b1;
		pf_live <= 1'b0; pf_stop <= 1'b0; pf_dem <= 1'b0; w_tent <= 1'b0; w_block <= 1'b0;
		xl_on <= 1'b0; xl_sp <= 1'b1; xl_lw <= 30'd0;
		w_receipt <= 1'b0;
		rflt_a <= 1'b0; rflt_a_bus <= 1'b0; rflt_b <= 1'b0; flt_bus <= 1'b0; flt_ma <= 1'b0;
		b_x <= 1'b0; w_x <= 1'b0; b_bi <= 2'd0; b_last <= 2'd0; w_bi <= 2'd0; w_last <= 2'd0;
		b_acc <= 24'd0; w_pb <= 2'd0; pb_req <= 1'b0; pb_addr <= 32'd0;
		pf_q[0] <= 32'd0; pf_q[1] <= 32'd0; pf_q[2] <= 32'd0; pf_q[3] <= 32'd0;
		a_pend <= 1'b0; b_pend <= 1'b0; w_pend <= 1'b0; a_dfr <= 1'b0; w_snoop <= 1'b0;
		a_addr <= 32'd0; b_addr <= 32'd0; b_size <= `AP040_SZ_L;
		a_sup <= 1'b1; b_fc <= `AP040_FC_SUPER_DATA; w_fc <= `AP040_FC_SUPER_DATA;
		w_addr <= 32'd0; w_data <= 32'd0; w_size <= `AP040_SZ_L;
		rvalid_a <= 1'b0; rvalid_b <= 1'b0;
		q_a <= 16'd0; q_a2 <= 16'd0; q_b <= 32'd0;
		mem_req <= 1'b0; mem_write <= 1'b0; mem_instr <= 1'b0;
		mem_size <= `AP040_SZ_L; mem_addr <= 32'd0; mem_wdata <= 32'd0;
		mem_fc <= `AP040_FC_SUPER_PROG;
	end else begin
		if (wr_drop) w_block <= 1'b0;
		w_snoop <= w_accept;
		if (w_pass_now) begin
			w_tent    <= 1'b0;
			w_receipt <= !wren_b;
		end else if (wren_b) w_receipt <= 1'b0;   // consumed: wr_busy was low for it
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
			q_a      <= a_addr[1] ? mem_rdata[15:0] : mem_rdata[31:16];
			q_a2     <= mem_rdata[15:0];
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
		if (rd_b || rx) begin
			b_addr   <= rx ? rx_addr : address_b;
			b_size   <= rx ? rx_size : size_b;
			b_x      <= !rx && xlat_e && crosses(address_b, size_b, pg_mask);
			b_bi     <= 2'd0;
			b_last   <= last_of(rx ? rx_size : size_b);
			b_acc    <= 24'd0;
			b_fc     <= rx ? rx_fc : fc_ovr ? fc_ovr_val : fc_of(1'b0, sup_b);
			b_pend   <= 1'b1;
			rvalid_b <= 1'b0;
		end
		if (w_accept) begin
			w_addr <= address_b;
			w_data <= data_b;
			w_size <= size_b;
			w_x    <= xlat_e && crosses(address_b, size_b, pg_mask);
			w_pb   <= (xlat_e && crosses(address_b, size_b, pg_mask)) ? 2'd1 : 2'd0;
			w_bi   <= 2'd0;
			w_last <= last_of(size_b);
			w_fc   <= fc_ovr ? fc_ovr_val : fc_of(1'b0, sup_b);
			w_pend <= 1'b1;
			w_tent <= wr_sync;
		end

		// ---- the bus ----
		if (busy && mem_flt) begin
			// Refused, or a physical bus error: the transaction is over, and
			// whoever it was for is told. A demand fetch gets the fault with its
			// valid; a speculative prefetch stops the stream -- the fetch unit
			// asking for that longword later restarts it, and faults then, so a
			// fault is only ever raised on a word the program needs. A request
			// that joined a prefetch already on the bus is not a demand yet:
			// it stays pending, and the read goes out again for it. A write
			// already accepted (posted) has no instruction left to take it: that
			// is only a physical bus error, and it is dropped (see the plan).
			busy    <= 1'b0;
			mem_req <= 1'b0;
			flt_bus <= mem_flt_bus;
			flt_ma  <= 1'b0;
			case (who)
			WHO_A: begin
				// Nothing is left in flight to kill, whoever wanted it. A request
				// arriving now supersedes the stream the fault belonged to.
				pf_out  <= 1'b0;
				pf_kill <= 1'b0;
				if (!pf_kill && !en_a) begin
					if (a_pend && pf_dem) begin
						q_a        <= 16'h4AFC;
						q_a2       <= 16'h4AFC;
						rvalid_a   <= 1'b1;
						rflt_a     <= 1'b1;
						rflt_a_bus <= mem_flt_bus;
						a_pend     <= 1'b0;
						pf_stop    <= 1'b1;
					end else if (!a_pend) pf_stop <= 1'b1;
				end
			end
			WHO_BR: begin
				rvalid_b <= 1'b1;
				rflt_b   <= 1'b1;
				b_pend   <= 1'b0;
				// a crossing read's byte past the boundary: MA
				flt_ma   <= b_x && ((mem_addr & ~pg_mask32) != (b_addr & ~pg_mask32));
			end
			default: begin   // WHO_BW
				w_pend <= 1'b0;
				w_tent <= 1'b0;
				if (w_tent) w_block <= 1'b1;
			end
			endcase
		end else if (busy) begin
			if (mem_ack) begin
				busy    <= 1'b0;
				mem_req <= 1'b0;   // dropped in the ack cycle, per the contract
				case (who)
				WHO_A: ;   // the prefetch stream, above
				WHO_BR: if (b_x && (b_bi != b_last)) begin
					// a crossing read's byte, and more to come
					b_acc    <= {b_acc[15:0], mem_rdata[7:0]};
					b_bi     <= b_bi + 2'd1;
				end else begin
					q_b      <= b_x ? {b_acc, mem_rdata[7:0]} : mem_rdata;
					rvalid_b <= 1'b1;
					rflt_b   <= 1'b0;
					b_pend   <= 1'b0;
				end
				default: if (w_x && (w_bi != w_last)) w_bi <= w_bi + 2'd1;   // WHO_BW
				         else w_pend <= 1'b0;
				endcase
			end
		end else if (w_pend && w_x && (w_pb != 2'd0)) begin
			// A crossing write's probes, page 1 then page 2, before any byte.
			// The bus stays free; the MMU holds every transaction off while
			// the probe is up. Refused: the write is withdrawn, as one the MMU
			// refused on the bus, with MA if it was the second page.
			if (!pb_req) begin
				pb_req  <= 1'b1;
				pb_addr <= (w_pb == 2'd1) ? w_addr : ((w_addr | pg_mask32) + 32'd1);
			end else if (pb_done) begin
				pb_req <= 1'b0;
				if (pb_fail) begin
					w_pend  <= 1'b0;
					w_tent  <= 1'b0;
					w_block <= 1'b1;
					w_pb    <= 2'd0;
					flt_bus <= 1'b0;
					flt_ma  <= (w_pb == 2'd2);
				end else w_pb <= (w_pb == 2'd1) ? 2'd2 : 2'd0;
			end
		end else if (w_pend && !(wren_b && !w_pend)) begin
			busy      <= 1'b1;  who <= WHO_BW;
			mem_req   <= 1'b1;  mem_write <= 1'b1;  mem_instr <= 1'b0;
			mem_size  <= w_x ? `AP040_SZ_B : w_size;
			mem_addr  <= w_x ? (w_addr + {30'd0, w_bi}) : w_addr;
			mem_wdata <= w_x ? {24'd0, w_byte} : w_data;
			mem_fc    <= w_fc;
		end else if (b_pend || rx) begin
			busy      <= 1'b1;  who <= WHO_BR;
			mem_req   <= 1'b1;  mem_write <= 1'b0;  mem_instr <= 1'b0;
			mem_size  <= !b_pend ? rx_size : b_x ? `AP040_SZ_B : b_size;
			mem_addr  <= !b_pend ? rx_addr : b_x ? (b_addr + {30'd0, b_bi}) : b_addr;
			mem_fc    <= !b_pend ? rx_fc : b_fc;
		end else if (xl_go) begin
			// the stream's read, translated
			busy       <= 1'b1;  who <= WHO_A;
			xl_on      <= 1'b0;
			mem_req    <= 1'b1;  mem_write <= 1'b0;  mem_instr <= 1'b1;
			mem_size   <= `AP040_SZ_L; mem_addr <= {x_pa[31:2], 2'b00};
			mem_fc     <= fc_of(1'b1, xl_sp);
		end else if (pf_new && pf_direct) begin
			busy       <= 1'b1;  who <= WHO_A;
			pf_out     <= 1'b1;
			pf_dem     <= en_a ? !req_hit : a_pend;
			mem_req    <= 1'b1;  mem_write <= 1'b0;  mem_instr <= 1'b1;
			mem_size   <= `AP040_SZ_L;
			mem_addr   <= pf_xlat ? {pk_pa[31:2], 2'b00} : {pf_issue_lw, 2'b00};
			mem_fc     <= fc_of(1'b1, pf_issue_sp);
		end
		// Otherwise translated first, from this register (see the header) --
		// whatever the bus is doing, so the translation overlaps it.
		if (pf_new && pf_xlat && !(pf_direct && pf_bus_free)) begin
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
			flt_bus <= 1'b0;
			flt_ma  <= 1'b0;
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
