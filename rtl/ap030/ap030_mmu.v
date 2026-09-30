//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_mmu.v - memory management unit (UM Section 9)                      //
//                                                                          //
//  - 22-entry fully associative address translation cache with the         //
//    entry format of UM 9.4 (V/FC/LA -> B/CI/WP/M/PA), pseudo-LRU           //
//    replacement from a history bit                                        //
//  - TT0/TT1 transparent translation (UM 9.3), CPU space untranslated       //
//  - table search engine (UM 9.5): function code lookup, up to four index  //
//    levels, short and long descriptors, limits, early termination with    //
//    contiguous mapping, indirect descriptors, supervisor and write         //
//    protection, U and M history updates written back under RMC            //
//  - PLOAD, PTEST (levels 0-7 with MMUSR of UM Table 9-3), PFLUSH           //
//  - TC/CRP/SRP consistency checks for the MMU configuration exception     //
//                                                                          //
// The translation port is combinational: the requester registers tr_*     //
// at the end of the clock in which it presents the logical address, which  //
// is the "translation in parallel with the cache lookup" of UM 9.2.       //
//--------------------------------------------------------------------------//

`include "ap030_defs.svh"

module ap030_mmu
(
	input             clk,
	input             rst,

	// ---- translation port ---------------------------------------------
	input      [31:0] tr_la,
	input       [2:0] tr_fc,
	input             tr_rw,        // 1 = read
	input             tr_rmc,       // read-modify-write access
	input             mmudis,       // MMUDIS pin, synchronized
	output            tr_ok,        // physical address valid, access allowed
	output            tr_fault,     // access denied: bus error exception
	output            tr_walk,      // table search needed before the access can proceed
	output     [31:0] tr_pa,
	output            tr_ci,        // CIOUT
	input             tr_use,       // the translation is being consumed: update the history bit

	// ---- table search request (from the translation port's requester) --
	input             walk_req,     // start a search for walk_la/walk_fc/walk_rw/walk_rmc
	input      [31:0] walk_la,
	input       [2:0] walk_fc,
	input             walk_rw,
	input             walk_rmc,
	output reg        walk_done,    // pulse: the ATC has an entry for that address (or a B entry)

	// ---- MMU instructions from the core ---------------------------------
	input             op_req,
	input       [2:0] op_kind,      // 0 PLOADR 1 PLOADW 2 PTESTR 3 PTESTW 4 PFLUSHA 5 PFLUSH fc 6 PFLUSH fc,ea
	input       [2:0] op_level,     // PTEST level
	input      [31:0] op_la,
	input       [2:0] op_fc,
	input       [2:0] op_fcmask,    // PFLUSH: ones select the FC bits compared
	output reg        op_done,
	output reg [31:0] op_desc_addr, // PTEST: address of the last descriptor fetched

	// ---- register port (PMOVE) -----------------------------------------
	input             reg_we,
	input       [2:0] reg_sel,      // 0 TC 1 SRP 2 CRP 3 TT0 4 TT1 5 MMUSR
	input      [31:0] reg_wdata_hi, // SRP/CRP first longword
	input      [31:0] reg_wdata_lo, // second longword, or the value for 32/16-bit registers
	input             reg_fd,       // flush disable
	output reg        cfg_err,      // pulse: MMU configuration exception
	output reg [31:0] tc,
	output reg [31:0] srp_hi, srp_lo,
	output reg [31:0] crp_hi, crp_lo,
	output reg [31:0] tt0, tt1,
	output reg [15:0] mmusr,

	// ---- bus access for table searches (routed by the memory subsystem) --
	output reg        w_req,
	output reg [31:0] w_addr,
	output reg        w_rw,
	output reg [31:0] w_wdata,
	input             w_ack,        // transfer done (data valid for reads)
	input      [31:0] w_rdata,
	input             w_berr,
	output            w_active,     // a search is in progress: RMC must stay asserted
	output            busy          // the search engine is not idle
);

//---------------------------------------------------------------------------
// TC fields
//---------------------------------------------------------------------------
wire       tc_e   = tc[31];
wire       tc_sre = tc[25];
wire       tc_fcl = tc[24];
wire [3:0] tc_ps  = tc[23:20];
wire [3:0] tc_is  = tc[19:16];
wire [3:0] tc_tia = tc[15:12];
wire [3:0] tc_tib = tc[11:8];
wire [3:0] tc_tic = tc[7:4];
wire [3:0] tc_tid = tc[3:0];

// page mask: which of LA[31:8] take part in the compare (ones) for the page
// size; PS = 8 compares all 24 bits, PS = 15 compares 17
reg [23:0] pmask;
always @* begin
	case (tc_ps)
		4'd8:  pmask = 24'hFFFFFF;
		4'd9:  pmask = 24'hFFFFFE;
		4'd10: pmask = 24'hFFFFFC;
		4'd11: pmask = 24'hFFFFF8;
		4'd12: pmask = 24'hFFFFF0;
		4'd13: pmask = 24'hFFFFE0;
		4'd14: pmask = 24'hFFFFC0;
		default: pmask = 24'hFFFF80;
	endcase
end

//---------------------------------------------------------------------------
// ATC
//---------------------------------------------------------------------------
localparam N = 22;
reg        atc_v   [0:N-1];
reg  [2:0] atc_fc  [0:N-1];
reg [23:0] atc_la  [0:N-1];
reg        atc_b   [0:N-1];
reg        atc_ci  [0:N-1];
reg        atc_wp  [0:N-1];
reg        atc_m   [0:N-1];
reg [23:0] atc_pa  [0:N-1];
reg        atc_h   [0:N-1];   // history bit for the replacement algorithm
reg  [4:0] atc_ptr;           // rotating start point for victim selection

// lookup of {la, fc}: one-hot match vector
function [N-1:0] atc_match;
	input [31:0] la;
	input [2:0]  fc;
	integer k;
	begin
		for (k = 0; k < N; k = k + 1)
			atc_match[k] = atc_v[k] && (atc_fc[k] == fc) &&
			               ((atc_la[k] & pmask) == (la[31:8] & pmask));
	end
endfunction

wire [N-1:0] tr_m = atc_match(tr_la, tr_fc);
wire         tr_hit = |tr_m;
reg          e_b, e_ci, e_wp, e_m;
reg  [23:0]  e_pa;
integer      ei;
always @* begin
	e_b = 1'b0; e_ci = 1'b0; e_wp = 1'b0; e_m = 1'b0; e_pa = 24'd0;
	for (ei = 0; ei < N; ei = ei + 1) begin
		if (tr_m[ei]) begin
			e_b = e_b | atc_b[ei]; e_ci = e_ci | atc_ci[ei]; e_wp = e_wp | atc_wp[ei];
			e_m = e_m | atc_m[ei]; e_pa = e_pa | atc_pa[ei];
		end
	end
end

//---------------------------------------------------------------------------
// transparent translation (UM 9.3)
//---------------------------------------------------------------------------
function tt_match;
	input [31:0] t;
	input [31:0] la;
	input [2:0]  fc;
	input        rw;
	input        rmc;
	begin
		tt_match = t[15] &&
		           ((la[31:24] | t[23:16]) == (t[31:24] | t[23:16])) &&
		           ((fc | t[2:0]) == (t[6:4] | t[2:0])) &&
		           (t[8] ? 1'b1 : (!rmc && (rw == t[9])));
	end
endfunction
wire tr_tt0 = tt_match(tt0, tr_la, tr_fc, tr_rw, tr_rmc);
wire tr_tt1 = tt_match(tt1, tr_la, tr_fc, tr_rw, tr_rmc);
wire tr_tt  = (tr_tt0 | tr_tt1) && (tr_fc != `FC_CPU_SPACE);
wire tr_tt_ci = (tr_tt0 & tt0[10]) | (tr_tt1 & tt1[10]);

