//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_pipe_bcu.v - bus controller: one memory port for IF, EA-fetch and  //
// the stores WB commits (Minimig plan M5)                                  //
//                                                                          //
// Memory side: the reference core's request port (lib/AP68040 ap040_core.v //
// mem_*): mem_req with {write, instr, size, addr, wdata, fc} held stable   //
// until mem_ack (a one-clock pulse, mem_rdata valid with it); mem_req is   //
// dropped in the ack clock, so it is low at the next enabled edge before  //
// a new request ("Changing an address while req remains asserted can make  //
// a completed request look like a duplicate transaction", ap040_core.v    //
// S_EPF_GAP).  Everything runs on the core's clock enable (the Minimig    //
// kernel is gated by clkena, ap040_tg68k_compat.v).                        //
//                                                                          //
// Clients:                                                                 //
//   stores  WB's committed store enters a posted-store FIFO (SB_N deep);   //
//           sb_full makes WB hold the store.  Stores go first: they are    //
//           older than any read outstanding.                               //
//   data    EA-fetch's read (rd_req a one-clock pulse, one outstanding),   //
//           answered by rd_ack.  It waits until every older store is in   //
//           memory: none in the FIFO, none committing in WB, none in EX    //
//           (older_st) -- so a read never needs store forwarding here.     //
//   fetch   IF's request (f_req held until f_gnt), answered by f_ack.      //
//           Lowest priority.                                               //
//                                                                          //
// mem_flt (an access error, M6) ends the transfer like an ack; rd_err /    //
// f_err flag the answer.  A store's error is fatal (st_err: nothing can be //
// restarted -- the reference's post_err).                                  //
//                                                                          //
// With translation on (tc_e), a data transfer that crosses a page boundary //
// is issued one byte at a time, most significant first, so each byte is   //
// translated through its own page (the reference's S_MRD_B/S_MWR_B,        //
// ap040_core.v; M68040UM 3.5 -- a misaligned operand's pieces are separate //
// accesses).  A fault on any byte ends the transfer with the error; the   //
// requester reports the transfer's first byte as FA, as the reference.    //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_bcu
	import ap040_pipe_pkg::*;
#(
	parameter SB_N = 4,
	// 0: synchronous stores -- WB holds a store until memory has taken it, so
	//    an access error on it is precise (M6; the reference core's stores are
	//    synchronous at the core too).  1: posted through the SB_N FIFO; an
	//    error on a posted store is fatal (st_err, the reference's post_err).
	parameter POST = 0,
	// (POST = 0) 1: WB's synchronous store completes the clock AFTER memory
	// acknowledges it (st_done & co. are registered).  The acknowledge is a
	// clk_114 signal registered on the edge right before the core's clk_38
	// edge (TG68K.vhd x_ack_r), and through st_done it reached WB's hold, EX's
	// stall and the whole stall chain back to IF's request -- 8.8 ns, the
	// design's one structural timing family (PLAN M11.1).  Registering it
	// ends that family at this module's flip-flops, for one clock per store.
	parameter DONE_REG = 0
)
(
	input             clk,
	input             nreset,
	input             ce,

	// stores (WB commit)
	input             st_v,       // commits this clock
	input      [31:0] st_addr,
	input       [1:0] st_size,
	input      [31:0] st_data,
	input       [2:0] st_fc,
	input             st_rb,      // (a CAS/CAS2 locked write-back: carried to mem_rb for the benches)
	output            sb_full,    // WB must hold a store (POST = 1)
	output            st_done,    // (POST = 0) WB's store completes this clock ...
	output            st_ferr,    // ... with an access error
	output            st_fatc,    // ... from the MMU
	output            sb_busy,    // a posted store is not in memory yet
	input             older_st,   // EX or WB holds a store not yet committed

	// data reads (EA-fetch)
	input             rd_req,
	input      [31:0] rd_addr,
	input       [1:0] rd_size,
	input       [2:0] rd_fc,
	output reg        rd_ack,
	output reg [31:0] rd_data,
	output reg        rd_err,
	// plan M14 step 3: the data read path serves the read in the slot this
	// clock (rd_fast, with its data): it is answered like a completed read
	// and never goes on the port.  Tie low without the path.
	input             rd_fast,
	input      [31:0] rd_fast_data,

	// instruction fetch (IF)
	input             f_req,
	input      [31:0] f_addr,
	input             f_long,
	input       [2:0] f_fc,
	output            f_gnt,
	output reg        f_ack,
	output reg [31:0] f_data,
	output reg        f_err,

	output reg        st_err,

	// memory port
	output reg        mem_req,
	output reg        mem_write,
	output reg        mem_instr,
	output reg  [1:0] mem_size,
	output reg [31:0] mem_addr,
	output reg [31:0] mem_wdata,
	output reg  [2:0] mem_fc,
	output reg        mem_rb,     // the store in progress is a locked write-back (debug)
	input             mem_ack,
	input      [31:0] mem_rdata,
	input             mem_flt,
	input             mem_atc,    // (with mem_flt) the MMU's fault, not the bus's (M7)
	output reg        rd_atc,
	output reg        f_atc,
	output reg        rd_ma,      // (with rd_err) the fault hit a split read's second page
	output            st_fma,     // (with st_ferr) ... a split store's
	input             tc_e,       // TC.E: translation on (M7)
	input             tc_p        // TC.P: 8K pages
);

