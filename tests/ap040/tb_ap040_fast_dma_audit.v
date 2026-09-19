// Focused integration reproducer: AP040 D-cache -> bus16 -> router ->
// DDR outer cache, with real chipdma_arb CD DMA into that controller.
// No cache state is seeded or forced. The CPU request source and DDR slave
// are models. The missing top-level snoop is represented by s_stb=0;
// +snoop=1 supplies a diagnostic invalidate after DMA, not a production fix.
`timescale 1ns/1ps
module tb_ap040_fast_dma_audit;
reg clk = 0;
always #5 clk = ~clk;
reg chipclk = 0;
always #20 chipclk = ~chipclk;
reg reset_n = 0;
integer ce_div = 1, window = 0, snoop_mode = 0, no_inner = 0, waits = 0;
integer phase = 0;
always @(posedge clk) phase <= phase == ce_div-1 ? 0 : phase+1;
wire tick = phase == 0;
reg [1:0] c7_count = 0;
always @(posedge chipclk) c7_count <= c7_count + 1'b1;
wire c7 = c7_count == 0;

reg c_req = 0;
reg [31:0] c_addr = 0;
wire c_ack;
wire [31:0] c_rdata;
reg cinv_req = 0;
wire cinv_done;
reg s_stb = 0;
reg [31:0] s_addr = 0;
wire m_req, m_write, m_instr, m_ack, sb_busy;
wire [1:0] m_size;
wire [31:0] m_addr, m_wdata, m_rdata;
wire [2:0] m_fc;
wire [31:0] bus_addr;
wire [15:0] bus_data, cpu_read;
wire nwr, nuds, nlds, ready;
wire [1:0] busstate;
wire bus_active = busstate != 2'b01;
wire bus_ce = tick && (!bus_active || ready);
wire core_ce = tick && (!bus_active || ready || sb_busy);

// The runner extracts the cache-window predicate verbatim from the compat
// wrapper. This is the only modeled CPU-side policy in this subsystem bench.
wire [31:0] mm_addr = c_addr;
wire cache_z2_ena = window < 2;
wire [4:0] cache_z3_base0 = 5'd3;
wire cache_z3_ena0 = window == 2;
wire [3:0] cache_z3_base1 = 4'd4;
wire cache_z3_ena1 = window == 3;
`include "audit_cache_window.svh"

