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
	output      [2:0] cache_burst_len   // Burst length (number of words)
);

assign ramsel       = cpu_req & ~sel_nmi_vector & (sel_zram | sel_mbram| sel_chipram | sel_kickram | sel_dd | sel_rtg);
assign ramshared    = sel_dd;

// NMI
always @(posedge clk) nmi_addr <= vbr + 32'h7c;

wire sel_z3ram0 = (cpu_addr[31:27] == z3ram_base0) && z3ram_ena0;
wire sel_z3ram1 = (cpu_addr[31:28] == z3ram_base1) && z3ram_ena1;
wire sel_z2ram  = !cpu_addr[31:24] && (cpu_addr[23] ^ |cpu_addr[22:21]) && z2ram_ena; // addr[23:21] = 1..4
// BUG #94 FIX: Amiga 32-bit Memory Map - Motherboard Fast RAM
// $04000000-$07FFFFFF (64MB): Motherboard Fast RAM (Amiga specification)
// Without this mapping, addresses above $00FFFFFF wrap around to 24-bit chip space!
// This prevents the 24-bit address bus test at $04000700 from wrapping to $000700
// Only enabled on 68020/030 CPUs (cpucfg[1]=1) to maintain 24-bit compatibility for 68000/68010
wire sel_mbram = (cpu_addr[31:26] == 6'b000001) && cpucfg[1]; // $04000000-$07FFFFFF on 68020/030 only
wire sel_zram   = sel_z3ram0 | sel_z3ram1 | sel_z2ram | sel_mbram;
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
// BUG #94 FIX: Map sel_mbram ($04-$07) to DDR3 region at ramaddr $08000000-$0BFFFFFF (128MB-192MB)
assign ramaddr[28]    = sel_zram & ~sel_z3ram0 & ~sel_mbram;
assign ramaddr[27]    = sel_zram & ((sel_mbram & cpu_addr[25]) | (~sel_z3ram1 | cpu_addr[27]));
assign ramaddr[26:23] = (sel_z3ram0 | sel_z3ram1 | sel_mbram) ? cpu_addr[26:23]: (sel_rtg ? 4'b1110 : {4{sel_dd}});
assign ramaddr[22:19] = {4{sel_dd}} | cpu_addr[22:19];
assign ramaddr[18]    =    sel_dd   | (sel_kicklower & bootrom) | cpu_addr[18];
assign ramaddr[17:16] = {2{sel_dd}} | cpu_addr[17:16];
assign ramaddr[15:1]  = cpu_addr[15:1];

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

wire [15:0] cpu_din = (USE_68030_CACHE & cache_hit) ? cache_data_out_16 :
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
		chip_as      = c_as;
		chip_rw      = c_rw;
		chip_uds     = c_uds;
		chip_lds     = c_lds;
		// Address mux: PMMU walker overrides CPU address during page table walks
		if (USE_68030_CACHE && walker_active)
			chip_addr    = walker_chip_addr;
		else
			chip_addr    = cpu_addr_p[23:1];
		chip_din     = cpu_dout_p;
		chip_data    = chipdout_i;
		fastchip_sel = cpu_req & !cpu_addr_p[31:24];
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
wire        pmmu_walker_req_p;
wire [31:0] pmmu_walker_addr_p;
reg         pmmu_walker_ack_p;
reg  [31:0] pmmu_walker_data_p;

// PMMU walker address mux signals (for bus arbitration)
reg         walker_active;
wire [23:1] walker_chip_addr;

// Cache interface signals (68030 only)
wire        i_cache_enabled;
wire        d_cache_enabled;
wire        cache_hit;
wire        cache_miss;
wire        cache_cinv_req;
wire        cache_cpush_req;
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
  .clkena_in((~cpu_req | chipready | ramready | fastchip_ready | (USE_68030_CACHE & cache_hit)) & ~pmmu_walker_req_p),
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
  .cache_cinv_req(cache_cinv_req),
  .cache_cpush_req(cache_cpush_req),
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
  // PMMU walker memory interface
  .pmmu_walker_req(pmmu_walker_req_p),
  .pmmu_walker_addr(pmmu_walker_addr_p),
  .pmmu_walker_ack(pmmu_walker_ack_p),
  .pmmu_walker_data(pmmu_walker_data_p),
  // Cache operation address
  .cache_op_addr(cache_op_addr)
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
		// Cache Control Instructions
		.cinv_req(cache_cinv_req),
		.cpush_req(cache_cpush_req),
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
	assign cache_hit = (i_cache_hit & i_cache_req) | (d_cache_hit & d_cache_req);
	assign cache_miss = ((i_cache_enabled & ~i_cache_hit & i_cache_req) | (d_cache_enabled & ~d_cache_hit & d_cache_req));

	// Connect cache fill interface to external memory controller
	assign cache_req = i_fill_req | d_fill_req;
	assign cache_addr = i_fill_req ? i_fill_addr : d_fill_addr;

	// Burst mode control - request burst when IBE/DBE bits are set
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

	reg [2:0] walker_state;
	reg [15:0] walker_data_low;
	reg [31:1] walker_addr_latch;  // Latch address to hold during multi-cycle read

	localparam WALKER_IDLE       = 3'd0;
	localparam WALKER_START      = 3'd1;
	localparam WALKER_READ_LOW   = 3'd2;
	localparam WALKER_WAIT_LOW   = 3'd3;
	localparam WALKER_READ_HIGH  = 3'd4;
	localparam WALKER_WAIT_HIGH  = 3'd5;
	localparam WALKER_DONE       = 3'd6;

	// Address multiplexing: Walker overrides CPU address during active states
	// Walker addresses are byte addresses, chip_addr is word address (23:1)
	// To read 32-bit descriptor: read word at addr[23:1], then addr[23:1]+1
	wire walker_read_low_phase = (walker_state == WALKER_READ_LOW) | (walker_state == WALKER_WAIT_LOW);
	wire [23:1] walker_base_addr = walker_addr_latch[23:1];  // Byte to word address
	assign walker_chip_addr = walker_read_low_phase ?
	                          walker_base_addr :           // Low word at base address
	                          (walker_base_addr + 1'b1);   // High word at base+1

	always @(posedge clk) begin
		if (~reset) begin
			walker_state <= WALKER_IDLE;
			pmmu_walker_ack_p <= 0;
			pmmu_walker_data_p <= 0;
			walker_data_low <= 0;
			walker_addr_latch <= 0;
			walker_active <= 0;
		end else begin
			case (walker_state)
				WALKER_IDLE: begin
					pmmu_walker_ack_p <= 0;
					walker_active <= 0;
					if (pmmu_walker_req_p) begin
						// Latch walker address and start read sequence
						walker_addr_latch <= pmmu_walker_addr_p[31:1];
						walker_state <= WALKER_START;
					end
				end

				WALKER_START: begin
					// Wait one cycle for CPU to stall (clkena_in gated low)
					walker_active <= 1;  // Walker now owns the bus
					walker_state <= WALKER_READ_LOW;
				end

				WALKER_READ_LOW: begin
					// Drive walker address with LSB=0 for low word via walker_chip_addr mux
					// Memory controller sees our address
					walker_state <= WALKER_WAIT_LOW;
				end

				WALKER_WAIT_LOW: begin
					if (chipready | ramready | fastchip_ready) begin
						// Capture low 16 bits
						walker_data_low <= cpu_din;
						walker_state <= WALKER_READ_HIGH;
					end
				end

				WALKER_READ_HIGH: begin
					// Drive walker address with LSB=1 for high word via walker_chip_addr mux
					walker_state <= WALKER_WAIT_HIGH;
				end

				WALKER_WAIT_HIGH: begin
					if (chipready | ramready | fastchip_ready) begin
						// Capture high 16 bits and assemble 32-bit descriptor
						pmmu_walker_data_p <= {cpu_din, walker_data_low};
						walker_state <= WALKER_DONE;
					end
				end

				WALKER_DONE: begin
					// Acknowledge completion to PMMU
					pmmu_walker_ack_p <= 1;
					walker_active <= 0;  // Release bus
					if (~pmmu_walker_req_p) begin
						// PMMU has deasserted request, return to idle
						walker_state <= WALKER_IDLE;
					end
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

	always @(posedge clk) begin
		if (~reset) begin
			pmmu_walker_ack_p <= 0;
			walker_active <= 0;
			pmmu_walker_data_p <= 0;
		end else begin
			pmmu_walker_ack_p <= 0;
			pmmu_walker_data_p <= 0;
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
