//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_ucache.v - unified L1 cache, the successor to ap040_cache.v        //
//                                                                          //
// 8KB: 128 sets x 4 ways x 16 byte lines, physically tagged, one storage   //
// for instructions and data.  Same total storage as the split cache it     //
// replaces (128 tag rows, 512 longwords per way) -- what changes is what   //
// the organisation buys:                                                   //
//                                                                          //
//   * SELF-MODIFYING CODE IS CORRECT BY CONSTRUCTION.  A store that hits   //
//     updates the line in place, and an instruction fetch of that line     //
//     reads the updated bytes, because they are the same bytes.  The       //
//     chip-window instruction-fetch bypass (192d82ce) -- measured at       //
//     25-34% of all chip-window execution -- is retired by this module.    //
//     This deliberately makes stores MORE coherent than real 68040         //
//     silicon, where the I-cache is not snooped by CPU writes; software    //
//     that requires staleness does not exist, software that requires       //
//     coherence (all A500-era self-modifying code) is common.             //
//                                                                          //
//   * STORES NO LONGER DESTROY THE CACHE.  The split cache invalidated     //
//     the whole set on every store (one port-B row write of zero), so a    //
//     read-modify-write of one resident line cost ~36 cycles per access    //
//     against 10.7 warm (bw_probe block 8).  Here an aligned store that    //
//     hits merges its bytes into the hitting way; only misaligned stores   //
//     that cannot be located in one longword fall back to the old          //
//     invalidate-the-set path.                                             //
//                                                                          //
//   * SNOOPS REACH CODE.  Chipset DMA writes invalidate the matching set   //
//     wherever it is -- there is no I bank a snoop cannot see, which was   //
//     the entire reason the bypass existed.                                //
//                                                                          //
// Write-through, no write-allocate: memory is always current, no dirty     //
// state exists, CPUSH degenerates to CINV, and any invalidation is         //
// correctness-safe.  CINV IC/DC selectivity becomes over-invalidation      //
// (either clears everything), which write-through makes safe.              //
//                                                                          //
// Carried forward from ap040_cache.v, because each was paid for:           //
//   * an aborted fill invalidates the row it was filling -- the victim     //
//     way's old tag was still live over overwritten data (4871fa16);       //
//   * the fill's tag writeback composes from the LIVE tag row, so a        //
//     concurrent CINV sweep or snoop is not undone (snapshot hazard);      //
//   * snoops are free-running (a chipset write must land while clkena is   //
//     frozen) and poison any fill or lookup whose row they touch;          //
//   * a cache-inhibited access that hits a resident line invalidates it    //
//     while it bypasses, without ever wedging a store (5528ecd1);          //
//   * c_ack is registered, never combinational in c_req (the 5.9ns ATC     //
//     path that once kept these caches disabled).                          //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_ucache
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
	input      [31:0] m_rdata,
	input             m_err,

	// free-running snoop, as in ap040_cache.v
	input             s_stb,
	input      [31:0] s_addr
);

//---------------------------------------------------------------------------
// storage
//---------------------------------------------------------------------------

//   row = { rr[1:0], valid[3:0], tag3, tag2, tag1, tag0 }   (90 bits)
localparam TAGW = 21;
localparam ROWW = 2 + 4 + 4*TAGW;

// One data RAM per way, 512 longwords ({set[6:0], word[1:0]}).  Each way is
// built from FOUR byte-wide arrays rather than one 32-bit array with
// conditional part-selects: a line fill writes all four lanes, a store merge
// writes only the lanes it touches, and byte-wide arrays are the only shape
// Quartus 17.0 reliably infers as M10K under that pattern.  Writing
// `if (be[n]) arr[idx][hi:lo] <= ...` into a 32-bit array instead sent all
// four ways into LABs: 87,184 ALMs, 208% of the device, build refused.  The
// same split is what cpu_cache_new's dpram_be_1024x16 does, for the same
// reason.
wire [ROWW-1:0] tag_q;
wire [31:0] data_q0, data_q1, data_q2, data_q3;

