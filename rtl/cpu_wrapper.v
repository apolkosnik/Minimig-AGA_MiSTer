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
	parameter BUS_TIMEOUT_BITS = 20,
	// Experimental synchronous memory interface. The hardware top still
	// uses the legacy clock until clk_114 timing is closed for the core.
	parameter FAST_CLOCK = 0,
	parameter CORE_DIV = 4,
	// Posted stores.  The guarantee this needs -- that a write cannot fault
	// BELOW the MMU -- holds on Minimig and nowhere else in particular, which
	// is why it is this wrapper's parameter and not the CPU's: the core's
	// berr is driven by ap040_bus_timeout alone (below), no bus module asserts
	// it for a CPU access, and a timeout on a write is a controller that has
	// stopped answering, fatal in any case.  MMU faults, write-protect
	// included, are raised above the cache and stay precise.
	//
	// OFF, measured: the buffer alone is worth 0.1 % on the real memory path
	// (chip bench dhry 5,441,636 -> 5,435,232), because the cache accepts
	// nothing while a store drains and every instruction fetch waits behind
	// it.  A change to exception precision is not traded for that.  Set to 1
	// once the drain no longer blocks hits -- everything else is in place and
	// validated under posting (53/53, six posted snoop legs, full corpus).
	parameter POST_STORES = 0
)
(
	input             reset,
	output reg        reset_out,

	input             clk,
	// Required only by FAST_CLOCK: the existing 28 MHz peripheral clock.
	input             clk_peripheral,
	input             ph1,
	input             ph2,

	input       [2:0] cpucfg,
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

	input             cdtv_mode,
	output reg  [7:0] cdtv_base,

	input      [15:0] cdtv_din,
	input             cdtv_selack,

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
	output reg [31:0] nmi_addr,

	output reg        z2ram_ena,
	output reg  [4:0] z3ram_base0,
	output reg        z3ram_ena0,
	output reg  [3:0] z3ram_base1,
	output reg        z3ram_ena1,

	output            dcache_sw_en
);

// AP040 software data-cache enable is CACR[31].
assign dcache_sw_en = cacr_p[31];

assign ramsel_i     = cpu_req & ~sel_nmi_vector & (sel_zram | sel_chipram | sel_kickram | sel_dd | sel_rtg);
assign ramshared_i  = sel_dd;

// NMI
always @(posedge clk) nmi_addr <= vbr + 32'h7c;

wire sel_chipram;
wire sel_kickram;
wire sel_zram;
wire sel_dd;
wire sel_rtg;

memory_router u_memory_router
(
	.cpu_addr      (cpu_addr      ),
	.cchip         (cchip         ),
	.ckick         (ckick         ),
	.wr            (wr            ),
	.bootrom       (bootrom       ),
	.cdtv_mode     (cdtv_mode     ),
	.z2ram_ena     (z2ram_ena     ),
	.z3ram_base0   (z3ram_base0   ),
	.z3ram_ena0    (z3ram_ena0    ),
	.z3ram_base1   (z3ram_base1   ),
	.z3ram_ena1    (z3ram_ena1    ),
	.sel_chipram   (sel_chipram   ),
	.sel_kickram   (sel_kickram   ),
	.sel_zram      (sel_zram      ),
	.sel_dd        (sel_dd        ),
	.sel_rtg       (sel_rtg       ),
	.ramaddr       (ramaddr_i     )
);


// we route everything hrtmon related through cart.v (needs a couple of signals to
// decide what to do, would not be good style to replicate that here).
wire sel_nmi_vector = (cpu_addr[31:2] == nmi_addr[31:2]) && (cpustate == 2);

wire [15:0] ramdat;

assign ramlds_i = sel_rtg ? uds_in : lds_in;
assign ramuds_i = sel_rtg ? lds_in : uds_in;
assign ramdin_i = sel_rtg ? {cpu_dout[7:0],cpu_dout[15:8]} : cpu_dout;
assign ramdat = sel_rtg ? {ramdout[7:0], ramdout[15:8]}  : ramdout;

assign fastchip_lds = lds_in;
assign fastchip_uds = uds_in;
assign fastchip_rnw = wr;

