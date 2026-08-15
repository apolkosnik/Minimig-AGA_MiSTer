//////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////
//                                                                          //
// Copyright (c) 2009/2011 Tobias Gubener                                   //
// Subdesign fAMpIGA by TobiFlex                                            //
//                                                                          //
// This source file is free software: you can redistribute it and/or modify //
// it under the terms of the GNU General Public License as published        //
// by the Free Software Foundation, either version 3 of the License, or     //
// (at your option) any later version.                                      //
//                                                                          //
// This source file is distributed in the hope that it will be useful,      //
// but WITHOUT ANY WARRANTY; without even the implied warranty of           //
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            //
// GNU General Public License for more details.                             //
//                                                                          //
// You should have received a copy of the GNU General Public License        //
// along with this program.  If not, see <http://www.gnu.org/licenses/>.    //
//                                                                          //
//////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////
//
// Code re-work:
// - Shrink 16 to 12 cycles to work at quarter lower frequency with the same performance.
// - Support for 64MB SDRAM
//
// (C)2019 Alexey Melnikov
//


module sdram_ctrl
(
	// system
	input             sysclk,
	input             c_7m,
	input             reset_n,
	input             cache_rst,
	input             cache_inhibit,
	input       [3:0] cpu_cache_ctrl,
	// sdram
	output reg [12:0] sd_addr,
	output reg  [1:0] sd_ba,
	output            sd_cs,
	output reg        sd_we,
	output reg        sd_ras,
	output reg        sd_cas,
	output reg  [1:0] sd_dqm,
	inout  reg [15:0] sd_data,
	output reg        sd_clk,
	output            sd_cke,
	// chip
	input      [24:1] chipAddr,
	input             chipL,
	input             chipU,
	input             chipRW,
	input             chipDMA,
	input      [15:0] chipWR,
	output reg [15:0] chipRD,
	output     [47:0] chip48,
	// cpu
	input      [24:1] cpuAddr,
	input             cpuCS,
	input       [1:0] cpustate,
	input             cpuL,
	input             cpuU,
	input      [15:0] cpuWR,
	output     [15:0] cpuRD,
	output            ramready,

	// Dedicated, cache-bypassing AP040 table-walker port (clk=sysclk).
	input             walker_req,
	input             walker_we,
	input      [24:2] walker_addr,
	input      [31:0] walker_wdata,
	output reg        walker_ack,
	output reg [31:0] walker_rdata
);

assign sd_cs = 0;
assign sd_cke = 1;

//// parameters ////
localparam [2:0]
	IDLE = 0,
	CHIP = 1,
	CPU_READCACHE = 2,
	CPU_WRITECACHE = 3,
	WALKER_READ = 4,
	WALKER_WRITE = 5;

reg         cache_fill;
reg  [3:0]  initstate;
reg         init_done;
reg  [3:0]  sdram_state;
reg  [2:0]  slot_type = IDLE;
reg [15:0]  sdata_reg;
reg [15:0]  sdata_reg_q;
reg         chipWE;


////////////////////////////////////////
// reset
////////////////////////////////////////

reg reset;
always @(posedge sysclk) begin
	reg [7:0] reset_cnt;

	if(!reset_n) begin
		reset_cnt     <= 0;
		reset         <= 0;
	end else begin
		if(reset_cnt == 170) begin
			if(sdram_state == 15) reset <= 1;
		end
		else begin
			reset_cnt <= reset_cnt + 8'd1;
		end
	end
end

wire ramsel = cpuCS & (~&cpustate | ~cpuU | ~cpuL);

// cpu cache
wire cache_rd_ack;
wire cache_wr_ack;
wire cache_req;
reg         walker_busy;
reg [24:2]  walker_addr_latch;
reg [31:0]  walker_wdata_latch;
(* preserve *) reg [15:0] walker_sdata_pipe;
reg [15:0] walker_sdata_pipe2;
reg [15:0]  walker_read_hi;
reg [15:0]  walker_read_lo;
// cpu_cache_new has no snoop-ready output.  Its synchronous tag lookup and
// data-RAM write take four sampled edges (IDLE, WAIT, SNOOP, write), so each
// address/data half must remain selected throughout that window.  Starting
// the low half at state 6 also leaves the cache idle after the high-half
// write; the former state-2/state-4 pulses made the low request arrive while
// the cache was busy and changed the live RAM address under the high write.
wire        walker_snoop_hi = (slot_type == WALKER_WRITE) &&
						   (sdram_state >= 4'd2) && (sdram_state <= 4'd5);