wire        tag_we;
wire  [6:0] tag_ridx, tag_widx;
wire [ROWW-1:0] tag_wdat;
wire        inv_we;
wire        inv_wren;
wire  [6:0] inv_idx;
wire        cd_rd_en;
wire  [8:0] cd_ridx, cd_widx;
wire  [3:0] cd_wsel;             // one bit per way
wire  [3:0] cd_be;               // byte lanes within the longword
wire [31:0] cd_wdat;

dpram #(7, ROWW) ctag_ram
(
	.clock     (clk),
	.address_a (tag_we ? tag_widx : tag_ridx),
	.data_a    (tag_wdat),
	.wren_a    (ce & tag_we),
	.q_a       (tag_q),
	.address_b (inv_idx),
	.data_b    ({ROWW{1'b0}}),
	.wren_b    (inv_wren),
	.q_b       ()
);

ap040_ucache_way way0 (.clk(clk), .ce(ce), .we(cd_wsel[0]), .be(cd_be),
	.waddr(cd_widx), .wdata(cd_wdat), .rd_en(cd_rd_en), .raddr(cd_ridx),
	.q(data_q0));
ap040_ucache_way way1 (.clk(clk), .ce(ce), .we(cd_wsel[1]), .be(cd_be),
	.waddr(cd_widx), .wdata(cd_wdat), .rd_en(cd_rd_en), .raddr(cd_ridx),
	.q(data_q1));
ap040_ucache_way way2 (.clk(clk), .ce(ce), .we(cd_wsel[2]), .be(cd_be),
	.waddr(cd_widx), .wdata(cd_wdat), .rd_en(cd_rd_en), .raddr(cd_ridx),
	.q(data_q2));
ap040_ucache_way way3 (.clk(clk), .ce(ce), .we(cd_wsel[3]), .be(cd_be),
	.waddr(cd_widx), .wdata(cd_wdat), .rd_en(cd_rd_en), .raddr(cd_ridx),
	.q(data_q3));

//---------------------------------------------------------------------------
// request classification
//---------------------------------------------------------------------------

wire        ena       = c_instr ? ie : de;
wire        fits_long = (c_size == `AP040_SZ_B) ||
                        (c_size == `AP040_SZ_W && !c_addr[0]) ||
                        (c_size == `AP040_SZ_L && c_addr[1:0] == 2'b00);
wire        bypass    = c_nocache || !ena || c_write || !fits_long;

// A store whose bytes sit inside one aligned longword can be located in the
// tag row and merged.  Anything else (misaligned word/long, line crossers)
// keeps the split cache's invalidate-the-set path.
wire        st_mergeable = fits_long && ena && !c_nocache;

wire  [2:0] write_tail = (c_size == `AP040_SZ_B) ? 3'd0 :
                          (c_size == `AP040_SZ_W) ? 3'd1 : 3'd3;
wire        write_cross_line = ({1'b0, c_addr[3:0]} +
                                 {2'd0, write_tail}) > 5'd15;

wire  [6:0] a_set  = c_addr[10:4];
wire [20:0] a_tag  = c_addr[31:11];
wire  [6:0] a_row  = a_set;

wire rd_accept;

//---------------------------------------------------------------------------
// FSM
//---------------------------------------------------------------------------

localparam C_IDLE  = 3'd0;
localparam C_LOOK  = 3'd1;
localparam C_FERR  = 3'd2;
localparam C_WINV  = 3'd3;
localparam C_FILL  = 3'd4;
localparam C_TAGW  = 3'd5;
localparam C_PASS  = 3'd6;
localparam C_SWEEP = 3'd7;

reg   [2:0] cst;
reg   [7:0] sweep_cnt;
reg         sweep_all;
reg         winv_pend;
reg   [6:0] winv_set2;
reg         store_inv_lost;
reg   [6:0] store_inv_set;
reg   [6:0] r_row;
reg  [20:0] r_tag;
reg   [1:0] r_way;
reg   [1:0] r_beat;
reg         r_issued;
reg  [31:0] r_addr;
reg   [1:0] r_size;
reg   [1:0] r_off;
reg  [31:0] fill_hold;
reg         ack_r;
reg  [31:0] rdata_r;
reg         st_merge_arm;   // this PASS may merge on hit at its m_ack
reg         st_inv_arm;     // this PASS records a hit for invalidation
reg         st_snooped;     // a snoop touched the store's row: no merge

wire [20:0] t_w0 = tag_q[20:0];
wire [20:0] t_w1 = tag_q[41:21];
wire [20:0] t_w2 = tag_q[62:42];
wire [20:0] t_w3 = tag_q[83:63];
wire v_w0 = tag_q[84];
wire v_w1 = tag_q[85];
wire v_w2 = tag_q[86];
wire v_w3 = tag_q[87];
wire h0 = v_w0 && (t_w0 == r_tag);
wire h1 = v_w1 && (t_w1 == r_tag);
wire h2 = v_w2 && (t_w2 == r_tag);
wire h3 = v_w3 && (t_w3 == r_tag);
wire      look_hit = h0 | h1 | h2 | h3;
wire [1:0] hit_way = h0 ? 2'd0 : h1 ? 2'd1 : h2 ? 2'd2 : 2'd3;

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

// inverse of lw_extract: which byte lanes a store touches, and the merge
// word with the store data placed on those lanes (big endian)
function [3:0] st_lanes;
	input [1:0] size;
	input [1:0] off;
	begin
		case (size)
			`AP040_SZ_B:
				case (off)
					2'd0: st_lanes = 4'b1000;
					2'd1: st_lanes = 4'b0100;
					2'd2: st_lanes = 4'b0010;
					default: st_lanes = 4'b0001;
				endcase
			`AP040_SZ_W:
				st_lanes = off[1] ? 4'b0011 : 4'b1100;
			default: st_lanes = 4'b1111;
		endcase
	end
endfunction

function [31:0] st_place;
	input [31:0] wd;
	input [1:0] size;
	input [1:0] off;
	begin
		case (size)
			`AP040_SZ_B: st_place = {wd[7:0], wd[7:0], wd[7:0], wd[7:0]};
			`AP040_SZ_W: st_place = {wd[15:0], wd[15:0]};
			default:     st_place = wd;
		endcase
	end
endfunction

// snoop collision tracking, as in the split cache but bankless: any lookup,
// fill or store-merge whose row a snoop touches is poisoned
wire snoop_fill_row = s_stb && (s_addr[10:4] == r_row);
wire snoop_look_row = s_stb && (s_addr[10:4] == a_set);
// a store's poisoning window runs from acceptance (row = a_set) through
// PASS (row = r_row); a snoop landing in exactly the merge cycle needs no
// flag -- same-row means the row is being invalidated anyway, so a merge
// into it is moot, and different-row does not disturb the port A read
wire snoop_fill_row_st = s_stb && (s_addr[10:4] ==
                         ((cst == C_IDLE) ? a_set : r_row));
reg  fill_snooped, look_snooped;
always @(posedge clk) begin
	if (!nreset) begin
		fill_snooped <= 0;
		look_snooped <= 0;
		st_snooped   <= 0;
	end
	else begin
		if (ce && cst == C_LOOK && !look_hit) fill_snooped <= 0;
		if ((cst == C_FILL || cst == C_TAGW) && snoop_fill_row)
			fill_snooped <= 1;
		if (ce && rd_accept) look_snooped <= 0;
		if ((rd_accept || cst == C_LOOK) && snoop_look_row)
			look_snooped <= 1;
		// the store's tag image is read across acceptance and PASS; a
		// snoop anywhere in that window makes the compare unreliable
		// (mixed-port read-during-write is DONT_CARE), so the merge is
		// abandoned for this store -- never merged into a way chosen
		// from a poisoned compare, which could corrupt an innocent line
		if (ce && cst == C_IDLE) st_snooped <= 0;
		if (((cst == C_IDLE) || (cst == C_PASS)) && snoop_fill_row_st)
			st_snooped <= 1;
	end
end

//---------------------------------------------------------------------------
// forwarding
//---------------------------------------------------------------------------

wire pass_active = (cst == C_PASS);
wire fill_active = (cst == C_FILL);

reg  err_hold;
reg        pass_ci_chk;
reg        ci_inv_pend;
reg  [6:0] ci_inv_row;

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
                   c_req && !ack_r && !c_write && !bypass && !ci_inv_pend;

assign tag_ridx  = a_row;
wire [83:0] tags_next = (r_way == 2'd0) ? {tag_q[83:21], r_tag} :
                        (r_way == 2'd1) ? {tag_q[83:42], r_tag, tag_q[20:0]} :
                        (r_way == 2'd2) ? {tag_q[83:63], r_tag, tag_q[41:0]} :
                                          {r_tag, tag_q[62:0]};
wire  [3:0] val_next  = tag_q[87:84] | (4'd1 << r_way);
// unified storage: CINV of either cache clears everything (over-
// invalidation, safe under write-through)
wire        sweep_hit = sweep_all || cinv_ic || cinv_dc;
assign tag_we    = ((cst == C_TAGW) && !fill_snooped && !snoop_fill_row) ||
                   ((cst == C_SWEEP) && sweep_hit);
assign tag_widx  = (cst == C_SWEEP) ? sweep_cnt[6:0] : r_row;
assign tag_wdat  = (cst == C_SWEEP) ? {ROWW{1'b0}}
                                    : {tag_q[89:88] + 2'd1, val_next, tags_next};

// Port B: snoops (free-running, highest priority), the aborted-fill row
// clear, the CI-hit invalidate, and the residual store-invalidate path --
// which now serves ONLY stores that cannot be merged: misaligned/crossing
// stores, and stores whose tag compare a snoop poisoned or that hit under
// a cache-inhibited or disabled mapping.
wire store_inv = ((cst == C_IDLE) && c_req && c_write && !ack_r &&
                  !st_mergeable && !store_inv_lost) ||
                 ((cst == C_PASS) && winv_pend) ||
                 (cst == C_WINV);
wire snoop_wr  = s_stb && !((cst == C_SWEEP) && sweep_hit &&
                            (sweep_cnt[6:0] == s_addr[10:4]));
wire fill_err_inv = (cst == C_FERR) && !snoop_wr;
wire ci_inv = ci_inv_pend && !snoop_wr && !store_inv && !store_inv_lost &&
              !fill_err_inv;

assign inv_we   = snoop_wr || store_inv || store_inv_lost || fill_err_inv ||
                  ci_inv;
assign inv_wren = snoop_wr | (ce & (store_inv | store_inv_lost | fill_err_inv |
                                    ci_inv));
assign inv_idx  = snoop_wr        ? s_addr[10:4] :
                  fill_err_inv    ? r_row :
                  ci_inv          ? ci_inv_row :
                  store_inv_lost ? store_inv_set :
                  (cst == C_IDLE) ? c_addr[10:4] : winv_set2;

assign cd_rd_en  = rd_accept;
assign cd_ridx   = {a_set, c_addr[3:2]};

// data writes: a fill beat, or a store merge in its PASS m_ack cycle
wire st_merge_now = pass_active && st_merge_arm && !st_snooped &&
                    look_hit && m_ack && !m_err;
assign cd_wsel = ((cst == C_FILL) && r_issued && m_ack) ? (4'd1 << r_way) :
                 st_merge_now ? (4'd1 << hit_way) : 4'd0;
assign cd_be   = fill_active ? 4'b1111 : st_lanes(r_size, r_off);
assign cd_widx = fill_active ? {r_row, r_beat} : {r_row, r_addr[3:2]};
assign cd_wdat = fill_active ? m_rdata : st_place(c_wdata, r_size, r_off);

wire [31:0] data_hit = (hit_way == 2'd0) ? data_q0 :
                       (hit_way == 2'd1) ? data_q1 :
                       (hit_way == 2'd2) ? data_q2 : data_q3;

always @(posedge clk) begin
	if (!nreset) begin
		cst <= C_SWEEP;
		sweep_cnt <= 0;
		sweep_all <= 1;
		winv_pend <= 0;
		winv_set2 <= 0;
		err_hold <= 0;
		pass_ci_chk <= 0;
		ci_inv_pend <= 0;
		ci_inv_row <= 0;
		store_inv_lost <= 0;
		store_inv_set <= 0;
		cinv_done <= 0;
		st_merge_arm <= 0;
		st_inv_arm <= 0;
		r_row <= 0; r_tag <= 0; r_way <= 0;
		r_beat <= 0; r_issued <= 0; r_addr <= 0; r_size <= 0; r_off <= 0;
		fill_hold <= 0; ack_r <= 0; rdata_r <= 0;
	end
	else if (ce) begin
		ack_r <= 0;
		cinv_done <= 0;
		if (ci_inv) ci_inv_pend <= 0;

		if (snoop_wr && (cst == C_IDLE) && c_req && c_write && !ack_r &&
		    !st_mergeable && !store_inv_lost) begin
			store_inv_lost <= 1;
			store_inv_set  <= c_addr[10:4];
		end
		else if (store_inv_lost && !s_stb)
			store_inv_lost <= 0;

		case (cst)
			C_IDLE: begin
				if (!c_req) err_hold <= 0;
				if (cinv_req && !cinv_done) begin
					sweep_cnt <= 0;
					sweep_all <= 0;
					cst <= C_SWEEP;
				end
				// CI-hit hold and the store exemption: see ap040_cache.v.
				// The exemption survives unchanged -- a store still never
				// reads data_q, and a mergeable store's tag check runs in
				// PASS against a row ci_inv has by then already cleared.
				else if (c_req && !ack_r && !err_hold &&
				         (c_write || !ci_inv_pend)) begin
					if (c_write) begin
						if (!st_mergeable && store_inv_lost) begin
							// port B owes a recorded invalidate: hold the
							// store one cycle (split-cache path, kept)
						end
						else begin
							// The tag row read runs in parallel with the
							// acceptance for every store; PASS decides
							// between merge (aligned, cacheable, clean
							// compare) and invalidate (everything else).
							r_row  <= a_set;
							r_tag  <= a_tag;
							r_addr <= c_addr;
							r_size <= c_size;
							r_off  <= c_addr[1:0];
							st_merge_arm <= st_mergeable;
							st_inv_arm   <= !st_mergeable ||
							                c_nocache || !ena;
							winv_set2 <= c_addr[10:4] + 7'd1;
							winv_pend <= !st_mergeable && write_cross_line;
							cst <= C_PASS;
						end
					end
					else if (bypass) begin
						r_row <= a_row;
						r_tag <= a_tag;
						pass_ci_chk <= c_nocache && !c_write;
						cst <= C_PASS;
					end
					else begin
						r_row <= a_row;
						r_tag <= a_tag;
						r_addr <= c_addr;
						r_size <= c_size;
						r_off <= c_addr[1:0];
						cst <= C_LOOK;
					end
				end
			end

			C_PASS: begin
				if (!s_stb && !store_inv_lost) winv_pend <= 0;
				if (pass_ci_chk) begin
					pass_ci_chk <= 0;
					if (look_hit) begin
						ci_inv_pend <= 1;
						ci_inv_row  <= r_row;
					end
				end
				// A store that could not merge but HIT a resident line
				// must still kill that line: a CI store, a store with the
				// cache disabled, or a snoop-poisoned compare.  (An
				// unaligned store never arms this; it took the whole-set
				// invalidate at acceptance.)  Recorded once, served by
				// port B via ci_inv like the CI-read case.
				if (st_inv_arm && look_hit && !ci_inv_pend) begin
					ci_inv_pend <= 1;
					ci_inv_row  <= r_row;
					st_inv_arm  <= 0;
				end
				// A snoop-poisoned merge falls back to the same kill: the
				// compare cannot be trusted to pick the way, but the row
				// address itself is registered and correct.
				if (st_merge_arm && st_snooped) begin
					st_merge_arm <= 0;
					ci_inv_pend  <= 1;
					ci_inv_row   <= r_row;
				end
				if (m_err) begin
					st_merge_arm <= 0;
					st_inv_arm <= 0;
					err_hold <= 1;
					cst <= (winv_pend && (s_stb || store_inv_lost))
					       ? C_WINV : C_IDLE;
				end
				else if (m_ack) begin
					// st_merge_now writes the data array THIS cycle
					st_merge_arm <= 0;
					st_inv_arm <= 0;
					cst <= (winv_pend && (s_stb || store_inv_lost))
					                  ? C_WINV : C_IDLE;
				end
			end

			C_FERR: begin
				if (!c_req) err_hold <= 0;
				if (!snoop_wr) cst <= C_IDLE;
			end

			C_WINV: begin
				if (!s_stb && !store_inv_lost) begin
					winv_pend <= 0;
					cst <= C_IDLE;
				end
			end

			C_SWEEP: begin
				sweep_cnt <= sweep_cnt + 8'd1;
				if (sweep_cnt[6:0] == 7'd127) begin
					if (!sweep_all) cinv_done <= 1;
					sweep_all <= 0;
					cst <= C_IDLE;
				end
			end

			C_LOOK: begin
				if (look_hit && !look_snooped && !snoop_look_row) begin
					rdata_r <= lw_extract(data_hit, r_size, r_off);
					ack_r <= 1;
					cst <= C_IDLE;
				end
				else begin
					r_way <= tag_q[89:88];
					r_beat <= 0;
					r_issued <= 0;
					cst <= C_FILL;
				end
			end

			C_FILL: begin
				if (m_err) begin
					r_issued <= 0;
					err_hold <= 1;
					cst <= C_FERR;
				end
				else if (!r_issued) r_issued <= 1;
				else if (m_ack) begin
					if (r_beat == r_addr[3:2]) fill_hold <= m_rdata;
					r_issued <= 0;
					if (r_beat == 2'd3) cst <= C_TAGW;
					else r_beat <= r_beat + 2'd1;
				end
			end

			C_TAGW: begin
				rdata_r <= lw_extract(fill_hold, r_size, r_off);
				ack_r <= 1;
				cst <= C_IDLE;
			end

			default: cst <= C_IDLE;
		endcase
	end
end

endmodule

//--------------------------------------------------------------------------//
// One cache way's data storage: 512 longwords with byte enables, built from //
// four byte-wide arrays so each infers as block RAM.  Reads free-run under  //
// ce exactly as the split cache's did -- the address is held for the whole  //
// request, so a stalled ce simply re-reads the same row.                    //
//--------------------------------------------------------------------------//
module ap040_ucache_way
(
	input             clk,
	input             ce,
	input             we,
	input       [3:0] be,
	input       [8:0] waddr,
	input      [31:0] wdata,
	input             rd_en,
	input       [8:0] raddr,
	output     [31:0] q
);

(* ramstyle = "no_rw_check" *) reg [7:0] b3 [0:511];
(* ramstyle = "no_rw_check" *) reg [7:0] b2 [0:511];
(* ramstyle = "no_rw_check" *) reg [7:0] b1 [0:511];
(* ramstyle = "no_rw_check" *) reg [7:0] b0 [0:511];
reg [7:0] q3, q2, q1, q0;

always @(posedge clk) begin
	if (ce & we & be[3]) b3[waddr] <= wdata[31:24];
	if (ce & we & be[2]) b2[waddr] <= wdata[23:16];
	if (ce & we & be[1]) b1[waddr] <= wdata[15:8];
	if (ce & we & be[0]) b0[waddr] <= wdata[7:0];
	if (ce & rd_en) begin
		q3 <= b3[raddr];
		q2 <= b2[raddr];
		q1 <= b1[raddr];
		q0 <= b0[raddr];
	end
end

assign q = {q3, q2, q1, q0};

endmodule
