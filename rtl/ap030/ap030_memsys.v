//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_memsys.v - memory subsystem: data unit, prefetch port, caches,     //
// MMU and the bus controller                                               //
//                                                                          //
// Data accesses are split into longword portions (at most two, UM 7.2.2).  //
// Each portion is looked up in the data cache while the MMU translates it   //
// (UM 9.2).  Reads that hit are served in two clocks; misses go to the bus  //
// controller, which completes the cache entry and may burst the line.      //
// Writes update the cache first (write-through, UM 6.1.2) and are posted   //
// to a one-deep write buffer (the "write pending buffer" of UM Figure 6-1)  //
// so execution continues; a bus error on a posted write is reported as a    //
// late fault.  Read-modify-write accesses bypass the cache read, assert     //
// RMC from the first read to the last write and are never posted.          //
//                                                                          //
// The instruction port fetches aligned longwords through the instruction   //
// cache with the same MMU.  Table searches use the bus with RMC asserted.  //
//                                                                          //
// Bus priority: table search, then the write buffer, then data, then       //
// instruction prefetch.                                                    //
//--------------------------------------------------------------------------//

`include "ap030_defs.svh"

module ap030_memsys
(
	input             clk,
	input             rst,

	// ---- control from the core ------------------------------------------
	input      [31:0] cacr,
	input             cacr_ci,      // pulses: clear instruction cache / entry, data cache / entry
	input             cacr_cei,
	input             cacr_cd,
	input             cacr_ced,
	input       [7:2] caar_idx,
	input             cdis,
	input             mmudis,
	input             halted,

	// ---- data port ---------------------------------------------------------
	input             d_stb,        // pulse: start an access; d_* held until d_ack / d_fault / d_iack_berr
	input      [31:0] d_addr,
	input       [1:0] d_size,       // SZ_B/W/L
	input             d_rw,
	input             d_rmc,        // this access is part of a read-modify-write
	input             d_rmc_last,   // ... and is its last cycle
	input             d_rmc_release,// pulse: end the RMW without a write (CAS mismatch)
	input             d_iack,       // interrupt acknowledge cycle (fc = 7)
	input             d_nocache,    // read past the data cache: no hit, no fill
	// external writes (other bus masters) to invalidate in the data cache
	input             snoop_we,
	input      [31:0] snoop_addr,
	input       [2:0] d_fc,
	input      [31:0] d_wdata,
	output            d_ack,        // pulse: read data valid / write accepted
	output     [31:0] d_rdata,
	output reg        d_fault,      // pulse: this access faulted (details in f_*)
	output reg        d_avec,       // with d_ack on an IACK: autovectored
	output reg        d_iack_berr,  // pulse: IACK bus error (spurious interrupt)
	output reg        d_late_fault, // pulse: a posted write faulted (details in f_*)
	output            d_wpend,      // a posted write is outstanding
	// fault record (valid with d_fault / d_late_fault)
	output reg [31:0] f_addr,
	output reg  [2:0] f_fc,
	output reg  [1:0] f_size,       // SIZ encoding of the remaining bytes
	output reg        f_rw,
	output reg        f_rm,
	output reg [31:0] f_dob,        // remaining write data, right justified
	output reg  [2:0] f_got,        // bytes of the operand already read before the fault
	output reg [31:0] f_partial,    // those bytes, right justified

	// ---- instruction port --------------------------------------------------
	input             i_stb,        // pulse: start a fetch (only when i_ready)
	input      [31:0] i_addr,       // longword aligned
	input       [2:0] i_fc,
	output            i_ready,      // a request can be presented: one more may be outstanding
	output            i_ack,
	output     [31:0] i_data,
	output reg        i_fault,

	// ---- MMU instructions and registers ---------------------------------
	input             op_req,
	input       [2:0] op_kind,
	input       [2:0] op_level,
	input      [31:0] op_la,
	input       [2:0] op_fc,
	input       [2:0] op_fcmask,
	output            op_done,
	output     [31:0] op_desc_addr,
	input             reg_we,
	input       [2:0] reg_sel,
	input      [31:0] reg_wdata_hi,
	input      [31:0] reg_wdata_lo,
	input             reg_fd,
	output            cfg_err,
	output     [31:0] tc,
	output     [31:0] srp_hi, srp_lo, crp_hi, crp_lo,
	output     [31:0] tt0, tt1,
	output     [15:0] mmusr,

	output            bus_quiet,    // no posted write, no bus activity (NOP synchronization)

	// ---- MC68030 pins ------------------------------------------------------
	output     [31:0] a_o,
	output      [2:0] fc_o,
	output      [1:0] siz_o,
	output            rw_o,
	output            rmc_n_o, as_n_o, ds_n_o, dben_n_o, ecs_n_o, ocs_n_o, ciout_n_o, cbreq_n_o,
	output            bus_oe,
	output     [31:0] d_o,
	output            d_oe,
	input      [31:0] d_i,
	input             dsack0_n, dsack1_n, sterm_n, berr_n, halt_n, avec_n, ciin_n, cback_n,
	input             br_n, bgack_n,
	output            bg_n_o,
	output            bus_granted
);

//---------------------------------------------------------------------------
// MMU
//---------------------------------------------------------------------------
reg  [31:0] tr_la;
reg   [2:0] tr_fc;
reg         tr_rw, tr_rmc, tr_use, walk_req;
reg  [31:0] walk_la;
reg   [2:0] walk_fc;
reg         walk_rw, walk_rmc;
wire        tr_ok, tr_fault, tr_walk, tr_ci;
wire [31:0] tr_pa;
wire        walk_done;
wire        w_req, w_rw, w_active, mmu_busy;
wire walker_busy = mmu_busy;
wire [31:0] w_addr, w_wdata;
reg         w_ack;
reg  [31:0] w_rdata;
reg         w_berr;

ap030_mmu mmu (
	.clk(clk), .rst(rst),
	.tr_la(tr_la), .tr_fc(tr_fc), .tr_rw(tr_rw), .tr_rmc(tr_rmc), .mmudis(mmudis),
	.tr_ok(tr_ok), .tr_fault(tr_fault), .tr_walk(tr_walk), .tr_pa(tr_pa), .tr_ci(tr_ci), .tr_use(tr_use),
	.walk_req(walk_req), .walk_la(walk_la), .walk_fc(walk_fc), .walk_rw(walk_rw), .walk_rmc(walk_rmc),
	.walk_done(walk_done),
	.op_req(op_req), .op_kind(op_kind), .op_level(op_level), .op_la(op_la), .op_fc(op_fc),
	.op_fcmask(op_fcmask), .op_done(op_done), .op_desc_addr(op_desc_addr),
	.reg_we(reg_we), .reg_sel(reg_sel), .reg_wdata_hi(reg_wdata_hi), .reg_wdata_lo(reg_wdata_lo),
	.reg_fd(reg_fd), .cfg_err(cfg_err), .tc(tc), .srp_hi(srp_hi), .srp_lo(srp_lo),
	.crp_hi(crp_hi), .crp_lo(crp_lo), .tt0(tt0), .tt1(tt1), .mmusr(mmusr),
	.w_req(w_req), .w_addr(w_addr), .w_rw(w_rw), .w_wdata(w_wdata), .w_ack(w_ack),
	.w_rdata(w_rdata), .w_berr(w_berr), .w_active(w_active), .busy(mmu_busy)
);

//---------------------------------------------------------------------------
// caches
//---------------------------------------------------------------------------
wire ic_en  = cacr[`CACR_EI] & ~cdis;
wire dc_en  = cacr[`CACR_ED] & ~cdis;
wire ic_fill_ok = ic_en & ~cacr[`CACR_FI];
wire dc_fill_ok = dc_en & ~cacr[`CACR_FD];

reg  [31:0] ic_lk_la;
reg   [2:0] ic_lk_fc;
wire        ic_tag_hit, ic_hit, ic_line_empty;
wire [31:0] ic_data;
reg         ic_fi_we;
reg  [31:2] ic_fi_addr;
reg   [2:0] ic_fi_fc;
reg  [31:0] ic_fi_data;

ap030_cache #(.FC_BITS(1)) icache (
	.clk(clk), .rst(rst),
	.lk_la(ic_lk_la), .lk_fc(ic_lk_fc), .lk_tag_hit(ic_tag_hit), .lk_hit(ic_hit),
	.lk_line_empty(ic_line_empty), .lk_data(ic_data),
	.fi_we(ic_fi_we), .fi_addr(ic_fi_addr), .fi_fc(ic_fi_fc), .fi_data(ic_fi_data),
	.wr_we(1'b0), .wr_la(32'd0), .wr_fc(3'd0), .wr_be(4'd0), .wr_data(32'd0), .wr_wa(1'b0), .wr_allow_fill(1'b0),
	.inv_we(1'b0), .inv_la(32'd0),
	.snp_we(1'b0), .snp_la(32'd0),
	.clr_all(cacr_ci), .clr_entry(cacr_cei), .clr_index(caar_idx)
);

reg  [31:0] dc_lk_la;
reg   [2:0] dc_lk_fc;
wire        dc_tag_hit, dc_hit, dc_line_empty;
wire [31:0] dc_data;
reg         dc_fi_we;
reg  [31:2] dc_fi_addr;
reg   [2:0] dc_fi_fc;
reg  [31:0] dc_fi_data;
reg         dc_wr_we;
reg  [31:0] dc_wr_la;
reg   [2:0] dc_wr_fc;
reg   [3:0] dc_wr_be;
reg  [31:0] dc_wr_data;
reg         dc_inv_we;
reg  [31:0] dc_inv_la;

ap030_cache #(.FC_BITS(3)) dcache (
	.clk(clk), .rst(rst),
	.lk_la(dc_lk_la), .lk_fc(dc_lk_fc), .lk_tag_hit(dc_tag_hit), .lk_hit(dc_hit),
	.lk_line_empty(dc_line_empty), .lk_data(dc_data),
	.fi_we(dc_fi_we), .fi_addr(dc_fi_addr), .fi_fc(dc_fi_fc), .fi_data(dc_fi_data),
	.wr_we(dc_wr_we), .wr_la(dc_wr_la), .wr_fc(dc_wr_fc), .wr_be(dc_wr_be), .wr_data(dc_wr_data),
	.wr_wa(cacr[`CACR_WA]), .wr_allow_fill(dc_fill_ok),
	.inv_we(dc_inv_we), .inv_la(dc_inv_la),
	.snp_we(snoop_we), .snp_la(snoop_addr),
	.clr_all(cacr_cd), .clr_entry(cacr_ced), .clr_index(caar_idx)
);