wire        walker_snoop_lo = (slot_type == WALKER_WRITE) &&
						   (sdram_state >= 4'd6) && (sdram_state <= 4'd9);
wire        walker_snoop = walker_snoop_hi | walker_snoop_lo;
wire [24:1] walker_snoop_addr = {walker_addr_latch, walker_snoop_lo};
wire [15:0] walker_snoop_data = walker_snoop_lo
							? walker_wdata_latch[15:0]
							: walker_wdata_latch[31:16];
cpu_cache_new cpu_cache
(
	.clk              (sysclk),                // clock
	.rst              (!reset || !cache_rst),  // cache reset
	.cpu_cache_ctrl   (cpu_cache_ctrl),        // CPU cache control
	.cache_inhibit    (cache_inhibit),         // cache inhibit
	.cpu_cs           (ramsel),                // cpu activity
	.cpu_adr          (cpuAddr),               // cpu address
	.cpu_bs           ({!cpuU, !cpuL}),        // cpu byte selects
	.cpu_we           (cpustate == 3),         // cpu write
	.cpu_ir           (cpustate == 0),         // cpu instruction read
	.cpu_dr           (cpustate == 2),         // cpu data read
	.cpu_dat_w        (cpuWR),                 // cpu write data
	.cpu_dat_r        (cpuRD),                 // cpu read data
	.cpu_ack          (cache_rd_ack),          // cpu acknowledge
	.wb_en            (cache_wr_ack),          // write enable
	.sdr_dat_r        (sdata_reg_q),           // sdram read data (registered)
	.sdr_read_req     (cache_req),             // sdram read request from cache
	.sdr_read_ack     (cache_fill),            // sdram read acknowledge to cache
	.snoop_act        (chipWE | walker_snoop), // keep cached page-table words coherent
	.snoop_adr        (walker_snoop ? walker_snoop_addr : chipAddr),
	.snoop_dat_w      (walker_snoop ? walker_snoop_data : chipWR),
	.snoop_bs         (walker_snoop ? 2'b11 : {!chipU, !chipL})
);

// The cache consumes fill data through a dedicated register: the direct
// sdata_reg hop into cpu_cache_new's line-write port was the other
// recurring -0.38ns violator.  The strobes move one state later to
// match; the cache just counts four acknowledges, so the shift is
// transparent to it (last beat lands during state 15, inside the slot).
always @ (posedge sysclk) begin
	sdata_reg_q <= sdata_reg;
	cache_fill <= 0;

	if(init_done && slot_type == CPU_READCACHE) begin
		case(sdram_state)
		   8, 10, 12, 14: cache_fill <= 1;
		endcase
	end
end

// write buffer, enables CPU to continue while a write is in progress
reg        write_ena;
reg        write_req;
reg        write_ack;
reg  [1:0] write_dqm;
reg [24:1] writeAddr;
reg [15:0] writeDat;

always @ (posedge sysclk) begin
	reg  [1:0] write_state;

	if(~reset_n) begin
		write_req   <= 0;
		write_ena   <= 0;
		write_state <= 0;
	end else begin
		case(write_state)
			default:
				if(~write_ena && ramsel && cpustate == 3) begin
					writeAddr <= cpuAddr;
					writeDat  <= cpuWR;
					write_dqm <= {cpuU, cpuL};
					write_req <= 1;
					if(cache_wr_ack) begin
						write_ena   <= 1;
						write_state <= 1;
					end
				end

			1: if(write_ack) begin
					write_req   <= 0;
					write_state <= 2;
				end

			2: if(!write_ack) begin
					write_state <= 0;
				end
		endcase

		if(~ramsel) write_ena <= 0;
	end
end

assign ramready = cache_rd_ack || write_ena;

//// chip line read ////
reg [15:0] chip48_1, chip48_2, chip48_3;

always @ (posedge sysclk) begin
	reg [15:0] sdata_chip;

	sdata_chip <= sdata_reg;
	if(slot_type == CHIP) begin
		case(sdram_state)
			 9: chipRD   <= sdata_chip;
			11: chip48_1 <= sdata_chip;
			13: chip48_2 <= sdata_chip;
			15: chip48_3 <= sdata_chip;
		endcase
	end
end

assign chip48 = {chip48_1, chip48_2, chip48_3};


////////////////////////////////////////
// SDRAM control
////////////////////////////////////////


//// init counter ////
always @ (posedge sysclk) begin
	if(!reset) begin
		initstate <= 0;
		init_done <= 0;
	end else begin
		if (sdram_state == 15) begin
			if(~&initstate) initstate <= initstate + 1'd1;
			else init_done <= 1;
		end
	end
end


// One-cycle pre-decoded select for the CAS state: the recurring setup
// violators across every fit of this floorplan are the sd_addr/sd_cas/
// sd_data pin-register input cones, whose selects previously computed
// the full 4-bit state compare plus qualifiers in the same cycle they
// load.  cas_go collapses that to a single registered flag.  The state
// counter only leaves the 0..15 ramp at the c_7m wrap, which in steady
// state coincides with 15->0, so state==1 now is exactly state==2 next.
reg cas_go;
always @ (posedge sysclk) begin
	cas_go <= (sdram_state == 4'd1);
end

//// sdram state ////
always @ (posedge sysclk) begin
	reg old_7m;

	sdram_state <= sdram_state + 1'd1;

	old_7m <= c_7m;
	if(~old_7m & c_7m) sdram_state <= 0;
end

//// sdram control ////

// The walker request is registered before it reaches the slot arbiter.  It
// arrives gated by the SDRAM/DDR3 bank decode, which is several levels of
// logic past the clock-domain-crossing register, and feeding that directly
// into the priority chain and the row-address mux was the critical path of
// the whole 113MHz domain.  The handshake is level held until ack, so one
// cycle of extra acceptance latency changes nothing functionally.
reg walker_req_q;
always @(posedge sysclk) begin
	if (!reset_n) walker_req_q <= 1'b0;
	else          walker_req_q <= walker_req && !walker_busy;
end

// Slot pre-arbitration: the local requesters (write buffer, walker,
// cache) are all level-held registers, so they are arbitrated one
// cycle EARLY (state 15) into staging registers.  The state-0 row-
// address load then muxes through a single 2-bit select instead of
// the full request/address cones -- the recurring sd_addr[7/8] setup
// violators (walker_req_q/init_done/state-dups into the row mux) get
// a whole cycle of their own.  The chipset keeps absolute priority,
// still sampled AT state 0: when it steals the slot the staged local
// grant is simply discarded and retried next CCK (level-held, no
// loss).  A request first asserting during state 15/0 waits one CCK.
localparam [1:0] PRE_NONE = 2'd0, PRE_WRITE = 2'd1,
                 PRE_WALKER = 2'd2, PRE_CACHE = 2'd3;

// The cache acknowledges the CPU on the FIRST burst beat, so cpuAddr can
// already point at the next access while sdr_read_req still streams the
// fill: a slot granted then would fetch the WRONG address into the line
// (the stale-hit corruption behind cputest FABS.X ([0]) and friends --
// present since before the pre-arbitration, which inherited it).  Latch
// the address at the request EDGE, when it is still the miss address.
reg [24:1] cache_addr_lat;
reg        cache_req_q2;
always @(posedge sysclk) begin
	cache_req_q2 <= cache_req;
	if (cache_req && !cache_req_q2)
		cache_addr_lat <= cpuAddr;
end
reg  [1:0] pre_sel;
reg  [1:0] pre_ba;
reg [12:0] pre_row;
reg  [9:0] pre_col;
always @(posedge sysclk) begin
	if (!reset_n) begin
		pre_sel <= PRE_NONE;
	end
	else if (sdram_state == 4'd15) begin
		if (!init_done)
			pre_sel <= PRE_NONE;
		else if (write_req) begin
			pre_sel <= PRE_WRITE;
			{pre_ba, pre_row, pre_col[8:0]} <= writeAddr;
		end
		else if (!walker_busy && walker_req_q) begin
			pre_sel <= PRE_WALKER;
			{pre_ba, pre_row, pre_col[8:0]} <= {walker_addr, 1'b0};
		end
		else if (cache_req && cache_req_q2) begin
			pre_sel <= PRE_CACHE;
			{pre_ba, pre_row, pre_col[8:0]} <= cache_addr_lat;
		end
		else
			pre_sel <= PRE_NONE;
	end
end

wire walker_grant = (sdram_state == 4'd0) && (pre_sel == PRE_WALKER) &&
				    !((~chipDMA) | (~chipRW));

// Capture native walker completions. The request remains level-held across
// the transfer; walker_busy prevents it from being accepted twice.
always @(posedge sysclk) begin
	if (!reset_n) begin
		walker_busy        <= 0;
		walker_addr_latch  <= 0;
		walker_wdata_latch <= 0;
		walker_sdata_pipe  <= 0;
		walker_read_hi     <= 0;
		walker_read_lo     <= 0;
		walker_ack         <= 0;
		walker_rdata       <= 0;
	end
	else begin
		// Keep the SDRAM input register's new fanout to one simple local
		// register.  Besides easing the 114 MHz path, the extra stages make
		// the longword assembly independent of the controller's burst timing.
		// Two stages: sdata_reg -> pipe -> pipe2 gives the router a full
		// spare cycle on the sdata_reg hop (it was a -0.39ns violator).
		walker_sdata_pipe  <= sdata_reg;
		walker_sdata_pipe2 <= walker_sdata_pipe;
		walker_ack <= 0;
		if (!walker_req) walker_busy <= 0;
		if (walker_grant) begin
			walker_busy        <= 1;
			walker_addr_latch  <= walker_addr;
			walker_wdata_latch <= walker_wdata;
		end

		if (slot_type == WALKER_READ) begin
			// one state later than before: the data now arrives through
			// pipe2 (same burst words, one extra register of margin)
			if (sdram_state == 4'd10)
				walker_read_hi <= walker_sdata_pipe2;
			if (sdram_state == 4'd12)
				walker_read_lo <= walker_sdata_pipe2;
			if (sdram_state == 4'd13) begin
				walker_rdata <= {walker_read_hi, walker_read_lo};
				walker_ack   <= 1;
			end
		end
		// Ack only after both cache snoops have reached their data-RAM write
		// edge.  The physical SDRAM writes themselves complete at state 4.
		else if ((slot_type == WALKER_WRITE) && (sdram_state == 4'd10))
			walker_ack <= 1;
	end
end

always @ (posedge sysclk) begin
	reg        cas_sd_cas;
	reg        cas_sd_we;
	reg  [1:0] cas_dqm;
	reg [15:0] datawr;
	reg  [9:0] casaddr;
	reg  [3:0] rcnt;
	
	sd_clk <= sdram_state[0];

	if(~sdram_state[0]) begin
		sd_ras                <= 1;
		sd_cas                <= 1;
		sd_we                 <= 1;
		sd_data               <= 16'hZZZZ;
		chipWE                <= 0;
	end

	if(sdram_state[0]) sdata_reg <= sd_data;

	if(!init_done) begin
		slot_type             <= IDLE;
		casaddr               <= 0;
		rcnt                  <= 0;
		sd_dqm                <= 3;
		sd_ba                 <= 0;
		if(sdram_state == 0) begin
			case(initstate)
				4 : begin // PRECHARGE
					sd_addr[10]  <= 1; // all banks
					sd_ras       <= 0;
					sd_cas       <= 1;
					sd_we        <= 0;
				end
				8,10 : begin // AUTOREFRESH
					sd_ras       <= 0;
					sd_cas       <= 0;
					sd_we        <= 1;
				end
				13 : begin // LOAD MODE REGISTER
					sd_ras       <= 0;
					sd_cas       <= 0;
					sd_we        <= 0;
					sd_addr      <= 13'b0001000100010; // CL=2, BURST=4
				end
			endcase
		end
	end else begin

		case(sdram_state)

			// RAS
			0 : begin
				cas_sd_cas      <= 1;
				cas_sd_we       <= 1;
				cas_dqm         <= 0;
				sd_dqm          <= 3;
				slot_type       <= IDLE;

				if(~&rcnt) rcnt <= rcnt + 1'd1;

				// we give the chipset first priority
				// (this includes anything on the "motherboard" - chip RAM, slow RAM and Kickstart, turbo modes notwithstanding)
				if(~chipDMA | ~chipRW) begin
					slot_type    <= CHIP;
					{sd_ba,sd_addr,casaddr[8:0]} <= chipAddr;
					sd_ras       <= 0;
					cas_dqm      <= {chipU,chipL};
					cas_sd_cas   <= 0;
					cas_sd_we    <= chipRW;
					datawr       <= chipWR;
					chipWE       <= !chipRW;
				end
				else if(pre_sel == PRE_WRITE) begin
					slot_type    <= CPU_WRITECACHE;
					{sd_ba,sd_addr,casaddr[8:0]} <= {pre_ba, pre_row, pre_col[8:0]};
					sd_ras       <= 0;
					cas_dqm      <= write_dqm;
					cas_sd_we    <= 0;
					cas_sd_cas   <= 0;
					write_ack    <= 1; // let the write buffer know we're about to write
					datawr       <= writeDat;
				end
				else if(pre_sel == PRE_WALKER) begin
					slot_type    <= walker_we ? WALKER_WRITE : WALKER_READ;
					{sd_ba,sd_addr,casaddr[8:0]} <= {pre_ba, pre_row, pre_col[8:0]};
					sd_ras       <= 0;
					cas_dqm      <= 0;
					cas_sd_cas   <= 0;
					cas_sd_we    <= ~walker_we;
					datawr       <= walker_wdata[31:16];
				end
				// request from read cache
				else if(pre_sel == PRE_CACHE) begin
					slot_type    <= CPU_READCACHE;
					{sd_ba,sd_addr,casaddr[8:0]} <= {pre_ba, pre_row, pre_col[8:0]};
					sd_ras       <= 0;
					cas_sd_cas   <= 0;
				end
				else if(&rcnt) begin
					// REFRESH
					sd_ras       <= 0;
					sd_cas       <= 0;
					rcnt         <= 0;
				end
			end

			// CAS command moved below the case, keyed on the one-cycle
			// pre-decoded cas_go flag so the sd_* pin registers see a
			// single-signal select instead of the 4-bit state compare
			2 : write_ack <= 0; // safe to accept the next write

			// The mode word sets A9 (write burst = single location), so a
			// data beat after the CAS cycle is IGNORED by the chip -- the
			// original code lost the low word of every 32-bit walker
			// write.  Issue a second single-write CAS to column+1 with
			// the low word instead (tCCD=1 on SDR makes back-to-back
			// writes two states apart legal).
			4 : if (slot_type == WALKER_WRITE) begin
				sd_addr      <= {1'b1, casaddr[9:1], 1'b1}; // col+1, A10 precharge
				sd_cas       <= 0;
				sd_we        <= 0;
				sd_data      <= walker_wdata_latch[15:0];
				sd_dqm       <= 0;
			end
		endcase

		// CAS: all qualifiers (cas_sd_cas/cas_sd_we/cas_dqm/casaddr/
		// datawr) are registers latched at the RAS state, so with the
		// pre-decoded flag every sd_* pin-register input cone is one
		// LUT deep.  Placed after the case: overrides the even-state
		// deasserts exactly like the original arm did.
		if (cas_go) begin
			// A walker write issues a second single-write CAS two cycles
			// later; auto-precharging on the FIRST command would put the
			// bank into precharge under that second command (undefined on
			// real silicon).  Hold the row open here and let the second
			// command carry A10 instead.
			sd_addr         <= {(slot_type != WALKER_WRITE), casaddr}; // A10: AUTO PRECHARGE
			sd_cas          <= cas_sd_cas;
			sd_dqm          <= 0;
			if(!cas_sd_we) begin
				sd_data      <= datawr;
				sd_addr[12:11]<= cas_dqm;
				sd_dqm       <= cas_dqm;
				sd_we        <= 0;
			end
		end
	end
end

endmodule
