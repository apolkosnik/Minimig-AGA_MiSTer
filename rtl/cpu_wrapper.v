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
wire [28:1] ramaddr_comb;
assign ramaddr_comb[28]    = walker_fast_ram ? walker_ramaddr[28] : (sel_zram & ~sel_z3ram0);
assign ramaddr_comb[27]    = walker_fast_ram ? walker_ramaddr[27] : (sel_zram & (~sel_z3ram1 | bus_addr[27]));
assign ramaddr_comb[26:23] = walker_fast_ram ? walker_ramaddr[26:23] : ((sel_z3ram0 | sel_z3ram1) ? bus_addr[26:23]: (sel_rtg ? 4'b1110 : {4{sel_dd}}));
assign ramaddr_comb[22:19] = walker_fast_ram ? walker_ramaddr[22:19] : ({4{sel_dd}} | bus_addr[22:19]);
assign ramaddr_comb[18]    = walker_fast_ram ? walker_ramaddr[18] : (sel_dd   | (sel_kicklower & bootrom) | bus_addr[18]);
assign ramaddr_comb[17:16] = walker_fast_ram ? walker_ramaddr[17:16] : ({2{sel_dd}} | bus_addr[17:16]);
assign ramaddr_comb[15:1]  = walker_fast_ram ? walker_ramaddr[15:1] : bus_addr[15:1];
assign ramaddr = ramaddr_comb;

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
// BUG #439 FIX: Suppress walker_fast_ram during WALKER_RAM_GAP to deassert cpu_cs
// for the SDRAM/DDR3 cache, allowing it to complete one transaction before starting
// the next. Without this, cpu_ack stays latched high and the high word read gets
// stale data from the low word read.
wire walker_fast_ram = USE_68030_CACHE && walker_active && sel_zram_walker
                       && (walker_state != 4'd11)   // != WALKER_RAM_GAP
                       && (walker_state != 4'd12);  // != WALKER_WRITE_RAM_GAP

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
// BUG #408 FIX: When walker reads from legacy chip/Gary bus RAM, force cpu_din to chip_data.
// Without this, CPU's frozen address can set ramsel=1 (turbochip/kickstart), causing
// cpu_din to select ramdat (SDRAM data at CPU address) instead of chip_data (page table).
wire [15:0] cpu_din = (USE_68030_CACHE & cache_hit & ~walker_active & ~pmmu_fault_p) ? cache_data_out_16 :
                      walker_chip_ram ? chip_data :
                      ramsel ? ramdat : fastchip_selack ? fastchip_dout :
                      {sel_autoconfig ? autocfg_data : chip_data[15:12], chip_data[11:0]};
reg         wr;
reg         uds_in;
reg         lds_in;
reg  [15:0] chip_data;
reg  [31:0] vbr;
reg  [23:1] chip_addr_req;
reg  [15:0] chip_din_req;
reg  [23:1] chip_addr_latched;
reg  [15:0] chip_din_latched;

always @* begin
	chip_addr_req = 23'b0;
	chip_din_req  = 16'b0;
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
		// BUG #194 FIX: Walker must only drive the legacy chip/Gary bus for RAM
		// that lives behind that bus. Z2/Z3 Fast RAM uses ramdata, not chip bus.
		// Driving chip_as during Fast RAM access causes bus conflicts with CPU instruction fetch
		// This was causing WhichAmiga and cputest lockups when page tables were in Fast RAM
		if (walker_chip_ram && walker_reading) begin
			chip_addr_req = walker_chip_addr;
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
			chip_din_req = cpu_dout_p;  // Not used for reads
		end else if (walker_chip_ram && walker_writing) begin
			// MC68030 U/M bit: Walker writing descriptor update
			chip_addr_req = walker_chip_addr;
			// BUG #423 FIX: Same AS cycling fix as read path (see above)
			chip_as      = c_as;  // SM cycles AS properly for dtack recycling
			chip_rw      = 0;  // Write operation
			chip_uds     = 0;  // Upper byte strobe active (low)
			chip_lds     = 0;  // Lower byte strobe active (low)
			// BUG #405 FIX: Write high word [31:16] to low address, low word [15:0] to high address (big-endian)
			chip_din_req = walker_write_low_phase ? walker_wdata_latch[31:16] : walker_wdata_latch[15:0];
		end else if (USE_68030_CACHE && walker_chip_cycle_active) begin
			// BUG #408 FIX: Only hold walker address on chip bus when the walk target is Chip RAM.
			// For Fast RAM walks, driving walker_chip_addr with CPU strobes can corrupt chip accesses.
			// Keep walker address only for Chip-RAM transitional states (e.g. WALKER_DONE).
			chip_addr_req = walker_chip_addr;
			chip_as      = c_as;
			chip_rw      = c_rw;
			chip_uds     = c_uds;
			chip_lds     = c_lds;
			chip_din_req = cpu_dout_p;
		end else begin
			// BUG #417 FIX: Use physical address for chip bus routing
			// When MMU remaps addresses, chip_addr must reflect the physical address
			// so the chip bus accesses the correct memory location
			chip_addr_req = pmmu_addr_phys_p[23:1];
			chip_as      = c_as;
			chip_rw      = c_rw;
			chip_uds     = c_uds;
			chip_lds     = c_lds;
			chip_din_req = cpu_dout_p;
		end
		chip_addr    = (chip_stage != 0) ? chip_addr_latched : chip_addr_req;
		chip_din     = (chip_stage != 0) ? chip_din_latched  : chip_din_req;
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
		chip_addr_req = cpu_addr_o[23:1];
		chip_din_req  = cpu_dout_o;
		chip_addr    = chip_addr_req;
		chip_din     = chip_din_req;
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
wire        cpu_halted_p;        // Double bus fault halt
wire  [1:0] kernel_state_p;      // Kernel main state machine
wire        kernel_clkena_lw_p;  // Kernel clock enable (internal)
wire        kernel_stop_p;       // Kernel STOP instruction state
wire        kernel_interrupt_p;  // Kernel interrupt pending
wire        kernel_setendOPC_p;  // setendOPC combinational
wire  [2:0] kernel_IPL_nr_p;    // IPL level (inverted)
wire        pmmu_fault_p;        // PMMU translation fault (suppress bus access)
// CHK/Group2 exception frame debug signals (for EXCF ISSP probe)
wire        kernel_make_trace_p;
wire        kernel_trace_pending_grp2_p;
wire        kernel_useStackframe2_p;
wire        kernel_exec_trap_chk_p;
wire        kernel_set_trap_chk_p;
wire [31:0] kernel_data_write_tmp_p;
wire  [7:0] kernel_FlagsSR_p;
wire [31:0] kernel_trap_vector_p;
wire [31:0] kernel_micro_state_p;    // VHDL integer 0-255 maps to 32-bit
wire [31:0] kernel_next_ms_p;        // VHDL integer 0-255 maps to 32-bit
wire        kernel_trapmake_p;
// CPU Core debug signals (for CPUS ISSP probe)
wire [31:0] kernel_TG68_PC_p;
wire [15:0] kernel_opcode_p;
wire [15:0] kernel_last_opc_read_p;
wire [31:0] kernel_data_read_p;
wire [15:0] kernel_brief_p;
wire [31:0] kernel_memaddr_reg_p;
wire  [5:0] kernel_memmask_p;
wire        kernel_decodeOPC_p;
wire        kernel_setnextpass_p;
wire        kernel_SVmode_p;
wire [31:0] kernel_exe_PC_p;
wire        kernel_trap_illegal_p;
wire        kernel_trap_priv_p;
wire        kernel_trap_addr_error_p;
wire        kernel_trap_berr_p;
wire        kernel_trap_mmu_berr_p;
wire        kernel_make_berr_p;
wire        kernel_berr_exception_active_p;
wire        kernel_pmmu_fault_dispatched_p;
wire        kernel_pmmu_fault_was_cleared_p;
wire        kernel_pmmu_fault_rw_p;
wire        kernel_pmmu_fault_is_insn_p;
wire  [2:0] kernel_pmmu_fault_fc_p;
wire        kernel_trap_1111_p;
wire        kernel_pmmu_reg_we_p;
wire  [4:0] kernel_pmmu_reg_sel_p;
wire [31:0] kernel_pmmu_reg_wdat_p;
wire        kernel_pmmu_reg_part_p;
// T0 trace investigation signals
wire        kernel_exec_directSR_p;
wire        kernel_exec_to_SR_p;
wire [31:0] kernel_usp_p;
wire [31:0] kernel_msp_p;
wire [31:0] kernel_isp_p;
wire        kernel_a7_is_msp_p;
wire        kernel_interrupt_mode_p;
wire        kernel_rte_saved_mbit_p;
// Register file debug (for REGS ISSP probe)
wire [31:0] kernel_regfile_d0_p, kernel_regfile_d1_p, kernel_regfile_d2_p, kernel_regfile_d3_p;
wire [31:0] kernel_regfile_d4_p, kernel_regfile_d5_p, kernel_regfile_d6_p, kernel_regfile_d7_p;
wire [31:0] kernel_regfile_a0_p, kernel_regfile_a1_p, kernel_regfile_a2_p, kernel_regfile_a3_p;
wire [31:0] kernel_regfile_a4_p, kernel_regfile_a5_p, kernel_regfile_a6_p, kernel_regfile_a7_p;
// Format Error debug latch signals from Kernel
wire        fmt_err_latched_p;
wire [15:0] fmt_err_rte_word_p;
wire  [7:0] fmt_err_sr_p;
wire [31:0] fmt_err_pc_p;
wire [31:0] fmt_err_addr_p;
reg         pmmu_walker_ack_p;
reg  [31:0] pmmu_walker_data_p;
reg         pmmu_walker_berr_p;  // BUG #156 FIX: Bus error during table walk (sets MMUSR B bit)

// SignalTap/ISSP debug is intentionally opt-in. Leaving these probes preserved in
// normal builds adds very wide fanout on already timing-critical CPU/MMU paths.
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
`define CPUWRAP_DEBUG_KEEP (* noprune, preserve *)
`else
`define CPUWRAP_DEBUG_KEEP
`endif

// SignalTap debug registers (from PMMU via Kernel)
wire [31:0] stp_pmmu_tc_w, stp_pmmu_tt0_w, stp_pmmu_tt1_w;
wire [31:0] stp_pmmu_crp_hi_w, stp_pmmu_crp_lo_w;
wire [31:0] stp_pmmu_srp_hi_w, stp_pmmu_srp_lo_w;
wire  [4:0] stp_pmmu_wstate_w;
wire [21:0] stp_atc_buserr_w, stp_atc_valid_w;
wire [15:0] stp_fault_status_w;
wire [31:0] stp_saved_addr_w;
wire [31:0] stp_walk_desc_addr_w, stp_walk_desc_data_w;
wire [31:0] stp_ptr1_desc_addr_w, stp_ptr1_desc_data_w;
wire [31:0] stp_ptr2_desc_addr_w, stp_ptr2_desc_data_w;
wire [31:0] stp_ptr3_desc_addr_w, stp_ptr3_desc_data_w;
wire  [2:0] stp_saved_fc_w;
wire [15:0] kernel_pmmu_pending_flags_p;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_pmmu_tc;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_pmmu_tt0;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_pmmu_tt1;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_pmmu_crp_hi;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_pmmu_crp_lo;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_pmmu_srp_hi;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_pmmu_srp_lo;
`CPUWRAP_DEBUG_KEEP reg  [4:0] stp_pmmu_wstate;
`CPUWRAP_DEBUG_KEEP reg        stp_pmmu_fault;
`CPUWRAP_DEBUG_KEEP reg        stp_pmmu_busy;
// Sticky fault latch: captures fault and holds until JTAG reads new build
`CPUWRAP_DEBUG_KEEP reg        stp_fault_latched;
`CPUWRAP_DEBUG_KEEP reg        stp_walker_timeout_latched;
// Latch PMMU state at moment of fault
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_tc;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_addr;
`CPUWRAP_DEBUG_KEEP reg  [4:0] stp_fault_wstate;
`CPUWRAP_DEBUG_KEEP reg [21:0] stp_atc_buserr;
`CPUWRAP_DEBUG_KEEP reg [21:0] stp_atc_valid;
// Sticky: latch ATC buserr state at fault time
`CPUWRAP_DEBUG_KEEP reg [21:0] stp_fault_atc_buserr;
`CPUWRAP_DEBUG_KEEP reg [21:0] stp_fault_atc_valid;
// Sticky: latch fault status (MMUSR format) and walker's saved_addr at fault time
`CPUWRAP_DEBUG_KEEP reg [15:0] stp_fault_mmusr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_saved_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_desc_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_desc_data;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_ptr1_desc_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_ptr1_desc_data;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_ptr2_desc_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_ptr2_desc_data;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_ptr3_desc_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_ptr3_desc_data;
`CPUWRAP_DEBUG_KEEP reg  [2:0] stp_fault_fc;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_pc;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_exe_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] stp_fault_opcode;
`CPUWRAP_DEBUG_KEEP reg  [1:0] stp_fault_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_fault_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_fault_next_micro_state;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_memaddr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_log_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_phys_addr;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_fault_flags;
`CPUWRAP_DEBUG_KEEP reg        stp_fault_rw;
`CPUWRAP_DEBUG_KEEP reg        stp_fault_is_insn;
`CPUWRAP_DEBUG_KEEP reg  [2:0] stp_fault_fault_fc;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_fault_a7;
wire [0:0] pmmu_issp_source;
wire [0:0] pmm2_issp_source;
wire [0:0] tcwr_issp_source;
`ifndef ENABLE_CPUWRAP_DEBUG_ISSP
assign pmmu_issp_source = 1'b0;
assign pmm2_issp_source = 1'b0;
assign tcwr_issp_source = 1'b0;
`endif
// Kernel internal state debug (6 bits, probe limit=511)
`CPUWRAP_DEBUG_KEEP reg  [2:0] stp_ipl_nr;
`CPUWRAP_DEBUG_KEEP reg        stp_setendOPC;
`CPUWRAP_DEBUG_KEEP reg        stp_stop;

// TC write trace.  The sticky PMMU fault latch can show that TC was enabled,
// but live TC may later be zero after the OS falls back.  Capture the PMOVE
// writes that changed TC so the failure path is attributable.
`CPUWRAP_DEBUG_KEEP reg        tcwr_seen;
`CPUWRAP_DEBUG_KEEP reg  [7:0] tcwr_count;
`CPUWRAP_DEBUG_KEEP reg [31:0] tcwr_last_value;
`CPUWRAP_DEBUG_KEEP reg [31:0] tcwr_last_pc;
`CPUWRAP_DEBUG_KEEP reg [31:0] tcwr_last_exe_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] tcwr_last_opcode;
`CPUWRAP_DEBUG_KEEP reg [15:0] tcwr_last_brief;
`CPUWRAP_DEBUG_KEEP reg  [7:0] tcwr_last_flags;
`CPUWRAP_DEBUG_KEEP reg  [7:0] tcwr_last_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] tcwr_last_next_micro_state;
`CPUWRAP_DEBUG_KEEP reg        tcwr_last_part;
`CPUWRAP_DEBUG_KEEP reg        tcwr_enable_seen;
`CPUWRAP_DEBUG_KEEP reg [31:0] tcwr_first_enable_value;
`CPUWRAP_DEBUG_KEEP reg [31:0] tcwr_first_enable_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] tcwr_first_enable_opcode;
`CPUWRAP_DEBUG_KEEP reg [15:0] tcwr_first_enable_brief;
`CPUWRAP_DEBUG_KEEP reg        tcwr_disable_seen;
`CPUWRAP_DEBUG_KEEP reg [31:0] tcwr_first_disable_value;
`CPUWRAP_DEBUG_KEEP reg [31:0] tcwr_first_disable_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] tcwr_first_disable_opcode;
`CPUWRAP_DEBUG_KEEP reg [15:0] tcwr_first_disable_brief;
`CPUWRAP_DEBUG_KEEP reg  [7:0] tcwr_first_disable_flags;
`CPUWRAP_DEBUG_KEEP reg        tcwr_tc_we_prev;

wire tcwr_tc_we = kernel_pmmu_reg_we_p && (kernel_pmmu_reg_sel_p == 5'b10000);

always @(posedge clk) begin
	if (~reset || tcwr_issp_source[0]) begin
		tcwr_seen <= 0;
		tcwr_count <= 0;
		tcwr_last_value <= 0;
		tcwr_last_pc <= 0;
		tcwr_last_exe_pc <= 0;
		tcwr_last_opcode <= 0;
		tcwr_last_brief <= 0;
		tcwr_last_flags <= 0;
		tcwr_last_micro_state <= 0;
		tcwr_last_next_micro_state <= 0;
		tcwr_last_part <= 0;
		tcwr_enable_seen <= 0;
		tcwr_first_enable_value <= 0;
		tcwr_first_enable_pc <= 0;
		tcwr_first_enable_opcode <= 0;
		tcwr_first_enable_brief <= 0;
		tcwr_disable_seen <= 0;
		tcwr_first_disable_value <= 0;
		tcwr_first_disable_pc <= 0;
		tcwr_first_disable_opcode <= 0;
		tcwr_first_disable_brief <= 0;
		tcwr_first_disable_flags <= 0;
		tcwr_tc_we_prev <= 0;
	end else begin
		tcwr_tc_we_prev <= tcwr_tc_we;
		if (tcwr_tc_we && !tcwr_tc_we_prev) begin
			tcwr_seen <= 1;
			tcwr_count <= tcwr_count + 8'd1;
			tcwr_last_value <= kernel_pmmu_reg_wdat_p;
			tcwr_last_pc <= kernel_TG68_PC_p;
			tcwr_last_exe_pc <= kernel_exe_PC_p;
			tcwr_last_opcode <= kernel_opcode_p;
			tcwr_last_brief <= kernel_brief_p;
			tcwr_last_flags <= kernel_FlagsSR_p;
			tcwr_last_micro_state <= kernel_micro_state_p[7:0];
			tcwr_last_next_micro_state <= kernel_next_ms_p[7:0];
			tcwr_last_part <= kernel_pmmu_reg_part_p;
			if (kernel_pmmu_reg_wdat_p[31] && !tcwr_enable_seen) begin
				tcwr_enable_seen <= 1;
				tcwr_first_enable_value <= kernel_pmmu_reg_wdat_p;
				tcwr_first_enable_pc <= kernel_TG68_PC_p;
				tcwr_first_enable_opcode <= kernel_opcode_p;
				tcwr_first_enable_brief <= kernel_brief_p;
			end
			if (!kernel_pmmu_reg_wdat_p[31] && tcwr_enable_seen && !tcwr_disable_seen) begin
				tcwr_disable_seen <= 1;
				tcwr_first_disable_value <= kernel_pmmu_reg_wdat_p;
				tcwr_first_disable_pc <= kernel_TG68_PC_p;
				tcwr_first_disable_opcode <= kernel_opcode_p;
				tcwr_first_disable_brief <= kernel_brief_p;
				tcwr_first_disable_flags <= kernel_FlagsSR_p;
			end
		end
	end
end
always @(posedge clk) begin
	stp_pmmu_tc     <= stp_pmmu_tc_w;
	stp_pmmu_tt0    <= stp_pmmu_tt0_w;
	stp_pmmu_tt1    <= stp_pmmu_tt1_w;
	stp_pmmu_crp_hi <= stp_pmmu_crp_hi_w;
	stp_pmmu_crp_lo <= stp_pmmu_crp_lo_w;
	stp_pmmu_srp_hi <= stp_pmmu_srp_hi_w;
	stp_pmmu_srp_lo <= stp_pmmu_srp_lo_w;
	stp_pmmu_wstate <= stp_pmmu_wstate_w;
	stp_pmmu_fault  <= pmmu_fault_p;
	stp_pmmu_busy   <= pmmu_busy_p;
	stp_atc_buserr  <= stp_atc_buserr_w;
	stp_atc_valid   <= stp_atc_valid_w;
	// Kernel internal state debug
	stp_ipl_nr         <= kernel_IPL_nr_p;
	stp_setendOPC      <= kernel_setendOPC_p;
	stp_stop           <= kernel_stop_p;
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
		stp_fault_desc_addr <= 0;
		stp_fault_desc_data <= 0;
		stp_fault_ptr1_desc_addr <= 0;
		stp_fault_ptr1_desc_data <= 0;
		stp_fault_ptr2_desc_addr <= 0;
		stp_fault_ptr2_desc_data <= 0;
		stp_fault_ptr3_desc_addr <= 0;
		stp_fault_ptr3_desc_data <= 0;
		stp_fault_fc <= 0;
		stp_fault_pc <= 0;
		stp_fault_exe_pc <= 0;
		stp_fault_opcode <= 0;
		stp_fault_state <= 0;
		stp_fault_micro_state <= 0;
		stp_fault_next_micro_state <= 0;
		stp_fault_memaddr <= 0;
		stp_fault_log_addr <= 0;
		stp_fault_phys_addr <= 0;
		stp_fault_flags <= 0;
		stp_fault_rw <= 0;
		stp_fault_is_insn <= 0;
		stp_fault_fault_fc <= 0;
		stp_fault_a7 <= 0;
	end else if (pmmu_issp_source[0] || pmm2_issp_source[0]) begin
		stp_fault_latched <= 0;
		stp_walker_timeout_latched <= 0;
		stp_fault_tc <= 0;
		stp_fault_addr <= 0;
		stp_fault_wstate <= 0;
		stp_fault_atc_buserr <= 0;
		stp_fault_atc_valid <= 0;
		stp_fault_mmusr <= 0;
		stp_fault_saved_addr <= 0;
		stp_fault_desc_addr <= 0;
		stp_fault_desc_data <= 0;
		stp_fault_ptr1_desc_addr <= 0;
		stp_fault_ptr1_desc_data <= 0;
		stp_fault_ptr2_desc_addr <= 0;
		stp_fault_ptr2_desc_data <= 0;
		stp_fault_ptr3_desc_addr <= 0;
		stp_fault_ptr3_desc_data <= 0;
		stp_fault_fc <= 0;
		stp_fault_pc <= 0;
		stp_fault_exe_pc <= 0;
		stp_fault_opcode <= 0;
		stp_fault_state <= 0;
		stp_fault_micro_state <= 0;
		stp_fault_next_micro_state <= 0;
		stp_fault_memaddr <= 0;
		stp_fault_log_addr <= 0;
		stp_fault_phys_addr <= 0;
		stp_fault_flags <= 0;
		stp_fault_rw <= 0;
		stp_fault_is_insn <= 0;
		stp_fault_fault_fc <= 0;
		stp_fault_a7 <= 0;
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
			stp_fault_desc_addr <= stp_walk_desc_addr_w;
			stp_fault_desc_data <= stp_walk_desc_data_w;
			stp_fault_ptr1_desc_addr <= stp_ptr1_desc_addr_w;
			stp_fault_ptr1_desc_data <= stp_ptr1_desc_data_w;
			stp_fault_ptr2_desc_addr <= stp_ptr2_desc_addr_w;
			stp_fault_ptr2_desc_data <= stp_ptr2_desc_data_w;
			stp_fault_ptr3_desc_addr <= stp_ptr3_desc_addr_w;
			stp_fault_ptr3_desc_data <= stp_ptr3_desc_data_w;
			stp_fault_fc <= stp_saved_fc_w;
			stp_fault_pc <= kernel_TG68_PC_p;
			stp_fault_exe_pc <= kernel_exe_PC_p;
			stp_fault_opcode <= kernel_opcode_p;
			stp_fault_state <= kernel_state_p;
			stp_fault_micro_state <= kernel_micro_state_p[7:0];
			stp_fault_next_micro_state <= kernel_next_ms_p[7:0];
			stp_fault_memaddr <= kernel_memaddr_reg_p;
			stp_fault_log_addr <= pmmu_addr_log_p;
			stp_fault_phys_addr <= pmmu_addr_phys_p;
			stp_fault_flags <= kernel_FlagsSR_p;
			stp_fault_rw <= kernel_pmmu_fault_rw_p;
			stp_fault_is_insn <= kernel_pmmu_fault_is_insn_p;
			stp_fault_fault_fc <= kernel_pmmu_fault_fc_p;
			stp_fault_a7 <= kernel_regfile_a7_p;
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
				stp_fault_desc_addr <= stp_walk_desc_addr_w;
				stp_fault_desc_data <= stp_walk_desc_data_w;
				stp_fault_ptr1_desc_addr <= stp_ptr1_desc_addr_w;
				stp_fault_ptr1_desc_data <= stp_ptr1_desc_data_w;
				stp_fault_ptr2_desc_addr <= stp_ptr2_desc_addr_w;
				stp_fault_ptr2_desc_data <= stp_ptr2_desc_data_w;
				stp_fault_ptr3_desc_addr <= stp_ptr3_desc_addr_w;
				stp_fault_ptr3_desc_data <= stp_ptr3_desc_data_w;
				stp_fault_fc <= stp_saved_fc_w;
				stp_fault_pc <= kernel_TG68_PC_p;
				stp_fault_exe_pc <= kernel_exe_PC_p;
				stp_fault_opcode <= kernel_opcode_p;
				stp_fault_state <= kernel_state_p;
				stp_fault_micro_state <= kernel_micro_state_p[7:0];
				stp_fault_next_micro_state <= kernel_next_ms_p[7:0];
				stp_fault_memaddr <= kernel_memaddr_reg_p;
				stp_fault_log_addr <= pmmu_addr_log_p;
				stp_fault_phys_addr <= pmmu_addr_phys_p;
				stp_fault_flags <= kernel_FlagsSR_p;
				stp_fault_rw <= kernel_pmmu_fault_rw_p;
				stp_fault_is_insn <= kernel_pmmu_fault_is_insn_p;
				stp_fault_fault_fc <= kernel_pmmu_fault_fc_p;
				stp_fault_a7 <= kernel_regfile_a7_p;
			end
		end
	end
end

// EXCF ISSP: Sticky trap-event latch for CHK/Group2 exception frame debugging
// micro_state integer encoding (trap0=53, trap00=52, trace_stk_grp2=114)
// Probe layout (128 bits, MSB first):
//   [127]     chk_dispatch_latched
//   [126]     make_trace_at_dispatch
//   [125]     exec_trap_chk_at_dispatch
//   [124]     set_trap_chk_at_dispatch
//   [123:116] FlagsSR_at_dispatch (8 bits)
//   [115:104] trap_vector_at_dispatch (12 bits)
//   [103:96]  next_micro_state_at_dispatch (8 bits, 52=trap00 53=trap0)
//   [95]      fmt1_latched (first trap0 format word)
//   [94]      useStackframe2_at_fmt1
//   [93:78]   format_word_1 (16 bits)
//   [77]      fmt2_latched (second trap0 format word, stacked trace)
//   [76]      useStackframe2_at_fmt2
//   [75:60]   format_word_2 (16 bits)
//   [59]      trace_stk_grp2_entered
//   [58:0]    unused

`CPUWRAP_DEBUG_KEEP reg        excf_chk_dispatch_latched;
`CPUWRAP_DEBUG_KEEP reg        excf_make_trace_cap;
`CPUWRAP_DEBUG_KEEP reg        excf_exec_trap_chk_cap;
`CPUWRAP_DEBUG_KEEP reg        excf_set_trap_chk_cap;
`CPUWRAP_DEBUG_KEEP reg  [7:0] excf_flagsSR_cap;
`CPUWRAP_DEBUG_KEEP reg [11:0] excf_trap_vector_cap;
`CPUWRAP_DEBUG_KEEP reg  [7:0] excf_next_ms_cap;
`CPUWRAP_DEBUG_KEEP reg        excf_fmt1_latched;
`CPUWRAP_DEBUG_KEEP reg        excf_useStackframe2_1;
`CPUWRAP_DEBUG_KEEP reg [15:0] excf_format_word_1;
`CPUWRAP_DEBUG_KEEP reg        excf_fmt2_latched;
`CPUWRAP_DEBUG_KEEP reg        excf_useStackframe2_2;
`CPUWRAP_DEBUG_KEEP reg [15:0] excf_format_word_2;
`CPUWRAP_DEBUG_KEEP reg        excf_trace_stk_grp2_entered;

wire [0:0] excf_issp_source;
`ifndef ENABLE_CPUWRAP_DEBUG_ISSP
assign excf_issp_source = 1'b0;
`endif

always @(posedge clk or negedge reset) begin
	if (!reset) begin
		excf_chk_dispatch_latched  <= 0;
		excf_make_trace_cap        <= 0;
		excf_exec_trap_chk_cap     <= 0;
		excf_set_trap_chk_cap      <= 0;
		excf_flagsSR_cap           <= 0;
		excf_trap_vector_cap       <= 0;
		excf_next_ms_cap           <= 0;
		excf_fmt1_latched          <= 0;
		excf_useStackframe2_1      <= 0;
		excf_format_word_1         <= 0;
		excf_fmt2_latched          <= 0;
		excf_useStackframe2_2      <= 0;
		excf_format_word_2         <= 0;
		excf_trace_stk_grp2_entered <= 0;
	end else if (excf_issp_source[0]) begin
		// Synchronous clear via ISSP source bit
		excf_chk_dispatch_latched  <= 0;
		excf_make_trace_cap        <= 0;
		excf_exec_trap_chk_cap     <= 0;
		excf_set_trap_chk_cap      <= 0;
		excf_flagsSR_cap           <= 0;
		excf_trap_vector_cap       <= 0;
		excf_next_ms_cap           <= 0;
		excf_fmt1_latched          <= 0;
		excf_useStackframe2_1      <= 0;
		excf_format_word_1         <= 0;
		excf_fmt2_latched          <= 0;
		excf_useStackframe2_2      <= 0;
		excf_format_word_2         <= 0;
		excf_trace_stk_grp2_entered <= 0;
	end else if (kernel_clkena_lw_p) begin
		// Group A: capture at CHK trap dispatch (trapmake with exec or set trap_chk)
		// Only capture when make_trace is active (T1 trace) so we see the
		// stacked trace path, not a normal non-traced CHK dispatch.
		if (kernel_trapmake_p && (kernel_exec_trap_chk_p || kernel_set_trap_chk_p)
		    && kernel_make_trace_p
		    && !excf_chk_dispatch_latched) begin
			excf_chk_dispatch_latched <= 1;
			excf_make_trace_cap       <= kernel_make_trace_p;
			excf_exec_trap_chk_cap    <= kernel_exec_trap_chk_p;
			excf_set_trap_chk_cap     <= kernel_set_trap_chk_p;
			excf_flagsSR_cap          <= kernel_FlagsSR_p;
			excf_trap_vector_cap      <= kernel_trap_vector_p[11:0];
			excf_next_ms_cap          <= kernel_next_ms_p[7:0];
		end
		// Group B: capture format word at trap1 (micro_state==54).
		// GATED on excf_chk_dispatch_latched so we only capture the CHK frame,
		// not format words from earlier unrelated exceptions (F-line, priv, etc.).
		// data_write_tmp is SET by the kernel clocked process at the trap0 edge,
		// so its new value is only visible on the following cycle (trap1).
		if (excf_chk_dispatch_latched && kernel_micro_state_p == 32'd54 && !excf_fmt1_latched) begin
			excf_fmt1_latched      <= 1;
			excf_useStackframe2_1  <= kernel_useStackframe2_p;
			excf_format_word_1     <= kernel_data_write_tmp_p[15:0];
		end else if (excf_chk_dispatch_latched && kernel_micro_state_p == 32'd54 && excf_fmt1_latched && !excf_fmt2_latched) begin
			excf_fmt2_latched      <= 1;
			excf_useStackframe2_2  <= kernel_useStackframe2_p;
			excf_format_word_2     <= kernel_data_write_tmp_p[15:0];
		end
		// Group C: trace_stk_grp2 entered (micro_state==114)
		// Also gated on CHK dispatch to avoid capturing unrelated trace entries
		if (excf_chk_dispatch_latched && kernel_micro_state_p == 32'd114) begin
			excf_trace_stk_grp2_entered <= 1;
		end
	end
end

// In-System Sources and Probes (ISSP) for JTAG readback of PMMU debug state
// Probe layout (MSB first):
//   TC[31:0] + TT0[31:0] + TT1[31:0] = 96
//   + CRP_HI[31:0] + CRP_LO[31:0] + SRP_HI[31:0] + SRP_LO[31:0] = 128
//   + WSTATE[4:0] + FAULT + BUSY = 7
//   + ATC_BUSERR[21:0] + ATC_VALID[21:0] = 44
//   + FAULT_LATCHED + WALKER_TIMEOUT_LATCHED = 2
//   + FAULT_TC[31:0] + FAULT_ADDR[31:0] + FAULT_WSTATE[4:0] = 69
//   + FAULT_ATC_BUSERR[21:0] + FAULT_ATC_VALID[21:0] = 44
//   + FAULT_MMUSR[15:0] + FAULT_SAVED_ADDR[31:0] = 48
//   + FAULT_DESC_ADDR[31:0] + FAULT_DESC_DATA[31:0] = 64
//   + FAULT_FC[2:0] = 3
//   + IPL_NR[2:0] + setendOPC + STOP = 5
//   Total = 511 (max for altsource_probe)
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (0),
	.instance_id             ("PMMU"),
	.probe_width             (511),
	.source_width            (1),
	.enable_metastability    ("YES")
) pmmu_issp (
	.probe ({stp_pmmu_tc, stp_pmmu_tt0, stp_pmmu_tt1,
	         stp_pmmu_crp_hi, stp_pmmu_crp_lo, stp_pmmu_srp_hi, stp_pmmu_srp_lo,
	         stp_pmmu_wstate, stp_pmmu_fault, stp_pmmu_busy,
	         stp_atc_buserr, stp_atc_valid,
	         stp_fault_latched, stp_walker_timeout_latched,
	         stp_fault_tc, stp_fault_addr, stp_fault_wstate,
	         stp_fault_atc_buserr, stp_fault_atc_valid,
	         stp_fault_mmusr, stp_fault_saved_addr,
	         stp_fault_desc_addr, stp_fault_desc_data,
	         stp_fault_fc,
	         stp_ipl_nr, stp_setendOPC, stp_stop,
	         cpu_halted_p}),
	.source (pmmu_issp_source)
);
`endif

// Secondary PMMU sticky probe: per-level descriptor snapshots (A/B/C)
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (1),
	.instance_id             ("PMM2"),
	.probe_width             (433),
	.source_width            (1),
	.enable_metastability    ("YES")
) pmmu_issp_desc (
	.probe ({stp_fault_pc, stp_fault_exe_pc, stp_fault_opcode,
	         stp_fault_state, stp_fault_micro_state, stp_fault_next_micro_state,
	         stp_fault_memaddr, stp_fault_log_addr, stp_fault_phys_addr,
	         stp_fault_flags, stp_fault_rw, stp_fault_is_insn, stp_fault_fault_fc,
	         stp_fault_a7,
	         stp_fault_latched, stp_walker_timeout_latched,
	         stp_fault_ptr1_desc_addr, stp_fault_ptr1_desc_data,
	         stp_fault_ptr2_desc_addr, stp_fault_ptr2_desc_data,
	         stp_fault_ptr3_desc_addr, stp_fault_ptr3_desc_data}),
	.source (pmm2_issp_source)
);
`endif

// TC write trace probe.  Source bit 0 clears the sticky history.
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (10),
	.instance_id             ("TCWR"),
	.probe_width             (412),
	.source_width            (1),
	.enable_metastability    ("YES")
) tcwr_issp (
	.probe ({
		tcwr_seen,                  // [411]
		tcwr_count,                 // [410:403]
		tcwr_last_value,            // [402:371]
		tcwr_last_pc,               // [370:339]
		tcwr_last_exe_pc,           // [338:307]
		tcwr_last_opcode,           // [306:291]
		tcwr_last_brief,            // [290:275]
		tcwr_last_flags,            // [274:267]
		tcwr_last_micro_state,      // [266:259]
		tcwr_last_next_micro_state, // [258:251]
		tcwr_last_part,             // [250]
		tcwr_enable_seen,           // [249]
		tcwr_first_enable_value,    // [248:217]
		tcwr_first_enable_pc,       // [216:185]
		tcwr_first_enable_opcode,   // [184:169]
		tcwr_first_enable_brief,    // [168:153]
		tcwr_disable_seen,          // [152]
		tcwr_first_disable_value,   // [151:120]
		tcwr_first_disable_pc,      // [119:88]
		tcwr_first_disable_opcode,  // [87:72]
		tcwr_first_disable_brief,   // [71:56]
		tcwr_first_disable_flags,   // [55:48]
		stp_pmmu_tc,                // [47:16]
		kernel_pmmu_pending_flags_p // [15:0]
	}),
	.source (tcwr_issp_source)
);
`endif

// Tertiary ISSP: CHK/Group2 exception frame trap-event latch (instance 2)
// Probe width = 128 bits; source width = 1 (bit [0] clears the latch)
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (2),
	.instance_id             ("EXCF"),
	.probe_width             (128),
	.source_width            (1),
	.enable_metastability    ("YES")
) excf_issp (
	.probe ({excf_chk_dispatch_latched,
	         excf_make_trace_cap,
	         excf_exec_trap_chk_cap,
	         excf_set_trap_chk_cap,
	         excf_flagsSR_cap,
	         excf_trap_vector_cap,
	         excf_next_ms_cap,
	         excf_fmt1_latched,
	         excf_useStackframe2_1,
	         excf_format_word_1,
	         excf_fmt2_latched,
	         excf_useStackframe2_2,
	         excf_format_word_2,
	         excf_trace_stk_grp2_entered,
	         59'b0}),
	.source (excf_issp_source)
);
`endif

// ============================================================================
// ISSP Instance 3: CPUS - CPU Core State (live + sticky hang capture)
// ============================================================================
// Live probe (256 bits):
//   PC[31:0]=32, opcode[15:0]=16, state[1:0]=2, micro_state[7:0]=8,
//   next_micro_state[7:0]=8, memmask[5:0]=6, FlagsSR[7:0]=8, SVmode=1,
//   memaddr_reg[31:0]=32, exe_PC[31:0]=32, last_opc_read[15:0]=16,
//   brief[15:0]=16, trap_vector[31:0]=32,
//   trap_illegal=1, trap_priv=1, trap_addr_error=1, trap_berr=1,
//   trap_mmu_berr=1, make_berr=1, trap_1111=1, trapmake=1,
//   decodeOPC=1, setnextpass=1, setendOPC=1, stop=1, clkena_lw=1,
//   cpu_halted=1, pmmu_fault=1, interrupt=1
//   = 32+16+2+8+8+6+8+1+32+32+16+16+32+8+1+1+1+1+1+1 = 223
// Sticky hang capture (223 bits, same layout):
//   hang_latched=1, hang_counter_overflow=1, + same fields = 224
// Source: 1 bit (clear sticky latch)
// Total probe = 223 + 224 = 447

`CPUWRAP_DEBUG_KEEP reg [31:0] stp_cpu_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] stp_cpu_opcode;
`CPUWRAP_DEBUG_KEEP reg  [1:0] stp_cpu_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_cpu_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_cpu_next_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [5:0] stp_cpu_memmask;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_cpu_flagsSR;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_SVmode;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_cpu_memaddr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_cpu_exe_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] stp_cpu_last_opc_read;
`CPUWRAP_DEBUG_KEEP reg [15:0] stp_cpu_brief;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_cpu_trap_vector;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_trap_illegal;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_trap_priv;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_trap_addr_error;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_trap_berr;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_trap_mmu_berr;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_make_berr;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_trap_1111;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_trapmake;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_decodeOPC;
`CPUWRAP_DEBUG_KEEP reg        stp_cpu_setnextpass;

// Sticky hang capture: latches CPU state when CPU stops advancing
// Detection: if micro_state and PC don't change for 2^16 cycles (~580us at 114MHz)
`CPUWRAP_DEBUG_KEEP reg        stp_hang_latched;
`CPUWRAP_DEBUG_KEEP reg        stp_hang_overflow;  // counter saturated
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_hang_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] stp_hang_opcode;
`CPUWRAP_DEBUG_KEEP reg  [1:0] stp_hang_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_hang_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_hang_next_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [5:0] stp_hang_memmask;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stp_hang_flagsSR;
`CPUWRAP_DEBUG_KEEP reg        stp_hang_SVmode;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_hang_memaddr;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_hang_exe_pc;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_hang_trap_vector;
`CPUWRAP_DEBUG_KEEP reg        stp_hang_trapmake;
`CPUWRAP_DEBUG_KEEP reg        stp_hang_pmmu_fault;
`CPUWRAP_DEBUG_KEEP reg        stp_hang_cpu_halted;

reg [15:0] hang_detect_counter;
reg [31:0] hang_prev_pc;
reg  [7:0] hang_prev_micro;
wire [0:0] cpus_issp_source;  // JTAG clear for hang latch and T0 latch
`ifndef ENABLE_CPUWRAP_DEBUG_ISSP
assign cpus_issp_source = 1'b0;
`endif
wire [0:0] fmtd_issp_source;
wire [0:0] rted_issp_source;
wire [0:0] trpd_issp_source;
wire [0:0] haltd_issp_source;
wire [0:0] stkd_issp_source;
`ifndef ENABLE_CPUWRAP_DEBUG_ISSP
assign fmtd_issp_source = 1'b0;
assign rted_issp_source = 1'b0;
assign trpd_issp_source = 1'b0;
assign haltd_issp_source = 1'b0;
assign stkd_issp_source = 1'b0;
`endif

// RTE microstate encoding from TG68K_Pack.vhd.
localparam [7:0] MS_RTE1 = 8'd44;
localparam [7:0] MS_RTE2 = 8'd45;
localparam [7:0] MS_RTE3 = 8'd46;
localparam [7:0] MS_RTE4 = 8'd47;
localparam [7:0] MS_RTE6 = 8'd49;
localparam [7:0] MS_TRAP0 = 8'd53;

`CPUWRAP_DEBUG_KEEP reg        rted_seen;
`CPUWRAP_DEBUG_KEEP reg        rted_active;
`CPUWRAP_DEBUG_KEEP reg        rted_done;
`CPUWRAP_DEBUG_KEEP reg  [2:0] rted_read_count;
`CPUWRAP_DEBUG_KEEP reg  [3:0] rted_seq_count;
`CPUWRAP_DEBUG_KEEP reg [31:0] rted_entry_pc;
`CPUWRAP_DEBUG_KEEP reg [31:0] rted_entry_a7;
`CPUWRAP_DEBUG_KEEP reg  [7:0] rted_entry_flags;
`CPUWRAP_DEBUG_KEEP reg [31:0] rted_after_pc;

`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r0_log;
`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r0_phys;
`CPUWRAP_DEBUG_KEEP reg [15:0] rted_r0_din;
`CPUWRAP_DEBUG_KEEP reg  [7:0] rted_r0_micro;
`CPUWRAP_DEBUG_KEEP reg  [1:0] rted_r0_state;
`CPUWRAP_DEBUG_KEEP reg        rted_r0_lw;

`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r1_log;
`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r1_phys;
`CPUWRAP_DEBUG_KEEP reg [15:0] rted_r1_din;
`CPUWRAP_DEBUG_KEEP reg  [7:0] rted_r1_micro;
`CPUWRAP_DEBUG_KEEP reg  [1:0] rted_r1_state;
`CPUWRAP_DEBUG_KEEP reg        rted_r1_lw;

`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r2_log;
`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r2_phys;
`CPUWRAP_DEBUG_KEEP reg [15:0] rted_r2_din;
`CPUWRAP_DEBUG_KEEP reg  [7:0] rted_r2_micro;
`CPUWRAP_DEBUG_KEEP reg  [1:0] rted_r2_state;
`CPUWRAP_DEBUG_KEEP reg        rted_r2_lw;

`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r3_log;
`CPUWRAP_DEBUG_KEEP reg [31:0] rted_r3_phys;
`CPUWRAP_DEBUG_KEEP reg [15:0] rted_r3_din;
`CPUWRAP_DEBUG_KEEP reg  [7:0] rted_r3_micro;
`CPUWRAP_DEBUG_KEEP reg  [1:0] rted_r3_state;
`CPUWRAP_DEBUG_KEEP reg        rted_r3_lw;

`CPUWRAP_DEBUG_KEEP reg        trpd_seen;
`CPUWRAP_DEBUG_KEEP reg        trpd_active;
`CPUWRAP_DEBUG_KEEP reg        trpd_done;
`CPUWRAP_DEBUG_KEEP reg  [2:0] trpd_write_count;
`CPUWRAP_DEBUG_KEEP reg  [3:0] trpd_seq_count;
`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_start_pc;
`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_start_exe_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] trpd_start_opcode;
`CPUWRAP_DEBUG_KEEP reg  [7:0] trpd_start_flags;
`CPUWRAP_DEBUG_KEEP reg [15:0] trpd_start_vector;
`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_start_a7;

`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w0_log;
`CPUWRAP_DEBUG_KEEP reg [15:0] trpd_w0_dout;
`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w0_tmp;
`CPUWRAP_DEBUG_KEEP reg  [7:0] trpd_w0_micro;
`CPUWRAP_DEBUG_KEEP reg        trpd_w0_lw;

`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w1_log;
`CPUWRAP_DEBUG_KEEP reg [15:0] trpd_w1_dout;
`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w1_tmp;
`CPUWRAP_DEBUG_KEEP reg  [7:0] trpd_w1_micro;
`CPUWRAP_DEBUG_KEEP reg        trpd_w1_lw;

`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w2_log;
`CPUWRAP_DEBUG_KEEP reg [15:0] trpd_w2_dout;
`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w2_tmp;
`CPUWRAP_DEBUG_KEEP reg  [7:0] trpd_w2_micro;
`CPUWRAP_DEBUG_KEEP reg        trpd_w2_lw;

`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w3_log;
`CPUWRAP_DEBUG_KEEP reg [15:0] trpd_w3_dout;
`CPUWRAP_DEBUG_KEEP reg [31:0] trpd_w3_tmp;
`CPUWRAP_DEBUG_KEEP reg  [7:0] trpd_w3_micro;
`CPUWRAP_DEBUG_KEEP reg        trpd_w3_lw;

`CPUWRAP_DEBUG_KEEP reg        haltd_seen;
`CPUWRAP_DEBUG_KEEP reg        haltd_prev_cpu_halted;
`CPUWRAP_DEBUG_KEEP reg  [3:0] haltd_seq_count;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_pc;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_exe_pc;
`CPUWRAP_DEBUG_KEEP reg [15:0] haltd_opcode;
`CPUWRAP_DEBUG_KEEP reg  [1:0] haltd_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] haltd_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] haltd_next_micro_state;
`CPUWRAP_DEBUG_KEEP reg  [7:0] haltd_flags;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_a7;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_trap_vector;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_memaddr;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_log_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_phys_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_cpu_addr;
`CPUWRAP_DEBUG_KEEP reg [15:0] haltd_mmusr;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_saved_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_desc_addr;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_desc_data;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_tc;
`CPUWRAP_DEBUG_KEEP reg [31:0] haltd_crp_lo;
`CPUWRAP_DEBUG_KEEP reg  [4:0] haltd_wstate;
`CPUWRAP_DEBUG_KEEP reg        haltd_pmmu_fault;
`CPUWRAP_DEBUG_KEEP reg        haltd_pmmu_busy;
`CPUWRAP_DEBUG_KEEP reg        haltd_cpu_halted;
`CPUWRAP_DEBUG_KEEP reg        haltd_interrupt;
`CPUWRAP_DEBUG_KEEP reg        haltd_trapmake;
`CPUWRAP_DEBUG_KEEP reg        haltd_trap_addr_error;
`CPUWRAP_DEBUG_KEEP reg        haltd_trap_berr;
`CPUWRAP_DEBUG_KEEP reg        haltd_trap_mmu_berr;
`CPUWRAP_DEBUG_KEEP reg        haltd_make_berr;
`CPUWRAP_DEBUG_KEEP reg        haltd_berr_exception_active;
`CPUWRAP_DEBUG_KEEP reg        haltd_pmmu_fault_dispatched;
`CPUWRAP_DEBUG_KEEP reg        haltd_pmmu_fault_was_cleared;
`CPUWRAP_DEBUG_KEEP reg        haltd_pmmu_fault_rw;
`CPUWRAP_DEBUG_KEEP reg        haltd_pmmu_fault_is_insn;
`CPUWRAP_DEBUG_KEEP reg  [2:0] haltd_pmmu_fault_fc;
`CPUWRAP_DEBUG_KEEP reg        haltd_clkena_lw;
`CPUWRAP_DEBUG_KEEP reg        haltd_walker_berr;
`CPUWRAP_DEBUG_KEEP reg        haltd_walker_timeout;
`CPUWRAP_DEBUG_KEEP reg        haltd_cpu_clkena_in;
`CPUWRAP_DEBUG_KEEP reg        haltd_fault_latched;

`CPUWRAP_DEBUG_KEEP reg        stkd_seen;
`CPUWRAP_DEBUG_KEEP reg  [3:0] stkd_seq_count;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_entry_pc;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_entry_a7;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stkd_entry_flags;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_entry_usp;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_entry_msp;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_entry_isp;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stkd_entry_mode;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_tt0;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_tt1;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_crp_hi;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkw0_log, stkw1_log, stkw2_log, stkw3_log;
`CPUWRAP_DEBUG_KEEP reg [15:0] stkw0_dout, stkw1_dout, stkw2_dout, stkw3_dout;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stkw0_micro, stkw1_micro, stkw2_micro, stkw3_micro;
`CPUWRAP_DEBUG_KEEP reg        stkw0_lw, stkw1_lw, stkw2_lw, stkw3_lw;
`CPUWRAP_DEBUG_KEEP reg [31:0] stkd_w0_log, stkd_w1_log, stkd_w2_log, stkd_w3_log;
`CPUWRAP_DEBUG_KEEP reg [15:0] stkd_w0_dout, stkd_w1_dout, stkd_w2_dout, stkd_w3_dout;
`CPUWRAP_DEBUG_KEEP reg  [7:0] stkd_w0_micro, stkd_w1_micro, stkd_w2_micro, stkd_w3_micro;
`CPUWRAP_DEBUG_KEEP reg        stkd_w0_lw, stkd_w1_lw, stkd_w2_lw, stkd_w3_lw;

// T0 edge detector: captures state when FlagsSR(6) transitions 0->1
`CPUWRAP_DEBUG_KEEP reg        stp_t0_latched;         // sticky: T0 rising edge seen
`CPUWRAP_DEBUG_KEEP reg        stp_t0_cause_directSR;  // exec(directSR) was active (RTE)
`CPUWRAP_DEBUG_KEEP reg        stp_t0_cause_to_SR;     // exec(to_SR) was active (MOVE/ORI/EORI to SR)
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_t0_pc;              // PC when T0 was set
`CPUWRAP_DEBUG_KEEP reg [15:0] stp_t0_opcode;          // opcode when T0 was set
reg        prev_flagsSR_6;  // previous value of FlagsSR(6) for edge detection

always @(posedge clk) begin
	// Live state capture
	stp_cpu_pc              <= kernel_TG68_PC_p;
	stp_cpu_opcode          <= kernel_opcode_p;
	stp_cpu_state           <= kernel_state_p;
	stp_cpu_micro_state     <= kernel_micro_state_p[7:0];
	stp_cpu_next_micro_state <= kernel_next_ms_p[7:0];
	stp_cpu_memmask         <= kernel_memmask_p;
	stp_cpu_flagsSR         <= kernel_FlagsSR_p;
	stp_cpu_SVmode          <= kernel_SVmode_p;
	stp_cpu_memaddr         <= kernel_memaddr_reg_p;
	stp_cpu_exe_pc          <= kernel_exe_PC_p;
	stp_cpu_last_opc_read   <= kernel_last_opc_read_p;
	stp_cpu_brief           <= kernel_brief_p;
	stp_cpu_trap_vector     <= kernel_trap_vector_p;
	stp_cpu_trap_illegal    <= kernel_trap_illegal_p;
	stp_cpu_trap_priv       <= kernel_trap_priv_p;
	stp_cpu_trap_addr_error <= kernel_trap_addr_error_p;
	stp_cpu_trap_berr       <= kernel_trap_berr_p;
	stp_cpu_trap_mmu_berr   <= kernel_trap_mmu_berr_p;
	stp_cpu_make_berr       <= kernel_make_berr_p;
	stp_cpu_trap_1111       <= kernel_trap_1111_p;
	stp_cpu_trapmake        <= kernel_trapmake_p;
	stp_cpu_decodeOPC       <= kernel_decodeOPC_p;
	stp_cpu_setnextpass     <= kernel_setnextpass_p;

	// Hang detection: PC and micro_state unchanged for 2^16 cycles
	if (~reset) begin
		hang_detect_counter <= 0;
		hang_prev_pc <= 0;
		hang_prev_micro <= 0;
		stp_hang_latched <= 0;
		stp_hang_overflow <= 0;
	end else if (cpus_issp_source[0]) begin
		// JTAG clear
		stp_hang_latched <= 0;
		stp_hang_overflow <= 0;
		hang_detect_counter <= 0;
	end else begin
		if (kernel_TG68_PC_p != hang_prev_pc || kernel_micro_state_p[7:0] != hang_prev_micro) begin
			// State changed - reset counter
			hang_detect_counter <= 0;
			hang_prev_pc <= kernel_TG68_PC_p;
			hang_prev_micro <= kernel_micro_state_p[7:0];
		end else if (!stp_hang_latched) begin
			if (hang_detect_counter == 16'hFFFF) begin
				// Hung! Capture state
				stp_hang_latched         <= 1;
				stp_hang_overflow        <= 1;
				stp_hang_pc              <= kernel_TG68_PC_p;
				stp_hang_opcode          <= kernel_opcode_p;
				stp_hang_state           <= kernel_state_p;
				stp_hang_micro_state     <= kernel_micro_state_p[7:0];
				stp_hang_next_micro_state <= kernel_next_ms_p[7:0];
				stp_hang_memmask         <= kernel_memmask_p;
				stp_hang_flagsSR         <= kernel_FlagsSR_p;
				stp_hang_SVmode          <= kernel_SVmode_p;
				stp_hang_memaddr         <= kernel_memaddr_reg_p;
				stp_hang_exe_pc          <= kernel_exe_PC_p;
				stp_hang_trap_vector     <= kernel_trap_vector_p;
				stp_hang_trapmake        <= kernel_trapmake_p;
				stp_hang_pmmu_fault      <= pmmu_fault_p;
				stp_hang_cpu_halted      <= cpu_halted_p;
			end else begin
				hang_detect_counter <= hang_detect_counter + 1;
			end
		end
	end

	// T0 edge detector: capture when FlagsSR(6) transitions 0->1
	prev_flagsSR_6 <= kernel_FlagsSR_p[6];
	if (~reset) begin
		stp_t0_latched        <= 0;
		stp_t0_cause_directSR <= 0;
		stp_t0_cause_to_SR    <= 0;
		stp_t0_pc             <= 0;
		stp_t0_opcode         <= 0;
		prev_flagsSR_6        <= 0;
	end else if (cpus_issp_source[0]) begin
		stp_t0_latched        <= 0;
		stp_t0_cause_directSR <= 0;
		stp_t0_cause_to_SR    <= 0;
		stp_t0_pc             <= 0;
		stp_t0_opcode         <= 0;
	end else if (kernel_FlagsSR_p[6] && !prev_flagsSR_6 && !stp_t0_latched) begin
		// Rising edge of T0 - capture cause
		stp_t0_latched        <= 1;
		stp_t0_cause_directSR <= kernel_exec_directSR_p;
		stp_t0_cause_to_SR    <= kernel_exec_to_SR_p;
		stp_t0_pc             <= kernel_TG68_PC_p;
		stp_t0_opcode         <= kernel_opcode_p;
	end
end

// CPUS ISSP probe layout (458 bits):
// Live[222:0] + Hang[181:0] + T0[53:0]
// Live = PC[31:0] opcode[15:0] state[1:0] micro[7:0] next_micro[7:0]
//        memmask[5:0] flagsSR[7:0] SVmode memaddr[31:0] exe_pc[31:0]
//        last_opc_read[15:0] brief[15:0] trap_vector[31:0]
//        trap_illegal trap_priv trap_addr_error trap_berr trap_mmu_berr
//        make_berr trap_1111 trapmake decodeOPC setnextpass
//        setendOPC stop clkena_lw cpu_halted pmmu_fault interrupt
// Hang = hang_latched hang_overflow + captured fields
// T0 = t0_latched cause_directSR cause_to_SR t0_pc[31:0] t0_opcode[15:0] pad[2:0]
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (3),
	.instance_id             ("CPUS"),
	.probe_width             (458),
	.source_width            (1),
	.enable_metastability    ("YES")
) cpus_issp (
	.probe ({
		// Live state (223 bits)
		stp_cpu_pc,                    // [457:426] 32
		stp_cpu_opcode,                // [425:410] 16
		stp_cpu_state,                 // [409:408] 2
		stp_cpu_micro_state,           // [407:400] 8
		stp_cpu_next_micro_state,      // [399:392] 8
		stp_cpu_memmask,               // [391:386] 6
		stp_cpu_flagsSR,               // [385:378] 8
		stp_cpu_SVmode,                // [377]     1
		stp_cpu_memaddr,               // [376:345] 32
		stp_cpu_exe_pc,                // [344:313] 32
		stp_cpu_last_opc_read,         // [312:297] 16
		stp_cpu_brief,                 // [296:281] 16
		stp_cpu_trap_vector,           // [280:249] 32
		stp_cpu_trap_illegal,          // [248]
		stp_cpu_trap_priv,             // [247]
		stp_cpu_trap_addr_error,       // [246]
		stp_cpu_trap_berr,             // [245]
		stp_cpu_trap_mmu_berr,         // [244]
		stp_cpu_make_berr,             // [243]
		stp_cpu_trap_1111,             // [242]
		stp_cpu_trapmake,              // [241]
		stp_cpu_decodeOPC,             // [240]
		stp_cpu_setnextpass,           // [239]
		stp_setendOPC,                 // [238]
		stp_stop,                      // [237]
		kernel_clkena_lw_p,            // [236]
		cpu_halted_p,                  // [235]
		// Sticky hang capture (181 bits)
		stp_hang_latched,              // [234]
		stp_hang_overflow,             // [233]
		stp_hang_pc,                   // [232:201] 32
		stp_hang_opcode,               // [200:185] 16
		stp_hang_state,                // [184:183] 2
		stp_hang_micro_state,          // [182:175] 8
		stp_hang_next_micro_state,     // [174:167] 8
		stp_hang_memmask,              // [166:161] 6
		stp_hang_flagsSR,              // [160:153] 8
		stp_hang_SVmode,               // [152]
		stp_hang_memaddr,              // [151:120] 32
		stp_hang_exe_pc,               // [119:88]  32
		stp_hang_trap_vector,          // [87:56]   32
		stp_hang_trapmake,             // [55]
		stp_hang_pmmu_fault,           // [54]
		stp_hang_cpu_halted,           // [53]
		pmmu_fault_p,                  // [52]      live pmmu_fault
		kernel_interrupt_p,            // [51]      live interrupt
		// T0 edge capture (51 bits + 1 pad = 52)
		stp_t0_latched,                // [50]
		stp_t0_cause_directSR,         // [49]
		stp_t0_cause_to_SR,            // [48]
		stp_t0_pc,                     // [47:16]   32
		stp_t0_opcode,                 // [15:0]    16
	}),
	.source (cpus_issp_source)
	);
	`endif

// ============================================================================
// ISSP Instance 4: REGS - Register File Snapshot (D0-D7, A0-A7)
// ============================================================================
// 512 bits = 16 registers x 32 bits (max probe width)
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_reg_d0, stp_reg_d1, stp_reg_d2, stp_reg_d3;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_reg_d4, stp_reg_d5, stp_reg_d6, stp_reg_d7;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_reg_a0, stp_reg_a1, stp_reg_a2, stp_reg_a3;
`CPUWRAP_DEBUG_KEEP reg [31:0] stp_reg_a4, stp_reg_a5, stp_reg_a6, stp_reg_a7;

always @(posedge clk) begin
	stp_reg_d0 <= kernel_regfile_d0_p;
	stp_reg_d1 <= kernel_regfile_d1_p;
	stp_reg_d2 <= kernel_regfile_d2_p;
	stp_reg_d3 <= kernel_regfile_d3_p;
	stp_reg_d4 <= kernel_regfile_d4_p;
	stp_reg_d5 <= kernel_regfile_d5_p;
	stp_reg_d6 <= kernel_regfile_d6_p;
	stp_reg_d7 <= kernel_regfile_d7_p;
	stp_reg_a0 <= kernel_regfile_a0_p;
	stp_reg_a1 <= kernel_regfile_a1_p;
	stp_reg_a2 <= kernel_regfile_a2_p;
	stp_reg_a3 <= kernel_regfile_a3_p;
	stp_reg_a4 <= kernel_regfile_a4_p;
	stp_reg_a5 <= kernel_regfile_a5_p;
	stp_reg_a6 <= kernel_regfile_a6_p;
	stp_reg_a7 <= kernel_regfile_a7_p;
end

// Format-error debug probe. Keep it with the rest of the optional debug fabric;
// this is a 511-bit path into the CPU/MMU state and is not free in hardware.
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (5),
	.instance_id             ("FMTD"),
	.probe_width             (511),
	.source_width            (1),
	.enable_metastability    ("YES")
) fmtd_issp (
	.probe ({
		kernel_pmmu_pending_flags_p,   // [510:495]
		fmt_err_latched_p,            // [494]
		fmt_err_rte_word_p,           // [493:478]
		fmt_err_pc_p,                 // [477:446]
		fmt_err_addr_p,               // [445:414]
		fmt_err_sr_p,                 // [413:406]
		stp_cpu_pc,                   // [405:374]
		stp_cpu_opcode,               // [373:358]
		stp_cpu_state,                // [357:356]
		stp_cpu_micro_state,          // [355:348]
		stp_cpu_next_micro_state,     // [347:340]
		stp_cpu_memaddr,              // [339:308]
		stp_cpu_flagsSR,              // [307:300]
		pmmu_fault_p,                 // [299]
		cpu_halted_p,                 // [298]
		kernel_interrupt_p,           // [297]
		kernel_clkena_lw_p,           // [296]
		kernel_trapmake_p,            // [295]
		stp_reg_a7,                   // [294:263]
		stp_hang_latched,             // [262]
		stp_hang_overflow,            // [261]
		stp_hang_pc,                  // [260:229]
		stp_hang_opcode,              // [228:213]
		stp_hang_state,               // [212:211]
		stp_hang_micro_state,         // [210:203]
		stp_hang_next_micro_state,    // [202:195]
		stp_hang_memaddr,             // [194:163]
		stp_hang_flagsSR,             // [162:155]
		stp_hang_pmmu_fault,          // [154]
		stp_hang_cpu_halted,          // [153]
		stp_pmmu_tc,                  // [152:121]
		stp_pmmu_crp_lo,              // [120:89]
		stp_pmmu_wstate,              // [88:84]
		stp_pmmu_fault,               // [83]
		stp_pmmu_busy,                // [82]
		stp_fault_latched,            // [81]
		stp_walker_timeout_latched,   // [80]
		stp_fault_mmusr,              // [79:64]
		stp_fault_saved_addr,         // [63:32]
		stp_fault_addr                // [31:0]
	}),
	.source (fmtd_issp_source)
);
`endif

// 511 bits max: 15 regs x 32 = 480 + A7[31:1] = 31 = 511
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (4),
	.instance_id             ("REGS"),
	.probe_width             (511),
	.source_width            (0),
	.enable_metastability    ("YES")
) regs_issp (
	.probe ({
		stp_reg_d0, stp_reg_d1, stp_reg_d2, stp_reg_d3,
		stp_reg_d4, stp_reg_d5, stp_reg_d6, stp_reg_d7,
		stp_reg_a0, stp_reg_a1, stp_reg_a2, stp_reg_a3,
		stp_reg_a4, stp_reg_a5, stp_reg_a6, stp_reg_a7[31:1]
	})
);
`endif

// PMMU walker address mux signals (for bus arbitration)
// NOTE: Walker supports full 32-bit addressing:
//   - Legacy chip/Gary bus RAM (chip + slow): uses walker_chip_addr[23:1] -> chip_addr bus
//   - Z3/Z2 Fast RAM: uses walker_addr_word[31:1] -> walker_ramaddr -> ramsel path
// Page tables in Z3 RAM above 16MB are fully supported via the ramaddr path.
reg         walker_active;
reg   [3:0] walker_state;  // BUG #124 FIX: Walker state visible for bus mux (4-bit for write states)
reg  [31:0] walker_wdata_latch;  // MC68030 U/M bit: Latch write data from PMMU
reg         walker_timeout_error; // BUG #138: Walker timeout error flag
reg         walker_write_ready_armed; // Require a fresh ready pulse for descriptor writes
reg         walker_read_ready_armed;  // Require a fresh ready pulse for descriptor reads
wire [23:1] walker_chip_addr;  // For legacy chip/Gary bus RAM
wire        walker_reading;  // BUG #124 FIX: Walker actively reading memory
wire        walker_writing;  // MC68030 U/M bit: Walker actively writing memory
wire        walker_write_low_phase;  // MC68030 U/M bit: Writing low word
wire        walker_mem_ready;
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
// Qualify CPU completion on the bus that is currently selected.
// This blocks stale ready pulses (e.g. delayed SDRAM ramready from a stale
// physical address) from completing an unrelated chip/fast cycle.
wire        cpu_ready_qualified = (ramsel & ramready) |
                                  (fastchip_selack & fastchip_ready) |
                                  (~ramsel & ~fastchip_selack & chipready);
wire        cpu_clkena_in = (~cpu_req | cpu_ready_qualified | (USE_68030_CACHE & cache_hit) |
                             pmmu_fault_p | walker_timeout_error | ~reset) &
                            (~pmmu_walker_req_p | ~reset | walker_timeout_error) &
                            (~pmmu_busy_p | pmmu_fault_p | walker_timeout_error | ~reset);

wire rted_rte_opcode = (kernel_opcode_p == 16'h4E73);
wire rted_start = cpu_clkena_in && rted_rte_opcode &&
                  (kernel_next_ms_p[7:0] == MS_RTE1) &&
                  (kernel_micro_state_p[7:0] != MS_RTE6);
wire rted_read_complete = rted_active && cpu_clkena_in &&
                          (kernel_state_p == 2'b10);

always @(posedge clk) begin
	if (~reset || rted_issp_source[0] || fmtd_issp_source[0]) begin
		rted_seen        <= 0;
		rted_active      <= 0;
		rted_done        <= 0;
		rted_read_count  <= 0;
		rted_seq_count   <= 0;
		rted_entry_pc    <= 0;
		rted_entry_a7    <= 0;
		rted_entry_flags <= 0;
		rted_after_pc    <= 0;
		rted_r0_log      <= 0;
		rted_r0_phys     <= 0;
		rted_r0_din      <= 0;
		rted_r0_micro    <= 0;
		rted_r0_state    <= 0;
		rted_r0_lw       <= 0;
		rted_r1_log      <= 0;
		rted_r1_phys     <= 0;
		rted_r1_din      <= 0;
		rted_r1_micro    <= 0;
		rted_r1_state    <= 0;
		rted_r1_lw       <= 0;
		rted_r2_log      <= 0;
		rted_r2_phys     <= 0;
		rted_r2_din      <= 0;
		rted_r2_micro    <= 0;
		rted_r2_state    <= 0;
		rted_r2_lw       <= 0;
		rted_r3_log      <= 0;
		rted_r3_phys     <= 0;
		rted_r3_din      <= 0;
		rted_r3_micro    <= 0;
		rted_r3_state    <= 0;
		rted_r3_lw       <= 0;
	end else if (!fmt_err_latched_p) begin
		if (rted_start) begin
			rted_seen        <= 1;
			rted_active      <= 1;
			rted_done        <= 0;
			rted_read_count  <= 0;
			rted_seq_count   <= rted_seq_count + 1'b1;
			rted_entry_pc    <= kernel_TG68_PC_p;
			rted_entry_a7    <= kernel_regfile_a7_p;
			rted_entry_flags <= kernel_FlagsSR_p;
			rted_after_pc    <= 0;
			rted_r0_log      <= 0;
			rted_r0_phys     <= 0;
			rted_r0_din      <= 0;
			rted_r0_micro    <= 0;
			rted_r0_state    <= 0;
			rted_r0_lw       <= 0;
			rted_r1_log      <= 0;
			rted_r1_phys     <= 0;
			rted_r1_din      <= 0;
			rted_r1_micro    <= 0;
			rted_r1_state    <= 0;
			rted_r1_lw       <= 0;
			rted_r2_log      <= 0;
			rted_r2_phys     <= 0;
			rted_r2_din      <= 0;
			rted_r2_micro    <= 0;
			rted_r2_state    <= 0;
			rted_r2_lw       <= 0;
			rted_r3_log      <= 0;
			rted_r3_phys     <= 0;
			rted_r3_din      <= 0;
			rted_r3_micro    <= 0;
			rted_r3_state    <= 0;
			rted_r3_lw       <= 0;
		end
		if (rted_seen && (kernel_micro_state_p[7:0] == MS_RTE4)) begin
			rted_after_pc <= kernel_TG68_PC_p;
			rted_done     <= 1;
		end
		if (rted_read_complete) begin
			case (rted_read_count)
				3'd0: begin
					rted_r0_log   <= pmmu_addr_log_p;
					rted_r0_phys  <= pmmu_addr_phys_p;
					rted_r0_din   <= cpu_din;
					rted_r0_micro <= kernel_micro_state_p[7:0];
					rted_r0_state <= kernel_state_p;
					rted_r0_lw    <= kernel_clkena_lw_p;
				end
				3'd1: begin
					rted_r1_log   <= pmmu_addr_log_p;
					rted_r1_phys  <= pmmu_addr_phys_p;
					rted_r1_din   <= cpu_din;
					rted_r1_micro <= kernel_micro_state_p[7:0];
					rted_r1_state <= kernel_state_p;
					rted_r1_lw    <= kernel_clkena_lw_p;
				end
				3'd2: begin
					rted_r2_log   <= pmmu_addr_log_p;
					rted_r2_phys  <= pmmu_addr_phys_p;
					rted_r2_din   <= cpu_din;
					rted_r2_micro <= kernel_micro_state_p[7:0];
					rted_r2_state <= kernel_state_p;
					rted_r2_lw    <= kernel_clkena_lw_p;
				end
				3'd3: begin
					rted_r3_log   <= pmmu_addr_log_p;
					rted_r3_phys  <= pmmu_addr_phys_p;
					rted_r3_din   <= cpu_din;
					rted_r3_micro <= kernel_micro_state_p[7:0];
					rted_r3_state <= kernel_state_p;
					rted_r3_lw    <= kernel_clkena_lw_p;
					rted_active   <= 0;
					rted_done     <= 1;
				end
				default: ;
			endcase
			if (rted_read_count != 3'd4) begin
				rted_read_count <= rted_read_count + 1'b1;
			end
		end
	end
end

wire trpd_write_complete = cpu_clkena_in && (kernel_state_p == 2'b11);
wire trpd_fline_format_write = trpd_write_complete &&
                               (kernel_micro_state_p[7:0] == MS_TRAP0) &&
                               (kernel_data_write_tmp_p[15:0] == 16'h002C);

always @(posedge clk) begin
	if (~reset || stkd_issp_source[0] || fmtd_issp_source[0]) begin
		stkd_seen        <= 0;
		stkd_seq_count   <= 0;
		stkd_entry_pc    <= 0;
		stkd_entry_a7    <= 0;
		stkd_entry_flags <= 0;
		stkd_entry_usp   <= 0;
		stkd_entry_msp   <= 0;
		stkd_entry_isp   <= 0;
		stkd_entry_mode  <= 0;
		stkd_tt0         <= 0;
		stkd_tt1         <= 0;
		stkd_crp_hi      <= 0;
		stkw0_log        <= 0;
		stkw1_log        <= 0;
		stkw2_log        <= 0;
		stkw3_log        <= 0;
		stkw0_dout       <= 0;
		stkw1_dout       <= 0;
		stkw2_dout       <= 0;
		stkw3_dout       <= 0;
		stkw0_micro      <= 0;
		stkw1_micro      <= 0;
		stkw2_micro      <= 0;
		stkw3_micro      <= 0;
		stkw0_lw         <= 0;
		stkw1_lw         <= 0;
		stkw2_lw         <= 0;
		stkw3_lw         <= 0;
		stkd_w0_log      <= 0;
		stkd_w1_log      <= 0;
		stkd_w2_log      <= 0;
		stkd_w3_log      <= 0;
		stkd_w0_dout     <= 0;
		stkd_w1_dout     <= 0;
		stkd_w2_dout     <= 0;
		stkd_w3_dout     <= 0;
		stkd_w0_micro    <= 0;
		stkd_w1_micro    <= 0;
		stkd_w2_micro    <= 0;
		stkd_w3_micro    <= 0;
		stkd_w0_lw       <= 0;
		stkd_w1_lw       <= 0;
		stkd_w2_lw       <= 0;
		stkd_w3_lw       <= 0;
	end else begin
		if (trpd_write_complete) begin
			stkw3_log   <= stkw2_log;
			stkw3_dout  <= stkw2_dout;
			stkw3_micro <= stkw2_micro;
			stkw3_lw    <= stkw2_lw;
			stkw2_log   <= stkw1_log;
			stkw2_dout  <= stkw1_dout;
			stkw2_micro <= stkw1_micro;
			stkw2_lw    <= stkw1_lw;
			stkw1_log   <= stkw0_log;
			stkw1_dout  <= stkw0_dout;
			stkw1_micro <= stkw0_micro;
			stkw1_lw    <= stkw0_lw;
			stkw0_log   <= pmmu_addr_log_p;
			stkw0_dout  <= cpu_dout_p;
			stkw0_micro <= kernel_micro_state_p[7:0];
			stkw0_lw    <= kernel_clkena_lw_p;
		end
		if (rted_start) begin
			stkd_seen        <= 1;
			stkd_seq_count   <= stkd_seq_count + 1'b1;
			stkd_entry_pc    <= kernel_TG68_PC_p;
			stkd_entry_a7    <= kernel_regfile_a7_p;
			stkd_entry_flags <= kernel_FlagsSR_p;
			stkd_entry_usp   <= kernel_usp_p;
			stkd_entry_msp   <= kernel_msp_p;
			stkd_entry_isp   <= kernel_isp_p;
			stkd_entry_mode  <= {kernel_SVmode_p, kernel_FlagsSR_p[5], kernel_a7_is_msp_p,
			                     kernel_interrupt_mode_p, kernel_rte_saved_mbit_p,
			                     kernel_exec_directSR_p, kernel_exec_to_SR_p, pmmu_fault_p};
			stkd_tt0         <= stp_pmmu_tt0_w;
			stkd_tt1         <= stp_pmmu_tt1_w;
			stkd_crp_hi      <= stp_pmmu_crp_hi_w;
			stkd_w0_log      <= stkw0_log;
			stkd_w0_dout     <= stkw0_dout;
			stkd_w0_micro    <= stkw0_micro;
			stkd_w0_lw       <= stkw0_lw;
			stkd_w1_log      <= stkw1_log;
			stkd_w1_dout     <= stkw1_dout;
			stkd_w1_micro    <= stkw1_micro;
			stkd_w1_lw       <= stkw1_lw;
			stkd_w2_log      <= stkw2_log;
			stkd_w2_dout     <= stkw2_dout;
			stkd_w2_micro    <= stkw2_micro;
			stkd_w2_lw       <= stkw2_lw;
			stkd_w3_log      <= stkw3_log;
			stkd_w3_dout     <= stkw3_dout;
			stkd_w3_micro    <= stkw3_micro;
			stkd_w3_lw       <= stkw3_lw;
		end
	end
end

always @(posedge clk) begin
	if (~reset || trpd_issp_source[0] || fmtd_issp_source[0]) begin
		trpd_seen         <= 0;
		trpd_active       <= 0;
		trpd_done         <= 0;
		trpd_write_count  <= 0;
		trpd_seq_count    <= 0;
		trpd_start_pc     <= 0;
		trpd_start_exe_pc <= 0;
		trpd_start_opcode <= 0;
		trpd_start_flags  <= 0;
		trpd_start_vector <= 0;
		trpd_start_a7     <= 0;
		trpd_w0_log       <= 0;
		trpd_w0_dout      <= 0;
		trpd_w0_tmp       <= 0;
		trpd_w0_micro     <= 0;
		trpd_w0_lw        <= 0;
		trpd_w1_log       <= 0;
		trpd_w1_dout      <= 0;
		trpd_w1_tmp       <= 0;
		trpd_w1_micro     <= 0;
		trpd_w1_lw        <= 0;
		trpd_w2_log       <= 0;
		trpd_w2_dout      <= 0;
		trpd_w2_tmp       <= 0;
		trpd_w2_micro     <= 0;
		trpd_w2_lw        <= 0;
		trpd_w3_log       <= 0;
		trpd_w3_dout      <= 0;
		trpd_w3_tmp       <= 0;
		trpd_w3_micro     <= 0;
		trpd_w3_lw        <= 0;
	end else if (trpd_fline_format_write && !trpd_active && !trpd_done) begin
		trpd_seen         <= 1;
		trpd_active       <= 1;
		trpd_done         <= 0;
		trpd_write_count  <= 1;
		trpd_seq_count    <= trpd_seq_count + 1'b1;
		trpd_start_pc     <= kernel_TG68_PC_p;
		trpd_start_exe_pc <= kernel_exe_PC_p;
		trpd_start_opcode <= kernel_opcode_p;
		trpd_start_flags  <= kernel_FlagsSR_p;
		trpd_start_vector <= kernel_trap_vector_p[15:0];
		trpd_start_a7     <= kernel_regfile_a7_p;
		trpd_w0_log       <= pmmu_addr_log_p;
		trpd_w0_dout      <= cpu_dout_p;
		trpd_w0_tmp       <= kernel_data_write_tmp_p;
		trpd_w0_micro     <= kernel_micro_state_p[7:0];
		trpd_w0_lw        <= kernel_clkena_lw_p;
	end else if (trpd_active && trpd_write_complete) begin
		case (trpd_write_count)
			3'd1: begin
				trpd_w1_log   <= pmmu_addr_log_p;
				trpd_w1_dout  <= cpu_dout_p;
				trpd_w1_tmp   <= kernel_data_write_tmp_p;
				trpd_w1_micro <= kernel_micro_state_p[7:0];
				trpd_w1_lw    <= kernel_clkena_lw_p;
			end
			3'd2: begin
				trpd_w2_log   <= pmmu_addr_log_p;
				trpd_w2_dout  <= cpu_dout_p;
				trpd_w2_tmp   <= kernel_data_write_tmp_p;
				trpd_w2_micro <= kernel_micro_state_p[7:0];
				trpd_w2_lw    <= kernel_clkena_lw_p;
			end
			3'd3: begin
				trpd_w3_log   <= pmmu_addr_log_p;
				trpd_w3_dout  <= cpu_dout_p;
				trpd_w3_tmp   <= kernel_data_write_tmp_p;
				trpd_w3_micro <= kernel_micro_state_p[7:0];
				trpd_w3_lw    <= kernel_clkena_lw_p;
				trpd_active   <= 0;
				trpd_done     <= 1;
			end
			default: ;
		endcase
		if (trpd_write_count != 3'd4) begin
			trpd_write_count <= trpd_write_count + 1'b1;
		end
	end
end

always @(posedge clk) begin
	if (~reset) begin
		haltd_seen                   <= 0;
		haltd_prev_cpu_halted        <= 0;
		haltd_seq_count              <= 0;
		haltd_pc                     <= 0;
		haltd_exe_pc                 <= 0;
		haltd_opcode                 <= 0;
		haltd_state                  <= 0;
		haltd_micro_state            <= 0;
		haltd_next_micro_state       <= 0;
		haltd_flags                  <= 0;
		haltd_a7                     <= 0;
		haltd_trap_vector            <= 0;
		haltd_memaddr                <= 0;
		haltd_log_addr               <= 0;
		haltd_phys_addr              <= 0;
		haltd_cpu_addr               <= 0;
		haltd_mmusr                  <= 0;
		haltd_saved_addr             <= 0;
		haltd_desc_addr              <= 0;
		haltd_desc_data              <= 0;
		haltd_tc                     <= 0;
		haltd_crp_lo                 <= 0;
		haltd_wstate                 <= 0;
		haltd_pmmu_fault             <= 0;
		haltd_pmmu_busy              <= 0;
		haltd_cpu_halted             <= 0;
		haltd_interrupt              <= 0;
		haltd_trapmake               <= 0;
		haltd_trap_addr_error        <= 0;
		haltd_trap_berr              <= 0;
		haltd_trap_mmu_berr          <= 0;
		haltd_make_berr              <= 0;
		haltd_berr_exception_active  <= 0;
		haltd_pmmu_fault_dispatched  <= 0;
		haltd_pmmu_fault_was_cleared <= 0;
		haltd_pmmu_fault_rw          <= 0;
		haltd_pmmu_fault_is_insn     <= 0;
		haltd_pmmu_fault_fc          <= 0;
		haltd_clkena_lw              <= 0;
		haltd_walker_berr            <= 0;
		haltd_walker_timeout         <= 0;
		haltd_cpu_clkena_in          <= 0;
		haltd_fault_latched          <= 0;
	end else if (haltd_issp_source[0] || fmtd_issp_source[0]) begin
		haltd_seen            <= 0;
		haltd_prev_cpu_halted <= cpu_halted_p;
	end else begin
		if (cpu_halted_p && !haltd_prev_cpu_halted && !haltd_seen) begin
			haltd_seen                   <= 1;
			haltd_seq_count              <= haltd_seq_count + 1'b1;
			haltd_pc                     <= kernel_TG68_PC_p;
			haltd_exe_pc                 <= kernel_exe_PC_p;
			haltd_opcode                 <= kernel_opcode_p;
			haltd_state                  <= kernel_state_p;
			haltd_micro_state            <= kernel_micro_state_p[7:0];
			haltd_next_micro_state       <= kernel_next_ms_p[7:0];
			haltd_flags                  <= kernel_FlagsSR_p;
			haltd_a7                     <= kernel_regfile_a7_p;
			haltd_trap_vector            <= kernel_trap_vector_p;
			haltd_memaddr                <= kernel_memaddr_reg_p;
			haltd_log_addr               <= pmmu_addr_log_p;
			haltd_phys_addr              <= pmmu_addr_phys_p;
			haltd_cpu_addr               <= cpu_addr_p;
			haltd_mmusr                  <= stp_fault_status_w;
			haltd_saved_addr             <= stp_saved_addr_w;
			haltd_desc_addr              <= stp_walk_desc_addr_w;
			haltd_desc_data              <= stp_walk_desc_data_w;
			haltd_tc                     <= stp_pmmu_tc_w;
			haltd_crp_lo                 <= stp_pmmu_crp_lo_w;
			haltd_wstate                 <= stp_pmmu_wstate_w;
			haltd_pmmu_fault             <= pmmu_fault_p;
			haltd_pmmu_busy              <= pmmu_busy_p;
			haltd_cpu_halted             <= cpu_halted_p;
			haltd_interrupt              <= kernel_interrupt_p;
			haltd_trapmake               <= kernel_trapmake_p;
			haltd_trap_addr_error        <= kernel_trap_addr_error_p;
			haltd_trap_berr              <= kernel_trap_berr_p;
			haltd_trap_mmu_berr          <= kernel_trap_mmu_berr_p;
			haltd_make_berr              <= kernel_make_berr_p;
			haltd_berr_exception_active  <= kernel_berr_exception_active_p;
			haltd_pmmu_fault_dispatched  <= kernel_pmmu_fault_dispatched_p;
			haltd_pmmu_fault_was_cleared <= kernel_pmmu_fault_was_cleared_p;
			haltd_pmmu_fault_rw          <= kernel_pmmu_fault_rw_p;
			haltd_pmmu_fault_is_insn     <= kernel_pmmu_fault_is_insn_p;
			haltd_pmmu_fault_fc          <= kernel_pmmu_fault_fc_p;
			haltd_clkena_lw              <= kernel_clkena_lw_p;
			haltd_walker_berr            <= pmmu_walker_berr_p;
			haltd_walker_timeout         <= walker_timeout_error;
			haltd_cpu_clkena_in          <= cpu_clkena_in;
			haltd_fault_latched          <= stp_fault_latched;
		end
		haltd_prev_cpu_halted <= cpu_halted_p;
	end
end

// RTE return-frame trace probe. Captures the first four RTE data-read bus
// completions: SR, PC high, PC low, and format/vector word for short frames.
// freezes once the core's sticky format-error latch is set.
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (6),
	.instance_id             ("RTED"),
	.probe_width             (483),
	.source_width            (1),
	.enable_metastability    ("YES")
) rted_issp (
	.probe ({
		rted_seen,              // [482]
		rted_active,            // [481]
		rted_done,              // [480]
		fmt_err_latched_p,      // [479]
		pmmu_fault_p,           // [478]
		pmmu_busy_p,            // [477]
		cpu_halted_p,           // [476]
		kernel_trapmake_p,      // [475]
		rted_read_count,        // [474:472]
		rted_seq_count,         // [471:468]
		rted_entry_pc,          // [467:436]
		rted_entry_a7,          // [435:404]
		rted_entry_flags,       // [403:396]
		rted_after_pc,          // [395:364]
		rted_r0_log,            // [363:332]
		rted_r0_phys,           // [331:300]
		rted_r0_din,            // [299:284]
		rted_r0_micro,          // [283:276]
		rted_r0_state,          // [275:274]
		rted_r0_lw,             // [273]
		rted_r1_log,            // [272:241]
		rted_r1_phys,           // [240:209]
		rted_r1_din,            // [208:193]
		rted_r1_micro,          // [192:185]
		rted_r1_state,          // [184:183]
		rted_r1_lw,             // [182]
		rted_r2_log,            // [181:150]
		rted_r2_phys,           // [149:118]
		rted_r2_din,            // [117:102]
		rted_r2_micro,          // [101:94]
		rted_r2_state,          // [93:92]
		rted_r2_lw,             // [91]
		rted_r3_log,            // [90:59]
		rted_r3_phys,           // [58:27]
		rted_r3_din,            // [26:11]
		rted_r3_micro,          // [10:3]
		rted_r3_state,          // [2:1]
		rted_r3_lw              // [0]
	}),
	.source (rted_issp_source)
);
`endif

// Trap-frame write trace probe. It arms on the short F-line format/vector word
// ($002C) and captures the four bus writes that build the frame:
// format/vector, PC high, PC low, SR.
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (7),
	.instance_id             ("TRPD"),
	.probe_width             (505),
	.source_width            (1),
	.enable_metastability    ("YES")
) trpd_issp (
	.probe ({
		trpd_seen,          // [504]
		trpd_active,        // [503]
		trpd_done,          // [502]
		trpd_write_count,   // [501:499]
		trpd_seq_count,     // [498:495]
		trpd_start_pc,      // [494:463]
		trpd_start_exe_pc,  // [462:431]
		trpd_start_opcode,  // [430:415]
		trpd_start_flags,   // [414:407]
		trpd_start_vector,  // [406:391]
		trpd_start_a7,      // [390:359]
		trpd_w0_log,        // [358:327]
		trpd_w0_dout,       // [326:311]
		trpd_w0_tmp,        // [310:279]
		trpd_w0_micro,      // [278:271]
		trpd_w0_lw,         // [270]
		trpd_w1_log,        // [269:238]
		trpd_w1_dout,       // [237:222]
		trpd_w1_tmp,        // [221:190]
		trpd_w1_micro,      // [189:182]
		trpd_w1_lw,         // [181]
		trpd_w2_log,        // [180:149]
		trpd_w2_dout,       // [148:133]
		trpd_w2_tmp,        // [132:101]
		trpd_w2_micro,      // [100:93]
		trpd_w2_lw,         // [92]
		trpd_w3_log,        // [91:60]
		trpd_w3_dout,       // [59:44]
		trpd_w3_tmp,        // [43:12]
		trpd_w3_micro,      // [11:4]
		trpd_w3_lw,         // [3]
		3'b000              // [2:0]
	}),
	.source (trpd_issp_source)
);
`endif

// Halt-edge context probe. This latches the exact cycle where the core enters
// the MC68030 double-bus-fault halted state, including PMMU and exception state.
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (8),
	.instance_id             ("HALT"),
	.probe_width             (506),
	.source_width            (1),
	.enable_metastability    ("YES")
) halt_issp (
	.probe ({
		haltd_seen,                   // [505]
		haltd_seq_count,              // [504:501]
		haltd_pc,                     // [500:469]
		haltd_exe_pc,                 // [468:437]
		haltd_opcode,                 // [436:421]
		haltd_state,                  // [420:419]
		haltd_micro_state,            // [418:411]
		haltd_next_micro_state,       // [410:403]
		haltd_flags,                  // [402:395]
		haltd_a7,                     // [394:363]
		haltd_trap_vector,            // [362:331]
		haltd_memaddr,                // [330:299]
		haltd_log_addr,               // [298:267]
		haltd_phys_addr,              // [266:235]
		haltd_cpu_addr,               // [234:203]
		haltd_mmusr,                  // [202:187]
		haltd_saved_addr,             // [186:155]
		haltd_desc_addr,              // [154:123]
		haltd_desc_data,              // [122:91]
		haltd_tc,                     // [90:59]
		haltd_crp_lo,                 // [58:27]
		haltd_wstate,                 // [26:22]
		haltd_pmmu_fault,             // [21]
		haltd_pmmu_busy,              // [20]
		haltd_cpu_halted,             // [19]
		haltd_interrupt,              // [18]
		haltd_trapmake,               // [17]
		haltd_trap_addr_error,        // [16]
		haltd_trap_berr,              // [15]
		haltd_trap_mmu_berr,          // [14]
		haltd_make_berr,              // [13]
		haltd_berr_exception_active,  // [12]
		haltd_pmmu_fault_dispatched,  // [11]
		haltd_pmmu_fault_was_cleared, // [10]
		haltd_pmmu_fault_rw,          // [9]
		haltd_pmmu_fault_is_insn,     // [8]
		haltd_pmmu_fault_fc,          // [7:5]
		haltd_clkena_lw,              // [4]
		haltd_walker_berr,            // [3]
		haltd_walker_timeout,         // [2]
		haltd_cpu_clkena_in,          // [1]
		haltd_fault_latched           // [0]
	}),
	.source (haltd_issp_source)
);
`endif

