// Co-simulation of cpu_wrapper's 7MHz chip-bus stage machine with the
// AP68040 core behind ap68040_minimig and the bus16 adapter.  The core's
// own bench never exercises the ph1/ph2 chip handshake that real chip-RAM
// accesses use; the hardware cputest FADD.P ([]d0.w*8) failure of the
// previous core (stale first word of the memory-indirect pointer read at
// address 0) lived in exactly that gap.  Here the ENTIRE test program runs
// over the chip bus: turbo chipram off, no Zorro RAM, so every fetch and
// data access takes the cpu_wrapper chip path with its mixed
// posedge/negedge stage machine, one CCK per 16-bit transfer, dtack always
// granted.  The core runs on clk_cpu, clk_114/2, its edges aligned with
// clk's as the PLL's are on the board.
`timescale 1ns/1ns

module tb_cpu_wrapper_chip #(
	parameter CPU_PHASE = 0,
	parameter DTACK_MODE = 0,
	parameter RAM_LAT = 3,
	// Turbo chipram: cchip claims $000000-$1FFFFF, so fetches and data both
	// leave the chip bus for the accelerated RAM port.  That is how an
	// accelerated board actually runs, and it means EVERY fastchip access is
	// preceded by a RAM access rather than a chip-bus one.
	parameter TURBO_CHIP = 0,
	// fastramcfg: 0 no Zorro RAM; 4 offers a Zorro III board for a program
	// to configure (the coherence programs put VBR in Z3 fast RAM).  The RAM
	// port's model serves its addresses from the chip RAM array.
	parameter FASTRAM_CFG = 0
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
// the processor clock: half clk_114, rising with clk's rising edge
wire clk_cpu = (div[0] == CPU_PHASE[0]);
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
wire chip_wait = ((DTACK_MODE != 0) && !cck_count[0]) | wberr_hold;

reg  [2:0] ipl_lvl = 0;
reg [15:0] ipl_delay = 0;   // $F148: delayed level-2 IPL countdown
reg        wberr_arm = 0;   // $F146: one-shot bus error on a table-walk access

// $F146 (WBERRCTL) arms a bus error for the next table-search access.  The
// AP68040 walks its tables over the ordinary bus (TM = 3 data, 4 code), so
// the armed access is simply never acknowledged -- on whichever port it
// lands -- and cpu_wrapper's own watchdog turns it into the bus error, the
// path a dead descriptor address takes on the board.  The watchdog is
// shortened for the bench; chip-bus waits here are a few CCKs.
wire tblacc     = dut.cpu_req && (dut.adapter.fc == 3'd3 || dut.adapter.fc == 3'd4);
wire wberr_hold = wberr_arm && tblacc;

cpu_wrapper #(.BUS_TIMEOUT_BITS(12)) dut
(
	// the chipset DMA write's snoop, as the RAM controller signals it
	.snoop_tgl(dma_snoop),
	.snoop_adr(24'h001A80),     // $003500 (word address)
	.reset(reset),
	.reset_out(cpu_nrst_out),

	.clk(clk),
	.clk_cpu(clk_cpu),
	.ph1(ph1),
	.ph2(ph2),

	.cpucfg(2'b10),          // 68040 class, no fastchip acceleration
	.fastramcfg(FASTRAM_CFG[2:0]),
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
	.chip_ipl(cart_int7 ? 3'b000 : ~ipl_lvl),   // the cartridge's freeze is level 7

	.fastchip_dout(fc_dout),
	.fastchip_sel(fc_sel),
	.fastchip_lds(fc_lds),
	.fastchip_uds(fc_uds),
	.fastchip_rnw(fc_rnw),
	.fastchip_lw(fc_lw),
	.fastchip_selack(fc_selack),
	.fastchip_ready(fc_ready),

	.ramsel(ramsel),
	.ramaddr(ramaddr),
	.ramdin(ramdin),
	.ramdout(ramdout),
	.ramready(ramready),
	.ramconsumed(ramconsumed),
	.ramlds(ramlds),
	.ramuds(ramuds),
	.ramshared(),

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
	.longword(fc_lw),
	.rtg_ena(), .rtg_hsize(), .rtg_vsize(), .rtg_format(),
	.rtg_base(), .rtg_stride(),
	.rtg_pal_clk(pal_clk), .rtg_pal_dw(pal_dw), .rtg_pal_dr(pal_dr),
	.rtg_pal_a(pal_a), .rtg_pal_wr(pal_wr),
	.ide_ena(1'b0), .ide_irq(), .ide_req(),
	.ide_address(5'd0), .ide_write(1'b0), .ide_writedata(16'd0),
	.ide_read(1'b0), .ide_readdata(), .ide_led()
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
	else if (!ramready_r && !wberr_hold) begin
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

//---------------------------------------------------------------------------
// The cartridge (HRTMon) and a chipset DMA write, for the coherence
// programs (asm/coh_*.s).  Both are idle unless a program asks:
//   $F130 word  DMA: writes {value, $0000} to $3500 behind the CPU, on the
//               chip RAM side, and toggles the wrapper's snoop input once
//   $F170 word  asserts the cartridge's freeze (a level 7 interrupt whose
//               vector read the cartridge overlays with its monitor entry,
//               $00A1000C; $A1xxxx reads come from $6000 + offset - $C)
//   $F174 word  the program's observed value, printed
//---------------------------------------------------------------------------
reg dma_snoop = 0;
reg cart_freeze = 0;
wire cart_int7, cart_ovr;
wire [15:0] cart_data;
integer vector_reads = 0;
cart cart_board (
	.clk(clk_114), .clk7_en(div == 4'd0), .clk7n_en(1'b0),
	.cpu_rst(!reset), .cpu_address_in(chip_addr), ._cpu_as(chip_as),
	.cpu_rd(!chip_as && chip_rw), .cpu_hwr(1'b0), .cpu_lwr(1'b0),
	.nmi_addr(dut.nmi_addr), .nmi_ack_toggle(dut.nmi_ack_toggle),
	.reg_address_in(8'd0), .reg_data_in(16'd0), .dbr(1'b0), .ovl(1'b0),
	.freeze(cart_freeze), .cpuhlt(1'b0), .cart_data_out(cart_data),
	.int7(cart_int7), .sel_cart(), .ovr(cart_ovr)
);
assign chip_dout = cart_ovr ? cart_data :
                   chip_addr[23:16] == 8'hA1 ? mem[15'h3000 + chip_addr[15:1] - 15'h6] :
                   mem[chip_addr[15:1]];
always @(posedge clk_114)
	if (reset && ph2 && !chip_ph2_d && !chip_as && chip_rw && cart_ovr)
		vector_reads <= vector_reads + 1;
reg coh_seen = 0;   // one event per bus write (the chip bus write spans clocks)
always @(posedge clk_114) begin
	if (chip_as && !ram_wr_commit) coh_seen <= 0;
	if (cw_stb && !coh_seen) begin
		coh_seen <= 1;
		if (cw_addr == (16'hF130 >> 1)) begin
			mem[16'h3500 >> 1] <= cw_data;
			mem[16'h3502 >> 1] <= 16'd0;
			dma_snoop <= ~dma_snoop;
			$display("DMA write %h0000 to $3500, snoop toggled", cw_data);
		end
		if (cw_addr == (16'hF170 >> 1)) cart_freeze <= 1;
		if (cw_addr == (16'hF174 >> 1)) $display("observed %h", cw_data);
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
wire chip_wr_commit = reset && ph2 && !chip_ph2_d && !chip_as && !chip_rw;
wire        cw_stb  = chip_wr_commit | ram_wr_commit;
wire [15:1] cw_addr = ram_wr_commit ? ram_cidx : chip_addr[15:1];
wire [15:0] cw_data = ram_wr_commit ? ramdin   : chip_din;
wire        cw_uds  = ram_wr_commit ? ramuds   : chip_uds;
wire        cw_lds  = ram_wr_commit ? ramlds   : chip_lds;

always @(posedge clk_114) begin
	chip_ph2_d <= ph2;

	if (cw_stb) begin
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
			wberr_arm <= 1;   // the next table-walk access bus-errors
	end
	if (dut.bus_berr) wberr_arm <= 0;

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
	// capability word: bit 0 coarse IPL, bit 4 the real fastchip block.
	// Bit 3 (the previous core's chip-window I-fetch bypass) is off: the
	// AP68040 caches what the MMU and the TTRs allow, as a 68040 does.
	mem[16'hF160 >> 1] = 16'h0011;	// coarse IPL + fastchip

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
		$display("  pc=%08x halted=%b busstate=%0d", dut.cpu_inst_p.debug_pc,
		         dut.cpu_inst_p.debug_halted, cpustate);
	end
	else if (result == 2) begin
	begin
		$display("FAIL: program reports failure, test %0d", failcode);
		// the programs' fault record: which handler, the fault address and
		// the stacked PC (hid, hfa, hfpc of t_exceptions and t_mmu)
		$display("  hid=%04x hfa=%08x hfpc=%08x", mem[16'h3670 >> 1],
		         {mem[16'h3674 >> 1], mem[16'h3676 >> 1]},
		         {mem[16'h3678 >> 1], mem[16'h367A >> 1]});
	end
	end
	else
		$display("chip-bus run passed (%0d cycles)", timeout);

	if (cart_freeze)
		$display("cartridge: active=%b, level 7 acknowledged=%b, vector reads overlaid=%0d",
		         cart_board.active, dut.nmi_ack_toggle, vector_reads);
	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
