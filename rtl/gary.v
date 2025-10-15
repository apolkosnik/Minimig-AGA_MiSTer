// Copyright 2006, 2007 Dennis van Weeren
//
// This file is part of Minimig
//
// Minimig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// Minimig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
//
//
// This is Gary
// It is the equivalent of Gary in a real Amiga
// Gary handles the address decoding and cpu/chip bus multiplexing
// Gary handles kickstart area and bootrom overlay
// Gary handles CIA e clock synchronization
//
// 20-12-2005	- started coding
// 21-12-2005	- done more coding
// 25-12-2005	- changed blitter nasty handling
// 15-01-2006	- fixed sensitivity list
// 12-11-2006	- debugging for new Minimig rev1.0 board
// 17-11-2006	- removed debugging and added decode for $C0000 ram
// ----------
// JB:
// 2008-10-06	- added decoders for IDE and GAYLE register range
// 2008-10-15	- signal name change cpuok -> dbr
// 2009-05-23	- better timing model for CIA interface
// 2009-05-24	- clean-up & renaming
// 2009-05-25	- ram, cpu and custom chips bus multiplexer
// 2009-09-01	- fixed sel_kick
// 2010-08-15	- clean-up
//
// SB:
// 2010-10-18 - added special memory config like in A500 Rev.6 with 512kb + 512kb of memory
//
// AMR:
// 2012-03-23  - Added select for Akiko


module gary
(
	input  [31:1] cpu_address_in, //cpu address bus input (expanded to 32-bit)
	input  [20:1] dma_address_in, //agnus dma memory address input
	output [31:1] ram_address_out, //full ram address output (expanded to 32-bit)
	input  [31:0] cpu_data_out,
	output [31:0] cpu_data_in,
	input  [15:0] custom_data_out,
	output [15:0] custom_data_in,
	input  [31:0] ram_data_out,
	output [31:0] ram_data_in,
	input         a1k,
	input         bootrom, // do the A1000 bootrom magic 		 
	input         clk,
	input         reset, //global reset signal
	input         cpu_rd, //cpu read
	input         cpu_hwr, //cpu high write (legacy, bits 15:8)
	input         cpu_lwr, //cpu low write (legacy, bits 7:0)
	input         cpu_byte3_wr, //cpu byte 3 write (bits 31:24) - NEW 32-bit
	input         cpu_byte2_wr, //cpu byte 2 write (bits 23:16) - NEW 32-bit
	input         cpu_byte1_wr, //cpu byte 1 write (bits 15:8) - NEW 32-bit
	input         cpu_byte0_wr, //cpu byte 0 write (bits 7:0) - NEW 32-bit
	input         cpu_hlt,

	input         ovl, //overlay kickstart rom over chipram
	input         dbr, //Agns takes the bus
	input         dbwe, //Agnus does a write cycle
	output        dbs, //data bus slow down
	output        xbs, //cross bridge select, active dbr prevents access

	input   [3:0] memory_config, //selected memory configuration
	input         ecs, // ECS chipset enable
	input         hdc_ena, //enables hdd interface

	input         toccata_ena,
	input   [7:0] toccata_base,

	output        ram_rd, //bus read
	output        ram_hwr, //bus high write (legacy, bits 15:8)
	output        ram_lwr, //bus low write (legacy, bits 7:0)
	output        ram_byte3_wr, //ram byte 3 write (bits 31:24) - NEW 32-bit
	output        ram_byte2_wr, //ram byte 2 write (bits 23:16) - NEW 32-bit
	output        ram_byte1_wr, //ram byte 1 write (bits 15:8) - NEW 32-bit
	output        ram_byte0_wr, //ram byte 0 write (bits 7:0) - NEW 32-bit

	output        sel_reg, //select chip register bank
	output reg [3:0] sel_chip, //select chip memory
	output reg [2:0] sel_slow, //select slowfast memory ($C0000)
	output reg   sel_kick, //select kickstart rom
	output reg   sel_kick1mb, // 1MB kickstart rom 'upper' half
	output reg   sel_kick256kmirror, //mirror $fc-$ff to $f8, when rom_readonly and bootrom 
	output       sel_cia, //select CIA space
	output       sel_cia_a, //select cia A
	output       sel_cia_b, //select cia B
	output       sel_rtg, //select rtg
	output       sel_rtc, //select $DCxxxx
	output       sel_ide, //select $DAxxxx
	output       sel_gayle, //select $DExxxx
	output       sel_toccata, //select $E9xxxx (or whatever's specified by toccata_base)
	output reg   rom_readonly = 0 //when zero allows to write to $fc-$ff, blocks effect of kick256kmirror.  
);

