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

// The tag row holds everything the lookup needs: the four way tags, their
// valid bits and the round-robin victim pointer.  Keeping validity and LRU
// here rather than in flop arrays puts them in M10K with the tags instead
// of in LABs.  The row is carried by the project's true-dual-port dpram
// (rtl/bram.vhd -> altsyncram), so port B can invalidate on a store while
// port A serves lookups and fills; inferring a second write port from a
// bare array does NOT map to M10K and costs ~3000 ALMs instead.
//
//   row = { rr[1:0], valid[3:0], tag3, tag2, tag1, tag0 }   (94 bits)
localparam TAGW = 22;
localparam ROWW = 2 + 4 + 4*TAGW;

(* ramstyle = "no_rw_check" *) reg [31:0] cdata [0:2047];  // {bank, set, way, word}

wire [ROWW-1:0] tag_q;
reg  [31:0] data_q;

// RAM control (driven combinationally from the FSM state so the arrays
// infer as block RAM: no resets, enable-gated synchronous reads)
wire        tag_we;
wire  [6:0] tag_ridx, tag_widx;
wire [ROWW-1:0] tag_wdat;
wire        inv_we;              // port B: store invalidation
wire  [6:0] inv_idx;
wire        cd_rd_en, cd_we;
wire [10:0] cd_ridx, cd_widx;
wire [31:0] cd_wdat;

