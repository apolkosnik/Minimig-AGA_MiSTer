//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 17: address error)       //
//                                                                          //
// ap040_ea_fetch.v - EA-fetch stage                                       //
//                                                                          //
// This is where the pipeline's register forwarding lives. The top-level   //
// regfile (ap040_pipe_core.v, its own ap040_pipe_regfile.v fork) is read    //
// combinationally here on BOTH ports -- port A at eac_src_reg, port B at   //
// eac_dest_reg -- and each resolved, independently, as a flat priority mux //
// rather than a chain of ternaries:                                       //
//                                                                          //
//   ex_fwd_*  the instruction currently in EX (still combinational this   //
//             cycle, not yet committed) -- "producer one stage ahead"     //
//                                                                          //
// Port B (eac_dest_reg) is read unconditionally, for every instruction,   //
// not just ones that need it: it's a pure regfile read with no side       //
// effect, and AP040_ALU_MOVE (MOVEQ/MOVE.L's op) never references its `b` //
// input at all (ap040_pipe_alu.v:139-142), so fetching it for those two is //
// simply unused, not wrong -- and the same is true for a branch, whose      //
// eac_dest_reg field is meaningless leftover bits, harmless because         //
// eac_writes_reg is always 0 for one. Scc, this milestone, is the first     //
// instruction that actually NEEDS port B's value for something other than  //
// forwarding to a later instruction: it's the register Scc's byte-merge     //
// preserves the upper bits of (ap040_execute.v). This is the                //
// generalization the milestone-2 altitude review asked for instead of a     //
// per-opcode special case: adding another instruction needs no new mux      //
// shape here.                                                               //
//                                                                          //
// The other hazard case -- a producer committing to the regfile the exact //
// same cycle a consumer reads it -- does NOT need a second mux on either   //
// port: it's resolved inside ap040_pipe_regfile.v itself (its write-through //
// bypass, unconditional in that file -- see its header). A mutation test    //
// during milestone 2 development confirmed this empirically for port A --   //
// forcing this stage's own would-be WB-forward mux to always miss still     //
// passed, because rdata_a was already correct by the time it got here.      //
// Keeping a second, provably redundant mux here would be dead logic; see    //
// ap040_pipe_core.v for the write-through wiring.                           //
//                                                                          //
// id_is_branch/id_is_scc/id_is_dbcc/id_cond/id_next_pc ride through          //
// unchanged -- this stage has nothing to compute for any of them;            //
// ap040_execute.v is where the condition is actually checked, the Scc merge  //
// actually happens, the DBcc decrement/compare happens, and eaf_next_pc is   //
// finally consumed (as ex_recovery_pc), per its header comment on why.       //
//                                                                          //
// DBcc (milestone 8) needs no new mux shape here either: its loop-counter    //
// register is both eac_src_reg and eac_dest_reg (ap040_decode.v sets both     //
// to the same Dn), so operand_a already resolves to Dn's current,             //
// correctly-forwarded value via the existing port-A priority mux -- exactly   //
// the read a decrement needs, with no dedicated DBcc case added to either     //
// port's select logic.                                                      //
//                                                                          //
// flush: when ap040_execute.v detects a mispredicted branch, everything     //
// speculatively fetched behind it -- including whatever is sitting here -- //
// must be discarded. Same shape as stall_in but forces a bubble instead     //
// of holding.                                                              //
//                                                                          //
// MOVE.L (An),Dn (milestone 9b, new) is this pipeline's first memory read,   //
// and its first genuine stall. The address itself needs NO new logic: An's  //
// value is already what `operand_a` resolves to (decode set eac_src_reg to   //
// An's unified regfile index, see ap040_decode.v's header) -- the SAME       //
// priority mux, with the SAME EX-forward source, that every register-direct  //
// operand has used since milestone 2. What's new is turning that value into  //
// an actual ap040_pipe_l1.v port-B access:                                   //
//                                                                            //
//   mem_issue    (eac_valid && eac_is_mem_src && !mem_pending) -- the cycle  //
//                this stage first sees an unserviced memory instruction.     //
//                l1_addr_b is driven combinationally off operand_a THIS      //
//                cycle (ap040_pipe_l1.v registers l1_q_b from it, valid      //
//                next cycle); eaf_valid goes to 0 (nothing for EX yet); and  //
//                eaf_stall's mem_issue term freezes ap040_ea_calc.v's        //
//                OUTPUT for exactly this one cycle -- not a separate pending-//
//                instruction latch in THIS stage, just reusing the stall     //
//                chain's existing freeze-on-stall_in behavior (every stage    //
//                has had it since milestone 1). That's why eac_* is         //
//                guaranteed to still describe the SAME instruction next      //
//                cycle with no extra bookkeeping here.                       //
//   mem_complete (mem_pending, i.e. the cycle after issuing) -- eac_* is      //
//                still frozen on this same instruction, l1_q_b now holds the  //
//                fetched longword. Finishes exactly like the normal path      //
//                below, except eaf_operand_a comes from l1_q_b instead of     //
//                operand_a/regfile/forwarding. eaf_stall drops (mem_issue is  //
//                false once mem_pending is set), so ap040_ea_calc.v is free   //
//                to advance a NEW instruction into its output starting THIS   //
//                cycle -- the memory latency is hidden from whatever comes    //
//                next, not paid twice.                                       //
//                                                                            //
// L1 addressing: ap040_pipe_l1.v is addressed PC_RESET-relative (see          //
// ap040_inst_fetch.v's header) -- PC_RESET is the L1 window's BASE address,   //
// not "where execution starts" in isolation, and both ports must agree on    //
// it or the "unified" memory silently stops being unified. This stage takes  //
// the SAME PC_RESET parameter ap040_inst_fetch.v does (ap040_pipe_core.v     //
// passes the identical value to both) rather than assuming address 0.        //
//                                                                            //
// MOVE.L (d16,An),Dn (milestone 10, new): needed NO changes to the mem_issue/ //
// mem_complete FSM above -- ap040_decode.v now reuses id_imm to carry the      //
// sign-extended displacement (0 for the plain (An) case), and this stage's     //
// address computation became `operand_a + eac_imm` unconditionally (see        //
// where l1_addr_b is assigned below) rather than a per-mode branch. The         //
// gather that assembles the extension word happens entirely in                  //
// ap040_decode.v, same as Bcc.W/DBcc -- this stage never knows a gather           //
// happened, exactly the same "looks identical from EA-calc onward" property       //
// those two established.                                                          //
//                                                                            //
// flush: when ap040_execute.v detects a mispredicted branch, everything     //
// speculatively fetched behind it -- including whatever is sitting here -- //
// must be discarded. An outstanding L1 request (mem_pending) is simply       //
// abandoned, not unwound -- a read has no side effect, so its eventual        //
// l1_q_b is just never consumed once mem_pending clears.                     //
//                                                                            //
// JMP (An) / JMP (d16,An) (milestone 11, new): the EA (operand_a + eac_imm,   //
// the exact same expression l1_addr_b already computes) is what JMP needs     //
// as its RESULT, not an address to dereference -- eac_is_mem_src stays 0 for  //
// JMP (ap040_decode.v never sets it), so this stage's mem_issue/mem_complete   //
// FSM never triggers for it and JMP rides the plain, non-stalling "else"       //
// path below like any register-direct instruction. The only change there is    //
// eaf_operand_a: `eac_is_jmp ? (operand_a + eac_imm) : operand_a` -- routing     //
// the computed target into the SAME field ap040_execute.v already reads for      //
// its EX-forward tap and (via a new case there) ex_recovery_pc. See its           //
// header for why JMP is modeled as an unconditional misprediction rather than      //
// a new redirect mechanism.                                                        //
//                                                                            //
// BSR / JSR (milestone 13, new): this pipeline's first genuine memory WRITE,   //
// and its second kind of stall (mem_issue's read-side FSM has existed since     //
// milestone 9b; this is the write-side counterpart). Both push the return        //
// address (eac_next_pc -- already exactly right, no new arithmetic: it's the      //
// address of whatever comes after the whole BSR/JSR, extension words              //
// included, the same field id_next_pc has threaded since milestone 7) onto        //
// -(A7), then decrement A7 by 4. Both quantities the push needs -- the WRITE       //
// ADDRESS (A7-4) and the NEW A7 VALUE to commit -- are the SAME expression,         //
// and ap040_decode.v set eac_dest_reg to A7's unified index (4'd15) for both        //
// instructions specifically so operand_b (port B, "the destination register's       //
// current value", already resolved with full EX-forwarding) gives us A7's            //
// CURRENT value for free -- no new regfile read, no new forwarding mux. JSR's         //
// own EA target (An + eac_imm, via operand_a, exactly like JMP) and BSR/JSR's          //
// push address (operand_b - 4) are simply two DIFFERENT fields, resolved from           //
// two DIFFERENT ports, with no conflict.                                                //
//                                                                            //
//   l1_addr_b (extended): now selects between ea_target (a memory-source read     //
//   or JMP/JSR's redirect target) and push_addr (operand_b - 4) depending on        //
//   which this cycle's instruction actually is -- mutually exclusive by              //
//   construction, an instruction is never more than one of these at once.             //
//   l1_wren_b/l1_data_b: asserted whenever eac_is_bsr||eac_is_jsr, driving the          //
//   SAME push_addr and eac_next_pc as the data -- held stable (not gated by any          //
//   "have we issued yet" latch) for as long as eac_* itself stays stable, which           //
//   the stall below guarantees.                                                            //
//   wr_stall (`eac_valid && (eac_is_bsr||eac_is_jsr) && l1_wr_busy`): unlike a               //
//   read, a write needs no "wait for the response" phase -- ap040_pipe_l1.v's                //
//   OWN contract (see its header) is that asserting wren_b while wr_busy is LOW               //
//   always succeeds THIS cycle, so the only thing to wait for is the port being                //
//   free at all. When wr_stall is false (either this isn't a push, or it is and                 //
//   l1_wr_busy just read low), the push -- if any -- is being accepted THIS SAME                 //
//   cycle, and the instruction proceeds to EX in that SAME cycle carrying                         //
//   eaf_operand_b = operand_b - 4 as its result (ap040_execute.v routes this into                  //
//   the regfile commit for A7, exactly the same "dedicated combinational result,                    //
//   not the generic ALU" pattern DBcc's decrement and Scc's byte-merge already use;                  //
//   see its header for why the generic ALU wasn't used here either -- eaf_operand_a                   //
//   is busy carrying JSR's redirect target and can't also carry a "4" operand).                        //
//                                                                            //
// TRAP #n / illegal instruction (milestone 14, new): this pipeline's first     //
// exception entry, and its first multi-beat memory sequence -- BSR/JSR's push    //
// was exactly one write; a format-$0 frame is TWO (SR:PC_hi, then PC_lo:         //
// FmtVec), followed by a THIRD access, a plain read, to fetch the handler          //
// address out of the vector table. A small state register (exc_ph, BEAT0/          //
// BEAT1/VECRD) sequences these three L1 accesses one at a time; eac_* stays          //
// frozen throughout via exc_stall feeding eaf_stall, the SAME freeze-on-stall         //
// mechanism every multi-cycle operation in this stage already uses (mem_issue/        //
// wr_stall above). Each beat reuses wr_stall's own accept-when-!l1_wr_busy idiom       //
// independently (retried every cycle it's needed, exactly like BSR/JSR's single        //
// write already does) rather than a new handshake shape.                                //
//                                                                            //
// Frame contents (format $0 only this milestone -- see ap040_decode.v's header    //
// for why address-error's format $2 is deferred to its own milestone):             //
//   SR word:  this pipeline has no real T1/T0/M/IPL state (sr_s/sr_m are            //
//             hardwired in ap040_pipe_core.v), so the system byte is a fixed        //
//             8'b0010_0000 (S=1, everything else 0, matching AP040_SR_RESET's        //
//             S=1/M=0) -- ccr_in supplies the real, live low byte (this stage's       //
//             CCR forwarding source, same signal ap040_execute.v's Bcc/Scc            //
//             condition check already uses -- see ap040_pipe_core.v).                  //
//   PC field: id_pc (the faulting instruction's OWN address) for illegal --             //
//             you can't "return past" an illegal opcode -- id_next_pc (the               //
//             FOLLOWING instruction, TRAP's actual return address) for TRAP,              //
//             the same subroutine-call semantics BSR/JSR's return-address push             //
//             already established. Verified against ap040_core.v's go_illegal              //
//             (spc=pc_i, its own convention for "current instruction's address")             //
//             vs. its vector-32+n TRAP dispatch (spc=pc, its convention for "the              //
//             next instruction" -- see that file for the pc/pc_i distinction).                //
//   Format/vector-offset word: {format(4)=0, 00, vector(8), 00} -- vector*4 falls               //
//             naturally out of this bit placement, no explicit shift needed.                     //
//                                                                            //
// Vector fetch: this substrate has NO real VBR register consulted here (see              //
// milestone 15 below -- one now EXISTS in ap040_pipe_core.v, but this pipeline's           //
// only two implemented vectors are both low, fixed numbers, so nothing here has             //
// needed to add it in yet) and, unlike a real 68040, no separate low-memory region           //
// distinct from ap040_pipe_l1.v's PC_RESET-relative window -- vector*4 is used                //
// as an ABSOLUTE address, fed through the exact SAME `l1_addr_word - PC_RESET) >>              //
// 1` conversion every other address on this port already goes through. This is                 //
// not a special case: PC_RESET's own value (0x400 in every testbench so far,                    //
// deliberately -- exactly the byte size of a full 256-entry 68k vector table) was                 //
// already chosen with headroom for the vector table to occupy the address range                    //
// BELOW it, and the unsigned wraparound in that subtraction lands vector*4 in the                    //
// mathematically-correct modular slot of the SAME L1 array with zero new address                     //
// logic -- confirmed arithmetically, not assumed, before relying on it.                                //
//                                                                                          //
// MOVE to SR / MOVEC / privilege violation (milestone 15, new): the first DYNAMIC          //
// exception trigger. Illegal/TRAP are decode-time facts; whether a privileged             //
// opcode actually FAULTS depends on the LIVE S bit (sr_in[13]) -- eac_is_priv is           //
// computed right here, the earliest point that value exists, and folds straight            //
// into eac_is_exc/exc_pc_field/exc_vec_num alongside illegal/TRAP (own address,            //
// vector 8, format $0 -- go_priv's exact convention). The frame push itself uses            //
// isp_in/msp_in DIRECTLY, never port B/A7 (see exc_sp_bank below for why: a fault             //
// taken WHILE ALREADY IN USER MODE must still land its frame on a SUPERVISOR                  //
// stack, not USP) -- which also means MOVEC's READ direction pointing port B at                //
// its intended GPR destination for the NORMAL case is fine as-is, no rerouting                  //
// needed there at all. eaf_dest_reg IS still overridden on the COMMIT side once                  //
// exc_vec_done finalizes (A7, not Rn, is what the exception's OWN result writes),                 //
// since that's a genuinely different register than whatever the now-suppressed                    //
// original instruction intended. MOVE-to-SR and MOVEC's WRITE direction never                      //
// needed ANY of this: decode points their eac_dest_reg at A7 unconditionally (same                  //
// "dummy anchor" trick BSR uses) purely so raddr_b's default read is harmless, not                   //
// because anything downstream actually depends on it. Their SR/control-register                      //
// write itself (when NOT faulting) is entirely ap040_execute.v's job -- this stage                     //
// just threads eaf_is_movesr/eaf_is_movec/eaf_movec_dir/eaf_movec_sel through                           //
// unchanged, the same mechanical pass-through every other classification flag gets.                      //
//                                                                                          //
// RTS / RTE (milestone 16, new): RTS is deliberately NOT a new mechanism -- it              //
// reuses mem_issue/mem_complete VERBATIM (ap040_decode.v sets eac_is_mem_src for            //
// it, same as MOVE.L (An),Dn), since a pop is structurally just a 32-bit read from            //
// (A7) with the register hardcoded instead of decoded from opcode bits. The ONLY              //
// addition is mem_complete's eaf_operand_b, which now also has to carry A7's NEW               //
// (post-pop) value forward for the commit -- one ternary, not a new FSM. RTE is                 //
// genuinely new: a privilege-violating RTE (checked exactly like MOVE-to-SR/MOVEC,                //
// via eac_is_priv -- see above) never reaches its own machinery at all, redirected                 //
// into the SAME exception-entry sequencer instead; a supervisor RTE gets its own 2-                 //
// beat READ sequencer (ret_ph/ret_pending/ret_dword0), the mirror image of the                       //
// exception-entry sequencer's own WRITE beats, reading back the exact two dwords a                    //
// format-$0 push wrote. The format nibble in dword1 decides the pop (milestone 76):     //
// $0 is eight bytes, $2/$3 twelve, anything else is a FORMAT ERROR -- vector 14, a       //
// format-$0 frame naming the RTE itself, A7 untouched -- raised from inside the pop     //
// through the same exception-entry sequencer (fmterr_now/exc_pend_fmterr below).        //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_ea_fetch
#(
	parameter         DUMMY    = 0   // (no parameters of its own since milestone 81)
)
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // EX cannot accept this cycle
	input             flush,      // EX detected a misprediction: force a bubble

	input             eac_valid,
	input      [31:0] eac_pc,
	input      [31:0] eac_next_pc,
	input       [3:0] eac_dest_reg,
	input       [3:0] eac_src_reg,
	input      [31:0] eac_imm,
	input       [5:0] eac_alu_op,
	input       [1:0] eac_size,
	input       [5:0] eac_shcnt,
	input             eac_src_a_is_imm,
	input             eac_writes_reg,
	input             eac_writes_ccr,
	input             eac_is_branch,
	input             eac_is_scc,
	input             eac_is_dbcc,
	input             eac_is_mem_src,
	input             eac_is_abs,
	input             eac_is_store,
	input             eac_is_postinc,
	input             eac_is_predec,
	input             eac_is_jmp,
	input             eac_is_lea,
	input             eac_sxt_w,
	input             eac_ea_indexed,
	input             eac_ea_pcrel,
	input             eac_is_rmw,
	input             eac_is_div,
	input             eac_div_signed,
	input             eac_is_movem,
	input             eac_movem_dir,
	input             eac_movem_word,
	input             eac_movem_down,
	input             eac_movem_wb,
	input             eac_movem_pcrel,
	input             eac_movem_abs,
	input      [15:0] eac_movem_mask,
	input             eac_is_trapcc,
	input             eac_is_chk,
	input             eac_is_immsr,
	input             eac_immsr_to_sr,
	input             eac_is_pea,
	input             eac_is_link,
	input             eac_is_unlk,
	// The EX stage has taken L1 port B this cycle for a read-modify-write's
	// store half. Everything this stage would have done with the port has
	// to wait, so it behaves exactly as if it had never been fetched: no
	// read is issued, no output register moves, and the stall propagates
	// backward as usual. See ap040_execute.v's header for why EX wins.
	input             port_taken,
	input             wb_busy,         // WB holds an instruction (the core's exe_valid) -- trace waits for it
	input             ex_br_resolve,   // EX settles a Bcc/DBcc this cycle...
	input             ex_br_taken,     // ...taken or not (T0 trace arm)
	input             eac_is_bsr,
	input             eac_is_jsr,
	input             eac_is_trap,
	input             eac_is_illegal,
	input             eac_is_movesr,
	input             eac_is_movec,
	input             eac_is_rts,
	input             eac_is_rte,
	input             eac_is_nop,
	input       [3:0] eac_cond,

	// Architectural SR (milestone 15: widened from a 5-bit CCR-only port to
	// the full 16-bit register, write-through forwarded -- see
	// ap040_pipe_core.v's sr_resolved). The exception frame's SR word is now
	// simply THIS value, no synthesis -- and sr_in[13] (S) is what a
	// privilege check actually reads -- see header.
	input      [15:0] sr_in,

	// ap040_pipe_regfile.v's OWN ISP/MSP state, read directly -- an
	// exception's stack access must always target one of these, never
	// whatever bank port B/A7 is currently reading -- see exc_sp_bank above.
	input      [31:0] isp_in,
	input      [31:0] msp_in,

	// regfile operand read ports (driven combinationally by this stage;
	// ap040_pipe_core.v wires raddr_a/b <-> rdata_a/b straight to the
	// ap040_pipe_regfile.v instance)
	output     [3:0]  raddr_a,
	input      [31:0] rdata_a,
	output     [3:0]  raddr_c,
	input      [31:0] rdata_c,
	output     [3:0]  raddr_b,
	input      [31:0] rdata_b,

	// EX-forward source, see header comment
	input             ex_fwd_valid,
	input       [3:0] ex_fwd_dest,
	input      [31:0] ex_fwd_data,
	// Second EX forward: the (An)+/-(An) address update, which is a real
	// architectural write and so must be visible to the very next
	// instruction exactly as the primary result is.
	input             ex_fwd2_valid,
	input       [3:0] ex_fwd2_dest,
	input      [31:0] ex_fwd2_data,

	// ap040_pipe_l1.v port B -- read for a memory-source instruction or
	// JMP/JSR's redirect target; write for BSR/JSR's push -- see header.
	output     [31:0] l1_addr_b,
	input        [31:0] l1_q_b,
	input               l1_rvalid_b,   // l1_q_b is the return for the last l1_rd_b (milestone 80)
	output              l1_rd_b,       // port-B read request: one in flight at a time
	output              l1_wren_b,
	output        [3:0] l1_be_b,
	output       [31:0] l1_data_b,
	input               l1_wr_busy,

	output            eaf_stall,  // to EA-calc

	output reg        eaf_valid,
	output reg [31:0] eaf_pc,
	output reg [31:0] eaf_next_pc,
	output reg  [3:0] eaf_dest_reg,
	output reg [31:0] eaf_operand_a,
	output reg [31:0] eaf_operand_b,
	output reg  [5:0] eaf_alu_op,
	output reg  [1:0] eaf_size,
	output reg  [5:0] eaf_shcnt,
	output reg        eaf_writes_an,
	output reg  [3:0] eaf_an_reg,
	output reg [31:0] eaf_an_data,
	output reg        eaf_writes_reg,
	output reg        eaf_writes_ccr,
	output reg        eaf_is_branch,
	output reg        eaf_is_scc,
	output reg        eaf_is_dbcc,
	output reg        eaf_is_jmp,
	output reg        eaf_is_bsr,
	output reg        eaf_is_jsr,
	output reg        eaf_is_trap,
	output reg        eaf_is_illegal,
	output reg        eaf_is_priv,
	output reg        eaf_is_addrerr,
	output reg        eaf_is_divzero,
	output reg        eaf_is_movesr,
	output reg        eaf_is_movec,
	output reg        eaf_movec_dir,
	output reg  [2:0] eaf_movec_sel,
	// The live SR AS OF THIS STAGE'S OWN cycle (already correctly EX-
	// forwarded/write-through resolved via sr_in) -- threaded straight
	// down to ap040_execute.v for its exception-entry SR-masking
	// arithmetic, rather than having it read sr_in live a second time one
	// cycle later, which would close a combinational loop through its own
	// EX-forward output -- see its header.
	output reg [15:0] eaf_sr_snapshot,
	output reg        eaf_is_rmw,
	// MOVEM's third register write port -- see ap040_pipe_regfile.v.
	output            rf3_we,
	output      [3:0] rf3_addr,
	output     [31:0] rf3_data,
	output reg        eaf_is_div,
	output reg        eaf_div_signed,
	output reg        eaf_is_trapcc,
	output reg        eaf_is_chk,
	output reg        eaf_is_immsr,
	output reg        eaf_immsr_to_sr,
	output reg        eaf_is_pea,
	output reg        eaf_is_link,
	output reg [31:0] eaf_ea_target,
	output reg        eaf_is_rts,
	output reg        eaf_is_rte,
	output reg        eaf_is_fmterr,   // RTE format error, vector 14 (milestone 76)
	output reg        eaf_is_trace,    // instruction trace, vector 9 (milestone 78)
	// RTE's popped SR (masked, format-$0-frame's word0 high half) --
	// ap040_execute.v's new commit source for restoring it, same shape as
	// eaf_sr_snapshot above but this one's a REAL architectural value
	// being adopted, not just a forwarded read -- see ap040_execute.v's
	// header for why it needs its own field rather than reusing
	// eaf_operand_a/b (both already busy carrying the redirect target and
	// the new A7 value).
	output reg [15:0] eaf_rte_sr_data,
	output reg  [3:0] eaf_cond
);