//--------------------------------------------------------------- store FIFO
localparam PW = (SB_N <= 2) ? 1 : (SB_N <= 4) ? 2 : 3;
reg [31:0] sb_a [0:SB_N-1];
reg [31:0] sb_d [0:SB_N-1];
reg  [1:0] sb_s [0:SB_N-1];
reg  [2:0] sb_f [0:SB_N-1];
reg        sb_b [0:SB_N-1];
reg [PW-1:0] sb_rp, sb_wp;
reg [PW:0]   sb_cnt;

assign sb_full = POST ? (sb_cnt == SB_N[PW:0]) : 1'b0;
assign sb_busy = (sb_cnt != 0) || (mem_req && mem_write);

//--------------------------------------------------------------- data read slot
reg        dq_v;
reg [31:0] dq_a;
reg  [1:0] dq_s;
reg  [2:0] dq_f;

//--------------------------------------------------------------- the port
localparam [1:0] K_ST = 2'd0, K_RD = 2'd1, K_IF = 2'd2;
reg  [1:0] kind;           // what the transfer in progress is

// page-crossing split state (see below)
reg        sp_on;          // the transfer in progress is split into bytes
reg  [1:0] sp_i;           // the byte on the bus
reg  [1:0] sp_s;           // the whole transfer's size
reg [31:0] sp_a;           // ... its address
reg [31:0] sp_d;           // ... its store data
reg [23:0] sp_acc;         // the bytes read so far
wire idle    = !mem_req;         // (a new request never starts in the ack clock: one low enabled edge)
wire go_st   = POST ? (idle && !sp_on && (sb_cnt != 0)) :
                      (idle && !sp_on && st_v && !((DONE_REG != 0) && st_done_q));
// A read goes from the slot, never in the clock it is requested: EA-fetch
// may be sending the older instruction's store to EX in that same clock
// (an early read), and older_st sees it only once it is there.
wire go_rd   = idle && !sp_on && (sb_cnt == 0) && !st_v && !older_st && dq_v && !rd_fast;
wire go_if   = idle && !sp_on && !go_st && !go_rd && f_req;
assign f_gnt = go_if;

wire done    = mem_req && (mem_ack || mem_flt);

//--------------------------------------------------------------- page-crossing split
// (sp_on .. sp_acc: declared with the port logic above)
function automatic logic crosses(input logic e, input logic p, input logic [31:0] a, input logic [1:0] sz);
	logic [13:0] off;
	off = {1'b0, p & a[12], a[11:0]} + ((sz == SZ_L) ? 14'd4 : (sz == SZ_W) ? 14'd2 : 14'd1);
	return e && (sz != SZ_B) && (p ? (off > 14'h2000) : (off > 14'h1000));
