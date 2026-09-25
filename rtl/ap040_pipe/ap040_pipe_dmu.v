//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (2026-09-25)                   //
//                                                                          //
// ap040_pipe_dmu.v - the data memory unit                                  //
//                                                                          //
// Between EA-fetch's port B and the bus controller (ap040_pipe_membus.v),  //
// as the MC68040's DMU sits between its operand accesses and its bus       //
// controller (MC68040UM Figure 4-1): operand addresses are translated here //
// by ap040_pipe_mmu.v's data port, and only physical addresses go on.      //
// Stage A of doc_AP040_PIPELINE_CACHES.md put translation here; stage C    //
// the data cache, write-through (below).                                   //
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
//                                                                          //
// The data cache (caches stage C, write-through; MC68040UM 4). 64 sets of  //
// four 16-byte lines, physically tagged, on stage 0's arrays (a longword a //
// way a read, byte enables; a tag row a set; the snoop copy); valid bits    //
// and the replacement counter in flops. CACR DE turns it on; with DE clear //
// every path above is as it was.                                           //
//   Reads. Every read is latched and translated (untranslated, the MMU      //
//   passes it at once, with the caching mode a TTR gives, else write-      //
//   through). Its set is read in the cycle its translation passes -- PA9-  //
//   PA2 are the untranslated bits, already in the latch -- and compared    //
//   the next: a hit is answered from the cache, right-aligned by size.     //
//   A miss reads the line, the longword asked for first and the rest       //
//   wrapping, each longword a bus controller read; the first answers the   //
//   read, the rest are handed to later reads of the line as they arrive.  //
//   The line is valid when all four are in; an error on any beat abandons //
//   it, faulting only the read waiting for that longword.                  //
//   Not cached: an access a TTR or page marks inhibited (CM 1x), MOVES to  //
//   an alternate space, a locked access (TAS, CAS, CAS2); each first       //
//   invalidates a line holding its address (4.3.2, 7.4.5), then goes to    //
//   the bus. A read spanning two longwords, or pages, goes to the bus too  //
//   (the cache holds what memory does: it is write-through). Exception     //
//   frames, the vector fetch and MOVE16 allocate nothing (4.3.3): a read   //
//   of theirs that misses goes to the bus alone.                           //
//   Writes go to the bus controller as they did, and each updates a line   //
//   holding it, through the byte enables, in the order the writes are      //
//   sent (4.3.1.1; Table 4-4) -- a MOVE16 write, or a write to a page not  //
//   cached, invalidates the line instead. A read's lookup waits for the    //
//   update of every write before it. A write into the line being read     //
//   keeps that line from being made valid, and its longwords from being    //
//   handed on.                                                             //
//   Replacement: the first invalid way, else the counter's, which counts   //
//   every read looked up and every write sent (4.1).                       //
//   CINV/CPUSH on the data cache (cm_*), whatever CACR says: all ways, a   //
//   line, or a 4 KB page (64 tag rows), at a physical address; there is no //
//   dirty data, so CPUSH is CINV (stage D brings copyback).                //
//   Snoops (sn_*): as the instruction cache's, through the tag copy.       //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_dmu
(
	input             clk,
	input             nreset,

	input             xlat,        // translation can refuse a data write (l1_wr_sync)
	input             tc_e,
	input             tc_p,

	// ---- the data cache's controls (stage C) ----
	input             dc_en,       // CACR DE
	input      [31:0] dtt0,        // the caching mode of an untranslated write
	input      [31:0] dtt1,
	// CINV/CPUSH (ap040_ea_fetch.v), held until cm_done; the top combines
	// this done with the instruction cache's
	input             cm_req,
	input             cm_dc,
	input       [1:0] cm_scope,    // 01 line, 10 page, 11 all
	input      [31:0] cm_addr,     // physical
	output reg        cm_done,
	// another master wrote memory (caches stage F wires it)
	input             sn_req,
	input      [31:0] sn_addr,

	// ---- EA-fetch (port B) ----
	input      [31:0] c_addr,
	input             c_rd,
	input             c_wr,
	input       [1:0] c_size,
	input      [31:0] c_wdata,
	input             c_sup,
	input             c_fc_ovr,
	input       [2:0] c_fc_val,
	// what the access is (4.3.3, 7.4.5): allocates no line (an exception
	// frame, the vector fetch, MOVE16); MOVE16 (a write hit invalidates);
	// locked (TAS, CAS, CAS2: not cached)
	input             c_nalloc,
	input             c_m16,
	input             c_lock,
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
	input       [1:0] d_cm,        // with d_pass: the caching mode (00 WT, 01 CB, 1x inhibited)

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
function ttr_match;   // ap040_pipe_mmu.v's
	input [31:0] ttr;
	input [31:0] la;
	input        s;
	begin
		ttr_match = ttr[15] &&
		            (&((la[31:24] ~^ ttr[31:24]) | ttr[23:16])) &&
		            (ttr[14] || (ttr[13] == s));
	end
endfunction
// A read's answer from a longword: right-aligned by its size, as the bus
// controller answers.
function [31:0] ext_of;
	input [31:0] lw;
	input  [1:0] off;
	input  [1:0] sz;
	begin
		case (sz)
		`AP040_SZ_B: ext_of = {24'd0, lw[(5'd24 - {off, 3'b000}) +: 8]};
		`AP040_SZ_W: ext_of = {16'd0, lw[(5'd16 - {off, 3'b000}) +: 16]};   // off 0-2
		default:     ext_of = lw;
		endcase
	end
endfunction
// Whether an access of sz bytes at off spans two longwords.
function spans;
	input [1:0] off;
	input [1:0] sz;
	begin
		spans = ({1'b0, off} + ((sz == `AP040_SZ_L) ? 3'd4 : (sz == `AP040_SZ_W) ? 3'd2 : 3'd1)) > 3'd4;
	end
endfunction

//---------------------------------------------------------------------------
// the data cache's state (stage C; its logic is below)
//---------------------------------------------------------------------------

// The line being read (a miss's), and its buffer.
reg        fl_act;
reg [27:0] fl_line;             // PA31-PA4
reg  [2:0] fl_fc;
reg  [1:0] fl_st;               // the longword asked for: read first
reg  [2:0] fl_iss;              // reads sent
reg  [1:0] fl_arr;              // longwords arrived
reg  [3:0] fl_have;
reg [31:0] fb [0:3];
reg  [1:0] fl_way;
reg [87:0] fl_tags;             // the set's tag row, written back with the new tag
reg        fl_out;              // a read of the line is with the bus controller
reg        fl_nov;              // snooped while being read: not to be made valid
// The last write's update: a line holding it takes its bytes, or goes.
reg        su_v;
reg        su_cmp;              // its set's rows are on the outputs
reg        su_part;             // its second longword (it spans two)
reg [31:0] su_pa;
reg  [1:0] su_size;
reg [31:0] su_data;
reg        su_inv;              // invalidate the line rather than update it
reg        su_tt, su_s;         // untranslated: a data TTR may inhibit it; its privilege
// Valid bits and the replacement counter, in flops.
reg  [3:0] vld [0:63];
reg  [1:0] rep;
// CINV/CPUSH
localparam [1:0] CM_IDLE = 2'd0, CM_LINE = 2'd1, CM_PAGE = 2'd2;
reg  [1:0] cm_st;
reg  [5:0] cm_set, cm_rset;
reg        cm_more, cm_rdv, cm_seen;
// snoops: captured (1), their row on the copy's outputs (2)
reg        sn_v1, sn_v2, sn_junk2;
reg [27:0] sn_l1, sn_l2;

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
reg  [1:0] w_cm;                // its caching mode, from its translation
reg        w_m16, w_lk;         // MOVE16; locked
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
// holds a write from before translation was turned off, or (DE) the data
// cache has not yet taken the last write's update.
wire       w_thru  = !xlat && c_wr && !w_slot && !su_v;

//---------------------------------------------------------------------------
// the read
//---------------------------------------------------------------------------

localparam [2:0] RS_IDLE = 3'd0,   // nothing outstanding here
                 RS_XL   = 3'd1,   // translating (crossing: page 1)
                 RS_XL2  = 3'd2,   // crossing: translating page 2
                 RS_RDY  = 3'd3,   // translated, waiting for the slot to empty
                 RS_BYTE = 3'd4,   // crossing: its bytes, one read each
                 RS_LK   = 3'd5,   // DE: waiting for the cache to look it up
                 RS_CMP  = 3'd6,   // DE: its set's rows are on the arrays' outputs
                 RS_FW   = 3'd7;   // DE: waiting for its line's first longword
reg  [2:0] rs;
reg [31:0] r_la;
reg  [1:0] r_size;
reg        r_sup, r_ovr;
reg  [2:0] r_fcv;
reg [31:0] r_pa1, r_pa2;
reg  [1:0] r_bi, r_last;
reg [23:0] r_acc;               // a crossing read's bytes so far, right-aligned
reg        r_wait;              // a byte's read is with the bus controller
reg        r_dc;                // DE was set when it came: the cache's
reg        r_na, r_lk;          // allocates nothing; locked
reg        r_ci;                // not cached: a line holding it is invalidated, then the bus
// The answer: the bus controller's, or this unit's own (a fault, or a
// crossing read's assembled bytes).
reg        own;
reg        own_v, own_flt;
reg [31:0] own_q;
// The last fault's kind, from whichever unit raised it.
reg        fsrc;                // 1: this unit's registers, 0: the bus controller's
reg        flt_bus_r, flt_ma_r;

// Untranslated, straight to the bus controller; otherwise latched here --
// always with the data cache on, and while a line is being read.
wire        r_thru  = !xlat && !dc_en && c_rd && (rs == RS_IDLE) && !w_slot && !fl_act;
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
wire        s_post    = (ws == WS_POST) && !m_wr_busy_w && !su_v;

// A translated read goes only when nothing older is here: the slot empty.
// (A write the CPU presents in the same cycle is not older than a read
// already waiting here -- port B asks one thing at a time, and a read
// outstanding is answered before its instruction's own writes -- and it
// goes into the slot, or to the bus controller's write input: never onto
// rx's.)
wire        r_go      = !w_slot && !fl_act;
wire        r_send_x  = r_pass && (rs == RS_XL) && !r_x && r_go && !r_dc;   // straight on its translation
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
// Translated reads, and the data cache's line reads -- the first in the
// cycle the miss is seen (nothing else of this unit's is out then).
assign m_rx      = r_send_x || r_send_q || r_issue || fl_start || fl_rq;
assign m_rx_addr = fl_start ? {r_pa1[31:2], 2'b00} : fl_rq ? {fl_line, fl_st + fl_iss[1:0], 2'b00} :
                   r_send_x ? d_pa : r_send_q ? r_pa1 : r_byte_pa;
assign m_rx_size = (fl_start || fl_rq) ? `AP040_SZ_L : r_issue ? `AP040_SZ_B : r_size;
assign m_rx_fc   = fl_start ? r_fcb : fl_rq ? fl_fc : r_ovr ? fc_bus(r_fcv) : {r_sup, 2'b01};

//---------------------------------------------------------------------------
// the data cache (stage C)
//---------------------------------------------------------------------------

// The cache is free for a lookup: no line being read, no maintenance.
wire        cm_go   = cm_req && !cm_seen && (cm_st == CM_IDLE) && !su_v && !fl_act && (rs != RS_CMP) && !su_cmp;
wire        c_free  = !fl_act && (cm_st == CM_IDLE) && !cm_go;
// The last write's update: its bytes in an 8-byte window from its longword.
wire  [7:0] su_be8  = ((su_size == `AP040_SZ_L) ? 8'hF0 : (su_size == `AP040_SZ_W) ? 8'hC0 : 8'h80) >> su_pa[1:0];
wire [63:0] su_d64  = ((su_size == `AP040_SZ_L) ? {su_data, 32'd0} :
                       (su_size == `AP040_SZ_W) ? {su_data[15:0], 48'd0} : {su_data[7:0], 56'd0}) >> {su_pa[1:0], 3'b000};
wire [29:0] su_lw   = su_pa[31:2] + {29'd0, su_part};
wire  [3:0] su_be   = su_part ? su_be8[3:0] : su_be8[7:4];
wire [31:0] su_wd   = su_part ? su_d64[31:0] : su_d64[63:32];
wire        su_two  = (su_be8[3:0] != 4'd0);
wire        su_ta   = ttr_match(dtt0, su_pa, su_s);
wire        su_tb   = ttr_match(dtt1, su_pa, su_s);
wire        su_ci   = su_inv || (su_tt && (su_ta ? dtt0[6] : su_tb ? dtt1[6] : 1'b0));
wire        su_rd   = su_v && !su_cmp && c_free;          // its set is read now
// A read's lookup: in the cycle its translation passes, or later from
// RS_LK; never while a write's update is waiting (the write is older).
wire        rd_lk   = c_free && !su_v && r_go &&
                      (((rs == RS_XL) && r_pass && !r_x && r_dc && !spans(r_la[1:0], r_size)) ||
                       (rs == RS_LK));
wire  [7:0] a_addr  = su_v ? su_lw[7:0] : r_la[9:2];
wire [127:0] a_data;
wire  [87:0] a_tags, b_tags, s_tags;
// the compare: a read's (RS_CMP, against its translation) or an update's
wire [21:0] ck_tag  = su_cmp ? su_lw[29:8] : r_pa1[31:10];
wire  [5:0] ck_set  = su_cmp ? su_lw[7:2]  : r_pa1[9:4];
wire  [3:0] ck_vrow = vld[ck_set];
wire  [3:0] ck_hw;
genvar gw;
generate
for (gw = 0; gw < 4; gw = gw + 1) begin : hw
	assign ck_hw[gw] = ck_vrow[gw] && (a_tags[gw*22 +: 22] == ck_tag);
end
endgenerate
wire        ck_hit  = |ck_hw;
wire  [1:0] ck_way  = ck_hw[0] ? 2'd0 : ck_hw[1] ? 2'd1 : ck_hw[2] ? 2'd2 : 2'd3;
wire        dc_hit  = (rs == RS_CMP) && !su_cmp && ck_hit;
wire [31:0] dc_hlw  = a_data[ck_way*32 +: 32];
wire        su_hit  = su_cmp && ck_hit;
wire        su_we   = su_hit && !su_ci;
// A miss reads the line (a read that allocates); the way it replaces: the
// first invalid, else the counter's.
wire        fl_start = (rs == RS_CMP) && !su_cmp && !ck_hit && !r_ci && !r_na;
wire  [1:0] fl_vict  = !ck_vrow[0] ? 2'd0 : !ck_vrow[1] ? 2'd1 : !ck_vrow[2] ? 2'd2 :
                       !ck_vrow[3] ? 2'd3 : rep;
wire  [1:0] fl_aidx  = fl_st + fl_arr;                    // the longword arriving next
wire        fl_ack   = fl_out && m_rvalid && !m_rflt;
wire        fl_flt   = fl_out && m_rvalid && m_rflt;
wire        fl_rq    = fl_act && !fl_out && (fl_iss != 3'd4);
wire        fl_done  = fl_ack && (fl_arr == 2'd3);
wire  [2:0] r_fcb    = r_ovr ? fc_bus(r_fcv) : {r_sup, 2'b01};
// A read in the line being read, its longword in (or arriving), and no
// write's update waiting that could change it: handed on.
wire        lk_infl  = (rs == RS_LK) && fl_act && !fl_nov && !su_v && !r_ci && (r_pa1[31:4] == fl_line);
wire        lk_fb    = lk_infl && fl_have[r_pa1[3:2]];
wire        lk_fa    = lk_infl && fl_ack && (fl_aidx == r_pa1[3:2]);
// ...or its longword's read errs: the read's fault; another longword's error
// sends it back to be looked up again
wire        lk_ff    = (rs == RS_LK) && fl_act && !r_ci && (r_pa1[31:4] == fl_line) && fl_flt &&
                       (fl_aidx == r_pa1[3:2]);
// the tag row the fill writes back
wire [87:0] fl_wtags;
generate
for (gw = 0; gw < 4; gw = gw + 1) begin : twr
	assign fl_wtags[gw*22 +: 22] = (fl_way == gw) ? fl_line[27:6] : fl_tags[gw*22 +: 22];
end
endgenerate
// CINV/CPUSH rows through the tag port B
wire        cm_rd   = (cm_st != CM_IDLE) && cm_more;
wire  [3:0] cm_hw;
generate
for (gw = 0; gw < 4; gw = gw + 1) begin : cmw
	assign cm_hw[gw] = (cm_st == CM_LINE) ? (b_tags[gw*22 +: 22] == cm_addr[31:10])
	                                      : (b_tags[gw*22 + 2 +: 20] == cm_addr[31:12]);
end
endgenerate
// snoops
wire  [3:0] sn_hw;
generate
for (gw = 0; gw < 4; gw = gw + 1) begin : snw
	assign sn_hw[gw] = (s_tags[gw*22 +: 22] == sn_l2[27:6]);
end
endgenerate
wire  [3:0] sn_clr  = sn_junk2 ? 4'hF : sn_hw;
wire        sn_fill = sn_v2 && fl_act && (sn_l2 == fl_line);
// The valid bits: a snoop's set and one other change a cycle, merged.
wire        cm_all  = cm_go && cm_dc && (cm_scope == 2'b11);
wire        rd_inv  = (rs == RS_CMP) && !su_cmp && ck_hit && r_ci;
wire        su_inv1 = su_hit && su_ci;
wire        o_v     = rd_inv || su_inv1 || fl_start || fl_done || cm_rdv;
wire  [5:0] o_set   = fl_done ? fl_line[5:0] : cm_rdv ? cm_rset : ck_set;
wire  [3:0] o_and   = (rd_inv || su_inv1) ? ~(4'd1 << ck_way) : fl_start ? ~(4'd1 << fl_vict) :
                      cm_rdv ? ~cm_hw : 4'hF;
wire  [3:0] o_or    = (fl_done && !fl_nov && !sn_fill) ? (4'd1 << fl_way) : 4'd0;

ap040_pipe_dcache_arr u_arr
(
	.clk     (clk),
	.a_addr  (a_addr), .a_data (a_data), .a_way (ck_way), .a_wdata (su_wd), .a_be (su_be), .a_we (su_we),
	.b_addr  ({fl_line[5:0], fl_aidx}), .b_data (), .b_way (fl_way), .b_wdata (m_q), .b_we (fl_ack),
	.ta_set  (a_addr[7:2]), .ta_tags (a_tags),
	.tb_set  ((cm_st != CM_IDLE) ? cm_set : fl_line[5:0]), .tb_tags (b_tags),
	.tb_wtags (fl_wtags), .tb_we (fl_done),
	.s_set   (sn_l1[5:0]), .s_tags (s_tags)
);

integer i;
always @(posedge clk) begin
	cm_done <= 1'b0;
	if (!nreset) begin
		fl_act <= 1'b0; fl_line <= 28'd0; fl_fc <= 3'd0; fl_st <= 2'd0; fl_iss <= 3'd0; fl_arr <= 2'd0;
		fl_have <= 4'd0; fl_way <= 2'd0; fl_tags <= 88'd0; fl_out <= 1'b0; fl_nov <= 1'b0;
		su_v <= 1'b0; su_cmp <= 1'b0; su_part <= 1'b0; su_pa <= 32'd0; su_size <= `AP040_SZ_L;
		su_data <= 32'd0; su_inv <= 1'b0; su_tt <= 1'b0; su_s <= 1'b1;
		rep <= 2'd0;
		cm_st <= CM_IDLE; cm_set <= 6'd0; cm_rset <= 6'd0; cm_more <= 1'b0; cm_rdv <= 1'b0; cm_seen <= 1'b0;
		sn_v1 <= 1'b0; sn_v2 <= 1'b0; sn_junk2 <= 1'b0; sn_l1 <= 28'd0; sn_l2 <= 28'd0;
		for (i = 0; i < 64; i = i + 1) vld[i] <= 4'd0;
	end else begin
		// ---- a write sent: its update ----
		if (dc_en && m_wr) begin
			su_v    <= 1'b1;
			su_cmp  <= 1'b0;
			su_part <= 1'b0;
			su_pa   <= m_addr;
			su_size <= m_size;
			su_data <= m_wdata;
			// the slot's: its translation's mode, a crossing write's bytes, a
			// MOVES to an alternate space; straight through: an alternate
			// space, or a data TTR (su_tt, below)
			su_inv  <= s_post ? (w_cm[1] || w_x || w_m16 || w_lk || alt_of(w_ovr, w_fcv))
			                  : (c_m16 || c_lock || c_alt);
			su_tt   <= !s_post;
			su_s    <= s_post ? w_sup : sup_of(c_fc_ovr, c_fc_val, c_sup);
		end else if (su_rd) su_cmp <= 1'b1;
		else if (su_cmp) begin
			su_cmp <= 1'b0;
			if (!su_part && su_two) su_part <= 1'b1;
			else begin su_v <= 1'b0; su_part <= 1'b0; end
		end
		// the counter: every read looked up, every write sent, and once more
		// after naming a way to replace
		rep <= rep + {1'b0, rd_lk} + {1'b0, dc_en && m_wr} + {1'b0, fl_start && (&ck_vrow)};

		// ---- a miss: its line ----
		if (fl_start) begin
			fl_act  <= 1'b1;
			fl_line <= r_pa1[31:4];
			fl_fc   <= r_fcb;
			fl_st   <= r_pa1[3:2];
			fl_iss  <= 3'd0;
			fl_arr  <= 2'd0;
			fl_have <= 4'd0;
			fl_way  <= fl_vict;
			fl_tags <= a_tags;
			fl_nov  <= 1'b0;
		end
		if (fl_start) begin fl_out <= 1'b1; fl_iss <= 3'd1; end   // its first read goes now
		else if (fl_rq) begin fl_out <= 1'b1; fl_iss <= fl_iss + 3'd1; end
		if (fl_ack) begin
			fl_out           <= 1'b0;
			fl_arr           <= fl_arr + 2'd1;
			fl_have[fl_aidx] <= 1'b1;
			fb[fl_aidx]      <= m_q;
			if (fl_arr == 2'd3) fl_act <= 1'b0;       // valid (below), its tag written now
		end
		if (fl_flt) begin
			// the line is abandoned; its way stays invalid
			fl_out <= 1'b0;
			fl_act <= 1'b0;
		end

		// ---- CINV/CPUSH ----
		if (!cm_req) cm_seen <= 1'b0;
		cm_rdv  <= cm_rd;
		cm_rset <= cm_set;
		if (cm_go) begin
			if (!cm_dc) begin cm_done <= 1'b1; cm_seen <= 1'b1; end
			else case (cm_scope)
			2'b01: begin cm_st <= CM_LINE; cm_set <= cm_addr[9:4]; cm_more <= 1'b1; end
			2'b10: begin cm_st <= CM_PAGE; cm_set <= 6'd0;         cm_more <= 1'b1; end
			default: begin cm_done <= 1'b1; cm_seen <= 1'b1; end   // all ways: cm_all
			endcase
		end
		if (cm_rd) begin
			if (cm_st == CM_PAGE && cm_set != 6'd63) cm_set <= cm_set + 6'd1;
			else cm_more <= 1'b0;
		end
		if (cm_rdv && (cm_st == CM_LINE || cm_rset == 6'd63)) begin
			cm_st <= CM_IDLE; cm_done <= 1'b1; cm_seen <= 1'b1;
		end

		// ---- snoops ----
		sn_v1    <= sn_req;
		sn_l1    <= sn_addr[31:4];
		sn_v2    <= sn_v1;
		sn_l2    <= sn_l1;
		sn_junk2 <= sn_v1 && fl_done && (fl_line[5:0] == sn_l1[5:0]);
		if (sn_fill) fl_nov <= 1'b1;

		// ---- the valid bits ----
		if (cm_all) for (i = 0; i < 64; i = i + 1) vld[i] <= 4'd0;
		else if (o_v && sn_v2 && (o_set == sn_l2[5:0]))
			vld[o_set] <= ((vld[o_set] & o_and) | o_or) & ~sn_clr;
		else begin
			if (o_v)   vld[o_set]       <= (vld[o_set] & o_and) | o_or;
			if (sn_v2) vld[sn_l2[5:0]] <= vld[sn_l2[5:0]] & ~sn_clr;
		end
	end
end

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
                          : (m_wr_busy_w || w_slot || su_v);
assign c_idle      = m_idle && !w_slot && (rs == RS_IDLE) && !fl_act && !su_v;
assign wr_pend     = (ws == WS_POST) || m_wr_busy_w;

always @(posedge clk) begin
	if (!nreset) begin
		ws <= WS_FREE; w_la <= 32'd0; w_data <= 32'd0; w_size <= `AP040_SZ_L;
		w_cm <= 2'b00; w_m16 <= 1'b0; w_lk <= 1'b0;
		w_sup <= 1'b1; w_ovr <= 1'b0; w_fcv <= 3'd0;
		w_pa1 <= 32'd0; w_pa2 <= 32'd0; w_bi <= 2'd0; w_last <= 2'd0;
		w_block <= 1'b0; w_receipt <= 1'b0; w_acc <= 1'b0;
		rs <= RS_IDLE; r_la <= 32'd0; r_size <= `AP040_SZ_L; r_sup <= 1'b1; r_ovr <= 1'b0;
		r_dc <= 1'b0; r_na <= 1'b0; r_lk <= 1'b0; r_ci <= 1'b0;
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
			w_m16  <= c_m16;
			w_lk   <= c_lock;
			if (c_alt) begin w_pa1 <= c_addr; w_cm <= 2'b10; ws <= WS_POST; end
			else ws <= WS_CHK1;
		end
		case (ws)
		WS_CHK1: if (w_flt) begin
			// refused: nothing written; MA clear, it is the first page
			ws <= WS_FREE; w_block <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b0; flt_ma_r <= 1'b0;
		end else if (w_pass) begin
			if (w_x) ws <= WS_CHK2;
			else begin w_pa1 <= d_pa; w_cm <= d_cm; ws <= WS_POST; end
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
			r_dc    <= dc_en;
			r_na    <= c_nalloc;
			r_lk    <= c_lock;
			r_ci    <= c_alt;
			own     <= 1'b1;         // answered here until it is sent
			own_v   <= 1'b0;
			own_flt <= 1'b0;
			// an alternate space needs no translation: it waits only for the
			// slot -- and with DE, for its line to be invalidated
			if (c_alt) begin r_pa1 <= c_addr; rs <= dc_en ? RS_LK : RS_RDY; end
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
			else if (r_dc) begin
				// its set read now, if the cache is free; a read spanning two
				// longwords goes to the bus
				r_pa1 <= d_pa;
				r_ci  <= r_lk || d_cm[1];
				rs    <= spans(r_la[1:0], r_size) ? RS_RDY : rd_lk ? RS_CMP : RS_LK;
			end
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
		RS_LK: if (lk_fb || lk_fa) begin
			// in the line being read, and in: handed on
			rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b0;
			own_q <= ext_of(lk_fb ? fb[r_pa1[3:2]] : m_q, r_pa1[1:0], r_size);
		end else if (lk_ff) begin
			// its longword's read erred: the read's bus error
			rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b1; flt_ma_r <= 1'b0;
		end else if (rd_lk) rs <= RS_CMP;
		RS_CMP: if (dc_hit && !r_ci) begin
			rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b0;
			own_q <= ext_of(dc_hlw, r_pa1[1:0], r_size);
		end else if (dc_hit || r_ci || r_na) rs <= RS_RDY;   // (a hit not cached: invalidated below)
		else rs <= RS_FW;                                     // the line is read (below)
		RS_FW: if (fl_ack && (fl_arr == 2'd0)) begin
			rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b0;
			own_q <= ext_of(m_q, r_pa1[1:0], r_size);
		end else if (fl_flt && (fl_arr == 2'd0)) begin
			rs <= RS_IDLE; own_v <= 1'b1; own_flt <= 1'b1;
			fsrc <= 1'b1; flt_bus_r <= 1'b1; flt_ma_r <= 1'b0;
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
