// Directed MC68040 double-bus-fault tests.  Access faults during reset,
// exception processing, or RTE state loading must halt the processor rather
// than attempt to stack a second exception.
`timescale 1ns/1ps

module tb_ap040_double_fault;

reg clk = 0;
reg nreset = 0;
always #5 clk = ~clk;

wire [15:0] data_in;
wire [31:0] addr_out;
wire [15:0] data_write;
wire nwr, nuds, nlds;
wire [1:0] busstate;
wire longword, nresetout;
wire [2:0] fc;
wire debug_busy, debug_fault, debug_halted;
wire [255:0] debug_status;

reg mem_ready;
integer phase;
wire active = busstate != 2'b01;
wire berr = nreset && active &&
            ((phase == 1 && addr_out[15:0] == 16'h0000) ||
             (phase == 2 && busstate == 2'b00 && addr_out[15:0] == 16'h0300) ||
             (phase == 3 && busstate == 2'b10 && addr_out[15:0] == 16'h1000) ||
             (phase == 4 && busstate == 2'b11 && addr_out[15:0] == 16'h0ff8) ||
             (phase == 5 && busstate == 2'b10 && addr_out[15:0] == 16'h0010));
wire clkena_in = !active || mem_ready || berr;

ap040_tg68k_compat dut (
	.clk(clk), .nreset(nreset), .clkena_in(clkena_in),
	.data_in(data_in), .ipl(3'b111), .ipl_autovector(1'b1), .berr(berr),
	.addr_out(addr_out), .data_write(data_write), .nwr(nwr),
	.nuds(nuds), .nlds(nlds), .busstate(busstate), .longword(longword),
	.nresetout(nresetout), .fc(fc),
	.walker_ack(1'b0), .walker_data(32'd0), .walker_berr(1'b0),
	.cache_data(16'd0), .cache_ack(1'b0),
	.debug_busy(debug_busy), .debug_fault(debug_fault),
	.debug_halted(debug_halted), .debug_status(debug_status)
);

reg [15:0] mem [0:32767];
assign data_in = mem[addr_out[15:1]];

integer i;
integer errors = 0;
integer cycles;

always @(posedge clk) begin
	mem_ready <= 0;
	if (nreset && active && !berr && !mem_ready) mem_ready <= 1;
	if (nreset && mem_ready && busstate == 2'b11) begin
		if (!nuds) mem[addr_out[15:1]][15:8] <= data_write[15:8];
		if (!nlds) mem[addr_out[15:1]][7:0]  <= data_write[7:0];
	end
end

task init_image;
	input integer ph;
	begin
		for (i = 0; i < 32768; i = i + 1) mem[i] = 0;
		// Reset ISP=$1000, PC=$0200.
		mem[0] = 16'h0000; mem[1] = 16'h1000;
		mem[2] = 16'h0000; mem[3] = 16'h0200;
		// Illegal vector -> $0300.  Vector 2 intentionally remains zero.
		mem[8] = 16'h0000; mem[9] = 16'h0300;
		mem[16'h0200 >> 1] = (ph == 3) ? 16'h4e73 : 16'h4afc;
		phase = ph;
	end
endtask

task expect_halt;
	input integer ph;
	input [8*48-1:0] what;
	begin
		init_image(ph);
		nreset = 0;
		repeat (8) @(posedge clk);
		nreset = 1;
		cycles = 0;
		while (!debug_halted && cycles < 2000) begin
			@(posedge clk);
			cycles = cycles + 1;
		end
		if (!debug_halted || !debug_fault) begin
			errors = errors + 1;
			$display("FAIL: %0s did not enter double-fault halt (pc=%h state=%0d)",
			         what, debug_status[31:0], dut.core.state);
		end
		else $display("PASS: %0s halted in %0d cycles", what, cycles);
	end
endtask

initial begin
	mem_ready = 0;
	phase = 0;
	expect_halt(1, "reset-vector access fault");
	expect_halt(2, "first exception-handler fetch fault");
	expect_halt(3, "RTE frame-load access fault");
	expect_halt(4, "exception stack-write fault");
	expect_halt(5, "exception vector-fetch fault");

	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
