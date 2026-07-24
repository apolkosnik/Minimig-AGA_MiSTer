// tb_walker_stale_rtg.v
// BUG #447 regression — walker Fast-RAM descriptor cycles must not inherit the
// stale CPU address attributes (sel_rtg byte-swap on ramdat, sel_dd ramshared).
//
// During a table walk, bus_addr = pmmu_addr_phys_p, which still holds the LAST
// COMPLETED translation. If that translation targeted RTG ($02xxxxxx) or the
// DD window, the pre-fix wrapper byte-swapped the walker's descriptor reads
// (ramdat) and routed U/M write-back through the DDR-shared swap (ramshared).
//
// Scenario:
//   1. Enable the MMU (CRP/TC as in tb_cpu_wrapper_pmmu).
//   2. Prime the ATC with an RTG page: MOVE.L ($02000200),D4 (identity map via
//      root entry 0). After this access addr_phys_reg = $020002xx.
//   3. CMPM.L (A3)+,(A4)+ reads RTG again (ATC hit, refreshes the stale RTG
//      physical address) and then immediately reads $20200200, whose page is
//      NOT in the ATC. The walk's second-level descriptor lives in Z2 Fast RAM
//      at $200004 and REMAPS the chunk to phys $00400000; its words ($0040,
//      $0061) are chosen so a byte-swap breaks the DT field (descriptor would
//      decode as invalid -> spurious MMU fault) - the pre-fix failure is loud.
//   4. MOVE.L ($20200200),D5 fetches the remapped payload ($CAFED00D) and a
//      final MOVE.W #$600D,($1300).W checkpoints completion.
//
// Checks:
//   a. ramshared == 0 whenever walker_fast_ram is asserted.
//   b. ramdat == ramdout (no swap) on every walker Fast-RAM ready beat.
//   c. Coverage: at least one walker Fast-RAM beat happened with sel_rtg
//      stale-high (otherwise the scenario silently stopped exercising the bug).
//   d. End-to-end: D5 == $CAFED00D and the $1300 checkpoint write landed.
//
// Scenario 2 (BUG #464): after the main pass, ramready is forced to stick
// HIGH right after the walker consumes the low descriptor word of a fresh
// walk ($20400200). The walker then enters WALKER_READ_HIGH with ready still
// asserted; pre-fix it spun there forever (counter incremented, never
// compared, no req-drop check) - a hard hang. Post-fix the 2048-cycle
// watchdog fires: walker_timeout_error + BERR.
//
// Standing invariant (BUG #456): fastchip_sel must never assert while
// pmmu_suppress_bus is high (stale pmmu_addr_phys_p in busy/fault windows).

