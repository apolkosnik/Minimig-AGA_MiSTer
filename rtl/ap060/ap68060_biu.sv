//--------------------------------------------------------------------------//
// AP68060 - pipelined MC68060                                              //
//                                                                          //
// ap68060_biu.sv - bus interface unit (MC68060UM section 7)                 //
//                                                                          //
// Runs one internal transaction at a time on the 68060 bus:                //
//   * byte/word/long transfers (the requester has already split a          //
//     misaligned operand into aligned pieces, 7.6), with the byte selects  //
//     BS3-BS0 (table 2-6)                                                  //
//   * line transfers as a burst; TBI on the first beat falls back to       //
//     three long-word transfers (7.7.2, 7.7.4).  A3:A2 stay put unless     //
//     CLA is asserted, which advances them, wrapping in the line (7.7.7); //
//     the slave counts the beats either way                                //
//   * termination (7.9, table 7-5) in the protocol chosen at reset:        //
//       68040: TA normal, TEA bus error, TA+TEA retry (a retry after the   //
//              first beat of a line is a bus error)                        //
//       native: TEA bus error, TRA retry (ignored after the first beat),  //
//              TA normal                                                   //
//   * the acknowledge termination ignore states (7.14.1): the primary     //
//     count before the first sample of a transfer, the secondary before   //
//     every later beat of a line; SAS is asserted for the one bus clock   //
//     at whose end a beat's terminations are first sampled (2.4.3)        //
//   * the extra data write hold (7.14.3): write data stays one bus clock  //
//     past its TA (the next beat's data follows then)                     //
//   * locked sequences: LOCK from the first locked transfer to the end of //
//     the LOCKE transfer, on every transfer between them (instruction      //
//     fetches too, C.2.2.3); a negated BG does not take the bus away       //
//     inside one unless BGR is asserted (7.11).  Only the LOCKE transfer's //
//     end, a bus error on a locked transfer, or the processor abandoning  //
//     the sequence (unlock: an exception, BUSCR.L cleared) ends it (7.4)   //
//   * arbitration (7.11, figure 7-41): reset, alternate-master implicit   //
//     and explicit ownership, implicit and explicit ownership, end of      //
//     tenure.  Either protocol works: a tenure of another master ends     //
//     with BTT or with BB going negated; ours ends with BTT asserted one   //
//     bus clock and negated one, BB negated one CLK, then three-stated.   //
//     The bus is driven only in explicit ownership.  A retry with BG      //
//     negated gives the bus up and retries once it is back (7.9.2).       //
//   * RSTO for 512 CLK cycles (RESET instruction, 7.13), once the transfer //
//     in progress has ended: no bus cycle overlaps it (2.8.4)              //
//   * a snoop has priority over the processor (5.6): no transfer starts   //
//     while the snooper still has invalidations to make                   //
//                                                                          //
// Every bus output changes only in a clk cycle with bclk_en high, except  //
// BB and TIP, which are negated for one CLK before being three-stated,    //
// and RSTO; inputs are sampled only in bclk_en cycles.                     //
//                                                                          //
// Requester interface (per client c):                                      //
//   req[c]      level; breq[c] must be stable while req[c] is high and    //
//               gnt[c] has not pulsed; wdata[c] from the request until    //
//               done[c] or err[c] (the BIU drives the bus from it)         //
//   gnt[c]      pulse: the transaction is latched, req may drop or change  //
//   rvalid      pulse per read beat for the client in rclient; rdata,      //
//               rbeat (the long word's A3:A2), avec (AVEC with TA)         //
//   done[c]     pulse: transaction finished without error                  //
//   err[c]      pulse: transaction ended with a bus error; errbeat says    //
//               which long word of a line (0 = the first transferred)      //
//   tci         TCI sampled with the first beat, valid with the first      //
//               rvalid                                                     //
// Line write data: wdata[c][127:96] is the long word at A3:A2 = 0, ...,    //
// wdata[c][31:0] at A3:A2 = 3.  Single writes take wdata[c][31:0] already  //
// placed on the byte lanes D31-D0.                                         //
//--------------------------------------------------------------------------//

module ap68060_biu
	import ap68060_pkg::*;
