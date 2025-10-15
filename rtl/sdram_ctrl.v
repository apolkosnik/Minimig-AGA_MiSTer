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
	// sdram (chip 1 - lower 16 bits)
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
`ifdef MISTER_DUAL_SDRAM
	// sdram2 (chip 2 - upper 16 bits)
	output reg [12:0] sd2_addr,
	output reg  [1:0] sd2_ba,
	output            sd2_cs,
	output reg        sd2_we,
	output reg        sd2_ras,
	output reg        sd2_cas,
	output reg  [1:0] sd2_dqm,
	inout  reg [15:0] sd2_data,
	output reg        sd2_clk,
`endif
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
`ifdef MISTER_DUAL_SDRAM
	input      [31:0] cpuWR,        // 32-bit CPU write data (dual SDRAM mode)
	output     [31:0] cpuRD,        // 32-bit CPU read data (dual SDRAM mode)
`else
	input      [15:0] cpuWR,        // 16-bit CPU write data (single SDRAM mode)
	output     [15:0] cpuRD,        // 16-bit CPU read data (single SDRAM mode)
`endif
	output            ramready
);

assign sd_cs = 0;
assign sd_cke = 1;

`ifdef MISTER_DUAL_SDRAM
// DUAL SDRAM mode: True 32-bit memory with two 16-bit chips
assign sd2_cs = 0;

// Split 32-bit CPU write data into two 16-bit chips
wire [15:0] cpuWR_low  = cpuWR[15:0];   // Lower 16 bits → SDRAM chip 1
wire [15:0] cpuWR_high = cpuWR[31:16];  // Upper 16 bits → SDRAM chip 2

// Combine 16-bit read data from two chips into 32-bit (BIG-ENDIAN)
// Cache now handles full 32-bit data with dual SDRAM
// Big-endian: high word at lower address goes to upper 16 bits
wire [31:0] sdr_dat_r_combined = {sdata_reg, sdata2_reg};  // Chip0=high word, Chip1=low word
wire [31:0] cpuRD_internal;
assign cpuRD = cpuRD_internal;
`else
// Single 16-bit SDRAM mode (legacy)
wire [15:0] cpuWR_low  = cpuWR;
wire [15:0] cpuRD_low;
assign cpuRD = cpuRD_low;
`endif

//// parameters ////
localparam [2:0]
	IDLE = 0,
	CHIP = 1,
	CPU_READCACHE = 2,
	CPU_WRITECACHE = 3;


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
`ifdef MISTER_DUAL_SDRAM
	.cpu_dat_w        (cpuWR),                 // cpu write data (32-bit)
	.cpu_dat_r        (cpuRD_internal),        // cpu read data (32-bit)
`else
	.cpu_dat_w        (cpuWR_low),             // cpu write data (16-bit)
	.cpu_dat_r        (cpuRD_low),             // cpu read data (16-bit)
`endif
	.cpu_ack          (cache_rd_ack),          // cpu acknowledge
	.wb_en            (cache_wr_ack),          // write enable
`ifdef MISTER_DUAL_SDRAM
	.sdr_dat_r        (sdr_dat_r_combined),    // sdram read data (32-bit)
`else
	.sdr_dat_r        (sdata_reg),             // sdram read data (16-bit)
`endif
	.sdr_read_req     (cache_req),             // sdram read request from cache
	.sdr_read_ack     (cache_fill),            // sdram read acknowledge to cache
	.snoop_act        (chipWE),                // snoop act (write only - just update existing data in cache)
	.snoop_adr        (chipAddr),              // snoop address
	.snoop_dat_w      (chipWR),                // snoop write data
	.snoop_bs         ({!chipU, !chipL})       // snoop byte selects
);

reg cache_fill;
always @ (posedge sysclk) begin
	cache_fill <= 0;

	if(init_done && slot_type == CPU_READCACHE) begin
		case(sdram_state)
		   7, 9, 11, 13: cache_fill <= 1;
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
`ifdef MISTER_DUAL_SDRAM
					writeDat  <= cpuWR[15:0];    // Lower 16 bits for write buffer (upper handled separately)
`else
					writeDat  <= cpuWR_low;      // 16-bit write buffer
