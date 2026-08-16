//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_mmu.v - MC68040 memory management unit (milestone E)               //
//                                                                          //
// Sits between the core memory port and the 16-bit bus adapter:            //
//  - ITT0/1 and DTT0/1 transparent translation matching                    //
//  - split instruction/data ATCs, 16 sets x 4 ways each                    //
//  - three-level table walk with indirect page descriptors, U/M history    //
//    bit updates and accumulated write protection                          //
//  - 4K (TC.P=0) and 8K (TC.P=1) page sizes                                //
//  - protection/translation faults reported with a one-cycle c_flt pulse;  //
//    the faulted request is consumed and the core builds the format $7     //
//    access error frame                                                    //
//  - PTEST performs a real table search and returns MMUSR contents;        //
//    PFLUSH implements the page/global variants over both ATCs             //
//                                                                          //
// The whole unit advances only when ce (clkena) is high. Table searches    //
// are plain read/write cycles (not bus locked): this fabric has a single   //
// CPU master. Invalid translations are not cached, so a descriptor fixed   //
// by a handler takes effect even without a PFLUSH.                         //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_mmu
(
	input             clk,
	input             nreset,
	input             ce,

	// control registers (from the core MOVEC set)
	input      [31:0] tc,          // bit15 E, bit14 P
	input      [31:0] urp,
	input      [31:0] srp,
	input      [31:0] itt0,
	input      [31:0] itt1,
	input      [31:0] dtt0,
	input      [31:0] dtt1,

	// core side
	input             c_req,
	input             c_write,
	input             c_instr,
	input       [1:0] c_size,
	input      [31:0] c_addr,
	input      [31:0] c_wdata,
	input       [2:0] c_fc,
	output            c_ack,
	output     [31:0] c_rdata,
	output reg        c_flt,       // one ce cycle; request is consumed

	// PTEST/PFLUSH sideband
	input             pt_req,
	input             pt_write,
	input      [31:0] pt_addr,
	input       [2:0] pt_fc,
	output reg        pt_done,
	output reg [31:0] pt_mmusr,

	input             pf_req,
	input       [1:0] pf_mode,     // 00 (An) nonglobal, 01 (An), 10 all nonglobal, 11 all
	input      [31:0] pf_addr,
	input       [2:0] pf_fc,
	output reg        pf_done,

	// bus adapter side
	output            m_req,
	output            m_write,
	output            m_instr,
	output      [1:0] m_size,
	output     [31:0] m_addr,
	output     [31:0] m_wdata,
	output      [2:0] m_fc,
	input             m_ack,
	input      [31:0] m_rdata,

	// Dedicated physical longword port used only for table searches.  Keeping
	// descriptor traffic off m_* avoids serialising every descriptor through
	// the 16-bit CPU bus and prevents it from polluting either CPU cache.
	output            walker_req,
	output            walker_we,
	output     [31:0] walker_addr,
	output     [31:0] walker_wdat,
	input             walker_ack,
	input      [31:0] walker_data,
	input             walker_berr,

	output     [31:0] phys_addr,
	output            cache_inhibit,
	output            m_nocache
);

wire tc_e = tc[15];
wire tc_p = tc[14];

//---------------------------------------------------------------------------
// helper functions
//---------------------------------------------------------------------------

function ttr_match;
	input [31:0] ttr;
	input [31:0] la;
	input        sup;
	begin
		ttr_match = ttr[15] &&
		            (&((la[31:24] ~^ ttr[31:24]) | ttr[23:16])) &&
		            (ttr[14] || (ttr[13] == sup));
	end
endfunction

function [31:0] pgtbl_addr;
	input [31:0] desc;
	begin
		pgtbl_addr = tc_p ? {desc[31:7], 7'd0} : {desc[31:8], 8'd0};
	end
endfunction

//---------------------------------------------------------------------------
// address translation cache: index {bank, set, way}, bank 0=data 1=instr
//---------------------------------------------------------------------------

