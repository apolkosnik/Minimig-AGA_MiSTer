//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (milestone 17: address error)       //
//                                                                          //
// ap040_ea_calc.v - EA-calc stage                                         //
//                                                                          //
// MOVEQ, register-direct MOVE.L/ADD.L, Bcc/BRA (any displacement width),   //
// Scc, DBcc, JMP, BSR, and JSR all have no memory effective address to     //
// compute, so this is still a pure pass-through -- it exists to occupy the //
// register slot a real address calculation will use once an EA mode that   //
// actually needs arithmetic is added, rather than being spliced in later   //
// and reshaping the pipeline. id_is_branch/id_is_scc/id_cond/              //
// id_writes_ccr/id_next_pc ride through unchanged for the same reason --   //
// this stage has nothing to compute for any of them; only                  //
// ap040_execute.v actually evaluates a condition or merges a byte, per its //
// header comment. id_next_pc is just one more field in the same            //
// pass-through shape.                                                     //
//                                                                          //
// MOVE.L (An),Dn (milestone 9b) and JMP (An)/(d16,An) (milestone 11) are    //
// ALSO pure pass-throughs here, deliberately: their effective addresses     //
// are An's raw value (plus id_imm's displacement for the (d16,An) forms),   //
// no arithmetic -- id_is_mem_src/id_is_jmp thread through unchanged, same   //
// shape as every other flag above. This is why the EA-calc/EA-fetch split   //
// exists as two stages already (per the original plan): the day an EA mode  //
// needs real arithmetic (indexed modes, etc.), it lands HERE, and EA-       //
// fetch's memory-access/stall logic (see its header) doesn't need to        //
// change at all -- it already just consumes whatever address EA-calc        //
// resolved.                                                                 //
//                                                                          //
// BSR/JSR (milestone 13, new) are the SAME story one level further: the     //
// push address (A7-4) and the memory write itself are both computed and     //
// issued entirely in ap040_ea_fetch.v, from id_dest_reg's register value    //
// (port B) -- id_is_bsr/id_is_jsr just thread through here unchanged, same  //
// as every other flag.                                                     //
//                                                                          //
// TRAP #n / illegal instruction (milestone 14, new): same story a third     //
// time. Both need A7's value (port B, id_dest_reg already pointed at A7 by   //
// ap040_decode.v, same trick BSR/JSR use) and nothing else EA-calc could      //
// compute -- the frame contents, the multi-beat push, and the vector-table    //
// read all live in ap040_ea_fetch.v's new exception-entry sequencer. id_is_    //
// trap/id_is_illegal just thread through unchanged, same shape as every       //
// other flag above.                                                          //
//                                                                          //
// MOVE to SR / MOVEC (milestone 15, new): a fourth and fifth flavor of the    //
// same story, PLUS a genuinely dynamic wrinkle this stage still doesn't       //
// need to know about -- whether either one actually FAULTS (privilege         //
// violation) depends on the live, forwarded S bit, which doesn't exist         //
// until ap040_ea_fetch.v/ap040_execute.v. id_is_movesr/id_is_movec thread       //
// through unchanged either way; the fault decision and its consequences         //
// (suppressing the normal SR/control-register write, rerouting port B to         //
// A7 for the exception's own push) are entirely ap040_ea_fetch.v's job -- see     //
// its header.                                                                     //
//                                                                          //
// RTS / RTE (milestone 16, new): a sixth and seventh flavor, same story        //
// again. RTS reuses id_is_mem_src (ap040_decode.v now sets it for RTS too,       //
// same FSM MOVE.L (An),Dn already uses) so it needs NO new pass-through field       //
// at all beyond id_is_rts itself, purely for ap040_execute.v's redirect/commit       //
// classification. RTE gets its own new sequencer entirely in ap040_ea_fetch.v         //
// (two reads, not one, plus a dynamic privilege check) -- this stage still has          //
// nothing to compute for it either.                                                      //
//                                                                          //
// flush: when ap040_execute.v detects a mispredicted branch, everything     //
// speculatively fetched behind it -- including whatever is sitting here -- //
// must be discarded. Same shape as stall_in but forces a bubble instead     //
// of holding.                                                              //
//--------------------------------------------------------------------------//

