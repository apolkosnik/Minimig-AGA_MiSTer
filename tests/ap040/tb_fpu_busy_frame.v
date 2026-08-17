`timescale 1ns/1ps

// Focused native-FPU check for the revision-$41 E3/busy state payload.
// The full AP040 program exercises exception delivery; this test drives the
// FPU directly so the frame decision and captured intermediate operands can
// be checked without depending on a particular exception handler.
module tb_fpu_busy_frame;
  reg clk = 0;
  always #5 clk = ~clk;

  reg nreset = 0;
  reg ce = 1;
  reg req = 0;
  reg [2:0] op_class = 0, src_fmt = 0, src_r = 0, dst_r = 0;
  reg [6:0] opmode = 0;
  reg [95:0] din = 0;
  wire done, accepted, unimp, unsupp, exc_req;
  wire [7:0] exc_vec;
  wire [95:0] dout;
  wire [3:0] fpcc;
  reg [1:0] cr_sel = 0;
  reg cr_we = 0;
  reg [31:0] cr_wdata = 0;
  wire [31:0] cr_rdata;
  reg bsun_req = 0;
  wire bsun_enable;
  reg ia_we = 0;
  reg [31:0] ia_wdata = 32'h12345678;
  reg [2:0] fm_sel = 0;
  reg fm_we = 0;
  reg [95:0] fm_wdata = 0;
  wire [95:0] fm_rdata;
  wire fpu_used, fstate_unimp, fstate_e1, fstate_busy;
  wire [15:0] fstate_cmd1, fstate_cmd3;
  wire [2:0] fstate_stag, fstate_dtag, fstate_flags;
  wire [95:0] fstate_fpt, fstate_et;
  wire [31:0] fstate_cusavepc, fstate_fpiarcu;
  wire [31:0] fstate_wbt0, fstate_wbt1, fstate_wbt2;
  wire fstate_wbtm66, fstate_wbte15;
  wire [2:0] fstate_grs;

  reg fsave_ack = 0, frestore_idle = 0, frestore_unimp = 0;
  reg frestore_busy = 0;
  reg [15:0] frestore_cmd1 = 0, frestore_cmd3 = 0;
  reg [2:0] frestore_stag = 0, frestore_dtag = 0, frestore_flags = 0;
  reg [95:0] frestore_fpt = 0, frestore_et = 0;
  reg [31:0] frestore_cusavepc = 0, frestore_fpiarcu = 0;
  reg [31:0] frestore_wbt0 = 0, frestore_wbt1 = 0, frestore_wbt2 = 0;
  reg frestore_wbtm66 = 0;
  reg [2:0] frestore_grs = 0;
  reg frestore_wbte15 = 0;
  reg fp_reset = 0;

  ap040_fpu dut (
    .clk(clk), .nreset(nreset), .ce(ce), .req(req),
    .op_class(op_class), .opmode(opmode), .src_fmt(src_fmt),
    .src_r(src_r), .dst_r(dst_r), .din(din), .done(done),
    .accepted(accepted), .unimp(unimp), .unsupp(unsupp),
    .exc_req(exc_req), .exc_vec(exc_vec), .dout(dout), .fpcc(fpcc),
    .cr_sel(cr_sel), .cr_we(cr_we), .cr_wdata(cr_wdata),
    .cr_rdata(cr_rdata), .bsun_req(bsun_req), .bsun_enable(bsun_enable),
    .ia_we(ia_we), .ia_wdata(ia_wdata), .fm_sel(fm_sel), .fm_we(fm_we),
    .fm_wdata(fm_wdata), .fm_rdata(fm_rdata), .fpu_used(fpu_used),
    .fstate_unimp(fstate_unimp), .fstate_e1(fstate_e1),
    .fstate_busy(fstate_busy), .fstate_cmd1(fstate_cmd1),
    .fstate_cmd3(fstate_cmd3), .fstate_stag(fstate_stag),
    .fstate_dtag(fstate_dtag), .fstate_flags(fstate_flags),
    .fstate_fpt(fstate_fpt), .fstate_et(fstate_et),
    .fstate_cusavepc(fstate_cusavepc), .fstate_fpiarcu(fstate_fpiarcu),
    .fstate_wbt0(fstate_wbt0), .fstate_wbt1(fstate_wbt1),
    .fstate_wbt2(fstate_wbt2), .fstate_wbtm66(fstate_wbtm66),
    .fstate_grs(fstate_grs), .fstate_wbte15(fstate_wbte15),
    .fsave_ack(fsave_ack), .frestore_idle(frestore_idle),
    .frestore_unimp(frestore_unimp), .frestore_busy(frestore_busy),
    .frestore_cmd1(frestore_cmd1), .frestore_cmd3(frestore_cmd3),
    .frestore_stag(frestore_stag), .frestore_dtag(frestore_dtag),
    .frestore_flags(frestore_flags), .frestore_fpt(frestore_fpt),
    .frestore_et(frestore_et), .frestore_cusavepc(frestore_cusavepc),
    .frestore_fpiarcu(frestore_fpiarcu), .frestore_wbt0(frestore_wbt0),
    .frestore_wbt1(frestore_wbt1), .frestore_wbt2(frestore_wbt2),
    .frestore_wbtm66(frestore_wbtm66), .frestore_grs(frestore_grs),
    .frestore_wbte15(frestore_wbte15), .fpu_rte(1'b0), .fp_reset(fp_reset)
  );

  task write_fp;
    input [2:0] r;
    input [95:0] v;
    begin
      @(negedge clk); fm_sel = r; fm_wdata = v; fm_we = 1;
      @(negedge clk); fm_we = 0;
    end
  endtask

  task write_cr;
    input [1:0] s;
    input [31:0] v;
    begin
      @(negedge clk); cr_sel = s; cr_wdata = v; cr_we = 1;
      @(negedge clk); cr_we = 0;
    end
  endtask

  integer i;
  initial begin
    repeat (2) @(negedge clk);
    nreset = 1;
    // +1.0 in FP0 and +3.0 in FP1.
    write_fp(3'd0, 96'h3fff0000_80000000_00000000);
    write_fp(3'd1, 96'h40000000_c0000000_00000000);
    // Enable INEX2 (FPSR exception bit 9).
    write_cr(2'd2, 32'h00000200);
    repeat (2) @(posedge clk);

    // FDIV.X FP1,FP0: 1/3 is an E3 inexact result.
    @(negedge clk);
    op_class = 3'b000; opmode = 7'h20; src_fmt = 3'd7;
    src_r = 3'd1; dst_r = 3'd0; req = 1;
    @(negedge clk); req = 0;

    i = 0;
    while (!exc_req && i < 300) begin @(posedge clk); i = i + 1; end
    if (!exc_req) $fatal(1, "timed out waiting for E3 exception");
    if (exc_vec != 8'd49) $fatal(1, "wrong exception vector %0d", exc_vec);
    if (!fstate_busy || fstate_unimp || fstate_e1)
      $fatal(1, "E3 did not leave a busy-only state frame");
    if (fstate_flags != 3'b010)
      $fatal(1, "wrong E3 flags %b", fstate_flags);
    if (fstate_et != 96'h40000000_c0000000_00000000)
      $fatal(1, "source ETEMP mismatch %h", fstate_et);
    if (fstate_fpt != 96'h3fff0000_80000000_00000000)
      $fatal(1, "destination FPTEMP mismatch %h", fstate_fpt);
    if (fstate_cmd3[15:13] != 3'b000 || fstate_cmd3[6:0] == 0)
      $fatal(1, "CMDREG3B was not captured: %h", fstate_cmd3);

    // FSAVE acknowledgement retires the pending frame.
    @(negedge clk); fsave_ack = 1;
    @(negedge clk); fsave_ack = 0;
    @(posedge clk);
    if (fstate_busy) $fatal(1, "FSAVE did not retire busy state");

    // A divide-by-zero is an E1 frame and must remain saveable until the
    // handler acknowledges it (or completes RTE).
    write_fp(3'd1, 96'd0);
    write_cr(2'd2, 32'h00000400);
    @(negedge clk);
    op_class = 3'b000; opmode = 7'h20; src_fmt = 3'd7;
    src_r = 3'd1; dst_r = 3'd0; req = 1;
    @(negedge clk); req = 0;
    i = 0;
    while (!exc_req && i < 100) begin @(posedge clk); i = i + 1; end
    if (!exc_req || exc_vec != 8'd50 || !fstate_e1 || fstate_busy ||
        fstate_unimp || fstate_flags != 3'b100)
      $fatal(1, "E1 divide-by-zero state was not retained");
    @(negedge clk); fsave_ack = 1;
    @(negedge clk); fsave_ack = 0;
    @(posedge clk);
    if (fstate_e1) $fatal(1, "E1 FSAVE did not retire state");

    // A restored native command in the 52-byte frame is E1 state, not a
    // vector-11 unimplemented instruction frame.
    frestore_cmd1 = 16'h1c20; // opclass 000, X source, FDIV
    frestore_cmd3 = 16'h1c20;
    frestore_stag = 3'd0;
    frestore_dtag = 3'd0;
    frestore_flags = 3'b100;
    frestore_fpt = 96'h3fff0000_80000000_00000000;
    frestore_et = 96'h40000000_c0000000_00000000;
    @(negedge clk); frestore_unimp = 1;
    @(negedge clk); frestore_unimp = 0;
    if (!fstate_e1 || fstate_unimp || fstate_busy)
      $fatal(1, "FRESTORE misclassified native E1 frame");
    @(negedge clk); fsave_ack = 1;
    @(negedge clk); fsave_ack = 0;
    @(posedge clk);
    if (fstate_e1) $fatal(1, "restored E1 state did not retire");

    // FRESTORE's decoded payload must reinstall the complete busy state.
    frestore_cmd1 = 16'h2468;
    frestore_cmd3 = 16'h1357;
    frestore_stag = 3'd2;
    frestore_dtag = 3'd1;
    frestore_flags = 3'b010;
    frestore_fpt = 96'h3fff0000_80000000_00000000;
    frestore_et = 96'h40000000_c0000000_00000000;
    frestore_cusavepc = 32'h000000fe;
    frestore_fpiarcu = 32'hfeedcafe;
    frestore_wbt0 = 32'h40000000;
    frestore_wbt1 = 32'hc0000000;
    frestore_wbt2 = 32'h00000000;
    frestore_wbtm66 = 1;
    frestore_grs = 3'd5;
    frestore_wbte15 = 1;
    @(negedge clk); frestore_busy = 1;
    @(negedge clk); frestore_busy = 0;
    if (!fstate_busy || fstate_cmd1 != frestore_cmd1 ||
        fstate_cmd3 != frestore_cmd3 || fstate_fpt != frestore_fpt ||
        fstate_et != frestore_et || fstate_cusavepc != frestore_cusavepc ||
        fstate_fpiarcu != frestore_fpiarcu || fstate_wbt0 != frestore_wbt0 ||
        fstate_wbtm66 != frestore_wbtm66 || fstate_grs != frestore_grs ||
        !fstate_wbte15)
      $fatal(1, "FRESTORE did not reinstall busy payload");
    @(negedge clk); fsave_ack = 1;
    @(negedge clk); fsave_ack = 0;
    @(posedge clk);
    if (fstate_busy) $fatal(1, "restored busy state did not retire");

    // Unsupported extended source data (vector 55) uses the 040 BUSY frame,
    // with the raw operand in ETEMP and the X-denormal tag.  This is the
    // state that software FPSP handlers preserve with FSAVE before retrying.
    write_fp(3'd1, 96'h00000000_40000000_00000000);
    @(negedge clk);
    op_class = 3'b000; opmode = 7'h20; src_fmt = 3'd7;
    src_r = 3'd1; dst_r = 3'd0; req = 1;
    @(negedge clk); req = 0;
    i = 0;
    while (!unsupp && i < 40) begin @(posedge clk); i = i + 1; end
    if (!unsupp || !fstate_busy || fstate_flags != 3'b000 ||
        fstate_stag != 3'd4 ||
        fstate_et != 96'h00000000_40000000_00000000)
      $fatal(1, "vector-55 extended payload was not captured");
    @(negedge clk); fsave_ack = 1;
    @(negedge clk); fsave_ack = 0;
    @(posedge clk);
    if (fstate_busy) $fatal(1, "vector-55 frame did not retire");

    // Packed output is an opclass-011 datatype fault: WinUAE marks both the
    // packed E1 bit and the T (store) bit while retaining the source twice.
    write_fp(3'd2, 96'h3fff0000_80000000_00000000);
    @(negedge clk);
    op_class = 3'b011; opmode = 7'h00; src_fmt = 3'd3;
    src_r = 3'd2; dst_r = 3'd0; req = 1;
    @(negedge clk); req = 0;
    i = 0;
    while (!unsupp && i < 40) begin @(posedge clk); i = i + 1; end
    if (!unsupp || !fstate_busy || fstate_flags != 3'b101 ||
        fstate_fpt != 96'h3fff0000_80000000_00000000 ||
        fstate_et != 96'h3fff0000_80000000_00000000)
      $fatal(1, "packed vector-55 payload was not captured");
    @(negedge clk); fsave_ack = 1;
    @(negedge clk); fsave_ack = 0;
    @(posedge clk);
    if (fstate_busy) $fatal(1, "packed vector-55 frame did not retire");

    // Packed source (opclass 010) uses the silicon/WinUAE undocumented
    // three-word shuffle rather than treating the bytes as an X operand.
    din = 96'h11223344_55667788_99aabbcc;
    @(negedge clk);
    op_class = 3'b010; opmode = 7'h20; src_fmt = 3'd3;
    src_r = 3'd0; dst_r = 3'd0; req = 1;
    @(negedge clk); req = 0;
    i = 0;
    while (!unsupp && i < 40) begin @(posedge clk); i = i + 1; end
    if (!unsupp || !fstate_busy || fstate_flags != 3'b100 ||
        fstate_stag != 3'd7 || fstate_dtag != 3'd0 ||
        fstate_et != 96'h00000000_55667788_99aabbcc ||
        fstate_fpt != 96'h00000000_55667788_11223344)
      $fatal(1, "packed source vector-55 shuffle mismatch");
    @(negedge clk); fsave_ack = 1;
    @(negedge clk); fsave_ack = 0;
    @(posedge clk);
    if (fstate_busy) $fatal(1, "packed source frame did not retire");

    $display("tb_fpu_busy_frame: ALL TESTS PASSED");
    $finish;
  end
endmodule
