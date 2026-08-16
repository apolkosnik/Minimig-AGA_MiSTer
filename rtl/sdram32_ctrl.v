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
// AP040X2 work package X2.1: sdram32_ctrl
//
// This is rtl/sdram_ctrl.v with its data path doubled.  The command engine,
// the 16-state CCK slot machine, the slot pre-arbitration, the refresh
// discipline, the write buffer, the chipset port and the table-walker port
// are the proven originals -- only the data path, the address mapping and
// the new 32-bit line-fill port are new.  Both SDRAMs receive the SAME
// command every cycle (see "lockstep" below); the primary carries D[15:0]
// of each longword, the secondary D[31:16].
//
// ---------------------------------------------------------------------------
// Address mapping (DUAL_SDRAM = 1)
// ---------------------------------------------------------------------------
// One (bank,row,column) selects a 32-bit UNIT spanning both chips, so the
// unit index is the LONGWORD index addr[24:2] and the 16-bit word inside it
// is selected by addr[1]:
//
//     addr[1] = 0  ->  even (high) word, D[31:16], SECONDARY chip
//     addr[1] = 1  ->  odd  (low)  word, D[15:0],  PRIMARY   chip
//
// The plan text asks for the chipset port to live "on the primary chip
// only".  That is not physically realisable together with a coherent 32-bit
// CPU view: with the two chips in lockstep the pair holds ONE memory whose
// even words are in chip 2, and chip RAM is shared between Agnus and the
// CPU.  Confining chipset traffic to chip 1 would make the CPU read the
// stale half of every longword Agnus wrote (and vice versa).  What the
// constraint really protects -- the CCK-locked Agnus timing and the rule
// that a 16-bit chipset access must disturb exactly ONE 16-bit lane -- is
// honoured exactly:
//
//   - chipset slots keep the original 16-bit shape, the original slot
//     position and the original state-9/11/13/15 data timing;
//   - a chipset (or CPU 16-bit) WRITE updates one lane only.  The other
//     chip is masked for the whole slot, so it neither opens a row nor
//     accepts the write.
//
// Masking is done with nCS, not with DQM: MiSTer's io-board second SDRAM
// (sys/sys_dual_sdram.tcl) routes A, BA, nRAS, nCAS, nWE, nCS, CLK and DQ
// but NOT DQML/DQMH -- the second chip's byte masks are tied on the board.
// sd2_dqm is still driven correctly for boards that do route it, but nCS is
// the load-bearing mask.  The mask covers the ACTIVE as well as the WRITE:
// masking only the WRITE would leave the secondary's row open while the
// primary auto-precharges, and the next slot's ACTIVE to an open bank is
// illegal.
//
// ---------------------------------------------------------------------------
// Bursts
// ---------------------------------------------------------------------------
// The mode word is unchanged (CL=2, sequential burst of 4, single-location
// write).  In dual mode a burst of 4 units is 4 longwords = 16 bytes, so the
// new fill port takes ONE ACTIVE + ONE burst per cache line.
//
// The 16-bit ports need only the 4 words of one aligned 8-byte block, i.e.
// two units.  A burst that starts at the requested unit delivers the partner
// unit last when the requested word sits in the upper half of the block, too
// late for the state-11/13 chip48 and cache-fill windows.  Dual mode
// therefore issues a SECOND read command at state 4 for the partner unit
// (the truncating-read idiom the walker write already used, tCCD=1 on SDR):
//
//     state 2 CAS -> unit U      -> beat A, captured into sdata_reg at 7
//     state 4 CAS -> unit U^1    -> beat B, captured into sdata_reg at 9
//
// which puts both units in hand by state 10, and the four block words are
// then presented in the ORIGINAL rotated burst order (critical word first)
// at exactly the original states.  A10/auto-precharge moves to the second
// command, as it does for the walker's second write.
//
// ---------------------------------------------------------------------------
// Lockstep
// ---------------------------------------------------------------------------
// sd2_addr/ba/ras/cas/we/clk/cke are continuous copies of the primary's pin
// registers, so command identity is structural rather than duplicated logic
// that could drift; tb_sdram32 checks it every cycle anyway.  Only nCS, DQM
// and DQ differ, and only for lane-masked writes and walker writes.  The
// fitter is expected to duplicate the source registers into the second IO
// cell (FAST_OUTPUT_REGISTER is set on SDRAM2_* by sys_dual_sdram.tcl).
//
// ---------------------------------------------------------------------------
// DUAL_SDRAM = 0
// ---------------------------------------------------------------------------
// Everything degenerates to the 16-bit controller: original addressing
// (unit = word address), no lane masking, no second read command, walker
// writes back to their two-CAS form, and the fill port takes two slots of
// four words (two beats per longword) instead of one.  In that mode this
// module is cycle- and bit-identical to sdram_ctrl on every original port,
// which is what tb_sdram32 asserts against the real sdram_ctrl.
//
//////////////////////////////////////////////////////////////////////////////