#(
	parameter int NC = 3            // number of requesters, 0 = highest priority
)
(
	input  logic              clk,
	input  logic              nreset,
	input  logic              bclk_en,

	// modes registered at reset (7.14)
	input  logic              m_ign,      // ignore state capability (IPL0)
	input  logic              m_native,   // native acknowledge termination (IPL1)
	input  logic              m_hold,     // extra data write hold (IPL2)
	input  logic [15:0]       m_cnt,      // D15-D0: read primary/secondary, write primary/secondary

	// requesters
	input  logic [NC-1:0]     req,
	input  busreq_t           breq   [NC],
	input  logic [127:0]      wdata  [NC],
	output logic [NC-1:0]     gnt,
	output logic [NC-1:0]     done,
	output logic [NC-1:0]     err,
	output logic              rvalid,
	output logic [$clog2(NC)-1:0] rclient,
	output logic [31:0]       rdata,
	output logic  [1:0]       rbeat,
	output logic              ravec,
	output logic              rtci,
	output logic  [1:0]       errbeat,
	output logic              idle,     // no transaction latched or running
	output logic              own,      // we hold the bus (implicitly or explicitly)

	input  logic              unlock,   // the processor abandons an open locked sequence
	input  logic              sn_busy,  // snoop invalidations still pending: no new transfer
	input  logic              halt,     // the processor halted: end the tenure, BR negated
	input  logic [NC-1:0]     more,     // another transfer of the client waits behind this one
	input  logic [NC-1:0]     drop,     // a retry waiting for the bus is not wanted any more
	                                    // (a push whose line a snoop took): done, not rerun

	// RESET instruction
	input  logic              rsto_req,  // pulse
	output logic              rsto_busy, // RSTO asserted, or waiting for the transfer to end

	// the 68060 bus
	output logic [31:0]       a_o,
	output logic              a_oe,      // address, attributes, TS, SAS, TIP driven
	input  logic [31:0]       d_i,
	output logic [31:0]       d_o,
	output logic              d_oe,
	output logic              rw_n,
	output logic  [1:0]       siz,
	output logic  [3:0]       bs_n,      // BS0-BS3 (bs_n[0] = BS0, D31-D24)
	output logic  [1:0]       tt,
	output logic  [2:0]       tm,
	output logic  [1:0]       tln,
	output logic  [1:0]       upa,
	output logic              ciout_n,
	output logic              lock_n,
	output logic              lk_oe,     // LOCK and LOCKE driven (2.3.7, 2.3.8)
	output logic              sas_oe,    // SAS driven (2.4.3)
	output logic              locke_n,
	output logic              ts_n,
	output logic              tip_n,
	output logic              tip_oe,
	output logic              sas_n,
	input  logic              ta_n,
	input  logic              tea_n,
	input  logic              tra_n,
	input  logic              tci_n,
	input  logic              tbi_n,
	input  logic              avec_n,
	input  logic              cla_n,
	output logic              br_n,
	input  logic              bg_n,
	input  logic              bgr_n,
	input  logic              ts_n_i,    // the bused TS (another master's)
	input  logic              bb_n_i,
	output logic              bb_n_o,
	output logic              bb_oe,
	input  logic              btt_n_i,
	output logic              btt_n_o,
	output logic              btt_oe,
	output logic              rsto_n
);

localparam int CW = (NC > 1) ? $clog2(NC) : 1;

typedef enum logic [2:0] {
	S_IDLE,     // no transfer
	S_C1,       // TS asserted this bus clock
	S_DATA,     // terminations sampled (after the ignore states), beats
	S_HOLD,     // extra data write hold after a write beat's TA
	S_GAP,      // a burst-inhibited line restarts with the next long word
	S_RETRY     // a retry with the bus given up: rerun once it is back
} state_t;

// arbitration (figure 7-41)
typedef enum logic [2:0] {
	B_RESET,    // after RSTI
	B_AMI,      // alternate master: implicit (BG not ours, no tenure seen)
	B_AME,      // alternate master: explicit (its TS seen, its tenure open)
	B_IMP,      // implicit ownership: BG ours, bus not driven
	B_EXP,      // explicit ownership: BB asserted, bus driven
	B_END1,     // end of tenure: BTT asserted
	B_END2      // ... BTT negated, then three-stated
} arb_t;

