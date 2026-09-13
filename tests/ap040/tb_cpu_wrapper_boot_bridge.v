// Full AP040 chip-bus integration test.  Unlike tb_cpu_wrapper_chip, this
// bench includes the production amiga_clk and minimig_m68k_bridge modules,
// so address registration, read-data latching, CCK arbitration and DTACK
// timing are the same logic used on the FPGA.
`timescale 1ns/1ns

module tb_cpu_wrapper_boot_bridge #(
	parameter CLK114_PHASE = 0,
	parameter DBR_MODE = 0,
 parameter FAST_CLOCK = 1,
 parameter CORE_DIV = 4
);

reg clk_114 = 0;
reg clk_sys = 0;
reg reset = 0;

always #5 clk_114 = ~clk_114;
integer phase;
initial begin
 if (!$value$plusargs("phase=%d", phase)) phase=CLK114_PHASE;
	#(phase);
	forever #20 clk_sys = ~clk_sys;
end

wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk clocks (
	.clk_28(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
	.c1(c1), .c3(c3), .cck(cck), .eclk(eclk), .reset_n(reset)
);

// This is copied structurally from Minimig.sv: the 114-MHz phase generator
// is resynchronised to c1, including the bridge read-latch phase.
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

wire cpu_clk = FAST_CLOCK ? clk_114 : clk_sys;
cpu_wrapper #(.FAST_CLOCK(FAST_CLOCK), .CORE_DIV(CORE_DIV)) dut (
	.reset(reset), .reset_out(cpu_nrst_out),
	.clk(cpu_clk), .clk_peripheral(clk_sys), .ph1(cpu_ph1), .ph2(cpu_ph2),
	.cpucfg(3'b010), .fastramcfg(3'd0), .cachecfg(3'd0),
	.bootrom(1'b0),
 .cdtv_mode(1'b0), .cdtv_din(16'd0), .cdtv_selack(1'b0),
 .snoop_tgl(1'b0), .snoop_adr(24'd0),
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
integer dbr_mode;
initial if (!$value$plusargs("dbr=%d", dbr_mode)) dbr_mode=DBR_MODE;
wire bridge_dbr = (dbr_mode != 0) && dma_slots[0];

minimig_m68k_bridge bridge (
	.clk(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
	.c1(c1), .c3(c3), .cck(cck), .eclk(eclk),
	.vpa(bridge_addr[23:16] == 8'hBF), .dbr(bridge_dbr), .dbs(1'b1), .xbs(1'b0),
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

// A self-contained ROM with deliberately distinct reset-vector words.
// The old FAST_CLOCK chip sampler returned 0000,1114,4447,00f8 here,
// starting execution at 444700f8 instead of 00f800d6.
reg [15:0] rom [0:127];
wire [23:0] ba = {bridge_addr, 1'b0};
// The REAL CIA-A behind the bridge (as minimig.v wires it): the bridge's
// write strobes are combinational and a strobe seen at any clk_sys edge
// proves nothing -- the CIA latches only on a clk7_en edge inside the
// window where AS and DTACK are both still low.  A chip machine that
// releases AS one fast clock too early passes the strobe check and loses
// the write on silicon (DiagROM's power LED never lit, 2026-09-12).
wire       cia_aen = (bridge_addr[23:16] == 8'hBF) && !bridge_addr[12];
wire [7:0] cia_dout; wire [3:0] cia_porta;
ciaa cia (
	.clk(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .aen(cia_aen),
	.rd(bridge_rd), .wr(bridge_lwr | bridge_hwr), .reset(~reset),
	.rs(bridge_addr[11:8]), .data_in(bridge_wdata[7:0]), .data_out(cia_dout),
	.tick(1'b0), .eclk(eclk[8]), .cnt_in(1'b1), .irq(),
	.porta_in(6'b111111), .porta_out(cia_porta), .portb_in(8'hFF),
	.kms_level(1'b0), .kbd_mouse_type(2'd0), .kbd_mouse_data(8'd0),
	.freeze(), .hrtmon_en(1'b0));
assign bridge_rdata = cia_aen ? {8'h00, cia_dout} :
                     (ba < 24'h000100 ||
                     (ba >= 24'hf80000 && ba < 24'hf80100)) ? rom[ba[7:1]] : 16'd0;

integer vector_words = 0;
reg cia_ddr_seen = 0, cia_pra_seen = 0, serial_seen = 0;
always @(posedge cpu_clk) if (reset) begin
 if (dut.core_halted) $fatal(1, "CPU halted before startup completed");
 if (dut.core_enable && dut.cpu_req && vector_words < 4) begin
  if (dut.cpu_addr_p !== vector_words*2 || dut.cpu_din !== rom[vector_words])
   $fatal(1, "reset word %0d: address=%h data=%h expected=%h",
          vector_words, dut.cpu_addr_p, dut.cpu_din, rom[vector_words]);
  vector_words = vector_words + 1;
 end
end

// Observe actual downstream bridge writes, not CPU-side requests.
// CIA accesses exercise VPA/ECLK acknowledgement as on the board.
always @(posedge clk_sys) if (reset) begin
 if (bridge_lwr && ba == 24'hbfe200 && bridge_wdata[7:0] == 8'h03)
  cia_ddr_seen <= 1;
 if (bridge_lwr && ba == 24'hbfe000 && bridge_wdata[7:0] == 8'h00) begin
  if (!cia_ddr_seen) $fatal(1, "CIA PRA write preceded DDR setup");
  cia_pra_seen <= 1;
 end
 if (bridge_lwr && bridge_hwr && ba == 24'hdff030) begin
  if (!cia_pra_seen || bridge_wdata !== 16'h0141)
   $fatal(1, "incorrect startup serial write: %h", bridge_wdata);
  serial_seen <= 1;
 end
end

integer i, timeout;
initial begin
 for (i=0; i<128; i=i+1) rom[i]=16'h4e71;
 rom[0]=16'h1114; rom[1]=16'h4447;
 rom[2]=16'h00f8; rom[3]=16'h00d6;
 // move.b #3,$bfe201 ; move.b #0,$bfe001 ; move.w #$141,$dff030
 rom[107]=16'h13fc; rom[108]=16'h0003; rom[109]=16'h00bf; rom[110]=16'he201;
 rom[111]=16'h13fc; rom[112]=16'h0000; rom[113]=16'h00bf; rom[114]=16'he001;
 rom[115]=16'h33fc; rom[116]=16'h0141; rom[117]=16'h00df; rom[118]=16'hf030;
 rom[119]=16'h60fe;
 repeat (50) @(negedge clk_sys);
 reset=1;
 timeout=0;
 while (!serial_seen && timeout<50000) begin
  @(negedge clk_sys); timeout=timeout+1;
 end
 if (!serial_seen || vector_words != 4)
  $fatal(1, "startup timed out: PC=%h vectors=%0d CIA=%b%b",
         dut.cpu_inst_p.core.pc, vector_words, cia_ddr_seen, cia_pra_seen);
 // the CIA must have LATCHED DiagROM's DDR/PRA writes, not merely been strobed:
 if (cia.ddrporta[1:0] !== 2'b11) $fatal(1, "CIA-A never latched DDRA (ddrporta=%b): the write strobe missed clk7_en", cia.ddrporta);
 if (cia_porta[1] !== 1'b0) $fatal(1, "CIA-A never latched PRA: power LED still off (porta_out=%b regporta=%b)", cia_porta, cia.regporta);
 $display("ALL TESTS PASSED: boot bridge FAST_CLOCK=%0d CORE_DIV=%0d phase=%0d dbr=%0d",
          FAST_CLOCK, CORE_DIV, phase, dbr_mode);
 $finish;
end

// +trace_cia: print the chip-bus / bridge / CIA signals around the first CIA
// write, one line per clk_114 edge, to see why a write is or is not latched.
integer trace_n = 0; reg trace_on = 0; reg trace_arm = 0;
always @(posedge clk_114) begin
	if ($test$plusargs("trace_cia")) begin
		if (!trace_arm && cia_aen && !chip_rw) begin trace_arm <= 1; trace_on <= 1; end
		if (trace_on && trace_n < 900) begin
			trace_n <= trace_n + 1;
			$display("t=%0t 7en=%b 7ne=%b cck=%b e8=%b vma=%b | as=%b uds=%b lds=%b rw=%b dtack=%b | l_as=%b l_dtack=%b hwr=%b lwr=%b | ph1=%b ph2=%b cia_wr=%b ddra=%b",
				$time, clk7_en, clk7n_en, cck, eclk[8], bridge.vma, chip_as, chip_uds, chip_lds, chip_rw, chip_dtack,
				bridge.l_as, bridge.l_dtack, bridge_hwr, bridge_lwr, cpu_ph1, cpu_ph2, cia.wr, cia.ddrporta[1:0]);
		end
	end
end
endmodule
