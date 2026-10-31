//--------------------------------------------------------------------------//
// tb_ap060_wrapchip.sv - the AP68060 through cpu_wrapper                   //
//                                                                          //
// The real cpu_wrapper (its chip bus state machine on the 7 MHz phases,   //
// autoconfiguration, memory_router) with ap060_tg68k_compat and the       //
// AP68060 core in TG68K's place.  Around it:                              //
//   - the clocks as Minimig.sv makes them: clk_114, clk_cpu (half of it)  //
//     and clk (a quarter), rising edges aligned; the 7 MHz phases and the //
//     RAM port's cycle gating (cyc, ram_cs) from Minimig.sv, verbatim     //
//   - chip bus: 2 MB of chip RAM at $000000 holding the program; DTACK    //
//     after DTACK_WAIT clocks (WAIT: a random 0..7 more per cycle)        //
//   - the RAM port: the Zorro II Fast RAM card, 2 MB.  REAL_DDR = 1: the  //
//     real ddram_ctrl (cpu_cache_new, write buffer) on a DDR3 model       //
//     (DDR_LAT clk_114 cycles to read data, WAIT: random waitrequest), as //
//     Minimig.sv wires it; REAL_DDR = 0: a simple model answering RAM_LAT //
//     clocks after a request, one clock wide                              //
//   - MMIO in chip RAM space, as the AP68060 program bench has it:       //
//       $F100.w  test number   $F102.w  $600D pass, else fail             //
//       $F108.w  time stamp: prints the value and the ns since the last  //
//       $F11C.w  the next $F124 queues a DMA read instead (its result in  //
//                chip RAM $F128.w when done)                               //
//       $F11E.w  hold the Fast RAM port's DDR3 writes until ddram_ctrl    //
//                presents a DMA (each write arms it once)                  //
//       $F12C.w  the next chip-bus cycle waits this many clocks more (as   //
//                busy chipset DMA would hold it)                           //
//       $F130.w  the next DDR3 read burst longer than a line waits this   //
//                many clk_114 clocks after its first line (the Fast RAM   //
//                port's prefetched lines arrive late)                     //
//       $F12E.w  the run ends when RSTO asserts: PASS when nothing posted  //
//                is unfinished and chip RAM $8100.w holds $1234 (t_reset)  //
//       $F1D0.w  IDE: load a 256-word sector into drive 0 (fastchip's      //
//                Gayle), DRQ raised; chip RAM $F1D2.w nonzero when done    //
//       $F126.w  DMA data; $F124.w a word offset into the Zorro II card:   //
//                ddram_ctrl's DMA port writes the word there (as Akiko or  //
//                CDTV DMA does, through chipdma_arb); chip RAM $F12A.w     //
//                counts the DMA writes completed (dmaACK; REAL_DDR)        //
//       $F110.w  interrupt level (IPL) the bench drives                   //
//       $F120.w  the bench rewrites chip RAM $8000.l with ~its value,    //
//                as chipset DMA would (no CPU bus cycle)                   //
//       $F118.w  an NMI as the Action Replay/HRTmon cartridge raises it   //
//                (cart.v): level 7 held until a read at the acknowledge   //
//                address $FFFFFE (the level 7 one) takes it away           //
//       $F200.w  the bench writes the level of every interrupt           //
//                acknowledge read it sees on the chip bus ($FFFFFFF0 +    //
//                level * 2), for the program to check                      //
//       $DFF09C.w INTREQ: a clearing write (bit 15 clear) releases the    //
//                bench's interrupt request (as $F110 = 0)                  //
//       $F112.w  random interrupts: level (0 off); each one is raised     //
//                after a random 1..$F114.w clocks and held until the      //
//                handler writes $F110 = 0                                  //
//                                                                          //
//   +prog=<16-bit word hex>  +timeout=<clocks>  +trace                     //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_ap060_wrapchip #(
	parameter FASTRAM    = 1,          // the 2 MB Zorro II card
	parameter WAIT       = 0,          // random wait states on both ports
	parameter DTACK_WAIT = 2,
	parameter RAM_LAT    = 3,
	parameter REAL_DDR   = 1,          // ddram_ctrl on a DDR3 model
	parameter DDR_LAT    = 12,
	parameter AVL_STRICT = 1,          // 1: read data may return while waitrequest is asserted
	                                   // (Avalon allows it; 0 holds it back, as before the
	                                   // ddram_ctrl fix)
	parameter THROTTLE   = 0,          // the OSD's stock speed option (cpucfg[2])
	parameter CPU_1X     = 0,          // 1: the processor on clk itself (the crossings then
	                                   // run between two copies of one clock)
	parameter real CPU_HALF = 9.0909,  // the processor clock's half period: 55 MHz
	parameter A2065      = 1,          // the A2065 mailbox on ddram_ctrl's second port, polling
	parameter FPU        = 1           // a full MC68060 (0: an MC68LC060)
);

//--------------------------------------------------------------------------
// clocks: one tick generator, so the three rising edges coincide exactly
//--------------------------------------------------------------------------
reg clk_114 = 0, clk_cpu = 0, clk = 0;
reg [1:0] tick = 0;
always #4.358 begin                    // 114.7 MHz half period
	tick    = tick + 2'd1;
	clk_114 = ~clk_114;                // rises on odd ticks
	if (tick == 2'd1) clk = ~clk;      // every fourth
	if (CPU_1X) clk_cpu = clk;
end
// the processor clock: pll_cpu's, unrelated to the Minimig clocks
initial if (!CPU_1X) begin
	#3.1;                              // an arbitrary phase
	forever #(CPU_HALF) clk_cpu = ~clk_cpu;
end

reg reset = 0;                         // active low
real stamp_t = 0.0;                    // $F108: the previous time stamp
reg [15:0] dma_dat = 0;                // $F126: the next DMA write's data
integer    cw_extra = 0;               // $F12C: wait clocks added to the next chip-bus cycle
reg        rst_end = 1'b0;             // $F12E: the run ends at RSTO (t_reset)
reg [32:0] dma_q [0:63];               // $F124: queued DMA operations {read, offset, data}
reg        dma_rdnext = 1'b0;          // $F11C: the next $F124 queues a DMA read
reg        fq_hold_tgl = 1'b0;         // $F11E: hold the Fast RAM port's DDR3 writes until a DMA
reg        pg_tgl = 1'b0;              // $F130: delay the next burst's lines after its first
reg [15:0] pg_val = 16'd0;
integer    dma_qw = 0, dma_qr = 0;

// Minimig.sv: c1 (a 7 MHz phase enable in the clk domain) resynchronises
// the clk_114 divider; cyc marks the cycle before each clk edge; the 7 MHz
// phases for cpu_wrapper's chip bus state machine
reg [1:0] c1q = 0;
reg       c1 = 0;
always @(posedge clk) begin c1q <= c1q + 2'd1; c1 <= (c1q == 2'd3); end