wire	[2:0] t_sel_slow;
wire	sel_xram;
wire	sel_bank_1; 				// $200000-$3FFFFF
 

//--------------------------------------------------------------------------------------

assign ram_data_in    = dbr ? {16'h0000, custom_data_out} : cpu_data_out;
`ifdef MINIMIG_32BIT_BUSES
assign custom_data_in = dbr ? ram_data_out[15:0] : cpu_rd ? 16'hFFFF : cpu_data_out[15:0];
`else
assign custom_data_in = dbr ? ram_data_out[15:0] : cpu_rd ? 16'hFFFF : cpu_data_out[15:0];
`endif
assign cpu_data_in    = dbr ? 32'h00000000 : {16'h0000, custom_data_out} | ram_data_out | {32{sel_bank_1}};

//read write control signals
assign ram_rd  = dbr ? ~dbwe : cpu_rd;

// Legacy 16-bit write strobes (for backward compatibility)
assign ram_hwr = dbr ?  dbwe : cpu_hwr;
assign ram_lwr = dbr ?  dbwe : cpu_lwr;

// TRUE 32-BIT: Pass through all 4 byte write enables
// When DMA is active (dbr=1), Agnus drives both bytes for 16-bit transfers
// When CPU is active (dbr=0), pass through individual byte enables
assign ram_byte3_wr = dbr ? 1'b0      : cpu_byte3_wr;  // Byte 3 (bits 31:24)
assign ram_byte2_wr = dbr ? 1'b0      : cpu_byte2_wr;  // Byte 2 (bits 23:16)
assign ram_byte1_wr = dbr ? dbwe      : cpu_byte1_wr;  // Byte 1 (bits 15:8) - DMA uses this
assign ram_byte0_wr = dbr ? dbwe      : cpu_byte0_wr;  // Byte 0 (bits 7:0) - DMA uses this

//--------------------------------------------------------------------------------------

// ram address multiplexer - 32-bit CPU address support
// DMA addresses stay 20-bit (original Amiga), CPU addresses expanded to 32-bit
assign ram_address_out  = dbr ? {11'b00000000000, dma_address_in[20:1]} : cpu_address_in[31:1];
   
   
//--------------------------------------------------------------------------------------

always @ (posedge clk) begin
	if (reset) rom_readonly <= ~bootrom;
	else if ((cpu_hwr || cpu_lwr) && (cpu_address_in[23:18]==6'b1111_10)) rom_readonly <= 1;
end

   
// 32-bit address space check - only allow chip access in original 24-bit space ($00000000-$00FFFFFF)
wire chip_space_32bit = (cpu_address_in[31:24] == 8'h00);

//chipram, kickstart and bootrom address decode
always @(*)
begin
	if (dbr)//agnus only accesses chipram
	begin
		sel_chip[0] = ~dma_address_in[20] & ~dma_address_in[19];
		sel_chip[1] = ~dma_address_in[20] &  dma_address_in[19];
		sel_chip[2] =  dma_address_in[20] & ~dma_address_in[19];
		sel_chip[3] =  dma_address_in[20] &  dma_address_in[19];
		sel_slow[0] =  ecs && memory_config==4'b0100 && dma_address_in[20:19]==2'b01; //use slow0 as chipmem, when only chip0 and slow0 are enabled.
		sel_slow[1] = 0;
		sel_slow[2] = 0;
	   sel_kick    = 0;
	   sel_kick1mb = 0;
	   sel_kick256kmirror = 0;
	end
	else
	begin
		// 32-bit addressing: only select chip resources when in 24-bit compatible space
		sel_chip[0] = chip_space_32bit && cpu_address_in[23:19]==5'b0000_0 && (!ovl || cpu_hlt);
		sel_chip[1] = chip_space_32bit && cpu_address_in[23:19]==5'b0000_1;
		sel_chip[2] = chip_space_32bit && cpu_address_in[23:19]==5'b0001_0;
		sel_chip[3] = chip_space_32bit && cpu_address_in[23:19]==5'b0001_1;
		sel_slow[0] = chip_space_32bit && t_sel_slow[0];
		sel_slow[1] = chip_space_32bit && t_sel_slow[1];
		sel_slow[2] = chip_space_32bit && t_sel_slow[2];
		sel_kick    = chip_space_32bit && ((cpu_address_in[23:19]==5'b1111_1 && (cpu_rd || cpu_hlt || (!rom_readonly && cpu_address_in[18])))  || (cpu_rd && ovl && cpu_address_in[23:19]==5'b0000_0)); //$F80000 - $FFFFFF
		sel_kick1mb = chip_space_32bit && cpu_address_in[23:19]==5'b1110_0 && (cpu_rd || cpu_hlt); // $E00000 - $E7FFFF
		sel_kick256kmirror = chip_space_32bit && cpu_address_in[23:19]==5'b1111_1 &&  cpu_rd && rom_readonly && !cpu_hlt && bootrom;
	end
end

assign t_sel_slow[0] = (cpu_address_in[31:19]==13'b0000_0000_1100_0) && |memory_config[3:2]; //$C00000 - $C7FFFF
assign t_sel_slow[1] = (cpu_address_in[31:19]==13'b0000_0000_1100_1) &&  memory_config[3];   //$C80000 - $CFFFFF
assign t_sel_slow[2] = (cpu_address_in[31:19]==13'b0000_0000_1101_0) && &memory_config[3:2]; //$D00000 - $D7FFFF

// 32-bit addressing: chip selectors only active in 24-bit compatible space
assign sel_ide   = chip_space_32bit && hdc_ena && cpu_address_in[31:16]==16'b0000_0000_1101_1010;        //IDE registers at $DA0000 - $DAFFFF
assign sel_gayle = chip_space_32bit && hdc_ena && cpu_address_in[31:12]==20'b0000_0000_1101_1110_0001;  //GAYLE registers at $DE1000 - $DE1FFF
assign sel_rtc   = chip_space_32bit && cpu_address_in[31:16]==16'b000_0000_1101_1100;                   //RTC registers at $DC0000 - $DCFFFF
assign sel_reg   = chip_space_32bit && cpu_address_in[31:21]==11'b0000_0000_110 ? ~(|t_sel_slow | sel_rtc | sel_ide | sel_gayle) : 1'b0;	//chip registers at $DF0000 - $DFFFFF
assign sel_cia   = chip_space_32bit && cpu_address_in[31:16]==8'h00BF; // $BFxxxx
assign sel_cia_a = sel_cia & ~cpu_address_in[12];
assign sel_cia_b = sel_cia & ~cpu_address_in[13];
assign sel_rtg   = chip_space_32bit && cpu_address_in[31:16]==8'h00B8; // $B8xxxxx
assign sel_bank_1 = chip_space_32bit && cpu_address_in[31:21]==11'b0000_0000_001;

assign sel_toccata = chip_space_32bit && toccata_ena && cpu_address_in[23:16]==toccata_base; // Nominally $e9xxxx

//data bus slow down - only apply in 24-bit compatible space
assign dbs = chip_space_32bit && (cpu_address_in[31:21]==3'b0000_0000_000 || cpu_address_in[31:20]==12'b0000_0000_1100 || cpu_address_in[31:19]==13'b0000_0000_1101_0 || cpu_address_in[31:16]==16'b0000_0000_1101_1111);
assign xbs = ~(sel_cia | sel_gayle | sel_ide);

endmodule