reg mem_pending;   // an L1 port-B request is in flight for the CURRENT eac_*
                    // instruction; its result becomes valid next cycle -- see
                    // header.

// Moved ahead of eac_is_push/the exception-detection wires below (both now
// need ea_target, milestone 17) -- iverilog requires a wire's declaration
// to textually precede any use of it in another continuous assignment,
// even though nothing here structurally depends on file order otherwise.
wire fwd_a_from_ex  = ex_fwd_valid  && (ex_fwd_dest  == raddr_a);
wire fwd_a_from_ex2 = ex_fwd2_valid && (ex_fwd2_dest == raddr_a);

// Flat 3-way select on port A: immediate, else forwarded, else the
// regfile's own (possibly write-through-bypassed) read. eac_src_a_is_imm
// and fwd_a_from_ex are mutually exclusive in practice (MOVEQ never has a
// meaningful eac_src_reg), so this is one priority mux, not two stacked.
// For a memory-source instruction this IS the effective address (An's
// value, decode having set eac_src_reg to An's unified index) -- see header.
wire [31:0] operand_a = eac_src_a_is_imm ? eac_imm :
                         fwd_a_from_ex   ? ex_fwd_data :
                         fwd_a_from_ex2  ? ex_fwd2_data :
                                           rdata_a;

