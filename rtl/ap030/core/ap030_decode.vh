// AP68030 core - instruction decoder (included by ap030_core.v)
//
// Decodes the word `dw` (the word being dispatched, or ir afterwards) into
// the first sequencer state and the generic-path controls.  Instructions
// that share the read-operate-write pattern use the generic path; the
// others get their own first state.

reg  [7:0] dc_first;
reg  [1:0] dc_size;
reg  [5:0] dc_alu;
reg  [1:0] dc_srck;     // 0 register, 1 immediate, 2 memory EA, 3 quick
reg  [1:0] dc_dstk;     // 0 register, 1 memory EA, 2 none, 3 immediate (BTST #,#)
reg  [3:0] dc_sreg, dc_dreg;
reg        dc_flags;    // update CCR
reg        dc_wb;       // write the result
reg        dc_dstrd;    // memory destination is read first
reg        dc_sext;     // sign extend the source to 32 bits (address arithmetic)
reg        dc_bitop;    // bit number modulo 8 (memory) / 32 (register)
reg        dc_priv;
reg        dc_illegal;
reg [31:0] dc_quick;
reg        dc_move_mem; // MOVE to a memory destination
reg        dc_shift;    // register shift/rotate

localparam SK_REG = 2'd0, SK_IMM = 2'd1, SK_EA = 2'd2, SK_QUICK = 2'd3;
localparam DK_REG = 2'd0, DK_EA = 2'd1, DK_NONE = 2'd2, DK_IMM = 2'd3;