// Reads free-run: the address is held for the whole request, so a stalled
// ce simply re-reads the same row.  Only the writes are ce-gated.
dpram #(7, ROWW) ctag_ram
(
	.clock     (clk),
	.address_a (tag_we ? tag_widx : tag_ridx),
	.data_a    (tag_wdat),
	.wren_a    (ce & tag_we),
	.q_a       (tag_q),
	.address_b (inv_idx),
	.data_b    ({ROWW{1'b0}}),
	.wren_b    (ce & inv_we),
	.q_b       ()
);

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
                        (c_size == `AP040_SZ_W && !c_addr[0]) ||
                        (c_size == `AP040_SZ_L && c_addr[1:0] == 2'b00);
wire        bypass    = c_nocache || !ena || c_write || !fits_long;

// Number of bytes following the first byte.  Use a five-bit sum so a
// transfer ending beyond offset 15 cannot wrap before the comparison.
wire  [2:0] write_tail = (c_size == `AP040_SZ_B) ? 3'd0 :
                          (c_size == `AP040_SZ_W) ? 3'd1 : 3'd3;
wire        write_cross_line = ({1'b0, c_addr[3:0]} +
                                 {2'd0, write_tail}) > 5'd15;

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
localparam C_WINV  = 3'd3;   // second-line invalidate owed by a store
localparam C_FILL  = 3'd4;
localparam C_TAGW  = 3'd5;
localparam C_PASS  = 3'd6;
localparam C_SWEEP = 3'd7;   // reset / CINV: walk the rows clearing them

reg   [2:0] cst;
reg   [6:0] sweep_cnt;
reg         sweep_all;   // reset sweep clears both banks
reg         winv_pend;   // a store still owes its second-line invalidate
reg   [5:0] winv_set2;
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
wire v_w0 = tag_q[88];
wire v_w1 = tag_q[89];
wire v_w2 = tag_q[90];
wire v_w3 = tag_q[91];
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

assign tag_ridx  = a_row;
wire [87:0] tags_next = (r_way == 2'd0) ? {tag_q[87:22], r_tag} :
                        (r_way == 2'd1) ? {tag_q[87:44], r_tag, tag_q[21:0]} :
                        (r_way == 2'd2) ? {tag_q[87:66], r_tag, tag_q[43:0]} :
                                          {r_tag, tag_q[65:0]};
wire  [3:0] val_next  = tag_q[91:88] | (4'd1 << r_way);
wire        sweep_hit = sweep_all || (sweep_cnt[6] ? cinv_ic : cinv_dc);
assign tag_we    = (cst == C_TAGW) || ((cst == C_SWEEP) && sweep_hit);
assign tag_widx  = (cst == C_SWEEP) ? sweep_cnt : r_row;
assign tag_wdat  = (cst == C_SWEEP) ? {ROWW{1'b0}}
                                    : {tag_q[93:92] + 2'd1, val_next, tags_next};

// Port B: a store invalidates the data-bank set it touches, and the next
// set when the transfer crosses the line.  A cleared row needs no
// read-modify-write -- the tags left behind are never consulted without
// their valid bit.  The 68040 leaves the instruction cache alone here.
assign inv_we    = ((cst == C_IDLE) && c_req && c_write && !ack_r) ||
                   ((cst == C_PASS) && winv_pend) ||
                   (cst == C_WINV);
assign inv_idx   = (cst == C_IDLE) ? {1'b0, c_addr[9:4]} : {1'b0, winv_set2};
assign cd_rd_en  = (cst == C_LOOK) && look_hit;
assign cd_ridx   = {r_bank, r_row[5:0], hit_way, r_addr[3:2]};
assign cd_we     = (cst == C_FILL) && r_issued && m_ack;
assign cd_widx   = {r_bank, r_row[5:0], r_way, r_beat};
assign cd_wdat   = m_rdata;

always @(posedge clk) begin
	if (!nreset) begin
		// the tag RAM has no reset, so sweep it clear before serving
		// anything: a garbage row would otherwise read back as a hit
		cst <= C_SWEEP;
		sweep_cnt <= 0;
		sweep_all <= 1;
		winv_pend <= 0;
		winv_set2 <= 0;
		cinv_done <= 0;
		r_row <= 0; r_tag <= 0; r_word <= 0; r_way <= 0; r_bank <= 0;
		r_beat <= 0; r_issued <= 0; r_addr <= 0; r_size <= 0; r_off <= 0;
		fill_hold <= 0; ack_r <= 0; rdata_r <= 0;
	end
	else if (ce) begin
		ack_r <= 0;
		cinv_done <= 0;

		case (cst)
			C_IDLE: begin
				if (cinv_req && !cinv_done) begin
					sweep_cnt <= 0;
					sweep_all <= 0;   // honour the cinv_ic/cinv_dc selects
					cst <= C_SWEEP;
				end
				else if (c_req && !ack_r) begin
					if (c_write) begin
						// write-through.  Port B clears the set this store
						// touches; a store crossing the line owes a second
						// one, taken during the pass wait, or in C_WINV if
						// the write acked immediately.
						winv_set2 <= c_addr[9:4] + 6'd1;
						if (m_ack) begin
							if (write_cross_line) cst <= C_WINV;
						end
						else begin
							winv_pend <= write_cross_line;
							cst <= C_PASS;
						end
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

			C_PASS: begin
				winv_pend <= 0;   // port B takes it in this same cycle
				if (m_ack) cst <= C_IDLE;
			end

			C_WINV: cst <= C_IDLE;

			C_SWEEP: begin
				// one row per cycle; port A writes it (see sweep_hit)
				sweep_cnt <= sweep_cnt + 7'd1;
				if (sweep_cnt == 7'd127) begin
					if (!sweep_all) cinv_done <= 1;
					sweep_all <= 0;
					cst <= C_IDLE;
				end
			end

			C_LOOK: begin
				if (look_hit) begin
					// the data RAM read runs in parallel (cd_rd_en)
					cst <= C_RDD;
				end
				else begin
					r_way <= tag_q[93:92];   // round-robin victim
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
				// the tag row write runs in parallel (tag_we): new tag,
				// its valid bit, and the advanced round robin
				rdata_r <= lw_extract(fill_hold, r_size, r_off);
				ack_r <= 1;
				cst <= C_IDLE;
			end

			default: cst <= C_IDLE;
		endcase
	end
end

endmodule
