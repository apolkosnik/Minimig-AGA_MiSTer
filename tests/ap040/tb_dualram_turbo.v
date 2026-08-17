// Dual-controller co-simulation: cpu_wrapper (28MHz) + BOTH RAM
// controllers at 113MHz -- sdram_ctrl/cpu_cache_new for chip data and
// ddram_ctrl (its own cpu_cache_new instance) for instruction fetches --
// with the combinational ready/data/CS muxes of Minimig.sv between them.
// On hardware cputest's code runs from Z3 fast RAM through ddram_ctrl
// while the failing operands live in chip RAM behind sdram_ctrl; the
// interleaved fetch/data streams flip the shared ram_cs_guard and the
// ready mux exactly as zram_sel does on the board.  This is fidelity gap
// #1 of the FABS.X ([0]) +2-window investigation: a single-controller
// bench cannot see a leftover level-ack of one controller being consumed
// through the mux while the other one is addressed.
//
// Fetches are presented to ddram_ctrl in a Z3-style window (bit 26 set)
// so its cache tags them apart; both controllers are backed by the same
// coherent program image, as chip and fast RAM hold the same bytes a
// relocating loader would place there.
`timescale 100ps/100ps

module tb_dualram_turbo;

// Default matches the deployed cache-coherence stress topology.  Zero
// explicitly exercises the production no-storage controller configuration.
parameter CPU_CACHE = 1;

reg clk113 = 0;
always #44 clk113 = ~clk113;

// phase-locked divide-by-4: clk28 edges chosen so the one-clk113 ph1/ph2
// pulses (div 2 and 10) straddle a 28MHz posedge, as they must on real
// hardware for the chip stage machine to see them at all.
reg [3:0] div = 0;
always @(posedge clk113) div <= div + 1'd1;
parameter CPU_PHASE = 3;
wire clk28 = (div[1:0] == CPU_PHASE[1:0]) | (div[1:0] == ((CPU_PHASE[1:0] + 2'd1) & 2'd3));

// 7MHz square for the SDRAM slot engine (16 clk113 per CCK)
wire c_7m = div[3];

reg ph1 = 0, ph2 = 0;
always @(posedge clk113) begin
	ph1 <= 0;
	ph2 <= 0;
	if (div[1] & ~div[0]) begin
		case (div[3:2])
			2'd0: ph2 <= 1;
			2'd2: ph1 <= 1;
			default: ;
		endcase
	end
end

reg reset = 0;

// Minimig.sv interposer between the CPU's ram_sel and the controller's
// cpuCS.  When ready meets the cyc phase marker the guard drops cpuCS and
// holds it low until the 28MHz side releases ram_sel, preventing a ghost
// transaction. CYC_PHASE sweeps the unknown PLL alignment vs clk28.
parameter CYC_PHASE = 1;
reg cyc = 0;
wire ram_cs;
wire ram_consumed;

//---------------------------------------------------------------------------
// CPU side
//---------------------------------------------------------------------------

wire        ramsel;
wire        cache_inhibit;
// Fetch/data routing between the two real controllers.  The select is
// the zram_sel analogue: combinational with the request, held at its
// last value while the bus is idle (the address register keeps the old
// value on hardware).  Assigns live below the memory model.
// exception and wild-PC tracer for MMU debug
integer exctrc = 0;
reg [7:0] prev_cstate = 0;
always @(posedge clk28) begin
	prev_cstate <= cpu.cpu_inst_p.core.state;
	if (cpu.cpu_inst_p.core.state == 8'd41 && prev_cstate != 8'd41 && exctrc < 200) begin
		$display("EXC t=%0d vec=%0d pc=%08x sr=%04x", $time,
			cpu.cpu_inst_p.core.exc_vec, cpu.cpu_inst_p.core.pc, cpu.cpu_inst_p.core.sr);
		exctrc = exctrc + 1;
	end
	if (cpu.cpu_inst_p.core.state == 8'd42 && prev_cstate != 8'd42 && exctrc < 200) begin
		$display("EXCJMP t=%0d target=%08x", $time, cpu.cpu_inst_p.core.m_val);
		exctrc = exctrc + 1;
	end
end

// PC history ring: dumped on timeout to localize where execution went wild
reg [31:0] prev_pc = 0;
reg [31:0] pc_ring [0:63];
reg [31:0] pc_time [0:63];
integer pc_rp = 0;
integer kk;
reg wild_logged = 0;
always @(posedge clk28) begin
	if (cpu.cpu_inst_p.core.pc != prev_pc) begin
		pc_ring[pc_rp & 63] <= cpu.cpu_inst_p.core.pc;
		pc_time[pc_rp & 63] <= $time;
		pc_rp <= pc_rp + 1;
		if (cpu.cpu_inst_p.core.pc > 32'h8000 && !wild_logged) begin
			wild_logged <= 1;
			$display("WILD: pc left program at t=%0d: %08x -> %08x", $time,
				prev_pc, cpu.cpu_inst_p.core.pc);
			for (kk = 0; kk < 64; kk = kk + 1)
				$display("  ring[%0d] t=%0d pc=%08x", kk,
					pc_time[(pc_rp + kk) & 63], pc_ring[(pc_rp + kk) & 63]);
		end
		prev_pc <= cpu.cpu_inst_p.core.pc;
	end
end

// periodic cache invalidation, mimicking cputest's per-test CINV flush
// (the clear/refill cycle was never exercised in sim before)
reg         cinv_tgl = 0;
reg  [14:0] cinv_cnt = 0;
always @(posedge clk113) begin
	cinv_cnt <= cinv_cnt + 1'd1;
	if (cinv_cnt == 0) cinv_tgl <= ~cinv_tgl;
end
wire        is_fetch;
wire        sel_ddr;
wire        ctrl_cs;
wire [15:0] ctrl_rd;
wire        ctrl_ready;
wire        ddr_cs;
wire [15:0] ddr_rd;
wire        ddr_ready;
wire [15:0] cpuRD_mux;
wire        ramready_mux;
wire [28:1] ramaddr;
wire [15:0] ramdin;
wire        ramlds, ramuds;
wire [15:0] cpuRD;

wire  [1:0] cpu_state;
wire  [3:0] cpu_cacr;
wire        cpu_nrst_out;

wire        cw_req, cw_we, cw_ddr, cw_bad;
wire [28:2] cw_addr;
wire [31:0] cw_wdat;
wire        cw_ack, cw_berr;
wire [31:0] cw_rdata;
wire        mw_req, mw_we, mw_ddr;
wire [28:2] mw_addr;
wire [31:0] mw_wdata;

reg  [2:0] ipl_lvl = 0;
reg [15:0] ipl_delay = 0;
reg        ipl_set_w = 0, ipl_arm_w = 0;
reg  [2:0] ipl_set_v = 0;
reg [15:0] ipl_arm_v = 0;

cpu_wrapper cpu
(
	.snoop_tgl(1'b0),
	.snoop_adr(24'd0),
	.reset(reset),
	.reset_out(cpu_nrst_out),

	.clk(clk28),
	.ph1(ph1),
	.ph2(ph2),

	.cpucfg(2'b10),
	.fastramcfg(3'd0),
	.cachecfg(3'b101),       // turbo chipram ON, data cache ON: chip data
	.bootrom(1'b0),          // reads take the cpu_cache_new/SDRAM path

	.chip_addr(),
	.chip_dout(16'h0000),
	.chip_din(),
	.chip_as(),
	.chip_uds(),
	.chip_lds(),
	.chip_rw(),
	.chip_dtack(1'b0),
	.chip_ipl(~ipl_lvl),

	.fastchip_dout(16'd0),
	.fastchip_sel(),
	.fastchip_lds(),
	.fastchip_uds(),
	.fastchip_rnw(),
	.fastchip_lw(),
	.fastchip_selack(1'b0),
	.fastchip_ready(1'b0),

	.ramsel(ramsel),
	.ramaddr(ramaddr),
	.ramdin(ramdin),
	.ramdout(cpuRD_mux),
	.ramready(ramready_mux),
	.ramconsumed(ram_consumed),
	.ramlds(ramlds),
	.ramuds(ramuds),
	.ramshared(),

	.walker_mem_req(cw_req),
	.walker_mem_we(cw_we),
	.walker_mem_addr(cw_addr),
	.walker_mem_wdat(cw_wdat),
	.walker_mem_ddr(cw_ddr),
	.walker_mem_bad(cw_bad),
	.walker_mem_ack(cw_ack),
	.walker_mem_rdata(cw_rdata),
	.walker_mem_berr(cw_berr),

	.toccata_ena(),
	.toccata_base(),
	.a2065_ena(),
	.a2065_base(),

	.cpustate(cpu_state),
	.cacr(cpu_cacr),
	.cache_inhibit(cache_inhibit),
	.nmi_ack_toggle(),
	.nmi_addr()
);

// periodic chipset DMA load (reads only, alternating CCKs) -- display
// DMA on real hardware is periodic, which is exactly what keeps the
// observed corruption byte-stable from run to run
reg        dma_act = 1;      // active low into chipDMA
reg [23:1] dma_addr = 23'h10000;
always @(posedge clk113) begin
	if (div == 4'd15) begin
		dma_act  <= ~dma_act;
		dma_addr <= dma_addr + 1'd1;
	end
end

//---------------------------------------------------------------------------
// SDRAM controller (113MHz)
//---------------------------------------------------------------------------

wire [12:0] sd_addr;
wire  [1:0] sd_ba;
wire        sd_we, sd_ras, sd_cas;
wire  [1:0] sd_dqm;
wire [15:0] sd_data;
wire        sd_clk;

// Direct walker-port exercise against the REAL controller and SDRAM
// model: the MMU table-walk path (32-bit reads, dual-CAS 32-bit writes)
// has no other bench through sdram_ctrl.  Level-held request semantics
// exactly like ap040_walker_cdc: req holds until ack.
// CPU-side walker path: wrapper (clk28) -> CDC -> SDRAM walker port (clk113),
// same topology as Minimig.sv. The selftest wk_* driver shares the port; it
// only runs after the program has quiesced, so a simple OR-mux suffices.
reg         wk_req = 0, wk_we = 0;
reg  [24:2] wk_addr = 0;
reg  [31:0] wk_wdata = 0;
wire        wk_ack;
wire [31:0] wk_rdata;

// $F146 (WBERRCTL) arms a one-shot bus error on the NEXT walker descriptor
// fetch, mirroring the flat TB back-door used by the MMUSR B-bit tests.
reg  wberr_arm = 0;
reg  wberr_fire = 0;
reg  mw_req_d = 0;
always @(posedge clk113) begin
	wberr_fire <= 0;
	mw_req_d <= mw_req;
	if (mw_req && !mw_req_d && wberr_arm) begin
		wberr_fire <= 1;
		wberr_arm <= 0;
	end
end

ap040_walker_cdc walker_cdc
(
	.s_clk     (clk28),
	.s_reset_n (reset),
	.s_req     (cw_req),
	.s_we      (cw_we),
	.s_addr    (cw_addr),
	.s_wdata   (cw_wdat),
	.s_ddr     (cw_ddr),
	.s_bad     (cw_bad),
	.s_ack     (cw_ack),
	.s_rdata   (cw_rdata),
	.s_berr    (cw_berr),

	.m_clk     (clk113),
	.m_reset_n (reset),
	.m_req     (mw_req),
	.m_we      (mw_we),
	.m_addr    (mw_addr),
	.m_wdata   (mw_wdata),
	.m_ddr     (mw_ddr),
	.m_ack     (wk_ack & ~wberr_arm & ~wberr_fire),
	.m_rdata   (wk_rdata),
	.m_berr    (wberr_fire)
);


sdram_ctrl #(.CPU_CACHE(CPU_CACHE)) ram
(
	.sysclk(clk113),
	.c_7m(c_7m),
	.reset_n(reset),
	.cache_rst(reset),
	.cache_inhibit(cache_inhibit),
	// cputest runs under AmigaOS with CACR=80008000: BOTH external
	// caches enabled.  Every prior sim run left them off (the test
	// programs never set CACR), so the HIT paths were never exercised.
	.cpu_cache_ctrl((cpu_cacr | 4'b0011) ^ {cinv_tgl, 3'b000}),

	.sd_addr(sd_addr),
	.sd_ba(sd_ba),
	.sd_cs(),
	.sd_we(sd_we),
	.sd_ras(sd_ras),
	.sd_cas(sd_cas),
	.sd_dqm(sd_dqm),
	.sd_data(sd_data),
	.sd_clk(sd_clk),
	.sd_cke(),

	.chipAddr(dma_addr),
	.chipL(1'b1),
	.chipU(1'b1),
	.chipRW(1'b1),
	.chipDMA(dma_act),
	.chipWR(16'd0),
	.chipRD(),
	.chip48(),

	.cpuAddr(ramaddr[24:1]),
	.cpuCS(ctrl_cs),
	.cpustate(cpu_state),
	.cpuL(ramlds),
	.cpuU(ramuds),
	.cpuWR(ramdin),
	.cpuRD(ctrl_rd),
	.ramready(ctrl_ready),

	.walker_req(wk_req | (mw_req & ~wberr_arm & ~wberr_fire)),
	.walker_we(wk_req ? wk_we : mw_we),
	.walker_addr(wk_req ? wk_addr : mw_addr[24:2]),
	.walker_wdata(wk_req ? wk_wdata : mw_wdata),
	.walker_ack(wk_ack),
	.walker_rdata(wk_rdata)
);

//---------------------------------------------------------------------------
// DDR3 controller (113MHz): the REAL ddram_ctrl with its own cpu_cache_new,
// serving instruction fetches in a Z3-style window (bit 26 set).
//---------------------------------------------------------------------------

wire [28:1] ddr_cpuAddr = {4'b0100, ramaddr[24:1]};

wire        DDRAM_BUSY;
wire  [7:0] DDRAM_BURSTCNT;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DOUT;
wire        DDRAM_DOUT_READY;
wire        DDRAM_RD;
wire [63:0] DDRAM_DIN;
wire  [7:0] DDRAM_BE;
wire        DDRAM_WE;

ddram_ctrl #(.CPU_CACHE(CPU_CACHE)) ram2
(
	.sysclk(clk113),
	.reset_n(reset),
	.cache_rst(reset),
	.cache_inhibit(cache_inhibit),
	.cpu_cache_ctrl((cpu_cacr | 4'b0011) ^ {cinv_tgl, 3'b000}),

	.DDRAM_CLK(),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),

	.mem2_address(29'd0),
	.mem2_burstcount(8'd1),
	.mem2_read(1'b0),
	.mem2_readdata(),
	.mem2_readdatavalid(),
	.mem2_writedata(64'd0),
	.mem2_byteenable(8'd0),
	.mem2_write(1'b0),
	.mem2_waitrequest(),

	.cpuAddr(ddr_cpuAddr),
	.cpuCS(ddr_cs),
	.cpustate(cpu_state),
	.cpuL(ramlds),
	.cpuU(ramuds),
	.cpuWR(ramdin),
	.cpuRD(ddr_rd),
	.ramshared(1'b0),
	.ramready(ddr_ready),

	.walker_req(1'b0),
	.walker_we(1'b0),
	.walker_addr(27'd0),
	.walker_wdata(32'd0),
	.walker_ack(),
	.walker_rdata()
);

// Behavioral DDR3/HPS Avalon slave and fetch-path truth monitor live
// below the program-image declaration.





always @(posedge clk113)
	cyc <= (div[1:0] == CYC_PHASE[1:0]);



// Instantiate the same guard used by Minimig.sv.  CYC=1/CPU=0 is one of
// the valid relative phases that deadlocks with the old one-cycle CS kill.
ram_cs_guard ram_guard (
	.clk(clk113), .nreset(reset), .cpu_type(1'b1),
	.ram_consumed(ram_consumed),
	.ram_sel(ramsel), .ram_ready(ramready_mux), .ram_cs(ram_cs)
);

//---------------------------------------------------------------------------
// Behavioral SDR SDRAM: 64KB window, CL2, read burst 4, write burst single
// (mode word A9=1), auto-precharge ignored.  RD_DELAY calibrates command-
// to-first-data in clk113 cycles (CL2 nominal: data 2 cycles after READ).
//---------------------------------------------------------------------------

parameter RD_DELAY = 0;

integer errors = 0;
integer result = 0;
reg [15:0] failcode = 0;



reg [15:0] mem [0:32767];

//---------------------------------------------------------------------------
// Behavioral DDR3/HPS Avalon slave: single-beat bursts (ddram_ctrl issues
// burstcount 1), long VARIABLE read latency (10..41 cycles, deterministic
// pattern) plus periodic busy stretches, backed by the same program image.
// 64-bit word: 16-bit word k of a block sits at bits [16k +:16].
//---------------------------------------------------------------------------

reg  [4:0] dbz = 0;
always @(posedge clk113) dbz <= dbz + 1'd1;
assign DDRAM_BUSY = (dbz[4:2] == 3'b101);   // 4-cycle stall every 32

reg        dpend = 0;
reg [12:0] didx = 0;
reg  [5:0] dlat = 0;
reg  [5:0] dcnt = 0;

// ddram_ctrl samples ram_dout_ready only while ~ram_busy; the HPS bridge
// never presents data during a busy cycle, so the model's valid strobe is
// gated by the LIVE busy signal and the response is held until it lands.
assign DDRAM_DOUT_READY = dpend && (dlat == 0) && !DDRAM_BUSY;
assign DDRAM_DOUT = {mem[{didx, 2'd3}], mem[{didx, 2'd2}],
                     mem[{didx, 2'd1}], mem[{didx, 2'd0}]};

always @(posedge clk113) begin
	if (!reset) begin
		dpend <= 0;
		dcnt  <= 0;
	end
	else if (DDRAM_RD && !DDRAM_BUSY && !dpend) begin
		dpend <= 1;
		didx  <= DDRAM_ADDR[12:0];
		dlat  <= 6'd10 + ((dcnt * 7 + 3) & 6'd31);
		dcnt  <= dcnt + 1'd1;
	end
	else if (dpend) begin
		if (dlat != 0) dlat <= dlat - 1'd1;
		else if (DDRAM_DOUT_READY) dpend <= 0;
	end
	if (DDRAM_WE && !DDRAM_BUSY) begin
		if (DDRAM_BE[1]) mem[{DDRAM_ADDR[12:0], 2'd0}][15:8] <= DDRAM_DIN[15:8];
		if (DDRAM_BE[0]) mem[{DDRAM_ADDR[12:0], 2'd0}][7:0]  <= DDRAM_DIN[7:0];
		if (DDRAM_BE[3]) mem[{DDRAM_ADDR[12:0], 2'd1}][15:8] <= DDRAM_DIN[31:24];
		if (DDRAM_BE[2]) mem[{DDRAM_ADDR[12:0], 2'd1}][7:0]  <= DDRAM_DIN[23:16];
		if (DDRAM_BE[5]) mem[{DDRAM_ADDR[12:0], 2'd2}][15:8] <= DDRAM_DIN[47:40];
		if (DDRAM_BE[4]) mem[{DDRAM_ADDR[12:0], 2'd2}][7:0]  <= DDRAM_DIN[39:32];
		if (DDRAM_BE[7]) mem[{DDRAM_ADDR[12:0], 2'd3}][15:8] <= DDRAM_DIN[63:56];
		if (DDRAM_BE[6]) mem[{DDRAM_ADDR[12:0], 2'd3}][7:0]  <= DDRAM_DIN[55:48];
	end
end

// +bustrace=<start>,<end>: per-cycle dump of the routing layer, used to
// localize handshake wedges between the two controllers
integer bt_lo = 0, bt_hi = 0;
initial begin
	void'($value$plusargs("bt_lo=%d", bt_lo));
	void'($value$plusargs("bt_hi=%d", bt_hi));
end
always @(posedge clk113) begin
	if (bt_hi != 0 && $time > bt_lo && $time < bt_hi) begin
		$display("BT t=%0t cst=%b sel=%b rsel=%b rcs=%b ccs=%b dcs=%b crdy=%b drdy=%b adr=%h d2st=%0d creq2=%b rd2=%b busy2=%b pend=%b lat=%0d",
		         $time, cpu_state, sel_ddr, ramsel, ram_cs, ctrl_cs, ddr_cs,
		         ctrl_ready, ddr_ready, {ramaddr, 1'b0},
		         ram2.cpu_cache.cpu_sm_state, ram2.cache_req,
		         DDRAM_RD, DDRAM_BUSY, dpend, dlat);
	end
end

// +gt trace: guard/strobe registers only (glitch-free views, clk113)
always @(negedge clk113) begin
	if (bt_hi != 0 && $time > bt_lo && $time < bt_hi &&
	    $test$plusargs("gt")) begin
		$display("GT t=%0t rsel=%b rrdy=%b rcs=%b cons=%b consq=%b killed=%b",
		         $time, ramsel, ramready_mux, ram_cs, ram_consumed,
		         ram_guard.consumed_q, ram_guard.ram_killed);
	end
end

// +ct trace: core/adapter handshake at the same window (clk28 domain)
always @(posedge clk28) begin
	if (bt_hi != 0 && $time > bt_lo && $time < bt_hi &&
	    $test$plusargs("ct")) begin
		$display("CT t=%0t st=%0d bstate=%b act=%b mack=%b creq=%b mmreq=%b breq=%b wst=%0d wact=%b lw=%b a=%h clkena=%b rdy=%b din=%h",
		         $time, cpu.cpu_inst_p.core.state,
		         cpu.cpu_inst_p.busstate, cpu.cpu_inst_p.bus16.active,
		         cpu.cpu_inst_p.bus16.mem_ack, cpu.cpu_inst_p.mem_req,
		         cpu.cpu_inst_p.mm_req, cpu.cpu_inst_p.b_req,
		         cpu.cpu_inst_p.mmu.wst, cpu.cpu_inst_p.mmu.w_active,
		         cpu.cpu_inst_p.longword, cpu.cpu_inst_p.addr_out,
		         cpu.cpu_inst_p.clkena_in, ramready_mux, cpuRD_mux);
	end
end

// truth monitor for the fetch path: every acknowledged instruction read
// through ddram_ctrl must match the program image
integer idbg = 0;
always @(posedge clk113) begin
	if (ram2.cpu_cache.cpu_ack && sel_ddr && idbg < 24 &&
	    (cpu_state == 2'b00 || cpu_state == 2'b10)) begin
		if (ram2.cpuRD !== mem[ramaddr[15:1]]) begin
			$display("STALE-I t=%0t adr=%h ddr=%h mem=%h", $time,
			         {ramaddr, 1'b0}, ram2.cpuRD, mem[ramaddr[15:1]]);
			idbg = idbg + 1;
			errors = errors + 1;
		end
	end
end

assign is_fetch   = (cpu_state == 2'b00);

// +datasplit: route DATA by address as the real machine does -- cputest's
// low memory (vectors, the ([0]) pointer, odd operands) is CHIP RAM behind
// sdram_ctrl while its code, stack, register images and exception frames
// live in Z3 behind ddram_ctrl.  For the t_fpu image the chip window is
// the vector page and the $3600-$37FF data scratch (operand + pointers);
// everything else -- including the supervisor stack at $3400 and the
// harness-replica register images -- crosses to the DDR side.
reg datasplit = 0;
initial if ($test$plusargs("datasplit")) datasplit = 1;
wire data_chip = (ramaddr[15:1] < (16'h0400 >> 1)) ||
                 ((ramaddr[15:1] >= (16'h3600 >> 1)) &&
                  (ramaddr[15:1] <  (16'h3800 >> 1))) ||
                 (ramaddr[15:1] >= (16'hF000 >> 1)); // TB control ports
wire want_ddr = is_fetch || (datasplit && !data_chip);

// zram_sel analogue: flips with the request, holds its last value while
// the bus is idle (Minimig.sv's zram_sel follows the registered address,
// which only changes when the next request begins).
reg sel_q = 0;
always @(posedge clk113) if (ramsel) sel_q <= want_ddr;
assign sel_ddr = ramsel ? want_ddr : sel_q;

// Minimig.sv:    .cpuCS (~zram_sel&ram_cs) / (zram_sel&ram_cs)
//                ram_dout/ram_ready muxed combinationally by zram_sel
assign ctrl_cs      = ram_cs && !sel_ddr;
assign ddr_cs       = ram_cs && sel_ddr;
assign cpuRD_mux    = sel_ddr ? ddr_rd    : ctrl_rd;
assign ramready_mux = sel_ddr ? ddr_ready : ctrl_ready;

// Write-path FSM tracer: state/cs/we/adr through the missing-update window
integer wt = 0;
reg [3:0] pst = 0;
always @(posedge clk113) begin
	if ($time > 1838200 && $time < 1846500 && wt < 80) begin
		if (ram.cpu_cache.cpu_sm_state != pst ||
		    (ram.cpu_cache.cpu_cs && ram.cpu_cache.cpu_we)) begin
			$display("WT t=%0t st=%0d cs=%b we=%b adr=%h wdat=%h wena=%b",
			         $time, ram.cpu_cache.cpu_sm_state,
			         ram.cpu_cache.cpu_cs, ram.cpu_cache.cpu_we,
			         {ram.cpu_cache.cpu_adr[15:1],1'b0}, ram.cpuWR, ram.write_ena);
			wt = wt + 1;
		end
	end
	pst <= ram.cpu_cache.cpu_sm_state;
	if ($time > 1838200 && $time < 1846500 && ram.cpu_cache.dtram_cpu_we)
		$display("WT t=%0t DTAGWR set=%h dat=%h", $time,
		         ram.cpu_cache.dtram_cpu_adr, ram.cpu_cache.dtram_cpu_dat_w[39:36]);
end

// One-shot fill-beat tracer: sdram state vs bus data vs sdata_reg vs
// sdata_reg_q vs cache_fill for the first CPU_READCACHE slot after 1.8M
integer ftr = 0;
always @(posedge clk113) begin
	if ($time > 1830000 && ftr < 20 && ram.slot_type == 3'd2) begin
		$display("FT t=%0t st=%0d sd=%h reg=%h q=%h fill=%b",
		         $time, ram.sdram_state, sd_data, ram.sdata_reg,
		         ram.sdata_reg_q, ram.cache_fill);
		ftr = ftr + 1;
	end
end

// $0AA8-line lifecycle (ddram words 554-557, both ways)
integer lc2 = 0;
always @(posedge clk113) begin
	if (lc2 < 30) begin
		if (ram.cpu_cache.ddram0_cpu_we && ram.cpu_cache.ddram0_cpu_adr[9:2] == 8'h55) begin
			$display("L2 t=%0t D0WR adr=%h bs=%b dat=%h fill=%b",
			         $time, ram.cpu_cache.ddram0_cpu_adr, ram.cpu_cache.ddram0_cpu_bs,
			         ram.cpu_cache.ddram0_cpu_dat_w, ram.cpu_cache.fill);
			lc2 = lc2 + 1;
		end
		if (ram.cpu_cache.ddram1_cpu_we && ram.cpu_cache.ddram1_cpu_adr[9:2] == 8'h55) begin
			$display("L2 t=%0t D1WR adr=%h bs=%b dat=%h fill=%b",
			         $time, ram.cpu_cache.ddram1_cpu_adr, ram.cpu_cache.ddram1_cpu_bs,
			         ram.cpu_cache.ddram1_cpu_dat_w, ram.cpu_cache.fill);
			lc2 = lc2 + 1;
		end
	end
end

// Lifecycle monitor for the cell behind the stale hit ($33F8/$33FC:
// ddram word indices 1FC/1FE, plus its tag set writes)
integer lc = 0;
always @(posedge clk113) begin
	if (lc < 40) begin
		if (ram.cpu_cache.ddram1_cpu_we &&
		    (ram.cpu_cache.ddram1_cpu_adr[9:1] == 9'h0FE ||
		     ram.cpu_cache.ddram1_cpu_adr == 10'h1FC || ram.cpu_cache.ddram1_cpu_adr == 10'h1FE)) begin
			$display("LC t=%0t D1WR adr=%h bs=%b dat=%h fill=%b",
			         $time, ram.cpu_cache.ddram1_cpu_adr,
			         ram.cpu_cache.ddram1_cpu_bs,
			         ram.cpu_cache.ddram1_cpu_dat_w, ram.cpu_cache.fill);
			lc = lc + 1;
		end
		if (ram.cpu_cache.ddram1_sdr_we &&
		    (ram.cpu_cache.ddram1_sdr_adr == 10'h1FC || ram.cpu_cache.ddram1_sdr_adr == 10'h1FE)) begin
			$display("LC t=%0t D1SNOOP adr=%h dat=%h",
			         $time, ram.cpu_cache.ddram1_sdr_adr,
			         ram.cpu_cache.ddram1_sdr_dat_w);
			lc = lc + 1;
		end
	end
end

// Cache truth monitor: on every acknowledged CPU read, compare the data
// the cache returned against the SDRAM model's actual memory.  A
// mismatch with dtag hit flags set = a stale hit.
integer cdbg = 0;
reg [15:0] true_w;
always @(posedge clk113) begin
	if (ram.cpu_cache.cpu_ack && cpu_state == 2'b10 && cdbg < 24) begin
		true_w = mem[ramaddr[15:1]];
		if (!sel_ddr && ram.cpuRD !== true_w) begin
			$display("STALE t=%0t adr=%h cache=%h mem=%h state=%0d i0=%b i1=%b d0=%b d1=%b",
			         $time, {ramaddr,1'b0}, ram.cpuRD, true_w,
			         ram.cpu_cache.cpu_sm_state,
			         ram.cpu_cache.itag0_match, ram.cpu_cache.itag1_match,
			         ram.cpu_cache.dtag0_match, ram.cpu_cache.dtag1_match);
			cdbg = cdbg + 1;
			errors = errors + 1;   // stale cache data fails the run
		end
	end
end

task walker_xfer;
	input        we;
	input [24:2] a;
	input [31:0] d;
	begin
		@(posedge clk113);
		wk_we    <= we;
		wk_addr  <= a;
		wk_wdata <= d;
		wk_req   <= 1;
		@(posedge wk_ack);
		@(posedge clk113);
		wk_req   <= 0;
		repeat (4) @(posedge clk113);
	end
endtask

integer wk_errors;
reg [31:0] wk_got;

`ifdef AP040_TURBO_CACHE_STORAGE
task walker_selftest;
	begin
		wk_errors = 0;
		// Keep the periodic maintenance toggle away from the direct cache
		// setup below.  The program has quiesced, so this only makes the
		// selftest's cache residency deterministic.
		cinv_cnt = 15'd1;
		repeat (8) @(posedge clk113);

		// Install the same descriptor in way 0 of both cache views.  The
		// walker bypasses cpu_cache_new, so its writeback snoops must update
		// both 16-bit halves in both I and D caches.
		ram.cpu_cache.g_storage.itram.mem[8'h80] = (40'h1 << 38) | 18'h00003;
		ram.cpu_cache.g_storage.dtram.mem[8'h80] = (40'h1 << 38) | 18'h00003;
		ram.cpu_cache.g_storage.idram0.ram_u.mem[10'h200] = 8'h00;
		ram.cpu_cache.g_storage.idram0.ram_l.mem[10'h200] = 8'h00;
		ram.cpu_cache.g_storage.idram0.ram_u.mem[10'h201] = 8'h00;
		ram.cpu_cache.g_storage.idram0.ram_l.mem[10'h201] = 8'h01;
		ram.cpu_cache.g_storage.ddram0.ram_u.mem[10'h200] = 8'h00;
		ram.cpu_cache.g_storage.ddram0.ram_l.mem[10'h200] = 8'h00;
		ram.cpu_cache.g_storage.ddram0.ram_u.mem[10'h201] = 8'h00;
		ram.cpu_cache.g_storage.ddram0.ram_l.mem[10'h201] = 8'h01;

		// 32-bit write: BOTH halves must land (the SDRAM mode word sets
		// write-burst-single, so the low word needs its own CAS command),
		// and the cache snoop must preserve that same longword. walker_addr
		// is a LONGWORD address: word index = addr << 1.
		walker_xfer(1, 23'h0700, 32'h12340019);
		if (mem[15'h0E00] !== 16'h1234) begin
			$display("FAIL: walker write high word: %h", mem[15'h0E00]);
			wk_errors = wk_errors + 1;
		end
		if (mem[15'h0E01] !== 16'h0019) begin
			$display("FAIL: walker write low word: %h", mem[15'h0E01]);
			wk_errors = wk_errors + 1;
		end
		if ({ram.cpu_cache.g_storage.idram0.ram_u.mem[10'h200],
		     ram.cpu_cache.g_storage.idram0.ram_l.mem[10'h200],
		     ram.cpu_cache.g_storage.idram0.ram_u.mem[10'h201],
		     ram.cpu_cache.g_storage.idram0.ram_l.mem[10'h201]} !== 32'h12340019) begin
			$display("FAIL: SDRAM walker I-cache snoop: %h%h%h%h",
			         ram.cpu_cache.g_storage.idram0.ram_u.mem[10'h200],
			         ram.cpu_cache.g_storage.idram0.ram_l.mem[10'h200],
			         ram.cpu_cache.g_storage.idram0.ram_u.mem[10'h201],
			         ram.cpu_cache.g_storage.idram0.ram_l.mem[10'h201]);
			wk_errors = wk_errors + 1;
		end
		if ({ram.cpu_cache.g_storage.ddram0.ram_u.mem[10'h200],
		     ram.cpu_cache.g_storage.ddram0.ram_l.mem[10'h200],
		     ram.cpu_cache.g_storage.ddram0.ram_u.mem[10'h201],
		     ram.cpu_cache.g_storage.ddram0.ram_l.mem[10'h201]} !== 32'h12340019) begin
			$display("FAIL: SDRAM walker D-cache snoop: %h%h%h%h",
			         ram.cpu_cache.g_storage.ddram0.ram_u.mem[10'h200],
			         ram.cpu_cache.g_storage.ddram0.ram_l.mem[10'h200],
			         ram.cpu_cache.g_storage.ddram0.ram_u.mem[10'h201],
			         ram.cpu_cache.g_storage.ddram0.ram_l.mem[10'h201]);
			wk_errors = wk_errors + 1;
		end

		// 32-bit read of known memory
		mem[15'h0F00] = 16'hDEAD;
		mem[15'h0F01] = 16'hBEEF;
		walker_xfer(0, 23'h0780, 32'h0);
		wk_got = wk_rdata;
		if (wk_got !== 32'hDEADBEEF) begin
			$display("FAIL: walker read: %h", wk_got);
			wk_errors = wk_errors + 1;
		end

		// read-back of the earlier write through the walker path
		walker_xfer(0, 23'h0700, 32'h0);
		wk_got = wk_rdata;
		if (wk_got !== 32'h12340019) begin
			$display("FAIL: walker readback: %h", wk_got);
			wk_errors = wk_errors + 1;
		end

		if (wk_errors == 0) $display("walker port selftest passed");
		else                errors = errors + wk_errors;
	end
endtask
`else
task walker_selftest;
	begin
		// no-storage configuration has no cache RAM hierarchy to poke
	end
endtask
`endif

reg [12:0] row [0:3];
reg  [2:0] pre_busy [0:3];   // auto-precharge busy countdown per bank
integer    ap_viol = 0;
reg [15:0] rd_pipe_dat [0:15];
reg        rd_pipe_en  [0:15];
reg  [3:0] wr_head = 0;
integer k;

wire [1:0]  c_ba   = sd_ba;
wire [24:1] rd_lin_base = {c_ba, row[c_ba], sd_addr[8:0]};

reg [15:0] sd_q = 0;
reg        sd_q_en = 0;
assign sd_data = sd_q_en ? sd_q : 16'hZZZZ;

wire [2:0] slot_typ_dbg = ram.slot_type;
// interrupt injection, mirroring tb_ap040_program: $F110 sets the level
// directly (0 releases), $F148 arms a delayed level-2 rise counted in
// clk113 cycles
always @(posedge clk113) begin
	if (ipl_delay != 0) begin
		ipl_delay <= ipl_delay - 1'd1;
		if (ipl_delay == 16'd1) ipl_lvl <= 3'd2;
	end
	if (ipl_set_w) ipl_lvl <= ipl_set_v;
	if (ipl_arm_w) ipl_delay <= ipl_arm_v;
	// auto-release at interrupt acceptance: the handler's $F110 release
	// write drains through the write buffer, so holding the level until
	// it lands could re-enter the handler after RTE
	if (ipl_lvl != 0 && cpu.cpu_inst_p.core.state == 8'd34 &&
	    cpu.cpu_inst_p.core.exc_is_irq)
		ipl_lvl <= 0;
end

reg sdclk_q = 0;
wire chip_tick = sd_clk && !sdclk_q;   // the chip's own clock edge

always @(posedge clk113) begin
	sdclk_q <= sd_clk;
	ipl_set_w <= 0;
	ipl_arm_w <= 0;
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

	if (!sd_ras && sd_cas && sd_we) begin
		// ACTIVE
		row[sd_ba] <= sd_addr;
	end
	else if (sd_ras && !sd_cas && sd_we) begin : do_read
		// READ, burst of 4 sequential
		reg [24:1] lin;
		lin = rd_lin_base;
		if (($time > 1830000 && $time < 1846000) || ($time > 27100000 && $time < 27240000))
			$display("RD t=%0t lin=%h (byte %h) words=%h %h %h %h slot=%0d",
			         $time, lin, {lin,1'b0}, mem[lin[15:1]], mem[lin[15:1]+1],
			         mem[lin[15:1]+2], mem[lin[15:1]+3], slot_typ_dbg);
		for (k = 0; k < 4; k = k + 1) begin
			// sequential burst-4 WRAPS within the aligned 4-word block
			// (the cache fills critical-word-first and relies on it)
			rd_pipe_dat[RD_DELAY + k] <=
				mem[{lin[15:3], lin[2:1] + k[1:0]}];
			rd_pipe_en[RD_DELAY + k]  <= 1'b1;
		end
	end
	else if (sd_ras && !sd_cas && !sd_we) begin : do_write
		// WRITE, single beat (mode A9=1), data and dqm with the command
		reg [24:1] lin;
		lin = rd_lin_base;
		if (pre_busy[sd_ba] != 0) begin
			$display("SDRAM MODEL: WRITE to precharging bank %0d IGNORED", sd_ba);
			ap_viol = ap_viol + 1;
			disable do_write;
		end
		if (sd_addr[10]) pre_busy[sd_ba] <= 3'd4; // auto-precharge after tWR
		if (!sd_dqm[1]) mem[lin[15:1]][15:8] <= sd_data[15:8];
		if (!sd_dqm[0]) mem[lin[15:1]][7:0]  <= sd_data[7:0];

		if (lin[15:1] == (16'hF100 >> 1))
			failcode <= sd_data;
		if (lin[15:1] == (16'hF110 >> 1)) begin
			ipl_set_w <= 1;
			ipl_set_v <= sd_data[2:0];
		end
		if (lin[15:1] == (16'hF148 >> 1)) begin
			ipl_arm_w <= 1;
			ipl_arm_v <= sd_data;
		end
		if (lin[15:1] == (16'hF146 >> 1))
			wberr_arm <= 1;
		if (lin[15:1] == (16'hF102 >> 1) && sd_dqm == 2'b00) begin
			if (sd_data == 16'h600D) result <= 1;
			else begin
				errors <= errors + 1;
				result <= 2;
			end
		end
	end
	end
end

//---------------------------------------------------------------------------
// driver
//---------------------------------------------------------------------------

reg [1023:0] prog_file;
integer i;
integer timeout;

initial begin
	if (!$value$plusargs("prog=%s", prog_file)) begin
		$display("FAIL: missing +prog=<hexfile>");
		$finish;
	end
	$display("tb_dualram_turbo: running %0s through sdram_ctrl + ddram_ctrl", prog_file);

	for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
	$readmemh(prog_file, mem);
	// interrupt delivery needs the chip stage machine to see the ph2
	// pulse: only the real-hardware alignment (CPU_PHASE 3) does; at
	// other phases the capability word stays 0 and t_fpu skips its soak
	mem[16'hF160 >> 1] = (CPU_PHASE[1:0] == 2'd3) ? 16'h0001 : 16'h0000;
	for (i = 0; i < 16; i = i + 1) begin
		rd_pipe_dat[i] = 0;
		rd_pipe_en[i] = 0;
	end
	row[0] = 0; row[1] = 0; row[2] = 0; row[3] = 0;
	pre_busy[0] = 0; pre_busy[1] = 0; pre_busy[2] = 0; pre_busy[3] = 0;

	reset = 0;
	repeat (400) @(posedge clk113);
	reset = 1;

	timeout = 0;
	while (result == 0 && timeout < 2000000) begin
		@(posedge clk113);
		timeout = timeout + 1;
		if (timeout % 500000 == 0)
			$display("progress: %0d cycles", timeout);
	end

	if (result == 1)
		walker_selftest();

	if (result == 0) begin
		errors = errors + 1;
		$display("FAIL: timeout after %0d cycles", timeout);
		$display("  final: state=%0d pc=%08x sr=%04x d7=%04x", cpu.cpu_inst_p.core.state,
			cpu.cpu_inst_p.core.pc, cpu.cpu_inst_p.core.sr,
			cpu.cpu_inst_p.core.regfile.dreg[7][15:0]);
		for (kk = 0; kk < 64; kk = kk + 1)
			$display("  ring[%0d] t=%0d pc=%08x", kk,
				pc_time[(pc_rp + kk) & 63], pc_ring[(pc_rp + kk) & 63]);
	end
	else if (result == 2)
		$display("FAIL: program reports failure, test %0d", failcode);
	else
		$display("turbo-path run passed (%0d cycles)", timeout);

	if (ap_viol != 0) begin
		errors = errors + ap_viol;
		$display("FAIL: %0d auto-precharge protocol violations", ap_viol);
	end
	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
