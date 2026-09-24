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
	// A MOVEC to a stack pointer is in EX (milestone 92): its write lands
	// through the register file's auxiliary port, which no forward reaches.
	input             ex_creg_sp,
	input             ex_creg_any,
	// An OLDER instruction's write to A7 has not reached the register file
	// yet (milestone 93). The exception sequencer reads the stack pointer
	// straight out of the file, so its frame base is stale until this
	// clears -- and half a frame went to the old address and half to the
	// new one when it did not wait.
	input             a7_busy,
	// The vector base (milestone 117), and whether a control-register write
	// that could change it is still in EX or committing in WB.
	input      [31:0] vbr_in,
	input             creg_busy,
	input             flush,      // EX detected a misprediction: force a bubble

	input             eac_valid,
	input      [31:0] eac_pc,
	input      [31:0] eac_next_pc,
	input       [3:0] eac_dest_reg,
	input       [3:0] eac_src_reg,
	input      [31:0] eac_imm,
	input      [31:0] eac_ea_ext,
	input       [6:0] eac_mm,
	input       [2:0] eac_moves,
	input       [1:0] eac_mvfsr,
	input      [31:0] eac_pc_base,
	input       [2:0] eac_movep,
	input       [6:0] eac_ml,
	input       [4:0] eac_bf,
	input       [2:0] eac_ck2,
	input       [4:0] eac_cas,
	input       [3:0] eac_m16,
	input             eac_fp,       // the F-line (2026-09-24), see ap040_pipe_fpu.v
	input       [8:0] eac_fp_op,
	input      [15:0] eac_fp_cmd,
	input      [95:0] eac_fp_imm,
	input       [5:0] eac_fx,       // a full-format extension (2026-09-24), see below
	input      [31:0] eac_fx_bd,
	input      [31:0] eac_fx_od,
	input       [5:0] eac_alu_op,
	input       [1:0] eac_size,
	input       [5:0] eac_shcnt,
	input             eac_shift_reg,
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
	input             eac_immrmw,
	input             eac_st_disp,
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
	input             eac_chk_long,
	input             eac_is_immsr,
	input             eac_is_stop,
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
	input       [1:0] eac_illegal_kind,
	input             eac_is_movesr,
	input             eac_is_movec,
	input             eac_is_rts,
	input             eac_is_rte,
	input             eac_is_nop,
	input             eac_bnt,
	input             eac_is_rtr,
	input             eac_is_reset,
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
	output            l1_sup_b,
	output     [31:0] l1_addr_b,
	input        [31:0] l1_q_b,
	input               l1_rvalid_b,   // l1_q_b is the return for the last l1_rd_b (milestone 80)
	output              l1_rd_b,       // port-B read request: one in flight at a time
	output              l1_wren_b,
	output        [1:0] l1_size_b,
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
	// Which A7 that write means (milestone 92). An autoincrement through
	// A7 belongs to the instruction, and if the instruction FAULTS the
	// exception switches to supervisor before the write commits -- so a
	// bank taken from the SR at commit sends it to the supervisor stack,
	// on top of the frame pointer the exception just wrote there.
	output reg  [1:0] eaf_an_sel,
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
	output reg  [3:0] eaf_movec_sel,
	// The live SR AS OF THIS STAGE'S OWN cycle (already correctly EX-
	// forwarded/write-through resolved via sr_in) -- threaded straight
	// down to ap040_execute.v for its exception-entry SR-masking
	// arithmetic, rather than having it read sr_in live a second time one
	// cycle later, which would close a combinational loop through its own
	// EX-forward output -- see its header.
	output reg [15:0] eaf_sr_snapshot,
	output reg        eaf_is_rmw,
	output reg        eaf_is_mm,
	output reg        eaf_is_xm,    // ADDX/SUBX/ABCD/SBCD/CMPM to memory (milestone 117)
	output reg        eaf_bnt,      // a branch predicted not taken; eaf_operand_a is its target
	output reg  [1:0] eaf_mvfsr,
	output reg  [6:0] eaf_ml,
	output reg  [2:0] eaf_bf,       // bitfield: {it is one, N, Z} -- EX takes the flags from here
	output reg  [2:0] eaf_ck2,      // CMP2/CHK2: {it is one, Z, C}
	output reg  [4:0] eaf_casf,     // CAS: {it is one, N, Z, V, C} -- CMP's flags
	output reg  [5:0] eaf_rtr_ccr,  // RTR: {it is one, the popped X N Z V C}
	// MOVEM's third register write port -- see ap040_pipe_regfile.v.
	output            rf3_we,
	output      [3:0] rf3_addr,
	output     [31:0] rf3_data,
	output reg        eaf_is_div,
	output reg        eaf_div_signed,
	output reg        eaf_is_trapcc,
	output reg        eaf_is_chk,
	// A CHK that retired WITHOUT trapping, which still writes N and C.
	output reg        eaf_chk_ok,
	output reg        eaf_is_immsr,
	output reg        eaf_is_stop,
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
// LINK A7,#d: the register being saved is the stack pointer itself, which
// the push has already moved. eac_src_reg is An for a LINK; eac_dest_reg
// is A7 for every one of them, so this is the only way to tell.
wire        link_pushes_sp = (eac_src_reg == 4'd15);

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
// A MOVES byte load into An reads a byte and sign-extends it (milestone
// 114), the byte counterpart of eac_sxt_w.
wire        moves_sxb = eac_moves[1];
wire [1:0]  eff_size = eac_sxt_w ? `AP040_SZ_W : moves_sxb ? `AP040_SZ_B : eac_size;
wire [31:0] an_step  = (eff_size == `AP040_SZ_L) ? 32'd4 :
                       (eff_size == `AP040_SZ_W) ? 32'd2 :
                       an_is_a7                  ? 32'd2 : 32'd1;

// Indexed addressing (milestone 56). For mode 110 eac_imm is the brief
// extension word VERBATIM rather than a displacement, so it is unpacked
// here: [15] D/A and [14:12] the register number name Xn, [11] its size
// (a Word index is SIGN-extended, not truncated), [10:9] the scale, and
// [7:0] a signed BYTE displacement -- not the 16-bit one every other mode
// uses.
// The EA's extension value (milestone 112). For an operand-plus-EA form --
// eac_immrmw set -- eac_imm is the OPERAND and the EA's own word is
// eac_ea_ext; for everything else they are the same thing. A mux of two
// registers selected by a register, which is what milestone 88 permits on
// the address path, and it replaces the mask that sat here before.
wire [31:0] ea_ext   = eac_immrmw ? eac_ea_ext : eac_imm;
wire  [3:0] idx_reg  = {ea_ext[15], ea_ext[14:12]};
wire [31:0] idx_raw  = ea_ext[11] ? operand_c
                                   : {{16{operand_c[15]}}, operand_c[15:0]};
wire [31:0] idx_val  = idx_raw << ea_ext[10:9];
wire [31:0] idx_disp = {{24{ea_ext[7]}}, ea_ext[7:0]};

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
wire [31:0] ea_base = eac_ea_pcrel ? eac_pc_base : operand_a;   // opcode + 2 unless an immediate intervenes

// An immediate with a memory destination (milestone 89) carries its
// OPERAND in eac_imm, not a displacement, so there is nothing to add to
// the base. Masked at the adder's input rather than muxed at its output:
// this is the L1 address path, and an AND folds into the LUT that already
// feeds the carry chain where a fifth mux way would be another level after
// it. eac_immrmw is a register, which is what the milestone-88 rule
// requires of anything selecting on this path.

// ------------------------------------------------ full-format extension
// (2026-09-24; see ap040_decode.v) {valid, the MOVE destination's, BS, IS,
// post-indexed, memory indirect}, with the base and outer displacements.
// Without indirection the address is (BS ? 0 : base) + (IS ? 0 : index) +
// bd -- the brief formula with a wider displacement and two suppresses, all
// selected by registers. With it, a pointer is read first, from base + bd,
// plus the index for the pre-indexed forms, and the address is that pointer
// plus od, plus the index for the post-indexed ones (ap040_core.v's
// S_EA_BD/S_EA_MIND/S_EA_OD). The read is a pre-phase: the stage holds with
// bubbles through hold_hazard, so stall_self keeps every other access of
// the instruction off the memory and nothing in the output chain runs until
// the pointer is in; the intermediate address and the result are both
// latched, so no forward reaches the L1 address. The instruction's own
// exceptions wait for it too -- a JMP's odd-target test must see the
// resolved address -- but a trace owed by the one before goes first.
wire        fx       = eac_fx[5];
wire        fx_dst   = eac_fx[4];
wire        fx_bs    = eac_fx[3];
wire        fx_is    = eac_fx[2];
wire        fx_post  = eac_fx[1];
wire        fx_ind   = eac_fx[0];
wire        fx_src   = fx && !fx_dst;
localparam [1:0] FXI_ADDR = 2'd0, FXI_RD = 2'd1, FXI_W = 2'd2, FXI_DONE = 2'd3;
reg   [1:0] fxi_ph;
reg  [31:0] fxi_addr, fxi_ea;
wire        fx_hold   = eac_valid && fx && fx_ind && (fxi_ph != FXI_DONE);
wire        fx_hold_go = fx_hold && !trace_hold && !ae_busy;
wire        fxi_rd    = (fxi_ph == FXI_RD);
wire        fxi_ld_go = fx_hold_go && fxi_rd && live && !port_taken && !stall_in;
wire [31:0] fx_base_s = (fx_src && fx_bs) ? 32'd0 : ea_base;
wire [31:0] fx_idx_s  = (fx_src && fx_is) ? 32'd0 : idx_val;
wire [31:0] fx_disp_s = fx_src ? eac_fx_bd : idx_disp;
wire [31:0] ea_disp   = ea_ext;
wire [31:0] ea_target = eac_is_abs     ? ea_ext             :
                        eac_is_predec  ? (an_base - an_step) :
                        eac_ea_indexed ? ((fx_src && fx_ind) ? fxi_ea : (fx_base_s + fx_idx_s + fx_disp_s)) :
                                         (ea_base + ea_disp);

// The value An takes afterwards. Both modes leave An at the same place --
// just past the longword for (An)+, at the start of it for -(An) -- which is
// why one expression covers both.
wire [31:0] an_new = eac_is_postinc ? (an_base + an_step) :
                                      (an_base - an_step);

// MOVE memory-to-memory (milestone 114) -- see ap040_decode.v. The load is
// the ordinary one above; this is the destination, formed when it completes
// and handed to EX as eaf_ea_target for the read-modify-write store.
//
// The source's (An)+/-(An) happens FIRST: MOVE (A0)+,(A0) writes at the
// incremented A0, and an index register that is the source's An sees its
// new value. The destination (An)+/-(An) then writes its An through the
// main port. When that is the same register as the source's, both ports
// write it in the same retirement, and ap040_pipe_regfile.v's w_collide
// already gives the main port the register (and every read bypass checks
// it first) -- the right answer, since the destination's value contains the
// source's step. A drop of the second-port write was written here first and
// taken out: no bench or mutation could tell it was there.
wire        mm          = eac_mm[5];
wire        mm_simm     = eac_mm[4];
wire        mm_dpi      = eac_mm[3];
wire        mm_dpd      = eac_mm[2];
wire        mm_dabs     = eac_mm[1];
wire        mm_didx     = eac_mm[0];
wire  [3:0] mm_didx_reg = {eac_ea_ext[15], eac_ea_ext[14:12]};
wire        mm_dphase   = mm && (mem_pending || mm_simm);
wire        mm_src_upd  = eac_is_postinc || eac_is_predec;
wire        mm_same     = mm_src_upd && (eac_src_reg == eac_dest_reg);
wire [31:0] mm_base     = mm_same ? an_new : operand_b;
wire [31:0] mm_c        = (mm_src_upd && (mm_didx_reg == eac_src_reg)) ? an_new : operand_c;
wire [31:0] mm_idx_val  = (eac_ea_ext[11] ? mm_c : {{16{mm_c[15]}}, mm_c[15:0]}) << eac_ea_ext[10:9];
wire [31:0] mm_idx_disp = {{24{eac_ea_ext[7]}}, eac_ea_ext[7:0]};
// The destination's size is the move's, except PACK/UNPK -(Ax),-(Ay)
// (milestone 117): eac_size is the load's, a word for PACK and a byte for
// UNPK, and the store is the other one.
wire  [1:0] mm_dsz      = (eac_alu_op == `AP040_ALU_PACK) ? `AP040_SZ_B :
                          (eac_alu_op == `AP040_ALU_UNPK) ? `AP040_SZ_W : eac_size;
wire [31:0] mm_dstep    = (mm_dsz == `AP040_SZ_B) ? ((eac_dest_reg == 4'd15) ? 32'd2 : 32'd1) :
                          (mm_dsz == `AP040_SZ_W) ? 32'd2 : 32'd4;
wire [31:0] fx_base_d   = (fx_dst && fx_bs) ? 32'd0 : mm_base;
wire [31:0] fx_idx_d    = (fx_dst && fx_is) ? 32'd0 : mm_idx_val;
wire [31:0] fx_disp_d   = fx_dst ? eac_fx_bd : mm_idx_disp;
wire [31:0] mm_daddr    = mm_dabs ? eac_ea_ext :
                          mm_dpd  ? (mm_base - mm_dstep) :
                          mm_didx ? ((fx_dst && fx_ind) ? fxi_ea : (fx_base_d + fx_idx_d + fx_disp_d)) :
                                    (mm_base + eac_ea_ext);   // (An), (An)+: zero; (d16,An)
wire [31:0] mm_dan_new  = mm_dpi ? (mm_base + mm_dstep) : (mm_base - mm_dstep);

// The two-load forms (milestone 117; see ap040_decode.v). The first load
// is the ordinary one, from the source; when it completes the value is kept
// here and the stage holds, and the second goes out at mm_daddr through the
// same mem_issue path. That completion retires the instruction: operand A
// the source, B the destination, the result stored at mm_daddr. EX's
// register result, the destination An's new value, rides eaf_ea_target:
// for -(Ax) that is the store address itself, and CMPM stores nothing.
wire        xm      = eac_mm[6];
wire        xm_nost = xm && (eac_alu_op == `AP040_ALU_CMP);
reg         xm_have;
reg  [31:0] xm_src;
// The destination's address and An's new value, latched when the FIRST load
// issues. mm_daddr is the forwarded Ax through two adders; driven straight
// onto the L1 address for the second load it was all 40 of the worst paths
// at the perf-1 fit (-2.540 ns at 25 ns: ex_fwd_data -> an_new -> mm_base
// -> mm_daddr -> l1_addr_b), the M88 rule broken -- nothing from a forward
// on the L1 address path. Operand B is as valid at that issue as operand A,
// which the first load's own address already depends on.
reg  [31:0] xm_daddr;
reg  [31:0] xm_dan;

// Second write port selection (milestone 49). LINK writes An with the new
// top of stack, UNLK writes A7 with An+4 -- neither is an autoincrement,
// but both need exactly the port autoincrement already owns, and neither
// instruction autoincrements, so there is no contention. Hoisted here so
// every branch below assigns the same three wires instead of repeating a
// ternary that now has three cases.
// ...and not at all while a deferred address error owns the pipeline. The
// held instruction is not the faulting one -- a faulting (A7)+ still has to
// commit its own step, which is what milestone 92 is about -- so this is
// gated on ae_busy rather than on an exception being under way at all.
// Without it the ENTRY committed the suppressed instruction's address
// update: the exception branch latches eaf_writes_an <= an_wr_any &&
// own_exc, own_exc is true again by then, and gating store_now had already
// swung an_wr_reg from the destination An to eac_src_reg -- so MOVE.L
// D0,(A0)+ at an odd RTE target wrote $11223348 into D0.
// EXG writes Ry through this port with Rx's value (milestone 115).
wire        an_wr_any  = fp ? (eac_valid && fp_fin && fp_w2_en) :
                         (an_write || (eac_valid && (eac_is_link || eac_is_unlk || eac_is_exgop)) ||
                          (mvm_fin && mvm_wb)) && !ae_busy && !moves_priv;
wire  [3:0] an_wr_reg  = fp ? fp_w2_reg :
                         (eac_is_link || eac_is_movem || eac_is_exgop) ? eac_src_reg :
                         eac_is_unlk  ? 4'd15       :
                         store_now ? eac_dest_reg : eac_src_reg;
wire [31:0] an_wr_data = fp           ? fp_w2_val            :
                         eac_is_exgop ? operand_b            :
                         eac_is_link  ? push_addr            :
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
wire        mvm_base_self = mvm_down && (mvm_reg == eac_src_reg);
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
wire mvm_stall = eac_valid && eac_is_movem && !mvm_fin && !trace_hold && !ae_busy;

// ------------------------------------------------------------------ MOVEP
// Two or four single-byte accesses at (d16,Ay), +2, +4, +6 (milestone 115).
// A store takes Dx's bytes high first from port B, which decode pointed at
// Dx; a load shifts each byte into mvp_acc, and the instruction then leaves
// through the ordinary retire with mvp_acc as its operand, where EX's Word
// merge keeps Dx's upper half for MOVEP.W. One beat per cycle for a store
// the write buffer accepts, two for a load (address, then data), exactly
// as MOVEM's beats go.
reg         mvp_active;
reg   [2:0] mvp_left;       // beats still to go
reg  [31:0] mvp_addr;
reg  [31:0] mvp_acc;
reg         mvp_rd_pend;
wire        mvp        = eac_movep[2];
wire        mvp_long   = eac_movep[1];
wire        mvp_wr     = eac_movep[0];
wire  [7:0] mvp_byte   = (mvp_left == 3'd4) ? operand_b[31:24] :
                         (mvp_left == 3'd3) ? operand_b[23:16] :
                         (mvp_left == 3'd2) ? operand_b[15:8]  : operand_b[7:0];
wire        mvp_st_want = mvp_active &&  mvp_wr && (mvp_left != 3'd0) && !port_taken;
wire        mvp_st_go   = mvp_st_want && !l1_wr_busy;
wire        mvp_ld_go   = mvp_active && !mvp_wr && (mvp_left != 3'd0) && !mvp_rd_pend && !port_taken;
wire        mvp_fin     = mvp_active && (mvp_left == 3'd0) && !mvp_rd_pend;
wire        mvp_stall   = eac_valid && mvp && !mvp_fin && !trace_hold && !ae_busy;

// -------------------------------------------------------------- bitfields
// BFTST/BFEXTU/BFCHG/BFEXTS/BFCLR/BFFFO/BFSET/BFINS (milestone 116), staged
// the way ap040_core.v's S_BF_* are. The EA is latched on the first cycle,
// while port C still serves any index; the offset, the width and a
// register BFINS's source then come through port C one per cycle. A
// register operand is rotated so the field is left-aligned; a memory one is
// read as the one to five bytes that hold the field -- one access, and a
// trailing byte for a three- or five-byte span -- and shifted by the bit
// offset within the first byte. Four registered stages extract the field,
// form the new one, and place it back; a modifying op on memory then writes
// the same one or two accesses. The instruction leaves through the ordinary
// retire with its register result as operand A, and N/Z in eaf_bf, because
// a field's sign is bit w-1, not bit 31.
localparam [3:0] BF_EA = 4'd0, BF_OFF = 4'd1, BF_WID = 4'd2, BF_SRC = 4'd3,
                 BF_RD1 = 4'd4, BF_RD1W = 4'd5, BF_RD2 = 4'd6, BF_RD2W = 4'd7,
                 BF_S1 = 4'd8, BF_S2 = 4'd9, BF_S3 = 4'd10, BF_S4 = 4'd11,
                 BF_WR1 = 4'd12, BF_WR2 = 4'd13, BF_DONE = 4'd14;
reg         bf_active;
reg   [3:0] bf_ph;
reg  [31:0] bf_ea, bf_off, bf_du, bf_addr, bf_w1, bf_field, bf_ones, bf_res;
reg   [5:0] bf_w;
reg   [2:0] bf_bib, bf_span;
reg   [7:0] bf_w2;
reg  [39:0] bf_t40, bf_maskl;
reg         bf_n, bf_z;
wire        bfv     = eac_bf[4];
wire        bf_reg  = eac_bf[3];
wire  [2:0] bf_op   = eac_bf[2:0];
wire [15:0] bfx     = eac_ea_ext[15:0];
wire        bf_modop = (bf_op == 3'd2) || (bf_op == 3'd4) || (bf_op == 3'd6) || (bf_op == 3'd7);
wire        bf_fin  = bf_active && (bf_ph == BF_DONE);
wire        bf_stall = eac_valid && bfv && !bf_fin && !trace_hold && !ae_busy;
wire        bf_two   = (bf_span == 3'd3) || (bf_span == 3'd5);
wire  [1:0] bf_sz1   = (bf_span == 3'd1) ? `AP040_SZ_B : (bf_span <= 3'd3) ? `AP040_SZ_W : `AP040_SZ_L;
wire [31:0] bf_cur_addr = ((bf_ph == BF_RD2) || (bf_ph == BF_WR2))
                          ? (bf_addr + ((bf_span == 3'd3) ? 32'd2 : 32'd4)) : bf_addr;
wire  [1:0] bf_cur_sz   = ((bf_ph == BF_RD2) || (bf_ph == BF_WR2)) ? `AP040_SZ_B : bf_sz1;
wire [31:0] bf_wdata    = (bf_ph == BF_WR2) ? {24'd0, (bf_span == 3'd3) ? bf_w1[15:8] : bf_w2} :
                          (bf_span == 3'd1) ? {24'd0, bf_w1[31:24]} :
                          (bf_span <= 3'd3) ? {16'd0, bf_w1[31:16]} : bf_w1;
wire        bf_ld_go  = bf_active && ((bf_ph == BF_RD1) || (bf_ph == BF_RD2)) && !port_taken;
wire        bf_st_want = bf_active && ((bf_ph == BF_WR1) || (bf_ph == BF_WR2)) && !port_taken;
wire        bf_st_go  = bf_st_want && !l1_wr_busy;
wire  [3:0] bf_rc     = (bf_ph == BF_OFF) ? {1'b0, bfx[8:6]} :
                        (bf_ph == BF_WID) ? {1'b0, bfx[2:0]} : {1'b0, bfx[14:12]};
wire        bf_use_c  = bf_active && ((bf_ph == BF_OFF) || (bf_ph == BF_WID) || (bf_ph == BF_SRC));
// The stage-3 values, from ap040_core.v's bf_newf and S_BF_X3/M3.
wire [31:0] bf_nf     = (bf_op == 3'd2) ? ((~bf_field) & bf_ones) :
                        (bf_op == 3'd4) ? 32'd0 :
                        (bf_op == 3'd6) ? bf_ones : (bf_du & bf_ones);
wire [31:0] bf_al     = bf_t40[39:8] & bf_maskl[39:8];
wire  [5:0] bf_clz;
function [5:0] bf_clz32;
	input [31:0] v;
	integer k;
	begin
		bf_clz32 = 6'd32;
		for (k = 0; k < 32; k = k + 1)
			if (v[k]) bf_clz32 = 6'd31 - k[5:0];
	end
endfunction
assign bf_clz = bf_clz32(bf_al);
wire [39:0] bf_head   = ~(40'hFF_FFFF_FFFF >> bf_bib);
wire [39:0] bf_nw40   = ({bf_w1, bf_w2} & bf_head) | (bf_t40 >> bf_bib);

// -------------------------------------------------------------- CHK2/CMP2
// Two sized reads, the lower bound at ea and the upper at ea + size
// (milestone 117), then ap040_core.v's S_CHK2_D: everything sign-extended
// by size except an address register, which compares whole; out of bounds
// is judged the other way round when the bounds are reversed. Z and C are
// all it writes. A CHK2 out of bounds becomes CHK's own vector-6 entry
// through eac_is_chk_trap, with its Z and C in the stacked SR.
localparam [2:0] CK_RD1 = 3'd1, CK_RD1W = 3'd2, CK_RD2 = 3'd3, CK_RD2W = 3'd4, CK_DONE = 3'd5;
reg         ck_active;
reg   [2:0] ck_ph;
reg  [31:0] ck_ea, ck_lb;
reg         ck_z, ck_c;
wire        ck      = eac_ck2[2];
wire        ck_chk  = eac_ck2[1];
wire        ck_an   = eac_ck2[0];
function [31:0] ck_sx;
	input [31:0] v;
	input  [1:0] sz;
	begin
		ck_sx = (sz == `AP040_SZ_B) ? {{24{v[7]}}, v[7:0]} :
		        (sz == `AP040_SZ_W) ? {{16{v[15]}}, v[15:0]} : v;
	end
endfunction
wire [31:0] ck_step   = (eac_size == `AP040_SZ_B) ? 32'd1 : (eac_size == `AP040_SZ_W) ? 32'd2 : 32'd4;
wire [31:0] ck_addr   = (ck_ph == CK_RD2) ? (ck_ea + ck_step) : ck_ea;
wire        ck_ld_go  = ck_active && ((ck_ph == CK_RD1) || (ck_ph == CK_RD2)) && !port_taken;
wire        ck_fin    = ck_active && (ck_ph == CK_DONE);
wire        ck_stall  = eac_valid && ck && !ck_fin && !trace_hold && !ae_busy;
wire signed [31:0] ck_rn = ck_an ? operand_b : ck_sx(operand_b, eac_size);
wire signed [31:0] ck_lbs = ck_lb;
wire signed [31:0] ck_ubs = ck_sx(l1_q_b, eac_size);
wire        ck_oob    = (ck_lbs <= ck_ubs) ? ((ck_rn < ck_lbs) || (ck_rn > ck_ubs))
                                           : ((ck_rn < ck_lbs) && (ck_rn > ck_ubs));
wire        ck2_trap  = eac_valid && ck && ck_chk && ck_fin && ck_c;

// ---------------------------------------------------------------- MOVE16
// (milestone 117; see ap040_decode.v). Both lines aligned down to sixteen
// bytes and latched at the start, then four rounds of one longword read and
// one longword write. ap040_core.v reads all four before writing; two
// aligned lines are the same line or disjoint, so the order changes
// nothing. It retires through the ordinary branch: the source An's +16 on
// port 2, and for (Ax)+,(Ay)+ Ay's on the main port, through the
// eaf_is_xm register-result route. Ax = Ay makes the two writes the same
// value, and the main port wins -- the one +16 of ap040_core.v's S_M16_INC.
localparam M16_RD = 2'd0, M16_RDW = 2'd1, M16_WR = 2'd2, M16_DONE = 2'd3;
wire        m16       = eac_m16[3];
wire  [2:0] m16_form  = eac_m16[2:0];
wire        m16_pp    = m16 && (m16_form == 3'd4);
wire        m16_an_up = m16 && ((m16_form == 3'd0) || (m16_form == 3'd1) || m16_pp);
reg         m16_active;
reg   [1:0] m16_ph, m16_i;
reg  [31:0] m16_s, m16_d, m16_buf;
wire [31:0] m16_src_c = ((m16_form == 3'd1) || (m16_form == 3'd3)) ? eac_imm : operand_a;
wire [31:0] m16_dst_c = ((m16_form == 3'd0) || (m16_form == 3'd2)) ? eac_imm :
                        m16_pp ? operand_b : operand_a;
wire [31:0] m16_addr  = ((m16_ph == M16_WR) ? m16_d : m16_s) + {28'd0, m16_i, 2'b00};
wire        m16_ld_go   = m16_active && (m16_ph == M16_RD) && !port_taken;
wire        m16_st_want = m16_active && (m16_ph == M16_WR) && !port_taken;
wire        m16_st_go   = m16_st_want && !l1_wr_busy;
wire        m16_fin     = m16_active && (m16_ph == M16_DONE);
wire        m16_stall   = eac_valid && m16 && !m16_fin && !trace_hold && !ae_busy;

// ------------------------------------------------------------------- CAS
// (milestone 117) The load is an ordinary one; this is its completion.
// Du comes through port C once the load is out, the way a 64-bit divide's
// Dr does. CMP's flags are for <ea> - Dc at the operand size.
wire        cas     = eac_cas[3];
function [3:0] cas_cmp;   // {N, Z, V, C} of d - s at size sz
	input [31:0] d, s;
	input  [1:0] sz;
	reg   [32:0] r;
	reg          dm, sm, rm;
	begin
		r  = {1'b0, d} - {1'b0, s};
		case (sz)
		`AP040_SZ_B: begin
			r = {24'd0, {1'b0, d[7:0]} - {1'b0, s[7:0]}};
			dm = d[7];  sm = s[7];  rm = r[7];
			cas_cmp = {rm, (r[7:0] == 8'd0), (dm != sm) && (rm != dm), r[8]};
		end
		`AP040_SZ_W: begin
			r = {16'd0, {1'b0, d[15:0]} - {1'b0, s[15:0]}};
			dm = d[15]; sm = s[15]; rm = r[15];
			cas_cmp = {rm, (r[15:0] == 16'd0), (dm != sm) && (rm != dm), r[16]};
		end
		default: begin
			dm = d[31]; sm = s[31]; rm = r[31];
			cas_cmp = {rm, (r[31:0] == 32'd0), (dm != sm) && (rm != dm), r[32]};
		end
		endcase
	end
endfunction
wire  [3:0] cas_fl  = cas_cmp(mem_lane, operand_b, eac_size);
// The store goes where the load went. ea_target is not that address at
// completion for (d8,An,Xn): port C has moved from the index to Du, so
// idx_val is Du and the store landed at base + Du + d8. Latched at issue,
// the way bf_ea and ck_ea are.
reg  [31:0] cas_ea;
wire        cas_eq  = cas_fl[2];

// ------------------------------------------------------------------ CAS2
// (milestone 117) ap040_core.v's S_CAS2_*: both operands read, the first
// compared with Dc1 and -- only if equal -- the second with Dc2; the flags
// are the comparison that decided. Both equal: Du1 and Du2 stored. Either
// not: Dc1 and then Dc2 loaded, merged at the size, so with Dc1 = Dc2 the
// second wins. Six registers come through port C a phase at a time, as the
// bitfields' offset and width do. The loads go to Dc2 on the main port and
// Dc1 on port 2, and w_collide's main-port priority is that "second wins".
localparam C2_R1 = 4'd0, C2_R2 = 4'd1, C2_RD1 = 4'd2, C2_RD1W = 4'd3, C2_RD2 = 4'd4,
           C2_RD2W = 4'd5, C2_DC1 = 4'd6, C2_DC2 = 4'd7, C2_CMP = 4'd8, C2_DU1 = 4'd9,
           C2_DU2 = 4'd10, C2_WR1 = 4'd11, C2_WR2 = 4'd12, C2_DONE = 4'd13;
wire        cas2     = eac_cas[4];
wire [31:0] c2x      = eac_imm;      // {first word, second word}
reg         c2_active, c2_eq;
reg   [3:0] c2_ph, c2_fl;
reg  [31:0] c2_a1, c2_a2, c2_m1, c2_m2, c2_dc1, c2_dc2, c2_du1, c2_du2;
wire  [3:0] c2_rc    = (c2_ph == C2_R1)  ? c2x[31:28] :
                       (c2_ph == C2_R2)  ? c2x[15:12] :
                       (c2_ph == C2_DC1) ? {1'b0, c2x[18:16]} :
                       (c2_ph == C2_DC2) ? {1'b0, c2x[2:0]} :
                       (c2_ph == C2_DU1) ? {1'b0, c2x[24:22]} : {1'b0, c2x[8:6]};
wire        c2_use_c = c2_active && ((c2_ph == C2_R1) || (c2_ph == C2_R2) || (c2_ph == C2_DC1) ||
                                     (c2_ph == C2_DC2) || (c2_ph == C2_DU1) || (c2_ph == C2_DU2));
wire        c2_ld_go    = c2_active && ((c2_ph == C2_RD1) || (c2_ph == C2_RD2)) && !port_taken;
wire        c2_st_want  = c2_active && ((c2_ph == C2_WR1) || (c2_ph == C2_WR2)) && !port_taken;
wire        c2_st_go    = c2_st_want && !l1_wr_busy;
wire        c2_fin      = c2_active && (c2_ph == C2_DONE);
wire        c2_stall    = eac_valid && cas2 && !c2_fin && !trace_hold && !ae_busy;
wire [31:0] c2_addr     = ((c2_ph == C2_RD2) || (c2_ph == C2_WR2)) ? c2_a2 : c2_a1;
wire [31:0] c2_wdata    = (c2_ph == C2_WR2) ? c2_du2 : c2_du1;
wire  [3:0] c2_f1       = cas_cmp(c2_m1, c2_dc1, eac_size);
wire  [3:0] c2_f2       = cas_cmp(c2_m2, c2_dc2, eac_size);
wire [31:0] c2_dc1_new  = (eac_size == `AP040_SZ_W) ? {c2_dc1[31:16], c2_m1[15:0]} : c2_m1;

// ---------------------------------------------------------------- FPU
// The F-line coprocessor-1 instructions (2026-09-24): ap040_pipe_fpu.v,
// ap040_core.v's FPU states around the shared engine -- see its header.
// It starts once EX is empty, so every older instruction has retired or
// is committing and the register file (with its commit bypass) is the
// state; it holds the stage, emitting bubbles, until it finishes. Then the
// instruction retires through the default branch -- a result on the main
// port by EX's eaf_is_xm route, an (An) step on port 2 through an_wr_*, a
// taken FBcc/FDBcc as a JMP to fp_target -- or it is an exception like any
// other, with its own vector, format, PC and address fields.
//
// Port A is the sequencer's while it runs (Dn sources, FScc/FDBcc, the
// dynamic FMOVEM list), so the control-mode EA, which is built from port
// A's An, is latched as it starts.
wire        fp          = eac_fp;
wire        fp_active, fp_fin, fp_exc, fp_w1_en, fp_w2_en, fp_redirect, fp_t0, fp_bg;
wire  [7:0] fp_exc_vec;
wire  [1:0] fp_exc_fmt;
wire [31:0] fp_exc_pc, fp_exc_addr, fp_w1_val, fp_w2_val, fp_target;
wire  [3:0] fp_w1_reg, fp_w2_reg, fp_rreg;
wire        fp_mem_rd, fp_mem_wr;
wire [31:0] fp_mem_addr, fp_mem_wdata;
wire  [1:0] fp_mem_size;
reg  [31:0] fp_ea_r;
wire        fp_ld_go     = fp_mem_rd && !port_taken;
wire        fp_st_want   = fp_mem_wr && !port_taken;
wire        fp_st_go     = fp_st_want && !l1_wr_busy;
wire        fp_stall     = eac_valid && fp && !fp_fin && !trace_hold && !ae_busy;
wire        fp_start     = live && fp && !eaf_valid && !fp_active && !fp_fin && !fx_hold &&
                           !trace_hold && !ae_busy && !stall_in;
wire        eac_is_fpexc = eac_valid && fp && fp_fin && fp_exc;
wire        fp_clear     = flush || (fp_fin && !eaf_stall);

always @(posedge clk)
	if (!nreset)             fp_ea_r <= 32'd0;
	else if (ce && fp_start) fp_ea_r <= ea_target;

// The full-format pointer read (see its block above). ADDR latches the
// intermediate address once EX can take the instruction's operands as
// final; RD sends it; the data may come back whatever EX is doing. It
// starts over whenever the instruction leaves the stage.
wire [31:0] fxi_mid = fx_dst ? (fx_base_d + eac_fx_bd + (fx_post ? 32'd0 : fx_idx_d))
                             : (fx_base_s + eac_fx_bd + (fx_post ? 32'd0 : fx_idx_s));
wire [31:0] fxi_idx = fx_dst ? fx_idx_d : fx_idx_s;
always @(posedge clk) begin
	if (!nreset) begin
		fxi_ph   <= FXI_ADDR;
		fxi_addr <= 32'd0;
		fxi_ea   <= 32'd0;
	end else if (ce) begin
		if (flush || !eaf_stall) fxi_ph <= FXI_ADDR;
		else case (fxi_ph)
			FXI_ADDR: if (fx_hold_go && live && !stall_in) begin
				fxi_addr <= fxi_mid;
				fxi_ph   <= FXI_RD;
			end
			FXI_RD:   if (fxi_ld_go) fxi_ph <= FXI_W;
			FXI_W:    if (l1_rvalid_b) begin
				fxi_ea <= l1_q_b + eac_fx_od + (fx_post ? fxi_idx : 32'd0);
				fxi_ph <= FXI_DONE;
			end
			default: ;
		endcase
	end
end

ap040_pipe_fpu u_fpu (
	.clk       (clk),
	.nreset    (nreset),
	.ce        (ce),
	.start     (fp_start),
	.clear     (fp_clear),
	.op        (eac_fp_op),
	.cmd       (eac_fp_cmd),
	.imm       (eac_fp_imm),
	.pc_i      (eac_pc),
	.pc        (eac_next_pc),
	.ea_addr   (fp_ea_r),
	.sup       (sr_in[13]),
	.rreg      (fp_rreg),
	.rdata     (rdata_a),
	.mem_rd    (fp_mem_rd),
	.mem_wr    (fp_mem_wr),
	.mem_addr  (fp_mem_addr),
	.mem_size  (fp_mem_size),
	.mem_wdata (fp_mem_wdata),
	.mem_rd_ok (fp_ld_go && !stall_self),
	.mem_wr_ok (fp_st_go && !stall_self),
	.mem_rvalid(l1_rvalid_b),
	.mem_rdata (l1_q_b),
	.active    (fp_active),
	.fin       (fp_fin),
	.exc       (fp_exc),
	.exc_vec   (fp_exc_vec),
	.exc_fmt   (fp_exc_fmt),
	.exc_pc    (fp_exc_pc),
	.exc_addr  (fp_exc_addr),
	.w1_en     (fp_w1_en),
	.w1_reg    (fp_w1_reg),
	.w1_val    (fp_w1_val),
	.w2_en     (fp_w2_en),
	.w2_reg    (fp_w2_reg),
	.w2_val    (fp_w2_val),
	.redirect  (fp_redirect),
	.target    (fp_target),
	.t0_flow   (fp_t0),
	.bg_busy   (fp_bg)
);

assign rf3_we   = mvm_rd_pend && l1_rvalid_b;
assign rf3_addr = mvm_rd_reg;
// A Word load SIGN-EXTENDS into the whole register: MOVEM.W does not
// preserve the upper half, it replaces it with the sign. That is the one
// behaviour separating MOVEM.W's load from a pair of half-width writes.
assign rf3_data = mvm_word ? {{16{l1_q_b[15]}}, l1_q_b[15:0]} : l1_q_b;
wire        an_write = eac_valid && (eac_is_postinc || eac_is_predec);
// The bank the address-register write means, as of THIS instruction --
// before any exception it is about to take (milestone 92).
wire  [1:0] an_sp_sel = !sr_in[13] ? 2'd0 : (sr_in[12] ? 2'd2 : 2'd1);

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

// ...and every OTHER way this core changes the program counter (milestone
// 97). An instruction address must be even, and until now only the two
// that compute an ea_target were checked. The other four take their target
// from four different places:
//
//   BRA/Bcc/BSR  a displacement, which decode has already turned into a
//                redirect -- but the same sum is available here, because
//                eac_imm carries that displacement for every width and
//                eac_pc is the instruction's own address.
//   RTS          the longword just loaded, in mem_lane.
//   RTE          the frame's own PC field, assembled from the two pops.
//
// A conditional branch faults on an odd target whether or not it is TAKEN,
// which is why this does not consult the condition: the reference core's
// finish_bcc raises the error before it decides. This stage could not
// consult it anyway -- EX resolves branches.
// RTE's own two-beat sequencer state, declared here rather than beside the
// sequencer because the odd-target check below is now its first reader and
// this file keeps declarations ahead of use.
reg        ret_ph;
reg        ret_pending;   // this beat's read is in flight; l1_q_b valid NEXT cycle -- same shape as mem_pending
reg [31:0] ret_dword0;    // captured {SR, PC_hi} after beat 0 completes
localparam RET_BEAT0_E = 1'd0, RET_BEAT1_E = 1'd1;

wire [31:0] br_target    = eac_pc + 32'd2 + eac_imm;
// DBcc too: its target is the same sum, and like a conditional branch it
// faults on an odd one whether or not the loop is taken.
wire eac_is_br_odd   = (eac_is_branch || eac_is_bsr || eac_is_dbcc) && br_target[0];
// The popped return address, checked in the cycle it arrives.
wire eac_is_rts_odd  = eac_is_rts && mem_pending && l1_rvalid_b && mem_lane[0];
// RTE's, assembled from dword0's low half and dword1's high half.
wire [31:0] rte_pc_now = {ret_dword0[15:0], l1_q_b[31:16]};
// ...and only when the frame is one this core accepts. A format nibble it
// does not recognise is a FORMAT ERROR, vector 14 with a four-word frame,
// and that outranks the odd address the same frame happens to carry: the
// frame was never valid, so its PC field means nothing (milestone 98).
// The nibble is read here rather than through fmterr_now because that
// wire is built further down and this file keeps declarations ahead of use.
wire rte_fmt_now_ok  = (l1_q_b[15:12] == 4'h0) || (l1_q_b[15:12] == 4'h2) ||
                       (l1_q_b[15:12] == 4'h3);
// An RTE with an odd restored PC faults AFTER it has finished, not instead
// of finishing (milestone 100). It restores the status register and pops
// its frame first, so the error frame carries the RESTORED status register
// and sits below the popped one -- and a restored M bit chooses the stack
// it lands on. rtl/ap040/ap040_core.v says so in as many words.
//
// That makes it an exception OWED by a completed instruction, which is
// what the trace machinery below already is, so it is built the same way:
// armed as the RTE departs, held over the instruction behind it, and taken
// once EX and WB have drained -- by which time the restore has committed
// and the stage reads the state the frame needs.
wire rte_odd_now     = live && eac_is_rte && !eac_is_priv && !trace_hold &&
                       ret_pending && l1_rvalid_b && (ret_ph == RET_BEAT1_E) &&
                       (rte_fmt_now_ok || eac_is_rtr) && rte_pc_now[0];
reg        ae_arm;
reg        ae_susp;
reg [31:0] ae_pc_r;    // the RTE's own address, which the frame's PC field carries
reg [31:0] ae_tgt_r;   // the odd address it tried to return to
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
// !stall_in for the REGISTER source (milestone 95). A divide holds EX for
// thirty-two cycles and its forward shows an intermediate the whole time,
// so a fault judged on it is judged on a number the program never
// computes: 100/7 tripped divide-by-zero on the quotient it was still
// building. TRAPcc's detector has carried this guard since milestone 74.
// The MEMORY source keeps its own guard instead of gaining this one --
// mem_lane is the loaded value, settled whatever EX is doing, and
// mem_pending && l1_rvalid_b is true for exactly one cycle, so requiring
// !stall_in there would DROP the fault rather than delay it.
// A long divide's divisor is all 32 bits (milestone 115).
wire divzero_now = eac_valid && eac_is_div &&
                   (eac_is_mem_src ? (mem_pending && l1_rvalid_b) : !stall_in) &&
                   (eac_ml[6] ? (div_divisor == 32'd0) : (div_divisor[15:0] == 16'd0));

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
// CHK.L compares the full 32 bits (milestone 111). The word form's operands
// are the low halves, sign-extended by their own reads; the long form's are
// the registers themselves.
wire signed [31:0] chk_value_l = operand_b;
wire signed [31:0] chk_bound_l = chk_src;
wire chk_long     = eac_chk_long;
wire chk_negative = chk_long ? (chk_value_l < 32'sd0) : (chk_value < 16'sd0);
wire chk_over     = chk_long ? (chk_value_l > chk_bound_l) : (chk_value > chk_bound);
// The 68040's CHK flags (milestone 112), from ap040_core.v:2899, which the
// cputest reference measured on hardware. N always tracks the value's sign;
// C is cleared when the value is in bounds and, on a trap, set only for
// these sign combinations; Z, V and X are left alone. This core used to
// leave the CCR untouched on the in-bounds path and C untouched on a trap,
// which is every one of the CHK corpus rounds that disagreed.
wire chk_c = chk_long ? (((chk_value_l < 32'sd0) && (chk_bound_l >= 32'sd0)) ||
                         ((chk_bound_l >= 32'sd0) && (chk_value_l >= chk_bound_l)) ||
                         ((chk_value_l < 32'sd0) && (chk_bound_l < chk_value_l)))
                      : (((chk_value < 16'sd0) && (chk_bound >= 16'sd0)) ||
                         ((chk_bound >= 16'sd0) && (chk_value >= chk_bound)) ||
                         ((chk_value < 16'sd0) && (chk_bound < chk_value)));
// CHK decides its trap in this stage from the checked register, and the
// trap steers the whole output register through exc_active. With that
// register forwarded from EX, every one of the 40 worst paths of the
// perf-1b fit ran EX's shifter or ALU -> ex_fwd_data -> the bounds compare
// -> exc_active (-0.429 ns at 25 ns). So CHK waits out one bubble when
// the instruction in EX may write that register, judged on EX's registered
// destinations alone, and reads it from the register file's commit bypass
// the cycle after. CHK straight behind its value's producer is the only
// cost. CHK2 needs none: its compare is latched in ck_c and traps from
// registers.
wire chk_ex_writes  = eaf_valid && ((eaf_dest_reg == eac_dest_reg) ||
                                    (eaf_writes_an && (eaf_an_reg == eac_dest_reg)) ||
                                    (eaf_ml[6] && ({1'b0, eaf_ml[2:0]} == eac_dest_reg)));
wire chk_fwd_hazard = eac_valid && eac_is_chk && chk_ex_writes;
wire chk_now = eac_valid && eac_is_chk && !chk_fwd_hazard &&
               (eac_is_mem_src ? (mem_pending && l1_rvalid_b) : !stall_in) &&
               (chk_negative || chk_over);
reg exc_pend_chk;
reg exc_pend_chk_n;
reg exc_pend_chk_c;
wire eac_is_chk_trap = chk_now || exc_pend_chk || ck2_trap;

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

// RTS and RTE see their target for exactly ONE cycle -- the one their read
// returns in -- so the verdict has to be latched, the same way the divisor
// test and the CHK comparison already latch theirs (milestone 97). Without
// it exc_active fell again the next cycle, exc_stall let the instruction
// depart, and the frame push it had started was abandoned half-written.
// The TARGET is latched with it, for the same reason and to the same rule.
// `live` gates the whole thing (milestone 99). None of the five terms
// checks eac_valid on its own -- eac_is_jmp_odd is eac_is_jmp AND an
// address bit -- so whatever the stage held after a flush could re-arm the
// latch, and the next instruction to take ANY exception inherited the dead
// one's address. A TRAP then stacked the wrong return address, and
// returning from it would have run the TRAP again.
wire ae_hold         = eac_valid && ae_arm;
// ae_arm is the DETECTION window and it is too short to suppress anything
// with: it clears on ae_take, and the frame writes, the vector read and the
// redirect all happen after that. ae_susp is the whole window, from the odd
// RTE that arms the fault to the vector read that ends its entry, and it is
// what the held instruction's memory and side effects are gated on
// (milestone 109). It is deliberately NOT folded into own_exc: own_exc has
// to be TRUE when the deferred entry retires, because the exception branch
// latches eaf_is_addrerr <= eac_is_addrerr && own_exc.
//
// The gates below are the whole fix. A hold BRANCH beside the trace's own
// -- parking the instruction so it cannot retire -- was written first and
// then removed: with the requests and the address update gated, no mutation
// and none of the review's twenty-eight scenarios could tell whether it was
// there, for a store, a MOVEM, an ILLEGAL or a plain MOVEQ target alike.
wire ae_busy         = eac_valid && ae_susp;
wire ae_take         = ae_hold && !eaf_valid && !wb_busy && !stall_in;
wire addrerr_now     = (live && (eac_is_jmp_odd || eac_is_jsr_odd || eac_is_br_odd ||
                                 eac_is_rts_odd)) || ae_take || vecodd_pend;
// The second address error the first entry's own vector read produces. It
// cannot ride exc_pend_addrerr directly: that is qualified by exc_go, which
// clears on exc_vec_done, so it would never raise anything. This feeds
// addrerr_now instead, the same door ae_take uses.
reg        vecodd_pend;
reg [31:0] vecodd_pc_r, vecodd_tgt_r;
reg        exc_pend_addrerr;
reg [31:0] exc_pend_ae_target;
reg [31:0] exc_pend_ae_pc;
// The held verdict belongs to ONE instruction, and exc_go is what says
// which: it is set for the faulting instruction and clears when that
// instruction departs. Without that scope the flag outlived its owner --
// the handler's own first instruction inherited it and took the same
// address error a second time, with the same stale target, which a low
// clock enable made routine by stretching the window (milestone 97).
// addrerr_now covers the detection cycle itself, before exc_go is set.
wire eac_is_addrerr  = addrerr_now || (exc_pend_addrerr && exc_go);
// The target each of them referenced, which is what the format $2 frame's
// address field carries -- with bit 0 cleared, as the reference does.
wire [31:0] addrerr_live   = vecodd_pend    ? vecodd_tgt_r :
                             ae_take        ? ae_tgt_r  :
                             eac_is_br_odd  ? br_target :
                             eac_is_rts_odd ? mem_lane  : ea_target;
wire [31:0] addrerr_target = exc_pend_addrerr ? exc_pend_ae_target : addrerr_live;
// ...and the PC field the frame carries, which differs per source and is
// latched with the verdict for the same reason the target is.
wire [31:0] addrerr_pc_live = vecodd_pend    ? vecodd_pc_r :
                              ae_take        ? ae_pc_r :
                              eac_is_jmp_odd ? (eac_pc + (eac_ea_indexed ? 32'd6 : 32'd2)) :
                              eac_is_jsr_odd ? ea_target : eac_pc;
// The six-word frame (milestone 77): address error, and -- as on the 68040
// and in ap040_core.v's exc(..., 4'd2, pc, pc_i) -- CHK, TRAPcc and zero
// divide, whose extra longword is the faulting instruction's own address
// while the PC field stays the next instruction. TRAP, illegal, privilege
// and format error keep the four-word frame. Until milestone 77 the three
// dynamic ones pushed format $0; tb_ap040_pipe_integration4.v's handlers
// read the frames and said so.
wire eac_is_fmt2     = eac_is_addrerr || eac_is_divzero || eac_is_chk_trap ||
                       eac_is_trapcc_trap || eac_is_trace ||
                       (eac_is_fpexc && (fp_exc_fmt != 2'd0));
// Format $3, the FPU's post-instruction frame: format $2's shape, its own
// nibble, and only when the FPU's is the exception being taken.
wire eac_is_fmt3     = eac_is_fpexc && (fp_exc_fmt == 2'd3) && !eac_is_trace && !eac_is_addrerr;

// The L1 always returns a full longword on port B (address_b is the HIGH
// word, the low word implicitly address_b+1), so a sized load is a lane
// select rather than a narrower access. The value lands in the LOW bits
// because ap040_pipe_alu.v masks operand a by size (am = a & szmask) and
// ap040_execute.v splices the result back by size, so everything downstream
// already does the right thing once the right bits are here.
//
// A word takes the high half of the pair, which is the word the address
// names. A byte takes one half of that word, chosen by address bit 0.
// The port is sized and returns its value right-aligned at any alignment
// (milestone 86), so there is nothing left to select here. Every lane
// expression this stage used to carry -- and the assumption inside them
// that the bytes wanted were somewhere in one aligned longword, which a
// Long at an odd address disproves -- lives in ap040_pipe_l1.v and
// ap040_pipe_membus.v now.
wire [31:0] mem_raw = l1_q_b;

// The sign extension itself. Zero-extending a Word source instead is a
// silently wrong answer for every negative offset -- which is most of what
// SUBA is used for -- rather than a crash, so it gets its own check in
// tb_ap040_pipe_adda.v.
function [31:0] sxt_w_of;
	input [31:0] v;
	sxt_w_of = {{16{v[15]}}, v[15:0]};
endfunction

wire [31:0] mem_lane = eac_sxt_w ? sxt_w_of(mem_raw) :
                       moves_sxb ? {{24{mem_raw[7]}}, mem_raw[7:0]} : mem_raw;

// A register-count shift (milestone 87) reads its count through port A,
// which decode pointed at the count register -- so it forwards from EX and
// WB like any other source operand, with no new path. The 68040 takes the
// count modulo 64, which is the width of the field.
wire [5:0] shcnt_now = eac_shift_reg ? operand_a[5:0] : eac_shcnt;

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

// One cycle, and only for an instruction that actually reads A7. A MOVEC
// to the active stack pointer commits through the register file's
// auxiliary port, so a reader one instruction behind it reads the old
// value -- it is not lost, it is late, which is why two NOPs "fixed" it.
// Waiting puts the read in the commit cycle, where the auxiliary bypass
// answers it. MOVEC to a stack pointer is setup code, so the cost is
// nothing.
wire sp_read_a    = (raddr_a == 4'd15) || (raddr_b == 4'd15);
// The same one cycle for a control register READ (milestone 117). EX reads
// the registered copy (creg_read_value), and a MOVEC or an RTE's stack
// restore one instruction ahead commits it in WB, the cycle that reader
// spends in EX: MOVE A0,USP; MOVE USP,A1 read the old USP.
// An A7 write ahead of a USP/ISP/MSP read would be the same hazard, and is
// not listed because it cannot happen. Only MOVE USP,An is one word; it
// reads USP, runs in supervisor mode, and no supervisor A7 write lands in
// USP. MOVEC gathers, and decode's gather freezes with every stall, so it
// arrives at least two stages behind anything -- tried behind MOVEA, UNLK
// and a load held up by a store, and never closer.
wire movec_rd       = eac_is_movec && !eac_imm[4];
wire creg_rd_hazard = movec_rd && ex_creg_any;
wire creg_hazard  = live && ((ex_creg_sp && sp_read_a) || creg_rd_hazard);
wire hold_hazard    = creg_hazard || (live && chk_fwd_hazard) ||   // chk_fwd_hazard: see chk_now
                      (live && fx_hold_go);                        // a full-format pointer read

// A hazard has to stop the stage it is IN. eaf_stall tells the stages
// BEHIND this one to wait; on its own it left this instruction retiring,
// and re-issuing its memory request, once per cycle of the hazard
// (milestone 93). The register read self-corrected -- the last pass wrote
// the right answer over the earlier ones -- but a push ran twice and
// pushed twice. What it must NOT do is freeze this stage outright: the
// instruction in EX is the MOVEC, and holding EA-fetch's output register
// holds the MOVEC in EX for ever, which is a deadlock rather than a stall.
// The hazard emits a BUBBLE instead -- the branch below -- and stall_self
// keeps the held instruction's requests off the memory while it waits.
wire stall_self = stall_in || hold_hazard;

wire mem_issue    = live && eac_is_mem_src && !mem_pending && !port_taken && !trace_hold && !ae_busy &&
                    !moves_priv;
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
wire eac_is_push  = ((eac_is_bsr && !eac_is_br_odd) ||
                     (eac_is_jsr && !eac_is_jsr_odd) ||
                     eac_is_link || eac_is_pea) && !trace_hold && !ae_busy;
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
wire eac_is_priv_capable = eac_is_movesr || eac_is_movec || (eac_is_rte && !eac_is_rtr) || eac_moves[2] || eac_is_reset ||
                            (eac_mvfsr[1] && !eac_mvfsr[0]) ||
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
wire own_exc      = !trace_hold && !ae_hold;   // the held instruction's own faults are not taken

// T0, trace on change of flow (milestone 79). The arm is taken by the
// instructions the 68040 defines as changes of flow: taken branches and
// DBcc, BSR/JMP/JSR, RTS/RTE, and the non-branch
// ones that resynchronise the pipeline -- MOVE to SR, ORI/ANDI/EORI to SR,
// MOVEC to a control register, NOP, MOVES, CAS (ap040_core.v's t0_special,
// which cputest confirmed on hardware; MOVE An,USP and CINV/CPUSH/FSAVE are
// not decoded here). MOVES joined the list late: milestone 113 decoded it
// without it, and under T0 the instruction after it retired before the
// trace, the frame naming that later instruction (review 13). A conditional branch's taken-ness is only known in
// EX, so it arms provisionally (trace_arm_cond) and EX's verdict confirms or
// cancels the arm: EX resolves the cycle after the branch departs, and the
// hold on the next instruction outlasts that. T1 traces everything and
// T1T0 = 11 behaves as T1.
// STOP is not an ORI-to-SR for this purpose, though it rides that path
// everywhere else (milestone 110). ap040_core.v:6622's S_STOP_LD spells the
// rule out: T1 traces a STOP unconditionally, but T0 traces it only when
// the immediate CHANGES T1/T0/S/M or the interrupt mask -- WinUAE's
// MakeFromSR returns before its trace decision when none of those move, so
// "STOP SR-modification does not generate T0". Inheriting the blanket
// immediate-to-SR classification made STOP #$6715 with SR already $6715
// push a vector-9 frame and run the handler.
wire stop_t0_change = {eac_imm[15:12], eac_imm[10:8]} != {sr_in[15:12], sr_in[10:8]};
// A TRACED stop does not stop: it raises vector 9 and the handler runs,
// which is what ap040_core.v:6622 does before it ever reaches S_STOPPED.
// Named once so both retire sites share it -- and so a mutation can reach
// it, which two identical copies did not allow.
wire stop_takes_hold = eac_is_stop && !traced_now;
// PACK/UNPK Dx,Dy,#adj (milestone 113) are computed HERE, where Dx
// (operand_a) and the adjustment (eac_ea_ext) are both at hand, and leave as
// an ALU_MOVE of the finished byte or word. Operand B has to stay Dy: EX's
// alu_sized takes a Byte/Word result's upper bits from it.
wire eac_is_packop   = (eac_alu_op == `AP040_ALU_PACK) || (eac_alu_op == `AP040_ALU_UNPK);
// EXG and BTST Dn,#imm (milestone 115) leave here as ALU_MOVE and ALU_BTST.
wire eac_is_exgop    = (eac_alu_op == `AP040_ALU_EXG);
wire eac_is_btstr    = (eac_alu_op == `AP040_ALU_BTSTR);
// The memory form's source is the loaded value (milestone 117).
wire [31:0] pack_src = eac_is_mem_src ? mem_lane : operand_a;
wire [15:0] pack_sum = pack_src[15:0] + eac_ea_ext[15:0];
wire [15:0] unpk_sum = {4'd0, pack_src[7:4], 4'd0, pack_src[3:0]} + eac_ea_ext[15:0];
wire [31:0] pack_value = (eac_alu_op == `AP040_ALU_PACK) ? {24'd0, pack_sum[11:8], pack_sum[3:0]}
                                                         : {16'd0, unpk_sum};
wire t0_flow_static = eac_is_bsr || eac_is_jmp || eac_is_jsr || eac_is_rts || eac_is_rte ||
                      eac_is_movesr ||
                      (eac_is_immsr && eac_immsr_to_sr && !eac_is_stop) ||
                      (eac_is_stop && stop_t0_change) ||
                      (eac_is_movec && eac_imm[4]) || eac_is_nop || eac_moves[2] || eac_cas[3] ||
                      eac_cas[4] || (fp && fp_t0);
wire t0_flow_cond   = eac_is_branch || eac_is_dbcc;
wire traced_now     = sr_in[15] || (sr_in[14] && (t0_flow_static || t0_flow_cond));
wire traced_cond    = !sr_in[15] && sr_in[14] && t0_flow_cond && !t0_flow_static;
reg  trace_arm_cond;
// A held store is not a store: it selects nothing -- address, byte enables,
// data, stall, write enable -- while the trace entry's own beats go out.
// eac_is_store outranks exc_writing in l1_addr_word and st_be assumes the
// store's size, so without this the frame's beats went to the store's
// address with the store's lanes.
// MOVES and MOVE to/from SR are the first privileged instructions that
// touch memory (milestone 114), and a user-mode one must do nothing before
// its vector-8 entry: no load, no store, no address-register step. Every
// other privileged form reaches memory, if at all, through its own
// sequencer, so this is the whole of eac_is_priv.
wire moves_priv   = eac_is_priv;
wire store_now    = eac_is_store && !trace_hold && !ae_busy && !moves_priv;

// ae_take sits beside eac_is_trace and OUTSIDE own_exc for the same reason
// the trace does: both fire while the instruction behind the completed one
// is held, and own_exc exists precisely to keep THAT instruction's faults
// from being taken. The debt is the completed instruction's, not the held
// one's (milestone 100).
wire eac_is_exc    = eac_is_trace || ae_take ||
                     (own_exc && !fx_hold && (eac_is_trap || eac_is_illegal || eac_is_priv || eac_is_addrerr ||
                                  eac_is_divzero || eac_is_chk_trap || eac_is_trapcc_trap || eac_is_fmterr ||
                                  eac_is_fpexc));
wire exc_active    = live && eac_is_exc;
// The frame starts one cycle AFTER the fault is detected (milestone 88).
// exc_active is the fault cone: the CHK compare on a forwarded ALU result,
// the divisor test on loaded data, the privilege check on a forwarded S
// bit, the odd-target test on the EA adder. Until this milestone the
// frame's first beat went out in the detection cycle itself, so that whole
// cone sat on the L1 address mux -- and therefore on EVERY load's address
// path, exception or not: 5.7 ns of the 24.5 ns spine, measured at
// milestone 87. exc_go is the cone, registered. The sequencer's own
// signals key off it, so the address, size, write-enable and read strobe
// the L1 sees are all a register's worth away from the cone. The stall
// (exc_stall) and the retirement block (mem_complete) still use exc_active
// directly: the faulting instruction has to be held and not retired in the
// cycle it faults, and those two are not on the L1's path.
//
// The cost is one cycle per exception entry, spent in the wait branch
// below. The faulting instruction's eac_* are frozen by exc_stall and the
// data-derived faults are latched (exc_pend_*), so the verdict exc_go was
// set from is still standing when the beats go out.
reg  exc_go;
// The frame's shape, latched with the verdict. The first fit after exc_go
// found the format nibble still on the address path: a TRAPcc's condition
// reads the CCR forwarded from EX, that decides eac_is_fmt2, and that
// selects the frame size the beat address is computed from. The SELECT
// of the address mux had left the cone; its DATA had not.
reg  exc_fmt2_r;
reg  exc_fmt3_r;   // format $3 (the FPU), latched the same way
// The vector and the stack bank, latched the same way (second fit after
// exc_go). exc_vec_num is the fault-priority mux over the whole cone and
// {exc_vec_num, 00} is the vector read's ADDRESS; sr_in[12] is the M bit
// from the milestone-74 SR forward and selects the bank the frame's
// address is computed from. Latching the shape and leaving these two live
// left the cone on l1_addr_b through the vector -- the second fit's worst
// path went ALU -> sr_resolved_ea -> eac_is_trapcc_trap -> exc_vec_num ->
// l1_addr_b. With all three captured at the verdict, every exception
// address is a register, a register minus a constant, or a mux of those
// selected by a register.
reg  [7:0] exc_vec_r;
reg [31:0] exc_vbase_r;   // VBR, latched with the vector (milestone 117)
reg        exc_m_r;
reg [31:0] exc_sp_r;
wire exc_writing   = exc_go && !exc_vec_pending &&
                      (exc_ph == EXC_BEAT0 || exc_ph == EXC_BEAT1 ||
                       (exc_ph == EXC_BEAT2 && exc_fmt2_r));
// ...and not accepted at all if ap040_execute.v took the port this cycle:
// the core's mux drops this stage's wren_b, so the beat never reached the
// L1 and must be retried rather than counted.
wire exc_beat_ack  = exc_writing && !l1_wr_busy && !port_taken;
// ...and not while EX holds port B for a store (milestone 114). The
// bookkeeping below sits under the port_taken branch and records nothing
// that cycle, so an ungated request reached the L1 unrecorded and went out
// again the next cycle, a second read on top of the first. MOVEM's load and
// mem_issue already yielded; these two did not.
wire exc_vec_issue = exc_go && !exc_vec_pending && (exc_ph == EXC_VECRD) && !port_taken;
wire exc_vec_done  = exc_go && exc_vec_pending && l1_rvalid_b;
// An odd exception VECTOR (milestone 110). The handler address read out of
// the vector table must be even. The reference's rule, recorded in the plan
// since milestone 99 and blocked until milestone 108 gave this core a halt:
// an odd handler for vector 2 or 3 is a DOUBLE FAULT and halts; any other
// odd handler becomes an address error whose frame's PC field is 4 * vector
// WITHOUT the vector base register -- "offset, not vbr + offset" -- and
// whose address field is the handler with bit 0 cleared.
wire exc_vec_odd_now = exc_vec_done && l1_q_b[0];
wire exc_vec_dbl     = exc_vec_odd_now &&
                       ((exc_vec_r == 8'd2) || (exc_vec_r == 8'd3));
wire exc_stall     = exc_active && !exc_vec_done;
// ...and the frame cannot start until the base is trustworthy, which is
// what a7_busy says. exc_go simply does not latch before then, and
// exc_stall above already holds the instruction while it waits.

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

wire ret_active   = live && eac_is_rte_active;
// ...and not once the RTE has turned out to be an address error
// (milestone 97). A memory-source fault yields the same way -- mem_issue's
// own branch is guarded on exc_active -- because the sequencer that found
// the fault must stop, or it keeps re-reading underneath the frame push
// and the instruction never departs.
wire ret_issue    = ret_active && !ret_pending && !exc_active && !port_taken;   // see exc_vec_issue
wire ret_complete = ret_active && ret_pending && l1_rvalid_b;
wire ret_done     = ret_complete && (ret_ph == RET_BEAT1);
wire ret_stall    = ret_active && !ret_done;

// Every port-B read this stage makes, as the L1's request strobe. The four
// requesters are exclusive by construction (one instruction is never more
// than one of them), and each waits for l1_rvalid_b before it looks at l1_q_b
// (milestone 80): mem_complete, exc_vec_done, ret_complete, rf3_we.
// Requests and bookkeeping share one enable (milestone 92). Everything
// that records a request as having happened -- mem_pending for a read, the
// exception sequencer's phase, MOVEM's beat counter -- lives in the
// `!stall_in` block below, so a request asserted outside that window is one
// the memory accepts and nothing remembers. Behind a divide, one
// MOVE.L (A0),D1 issued thirty-four reads and one TRAP pushed its frame
// eighteen times. The earlier fix gated the ordinary store alone, which was
// the reported symptom rather than the defect.
assign l1_rd_b = fxi_ld_go || !stall_self &&
                 (mem_issue || exc_vec_issue || ret_issue || mvm_ld_go || mvp_ld_go || bf_ld_go || ck_ld_go ||
                  m16_ld_go || c2_ld_go || fp_ld_go);

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
assign fmterr_now = ret_done && !ret_fmt_ok && !eac_is_rtr;   // RTR's second word is not a format

// One cycle, and only for an instruction that actually reads A7. A MOVEC
// to the active stack pointer commits through the auxiliary port, so a
// reader one instruction behind it reads the register file's old value --
// it is not lost, it is late, which is why two NOPs "fixed" it. Waiting
// puts the read in the commit cycle, where the auxiliary bypass answers
// it. MOVEC to a stack pointer is setup code, so the cost is nothing.
assign eaf_stall = stall_in || hold_hazard || mem_issue || (mem_pending && !l1_rvalid_b) || wr_stall || exc_stall ||
                   ret_stall || port_taken || mvm_stall || mvp_stall || bf_stall || ck_stall || m16_stall ||
                   c2_stall || fp_stall ||
                   (eac_valid && xm && !xm_have) ||
                   (trace_hold && !exc_active);   // waiting for EX/WB to drain before the trace entry
assign raddr_a    = fp_active ? fp_rreg : mvm_st_want ? mvm_reg : eac_src_reg;
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
// ...and for a memory-to-memory MOVE, once its load is out, the
// DESTINATION's index register (milestone 114). The source's index is used
// at mem_issue and the destination's at mem_complete, never both at once,
// so one port serves an indexed-to-indexed MOVE. The select is mem_pending,
// a register, which is what the milestone-88 rule asks of this path.
// ...and for a 64-bit long divide, Dr, the dividend's high half (milestone
// 115): once any index has been used, or at once when there is none.
wire        ml_rd_dr  = eac_ml[6] && eac_ml[5] && eac_ml[3] && (eac_ml[2:0] != eac_dest_reg[2:0]);
// Three registers (milestone 117): two results and an (An)+/-(An) step.
// The step's value rides eaf_ea_target, which MULL/DIVL do not otherwise
// use -- they store nothing -- and ap040_execute.v writes it early.
wire        ml_an3    = eac_ml[6] && (eac_ml[5] || eac_ml[3]) && (eac_ml[2:0] != eac_dest_reg[2:0]) &&
                        (eac_is_postinc || eac_is_predec);
assign raddr_c    = (fx_hold && fx_dst) ? mm_didx_reg :   // a MOVE destination's pointer read
                    c2_use_c ? c2_rc :
                    mm_dphase ? mm_didx_reg :
                    bf_use_c  ? bf_rc :
                    (cas && mem_pending) ? {1'b0, eac_cas[2:0]} :
                    (ml_rd_dr && (!eac_is_mem_src || mem_pending)) ? {1'b0, eac_ml[2:0]} : idx_reg;
wire fwd_c_from_ex  = ex_fwd_valid  && (ex_fwd_dest  == raddr_c);
wire fwd_c_from_ex2 = ex_fwd2_valid && (ex_fwd2_dest == raddr_c);
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
// pointed at. The bank SELECT is exc_m_r, the M bit as it stood at the
// verdict (milestone 88): sr_in is the SR forward, so reading it live put
// EX's flag result on the frame's address. The pointers themselves are
// the committed isp_q/msp_q registers and are read live -- nothing
// retires during the sequence (exc_stall), so they cannot move.
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
// The exception's own bank, and the pointer it starts from. Two things
// make the second harder than reading a register (milestone 93).
//
// If the FAULTING instruction also updates A7 -- a (A7)+ operand that
// faulted -- the increment happens first architecturally, and the frame is
// pushed from where it leaves the pointer. When that update lands on the
// same stack the exception is about to use, the base is the UPDATED value;
// when it does not (a user-mode (A7)+ faulting onto the supervisor stack)
// the two are separate registers and the base is the bank's own.
// Selected on the LIVE M bit, not the latched one: this wire is what gets
// latched, in the same cycle exc_m_r does, so reading exc_m_r here reads
// the value from the PREVIOUS exception. A TRAP taken with M set then
// built its frame from ISP and left MSP alone.
wire  [1:0] exc_bank_sel   = sr_in[12] ? 2'd2 : 2'd1;   // S is 1 by construction here
// ...and own_exc, because a TRACE entry belongs to the instruction that
// just finished, not to the one held behind it (milestone 95). That held
// instruction has executed nothing, so its A7 update must not move the
// frame: a held MOVE.L (A7)+ moved it four bytes, which is exactly the
// step it had not taken.
wire        exc_a7_self    = own_exc && an_wr_any && (an_wr_reg == 4'd15) &&
                             (an_sp_sel == exc_bank_sel);
wire [31:0] exc_sp_live    = exc_a7_self ? an_wr_data
                                         : (sr_in[12] ? msp_in : isp_in);
// ...and it is RESOLVED ONCE, with the verdict, not re-read per beat. The
// register file is not still while the frame is being written: an older
// instruction that writes A7 commits between one beat and the next, and
// the two halves of the frame landed 512 bytes apart.
wire [31:0] exc_sp_bank    = exc_sp_r;
// Both sizes, subtracted in parallel, and the format picks one (milestone
// 81). Written as `bank - (fmt2 ? 12 : 8)` the format select drives an
// ADDER, and that adder is the last thing before the L1 address: the fit
// after milestone 81 put the worst path through mem_raw -> divzero_now ->
// eac_is_fmt2 -> this subtract -> l1_addr_b. Now it drives a mux, and the
// two subtracts of a constant sit off the path.
wire [31:0] exc_sp_fmt0    = exc_sp_bank - 32'd8;
wire [31:0] exc_sp_fmt2    = exc_sp_bank - 32'd12;
wire [31:0] exc_new_sp     = exc_fmt2_r ? exc_sp_fmt2 : exc_sp_fmt0;
// The status register as of the fault, with the flag effects the fault
// ITSELF has, resolved once (milestone 95). It used to be built here for
// the stacked word alone, so the frame said one thing and the handler's
// own SR another: a CHK on a negative operand stacked N set and entered
// its handler with N clear. Everything that needs the faulting SR reads
// this, including the snapshot EX turns into the entry SR.
//
// CHK sets N from the comparison, and a divide by zero clears C while
// leaving X/N/Z/V alone -- both are what rtl/ap040/ap040_core.v does, and
// it is the core that passes the corpus.
//
// ...but only when that fault is the one being TAKEN (review 12, finding
// 1). A deferred address error -- behind an odd RTE, or an odd exception
// vector -- outranks both, and the instruction it holds never executes;
// its CHK or zero divide still asserted, and the address-error frame
// stacked C cleared by a divide that was never allowed to run. The trace
// already had this exclusion. eac_is_addrerr stays true for the whole
// entry (exc_pend_addrerr && exc_go), so the choice holds while the frame
// is written.
wire [15:0] sr_faulted     = (ck2_trap && !eac_is_trace && !eac_is_addrerr)
                              ? {sr_in[15:3], ck_z, sr_in[1], ck_c} :
                             (eac_is_chk_trap && !eac_is_trace && !eac_is_addrerr)
                              ? {sr_in[15:4],
                                 (exc_pend_chk ? exc_pend_chk_n : chk_negative), sr_in[2:1],
                                 (exc_pend_chk ? exc_pend_chk_c : chk_c)}
                              : (eac_is_divzero && !eac_is_trace && !eac_is_addrerr)
                              ? {sr_in[15:1], 1'b0}
                              : sr_in;
wire [15:0] exc_sr_word    = sr_faulted;
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
// An address error's PC field differs per source -- an indexed JMP reads
// two words further on than any other mode, a JSR reads its own target,
// an armed RTE reads the RTE's address -- so it is built once in
// addrerr_pc_live above and latched with the verdict (milestone 100).
wire [31:0] exc_pc_field   = eac_is_trace   ? eac_pc :   // the instruction the trace handler returns to
                              eac_is_addrerr ? (exc_pend_addrerr ? exc_pend_ae_pc
                                                                 : addrerr_pc_live) :
                              eac_is_fpexc   ? fp_exc_pc :   // registers of ap040_pipe_fpu.v
                              (eac_is_illegal || eac_is_priv || eac_is_fmterr) ? eac_pc
                                                                               : eac_next_pc;
// The address error is tested BEFORE illegal and privilege, which is the
// order exc_pc_field above has always used. With it the other way round a
// deferred RTE fault started an entry and then took its VECTOR from the
// held instruction it had just suppressed: an ILLEGAL at the odd target
// stacked vector 4, and a privileged opcode after a return to user mode
// stacked vector 8, both with the address error's own PC and address
// fields. rte_odd_now already excludes eac_is_priv, so no instruction can
// legitimately be both (milestone 109).
wire  [7:0] exc_vec_num    = eac_is_trace ? 8'd9 :
                              eac_is_addrerr ? 8'd3 :
                              eac_is_fpexc   ? fp_exc_vec :
                              // 10 A-line, 11 F-line, 4 illegal -- literals
                              // like every other vector in this mux, because
                              // AP040_VEC_* lives in rtl/ap040's defs and the
                              // bench build does not include that directory.
                              // Privilege outranks illegal: a user-mode MOVEC with
                              // an invalid selector is both, and the 68040 raises
                              // vector 8 (milestone 113). Nothing else is both.
                              eac_is_priv ? 8'd8 :
                              eac_is_illegal ? (eac_illegal_kind == 2'd1 ? 8'd10 :
                                                eac_illegal_kind == 2'd2 ? 8'd11 :
                                                                           8'd4) :
                              eac_is_divzero ? 8'd5 :
                              eac_is_chk_trap ? 8'd6 :
                              eac_is_trapcc_trap ? 8'd7 :
                              eac_is_fmterr ? 8'd14 : eac_imm[7:0];
wire [15:0] exc_vecoff_word = {exc_fmt3_r ? 4'd3 : exc_fmt2_r ? 4'd2 : 4'd0, 2'b00, exc_vec_r, 2'b00};
// Format $2's own extra "instruction address" longword. For an odd JMP/JSR
// target it is the target itself, LSB cleared (ap040_core.v's own convention
// for this field, identical for JMP and JSR despite their differing PC
// fields above); for CHK, TRAPcc and zero divide it is the faulting
// instruction's own address (ap040_core.v passes pc_i), which is what a
// handler needs to find the instruction its PC field has already stepped past.
wire [31:0] exc_addr_field = eac_is_trace   ? trace_pc :
                             eac_is_addrerr ? {addrerr_target[31:1], 1'b0} :
                             eac_is_fpexc   ? fp_exc_addr : eac_pc;

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
// VBR + 4 * vector (milestone 117). Until then this read 4 * vector and
// ignored VBR altogether: every handler came from the table at 0, wherever
// a MOVEC had put the base. Both terms are registers latched at the verdict
// -- the milestone-88 rule, nothing combinational on the L1 address path.
wire [31:0] exc_vec_addr = exc_vbase_r + {22'd0, exc_vec_r, 2'b00};

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
wire [31:0] l1_addr_word = fxi_rd       ? fxi_addr     :
                            fp_active    ? fp_mem_addr  :
                            mvm_active   ? mvm_cur_addr :
                            mvp_active   ? mvp_addr     :
                            bf_active    ? bf_cur_addr  :
                            m16_active   ? m16_addr     :
                            c2_active    ? c2_addr      :
                            // ...but not once finished: a CHK2 out of bounds takes its
                            // exception with the sequencer still up, and the frame
                            // beats below must win the port (milestone 117).
                            (ck_active && !ck_fin) ? ck_addr :
                            // A store with a displacement takes the LOAD's
                            // adder instead of one of its own (milestone
                            // 91): decode points eac_src_reg at An for
                            // that form, so operand_a is already the base
                            // and ea_target is already base + eac_imm.
                            // The whole cost here is one registered term
                            // on a select that existed anyway -- an adder
                            // on this branch cost 0.97 ns, and an adder
                            // shared by way of a mux on ea_base cost 0.65.
                            (store_now && !eac_st_disp)
                                      ? (eac_is_abs    ? eac_imm :
                                         eac_is_predec ? (an_base - an_step)
                                                       : an_base) :
                            eac_is_push  ? push_addr :
                            exc_writing ? exc_beat_addr :
                            (exc_vec_issue || exc_vec_pending) ? exc_vec_addr :
                            ret_active  ? ret_addr :
                            xm_have     ? xm_daddr :
                                                                  ea_target;
assign l1_addr_b = l1_addr_word;   // the byte address itself (milestone 81)
// !stall_in (milestone 92): the request is combinational off eac_valid and
// says nothing about whether this instruction has already had its turn,
// which is right while its OWN wr_stall holds it -- the buffer is full, so
// nothing was accepted and the request must stay up -- and wrong while
// anything else does. Behind a divide, EX holds EA-fetch for thirty-two
// cycles and the buffer drains and accepts again in each of them: one
// MOVE.L D0,(A0) was posted eighteen times. The value is the same every
// time, so RAM ends up correct and only a count can see it; a device
// register does not work that way. The frame and MOVEM beats below carry
// their own sequencer, which advances per accepted beat, so they post once
// each without needing this.
assign l1_wren_b = !stall_self &&
                   ((live && (eac_is_push || store_now)) || exc_writing || mvm_st_want || mvp_st_want ||
                    bf_st_want || m16_st_want || c2_st_want || fp_st_want);
// The privilege this access carries (milestone 92). An exception's frame
// writes and vector read are SUPERVISOR accesses whatever mode the faulting
// instruction ran in, and the switch to supervisor has not committed while
// they are happening -- so it cannot be read off the status register at the
// far end of the bridge.
assign l1_sup_b = sr_in[13] || exc_writing || exc_vec_issue || exc_vec_pending;
// The size of whatever access l1_addr_word above selected, in the same
// priority order (milestone 86). Everything that is not a sized store or a
// sized load -- pushes, exception frame beats, the vector fetch, RTE's pops
// -- is a Longword.
assign l1_size_b = fxi_rd       ? `AP040_SZ_L :
                   fp_active    ? fp_mem_size :
                   mvm_active   ? (mvm_word ? `AP040_SZ_W : `AP040_SZ_L) :
                   mvp_active   ? `AP040_SZ_B :
                   bf_active    ? bf_cur_sz :
                   m16_active   ? `AP040_SZ_L :
                   c2_active    ? eac_size :
                   (ck_active && !ck_fin) ? eac_size :
                   store_now    ? eac_size :
                   eac_is_push  ? `AP040_SZ_L :
                   exc_writing  ? `AP040_SZ_L :
                   (exc_vec_issue || exc_vec_pending) ? `AP040_SZ_L :
                   ret_active   ? `AP040_SZ_L :
                                  eff_size;
// operand_a is port A, which mvm_st_want has pointed at the register this
// beat stores -- so the same wire that carries a LINK's pushed An carries
// each MOVEM register in turn.
// Three different things ride the same push: BSR pushes a return address,
// LINK pushes the old An, and PEA pushes the effective address itself.
// Right-aligned, by size -- so a MOVEM word beat and a sized store are the
// same expression now.
// A predecrement MOVEM whose list contains the BASE register stores that
// register's initial value MINUS one operation size on the 68020 through
// 68040 -- the 68000 and 68010 store it undecremented, and
// rtl/ap040/ap040_core.v, which passes the cputest corpus, follows the
// later rule. An is not written back until the sequence finishes, so
// operand_a is still the initial value when this beat goes out.
assign l1_data_b = fp_st_want   ? fp_mem_wdata :
                   mvp_st_want  ? {24'd0, mvp_byte} :
                   m16_st_want  ? m16_buf :
                   c2_st_want   ? c2_wdata :
                   bf_st_want   ? bf_wdata :
                   mvm_st_want  ? (mvm_base_self ? (operand_a - mvm_step)
                                                 : operand_a) :
                   exc_writing  ? exc_wdata :
                   store_now    ? (eac_st_disp ? operand_b : eac_moves[0] ? an_new : operand_a) :
                   eac_is_pea   ? ea_target :
                   // LINK An,#d decrements the stack pointer BEFORE it
                   // pushes An, so when An IS A7 the value that reaches
                   // memory is the decremented one -- push_addr, the same
                   // expression the write address already uses. For any
                   // other An the two differ and the register's own value
                   // is what gets saved (milestone 95).
                   eac_is_link  ? (link_pushes_sp ? push_addr : operand_a)
                                : eac_next_pc;

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
		eaf_an_sel     <= 2'd0;
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
		eaf_movec_sel  <= 4'h0;
		eaf_sr_snapshot<= 16'h0;
		eaf_is_rmw     <= 1'b0;
		eaf_is_mm      <= 1'b0;
		eaf_is_xm      <= 1'b0;
		eaf_bnt        <= 1'b0;
		xm_have        <= 1'b0;
		xm_src         <= 32'h0;
		xm_daddr       <= 32'h0;
		xm_dan         <= 32'h0;
		eaf_mvfsr      <= 2'd0;
		eaf_ml         <= 7'd0;
		eaf_is_div     <= 1'b0;
		eaf_div_signed <= 1'b0;
		eaf_is_chk     <= 1'b0;
		eaf_chk_ok     <= 1'b0;
		eaf_is_trapcc     <= 1'b0;
		eaf_is_immsr   <= 1'b0;
		eaf_is_stop    <= 1'b0;
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
		mvp_active     <= 1'b0;
		mvp_left       <= 3'd0;
		mvp_addr       <= 32'h0;
		mvp_acc        <= 32'h0;
		mvp_rd_pend    <= 1'b0;
		bf_active      <= 1'b0;
		bf_ph          <= BF_EA;
		bf_ea          <= 32'h0;
		bf_off         <= 32'h0;
		bf_du          <= 32'h0;
		bf_addr        <= 32'h0;
		bf_w1          <= 32'h0;
		bf_w2          <= 8'h0;
		bf_field       <= 32'h0;
		bf_ones        <= 32'h0;
		bf_res         <= 32'h0;
		bf_w           <= 6'd0;
		bf_bib         <= 3'd0;
		bf_span        <= 3'd0;
		bf_t40         <= 40'h0;
		bf_maskl       <= 40'h0;
		bf_n           <= 1'b0;
		bf_z           <= 1'b0;
		eaf_bf         <= 3'd0;
		ck_active      <= 1'b0;
		m16_active     <= 1'b0;
		c2_active      <= 1'b0;
		c2_eq          <= 1'b0;
		c2_ph          <= C2_R1;
		c2_fl          <= 4'd0;
		c2_a1          <= 32'h0;
		c2_a2          <= 32'h0;
		c2_m1          <= 32'h0;
		c2_m2          <= 32'h0;
		c2_dc1         <= 32'h0;
		c2_dc2         <= 32'h0;
		c2_du1         <= 32'h0;
		c2_du2         <= 32'h0;
		m16_ph         <= M16_RD;
		m16_i          <= 2'd0;
		m16_s          <= 32'h0;
		m16_d          <= 32'h0;
		m16_buf        <= 32'h0;
		ck_ph          <= CK_RD1;
		ck_ea          <= 32'h0;
		cas_ea         <= 32'h0;
		ck_lb          <= 32'h0;
		ck_z           <= 1'b0;
		ck_c           <= 1'b0;
		eaf_ck2        <= 3'd0;
		eaf_casf       <= 5'd0;
		eaf_rtr_ccr    <= 6'd0;
		mvm_mask       <= 16'h0;
		mvm_addr       <= 32'h0;
		mvm_dir        <= 1'b0;
		mvm_word       <= 1'b0;
		mvm_down       <= 1'b0;
		mvm_wb         <= 1'b0;
		mvm_rd_pend    <= 1'b0;
		mvm_rd_reg     <= 4'h0;
		exc_pend_divzero <= 1'b0;
		exc_pend_addrerr <= 1'b0;
		exc_pend_ae_target <= 32'd0;
		exc_pend_ae_pc     <= 32'd0;
		ae_arm             <= 1'b0;
		ae_susp            <= 1'b0;
		vecodd_pend        <= 1'b0;
		vecodd_pc_r        <= 32'h0;
		vecodd_tgt_r       <= 32'h0;
		ae_pc_r            <= 32'd0;
		ae_tgt_r           <= 32'd0;
		exc_pend_chk     <= 1'b0;
		exc_pend_chk_n   <= 1'b0;
		exc_pend_chk_c   <= 1'b0;
		exc_pend_trapcc  <= 1'b0;
		exc_pend_fmterr  <= 1'b0;
		exc_pend_trace   <= 1'b0;
		trace_arm        <= 1'b0;
		trace_arm_cond   <= 1'b0;
		trace_pc         <= 32'h0;
		exc_ph          <= EXC_BEAT0;
		exc_vec_pending <= 1'b0;
		exc_go          <= 1'b0;
		exc_fmt2_r      <= 1'b0;
		exc_fmt3_r      <= 1'b0;
		exc_vec_r       <= 8'd0;
		exc_vbase_r     <= 32'd0;
		exc_m_r         <= 1'b0;
		exc_sp_r        <= 32'd0;
		ret_ph          <= RET_BEAT0;
		ret_pending     <= 1'b0;
	end else if (ce) begin
		// The registered fault verdict (milestone 88). It clears with the
		// departure it belongs to -- exc_vec_done under the same !stall_in
		// the output chain runs under, so a stalled departure does not
		// lose it -- or with a flush, which kills the instruction it was
		// set for.
		if (flush || (exc_vec_done && !stall_in)) exc_go <= 1'b0;
		else if (exc_active && !a7_busy && !creg_busy) begin
			exc_go <= 1'b1;
			if (!exc_go) begin   // fixed at the verdict, not re-read per beat
				exc_fmt2_r <= eac_is_fmt2;
				exc_fmt3_r <= eac_is_fmt3;
				exc_vec_r  <= exc_vec_num;
				exc_vbase_r <= vbr_in;   // creg_busy: no MOVEC to VBR still in flight
				exc_m_r    <= sr_in[12];
				exc_sp_r   <= exc_sp_live;
			end
		end

		// Each of these holds a fault's verdict from the cycle it was seen
		// until the exception has fetched its vector. Two things they all
		// need, and did not have (milestone 97):
		//
		// They clear on the SAME condition exc_go does, exc_vec_done with
		// the departure actually happening. Clearing on exc_vec_done alone
		// dropped the verdict a cycle early, and if the departure was then
		// delayed -- which a low clock enable does -- a LEVEL condition
		// like an odd JMP target re-armed it and the instruction took its
		// exception a second time, twelve more bytes of frame each time.
		//
		// And they arm only while exc_go is still low, so one instruction
		// latches one verdict however long it is held. Conditions that are
		// true for a single cycle, like a memory operand's, never needed
		// that; the ones that stay true for as long as the operand does
		// always did.
		if (exc_vec_done && !stall_in)   exc_pend_divzero <= 1'b0;
		else if (divzero_now && !exc_go) exc_pend_divzero <= 1'b1;

		// Armed as the RTE departs. NOT cleared by a flush -- the RTE's own
		// redirect is one, and the debt survives it exactly as the trace
		// arm does -- and cleared the moment the exception is TAKEN: from
		// then exc_pend_addrerr carries it, and leaving the arm up would
		// hold every instruction behind it for ever.
		if (ae_take) ae_arm <= 1'b0;
		else if (rte_odd_now) begin
			ae_arm   <= 1'b1;
			ae_pc_r  <= eac_pc;
			ae_tgt_r <= rte_pc_now;
		end

		if (exc_vec_done && !stall_in)   exc_pend_addrerr <= 1'b0;
		else if (addrerr_now && !exc_go) begin
			exc_pend_addrerr   <= 1'b1;
			exc_pend_ae_target <= addrerr_live;
			exc_pend_ae_pc     <= addrerr_pc_live;
		end

		// Cleared where exc_pend_addrerr is, because that is when the entry
		// this window exists for has finished reading its vector.
		// An odd exception VECTOR opens the same window (milestone 113): the
		// handler's first instruction carries the secondary address error
		// exactly as the instruction behind an odd RTE carries its deferred
		// one, and without the gates its store, load, push or MOVEM ran --
		// a store to $800 redirected all three secondary frame beats there.
		// It is armed on the vector read that turns out odd, which is also
		// an exc_vec_done, so it outranks the clear; the window then lasts
		// to the SECONDARY entry's own vector read. vecodd_pend is too short
		// for this: it drops when that entry starts, before its frame is out.
		if (exc_vec_odd_now && !exc_vec_dbl && !stall_in) ae_susp <= 1'b1;
		else if (exc_vec_done && !stall_in)               ae_susp <= 1'b0;
		else if (rte_odd_now)                             ae_susp <= 1'b1;

		// The odd-vector re-entry. Set when the vector arrives odd and is
		// not a double fault; cleared when the entry it asks for actually
		// departs, which is the same condition exc_go latches a verdict on.
		if (exc_vec_odd_now && !exc_vec_dbl && !stall_in) begin
			vecodd_pend  <= 1'b1;
			// 4 * vector, and deliberately NOT vbr + 4 * vector.
			vecodd_pc_r  <= {22'd0, exc_vec_r, 2'b00};
			vecodd_tgt_r <= {l1_q_b[31:1], 1'b0};
		end else if (exc_active && !a7_busy && !creg_busy && !exc_go) vecodd_pend <= 1'b0;

		if (exc_vec_done && !stall_in) exc_pend_chk <= 1'b0;
		else if (chk_now && !exc_go) begin
			exc_pend_chk   <= 1'b1;
			exc_pend_chk_n <= chk_negative;
			exc_pend_chk_c <= chk_c;
		end

		if (exc_vec_done && !stall_in)  exc_pend_trapcc <= 1'b0;
		else if (trapcc_now && !exc_go) exc_pend_trapcc <= 1'b1;

		if (exc_vec_done && !stall_in)  exc_pend_fmterr <= 1'b0;
		else if (fmterr_now && !exc_go) exc_pend_fmterr <= 1'b1;

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
			xm_have         <= 1'b0;
			m16_active      <= 1'b0;
			c2_active       <= 1'b0;
			mvm_active      <= 1'b0;
			mvm_rd_pend     <= 1'b0;
			mvp_active      <= 1'b0;
			mvp_rd_pend     <= 1'b0;
			bf_active       <= 1'b0;
			bf_ph           <= BF_EA;
			ck_active       <= 1'b0;
			exc_pend_divzero <= 1'b0;
			exc_pend_addrerr <= 1'b0;
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
			if (hold_hazard) begin
				// The bubble, and it has to come FIRST. Below mem_issue it
				// set mem_pending for a read that stall_self had already
				// kept off the memory, and the stage then waited for a
				// return that was never asked for -- bookkeeping without
				// the request it records, which is the same shape as the
				// defect this whole milestone is about. eaf_stall is
				// holding eac_* in place, so the instruction is still here
				// next cycle, by which time the MOVEC has committed and
				// the auxiliary bypass answers its read.
				eaf_valid      <= 1'b0;
			end else if (mem_issue) begin
				eaf_valid   <= 1'b0;
				mem_pending <= 1'b1;
				cas_ea      <= ea_target;
				if (!xm_have) begin
					xm_daddr <= mm_daddr;
					xm_dan   <= mm_dan_new;
				end
			end else if (mem_complete && xm && !xm_have) begin
				// The source is in; the destination's load goes out next.
				eaf_valid   <= 1'b0;
				mem_pending <= 1'b0;
				xm_have     <= 1'b1;
				xm_src      <= mem_lane;
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
				// ...and an immediate-source RMW crosses over the same way,
				// with eac_imm where the register source would be. operand_a
				// is NOT available as the source here: it is the address
				// base, which is exactly why id_src_a_is_imm stays clear for
				// this form (milestone 89).
				// CAS (milestone 117): equal -- store Du; not equal -- the value
				// goes to Dc, merged at the operand size by EX's alu_sized.
				eaf_operand_a  <= xm         ? xm_src :
				                  eac_is_packop ? pack_value :
				                  cas        ? (cas_eq ? operand_c : mem_lane) :
				                  eac_immrmw ? eac_imm   :
				                  eac_is_rmw ? operand_b : mem_lane;
				// Every classification flag this stage exports, because a
				// path that leaves one alone hands the NEXT instruction the
				// previous one's (milestone 101). A load behind a LINK
				// carried eaf_is_link and wrote no register; behind an
				// ORI-to-SR it carried eaf_is_immsr and quietly rewrote the
				// status register with whatever it had loaded. Eight were
				// stale, of which a review found three; the rest came out
				// of diffing this branch's assignments against the general
				// one's, which is the only way to be sure there is not a
				// ninth.
				eaf_immsr_to_sr<= eac_immsr_to_sr;
				eaf_is_chk     <= 1'b0;
				eaf_chk_ok     <= eac_is_chk;
				eaf_is_immsr   <= eac_is_immsr;
				eaf_is_stop    <= stop_takes_hold;
				eaf_is_link    <= eac_is_link;
				eaf_is_pea     <= eac_is_pea;
				eaf_is_trapcc  <= 1'b0;
				eaf_movec_dir  <= eac_imm[4];
				eaf_movec_sel  <= eac_imm[3:0];
				// The store half needs the address again a stage later, and
				// eac_* will have moved on by then.
				// BTST to memory is marked RMW for the operand crossover only
				// and writes nothing back (milestone 113).
				eaf_is_rmw     <= (eac_is_rmw && (eac_alu_op != `AP040_ALU_BTST)) || (mm && !xm_nost) || (cas && cas_eq);
				eaf_casf       <= {cas, cas_fl};
				eaf_is_mm      <= mm && !xm;
				eaf_is_xm      <= xm;
				eaf_bnt        <= 1'b0;
				xm_have        <= 1'b0;
				eaf_mvfsr      <= eac_mvfsr;
				eaf_ml         <= eac_ml;
				if (!bfv) eaf_bf <= 3'd0;
				if (!ck) eaf_ck2 <= 3'd0;
				if (!cas) eaf_casf <= 5'd0;
				eaf_rtr_ccr    <= 6'd0;
				eaf_is_div     <= eac_is_div;
				eaf_div_signed <= eac_div_signed;
				eaf_ea_target  <= xm ? xm_dan : ml_an3 ? an_new : mm ? mm_daddr : cas ? cas_ea : ea_target;
				// RTS: the popped value (l1_q_b, into eaf_operand_a above)
				// is the redirect target, exactly like JMP/JSR/exceptions
				// already route through eaf_operand_a -- but this stage
				// ALSO owes A7 its post-pop value (old+4), which is NOT
				// what a plain MOVE.L (An),Dn would put in eaf_operand_b
				// (that instruction's operand_b is simply unused). See
				// header.
				// RTD adds its displacement to the same sum (milestone 113); it
				// rides eac_ea_ext, which is zero for a plain RTS.
				// ...and an <ea>,An whose <ea> steps that same An -- ADDA.W
				// (A6)+,A6 -- operates on the STEPPED An (milestone 114): the
				// source's side effect comes first. Port B read the register
				// before the step. This was the whole of the corpus's
				// remaining 2,496 wrong rounds.
				eaf_operand_b  <= xm         ? mem_lane :
				                  mm         ? mm_dan_new :
				                  eac_is_rts ? (operand_a + 32'd4 + eac_ea_ext) :
				                  (eac_is_rmw || eac_immrmw) ? mem_lane :
				                  mm_same    ? an_new : operand_b;
				eaf_alu_op     <= eac_is_packop ? `AP040_ALU_MOVE : eac_alu_op;
				eaf_size       <= eac_is_packop ? mm_dsz : eac_size;
				eaf_shcnt      <= shcnt_now;
				eaf_writes_an  <= an_wr_any;
				eaf_an_sel     <= an_sp_sel;
				eaf_an_reg     <= an_wr_reg;
				eaf_an_data    <= ml_rd_dr ? operand_c : an_wr_data;   // Dr for a 64-bit divide
				eaf_writes_reg <= eac_writes_reg && !(cas && cas_eq);
				eaf_writes_ccr <= eac_writes_ccr || eac_is_chk;
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
			end else if (exc_active && !exc_go) begin
				// The fault cycle (milestone 88): the verdict is being
				// registered and the frame starts next cycle. Nothing below
				// may run for this instruction now -- in particular not
				// ret_done, which would let an RTE with a bad format word
				// complete its pop in the cycle fmterr_now says otherwise.
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
			end else if (eac_valid && eac_is_movem && !mvm_fin && !trace_hold && !ae_busy) begin
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
					// ...and the indexed modes (milestone 115) start from
					// ea_target; eac_pc_base carries the mask word's two bytes.
					mvm_addr    <= eac_ea_indexed  ? ea_target :
					               eac_movem_abs   ? eac_imm :
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
			end else if (fp_stall) begin
				// The FPU sequencer has the instruction (see its block); eac_*
				// frozen by fp_stall, nothing goes to EX until it finishes.
				eaf_valid <= 1'b0;
			end else if (eac_valid && ck && !ck_fin && !trace_hold && !ae_busy) begin
				// CHK2/CMP2 (see its header); eac_* frozen by ck_stall.
				eaf_valid <= 1'b0;
				if (!ck_active) begin
					ck_active <= 1'b1;
					ck_ea     <= ea_target;
					ck_ph     <= CK_RD1;
				end else case (ck_ph)
				CK_RD1:  if (ck_ld_go) ck_ph <= CK_RD1W;
				CK_RD1W: if (l1_rvalid_b) begin
					ck_lb <= ck_sx(l1_q_b, eac_size);
					ck_ph <= CK_RD2;
				end
				CK_RD2:  if (ck_ld_go) ck_ph <= CK_RD2W;
				CK_RD2W: if (l1_rvalid_b) begin
					ck_z  <= (ck_rn == ck_lbs) || (ck_rn == ck_ubs);
					ck_c  <= ck_oob;
					ck_ph <= CK_DONE;
				end
				default: ;
				endcase
			end else if (eac_valid && cas2 && !c2_fin && !trace_hold && !ae_busy) begin
				// CAS2 (see its header); eac_* frozen by c2_stall.
				eaf_valid <= 1'b0;
				if (!c2_active) begin
					c2_active <= 1'b1;
					c2_ph     <= C2_R1;
				end else case (c2_ph)
				C2_R1:   begin c2_a1  <= operand_c; c2_ph <= C2_R2;  end
				C2_R2:   begin c2_a2  <= operand_c; c2_ph <= C2_RD1; end
				C2_RD1:  if (c2_ld_go) c2_ph <= C2_RD1W;
				C2_RD1W: if (l1_rvalid_b) begin c2_m1 <= l1_q_b; c2_ph <= C2_RD2; end
				C2_RD2:  if (c2_ld_go) c2_ph <= C2_RD2W;
				C2_RD2W: if (l1_rvalid_b) begin c2_m2 <= l1_q_b; c2_ph <= C2_DC1; end
				C2_DC1:  begin c2_dc1 <= operand_c; c2_ph <= C2_DC2; end
				C2_DC2:  begin c2_dc2 <= operand_c; c2_ph <= C2_CMP; end
				C2_CMP:  begin
					c2_fl <= c2_f1[2] ? c2_f2 : c2_f1;
					c2_eq <= c2_f1[2] && c2_f2[2];
					c2_ph <= (c2_f1[2] && c2_f2[2]) ? C2_DU1 : C2_DONE;
				end
				C2_DU1:  begin c2_du1 <= operand_c; c2_ph <= C2_DU2; end
				C2_DU2:  begin c2_du2 <= operand_c; c2_ph <= C2_WR1; end
				C2_WR1:  if (c2_st_go) c2_ph <= C2_WR2;
				C2_WR2:  if (c2_st_go) c2_ph <= C2_DONE;
				default: ;
				endcase
			end else if (eac_valid && m16 && !m16_fin && !trace_hold && !ae_busy) begin
				// MOVE16 (see its header); eac_* frozen by m16_stall.
				eaf_valid <= 1'b0;
				if (!m16_active) begin
					m16_active <= 1'b1;
					m16_s      <= m16_src_c & 32'hFFFF_FFF0;
					m16_d      <= m16_dst_c & 32'hFFFF_FFF0;
					m16_i      <= 2'd0;
					m16_ph     <= M16_RD;
				end else case (m16_ph)
				M16_RD:  if (m16_ld_go) m16_ph <= M16_RDW;
				M16_RDW: if (l1_rvalid_b) begin
					m16_buf <= l1_q_b;
					m16_ph  <= M16_WR;
				end
				M16_WR:  if (m16_st_go) begin
					m16_i  <= m16_i + 2'd1;
					m16_ph <= (m16_i == 2'd3) ? M16_DONE : M16_RD;
				end
				default: ;
				endcase
			end else if (eac_valid && bfv && !bf_fin && !trace_hold && !ae_busy) begin
				// The bitfield sequencer (see its header). eac_* is frozen by
				// bf_stall throughout.
				eaf_valid <= 1'b0;
				if (!bf_active) begin
					bf_active <= 1'b1;
					bf_ea     <= ea_target;      // port C is still the index here
					bf_ph     <= BF_OFF;
				end else case (bf_ph)
				BF_OFF: begin
					bf_off <= bfx[11] ? operand_c : {27'd0, bfx[10:6]};
					bf_ph  <= BF_WID;
				end
				BF_WID: begin
					bf_w   <= bfx[5] ? ((operand_c[4:0] == 5'd0) ? 6'd32 : {1'b0, operand_c[4:0]})
					                 : ((bfx[4:0] == 5'd0)       ? 6'd32 : {1'b0, bfx[4:0]});
					bf_ph  <= BF_SRC;
				end
				BF_SRC: begin
					// A register BFINS takes its source through port C; a memory
					// one had decode point port B at it.
					bf_du <= bf_reg ? operand_c : operand_b;
					if (bf_reg) begin
						bf_w1  <= (bf_off[4:0] == 5'd0) ? operand_a
						          : ((operand_a << bf_off[4:0]) | (operand_a >> (6'd32 - {1'b0, bf_off[4:0]})));
						bf_w2  <= 8'd0;
						bf_bib <= 3'd0;
						bf_ph  <= BF_S1;
					end else begin
						bf_addr <= bf_ea + {{3{bf_off[31]}}, bf_off[31:3]};
						bf_bib  <= bf_off[2:0];
						bf_span <= ({3'd0, bf_off[2:0]} + bf_w + 6'd7) >> 3;
						bf_ph   <= BF_RD1;
					end
				end
				BF_RD1: if (bf_ld_go) bf_ph <= BF_RD1W;
				BF_RD1W: if (l1_rvalid_b) begin
					bf_w1 <= (bf_span == 3'd1) ? {l1_q_b[7:0], 24'd0} :
					         (bf_span <= 3'd3) ? {l1_q_b[15:0], 16'd0} : l1_q_b;
					bf_w2 <= 8'd0;
					bf_ph <= bf_two ? BF_RD2 : BF_S1;
				end
				BF_RD2: if (bf_ld_go) bf_ph <= BF_RD2W;
				BF_RD2W: if (l1_rvalid_b) begin
					if (bf_span == 3'd3) bf_w1[15:8] <= l1_q_b[7:0];
					else                 bf_w2       <= l1_q_b[7:0];
					bf_ph <= BF_S1;
				end
				BF_S1: begin
					bf_t40 <= {bf_w1, bf_w2} << bf_bib;
					bf_ph  <= BF_S2;
				end
				BF_S2: begin
					bf_field <= (bf_w == 6'd32) ? bf_t40[39:8] : (bf_t40[39:8] >> (6'd32 - bf_w));
					bf_ones  <= (bf_w == 6'd32) ? 32'hFFFF_FFFF : ((32'd1 << bf_w) - 32'd1);
					bf_maskl <= (bf_w == 6'd32) ? {32'hFFFF_FFFF, 8'd0}
					                            : ({32'hFFFF_FFFF, 8'd0} << (6'd32 - bf_w));
					bf_ph    <= BF_S3;
				end
				BF_S3: begin
					bf_n <= (bf_op == 3'd7) ? bf_nf[bf_w - 6'd1] : bf_field[bf_w - 6'd1];
					bf_z <= (bf_op == 3'd7) ? (bf_nf == 32'd0)   : (bf_field == 32'd0);
					bf_res <= (bf_op == 3'd3) ? (bf_field | (bf_field[bf_w - 6'd1] ? ~bf_ones : 32'd0)) :
					          (bf_op == 3'd5) ? (bf_off + {26'd0, (bf_al == 32'd0) ? bf_w : bf_clz}) :
					                            bf_field;
					if (bf_modop) begin
						bf_t40 <= (bf_t40 & ~bf_maskl) | (({bf_nf, 8'd0} << (6'd32 - bf_w)) & bf_maskl);
						bf_ph  <= BF_S4;
					end else
						bf_ph  <= BF_DONE;
				end
				BF_S4: begin
					if (bf_reg) begin
						bf_res <= (bf_off[4:0] == 5'd0) ? bf_t40[39:8]
						          : ((bf_t40[39:8] >> bf_off[4:0]) |
						             (bf_t40[39:8] << (6'd32 - {1'b0, bf_off[4:0]})));
						bf_ph  <= BF_DONE;
					end else begin
						bf_w1 <= bf_nw40[39:8];
						bf_w2 <= bf_nw40[7:0];
						bf_ph <= BF_WR1;
					end
				end
				BF_WR1: if (bf_st_go) bf_ph <= bf_two ? BF_WR2 : BF_DONE;
				BF_WR2: if (bf_st_go) bf_ph <= BF_DONE;
				default: ;
				endcase
			end else if (eac_valid && mvp && !mvp_fin && !trace_hold && !ae_busy) begin
				// MOVEP: start, then one beat at a time (see its header).
				// eac_* is frozen by mvp_stall, so ea_target still names
				// (d16,Ay) on the starting cycle and operand_b is Dx.
				eaf_valid <= 1'b0;
				if (!mvp_active) begin
					mvp_active  <= 1'b1;
					mvp_left    <= mvp_long ? 3'd4 : 3'd2;
					mvp_addr    <= ea_target;
					mvp_acc     <= 32'h0;
					mvp_rd_pend <= 1'b0;
				end else if (mvp_ld_go) begin
					mvp_rd_pend <= 1'b1;
					mvp_addr    <= mvp_addr + 32'd2;
					mvp_left    <= mvp_left - 3'd1;
				end else if (mvp_rd_pend && l1_rvalid_b) begin
					mvp_rd_pend <= 1'b0;
					mvp_acc     <= {mvp_acc[23:0], l1_q_b[7:0]};
				end else if (mvp_st_go) begin
					mvp_addr    <= mvp_addr + 32'd2;
					mvp_left    <= mvp_left - 3'd1;
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
						EXC_BEAT1: exc_ph <= exc_fmt2_r ? EXC_BEAT2 : EXC_VECRD;
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
				ck_active      <= 1'b0;
				eaf_ck2        <= 3'd0;
				eaf_casf       <= 5'd0;
				eaf_rtr_ccr    <= 6'd0;
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
				                    eac_is_trace || eac_is_fpexc) ? 4'd15 : eac_dest_reg;
				// The vector is a LONGWORD, always. It must not go through
				// mem_lane, which selects a lane from eff_size and would
				// hand back a sign-extended half-word for any faulting
				// instruction that set eac_sxt_w. Divide by zero is the
				// first instruction that both sets it and can fault, so
				// this was latent until milestone 52: the frame pushed and
				// the vector read correctly, and then the redirect went to
				// $00000000.
				// An odd handler never becomes a target: the even address is
				// what the frame's address field carries and what anything
				// fetched before the second entry supersedes it uses.
				eaf_operand_a  <= exc_vec_odd_now ? {l1_q_b[31:1], 1'b0} : l1_q_b;
				eaf_operand_b  <= exc_new_sp;
				// No exception entry leaves a trace behind it on the 68040
				// (review 14). This armed one whenever T1 or T0 was set, the
				// 68000/68020 rule that a traced TRAP is traced on its
				// handler's first instruction, and every synchronous
				// exception -- ILLEGAL, privilege, TRAP, TRAPV, divide by
				// zero, CHK/CHK2, an odd RTR/RTE, a format error -- pushed a
				// second, vector-9 frame before its own handler ran.
				// ap040_core.v's S_EXC0 clears T1/T0 and arms nothing: only an
				// interrupt that preempts a trace already owed carries it into
				// the handler, and this pipeline takes no interrupts. Its
				// notes record the hardware: cputest reported "Got unexpected
				// trace exception" after the ILLEGAL ending every test while
				// the sequential core still carried T0 through.
				trace_arm      <= 1'b0;
				trace_arm_cond <= 1'b0;
				trace_pc       <= eac_pc;
				eaf_alu_op     <= eac_alu_op;
				eaf_size       <= eac_size;
				eaf_shcnt      <= shcnt_now;
				eaf_writes_an  <= an_wr_any && own_exc;
				eaf_an_sel     <= an_sp_sel;   // a trace entry runs none of the held instruction
				eaf_an_reg     <= an_wr_reg;
				eaf_an_data    <= ml_rd_dr ? operand_c : an_wr_data;   // Dr for a 64-bit divide
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
				eaf_is_mm      <= 1'b0;
				eaf_is_xm      <= 1'b0;
				eaf_bnt        <= 1'b0;
				eaf_mvfsr      <= 2'd0;
				eaf_ml         <= 7'd0;
				eaf_bf         <= 3'd0;
				eaf_ck2        <= 3'd0;
				eaf_casf       <= 5'd0;
				eaf_rtr_ccr    <= 6'd0;
				eaf_is_link    <= 1'b0;
				eaf_is_pea     <= 1'b0;
				eaf_is_immsr   <= 1'b0;
				// ...except a double fault, which halts (milestone 110).
				eaf_is_stop    <= exc_vec_dbl;
				eaf_is_chk     <= eac_is_chk_trap && own_exc;
				eaf_chk_ok     <= 1'b0;
				eaf_is_trapcc     <= eac_is_trapcc_trap && own_exc;
				eaf_is_div     <= 1'b0;
				eaf_div_signed <= 1'b0;
				eaf_is_bsr     <= 1'b0;
				eaf_is_jsr     <= 1'b0;
				eaf_is_trap    <= eac_is_trap && own_exc;
				// ...and the FPU's exceptions: EX needs only to know an entry is
				// retiring (exc_reaching_ex), and this flag says nothing more. Without
				// it the entry retired as an ordinary instruction and A7 took the
				// handler's address, in the faulting instruction's own bank.
				eaf_is_illegal <= (eac_is_illegal || eac_is_fpexc) && own_exc;
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
				eaf_sr_snapshot <= sr_faulted;
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
				// ...unless the PC it restores is odd (review 12, finding 2):
				// the address error that return owes supersedes the trace, as
				// ap040_core.v's S_RTE_FIN2 checks the PC before the traced
				// path. Armed, the trace outranked the deferred address error
				// and took vector 9 with the odd PC in its frame.
				trace_arm       <= traced_now && !rte_pc_now[0];   // judged on the SR BEFORE the RTE
				trace_arm_cond  <= 1'b0;         // (RTE is a change of flow, so T0 traces it too)
				trace_pc        <= eac_pc;
				// RTR (milestone 117) parts from RTE here. It leaves as an RTS
				// -- the redirect, and A7 through the main port, banked by an
				// S bit RTR cannot change, so a user-mode RTR moves USP where
				// RTE's fixed ISP/MSP write would have missed it -- with the
				// popped CCR committed by EX (eaf_rtr_ccr). An odd PC leaves A7
				// where it was: ap040_core.v's S_RET3 backs the pop out before
				// the address error, which rte_odd_now then owes exactly as it
				// does an RTE's, the frame carrying the popped CCR.
				eaf_operand_b   <= eac_is_rtr ? (operand_a + (rte_pc_now[0] ? 32'd0 : 32'd6)) :
				                   operand_a +
				                    (ret_fmt_long ? 32'd12 : 32'd8);   // new A7: $2/$3 are twelve bytes
				eaf_alu_op      <= eac_alu_op;
				eaf_size       <= eac_size;
				eaf_shcnt      <= shcnt_now;
				eaf_writes_an  <= an_wr_any;
				eaf_an_sel     <= an_sp_sel;
				eaf_an_reg     <= an_wr_reg;
				eaf_an_data    <= ml_rd_dr ? operand_c : an_wr_data;   // Dr for a 64-bit divide
				// NOT 1: RTE's A7 restore does NOT go through the normal
				// commit_reg/A7-bank path at all -- see ap040_execute.v's
				// header for the real race that forces this (RTE's own SR
				// restore commits the SAME cycle, and would otherwise bank
				// this very write through the NEW, just-restored S bit
				// instead of the OLD one). eaf_operand_b (the new A7 value,
				// still computed above) is instead consumed by
				// ap040_execute.v's exe_writes_creg path, writing directly
				// to ISP/MSP.
				eaf_writes_reg  <= eac_is_rtr;
				eaf_writes_ccr  <= eac_is_rtr;
				eaf_is_branch   <= 1'b0;
				eaf_is_scc      <= 1'b0;
				eaf_is_dbcc     <= 1'b0;
				eaf_is_jmp      <= 1'b0;
				eaf_is_rmw      <= 1'b0;
				eaf_is_mm       <= 1'b0;
				eaf_is_xm       <= 1'b0;
				eaf_bnt         <= 1'b0;
				eaf_mvfsr       <= 2'd0;
				eaf_ml          <= 7'd0;
				eaf_bf          <= 3'd0;
				eaf_ck2         <= 3'd0;
				eaf_casf        <= 5'd0;
				eaf_rtr_ccr     <= {eac_is_rtr, ret_dword0[20:16]};
				eaf_is_link     <= 1'b0;
				eaf_is_pea      <= 1'b0;
				eaf_is_immsr    <= 1'b0;
				eaf_is_stop     <= 1'b0;
				eaf_is_chk      <= 1'b0;
				eaf_chk_ok      <= 1'b0;
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
				eaf_is_rts      <= eac_is_rtr;
				eaf_is_rte      <= !eac_is_rtr;
				eaf_is_fmterr  <= 1'b0;
				eaf_is_trace   <= 1'b0;
				// Popped SR, masked -- ap040_execute.v's new commit source
				// for restoring it (exe_writes_sr/exe_sr_data) -- see its
				// header for why this needs its own field rather than
				// reusing eaf_sr_snapshot (that one's a forwarded READ of
				// the CURRENT live SR, not the value being ADOPTED).
				eaf_rte_sr_data <= ret_dword0[31:16] & `AP040_SR_MASK;
				eaf_sr_snapshot <= sr_faulted;
				eaf_cond        <= eac_cond;
				ret_ph          <= RET_BEAT0;
				ret_pending     <= 1'b0;
			end else begin
				// A finishing MOVEM completes through this branch, which is
				// also where An gets written via an_wr_* -- so the sequencer
				// is retired here. Unconditional because it is already low
				// for every other instruction.
				mvm_active     <= 1'b0;
				mvp_active     <= 1'b0;
				bf_active      <= 1'b0;
				bf_ph          <= BF_EA;
				eaf_bf         <= {bfv, bf_n, bf_z};
				ck_active      <= 1'b0;
				m16_active     <= 1'b0;
				c2_active      <= 1'b0;
				eaf_ck2        <= {ck, ck_z, ck_c};
				eaf_valid      <= eac_valid;
				eaf_pc         <= eac_pc;
				if (eac_valid) begin   // a bubble departing here must not drop a pending trace
					trace_arm      <= traced_now;
					trace_arm_cond <= traced_cond;
					trace_pc       <= eac_pc;
				end
				eaf_next_pc    <= eac_next_pc;
				eaf_dest_reg   <= cas2 ? {1'b0, c2x[2:0]} : fp ? fp_w1_reg : eac_dest_reg;
				// JMP/JSR: route the computed EA itself, not the register
				// value alone -- see header. BSR has no source read at all
				// (operand_a is simply unused for it), so it falls through
				// to the same default every register-direct instruction
				// already used.
				// LEA joins JMP/JSR here (milestone 42): its whole job is to
				// deliver the computed address as the operand, so ALU_MOVE
				// then writes it to An. This one line is the entire
				// datapath cost of the instruction.
				// A store with a displacement reads its ADDRESS through
				// port A (milestone 91), so the data -- which is what MOVE
				// sets N and Z from -- is on port B. A registered
				// assignment, not the address path.
				// A branch predicted not taken carries its target to EX, which
				// redirects there if it is taken (2026-09-24).
				eaf_operand_a  <= fp ? fp_target : (eac_is_branch && eac_bnt) ? br_target :
				                  cas2 ? c2_m2 : (eac_is_jmp || eac_is_jsr || eac_is_lea) ? ea_target :
				                  eac_is_packop                            ? pack_value :
				                  mvp                                      ? mvp_acc :
				                  bfv                                      ? bf_res :
				                  // BTST Dn,#imm: the bit number is Dn (port B), the
				                  // data the immediate -- ALU_BTST's a and b swapped.
				                  eac_is_btstr                             ? operand_b :
				                  eac_st_disp                              ? operand_b :
				                  eac_sxt_w                                ? sxt_w_of(operand_a) :
				                                                             operand_a;
				// BSR/JSR: the NEW A7 value (== push_addr, the same
				// expression already used for the write address) -- see
				// header for why the decrement happens HERE, once, rather
				// than being recomputed in ap040_execute.v.
				eaf_operand_b  <= cas2 ? c2_dc2 : (eac_is_bsr || eac_is_jsr || eac_is_pea) ? push_addr :
				                  eac_is_link                ? (push_addr + eac_imm) :
				                  mm                         ? mm_dan_new :
				                  eac_is_btstr               ? operand_a : operand_b;
				eaf_is_link    <= eac_is_link;
				eaf_is_pea     <= eac_is_pea;
				eaf_is_immsr   <= eac_is_immsr;
				eaf_is_stop    <= stop_takes_hold;
				eaf_is_chk     <= 1'b0;
				eaf_chk_ok     <= eac_is_chk;
				eaf_is_trapcc     <= 1'b0;
				eaf_immsr_to_sr<= eac_immsr_to_sr;
				eaf_alu_op     <= cas2 ? `AP040_ALU_MOVE : (eac_is_packop || eac_is_exgop) ? `AP040_ALU_MOVE :
				                  eac_is_btstr                    ? `AP040_ALU_BTST : eac_alu_op;
				eaf_size       <= eac_size;
				eaf_shcnt      <= shcnt_now;
				eaf_writes_an  <= cas2 ? !c2_eq : m16 ? m16_an_up : an_wr_any;
				eaf_an_sel     <= an_sp_sel;
				eaf_an_reg     <= cas2 ? {1'b0, c2x[18:16]} : m16 ? eac_src_reg : an_wr_reg;
				eaf_an_data    <= cas2 ? c2_dc1_new : m16 ? (operand_a + 32'd16) :
				                  ml_rd_dr ? operand_c : an_wr_data;   // Dr for a 64-bit divide
				eaf_writes_reg <= cas2 ? !c2_eq : fp ? fp_w1_en : eac_writes_reg;
				eaf_writes_ccr <= eac_writes_ccr || eac_is_chk;
				eaf_is_branch  <= eac_is_branch;
				eaf_is_scc     <= eac_is_scc;
				eaf_is_dbcc    <= eac_is_dbcc;
				eaf_is_jmp     <= eac_is_jmp || (fp && fp_redirect);
				eaf_is_rmw     <= mm;
				eaf_is_mm      <= mm;
				eaf_is_xm      <= m16_pp || (fp && fp_w1_en);   // the FPU's result rides eaf_ea_target
				eaf_bnt        <= eac_is_branch && eac_bnt;
				eaf_mvfsr      <= eac_mvfsr;
				eaf_ml         <= eac_ml;
				if (!bfv) eaf_bf <= 3'd0;
				if (!ck) eaf_ck2 <= 3'd0;
				if (!cas) eaf_casf <= cas2 ? {1'b1, c2_fl} : 5'd0;
				eaf_rtr_ccr    <= 6'd0;
				if (mm) eaf_ea_target <= mm_daddr;
				if (m16) eaf_ea_target <= operand_b + 32'd16;   // (Ax)+,(Ay)+: Ay's step
				if (fp) eaf_ea_target <= fp_w1_val;
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
				eaf_movec_dir  <= eac_imm[4];
				eaf_movec_sel  <= eac_imm[3:0];
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
