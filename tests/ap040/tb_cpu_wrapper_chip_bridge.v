// Full AP040 chip-bus integration test.  Unlike tb_cpu_wrapper_chip, this
// bench includes the production amiga_clk and minimig_m68k_bridge modules,
// so address registration, read-data latching, CCK arbitration and DTACK
// timing are the same logic used on the FPGA.
`timescale 1ns/1ns

module tb_cpu_wrapper_chip_bridge #(
	parameter CLK114_PHASE = 0,
	parameter DBR_MODE = 0
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

cpu_wrapper dut (
	.reset(reset), .reset_out(cpu_nrst_out),
	.clk(clk_sys), .ph1(cpu_ph1), .ph2(cpu_ph2),
	.cpucfg(2'b10), .fastramcfg(3'd0), .cachecfg(3'd0),
	.bootrom(1'b0),
	.chip_addr(chip_addr), .chip_dout(chip_to_cpu),
	.chip_din(chip_from_cpu), .chip_as(chip_as),
	.chip_uds(chip_uds), .chip_lds(chip_lds), .chip_rw(chip_rw),
	.chip_dtack(chip_dtack), .chip_ipl(3'b111),
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
assign bridge_rdata = mem[bridge_addr[15:1]];

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
	else if (result == 2)
		$display("FAIL: program reports failure, test %0d", failcode);
	else
		$display("real chip bridge run passed (%0d cycles)", timeout);

	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
