//--------------------------------------------------------------------------//
// AP040 32-bit line-fill clock-domain bridge                               //
//                                                                          //
// The L1 runs at clk_sys while sdram32_ctrl's line fill port runs at       //
// clk_114 and delivers its four longwords as single-clk_114 strobes,       //
// back to back.  The CPU domain cannot sample those directly -- its clock  //
// is a quarter the rate, so most strobes fall between its edges (and the   //
// cache advances only under ce on top of that).  This bridge collects the  //
// whole burst on the m side, indexed by the beat each strobe names, and    //
// presents the complete line to the cache as a LEVEL: s_done and s_line    //
// hold until the cache drops s_req, the same contract ap040_walker_cdc's   //
// level-held s_ack provides, and for the same reason (see the blind-window //
// history in ap040_mmu.v).                                                 //
//                                                                          //
// Structure follows ap040_walker_cdc: toggle handshakes both ways, all     //
// multi-bit payloads registered and stable before the opposite domain      //
// observes the corresponding toggle, and the s-side reset crossed into     //
// the m domain so a CPU-only reset cannot desync the toggle parity.        //
//--------------------------------------------------------------------------//

module ap040_fill_cdc
(
	// cache / clk_sys side
	input              s_clk,
	input              s_reset_n,
	input              s_req,
	input      [24:4]  s_addr,
	input       [1:0]  s_bsel,
	output reg         s_done,
	output reg [127:0] s_line,      // {beat3, beat2, beat1, beat0}

	// sdram32_ctrl fill port / clk_114 side
	input              m_clk,
	input              m_reset_n,
	output reg         m_req,
	output reg [24:4]  m_addr,
	output reg  [1:0]  m_bsel,
	input      [31:0]  m_dat,
	input       [1:0]  m_beat,
	input              m_strb,
	input              m_ack
);

reg         s_req_toggle;
reg         s_busy;
reg [24:4]  s_addr_hold;
reg  [1:0]  s_bsel_hold;

reg         m_done_toggle;
reg [127:0] m_line;

(* async_reg = "true" *) reg [1:0] s_done_sync;
(* async_reg = "true" *) reg [1:0] m_req_sync;
reg s_done_seen;
reg m_req_seen;
reg m_active;

// Source side: accept exactly one level-held cache request.  The cache
// drops s_req once it has consumed the line, which re-arms the bridge.
always @(posedge s_clk or negedge s_reset_n) begin
	if (!s_reset_n) begin
		s_req_toggle <= 0;
		s_busy       <= 0;
		s_addr_hold  <= 0;
		s_bsel_hold  <= 0;
		s_done_sync  <= 0;
		s_done_seen  <= 0;
		s_done       <= 0;
		s_line       <= 0;
	end
	else begin
		s_done_sync <= {s_done_sync[0], m_done_toggle};

		// s_done is LEVEL-HELD until the cache drops s_req: the cache
		// samples only under its clock enable, and a pulse landing in a
		// ce-gated blind window would be lost, hanging the fill.
		if (!s_req) s_done <= 0;

		if (!s_busy && s_req) begin
			s_addr_hold  <= s_addr;
			s_bsel_hold  <= s_bsel;
			s_req_toggle <= ~s_req_toggle;
			s_busy       <= 1;
		end

		if (s_busy && (s_done_sync[1] != s_done_seen)) begin
			s_done_seen <= s_done_sync[1];
			s_line      <= m_line;
			s_done      <= 1;
		end

		if (s_busy && !s_req && (s_done_sync[1] == s_done_seen))
			s_busy <= 0;
	end
end

// The s-side reset crossed into the m domain, exactly as in
// ap040_walker_cdc: a CPU-only reset must clear BOTH sides or the toggle
// parity desyncs and the first post-reset fill is answered with a stale
// line.  Async assert, release synchronized into m_clk.
(* async_reg = "true" *) reg [1:0] m_srst_sync;
always @(posedge m_clk or negedge s_reset_n) begin
	if (!s_reset_n) m_srst_sync <= 2'b00;
	else            m_srst_sync <= {m_srst_sync[0], 1'b1};
end
wire m_rst_n = m_reset_n & m_srst_sync[1];

// Destination side: run one fill-port transaction per request toggle.  The
// controller strobes each longword with its beat index; the line register
// collects them in place, so the burst order (wrapped by m_bsel) never
// matters here or above.
always @(posedge m_clk or negedge m_rst_n) begin
	if (!m_rst_n) begin
		m_req_sync    <= 0;
		m_req_seen    <= 0;
		m_done_toggle <= 0;
		m_line        <= 0;
		m_req         <= 0;
		m_addr        <= 0;
		m_bsel        <= 0;
		m_active      <= 0;
	end
	else begin
		m_req_sync <= {m_req_sync[0], s_req_toggle};

		if (!m_active && (m_req_sync[1] != m_req_seen)) begin
			m_req_seen <= m_req_sync[1];
			m_addr     <= s_addr_hold;
			m_bsel     <= s_bsel_hold;
			m_req      <= 1;
			m_active   <= 1;
		end

		if (m_active && m_strb)
			m_line[m_beat*32 +: 32] <= m_dat;

		if (m_active && m_ack) begin
			m_req         <= 0;
			m_active      <= 0;
			m_done_toggle <= ~m_done_toggle;
		end
	end
end

endmodule
