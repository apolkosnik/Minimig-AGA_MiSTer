// SPDX-License-Identifier: GPL-3.0-or-later
//
// ddram_slice.v - a register slice on an Avalon-MM interface (the core's
// DDRAM port): commands toward the slave leave a register, with a second
// (skid) register so the master's waitrequest is a register too; read data
// and readdatavalid come back one clock later.  No combinational path
// crosses it in either direction.
//
// Every transfer is taken as Avalon presents it: a read command with its
// burstcount, or one write beat; the order is kept.

module ddram_slice #(
	parameter ADDR_W  = 29,
	parameter DATA_W  = 64,
	parameter BURST_W = 8,
	parameter BYTE_W  = 8
)(
	input                     clk,
	input                     rst,

	// from the master
	input      [ADDR_W-1:0]   m_address,
	input      [BURST_W-1:0]  m_burstcount,
	input                     m_read,
	input                     m_write,
	input      [DATA_W-1:0]   m_writedata,
	input      [BYTE_W-1:0]   m_byteenable,
	output                    m_waitrequest,
	output reg [DATA_W-1:0]   m_readdata,
	output reg                m_readdatavalid,

	// to the slave
	output     [ADDR_W-1:0]   s_address,
	output     [BURST_W-1:0]  s_burstcount,
	output                    s_read,
	output                    s_write,
	output     [DATA_W-1:0]   s_writedata,
	output     [BYTE_W-1:0]   s_byteenable,
	input                     s_waitrequest,
	input      [DATA_W-1:0]   s_readdata,
	input                     s_readdatavalid
);

localparam W = 1 + ADDR_W + BURST_W + DATA_W + BYTE_W;   // {is_read, ...}

reg         o_v = 1'b0, k_v = 1'b0;     // output register, skid register
reg [W-1:0] o_d, k_d;

wire [W-1:0] m_d    = {m_read, m_address, m_burstcount, m_writedata, m_byteenable};
wire         m_xfer = (m_read | m_write) & ~k_v;
wire         o_free = ~o_v | ~s_waitrequest;

assign m_waitrequest = k_v;

always @(posedge clk) begin
	if (rst) begin
		o_v <= 1'b0;
		k_v <= 1'b0;
	end else if (o_free) begin
		// the output register is free (or handing over this clock)
		if (k_v) begin o_d <= k_d; o_v <= 1'b1; k_v <= 1'b0; end
		else if (m_xfer) begin o_d <= m_d; o_v <= 1'b1; end
		else o_v <= 1'b0;
	end else if (m_xfer) begin
		k_d <= m_d; k_v <= 1'b1;
	end
end

assign {s_read, s_address, s_burstcount, s_writedata, s_byteenable} = {o_v & o_d[W-1], o_d[W-2:0]};
assign s_write = o_v & ~o_d[W-1];

always @(posedge clk) begin
	m_readdatavalid <= ~rst & s_readdatavalid;
	m_readdata      <= s_readdata;
end

endmodule
