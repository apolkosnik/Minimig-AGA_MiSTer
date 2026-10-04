//--------------------------------------------------------------------------//
// AP020 - MC68020 compatible CPU                                           //
//                                                                          //
// ap020_fastram_fe.v - shared Fast RAM cache with optional native port.   //
// Pin bus: STERM termination and CBACK bursts (UM 7.3.2, 7.3.7). Runs      //
// on the processor clock; the DDR3 side (ap020_fastram_be) is reached      //
// through two dual-clock FIFOs.                                            //
//                                                                          //
// Reads are served from two line buffers (16 bytes each, one for program  //
// fetches, one for data): every read of a buffered line terminates at      //
// once.  A cache burst (CBREQ) is accepted with CBACK and its four         //
// longwords follow at one per clock, wrapping modulo 4 from the requested  //
// one.  Behind the buffers is an 8 KiB cache of Fast RAM (512 lines of 16  //
// bytes, direct mapped on the physical DDR3 line, block RAM): a buffer    //
// miss looks it up (two clocks) and a hit loads the whole line into the   //
// buffer; a miss reads the line from DDR3 and allocates it.  The           //
// processor's on-chip caches and CACR are unchanged; this cache is on     //
// physical addresses.                                                      //
//                                                                          //
// With NATIVE_PORT, CPU requests can bypass the pin sequencer.  Both      //
// ports share the buffers, block RAM and FIFO; locked (RMC) transfers     //
// still use pins. Native responses return the requested                    //
// longword first and wrap through the line without response backpressure. //
//                                                                          //
// Writes are posted: STERM as soon as the command FIFO has room.  They     //
// update any buffered copy of their line and the cache's copy (write      //
// through, no allocation), and they reach DDR3 in order with the reads,   //
// so a read never overtakes a write to the same address.                   //
//                                                                          //
// Coherence: the buffers and the cache follow the processor's cache       //
// maintenance -- a CACR clear (C or CE) empties the buffers and sweeps    //
// the cache invalid (512 clocks, reads go to DDR3 meanwhile), as does a    //
// processor reset -- and a cache-inhibited access (CIOUT) is never         //
// answered from a buffered line or the cache: it fetches the line, which  //
// is not allocated and is dropped when that cycle ends.  A                 //
// fill in flight when the buffers are cleared serves only the cycle that   //
// waits for it and is not allocated.  The processor is the only master     //
// that writes Fast RAM through its caches; a DMA writer (CDTV) relies on   //
// the operating system's cache clear after the transfer, as the on-chip   //
// caches do.                                                               //
//                                                                          //
// DDR3 layout (as the Minimig controllers use it): a 64-bit word holds     //
// four 16-bit words in ascending address order from bit 0, each word big   //
// endian.                                                                  //
//--------------------------------------------------------------------------//

module ap020_fastram_fe
#(parameter NATIVE_PORT = 0)
(
	input             clk,
	input             rst,

	// the processor bus (the MC68030's)
	input      [31:0] a,
	input       [2:0] fc,
	input       [1:0] siz,
	input             rw,
	input             as_n,
	input      [31:0] d_o,
	input             d_oe,
	input             cbreq_n,
	input             sel,          // the address is Fast RAM (decode of a)
	input             ci,           // CIOUT: the access is cache inhibited
	input             clear,        // pulse: a CACR cache clear (drop the line buffers)
	input      [28:0] ddr_addr,     // DDR3 64-bit word address of a
	output            sterm_n,
	output            cback_n,
	output     [31:0] d_i,

	// command FIFO (to DDR3): {write, ddr address, byte enables, data}
	output reg        cmd_we,
	output reg [101:0] cmd_wdata,
	input       [3:0] cmd_wlevel,   // entries in flight (FIFO of 8)

	// response FIFO (from DDR3): 64-bit beats of a requested line
	input      [63:0] rsp_rdata,
	input             rsp_rempty,
	output            rsp_re,

	// Processor-clock request/response port. It shares all cache state and
	// DDR queues with pin-bus accesses. Responses are consumed every clock.
	input             n_req,
	output            n_ready,
	input      [31:0] n_addr,
	input      [28:0] n_ddr_addr,
	input       [2:0] n_fc,
	input             n_rw, n_ci, n_burst,
	input       [3:0] n_be,
	input      [31:0] n_wdata,
	output reg        n_valid, n_last,
	output reg  [1:0] n_word,
	output reg [31:0] n_rdata
);

