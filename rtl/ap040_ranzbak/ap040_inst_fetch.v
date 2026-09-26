//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_inst_fetch.v - IF stage with a prefetch queue (Minimig plan M1)    //
//                                                                          //
// Fetches two 16-bit words per clock (one 32-bit read of L1 port A) into  //
// a six-word queue; ID takes 0, 1 or 2 words from its head per clock.     //
// Two words a clock is what lets an instruction with one extension word   //
// (MOVE.L (d16,An),Dn) pass ID in one clock, as on the 68040 (M68040UM     //
// 10.4, p. 10-9: <ea> calculate 1, execute 1) -- the M0.5 cycle checker   //
// measured 3 clocks with the one-word IF.                                  //
//                                                                          //
// A redirect (EX's flush, or ID's guessed-taken branch) empties the queue, //
// drops the fetch in flight, and fetches at the target in the same clock. //
//                                                                          //
// Fetch port (plan M5): f_req/f_addr/f_long held until f_gnt; the answer   //
// f_ack/f_data (the two words, or the one in f_data[31:16]) comes one or  //
// more clocks later.  One fetch outstanding; a new one may issue in the   //
// clock the previous answers.  A redirect while a fetch is outstanding    //
// marks its answer for dropping.  LONG_ANY = 1: always two words (the L1  //
// test substrate reads any word pair); 0: one word at a word address that //
// is not longword aligned (the bus).                                      //
//                                                                          //
// FETCH_AT_RESET = 0: idle after reset until the first redirect (the reset //
// vector fetch in EA-fetch supplies it).  PROG_WORDS bounds how many words //
// are fetched (the milestone benches' drain checks rely on it).           //
//                                                                          //
// Debug view (dbg_if_*): valid/pc of the queue head, i.e. the word ID sees. //
//--------------------------------------------------------------------------//

module ap040_inst_fetch
#(
	parameter [31:0] PC_RESET       = 32'h0000_0400,
	parameter         PROG_WORDS     = 10,
	parameter         L1_AW          = 12,
	parameter         FETCH_AT_RESET = 1,
	parameter         LONG_ANY       = 1
)
(
	input             clk,
	input             nreset,
	input             ce,

	input             redirect_valid,
	input      [31:0] redirect_pc,
	input             redirect_s,   // (with redirect_valid) the S bit the new stream runs under (M7)
	input             redirect_hold, // (with redirect_valid) take it, but fetch one clock later:
	                                 // a store into the code is still on its way to memory

	input             fetch_hold,   // no new fetch (a PTEST/PFLUSH owns the MMU, M7)
	input       [1:0] consume,      // words ID takes from the head this clock
	input       [1:0] consume_nf,   // the same without ID's flush term: equal whenever
	                                // redirect_valid is low, which is the only time
	                                // after_c and qpc look at it (timing)

	output            f_req,
	output     [31:0] f_addr,
	output            f_long,       // two words (else one)
	input             f_gnt,        // the request is taken this clock
	output            f_s,          // the request's S bit: its FC is 6 or 2
	input             f_ack,        // the answer
	input      [31:0] f_data,       // {word at addr, word at addr+2}
	input             f_err,        // ... is an access error (M6): its words are poisoned
	input             f_atc,        // ... from the MMU

	output            q_v0,         // head word valid
	output            q_v1,         // second word valid
	output     [31:0] q_pc0,        // address of the head word
	output     [15:0] q_w0,
	output     [15:0] q_w1,
	output            q_e0,         // the head word is poisoned (its fetch faulted)
	output            q_e1,
	output reg [31:0] pf_addr,      // the faulted fetch: address, two words, ATC
	output reg        pf_long,
	output reg        pf_atc,
	// the code held here: every word queued or in flight lies in [q_lo, q_hi)
	output     [31:0] q_lo,
	output     [31:0] q_hi
);

localparam QN = 6;

reg [15:0] q [0:QN-1];
reg  [2:0] qcnt;
reg [31:0] qpc;           // address of q[0]
reg [31:0] fpc;           // next fetch address
reg        infl;          // a fetch is outstanding
reg        fdrop;         // ... and its answer is to be dropped (a redirect came after it)
reg [31:0] f_fa;          // ... and its address
reg  [1:0] infl_n;        // how many words it carries
reg [31:0] issued;        // words handed to ID so far
reg        running;
reg        hold;          // no fetch this clock (after an SMC redirect)
reg        qerr [0:QN-1]; // poisoned words (M6: a fault is raised only if the word is used)
reg        pstop;         // a fetch faulted: no more fetches until a redirect