`endif
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
reg [3:0] initstate;
reg       init_done;
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


//// sdram state ////
reg [3:0] sdram_state;
always @ (posedge sysclk) begin
	reg old_7m;

	sdram_state <= sdram_state + 1'd1;

	old_7m <= c_7m;
	if(~old_7m & c_7m) sdram_state <= 0;
end

//// sdram control ////

reg  [2:0] slot_type = IDLE;
`ifdef MISTER_DUAL_SDRAM
reg        chip_addr_bit1;  // Store original chipAddr[1] for address interleaving
`endif
reg [15:0] sdata_reg;
reg        chipWE;
`ifdef MISTER_DUAL_SDRAM
reg [15:0] sdata2_reg;  // Data register for second SDRAM chip
`endif

always @ (posedge sysclk) begin
	reg        cas_sd_cas;
	reg        cas_sd_we;
	reg  [1:0] cas_dqm;
	reg [15:0] datawr;
	reg  [9:0] casaddr;
	reg  [3:0] rcnt;
	
	sd_clk <= sdram_state[0];

`ifdef MISTER_DUAL_SDRAM
	// Second SDRAM chip clock (same as first)
	sd2_clk <= sdram_state[0];
`endif

	if(~sdram_state[0]) begin
		sd_ras                <= 1;
		sd_cas                <= 1;
		sd_we                 <= 1;
		sd_data               <= 16'hZZZZ;
		chipWE                <= 0;
`ifdef MISTER_DUAL_SDRAM
		// Second chip control (same as first for control signals)
		sd2_ras               <= 1;
		sd2_cas               <= 1;
		sd2_we                <= 1;
		sd2_data              <= 16'hZZZZ;
`endif
	end

	if(sdram_state[0]) sdata_reg <= sd_data;
`ifdef MISTER_DUAL_SDRAM
	if(sdram_state[0]) sdata2_reg <= sd2_data;
`endif

	if(!init_done) begin
		slot_type             <= IDLE;
		casaddr               <= 0;
		rcnt                  <= 0;
		sd_dqm                <= 3;
		sd_ba                 <= 0;
`ifdef MISTER_DUAL_SDRAM
		sd2_dqm               <= 3;
		sd2_ba                <= 0;
`endif
		if(sdram_state == 0) begin
			case(initstate)
				4 : begin // PRECHARGE
					sd_addr[10]  <= 1; // all banks
					sd_ras       <= 0;
					sd_cas       <= 1;
					sd_we        <= 0;
`ifdef MISTER_DUAL_SDRAM
					sd2_addr[10] <= 1;
					sd2_ras      <= 0;
					sd2_cas      <= 1;
					sd2_we       <= 0;
`endif
				end
				8,10 : begin // AUTOREFRESH
					sd_ras       <= 0;
					sd_cas       <= 0;
					sd_we        <= 1;
`ifdef MISTER_DUAL_SDRAM
					sd2_ras      <= 0;
					sd2_cas      <= 0;
					sd2_we       <= 1;
`endif
				end
				13 : begin // LOAD MODE REGISTER
					sd_ras       <= 0;
					sd_cas       <= 0;
					sd_we        <= 0;
					sd_addr      <= 13'b0001000100010; // CL=2, BURST=4
`ifdef MISTER_DUAL_SDRAM
					sd2_ras      <= 0;
					sd2_cas      <= 0;
					sd2_we       <= 0;
					sd2_addr     <= 13'b0001000100010; // CL=2, BURST=4
`endif
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
`ifdef MISTER_DUAL_SDRAM
				sd2_dqm         <= 3;
`endif
				slot_type       <= IDLE;

				if(~&rcnt) rcnt <= rcnt + 1'd1;

				// we give the chipset first priority
				// (this includes anything on the "motherboard" - chip RAM, slow RAM and Kickstart, turbo modes notwithstanding)
				if(~chipDMA | ~chipRW) begin
					slot_type    <= CHIP;
`ifdef MISTER_DUAL_SDRAM
					// CRITICAL INTERLEAVING for 32-bit operation:
					// Route 16-bit CHIP writes based on address LSB:
					// - Even word addresses (A[0]=0) → Chip 0 only
					// - Odd word addresses (A[0]=1) → Chip 1 only
					// Both chips addressed at chipAddr >> 1 (drop LSB)
					chip_addr_bit1 <= chipAddr[1];  // Save LSB to route write
					{sd_ba,sd_addr,casaddr[8:0]} <= chipAddr >> 1;  // Drop LSB
					{sd2_ba,sd2_addr} <= chipAddr >> 1;  // Same address
					sd_ras       <= 0;
					sd2_ras      <= 0;
