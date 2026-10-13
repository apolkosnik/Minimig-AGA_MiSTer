//--------------------------------------------------------------------------//
// AP68060 - pipelined MC68060                                              //
//                                                                          //
// ap68060_snoop.sv - bus snooper (MC68060UM 2.6, 5.6, 7.12)                 //
//                                                                          //
// While another master owns the bus, a transfer it starts (TS) with       //
// SNOOP asserted and TT1 = 0 (a normal or MOVE16 transfer) is snooped:    //
// the line at A31-A4 is invalidated in both caches, whatever the          //
// direction, size or the line's state -- a dirty line's data is lost (the //
// 68060 needs shared pages write-through or cache-inhibited).  Nothing is //
// driven on the bus: no memory inhibit, no intervention, no termination   //
// needed for the snooped transfer.  A3:A0 do not matter.                  //
//                                                                          //
// The manual puts no limit on how fast snooped transfers may follow each  //
// other (a snoop has priority over the processor, 5.6), so the data cache //
// side keeps up with one every bus clock: a copy of the data cache's tags //
// and valid bits here, kept with the DMU's writes, checks each snooped    //
// line a clock after its TS.  A miss needs nothing more; a hit is queued  //
// by set and way and the DMU invalidates it in one frozen clock (one per  //
// clock).  A line that may be a dirty line waiting for its push (the push //
// buffer, a push queued for the bus) goes through the DMU's full lookup,  //
// which also cancels the push: at most two such lines exist.  The         //
// instruction cache's invalidations go through the fetch unit's request; //
// a full queue there turns into an invalidation of every line (more than  //
// the 68060 drops, never less: its contents are only copies).  dc_ovf     //
// records a data-cache queue overflow for the bench (it cannot happen).   //
//--------------------------------------------------------------------------//

module ap68060_snoop
	import ap68060_pkg::*;
#(
	parameter int DQ = 2,           // full lookups (a push's line)
	parameter int FQ = 8            // fast invalidations
)(
	input  logic        clk,
	input  logic        nreset,
	input  logic        bclk_en,
	input  logic        own,            // BIU: we drive the bus

	// the bus, as the alternate master drives it
	input  logic [31:0] a_i,
	input  logic        ts_n_i,
	input  logic  [1:0] tt_i,
	input  logic        snoop_n,

	// data cache: the DMU's snoop port (invalidate what is found)
	output logic        dc_req,
	output logic [31:0] dc_pa,
	input  logic        dc_look,
	input  logic        dc_hit,
	output logic        dc_inv,
	output logic        dc_ovf,         // (simulation) the queue overflowed
	output logic        busy,           // invalidations still to be made
	output logic        sf_req,         // a way to invalidate (fast)
	output logic  [6:0] sf_set,
	output logic  [1:0] sf_way,
	output logic        sf_more,        // ... and another one after it
	input  logic        sf_ack,
	// the data cache's state, for the copy
	input  logic        dt_we,
	input  logic  [6:0] dt_set,
	input  logic  [1:0] dt_way,
	input  logic [20:0] dt_tag,
	input  logic        dv_we,
	input  logic  [6:0] dv_set,
	input  logic  [3:0] dv_wm,
	input  logic        dv_lv,
	input  logic        pq0_v,
	input  logic [27:0] pq0_l,
	input  logic        pq1_v,
	input  logic [27:0] pq1_l,

	// instruction cache: line invalidation in the fetch unit
	output logic        ic_req,
	output logic [31:0] ic_pa,
	output logic        ic_all,         // ... or every line (queue overflow)
	input  logic        ic_done
);

// a snooped transfer starts on this bus clock edge
wire        snoop = bclk_en && !own && !ts_n_i && !snoop_n && !tt_i[1];
wire [27:0] nl    = a_i[31:4];

