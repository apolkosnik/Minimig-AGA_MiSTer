------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Package - MC68040 Specific Definitions                          --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- This package extends TG68K_Pack with MC68040-specific definitions including:
-- - 68040 control registers (CACR, TC, ITT0/1, DTT0/1, etc.)
-- - Cache control structures
-- - MMU structures
-- - FPU structures
-- - Pipeline control types
--
-- Version: 0.1 (Phase 1 - Foundation)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package TG68040_Pack is

	------------------------------------------------------------------------------
	-- CPU Mode Constants
	------------------------------------------------------------------------------
	-- Extends TG68K CPU modes:
	-- "00" -> 68000
	-- "01" -> 68010
	-- "11" -> 68020
	-- "10" -> 68040 (NEW)
	------------------------------------------------------------------------------
	constant CPU_68000 : std_logic_vector(1 downto 0) := "00";
	constant CPU_68010 : std_logic_vector(1 downto 0) := "01";
	constant CPU_68020 : std_logic_vector(1 downto 0) := "11";
	constant CPU_68040 : std_logic_vector(1 downto 0) := "10";

	------------------------------------------------------------------------------
	-- MC68040 Control Register Addresses (for MOVEC instruction)
	------------------------------------------------------------------------------
	-- Standard registers (from 68020, also in 68040):
	constant MOVEC_SFC    : std_logic_vector(11 downto 0) := x"000"; -- Source Function Code
	constant MOVEC_DFC    : std_logic_vector(11 downto 0) := x"001"; -- Destination Function Code
	constant MOVEC_USP    : std_logic_vector(11 downto 0) := x"800"; -- User Stack Pointer
	constant MOVEC_VBR    : std_logic_vector(11 downto 0) := x"801"; -- Vector Base Register
	constant MOVEC_CACR   : std_logic_vector(11 downto 0) := x"002"; -- Cache Control Register
	constant MOVEC_CAAR   : std_logic_vector(11 downto 0) := x"802"; -- Cache Address Register (68020)
	constant MOVEC_MSP    : std_logic_vector(11 downto 0) := x"803"; -- Master Stack Pointer
	constant MOVEC_ISP    : std_logic_vector(11 downto 0) := x"804"; -- Interrupt Stack Pointer

	-- MC68040 specific registers:
	constant MOVEC_TC     : std_logic_vector(11 downto 0) := x"003"; -- Translation Control
	constant MOVEC_ITT0   : std_logic_vector(11 downto 0) := x"004"; -- Instruction Transparent Translation 0
	constant MOVEC_ITT1   : std_logic_vector(11 downto 0) := x"005"; -- Instruction Transparent Translation 1
	constant MOVEC_DTT0   : std_logic_vector(11 downto 0) := x"006"; -- Data Transparent Translation 0
	constant MOVEC_DTT1   : std_logic_vector(11 downto 0) := x"007"; -- Data Transparent Translation 1
	constant MOVEC_MMUSR  : std_logic_vector(11 downto 0) := x"805"; -- MMU Status Register
	constant MOVEC_URP    : std_logic_vector(11 downto 0) := x"806"; -- User Root Pointer
	constant MOVEC_SRP    : std_logic_vector(11 downto 0) := x"807"; -- Supervisor Root Pointer

	------------------------------------------------------------------------------
	-- Cache Control Register (CACR) - MC68040 Format (32-bit)
	------------------------------------------------------------------------------
	-- Bit assignments for MC68040 CACR:
	-- 31: Enable Data Cache
	-- 30: Freeze Data Cache
	-- 29: Enable Data Burst
	-- 28: Reserved
	-- 27-26: Reserved
	-- 25-24: Write Allocation
	-- 23-20: Reserved
	-- 19: Half Cache Mode (not implemented yet)
	-- 18-16: Reserved
	-- 15: Enable Instruction Cache
	-- 14: Freeze Instruction Cache
	-- 13: Enable Instruction Burst
	-- 12: Reserved
	-- 11-8: Reserved
	-- 7-4: Reserved
	-- 3: Clear Data Cache Entry
	-- 2: Clear Instruction Cache Entry
	-- 1: Clear Data Cache
	-- 0: Clear Instruction Cache
	------------------------------------------------------------------------------

	-- CACR bit positions
	constant CACR_DE   : integer := 31;  -- Data Cache Enable
	constant CACR_DF   : integer := 30;  -- Data Cache Freeze
	constant CACR_DBE  : integer := 29;  -- Data Burst Enable
	constant CACR_IE   : integer := 15;  -- Instruction Cache Enable
	constant CACR_IF   : integer := 14;  -- Instruction Cache Freeze
	constant CACR_IBE  : integer := 13;  -- Instruction Burst Enable
	constant CACR_CDE  : integer := 3;   -- Clear Data Cache Entry
	constant CACR_CIE  : integer := 2;   -- Clear Instruction Cache Entry
	constant CACR_CD   : integer := 1;   -- Clear Data Cache
	constant CACR_CI   : integer := 0;   -- Clear Instruction Cache

	------------------------------------------------------------------------------
	-- Translation Control Register (TC) - MC68040 Format (32-bit)
	------------------------------------------------------------------------------
	-- Bit assignments:
	-- 31: Enable (Translation Enable)
	-- 30-16: Reserved
	-- 15: Page Size (0 = 4KB, 1 = 8KB) - we'll support 4KB only initially
	-- 14-0: Reserved
	------------------------------------------------------------------------------
	constant TC_E   : integer := 31;  -- Translation Enable
	constant TC_PS  : integer := 15;  -- Page Size (0=4KB, 1=8KB)

	------------------------------------------------------------------------------
	-- Transparent Translation Registers (ITT0, ITT1, DTT0, DTT1) - 32-bit
	------------------------------------------------------------------------------
	-- Bit assignments:
	-- 31-24: Logical Address Base
	-- 23-16: Logical Address Mask
	-- 15: Enable
	-- 14-13: Reserved
	-- 12-10: Function Code Base
	-- 9-8: Function Code Mask
	-- 7-5: Reserved
	-- 4: Supervisor Mode
	-- 3: User Mode
	-- 2: Cache Inhibit
	-- 1: Write Protect
	-- 0: Reserved
	------------------------------------------------------------------------------
	constant TTR_E   : integer := 15;  -- Enable
	constant TTR_S   : integer := 4;   -- Supervisor Mode
	constant TTR_U   : integer := 3;   -- User Mode
	constant TTR_CI  : integer := 2;   -- Cache Inhibit
	constant TTR_WP  : integer := 1;   -- Write Protect

	------------------------------------------------------------------------------
	-- MMU Status Register (MMUSR) - 16-bit
	------------------------------------------------------------------------------
	-- Bit assignments:
	-- 15: Bus Error
	-- 14: Limit Violation
	-- 13: Supervisor Violation
	-- 12: Write Protected
	-- 11: Invalid
	-- 10: Modified
	-- 9-8: Transparent Translation Hit (00=none, 01=TTR0, 10=TTR1)
	-- 7-0: Reserved
	------------------------------------------------------------------------------
	constant MMUSR_B  : integer := 15;  -- Bus Error
	constant MMUSR_L  : integer := 14;  -- Limit Violation
	constant MMUSR_S  : integer := 13;  -- Supervisor Violation
	constant MMUSR_W  : integer := 12;  -- Write Protected
	constant MMUSR_I  : integer := 11;  -- Invalid
	constant MMUSR_M  : integer := 10;  -- Modified

	------------------------------------------------------------------------------
	-- Cache Organization Constants
	------------------------------------------------------------------------------
	constant CACHE_SIZE      : integer := 4096;     -- 4KB cache size
	constant CACHE_LINE_SIZE : integer := 16;       -- 16 bytes per line
	constant CACHE_NUM_LINES : integer := CACHE_SIZE / CACHE_LINE_SIZE; -- 256 lines

	-- For direct-mapped cache:
	constant CACHE_INDEX_BITS : integer := 8;       -- 256 lines = 2^8
	constant CACHE_OFFSET_BITS : integer := 4;      -- 16 bytes = 2^4
	constant CACHE_TAG_BITS   : integer := 32 - CACHE_INDEX_BITS - CACHE_OFFSET_BITS; -- 20 bits

	-- Cache line state
	type cache_line_state_t is (
		INVALID,     -- Line is invalid
		VALID,       -- Line is valid (clean)
		DIRTY        -- Line is valid and modified (for write-back, future)
	);

	------------------------------------------------------------------------------
	-- MMU Constants
	------------------------------------------------------------------------------
	constant PAGE_SIZE_4KB : integer := 4096;       -- 4KB pages
	constant PAGE_SIZE_8KB : integer := 8192;       -- 8KB pages (future)
	constant PAGE_OFFSET_BITS_4KB : integer := 12;  -- 2^12 = 4096

	-- TLB (Translation Lookaside Buffer) size
	-- Real 68040 has 64 entries per TLB, we'll use 16 for now
	constant TLB_NUM_ENTRIES : integer := 16;
	constant TLB_INDEX_BITS  : integer := 4;        -- 2^4 = 16

	------------------------------------------------------------------------------
	-- FPU Constants
	------------------------------------------------------------------------------
	-- FPU Register file: 8 registers (FP0-FP7), 80-bit extended precision
	constant FPU_NUM_REGS : integer := 8;
	constant FPU_REG_WIDTH : integer := 80;         -- Extended precision

	-- FP Data types
	type fp_datatype_t is (
		FP_BYTE,          -- Byte integer
		FP_WORD,          -- Word integer
		FP_LONG,          -- Long integer
		FP_SINGLE,        -- Single precision (32-bit)
		FP_DOUBLE,        -- Double precision (64-bit)
		FP_EXTENDED,      -- Extended precision (80-bit)
		FP_PACKED_DEC     -- Packed decimal (not implemented initially)
	);

	-- FP Rounding modes
	type fp_rounding_mode_t is (
		FP_ROUND_NEAREST,     -- Round to nearest (even)
		FP_ROUND_ZERO,        -- Round toward zero
		FP_ROUND_NEG_INF,     -- Round toward negative infinity
		FP_ROUND_POS_INF      -- Round toward positive infinity
	);

	------------------------------------------------------------------------------
	-- Pipeline Stage Types
	------------------------------------------------------------------------------
	-- Pipeline stages for MC68040 6-stage pipeline
	type pipeline_stage_t is (
		STAGE_IF,    -- Instruction Fetch
		STAGE_ID,    -- Instruction Decode
		STAGE_EA,    -- Effective Address calculation
		STAGE_OF,    -- Operand Fetch
		STAGE_EX,    -- Execute
		STAGE_WB     -- Write Back
	);

	------------------------------------------------------------------------------
	-- New MC68040 Instructions Opcodes
	------------------------------------------------------------------------------
	-- MOVE16 - 16-byte block move (cache line sized)
	-- Format: 1111 0110 00xx xxxx for various addressing modes
	constant OPC_MOVE16_BASE : std_logic_vector(15 downto 8) := x"F6";

	-- MOVE16 variants (bits 3-0)
	constant MOVE16_AN_INC_ABS  : std_logic_vector(3 downto 0) := "0000"; -- (An)+, (xxx).L
	constant MOVE16_ABS_AN_INC  : std_logic_vector(3 downto 0) := "1000"; -- (xxx).L, (An)+
	constant MOVE16_AN_ABS      : std_logic_vector(3 downto 0) := "0001"; -- (An), (xxx).L
	constant MOVE16_ABS_AN      : std_logic_vector(3 downto 0) := "1001"; -- (xxx).L, (An)

	-- Cache instructions
	-- CINV - Cache Invalidate
	-- Format: 1111 0100 0xx0 1xxx (bit 9-8: scope, bit 6: cache, bit 3: 1)
	constant OPC_CINV_BASE : std_logic_vector(15 downto 10) := "111101";
	constant CINV_LINE : std_logic_vector(9 downto 8) := "01";  -- Invalidate line
	constant CINV_PAGE : std_logic_vector(9 downto 8) := "10";  -- Invalidate page
	constant CINV_ALL  : std_logic_vector(9 downto 8) := "11";  -- Invalidate all

	-- CPUSH - Cache Push
	-- Format: 1111 0100 0xx1 0xxx (bit 9-8: scope, bit 6: cache, bit 3: 0)
	constant OPC_CPUSH_BASE : std_logic_vector(15 downto 10) := "111101";
	constant CPUSH_LINE : std_logic_vector(9 downto 8) := "01";  -- Push line
	constant CPUSH_PAGE : std_logic_vector(9 downto 8) := "10";  -- Push page
	constant CPUSH_ALL  : std_logic_vector(9 downto 8) := "11";  -- Push all

	-- Cache selector (bit 6)
	constant CACHE_DATA : std_logic := '0';  -- Data cache
	constant CACHE_INSN : std_logic := '1';  -- Instruction cache

	------------------------------------------------------------------------------
	-- Instruction Decoder Types
	------------------------------------------------------------------------------
	-- Instruction type enumeration
	type instr_type_t is (
		INSTR_NONE,      -- No instruction
		INSTR_MOVE16,    -- MOVE16
		INSTR_CINV,      -- Cache invalidate
		INSTR_CPUSH,     -- Cache push
		INSTR_OTHER      -- Other instructions (handled by TG68K)
	);

	-- Cache operation scope
	type cache_op_scope_t is (
		SCOPE_LINE,      -- Single cache line
		SCOPE_PAGE,      -- All lines in 4KB page
		SCOPE_ALL        -- Entire cache
	);

	-- Cache operation type
	type cache_op_type_t is (
		CACHE_OP_NONE,   -- No operation
		CACHE_OP_INV,    -- Invalidate
		CACHE_OP_PUSH    -- Push (write-back + invalidate)
	);

	-- Cache selector type
	type cache_select_t is (
		CACHE_SEL_DATA,  -- Data cache
		CACHE_SEL_INSN,  -- Instruction cache
		CACHE_SEL_BOTH   -- Both caches (supervisor only)
	);

	-- MOVE16 addressing mode
	type move16_mode_t is (
		MOVE16_AN_INC_TO_ABS,  -- (An)+, (xxx).L
		MOVE16_ABS_TO_AN_INC,  -- (xxx).L, (An)+
		MOVE16_AN_TO_ABS,      -- (An), (xxx).L
		MOVE16_ABS_TO_AN       -- (xxx).L, (An)
	);

	------------------------------------------------------------------------------
	-- Cache Operation Control Structure
	------------------------------------------------------------------------------
	-- Control signals for cache operations (to cache controller, future)
	type cache_op_ctrl_t is record
		enable      : std_logic;                       -- Operation enable
		op_type     : cache_op_type_t;                 -- Invalidate or push
		scope       : cache_op_scope_t;                -- Line, page, or all
		cache_sel   : cache_select_t;                  -- Which cache(s)
		address     : std_logic_vector(31 downto 0);   -- Address for line/page ops
	end record;

	------------------------------------------------------------------------------
	-- Cache Line Structure
	------------------------------------------------------------------------------
	-- A cache line contains tag, valid bit, dirty bit (future), and data
	type cache_tag_t is record
		tag        : std_logic_vector(CACHE_TAG_BITS-1 downto 0);  -- Address tag
		valid      : std_logic;                                     -- Valid bit
		dirty      : std_logic;                                     -- Dirty bit (for write-back)
	end record;

	-- Cache data: 16 bytes = 128 bits
	subtype cache_line_data_t is std_logic_vector(127 downto 0);

	-- Complete cache line
	type cache_line_t is record
		tag_info : cache_tag_t;
		data     : cache_line_data_t;
	end record;

	------------------------------------------------------------------------------
	-- TLB Entry Structure
	------------------------------------------------------------------------------
	type tlb_entry_t is record
		valid      : std_logic;                          -- Entry is valid
		logical    : std_logic_vector(19 downto 0);      -- Logical page address (upper 20 bits for 4KB)
		physical   : std_logic_vector(19 downto 0);      -- Physical page address
		supervisor : std_logic;                          -- Supervisor mode access
		write_prot : std_logic;                          -- Write protected
		cache_inh  : std_logic;                          -- Cache inhibit
		modified   : std_logic;                          -- Page has been modified
		referenced : std_logic;                          -- Page has been referenced
	end record;

	------------------------------------------------------------------------------
	-- Function: is_68040_mode
	-- Returns true if CPU is in 68040 mode
	------------------------------------------------------------------------------
	function is_68040_mode(cpu_mode : std_logic_vector(1 downto 0)) return boolean;

	------------------------------------------------------------------------------
	-- Function: cache_index
	-- Extract cache index from address
	------------------------------------------------------------------------------
	function cache_index(addr : std_logic_vector(31 downto 0)) return integer;

	------------------------------------------------------------------------------
	-- Function: cache_tag
	-- Extract cache tag from address
	------------------------------------------------------------------------------
	function cache_tag(addr : std_logic_vector(31 downto 0)) return std_logic_vector;

	------------------------------------------------------------------------------
	-- Function: cache_offset
	-- Extract cache offset from address
	------------------------------------------------------------------------------
	function cache_offset(addr : std_logic_vector(31 downto 0)) return integer;

	------------------------------------------------------------------------------
	-- Function: page_number
	-- Extract page number from address (for 4KB pages)
	------------------------------------------------------------------------------
	function page_number(addr : std_logic_vector(31 downto 0)) return std_logic_vector;

	------------------------------------------------------------------------------
	-- Function: page_offset
	-- Extract page offset from address (for 4KB pages)
	------------------------------------------------------------------------------
	function page_offset(addr : std_logic_vector(31 downto 0)) return std_logic_vector;

	------------------------------------------------------------------------------
	-- Function: is_aligned_16
	-- Check if address is 16-byte aligned (for MOVE16)
	------------------------------------------------------------------------------
	function is_aligned_16(addr : std_logic_vector(31 downto 0)) return boolean;

	------------------------------------------------------------------------------
	-- Function: align_to_16
	-- Align address down to 16-byte boundary
	------------------------------------------------------------------------------
	function align_to_16(addr : std_logic_vector(31 downto 0)) return std_logic_vector;