wire tr_write = !tr_rw || tr_rmc;
wire tr_translate = tc_e && !mmudis && !tr_tt && (tr_fc != `FC_CPU_SPACE);

assign tr_fault = tr_translate && tr_hit && (e_b || (tr_write && e_wp));
assign tr_walk  = tr_translate && (!tr_hit || (tr_write && !e_m && !e_wp && !e_b));
assign tr_ok    = !tr_translate || (tr_hit && !tr_fault && !tr_walk);
assign tr_pa    = tr_translate ? {(e_pa & pmask) | (tr_la[31:8] & ~pmask), tr_la[7:0]} : tr_la;
assign tr_ci    = tr_tt ? tr_tt_ci : (tr_translate ? e_ci : 1'b0);

//---------------------------------------------------------------------------
// table search engine
//---------------------------------------------------------------------------
localparam W_IDLE   = 4'd0;
localparam W_INIT   = 4'd1;
localparam W_ROOT   = 4'd2;
localparam W_ADDR   = 4'd3;
localparam W_FETCH0 = 4'd4;
localparam W_FETCH1 = 4'd5;
localparam W_EVAL   = 4'd6;
localparam W_WB     = 4'd7;
localparam W_IND    = 4'd8;   // indirect: fetch the target page descriptor
localparam W_DONE   = 4'd9;
localparam W_ATC0   = 4'd10;  // PTEST level 0: ATC status
localparam W_FETCH1R = 4'd11; // request the second longword (w_req low for a clock)

reg  [3:0] wst;
reg        op_pend;
reg [31:0] s_la;
reg  [2:0] s_fc;
reg        s_write;        // write access: M must be set
reg        s_ptest;        // PTEST: no updates, no ATC entry, MMUSR result
reg        s_pload;
reg  [2:0] s_maxlvl;       // PTEST level
reg        s_walk_norm;    // normal translation search (walk_done at the end)
reg  [2:0] s_n;            // tables accessed
reg        s_b, s_l, s_sv, s_wp, s_i, s_m, s_ci;
reg  [5:0] s_bitpos;       // MSB of the next index field (0..31), 63 = none
reg  [1:0] s_fld;          // which TIx is next: 0 A, 1 B, 2 C, 3 D; 4 = exhausted
reg        s_fcl_pending;  // first level is the function code
reg  [1:0] s_dt;           // descriptor type of the table to fetch from
reg [31:4] s_tbl;          // table address
reg [14:0] s_idx;          // index into that table
reg        s_lim_lu;       // pending limit for s_idx
reg [14:0] s_lim;
reg        s_lim_chk;
reg [31:0] s_lw0, s_lw1;   // fetched descriptor
reg [31:0] s_daddr;        // address of the descriptor being fetched
reg        s_long;         // it is a long descriptor
reg        s_indirect;     // evaluating the target of an indirect descriptor
reg [23:0] s_pa;

reg  [3:0] fld_w;
always @* begin
	case (s_fld)
		2'd0: fld_w = tc_tia;
		2'd1: fld_w = tc_tib;
		2'd2: fld_w = tc_tic;
		default: fld_w = tc_tid;
	endcase
end
// fields that follow a zero width are ignored (UM Table 9-1)
reg        s_fld_done;
wire       fld_avail = (s_bitpos != 6'd63) && (fld_w != 4'd0) && !s_fld_done;

// index extraction: field of width w whose MSB is at bitpos
function [14:0] field_of;
	input [31:0] la;
	input [5:0]  bitpos;
	input [3:0]  w;
	reg  [31:0]  sh;
	begin
		sh = la << (6'd31 - bitpos);
		field_of = sh[31:17] >> (4'd15 - w);
	end
endfunction

// bits of LA below and including the current field position (unused index
// bits plus the page offset) for early termination (UM 9.5.3.1)
function [31:0] low_mask;
	input [5:0] bitpos;
	begin
		low_mask = (bitpos == 6'd63) ? 32'd0 : ((32'd2 << bitpos) - 32'd1);
	end
endfunction

// physical page address bits [31:8] that a page descriptor supplies (the
// low PS-8 bits of the field are unused)
wire [23:0] pa_field_mask = pmask;

wire [14:0] idx_now  = field_of(s_la, s_bitpos, fld_w);
wire [3:0]  fld_w_next = (s_fld == 2'd0) ? tc_tib : (s_fld == 2'd1) ? tc_tic : (s_fld == 2'd2) ? tc_tid : 4'd0;
wire [5:0]  bitpos_next = s_bitpos - {2'd0, fld_w};

// limit check (UM 9.5.1.1 L/U, LIMIT)
function lim_viol;
	input        lu;
	input [14:0] lim;
	input [14:0] idx;
	begin
		lim_viol = lu ? (idx < lim) : (idx > lim);
	end
endfunction

// descriptor fields
wire [1:0]  dt_f   = s_lw0[1:0];
// a table-type code where no index field is left is an indirect descriptor
// (UM 9.5.1.11): its bits above DT are all address, not U/WP
wire        d_ind  = (dt_f[1] == 1'b1) && !fld_avail && !s_indirect;
wire        d_u    = s_lw0[3];
wire        d_wp   = s_lw0[2];
wire        d_m    = s_lw0[4];
wire        d_ci   = s_lw0[6];
wire        d_s    = s_long & s_lw0[8];
wire        d_lu   = s_lw0[31];
wire [14:0] d_lim  = s_lw0[30:16];
wire [31:0] d_addr = s_long ? s_lw1 : s_lw0;

reg s_ptest_lvl0;
assign w_active = (wst != W_IDLE) && (wst != W_ATC0) && (wst != W_DONE) && !s_ptest_lvl0;
assign busy = (wst != W_IDLE);

// ATC entry creation
reg        atc_wr;
reg  [2:0] atc_wr_fc;
reg [23:0] atc_wr_la;
reg        atc_wr_b, atc_wr_ci, atc_wr_wp, atc_wr_m;
reg [23:0] atc_wr_pa;
// PFLUSH
reg        fl_all, fl_fc, fl_ea;
reg  [2:0] fl_fcv, fl_fcm;
reg [31:0] fl_la;

// victim: first invalid entry, else the first entry at or after the pointer
// whose history bit is clear; when all history bits are set they are cleared
reg [4:0] victim;
reg       victim_found, all_hist;
integer vi;
always @* begin
	victim = atc_ptr; victim_found = 1'b0; all_hist = 1'b1;
	for (vi = 0; vi < N; vi = vi + 1) if (!atc_h[vi] && atc_v[vi]) all_hist = 1'b0;
	for (vi = 0; vi < N; vi = vi + 1) begin
		if (!victim_found && !atc_v[vi]) begin victim = vi[4:0]; victim_found = 1'b1; end
	end
	if (!victim_found) begin
		for (vi = 0; vi < 2*N; vi = vi + 1) begin
			if (!victim_found && (vi >= atc_ptr) && !atc_h[(vi >= N) ? vi - N : vi]) begin
				victim = (vi >= N) ? vi[4:0] - 5'd22 : vi[4:0]; victim_found = 1'b1;
			end
		end
	end
	if (!victim_found) victim = atc_ptr;
end

integer ai;
reg [N-1:0] tr_m_q;
always @(posedge clk) begin
	if (rst) begin
		tr_m_q <= {N{1'b0}};
		for (ai = 0; ai < N; ai = ai + 1) begin
			// UM 9.2.2: RESET does not invalidate the ATC.  Simulation and
			// FPGA power-up start with an empty cache; a warm reset keeps it.
			atc_h[ai] <= 1'b0;
		end
		atc_ptr <= 5'd0;
	end else begin
		// history bit on use (UM 9.4): tr_use follows the lookup by a clock
		tr_m_q <= tr_translate && tr_hit ? tr_m : {N{1'b0}};
		if (tr_use) begin
			for (ai = 0; ai < N; ai = ai + 1) if (tr_m_q[ai]) atc_h[ai] <= 1'b1;
		end
		if (atc_wr) begin
			// an existing entry for the same page is replaced
			for (ai = 0; ai < N; ai = ai + 1) begin
				if (atc_v[ai] && atc_fc[ai] == atc_wr_fc && ((atc_la[ai] & pmask) == (atc_wr_la & pmask)))
					atc_v[ai] <= 1'b0;
			end
			atc_v[victim]  <= 1'b1;
			atc_fc[victim] <= atc_wr_fc;
			atc_la[victim] <= atc_wr_la;
			atc_b[victim]  <= atc_wr_b;
			atc_ci[victim] <= atc_wr_ci;
			atc_wp[victim] <= atc_wr_wp;
			atc_m[victim]  <= atc_wr_m;
			atc_pa[victim] <= atc_wr_pa;
			atc_h[victim]  <= 1'b1;
			if (all_hist) for (ai = 0; ai < N; ai = ai + 1) if (ai[4:0] != victim) atc_h[ai] <= 1'b0;
			atc_ptr <= (victim == N-1) ? 5'd0 : victim + 5'd1;
		end
		if (fl_all) begin
			for (ai = 0; ai < N; ai = ai + 1) begin atc_v[ai] <= 1'b0; atc_h[ai] <= 1'b0; end
		end else if (fl_fc) begin
			for (ai = 0; ai < N; ai = ai + 1)
				if (((atc_fc[ai] ^ fl_fcv) & fl_fcm) == 3'd0 &&
				    (!fl_ea || ((atc_la[ai] & pmask) == (fl_la[31:8] & pmask))))
					atc_v[ai] <= 1'b0;
		end
	end
end

// simulation/power-up initial state of the ATC
integer ii;
initial begin
	for (ii = 0; ii < N; ii = ii + 1) begin
		atc_v[ii] = 1'b0; atc_fc[ii] = 3'd0; atc_la[ii] = 24'd0; atc_b[ii] = 1'b0;
		atc_ci[ii] = 1'b0; atc_wp[ii] = 1'b0; atc_m[ii] = 1'b0; atc_pa[ii] = 24'd0; atc_h[ii] = 1'b0;
	end
end

//---------------------------------------------------------------------------
// registers (PMOVE) and the configuration checks (UM 9.7.5.3)
//---------------------------------------------------------------------------
// sum of IS, PS and the TIx fields up to the first zero
wire [3:0] c_tia = reg_wdata_lo[15:12];
wire [3:0] c_tib = reg_wdata_lo[11:8];
wire [3:0] c_tic = reg_wdata_lo[7:4];
wire [3:0] c_tid = reg_wdata_lo[3:0];
wire [6:0] c_sum = {3'd0, reg_wdata_lo[19:16]} + {3'd0, reg_wdata_lo[23:20]} + {3'd0, c_tia} +
                   ((c_tia == 0) ? 7'd0 : {3'd0, c_tib}) +
                   ((c_tia == 0 || c_tib == 0) ? 7'd0 : {3'd0, c_tic}) +
                   ((c_tia == 0 || c_tib == 0 || c_tic == 0) ? 7'd0 : {3'd0, c_tid});
wire tc_bad = reg_wdata_lo[31] && ((c_sum != 7'd32) || !reg_wdata_lo[23]);   // PS < 8 is reserved

reg        mmusr_we;
reg [15:0] mmusr_new;
reg flush_req;
always @(posedge clk) begin
	cfg_err <= 1'b0;
	flush_req <= 1'b0;
	if (rst) begin
		// UM 9.2.2: E bits cleared, contents otherwise kept
		tc[31] <= 1'b0; tt0[15] <= 1'b0; tt1[15] <= 1'b0;
	end else if (reg_we) begin
		case (reg_sel)
			3'd0: begin
				tc <= reg_wdata_lo & 32'h83FF_FFFF;
				if (tc_bad) begin tc[31] <= 1'b0; cfg_err <= 1'b1; end
				flush_req <= !reg_fd;
			end
			3'd1: begin
				srp_hi <= reg_wdata_hi & 32'hFFFF_0003; srp_lo <= reg_wdata_lo & 32'hFFFF_FFF0;
				if (reg_wdata_hi[1:0] == 2'b00) cfg_err <= 1'b1;
				flush_req <= !reg_fd;
			end
			3'd2: begin
				crp_hi <= reg_wdata_hi & 32'hFFFF_0003; crp_lo <= reg_wdata_lo & 32'hFFFF_FFF0;
				if (reg_wdata_hi[1:0] == 2'b00) cfg_err <= 1'b1;
				flush_req <= !reg_fd;
			end
			3'd3: begin tt0 <= reg_wdata_lo & 32'hFFFF_8777; flush_req <= !reg_fd; end
			3'd4: begin tt1 <= reg_wdata_lo & 32'hFFFF_8777; flush_req <= !reg_fd; end
			default: mmusr <= reg_wdata_lo[15:0] & 16'hEE47;
		endcase
	end
	if (mmusr_we) mmusr <= mmusr_new;
end
initial begin
	tc = 32'd0; srp_hi = 32'd0; srp_lo = 32'd0; crp_hi = 32'd0; crp_lo = 32'd0;
	tt0 = 32'd0; tt1 = 32'd0; mmusr = 16'd0;
end

//---------------------------------------------------------------------------
// the search state machine
//---------------------------------------------------------------------------
wire [31:0] root_hi = (s_fc[2] && tc_sre) ? srp_hi : crp_hi;
wire [31:0] root_lo = (s_fc[2] && tc_sre) ? srp_lo : crp_lo;

// page address with the contiguous-region offset of an early termination
wire [31:0] pa_sum = {d_addr[31:8] & pa_field_mask, 8'd0} + (s_la & low_mask(s_bitpos));
wire [31:0] root_pa_sum = ({s_tbl, 4'd0} & {pmask, 8'd0}) + (s_la & low_mask(s_bitpos));

always @(posedge clk) begin
	walk_done <= 1'b0;
	op_done   <= 1'b0;
	atc_wr    <= 1'b0;
	fl_all    <= 1'b0; fl_fc <= 1'b0;
	mmusr_we  <= 1'b0;
	if (rst) begin
		wst <= W_IDLE; w_req <= 1'b0; s_ptest_lvl0 <= 1'b0; s_fld_done <= 1'b0; op_pend <= 1'b0;
	end else begin
		if (flush_req) fl_all <= 1'b1;
		// an instruction's request waits for a search in progress
		if (op_req) op_pend <= 1'b1;
		case (wst)
			W_IDLE: begin
				if (walk_req) begin
					s_la <= walk_la; s_fc <= walk_fc; s_write <= !walk_rw || walk_rmc;
					s_ptest <= 1'b0; s_pload <= 1'b0; s_maxlvl <= 3'd7; s_walk_norm <= 1'b1;
					wst <= W_INIT;
				end else if (op_req || op_pend) begin
					op_pend <= 1'b0;
					s_la <= op_la; s_fc <= op_fc; s_walk_norm <= 1'b0;
					case (op_kind)
						3'd0, 3'd1: begin s_write <= op_kind[0]; s_ptest <= 1'b0; s_pload <= 1'b1; s_maxlvl <= 3'd7; wst <= W_INIT; end
						3'd2, 3'd3: begin
							s_write <= op_kind[0]; s_ptest <= 1'b1; s_pload <= 1'b0; s_maxlvl <= op_level;
							if (op_level == 3'd0) begin s_ptest_lvl0 <= 1'b1; wst <= W_ATC0; end
							else wst <= W_INIT;
						end
						3'd4: begin fl_all <= 1'b1; op_done <= 1'b1; end
						3'd5, 3'd6: begin
							fl_fc <= 1'b1; fl_ea <= (op_kind == 3'd6); fl_fcv <= op_fc; fl_fcm <= op_fcmask; fl_la <= op_la;
							op_done <= 1'b1;
						end
						default: op_done <= 1'b1;
					endcase
				end
			end

			W_ATC0: begin : ptest0
				// PTEST level 0 (UM Table 9-3): ATC search only
				reg [N-1:0] m;
				reg b, wp, mm;
				integer k;
				m = atc_match(s_la, s_fc);
				b = 1'b0; wp = 1'b0; mm = 1'b0;
				for (k = 0; k < N; k = k + 1) if (m[k]) begin b = b | atc_b[k]; wp = wp | atc_wp[k]; mm = mm | atc_m[k]; end
				if (tt_match(tt0, s_la, s_fc, !s_write, 1'b0) || tt_match(tt1, s_la, s_fc, !s_write, 1'b0))
					mmusr_new <= 16'h0040;   // T set, the rest undefined (zero here)
				else
					mmusr_new <= {b, 1'b0, 1'b0, 1'b0, wp, (!(|m) || b), mm, 9'd0};
				mmusr_we <= 1'b1;
				op_done <= 1'b1;
				s_ptest_lvl0 <= 1'b0;
				wst <= W_IDLE;
			end

			W_INIT: begin
				// UM 9.5.2: select the tree, the first index and its limit
				s_n <= 3'd0; s_b <= 1'b0; s_l <= 1'b0; s_sv <= 1'b0; s_wp <= 1'b0; s_i <= 1'b0;
				s_m <= 1'b0; s_ci <= 1'b0; s_indirect <= 1'b0; s_fld_done <= 1'b0;
				s_bitpos <= 6'd31 - {2'd0, tc_is};
				s_fld <= 2'd0;
				s_dt <= root_hi[1:0];
				s_tbl <= root_lo[31:4];
				s_lim_lu <= root_hi[31];
				s_lim <= root_hi[30:16];
				s_lim_chk <= !tc_fcl;            // the function code level is not limited
				s_fcl_pending <= tc_fcl;
				op_desc_addr <= 32'd0;
				wst <= W_ROOT;
			end

			W_ROOT: begin
				// the root pointer acts as the first "descriptor"
				if (s_dt == 2'b01) begin
					// UM 9.7.1: DT=1 at the root -- direct mapping with offset,
					// limit checked regardless of FCL
					if (lim_viol(s_lim_lu, s_lim, idx_now) && (fld_w != 0)) begin
						s_l <= 1'b1; s_i <= 1'b1; wst <= W_DONE;
					end else begin
						s_pa <= root_pa_sum[31:8];
						// no descriptor in memory to update: a write search
						// makes the entry modified at once (UM 9.5.3.1)
						s_m <= s_write && !s_ptest;
						wst <= W_DONE;
					end
				end else begin
					if (s_fcl_pending) begin
						s_idx <= {12'd0, s_fc};
						s_fcl_pending <= 1'b0;
						wst <= W_ADDR;
					end else if (!fld_avail) begin
						// TIA = 0 is not a valid configuration; treat as invalid
						s_i <= 1'b1; wst <= W_DONE;
					end else if (s_lim_chk && lim_viol(s_lim_lu, s_lim, idx_now)) begin
						s_l <= 1'b1; s_i <= 1'b1; wst <= W_DONE;
					end else begin
						s_idx <= idx_now;
						s_bitpos <= bitpos_next;
						s_fld <= s_fld + 2'd1;
						if (s_fld == 2'd3 || fld_w_next == 4'd0) s_fld_done <= 1'b1;
						wst <= W_ADDR;
					end
				end
			end

			W_ADDR: begin
				// descriptor address: table base plus index scaled by the format
				s_long  <= (s_dt == 2'b11);
				s_daddr <= {s_tbl, 4'd0} + ((s_dt == 2'b11) ? {14'd0, s_idx, 3'd0} : {15'd0, s_idx, 2'd0});
				w_addr  <= {s_tbl, 4'd0} + ((s_dt == 2'b11) ? {14'd0, s_idx, 3'd0} : {15'd0, s_idx, 2'd0});
				w_rw    <= 1'b1;
				w_req   <= 1'b1;
				wst <= W_FETCH0;
			end

			W_FETCH0: begin
				if (w_ack) begin
					w_req <= 1'b0;
					if (w_berr) begin s_b <= 1'b1; s_i <= 1'b1; wst <= W_DONE; end
					else begin
						s_lw0 <= w_rdata;
						s_n <= s_n + 3'd1;
						if (s_long) begin
							wst <= W_FETCH1R;
						end else begin
							op_desc_addr <= s_daddr;   // PTEST An: the last descriptor fetched completely
							wst <= W_EVAL;
						end
					end
				end
			end

			W_FETCH1R: begin
				w_addr <= s_daddr + 32'd4; w_rw <= 1'b1; w_req <= 1'b1; wst <= W_FETCH1;
			end

			W_FETCH1: begin
				if (w_ack) begin
					w_req <= 1'b0;
					if (w_berr) begin s_b <= 1'b1; s_i <= 1'b1; wst <= W_DONE; end
					else begin s_lw1 <= w_rdata; op_desc_addr <= s_daddr; wst <= W_EVAL; end
				end
			end

			W_EVAL: begin
				// UM 9.5.2 / 9.5.5: evaluate the fetched descriptor
				if (s_indirect && dt_f != 2'b01) begin
					// the target of an indirect descriptor must be a page descriptor
					s_i <= 1'b1; wst <= W_DONE;
				end else if (dt_f == 2'b00) begin
					s_i <= 1'b1; wst <= W_DONE;
				end else if (d_ind) begin
					// indirect: no history or protection bits of its own
					if (s_ptest && s_n == s_maxlvl) wst <= W_DONE;
					else wst <= W_IND;
				end else if (d_s && !s_fc[2]) begin
					// supervisor violation: search ends, U not updated
					s_sv <= 1'b1; if (!s_ptest) s_i <= 1'b1; wst <= W_DONE;
				end else if (s_long && !s_indirect && fld_avail && lim_viol(d_lu, d_lim, idx_now)) begin
					// the limit of a long descriptor bounds the index into the
					// table (or the pages of an early termination) below it
					s_l <= 1'b1; s_i <= 1'b1;
					wst <= W_DONE;
				end else begin
					s_wp <= s_wp | d_wp;
					if (dt_f == 2'b01) begin
						// page descriptor (normal, early termination, or indirect target)
						s_pa <= pa_sum[31:8];
						s_ci <= d_ci;
						s_m  <= d_m;
						if (!s_ptest && (!d_u || (s_write && !d_m && !(s_wp | d_wp)))) begin
							w_wdata <= s_lw0 | 32'h8 | ((s_write && !(s_wp | d_wp)) ? 32'h10 : 32'h0);
							w_addr  <= s_daddr; w_rw <= 1'b0; w_req <= 1'b1;
							if (s_write && !(s_wp | d_wp)) s_m <= 1'b1;
							wst <= W_WB;
						end else wst <= W_DONE;
					end else begin
						// table (or indirect) descriptor
						if (s_ptest && s_n == s_maxlvl) begin
							wst <= W_DONE;
						end else if (!s_ptest && !d_u) begin
							w_wdata <= s_lw0 | 32'h8; w_addr <= s_daddr; w_rw <= 1'b0; w_req <= 1'b1;
							wst <= W_WB;
						end else wst <= W_IND;
					end
				end
			end

			W_WB: begin
				// U/M write back under RMC (UM 9.5.2)
				if (w_ack) begin
					w_req <= 1'b0;
					if (w_berr) begin s_b <= 1'b1; s_i <= 1'b1; wst <= W_DONE; end
					else if (dt_f == 2'b01) wst <= W_DONE;
					else wst <= W_IND;
				end
			end

			W_IND: begin
				// continue below the table descriptor: next level, or indirect
				if (s_ptest && s_n == s_maxlvl) wst <= W_DONE;
				else if (!fld_avail || s_indirect) begin
					// no index field left: this is an indirect descriptor
					s_indirect <= 1'b1;
					s_dt <= dt_f;
					s_long <= (dt_f == 2'b11);
					s_daddr <= {d_addr[31:2], 2'd0};
					w_addr <= {d_addr[31:2], 2'd0}; w_rw <= 1'b1; w_req <= 1'b1;
					s_bitpos <= 6'd63;
					wst <= W_FETCH0;
				end else begin
					s_dt <= dt_f;
					s_tbl <= d_addr[31:4];
					s_idx <= idx_now;
					s_bitpos <= bitpos_next;
					s_fld <= s_fld + 2'd1;
					if (s_fld == 2'd3 || fld_w_next == 4'd0) s_fld_done <= 1'b1;
					wst <= W_ADDR;
				end
			end

			W_DONE: begin
				if (s_ptest) begin
					mmusr_new <= {s_b, s_l, s_sv, 1'b0, s_wp, s_i, s_m, 6'd0, s_n};
					mmusr_we <= 1'b1;
					op_done <= 1'b1;
				end else begin
					// ATC entry (UM 9.4 / Figure 9-27); errors produce a B entry
					atc_wr <= 1'b1;
					atc_wr_fc <= s_fc;
					atc_wr_la <= s_la[31:8];
					atc_wr_b  <= s_i | s_b | s_l | s_sv;
					atc_wr_ci <= s_ci;
					atc_wr_wp <= s_wp;
					atc_wr_m  <= s_m;
					atc_wr_pa <= s_pa;
					if (s_pload) op_done <= 1'b1;
					else walk_done <= 1'b1;
				end
				wst <= W_IDLE;
			end
			default: wst <= W_IDLE;
		endcase
	end
end

endmodule
