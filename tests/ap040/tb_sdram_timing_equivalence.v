// Cycle/pin comparison against the pre-recovery controller.  The external
// data pattern is stimulus, not an SDRAM model; the SDRAM/dualram program
// benches separately check actual read/write transactions against memory.
`timescale 1ns/1ps
module tb_sdram_timing_equivalence;
parameter CPU_CACHE=1, READ_PIPE=0;
reg sysclk=0; always #5 sysclk=~sysclk;
reg c_7m=0, reset_n=0;
reg [3:0] clkdiv=0;
reg [31:0] rng=1;
reg [15:0] memory_data=0;
reg [24:1] chipAddr=0, cpuAddr=0;
reg chipL=1, chipU=1, chipRW=1, chipDMA=1;
reg [15:0] chipWR=0, cpuWR=0;
reg cpuCS=0, cpuL=1, cpuU=1;
reg [1:0] cpustate=1;
reg walker_req=0, walker_we=0;
reg [24:2] walker_addr=0;
reg [31:0] walker_wdata=0;
wire [12:0] sd_addr[0:1];
wire [1:0] sd_ba[0:1], sd_dqm[0:1];
wire sd_cs[0:1], sd_we[0:1], sd_ras[0:1], sd_cas[0:1];
wire sd_clk[0:1], sd_cke[0:1], snoop_tgl[0:1], ramready[0:1], walker_ack[0:1];
wire [15:0] sd_data0, sd_data1, sd_data[0:1], chipRD[0:1], cpuRD[0:1];
wire [24:1] snoop_addr[0:1];
wire [47:0] chip48[0:1];
wire [31:0] walker_rdata[0:1];
wire [177:0] observed[0:1];
assign sd_data0 = dut.sd_data_en ? 16'hzzzz : memory_data;
assign sd_data1 = reference.sd_data_en ? 16'hzzzz : memory_data;
assign sd_data[0]=sd_data0;
assign sd_data[1]=sd_data1;
genvar n;
generate for(n=0;n<2;n=n+1) begin
  assign observed[n] = {sd_addr[n],sd_ba[n],sd_dqm[n],sd_cs[n],sd_we[n],
    sd_ras[n],sd_cas[n],sd_clk[n],sd_cke[n],sd_data[n],chipRD[n],chip48[n],
    snoop_tgl[n],snoop_addr[n],ramready[n],cpuRD[n],walker_ack[n],walker_rdata[n]};
end endgenerate
`define PORTS(N) .sysclk(sysclk),.c_7m(c_7m),.reset_n(reset_n), \
 .cache_rst(1'b1),.cache_inhibit(1'b0),.cpu_cache_ctrl(4'b1111),.dcache_sw_en(1'b1), \
 .sd_addr(sd_addr[N]),.sd_ba(sd_ba[N]),.sd_cs(sd_cs[N]),.sd_we(sd_we[N]), \
 .sd_ras(sd_ras[N]),.sd_cas(sd_cas[N]),.sd_dqm(sd_dqm[N]),.sd_data(sd_data``N), \
 .sd_clk(sd_clk[N]),.sd_cke(sd_cke[N]),.chipAddr(chipAddr),.chipL(chipL), \
 .chipU(chipU),.chipRW(chipRW),.chipDMA(chipDMA),.chipWR(chipWR), \
 .chipRD(chipRD[N]),.chip48(chip48[N]),.snoop_tgl(snoop_tgl[N]),.snoop_addr(snoop_addr[N]), \
 .cpuAddr(cpuAddr),.cpuCS(cpuCS),.cpustate(cpustate),.cpuL(cpuL),.cpuU(cpuU), \
 .cpuWR(cpuWR),.cpuRD(cpuRD[N]),.ramready(ramready[N]),.walker_req(walker_req), \
 .walker_we(walker_we),.walker_addr(walker_addr),.walker_wdata(walker_wdata), \
 .walker_ack(walker_ack[N]),.walker_rdata(walker_rdata[N])
