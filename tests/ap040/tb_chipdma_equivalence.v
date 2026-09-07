// Compare every arbiter output against the selected baseline RTL.
`timescale 1ns/1ps
module tb_dma_equivalence;
reg clk=0; always #5 clk=~clk;
reg  reset=0;
reg  c_7m=0;
reg [24:1] chip_in_addr=0;
reg  chip_in_l=0;
reg  chip_in_u=0;
reg  chip_in_rw=0;
reg  chip_in_dma=0;
reg [15:0] chip_in_wr=0;
reg  akiko_dma_req=0;
reg  akiko_dma_we=0;
reg [23:0] akiko_dma_baddr=0;
reg [7:0] akiko_dma_wbyte=0;
wire [7:0] got_akiko_dma_rbyte, ref_akiko_dma_rbyte;
wire  got_akiko_dma_ack, ref_akiko_dma_ack;
wire  got_akiko_arm, ref_akiko_arm;
reg  cdtv_dma_req=0;
reg  cdtv_dma_we=0;
reg [31:0] cdtv_dma_baddr=0;
reg [7:0] cdtv_dma_wbyte=0;
wire [7:0] got_cdtv_dma_rbyte, ref_cdtv_dma_rbyte;
wire  got_cdtv_dma_ack, ref_cdtv_dma_ack;
wire [24:1] got_chip_out_addr, ref_chip_out_addr;
wire  got_chip_out_l, ref_chip_out_l;
wire  got_chip_out_u, ref_chip_out_u;
wire  got_chip_out_rw, ref_chip_out_rw;
wire  got_chip_out_dma, ref_chip_out_dma;
wire [15:0] got_chip_out_wr, ref_chip_out_wr;
reg [15:0] chip_in_rd=0;
reg  z2ram_ena=0;
reg [4:0] z3ram_base0=0;
reg  z3ram_ena0=0;
reg [3:0] z3ram_base1=0;
reg  z3ram_ena1=0;
wire [28:1] got_ddr_out_addr, ref_ddr_out_addr;
wire  got_ddr_out_l, ref_ddr_out_l;
wire  got_ddr_out_u, ref_ddr_out_u;
wire  got_ddr_out_we, ref_ddr_out_we;
wire  got_ddr_out_cs, ref_ddr_out_cs;
wire [15:0] got_ddr_out_wr, ref_ddr_out_wr;
reg  ddr_in_ack=0;
reg [15:0] ddr_in_rd=0;
chipdma_arb got (
    .clk(clk),
    .reset(reset),
    .c_7m(c_7m),
    .chip_in_addr(chip_in_addr),
    .chip_in_l(chip_in_l),
    .chip_in_u(chip_in_u),
    .chip_in_rw(chip_in_rw),
    .chip_in_dma(chip_in_dma),
    .chip_in_wr(chip_in_wr),
    .akiko_dma_req(akiko_dma_req),
    .akiko_dma_we(akiko_dma_we),
    .akiko_dma_baddr(akiko_dma_baddr),
    .akiko_dma_wbyte(akiko_dma_wbyte),
    .akiko_dma_rbyte(got_akiko_dma_rbyte),
    .akiko_dma_ack(got_akiko_dma_ack),
    .akiko_arm(got_akiko_arm),
    .cdtv_dma_req(cdtv_dma_req),
    .cdtv_dma_we(cdtv_dma_we),
    .cdtv_dma_baddr(cdtv_dma_baddr),
    .cdtv_dma_wbyte(cdtv_dma_wbyte),
    .cdtv_dma_rbyte(got_cdtv_dma_rbyte),
    .cdtv_dma_ack(got_cdtv_dma_ack),
    .chip_out_addr(got_chip_out_addr),
    .chip_out_l(got_chip_out_l),
    .chip_out_u(got_chip_out_u),
    .chip_out_rw(got_chip_out_rw),
    .chip_out_dma(got_chip_out_dma),
    .chip_out_wr(got_chip_out_wr),
    .chip_in_rd(chip_in_rd),
    .z2ram_ena(z2ram_ena),
    .z3ram_base0(z3ram_base0),
    .z3ram_ena0(z3ram_ena0),
    .z3ram_base1(z3ram_base1),
    .z3ram_ena1(z3ram_ena1),
    .ddr_out_addr(got_ddr_out_addr),
    .ddr_out_l(got_ddr_out_l),
    .ddr_out_u(got_ddr_out_u),
    .ddr_out_we(got_ddr_out_we),
    .ddr_out_cs(got_ddr_out_cs),
    .ddr_out_wr(got_ddr_out_wr),
    .ddr_in_ack(ddr_in_ack),
    .ddr_in_rd(ddr_in_rd));
chipdma_reference reference (
    .clk(clk),
    .reset(reset),
    .c_7m(c_7m),
    .chip_in_addr(chip_in_addr),
    .chip_in_l(chip_in_l),
    .chip_in_u(chip_in_u),
    .chip_in_rw(chip_in_rw),
    .chip_in_dma(chip_in_dma),
    .chip_in_wr(chip_in_wr),
    .akiko_dma_req(akiko_dma_req),
    .akiko_dma_we(akiko_dma_we),
    .akiko_dma_baddr(akiko_dma_baddr),
    .akiko_dma_wbyte(akiko_dma_wbyte),
    .akiko_dma_rbyte(ref_akiko_dma_rbyte),
    .akiko_dma_ack(ref_akiko_dma_ack),
    .akiko_arm(ref_akiko_arm),
    .cdtv_dma_req(cdtv_dma_req),
    .cdtv_dma_we(cdtv_dma_we),
    .cdtv_dma_baddr(cdtv_dma_baddr),
    .cdtv_dma_wbyte(cdtv_dma_wbyte),
    .cdtv_dma_rbyte(ref_cdtv_dma_rbyte),
    .cdtv_dma_ack(ref_cdtv_dma_ack),
    .chip_out_addr(ref_chip_out_addr),
    .chip_out_l(ref_chip_out_l),
    .chip_out_u(ref_chip_out_u),
    .chip_out_rw(ref_chip_out_rw),
    .chip_out_dma(ref_chip_out_dma),
    .chip_out_wr(ref_chip_out_wr),
    .chip_in_rd(chip_in_rd),
    .z2ram_ena(z2ram_ena),
    .z3ram_base0(z3ram_base0),
    .z3ram_ena0(z3ram_ena0),
    .z3ram_base1(z3ram_base1),
    .z3ram_ena1(z3ram_ena1),
    .ddr_out_addr(ref_ddr_out_addr),
    .ddr_out_l(ref_ddr_out_l),
    .ddr_out_u(ref_ddr_out_u),
    .ddr_out_we(ref_ddr_out_we),
    .ddr_out_cs(ref_ddr_out_cs),
    .ddr_out_wr(ref_ddr_out_wr),
    .ddr_in_ack(ddr_in_ack),
    .ddr_in_rd(ddr_in_rd));
integer i; initial begin
reset=1; repeat(3) @(negedge clk); reset=0;
for(i=0;i<100000;i=i+1) begin
@(negedge clk);
c_7m=$urandom;
chip_in_addr=$urandom;
chip_in_l=$urandom;
chip_in_u=$urandom;
chip_in_rw=$urandom;
chip_in_dma=$urandom;
chip_in_wr=$urandom;
akiko_dma_req=$urandom;
akiko_dma_we=$urandom;
akiko_dma_baddr=$urandom;
akiko_dma_wbyte=$urandom;
cdtv_dma_req=$urandom;
cdtv_dma_we=$urandom;
cdtv_dma_baddr=$urandom;
cdtv_dma_wbyte=$urandom;
chip_in_rd=$urandom;
z2ram_ena=$urandom;
z3ram_base0=$urandom;
z3ram_ena0=$urandom;
z3ram_base1=$urandom;
z3ram_ena1=$urandom;
ddr_in_ack=$urandom;
ddr_in_rd=$urandom;
reset=(i%997==0);
@(posedge clk); #1;
if(got_akiko_dma_rbyte !== ref_akiko_dma_rbyte) $fatal(1,"Mismatch on akiko_dma_rbyte at cycle %0d",i);
if(got_akiko_dma_ack !== ref_akiko_dma_ack) $fatal(1,"Mismatch on akiko_dma_ack at cycle %0d",i);
if(got_akiko_arm !== ref_akiko_arm) $fatal(1,"Mismatch on akiko_arm at cycle %0d",i);
if(got_cdtv_dma_rbyte !== ref_cdtv_dma_rbyte) $fatal(1,"Mismatch on cdtv_dma_rbyte at cycle %0d",i);
if(got_cdtv_dma_ack !== ref_cdtv_dma_ack) $fatal(1,"Mismatch on cdtv_dma_ack at cycle %0d",i);
if(got_chip_out_addr !== ref_chip_out_addr) $fatal(1,"Mismatch on chip_out_addr at cycle %0d",i);
if(got_chip_out_l !== ref_chip_out_l) $fatal(1,"Mismatch on chip_out_l at cycle %0d",i);
if(got_chip_out_u !== ref_chip_out_u) $fatal(1,"Mismatch on chip_out_u at cycle %0d",i);
if(got_chip_out_rw !== ref_chip_out_rw) $fatal(1,"Mismatch on chip_out_rw at cycle %0d",i);
if(got_chip_out_dma !== ref_chip_out_dma) $fatal(1,"Mismatch on chip_out_dma at cycle %0d",i);
if(got_chip_out_wr !== ref_chip_out_wr) $fatal(1,"Mismatch on chip_out_wr at cycle %0d",i);
if(got_ddr_out_addr !== ref_ddr_out_addr) $fatal(1,"Mismatch on ddr_out_addr at cycle %0d",i);
if(got_ddr_out_l !== ref_ddr_out_l) $fatal(1,"Mismatch on ddr_out_l at cycle %0d",i);
if(got_ddr_out_u !== ref_ddr_out_u) $fatal(1,"Mismatch on ddr_out_u at cycle %0d",i);
if(got_ddr_out_we !== ref_ddr_out_we) $fatal(1,"Mismatch on ddr_out_we at cycle %0d",i);
if(got_ddr_out_cs !== ref_ddr_out_cs) $fatal(1,"Mismatch on ddr_out_cs at cycle %0d",i);
if(got_ddr_out_wr !== ref_ddr_out_wr) $fatal(1,"Mismatch on ddr_out_wr at cycle %0d",i);
end
$display("ALL TESTS PASSED: 100000 randomized DMA equivalence cycles"); $finish; end
endmodule
