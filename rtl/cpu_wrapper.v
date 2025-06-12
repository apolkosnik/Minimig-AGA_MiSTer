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
	// System control signals
	input             reset,
	output reg        reset_out,      // CPU reset output

	// Clock and timing signals
	input             clk,
	input             ph1,            // Phase 1 clock for 68000
	input             ph2,            // Phase 2 clock for 68000

	// Configuration inputs
	input       [1:0] cpucfg,         // CPU configuration (which CPU core to use)
	input       [2:0] fastramcfg,     // Fast RAM configuration
	input       [2:0] cachecfg,       // Cache configuration
	input             bootrom,        // Boot ROM enable

	// Chip RAM interface (original Amiga chip memory)
	output reg [23:1] chip_addr,      // Chip RAM address
	input      [15:0] chip_dout,      // Data from chip RAM
	output reg [15:0] chip_din,       // Data to chip RAM
	output reg        chip_as,        // Address strobe
	output reg        chip_uds,       // Upper data strobe
	output reg        chip_lds,       // Lower data strobe
	output reg        chip_rw,        // Read/Write signal
	input             chip_dtack,     // Data acknowledge from chip RAM
	input       [2:0] chip_ipl,       // Interrupt priority level
	
	// Fast chip interface (for fast chip RAM access)
	input      [15:0] fastchip_dout,
	output reg        fastchip_sel,
	output            fastchip_lds,
	output            fastchip_uds,
	output            fastchip_rnw,
	output reg        fastchip_lw,    // Longword access
	input             fastchip_selack,
	input             fastchip_ready,

	// Main RAM interface (SDRAM/DDR)
	output            ramsel,         // RAM select signal
	output     [28:1] ramaddr,        // RAM address (up to 512MB addressable)
	output     [15:0] ramdin,         // Data to RAM
	input      [15:0] ramdout,        // Data from RAM
	input             ramready,       // RAM ready signal
	output            ramlds,         // RAM lower data strobe
	output            ramuds,         // RAM upper data strobe
	output            ramshared,      // Indicates shared RAM access

	// Toccata sound card support
	output            toccata_ena,
	output reg  [7:0] toccata_base,   // Base address for Toccata card

	// CPU state outputs
	output reg  [1:0] cpustate,       // CPU state (fetch, read, write, etc.)
	output reg  [3:0] cacr,           // Cache control register
	output reg [31:0] nmi_addr        // Non-maskable interrupt address
);

// RAM selection logic - selects main RAM for various memory regions
assign ramsel       = cpu_req & ~sel_nmi_vector & (sel_zram | sel_chipram | sel_kickram | sel_dd | sel_rtg);
assign ramshared    = sel_dd;  // DD memory region is shared

// NMI (Non-Maskable Interrupt) address calculation
// VBR (Vector Base Register) + 0x7C = NMI vector offset
always @(posedge clk) nmi_addr <= vbr + 32'h7c;

