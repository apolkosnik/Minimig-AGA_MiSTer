//This module maps physical 512KB blocks of every memory chip to different memory ranges in Amiga
//
// Since we currently have 8M for non-fastram, this was simplified to
// use the full address for mapping.  We only use this part to signal
// that ram access should occur and to emulate the mirroring behaviour
// of the lower 2M when less than 2M chipram is selected. Moreover we
// use sel_kick downstream, because there is no boot overlay
// information in the address alone.

module minimig_bankmapper
(
	input        chip0,          // chip ram select: 1st 512 KB block
	input        chip1,          // chip ram select: 2nd 512 KB block
	input        chip2,          // chip ram select: 3rd 512 KB block
	input        chip3,          // chip ram select: 4th 512 KB block
	input        chip4,          // chip ram select: 5th 512 KB block
	input        chip5,          // chip ram select: 6th 512 KB block
	input        chip6,          // chip ram select: 7th 512 KB block
	input        chip7,          // chip ram select: 8th 512 KB block
	input        chip8,          // chip ram select: 9th 512 KB block
	input        chip9,          // chip ram select: 10th 512 KB block
	input        chip10,         // chip ram select: 11th 512 KB block
	input        chip11,         // chip ram select: 12th 512 KB block
	input        chip12,         // chip ram select: 13th 512 KB block
	input        chip13,         // chip ram select: 14th 512 KB block
	input        chip14,         // chip ram select: 15th 512 KB block
	input        chip15,         // chip ram select: 16th 512 KB block
	input        slow0,          // slow ram select: 1st 512 KB block
	input        slow1,          // slow ram select: 2nd 512 KB block
	input        slow2,          // slow ram select: 3rd 512 KB block
	input        kick,           // Kickstart ROM address range select
	input        kick1mb,        // 1MB Kickstart 'upper' half
	input        kick256kmirror, // mirror f8-fb to fc-ff in a1k mode
	input        cart,           // Action Reply memory range select
	input        chip8mb,        // 8MB ChipRAM mode enable (AGA only)
	input  [1:0] memory_config,  // memory configuration (bits [1:0] for 0.5-2MB modes)
	output [7:0] bank            // bank select
);

assign bank = bank_r;

reg [7:0] bank_r;

wire chip_any;
assign chip_any = chip15 | chip14 | chip13 | chip12 | chip11 | chip10 | chip9 | chip8 | chip7 | chip6 | chip5 | chip4 | chip3 | chip2 | chip1 | chip0;

always @(*) begin
	if (chip8mb) begin
		// 8MB mode: no mirroring, all 16 banks mapped directly
		bank_r[7:4] = { kick, kick256kmirror, chip_any, kick1mb | slow0 | slow1 | slow2 | cart };
		bank_r[3:0] = { chip15 | chip14 | chip13 | chip12,
		                chip11 | chip10 | chip9  | chip8,
		                chip7  | chip6  | chip5  | chip4,
		                chip3  | chip2  | chip1  | chip0 };
	end else begin
		// 2MB mode: original mirroring behavior for 0.5-2MB configurations
		bank_r[7:4] = { kick, kick256kmirror, chip3 | chip2 | chip1 | chip0, kick1mb | slow0 | slow1 | slow2 | cart };
		case (memory_config)
			0: bank_r[3:0] = {    1'b0,  1'b0,          1'b0, chip3 | chip2 | chip1 | chip0 }; // 0.5M CHIP
			1: bank_r[3:0] = {    1'b0,  1'b0, chip3 | chip1,                 chip2 | chip0 }; // 1.0M CHIP
			2: bank_r[3:0] = {    1'b0, chip2,         chip1,                         chip0 }; // 1.5M CHIP
			3: bank_r[3:0] = {   chip3, chip2,         chip1,                         chip0 }; // 2.0M CHIP
		endcase
	end
end

endmodule

