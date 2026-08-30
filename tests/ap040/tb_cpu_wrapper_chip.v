// Co-simulation of cpu_wrapper's 7MHz chip-bus stage machine with the
// AP040 core and bus16 adapter.  The program TB drives the compat wrapper
// directly and so never exercises the ph1/ph2 chip handshake that real
// chip-RAM accesses use; the hardware cputest FADD.P ([]d0.w*8) failure
// (stale first word of the memory-indirect pointer read at address 0)
// lives in exactly that gap.  Here the ENTIRE test program runs over the
// chip bus: turbo chipram off, no Zorro RAM, so every fetch and data
// access takes the cpu_wrapper chip path with its mixed posedge/negedge
// stage machine, one CCK per 16-bit transfer, dtack always granted.
`timescale 1ns/1ns

module tb_cpu_wrapper_chip #(
	parameter CPU_PHASE = 0,
	parameter DTACK_MODE = 0,
	parameter RAM_LAT = 3,
	// Turbo chipram: cchip claims $000000-$1FFFFF, so fetches and data both
	// leave the chip bus for the accelerated RAM port.  That is how an
	// accelerated board actually runs, and it means EVERY fastchip access is
	// preceded by a RAM access rather than a chip-bus one.
	parameter TURBO_CHIP = 0
);

reg reset = 0;

// Reproduce the actual two-clock topology in Minimig.sv. cpu_ph1/cpu_ph2
// are generated on clk_114, then sampled by cpu_wrapper on the phase-locked
// clk_sys output.  CPU_PHASE sweeps the four possible PLL edge alignments;
// the old bench generated both from clk_sys and therefore exercised only one
// artificially safe relationship.
reg clk_114 = 0;
always #5 clk_114 = ~clk_114;

reg [3:0] div = 0;
wire clk = (div[1:0] == CPU_PHASE[1:0]) |
	       (div[1:0] == ((CPU_PHASE[1:0] + 2'd1) & 2'd3));
reg ph1 = 0, ph2 = 0;
always @(posedge clk_114) begin
	div <= div + 1'd1;
	if (div[1] & ~div[0]) begin
		ph1 <= 0;
		ph2 <= 0;
		case (div[3:2])
			2'd0: ph2 <= 1;
			2'd2: ph1 <= 1;
			default: ;
		endcase
	end
end

wire [23:1] chip_addr;
wire        ramsel, ramlds, ramuds, ramready, ramconsumed;
wire        fill_req;
wire [24:4] fill_addr;
wire  [1:0] fill_bsel;
wire[127:0] fill_line;
wire        fill_done;
// m (clk_114) side of the bridge, served by the fill model below
wire        mf_req;
wire [24:4] mf_addr;
wire  [1:0] mf_bsel;
wire [31:0] fill_dat;
wire  [1:0] fill_beat;
wire        fill_strb;
wire        fill_ack;

// the REAL bridge, so the bench covers the CDC as well as the cache logic
ap040_fill_cdc fill_cdc
(
	.s_clk(clk), .s_reset_n(reset),
	.s_req(fill_req), .s_addr(fill_addr), .s_bsel(fill_bsel),
	.s_done(fill_done), .s_line(fill_line),
	.m_clk(clk_114), .m_reset_n(reset),
	.m_req(mf_req), .m_addr(mf_addr), .m_bsel(mf_bsel),
	.m_dat(fill_dat), .m_beat(fill_beat), .m_strb(fill_strb), .m_ack(fill_ack)
);
wire [28:1] ramaddr;
wire [15:0] ramdin, ramdout;
wire  [1:0] cpustate;
wire        pal_clk;
wire [23:0] pal_dr;
wire [23:0] pal_dw;
wire  [7:0] pal_a;
wire        pal_wr;
wire        fc_sel, fc_lds, fc_uds, fc_rnw, fc_lw;
wire        fc_selack, fc_ready;
wire [15:0] fc_dout;


wire [15:0] chip_din;
wire        chip_as, chip_uds, chip_lds, chip_rw;
wire        cpu_nrst_out;
wire [15:0] chip_dout;

// chip_dtack is active high for wait.  Mode 0 is an uncontended bus; mode 1
// holds alternate CCK slots to cover the normal DMA/arbitration completion
// path without changing any CPU-side timing.
reg [7:0] cck_count = 0;
always @(posedge clk_114) if (div == 4'hf) cck_count <= cck_count + 1'd1;
wire chip_wait = (DTACK_MODE != 0) && !cck_count[0];

reg  [2:0] ipl_lvl = 0;
reg [15:0] ipl_delay = 0;   // $F148: delayed level-2 IPL countdown
reg        wberr_arm = 0;   // $F146: one-shot walker bus error

wire        walker_req, walker_we, walker_ddr, walker_bad;
wire [28:2] walker_addr;
wire [31:0] walker_wdat;
reg         walker_ack   = 0;
reg         walker_berr  = 0;
reg  [31:0] walker_rdata = 0;

cpu_wrapper dut
(
	.snoop_tgl(1'b0),
	.snoop_adr(24'd0),
	.reset(reset),
	.reset_out(cpu_nrst_out),

	.clk(clk),
	.ph1(ph1),
	.ph2(ph2),

	.cpucfg(2'b10),          // 68040 class, no fastchip acceleration
	.fastramcfg(3'd0),       // no Zorro RAM: nothing selects the RAM port
	.cachecfg(TURBO_CHIP ? 3'b101 : 3'd0),  // turbochip + dcache, or all off
	.bootrom(1'b0),

	.chip_addr(chip_addr),
	.chip_dout(chip_dout),
	.chip_din(chip_din),
	.chip_as(chip_as),
	.chip_uds(chip_uds),
	.chip_lds(chip_lds),
	.chip_rw(chip_rw),
	.chip_dtack(chip_wait),
	.chip_ipl(~ipl_lvl),

	.fastchip_dout(fc_dout),
	.fastchip_sel(fc_sel),
	.fastchip_lds(fc_lds),
	.fastchip_uds(fc_uds),
	.fastchip_rnw(fc_rnw),
	.fastchip_lw(fc_lw),
	.fastchip_selack(fc_selack),
	.fastchip_ready(fc_ready),

	.fill_req(fill_req),
	.fill_addr(fill_addr),
	.fill_bsel(fill_bsel),
	.fill_avail(1'b1),
	.fill_line(fill_line),
	.fill_done(fill_done),

	.ramsel(ramsel),
	.ramaddr(ramaddr),
	.ramdin(ramdin),
	.ramdout(ramdout),
	.ramready(ramready),
	.ramconsumed(ramconsumed),
	.ramlds(ramlds),
	.ramuds(ramuds),
	.ramshared(),

	.walker_mem_req(walker_req),
	.walker_mem_we(walker_we),
	.walker_mem_addr(walker_addr),
	.walker_mem_wdat(walker_wdat),
	.walker_mem_ddr(walker_ddr),
	.walker_mem_bad(walker_bad),
	.walker_mem_ack(walker_ack),
	.walker_mem_rdata(walker_rdata),
	.walker_mem_berr(walker_berr),

	.toccata_ena(),
	.toccata_base(),
	.a2065_ena(),
	.a2065_base(),

	.cpustate(cpustate),
	.cacr(),
	.cache_inhibit(),
	.nmi_ack_toggle(),
	.nmi_addr()
);

// The fastchip block (RTG registers, IDE, Akiko) was stubbed off in this
// bench -- selack/ready tied 0, dout tied 0 -- so the whole RTG register
// interface had never been simulated on this CPU.  Hardware reads the RTG
// ID at $B8010E as $5001 on TG68K-020 and $0000 here, which is precisely
// what an unsimulated handshake looks like.  Wire the real modules in.

fastchip fastchip
(
	.clk(clk_114),
	.cyc(1'b1),                 // fastchip declares cyc but never uses it
	.clk_sys(clk),
	// Minimig.sv drives ~cpu_rst | ~cpu_nrst_out: active HIGH, while the
	// bench's own reset is active low
	.reset(~reset | ~cpu_nrst_out),
	.sel(fc_sel),
	.sel_ack(fc_selack),
	.ready(fc_ready),
	.addr({chip_addr, 1'b0}),
	.din(chip_din),
	.dout(fc_dout),
	.lds(~fc_lds),
	.uds(~fc_uds),
	.rnw(fc_rnw),
	.rtg_ena(), .rtg_hsize(), .rtg_vsize(), .rtg_format(),
	.rtg_base(), .rtg_stride(),
	.rtg_pal_clk(pal_clk), .rtg_pal_dw(pal_dw), .rtg_pal_dr(pal_dr),
	.rtg_pal_a(pal_a), .rtg_pal_wr(pal_wr),
	// the gayle block moved up to Minimig.sv and is shared with minimig;
	// this bench never enabled IDE, so leave the frontend unclaimed
	.ide_ena(1'b0),
	.gayle_sel_ide(), .gayle_sel_gayle(), .gayle_rd(), .gayle_wr(),
	.gayle_dout(16'd0), .gayle_nrdy(1'b0)
);

//---------------------------------------------------------------------------
// Accelerated RAM port model.
//
// This port used to be tied off (ramready 1'b0), which made the bench blind
// to how the real controllers acknowledge: sdram_ctrl/ddram_ctrl hold their
// level ack -- and the captured data -- until cpuCS falls, and cpuCS is
// ram_cs_guard's REGISTERED copy of ramsel, so it lags the request by a
// clk_114 cycle.  A ready that outlives its own access is exactly what
// cpu_wrapper's unqualified bus_complete (chipready | ramready |
// fastchip_ready) can mistake for the NEXT access completing.
//
// With fastramcfg/cachecfg both zero the only thing that selects this port
// is the RTG framebuffer aperture, cpu_addr $02xxxxxx, which cpu_wrapper
// remaps to ramaddr[26:23] = 4'b1110 -- DDR3 byte $27000000 once ddram_ctrl
// adds its {3'b001} prefix, the FB_BASE MiSTer.card.asm hardcodes.  Model a
// window of it so a framebuffer write can be read back, and so an RTG
// register access can follow a RAM access the way it does on the board.
//
// ramuds/ramlds are active low (sdram_ctrl takes them as {!cpuU, !cpuL}),
// and cpu_wrapper swaps the two halves plus the data bytes for the RTG
// aperture, so the model stores what the scaler would actually fetch.
//---------------------------------------------------------------------------
// swept by run_tests.sh: the window where a stale ready can be mistaken for
// the next access's is latency dependent, so one value proves nothing

wire ram_cs;
ram_cs_guard ram_guard
(
	.clk(clk_114),
	.nreset(reset),
	.cpu_type(1'b1),
	.ram_consumed(ramconsumed),
	.ram_sel(ramsel),
	.ram_ready(ramready),
	.ram_cs(ram_cs)
);

reg [15:0] mem [0:32767];
reg [15:0] fbmem [0:2047];
reg [15:0] ramdout_r;
reg        ramready_r;
reg  [2:0] ram_lat;
wire [10:0] fbidx = ramaddr[11:1];
// ramaddr[26] is set only by the RTG aperture remap (ramaddr[26:23]=1110);
// everything else reaching this port under TURBO_CHIP is chip RAM, which
// must come from the SAME array the chip bus serves or the program cannot run
wire        ram_is_fb = ramaddr[26];
wire [14:0] ram_cidx  = ramaddr[15:1];
integer fi;
initial begin
	for (fi = 0; fi < 2048; fi = fi + 1) fbmem[fi] = 16'h0000;
	ramdout_r  = 16'h0000;
	ramready_r = 1'b0;
	ram_lat    = 3'd0;
end

always @(posedge clk_114) begin
	if (!reset || !ram_cs) begin
		// the ack is dropped only when the select falls, never earlier
		ramready_r <= 1'b0;
		ram_lat    <= 3'd0;
	end
	else if (!ramready_r) begin
		if (ram_lat == RAM_LAT[2:0]) begin
			if (cpustate == 2'd3) begin
				if (ram_is_fb) begin
					if (!ramuds) fbmem[fbidx][15:8] <= ramdin[15:8];
					if (!ramlds) fbmem[fbidx][7:0]  <= ramdin[7:0];
				end
				else begin
					if (!ramuds) mem[ram_cidx][15:8] <= ramdin[15:8];
					if (!ramlds) mem[ram_cidx][7:0]  <= ramdin[7:0];
				end
			end
			ramdout_r  <= ram_is_fb ? fbmem[fbidx] : mem[ram_cidx];
			ramready_r <= 1'b1;
		end
		else ram_lat <= ram_lat + 3'd1;
	end
end

assign ramready = ramready_r;
assign ramdout  = ramdout_r;

//---------------------------------------------------------------------------
// 32-bit line fill port model (sdram32_ctrl's contract)
//---------------------------------------------------------------------------
// fill_req is level held until fill_ack.  Delivery starts at fill_bsel and
// wraps; each strobe names its beat on fill_beat.  RAM_LAT models the
// first-word latency and the remaining beats follow back to back, which is
// what a burst of 4 does -- that back-to-back part is the whole point of the
// port, so modelling it any other way would measure the wrong thing.
//
// Reads the SAME mem[] array the chip bus and the 16-bit RAM port serve, so
// a line filled through this port is indistinguishable from one filled the
// slow way except in timing.
reg  [2:0] fl_lat;
reg  [2:0] fl_cnt;
reg        fl_busy;
reg [31:0] fill_dat_r;
reg  [1:0] fill_beat_r;
reg        fill_strb_r;
reg        fill_ack_r;

wire  [1:0] fl_beat = mf_bsel + fl_cnt[1:0];
wire [14:0] fl_widx = {mf_addr[15:4], fl_beat, 1'b0};

initial begin
	fl_lat = 0; fl_cnt = 0; fl_busy = 0;
	fill_dat_r = 0; fill_beat_r = 0; fill_strb_r = 0; fill_ack_r = 0;
end

always @(posedge clk_114) begin
	fill_strb_r <= 1'b0;
	fill_ack_r  <= 1'b0;

	if (!reset || !mf_req) begin
		fl_lat  <= 3'd0;
		fl_cnt  <= 3'd0;
		fl_busy <= 1'b0;
	end
	else if (!fl_busy) begin
		if (fl_lat == RAM_LAT[2:0]) begin
			fl_busy <= 1'b1;
			fill_dat_r  <= {mem[fl_widx], mem[fl_widx + 15'd1]};
			fill_beat_r <= fl_beat;
			fill_strb_r <= 1'b1;
			fl_cnt      <= 3'd1;
		end
		else fl_lat <= fl_lat + 3'd1;
	end
	else if (fl_cnt < 3'd4) begin
		fill_dat_r  <= {mem[fl_widx], mem[fl_widx + 15'd1]};
		fill_beat_r <= fl_beat;
		fill_strb_r <= 1'b1;
		if (fl_cnt == 3'd3) fill_ack_r <= 1'b1;
		fl_cnt <= fl_cnt + 3'd1;
	end
end

assign fill_dat  = fill_dat_r;
assign fill_beat = fill_beat_r;
assign fill_strb = fill_strb_r;
assign fill_ack  = fill_ack_r;

// Under TURBO_CHIP, sel_chipram claims $000000-$1FFFFF, which contains every
// testbench control port -- result, failcode and the interrupt injectors --
// so those writes leave the chip bus entirely.  Decoding them on the chip
// bus alone made the program hang waiting for an interrupt that was never
// injected.  Expose the RAM-path write as a single-cycle event instead, and
// let one decode below serve both paths.
wire ram_wr_commit = reset && ram_cs && !ramready_r &&
                     (ram_lat == RAM_LAT[2:0]) && (cpustate == 2'd3) &&
                     !ram_is_fb;

//---------------------------------------------------------------------------
// Cross-target completion checker.
//
// cpu_wrapper advances the CPU on
//     clkena_in = ~cpu_req | bus_complete | bus_berr
// with
//     bus_complete = chipready | ramready | fastchip_ready
// which never asks WHICH target the access in flight belongs to.  Each of
// the three is a level that outlives its own access by some amount -- the
// RAM controllers hold theirs until cpuCS falls, and cpuCS is ram_cs_guard's
// registered copy of ramsel -- so a ready left over from the previous access
// can complete the current one.  A fastchip read finished that way returns
// rtg's registered dout before its read pipeline has driven it, which is
// 16'h0000: exactly the $0000 seen reading the RTG ID on hardware where
// $5001 is expected.
//
// Watch for it continuously rather than hoping a test lands in the window.
//---------------------------------------------------------------------------
integer xtarget_hits = 0;
always @(posedge clk) begin
	if (reset && dut.cpu_req) begin
		if (fc_selack && !fc_ready && (ramready || dut.chipready)) begin
			if (xtarget_hits < 20)
				$display("XTARGET: fastchip access completed by %s at t=%0t addr=%h",
				         ramready ? "ramready" : "chipready", $time,
				         {chip_addr, 1'b0});
			xtarget_hits = xtarget_hits + 1;
		end
		if (ramsel && !ramready && (fc_ready || dut.chipready)) begin
			if (xtarget_hits < 20)
				$display("XTARGET: RAM access completed by %s at t=%0t addr=%h",
				         fc_ready ? "fastchip_ready" : "chipready", $time,
				         {ramaddr, 1'b0});
			xtarget_hits = xtarget_hits + 1;
		end
	end
end

//---------------------------------------------------------------------------
// RTG CLUT model.  On the board these four signals leave the core for the
// HPS framebuffer, which holds the 256-entry palette; a black RTG screen is
// exactly what an all-zero CLUT looks like, and the palette is the one RTG
// window whose read handshake differs -- rtg.v holds it for three clk_sys
// edges (rd_r[2]) against one (rd_r[0]) for the control registers.  Model it
// the way ascal does: written on pal_wr at pal_a, read combinationally.
//---------------------------------------------------------------------------
reg  [23:0] clut [0:255];
always @(posedge pal_clk) if (pal_wr) clut[pal_a] <= pal_dw;
assign pal_dr = clut[pal_a];

//---------------------------------------------------------------------------
// 64 KB chip RAM model (word addressed), data valid combinationally like
// real chip RAM by the dtack phase; writes latch during the data phase.
//---------------------------------------------------------------------------

assign chip_dout = mem[chip_addr[15:1]];

//---------------------------------------------------------------------------
// MMU walker physical port.  On hardware the table walker bypasses the
// chip bus and reads descriptors over the SDRAM/DDR3 port; here the
// tables live in the same 64 KB model.  Handshake mirrors the flat TB:
// a held request is accepted once, re-armed when it drops, acked for one
// cycle after a short latency.  walker_mem_bad (corrupt table address)
// answers with a bus error, as Minimig does.
//---------------------------------------------------------------------------

reg       walker_armed   = 1;
reg       walker_pending = 0;
reg [1:0] walker_lat     = 0;
reg       walker_we_l    = 0;
reg [13:0] walker_word_l = 0;
reg       walker_bad_l   = 0;
reg [31:0] walker_wdat_l = 0;

always @(posedge clk) begin
	walker_ack  <= 0;
	walker_berr <= 0;
	if (!reset) begin
		walker_armed   <= 1;
		walker_pending <= 0;
	end
	else begin
		if (!walker_req) walker_armed <= 1;
		if (walker_req && walker_armed && !walker_pending) begin
			walker_pending <= 1;
			walker_armed   <= 0;
			walker_we_l    <= walker_we;
			walker_word_l  <= walker_addr[15:2];
			walker_bad_l   <= walker_bad | walker_ddr | (|walker_addr[28:16]);
			walker_wdat_l  <= walker_wdat;
			walker_lat     <= 2'd2;
		end
		else if (walker_pending) begin
			if (walker_lat != 0)
				walker_lat <= walker_lat - 1'd1;
			else begin
				walker_pending <= 0;
				if (walker_bad_l || wberr_arm) begin
					wberr_arm   <= 0;
					walker_berr <= 1;
				end
				else if (walker_we_l) begin
					mem[{walker_word_l, 1'b0}] <= walker_wdat_l[31:16];
					mem[{walker_word_l, 1'b1}] <= walker_wdat_l[15:0];
					walker_ack <= 1;
				end
				else begin
					walker_rdata <= {mem[{walker_word_l, 1'b0}],
					                 mem[{walker_word_l, 1'b1}]};
					walker_ack <= 1;
				end
			end
		end
	end
end

integer errors = 0;
integer result = 0;      // 0 running, 1 pass, 2 fail
reg [15:0] failcode = 0;

// chip RAM writes still land here, on the chip bus, as before
always @(posedge clk) begin
	if (ph2 && !chip_as && !chip_rw && reset) begin
		if (!chip_uds) mem[chip_addr[15:1]][15:8] <= chip_din[15:8];
		if (!chip_lds) mem[chip_addr[15:1]][7:0]  <= chip_din[7:0];
	end
end

// One control-port decode for both paths.  ph2 is four clk_114 cycles wide,
// so take its rising edge to keep the chip-bus source single-cycle, matching
// what one posedge clk used to see.
reg  chip_ph2_d;
integer c114_free = 0;
integer stamp_prev = 0;
always @(posedge clk_114) c114_free = c114_free + 1;
wire chip_wr_commit = reset && ph2 && !chip_ph2_d && !chip_as && !chip_rw;
wire        cw_stb  = chip_wr_commit | ram_wr_commit;
wire [15:1] cw_addr = ram_wr_commit ? ram_cidx : chip_addr[15:1];
wire [15:0] cw_data = ram_wr_commit ? ramdin   : chip_din;
wire        cw_uds  = ram_wr_commit ? ramuds   : chip_uds;
wire        cw_lds  = ram_wr_commit ? ramlds   : chip_lds;

always @(posedge clk_114) begin
	chip_ph2_d <= ph2;

	if (cw_stb) begin
		// $F108: cycle-stamp marker, as in tb_ap040_program -- a write
		// prints the clk_114-cycle count since the previous stamp so a
		// program can bracket a block and read its cost from the log.
		// clk_114 counts are 4x the clk_sys costs the plan quotes.
		if (cw_addr == (16'hF108 >> 1)) begin
			$display("STAMP tag=%04x cycles114=%0d", cw_data,
			         c114_free - stamp_prev);
			stamp_prev = c114_free;
		end
		if (cw_addr == (16'hF100 >> 1))
			failcode <= cw_data;
		if (cw_addr == (16'hF102 >> 1) && !cw_uds && !cw_lds) begin
			if (cw_data == 16'h600D) result <= 1;
			else begin
				errors <= errors + 1;
				result <= 2;
			end
		end
		// interrupt injection, mirroring tb_ap040_program: $F110 sets the
		// level directly (0 releases), $F148 arms a delayed level-2 rise
		if (cw_addr == (16'hF110 >> 1))
			ipl_lvl <= cw_data[2:0];
		if (cw_addr == (16'hF146 >> 1))
			wberr_arm <= 1;   // next walker transaction bus-errors
	end

	// the 7 MHz bus stretches every instruction ~16x, so scale the armed
	// delay to sweep the same fraction of the FPU op's window as the
	// fast-bus testbench does with raw clk counts
	if (cw_stb && cw_addr == (16'hF148 >> 1))
		ipl_delay <= cw_data << 8;
	else if (ipl_delay != 0) begin
		ipl_delay <= ipl_delay - 1'd1;
		if (ipl_delay == 16'd1) ipl_lvl <= 3'd2;
	end
end

//---------------------------------------------------------------------------
// driver
//---------------------------------------------------------------------------

reg [1023:0] prog_file;
reg [1023:0] vcd_file;
integer i;
integer timeout;

initial begin
	if (!$value$plusargs("prog=%s", prog_file)) begin
		$display("FAIL: missing +prog=<hexfile>");
		$finish;
	end
	$display("tb_cpu_wrapper_chip: running %0s over the 7MHz chip bus", prog_file);
	if ($value$plusargs("vcd=%s", vcd_file)) begin
		$dumpfile(vcd_file);
		$dumpvars(1, tb_cpu_wrapper_chip);
		$dumpvars(1, fastchip);
		$dumpvars(1, fastchip.rtg);
	end

	for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
	$readmemh(prog_file, mem);
	// capability word: bit 0 coarse IPL; bit 3 = the cache_allow window
	// models production (cache_allow_all=0), so the chip-window I-fetch
	// bypass is active and t_exceptions 157/158 can assert it
	mem[16'hF160 >> 1] = 16'h0019;	// coarse IPL + production cache window + fastchip

	reset = 0;
	repeat (50) @(posedge clk);
	reset = 1;

	timeout = 0;
	while (result == 0 && timeout < 60000000) begin
		@(posedge clk);
		timeout = timeout + 1;
	end

	if (xtarget_hits != 0) begin
		errors = errors + 1;
		$display("FAIL: %0d cross-target bus completions", xtarget_hits);
	end

	if (result == 0) begin
		errors = errors + 1;
		$display("FAIL: timeout after %0d cycles", timeout);
		$display("  pc=%08x ir=%04x sr=%04x state=%02x",
		         dut.cpu_inst_p.core.pc, dut.cpu_inst_p.core.ir,
		         dut.cpu_inst_p.core.sr, dut.cpu_inst_p.core.state);
	end
	else if (result == 2) begin
		$display("FAIL: program reports failure, test %0d", failcode);
	end
	else
		$display("chip-bus run passed (%0d cycles)", timeout);

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	$finish;
end


endmodule
