//--------------------------------------------------------------------------//
//--------------------------------------------------------------------------//
//                                                                          //
// Copyright (c) 2009-2011 Tobias Gubener                                   //
// Copyright (c) 2017-2019 Alexey Melnikov                                  //
// Subdesign fAMpIGA by TobiFlex                                            //
//                                                                          //
// This is the cpu wrapper to generate 68K Bus signals                      //
// and configure Zorro cards                                                //
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
//--------------------------------------------------------------------------//
//--------------------------------------------------------------------------//

module cpu_wrapper
#(
	// A missing target must eventually produce a 68040 bus error, but chip
	// RAM can legitimately wait thousands of clk_sys cycles for a DMA slot.
	// cpu_wrapper.clk is clk_sys (28.6875 MHz), so 2^20 clocks is about 36.6 ms
	// and comfortably separates the two.
	parameter BUS_TIMEOUT_BITS = 20
)
(
	input             reset,
	output reg        reset_out,

	input             clk,
	input             ph1,
	input             ph2,

	input       [1:0] cpucfg,
	input       [2:0] fastramcfg,
	input       [2:0] cachecfg,
	input             bootrom,

	output reg [23:1] chip_addr,
	input      [15:0] chip_dout,
	output reg [15:0] chip_din,
	output reg        chip_as,
	output reg        chip_uds,
	output reg        chip_lds,
	output reg        chip_rw,
	input             chip_dtack,
	input       [2:0] chip_ipl,
	
	input      [15:0] fastchip_dout,
	output reg        fastchip_sel,
	output            fastchip_lds,
	output            fastchip_uds,
	output            fastchip_rnw,
	output reg        fastchip_lw,
	input             fastchip_selack,
	input             fastchip_ready,

	output            ramsel,
	output     [28:1] ramaddr,

	// 32-bit line fill port, forwarded to ram1 (sdram32_ctrl).  See the
	// fill_ok comment below for why only part of the map can use it.
	output            fill_req,
	output     [24:4] fill_addr,
	output      [1:0] fill_bsel,
	input             fill_avail,   // an ap040_fill_cdc + ported controller exist
	input     [127:0] fill_line,
	input             fill_done,
	output     [15:0] ramdin,
	input      [15:0] ramdout,
	input             ramready,
	output            ramlds,
	output            ramuds,
	output            ramshared,
	// One-CPU-clock strobe: the CPU sampled ramready high for an active
	// RAM request on this edge, i.e. the level acknowledgement has been
	// consumed.  ram_cs_guard keys its deselect on this instead of
	// guessing the consumption point from a clock-phase marker.
	output reg        ramconsumed,

	// Dedicated AP040 physical table-walk channel.  Addresses are already
	// encoded for the SDRAM/DDR3 controllers; walker_mem_ddr selects the bank.
	output            walker_mem_req,
	output            walker_mem_we,
	output     [28:2] walker_mem_addr,
	output     [31:0] walker_mem_wdat,
	output            walker_mem_ddr,
	output            walker_mem_bad,
	input             walker_mem_ack,
	input      [31:0] walker_mem_rdata,
	input             walker_mem_berr,

	output            toccata_ena,
	output reg  [7:0] toccata_base,

	output            a2065_ena,
	output reg  [7:0] a2065_base,


	output reg  [1:0] cpustate,
	output reg  [3:0] cacr,
	// MMU cache-inhibit attribute of the current access (TTR CM or page
	// descriptor CM); the external caches must not retain such data.
	output            cache_inhibit,
	// Chipset-DMA write snoop from the RAM controller (clk_114 domain).
	// snoop_tgl flips once per write with snoop_adr held; this crosses it
	// into the CPU clock so ap040_cache can invalidate the line.
	input             snoop_tgl,
	input      [24:1] snoop_adr,
	output            nmi_ack_toggle,
	output reg [31:0] nmi_addr
);

assign ramsel       = cpu_req & ~sel_nmi_vector & (sel_zram | sel_chipram | sel_kickram | sel_dd | sel_rtg);
assign ramshared    = sel_dd;

// NMI
always @(posedge clk) nmi_addr <= vbr + 32'h7c;

// declared here so they precede the ap040 instance; driven further down,
// beside turbochip_d/dcache_d which the decode needs
wire        fill_req_c;
wire [31:0] fill_addr_c;
wire        fill_instr_c;
wire        fill_cchip;
wire        fill_ok;
wire        fill_busy;

