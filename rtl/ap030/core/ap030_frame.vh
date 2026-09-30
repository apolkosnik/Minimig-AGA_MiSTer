// AP68030 core - exception stack frame words (UM 8.4, included by ap030_core.v)
//
// frame_word(i) is word i (offset 2*i) of the frame being built.  Formats:
//   $0/$1  4 words   SR, PC, format/vector
//   $2     6 words   + instruction address
//   $9    10 words   + instruction address, 4 internal words
//   $A    16 words   short bus fault
//   $B    46 words   long bus fault
// The internal words of the bus fault frames hold this core's resume state
// (resume kind/state, temporaries); handlers must leave them alone except
// for the SSW rerun bits and the data input buffer, as UM 8.2.2 says.

function [15:0] frame_word;
	input [5:0] i;
	begin
		case (i)
			6'd0:  frame_word = exc_throw ? (exc_sr | 16'h2000) : exc_sr;   // throwaway: S set (UM 8.1.9)
			6'd1:  frame_word = exc_pc[31:16];
			6'd2:  frame_word = exc_pc[15:0];
			6'd3:  frame_word = {exc_fmt, 2'b00, exc_vec, 2'b00};
			default: begin
				if (exc_fmt == `FMT_SIXWORD || exc_fmt == `FMT_CPMID) begin
					case (i)
						6'd4: frame_word = exc_ia[31:16];
						6'd5: frame_word = exc_ia[15:0];
						6'd6: frame_word = {cp_kind, cp_id, cp_cond, cp_dr, cp_ca, cp_pcbit, cp_trace_wait, 4'd0};
						6'd7: frame_word = ir;
						6'd8: frame_word = ea[31:16];
						default: frame_word = ea[15:0];
					endcase
				end else begin
					case (i)
						6'd4:  frame_word = {exc_rk, 4'd0, exc_rs};
						6'd5:  frame_word = exc_ssw;
						6'd6:  frame_word = exc_stage_c;
						6'd7:  frame_word = exc_stage_b;
						6'd8:  frame_word = exc_fa[31:16];
						6'd9:  frame_word = exc_fa[15:0];
						6'd10: frame_word = ea[31:16];
						6'd11: frame_word = ea[15:0];
						6'd12: frame_word = exc_dob[31:16];
						6'd13: frame_word = exc_dob[15:0];
						6'd14: frame_word = src[31:16];
						6'd15: frame_word = src[15:0];
						6'd16: frame_word = dst[31:16];
						6'd17: frame_word = dst[15:0];
						6'd18: frame_word = exc_baddr[31:16];
						6'd19: frame_word = exc_baddr[15:0];
						6'd20: frame_word = imm[31:16];
						6'd21: frame_word = imm[15:0];
						6'd22: frame_word = 16'd0;                 // data input buffer
						6'd23: frame_word = 16'd0;
						6'd24: frame_word = tmp[31:16];
						6'd25: frame_word = tmp[15:0];
						6'd26: frame_word = ir;
						6'd27: frame_word = {4'h0, exc_dw_dst, exc_dw_ret};  // version 0
						6'd28: frame_word = tmp2[31:16];
						6'd29: frame_word = tmp2[15:0];
						6'd30: frame_word = ea2[31:16];
						6'd31: frame_word = ea2[15:0];
						6'd32: frame_word = {exc_cnt, sub};
						6'd33: frame_word = mm_mask;
						6'd34: frame_word = tmp3[15:0];
						6'd35: frame_word = {ea_sel, imm_tgt, dw_reg, 1'b0, ea_pc, ea_ret};
						6'd36: frame_word = {exc_got, 5'd0, imm_ret};
						6'd37: frame_word = exc_partial[31:16];
						6'd38: frame_word = exc_partial[15:0];
						6'd39: frame_word = ext;
						6'd40: frame_word = {tr_t1, tr_t0, flow, cp_cond, cp_dr, cp_ca, cp_pcbit, cp_trace_wait, cp_kind, cp_id, 1'b0};
						6'd41: frame_word = {cp_len, cp_pos};
						6'd42: frame_word = cp_base[31:16];
						6'd43: frame_word = cp_base[15:0];
						6'd44: frame_word = cp_resp;
						default: frame_word = 16'd0;
					endcase
				end
			end
		endcase
	end
endfunction

// frame length in longwords per format
function [5:0] frame_lw;
	input [3:0] f;
	begin
		case (f)
			`FMT_SIXWORD: frame_lw = 6'd3;
			`FMT_CPMID:   frame_lw = 6'd5;
			`FMT_SHORTBUS: frame_lw = 6'd8;
			`FMT_LONGBUS: frame_lw = 6'd23;
			default: frame_lw = 6'd2;
		endcase
	end
endfunction

// word i of the frame image read by RTE (fr[] holds longwords)
function [15:0] fr_word;
	input [5:0] i;
	begin
		fr_word = i[0] ? fr[i[5:1]][15:0] : fr[i[5:1]][31:16];
	end
endfunction
function [31:0] fr_long;
	input [5:0] i;    // word index of the high word
	begin
		fr_long = {fr_word(i), fr_word(i + 6'd1)};
	end
endfunction
