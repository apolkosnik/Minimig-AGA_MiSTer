// This module interfaces Minimig's synchronous bus to the 68SEC000 CPU
// Modified for 32-bit wide bus support with dual SDRAM
//
// cycle exact CIA interface:
// ECLK low for 6 cycles and high for 4
// data latched with falling edge of ECLK
// VPA sampled 3 CLKs before rising edge of ECLK
// VMA asserted one clock later if VPA recognized
// DTACK sampled one clock before ECLK falling edge
//
//             ___     ___     ___     ___     ___     ___     ___     ___     ___     ___     ___
// CLK     ___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___
//         ___     ___     ___     ___     ___     ___     ___     ___     ___     ___     ___     ___
// CPU_CLK    \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/
//         ___ _______ _______ _______ _______ _______ _______ _______ _______ _______ _______ _______
//         ___X___0___X___1___X___2___X___3___X___4___X___5___X___6___X___7___X___8___X___9___X___0___
//         ___                                                 _______________________________
// ECLK       \_______________________________________________/                               \_______
//                                    |       |_VMA_asserted                          
//                                    |_VPA_sampled                   _______________           ______
//                                                                            \\\\\\\\_________/       DTACK asserted (7MHz)
//                                                                                    |__DTACK_sampled (7MHz) 
//                                                                    _____________________     ______
//                                                                                         \___/       DTACK asserted (28MHz)
//                                                                                          |__DTACK_sampled (28MHz)
//
// NOTE: in 28MHz mode this timing model is not (yet?) supported, CPU talks to CIAs with no waitstates
//


module minimig_m68k_bridge
(
	input	        clk,           // 28 MHz system clock
	input         clk7_en,
	input         clk7n_en,
	input	        c1,            // clock enable signal
	input	        c3,            // clock enable signal
	input	  [9:0] eclk,          // ECLK enable signal
	input	        vpa,           // valid peripheral address (CIAs)
	input	        dbr,           // data bus request, Gary keeps CPU off the bus (custom chips transfer data)
	input	        dbs,           // data bus slowdown (access to chip ram or custom registers)
	input	        xbs,           // cross bridge access (active dbr holds off CPU access)
	input         nrdy,          // target device is not ready
	output        bls,           // blitter slowdown, tells the blitter that CPU wants the bus
	input	        cck,           // colour clock enable, active when dma can access the memory bus
	input   [3:0] memory_config, // system memory config
	input	        _as,           // m68k adress strobe
	input	        _lds,          // m68k lower data strobe d0-d7
	input	        _uds,          // m68k upper data strobe d8-d15
	input   [3:0] _be,           // 4-byte enables (active-low): BE3(31:24), BE2(23:16), BE1(15:8), BE0(7:0)
	input	        r_w,           // m68k read / write
	output        _dtack,        // m68k data acknowledge to cpu
	output        rd,            // bus read
	output        hwr,           // bus high write (bits 15:8) - legacy
	output        lwr,           // bus low write (bits 7:0) - legacy
	output        byte3_wr,      // byte 3 write (bits 31:24) - NEW 32-bit support
	output        byte2_wr,      // byte 2 write (bits 23:16) - NEW 32-bit support
	output        byte1_wr,      // byte 1 write (bits 15:8)
	output        byte0_wr,      // byte 0 write (bits 7:0)
	input	 [31:1] address,       // external cpu address bus (expanded to 32-bit)
	output [31:1] address_out,   // internal cpu address bus output (expanded to 32-bit)
	output [31:0] data,          // external cpu data bus
	input  [31:0] cpudatain,
	output [31:0] data_out,      // internal data bus output
	input  [31:0] data_in,       // internal data bus input
	output        rd_cyc,        // early rd signal can be used to delay DTACK

	// UserIO interface
    input         _cpu_reset,
    input         cpu_halt,
    input         host_cs,
    input  [31:1] host_adr,
    input         host_we,
    input   [3:0] host_bs,
    input  [31:0] host_wdat,
    output [31:0] host_rdat,
    output        host_ack
);

/*
68000 bus timing diagram

          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
        7 . 0 . 1 . 2 . 3 . 4 . 5 . 6 . 7 . 0 . 1 . 2 . 3 . 4 . 5 . 6 . 7 . 0 . 1
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
           ___     ___     ___     ___     ___     ___     ___     ___     ___
CLK    ___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___/   \___
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
       _____________________________________________                         _____		  
R/W                 \_ _ _ _ _ _ _ _ _ _ _ _/       \_______________________/     
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
       _________ _______________________________ _______________________________ _		  
ADDR   _________X_______________________________X_______________________________X_
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
       _____________                     ___________                     _________
/AS                 \___________________/           \___________________/         
          .....   .   .   .       .   .   .....   .   .   .   .       .   .....
       _____________        READ         ___________________    WRITE    _________
/DS                 \___________________/                   \___________/         
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
       _____________________     ___________________________     _________________
/DTACK                      \___/                           \___/                 
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
                                     ___
DIN    -----------------------------<___>-----------------------------------------
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
                                                         ___________________
DOUT   -------------------------------------------------<___________________>-----
          .....   .   .   .   .   .   .   .....   .   .   .   .   .   .   .....
*/

