// AP030 variant of tests/ap040/tb_cpu_wrapper_chip.v: the same bench with the
// AP030 core (ap030_tg68k_compat) behind cpu_wrapper.
//
// Co-simulation of cpu_wrapper's 7MHz chip-bus stage machine with the
// AP040 core and bus16 adapter.  The program TB drives the compat wrapper
// directly and so never exercises the ph1/ph2 chip handshake that real
// chip-RAM accesses use; the hardware cputest FADD.P ([]d0.w*8) failure
// (stale first word of the memory-indirect pointer read at address 0)
// lives in exactly that gap.  Here the ENTIRE test program runs over the
// chip bus: turbo chipram off, no Zorro RAM, so every fetch and data
// access takes the cpu_wrapper chip path with its mixed posedge/negedge
// stage machine, one CCK per 16-bit transfer, dtack always granted.
`timescale 1ns/100ps

module tb_ap030_wrapchip #(
	parameter CPU_PHASE = 0,
	parameter DTACK_MODE = 0,
	parameter RAM_LAT = 3,
	// Turbo chipram: cchip claims $000000-$1FFFFF, so fetches and data both
	// leave the chip bus for the accelerated RAM port.  That is how an
	// accelerated board actually runs, and it means EVERY fastchip access is
	// preceded by a RAM access rather than a chip-bus one.
	parameter TURBO_CHIP = 0,
	// AP030: Zorro II Fast RAM offered to autoconfig (fastramcfg), served by
	// the 32-bit synchronous port through the DDR3 model below
	parameter FASTRAM = 0,
	parameter DDR_LAT = 12,        // clk_114 cycles from an accepted read to its first beat
	parameter DDR_WAIT = 0         // 1: pseudo-random waitrequest on the DDR3 model
);

// AP030 processor clock: 50 MHz, asynchronous to the 114/28 MHz pair
reg clk_cpu = 0;
always #10.3 clk_cpu = ~clk_cpu;

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

//---------------------------------------------------------------------------
// DDR3 model for the AP030 Fast RAM port: Avalon-MM slave on clk_114, 64-bit,
// bursts, readdata DDR_LAT cycles after a read is accepted, optional random
// waitrequest.  1 MB, addressed by the low bits of the 64-bit word address.
//---------------------------------------------------------------------------
wire [28:0] fr_address;
wire  [7:0] fr_burstcount, fr_byteenable;
wire        fr_read, fr_write;
wire [63:0] fr_writedata;
wire        fr_waitrequest;
wire [63:0] fr_readdata;
wire        fr_readdatavalid;
// the DDR3 slave behind Minimig.sv's fastram_arbiter (m0 = the processor,
// m1 = a second master standing in for ddram_ctrl's traffic)
wire [28:0] s_address;
wire  [7:0] s_burstcount, s_byteenable;
wire        s_read, s_write;
wire [63:0] s_writedata;
reg         s_waitrequest = 1;
reg  [63:0] s_readdata = 0;
reg         s_readdatavalid = 0;
reg  [28:0] m1_address = 0;
reg         m1_read = 0, m1_write = 0;
reg  [63:0] m1_writedata = 0;
wire        m1_waitrequest, m1_readdatavalid;
wire [63:0] m1_readdata;
a2065_ddram_arbiter fastram_arbiter (
	.clk(clk_114), .rst(1'b0),
	.m0_address(fr_address), .m0_burstcount(fr_burstcount), .m0_read(fr_read), .m0_readdata(fr_readdata),
	.m0_readdatavalid(fr_readdatavalid), .m0_writedata(fr_writedata), .m0_byteenable(fr_byteenable),
	.m0_write(fr_write), .m0_waitrequest(fr_waitrequest),
	.m1_address(m1_address), .m1_burstcount(8'd1), .m1_read(m1_read), .m1_readdata(m1_readdata),
	.m1_readdatavalid(m1_readdatavalid), .m1_writedata(m1_writedata), .m1_byteenable(8'hFF),
	.m1_write(m1_write), .m1_waitrequest(m1_waitrequest),
	.s_address(s_address), .s_burstcount(s_burstcount), .s_read(s_read), .s_readdata(s_readdata),
	.s_readdatavalid(s_readdatavalid), .s_writedata(s_writedata), .s_byteenable(s_byteenable),
	.s_write(s_write), .s_waitrequest(s_waitrequest)
);
reg  [63:0] ddr [0:524287];            // 4 MB: the 2 MB card (word bit 18 set) and the second master
reg  [15:0] lfsr = 16'hACE1;
reg  [18:0] rd_addr_q [0:15];
reg   [7:0] rd_left_q [0:15];
reg  [31:0] rd_due_q  [0:15];
reg   [3:0] rq_head = 0, rq_tail = 0;
reg  [31:0] mclk = 0;
integer     di, ddr_reads = 0, ddr_writes = 0;
// chipset write snoop to cpu_wrapper (as Minimig's chip RAM controller
// reports DMA writes: a toggle and the word address, at most once per CCK)
reg        snp_tgl = 0;
reg [24:1] snp_adr = 0;

cpu_wrapper dut
(
	.snoop_tgl(snp_tgl),
	.snoop_adr(snp_adr),
	.reset(reset),
	.reset_out(cpu_nrst_out),

	.clk(clk),
	.clk_cpu(clk_cpu),
	.clk_mem(clk_114),
	.fr_address(fr_address),
	.fr_burstcount(fr_burstcount),
	.fr_read(fr_read),
	.fr_write(fr_write),
	.fr_writedata(fr_writedata),
	.fr_byteenable(fr_byteenable),
	.fr_waitrequest(fr_waitrequest),
	.fr_readdata(fr_readdata),
	.fr_readdatavalid(fr_readdatavalid),
	.ph1(ph1),
	.ph2(ph2),

	.cpucfg(2'b10),          // 68040 class, no fastchip acceleration
	.fastramcfg(FASTRAM ? 3'd1 : 3'd0),   // 2 MB Zorro II RAM when FASTRAM, else none
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
	.longword(fc_lw),
	.rtg_ena(), .rtg_hsize(), .rtg_vsize(), .rtg_format(),
	.rtg_base(), .rtg_stride(),
	.rtg_pal_clk(pal_clk), .rtg_pal_dw(pal_dw), .rtg_pal_dr(pal_dr),
	.rtg_pal_a(pal_a), .rtg_pal_wr(pal_wr),
	.ide_ena(1'b1), .ide_irq(), .ide_req(),
	.ide_address(ide_a), .ide_write(ide_w), .ide_writedata(ide_wd),
	.ide_read(1'b0), .ide_readdata(), .ide_led()
);

//---------------------------------------------------------------------------
// IDE management side (MiSTer's ARM): a write to $F1D0 marks drive 0
// present, loads one 256-word sector (word i = {i ^ $5A, i}) into its
// buffer and raises DRQ with the last-read flag; $F1D2 becomes nonzero
//---------------------------------------------------------------------------
reg  [4:0] ide_a = 0;
reg        ide_w = 0;
reg [15:0] ide_wd = 0;
reg  [9:0] ide_step = 0;       // 0 idle, 1..258 writes, 259 status
reg        ide_tgl = 0, ide_tgl_seen = 0;
reg        ide_done = 0;
wire [7:0] ide_i = ide_step[7:0] - 8'd3;
reg  [3:0] ide_ph = 0;          // each management write: 8 clk_114 high, 8 low (clk_sys domain)
always @(posedge clk_114) begin
	ide_done <= 1'b0;
	ide_ph <= ide_ph + 1'd1;
	if (ide_ph == 4'd7) ide_w <= 1'b0;
	if (ide_step == 0) begin
		ide_ph <= 0;
		if (ide_ph == 4'd7) ide_w <= 1'b0; else if (ide_ph < 4'd7) ide_ph <= ide_ph + 1'd1;   // finish the last strobe
		if (ide_tgl != ide_tgl_seen) begin ide_tgl_seen <= ide_tgl; ide_step <= 1; end
	end else if (ide_ph == 4'd15) begin
		if (ide_step == 1) begin ide_a <= 5'd6; ide_wd <= 16'h000B; end          // drive 0 present
		else if (ide_step == 2) begin ide_a <= 5'd0; ide_wd <= 16'h0001; end     // 256 words, no error
		else if (ide_step <= 258) begin ide_a <= 5'h0F; ide_wd <= {ide_i ^ 8'h5A, ide_i}; end
		else begin ide_a <= 5'd5; ide_wd <= 16'h5A00; end                        // DRDY DSC DRQ, last read
		ide_w <= 1'b1;
		if (ide_step == 259) begin ide_step <= 0; ide_done <= 1'b1; ide_tgl_seen <= ide_tgl; end   // requests during the load are dropped
		else ide_step <= ide_step + 1'd1;
	end
end
always @(posedge clk_114) if (ide_done) mem[16'hF1D2 >> 1] <= 16'h0001;
reg [13:0] idet_io = 0, idet_mg = 0;
reg        idet_rd = 0;
always @(posedge clk_114) if ($test$plusargs("idetrace")) begin
	idet_io <= fastchip.gayle.ide0.io_cnt; idet_mg <= fastchip.gayle.ide0.mgmt_cnt;
	idet_rd <= fastchip.gayle.ide0.io_read;
	if (fastchip.gayle.ide0.io_cnt != idet_io || fastchip.gayle.ide0.io_read != idet_rd)
		$display("%0t IDE io_cnt=%0d io_read=%b io_32=%b drq=%b status=%h addr=%h lw=%b", $time,
		         fastchip.gayle.ide0.io_cnt, fastchip.gayle.ide0.io_read, fastchip.gayle.ide0.io_32,
		         fastchip.gayle.ide0.drq, fastchip.gayle.ide0.status, {chip_addr,1'b0}, fc_lw);
	if (fastchip.gayle.ide0.io_stb || fastchip.gayle.ide0.reset)
		$display("%0t IDE stb=%b reset=%b mgw=%b mga=%h rd=%b sel_tfr=%b", $time, fastchip.gayle.ide0.io_stb,
		         fastchip.gayle.ide0.reset, fastchip.gayle.ide0.mgmt_write, fastchip.gayle.ide0.mgmt_address,
		         fastchip.gayle.rd, fastchip.gayle.sel_tfr);
	if (fastchip.gayle.ide0.mgmt_cnt != idet_mg && fastchip.gayle.ide0.mgmt_cnt < 6)
		$display("%0t IDE mgmt_cnt=%0d", $time, fastchip.gayle.ide0.mgmt_cnt);
end

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
reg [1:0] dma_val = 0;
reg [31:0] dma_data = 32'h55667788;   // $F184: the value the DMA model writes
reg       dma_tgl = 0;
reg [31:0] bench_runs = 0, bench_clks = 0;
reg        bench_report = 0;
always @(posedge clk_114) if (bench_report) begin
	bench_report <= 0;
	if (bench_runs != 0 && bench_clks != 0)
		$display("BENCH runs=%0d cpu clocks=%0d clocks/run=%0.1f: at 50 MHz %0.0f Dhrystones/s = %0.2f DMIPS",
		         bench_runs, bench_clks, $itor(bench_clks) / $itor(bench_runs),
		         $itor(bench_runs) * 50.0e6 / $itor(bench_clks), $itor(bench_runs) * 50.0e6 / $itor(bench_clks) / 1757.0);
end

// +xtrace: the processor/Minimig handshake, every processor clock
always @(posedge clk_cpu) if ($test$plusargs("xtrace") && cpu_clocks < 400)
	$display("%0t as=%b ds=%b a=%h siz=%0d fc=%0d | p: tgl=%b own=%b term=%b berr=%b | k: tgl=%b st=%0d clkena=%b uds=%b lds=%b addr=%h | cpust=%0d",
	         $time, dut.cpu_inst_p.as_n, dut.cpu_inst_p.ds_n, dut.cpu_inst_p.a, dut.cpu_inst_p.siz, dut.cpu_inst_p.cfc,
	         dut.cpu_inst_p.p_tgl, dut.cpu_inst_p.p_own, dut.cpu_inst_p.p_term, dut.cpu_inst_p.p_berr,
	         dut.cpu_inst_p.k_tgl_r, dut.cpu_inst_p.kst, dut.cpu_inst_p.clkena_in, dut.cpu_inst_p.nuds, dut.cpu_inst_p.nlds,
	         dut.cpu_inst_p.addr_out, dut.cpustate);
reg [1:0] dma_cmd = 0;
reg [4:0] dma_t = 0;
reg       dma_seen = 0;
always @(posedge clk_114) begin
	if (dma_tgl != dma_seen) begin dma_seen <= dma_tgl; dma_cmd <= dma_val; end
	else if (dma_cmd != 0 && dma_t == 0) begin
		if (dma_cmd == 2'd2) begin
			ddr[19'h40020][31:0] <= {dma_data[15:0], dma_data[31:16]};   // $200100: word $40020
			dma_cmd <= 0;
		end else begin
			mem[16'h3100 >> 1] <= dma_data[31:16];
			mem[16'h3102 >> 1] <= dma_data[15:0];
			if (dma_cmd == 2'd1) begin snp_adr <= 24'h001880; snp_tgl <= ~snp_tgl; end
			dma_t <= 1;
		end
	end else if (dma_t != 0) begin
		dma_t <= dma_t + 1;
		if (dma_t == 5'd16) begin
			if (dma_cmd == 2'd1) begin snp_adr <= 24'h001881; snp_tgl <= ~snp_tgl; end
			dma_t <= 0; dma_cmd <= 0;
		end
	end
end

// DDR3 model and CPU clock counter (declarations above cpu_wrapper)
initial for (di = 0; di < 524288; di = di + 1) ddr[di] = 64'd0;
always @(posedge clk_114) begin
	mclk <= mclk + 1;
	lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
	s_waitrequest <= DDR_WAIT ? lfsr[0] & lfsr[3] : 1'b0;
	s_readdatavalid <= 1'b0;
	if (!s_waitrequest && s_write) begin
		for (di = 0; di < 8; di = di + 1)
			if (s_byteenable[di]) ddr[s_address[18:0]][8*di +: 8] <= s_writedata[8*di +: 8];
		ddr_writes = ddr_writes + 1;
	end
	if (!s_waitrequest && s_read) begin
		rd_addr_q[rq_tail] <= s_address[18:0];
		rd_left_q[rq_tail] <= s_burstcount;
		rd_due_q[rq_tail]  <= mclk + DDR_LAT;
		rq_tail <= rq_tail + 1;
		ddr_reads = ddr_reads + 1;
	end
	if (rq_head != rq_tail && mclk >= rd_due_q[rq_head]) begin
		s_readdatavalid <= 1'b1;
		s_readdata <= ddr[rd_addr_q[rq_head]];
		rd_addr_q[rq_head] <= rd_addr_q[rq_head] + 1;
		rd_left_q[rq_head] <= rd_left_q[rq_head] - 1;
		if (rd_left_q[rq_head] == 1) rq_head <= rq_head + 1;
	end
end
// the Fast RAM port must map Zorro II RAM exactly as cpu_wrapper and
// ddram_ctrl do: 64-bit word {3'b001, ramaddr[28:3]} with ramaddr[28:27] = 11,
// ramaddr[26:23] = 0 and ramaddr[22:3] = the address ($200000-$9FFFFF)
always @(posedge clk_114)
	if ((fr_read || fr_write) && !(fr_address[28:26] == 3'b001 && fr_address[25:24] == 2'b11 &&
	                               fr_address[23:20] == 4'd0)) begin
		$display("FAIL: Fast RAM access mapped outside Zorro II RAM: %h", fr_address);
		errors = errors + 1;
	end
// the second master: random single reads and writes in its own region
// (DDR3 words below the card's, word bit 18 clear), checking what it reads back
reg  [63:0] m1_shadow [0:15];
reg   [3:0] m1_slot = 0;
reg         m1_wait_rd = 0;
integer     m1_ops = 0, mi;
initial for (mi = 0; mi < 16; mi = mi + 1) m1_shadow[mi] = 64'd0;
always @(posedge clk_114) begin
	if ((m1_read || m1_write) && !m1_waitrequest) begin
		if (m1_write) m1_shadow[m1_slot] <= m1_writedata;
		m1_wait_rd <= m1_read;
		m1_read <= 0; m1_write <= 0;
		m1_ops = m1_ops + 1;
	end else if (m1_readdatavalid && m1_wait_rd) begin
		if (m1_readdata !== m1_shadow[m1_slot]) begin
			$display("FAIL: second DDR3 master read %h, expected %h", m1_readdata, m1_shadow[m1_slot]);
			errors = errors + 1;
		end
		m1_wait_rd <= 0;
	end else if (FASTRAM && !m1_read && !m1_write && !m1_wait_rd && lfsr[7:4] == 4'hA) begin
		m1_slot      <= lfsr[11:8];
		m1_address   <= {3'b001, 22'd16, lfsr[11:8]};
		m1_writedata <= {lfsr, lfsr, ~lfsr, mclk[15:0]};
		if (lfsr[12]) m1_write <= 1; else m1_read <= 1;
	end
end

// CPU clock counter, readable at $F150 (the program's timer)
reg [31:0] cpu_clocks = 0;
always @(posedge clk_cpu) cpu_clocks <= cpu_clocks + 1;

// FC watch, as in tb_ap030_program: $F1C0 long = watched longword address,
// $F1C4 word = the function code of the last processor read of it, taken
// at the AP030 pins
reg [31:0] watch_addr = 32'hFFFFFFFF;
reg  [2:0] watch_fc = 0;
always @(posedge clk_cpu)
	if (!dut.cpu_inst_p.as_n && dut.cpu_inst_p.rw &&
	    ({dut.cpu_inst_p.a[31:2], 2'b00} == {watch_addr[31:2], 2'b00}))
		watch_fc <= dut.cpu_inst_p.cfc;

always @(posedge clk_114) begin
	mem[16'hF150 >> 1] <= cpu_clocks[31:16];
	mem[16'hF152 >> 1] <= cpu_clocks[15:0];
	mem[16'hF1C4 >> 1] <= {13'd0, watch_fc};
end

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
		if (cw_addr == (16'hF102 >> 1) && !cw_uds && !cw_lds && $test$plusargs("idedump"))
			$display("IDEDUMP w: %h %h %h %h %h %h %h %h | l: %h %h %h %h %h %h %h %h",
			         mem[16'h4000>>1], mem[16'h4002>>1], mem[16'h4004>>1], mem[16'h4006>>1],
			         mem[16'h4008>>1], mem[16'h400A>>1], mem[16'h400C>>1], mem[16'h400E>>1],
			         mem[16'h4400>>1], mem[16'h4402>>1], mem[16'h4404>>1], mem[16'h4406>>1],
			         mem[16'h4408>>1], mem[16'h440A>>1], mem[16'h440C>>1], mem[16'h440E>>1]);
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
		// DMA model ($F180): 1 = chipset write of dma_data ($F184, default
		// $55667788) at chip $3100 with its snoops, 3 = the same write without
		// snoops (a control), 2 = an external write of dma_data to Fast RAM
		// $200100 (DDR3; the system has no such writer, no snoop path)
		if (cw_addr == (16'hF180 >> 1)) begin dma_val <= cw_data[1:0]; dma_tgl <= ~dma_tgl; end
		if (cw_addr == (16'hF184 >> 1)) dma_data[31:16] <= cw_data;
		if (cw_addr == (16'hF186 >> 1)) dma_data[15:0]  <= cw_data;
		if (cw_addr == (16'hF1A0 >> 1)) bench_runs[31:16] <= cw_data;
		if (cw_addr == (16'hF1A2 >> 1)) bench_runs[15:0]  <= cw_data;
		if (cw_addr == (16'hF1A4 >> 1)) bench_clks[31:16] <= cw_data;
		if (cw_addr == (16'hF1A6 >> 1)) bench_clks[15:0]  <= cw_data;
		if (cw_addr == (16'hF1A8 >> 1)) bench_report <= 1;
		if (cw_addr == (16'hF1D0 >> 1)) ide_tgl <= ~ide_tgl;
		if (cw_addr == (16'hF1C0 >> 1)) watch_addr[31:16] <= cw_data;
		if (cw_addr == (16'hF1C2 >> 1)) watch_addr[15:0]  <= cw_data;
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
	$display("tb_ap030_wrapchip: running %0s over the 7MHz chip bus", prog_file);
	if ($value$plusargs("vcd=%s", vcd_file)) begin
		$dumpfile(vcd_file);
		$dumpvars(1, tb_ap030_wrapchip);
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
		$display("  pc=%08x ir=%04x sr=%04x state=%0d",
		         dut.cpu_inst_p.cpu.core.pc_i, dut.cpu_inst_p.cpu.core.ir,
		         dut.cpu_inst_p.cpu.core.sr, dut.cpu_inst_p.cpu.core.state);
	end
	else if (result == 2) begin
		$display("FAIL: program reports failure, test %0d", failcode);
	end
	else
		$display("chip-bus run passed (%0d cycles; DDR3 reads %0d writes %0d, second master %0d)", timeout, ddr_reads, ddr_writes, m1_ops);

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
