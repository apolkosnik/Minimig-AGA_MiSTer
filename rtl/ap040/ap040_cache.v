//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_cache.v - internal instruction and data caches (milestone G)       //
//                                                                          //
// 4KB per side: 64 sets x 4 ways x 16 byte lines, physically tagged        //
// (sits between the MMU and the 16-bit bus adapter). Write-through with    //
// invalidate-on-write: writes always go to memory and clear any matching   //
// data cache set, so no dirty state ever exists and CPUSH degenerates to   //
// CINV. Cacheable reads must fit inside one aligned longword; misaligned   //
// and line-crossing accesses, walker cycles and cache-inhibited pages      //
// bypass the cache entirely.                                               //
//                                                                          //
// The instruction cache is not snooped by CPU writes (as on the real       //
// 68040): self-modifying code must execute CINV, which invalidates the     //
// whole selected cache (over-invalidation is architecturally safe).        //
//                                                                          //
// Storage: line data in one synchronous RAM (2 banks x 1024 longwords),    //
// tags in one wide synchronous RAM row per {bank, set} (4 ways of 22       //
// bits), valid bits in flip-flops for single-cycle invalidation.           //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_cache
(
	input             clk,
	input             nreset,
	input             ce,

	input             ie,          // CACR instruction cache enable
	input             de,          // CACR data cache enable

	input             cinv_req,
	input             cinv_ic,
	input             cinv_dc,
	output reg        cinv_done,

	// slave side (from the MMU)
	input             c_req,
	input             c_write,
	input             c_instr,
	input       [1:0] c_size,
	input      [31:0] c_addr,
	input      [31:0] c_wdata,
	input       [2:0] c_fc,
	input             c_nocache,
	output            c_ack,
	output     [31:0] c_rdata,

	// master side (to the bus adapter)
	output            m_req,
	output            m_write,
	output            m_instr,
	output      [1:0] m_size,
	output     [31:0] m_addr,
	output     [31:0] m_wdata,
	output      [2:0] m_fc,
	input             m_ack,
	input      [31:0] m_rdata
);

//---------------------------------------------------------------------------
// storage
//---------------------------------------------------------------------------

(* ramstyle = "no_rw_check" *) reg [87:0] ctag [0:127];   // 4 way tags per row
(* ramstyle = "no_rw_check" *) reg [31:0] cdata [0:2047];  // {bank, set, way, word}
reg         cval [0:511];        // {bank, set, way}
reg   [1:0] crr  [0:127];        // round robin per {bank, set}

reg  [87:0] tag_q;               // no reset: RAM read-side registers
reg  [31:0] data_q;

// RAM control (driven combinationally from the FSM state so the arrays
// infer as block RAM: no resets, enable-gated synchronous reads)
wire        tag_rd_en, tag_we;
wire  [6:0] tag_ridx, tag_widx;
wire [87:0] tag_wdat;
wire        cd_rd_en, cd_we;
wire [10:0] cd_ridx, cd_widx;
wire [31:0] cd_wdat;

always @(posedge clk) begin
	if (ce & tag_we)    ctag[tag_widx] <= tag_wdat;
	if (ce & tag_rd_en) tag_q <= ctag[tag_ridx];
end

always @(posedge clk) begin
	if (ce & cd_we)    cdata[cd_widx] <= cd_wdat;
	if (ce & cd_rd_en) data_q <= cdata[cd_ridx];
end

//---------------------------------------------------------------------------
// request classification
//---------------------------------------------------------------------------

