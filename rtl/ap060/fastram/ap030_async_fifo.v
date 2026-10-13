//--------------------------------------------------------------------------//
// AP030 - MC68030 compatible CPU                                           //
//                                                                          //
// ap030_async_fifo.v - dual-clock FIFO (Gray-coded pointers, two-flop      //
// synchronisers).  The read port is show-ahead: rdata is the oldest entry  //
// whenever rempty is low, and re removes it.                               //
//                                                                          //
// wlevel/rlevel are each side's (conservative) view of the fill level:     //
// the writer may see entries already read, the reader may miss entries     //
// just written, never the other way round.                                 //
//                                                                          //
// No reset: the pointers power up equal (FPGA initial values) and the      //
// users never discard entries, so a FIFO is never left half-cleared by a   //
// reset of only one of its clock domains.                                  //
//--------------------------------------------------------------------------//

module ap030_async_fifo
#(
	parameter W  = 64,          // data width
	parameter AW = 3            // log2 of the depth
)
(
	input              wclk,
	input              we,
	input      [W-1:0] wdata,
	output             wfull,
	output    [AW:0]   wlevel,

	input              rclk,
	input              re,
	output     [W-1:0] rdata,
	output             rempty,
	output    [AW:0]   rlevel
);

reg [W-1:0] mem [0:(1<<AW)-1];

// binary and Gray pointers, one bit wider than the address
reg [AW:0] wbin = 0, wgray = 0;
reg [AW:0] rbin = 0, rgray = 0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [AW:0] rgray_w1 = 0;
reg [AW:0] rgray_w2 = 0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [AW:0] wgray_r1 = 0;
reg [AW:0] wgray_r2 = 0;

function [AW:0] bin2gray; input [AW:0] b; begin bin2gray = b ^ (b >> 1); end endfunction
function [AW:0] gray2bin;
	input [AW:0] g;
	integer i;
	begin
		gray2bin[AW] = g[AW];
		for (i = AW - 1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i + 1] ^ g[i];
	end
endfunction

// write side
always @(posedge wclk) begin
	rgray_w1 <= rgray;
	rgray_w2 <= rgray_w1;
	if (we && !wfull) begin
		mem[wbin[AW-1:0]] <= wdata;
		wbin  <= wbin + 1'd1;
		wgray <= bin2gray(wbin + 1'd1);
	end
end
wire [AW:0] rbin_w = gray2bin(rgray_w2);
assign wlevel = wbin - rbin_w;
assign wfull  = (wlevel[AW] == 1'b1);

// read side
always @(posedge rclk) begin
	wgray_r1 <= wgray;
	wgray_r2 <= wgray_r1;
	if (re && !rempty) begin
		rbin  <= rbin + 1'd1;
		rgray <= bin2gray(rbin + 1'd1);
	end
end
wire [AW:0] wbin_r = gray2bin(wgray_r2);
assign rlevel = wbin_r - rbin;
assign rempty = (rlevel == 0);
assign rdata  = mem[rbin[AW-1:0]];

endmodule
