//--------------------------------------------------------------------------//
// AP030 - MC68030 compatible CPU                                           //
//                                                                          //
// ap030_l2ram.sv - the RAMs of the Fast RAM cache (ap030_fastram_fe):      //
//   ap030_l2ram_be  simple dual-port, 32 bits with byte enables            //
//   ap030_l2ram     simple dual-port, plain                                //
// One clock, registered read, written as Intel's RAM templates so they map //
// to M10K blocks.  A read of the address being written returns the old     //
// data; the user never relies on it.                                       //
//--------------------------------------------------------------------------//

module ap030_l2ram_be #(parameter AW = 9)
(
	input               clk,
	input               we,
	input      [AW-1:0] wa,
	input         [3:0] be,         // bit 3 = D31-D24
	input        [31:0] wd,
	input      [AW-1:0] ra,
	output reg   [31:0] q
);

logic [3:0][7:0] ram [0:(1<<AW)-1];

always_ff @(posedge clk) begin
	if (we) begin
		if (be[0]) ram[wa][0] <= wd[7:0];
		if (be[1]) ram[wa][1] <= wd[15:8];
		if (be[2]) ram[wa][2] <= wd[23:16];
		if (be[3]) ram[wa][3] <= wd[31:24];
	end
	q <= ram[ra];
end

endmodule

module ap030_l2ram #(parameter AW = 9, parameter DW = 20)
(
	input               clk,
	input               we,
	input      [AW-1:0] wa,
	input      [DW-1:0] wd,
	input      [AW-1:0] ra,
	output reg [DW-1:0] q
);

logic [DW-1:0] ram [0:(1<<AW)-1];

always_ff @(posedge clk) begin
	if (we) ram[wa] <= wd;
	q <= ram[ra];
end

endmodule