reg  [31:0] cpu_addr;
reg  [15:0] cpu_dout;
wire [15:0] cpu_din;   // read mux; defined with the FAST_CLOCK boundary registers below
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
	fastchip_sel = cpu_req & !cpu_addr_p[31:24] &
	               !(FAST_CLOCK && fastchip_served);
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
wire        fastchip_served, fastchip_pending;
wire [15:0] fastchip_data_l;
// Under FAST_CLOCK the completion is REGISTERED once before it reaches
// core_enable.  The RAM controllers' acknowledge is a level from the
// controller cache's FSM; combinationally it ran through the guard and this
// mux straight into core_enable -- the clock enable of every tick-gated
// register in the core, six thousand pins -- and missed by -2.4 ns at
// 114 MHz (report_timing, 00db688b).  No exception may cover that path: a
// late clock enable at a tick is torn state, not a late value.  A flop here
// splits it into "acknowledge -> flop" and "flop -> enable fan-out", each
// its own cycle.  Every acknowledge is a level held until it is consumed,
// and the read data is held with it, so seeing them one fast cycle later
// changes nothing but the tick that consumes them: at worst one extra tick
// per transaction, when the acknowledge lands exactly on one.  ramconsumed,
// the chip stage machine and the fastchip crossing all derive from the one
// core_enable, so they move together.  The legacy path is untouched.
wire        bus_complete_fast = (chipready && !ramsel_i && !fastchip_selack && !fastchip_served) |
                                (ramready && ramsel_i) |
                                fastchip_pending;
reg         bus_complete_r;
always @(posedge clk) begin
    if (!reset) bus_complete_r <= 1'b0;
    else        bus_complete_r <= bus_complete_fast;
end
wire        bus_complete = FAST_CLOCK ? bus_complete_r
                                      : (chipready | ramready | fastchip_ready);

// The REQUEST side of the same boundary, registered once under FAST_CLOCK.
// The adapter's address and the MMU's cache-mode bit reached the RAM
// controllers' caches combinationally -- bus16|addr_out -> tagupd_idx at
// -3.3 ns and atc_ram -> cache_inhibit -> fill_discard at -3.0 (round 5,
// 3151ed33) -- and a controller cache samples the address on the first
// fast cycle it sees chip-select, so a late address there is a possible
// false hit, not a lost cycle: single-cycle by nature, closable only by a
// flop.  All seven signals move together so the attribute bits stay
// aligned with the address they describe.  Only the PORTS are registered:
// the internal decode (ramsel_i and friends) stays combinational, because
// it is paired with the tick-gated cpu_req -- chipreq in particular would
// raise a spurious one-cycle chip request on a RAM access that follows a
// chip access if it saw a lagging select.  ramready answers the registered
// request; ramconsumed and bus_complete pair it with the internal select,
// and both selects are high for the whole request, differing only at its
// edges, where ~cpu_req already governs.  The legacy path is untouched.
wire        ramsel_i, ramshared_i, ramlds_i, ramuds_i, cache_inhibit_i;
wire [28:1] ramaddr_i;
wire [15:0] ramdin_i;
reg         ramsel_r, ramshared_r, ramlds_r, ramuds_r, cache_inhibit_r;
reg  [28:1] ramaddr_r;
reg  [15:0] ramdin_r;
always @(posedge clk) begin
    if (!reset) begin
        ramsel_r <= 1'b0; ramshared_r <= 1'b0; ramlds_r <= 1'b0; ramuds_r <= 1'b0;
        cache_inhibit_r <= 1'b0; ramaddr_r <= 28'd0; ramdin_r <= 16'd0;
    end else begin
        ramsel_r <= ramsel_i; ramshared_r <= ramshared_i; ramlds_r <= ramlds_i; ramuds_r <= ramuds_i;
        cache_inhibit_r <= cache_inhibit_i; ramaddr_r <= ramaddr_i; ramdin_r <= ramdin_i;
    end
end
assign ramsel        = FAST_CLOCK ? ramsel_r        : ramsel_i;
assign ramshared     = FAST_CLOCK ? ramshared_r     : ramshared_i;
assign ramlds        = FAST_CLOCK ? ramlds_r        : ramlds_i;
assign ramuds        = FAST_CLOCK ? ramuds_r        : ramuds_i;
assign cache_inhibit = FAST_CLOCK ? cache_inhibit_r : cache_inhibit_i;
assign ramaddr       = FAST_CLOCK ? ramaddr_r       : ramaddr_i;
assign ramdin        = FAST_CLOCK ? ramdin_r        : ramdin_i;

