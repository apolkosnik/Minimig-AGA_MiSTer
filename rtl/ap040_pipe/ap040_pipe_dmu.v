//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (2026-09-25)                   //
//                                                                          //
// ap040_pipe_dmu.v - the data memory unit                                  //
//                                                                          //
// Between EA-fetch's port B and the bus controller (ap040_pipe_membus.v),  //
// as the MC68040's DMU sits between its operand accesses and its bus       //
// controller (MC68040UM Figure 4-1): operand addresses are translated here //
// by ap040_pipe_mmu.v's data port, and only physical addresses go on.      //
// Stage A of doc_AP040_PIPELINE_CACHES.md -- translation only; the data    //
// cache joins this unit in stage C.                                        //
//                                                                          //
// Toward the CPU this is the bus controller's port-B protocol exactly,     //
// which the bus controller implemented while the MMU sat below it: one     //
// read at a time, returned with a valid that holds as a level; writes      //
// posted; a write that translation can refuse (the CPU's l1_wr_sync: TC.E  //
// or a data TTR enabled) is TENTATIVE -- held busy until it passes,        //
// accepted in the cycle wr_busy drops, the refusal a level until the CPU   //
// has let go (c_wr_drop), and the acceptance kept across a cycle the CPU   //
// was not looking (review 16's receipt). Those rules move here with the    //
// translation; the bus controller sees only writes that have passed, and   //
// reports only physical bus errors.                                        //
//                                                                          //
// Translated from registers. The CPU's port-B address settles late in its  //
// cycle, from EA-fetch's stalls; an ATC compare and a physical address     //
// after it do not fit in 25 ns (the first draft, which translated in the   //
// request's own cycle, fitted at -5.3 ns). So with translation able to     //
// refuse (xlat), a request is latched as it arrives and translated from    //
// the latch, and every signal toward the CPU and the MMU comes from        //
// registers: a read goes to the bus controller the cycle after it is       //
// asked for, through its translated-read input (rx_*), which puts it on   //
// the bus in that cycle -- the bus controller's own timing, which took a   //
// read the cycle it came and put it on the bus the next; a write is        //
// accepted the cycle after its translation passes -- a cycle after it is   //
// taken when the MMU's most recent hit covers it, two when its lookup     //
// runs, as the bus controller accepted it. Untranslated (xlat low), reads  //
// and writes go straight through, as they did.                             //
//                                                                          //
// Ordering. A write accepted here goes to the bus controller before any    //
// read that arrives after it: a read waits while the write slot holds      //
// anything, and the bus controller sends the writes it holds before the    //
// reads.                                                                   //
//                                                                          //
// The MMU's data port is held by whoever raised it -- the slot or the read //
// -- at the same address until it passes or faults: a walk cannot be       //
// recalled, and its fault belongs to the access it was for. After a fault  //
// the port is left down for a cycle, which is what the walker waits for    //
// (ap040_pipe_mmu.v's W_DROP).                                             //
//                                                                          //
// Transfers that cross a page with translation on: the two pages are       //
// translated separately and the transfer goes out a byte at a time, each   //
// byte to its own page's physical address, a read's bytes assembled here;  //
// a fault on the second page reports MA. A crossing write is first CHECKED //
// on both pages (the MMU's access check: no M history), so a refused write //
// has written nothing and marked nothing -- as the bus controller's PTEST  //
// probes guaranteed -- then translated for real on each page, which sets   //
// M, and only then accepted and its bytes posted. Every table search a     //
// write needs is thereby over before it is accepted, and the walker never  //
// runs while an accepted write has still to reach memory (wr_pend).        //
//                                                                          //
// MOVES spaces (MC68040UM 3.2, Table 3-2; stage A2). $0, $3, $4 and $7 are //
// alternate address spaces: the address is physical, used without          //
// translation -- no ATC lookup, no search, no protection, no MMU fault --   //
// and not split at a page. $2 and $6 are converted to the data spaces $1   //
// and $5: translated as any data access, and on the bus as data (the bus   //
// controller converts what it is given; this unit its translated reads).  //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_dmu
(
	input             clk,
	input             nreset,

	input             xlat,        // translation can refuse a data write (l1_wr_sync)
	input             tc_e,
	input             tc_p,

	// ---- EA-fetch (port B) ----
	input      [31:0] c_addr,
	input             c_rd,
	input             c_wr,
	input       [1:0] c_size,
	input      [31:0] c_wdata,
	input             c_sup,
	input             c_fc_ovr,
	input       [2:0] c_fc_val,
	input             c_wr_drop,
	output     [31:0] c_q,
	output            c_rvalid,
	output            c_wr_busy_w,
	output            c_rflt,
	output            c_wflt,
	output            c_flt_bus,
	output            c_flt_ma,
	output            c_idle,
	// A write accepted here has not reached memory yet: the table walker
	// must not read around it (ap040_pipe_mmu.v's walk_hold).
	output            wr_pend,

	// ---- ap040_pipe_mmu.v's data port ----
	output            d_req,
	output            d_write,
	output            d_acc,
	output     [31:0] d_addr,
	output            d_sup,
	input             d_pass,
	input             d_flt,
	input      [31:0] d_pa,

	// ---- the bus controller's port B (physical) ----
	// writes, and reads untranslated
	output     [31:0] m_addr,
	output            m_rd,
	output            m_wr,
	output      [1:0] m_size,
	output     [31:0] m_wdata,
	output            m_sup,
	output            m_fc_ovr,
	output      [2:0] m_fc_val,
	// the logical address of the write on m_wr: the bus controller's
	// prefetch window is logical, and snoops writes by it
	output     [31:0] m_la,
	// translated reads, from registers
	output            m_rx,
	output     [31:0] m_rx_addr,
	output      [1:0] m_rx_size,
	output      [2:0] m_rx_fc,
	input      [31:0] m_q,
	input             m_rvalid,
	input             m_wr_busy_w,
	input             m_rflt,
	input             m_flt_bus,
	input             m_flt_ma,
	input             m_idle
);