// Memory region selection signals
// Zorro III RAM regions (128MB and 256MB chunks)
wire sel_z3ram0 = (cpu_addr[31:27] == z3ram_base0) && z3ram_ena0;
wire sel_z3ram1 = (cpu_addr[31:28] == z3ram_base1) && z3ram_ena1;
// Zorro II RAM (2-8MB in 24-bit address space)
wire sel_z2ram  = !cpu_addr[31:24] && (cpu_addr[23] ^ |cpu_addr[22:21]) && z2ram_ena; // addr[23:21] = 1..4
wire sel_zram   = sel_z3ram0 | sel_z3ram1 | sel_z2ram;  // Any Zorro RAM
// DD memory region (diagnostic/debug area at $00DD0000)
wire sel_dd     = (cpu_addr[31:16] == 16'h00DD) && (cpu_addr[15:13] == 'b010);
// RTG (Retargetable Graphics) memory at $02000000
wire sel_rtg    = (cpu_addr[31:24] == 8'h02);

// Kickstart ROM selection
// Located at $F80000-$FFFFFF and $E00000-$E7FFFF (when reading only)
wire sel_kickram   = !cpu_addr[31:24] && (&cpu_addr[23:19] || (cpu_addr[23:19] == 5'b11100)) && ckick && wr;
wire sel_kicklower = !cpu_addr[31:24] && (cpu_addr[23:18] == 6'b111110);
// Chip RAM selection (first 2MB of address space)
wire sel_chipram   = !cpu_addr[31:21] && cchip;

// NMI vector selection (for debugging/hrtmon)
wire sel_nmi_vector = (cpu_addr[31:2] == nmi_addr[31:2]) && (cpustate == 2);

wire [15:0] ramdat;

// RTG byte swapping logic (RTG uses different endianness)
assign ramlds = sel_rtg ? uds_in : lds_in;
assign ramuds = sel_rtg ? lds_in : uds_in;
assign ramdin = sel_rtg ? {cpu_dout[7:0],cpu_dout[15:8]} : cpu_dout;
assign ramdat = sel_rtg ? {ramdout[7:0], ramdout[15:8]}  : ramdout;

// RAM address mapping
// Maps different memory regions to physical RAM addresses
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

// Address bit assignments for RAM controller
assign ramaddr[28]    = sel_zram & ~sel_z3ram0;
assign ramaddr[27]    = sel_zram & (~sel_z3ram1 | cpu_addr[27]);
assign ramaddr[26:23] = (sel_z3ram0 | sel_z3ram1) ? cpu_addr[26:23]: (sel_rtg ? 4'b1110 : {4{sel_dd}});
assign ramaddr[22:19] = {4{sel_dd}} | cpu_addr[22:19];
assign ramaddr[18]    =    sel_dd   | (sel_kicklower & bootrom) | cpu_addr[18];
assign ramaddr[17:16] = {2{sel_dd}} | cpu_addr[17:16];
assign ramaddr[15:1]  = cpu_addr[15:1];

// Fast chip RAM control signals
assign fastchip_lds = lds_in;
assign fastchip_uds = uds_in;
assign fastchip_rnw = wr;

// CPU interface signals
reg  [31:0] cpu_addr;     // Current CPU address
reg  [15:0] cpu_dout;     // CPU data output
// CPU data input multiplexer - selects between different data sources
wire [15:0] cpu_din = ramsel ? ramdat : 
                      fastchip_selack ? fastchip_dout : 
                      {sel_autoconfig ? autocfg_data : chip_data[15:12], chip_data[11:0]};
reg         wr;           // Write signal (1=read, 0=write)
reg         uds_in;       // Upper data strobe
reg         lds_in;       // Lower data strobe
reg  [15:0] chip_data;    // Latched chip RAM data
reg  [31:0] vbr;          // Vector Base Register

// CPU core selection multiplexer
// Selects between TG68K (020+ compatible) and fx68k (cycle-accurate 68000)
always @* begin
	if(cpucfg[1:0]) begin
		// Use TG68K core (68020+ compatible)
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
		chip_addr    = cpu_addr_p[23:1];
		chip_din     = cpu_dout_p;
		chip_data    = chipdout_i;
		fastchip_sel = cpu_req & !cpu_addr_p[31:24];
		fastchip_lw  = longword;
	end
	else begin
		// Use fx68k core (cycle-accurate 68000)
		cpu_dout     = cpu_dout_o;
		cpu_addr     = {cpu_addr_o,1'b0};
		cpustate     = as_o ? 2'b01 : ~{wr_o,wr_o};
		cacr         = 1;  // Simple cache for 68000
		vbr          = 0;  // No VBR on 68000
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
		fastchip_sel = 0;  // No fast chip access for 68000
		fastchip_lw  = 0;
	end
end

// TG68K core signals (68020+ compatible core)
wire [15:0] cpu_dout_p;
wire [31:0] cpu_addr_p;
wire  [1:0] cpustate_p;
wire  [3:0] cacr_p;
wire [31:0] vbr_p;
wire        wr_p;
wire        uds_p;
wire        lds_p;
wire        reset_out_p;
wire        longword;

// TG68K CPU instantiation (68020/030/040 compatible)
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
  .clkena_in(~cpu_req | chipready | ramready | fastchip_ready),  // CPU clock enable
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
  .vbr_out(vbr_p)
);

// fx68k core signals (cycle-accurate 68000)
wire [15:0] cpu_dout_o;
wire [23:1] cpu_addr_o;
wire  [2:0] fc_o;
wire        wr_o;
wire        as_o;
wire        uds_o;
wire        lds_o;
wire        reset_out_o;

// fx68k CPU instantiation (cycle-accurate 68000)
fx68k cpu_inst_o
(
	.clk(clk),
	.enPhi1(ph1),     // Enable phase 1 clock
	.enPhi2(ph2),     // Enable phase 2 clock

	.extReset(~reset),
	.pwrUp(~reset),
	.oRESETn(reset_out_o),
	.HALTn(1),        // Not halted

	// Bus control signals
	.eRWn(wr_o),
	.ASn(as_o),
	.LDSn(lds_o),
	.UDSn(uds_o),
	.DTACKn(ramsel ? ~ramready : chip_dtack),  // Data acknowledge

	// Function codes (supervisor/user, program/data)
	.FC0(fc_o[0]),
	.FC1(fc_o[1]),
	.FC2(fc_o[2]), 

	// Interrupt control
	.VPAn(~&fc_o),    // Valid peripheral address (autovector)
	.BERRn(1),        // No bus error
	.BRn(1),          // No bus request
	.BGACKn(1),       // No bus grant acknowledge
	.IPL0n(chip_ipl[0]),
	.IPL1n(chip_ipl[1]),
	.IPL2n(chip_ipl[2]),
	
	// Data bus
	.iEdb(cpu_din),
	.oEdb(cpu_dout_o),
	.eab(cpu_addr_o)
);

// CPU request signal (active when not in idle state)
wire cpu_req = (cpustate != 1);

// Turbo mode signals for chip and kick RAM
wire cchip = turbochip_d & (!cpustate | dcache_d);  // Fast chip RAM access
wire ckick = turbokick_d & (!cpustate | dcache_d);  // Fast kick ROM access

// Cache configuration registers
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
		turbochip_d <= cachecfg[0] & cpucfg[1];  // Enable turbo chip RAM for 020+
		turbokick_d <= cachecfg[1] & cpucfg[1];  // Enable turbo kick ROM for 020+
		dcache_d    <= cachecfg[2];              // Data cache enable
	end
end

// Chip RAM request and interrupt handling
reg       chipreq;
reg [2:0] cpu_ipl;
always @(posedge clk) begin
	chipreq <= cpu_req & ~ramsel & ~fastchip_selack;  // Request to chip RAM
	cpu_ipl <= ipl_i;  // Latch interrupt priority level
end

// Phase clock edge detection
reg ph1n, ph2n;
always @(posedge clk) begin
	ph1n <= ph1;
	ph2n <= ph2;
end

// Chip RAM access state machine
// Handles the timing for accessing the original Amiga chip RAM
reg        chipready;
reg [15:0] chipdout_i;
reg  [2:0] ipl_i;
reg        c_as,c_rw,c_uds,c_lds;
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
			waitm <= chip_dtack;  // Sample DTACK on phase 2
			if(~stage[0]) ipl_i <= chip_ipl;  // Sample interrupt level
		end

		chipready <= 0;
		if (ph1n) begin
			chipready <= ready;
			ready <= 0;
			case (stage)
				0: if (chipreq) begin
						// Start chip RAM access cycle
						c_as <= 0;
						c_rw <= wr;
						c_uds <= uds_in;
						c_lds <= lds_in;
						stage <= 1;
					end
				1: stage <= 2;  // Wait state
				2: begin
						// Complete the access
						chipdout_i <= chip_dout;
						if (~waitm) begin  // Wait for DTACK
							c_as <= 1;
							c_rw <= 1;
							c_uds <= 1;
							c_lds <= 1;
							ready <= 1;
							stage <= 3;
						end
					end
				3: stage <= 0;  // Return to idle
			endcase
		end
	end
end

///////////////////// AUTOCONFIG ////////////////////////////
// Implements Amiga's autoconfig protocol for Zorro expansion cards

reg       ac_toccata;    // Toccata sound card autoconfig
reg [2:0] ac_memcard;    // Memory card autoconfig state
reg [3:0] autocfg_data;  // Autoconfig data nibble

always @(*) begin
	autocfg_data = 4'b1111;  // Default to all 1s (no card)

	// Zorro II RAM autoconfig (2-8MB at 0x200000) It has a fixed base, so it must be first in the chain.
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
			6'b010011: autocfg_data = 4'b1110; // Serial number = 1
			  default:;
		endcase
	end
	// Toccata sound card autoconfig
	else if(ac_toccata) begin
		case (chip_addr[6:1])
			6'h0: autocfg_data = 4'b1100; // Zorro-II card, no link, no ROM
			6'h1: autocfg_data = 4'b0001; // Next board not related, size 64k
			// Inverted nibbles from here on
			6'h3: autocfg_data = 4'b0011; // Lower byte product number
			6'h8: autocfg_data = 4'b1011; // Manufacturer ID: 0x4754
			6'h9: autocfg_data = 4'b1000;
			6'ha: autocfg_data = 4'b1010;
			6'hb: autocfg_data = 4'b1011;
			default: ;
		endcase
	end 
	// Zorro III RAM autoconfig (128MB or 256MB)
	else if(ac_memcard[2]) begin
		case (chip_addr[6:1])
			6'b000000: autocfg_data = 4'b1010;	// Zorro-III card, add mem, no ROM
			6'b000001: autocfg_data = ac_memcard[1] ? 4'b0011 : 4'b0100; // 128MB or 256MB
			6'b000010: autocfg_data = 4'b1110;	// ProductID=0x10
			6'b000100: autocfg_data = 4'b0000;	// Memory card, extended size
			6'b000101: autocfg_data = 4'b1111;	// Logical size matches physical
			6'b001000: autocfg_data = 4'b1110;	// Manufacturer ID: 0x139c
			6'b001001: autocfg_data = 4'b1100;
			6'b001010: autocfg_data = 4'b0110;
			6'b001011: autocfg_data = 4'b0011;
			6'b010011: autocfg_data = {2'b11, ~ac_memcard[1], ac_memcard[1]};	// Serial 1/2
			  default:;
		endcase
	end
end

// Autoconfig space selection ($E80000 - $E8FFFF)
wire sel_autoconfig = (chip_addr[23:16] == 8'b11101000) && (ac_memcard || ac_toccata);

// Autoconfig state machine
// Handles configuration of Zorro expansion cards
reg       z2ram_ena;      // Zorro II RAM enable
reg [4:0] z3ram_base0;    // Zorro III RAM base address (128MB)
reg [3:0] z3ram_base1;    // Zorro III RAM base address (256MB)
reg       z3ram_ena0;     // Zorro III RAM 0 enable
reg       z3ram_ena1;     // Zorro III RAM 1 enable

always @(posedge clk) begin
	reg old_uds;
	old_uds <= chip_uds;

	if (~reset | ~reset_out) begin
		// Initialize autoconfig based on CPU and RAM configuration
		ac_memcard  <= cpucfg[1] ? fastramcfg : fastramcfg[2] ? 3'd3 : {1'b0, fastramcfg[1:0]};
		ac_toccata  <= 1;
		z2ram_ena   <= 0;
		z3ram_ena0  <= 0;
		z3ram_ena1  <= 0;
		z3ram_base0 <= 1;
		z3ram_base1 <= 1;
	end
	else if (sel_autoconfig && ~chip_rw && ~chip_uds && old_uds) begin
		// Handle autoconfig writes
		if(~ac_memcard[2] && ac_memcard[1:0]) begin
			if (chip_addr[6:1] == 6'b100100) begin // Register 0x48 - config done, ZII RAM
				z2ram_ena <= 1;  // Enable Zorro II RAM
				ac_memcard <= 0; // Move to next card
			end
		end
		else if(ac_toccata) begin
			if (chip_addr[6:1] == 6'b100100) begin // Register 0x48 - config done
				toccata_base <= cpu_dout[7:0];  // Set Toccata base address
				ac_toccata<=0;  // Move to next card
			end		
		end
		else if(ac_memcard[2]) begin
			if(chip_addr[6:1] == 6'b100010) begin // Register 0x44 - base address
				if(~ac_memcard[1]) begin
					// Configure 256MB Zorro III RAM
					z3ram_base1 <= cpu_dout[15:12];
					z3ram_ena1 <= 1;
					ac_memcard <= {ac_memcard[0], ac_memcard[0], 1'b0};
				end
				else begin
					// Configure 128MB Zorro III RAM
					z3ram_base0 <= cpu_dout[15:11];
					z3ram_ena0 <= 1;
					ac_memcard <= 0;
				end
			end
		end
	end
end

// Toccata sound card enable output
assign toccata_ena = ~ac_toccata;

endmodule