`else
					{sd_ba,sd_addr,casaddr[8:0]} <= chipAddr;
					sd_ras       <= 0;
`endif
					cas_dqm      <= {chipU,chipL};
					cas_sd_cas   <= 0;
					cas_sd_we    <= chipRW;
					datawr       <= chipWR;
					chipWE       <= !chipRW;
				end
				else if(write_req) begin
					slot_type    <= CPU_WRITECACHE;
`ifdef MISTER_DUAL_SDRAM
					// CPU writes with INTERLEAVING:
					// Both chips write at writeAddr >> 1 (drop LSB)
					// Chip 0 writes HIGH word, Chip 1 writes LOW word
					{sd_ba,sd_addr,casaddr[8:0]} <= writeAddr >> 1;              // Chip 0: addr >> 1
					{sd2_ba,sd2_addr} <= writeAddr >> 1;                         // Chip 1: addr >> 1
					sd_ras       <= 0;
					sd2_ras      <= 0;
`else
					{sd_ba,sd_addr,casaddr[8:0]} <= writeAddr;
					sd_ras       <= 0;
`endif
					cas_dqm      <= write_dqm;
					cas_sd_we    <= 0;
					cas_sd_cas   <= 0;
					write_ack    <= 1; // let the write buffer know we're about to write
					datawr       <= writeDat;
				end
				// request from read cache
				else if(cache_req) begin
					slot_type    <= CPU_READCACHE;
`ifdef MISTER_DUAL_SDRAM
					// CPU reads with INTERLEAVING:
					// Both chips read from cpuAddr >> 1 (drop LSB)
					// Chip 0 has even words (HIGH), Chip 1 has odd words (LOW)
					{sd_ba,sd_addr,casaddr[8:0]} <= cpuAddr >> 1;               // Chip 0: addr >> 1
					{sd2_ba,sd2_addr} <= cpuAddr >> 1;                          // Chip 1: addr >> 1
					sd_ras       <= 0;
					sd2_ras      <= 0;
`else
					{sd_ba,sd_addr,casaddr[8:0]} <= cpuAddr;
					sd_ras       <= 0;
`endif
					cas_sd_cas   <= 0;
				end
				else if(&rcnt) begin
					// REFRESH
					sd_ras       <= 0;
					sd_cas       <= 0;
					rcnt         <= 0;
`ifdef MISTER_DUAL_SDRAM
					sd2_ras      <= 0;
					sd2_cas      <= 0;
`endif
				end
			end

			// CAS
			2 : begin
				sd_addr         <= {1'b1, casaddr}; // AUTO PRECHARGE
				sd_cas          <= cas_sd_cas;
				sd_dqm          <= 0;
				if(!cas_sd_we) begin
`ifdef MISTER_DUAL_SDRAM
					// Data routing:
					// For CHIP: write to Chip 0 only if even word address (A[1]=0)
					// For CPU: cpuWR_high goes to Chip 0
					sd_data      <= (slot_type == CHIP) ? datawr : cpuWR_high;
					// Mask Chip 0 if CHIP write to odd address
					sd_dqm       <= (slot_type == CHIP && chip_addr_bit1) ? 2'b11 : cas_dqm;
`else
					sd_data      <= datawr;
					sd_dqm       <= cas_dqm;
`endif
					sd_addr[12:11]<= cas_dqm;
					sd_we        <= 0;
				end
				write_ack       <= 0; // indicate to write that it's safe to accept the next write
`ifdef MISTER_DUAL_SDRAM
				// Second chip CAS cycle
				sd2_addr        <= {1'b1, casaddr}; // AUTO PRECHARGE
				sd2_cas         <= cas_sd_cas;
				sd2_dqm         <= 0;
				if(!cas_sd_we) begin
					// CRITICAL INTERLEAVING + CPU 32-bit:
					// For CHIP writes: write to Chip 1 only if odd word address (A[1]=1)
					// For CPU writes: split 32-bit data (HIGH→Chip0, LOW→Chip1)
					if (slot_type == CHIP) begin
						sd2_data     <= datawr;  // CHIP: same data
						sd2_dqm      <= chip_addr_bit1 ? cas_dqm : 2'b11;  // Write only if A[1]=1 (odd)
						sd2_we       <= 0;
					end else begin
						sd2_data     <= cpuWR_low;  // CPU: lower 16 bits go to Chip 1
						sd2_dqm      <= cas_dqm;
						sd2_we       <= 0;
					end
					sd2_addr[12:11]<= cas_dqm;
				end
`endif
			end
		endcase
	end
end

endmodule