//---------------------------------------------------------------------------
// bus controller
//---------------------------------------------------------------------------
reg         b_req;
reg   [1:0] b_kind;
reg  [31:0] b_addr;
reg   [2:0] b_nbytes, b_total;
reg         b_rw;
reg   [2:0] b_fc;
reg         b_rmc, b_rmc_last, b_ciout, b_cbreq, b_ocs, b_cache;
reg  [31:0] b_wdata;
wire        b_ack, b_busy, b_done, b_berr, b_avec, b_ciin, b_fill_stb, b_idle;
wire [31:0] b_rdata, b_fill_data;
wire [31:2] b_fill_addr;
reg         b_rmc_release;

ap030_bus bus (
	.clk(clk), .rst(rst),
	.req(b_req), .req_kind(b_kind), .req_addr(b_addr), .req_nbytes(b_nbytes), .req_total(b_total),
	.req_rw(b_rw), .req_fc(b_fc), .req_rmc(b_rmc), .req_rmc_last(b_rmc_last), .req_ciout(b_ciout),
	.req_cbreq(b_cbreq), .req_ocs(b_ocs), .req_cache(b_cache), .req_wdata(b_wdata),
	.req_ack(b_ack), .busy(b_busy), .done(b_done), .rd_data(b_rdata), .res_berr(b_berr),
	.res_avec(b_avec), .res_ciin(b_ciin), .fill_stb(b_fill_stb), .fill_addr(b_fill_addr),
	.fill_data(b_fill_data), .rmc_release(b_rmc_release), .halted(halted), .bus_idle(b_idle),
	.a_o(a_o), .fc_o(fc_o), .siz_o(siz_o), .rw_o(rw_o), .rmc_n_o(rmc_n_o), .as_n_o(as_n_o),
	.ds_n_o(ds_n_o), .dben_n_o(dben_n_o), .ecs_n_o(ecs_n_o), .ocs_n_o(ocs_n_o), .ciout_n_o(ciout_n_o),
	.cbreq_n_o(cbreq_n_o), .bus_oe(bus_oe), .d_o(d_o), .d_oe(d_oe), .d_i(d_i),
	.dsack0_n(dsack0_n), .dsack1_n(dsack1_n), .sterm_n(sterm_n), .berr_n(berr_n), .halt_n(halt_n),
	.avec_n(avec_n), .ciin_n(ciin_n), .cback_n(cback_n), .br_n(br_n), .bgack_n(bgack_n),
	.bg_n_o(bg_n_o), .bus_granted(bus_granted)
);