module ap040_ea_calc
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // EA-fetch cannot accept this cycle
	input             flush,      // EX detected a misprediction: force a bubble

	input             id_valid,
	input      [31:0] id_pc,
	input      [31:0] id_next_pc,
	input       [3:0] id_dest_reg,
	input       [3:0] id_src_reg,
	input      [31:0] id_imm,
	input       [5:0] id_alu_op,
	input       [1:0] id_size,
	input       [5:0] id_shcnt,
	input             id_src_a_is_imm,
	input             id_writes_reg,
	input             id_writes_ccr,
	input             id_is_branch,
	input             id_is_scc,
	input             id_is_dbcc,
	input             id_is_mem_src,
	input             id_is_abs,
	input             id_is_store,
	input             id_is_postinc,
	input             id_is_predec,
	input             id_is_jmp,
	input             id_is_lea,
	input             id_sxt_w,
	input             id_ea_indexed,
	input             id_ea_pcrel,
	input             id_is_rmw,
	input             id_is_div,
	input             id_div_signed,
	input             id_is_movem,
	input             id_movem_dir,
	input             id_movem_word,
	input             id_movem_down,
	input             id_movem_wb,
	input             id_is_chk,
	input             id_is_immsr,
	input             id_immsr_to_sr,
	input             id_is_pea,
	input             id_is_link,
	input             id_is_unlk,
	input             id_is_bsr,
	input             id_is_jsr,
	input             id_is_trap,
	input             id_is_illegal,
	input             id_is_movesr,
	input             id_is_movec,
	input             id_is_rts,
	input             id_is_rte,
	input       [3:0] id_cond,

	output            ea_stall,   // to ID: no local stall of its own yet

	output reg        eac_valid,
	output reg [31:0] eac_pc,
	output reg [31:0] eac_next_pc,
	output reg  [3:0] eac_dest_reg,
	output reg  [3:0] eac_src_reg,
	output reg [31:0] eac_imm,
	output reg  [5:0] eac_alu_op,
	output reg  [1:0] eac_size,
	output reg  [5:0] eac_shcnt,
	output reg        eac_src_a_is_imm,
	output reg        eac_writes_reg,
	output reg        eac_writes_ccr,
	output reg        eac_is_branch,
	output reg        eac_is_scc,
	output reg        eac_is_dbcc,
	output reg        eac_is_mem_src,
	output reg        eac_is_abs,
	output reg        eac_is_store,
	output reg        eac_is_postinc,
	output reg        eac_is_predec,
	output reg        eac_is_jmp,
	output reg        eac_is_lea,
	output reg        eac_sxt_w,
	output reg        eac_ea_indexed,
	output reg        eac_ea_pcrel,
	output reg        eac_is_rmw,
	output reg        eac_is_div,
	output reg        eac_div_signed,
	output reg        eac_is_movem,
	output reg        eac_movem_dir,
	output reg        eac_movem_word,
	output reg        eac_movem_down,
	output reg        eac_movem_wb,
	output reg        eac_is_chk,
	output reg        eac_is_immsr,
	output reg        eac_immsr_to_sr,
	output reg        eac_is_pea,
	output reg        eac_is_link,
	output reg        eac_is_unlk,
	output reg        eac_is_bsr,
	output reg        eac_is_jsr,
	output reg        eac_is_trap,
	output reg        eac_is_illegal,
	output reg        eac_is_movesr,
	output reg        eac_is_movec,
	output reg        eac_is_rts,
	output reg        eac_is_rte,
	output reg  [3:0] eac_cond
);

assign ea_stall = stall_in;