//--------------------------------------------------------------------------
// the data cache's copy: tags in block RAM (written as the DMU's tag RAM
// is), valid bits in block RAM (written a clock after the DMU's), both read
// at the snooped set on the TS clock; the writes the reads cannot see yet
// are laid over the result
//--------------------------------------------------------------------------
logic [20:0] ct_q [4];
logic        cv_q [4];
genvar gw;
generate
	for (gw = 0; gw < 4; gw++) begin : g_way
		(* ramstyle = "M10K, no_rw_check" *) logic [20:0] ct [0:127];
		(* ramstyle = "M10K, no_rw_check" *) logic       cv [0:127];
		always_ff @(posedge clk) begin
			if (dt_we && dt_way == 2'(gw)) ct[dt_set] <= dt_tag;
			if (dv_we && dv_wm[gw]) cv[dv_set] <= dv_lv;
			ct_q[gw] <= ct[nl[6:0]];
			cv_q[gw] <= cv[nl[6:0]];
		end
		// synthesis translate_off
		initial for (int i = 0; i < 128; i++) begin ct[i] = '0; cv[i] = 1'b0; end
		// synthesis translate_on
	end
endgenerate

// the snooped line, a clock after its TS
logic        sp_v;
logic [27:0] sp_l;
// the writes that land with or after the reads: the tag write and the
// valid write of the TS clock, the valid write of this one
logic        ow_t, ow_v;
logic  [6:0] ow_tset, ow_vset;
logic  [1:0] ow_tway;
logic [20:0] ow_tag;
logic  [3:0] ow_wm;
logic        ow_lv;
always_ff @(posedge clk) begin
	sp_v    <= nreset && snoop;
	sp_l    <= nl;
	ow_t    <= dt_we;
	ow_tset <= dt_set;
	ow_tway <= dt_way;
	ow_tag  <= dt_tag;
	ow_v    <= dv_we;
	ow_vset <= dv_set;
	ow_wm   <= dv_wm;
	ow_lv   <= dv_lv;
end

logic       sp_hit, sp_slow;
logic [1:0] sp_way;
always_comb begin
	logic [20:0] t [4];
	logic        v [4];
	for (int i = 0; i < 4; i++) begin
		t[i] = ct_q[i];
		v[i] = cv_q[i];
		if (ow_t && ow_tset == sp_l[6:0] && ow_tway == 2'(i)) t[i] = ow_tag;
		if (ow_v && ow_vset == sp_l[6:0] && ow_wm[i]) v[i] = ow_lv;
		if (dv_we && dv_set == sp_l[6:0] && dv_wm[i]) v[i] = dv_lv;
	end
	sp_hit = 1'b0;
	sp_way = 2'd0;
	for (int i = 0; i < 4; i++)
		if (v[i] && t[i] == sp_l[27:7]) begin sp_hit = 1'b1; sp_way = 2'(i); end
	sp_slow = (pq0_v && pq0_l == sp_l) || (pq1_v && pq1_l == sp_l);
end

//--------------------------------------------------------------------------
// fast invalidations: set and way
//--------------------------------------------------------------------------
// A hit is queued; with the queue empty it also asks at once, so the DMU
// freezes for it the next clock (two clocks after the TS, as soon as the
// full lookup used to), when the entry is at the head
logic [8:0] fq [FQ];
logic [$clog2(FQ):0] fn;
logic        fq_ovf, dq_ovf;
logic        sp_new;            // a hit not queued yet
assign dc_ovf = fq_ovf || dq_ovf;
always_comb begin
	sp_new = sp_v && sp_hit && !sp_slow;
	for (int i = 0; i < FQ; i++)
		if (i < fn && !(sf_ack && i == 0) && fq[i] == {sp_l[6:0], sp_way}) sp_new = 1'b0;
end
assign sf_req  = (fn != 0) || sp_new;
assign sf_set  = fq[0][8:2];
assign sf_way  = fq[0][1:0];
assign sf_more = (fn > 1) || (fn == 1 && sp_new);

always_ff @(posedge clk) begin
	if (!nreset) begin
		fn <= '0; fq_ovf <= 1'b0;
		for (int i = 0; i < FQ; i++) fq[i] <= '0;
	end
	else begin
		logic [$clog2(FQ):0] n;
		n = fn;
		if (sf_ack) begin
			for (int i = 0; i < FQ - 1; i++) fq[i] <= fq[i + 1];
			n = n - 1'd1;
		end
		if (sp_new) begin
			if (n < FQ) begin
				fq[n] <= {sp_l[6:0], sp_way};
				n = n + 1'd1;
			end
			else fq_ovf <= 1'b1;
		end
		fn <= n;
		if (sf_ack && fn == 0) fq_ovf <= 1'b1;      // (cannot happen: for the bench)
	end
end

//--------------------------------------------------------------------------
// full lookups (a line that may be waiting for its push)
//--------------------------------------------------------------------------
logic [27:0] dq [DQ];
logic [$clog2(DQ):0] dn;
logic        dbusy;             // the head is being looked up

always_ff @(posedge clk) begin
	dc_inv <= 1'b0;
	if (!nreset) begin
		dn <= '0; dbusy <= 1'b0; dc_req <= 1'b0; dc_pa <= '0; dq_ovf <= 1'b0;
		for (int i = 0; i < DQ; i++) dq[i] <= '0;
	end
	else begin
		logic [$clog2(DQ):0] n;
		logic dup, pop;
		n = dn;
		pop = dbusy && dc_look;
		// the head's lookup: invalidate on a hit, then the next entry
		if (pop) begin
			dc_inv <= dc_hit;
			dc_req <= 1'b0;
			dbusy  <= 1'b0;
			for (int i = 0; i < DQ - 1; i++) dq[i] <= dq[i + 1];
			n = n - 1'd1;
		end
		if (sp_v && sp_slow) begin
			// (a head whose lookup ends now does not cover a new snoop)
			dup = 1'b0;
			for (int i = 0; i < DQ; i++)
				if (i < dn && !(pop && i == 0) && dq[i] == sp_l) dup = 1'b1;
			if (!dup) begin
				if (n < DQ) begin
					dq[n] <= sp_l;
					n = n + 1'd1;
				end
				else dq_ovf <= 1'b1;
			end
		end
		dn <= n;
		// the head's lookup starts at once.  Not in the clock a lookup
		// ends: the DMU's port waits for the request to drop.
		if (!dbusy && n != 0) begin
			dc_req <= 1'b1;
			dc_pa  <= {(dn != 0) ? dq[0] : sp_l, 4'd0};
			dbusy  <= 1'b1;
		end
	end
end

// the data cache's invalidations hold the processor's next transfer (a
// push of a line a snoop hit must not go out); the instruction cache's do
// not, the fetch unit making them only outside a line fill
assign busy = snoop || sp_v || (fn != 0) || (dn != 0) || dc_req || dbusy;

//--------------------------------------------------------------------------
// instruction cache queue: two entries, overflow -> every line
//--------------------------------------------------------------------------
logic        iq_v1, iq_all;
logic [27:0] iq_l1;
always_ff @(posedge clk) begin
	if (!nreset) begin
		ic_req <= 1'b0; ic_pa <= '0; ic_all <= 1'b0;
		iq_v1 <= 1'b0; iq_all <= 1'b0; iq_l1 <= '0;
	end
	else begin
		logic        v0, a0, v1, ov;
		logic [27:0] l0, l1;
		v0 = ic_req; a0 = ic_all; l0 = ic_pa[31:4];
		v1 = iq_v1;  ov = iq_all; l1 = iq_l1;
		if (ic_done) begin
			// the head is done: the second entry moves up
			v0 = v1 || ov; a0 = ov; l0 = l1;
			v1 = 1'b0; ov = 1'b0;
		end
		if (snoop) begin
			if (!v0) begin v0 = 1'b1; a0 = 1'b0; l0 = nl; end
			else if (a0 || l0 == nl || ov || (v1 && l1 == nl)) ;   // covered
			else if (!v1) begin v1 = 1'b1; l1 = nl; end
			else ov = 1'b1;
		end
		ic_req <= v0; ic_all <= a0; ic_pa <= {l0, 4'd0};
		iq_v1  <= v1; iq_all <= ov; iq_l1 <= l1;
	end
end

endmodule
