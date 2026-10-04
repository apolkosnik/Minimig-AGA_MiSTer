// ap020_fastram_fe unit bench: the native port and the pin route (the
// MC68030 bus: STERM, CBACK bursts, CIOUT) sharing the line buffers, the
// 8 KiB cache and the DDR3 queues.
`timescale 1ns/1ps
module tb_native_cache;
  reg clk=0; always #5 clk=~clk;
  reg rst=1;
  reg [31:0] a=0;
  reg [2:0] fc=5;
  reg [1:0] siz=0;
  reg rw=1, as_n=1, d_oe=0, cbreq_n=1, sel=1, ci=0, clear=0;
  reg [31:0] d_o=0;
  wire [28:0] ddr_addr=a[31:3];
  wire sterm_n,cback_n;
  wire [31:0] d_i;
  wire cmd_we,rsp_re;
  wire [101:0] cmd_wdata;
  reg [3:0] cmd_wlevel=0;
  reg [63:0] rsp_rdata=0;
  reg rsp_rempty=1;
  reg n_req=0;
  wire n_ready,n_valid,n_last;
  reg [31:0] n_addr=0,n_wdata=0;
  wire [28:0] n_ddr_addr=n_addr[31:3];
  reg [2:0] n_fc=5;
  reg n_rw=1,n_ci=0,n_burst=0;
  reg [3:0] n_be=0;
  wire [1:0] n_word;
  wire [31:0] n_rdata;
  ap020_fastram_fe #(.NATIVE_PORT(1)) dut(.*);

  reg [63:0] mem[0:8191];
  integer read_commands=0, write_commands=0;
  integer backend_delay=9, backend_gap=3;
  integer due=0, pending=0, half=0, base=0, ticks=0;
  integer i,j;
  reg [63:0] captured0,captured1;
  // In-order backend model, including gaps between the two response beats.
  // Memory words use the real DDR bridge's 16-bit-word packing.
  always @(posedge clk) begin
    ticks=ticks+1;
    if(cmd_we) begin
      if(cmd_wdata[101]) begin
        write_commands=write_commands+1;
        for(integer b=0;b<8;b=b+1)
          if(cmd_wdata[64+b]) mem[cmd_wdata[100:72]][8*b+:8]=cmd_wdata[8*b+:8];
      end else begin
        if(pending) $fatal(1,"overlapping backend reads");
        read_commands=read_commands+1;
        pending=1; half=0; base=cmd_wdata[100:72]; due=ticks+backend_delay;
        captured0=mem[base]; captured1=mem[base+1];
      end
    end
    if(rsp_re) begin
      rsp_rempty<=1;
      if(half==0) begin half=1; due=ticks+backend_gap; end
      else pending=0;
    end else if(pending && rsp_rempty && ticks>=due) begin
      rsp_rdata<=half ? captured1 : captured0;
      rsp_rempty<=0;
    end
  end

  function [31:0] memory_long(input [31:0] addr);
    reg [63:0] b;
    begin
      b=mem[addr>>3];
      memory_long=addr[2] ? {b[47:32],b[63:48]} : {b[15:0],b[31:16]};
    end
  endfunction
  function [31:0] merged(input [31:0] oldv,input [31:0] newv,input integer off,input integer n);
    reg [31:0] v;
    begin
      v=oldv;
      for(integer b=0;b<4;b=b+1)
        if(b>=off && b<off+n) v[31-8*b-:8]=newv[31-8*b-:8];
      merged=v;
    end
  endfunction
  task idle(input integer n);
    repeat(n) begin @(posedge clk); #1; end
  endtask
  task start_bus(input [31:0] addr,input bit reading,input [1:0] size,input bit inhibited,input bit instruction);
    begin
      @(negedge clk); #1;
      a=addr; rw=reading; siz=size; ci=inhibited; fc=instruction?6:5;
      as_n=1; d_oe=!reading; cbreq_n=1;
      @(negedge clk); #1; as_n=0;
    end
  endtask
  task end_bus;
    begin @(negedge clk); #1; as_n=1; cbreq_n=1; d_oe=0; idle(1); end
  endtask
  task wait_ack(output [31:0] value);
    integer timeout;
    bit accepted;
    begin
      timeout=0;
      do begin
        @(posedge clk); accepted=!sterm_n; value=d_i; #1;
        timeout=timeout+1;
        if(timeout>300) $fatal(1,"bus timeout a=%h",a);
      end while(!accepted);
    end
  endtask
  task read_long(input [31:0] addr,input [31:0] expected,input integer requests,input bit inhibited,input bit instruction);
    integer before_count;
    reg [31:0] got;
    begin
      before_count=read_commands;
      start_bus(addr,1,0,inhibited,instruction);
      wait_ack(got);
      if(got!==expected) $fatal(1,"read %h got %h expected %h",addr,got,expected);
      if(requests>=0 && read_commands-before_count!=requests)
        $fatal(1,"read %h issued %0d DDR requests expected %0d",addr,read_commands-before_count,requests);
      end_bus;
    end
  endtask
  task write_part(input [31:0] addr,input [31:0] value,input [1:0] size);
    integer before_count;
    reg [31:0] unused;
    begin
      before_count=write_commands;
      start_bus(addr,0,size,0,0); d_o=value;
      wait_ack(unused); end_bus; idle(2);
      if(write_commands-before_count!=1) $fatal(1,"write did not post exactly once");
    end
  endtask
  task flush;
    begin @(negedge clk); #1; clear=1; idle(1); clear=0; idle(515); end
  endtask
  task burst(input [31:0] addr,input integer requests);
    integer before_count;
    reg [31:0] got,word_addr;
    begin
      before_count=read_commands;
      start_bus(addr,1,0,0,1); cbreq_n=0;
      for(integer b=0;b<4;b=b+1) begin
        wait_ack(got);
        word_addr=(addr&32'hfffffff0)|(((addr+4*b)&15));
        if(got!==memory_long(word_addr)) $fatal(1,"burst %h beat %0d got %h",addr,b,got);
        if(cback_n) $fatal(1,"burst missing CBACK");
      end
      if(read_commands-before_count!=requests) $fatal(1,"burst request count");
      end_bus;
    end
  endtask


  task native_start(input [31:0] addr,input bit reading,input bit inhibited,
                    input bit instruction,input bit burst_mode,input [3:0] enables,input [31:0] data);
    integer timeout;
    bit accepted;
    begin
      @(negedge clk); #1;
      n_addr=addr; n_rw=reading; n_ci=inhibited; n_fc=instruction?6:5;
      n_burst=burst_mode; n_be=enables; n_wdata=data; n_req=1;
      timeout=0;
      do begin
        @(posedge clk); accepted=n_ready; #1; timeout=timeout+1;
        if(timeout>100) $fatal(1,"native request timeout");
      end while(!accepted);
      @(negedge clk); #1; n_req=0;
    end
  endtask
  task native_response(output [31:0] data,output bit last,output [1:0] word_index);
    integer timeout;
    bit received;
    begin
      timeout=0;
      do begin
        @(posedge clk); received=n_valid; data=n_rdata; last=n_last; word_index=n_word; #1;
        timeout=timeout+1;
        if(timeout>300) $fatal(1,"native response timeout addr=%h",n_addr);
      end while(!received);
    end
  endtask
  task native_read(input [31:0] addr,input bit inhibited,input bit instruction,
                   input bit burst_mode,input integer requests);
    integer before_count;
    reg [31:0] got,word_addr;
    reg [1:0] word_index;
    bit last;
    begin
      before_count=read_commands;
      native_start(addr,1,inhibited,instruction,burst_mode,0,0);
      for(integer b=0;b<(burst_mode?4:1);b=b+1) begin
        native_response(got,last,word_index);
        word_addr=(addr&32'hfffffff0)|((addr+4*b)&12);
        if(got!==memory_long(word_addr) || word_index!==word_addr[3:2])
          $fatal(1,"native read %h beat %0d got %h expected %h word %0d",addr,b,got,memory_long(word_addr),word_index);
        if(last !== (b==(burst_mode?3:0))) $fatal(1,"native last beat");
      end
      if(requests>=0 && read_commands-before_count!=requests)
        $fatal(1,"native read %h requested %0d DDR lines, expected %0d",addr,read_commands-before_count,requests);
    end
  endtask
  task native_write(input [31:0] addr,input [31:0] value,input [3:0] enables);
    integer before_count;
    reg [31:0] unused;
    reg [1:0] word_index;
    bit last;
    begin
      before_count=write_commands;
      native_start(addr,0,0,0,0,enables,value);
      native_response(unused,last,word_index);
      if(!last) $fatal(1,"write must have one response");
      idle(2);
      if(write_commands-before_count!=1) $fatal(1,"native write posting count");
    end
  endtask
  reg [31:0] expected,old_value,new_value,unused;
  integer n,off,word_index,before_count;
  reg [31:0] rng=32'h35279bad, random_addr;
  initial begin
    for(i=0;i<8192;i=i+1) mem[i]={32'hfedcba98^i,32'h01234567^(i*32'd17)};
    idle(3); rst=0; idle(515);
    read_long('h1000,memory_long('h1000),1,0,0);
    read_long('h1010,memory_long('h1010),1,0,0);
    read_long('h1000,memory_long('h1000),0,0,0);
    // Program/data share physical cache lines even when the tiny buffers miss.
    read_long('h1010,memory_long('h1010),0,0,1);
    $display("PASS cache retention and shared physical tags");

    // Check all words, offsets, byte/word/three-byte/long write sizes against
    // an independent byte merge, with the target absent from both buffers.
    for(word_index=0;word_index<4;word_index=word_index+1)
      for(n=1;n<=4;n=n+1)
        for(off=0;off<4;off=off+1) begin
          read_long('h1010,memory_long('h1010),0,0,0);
          read_long('h1010,memory_long('h1010),0,0,1);
          old_value=memory_long('h1000+4*word_index);
          new_value=32'h89abcdef^(word_index*'h1234+n*'h76543+off*'h1357);
          expected=merged(old_value,new_value,off,n);
          write_part('h1000+4*word_index+off,new_value,n[1:0]);
          if(memory_long('h1000+4*word_index)!==expected) $fatal(1,"DDR byte merge");
          read_long('h1000+4*word_index,expected,0,0,0);
        end
    $display("PASS 64 partial-write combinations with L2-only hits");

    flush;
    write_part('h1600,32'haabbccdd,0);
    read_long('h1600,32'haabbccdd,1,0,0);
    read_long('h1610,memory_long('h1610),1,0,0);
    read_long('h1600,32'haabbccdd,0,0,0);
    flush;
    read_long('h1000,memory_long('h1000),1,0,0);
    read_long('h3000,memory_long('h3000),1,0,0);
    read_long('h1000,memory_long('h1000),1,0,0);
    $display("PASS write-through/no-write-allocate and conflicting tags");

    // A bypassed external change becomes visible on CI reads and on a clear.
    old_value=memory_long('h1000);
    mem['h1000>>3]=64'h9876543212345678;
    read_long('h1000,memory_long('h1000),1,1,0);
    read_long('h1000,memory_long('h1000),1,1,0);
    flush;
    read_long('h1000,memory_long('h1000),1,0,0);
    flush;
    read_long('h1200,memory_long('h1200),1,1,0);
    read_long('h1200,memory_long('h1200),1,0,0);
    $display("PASS inhibited reads bypass and do not allocate; clear invalidates");

    for(i=0;i<4;i=i+1) begin
      flush;
      burst('h1800+4*i,1);
      read_long('h1810,memory_long('h1810),1,0,1);
      burst('h1800+4*i,0);
    end
    $display("PASS all four burst wrap positions, cold and cached");

    // Clear on each lookup/response phase: the pending cycle must finish,
    // and a later access must fetch again instead of resurrecting its fill.
    for(j=0;j<4;j=j+1) begin
      flush;
      fork
        begin read_long('h1a00,memory_long('h1a00),1,0,0); end
        begin
          if(j==0) wait(dut.l2s==1);
          else if(j==1) wait(cmd_we && !cmd_wdata[101]);
          else if(j==2) wait(rsp_re && !dut.rd_half);
          else wait(rsp_re && dut.rd_half);
          clear=1; @(posedge clk); #1; clear=0;
        end
      join
      read_long('h1a10,memory_long('h1a10),1,0,0);
      read_long('h1a00,memory_long('h1a00),1,0,0);
    end
    $display("PASS clear during lookup, outstanding read, and both response beats");

    // An abandoned read drains before the new transaction, without retaining
    // its old contents in either cache or line buffer.
    flush; backend_delay=25;
    start_bus('h1c00,1,0,0,0);
    wait(read_commands>0 && pending);
    @(negedge clk); #1; rst=1; as_n=1; idle(1); rst=0;
    mem['h1c00>>3]=64'hbbaa998877665544;
    read_long('h1c00,memory_long('h1c00),1,0,0);
    backend_delay=9;
    $display("PASS reset during outstanding read");

    flush; cmd_wlevel=8; before_count=read_commands;
    fork
      begin read_long('h1e00,memory_long('h1e00),1,0,0); end
      begin idle(20); if(read_commands!=before_count) $fatal(1,"read ignored full FIFO"); cmd_wlevel=0; end
    join
    cmd_wlevel=7; before_count=write_commands;
    fork
      begin write_part('h1e04,32'hdeadbeef,0); end
      begin idle(20); if(write_commands!=before_count || !sterm_n) $fatal(1,"write ignored FIFO pressure"); cmd_wlevel=0; end
    join
    read_long('h1e10,memory_long('h1e10),1,0,0);
    read_long('h1e04,32'hdeadbeef,0,0,0);
    $display("PASS FIFO pressure and posted-write visibility");
    // Exercise write tag mismatches and replacements across the full memory,
    // alternating program/data reads with varying latency and response gaps.
    for(integer trial=0;trial<1000;trial=trial+1) begin
      rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
      random_addr={16'd0,rng[15:2],2'b00};
      backend_delay=2+rng[19:16]; backend_gap=1+rng[22:20];
      if(rng[31:27]==0) flush;
      if(rng[24]) begin
        n=1+int'(rng[26:25]); off=int'(rng[28:27]);
        expected=merged(memory_long(random_addr),rng,off,n);
        write_part(random_addr+off,rng,n[1:0]);
        if(memory_long(random_addr)!==expected) $fatal(1,"random DDR write");
      end else expected=memory_long(random_addr);
      read_long(random_addr,expected,-1,rng[29],rng[30]);
    end
    $display("PASS 1000 deterministic mixed operations with variable backend latency");

    flush;
    // Both access routes share lines. Cover every burst start word, first
    // from DDR, then from L2, then from the opposite port's line buffer.
    for(integer first_word=0;first_word<4;first_word=first_word+1) begin
      flush;
      native_read('h2000+4*first_word,0,1,1,1);
      native_read('h2010,0,1,0,1);
      native_read('h2000+4*first_word,0,1,1,0);
      burst('h2000+4*first_word,0);
      read_long('h2010,memory_long('h2010),0,0,1);
      native_read('h2000+4*first_word,0,1,1,0);
    end
    $display("PASS native DDR/L2/buffer bursts and native/pin sharing");

    // Native writes must update copies used by locked pin-bus operations;
    // pin writes must likewise update the native path, with no allocation.
    for(integer bank=0;bank<4;bank=bank+1) begin
      for(integer mask=1;mask<16;mask=mask+1) begin
        native_read('h2010,0,0,0,-1); native_read('h2010,0,1,0,-1);
        old_value=memory_long('h2000+4*bank); new_value=32'h2468abcd^(bank*17+mask);
        expected=old_value;
        for(integer b=0;b<4;b=b+1) if(mask&(1<<b)) expected[8*b+:8]=new_value[8*b+:8];
        native_write('h2000+4*bank,new_value,mask[3:0]);
        if(memory_long('h2000+4*bank)!==expected) $fatal(1,"native lane merge");
        read_long('h2000+4*bank,expected,0,0,0);
        native_read('h2000+4*bank,0,1,0,0);
        native_read('h2010,0,0,0,-1); native_read('h2010,0,1,0,-1);
        write_part('h2000+4*bank,~new_value,0);
        native_read('h2000+4*bank,0,0,0,0);
      end
    end
    $display("PASS all native byte-enable masks and cross-port write visibility");

    native_read('h2000,0,0,0,0);
    mem['h2000>>3]=64'hffeeddccbbaa9988;
    native_read('h2000,1,0,0,1);
    native_read('h2000,1,0,0,1);
    flush;
    native_read('h2000,0,0,0,1);
    $display("PASS native CI bypass and cache clear");

    for(j=0;j<4;j=j+1) begin
      flush;
      fork
        begin native_read('h2200,0,0,1,1); end
        begin
          if(j==0) wait(dut.l2s==1);
          else if(j==1) wait(cmd_we && !cmd_wdata[101]);
          else if(j==2) wait(rsp_re && !dut.rd_half);
          else wait(rsp_re && dut.rd_half);
          clear=1; @(posedge clk); #1; clear=0;
        end
      join
      idle(515);
      // A fill crossed by clear must not survive even in its line buffer.
      native_read('h2200,0,0,0,1);
    end
    $display("PASS native clear during lookup/request/each response half");

    flush; backend_delay=25;
    native_start('h2400,1,0,0,0,0,0);
    wait(pending);
    @(negedge clk); #1; rst=1; idle(1); rst=0;
    mem['h2400>>3]=64'h123456789abcdef0;
    native_read('h2400,0,0,0,1);
    backend_delay=9;
    $display("PASS native reset-abandoned response draining");

    flush; cmd_wlevel=8; before_count=read_commands;
    fork
      begin native_read('h2600,0,0,1,1); end
      begin idle(20); if(read_commands!=before_count || n_ready) $fatal(1,"native full FIFO"); cmd_wlevel=0; end
    join
    cmd_wlevel=7; before_count=write_commands;
    fork
      begin native_write('h2604,32'h13579bdf,15); end
      begin idle(20); if(write_commands!=before_count || n_ready) $fatal(1,"native write FIFO pressure"); cmd_wlevel=0; end
    join
    native_read('h2604,0,0,0,0);
    $display("PASS native FIFO backpressure");

    for(integer trial=0;trial<1000;trial=trial+1) begin
      rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
      random_addr={16'd0,rng[15:2],2'b00};
      backend_delay=2+rng[19:16]; backend_gap=1+rng[22:20];
      if(rng[31:27]==0) flush;
      if(rng[24]) begin
        if(rng[25]) native_write(random_addr,rng,rng[29:26]);
        else write_part(random_addr,rng,0);
      end
      if(rng[30]) native_read(random_addr,rng[29],rng[28],rng[26]&&!rng[29],-1);
      else read_long(random_addr,memory_long(random_addr),-1,rng[29],rng[28]);
    end
    $display("PASS 1000 mixed native/pin operations and latency variation");
    $display("ALL CACHE UNIT TESTS PASSED");
    $finish;
  end
  initial begin #10000000; $fatal(1,"global timeout"); end
endmodule