always @(posedge clk) begin
	if (!nreset) begin
		eac_valid        <= 1'b0;
		eac_pc           <= 32'h0;
		eac_next_pc      <= 32'h0;
		eac_dest_reg     <= 4'h0;
		eac_src_reg      <= 4'h0;
		eac_imm          <= 32'h0;
		eac_alu_op       <= 6'h0;
		eac_size         <= `AP040_SZ_L;
		eac_shcnt        <= 6'd1;
		eac_src_a_is_imm <= 1'b0;
		eac_writes_reg   <= 1'b0;
		eac_writes_ccr   <= 1'b0;
		eac_is_branch    <= 1'b0;
		eac_is_scc       <= 1'b0;
		eac_is_dbcc      <= 1'b0;
		eac_is_mem_src   <= 1'b0;
		eac_is_abs       <= 1'b0;
		eac_is_store     <= 1'b0;
		eac_is_postinc   <= 1'b0;
		eac_is_predec    <= 1'b0;
		eac_is_jmp       <= 1'b0;
		eac_is_lea       <= 1'b0;
		eac_sxt_w        <= 1'b0;
		eac_ea_indexed   <= 1'b0;
		eac_ea_pcrel     <= 1'b0;
		eac_is_rmw       <= 1'b0;
		eac_is_div       <= 1'b0;
		eac_div_signed   <= 1'b0;
		eac_is_movem     <= 1'b0;
		eac_movem_dir    <= 1'b0;
		eac_movem_word   <= 1'b0;
		eac_movem_down   <= 1'b0;
		eac_movem_wb     <= 1'b0;
		eac_is_chk       <= 1'b0;
		eac_is_immsr     <= 1'b0;
		eac_immsr_to_sr  <= 1'b0;
		eac_is_pea       <= 1'b0;
		eac_is_link      <= 1'b0;
		eac_is_unlk      <= 1'b0;
		eac_is_bsr       <= 1'b0;
		eac_is_jsr       <= 1'b0;
		eac_is_trap      <= 1'b0;
		eac_is_illegal   <= 1'b0;
		eac_is_movesr    <= 1'b0;
		eac_is_movec     <= 1'b0;
		eac_is_rts       <= 1'b0;
		eac_is_rte       <= 1'b0;
		eac_cond         <= 4'h0;
	end else if (ce) begin
		if (flush) begin
			eac_valid <= 1'b0;
		end else if (!stall_in) begin
			eac_valid        <= id_valid;
			eac_pc           <= id_pc;
			eac_next_pc      <= id_next_pc;
			eac_dest_reg     <= id_dest_reg;
			eac_src_reg      <= id_src_reg;
			eac_imm          <= id_imm;
			eac_alu_op       <= id_alu_op;
			eac_size         <= id_size;
			eac_shcnt        <= id_shcnt;
			eac_src_a_is_imm <= id_src_a_is_imm;
			eac_writes_reg   <= id_writes_reg;
			eac_writes_ccr   <= id_writes_ccr;
			eac_is_branch    <= id_is_branch;
			eac_is_scc       <= id_is_scc;
			eac_is_dbcc      <= id_is_dbcc;
			eac_is_mem_src   <= id_is_mem_src;
			eac_is_abs       <= id_is_abs;
			eac_is_store     <= id_is_store;
			eac_is_postinc   <= id_is_postinc;
			eac_is_predec    <= id_is_predec;
			eac_is_jmp       <= id_is_jmp;
			eac_is_lea       <= id_is_lea;
			eac_sxt_w        <= id_sxt_w;
			eac_ea_indexed   <= id_ea_indexed;
			eac_ea_pcrel     <= id_ea_pcrel;
			eac_is_rmw       <= id_is_rmw;
			eac_is_div       <= id_is_div;
			eac_div_signed   <= id_div_signed;
			eac_is_movem     <= id_is_movem;
			eac_movem_dir    <= id_movem_dir;
			eac_movem_word   <= id_movem_word;
			eac_movem_down   <= id_movem_down;
			eac_movem_wb     <= id_movem_wb;
			eac_is_chk       <= id_is_chk;
			eac_is_immsr     <= id_is_immsr;
			eac_immsr_to_sr  <= id_immsr_to_sr;
			eac_is_pea       <= id_is_pea;
			eac_is_link      <= id_is_link;
			eac_is_unlk      <= id_is_unlk;
			eac_is_bsr       <= id_is_bsr;
			eac_is_jsr       <= id_is_jsr;
			eac_is_trap      <= id_is_trap;
			eac_is_illegal   <= id_is_illegal;
			eac_is_movesr    <= id_is_movesr;
			eac_is_movec     <= id_is_movec;
			eac_is_rts       <= id_is_rts;
			eac_is_rte       <= id_is_rte;
			eac_cond         <= id_cond;
		end
	end
end

endmodule
