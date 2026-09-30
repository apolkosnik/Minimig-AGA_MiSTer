// AP68030 core - states part A: boundary, data wait, immediates, effective
// addresses, the generic read-operate-write path, MOVE, program flow,
// linkage, and the simpler special instructions

//-------------------------------------------------------------- reset (UM 8.1.1)
S_RESET0: begin
	exc_active <= 1'b1; exc_busfault <= 1'b1; exc_is_reset <= 1'b1;
	status_cnt <= 2'd3;
	dreq(32'd0, `SZ_L, 1'b1, 32'd0, `FC_SUPER_PROG, 1'b0, 1'b0, DW_TMP, S_RESET1);
end
S_RESET1: begin
	sp_we <= 1'b1; sp_sel <= 2'd1; sp_wdata <= tmp;
	dreq(32'd4, `SZ_L, 1'b1, 32'd0, `FC_SUPER_PROG, 1'b0, 1'b0, DW_TMP, S_RESET2);
end
S_RESET2: begin
	exc_busfault <= 1'b0; exc_active <= 1'b0; exc_is_reset <= 1'b0; fetch_hold <= 1'b0;
	pc_i <= tmp;
	if (tmp[0]) begin halted_r <= 1'b1; state <= S_HALT; end
	else begin flush_req = 1'b1; flush_pc = tmp; state <= S_FETCH; end
end
S_HALT: begin
	halted_r <= 1'b1;
end

//-------------------------------------------------------------- instruction boundary
S_FETCH: begin
	if (late_fault_pend) begin
		exc_late_fault;
	end else if (trace_pend) begin
		trace_pend <= 1'b0;
		status_cnt <= 2'd2;
		exc_go(`VEC_TRACE, `FMT_SIXWORD, scan_pc, pc_i);
	end else if (irq_pend) begin
		stopped <= 1'b0;
		status_cnt <= 2'd2;
		exc_ilvl <= irq_lvl;
		state <= S_IACK;
	end else if (stopped) begin
		// STOP: wait for an interrupt (UM 8.1.7 / PRM STOP)
	end else if (w0_v) begin
		if (w0_f) exc_stream_fault(1'b0, 1'b1);
		else if (dc_needs_ext && !w1_v) ;                    // second word not yet here
		else if (dc_needs_ext && w1_f) exc_stream_fault(1'b1, 1'b1);
		else dispatch;
	end
end

//-------------------------------------------------------------- interrupt acknowledge (UM 7.4.1)
S_IACK: begin
	d_stb <= 1'b1; d_iack <= 1'b1;
	d_addr <= {28'hFFFFFFF, 1'b1, exc_ilvl}; d_addr[0] <= 1'b1; d_addr[3:1] <= exc_ilvl;
	d_size <= `SZ_B; d_rw <= 1'b1; d_fc <= `FC_CPU_SPACE; d_rmc <= 1'b0; d_rmc_last <= 1'b0; d_wdata <= 32'd0;
	dw_dst <= DW_TMP; dw_ret <= S_EXC0;
	ipend_r <= 1'b0;
	state <= S_DWAIT;
end

//-------------------------------------------------------------- data access wait
S_DWAIT: begin
	if (d_iack && (d_ack || d_iack_berr)) begin
		// interrupt vector: supplied, autovector, or spurious (bus error)
		d_iack <= 1'b0;
		// a coprocessor busy/not-ready service stacks the instruction's own
		// address so that it restarts (UM 10.4.3); otherwise the next one
		exc_go(d_iack_berr ? `VEC_SPURIOUS : (d_avec ? (`VEC_AUTOVEC + {5'd0, exc_ilvl}) : d_rdata[7:0]),
		       `FMT_NORMAL, iack_pc_i ? pc_i : scan_pc, 32'd0);
		iack_pc_i <= 1'b0;
		exc_is_irq <= 1'b1;
		if (exc_ilvl == 3'd7) irq_taken7 <= 1'b1;
	end else if (rte_fake || d_ack) begin : deliver
		reg [31:0] data;
		reg  [1:0] dsz;
		data = rte_fake ? rte_fake_data : d_rdata;
		dsz  = d_size;
		if (rerun_merge) begin
			// UM 8.2.1: a rerun of the second portion completes the operand;
			// the rerun moves the SSW SIZE bytes, the operand is those plus
			// the bytes already read
			data = (exc_partial << (8 * bytes_of_sz(sz_of_siz(exc_ssw[5:4])))) | data;
			dsz  = sz_of_bytes(exc_got + bytes_of_sz(sz_of_siz(exc_ssw[5:4])));
			rerun_merge <= 1'b0;
		end
		rte_fake <= 1'b0;
		case (dw_dst)
			DW_SRC:  src <= data;
			DW_DST:  dst <= data;
			DW_TMP:  tmp <= data;
			DW_TMP2: tmp2 <= data;
			DW_EA:   ea <= data;
			DW_IMM:  imm <= data;
			DW_REG:  wreg(dw_reg, merge(dst, data, dsz));
			DW_REGL: wreg(dw_reg, sext_sz(data, dsz));
			DW_SR:   sr <= data[15:0] & `SR_MASK;
			DW_FRAME: begin fr[cnt[4:0]] <= data; cnt <= cnt + 8'd1; end
			default: ;
		endcase
		state <= dw_ret;
	end else if (d_fault) begin
		if (exc_busfault) begin
			// UM 7.5.4: double bus fault
			halted_r <= 1'b1; state <= S_HALT;
		end else if (cpu_flt_ill) begin
			cpu_flt_ill <= 1'b0; exc_pre(`VEC_ILLEGAL);           // BKPT acknowledge terminated by BERR
		end else if (cpu_flt_fline) begin
			cpu_flt_fline <= 1'b0; exc_pre(`VEC_FLINE);           // no coprocessor answered (UM 10.5.2.8)
		end else if (exc_active) begin
			exc_data_fault(1'b1, RK_BOUNDARY, S_FETCH);
		end else begin
			// an RMW fault is rerun as a whole instruction, or the instruction
			// counts as emulated when DF is cleared (UM 8.2.2)
			exc_data_fault(1'b0, d_rmc ? RK_RMW : d_rw ? RK_READ : RK_WRITE, S_DWAIT);
		end
	end
end

//-------------------------------------------------------------- immediate operand
S_IMM: begin : imm_state
	reg two;
	two = !imm_tgt && (g_size == `SZ_L) && !g_bitop;
	if (!pipe_ready(two)) ;
	else if (pipe_faulted(two)) exc_stream_fault(two, 1'b0);
	else begin
		if (imm_tgt) dst <= {24'd0, w0[7:0]};
		else if (g_bitop) src <= {24'd0, w0[7:0]};      // bit number: one word, low byte
		else if (two) src <= {w0, w1};
		else if (g_size == `SZ_B) src <= {24'd0, w0[7:0]};
		else src <= {16'd0, w0};
		pop(two ? 2'd2 : 2'd1);
		imm_tgt <= 1'b1;
		state <= imm_ret;
	end
end

//-------------------------------------------------------------- effective address (PRM 2.2)
S_EA: begin : ea_state
	reg [31:0] bytes;
	bytes = size_bytes(g_size, ea_regn == 3'd7);
	ea_pc <= ea_pcrel;          // the reads that follow use program space for PC-relative modes
	case (ea_mode)
		3'b010: begin ea <= rf_a; state <= ea_ret; end
		3'b011: begin
			ea <= rf_a; wreg({1'b1, ea_regn}, rf_a + bytes); state <= ea_ret;
			// a register destination that is this base register sees the update
			if (g_dstk == DK_REG && g_dreg == {1'b1, ea_regn}) dst <= rf_a + bytes;
		end
		3'b100: begin
			ea <= rf_a - bytes; wreg({1'b1, ea_regn}, rf_a - bytes); state <= ea_ret;
			if (g_dstk == DK_REG && g_dreg == {1'b1, ea_regn}) dst <= rf_a - bytes;
			// MOVE An,-(An) stores the initial value of An: the source is read
			// before the destination address is formed (WinUAE 68030 cputest)
		end
		3'b101: begin
			if (!w0_v) ; else if (w0_f) exc_stream_fault(1'b0, 1'b0);
			else begin ea <= rf_a + sext16(w0); pop(2'd1); state <= ea_ret; end
		end
		3'b110: begin
			if (!w0_v) ; else if (w0_f) exc_stream_fault(1'b0, 1'b0);
			else if (!w0[8]) begin
				ea <= rf_a + sext8(w0[7:0]) + index_val(rf_c, w0);
				pop(2'd1); state <= ea_ret;
			end else begin
				tmp <= w0[7] ? 32'd0 : rf_a;
				tmp2 <= w0[6] ? 32'd0 : index_val(rf_c, w0);
				sub <= w0[7:0];
				pop(2'd1); state <= S_EA_FULL;
			end
		end
		default: begin
			case (ea_regn)
				3'b000: begin
					if (!w0_v) ; else if (w0_f) exc_stream_fault(1'b0, 1'b0);
					else begin ea <= sext16(w0); pop(2'd1); state <= ea_ret; end
				end
				3'b001: begin
					if (!have2) ; else if (pipe_faulted(1'b1)) exc_stream_fault(1'b1, 1'b0);
					else begin ea <= {w0, w1}; pop(2'd2); state <= ea_ret; end
				end
				3'b010: begin
					if (!w0_v) ; else if (w0_f) exc_stream_fault(1'b0, 1'b0);
					else begin ea <= scan_pc + sext16(w0); pop(2'd1); state <= ea_ret; end
				end
				3'b011: begin
					if (!w0_v) ; else if (w0_f) exc_stream_fault(1'b0, 1'b0);
					else if (!w0[8]) begin
						ea <= scan_pc + sext8(w0[7:0]) + index_val(rf_c, w0);
						pop(2'd1); state <= ea_ret;
					end else begin
						tmp <= w0[7] ? 32'd0 : scan_pc;
						tmp2 <= w0[6] ? 32'd0 : index_val(rf_c, w0);
						sub <= w0[7:0];
						pop(2'd1); state <= S_EA_FULL;
					end
				end
				default: begin
					// immediate as a destination address is meaningless; illegal
					go_illegal;
				end
			endcase
		end
	endcase
end

S_EA_FULL: begin : ea_full
	// base displacement per BD SIZE, then the indirection of PRM Table 2-2
	reg [31:0] bd;
	reg ok, flt, two;
	case (sub[5:4])
		2'b10: begin two = 1'b0; ok = w0_v; flt = w0_v & w0_f; bd = sext16(w0); end
		2'b11: begin two = 1'b1; ok = have2; flt = pipe_faulted(1'b1); bd = {w0, w1}; end
		default: begin two = 1'b0; ok = 1'b1; flt = 1'b0; bd = 32'd0; end
	endcase
	if (!ok) ;
	else if (flt) exc_stream_fault(two, 1'b0);
	else begin
		if (sub[5:4] == 2'b10) pop(2'd1);
		else if (sub[5:4] == 2'b11) pop(2'd2);
		if (sub[2:0] == 3'b000) begin
			ea <= tmp + bd + tmp2;
			state <= ea_ret;
		end else begin
			// memory indirect: preindexed unless IS=1 or I/IS[2]=1 (postindexed)
			tmp <= tmp + bd + ((!sub[6] && !sub[2]) ? tmp2 : 32'd0);
			rd(tmp + bd + ((!sub[6] && !sub[2]) ? tmp2 : 32'd0), `SZ_L, DW_EA, S_EA_IND);
		end
	end
end

S_EA_IND: begin : ea_ind_blk
	// outer displacement per I/IS[1:0]; postindexing adds the index now
	reg [31:0] od;
	reg ok, flt, two;
	case (sub[1:0])
		2'b10: begin two = 1'b0; ok = w0_v; flt = w0_v & w0_f; od = sext16(w0); end
		2'b11: begin two = 1'b1; ok = have2; flt = pipe_faulted(1'b1); od = {w0, w1}; end
		default: begin two = 1'b0; ok = 1'b1; flt = 1'b0; od = 32'd0; end
	endcase
	if (!ok) ;
	else if (flt) exc_stream_fault(two, 1'b0);
	else begin
		if (sub[1:0] == 2'b10) pop(2'd1);
		else if (sub[1:0] == 2'b11) pop(2'd2);
		ea <= ea + od + ((!sub[6] && sub[2]) ? tmp2 : 32'd0);
		state <= ea_ret;
	end
end

//-------------------------------------------------------------- generic path
S_GEN_RD: begin
	rd(ea, g_size, (g_srck == SK_EA) ? DW_SRC : DW_DST, g_move_mem ? S_MOVE_DEA : nx);
end

S_GEN_EXEC: begin : gen_exec
	reg can_overlap;
	if (g_alu_shift && !sh_wait) begin
		// the shifter works from registered operands: its result is valid
		// in the next clock
		sh_wait <= 1'b1;
	end else begin
		sh_wait <= 1'b0;
		if (g_flags) sr[4:0] <= alu_f;
		if (g_dstk == DK_REG && g_wb) wreg(g_dreg, g_dreg[3] ? alu_r : merge(dst, alu_r, g_size));
		if (g_dstk == DK_EA && g_wb) begin
			finish;
			wr(ea, g_size, alu_r, S_FETCH);
		end else begin
			// the next instruction can be dispatched in this clock when nothing
			// else has to happen at the boundary
			can_overlap = !tr_t1 && !(tr_t0 & flow) && !irq_pend && !late_fault_pend && !stopped &&
			              w0_v && !w0_f && !(dc_needs_ext && (!w1_v || w1_f));
			if (can_overlap) begin
				dispatch;
				// an exception taken at that dispatch (illegal, privilege,
				// A/F-line) stacks the SR this instruction leaves behind
				if (g_flags) exc_sr[4:0] <= alu_f;
			end else finish;
		end
	end
end

//-------------------------------------------------------------- MOVE to memory
S_MOVE_DEA: begin
	ea_sel <= 1'b1; ea_ret <= S_MOVE_WR; state <= S_EA;
end
S_MOVE_WR: begin
	sr[4:0] <= alu_f;      // ALU op MOVE on the source
	finish;
	wr(ea, g_size, src, S_FETCH);
end

//-------------------------------------------------------------- LEA / PEA
S_LEA: begin wreg({1'b1, ir[11:9]}, ea); finish; end
S_PEA: begin wreg(4'd15, rf_c - 32'd4); finish; wr(rf_c - 32'd4, `SZ_L, ea, S_FETCH); end

//-------------------------------------------------------------- Bcc / BRA / BSR
S_BCC: begin : bcc_state
	reg [31:0] target, ret;
	reg ok, flt, two;
	reg [1:0] npop;
	if (ir[7:0] == 8'h00) begin two = 1'b0; ok = w0_v; flt = w0_v & w0_f; target = scan_pc + sext16(w0); npop = 2'd1; end
	else if (ir[7:0] == 8'hFF) begin two = 1'b1; ok = have2; flt = pipe_faulted(1'b1); target = scan_pc + {w0, w1}; npop = 2'd2; end
	else begin two = 1'b0; ok = 1'b1; flt = 1'b0; target = scan_pc + sext8(ir[7:0]); npop = 2'd0; end
	ret = scan_pc + {29'd0, npop, 1'b0};
	if (!ok) ;
	else if (flt) exc_stream_fault(two, 1'b0);
	else if (ir[11:8] == 4'h1) begin
		// BSR: push the return address, then branch
		pop(npop);
		ea <= target;
		wreg(4'd15, rf_c - 32'd4);
		wr(rf_c - 32'd4, `SZ_L, ret, S_JMP);
	end else if (ir[11:8] == 4'h0 || cc_true(ir[11:8], sr[4:0])) begin
		pop(npop);
		go_pc(target);
	end else begin
		pop(npop);
		finish;
	end
end

//-------------------------------------------------------------- JMP / JSR / RTS / RTR / RTD
// an odd target: the address error frame's PC is the instruction + 2 for
// JMP and the target for JSR (WinUAE gencpu, 68030 AE corpus v24)
S_JMP: begin
	go_pc(ea);
	// JMP: instruction + 2; the 68020+ index modes have already consumed
	// their extension words, so the end of the instruction + 2 for them
	if (ea[0] && ir[15:6] == 10'b0100_1110_11)
		exc_pc <= (ir[5:3] == 3'b110 || ir[5:0] == 6'b111011) ? scan_pc + 32'd2 : pc_i + 32'd2;
	if (ea[0] && ir[15:6] == 10'b0100_1110_10) exc_pc <= ea;             // JSR
end
S_JSR: begin
	wreg(4'd15, rf_c - 32'd4);
	wr(rf_c - 32'd4, `SZ_L, scan_pc, S_JMP);
end
S_RTS: rd(rf_c, `SZ_L, DW_TMP, S_RTS2);
S_RTS2: begin
	wreg(4'd15, rf_c + 32'd4);
	go_pc(tmp);
	if (tmp[0] && ir[2:0] == 3'd7) exc_pc <= pc_i + 32'd2;   // RTR: instruction + 2
end
S_RTR: rd(rf_c, `SZ_W, DW_TMP2, S_RTR2);
S_RTR2: begin
	sr[4:0] <= tmp2[4:0];
	wreg(4'd15, rf_c + 32'd2);
	rd(rf_c + 32'd2, `SZ_L, DW_TMP, S_RTS2);
end
S_RTD: begin
	// the displacement was popped with the opcode (ext)
	tmp2 <= sext16(ext);
	rd(rf_c, `SZ_L, DW_TMP, S_RTD2);
end
S_RTD2: begin wreg(4'd15, rf_c + 32'd4 + tmp2); go_pc(tmp); end

//-------------------------------------------------------------- DBcc / Scc / TRAPcc / TRAPV
S_DBCC: begin : dbcc_state
	// the displacement (ext) is relative to its own address, pc_i + 2
	reg [15:0] nw;
	nw = rf_a[15:0] - 16'd1;
	if (cc_true(ir[11:8], sr[4:0])) finish;
	else begin
		wreg({1'b0, ir[2:0]}, {rf_a[31:16], nw});
		// the MC68020/030 prefetch from the branch target whenever the
		// condition is false, so an odd displacement is an address error
		// even when the count expires (WinUAE gencpu DBcc, 68030 AE corpus)
		if (nw != 16'hFFFF || ext[0]) begin
			go_pc(pc_i + 32'd2 + sext16(ext));
			if (ext[0]) exc_pc <= pc_i + 32'd2 + sext16(ext);   // the frame's PC is the target
		end
		else finish;
	end
end
S_SCC: begin : scc_state
	reg [7:0] v;
	v = cc_true(ir[11:8], sr[4:0]) ? 8'hFF : 8'h00;
	if (ir[5:3] == 3'b000) begin wreg({1'b0, ir[2:0]}, {dst[31:8], v}); finish; end
	else begin finish; wr(ea, `SZ_B, {24'd0, v}, S_FETCH); end
end
S_TRAPCC: begin : trapcc_state
	reg [1:0] npop;
	reg ok, flt, two;
	if (ir[15:12] == 4'h4) begin npop = 2'd0; ok = 1'b1; flt = 1'b0; two = 1'b0; end       // TRAPV
	else if (ir[2:0] == 3'b010) begin npop = 2'd1; ok = w0_v; flt = w0_v & w0_f; two = 1'b0; end
	else if (ir[2:0] == 3'b011) begin npop = 2'd2; ok = have2; flt = pipe_faulted(1'b1); two = 1'b1; end
	else begin npop = 2'd0; ok = 1'b1; flt = 1'b0; two = 1'b0; end
	if (!ok) ;
	else if (flt) exc_stream_fault(two, 1'b0);
	else begin
		pop(npop);
		if (cc_true((ir[15:12] == 4'h4) ? 4'h9 : ir[11:8], sr[4:0]))
			exc_go(`VEC_TRAPCC, `FMT_SIXWORD, scan_pc + {29'd0, npop, 1'b0}, pc_i);
		else finish;
	end
end

//-------------------------------------------------------------- LINK / UNLK
S_LINK: begin : link_state
	// LINK.W: the displacement is ext; LINK.L: ext is its high word, the low word follows
	reg two;
	reg [31:0] disp;
	two = (g_size == `SZ_L);
	disp = two ? {ext, w0} : sext16(ext);
	if (two && !w0_v) ; else if (two && w0_f) exc_stream_fault(1'b0, 1'b0);
	else begin
		if (two) pop(2'd1);
		imm <= disp;
		tmp <= rf_c - 32'd4;
		// LINK A7 pushes the initial A7 on the 68020/030 (only the 68040
		// pushes the decremented value; WinUAE gencpu and 68030 cputest)
		wr(rf_c - 32'd4, `SZ_L, rf_a, S_LINK2);
	end
end
S_LINK2: begin wreg({1'b1, ir[2:0]}, tmp); state <= S_LINK3; end
S_LINK3: begin wreg(4'd15, tmp + imm); finish; end
S_UNLK: begin tmp <= rf_a; rd(rf_a, `SZ_L, DW_TMP2, S_UNLK2); end
S_UNLK2: begin wreg({1'b1, ir[2:0]}, tmp2); state <= S_UNLK3; end
S_UNLK3: begin if (ir[2:0] != 3'd7) wreg(4'd15, tmp + 32'd4); finish; end

//-------------------------------------------------------------- MOVE USP / from SR,CCR / to SR,CCR
S_MOVE_USP: begin
	if (ir[3]) wreg({1'b1, ir[2:0]}, usp_q);
	else begin sp_we <= 1'b1; sp_sel <= 2'd0; sp_wdata <= rf_a; end
	finish;
end
S_MOVE_FSR: begin : movefsr
	reg [15:0] v;
	v = (ir[11:9] == 3'b000) ? sr : {8'd0, sr[7:0]};
	if (ir[5:3] == 3'b000) begin wreg({1'b0, ir[2:0]}, {dst[31:16], v}); finish; end
	else begin finish; wr(ea, `SZ_W, {16'd0, v}, S_FETCH); end
end
S_MOVE_SR: begin : movesr
	reg [15:0] nsr;
	reg is_sr;
	is_sr = (ir[15:12] == 4'h4) ? ir[9] : ir[6];        // MOVE to SR ($46C0) / ORI etc. with word size
	case (g_alu)
		`ALU_OR:  nsr = sr | src[15:0];
		`ALU_AND: nsr = sr & src[15:0];
		`ALU_EOR: nsr = sr ^ src[15:0];
		default:  nsr = src[15:0];
	endcase
	// T0 traces ORI/ANDI/EORI to CCR and SR and MOVE to SR, whatever
	// they change; MOVE to CCR is not traced by T0 (WinUAE gencpu
	// check_trace, 68020/68030; 68030 corpus v24)
	if (!is_sr) begin
		sr[4:0] <= nsr[4:0];
		finish;
		if (ir[15:12] != 4'h4) trace_pend <= tr_t1 | tr_t0;
	end else begin
		sr <= nsr & `SR_MASK;
		// the program space may have changed: refill the pipe (UM 12.7.1)
		flush_req = 1'b1; flush_pc = scan_pc;
		trace_pend <= tr_t1 | tr_t0;
		state <= S_FETCH;
	end
end

//-------------------------------------------------------------- MOVEC (PRM)
S_MOVEC: begin : movec_state
	reg [31:0] v;
	reg bad;
	bad = 1'b0;
	case (ext[11:0])
		12'h000: v = {29'd0, sfc};
		12'h001: v = {29'd0, dfc};
		12'h002: v = cacr;
		12'h800: v = usp_q;
		12'h801: v = vbr;
		12'h802: v = caar;
		12'h803: v = msp_q;
		12'h804: v = isp_q;
		default: begin v = 32'd0; bad = 1'b1; end
	endcase
	if (bad) go_illegal;
	else if (!ir[0]) begin
		wreg({ext[15], ext[14:12]}, v);
		finish;
	end else begin
		case (ext[11:0])
			12'h000: sfc <= rf_a[2:0];
			12'h001: dfc <= rf_a[2:0];
			12'h002: begin
				cacr <= rf_a & `CACR_RDMASK;
				cacr_ci <= rf_a[`CACR_CI]; cacr_cei <= rf_a[`CACR_CEI];
				cacr_cd <= rf_a[`CACR_CD]; cacr_ced <= rf_a[`CACR_CED];
			end
			12'h800: begin sp_we <= 1'b1; sp_sel <= 2'd0; sp_wdata <= rf_a; end
			12'h801: vbr <= rf_a;
			12'h802: caar <= rf_a;
			12'h803: begin sp_we <= 1'b1; sp_sel <= 2'd2; sp_wdata <= rf_a; end
			default: begin sp_we <= 1'b1; sp_sel <= 2'd1; sp_wdata <= rf_a; end
		endcase
		finish;
	end
end

//-------------------------------------------------------------- MOVES (PRM)
S_MOVES0: begin
	if (ext[11]) begin
		// register to <ea> in DFC space
		finish;
		dreq(ea, g_size, 1'b0, rf_a, dfc, 1'b0, 1'b0, DW_NONE, S_FETCH);
	end else begin
		dst <= rf_a;
		dw_reg <= {ext[15], ext[14:12]};
		dreq(ea, g_size, 1'b1, 32'd0, sfc, 1'b0, 1'b0, ext[15] ? DW_REGL : DW_REG, S_MOVES1);
	end
end
S_MOVES1: finish;

//-------------------------------------------------------------- NOP / STOP / RESET / TRAP / BKPT
S_NOP: begin
	if (bus_quiet) finish;      // UM 7.6: NOP synchronizes with pending bus cycles
end
S_STOP: begin
	// the immediate SR value was popped with the opcode (ext)
	sr <= ext & `SR_MASK;
	// a traced STOP does not stop (UM 8.1.7)
	if (tr_t1 || (tr_t0 && ({ext[15:12], ext[10:8]} != {sr[15:12], sr[10:8]}))) trace_pend <= 1'b1;
	else stopped <= 1'b1;
	state <= S_FETCH;
end
S_RESETI: begin
	// UM 7.8: RESET drives the pin for 512 clocks; the CPU's own state is untouched
	if (!reset_drive) begin reset_drive <= 1'b1; rst_cnt <= 10'd511; end
	else if (rst_cnt != 10'd0) rst_cnt <= rst_cnt - 10'd1;
	else begin reset_drive <= 1'b0; finish; end
end
S_TRAP: exc_go(`VEC_TRAP + {4'd0, ir[3:0]}, `FMT_NORMAL, scan_pc, 32'd0);
S_BKPT: begin
	// breakpoint acknowledge cycle (UM 7.4.2): CPU space type 0, number on A2-A4
	cpu_flt_ill <= 1'b1;
	dreq({27'd0, ir[2:0], 2'b00}, `SZ_W, 1'b1, 32'd0, `FC_CPU_SPACE, 1'b0, 1'b0, DW_TMP, S_BKPT2);
end
S_BKPT2: begin
	// the returned word replaces the BKPT in the pipe and executes
	cpu_flt_ill <= 1'b0;
	pipe_load = 1'b1; flush_pc = pc_i;
	pipe_c = tmp[15:0]; pipe_c_v = 1'b1;
	pipe_b = w0; pipe_b_v = w0_v & !w0_f;
	state <= S_FETCH;
end

//-------------------------------------------------------------- EXG
S_EXG: begin tmp <= rf_a; wreg(ra_a, rf_b); state <= S_EXG2; end
S_EXG2: begin wreg(ra_b, tmp); finish; end

//-------------------------------------------------------------- -(Ay),-(Ax) / (Ay)+,(Ax)+ forms and PACK/UNPK
// ABCD/SBCD/ADDX/SUBX -(Ay),-(Ax); CMPM (Ay)+,(Ax)+; PACK/UNPK -(Ay),-(Ax) or Dx,Dy
S_PACK: begin : pack_state
	reg [31:0] bs;       // source operand size in bytes
	reg is_pack, is_unpk, is_cmpm;
	is_pack = (ir[15:12] == 4'h8) && (ir[8:6] == 3'b101);
	is_unpk = (ir[15:12] == 4'h8) && (ir[8:6] == 3'b110);
	is_cmpm = (ir[15:12] == 4'hB);
	bs = is_pack ? 32'd2 : (is_unpk ? ((ir[2:0] == 3'd7) ? 32'd2 : 32'd1) : size_bytes(g_size, ir[2:0] == 3'd7));
	if (!ir[3]) begin
		// register form (PACK/UNPK Dx,Dy)
		src <= rf_a; dst <= rf_b; state <= S_PACK3;
	end else if (is_cmpm) begin
		wreg({1'b1, ir[2:0]}, rf_a + bs);
		rd(rf_a, g_size, DW_SRC, S_PACK2);
	end else begin
		wreg({1'b1, ir[2:0]}, rf_a - bs);
		rd(rf_a - bs, is_pack ? `SZ_W : (is_unpk ? `SZ_B : g_size), DW_SRC, S_PACK2);
	end
end
S_PACK2: begin : pack2_state
	reg [31:0] bd;
	reg is_pack, is_unpk, is_cmpm;
	is_pack = (ir[15:12] == 4'h8) && (ir[8:6] == 3'b101);
	is_unpk = (ir[15:12] == 4'h8) && (ir[8:6] == 3'b110);
	is_cmpm = (ir[15:12] == 4'hB);
	bd = is_pack ? ((ir[11:9] == 3'd7) ? 32'd2 : 32'd1) : (is_unpk ? 32'd2 : size_bytes(g_size, ir[11:9] == 3'd7));
	if (is_cmpm) begin
		wreg({1'b1, ir[11:9]}, rf_b + bd);
		ea <= rf_b;
		rd(rf_b, g_size, DW_DST, S_PACK3);
	end else if (is_pack || is_unpk) begin
		// PACK/UNPK do not read the destination
		wreg({1'b1, ir[11:9]}, rf_b - bd);
		ea <= rf_b - bd;
		state <= S_PACK3;
	end else begin
		wreg({1'b1, ir[11:9]}, rf_b - bd);
		ea <= rf_b - bd;
		rd(rf_b - bd, g_size, DW_DST, S_PACK3);
	end
end
S_PACK3: begin : pack3_state
	reg is_pack, is_unpk, is_cmpm;
	reg [15:0] adj;
	reg [31:0] r;
	is_pack = (ir[15:12] == 4'h8) && (ir[8:6] == 3'b101);
	is_unpk = (ir[15:12] == 4'h8) && (ir[8:6] == 3'b110);
	is_cmpm = (ir[15:12] == 4'hB);
	adj = src[15:0] + ext;
	if (is_pack) begin
		r = {24'd0, adj[11:8], adj[3:0]};
		if (!ir[3]) begin wreg({1'b0, ir[11:9]}, {dst[31:8], r[7:0]}); finish; end
		else begin finish; wr(ea, `SZ_B, r, S_FETCH); end
	end else if (is_unpk) begin
		r = {16'd0, ({4'd0, src[7:4], 4'd0, src[3:0]} + ext)};
		if (!ir[3]) begin wreg({1'b0, ir[11:9]}, {dst[31:16], r[15:0]}); finish; end
		else begin finish; wr(ea, `SZ_W, r, S_FETCH); end
	end else begin
		sr[4:0] <= alu_f;
		if (is_cmpm) finish;
		else begin finish; wr(ea, g_size, alu_r, S_FETCH); end
	end
end

//-------------------------------------------------------------- TAS (read-modify-write, UM 7.3.3)
S_TAS: dreq(ea, `SZ_B, 1'b1, 32'd0, fc_data, 1'b1, 1'b0, DW_DST, S_TAS2);
S_TAS2: begin
	sr[4:0] <= alu_f;
	finish;
	dreq(ea, `SZ_B, 1'b0, alu_r, fc_data, 1'b1, 1'b1, DW_NONE, S_FETCH);
end

//-------------------------------------------------------------- MOVEP
S_MOVEP0: begin
	ea <= rf_a + sext16(ext);
	cnt <= 8'd0; tmp <= 32'd0; dst <= rf_b;
	state <= S_MOVEP1;
end
S_MOVEP1: begin : movep1
	reg [2:0] n;
	n = ir[6] ? 3'd4 : 3'd2;
	if (cnt[2:0] == n) begin
		if (!ir[7]) wreg({1'b0, ir[11:9]}, ir[6] ? tmp : {dst[31:16], tmp[15:0]});
		finish;
	end else if (ir[7]) begin
		cnt <= cnt + 8'd1;
		wr(ea + {cnt[6:0], 1'b0}, `SZ_B, ir[6] ? (dst >> (8 * (3'd3 - cnt[2:0]))) : (dst >> (8 * (3'd1 - cnt[1:0]))), S_MOVEP1);
	end else begin
		cnt <= cnt + 8'd1;
		rd(ea + {cnt[6:0], 1'b0}, `SZ_B, DW_TMP2, S_MOVEP2);
	end
end
S_MOVEP2: begin tmp <= {tmp[23:0], tmp2[7:0]}; state <= S_MOVEP1; end

//-------------------------------------------------------------- CHK (PRM)
S_CHK: begin : chk_state
	reg signed [31:0] v, b;
	reg [31:0] d;
	reg [3:0] nf;
	reg out_of;
	v = sext_sz(dst, g_size);
	b = sext_sz(src, g_size);
	d = b - v;
	out_of = (v < 0) || (v > b);
	// N, Z, V and C are undefined; the MC68020/030 values on both paths
	// (WinUAE setchkundefinedflags): V is the overflow of bound - Dn, C
	// follows the signs, both are clear when Dn is in bounds
	nf[3] = (v < 0);
	nf[2] = (v == 0);
	nf[1] = out_of && ((v[31] ^ b[31]) & ((g_size == `SZ_W ? d[15] : d[31]) ^ b[31]));
	nf[0] = out_of && ((v < 0) ? ((v > b) || (b >= 0)) : (b >= 0));
	sr[3:0] <= nf;
	if (out_of) begin
		exc_go(`VEC_CHK, `FMT_SIXWORD, scan_pc, pc_i);
		exc_sr <= {sr[15:4], nf};       // the frame holds the updated flags
	end else finish;
end
S_DIVZ: exc_go(`VEC_DIVZERO, `FMT_SIXWORD, scan_pc, pc_i);