// RTE stack context probe. Captures the four most recent CPU write cycles before
// each RTE begins, plus stack-shadow and MMU transparent/root context.
`ifdef ENABLE_CPUWRAP_DEBUG_ISSP
altsource_probe #(
	.sld_auto_instance_index ("YES"),
	.sld_instance_index      (9),
	.instance_id             ("STKD"),
	.probe_width             (505),
	.source_width            (1),
	.enable_metastability    ("YES")
) stkd_issp (
	.probe ({
		stkd_seen,         // [504]
		stkd_seq_count,    // [503:500]
		stkd_entry_pc,     // [499:468]
		stkd_entry_a7,     // [467:436]
		stkd_entry_flags,  // [435:428]
		stkd_entry_usp,    // [427:396]
		stkd_entry_msp,    // [395:364]
		stkd_entry_isp,    // [363:332]
		stkd_entry_mode,   // [331:324]
		stkd_tt0,          // [323:292]
		stkd_tt1,          // [291:260]
		stkd_crp_hi,       // [259:228]
		stkd_w3_log,       // [227:196] oldest captured write
		stkd_w3_dout,      // [195:180]
		stkd_w3_micro,     // [179:172]
		stkd_w3_lw,        // [171]
		stkd_w2_log,       // [170:139]
		stkd_w2_dout,      // [138:123]
		stkd_w2_micro,     // [122:115]
		stkd_w2_lw,        // [114]
		stkd_w1_log,       // [113:82]
		stkd_w1_dout,      // [81:66]
		stkd_w1_micro,     // [65:58]
		stkd_w1_lw,        // [57]
		stkd_w0_log,       // [56:25] newest captured write
		stkd_w0_dout,      // [24:9]
		stkd_w0_micro,     // [8:1]
		stkd_w0_lw         // [0]
	}),
	.source (stkd_issp_source)
);
`endif

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
  .clkena_in(cpu_clkena_in),
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
  .debug_cpu_halted(cpu_halted_p),
  .debug_stop(kernel_stop_p),
  .debug_state(kernel_state_p),
  .debug_clkena_lw(kernel_clkena_lw_p),
  .debug_interrupt(kernel_interrupt_p),
  .debug_setendOPC(kernel_setendOPC_p),
  .debug_IPL_nr(kernel_IPL_nr_p),
  // MC68030 bus fault: PMMU fault signal for bus access suppression
  .debug_pmmu_fault(pmmu_fault_p),
  .debug_pmmu_reg_we(kernel_pmmu_reg_we_p),
  .debug_pmmu_reg_re(),
  .debug_pmmu_reg_sel(kernel_pmmu_reg_sel_p),
  .debug_pmmu_reg_wdat(kernel_pmmu_reg_wdat_p),
  .debug_pmmu_reg_part(kernel_pmmu_reg_part_p),
  .debug_pmmu_reg_rdat(),
  // Format Error debug latch
  .debug_trap_format_error(fmt_err_latched_p),
  .debug_format_error_rte_word(fmt_err_rte_word_p),
  .debug_format_error_sr(fmt_err_sr_p),
  .debug_format_error_pc(fmt_err_pc_p),
  .debug_format_error_addr(fmt_err_addr_p),
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
  .debug_pmmu_pending_flags(kernel_pmmu_pending_flags_p),
  .debug_pmmu_fault_status(stp_fault_status_w),
  .debug_pmmu_saved_addr(stp_saved_addr_w),
  .debug_pmmu_srp_hi(stp_pmmu_srp_hi_w),
  .debug_pmmu_srp_lo(stp_pmmu_srp_lo_w),
  .debug_pmmu_walk_desc_addr(stp_walk_desc_addr_w),
  .debug_pmmu_walk_desc_data(stp_walk_desc_data_w),
  .debug_pmmu_ptr1_desc_addr(stp_ptr1_desc_addr_w),
  .debug_pmmu_ptr1_desc_data(stp_ptr1_desc_data_w),
  .debug_pmmu_ptr2_desc_addr(stp_ptr2_desc_addr_w),
  .debug_pmmu_ptr2_desc_data(stp_ptr2_desc_data_w),
  .debug_pmmu_ptr3_desc_addr(stp_ptr3_desc_addr_w),
  .debug_pmmu_ptr3_desc_data(stp_ptr3_desc_data_w),
  .debug_pmmu_saved_fc(stp_saved_fc_w),
  // CHK/Group2 exception frame ISSP probes
  .debug_make_trace(kernel_make_trace_p),
  .debug_trace_pending_grp2(kernel_trace_pending_grp2_p),
  .debug_useStackframe2(kernel_useStackframe2_p),
  .debug_exec_trap_chk(kernel_exec_trap_chk_p),
  .debug_set_trap_chk(kernel_set_trap_chk_p),
  .debug_data_write_tmp(kernel_data_write_tmp_p),
  .debug_FlagsSR(kernel_FlagsSR_p),
  .debug_USP(kernel_usp_p),
  .debug_MSP(kernel_msp_p),
  .debug_ISP(kernel_isp_p),
  .debug_a7_is_msp(kernel_a7_is_msp_p),
  .debug_interrupt_mode(kernel_interrupt_mode_p),
  .debug_rte_saved_mbit(kernel_rte_saved_mbit_p),
  .debug_trap_vector(kernel_trap_vector_p),
  .debug_micro_state(kernel_micro_state_p),
  .debug_next_micro_state(kernel_next_ms_p),
  .debug_trapmake(kernel_trapmake_p),
  // CPU Core debug (CPUS ISSP)
  .debug_TG68_PC(kernel_TG68_PC_p),
  .debug_opcode(kernel_opcode_p),
  .debug_last_opc_read(kernel_last_opc_read_p),
  .debug_data_read(kernel_data_read_p),
  .debug_brief(kernel_brief_p),
  .debug_memaddr_reg(kernel_memaddr_reg_p),
  .debug_memmask(kernel_memmask_p),
  .debug_decodeOPC(kernel_decodeOPC_p),
  .debug_setnextpass(kernel_setnextpass_p),
  .debug_SVmode(kernel_SVmode_p),
  .debug_exe_PC(kernel_exe_PC_p),
  .debug_trap_illegal(kernel_trap_illegal_p),
  .debug_trap_priv(kernel_trap_priv_p),
  .debug_trap_addr_error(kernel_trap_addr_error_p),
  .debug_trap_berr(kernel_trap_berr_p),
  .debug_trap_mmu_berr(kernel_trap_mmu_berr_p),
  .debug_make_berr(kernel_make_berr_p),
  .debug_berr_exception_active(kernel_berr_exception_active_p),
  .debug_pmmu_fault_dispatched(kernel_pmmu_fault_dispatched_p),
  .debug_pmmu_fault_was_cleared(kernel_pmmu_fault_was_cleared_p),
  .debug_pmmu_fault_rw(kernel_pmmu_fault_rw_p),
  .debug_pmmu_fault_is_insn(kernel_pmmu_fault_is_insn_p),
  .debug_pmmu_fault_fc(kernel_pmmu_fault_fc_p),
  .debug_trap_1111(kernel_trap_1111_p),
  .debug_exec_directSR(kernel_exec_directSR_p),
  .debug_exec_to_SR(kernel_exec_to_SR_p),
  // Register file debug (REGS ISSP)
  .debug_regfile_d0(kernel_regfile_d0_p),
  .debug_regfile_d1(kernel_regfile_d1_p),
  .debug_regfile_d2(kernel_regfile_d2_p),
  .debug_regfile_d3(kernel_regfile_d3_p),
  .debug_regfile_d4(kernel_regfile_d4_p),
  .debug_regfile_d5(kernel_regfile_d5_p),
  .debug_regfile_d6(kernel_regfile_d6_p),
  .debug_regfile_d7(kernel_regfile_d7_p),
  .debug_regfile_a0(kernel_regfile_a0_p),
  .debug_regfile_a1(kernel_regfile_a1_p),
  .debug_regfile_a2(kernel_regfile_a2_p),
  .debug_regfile_a3(kernel_regfile_a3_p),
  .debug_regfile_a4(kernel_regfile_a4_p),
  .debug_regfile_a5(kernel_regfile_a5_p),
  .debug_regfile_a6(kernel_regfile_a6_p),
  .debug_regfile_a7(kernel_regfile_a7_p)
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

	localparam DIAG_DISABLE_030_CACHE = 1'b1;

	// Cache enable logic - independent control for instruction and data caches.
	// The existing OSD slot with cpucfg=10 is reused for 68030; the logic keys off cpucfg[1].
	assign i_cache_enabled = cpucfg[1] & cacr_ie & ~DIAG_DISABLE_030_CACHE; // 68030 slot active and instruction cache enabled
	assign d_cache_enabled = cpucfg[1] & cacr_de & ~DIAG_DISABLE_030_CACHE; // 68030 slot active and data cache enabled

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
	assign i_cache_req = i_cache_enabled & (cpustate_p == 2'b00) & ~pmmu_fault_p; // Instruction fetch
	assign d_cache_addr = pmmu_addr_log_p;  // Use logical address for cache indexing
	assign d_cache_req = d_cache_enabled & (cpustate_p == 2'b10 | cpustate_p == 2'b11) & ~pmmu_fault_p; // Data read/write
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
	assign cache_hit = ((i_cache_hit & i_cache_req) | (d_cache_hit & d_cache_req & ~d_cache_we)) & ~pmmu_fault_p;
	assign cache_miss = ((i_cache_enabled & ~i_cache_hit & i_cache_req) | (d_cache_enabled & ~d_cache_hit & d_cache_req));

	// Connect cache fill interface to external memory controller
	// IBE/DBE bits control whether cache fills are allowed (not burst mode itself)
	// When IBE=0, instruction cache fills are disabled (all I-fetches bypass cache)
	// When DBE=0, data cache fills are disabled (all D-accesses bypass cache)
	// SDRAM burst mode is always BURST=4 (hardcoded in sdram_ctrl.v line 291)
	// Do not launch cache-line fills while PMMU translation is still unresolved or
	// while the walker owns Fast RAM. The cache fill request stays asserted until
	// serviced, so deferring it here is enough to prevent overlap with descriptor
	// reads without losing the miss.
	assign cache_req = fill_active | ((fill_pending_i | fill_pending_d) &
	                   ~pmmu_busy_p & ~pmmu_walker_req_p & ~walker_active);
	assign cache_addr = fill_active ? fill_addr_latched : (fill_pending_i ? i_fill_addr : d_fill_addr);

	// Burst control - unused (SDRAM permanently in BURST=4 mode)
	assign cache_burst = cache_req;
	assign cache_burst_len = 3'd7;  // Always 8 words for 128-bit cache line

	// Cache fill logic - accumulate 16-bit reads into 128-bit cache lines
	reg [2:0] fill_count;
	reg [127:0] fill_buffer;
	reg fill_active;
	reg fill_owner_i;
	reg [31:0] fill_addr_latched;
	reg fill_valid_r;
	reg fill_owner_r;
	reg [127:0] fill_data_r;

	wire fill_pending_i = i_fill_req & cacr_ibe;
	wire fill_pending_d = d_fill_req & cacr_dbe;
	wire fill_start = ~fill_active & ~pmmu_busy_p & ~pmmu_walker_req_p & ~walker_active &
	                  (fill_pending_i | fill_pending_d) & cache_ack;
	wire fill_accept = fill_active & cache_ack;

	always @(posedge clk) begin
		if (~reset) begin
			fill_count <= 0;
			fill_buffer <= 0;
			fill_active <= 0;
			fill_owner_i <= 0;
			fill_addr_latched <= 0;
			fill_valid_r <= 0;
			fill_owner_r <= 0;
			fill_data_r <= 0;
		end else begin
			fill_valid_r <= 0;
			if (fill_start) begin
				fill_active <= 1;
				fill_count <= 0;
				fill_owner_i <= fill_pending_i;
				fill_addr_latched <= fill_pending_i ? i_fill_addr : d_fill_addr;
				fill_buffer[15:0] <= cache_data;
			end else if (fill_accept) begin
				// Accumulate 16-bit words into 128-bit cache line
				case (fill_count)
					3'd0: fill_buffer[31:16]   <= cache_data;
					3'd1: fill_buffer[47:32]   <= cache_data;
					3'd2: fill_buffer[63:48]   <= cache_data;
					3'd3: fill_buffer[79:64]   <= cache_data;
					3'd4: fill_buffer[95:80]   <= cache_data;
					3'd5: fill_buffer[111:96]  <= cache_data;
					3'd6: begin
						fill_buffer[127:112] <= cache_data;
						fill_data_r <= {cache_data, fill_buffer[111:0]};
						fill_owner_r <= fill_owner_i;
						fill_valid_r <= 1;
						fill_active <= 0;  // Complete cache line
					end
					default: ;
				endcase
				if (fill_count < 7) fill_count <= fill_count + 1;
			end
		end
	end

	// Provide filled cache line to cache module
	assign i_fill_data = fill_data_r;
	assign i_fill_valid = fill_valid_r & fill_owner_r;
	assign d_fill_data = fill_data_r;
	assign d_fill_valid = fill_valid_r & ~fill_owner_r;

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
		assign walker_mem_ready = walker_chip_ram ? chipready : (walker_fast_ram ? ramready : (chipready | ramready | fastchip_ready));
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
	// BUG #439 FIX: Gap cycle between low and high word reads for SDRAM/DDR3.
	// The SDRAM/DDR3 cache (cpu_cache_new) uses cpu_cs level to detect requests.
	// cpu_ack (=ramready) stays latched high as long as cpu_cs stays high.
	// Without a gap, the high word read sees stale ramready and captures the
	// same data as the low word read, corrupting every 32-bit descriptor.
	localparam WALKER_RAM_GAP   = 4'd11;
	localparam WALKER_WRITE_RAM_GAP = 4'd12;

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
			walker_write_ready_armed <= 0;
			walker_read_ready_armed <= 0;
		end else begin
			case (walker_state)
				WALKER_IDLE: begin
					pmmu_walker_ack_p <= 0;
					pmmu_walker_berr_p <= 0;  // BUG #156 FIX: Clear BERR at start of new walk
					walker_active <= 0;
					// BUG #138: Reset timeout counter and error flag when idle
					walker_timeout_cnt <= 0;
					walker_timeout_error <= 0;
					walker_write_ready_armed <= 0;
					walker_read_ready_armed <= 0;
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
					walker_read_ready_armed <= 0;
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
					// Legacy chip/Gary bus walks: wait for chip bus SM idle (chip_stage==0).
					// SDRAM walks: wait for stale_ram_pending to clear (ramready fires).
					else if (walker_chip_ram) begin
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
					end else if (~walker_mem_ready) begin
						walker_read_ready_armed <= 1;
						walker_timeout_cnt <= walker_timeout_cnt + 1;
					end else if (walker_read_ready_armed) begin
						// Capture low 16 bits
						walker_read_ready_armed <= 0;
						walker_data_low <= cpu_din;
						// BUG #439 FIX: For SDRAM/DDR3 reads, insert a gap cycle to
						// deassert cpu_cs and clear cpu_ack before the high word read.
						// Legacy chip/Gary bus uses chipready (not cache), so no gap needed.
						if (walker_chip_ram)
							walker_state <= WALKER_READ_HIGH;
						else
							walker_state <= WALKER_RAM_GAP;
					end else begin
						// BUG #138: Increment timeout counter while waiting
						walker_timeout_cnt <= walker_timeout_cnt + 1;
					end
				end

				// BUG #439 FIX: Gap cycle for SDRAM/DDR3 cache between low and high word reads.
				// During this state, walker_fast_ram is suppressed (walker_state == WALKER_RAM_GAP
				// excluded). This deasserts ramsel -> cpuCS -> cpu_cs for the cache, clearing
				// cpu_ack and resetting the cache SM to IDLE. The next cycle (WALKER_READ_HIGH)
				// reasserts walker_fast_ram, starting a fresh cache transaction for the high word.
				WALKER_RAM_GAP: begin
					walker_timeout_cnt <= 0;
					walker_read_ready_armed <= 0;
					walker_state <= WALKER_READ_HIGH;
				end

				WALKER_READ_HIGH: begin
					// Drive walker address with LSB=1 for high word via walker_chip_addr mux
					// BUG #138: Reset timeout counter when entering wait state
					walker_timeout_cnt <= 0;
					walker_read_ready_armed <= 0;
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
						end else if (~walker_mem_ready) begin
							walker_read_ready_armed <= 1;
							walker_timeout_cnt <= walker_timeout_cnt + 1;
						end else if (walker_read_ready_armed) begin
							// BUG #405 FIX: Assemble 32-bit descriptor in big-endian order
							// walker_data_low was read from low address (= high word in big-endian)
							// cpu_din was read from high address (= low word in big-endian)
							walker_read_ready_armed <= 0;
							pmmu_walker_data_p <= {walker_data_low, cpu_din};
							pmmu_walker_ack_p <= 1;
							walker_state <= WALKER_DONE;
						end else begin
							// BUG #138: Increment timeout counter while waiting
							walker_timeout_cnt <= walker_timeout_cnt + 1;
						end
				end

					WALKER_DONE: begin
						// Completion pulse cleanup. ACK/BERR are asserted in the WAIT states
						// that actually complete the transfer, then cleared here so the next
						// descriptor read cannot observe a stale response.
						walker_active <= 0;  // Release bus
						walker_read_ready_armed <= 0;
						pmmu_walker_ack_p <= 0;
						pmmu_walker_berr_p <= 0;
						walker_state <= WALKER_IDLE;
					end

				// MC68030 U/M bit: Write states for descriptor updates
					WALKER_WRITE_LOW: begin
					// Drive walker address with LSB=0 for low word
					// Write data (walker_wdata_latch[15:0]) is driven via chip_din mux
						// BUG #424 FIX: Same escape hatches as WALKER_READ_LOW
						walker_timeout_cnt <= walker_timeout_cnt + 1;
						walker_write_ready_armed <= 0;
						if (~pmmu_walker_req_p) begin
						walker_state <= WALKER_DONE;
					end
					else if (walker_timeout_cnt >= WALKER_TIMEOUT_LIMIT) begin
						walker_timeout_error <= 1;
						pmmu_walker_berr_p <= 1;
						walker_state <= WALKER_DONE;
					end
					// BUG #422 FIX: Same stale-cycle guard as WALKER_READ_LOW (see above)
					else if (walker_chip_ram) begin
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
						end else if (~walker_mem_ready) begin
							walker_write_ready_armed <= 1;
							walker_timeout_cnt <= walker_timeout_cnt + 1;
						end else if (walker_write_ready_armed) begin
							// Low word written, now write high word.
							// Fast RAM uses cpu_cache_new/write-buffer logic behind a level-sensitive
							// cpu_cs. Drop walker_fast_ram for a cycle so the write path can return
							// to idle before the second 16-bit descriptor write.
							walker_write_ready_armed <= 0;
							if (walker_chip_ram)
								walker_state <= WALKER_WRITE_HIGH;
							else
								walker_state <= WALKER_WRITE_RAM_GAP;
						end else begin
							walker_timeout_cnt <= walker_timeout_cnt + 1;
						end
					end

					WALKER_WRITE_RAM_GAP: begin
						walker_timeout_cnt <= 0;
						walker_write_ready_armed <= 0;
						walker_state <= WALKER_WRITE_HIGH;
					end

					WALKER_WRITE_HIGH: begin
					// Drive walker address with LSB=1 for high word
						// Write data (walker_wdata_latch[31:16]) is driven via chip_din mux
						walker_timeout_cnt <= 0;
						walker_write_ready_armed <= 0;
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
							end else if (~walker_mem_ready) begin
								walker_write_ready_armed <= 1;
								walker_timeout_cnt <= walker_timeout_cnt + 1;
							end else if (walker_write_ready_armed) begin
								// Write complete
								walker_write_ready_armed <= 0;
								pmmu_walker_ack_p <= 1;
								walker_state <= WALKER_DONE;
							end else begin
								walker_timeout_cnt <= walker_timeout_cnt + 1;
							end
					end

					default: begin
						// Safety: recover from corrupted walker_state (e.g. timing violations)
						walker_state <= WALKER_IDLE;
						walker_active <= 0;
						walker_read_ready_armed <= 0;
						walker_write_ready_armed <= 0;
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

// BUG #135 FIX: Walker legacy RAM access detection
// When walker is reading from or writing to RAM behind Gary's legacy bus, it must trigger
// the chip bus state machine. Otherwise chipready never goes high and walker hangs.
// Chip RAM is $000000-$1FFFFF. Slow RAM is $C00000-$D7FFFF in 512 KiB banks.
wire walker_addr_is_chipram = !walker_addr_latch[31] && !walker_addr_latch[30] &&
                              !walker_addr_latch[29] && !walker_addr_latch[28] &&
                              !walker_addr_latch[27] && !walker_addr_latch[26] &&
                              !walker_addr_latch[25] && !walker_addr_latch[24] &&
                              !walker_addr_latch[23] && !walker_addr_latch[22] &&
                              !walker_addr_latch[21];
wire walker_addr_is_slowram = !walker_addr_latch[31] && !walker_addr_latch[30] &&
                              !walker_addr_latch[29] && !walker_addr_latch[28] &&
                              !walker_addr_latch[27] && !walker_addr_latch[26] &&
                              !walker_addr_latch[25] && !walker_addr_latch[24] &&
                              ((walker_addr_latch[23:19] == 5'b11000) ||
                               (walker_addr_latch[23:19] == 5'b11001) ||
                               (walker_addr_latch[23:19] == 5'b11010));
wire walker_addr_uses_chip_bus = walker_addr_is_chipram | walker_addr_is_slowram;

// MC68030 U/M bit: Include walker writes for descriptor updates
wire walker_chip_ram = USE_68030_CACHE && (walker_reading | walker_writing) && walker_addr_uses_chip_bus;
wire walker_chip_cycle_active = USE_68030_CACHE && walker_active && walker_addr_uses_chip_bus;

always @(posedge clk) begin
	// BUG #135 FIX: Include walker chip RAM access in chipreq
	// MC68030 bus fault: suppress chip bus when PMMU is translating or faulted
	chipreq <= (cpu_req & ~ramsel & ~fastchip_selack & ~pmmu_suppress_bus ) | walker_chip_ram;
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
		chip_addr_latched <= 23'b0;
		chip_din_latched <= 16'b0;
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
						chip_addr_latched <= chip_addr_req;
						chip_din_latched <= chip_din_req;
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