`timescale 1 ns / 1 ps

module tb_walker_stale_rtg;

  // ---------------- Clock / reset ----------------
  reg clk   = 1'b0;
  reg reset = 1'b0;
  reg ph1   = 1'b0;
  reg ph2   = 1'b0;

  localparam CLK_HALF = 5; // 100 MHz
  always #(CLK_HALF) clk <= ~clk;

  always @(posedge clk) ph1 <= ~ph1;
  always @(negedge clk) ph2 <= ~ph2;

  // ---------------- CPU config ----------------
  reg  [1:0] cpucfg     = 2'b10; // 68030
  reg  [2:0] fastramcfg = 3'b111;
  reg  [2:0] cachecfg   = 3'b011;
  reg        bootrom    = 1'b0;

  // ---------------- Chip bus ----------------
  wire [23:1] chip_addr;
  reg  [15:0] chip_dout;
  wire [15:0] chip_din;
  wire        chip_as, chip_uds, chip_lds, chip_rw;
  reg         chip_dtack = 1'b1;
  reg  [2:0]  chip_ipl   = 3'b111;

  // ---------------- Fastchip (tied off) ----------------
  reg  [15:0] fastchip_dout  = 16'h0;
  wire        fastchip_sel;
  wire        fastchip_lds, fastchip_uds, fastchip_rnw;
  wire        fastchip_lw;
  reg         fastchip_selack = 1'b0;
  reg         fastchip_ready  = 1'b0;

  // ---------------- SDRAM (Z2 fast RAM + turbochip + RTG) ----------------
  wire        ramsel;
  wire [28:1] ramaddr;
  wire [15:0] ramdin;
  reg  [15:0] ramdout;
  reg         ramready = 1'b0;
  wire        ramlds, ramuds, ramshared;

  // ---------------- Toccata / misc ----------------
  wire        toccata_ena;
  wire [7:0]  toccata_base;

  // ---------------- CPU state exports ----------------
  wire [1:0]  cpustate;
  wire [31:0] cacr;
  wire [31:0] nmi_addr;

  // ---------------- Cache port (simple model) ----------------
  wire        cache_req;
  wire [31:0] cache_addr;
  reg  [15:0] cache_data = 16'h4E71;
  reg         cache_ack  = 1'b0;
  wire        cache_burst;
  wire [2:0]  cache_burst_len;
  wire [28:1] cache_ramaddr;

  wire [6:0]  debug_fmt_err;
  wire        walker_active_out;
  wire        walker_writing_out;
  wire        pmmu_cache_inhibit_out;

  // ---------------- DUT ----------------
  cpu_wrapper #(.USE_68030_CACHE(1)) uut (
    .reset(reset),
    .reset_out(),
    .clk(clk),
    .ph1(ph1),
    .ph2(ph2),
    .cpucfg(cpucfg),
    .fastramcfg(fastramcfg),
    .cachecfg(cachecfg),
    .bootrom(bootrom),
    .chip_addr(chip_addr),
    .chip_dout(chip_dout),
    .chip_din(chip_din),
    .chip_as(chip_as),
    .chip_uds(chip_uds),
    .chip_lds(chip_lds),
    .chip_rw(chip_rw),
    .chip_dtack(chip_dtack),
    .chip_ipl(chip_ipl),
    .fastchip_dout(fastchip_dout),
    .fastchip_sel(fastchip_sel),
    .fastchip_lds(fastchip_lds),
    .fastchip_uds(fastchip_uds),
    .fastchip_rnw(fastchip_rnw),
    .fastchip_lw(fastchip_lw),
    .fastchip_selack(fastchip_selack),
    .fastchip_ready(fastchip_ready),
    .ramsel(ramsel),
    .ramaddr(ramaddr),
    .ramdin(ramdin),
    .ramdout(ramdout),
    .ramready(ramready),
    .ramlds(ramlds),
    .ramuds(ramuds),
    .ramshared(ramshared),
    .toccata_ena(toccata_ena),
    .toccata_base(toccata_base),
    .cpustate(cpustate),
    .cacr(cacr),
    .nmi_addr(nmi_addr),
    .cache_req(cache_req),
    .cache_addr(cache_addr),
    .cache_data(cache_data),
    .cache_ack(cache_ack),
    .cache_burst(cache_burst),
    .cache_burst_len(cache_burst_len),
    .cache_ramaddr(cache_ramaddr),
    .debug_fmt_err(debug_fmt_err),
    .walker_active_out(walker_active_out),
    .walker_writing_out(walker_writing_out),
    .pmmu_cache_inhibit_out(pmmu_cache_inhibit_out)
  );

  // ---------------- Force Zorro-config regs (bypass autoconfig) ----------------
  initial begin
    #1;
    force uut.z2ram_ena   = 1'b1;
    force uut.z3ram_ena0  = 1'b0;
    force uut.z3ram_ena1  = 1'b0;
    force uut.z3ram_base0 = 5'b00000;
    force uut.z3ram_base1 = 4'b0000;
  end

  // ---------------- Memory models ----------------
  reg [15:0] chipmem [0:1048575];   // 2 MB word-addressed
  reg [15:0] fastmem [0:4194303];   // 8 MB word-addressed, Z2 $200000-$9FFFFF

  // ---------------- Chip bus responder ----------------
  reg [1:0] chip_resp_cnt;
  always @(posedge clk) begin
    if (~reset) begin
      chip_dtack    <= 1'b1;
      chip_resp_cnt <= 2'd0;
      chip_dout     <= 16'h0;
    end else begin
      if (chip_as == 1'b0) begin
        if (chip_resp_cnt == 2'd0) begin
          chip_resp_cnt <= 2'd1;
          chip_dout     <= chipmem[{chip_addr[23:1]}];
        end else if (chip_resp_cnt == 2'd1) begin
          if (chip_rw == 1'b0)
            chipmem[{chip_addr[23:1]}] <= chip_din;
          chip_dtack    <= 1'b0;
          chip_resp_cnt <= 2'd2;
        end else begin
          chip_dtack    <= 1'b0;
        end
      end else begin
        chip_dtack    <= 1'b1;
        chip_resp_cnt <= 2'd0;
      end
    end
  end

  // ---------------- SDRAM responder (reads + writes + RTG) ----------------
  // Write cycles: walker descriptor U/M write-back (walker_writing) and CPU
  // writes (cpustate==3). Strobes ramuds/ramlds are active low.
  reg [15:0] ram_delay_cycles = 16'd2;
  reg [15:0] ram_cnt;
  wire ram_is_write = uut.walker_fast_ram ? uut.walker_writing : (cpustate == 2'b11);
  // Scenario 2 (BUG #464): once armed, ramready sticks high after the walker
  // consumes the LOW descriptor word, so the walker reaches WALKER_READ_HIGH
  // with a level-held ready that never deasserts.
  reg arm_stuck_after_low = 1'b0;
  reg ram_stuck_high      = 1'b0;
  always @(posedge clk) begin
    if (arm_stuck_after_low && uut.walker_state == 4'd3 && ramready)
      ram_stuck_high <= 1'b1;
    if (!arm_stuck_after_low)
      ram_stuck_high <= 1'b0;
  end
  always @(posedge clk) begin
    if (~reset) begin
      ramready <= 1'b0;
      ramdout  <= 16'h0;
      ram_cnt  <= 16'd0;
    end else begin
      ramready <= 1'b0;
      if (ramsel) begin
        if (ram_cnt < ram_delay_cycles)
          ram_cnt <= ram_cnt + 16'd1;
        else begin
          ramready <= 1'b1;
          ram_cnt  <= 16'd0;
          if (ram_is_write) begin
            if (ramaddr[28:21] == 8'h00) begin
              if (!ramuds) chipmem[{ramaddr[20:1]}][15:8] <= ramdin[15:8];
              if (!ramlds) chipmem[{ramaddr[20:1]}][7:0]  <= ramdin[7:0];
            end else if (ramaddr[28:27] == 2'b11) begin
              if (!ramuds) fastmem[{ramaddr[22:1]} - 22'h100000][15:8] <= ramdin[15:8];
              if (!ramlds) fastmem[{ramaddr[22:1]} - 22'h100000][7:0]  <= ramdin[7:0];
            end
          end else begin
            // Turbochip chip-RAM SDRAM path
            if (ramaddr[28:21] == 8'h00)
              ramdout <= chipmem[{ramaddr[20:1]}];
            // Z2 Fast RAM ($200000 byte base -> $100000 word base)
            else if (ramaddr[28:27] == 2'b11)
              ramdout <= fastmem[{ramaddr[22:1]} - 22'h100000];
            // RTG window (ramaddr[26:23]=1110): serve a fixed byte-asymmetric
            // pattern; the wrapper unswaps it for the CPU ($1234 per word).
            else if (ramaddr[28:23] == 6'b001110)
              ramdout <= 16'h3412;
            else
              ramdout <= 16'hDEAD;
          end
        end
      end else begin
        ram_cnt <= 16'd0;
      end

      // BUG #464 scenario override: level-held ready that never deasserts
      if (ram_stuck_high)
        ramready <= 1'b1;
    end
  end

  // ---------------- Cache response (CACR disabled; idle) ----------------
  always @(posedge clk) begin
    cache_ack <= 1'b0;
    if (cache_req) begin
      cache_ack  <= 1'b1;
      cache_data <= 16'h4E71;
    end
  end

  // ============================================================
  // Memory pre-load
  // ============================================================
  integer i;
  task preload_memory;
    begin
      for (i = 0; i < 1048576; i = i + 1) chipmem[i] = 16'h4E71;
      for (i = 0; i < 4194304; i = i + 1) fastmem[i] = 16'h4E71;

      // -------- Reset vectors --------
      chipmem[16'h0000 >> 1] = 16'h0001;  // SSP = $00010000
      chipmem[16'h0002 >> 1] = 16'h0000;
      chipmem[16'h0004 >> 1] = 16'h0000;  // PC = $00000400
      chipmem[16'h0006 >> 1] = 16'h0400;
      chipmem[16'h0008 >> 1] = 16'h0000;  // Bus-error vector = $00000500
      chipmem[16'h000A >> 1] = 16'h0500;
      chipmem[16'h007C >> 1] = 16'h0000;  // NMI vector
      chipmem[16'h007E >> 1] = 16'h0500;

      // Bus-error handler at $500: BRA.S to self — end-to-end checks then fail
      chipmem[16'h0500 >> 1] = 16'h60FE;

      // -------- CRP image at $001080, TC image at $001088 --------
      chipmem[16'h1080 >> 1] = 16'h8000;  // CRP_H = $80000002
      chipmem[16'h1082 >> 1] = 16'h0002;
      chipmem[16'h1084 >> 1] = 16'h0000;  // CRP_L = root table $6000
      chipmem[16'h1086 >> 1] = 16'h6000;
      chipmem[16'h1088 >> 1] = 16'h80D0;  // TC = $80D04780 (E=1 PS=8K TIA=4 TIB=7 TIC=8)
      chipmem[16'h108A >> 1] = 16'h4780;

      // -------- Root table at $006000: 16 early-term identity entries --------
      for (i = 0; i < 16; i = i + 1) begin
        chipmem[(16'h6000 + i*4) >> 1] = {i[7:0] << 4, 8'h00};
        chipmem[(16'h6002 + i*4) >> 1] = 16'h0061;
      end
      // Entry 2 ($20xxxxxx): pointer to second-level table in Z2 Fast RAM
      chipmem[(16'h6000 + 2*4) >> 1] = 16'h0020;
      chipmem[(16'h6002 + 2*4) >> 1] = 16'h0002;   // $00200002, DT=10

      // -------- Second-level (TIB) table in Z2 Fast RAM at $200000 --------
      // Entry i covers logical $20000000 + i*2MB. Entry 1 ($20200000..)
      // REMAPS to physical $00400000 with byte-asymmetric descriptor words:
      // $00400061 — a stale-RTG byte swap would turn the low word $0061 into
      // $6100 (DT=00, invalid) and the walk would fault instead of remap.
      for (i = 0; i < 128; i = i + 1) begin
        fastmem[(i*4)     >> 1] = 16'h0020;
        fastmem[(i*4 + 2) >> 1] = 16'h0061;
      end
      fastmem[(1*4)     >> 1] = 16'h0040;   // descriptor[31:16] at low address
      fastmem[(1*4 + 2) >> 1] = 16'h0061;   // descriptor[15:0]

      // -------- Remapped payload: logical $20200200 -> phys $00400200 --------
      // Z2 model index = (byte >> 1) - 22'h100000
      fastmem[22'h100100] = 16'hCAFE;
      fastmem[22'h100101] = 16'hD00D;

      // -------- Program at $000400 --------
      // PMOVE ($1080).W,CRP
      chipmem[16'h0400 >> 1] = 16'hF038;
      chipmem[16'h0402 >> 1] = 16'h4C00;
      chipmem[16'h0404 >> 1] = 16'h1080;
      // PFLUSHA
      chipmem[16'h0406 >> 1] = 16'hF000;
      chipmem[16'h0408 >> 1] = 16'h2400;
      // PMOVE ($1088).W,TC — enables MMU
      chipmem[16'h040A >> 1] = 16'hF038;
      chipmem[16'h040C >> 1] = 16'h4000;
      chipmem[16'h040E >> 1] = 16'h1088;
      // Pipeline settle
      chipmem[16'h0410 >> 1] = 16'h4E71;
      chipmem[16'h0412 >> 1] = 16'h4E71;
      chipmem[16'h0414 >> 1] = 16'h4E71;
      chipmem[16'h0416 >> 1] = 16'h4E71;
      chipmem[16'h0418 >> 1] = 16'h4E71;
      chipmem[16'h041A >> 1] = 16'h4E71;
      chipmem[16'h041C >> 1] = 16'h4E71;
      chipmem[16'h041E >> 1] = 16'h4E71;
      // $0420: MOVEA.L #$02000200,A3
      chipmem[16'h0420 >> 1] = 16'h267C;
      chipmem[16'h0422 >> 1] = 16'h0200;
      chipmem[16'h0424 >> 1] = 16'h0200;
      // $0426: MOVE.L (A3),D4 — prime RTG page in ATC
      chipmem[16'h0426 >> 1] = 16'h2813;
      // $0428: MOVEA.L #$20200200,A4
      chipmem[16'h0428 >> 1] = 16'h287C;
      chipmem[16'h042A >> 1] = 16'h2020;
      chipmem[16'h042C >> 1] = 16'h0200;
      // $042E: NOP
      chipmem[16'h042E >> 1] = 16'h4E71;
      // $0430: CMPM.L (A3)+,(A4)+ — RTG read immediately followed by the
      // ATC-missing $20200200 read: the walk starts with addr_phys stale=RTG
      chipmem[16'h0430 >> 1] = 16'hB98B;
      // $0432: MOVEA.L #$20200200,A4 (reload after post-increment)
      chipmem[16'h0432 >> 1] = 16'h287C;
      chipmem[16'h0434 >> 1] = 16'h2020;
      chipmem[16'h0436 >> 1] = 16'h0200;
      // $0438: MOVE.L (A4),D5 — remapped payload read
      chipmem[16'h0438 >> 1] = 16'h2A14;
      // $043A: MOVE.W #$600D,($1300).W — completion checkpoint
      chipmem[16'h043A >> 1] = 16'h31FC;
      chipmem[16'h043C >> 1] = 16'h600D;
      chipmem[16'h043E >> 1] = 16'h1300;
      // $0440-$047E: NOP slide - window for the harness to arm Scenario 2
      // (BUG #464) after detecting the $1300 checkpoint.
      for (i = 0; i < 32; i = i + 1)
        chipmem[(16'h0440 + i*2) >> 1] = 16'h4E71;
      // $0480: MOVEA.L #$20400200,A6 - page not yet in ATC -> fresh walk
      chipmem[16'h0480 >> 1] = 16'h2C7C;
      chipmem[16'h0482 >> 1] = 16'h2040;
      chipmem[16'h0484 >> 1] = 16'h0200;
      // $0486: MOVE.L (A6),D6 - the walk that gets the stuck-high ready
      chipmem[16'h0486 >> 1] = 16'h2C16;
      // $0488: NOP loop
      chipmem[16'h0488 >> 1] = 16'h4E71;
      chipmem[16'h048A >> 1] = 16'h60FC;
    end
  endtask

  // ============================================================
  // Scoreboard
  // ============================================================
  integer errors = 0;

  task pass(input [1023:0] msg);
    begin
      $display("[PASS] %0s  (time=%0t)", msg, $time);
    end
  endtask

  task fail(input [1023:0] msg);
    begin
      $display("[FAIL] %0s  (time=%0t)", msg, $time);
      errors = errors + 1;
    end
  endtask

  // ============================================================
  // Probes and invariants
  // ============================================================
  wire walker_fast_ram_p = uut.walker_fast_ram;
  wire sel_rtg_p         = uut.sel_rtg;
  wire sel_dd_p          = uut.sel_dd;

  integer n_walker_fast_beats  = 0;
  integer n_stale_rtg_windows  = 0;

  // BUG #447a: ramshared must never assert during a walker Fast-RAM cycle
  always @(posedge clk) begin
    if (reset && walker_fast_ram_p) begin
      if (ramshared !== 1'b0)
        fail("BUG #447: ramshared asserted during walker fast-RAM cycle (stale sel_dd)");
    end
  end

  // BUG #447b: walker read data must reach the walker unswapped
  always @(posedge clk) begin
    if (reset && walker_fast_ram_p && ramready) begin
      n_walker_fast_beats = n_walker_fast_beats + 1;
      if (sel_rtg_p) n_stale_rtg_windows = n_stale_rtg_windows + 1;
      if (uut.ramdat !== ramdout)
        fail("BUG #447: walker fast-RAM data byte-swapped by stale sel_rtg");
    end
  end

  // Walker-ownership invariant (same as tb_cpu_wrapper_pmmu)
  always @(posedge clk) begin
    if (reset && uut.walker_active && ramsel && !walker_fast_ram_p)
      fail("walker-ownership: ramsel high during walker but not walker-driven");
  end

  // BUG #456 invariant: fastchip_sel must be suppressed while the PMMU is
  // busy/faulted (pmmu_addr_phys_p is stale in those windows). Also count the
  // windows where the pre-fix decode would have asserted, for coverage.
  integer n_fastchip_suppress_windows = 0;
  always @(posedge clk) begin
    if (reset && uut.pmmu_suppress_bus) begin
      if (fastchip_sel)
        fail("BUG #456: fastchip_sel asserted during pmmu busy/fault window");
      if (uut.cpu_req && !uut.pmmu_addr_phys_p[31:24] && !uut.walker_active)
        n_fastchip_suppress_windows = n_fastchip_suppress_windows + 1;
    end
  end

  // ============================================================
  // Test orchestration
  // ============================================================
  integer timeout_cycles;

  initial begin
    $display("==== tb_walker_stale_rtg starting ====");
    preload_memory;
    #5;

    reset = 1'b0;
    #200;
    reset = 1'b1;

    // Wait for the remapped payload read to land in D5
    timeout_cycles = 0;
    while (uut.kernel_regfile_d5_p !== 32'hCAFED00D && timeout_cycles < 300000) begin
      @(posedge clk);
      timeout_cycles = timeout_cycles + 1;
    end
    if (uut.kernel_regfile_d5_p === 32'hCAFED00D)
      pass("remapped read completed: D5 = $CAFED00D (walk descriptor intact)");
    else
      fail("remapped read did not complete - walk descriptor corrupted or faulted");

    // Wait for the checkpoint write
    timeout_cycles = 0;
    while (chipmem[16'h1300 >> 1] !== 16'h600D && timeout_cycles < 100000) begin
      @(posedge clk);
      timeout_cycles = timeout_cycles + 1;
    end
    if (chipmem[16'h1300 >> 1] === 16'h600D)
      pass("checkpoint write at $1300 landed (no spurious fault after walk)");
    else
      fail("checkpoint write missing - CPU stuck (bus error spin?)");

    // Coverage: the walk must actually have run with sel_rtg stale-high,
    // otherwise this bench no longer tests BUG #447 at all.
    if (n_stale_rtg_windows >= 1)
      pass("coverage: walker fast-RAM beat(s) observed with stale sel_rtg high");
    else
      fail("coverage: no walker beat with stale sel_rtg - scenario broken");

    // -------- Scenario 2 (BUG #464): stuck-high ready in WALKER_READ_HIGH ----
    // Success criterion: the walker ESCAPES (walker_active drops) instead of
    // parking in READ_HIGH forever. The escape route is either the BUG #419
    // req-drop check (PMMU's internal ~500-cycle watchdog withdraws req) or
    // the wrapper's own 2048-cycle watchdog - pre-fix READ_HIGH checked
    // NEITHER, so walker_active stayed high for good and the CPU hard-hung.
    $display("-- Scenario 2: arming stuck-high ramready after next low-word beat ...");
    arm_stuck_after_low = 1'b1;

    // Wait for the stuck condition to actually engage (low word consumed)
    timeout_cycles = 0;
    while (!ram_stuck_high && timeout_cycles < 100000) begin
      @(posedge clk);
      timeout_cycles = timeout_cycles + 1;
    end
    if (!ram_stuck_high)
      fail("Scenario 2 (BUG #464): stuck-high never engaged - no fresh walk seen");
    else begin
      // Give the walker the wrapper watchdog budget (2048) plus slack.
      timeout_cycles = 0;
      while (uut.walker_active && timeout_cycles < 8192) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
      end
      if (!uut.walker_active)
        pass("Scenario 2 (BUG #464): walker escaped READ_HIGH on stuck-high ready");
      else
        fail("Scenario 2 (BUG #464): walker parked in READ_HIGH - no escape fired");
    end
    arm_stuck_after_low = 1'b0;

    $display("==== tb_walker_stale_rtg summary ====");
    $display("walker_fast_beats=%0d stale_rtg_windows=%0d fastchip_suppress_windows=%0d",
             n_walker_fast_beats, n_stale_rtg_windows, n_fastchip_suppress_windows);
    if (errors == 0)
      $display("RESULT: PASS (0 failures)");
    else
      $display("RESULT: FAIL (%0d failures)", errors);
    $finish;
  end

  // Global watchdog
  initial begin
    #5_000_000;
    $display("[TIMEOUT] global simulation watchdog at 5ms, errors=%0d", errors);
    $finish;
  end

endmodule