// PROG_WORDS bounds the words handed to ID (as the milestone-4 IF counted
// the words it presented), not the words fetched
// PROG_WORDS >= 32'h7FFF_FFFF means NO bound (the compat wrapper, i.e. every
// real build): the count would otherwise run out after 2^31 words -- a few
// minutes of a running Amiga -- and IF would hand ID nothing ever again, a
// hard freeze with no fault and no halt.  It also kept a 32-bit counter and
// comparator on the path from IF's queue into ID, EA-calc and the fetch PC.
localparam PROG_BOUNDED = (PROG_WORDS < 32'h7FFF_FFFF);
assign q_v0  = (qcnt >= 3'd1) && (!PROG_BOUNDED || (issued < PROG_WORDS));
assign q_v1  = (qcnt >= 3'd2) && (!PROG_BOUNDED || (issued + 32'd1 < PROG_WORDS));
assign q_pc0 = qpc;
assign q_w0  = q[0];
assign q_w1  = q[1];
assign q_e0  = qerr[0];
assign q_e1  = qerr[1];

wire [31:0] fa        = redirect_valid ? redirect_pc : fpc;
// The fetch function code follows the stream, not WB's SR: a redirect that
// changes S (RTE, an exception, a MOVE to SR) brings the new S with it, and
// the fetch it starts may go out before WB commits the SR (the RTE to user
// in t_mmu.s "8K user-mode demand paging" fetched through the supervisor
// root otherwise).  Every SR write redirects, so fs is never stale.
reg         fs;
assign f_s = redirect_valid ? redirect_s : fs;
wire  [1:0] want      = (LONG_ANY != 0 || !fa[1]) ? 2'd2 : 2'd1;
wire        got       = infl && f_ack;                      // an answer this clock
wire        use_ans   = got && !fdrop && !redirect_valid;  // ... that goes into the queue
wire  [2:0] after_c   = redirect_valid ? 3'd0 : (qcnt - {1'b0, consume_nf});
wire  [2:0] pend      = (!redirect_valid && infl && !fdrop) ? {1'b0, infl_n} : 3'd0;
assign q_lo = qpc;
assign q_hi = fpc;
// a request goes out when there is room for the answer and no other fetch
// is outstanding (or it answers now)
wire        want_req  = (running || redirect_valid) && !hold && !(redirect_valid && redirect_hold) &&
                        !(pstop && !redirect_valid) && !fetch_hold &&
                        (!infl || f_ack) && (after_c + pend + 3'd2 <= QN);
assign f_req  = ce && want_req;
assign f_addr = fa;
assign f_long = (want == 2'd2);
wire        can_issue = f_req && f_gnt;

integer k;
reg [15:0] nq [0:QN-1];
reg        ne [0:QN-1];
reg  [2:0] ncnt;

always @(posedge clk) begin
	if (!nreset) begin
		qcnt    <= 3'd0;
		qpc     <= PC_RESET;
		fpc     <= PC_RESET;
		infl    <= 1'b0;
		fdrop   <= 1'b0;
		infl_n  <= 2'd0;
		issued  <= 32'd0;
		running <= (FETCH_AT_RESET != 0);
		hold    <= 1'b0;
		pstop   <= 1'b0;
		fs      <= 1'b1;
		pf_addr <= 32'd0; pf_long <= 1'b0; pf_atc <= 1'b0;
		for (k = 0; k < QN; k = k + 1) begin q[k] <= 16'h4E71; qerr[k] <= 1'b0; end
	end else if (ce) begin
		// pop what ID took, append what arrives (not after a redirect)
		for (k = 0; k < QN; k = k + 1) begin
			nq[k] = (k + consume < QN) ? q[k + consume] : 16'h4E71;
			ne[k] = (k + consume < QN) ? qerr[k + consume] : 1'b0;
		end
		if (redirect_valid) for (k = 0; k < QN; k = k + 1) ne[k] = 1'b0;
		ncnt = after_c;
		if (use_ans) begin
			// (a poisoned word reads as NOP: ID sizes the instruction from
			// defined words, and the MMU's data on a fault is not defined)
			nq[ncnt] = f_err ? 16'h4E71 : f_data[31:16]; ne[ncnt] = f_err;
			if (infl_n == 2'd2) begin nq[ncnt + 1] = f_err ? 16'h4E71 : f_data[15:0]; ne[ncnt + 1] = f_err; end
			ncnt = ncnt + {1'b0, infl_n};
		end
		for (k = 0; k < QN; k = k + 1) begin q[k] <= nq[k]; qerr[k] <= ne[k]; end
		// a faulted fetch: remember it, fetch no further until a redirect
		if (use_ans && f_err) begin
			pstop <= 1'b1; pf_addr <= f_fa; pf_long <= (infl_n == 2'd2); pf_atc <= f_atc;
		end
		if (redirect_valid) pstop <= 1'b0;
		if (redirect_valid) fs <= redirect_s;
		qcnt <= ncnt;
		if (redirect_valid) begin
			qpc     <= redirect_pc;
			running <= 1'b1;
		end else begin
			qpc <= qpc + {29'd0, consume_nf, 1'b0};
		end
		hold   <= redirect_valid && redirect_hold;
		if (can_issue) begin
			infl <= 1'b1; infl_n <= want; fdrop <= 1'b0; f_fa <= fa;
		end else if (got) begin
			infl <= 1'b0; fdrop <= 1'b0;
		end
		// a redirect while a fetch is outstanding (and not answering now): drop its answer
		if (redirect_valid && infl && !f_ack && !can_issue) fdrop <= 1'b1;
		issued <= issued + {30'd0, consume};
		if (can_issue) begin
			fpc    <= fa + {29'd0, want, 1'b0};
		end else if (redirect_valid) begin
			fpc    <= redirect_pc;
		end
	end
end

endmodule
