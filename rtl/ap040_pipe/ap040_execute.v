//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 17: address error)       //
//                                                                          //
// ap040_execute.v - EX stage                                              //
//                                                                          //
// Instantiates ap040_pipe_alu.v (this directory's own fork of              //
// rtl/ap040/ap040_alu.v -- see its header) unmodified -- it is purely      //
// combinational and stateless, so it drops into a single pipeline stage    //
// as-is. `op` and `b` are both plain data connections to decode/EA-fetch's //
// fields, not hardcoded -- MOVEQ/MOVE.L decode to AP040_ALU_MOVE (result = //
// a, N/Z from the result, V/C cleared, X passed through from flags_in --   //
// confirmed by reading ap040_pipe_alu.v:139-142) and ignore `b` entirely;  //
// ADD.L Dn,Dm decodes to AP040_ALU_ADD and uses both operands (confirmed   //
// against ap040_pipe_alu.v:144-147: result/flags_out come entirely from    //
// a/b, never flags_in, so this op needs no CCR forwarding). A further op   //
// only needs decode to emit a different eaf_alu_op -- no new mux logic     //
// here.                                                                    //
//                                                                          //
// Exposes the pipeline's "EX-forward" tap: the live combinational result   //
// this cycle (ALU output, or the Scc byte-merge below), for                //
// ap040_ea_fetch.v to bypass around the regfile when the producer is       //
// still here (one stage ahead of the consumer's own EA-fetch cycle) and    //
// hasn't committed yet. See ap040_ea_fetch.v's header comment for the      //
// full forwarding picture, including the port-B compare added in           //
// milestone 3 for the case where the destination register is also read     //
// as an ALU operand.                                                       //
//                                                                          //
// Bcc condition check happens HERE, not in decode or any earlier stage,    //
// and that placement was derived from the actual pipeline timing, not      //
// assumed: an immediately-adjacent flag-setter (the tightest case) is      //
// only committing (driving exe_result_flags/commit_ccr --                  //
// ap040_pipe_core.v's write-through-style ccr_in source) at the exact      //
// cycle the branch itself reaches EX. Checking any earlier (e.g. in id_*,  //
// where GPR fields are recognized) is too early -- the producer would      //
// still be sitting in EA-calc, short of both this core's forwarding        //
// sources. So ccr_in already carries a correctly-forwarded value by the    //
// time it reaches this port; no separate CCR-forward mux lives in this     //
// file, unlike the GPR case which needed one (ex_fwd_*) precisely because   //
// GPR reads happen a stage earlier, in ap040_ea_fetch.v.                   //
//                                                                          //
// cond_true() mirrors ap040_core.v:720-740's condition-code table exactly  //
// -- an independent copy, not a shared function, same non-coupling         //
// precedent as sxb/d_reg9 in ap040_decode.v (milestone 3): this core's      //
// decode/execute logic stays decoupled from the sequential core's. Every   //
// one of its 16 encodings (T/F/14 real conditions) is implemented, not a    //
// subset -- reused as-is by both Bcc and, this milestone, Scc, since they   //
// share the same 4-bit condition-code field position (if_opcode[11:8]).    //
//                                                                          //
// Scc.B Dn: result = cond_true(cc) ? 8'hFF : 8'h00, merged into             //
// eaf_operand_b's upper 24 bits (the destination register's current,       //
// already-forwarded value -- confirmed against ap040_core.v:2122-2130's    //
// EK_SCC: same fill, same merge, no flag change at all). The merge happens //
// here, in the caller, not inside ap040_pipe_alu.v -- matching that file's  //
// own documented convention that it never merges by size internally        //
// (callers do). "No flag change" is why exe_writes_ccr exists as a signal   //
// distinct from exe_writes_reg: Scc writes a register but must never        //
// update CCR.                                                              //
//                                                                          //
// ex_recovery_pc (changed milestone 7): now eaf_next_pc directly, not       //
// eaf_pc + 32'd2. Every instruction before Bcc.W/Bcc.L was exactly one      //
// word, so "+2" was correct only by coincidence of scope; ap040_decode.v    //
// now computes the actual next-instruction address itself (accounting for   //
// however many extension words a branch consumed) and threads it as its     //
// own field -- see its header comment. No arithmetic is left here at all.   //
//                                                                          //
// DBcc Dn,<label> (milestone 8, new): decode always speculatively           //
// redirected IF to the branch target (same "assume taken" policy as Bcc),   //
// so this stage's only new job is computing the REAL outcome and comparing  //
// it to that guess -- reusing ex_mispredict/ex_recovery_pc exactly as they   //
// already exist, no new redirect path. Per ap040_core.v's S_DBCC1/S_DBCC2    //
// (ap040_core.v:3040-3059) and its 0x5 decode group (ap040_core.v:5415-      //
// 5421), verified rather than assumed:                                      //
//   - if cond_true(cc): the loop terminates WITHOUT decrementing Dn at all   //
//     -- register write and branch are both suppressed.                     //
//   - else: Dn's low 16 bits decrement by one (high 16 bits pass through     //
//     unchanged -- a word-sized RMW on a 32-bit register, not a full-word    //
//     overwrite); if the result != $FFFF the branch IS taken (to the same    //
//     target decode already guessed), otherwise the loop has expired and     //
//     falls through. Either way -- taken or expired -- Dn's decremented      //
//     value is written back; only the cond_true case above skips the write   //
//     entirely.                                                             //
// This makes DBcc the first instruction whose exe_writes_reg depends on a    //
// RUNTIME value rather than a static decode-time bit: eaf_writes_reg stays   //
// 0 from decode (like Bcc), and writes_reg_resolved below overrides it        //
// dynamically off cond_result for eaf_is_dbcc, gating both the regfile        //
// commit (ap040_pipe_core.v's commit_reg) and the EX-forward tap the same     //
// way. exe_writes_ccr is untouched (stays 0, from decode) -- DBcc never        //
// affects flags on real hardware, confirmed by the absence of any CCR         //
// update in ap040_core.v's S_DBCC1/S_DBCC2.                                  //
//                                                                          //
// NOT implemented (deferred, same discipline as TRAPcc's exception-delivery  //
// dependency in milestone 6): the real 68040 checks the branch TARGET's       //
// parity before the condition, even on an iteration that would not have       //
// branched (ap040_core.v's own S_DBCC1 comment, citing cputest 68040_ae       //
// DBcc.W) -- an odd target always faults. That needs exception delivery       //
// (vector fetch, supervisor frame push), which this pipeline doesn't have     //
// yet; a target-parity check with nowhere to deliver the fault would be       //
// worse than not checking at all, so it's left for whichever milestone        //
// builds exception delivery, not silently guessed at here.                   //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_execute
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // WB cannot accept this cycle

	input             eaf_valid,
	input      [31:0] eaf_pc,
	input      [31:0] eaf_next_pc,
	input       [3:0] eaf_dest_reg,
	input      [31:0] eaf_operand_a,
	input      [31:0] eaf_operand_b,
	input       [5:0] eaf_alu_op,
	input       [1:0] eaf_size,
	input       [5:0] eaf_shcnt,
	input             eaf_writes_an,
	input       [3:0] eaf_an_reg,
	input      [31:0] eaf_an_data,
	input             eaf_writes_reg,
	input             eaf_writes_ccr,
	input             eaf_is_branch,
	input             eaf_is_scc,
	input             eaf_is_dbcc,
	input             eaf_is_jmp,
	input             eaf_is_div,
	input             eaf_div_signed,
	input             eaf_is_trapcc,
	input             eaf_is_fmterr,
	input             eaf_is_trace,
	input             eaf_is_chk,
	input             eaf_is_immsr,
	input             eaf_immsr_to_sr,
	input             eaf_is_pea,
	input             eaf_is_link,
	input             eaf_is_bsr,
	input             eaf_is_jsr,
	input             eaf_is_trap,
	input             eaf_is_illegal,
	input             eaf_is_priv,
	input             eaf_is_addrerr,
	input             eaf_is_divzero,
	input             eaf_is_movesr,
	input             eaf_is_movec,
	input             eaf_movec_dir,
	input       [2:0] eaf_movec_sel,
	input             eaf_is_rts,
	input             eaf_is_rte,
	input      [15:0] eaf_rte_sr_data,
	input       [3:0] eaf_cond,

	input       [4:0] ccr_in,    // already write-through-forwarded by
	                              // ap040_pipe_core.v -- see header comment
	// The OLD (pre-fault) SR, for exception entry's masking arithmetic --
	// ap040_ea_fetch.v's OWN already-correctly-forwarded read of the SAME
	// value (its exc_sr_word), threaded straight down rather than read
	// live again here: this stage's own EX-live SR forward (ex_sr_fwd_*
	// below) feeds INTO ap040_pipe_core.v's sr_resolved, so taking a fresh
	// "live" read of sr_resolved back INTO this stage would be a genuine
	// combinational loop, not just a staleness risk -- see header.
	input      [15:0] eaf_sr_snapshot,

	// MOVEC's read direction (control register -> GPR): the seven control
	// registers' CURRENT values, fed straight from ap040_pipe_core.v (their
	// actual home), not threaded through ap040_decode.v/ap040_ea_calc.v/
	// ap040_ea_fetch.v at all -- these are live architectural state, not
	// per-instruction pipeline data, the same reasoning ccr_in is wired
	// straight in rather than passed stage by stage.
	input      [31:0] sfc_in,
	input      [31:0] dfc_in,
	input      [31:0] cacr_in,
	input      [31:0] vbr_in,
	input      [31:0] usp_in,
	input      [31:0] isp_in,
	input      [31:0] msp_in,

	// Read-modify-write store half (milestone 48). This stage is the first
	// in the pipeline to touch memory, and it has to be: an RMW's store data
	// is the ALU RESULT, which does not exist until here, while
	// ap040_ea_fetch.v issues every other store a stage earlier from a
	// register it already holds.
	//
	// EX wins the port unconditionally rather than being arbitrated fairly.
	// It is the OLDER instruction -- ap040_ea_fetch.v is working on the next
	// one -- so making the younger one wait is both correct and deadlock-
	// free, while the reverse could starve an RMW behind a run of loads.
	// port_taken carries that decision backward.
	//
	// If the L1 cannot accept the write (l1_wr_busy), this stage stalls and
	// retries, holding its own output registers as well as EA-fetch's. That
	// second part matters: ex_stall used to be a pure pass-through of
	// stall_in, so the update below was gated on stall_in alone, and a local
	// stall that did not also gate it would retire the instruction
	// downstream while its store was still pending -- and then store again
	// on the retry.
	input             eaf_is_rmw,
	input      [31:0] eaf_ea_target,
	input             l1_wr_busy,
	output            ex_st_req,
	output     [31:0] ex_st_addr,   // BYTE address; the core converts
	output     [31:0] ex_st_data,
	output      [3:0] ex_st_be,

	output            ex_stall,

	// Condition-code forward (milestone 74): the flags this stage's
	// instruction will register THIS cycle, live. ap040_pipe_core.v folds
	// them into sr_resolved so a consumer one stage EARLIER than EX -- the
	// exception frame's stacked SR, and TRAPcc's condition -- sees the
	// instruction ahead of it. commit_ccr covers only the instruction in WB;
	// between the two there was a one-cycle window in which an ALU op's
	// flags existed but nobody upstream could read them. Bcc/Scc/DBcc never
	// noticed, since they evaluate here in EX.
	output            ex_ccr_fwd_valid,
	output      [4:0] ex_ccr_fwd_data,
	output            ex_br_resolve,   // a Bcc/DBcc is final this cycle...
	output            ex_br_taken,     // ...and this is its verdict (T0 trace, milestone 79)

	// "EX-forward" tap (combinational, live this cycle)
	output            ex_fwd_valid,
	output            ex_fwd2_valid,
	output      [3:0] ex_fwd2_dest,
	output     [31:0] ex_fwd2_data,
	output      [3:0] ex_fwd_dest,
	output     [31:0] ex_fwd_data,

	// SR's OWN EX-forward tap (milestone 15, new) -- the same "producer
	// still here, one stage ahead of a consumer's EA-fetch cycle" case
	// ex_fwd_* already covers for GPRs, now needed for SR too: a MOVE-to-SR
	// (or an exception) sitting HERE, not yet committed, must still be
	// visible to whatever's reading the live S/M bits one stage earlier in
	// ap040_ea_fetch.v (its eac_is_priv check, or ap040_pipe_regfile.v's
	// own sr_s/sr_m bank select) THIS SAME cycle -- see
	// ap040_pipe_core.v's sr_resolved for where this feeds in.
	output            ex_sr_fwd_valid,
	output     [15:0] ex_sr_fwd_data,

	// Misprediction signal (combinational, live this cycle) -- see header
	// comment. ap040_pipe_core.v broadcasts this as `flush` to ID/EA-calc/
	// EA-fetch and redirects IF to ex_recovery_pc.
	output            ex_mispredict,
	output     [31:0] ex_recovery_pc,

	output reg        exe_valid,
	output reg [31:0] exe_pc,
	output reg  [3:0] exe_dest_reg,
	output reg [31:0] exe_result_data,
	output reg        exe_writes_reg,
	output reg  [3:0] exe_dest_reg2,
	output reg [31:0] exe_result_data2,
	output reg        exe_writes_reg2,
	output reg        exe_writes_ccr,
	output reg  [4:0] exe_result_flags,

	// New commit paths, milestone 15 -- see header. Both gated by exe_valid
	// exactly like exe_writes_reg/exe_writes_ccr already are; neither ever
	// fires together with the other (MOVE-to-SR/an exception writes SR;
	// MOVEC's write direction writes a control register; mutually
	// exclusive by construction).
	output reg        exe_writes_sr,
	output reg [15:0] exe_sr_data,
	output reg        exe_writes_creg,
	output reg  [2:0] exe_creg_sel,
	output reg [31:0] exe_creg_data
);