wire as_asserted = !as_n;
reg as_d;
reg n_active, n_emit, n_rw_q, n_ci_q, n_prog_q;
reg [28:1] n_line_q;
reg [1:0] n_pos;
reg [2:0] n_left;
wire use_native = n_active || (NATIVE_PORT && n_req && as_n);
wire prog = use_native ? (n_active ? n_prog_q : n_fc[1:0] == 2'b10) : fc[1:0] == 2'b10;
wire access_ci = use_native ? (n_active ? n_ci_q : n_ci) : ci;
wire access_rw = n_active ? n_rw_q : rw;
wire access_active = n_active || (sel && as_asserted);


//---------------------------------------------------------------------------
// line buffers: 0 data, 1 program
//---------------------------------------------------------------------------
reg        lb_valid [0:1];
reg        lb_once  [0:1];        // valid only for the cycle that requested the fill
reg [28:1] lb_line  [0:1];        // DDR3 word address without the half bit
reg [31:0] lb_d     [0:1][0:3];   // longwords in address order

wire [28:1] cur_line = use_native ? (n_active ? n_line_q : n_ddr_addr[28:1]) : ddr_addr[28:1];
wire        hit_d    = lb_valid[0] && (lb_line[0] == cur_line);
wire        hit_p    = lb_valid[1] && (lb_line[1] == cur_line);
wire        once_cur = prog ? lb_once[1] : lb_once[0];
// a cache-inhibited read is served only by a line fetched for it
wire        rd_hit   = (prog ? hit_p : hit_d) && (!access_ci || once_cur);

//---------------------------------------------------------------------------
// line reads
//---------------------------------------------------------------------------
reg        rd_pend;               // a line read is in flight
reg        rd_ent;                // the buffer it fills
reg        rd_half;               // next beat expected
reg        rd_drop;               // it belongs to a cycle a reset abandoned

assign rsp_re = rd_pend && !rsp_rempty;

// longwords of a beat: word k at bits 16k+15..16k, long = {word 2m, word 2m+1}
function [31:0] beat_long; input [63:0] b; input m;
	begin beat_long = m ? {b[47:32], b[63:48]} : {b[15:0], b[31:16]}; end endfunction

//---------------------------------------------------------------------------
// the cycle: STERM, CBACK, burst beats (the slave timing of UM Figure 7-45)
//---------------------------------------------------------------------------
wire wr_room  = (cmd_wlevel <= 4'd6);             // a push may still be pending
// Pin acknowledgements have a half-cycle path to the write capture. They
// must not depend on the native request/address mux, even when no native
// transfer can be accepted while AS is asserted.
wire pin_prog = fc[1:0] == 2'b10;
wire pin_hit_d = lb_valid[0] && lb_line[0] == ddr_addr[28:1];
wire pin_hit_p = lb_valid[1] && lb_line[1] == ddr_addr[28:1];
wire pin_once = pin_prog ? lb_once[1] : lb_once[0];
wire pin_rd_hit = (pin_prog ? pin_hit_p : pin_hit_d) && (!ci || pin_once);
wire ready    = rw ? pin_rd_hit : wr_room;
assign sterm_n = !(sel && as_asserted && !n_active && ready);
assign cback_n = !(sel && as_asserted);

reg  [1:0] beat_idx;
reg        burst_active, sterm_rec;
always @(posedge clk) sterm_rec <= sel && !sterm_n && as_asserted && rw && (!cbreq_n || burst_active);
always @(negedge clk) begin
	if (!as_asserted) begin beat_idx <= a[3:2]; burst_active <= 1'b0; end
	else if (sterm_rec) begin burst_active <= 1'b1; beat_idx <= beat_idx + 2'd1; end
end
assign d_i = lb_d[fc[1:0] == 2'b10][beat_idx];

//---------------------------------------------------------------------------
// writes: the data is captured on the falling edge after STERM (as the
// memory would latch it), merged into the line buffers and posted
//---------------------------------------------------------------------------
// byte lanes of a 32-bit port (UM Table 7-7): siz bytes from a[1:0], within the longword
wire [2:0] nbytes = (siz == 2'b00) ? 3'd4 : {1'b0, siz};
function [3:0] lanes; input [1:0] off; input [2:0] n;
	reg [3:0] m;
	begin
		case (n)
			3'd1: m = 4'b1000;
			3'd2: m = 4'b1100;
			3'd3: m = 4'b1110;
			default: m = 4'b1111;
		endcase
		lanes = m >> off;     // bit 3 = byte at offset 0 (D31-D24)
	end
endfunction

reg        wcap;               // captured, not yet posted
reg        wcap_done;          // this cycle's write is captured
reg  [3:0] w_lanes;
reg [31:0] w_data;
reg [28:0] w_addr;
reg  [1:0] w_long;             // longword within the line
reg wcap_ack;
always @(negedge clk) begin
	if (wcap_ack) wcap <= 1'b0;
	if (!as_asserted) wcap_done <= 1'b0;
	else if (sel && !rw && !sterm_n && d_oe && !wcap_done) begin
		wcap <= 1'b1; wcap_done <= 1'b1;
		w_lanes <= lanes(a[1:0], nbytes);
		w_data <= d_o;
		w_addr <= ddr_addr;
		w_long <= a[3:2];
	end
end

function [31:0] merge; input [31:0] old; input [31:0] nw; input [3:0] l;
	begin
		merge = {l[3] ? nw[31:24] : old[31:24], l[2] ? nw[23:16] : old[23:16],
		         l[1] ? nw[15:8]  : old[15:8],  l[0] ? nw[7:0]   : old[7:0]};
	end endfunction

//---------------------------------------------------------------------------
// the Fast RAM cache: 512 lines of 16 bytes, direct mapped.  Index = DDR3
// line address bits 9..1, tag = bits 28..10; one tag RAM {valid, tag} and
// one 32-bit data RAM per longword of the line (byte enables).
//---------------------------------------------------------------------------
localparam L_IDLE = 2'd0, L_LOOK = 2'd1, L_UPD = 2'd2;
reg  [1:0] l2s;
reg        sweeping;               // tags are being cleared, sw_idx next
reg  [8:0] sw_idx;
reg        lk_ent;                 // the lookup in progress fills this buffer
reg [28:1] lk_line;
reg  [8:0] u_idx;                  // the posted write whose tag is being read
reg [18:0] u_tag;
reg  [1:0] u_long;
reg  [3:0] u_lanes;
reg [31:0] u_data;
reg        f_alloc;                // the line read in flight allocates when it completes
reg        f_pend;                 // a completed fill waits to be written into the cache
reg  [8:0] f_idx;
reg [18:0] f_tag;
reg        f_ent;

wire [19:0] l2_tag_q;
wire [31:0] l2_d_q [0:3];
// the fill write takes the RAMs for a clock: it waits for a write update's
// data write, and posting and new lookups wait for it (a read of what is
// being written would return the old contents)
wire        f_wr     = f_pend && (l2s != L_UPD) && !clear && !rst;
wire        post_now = wcap && !wcap_ack && !f_wr;
wire        rd_miss  = access_active && access_rw && !(n_active && n_emit) && !rd_hit && !rd_pend && !wcap && cmd_wlevel <= 4'd7;
wire        look_go  = rd_miss && !access_ci && !clear && !sweeping && (l2s == L_IDLE) && !f_pend;
wire        ddr_go   = rd_miss && (access_ci || clear || sweeping) && (l2s != L_LOOK);
wire        look_hit = (l2s == L_LOOK) && !sweeping && !clear && l2_tag_q[19] && (l2_tag_q[18:0] == lk_line[28:10]);
wire        upd_hit  = (l2s == L_UPD) && !sweeping && !clear && !rst && l2_tag_q[19] && (l2_tag_q[18:0] == u_tag);
assign n_ready = NATIVE_PORT && !rst && as_n && !as_d && !n_active &&
                 !rd_pend && !wcap && !f_pend && l2s == L_IDLE &&
                 (n_rw ? cmd_wlevel <= 4'd7 : wr_room);
wire native_take = n_req && n_ready;
wire native_post = native_take && !n_rw;
wire [28:0] post_addr = post_now ? w_addr : n_ddr_addr;
wire [1:0] post_long = post_now ? w_long : n_addr[3:2];
wire [3:0] post_lanes = post_now ? w_lanes : n_be;
wire [31:0] post_data = post_now ? w_data : n_wdata;
// DDR packing swaps the two 16-bit words of a big-endian longword.
wire [7:0] post_be = post_long[0] ? {post_lanes[1:0], post_lanes[3:2], 4'd0} :
                                                  {4'd0, post_lanes[1:0], post_lanes[3:2]};
wire [63:0] post_data64 = post_long[0] ? {post_data[15:0], post_data[31:16], 32'd0} :
                                                     {32'd0, post_data[15:0], post_data[31:16]};
wire [8:0] l2_ra = post_now ? w_addr[9:1] : native_take ? n_ddr_addr[9:1] : cur_line[9:1];

// Return the requested longword first, then wrap through the other three.
task native_reply;
 input [31:0] value;
 input [1:0] word_index;
 input [2:0] remaining;
 begin
  n_valid <= 1'b1; n_rdata <= value; n_word <= word_index;
  n_last <= remaining == 3'd1;
  n_pos <= word_index + 2'd1;
  n_left <= remaining - 3'd1;
  n_active <= remaining != 3'd1;
  n_emit <= remaining != 3'd1;
 end
endtask

wire        tag_we   = sweeping || f_wr;
wire  [8:0] tag_wa   = sweeping ? sw_idx : f_idx;
wire [19:0] tag_wd   = sweeping ? 20'd0  : {1'b1, f_tag};

ap020_l2ram #(.AW(9), .DW(20)) l2_tag (
	.clk(clk), .we(tag_we), .wa(tag_wa), .wd(tag_wd), .ra(l2_ra), .q(l2_tag_q)
);
genvar gl;
generate for (gl = 0; gl < 4; gl = gl + 1) begin : g_l2d
	wire dwe = (f_wr && !sweeping) || (upd_hit && u_long == gl);
	ap020_l2ram_be #(.AW(9)) l2_data (
		.clk(clk), .we(dwe), .wa(f_wr ? f_idx : u_idx),
		.be(f_wr ? 4'b1111 : u_lanes), .wd(f_wr ? lb_d[f_ent][gl] : u_data),
		.ra(l2_ra), .q(l2_d_q[gl])
	);
end endgenerate

//---------------------------------------------------------------------------
// sequencing (processor clock)
//---------------------------------------------------------------------------
integer e, k;
always @(posedge clk) begin
	cmd_we <= 1'b0;
	wcap_ack <= 1'b0;
	n_valid <= 1'b0;
	as_d <= access_active;
	// the end of a cycle drops lines that were fetched for it alone
	if (as_d && !access_active)
		for (e = 0; e < 2; e = e + 1)
			if (lb_once[e] && !(rd_pend && rd_ent == e)) begin lb_valid[e] <= 1'b0; lb_once[e] <= 1'b0; end
	// the cache sweep: one tag per clock
	if (sweeping) begin
		sw_idx <= sw_idx + 9'd1;
		if (sw_idx == 9'd511) sweeping <= 1'b0;
	end
	if (rst) begin
		n_active <= 1'b0; n_emit <= 1'b0;
		for (e = 0; e < 2; e = e + 1) begin lb_valid[e] <= 1'b0; lb_once[e] <= 1'b0; end
		// a line read still in flight completes into nothing
		if (rd_pend) rd_drop <= 1'b1;
		sweeping <= 1'b1; sw_idx <= 9'd0;
		l2s <= L_IDLE; f_pend <= 1'b0; f_alloc <= 1'b0;
	end else begin
		// cache maintenance: the buffers are emptied; a fill in flight
		// serves only the cycle waiting for it; the cache is swept
		if (clear) begin
			for (e = 0; e < 2; e = e + 1) begin
				if ((rd_pend && rd_ent == e) || (l2s == L_LOOK && lk_ent == e)) lb_once[e] <= 1'b1;
				else begin lb_valid[e] <= 1'b0; lb_once[e] <= 1'b0; end
			end
			sweeping <= 1'b1; sw_idx <= 9'd0;
			f_alloc <= 1'b0; f_pend <= 1'b0;
		end
		// Buffered native reads and continuation beats do not traverse the
		// pin-bus sequencer. A cache lookup hit emits its first word below.
		if (n_active && n_rw_q && (n_emit || (rd_hit && !rd_pend && l2s == L_IDLE)))
			native_reply(lb_d[n_prog_q][n_pos], n_pos, n_left);
		// a completed fill is written into the cache (data and tag)
		if (f_wr) f_pend <= 1'b0;
		// a posted write's tag compare: update the cached copy
		if (l2s == L_UPD) l2s <= L_IDLE;
		// a lookup's tag compare: a hit loads the whole line into the
		// buffer; a miss reads it from DDR3 and allocates it
		if (l2s == L_LOOK) begin
			l2s <= L_IDLE;
			if (look_hit) begin
				for (k = 0; k < 4; k = k + 1) lb_d[lk_ent][k] <= l2_d_q[k];
				lb_valid[lk_ent] <= 1'b1;
				lb_once[lk_ent]  <= 1'b0;
				lb_line[lk_ent]  <= lk_line;
				if (n_active) native_reply(l2_d_q[n_pos], n_pos, n_left);
			end else begin
				cmd_we    <= 1'b1;
				cmd_wdata <= {1'b0, lk_line, 1'b0, 8'hFF, 64'd0};
				rd_pend   <= 1'b1;
				rd_ent    <= lk_ent;
				rd_half   <= 1'b0;
				rd_drop   <= 1'b0;
				f_alloc   <= !sweeping && !clear;
				lb_valid[lk_ent] <= 1'b0;
				lb_once[lk_ent]  <= clear;
				lb_line[lk_ent]  <= lk_line;
			end
		end
		// post a captured write (it always fits: STERM waited for room)
		else if (post_now || native_post) begin
			cmd_we    <= 1'b1;
			cmd_wdata <= {1'b1, post_addr, post_be, post_data64};
			wcap_ack <= post_now;
			if (native_post) native_reply(32'd0, n_addr[3:2], 3'd1);
			for (e = 0; e < 2; e = e + 1)
				if (lb_valid[e] && lb_line[e] == post_addr[28:1])
					lb_d[e][post_long] <= merge(lb_d[e][post_long], post_data, post_lanes);
			// its tag is read this clock and compared in the next
			l2s     <= L_UPD;
			u_idx   <= post_addr[9:1];
			u_tag   <= post_addr[28:10];
			u_long  <= post_long;
			u_lanes <= post_lanes;
			u_data  <= post_data;
		end
		else if (native_take) begin
			n_active <= 1'b1; n_emit <= 1'b0;
			n_rw_q <= 1'b1; n_ci_q <= n_ci; n_prog_q <= prog;
			n_line_q <= n_ddr_addr[28:1]; n_pos <= n_addr[3:2];
			n_left <= n_burst ? 3'd4 : 3'd1;
			if (rd_hit && !n_ci && !once_cur && !clear) begin
				native_reply(lb_d[prog][n_addr[3:2]], n_addr[3:2], n_burst ? 3'd4 : 3'd1);
			end else if (!n_ci && !sweeping && !clear) begin
				l2s <= L_LOOK; lk_ent <= prog; lk_line <= n_ddr_addr[28:1];
				lb_valid[prog] <= 1'b0;
			end else begin
				cmd_we <= 1'b1;
				cmd_wdata <= {1'b0, n_ddr_addr[28:1], 1'b0, 8'hFF, 64'd0};
				rd_pend <= 1'b1; rd_ent <= prog; rd_half <= 1'b0; rd_drop <= 1'b0;
				f_alloc <= 1'b0; lb_valid[prog] <= 1'b0;
				lb_once[prog] <= n_ci || clear; lb_line[prog] <= n_ddr_addr[28:1];
			end
		end
		// a read that misses the buffers looks the line up in the cache
		else if (look_go && !f_wr) begin
			l2s     <= L_LOOK;
			lk_ent  <= prog;
			lk_line <= cur_line;
		end
		// cache inhibited, or the cache being swept: straight to DDR3,
		// not allocated
		else if (ddr_go && !f_wr) begin
			cmd_we    <= 1'b1;
			cmd_wdata <= {1'b0, cur_line, 1'b0, 8'hFF, 64'd0};
			rd_pend   <= 1'b1;
			rd_ent    <= prog;
			rd_half   <= 1'b0;
			rd_drop   <= 1'b0;
			f_alloc   <= 1'b0;
			lb_valid[prog] <= 1'b0;
			lb_once[prog]  <= access_ci || clear;
			lb_line[prog]  <= cur_line;
		end
	end
	// the line arrives as two beats (lower half first)
	if (rsp_re) begin
		if (!rd_drop && !rst) begin
			lb_d[rd_ent][{rd_half, 1'b0}] <= beat_long(rsp_rdata, 1'b0);
			lb_d[rd_ent][{rd_half, 1'b1}] <= beat_long(rsp_rdata, 1'b1);
		end
		rd_half <= 1'b1;
		if (rd_half) begin
			rd_pend <= 1'b0;
			rd_drop <= 1'b0;
			if (!rd_drop && !rst) lb_valid[rd_ent] <= 1'b1;
			// allocate: written into the cache from the buffer next clock
			if (!rd_drop && !rst && f_alloc && !clear && !sweeping) begin
				f_pend <= 1'b1;
				f_idx  <= lb_line[rd_ent][9:1];
				f_tag  <= lb_line[rd_ent][28:10];
				f_ent  <= rd_ent;
			end
			f_alloc <= 1'b0;
		end
	end
end

initial begin
	n_active = 0; n_emit = 0; n_rw_q = 1; n_ci_q = 0; n_prog_q = 0;
	n_line_q = 0; n_pos = 0; n_left = 0;
	n_valid = 0; n_last = 0; n_word = 0; n_rdata = 0;
	lb_valid[0] = 1'b0; lb_valid[1] = 1'b0; lb_line[0] = 0; lb_line[1] = 0;
	lb_once[0] = 1'b0; lb_once[1] = 1'b0; as_d = 1'b0;
	for (k = 0; k < 4; k = k + 1) begin lb_d[0][k] = 32'd0; lb_d[1][k] = 32'd0; end
	rd_pend = 1'b0; rd_ent = 1'b0; rd_half = 1'b0; rd_drop = 1'b0;
	wcap = 1'b0; wcap_done = 1'b0; wcap_ack = 1'b0; cmd_we = 1'b0; cmd_wdata = 0;
	beat_idx = 2'd0; burst_active = 1'b0; sterm_rec = 1'b0;
	w_lanes = 4'd0; w_data = 32'd0; w_addr = 29'd0; w_long = 2'd0;
	l2s = L_IDLE; sweeping = 1'b1; sw_idx = 9'd0; f_alloc = 1'b0; f_pend = 1'b0;
	lk_ent = 1'b0; lk_line = 28'd0; f_idx = 9'd0; f_tag = 19'd0; f_ent = 1'b0;
	u_idx = 9'd0; u_tag = 19'd0; u_long = 2'd0; u_lanes = 4'd0; u_data = 32'd0;
end

endmodule
