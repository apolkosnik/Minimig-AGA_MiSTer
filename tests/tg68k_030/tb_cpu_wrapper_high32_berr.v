`timescale 1ns/1ps

module tb_cpu_wrapper_high32_berr;

reg clk = 1'b0;
reg reset = 1'b0;
reg ph1 = 1'b0;
reg ph2 = 1'b1;

always #5 clk = ~clk;

always @(posedge clk or negedge reset) begin
	if (!reset) begin
		ph1 <= 1'b0;
		ph2 <= 1'b1;
	end else begin
		ph1 <= ~ph1;
		ph2 <= ~ph2;
	end
end

reg  [1:0] cpucfg = 2'b10;
reg  [2:0] fastramcfg = 3'b000;
reg  [2:0] cachecfg = 3'b000;
reg        bootrom = 1'b0;

wire [23:1] chip_addr;
reg  [15:0] chip_dout = 16'h4E71;
wire [15:0] chip_din;
wire        chip_as;
wire        chip_uds;
wire        chip_lds;
wire        chip_rw;
reg         chip_dtack = 1'b1;
reg  [2:0]  chip_ipl = 3'b111;

reg  [15:0] fastchip_dout = 16'h0000;
wire        fastchip_sel;
wire        fastchip_lds;
wire        fastchip_uds;
wire        fastchip_rnw;
wire        fastchip_lw;
reg         fastchip_selack = 1'b0;
reg         fastchip_ready = 1'b0;

wire        ramsel;
wire [28:1] ramaddr;
wire [15:0] ramdin;
reg  [15:0] ramdout = 16'h4E71;
reg         ramready = 1'b0;
wire        ramlds;
wire        ramuds;
wire        ramshared;

wire        toccata_ena;
wire [7:0]  toccata_base;
wire [1:0]  cpustate;
wire [31:0] cacr;
wire [31:0] nmi_addr;

wire        cache_req;
wire [31:0] cache_addr;
reg  [15:0] cache_data = 16'h4E71;
reg         cache_ack = 1'b0;
wire        cache_burst;
wire [2:0]  cache_burst_len;
wire [28:1] cache_ramaddr;
wire [6:0]  debug_fmt_err;
wire        walker_active_out;
wire        walker_writing_out;
wire        pmmu_cache_inhibit_out;

cpu_wrapper #(.USE_68030_CACHE(1)) dut (
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

reg [15:0] chipmem [0:65535];
integer i;
wire [23:0] chip_byte_addr = {chip_addr, 1'b0};

task put_word(input [31:0] addr, input [15:0] value);
	begin
		chipmem[addr[16:1]] = value;
	end
endtask

task put_long(input [31:0] addr, input [31:0] value);
	begin
		put_word(addr, value[31:16]);
		put_word(addr + 32'd2, value[15:0]);
	end
endtask

initial begin
	for (i = 0; i < 65536; i = i + 1)
		chipmem[i] = 16'h4E71;

	put_long(32'h00000000, 32'h00001000); // SSP
	put_long(32'h00000004, 32'h00000400); // reset PC
	put_long(32'h00000008, 32'h00000500); // bus-error vector

	// MOVE.L $01000000,D0; STOP #$2700 if no bus error occurs.
	put_word(32'h00000400, 16'h2039);
	put_long(32'h00000402, 32'h01000000);
	put_word(32'h00000406, 16'h4E72);
	put_word(32'h00000408, 16'h2700);

	// Vector-2 handler: STOP #$2700. Reaching this handler is enough for this
	// wrapper-level test; RTE frame semantics are covered by kernel benches.
	put_word(32'h00000500, 16'h4E72);
	put_word(32'h00000502, 16'h2700);
end

reg [1:0] chip_resp_cnt = 2'd0;
always @(posedge clk) begin
	if (!reset) begin
		chip_dtack <= 1'b1;
		chip_resp_cnt <= 2'd0;
		chip_dout <= 16'h4E71;
	end else if (!chip_as) begin
		if (chip_resp_cnt == 2'd0) begin
			chip_dout <= chipmem[chip_byte_addr[16:1]];
			chip_resp_cnt <= 2'd1;
		end else begin
			if (!chip_rw) begin
				if (!chip_uds)
					chipmem[chip_byte_addr[16:1]][15:8] <= chip_din[15:8];
				if (!chip_lds)
					chipmem[chip_byte_addr[16:1]][7:0] <= chip_din[7:0];
			end
			chip_dtack <= 1'b0;
			chip_resp_cnt <= 2'd2;
		end
	end else begin
		chip_dtack <= 1'b1;
		chip_resp_cnt <= 2'd0;
	end
end

always @(posedge clk) begin
	cache_ack <= 1'b0;
	if (cache_req) begin
		cache_ack <= 1'b1;
		cache_data <= 16'h4E71;
	end
	ramready <= 1'b0;
	ramdout <= 16'h4E71;
end

reg saw_berr = 1'b0;
reg saw_handler = 1'b0;
reg saw_halt = 1'b0;

always @(posedge clk) begin
	if (reset) begin
		if (dut.kernel_trap_berr_p)
			saw_berr <= 1'b1;
		if (dut.cpu_halted_p)
			saw_halt <= 1'b1;
		if (dut.kernel_TG68_PC_p >= 32'h00000500 &&
		    dut.kernel_TG68_PC_p < 32'h00000510)
			saw_handler <= 1'b1;
	end
end

initial begin
	#200;
	reset = 1'b1;

	repeat (20000) @(posedge clk);

	if (saw_halt) begin
		$display("FAIL: CPU halted during high32 BERR dispatch pc=%08x bus=%08x", dut.kernel_TG68_PC_p, dut.bus_addr);
		$finish(1);
	end
	if (!saw_berr) begin
		$display("FAIL: high32 access did not assert trap_berr pc=%08x bus=%08x", dut.kernel_TG68_PC_p, dut.bus_addr);
		$finish(1);
	end
	if (!saw_handler) begin
		$display("FAIL: high32 BERR did not reach vector-2 handler pc=%08x bus=%08x", dut.kernel_TG68_PC_p, dut.bus_addr);
		$finish(1);
	end

	$display("PASS: high32 unclaimed access dispatched vector 2 without halt");
	$finish;
end

endmodule
