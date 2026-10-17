// AP68020 core - states part M: module call and return, CALLM and RTM
// (MC68020 UM 9.7 and 9.8, M68000 PRM 4-64 and 4-167)
//
// CALLM #n,<ea>: <ea> (control) is the module descriptor.  Its first
// longword holds opt (31:29), type (28:24) and the access level (23:16);
// then the module entry word pointer (+$04), the module data area pointer
// (+$08) and, for a type $01 module that changes stacks, its stack pointer
// (+$0C).  The word at the entry address names the register (D/A, reg in
// 15:12) that is saved in the frame and loaded with the data area pointer;
// the module starts at the word after it.  The module stack frame:
//   +$00 opt/type/saved access level   +$02 CCR (low byte)
//   +$04 argument count (low byte)     +$06 reserved
//   +$08 descriptor pointer            +$0C saved PC (after the CALLM)
//   +$10 saved data area register      +$14 saved SP (at the CALLM)
//   +$18 the arguments (on a stack change with opt 000, copied there; opt
//        100 leaves them on the calling stack, reached through the saved SP)
// RTM Rn reverses it: CCR, PC and Rn from the frame, then SP past the frame
// and the argument count (type $01: the saved SP plus the argument count).
// Opt must be 000 or 100 and type $00 or $01, else a format error (no
// register changed).  Type $01 talks to external access control hardware
// in CPU space (A19-A16 = 0001): CAL $00, access status $04, IAL $08, DAL
// $0C, the descriptor address registers $40 + 4 x FC; a bus error on any of
// those is a format error, as is an access status of 0 or above 7.
//
// Saved across a bus fault (long frame): imm (descriptor pointer), tmp
// (descriptor control), tmp2 (entry pointer), src (data area pointer), dst
// (return PC), ea2 (frame base), tmp3 (15:12 data area register, 8 stack
// change, 7:0 saved access level), cnt (argument copy), ext (argument
// count).  ea only carries a value into the state right after its read.

`define AC_SPACE(off) (32'h0001_0000 | (off))

//-------------------------------------------------------------- CALLM
S_CALLM0: begin
	// the effective address is the descriptor; the argument count was
	// popped with the opcode (ext), the return PC follows the instruction
	imm <= ea; dst <= scan_pc; tmp3 <= 32'd0;
	rd(ea, `SZ_L, DW_TMP, S_CALLM1);