reg  cpu_ph1 = 0, cpu_ph2 = 0, cyc = 0, ram_cs = 0;
wire ram_ready, ram_sel;
always @(posedge clk_114) begin
	reg [3:0] div;
	reg       c1d;
	div <= div + 1'd1;
	c1d <= c1;
	if (~c1d & c1) div <= 3;
	if (~reset) begin
		cyc <= 0; cpu_ph1 <= 0; cpu_ph2 <= 0;
	end
	else begin
		cyc <= !div[1:0];
		if (div[1] & ~div[0]) begin
			cpu_ph1 <= 0; cpu_ph2 <= 0;
			case (div[3:2])
				0: cpu_ph2 <= 1;
				2: cpu_ph1 <= 1;
			endcase
		end
	end
	ram_cs <= ~(ram_ready & cyc) & ram_sel;      // cpu_type = 1
end

//--------------------------------------------------------------------------
// the design under test
//--------------------------------------------------------------------------
wire [23:1] chip_addr;
reg  [15:0] chip_dout;
wire [15:0] chip_din;
wire        chip_as, chip_uds, chip_lds, chip_rw;
reg         chip_dtack = 1'b1;
reg   [2:0] chip_ipl = 3'b111;
reg         nmi_req  = 1'b0;           // cart.v's int7
wire  [2:0] chip_ipl_eff = nmi_req ? 3'b000 : chip_ipl;

wire        ramlds, ramuds, ramshared;
wire [28:1] ramaddr;
wire [15:0] ramdin;
wire [15:0] ramdout;
wire        reset_out;
wire  [1:0] cpustate;
wire  [3:0] cacr;
wire [31:0] nmi_addr;
wire        z2ram_ena, z3ram_ena0, z3ram_ena1, dcache_sw_en;
wire  [4:0] z3ram_base0;
wire  [3:0] z3ram_base1;

// the processor's Fast RAM port (Minimig.sv: fastram_arbiter, ahead of
// ddram_ctrl on DDRAM)
wire [28:0] fr_address;
wire  [7:0] fr_burstcount, fr_byteenable;
wire        fr_read, fr_write, fr_waitrequest, fr_readdatavalid;
wire [63:0] fr_writedata, fr_readdata;
wire        fr_dma_req, fr_dma_ack;    // ddram_ctrl <-> the Fast RAM port: DMA coherence
wire  [7:0] fr_q_done;                 // ... and DMA ordering
wire  [4:0] fr_q_pend;
// fastchip (Minimig.sv): Gayle IDE, the RTG registers and Akiko, answered
// in clk_sys without the chip bus
wire        fc_sel, fc_lds, fc_uds, fc_rnw, fc_lw, fc_selack, fc_ready;
wire [15:0] fc_dout;

