// Parameter names match the hardware primitive's generics (rtl/bram.vhd)
// so cpu_cache_new can bind rdw_mode_a BY NAME and elaborate identically
// against Quartus and against this model.  CPU regressions do not access
// Akiko's battery-backed NVRAM; its MIF contents are not modeled.
module dpram #(parameter addr_width = 8, parameter data_width = 8,
               parameter mem_init_file = "",
               parameter rdw_mode_a = "NEW_DATA_NO_NBE_READ") (
	input clock,
	input [addr_width-1:0] address_a,
	input [data_width-1:0] data_a,
	input wren_a,
	output reg [data_width-1:0] q_a,
	input [addr_width-1:0] address_b,
	input [data_width-1:0] data_b,
	input wren_b,
	output reg [data_width-1:0] q_b
);
	reg [data_width-1:0] mem [0:(1<<addr_width)-1];
	always @(posedge clock) begin
		if (wren_a) mem[address_a] <= data_a;
		if (wren_b) mem[address_b] <= data_b;
		// Same-port read-during-write.  An instance declared DONT_CARE
		// has told synthesis it never reads what it is writing, so the
		// model returns X there: a collision the RTL claims cannot
		// happen surfaces as X in the regression instead of hiding
		// behind whichever value this model happened to pick.
		if (wren_a && rdw_mode_a == "DONT_CARE") q_a <= {data_width{1'bx}};
		else                                     q_a <= mem[address_a];
		q_b <= mem[address_b];
	end
endmodule