end
S_CALLM1: begin
	if (!((tmp[31:29] == 3'b000 || tmp[31:29] == 3'b100) && (tmp[28:24] == 5'h00 || tmp[28:24] == 5'h01)))
		exc_pre(`VEC_FMTERR);
	else if (tmp[28:24] == 5'h01) begin
		// type $01: the current access level from external hardware
		cpu_flt_fmt <= 1'b1;
		dreq(`AC_SPACE(32'h00), `SZ_B, 1'b1, 32'd0, `FC_CPU_SPACE, 1'b0, 1'b0, DW_EA, S_CALLMA1);
	end else rd(imm + 32'd4, `SZ_L, DW_TMP2, S_CALLM2);
end
S_CALLMA1: begin
	// the calling module must be able to read its stack (an ordinary read)
	cpu_flt_fmt <= 1'b0;
	tmp3[7:0] <= ea[7:0];
	dreq(rf_c, `SZ_W, 1'b1, 32'd0, fc_data, 1'b0, 1'b0, DW_NONE, S_CALLMA2);
end
S_CALLMA2: begin
	// the descriptor's address, for validation of a type $01 descriptor, in
	// the descriptor address register of the space it was read from (a
	// PC-relative descriptor is a program reference, see rd)
	cpu_flt_fmt <= 1'b1;
	dreq(`AC_SPACE(32'h40 | {27'd0, (ea_pc && PCREL_PROGRAM_SPACE) ? fc_prog : fc_data, 2'b00}), `SZ_L, 1'b0, imm,
	     `FC_CPU_SPACE, 1'b0, 1'b0, DW_NONE, S_CALLMA3);
end
S_CALLMA3: dreq(`AC_SPACE(32'h08), `SZ_B, 1'b0, {24'd0, tmp[23:16]}, `FC_CPU_SPACE, 1'b0, 1'b0, DW_NONE, S_CALLMA4);
S_CALLMA4: dreq(`AC_SPACE(32'h04), `SZ_B, 1'b1, 32'd0, `FC_CPU_SPACE, 1'b0, 1'b0, DW_EA, S_CALLMA5);
S_CALLMA5: begin
	cpu_flt_fmt <= 1'b0;
	// access status (UM Table 9-6): 0 refused; 1 no change; 2-3 change of
	// access rights; 4-7 also a change of stack; anything else undefined
	if (ea[7:0] == 8'd0 || ea[7:0] > 8'd7) exc_pre(`VEC_FMTERR);
	else if (ea[7:0] >= 8'd4) begin
		tmp3[8] <= 1'b1;
		rd(imm + 32'd12, `SZ_L, DW_EA, S_CALLMA6);
	end else rd(imm + 32'd4, `SZ_L, DW_TMP2, S_CALLM2);
end
S_CALLMA6: begin
	// the frame goes below the arguments copied to the new stack; opt 100
	// copies nothing, the module reaches the arguments through the saved SP
	// (UM 9.7.1)
	ea2 <= ea - (tmp[31] ? 32'd0 : {24'd0, ext[7:0]}) - 32'd24;
	rd(imm + 32'd4, `SZ_L, DW_TMP2, S_CALLM2);
end
S_CALLM2: rd(imm + 32'd8, `SZ_L, DW_SRC, S_CALLM3);
S_CALLM3: dreq(tmp2, `SZ_W, 1'b1, 32'd0, fc_prog, 1'b0, 1'b0, DW_EA, S_CALLM4);
S_CALLM4: begin tmp3[15:12] <= ea[15:12]; state <= S_CALLM5; end
S_CALLM5: begin
	cnt <= 8'd0;
	if (!tmp3[8]) begin ea2 <= rf_c - 32'd24; state <= S_CALLM6; end
	else if (ext[7:0] != 8'd0 && !tmp[31]) state <= S_CALLMC;
	else state <= S_CALLM6;
end
// stack change: the arguments from the calling stack to the new one
S_CALLMC: dreq(rf_c + {24'd0, cnt}, `SZ_B, 1'b1, 32'd0, fc_data, 1'b0, 1'b0, DW_EA, S_CALLMC2);
S_CALLMC2: begin
	cnt <= cnt + 8'd1;
	wr(ea2 + 32'd24 + {24'd0, cnt}, `SZ_B, {24'd0, ea[7:0]}, (cnt + 8'd1 == ext[7:0]) ? S_CALLM6 : S_CALLMC);
end
S_CALLM6: wr(ea2, `SZ_L, {tmp[31:24], tmp3[7:0], 8'd0, 3'd0, sr[4:0]}, S_CALLM7);
S_CALLM7: wr(ea2 + 32'd4, `SZ_L, {8'd0, ext[7:0], 16'd0}, S_CALLM8);
S_CALLM8: wr(ea2 + 32'd8, `SZ_L, imm, S_CALLM9);
S_CALLM9: wr(ea2 + 32'd12, `SZ_L, dst, S_CALLM10);
S_CALLM10: wr(ea2 + 32'd16, `SZ_L, rf_a, S_CALLM11);       // ra_a: the data area register
S_CALLM11: wr(ea2 + 32'd20, `SZ_L, rf_c, S_CALLM12);       // SP at the CALLM (A7 not yet changed)
S_CALLM12: begin
	// A7 as the data area register: the stack pointer value prevails
	if (tmp3[15:12] != 4'd15) wreg(tmp3[15:12], src);
	state <= S_CALLM13;
end
S_CALLM13: begin wreg(4'd15, ea2); go_pc(tmp2 + 32'd2); end

//-------------------------------------------------------------- RTM
S_RTM0: dreq(rf_c, `SZ_L, 1'b1, 32'd0, fc_data, 1'b0, 1'b0, DW_TMP, S_RTM1);
S_RTM1: begin
	if (!((tmp[31:29] == 3'b000 || tmp[31:29] == 3'b100) && (tmp[28:24] == 5'h00 || tmp[28:24] == 5'h01)))
		exc_pre(`VEC_FMTERR);
	else dreq(rf_c + 32'd4, `SZ_L, 1'b1, 32'd0, fc_data, 1'b0, 1'b0, DW_TMP2, S_RTM2);
end
S_RTM2: dreq(rf_c + 32'd12, `SZ_L, 1'b1, 32'd0, fc_data, 1'b0, 1'b0, DW_SRC, S_RTM3);
S_RTM3: dreq(rf_c + 32'd16, `SZ_L, 1'b1, 32'd0, fc_data, 1'b0, 1'b0, DW_DST, S_RTM4);
S_RTM4: begin
	if (tmp[28:24] == 5'h01) dreq(rf_c + 32'd20, `SZ_L, 1'b1, 32'd0, fc_data, 1'b0, 1'b0, DW_IMM, S_RTMA1);
	else begin imm <= rf_c + 32'd24; state <= S_RTM5; end
end
S_RTMA1: begin
	// type $01: the saved access level to the DAL for validation
	cpu_flt_fmt <= 1'b1;
	dreq(`AC_SPACE(32'h0C), `SZ_B, 1'b0, {24'd0, tmp[23:16]}, `FC_CPU_SPACE, 1'b0, 1'b0, DW_NONE, S_RTMA2);
end
S_RTMA2: dreq(`AC_SPACE(32'h04), `SZ_B, 1'b1, 32'd0, `FC_CPU_SPACE, 1'b0, 1'b0, DW_EA, S_RTMA3);
S_RTMA3: begin
	cpu_flt_fmt <= 1'b0;
	if (ea[7:0] == 8'd0 || ea[7:0] > 8'd7) exc_pre(`VEC_FMTERR);
	else state <= S_RTM5;
end
S_RTM5: begin
	// condition codes from the frame; Rn unless it is A7 (the SP prevails)
	sr[4:0] <= tmp[4:0];
	if (ir[3:0] != 4'd15) wreg(ir[3:0], dst);
	state <= S_RTM6;
end
S_RTM6: begin wreg(4'd15, imm + {24'd0, tmp2[23:16]}); go_pc(src); end

`undef AC_SPACE