// The effective address: operand_a (An's value, resolved by the mux above)
// PLUS eac_imm (the sign-extended displacement for a (d16,An) form, or
// exactly 0 for the plain (An) form -- see ap040_decode.v's header for why
// id_imm is zeroed for the plain case). One formula for both EA modes and
// both consumers (a memory-source MOVE dereferences it below; JMP uses it
// directly as its result) -- adding a future EA mode that also produces an
// address+offset shape (indexed, etc.) needs no new logic here, just
// decode emitting the right eac_imm.
// An absolute address has no register term: eac_imm IS the address. Every
// other mode here is base + displacement, which is why this is a mux rather
// than decode arranging for operand_a to read zero -- no register does.
// -(An) accesses the DECREMENTED address, (An)+ the original one. Long only,
// matching the memory-source support, so the step is always 4.
// A load's address register is the SOURCE (ir[2:0]); a store's is the
// DESTINATION (ir[11:9]), which resolves to operand_b. One base wire keeps
// the increment logic below from having to care which it is.
wire [31:0] an_base = store_now ? operand_b : operand_a;
// LINK reuses this as its own write address as well as An's new value.
wire [31:0] push_addr = operand_b - 32'd4;

// The auto-increment step follows the operand size, with the 68000's stack
// exception: a BYTE access through A7 steps by two, not one, so the stack
// pointer stays even. A7 is the address bank's register 7, unified index 15.
wire        an_is_a7 = (store_now ? eac_dest_reg : eac_src_reg) == 4'd15;
//
// ADDA.W/SUBA.W/CMPA.W (milestone 44) are the first instructions whose
// memory width and ALU width differ: they read a WORD, sign-extend it and
// then operate on 32 bits. eac_size stays Long for the ALU, so every
// size-driven decision on the MEMORY side reads eff_size instead -- both the
// lane select below and this step, since (A0)+ under ADDA.W must advance by
// two, not four.
wire [1:0]  eff_size = eac_sxt_w ? `AP040_SZ_W : eac_size;
wire [31:0] an_step  = (eff_size == `AP040_SZ_L) ? 32'd4 :
                       (eff_size == `AP040_SZ_W) ? 32'd2 :
                       an_is_a7                  ? 32'd2 : 32'd1;

// Indexed addressing (milestone 56). For mode 110 eac_imm is the brief
// extension word VERBATIM rather than a displacement, so it is unpacked
// here: [15] D/A and [14:12] the register number name Xn, [11] its size
// (a Word index is SIGN-extended, not truncated), [10:9] the scale, and
// [7:0] a signed BYTE displacement -- not the 16-bit one every other mode
// uses.
wire  [3:0] idx_reg  = {eac_imm[15], eac_imm[14:12]};
wire [31:0] idx_raw  = eac_imm[11] ? operand_c
                                   : {{16{operand_c[15]}}, operand_c[15:0]};
wire [31:0] idx_val  = idx_raw << eac_imm[10:9];
wire [31:0] idx_disp = {{24{eac_imm[7]}}, eac_imm[7:0]};

// PC-relative addressing (milestone 57) changes only the BASE: the program
// counter of the EXTENSION WORD, which is the opcode's PC plus two, rather
// than An. Everything built on top of it -- the displacement add, and
// milestone 56's index arithmetic -- is unchanged, which is why (d8,PC,Xn)
// came along for free with (d16,PC).
//
// eac_pc is the opcode's own address and was already threaded for the
// exception frames, so nothing new reaches this stage. operand_a is simply
// unused for these modes; decode still points eac_src_reg at the register
// the mode field nominally names, and reading it is harmless.
wire [31:0] ea_base = eac_ea_pcrel ? (eac_pc + 32'd2) : operand_a;

wire [31:0] ea_target = eac_is_abs     ? eac_imm            :
                        eac_is_predec  ? (an_base - an_step) :
                        eac_ea_indexed ? (ea_base + idx_val + idx_disp) :
                                         (ea_base + eac_imm);

// The value An takes afterwards. Both modes leave An at the same place --
// just past the longword for (An)+, at the start of it for -(An) -- which is
// why one expression covers both.
wire [31:0] an_new = eac_is_postinc ? (an_base + an_step) :
                                      (an_base - an_step);

// Second write port selection (milestone 49). LINK writes An with the new
// top of stack, UNLK writes A7 with An+4 -- neither is an autoincrement,
// but both need exactly the port autoincrement already owns, and neither
// instruction autoincrements, so there is no contention. Hoisted here so
// every branch below assigns the same three wires instead of repeating a
// ternary that now has three cases.
wire        an_wr_any  = an_write || (eac_valid && (eac_is_link || eac_is_unlk)) ||
                         (mvm_fin && mvm_wb);
wire  [3:0] an_wr_reg  = (eac_is_link || eac_is_movem) ? eac_src_reg :
                         eac_is_unlk  ? 4'd15       :
                         store_now ? eac_dest_reg : eac_src_reg;
wire [31:0] an_wr_data = eac_is_link  ? push_addr            :
                         eac_is_unlk  ? (operand_a + 32'd4)  :
                         eac_is_movem ? mvm_addr             : an_new;

// ------------------------------------------------------------------ MOVEM
// One memory access per set mask bit, up to sixteen, so this is a sequencer
// like the exception-frame and RTE ones above rather than anything the
// single-access paths could carry.
//
// Walking the mask from bit 0 upward is right for BOTH directions once the
// register index is read off correctly: the predecrementing store numbers
// bit 0 as A7, so it stores A7 first at the highest address and the index
// is 15 - bit; the postincrementing load numbers bit 0 as D0 and the index
// IS the bit. That symmetry is why one sequencer covers both.
//
// Stores take one cycle per register when the write buffer is free and
// retry while it is not, exactly as an exception frame beat does. Loads
// take two -- drive the address, then capture l1_q_b the cycle after --
// because the L1 registers its read data. Pipelining the load beats is
// left for when MOVEM is on a path that cares.
reg         mvm_active;
reg  [15:0] mvm_mask;
reg  [31:0] mvm_addr;
reg         mvm_dir;        // 1 = memory -> registers
reg         mvm_word;       // 1 = Word transfers, sign-extended on load
// Only the PREDECREMENT store walks downward and reverses the mask; every
// other mode, store or load, walks up with bit 0 = D0. And only -(An) and
// (An)+ write the address register back at all. Milestone 50 tied both
// behaviours to "is a store", which was indistinguishable from the truth
// while -(An) was the only store mode there was.
reg         mvm_down;
reg         mvm_wb;
reg         mvm_rd_pend;    // an address was driven last cycle; data is here now
reg   [3:0] mvm_rd_reg;

wire        mvm_any  = |mvm_mask;
wire  [3:0] mvm_bit  = mvm_mask[0]  ? 4'd0 :
                     mvm_mask[1]  ? 4'd1 :
                     mvm_mask[2]  ? 4'd2 :
                     mvm_mask[3]  ? 4'd3 :
                     mvm_mask[4]  ? 4'd4 :
                     mvm_mask[5]  ? 4'd5 :
                     mvm_mask[6]  ? 4'd6 :
                     mvm_mask[7]  ? 4'd7 :
                     mvm_mask[8]  ? 4'd8 :
                     mvm_mask[9]  ? 4'd9 :
                     mvm_mask[10]  ? 4'd10 :
                     mvm_mask[11]  ? 4'd11 :
                     mvm_mask[12]  ? 4'd12 :
                     mvm_mask[13]  ? 4'd13 :
                     mvm_mask[14]  ? 4'd14 :
                     mvm_mask[15]  ? 4'd15 :
                                     4'd0;
wire [15:0] mvm_onehot = (16'd1 << mvm_bit);
wire  [3:0] mvm_reg  = mvm_down ? (4'd15 - mvm_bit) : mvm_bit;
// Word transfers step by two and occupy the half-word the address names --
// which for this L1 is the HIGH half of the longword pair, lanes 3 and 2,
// exactly as a sized store already does.
wire [31:0] mvm_step    = mvm_word ? 32'd2 : 32'd4;
// A downward walk decrements BEFORE the access and leaves the running
// address there; an upward walk accesses first and advances after.
wire [31:0] mvm_st_addr  = mvm_addr - mvm_step;
wire [31:0] mvm_cur_addr = mvm_down ? mvm_st_addr : mvm_addr;
wire [31:0] mvm_nxt_addr = mvm_down ? mvm_st_addr : (mvm_addr + mvm_step);

// Wanting the port and getting it are separate, the same split exc_writing
// and exc_beat_ack already use: wren_b is asserted while the request
// stands, and only a cycle where wr_busy reads low actually advances.
wire mvm_st_want = mvm_active && !mvm_dir && mvm_any && !port_taken;
wire mvm_st_go   = mvm_st_want && !l1_wr_busy;
wire mvm_ld_go   = mvm_active &&  mvm_dir && mvm_any && !mvm_rd_pend && !port_taken;

// Finished: nothing left in the mask and no read still in flight. On that
// cycle the instruction falls through to the ordinary completion path
// below, which writes An through the second port via an_wr_*.
wire mvm_fin   = mvm_active && !mvm_any && !mvm_rd_pend;
wire mvm_stall = eac_valid && eac_is_movem && !mvm_fin && !trace_hold;

assign rf3_we   = mvm_rd_pend && l1_rvalid_b;
assign rf3_addr = mvm_rd_reg;
// A Word load SIGN-EXTENDS into the whole register: MOVEM.W does not
// preserve the upper half, it replaces it with the sign. That is the one
// behaviour separating MOVEM.W's load from a pair of half-width writes.
assign rf3_data = mvm_word ? {{16{l1_q_b[31]}}, l1_q_b[31:16]} : l1_q_b;
wire        an_write = eac_valid && (eac_is_postinc || eac_is_predec);

// Address error on an odd JMP/JSR target (milestone 17, new): a SECOND
// dynamic exception trigger, same reasoning as eac_is_priv below -- "this
// is a JMP/JSR" is a decode-time fact, but "the target happens to be odd"
// depends on ea_target (above), not known until here either. Format $2
// (the 6-word frame, one extra "instruction address" longword), not
// format $0 -- see exc_pc_field/exc_addr_field below for the real,
// mode-dependent bit-exact stacked-PC quirks this needed, verified
// against ap040_core.v's own S_JMP1/S_JSR1, not guessed.
wire eac_is_jmp_odd  = eac_is_jmp && ea_target[0];
wire eac_is_jsr_odd  = eac_is_jsr && ea_target[0];
// Division by zero (milestone 52). Detected here rather than in
// ap040_execute.v for the same reason an odd JMP target is: the operand is
// already in hand, and this stage owns the frame push and the vector read.
// The divider downstream therefore never sees a zero divisor.
//
// The divisor is the <ea> side, and WHERE that is depends on the mode.
// For a register source it is operand_a. For a memory source operand_a is
// the ADDRESS -- the divisor is the value loaded into mem_lane, which is
// only meaningful once mem_pending says l1_q_b holds it.
//
// Milestone 52 checked operand_a unconditionally, so a memory-source
// DIVU.W (A1),D0 tested the ADDRESS against zero and never trapped: the
// divider ran with a zero divisor and the instruction after it executed
// normally. Found while designing CHK, which has the same operand shape.
wire [31:0] div_divisor = eac_is_mem_src ? mem_lane : operand_a;
wire divzero_now = eac_valid && eac_is_div &&
                   (eac_is_mem_src ? (mem_pending && l1_rvalid_b) : 1'b1) &&
                   (div_divisor[15:0] == 16'd0);

// ...and it has to be LATCHED, not recomputed. mem_lane is l1_q_b, which
// lives for exactly one cycle: the frame push this very exception starts
// drives a new address on port B, so by the next cycle mem_lane is the
// pushed word and the condition evaporates. Without the latch the
// exception begins, advances one beat, then unasserts itself -- and
// mem_complete, freed again, retires the instruction as if nothing had
// happened.
//
// A register-source divide needs no latch, since operand_a is stable, but
// it costs nothing to hold that case too.
reg exc_pend_divzero;
wire eac_is_divzero = divzero_now || exc_pend_divzero;

// CHK (milestone 64). Same operand shape as the divide, so the same care:
// the BOUND is the <ea> side, which for a memory source is mem_lane and
// only while mem_pending holds it. And the same latch, for the same reason
// -- the frame push this exception starts overwrites l1_q_b.
//
// N is DEFINED on the two trapping paths and nowhere else: set when the
// value is negative, cleared when it merely exceeds the bound. It goes into
// the STACKED SR, which is what the handler reads and what RTE restores, so
// it must be latched alongside the fault itself.
wire signed [15:0] chk_value = operand_b[15:0];
wire [31:0]        chk_src   = eac_is_mem_src ? mem_lane : operand_a;
wire signed [15:0] chk_bound = chk_src[15:0];
wire chk_negative = chk_value < 16'sd0;
wire chk_over     = chk_value > chk_bound;
wire chk_now = eac_valid && eac_is_chk &&
               (eac_is_mem_src ? (mem_pending && l1_rvalid_b) : 1'b1) &&
               (chk_negative || chk_over);
reg exc_pend_chk;
reg exc_pend_chk_n;
wire eac_is_chk_trap = chk_now || exc_pend_chk;

// TRAPcc (milestone 74). The condition is evaluated HERE, on sr_in's low
// five bits -- the live, forwarded CCR -- because this is where a frame
// can still be pushed. This function must match ap040_execute.v's
// cond_true bit for bit; it is duplicated rather than shared because a
// function cannot be declared in the .svh at module scope, and a
// multi-condition bench guards the two against drifting apart.
//
// Decided once and LATCHED, like divzero and CHK. Not because the CCR is
// one-cycle data -- it is stable -- but because an older instruction's
// flags may still commit during the frame push, and the trap must be
// judged on the CCR as this instruction saw it, not re-judged each beat.
function trapcc_cond_true;
	input [3:0] cond;
	input [4:0] ccr;
	begin
		case (cond)
			4'h0: trapcc_cond_true = 1'b1;
			4'h1: trapcc_cond_true = 1'b0;
			4'h2: trapcc_cond_true = !ccr[0] && !ccr[2];
			4'h3: trapcc_cond_true =  ccr[0] ||  ccr[2];
			4'h4: trapcc_cond_true = !ccr[0];
			4'h5: trapcc_cond_true =  ccr[0];
			4'h6: trapcc_cond_true = !ccr[2];
			4'h7: trapcc_cond_true =  ccr[2];
			4'h8: trapcc_cond_true = !ccr[1];
			4'h9: trapcc_cond_true =  ccr[1];
			4'hA: trapcc_cond_true = !ccr[3];
			4'hB: trapcc_cond_true =  ccr[3];
			4'hC: trapcc_cond_true =  ccr[3] ==  ccr[1];
			4'hD: trapcc_cond_true =  ccr[3] !=  ccr[1];
			4'hE: trapcc_cond_true = !ccr[2] && (ccr[3] == ccr[1]);
			default: trapcc_cond_true = ccr[2] || (ccr[3] != ccr[1]);
		endcase
	end
endfunction
// ...and only judged while EX is not stalled: a divide in EX has not
// produced its flags yet, and the forward that makes sr_in current for an
// EA-fetch consumer (ap040_pipe_core.v's ex_ccr_fwd) is valid only in the
// cycle EX's instruction actually registers.
wire trapcc_now = eac_valid && eac_is_trapcc && !stall_in &&
                  trapcc_cond_true(eac_cond, sr_in[4:0]);
reg  exc_pend_trapcc;
wire eac_is_trapcc_trap = trapcc_now || exc_pend_trapcc;

wire eac_is_addrerr  = eac_is_jmp_odd || eac_is_jsr_odd;
// The six-word frame (milestone 77): address error, and -- as on the 68040
// and in ap040_core.v's exc(..., 4'd2, pc, pc_i) -- CHK, TRAPcc and zero
// divide, whose extra longword is the faulting instruction's own address
// while the PC field stays the next instruction. TRAP, illegal, privilege
// and format error keep the four-word frame. Until milestone 77 the three
// dynamic ones pushed format $0; tb_ap040_pipe_integration4.v's handlers
// read the frames and said so.
wire eac_is_fmt2     = eac_is_addrerr || eac_is_divzero || eac_is_chk_trap ||
                       eac_is_trapcc_trap || eac_is_trace;

// The L1 always returns a full longword on port B (address_b is the HIGH
// word, the low word implicitly address_b+1), so a sized load is a lane
// select rather than a narrower access. The value lands in the LOW bits
// because ap040_pipe_alu.v masks operand a by size (am = a & szmask) and
// ap040_execute.v splices the result back by size, so everything downstream
// already does the right thing once the right bits are here.
//
// A word takes the high half of the pair, which is the word the address
// names. A byte takes one half of that word, chosen by address bit 0.
wire [31:0] mem_raw =
    (eff_size == `AP040_SZ_L) ? l1_q_b :
    (eff_size == `AP040_SZ_W) ? {16'd0, l1_q_b[31:16]} :
                                {24'd0, (ea_target[0] ? l1_q_b[23:16]
                                                      : l1_q_b[31:24])};

// The sign extension itself. Zero-extending a Word source instead is a
// silently wrong answer for every negative offset -- which is most of what
// SUBA is used for -- rather than a crash, so it gets its own check in
// tb_ap040_pipe_adda.v.
function [31:0] sxt_w_of;
	input [31:0] v;
	sxt_w_of = {{16{v[15]}}, v[15:0]};
endfunction

wire [31:0] mem_lane = eac_sxt_w ? sxt_w_of(mem_raw) : mem_raw;

// The flush cycle (milestone 78). The instruction behind an exception entry
// waits in EA-calc through the frame push and moves in here the cycle the
// entry departs -- which is the cycle EX raises flush for it. The output
// block ignores that cycle (flush has priority there), but the combinational
// side effects did not: a store wrote, a push wrote, and a TRAP's own beat 0
// went out at ISP-8 before the first entry's A7 had committed -- on top of
// the first frame. tb_ap040_pipe_trace.v found it because tracing makes
// "exception entry, then another instruction that faults" the common case;
// tb_ap040_pipe_excexc.v shows it without trace. Everything that reaches
// the L1 from this stage on the instruction's behalf is gated by `live`.
wire live         = eac_valid && !flush;

wire mem_issue    = live && eac_is_mem_src && !mem_pending && !port_taken && !trace_hold;
// ...unless this instruction has just turned out to be an exception. For a
// memory-source fault the value that CAUSES the fault is the one the load
// just returned, so both conditions are true in the same cycle -- and the
// branch chain below reaches mem_complete first, which would retire the
// instruction normally and never start the frame push. Yielding here is
// what lets a memory-source exception exist at all.
//
// No combinational loop: exc_active depends on mem_pending and mem_lane,
// neither of which depends on mem_complete.
wire mem_complete = mem_pending && l1_rvalid_b && !exc_active;
// BSR/JSR's push -- no "pending" latch needed, see header: a write either
// succeeds immediately (l1_wr_busy low) or must wait for the port, but
// never needs a separate multi-cycle completion phase the way a read does.
// eac_is_jsr_odd (milestone 17) is excluded here: an odd JSR target never
// pushes at all, per ap040_core.v's own S_JSR1 -- it goes straight to the
// address-error exception instead (below), the fault taken on the
// INSTRUCTION FETCH at the odd target, not on the call itself.
wire eac_is_push  = (eac_is_bsr || (eac_is_jsr && !eac_is_jsr_odd) || eac_is_link || eac_is_pea) && !trace_hold;
wire wr_stall     = live && (eac_is_push || store_now) && (l1_wr_busy || port_taken);

// TRAP #n / illegal instruction exception entry -- see header. exc_ph
// sequences the frame's writes and the vector-table read one at a time;
// exc_vec_pending mirrors mem_pending's own shape for the read's one-cycle
// latency. EXC_BEAT2 (milestone 17, new) is a THIRD write beat, used only
// for format $2's extra "instruction address" longword -- see
// eac_is_fmt2/exc_writing below for why format $0 exceptions skip it
// entirely rather than visiting an empty state.
localparam EXC_BEAT0 = 2'd0, EXC_BEAT1 = 2'd1, EXC_BEAT2 = 2'd2, EXC_VECRD = 2'd3;
reg [1:0] exc_ph;
reg       exc_vec_pending;

// Privilege violation (milestone 15, new): the ONLY dynamic exception
// trigger in this pipeline -- illegal/TRAP are static decode-time facts,
// but "is this opcode privileged" (MOVE to SR, MOVEC) says nothing about
// whether it actually FAULTS; that depends on the LIVE, forwarded S bit,
// which doesn't exist until here. eac_is_priv_capable is what
// ap040_decode.v recognized; eac_is_priv is whether it actually fires THIS
// cycle -- see header for why the check couldn't happen any earlier.
// The SR forms of ORI/ANDI/EORI are privileged; the CCR forms are not, and
// that is the whole difference between them at this level.
wire eac_is_priv_capable = eac_is_movesr || eac_is_movec || eac_is_rte ||
                            (eac_is_immsr && eac_immsr_to_sr);
wire eac_is_priv         = eac_is_priv_capable && !sr_in[13];

// RTE format error (milestone 76): the nibble arrives with the pop's second
// dword, so it is judged where ret_done is (below) and latched like the other
// data-derived faults -- the frame push it starts runs for several cycles and
// l1_q_b moves on.
wire fmterr_now;
reg  exc_pend_fmterr;
wire eac_is_fmterr = fmterr_now || exc_pend_fmterr;

// Instruction trace, T1 (milestone 78). The traced instruction is the one
// that LEFT this stage with T1 set in its start SR (trace_arm/trace_pc are
// written at every departure in the output block). The exception is
// delivered on the instruction that FOLLOWS it: that instruction is held
// here until EX and WB have drained -- so the stacked SR and the stack
// pointer are the real registers, after the traced instruction's own writes
// -- and is then turned into a format-$2 vector-9 entry whose PC field is
// its own address and whose address field is the traced instruction's. Its
// own semantics never happen (own_exc, and the !trace_hold gates on
// mem_issue, the push/store write, MOVEM and the RTE pop): the frame's PC
// brings it back after the handler's RTE. A traced TRAP/CHK therefore gets
// its trace on the handler's first instruction, after the exception
// processing, as on the 68020 and later. A traced MOVE to SR that clears T1
// is still traced, with T1 clear in the stacked SR, so the handler's RTE
// returns with tracing off.
reg         trace_arm;
reg  [31:0] trace_pc;
reg         exc_pend_trace;
wire trace_hold   = eac_valid && trace_arm;
wire trace_take   = trace_hold && !eaf_valid && !wb_busy && !stall_in;
wire eac_is_trace = trace_take || exc_pend_trace;
wire own_exc      = !trace_hold;   // the held instruction's own faults are not taken

// T0, trace on change of flow (milestone 79). The arm is taken by the
// instructions the 68040 defines as changes of flow: taken branches and
// DBcc, BSR/JMP/JSR, RTS/RTE, every exception entry, and the non-branch
// ones that resynchronise the pipeline -- MOVE to SR, ORI/ANDI/EORI to SR,
// MOVEC to a control register, NOP (ap040_core.v's t0_special, which
// cputest confirmed on hardware; MOVE An,USP and MOVES/CAS/CINV/CPUSH/FSAVE
// are not decoded here). A conditional branch's taken-ness is only known in
// EX, so it arms provisionally (trace_arm_cond) and EX's verdict confirms or
// cancels the arm: EX resolves the cycle after the branch departs, and the
// hold on the next instruction outlasts that. T1 traces everything and
// T1T0 = 11 behaves as T1.
wire t0_flow_static = eac_is_bsr || eac_is_jmp || eac_is_jsr || eac_is_rts || eac_is_rte ||
                      eac_is_movesr || (eac_is_immsr && eac_immsr_to_sr) ||
                      (eac_is_movec && eac_imm[3]) || eac_is_nop;
wire t0_flow_cond   = eac_is_branch || eac_is_dbcc;
wire traced_now     = sr_in[15] || (sr_in[14] && (t0_flow_static || t0_flow_cond));
wire traced_cond    = !sr_in[15] && sr_in[14] && t0_flow_cond && !t0_flow_static;
reg  trace_arm_cond;
// A held store is not a store: it selects nothing -- address, byte enables,
// data, stall, write enable -- while the trace entry's own beats go out.
// eac_is_store outranks exc_writing in l1_addr_word and st_be assumes the
// store's size, so without this the frame's beats went to the store's
// address with the store's lanes.
wire store_now    = eac_is_store && !trace_hold;

wire eac_is_exc    = eac_is_trace ||
                     (own_exc && (eac_is_trap || eac_is_illegal || eac_is_priv || eac_is_addrerr ||
                                  eac_is_divzero || eac_is_chk_trap || eac_is_trapcc_trap || eac_is_fmterr));
wire exc_active    = live && eac_is_exc;
wire exc_writing   = exc_active && !exc_vec_pending &&
                      (exc_ph == EXC_BEAT0 || exc_ph == EXC_BEAT1 ||
                       (exc_ph == EXC_BEAT2 && eac_is_fmt2));
// ...and not accepted at all if ap040_execute.v took the port this cycle:
// the core's mux drops this stage's wren_b, so the beat never reached the
// L1 and must be retried rather than counted.
wire exc_beat_ack  = exc_writing && !l1_wr_busy && !port_taken;
wire exc_vec_issue = exc_active && !exc_vec_pending && (exc_ph == EXC_VECRD);
wire exc_vec_done  = exc_active && exc_vec_pending && l1_rvalid_b;
wire exc_stall     = exc_active && !exc_vec_done;

// RTE (milestone 16, new): a genuinely supervisor RTE (eac_is_priv already
// false means sr_in[13] was 1) gets its own 2-beat READ sequencer -- the
// mirror image of the exception-entry sequencer's own WRITE beats above,
// reading back the SAME two dwords a format-$0 frame push wrote: dword0 @
// A7 = {SR, PC_hi}, dword1 @ A7+4 = {PC_lo, FmtVec}. ret_dword0 stashes
// the first read's result while the second is in flight (this stage's
// only two "carry a value forward" registers, eaf_operand_a/b, are both
// needed for the FINAL result -- the redirect target and the new A7 --
// not an intermediate one). A privilege-violating RTE never reaches this
// at all: eac_is_priv already took priority via eac_is_exc above, so
// eac_is_rte_active can safely assume supervisor.
//
// The format nibble is judged when dword1 arrives (ret_fmt_* / fmterr_now,
// below the sequencer's wires): $0 pops eight bytes, $2 and $3 twelve, and
// anything else is a format error (milestone 76).
wire eac_is_rte_active = eac_is_rte && !eac_is_priv && !trace_hold;

localparam RET_BEAT0 = 1'd0, RET_BEAT1 = 1'd1;
reg        ret_ph;
reg        ret_pending;   // this beat's read is in flight; l1_q_b valid NEXT cycle -- same shape as mem_pending
reg [31:0] ret_dword0;    // captured {SR, PC_hi} after beat 0 completes

wire ret_active   = live && eac_is_rte_active;
wire ret_issue    = ret_active && !ret_pending;
wire ret_complete = ret_active && ret_pending && l1_rvalid_b;
wire ret_done     = ret_complete && (ret_ph == RET_BEAT1);
wire ret_stall    = ret_active && !ret_done;

// Every port-B read this stage makes, as the L1's request strobe. The four
// requesters are exclusive by construction (one instruction is never more
// than one of them), and each waits for l1_rvalid_b before it looks at l1_q_b
// (milestone 80): mem_complete, exc_vec_done, ret_complete, rf3_we.
assign l1_rd_b = mem_issue || exc_vec_issue || ret_issue || mvm_ld_go;

// Format check (milestone 76). $0 is the four-word frame this core pushes
// for everything but address error; $2 and $3 are the six-word frames ($3
// is the FPU post-instruction frame, same shape -- ap040_core.v's S_RTE_FIN
// accepts both, and so does this). Anything else is a format error: vector
// 14, a format-$0 frame stacking the RTE's OWN address so the handler can
// repair the frame and re-execute it, and A7 unchanged -- the pop never
// commits. fmterr_now makes the ret_done cycle an exception entry instead:
// exc_writing sits above ret_done in the output block's chain and wins the
// L1 address mux, so beat 0 of the frame goes out in that same cycle.
//
// Deliberate deviations, deferred with the mechanisms they need: $1
// (throwaway) needs the SR loaded and the pop restarted on the next frame;
// $7 (access error) needs the BCU/MMU that would push it. Both land here
// rather than being silently popped as $0.
wire [3:0] ret_fmt      = l1_q_b[15:12];
wire       ret_fmt_long = (ret_fmt[3:1] == 3'b001);   // $2 or $3: twelve bytes
wire       ret_fmt_ok   = (ret_fmt == 4'h0) || ret_fmt_long;
assign fmterr_now = ret_done && !ret_fmt_ok;

assign eaf_stall = stall_in || mem_issue || (mem_pending && !l1_rvalid_b) || wr_stall || exc_stall ||
                   ret_stall || port_taken || mvm_stall ||
                   (trace_hold && !exc_active);   // waiting for EX/WB to drain before the trace entry
assign raddr_a    = mvm_st_want ? mvm_reg : eac_src_reg;
// A privilege violation reroutes port B to A7 REGARDLESS of what the
// faulting instruction's own eac_dest_reg says (MOVEC's read direction
// points it at the destination GPR, Rn, for its NORMAL case) -- but NOT via
// port B/operand_b at all (see exc_new_sp below for why: an exception's OWN
// stack access must never go through the CURRENTLY active bank, which could
// be USP). raddr_b stays the plain, unconditional eac_dest_reg -- MOVEC's
// read direction doesn't actually need port B for its result either (that
// comes from creg_read_value in ap040_execute.v, entirely bypassing this
// port), so there is no live conflict left to resolve here at all.
// Port C carries the index register, and forwards exactly as A and B do:
// MOVE.L D1,D3 followed by MOVE.L (0,A0,D3.L),D2 must see the new D3.
assign raddr_c    = idx_reg;
wire fwd_c_from_ex  = ex_fwd_valid  && (ex_fwd_dest  == idx_reg);
wire fwd_c_from_ex2 = ex_fwd2_valid && (ex_fwd2_dest == idx_reg);
wire [31:0] operand_c = fwd_c_from_ex  ? ex_fwd_data  :
                        fwd_c_from_ex2 ? ex_fwd2_data : rdata_c;

assign raddr_b    = eac_dest_reg;

wire fwd_b_from_ex  = ex_fwd_valid  && (ex_fwd_dest  == eac_dest_reg);
wire fwd_b_from_ex2 = ex_fwd2_valid && (ex_fwd2_dest == eac_dest_reg);

// Port B has no immediate case -- it's always "the destination register's
// current value" -- so it's a flat 2-way select.
wire [31:0] operand_b = fwd_b_from_ex  ? ex_fwd_data  :
                       fwd_b_from_ex2 ? ex_fwd2_data : rdata_b;

// BSR/JSR's push address AND the new A7 value to commit are the SAME
// expression, from operand_b (A7's current value via port B, decode having
// set eac_dest_reg to A7's unified index for both -- see header).

// TRAP #n / illegal instruction / privilege violation: A7's NEW value after
// a format-$0 (8-byte) frame -- but NOT computed from operand_b/port B,
// unlike BSR/JSR's push_addr above. An exception's own stack access must
// ALWAYS target a SUPERVISOR stack (ISP, or MSP if M=1 -- never USP),
// regardless of which bank was active when the fault occurred: a privilege
// violation taken WHILE ALREADY IN USER MODE (S=0) would otherwise read
// port B's A7 as USP and silently push its own exception frame onto the
// user stack -- confirmed wrong against ap040_core.v's own S_EXC0/S_EXC1
// ordering (`sr[13]<=1` commits a FULL CYCLE before `dbg_a7` -- itself
// bank-selected off the now-already-supervisor sr -- is read for the
// stack pointer), not assumed. isp_in/msp_in are ap040_pipe_regfile.v's
// OWN state, read directly (same "fed straight from its real home"
// precedent ap040_execute.v's MOVEC-read inputs already established),
// completely bypassing whatever bank sr_s/sr_m currently have port B
// pointed at. Recomputed live every cycle of the sequence rather than
// latched once: eac_*/sr_in are frozen by exc_stall the whole time anyway
// (nothing downstream can change them), so a latch would just be a
// redundant copy.
//
// exc_sr_word (simplified, milestone 15): no more synthesis -- sr_in IS a
// real, live SR now (was a fixed system-byte constant over just CCR before
// this milestone), so the pushed word is simply the value being saved,
// exactly as architecturally required.
//
// exc_frame_size (milestone 17, new): format $2 is 12 bytes (6 words),
// format $0 is 8 (4 words) -- the ONLY difference in overall frame shape
// this milestone introduces; everything else about the sequencer (which
// stack, how M/S select it) is unchanged.
wire [31:0] exc_sp_bank    = sr_in[12] ? msp_in : isp_in;   // M selects ISP vs MSP; S is irrelevant here
wire [31:0] exc_frame_size = eac_is_fmt2 ? 32'd12 : 32'd8;
wire [31:0] exc_new_sp     = exc_sp_bank - exc_frame_size;
wire [15:0] exc_sr_word    = (eac_is_chk_trap && !eac_is_trace)
                              ? {sr_in[15:4],
                                 (exc_pend_chk ? exc_pend_chk_n : chk_negative), sr_in[2:0]}
                              : sr_in;
// Illegal and privilege violation both stack the FAULTING instruction's OWN
// address (go_illegal's/go_priv's shared pc_i convention -- you can't
// "return past" either kind of fault); TRAP stacks the FOLLOWING
// instruction's (its return address, a subroutine call).
//
// Odd JMP/JSR target (milestone 17, new): NEITHER of the above two
// conventions -- verified against ap040_core.v's own S_JMP1/S_JSR1, not
// guessed, and the two are genuinely DIFFERENT from each other:
//   JMP:  pc_i+2 -- gencpu's i_JMP already did incpc(2) before the fault
//         is even detected, regardless of how many extension words this
//         JMP gathered; this decoder's own id_next_pc (held_pc+2+width)
//         would be WRONG here for the (d16,An) form specifically, since
//         real hardware's "+2" reflects the OPCODE WORD alone, not the
//         whole gathered instruction -- eac_pc+2 is used directly instead.
//         (The v24 AE corpus's OTHER value, pc_i+6 for indexed/absolute-
//         long modes, doesn't apply: this decoder has neither mode.)
//   JSR:  ea_target ITSELF, not any PC-relative value at all -- unlike
//         JMP, a 68040 takes an odd JSR's fault on the INSTRUCTION FETCH
//         at the odd target, so the frame names THAT target, not the
//         call site. This is also why JSR's push never happens for this
//         case (see eac_is_push above) -- there is no return address to
//         protect if the call itself never completes.
wire [31:0] exc_pc_field   = eac_is_trace   ? eac_pc :   // the instruction the trace handler returns to
                              eac_is_jmp_odd ? (eac_pc + 32'd2) :
                              eac_is_jsr_odd ? ea_target :
                              (eac_is_illegal || eac_is_priv || eac_is_fmterr) ? eac_pc : eac_next_pc;
wire  [7:0] exc_vec_num    = eac_is_trace ? 8'd9 :
                              eac_is_illegal ? 8'd4 : eac_is_priv ? 8'd8 :
                              eac_is_addrerr ? 8'd3 :
                              eac_is_divzero ? 8'd5 :
                              eac_is_chk_trap ? 8'd6 :
                              eac_is_trapcc_trap ? 8'd7 :
                              eac_is_fmterr ? 8'd14 : eac_imm[7:0];
wire [15:0] exc_vecoff_word = {eac_is_fmt2 ? 4'd2 : 4'd0, 2'b00, exc_vec_num, 2'b00};
// Format $2's own extra "instruction address" longword. For an odd JMP/JSR
// target it is the target itself, LSB cleared (ap040_core.v's own convention
// for this field, identical for JMP and JSR despite their differing PC
// fields above); for CHK, TRAPcc and zero divide it is the faulting
// instruction's own address (ap040_core.v passes pc_i), which is what a
// handler needs to find the instruction its PC field has already stepped past.
wire [31:0] exc_addr_field = eac_is_trace   ? trace_pc :
                             eac_is_addrerr ? {ea_target[31:1], 1'b0} : eac_pc;

// Beat0 @ exc_new_sp: SR, then PC's high word. Beat1 @ exc_new_sp+4: PC's
// low word, then the format/vector-offset word. Beat2 @ exc_new_sp+8
// (format $2 only): the extra address field -- five/six 16-bit frame
// words packed into two or three 32-bit L1 writes, see header.
wire [31:0] exc_beat_addr = (exc_ph == EXC_BEAT2) ? (exc_new_sp + 32'd8) :
                             (exc_ph == EXC_BEAT1) ? (exc_new_sp + 32'd4) : exc_new_sp;
wire [31:0] exc_wdata     = (exc_ph == EXC_BEAT0) ? {exc_sr_word, exc_pc_field[31:16]} :
                             (exc_ph == EXC_BEAT1) ? {exc_pc_field[15:0], exc_vecoff_word} :
                                                       exc_addr_field;   // EXC_BEAT2

// Vector table address: vector*4, used as an ABSOLUTE address fed through
// the SAME PC_RESET-relative conversion below -- see header for why no
// special-casing (a real VBR, a separate low-memory region) is needed.
wire [31:0] exc_vec_addr = {22'd0, exc_vec_num, 2'b00};

// RTE's own two read-beat addresses: A7 (dword0), A7+4 (dword1) -- via
// operand_a/port A, same as RTS's mem_issue/mem_complete reuse (decode set
// eac_src_reg=A7 for RTE too, see ap040_decode.v's header).
wire [31:0] ret_addr = (ret_ph == RET_BEAT1) ? (operand_a + 32'd4) : operand_a;

// Driven unconditionally, same "compute always, gate consumption" precedent
// as raddr_b -- harmless when none of eac_is_mem_src/eac_is_jmp/eac_is_push/
// eac_is_exc/eac_is_rte_active is set, nothing reads l1_q_b or l1_wr_busy
// that cycle. PC_RESET-relative to match ap040_inst_fetch.v's own L1
// addressing -- see header. Five-way select: a READ target (memory-source,
// JMP/JSR's redirect, or now RTS via the same mem_issue/mem_complete path),
// the BSR/JSR PUSH address, an exception frame WRITE beat, the exception's
// own vector-table READ, or RTE's own pop READ -- mutually exclusive by
// construction (an instruction is never more than one of these at once).
wire [31:0] l1_addr_word = mvm_active   ? mvm_cur_addr :
                            store_now ? (eac_is_abs    ? eac_imm :
                                                       eac_is_predec ? (an_base - an_step)
                                                                     : an_base) :
                            eac_is_push  ? push_addr :
                            exc_writing ? exc_beat_addr :
                            (exc_vec_issue || exc_vec_pending) ? exc_vec_addr :
                            ret_active  ? ret_addr :
                                                                  ea_target;
assign l1_addr_b = l1_addr_word;   // the byte address itself (milestone 81)
assign l1_wren_b = (live && (eac_is_push || store_now)) || exc_writing || mvm_st_want;
// A sized store places its data in the lane the address names and enables
// only that lane. Lane 3 is the longword's first byte, matching
// ap040_pipe_l1.v's be_b. Everything that is not a sized store -- pushes,
// exception frames, Long stores -- asserts all four and is unaffected.
wire [1:0]  st_off = l1_addr_word[1:0];
wire [3:0]  st_be  = (!store_now)             ? 4'b1111 :
                     (eac_size == `AP040_SZ_L)   ? 4'b1111 :
                     (eac_size == `AP040_SZ_W)   ? 4'b1100 :
                     st_off[0]                   ? 4'b0100 : 4'b1000;
wire [31:0] st_dat = (eac_size == `AP040_SZ_L || !store_now) ? operand_a :
                     (eac_size == `AP040_SZ_W) ? {operand_a[15:0], 16'd0} :
                     st_off[0] ? {8'd0, operand_a[7:0], 16'd0}
                               : {operand_a[7:0], 24'd0};

assign l1_be_b   = mvm_active ? (mvm_word ? 4'b1100 : 4'b1111) : st_be;
// operand_a is port A, which mvm_st_want has pointed at the register this
// beat stores -- so the same wire that carries a LINK's pushed An carries
// each MOVEM register in turn.
// Three different things ride the same push: BSR pushes a return address,
// LINK pushes the old An, and PEA pushes the effective address itself.
assign l1_data_b = mvm_st_want  ? (mvm_word ? {operand_a[15:0], 16'd0} : operand_a) :
                   exc_writing  ? exc_wdata :
                   store_now ? st_dat  :
                   eac_is_pea   ? ea_target :
                   eac_is_link  ? operand_a : eac_next_pc;

always @(posedge clk) begin
	if (!nreset) begin
		eaf_valid      <= 1'b0;
		eaf_pc         <= 32'h0;
		eaf_next_pc    <= 32'h0;
		eaf_dest_reg   <= 4'h0;
		eaf_operand_a  <= 32'h0;
		eaf_operand_b  <= 32'h0;
		eaf_alu_op     <= 6'h0;
		eaf_size       <= `AP040_SZ_L;
		eaf_shcnt      <= 6'd1;
		eaf_writes_an  <= 1'b0;
		eaf_an_reg     <= 4'd0;
		eaf_an_data    <= 32'd0;
		eaf_writes_reg <= 1'b0;
		eaf_writes_ccr <= 1'b0;
		eaf_is_branch  <= 1'b0;
		eaf_is_scc     <= 1'b0;
		eaf_is_dbcc    <= 1'b0;
		eaf_is_jmp     <= 1'b0;
		eaf_is_bsr     <= 1'b0;
		eaf_is_jsr     <= 1'b0;
		eaf_is_trap    <= 1'b0;
		eaf_is_illegal <= 1'b0;
		eaf_is_priv    <= 1'b0;
		eaf_is_addrerr <= 1'b0;
		eaf_is_divzero <= 1'b0;
		eaf_is_movesr  <= 1'b0;
		eaf_is_movec   <= 1'b0;
		eaf_movec_dir  <= 1'b0;
		eaf_movec_sel  <= 3'h0;
		eaf_sr_snapshot<= 16'h0;
		eaf_is_rmw     <= 1'b0;
		eaf_is_div     <= 1'b0;
		eaf_div_signed <= 1'b0;
		eaf_is_chk     <= 1'b0;
		eaf_is_trapcc     <= 1'b0;
		eaf_is_immsr   <= 1'b0;
		eaf_immsr_to_sr<= 1'b0;
		eaf_is_pea     <= 1'b0;
		eaf_is_link    <= 1'b0;
		eaf_ea_target  <= 32'h0;
		eaf_is_rts     <= 1'b0;
		eaf_is_rte     <= 1'b0;
		eaf_is_fmterr  <= 1'b0;
		eaf_is_trace   <= 1'b0;
		eaf_rte_sr_data<= 16'h0;
		eaf_cond       <= 4'h0;
		mem_pending    <= 1'b0;
		mvm_active     <= 1'b0;
		mvm_mask       <= 16'h0;
		mvm_addr       <= 32'h0;
		mvm_dir        <= 1'b0;
		mvm_word       <= 1'b0;
		mvm_down       <= 1'b0;
		mvm_wb         <= 1'b0;
		mvm_rd_pend    <= 1'b0;
		mvm_rd_reg     <= 4'h0;
		exc_pend_divzero <= 1'b0;
		exc_pend_chk     <= 1'b0;
		exc_pend_chk_n   <= 1'b0;
		exc_pend_trapcc  <= 1'b0;
		exc_pend_fmterr  <= 1'b0;
		exc_pend_trace   <= 1'b0;
		trace_arm        <= 1'b0;
		trace_arm_cond   <= 1'b0;
		trace_pc         <= 32'h0;
		exc_ph          <= EXC_BEAT0;
		exc_vec_pending <= 1'b0;
		ret_ph          <= RET_BEAT0;
		ret_pending     <= 1'b0;
	end else if (ce) begin
		// Held from the cycle the divisor was seen until the exception has
		// fetched its vector; see the latch's own comment above.
		if (exc_vec_done)      exc_pend_divzero <= 1'b0;
		else if (divzero_now)  exc_pend_divzero <= 1'b1;

		if (exc_vec_done)  exc_pend_chk <= 1'b0;
		else if (chk_now) begin
			exc_pend_chk   <= 1'b1;
			exc_pend_chk_n <= chk_negative;
		end

		if (exc_vec_done)     exc_pend_trapcc <= 1'b0;
		else if (trapcc_now)  exc_pend_trapcc <= 1'b1;

		if (exc_vec_done)     exc_pend_fmterr <= 1'b0;
		else if (fmterr_now)  exc_pend_fmterr <= 1'b1;

		if (exc_vec_done)     exc_pend_trace <= 1'b0;
		else if (trace_take)  exc_pend_trace <= 1'b1;

		// A provisionally armed conditional branch: EX's verdict decides.
		// Nothing departs this stage while the arm is up, so no departure
		// write below can land in the same cycle as this one.
		if (ex_br_resolve && trace_arm_cond) begin
			trace_arm      <= ex_br_taken;
			trace_arm_cond <= 1'b0;
		end

		if (flush) begin
			eaf_valid       <= 1'b0;
			mem_pending     <= 1'b0;
			mvm_active      <= 1'b0;
			mvm_rd_pend     <= 1'b0;
			exc_pend_divzero <= 1'b0;
			exc_pend_chk     <= 1'b0;
			exc_pend_trapcc  <= 1'b0;
			exc_pend_fmterr  <= 1'b0;
			exc_pend_trace   <= 1'b0;
			// trace_arm is NOT cleared by a flush: the flush that follows a
			// traced branch or a traced exception entry kills the wrong-path
			// or unreached instruction here, and the trace is still owed to
			// whichever instruction arrives next. It is cleared only when the
			// trace entry itself departs (exc_vec_done below).
			// Abandon a mid-flight exception sequence the same way an
			// abandoned mem_pending read is: nothing downstream of a flush
			// consumes what was in progress, but exc_ph/exc_vec_pending
			// MUST reset here too, or the next (unrelated) exception
			// instruction would resume mid-sequence instead of starting at
			// beat0. ret_ph/ret_pending need the same treatment for a
			// mid-flight RTE.
			exc_ph          <= EXC_BEAT0;
			exc_vec_pending <= 1'b0;
			ret_ph          <= RET_BEAT0;
			ret_pending     <= 1'b0;
		end else if (!stall_in) begin
			if (mem_issue) begin
				eaf_valid   <= 1'b0;
				mem_pending <= 1'b1;
			end else if (mem_complete) begin
				eaf_valid      <= eac_valid;
				eaf_pc         <= eac_pc;
				eaf_next_pc    <= eac_next_pc;
				eaf_dest_reg   <= eac_dest_reg;
				trace_arm      <= traced_now;   // T1: always; T0: if it changes flow
				trace_arm_cond <= traced_cond;
				trace_pc       <= eac_pc;
				// A read-modify-write crosses its operands over here. The
				// ALU computes b op a, and SUB.L D0,(A0) must be memory
				// MINUS D0 -- so the loaded value has to be b, not a, which
				// is the opposite of every other memory-source instruction.
				// operand_b is the data register Dn (decode pointed
				// eac_dest_reg at it precisely so this read would be
				// available), and operand_a was only ever the address base.
				eaf_operand_a  <= eac_is_rmw ? operand_b : mem_lane;
				// The store half needs the address again a stage later, and
				// eac_* will have moved on by then.
				eaf_is_rmw     <= eac_is_rmw;
				eaf_is_div     <= eac_is_div;
				eaf_div_signed <= eac_div_signed;
				eaf_ea_target  <= ea_target;
				// RTS: the popped value (l1_q_b, into eaf_operand_a above)
				// is the redirect target, exactly like JMP/JSR/exceptions
				// already route through eaf_operand_a -- but this stage
				// ALSO owes A7 its post-pop value (old+4), which is NOT
				// what a plain MOVE.L (An),Dn would put in eaf_operand_b
				// (that instruction's operand_b is simply unused). See
				// header.
				eaf_operand_b  <= eac_is_rts ? (operand_a + 32'd4) :
				                  eac_is_rmw ? mem_lane            : operand_b;
				eaf_alu_op     <= eac_alu_op;
				eaf_size       <= eac_size;
				eaf_shcnt      <= eac_shcnt;
				eaf_writes_an  <= an_wr_any;
				eaf_an_reg     <= an_wr_reg;
				eaf_an_data    <= an_wr_data;
				eaf_writes_reg <= eac_writes_reg;
				eaf_writes_ccr <= eac_writes_ccr;
				eaf_is_branch  <= eac_is_branch;
				eaf_is_scc     <= eac_is_scc;
				eaf_is_dbcc    <= eac_is_dbcc;
				eaf_is_jmp     <= 1'b0;
				eaf_is_bsr     <= 1'b0;
				eaf_is_jsr     <= 1'b0;
				eaf_is_trap    <= 1'b0;
				eaf_is_illegal <= 1'b0;
				eaf_is_priv    <= 1'b0;
				eaf_is_addrerr <= 1'b0;
				eaf_is_divzero <= 1'b0;
				eaf_is_movesr  <= 1'b0;
				eaf_is_movec   <= 1'b0;
				eaf_is_rts     <= eac_is_rts;
				eaf_is_rte     <= 1'b0;
				eaf_is_fmterr  <= 1'b0;
				eaf_is_trace   <= 1'b0;
				eaf_sr_snapshot<= sr_in;
				eaf_cond       <= eac_cond;
				mem_pending    <= 1'b0;
			end else if (mem_pending && !exc_active) begin
				// The read is in flight and has not returned (milestone 80).
				// Without this branch the chain fell through to the default
				// and DEPARTED the instruction with no data. A faulting
				// memory-source load keeps mem_pending set through its own
				// exception entry, so exc_active must get past this.
				eaf_valid      <= 1'b0;
			end else if (wr_stall) begin
				// Waiting for l1_wr_busy to clear -- see header. eac_* stays
				// frozen (eaf_stall propagates backward), so this re-evaluates
				// identically next cycle with the SAME push request still
				// asserted, until the port is free.
				eaf_valid <= 1'b0;
			end else if (port_taken) begin
				// ap040_execute.v has L1 port B this cycle for a
				// read-modify-write's store half. This stage emits a BUBBLE
				// and retries -- the same mechanism mem_issue already uses,
				// and deliberately not a freeze of the output registers:
				// eaf_valid is the only thing that can drop ex_st_req, so
				// holding it would deadlock the pipeline against itself.
				// eac_* is held by eaf_stall, so nothing is lost.
				//
				// This sits AFTER the mem_complete branch on purpose. A
				// completing read consumes l1_q_b, which the L1 registered
				// from the address driven LAST cycle -- before EX took the
				// port -- so that data is still ours and must be taken now.
				// Bubbling ahead of it would drop it on the floor, since
				// next cycle l1_q_b holds whatever EX's store put there.
				eaf_valid       <= 1'b0;
			end else if (trace_hold && !exc_active) begin
				// The instruction after a traced one waits here, doing
				// nothing, until EX and WB are empty; then trace_take turns
				// it into the trace entry (exc_writing, above in this chain
				// on the next pass).
				eaf_valid       <= 1'b0;
			end else if (eac_valid && eac_is_movem && !mvm_fin && !trace_hold) begin
				// Start, then one beat per cycle. eac_* is frozen by
				// mvm_stall throughout, so operand_a still reads An on the
				// starting cycle, and the mask and base are latched once.
				eaf_valid <= 1'b0;
				if (!mvm_active) begin
					mvm_active  <= 1'b1;
					mvm_dir     <= eac_movem_dir;
					mvm_word    <= eac_movem_word;
					mvm_down    <= eac_movem_down;
					mvm_wb      <= eac_movem_wb;
					// The mask is the HIGH half of eac_imm and the low half is a
					// displacement, zero for every mode that has none.
					mvm_mask    <= eac_movem_mask;
					// Three bases. $xxx.W is the sign-extended low half alone.
					// (d16,PC)'s base is the address of the DISPLACEMENT word,
					// which for MOVEM is PC+4 -- the mask word sits between the
					// opcode and the displacement, unlike every other
					// PC-relative mode, where the base is PC+2. Getting this
					// wrong reads the table one word early.
					// eac_imm is already the EA: sign-extended for a displacement
					// or $xxx.W, all 32 bits for $xxx.L, zero for the modes with
					// none. The mask has its own field since milestone 73.
					mvm_addr    <= eac_movem_abs   ? eac_imm :
					               eac_movem_pcrel ? (eac_pc + 32'd4 + eac_imm) :
					                                 (operand_a + eac_imm);
					mvm_rd_pend <= 1'b0;
					mvm_rd_reg  <= 4'h0;
				end else if (mvm_ld_go) begin
					// Address driven this cycle; l1_q_b has it next, and
					// rf3_we commits it then.
					mvm_mask    <= mvm_mask & ~mvm_onehot;
					mvm_addr    <= mvm_nxt_addr;
					mvm_rd_pend <= 1'b1;
					mvm_rd_reg  <= mvm_reg;
				end else if (mvm_rd_pend && l1_rvalid_b) begin
					mvm_rd_pend <= 1'b0;
				end else if (mvm_st_go) begin
					// Predecrementing: the beat wrote mvm_st_addr, which
					// becomes the new running address.
					mvm_mask    <= mvm_mask & ~mvm_onehot;
					mvm_addr    <= mvm_nxt_addr;
				end
			end else if (exc_writing) begin
				// Posting one beat of the exception frame -- see header.
				// exc_beat_ack means l1_wr_busy read low THIS cycle, so the
				// combinational wren_b above is being accepted right now;
				// advance to the next beat. Otherwise the port's still
				// busy: hold exc_ph, retry the SAME beat next cycle (eac_*
				// stays frozen via exc_stall, exactly like wr_stall above).
				// After beat 1, format $2 needs one more beat (EXC_BEAT2,
				// the extra address field); format $0 skips straight to
				// the vector-table read -- exc_writing's own gating above
				// already ensures EXC_BEAT2 is never ENTERED for a format
				// $0 exception, so no separate check is needed once we're
				// actually leaving beat 2.
				eaf_valid <= 1'b0;
				if (exc_beat_ack) begin
					case (exc_ph)
						EXC_BEAT0: exc_ph <= EXC_BEAT1;
						EXC_BEAT1: exc_ph <= eac_is_fmt2 ? EXC_BEAT2 : EXC_VECRD;
						default:   exc_ph <= EXC_VECRD;   // EXC_BEAT2 done
					endcase
				end
			end else if (exc_vec_issue) begin
				// Both frame writes are posted; the vector-table address is
				// being driven THIS cycle (l1_addr_b, see the combinational
				// block above) -- l1_q_b registers its data by next cycle,
				// same one-cycle latency mem_issue/mem_complete already
				// relies on.
				eaf_valid       <= 1'b0;
				exc_vec_pending <= 1'b1;
			end else if (exc_vec_pending && !exc_vec_done) begin
				// vector read in flight (milestone 80) -- same as mem_pending above
				eaf_valid       <= 1'b0;
			end else if (exc_vec_done) begin
				// l1_q_b now holds the handler address fetched last cycle.
				// eaf_operand_a carries it into ap040_execute.v's
				// ex_recovery_pc exactly like JMP/JSR's redirect target;
				// eaf_operand_b carries A7's new (post-push) value into the
				// regfile commit, exactly like BSR/JSR's decrement -- zero
				// new mux shapes in ap040_execute.v beyond adding these two
				// flags to existing OR-chains, see its header.
				eaf_valid      <= eac_valid;
				eaf_pc         <= eac_pc;
				eaf_next_pc    <= eac_next_pc;
				// eac_dest_reg is ALREADY A7 for illegal/TRAP/MOVE-to-SR/
				// MOVEC-write/JSR (decode's static "dummy anchor" trick,
				// same as BSR) -- the cases that genuinely need overriding
				// here are a privilege violation on MOVEC's READ direction
				// (eac_dest_reg is Rn, the instruction's own, now-
				// suppressed, real destination) and an odd JMP target
				// (JMP, unlike JSR, writes NO register at all normally, so
				// decode never pointed eac_dest_reg at A7 for it in the
				// first place): the exception's OWN result (the new
				// supervisor SP, see exc_sp_bank above) must commit to A7
				// in both cases, not whatever eac_dest_reg otherwise says.
				// Divide by zero joins the dynamic exceptions here (milestone
				// 52) for the same reason priv and address error are in the
				// list: decode could not know this instruction would fault,
				// so eac_dest_reg still names the divide's own destination
				// register, and the exception's result -- the new supervisor
				// SP -- would commit THERE instead of to A7.
				eaf_dest_reg   <= (eac_is_priv || eac_is_addrerr || eac_is_divzero ||
				                    eac_is_chk_trap || eac_is_trapcc_trap || eac_is_fmterr ||
				                    eac_is_trace) ? 4'd15 : eac_dest_reg;
				// The vector is a LONGWORD, always. It must not go through
				// mem_lane, which selects a lane from eff_size and would
				// hand back a sign-extended half-word for any faulting
				// instruction that set eac_sxt_w. Divide by zero is the
				// first instruction that both sets it and can fault, so
				// this was latent until milestone 52: the frame pushed and
				// the vector read correctly, and then the redirect went to
				// $00000000.
				eaf_operand_a  <= l1_q_b;
				eaf_operand_b  <= exc_new_sp;
				// An exception entry is the traced instruction's completion
				// (a traced TRAP is traced on its handler's first
				// instruction), except the trace entry itself: the SR it
				// stacks still has T1, but the handler starts with it clear.
				trace_arm      <= (sr_in[15] || sr_in[14]) && !eac_is_trace;   // an entry is a change of flow
				trace_arm_cond <= 1'b0;
				trace_pc       <= eac_pc;
				eaf_alu_op     <= eac_alu_op;
				eaf_size       <= eac_size;
				eaf_shcnt      <= eac_shcnt;
				eaf_writes_an  <= an_wr_any && own_exc;   // a trace entry runs none of the held instruction
				eaf_an_reg     <= an_wr_reg;
				eaf_an_data    <= an_wr_data;
				// UNCONDITIONALLY 1, not forwarded from eac_writes_reg:
				// every exception entry writes A7 the new SP, full stop --
				// illegal/TRAP already had eac_writes_reg=1 for this exact
				// reason, but MOVE-to-SR/MOVEC-write have eac_writes_reg=0
				// in their OWN normal case (they don't write a GPR at all
				// normally -- see ap040_decode.v's header), which would
				// silently skip A7's commit on their privilege-violation
				// path if forwarded here.
				eaf_writes_reg <= 1'b1;
				eaf_writes_ccr <= eac_writes_ccr;
				eaf_is_branch  <= 1'b0;
				eaf_is_scc     <= 1'b0;
				eaf_is_dbcc    <= 1'b0;
				eaf_is_jmp     <= 1'b0;
				eaf_is_rmw     <= 1'b0;
				eaf_is_link    <= 1'b0;
				eaf_is_pea     <= 1'b0;
				eaf_is_immsr   <= 1'b0;
				eaf_is_chk     <= eac_is_chk_trap && own_exc;
				eaf_is_trapcc     <= eac_is_trapcc_trap && own_exc;
				eaf_is_div     <= 1'b0;
				eaf_div_signed <= 1'b0;
				eaf_is_bsr     <= 1'b0;
				eaf_is_jsr     <= 1'b0;
				eaf_is_trap    <= eac_is_trap && own_exc;
				eaf_is_illegal <= eac_is_illegal && own_exc;
				eaf_is_priv    <= eac_is_priv && own_exc;
				eaf_is_addrerr <= eac_is_addrerr && own_exc;
				eaf_is_divzero <= eac_is_divzero && own_exc;
				// The original (now-suppressed) instruction's own semantics
				// must not reach EX -- a MOVEC/MOVE-to-SR that just faulted
				// is NOT also still a MOVEC/MOVE-to-SR as far as
				// ap040_execute.v is concerned, exactly like a mem-source
				// instruction is never also a JMP above. Same for an odd
				// JMP/JSR target -- it is NOT also still a JMP/JSR (its
				// normal redirect never happened; the exception's own
				// target, from the vector table, is what eaf_operand_a
				// carries instead).
				eaf_is_movesr  <= 1'b0;
				eaf_is_movec   <= 1'b0;
				// An RTE that just privilege-violated is NOT also still an
				// RTE as far as ap040_execute.v is concerned -- same
				// reasoning as movesr/movec above; its own pop never
				// happened (ret_ph's sequencer never even started, gated
				// on eac_is_rte_active).
				eaf_is_rts     <= 1'b0;
				eaf_is_rte     <= 1'b0;
				eaf_is_fmterr  <= eac_is_fmterr;
				eaf_is_trace   <= eac_is_trace;
				// The value ap040_execute.v's exception-masking arithmetic
				// needs -- captured HERE (this stage's own already-forwarded
				// read), not re-read live one cycle later there, to avoid a
				// combinational loop through EX's own SR forward -- see its
				// header.
				eaf_sr_snapshot <= sr_in;
				eaf_cond       <= eac_cond;
				exc_ph          <= EXC_BEAT0;
				exc_vec_pending <= 1'b0;
				// A format error left the pop parked at beat 1 with its read
				// still marked pending (ret_done's branch never ran); the next
				// RTE must start at beat 0. Already there for every other
				// exception. Unobservable in tb_ap040_pipe_fmterr.v with this
				// removed: the flush EX raises for every exception resets
				// both a cycle later, before anything can consume them. Kept
				// so the sequencer's own exit leaves it clean.
				ret_ph          <= RET_BEAT0;
				ret_pending     <= 1'b0;
			end else if (ret_issue) begin
				// Posting this beat's read address (ret_addr, driven
				// combinationally above) -- l1_q_b registers its data by
				// next cycle, same one-cycle latency mem_issue/mem_complete
				// and the exception's own vector-fetch already rely on.
				eaf_valid   <= 1'b0;
				ret_pending <= 1'b1;
			end else if (ret_pending && !ret_complete) begin
				// pop beat in flight (milestone 80)
				eaf_valid   <= 1'b0;
			end else if (ret_complete && ret_ph == RET_BEAT0) begin
				// l1_q_b now holds dword0 ({SR, PC_hi}) -- stash it (this
				// stage's carry-forward registers, eaf_operand_a/b, are
				// both needed for the FINAL result below, not an
				// intermediate one), advance to beat 1.
				ret_dword0  <= l1_q_b;
				ret_ph      <= RET_BEAT1;
				ret_pending <= 1'b0;
				eaf_valid   <= 1'b0;
			end else if (ret_done) begin
				// l1_q_b now holds dword1 ({PC_lo, FmtVec}) -- finalize.
				//
				// The format nibble is now CONSULTED (milestone 54). It was
				// read off the stack from the start and ignored, which was
				// harmless while nothing could push anything but a format
				// $0 frame. Milestone 17 made address error push a format
				// $2 frame, and from then on an RTE returning from an
				// address-error handler popped eight bytes off a
				// twelve-byte frame and left A7 four bytes low -- the stack
				// slowly walking downward, once per such return.
				//
				// Only the frame SIZE differs between the two: the SR, PC
				// and format word sit at the same offsets, and format $2's
				// extra longword is the faulting address, which this core
				// has no use for on return.
				//
				// A nibble that is neither $0 nor $2/$3 never reaches this
				// branch: fmterr_now made this cycle an exception entry, and
				// exc_writing sits above ret_done in this chain (milestone 76).
				eaf_valid       <= eac_valid;
				eaf_pc          <= eac_pc;
				eaf_next_pc     <= eac_next_pc;
				eaf_dest_reg    <= eac_dest_reg;   // already A7 -- unused for RTE's OWN write now, see below
				eaf_operand_a   <= {ret_dword0[15:0], l1_q_b[31:16]};   // popped PC -> redirect target
				trace_arm       <= traced_now;   // judged on the SR BEFORE the RTE, whatever it restores
				trace_arm_cond  <= 1'b0;         // (RTE is a change of flow, so T0 traces it too)
				trace_pc        <= eac_pc;
				eaf_operand_b   <= operand_a +
				                    (ret_fmt_long ? 32'd12 : 32'd8);   // new A7: $2/$3 are twelve bytes
				eaf_alu_op      <= eac_alu_op;
				eaf_size       <= eac_size;
				eaf_shcnt      <= eac_shcnt;
				eaf_writes_an  <= an_wr_any;
				eaf_an_reg     <= an_wr_reg;
				eaf_an_data    <= an_wr_data;
				// NOT 1: RTE's A7 restore does NOT go through the normal
				// commit_reg/A7-bank path at all -- see ap040_execute.v's
				// header for the real race that forces this (RTE's own SR
				// restore commits the SAME cycle, and would otherwise bank
				// this very write through the NEW, just-restored S bit
				// instead of the OLD one). eaf_operand_b (the new A7 value,
				// still computed above) is instead consumed by
				// ap040_execute.v's exe_writes_creg path, writing directly
				// to ISP/MSP.
				eaf_writes_reg  <= 1'b0;
				eaf_writes_ccr  <= 1'b0;
				eaf_is_branch   <= 1'b0;
				eaf_is_scc      <= 1'b0;
				eaf_is_dbcc     <= 1'b0;
				eaf_is_jmp      <= 1'b0;
				eaf_is_rmw      <= 1'b0;
				eaf_is_link     <= 1'b0;
				eaf_is_pea      <= 1'b0;
				eaf_is_immsr    <= 1'b0;
				eaf_is_chk      <= 1'b0;
				eaf_is_trapcc      <= 1'b0;
				eaf_is_div      <= 1'b0;
				eaf_div_signed  <= 1'b0;
				eaf_is_bsr      <= 1'b0;
				eaf_is_jsr      <= 1'b0;
				eaf_is_trap     <= 1'b0;
				eaf_is_illegal  <= 1'b0;
				eaf_is_priv     <= 1'b0;
				eaf_is_addrerr  <= 1'b0;
				eaf_is_divzero  <= 1'b0;
				eaf_is_movesr   <= 1'b0;
				eaf_is_movec    <= 1'b0;
				eaf_is_rts      <= 1'b0;
				eaf_is_rte      <= 1'b1;
				eaf_is_fmterr  <= 1'b0;
				eaf_is_trace   <= 1'b0;
				// Popped SR, masked -- ap040_execute.v's new commit source
				// for restoring it (exe_writes_sr/exe_sr_data) -- see its
				// header for why this needs its own field rather than
				// reusing eaf_sr_snapshot (that one's a forwarded READ of
				// the CURRENT live SR, not the value being ADOPTED).
				eaf_rte_sr_data <= ret_dword0[31:16] & `AP040_SR_MASK;
				eaf_sr_snapshot <= sr_in;
				eaf_cond        <= eac_cond;
				ret_ph          <= RET_BEAT0;
				ret_pending     <= 1'b0;
			end else begin
				// A finishing MOVEM completes through this branch, which is
				// also where An gets written via an_wr_* -- so the sequencer
				// is retired here. Unconditional because it is already low
				// for every other instruction.
				mvm_active     <= 1'b0;
				eaf_valid      <= eac_valid;
				eaf_pc         <= eac_pc;
				if (eac_valid) begin   // a bubble departing here must not drop a pending trace
					trace_arm      <= traced_now;
					trace_arm_cond <= traced_cond;
					trace_pc       <= eac_pc;
				end
				eaf_next_pc    <= eac_next_pc;
				eaf_dest_reg   <= eac_dest_reg;
				// JMP/JSR: route the computed EA itself, not the register
				// value alone -- see header. BSR has no source read at all
				// (operand_a is simply unused for it), so it falls through
				// to the same default every register-direct instruction
				// already used.
				// LEA joins JMP/JSR here (milestone 42): its whole job is to
				// deliver the computed address as the operand, so ALU_MOVE
				// then writes it to An. This one line is the entire
				// datapath cost of the instruction.
				eaf_operand_a  <= (eac_is_jmp || eac_is_jsr || eac_is_lea) ? ea_target :
				                  eac_sxt_w                                ? sxt_w_of(operand_a) :
				                                                             operand_a;
				// BSR/JSR: the NEW A7 value (== push_addr, the same
				// expression already used for the write address) -- see
				// header for why the decrement happens HERE, once, rather
				// than being recomputed in ap040_execute.v.
				eaf_operand_b  <= (eac_is_bsr || eac_is_jsr || eac_is_pea) ? push_addr :
				                  eac_is_link                ? (push_addr + eac_imm) : operand_b;
				eaf_is_link    <= eac_is_link;
				eaf_is_pea     <= eac_is_pea;
				eaf_is_immsr   <= eac_is_immsr;
				eaf_is_chk     <= 1'b0;
				eaf_is_trapcc     <= 1'b0;
				eaf_immsr_to_sr<= eac_immsr_to_sr;
				eaf_alu_op     <= eac_alu_op;
				eaf_size       <= eac_size;
				eaf_shcnt      <= eac_shcnt;
				eaf_writes_an  <= an_wr_any;
				eaf_an_reg     <= an_wr_reg;
				eaf_an_data    <= an_wr_data;
				eaf_writes_reg <= eac_writes_reg;
				eaf_writes_ccr <= eac_writes_ccr;
				eaf_is_branch  <= eac_is_branch;
				eaf_is_scc     <= eac_is_scc;
				eaf_is_dbcc    <= eac_is_dbcc;
				eaf_is_jmp     <= eac_is_jmp;
				eaf_is_rmw     <= 1'b0;
				eaf_is_div     <= eac_is_div;
				eaf_div_signed <= eac_div_signed;
				eaf_is_bsr     <= eac_is_bsr;
				eaf_is_jsr     <= eac_is_jsr;
				eaf_is_trap    <= eac_is_trap;
				eaf_is_illegal <= eac_is_illegal;
				// This branch is only reached for a MOVE-to-SR/MOVEC
				// instruction when eac_is_priv is FALSE this cycle (any
				// privilege-violating one routes into exc_writing/
				// exc_vec_issue/exc_vec_done above instead, via exc_active)
				// -- so threading them straight through here is exactly the
				// "genuinely not faulting" case, no additional gating
				// needed.
				eaf_is_priv    <= 1'b0;
				// Same reasoning for an odd JMP/JSR target: only a
				// genuinely EVEN target ever reaches this plain redirect
				// path (eac_is_addrerr routes the odd case into
				// exc_writing/exc_vec_issue/exc_vec_done above instead).
				eaf_is_addrerr <= 1'b0;
				eaf_is_divzero <= 1'b0;
				eaf_is_movesr  <= eac_is_movesr;
				eaf_is_movec   <= eac_is_movec;
				eaf_movec_dir  <= eac_imm[3];
				eaf_movec_sel  <= eac_imm[2:0];
				// RTS/RTE never reach this branch (RTS routes through
				// mem_issue/mem_complete above, RTE through its own ret_ph
				// sequencer or the exception path) -- zeroed here purely for
				// the same "every field explicitly assigned in every branch"
				// discipline every other flag already follows.
				eaf_is_rts     <= 1'b0;
				eaf_is_rte     <= 1'b0;
				eaf_is_fmterr  <= 1'b0;
				eaf_is_trace   <= 1'b0;
				eaf_sr_snapshot<= sr_in;
				eaf_cond       <= eac_cond;
			end
		end
	end
end

endmodule