state_t      st;
arb_t        ab;
busreq_t     cur;
logic [CW-1:0] cur_c;
wire  [127:0] cur_wd = wdata[cur_c];   // stable until done/err (contract)
logic  [1:0] beat;        // beats completed so far in a line
logic  [1:0] a32;         // A3:A2 on the bus
logic        inhibited;   // line continued as long-word transfers
logic        locked;      // a locked sequence is open
logic  [3:0] ign;         // ignore states left before sampling
logic        bb_q;        // BB at the previous bus clock edge
logic        sas_hold;    // SAS driven negated a bus clock after the release
logic        sas_en;      // a_oe a bus clock ago: SAS stays three-stated in
                          // the first TS clock of a tenure (2.4.3)
logic        lk_hold;     // LOCK/LOCKE driven negated a bus clock after the
                          // address bus is released (they were asserted)
logic  [1:0] rst_et;      // reset from explicit ownership: its end of tenure
                          // (1 waits for a bus clock edge, 2 BTT asserted,
                          // 3 BTT negated), 7.11.2 and 7.13
logic        h_last;      // S_HOLD follows the transfer's last beat

//--------------------------------------------------------------------------
// arbitration among requesters: fixed priority.  An open locked sequence
// does not shut the others out: the instructions between its operand
// accesses may have to be fetched (MC68060UM C.2.2.3), and every transfer
// inside it carries LOCK (7.11.2)
//--------------------------------------------------------------------------
logic          pick_v;
logic [CW-1:0] pick_c;
always_comb begin
	pick_v = 1'b0;
	pick_c = '0;
	for (int i = NC - 1; i >= 0; i--)
		if (req[i]) begin
			pick_v = 1'b1;
			pick_c = CW'(i);
		end
end

// long-word data for a line's long word at A3:A2
function automatic logic [31:0] line_word(input logic [127:0] w, input logic [1:0] a);
	case (a)
		2'd0: line_word = w[127:96];
		2'd1: line_word = w[95:64];
		2'd2: line_word = w[63:32];
		default: line_word = w[31:0];
	endcase
endfunction

// BS3-BS0 from SIZ and A1:A0 (table 2-6; asserted low)
function automatic logic [3:0] bsel(input logic [1:0] s, input logic [1:0] a10);
	logic [3:0] b;       // b[0] = BS0 (D31-D24)
	case (s)
		SIZ_B:   b = 4'b0001 << a10;
		SIZ_W:   b = a10[1] ? 4'b1100 : 4'b0011;
		default: b = 4'b1111;
	endcase
	bsel = ~b;
endfunction

// the ignore state count for a beat (7.14.1): [15:12] read primary, [11:8]
// read secondary, [7:4] write primary, [3:0] write secondary
function automatic logic [3:0] icount(input logic rd, input logic secondary);
	if (!m_ign) icount = 4'd0;
	else case ({rd, secondary})
		2'b10:   icount = m_cnt[15:12];
		2'b11:   icount = m_cnt[11:8];
		2'b00:   icount = m_cnt[7:4];
		default: icount = m_cnt[3:0];
	endcase
endfunction

