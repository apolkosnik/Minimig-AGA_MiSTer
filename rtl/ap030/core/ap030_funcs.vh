// AP68030 core - helper functions (included by ap030_core.v at module level)

// rotates for register bit fields
function [31:0] rotl32; input [31:0] v; input [4:0] n;
	begin rotl32 = (v << n) | (v >> (6'd32 - {1'b0, n})); if (n == 0) rotl32 = v; end endfunction
function [31:0] rotr32; input [31:0] v; input [4:0] n;
	begin rotr32 = (v >> n) | (v << (6'd32 - {1'b0, n})); if (n == 0) rotr32 = v; end endfunction

// mask of the top w bits (w = 1..32)
function [31:0] topmask; input [5:0] w;
	begin topmask = (w >= 6'd32) ? 32'hFFFFFFFF : ~(32'hFFFFFFFF >> w); end endfunction

// leading zeros of a w-bit field held in the low bits of v (returns w when zero)
function [5:0] field_lz; input [31:0] v; input [5:0] w;
	integer i; reg found;
	begin
		field_lz = w; found = 1'b0;
		for (i = 31; i >= 0; i = i - 1) begin
			if (!found && (i < w) && v[i]) begin field_lz = w - 6'd1 - i[5:0]; found = 1'b1; end
		end
	end
endfunction

// MOVEM: the next register to move (lowest set bit ascending, highest descending)
function [3:0] mm_next; input [15:0] m; input desc;
	integer i;
	begin
		mm_next = 4'd0;
		if (desc) begin for (i = 0; i < 16; i = i + 1) if (m[i]) mm_next = i[3:0]; end
		else begin for (i = 15; i >= 0; i = i - 1) if (m[i]) mm_next = i[3:0]; end
	end
endfunction

function [4:0] popcount16; input [15:0] m;
	integer i;
	begin popcount16 = 5'd0; for (i = 0; i < 16; i = i + 1) popcount16 = popcount16 + {4'd0, m[i]}; end
endfunction

// transfer size code for 1..4 bytes
function [1:0] sz_of_bytes; input [2:0] n;
	begin
		case (n)
			3'd1: sz_of_bytes = `SZ_B;
			3'd2: sz_of_bytes = `SZ_W;
			3'd3: sz_of_bytes = `SZ_3;
			default: sz_of_bytes = `SZ_L;
		endcase
	end
endfunction
function [2:0] bytes_of_sz; input [1:0] s;
	begin
		case (s)
			`SZ_B: bytes_of_sz = 3'd1;
			`SZ_W: bytes_of_sz = 3'd2;
			`SZ_3: bytes_of_sz = 3'd3;
			default: bytes_of_sz = 3'd4;
		endcase
	end
endfunction
// SSW SIZE field (SIZ encoding) to the internal size code
function [1:0] sz_of_siz; input [1:0] siz;
	begin
		case (siz)
			`SIZ_BYTE: sz_of_siz = `SZ_B;
			`SIZ_WORD: sz_of_siz = `SZ_W;
			`SIZ_3BYTE: sz_of_siz = `SZ_3;
			default: sz_of_siz = `SZ_L;
		endcase
	end
endfunction

// bit field extraction from a 40-bit memory image (bit 39 = first byte MSB)
function [31:0] bf_extract40; input [39:0] d; input [2:0] boff; input [5:0] w;
	reg [39:0] sh;
	begin
		sh = d << boff;
		bf_extract40 = sh[39:8] >> (6'd32 - w);
		if (w >= 6'd32) bf_extract40 = sh[39:8];
	end
endfunction
function [39:0] bf_insert40; input [39:0] d; input [2:0] boff; input [5:0] w; input [31:0] v;
	reg [39:0] mask, val;
	reg [6:0] sh;
	begin
		sh = 7'd40 - {4'd0, boff} - {1'b0, w};
		mask = (w >= 6'd32) ? 40'hFFFFFFFF : ((40'd1 << w) - 40'd1);
		val  = {8'd0, v} & mask;
		bf_insert40 = (d & ~(mask << sh)) | (val << sh);
	end
endfunction

// MMU instruction function code field (PRM PFLUSH/PLOAD/PTEST): 10xxx immediate,
// 01ddd Dn, 00000 SFC, 00001 DFC; the caller supplies Dn
function [2:0] mmu_fc; input [4:0] f; input [2:0] dn;
	begin
		if (f[4]) mmu_fc = f[2:0];
		else if (f[3]) mmu_fc = dn;
		else if (f[0]) mmu_fc = dfc;
		else mmu_fc = sfc;
	end
endfunction
function mmu_fc_ok; input [4:0] f;
	begin mmu_fc_ok = f[4] || (f[3] && !f[4]) || (f[4:1] == 4'd0); end endfunction

// coprocessor "valid EA" categories (UM Table 10-4) against dw[5:0]
function cp_ea_ok; input [2:0] cat;
	begin
		case (cat)
			3'b000: cp_ea_ok = ea_ctrlalt;
			3'b001: cp_ea_ok = ea_dataalt;
			3'b010: cp_ea_ok = ea_memalt;
			3'b011: cp_ea_ok = ea_alt;
			3'b100: cp_ea_ok = ea_ctrl;
			3'b101: cp_ea_ok = ea_data;
			3'b110: cp_ea_ok = ea_mem;
			default: cp_ea_ok = ea_any;
		endcase
	end
endfunction