module sdram32_ctrl
#(
	// CPU_CACHE 0 removes this controller's cpu_cache_new storage: the CPU's
	// own ap040_cache becomes the only cache, and this instance keeps just
	// the fill/pass protocol.  Left at 1 by default so the existing
	// controller benches still exercise the cached path.
	parameter CPU_CACHE = 1,
	// DUAL_SDRAM 1 drives the io-board's second SDRAM as the upper half of a
	// 32-bit bus.  0 builds the plain 16-bit controller (boards without the
	// second module), at half the line-fill rate.
	parameter DUAL_SDRAM = 1
)
(
	// system
	input             sysclk,
	input             c_7m,
	input             reset_n,
	input             cache_rst,
	input             cache_inhibit,
	input       [3:0] cpu_cache_ctrl,
	// sdram #1 (primary): D[15:0] of every longword
	output reg [12:0] sd_addr,
	output reg  [1:0] sd_ba,
	output reg        sd_cs,
	output reg        sd_we,
	output reg        sd_ras,
	output reg        sd_cas,
	output reg  [1:0] sd_dqm,
	inout      [15:0] sd_data,
	output reg        sd_clk,
	output            sd_cke,
	// sdram #2 (secondary): D[31:16] of every longword
	output     [12:0] sd2_addr,
	output      [1:0] sd2_ba,
	output reg        sd2_cs,
	output            sd2_we,
	output            sd2_ras,
	output            sd2_cas,
	output reg  [1:0] sd2_dqm,
	inout      [15:0] sd2_data,
	output            sd2_clk,
	output            sd2_cke,
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
	output reg [31:0] walker_rdata,

	// 32-bit cache line fill port (16 byte line, 4 longword beats).
	// fill_req is level held until fill_ack; fill_addr must stay stable
	// while it is asserted.  fill_strb pulses once per delivered longword,
	// beats ascending within the line, and fill_ack pulses with the last.
	input             fill_req,
	input      [24:4] fill_addr,
	output reg [31:0] fill_dat,
	output reg        fill_strb,
	output reg        fill_ack
);

assign sd_cke  = 1;
assign sd2_cke = 1;

// Command lockstep: one source, two pin groups (see header).
assign sd2_addr = sd_addr;
assign sd2_ba   = sd_ba;
assign sd2_we   = sd_we;
assign sd2_ras  = sd_ras;
assign sd2_cas  = sd_cas;
assign sd2_clk  = sd_clk;

//// parameters ////
localparam [2:0]
	IDLE = 0,
	CHIP = 1,
	CPU_READCACHE = 2,
	CPU_WRITECACHE = 3,
	WALKER_READ = 4,
	WALKER_WRITE = 5,
	CPU_FILL = 6;

reg         cache_fill;
reg  [3:0]  initstate;
reg         init_done;
reg  [3:0]  sdram_state;
reg  [2:0]  slot_type = IDLE;
reg [15:0]  sdata_reg;
reg [15:0]  sdata_reg_q;
reg [15:0]  sdata2_reg;
reg         chipWE;

