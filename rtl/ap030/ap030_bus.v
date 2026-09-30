//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_bus.v - bus controller: MC68030 pin protocol (UM Section 7)        //
//                                                                          //
// One "transfer" = one longword-aligned portion of an operand (1..4 bytes  //
// that do not cross a longword boundary), an instruction prefetch, an      //
// interrupt acknowledge, or one MMU table search access.  The controller   //
// runs as many bus cycles as the responding port size needs (dynamic bus   //
// sizing, UM 7.2.1), drives write data on the lanes of UM Table 7-5,       //
// extracts read data per UM Table 7-4/7.2.7, completes cache entries from  //
// 8/16-bit ports (UM 6.1.3.1) and runs burst fills (UM 7.3.7).             //
//                                                                          //
// Timing model.  A bus state is half a clock; even states begin on the     //
// rising edge, odd states on the falling edge.  Every decision is made in  //
// the posedge domain.  The signals the MC68030 changes on falling edges    //
// (AS, DS, DBEN on reads, CBREQ, BG, the read-data latch) are single       //
// negedge flops driven by posedge registers, and the asynchronous inputs   //
// (DSACKx, BERR, HALT, AVEC, BR, BGACK) are sampled on falling edges as    //
// UM 7.1 requires.  STERM, CBACK and CIIN are synchronous inputs sampled   //
// on rising edges.                                                         //
//                                                                          //
//   async cycle, no wait:  S0 S1 | S2 S3 | S4 S5            3 clocks       //
//   sync cycle:            S0 S1 | S2 S3                    2 clocks       //
//   burst of four:         S0 S1 | S2 S3 | S4 S5 | S6 S7 | S8 S9  5 clocks //
//                                                                          //
// ECS/OCS are asserted during S0 only: a posedge flag and a toggle that    //
// is copied on the falling edge form the half-clock pulse without gating   //
// the clock.                                                               //
//--------------------------------------------------------------------------//