// halt is enabled when halt request comes in and cpu bus is idle
reg halt=0;
always @ (posedge clk) begin
	if (clk7_en) begin
		if (_as && cpu_halt) halt <= #1 1'b1;
		else if (_as && !cpu_halt) halt <= #1 1'b0;
	end
end

//latched valid peripheral address
reg lvpa; // latched valid peripheral address (CIAs)
always @(posedge clk) if (clk7_en) lvpa <= vpa;

//vma output
reg vma; // valid memory address (synchronised VPA with ECLK)
always @(posedge clk) begin
	if (clk7_en) begin
		if (eclk[9]) vma <= 0;
		else if (eclk[3] && lvpa) vma <= 1;
	end
end

//latched CPU bus control signals
reg lr_w,l_as,l_dtack; // synchronised inputs
always @ (posedge clk) begin
	if (clk7_en) begin
		lr_w <= !halt ? r_w : !host_we;
		l_as <= !halt ? _as : !host_cs;
		l_dtack <= _dtack;
	end
end

// Latch all 4 byte enables for true 32-bit support
reg l_uds,l_lds,l_uws,l_lws;
reg [3:0] l_be;  // Latched 4-byte enables
always @(posedge clk) begin
  // Legacy 16-bit strobes (for backward compatibility)
  l_uds <= !halt ? _uds : !(host_bs[1]); // Upper data strobe (bits 15:8)
  l_lds <= !halt ? _lds : !(host_bs[0]); // Lower data strobe (bits 7:0)
  l_uws <= !halt ? _uds : !(host_bs[1]); // Upper word strobe (bits 15:8)
  l_lws <= !halt ? _lds : !(host_bs[0]); // Lower word strobe (bits 7:0)

  // NEW: Latch all 4 byte enables (active-low)
  l_be <= !halt ? _be : ~host_bs;  // BE3(31:24), BE2(23:16), BE1(15:8), BE0(7:0)
end

wire _as_and_cs = !halt ? _as : !host_cs;

// data transfer acknowledge in normal mode (original timing, reliable for CIAs/Paula)
reg _ta_n; // transfer acknowledge
always @(posedge clk or posedge _as_and_cs) begin
	if (_as_and_cs) _ta_n <= 1;
	else if (clk7n_en) begin
		// Assert DTACK only when color clock window is open and target is ready
		if (!l_as && cck && ((!vpa && !(dbr && dbs)) || (vpa && vma && eclk[8])) && !nrdy) _ta_n <= 0;
	end
end

assign host_ack = !_ta_n;
assign _dtack   = _ta_n;

// synchronous control signals
wire   enable = ~l_as & ~l_dtack & ~cck;
assign rd = enable & lr_w;

// TRUE 32-BIT WRITE STROBES: Generate 4 independent byte write signals
assign byte3_wr = enable & ~lr_w & ~l_be[3];  // Byte 3 write (bits 31:24)
assign byte2_wr = enable & ~lr_w & ~l_be[2];  // Byte 2 write (bits 23:16)
assign byte1_wr = enable & ~lr_w & ~l_be[1];  // Byte 1 write (bits 15:8)
assign byte0_wr = enable & ~lr_w & ~l_be[0];  // Byte 0 write (bits 7:0)

// Legacy 16-bit write strobes (for backward compatibility with old code)
assign hwr = enable & ~lr_w & (~l_uds | ~l_uws);  // DEPRECATED: Use byte1_wr instead
assign lwr = enable & ~lr_w & (~l_lds | ~l_lws);  // DEPRECATED: Use byte0_wr instead

assign rd_cyc = ~l_as & lr_w;

//blitter slow down signalling, asserted whenever CPU is missing bus access to chip ram, slow ram and custom registers 
assign bls = dbs & ~l_as & l_dtack;

reg [31:0] cpudatain_r;
always @(posedge clk) cpudatain_r <= cpudatain;

// data_out multiplexer and latch   
assign data_out = !halt ? cpudatain_r : host_wdat;

reg [31:0] ldata_in;	// latched data_in
always @(posedge clk) if (!c1 && c3 && enable) ldata_in <= data_in;

// --------------------------------------------------------------------------------------

// CPU data bus tristate buffers and output data multiplexer
assign data[31:0] = ldata_in;
assign host_rdat  = ldata_in;

reg [31:1] address_r;
always @(posedge clk) address_r <= address;

assign address_out[31:1] = !halt ? address_r : {host_adr[31:1]};

endmodule