sdram_ctrl #(.CPU_CACHE(CPU_CACHE),.CACHE_READ_PIPE(READ_PIPE)) dut (`PORTS(0));
sdram_reference #(.CPU_CACHE(CPU_CACHE),.CACHE_READ_PIPE(READ_PIPE)) reference (`PORTS(1));
`undef PORTS
integer cycles=0, cpu_gap=0, walker_gap=0;
integer slots[0:5], reads=0, writes=0, chip_reads=0, chip_writes=0;
integer resets=0, phase_jumps=0;
reg [15:0] reset_phases=0;
// Stimulus changes on the opposite clock edge. Requests stay held until ack;
// chipset ownership varies by slot, and the read input changes every cycle.
always @(negedge sysclk) begin
  rng = {rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  clkdiv = clkdiv + 1'b1;
  c_7m = clkdiv[3];
  memory_data = rng[15:0] ^ rng[31:16];
  if(!reset_n || !dut.init_done) begin
    cpuCS=0; cpuL=1; cpuU=1; cpustate=1;
    walker_req=0; chipDMA=1; chipRW=1;
    cpu_gap=4; walker_gap=4;
  end else begin
    if(dut.sdram_state==15) begin
      chipDMA = (rng[1:0]!=0);
      chipRW = chipDMA || rng[2];
      chipAddr = {12'd0,rng[19:8]};
      chipWR = rng[31:16];
      {chipU,chipL} = rng[4:3]==3 ? 2'b00 : rng[4:3];
    end
    if(cpuCS) begin
      if(ramready[0]) begin
        cpuCS=0; cpuL=1; cpuU=1; cpustate=1; cpu_gap=5;
      end
    end else if(cpu_gap>0) cpu_gap=cpu_gap-1;
    else if(rng[5]) begin
      cpuCS=1; cpustate=rng[6] ? 3 : 2;
      cpuAddr={12'd0,rng[23:12]}; cpuWR=rng[31:16];
      {cpuU,cpuL}=rng[8:7]==3 ? 2'b00 : rng[8:7];
    end
    if(walker_req) begin
      if(walker_ack[0]) begin walker_req=0; walker_gap=24; end
    end else if(walker_gap>0) walker_gap=walker_gap-1;
    else if(rng[9:8]==0) begin
      walker_req=1; walker_we=rng[10];
      walker_addr={12'd0,rng[22:12]}; walker_wdata=rng;
    end
  end
end
always @(posedge sysclk) begin
  cycles=cycles+1;
  if(dut.init_done && dut.sdram_state==1) begin
    slots[dut.slot_type]=slots[dut.slot_type]+1;
    if(dut.slot_type==1) begin
      if(chipRW) chip_reads=chip_reads+1;
      else chip_writes=chip_writes+1;
    end
  end
  if(walker_ack[0]) begin
    if(walker_we) writes=writes+1; else reads=reads+1;
  end
  #1;
  if(cycles>2 && (observed[0] !== observed[1] ||
                 dut.sd_data_en !== reference.sd_data_en)) begin
    $display("cycle=%0d state=%0d reset_n=%b init_done=%b",cycles,dut.sdram_state,reset_n,dut.init_done);
    $display("got=%h ref=%h oe=%b/%b",observed[0],observed[1],dut.sd_data_en,reference.sd_data_en);
    $fatal(1,"FAIL: controller outputs differ");
  end
end
integer phase, k, seed;
initial begin
  for(k=0;k<6;k=k+1) slots[k]=0;
  if($value$plusargs("seed=%d",seed)) rng=seed;
  repeat(20) @(negedge sysclk);
  #1 reset_n=1;
  for(phase=0;phase<16;phase=phase+1) begin
    wait(dut.init_done);
    repeat(1500) @(negedge sysclk);
    // Pull the slot clock away from its old phase, exercising resynchronization.
    #1 clkdiv=phase[3:0]; phase_jumps=phase_jumps+1;
    repeat(700) @(negedge sysclk);
    while(dut.sdram_state!=phase) @(negedge sysclk);
    #1 reset_n=0; reset_phases[phase]=1; resets=resets+1;
    repeat(1+phase%3) @(negedge sysclk);
    #1 reset_n=1;
  end
  wait(dut.init_done);
  repeat(2000) @(negedge sysclk);
  for(k=0;k<6;k=k+1)
    if(slots[k]==0) $fatal(1,"FAIL: no coverage of slot type %0d",k);
  if(reads==0 || writes==0 || chip_reads==0 || chip_writes==0 || reset_phases!=16'hffff)
    $fatal(1,"FAIL: incomplete coverage");
  $display("ALL TESTS PASSED: %0d cycles; slots=%0d/%0d/%0d/%0d/%0d/%0d; walker=%0d/%0d chip=%0d/%0d; resets=%0d phase_jumps=%0d",
    cycles,slots[0],slots[1],slots[2],slots[3],slots[4],slots[5],reads,writes,chip_reads,chip_writes,resets,phase_jumps);
  $finish;
end
initial begin #1000000; $fatal(1,"FAIL: timeout"); end
endmodule