// EA classification of dw[5:0]
wire [2:0] em = dw[5:3];
wire [2:0] er = dw[2:0];
wire ea_dn   = (em == 3'b000);
wire ea_an   = (em == 3'b001);
wire ea_ind  = (em == 3'b010);
wire ea_pi   = (em == 3'b011);
wire ea_pd   = (em == 3'b100);
wire ea_d16  = (em == 3'b101);
wire ea_idx  = (em == 3'b110);
wire ea_absw = (em == 3'b111) && (er == 3'b000);
wire ea_absl = (em == 3'b111) && (er == 3'b001);
wire ea_pcd  = (em == 3'b111) && (er == 3'b010);
wire ea_pci  = (em == 3'b111) && (er == 3'b011);
wire ea_imm  = (em == 3'b111) && (er == 3'b100);
wire ea_bad  = (em == 3'b111) && (er[2:0] > 3'b100);
wire ea_mem      = ea_ind | ea_pi | ea_pd | ea_d16 | ea_idx | ea_absw | ea_absl | ea_pcd | ea_pci;
wire ea_memalt   = ea_ind | ea_pi | ea_pd | ea_d16 | ea_idx | ea_absw | ea_absl;
wire ea_ctrl     = ea_ind | ea_d16 | ea_idx | ea_absw | ea_absl | ea_pcd | ea_pci;
wire ea_ctrlalt  = ea_ind | ea_d16 | ea_idx | ea_absw | ea_absl;
wire ea_data     = ea_dn | ea_mem | ea_imm;
wire ea_dataalt  = ea_dn | ea_memalt;
wire ea_alt      = ea_dn | ea_an | ea_memalt;
wire ea_any      = !ea_bad;

// MOVE destination classification (dw[8:6] mode, dw[11:9] register)
wire [2:0] dm = dw[8:6];
wire [2:0] dr = dw[11:9];
wire dm_dn   = (dm == 3'b000);
wire dm_an   = (dm == 3'b001);
wire dm_mem  = (dm == 3'b010) | (dm == 3'b011) | (dm == 3'b100) | (dm == 3'b101) | (dm == 3'b110) |
               ((dm == 3'b111) && (dr == 3'b000 || dr == 3'b001));

wire [1:0] sz_std = dw[7:6];   // 00 B 01 W 10 L

always @* begin
	dc_first = S_GEN_EXEC;
	dc_size = `SZ_L;
	dc_alu = `ALU_MOVE;
	dc_srck = SK_REG; dc_dstk = DK_REG;
	dc_sreg = {1'b0, dw[2:0]};
	dc_dreg = {1'b0, dw[11:9]};
	dc_flags = 1'b1; dc_wb = 1'b1; dc_dstrd = 1'b1; dc_sext = 1'b0; dc_bitop = 1'b0;
	dc_priv = 1'b0; dc_illegal = 1'b0; dc_quick = 32'd0; dc_move_mem = 1'b0; dc_shift = 1'b0;

	case (dw[15:12])
	//------------------------------------------------------------------ 0000
	4'h0: begin
		if (dw[8]) begin
			if (ea_an) begin
				// MOVEP
				dc_first = S_MOVEP0;
				dc_size = dw[6] ? `SZ_L : `SZ_W;
			end else begin
				// dynamic bit operations: BTST/BCHG/BCLR/BSET Dn,<ea>
				dc_bitop = 1'b1;
				dc_sreg = {1'b0, dw[11:9]};
				case (dw[7:6])
					2'b00: begin dc_alu = `ALU_BTST; dc_wb = 1'b0; end
					2'b01: dc_alu = `ALU_BCHG;
					2'b10: dc_alu = `ALU_BCLR;
					default: dc_alu = `ALU_BSET;
				endcase
				if (ea_dn) begin dc_size = `SZ_L; dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
				else begin
					dc_size = `SZ_B;
					if (ea_imm && dw[7:6] == 2'b00) dc_dstk = DK_IMM;
					else begin dc_dstk = DK_EA; if (!(dw[7:6] == 2'b00 ? ea_mem : ea_memalt)) dc_illegal = 1'b1; end
				end
			end
		end else if (dw[11:9] == 3'b100) begin
			// static bit operations: BTST/BCHG/BCLR/BSET #n,<ea> (the bit
			// number is one word; the operand is a byte in memory, long in Dn)
			dc_bitop = 1'b1;
			dc_srck = SK_IMM;
			dc_size = `SZ_B;
			case (dw[7:6])
				2'b00: begin dc_alu = `ALU_BTST; dc_wb = 1'b0; end
				2'b01: dc_alu = `ALU_BCHG;
				2'b10: dc_alu = `ALU_BCLR;
				default: dc_alu = `ALU_BSET;
			endcase
			dc_first = S_GEN_EXEC;
			if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; dc_size = `SZ_L; end
			else begin dc_dstk = DK_EA; if (!(dw[7:6] == 2'b00 ? ea_mem : ea_memalt)) dc_illegal = 1'b1; end
		end else if (dw[7:6] == 2'b11) begin
			// CHK2/CMP2 (00C0/02C0/04C0), CAS (0AC0/0CC0/0EC0), CAS2 (0CFC/0EFC), CALLM/RTM (illegal)
			case (dw[11:9])
				3'b000, 3'b001, 3'b010: begin
					dc_first = S_CHK2_0;
					dc_size = dw[10:9];
					if (!ea_ctrl) dc_illegal = 1'b1;
				end
				3'b101, 3'b110, 3'b111: begin
					dc_size = dw[10:9] - 2'd1;
					if (ea_imm && dw[11:9] != 3'b101) dc_first = S_CAS2_0;
					else begin dc_first = S_CAS0; if (!ea_memalt) dc_illegal = 1'b1; end
				end
				default: dc_illegal = 1'b1;
			endcase
		end else if (dw[11:9] == 3'b111) begin
			// MOVES
			dc_first = S_MOVES0;
			dc_size = sz_std;
			dc_priv = 1'b1;
			if (!ea_memalt) dc_illegal = 1'b1;
		end else begin
			// ORI ANDI SUBI ADDI EORI CMPI #imm,<ea>; to CCR/SR
			dc_srck = SK_IMM;
			dc_size = sz_std;
			dc_first = S_GEN_EXEC;
			case (dw[11:9])
				3'b000: dc_alu = `ALU_OR;
				3'b001: dc_alu = `ALU_AND;
				3'b010: dc_alu = `ALU_SUB;
				3'b011: dc_alu = `ALU_ADD;
				3'b101: dc_alu = `ALU_EOR;
				default: begin dc_alu = `ALU_CMP; dc_wb = 1'b0; end
			endcase
			if (ea_imm && (dw[11:9] == 3'b000 || dw[11:9] == 3'b001 || dw[11:9] == 3'b101) && (dw[7:6] != 2'b10)) begin
				// to CCR (byte) / SR (word)
				dc_dstk = DK_NONE;
				dc_priv = dw[6];
				dc_first = S_MOVE_SR;
			end else if (ea_dn) begin
				dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]};
			end else begin
				dc_dstk = DK_EA;
				if (!(dw[11:9] == 3'b110 ? ea_mem : ea_memalt)) dc_illegal = 1'b1;
			end
		end
	end

	//------------------------------------------------------------------ MOVE
	4'h1, 4'h2, 4'h3: begin
		dc_size = (dw[13:12] == 2'b01) ? `SZ_B : (dw[13:12] == 2'b11) ? `SZ_W : `SZ_L;
		dc_alu = `ALU_MOVE;
		dc_dstrd = 1'b0;
		if (ea_dn) dc_srck = SK_REG;
		else if (ea_an) begin dc_srck = SK_REG; dc_sreg = {1'b1, dw[2:0]}; if (dc_size == `SZ_B) dc_illegal = 1'b1; end
		else if (ea_imm) begin dc_srck = SK_IMM; dc_first = S_GEN_EXEC; end
		else if (ea_mem) begin dc_srck = SK_EA; dc_first = S_GEN_EXEC; end
		else dc_illegal = 1'b1;
		if (dm_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[11:9]}; end
		else if (dm_an) begin
			// MOVEA
			dc_dstk = DK_REG; dc_dreg = {1'b1, dw[11:9]}; dc_alu = `ALU_MOVEA; dc_flags = 1'b0; dc_sext = 1'b1;
			if (dc_size == `SZ_B) dc_illegal = 1'b1;
		end else if (dm_mem) begin
			dc_dstk = DK_EA; dc_move_mem = 1'b1;
			if (dc_srck == SK_REG) dc_first = S_MOVE_DEA;
		end else dc_illegal = 1'b1;
	end

	//------------------------------------------------------------------ 0100
	4'h4: begin
		if (dw[8]) begin
			case (dw[7:6])
				2'b11: begin
					if (dw[11:9] == 3'b100 && ea_dn) begin   // EXTB.L Dn ($49C0)
						dc_alu = `ALU_EXTB; dc_size = `SZ_L; dc_srck = SK_QUICK; dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]};
					end else begin dc_first = S_LEA; dc_flags = 1'b0; if (!ea_ctrl) dc_illegal = 1'b1; end   // LEA
				end
				2'b10, 2'b00: begin
					dc_first = S_CHK; dc_size = dw[7] ? `SZ_W : `SZ_L; dc_flags = 1'b0; dc_wb = 1'b0;
					if (ea_dn) dc_srck = SK_REG;
					else if (ea_imm) dc_srck = SK_IMM;
					else if (ea_mem) dc_srck = SK_EA;
					else dc_illegal = 1'b1;
				end
				default: dc_illegal = 1'b1;
			endcase
		end else case (dw[11:9])
			3'b000: begin  // NEGX / MOVE from SR
				if (dw[7:6] == 2'b11) begin dc_first = S_MOVE_FSR; dc_size = `SZ_W; dc_dreg = {1'b0, dw[2:0]}; dc_priv = 1'b1; if (!ea_dataalt) dc_illegal = 1'b1; end
				else begin dc_alu = `ALU_NEGX; dc_size = sz_std; dc_srck = SK_QUICK;
					if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
					else begin dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
				end
			end
			3'b001: begin  // CLR / MOVE from CCR
				if (dw[7:6] == 2'b11) begin dc_first = S_MOVE_FSR; dc_size = `SZ_W; dc_dreg = {1'b0, dw[2:0]}; if (!ea_dataalt) dc_illegal = 1'b1; end
				else begin dc_alu = `ALU_CLR; dc_size = sz_std; dc_srck = SK_QUICK; dc_dstrd = 1'b0;
					if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
					else begin dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
				end
			end
			3'b010: begin  // NEG / MOVE to CCR
				if (dw[7:6] == 2'b11) begin
					dc_first = S_MOVE_SR; dc_size = `SZ_W; dc_dstk = DK_NONE;
					if (ea_dn) dc_srck = SK_REG; else if (ea_imm) dc_srck = SK_IMM; else if (ea_mem) dc_srck = SK_EA; else dc_illegal = 1'b1;
				end else begin dc_alu = `ALU_NEG; dc_size = sz_std; dc_srck = SK_QUICK;
					if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
					else begin dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
				end
			end
			3'b011: begin  // NOT / MOVE to SR
				if (dw[7:6] == 2'b11) begin
					dc_first = S_MOVE_SR; dc_size = `SZ_W; dc_priv = 1'b1; dc_dstk = DK_NONE;
					if (ea_dn) dc_srck = SK_REG; else if (ea_imm) dc_srck = SK_IMM; else if (ea_mem) dc_srck = SK_EA; else dc_illegal = 1'b1;
				end else begin dc_alu = `ALU_NOT; dc_size = sz_std; dc_srck = SK_QUICK;
					if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
					else begin dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
				end
			end
			3'b100: begin
				case (dw[7:6])
					2'b00: begin  // NBCD / LINK.L
						if (ea_an) begin dc_first = S_LINK; dc_size = `SZ_L; end
						else begin dc_alu = `ALU_NBCD; dc_size = `SZ_B; dc_srck = SK_QUICK;
							if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
							else begin dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
						end
					end
					2'b01: begin  // SWAP / BKPT / PEA
						if (ea_dn) begin dc_alu = `ALU_SWAP; dc_size = `SZ_L; dc_srck = SK_QUICK; dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
						else if (ea_an) dc_first = S_BKPT;
						else begin dc_first = S_PEA; if (!ea_ctrl) dc_illegal = 1'b1; end
					end
					default: begin  // EXT.W / EXT.L / MOVEM reg->mem
						if (ea_dn) begin dc_alu = `ALU_EXT; dc_size = dw[6] ? `SZ_L : `SZ_W; dc_srck = SK_QUICK; dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
						else begin dc_first = S_MOVEM0; dc_size = dw[6] ? `SZ_L : `SZ_W; if (!(ea_ctrlalt || ea_pd)) dc_illegal = 1'b1; end
					end
				endcase
			end
			3'b101: begin  // TST / TAS / ILLEGAL
				if (dw[7:6] == 2'b11) begin
					if (ea_imm) dc_illegal = 1'b1;   // ILLEGAL ($4AFC)
					else begin dc_alu = `ALU_TAS; dc_size = `SZ_B;
						if (ea_dn) begin dc_srck = SK_QUICK; dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
						else begin dc_first = S_TAS; if (!ea_memalt) dc_illegal = 1'b1; end
					end
				end else begin
					dc_alu = `ALU_TST; dc_size = sz_std; dc_wb = 1'b0;
					if (ea_dn) begin dc_srck = SK_REG; dc_dstk = DK_NONE; end
					else if (ea_an) begin dc_srck = SK_REG; dc_sreg = {1'b1, dw[2:0]}; dc_dstk = DK_NONE; if (dc_size == `SZ_B) dc_illegal = 1'b1; end
					else if (ea_imm) begin dc_srck = SK_IMM; dc_dstk = DK_NONE; dc_first = S_GEN_EXEC; end
					else begin dc_srck = SK_EA; dc_dstk = DK_NONE; dc_first = S_GEN_EXEC; if (!ea_mem) dc_illegal = 1'b1; end
				end
			end
			3'b110: begin  // MULL / DIVL / MOVEM mem->reg
				if (dw[7]) begin dc_first = S_MOVEM0; dc_size = dw[6] ? `SZ_L : `SZ_W; if (!(ea_ctrl || ea_pi)) dc_illegal = 1'b1; end
				else begin
					dc_first = S_MULDIV0; dc_size = `SZ_L; dc_dstk = DK_NONE;
					if (ea_dn) dc_srck = SK_REG; else if (ea_imm) dc_srck = SK_IMM; else if (ea_mem) dc_srck = SK_EA; else dc_illegal = 1'b1;
				end
			end
			default: begin  // 3'b111
				case (dw[7:6])
					2'b01: begin
						case (dw[5:3])
							3'b000, 3'b001: dc_first = S_TRAP;
							3'b010: begin dc_first = S_LINK; dc_size = `SZ_W; end
							3'b011: dc_first = S_UNLK;
							3'b100, 3'b101: begin dc_first = S_MOVE_USP; dc_priv = 1'b1; end
							3'b110: begin
								case (dw[2:0])
									3'b000: begin dc_first = S_RESETI; dc_priv = 1'b1; end
									3'b001: dc_first = S_NOP;
									3'b010: begin dc_first = S_STOP; dc_priv = 1'b1; end
									3'b011: begin dc_first = S_RTE0; dc_priv = 1'b1; end
									3'b100: dc_first = S_RTD;
									3'b101: dc_first = S_RTS;
									3'b110: dc_first = S_TRAPCC;   // TRAPV
									default: dc_first = S_RTR;
								endcase
							end
							default: begin
								if (dw[2:1] == 2'b01) begin dc_first = S_MOVEC; dc_priv = 1'b1; end   // 4E7A/4E7B
								else dc_illegal = 1'b1;
							end
						endcase
					end
					2'b10: begin dc_first = S_JSR; if (!ea_ctrl) dc_illegal = 1'b1; end
					2'b11: begin dc_first = S_JMP; if (!ea_ctrl) dc_illegal = 1'b1; end
					default: dc_illegal = 1'b1;
				endcase
			end
		endcase
	end

	//------------------------------------------------------------------ 0101 ADDQ/SUBQ/Scc/DBcc/TRAPcc
	4'h5: begin
		if (dw[7:6] == 2'b11) begin
			if (ea_an) dc_first = S_DBCC;
			else if (em == 3'b111 && (er == 3'b010 || er == 3'b011 || er == 3'b100)) dc_first = S_TRAPCC;
			else begin dc_first = S_SCC; dc_size = `SZ_B; dc_dreg = {1'b0, dw[2:0]}; if (!ea_dataalt) dc_illegal = 1'b1; end
		end else begin
			dc_size = sz_std;
			dc_srck = SK_QUICK;
			dc_quick = (dw[11:9] == 3'd0) ? 32'd8 : {29'd0, dw[11:9]};
			dc_alu = dw[8] ? `ALU_SUB : `ALU_ADD;
			if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
			else if (ea_an) begin
				dc_dstk = DK_REG; dc_dreg = {1'b1, dw[2:0]}; dc_flags = 1'b0; dc_size = `SZ_L;
				dc_alu = dw[8] ? `ALU_SUBA : `ALU_ADDA;
				if (sz_std == `SZ_B) dc_illegal = 1'b1;
			end else begin dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
		end
	end

	//------------------------------------------------------------------ 0110 Bcc/BRA/BSR
	4'h6: dc_first = S_BCC;

	//------------------------------------------------------------------ 0111 MOVEQ
	4'h7: begin
		if (dw[8]) dc_illegal = 1'b1;
		else begin
			dc_alu = `ALU_MOVE; dc_size = `SZ_L; dc_srck = SK_QUICK; dc_quick = sext8(dw[7:0]);
			dc_dstk = DK_REG; dc_dreg = {1'b0, dw[11:9]};
		end
	end

	//------------------------------------------------------------------ 1000 OR/DIV/SBCD/PACK/UNPK
	4'h8: begin
		case (dw[8:6])
			3'b011, 3'b111: begin
				dc_first = S_MULDIV0; dc_size = `SZ_W; dc_dstk = DK_REG; dc_dreg = {1'b0, dw[11:9]};
				if (ea_dn) dc_srck = SK_REG; else if (ea_imm) dc_srck = SK_IMM; else if (ea_mem) dc_srck = SK_EA; else dc_illegal = 1'b1;
			end
			3'b100: begin
				if (ea_dn) begin dc_alu = `ALU_SBCD; dc_size = `SZ_B; dc_srck = SK_REG; dc_dstk = DK_REG; end
				else if (ea_an) begin dc_first = S_PACK; dc_alu = `ALU_SBCD; dc_size = `SZ_B; end
				else begin dc_alu = `ALU_OR; dc_size = sz_std; dc_srck = SK_REG; dc_sreg = {1'b0, dw[11:9]}; dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
			end
			3'b101, 3'b110: begin
				if (ea_dn || ea_an) dc_first = S_PACK;   // PACK / UNPK
				else begin dc_alu = `ALU_OR; dc_size = sz_std; dc_srck = SK_REG; dc_sreg = {1'b0, dw[11:9]}; dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
			end
			default: begin  // OR <ea>,Dn
				dc_alu = `ALU_OR; dc_size = sz_std; dc_dstk = DK_REG;
				if (ea_dn) dc_srck = SK_REG;
				else if (ea_imm) begin dc_srck = SK_IMM; dc_first = S_GEN_EXEC; end
				else if (ea_mem) begin dc_srck = SK_EA; dc_first = S_GEN_EXEC; end
				else dc_illegal = 1'b1;
			end
		endcase
	end

	//------------------------------------------------------------------ 1001 SUB, 1101 ADD
	4'h9, 4'hD: begin
		case (dw[8:6])
			3'b011, 3'b111: begin  // SUBA/ADDA
				dc_alu = dw[14] ? `ALU_ADDA : `ALU_SUBA; dc_flags = 1'b0; dc_sext = 1'b1;
				dc_size = dw[8] ? `SZ_L : `SZ_W;
				dc_dstk = DK_REG; dc_dreg = {1'b1, dw[11:9]};
				if (ea_dn) dc_srck = SK_REG;
				else if (ea_an) begin dc_srck = SK_REG; dc_sreg = {1'b1, dw[2:0]}; end
				else if (ea_imm) begin dc_srck = SK_IMM; dc_first = S_GEN_EXEC; end
				else if (ea_mem) begin dc_srck = SK_EA; dc_first = S_GEN_EXEC; end
				else dc_illegal = 1'b1;
			end
			3'b100, 3'b101, 3'b110: begin
				dc_size = dw[7:6];
				if (ea_dn) begin dc_alu = dw[14] ? `ALU_ADDX : `ALU_SUBX; dc_srck = SK_REG; dc_dstk = DK_REG; end
				else if (ea_an) begin dc_alu = dw[14] ? `ALU_ADDX : `ALU_SUBX; dc_first = S_PACK; end   // -(Ay),-(Ax) form
				else begin dc_alu = dw[14] ? `ALU_ADD : `ALU_SUB; dc_srck = SK_REG; dc_sreg = {1'b0, dw[11:9]}; dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
			end
			default: begin  // SUB/ADD <ea>,Dn
				dc_alu = dw[14] ? `ALU_ADD : `ALU_SUB; dc_size = sz_std; dc_dstk = DK_REG;
				if (ea_dn) dc_srck = SK_REG;
				else if (ea_an) begin dc_srck = SK_REG; dc_sreg = {1'b1, dw[2:0]}; if (dc_size == `SZ_B) dc_illegal = 1'b1; end
				else if (ea_imm) begin dc_srck = SK_IMM; dc_first = S_GEN_EXEC; end
				else if (ea_mem) begin dc_srck = SK_EA; dc_first = S_GEN_EXEC; end
				else dc_illegal = 1'b1;
			end
		endcase
	end

	//------------------------------------------------------------------ 1010 A-line
	4'hA: dc_illegal = 1'b1;

	//------------------------------------------------------------------ 1011 CMP/CMPA/EOR/CMPM
	4'hB: begin
		case (dw[8:6])
			3'b011, 3'b111: begin  // CMPA
				dc_alu = `ALU_CMPA; dc_wb = 1'b0; dc_sext = 1'b1;
				dc_size = dw[8] ? `SZ_L : `SZ_W;
				dc_dstk = DK_REG; dc_dreg = {1'b1, dw[11:9]};
				if (ea_dn) dc_srck = SK_REG;
				else if (ea_an) begin dc_srck = SK_REG; dc_sreg = {1'b1, dw[2:0]}; end
				else if (ea_imm) begin dc_srck = SK_IMM; dc_first = S_GEN_EXEC; end
				else if (ea_mem) begin dc_srck = SK_EA; dc_first = S_GEN_EXEC; end
				else dc_illegal = 1'b1;
			end
			3'b100, 3'b101, 3'b110: begin
				dc_size = dw[7:6];
				if (ea_an) begin dc_first = S_PACK; dc_alu = `ALU_CMP; end   // CMPM (Ay)+,(Ax)+
				else begin
					dc_alu = `ALU_EOR; dc_srck = SK_REG; dc_sreg = {1'b0, dw[11:9]};
					if (ea_dn) begin dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]}; end
					else begin dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
				end
			end
			default: begin  // CMP <ea>,Dn
				dc_alu = `ALU_CMP; dc_size = sz_std; dc_wb = 1'b0; dc_dstk = DK_REG;
				if (ea_dn) dc_srck = SK_REG;
				else if (ea_an) begin dc_srck = SK_REG; dc_sreg = {1'b1, dw[2:0]}; if (dc_size == `SZ_B) dc_illegal = 1'b1; end
				else if (ea_imm) begin dc_srck = SK_IMM; dc_first = S_GEN_EXEC; end
				else if (ea_mem) begin dc_srck = SK_EA; dc_first = S_GEN_EXEC; end
				else dc_illegal = 1'b1;
			end
		endcase
	end

	//------------------------------------------------------------------ 1100 AND/MUL/ABCD/EXG
	4'hC: begin
		case (dw[8:6])
			3'b011, 3'b111: begin
				dc_first = S_MULDIV0; dc_size = `SZ_W; dc_dstk = DK_REG; dc_dreg = {1'b0, dw[11:9]};
				if (ea_dn) dc_srck = SK_REG; else if (ea_imm) dc_srck = SK_IMM; else if (ea_mem) dc_srck = SK_EA; else dc_illegal = 1'b1;
			end
			3'b100: begin
				if (ea_dn) begin dc_alu = `ALU_ABCD; dc_size = `SZ_B; dc_srck = SK_REG; dc_dstk = DK_REG; end
				else if (ea_an) begin dc_first = S_PACK; dc_alu = `ALU_ABCD; dc_size = `SZ_B; end
				else begin dc_alu = `ALU_AND; dc_size = sz_std; dc_srck = SK_REG; dc_sreg = {1'b0, dw[11:9]}; dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
			end
			3'b101, 3'b110: begin
				if (ea_dn && dw[8:6] == 3'b101) dc_first = S_EXG;        // EXG Dx,Dy
				else if (ea_an && dw[8:6] == 3'b101) dc_first = S_EXG;   // EXG Ax,Ay
				else if (ea_an && dw[8:6] == 3'b110) dc_first = S_EXG;   // EXG Dx,Ay
				else if (ea_dn) dc_illegal = 1'b1;
				else begin dc_alu = `ALU_AND; dc_size = sz_std; dc_srck = SK_REG; dc_sreg = {1'b0, dw[11:9]}; dc_dstk = DK_EA; dc_first = S_GEN_EXEC; if (!ea_memalt) dc_illegal = 1'b1; end
			end
			default: begin
				dc_alu = `ALU_AND; dc_size = sz_std; dc_dstk = DK_REG;
				if (ea_dn) dc_srck = SK_REG;
				else if (ea_imm) begin dc_srck = SK_IMM; dc_first = S_GEN_EXEC; end
				else if (ea_mem) begin dc_srck = SK_EA; dc_first = S_GEN_EXEC; end
				else dc_illegal = 1'b1;
			end
		endcase
	end

	//------------------------------------------------------------------ 1110 shifts / bitfields
	4'hE: begin
		if (dw[11] && dw[7:6] == 2'b11) begin
			dc_first = S_BF0;
			if (!(ea_dn || ea_ctrlalt || (dw[10:8] == 3'b000 || dw[10:8] == 3'b001 || dw[10:8] == 3'b011 || dw[10:8] == 3'b101) && ea_ctrl)) dc_illegal = 1'b1;
		end else if (dw[7:6] == 2'b11) begin
			// memory shift: word, count 1
			dc_size = `SZ_W; dc_srck = SK_QUICK; dc_quick = 32'd1; dc_dstk = DK_EA; dc_first = S_GEN_EXEC;
			case (dw[10:9])
				2'b00: dc_alu = dw[8] ? `ALU_ASL : `ALU_ASR;
				2'b01: dc_alu = dw[8] ? `ALU_LSL : `ALU_LSR;
				2'b10: dc_alu = dw[8] ? `ALU_ROXL : `ALU_ROXR;
				default: dc_alu = dw[8] ? `ALU_ROL : `ALU_ROR;
			endcase
			if (!ea_memalt) dc_illegal = 1'b1;
		end else begin
			// register shift: count immediate (0 -> 8) or Dn mod 64
			dc_size = sz_std; dc_shift = 1'b1;
			dc_dstk = DK_REG; dc_dreg = {1'b0, dw[2:0]};
			if (dw[5]) begin dc_srck = SK_REG; dc_sreg = {1'b0, dw[11:9]}; end
			else begin dc_srck = SK_QUICK; dc_quick = (dw[11:9] == 3'd0) ? 32'd8 : {29'd0, dw[11:9]}; end
			case (dw[4:3])
				2'b00: dc_alu = dw[8] ? `ALU_ASL : `ALU_ASR;
				2'b01: dc_alu = dw[8] ? `ALU_LSL : `ALU_LSR;
				2'b10: dc_alu = dw[8] ? `ALU_ROXL : `ALU_ROXR;
				default: dc_alu = dw[8] ? `ALU_ROL : `ALU_ROR;
			endcase
		end
	end

	//------------------------------------------------------------------ 1111 MMU / coprocessor
	default: begin
		if (dw[11:9] == 3'b000) begin
			// MMU instructions (CpID 0): privileged, the second word decides
			dc_first = S_PMMU0;
			dc_priv = 1'b1;
		end else begin
			case (dw[8:6])
				3'b000: dc_first = S_CP0;                  // cpGEN
				3'b001: begin
					if (ea_an) dc_first = S_CPDBCC;          // cpDBcc
					else if (em == 3'b111 && (er[1] || er == 3'b100)) dc_first = S_CPTRAP;   // cpTRAPcc (opmode 010/011/100 in er)
					else begin dc_first = S_CPSCC; dc_dreg = {1'b0, dw[2:0]}; end   // cpScc
				end
				3'b010, 3'b011: dc_first = S_CPBCC;        // cpBcc.W / .L
				3'b100: begin dc_first = S_CPSAVE0; dc_priv = 1'b1; if (!(ea_ctrlalt || ea_pd)) dc_illegal = 1'b1; end
				3'b101: begin dc_first = S_CPREST0; dc_priv = 1'b1; if (!(ea_ctrl || ea_pi)) dc_illegal = 1'b1; end
				default: dc_illegal = 1'b1;                // F-line emulator
			endcase
		end
	end
	endcase
end

// instructions whose second word is part of the operation (popped with the opcode)
wire dc_needs_ext = (dc_first == S_MULDIV0 && dw[15:12] == 4'h4) || (dc_first == S_CHK2_0) ||
                    (dc_first == S_CAS0) || (dc_first == S_CAS2_0) || (dc_first == S_BF0) ||
                    (dc_first == S_MOVES0) || (dc_first == S_MOVEC) || (dc_first == S_PMMU0) ||
                    (dc_first == S_CP0) || (dc_first == S_CPSCC) || (dc_first == S_CPDBCC) || (dc_first == S_CPTRAP) ||
                    (dc_first == S_MOVEP0) || (dc_first == S_MOVEM0) || (dc_first == S_LINK) || (dc_first == S_RTD) || (dc_first == S_STOP) ||
                    (dc_first == S_DBCC) || (dc_first == S_PACK && (dw[8:6] == 3'b101 || dw[8:6] == 3'b110) && dw[15:12] == 4'h8);
// instructions that evaluate their memory EA (no operand read) before their first state
wire dc_eaonly = ea_mem && ((dc_first == S_LEA) || (dc_first == S_PEA) || (dc_first == S_JMP) || (dc_first == S_JSR) ||
                            (dc_first == S_TAS) || (dc_first == S_SCC) || (dc_first == S_MOVE_FSR) || (dc_first == S_CAS0) ||
                            (dc_first == S_CHK2_0) || (dc_first == S_BF0) || (dc_first == S_MOVES0) ||
                            (dc_first == S_CPSAVE0 && !ea_pd) || (dc_first == S_CPREST0 && !ea_pi) ||   // the frame length sets the step
                            (dc_first == S_MOVEM0 && !ea_pi && !ea_pd));
