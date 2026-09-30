// AP68030 core - states part B: exceptions, RTE, MOVEM, MUL/DIV, CHK2/CMP2,
// CAS/CAS2, bit fields

//-------------------------------------------------------------- exception processing (UM 8.1)
S_EXC0: begin : exc0
	reg [31:0] base;
	reg use_msp;
	exc_active <= 1'b1;
	use_msp = exc_throw ? 1'b0 : sr_m;
	base = (use_msp ? msp_q : isp_q) - {frame_lw(exc_fmt), 2'b00};
	if (!exc_throw) begin
		// step 1: S set, tracing off, interrupt mask for interrupts
		sr[15:14] <= 2'b00;
		sr[13] <= 1'b1;
		if (exc_is_irq) sr[10:8] <= exc_ilvl;
	end
	exc_sp <= base;
	sp_we <= 1'b1; sp_sel <= use_msp ? 2'd2 : 2'd1; sp_wdata <= base;
	cnt <= 8'd0;
	state <= S_EXC1;
end
S_EXC1: begin
	// push the frame as longwords, ascending
	if (cnt[5:0] < frame_lw(exc_fmt)) begin
		cnt <= cnt + 8'd1;
		wr_sd(exc_sp + {cnt[5:0], 2'b00}, `SZ_L, {frame_word({cnt[4:0], 1'b0}), frame_word({cnt[4:0], 1'b1})}, S_EXC1);
	end else state <= S_EXC3;
end
S_EXC3: begin
	if (exc_is_irq && exc_sr[`SR_M] && !exc_throw) begin
		// UM 8.1.9: M set -- a throwaway frame goes on the interrupt stack
		exc_throw <= 1'b1;
		exc_fmt <= `FMT_THROWAWAY;
		sr[12] <= 1'b0;
		state <= S_EXC0;
	end else state <= S_EXC2;
end
S_EXC2: begin
	rd_sd(vbr + {22'd0, exc_vec, 2'b00}, `SZ_L, DW_TMP, S_EXC4);
	// system option: the level 7 autovector is always read from the bus, so
	// an external overlay of it (an Amiga freezer cartridge) is never missed
	if (nmi_vec_nocache && exc_vec == `VEC_AUTOVEC + 8'd7) d_nocache <= 1'b1;
end
S_EXC4: begin
	exc_active <= 1'b0; exc_is_irq <= 1'b0; exc_throw <= 1'b0; exc_busfault <= 1'b0;
	if (trace_after_exc) begin trace_pend <= 1'b1; trace_after_exc <= 1'b0; end
	pc_i <= tmp;
	if (tmp[0]) begin
		// odd vector: address error (a double fault while processing a bus fault)
		if (exc_busfault) begin halted_r <= 1'b1; state <= S_HALT; end
		else begin
			exc_addr_err(tmp);
			// the frame's PC is the vector offset of the exception being
			// processed (WinUAE cputest doexcstack, 68020+; 68030 corpus v24)
			exc_pc <= {22'd0, exc_vec, 2'b00};
		end
	end else begin
		flush_req = 1'b1; flush_pc = tmp;
		state <= S_FETCH;
	end
end

//-------------------------------------------------------------- RTE (UM 8.1.13, 8.2.3)
S_RTE0: rd_sd(rf_c, `SZ_L, DW_TMP, S_RTE1);
S_RTE1: rd_sd(rf_c + 32'd4, `SZ_L, DW_TMP2, S_RTE2);
S_RTE2: begin
	case (tmp2[15:12])
		`FMT_NORMAL: begin
			sr <= tmp[31:16] & `SR_MASK;
			wreg(4'd15, rf_c + 32'd8);
			go_pc({tmp[15:0], tmp2[31:16]});
			// an odd PC faults after the SR is restored: the address error
			// frame holds the SR from the RTE frame (WinUAE 68030 AE corpus)
			if (tmp2[16]) exc_sr <= tmp[31:16] & `SR_MASK;
		end
		`FMT_THROWAWAY: begin
			// SR from the frame, then RTE again on the (possibly different) stack
			sr <= tmp[31:16] & `SR_MASK;
			wreg(4'd15, rf_c + 32'd8);
			state <= S_RTE0;
		end
		`FMT_SIXWORD: begin
			sr <= tmp[31:16] & `SR_MASK;
			wreg(4'd15, rf_c + 32'd12);
			go_pc({tmp[15:0], tmp2[31:16]});
			// an odd PC faults after the SR is restored: the address error
			// frame holds the SR from the RTE frame (WinUAE 68030 AE corpus)
			if (tmp2[16]) exc_sr <= tmp[31:16] & `SR_MASK;
		end
		`FMT_CPMID, `FMT_SHORTBUS, `FMT_LONGBUS: begin
			fr[0] <= tmp; fr[1] <= tmp2;
			cnt <= 8'd2;
			exc_busfault <= 1'b1;        // a fault while loading internal state halts (UM 8.1.13)
			state <= S_RTE3;
		end
		default: begin
			// the MC68030 clears T1/T0 before the format error: its frame
			// stacks SR without them (WinUAE gencpu, 68030 corpus)
			exc_pre(`VEC_FMTERR);
			exc_sr <= {2'b00, sr[13:0]};
			sr[15:14] <= 2'b00;
		end
	endcase
end
S_RTE3: begin
	if (cnt[5:0] < frame_lw(fr[1][15:12])) rd_sd(rf_c + {cnt[5:0], 2'b00}, `SZ_L, DW_FRAME, S_RTE3);
	else state <= S_RTE4;
end
S_RTE4: begin : rte4
	reg [3:0] fmt;
	fmt = fr[1][15:12];
	exc_busfault <= 1'b0;
	if (fmt == `FMT_LONGBUS && frw[6'd27][15:12] != 4'h0) begin
		exc_pre(`VEC_FMTERR);            // version mismatch (UM 8.1.8)
		exc_sr <= {2'b00, sr[13:0]};     // T1/T0 cleared, as for any format error
		sr[15:14] <= 2'b00;
	end else begin
		sr <= fr_word(6'd0) & `SR_MASK;
		wreg(4'd15, rf_c + {frame_lw(fmt), 2'b00});
		exc_pc <= fr_long(6'd1);
		exc_ssw <= fr_word(6'd5);
		case (fmt)
			`FMT_CPMID: begin
				pc_i <= fr_long(6'd4);
				ir <= fr_word(6'd7);
				ea <= fr_long(6'd8);
				{cp_kind, cp_id, cp_cond, cp_dr, cp_ca, cp_pcbit, cp_trace_wait} <= frw[6'd6][15:4];
				cp_base <= {14'd0, 1'b1, 1'b0, frw[6'd6][11:9], 13'd0};
				tr_t1 <= frw[6'd0][15]; tr_t0 <= frw[6'd0][14];
				exc_rk <= RK_BOUNDARY;
				state <= S_RTE_PIPE;
			end
			`FMT_SHORTBUS: begin
				exc_rk <= RK_BOUNDARY;
				exc_fa <= fr_long(6'd8); exc_dob <= fr_long(6'd12);
				state <= S_RTE_PIPE;
			end
			default: begin
				exc_rk <= frw[6'd4][15:12];
				exc_rs <= frw[6'd4][7:0];
				pc_i <= fr_long(6'd1);
				ea <= fr_long(6'd10);
				exc_fa <= fr_long(6'd8); exc_dob <= fr_long(6'd12); exc_dib <= fr_long(6'd22);
				src <= fr_long(6'd14); dst <= fr_long(6'd16);
				exc_baddr <= fr_long(6'd18);
				imm <= fr_long(6'd20);
				tmp <= fr_long(6'd24);
				ir <= fr_word(6'd26);
				dw_dst <= frw[6'd27][11:8]; dw_ret <= frw[6'd27][7:0];
				tmp2 <= fr_long(6'd28); ea2 <= fr_long(6'd30);
				cnt <= frw[6'd32][15:8]; sub <= frw[6'd32][7:0];
				mm_mask <= fr_word(6'd33);
				tmp3 <= {16'd0, fr_word(6'd34)};
				{ea_sel, imm_tgt, dw_reg} <= frw[6'd35][15:10]; ea_ret <= frw[6'd35][7:0];
				ea_pc <= frw[6'd35][8];
				exc_got <= frw[6'd36][15:13]; imm_ret <= frw[6'd36][7:0];
				exc_partial <= fr_long(6'd37);
				ext <= fr_word(6'd39);
				{tr_t1, tr_t0, flow, cp_cond, cp_dr, cp_ca, cp_pcbit, cp_trace_wait, cp_kind, cp_id} <= frw[6'd40][15:1];
				{cp_len, cp_pos} <= fr_word(6'd41);
				cp_base <= fr_long(6'd42);
				cp_resp <= fr_word(6'd44);
				state <= S_RTE_PIPE;
			end
		endcase
	end
end
S_RTE_PIPE: begin : rte_pipe
	// the pipe: stage images from the frame unless their rerun bits are set,
	// then the continuation (UM 8.2.1): DF reruns the data cycle
	reg [3:0] fmt;
	fmt = fr[1][15:12];
	// generic-path controls of the resumed instruction (ir is restored now)
	g_alu <= dc_alu; g_size <= dc_size; g_srck <= dc_srck; g_dstk <= dc_dstk; g_dreg <= dc_dreg; g_sreg <= dc_sreg;
	g_flags <= dc_flags; g_wb <= dc_wb; g_sext <= dc_sext; g_bitop <= dc_bitop; g_shift <= dc_shift;
	g_move_mem <= dc_move_mem; g_dstrd <= dc_dstrd;
	nx <= dc_first;
	if (fmt == `FMT_CPMID) begin
		flush_req = 1'b1; flush_pc = exc_pc;
		state <= S_CP1;
	end else if (fmt == `FMT_SHORTBUS) begin
		if (exc_ssw[8]) begin
			// rerun the faulted data cycle, then continue at the PC
			dreq(exc_fa, sz_of_siz(exc_ssw[5:4]), exc_ssw[6], exc_dob, exc_ssw[2:0], exc_ssw[7], exc_ssw[7] & ~exc_ssw[6], DW_NONE, S_RTE_RERUN);
			tmp <= exc_pc;
		end else begin
			flush_req = 1'b1; flush_pc = exc_pc; state <= S_FETCH;
		end
	end else begin
		case (exc_rk)
			RK_RMW: begin
				// DF set: rerun the whole instruction; clear: it was emulated
				flush_req = 1'b1;
				flush_pc = exc_ssw[8] ? exc_pc : (exc_baddr - 32'd2);
				state <= S_FETCH;
			end
			RK_BOUNDARY: begin
				// a boundary fault resumes at the PC field, which the handler
				// may have changed (address error repair, UM 8.2.2)
				flush_req = 1'b1; flush_pc = exc_pc;
				state <= S_FETCH;
			end
			default: begin
				pipe_load = 1'b1; flush_pc = exc_baddr - 32'd2;
				pipe_c = fr_word(6'd6); pipe_c_v = ~exc_ssw[13];
				pipe_b = fr_word(6'd7); pipe_b_v = ~exc_ssw[12];
				if (exc_rk == RK_STREAM) state <= exc_rs;
				else if (exc_ssw[8]) begin
					// DF: rerun the data cycle described by the frame
					dreq(exc_fa, sz_of_siz(exc_ssw[5:4]), exc_ssw[6], exc_dob, exc_ssw[2:0], exc_ssw[7], exc_ssw[7] & ~exc_ssw[6], dw_dst, dw_ret);
					rerun_merge <= exc_ssw[6] && (exc_got != 3'd0);
				end else if (exc_rk == RK_READ) begin
					rte_fake <= 1'b1; rte_fake_data <= exc_dib;
					rerun_merge <= (exc_got != 3'd0);
					state <= S_DWAIT;
				end else state <= dw_ret;
			end
		endcase
	end
end
S_RTE_RERUN: begin flush_req = 1'b1; flush_pc = tmp; state <= S_FETCH; end

//-------------------------------------------------------------- MOVEM (PRM)
S_MOVEM0: begin
	if (ir[5:3] == 3'b100) begin
		// -(An): mask bit 0 is A7; descending addresses
		mm_mask <= {ext[0], ext[1], ext[2], ext[3], ext[4], ext[5], ext[6], ext[7],
		            ext[8], ext[9], ext[10], ext[11], ext[12], ext[13], ext[14], ext[15]};
		ea <= rf_a; tmp2 <= rf_a;
	end else begin
		mm_mask <= ext;
		if (ir[5:3] == 3'b011) ea <= rf_a;
	end
	state <= S_MOVEM1;
end
S_MOVEM1: begin : movem1
	reg [3:0] r;
	reg desc;
	reg [31:0] bytes;
	desc = (ir[5:3] == 3'b100);
	bytes = ir[6] ? 32'd4 : 32'd2;
	r = mm_next(mm_mask, desc);
	if (mm_mask == 16'd0) state <= S_MOVEM_LAST;
	else begin
		cnt <= {4'd0, r};
		mm_mask[r] <= 1'b0;
		if (ir[10]) begin
			// memory to registers
			dw_reg <= r;
			ea <= ea + bytes;
			rd(ea, ir[6] ? `SZ_L : `SZ_W, DW_REGL, S_MOVEM1);
		end else if (desc) begin
			ea <= ea - bytes;                    // -(An): the address first
			state <= S_MOVEM2;
		end else begin
			state <= S_MOVEM2;                   // ascending: write, then advance
		end
	end
end
S_MOVEM2: begin : movem2
	// registers to memory: the value read through port A (cnt) this clock;
	// the predecrement base register stores its initial value minus the size
	reg [31:0] v;
	reg desc;
	desc = (ir[5:3] == 3'b100);
	v = (desc && cnt[3:0] == {1'b1, ir[2:0]}) ? (tmp2 - (ir[6] ? 32'd4 : 32'd2)) : rf_a;
	if (!desc) ea <= ea + (ir[6] ? 32'd4 : 32'd2);
	wr(ea, ir[6] ? `SZ_L : `SZ_W, v, S_MOVEM1);
end
S_MOVEM_LAST: begin
	if (ir[5:3] == 3'b011 || ir[5:3] == 3'b100) wreg({1'b1, ir[2:0]}, ea);
	finish;
end

//-------------------------------------------------------------- MUL / DIV
S_MULDIV0: begin : muldiv0
	reg long;
	reg is_div;
	reg sgn;
	long = (ir[15:12] == 4'h4);
	is_div = long ? ir[6] : (ir[15:12] == 4'h8);
	sgn = long ? ext[11] : ir[8];
	if (is_div && ((long ? src : {16'd0, src[15:0]}) == 32'd0)) begin
		state <= S_DIVZ;                    // UM 8.1.4: divide by zero
		// the flags are undefined; the MC68020/030 values (WinUAE
		// divbyzero_special, divsl_divbyzero, divul_divbyzero)
		if (!long) begin
			if (sgn) sr[3:0] <= 4'b0100;
			else sr[3:0] <= {dst[31], dst[31:16] == 16'd0, 1'b1, 1'b0};
		end else if (sgn) begin
			sr[3] <= 1'b0; sr[2] <= 1'b1; sr[0] <= 1'b0;     // V is not changed
		end else
			sr[3:0] <= {rf_a[31], rf_a == 32'd0, 1'b1, 1'b0};
	end else begin
		md_start <= 1'b1;
		md_div <= is_div;
		md_sign <= sgn;
		if (long) begin
			md_a <= src;
			md_lo <= rf_a;                            // Dq
			md_hi <= ext[10] ? rf_b : (sgn ? {32{rf_a[31]}} : 32'd0);   // Dr:Dq for the 64-bit form
			tmp <= rf_a; tmp2 <= rf_b;
		end else begin
			md_a <= sgn ? sext16(src[15:0]) : {16'd0, src[15:0]};
			md_lo <= is_div ? dst : (sgn ? sext16(dst[15:0]) : {16'd0, dst[15:0]});
			md_hi <= (is_div && sgn) ? {32{dst[31]}} : 32'd0;
		end
		state <= S_MULDIVW;
	end
end
S_MULDIVW: if (md_done) state <= S_MULDIV1;
S_MULDIV1: begin : muldiv1
	reg long, is_div, sgn;
	reg [31:0] aquot;
	reg abs_ovf;
	aquot = md_rlo[31] ? (32'd0 - md_rlo) : md_rlo;
	abs_ovf = md_ovf || (aquot[31:16] != 16'd0);
	long = (ir[15:12] == 4'h4);
	is_div = long ? ir[6] : (ir[15:12] == 4'h8);
	sgn = long ? ext[11] : ir[8];
	if (!long) begin
		if (is_div) begin
			// word divide: 16-bit quotient range check
			if (md_ovf || (sgn ? (md_rlo[31:16] != {16{md_rlo[15]}}) : (md_rlo[31:16] != 16'd0))) begin
				// overflow: V set, the rest undefined; the MC68020/030 values
				// (WinUAE setdivuflags/setdivsflags)
				if (!sgn) begin
					sr[1] <= 1'b1;                       // Z and C are not changed
					if (dst[31]) sr[3] <= 1'b1;          // N set by a negative dividend
				end else begin
					// N and Z from the low byte of |quotient| unless the quotient
					// does not fit in 16 bits at all
					sr[1] <= 1'b1; sr[0] <= 1'b0;
					sr[3] <= !abs_ovf && aquot[7];
					sr[2] <= !abs_ovf && (aquot[7:0] == 8'd0);
				end
			end else begin
				wreg({1'b0, ir[11:9]}, {md_rhi[15:0], md_rlo[15:0]});
				sr[3] <= md_rlo[15]; sr[2] <= (md_rlo[15:0] == 16'd0); sr[1] <= 1'b0; sr[0] <= 1'b0;
			end
		end else begin
			wreg({1'b0, ir[11:9]}, md_rlo);
			sr[3] <= md_rlo[31]; sr[2] <= (md_rlo == 32'd0); sr[1] <= 1'b0; sr[0] <= 1'b0;
		end
		finish;
	end else if (is_div) begin
		if (md_ovf) begin
			// overflow: V set, C clear, N and Z undefined; the MC68020/030
			// values (WinUAE divul_overflow/divsl_overflow) from the dividend
			sr[1] <= 1'b1; sr[0] <= 1'b0;
			if (!sgn) begin
				sr[3] <= tmp[31]; sr[2] <= (tmp == 32'd0);
			end else if (ext[10] && tmp2 == 32'd0) begin
				sr[3] <= 1'b0; sr[2] <= 1'b1;
			end else if (ext[10] && tmp2[31] && src[31] && ($signed(tmp2) > $signed(src))) begin
				sr[3] <= 1'b0; sr[2] <= 1'b0;
			end else if (tmp == 32'd0) begin
				sr[3] <= 1'b0; sr[2] <= 1'b1;
			end else begin
				sr[3] <= tmp[31] ^ (ext[10] & tmp2[31]); sr[2] <= 1'b0;
			end
			finish;
		end else begin
			wreg({1'b0, ext[14:12]}, md_rlo);       // Dq = quotient
			sr[3] <= md_rlo[31]; sr[2] <= (md_rlo == 32'd0); sr[1] <= 1'b0; sr[0] <= 1'b0;
			if (ext[2:0] != ext[14:12]) state <= S_MULDIV2;   // Dr = remainder
			else finish;
		end
	end else begin
		wreg({1'b0, ext[14:12]}, md_rlo);           // Dq = low product
		if (ext[10]) begin
			sr[3] <= md_rhi[31]; sr[2] <= (md_rhi == 32'd0) && (md_rlo == 32'd0); sr[1] <= 1'b0; sr[0] <= 1'b0;
			state <= S_MULDIV2;                     // Dr = high product
		end else begin
			sr[3] <= md_rlo[31]; sr[2] <= (md_rlo == 32'd0); sr[0] <= 1'b0;
			sr[1] <= sgn ? (md_rhi != {32{md_rlo[31]}}) : (md_rhi != 32'd0);
			finish;
		end
	end
end
S_MULDIV2: begin wreg({1'b0, ext[2:0]}, md_rhi); finish; end

//-------------------------------------------------------------- CHK2 / CMP2 (PRM)
S_CHK2_0: rd(ea, g_size, DW_SRC, S_CHK2_1);
S_CHK2_1: rd(ea + {29'd0, bytes_of_sz(g_size)}, g_size, DW_DST, S_CHK2_2);
S_CHK2_2: begin : chk2
	reg [31:0] lo, hi, rn;
	reg [3:0] nf;
	if (ext[15]) begin lo = sext_sz(src, g_size); hi = sext_sz(dst, g_size); rn = rf_a; end
	else begin
		case (g_size)
			`SZ_B: begin lo = {24'd0, src[7:0]}; hi = {24'd0, dst[7:0]}; rn = {24'd0, rf_a[7:0]}; end
			`SZ_W: begin lo = {16'd0, src[15:0]}; hi = {16'd0, dst[15:0]}; rn = {16'd0, rf_a[15:0]}; end
			default: begin lo = src; hi = dst; rn = rf_a; end
		endcase
	end
	nf[2] = (rn == lo) || (rn == hi);
	nf[0] = (lo <= hi) ? ((rn < lo) || (rn > hi)) : ((rn > hi) && (rn < lo));
	{nf[3], nf[1]} = chk2_nv(ext[15] ? lo : sext_sz(lo, g_size), ext[15] ? hi : sext_sz(hi, g_size),
	                         ext[15] ? rn : sext_sz(rn, g_size));
	sr[3:0] <= nf;
	if (ext[11] && nf[0]) begin
		exc_go(`VEC_CHK, `FMT_SIXWORD, scan_pc, pc_i);
		exc_sr <= {sr[15:4], nf};       // the frame holds the updated flags
	end else finish;
end

//-------------------------------------------------------------- CAS / CAS2 (UM 7.3.3)
S_CAS0: dreq(ea, g_size, 1'b1, 32'd0, fc_data, 1'b1, 1'b0, DW_DST, S_CAS1);
S_CAS1: begin
	// the compare: its flags are registered, the decision follows a clock
	// later (the register file, the ALU and the decision in one clock is
	// the longest path of the core)
	sr[4:0] <= alu_f;
	state <= S_CAS1B;
end
S_CAS1B: begin
	if (sr[2]) begin
		finish;
		dreq(ea, g_size, 1'b0, rf_b, fc_data, 1'b1, 1'b1, DW_NONE, S_FETCH);
	end else begin
		wreg({1'b0, ext[2:0]}, merge(rf_a, dst, g_size));
		d_rmc_release <= 1'b1;
		finish;
	end
end
S_CAS2_0: begin
	if (!w0_v) ; else if (w0_f) exc_stream_fault(1'b0, 1'b0);
	else begin tmp3 <= {16'd0, w0}; pop(2'd1); state <= S_CAS2_1; end
end
S_CAS2_1: begin ea <= rf_c; tmp3[16] <= 1'b1; state <= S_CAS2_2; end
S_CAS2_2: begin ea2 <= rf_c; tmp3[16] <= 1'b0; dreq(ea, g_size, 1'b1, 32'd0, fc_data, 1'b1, 1'b0, DW_SRC, S_CAS2_3); end
S_CAS2_3: dreq(ea2, g_size, 1'b1, 32'd0, fc_data, 1'b1, 1'b0, DW_DST, S_CAS2_4);
S_CAS2_4: begin
	// operand 1 against Dc1 (flags registered, decision next clock)
	sr[4:0] <= alu_f;
	tmp <= rf_b;                                  // Du1
	state <= S_CAS2_4B;
end
S_CAS2_4B: begin
	if (sr[2]) begin tmp3[16] <= 1'b1; state <= S_CAS2_5; end
	else begin
		wreg({1'b0, ext[2:0]}, merge(rf_a, src, g_size));
		tmp3[16] <= 1'b1; state <= S_CAS2_6;
	end
end
S_CAS2_5: begin
	// operand 2 against Dc2
	sr[4:0] <= alu_f;
	tmp2 <= rf_b;                                 // Du2
	state <= S_CAS2_5B;
end
S_CAS2_5B: begin
	// both equal: operand 2 is written first, then operand 1 (the MC68030
	// order as modelled by WinUAE; visible when the operands overlap)
	if (sr[2]) dreq(ea2, g_size, 1'b0, tmp2, fc_data, 1'b1, 1'b0, DW_NONE, S_CAS2_7);
	else begin
		wreg({1'b0, tmp3[2:0]}, merge(rf_a, dst, g_size));
		tmp3[16] <= 1'b0; state <= S_CAS2_8;
	end
end
// a mismatch loads Dc2 and then Dc1: when both name one register, it
// receives operand 1 (Dc1 was written in S_CAS2_4B and is kept)
S_CAS2_6: begin
	if (tmp3[2:0] != ext[2:0]) wreg({1'b0, tmp3[2:0]}, merge(rf_a, dst, g_size));
	d_rmc_release <= 1'b1; finish;
end
S_CAS2_7: begin finish; dreq(ea, g_size, 1'b0, tmp, fc_data, 1'b1, 1'b1, DW_NONE, S_FETCH); end
S_CAS2_8: begin wreg({1'b0, ext[2:0]}, merge(rf_a, src, g_size)); d_rmc_release <= 1'b1; finish; end

//-------------------------------------------------------------- bit fields (PRM)
S_BF0: begin : bf0
	reg [5:0] w;
	w = ext[5] ? ((rf_c[4:0] == 5'd0) ? 6'd32 : {1'b0, rf_c[4:0]}) : ((ext[4:0] == 5'd0) ? 6'd32 : {1'b0, ext[4:0]});
	tmp <= ext[11] ? rf_b : {27'd0, ext[10:6]};   // offset (signed when from a register)
	cnt <= {2'd0, w};
	tmp2 <= rf_a;                                  // Dn (BFINS source)
	state <= S_BF1;
end
S_BF1: begin : bf1
	reg [31:0] base;
	reg [6:0] total;
	reg [2:0] nb;
	if (ir[5:3] == 3'b000) begin
		dst <= rf_b;                               // the data register operand
		state <= S_BF3;
	end else begin
		base = ea + {{3{tmp[31]}}, tmp[31:3]};
		total = {4'd0, tmp[2:0]} + {1'b0, cnt[5:0]};
		nb = total[5:3] + {2'd0, (total[2:0] != 3'd0)};
		ea <= base;
		sub <= {5'd0, nb};
		rd(base, (nb >= 3'd4) ? `SZ_L : sz_of_bytes(nb), DW_DST, (nb == 3'd5) ? S_BF2 : S_BF3);
	end
end
// the fifth byte goes to src: tmp2 holds the BFINS source register
S_BF2: rd(ea + 32'd4, `SZ_B, DW_SRC, S_BF3);
S_BF3: begin : bf3
	reg [39:0] d40, n40;
	reg [31:0] fld, nfld, rot, rot2;
	reg [5:0] w;
	reg [2:0] nb;
	reg n, z;
	w = cnt[5:0];
	nb = sub[2:0];
	if (ir[5:3] == 3'b000) begin
		rot = rotl32(dst, tmp[4:0]);
		fld = (w >= 6'd32) ? rot : (rot >> (6'd32 - w));
		d40 = 40'd0; n40 = 40'd0;
	end else begin
		d40 = (nb == 3'd5) ? {dst, src[7:0]} : ({dst, 8'd0} << (8 * (3'd4 - nb)));
		fld = bf_extract40(d40, tmp[2:0], w);
		rot = 32'd0;
	end
	case (ir[10:8])
		3'b010: nfld = ~fld;                       // BFCHG
		3'b100: nfld = 32'd0;                      // BFCLR
		3'b110: nfld = 32'hFFFFFFFF;               // BFSET
		3'b111: nfld = tmp2;                       // BFINS
		default: nfld = fld;
	endcase
	nfld = (w >= 6'd32) ? nfld : (nfld & ~(32'hFFFFFFFF << w));
	n = (ir[10:8] == 3'b111) ? nfld[w[4:0] - 5'd1] : fld[w[4:0] - 5'd1];
	z = (ir[10:8] == 3'b111) ? (nfld == 32'd0) : (fld == 32'd0);
	sr[3] <= n; sr[2] <= z; sr[1] <= 1'b0; sr[0] <= 1'b0;
	case (ir[10:8])
		3'b001: begin wreg({1'b0, ext[14:12]}, fld); finish; end                                   // BFEXTU
		3'b011: begin wreg({1'b0, ext[14:12]}, (w >= 6'd32) ? fld : (fld[w[4:0] - 5'd1] ? (fld | (32'hFFFFFFFF << w)) : fld)); finish; end   // BFEXTS
		3'b101: begin wreg({1'b0, ext[14:12]}, tmp + {26'd0, field_lz(fld, w)}); finish; end      // BFFFO
		3'b000: finish;                                                                           // BFTST
		default: begin
			// BFCHG / BFCLR / BFSET / BFINS write back
			if (ir[5:3] == 3'b000) begin
				rot2 = (w >= 6'd32) ? nfld : ((rot & ~topmask(w)) | (nfld << (6'd32 - w)));
				wreg({1'b0, ir[2:0]}, rotr32(rot2, tmp[4:0]));
				finish;
			end else begin
				n40 = bf_insert40(d40, tmp[2:0], w, nfld);
				tmp3 <= {24'd0, n40[7:0]};
				if (nb == 3'd5) wr(ea, `SZ_L, n40[39:8], S_BFWR);
				else begin finish; wr(ea, sz_of_bytes(nb), n40[39:8] >> (8 * (3'd4 - nb)), S_FETCH); end
			end
		end
	endcase
end
S_BFWR: begin finish; wr(ea + 32'd4, `SZ_B, tmp3, S_FETCH); end