end package TG68040_Pack;

------------------------------------------------------------------------------
-- Package Body
------------------------------------------------------------------------------
package body TG68040_Pack is

	------------------------------------------------------------------------------
	-- Function: is_68040_mode
	------------------------------------------------------------------------------
	function is_68040_mode(cpu_mode : std_logic_vector(1 downto 0)) return boolean is
	begin
		return cpu_mode = CPU_68040;
	end function;

	------------------------------------------------------------------------------
	-- Function: cache_index
	-- Extract bits [11:4] from address (256 lines, 16 bytes each)
	------------------------------------------------------------------------------
	function cache_index(addr : std_logic_vector(31 downto 0)) return integer is
	begin
		return to_integer(unsigned(addr(CACHE_INDEX_BITS + CACHE_OFFSET_BITS - 1 downto CACHE_OFFSET_BITS)));
	end function;

	------------------------------------------------------------------------------
	-- Function: cache_tag
	-- Extract upper bits from address
	------------------------------------------------------------------------------
	function cache_tag(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
	begin
		return addr(31 downto CACHE_INDEX_BITS + CACHE_OFFSET_BITS);
	end function;

	------------------------------------------------------------------------------
	-- Function: cache_offset
	-- Extract bits [3:0] from address (16-byte line)
	------------------------------------------------------------------------------
	function cache_offset(addr : std_logic_vector(31 downto 0)) return integer is
	begin
		return to_integer(unsigned(addr(CACHE_OFFSET_BITS - 1 downto 0)));
	end function;

	------------------------------------------------------------------------------
	-- Function: page_number
	-- Extract upper 20 bits for 4KB pages (bits [31:12])
	------------------------------------------------------------------------------
	function page_number(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
	begin
		return addr(31 downto PAGE_OFFSET_BITS_4KB);
	end function;

	------------------------------------------------------------------------------
	-- Function: page_offset
	-- Extract lower 12 bits for 4KB pages (bits [11:0])
	------------------------------------------------------------------------------
	function page_offset(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
	begin
		return addr(PAGE_OFFSET_BITS_4KB - 1 downto 0);
	end function;

	------------------------------------------------------------------------------
	-- Function: is_aligned_16
	-- Check if lower 4 bits are zero (16-byte alignment)
	------------------------------------------------------------------------------
	function is_aligned_16(addr : std_logic_vector(31 downto 0)) return boolean is
	begin
		return addr(3 downto 0) = "0000";
	end function;

	------------------------------------------------------------------------------
	-- Function: align_to_16
	-- Clear lower 4 bits to align to 16-byte boundary
	------------------------------------------------------------------------------
	function align_to_16(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
	begin
		return addr(31 downto 4) & "0000";
	end function;

end package body TG68040_Pack;
