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
(
	input             reset,
	output reg        reset_out,

	input             clk,
	input             ph1,
	input             ph2,

	input       [2:0] cpucfg,
	input       [2:0] fastramcfg,
	input       [2:0] cachecfg,
	input             bootrom,

	output reg [31:1] chip_addr,
	input      [31:0] chip_dout,
	output reg [31:0] chip_din,
	output reg        chip_as,
	output reg        chip_uds,
	output reg        chip_lds,
	output reg  [3:0] chip_be,     // NEW: 4-byte enables (active-low) for 32-bit support
	output reg        chip_rw,
	input             chip_dtack,
	input       [2:0] chip_ipl,
	
	input      [31:0] fastchip_dout,
	output reg        fastchip_sel,
	output            fastchip_lds,
	output            fastchip_uds,
	output            fastchip_rnw,
	output reg        fastchip_lw,
	input             fastchip_selack,
	input             fastchip_ready,

	output            ramsel,
	output     [28:1] ramaddr,
	output     [31:0] ramdin,
	input      [31:0] ramdout,
	input             ramready,
	output            ramlds,
	output            ramuds,
	output            ramshared,

	output            toccata_ena,
	output reg  [7:0] toccata_base,

	output reg  [1:0] cpustate,
	output reg  [3:0] cacr,
	output reg [31:0] nmi_addr,
	output            cpu_longword
);

assign ramsel       = cpu_req & ~sel_nmi_vector & (sel_zram | sel_chipram | sel_kickram | sel_dd | sel_rtg);
assign ramshared    = sel_dd;
assign cpu_longword = cpucfg[2] ? longword_w : cpucfg[1] ? longword : 1'b0;  // Export longword for gayle and other modules

// NMI
always @(posedge clk) nmi_addr <= vbr + 32'h7c;

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

wire [31:0] ramdat;

assign ramlds = sel_rtg ? uds_in : lds_in;
assign ramuds = sel_rtg ? lds_in : uds_in;
assign ramdin = sel_rtg ? {cpu_dout[23:16],cpu_dout[31:24],cpu_dout[7:0],cpu_dout[15:8]} : cpu_dout;
assign ramdat = sel_rtg ? {ramdout[23:16], ramdout[31:24], ramdout[7:0], ramdout[15:8]}  : ramdout;

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
reg  [31:0] cpu_dout;

// For now, run WF68K30L at full system clock speed
// The DSACK protocol will handle timing automatically
wire clk_cpu = clk;

// WF68K30L initialization sequencer
// Required: RESET_INn=1 AND HALT_INn=0 for 10+ clocks to release internal CPU reset
reg [3:0] wf68k_init_count;
reg wf68k_halt_n;

