// Full AP040 chip-bus integration test.  Unlike tb_cpu_wrapper_chip, this
// bench includes the production amiga_clk and minimig_m68k_bridge modules,
// so address registration, read-data latching, CCK arbitration and DTACK
// timing are the same logic used on the FPGA.
`timescale 1ns/1ns

module tb_cpu_wrapper_chip_bridge #(
	parameter CLK114_PHASE = 0,
	parameter DBR_MODE = 0,
	parameter CACHE_ALLOW_ALL = 0,
	parameter POST_STORES = 1
);

reg clk_114 = 0;
reg clk_sys = 0;
reg reset = 0;

always #5 clk_114 = ~clk_114;
initial begin
	#(CLK114_PHASE);
	forever #20 clk_sys = ~clk_sys;
end

wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk clocks (
	.clk_28(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
	.c1(c1), .c3(c3), .cck(cck), .eclk(eclk), .reset_n(reset)
);

// This is copied structurally from Minimig.sv: the 114-MHz phase generator
// is resynchronised to c1, while cpu_wrapper itself runs at clk_sys.
reg [3:0] div = 0;
reg c1d = 0;
reg cpu_ph1 = 0, cpu_ph2 = 0;
always @(posedge clk_114) begin
	div <= div + 1'd1;
	c1d <= c1;
	if (!c1d && c1) div <= 4'd3;
	if (!reset) begin
		cpu_ph1 <= 0;
		cpu_ph2 <= 0;
	end
	else if (div[1] && !div[0]) begin
		cpu_ph1 <= 0;
		cpu_ph2 <= 0;
		case (div[3:2])
			2'd0: cpu_ph2 <= 1;
			2'd2: cpu_ph1 <= 1;
			default: ;
		endcase
	end
end

wire [23:1] chip_addr;
wire [15:0] chip_from_cpu;
wire [15:0] chip_to_cpu;
wire chip_as, chip_uds, chip_lds, chip_rw, chip_dtack;
wire cpu_nrst_out;

cpu_wrapper #(.CACHE_ALLOW_ALL(CACHE_ALLOW_ALL), .POST_STORES(POST_STORES)) dut (
	.reset(reset), .reset_out(cpu_nrst_out),
	.clk(clk_sys), .clk_peripheral(clk_sys), .ph1(cpu_ph1), .ph2(cpu_ph2),
	.cpucfg(3'b010), .fastramcfg(3'd0), .cachecfg(3'd0),
	.bootrom(1'b0),
	.cdtv_mode(1'b0), .cdtv_din(16'd0), .cdtv_selack(1'b0),
	.snoop_tgl(1'b0), .snoop_adr(24'd0),
	.ddr_snoop_tgl(1'b0), .ddr_snoop_adr(24'd0),
	.chip_addr(chip_addr), .chip_dout(chip_to_cpu),
	.chip_din(chip_from_cpu), .chip_as(chip_as),
	.chip_uds(chip_uds), .chip_lds(chip_lds), .chip_rw(chip_rw),
	.chip_dtack(chip_dtack), .chip_ipl(~ipl_lvl),
	.fastchip_dout(16'd0), .fastchip_sel(), .fastchip_lds(),
	.fastchip_uds(), .fastchip_rnw(), .fastchip_lw(),
	.fastchip_selack(1'b0), .fastchip_ready(1'b0),
	.ramsel(), .ramaddr(), .ramdin(), .ramdout(16'd0),
	.ramready(1'b0), .ramlds(), .ramuds(), .ramshared(),
	.walker_mem_req(), .walker_mem_we(), .walker_mem_addr(),
	.walker_mem_wdat(), .walker_mem_ddr(), .walker_mem_bad(),
	.walker_mem_ack(1'b0), .walker_mem_rdata(32'd0),
	.walker_mem_berr(1'b0),
	.toccata_ena(), .toccata_base(), .a2065_ena(), .a2065_base(),
	.cpustate(), .cacr(), .cache_inhibit(), .nmi_ack_toggle(),
	.nmi_addr()
);

wire bridge_rd, bridge_hwr, bridge_lwr, bridge_rd_cyc;
wire [23:1] bridge_addr;
wire [15:0] bridge_wdata;
wire [15:0] bridge_rdata;
reg [2:0] dma_slots = 3'b001;
always @(posedge clk_sys) if (clk7_en)
	dma_slots <= {dma_slots[1:0], dma_slots[2] ^ dma_slots[0]};
wire bridge_dbr = (DBR_MODE != 0) && dma_slots[0];

minimig_m68k_bridge bridge (
	.clk(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
	.c1(c1), .c3(c3), .cck(cck), .eclk(eclk),
	.vpa(1'b0), .dbr(bridge_dbr), .dbs(1'b1), .xbs(1'b0),
	.nrdy(1'b0), .bls(), .memory_config(4'b0011),
	._as(chip_as), ._lds(chip_lds), ._uds(chip_uds), .r_w(chip_rw),
	._dtack(chip_dtack), .rd(bridge_rd), .rd_cyc(bridge_rd_cyc),
	.hwr(bridge_hwr), .lwr(bridge_lwr),
	.address(chip_addr), .address_out(bridge_addr),
	.cpudatain(chip_from_cpu), .data(chip_to_cpu),
	.data_out(bridge_wdata), .data_in(bridge_rdata),
	._cpu_reset(reset), .cpu_halt(1'b0),
	.host_cs(1'b0), .host_adr(23'd0), .host_we(1'b0),
	.host_bs(2'b00), .host_wdat(16'd0), .host_rdat(), .host_ack()
);

reg [15:0] mem [0:32767];
// The interrupt injector the program benches share (tb_ap040_program.v,
// upstream's tb_ap040_pipe_compat.v): a word written to $F110 is the level
// on the IPL lines (0 releases them); $F148 arms a level-2 request that
// rises the written number of clk_sys cycles later; $F160 reads as 1 so a
// program knows the injector is here (t_fpu.s's IPLCAP: with 0 its IRQ
// sweep across a released FDIV bypassed itself, and t_posted_irq_audit
// waited for a level that never came).  The wrapper samples IPL on its
// stage grid, so the sweep here does not reach the single-clock alignments
// of the two defects it found on upstream's bench (tb_ap040_pipe_compat.v:
// a request lost as the FDIV left P_START, a `done` dropped on an entry's
// redirect clock) -- a 160-clock sweep against either unfixed core passed
// here.  That bench is the regression for them; this one runs the sweep.
reg  [2:0] ipl_lvl = 3'd0;
reg [15:0] ipl_delay = 16'd0;
assign bridge_rdata = (bridge_addr[15:1] == (16'hF160 >> 1)) ? 16'h0001 : mem[bridge_addr[15:1]];

// The core may run during a posted store, but the adapter must hold the
// entire outstanding bus transfer until the chipset acknowledges it.
reg prev_reset = 0, prev_bus_enable = 0;
reg [67:0] prev_bus;
wire [67:0] bus_snapshot = {dut.cpu_addr_p, dut.cpu_dout_p,
                            dut.cpustate_p, dut.wr_p, dut.uds_p, dut.lds_p, 15'd0};
integer posted_progress = 0;
always @(posedge clk_sys) begin
	if (prev_reset && reset && !prev_bus_enable && bus_snapshot !== prev_bus)
		$fatal(1, "adapter advanced without a bus completion");
	prev_reset <= reset;
	prev_bus_enable <= dut.bus_enable;
	prev_bus <= bus_snapshot;
	if (reset && dut.post_drain && dut.core_enable && !dut.bus_enable) posted_progress <= posted_progress + 1;
end

integer errors = 0;
integer result = 0;
reg [15:0] failcode = 0;

always @(posedge clk_sys) begin
	if (reset) begin
		if (bridge_hwr) mem[bridge_addr[15:1]][15:8] <= bridge_wdata[15:8];
		if (bridge_lwr) mem[bridge_addr[15:1]][7:0] <= bridge_wdata[7:0];
		if ((bridge_hwr || bridge_lwr) &&
		    bridge_addr[15:1] == (16'hF100 >> 1))
			failcode <= bridge_wdata;
		if (bridge_hwr && bridge_lwr &&
		    bridge_addr[15:1] == (16'hF102 >> 1)) begin
			if (bridge_wdata == 16'h600D) result <= 1;
			else begin
				errors <= errors + 1;
				result <= 2;
			end
		end
		if ((bridge_hwr || bridge_lwr) && bridge_addr[15:1] == (16'hF110 >> 1))
			ipl_lvl <= bridge_wdata[2:0];
		if ((bridge_hwr || bridge_lwr) && bridge_addr[15:1] == (16'hF148 >> 1))
			ipl_delay <= bridge_wdata;
		else if (ipl_delay != 16'd0) begin
			ipl_delay <= ipl_delay - 16'd1;
			if (ipl_delay == 16'd1) ipl_lvl <= 3'd2;
		end
	end
end

// A qualified request is taken at the next instruction boundary.  This is
// upstream's tb_ap040_pipe_compat.v rule on the production DUT: a level above
// the mask claims the boundary; the claim ends when the level drops or an
// entry accepts it; an instruction leaving EA-fetch while the claim stands
// ages it, and sixteen starts is a LOST request (the design's measured worst
// case is six).  The window from an entry's start until its SR write lands
// is excluded: the level is still above the OLD mask there.  A program
// cannot see a request deferred to a later boundary -- it is delivered
// eventually and the count comes out right -- so this is what reports one
// on this bench's alignments.  (The known case, a level-2 rising as a
// released FDIV left P_START and starved by the addq/dbra loop behind it,
// is not among them: see the injector's note above.)
wire [15:0] core_sr      = dut.cpu_inst_p.core.sr;
wire  [2:0] core_irq_lvl = dut.cpu_inst_p.core.g_irq.irq_lvl_live;
wire  [2:0] core_exc_lvl = dut.cpu_inst_p.core.u_eaf.x_lvl;
wire        core_exc_irq = dut.cpu_inst_p.core.u_eaf.x_irq;
wire        core_in_exc  = (dut.cpu_inst_p.core.u_eaf.ph == 4'd2);   // P_EXC
wire        insn_start   = dut.cpu_inst_p.core.u_eaf.st.fin && dut.cpu_inst_p.core.ce;
reg         in_exc_q = 0, exc_sr_pend = 0;
reg  [15:0] core_sr_q = 0;
wire        exc_accept = core_in_exc && !in_exc_q;
wire        exc_window = core_in_exc || exc_sr_pend;
reg   [6:0] tb_must = 0;
reg   [7:0] must_age [1:6];
integer     irq_errors = 0;
integer     ml;
initial for (ml = 1; ml <= 6; ml = ml + 1) must_age[ml] = 0;
always @(posedge clk_sys) begin
	in_exc_q  <= core_in_exc;
	core_sr_q <= core_sr;
	if (!reset) exc_sr_pend <= 0;
	else if (core_in_exc) exc_sr_pend <= 1;
	else if (core_sr != core_sr_q) exc_sr_pend <= 0;
	if (!reset) begin
		tb_must <= 0;
		for (ml = 1; ml <= 6; ml = ml + 1) must_age[ml] <= 0;
	end else begin
		for (ml = 1; ml <= 6; ml = ml + 1) begin
			if ({29'd0, core_irq_lvl} < ml) begin
				tb_must[ml] <= 0; must_age[ml] <= 0;
			end else if (exc_accept && core_exc_irq && {29'd0, core_exc_lvl} >= ml) begin
				tb_must[ml] <= 0; must_age[ml] <= 0;
			end else if (!tb_must[ml] && !exc_window &&
			             {29'd0, core_irq_lvl} == ml && ml > {29'd0, core_sr[10:8]}) begin
				tb_must[ml] <= 1; must_age[ml] <= 0;
			end else if (tb_must[ml] && insn_start) begin
				must_age[ml] <= must_age[ml] + 1'd1;
				if (must_age[ml] == 8'd16) begin
					irq_errors = irq_errors + 1;
					$display("FAIL: qualified level-%0d request not taken at the next boundary (pc=%h sr=%h)",
					         ml, dut.core_dbgstat[31:0], core_sr);
				end
			end
		end
	end
end

reg [1023:0] prog_file;
integer i;
integer timeout;
initial begin
	if (!$value$plusargs("prog=%s", prog_file)) begin
		$display("FAIL: missing +prog=<hexfile>");
		$finish;
	end
	$display("tb_cpu_wrapper_chip_bridge: running %0s", prog_file);
	for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
	$readmemh(prog_file, mem);
	repeat (50) @(posedge clk_sys);
	reset = 1;

	timeout = 0;
	while (result == 0 && timeout < 20000000) begin
		@(posedge clk_sys);
		timeout = timeout + 1;
	end
	if (result == 0) begin
		errors = errors + 1;
		$display("FAIL: timeout after %0d cycles", timeout);
	end
	else if (result == 2) begin
		$display("FAIL: program reports failure, test %0d", failcode);
		$display("SP=%h exception stack=%h %h %h %h",
		         dut.core_dbgstat[95:64],
		         mem[dut.core_dbgstat[79:65]], mem[dut.core_dbgstat[79:65]+1],
		         mem[dut.core_dbgstat[79:65]+2], mem[dut.core_dbgstat[79:65]+3]);
	end
	else
		$display("real chip bridge run passed (%0d cycles)", timeout);

	$display("posted-store overlap cycles: %0d", posted_progress);
	if ($test$plusargs("require_overlap") && posted_progress == 0)
		$fatal(1, "posted-store overlap was never exercised");
	if (irq_errors != 0) $display("interrupt latency rule: %0d violations", irq_errors);
	if (errors + irq_errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors + irq_errors);
	$finish;
end

endmodule