reg         atc_v    [0:127];
reg  [16:0] atc_tag  [0:127];   // {super, LA page tag}
reg  [19:0] atc_pa   [0:127];   // PA[31:12] (bit 0 unused with 8K pages)
reg   [7:0] atc_attr [0:127];   // {G, U1, U0, S, CM1, CM0, M, W}
reg   [1:0] atc_rr   [0:31];    // round robin per {bank, set}
// ATC entries survive RSTI.  Clear them only at FPGA configuration/cold
// start; the initialized flag makes later nreset assertions architectural
// warm resets.
reg         atc_reset_seen = 1'b0;

wire        a_super = c_fc[2];
wire  [3:0] a_set   = tc_p ? c_addr[16:13] : c_addr[15:12];
wire [16:0] a_tag   = tc_p ? {a_super, c_addr[31:17], 1'b0}
                           : {a_super, c_addr[31:16]};
wire  [6:0] a_e0 = {c_instr, a_set, 2'd0};
wire  [6:0] a_e1 = {c_instr, a_set, 2'd1};
wire  [6:0] a_e2 = {c_instr, a_set, 2'd2};
wire  [6:0] a_e3 = {c_instr, a_set, 2'd3};

wire hit0 = atc_v[a_e0] && (atc_tag[a_e0] == a_tag);
wire hit1 = atc_v[a_e1] && (atc_tag[a_e1] == a_tag);
wire hit2 = atc_v[a_e2] && (atc_tag[a_e2] == a_tag);
wire hit3 = atc_v[a_e3] && (atc_tag[a_e3] == a_tag);
wire atc_hit = hit0 | hit1 | hit2 | hit3;

wire  [6:0] hit_e  = hit0 ? a_e0 : hit1 ? a_e1 : hit2 ? a_e2 : a_e3;
wire [19:0] h_pa   = atc_pa[hit_e];
wire  [7:0] h_attr = atc_attr[hit_e];
wire        h_s    = h_attr[4];
wire  [1:0] h_cm   = h_attr[3:2];
wire        h_m    = h_attr[1];
wire        h_w    = h_attr[0];

//---------------------------------------------------------------------------
// transparent translation
//---------------------------------------------------------------------------

wire [31:0] ttra = c_instr ? itt0 : dtt0;
wire [31:0] ttrb = c_instr ? itt1 : dtt1;
wire ttr_hit_a = ttr_match(ttra, c_addr, a_super);
wire ttr_hit_b = ttr_match(ttrb, c_addr, a_super);
wire ttr_hit   = ttr_hit_a | ttr_hit_b;
wire ttr_w     = ttr_hit_a ? ttra[2]   : ttrb[2];
wire [1:0] ttr_cm = ttr_hit_a ? ttra[6:5] : ttrb[6:5];

// PTEST uses DFC to select supervisor/user and instruction/data space.
wire        pt_instr = (pt_fc[1:0] == 2'b10);
wire [31:0] pt_ttra  = pt_instr ? itt0 : dtt0;
wire [31:0] pt_ttrb  = pt_instr ? itt1 : dtt1;
wire        pt_ttr_a = ttr_match(pt_ttra, pt_addr, pt_fc[2]);
wire        pt_ttr_b = ttr_match(pt_ttrb, pt_addr, pt_fc[2]);
wire        pt_ttr_hit = pt_ttr_a | pt_ttr_b;
wire        pt_ttr_w = pt_ttr_a ? pt_ttra[2] : pt_ttrb[2];

//---------------------------------------------------------------------------
// translation decision
//---------------------------------------------------------------------------

wire ttr_fault = ttr_hit && c_write && ttr_w;
wire atc_fault = tc_e && !ttr_hit && atc_hit &&
                 ((c_write && h_w) || (!a_super && h_s));
// write to a clean page runs a table search to set the M bit
wire atc_mmiss = atc_hit && c_write && !h_m && !h_w;

wire need_walk = tc_e && !ttr_hit && (!atc_hit || atc_mmiss) && !atc_fault;

wire [31:0] pa_out =
	ttr_hit ? c_addr :
	(tc_e && atc_hit) ? (tc_p ? {h_pa[19:1], c_addr[12], c_addr[11:0]}
	                          : {h_pa, c_addr[11:0]})
	: c_addr;

//---------------------------------------------------------------------------
// walker state
//---------------------------------------------------------------------------

localparam W_IDLE = 4'd0;
localparam W_RA   = 4'd1;
localparam W_UA   = 4'd2;
localparam W_RB   = 4'd3;
localparam W_UB   = 4'd4;
localparam W_RC   = 4'd5;
localparam W_RI   = 4'd6;
localparam W_UC   = 4'd7;
localparam W_FILL = 4'd8;
localparam W_FLT  = 4'd9;
localparam W_DFLT = 4'd10;
localparam W_DROP = 4'd11;

reg  [3:0] wst;
reg        w_issued;
reg        w_pt;
reg [31:0] w_la;
reg        w_super, w_write, w_user;
reg [31:0] w_desc_addr;
reg [31:0] w_desc;
reg        w_wp;
reg [31:0] w_req_addr, w_req_wdat;
reg        w_req_wr;
reg        w_active;

wire  [6:0] w_pi  = w_la[24:18];
wire  [5:0] w_pgi = tc_p ? {1'b0, w_la[17:13]} : w_la[17:12];

wire walk_ack = w_active && w_issued && walker_ack && !walker_berr;
wire walk_err = w_active && w_issued && walker_berr;

// fill way selection: overwrite an existing mapping of the same page
wire  [3:0] f_set = tc_p ? w_la[16:13] : w_la[15:12];
wire [16:0] f_tag = tc_p ? {w_super, w_la[31:17], 1'b0}
                         : {w_super, w_la[31:16]};
reg         f_bank;
wire  [6:0] f_e0 = {f_bank, f_set, 2'd0};
wire  [6:0] f_e1 = {f_bank, f_set, 2'd1};
wire  [6:0] f_e2 = {f_bank, f_set, 2'd2};
wire  [6:0] f_e3 = {f_bank, f_set, 2'd3};
wire fhit0 = atc_v[f_e0] && (atc_tag[f_e0] == f_tag);
wire fhit1 = atc_v[f_e1] && (atc_tag[f_e1] == f_tag);
wire fhit2 = atc_v[f_e2] && (atc_tag[f_e2] == f_tag);
wire fhit3 = atc_v[f_e3] && (atc_tag[f_e3] == f_tag);
wire       f_way_hit = fhit0 | fhit1 | fhit2 | fhit3;
wire [1:0] f_way = fhit0 ? 2'd0 : fhit1 ? 2'd1 : fhit2 ? 2'd2 : fhit3 ? 2'd3
                 : atc_rr[{f_bank, f_set}];

// PTESTW has ordinary table-search history side effects only when the
// probed write is permitted.  A failed probe still reports W/S in MMUSR.
wire w_hist_m = w_write &&
                  (!w_pt || (!(w_wp || w_desc[2]) &&
                             !(w_user && w_desc[7])));
wire w_denied = !w_pt && ((w_user && w_desc[7]) ||
                          (w_write && (w_wp || w_desc[2])));

//---------------------------------------------------------------------------
// request forwarding
//---------------------------------------------------------------------------

wire pass_ok = c_req && !c_flt && !need_walk && !ttr_fault && !atc_fault &&
               (wst == W_IDLE) && !w_active && !pf_req && !pt_req;

assign m_req   = pass_ok;
assign m_write = c_write;
assign m_instr = c_instr;
assign m_size  = c_size;
assign m_addr  = pa_out;
assign m_wdata = c_wdata;
assign m_fc    = c_fc;

// w_issued inserts a request-low cycle before each descriptor transaction.
// Besides making the interface unambiguous for a level-handshake backend,
// this prevents a held ack from completing the following descriptor.
assign walker_req  = w_active && w_issued;
assign walker_we   = w_req_wr;
assign walker_addr = w_req_addr;
assign walker_wdat = w_req_wdat;

// A downstream ack can only be generated for a request which m_req already
// admitted.  Re-evaluating pass_ok on the response creates a needless
// mem_addr -> ATC lookup -> core-ack critical path (over 50 logic levels in
// TimeQuest) and cannot reject any legitimate stale response because the
// core holds the request stable until ack.
assign c_ack   = m_ack;
assign c_rdata = m_rdata;

assign phys_addr     = pa_out;
assign cache_inhibit = ttr_hit ? ttr_cm[1]
                     : (tc_e && atc_hit) ? h_cm[1] : 1'b0;
assign m_nocache     = cache_inhibit;

//---------------------------------------------------------------------------
// walker FSM (single always block: owns atc arrays and w_* state)
//---------------------------------------------------------------------------

task wrd;
	input [31:0] a;
	begin
		w_req_addr <= a;
		w_req_wr   <= 0;
		w_active   <= 1;
		w_issued   <= 0;
	end
endtask

task wwr;
	input [31:0] a;
	input [31:0] d;
	begin
		w_req_addr <= a;
		w_req_wdat <= d;
		w_req_wr   <= 1;
		w_active   <= 1;
		w_issued   <= 0;
	end
endtask

integer k;

always @(posedge clk) begin
	if (!nreset) begin
		wst <= W_IDLE;
		w_issued <= 0; w_pt <= 0;
		w_la <= 0; w_super <= 0; w_write <= 0; w_user <= 0;
		w_desc_addr <= 0; w_desc <= 0; w_wp <= 0;
		w_req_addr <= 0; w_req_wdat <= 0; w_req_wr <= 0;
		w_active <= 0; f_bank <= 0;
		c_flt <= 0;
		pt_done <= 0; pt_mmusr <= 0;
		pf_done <= 0;
		if (!atc_reset_seen) begin
			for (k = 0; k < 128; k = k + 1) atc_v[k] <= 0;
			for (k = 0; k < 32; k = k + 1) atc_rr[k] <= 0;
		end
		atc_reset_seen <= 1;
	end
	else if (ce) begin
		c_flt <= 0;
		pt_done <= 0;
		pf_done <= 0;
		if (w_active && !w_issued) w_issued <= 1;

		if (walk_err) begin
			// A physical bus error while fetching or updating a descriptor is
			// reported as an unsuccessful table search.  Do not fill the ATC.
			// A probing PTEST reports it in the MMUSR B bit.
			w_active <= 0;
			if (w_pt) begin
				pt_mmusr <= 32'h0000_0800;
				pt_done <= 1;
				w_pt <= 0;
				wst <= W_IDLE;
			end
			else wst <= W_FLT;
		end
		else case (wst)
			W_IDLE: begin
				if (pf_req && !pf_done) begin
					for (k = 0; k < 128; k = k + 1) begin
						if (pf_mode[1] ||
						    ((atc_tag[k] == (tc_p ? {pf_fc[2], pf_addr[31:17], 1'b0}
						                             : {pf_fc[2], pf_addr[31:16]})) &&
						     (k[5:2] == (tc_p ? pf_addr[16:13] : pf_addr[15:12])))) begin
							if (pf_mode[0] || !atc_attr[k][7])
								atc_v[k] <= 0;
						end
					end
					pf_done <= 1;
				end
				else if (pt_req && !pt_done) begin
					// A PTEST first discards the matching entry in BOTH ATCs
					// (WinUAE's mmu_flush_atc iterates the data and the
					// instruction array).  A successful search below installs
					// a fresh entry in the ATC its DFC selects.
					for (k = 0; k < 128; k = k + 1) begin
						if ((k[5:2] == (tc_p ? pt_addr[16:13] : pt_addr[15:12])) &&
						    (atc_tag[k] == (tc_p ? {pt_fc[2], pt_addr[31:17], 1'b0}
						                               : {pt_fc[2], pt_addr[31:16]})))
							atc_v[k] <= 0;
					end
					w_pt    <= 1;
					w_la    <= pt_addr;
					w_super <= pt_fc[2];
					w_user  <= !pt_fc[2];
					w_write <= pt_write;
					w_wp    <= 0;
					f_bank  <= pt_instr;
					if (pt_ttr_hit) begin
						// A TTR match reports T and R only -- the physical
						// address field stays clear -- and a write probe
						// against a write-protected TTR reports B (WinUAE
						// mmu_op PTEST: MMU_MMUSR_B, not a G-bit pattern).
						pt_mmusr <= (pt_write && pt_ttr_w) ? 32'h0000_0800
						                                   : 32'h0000_0003;
						pt_done <= 1;
						w_pt <= 0;
					end
					else begin
						// PTEST runs the table search even when translation
						// is disabled: TC.E gates ordinary accesses only,
						// the probe always walks URP/SRP (WinUAE has no
						// tc_e test in its PTEST path).
						wrd({(pt_fc[2] ? srp[31:9] : urp[31:9]), 9'd0} +
						    {23'd0, pt_addr[31:25], 2'b00});
						wst <= W_RA;
					end
				end
				else if (c_req && !c_flt && (ttr_fault || atc_fault)) begin
					c_flt <= 1;
				end
				else if (c_req && !c_flt && need_walk) begin
					w_pt    <= 0;
					w_la    <= c_addr;
					w_super <= a_super;
					w_user  <= !a_super;
					w_write <= c_write;
					w_wp    <= 0;
					f_bank  <= c_instr;
					wrd({(a_super ? srp[31:9] : urp[31:9]), 9'd0} +
					    {23'd0, c_addr[31:25], 2'b00});
					wst <= W_RA;
				end
			end

			W_RA: if (walk_ack) begin
				w_desc <= walker_data;
				w_desc_addr <= w_req_addr;
				w_active <= 0;
				if (!walker_data[1]) wst <= W_FLT;   // UDT invalid
				else begin
					w_wp <= w_wp | walker_data[2];
					if (!walker_data[3]) begin
						wwr(w_req_addr, walker_data | 32'h8);
						wst <= W_UA;
					end
					else begin
						wrd({walker_data[31:9], 9'd0} + {23'd0, w_pi, 2'b00});
						wst <= W_RB;
					end
				end
			end

			W_UA: if (walk_ack) begin
				w_active <= 0;
				wrd({w_desc[31:9], 9'd0} + {23'd0, w_pi, 2'b00});
				wst <= W_RB;
			end

			W_RB: if (walk_ack) begin
				w_desc <= walker_data;
				w_desc_addr <= w_req_addr;
				w_active <= 0;
				if (!walker_data[1]) wst <= W_FLT;
				else begin
					w_wp <= w_wp | walker_data[2];
					if (!walker_data[3]) begin
						wwr(w_req_addr, walker_data | 32'h8);
						wst <= W_UB;
					end
					else begin
						wrd(pgtbl_addr(walker_data) + {24'd0, w_pgi, 2'b00});
						wst <= W_RC;
					end
				end
			end

			W_UB: if (walk_ack) begin
				w_active <= 0;
				wrd(pgtbl_addr(w_desc) + {24'd0, w_pgi, 2'b00});
				wst <= W_RC;
			end

			W_RC: if (walk_ack) begin
				w_desc <= walker_data;
				w_desc_addr <= w_req_addr;
				w_active <= 0;
				case (walker_data[1:0])
					2'b00: wst <= W_FLT;
					2'b10: begin
						wrd(walker_data & 32'hFFFF_FFFC);
						wst <= W_RI;
					end
					default: wst <= W_UC;
				endcase
			end

			W_RI: if (walk_ack) begin
				w_desc <= walker_data;
				w_desc_addr <= w_req_addr;
				w_active <= 0;
				// an indirect descriptor must resolve to a resident page
				if (walker_data[1:0] == 2'b00 || walker_data[1:0] == 2'b10) wst <= W_FLT;
				else wst <= W_UC;
			end

			W_UC: begin
				// A valid page descriptor is used by the table search even when
				// its protection attributes deny the access.  The 68040 therefore
				// sets U before reporting the access error, but must not set M for
				// a denied write.  Defer c_flt until the descriptor writeback has
				// completed, then keep the walker quiescent until the core drops
				// the held request; otherwise it can immediately begin a second
				// walk before the access-error state has consumed the fault pulse.
				if (w_denied) begin
					if (!w_desc[3]) begin
						wwr(w_desc_addr, w_desc | 32'h8);
						w_desc <= w_desc | 32'h8;
					end
					wst <= W_DFLT;
				end
				else if (!w_desc[3] || (w_hist_m && !w_desc[4])) begin
					wwr(w_desc_addr, w_desc | 32'h8 |
					    (w_hist_m ? 32'h10 : 32'h0));
					w_desc <= w_desc | 32'h8 | (w_hist_m ? 32'h10 : 32'h0);
					wst <= W_FILL;
				end
				else wst <= W_FILL;
			end

			// Protection fault after the optional Used-bit writeback.
			W_DFLT: begin
				if (w_active) begin
					if (walk_ack) w_active <= 0;
				end
				else begin
					c_flt <= 1;
					wst <= W_DROP;
				end
			end

			// c_flt is sampled by the core one ce edge after it is registered.
			// Do not return to W_IDLE until that edge has made c_req fall.
			W_DROP: begin
				if (!c_req) wst <= W_IDLE;
			end

			W_FILL: begin
				if (w_active) begin
					if (walk_ack) w_active <= 0;
				end
				else if (w_pt) begin
					atc_v[{f_bank, f_set, f_way}]    <= 1;
					atc_tag[{f_bank, f_set, f_way}]  <= f_tag;
					atc_pa[{f_bank, f_set, f_way}]   <=
						tc_p ? {w_desc[31:13], 1'b0} : w_desc[31:12];
					atc_attr[{f_bank, f_set, f_way}] <=
						{w_desc[10], w_desc[9:8], w_desc[7], w_desc[6:5],
						 w_desc[4], (w_wp | w_desc[2])};
					if (!f_way_hit)
						atc_rr[{f_bank, f_set}] <= atc_rr[{f_bank, f_set}] + 2'd1;
					pt_mmusr <= (tc_p ? {w_desc[31:13], w_la[12], 12'd0}
					                  : {w_desc[31:12], 12'd0}) |
					            {21'd0, w_desc[10], w_desc[9:8], w_desc[7],
					             w_desc[6:5], w_desc[4], 1'b0,
					             (w_wp | w_desc[2]), 1'b0, 1'b1};
					pt_done <= 1;
					w_pt <= 0;
					wst <= W_IDLE;
				end
				else begin
					atc_v[{f_bank, f_set, f_way}]    <= 1;
					atc_tag[{f_bank, f_set, f_way}]  <= f_tag;
					atc_pa[{f_bank, f_set, f_way}]   <=
						tc_p ? {w_desc[31:13], 1'b0} : w_desc[31:12];
					atc_attr[{f_bank, f_set, f_way}] <=
						{w_desc[10], w_desc[9:8], w_desc[7], w_desc[6:5],
						 w_desc[4], (w_wp | w_desc[2])};
					if (!f_way_hit)
						atc_rr[{f_bank, f_set}] <= atc_rr[{f_bank, f_set}] + 2'd1;
					wst <= W_IDLE;   // the held request now hits and forwards
				end
			end

			W_FLT: begin
				if (w_pt) begin
					pt_mmusr <= 32'd0;   // not resident
					pt_done <= 1;
					w_pt <= 0;
				end
				else c_flt <= 1;
				wst <= W_IDLE;
			end

			default: wst <= W_IDLE;
		endcase
	end
end

endmodule
