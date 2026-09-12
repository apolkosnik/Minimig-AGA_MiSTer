// Parameter names match the hardware primitive's generics (rtl/bram.vhd)
// so cpu_cache_new can bind rdw_mode_a BY NAME and elaborate identically
// against Quartus and against this model.  CPU regressions do not access
// Akiko's battery-backed NVRAM; its MIF contents are not modeled.
module dpram #(parameter addr_width = 8, parameter data_width = 8,
               parameter mem_init_file = "",
               parameter rdw_mode_a = "NEW_DATA_NO_NBE_READ",
               // mixed-port read-during-write: what port A reads in the
               // cycle port B writes the same address.  Silicon is
               // DONT_CARE (the generated altsyncram wrapper says so:
               // READ_DURING_WRITE_MODE_MIXED_PORTS="DONT_CARE").  The
               // default keeps this model's historical old-data answer so
               // nothing already passing changes; a bench that needs the
               // silicon behaviour observable -- the snoop guard exists
               // for exactly this collision -- sets DONT_CARE and gets X.
               parameter rdw_mixed = "OLD_DATA") (
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
		else if (wren_b && address_b == address_a && rdw_mixed == "DONT_CARE")
		                                         q_a <= {data_width{1'bx}};
		else                                     q_a <= mem[address_a];
		if (wren_a && address_a == address_b && rdw_mixed == "DONT_CARE")
		                                         q_b <= {data_width{1'bx}};
		else                                     q_b <= mem[address_b];
	end
endmodule