// Page geometry, and whether a transfer crosses out of its page
// (ap040_pipe_membus.v's).
wire [12:0] pg_mask   = tc_p ? 13'h1FFF : 13'h0FFF;
wire [31:0] pg_mask32 = {19'd0, pg_mask};
function crosses;
	input [31:0] a;
	input  [1:0] sz;
	input [12:0] mask;
	begin
		crosses = ({1'b0, a[12:0] & mask} + ((sz == `AP040_SZ_L) ? 14'd4 : (sz == `AP040_SZ_W) ? 14'd2 : 14'd1)) >
		          ({1'b0, mask} + 14'd1);
	end
endfunction
function [1:0] last_of;   // the transfer's last byte index
	input [1:0] sz;
	begin
		last_of = (sz == `AP040_SZ_L) ? 2'd3 : (sz == `AP040_SZ_W) ? 2'd1 : 2'd0;
	end
endfunction
// An access's privilege: its function code's, as the MMU has always taken it.
function sup_of;
	input       ovr;
	input [2:0] fcv;
	input       sup;
	begin
		sup_of = ovr ? fcv[2] : sup;
	end
endfunction
// MOVES to an alternate space: physical, untranslated.
function alt_of;
	input       ovr;
	input [2:0] fcv;
	begin
		alt_of = ovr && ((fcv[1:0] == 2'b00) || (fcv[1:0] == 2'b11));
	end
endfunction
// The function code on the bus: MOVES to program space is a data reference.
function [2:0] fc_bus;
	input [2:0] fcv;
	begin
		fc_bus = (fcv[1:0] == 2'b10) ? {fcv[2], 2'b01} : fcv;
	end
endfunction
wire c_alt = alt_of(c_fc_ovr, c_fc_val);

//---------------------------------------------------------------------------
// the write slot (translation can refuse writes)
//---------------------------------------------------------------------------

localparam [2:0] WS_FREE = 3'd0,   // empty
                 WS_CHK1 = 3'd1,   // translating (crossing: checking page 1)
                 WS_CHK2 = 3'd2,   // crossing: checking page 2
                 WS_T1   = 3'd3,   // crossing: translating page 1 for real (sets M)
                 WS_T2   = 3'd4,   // crossing: translating page 2 for real (sets M)
                 WS_POST = 3'd5;   // translated: to the bus controller
reg  [2:0] ws;
reg [31:0] w_la, w_data;
reg  [1:0] w_size;
reg        w_sup, w_ovr;
reg  [2:0] w_fcv;
reg [31:0] w_pa1, w_pa2;        // physical: the address (w_x: page 1's base), page 2's base
reg  [1:0] w_bi, w_last;
reg        w_block;             // a tentative write was refused: take none until the CPU lets go
reg        w_receipt;           // accepted while the CPU was not looking
reg        w_acc;               // accepted this cycle: its translation passed last cycle
wire       w_slot  = (ws != WS_FREE);
// Crosses a page: from the latched address, not the CPU's (which settles late
// in its cycle). TC cannot change while the slot holds a write: a MOVEC to it
// waits for the memory side to be idle.
wire       w_x     = tc_e && !alt_of(w_ovr, w_fcv) && crosses(w_la, w_size, pg_mask);
wire [31:0] w_pg2  = (w_la | pg_mask32) + 32'd1;
wire       w_wants = (ws == WS_CHK1) || (ws == WS_CHK2) || (ws == WS_T1) || (ws == WS_T2);
// Taken into the slot as it arrives, and translated from there.
wire       w_take  = xlat && c_wr && !w_slot && !w_block && !w_receipt;
// Untranslated, straight to the bus controller -- unless the slot still
// holds a write from before translation was turned off.
wire       w_thru  = !xlat && c_wr && !w_slot;

//---------------------------------------------------------------------------
// the read
//---------------------------------------------------------------------------

localparam [2:0] RS_IDLE = 3'd0,   // nothing outstanding here
                 RS_XL   = 3'd1,   // translating (crossing: page 1)
                 RS_XL2  = 3'd2,   // crossing: translating page 2
                 RS_RDY  = 3'd3,   // translated, waiting for the slot to empty
                 RS_BYTE = 3'd4;   // crossing: its bytes, one read each
reg  [2:0] rs;
reg [31:0] r_la;
reg  [1:0] r_size;
reg        r_sup, r_ovr;
reg  [2:0] r_fcv;
reg [31:0] r_pa1, r_pa2;
reg  [1:0] r_bi, r_last;
reg [23:0] r_acc;               // a crossing read's bytes so far, right-aligned
reg        r_wait;              // a byte's read is with the bus controller
// The answer: the bus controller's, or this unit's own (a fault, or a
// crossing read's assembled bytes).
reg        own;
reg        own_v, own_flt;
reg [31:0] own_q;
// The last fault's kind, from whichever unit raised it.
reg        fsrc;                // 1: this unit's registers, 0: the bus controller's
reg        flt_bus_r, flt_ma_r;

// Untranslated, straight to the bus controller; otherwise latched here.
wire        r_thru  = !xlat && c_rd && (rs == RS_IDLE) && !w_slot;
wire        r_new   = c_rd && (rs == RS_IDLE) && !r_thru;
// As w_x; an alternate-space read never consults it (it goes from the
// latch straight to RS_RDY, whole).
wire        r_x     = tc_e && crosses(r_la, r_size, pg_mask);
wire        r_wants = (rs == RS_XL) || (rs == RS_XL2);
wire [31:0] r_xaddr = (rs == RS_XL2) ? ((r_la | pg_mask32) + 32'd1) : r_la;

//---------------------------------------------------------------------------
// the MMU's data port: registers only
//---------------------------------------------------------------------------

reg  d_hw, d_hr;                // left raised for the slot / the read, unanswered
reg  d_gap;                     // the cycle after a fault: nothing raised
wire w_on = w_wants && !d_hr && !d_gap;
wire r_on = r_wants && !d_hw && !d_gap && !w_on;

assign d_req   = w_on || r_on;
assign d_write = w_on;
assign d_acc   = w_on && w_x && ((ws == WS_CHK1) || (ws == WS_CHK2));
assign d_addr  = w_on ? (((ws == WS_CHK2) || (ws == WS_T2)) ? w_pg2 : w_la) : r_xaddr;
assign d_sup   = w_on ? w_sup : r_sup;

wire w_pass = w_on && d_pass;
wire w_flt  = w_on && d_flt;
wire r_pass = r_on && d_pass;
wire r_flt  = r_on && d_flt;

// Accepted -- wr_busy low -- the cycle after its translation (crossing: its
// second page's) passes.
// An alternate-space write needs no translation: accepted as it is taken.
wire w_passed = (w_take && c_alt) || (w_pass && (((ws == WS_CHK1) && !w_x) || (ws == WS_T2)));

//---------------------------------------------------------------------------
// the bus controller's port B
//---------------------------------------------------------------------------

// The slot's write, or its bytes.
wire  [1:0] w_bk      = w_last - w_bi;              // byte k of the operand, from the top
wire  [7:0] w_byte    = w_data[{w_bk, 3'b000} +: 8];
wire [31:0] w_byte_la = w_la + {30'd0, w_bi};
wire        w_byte_p2 = (w_byte_la & ~pg_mask32) != (w_la & ~pg_mask32);
wire [31:0] w_byte_pa = (w_byte_p2 ? w_pa2 : w_pa1) | (w_byte_la & pg_mask32);
wire        s_post    = (ws == WS_POST) && !m_wr_busy_w;

// A translated read goes only when nothing older is here: the slot empty.
// (A write the CPU presents in the same cycle is not older than a read
// already waiting here -- port B asks one thing at a time, and a read
// outstanding is answered before its instruction's own writes -- and it
// goes into the slot, or to the bus controller's write input: never onto
// rx's.)
wire        r_go      = !w_slot;
wire        r_send_x  = r_pass && (rs == RS_XL) && !r_x && r_go;   // straight on its translation
wire        r_send_q  = (rs == RS_RDY) && r_go;                    // translated earlier
wire [31:0] r_byte_la = r_la + {30'd0, r_bi};
wire        r_byte_p2 = (r_byte_la & ~pg_mask32) != (r_la & ~pg_mask32);
wire [31:0] r_byte_pa = (r_byte_p2 ? r_pa2 : r_pa1) | (r_byte_la & pg_mask32);
wire        r_issue   = (rs == RS_BYTE) && !r_wait && r_go;

// Writes and untranslated reads: the CPU's own, or the slot's.
assign m_wr     = s_post || w_thru;
assign m_rd     = r_thru;
assign m_addr   = s_post ? (w_x ? w_byte_pa : w_pa1) : c_addr;
assign m_la     = s_post ? (w_x ? w_byte_la : w_la) : c_addr;
assign m_size   = s_post ? (w_x ? `AP040_SZ_B : w_size) : c_size;
assign m_wdata  = s_post ? (w_x ? {24'd0, w_byte} : w_data) : c_wdata;
assign m_sup    = s_post ? w_sup : c_sup;
assign m_fc_ovr = s_post ? w_ovr : c_fc_ovr;
assign m_fc_val = s_post ? w_fcv : c_fc_val;
// Translated reads.
assign m_rx      = r_send_x || r_send_q || r_issue;
assign m_rx_addr = r_send_x ? d_pa : r_send_q ? r_pa1 : r_byte_pa;
assign m_rx_size = r_issue ? `AP040_SZ_B : r_size;
assign m_rx_fc   = r_ovr ? fc_bus(r_fcv) : {r_sup, 2'b01};

//---------------------------------------------------------------------------
// toward the CPU: registers, and the bus controller's registered answers
//---------------------------------------------------------------------------

assign c_q         = own ? own_q   : m_q;
assign c_rvalid    = own ? own_v   : m_rvalid;
assign c_rflt      = own ? own_flt : m_rflt;
assign c_wflt      = w_block;
assign c_flt_bus   = fsrc ? flt_bus_r : m_flt_bus;
assign c_flt_ma    = fsrc ? flt_ma_r  : m_flt_ma;
// As the bus controller's: busy from the cycle a tentative write first
// appears until it is accepted, free that one cycle; untranslated, the bus
// controller's own.
assign c_wr_busy_w = xlat ? (w_block || (!w_receipt && !w_acc))
                          : (m_wr_busy_w || w_slot);
assign c_idle      = m_idle && !w_slot && (rs == RS_IDLE);
assign wr_pend     = (ws == WS_POST) || m_wr_busy_w;

always @(posedge clk) begin
	if (!nreset) begin
		ws <= WS_FREE; w_la <= 32'd0; w_data <= 32'd0; w_size <= `AP040_SZ_L;
		w_sup <= 1'b1; w_ovr <= 1'b0; w_fcv <= 3'd0;
		w_pa1 <= 32'd0; w_pa2 <= 32'd0; w_bi <= 2'd0; w_last <= 2'd0;
		w_block <= 1'b0; w_receipt <= 1'b0; w_acc <= 1'b0;
		rs <= RS_IDLE; r_la <= 32'd0; r_size <= `AP040_SZ_L; r_sup <= 1'b1; r_ovr <= 1'b0;
		r_fcv <= 3'd0; r_pa1 <= 32'd0; r_pa2 <= 32'd0; r_bi <= 2'd0; r_last <= 2'd0;
		r_acc <= 24'd0; r_wait <= 1'b0;
		own <= 1'b0; own_v <= 1'b0; own_flt <= 1'b0; own_q <= 32'd0;
		fsrc <= 1'b0; flt_bus_r <= 1'b0; flt_ma_r <= 1'b0;
		d_hw <= 1'b0; d_hr <= 1'b0; d_gap <= 1'b0;
	end else begin
		// ---- the MMU's data port ----
		d_hw  <= w_on && !d_pass && !d_flt;
		d_hr  <= r_on && !d_pass && !d_flt;
		d_gap <= d_flt;

		// ---- the write slot ----
		if (c_wr_drop) w_block <= 1'b0;
		w_acc <= w_passed;
		if (w_acc)      w_receipt <= !c_wr;
		else if (c_wr)  w_receipt <= 1'b0;   // consumed: wr_busy was low for it
		if (w_take) begin
			w_la   <= c_addr;
			w_data <= c_wdata;
			w_size <= c_size;
			w_sup  <= sup_of(c_fc_ovr, c_fc_val, c_sup);
			w_ovr  <= c_fc_ovr;
			w_fcv  <= c_fc_val;
			w_bi   <= 2'd0;
			w_last <= last_of(c_size);
			if (c_alt) begin w_pa1 <= c_addr; ws <= WS_POST; end
			else ws <= WS_CHK1;
		end
		case (ws)
		WS_CHK1: if (w_flt) begin
			// refused: nothing written; MA clear, it is the first page
			ws <= WS_FREE; w_block <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b0; flt_ma_r <= 1'b0;
		end else if (w_pass) begin
			if (w_x) ws <= WS_CHK2;
			else begin w_pa1 <= d_pa; ws <= WS_POST; end
		end
		WS_CHK2: if (w_flt) begin
			ws <= WS_FREE; w_block <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b0; flt_ma_r <= 1'b1;
		end else if (w_pass) ws <= WS_T1;
		// Both pages checked: now translated for real. A fault here can only
		// be a table search's bus error (the checks passed), and the write,
		// not yet accepted, is refused like any other.
		WS_T1: if (w_flt) begin
			ws <= WS_FREE; w_block <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b0; flt_ma_r <= 1'b0;
		end else if (w_pass) begin w_pa1 <= d_pa & ~pg_mask32; ws <= WS_T2; end
		WS_T2: if (w_flt) begin
			ws <= WS_FREE; w_block <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b0; flt_ma_r <= 1'b1;
		end else if (w_pass) begin w_pa2 <= d_pa & ~pg_mask32; ws <= WS_POST; end
		WS_POST: if (s_post) begin
			if (w_x && (w_bi != w_last)) w_bi <= w_bi + 2'd1;
			else ws <= WS_FREE;
		end
		default: ;
		endcase

		// ---- the read ----
		if (r_thru) begin
			own  <= 1'b0;            // the bus controller answers; it drops its valid now
			fsrc <= 1'b0;
		end
		if (r_new) begin
			r_la    <= c_addr;
			r_size  <= c_size;
			r_sup   <= sup_of(c_fc_ovr, c_fc_val, c_sup);
			r_ovr   <= c_fc_ovr;
			r_fcv   <= c_fc_val;
			r_bi    <= 2'd0;
			r_last  <= last_of(c_size);
			r_acc   <= 24'd0;
			own     <= 1'b1;         // answered here until it is sent
			own_v   <= 1'b0;
			own_flt <= 1'b0;
			// an alternate space needs no translation: it waits only for the slot
			if (c_alt) begin r_pa1 <= c_addr; rs <= RS_RDY; end
			else rs <= RS_XL;
		end
		case (rs)
		RS_XL: if (r_flt) begin
			rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b0; flt_ma_r <= 1'b0;
		end else if (r_send_x) begin
			rs <= RS_IDLE; own <= 1'b0; fsrc <= 1'b0;
		end else if (r_pass) begin
			if (r_x) begin r_pa1 <= d_pa & ~pg_mask32; rs <= RS_XL2; end
			else     begin r_pa1 <= d_pa;              rs <= RS_RDY; end
		end
		RS_XL2: if (r_flt) begin
			rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b0; flt_ma_r <= 1'b1;
		end else if (r_pass) begin
			r_pa2 <= d_pa & ~pg_mask32; rs <= RS_BYTE;
		end
		RS_RDY: if (r_send_q) begin
			rs <= RS_IDLE; own <= 1'b0; fsrc <= 1'b0;
		end
		RS_BYTE: begin
			if (r_issue) r_wait <= 1'b1;
			else if (r_wait && m_rvalid) begin
				r_wait <= 1'b0;
				if (m_rflt) begin
					// a byte's bus error: the read faults, MA past the boundary
					rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b1;
					fsrc <= 1'b1; flt_bus_r <= 1'b1; flt_ma_r <= r_byte_p2;
				end else if (r_bi != r_last) begin
					r_acc <= {r_acc[15:0], m_q[7:0]};
					r_bi  <= r_bi + 2'd1;
				end else begin
					rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b0;
					own_q <= {r_acc, m_q[7:0]};
				end
			end
		end
		default: ;
		endcase
	end
end

`ifdef VERILATOR
always @(posedge clk)
	if (nreset) begin
		// The bus controller's port B takes one address a cycle.
		if (m_rd && m_wr)
			$error("ap040_pipe_dmu: a read and a write on the bus controller's port B in one cycle");
		// One read at a time: the CPU asks again only once it has its answer,
		// and by then this unit has sent or answered the last one.
		if (c_rd && (rs != RS_IDLE))
			$error("ap040_pipe_dmu: a read asked for while one is outstanding here (%0d)", rs);
	end
`endif

endmodule