wire sel_z3ram0 = (cpu_addr[31:27] == z3ram_base0) && z3ram_ena0;
wire sel_z3ram1 = (cpu_addr[31:28] == z3ram_base1) && z3ram_ena1;
wire sel_z2ram  = !cpu_addr[31:24] && (cpu_addr[23] ^ |cpu_addr[22:21]) && z2ram_ena; // addr[23:21] = 1..4
wire sel_zram   = sel_z3ram0 | sel_z3ram1 | sel_z2ram;
wire sel_dd     = (cpu_addr[31:16] == 16'h00DD) && (cpu_addr[15:13] == 'b010);
wire sel_rtg    = (cpu_addr[31:24] == 8'h02);

// don't sel_kickram when writing
wire sel_kickram   = !cpu_addr[31:24] && (&cpu_addr[23:19] || (cpu_addr[23:19] == 5'b11100)) && ckick && wr;	// $f8xxxx, e0xxxx
wire sel_kicklower = !cpu_addr[31:24] && (cpu_addr[23:18] == 6'b111110);
wire sel_chipram   = !cpu_addr[31:21] && cchip; 		             //$000000 - $1FFFFF

// we route everything hrtmon related through cart.v (needs a couple of signals to
// decide what to do, would not be good style to replicate that here). 
wire sel_nmi_vector = (cpu_addr[31:2] == nmi_addr[31:2]) && (cpustate == 2);

wire [15:0] ramdat;

assign ramlds = sel_rtg ? uds_in : lds_in;
assign ramuds = sel_rtg ? lds_in : uds_in;
assign ramdin = sel_rtg ? {cpu_dout[7:0],cpu_dout[15:8]} : cpu_dout;
assign ramdat = sel_rtg ? {ramdout[7:0], ramdout[15:8]}  : ramdout;

//       Main  DDx  RTG  8M  128M  256M
//       ----  ---  ---  --  ----  ----
//        SDR  DDR  RTG  Z2  Z3_0  Z3_1
// 28      0    0    0   1    0     1
// 27      0    0    0   1    1     X
// 26      0    1    1   0    X     X
// 25-23   0   111  110  0    X     X
// supported configs: SDR + (Z2, Z3_1, Z3_0+Z3_1)

// This is the mapping to the sram
// map 00-1f to 00-1f (chipram), a0-ff to 20-7f. All non-fastram goes into the first
// 8M block(SDRAM). This map should be the same as in minimig_sram_bridge.v 
// All Zorro RAM goes to DDR3
assign ramaddr[28]    = sel_zram & ~sel_z3ram0;
assign ramaddr[27]    = sel_zram & (~sel_z3ram1 | cpu_addr[27]);
assign ramaddr[26:23] = (sel_z3ram0 | sel_z3ram1) ? cpu_addr[26:23]: (sel_rtg ? 4'b1110 : {4{sel_dd}});
assign ramaddr[22:19] = {4{sel_dd}} | cpu_addr[22:19];
assign ramaddr[18]    =    sel_dd   | (sel_kicklower & bootrom) | cpu_addr[18];
assign ramaddr[17:16] = {2{sel_dd}} | cpu_addr[17:16];
assign ramaddr[15:1]  = cpu_addr[15:1];

assign fastchip_lds = lds_in;
assign fastchip_uds = uds_in;
assign fastchip_rnw = wr;

reg  [31:0] cpu_addr;
reg  [15:0] cpu_dout;
wire [15:0] cpu_din = ramsel ? ramdat : fastchip_selack ? fastchip_dout : {sel_autoconfig ? autocfg_data : chip_data[15:12], chip_data[11:0]};
reg         wr;
reg         uds_in;
reg         lds_in;
reg  [15:0] chip_data;
reg  [31:0] vbr;

// AP040 is the only CPU path; cpucfg keeps its OSD meaning for the
// turbo chipram/kickstart gating and autoconfig defaults below.
always @* begin
	cpu_dout     = cpu_dout_p;
	cpu_addr     = cpu_addr_p;
	cpustate     = cpustate_p;
	// 040 CACR: bit 15 enables the instruction cache, bit 31 the data
	// cache.  The external cache takes them separately (bit 0 = I, 1 = D).
	cacr         = {cache_clear_toggle, 1'b0, cacr_p[31], cacr_p[15]};
	vbr          = vbr_p;
	wr           = wr_p;
	uds_in       = uds_p;
	lds_in       = lds_p;
	reset_out    = reset_out_p;
	chip_as      = c_as;
	chip_rw      = c_rw;
	chip_uds     = c_uds;
	chip_lds     = c_lds;
	chip_addr    = cpu_addr_p[23:1];
	chip_din     = cpu_dout_p;
	chip_data    = chipdout_i;
	fastchip_sel = cpu_req & !cpu_addr_p[31:24];
	fastchip_lw  = longword;
end

wire [15:0] cpu_dout_p;
wire [31:0] cpu_addr_p;
wire  [1:0] cpustate_p;
wire [31:0] cacr_p;
wire [31:0] vbr_p;
wire        wr_p;
wire        uds_p;
wire        lds_p;
wire        reset_out_p;
wire        longword;
wire        walker_req_p, walker_we_p;
wire [31:0] walker_addr_p, walker_wdat_p;
wire        cache_maint_p;
reg         cache_maint_d;
reg         cache_clear_toggle;
wire        bus_berr;
wire        bus_complete = chipready | ramready | fastchip_ready;

// Level-acknowledge consumption strobe for ram_cs_guard: exactly the edge
// where the qualified clock advances a waiting RAM transaction.
always @(posedge clk) begin
	if (~reset) ramconsumed <= 0;
	else        ramconsumed <= cpu_req & ramsel & ramready;
end

// Snoop CDC.  A chipset write happens at most once per CCK, i.e. every
// four CPU clocks, so a two-flop synchroniser on the toggle plus one
// cycle to act keeps up without a queue.  The address is held by the
// producer until the next write, so it is stable when the toggle arrives.
reg  [2:0] snoop_tgl_s;
reg        snoop_stb_r;
reg [31:0] snoop_addr_r;
always @(posedge clk) begin
	if (!reset) begin
		snoop_tgl_s <= 0;
		snoop_stb_r <= 0;
	end
	else begin
		snoop_tgl_s <= {snoop_tgl_s[1:0], snoop_tgl};
		snoop_stb_r <= snoop_tgl_s[2] ^ snoop_tgl_s[1];
		if (snoop_tgl_s[2] ^ snoop_tgl_s[1])
			snoop_addr_r <= {7'd0, snoop_adr, 1'b0};
	end
end

ap040_tg68k_compat #(
	// Internal caches ON.  Their storage is block RAM by construction
	// (ap040_cache.v: explicit dpram tag row, inferred cdata ways), so the
	// pair of 4KB caches costs 283 ALMs and 13 M10K -- the ATC's own move
	// into block RAM is what made the room.  The timing objection that
	// kept them off is fixed at the source: the cache no longer forwards a
	// bypassed access combinationally in C_IDLE, which had put the ATC
	// compare in front of the core's exception-format mux (see the
	// pass_active comment there).  Measured worth on loop-heavy code:
	// 1.41x with a zero-latency bus, 2.27x with a latent one, and near
	// immunity to bus latency (tests/ap040/asm/bench_loop.s under +prof).
	.AP040_ENABLE_CACHE(1),
	// FPU hardware subset (milestone H): FMOVE all formats, FMOVEM,
	// FADD/FSUB/FMUL/FDIV/FSQRT/FABS/FNEG/FCMP/FTST with IEEE rounding;
	// unimplemented ops trap to the FPSP route like real 040 silicon
	.AP040_HAS_FPU(1)
) cpu_inst_p
(
	.clk(clk),
	.nreset(reset),
	.clkena_in(~cpu_req | bus_complete | bus_berr | fill_busy),
	.cache_allow_all(1'b0),
	.cache_snoop_stb(snoop_stb_r),
	.cache_snoop_addr(snoop_addr_r),
	.cache_z2_ena(z2ram_ena),
	.cache_z3_base0(z3ram_base0),
	.cache_z3_ena0(z3ram_ena0),
	.cache_z3_base1(z3ram_base1),
	.cache_z3_ena1(z3ram_ena1),
	.data_in(cpu_din),
	.ipl(cpu_ipl),
	.ipl_autovector(1'b1),
	.berr(bus_berr),

	.addr_out(cpu_addr_p),
	.data_write(cpu_dout_p),
	.nwr(wr_p),
	.nuds(uds_p),
	.nlds(lds_p),
	.busstate(cpustate_p),		// 0: fetch code, 1: no memaccess, 2: read data, 3: write data
	.longword(longword),
	.nresetout(reset_out_p),
	.fc(),
	.nmi_ack_toggle(nmi_ack_toggle),
	.cache_maint_req(cache_maint_p),
	.cache_maint_ic(),
	.cache_maint_dc(),

	// MMU and dedicated physical table-walker sideband
	.mmu_addr_log(),
	.mmu_addr_phys(),
	.mmu_cache_inhibit(cache_inhibit),
	.walker_req(walker_req_p),
	.walker_we(walker_we_p),
	.walker_addr(walker_addr_p),
	.walker_wdat(walker_wdat_p),
	.walker_ack(walker_mem_ack),
	.walker_data(walker_mem_rdata),
	.walker_berr(walker_mem_berr),
	.cache_req(),
	.cache_addr(),
	.cache_data(16'd0),
	.cache_ack(1'b0),
	.fill_req(fill_req_c),
	.fill_addr(fill_addr_c),
	.fill_bsel(fill_bsel),
	.fill_instr(fill_instr_c),
	.fill_busy(fill_busy),
	.fill_ok(fill_ok),
	.fill_line(fill_line),
	.fill_done(fill_done),
	.cache_ramaddr(),

	.cacr_out(cacr_p),
	.vbr_out(vbr_p),
	.debug_busy(),
	.debug_fault(),
	.debug_halted(core_halted),
	.debug_status(core_dbgstat),
	.debug_status2(core_dbgstat2)
);

wire cpu_req = (cpustate != 1);

// Convert the core's level handshake into a toggle.  The RAM controllers
// may be in another clock domain and/or busy when CINV/CPUSH executes; a
// stable toggle cannot be lost the way a one-cycle clear pulse can.
always @(posedge clk) begin
	if (!reset) begin
		cache_maint_d      <= 0;
		cache_clear_toggle <= 0;
	end
	else begin
		cache_maint_d <= cache_maint_p;
		if (cache_maint_p && !cache_maint_d)
			cache_clear_toggle <= ~cache_clear_toggle;
	end
end

// Keep berr asserted until the bus adapter has sampled it on a qualified
// edge and released cpu_req; this avoids a narrow pulse at exactly the point
// where clkena_in was previously stalled.
ap040_bus_timeout #(.COUNTER_BITS(BUS_TIMEOUT_BITS)) bus_timeout (
	.clk(clk),
	.nreset(reset && reset_out_p),
	.req(cpu_req),
	.complete(bus_complete),
	.berr(bus_berr)
);

//--------------------------------------------------------------------------//
// Halt post-mortem beacon                                                  //
//                                                                          //
// fatal_halt (a fault taken while processing another fault -- a double     //
// bus fault) clears mem_req and parks the core in S_HALT.  Because every   //
// bus watchdog counts only while a request is ASSERTED, a halted core is   //
// invisible to all of them: the machine simply goes silent, which is the   //
// live NetBSD signature (all interrupts dead, zero memory movement, and    //
// no exception frame ever stacked because the second fault is exactly what //
// could not be stacked).                                                   //
//                                                                          //
// The core is halted, so the table-walker port is permanently idle and can //
// be borrowed.  On the halt edge, write a post-mortem record to a fixed    //
// physical address; the machine is already dead, so clobbering that memory //
// costs nothing, and the record is readable afterwards over /dev/mem.      //
// Layout at BEACON_ADDR: magic, PC, {IR,SR}, {state,fault}.                //
//--------------------------------------------------------------------------//
// The halt beacon is diagnostic instrumentation: it found the A7 shadow
// rollback bug (see 2035c49d) by writing the core's state to memory when
// fatal_halt fired.  Routing debug_status/debug_status2 across the design
// costs real timing (HDMI setup went negative on three consecutive fitter
// seeds with it in), so it is compiled out by default and switched on when
// a silent halt needs investigating again.
localparam HALT_BEACON = 0;

wire         core_halted;
wire [255:0] core_dbgstat;
wire [127:0] core_dbgstat2;
localparam [31:0] BEACON_ADDR = 32'h4000_0000;   // Z3_1 base (ARM 0x30000000)

reg         halted_d;
reg         beacon_active;
reg   [3:0] beacon_idx;
reg         beacon_req;
reg  [31:0] beacon_wdat;
reg  [31:0] beacon_addr;

always @(posedge clk) begin
	if (!reset) begin
		halted_d      <= 0;
		beacon_active <= 0;
		beacon_idx    <= 0;
		beacon_req    <= 0;
	end
	else begin
		halted_d <= core_halted;
		if (HALT_BEACON && core_halted && !halted_d) begin
			beacon_active <= 1;
			beacon_idx    <= 0;
			beacon_req    <= 0;
		end
		else if (beacon_active) begin
			if (!beacon_req) begin
				case (beacon_idx)
					4'd0: beacon_wdat <= 32'hA040_DEAD;
					4'd1: beacon_wdat <= core_dbgstat[31:0];      // PC
					4'd2: beacon_wdat <= {core_dbgstat[63:48],
					                      core_dbgstat[47:32]};   // IR, SR
					4'd3: beacon_wdat <= {16'd0,
					                      core_dbgstat[239:232],
					                      core_dbgstat[231:224]}; // flags,state
					// A7 identifies the stack the frame was being written
					// to when the second fault hit -- the single most
					// diagnostic value for a double fault taken during
					// exception stacking.
					4'd4: beacon_wdat <= core_dbgstat[95:64];     // A7
					4'd5: beacon_wdat <= core_dbgstat[223:192];   // A0
					4'd6: beacon_wdat <= core_dbgstat[127:96];    // D0
					4'd7: beacon_wdat <= core_dbgstat[159:128];   // D1
					// stack registers and the faulting address: these
					// separate "the stack switch failed" from "the
					// supervisor stack pointer was already wrong"
					4'd8:  beacon_wdat <= core_dbgstat2[127:96];  // fault addr
					4'd9:  beacon_wdat <= core_dbgstat2[95:64];   // USP
					4'd10: beacon_wdat <= core_dbgstat2[63:32];   // ISP
					4'd11: beacon_wdat <= core_dbgstat2[31:0];    // vec/flags
					default: beacon_wdat <= 32'd0;
				endcase
				beacon_addr <= BEACON_ADDR + {26'd0, beacon_idx, 2'b00};
				beacon_req  <= 1;
			end
			else if (walker_mem_ack) begin
				beacon_req <= 0;
				if (beacon_idx == 4'd11) beacon_active <= 0;
				else beacon_idx <= beacon_idx + 4'd1;
			end
		end
	end
end

// The beacon owns the walker port only while the core is halted, so it can
// never contend with a live table walk.
wire        beacon_own      = HALT_BEACON[0] & beacon_active;
wire        walker_req_eff  = beacon_own ? beacon_req  : walker_req_p;
wire        walker_we_eff   = beacon_own ? 1'b1        : walker_we_p;
wire [31:0] walker_addr_eff = beacon_own ? beacon_addr : walker_addr_p;
wire [31:0] walker_wdat_eff = beacon_own ? beacon_wdat : walker_wdat_p;

// Translate the walker's physical address to the same SDRAM/DDR3 bank map
// used by normal CPU traffic.  The MMU guarantees aligned longword accesses.
wire walker_sel_z3ram0 = (walker_addr_eff[31:27] == z3ram_base0) && z3ram_ena0;
wire walker_sel_z3ram1 = (walker_addr_eff[31:28] == z3ram_base1) && z3ram_ena1;
wire walker_sel_z2ram  = !walker_addr_eff[31:24] &&
					 (walker_addr_eff[23] ^ |walker_addr_eff[22:21]) && z2ram_ena;
wire walker_sel_zram   = walker_sel_z3ram0 | walker_sel_z3ram1 |
					 walker_sel_z2ram;
wire walker_sel_dd     = (walker_addr_eff[31:16] == 16'h00DD) &&
					 (walker_addr_eff[15:13] == 3'b010);
wire walker_sel_rtg    = (walker_addr_eff[31:24] == 8'h02);
wire walker_kicklower  = !walker_addr_eff[31:24] &&
					 (walker_addr_eff[23:18] == 6'b111110);
wire [28:1] walker_ramaddr;

assign walker_ramaddr[28]    = walker_sel_zram & ~walker_sel_z3ram0;
assign walker_ramaddr[27]    = walker_sel_zram &
					      (~walker_sel_z3ram1 | walker_addr_eff[27]);
assign walker_ramaddr[26:23] = (walker_sel_z3ram0 | walker_sel_z3ram1)
					      ? walker_addr_eff[26:23]
					      : (walker_sel_rtg ? 4'b1110 : {4{walker_sel_dd}});
assign walker_ramaddr[22:19] = {4{walker_sel_dd}} | walker_addr_eff[22:19];
assign walker_ramaddr[18]    = walker_sel_dd | (walker_kicklower & bootrom) |
					      walker_addr_eff[18];
assign walker_ramaddr[17:16] = {2{walker_sel_dd}} | walker_addr_eff[17:16];
assign walker_ramaddr[15:1]  = walker_addr_eff[15:1];

assign walker_mem_req  = walker_req_eff;
assign walker_mem_we   = walker_we_eff;
assign walker_mem_addr = walker_ramaddr[28:2];
assign walker_mem_wdat = walker_wdat_eff;
assign walker_mem_ddr  = |walker_ramaddr[28:26];
// High physical addresses are valid only when they decode as configured Z3
// RAM.  Misalignment indicates corrupt descriptor-table state.
// Valid table memory is Z2/Z3 RAM, the DD and RTG apertures, and the low
// 16M (which decodes as chip/slow/kick).  Anything else, or a misaligned
// descriptor address, indicates corrupt translation-table state.
assign walker_mem_bad  = (|walker_addr_eff[1:0]) |
					 ((|walker_addr_eff[31:24]) &&
					  !(walker_sel_zram | walker_sel_dd | walker_sel_rtg));

// ---------------------------------------------------------------------
// 32-bit line fill port routing.
//
// ram1 (sdram32_ctrl) is the only controller with the port, and Minimig.sv
// routes to it on zram_sel = |ram_addr[28:26] being LOW -- which after the
// ramaddr map above means chip and kick RAM.  ram2 (ddram_ctrl) serves Z2/Z3
// fast RAM, RTG and DD, and has no such port, so those must keep using the
// 16-bit path.
//
// Restricted further to CHIP RAM here.  It is the worst-measured region
// (22.0 clocks/long against FAST's 17.0), and it avoids sel_kickram's
// bootrom shadowing and its "not while writing" term, neither of which has
// an obvious meaning for a line fill and both of which would need their own
// argument.  Kick RAM is the natural follow-up once this is proven on
// hardware; FAST needs the port added to ddram_ctrl before it can join.
//
// cchip's (!cpustate | dcache_d) is mirrored with the fill's own instr flag:
// a fill is not a CPU bus cycle, so cpustate does not describe it.
assign fill_cchip = turbochip_d & (fill_instr_c | dcache_d);
assign fill_ok    = fill_avail && !fill_addr_c[31:21] && fill_cchip;

assign fill_req  = fill_req_c & fill_ok;
// chip RAM maps straight through: every ramaddr term above is zero for
// addr[31:21] == 0, so the line address needs no translation
assign fill_addr = fill_addr_c[24:4];

wire cchip = turbochip_d & (!cpustate | dcache_d);
wire ckick = turbokick_d & (!cpustate | dcache_d);

reg turbochip_d;
reg turbokick_d;
reg dcache_d;
always @(posedge clk) begin
	if (~reset | ~reset_out) begin
		turbochip_d <= 0;
		turbokick_d <= 0;
		dcache_d    <= 0;
	end
	else if (~cpu_req) begin	// No mem access, so safe to switch chipram access mode
		turbochip_d <= cachecfg[0] & cpucfg[1];
		turbokick_d <= cachecfg[1] & cpucfg[1];
		dcache_d    <= cachecfg[2];
	end
end

reg       chipreq;
// Initialized to IDLE (active-low: 111 = no interrupt).  These power up as
// zeros, and zeros on this chain mean LEVEL 7: under a 2-state simulator the
// core sees a phantom NMI racing its first instruction boundary (the
// mmu_turbo boot wedge), and on hardware the same window exists for a few
// cycles after reset release until real samples propagate.
reg [2:0] cpu_ipl = 3'b111;
always @(posedge clk) begin
	chipreq <= cpu_req & ~ramsel & ~fastchip_selack;
	cpu_ipl <= ipl_i;
end

reg ph1n, ph2n;
always @(posedge clk) begin
	ph1n <= ph1;
	ph2n <= ph2;
end

reg        chipready;
reg [15:0] chipdout_i;
reg  [2:0] ipl_i = 3'b111;   // idle, see cpu_ipl
reg        c_as,c_rw,c_uds,c_lds;
always @(negedge clk, negedge reset) begin
	reg [1:0] stage;
	reg waitm;
	reg ready;

	if(~reset) begin
		stage <= 0;
		waitm <= 0;
		c_as <= 1;
		c_rw <= 1;
		c_uds <= 1;
		c_lds <= 1;
		ready <= 0;
		chipready <= 0;
	end
	else if (bus_berr) begin
		// The bus16 adapter aborts on the next positive edge.  Release
		// any chip-bus phase here as well so the exception-vector fetch
		// starts from a clean bus transaction.
		stage <= 0;
		waitm <= 0;
		c_as <= 1;
		c_rw <= 1;
		c_uds <= 1;
		c_lds <= 1;
		ready <= 0;
		chipready <= 0;
	end
	else begin
		if (ph2n) begin
			waitm <= chip_dtack;
			if(~stage[0]) ipl_i <= chip_ipl;
		end

		chipready <= 0;
		if (ph1n) begin
			chipready <= ready;
			ready <= 0;
			case (stage)
				0: if (chipreq) begin
						c_as <= 0;
						c_rw <= wr;
						c_uds <= uds_in;
						c_lds <= lds_in;
						stage <= 1;
					end
				1: stage <= 2;
				2: begin
						chipdout_i <= chip_dout;
						if (~waitm) begin
							c_as <= 1;
							c_rw <= 1;
							c_uds <= 1;
							c_lds <= 1;
							ready <= 1;
							stage <= 3;
						end
					end
				3: stage <= 0;
			endcase
		end
	end
end

///////////////////// AUTOCONFIG ////////////////////////////

reg       ac_toccata;
reg       ac_a2065;
reg [2:0] ac_memcard;
reg [3:0] autocfg_data;


always @(*) begin
	autocfg_data = 4'b1111;

	// Zorro II RAM (Up to 8 meg at 0x200000). It has a fixed base, so it must be first in the chain.
	if (~ac_memcard[2] && ac_memcard[1:0]) begin
		case (chip_addr[6:1])
			6'b000000: autocfg_data = 4'b1110;	// Zorro-II card, add mem, no ROM
			6'b000001:
				case (ac_memcard[1:0])
							1: autocfg_data = 4'b0110; // 2MB
							2: autocfg_data = 4'b0111; // 4MB
					default: autocfg_data = 4'b0000; // 8MB
				endcase
			6'b001000: autocfg_data = 4'b1110;	// Manufacturer ID: 0x139c
			6'b001001: autocfg_data = 4'b1100;
			6'b001010: autocfg_data = 4'b0110;
			6'b001011: autocfg_data = 4'b0011;
			6'b010011: autocfg_data = 4'b1110; //serial=1
			  default:;
		endcase
	end
	// Zorro II other cards
	else if(ac_toccata) begin
		case (chip_addr[6:1])
			6'h0: autocfg_data = 4'b1100; // Zorro-II card, no link, no ROM
			6'h1: autocfg_data = 4'b0001; // Next board not related, size 'h64k
			// Inverted from here on
			6'h3: autocfg_data = 4'b0011; // Lower byte product number
			//6'h5: autocfg_data = 4'b1101; // logical size 64k -- commented out -> logical size == physical size. Issue with KS1.3?
			6'h8: autocfg_data = 4'b1011; // Manufacturer ID: 0x4754
			6'h9: autocfg_data = 4'b1000;
			6'ha: autocfg_data = 4'b1010;
			6'hb: autocfg_data = 4'b1011;
			default: ;
		endcase
	end
	// A2065 Ethernet (Commodore, mfr=0x0202, product=0x70)
	else if(ac_a2065) begin
		case (chip_addr[6:1])
			6'h0: autocfg_data = 4'b1100; // Zorro-II card, no link, no ROM
			6'h1: autocfg_data = 4'b0001; // size 64KB
			// Inverted from here on
			6'h2: autocfg_data = 4'b1000; // er_Product high nibble
			6'h3: autocfg_data = 4'b1111; // er_Product low nibble -> 0x70
			6'h4: autocfg_data = 4'b1111; // er_Flags high
			6'h5: autocfg_data = 4'b1111; // er_Flags low
			6'h8: autocfg_data = 4'b1111; // er_Manufacturer high high
			6'h9: autocfg_data = 4'b1101; // er_Manufacturer high low
			6'ha: autocfg_data = 4'b1111; // er_Manufacturer low high
			6'hb: autocfg_data = 4'b1101; // er_Manufacturer low low -> 0x0202
			// er_SerialNumber bytes 2..5 — the A2065 station address low
			// bytes, which AmigaOS reads as the card's MAC. Left at zero
			// (nibbles are inverted, so 4'b1111 reads as 0): the host side
			// rewrites the source address on the wire, so the card does not
			// need a unique serial here. Driving these from a register would
			// mean a real MAC arriving before autoconfig has run.
			6'hc:  autocfg_data = 4'b1111;
			6'hd:  autocfg_data = 4'b1111;
			6'he:  autocfg_data = 4'b1111;
			6'hf:  autocfg_data = 4'b1111;
			6'h10: autocfg_data = 4'b1111;
			6'h11: autocfg_data = 4'b1111;
			6'h12: autocfg_data = 4'b1111;
			6'h13: autocfg_data = 4'b1111;
			6'h14: autocfg_data = 4'b1111; // er_InitDiagVec
			6'h15: autocfg_data = 4'b1111; // er_InitDiagVec
			default: ;
		endcase
	end
	// Zorro III RAM 128MB/256MB/384MB
	else if(ac_memcard[2]) begin
		case (chip_addr[6:1])
			6'b000000: autocfg_data = 4'b1010;	// Zorro-III card, add mem, no ROM
			6'b000001: autocfg_data = ac_memcard[1] ? 4'b0011 : 4'b0100; // 128MB or 256MB, extended
			6'b000010: autocfg_data = 4'b1110;	// ProductID=0x10 (only setting upper nibble)
			6'b000100: autocfg_data = 4'b0000;	// Memory card, not silenceable, Extended size, reserved.
			6'b000101: autocfg_data = 4'b1111;	// 0000 - logical size matches physical size TODO change this to 0001, so it is autosized by the OS, WHEN it will be 24MB.
			6'b001000: autocfg_data = 4'b1110;	// Manufacturer ID: 0x139c
			6'b001001: autocfg_data = 4'b1100;
			6'b001010: autocfg_data = 4'b0110;
			6'b001011: autocfg_data = 4'b0011;
			6'b010011: autocfg_data = {2'b11, ~ac_memcard[1], ac_memcard[1]};	// serial=1/2
			  default:;
		endcase
	end
end

wire sel_autoconfig = (chip_addr[23:16] == 8'b11101000) && (ac_memcard || ac_toccata || ac_a2065); //$E80000 - $E8FFFF

reg       z2ram_ena;
reg [4:0] z3ram_base0;
reg [3:0] z3ram_base1;
reg       z3ram_ena0;
reg       z3ram_ena1;
always @(posedge clk) begin
	reg old_uds;
	old_uds <= chip_uds;

	if (~reset | ~reset_out) begin
		ac_memcard  <= cpucfg[1] ? fastramcfg : fastramcfg[2] ? 3'd3 : {1'b0, fastramcfg[1:0]};
		ac_toccata  <= 1;
		ac_a2065    <= 1;
		z2ram_ena   <= 0;
		z3ram_ena0  <= 0;
		z3ram_ena1  <= 0;
		z3ram_base0 <= 1;
		z3ram_base1 <= 1;
	end
	else if (sel_autoconfig && ~chip_rw && ~chip_uds && old_uds) begin
		if(~ac_memcard[2] && ac_memcard[1:0]) begin
			if (chip_addr[6:1] == 6'b100100) begin // Register 0x48 - config, ZII RAM
				z2ram_ena <= 1;
				ac_memcard <= 0;
			end
		end
		else if(ac_toccata) begin
			if (chip_addr[6:1] == 6'b100100) begin // Register 0x48 - config, Toccata card in ZII io space ($E90000)
				toccata_base <= cpu_dout[7:0];
				ac_toccata<=0;
			end		
		end
		else if(ac_a2065) begin
			if (chip_addr[6:1] == 6'b100100) begin // Register 0x48 - config, A2065 Ethernet
				a2065_base <= cpu_dout[7:0];
				ac_a2065<=0;
			end
		end
		else if(ac_memcard[2]) begin
			if(chip_addr[6:1] == 6'b100010) begin // Register 0x44, assign base address to ZIII RAM.
				if(~ac_memcard[1]) begin
					z3ram_base1 <= cpu_dout[15:12]; //256MB chunk
					z3ram_ena1 <= 1;
					ac_memcard <= {ac_memcard[0], ac_memcard[0], 1'b0};
				end
				else begin
					z3ram_base0 <= cpu_dout[15:11]; //128MB chunk
					z3ram_ena0 <= 1;
					ac_memcard <= 0;
				end
			end
		end
	end
end

assign toccata_ena = ~ac_toccata;
assign a2065_ena   = ~ac_a2065;

endmodule
