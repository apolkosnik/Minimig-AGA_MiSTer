// Stage 0 of doc_AP040_PIPELINE_CACHES.md: the instruction and data caches'
// arrays and the ATC fitted alone, with the hit paths the IMU and DMU will
// have, so their block RAM count and the two-cycle hit's timing are known
// before any control is written. Not part of the core: tests/ap040/
// pipe_synth/run.sh <work> ap040_pipe_cache_fit.
//
// Each port's hit, from registered inputs to a registered result:
//   cycle 1  the logical address is registered; the ATC row and the cache
//            set (untranslated bits) are read in parallel
//   cycle 2  ATC tag compare -> physical page -> the four cache tag
//            compares -> way select -> the result register
// which is the slow case, translation on and no recent-hit copy. Fills,
// store hits and snoops are driven from registered inputs so every RAM
// port is used as the units will use it.

module ap040_pipe_cache_fit
(
	input             clk,

	// instruction side
	input      [31:0] i_la,
	input             i_sup,
	output reg [63:0] i_q,
	output reg        i_hit,
	input       [5:0] if_set,
	input             if_half,
	input       [1:0] if_way,
	input      [63:0] if_data,
	input             if_data_we,
	input      [87:0] if_tags,
	input             if_tags_we,
	input       [5:0] is_set,
	output reg [87:0] is_tags,

	// data side
	input      [31:0] d_la,
	input             d_sup,
	output reg [31:0] d_q,
	output reg        d_hit,
	output reg  [1:0] d_hway,
	input       [1:0] ds_way,     // store hit, into the way found two cycles before
	input      [31:0] ds_data,
	input       [3:0] ds_be,
	input             ds_we,
	input       [7:0] ds_addr,
	input       [7:0] db_addr,
	input       [1:0] db_way,
	input      [31:0] db_data,
	input             db_we,
	output reg[127:0] db_q,
	input       [5:0] dt_set,
	input      [87:0] dt_tags,
	input             dt_we,
	output reg [87:0] dt_q,
	input       [5:0] ds_set,
	output reg [87:0] ds_tags,

	// ATC fill
	input       [4:0] af_row,
	input     [183:0] af_row_data,
	input             af_we
);

// registered inputs, as the units' requests will be
reg [31:0] i_la_r, d_la_r;
reg        i_sup_r, d_sup_r;
reg  [5:0] if_set_r, is_set_r, dt_set_r, ds_set_r;
reg        if_half_r, if_data_we_r, if_tags_we_r, ds_we_r, db_we_r, dt_we_r, af_we_r;
reg  [1:0] if_way_r, ds_way_r, db_way_r;
reg [63:0] if_data_r;
reg [87:0] if_tags_r, dt_tags_r;
reg [31:0] ds_data_r, db_data_r;
reg  [3:0] ds_be_r;
reg  [7:0] ds_addr_r, db_addr_r;
reg  [4:0] af_row_r;
reg[183:0] af_row_data_r;
always @(posedge clk) begin
	i_la_r <= i_la; i_sup_r <= i_sup; d_la_r <= d_la; d_sup_r <= d_sup;
	if_set_r <= if_set; if_half_r <= if_half; if_way_r <= if_way; if_data_r <= if_data;
	if_data_we_r <= if_data_we; if_tags_r <= if_tags; if_tags_we_r <= if_tags_we; is_set_r <= is_set;
	ds_way_r <= ds_way; ds_data_r <= ds_data; ds_be_r <= ds_be; ds_we_r <= ds_we; ds_addr_r <= ds_addr;
	db_addr_r <= db_addr; db_way_r <= db_way; db_data_r <= db_data; db_we_r <= db_we;
	dt_set_r <= dt_set; dt_tags_r <= dt_tags; dt_we_r <= dt_we; ds_set_r <= ds_set;
	af_row_r <= af_row; af_row_data_r <= af_row_data; af_we_r <= af_we;
end

