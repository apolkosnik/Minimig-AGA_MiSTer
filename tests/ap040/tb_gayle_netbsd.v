//--------------------------------------------------------------------------//
// tb_gayle_netbsd.v - replay NetBSD's wdc register sequence against the    //
// gayle.v + ide.v pair, with the mgmt (ARM) side modeled just enough to    //
// complete commands.  No CPU and no MMU are instantiated: this bench       //
// exists to decide whether the interrupt freeze seen on hardware after     //
// root mount lives in the DEVICE MODEL alone.                              //
//                                                                          //
// Sequence (from sys/arch/amiga/dev/wdc_amiga.c, netbsd-9):                //
//   cmd_iot base = $DA0002, stride 4 "swap": reg i at $DA0002 + 4*i        //
//   ctl register = subregion 0x406       -> byte $DA101A                   //
//   gayle INTENA $DAA000 MSB set at attach                                 //
//   per transfer: write SDH/regs, write CMD (reg 7), await INT2, ISR reads //
//   $DA9000 (bit7), acks $DA9000 write, wdcintr reads STATUS (reg 7)       //
//   polled ops write ctl WDCTL_IDS|4BIT ($0A) first, then clear to $08     //
//--------------------------------------------------------------------------//
`timescale 1ns/1ns

module tb_gayle_netbsd;

reg clk = 0;
always #5 clk = ~clk;

reg reset = 1;

reg  [23:1] addr = 0;
reg  [15:0] data_in = 0;
wire [15:0] data_out;
reg         rd = 0, wr = 0;
reg         sel_ide = 0;
wire        irq, nrdy;

// mgmt side (the ARM in real life)
reg   [4:0] ide_address = 0;
reg         ide_write = 0;
reg  [15:0] ide_writedata = 0;
reg         ide_read = 0;
wire  [5:0] ide_req;
wire [15:0] ide_readdata;

gayle DUT
(
	.clk(clk), .reset(reset),
	.addr(addr), .data_in(data_in), .data_out(data_out),
	.rd(rd), .wr(wr),
	.sel_ide(sel_ide), .sel_gayle(1'b0),
	.irq(irq), .nrdy(nrdy), .longword(1'b0),
	.ide_req(ide_req),
	.ide_address(ide_address), .ide_write(ide_write),
	.ide_writedata(ide_writedata), .ide_read(ide_read),
	.ide_readdata(ide_readdata),
	.led()
);

integer errors = 0;

task bus_write(input [23:0] a, input [15:0] v);
	begin
		@(posedge clk); addr <= a[23:1]; data_in <= v; sel_ide <= 1; wr <= 1;
		@(posedge clk); @(posedge clk); wr <= 0; sel_ide <= 0;
		@(posedge clk);
	end
endtask

task bus_read(input [23:0] a, output [15:0] v);
	begin
		@(posedge clk); addr <= a[23:1]; sel_ide <= 1; rd <= 1;
		@(posedge clk); @(posedge clk); v = data_out; rd <= 0; sel_ide <= 0;
		@(posedge clk);
	end
endtask

// byte write: the CPU duplicates the byte on both lanes
task byte_write(input [23:0] a, input [7:0] v);
	begin
		bus_write(a, {v, v});
	end
endtask

// mgmt: mark drive 0 present, then complete one command with an IRQ
task mgmt_present;
	begin
		@(posedge clk); ide_address <= 6; ide_writedata <= 16'h000B; ide_write <= 1;
		@(posedge clk); ide_write <= 0;
	end
endtask

task mgmt_complete;   // as the ARM does after serving a command
	begin
		@(posedge clk); ide_address <= 5; ide_writedata <= 16'h0400; ide_write <= 1;
		@(posedge clk); ide_write <= 0;
	end
endtask

reg [15:0] v;
integer pass;

initial begin
	repeat (5) @(posedge clk);
	reset = 0;
	repeat (5) @(posedge clk);
	mgmt_present;

	// --- attach: gayle_intr_enable_set(GAYLE_INT_IDE): RMW $DAA000
	bus_read(24'hDAA000, v);
	byte_write(24'hDAA000, v[15:8] | 8'h80);

	// NetBSD wdc_init_shadow_regs / attach pokes ctl (WDCTL_4BIT = $08)
	byte_write(24'hDA101A, 8'h08);

	// --- polled command (autoconf style): IDS set, command, poll, IDS clear
	byte_write(24'hDA101A, 8'h0A);           // WDCTL_IDS | WDCTL_4BIT
	byte_write(24'hDA1016, 8'hE0);           // SDH via $DA0002+4*6 = DA001A? use cmd bank reg6
	byte_write(24'hDA001A, 8'hE0);           // SDH proper (cmd bank)
	byte_write(24'hDA001E, 8'hEC);           // IDENTIFY to CMD reg (io 7)
	mgmt_complete;                           // device done; nIEN should hold irq off?
	repeat (4) @(posedge clk);
	$display("after polled IDENTIFY complete: irq=%b (real Gayle: 0 if nIEN honored, else 1)", irq);
	bus_read(24'hDA001E, v);                 // polled status read (clears any irq)
	byte_write(24'hDA101A, 8'h08);           // clear IDS
	repeat (4) @(posedge clk);
	if (irq !== 1'b0) begin errors = errors + 1; $display("FAIL: irq stuck after polled op"); end

	// --- interrupt-mode transfers, several in a row (the mount pattern)
	for (pass = 0; pass < 3; pass = pass + 1) begin
		byte_write(24'hDA001A, 8'hE0);       // SDH
		byte_write(24'hDA001E, 8'h20);       // READ SECTORS (io 7 write clears irq, arms request)
		mgmt_complete;                       // ARM served it
		repeat (4) @(posedge clk);
		if (irq !== 1'b1) begin
			errors = errors + 1;
			$display("FAIL: pass %0d: no INT2 after completion (irq=%b)", pass, irq);
		end
		// ISR: read $DA9000, ack write, wdcintr reads STATUS
		bus_read(24'hDA9000, v);
		if (!v[15]) begin errors = errors + 1; $display("FAIL: pass %0d: INTREQ not visible", pass); end
		byte_write(24'hDA9000, 8'h7C);       // gayle_intr_ack
		bus_read(24'hDA001E, v);             // STATUS read ends the request
		repeat (4) @(posedge clk);
		if (irq !== 1'b0) begin errors = errors + 1; $display("FAIL: pass %0d: irq not cleared by ISR", pass); end
	end

	if (errors == 0) $display("GAYLE NETBSD SEQUENCE PASSED");
	else             $display("GAYLE NETBSD SEQUENCE FAILED with %0d errors", errors);
	$finish;
end

endmodule