wire        ena       = c_instr ? ie : de;
// the access must sit inside one aligned longword to be served
wire        fits_long = (c_size == `AP040_SZ_B) ||
                        (c_size == `AP040_SZ_W && c_addr[1:0] != 2'b11) ||
                        (c_size == `AP040_SZ_L && c_addr[1:0] == 2'b00);
wire        bypass    = c_nocache || !ena || c_write || !fits_long;

wire  [5:0] a_set  = c_addr[9:4];
wire [21:0] a_tag  = c_addr[31:10];
wire  [6:0] a_row  = {c_instr, a_set};

// cacheable read acceptance out of idle (shared with the tag RAM read)
wire rd_accept;

//---------------------------------------------------------------------------
// FSM
//---------------------------------------------------------------------------

localparam C_IDLE  = 3'd0;
localparam C_LOOK  = 3'd1;
localparam C_RDD   = 3'd2;
localparam C_ACK   = 3'd3;
localparam C_FILL  = 3'd4;
localparam C_TAGW  = 3'd5;
localparam C_PASS  = 3'd6;

reg   [2:0] cst;
reg   [6:0] r_row;
reg  [21:0] r_tag;
reg   [3:0] r_word;              // {word[1:0]} of the request, plus bank/way
reg   [1:0] r_way;
reg         r_bank;
reg   [1:0] r_beat;
reg         r_issued;
reg  [31:0] r_addr;
reg   [1:0] r_size;
reg   [1:0] r_off;
reg  [31:0] fill_hold;           // requested longword captured during fill
reg         ack_r;
reg  [31:0] rdata_r;

wire [21:0] t_w0 = tag_q[21:0];
wire [21:0] t_w1 = tag_q[43:22];
wire [21:0] t_w2 = tag_q[65:44];
wire [21:0] t_w3 = tag_q[87:66];
wire v_w0 = cval[{r_bank, r_row[5:0], 2'd0}];
wire v_w1 = cval[{r_bank, r_row[5:0], 2'd1}];
wire v_w2 = cval[{r_bank, r_row[5:0], 2'd2}];
wire v_w3 = cval[{r_bank, r_row[5:0], 2'd3}];
wire h0 = v_w0 && (t_w0 == r_tag);
wire h1 = v_w1 && (t_w1 == r_tag);
wire h2 = v_w2 && (t_w2 == r_tag);
wire h3 = v_w3 && (t_w3 == r_tag);
wire      look_hit = h0 | h1 | h2 | h3;
wire [1:0] hit_way = h0 ? 2'd0 : h1 ? 2'd1 : h2 ? 2'd2 : 2'd3;

// size extraction from a cached longword (big endian lanes)
function [31:0] lw_extract;
	input [31:0] lw;
	input [1:0] size;
	input [1:0] off;
	begin
		case (size)
			`AP040_SZ_B:
				case (off)
					2'd0: lw_extract = {24'd0, lw[31:24]};
					2'd1: lw_extract = {24'd0, lw[23:16]};
					2'd2: lw_extract = {24'd0, lw[15:8]};
					default: lw_extract = {24'd0, lw[7:0]};
				endcase
			`AP040_SZ_W:
				lw_extract = off[1] ? {16'd0, lw[15:0]} : {16'd0, lw[31:16]};
			default: lw_extract = lw;
		endcase
	end
endfunction

//---------------------------------------------------------------------------
// forwarding
//---------------------------------------------------------------------------

wire pass_active = (cst == C_IDLE && c_req && bypass && !ack_r) || (cst == C_PASS);
wire fill_active = (cst == C_FILL);

assign m_req   = fill_active ? 1'b1 : (pass_active ? c_req : 1'b0);
assign m_write = fill_active ? 1'b0 : c_write;
assign m_instr = c_instr;
assign m_size  = fill_active ? `AP040_SZ_L : c_size;
assign m_addr  = fill_active ? {r_addr[31:4], r_beat, 2'b00} : c_addr;
assign m_wdata = c_wdata;
assign m_fc    = c_fc;

assign c_ack   = pass_active ? m_ack : ack_r;
assign c_rdata = pass_active ? m_rdata : rdata_r;

assign rd_accept = (cst == C_IDLE) && !(cinv_req && !cinv_done) &&
                   c_req && !ack_r && !c_write && !bypass;

assign tag_rd_en = rd_accept;
assign tag_ridx  = a_row;
assign tag_we    = (cst == C_TAGW);
assign tag_widx  = r_row;
assign tag_wdat  = (r_way == 2'd0) ? {tag_q[87:22], r_tag} :
                   (r_way == 2'd1) ? {tag_q[87:44], r_tag, tag_q[21:0]} :
                   (r_way == 2'd2) ? {tag_q[87:66], r_tag, tag_q[43:0]} :
                                     {r_tag, tag_q[65:0]};
assign cd_rd_en  = (cst == C_LOOK) && look_hit;
assign cd_ridx   = {r_bank, r_row[5:0], hit_way, r_addr[3:2]};
assign cd_we     = (cst == C_FILL) && r_issued && m_ack;
assign cd_widx   = {r_bank, r_row[5:0], r_way, r_beat};
assign cd_wdat   = m_rdata;

integer k;

always @(posedge clk) begin
	if (!nreset) begin
		cst <= C_IDLE;
		cinv_done <= 0;
		r_row <= 0; r_tag <= 0; r_word <= 0; r_way <= 0; r_bank <= 0;
		r_beat <= 0; r_issued <= 0; r_addr <= 0; r_size <= 0; r_off <= 0;
		fill_hold <= 0; ack_r <= 0; rdata_r <= 0;
		for (k = 0; k < 512; k = k + 1) cval[k] <= 0;
		for (k = 0; k < 128; k = k + 1) crr[k] <= 0;
	end
	else if (ce) begin
		ack_r <= 0;
		cinv_done <= 0;

		case (cst)
			C_IDLE: begin
				if (cinv_req && !cinv_done) begin
					for (k = 0; k < 512; k = k + 1) begin
						if ((k[8] && cinv_ic) || (!k[8] && cinv_dc))
							cval[k] <= 0;
					end
					cinv_done <= 1;
				end
				else if (c_req && !ack_r) begin
					if (c_write) begin
						// write-through: invalidate both possibly touched
						// data cache sets while the write passes through
						for (k = 0; k < 4; k = k + 1) begin
							cval[{1'b0, c_addr[9:4], k[1:0]}] <= 0;
							cval[{1'b0, c_addr[9:4] + 6'd1, k[1:0]}] <=
								((c_addr[3:0] + {2'd0, c_size} + 4'd1) > 4'hF) ? 1'b0
								: cval[{1'b0, c_addr[9:4] + 6'd1, k[1:0]}];
						end
						if (m_ack) ;   // pass path acks combinationally
						else cst <= C_PASS;
					end
					else if (bypass) begin
						if (!m_ack) cst <= C_PASS;
					end
					else begin
						// cacheable read: the tag row read runs in parallel
						r_row <= a_row;
						r_tag <= a_tag;
						r_bank <= c_instr;
						r_addr <= c_addr;
						r_size <= c_size;
						r_off <= c_addr[1:0];
						r_word <= {2'd0, c_addr[3:2]};
						cst <= C_LOOK;
					end
				end
			end

			C_PASS: if (m_ack) cst <= C_IDLE;

			C_LOOK: begin
				if (look_hit) begin
					// the data RAM read runs in parallel (cd_rd_en)
					cst <= C_RDD;
				end
				else begin
					r_way <= crr[r_row];
					r_beat <= 0;
					r_issued <= 0;
					cst <= C_FILL;
				end
			end

			C_RDD: begin
				rdata_r <= lw_extract(data_q, r_size, r_off);
				ack_r <= 1;
				cst <= C_IDLE;
			end

			C_FILL: begin
				if (!r_issued) r_issued <= 1;
				else if (m_ack) begin
					// the data RAM write runs in parallel (cd_we)
					if (r_beat == r_addr[3:2]) fill_hold <= m_rdata;
					r_issued <= 0;
					if (r_beat == 2'd3) cst <= C_TAGW;
					else r_beat <= r_beat + 2'd1;
				end
			end

			C_TAGW: begin
				// the tag row write runs in parallel (tag_we)
				cval[{r_bank, r_row[5:0], r_way}] <= 1;
				crr[r_row] <= crr[r_row] + 2'd1;
				rdata_r <= lw_extract(fill_hold, r_size, r_off);
				ack_r <= 1;
				cst <= C_IDLE;
			end

			default: cst <= C_IDLE;
		endcase
	end
end

endmodule
