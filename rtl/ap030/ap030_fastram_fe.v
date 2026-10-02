//--------------------------------------------------------------------------//
// AP030 - MC68030 compatible CPU                                           //
//                                                                          //
// ap030_fastram_fe.v - Fast RAM on the 68030 bus as a 32-bit synchronous   //
// port (UM 7.3.2, 7.3.7): STERM termination, burst fills with CBACK.  Runs //
// on the processor clock; the DDR3 side (ap030_fastram_be) is reached      //
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
// processor's on-chip caches and CACR are unchanged; this cache is below   //
// the MMU, on physical addresses.                                          //
//                                                                          //
// Writes are posted: STERM as soon as the command FIFO has room.  They     //
// update any buffered copy of their line and the cache's copy (write      //
// through, no allocation), and they reach DDR3 in order with the reads,   //
// so a read never overtakes a write to the same address.                   //
//                                                                          //
// Coherence: the buffers and the cache follow the processor's cache       //
// maintenance -- a CACR clear of either cache (CI, CEI, CD, CED) empties   //
// the buffers and sweeps the cache invalid (512 clocks, reads go to DDR3   //
// meanwhile), as does a processor reset -- and a cache-inhibited access    //
// (CIOUT) is never answered from a buffered line or the cache: it fetches  //
// the line, which is not allocated and is dropped when that cycle ends.  A //
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

module ap030_fastram_fe
(
	input             clk,
	input             rst,

	// the 68030 bus
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
	output            rsp_re
);

wire as_asserted = !as_n;
wire prog = (fc[1:0] == 2'b10);

//---------------------------------------------------------------------------
// line buffers: 0 data, 1 program
//---------------------------------------------------------------------------
reg        lb_valid [0:1];
reg        lb_once  [0:1];        // valid only for the cycle that requested the fill
reg [28:1] lb_line  [0:1];        // DDR3 word address without the half bit
reg [31:0] lb_d     [0:1][0:3];   // longwords in address order

wire [28:1] cur_line = ddr_addr[28:1];
wire        hit_d    = lb_valid[0] && (lb_line[0] == cur_line);
wire        hit_p    = lb_valid[1] && (lb_line[1] == cur_line);
wire        once_cur = prog ? lb_once[1] : lb_once[0];
// a cache-inhibited read is served only by a line fetched for it
wire        rd_hit   = (prog ? hit_p : hit_d) && (!ci || once_cur);

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
wire ready    = rw ? rd_hit : wr_room;
assign sterm_n = !(sel && as_asserted && ready);
assign cback_n = !(sel && as_asserted);

reg  [1:0] beat_idx;
reg        burst_active, sterm_rec;
always @(posedge clk) sterm_rec <= sel && !sterm_n && as_asserted && rw && (!cbreq_n || burst_active);
always @(negedge clk) begin
	if (!as_asserted) begin beat_idx <= a[3:2]; burst_active <= 1'b0; end
	else if (sterm_rec) begin burst_active <= 1'b1; beat_idx <= beat_idx + 2'd1; end
end
assign d_i = lb_d[prog][beat_idx];

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

// byte enables and data of the 64-bit DDR3 word for a longword at w_long[0]
// be bit 2k+1 = even byte of word k, 2k = odd byte; a longword is words
// 2m (offsets 0,1) and 2m+1 (offsets 2,3); w_lanes bit 3 is offset 0
wire [7:0]  be_long = {4'd0, w_lanes[1], w_lanes[0], w_lanes[3], w_lanes[2]};
wire [63:0] w_data64 = w_long[0] ? {w_data[15:0], w_data[31:16], 32'd0} : {32'd0, w_data[15:0], w_data[31:16]};
wire [7:0]  w_be8    = w_long[0] ? {be_long[3:0], 4'd0} : {4'd0, be_long[3:0]};

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
wire        f_wr     = f_pend && (l2s != L_UPD);
wire        post_now = wcap && !wcap_ack && !f_wr;
wire        rd_miss  = sel && as_asserted && rw && !rd_hit && !rd_pend && !wcap && cmd_wlevel <= 4'd7;
wire        look_go  = rd_miss && !ci && !sweeping && (l2s == L_IDLE) && !f_pend;
wire        ddr_go   = rd_miss && (ci || sweeping) && (l2s != L_LOOK);
wire        look_hit = (l2s == L_LOOK) && !sweeping && !clear && l2_tag_q[19] && (l2_tag_q[18:0] == lk_line[28:10]);
wire        upd_hit  = (l2s == L_UPD) && !sweeping && l2_tag_q[19] && (l2_tag_q[18:0] == u_tag);
wire  [8:0] l2_ra    = post_now ? w_addr[9:1] : cur_line[9:1];

wire        tag_we   = sweeping || f_wr;
wire  [8:0] tag_wa   = sweeping ? sw_idx : f_idx;
wire [19:0] tag_wd   = sweeping ? 20'd0  : {1'b1, f_tag};

ap030_l2ram #(.AW(9), .DW(20)) l2_tag (
	.clk(clk), .we(tag_we), .wa(tag_wa), .wd(tag_wd), .ra(l2_ra), .q(l2_tag_q)
);
genvar gl;
generate for (gl = 0; gl < 4; gl = gl + 1) begin : g_l2d
	wire dwe = (f_wr && !sweeping) || (upd_hit && u_long == gl);
	ap030_l2ram_be #(.AW(9)) l2_data (
		.clk(clk), .we(dwe), .wa(f_wr ? f_idx : u_idx),
		.be(f_wr ? 4'b1111 : u_lanes), .wd(f_wr ? lb_d[f_ent][gl] : u_data),
		.ra(l2_ra), .q(l2_d_q[gl])
	);