//---------------------------------------------------------------------------
// bus slot ownership
//---------------------------------------------------------------------------
localparam OWN_NONE = 2'd0, OWN_WALK = 2'd1, OWN_WB = 2'd2, OWN_DU = 2'd3;
reg  [1:0] owner;
reg        own_ifetch;
// the slot is free for a new request this clock
wire slot_free = (owner == OWN_NONE) && !b_req && !b_busy;

//---------------------------------------------------------------------------
// data unit
//---------------------------------------------------------------------------
localparam DS_IDLE   = 4'd0;   // also the lookup clock of the first portion
localparam DS_LOOKUP = 4'd1;   // lookup of a later portion, or a retry after a walk
localparam DS_WALK   = 4'd2;
localparam DS_HIT    = 4'd3;   // cache data valid this clock
localparam DS_BUSREQ = 4'd4;   // waiting for the bus slot
localparam DS_BUSWAIT= 4'd5;
localparam DS_WBWAIT = 4'd6;   // waiting for the write buffer
localparam DS_RMW    = 4'd7;   // RMW write in flight
localparam DS_FLTWAIT= 4'd8;   // a later portion faulted: the first one is still written

reg  [3:0] ds;
reg [31:0] r_addr;       // current portion address (logical)
reg  [2:0] r_rem;        // operand bytes remaining
reg  [2:0] r_pn;         // bytes in the current portion
reg [31:0] r_data;       // assembled read data / remaining write data (right justified)
reg  [2:0] r_got;        // read bytes obtained so far
reg        r_ocs;        // OCS still to be asserted for this operand
reg        r_first;
reg        r_cross_line;
// write buffer
reg        wb_valid;
reg        wb_stage;     // 0: portion 1 pending, 1: portion 2 pending
reg [31:0] wb_pa0, wb_pa1, wb_la0, wb_la1;
reg        wb_ci0, wb_ci1;
reg  [2:0] wb_n0, wb_n1, wb_total;
reg [31:0] wb_data;
reg  [2:0] wb_fc;
reg        wb_rmc, wb_rmc_last;
reg        wb_two;
reg        wb_posted;
reg        wb_err_seen;

wire [2:0] d_bytes  = (d_size == `SZ_B) ? 3'd1 : (d_size == `SZ_W) ? 3'd2 : (d_size == `SZ_3) ? 3'd3 : 3'd4;
wire [2:0] d_to_end = 3'd4 - {1'b0, d_addr[1:0]};
wire [2:0] d_p1     = (d_bytes < d_to_end) ? d_bytes : d_to_end;

