// pll_cpu for Verilator: the AP68060's processor clock, driven by the bench
// (sim_main.cpp) through this public register at its own frequency,
// unrelated to the Minimig clocks.  Only for the simulation.
module pll_cpu
(
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire locked
);
reg ccpu /*verilator public_flat_rw*/ = 1'b0;
assign outclk_0 = ccpu;
assign locked   = 1'b1;
endmodule