ap040_cache inner (
 .clk(clk), .nreset(reset_n), .ce(core_ce), .ie(1'b1), .de(1'b1),
 .cinv_req(cinv_req), .cinv_ic(1'b0), .cinv_dc(1'b1), .cinv_done(cinv_done),
 .c_req(c_req), .c_write(1'b0), .c_instr(1'b0), .c_size(2'd2),
 .c_addr(c_addr), .c_wdata(32'd0), .c_fc(3'd5),
 .c_nocache(no_inner != 0 || !cache_win), .c_post_ok(1'b1),
 .c_ack(c_ack), .c_rdata(c_rdata), .sb_busy(sb_busy),
 .m_req(m_req), .m_write(m_write), .m_instr(m_instr), .m_size(m_size),
 .m_addr(m_addr), .m_wdata(m_wdata), .m_fc(m_fc),
 .m_ack(m_ack), .m_rdata(m_rdata), .m_err(1'b0), .s_stb(s_stb), .s_addr(s_addr)
);
ap040_bus16_adapter adapter (
 .clk(clk), .nreset(reset_n), .clkena_in(bus_ce), .mem_berr(1'b0),
 .mem_req(m_req), .mem_write(m_write), .mem_instr(m_instr), .mem_size(m_size),
 .mem_addr(m_addr), .mem_wdata(m_wdata), .mem_fc(m_fc),
 .mem_ack(m_ack), .mem_rdata(m_rdata), .data_in(cpu_read),
 .addr_out(bus_addr), .data_write(bus_data), .nwr(nwr), .nuds(nuds),
 .nlds(nlds), .busstate(busstate), .longword(), .fc()
);
wire [28:1] routed_addr;
wire sel_zram;
memory_router router (
 .cpu_addr(bus_addr), .cchip(1'b0), .ckick(1'b0), .wr(nwr),
 .bootrom(1'b0), .cdtv_mode(1'b0), .z2ram_ena(cache_z2_ena),
 .z3ram_base0(cache_z3_base0), .z3ram_ena0(cache_z3_ena0),
 .z3ram_base1(cache_z3_base1), .z3ram_ena1(cache_z3_ena1),
 .sel_zram(sel_zram), .ramaddr(routed_addr)
);

reg ak_req = 0, cd_req = 0;
reg [31:0] dma_target = 0;
reg [7:0] dma_byte = 0;
wire ak_ack, cd_ack;
wire [28:1] dma_addr;
wire dma_l, dma_u, dma_we, dma_cs, dma_ack;
wire [15:0] dma_wr, dma_rd;
chipdma_arb dma (
 .clk(chipclk), .reset(!reset_n), .c_7m(c7),
 .chip_in_addr(24'd0), .chip_in_l(1'b1), .chip_in_u(1'b1),
 .chip_in_rw(1'b1), .chip_in_dma(1'b1), .chip_in_wr(16'd0),
 .akiko_dma_req(ak_req), .akiko_dma_we(1'b1),
 .akiko_dma_baddr(dma_target[23:0]), .akiko_dma_wbyte(dma_byte),
 .akiko_dma_rbyte(), .akiko_dma_ack(ak_ack), .akiko_arm(),
 .cdtv_dma_req(cd_req), .cdtv_dma_we(1'b1), .cdtv_dma_baddr(dma_target),
 .cdtv_dma_wbyte(dma_byte), .cdtv_dma_rbyte(), .cdtv_dma_ack(cd_ack),
 .chip_out_addr(), .chip_out_l(), .chip_out_u(), .chip_out_rw(),
 .chip_out_dma(), .chip_out_wr(), .chip_in_rd(16'd0),
 .z2ram_ena(cache_z2_ena), .z3ram_base0(cache_z3_base0),
 .z3ram_ena0(cache_z3_ena0), .z3ram_base1(cache_z3_base1),
 .z3ram_ena1(cache_z3_ena1),
 .ddr_out_addr(dma_addr), .ddr_out_l(dma_l), .ddr_out_u(dma_u),
 .ddr_out_we(dma_we), .ddr_out_cs(dma_cs), .ddr_out_wr(dma_wr),
 .ddr_in_ack(dma_ack), .ddr_in_rd(dma_rd)
);

wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire [7:0] ddr_be, ddr_burst;
wire ddr_rd, ddr_we;
reg [63:0] ddr_dout = 0;
reg ddr_valid = 0, busy_phase = 0;
always @(posedge clk) busy_phase <= !busy_phase;
wire ddr_busy = waits != 0 && busy_phase;
ddram_ctrl #(.CPU_CACHE(1)) outer (
 .sysclk(clk), .reset_n(reset_n), .cache_rst(1'b1),
 .cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0011), .dcache_sw_en(1'b1),
 .DDRAM_CLK(), .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst),
 .DDRAM_ADDR(ddr_addr), .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_valid),
 .DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
 .mem2_address(29'd0), .mem2_burstcount(8'd0), .mem2_read(1'b0),
 .mem2_readdata(), .mem2_readdatavalid(), .mem2_writedata(64'd0),
 .mem2_byteenable(8'd0), .mem2_write(1'b0), .mem2_waitrequest(),
 .cpuAddr(routed_addr), .cpuCS(bus_active && sel_zram), .cpustate(busstate),
 .cpuL(nlds), .cpuU(nuds), .cpuWR(bus_data), .cpuRD(cpu_read),
 .ramshared(1'b0), .ramready(ready), .walker_req(1'b0), .walker_we(1'b0),
 .walker_addr(27'd0), .walker_wdata(32'd0), .walker_ack(), .walker_rdata(),
 .dmaAddr(dma_addr), .dmaCS(dma_cs), .dmaWE(dma_we), .dmaL(dma_l),
 .dmaU(dma_u), .dmaWR(dma_wr), .dmaRD(dma_rd), .dmaACK(dma_ack)
);

// DDR addresses are 64-bit WORD addresses. This array models the low 4 KB
// of the selected region; full write addresses are checked separately.
reg [63:0] memory [0:511];
reg [63:0] response [0:7];
reg [7:0] response_valid = 0;
integer i, reads = 0, writes = 0, lower_reads = 0;
reg [31:0] target, backing;
always @(posedge clk) begin
 ddr_valid <= response_valid[0];
 ddr_dout <= response[0];
 for (i=0; i<7; i=i+1) begin
  response_valid[i] <= response_valid[i+1];
  response[i] <= response[i+1];
 end
 response_valid[7] <= 0;
 if (reset_n && ddr_rd && !ddr_busy) begin
  if (ddr_burst != 1) $fatal(1, "HARNESS: unexpected DDR burst");
  response_valid[3] <= 1;
  response[3] <= memory[ddr_addr[8:0]];
  reads <= reads + 1;
 end
 if (reset_n && ddr_we && !ddr_busy) begin
  if (ddr_addr != {3'b001,backing[28:3]})
   $fatal(1, "HARNESS: DMA wrote wrong backing address %h", ddr_addr);
  for (i=0; i<8; i=i+1)
   if (ddr_be[i]) memory[ddr_addr[8:0]][8*i +: 8] <= ddr_din[8*i +: 8];
  writes <= writes + 1;
 end
 if (reset_n && m_ack && core_ce) lower_reads <= lower_reads + 1;
end

task read_cpu(output [31:0] value);
 integer guard;
 begin
  @(negedge clk); c_addr = target; c_req = 1;
  guard = 0;
  @(posedge clk);
  while (!(c_ack && core_ce) && guard < 20000) begin
   @(posedge clk); guard = guard + 1;
  end
  if (guard == 20000) $fatal(1, "HARNESS: CPU timeout");
  value = c_rdata;
  @(negedge clk); c_req = 0;
  repeat (12*ce_div) @(negedge clk);
 end
endtask
task write_dma(input [31:0] addr, input [7:0] value);
 integer guard;
 begin
  @(negedge chipclk); dma_target = addr; dma_byte = value;
  ak_req = window == 0; cd_req = window != 0;
  guard = 0;
  @(posedge chipclk);
  while (!(ak_ack || cd_ack) && guard < 2000) begin
   @(posedge chipclk); guard = guard + 1;
  end
  if (guard == 2000) $fatal(1, "HARNESS: CD DMA timeout");
  @(negedge chipclk); ak_req = 0; cd_req = 0;
  repeat (12) @(negedge chipclk);
  if (snoop_mode != 0) begin
   @(negedge clk); s_addr = addr ^ (snoop_mode == 2 ? 32'h10 : 32'd0); s_stb = 1;
   @(negedge clk); s_stb = 0;
  end
 end
endtask
task invalidate;
 integer guard;
 begin
  @(negedge clk); cinv_req = 1; guard = 0;
  @(posedge clk);
  while (!(cinv_done && core_ce) && guard < 10000) begin
   @(posedge clk); guard = guard + 1;
  end
  if (guard == 10000) $fatal(1, "HARNESS: CINV timeout");
  @(negedge clk); cinv_req = 0;
  repeat (8*ce_div) @(negedge clk);
 end
endtask

reg [31:0] got, after_dma;
integer before_read, before_ddr, dma_lower_reads;
initial begin
 if ($value$plusargs("ce_div=%d",ce_div)) begin end
 if ($value$plusargs("window=%d",window)) begin end
 if ($value$plusargs("snoop=%d",snoop_mode)) begin end
 if ($value$plusargs("no_inner=%d",no_inner)) begin end
 if ($value$plusargs("waits=%d",waits)) begin end
 if (window < 2) begin target = 32'h00201000; backing = 32'h10201000; end
 else if (window == 2) begin target = 32'h18201000; backing = 32'h08201000; end
 else begin target = 32'h40201000; backing = 32'h10201000; end
 for (integer k=0;k<512;k=k+1) memory[k] = 64'h7788556633441122;
 repeat (12) @(negedge clk); reset_n = 1;
 repeat (1000*ce_div) @(negedge clk);
 c_addr = target;
 #1;
 if (!cache_win) $fatal(1,"HARNESS: target not admitted by production cache window");
 read_cpu(got);
 if (got !== 32'h11223344) $fatal(1,"HARNESS: initial read %h",got);
 before_read = lower_reads;
 read_cpu(got);
 if (got !== 32'h11223344) $fatal(1,"HARNESS: warm read %h",got);
 if (!no_inner && lower_reads != before_read)
  $fatal(1,"HARNESS: AP040 line did not become resident");
 write_dma(target,8'haa);
 write_dma(target+1,8'hbb);
 if (writes != 2 || memory[0][15:0] !== 16'haabb)
  $fatal(1,"HARNESS: DMA did not commit both bytes, writes=%0d backing=%h",writes,memory[0]);
 before_read = lower_reads;
 read_cpu(after_dma);
 dma_lower_reads = lower_reads - before_read;
 before_ddr = reads;
 invalidate;
 read_cpu(got);
 if (got !== 32'haabb3344)
  $fatal(1,"HARNESS: CINV did not recover new data %h",got);
 if (reads != before_ddr)
  $fatal(1,"HARNESS: outer cache verification needed a DDR refill");
 $display("RESULT window=%0d ce_div=%0d waits=%0d snoop=%0d bypass=%0d before=11223344 after_dma=%h after_cinv=%h dma_lower_reads=%0d writes=%0d",
          window,ce_div,waits,snoop_mode,no_inner,after_dma,got,dma_lower_reads,writes);
 if (after_dma !== 32'haabb3344) $display("FAIL: stale AP040 data after completed CD DMA");
 else $display("ALL TESTS PASSED");
 $finish;
end
endmodule
