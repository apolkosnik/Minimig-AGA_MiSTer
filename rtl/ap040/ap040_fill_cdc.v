//--------------------------------------------------------------------------//
// AP040 line-fill channel clock-domain bridge (plan X3.4, A1)              //
//                                                                          //
// The cache's fill request (clk_sys) crosses into the RAM controllers'     //
// clock (clk_114) and the line comes back as one 128-bit payload, on the   //
// same toggle handshake ap040_walker_cdc uses: every multi-bit payload is  //
// registered and stable until the opposite domain has observed its        //
// toggle, and the acknowledge to the cache is LEVEL-HELD until the cache   //
// drops its request, so no ce-gated consumer can miss it.                  //
//                                                                          //
// The controller side delivers the line as four ascending longword beats  //
// (m_strb with m_dat, offset 0 first) and pulses m_ack with the last one,  //
// which is sdram32_ctrl's fill port shape and the one ddram_ctrl's fill    //
// port adopts; the bridge collects them.  m_berr, from the controller or   //
// the watchdog in front of it, ends the transfer with s_err instead.       //
//--------------------------------------------------------------------------//

module ap040_fill_cdc
(
	// cache / clk_sys side
	input             s_clk,
	input             s_reset_n,
	input             s_req,
	input      [28:4] s_addr,
	input             s_ddr,
	input             s_bad,
	output reg        s_ack,
	output reg [127:0] s_data,
	output reg        s_err,

	// RAM-controller / clk_114 side
	input             m_clk,
	input             m_reset_n,
	output reg        m_req,
	output reg [28:4] m_addr,
	output reg        m_ddr,
	input             m_strb,
	input      [31:0] m_dat,
	input             m_ack,
	input             m_berr
);

reg         s_req_toggle;
reg         s_busy;
reg  [28:4] s_addr_hold;
reg         s_ddr_hold, s_bad_hold;

reg         m_ack_toggle;
reg [127:0] m_resp_data;
reg         m_resp_berr;
reg [127:0] m_line;

(* async_reg = "true" *) reg [1:0] s_ack_sync;
(* async_reg = "true" *) reg [1:0] m_req_sync;
reg s_ack_seen;
reg m_req_seen;
reg m_active;

// Source side: exactly one level-held request at a time.  The cache drops
// s_req once it has taken the line (or the error), which re-arms this side.
always @(posedge s_clk or negedge s_reset_n) begin
	if (!s_reset_n) begin
		s_req_toggle <= 0;
		s_busy       <= 0;
		s_addr_hold  <= 0;
		s_ddr_hold   <= 0;
		s_bad_hold   <= 0;
		s_ack_sync   <= 0;
		s_ack_seen   <= 0;
		s_ack        <= 0;
		s_data       <= 0;
		s_err        <= 0;
	end
	else begin
		s_ack_sync <= {s_ack_sync[0], m_ack_toggle};
		if (!s_req) begin
			s_ack <= 0;
			s_err <= 0;
		end
		if (!s_busy && s_req) begin
			s_addr_hold  <= s_addr;
			s_ddr_hold   <= s_ddr;
			s_bad_hold   <= s_bad;
			s_req_toggle <= ~s_req_toggle;
			s_busy       <= 1;
		end
		if (s_busy && (s_ack_sync[1] != s_ack_seen)) begin
			s_ack_seen <= s_ack_sync[1];
			s_data     <= m_resp_data;
			s_err      <= m_resp_berr;
			s_ack      <= 1;
		end
		if (s_busy && !s_req && (s_ack_sync[1] == s_ack_seen))
			s_busy <= 0;
	end
end

// The s-side reset crossed into the m domain, as in ap040_walker_cdc: a
// CPU-only reset must clear both sides or the toggle parity desyncs.
(* async_reg = "true" *) reg [1:0] m_srst_sync;
always @(posedge m_clk or negedge s_reset_n) begin
	if (!s_reset_n) m_srst_sync <= 2'b00;
	else            m_srst_sync <= {m_srst_sync[0], 1'b1};
end
wire m_rst_n = m_reset_n & m_srst_sync[1];

// Destination side.  The source payload has been stable for at least two
// destination clocks when the synchronized request toggle changes.  A
// request the wrapper marked bad (no RAM there) answers with an error at
// once, without touching a controller.
always @(posedge m_clk or negedge m_rst_n) begin
	if (!m_rst_n) begin
		m_req_sync   <= 0;
		m_req_seen   <= 0;
		m_ack_toggle <= 0;
		m_resp_data  <= 0;
		m_resp_berr  <= 0;
		m_req        <= 0;
		m_addr       <= 0;
		m_ddr        <= 0;
		m_active     <= 0;
		m_line       <= 0;
	end
	else begin
		m_req_sync <= {m_req_sync[0], s_req_toggle};

		if (!m_active && (m_req_sync[1] != m_req_seen)) begin
			m_req_seen <= m_req_sync[1];
			m_addr     <= s_addr_hold;
			m_ddr      <= s_ddr_hold;
			m_line     <= 0;
			if (s_bad_hold) begin
				m_resp_data  <= 0;
				m_resp_berr  <= 1;
				m_ack_toggle <= ~m_ack_toggle;
			end
			else begin
				m_req    <= 1;
				m_active <= 1;
			end
		end

		if (m_active && m_strb)
			m_line <= {m_line[95:0], m_dat};

		if (m_active && (m_ack || m_berr)) begin
			// the last beat may arrive in the acknowledge cycle
			m_resp_data  <= m_strb ? {m_line[95:0], m_dat} : m_line;
			m_resp_berr  <= m_berr;
			m_req        <= 0;
			m_active     <= 0;
			m_ack_toggle <= ~m_ack_toggle;
		end
	end
end

endmodule
