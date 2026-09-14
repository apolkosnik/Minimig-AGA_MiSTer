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
               // for exactly this collision -- sets DONT_CARE.
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
	reg [15:0] poison = 16'hACE1;
	function [data_width-1:0] rot;
		input [addr_width-1:0] a;
		integer k;
		begin
			for (k = 0; k < data_width; k = k + 1)
				rot[k] = poison[(k + a) % 16] ^ a[k % addr_width];
		end
	endfunction
	always @(posedge clock) begin
		if (wren_a) mem[address_a] <= data_a;
		if (wren_b) mem[address_b] <= data_b;
		// Read-during-write, same port and mixed port.  An instance
		// declared DONT_CARE has told synthesis it never reads what it
		// is writing, so a collision the RTL claims cannot happen must
		// not quietly return a plausible word.
		//
		// The poison is a deterministic pseudo-random word, not X.
		// This project simulates two-state, where X reads back as 0 --
		// a word a tag row can legitimately hold, so an X poison would
		// be invisible exactly where it matters.  A constant is no better: the bitwise inverse was
		// tried and both negative controls stopped failing, because
		// inverting a row's tags AND its valid bits turns a matching way
		// into a clean miss, which is safe.  DONT_CARE does not promise
		// a safe word, so the model must not supply one -- it walks an
		// LFSR instead, mixing the address in, so a guard that is
		// missing meets valid bits set and tags that sometimes match
		// rather than one shape it can be accidentally immune to.
		// Deterministic from reset, so a failing run reproduces.
		poison <= {poison[14:0], poison[15] ^ poison[13] ^ poison[12] ^ poison[10]};
		if (wren_a && rdw_mode_a == "DONT_CARE") q_a <= rot(address_a);
		else if (wren_b && address_b == address_a && rdw_mixed == "DONT_CARE")
		                                         q_a <= rot(address_a);
		else                                     q_a <= mem[address_a];
		if (wren_a && address_a == address_b && rdw_mixed == "DONT_CARE")
		                                         q_b <= rot(address_b);
		else                                     q_b <= mem[address_b];
	end
endmodule
