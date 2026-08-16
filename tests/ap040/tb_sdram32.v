// tb_sdram32.v -- AP040X2 work package X2.1 deliverable gate.
//
// Three controllers run side by side on ONE stimulus stream at 113MHz:
//
//   ctl_ref   rtl/sdram_ctrl.v          + 1 behavioral SDRAM  (the original)
//   ctl_d     rtl/sdram32_ctrl.v DUAL=1 + 2 behavioral SDRAMs (the new bus)
//   ctl_z     rtl/sdram32_ctrl.v DUAL=0 + 1 behavioral SDRAM  (fallback build)
//
// The three memories hold the SAME logical image: the reference and the
// DUAL=0 model index it as 16-bit words, the dual pair splits it so the
// primary holds the odd (low) words of every longword and the secondary the
// even (high) words -- exactly the mapping sdram32_ctrl drives.
//
// What is proven here:
//   1. LOCKSTEP: every command pin driven to chip 2 (ras/cas/we/addr/ba/
//      cke/clk) equals chip 1's on EVERY cycle.  Only nCS/DQM/DQ differ, and
//      only where a 16-bit write masks one lane.
//   2. CHIPSET EQUIVALENCE: chipRD, chip48, cpuRD, ramready, walker_ack,
//      walker_rdata, snoop_tgl and snoop_addr of both sdram32_ctrl builds
//      are compared against the original controller cycle by cycle.
//   3. FILL LATENCY: the 32-bit line-fill port is measured from slot grant
//      to fourth beat and its data checked against memory.
//   4. LANE INTEGRITY: a 16-bit chipset/CPU write updates exactly one word;
//      the partner word in the same longword must not move.
//   5. COHERENCE: a chipset write is visible to the 32-bit fill port (the
//      check that fails if chipset traffic is confined to one chip).
//
// Build/run:
//   python3 prepare_sdram_sim.py ../../rtl/sdram_ctrl.v build/sdram_ctrl_sim.v
//   iverilog -g2012 -s tb_sdram32 -o /tmp/tb_sdram32.vvp tb_sdram32.v \
//       ../../rtl/sdram32_ctrl.v build/sdram_ctrl_sim.v \
//       ../../rtl/cpu_cache_new.v sim_dpram.v
//   vvp /tmp/tb_sdram32.vvp
//
// (sdram_ctrl.v needs prepare_sdram_sim.py's inout-reg rewrite for Icarus;
// sdram32_ctrl.v drives its buses with an explicit output enable and needs
// no rewrite.)

