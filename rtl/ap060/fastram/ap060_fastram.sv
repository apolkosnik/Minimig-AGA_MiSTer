//--------------------------------------------------------------------------//
// AP68060 - pipelined MC68060                                              //
//                                                                          //
// ap060_fastram.sv - Fast RAM on the 68060 bus, backed by DDR3: the bus    //
// slave (ap060_fastram_bus) in front of the AP030 Fast RAM front end's     //
// native port (line buffers, 8 KiB cache, posted writes; ap030_fastram_fe) //
// and its DDR3 side (ap030_fastram_be), joined by two dual-clock FIFOs.   //
//                                                                          //
//   clk      the processor clock (bclk_en: the bus clock edges)            //
//   clk_mem  the DDR3 side: an Avalon-MM master, 64 bits                   //
//                                                                          //
// The integration decodes the window (sel, with TS) and maps the address  //
// to DDR3 64-bit words (ddr_addr).  The front end's cache is below the    //
// processor's caches and is written through by every processor write; it //
// is swept by the reset, and by clear: held while another master's writes //
// to the DDR3 it caches land (a DMA writer), it keeps the cache from       //
// allocating until the last of them is in.                                 //
//--------------------------------------------------------------------------//

module ap060_fastram
(
	input  logic         clk,
	input  logic         clk_mem,
	input  logic         rst,          // processor clock domain
	input  logic         bclk_en,
	// (processor clock) the front end's cache is cleared and refills nothing
	// while this is high: another master wrote the DDR3 it caches
	input  logic         clear,

	input  logic         m_ign,
	input  logic  [15:0] m_cnt,
	input  logic         m_hold,

	input  logic  [31:0] a,
	input  logic         rw_n,
	input  logic   [1:0] siz,
	input  logic   [1:0] tt,
	input  logic   [2:0] tm,
	input  logic   [3:0] bs_n,
	input  logic         ts_n,
	input  logic         ciout_n,
	input  logic  [31:0] d_cpu,
	input  logic         sel,
	input  logic  [28:0] ddr_addr,
	output logic         ta_n,
	output logic  [31:0] d_o,
	output logic         d_oe,
	output logic         busy,

	output logic  [28:0] avm_address,
	output logic   [7:0] avm_burstcount,
	output logic         avm_read,
	output logic         avm_write,
	output logic  [63:0] avm_writedata,
	output logic   [7:0] avm_byteenable,
	input  logic         avm_waitrequest,
	input  logic  [63:0] avm_readdata,
	input  logic         avm_readdatavalid
);

logic        n_req, n_ready, n_rw, n_ci, n_burst, n_valid, n_last;
logic [31:0] n_addr, n_wdata, n_rdata;
logic [28:0] n_ddr_addr;
logic  [2:0] n_fc;
logic  [3:0] n_be;
logic  [1:0] n_word;

ap060_fastram_bus bus (
	.clk(clk), .rst(rst), .bclk_en(bclk_en),
	.m_ign(m_ign), .m_cnt(m_cnt), .m_hold(m_hold),
	.a(a), .rw_n(rw_n), .siz(siz), .tt(tt), .tm(tm), .bs_n(bs_n), .ts_n(ts_n), .ciout_n(ciout_n),
	.d_cpu(d_cpu), .sel(sel), .ddr_addr(ddr_addr),
	.ta_n(ta_n), .d_o(d_o), .d_oe(d_oe), .busy(busy),
	.n_req(n_req), .n_ready(n_ready), .n_addr(n_addr), .n_ddr_addr(n_ddr_addr), .n_fc(n_fc),
	.n_rw(n_rw), .n_ci(n_ci), .n_burst(n_burst), .n_be(n_be), .n_wdata(n_wdata),
	.n_valid(n_valid), .n_last(n_last), .n_word(n_word), .n_rdata(n_rdata)
);

logic         cmd_we, cmd_re, cmd_rempty;
logic [101:0] cmd_wdata, cmd_rdata;
logic   [3:0] cmd_wlevel;
logic         rsp_we, rsp_re, rsp_rempty;
logic  [63:0] rsp_wdata, rsp_rdata;
logic   [3:0] rsp_wlevel;

// (the pin bus of the front end is unused: AS negated, nothing selected)
ap030_fastram_fe #(.NATIVE_PORT(1)) fe (
	.clk(clk), .rst(rst),
	.a(32'd0), .fc(3'd0), .siz(2'd0), .rw(1'b1), .as_n(1'b1), .d_o(32'd0), .d_oe(1'b0), .cbreq_n(1'b1),
	.sel(1'b0), .ci(1'b0), .clear(clear), .ddr_addr(29'd0),
	.sterm_n(), .cback_n(), .d_i(),
	.cmd_we(cmd_we), .cmd_wdata(cmd_wdata), .cmd_wlevel(cmd_wlevel),
	.rsp_rdata(rsp_rdata), .rsp_rempty(rsp_rempty), .rsp_re(rsp_re),
	.n_req(n_req), .n_ready(n_ready), .n_addr(n_addr), .n_ddr_addr(n_ddr_addr),
	.n_fc(n_fc), .n_rw(n_rw), .n_ci(n_ci), .n_burst(n_burst), .n_be(n_be), .n_wdata(n_wdata),
	.n_valid(n_valid), .n_last(n_last), .n_word(n_word), .n_rdata(n_rdata)
);

ap030_async_fifo #(.W(102), .AW(3)) cmd_fifo (
	.wclk(clk), .we(cmd_we), .wdata(cmd_wdata), .wfull(), .wlevel(cmd_wlevel),
	.rclk(clk_mem), .re(cmd_re), .rdata(cmd_rdata), .rempty(cmd_rempty), .rlevel()
);

ap030_async_fifo #(.W(64), .AW(3)) rsp_fifo (
	.wclk(clk_mem), .we(rsp_we), .wdata(rsp_wdata), .wfull(), .wlevel(rsp_wlevel),
	.rclk(clk), .re(rsp_re), .rdata(rsp_rdata), .rempty(rsp_rempty), .rlevel()
);

ap030_fastram_be be (
	.clk(clk_mem), .rst(1'b0),
	.cmd_rdata(cmd_rdata), .cmd_rempty(cmd_rempty), .cmd_re(cmd_re),
	.rsp_we(rsp_we), .rsp_wdata(rsp_wdata), .rsp_wlevel(rsp_wlevel),
	.avm_address(avm_address), .avm_burstcount(avm_burstcount), .avm_read(avm_read), .avm_write(avm_write),
	.avm_writedata(avm_writedata), .avm_byteenable(avm_byteenable), .avm_waitrequest(avm_waitrequest),
	.avm_readdata(avm_readdata), .avm_readdatavalid(avm_readdatavalid)
);

endmodule
