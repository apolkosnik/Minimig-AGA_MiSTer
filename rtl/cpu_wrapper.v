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
	parameter USE_68030_CACHE = 1  // 0=use existing cache, 1=use new 68030 cache
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
	output     [15:0] ramdin,
	input      [15:0] ramdout,
	input             ramready,
	output            ramlds,
	output            ramuds,
	output            ramshared,

	output            toccata_ena,
	output reg  [7:0] toccata_base,

	output reg  [1:0] cpustate,
	output reg [31:0] cacr,
	output reg [31:0] nmi_addr,

	// 68030 Cache interface (when USE_68030_CACHE=1)
	output            cache_req,
	output     [31:0] cache_addr,
	input      [15:0] cache_data,
	input             cache_ack,
	output            cache_burst,      // Burst mode request
	output      [2:0] cache_burst_len,  // Burst length (number of words)
	output     [28:1] cache_ramaddr,    // Properly encoded ramaddr for cache fill
	// Format Error debug: [6]=latched, [5:2]=format code, [1]=SR.S, [0]=SR.M
	output      [6:0] debug_fmt_err,

	// BUG #426: Walker active flag for SDRAM cache SM deassert
	output            walker_active_out,
	// BUG #427: Walker writing flag for SDRAM cpustate override
	output            walker_writing_out
);

// BUG #136 FIX: Include walker Fast RAM access in ramsel
// When walker is reading/writing page tables in Fast RAM (Z2, Z3), it needs to trigger RAM controller
// BUG #408 FIX: Suppress CPU's ramsel when walker is active. Without this, CPU's frozen address
// (e.g., turbo-cached chip RAM or Kickstart ROM) triggers a spurious SDRAM read that races with
// the walker's chip bus read. The spurious ramready can cause the walker to advance prematurely
// or leave stale SDRAM state that interferes when the CPU resumes after the walk.
// MC68030 bus fault suppression: When PMMU is translating (busy) or has faulted, suppress
// CPU bus accesses. On real 68030, faulting bus cycles are aborted before data reaches memory.
// The busy->fault transition is glitch-free (at least one is always high during handshake).
wire pmmu_suppress_bus = cpucfg[1] & (pmmu_busy_p | pmmu_fault_p | walker_timeout_error);
assign ramsel       = (cpu_req & ~sel_nmi_vector & ~walker_active & ~pmmu_suppress_bus & (sel_zram | sel_chipram | sel_kickram | sel_dd | sel_rtg)) | walker_fast_ram;
assign ramshared    = sel_dd;
assign walker_active_out = walker_active;
assign walker_writing_out = walker_writing;

// NMI
always @(posedge clk) nmi_addr <= vbr + 32'h7c;

// BUG #417 FIX: Use PMMU physical address for bus routing in 68030 mode
// When MMU translates logical->physical addresses, bus region selection (chipram, zram,
// kickram, etc.) and SDRAM address encoding must use the PHYSICAL address, not the
// logical address the CPU outputs. Without this, MMU-remapped accesses (e.g. WhichAmiga
// mapping $D0xxxxxx -> $00xxxxxx) hit the wrong bus path (chip bus instead of SDRAM),
// causing lockups when chip_dtack never arrives for non-chipset addresses.
// For non-68030 modes, pmmu_addr_phys_p = cpu_addr_p (identity, no MMU).
// For 68030 with TC.E=0 (MMU disabled), PMMU outputs addr_phys = addr_log (identity).
// pmmu_suppress_bus ensures bus_addr is only sampled after translation completes.
wire [31:0] bus_addr = cpucfg[1] ? pmmu_addr_phys_p : cpu_addr;

wire sel_z3ram0 = (bus_addr[31:27] == z3ram_base0) && z3ram_ena0;
wire sel_z3ram1 = (bus_addr[31:28] == z3ram_base1) && z3ram_ena1;
wire sel_z2ram  = !bus_addr[31:24] && (bus_addr[23] ^ |bus_addr[22:21]) && z2ram_ena; // addr[23:21] = 1..4
// Motherboard Fast RAM mapping DISABLED - caused issues

