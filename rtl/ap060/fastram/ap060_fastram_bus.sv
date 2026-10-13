//--------------------------------------------------------------------------//
// AP68060 - pipelined MC68060                                              //
//                                                                          //
// ap060_fastram_bus.sv - Fast RAM as a slave on the 68060 bus (MC68060UM   //
// section 7): terminates the processor's transfers to the Fast RAM window  //
// through the native request port of ap030_fastram_fe.                     //
//                                                                          //
//   * a read is one native request: a line (SIZ = line, a burst or a      //
//     MOVE16) asks for the line, the four long words come back requested   //
//     one first and wrapping, the order of the 68060's burst (7.7.2);      //
//     anything else asks for one long word and takes its bytes            //
//   * a write is posted beat by beat: each long word of a line write, or  //
//     the one long word of a smaller write with its byte selects          //
//     BS3-BS0, is a native write; TA once the front end took it            //
//   * TA only: no TEA, TRA, TBI or TCI.  CIOUT goes to the front end (an   //
//     inhibited read is served by a line fetched for it alone)             //
//                                                                          //
// The processor samples terminations only on bus clock edges (bclk_en),   //
// not in its ignored clocks (7.14.1: the primary count before the first   //
// sample of a transfer, the secondary before each later beat of a line)   //
// and not in the clock of an extra data write hold (7.14.3); the adapter  //
// asserts TA only for a clock that ends in a sampling edge.  The native   //
// port's responses do not wait: a read's long words are buffered (4).     //
//                                                                          //
// sel and ddr_addr are the integration's decode of the address on the    //
// bus with TS (the window and its DDR3 64-bit word address); every beat   //
// of a line stays in the line ddr_addr names.                             //
//--------------------------------------------------------------------------//

module ap060_fastram_bus
(
	input  logic        clk,
	input  logic        rst,
	input  logic        bclk_en,

	// the processor's reset modes (7.14)
	input  logic        m_ign,
	input  logic [15:0] m_cnt,
	input  logic        m_hold,

	// the 68060 bus
	input  logic [31:0] a,
	input  logic        rw_n,
	input  logic  [1:0] siz,
	input  logic  [1:0] tt,
	input  logic  [2:0] tm,
	input  logic  [3:0] bs_n,          // bs_n[0] = BS0 (D31-D24)
	input  logic        ts_n,
	input  logic        ciout_n,
	input  logic [31:0] d_cpu,         // the processor's write data
	input  logic        sel,           // a is in the window (with TS)
	input  logic [28:0] ddr_addr,      // its DDR3 64-bit word address
	output logic        ta_n,
	output logic [31:0] d_o,           // read data
	output logic        d_oe,          // read data driven (a read in progress)
	output logic        busy,

	// ap030_fastram_fe's native port
	output logic        n_req,
	input  logic        n_ready,
	output logic [31:0] n_addr,
	output logic [28:0] n_ddr_addr,
	output logic  [2:0] n_fc,
	output logic        n_rw,
	output logic        n_ci,
	output logic        n_burst,
	output logic  [3:0] n_be,
	output logic [31:0] n_wdata,
	input  logic        n_valid,
	input  logic        n_last,
	input  logic  [1:0] n_word,
	input  logic [31:0] n_rdata
);

// the ignore state count of a beat (7.14.1)
function automatic logic [3:0] icount(input logic rd, input logic secondary);
	if (!m_ign) icount = 4'd0;
	else case ({rd, secondary})
		2'b10:   icount = m_cnt[15:12];
		2'b11:   icount = m_cnt[11:8];
		2'b00:   icount = m_cnt[7:4];
		default: icount = m_cnt[3:0];
	endcase
endfunction

logic        act;          // a transfer is ours
logic        rd, line;
logic [31:0] base;         // the address with TS
logic [28:1] dline;        // its DDR3 line
logic  [1:0] beat;         // beats done
logic  [4:0] skip;         // bus clock edges ahead that are not sampled
logic        ta_q;         // TA asserted for the edge ahead
// write beats: the data valid (dv_wait edges after the beat began), posted
logic  [1:0] dv_wait;
logic        posted;
// read data: four long words in arrival order
logic [31:0] rq [4];
logic  [2:0] rq_n;
logic  [1:0] rq_rd, rq_wr;
logic        rq_req;       // the read's native request is outstanding

wire  [1:0]  lw   = base[3:2] + beat;               // the long word this beat moves
wire         last = !line || beat == 2'd3;
wire         ts_hit = !ts_n && sel && tt != 2'd3;

assign busy = act;
assign ta_n = !ta_q;
assign d_oe = act && rd;

