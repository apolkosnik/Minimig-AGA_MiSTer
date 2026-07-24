// tb_l2_inhibit_snoop.v
// BUG #462 unit regression for cpu_cache_new (the L2 under the 030 cache).
//
// An INHIBITED CPU write (walker U/M descriptor write-back runs with
// cache_inhibit set via walker_active; any CI-mapped write too) must not
// leave a stale valid line: pre-fix the write-hit update was gated by
// !cache_inhibit and the line kept its PRE-WRITE data, so later cacheable
// reads hit stale data (OS re-reads a pre-update page-table longword and can
// write back U/M=0). Post-fix the matching way is INVALIDATED.
//
// Context: ddram_ctrl snoops every CPU write back into this cache, masking
// the bug on the DDR path - but sdram_ctrl's snoop port is wired to the
// CHIP/DMA port only, so on SDRAM-backed fast RAM the stale line was real.
// This bench drives cpu_cache_new directly, representing that exposure.

`timescale 1ns/1ps

// Minimal dual-port RAM model used by cpu_cache_new.
module dpram #(parameter AW = 8, parameter DW = 16)
(
	input                 clock,
	input      [AW-1:0]   address_a,
	input                 wren_a,
	input      [DW-1:0]   data_a,
	output     [DW-1:0]   q_a,
	input      [AW-1:0]   address_b,
	input                 wren_b,
	input      [DW-1:0]   data_b,
	output     [DW-1:0]   q_b
);
	reg [DW-1:0] mem [0:(1<<AW)-1];
	integer i;
	initial begin
		for (i = 0; i < (1<<AW); i = i + 1)
			mem[i] = {DW{1'b0}};
	end
	assign q_a = mem[address_a];
	assign q_b = mem[address_b];
	always @(posedge clock) begin
		if (wren_a) mem[address_a] <= data_a;
		if (wren_b) mem[address_b] <= data_b;
	end
endmodule

module tb_l2_inhibit_snoop;

  reg clk = 0;
  always #5 clk = ~clk;

  reg         rst = 1;
  reg  [3:0]  ctrl = 4'b0000;
  reg         inhibit = 0;
  reg         cs = 0;
  reg  [28:1] adr = 0;
  reg  [1:0]  bs = 2'b11;
  reg         we = 0, ir = 0, dr = 0;
  reg  [15:0] dat_w = 0;
  wire [15:0] dat_r;
  wire        ack;
  wire        wb_en;
  reg  [15:0] sdr_dat = 0;
  wire        req;
  reg         sack = 0;

  cpu_cache_new uut (
    .clk(clk), .rst(rst), .cpu_cache_ctrl(ctrl), .cache_inhibit(inhibit),
    .cpu_cs(cs), .cpu_adr(adr), .cpu_bs(bs), .cpu_we(we), .cpu_ir(ir), .cpu_dr(dr),
    .cpu_dat_w(dat_w), .cpu_dat_r(dat_r), .cpu_ack(ack), .wb_en(wb_en),
    .sdr_dat_r(sdr_dat), .sdr_read_req(req), .sdr_read_ack(sack),
    .snoop_act(1'b0), .snoop_adr(28'h0), .snoop_dat_w(16'h0), .snoop_bs(2'b00)
  );

  // Backing memory (write-through target), 64K words
  reg [15:0] mem [0:65535];
  integer errors = 0;
  integer n_fills = 0;

  // Fill server: critical-word-first, 4 words wrapping within the line.
  reg        serving = 0;
  reg [2:0]  scount = 0;
  reg [13:0] sline;
  reg [1:0]  soff;
  always @(posedge clk) begin
    sack <= 0;
    if (!serving) begin
      if (req) begin
        serving <= 1;
        scount  <= 0;
        sline   <= adr[16:3];
        soff    <= adr[2:1];
        n_fills <= n_fills + 1;
      end
    end else begin
      if (scount < 4) begin
        sack    <= 1;
        sdr_dat <= mem[{sline, soff + scount[1:0]}];
        scount  <= scount + 1;
      end else begin
        serving <= 0;
      end
    end
  end

  task fail(input [511:0] msg);
    begin
      $display("[FAIL] %0s (time=%0t)", msg, $time);
      errors = errors + 1;
    end
  endtask
  task pass(input [511:0] msg);
    begin
      $display("[PASS] %0s", msg);
    end
  endtask

  task do_read(input [28:1] a, input insn, input [15:0] exp,
               input expect_fill, input [511:0] label);
    integer t;
    integer fills_before;
    begin
      fills_before = n_fills;
      adr = a; ir = insn; dr = !insn; we = 0; bs = 2'b11;
      cs = 1;
      t = 0;
      while (ack !== 1'b1 && t < 200) begin @(posedge clk); #1; t = t + 1; end
      if (ack !== 1'b1)
        fail({label, ": no ack"});
      else begin
        if (dat_r !== exp) begin
          $display("[FAIL] %0s: got %04x expected %04x", label, dat_r, exp);
          errors = errors + 1;
        end else if (expect_fill && n_fills == fills_before)
          fail({label, ": expected a refill but line was served from cache"});
        else if (!expect_fill && n_fills != fills_before)
          fail({label, ": expected a cache hit but a fill happened"});
        else
          pass(label);
      end
      cs = 0; ir = 0; dr = 0;
      repeat (8) @(posedge clk);
      #1;
    end
  endtask

  task do_write(input [28:1] a, input [15:0] val, input inh);
    begin
      adr = a; we = 1; dr = 1; ir = 0; bs = 2'b11; dat_w = val;
      inhibit = inh;
      cs = 1;
      repeat (4) @(posedge clk);
      cs = 0; we = 0; dat_w = 0;
      inhibit = 0;
      mem[a[16:1]] = val;  // write-through lands in memory regardless
      repeat (6) @(posedge clk);
      #1;
    end
  endtask

  integer k;
  initial begin
    $display("==== tb_l2_inhibit_snoop (BUG #462) ====");
    for (k = 0; k < 65536; k = k + 1) mem[k] = 16'hA000 + k[11:0];

    rst = 1;
    repeat (10) @(posedge clk);
    rst = 0;
    ctrl = 4'b0011;   // I + D cache enable
    // wait out tag init
    repeat (600) @(posedge clk);

    // 1. D-read allocates; serves OLD value
    do_read(28'h0001000, 0, mem[16'h1000], 1, "D allocate (fill)");
    do_read(28'h0001000, 0, mem[16'h1000], 0, "D re-read hits");

    // 2. BUG #462 core: inhibited write must invalidate the matching line
    do_write(28'h0001000, 16'h5A5A, 1);
    do_read(28'h0001000, 0, 16'h5A5A, 1,
            "BUG #462: cacheable re-read after inhibited write refills fresh");

    // 3. Control: NORMAL write-hit still updates the line in place
    do_write(28'h0001000, 16'hC3C3, 0);
    do_read(28'h0001000, 0, 16'hC3C3, 0,
            "normal write-hit updates line (no refill)");

    // 4. I-side variant
    do_read(28'h0002000, 1, mem[16'h2000], 1, "I allocate (fill)");
    do_write(28'h0002000, 16'h1234, 1);
    do_read(28'h0002000, 1, 16'h1234, 1,
            "BUG #462: I-line invalidated by inhibited write");

    // 5. Double-match corner: same line valid in BOTH I and D tags
    do_read(28'h0003000, 0, mem[16'h3000], 1, "D allocate shared line");
    do_read(28'h0003000, 1, mem[16'h3000], 1, "I allocate shared line");
    do_write(28'h0003000, 16'h7E7E, 1);
    do_read(28'h0003000, 0, 16'h7E7E, 1,
            "BUG #462: D side of shared line invalidated");
    do_read(28'h0003000, 1, 16'h7E7E, 1,
            "BUG #462: I side of shared line invalidated (deferred WB slot)");

    $display("==== summary: errors=%0d ====", errors);
    if (errors == 0) $display("RESULT: PASS (0 failures)");
    else $display("RESULT: FAIL (%0d failures)", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("[TIMEOUT] watchdog");
    $finish;
  end

endmodule
