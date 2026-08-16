`timescale 1ns/1ps

module tb_ap040_walker_cdc;
reg s_clk = 0, m_clk = 0;
reg s_reset_n = 0, m_reset_n = 0;
always #17 s_clk = ~s_clk;
always #4  m_clk = ~m_clk;

reg s_req, s_we, s_ddr, s_bad;
reg [28:2] s_addr;
reg [31:0] s_wdata;
wire s_ack, s_berr;
wire [31:0] s_rdata;

wire m_req, m_we, m_ddr;
wire [28:2] m_addr;
wire [31:0] m_wdata;
reg m_ack, m_berr;
reg [31:0] m_rdata;

ap040_walker_cdc dut (
	.s_clk(s_clk), .s_reset_n(s_reset_n),
	.s_req(s_req), .s_we(s_we), .s_addr(s_addr), .s_wdata(s_wdata),
	.s_ddr(s_ddr), .s_bad(s_bad), .s_ack(s_ack), .s_rdata(s_rdata),
	.s_berr(s_berr),
	.m_clk(m_clk), .m_reset_n(m_reset_n),
	.m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
	.m_ddr(m_ddr), .m_ack(m_ack), .m_rdata(m_rdata), .m_berr(m_berr)
);

integer errors = 0;
integer native_count = 0;
reg native_armed = 1;
reg native_pending = 0;
reg [2:0] native_wait;

always @(posedge m_clk) begin
	m_ack <= 0;
	m_berr <= 0;
	if (!m_reset_n) begin
		native_armed <= 1;
		native_pending <= 0;
		native_count <= 0;
	end
	else begin
		if (!m_req) native_armed <= 1;
		if (m_req && native_armed && !native_pending) begin
			native_armed <= 0;
			native_pending <= 1;
			native_wait <= 3;
			native_count <= native_count + 1;
		end
		else if (native_pending) begin
			if (native_wait != 0) native_wait <= native_wait - 1'b1;
			else begin
				m_rdata <= {m_addr[15:2], 2'b00} ^ 32'hA5A5_5A5A;
				m_ack <= 1;
				native_pending <= 0;
			end
		end
	end
end

task transact;
	input we;
	input ddr;
	input bad;
	input [28:2] addr;
	input [31:0] wdata;
	input expect_berr;
	reg [31:0] expected;
	integer guard;
	begin
		@(negedge s_clk);
		s_we = we; s_ddr = ddr; s_bad = bad;
		s_addr = addr; s_wdata = wdata; s_req = 1;
		guard = 0;
		while (!s_ack && guard < 100) begin
			@(posedge s_clk);
			guard = guard + 1;
		end
		if (!s_ack) begin
			$display("FAIL: source timeout");
			errors = errors + 1;
		end
		if (s_berr !== expect_berr) begin
			$display("FAIL: berr got=%b expected=%b", s_berr, expect_berr);
			errors = errors + 1;
		end
		expected = {addr[15:2], 2'b00} ^ 32'hA5A5_5A5A;
		if (!we && !bad && s_rdata !== expected) begin
			$display("FAIL: rdata got=%h expected=%h", s_rdata, expected);
			errors = errors + 1;
		end
		@(negedge s_clk);
		s_req = 0;
		repeat (3) @(posedge s_clk);
	end
endtask

initial begin
	s_req = 0; s_we = 0; s_ddr = 0; s_bad = 0;
	s_addr = 0; s_wdata = 0; m_ack = 0; m_berr = 0; m_rdata = 0;
	repeat (4) @(posedge s_clk);
	s_reset_n = 1;
	m_reset_n = 1;

	transact(0, 0, 0, 27'h0012340, 0, 0);
	transact(1, 1, 0, 27'h1234560, 32'hDEAD_BEEF, 0);
	transact(0, 0, 1, 27'h0000040, 0, 1);

	if (native_count != 2) begin
		$display("FAIL: native request count=%0d expected=2", native_count);
		errors = errors + 1;
	end
	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end
endmodule