wire        beat_line = (cur.siz == SIZ_LINE) && !inhibited;  // a burst beat follows
wire        last_beat = (cur.siz != SIZ_LINE) || (beat == 2'd3);
wire        first     = (beat == 2'd0) && !inhibited;
wire        ta        = !ta_n;
wire        tea       = !tea_n;
wire        tra       = !tra_n;
// the termination this bus clock (table 7-5)
wire        t_err     = m_native ? tea : (tea && !(ta && first));
wire        t_retry   = m_native ? (!tea && tra && first) : (tea && ta && first);
wire        t_ok      = ta && !t_err && !t_retry;

// another master's TS (ours is not on ts_n_i while we drive it)
wire        ts_oth    = !ts_n_i && !(a_oe && !ts_n);
// keep the bus: BG ours, or a locked sequence open that BGR does not break
wire        keep_bus  = !bg_n || (locked && bgr_n);

logic [9:0] rsto_cnt;
logic       rsto_pend;         // RESET: RSTO once the transfer in progress ends
logic       unlock_pend;
logic       end_tenure;        // relinquish once the transfer in progress ends

always_ff @(posedge clk) begin
	gnt    <= '0;
	done   <= '0;
	err    <= '0;
	rvalid <= 1'b0;

	// (a reset acts on the bus clock edges only: the pins it releases change
	// there, and the release intervals are whole bus clocks, 2.3.7, 2.4.3)
	if (!nreset && !bclk_en) begin
	end
	else if (!nreset) begin
		st        <= S_IDLE;
		ab        <= B_RESET;
		cur       <= '0;
		cur_c     <= '0;
		beat      <= 2'd0;
		a32       <= 2'd0;
		inhibited <= 1'b0;
		locked    <= 1'b0;
		ign       <= 4'd0;
		h_last    <= 1'b0;
		rclient   <= '0;
		rdata     <= '0;
		rbeat     <= 2'd0;
		ravec     <= 1'b0;
		rtci      <= 1'b0;
		errbeat   <= 2'd0;
		a_o       <= '0;
		a_oe      <= 1'b0;
		d_o       <= '0;
		d_oe      <= 1'b0;
		rw_n      <= 1'b1;
		siz       <= 2'd0;
		bs_n      <= 4'hF;
		tt        <= 2'd0;
		tm        <= 3'd0;
		tln       <= 2'd0;
		upa       <= 2'd0;
		ciout_n   <= 1'b1;
		lock_n    <= 1'b1;
		locke_n   <= 1'b1;
		ts_n      <= 1'b1;
		sas_n     <= 1'b1;
		sas_en    <= 1'b0;
		br_n      <= 1'b1;
		bb_q      <= 1'b1;
		// BB, TIP and BTT: a reset in explicit ownership goes through the
		// end of tenure first, so other masters see the bus released (BTT
		// a bus clock asserted, one negated); BB and TIP are driven negated
		// before they are three-stated
		case (rst_et)
			2'd0: begin
				if (ab == B_EXP) begin
					rst_et   <= 2'd1;           // (BB still asserted)
					// SAS, and LOCK/LOCKE if asserted, as in an end of
					// tenure: driven negated, three-stated with BB
					sas_hold <= 1'b1;
					lk_hold  <= !lock_n || !locke_n;
				end
				else begin
					sas_hold <= 1'b0;
					lk_hold  <= 1'b0;
					if (bb_oe && !bb_n_o) bb_n_o <= 1'b1; else bb_oe <= 1'b0;
					if (tip_oe && !tip_n) tip_n <= 1'b1; else tip_oe <= 1'b0;
					btt_n_o <= 1'b1;
					btt_oe  <= 1'b0;
				end
			end
			2'd1: if (bclk_en) begin
				btt_n_o <= 1'b0; btt_oe <= 1'b1;
				bb_n_o  <= 1'b1; tip_n  <= 1'b1;
				sas_hold <= 1'b0; lk_hold <= 1'b0;
				rst_et  <= 2'd2;
			end
			2'd2: if (bclk_en) begin
				btt_n_o <= 1'b1;
				bb_oe   <= 1'b0; tip_oe <= 1'b0;
				rst_et  <= 2'd3;
			end
			default: if (bclk_en) begin
				btt_oe <= 1'b0;
				rst_et <= 2'd0;
			end
		endcase
		rsto_n    <= 1'b1;
		rsto_cnt  <= '0;
		rsto_pend <= 1'b0;
		unlock_pend <= 1'b0;
		end_tenure  <= 1'b0;
	end
	else begin
		// (a reset shorter than its end of tenure: release the pins)
		if (rst_et != 2'd0) begin
			rst_et  <= 2'd0;
			sas_hold <= 1'b0; lk_hold <= 1'b0;
			btt_n_o <= 1'b1; btt_oe <= 1'b0;
			bb_oe   <= 1'b0; tip_oe <= 1'b0;
		end
		// BB and TIP: negated for one CLK, then three-stated (7.1)
		if (bb_oe && bb_n_o && ab != B_EXP) bb_oe <= 1'b0;
		if (tip_oe && tip_n && ab != B_EXP) tip_oe <= 1'b0;

		// RESET instruction: RSTO for 512 CLK cycles, from the end of the
		// transfer in progress (below)
		if (rsto_cnt != 0) begin
			rsto_cnt <= rsto_cnt - 1'd1;
			if (rsto_cnt == 10'd1) rsto_n <= 1'b1;
		end
		if (rsto_req) rsto_pend <= 1'b1;

		if (unlock) unlock_pend <= 1'b1;
		if ((unlock || unlock_pend) && st == S_IDLE) begin
			// an abandoned locked sequence: LOCK and LOCKE go too
			locked      <= 1'b0;
			unlock_pend <= 1'b0;
			// (the pins change on a bus clock edge: wait for one)
			if (bclk_en) begin lock_n <= 1'b1; locke_n <= 1'b1; end
			else unlock_pend <= 1'b1;
		end

		if (bclk_en) begin
			logic start, tbi_now, lk_now;
			start   = 1'b0;
			tbi_now = 1'b0;
			// the sequence stays open for a transfer starting now unless the
			// processor has just abandoned it
			lk_now  = locked && !unlock && !unlock_pend;

			bb_q <= bb_n_i;
			sas_en <= a_oe;

			//--------------------------------------------------------------
			// arbitration
			//--------------------------------------------------------------
			case (ab)
			B_RESET:
				// a tenure another master may have open ends with BTT / BB
				ab <= (!bg_n && !ts_oth) ? B_IMP : ts_oth ? B_AME : B_AMI;
			B_AMI: begin
				if (ts_oth)                       ab <= B_AME;
				else if (!bg_n && bb_n_i)         ab <= B_IMP;
				else if (!bg_n)                   ab <= B_AME;   // BB still held
			end
			B_AME: begin
				// the other master's tenure ends with BTT, or with BB going
				// from asserted to negated (BB pulled up in a system using
				// BTT alone: its level says nothing, 7.11.2)
				if (!ts_oth && (!btt_n_i || (!bb_q && bb_n_i)))
					ab <= !bg_n ? B_IMP : B_AMI;
			end
			B_IMP: begin
				if (ts_oth)      ab <= B_AME;
				else if (bg_n)   ab <= B_AMI;
				// (to B_EXP: below, with the first TS)
			end
			B_EXP: ;
			B_END1: begin
				btt_n_o <= 1'b1;         // BTT negated for one bus clock
				lk_hold <= 1'b0;         // LOCK/LOCKE three-stated
				sas_hold <= 1'b0;        // SAS three-stated
				ab      <= B_END2;
			end
			B_END2: begin
				btt_oe  <= 1'b0;
				ab      <= !bg_n ? B_IMP : B_AMI;
			end
			default: ab <= B_AMI;
			endcase

			//--------------------------------------------------------------
			// transfers
			//--------------------------------------------------------------
			case (st)
			S_IDLE, S_RETRY: begin
				ts_n  <= 1'b1;
				sas_n <= 1'b1;
				d_oe  <= 1'b0;
				if (st == S_RETRY && drop[cur_c]) begin
					st <= S_IDLE;
					done[cur_c] <= 1'b1;
					finish_cycle();
				end
				else if (st == S_RETRY && halt) begin
					// halted: no bus cycle is rerun (7.9.3)
					st <= S_IDLE;
					err[cur_c] <= 1'b1;
					errbeat    <= 2'd0;
					finish_cycle();
				end
				else if ((pick_v || st == S_RETRY) && !sn_busy &&
				    (((ab == B_IMP) && !bg_n && !ts_oth) || (ab == B_EXP && keep_bus && !end_tenure))) begin
					start = 1'b1;
					if (st == S_IDLE) begin
						cur   <= breq[pick_c];
						cur_c <= pick_c;
						gnt[pick_c] <= 1'b1;
						// a locked transfer opens or continues the sequence;
						// the LOCKE transfer keeps it until it terminates
						// normally (finish_cycle), so a retry of it with BG
						// negated and BGR negated holds the bus (7.11.2)
						if (breq[pick_c].lock) locked <= 1'b1;
					end
				end
				else if (ab == B_EXP && (!keep_bus || end_tenure || halt)) begin
					// end of tenure: BTT one bus clock asserted, one negated;
					// BB negated for one CLK
					ab         <= B_END1;
					end_tenure <= 1'b0;
					btt_n_o    <= 1'b0;
					btt_oe     <= 1'b1;
					bb_n_o     <= 1'b1;
					tip_n      <= 1'b1;
					a_oe       <= 1'b0;
					lock_n     <= 1'b1;
					locke_n    <= 1'b1;
					// (asserted ones are driven negated for a bus clock more)
					lk_hold    <= !lock_n || !locke_n;
					sas_hold   <= 1'b1;
					sas_n      <= 1'b1;
				end
				else if (ab == B_EXP) begin
					// explicit owner with nothing to do: TIP negated, the
					// address and attributes keep being driven (undefined)
					tip_n <= 1'b1;
				end
			end

			S_C1: begin
				ts_n <= 1'b1;
				// SAS: the terminations are sampled at the end of this clock
				sas_n <= (ign != 4'd0);
				st    <= S_DATA;
			end

			S_GAP: begin
				// the next long word of a burst-inhibited line: a cycle of its own
				a_o   <= {cur.addr[31:4], a32, cur.addr[1:0]};
				siz   <= SIZ_L;
				bs_n  <= 4'h0;
				d_o   <= line_word(cur_wd, a32);
				ts_n  <= 1'b0;
				tip_n <= 1'b0;
				ign   <= icount(cur.rd, 1'b0);   // a long-word cycle: the primary count
				st    <= S_C1;
			end

			S_HOLD: begin
				// write data held one bus clock past its TA (7.14.3)
				if (h_last) begin
					d_oe <= 1'b0;
					st   <= S_IDLE;
					done[cur_c] <= 1'b1;
					finish_cycle();
				end
				else if (inhibited) st <= S_GAP;
				else begin
					d_o   <= line_word(cur_wd, cur.addr[3:2] + beat);
					ign   <= icount(1'b0, 1'b1);
					sas_n <= (icount(1'b0, 1'b1) != 4'd0);
					st    <= S_DATA;
				end
			end

			S_DATA: begin
				if (ign != 4'd0) begin
					// an ignore state: terminations are not looked at
					ign   <= ign - 4'd1;
					sas_n <= (ign != 4'd1);
				end
				else if (t_err) begin
					err[cur_c] <= 1'b1;
					errbeat    <= beat;
					// a bus error on a locked operand access ends the
					// sequence: the requester takes an access error and will
					// not complete it.  (One on an instruction fetch inside
					// it may be a prefetch never used: an access error taken
					// for it abandons the sequence through unlock.)
					if (cur.lock) begin
						locked  <= 1'b0;
						lock_n  <= 1'b1;        // (and the pins with it)
						locke_n <= 1'b1;
					end
					d_oe       <= 1'b0;
					sas_n      <= 1'b1;
					st         <= S_IDLE;
					finish_cycle();
				end
				else if (t_retry) begin
					// rerun the transfer from its start; with BG negated (and
					// no locked sequence held without BGR) the bus goes first.
					// A halted processor starts no bus cycle (7.9.3): the
					// transfer ends in error instead (a prefetch nobody uses)
					sas_n <= 1'b1;
					if (halt) begin
						err[cur_c] <= 1'b1;
						errbeat    <= beat;
						d_oe       <= 1'b0;
						st         <= S_IDLE;
						finish_cycle();
					end
					else if (!keep_bus) begin
						d_oe <= 1'b0;
						st   <= S_RETRY;
					end
					else begin
						a32   <= cur.addr[3:2];
						a_o   <= cur.addr;
						d_o   <= (cur.siz == SIZ_LINE) ? line_word(cur_wd, cur.addr[3:2]) : cur_wd[31:0];
						ts_n  <= 1'b0;
						ign   <= icount(cur.rd, 1'b0);
						st    <= S_C1;
					end
				end
				else if (t_ok) begin
					logic [1:0] lw;
					lw = cur.addr[3:2] + beat;           // the long word this beat moves
					if (cur.rd) begin
						rvalid  <= 1'b1;
						rclient <= cur_c;
						rdata   <= d_i;
						rbeat   <= lw;
						ravec   <= !avec_n;
						if (beat == 2'd0 && !inhibited) rtci <= !tci_n;
					end
					if (last_beat) begin
						if (!cur.rd && m_hold) begin
							sas_n  <= 1'b1;
							h_last <= 1'b1;
							st     <= S_HOLD;
						end
						else begin
							d_oe  <= 1'b0;
							sas_n <= 1'b1;
							st    <= S_IDLE;
							done[cur_c] <= 1'b1;
							finish_cycle();
						end
					end
					else begin
						beat <= beat + 1'd1;
						if ((beat == 2'd0 && !inhibited && !tbi_n) || inhibited) begin
							// TBI with the first TA: the rest as long words,
							// from the long word after the one just moved,
							// whatever CLA did to A3:A2 (7.7.2, 7.7.4)
							tbi_now   = 1'b1;
							inhibited <= 1'b1;
							a32       <= lw + 2'd1;
							sas_n     <= 1'b1;
							h_last    <= 1'b0;
							st        <= (!cur.rd && m_hold) ? S_HOLD : S_GAP;
						end
						else if (!cur.rd && m_hold) begin
							sas_n  <= 1'b1;
							h_last <= 1'b0;
							st     <= S_HOLD;
						end
						else begin
							// burst: the next long word, after its ignore states
							d_o   <= line_word(cur_wd, lw + 2'd1);
							ign   <= icount(cur.rd, 1'b1);
							sas_n <= (icount(cur.rd, 1'b1) != 4'd0);
						end
					end
				end
				else
					sas_n <= 1'b1;   // a wait state: SAS marks only the first sample (2.4.3)
			end

			default: st <= S_IDLE;
			endcase

			// CLA (7.7.7): sampled from the edge after TS on, on every edge
			// of a burst, the ignore states included; each sample advances
			// A3:A2, wrapping in the line.  (A retry's restart and a TBI's
			// continuation override it.)
			if ((st == S_C1 || st == S_DATA || st == S_HOLD) && beat_line && !cla_n &&
			    !(st == S_DATA && ign == 4'd0 && t_retry) && !tbi_now) begin
				a32      <= a32 + 2'd1;
				a_o[3:2] <= a32 + 2'd1;
			end

			if (start) begin
				// drive the transfer (S_IDLE: the request picked; S_RETRY: cur)
				busreq_t r;
				logic [127:0] w;
				r = (st == S_RETRY) ? cur : breq[pick_c];
				w = (st == S_RETRY) ? cur_wd : wdata[pick_c];
				ab        <= B_EXP;
				bb_n_o    <= 1'b0;
				bb_oe     <= 1'b1;
				beat      <= 2'd0;
				inhibited <= 1'b0;
				a32       <= r.addr[3:2];
				a_o       <= r.addr;
				a_oe      <= 1'b1;
				rw_n      <= r.rd;
				siz       <= r.siz;
				bs_n      <= bsel(r.siz, r.addr[1:0]);
				tt        <= r.tt;
				tm        <= r.tm;
				tln       <= r.tln;
				upa       <= r.upa;
				// (an acknowledge cycle -- interrupt, breakpoint, the LPSTOP
				// broadcast -- has CIOUT negated, table 7-2)
				ciout_n   <= !r.ci || (r.tt == 2'd3);
				lock_n    <= !(r.lock || lk_now);
				locke_n   <= !(r.lock && r.locke);
				d_o       <= (r.siz == SIZ_LINE) ? line_word(w, r.addr[3:2]) : w[31:0];
				d_oe      <= !r.rd;
				ts_n      <= 1'b0;
				tip_n     <= 1'b0;
				tip_oe    <= 1'b1;
				ign       <= icount(r.rd, 1'b0);
				st        <= S_C1;
			end

			// RESET: RSTO once no transfer is in progress or starting (the
			// fetch is held from the request on, the store buffer is empty)
			if (rsto_pend && st == S_IDLE && !start) begin
				rsto_pend <= 1'b0;
				rsto_n    <= 1'b0;
				rsto_cnt  <= 10'd512;
			end

			// BR: the internal request, registered (7.11.2): asserted while a
			// transfer waits to start, whoever owns the bus, and negated with
			// the TS of the last one needed; negated while halted
			begin
				logic [NC-1:0] pend;
				pend = (req & ~gnt) | more;      // (a request lasts a clock past its grant)
				if (start && st == S_IDLE) pend[pick_c] = 1'b0;
				br_n <= halt || !((|pend) || (st == S_RETRY && !start && !drop[cur_c]));
			end
		end
	end
end

// a transfer ended (normally or with a bus error): LOCK/LOCKE negate after
// the LOCKE transfer; with BG negated the tenure ends unless a locked
// sequence holds the bus
task automatic finish_cycle();
	if (cur.lock && cur.locke) begin
		locked  <= 1'b0;
		lock_n  <= 1'b1;
		locke_n <= 1'b1;
	end
endtask

assign idle      = (st == S_IDLE);
assign lk_oe     = a_oe || lk_hold;
assign sas_oe    = (a_oe && sas_en) || sas_hold;
// (rst_et lives through the reset: only power-up clears it)
initial begin rst_et = 2'd0; lk_hold = 1'b0; sas_hold = 1'b0; sas_en = 1'b0; end
assign own       = (ab == B_IMP) || (ab == B_EXP);
assign rsto_busy = !rsto_n || rsto_pend;

endmodule
