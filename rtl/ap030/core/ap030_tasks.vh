// AP68030 core - sequencer tasks (included by ap030_core.v)
//
// All tasks are called from the clocked sequencer block and use
// nonblocking assignments; the pipe commands (pop_n, flush_req) are
// blocking per-clock variables consumed at the end of the block.

// data access: the result goes to dw_dst, execution continues at dw_ret
task dreq;
	input [31:0] addr;
	input  [1:0] size;
	input        rw;
	input [31:0] wdata;
	input  [2:0] fc;
	input        rmc;
	input        rmc_last;
	input  [3:0] dst_sel;
	input  [7:0] ret;
	begin
		d_stb <= 1'b1;
		d_addr <= addr; d_size <= size; d_rw <= rw; d_wdata <= wdata; d_fc <= fc;
		d_rmc <= rmc; d_rmc_last <= rmc_last; d_iack <= 1'b0; d_nocache <= 1'b0;
		dw_dst <= dst_sel; dw_ret <= ret;
		state <= S_DWAIT;
	end
endtask

// convenience wrappers
task rd;   input [31:0] addr; input [1:0] size; input [3:0] dst_sel; input [7:0] ret;
	begin dreq(addr, size, 1'b1, 32'd0, (ea_pc && PCREL_PROGRAM_SPACE) ? fc_prog : fc_data, 1'b0, 1'b0, dst_sel, ret); end endtask