endfunction
function automatic logic [7:0] sp_byte(input logic [31:0] d, input logic [1:0] sz, input logic [1:0] i);
	if (sz == SZ_W) return i[0] ? d[7:0] : d[15:8];
	case (i)
		2'd0: return d[31:24];
		2'd1: return d[23:16];
		2'd2: return d[15:8];
		default: return d[7:0];
	endcase
endfunction
wire [1:0] sp_nm1 = (sp_s == SZ_L) ? 2'd3 : 2'd1;            // the last byte's index
wire       sp_fin = !sp_on || mem_flt || (sp_i == sp_nm1);   // the transfer ends with this answer
wire       go_sp  = idle && sp_on;                           // the next byte (first priority)
wire [31:0] sp_rd = (sp_s == SZ_L) ? {sp_acc, mem_rdata[7:0]} : {16'd0, sp_acc[7:0], mem_rdata[7:0]};

wire   st_done_c = !POST && done && (kind == K_ST) && sp_fin;
wire   st_fma_c, st_ferr_c, st_fatc_c;
reg    st_done_q, st_ferr_q, st_fatc_q, st_fma_q;
assign st_done = (DONE_REG != 0) ? st_done_q : st_done_c;
// SSW.MA: the fault is on the far side of the page boundary (the reference's aer_ma)
wire   sp_ma   = sp_on && (tc_p ? (mem_addr[31:13] != sp_a[31:13]) : (mem_addr[31:12] != sp_a[31:12]));
assign st_fma_c  = sp_ma;
assign st_ferr_c = st_done_c && mem_flt;
assign st_fatc_c = st_ferr_c && mem_atc;
assign st_fma  = (DONE_REG != 0) ? st_fma_q  : st_fma_c;
assign st_ferr = (DONE_REG != 0) ? st_ferr_q : st_ferr_c;
assign st_fatc = (DONE_REG != 0) ? st_fatc_q : st_fatc_c;
always @(posedge clk)
	if (!nreset) begin st_done_q <= 1'b0; st_ferr_q <= 1'b0; st_fatc_q <= 1'b0; st_fma_q <= 1'b0; end
	else if (ce) begin
		st_done_q <= st_done_c; st_ferr_q <= st_ferr_c; st_fatc_q <= st_fatc_c; st_fma_q <= st_fma_c;
	end

integer k;
always @(posedge clk) begin
	if (!nreset) begin
		mem_req <= 1'b0; mem_write <= 1'b0; mem_instr <= 1'b0; mem_size <= SZ_L;
		mem_addr <= 32'd0; mem_wdata <= 32'd0; mem_fc <= 3'd5;
		kind <= K_ST;
		sb_rp <= '0; sb_wp <= '0; sb_cnt <= '0;
		dq_v <= 1'b0; dq_a <= 32'd0; dq_s <= SZ_L; dq_f <= 3'd5;
		rd_ack <= 1'b0; rd_data <= 32'd0; rd_err <= 1'b0; rd_atc <= 1'b0; f_atc <= 1'b0; rd_ma <= 1'b0;
		f_ack <= 1'b0; f_data <= 32'd0; f_err <= 1'b0;
		st_err <= 1'b0;
		for (k = 0; k < SB_N; k = k + 1) begin sb_a[k] <= 32'd0; sb_d[k] <= 32'd0; sb_s[k] <= SZ_L; sb_f[k] <= 3'd5; sb_b[k] <= 1'b0; end
		mem_rb <= 1'b0;
		sp_on <= 1'b0; sp_i <= 2'd0; sp_s <= SZ_L; sp_a <= 32'd0; sp_d <= 32'd0; sp_acc <= 24'd0;
	end else if (ce) begin
		rd_ack <= 1'b0; f_ack <= 1'b0;
		// a store committed by WB (posted)
		if (POST && st_v) begin
			sb_a[sb_wp] <= st_addr; sb_d[sb_wp] <= st_data; sb_s[sb_wp] <= st_size; sb_f[sb_wp] <= st_fc;
			sb_b[sb_wp] <= st_rb;
			sb_wp <= sb_wp + 1'b1;
		end
		if (POST) sb_cnt <= sb_cnt + (st_v ? 1'b1 : 1'b0) - ((done && kind == K_ST && sp_fin) ? 1'b1 : 1'b0);
		// a data read request waits in the slot
		if (rd_req) begin dq_v <= 1'b1; dq_a <= rd_addr; dq_s <= rd_size; dq_f <= rd_fc; end
		// ... unless the data read path answers it (M14 step 3)
		if (rd_fast && dq_v) begin
			dq_v <= 1'b0;
			rd_ack <= 1'b1; rd_data <= rd_fast_data;
			rd_err <= 1'b0; rd_atc <= 1'b0; rd_ma <= 1'b0;
		end
		// completion
		if (done && !sp_fin) begin
			// a byte of a split transfer: on to the next
			mem_req <= 1'b0;
			sp_i <= sp_i + 2'd1;
			sp_acc <= {sp_acc[15:0], mem_rdata[7:0]};
		end else if (done) begin
			mem_req <= 1'b0;
			sp_on <= 1'b0;
			case (kind)
				K_ST: begin
					if (POST) begin
						sb_rp <= sb_rp + 1'b1;   // (sp_fin: the whole store)
						if (mem_flt) st_err <= 1'b1;
					end
				end
				K_RD: begin rd_ack <= 1'b1; rd_data <= sp_on ? sp_rd : mem_rdata; rd_err <= mem_flt; rd_atc <= mem_flt && mem_atc; rd_ma <= mem_flt && sp_ma; end
				default: begin                // a word fetch answers right-aligned: IF wants it on top
					f_ack <= 1'b1; f_err <= mem_flt; f_atc <= mem_flt && mem_atc;
					f_data <= (mem_size == SZ_W) ? {mem_rdata[15:0], 16'h4E71} : mem_rdata;
				end
			endcase
		end
		// a new transfer
		if (go_sp) begin
			// the next byte of a split transfer (write/fc/kind stand)
			mem_req <= 1'b1; mem_size <= SZ_B;
			mem_addr <= sp_a + {30'd0, sp_i};
			mem_wdata <= {24'd0, sp_byte(sp_d, sp_s, sp_i)};
		end else if (go_st) begin : g_st
			// the store WB holds (stable until st_done), or the FIFO's oldest
			logic [31:0] a, d; logic [1:0] z;
			a = POST ? sb_a[sb_rp] : st_addr; d = POST ? sb_d[sb_rp] : st_data; z = POST ? sb_s[sb_rp] : st_size;
			mem_req <= 1'b1; kind <= K_ST; mem_write <= 1'b1; mem_instr <= 1'b0;
			mem_fc <= POST ? sb_f[sb_rp] : st_fc; mem_rb <= POST ? sb_b[sb_rp] : st_rb;
			if (crosses(tc_e, tc_p, a, z)) begin
				sp_on <= 1'b1; sp_i <= 2'd0; sp_s <= z; sp_a <= a; sp_d <= d;
				mem_addr <= a; mem_size <= SZ_B; mem_wdata <= {24'd0, sp_byte(d, z, 2'd0)};
			end else begin
				mem_addr <= a; mem_size <= z; mem_wdata <= d;
			end
		end else if (go_rd) begin
			mem_req <= 1'b1; kind <= K_RD; mem_write <= 1'b0; mem_instr <= 1'b0;
			mem_addr <= dq_a; mem_fc <= dq_f;
			if (crosses(tc_e, tc_p, dq_a, dq_s)) begin
				sp_on <= 1'b1; sp_i <= 2'd0; sp_s <= dq_s; sp_a <= dq_a; sp_acc <= 24'd0;
				mem_size <= SZ_B;
			end else mem_size <= dq_s;
			dq_v <= 1'b0;
		end else if (go_if) begin
			mem_req <= 1'b1; kind <= K_IF; mem_write <= 1'b0; mem_instr <= 1'b1;
			mem_addr <= f_addr; mem_size <= f_long ? SZ_L : SZ_W; mem_fc <= f_fc;
		end
	end
end

endmodule