`timescale 100ps/100ps

//---------------------------------------------------------------------------
// Behavioral SDR SDRAM: 64K x 16 window, CL2, read burst 4 sequential with
// wrap, single-location write (mode word A9=1).  Same array + burst pipeline
// model as tests/ap040/tb_sdram_turbo.v, with nCS decoding and open-row
// bookkeeping added: sdram32_ctrl masks whole slots with nCS, and a second
// command inside one slot makes auto-precharge ordering worth policing.
//---------------------------------------------------------------------------
module sdram32_model
(
	input             clk,
	input             sd_clk,
	input             cs_n,
	input             ras_n,
	input             cas_n,
	input             we_n,
	input      [12:0] addr,
	input       [1:0] ba,
	input       [1:0] dqm,
	inout      [15:0] dq
);

reg [15:0] mem [0:32767];
reg [12:0] row [0:3];
reg  [2:0] pre_busy [0:3];      // auto-precharge busy countdown per bank
reg        bank_open [0:3];
integer    ap_viol = 0;         // write into a precharging bank
integer    open_viol = 0;       // ACTIVE into an already open bank
integer    ref_viol = 0;        // AUTOREFRESH with a bank still open
integer    wr_count = 0;
reg [15:0] rd_pipe_dat [0:15];
reg        rd_pipe_en  [0:15];
integer    k;
integer    i;

wire [1:0]  c_ba = ba;
wire [24:1] lin_base = {c_ba, row[c_ba], addr[8:0]};

reg [15:0] sd_q = 0;
reg        sd_q_en = 0;
assign dq = sd_q_en ? sd_q : 16'hZZZZ;

reg  sdclk_q = 0;
wire chip_tick = sd_clk && !sdclk_q;

initial begin
	for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
	for (i = 0; i < 16; i = i + 1) begin
		rd_pipe_dat[i] = 16'h0000;
		rd_pipe_en[i]  = 1'b0;
	end
	for (i = 0; i < 4; i = i + 1) begin
		row[i]       = 13'd0;
		pre_busy[i]  = 3'd0;
		bank_open[i] = 1'b0;
	end
end

always @(posedge clk) begin
	sdclk_q <= sd_clk;
	if (chip_tick) begin
		// shift the read pipeline (one beat per CHIP clock)
		sd_q    <= rd_pipe_dat[0];
		sd_q_en <= rd_pipe_en[0];
		for (k = 0; k < 15; k = k + 1) begin
			rd_pipe_dat[k] <= rd_pipe_dat[k+1];
			rd_pipe_en[k]  <= rd_pipe_en[k+1];
		end
		rd_pipe_dat[15] <= 16'h0000;
		rd_pipe_en[15]  <= 1'b0;

		for (k = 0; k < 4; k = k + 1)
			if (pre_busy[k] != 0) pre_busy[k] <= pre_busy[k] - 1'd1;

		if (!cs_n) begin
			if (!ras_n && cas_n && we_n) begin
				// ACTIVE
				if (bank_open[ba]) begin
					$display("SDRAM MODEL: ACTIVE into open bank %0d at t=%0t", ba, $time);
					open_viol = open_viol + 1;
				end
				row[ba]       <= addr;
				bank_open[ba] <= 1'b1;
			end
			else if (!ras_n && cas_n && !we_n) begin
				// PRECHARGE (A10: all banks)
				if (addr[10]) begin
					bank_open[0] <= 1'b0; bank_open[1] <= 1'b0;
					bank_open[2] <= 1'b0; bank_open[3] <= 1'b0;
				end
				else bank_open[ba] <= 1'b0;
			end
			else if (!ras_n && !cas_n && we_n) begin
				// AUTOREFRESH: every bank must be idle
				if (bank_open[0] || bank_open[1] || bank_open[2] || bank_open[3]) begin
					$display("SDRAM MODEL: AUTOREFRESH with an open bank at t=%0t", $time);
					ref_viol = ref_viol + 1;
				end
			end
			else if (ras_n && !cas_n && we_n) begin : do_read
				// READ, burst of 4 sequential, wrapping inside the aligned
				// 4-unit block (the caches fill critical-word-first and
				// rely on that wrap)
				reg [24:1] lin;
				lin = lin_base;
				for (k = 0; k < 4; k = k + 1) begin
					rd_pipe_dat[k] <= mem[{lin[15:3], lin[2:1] + k[1:0]}];
					rd_pipe_en[k]  <= 1'b1;
				end
				if (addr[10]) bank_open[ba] <= 1'b0;  // auto precharge
			end
			else if (ras_n && !cas_n && !we_n) begin : do_write
				// WRITE, single beat (mode A9=1), data and dqm with the command
				reg [24:1] lin;
				lin = lin_base;
				if (pre_busy[ba] != 0) begin
					$display("SDRAM MODEL: WRITE to precharging bank %0d IGNORED at t=%0t",
					         ba, $time);
					ap_viol = ap_viol + 1;
					disable do_write;
				end
				if (addr[10]) begin
					pre_busy[ba]  <= 3'd4;   // auto-precharge after tWR
					bank_open[ba] <= 1'b0;
				end
				if (!dqm[1]) mem[lin[15:1]][15:8] <= dq[15:8];
				if (!dqm[0]) mem[lin[15:1]][7:0]  <= dq[7:0];
				if (!dqm[1] || !dqm[0]) wr_count = wr_count + 1;
			end
		end
	end
end

endmodule


//---------------------------------------------------------------------------
// bench
//---------------------------------------------------------------------------
module tb_sdram32;

reg clk113 = 0;
always #44 clk113 = ~clk113;

reg [3:0] div = 0;
always @(posedge clk113) div <= div + 1'd1;

// 7MHz square for the SDRAM slot engine (16 clk113 per CCK)
wire c_7m = div[3];

reg reset = 0;

// nonblocking: every other block that samples cyc must see one stable value
// per clock, or a latency measured across two blocks is off by one
integer cyc = 0;
always @(posedge clk113) cyc <= cyc + 1;

integer errors  = 0;
integer lockerr = 0;
integer eqverr  = 0;
reg     mon_en  = 0;

//---------------------------------------------------------------------------
// shared stimulus
//---------------------------------------------------------------------------
reg [24:1] chipAddr = 24'h000000;
reg        chipL    = 1'b1;
reg        chipU    = 1'b1;
reg        chipRW   = 1'b1;
reg        chipDMA  = 1'b1;
reg [15:0] chipWR   = 16'h0000;

reg [24:1] cpuAddr  = 24'h000000;
reg        cpuCS    = 1'b0;
reg  [1:0] cpustate = 2'b01;
reg        cpuL     = 1'b1;
reg        cpuU     = 1'b1;
reg [15:0] cpuWR    = 16'h0000;

reg        wk_req   = 1'b0;
reg        wk_we    = 1'b0;
reg [24:2] wk_addr  = 23'd0;
reg [31:0] wk_wdata = 32'd0;

reg        fill_req  = 1'b0;
reg [24:4] fill_addr = 21'd0;

//---------------------------------------------------------------------------
// reference controller: rtl/sdram_ctrl.v + one 16-bit SDRAM
//---------------------------------------------------------------------------
wire [12:0] r_sd_addr;
wire  [1:0] r_sd_ba;
wire        r_sd_cs, r_sd_we, r_sd_ras, r_sd_cas, r_sd_clk, r_sd_cke;
wire  [1:0] r_sd_dqm;
wire [15:0] r_sd_data;

wire [15:0] r_chipRD;
wire [47:0] r_chip48;
wire [15:0] r_cpuRD;
wire        r_ramready;
wire        r_snoop_tgl;
wire [24:1] r_snoop_addr;
wire        r_wk_ack;
wire [31:0] r_wk_rdata;

sdram_ctrl #(.CPU_CACHE(1)) ctl_ref
(
	.sysclk(clk113), .c_7m(c_7m), .reset_n(reset), .cache_rst(reset),
	.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0011),

	.sd_addr(r_sd_addr), .sd_ba(r_sd_ba), .sd_cs(r_sd_cs), .sd_we(r_sd_we),
	.sd_ras(r_sd_ras), .sd_cas(r_sd_cas), .sd_dqm(r_sd_dqm),
	.sd_data(r_sd_data), .sd_clk(r_sd_clk), .sd_cke(r_sd_cke),

	.chipAddr(chipAddr), .chipL(chipL), .chipU(chipU), .chipRW(chipRW),
	.chipDMA(chipDMA), .chipWR(chipWR), .chipRD(r_chipRD),
	.snoop_tgl(r_snoop_tgl), .snoop_addr(r_snoop_addr), .chip48(r_chip48),

	.cpuAddr(cpuAddr), .cpuCS(cpuCS), .cpustate(cpustate), .cpuL(cpuL),
	.cpuU(cpuU), .cpuWR(cpuWR), .cpuRD(r_cpuRD), .ramready(r_ramready),

	.walker_req(wk_req), .walker_we(wk_we), .walker_addr(wk_addr),
	.walker_wdata(wk_wdata), .walker_ack(r_wk_ack), .walker_rdata(r_wk_rdata)
);

sdram32_model ram_ref
(
	.clk(clk113), .sd_clk(r_sd_clk), .cs_n(r_sd_cs), .ras_n(r_sd_ras),
	.cas_n(r_sd_cas), .we_n(r_sd_we), .addr(r_sd_addr), .ba(r_sd_ba),
	.dqm(r_sd_dqm), .dq(r_sd_data)
);

//---------------------------------------------------------------------------
// DUAL_SDRAM = 1 device under test + its pair of SDRAMs
//---------------------------------------------------------------------------
wire [12:0] d_sd_addr,  d_sd2_addr;
wire  [1:0] d_sd_ba,    d_sd2_ba;
wire        d_sd_cs,    d_sd2_cs;
wire        d_sd_we,    d_sd2_we;
wire        d_sd_ras,   d_sd2_ras;
wire        d_sd_cas,   d_sd2_cas;
wire  [1:0] d_sd_dqm,   d_sd2_dqm;
wire [15:0] d_sd_data,  d_sd2_data;
wire        d_sd_clk,   d_sd2_clk;
wire        d_sd_cke,   d_sd2_cke;

wire [15:0] d_chipRD;
wire [47:0] d_chip48;
wire [15:0] d_cpuRD;
wire        d_ramready;
wire        d_snoop_tgl;
wire [24:1] d_snoop_addr;
wire        d_wk_ack;
wire [31:0] d_wk_rdata;
wire [31:0] d_fill_dat;
wire        d_fill_strb;
wire        d_fill_ack;

sdram32_ctrl #(.CPU_CACHE(1), .DUAL_SDRAM(1)) ctl_d
(
	.sysclk(clk113), .c_7m(c_7m), .reset_n(reset), .cache_rst(reset),
	.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0011),

	.sd_addr(d_sd_addr), .sd_ba(d_sd_ba), .sd_cs(d_sd_cs), .sd_we(d_sd_we),
	.sd_ras(d_sd_ras), .sd_cas(d_sd_cas), .sd_dqm(d_sd_dqm),
	.sd_data(d_sd_data), .sd_clk(d_sd_clk), .sd_cke(d_sd_cke),

	.sd2_addr(d_sd2_addr), .sd2_ba(d_sd2_ba), .sd2_cs(d_sd2_cs),
	.sd2_we(d_sd2_we), .sd2_ras(d_sd2_ras), .sd2_cas(d_sd2_cas),
	.sd2_dqm(d_sd2_dqm), .sd2_data(d_sd2_data), .sd2_clk(d_sd2_clk),
	.sd2_cke(d_sd2_cke),

	.chipAddr(chipAddr), .chipL(chipL), .chipU(chipU), .chipRW(chipRW),
	.chipDMA(chipDMA), .chipWR(chipWR), .chipRD(d_chipRD),
	.snoop_tgl(d_snoop_tgl), .snoop_addr(d_snoop_addr), .chip48(d_chip48),

	.cpuAddr(cpuAddr), .cpuCS(cpuCS), .cpustate(cpustate), .cpuL(cpuL),
	.cpuU(cpuU), .cpuWR(cpuWR), .cpuRD(d_cpuRD), .ramready(d_ramready),

	.walker_req(wk_req), .walker_we(wk_we), .walker_addr(wk_addr),
	.walker_wdata(wk_wdata), .walker_ack(d_wk_ack), .walker_rdata(d_wk_rdata),

	.fill_req(fill_req), .fill_addr(fill_addr), .fill_dat(d_fill_dat),
	.fill_strb(d_fill_strb), .fill_ack(d_fill_ack)
);

sdram32_model ram_d1     // primary: D[15:0], odd (low) words
(
	.clk(clk113), .sd_clk(d_sd_clk), .cs_n(d_sd_cs), .ras_n(d_sd_ras),
	.cas_n(d_sd_cas), .we_n(d_sd_we), .addr(d_sd_addr), .ba(d_sd_ba),
	.dqm(d_sd_dqm), .dq(d_sd_data)
);

sdram32_model ram_d2     // secondary: D[31:16], even (high) words
(
	.clk(clk113), .sd_clk(d_sd2_clk), .cs_n(d_sd2_cs), .ras_n(d_sd2_ras),
	.cas_n(d_sd2_cas), .we_n(d_sd2_we), .addr(d_sd2_addr), .ba(d_sd2_ba),
	.dqm(d_sd2_dqm), .dq(d_sd2_data)
);

//---------------------------------------------------------------------------
// DUAL_SDRAM = 0 fallback build + its single SDRAM
//---------------------------------------------------------------------------
wire [12:0] z_sd_addr,  z_sd2_addr;
wire  [1:0] z_sd_ba,    z_sd2_ba;
wire        z_sd_cs,    z_sd2_cs;
wire        z_sd_we,    z_sd2_we;
wire        z_sd_ras,   z_sd2_ras;
wire        z_sd_cas,   z_sd2_cas;
wire  [1:0] z_sd_dqm,   z_sd2_dqm;
wire [15:0] z_sd_data,  z_sd2_data;
wire        z_sd_clk,   z_sd2_clk;
wire        z_sd_cke,   z_sd2_cke;

wire [15:0] z_chipRD;
wire [47:0] z_chip48;
wire [15:0] z_cpuRD;
wire        z_ramready;
wire        z_snoop_tgl;
wire [24:1] z_snoop_addr;
wire        z_wk_ack;
wire [31:0] z_wk_rdata;
wire [31:0] z_fill_dat;
wire        z_fill_strb;
wire        z_fill_ack;

sdram32_ctrl #(.CPU_CACHE(1), .DUAL_SDRAM(0)) ctl_z
(
	.sysclk(clk113), .c_7m(c_7m), .reset_n(reset), .cache_rst(reset),
	.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0011),

	.sd_addr(z_sd_addr), .sd_ba(z_sd_ba), .sd_cs(z_sd_cs), .sd_we(z_sd_we),
	.sd_ras(z_sd_ras), .sd_cas(z_sd_cas), .sd_dqm(z_sd_dqm),
	.sd_data(z_sd_data), .sd_clk(z_sd_clk), .sd_cke(z_sd_cke),

	.sd2_addr(z_sd2_addr), .sd2_ba(z_sd2_ba), .sd2_cs(z_sd2_cs),
	.sd2_we(z_sd2_we), .sd2_ras(z_sd2_ras), .sd2_cas(z_sd2_cas),
	.sd2_dqm(z_sd2_dqm), .sd2_data(z_sd2_data), .sd2_clk(z_sd2_clk),
	.sd2_cke(z_sd2_cke),

	.chipAddr(chipAddr), .chipL(chipL), .chipU(chipU), .chipRW(chipRW),
	.chipDMA(chipDMA), .chipWR(chipWR), .chipRD(z_chipRD),
	.snoop_tgl(z_snoop_tgl), .snoop_addr(z_snoop_addr), .chip48(z_chip48),

	.cpuAddr(cpuAddr), .cpuCS(cpuCS), .cpustate(cpustate), .cpuL(cpuL),
	.cpuU(cpuU), .cpuWR(cpuWR), .cpuRD(z_cpuRD), .ramready(z_ramready),

	.walker_req(wk_req), .walker_we(wk_we), .walker_addr(wk_addr),
	.walker_wdata(wk_wdata), .walker_ack(z_wk_ack), .walker_rdata(z_wk_rdata),

	.fill_req(fill_req), .fill_addr(fill_addr), .fill_dat(z_fill_dat),
	.fill_strb(z_fill_strb), .fill_ack(z_fill_ack)
);

sdram32_model ram_z
(
	.clk(clk113), .sd_clk(z_sd_clk), .cs_n(z_sd_cs), .ras_n(z_sd_ras),
	.cas_n(z_sd_cas), .we_n(z_sd_we), .addr(z_sd_addr), .ba(z_sd_ba),
	.dqm(z_sd_dqm), .dq(z_sd_data)
);

//---------------------------------------------------------------------------
// 1. lockstep command identity
//---------------------------------------------------------------------------
// The command word driven to chip 2 must equal chip 1's every cycle.  nCS,
// DQM and DQ are deliberately excluded: those are the lane controls.
wire lock_match =
	(d_sd_addr === d_sd2_addr) && (d_sd_ba  === d_sd2_ba ) &&
	(d_sd_ras  === d_sd2_ras ) && (d_sd_cas === d_sd2_cas) &&
	(d_sd_we   === d_sd2_we  ) && (d_sd_cke === d_sd2_cke) &&
	(d_sd_clk  === d_sd2_clk );

// the same identity is required of the fallback build (it drives both pin
// groups too, the board just has nothing on the second one)
wire lock_match_z =
	(z_sd_addr === z_sd2_addr) && (z_sd_ba  === z_sd2_ba ) &&
	(z_sd_ras  === z_sd2_ras ) && (z_sd_cas === z_sd2_cas) &&
	(z_sd_we   === z_sd2_we  ) && (z_sd_cke === z_sd2_cke) &&
	(z_sd_clk  === z_sd2_clk );

// CPU slots (write buffer, cache fill, walker, line fill) for the report
wire cpu_slot_d = (ctl_d.slot_type >= 3'd2);

always @(posedge clk113) begin
	if (reset) begin
		if (!lock_match) begin
			if (lockerr < 10)
				$display("FAIL: lockstep mismatch at cycle %0d (state %0d, slot %0d, cpu_slot=%b)",
				         cyc, ctl_d.sdram_state, ctl_d.slot_type, cpu_slot_d);
			lockerr = lockerr + 1;
			errors  = errors + 1;
		end
		if (!lock_match_z) begin
			if (lockerr < 10)
				$display("FAIL: lockstep mismatch (DUAL=0 build) at cycle %0d state %0d",
				         cyc, ctl_z.sdram_state);
			lockerr = lockerr + 1;
			errors  = errors + 1;
		end
	end
end

//---------------------------------------------------------------------------
// 2. cycle-by-cycle equivalence against the original controller
//---------------------------------------------------------------------------
task eq_chk;
	input [63:0] got_d;
	input [63:0] got_r;
	input [31:0] which;      // 0 = DUAL, 1 = fallback
	input [127:0] name;
	begin
		if (got_d !== got_r) begin
			if (eqverr < 20)
				$display("FAIL: %0s mismatch (%0s) at cycle %0d state %0d: dut=%h ref=%h",
				         name, which ? "DUAL=0" : "DUAL=1", cyc,
				         ctl_ref.sdram_state, got_d, got_r);
			eqverr = eqverr + 1;
			errors = errors + 1;
		end
	end
endtask

always @(posedge clk113) begin
	if (mon_en) begin
		eq_chk({48'd0, d_chipRD},  {48'd0, r_chipRD},  0, "chipRD");
		eq_chk({48'd0, z_chipRD},  {48'd0, r_chipRD},  1, "chipRD");
		eq_chk({16'd0, d_chip48},  {16'd0, r_chip48},  0, "chip48");
		eq_chk({16'd0, z_chip48},  {16'd0, r_chip48},  1, "chip48");
		eq_chk({48'd0, d_cpuRD},   {48'd0, r_cpuRD},   0, "cpuRD");
		eq_chk({48'd0, z_cpuRD},   {48'd0, r_cpuRD},   1, "cpuRD");
		eq_chk({63'd0, d_ramready},{63'd0, r_ramready},0, "ramready");
		eq_chk({63'd0, z_ramready},{63'd0, r_ramready},1, "ramready");
		eq_chk({63'd0, d_wk_ack},  {63'd0, r_wk_ack},  0, "walker_ack");
		eq_chk({63'd0, z_wk_ack},  {63'd0, r_wk_ack},  1, "walker_ack");
		eq_chk({32'd0, d_wk_rdata},{32'd0, r_wk_rdata},0, "walker_rdata");
		eq_chk({32'd0, z_wk_rdata},{32'd0, r_wk_rdata},1, "walker_rdata");
		eq_chk({63'd0, d_snoop_tgl},{63'd0, r_snoop_tgl},0, "snoop_tgl");
		eq_chk({63'd0, z_snoop_tgl},{63'd0, r_snoop_tgl},1, "snoop_tgl");
		eq_chk({40'd0, d_snoop_addr},{40'd0, r_snoop_addr},0, "snoop_addr");
		eq_chk({40'd0, z_snoop_addr},{40'd0, r_snoop_addr},1, "snoop_addr");
	end
end

//---------------------------------------------------------------------------
// fill port collectors and latency measurement
//---------------------------------------------------------------------------
reg [31:0] d_beat [0:3];
reg [31:0] z_beat [0:3];
integer    d_beats = 0;
integer    z_beats = 0;
integer    d_grant_cyc = -1;
integer    d_req_cyc   = -1;
integer    d_last_cyc  = -1;
integer    z_grant_cyc = -1;
integer    z_last_cyc  = -1;
reg        fill_req_q  = 0;
reg        d_fill_ack_seen = 0;
reg        z_fill_ack_seen = 0;

always @(posedge clk113) begin
	fill_req_q <= fill_req;
	if (fill_req && !fill_req_q) begin
		d_beats     = 0;
		z_beats     = 0;
		d_grant_cyc = -1;
		z_grant_cyc = -1;
		d_req_cyc   = cyc;
	end
	if (ctl_d.fill_grant && d_grant_cyc < 0) d_grant_cyc = cyc;
	if (ctl_z.fill_grant && z_grant_cyc < 0) z_grant_cyc = cyc;
	if (d_fill_strb) begin
		if (d_beats < 4) d_beat[d_beats] = d_fill_dat;
		d_beats    = d_beats + 1;
		d_last_cyc = cyc;
	end
	if (z_fill_strb) begin
		if (z_beats < 4) z_beat[z_beats] = z_fill_dat;
		z_beats    = z_beats + 1;
		z_last_cyc = cyc;
	end
	if (fill_req && !fill_req_q) begin
		d_fill_ack_seen <= 0;
		z_fill_ack_seen <= 0;
	end
	if (d_fill_ack) d_fill_ack_seen <= 1;
	if (z_fill_ack) z_fill_ack_seen <= 1;
end

//---------------------------------------------------------------------------
// memory image shadow + preload
//---------------------------------------------------------------------------
reg [15:0] shadow [0:32767];
integer    i;

// logical word address -> the three memory images.  The dual pair splits by
// the word-address LSB: odd words to the primary (D[15:0]), even words to
// the secondary (D[31:16]); its unit index is the longword index.
task poke_word;
	input [24:1] wa;
	input [15:0] d;
	begin
		shadow[wa[15:1]]    = d;
		ram_ref.mem[wa[15:1]] = d;
		ram_z.mem[wa[15:1]]   = d;
		if (wa[1]) ram_d1.mem[wa[15:2]] = d;
		else       ram_d2.mem[wa[15:2]] = d;
	end
endtask

function [15:0] pat;
	input [24:1] wa;
	begin
		pat = {wa[8:1], wa[16:9]} ^ 16'h5A5A;
	end
endfunction

//---------------------------------------------------------------------------
// stimulus helpers
//---------------------------------------------------------------------------
task wait_state;
	input [3:0] s;
	begin
		while (ctl_ref.sdram_state !== s) @(posedge clk113);
	end
endtask

// one chipset slot: signals presented during state 15, held for the whole
// slot, released at the next state 15 (Agnus holds for the CCK)
task chip_cycle;
	input [24:1] a;
	input        rw;
	input        u;
	input        l;
	input [15:0] d;
	begin
		wait_state(4'd14);
		@(posedge clk113);
		chipAddr <= a;
		chipRW   <= rw;
		chipU    <= u;
		chipL    <= l;
		chipWR   <= d;
		chipDMA  <= 1'b0;
		wait_state(4'd14);
		@(posedge clk113);
		chipDMA  <= 1'b1;
		chipRW   <= 1'b1;
		chipU    <= 1'b1;
		chipL    <= 1'b1;
		repeat (3) @(posedge clk113);   // let chip48_3 land
	end
endtask

reg [15:0] exp_w0, exp_w1, exp_w2, exp_w3;
reg [24:1] tmp_wa;

task chip_read_check;
	input [24:1] a;
	begin
		chip_cycle(a, 1'b1, 1'b0, 1'b0, 16'h0000);
		// the burst wraps inside the aligned 4-word block
		exp_w0 = shadow[{a[15:3], a[2:1] + 2'd0}];
		exp_w1 = shadow[{a[15:3], a[2:1] + 2'd1}];
		exp_w2 = shadow[{a[15:3], a[2:1] + 2'd2}];
		exp_w3 = shadow[{a[15:3], a[2:1] + 2'd3}];
		if (r_chipRD !== exp_w0) begin
			$display("FAIL: reference chipRD @%h = %h, expected %h",
			         {a, 1'b0}, r_chipRD, exp_w0);
			errors = errors + 1;
		end
		if (d_chipRD !== exp_w0) begin
			$display("FAIL: DUAL chipRD @%h = %h, expected %h",
			         {a, 1'b0}, d_chipRD, exp_w0);
			errors = errors + 1;
		end
		if (d_chip48 !== {exp_w1, exp_w2, exp_w3}) begin
			$display("FAIL: DUAL chip48 @%h = %h, expected %h%h%h",
			         {a, 1'b0}, d_chip48, exp_w1, exp_w2, exp_w3);
			errors = errors + 1;
		end
		if (r_chip48 !== {exp_w1, exp_w2, exp_w3}) begin
			$display("FAIL: reference chip48 @%h = %h, expected %h%h%h",
			         {a, 1'b0}, r_chip48, exp_w1, exp_w2, exp_w3);
			errors = errors + 1;
		end
	end
endtask

task chip_write;
	input [24:1] a;
	input        u;      // active low upper byte
	input        l;      // active low lower byte
	input [15:0] d;
	begin
		chip_cycle(a, 1'b0, u, l, d);
		if (!u) shadow[a[15:1]][15:8] = d[15:8];
		if (!l) shadow[a[15:1]][7:0]  = d[7:0];
	end
endtask

// CPU port through cpu_cache_new
integer cpu_to;
task cpu_read;
	input [24:1] a;
	input [15:0] exp;
	begin
		@(posedge clk113);
		cpuAddr  <= a;
		cpustate <= 2'b10;      // data read
		cpuU     <= 1'b0;
		cpuL     <= 1'b0;
		cpuCS    <= 1'b1;
		cpu_to = 0;
		@(posedge clk113);
		while (!(r_ramready && d_ramready && z_ramready) && cpu_to < 4000) begin
			@(posedge clk113);
			cpu_to = cpu_to + 1;
		end
		if (cpu_to >= 4000) begin
			$display("FAIL: cpu_read @%h timed out (ready r=%b d=%b z=%b)",
			         {a, 1'b0}, r_ramready, d_ramready, z_ramready);
			errors = errors + 1;
		end
		if (r_cpuRD !== exp) begin
			$display("FAIL: reference cpuRD @%h = %h, expected %h", {a,1'b0}, r_cpuRD, exp);
			errors = errors + 1;
		end
		if (d_cpuRD !== exp) begin
			$display("FAIL: DUAL cpuRD @%h = %h, expected %h", {a,1'b0}, d_cpuRD, exp);
			errors = errors + 1;
		end
		if (z_cpuRD !== exp) begin
			$display("FAIL: DUAL=0 cpuRD @%h = %h, expected %h", {a,1'b0}, z_cpuRD, exp);
			errors = errors + 1;
		end
		@(posedge clk113);
		cpuCS    <= 1'b0;
		cpustate <= 2'b01;
		cpuU     <= 1'b1;
		cpuL     <= 1'b1;
		repeat (6) @(posedge clk113);
	end
endtask

task cpu_write;
	input [24:1] a;
	input [15:0] d;
	begin
		@(posedge clk113);
		cpuAddr  <= a;
		cpustate <= 2'b11;      // write
		cpuU     <= 1'b0;
		cpuL     <= 1'b0;
		cpuWR    <= d;
		cpuCS    <= 1'b1;
		cpu_to = 0;
		@(posedge clk113);
		while (!(r_ramready && d_ramready && z_ramready) && cpu_to < 4000) begin
			@(posedge clk113);
			cpu_to = cpu_to + 1;
		end
		if (cpu_to >= 4000) begin
			$display("FAIL: cpu_write @%h timed out", {a, 1'b0});
			errors = errors + 1;
		end
		@(posedge clk113);
		cpuCS    <= 1'b0;
		cpustate <= 2'b01;
		cpuU     <= 1'b1;
		cpuL     <= 1'b1;
		shadow[a[15:1]] = d;
		repeat (40) @(posedge clk113);   // let the write buffer drain
	end
endtask

// walker port: level held until every controller has acknowledged
reg wk_seen_r, wk_seen_d, wk_seen_z;
always @(posedge clk113) begin
	if (!wk_req) begin
		wk_seen_r <= 0;
		wk_seen_d <= 0;
		wk_seen_z <= 0;
	end
	else begin
		if (r_wk_ack) wk_seen_r <= 1;
		if (d_wk_ack) wk_seen_d <= 1;
		if (z_wk_ack) wk_seen_z <= 1;
	end
end

integer wk_to;
task walker_xfer;
	input        we;
	input [24:2] a;
	input [31:0] d;
	begin
		@(posedge clk113);
		wk_we    <= we;
		wk_addr  <= a;
		wk_wdata <= d;
		wk_req   <= 1'b1;
		wk_to = 0;
		@(posedge clk113);
		while (!(wk_seen_r && wk_seen_d && wk_seen_z) && wk_to < 4000) begin
			@(posedge clk113);
			wk_to = wk_to + 1;
		end
		if (wk_to >= 4000) begin
			$display("FAIL: walker %0s @%h timed out (r=%b d=%b z=%b)",
			         we ? "write" : "read", {a, 2'b00},
			         wk_seen_r, wk_seen_d, wk_seen_z);
			errors = errors + 1;
		end
		@(posedge clk113);
		wk_req <= 1'b0;
		repeat (8) @(posedge clk113);
		if (we) begin
			tmp_wa = {a, 1'b0};
			shadow[tmp_wa[15:1]] = d[31:16];
			tmp_wa = {a, 1'b1};
			shadow[tmp_wa[15:1]] = d[15:0];
		end
	end
endtask

integer fill_to;
task fill_line;
	input [24:4] a;
	begin
		@(posedge clk113);
		fill_addr <= a;
		fill_req  <= 1'b1;
		fill_to = 0;
		@(posedge clk113);
		while (!(d_beats >= 4 && z_beats >= 4) && fill_to < 4000) begin
			@(posedge clk113);
			fill_to = fill_to + 1;
		end
		if (fill_to >= 4000) begin
			$display("FAIL: fill @%h timed out (dual beats=%0d, 16-bit beats=%0d)",
			         {a, 4'h0}, d_beats, z_beats);
			errors = errors + 1;
		end
		@(posedge clk113);
		fill_req <= 1'b0;
		repeat (8) @(posedge clk113);
	end
endtask

reg [31:0] exp_lw;
integer    b;
task fill_check;
	input [24:4] a;
	begin
		if (d_beats != 4) begin
			$display("FAIL: DUAL fill delivered %0d beats, expected 4", d_beats);
			errors = errors + 1;
		end
		if (z_beats != 4) begin
			$display("FAIL: DUAL=0 fill delivered %0d beats, expected 4", z_beats);
			errors = errors + 1;
		end
		if (!d_fill_ack_seen) begin
			$display("FAIL: DUAL fill_ack never asserted");
			errors = errors + 1;
		end
		if (!z_fill_ack_seen) begin
			$display("FAIL: DUAL=0 fill_ack never asserted");
			errors = errors + 1;
		end
		for (b = 0; b < 4; b = b + 1) begin
			tmp_wa = {a, b[1:0], 1'b0};
			exp_lw[31:16] = shadow[tmp_wa[15:1]];
			tmp_wa = {a, b[1:0], 1'b1};
			exp_lw[15:0]  = shadow[tmp_wa[15:1]];
			if (d_beat[b] !== exp_lw) begin
				$display("FAIL: DUAL fill @%h beat %0d = %h, expected %h",
				         {a, 4'h0}, b, d_beat[b], exp_lw);
				errors = errors + 1;
			end
			if (z_beat[b] !== exp_lw) begin
				$display("FAIL: DUAL=0 fill @%h beat %0d = %h, expected %h",
				         {a, 4'h0}, b, z_beat[b], exp_lw);
				errors = errors + 1;
			end
		end
	end
endtask

//---------------------------------------------------------------------------
// memory image verification
//---------------------------------------------------------------------------
integer mv;
integer mem_errors;
task verify_memory;
	begin
		mem_errors = 0;
		for (mv = 0; mv < 4096; mv = mv + 1) begin
			if (ram_ref.mem[mv] !== shadow[mv] && mem_errors < 10) begin
				$display("FAIL: reference memory word %0d = %h, expected %h",
				         mv, ram_ref.mem[mv], shadow[mv]);
				mem_errors = mem_errors + 1;
			end
			if (ram_z.mem[mv] !== shadow[mv] && mem_errors < 10) begin
				$display("FAIL: DUAL=0 memory word %0d = %h, expected %h",
				         mv, ram_z.mem[mv], shadow[mv]);
				mem_errors = mem_errors + 1;
			end
			if (mv[0]) begin
				if (ram_d1.mem[mv>>1] !== shadow[mv] && mem_errors < 10) begin
					$display("FAIL: primary memory word %0d (unit %0d) = %h, expected %h",
					         mv, mv>>1, ram_d1.mem[mv>>1], shadow[mv]);
					mem_errors = mem_errors + 1;
				end
			end
			else begin
				if (ram_d2.mem[mv>>1] !== shadow[mv] && mem_errors < 10) begin
					$display("FAIL: secondary memory word %0d (unit %0d) = %h, expected %h",
					         mv, mv>>1, ram_d2.mem[mv>>1], shadow[mv]);
					mem_errors = mem_errors + 1;
				end
			end
		end
		errors = errors + mem_errors;
		if (mem_errors == 0)
			$display("memory image: all three controllers hold the expected 8KB window");
	end
endtask

//---------------------------------------------------------------------------
// driver
//---------------------------------------------------------------------------
integer init_to;
integer err_mark;
integer lat_grant, lat_core, lat_req;
integer zlat_grant;

initial begin
	$display("tb_sdram32: sdram_ctrl vs sdram32_ctrl(DUAL=1) vs sdram32_ctrl(DUAL=0)");

	// after the models' own zeroing initial blocks
	#1;
	for (i = 0; i < 32768; i = i + 1) shadow[i] = 16'h0000;
	for (i = 0; i < 4096; i = i + 1) poke_word(i[23:0], pat(i[23:0]));

	reset = 0;
	repeat (400) @(posedge clk113);
	reset = 1;

	init_to = 0;
	while (!(ctl_ref.init_done && ctl_d.init_done && ctl_z.init_done) && init_to < 20000) begin
		@(posedge clk113);
		init_to = init_to + 1;
	end
	if (init_to >= 20000) begin
		$display("FAIL: controllers never finished SDRAM init");
		errors = errors + 1;
	end
	repeat (64) @(posedge clk113);
	mon_en = 1;
	$display("init complete at cycle %0d, equivalence monitor armed", cyc);

	//----------------------------------------------------------------
	// chipset reads: all four rotations inside an aligned block, so the
	// dual build's partner-unit read and the wrapped chip48 order are
	// both exercised
	//----------------------------------------------------------------
	err_mark = errors;
	chip_read_check(24'h000100);   // block word 0
	chip_read_check(24'h000101);   // block word 1
	chip_read_check(24'h000102);   // block word 2
	chip_read_check(24'h000103);   // block word 3
	chip_read_check(24'h000287);
	chip_read_check(24'h0003AA);
	if (errors == err_mark)
		$display("chipset reads: chipRD and chip48 match the reference in all rotations");

	//----------------------------------------------------------------
	// chipset writes: one lane only, byte enables, partner word intact
	//----------------------------------------------------------------
	err_mark = errors;
	chip_write(24'h000200, 1'b0, 1'b0, 16'h1234);   // even word -> secondary
	chip_write(24'h000201, 1'b0, 1'b0, 16'h5678);   // odd  word -> primary
	chip_write(24'h000202, 1'b0, 1'b1, 16'hAB00);   // upper byte only
	chip_write(24'h000203, 1'b1, 1'b0, 16'h00CD);   // lower byte only
	chip_read_check(24'h000200);
	chip_read_check(24'h000202);
	// the partner words of the block must be untouched
	chip_read_check(24'h000204);
	if (errors == err_mark)
		$display("chipset writes: byte-masked single-lane writes verified");

	//----------------------------------------------------------------
	// CPU port through cpu_cache_new (16-bit): fill order and write path
	//----------------------------------------------------------------
	err_mark = errors;
	cpu_read (24'h000400, shadow[15'h0400]);
	cpu_read (24'h000401, shadow[15'h0401]);
	cpu_read (24'h000403, shadow[15'h0403]);   // fill starting at block word 3
	cpu_read (24'h000502, shadow[15'h0502]);   // fill starting at block word 2
	cpu_write(24'h000600, 16'hCAFE);
	cpu_write(24'h000601, 16'hBABE);
	cpu_read (24'h000600, 16'hCAFE);
	cpu_read (24'h000601, 16'hBABE);
	if (errors == err_mark)
		$display("cpu port: cached fills and write buffer match the reference");

	//----------------------------------------------------------------
	// walker port: 32-bit read and 32-bit write
	//----------------------------------------------------------------
	err_mark = errors;
	walker_xfer(1'b1, 23'h000180, 32'h12345678);   // byte $600
	walker_xfer(1'b0, 23'h000180, 32'h0);
	if (r_wk_rdata !== 32'h12345678) begin
		$display("FAIL: reference walker read = %h", r_wk_rdata);
		errors = errors + 1;
	end
	if (d_wk_rdata !== 32'h12345678) begin
		$display("FAIL: DUAL walker read = %h", d_wk_rdata);
		errors = errors + 1;
	end
	if (z_wk_rdata !== 32'h12345678) begin
		$display("FAIL: DUAL=0 walker read = %h", z_wk_rdata);
		errors = errors + 1;
	end
	walker_xfer(1'b0, 23'h000100, 32'h0);          // byte $400 = words $200/$201
	if (d_wk_rdata !== {shadow[15'h0200], shadow[15'h0201]}) begin
		$display("FAIL: DUAL walker image read = %h, expected %h%h",
		         d_wk_rdata, shadow[15'h0200], shadow[15'h0201]);
		errors = errors + 1;
	end
	if (errors == err_mark)
		$display("walker port: 32-bit read/write identical to the reference");

	//----------------------------------------------------------------
	// 3. line fill latency, quiet bus
	//----------------------------------------------------------------
	fill_line(21'h00080);            // byte $800
	fill_check(21'h00080);
	if (d_grant_cyc < 0) begin
		$display("FAIL: DUAL fill was never granted a slot");
		errors = errors + 1;
	end
	else begin
		lat_grant = d_last_cyc - d_grant_cyc;
		lat_req   = d_last_cyc - d_req_cyc;
		lat_core  = (lat_grant + 3) / 4;     // core cycle = 4 clk_114 at ce=4
		zlat_grant = z_last_cyc - z_grant_cyc;
		$display("FILL LATENCY (DUAL=1): slot grant -> 4th beat = %0d clk_114 cycles = %0d core cycles at ce=4",
		         lat_grant, lat_core);
		$display("FILL LATENCY (DUAL=1): request -> 4th beat = %0d clk_114 cycles (includes the wait for the CCK slot)",
		         lat_req);
		$display("FILL LATENCY (DUAL=0): slot grant -> 4th beat = %0d clk_114 cycles (two slots, two beats per longword)",
		         zlat_grant);
		// gate: one ACTIVE + one burst, inside a single 16-cycle slot
		if (lat_grant > 16) begin
			$display("FAIL: DUAL fill needed more than one slot (%0d cycles)", lat_grant);
			errors = errors + 1;
		end
		// gate T2 of the plan: a cache line fill in <= 8 core cycles.
		// (8 clk_114 is not reachable by any command engine: tRCD=2 plus
		// CL2=4 plus 3 burst beats plus the capture register is 15.)
		if (lat_core > 8) begin
			$display("FAIL: DUAL fill took %0d core cycles, gate is 8", lat_core);
			errors = errors + 1;
		end
		if (zlat_grant <= lat_grant) begin
			$display("FAIL: the 16-bit fallback (%0d) is not slower than the 32-bit fill (%0d) -- the dual path is not doing what it claims",
			         zlat_grant, lat_grant);
			errors = errors + 1;
		end
	end

	//----------------------------------------------------------------
	// line fill under chipset traffic (the arbiter must still let the
	// chipset take its slot, and the fill must not lose beats)
	//----------------------------------------------------------------
	err_mark = errors;
	fork
		begin
			fill_line(21'h00090);
			fill_check(21'h00090);
		end
		begin
			chip_cycle(24'h000300, 1'b1, 1'b0, 1'b0, 16'h0000);
			chip_cycle(24'h000302, 1'b1, 1'b0, 1'b0, 16'h0000);
			chip_cycle(24'h000304, 1'b1, 1'b0, 1'b0, 16'h0000);
		end
	join
	if (errors == err_mark)
		$display("line fill under chipset traffic: 4 beats delivered, data correct");

	//----------------------------------------------------------------
	// 5. coherence: what Agnus writes, the 32-bit fill port must read.
	// This is the check that fails if chipset traffic is confined to one
	// chip of the pair.
	//----------------------------------------------------------------
	chip_write(24'h000A00, 1'b0, 1'b0, 16'hDEAD);   // even word (secondary)
	chip_write(24'h000A01, 1'b0, 1'b0, 16'hBEEF);   // odd word  (primary)
	chip_write(24'h000A02, 1'b0, 1'b0, 16'hFEED);
	chip_write(24'h000A03, 1'b0, 1'b0, 16'hFACE);
	fill_line(21'h00140);                            // byte $1400
	fill_check(21'h00140);
	if (d_beat[0] !== 32'hDEADBEEF || d_beat[1] !== 32'hFEEDFACE) begin
		$display("FAIL: chipset writes not coherent with the 32-bit fill port: beats %h %h",
		         d_beat[0], d_beat[1]);
		errors = errors + 1;
	end
	else
		$display("coherence: chipset writes are visible to the 32-bit fill port");

	//----------------------------------------------------------------
	verify_memory();

	repeat (64) @(posedge clk113);
	mon_en = 0;

	//----------------------------------------------------------------
	if (ram_ref.ap_viol || ram_d1.ap_viol || ram_d2.ap_viol || ram_z.ap_viol) begin
		$display("FAIL: %0d auto-precharge protocol violations (ref %0d, pri %0d, sec %0d, 16b %0d)",
		         ram_ref.ap_viol + ram_d1.ap_viol + ram_d2.ap_viol + ram_z.ap_viol,
		         ram_ref.ap_viol, ram_d1.ap_viol, ram_d2.ap_viol, ram_z.ap_viol);
		errors = errors + ram_ref.ap_viol + ram_d1.ap_viol + ram_d2.ap_viol + ram_z.ap_viol;
	end
	if (ram_ref.open_viol || ram_d1.open_viol || ram_d2.open_viol || ram_z.open_viol) begin
		$display("FAIL: %0d ACTIVE-into-open-bank violations (ref %0d, pri %0d, sec %0d, 16b %0d)",
		         ram_ref.open_viol + ram_d1.open_viol + ram_d2.open_viol + ram_z.open_viol,
		         ram_ref.open_viol, ram_d1.open_viol, ram_d2.open_viol, ram_z.open_viol);
		errors = errors + ram_ref.open_viol + ram_d1.open_viol + ram_d2.open_viol + ram_z.open_viol;
	end
	if (ram_ref.ref_viol || ram_d1.ref_viol || ram_d2.ref_viol || ram_z.ref_viol) begin
		$display("FAIL: %0d refresh-with-open-bank violations",
		         ram_ref.ref_viol + ram_d1.ref_viol + ram_d2.ref_viol + ram_z.ref_viol);
		errors = errors + ram_ref.ref_viol + ram_d1.ref_viol + ram_d2.ref_viol + ram_z.ref_viol;
	end

	if (lockerr == 0)
		$display("lockstep: chip 2 saw the same command as chip 1 on all %0d cycles", cyc);
	else
		$display("lockstep: %0d mismatching cycles", lockerr);

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	$finish;
end

// global timeout
initial begin
	#40000000;
	$display("FAIL: bench timeout");
	$display("TEST FAILED with %0d errors", errors + 1);
	$finish;
end

endmodule