// data bus drivers.  The synthesizable inout-reg idiom of sdram_ctrl needs
// a source rewrite for Icarus (tests/ap040/prepare_sdram_sim.py); an
// explicit output enable is legal for both tools and needs no rewrite.
reg [15:0]  sd_dout;
reg         sd_doe;
reg [15:0]  sd2_dout;
reg         sd2_doe;
assign sd_data  = sd_doe  ? sd_dout  : 16'hZZZZ;
assign sd2_data = sd2_doe ? sd2_dout : 16'hZZZZ;


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

////////////////////////////////////////
// dual data path: beat holds and the
// 16-bit word rotation
////////////////////////////////////////

// Beat A (unit U, captured into sdata_reg/sdata2_reg at state 7) is held
// from state 8, beat B (unit U^1, captured at state 9) from state 10.  The
// state-8/state-10 bypasses let the delivery that happens ON those edges
// see the live capture registers instead of the hold that is being written
// in the same edge.
reg [15:0] hA_hi, hA_lo, hB_hi, hB_lo;
always @ (posedge sysclk) begin
	if (sdram_state == 4'd8)  begin hA_hi <= sdata2_reg; hA_lo <= sdata_reg; end
	if (sdram_state == 4'd10) begin hB_hi <= sdata2_reg; hB_lo <= sdata_reg; end
end

wire [15:0] bA_hi = (sdram_state == 4'd8)  ? sdata2_reg : hA_hi;
wire [15:0] bA_lo = (sdram_state == 4'd8)  ? sdata_reg  : hA_lo;
wire [15:0] bB_hi = (sdram_state == 4'd10) ? sdata2_reg : hB_hi;
wire [15:0] bB_lo = (sdram_state == 4'd10) ? sdata_reg  : hB_lo;

// cas_rot = addr[2:1] of the slot's 16-bit requester: bit 1 says which unit
// of the aligned 8-byte block arrived as beat A, bit 0 is the lane.
reg [1:0] cas_rot;

// the four words of the block, in ascending block order
wire [15:0] dw0 = (cas_rot[1] == 1'b0) ? bA_hi : bB_hi;
wire [15:0] dw1 = (cas_rot[1] == 1'b0) ? bA_lo : bB_lo;
wire [15:0] dw2 = (cas_rot[1] == 1'b1) ? bA_hi : bB_hi;
wire [15:0] dw3 = (cas_rot[1] == 1'b1) ? bA_lo : bB_lo;

// ... delivered in the wrapped burst order the 16-bit controller produced
wire [1:0] j0 = cas_rot;
wire [1:0] j1 = cas_rot + 2'd1;
wire [1:0] j2 = cas_rot + 2'd2;
wire [1:0] j3 = cas_rot + 2'd3;
wire [15:0] dsel0 = (j0 == 2'd0) ? dw0 : (j0 == 2'd1) ? dw1 : (j0 == 2'd2) ? dw2 : dw3;
wire [15:0] dsel1 = (j1 == 2'd0) ? dw0 : (j1 == 2'd1) ? dw1 : (j1 == 2'd2) ? dw2 : dw3;
wire [15:0] dsel2 = (j2 == 2'd0) ? dw0 : (j2 == 2'd1) ? dw1 : (j2 == 2'd2) ? dw2 : dw3;
wire [15:0] dsel3 = (j3 == 2'd0) ? dw0 : (j3 == 2'd1) ? dw1 : (j3 == 2'd2) ? dw2 : dw3;

// fill data for cpu_cache_new: same pipeline depth as sdata_reg_q, so the
// cache's four acknowledges are unchanged in timing.
reg [15:0] cfill_dat;
wire [15:0] cache_dat_r = DUAL_SDRAM ? cfill_dat : sdata_reg_q;

cpu_cache_new #(.CACHE_ENABLE(CPU_CACHE)) cpu_cache
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
	.sdr_dat_r        (cache_dat_r),           // sdram read data (registered)
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
			 8: begin cache_fill <= 1; cfill_dat <= dsel0; end
			10: begin cache_fill <= 1; cfill_dat <= dsel1; end
			12: begin cache_fill <= 1; cfill_dat <= dsel2; end
			14: begin cache_fill <= 1; cfill_dat <= dsel3; end
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
			 9: chipRD   <= DUAL_SDRAM ? dsel0 : sdata_chip;
			11: chip48_1 <= DUAL_SDRAM ? dsel1 : sdata_chip;
			13: chip48_2 <= DUAL_SDRAM ? dsel2 : sdata_chip;
			15: chip48_3 <= DUAL_SDRAM ? dsel3 : sdata_chip;
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

// One-cycle pre-decodes of the state selects that feed SDRAM pin
// registers and the cache snoop cone.  next_sdram_state mirrors the
// counter including the 7MHz resync, so every flag is exact even on the
// cycle the counter is yanked back to zero.
reg        old_7m_q;
reg        ras_go;          // high during state 0
reg        cas2_go;         // high during state 4 (slots with a second command)
always @ (posedge sysclk) old_7m_q <= c_7m;
wire [3:0] next_sdram_state = (~old_7m_q & c_7m) ? 4'd0 : (sdram_state + 4'd1);
always @ (posedge sysclk) begin
	ras_go         <= (next_sdram_state == 4'd0);
	cas2_go        <= (next_sdram_state == 4'd4);
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
// cache, line fill) are all level-held registers, so they are arbitrated
// one cycle EARLY (state 15) into staging registers.  The state-0 row-
// address load then muxes through a single select instead of the full
// request/address cones -- the recurring sd_addr[7/8] setup violators
// (walker_req_q/init_done/state-dups into the row mux) get a whole cycle
// of their own.  The chipset keeps absolute priority, still sampled AT
// state 0: when it steals the slot the staged local grant is simply
// discarded and retried next CCK (level-held, no loss).  A request first
// asserting during state 15/0 waits one CCK.
localparam [2:0] PRE_NONE = 3'd0, PRE_WRITE = 3'd1,
                 PRE_WALKER = 3'd2, PRE_CACHE = 3'd3, PRE_FILL = 3'd4;

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

// line fill port state.  fill_slot marks the slot currently delivering, so
// the 16-bit mode's second half is not re-arbitrated into its own slot;
// fill_more is the "another slot is needed" flag that mode sets.
reg        fill_started;
reg        fill_more;
reg        fill_slot;
reg  [2:0] fill_cnt;
reg [15:0] fill_hi16;
reg        fill_req_q;
wire       fill_want = fill_req && (!fill_started || fill_more) && !fill_slot;
always @(posedge sysclk) begin
	if (!reset_n) fill_req_q <= 1'b0;
	else          fill_req_q <= fill_want;
end

// Unit (= command) addresses.  In dual mode one command address covers a
// whole longword, so the word-address LSB drops out of the command and
// becomes the lane select; in 16-bit mode the mapping is the original one.
wire [23:0] chip_unit   = DUAL_SDRAM ? {1'b0, chipAddr[24:2]}       : chipAddr[24:1];
wire [23:0] write_unit  = DUAL_SDRAM ? {1'b0, writeAddr[24:2]}      : writeAddr[24:1];
wire [23:0] walker_unit = DUAL_SDRAM ? {1'b0, walker_addr[24:2]}    : {walker_addr, 1'b0};
wire [23:0] cache_unit  = DUAL_SDRAM ? {1'b0, cache_addr_lat[24:2]} : cache_addr_lat[24:1];
// 16-bit mode fetches the line in two 4-word halves; fill_started selects
// which half is being requested.
wire [23:0] fill_unit   = DUAL_SDRAM ? {1'b0, fill_addr[24:4], 2'b00}
                                     : {fill_addr[24:4], fill_started, 2'b00};

reg  [2:0] pre_sel;
reg  [1:0] pre_ba;
reg [12:0] pre_row;
reg  [9:0] pre_col;
reg  [1:0] pre_rot;
always @(posedge sysclk) begin
	if (!reset_n) begin
		pre_sel <= PRE_NONE;
	end
	else if (sdram_state == 4'd15) begin
		if (!init_done)
			pre_sel <= PRE_NONE;
		else if (write_req) begin
			pre_sel <= PRE_WRITE;
			{pre_ba, pre_row, pre_col[8:0]} <= write_unit;
			pre_rot <= writeAddr[2:1];
		end
		else if (!walker_busy && walker_req_q) begin
			pre_sel <= PRE_WALKER;
			{pre_ba, pre_row, pre_col[8:0]} <= walker_unit;
			pre_rot <= 2'b00;
		end
		else if (cache_req && cache_req_q2) begin
			pre_sel <= PRE_CACHE;
			{pre_ba, pre_row, pre_col[8:0]} <= cache_unit;
			pre_rot <= cache_addr_lat[2:1];
		end
		else if (fill_req_q) begin
			pre_sel <= PRE_FILL;
			{pre_ba, pre_row, pre_col[8:0]} <= fill_unit;
			pre_rot <= 2'b00;
		end
		else
			pre_sel <= PRE_NONE;
	end
end

wire chip_steals = (~chipDMA) | (~chipRW);

wire walker_grant = (sdram_state == 4'd0) && (pre_sel == PRE_WALKER) && !chip_steals;
wire fill_grant   = (sdram_state == 4'd0) && (pre_sel == PRE_FILL)   && !chip_steals;

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
			// dual mode: the whole longword arrives as one beat, so the two
			// halves come out of the beat-A hold.  16-bit mode keeps the
			// original two-word assembly through the pipe registers.
			if (sdram_state == 4'd10) begin
				walker_read_hi <= DUAL_SDRAM ? hA_hi : walker_sdata_pipe2;
				if (DUAL_SDRAM) walker_read_lo <= hA_lo;
			end
			if (!DUAL_SDRAM && sdram_state == 4'd12)
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

// line fill delivery.  Dual: one 4-unit burst, one longword per beat at the
// same states the cache fill uses.  16-bit: four words per slot, assembled
// into two longwords, two slots per line.
always @(posedge sysclk) begin
	if (!reset_n) begin
		fill_started <= 0;
		fill_more    <= 0;
		fill_slot    <= 0;
		fill_cnt     <= 0;
		fill_strb    <= 0;
		fill_ack     <= 0;
		fill_dat     <= 0;
	end
	else begin
		fill_strb <= 0;
		fill_ack  <= 0;

		if (!fill_req) begin
			fill_started <= 0;
			fill_more    <= 0;
			fill_slot    <= 0;
			fill_cnt     <= 0;
		end
		else begin
			if (fill_grant) begin
				fill_slot    <= 1;
				fill_started <= 1;
				fill_more    <= DUAL_SDRAM ? 1'b0 : ~fill_started;
			end
			// released early enough for the 16-bit mode's second half to be
			// pre-arbitrated at state 15 of the same CCK
			if (sdram_state == 4'd12) fill_slot <= 0;

			if (init_done && slot_type == CPU_FILL) begin
				if (DUAL_SDRAM) begin
					case (sdram_state)
						8, 10, 12, 14: begin
							fill_dat  <= {sdata2_reg, sdata_reg};
							fill_strb <= 1;
							fill_cnt  <= fill_cnt + 1'd1;
							if (fill_cnt == 3'd3) fill_ack <= 1;
						end
					endcase
				end
				else begin
					case (sdram_state)
						8, 12: fill_hi16 <= sdata_reg;
						10, 14: begin
							fill_dat  <= {fill_hi16, sdata_reg};
							fill_strb <= 1;
							fill_cnt  <= fill_cnt + 1'd1;
							if (fill_cnt == 3'd3) fill_ack <= 1;
						end
					endcase
				end
			end
		end
	end
end

// slot qualifiers latched with the slot decode at state 0 (valid from state
// 1, i.e. well before the state-2 and state-4 command edges use them)
reg        slot_cas2;      // this slot issues a second command at state 4
reg        slot_cas2_we;   // ... and that command is a write (walker, 16-bit)
reg [15:0] datawr2;

reg        cas_sd_cas;
reg        cas_sd_we;
reg  [1:0] cas_dqm;
reg  [1:0] cas_dqm2;
reg [15:0] datawr;
reg  [9:0] casaddr;
reg  [3:0] rcnt;

always @ (posedge sysclk) begin

	sd_clk <= sdram_state[0];

	if(~sdram_state[0]) begin
		sd_ras                <= 1;
		sd_cas                <= 1;
		sd_we                 <= 1;
		sd_doe                <= 0;
		sd2_doe               <= 0;
		chipWE                <= 0;
	end

	if(sdram_state[0]) begin
		sdata_reg  <= sd_data;
		sdata2_reg <= sd2_data;
	end

	if(!init_done) begin
		slot_type             <= IDLE;
		casaddr               <= 0;
		rcnt                  <= 0;
		sd_dqm                <= 3;
		sd2_dqm               <= 3;
		sd_ba                 <= 0;
		sd_cs                 <= 0;
		sd2_cs                <= 0;
		slot_cas2             <= 0;
		slot_cas2_we          <= 0;
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

			// RAS, CAS and the second command are keyed on the one-cycle
			// pre-decoded ras_go/cas_go/cas2_go flags in the blocks below
			// the case, so the sd_* pin registers see single-signal selects
			// instead of 4-bit state compares
			2 : write_ack <= 0; // safe to accept the next write
		endcase

		// RAS slot arbitration (state 0)
		if (ras_go) begin
				cas_sd_cas      <= 1;
				cas_sd_we       <= 1;
				cas_dqm         <= 0;
				cas_dqm2        <= 0;
				sd_dqm          <= 3;
				sd2_dqm         <= 3;
				sd_cs           <= 0;
				sd2_cs          <= 0;
				slot_type       <= IDLE;
				slot_cas2       <= 0;
				slot_cas2_we    <= 0;
				cas_rot         <= 2'b00;

				if(~&rcnt) rcnt <= rcnt + 1'd1;

				// we give the chipset first priority
				// (this includes anything on the "motherboard" - chip RAM, slow RAM and Kickstart, turbo modes notwithstanding)
				if(~chipDMA | ~chipRW) begin
					slot_type    <= CHIP;
					{sd_ba,sd_addr,casaddr[8:0]} <= chip_unit;
					sd_ras       <= 0;
					cas_dqm      <= {chipU,chipL};
					cas_dqm2     <= {chipU,chipL};
					cas_sd_cas   <= 0;
					cas_sd_we    <= chipRW;
					datawr       <= chipWR;
					datawr2      <= chipWR;
					chipWE       <= !chipRW;
					cas_rot      <= chipAddr[2:1];
					// dual reads need the partner unit for chip48
					slot_cas2    <= DUAL_SDRAM && chipRW;
					// a 16-bit write touches one lane: mask the other chip
					// for the whole slot, ACTIVE included
					if (DUAL_SDRAM && !chipRW) begin
						sd_cs    <= ~chipAddr[1];
						sd2_cs   <=  chipAddr[1];
						cas_dqm  <= chipAddr[1] ? {chipU,chipL} : 2'b11;
						cas_dqm2 <= chipAddr[1] ? 2'b11 : {chipU,chipL};
					end
				end
				else if(pre_sel == PRE_WRITE) begin
					slot_type    <= CPU_WRITECACHE;
					{sd_ba,sd_addr,casaddr[8:0]} <= {pre_ba, pre_row, pre_col[8:0]};
					sd_ras       <= 0;
					cas_dqm      <= write_dqm;
					cas_dqm2     <= write_dqm;
					cas_sd_we    <= 0;
					cas_sd_cas   <= 0;
					write_ack    <= 1; // let the write buffer know we're about to write
					datawr       <= writeDat;
					datawr2      <= writeDat;
					cas_rot      <= pre_rot;
					if (DUAL_SDRAM) begin
						sd_cs    <= ~pre_rot[0];
						sd2_cs   <=  pre_rot[0];
						cas_dqm  <= pre_rot[0] ? write_dqm : 2'b11;
						cas_dqm2 <= pre_rot[0] ? 2'b11 : write_dqm;
					end
				end
				else if(pre_sel == PRE_WALKER) begin
					slot_type    <= walker_we ? WALKER_WRITE : WALKER_READ;
					{sd_ba,sd_addr,casaddr[8:0]} <= {pre_ba, pre_row, pre_col[8:0]};
					sd_ras       <= 0;
					cas_dqm      <= 0;
					cas_dqm2     <= 0;
					cas_sd_cas   <= 0;
					cas_sd_we    <= ~walker_we;
					// dual: both halves go out with the single command.
					// 16-bit: high word now, low word at the second CAS.
					datawr       <= DUAL_SDRAM ? walker_wdata[15:0] : walker_wdata[31:16];
					datawr2      <= walker_wdata[31:16];
					slot_cas2    <= !DUAL_SDRAM && walker_we;
					slot_cas2_we <= !DUAL_SDRAM && walker_we;
				end
				// request from read cache
				else if(pre_sel == PRE_CACHE) begin
					slot_type    <= CPU_READCACHE;
					{sd_ba,sd_addr,casaddr[8:0]} <= {pre_ba, pre_row, pre_col[8:0]};
					sd_ras       <= 0;
					cas_sd_cas   <= 0;
					cas_rot      <= pre_rot;
					slot_cas2    <= DUAL_SDRAM ? 1'b1 : 1'b0;
				end
				// 32-bit line fill
				else if(pre_sel == PRE_FILL) begin
					slot_type    <= CPU_FILL;
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

		// Second command of the slot, at state 4 (tCCD=1 on SDR makes
		// back-to-back commands two states apart legal):
		//  - 16-bit walker write: the low word needs its own single-write
		//    CAS to column+1 (the mode word sets A9, so a data beat after
		//    the CAS cycle is IGNORED by the chip),
		//  - dual chipset/cache read: the partner unit of the aligned
		//    8-byte block, truncating the first burst after its first beat.
		// The address is the same in both cases: column with its LSB
		// flipped.  A10/auto-precharge rides on THIS command; the first one
		// held the row open (auto-precharging on the first command would
		// put the bank into precharge under the second -- undefined on
		// real silicon).
		if (cas2_go && slot_cas2) begin
				sd_addr      <= {1'b1, casaddr[9:1], ~casaddr[0]};
				sd_cas       <= 0;
				sd_dqm       <= 0;
				sd2_dqm      <= 0;
				if (slot_cas2_we) begin
					sd_we    <= 0;
					sd_dout  <= walker_wdata_latch[15:0];
					sd_doe   <= 1;
					sd2_dout <= walker_wdata_latch[15:0];
					sd2_doe  <= 1;
				end
		end


		// CAS: all qualifiers (cas_sd_cas/cas_sd_we/cas_dqm/casaddr/
		// datawr) are registers latched at the RAS state, so with the
		// pre-decoded flag every sd_* pin-register input cone is one
		// LUT deep.  Placed after the case: overrides the even-state
		// deasserts exactly like the original arm did.
		if (cas_go) begin
			sd_addr         <= {!slot_cas2, casaddr}; // A10: AUTO PRECHARGE
			sd_cas          <= cas_sd_cas;
			sd_dqm          <= 0;
			sd2_dqm         <= 0;
			if(!cas_sd_we) begin
				sd_dout      <= datawr;
				sd_doe       <= 1;
				sd2_dout     <= datawr2;
				sd2_doe      <= 1;
				sd_addr[12:11]<= cas_dqm;
				sd_dqm       <= cas_dqm;
				sd2_dqm      <= cas_dqm2;
				sd_we        <= 0;
			end
		end
	end
end

endmodule