cpu_wrapper #(.AP060_FPU(FPU)) dut (
	.reset(reset), .reset_out(reset_out),
	.clk(clk), .clk_cpu(clk_cpu), .ph1(cpu_ph1), .ph2(cpu_ph2),
	.cpucfg({THROTTLE != 0, 2'b11}), .fastramcfg(FASTRAM ? 3'd1 : 3'd0), .cachecfg(3'd0), .bootrom(1'b0),
	.chip_addr(chip_addr), .chip_dout(chip_dout), .chip_din(chip_din),
	.chip_as(chip_as), .chip_uds(chip_uds), .chip_lds(chip_lds), .chip_rw(chip_rw),
	.chip_dtack(chip_dtack), .chip_ipl(chip_ipl_eff),
	.fastchip_dout(fc_dout), .fastchip_sel(fc_sel), .fastchip_lds(fc_lds), .fastchip_uds(fc_uds),
	.fastchip_rnw(fc_rnw), .fastchip_lw(fc_lw), .fastchip_selack(fc_selack), .fastchip_ready(fc_ready),
	.ramsel(ram_sel), .ramaddr(ramaddr), .ramdin(ramdin), .ramdout(ramdout), .ramready(ram_ready),
	.ramlds(ramlds), .ramuds(ramuds), .ramshared(ramshared),
	.toccata_ena(), .toccata_base(), .a2065_ena(), .a2065_base(),
	.cdtv_mode(1'b0), .cdtv_base(), .cdtv_din(16'd0), .cdtv_selack(1'b0),
	.cpustate(cpustate), .cacr(cacr), .nmi_addr(nmi_addr),
	.z2ram_ena(z2ram_ena), .z3ram_base0(z3ram_base0), .z3ram_ena0(z3ram_ena0),
	.z3ram_base1(z3ram_base1), .z3ram_ena1(z3ram_ena1),
	.dcache_sw_en(dcache_sw_en),
	.clk_mem(clk_114), .fr_dma_req(fr_dma_req), .fr_dma_ack(fr_dma_ack), .fr_q_done(fr_q_done), .fr_q_pend(fr_q_pend),
	.fr_address(fr_address), .fr_burstcount(fr_burstcount), .fr_read(fr_read), .fr_write(fr_write),
	.fr_writedata(fr_writedata), .fr_byteenable(fr_byteenable), .fr_waitrequest(fr_waitrequest),
	.fr_readdata(fr_readdata), .fr_readdatavalid(fr_readdatavalid)
);

//--------------------------------------------------------------------------
// memories
//--------------------------------------------------------------------------
reg [15:0] chip [0:(1<<20)-1];         // 2 MB, word addressed
reg [15:0] fast [0:(1<<20)-1];         // REAL_DDR = 0
reg [63:0] ddr  [0:(1<<20)-1];         // REAL_DDR = 1: 8 MB of 64-bit words
integer i;
string  prog;
integer timeout;
initial begin
	for (i = 0; i < (1<<20); i = i + 1) begin chip[i] = 16'd0; fast[i] = 16'hDEAD; ddr[i] = 64'hDEADDEADDEADDEAD; end
	if (!$value$plusargs("prog=%s", prog)) prog = "prog.hex";
	if (!$value$plusargs("timeout=%d", timeout)) timeout = 4000000;
	$readmemh(prog, chip);
end

//--------------------------------------------------------------------------
// chip bus: DTACK after a few clocks, the access on the clock it is given
//--------------------------------------------------------------------------
integer cw = 0;
reg     cbusy = 0;
reg [2:0]  rnd_lvl = 0;                // random interrupt level, 0 off
reg [15:0] progress = 0;               // $F10A: the program's progress counter
reg [15:0] rnd_max = 16'd200;
integer    rnd_cnt = 100;
reg [15:0] result = 0;
reg [15:0] testno = 0;
integer cycles = 0;
wire [19:0] cwi = chip_addr[20:1];
wire        cmem = (chip_addr[23:21] == 3'd0);

always @(posedge clk) begin
	cycles <= cycles + 1;
	// random interrupts: count down while none is pending, then raise one
	if (rnd_lvl != 0 && chip_ipl == 3'b111) begin
		if (rnd_cnt <= 0) begin
			chip_ipl <= ~rnd_lvl;
			rnd_cnt  <= 1 + ($urandom % rnd_max);
		end
		else rnd_cnt <= rnd_cnt - 1;
	end
	if (chip_as) begin
		chip_dtack <= 1'b1;
		cbusy <= 1'b0;
	end
	else if (!cbusy) begin
		cbusy <= 1'b1;
		cw    <= DTACK_WAIT + (WAIT ? ($urandom % 8) : 0) + cw_extra;
		cw_extra <= 0;
	end
	else if (cw != 0) cw <= cw - 1;
	else if (chip_dtack) begin
		chip_dtack <= 1'b0;
		if (chip_rw) begin
			chip_dout <= cmem ? chip[cwi] : 16'hFFFF;
			// interrupt acknowledge reads ($FFFFFFF0 + level * 2)
			if (chip_addr[23:4] == 20'hFFFFF) begin
				chip[20'h7900] <= {13'd0, chip_addr[3:1]};     // $F200
				if (&chip_addr) nmi_req <= 1'b0;               // cart.v: int7_ack
			end
		end
		else begin
			if (cmem) begin
				if (!chip_uds) chip[cwi][15:8] <= chip_din[15:8];
				if (!chip_lds) chip[cwi][7:0]  <= chip_din[7:0];
			end
			case ({chip_addr[23:1], 1'b0})
				24'h00F100: testno <= chip_din;
				24'h00F102: begin
					result <= chip_din;
					if (chip_din != 16'h600D)
						$display("FAIL: program reports failure, test %0d (cycle %0d)", testno, cycles);
				end
				24'h00F110: chip_ipl <= ~chip_din[2:0];
				// INTREQ: a write clearing bits (SET, bit 15, clear) takes the
				// bench's request away, as Paula's acknowledge does
				24'hDFF09C: if (!chip_din[15]) chip_ipl <= 3'b111;
				24'h00F118: nmi_req  <= 1'b1;
				24'h00F112: rnd_lvl  <= chip_din[2:0];
				24'h00F10A: progress <= chip_din;
				24'h00F114: rnd_max  <= chip_din;
				24'h00F126: dma_dat  <= chip_din;
				24'h00F12C: cw_extra <= chip_din;
				24'h00F12E: rst_end  <= 1'b1;
				24'h00F1D0: ide_tgl  <= ~ide_tgl;
				24'h00F124: begin dma_q[dma_qw % 64] <= {dma_rdnext, chip_din, dma_dat}; dma_qw <= dma_qw + 1; dma_rdnext <= 1'b0; end
				24'h00F11C: dma_rdnext <= 1'b1;
				24'h00F11E: fq_hold_tgl <= ~fq_hold_tgl;
				24'h00F130: begin pg_val <= chip_din; pg_tgl <= ~pg_tgl; end
				24'h00F108: begin
					// a time stamp: the time since the previous one
					$display("STAMP %04h %0d ns", chip_din, $rtoi($realtime - stamp_t));
					stamp_t = $realtime;
				end
				24'h00F120: begin
					// chipset DMA: rewrite $8000.l behind the processor
					chip[20'h4000] <= ~chip[20'h4000];
					chip[20'h4001] <= ~chip[20'h4001];
				end
				default: ;
			endcase
		end
	end
end

//--------------------------------------------------------------------------
// RAM port
//--------------------------------------------------------------------------
wire zram_sel = |ramaddr[28:26];       // Minimig.sv: the DDR3 controller's share
//--------------------------------------------------------------------------
// fastchip, as Minimig.sv instantiates it (IDE in its fast mode), and the
// IDE management side MiSTer's ARM plays: a write to $F1D0 marks drive 0
// present, loads one 256-word sector into its buffer (word i = {i ^ $5A,
// i}) and raises DRQ with the last-read flag; chip RAM $F1D2 becomes
// nonzero when it is done (from tests/ap030, the AP68030's bench)
//--------------------------------------------------------------------------
wire        pal_clk, pal_wr;
wire [23:0] pal_dw, pal_dr;
wire  [7:0] pal_a;
reg  [23:0] clut [0:255];
always @(posedge pal_clk) if (pal_wr) clut[pal_a] <= pal_dw;
assign pal_dr = clut[pal_a];
reg  [4:0] ide_a = 0;
reg        ide_w = 0;
reg [15:0] ide_wd = 0;
fastchip fastchip (
	.clk(clk_114), .cyc(cyc), .clk_sys(clk),
	.reset(~reset | ~reset_out),
	.sel(fc_sel), .sel_ack(fc_selack), .ready(fc_ready),
	.addr({chip_addr, 1'b0}), .din(chip_din), .dout(fc_dout),
	.lds(~fc_lds), .uds(~fc_uds), .rnw(fc_rnw), .longword(fc_lw),
	.rtg_ena(), .rtg_hsize(), .rtg_vsize(), .rtg_format(), .rtg_base(), .rtg_stride(),
	.rtg_pal_clk(pal_clk), .rtg_pal_dw(pal_dw), .rtg_pal_dr(pal_dr), .rtg_pal_a(pal_a), .rtg_pal_wr(pal_wr),
	.ide_ena(1'b1), .ide_irq(), .ide_req(),
	.ide_address(ide_a), .ide_write(ide_w), .ide_writedata(ide_wd), .ide_read(1'b0), .ide_readdata(),
	.ide_led(),
	.akiko_irq(),
	.akiko_dma_req(), .akiko_dma_we(), .akiko_dma_baddr(), .akiko_dma_wbyte(),
	.akiko_dma_rbyte(8'd0), .akiko_dma_ack(1'b0), .akiko_dma_arm(1'b0),
	.akiko_uio_cs(1'b0), .akiko_uio_cs_sec(1'b0), .akiko_uio_cs_nvr(1'b0), .akiko_uio_cs_subcode(1'b0),
	.akiko_uio_wr(1'b0), .akiko_uio_rd(1'b0), .akiko_uio_din(16'd0), .akiko_uio_dout(),
	.akiko_uio_req(), .akiko_uio_sec_req(), .akiko_uio_rx_busy(), .akiko_uio_nvr_dirty()
);
reg  [9:0] ide_step = 0;               // 0 idle, 1..258 writes, 259 status
reg        ide_tgl = 0;
reg  [1:0] ide_tgl_s = 0;
wire [7:0] ide_i = ide_step[7:0] - 8'd3;
reg  [3:0] ide_ph = 0;                 // each write: 8 clk_114 high, 8 low
always @(posedge clk_114) begin
	ide_tgl_s <= {ide_tgl_s[0], ide_tgl};
	ide_ph <= ide_ph + 1'd1;
	if (ide_ph == 4'd7) ide_w <= 1'b0;
	if (ide_step == 0) begin
		// (the last write's strobe still ends after its eight clocks)
		if (ide_ph == 4'd7) ide_w <= 1'b0;
		ide_ph <= (ide_ph < 4'd7) ? ide_ph + 1'd1 : 4'd0;
		if (ide_tgl_s[1] != ide_tgl_s[0]) begin ide_step <= 1; ide_ph <= 0; end
	end
	else if (ide_ph == 4'd15) begin
		if (ide_step == 1) begin ide_a <= 5'd6; ide_wd <= 16'h000B; end          // drive 0 present
		else if (ide_step == 2) begin ide_a <= 5'd0; ide_wd <= 16'h0001; end     // 256 words, no error
		else if (ide_step <= 258) begin ide_a <= 5'h0F; ide_wd <= {ide_i ^ 8'h5A, ide_i}; end
		else begin ide_a <= 5'd5; ide_wd <= 16'h5A00; end                        // DRDY DSC DRQ, last read
		ide_w <= 1'b1;
		if (ide_step == 259) begin ide_step <= 0; chip[20'h78E9] <= 16'h0001; end   // $F1D2
		else ide_step <= ide_step + 1'd1;
	end
end

// RSTO (cpu_wrapper's reset_out) never overtakes a posted access: when it
// asserts, the adapter has no request queued and no chip-bus cycle is open
always @(posedge clk) if (reset && reset_out_q && !reset_out) begin
	if ($test$plusargs("rsttrace"))
		$display("%0d RSTO: queued %b kst %0d chip_as %b", cycles, dut.cpu_inst_p.p_tgl ^ dut.cpu_inst_p.k_tgl,
		         dut.cpu_inst_p.kst, chip_as);
	if (dut.cpu_inst_p.p_tgl != dut.cpu_inst_p.k_tgl || dut.cpu_inst_p.kst != 0 || !chip_as) begin
		$display("FAIL: RESET (RSTO) asserted with a posted access unfinished: queued %b kst %0d chip_as %b addr %h",
		         dut.cpu_inst_p.p_tgl ^ dut.cpu_inst_p.k_tgl, dut.cpu_inst_p.kst, chip_as, {chip_addr, 1'b0});
		$finish;
	end
	else if (rst_end) begin
		if (chip[20'h4080] == 16'h1234) result <= 16'h600D;
		else begin
			$display("FAIL: RESET: the write before it is not in chip RAM ($8100 = %h)", chip[20'h4080]);
			$finish;
		end
	end
end
reg reset_out_q = 1'b1;
always @(posedge clk) reset_out_q <= reset_out;

// +idetrace: the IDE model's counters as they move
reg [13:0] idet_io = 0, idet_mg = 0;
always @(posedge clk_114) if ($test$plusargs("idetrace")) begin
	idet_io <= fastchip.gayle.ide0.io_cnt; idet_mg <= fastchip.gayle.ide0.mgmt_cnt;
	if (fastchip.gayle.ide0.mgmt_write && fastchip.gayle.ide0.mgmt_address != 5'h0F)
		$display("%0d IDE mgmt write a=%0d d=%h reset=%b", cycles, fastchip.gayle.ide0.mgmt_address,
		         fastchip.gayle.ide0.mgmt_writedata, fastchip.gayle.ide0.reset);
	if (fastchip.gayle.ide0.io_cnt != idet_io || fastchip.gayle.ide0.mgmt_cnt != idet_mg)
		$display("%0d IDE io_cnt=%0d mgmt_cnt=%0d drq=%b io_read=%b", cycles, fastchip.gayle.ide0.io_cnt,
		         fastchip.gayle.ide0.mgmt_cnt, fastchip.gayle.ide0.drq, fastchip.gayle.ide0.io_read);
end
// the lost-write record (the detector below)
reg [15:0] sh_bus  [0:(1<<20)-1];      // 16-bit words of the 2 MB card
reg [15:0] sh_port [0:(1<<20)-1];
reg        sh_v    [0:(1<<20)-1];
integer    lost = 0;
initial for (i = 0; i < (1<<20); i = i + 1) begin sh_bus[i] = 16'hDEAD; sh_port[i] = 16'hDEAD; sh_v[i] = 0; end

generate if (REAL_DDR) begin : g_ddr
	// the A2065's DDR3 mailbox (Minimig: inside minimig.v's a2065), idle: it
	// publishes its write index after reset, then polls the CSR and INT
	// words every 64 clk_114 cycles, sharing ddram_ctrl's port as on the board
	wire [28:0] mb_address;
	wire  [7:0] mb_burstcount, mb_byteenable;
	wire        mb_read, mb_write, mb_readdatavalid, mb_waitrequest;
	wire [63:0] mb_writedata, mb_readdata;
	if (A2065) begin : g_mb
		a2065_ddr3_mailbox mb (
			.clk(clk_114), .rst_n(reset),
			.cmd_pending(1'b0), .cmd_rap(7'd0), .cmd_data(16'd0), .cmd_clear(),
			.csr0_out(), .csr1_out(), .csr2_out(), .csr3_out(), .a2065_int2(),
			.bram_req_valid(1'b0), .bram_req_addr(14'd0), .bram_req_wdata(16'd0), .bram_req_rw(1'b0),
			.bram_req_be(2'b11), .bram_req_ack(), .bram_resp_valid(), .bram_resp_data(),
			.avl_address(mb_address), .avl_burstcount(mb_burstcount), .avl_read(mb_read),
			.avl_readdata(mb_readdata), .avl_readdatavalid(mb_readdatavalid),
			.avl_writedata(mb_writedata), .avl_byteenable(mb_byteenable), .avl_write(mb_write),
			.avl_waitrequest(mb_waitrequest)
		);
	end
	else begin : g_nomb
		assign mb_address = 29'd0; assign mb_burstcount = 8'd1; assign mb_byteenable = 8'd0;
		assign mb_read = 1'b0; assign mb_write = 1'b0; assign mb_writedata = 64'd0;
	end

	// Minimig.sv: the processor's Fast RAM port and ram2 share DDRAM through
	// fastram_arbiter (the port first); the DDR3 model behind it
	wire        DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY;
	wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
	wire [28:0] DDRAM_ADDR;
	wire [63:0] DDRAM_DIN, DDRAM_DOUT;
	wire        ddr1_busy, ddr1_dout_ready, ddr1_rd, ddr1_we;
	wire  [7:0] ddr1_burstcnt, ddr1_be;
	wire [28:0] ddr1_addr;
	wire [63:0] ddr1_dout, ddr1_din;
	// ($F11E) the port's writes held off ahead of the arbiter, still queued
	// in the port, so that ddram_ctrl's DMA can take DDR3 meanwhile
	wire        fq_hold;
	wire        fr_write_a = fr_write && !fq_hold;
	wire        fr_waitrequest_a;
	assign      fr_waitrequest = fr_waitrequest_a || fq_hold;
	a2065_ddram_arbiter fastram_arbiter (
		.clk(clk_114), .rst(!reset),
		.m0_address(fr_address), .m0_burstcount(fr_burstcount), .m0_read(fr_read), .m0_readdata(fr_readdata),
		.m0_readdatavalid(fr_readdatavalid), .m0_writedata(fr_writedata), .m0_byteenable(fr_byteenable),
		.m0_write(fr_write_a), .m0_waitrequest(fr_waitrequest_a),
		.m1_address(ddr1_addr), .m1_burstcount(ddr1_burstcnt), .m1_read(ddr1_rd), .m1_readdata(ddr1_dout),
		.m1_readdatavalid(ddr1_dout_ready), .m1_writedata(ddr1_din), .m1_byteenable(ddr1_be),
		.m1_write(ddr1_we), .m1_waitrequest(ddr1_busy),
		.s_address(DDRAM_ADDR), .s_burstcount(DDRAM_BURSTCNT), .s_read(DDRAM_RD), .s_readdata(DDRAM_DOUT),
		.s_readdatavalid(DDRAM_DOUT_READY), .s_writedata(DDRAM_DIN), .s_byteenable(DDRAM_BE),
		.s_write(DDRAM_WE), .s_waitrequest(DDRAM_BUSY)
	);
	ddram_ctrl ram2 (
		.sysclk(clk_114), .reset_n(reset),
		.cache_rst(reset), .cache_inhibit(1'b0), .cpu_cache_ctrl(cacr), .dcache_sw_en(dcache_sw_en),
		.DDRAM_CLK(), .DDRAM_BUSY(ddr1_busy), .DDRAM_BURSTCNT(ddr1_burstcnt), .DDRAM_ADDR(ddr1_addr),
		.DDRAM_DOUT(ddr1_dout), .DDRAM_DOUT_READY(ddr1_dout_ready), .DDRAM_RD(ddr1_rd),
		.DDRAM_DIN(ddr1_din), .DDRAM_BE(ddr1_be), .DDRAM_WE(ddr1_we),
		.mem2_address(mb_address), .mem2_burstcount(mb_burstcount), .mem2_read(mb_read),
		.mem2_readdata(mb_readdata), .mem2_readdatavalid(mb_readdatavalid), .mem2_writedata(mb_writedata),
		.mem2_byteenable(mb_byteenable), .mem2_write(mb_write), .mem2_waitrequest(mb_waitrequest),
		.cpuWR(ramdin), .cpuAddr(ramaddr), .cpuU(ramuds), .cpuL(ramlds), .cpustate(cpustate),
		.cpuCS(zram_sel & ram_cs), .cpuRD(ramdout), .ramshared(ramshared), .ramready(ram_ready),
		.dmaAddr(dm_addr), .dmaCS(dm_cs), .dmaWE(dm_we), .dmaL(1'b0), .dmaU(1'b0), .dmaWR(dm_dat),
		.dmaRD(dm_rd), .dmaACK(dm_ack), .dma_coh_req(fr_dma_req), .dma_coh_ack(fr_dma_ack),
		.fr_q_done(fr_q_done), .fr_q_pend(fr_q_pend)
	);
	// the DMA master: one 16-bit write per $F124 write, at the card's word
	// dma_off (memory_router's Zorro II mapping: ramaddr {1, 0, 0000, a[22:1]})
	reg [15:0] dm_dat = 0;
	reg        dm_we = 1'b1;
	wire [15:0] dm_rd;
	reg  [1:0] dm_st = 0;
	reg        dm_cs = 0;
	reg [28:1] dm_addr = 0;
	wire       dm_ack;
	always @(posedge clk_114) begin
		case (dm_st)
			// (the queue: writes the program issues faster than they complete)
			0: if (dma_qr != dma_qw) begin
				dm_addr <= {1'b1, 1'b0, 4'd0, 22'h100000 + {6'd0, dma_q[dma_qr % 64][31:16]}};
				dm_dat  <= dma_q[dma_qr % 64][15:0];
				dm_we   <= !dma_q[dma_qr % 64][32];
				dma_qr  <= dma_qr + 1;
				dm_cs   <= 1'b1;
				dm_st   <= 1;
				if (!dma_q[dma_qr % 64][32]) begin
					sh_bus[{4'd0, dma_q[dma_qr % 64][31:16]}] <= dma_q[dma_qr % 64][15:0];   // (the lost-write record)
					sh_v[{4'd0, dma_q[dma_qr % 64][31:16]}]   <= 1'b1;
				end
			end
			1: if (dm_ack) begin
				dm_cs <= 1'b0; dm_st <= 2;
				// the program learns the write is done when the DMA is: in
				// DDR3, and no cache below the 68060 holds the old data
				chip[20'h7895] <= chip[20'h7895] + 16'd1;          // $F12A
				if (!dm_we) chip[20'h7894] <= dm_rd;              // $F128: a read's data
			end
			default: if (!dm_ack) dm_st <= 0;
		endcase
	end

	// the DDR3 model: 64-bit words, byte enables, read data DDR_LAT cycles
	// after a read is accepted (in order), optional random waitrequest
	reg         busy = 1'b1;
	reg  [63:0] rdq  [0:511];              // a read's words (up to 8), as at its acceptance
	reg   [3:0] rdb  [0:63];               // ... beats returned
	integer     rdn  [0:63];               // ... its length
	integer     rdt [0:63];
	integer     rq_head = 0, rq_tail = 0, mclk = 0;
	reg  [63:0] dout_r = 0;
	reg         dout_v = 0;
	reg  [15:0] lfsr = 16'hACE1;
	// ($F11E) the Fast RAM port's writes (the card's DDR3 words) held off
	// until a DMA request is pending, once
	reg  [1:0] pg_tgl_s = 2'b00;
	reg        pg_on = 1'b0;
	always @(posedge clk_114) pg_tgl_s <= {pg_tgl_s[0], pg_tgl};
	reg  [1:0] fq_tgl_s = 2'b00;
	reg        fq_on = 1'b0;           // armed, until a DMA request is pending
	reg        fq_dma = 1'b0;          // that DMA: not held by the DMA-write stall
	reg  [6:0] fq_wait = 7'd0;
	always @(posedge clk_114) begin
		fq_tgl_s <= {fq_tgl_s[0], fq_hold_tgl};
		if (fq_tgl_s[1] != fq_tgl_s[0]) fq_on <= 1'b1;
		// (released when ddram_ctrl's DMA reaches DDR3 -- the port's queued
		// writes then follow it -- or, when a DMA that waits for the port's
		// queue is pending for 64 clocks, to let that queue drain)
		else if (fq_on && (ram2.dma_write_ack || ram2.dma_read_in_flight || fq_wait == 7'd64)) begin
			fq_on <= 1'b0; fq_dma <= 1'b1;
		end
		fq_wait <= (fq_on && (ram2.dma_read_req || ram2.dma_write_req)) ? fq_wait + 7'd1 : 7'd0;
		if (fq_dma && dm_ack) fq_dma <= 1'b0;
	end
	assign fq_hold = fq_on && fr_write && (fr_address[28:18] == 11'h181);
	always @(posedge clk_114) if ($test$plusargs("ddrtrace") && !DDRAM_BUSY && (DDRAM_WE || DDRAM_RD) && DDRAM_ADDR[28:18] == 11'h181)
		$display("%0d DDR %s a=%h d=%h be=%h dma=%b", cycles, DDRAM_WE ? "WR" : "RD", DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, ram2.dma_we_cmd);
	assign DDRAM_BUSY = busy | (ram2.dma_we_cmd && !fq_dma && dm_wcnt != 15'd20000) | fq_hold;
	assign DDRAM_DOUT = dout_r;
	assign DDRAM_DOUT_READY = dout_v;
	integer k;
	reg  [14:0] dm_wcnt = 15'd0;
	reg         av_stall = 0, av_rd = 0, av_we = 0;
	reg  [28:0] av_a = 0;
	reg   [7:0] av_n = 0, av_be = 0;
	reg  [63:0] av_d = 0;
	wire nbusy = WAIT ? (lfsr[0] & lfsr[3]) : 1'b0;     // waitrequest next cycle
	always @(posedge clk_114) begin
		mclk <= mclk + 1;
		lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
		busy <= nbusy;
		// a DMA write presented is held off for 20000 cycles (waitrequest
		// from its first clock, ~175 us: many of the program's polls of
		// $F12A, each a chip-bus read): a controller that acknowledged a DMA
		// write on presenting it would let the program read the old data
		dm_wcnt <= !ram2.dma_we_cmd ? 15'd0 : (dm_wcnt != 15'd20000) ? dm_wcnt + 15'd1 : dm_wcnt;
		// Avalon: a command the slave stalls stays as it was presented
		// (address, burst count, read/write, write data and byte enables)
		if (av_stall && (DDRAM_RD != av_rd || DDRAM_WE != av_we || DDRAM_ADDR != av_a ||
		                 DDRAM_BURSTCNT != av_n || (av_we && (DDRAM_DIN != av_d || DDRAM_BE != av_be)))) begin
			$display("FAIL: DDR3 command changed under waitrequest: %s %h n=%0d -> %s %h n=%0d (cycle %0d)",
			         av_rd ? "RD" : "WR", av_a, av_n, DDRAM_RD ? "RD" : DDRAM_WE ? "WR" : "--",
			         DDRAM_ADDR, DDRAM_BURSTCNT, cycles);
			$finish;
		end
		av_stall <= DDRAM_BUSY && (DDRAM_RD || DDRAM_WE);
		av_rd <= DDRAM_RD; av_we <= DDRAM_WE; av_a <= DDRAM_ADDR; av_n <= DDRAM_BURSTCNT;
		av_d <= DDRAM_DIN; av_be <= DDRAM_BE;
		dout_v <= 1'b0;
		if (pg_tgl_s[1] != pg_tgl_s[0]) pg_on <= 1'b1;
		if (!DDRAM_BUSY && DDRAM_WE) begin
			if (DDRAM_BURSTCNT != 8'd1) $display("FAIL: DDR3 write burst %0d", DDRAM_BURSTCNT);
			for (k = 0; k < 8; k = k + 1)
				if (DDRAM_BE[k]) ddr[DDRAM_ADDR[19:0]][8*k +: 8] <= DDRAM_DIN[8*k +: 8];
		end
		if (!DDRAM_BUSY && DDRAM_RD) begin
			if (DDRAM_BURSTCNT == 8'd0 || DDRAM_BURSTCNT > 8'd8) $display("FAIL: DDR3 read burst %0d", DDRAM_BURSTCNT);
			for (k = 0; k < 8; k = k + 1)
				rdq[{rq_tail[5:0], 3'(k)}] <= ddr[DDRAM_ADDR[19:0] + 20'(k)];
			rdb[rq_tail[5:0]]  <= 4'd0;
			rdn[rq_tail[5:0]]  <= DDRAM_BURSTCNT;
			rdt[rq_tail[5:0]] <= mclk + DDR_LAT;
			rq_tail <= rq_tail + 1;
		end
		// Avalon lets a slave return read data while it holds waitrequest
		// for a new command (the default here: every master must take it)
		if (rq_head != rq_tail && mclk >= rdt[rq_head[5:0]] && (AVL_STRICT || !nbusy)) begin
			dout_r  <= rdq[{rq_head[5:0], rdb[rq_head[5:0]][2:0]}];
			dout_v  <= 1'b1;
			rdb[rq_head[5:0]] <= rdb[rq_head[5:0]] + 4'd1;
			// ($F130) the rest of a burst held back after its first line
			if (pg_on && rdb[rq_head[5:0]] == 4'd1 && rdn[rq_head[5:0]] > 2) begin
				rdt[rq_head[5:0]] <= mclk + pg_val;
				pg_on <= 1'b0;
				if ($test$plusargs("ddrtrace")) $display("%0d DDR burst held %0d clocks after its first line", cycles, pg_val);
			end
			if (rdb[rq_head[5:0]] + 4'd1 == 4'(rdn[rq_head[5:0]])) rq_head <= rq_head + 1;
		end
	end
end
else begin : g_simple
	// a simple model: ramready one clock, RAM_LAT clocks after the request
	integer rw = 0;
	reg [1:0] rst8 = 0;
	reg       rdy = 0;
	reg [15:0] rd = 0;
	wire [19:0] fwi = ramaddr[20:1];
	assign ram_ready = rdy;
	assign ramdout = rd;
	always @(posedge clk) begin
		rdy <= 1'b0;
		case (rst8)
			0: if (ram_sel) begin
				rst8 <= 1;
				rw   <= RAM_LAT + (WAIT ? ($urandom % 8) : 0);
			end
			1: if (rw != 0) rw <= rw - 1;
			   else begin
				if (!ramaddr[28]) begin
					$display("FAIL: RAM port access outside the Zorro II card (ramaddr %h, cycle %0d)",
					         {ramaddr, 1'b0}, cycles);
					result <= 16'hBAD1;
				end
				rdy <= 1'b1;
				rd  <= fast[fwi];
				if (!dut.wr) begin
					if (!ramuds) fast[fwi][15:8] <= ramdin[15:8];
					if (!ramlds) fast[fwi][7:0]  <= ramdin[7:0];
				end
				rst8 <= 2;
			   end
			2: rst8 <= 0;
		endcase
	end
	assign fr_dma_req = 1'b0;
	// the processor's Fast RAM port on the same array: an Avalon-MM slave,
	// 64-bit words of four 16-bit words ascending from bit 0 (the DDR3
	// layout), the card's word w at 64-bit word w[19:2]; read data RAM_LAT
	// clk_114 cycles after a read is accepted
	reg        fr_v = 0;
	reg [63:0] fr_q = 0;
	reg [19:0] fr_a;
	integer    fr_n = 0, fr_t = 0;
	assign fr_waitrequest   = (fr_n != 0);
	assign fr_readdata      = fr_q;
	assign fr_readdatavalid = fr_v;
	always @(posedge clk_114) begin
		fr_v <= 1'b0;
		if (fr_n == 0 && fr_write)
			for (int j = 0; j < 4; j++) begin
				if (fr_byteenable[2*j])     fast[{fr_address[17:0], 2'(j)}][7:0]  <= fr_writedata[16*j +: 8];
				if (fr_byteenable[2*j + 1]) fast[{fr_address[17:0], 2'(j)}][15:8] <= fr_writedata[16*j + 8 +: 8];
			end
		if (fr_n == 0 && fr_read) begin
			fr_a <= {fr_address[17:0], 2'd0};
			fr_n <= fr_burstcount;
			fr_t <= RAM_LAT;
		end
		else if (fr_n != 0) begin
			if (fr_t != 0) fr_t <= fr_t - 1;
			else begin
				fr_q  <= {fast[fr_a + 20'd3], fast[fr_a + 20'd2], fast[fr_a + 20'd1], fast[fr_a]};
				fr_v  <= 1'b1;
				fr_a  <= fr_a + 20'd4;
				fr_n  <= fr_n - 1;
			end
		end
	end
end endgenerate

//--------------------------------------------------------------------------
// lost-write detector (REAL_DDR): what the processor wrote to Fast RAM,
// seen on the 68060 bus (TS with TA) and on the RAM port (a completed
// 16-bit write), against what the DDR3 model holds, checked whenever the
// model is read and at the end of the run
//--------------------------------------------------------------------------
generate if (REAL_DDR) begin : g_detect
	// the 68060 bus: the transfer latched by the adapter, at each TA (the
	// write data on D31-D0 then; a line beat at its own long word)
	wire [31:0] xa  = (dut.cpu_inst_p.xsiz == 2'b11) ?
	                  {dut.cpu_inst_p.xa[31:4], dut.cpu_inst_p.lw, 2'b00} : dut.cpu_inst_p.xa;
	wire  [1:0] xsz = dut.cpu_inst_p.xsiz;
	wire        xwr = !dut.cpu_inst_p.xrd;
	wire [31:0] wd  = dut.cpu_inst_p.d_o;
	wire        inz2 = (xa[31:21] == 11'd1);          // $200000-$3FFFFF
	always @(posedge clk_cpu) if (!(dut.cpu_inst_p.ta_n & dut.cpu_inst_p.f_ta_n) && xwr && inz2) begin
		case (xsz)
			2'b01: if (xa[0]) sh_bus[xa[20:1]][7:0] <= xa[1] ? wd[7:0] : wd[23:16];
			       else       sh_bus[xa[20:1]][15:8] <= xa[1] ? wd[15:8] : wd[31:24];
			2'b10: sh_bus[xa[20:1]] <= xa[1] ? wd[15:0] : wd[31:16];
			default: begin sh_bus[{xa[20:2], 1'b0}] <= wd[31:16]; sh_bus[{xa[20:2], 1'b1}] <= wd[15:0]; end
		endcase
		sh_v[xa[20:1]] <= 1'b1;
		if (xsz == 2'b00 || xsz == 2'b11) sh_v[{xa[20:2], 1'b1}] <= 1'b1;
	end
	// the RAM port: a write the wrapper completed (ramready at a clk edge)
	always @(posedge clk) if (ram_sel && cpustate == 2'd3 && ram_ready && ramaddr[28]) begin
		if (!ramuds) sh_port[ramaddr[20:1]][15:8] <= ramdin[15:8];
		if (!ramlds) sh_port[ramaddr[20:1]][7:0]  <= ramdin[7:0];
	end
	// the DDR3 model holds the card at address bits 22:3 (memory_router:
	// the Zorro II window, $200000-$3FFFFF, a[22:21] = 01); w indexes the
	// card's 16-bit words
	function [15:0] ddr_word(input [19:0] w);
		ddr_word = ddr[{2'b01, w[19:2]}][16*w[1:0] +: 16];
	endfunction
	task check(input [19:0] w, input string when);
		// (Fast RAM writes reach DDR3 through the processor's own port now,
		// not cpu_wrapper's: the bus against DDR3; port is shown for reference)
		if (sh_v[w] && ddr_word(w) != sh_bus[w]) begin
			lost = lost + 1;
			if (lost <= 20)
				$display("LOST WRITE %s: $%06x bus %04x port %04x ddr %04x (cycle %0d)", when,
				         {11'd1, w, 1'b0}, sh_bus[w], sh_port[w], ddr_word(w), cycles);
		end
	endtask
	always @(posedge clk_114) if (!g_ddr.DDRAM_BUSY && g_ddr.DDRAM_RD && !g_ddr.ram2.write_req && !g_ddr.ram2.write_ack) begin
		// (only when no write is in flight in ddram_ctrl: it serialises; the
		// Fast RAM port keeps its writes and reads in one ordered queue)
		for (int b = 0; b < g_ddr.DDRAM_BURSTCNT; b++)
			for (int j = 0; j < 4; j++)
				check({g_ddr.DDRAM_ADDR[17:0] + 18'(b), 2'(j)}, "on read");
	end
	final begin
		for (i = 0; i < (1<<20); i = i + 1) check(i[19:0], "at end");
		if (lost) $display("FAIL: %0d lost writes", lost);
		else $display("lost-write check: none");
	end
end endgenerate

// +trace: the processor's transfers (on its clock) and the wrapper's 16-bit
// accesses
reg trace = 0;
initial trace = $test$plusargs("trace");
always @(posedge clk_cpu) if (trace) begin
	if (!dut.cpu_inst_p.ts_n)
		$display("%8d TS  a=%h %s siz=%0d tt=%0d tm=%0d", cycles, dut.cpu_inst_p.a_o,
		         dut.cpu_inst_p.rw_n ? "RD" : "WR", dut.cpu_inst_p.siz, dut.cpu_inst_p.tt, dut.cpu_inst_p.tm);
	if (!dut.cpu_inst_p.ta_n)
		$display("%8d TA  d=%h tbi=%b tci=%b avec=%b", cycles, dut.cpu_inst_p.d_i,
		         !dut.cpu_inst_p.tbi_n, !dut.cpu_inst_p.tci_n, !dut.cpu_inst_p.avec_n);
end
always @(posedge clk) if (trace) begin
	if (dut.cpu_req && dut.clkena_p_throttled)
		$display("%8d ACC a=%h bs=%0d uds=%b lds=%b din=%h dout=%h ram=%b", cycles, dut.cpu_addr,
		         dut.cpustate, dut.uds_in, dut.lds_in, dut.cpu_din, dut.cpu_dout, ram_sel);
end

// +tfrom=<clk cycle>: the RAM port's handshake, every clk_114 cycle, for
// 400 cycles (REAL_DDR only)
integer tfrom;
initial if (!$value$plusargs("tfrom=%d", tfrom)) tfrom = -1;
generate if (REAL_DDR) begin : g_trace2
	integer t2 = 0;
	always @(posedge clk_114)
		if (tfrom >= 0 && cycles >= tfrom && t2 < 400) begin
			t2 <= t2 + 1;
			$display("%8d.%0d sel=%b cs=%b cyc=%b rdy=%b | csm=%0d hit=%b req=%b fill=%b wena=%b wreq=%b wack=%b | rd=%b we=%b busy=%b dv=%b | req=%b ena=%b cd=%0d a=%h st=%0d",
			         cycles, tick, ram_sel, ram_cs, cyc, ram_ready,
			         g_ddr.ram2.cpu_cache.cpu_sm_state, g_ddr.ram2.cache_hit, g_ddr.ram2.cache_req,
			         g_ddr.ram2.cache_fill, g_ddr.ram2.write_ena, g_ddr.ram2.write_req, g_ddr.ram2.write_ack,
			         g_ddr.DDRAM_RD, g_ddr.DDRAM_WE, g_ddr.DDRAM_BUSY, g_ddr.DDRAM_DOUT_READY,
			         dut.cpu_req, dut.clkena_p_throttled, dut.cooldown, dut.cpu_addr, cpustate);
		end
end endgenerate

// +ftrace=<from> (+ftto=<to>, default from + 200): the processor's
// pipeline every clk_cpu cycle -- fetch queue, back end stages and holds,
// the store buffer, the interrupt claim, the DMU engine and the BIU
integer ft_from, ft_to;
initial begin
	if (!$value$plusargs("ftrace=%d", ft_from)) ft_from = -1;
	if (!$value$plusargs("ftto=%d", ft_to)) ft_to = ft_from + 200;
end
always @(posedge clk_cpu)
	if (ft_from >= 0 && cycles >= ft_from && cycles < ft_to)
		$display("%8d Q%0d fst=%0d | AG %s DC1 %s DC2 %s EX %s WB %s | h ag=%b d2=%b ex=%b wb=%b | sbE=%b sbw=%b irqp=%b ipq=%0d ipend=%b | e=%0d biu=%0d ts=%b ta=%b",
		         cycles, dut.cpu_inst_p.cpu.fetch.cnt, dut.cpu_inst_p.cpu.fetch.st,
		         dut.cpu_inst_p.cpu.be.ag_v  ? $sformatf("%06x", dut.cpu_inst_p.cpu.be.ag_u.pc[23:0])  : "------",
		         dut.cpu_inst_p.cpu.be.dc1_v ? $sformatf("%06x", dut.cpu_inst_p.cpu.be.dc1_u.pc[23:0]) : "------",
		         dut.cpu_inst_p.cpu.be.dc2_v ? $sformatf("%06x", dut.cpu_inst_p.cpu.be.dc2_u.pc[23:0]) : "------",
		         dut.cpu_inst_p.cpu.be.ex_v  ? $sformatf("%06x", dut.cpu_inst_p.cpu.be.ex_u.pc[23:0])  : "------",
		         dut.cpu_inst_p.cpu.be.wb_v  ? $sformatf("%06x", dut.cpu_inst_p.cpu.be.wb_u.pc[23:0])  : "------",
		         dut.cpu_inst_p.cpu.be.ag_hold, dut.cpu_inst_p.cpu.be.dc2_hold, dut.cpu_inst_p.cpu.be.ex_hold,
		         dut.cpu_inst_p.cpu.be.wb_hold, dut.cpu_inst_p.cpu.be.sb_empty, dut.cpu_inst_p.cpu.be.sb_wait,
		         dut.cpu_inst_p.cpu.be.irq_pend, dut.cpu_inst_p.cpu.be.ipl_q, dut.cpu_inst_p.cpu.be.ipend_r,
		         dut.cpu_inst_p.cpu.dmu.e_st, dut.cpu_inst_p.cpu.biu.st,
		         !dut.cpu_inst_p.ts_n, !dut.cpu_inst_p.ta_n);

// +frtrace: the Fast RAM path -- the processor's TS and Fast RAM TA (clk_cpu),
// the DDR3 commands and read data of the port (clk_114), times in ns
reg frtrace = 0;
initial frtrace = $test$plusargs("frtrace");
always @(posedge clk_cpu) if (frtrace) begin
	if (!dut.cpu_inst_p.ts_n)
		$display("%0t TS  a=%h %s siz=%0d", $time, dut.cpu_inst_p.a_o, dut.cpu_inst_p.rw_n ? "RD" : "WR", dut.cpu_inst_p.siz);
	if (!dut.cpu_inst_p.f_ta_n) $display("%0t FTA", $time);
	if (dut.cpu_inst_p.fastram.n_req && dut.cpu_inst_p.fastram.n_ready) $display("%0t NREQ", $time);
	if (dut.cpu_inst_p.fastram.n_valid) $display("%0t NVALID", $time);
end
always @(posedge clk_114) if (frtrace) begin
	if (fr_read && !fr_waitrequest) $display("%0t AVRD a=%h n=%0d", $time, fr_address, fr_burstcount);
	if (fr_readdatavalid) $display("%0t AVDATA", $time);
end

// +exc: every exception entry the processor makes
reg exctrace = 0;
initial exctrace = $test$plusargs("exc");
always @(posedge clk_cpu)
	if (exctrace && dut.cpu_inst_p.cpu.be.x_go)
		$display("%8d EXC vec=%0d kind=%0d pc=%08x addr=%08x osr=%04x nsr=%04x", cycles,
		         dut.cpu_inst_p.cpu.be.x_vec, dut.cpu_inst_p.cpu.be.x_kind, dut.cpu_inst_p.cpu.be.x_pc,
		         dut.cpu_inst_p.cpu.be.x_addr, dut.cpu_inst_p.cpu.be.x_osr, dut.cpu_inst_p.cpu.be.x_nsr);

//--------------------------------------------------------------------------
// run
//--------------------------------------------------------------------------
initial begin
	repeat (40) @(posedge clk);
	reset = 1;
end

always @(posedge clk) begin
	if (result == 16'h600D) begin
		$display("PASS %s cycles=%0d", prog, cycles);
		$finish;
	end
	else if (result != 16'd0) begin
		$display("FAIL %s", prog);
		$finish;
	end
	else if (cycles >= timeout) begin
		$display("FAIL %s: timeout (test %0d, cpustate %0d, addr %h, progress %0d, pc %h)", prog, testno,
		         cpustate, dut.cpu_addr, progress, dut.cpu_inst_p.cpu.dbg_pc);
		$finish;
	end
end

endmodule