`include "ap030_defs.svh"

module ap030_bus
(
	input             clk,
	input             rst,          // synchronous, active high (RESET pin, synchronized)

	// ---- transfer request ---------------------------------------------
	input             req,
	input       [1:0] req_kind,     // BK_DATA / BK_IACK / BK_TABLE
	input      [31:0] req_addr,     // physical address of the first byte
	input       [2:0] req_nbytes,   // bytes in this portion: 1..4, within one longword
	input       [2:0] req_total,    // operand bytes remaining incl. this portion (SIZ pins)
	input             req_rw,       // 1 = read
	input       [2:0] req_fc,
	input             req_rmc,      // assert RMC from this transfer on
	input             req_rmc_last, // negate RMC when this transfer completes
	input             req_ciout,
	input             req_cbreq,    // burst permitted
	input             req_ocs,      // first external cycle of an operand: OCS
	input             req_cache,    // cachable read: complete the entry, report fills
	input      [31:0] req_wdata,    // remaining operand, right justified (req_total bytes)
	output            req_ack,      // request captured this clock
	output            busy,         // a transfer is loaded or running
	output reg        done,         // pulse: operand available, result registers valid
	output reg [31:0] rd_data,      // portion bytes, right justified
	output reg        res_berr,     // an operand cycle ended in bus error
	output reg        res_avec,     // IACK terminated by AVEC
	output reg        res_ciin,     // CIIN seen on an operand cycle: do not cache
	output reg        fill_stb,     // pulse: a complete cachable longword
	output reg [31:2] fill_addr,
	output reg [31:0] fill_data,
	input             rmc_release,  // negate RMC without another cycle (CAS mismatch)
	input             halted,       // double bus fault: never begin a cycle
	output            bus_idle,     // nothing loaded, nothing in progress

	// ---- MC68030 pins ---------------------------------------------------
	output reg [31:0] a_o,
	output reg  [2:0] fc_o,
	output reg  [1:0] siz_o,
	output reg        rw_o,         // 1 = read
	output            rmc_n_o,
	output            as_n_o,
	output            ds_n_o,
	output            dben_n_o,
	output            ecs_n_o,
	output            ocs_n_o,
	output            ciout_n_o,
	output            cbreq_n_o,
	output            bus_oe,       // address/control drivers enabled
	output     [31:0] d_o,
	output            d_oe,         // data drivers enabled (write S2..S5)
	input      [31:0] d_i,
	input             dsack0_n,
	input             dsack1_n,
	input             sterm_n,
	input             berr_n,
	input             halt_n,
	input             avec_n,
	input             ciin_n,
	input             cback_n,
	input             br_n,
	input             bgack_n,
	output            bg_n_o,
	output            bus_granted   // three-state control T (UM Figure 7-61)
);

//---------------------------------------------------------------------------
// falling-edge samplers for the asynchronous inputs (UM 7.1, Figure 7-2)
//---------------------------------------------------------------------------
reg [1:0] dsack_l;    // {DSACK1, DSACK0}, active high
reg       berr_l, halt_l, avec_l, br_l, bgack_l;
always @(negedge clk) begin
	dsack_l <= {~dsack1_n, ~dsack0_n};
	berr_l  <= ~berr_n;
	halt_l  <= ~halt_n;
	avec_l  <= ~avec_n;
	br_l    <= ~br_n;
	bgack_l <= ~bgack_n;
end
wire sterm = ~sterm_n;      // synchronous inputs
wire cback = ~cback_n;
wire ciin  = ~ciin_n;

//---------------------------------------------------------------------------
// state
//---------------------------------------------------------------------------
localparam B_IDLE  = 3'd0;
localparam B_S0    = 3'd1;   // S0/S1: address out, AS at the falling edge
localparam B_S2    = 3'd2;   // S2/S3: STERM sampled at the rising edge
localparam B_WAIT  = 3'd3;   // S4/S5 or Sw/Sw: DSACK/BERR from the last falling edge
localparam B_BURST = 3'd4;   // AS held, one longword per STERM
localparam B_RETRY = 3'd5;   // BERR+HALT seen: rerun the cycle once HALT negates

reg  [2:0] bst;
// the transfer
reg        t_valid;
reg  [1:0] t_kind;
reg [31:0] t_addr;        // address of the next cycle
reg  [2:0] t_rem;         // portion bytes still to move
reg  [2:0] t_total;       // operand bytes remaining (SIZ)
reg        t_rw;
reg  [2:0] t_fc;
reg        t_rmc_last;
reg        t_rmc;
reg        t_ciout;
reg        t_cbreq;
reg        t_ocs;
reg        t_cache;
reg [31:0] t_wdata;
reg  [2:0] t_nbytes;
reg  [1:0] t_off;
reg        t_fill;        // completing the entry from a narrow port
reg  [3:0] t_have;        // entry bytes present (bit 0 = A1:A0 = 00)
reg [31:0] t_ebuf;
reg        t_noc;         // not cachable (CIIN, or an errored fill cycle)
reg        t_first;       // no cycle of this transfer has completed yet
reg        t_opdone;      // operand already reported (burst in progress)
// the cycle that terminated at the previous falling edge
reg        chk_late;
reg        term_err, term_retry, term_avec, term_sync;
reg  [1:0] term_port;
reg        term_ciin;     // CIIN with the terminating edge
reg        term_burst;    // termination enters burst mode (AS stays asserted)
// burst
reg        beat_pend;     // a burst beat latched at the previous falling edge
reg        beat_ciin, beat_last;
reg  [1:0] beat_cnt;      // follow-on beats recognized so far
reg  [1:0] beat_idx;      // line entry of the beat being latched
reg [31:4] beat_line;     // the line being burst-filled (address pins stay constant)
// pin-side posedge registers
reg        rmc_p, ciout_p, cbreq_p, ecs_p, ocs_p, ecs_tog, d_oe_p;
reg        dben_rd_tp;    // read DBEN: toggles at the S2 rising edge (assert)
reg        dben_rd_tn;    //            toggles at the S5 falling edge (negate)
reg        dben_wr_tn;    // write DBEN: toggles at the S1 falling edge (assert)
reg        dben_wr_tp;    //             toggles at the end of S5 (negate)
// posedge -> negedge commands
reg        c_as_set;      // assert AS (and DS on reads, DBEN on writes, CBREQ) at the next falling edge
reg        c_as_clr;      // negate AS, DS, read DBEN, CBREQ at the next falling edge
reg        c_ds_wr;       // assert write DS at the next falling edge
reg        c_cbreq_clr;
reg        c_latch;       // latch D31-D0 at the next falling edge
// negedge registers
reg        as_n_r, ds_n_r, cbreq_n_r, bg_n_r;
reg        ecs_tog_n;
reg [31:0] din_l;

always @(negedge clk) begin
	if (rst) begin
		as_n_r <= 1'b1; ds_n_r <= 1'b1; cbreq_n_r <= 1'b1;
		ecs_tog_n <= 1'b0; din_l <= 32'd0;
		dben_rd_tn <= 1'b0; dben_wr_tn <= 1'b0;
	end else begin
		ecs_tog_n <= ecs_tog;
		if (c_as_set) begin
			as_n_r <= 1'b0;
			if (t_rw) ds_n_r <= 1'b0;
			if (cbreq_p) cbreq_n_r <= 1'b0;
			if (!t_rw) dben_wr_tn <= ~dben_wr_tn;      // S1: write DBEN asserted with AS
		end
		if (c_ds_wr) ds_n_r <= 1'b0;
		if (c_cbreq_clr) cbreq_n_r <= 1'b1;
		if (c_as_clr) begin
			as_n_r <= 1'b1; ds_n_r <= 1'b1; cbreq_n_r <= 1'b1;
			if (t_rw) dben_rd_tn <= ~dben_rd_tn;       // S5: read DBEN negated with DS
		end
		if (c_latch) din_l <= d_i;
	end
end
// DBEN is asserted between a toggle on one edge and the matching toggle on
// the other; assertions and negations alternate strictly, so the pair of
// flops never needs to know the clock phase.
wire dben_rd = dben_rd_tp ^ dben_rd_tn;
wire dben_wr = dben_wr_tp ^ dben_wr_tn;

//---------------------------------------------------------------------------
// bus arbitration (UM 7.7.4, Figure 7-61).  R = BR, A = BGACK, G = BG, T
//---------------------------------------------------------------------------
reg [2:0] arb;
reg       arb_g, arb_t, tristate;
wire      arb_r = br_l & ~rmc_p;      // BG is never asserted while RMC is asserted
wire      arb_a = bgack_l;
always @(posedge clk) begin
	if (rst) begin
		arb <= 3'd0; arb_g <= 1'b0; arb_t <= 1'b0;
	end else case (arb)
		3'd0: if (arb_r) begin arb <= 3'd1; arb_g <= 1'b1; arb_t <= 1'b1; end
		      else if (arb_a) begin arb <= 3'd4; arb_t <= 1'b1; end
		3'd1: arb <= 3'd2;
		3'd2: if (arb_a || !arb_r) begin arb <= 3'd3; arb_g <= 1'b0; end
		3'd3: arb <= 3'd4;
		3'd4: if (!arb_a && !arb_r) begin arb <= 3'd0; arb_t <= 1'b0; end
		      else if (arb_r && arb_a) begin arb <= 3'd5; arb_g <= 1'b1; end
		      else if (arb_r) begin arb <= 3'd1; arb_g <= 1'b1; end
		3'd5: if (!arb_r) begin arb <= 3'd3; arb_g <= 1'b0; end
		      else if (!arb_a) arb <= 3'd6;
		3'd6: if (arb_a || !arb_r) begin arb <= 3'd3; arb_g <= 1'b0; end
		default: arb <= 3'd0;
	endcase
end
always @(negedge clk) bg_n_r <= rst ? 1'b1 : ~arb_g;   // BG moves on the falling edge
assign bg_n_o = bg_n_r;
// T takes effect once the current cycle (and RMW operation) is over
wire cycle_active = (bst == B_S0) || (bst == B_S2) || (bst == B_WAIT) || (bst == B_BURST);
always @(posedge clk) begin
	if (rst) tristate <= 1'b1;
	else if (arb_t) begin if (!cycle_active && !rmc_p && !chk_late) tristate <= 1'b1; end
	else tristate <= 1'b0;
end
assign bus_granted = tristate;
assign bus_oe = ~tristate;

//---------------------------------------------------------------------------
// data lane multiplexer for writes (UM Table 7-5): remaining operand bytes
// R0..R3 (R0 most significant), wrapped per the SIZ count
//---------------------------------------------------------------------------
reg [7:0] r0, r1, r2, r3;
always @* begin
	case (t_total)
		3'd1: begin r0 = t_wdata[7:0];   r1 = r0; r2 = r0; r3 = r0; end
		3'd2: begin r0 = t_wdata[15:8];  r1 = t_wdata[7:0]; r2 = r0; r3 = r1; end
		3'd3: begin r0 = t_wdata[23:16]; r1 = t_wdata[15:8]; r2 = t_wdata[7:0]; r3 = r0; end
		default: begin r0 = t_wdata[31:24]; r1 = t_wdata[23:16]; r2 = t_wdata[15:8]; r3 = t_wdata[7:0]; end
	endcase
end
reg [31:0] wlanes;
always @* begin
	case (t_addr[1:0])
		2'b00:   wlanes = {r0, r1, r2, r3};
		2'b01:   wlanes = {r0, r0, r1, r2};
		2'b10:   wlanes = {r0, r1, r0, r1};
		default: wlanes = {r0, r0, r1, r0};
	endcase
end
assign d_o  = wlanes;
assign d_oe = d_oe_p;

//---------------------------------------------------------------------------
// helpers
//---------------------------------------------------------------------------
// bytes a cycle at offset o moves through port p when `want` are requested
function [2:0] moved;
	input [1:0] p; input [1:0] o; input [2:0] want;
	reg   [2:0] cap;
	begin
		case (p)
			`PORT_32: cap = 3'd4 - {1'b0, o};
			`PORT_16: cap = 3'd2 - {2'b0, o[0]};
			default:  cap = 3'd1;
		endcase
		moved = (want < cap) ? want : cap;
	end
endfunction

// entry bytes supplied by a read at offset o from port p (UM 7.2.7)
function [3:0] supplied;
	input [1:0] p; input [1:0] o;
	begin
		case (p)
			`PORT_32: supplied = 4'b1111;
			`PORT_16: supplied = o[1] ? 4'b1100 : 4'b0011;
			default:  supplied = 4'b0001 << o;
		endcase
	end
endfunction

function [7:0] lane_byte;
	input [31:0] d; input [1:0] lane;
	begin
		case (lane)
			2'd0: lane_byte = d[31:24];
			2'd1: lane_byte = d[23:16];
			2'd2: lane_byte = d[15:8];
			default: lane_byte = d[7:0];
		endcase
	end
endfunction

function [1:0] siz_enc;
	input [2:0] n;
	begin
		case (n)
			3'd1: siz_enc = `SIZ_BYTE;
			3'd2: siz_enc = `SIZ_WORD;
			3'd3: siz_enc = `SIZ_3BYTE;
			default: siz_enc = `SIZ_LONG;
		endcase
	end
endfunction

// portion bytes out of the entry buffer, right justified
function [31:0] extract;
	input [31:0] e; input [1:0] off; input [2:0] n;
	reg   [31:0] sh;
	begin
		sh = e << (8 * off);
		case (n)
			3'd1: extract = {24'd0, sh[31:24]};
			3'd2: extract = {16'd0, sh[31:16]};
			3'd3: extract = {8'd0, sh[31:8]};
			default: extract = sh;
		endcase
	end
endfunction

// lowest missing byte of an entry and the contiguous run of missing bytes
function [4:0] missing;     // {run[2:0], byte[1:0]}
	input [3:0] have;
	begin
		if      (!have[0]) missing = {!have[1] ? (!have[2] ? (!have[3] ? 3'd4 : 3'd3) : 3'd2) : 3'd1, 2'd0};
		else if (!have[1]) missing = {!have[2] ? (!have[3] ? 3'd3 : 3'd2) : 3'd1, 2'd1};
		else if (!have[2]) missing = {!have[3] ? 3'd2 : 3'd1, 2'd2};
		else if (!have[3]) missing = {3'd1, 2'd3};
		else               missing = 5'd0;
	end
endfunction

//---------------------------------------------------------------------------
// combinational: evaluate the terminated cycle, decide the transfer's fate
//---------------------------------------------------------------------------
reg        late_err, late_retry;
reg  [3:0] sup;
reg  [1:0] lane_base;
reg [31:0] ebuf_n;
reg  [3:0] have_n;
reg  [2:0] mv;
reg        portion_done;
reg        fin;           // transfer over this clock
reg        opdone;        // operand available this clock
reg        fin_err, fin_avec;
reg        want_fill;
reg  [4:0] miss_after;    // missing() of have_n
wire [4:0] miss_cur = missing(t_have);
reg        entry_fill;    // report the completed entry
reg        beat_abort;    // burst aborted by a late error on beat 1 or an errored beat
integer bi;

always @* begin
	late_err   = 1'b0; late_retry = 1'b0;
	sup = 4'd0; lane_base = 2'd0; ebuf_n = t_ebuf; have_n = t_have; mv = 3'd0;
	portion_done = 1'b0; fin = 1'b0; opdone = 1'b0; fin_err = 1'b0; fin_avec = 1'b0;
	want_fill = 1'b0; entry_fill = 1'b0; beat_abort = 1'b0;
	miss_after = 5'd0;
	bi = 0;                   // loop index: assigned on every path (no latch)

	if (chk_late) begin
		late_err   = term_err | berr_l;
		late_retry = term_retry | (berr_l & halt_l);
		if (!late_retry && !late_err && !term_avec) begin
			// fold the read data of this cycle into the entry buffer
			sup = supplied(term_port, t_addr[1:0]);
			case (term_port)
				`PORT_32: lane_base = 2'd0;
				`PORT_16: lane_base = {t_addr[1], 1'b0};
				default:  lane_base = t_addr[1:0];
			endcase
			for (bi = 0; bi < 4; bi = bi + 1) begin
				if (t_rw && sup[bi]) begin
					have_n[bi] = 1'b1;
					case (bi)
						0: ebuf_n[31:24] = lane_byte(din_l, 2'd0 - lane_base);
						1: ebuf_n[23:16] = lane_byte(din_l, 2'd1 - lane_base);
						2: ebuf_n[15:8]  = lane_byte(din_l, 2'd2 - lane_base);
						default: ebuf_n[7:0] = lane_byte(din_l, 2'd3 - lane_base);
					endcase
				end
			end
			mv = moved(term_port, t_addr[1:0], t_fill ? miss_cur[4:2] : t_rem);
			miss_after = missing(have_n);
			if (t_fill) begin
				if (term_ciin || have_n == 4'b1111) fin = 1'b1;
			end else begin
				portion_done = (t_rem == mv);
				if (portion_done) begin
					opdone = !t_opdone;
					if (term_burst) begin
						// the first beat of a burst also completes the entry
						entry_fill = !term_ciin;
					end else begin
						// UM 6.1.3.1: complete the entry from a narrow port
						want_fill = t_rw && t_cache && !t_noc && !term_ciin &&
						            (have_n != 4'b1111) && (t_kind == `BK_DATA);
						fin = !want_fill;
					end
				end
			end
		end else if (late_retry) begin
			// UM 7.5.2: rerun once HALT negates
		end else if (late_err) begin
			if (t_fill) fin = 1'b1;                 // UM 6.1.3.1: no exception for a fill-only cycle
			else if (term_burst) begin
				// UM 7.5.1: error on the first cycle of a burst -- data ignored,
				// the whole line invalid, exception for a data access
				fin = 1'b1; fin_err = 1'b1; opdone = 1'b1; beat_abort = 1'b1;
			end else begin
				fin = 1'b1; fin_err = 1'b1; opdone = 1'b1;
			end
		end else begin
			fin = 1'b1; fin_avec = 1'b1; opdone = 1'b1;      // IACK by AVEC
		end
	end

	if (beat_pend) begin
		if (berr_l) begin
			// UM 7.5.1: late BERR on a follow-on beat -- that entry stays
			// invalid, no exception, the burst ends
			beat_abort = 1'b1;
			fin = 1'b1;
		end else if (beat_last) begin
			fin = 1'b1;
		end
	end

	// a complete cachable entry from a non-burst transfer
	if (fin && !fin_err && !late_retry && t_rw && t_cache && !t_noc && !term_ciin &&
	    (have_n == 4'b1111) && (t_kind == `BK_DATA) && chk_late && !term_burst)
		entry_fill = 1'b1;
end

//---------------------------------------------------------------------------
// request capture and cycle start
//---------------------------------------------------------------------------
// A request is captured when no transfer is loaded, or in the clock the
// loaded transfer finishes (so a posted write's second portion or the next
// prefetch can start S0 in the same clock a cycle's S5 ends).
wire   accept  = req && (!t_valid || (fin && !(beat_pend && !beat_last && !beat_abort)));
assign req_ack = accept;
assign busy    = t_valid;

// next-cycle parameters: from the new request, or from the transfer
wire        n_from_req = accept;
wire [31:0] n_addr  = n_from_req ? req_addr :
                      (want_fill ? {t_addr[31:2], miss_after[1:0]} :
                       (chk_late && t_fill && !fin) ? {t_addr[31:2], miss_after[1:0]} :
                       (chk_late && !t_fill && !late_retry && !late_err) ? t_addr + {29'd0, mv} : t_addr);
wire  [2:0] n_siz   = n_from_req ? req_total :
                      (want_fill || (chk_late && t_fill && !fin)) ? miss_after[4:2] :
                      (t_fill ? miss_cur[4:2] :
                       (chk_late && !late_retry && !late_err) ? (t_total - mv) : t_total);
wire        n_rw    = n_from_req ? req_rw : t_rw;
wire  [2:0] n_fc    = n_from_req ? req_fc : t_fc;
wire        n_ciout = n_from_req ? req_ciout : t_ciout;
wire        n_rmc   = n_from_req ? req_rmc : t_rmc;
wire        n_ocs   = n_from_req ? req_ocs : t_ocs;
wire        n_kind_data = n_from_req ? (req_kind == `BK_DATA) : (t_kind == `BK_DATA);
wire        n_first = n_from_req ? 1'b1 : t_first;
wire        n_cbreq = n_from_req ? (req_cbreq && req_rw && req_cache && req_kind == `BK_DATA)
                                 : (t_cbreq && t_rw && t_cache && t_first && !t_fill && !want_fill && (t_kind == `BK_DATA));

// more cycles needed by the loaded transfer after this clock's evaluation
wire more_cycles = chk_late && !fin && !late_retry && !late_err && !term_burst &&
                   (want_fill || t_fill || !portion_done);
wire halt_gate   = halt_l | tristate | halted | arb_t;
wire retry_go    = (bst == B_RETRY) && !halt_l;
wire idle_go     = (bst == B_IDLE) && !chk_late && !beat_pend && t_valid;
wire start_now   = !halt_gate && (accept || more_cycles || retry_go || idle_go);

// IACK vector byte on the low byte of the responding port (UM Figure 7-44)
wire [7:0] iack_vec = (term_port == `PORT_32) ? din_l[7:0] :
                      (term_port == `PORT_16) ? din_l[23:16] : din_l[31:24];

assign rmc_n_o   = ~rmc_p;
assign as_n_o    = as_n_r;
assign ds_n_o    = ds_n_r;
assign dben_n_o  = ~(dben_rd | dben_wr);
assign cbreq_n_o = cbreq_n_r;
assign ciout_n_o = ~ciout_p;
assign ecs_n_o   = ~(ecs_p && (ecs_tog != ecs_tog_n));
assign ocs_n_o   = ~(ocs_p && (ecs_tog != ecs_tog_n));
assign bus_idle  = !t_valid && (bst == B_IDLE) && !chk_late && !beat_pend;

//---------------------------------------------------------------------------
// registers
//---------------------------------------------------------------------------
reg        t_term;        // termination decided this clock (S2/S4/Sw rising edge)
reg        t_term_sync, t_term_err, t_term_retry, t_term_avec;
reg  [1:0] t_term_port;
always @* begin
	t_term = 1'b0; t_term_sync = 1'b0; t_term_err = 1'b0; t_term_retry = 1'b0; t_term_avec = 1'b0;
	t_term_port = `PORT_32;
	if (bst == B_S0) begin
		// this rising edge begins S2: STERM alone can end the cycle (UM 7.3.4)
		if (sterm) begin t_term = 1'b1; t_term_sync = 1'b1; end
	end else if (bst == B_S2 || bst == B_WAIT) begin
		// this rising edge begins S4 or a wait state: DSACKx/BERR/AVEC were
		// sampled at the falling edge that ended S2 (or the last Sw)
		if (dsack_l != 2'b00 || berr_l || (avec_l && t_kind == `BK_IACK)) begin
			t_term = 1'b1;
			t_term_port  = (dsack_l == 2'b11) ? `PORT_32 : (dsack_l == 2'b10) ? `PORT_16 : `PORT_8;
			t_term_err   = berr_l;
			t_term_retry = berr_l & halt_l;
			t_term_avec  = avec_l && (t_kind == `BK_IACK) && !berr_l;
		end else if (sterm) begin
			t_term = 1'b1; t_term_sync = 1'b1; t_term_port = `PORT_32;
		end
	end
end
wire enter_burst = t_term && t_term_sync && !t_term_err && cbreq_p && cback && !ciin &&
                   t_rw && t_cache && t_first && !t_fill && (t_kind == `BK_DATA);

always @(posedge clk) begin
	if (rst) begin
		bst <= B_IDLE; t_valid <= 1'b0; t_kind <= 2'd0; t_addr <= 32'd0; t_rem <= 3'd0;
		t_total <= 3'd0; t_rw <= 1'b1; t_fc <= 3'd0; t_rmc_last <= 1'b0; t_rmc <= 1'b0; t_ciout <= 1'b0;
		t_cbreq <= 1'b0; t_ocs <= 1'b0; t_cache <= 1'b0; t_wdata <= 32'd0; t_nbytes <= 3'd0;
		t_off <= 2'd0; t_fill <= 1'b0; t_have <= 4'd0; t_ebuf <= 32'd0; t_noc <= 1'b0;
		t_first <= 1'b1; t_opdone <= 1'b0;
		chk_late <= 1'b0; term_err <= 1'b0; term_retry <= 1'b0; term_avec <= 1'b0;
		term_sync <= 1'b0; term_port <= `PORT_32; term_ciin <= 1'b0; term_burst <= 1'b0;
		beat_pend <= 1'b0; beat_ciin <= 1'b0; beat_last <= 1'b0; beat_cnt <= 2'd0; beat_idx <= 2'd0;
		beat_line <= 28'd0;
		rmc_p <= 1'b0; ciout_p <= 1'b0; cbreq_p <= 1'b0; ecs_p <= 1'b0; ocs_p <= 1'b0;
		ecs_tog <= 1'b0; d_oe_p <= 1'b0; dben_rd_tp <= 1'b0; dben_wr_tp <= 1'b0;
		c_as_set <= 1'b0; c_as_clr <= 1'b0; c_ds_wr <= 1'b0; c_cbreq_clr <= 1'b0; c_latch <= 1'b0;
		done <= 1'b0; rd_data <= 32'd0; res_berr <= 1'b0; res_avec <= 1'b0; res_ciin <= 1'b0;
		fill_stb <= 1'b0; fill_addr <= 30'd0; fill_data <= 32'd0;
		a_o <= 32'd0; fc_o <= 3'd0; siz_o <= 2'd0; rw_o <= 1'b1;
	end else begin
		// one-clock commands
		done <= 1'b0; fill_stb <= 1'b0;
		c_as_set <= 1'b0; c_as_clr <= 1'b0; c_ds_wr <= 1'b0; c_cbreq_clr <= 1'b0;
		c_latch <= 1'b0;
		ecs_p <= 1'b0; ocs_p <= 1'b0;
		chk_late <= 1'b0; beat_pend <= 1'b0;

		if (rmc_release && !t_valid) rmc_p <= 1'b0;

		//------------------------------------------------------ terminated cycle
		if (chk_late) begin
			d_oe_p <= 1'b0;                        // end of S5: data bus released
			if (!t_rw) dben_wr_tp <= ~dben_wr_tp;  // write DBEN held through S5
			if (late_retry) begin
				bst <= B_RETRY;
				if (term_burst) c_as_clr <= 1'b1;  // the burst's first cycle is rerun as a whole
			end else begin
				if (t_rw) begin t_ebuf <= ebuf_n; t_have <= have_n; end
				if (!late_err && !term_avec) begin
					t_first <= 1'b0;
					if (term_ciin) t_noc <= 1'b1;
					if (!t_fill) begin
						t_addr  <= t_addr + {29'd0, mv};
						t_rem   <= t_rem - mv;
						t_total <= t_total - mv;
					end
					if (want_fill) begin
						t_fill <= 1'b1;
						t_addr <= {t_addr[31:2], miss_after[1:0]};
					end else if (t_fill && !fin) begin
						t_addr <= {t_addr[31:2], miss_after[1:0]};
					end
					if (term_burst) begin
						// beat 1 accepted: burst mode (UM 7.3.7 S4..S9); beat_cnt
						// and beat_idx were initialized with the termination
						t_opdone <= 1'b1;
						if (entry_fill) begin
							fill_stb <= 1'b1; fill_addr <= t_addr[31:2]; fill_data <= ebuf_n;
						end
					end
				end else if (late_err && t_fill) begin
					t_noc <= 1'b1;
				end
				if (term_burst && (late_err || term_avec)) begin
					c_as_clr <= 1'b1;                  // abort: negate AS now
					bst <= B_IDLE;
				end
			end
		end

		//------------------------------------------------------ burst beats
		if (beat_pend) begin
			if (berr_l) begin
				if (bst == B_BURST) begin c_as_clr <= 1'b1; bst <= B_IDLE; end
			end else begin
				if (!beat_ciin) begin
					fill_stb <= 1'b1; fill_addr <= {beat_line, beat_idx}; fill_data <= din_l;
				end
				beat_idx <= beat_idx + 2'd1;
			end
		end

		//------------------------------------------------------ results
		if (opdone) begin
			done     <= 1'b1;
			res_berr <= fin_err;
			res_avec <= fin_avec;
			res_ciin <= t_noc | term_ciin;
			rd_data  <= (t_kind == `BK_IACK) ? {24'd0, iack_vec} : extract(ebuf_n, t_off, t_nbytes);
		end
		if (entry_fill && !term_burst) begin
			fill_stb <= 1'b1; fill_addr <= t_addr[31:2]; fill_data <= ebuf_n;
		end
		if (fin) begin
			t_valid <= 1'b0;
			t_fill  <= 1'b0;
			t_opdone <= 1'b0;
			if (t_rmc_last || fin_err) rmc_p <= 1'b0;
			if (bst == B_BURST && !beat_abort) bst <= B_IDLE;
		end

		//------------------------------------------------------ new request
		if (accept) begin
			t_valid <= 1'b1; t_kind <= req_kind; t_addr <= req_addr; t_rem <= req_nbytes;
			t_nbytes <= req_nbytes; t_total <= req_total; t_rw <= req_rw; t_fc <= req_fc;
			t_rmc_last <= req_rmc_last; t_rmc <= req_rmc; t_ciout <= req_ciout; t_cbreq <= req_cbreq;
			t_ocs <= req_ocs; t_cache <= req_cache; t_wdata <= req_wdata; t_off <= req_addr[1:0];
			t_fill <= 1'b0; t_have <= 4'd0; t_ebuf <= 32'd0; t_noc <= 1'b0; t_first <= 1'b1;
			t_opdone <= 1'b0;
		end

		//------------------------------------------------------ cycle start (S0)
		if (start_now) begin
			bst <= B_S0;
			ecs_p <= 1'b1;
			ecs_tog <= ~ecs_tog;
			ocs_p <= n_ocs;
			a_o   <= n_addr;
			fc_o  <= n_fc;
			siz_o <= siz_enc(n_siz);
			rw_o  <= n_rw;
			ciout_p <= n_ciout;
			if (n_rmc) rmc_p <= 1'b1;
			cbreq_p <= n_cbreq;
			c_as_set <= 1'b1;
			t_ocs <= 1'b0;
		end else if (bst == B_RETRY && !halt_l && !t_valid) begin
			bst <= B_IDLE;
		end

		//------------------------------------------------------ cycle progress
		case (bst)
			B_S0, B_S2, B_WAIT: begin
				if (bst == B_S0) begin
					// S2 begins: DBEN on reads, data on the bus for writes
					if (t_rw) dben_rd_tp <= ~dben_rd_tp;
					else d_oe_p <= 1'b1;
				end
				if (t_term) begin
					chk_late  <= 1'b1;
					term_err  <= t_term_err;
					term_retry <= t_term_retry;
					term_avec <= t_term_avec;
					term_sync <= t_term_sync;
					term_port <= t_term_port;
					term_ciin <= t_rw && ciin && (t_kind == `BK_DATA);   // latched with the terminating edge
					term_burst <= enter_burst;
					if (enter_burst) begin beat_cnt <= 2'd0; beat_idx <= t_addr[3:2] + 2'd1; beat_line <= t_addr[31:4]; end
					c_latch   <= t_rw;
					if (!enter_burst) c_as_clr <= 1'b1;   // S3/S5 falling edge
					bst <= enter_burst ? B_BURST : B_IDLE;
				end else begin
					if (bst == B_S0 && !t_rw) c_ds_wr <= 1'b1;   // S3: DS when a write waits
					bst <= (bst == B_S0) ? B_S2 : B_WAIT;
				end
			end
			B_BURST: begin
				if (chk_late && (late_err || late_retry)) begin
					// handled above: burst never entered
				end else if (beat_pend && berr_l) begin
					// handled above
				end else if (berr_l && !chk_late && !beat_pend) begin
					// BERR in lieu of STERM on a follow-on beat: entry invalid, no exception
					c_as_clr <= 1'b1;
					bst <= B_IDLE;
					t_valid <= 1'b0; t_opdone <= 1'b0;
				end else if (sterm) begin
					c_latch <= 1'b1;
					beat_pend <= 1'b1;
					beat_ciin <= ciin;
					beat_cnt  <= beat_cnt + 2'd1;
					// the fourth longword, CBACK negated, or CIIN: this beat is the last
					if (beat_cnt == 2'd2 || !cback || ciin) begin
						beat_last <= 1'b1;
						c_as_clr  <= 1'b1;
						bst <= B_IDLE;
					end else beat_last <= 1'b0;
					if (beat_cnt == 2'd1) c_cbreq_clr <= 1'b1;   // S7: CBREQ negated after the third STERM
				end
			end
			default: ;
		endcase
	end
end

endmodule
