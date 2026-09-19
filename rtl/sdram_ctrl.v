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
#(
	// CPU_CACHE 0 removes this controller's cpu_cache_new storage: the CPU's
	// own ap040_cache becomes the only cache, and this instance keeps just
	// the fill/pass protocol.  Left at 1 by default so the existing
	// controller benches still exercise the cached path.
	parameter CPU_CACHE = 1,
	// cpu_cache_new READ_PIPE: 1 only when the CPU shares this clock (P2).
	parameter CACHE_READ_PIPE = 0
)
(
	// system
	input             sysclk,
	input             c_7m,
	input             reset_n,
	input             cache_rst,
	input             cache_inhibit,
	input       [3:0] cpu_cache_ctrl,
	input             dcache_sw_en,
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
	// Chipset write visible to the CPU's internal cache.  snoop_tgl flips
	// once per write and snoop_addr is held with it, so cpu_wrapper can
	// cross a single event into the CPU clock domain with a toggle
	// synchroniser rather than trying to catch a 113MHz pulse.
	output            snoop_tgl,
	output     [24:1] snoop_addr,
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
// Share the first input capture with the cache and chipset.  A separate
// resettable copy put a reset mux on the long hop from the SDRAM input I/O
// register.  Move that reset qualification to the following, internal stage;
// the valid bit preserves the old pipe0 value on the first edge after reset.
reg walker_sdata_valid;
wire [15:0] walker_sdata_pipe0 = walker_sdata_valid ? sdata_reg_q : 16'd0;
(* preserve *) reg [15:0] walker_sdata_pipe;
reg [15:0] walker_sdata_pipe2;
reg [15:0]  walker_read_hi;
// cpu_cache_new has no snoop-ready output.  Its synchronous tag lookup and
// data-RAM write take four sampled edges (IDLE, WAIT, SNOOP, write), so each
// address/data half must remain selected throughout that window.  Starting
// the low half at state 6 also leaves the cache idle after the high-half
// write; the former state-2/state-4 pulses made the low request arrive while
// the cache was busy and changed the live RAM address under the high write.
// registered one cycle ahead (see the pre-decode block by the state
// counter): the raw range compares fed the cache's snoop tag-match cone
// straight from sdram_state and violated setup at 113 MHz
reg         walker_snoop_hi;
reg         walker_snoop_lo;
wire        walker_snoop = walker_snoop_hi | walker_snoop_lo;
wire [24:1] walker_snoop_addr = {walker_addr_latch, walker_snoop_lo};
wire [15:0] walker_snoop_data = walker_snoop_lo
							? walker_wdata_latch[15:0]
							: walker_wdata_latch[31:16];
reg        snoop_tgl_r = 0;
reg [24:1] snoop_addr_r;
reg        snoop_ev_q;
wire       snoop_ev = chipWE | walker_snoop;
always @ (posedge sysclk) begin
	snoop_ev_q <= snoop_ev;
	if (snoop_ev && !snoop_ev_q) begin
		snoop_tgl_r  <= ~snoop_tgl_r;
		snoop_addr_r <= walker_snoop ? walker_snoop_addr : chipAddr;
	end
end
assign snoop_tgl  = snoop_tgl_r;
assign snoop_addr = snoop_addr_r;

cpu_cache_new #(.CACHE_ENABLE(CPU_CACHE), .READ_PIPE(CACHE_READ_PIPE)) cpu_cache
(
	.clk              (sysclk),                // clock
	.rst              (!reset || !cache_rst),  // cache reset
	.cpu_cache_ctrl   (cpu_cache_ctrl),        // CPU cache control
	.dcache_sw_en     (dcache_sw_en),
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

// All read consumers share this first capture from the SDRAM input register.
// The cache consumes fill data through it: the direct
// sdata_reg hop into cpu_cache_new's line-write port was the other
// recurring -0.38ns violator.  The strobes move one state later to
// match; the cache just counts four acknowledges, so the shift is
// transparent to it (last beat lands during state 15, inside the slot).
always @ (posedge sysclk) begin
	sdata_reg_q <= sdata_reg;
	walker_sdata_valid <= reset_n;
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
reg        fwd_en = 1'b0;
reg  [1:0] fwd_pos;
reg [15:0] fwd_dat;
reg  [1:0] fwd_dqm;

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
	reg [15:0] m;

	m = sdata_reg_q;
	if(fwd_en) begin
		if(!fwd_dqm[1]) m[15:8] = fwd_dat[15:8];
		if(!fwd_dqm[0]) m[7:0]  = fwd_dat[7:0];
	end
	if(slot_type == CHIP) begin
		case(sdram_state)
			 9: chipRD   <= (fwd_en && fwd_pos==2'd0) ? m : sdata_reg_q;
			11: chip48_1 <= (fwd_en && fwd_pos==2'd1) ? m : sdata_reg_q;
			13: chip48_2 <= (fwd_en && fwd_pos==2'd2) ? m : sdata_reg_q;
			15: chip48_3 <= (fwd_en && fwd_pos==2'd3) ? m : sdata_reg_q;
		endcase
	end
end

assign chip48 = {chip48_1, chip48_2, chip48_3};


////////////////////////////////////////
// SDRAM control
////////////////////////////////////////


// The edge that starts a new slot.  sdram_state goes to 0 either by wrapping
// from 15 or because the 7MHz rise pulled it back, and everything that has to
// be ready for state 0 -- the init counter, pre_sel, the RAS row -- is loaded
// here rather than at state 15, so a slot cut short by the resynchronisation
// still gets a row instead of leaving the previous slot's CAS column in place
// (tb_sdram32 +break_slotphase).  In steady state the two are the same edge.
reg        old_7m_q;
always @ (posedge sysclk) old_7m_q <= c_7m;
wire [3:0] next_sdram_state = (~old_7m_q & c_7m) ? 4'd0 : (sdram_state + 4'd1);
wire       slot_start       = (next_sdram_state == 4'd0);

//// init counter ////
always @ (posedge sysclk) begin
	if(!reset) begin
		initstate <= 0;
		init_done <= 0;
	end else begin
		if (slot_start) begin
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

// Same treatment for the walker write's second CAS: slot_type is loaded
// at state 0, so a registered copy of the comparison is stable long
// before states 4 and 6 use it, and the sd_addr/sd_dqm pin registers see
// a single-bit select instead of the 3-bit slot compare (the recurring
// -0.2 ns sd_addr[12] violator of this floorplan).
reg walker_wr_slot;
always @ (posedge sysclk) begin
	walker_wr_slot <= (slot_type == WALKER_WRITE);
end

//// sdram state ////
always @ (posedge sysclk) begin
	reg old_7m;

	sdram_state <= sdram_state + 1'd1;

	old_7m <= c_7m;
	if(~old_7m & c_7m) sdram_state <= 0;
end

// One-cycle pre-decodes of the state selects that feed SDRAM pin
// registers and the cache snoop cone.  next_sdram_state mirrors the
// counter including the 7MHz resync, so every flag is exact even on the
// cycle the counter is yanked back to zero.
reg        ras_go;          // high during state 0
// sd_addr's input cone, one LUT deep.
//
// The pin register's D input was a mux over four sources picked by four
// separate one-hot conditions -- the RAS state, the CAS state, the walker's
// second CAS and the init sequence -- which is eight inputs per bit and so
// two LUT levels.  The route from this module to the address pins is
// 5.447 ns of the budget, so every level here is expensive.
//
// What is left is, per bit, one six-input LUT and nothing else:
//
//     sd_addr[i] <= (sel_ras & init_done & (~chipDMA | ~chipRW))
//                 ? chipAddr[i+10] : row_col[i]
//
// enabled by sel_ras|sel_cas.  Only two of those six inputs come from outside
// this module, and no shared node stands between them and the pin, so the
// synthesiser can duplicate the whole cone per bit and the fitter can put
// each copy next to the pin it drives.  177d4cd7 is the measurement behind
// that: a shared select node for this mux cost 1.40 ns on the worst path.
//
// One register holds every source, because no two of them are ever live at
// once.  Slot order is RAS at state 0, CAS at state 2, the walker's second
// CAS at state 4, and the next slot's row loaded at state 15 -- so the row is
// read before the column overwrites it, and the column before the row does.
//
// The capture schedule is untouched -- same edges, same values, so the SDRAM
// sees exactly what it saw before.
reg        sel_ras;      // the next edge loads the RAS row
reg        sel_cas;      // the next edge loads a CAS word
reg        walker_cas2_go;  // high during state 4 of a walker write slot
always @ (posedge sysclk) begin
	ras_go         <= (next_sdram_state == 4'd0);
	sel_ras        <= (next_sdram_state == 4'd0);
	sel_cas        <= (next_sdram_state != 4'd0) &&
	                  ((sdram_state == 4'd1) ||
	                   ((slot_type == WALKER_WRITE) &&
	                    (next_sdram_state == 4'd4)));
	walker_cas2_go <= (slot_type == WALKER_WRITE) && (next_sdram_state == 4'd4);
	walker_snoop_hi <= (slot_type == WALKER_WRITE) &&
	                   (next_sdram_state >= 4'd2) && (next_sdram_state <= 4'd5);
	walker_snoop_lo <= (slot_type == WALKER_WRITE) &&
	                   (next_sdram_state >= 4'd6) && (next_sdram_state <= 4'd9);
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
// The refresh counter lives at module scope because ras_local, which is loaded
// a slot ahead of the state 0 that uses it, has to read it.  It is still
// written only by the command block below.
reg  [3:0] rcnt;
reg        ras_local;   // the next state 0 issues a RAS-class command, chipset aside
reg        ras_refresh; // ... and specifically that it is the refresh slot
reg        init_cas;    // the next state 0 is an init command that drives CAS low
reg        init_we;     // ... and one that drives WE low
// At module scope for the same reason as rcnt: row_col has to be written from
// one block, and its CAS-time values are built from these.  Still written only
// by the command block.
reg        cas_sd_we;
// Predecode the complete ordinary-write qualifier, so init_done no longer
// routes directly into every data-pin OE register.  Use the next init_done
// value (including reset and a shortened slot) to preserve the old pin timing.
reg        cas_write_go;
always @(posedge sysclk)
	cas_write_go <= reset && (init_done || (slot_start && (&initstate))) &&
	                (sdram_state == 4'd1) && !cas_sd_we;
reg  [1:0] cas_dqm;
reg  [9:0] casaddr;
reg  [1:0] pre_ba;
reg  [9:0] pre_col;
// The one register behind sd_addr: the RAS row from state 15 until state 0
// has issued it, then the CAS column, then the walker write's second column.
reg [12:0] row_col;

// Everything sd_addr can load, in one register and one block: the next slot's
// RAS row at state 15, the CAS column at state 1, the walker write's second
// column at state 3.  The row is read at state 0 before state 1 overwrites it,
// and each column is read before the next row load, so nothing is ever lost.
always @(posedge sysclk) begin
	if (!reset_n) begin
		pre_sel   <= PRE_NONE;
		row_col   <= (13'd1 << 10);
		ras_local <= 1'b0;
	end
	else if (slot_start) begin
		// Everything but the chipset that can make state 0 issue a RAS-class
		// command, decided on the same edge that decides pre_sel and from the
		// same expressions.  rcnt only moves at state 0 and initstate only at
		// state 15, so this names exactly what the next state 0 will do.
		ras_local <= init_done
		           ? (write_req || (!walker_busy && walker_req_q) ||
		              (cache_req && cache_req_q2) || (&rcnt))
		           : ((initstate == 4'd3)  || (initstate == 4'd7) ||
		              (initstate == 4'd9)  || (initstate == 4'd12));
		// The refresh slot on its own: it is the last arm in the priority
		// chain, so it also needs the chipset to have passed, which is the
		// only late term left in the command pins' cones.
		ras_refresh <= init_done && (&rcnt) &&
		               !(write_req || (!walker_busy && walker_req_q) ||
		                 (cache_req && cache_req_q2));
		// AUTOREFRESH (init 8 and 10) and LOAD MODE REGISTER (13) drive CAS
		// low; PRECHARGE (4) and LOAD MODE REGISTER drive WE low.  initstate
		// advances on this edge, so these name the next slot's command.
		init_cas  <= !init_done && ((initstate == 4'd7) || (initstate == 4'd9) ||
		                            (initstate == 4'd12));
		init_we   <= !init_done && ((initstate == 4'd3) || (initstate == 4'd12));
		if (!init_done) begin
			pre_sel <= PRE_NONE;
			// initstate increments on this same edge, so the row loaded here
			// is the one the next slot's state 0 issues.  State 13 is LOAD
			// MODE REGISTER; state 4 is PRECHARGE ALL and wants A10; every
			// other init state issues no command and its address is a
			// don't-care.
			row_col <= (initstate == 4'd12) ? 13'b0001000100010
			                                : (13'd1 << 10);
		end
		else if (write_req) begin
			pre_sel <= PRE_WRITE;
			{pre_ba, row_col, pre_col[8:0]} <= writeAddr;
		end
		else if (!walker_busy && walker_req_q) begin
			pre_sel <= PRE_WALKER;
			{pre_ba, row_col, pre_col[8:0]} <= {walker_addr, 1'b0};
		end
		else if (cache_req && cache_req_q2) begin
			pre_sel <= PRE_CACHE;
			{pre_ba, row_col, pre_col[8:0]} <= cache_addr_lat;
		end
		else
			pre_sel <= PRE_NONE;
	end

	// The CAS-time values, built a cycle before the state that uses them so
	// the pin register selects between settled words.  slot_type is read
	// directly rather than through walker_wr_slot, which is a cycle behind it
	// and would still name the previous slot here.  States 1, 3 and 15 are
	// disjoint, so these and the row load above never race.
	if (reset_n && (sdram_state == 4'd1))
		row_col <= {(!cas_sd_we ? cas_dqm : 2'b00),
		            !(slot_type == WALKER_WRITE), casaddr};
	if (reset_n && (sdram_state == 4'd3))
		row_col <= {2'b00, 1'b1, casaddr[9:1], 1'b1};
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
		walker_ack         <= 0;
		walker_rdata       <= 0;
	end
	else begin
		// Three stages, with the first shared with the other read consumers.
		// The reset mux is after that capture, away from the SDRAM input pin.
		walker_sdata_pipe  <= walker_sdata_pipe0;
		walker_sdata_pipe2 <= walker_sdata_pipe;
		walker_ack <= 0;
		if (!walker_req) walker_busy <= 0;
		if (walker_grant) begin
			walker_busy        <= 1;
			walker_addr_latch  <= walker_addr;
			walker_wdata_latch <= walker_wdata;
		end

		if (slot_type == WALKER_READ) begin
			// One state later again for the third stage.  The low half is
			// taken straight off pipe2 in the acknowledge state instead of
			// through a register of its own, which keeps the ack at state 13
			// -- the slot has states 0..15 and moving the ack to 14 would
			// leave a one-cycle pulse in the last state before the wrap.
			if (sdram_state == 4'd11)
				walker_read_hi <= walker_sdata_pipe2;
			if (sdram_state == 4'd13) begin
				walker_rdata <= {walker_read_hi, walker_sdata_pipe2};
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
	reg [15:0] datawr;
	
	sd_clk <= sdram_state[0];

	// The three command pins, each written from exactly one place.
	//
	// Every condition that drives one of them low -- the init commands at
	// state 0, the slot arbiter's RAS at state 0, the CAS at state 2, the
	// walker write's second CAS at state 4 -- falls on an even state, so the
	// enable for all three is simply ~sdram_state[0].  Written as scattered
	// overrides the synthesiser could not see that, so it implemented the odd
	// states as a hold, which needs the register's own output back at its
	// input; it then duplicated sd_cas and put the two copies far apart, and
	// ram1|sd_cas~_Duplicate_1 -> ram1|sd_cas was the worst path in the
	// design at -2.314 ns.  One assignment each, no feedback.
	//
	// Every term is a registered flag except the chipset's ownership of the
	// slot, which cannot be registered earlier: Agnus drives it on the edge
	// that starts the slot.  The CAS qualifiers are gated by init_done because
	// nothing writes them until the init sequence is over, and before the fold
	// they were unreachable during it rather than merely unused.
	if(~sdram_state[0]) begin
		sd_ras  <= !(ras_go && ((init_done && ((~chipDMA) | (~chipRW))) ||
		                        ras_local));
		sd_cas  <= !((ras_go && (init_cas ||
		                         (ras_refresh && !((~chipDMA) | (~chipRW))))) ||
		             walker_cas2_go || (init_done && cas_go && !cas_sd_cas));
		sd_we   <= !((ras_go && init_we) || walker_cas2_go || cas_write_go);
		// Same argument, same enable: the data bus is driven only by the two
		// CAS states and released everywhere else, and chipWE is raised only
		// by the chipset's own RAS.
		sd_data <= walker_cas2_go            ? walker_wdata_latch[15:0] :
		           cas_write_go                    ? datawr
		                                              : 16'hZZZZ;
		chipWE  <= ras_go && init_done && ((~chipDMA) | (~chipRW)) && !chipRW;
	end

	if(sdram_state[0]) sdata_reg <= sd_data;

	if (sel_ras && init_done && ((~chipDMA) | (~chipRW)))
		sd_addr <= chipAddr[22:10];
	else if (sel_ras || sel_cas)
		sd_addr <= row_col;
	// otherwise hold

	// The mask and the bank hold across the whole burst rather than across the
	// odd states, so their enable is not ~sdram_state[0] -- but it is still a
	// short list of registered flags, and writing them once each keeps their
	// own outputs out of their own cones.  The bank is loaded at every RAS,
	// taking pre_ba on the slots that do not belong to the chipset; on a slot
	// that issues no command at all it is a don't-care, exactly as the row in
	// row_col is.
	if (!init_done || ras_go || walker_cas2_go || cas_go)
		sd_dqm <= (!init_done || ras_go)  ? 2'd3 :
		          walker_cas2_go          ? 2'd0 :
		          (!cas_sd_we)            ? cas_dqm : 2'd0;
	if (!init_done || ras_go)
		sd_ba  <= !init_done ? 2'd0 :
		          ((~chipDMA) | (~chipRW)) ? chipAddr[24:23] : pre_ba;

	if(!init_done) begin
		slot_type             <= IDLE;
		casaddr               <= 0;
		rcnt                  <= 0;
	end else begin

		case(sdram_state)

			// RAS, CAS and the walker's second CAS are keyed on the
			// one-cycle pre-decoded ras_go/cas_go/walker_cas2_go flags in
			// the blocks below the case, so the sd_* pin registers see
			// single-signal selects instead of 4-bit state compares
			2 : write_ack <= 0; // safe to accept the next write
		endcase

		// RAS slot arbitration (state 0)
		if (ras_go) begin
				cas_sd_cas      <= 1;
				cas_sd_we       <= 1;
				cas_dqm         <= 0;
				slot_type       <= IDLE;
				fwd_en          <= 0;

				if(~&rcnt) rcnt <= rcnt + 1'd1;

				// we give the chipset first priority
				// (this includes anything on the "motherboard" - chip RAM, slow RAM and Kickstart, turbo modes notwithstanding)
				if(~chipDMA | ~chipRW) begin
					slot_type    <= CHIP;
					casaddr[8:0] <= chipAddr[9:1];
					cas_dqm      <= {chipU,chipL};
					cas_sd_cas   <= 0;
					cas_sd_we    <= chipRW;
					datawr       <= chipWR;
					if(chipRW & write_req & (writeAddr[24:3] == chipAddr[24:3])) begin
						fwd_en  <= 1'b1;
						fwd_pos <= writeAddr[2:1] - chipAddr[2:1];
						fwd_dat <= writeDat;
						fwd_dqm <= write_dqm;
					end
				end
				else if(pre_sel == PRE_WRITE) begin
					slot_type    <= CPU_WRITECACHE;
					casaddr[8:0] <= pre_col[8:0];
					cas_dqm      <= write_dqm;
					cas_sd_we    <= 0;
					cas_sd_cas   <= 0;
					write_ack    <= 1; // let the write buffer know we're about to write
					datawr       <= writeDat;
				end
				else if(pre_sel == PRE_WALKER) begin
					slot_type    <= walker_we ? WALKER_WRITE : WALKER_READ;
					casaddr[8:0] <= pre_col[8:0];
					cas_dqm      <= 0;
					cas_sd_cas   <= 0;
					cas_sd_we    <= ~walker_we;
					datawr       <= walker_wdata[31:16];
				end
				// request from read cache
				else if(pre_sel == PRE_CACHE) begin
					slot_type    <= CPU_READCACHE;
					casaddr[8:0] <= pre_col[8:0];
					cas_sd_cas   <= 0;
				end
				else if(&rcnt) begin
					// REFRESH
					rcnt         <= 0;
				end
		end

		// The CAS states no longer appear here at all.  Every pin they drive
		// -- address, command, data, mask, bank -- is written once, at the top
		// of this block, from cas_go and walker_cas2_go and the registered
		// qualifiers latched at the RAS state.  Two notes that lived here and
		// still matter:
		//
		// A walker write issues a second single-write CAS to column+1 two
		// cycles later (the mode word sets A9, single-location write burst, so
		// a data beat after the CAS cycle is ignored by the chip; tCCD=1 on
		// SDR makes back-to-back writes two states apart legal).  The first of
		// the two must not auto-precharge, or the bank would be precharging
		// under the second command -- cas_sd_cas carries that, and the second
		// command carries A10 instead.
	end
end

endmodule