// The RESPONSE DATA, registered once under FAST_CLOCK to match the
// registered acknowledge above.  The adapter samples data_in in the cycle
// it sees the acknowledge, and with bus_complete_r that cycle is one after
// the raw ready -- so the data takes the same flop and the pair arrive
// together, sampled in the ready cycle exactly as the legacy path samples
// them.  The mux select is the whole address decode, including the 30-bit
// NMI-vector compare, and it ran from nmi_addr through this mux into
// bus16|mem_rdata at -2.95 ns (round 6, 2fe902ca).  Under FAST_CLOCK the
// mux selects on ramsel_r, the select the RAM controller actually
// answered, so the compare leaves the data cone altogether: the address is
// stable from request to acknowledge, and the acknowledge follows the
// registered request, so the two selects agree in every cycle whose data
// is consumed.  The legacy path is untouched.
wire        din_ramsel = FAST_CLOCK ? ramsel_r : ramsel_i;
wire [15:0] cpu_din_c  = (FAST_CLOCK && fastchip_pending) ? fastchip_data_l :
                         din_ramsel ? ramdat :
                         fastchip_selack ? fastchip_dout :
                         cdtv_selack ? cdtv_din :
                         {sel_autoconfig ? autocfg_data : chip_data[15:12], chip_data[11:0]};
reg  [15:0] cpu_din_r;
always @(posedge clk) cpu_din_r <= cpu_din_c;
assign      cpu_din    = FAST_CLOCK ? cpu_din_r : cpu_din_c;

// FAST_CLOCK keeps CPU and RAM on the same clock. Only the architectural
// core advances at CORE_DIV; bus completions remain held until that edge.
reg [1:0] core_phase;
always @(posedge clk) begin
    if (!reset) core_phase <= 0;
    else if (core_phase == CORE_DIV-1) core_phase <= 0;
    else core_phase <= core_phase + 1'b1;
end
wire core_tick = !FAST_CLOCK || (core_phase == 0);
wire core_enable = core_tick && (~cpu_req | bus_complete | bus_berr);
// RTG/IDE/Akiko still run at 28 MHz. A combinational write-ready means
// "accepted on the next peripheral edge", not on the next fast CPU edge.
// Capture the result on that edge and cross a retained acknowledgement.
// Select drops immediately after acceptance, so side-effecting writes land
// exactly once. The return toggle permits the next request even if its
// one-fast-clock idle gap was too short for the peripheral domain to see.
generate if (FAST_CLOCK) begin : g_fastchip_cdc
    reg served, ack_toggle, consumed;
    reg [1:0] consumed_s, ack_s;
    reg [15:0] data_l;
    always @(posedge clk_peripheral) begin
        if (!reset) begin
            served <= 0; ack_toggle <= 0; consumed_s <= 0; data_l <= 0;
        end else begin
            consumed_s <= {consumed_s[0], consumed};
            if (served) begin
                if (consumed_s[1] == ack_toggle) served <= 0;
            end else if (fastchip_selack && fastchip_ready) begin
                data_l <= fastchip_dout;
                ack_toggle <= ~ack_toggle;
                served <= 1;
            end
        end
    end
    always @(posedge clk) begin
        if (!reset) begin ack_s <= 0; consumed <= 0; end
        else begin
            ack_s <= {ack_s[0], ack_toggle};
            if (core_enable && cpu_req && fastchip_pending) consumed <= ack_s[1];
        end
    end
    assign fastchip_pending = ack_s[1] != consumed;
    assign fastchip_served = served;
    assign fastchip_data_l = data_l;
end else begin : g_fastchip_legacy
    assign fastchip_pending = 1'b0;
    assign fastchip_served = 1'b0;
    assign fastchip_data_l = 16'd0;
end endgenerate
generate if (FAST_CLOCK) begin : g_sync_consumed
    always @* ramconsumed = core_enable && cpu_req && ramsel_i && ramready;
end else begin : g_async_consumed
    always @(posedge clk) begin
        if (!reset) ramconsumed <= 0;
        else ramconsumed <= cpu_req && ramsel_i && ramready;
    end