assign ex_st_req = eaf_valid && eaf_is_rmw;
wire   rmw_wait  = ex_st_req && l1_wr_busy;
assign ex_stall  = stall_in || rmw_wait || div_wait;

// ------------------------------------------------------------- divide
// A 32/16 divide cannot be combinational the way the 16x16 multiply can, so
// this is an iterative restoring divider that holds the pipeline. It lives
// here rather than in ap040_pipe_alu.v because it has state; the ALU is
// purely combinational and staying that way is worth more than uniformity.
//
// It reuses milestone 48's local-stall machinery wholesale: div_wait joins
// rmw_wait in ex_stall, which both freezes ap040_ea_fetch.v and -- through
// the same gate milestone 48 had to move from stall_in to ex_stall -- holds
// this stage's own output registers, so the instruction retires exactly
// once. That gate was unreachable then and is exercised now.
//
// Thirty-two steps, not sixteen. A 32-bit quotient is computed and then
// checked for fitting in 16 bits, which is the same test as the 68k's
// "upper word of the dividend >= divisor" precondition but does not need to
// be reasoned about separately.
//
// The divisor is never zero here: ap040_ea_fetch.v turns that into a
// vector-5 exception before the instruction reaches this stage.
reg        div_busy;
reg  [5:0] div_cnt;
reg [31:0] div_dvd;      // shifts left; its low bits collect the quotient
reg [16:0] div_rem;
reg [15:0] div_dsr;
reg        div_qneg, div_rneg;

