// AP68020 core - helper functions (included by ap020_core.v at module level)

// rotates for register bit fields
// mask of the top w bits (w = 1..32)
function [31:0] topmask; input [5:0] w;
	begin topmask = (w >= 6'd32) ? 32'hFFFFFFFF : ~(32'hFFFFFFFF >> w); end endfunction

// leading zeros of v (32 when v is zero)
function [5:0] lz32; input [31:0] v;
	integer i; reg found;
	begin
		lz32 = 6'd32; found = 1'b0;
		for (i = 31; i >= 0; i = i - 1) begin
			if (!found && v[i]) begin lz32 = 6'd31 - i[5:0]; found = 1'b1; end
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

// bit fields in memory: the nb bytes read (1..5) as a 40-bit image with the
// first byte at bit 39 (four in d, the fifth in the low byte of e)
function [39:0] bf_image; input [31:0] d; input [7:0] e; input [2:0] nb;
	begin bf_image = (nb == 3'd5) ? {d, e} : ({d, 8'd0} << (8 * (3'd4 - nb))); end endfunction

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