always @(posedge clk) begin
    if (reset) begin
        wf68k_init_count <= 4'd0;
        wf68k_halt_n <= 1'b0;  // Assert HALT during system reset
    end else begin
        if (wf68k_init_count < 4'd15) begin
            wf68k_init_count <= wf68k_init_count + 4'd1;
            wf68k_halt_n <= 1'b0;  // Keep HALT asserted for 15 clocks after reset release
        end else begin
            wf68k_halt_n <= 1'b1;  // Release HALT after initialization complete
        end
    end
end

// Proper autoconfig halfword selection with byte-lane discipline
wire [31:0] autoconfig_data;
assign autoconfig_data = sel_autoconfig ? 
    (longword ? 
        // Longword read: return autoconfig data in upper nibble of each halfword
        {autocfg_data, 12'hFFF, autocfg_data, 12'hFFF} :
        // Halfword reads
        (uds_in ? {autocfg_data, 12'hFFF, 16'hFFFF} :  // Upper half addressed
         lds_in ? {16'hFFFF, autocfg_data, 12'hFFF} :   // Lower half addressed  
                  {autocfg_data, 12'hFFF, autocfg_data, 12'hFFF})) : // Fallback
    32'hFFFFFFFF;

// Clean multiplexer to prevent bit contamination - only one source active
wire [31:0] cpu_din = ramsel ? ramdat :
                     fastchip_selack ? fastchip_dout :
                     sel_autoconfig ? autoconfig_data :
                     chip_data;
wire [15:0] cpu_din_16 = cpu_din[15:0];  // 16-bit data for TG68K - keep simple
reg         wr;
reg         uds_in;
reg         lds_in;
reg  [31:0] chip_data;
reg  [31:0] vbr;
reg         longword_autoconfig;
reg   [1:0] autoconfig_addr_r;

// Byte enable generation for consistent lane discipline
wire  [3:0] byte_enables;
assign byte_enables = longword ? 4'b1111 :
                     uds_in ? (cpu_addr[1] ? 4'b1100 : 4'b0011) :
                     lds_in ? (cpu_addr[1] ? 4'b1100 : 4'b0011) :
                              4'b1111; // Default to all enabled

always @* begin
	if(cpucfg[2]) begin
		// WF68K30L CPU selected
		cpu_dout     = cpu_dout_w;
		cpu_addr     = cpu_addr_w;
		cpustate     = cpustate_w;
		cacr         = cacr_w;
		vbr          = vbr_w;
		wr           = ~wr_w;
		uds_in       = uds_w;
		lds_in       = lds_w;
		reset_out    = ~reset_out_w;
		chip_as      = as_w;
		chip_rw      = ~wr_w;  // CRITICAL FIX: RWn is active-low, chip_rw is active-high (1=write)
		chip_uds     = uds_w;
		chip_lds     = lds_w;
		chip_be      = be_w;  // NEW: Export 4-byte enables for 32-bit support
		chip_addr    = cpu_addr_w[31:1];
		chip_din     = cpu_dout_w;
		chip_data    = chip_dout;
		fastchip_sel = cpu_req & (cpu_addr_w[31:24] >= 8'h02 && cpu_addr_w[31:24] <= 8'h9F); // FastRAM regions $02000000-$9FFFFFFF
		fastchip_lw  = longword_w;
	end
	else if(cpucfg == 3'b001 || cpucfg == 3'b010 || cpucfg == 3'b011) begin
		// TG68K CPU selected
		cpu_dout     = cpu_dout_p;
		cpu_addr     = cpu_addr_p;
		cpustate     = cpustate_p;
		cacr         = cacr_p;
		vbr          = vbr_p;
		wr           = wr_p;
		uds_in       = uds_p;
		lds_in       = lds_p;
		reset_out    = reset_out_p;
		chip_as      = c_as;
		chip_rw      = c_rw;
		chip_uds     = c_uds;
		chip_lds     = c_lds;
		chip_be      = {2'b11, ~c_uds, ~c_lds};  // TG68K: Convert UDS/LDS to byte enables
		chip_addr    = cpu_addr_p[31:1];
		chip_din     = cpu_dout_p;
		chip_data    = chipdout_i;
		fastchip_sel = cpu_req & (cpu_addr_p[31:24] >= 8'h02 && cpu_addr_p[31:24] <= 8'h9F); // FastRAM regions $02000000-$9FFFFFFF
		fastchip_lw  = longword;
	end
	else begin
		// fx68k CPU selected (68000)
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
		chip_be      = {2'b11, ~uds_o, ~lds_o};  // FX68K: Convert UDS/LDS to byte enables
		chip_addr    = cpu_addr_o[31:1];
		chip_din     = cpu_dout_o;
		chip_data    = chip_dout;
		fastchip_sel = 0;
		fastchip_lw  = 0;
	end
end

wire [15:0] cpu_dout_p_16;
wire [31:0] cpu_dout_p = {cpu_dout_p_16, cpu_dout_p_16};
wire [31:0] cpu_addr_p;
wire  [1:0] cpustate_p;
wire  [3:0] cacr_p;
wire [31:0] vbr_p;
wire        wr_p;
wire        uds_p;
wire        lds_p;
wire        reset_out_p;
wire        longword;

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
  .clkena_in(~cpu_req | chipready | ramready | fastchip_ready),
  .data_in(cpu_din_16),
  .ipl(cpu_ipl),
  .ipl_autovector(1),
  .regin_out(),
  .addr_out(cpu_addr_p),
  .data_write(cpu_dout_p_16),
  .nwr(wr_p),
  .nuds(uds_p),
  .nlds(lds_p),
  .nresetout(reset_out_p),
  .longword(longword),
  
  .cpu(cpucfg),
  .busstate(cpustate_p),		// 0: fetch code, 1: no memaccess, 2: read data, 3: write data
  .cacr_out(cacr_p),
  .vbr_out(vbr_p)
);

wire [31:0] cpu_dout_o;
wire [31:1] cpu_addr_o;
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

// WF68K30L CPU Core - Full MC68030 compatibility
wire [31:0] cpu_dout_w;
wire [31:0] cpu_addr_w;
wire  [2:0] fc_w;
wire        wr_w;
wire        as_w;
wire        ds_w;
wire        rmc_w;
wire  [3:0] be_w;        // 4-byte enables: BE3(31:24), BE2(23:16), BE1(15:8), BE0(7:0)
wire        uds_w;       // Legacy 16-bit UDS (for backward compatibility)
wire        lds_w;       // Legacy 16-bit LDS (for backward compatibility)
wire        reset_out_w;
wire  [1:0] size_w;
wire  [1:0] cpustate_w;
wire  [3:0] cacr_w;
wire [31:0] vbr_w;
wire        longword_w;

// DSACK generation for WF68K30L
wire  [1:0] dsack_w;
// Note: chip_dtack is active-low from minimig module (._cpu_dtack)
wire        dtack_active = ramsel ? ramready : ~chip_dtack;

// Fixed DTACK to DSACK protocol conversion for WF68K30L
// DSACK encoding: 11=no acknowledge, 10=8-bit, 01=16-bit, 00=32-bit
// SIZE encoding: 00=byte, 01=word, 10=3-byte, 11=longword
// CRITICAL: Only assert DSACK when ASn is active (low) AND dtack is ready
assign dsack_w = (~as_w & dtack_active) ? (
    (size_w == 2'b00) ? 2'b10 :   // Byte -> 8-bit port
    (size_w == 2'b01) ? 2'b01 :   // Word -> 16-bit port
    (size_w == 2'b10) ? 2'b01 :   // 3-byte -> treat as 16-bit port
    (size_w == 2'b11) ? 2'b00 :   // Longword -> 32-bit port
    2'b11                         // Invalid -> no acknowledge
) : 2'b11;

// TRUE 32-BIT BUS: SIZE to 4-byte-enable conversion
// This removes the 16-bit bottleneck and enables full 32-bit bandwidth
// BE[3:0] active-low: BE3(31:24), BE2(23:16), BE1(15:8), BE0(7:0)
wire [1:0] byte_lanes = cpu_addr_w[1:0];
assign be_w = ds_w ? 4'b1111 : (  // When DSn inactive, all byte enables off
    (size_w == 2'b00) ? (  // Byte access - enable single byte based on address
        (byte_lanes == 2'b00) ? 4'b1110 :  // Byte 3 (bits 31:24)
        (byte_lanes == 2'b01) ? 4'b1101 :  // Byte 2 (bits 23:16)
        (byte_lanes == 2'b10) ? 4'b1011 :  // Byte 1 (bits 15:8)
        (byte_lanes == 2'b11) ? 4'b0111 :  // Byte 0 (bits 7:0)
        4'b1111
    ) :
    (size_w == 2'b01) ? (  // Word (16-bit) - enable 2 bytes based on address
        cpu_addr_w[1] ? 4'b0011 :  // Upper word (bits 31:16) - BE3,BE2 active
                        4'b1100    // Lower word (bits 15:0)  - BE1,BE0 active
    ) :
    (size_w == 2'b11) ? 4'b0000 :  // Longword (32-bit) - all 4 bytes active
    4'b1111  // Invalid/3-byte size
);

// Legacy 16-bit UDS/LDS for backward compatibility with minimig_m68k_bridge
// Map 4-byte enables to 16-bit strobes: UDS=BE1, LDS=BE0
assign uds_w = be_w[1];  // Byte 1 enable (bits 15:8)
assign lds_w = be_w[0];  // Byte 0 enable (bits 7:0)

// Map WF68K30L bus state to cpustate (invert AS since WF68K30L uses active low)
assign cpustate_w = as_w ? 2'b01 : (~wr_w ? 2'b11 : 2'b10);
assign longword_w = (size_w == 2'b11);

// WF68K30L advanced configuration from unused cache config bits
wire wf68k30l_pipeline_en = 1'b0; //cachecfg[2] & cpucfg[2];  // Enable pipelining when dcache bit set and WF68K30L selected
wire wf68k30l_loop_opt_en = 1'b0; //cachecfg[1] & cpucfg[2];  // Enable DBcc loop optimization
wire wf68k30l_bitfield_en = 1'b0; //cachecfg[0] & cpucfg[2];  // Enable bitfield operations

// WF68K30L control registers (simplified implementation)
assign cacr_w = 4'b0000;  // No cache in WF68K30L, always zero
assign vbr_w = 32'h00000000;  // Vector base register - could be enhanced later

WF68K30L_TOP
#(
    .VERSION(32'h20220101)        // Version identifier
    // Dynamic configuration via cachecfg bits when WF68K30L is selected:
    // - cachecfg[2] & cpucfg[2] -> Pipeline enable/disable
    // - cachecfg[1] & cpucfg[2] -> DBcc loop optimization
    // - cachecfg[0] & cpucfg[2] -> Bitfield operations
    // Note: Boolean generics must use default values due to Verilog/VHDL constraints
)
cpu_inst_w
(
    .CLK(clk_cpu),            // Use divided clock for WF68K30L (28.5 MHz)

    // Address and data buses
    .ADR_OUT(cpu_addr_w),
    .DATA_IN(cpu_din),
    .DATA_OUT(cpu_dout_w),
    .DATA_EN(),                   // Not used in MiSTer

    // System control
    .BERRn(1'b1),                 // No bus error for now
    .RESET_INn(~reset),           // WF68K30L expects active-low reset
    .RESET_OUT(reset_out_w),      // Open drain output
    .HALT_INn(wf68k_halt_n),      // Proper initialization sequence: RESET=1,HALT=0 for 10+ clocks
    .HALT_OUTn(),                 // Not used

    // Processor status
    .FC_OUT(fc_w),

    // Interrupt control
    .AVECn(1'b0),                 // Auto-vector enabled
    .IPLn(~chip_ipl),             // Active low interrupts
    .IPENDn(),                    // Not used

    // Asynchronous bus control
    .DSACKn(dsack_w),
    .SIZE(size_w),
    .ASn(as_w),
    .RWn(wr_w),
    .RMCn(rmc_w),
    .DSn(ds_w),
    .ECSn(),                      // Not used in MiSTer
    .OCSn(),                      // Not used in MiSTer
    .DBENn(),                     // Data buffer enable - not used
    .BUS_EN(),                    // Bus enable - not used

    // Synchronous bus control
    .STERMn(1'b1),                // No synchronous termination

    // Status controls
    .STATUSn(),                   // Not used
    .REFILLn(),                   // Not used

    // Bus arbitration control (not implemented in MiSTer)
    .BRn(1'b1),
    .BGn(),
    .BGACKn(1'b1)
);

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
		turbochip_d <= cachecfg[0] & (cpucfg[1] | cpucfg[2]);
		turbokick_d <= cachecfg[1] & (cpucfg[1] | cpucfg[2]);
		dcache_d    <= cachecfg[2];
	end
end

reg       chipreq;
reg [2:0] cpu_ipl;
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
reg [31:0] chipdout_i;
reg  [2:0] ipl_i;
reg        c_as,c_rw,c_uds,c_lds;

// WF68K30L fast path detection
wire wf68k30l_fast_access = cpucfg[2] && (ramsel || fastchip_sel || sel_kickram);

always @(negedge clk, negedge reset) begin
	reg [1:0] stage;
	reg waitm;
	reg ready;

	if(~reset) begin
		stage <= 0;
		c_as <= 1;
		c_rw <= 1;
		c_uds <= 1;
		c_lds <= 1;
		ready <= 0;
	end
	else begin
		if (ph2n) begin
			// Fast DTACK for WF68K30L accessing fast resources
			if (wf68k30l_fast_access) begin
				waitm <= 1'b0;  // Immediate DTACK for fast resources
			end else begin
				waitm <= chip_dtack;  // Standard DTACK for slow resources
			end
			if(~stage[0]) ipl_i <= chip_ipl;
		end

		chipready <= 0;
		if (ph1n) begin
			chipready <= ready;
			ready <= 0;

			// Ultra-fast single-cycle mode for WF68K30L fast accesses
			if (wf68k30l_fast_access && chipreq && stage == 0) begin
				// Single-cycle completion for WF68K30L fast resources
				c_as <= 0;
				c_rw <= wr;
				c_uds <= uds_in;
				c_lds <= lds_in;
				chipdout_i <= chip_dout;
				ready <= 1;
				stage <= 3;  // Skip to completion stage
			end
			else begin
				case (stage)
					0: if (chipreq) begin
							c_as <= 0;
							c_rw <= wr;
							c_uds <= uds_in;
							c_lds <= lds_in;
							// Fast path for WF68K30L - skip to stage 2 for immediate response
							stage <= wf68k30l_fast_access ? 2 : 1;
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
					3: begin
							c_as <= 1;
							c_rw <= 1;
							c_uds <= 1;
							c_lds <= 1;
							stage <= 0;
						end
				endcase
			end
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
		ac_memcard  <= (cpucfg[1] | cpucfg[2]) ? fastramcfg : fastramcfg[2] ? 3'd3 : {1'b0, fastramcfg[1:0]};
		ac_toccata  <= 1;
		z2ram_ena   <= 0;
		z3ram_ena0  <= 0;
		z3ram_ena1  <= 0;
		z3ram_base0 <= 1;
		z3ram_base1 <= 1;
		longword_autoconfig <= 0;
		autoconfig_addr_r <= 0;
	end
	// Track longword operations for autoconfig (similar to gayle.v)
	else if (sel_autoconfig && chip_rw) begin
		if ((cpucfg[1] && longword) || (cpucfg[2] && longword_w)) begin
			longword_autoconfig <= ~longword_autoconfig;
			if (~longword_autoconfig) autoconfig_addr_r <= cpu_addr[1:0];
		end
		else begin
			longword_autoconfig <= 0;
		end
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
