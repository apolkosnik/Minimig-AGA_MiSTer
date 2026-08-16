//--------------------------------------------------------------------------//
// Hold a consumed accelerated RAM request deselected until the controller   //
// has dropped its level acknowledgement.  The SDRAM/DDR3 caches hold ack    //
// (and the captured data) until their cpuCS input falls; allowing cpuCS to  //
// persist across a request boundary lets the next request consume the      //
// PREVIOUS one's acknowledgement and data.                                  //
//                                                                          //
// The deselect is keyed on the CPU wrapper's ram_consumed strobe -- the     //
// registered fact that the 28 MHz side sampled ramready for an active RAM   //
// request -- NOT on a clock-phase marker.  The TG68K-era `cyc` marker       //
// guessed the consumption edge from the PLL phase; at half the possible    //
// alignments the guess preceded every real sample point, which either      //
// starved the CPU of its acknowledgement outright or locked into a         //
// serve/kill loop that missed every sample edge (both reproduced by the    //
// 16-phase tb_sdram_turbo/tb_dualram_turbo sweeps).                        //
//                                                                          //
// The strobe reaches this module 4-8 clk_114 cycles after the actual       //
// consumption edge.  By then a fast controller may already be serving the  //
// NEXT sub-cycle, and killing that fresh acknowledgement would force a     //
// wasteful re-serve of every transfer.  ready_age separates the two: an    //
// acknowledgement that has been high continuously since before the        //
// consumption edge (age >= 4 when the strobe arrives) is the consumed,    //
// stale one and is killed; one that rose after the edge is a fresh serve   //
// and is left alone.  The stale ack is cleared well before the next        //
// request's first possible sample edge (one CPU clock after the next      //
// request begins).                                                         //
//--------------------------------------------------------------------------//

module ram_cs_guard
(
	input  clk,
	input  nreset,
	input  cpu_type,
	input  ram_consumed,
	input  ram_sel,
	input  ram_ready,
	output reg ram_cs
);

reg       consumed_q;
reg       consumed_qq;
reg [2:0] ready_age;
reg       ram_killed;

wire strobe   = consumed_q && !consumed_qq;
wire kill_now = strobe && ram_ready && (ready_age >= 3'd4) && cpu_type;

always @(posedge clk) begin
	if (!nreset) begin
		consumed_q  <= 0;
		consumed_qq <= 0;
		ready_age   <= 0;
		ram_killed  <= 0;
		ram_cs      <= 0;
	end
	else begin
		consumed_q  <= ram_consumed;
		consumed_qq <= consumed_q;

		if (!ram_ready)
			ready_age <= 0;
		else if (ready_age != 3'd7)
			ready_age <= ready_age + 3'd1;

		if (!ram_sel || !ram_ready)
			ram_killed <= 0;
		else if (kill_now)
			ram_killed <= 1;

		ram_cs <= ram_sel && !ram_killed && !kill_now;
	end
end

endmodule