wire        div_req    = eaf_valid && eaf_is_div;
wire [16:0] div_rem_sh = {div_rem[15:0], div_dvd[31]};
wire        div_rem_ge = (div_rem_sh >= {1'b0, div_dsr});
wire        div_fin    = div_busy && (div_cnt == 6'd0);
wire        div_wait   = div_req && !div_fin;

// Signed division is done on magnitudes and re-signed afterwards: the
// quotient takes the XOR of the operand signs, the remainder takes the
// DIVIDEND's sign. That second rule is the one worth stating -- it is not
// the sign of the divisor and it is not always the sign of the quotient.
wire [31:0] div_dividend = eaf_operand_b;
wire [15:0] div_divisor  = eaf_operand_a[15:0];
wire        dvd_neg = eaf_div_signed && div_dividend[31];
wire        dsr_neg = eaf_div_signed && div_divisor[15];
wire [31:0] dvd_mag = dvd_neg ? (~div_dividend + 32'd1) : div_dividend;
wire [15:0] dsr_mag = dsr_neg ? (~div_divisor  + 16'd1) : div_divisor;

wire [31:0] q_mag = div_dvd;
wire [15:0] r_mag = div_rem[15:0];
wire [15:0] div_q = div_qneg ? (~q_mag[15:0] + 16'd1) : q_mag[15:0];
wire [15:0] div_r = div_rneg ? (~r_mag       + 16'd1) : r_mag;
wire [31:0] div_result = {div_r, div_q};

// Overflow. Unsigned: anything above 16 bits. Signed: the magnitude must fit
// a 16-bit signed value, which allows 32768 only when the quotient is
// negative. On overflow the destination is left UNCHANGED and V is set --
// the first instruction in this core that can fail without writing.
wire div_ovf = eaf_div_signed ? (div_qneg ? (q_mag > 32'd32768) : (q_mag > 32'd32767))
                              : (|q_mag[31:16]);

// N and Z come from the 16-bit quotient. On overflow the 68k leaves them
// undefined; this core defines them as cleared rather than leaving X's in
// simulation. X is passed through, as it is for every non-arithmetic op.
wire [4:0] div_flags = div_ovf ? {ccr_in[4], 1'b0, 1'b0, 1'b1, 1'b0}
                               : {ccr_in[4], div_q[15], (div_q == 16'd0), 1'b0, 1'b0};

always @(posedge clk) begin
	if (!nreset) begin
		div_busy <= 1'b0;
		div_cnt  <= 6'd0;
		div_dvd  <= 32'h0;
		div_rem  <= 17'h0;
		div_dsr  <= 16'h0;
		div_qneg <= 1'b0;
		div_rneg <= 1'b0;
	end else if (ce) begin
		if (div_req && !div_busy) begin
			div_busy <= 1'b1;
			div_cnt  <= 6'd32;
			div_rem  <= 17'd0;
			div_dvd  <= dvd_mag;
			div_dsr  <= dsr_mag;
			div_qneg <= dvd_neg ^ dsr_neg;
			div_rneg <= dvd_neg;
		end else if (div_busy && div_cnt != 6'd0) begin
			div_rem <= div_rem_ge ? (div_rem_sh - {1'b0, div_dsr}) : div_rem_sh;
			div_dvd <= {div_dvd[30:0], div_rem_ge};
			div_cnt <= div_cnt - 6'd1;
		end else if (div_fin) begin
			div_busy <= 1'b0;
		end
	end
end

wire [31:0] alu_result;
wire [4:0]  alu_flags;

ap040_pipe_alu alu
(
	.op        (eaf_alu_op),
	.size      (eaf_size),
	.shcnt     (eaf_shcnt),
	.a         (eaf_operand_a),
	.b         (eaf_operand_b),
	.flags_in  (ccr_in),
	.result    (alu_result),
	.flags_out (alu_flags)
);

// ap040_core.v:720-740 equivalent. ccr_in bit order matches AP040_SR_C/V/
// Z/N (ap040_defs.svh): bit0=C, bit1=V, bit2=Z, bit3=N.
function cond_true;
	input [3:0] cond;
	input [4:0] ccr;
	begin
		case (cond)
			4'h0: cond_true = 1'b1;                              // T (BRA)
			4'h1: cond_true = 1'b0;                              // F (unused by Bcc -- BSR's slot)
			4'h2: cond_true = !ccr[0] && !ccr[2];                 // HI
			4'h3: cond_true =  ccr[0] ||  ccr[2];                 // LS
			4'h4: cond_true = !ccr[0];                            // CC
			4'h5: cond_true =  ccr[0];                            // CS
			4'h6: cond_true = !ccr[2];                            // NE
			4'h7: cond_true =  ccr[2];                            // EQ
			4'h8: cond_true = !ccr[1];                            // VC
			4'h9: cond_true =  ccr[1];                            // VS
			4'hA: cond_true = !ccr[3];                            // PL
			4'hB: cond_true =  ccr[3];                            // MI
			4'hC: cond_true =  ccr[3] ==  ccr[1];                 // GE
			4'hD: cond_true =  ccr[3] !=  ccr[1];                 // LT
			4'hE: cond_true = !ccr[2] && (ccr[3] == ccr[1]);      // GT
			default: cond_true = ccr[2] || (ccr[3] != ccr[1]);    // LE
		endcase
	end
endfunction

// Shared by Bcc (branch taken/not-taken), Scc (byte fill value), and DBcc
// (loop-terminate vs decrement-and-test) -- all three decode the condition
// into the same eaf_cond field, so this is the one evaluation all consume.
wire cond_result = cond_true(eaf_cond, ccr_in);

// DBcc: decrement is a word-sized RMW -- low 16 bits of operand_a (Dn, read
// via EA-fetch's normal port-A path since decode set src_reg=dest_reg=Dn),
// high 16 bits pass through untouched. Only meaningful when eaf_is_dbcc and
// cond_result is false (see header); computed unconditionally here because
// it's pure combinational arithmetic with no side effect on its own.
wire [15:0] dbcc_dec          = eaf_operand_a[15:0] - 16'd1;
wire        dbcc_expired      = (dbcc_dec == 16'hFFFF);
wire        dbcc_branch_taken = !cond_result && !dbcc_expired;
wire [31:0] dbcc_result       = {eaf_operand_a[31:16], dbcc_dec};

// DBcc writes Dn whenever it enters the decrement path at all (cond false),
// regardless of whether the decremented value then causes a taken branch or
// a loop-expired fall-through -- see header comment. Every other instruction
// still uses decode's static eaf_writes_reg unchanged.
// DIVU/DIVS join DBcc as instructions whose write depends on a RUNTIME
// value: an overflowing quotient writes nothing at all.
wire writes_reg_resolved = eaf_is_dbcc ? (eaf_valid && !cond_result) :
                            eaf_is_div  ? (eaf_writes_reg && !div_ovf) : eaf_writes_reg;

// Both of DBcc's "don't branch" outcomes -- condition true, or the
// decremented counter expired -- are architecturally identical to Bcc's
// not-taken case from IF's point of view: decode guessed taken, so anything
// but a taken branch is a misprediction recovered to eaf_next_pc.
//
// JMP (milestone 11): decode never guesses a target for it at all (no
// literal displacement exists to speculate with -- see ap040_decode.v's
// header), so its implicit "guess" is IF's own default sequential advance.
// That's correct only by the coincidence of the target happening to equal
// eaf_next_pc, so JMP is modeled as an UNCONDITIONAL misprediction once it
// reaches EX -- reusing ex_mispredict/ex_recovery_pc/flush exactly as they
// already exist, no new redirect path. The recovery target is
// eaf_operand_a itself: ap040_ea_fetch.v routed the computed EA there
// instead of a register value (see its header) specifically so EX doesn't
// need a separate "JMP target" input.
//
// JSR (milestone 13): the SAME reasoning as JMP -- its target is An + a
// possible displacement, not known until a register is read, so decode
// never speculates one and JSR joins JMP in this OR-chain. BSR is
// deliberately NOT here: it reuses Bcc's byte/word/long gather and
// speculative decode-time redirect verbatim (unconditionally taken, always
// correct -- see ap040_decode.v's header), so by the time a BSR reaches EX
// the redirect has already happened and there is nothing left to correct.
//
// TRAP #n / illegal instruction / privilege violation / odd JMP-JSR target
// (milestones 14/15/17): the SAME reasoning as JMP/JSR one more time --
// none of the four has a literal target decode could possibly speculate
// with (the handler address comes from ap040_ea_fetch.v's own vector-table
// read, resolved into eaf_operand_a exactly like JMP/JSR's EA -- see its
// header), so all four join this OR-chain unconditionally. eaf_is_priv
// fires for a privilege violation on MOVE-to-SR/MOVEC/RTE; eaf_is_addrerr
// fires for an odd JMP/JSR target -- see ap040_ea_fetch.v's header for
// where both are actually detected (dynamic, not a decode-time fact the
// way illegal/TRAP are). Reusing this SAME aggregate wire is also why
// address error needed no further changes anywhere else in this file:
// ex_mispredict/ex_recovery_pc/combined_result/exe_writes_sr_c/
// exe_sr_data_c all key off exc_reaching_ex already, not the individual
// flags.
// Divide by zero (milestone 52) joins the aggregate, which is the whole of
// what this file needed for it -- exactly as the comment above predicted
// for address error. Without this the frame is pushed and the vector is
// read correctly and then nothing redirects, so the instruction after the
// divide runs as if nothing had happened.
wire exc_reaching_ex = eaf_is_trap || eaf_is_illegal || eaf_is_priv || eaf_is_addrerr ||
                        eaf_is_divzero || eaf_is_chk || eaf_is_trapcc || eaf_is_fmterr ||
                        eaf_is_trace;

// RTS/RTE (milestone 16) join the SAME unconditional-redirect club one
// more time: RTS's popped PC (routed into eaf_operand_a exactly like
// JMP/JSR's EA, see ap040_ea_fetch.v's header for why it reuses
// mem_issue/mem_complete verbatim) and RTE's own popped PC (its 2-beat
// sequencer's own finalize) are both targets decode could never have
// speculated with either.
wire redirect_always = eaf_is_jmp || eaf_is_jsr || eaf_is_rts || eaf_is_rte ||
                        exc_reaching_ex;

assign ex_mispredict   = eaf_valid && ((eaf_is_branch && !cond_result) ||
                                        (eaf_is_dbcc   && !dbcc_branch_taken) ||
                                        redirect_always);
assign ex_recovery_pc  = redirect_always ? eaf_operand_a : eaf_next_pc;

wire [31:0] scc_fill   = {24'd0, {8{cond_result}}};
wire [31:0] scc_merged = {eaf_operand_b[31:8], scc_fill[7:0]};

// MOVEC's read direction (milestone 15): the selected control register's
// CURRENT value (fed straight in from ap040_pipe_core.v -- see the port
// list above), routed into combined_result exactly like any other GPR-
// writing instruction's result -- no new commit path needed for this
// direction at all, it rides the SAME commit_reg/ex_fwd_* machinery every
// register-writing instruction already uses. Meaningless (and unread) for
// the write direction, same "compute always, consume conditionally"
// precedent used throughout this pipeline.
wire [31:0] creg_read_value = (eaf_movec_sel == `AP040_CREG_SFC)  ? sfc_in  :
                               (eaf_movec_sel == `AP040_CREG_DFC)  ? dfc_in  :
                               (eaf_movec_sel == `AP040_CREG_CACR) ? cacr_in :
                               (eaf_movec_sel == `AP040_CREG_VBR)  ? vbr_in  :
                               (eaf_movec_sel == `AP040_CREG_USP)  ? usp_in  :
                               (eaf_movec_sel == `AP040_CREG_ISP)  ? isp_in  :
                                                                      msp_in;  // AP040_CREG_MSP

// BSR/JSR/TRAP/illegal/priv/RTS/RTE: eaf_operand_b already IS the result --
// ap040_ea_fetch.v computed the new A7 value there (the same expression it
// used for the push/pop address), so this stage just selects it, the same
// "precomputed elsewhere, EX only picks" shape scc_merged/dbcc_result
// already use. No generic-ALU op is used for this (eaf_operand_a is busy
// carrying the redirect/handler target and can't also carry a literal
// increment/decrement operand) -- see ap040_ea_fetch.v's header.
// A byte or word result keeps the destination register's upper bits, the
// same shape scc_merged already uses. eaf_operand_b is always the
// destination's current value (ap040_ea_fetch.v drives raddr_b from
// eac_dest_reg), and the ALU returns a sized result in the low bits with the
// upper ones zero, so the merge is a straight splice. Forwarding gets it for
// free: ex_fwd_data is combined_result, not alu_result.
// The store's lane placement, mirroring ap040_ea_fetch.v's st_be/st_dat
// exactly -- lane 3 is the longword's first byte, a Word always takes the
// half the address names, and a Byte is picked by address bit 0. The raw
// alu_result is used rather than alu_sized: the byte enables already
// restrict what lands, and alu_sized would splice in eaf_operand_b, which
// for an RMW is the value just read from that same memory.
assign ex_st_addr = eaf_ea_target;
wire [1:0] rmw_off = eaf_ea_target[1:0];
assign ex_st_be   = (eaf_size == `AP040_SZ_L) ? 4'b1111 :
                    (eaf_size == `AP040_SZ_W) ? (rmw_off[0] ? 4'b0110 : 4'b1100) :
                    rmw_off[0]                ? 4'b0100 : 4'b1000;
assign ex_st_data = (eaf_size == `AP040_SZ_L) ? alu_result :
                    (eaf_size == `AP040_SZ_W) ? (rmw_off[0] ? {8'd0, alu_result[15:0], 8'd0}
                                                            : {alu_result[15:0], 16'd0}) :
                    rmw_off[0] ? {8'd0, alu_result[7:0], 16'd0}
                               : {alu_result[7:0], 24'd0};

wire [31:0] alu_sized = (eaf_size == `AP040_SZ_B) ? {eaf_operand_b[31:8],  alu_result[7:0]}  :
                        (eaf_size == `AP040_SZ_W) ? {eaf_operand_b[31:16], alu_result[15:0]} :
                                                      alu_result;

wire [31:0] combined_result = eaf_is_scc  ? scc_merged :
                               eaf_is_dbcc ? dbcc_result :
                               // LINK joins this bypass (milestone 49): its A7 value was
                               // computed in ap040_ea_fetch.v as push_addr + d16 and has no
                               // business going through the ALU, exactly like BSR/JSR's.
                               // PEA joins for the same reason LINK did: its A7 value was
                               // computed in ap040_ea_fetch.v and has no business going
                               // through the ALU.
                               (eaf_is_bsr || eaf_is_jsr || eaf_is_rts || eaf_is_rte ||
                                eaf_is_link || eaf_is_pea || exc_reaching_ex)
                                 ? eaf_operand_b :
                               (eaf_is_movec && !eaf_movec_dir) ? creg_read_value :
                               eaf_is_div ? div_result :
                                                                    alu_sized;

// MOVE to SR (milestone 15, new): writes the WHOLE live SR, not just CCR --
// a genuinely different commit path from exe_writes_ccr's low-5-bits-only
// one (Scc/Bcc/DBcc's flags never touch S/M/T/IPL, and this instruction
// must never touch THEM through the ALU's flags_out path either). Its
// value is simply eaf_operand_a's low 16 bits -- the source Dn's already-
// forwarded value, same port A every register-direct source has used since
// milestone 2, no new operand path.
//
// Exception entry (illegal/TRAP/priv) ALSO writes the whole live SR: T1/T0
// cleared, S forced to 1 (entering the handler in supervisor mode
// unconditionally, per ap040_core.v's own S_EXC0: `sr[13]<=1; sr[15:14]<=
// 2'b00;`), M/IPL/CCR preserved from whatever they were the instant before
// the fault -- computed here off eaf_sr_snapshot (ap040_ea_fetch.v's OWN
// forwarded read of the SAME live SR, one cycle earlier, for the PUSHED
// copy -- see its header for why threading it down, not re-reading a live
// value here, is required, not just tidier).
//
// RTE (milestone 16) is a THIRD source: restores the SR it just popped
// (eaf_rte_sr_data, already masked with AP040_SR_MASK by
// ap040_ea_fetch.v's own finalize step -- see its header), the architectural
// inverse of the exception-entry case just above. All three sources are
// mutually exclusive by construction: a MOVE-to-SR or RTE that faults a
// privilege violation instead has its own eaf_is_movesr/eaf_is_rte cleared
// by ap040_ea_fetch.v's exc_vec_done branch, so exc_reaching_ex never
// overlaps with either.
// ORI/ANDI/EORI to CCR and SR (milestone 62). The operand is the status
// register rather than a GPR, so the result is computed here from
// eaf_sr_snapshot -- the live, forwarded SR this stage already receives --
// and commits on the same path MOVE-to-SR and RTE use.
//
// The CCR form is computed on eight bits rather than masked afterwards:
// ANDI #$FE,CCR must leave the upper byte alone, and a 16-bit AND with an
// immediate whose high byte is zero would clear the whole of it.
wire [15:0] immsr_imm = eaf_operand_a[15:0];
wire  [7:0] immsr_ccr = (eaf_alu_op == `AP040_ALU_AND) ? (eaf_sr_snapshot[7:0] & immsr_imm[7:0]) :
                        (eaf_alu_op == `AP040_ALU_EOR) ? (eaf_sr_snapshot[7:0] ^ immsr_imm[7:0]) :
                                                         (eaf_sr_snapshot[7:0] | immsr_imm[7:0]);
wire [15:0] immsr_full = (eaf_alu_op == `AP040_ALU_AND) ? (eaf_sr_snapshot & immsr_imm) :
                         (eaf_alu_op == `AP040_ALU_EOR) ? (eaf_sr_snapshot ^ immsr_imm) :
                                                          (eaf_sr_snapshot | immsr_imm);
wire [15:0] immsr_result = eaf_immsr_to_sr ? immsr_full
                                           : {eaf_sr_snapshot[15:8], immsr_ccr};

wire        exe_writes_sr_c = eaf_valid && (eaf_is_movesr || eaf_is_rte || eaf_is_immsr ||
                                            exc_reaching_ex);
wire [15:0] exe_sr_data_c   = exc_reaching_ex ? ((eaf_sr_snapshot & 16'h1FFF) | 16'h2000) :
                               eaf_is_rte      ? eaf_rte_sr_data :
                               eaf_is_immsr    ? immsr_result :
                                                  eaf_operand_a[15:0];

// MOVEC's write direction (milestone 15, new): writes ONE of the seven
// control registers ap040_pipe_core.v now owns, selected by eaf_movec_sel
// (ap040_decode.v's validated selector code -- an invalid one never
// reaches here, having become id_is_illegal instead, see its header).
// Value is eaf_operand_a again, same source-register path as MOVE-to-SR.
// Suppressed (like eaf_is_movec itself) whenever this MOVEC just faulted a
// privilege violation instead -- ap040_ea_fetch.v already cleared
// eaf_is_movec for that case, so eaf_movec_dir is simply never consulted.
//
// RTE's A7 restore (milestone 16, new) ALSO routes through this same
// direct-to-ISP/MSP path, deliberately NOT through the normal commit_reg/
// A7-bank-selected write every other A7-touching instruction uses. A real
// bug, found by this exact test failing, not by inspection: RTE's SR
// restore (exe_writes_sr, above) and its A7 restore commit on the SAME
// cycle, and ap040_pipe_core.v's sr_resolved -- correctly, per its own
// milestone-15 fix -- makes a same-cycle SR write visible to THAT SAME
// cycle's regfile bank-select. Going through commit_reg here would mean
// RTE's OWN A7 write gets banked by the SR it is ITSELF in the middle of
// restoring -- i.e. the NEW (post-restore) S bit, not the OLD one active
// while the frame was actually being popped -- silently landing the
// restored ISP/MSP value in USP instead whenever RTE returns to a
// different mode than it ran in. Using exe_writes_creg's fixed ISP/MSP
// target (selected off eaf_sr_snapshot[12], the M bit AS OF ea_fetch's own
// cycle -- the OLD context, before this same instruction's restore lands)
// sidesteps the race entirely, exactly the same "bypass the live bank,
// write the supervisor stack directly" reasoning exc_sp_bank already
// established for the exception-entry push.
wire exe_writes_creg_c = (eaf_valid && eaf_is_movec && eaf_movec_dir) ||
                          (eaf_valid && eaf_is_rte);
wire  [2:0] exe_creg_sel_c  = eaf_is_rte ? (eaf_sr_snapshot[12] ? `AP040_CREG_MSP : `AP040_CREG_ISP)
                                          : eaf_movec_sel;
wire [31:0] exe_creg_data_c = eaf_is_rte ? eaf_operand_b : eaf_operand_a;

assign ex_fwd_valid = eaf_valid && writes_reg_resolved;
assign ex_fwd_dest  = eaf_dest_reg;
assign ex_fwd_data  = combined_result;

// The one place the committed flags are chosen; the forward and the
// register both read it, so they cannot disagree.
wire [4:0] exe_flags_c = eaf_is_div ? div_flags : alu_flags;
assign ex_ccr_fwd_valid = eaf_valid && eaf_writes_ccr && !ex_stall;   // final this cycle
// The branch verdict, for EA-fetch's T0 trace arm: a conditional branch
// arms provisionally when it leaves that stage and this settles it.
assign ex_br_resolve = eaf_valid && (eaf_is_branch || eaf_is_dbcc) && !ex_stall;
assign ex_br_taken   = eaf_is_branch ? cond_result : dbcc_branch_taken;
assign ex_ccr_fwd_data  = exe_flags_c;

// The (An)+/-(An) address update forwards from the SAME point as the primary
// result: the instruction currently IN this stage, not the registered
// exe_*2 outputs one cycle later. Wiring it to the registered outputs made
// the very next instruction read the stale An, which is the whole hazard
// this path exists to close.
assign ex_fwd2_valid = eaf_valid && eaf_writes_an;
assign ex_fwd2_dest  = eaf_an_reg;
assign ex_fwd2_data  = eaf_an_data;

assign ex_sr_fwd_valid = exe_writes_sr_c;
assign ex_sr_fwd_data  = exe_sr_data_c;

always @(posedge clk) begin
	if (!nreset) begin
		exe_valid        <= 1'b0;
		exe_pc           <= 32'h0;
		exe_dest_reg     <= 4'h0;
		exe_result_data  <= 32'h0;
		exe_dest_reg2    <= 4'h0;
		exe_result_data2 <= 32'h0;
		exe_writes_reg2  <= 1'b0;
		exe_writes_reg   <= 1'b0;
		exe_writes_ccr   <= 1'b0;
		exe_result_flags <= 5'h0;
		exe_writes_sr    <= 1'b0;
		exe_sr_data      <= 16'h0;
		exe_writes_creg  <= 1'b0;
		exe_creg_sel     <= 3'h0;
		exe_creg_data    <= 32'h0;
	end else if (ce && !ex_stall) begin
		exe_valid        <= eaf_valid;
		exe_pc           <= eaf_pc;
		exe_dest_reg     <= eaf_dest_reg;
		exe_result_data  <= combined_result;
		// The address update rides alongside, on its own gate -- see
		// ap040_pipe_regfile.v's second write port.
		exe_dest_reg2    <= eaf_an_reg;
		exe_result_data2 <= eaf_an_data;
		exe_writes_reg2  <= eaf_writes_an;
		exe_writes_reg   <= writes_reg_resolved;
		exe_writes_ccr   <= eaf_writes_ccr;
		exe_result_flags <= exe_flags_c;
		exe_writes_sr    <= exe_writes_sr_c;
		exe_sr_data      <= exe_sr_data_c;
		exe_writes_creg  <= exe_writes_creg_c;
		exe_creg_sel     <= exe_creg_sel_c;
		exe_creg_data    <= exe_creg_data_c;
	end
end

endmodule
