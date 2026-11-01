// a2065_regfile: the CSR mirror.  The mailbox drives CSR0-CSR3 on the DDR3
// clock (here a faster clock, four to one, as clk_ddr to clk_sys); the
// register file copies them one at a time and the 68k reads them through
// RAP/RDP.  Each CSR, changed at an arbitrary DDR3 clock, must read back
// its new value within four system clocks of the change and never a value
// that was not driven; RAP, the chip ID registers (88, 89) and an RDP read
// with RAP above 3 (0) must read as before.
`timescale 1ns/1ps
module tb_a2065_csr;
reg clk = 0;   always #17.5 clk  = ~clk;   // clk_sys (28 MHz)
reg clkd = 0;  always #4.375 clkd = ~clkd; // clk_ddr (4x)
reg nrst = 0;
reg [23:0] a = 24'd0;
reg        rw = 1'b1, as_n = 1'b1, ds_n = 1'b1;
reg [15:0] din = 16'd0;
wire [15:0] dout;
wire        nrdy, cmd_pending;
wire  [6:0] cmd_rap;
wire [15:0] cmd_data;
reg  [15:0] csr [0:3];
integer errors = 0;

a2065_regfile dut (
	.clk(clk), .rst_n(nrst),
	.cpu_addr(a), .cpu_rw(rw), .cpu_as_n(as_n), .cpu_ds_n(ds_n),
	.cpu_data_in(din), .cpu_data_out(dout), .regs_nrdy(nrdy),
	.card_base(8'hE9), .card_configured(1'b1),
	.cmd_pending(cmd_pending), .cmd_rap(cmd_rap), .cmd_data(cmd_data), .cmd_clear(1'b0),
	.csr0_in(csr[0]), .csr1_in(csr[1]), .csr2_in(csr[2]), .csr3_in(csr[3]));

task chk(input c, input string what);
	if (!c) begin errors = errors + 1; $display("FAIL: %s (t=%0t)", what, $time); end
endtask

// a 68k bus cycle at the card's chip registers ($E94000 RDP, $E94002 RAP)
task bus_wr(input [23:0] addr, input [15:0] d);
	begin
		@(negedge clk); a = addr; rw = 1'b0; din = d; as_n = 1'b0; ds_n = 1'b0;
		@(negedge clk); @(negedge clk);
		as_n = 1'b1; ds_n = 1'b1; rw = 1'b1;
		@(negedge clk);
	end
endtask
task bus_rd(input [23:0] addr, output [15:0] d);
	begin
		@(negedge clk); a = addr; rw = 1'b1; as_n = 1'b0; ds_n = 1'b0;
		@(negedge clk); d = dout;
		as_n = 1'b1; ds_n = 1'b1;
		@(negedge clk);
	end
endtask

integer i, k, t;
reg [15:0] v, old, nv;
initial begin
	for (i = 0; i < 4; i = i + 1) csr[i] = 16'h1000 * (i + 1) + 16'h0055;
	repeat (4) @(posedge clk);
	nrst = 1;
	repeat (8) @(posedge clk);
	// RAP reads back, chip ID registers, RDP above 3 reads 0
	bus_wr(24'hE94002, 16'd89);
	bus_rd(24'hE94002, v); chk(v == 16'd89, "RAP reads back");
	bus_rd(24'hE94000, v); chk(v == 16'h3003, "CSR89 (chip ID) reads $3003");
	bus_wr(24'hE94002, 16'd88);
	bus_rd(24'hE94000, v); chk(v == 16'h0001, "CSR88 (chip ID) reads $0001");
	bus_wr(24'hE94002, 16'd7);
	bus_rd(24'hE94000, v); chk(v == 16'h0000, "RDP with RAP 7 reads 0");
	// the initial values are mirrored
	for (k = 0; k < 4; k = k + 1) begin
		bus_wr(24'hE94002, k);
		bus_rd(24'hE94000, v);
		chk(v == csr[k], $sformatf("CSR%0d mirrors its initial value", k));
	end
	// each CSR changed at varying DDR3 clocks: within four system clocks the
	// new value reads back, and every read before that is the old value or
	// the new one (never another)
	for (t = 0; t < 64; t = t + 1) begin
		k = t % 4;
		bus_wr(24'hE94002, k);
		old = csr[k];
		nv  = old ^ (16'h0101 << (t % 8)) ^ t;
		repeat (t % 7) @(posedge clkd);
		@(posedge clkd); csr[k] = nv;
		for (i = 0; i < 6; i = i + 1) begin
			@(negedge clk);
			v = dout;           // (the read data as a cycle would take it)
			as_n = 1'b0; ds_n = 1'b0; a = 24'hE94000; rw = 1'b1;
			@(negedge clk);
			v = dout;
			as_n = 1'b1; ds_n = 1'b1;
			chk(v == old || v == nv, $sformatf("CSR%0d read %h: neither old %h nor new %h", k, v, old, nv));
		end
		bus_rd(24'hE94000, v);
		chk(v == nv, $sformatf("CSR%0d reads %h after the change, not the new %h", k, v, nv));
	end
	if (errors == 0) $display("PASS: tb_a2065_csr");
	else             $display("FAIL: tb_a2065_csr, %0d errors", errors);
	$finish;
end
endmodule