always_ff @(posedge clk) begin
	// the native port: a request stays until the front end takes it
	if (n_req && n_ready) begin
		n_req  <= 1'b0;
		if (!n_rw) posted <= 1'b1;
	end
	// read responses (writes answer too: not data)
	if (n_valid && act && rd && !n_req) begin
		rq[rq_wr] <= n_rdata;
		rq_wr     <= rq_wr + 2'd1;
	end

	if (rst) begin
		act  <= 1'b0;
		ta_q <= 1'b0;
		n_req <= 1'b0;
		rq_n <= 3'd0; rq_rd <= 2'd0; rq_wr <= 2'd0;
	end
	else if (bclk_en) begin
		logic done, take;
		logic [2:0] n;
		ta_q <= 1'b0;
		n = rq_n + ((n_valid && act && rd && !n_req) ? 3'd1 : 3'd0);
		take = 1'b0;
		// the processor sampled our TA on this edge: the beat is done
		done = act && ta_q;
		if (done) begin
			if (last) act <= 1'b0;
			else begin
				beat    <= beat + 2'd1;
				// the next beat: its ignored clocks, the hold clock of a write
				skip    <= {1'b0, icount(rd, 1'b1)} + ((!rd && m_hold) ? 5'd1 : 5'd0);
				// (its data is on the bus from the next edge, a clock later
				// after the hold clock)
				dv_wait <= (!rd && m_hold) ? 2'd1 : 2'd0;
				posted  <= 1'b0;
				// a read's next long word already here and no ignored clock
				// before its sample: TA again for the very next edge (a line
				// at one beat a clock, 7.7.2), not a clock later
				if (rd && icount(rd, 1'b1) == 4'd0 && n != 3'd0) begin
					ta_q <= 1'b1;
					take = 1'b1;
				end
			end
		end
		else if (act) begin
			// a write beat's data is on the bus: post it
			if (!rd) begin
				if (dv_wait != 2'd0) dv_wait <= dv_wait - 2'd1;
				else if (!posted && !n_req) begin
					n_req      <= 1'b1;
					n_rw       <= 1'b0;
					n_burst    <= 1'b0;
					n_addr     <= {base[31:4], lw, 2'b00};
					n_ddr_addr <= {dline, lw[1]};
					n_be       <= line ? 4'hF : ~{bs_n[0], bs_n[1], bs_n[2], bs_n[3]};
					n_wdata    <= d_cpu;
				end
			end
			// TA for the edge ahead when it is a sampling edge and the
			// beat can end: the read's long word is here, the write posted
			if (skip != 5'd0) skip <= skip - 5'd1;
			else if (rd ? (n != 3'd0) : (posted && !(n_req && n_ready))) begin
				ta_q  <= 1'b1;
				take  = rd;
			end
		end
		else if (ts_hit) begin
			// a transfer of ours starts: the first sampling edge is the
			// second after this one, after the primary ignored clocks
			act     <= 1'b1;
			rd      <= rw_n;
			line    <= (siz == 2'b11);
			base    <= a;
			dline   <= ddr_addr[28:1];
			beat    <= 2'd0;
			skip    <= {1'b0, icount(rw_n, 1'b0)};
			posted  <= 1'b0;
			dv_wait <= 2'd0;
			n_fc    <= {tm[2], (tm[1:0] == 2'b10) ? 2'b10 : 2'b01};
			n_ci    <= !ciout_n;
			if (rw_n) begin
				n_req      <= 1'b1;
				n_rw       <= 1'b1;
				n_burst    <= (siz == 2'b11);
				n_addr     <= {a[31:2], 2'b00};
				n_ddr_addr <= ddr_addr;
				n_be       <= 4'hF;
			end
		end
		if (take) begin
			// (an empty buffer: the long word arriving now)
			d_o   <= (rq_n == 3'd0) ? n_rdata : rq[rq_rd];
			rq_rd <= rq_rd + 2'd1;
			n     = n - 3'd1;
		end
		rq_n <= n;
	end
	else if (n_valid && act && rd && !n_req)
		rq_n <= rq_n + 3'd1;
end

// synthesis translate_off
// the front end answers a line in the 68060's burst order
logic [1:0] sim_k;
always_ff @(posedge clk) begin
	if (ts_hit && !act && bclk_en) sim_k <= 2'd0;
	if (n_valid && act && rd && !n_req) begin
		if (n_word != base[3:2] + sim_k)
			$display("FAIL: Fast RAM: long word %0d of %08x arrived as word %0d", sim_k, base, n_word);
		sim_k <= sim_k + 2'd1;
	end
end
// synthesis translate_on

initial begin
	act = 1'b0; ta_q = 1'b0; n_req = 1'b0; rq_n = 3'd0; rq_rd = 2'd0; rq_wr = 2'd0;
end

endmodule
