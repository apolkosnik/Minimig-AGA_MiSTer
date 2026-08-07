//--------------------------------------------------------------------------//
// AP040 dedicated table-walker clock-domain bridge                         //
//                                                                          //
// The MMU runs at clk_sys while the SDRAM and DDR3 controllers run at      //
// clk_114.  Requests and responses cross with toggle handshakes; all       //
// multi-bit payloads remain registered and stable until the opposite       //
// domain has observed the corresponding toggle.                            //
//--------------------------------------------------------------------------//

module ap040_walker_cdc
(
	// MMU / clk_sys side
	input             s_clk,
	input             s_reset_n,
	input             s_req,
	input             s_we,
	input      [28:2] s_addr,
	input      [31:0] s_wdata,
	input             s_ddr,
	input             s_bad,
	output reg        s_ack,
	output reg [31:0] s_rdata,
	output reg        s_berr,

	// RAM-controller / clk_114 side
	input             m_clk,
	input             m_reset_n,
	output reg        m_req,
	output reg        m_we,
	output reg [28:2] m_addr,
	output reg [31:0] m_wdata,
	output reg        m_ddr,
	input             m_ack,
	input      [31:0] m_rdata,
	input             m_berr
);

reg        s_req_toggle;
reg        s_busy;
reg        s_we_hold, s_ddr_hold, s_bad_hold;
reg [28:2] s_addr_hold;
reg [31:0] s_wdata_hold;

reg        m_ack_toggle;
reg [31:0] m_resp_data;
reg        m_resp_berr;

(* async_reg = "true" *) reg [1:0] s_ack_sync;
(* async_reg = "true" *) reg [1:0] m_req_sync;
reg s_ack_seen;
reg m_req_seen;
reg m_active;

// Source side: accept exactly one level-held MMU request.  The MMU drops
// s_req for a cycle after s_ack, which rearms this bridge for the next one.
always @(posedge s_clk or negedge s_reset_n) begin
	if (!s_reset_n) begin
		s_req_toggle <= 0;
		s_busy       <= 0;
		s_we_hold    <= 0;
		s_ddr_hold   <= 0;
		s_bad_hold   <= 0;
		s_addr_hold  <= 0;
		s_wdata_hold <= 0;
		s_ack_sync   <= 0;
		s_ack_seen   <= 0;
		s_ack        <= 0;
		s_rdata      <= 0;
		s_berr       <= 0;
	end
	else begin
		s_ack_sync <= {s_ack_sync[0], m_ack_toggle};
		s_ack      <= 0;
		s_berr     <= 0;

		if (!s_busy && s_req) begin
			s_we_hold    <= s_we;
			s_addr_hold  <= s_addr;
			s_wdata_hold <= s_wdata;
			s_ddr_hold   <= s_ddr;
			s_bad_hold   <= s_bad;
			s_req_toggle <= ~s_req_toggle;
			s_busy       <= 1;
		end

		if (s_busy && (s_ack_sync[1] != s_ack_seen)) begin
			s_ack_seen <= s_ack_sync[1];
			s_rdata    <= m_resp_data;
			s_berr     <= m_resp_berr;
			s_ack      <= 1;
		end

		if (s_busy && !s_req && (s_ack_sync[1] == s_ack_seen))
			s_busy <= 0;
	end
end

// Destination side.  The source payload has been stable for at least two
// destination clocks when the synchronized request toggle changes.
always @(posedge m_clk or negedge m_reset_n) begin
	if (!m_reset_n) begin
		m_req_sync   <= 0;
		m_req_seen   <= 0;
		m_ack_toggle <= 0;
		m_resp_data  <= 0;
		m_resp_berr  <= 0;
		m_req         <= 0;
		m_we          <= 0;
		m_addr        <= 0;
		m_wdata       <= 0;
		m_ddr         <= 0;
		m_active      <= 0;
	end
	else begin
		m_req_sync <= {m_req_sync[0], s_req_toggle};

		if (!m_active && (m_req_sync[1] != m_req_seen)) begin
			m_req_seen <= m_req_sync[1];
			m_we        <= s_we_hold;
			m_addr      <= s_addr_hold;
			m_wdata     <= s_wdata_hold;
			m_ddr       <= s_ddr_hold;
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

		if (m_active && (m_ack || m_berr)) begin
			m_resp_data  <= m_rdata;
			m_resp_berr  <= m_berr;
			m_req         <= 0;
			m_active      <= 0;
			m_ack_toggle  <= ~m_ack_toggle;
		end
	end
end

endmodule