wire sel_zram   = sel_z3ram0 | sel_z3ram1 | sel_z2ram;
wire sel_dd     = (bus_addr[31:16] == 16'h00DD) && (bus_addr[15:13] == 'b010);
wire sel_rtg    = (bus_addr[31:24] == 8'h02);

// don't sel_kickram when writing
wire sel_kickram   = !bus_addr[31:24] && (&bus_addr[23:19] || (bus_addr[23:19] == 5'b11100)) && ckick && wr;	// $f8xxxx, e0xxxx
wire sel_kicklower = !bus_addr[31:24] && (bus_addr[23:18] == 6'b111110);
wire sel_chipram   = !bus_addr[31:21] && cchip; 		             //$000000 - $1FFFFF

// we route everything hrtmon related through cart.v (needs a couple of signals to
// decide what to do, would not be good style to replicate that here).
wire sel_nmi_vector = (bus_addr[31:2] == nmi_addr[31:2]) && (cpustate == 2);

wire [15:0] ramdat;

// BUG #137 FIX: Walker Fast RAM cycles need data strobes active (0 = active)
// When walker_fast_ram is true, force both bytes active for 16-bit reads/writes
assign ramlds = walker_fast_ram ? 1'b0 : (sel_rtg ? uds_in : lds_in);
assign ramuds = walker_fast_ram ? 1'b0 : (sel_rtg ? lds_in : uds_in);
// BUG #405 FIX: Write high word [31:16] to low address, low word [15:0] to high address (big-endian)
assign ramdin = (walker_fast_ram && walker_writing) ? (walker_write_low_phase ? walker_wdata_latch[31:16] : walker_wdata_latch[15:0]) :
                 sel_rtg ? {cpu_dout[7:0],cpu_dout[15:8]} : cpu_dout;
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
// BUG #136 FIX: Use walker_ramaddr when walker is accessing Fast RAM
// BUG #417 FIX: Use bus_addr (physical address) for SDRAM address encoding
assign ramaddr[28]    = walker_fast_ram ? walker_ramaddr[28] : (sel_zram & ~sel_z3ram0);
assign ramaddr[27]    = walker_fast_ram ? walker_ramaddr[27] : (sel_zram & (~sel_z3ram1 | bus_addr[27]));
assign ramaddr[26:23] = walker_fast_ram ? walker_ramaddr[26:23] : ((sel_z3ram0 | sel_z3ram1) ? bus_addr[26:23]: (sel_rtg ? 4'b1110 : {4{sel_dd}}));
assign ramaddr[22:19] = walker_fast_ram ? walker_ramaddr[22:19] : ({4{sel_dd}} | bus_addr[22:19]);
assign ramaddr[18]    = walker_fast_ram ? walker_ramaddr[18] : (sel_dd   | (sel_kicklower & bootrom) | bus_addr[18]);
assign ramaddr[17:16] = walker_fast_ram ? walker_ramaddr[17:16] : ({2{sel_dd}} | bus_addr[17:16]);
assign ramaddr[15:1]  = walker_fast_ram ? walker_ramaddr[15:1] : bus_addr[15:1];

// BUG #128 FIX: Compute properly encoded ramaddr for cache fill addresses
// Cache fills use cache_addr (physical address from PMMU) instead of cpu_addr
// This encoding is needed so DDR3 controller gets correct Z3 RAM addresses
wire sel_z3ram0_cache = (cache_addr[31:27] == z3ram_base0) && z3ram_ena0;
wire sel_z3ram1_cache = (cache_addr[31:28] == z3ram_base1) && z3ram_ena1;
wire sel_z2ram_cache  = !cache_addr[31:24] && (cache_addr[23] ^ |cache_addr[22:21]) && z2ram_ena;
wire sel_zram_cache   = sel_z3ram0_cache | sel_z3ram1_cache | sel_z2ram_cache;

assign cache_ramaddr[28]    = sel_zram_cache & ~sel_z3ram0_cache;
assign cache_ramaddr[27]    = sel_zram_cache & (~sel_z3ram1_cache | cache_addr[27]);
assign cache_ramaddr[26:23] = (sel_z3ram0_cache | sel_z3ram1_cache) ? cache_addr[26:23] : 4'b0000;
assign cache_ramaddr[22:1]  = cache_addr[22:1];

// BUG #136 FIX: Walker Fast RAM path support
// When page tables are in Fast RAM (Z2, Z3), walker needs to drive RAM controller
// walker_addr_latch is declared outside generate block, contains 32-bit physical address
// Walker state phases (computed from walker_state which is outside generate block)
// WALKER_READ_LOW=2, WALKER_WAIT_LOW=3, WALKER_READ_HIGH=4, WALKER_WAIT_HIGH=5
// WALKER_WRITE_LOW=7, WALKER_WAIT_WR_LOW=8, WALKER_WRITE_HIGH=9, WALKER_WAIT_WR_HIGH=10
wire walker_read_low_phase_global  = (walker_state == 4'd2) | (walker_state == 4'd3);
wire walker_write_low_phase_global = (walker_state == 4'd7) | (walker_state == 4'd8);
// Compute walker address for low word (bits 23:1) and high word (+1)
wire walker_low_phase_global = walker_read_low_phase_global | walker_write_low_phase_global;
wire [31:1] walker_addr_word = walker_low_phase_global ? {walker_addr_latch[31:2], 1'b0} :
                                                            {walker_addr_latch[31:2], 1'b1};

// Walker RAM selection (uses same logic as cpu_addr but with walker address)
wire sel_z3ram0_walker = (walker_addr_word[31:27] == z3ram_base0) && z3ram_ena0;
wire sel_z3ram1_walker = (walker_addr_word[31:28] == z3ram_base1) && z3ram_ena1;
wire sel_z2ram_walker  = !walker_addr_word[31:24] && (walker_addr_word[23] ^ |walker_addr_word[22:21]) && z2ram_ena;
wire sel_zram_walker   = sel_z3ram0_walker | sel_z3ram1_walker | sel_z2ram_walker;

// BUG #192 FIX: Use walker_active instead of (walker_reading | walker_writing)
// walker_reading/walker_writing go to 0 combinationally when entering WALKER_DONE,
// causing ramsel/ramaddr/ramdin to glitch mid-write before CPU is ungated.
// walker_active stays high during WALKER_DONE, ensuring clean bus handoff.
wire walker_fast_ram = USE_68030_CACHE && walker_active && sel_zram_walker;

// Walker encoded RAM address (same encoding as cpu->ramaddr)
wire [28:1] walker_ramaddr;
assign walker_ramaddr[28]    = sel_zram_walker & ~sel_z3ram0_walker;
assign walker_ramaddr[27]    = sel_zram_walker & (~sel_z3ram1_walker | walker_addr_word[27]);
assign walker_ramaddr[26:23] = (sel_z3ram0_walker | sel_z3ram1_walker) ? walker_addr_word[26:23] : 4'b0000;
assign walker_ramaddr[22:1]  = walker_addr_word[22:1];

assign fastchip_lds = lds_in;
assign fastchip_uds = uds_in;
assign fastchip_rnw = wr;

reg  [31:0] cpu_addr;
reg  [15:0] cpu_dout;
// CPU data input mux with cache support
reg [15:0] cache_data_out_16;
always @(*) begin
	// Select appropriate 16-bit data from 32-bit cache output based on address
	case (pmmu_addr_log_p[1:0])
		2'b00: begin
			// Instruction cache (always 16-bit aligned) or data cache lower word
			if (cpustate_p == 2'b00) 
				cache_data_out_16 = i_cache_data[15:0];   // Instruction fetch
			else
				cache_data_out_16 = d_cache_data_out[15:0];   // Data lower word
		end
		2'b10: begin
			// Upper word or instruction at +2
			if (cpustate_p == 2'b00)
				cache_data_out_16 = i_cache_data[31:16];  // Instruction at +2  
			else
				cache_data_out_16 = d_cache_data_out[31:16];  // Data upper word
		end
		2'b01: cache_data_out_16 = {8'h0, d_cache_data_out[15:8]};   // Byte at +1
		2'b11: cache_data_out_16 = {8'h0, d_cache_data_out[31:24]};  // Byte at +3
	endcase
end

// BUG #406 FIX: Don't let cache_hit intercept cpu_din during walker reads.
// When walker is active and reading from memory, cpu_din must reflect the actual
// memory bus data (chip_data/ramdat), not stale cache data from the CPU's frozen address.
// BUG #408 FIX: When walker reads from chip RAM, force cpu_din to chip_data.
// Without this, CPU's frozen address can set ramsel=1 (turbochip/kickstart), causing
// cpu_din to select ramdat (SDRAM data at CPU address) instead of chip_data (page table).
wire [15:0] cpu_din = (USE_68030_CACHE & cache_hit & ~walker_active) ? cache_data_out_16 :
                      walker_chip_ram ? chip_data :
                      ramsel ? ramdat : fastchip_selack ? fastchip_dout :
                      {sel_autoconfig ? autocfg_data : chip_data[15:12], chip_data[11:0]};
reg         wr;
reg         uds_in;
reg         lds_in;
reg  [15:0] chip_data;
reg  [31:0] vbr;

always @* begin
	if(cpucfg[1:0]) begin
		cpu_dout     = cpu_dout_p;
		cpu_addr     = cpu_addr_p;
		cpustate     = cpustate_p;
		cacr         = cacr_p;
		vbr          = vbr_p;
		wr           = wr_p;
		uds_in       = uds_p;
		lds_in       = lds_p;
		reset_out    = reset_out_p;
		// BUG #194 FIX: Walker must ONLY drive chip bus when accessing CHIP RAM ($000000-$1FFFFF)
		// When walker reads from Fast RAM (Z2/Z3), it uses ramdata bus, NOT chip bus!
		// Driving chip_as during Fast RAM access causes bus conflicts with CPU instruction fetch
		// This was causing WhichAmiga and cputest lockups when page tables were in Fast RAM
		if (walker_chip_ram && walker_reading) begin
			chip_addr    = walker_chip_addr;
			// BUG #423 FIX: Let chip bus SM control AS timing via c_as.
			// Forcing chip_as=0 permanently prevents the bridge (_ta_n in
			// minimig_m68k_bridge.v) from recycling dtack between bus cycles.
			// The bridge's async reset (posedge _as_and_cs) only fires when
			// chip_as transitions LOW->HIGH. With chip_as stuck low, dtack
			// stays asserted after the first cycle -> chip bus SM races through
			// subsequent cycles capturing stale data -> corrupted descriptors
			// -> PMMU fault -> double bus fault -> permanent lockup.
			chip_as      = c_as;  // SM cycles AS: assert at stage 0, deassert at stage 2
			chip_rw      = 1;  // Read operation
			chip_uds     = 0;  // Upper byte strobe active (low)
			chip_lds     = 0;  // Lower byte strobe active (low)
			chip_din     = cpu_dout_p;  // Not used for reads
		end else if (walker_chip_ram && walker_writing) begin
			// MC68030 U/M bit: Walker writing descriptor update
			chip_addr    = walker_chip_addr;
			// BUG #423 FIX: Same AS cycling fix as read path (see above)
			chip_as      = c_as;  // SM cycles AS properly for dtack recycling
			chip_rw      = 0;  // Write operation
			chip_uds     = 0;  // Upper byte strobe active (low)
			chip_lds     = 0;  // Lower byte strobe active (low)
			// BUG #405 FIX: Write high word [31:16] to low address, low word [15:0] to high address (big-endian)
			chip_din     = walker_write_low_phase ? walker_wdata_latch[31:16] : walker_wdata_latch[15:0];
		end else if (USE_68030_CACHE && walker_chip_cycle_active) begin
			// BUG #408 FIX: Only hold walker address on chip bus when the walk target is Chip RAM.
			// For Fast RAM walks, driving walker_chip_addr with CPU strobes can corrupt chip accesses.
			// Keep walker address only for Chip-RAM transitional states (e.g. WALKER_DONE).
			chip_addr    = walker_chip_addr;
			chip_as      = c_as;
			chip_rw      = c_rw;
			chip_uds     = c_uds;
			chip_lds     = c_lds;
			chip_din     = cpu_dout_p;
		end else begin
			// BUG #417 FIX: Use physical address for chip bus routing
			// When MMU remaps addresses, chip_addr must reflect the physical address
			// so the chip bus accesses the correct memory location
			chip_addr    = pmmu_addr_phys_p[23:1];
			chip_as      = c_as;
			chip_rw      = c_rw;
			chip_uds     = c_uds;
			chip_lds     = c_lds;
			chip_din     = cpu_dout_p;
		end
		chip_data    = chipdout_i;
		// BUG #417 FIX: Use physical address for fast chip select
		// BUG #425 FIX: Suppress fastchip_sel during walker activity.
		// walker_active blocks pmmu_suppress_bus from gating cpu_req, and
		// addr_phys may hold a stale walker address. Without this gate,
		// fastchip could spuriously respond to walker descriptor addresses.
		fastchip_sel = cpu_req & !pmmu_addr_phys_p[31:24] & ~walker_active;
		fastchip_lw  = longword;
	end
	else begin
		cpu_dout     = cpu_dout_o;
		cpu_addr     = {cpu_addr_o,1'b0};
		cpustate     = as_o ? 2'b01 : ~{wr_o,wr_o};
		cacr         = 1;
		vbr          = 0;
		wr           = wr_o;
		uds_in       = uds_o;
		lds_in       = lds_o;
		reset_out    = reset_out_o;
		chip_as      = ramsel | as_o;
		chip_rw      = wr_o;
		chip_uds     = uds_o;
		chip_lds     = lds_o;
		chip_addr    = cpu_addr_o[23:1];
		chip_din     = cpu_dout_o;
		chip_data    = chip_dout;
		fastchip_sel = 0;
		fastchip_lw  = 0;
	end
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
wire [31:0] pmmu_addr_log_p;
wire [31:0] pmmu_addr_phys_p;
wire        pmmu_cache_inhibit_p;  // BUG #126 FIX: Cache inhibit from PMMU (was unconnected)
wire        pmmu_walker_req_p;
wire        pmmu_walker_we_p;    // MC68030 U/M bit: write enable for descriptor updates
wire [31:0] pmmu_walker_addr_p;
wire [31:0] pmmu_walker_wdat_p;  // MC68030 U/M bit: write data
wire        pmmu_busy_p;         // BUG #407: PMMU busy (translation pending, not yet in walker)
wire        pmmu_fault_p;        // PMMU translation fault (suppress bus access)
// Format Error debug latch signals from Kernel
wire        fmt_err_latched_p;
wire [15:0] fmt_err_rte_word_p;
wire  [7:0] fmt_err_sr_p;
reg         pmmu_walker_ack_p;
reg  [31:0] pmmu_walker_data_p;
reg         pmmu_walker_berr_p;  // BUG #156 FIX: Bus error during table walk (sets MMUSR B bit)

// SignalTap debug registers (from PMMU via Kernel)
// noprune prevents Quartus from removing undriven-output registers
// preserve keeps the signal name for Node Finder
wire [31:0] stp_pmmu_tc_w, stp_pmmu_tt0_w, stp_pmmu_tt1_w;
wire [31:0] stp_pmmu_crp_hi_w, stp_pmmu_crp_lo_w;
wire  [4:0] stp_pmmu_wstate_w;
wire [21:0] stp_atc_buserr_w, stp_atc_valid_w;
wire [15:0] stp_fault_status_w;
wire [31:0] stp_saved_addr_w;
(* noprune, preserve *) reg [31:0] stp_pmmu_tc;
(* noprune, preserve *) reg [31:0] stp_pmmu_tt0;
(* noprune, preserve *) reg [31:0] stp_pmmu_tt1;
(* noprune, preserve *) reg [31:0] stp_pmmu_crp_hi;
(* noprune, preserve *) reg [31:0] stp_pmmu_crp_lo;
(* noprune, preserve *) reg  [4:0] stp_pmmu_wstate;
(* noprune, preserve *) reg        stp_pmmu_fault;
(* noprune, preserve *) reg        stp_pmmu_busy;
// Sticky fault latch: captures fault and holds until JTAG reads new build
(* noprune, preserve *) reg        stp_fault_latched;
(* noprune, preserve *) reg        stp_walker_timeout_latched;
// Latch PMMU state at moment of fault
(* noprune, preserve *) reg [31:0] stp_fault_tc;
(* noprune, preserve *) reg [31:0] stp_fault_addr;
(* noprune, preserve *) reg  [4:0] stp_fault_wstate;
(* noprune, preserve *) reg [21:0] stp_atc_buserr;
(* noprune, preserve *) reg [21:0] stp_atc_valid;
// Sticky: latch ATC buserr state at fault time
(* noprune, preserve *) reg [21:0] stp_fault_atc_buserr;
(* noprune, preserve *) reg [21:0] stp_fault_atc_valid;
// Sticky: latch fault status (MMUSR format) and walker's saved_addr at fault time
(* noprune, preserve *) reg [15:0] stp_fault_mmusr;
(* noprune, preserve *) reg [31:0] stp_fault_saved_addr;
always @(posedge clk) begin
	stp_pmmu_tc     <= stp_pmmu_tc_w;
	stp_pmmu_tt0    <= stp_pmmu_tt0_w;
	stp_pmmu_tt1    <= stp_pmmu_tt1_w;
	stp_pmmu_crp_hi <= stp_pmmu_crp_hi_w;
	stp_pmmu_crp_lo <= stp_pmmu_crp_lo_w;
	stp_pmmu_wstate <= stp_pmmu_wstate_w;
	stp_pmmu_fault  <= pmmu_fault_p;
	stp_pmmu_busy   <= pmmu_busy_p;
	stp_atc_buserr  <= stp_atc_buserr_w;
	stp_atc_valid   <= stp_atc_valid_w;
	// Sticky latches - once set, stay set forever
	if (~reset) begin
		stp_fault_latched <= 0;
		stp_walker_timeout_latched <= 0;
		stp_fault_tc <= 0;
		stp_fault_addr <= 0;
		stp_fault_wstate <= 0;
		stp_fault_atc_buserr <= 0;
		stp_fault_atc_valid <= 0;
		stp_fault_mmusr <= 0;
		stp_fault_saved_addr <= 0;
	end else begin
		if (pmmu_fault_p && !stp_fault_latched) begin
			stp_fault_latched <= 1;
			stp_fault_tc <= stp_pmmu_tc_w;
			stp_fault_addr <= cpu_addr_p;
			stp_fault_wstate <= stp_pmmu_wstate_w;
			stp_fault_atc_buserr <= stp_atc_buserr_w;
			stp_fault_atc_valid  <= stp_atc_valid_w;
			stp_fault_mmusr <= stp_fault_status_w;
			stp_fault_saved_addr <= stp_saved_addr_w;
		end
		if (walker_timeout_error && !stp_walker_timeout_latched) begin
			stp_walker_timeout_latched <= 1;
			if (!stp_fault_latched) begin
				stp_fault_tc <= stp_pmmu_tc_w;
				stp_fault_addr <= cpu_addr_p;
				stp_fault_wstate <= stp_pmmu_wstate_w;
				stp_fault_atc_buserr <= stp_atc_buserr_w;
				stp_fault_atc_valid  <= stp_atc_valid_w;
				stp_fault_mmusr <= stp_fault_status_w;
				stp_fault_saved_addr <= stp_saved_addr_w;
			end
		end
	end
end

// In-System Sources and Probes (ISSP) for JTAG readback of PMMU debug state
// Probe layout (MSB first):
//   TC[31:0] + TT0[31:0] + TT1[31:0] + CRP_HI[31:0] + CRP_LO[31:0] = 160
//   + WSTATE[4:0] + FAULT + BUSY = 7
//   + ATC_BUSERR[21:0] + ATC_VALID[21:0] = 44
//   + FAULT_LATCHED + WALKER_TIMEOUT_LATCHED = 2
//   + FAULT_TC[31:0] + FAULT_ADDR[31:0] + FAULT_WSTATE[4:0] = 69
//   + FAULT_ATC_BUSERR[21:0] + FAULT_ATC_VALID[21:0] = 44
//   + FAULT_MMUSR[15:0] + FAULT_SAVED_ADDR[31:0] = 48
//   Total = 374
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (0),
	.instance_id             ("PMMU"),
	.probe_width             (374),
	.source_width            (0),
	.enable_metastability    ("YES")
) pmmu_issp (
	.probe ({stp_pmmu_tc, stp_pmmu_tt0, stp_pmmu_tt1, stp_pmmu_crp_hi, stp_pmmu_crp_lo,
	         stp_pmmu_wstate, stp_pmmu_fault, stp_pmmu_busy,
	         stp_atc_buserr, stp_atc_valid,
	         stp_fault_latched, stp_walker_timeout_latched,
	         stp_fault_tc, stp_fault_addr, stp_fault_wstate,
	         stp_fault_atc_buserr, stp_fault_atc_valid,
	         stp_fault_mmusr, stp_fault_saved_addr})
);

// PMMU walker address mux signals (for bus arbitration)
// NOTE: Walker supports full 32-bit addressing:
//   - Chip RAM (<2MB): uses walker_chip_addr[23:1] -> chip_addr bus
//   - Z3/Z2 Fast RAM: uses walker_addr_word[31:1] -> walker_ramaddr -> ramsel path
// Page tables in Z3 RAM above 16MB are fully supported via the ramaddr path.
reg         walker_active;
reg   [3:0] walker_state;  // BUG #124 FIX: Walker state visible for bus mux (4-bit for write states)
reg  [31:0] walker_wdata_latch;  // MC68030 U/M bit: Latch write data from PMMU
reg         walker_timeout_error; // BUG #138: Walker timeout error flag
wire [23:1] walker_chip_addr;  // For Chip RAM only (inherently <2MB)
wire        walker_reading;  // BUG #124 FIX: Walker actively reading memory
wire        walker_writing;  // MC68030 U/M bit: Walker actively writing memory
wire        walker_write_low_phase;  // MC68030 U/M bit: Writing low word
reg  [31:1] walker_addr_latch;  // BUG #135 FIX: Declare outside generate for chipreq logic

// Cache interface signals (68030 only)
wire        i_cache_enabled;
wire        d_cache_enabled;
wire        cache_hit;
wire        cache_miss;
wire        cache_inv_req;
wire  [1:0] cache_op_scope;
wire  [1:0] cache_op_cache;
wire [31:0] cache_op_addr;
wire        cacr_ie;
wire        cacr_de;
wire        cacr_ifreeze;
wire        cacr_dfreeze;
wire        cacr_ibe;  // Instruction Burst Enable
wire        cacr_dbe;  // Data Burst Enable
wire        cacr_wa;   // Write Allocate
wire        i_cache_req;
wire [31:0] i_cache_addr;
wire [31:0] i_cache_data;
wire        i_cache_hit;
wire        i_fill_req;
wire [31:0] i_fill_addr;
wire[127:0] i_fill_data;
wire        i_fill_valid;
wire        d_cache_req;
wire [31:0] d_cache_addr;
wire        d_cache_we;
wire [31:0] d_cache_data_in;
wire [31:0] d_cache_data_out;
wire        d_cache_hit;
wire  [3:0] d_cache_be;
wire        d_fill_req;
wire [31:0] d_fill_addr;
wire[127:0] d_fill_data;
wire        d_fill_valid;

TG68KdotC_Kernel
#(
	.sr_read(2),        // 0=>user,   1=>privileged,    2=>switchable with CPU(0)
	.vbr_stackframe(2), // 0=>no,     1=>yes/extended,  2=>switchable with CPU(0)
	.extaddr_mode(2),   // 0=>no,     1=>yes,           2=>switchable with CPU(1)
	.mul_mode(2),       // 0=>16Bit,  1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,
	.div_mode(2),       // 0=>16Bit,  1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,
	.bitfield(2)        // 0=>no,     1=>yes,           2=>switchable with CPU(1)
)
cpu_inst_p
(
  .clk(clk),
  .nreset(reset),
  // BUG #139: Reset must bypass walker stall - allow clkena_in during reset recovery
  // so CPU internal reset can propagate even if walker is stuck
  // BUG #407: Also stall on pmmu_busy_p - catches the 1-cycle gap between ATC miss
  // detection (translation_pending='1') and walker mem_req assertion. Without this,
  // the CPU can advance with a stale physical address before the walker starts.
  // MC68030 bus fault: pmmu_fault_p bypasses pmmu_busy_p stall so the kernel can
  // advance to process the fault (accumulate make_berr, detect double bus fault).
  // Bus accesses are suppressed by pmmu_suppress_bus, so no stray writes occur.
  .clkena_in((~cpu_req | chipready | ramready | fastchip_ready | (USE_68030_CACHE & cache_hit) | pmmu_fault_p | walker_timeout_error | ~reset) & (~pmmu_walker_req_p | ~reset | walker_timeout_error) & (~pmmu_busy_p | pmmu_fault_p | walker_timeout_error | ~reset)),
  .data_in(cpu_din),
  .ipl(cpu_ipl),
  .ipl_autovector(1),
  .regin_out(),
  .addr_out(cpu_addr_p),
  .data_write(cpu_dout_p),
  .nwr(wr_p),
  .nuds(uds_p),
  .nlds(lds_p),
  .nresetout(reset_out_p),
  .longword(longword),
  
  .cpu(cpucfg),
  .busstate(cpustate_p),		// 0: fetch code, 1: no memaccess, 2: read data, 3: write data
  .cacr_out(cacr_p),
  .vbr_out(vbr_p),
  // Cache control interface (68030)
  .cache_inv_req(cache_inv_req),
  .cache_op_scope(cache_op_scope),
  .cache_op_cache(cache_op_cache),
  .cacr_ie(cacr_ie),
  .cacr_de(cacr_de),
  .cacr_ifreeze(cacr_ifreeze),
  .cacr_dfreeze(cacr_dfreeze),
  .cacr_ibe(cacr_ibe),
  .cacr_dbe(cacr_dbe),
  .cacr_wa(cacr_wa),
  // PMMU address interface
  .pmmu_addr_log(pmmu_addr_log_p),
  .pmmu_addr_phys(pmmu_addr_phys_p),
  .pmmu_cache_inhibit(pmmu_cache_inhibit_p),  // BUG #126 FIX: Cache inhibit from PMMU
  // PMMU walker memory interface
  .pmmu_walker_req(pmmu_walker_req_p),
  .pmmu_walker_we(pmmu_walker_we_p),    // MC68030 U/M bit: write enable
  .pmmu_walker_addr(pmmu_walker_addr_p),
  .pmmu_walker_wdat(pmmu_walker_wdat_p),  // MC68030 U/M bit: write data
  .pmmu_walker_ack(pmmu_walker_ack_p),
  .pmmu_walker_data(pmmu_walker_data_p),
  .pmmu_walker_berr(pmmu_walker_berr_p),  // MC68030: Bus error (sets MMUSR B bit)
  // BUG #407: PMMU busy signal for clkena_in gating
  .debug_pmmu_busy(pmmu_busy_p),
  // MC68030 bus fault: PMMU fault signal for bus access suppression
  .debug_pmmu_fault(pmmu_fault_p),
  // Format Error debug latch
  .debug_trap_format_error(fmt_err_latched_p),
  .debug_format_error_rte_word(fmt_err_rte_word_p),
  .debug_format_error_sr(fmt_err_sr_p),
  .debug_format_error_pc(),   // not routed to save pins
  .debug_format_error_addr(), // not routed to save pins
  // Cache operation address
  .cache_op_addr(cache_op_addr),
  // SignalTap debug ports (from PMMU)
  .debug_pmmu_tc(stp_pmmu_tc_w),
  .debug_pmmu_tt0(stp_pmmu_tt0_w),
  .debug_pmmu_tt1(stp_pmmu_tt1_w),
  .debug_pmmu_crp_hi(stp_pmmu_crp_hi_w),
  .debug_pmmu_crp_lo(stp_pmmu_crp_lo_w),
  .debug_pmmu_wstate(stp_pmmu_wstate_w),
  .debug_pmmu_atc_buserr(stp_atc_buserr_w),
  .debug_pmmu_atc_valid(stp_atc_valid_w),
  .debug_pmmu_fault_status(stp_fault_status_w),
  .debug_pmmu_saved_addr(stp_saved_addr_w)
);

wire [15:0] cpu_dout_o;
wire [23:1] cpu_addr_o;
wire  [2:0] fc_o;
wire        wr_o;
wire        as_o;
wire        uds_o;
wire        lds_o;
wire        reset_out_o;

fx68k cpu_inst_o
(
	.clk(clk),
	.enPhi1(ph1),
	.enPhi2(ph2),

	.extReset(~reset),
	.pwrUp(~reset),
	.oRESETn(reset_out_o),
	.HALTn(1),

	.eRWn(wr_o),
	.ASn(as_o),
	.LDSn(lds_o),
	.UDSn(uds_o),
	.DTACKn(ramsel ? ~ramready : chip_dtack),

	.FC0(fc_o[0]),
	.FC1(fc_o[1]),
	.FC2(fc_o[2]), 

	.VPAn(~&fc_o),
	.BERRn(1),
	.BRn(1),
	.BGACKn(1),
	.IPL0n(chip_ipl[0]),
	.IPL1n(chip_ipl[1]),
	.IPL2n(chip_ipl[2]),
	.iEdb(cpu_din),
	.oEdb(cpu_dout_o),
	.eab(cpu_addr_o)
);

// 68030 Cache implementation (conditional instantiation)
generate
if (USE_68030_CACHE) begin : gen_68030_cache

	// Cache enable logic - independent control for instruction and data caches
	// OSD sends cpucfg=10 for 68030 (temporary encoding until 68020 option added)
	assign i_cache_enabled = cpucfg[1] & cacr_ie; // 68030 (cpucfg=10 or 11) with instruction cache enabled --cpu(1)=1
	assign d_cache_enabled = cpucfg[1] & cacr_de; // 68030 (cpucfg=10 or 11) with data cache enabled --cpu(1)=1

	// 68030 Cache instantiation
	TG68K_Cache_030 cache_inst
	(
		.clk(clk),
		.nreset(reset),
		// Cache Control (from CACR register)
		.cacr_ie(cacr_ie),
		.cacr_de(cacr_de),
		.cacr_ifreeze(cacr_ifreeze),
		.cacr_dfreeze(cacr_dfreeze),
		.cacr_wa(cacr_wa),
		// Cache invalidation (68030 via CACR bits)
		.inv_req(cache_inv_req),
		.cache_op_scope(cache_op_scope),
		.cache_op_cache(cache_op_cache),
		.cache_op_addr(cache_op_addr),
		// Instruction Cache Interface
		.i_addr(i_cache_addr),
		.i_addr_phys(pmmu_addr_phys_p),  // Physical address from PMMU
		.i_req(i_cache_req),
		.i_cache_inhibit(pmmu_cache_inhibit_p),  // Cache inhibit from PMMU
		.i_data(i_cache_data),
		.i_hit(i_cache_hit),
		.i_fill_req(i_fill_req),
		.i_fill_addr(i_fill_addr),
		.i_fill_data(i_fill_data),
		.i_fill_valid(i_fill_valid),
		// Data Cache Interface
		.d_addr(d_cache_addr),
		.d_addr_phys(pmmu_addr_phys_p),  // Physical address from PMMU
		.d_req(d_cache_req),
		.d_we(d_cache_we),
		.d_cache_inhibit(pmmu_cache_inhibit_p),  // Cache inhibit from PMMU
		.d_data_in(d_cache_data_in),
		.d_data_out(d_cache_data_out),
		.d_be(d_cache_be),
		.d_hit(d_cache_hit),
		.d_fill_req(d_fill_req),
		.d_fill_addr(d_fill_addr),
		.d_fill_data(d_fill_data),
		.d_fill_valid(d_fill_valid)
	);

	// Cache interface logic
	assign i_cache_addr = pmmu_addr_log_p;  // Use logical address for cache indexing
	assign i_cache_req = i_cache_enabled & (cpustate_p == 2'b00); // Instruction fetch
	assign d_cache_addr = pmmu_addr_log_p;  // Use logical address for cache indexing
	assign d_cache_req = d_cache_enabled & (cpustate_p == 2'b10 | cpustate_p == 2'b11); // Data read/write
	assign d_cache_we = (cpustate_p == 2'b11); // Write enable for data cache
	
	// Generate 32-bit data and byte enables from 16-bit CPU interface
	// CPU provides 16-bit data with UDS/LDS strobes
	// Convert to 32-bit aligned data with proper byte enables
	wire [1:0] addr_low = pmmu_addr_log_p[1:0];
	
	// Data positioning based on address alignment
	assign d_cache_data_in = (addr_low == 2'b00) ? {16'h0, cpu_dout_p} :
	                         (addr_low == 2'b01) ? {24'h0, cpu_dout_p[7:0]} :
	                         (addr_low == 2'b10) ? {cpu_dout_p, 16'h0} :
	                                               {cpu_dout_p[7:0], 24'h0};
	
	// Byte enable generation
	assign d_cache_be = (addr_low == 2'b00) ? {2'b00, ~uds_p, ~lds_p} :
	                    (addr_low == 2'b01) ? {3'b000, ~lds_p} :
	                    (addr_low == 2'b10) ? {~uds_p, ~lds_p, 2'b00} :
	                                          {~uds_p, 3'b000};

	// Cache hit/miss logic
	// BUG #412 FIX: Data cache hits on WRITES must NOT bypass bus wait in clkena_in.
	// MC68030 data cache is write-through: writes must go to BOTH cache AND memory.
	// If cache_hit gates clkena_in during writes, the CPU advances before the actual
	// bus write completes. For chip bus: chipreq is registered one clock late, so by the
	// time the chip bus state machine starts, wr has changed to READ and chip_addr points
	// to the new fetch address - the write becomes a read to the wrong address.
	// For SDRAM: ramsel drops when cpu_req goes low, potentially losing the write.
	// Fix: Exclude write cycles (d_cache_we) from cache_hit used for clkena_in gating.
	// Reads can still be served entirely from cache; writes must wait for bus completion.
	assign cache_hit = (i_cache_hit & i_cache_req) | (d_cache_hit & d_cache_req & ~d_cache_we);
	assign cache_miss = ((i_cache_enabled & ~i_cache_hit & i_cache_req) | (d_cache_enabled & ~d_cache_hit & d_cache_req));

	// Connect cache fill interface to external memory controller
	// IBE/DBE bits control whether cache fills are allowed (not burst mode itself)
	// When IBE=0, instruction cache fills are disabled (all I-fetches bypass cache)
	// When DBE=0, data cache fills are disabled (all D-accesses bypass cache)
	// SDRAM burst mode is always BURST=4 (hardcoded in sdram_ctrl.v line 291)
	assign cache_req = (i_fill_req & cacr_ibe) | (d_fill_req & cacr_dbe);
	assign cache_addr = i_fill_req ? i_fill_addr : d_fill_addr;

	// Burst control - unused (SDRAM permanently in BURST=4 mode)
	assign cache_burst = ((i_fill_req & cacr_ibe) | (d_fill_req & cacr_dbe));
	assign cache_burst_len = 3'd7;  // Always 8 words for 128-bit cache line

	// Cache fill logic - accumulate 16-bit reads into 128-bit cache lines
	reg [2:0] fill_count;
	reg [127:0] fill_buffer;
	reg fill_active;

	always @(posedge clk) begin
		if (~reset) begin
			fill_count <= 0;
			fill_buffer <= 0;
			fill_active <= 0;
		end else begin
			if (cache_req & cache_ack) begin
				if (~fill_active) begin
					fill_active <= 1;
					fill_count <= 0;
				end
				
				// Accumulate 16-bit words into 128-bit cache line
				case (fill_count)
					3'd0: fill_buffer[15:0]    <= cache_data;
					3'd1: fill_buffer[31:16]   <= cache_data;
					3'd2: fill_buffer[47:32]   <= cache_data;
					3'd3: fill_buffer[63:48]   <= cache_data;
					3'd4: fill_buffer[79:64]   <= cache_data;
					3'd5: fill_buffer[95:80]   <= cache_data;
					3'd6: fill_buffer[111:96]  <= cache_data;
					3'd7: begin
						fill_buffer[127:112] <= cache_data;
						fill_active <= 0;  // Complete cache line
					end
				endcase
				
				if (fill_count < 7) fill_count <= fill_count + 1;
			end
		end
	end

	// Provide filled cache line to cache module
	assign i_fill_data = fill_buffer;
	assign i_fill_valid = fill_active & (fill_count == 7);
	assign d_fill_data = fill_buffer;
	assign d_fill_valid = fill_active & (fill_count == 7);

	// PMMU Walker Memory Arbiter (Stall-Based Approach)
	// The walker needs 32-bit descriptors from memory via two sequential 16-bit reads.
	// Strategy: When walker requests, stall CPU (via clkena_in gate), drive walker address
	// onto bus, perform reads, and acknowledge when complete.

	// walker_state and walker_addr_latch declared outside generate block for bus mux visibility
	reg [15:0] walker_data_low;

	// BUG #138: Walker timeout counter - abort if no memory response
	// On timeout, returns zeroed data with BERR to trigger PMMU bus error fault
	// The walker_timeout_error signal also unblocks clkena_in to allow CPU recovery
	reg [11:0] walker_timeout_cnt;  // 12-bit counter = 4096 cycles max (~36us @ 114MHz)

	// BUG #408 FIX: Walker must wait for the correct ready signal based on memory region.
	// Chip RAM reads wait for chipready; Fast RAM reads wait for ramready.
	// Without this, a spurious SDRAM read (from CPU's frozen address) produces ramready
	// before chipready, causing the walker to advance with stale/wrong chip_data.
	wire walker_mem_ready = walker_chip_ram ? chipready : (walker_fast_ram ? ramready : (chipready | ramready | fastchip_ready));
	localparam WALKER_TIMEOUT_LIMIT = 12'd2048;  // Timeout after 2048 cycles (~18us)

	// BUG #422 FIX: Track in-flight CPU SDRAM cycles for stale-ready detection.
	// When PMMU activates (busy='1'), ramsel drops the CPU component via ~pmmu_suppress_bus.
	// But the SDRAM controller may have already started a cycle from the previous posedge.
	// This stale SDRAM cycle generates ramready with data from the CPU's address, not the
	// walker's descriptor address. If the walker enters WAIT_LOW before this stale ramready
	// clears, it captures wrong data -> corrupted page walk -> lockup.
	// stale_ram_pending is set when the CPU has an active SDRAM request (ramsel with CPU
	// component). Cleared when ramready fires (stale cycle completed). The walker waits
	// in READ_LOW until this flag is clear before accepting ramready.
	reg stale_ram_pending;
	always @(posedge clk) begin
		if (~reset)
			stale_ram_pending <= 0;
		else if (ramready)
			stale_ram_pending <= 0;  // SDRAM cycle completed
		else if (!walker_active && !pmmu_suppress_bus && ramsel)
			stale_ram_pending <= 1;  // CPU has SDRAM cycle in-flight
	end

	localparam WALKER_IDLE       = 4'd0;
	localparam WALKER_START      = 4'd1;
	localparam WALKER_READ_LOW   = 4'd2;
	localparam WALKER_WAIT_LOW   = 4'd3;
	localparam WALKER_READ_HIGH  = 4'd4;
	localparam WALKER_WAIT_HIGH  = 4'd5;
	localparam WALKER_DONE       = 4'd6;
	// MC68030 U/M bit: Write states for descriptor updates
	localparam WALKER_WRITE_LOW  = 4'd7;
	localparam WALKER_WAIT_WR_LOW  = 4'd8;
	localparam WALKER_WRITE_HIGH = 4'd9;
	localparam WALKER_WAIT_WR_HIGH = 4'd10;

	// Address multiplexing: Walker overrides CPU address during active states
	// Walker addresses are byte addresses, chip_addr is word address (23:1)
	// To read 32-bit descriptor: read word at addr[23:1], then addr[23:1]+1
	wire walker_read_low_phase = (walker_state == WALKER_READ_LOW) | (walker_state == WALKER_WAIT_LOW);
	wire walker_read_high_phase = (walker_state == WALKER_READ_HIGH) | (walker_state == WALKER_WAIT_HIGH);
	// MC68030 U/M bit: Write phase detection
	wire walker_write_low_phase_i = (walker_state == WALKER_WRITE_LOW) | (walker_state == WALKER_WAIT_WR_LOW);
	wire walker_write_high_phase_i = (walker_state == WALKER_WRITE_HIGH) | (walker_state == WALKER_WAIT_WR_HIGH);
	wire walker_writing_i = walker_write_low_phase_i | walker_write_high_phase_i;
	// Assign to outer wires for bus mux visibility
	assign walker_writing = walker_writing_i;
	assign walker_write_low_phase = walker_write_low_phase_i;
	// BUG #124 FIX: Walker must also drive address strobe and data strobes during read phases
	// walker_reading declared outside generate block, assigned here
	assign walker_reading = walker_read_low_phase | walker_read_high_phase;
	// Chip RAM path only - Z3 RAM uses walker_ramaddr with full 32-bit walker_addr_word
	wire [23:1] walker_base_addr = walker_addr_latch[23:1];  // Lower 23 bits for chip_addr bus
	// Address mux for read/write operations
	wire walker_low_phase = walker_read_low_phase | walker_write_low_phase_i;
	assign walker_chip_addr = walker_low_phase ?
	                          walker_base_addr :           // Low word at base address
	                          (walker_base_addr + 1'b1);   // High word at base+1

	always @(posedge clk) begin
		if (~reset) begin
			walker_state <= WALKER_IDLE;
			pmmu_walker_ack_p <= 0;
			pmmu_walker_data_p <= 0;
			pmmu_walker_berr_p <= 0;  // BUG #156 FIX: Reset BERR signal
			walker_data_low <= 0;
			walker_addr_latch <= 0;
			walker_active <= 0;
			walker_wdata_latch <= 0;  // MC68030 U/M bit: Reset write data latch
			// BUG #138: Reset timeout counter and error flag
			walker_timeout_cnt <= 0;
			walker_timeout_error <= 0;
		end else begin
			case (walker_state)
				WALKER_IDLE: begin
					pmmu_walker_ack_p <= 0;
					pmmu_walker_berr_p <= 0;  // BUG #156 FIX: Clear BERR at start of new walk
					walker_active <= 0;
					// BUG #138: Reset timeout counter and error flag when idle
					walker_timeout_cnt <= 0;
					walker_timeout_error <= 0;
					if (pmmu_walker_req_p) begin
						// Latch walker address and start read sequence
						walker_addr_latch <= pmmu_walker_addr_p[31:1];
						walker_state <= WALKER_START;
					end
				end

				WALKER_START: begin
					// Wait one cycle for CPU to stall (clkena_in gated low)
					walker_active <= 1;  // Walker now owns the bus
					// MC68030 U/M bit: Check if this is a write operation
					if (pmmu_walker_we_p) begin
						// Write operation - latch data and start write sequence
						walker_wdata_latch <= pmmu_walker_wdat_p;
						walker_state <= WALKER_WRITE_LOW;
					end else begin
						walker_state <= WALKER_READ_LOW;
					end
				end

				WALKER_READ_LOW: begin
					// Drive walker address with LSB=0 for low word via walker_chip_addr mux
					// BUG #424 FIX: Increment timeout instead of resetting to 0.
					// Previously reset every cycle, so timeout never fired if stuck here
					// (e.g. chip bus SM hung, or stale_ram_pending never cleared).
					walker_timeout_cnt <= walker_timeout_cnt + 1;
					// BUG #419 FIX: Detect PMMU internal timeout (mem_req dropped)
					if (~pmmu_walker_req_p) begin
						walker_state <= WALKER_DONE;
					end
					// BUG #424 FIX: Wrapper-level timeout escape
					else if (walker_timeout_cnt >= WALKER_TIMEOUT_LIMIT) begin
						walker_timeout_error <= 1;
						pmmu_walker_berr_p <= 1;
						pmmu_walker_data_p <= 32'h0;
						walker_state <= WALKER_DONE;
					end
					// BUG #422 FIX: Wait for any stale CPU bus cycle to complete before
					// entering WAIT_LOW. When PMOVE-to-TC activates MMU, the CPU may
					// have a bus cycle in-flight (started before pmmu_suppress_bus or
					// walker_active took effect). If we enter WAIT_LOW while this stale
					// cycle is running, we capture its ready signal with wrong data.
					// Chip RAM walks: wait for chip bus SM idle (chip_stage==0).
					// SDRAM walks: wait for stale_ram_pending to clear (ramready fires).
					else if (walker_addr_is_chipram) begin
						if (chip_stage == 2'b00)
							walker_state <= WALKER_WAIT_LOW;
					end else begin
						if (!stale_ram_pending)
							walker_state <= WALKER_WAIT_LOW;
					end
				end

				WALKER_WAIT_LOW: begin
					// BUG #419 FIX: Detect PMMU internal timeout (mem_req dropped).
					// PMMU's 500-cycle timeout drops pmmu_walker_req_p while wrapper
					// is still counting to 2048. Without this, walker_active blocks
					// ALL CPU SDRAM access for ~1548 cycles. Bus error frame writes
					// can't reach Fast RAM, freezing the CPU. If the stack page needs
					// a walk too, the second PMMU timeout triggers false double bus
					// fault -> permanent hang.
					if (~pmmu_walker_req_p) begin
						walker_state <= WALKER_DONE;
					end
					// BUG #138: Check for wrapper-level timeout
					else if (walker_timeout_cnt >= WALKER_TIMEOUT_LIMIT) begin
						// BUG #156 FIX: Timeout is a bus error - assert BERR signal
						// MC68030 spec: Bus errors during table walk set MMUSR B bit
						walker_timeout_error <= 1;
						pmmu_walker_berr_p <= 1;  // Signal bus error to PMMU
						pmmu_walker_data_p <= 32'h0;  // Data doesn't matter when BERR is set
						walker_state <= WALKER_DONE;
					end else if (walker_mem_ready) begin
						// Capture low 16 bits
						walker_data_low <= cpu_din;
						walker_state <= WALKER_READ_HIGH;
					end else begin
						// BUG #138: Increment timeout counter while waiting
						walker_timeout_cnt <= walker_timeout_cnt + 1;
					end
				end

				WALKER_READ_HIGH: begin
					// Drive walker address with LSB=1 for high word via walker_chip_addr mux
					// BUG #138: Reset timeout counter when entering wait state
					walker_timeout_cnt <= 0;
					walker_state <= WALKER_WAIT_HIGH;
				end

				WALKER_WAIT_HIGH: begin
					// BUG #419 FIX: Detect PMMU internal timeout (see WALKER_WAIT_LOW)
					if (~pmmu_walker_req_p) begin
						walker_state <= WALKER_DONE;
					end
					// BUG #138: Check for wrapper-level timeout
					else if (walker_timeout_cnt >= WALKER_TIMEOUT_LIMIT) begin
						// BUG #156 FIX: Timeout is a bus error - assert BERR signal
						walker_timeout_error <= 1;
						pmmu_walker_berr_p <= 1;  // Signal bus error to PMMU
						pmmu_walker_data_p <= 32'h0;
						walker_state <= WALKER_DONE;
					end else if (walker_mem_ready) begin
						// BUG #405 FIX: Assemble 32-bit descriptor in big-endian order
						// walker_data_low was read from low address (= high word in big-endian)
						// cpu_din was read from high address (= low word in big-endian)
						pmmu_walker_data_p <= {walker_data_low, cpu_din};
						walker_state <= WALKER_DONE;
					end else begin
						// BUG #138: Increment timeout counter while waiting
						walker_timeout_cnt <= walker_timeout_cnt + 1;
					end
				end

				WALKER_DONE: begin
					// BUG #420 FIX: Stale ack race during multi-level page walks.
					// Previously, pmmu_walker_ack_p was unconditionally set to 1 every
					// cycle in WALKER_DONE. On the cycle when ~pmmu_walker_req_p triggers
					// the transition to WALKER_IDLE, the ack was STILL asserted (last
					// assignment wins). The PMMU, having already consumed the ack and
					// transitioned to the next walk level (e.g., W_PTR1), issues a new
					// mem_req on that same cycle. On the NEXT cycle, the PMMU sees
					// mem_req=1 AND mem_ack=1 (stale!) and immediately processes the
					// old data as if it were the new response. This corrupts every
					// multi-level page walk, producing wrong ATC entries -> wrong
					// physical addresses -> crashes -> double bus fault -> CPU halt.
					// Fix: Only assert ack while the PMMU still has its request active.
					// Clear ack on the transition cycle so the PMMU doesn't see a stale ack.
					walker_active <= 0;  // Release bus
					if (~pmmu_walker_req_p) begin
						// PMMU has deasserted request - clear ack and return to idle
						pmmu_walker_ack_p <= 0;
						walker_state <= WALKER_IDLE;
					end else begin
						// PMMU still has request active - keep acknowledging
						pmmu_walker_ack_p <= 1;
					end
				end

				// MC68030 U/M bit: Write states for descriptor updates
				WALKER_WRITE_LOW: begin
					// Drive walker address with LSB=0 for low word
					// Write data (walker_wdata_latch[15:0]) is driven via chip_din mux
					// BUG #424 FIX: Same escape hatches as WALKER_READ_LOW
					walker_timeout_cnt <= walker_timeout_cnt + 1;
					if (~pmmu_walker_req_p) begin
						walker_state <= WALKER_DONE;
					end
					else if (walker_timeout_cnt >= WALKER_TIMEOUT_LIMIT) begin
						walker_timeout_error <= 1;
						pmmu_walker_berr_p <= 1;
						walker_state <= WALKER_DONE;
					end
					// BUG #422 FIX: Same stale-cycle guard as WALKER_READ_LOW (see above)
					else if (walker_addr_is_chipram) begin
						if (chip_stage == 2'b00)
							walker_state <= WALKER_WAIT_WR_LOW;
					end else begin
						if (!stale_ram_pending)
							walker_state <= WALKER_WAIT_WR_LOW;
					end
				end

				WALKER_WAIT_WR_LOW: begin
					// BUG #419 FIX: Detect PMMU internal timeout (see WALKER_WAIT_LOW)
					if (~pmmu_walker_req_p) begin
						walker_state <= WALKER_DONE;
					end
					// Wait for write to complete
					else if (walker_timeout_cnt >= WALKER_TIMEOUT_LIMIT) begin
						// BUG #156 FIX: Timeout is a bus error
						walker_timeout_error <= 1;
						pmmu_walker_berr_p <= 1;
						walker_state <= WALKER_DONE;
					end else if (walker_mem_ready) begin
						// Low word written, now write high word
						walker_state <= WALKER_WRITE_HIGH;
					end else begin
						walker_timeout_cnt <= walker_timeout_cnt + 1;
					end
				end

				WALKER_WRITE_HIGH: begin
					// Drive walker address with LSB=1 for high word
					// Write data (walker_wdata_latch[31:16]) is driven via chip_din mux
					walker_timeout_cnt <= 0;
					walker_state <= WALKER_WAIT_WR_HIGH;
				end

				WALKER_WAIT_WR_HIGH: begin
					// BUG #419 FIX: Detect PMMU internal timeout (see WALKER_WAIT_LOW)
					if (~pmmu_walker_req_p) begin
						walker_state <= WALKER_DONE;
					end
					// Wait for write to complete
					else if (walker_timeout_cnt >= WALKER_TIMEOUT_LIMIT) begin
						// BUG #156 FIX: Timeout is a bus error
						walker_timeout_error <= 1;
						pmmu_walker_berr_p <= 1;
						walker_state <= WALKER_DONE;
					end else if (walker_mem_ready) begin
						// Write complete
						walker_state <= WALKER_DONE;
					end else begin
						walker_timeout_cnt <= walker_timeout_cnt + 1;
					end
				end

				default: begin
					// Safety: recover from corrupted walker_state (e.g. timing violations)
					walker_state <= WALKER_IDLE;
					walker_active <= 0;
					pmmu_walker_ack_p <= 0;
					pmmu_walker_berr_p <= 0;
				end
			endcase
		end
	end

end else begin : gen_no_68030_cache

	// Disable 68030 cache when not using it
	assign i_cache_enabled = 1'b0;
	assign d_cache_enabled = 1'b0;

	// No walker arbiter when cache disabled
	assign walker_chip_addr = 23'b0;  // Unused
	assign walker_reading = 1'b0;     // BUG #124: No walker when cache disabled
	assign walker_writing = 1'b0;     // MC68030 U/M bit: No walker when cache disabled
	assign walker_write_low_phase = 1'b0;

	always @(posedge clk) begin
		if (~reset) begin
			pmmu_walker_ack_p <= 0;
			pmmu_walker_berr_p <= 0;  // BUG #156 FIX: Reset BERR signal
			walker_active <= 0;
			walker_state <= 4'd0;  // BUG #124: Keep state at 0
			pmmu_walker_data_p <= 0;
			walker_wdata_latch <= 0;  // MC68030 U/M bit
			walker_timeout_error <= 0;
		end else begin
			pmmu_walker_ack_p <= 0;
			pmmu_walker_berr_p <= 0;  // BUG #156 FIX: No BERR when cache disabled
			pmmu_walker_data_p <= 0;
			walker_timeout_error <= 0;
		end
	end
	assign cache_hit = 1'b0;
	assign cache_miss = 1'b0;
	assign i_cache_req = 1'b0;
	assign i_cache_addr = 32'h0;
	assign i_cache_data = 32'h0;
	assign i_cache_hit = 1'b0;
	assign i_fill_req = 1'b0;
	assign i_fill_addr = 32'h0;
	assign i_fill_data = 128'h0;
	assign i_fill_valid = 1'b0;
	assign d_cache_req = 1'b0;
	assign d_cache_addr = 32'h0;
	assign d_cache_we = 1'b0;
	assign d_cache_data_in = 32'h0;
	assign d_cache_data_out = 32'h0;
	assign d_cache_hit = 1'b0;
	assign d_fill_req = 1'b0;
	assign d_fill_addr = 32'h0;
	assign d_fill_data = 128'h0;
	assign d_fill_valid = 1'b0;

	// Disable cache interface
	assign cache_req = 1'b0;
	assign cache_addr = 32'h0;
	assign cache_burst = 1'b0;
	assign cache_burst_len = 3'b0;

end
endgenerate

// Format Error debug output: [6]=latched, [5:2]=format code from rte_format_word, [1]=SR.S, [0]=SR.M
assign debug_fmt_err = {fmt_err_latched_p, fmt_err_rte_word_p[15:12], fmt_err_sr_p[5], fmt_err_sr_p[4]};

wire cpu_req = (cpustate != 1);

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
reg [2:0] cpu_ipl;

// BUG #135 FIX: Walker chip RAM access detection
// When walker is reading from or writing to chip RAM (address below 2MB), it needs to trigger
// the chipset state machine. Otherwise chipready never goes high and walker hangs.
// Chip RAM is $000000-$1FFFFF = bits 31:21 all zero
wire walker_addr_is_chipram = !walker_addr_latch[31] && !walker_addr_latch[30] &&
                              !walker_addr_latch[29] && !walker_addr_latch[28] &&
                              !walker_addr_latch[27] && !walker_addr_latch[26] &&
                              !walker_addr_latch[25] && !walker_addr_latch[24] &&
                              !walker_addr_latch[23] && !walker_addr_latch[22] &&
                              !walker_addr_latch[21];

// MC68030 U/M bit: Include walker writes for descriptor updates
wire walker_chip_ram = USE_68030_CACHE && (walker_reading | walker_writing) && walker_addr_is_chipram;
wire walker_chip_cycle_active = USE_68030_CACHE && walker_active && walker_addr_is_chipram;

always @(posedge clk) begin
	// BUG #135 FIX: Include walker chip RAM access in chipreq
	// MC68030 bus fault: suppress chip bus when PMMU is translating or faulted
	chipreq <= (cpu_req & ~ramsel & ~fastchip_selack & ~pmmu_suppress_bus) | walker_chip_ram;
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
// BUG #422 FIX: Expose chip bus SM stage for walker stale-cycle detection.
// Previously local to the negedge block, now module-level so the walker
// can wait for chip_stage==0 (bus idle) before accepting chipready.
reg  [1:0] chip_stage;
always @(negedge clk, negedge reset) begin
	reg waitm;
	reg ready;

	if(~reset) begin
		chip_stage <= 0;
		c_as <= 1;
		c_rw <= 1;
		c_uds <= 1;
		c_lds <= 1;
		ready <= 0;
	end
	else begin
		if (ph2n) begin
			waitm <= chip_dtack;
			if(~chip_stage[0]) ipl_i <= chip_ipl;
		end

		chipready <= 0;
		if (ph1n) begin
			chipready <= ready;
			ready <= 0;
			case (chip_stage)
				0: if (chipreq) begin
						c_as <= 0;
						c_rw <= wr;
						c_uds <= uds_in;
						c_lds <= lds_in;
						chip_stage <= 1;
					end
				1: chip_stage <= 2;
				2: begin
						chipdout_i <= chip_dout;
						if (~waitm) begin
							c_as <= 1;
							c_rw <= 1;
							c_uds <= 1;
							c_lds <= 1;
							ready <= 1;
							chip_stage <= 3;
						end
					end
				3: chip_stage <= 0;
			endcase
		end
	end
end

///////////////////// AUTOCONFIG ////////////////////////////

reg       ac_toccata;
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

wire sel_autoconfig = (chip_addr[23:16] == 8'b11101000) && (ac_memcard || ac_toccata); //$E80000 - $E8FFFF

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

endmodule