// the ATC: ap040_mmu.v's row RAM, instruction lookups on port A, data
// lookups on port B (a fill takes port B)
wire [183:0] atc_i_row, atc_d_row;
dpram #(.addr_width(5), .data_width(184)) atc
(
	.clock     (clk),
	.address_a ({1'b1, i_la_r[15:12]}),
	.data_a    (184'd0),
	.wren_a    (1'b0),
	.q_a       (atc_i_row),
	.address_b (af_we_r ? af_row_r : {1'b0, d_la_r[15:12]}),
	.data_b    (af_row_data_r),
	.wren_b    (af_we_r),
	.q_b       (atc_d_row)
);

// the caches
wire [255:0] i_data;
wire  [87:0] i_tags, i_stags;
ap040_pipe_icache_arr icache
(
	.clk (clk),
	.l_set (i_la_r[9:4]), .l_half (i_la_r[3]), .l_data (i_data), .l_tags (i_tags),
	.f_set (if_set_r), .f_half (if_half_r), .f_way (if_way_r), .f_data (if_data_r),
	.f_data_we (if_data_we_r), .f_tags (if_tags_r), .f_tags_we (if_tags_we_r),
	.s_set (is_set_r), .s_tags (i_stags)
);

wire [127:0] d_data, d_bdata;
wire  [87:0] d_tags, d_btags, d_stags;
ap040_pipe_dcache_arr dcache
(
	.clk (clk),
	.a_addr (ds_we_r ? ds_addr_r : d_la_r[9:2]), .a_data (d_data), .a_way (ds_way_r),
	.a_wdata (ds_data_r), .a_be (ds_be_r), .a_we (ds_we_r),
	.b_addr (db_addr_r), .b_data (d_bdata), .b_way (db_way_r), .b_wdata (db_data_r), .b_we (db_we_r),
	.ta_set (d_la_r[9:4]), .ta_tags (d_tags),
	.tb_set (dt_set_r), .tb_tags (d_btags), .tb_wtags (dt_tags_r), .tb_we (dt_we_r),
	.s_set (ds_set_r), .s_tags (d_stags)
);

// second cycle: the addresses as they were when the RAMs were read
reg [31:0] i_la_q, d_la_q;
reg        i_sup_q, d_sup_q;
always @(posedge clk) begin
	i_la_q <= i_la_r; i_sup_q <= i_sup_r; d_la_q <= d_la_r; d_sup_q <= d_sup_r;
end

// ATC compare: {resident, tag[16:0], pa[19:0], attr[7:0]} per 46-bit way
function [20:0] atc_xl;    // {hit, pa[19:0]}
	input [183:0] row;
	input  [16:0] tag;
	integer w;
	reg     hit;
	reg [19:0] pa;
	begin
		hit = 1'b0; pa = 20'd0;
		for (w = 0; w < 4; w = w + 1)
			if (row[w*46+45] && row[w*46+28 +: 17] == tag) begin
				hit = 1'b1; pa = row[w*46+8 +: 20];
			end
		atc_xl = {hit, pa};
	end
endfunction

wire [20:0] i_xl = atc_xl(atc_i_row, {i_sup_q, i_la_q[31:16]});
wire [20:0] d_xl = atc_xl(atc_d_row, {d_sup_q, d_la_q[31:16]});
wire [21:0] i_ptag = {i_xl[19:0], i_la_q[11:10]};
wire [21:0] d_ptag = {d_xl[19:0], d_la_q[11:10]};

// cache tag compare and way select
reg        i_h, d_h;
reg [63:0] i_sel;
reg [31:0] d_sel;
reg  [1:0] d_w;
integer k;
always @(*) begin
	i_h = 1'b0; i_sel = 64'd0; d_h = 1'b0; d_sel = 32'd0; d_w = 2'd0;
	for (k = 0; k < 4; k = k + 1) begin
		if (i_tags[k*22 +: 22] == i_ptag) begin i_h = 1'b1; i_sel = i_data[k*64 +: 64]; end
		if (d_tags[k*22 +: 22] == d_ptag) begin d_h = 1'b1; d_sel = d_data[k*32 +: 32]; d_w = k[1:0]; end
	end
end

always @(posedge clk) begin
	i_q <= i_sel; i_hit <= i_xl[20] && i_h;
	d_q <= d_sel; d_hit <= d_xl[20] && d_h; d_hway <= d_w;
	db_q <= d_bdata; dt_q <= d_btags; is_tags <= i_stags; ds_tags <= d_stags;
end

endmodule