task wr;   input [31:0] addr; input [1:0] size; input [31:0] data; input [7:0] ret;
	begin dreq(addr, size, 1'b0, data, fc_data, 1'b0, 1'b0, DW_NONE, ret); end endtask
task rd_sd; input [31:0] addr; input [1:0] size; input [3:0] dst_sel; input [7:0] ret;   // supervisor data
	begin dreq(addr, size, 1'b1, 32'd0, `FC_SUPER_DATA, 1'b0, 1'b0, dst_sel, ret); end endtask
task wr_sd; input [31:0] addr; input [1:0] size; input [31:0] data; input [7:0] ret;
	begin dreq(addr, size, 1'b0, data, `FC_SUPER_DATA, 1'b0, 1'b0, DW_NONE, ret); end endtask
// coprocessor interface register access (CPU space type 2)
task cir_rd; input [4:0] off; input [1:0] size; input [3:0] dst_sel; input [7:0] ret;
	begin dreq(cp_base | {27'd0, off}, size, 1'b1, 32'd0, `FC_CPU_SPACE, 1'b0, 1'b0, dst_sel, ret); end endtask
task cir_wr; input [4:0] off; input [1:0] size; input [31:0] data; input [7:0] ret;
	begin dreq(cp_base | {27'd0, off}, size, 1'b0, data, `FC_CPU_SPACE, 1'b0, 1'b0, DW_NONE, ret); end endtask

// register write (full 32 bits)
// A7 means the stack pointer selected by S and M now, when the write is
// issued; the register file commits a clock later, after a same-clock SR
// change (RTE) has already switched stacks
task wreg; input [3:0] idx; input [31:0] val;
	begin
		rf_we <= 1'b1; rf_waddr <= idx; rf_wdata <= val;
		rf_wact <= !sr_s ? 2'd0 : (sr_m ? 2'd2 : 2'd1);
		byp_we = 1'b1; byp_reg = idx; byp_data = val;
	end endtask
// register write merged by size (old value supplied)
task wreg_sz; input [3:0] idx; input [31:0] old; input [31:0] val; input [1:0] sz;
	begin wreg(idx, merge(old, val, sz)); end endtask

// instruction complete: trace disposition, back to the boundary
task finish;
	begin
		trace_pend <= tr_t1 | (tr_t0 & flow);
		state <= S_FETCH;
	end
endtask

// change of flow to a new PC: flush the pipe (address error on odd)
task go_pc;
	input [31:0] npc;
	begin
		flow <= 1'b1;
		if (npc[0]) begin
			exc_addr_err(npc);
		end else begin
			flush_req = 1'b1;
			flush_pc = npc;
			trace_pend <= tr_t1 | tr_t0;
			state <= S_FETCH;
		end
	end
endtask

// generic exception entry (UM 8.1): the frame fields are captured here
task exc_go;
	input  [7:0] vec;
	input  [3:0] fmt;
	input [31:0] pcv;
	input [31:0] iav;
	begin
		exc_vec <= vec; exc_fmt <= fmt; exc_pc <= pcv; exc_ia <= iav;
		exc_sr <= sr;
		exc_cnt <= cnt; exc_dw_dst <= dw_dst; exc_dw_ret <= dw_ret;
		exc_is_irq <= 1'b0; exc_is_reset <= 1'b0; exc_throw <= 1'b0;
		exc_busfault <= (vec == `VEC_BUSERR) || (vec == `VEC_ADDRERR);
		// T1 tracing survives the instruction traps (UM 8.1.7 / 8.1.12)
		trace_after_exc <= (tr_t1 | tr_t0) && ((vec == `VEC_DIVZERO) || (vec == `VEC_CHK) ||
		                   (vec == `VEC_TRAPCC) || (vec[7:4] == 4'h2 || vec[7:4] == 4'h3 && vec[7:0] < 8'd48));
		trace_pend <= 1'b0;
		if (vec == `VEC_BUSERR || vec == `VEC_ADDRERR || vec == `VEC_SPURIOUS || vec == `VEC_FLINE ||
		    (vec >= `VEC_AUTOVEC && vec < `VEC_TRAP)) status_cnt <= 2'd3;
		state <= S_EXC0;
	end
endtask

// pre-instruction exceptions (illegal, privilege, A/F-line): PC = instruction
task exc_pre; input [7:0] vec;
	begin exc_go(vec, `FMT_NORMAL, pc_i, 32'd0); end endtask
// post-instruction six-word frame (TRAPcc, CHK, divide by zero, MMU config): PC = next instruction
task exc_post; input [7:0] vec;
	begin exc_go(vec, `FMT_SIXWORD, scan_pc, pc_i); end endtask
task go_illegal; begin exc_pre(`VEC_ILLEGAL); end endtask
task go_priv;    begin exc_pre(`VEC_PRIV); end endtask

// stage images for the bus fault frames
task capture_pipe;
	begin
		exc_stage_c <= w0;
		exc_stage_b <= w1;
		exc_baddr <= scan_pc + 32'd2;
	end
endtask

// data access fault (from the memory system's fault record)
task exc_data_fault;
	input        boundary;      // at an instruction boundary (posted write): short frame
	input  [3:0] rkind;
	input  [7:0] rstate;
	begin
		capture_pipe;
		exc_fa <= f_addr;
		exc_dob <= f_dob;
		exc_got <= f_got;
		exc_partial <= f_partial;
		// SSW: FC FB RC RB 0 0 0 DF RM RW SIZE 0 FC2-FC0 (UM Figure 8-9)
		exc_ssw <= {1'b0, 1'b0, ~w0_v | w0_f, ~w1_v | w1_f, 3'b000, 1'b1, f_rm, f_rw, f_size, 1'b0, f_fc};
		exc_rk <= rkind; exc_rs <= rstate;
		exc_go(`VEC_BUSERR, boundary ? `FMT_SHORTBUS : `FMT_LONGBUS, boundary ? scan_pc : pc_i, 32'd0);
	end
endtask

// a posted write that failed, reported at a boundary
task exc_late_fault;
	begin
		late_fault_pend <= 1'b0;
		capture_pipe;
		exc_got <= 3'd0; exc_partial <= 32'd0;
		exc_ssw <= {1'b0, 1'b0, ~w0_v | w0_f, ~w1_v | w1_f, 3'b000, exc_ssw[8:0]};
		exc_rk <= RK_BOUNDARY; exc_rs <= S_FETCH;
		exc_go(`VEC_BUSERR, `FMT_SHORTBUS, scan_pc, 32'd0);
	end
endtask

// instruction stream fault: the word(s) needed are marked faulted
task exc_stream_fault;
	input need_b;      // the instruction also needed stage B
	input boundary;
	begin
		capture_pipe;
		exc_fa <= 32'd0; exc_dob <= 32'd0; exc_got <= 3'd0; exc_partial <= 32'd0;
		exc_ssw <= {w0_f, need_b & w1_f, ~w0_v | w0_f, ~w1_v | w1_f, 3'b000, 1'b0, 1'b0, 1'b1, 2'b00, 1'b0, fc_prog};
		exc_rk <= boundary ? RK_BOUNDARY : RK_STREAM;
		exc_rs <= state;
		exc_go(`VEC_BUSERR, `FMT_LONGBUS, boundary ? scan_pc : pc_i, 32'd0);
	end
endtask

// address error: prefetch from an odd address (UM 8.1.3)
task exc_addr_err;
	input [31:0] target;
	begin
		exc_stage_c <= 16'd0; exc_stage_b <= 16'd0;
		exc_baddr <= target + 32'd2;
		exc_fa <= 32'd0; exc_dob <= 32'd0; exc_got <= 3'd0; exc_partial <= 32'd0;
		exc_ssw <= {1'b0, 1'b0, 1'b1, 1'b1, 3'b000, 1'b0, 1'b0, 1'b1, 2'b00, 1'b0, fc_prog};
		exc_rk <= RK_BOUNDARY; exc_rs <= S_FETCH;
		exc_go(`VEC_ADDRERR, `FMT_LONGBUS, pc_i, 32'd0);
	end
endtask

// pop k words of the pipe (the caller checked they are present)
task pop; input [1:0] k; begin pop_n = k; end endtask

// consume an immediate/extension longword or word into imm (sign extended
// when asked); returns 0 when the words are not there yet or faulted
function pipe_ready;
	input two;
	begin
		pipe_ready = two ? have2 : w0_v;
	end
endfunction
function pipe_faulted;
	input two;
	begin
		pipe_faulted = two ? ((w0_v & w0_f) | (w1_v & w1_f) | (w0_v & !w0_f & w1_v & w1_f)) : (w0_v & w0_f);
	end
endfunction

// dispatch the next instruction from pq[0]
task dispatch;
	begin
		dbg_inst <= 1'b1;
		ir <= w0;
		ext <= w1;
		pc_i <= scan_pc;
		pop(dc_needs_ext ? 2'd2 : 2'd1);
		tr_t1 <= sr[`SR_T1];
		tr_t0 <= sr[`SR_T0];
		flow <= 1'b0;
		ea_sel <= 1'b0;
		ea_pc <= 1'b0;
		imm_tgt <= 1'b0;
		status_cnt <= 2'd1;
		// generic-path controls, so the decoder can look at the next word
		// while this instruction executes
		g_alu <= dc_alu; g_size <= dc_size; g_srck <= dc_srck; g_dstk <= dc_dstk; g_dreg <= dc_dreg; g_sreg <= dc_sreg;
		g_flags <= dc_flags; g_wb <= dc_wb; g_sext <= dc_sext; g_bitop <= dc_bitop; g_shift <= dc_shift;
		g_move_mem <= dc_move_mem; g_dstrd <= dc_dstrd;
		nx <= dc_first;
		// register operands (with the bypass of a write applied this clock)
		if (dc_srck == SK_REG) src <= (byp_we && byp_reg == dc_sreg) ? byp_data : rf_d;
		else if (dc_srck == SK_QUICK) src <= dc_quick;
		if (dc_dstk == DK_REG) dst <= (byp_we && byp_reg == dc_dreg) ? byp_data : rf_e;
		// exceptions detected at dispatch stack this instruction's address,
		// which is scan_pc in this clock (pc_i is being updated)
		if (dc_illegal) begin
			if (w0[15:12] == 4'hA) exc_go(`VEC_ALINE, `FMT_NORMAL, scan_pc, 32'd0);
			else if (w0[15:12] == 4'hF) begin
				if (!sr_s && w0[11:9] == 3'd0) exc_go(`VEC_PRIV, `FMT_NORMAL, scan_pc, 32'd0);
				else exc_go(`VEC_FLINE, `FMT_NORMAL, scan_pc, 32'd0);
			end else exc_go(`VEC_ILLEGAL, `FMT_NORMAL, scan_pc, 32'd0);
		end else if (dc_priv && !sr_s) begin
			exc_go(`VEC_PRIV, `FMT_NORMAL, scan_pc, 32'd0);
		end else if (dc_srck == SK_IMM) begin
			state <= S_IMM;
			imm_ret <= dc_move_mem ? S_MOVE_DEA : (dc_dstk == DK_EA) ? S_EA : (dc_dstk == DK_IMM) ? S_IMM : dc_first;
			ea_ret <= dc_dstrd ? S_GEN_RD : dc_first;
		end else if (dc_srck == SK_EA) begin
			state <= S_EA;
			ea_ret <= S_GEN_RD;
		end else if (dc_dstk == DK_EA) begin
			if (dc_move_mem) state <= S_MOVE_DEA;
			else begin state <= S_EA; ea_ret <= dc_dstrd ? S_GEN_RD : dc_first; end
		end else if (dc_dstk == DK_IMM) begin
			state <= S_IMM; imm_tgt <= 1'b1; imm_ret <= dc_first;
		end else if (dc_eaonly) begin
			state <= S_EA; ea_ret <= dc_first;
		end else begin
			state <= dc_first;
		end
	end
endtask