end endgenerate

//---------------------------------------------------------------------------
// sequencing (processor clock)
//---------------------------------------------------------------------------
integer e, k;
reg as_d;
always @(posedge clk) begin
	cmd_we <= 1'b0;
	wcap_ack <= 1'b0;
	as_d <= as_asserted;
	// the end of a cycle drops lines that were fetched for it alone
	if (as_d && !as_asserted)
		for (e = 0; e < 2; e = e + 1)
			if (lb_once[e] && !(rd_pend && rd_ent == e)) begin lb_valid[e] <= 1'b0; lb_once[e] <= 1'b0; end
	// the cache sweep: one tag per clock
	if (sweeping) begin
		sw_idx <= sw_idx + 9'd1;
		if (sw_idx == 9'd511) sweeping <= 1'b0;
	end
	if (rst) begin
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
				if (rd_pend && rd_ent == e) lb_once[e] <= 1'b1;
				else begin lb_valid[e] <= 1'b0; lb_once[e] <= 1'b0; end
			end
			sweeping <= 1'b1; sw_idx <= 9'd0;
			f_alloc <= 1'b0; f_pend <= 1'b0;
		end
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
			end else begin
				cmd_we    <= 1'b1;
				cmd_wdata <= {1'b0, lk_line, 1'b0, 8'hFF, 64'd0};
				rd_pend   <= 1'b1;
				rd_ent    <= lk_ent;
				rd_half   <= 1'b0;
				rd_drop   <= 1'b0;
				f_alloc   <= !sweeping && !clear;
				lb_valid[lk_ent] <= 1'b0;
				lb_once[lk_ent]  <= 1'b0;
				lb_line[lk_ent]  <= lk_line;
			end
		end
		// post a captured write (it always fits: STERM waited for room)
		else if (post_now) begin
			cmd_we    <= 1'b1;
			cmd_wdata <= {1'b1, w_addr, w_be8, w_data64};
			wcap_ack  <= 1'b1;
			for (e = 0; e < 2; e = e + 1)
				if (lb_valid[e] && lb_line[e] == w_addr[28:1])
					lb_d[e][w_long] <= merge(lb_d[e][w_long], w_data, w_lanes);
			// its tag is read this clock and compared in the next
			l2s     <= L_UPD;
			u_idx   <= w_addr[9:1];
			u_tag   <= w_addr[28:10];
			u_long  <= w_long;
			u_lanes <= w_lanes;
			u_data  <= w_data;
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
			lb_once[prog]  <= ci;
			lb_line[prog]  <= cur_line;
		end
	end
	// the line arrives as two beats (lower half first)
	if (rsp_re) begin
		if (!rd_drop) begin
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