end endgenerate

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
	.AP040_HAS_FPU(1),
	.AP040_POST_STORES(POST_STORES)
) cpu_inst_p
(
	.clk(clk),
	.nreset(reset),
	.clkena_in(core_enable),
	.tick_in(core_tick),
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
	.mmu_cache_inhibit(cache_inhibit_i),
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
	.cache_burst(),
	.cache_burst_len(),
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
wire [28:1] walker_ramaddr;

// Use the CPU/CD DMA bank mapping for descriptor accesses too.
memory_router walker_router (
    .cpu_addr(walker_addr_eff), .cchip(1'b0), .ckick(1'b0), .wr(1'b1),
    .bootrom(bootrom), .cdtv_mode(cdtv_mode),
    .z2ram_ena(z2ram_ena), .z3ram_base0(z3ram_base0), .z3ram_ena0(z3ram_ena0),
    .z3ram_base1(z3ram_base1), .z3ram_ena1(z3ram_ena1),
    .ramaddr(walker_ramaddr)
);

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

// AP040's guarded RAM port handles accelerated chip writes as well as reads.
// Keep both directions on that port; its snoops maintain cache coherence.
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

// cpucfg[2] selects the legacy 68020 throttle; AP040 runs at native speed.

reg       chipreq;
reg [2:0] cpu_ipl;
always @(posedge clk) begin
	chipreq <= cpu_req & ~ramsel_i & ~fastchip_selack &
	           !(FAST_CLOCK && fastchip_served);
	cpu_ipl <= ipl_i;
end

reg ph1n, ph2n;
always @(posedge clk) begin
	ph1n <= ph1;
	ph2n <= ph2;
end

reg        chipready;
reg [15:0] chipdout_i;
reg  [2:0] ipl_i;
reg        c_as,c_rw,c_uds,c_lds;
generate if (FAST_CLOCK) begin : g_sync_chip
// The chipset phases are events in the fast domain, not clock enables
// stretched over four fast cycles. Acknowledge/data persist until consumed.
always @(posedge clk or negedge reset) begin
    reg [1:0] stage;
    reg waitm;
    reg sample_pending;
    reg [2:0] release_dly;   // fast clocks left until the strobes are released
    if (!reset) begin
        stage <= 0; waitm <= 1; chipready <= 0; chipdout_i <= 0;
        sample_pending <= 0; release_dly <= 0;
        c_as <= 1; c_rw <= 1; c_uds <= 1; c_lds <= 1;
        ipl_i <= 3'b111;
    end else if (bus_berr) begin
        stage <= 0; chipready <= 0;
        sample_pending <= 0; release_dly <= 0;
        c_as <= 1; c_rw <= 1; c_uds <= 1; c_lds <= 1;
    end else begin
        if (chipready && core_enable && cpu_req && !ramsel_i && !fastchip_selack)
            chipready <= 0;
        if (ph2 && !ph2n) begin
            waitm <= chip_dtack;
            if (!stage[0]) ipl_i <= chip_ipl;
            // DTACK precedes minimig_m68k_bridge's read-data latch (!c1 && c3):
            // sampling at the ph1 that releases the strobes returned the
            // PREVIOUS word, including the reset PC.  The data is taken here,
            // at the ph2 after the release, once that latch has settled.
            if (sample_pending) begin
                chipdout_i <= chip_dout;
                chipready <= 1;
                sample_pending <= 0;
            end
        end
        // The strobes are released FOUR fast clocks after the ph1 that saw
        // DTACK, not at that ph1.  The bridge drives its write strobes from
        // l_as/l_dtack (registered on clk_sys) and the CIA and custom chips
        // latch a write on the clk7_en-qualified clk_sys edge after l_dtack
        // falls, sampling l_as as registered one edge before -- so AS must
        // still be low at THAT edge, which sits about two fast clocks after
        // the ph1 pulse.  Releasing at ph1 dropped AS ~20 ns too early
        // (tb_cpu_wrapper_boot_bridge +trace_cia: release 19525, edge 19545,
        // latch edge 19585): every write was acknowledged and lost --
        // DiagROM's power LED never lit, COLOR00 never took, no serial --
        // while reads worked (reset vectors and first fetches were seen
        // correct on the board).  The legacy machine releases on the edge
        // itself.  Four clocks lands ~2 clocks past it in every phase of the
        // bench's sweep and costs ~2 clocks more than the legacy release.
        if (release_dly != 3'd0) begin
            release_dly <= release_dly - 1'b1;
            if (release_dly == 3'd1) begin
                c_as <= 1; c_rw <= 1; c_uds <= 1; c_lds <= 1;
                sample_pending <= 1;
            end
        end
        if (ph1 && !ph1n) begin
            case (stage)
                0: if (chipreq && !chipready) begin
                    c_as <= 0; c_rw <= wr; c_uds <= uds_in; c_lds <= lds_in;
                    stage <= 1;
                end
                1: stage <= 2;
                2: if (!waitm) begin
                    release_dly <= 3'd4;
                    stage <= 3;
                end
                3: if (!chipready && release_dly == 3'd0 && !sample_pending) stage <= 0;
            endcase
        end
    end
end
end else begin : g_async_chip
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
		// No interrupt until the first chipset phase samples the pins.
		// Left unreset this register powers up at 0 -- level 7 on the
		// active-low IPL lines -- and the core, whose synchroniser arms
		// the edge-triggered NMI from its own reset value, takes vector
		// 31 after the first instruction of a cold boot when that phase
		// lands more than two core clocks after reset release.  The
		// FAST_CLOCK machine above already resets it the same way.
		ipl_i <= 3'b111;
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
end endgenerate

///////////////////// AUTOCONFIG ////////////////////////////

reg       ac_toccata;
reg       ac_a2065;
reg       ac_cdtv;
reg [2:0] ac_memcard;
reg [3:0] autocfg_data;


always @(*) begin
	autocfg_data = 4'b1111;

	if (ac_cdtv) begin
		case (chip_addr[6:1])
			6'h00: autocfg_data = 4'b1100;
			6'h01: autocfg_data = 4'b0001;
			6'h03: autocfg_data = 4'b1100;
			6'h04: autocfg_data = 4'b1011;
			6'h09: autocfg_data = 4'b1101;
			6'h0B: autocfg_data = 4'b1101;
			default: autocfg_data = 4'b1111;
		endcase
	end
	// Zorro II RAM (Up to 8 meg at 0x200000). It has a fixed base, so it must be first in the chain.
	else if (~ac_memcard[2] && ac_memcard[1:0]) begin
		case (chip_addr[6:1])
			6'b000000: autocfg_data = 4'b1110;
			6'b000001:
				case (ac_memcard[1:0])
							1: autocfg_data = 4'b0110; // 2MB
							2: autocfg_data = 4'b0111; // 4MB
					default: autocfg_data = 4'b0000; // 8MB
				endcase
			6'b000010: autocfg_data = 4'b1010;
			6'b000011: autocfg_data = 4'b1110;
			6'b001000: autocfg_data = 4'b1111;
			6'b001001: autocfg_data = 4'b1000;
			6'b001010: autocfg_data = 4'b0010;
			6'b001011: autocfg_data = 4'b0100;
			6'b010011: autocfg_data = 4'b1110;
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

wire sel_autoconfig = (chip_addr[23:16] == 8'b11101000) && (ac_memcard || ac_toccata || ac_a2065 || ac_cdtv); //$E80000 - $E8FFFF

always @(posedge clk) begin
	reg old_uds;
	old_uds <= chip_uds;

	if (~reset | ~reset_out) begin
		ac_memcard  <= cpucfg[1] ? fastramcfg : fastramcfg[2] ? 3'd3 : {1'b0, fastramcfg[1:0]};
		ac_toccata  <= cdtv_mode ? 1'b0 : 1'b1;
		ac_a2065    <= 1;
		ac_cdtv     <= cdtv_mode;
		cdtv_base   <= 8'hE9;
		z2ram_ena   <= 0;
		z3ram_ena0  <= 0;
		z3ram_ena1  <= 0;
		z3ram_base0 <= 1;
		z3ram_base1 <= 1;
	end
	else if (sel_autoconfig && ~chip_rw && ~chip_uds && old_uds) begin
		if(ac_cdtv) begin
			if (chip_addr[6:1] == 6'b100100) begin
				cdtv_base <= cpu_dout[15:8];
				ac_cdtv   <= 0;
			end
			else if (chip_addr[6:1] == 6'b100110) begin
				ac_cdtv   <= 0;
			end
		end
		else if(~ac_memcard[2] && ac_memcard[1:0]) begin
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

assign toccata_ena = ~ac_toccata & ~cdtv_mode;
assign a2065_ena   = ~ac_a2065;

endmodule
