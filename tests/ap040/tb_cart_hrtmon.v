//--------------------------------------------------------------------------//
// HRTMon/AP040 level-7 acknowledge regression                              //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_cart_hrtmon;

reg         clk = 0;
reg         clk7_en = 0;
reg         cpu_rst = 1;
reg  [23:1] cpu_address_in = 0;
reg         cpu_as_n = 1;
reg         cpu_rd = 1;
reg         freeze = 0;
reg         nmi_ack_toggle = 0;

wire [15:0] cart_data_out;
wire        int7;
wire        sel_cart;
wire        ovr;

always #5 clk = ~clk;

cart dut (
	.clk(clk),
	.clk7_en(clk7_en),
	.clk7n_en(1'b0),
	.cpu_rst(cpu_rst),
	.cpu_address_in(cpu_address_in),
	._cpu_as(cpu_as_n),
	.cpu_rd(cpu_rd),
	.cpu_hwr(1'b0),
	.cpu_lwr(1'b0),
	.nmi_addr(32'h0000_007c),
	.nmi_ack_toggle(nmi_ack_toggle),
	.reg_address_in(8'd0),
	.reg_data_in(16'd0),
	.dbr(1'b0),
	.ovl(1'b0),
	.freeze(freeze),
	.cpuhlt(1'b0),
	.cart_data_out(cart_data_out),
	.int7(int7),
	.sel_cart(sel_cart),
	.ovr(ovr)
);

integer errors = 0;

task clk7_step;
	begin
		clk7_en = 1;
		@(posedge clk);
		#1;
		clk7_en = 0;
	end
endtask

task check;
	input condition;
	input [8*80-1:0] message;
	begin
		if (!condition) begin
			$display("FAIL: %0s", message);
			errors = errors + 1;
		end
	end
endtask

initial begin
	// Reset both the cartridge state and its toggle-domain sampler.
	clk7_step;
	cpu_rst = 0;
	clk7_step;

	// A Help-key edge requests level 7.
	freeze = 1;
	clk7_step;
	check(int7, "freeze did not assert level 7");
	freeze = 0;
	clk7_step;

	// AP040 accepts the interrupt while clk7_en is low.  No legacy IACK bus
	// cycle is generated: AS remains negated and the address remains zero.
	nmi_ack_toggle = ~nmi_ack_toggle;
	repeat (3) @(posedge clk);
	check(int7, "acknowledge changed cartridge state outside clk7_en");
	clk7_step;
	check(!int7, "AP040 acknowledge did not clear level 7");

	// The accepted interrupt must expose HRTMon and override vector 31 with
	// its $00A1000C entry point.
	cpu_address_in = 23'h00003e; // byte address $00007c, upper vector word
	#1;
	check(ovr, "NMI vector override was not armed");
	check(cart_data_out == 16'h00a1, "wrong upper HRTMon vector word");
	cpu_address_in = 23'h00003f; // byte address $00007e, lower vector word
	#1;
	check(ovr, "NMI vector override dropped on lower word");
	check(cart_data_out == 16'h000c, "wrong lower HRTMon vector word");

	// Stealth remains set after the one-shot vector override is consumed,
	// making the monitor's $A00000-$A7FFFF cartridge RAM visible.
	clk7_step;
	cpu_address_in = (24'hA10000 >> 1);
	#1;
	check(sel_cart, "HRTMon cartridge RAM remained hidden");

	if (errors == 0)
		$display("HRTMon cartridge regression: ALL TESTS PASSED");
	else begin
		$display("HRTMon cartridge regression: %0d failure(s)", errors);
		$fatal(1);
	end
	$finish;
end

endmodule