// UM 6.1.3.2: while a burst is still filling a line, the next access waits
// for it (its entries are on their way and a write must not race a fill)
// (a fill is applied one clock after the controller reports it, and the
// tags are visible one clock later still)
wire        dburst_busy = ((owner == OWN_DU) && !own_ifetch && (b_busy || b_fill_stb)) || dc_fi_we;
wire        iburst_busy = ((owner == OWN_DU) && own_ifetch && (b_busy || b_fill_stb)) || ic_fi_we;
reg         d_pend, i_pend;    // a strobe seen while the unit was busy
reg  [31:0] ip_addr;           // the pending fetch (looked up after the one in flight)
reg   [2:0] ip_fc;
wire        d_go = d_stb | d_pend;
wire        i_go = i_stb | i_pend;
wire [31:0] i_req_addr = i_pend ? ip_addr : i_addr;   // the pending request goes first
wire  [2:0] i_req_fc   = i_pend ? ip_fc : i_fc;
// a new write cannot be looked up while the write buffer still holds the
// previous one (its record would be overwritten before the bus took it)
// the buffer takes a new record when it is empty, or in the clock its last
// portion completes without error (the next write posts without a gap)
wire        wb_done_ok = (owner == OWN_WB) && b_done && !b_berr && !(!wb_stage && wb_two);
wire        wb_free    = !wb_valid || wb_done_ok;
// the controller can take a request now (the owner register lags a clock
// behind the end of a transfer)
wire        bus_free_now = !b_busy && !b_req && !w_req && !walker_busy;
wire        wr_stall = (ds == DS_IDLE) && d_go && !d_rw && !wb_free;
// the portion being looked up this clock
wire        lk_first = (ds == DS_IDLE);
wire        lk_act   = (((ds == DS_IDLE) && d_go) || (ds == DS_LOOKUP)) && !dburst_busy && !wr_stall;
wire [31:0] c_addr   = lk_first ? d_addr  : r_addr;
wire  [2:0] c_rem    = lk_first ? d_bytes : r_rem;
wire  [2:0] c_pn     = lk_first ? d_p1    : r_pn;
wire [31:0] c_data   = lk_first ? d_wdata : r_data;
wire        c_cross  = lk_first ? ((d_p1 < d_bytes) && (d_addr[3:2] == 2'b11)) : r_cross_line;
wire        c_ocs    = lk_first ? 1'b1 : r_ocs;

function [1:0] siz_of;
	input [2:0] n;
	begin
		case (n)
			3'd1: siz_of = `SIZ_BYTE;
			3'd2: siz_of = `SIZ_WORD;
			3'd3: siz_of = `SIZ_3BYTE;
			default: siz_of = `SIZ_LONG;
		endcase
	end
endfunction

function [3:0] be_of;      // byte enables of a portion, bit 3 = D31-D24 lane
	input [1:0] off; input [2:0] n;
	begin
		be_of = (4'b1111 << (3'd4 - n)) >> off;
	end
endfunction

function [31:0] extract;   // bytes off..off+n-1 of an entry, right justified
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

// lane image of the current write portion: its bytes are the top c_pn of
// the remaining c_rem bytes
wire [31:0] wr_lane_img = (c_data << (8 * (3'd4 - c_rem))) >> (8 * c_addr[1:0]);
wire        cachable_space = (d_fc != `FC_CPU_SPACE);
wire        d_nopost = d_rmc || (d_fc == `FC_CPU_SPACE);

// prefetch side
localparam IS_IDLE = 3'd0, IS_LOOKUP = 3'd1, IS_WALK = 3'd2, IS_HIT = 3'd3, IS_BUSREQ = 3'd4, IS_BUSWAIT = 3'd5;
reg  [2:0] is;
reg [31:0] ir_addr;
reg  [2:0] ir_fc;
reg [31:0] ir_pa;
reg        ir_ci, ir_tag_hit, ir_line_empty;
// a fresh lookup starts from the idle state or while a hit is delivered
// (hits pipeline: one lookup per clock)
wire        ilk_first = (is == IS_IDLE) || (is == IS_HIT);
wire        ilk_act   = ((ilk_first && i_go) || (is == IS_LOOKUP)) && !iburst_busy;
// the pending slot is free after this clock: nothing waits, or the waiting
// request is taken up now and no new one arrives
wire        i_consume = ilk_act && ilk_first;
wire        i_pend_after = i_pend ? (i_stb || !i_consume) : (i_stb && !i_consume);
assign      i_ready = !i_pend_after;
// acknowledges: registered for bus transfers and writes, combinational in
// the clock a cache hit's data is valid (a two-clock read, UM 11.2)
reg         d_ack_r, i_ack_r;
reg  [31:0] d_rdata_r, i_data_r;
wire        d_hit_done = (ds == DS_HIT) && (r_pn == r_rem);
assign      d_ack   = d_ack_r | d_hit_done;
assign      d_rdata = d_hit_done ? ((r_data << (8 * r_pn)) | extract(dc_data, r_addr[1:0], r_pn)) : d_rdata_r;
assign      i_ack   = i_ack_r | (is == IS_HIT);
assign      i_data  = (is == IS_HIT) ? ic_data : i_data_r;
wire [31:0] ci_addr   = ilk_first ? {i_req_addr[31:2], 2'b00} : ir_addr;
wire  [2:0] ci_fc     = ilk_first ? i_req_fc : ir_fc;
// the data side owns the MMU port whenever it looks up
wire du_lookup = lk_act;
wire if_lookup = ilk_act && !du_lookup;

always @* begin
	if (du_lookup) begin
		tr_la = c_addr; tr_fc = d_fc; tr_rw = d_rw; tr_rmc = d_rmc && !d_iack;
	end else begin
		tr_la = ci_addr; tr_fc = ci_fc; tr_rw = 1'b1; tr_rmc = 1'b0;
	end
	dc_lk_la = c_addr; dc_lk_fc = d_fc;
	ic_lk_la = ci_addr; ic_lk_fc = ci_fc;
end

assign d_wpend   = wb_valid;
assign bus_quiet = !wb_valid && b_idle && !walker_busy;

// a read cache hit needs no translation unless the ATC entry says the page
// is bad (UM 9.2.1: hit with the B bit set aborts the access)
wire rd_hit_ok = d_rw && !d_rmc && !d_iack && !d_nocache && dc_en && dc_hit && cachable_space && !tr_fault;

reg [31:0] r_pa_hold;
reg        r_ci_hold, r_tag_hit, r_line_empty;
reg w_ack_pending, w_active_d;

always @(posedge clk) begin
	// pulses
	d_ack_r <= 1'b0; d_fault <= 1'b0; d_avec <= 1'b0; d_iack_berr <= 1'b0; d_late_fault <= 1'b0;
	i_ack_r <= 1'b0; i_fault <= 1'b0;
	dc_fi_we <= 1'b0; ic_fi_we <= 1'b0; dc_wr_we <= 1'b0; dc_inv_we <= 1'b0;
	walk_req <= 1'b0; tr_use <= 1'b0;
	w_ack <= 1'b0; b_rmc_release <= 1'b0;

	if (rst) begin
		ds <= DS_IDLE; is <= IS_IDLE; owner <= OWN_NONE; own_ifetch <= 1'b0;
		wb_valid <= 1'b0; wb_posted <= 1'b0; wb_err_seen <= 1'b0; wb_stage <= 1'b0; wb_two <= 1'b0;
		b_req <= 1'b0; b_kind <= 2'd0; b_addr <= 32'd0; b_nbytes <= 3'd0; b_total <= 3'd0; b_rw <= 1'b1;
		b_fc <= 3'd0; b_rmc <= 1'b0; b_rmc_last <= 1'b0; b_ciout <= 1'b0; b_cbreq <= 1'b0; b_ocs <= 1'b0;
		b_cache <= 1'b0; b_wdata <= 32'd0;
		r_addr <= 32'd0; r_rem <= 3'd0; r_pn <= 3'd0; r_data <= 32'd0; r_got <= 3'd0;
		r_ocs <= 1'b0; r_first <= 1'b1; r_cross_line <= 1'b0; d_pend <= 1'b0; i_pend <= 1'b0;
		ip_addr <= 32'd0; ip_fc <= 3'd0;
		ir_addr <= 32'd0; ir_fc <= 3'd0; ir_pa <= 32'd0; ir_ci <= 1'b0; ir_tag_hit <= 1'b0; ir_line_empty <= 1'b0;
		f_addr <= 32'd0; f_fc <= 3'd0; f_size <= 2'd0; f_rw <= 1'b1; f_rm <= 1'b0; f_dob <= 32'd0;
		walk_la <= 32'd0; walk_fc <= 3'd0; walk_rw <= 1'b1; walk_rmc <= 1'b0;
		f_got <= 3'd0; f_partial <= 32'd0;
		d_rdata_r <= 32'd0; i_data_r <= 32'd0;
		w_ack_pending <= 1'b0; w_active_d <= 1'b0; w_rdata <= 32'd0; w_berr <= 1'b0;
		wb_pa0 <= 32'd0; wb_pa1 <= 32'd0; wb_la0 <= 32'd0; wb_la1 <= 32'd0; wb_ci0 <= 1'b0; wb_ci1 <= 1'b0;
		wb_n0 <= 3'd0; wb_n1 <= 3'd0; wb_total <= 3'd0; wb_data <= 32'd0; wb_fc <= 3'd0;
		wb_rmc <= 1'b0; wb_rmc_last <= 1'b0;
	end else begin
		//------------------------------------------------------------ request handshake
		if (b_req && b_ack) b_req <= 1'b0;
		d_pend <= (ds == DS_IDLE) && d_go && (dburst_busy || wr_stall);
		// a fetch that cannot be looked up now waits in the pending slot; a
		// lookup from the idle state consumes the pending one first
		if (i_stb && !(ilk_act && ilk_first && !i_pend)) begin i_pend <= 1'b1; ip_addr <= i_addr; ip_fc <= i_fc; end
		else if (ilk_act && ilk_first && i_pend) i_pend <= 1'b0;
		if (d_rmc_release) b_rmc_release <= 1'b1;

		//------------------------------------------------------------ ownership release
		// a transfer (including its burst) is over when the controller is idle
		if (owner != OWN_NONE && !b_busy && !b_req) begin owner <= OWN_NONE; own_ifetch <= 1'b0; end

		//------------------------------------------------------------ table search accesses
		if (w_req && !w_ack_pending && slot_free) begin
			b_req <= 1'b1; b_kind <= `BK_TABLE; b_addr <= w_addr; b_nbytes <= 3'd4; b_total <= 3'd4;
			b_rw <= w_rw; b_fc <= `FC_SUPER_DATA; b_rmc <= 1'b1; b_rmc_last <= 1'b0; b_ciout <= 1'b0;
			b_cbreq <= 1'b0; b_ocs <= 1'b0; b_cache <= 1'b0; b_wdata <= w_wdata;
			owner <= OWN_WALK; own_ifetch <= 1'b0; w_ack_pending <= 1'b1;
		end
		if (owner == OWN_WALK && b_done) begin
			w_ack <= 1'b1; w_rdata <= b_rdata; w_berr <= b_berr;
		end
		if (!w_req) w_ack_pending <= 1'b0;
		w_active_d <= w_active;
		if (w_active_d && !w_active) b_rmc_release <= 1'b1;   // search over: RMC negated

		//------------------------------------------------------------ write buffer
		if (wb_valid && slot_free && !w_req && !walker_busy) begin
			b_req <= 1'b1; b_kind <= `BK_DATA;
			b_addr   <= wb_stage ? wb_pa1 : wb_pa0;
			b_nbytes <= wb_stage ? wb_n1 : wb_n0;
			b_total  <= wb_stage ? wb_n1 : wb_total;
			b_rw <= 1'b0; b_fc <= wb_fc; b_rmc <= wb_rmc;
			b_rmc_last <= wb_rmc_last && (wb_stage || !wb_two);
			b_ciout <= wb_stage ? wb_ci1 : wb_ci0;
			b_cbreq <= 1'b0; b_ocs <= !wb_stage; b_cache <= 1'b0;
			b_wdata <= wb_stage ? (wb_data & (32'hFFFF_FFFF >> (8 * (3'd4 - wb_n1)))) : wb_data;
			owner <= OWN_WB; own_ifetch <= 1'b0;
		end
		if (owner == OWN_WB && b_done) begin
			if (b_berr) begin
				// UM 8.2.1: the remaining part of the operand is described
				f_addr <= wb_stage ? wb_la1 : wb_la0;
				f_fc   <= wb_fc;
				f_size <= siz_of(wb_stage ? wb_n1 : wb_total);
				f_rw   <= 1'b0;
				f_rm   <= wb_rmc;
				f_dob  <= wb_stage ? (wb_data & (32'hFFFF_FFFF >> (8 * (3'd4 - wb_n1)))) : wb_data;
				f_got  <= 3'd0; f_partial <= 32'd0;
				if (wb_posted) d_late_fault <= 1'b1;
				wb_err_seen <= !wb_posted;
				wb_valid <= 1'b0;
			end else if (!wb_stage && wb_two) begin
				wb_stage <= 1'b1;
			end else begin
				wb_valid <= 1'b0;
			end
		end

		//------------------------------------------------------------ data unit
		case (ds)
			DS_IDLE, DS_LOOKUP: begin
				if (lk_act) begin
					r_addr <= c_addr; r_rem <= c_rem; r_pn <= c_pn; r_cross_line <= c_cross;
					if (lk_first) begin r_data <= d_wdata; r_got <= 3'd0; r_ocs <= 1'b1; r_first <= 1'b1; end
					if (d_iack) begin
						// CPU space: untranslated, never cached (UM 9.2.1)
						if (slot_free && !w_req && !walker_busy && !wb_valid) begin
							b_req <= 1'b1; b_kind <= `BK_IACK; b_addr <= c_addr; b_nbytes <= 3'd1; b_total <= 3'd1;
							b_rw <= 1'b1; b_fc <= d_fc; b_rmc <= 1'b0; b_rmc_last <= 1'b0; b_ciout <= 1'b0;
							b_cbreq <= 1'b0; b_ocs <= 1'b1; b_cache <= 1'b0; b_wdata <= 32'd0;
							owner <= OWN_DU; own_ifetch <= 1'b0;
							ds <= DS_BUSWAIT;
						end else ds <= DS_BUSREQ;
					end else if (rd_hit_ok) begin
						ds <= DS_HIT;
					end else if (tr_fault) begin
						if (!d_rw) begin dc_inv_we <= 1'b1; dc_inv_la <= c_addr; end
						f_addr <= c_addr; f_fc <= d_fc; f_size <= siz_of(c_rem); f_rw <= d_rw; f_rm <= d_rmc;
						f_dob <= d_rw ? 32'd0 : c_data;
						f_got <= lk_first ? 3'd0 : r_got; f_partial <= lk_first ? 32'd0 : r_data;
						if (!d_rw && !lk_first && !r_first) begin
							// the first portion was validated: its cycle runs as on
							// the real part, the frame describes the rest (UM 8.2.1)
							wb_two <= 1'b0;
							if (!wb_valid) begin
								wb_valid <= 1'b1; wb_stage <= 1'b0; wb_posted <= 1'b1; wb_err_seen <= 1'b0;
								d_fault <= 1'b1; ds <= DS_IDLE;
							end else ds <= DS_FLTWAIT;
						end else begin
							d_fault <= 1'b1;
							ds <= DS_IDLE;
						end
					end else if (tr_walk) begin
						// the search runs after the writes already posted (a
						// descriptor may just have been written)
						if (!walker_busy && !wb_valid) begin
							walk_req <= 1'b1; walk_la <= tr_la; walk_fc <= tr_fc; walk_rw <= tr_rw; walk_rmc <= tr_rmc;
							ds <= DS_WALK;
						end else ds <= DS_LOOKUP;
					end else begin
						tr_use <= 1'b1;
						if (!d_rw) begin
							// write: cache first (write-through), then the buffer
							if (dc_en && !tr_ci && cachable_space) begin
								dc_wr_we <= 1'b1; dc_wr_la <= c_addr; dc_wr_fc <= d_fc;
								dc_wr_be <= be_of(c_addr[1:0], c_pn); dc_wr_data <= wr_lane_img;
							end
							if (lk_first || r_first) begin
								// first portion (also after a table search)
								wb_pa0 <= tr_pa; wb_la0 <= c_addr; wb_ci0 <= tr_ci; wb_n0 <= c_pn;
								wb_total <= c_rem; wb_data <= c_data; wb_fc <= d_fc; wb_rmc <= d_rmc;
								wb_rmc_last <= d_rmc_last; wb_two <= (c_pn != c_rem);
							end else begin
								wb_pa1 <= tr_pa; wb_la1 <= c_addr; wb_ci1 <= tr_ci; wb_n1 <= c_pn;
							end
							if (c_pn != c_rem) begin
								r_addr <= {c_addr[31:2], 2'b00} + 32'd4;
								r_rem  <= c_rem - c_pn;
								r_pn   <= c_rem - c_pn;
								r_first <= 1'b0;
								ds <= DS_LOOKUP;
							end else if (wb_free) begin
								// post now; RMW and CPU-space writes complete first
								// (UM 10.5.2.8: a bus error on a coprocessor access is seen)
								wb_valid <= 1'b1; wb_stage <= 1'b0; wb_posted <= !d_nopost; wb_err_seen <= 1'b0;
								if (bus_free_now) begin
									// straight to the bus; the record stays for the completion
									b_req <= 1'b1; b_kind <= `BK_DATA;
									b_addr   <= (lk_first || r_first) ? tr_pa : wb_pa0;
									b_nbytes <= (lk_first || r_first) ? c_pn : wb_n0;
									b_total  <= (lk_first || r_first) ? c_rem : wb_total;
									b_rw <= 1'b0; b_fc <= d_fc; b_rmc <= d_rmc;
									b_rmc_last <= d_rmc_last && (lk_first || r_first);   // of two portions the first is not last
									b_ciout <= (lk_first || r_first) ? tr_ci : wb_ci0;
									b_cbreq <= 1'b0; b_ocs <= 1'b1; b_cache <= 1'b0;
									b_wdata <= (lk_first || r_first) ? c_data : wb_data;
									owner <= OWN_WB; own_ifetch <= 1'b0;
								end
								if (d_nopost) ds <= DS_RMW;
								else begin d_ack_r <= 1'b1;  ds <= DS_IDLE; end
							end else ds <= DS_WBWAIT;
						end else begin
							// read miss: to the bus
							if (slot_free && !w_req && !walker_busy && !wb_valid) begin
								b_req <= 1'b1; b_kind <= `BK_DATA;
								b_addr <= tr_pa; b_nbytes <= c_pn; b_total <= c_rem;
								b_rw <= 1'b1; b_fc <= d_fc; b_rmc <= d_rmc; b_rmc_last <= 1'b0;
								b_ciout <= tr_ci; b_ocs <= c_ocs;
								b_cache <= dc_fill_ok && !tr_ci && cachable_space && !d_rmc && !d_nocache;
								b_cbreq <= dc_fill_ok && cacr[`CACR_DBE] && !tr_ci && cachable_space && !d_rmc && !d_nocache &&
								           (!dc_tag_hit || dc_line_empty) && !((lk_first || r_first) && c_cross);
								b_wdata <= 32'd0;
								r_ocs <= 1'b0;
								owner <= OWN_DU; own_ifetch <= 1'b0;
								ds <= DS_BUSWAIT;
							end else begin
								r_pa_hold <= tr_pa; r_ci_hold <= tr_ci;
								r_tag_hit <= dc_tag_hit; r_line_empty <= dc_line_empty;
								ds <= DS_BUSREQ;
							end
						end
					end
				end
			end

			DS_WALK: begin
				if (walk_done) ds <= DS_LOOKUP;
			end

			DS_HIT: begin
				// cache data valid this clock (UM 11.2: two-clock read)
				if (r_pn != r_rem) begin
					r_data <= (r_data << (8 * r_pn)) | extract(dc_data, r_addr[1:0], r_pn);
					r_got  <= r_got + r_pn;
					r_addr <= {r_addr[31:2], 2'b00} + 32'd4;
					r_rem  <= r_rem - r_pn;
					r_pn   <= r_rem - r_pn;
					r_first <= 1'b0;
					ds <= DS_LOOKUP;
				end else begin
					// the last portion: delivered in this clock (d_hit_done)
					ds <= DS_IDLE;
				end
			end

			DS_BUSREQ: begin
				if (slot_free && !w_req && !walker_busy && !wb_valid) begin
					b_req <= 1'b1; b_kind <= d_iack ? `BK_IACK : `BK_DATA;
					b_addr <= d_iack ? r_addr : r_pa_hold; b_nbytes <= r_pn; b_total <= r_rem;
					b_rw <= 1'b1; b_fc <= d_fc; b_rmc <= d_rmc && !d_iack; b_rmc_last <= 1'b0;
					b_ciout <= r_ci_hold && !d_iack; b_ocs <= r_ocs;
					b_cache <= dc_fill_ok && !r_ci_hold && cachable_space && !d_rmc && !d_iack && !d_nocache;
					b_cbreq <= dc_fill_ok && cacr[`CACR_DBE] && !r_ci_hold && cachable_space && !d_rmc && !d_iack && !d_nocache &&
					           (!r_tag_hit || r_line_empty) && !(r_first && r_cross_line);
					b_wdata <= 32'd0;
					r_ocs <= 1'b0;
					owner <= OWN_DU; own_ifetch <= 1'b0;
					ds <= DS_BUSWAIT;
				end
			end

			DS_BUSWAIT: begin
				if (b_done) begin
					if (d_iack) begin
						if (b_berr) d_iack_berr <= 1'b1;
						else begin d_ack_r <= 1'b1; d_avec <= b_avec; d_rdata_r <= {24'd0, b_rdata[7:0]}; end
						
						ds <= DS_IDLE;
					end else if (b_berr) begin
						f_addr <= r_addr; f_fc <= d_fc; f_size <= siz_of(r_rem); f_rw <= 1'b1; f_rm <= d_rmc;
						f_dob <= 32'd0; f_got <= r_got; f_partial <= r_data;
						d_fault <= 1'b1; 
						ds <= DS_IDLE;
					end else if (r_pn != r_rem) begin
						r_data <= (r_data << (8 * r_pn)) | b_rdata;
						r_got  <= r_got + r_pn;
						r_addr <= {r_addr[31:2], 2'b00} + 32'd4;
						r_rem  <= r_rem - r_pn;
						r_pn   <= r_rem - r_pn;
						r_first <= 1'b0;
						ds <= DS_LOOKUP;
					end else begin
						d_ack_r <= 1'b1; 
						d_rdata_r <= (r_data << (8 * r_pn)) | b_rdata;
						ds <= DS_IDLE;
					end
				end
			end

			DS_WBWAIT: begin
				if (wb_free) begin
					wb_valid <= 1'b1; wb_stage <= 1'b0; wb_posted <= !d_nopost; wb_err_seen <= 1'b0;
					if (bus_free_now) begin
						b_req <= 1'b1; b_kind <= `BK_DATA;
						b_addr <= wb_pa0; b_nbytes <= wb_n0; b_total <= wb_total;
						b_rw <= 1'b0; b_fc <= wb_fc; b_rmc <= wb_rmc; b_rmc_last <= wb_rmc_last && !wb_two;
						b_ciout <= wb_ci0; b_cbreq <= 1'b0; b_ocs <= 1'b1; b_cache <= 1'b0; b_wdata <= wb_data;
						owner <= OWN_WB; own_ifetch <= 1'b0;
					end
					if (d_nopost) ds <= DS_RMW;
					else begin d_ack_r <= 1'b1;  ds <= DS_IDLE; end
				end
			end

			DS_FLTWAIT: begin
				if (wb_free) begin
					wb_valid <= 1'b1; wb_stage <= 1'b0; wb_posted <= 1'b1; wb_err_seen <= 1'b0;
					d_fault <= 1'b1; ds <= DS_IDLE;
				end
			end

			DS_RMW: begin
				// RMW writes are not posted: report completion or the fault
				if (!wb_valid) begin
					if (wb_err_seen) d_fault <= 1'b1; else d_ack_r <= 1'b1;
					wb_err_seen <= 1'b0;
					
					ds <= DS_IDLE;
				end
			end
			default: ds <= DS_IDLE;
		endcase

		// data cache fills (the transfer is the data unit's)
		if (b_fill_stb && owner == OWN_DU && !own_ifetch && dc_fill_ok) begin
			dc_fi_we <= 1'b1; dc_fi_addr <= {r_addr[31:4], b_fill_addr[3:2]}; dc_fi_fc <= d_fc; dc_fi_data <= b_fill_data;
		end

		//------------------------------------------------------------ instruction port
		case (is)
			IS_IDLE, IS_LOOKUP, IS_HIT: begin
				if (is == IS_HIT) begin
					// the previous lookup hit: delivered in this clock (i_ack) while
					// the next one starts
					if (!ilk_act) is <= IS_IDLE;
				end
				if (ilk_act) begin
					ir_addr <= ci_addr; ir_fc <= ci_fc;
					if (ic_en && ic_hit) begin
						is <= IS_HIT;
					end else if (if_lookup) begin
						ir_tag_hit <= ic_tag_hit; ir_line_empty <= ic_line_empty;
						if (tr_fault) begin
							i_fault <= 1'b1;  is <= IS_IDLE;
						end else if (tr_walk) begin
							if (!walker_busy && !wb_valid) begin
								walk_req <= 1'b1; walk_la <= tr_la; walk_fc <= tr_fc; walk_rw <= 1'b1; walk_rmc <= 1'b0;
								is <= IS_WALK;
							end else is <= IS_LOOKUP;
						end else begin
							tr_use <= 1'b1;
							ir_pa <= tr_pa; ir_ci <= tr_ci;
							is <= IS_BUSREQ;
						end
					end else is <= IS_LOOKUP;
				end
			end
			IS_WALK: begin
				if (walk_done) is <= IS_LOOKUP;
			end
			IS_BUSREQ: begin
				// lowest priority
				if (slot_free && !w_req && !walker_busy && !wb_valid && !lk_act && ds != DS_BUSREQ) begin
					b_req <= 1'b1; b_kind <= `BK_DATA;
					b_addr <= ir_pa; b_nbytes <= 3'd4; b_total <= 3'd4;
					b_rw <= 1'b1; b_fc <= ir_fc; b_rmc <= 1'b0; b_rmc_last <= 1'b0;
					b_ciout <= ir_ci; b_ocs <= 1'b1;
					b_cache <= ic_fill_ok && !ir_ci;
					b_cbreq <= ic_fill_ok && cacr[`CACR_IBE] && !ir_ci && (!ir_tag_hit || ir_line_empty);
					b_wdata <= 32'd0;
					owner <= OWN_DU; own_ifetch <= 1'b1;
					is <= IS_BUSWAIT;
				end
			end
			IS_BUSWAIT: begin
				if (b_done) begin
					if (b_berr) i_fault <= 1'b1;
					else begin i_ack_r <= 1'b1; i_data_r <= b_rdata; end
					
					is <= IS_IDLE;
				end
			end
			default: is <= IS_IDLE;
		endcase
		if (b_fill_stb && owner == OWN_DU && own_ifetch && ic_fill_ok) begin
			ic_fi_we <= 1'b1; ic_fi_addr <= {ir_addr[31:4], b_fill_addr[3:2]}; ic_fi_fc <= ir_fc; ic_fi_data <= b_fill_data;
		end
	end
end


endmodule
