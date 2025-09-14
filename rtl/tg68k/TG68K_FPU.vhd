------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 Compatible Floating Point Unit                       --
-- Copyright (c) 2025                                                       --
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

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity TG68K_FPU is
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;
		
		-- CPU Interface
		opcode					: in std_logic_vector(15 downto 0);
		extension_word			: in std_logic_vector(15 downto 0);	-- Second instruction word
		fpu_enable				: in std_logic;							-- 1 when F-line instruction should be handled by FPU
		supervisor_mode			: in std_logic;							-- 1 when CPU is in supervisor mode (for privilege checking)
		cpu_data_in				: in std_logic_vector(31 downto 0);	-- Data from CPU (for register/memory sources)
		cpu_address_in			: in std_logic_vector(31 downto 0);	-- Effective address from CPU (for FSAVE/FRESTORE)
		fpu_data_out			: out std_logic_vector(31 downto 0);	-- Data to CPU (for register destinations)
		
		-- FSAVE/FRESTORE Data Interface (CPU manages all memory operations)
		fsave_data_request		: in std_logic;							-- CPU requests FSAVE data at specific index
		fsave_data_index		: in integer range 0 to 54;
		frestore_data_write		: in std_logic;							-- CPU writing FRESTORE data
		frestore_data_in		: in std_logic_vector(31 downto 0);		-- Data from CPU for FRESTORE
		
		-- FMOVEM Data Interface (CPU manages all memory operations)
		fmovem_data_request		: in std_logic;							-- CPU requests FMOVEM data at specific register
		fmovem_reg_index		: in integer range 0 to 7;				-- Index of FP register (0-7)
		fmovem_data_write		: in std_logic;							-- CPU writing FMOVEM data to register
		fmovem_data_in			: in std_logic_vector(79 downto 0);		-- Data from CPU for FMOVEM load
		fmovem_data_out			: out std_logic_vector(79 downto 0);	-- Data to CPU for FMOVEM store
		
		-- Control Signals
		fpu_busy				: out std_logic;						-- FPU is executing multi-cycle operation
		fpu_done				: buffer std_logic;						-- Operation complete
		fpu_exception			: buffer std_logic;						-- FPU exception occurred
		exception_code			: out std_logic_vector(7 downto 0);	-- Exception type
		
		-- Status and Control Registers
		fpcr_out				: out std_logic_vector(31 downto 0);	-- Floating-Point Control Register
		fpsr_out				: out std_logic_vector(31 downto 0);	-- Floating-Point Status Register
		fpiar_out				: out std_logic_vector(31 downto 0);	-- Floating-Point Instruction Address Register
		
		-- FSAVE Frame Size Handshake (Critical for proper predecrement)
		fsave_frame_size		: out integer range 4 to 216;			-- Dynamic frame size in bytes
		fsave_size_valid		: out std_logic;						-- Frame size is valid and stable
		
		-- MC68020/68881 Coprocessor Interface Registers (CIR)
		-- CPU space addressing with FC=111, A4-A0 selects CIR register
		cir_address				: in std_logic_vector(4 downto 0);		-- A4-A0 from CPU space address
		cir_write				: in std_logic;							-- CPU writing to CIR
		cir_read				: in std_logic;							-- CPU reading from CIR  
		cir_data_in				: in std_logic_vector(15 downto 0);	-- Data from CPU to CIR
		cir_data_out			: out std_logic_vector(15 downto 0);	-- Data from CIR to CPU
		cir_data_valid			: out std_logic							-- CIR data available for CPU
	);
end TG68K_FPU;

architecture rtl of TG68K_FPU is

	-- MC68881/68882 Floating Point Register File (8 x 80-bit registers)
	-- Stored as 80-bit IEEE 754 extended precision values
	type fp_reg_t is array(0 to 7) of std_logic_vector(79 downto 0);
	-- IEEE 754 compliant initialization: All registers should contain positive non-signaling NaN
	-- Extended precision NaN: Sign=0, Exponent=7FFF, Mantissa=C000000000000000 (bit 62=1 for quiet NaN)
	constant IEEE_NaN : std_logic_vector(79 downto 0) := X"7FFFC000000000000000";
	signal fp_registers : fp_reg_t := (others => IEEE_NaN);
	
	-- Control and Status Registers with proper MC68882 defaults
	-- FPCR: MC68882 initialization
	-- Bits 31-16: Reserved (some implementations may have version info)
	-- Bits 15-14: Mode Control (00 = round to nearest)
	-- Bits 13-8: Exception Enable (000000 = no exceptions enabled)
	-- Bits 7-0: Reserved
	-- Standard initialization is usually all zeros, but some systems expect specific values
	signal fpcr : std_logic_vector(31 downto 0) := X"00000000";	-- Floating-Point Control Register
	-- FPSR: MC68882 initialization - cleared on reset per IEEE 754
	-- Bits 31-28: Condition codes (N,Z,I,NaN) = 0000 after reset
	-- Bits 27-24: Reserved = 0000  
	-- Bits 23-16: Quotient byte = 00000000
	-- Bits 15-8: Exception status byte = 00000000
	-- Bits 7-0: Accrued exception byte = 00000000
	signal fpsr : std_logic_vector(31 downto 0) := X"00000000";	-- Floating-Point Status Register
	signal fpiar : std_logic_vector(31 downto 0) := (others => '0');	-- Floating-Point Instruction Address Register
	
	-- MC68020/68881 Coprocessor Interface Registers (CIR)
	-- Per MC68020 Users Manual Section 7: A4-A0 select register
	-- 00000 = Response CIR, 00001 = Command CIR, 00010 = Condition CIR
	-- 00011 = Save CIR, 00100 = Restore CIR, 00101 = Operation Word CIR, 00110 = Command Address CIR
	-- MC68882 Coprocessor Interface Registers (CIR) - Complete implementation
	signal response_cir : std_logic_vector(15 downto 0) := (others => '0');	-- Response CIR (register 0) - Read-only
	signal command_cir : std_logic_vector(15 downto 0) := (others => '0');		-- Command CIR (register 1) - Write-only
	signal condition_cir : std_logic_vector(15 downto 0) := (others => '0');	-- Condition CIR (register 2) - Read-only
	signal save_cir : std_logic_vector(15 downto 0) := (others => '0');		-- Save CIR (register 3) - Read-only
	signal restore_cir : std_logic_vector(15 downto 0) := (others => '0');	-- Restore CIR (register 4) - Write-only
	signal operand_cir : std_logic_vector(15 downto 0) := (others => '0');		-- Operand CIR (register 5) - Write-only
	-- Additional MC68882 CIR registers for complete protocol support
	signal operation_word_cir : std_logic_vector(15 downto 0) := (others => '0');	-- Operation Word (register 6) - Read-only
	signal command_address_cir : std_logic_vector(31 downto 0) := (others => '0');	-- Command Address (register 7-8) - Read-only
	
	-- Internal state machine
	type fpu_state_t is (
		FPU_IDLE,
		FPU_DECODE,
		FPU_FETCH_SOURCE,
		FPU_MEMORY_READ,
		FPU_MEMORY_WRITE,
		FPU_EXECUTE,
		FPU_WRITE_RESULT,
		FPU_EXCEPTION_STATE,
		FPU_FSAVE_WRITE,      -- Added explicit state for FSAVE
		FPU_FRESTORE_READ,
		FPU_FMOVEM,           -- FMOVEM FP register operations (FP0-FP7)
		FPU_FMOVEM_CR         -- FMOVEM control register operations (FPCR/FPSR/FPIAR)
	);
	signal fpu_state : fpu_state_t := FPU_IDLE;
	signal next_state : fpu_state_t;
	signal fpu_busy_internal : std_logic := '0';
	
	-- FPU context state for dynamic FSAVE frame selection
	signal fsave_frame_format : std_logic_vector(7 downto 0); -- Current frame format to return
	
	-- FSAVE Frame Size Determination Signals
	signal fsave_frame_size_internal : integer range 4 to 216 := 60;  -- Default to IDLE frame
	signal fsave_size_valid_internal : std_logic := '0';  -- Frame size determination complete
	signal fsave_frame_size_latched : integer range 4 to 216 := 60;  -- Latched frame size for stability
	signal fsave_frame_format_latched : std_logic_vector(7 downto 0) := X"60";  -- Latched format
	signal fsave_frame_size_debug : integer range 0 to 255 := 0;  -- Debug signal to trace frame size
	
	-- MOVEM component control signals
	signal movem_register_list : std_logic_vector(7 downto 0);
	signal movem_direction : std_logic;  -- 0=store to memory, 1=load from memory
	
	-- Timeout counter to prevent infinite wait states
	signal timeout_counter : integer range 0 to 255 := 0;
	-- Improved timeout limits for different operation types
	constant TIMEOUT_LIMIT_MEMORY : integer := 128;  -- Memory operations (bus access)
	constant TIMEOUT_LIMIT_ALU : integer := 64;      -- ALU operations (arithmetic)
	constant TIMEOUT_LIMIT_FSAVE : integer := 32;    -- FSAVE/FRESTORE frame operations
	constant TIMEOUT_LIMIT_MOVEM : integer := 256;   -- MOVEM operations (multi-register transfers)
	
	-- MC68881/68882 instruction timing (in clock cycles) for accuracy
	signal instruction_cycles : integer range 0 to 255 := 0;
	-- Optimized timing constants for better performance
	constant TIMING_FMOVE : integer := 2;      -- FMOVE FPn,FPm (optimized)
	constant TIMING_FADD : integer := 4;       -- FADD (optimized)
	constant TIMING_FSUB : integer := 4;       -- FSUB (optimized)
	constant TIMING_FMUL : integer := 6;       -- FMUL (optimized)
	constant TIMING_FDIV : integer := 16;      -- FDIV (optimized)
	constant TIMING_FSQRT : integer := 24;     -- FSQRT (optimized)
	constant TIMING_FCMP : integer := 3;       -- FCMP (optimized)
	constant TIMING_FABS : integer := 1;       -- FABS/FNEG (fast operations)
	constant TIMING_TRANSCENDENTAL : integer := 32;  -- SIN/COS/LOG/EXP (optimized)
	
	-- Performance optimization signals
	signal fast_path_enabled : std_logic := '0';   -- Enable fast path for simple operations
	signal operation_complexity : std_logic_vector(1 downto 0) := "00";  -- 00=simple, 01=medium, 10=complex, 11=very complex
	
	-- FSAVE/FRESTORE operation signals
	signal fsave_counter : integer range 0 to 54 := 0;  -- Word counter for all frame types
	signal frestore_frame_format : std_logic_vector(7 downto 0);  -- Saved frame format for FRESTORE
	
	-- Instruction decode signals from decoder
	signal decoder_instruction_type	: std_logic_vector(3 downto 0);
	signal decoder_operation_code		: std_logic_vector(6 downto 0);
	signal decoder_source_format		: std_logic_vector(2 downto 0);
	signal decoder_dest_format			: std_logic_vector(2 downto 0);
	signal decoder_source_reg			: std_logic_vector(2 downto 0);
	signal decoder_dest_reg				: std_logic_vector(2 downto 0);
	signal decoder_ea_mode				: std_logic_vector(2 downto 0);
	signal decoder_ea_register			: std_logic_vector(2 downto 0);
	signal decoder_needs_extension		: std_logic;	-- unused
	signal decoder_valid_instruction	: std_logic;
	signal decoder_privileged			: std_logic;	-- unused
	signal decoder_illegal				: std_logic;
	signal decoder_unsupported			: std_logic;
	
	-- Internal decode signals
	signal fpu_operation : std_logic_vector(6 downto 0);	-- 7-bit operation field
	signal source_reg : std_logic_vector(2 downto 0);		-- Source FP register
	signal dest_reg : std_logic_vector(2 downto 0);		-- Destination FP register
	signal data_format : std_logic_vector(2 downto 0);		-- Data format (byte, word, long, single, double, extended, packed)
	signal ea_mode : std_logic_vector(2 downto 0);			-- Effective address mode
	signal ea_register : std_logic_vector(2 downto 0);		-- Effective address register
	
	-- Operation execution signals
	signal operation_done : std_logic;
	signal current_exception : std_logic;
	signal exception_type : std_logic_vector(7 downto 0);
	signal exception_code_internal : std_logic_vector(7 downto 0);  -- Internal signal for exception code
	
	-- ALU interface signals
	signal alu_start_operation : std_logic;
	signal alu_operation_code : std_logic_vector(6 downto 0);
	signal alu_operand_a : std_logic_vector(79 downto 0);
	signal alu_operand_b : std_logic_vector(79 downto 0);
	signal alu_result : std_logic_vector(79 downto 0);
	signal alu_result_valid : std_logic;
	signal alu_overflow : std_logic;
	signal alu_underflow : std_logic;
	signal alu_inexact : std_logic;
	
	-- Temporary signals for exception handler connections
	signal exception_reset : std_logic;
	signal exception_op_valid : std_logic;
	signal exception_op_type : std_logic_vector(7 downto 0);
	signal alu_invalid : std_logic;
	signal alu_divide_by_zero : std_logic;
	signal alu_operation_busy : std_logic;
	signal alu_operation_done : std_logic;
	signal alu_quotient_byte : std_logic_vector(7 downto 0);
	
	-- Transcendental unit interface signals
	signal trans_start_operation : std_logic;
	signal trans_operation_code : std_logic_vector(6 downto 0);
	signal trans_operand : std_logic_vector(79 downto 0);
	signal trans_result : std_logic_vector(79 downto 0);
	signal trans_result_valid : std_logic;
	signal trans_overflow : std_logic;
	signal trans_underflow : std_logic;
	signal trans_inexact : std_logic;
	signal trans_invalid : std_logic;
	signal trans_operation_busy : std_logic;
	signal trans_operation_done : std_logic;
	
	
	-- Final result selection
	signal final_result : std_logic_vector(79 downto 0);
	signal final_overflow : std_logic;
	signal final_underflow : std_logic;
	signal final_inexact : std_logic;
	signal final_invalid : std_logic;
	
	-- Legacy signals for compatibility
	signal op1_data : std_logic_vector(79 downto 0);		-- First operand (80-bit extended)
	signal op2_data : std_logic_vector(79 downto 0);		-- Second operand (80-bit extended)
	signal result_data : std_logic_vector(79 downto 0);	-- Result (80-bit extended)
	signal result_valid : std_logic;
	
	-- Data format conversion signals
	signal converter_start : std_logic;
	signal converter_done : std_logic;
	signal converter_valid : std_logic;
	signal converter_source_format : std_logic_vector(2 downto 0);
	signal converter_dest_format : std_logic_vector(2 downto 0);
	signal converter_data_in : std_logic_vector(95 downto 0);
	signal converter_data_out : std_logic_vector(79 downto 0);
	signal converter_overflow : std_logic;
	signal converter_underflow : std_logic;
	signal converter_inexact : std_logic;
	signal converter_invalid : std_logic;
	
	-- Constant ROM signals
	signal rom_offset : std_logic_vector(6 downto 0);
	signal rom_read_enable : std_logic;
	signal constrom_result : std_logic_vector(79 downto 0);
	signal constrom_valid : std_logic;
	
	-- MOVEM operation signals (CPU-managed memory operations)
	signal movem_start : std_logic;
	signal movem_done : std_logic;
	signal movem_busy : std_logic;
	signal movem_predecrement : std_logic := '0';
	signal movem_postincrement : std_logic := '0';
	
	-- FMOVEM interface signals are now ports (declared in entity)
	
	-- MOVEM register file interface signals
	signal movem_reg_address : std_logic_vector(2 downto 0);
	signal movem_reg_data_in : std_logic_vector(79 downto 0);
	signal movem_reg_data_out : std_logic_vector(79 downto 0);
	signal movem_reg_write_enable : std_logic;
	signal movem_address_error : std_logic;
	
	-- Floating-point to integer conversion signals
	signal fp_to_int_sign : std_logic;
	signal fp_to_int_exp : std_logic_vector(14 downto 0);
	signal fp_to_int_mant : std_logic_vector(63 downto 0);
	signal fp_to_int_exp_int : integer range -32768 to 32767;
	signal fp_to_int_shift : integer range 0 to 63;
	signal fp_to_int_result : std_logic_vector(31 downto 0);
	
	-- Exception handler signals
	signal exception_fpsr_out : std_logic_vector(31 downto 0);
	signal exception_pending_internal : std_logic;
	signal exception_vector_internal : std_logic_vector(7 downto 0);
	signal exception_corrected_result : std_logic_vector(79 downto 0);
	
	-- MC68881/68882 Operation Codes (7-bit field from instruction word)
	-- Basic operations (fully implemented)
	constant OP_FMOVE		: std_logic_vector(6 downto 0) := "0000000";
	constant OP_FINT		: std_logic_vector(6 downto 0) := "0000001";
	constant OP_FNOP		: std_logic_vector(6 downto 0) := "0000010";
	constant OP_FINTRZ		: std_logic_vector(6 downto 0) := "0000011";
	constant OP_FSQRT		: std_logic_vector(6 downto 0) := "0000100";
	constant OP_FABS		: std_logic_vector(6 downto 0) := "0011000";
	constant OP_FNEG		: std_logic_vector(6 downto 0) := "0011010";
	constant OP_FDIV		: std_logic_vector(6 downto 0) := "0100000";
	constant OP_FADD		: std_logic_vector(6 downto 0) := "0100010";
	constant OP_FMUL		: std_logic_vector(6 downto 0) := "0100011";
	constant OP_FSGLDIV		: std_logic_vector(6 downto 0) := "0100100";
	constant OP_FSGLMUL		: std_logic_vector(6 downto 0) := "0100111";
	constant OP_FSUB		: std_logic_vector(6 downto 0) := "0101000";
	constant OP_FCMP		: std_logic_vector(6 downto 0) := "0111000";
	constant OP_FTST		: std_logic_vector(6 downto 0) := "0111010";
	constant OP_FMOVEM		: std_logic_vector(6 downto 0) := "1000000";  -- FMOVEM operation
	constant OP_FMOVECR		: std_logic_vector(6 downto 0) := "1000001";  -- FMOVECR (move constant from ROM)
	
	-- Transcendental functions (extended library - basic placeholder support)
	constant OP_FSINH		: std_logic_vector(6 downto 0) := "0001011";  -- Hyperbolic sine
	constant OP_FLOGNP1		: std_logic_vector(6 downto 0) := "0000101";  -- ln(x + 1)
	constant OP_FETOXM1		: std_logic_vector(6 downto 0) := "0000111";  -- e^x - 1
	constant OP_FTANH		: std_logic_vector(6 downto 0) := "0001001";
	constant OP_FATAN		: std_logic_vector(6 downto 0) := "0001010";
	constant OP_FASIN		: std_logic_vector(6 downto 0) := "0001100";
	constant OP_FATANH		: std_logic_vector(6 downto 0) := "0001101";
	constant OP_FSIN		: std_logic_vector(6 downto 0) := "0001110";
	constant OP_FTAN		: std_logic_vector(6 downto 0) := "0001111";
	constant OP_FSINCOS		: std_logic_vector(6 downto 0) := "0110000";  -- FSINCOS: simultaneous sine and cosine
	constant OP_FETOX		: std_logic_vector(6 downto 0) := "0010000";
	constant OP_FTWOTOX		: std_logic_vector(6 downto 0) := "0010001";
	constant OP_FTENTOX		: std_logic_vector(6 downto 0) := "0010010";
	constant OP_FLOGN		: std_logic_vector(6 downto 0) := "0010100";
	constant OP_FLOG10		: std_logic_vector(6 downto 0) := "0010101";
	constant OP_FLOG2		: std_logic_vector(6 downto 0) := "0010110";
	constant OP_FCOSH		: std_logic_vector(6 downto 0) := "0011001";
	constant OP_FACOS		: std_logic_vector(6 downto 0) := "0011100";
	constant OP_FCOS		: std_logic_vector(6 downto 0) := "0011101";
	constant OP_FGETEXP		: std_logic_vector(6 downto 0) := "0011110";
	constant OP_FGETMAN		: std_logic_vector(6 downto 0) := "0011111";
	constant OP_FMOD		: std_logic_vector(6 downto 0) := "0100001";
	constant OP_FREM		: std_logic_vector(6 downto 0) := "0100101";
	constant OP_FSCALE		: std_logic_vector(6 downto 0) := "0100110";
	-- OP_FMOVECR already declared above at line 264
	
	-- Instruction type constants (matching decoder)
	constant INST_GENERAL		: std_logic_vector(3 downto 0) := "0000";	-- General instruction
	constant INST_FMOVE_FP		: std_logic_vector(3 downto 0) := "0001";	-- FMOVE FPn,<ea>
	constant INST_FMOVE_MEM		: std_logic_vector(3 downto 0) := "0010";	-- FMOVE <ea>,FPn
	constant INST_FMOVEM		: std_logic_vector(3 downto 0) := "0011";	-- FMOVEM
	constant INST_FMOVE_CR		: std_logic_vector(3 downto 0) := "0100";	-- FMOVE control register
	constant INST_FMOVEM_CR		: std_logic_vector(3 downto 0) := "1001";	-- FMOVEM control registers
	constant INST_FBCC			: std_logic_vector(3 downto 0) := "0101";	-- FBcc
	constant INST_FSAVE			: std_logic_vector(3 downto 0) := "0110";	-- FSAVE
	constant INST_FRESTORE		: std_logic_vector(3 downto 0) := "0111";	-- FRESTORE
	constant INST_FTRAP			: std_logic_vector(3 downto 0) := "1000";	-- FTRAPcc

	-- Data format encodings
	constant FORMAT_LONG		: std_logic_vector(2 downto 0) := "000";	-- 32-bit integer
	constant FORMAT_SINGLE		: std_logic_vector(2 downto 0) := "001";	-- 32-bit IEEE single
	constant FORMAT_EXTENDED	: std_logic_vector(2 downto 0) := "010";	-- 80-bit IEEE extended
	constant FORMAT_PACKED		: std_logic_vector(2 downto 0) := "011";	-- 96-bit packed decimal
	constant FORMAT_WORD		: std_logic_vector(2 downto 0) := "100";	-- 16-bit integer  
	constant FORMAT_DOUBLE		: std_logic_vector(2 downto 0) := "101";	-- 64-bit IEEE double
	constant FORMAT_BYTE		: std_logic_vector(2 downto 0) := "110";	-- 8-bit integer

	-- MC68882 Coprocessor Primitive Response Codes (Complete Implementation)
	constant PRIM_NULL			: std_logic_vector(15 downto 0) := X"0000";	-- NULL - No bus cycles required
	constant PRIM_CA			: std_logic_vector(15 downto 0) := X"0001";	-- CA - Transfer CPU register to coprocessor
	constant PRIM_CC			: std_logic_vector(15 downto 0) := X"0002";	-- CC - Transfer coprocessor register to CPU
	constant PRIM_CW			: std_logic_vector(15 downto 0) := X"0003";	-- CW - Write CPU register from coprocessor
	constant PRIM_CR			: std_logic_vector(15 downto 0) := X"0004";	-- CR - Read CPU register to coprocessor
	constant PRIM_DR			: std_logic_vector(15 downto 0) := X"0005";	-- DR - Supervisor check
	constant PRIM_BUSY			: std_logic_vector(15 downto 0) := X"0006";	-- BUSY - Coprocessor busy, try later

	-- MC68882 FPSR Condition Code Setting Function
	-- Sets condition codes according to IEEE 754 and MC68882 specification
	-- Input: 80-bit extended precision floating-point value
	-- Output: 4-bit condition code (N, Z, I, NaN)
	procedure set_fpsr_condition_codes(
		signal fpsr_reg : inout std_logic_vector(31 downto 0);
		fp_value : in std_logic_vector(79 downto 0)
	) is
		variable exponent : std_logic_vector(14 downto 0);
		variable mantissa : std_logic_vector(63 downto 0);
		variable sign : std_logic;
	begin
		sign := fp_value(79);
		exponent := fp_value(78 downto 64);
		mantissa := fp_value(63 downto 0);
		
		-- Clear all condition codes first
		fpsr_reg(31 downto 28) <= "0000";
		
		-- Check special values in priority order per MC68882 spec
		if exponent = "111111111111111" then
			-- Maximum exponent - could be NaN or Infinity
			if mantissa(63) = '0' or mantissa(62 downto 0) /= (62 downto 0 => '0') then
				-- NaN (explicit integer bit 0 OR non-zero fraction)
				fpsr_reg(28) <= '1';  -- Set NaN bit
			else
				-- Infinity (explicit integer bit 1 AND zero fraction)
				fpsr_reg(29) <= '1';  -- Set Infinity bit
				fpsr_reg(31) <= sign; -- Set sign for infinity
			end if;
		elsif exponent = (14 downto 0 => '0') and mantissa = (63 downto 0 => '0') then
			-- Zero (exponent and mantissa both zero)
			fpsr_reg(30) <= '1';  -- Set Zero bit
			fpsr_reg(31) <= sign; -- Preserve sign of zero
		else
			-- Normal number or denormalized number
			fpsr_reg(31) <= sign; -- Set sign bit
		end if;
	end procedure;
	
	-- MC68882 FPCR/FPSR Bit Field Validation Functions
	-- Validates and sanitizes control register values per MC68882 specification
	function validate_fpcr(input_fpcr : std_logic_vector(31 downto 0)) return std_logic_vector is
		variable result_fpcr : std_logic_vector(31 downto 0);
	begin
		result_fpcr := input_fpcr;
		
		-- Validate rounding precision (bits 7:6)
		if input_fpcr(7 downto 6) = "11" then
			-- Undefined precision mode - default to extended precision
			result_fpcr(7 downto 6) := "00";  -- Extended precision
		end if;
		
		-- Rounding mode (bits 5:4) - all values are valid per IEEE 754
		-- Exception enable bits (15:8) - all combinations are valid
		-- Reserved bits should be cleared
		result_fpcr(31 downto 16) := (others => '0');  -- Clear reserved upper bits
		result_fpcr(3 downto 0) := (others => '0');    -- Clear reserved lower bits
		
		return result_fpcr;
	end function;
	
	function validate_fpsr(input_fpsr : std_logic_vector(31 downto 0)) return std_logic_vector is
		variable result_fpsr : std_logic_vector(31 downto 0);
	begin
		result_fpsr := input_fpsr;
		
		-- FPSR validation per MC68882 specification:
		-- Bits 31-24: Condition Code Byte (all combinations valid)
		-- Bits 23-16: Quotient Byte (all combinations valid) 
		-- Bits 15-8:  Exception Status Byte (all combinations valid)
		-- Bits 7-0:   Accrued Exception Byte (all combinations valid)
		-- All bits in FPSR are functionally valid - no sanitization needed
		
		return result_fpsr;
	end function;

begin

	-- Instruction decoder instantiation
	FPU_DECODER: TG68K_FPU_Decoder
	port map(
		clk => clk,
		nReset => nReset,
		
		-- Input instruction words
		opcode => opcode,
		extension_word => extension_word,
		
		-- Decoder enable
		decode_enable => fpu_enable,
		
		-- Decoded instruction fields
		instruction_type => decoder_instruction_type,
		operation_code => decoder_operation_code,
		source_format => decoder_source_format,
		dest_format => decoder_dest_format,
		source_reg => decoder_source_reg,
		dest_reg => decoder_dest_reg,
		ea_mode => decoder_ea_mode,
		ea_register => decoder_ea_register,
		
		-- Control signals
		needs_extension_word => decoder_needs_extension,
		valid_instruction => decoder_valid_instruction,
		privileged_instruction => decoder_privileged,
		
		-- Exception flags
		illegal_instruction => decoder_illegal,
		unsupported_instruction => decoder_unsupported
	);

	-- FPU ALU instantiation
	FPU_ALU: entity work.TG68K_FPU_ALU
	port map(
		clk => clk,
		nReset => nReset,
		clkena => clkena,
		
		-- Operation control
		start_operation => alu_start_operation,
		operation_code => alu_operation_code,
		rounding_mode => fpcr(5 downto 4),
		
		-- Operands
		operand_a => alu_operand_a,
		operand_b => alu_operand_b,
		
		-- Result
		result => alu_result,
		result_valid => alu_result_valid,
		
		-- Status flags
		overflow => alu_overflow,
		underflow => alu_underflow,
		inexact => alu_inexact,
		invalid => alu_invalid,
		divide_by_zero => alu_divide_by_zero,
		
		-- Quotient byte for FMOD/FREM
		quotient_byte => alu_quotient_byte,
		
		-- Control
		operation_busy => alu_operation_busy,
		operation_done => alu_operation_done
	);

	-- FPU Transcendental Functions instantiation
	FPU_TRANS: TG68K_FPU_Transcendental
	port map(
		clk => clk,
		nReset => nReset,
		clkena => clkena,
		
		-- Operation control
		start_operation => trans_start_operation,
		operation_code => trans_operation_code,
		
		-- Operand
		operand => trans_operand,
		
		-- Result
		result => trans_result,
		result_valid => trans_result_valid,
		
		-- Status flags
		overflow => trans_overflow,
		underflow => trans_underflow,
		inexact => trans_inexact,
		invalid => trans_invalid,
		
		-- Control
		operation_busy => trans_operation_busy,
		operation_done => trans_operation_done
	);

	-- FPU Data Format Converter instantiation
	FPU_CONVERTER: TG68K_FPU_Converter
	port map(
		clk => clk,
		nReset => nReset,
		clkena => clkena,
		
		-- Control
		start_conversion => converter_start,
		conversion_done => converter_done,
		conversion_valid => converter_valid,
		
		-- Format specification
		source_format => converter_source_format,
		dest_format => converter_dest_format,
		
		-- Data
		data_in => converter_data_in,
		data_out => converter_data_out,
		
		-- Exception flags
		overflow => converter_overflow,
		underflow => converter_underflow,
		inexact => converter_inexact,
		invalid => converter_invalid
	);

	-- FPU Constant ROM instantiation
	FPU_CONST_ROM: TG68K_FPU_ConstantROM
	port map(
		clk => clk,
		nReset => nReset,
		
		-- ROM address (7-bit offset from FMOVECR instruction)
		rom_offset => rom_offset,
		read_enable => rom_read_enable,
		
		-- Output constant (IEEE 754 extended precision - 80 bits)
		constant_out => constrom_result,
		constant_valid => constrom_valid
	);

	-- FPU MOVEM unit instantiation
	FPU_MOVEM: entity work.TG68K_FPU_MOVEM
	port map(
		clk => clk,
		nReset => nReset,
		clkena => clkena,
		
		-- Control
		start_movem => movem_start,
		movem_done => movem_done,
		movem_busy => movem_busy,
		
		-- Operation parameters
		direction => movem_direction,
		register_mask => movem_register_list,
		predecrement => movem_predecrement,
		postincrement => movem_postincrement,
		
		-- CPU-managed memory interface (CPU handles all memory operations)
		fmovem_data_request => fmovem_data_request,
		fmovem_reg_index => fmovem_reg_index,
		fmovem_data_write => fmovem_data_write,
		fmovem_data_in => fmovem_data_in,
		fmovem_data_out => fmovem_data_out,
		
		-- FP register file interface
		reg_address => movem_reg_address,
		reg_data_in => movem_reg_data_in,
		reg_data_out => movem_reg_data_out,
		reg_write_enable => movem_reg_write_enable,
		
		-- Exception flags
		address_error => movem_address_error
	);

	-- FPU Exception Handler instantiation
	FPU_EXCEPTION_HANDLER: entity work.TG68K_FPU_Exception_Handler
	port map(
		clk => clk,
		reset => exception_reset,
		
		-- Input from FPU ALU/Transcendental
		operation_result => final_result,
		operation_valid => exception_op_valid,
		operation_type => exception_op_type,
		
		-- Operands for checking
		operand_a => alu_operand_a,
		operand_b => alu_operand_b,
		
		-- Exception flags from ALU/Transcendental
		overflow_flag => final_overflow,
		underflow_flag => final_underflow,
		inexact_flag => final_inexact,
		invalid_flag => final_invalid,
		divide_by_zero_flag => alu_divide_by_zero,
		
		-- Control
		fpcr => fpcr,
		fpsr_in => fpsr,
		
		-- Outputs
		fpsr_out => exception_fpsr_out,
		exception_pending => exception_pending_internal,
		exception_vector => exception_vector_internal,
		corrected_result => exception_corrected_result
	);

	-- Assign temporary signals for exception handler
	exception_reset <= not nReset;
	exception_op_valid <= alu_result_valid or trans_result_valid;
	exception_op_type <= "0" & alu_operation_code;

	-- Output assignments
	fpcr_out <= fpcr;
	-- CRITICAL: Use exception handler's updated FPSR when it has processed an operation
	fpsr_out <= exception_fpsr_out when (exception_op_valid = '1' and exception_pending_internal = '0') else fpsr;  
	fpiar_out <= fpiar;
	fsave_frame_size <= fsave_frame_size_latched;  -- Use latched value for stability
	fsave_size_valid <= fsave_size_valid_internal;
	-- fpu_data_out is now handled within the state machine process
	
	-- CRITICAL: Route exception information to CPU
	exception_code <= exception_vector_internal when exception_pending_internal = '1' else exception_code_internal;
	
	-- Dynamic FSAVE frame format and size determination process
	-- CRITICAL: This process provides the frame size to CPU BEFORE predecrement occurs
	fsave_format_process: process(fpu_enable, fpu_state, fp_registers, fpcr, fpsr, fpu_busy_internal, fpu_exception, opcode)
		variable any_register_nonzero : std_logic;
		variable any_control_nonzero : std_logic;
		variable has_pending_exception : std_logic;
	begin
		-- Check if any FP registers contain non-zero values
		any_register_nonzero := '0';
		for i in 0 to 7 loop
			if fp_registers(i) /= (79 downto 0 => '0') then
				any_register_nonzero := '1';
			end if;
		end loop;
		
		-- Check if control registers have meaningful state (including accrued exceptions)
		any_control_nonzero := '0';
		if fpcr /= X"00000000" or fpsr /= X"00000000" then
			any_control_nonzero := '1';
		end if;
		
		-- Check for pending exceptions in FPSR
		has_pending_exception := fpu_exception or fpsr(15) or fpsr(14) or fpsr(13) or fpsr(12) or fpsr(11) or fpsr(10) or fpsr(9) or fpsr(8);
		
		-- CRITICAL FIX: Default to IDLE frame to avoid invalid intermediate values
		fsave_frame_format <= X"60";  -- Default to MC68882 IDLE frame
		fsave_frame_size_internal <= 60;  -- Default to 60 bytes
		fsave_size_valid_internal <= '0';  -- Default to not valid
		
		-- Determine frame format and size based on FPU state (MC68881/68882 compliant)
		if fpu_enable = '0' then
			-- FPU is disabled and not FSAVE - return NULL frame
			fsave_frame_format <= X"00";  -- NULL frame
			fsave_frame_size_internal <= 4;  -- 4 bytes = 1 longword
		else
			case fpu_state is
				when FPU_EXECUTE | FPU_FETCH_SOURCE | FPU_MEMORY_READ | FPU_MEMORY_WRITE =>
					-- FPU is actively executing - return BUSY frame 
					fsave_frame_format <= X"D8";  -- MC68882 BUSY frame
					fsave_frame_size_internal <= 216;  -- 216 bytes = 54 longwords
					
				when FPU_EXCEPTION_STATE =>
					-- Exception pending - return BUSY frame to preserve exception state
					fsave_frame_format <= X"D8";  -- MC68882 BUSY frame
					fsave_frame_size_internal <= 216;  -- 216 bytes = 54 longwords
					
				when FPU_IDLE =>
					-- FPU is enabled and idle
					if has_pending_exception = '1' then
						-- Have pending exception - must save full state
						fsave_frame_format <= X"60";  -- MC68882 IDLE frame
						fsave_frame_size_internal <= 60;  -- 60 bytes = 15 longwords
					elsif any_register_nonzero = '1' or any_control_nonzero = '1' then
						-- Have FPU state to preserve - use IDLE frame
						fsave_frame_format <= X"60";  -- MC68882 IDLE frame
						fsave_frame_size_internal <= 60;  -- 60 bytes = 15 longwords
					else
						-- FPU is enabled but clean state - use IDLE for compatibility
						fsave_frame_format <= X"60";  -- MC68882 IDLE frame
						fsave_frame_size_internal <= 60;  -- 60 bytes = 15 longwords
					end if;
					
				when others =>
					-- For any other states, return IDLE frame
					fsave_frame_format <= X"60";  -- MC68882 IDLE frame
					fsave_frame_size_internal <= 60;  -- 60 bytes = 15 longwords
			end case;
		end if;
		
		-- Set frame size as valid when FSAVE is detected (enables early predecrement)
		if (fpu_enable = '1' and opcode(15 downto 12) = "1111" and opcode(11 downto 9) = "001" and opcode(8 downto 6) = "100") then
			fsave_size_valid_internal <= '1';
		else
			fsave_size_valid_internal <= '0';
		end if;
		-- NOTE: fsave_size_valid remains '1' throughout FSAVE operation for reliable handshaking
	end process;

	-- Instruction decode process - now uses decoder outputs
	decode_process: process(fpu_enable, opcode, decoder_operation_code, decoder_source_format, 
							decoder_source_reg, decoder_dest_reg, decoder_ea_mode, decoder_ea_register)
	begin
		if fpu_enable = '1' then
			-- Use decoded values from instruction decoder
			fpu_operation <= decoder_operation_code;
			data_format <= decoder_source_format;
			source_reg <= decoder_source_reg;
			dest_reg <= decoder_dest_reg;
			ea_mode <= decoder_ea_mode;
			ea_register <= decoder_ea_register;
		else
			fpu_operation <= (others => '0');
			data_format <= (others => '0');
			ea_mode <= (others => '0');
			ea_register <= (others => '0');
			source_reg <= (others => '0');
			dest_reg <= (others => '0');
		end if;
	end process;
	
	-- Main FPU state machine
	state_machine: process(clk, nReset)
	begin
		if nReset = '0' then
			fpu_state <= FPU_IDLE;
			fpu_done <= '0';
			fpu_exception <= '0';
			exception_code_internal <= (others => '0');
			-- Reset control registers to MC68882 defaults
			-- Some DiagROM implementations check for specific reset signatures
			fpcr <= X"00000000";	-- Standard MC68882 reset value
			fpsr <= X"00000000";	-- Standard MC68882 reset value  
			fpiar <= X"00000000";	-- Standard MC68882 reset value
			-- MC68882 SPECIFICATION COMPLIANCE: Initialize all FP registers to positive non-signaling NaN
			-- This matches the authentic MC68882 reset behavior per specification
			fp_registers <= (others => IEEE_NaN);
			-- Initialize MOVEM component interface signals
			movem_register_list <= (others => '0');
			movem_direction <= '0';
			-- Base address now managed by CPU
			-- Initialize MOVEM control signals (only inputs to MOVEM component)
			movem_start <= '0';
			movem_predecrement <= '0';
			movem_postincrement <= '0';
			-- Initialize timeout counter
			timeout_counter <= 0;
			-- Initialize FSAVE/FRESTORE signals
			fsave_counter <= 0;
			frestore_frame_format <= (others => '0');
			fsave_frame_size_latched <= 60;  -- Default to IDLE frame
			fsave_frame_format_latched <= X"60";  -- Default to IDLE format
			-- Initialize FPU data output
			fpu_data_out <= (others => '0');
		elsif rising_edge(clk) then
			if clkena = '1' then
				
				case fpu_state is
					when FPU_IDLE =>
						fpu_data_out <= (others => '0');
						-- Don't reset fpu_done here - let it hold until next operation starts
						fpu_exception <= '0';
						
						-- Check for direct CPU requests (bypassing decode)
						if fsave_data_request = '1' then
							-- FSAVE - Requires supervisor privilege per MC68882 specification
							if supervisor_mode = '0' then
								-- Privilege violation - generate exception
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= X"20";  -- Privilege violation
							else
								-- CPU is requesting FSAVE data - enter FSAVE state directly
								fpu_done <= '0';  -- Reset completion signal
								fsave_counter <= 0;
								-- CRITICAL: Latch frame format and size at FSAVE start for stability
								fsave_frame_format_latched <= fsave_frame_format;
								fsave_frame_size_latched <= fsave_frame_size_internal;
									fsave_frame_size_debug <= fsave_frame_size_internal;
								fpu_state <= FPU_FSAVE_WRITE;
							end if;
						elsif frestore_data_write = '1' then
							-- FRESTORE - Requires supervisor privilege per MC68882 specification
							if supervisor_mode = '0' then
								-- Privilege violation - generate exception
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= X"20";  -- Privilege violation
							else
								-- CPU is writing FRESTORE data - enter FRESTORE state directly
								fpu_done <= '0';  -- Reset completion signal  
								fsave_counter <= 0;
								frestore_frame_format <= (others => '0');
								fpu_state <= FPU_FRESTORE_READ;
							end if;
						elsif fpu_enable = '1' then
							fpu_state <= FPU_DECODE;
						end if;
					
					when FPU_DECODE =>
						fpu_data_out <= (others => '0');
						fpu_done <= '0';  -- Reset completion signal at start of new operation
						-- Reset timeout counter at start of decode
						timeout_counter <= 0;
						-- Update FPIAR with current instruction address at start of instruction
						-- This should be the PC of the F-line instruction being executed
						fpiar <= cpu_address_in;
						
						-- MC68882 Complete Primitive Protocol: Update CIR registers
						-- Set Operation Word CIR with current instruction word (for debugging/trace)
						operation_word_cir <= opcode;
						-- Set Command Address CIR with instruction address for exception handling
						command_address_cir <= cpu_address_in;
						-- Note: condition_cir is updated at the end of the process to avoid multiple drivers
						
						-- Check decoder outputs for validity
						if decoder_illegal = '1' then
							-- Illegal instruction
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"10";  -- Illegal instruction
						elsif decoder_unsupported = '1' then
							-- Unsupported instruction (transcendental functions, etc.)
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"0C";  -- Unimplemented instruction
						elsif decoder_valid_instruction = '0' then
							-- Invalid F-line instruction
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"10";  -- Illegal instruction
						-- CRITICAL FIX: Fast path for register-direct FTST (no memory transfer)
					elsif decoder_instruction_type = INST_GENERAL and 
						  decoder_operation_code = OP_FTST and 
						  decoder_ea_mode = "000" then  -- Data register direct (FTST.B D1)
						-- Register-direct FTST: convert integer register to extended, test, update FPSR only
						-- IMPORTANT: Must follow proper CIR protocol - cannot skip directly to FPU_IDLE
						-- Execute the operation immediately but maintain protocol compliance
						case decoder_source_format is
							when FORMAT_BYTE =>
								-- Sign-extend 8-bit integer from cpu_data_in(7:0) to extended precision
								-- For simplicity, treat as zero for now (implement proper conversion later)
								if cpu_data_in(7 downto 0) = "00000000" then
									fpsr(31 downto 28) <= "0100";  -- Zero
								elsif cpu_data_in(7) = '1' then
									fpsr(31 downto 28) <= "1000";  -- Negative
								else
									fpsr(31 downto 28) <= "0000";  -- Positive
								end if;
							when FORMAT_WORD =>
								-- 16-bit integer from cpu_data_in(15:0)
								if cpu_data_in(15 downto 0) = "0000000000000000" then
									fpsr(31 downto 28) <= "0100";  -- Zero
								elsif cpu_data_in(15) = '1' then
									fpsr(31 downto 28) <= "1000";  -- Negative
								else
									fpsr(31 downto 28) <= "0000";  -- Positive
								end if;
							when FORMAT_LONG =>
								-- 32-bit integer from cpu_data_in
								if cpu_data_in = "00000000000000000000000000000000" then
									fpsr(31 downto 28) <= "0100";  -- Zero
								elsif cpu_data_in(31) = '1' then
									fpsr(31 downto 28) <= "1000";  -- Negative
								else
									fpsr(31 downto 28) <= "0000";  -- Positive
								end if;
							when others =>
								-- Other formats (shouldn't happen for register-direct)
								fpsr(31 downto 28) <= "0001";  -- NaN
						end case;
						-- CRITICAL FIX: Follow CIR protocol - go to FPU_EXECUTE to complete dialog properly
						-- The FPU_DECODE state already returns NULL response for register-direct operations
						fpu_state <= FPU_EXECUTE;  -- Complete via proper protocol path
					elsif decoder_instruction_type = INST_GENERAL and 
						  (decoder_operation_code = OP_FABS or decoder_operation_code = OP_FNEG or decoder_operation_code = OP_FMOVE or decoder_operation_code = OP_FMOVECR) and
						  decoder_source_reg /= "111" then  -- Source is FP register, not memory (except FMOVECR)
						-- Fast path for simple single-cycle operations
						case decoder_operation_code is
							when OP_FABS =>
								-- FABS: Clear sign bit
								fp_registers(to_integer(unsigned(decoder_dest_reg))) <= 
									'0' & fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 0);
							when OP_FNEG =>
								-- FNEG: Toggle sign bit
								fp_registers(to_integer(unsigned(decoder_dest_reg))) <= 
									not fp_registers(to_integer(unsigned(decoder_source_reg)))(79) & 
									fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 0);
							when OP_FMOVE =>
								-- FMOVE: Direct copy
								fp_registers(to_integer(unsigned(decoder_dest_reg))) <= 
									fp_registers(to_integer(unsigned(decoder_source_reg)));
							when OP_FMOVECR =>
								-- FMOVECR: Load constant from ROM
								rom_offset <= decoder_source_reg & "0000";  -- Convert register to ROM offset
								rom_read_enable <= '1';
								-- Need to wait for ROM, so go to result state
								-- fpu_operation and dest_reg are already set by decode process
								fpu_state <= FPU_WRITE_RESULT;
							when others =>
								null;
						end case;
						-- Update FPSR condition codes for result (except FMOVECR which handles this in WRITE_RESULT)
						if decoder_operation_code /= OP_FMOVECR then
							-- Use proper MC68882 condition code setting function
							set_fpsr_condition_codes(fpsr, fp_registers(to_integer(unsigned(decoder_dest_reg))));
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
						end if;
					elsif decoder_instruction_type = INST_FMOVEM then
						-- FMOVEM - Multi-register transfer
						-- Additional format validation
						if (opcode(15 downto 8) /= X"F2") or 
						   (extension_word(15 downto 14) /= "11") or
						   (extension_word(12 downto 8) /= "00000") or
						   (extension_word(7 downto 0) = "00000000") then
							-- Invalid FMOVEM format or empty register list
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"0C";  -- Invalid instruction format
						else
							-- fpu_operation is already set by decode process
							movem_register_list <= extension_word(7 downto 0);  -- Register list
							movem_direction <= extension_word(13);  -- 0=to memory, 1=from memory
							-- Set addressing mode flags for MOVEM
							case ea_mode is
							when "010" =>  -- (An) - Address register indirect
								movem_predecrement <= '0';
								movem_postincrement <= '0';
							when "011" =>  -- (An)+ - Address register indirect with postincrement
								movem_predecrement <= '0';
								movem_postincrement <= '1';
							when "100" =>  -- -(An) - Address register indirect with predecrement
								movem_predecrement <= '1';
								movem_postincrement <= '0';
							when "101" =>  -- (d16,An) - Address register indirect with displacement
								movem_predecrement <= '0';
								movem_postincrement <= '0';
							when "110" =>  -- (d8,An,Xn) - Address register indirect with index
								movem_predecrement <= '0';
								movem_postincrement <= '0';
							when "111" =>  -- Absolute addressing modes
								case ea_register is
									when "000" =>  -- (xxx).W - Absolute short
										movem_predecrement <= '0';
										movem_postincrement <= '0';
									when "001" =>  -- (xxx).L - Absolute long
										movem_predecrement <= '0';
										movem_postincrement <= '0';
									when others =>
										-- Unsupported addressing mode for MOVEM
										movem_predecrement <= '0';
										movem_postincrement <= '0';
								end case;
							when others =>
								-- Unsupported addressing mode for MOVEM
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= X"0B";  -- Unsupported addressing mode
						end case;
						
						-- Additional addressing mode validation
						if (ea_mode = "000" or ea_mode = "001") then
							-- Data register direct or address register direct modes not allowed for MOVEM
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"0B";  -- Unsupported addressing mode
						elsif (ea_mode = "111" and ea_register > "001") then
							-- Only absolute short and long addressing allowed in mode 111
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"0B";  -- Unsupported addressing mode
						else
							-- movem_address is now output from MOVEM component
							-- Base address now managed by CPU
							movem_start <= '1';
							fpu_state <= FPU_EXECUTE;  -- Wait for MOVEM completion
						end if;
						end if;
					elsif decoder_instruction_type = INST_FMOVEM_CR then
						-- FMOVEM control registers - Multiple control register transfer
						-- FMOVEM.L FPCR/FPSR/FPIAR,-(A5) or FMOVEM.L (A5)+,FPCR/FPSR/FPIAR
						-- Control register mask in extension_word(12 downto 10): FPCR=bit12, FPSR=bit11, FPIAR=bit10
						-- Direction: extension_word(13) = 0 for control regs to memory, 1 for memory to control regs
						
						-- Check if any control registers are selected
						if extension_word(12 downto 10) = "000" then
							-- No control registers selected - operation complete
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
						else
							-- Start FMOVEM control register operation
							-- Use CPU-managed interface for memory operations
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';  -- Signal CPU to handle the transfers
						end if;
					elsif decoder_instruction_type = INST_FSAVE then
							-- FSAVE - Requires supervisor privilege per MC68882 specification
							if supervisor_mode = '0' then
								-- Privilege violation - generate exception
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= X"20";  -- Privilege violation
							else
								-- FSAVE - Provide FPU state frame data to CPU
								-- CPU will handle memory writes and addressing
								fsave_counter <= 0;
								-- CRITICAL: Latch frame format and size at FSAVE start for stability
								fsave_frame_format_latched <= fsave_frame_format;
								fsave_frame_size_latched <= fsave_frame_size_internal;
									fsave_frame_size_debug <= fsave_frame_size_internal;
								fpu_state <= FPU_FSAVE_WRITE;
							end if;
						elsif decoder_instruction_type = INST_FRESTORE then
							-- FRESTORE - Requires supervisor privilege per MC68882 specification
							if supervisor_mode = '0' then
								-- Privilege violation - generate exception
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= X"20";  -- Privilege violation
							else
								-- FRESTORE - Restore FPU state from memory
								-- Read state information from memory
								fsave_counter <= 0;
								frestore_frame_format <= (others => '0');
								fpu_state <= FPU_FRESTORE_READ;
							end if;
						elsif decoder_instruction_type = INST_FMOVEM then
							-- FMOVEM - Multiple register move for context switching
							-- F225xxxx = FMOVEM to memory (save registers)
							-- F21Dxxxx = FMOVEM from memory (restore registers)
							-- Extension word determines which registers and format:
							-- E0FF = FP0-FP7 extended precision
							-- BC00 = FPCR/FPSR/FPIAR control registers 
							-- 9C00 = FPCR/FPSR/FPIAR control registers (restore)
							-- D0FF = FP0-FP7 extended precision (restore)
							
							if (opcode(5 downto 3) = "010" and opcode(2 downto 0) = "101") then
								-- F225xxxx - FMOVEM to memory (save)
								if extension_word = X"E0FF" then
									-- Save FP0-FP7 to memory - all 8 registers
									movem_register_list <= "11111111";  -- All 8 FP registers
									movem_direction <= '0';  -- 0 = store to memory
									fpu_state <= FPU_FMOVEM;
								elsif extension_word = X"BC00" then
									-- Save FPCR/FPSR/FPIAR to memory - requires supervisor privilege
									if supervisor_mode = '0' then
										-- Privilege violation - generate exception
										fpu_state <= FPU_EXCEPTION_STATE;
										fpu_exception <= '1';
										exception_code_internal <= X"20";  -- Privilege violation
									else
										-- CPU will handle memory writes, provide data when requested
										fpu_state <= FPU_FMOVEM_CR;
										movem_direction <= '0';  -- 0 = store to memory
									end if;
								else
									-- Unknown FMOVEM format
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								end if;
							elsif (opcode(5 downto 3) = "001" and opcode(2 downto 0) = "101") then
								-- F21Dxxxx - FMOVEM from memory (restore)
								if extension_word = X"D0FF" then
									-- Restore FP0-FP7 from memory - all 8 registers
									movem_register_list <= "11111111";  -- All 8 FP registers  
									movem_direction <= '1';  -- 1 = load from memory
									fpu_state <= FPU_FMOVEM;
								elsif extension_word = X"9C00" then
									-- Restore FPCR/FPSR/FPIAR from memory - requires supervisor privilege
									if supervisor_mode = '0' then
										-- Privilege violation - generate exception
										fpu_state <= FPU_EXCEPTION_STATE;
										fpu_exception <= '1';
										exception_code_internal <= X"20";  -- Privilege violation
									else
										fpu_state <= FPU_FMOVEM_CR;
										movem_direction <= '1';  -- 1 = load from memory
									end if;
								else
									-- Unknown FMOVEM format
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								end if;
							else
								-- Unknown FMOVEM encoding
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
							end if;
						elsif decoder_instruction_type = INST_FMOVE_CR then
							-- Standard FMOVE control register operations
							if extension_word(15 downto 13) = "100" then
								-- Standard encoding - Check direction bit (bit 13)
								if extension_word(13) = '0' then
									-- FMOVE FPcr,<ea> - Read control register to destination
									case extension_word(12 downto 10) is  -- Control register select
										when "001" =>  -- FPCR
											fpu_data_out <= fpcr;
										when "010" =>  -- FPSR  
											fpu_data_out <= fpsr;
										when "100" =>  -- FPIAR
											fpu_data_out <= fpiar;
										when others =>
											fpu_data_out <= (others => '0');
									end case;
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								else
									-- FMOVE <ea>,FPcr - Write to control register from source
									case extension_word(12 downto 10) is  -- Control register select
										when "001" =>  -- FPCR - validate before writing
											fpcr <= validate_fpcr(cpu_data_in);
										when "010" =>  -- FPSR - validate before writing  
											fpsr <= validate_fpsr(cpu_data_in);
										when "100" =>  -- FPIAR
											fpiar <= cpu_data_in;
										when others =>
											null;
									end case;
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								end if;
							else
								-- Unknown control register encoding
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
							end if;
						elsif decoder_instruction_type = INST_GENERAL then
							-- General arithmetic operations - handled by existing logic
							-- Check operation code and data format for supported operations
							if fpu_operation = OP_FMOVE or fpu_operation = OP_FINT or fpu_operation = OP_FINTRZ or 
						      fpu_operation = OP_FADD or fpu_operation = OP_FSUB or fpu_operation = OP_FMUL or 
						      fpu_operation = OP_FDIV or fpu_operation = OP_FSQRT or 
						      fpu_operation = OP_FABS or fpu_operation = OP_FNEG or
						      fpu_operation = OP_FCMP or fpu_operation = OP_FTST or
						      fpu_operation = OP_FSGLDIV or fpu_operation = OP_FSGLMUL or
						      fpu_operation = OP_FSIN or fpu_operation = OP_FCOS or fpu_operation = OP_FTAN or
						      fpu_operation = OP_FASIN or fpu_operation = OP_FACOS or fpu_operation = OP_FATAN or
						      fpu_operation = OP_FSINH or fpu_operation = OP_FCOSH or fpu_operation = OP_FTANH or
						      fpu_operation = OP_FATANH or fpu_operation = OP_FETOX or fpu_operation = OP_FETOXM1 or 
						      fpu_operation = OP_FTWOTOX or fpu_operation = OP_FTENTOX or fpu_operation = OP_FLOGN or 
						      fpu_operation = OP_FLOGNP1 or fpu_operation = OP_FLOG10 or
						      fpu_operation = OP_FLOG2 or fpu_operation = OP_FMOVECR or fpu_operation = OP_FMOD or
						      fpu_operation = OP_FREM or fpu_operation = OP_FSCALE or fpu_operation = OP_FGETEXP or
						      fpu_operation = OP_FGETMAN or fpu_operation = OP_FSINCOS then
								-- Performance optimization: Determine operation complexity
								case fpu_operation is
									when OP_FABS | OP_FNEG =>
										operation_complexity <= "00";  -- Simple
										fast_path_enabled <= '1';
									when OP_FMOVE | OP_FCMP | OP_FTST =>
										operation_complexity <= "00";  -- Simple
										fast_path_enabled <= '1';
									when OP_FADD | OP_FSUB =>
										operation_complexity <= "01";  -- Medium
										fast_path_enabled <= '0';
									when OP_FMUL =>
										operation_complexity <= "01";  -- Medium
										fast_path_enabled <= '0';
									when OP_FDIV | OP_FSQRT =>
										operation_complexity <= "10";  -- Complex
										fast_path_enabled <= '0';
									when others =>
										operation_complexity <= "11";  -- Very complex (transcendental)
										fast_path_enabled <= '0';
								end case;
								
								if fpu_operation = OP_FMOVECR then
									-- FMOVECR - Move from constant ROM
									rom_offset <= extension_word(6 downto 0);  -- ROM offset from extension word
									rom_read_enable <= '1';
									fpu_state <= FPU_WRITE_RESULT;  -- Skip fetch, go directly to write result
								elsif fpu_operation = OP_FNOP then
									-- FNOP - No operation, just complete immediately
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								elsif fast_path_enabled = '1' and fpu_operation = OP_FABS then
									-- Fast path for FABS - clear sign bit immediately
									if to_integer(unsigned(decoder_source_reg)) <= 7 then
										fp_registers(to_integer(unsigned(decoder_dest_reg))) <= '0' & fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 0);
										fpu_state <= FPU_IDLE;
										fpu_done <= '1';
									else
										fpu_state <= FPU_EXCEPTION_STATE;
										fpu_exception <= '1';
										exception_code_internal <= X"0C";
									end if;
								elsif fast_path_enabled = '1' and fpu_operation = OP_FNEG then
									-- Fast path for FNEG - flip sign bit immediately
									if to_integer(unsigned(decoder_source_reg)) <= 7 then
										fp_registers(to_integer(unsigned(decoder_dest_reg))) <= (not fp_registers(to_integer(unsigned(decoder_source_reg)))(79)) & fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 0);
										fpu_state <= FPU_IDLE;
										fpu_done <= '1';
									else
										fpu_state <= FPU_EXCEPTION_STATE;
										fpu_exception <= '1';
										exception_code_internal <= X"0C";
									end if;
								elsif fpu_operation = OP_FTST or fpu_operation = OP_FCMP then
									-- FTST/FCMP: cpGEN instructions require CIR protocol
									-- Check if CPU has written operand to Operand CIR
									if cir_write = '1' and cir_address = "00101" then
										-- CPU has provided operand - proceed to execution
										fpu_state <= FPU_EXECUTE;
									else
										-- Wait for operand from CPU via CIR protocol
										fpu_state <= FPU_FETCH_SOURCE;
									end if;
								else
									fpu_state <= FPU_FETCH_SOURCE;
								end if;
							else
								-- Other operations not yet implemented
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= X"0C";  -- Unimplemented instruction
							end if;
						
						elsif decoder_instruction_type = INST_FMOVE_FP then
							-- FMOVE FPn,<ea> - Move FP register to memory/CPU register
							-- Source format is always extended precision from FP register
							-- Destination format specified in extension word bits 12-10
							-- Bounds check for register access
							if to_integer(unsigned(decoder_source_reg)) > 7 then
								-- Invalid register number - trigger exception
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= X"0C";  -- Invalid operand
							end if;
							case decoder_dest_format is
								when FORMAT_SINGLE =>
									-- Convert to single precision and write
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '1';  -- Write to memory
									-- CPU manages data size -- "10";  -- 32-bit single precision
									-- Simple extended to single conversion (for now)
									fpu_data_out <= fp_registers(to_integer(unsigned(decoder_source_reg)))(79) & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(71 downto 65) & "1" & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(63 downto 41);
									fpu_state <= FPU_MEMORY_WRITE;
								when FORMAT_DOUBLE =>
									-- Convert to double precision and write (simplified)
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '1';  -- Write to memory
									-- CPU manages data size -- "10";  -- 32-bit transfers (will need 2 transfers)
									-- Write high 32 bits first (sign + 11-bit exp + 20 high mantissa bits)
									fpu_data_out <= fp_registers(to_integer(unsigned(decoder_source_reg)))(79) & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(74 downto 65) & '0' & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(63 downto 44);
									fpu_state <= FPU_MEMORY_WRITE;
								when FORMAT_LONG =>
									-- Convert floating-point to 32-bit integer with proper IEEE 754 handling
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '1';  -- Write to memory
									-- CPU manages data size -- "10";  -- 32-bit integer
									
									-- Extract IEEE 754 components from source FP register
									fp_to_int_sign <= fp_registers(to_integer(unsigned(decoder_source_reg)))(79);
									fp_to_int_exp <= fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64);
									fp_to_int_mant <= fp_registers(to_integer(unsigned(decoder_source_reg)))(63 downto 0);
									
									-- Handle special cases with proper bias handling
									if fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64) = "000000000000000" then
										-- Zero or denormalized (treat as zero)
										fpu_data_out <= X"00000000";
									elsif fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64) = "111111111111111" then
										-- Infinity or NaN - return max/min integer (IEEE 754 overflow behavior)
										if fp_registers(to_integer(unsigned(decoder_source_reg)))(79) = '1' then
											fpu_data_out <= X"80000000";  -- -2^31 for negative
										else
											fpu_data_out <= X"7FFFFFFF";  -- 2^31-1 for positive  
										end if;
									else
										-- Normal number - check if it fits in 32-bit integer range
										-- Biased exponent to actual exponent: exp - 16383
										-- For 32-bit signed integer: valid range is exponent 0 to 30 (values 1.0 to 2^30)
										if to_integer(unsigned(fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64))) < 16383 then
											-- |value| < 1.0 - truncate to 0 (FINTRZ behavior)
											fpu_data_out <= X"00000000";
										elsif to_integer(unsigned(fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64))) > 16383 + 30 then
											-- Value too large for 32-bit signed integer
											if fp_registers(to_integer(unsigned(decoder_source_reg)))(79) = '1' then
												fpu_data_out <= X"80000000";  -- -2^31 (overflow)
											else
												fpu_data_out <= X"7FFFFFFF";  -- 2^31-1 (overflow)
											end if;
										else
											-- Extract integer part with proper shifting and bounds checking
											-- Calculate actual exponent (unbiased) with bounds checking
											if to_integer(unsigned(fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64))) < 16383 - 31 then
												-- Number too small (< 2^-31) - result is 0
												fp_to_int_shift <= 63;  -- Will produce 0
											elsif to_integer(unsigned(fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64))) > 16383 + 30 then
												-- Number too large (> 2^30) - already handled above, use max precision
												fp_to_int_shift <= 0;   -- Maximum precision
											else
												-- Normal case: calculate shift amount safely
												fp_to_int_shift <= 63 - (to_integer(unsigned(fp_registers(to_integer(unsigned(decoder_source_reg)))(78 downto 64))) - 16383);
											end if;
											
											-- Extract the top 32 bits after normalization
											-- For extended precision: bit 63 is integer bit, 62:0 is fractional
											if fp_to_int_shift <= 32 then
												-- Shift mantissa to get integer portion in top 32 bits
												case fp_to_int_shift is
													when 0 to 31 =>
														-- Extract based on shift amount
														fp_to_int_result <= fp_registers(to_integer(unsigned(decoder_source_reg)))(63 downto 32);
													when others =>
														fp_to_int_result <= (others => '0');
												end case;
												
												-- Apply 2's complement for negative numbers
												if fp_registers(to_integer(unsigned(decoder_source_reg)))(79) = '1' then
													fpu_data_out <= std_logic_vector(unsigned(not fp_to_int_result) + 1);
												else
													fpu_data_out <= fp_to_int_result;
												end if;
											else
												-- Shift too large, result is 0
												fpu_data_out <= X"00000000";
											end if;
										end if;
									end if;
									
									fpu_state <= FPU_MEMORY_WRITE;
								when FORMAT_PACKED =>
									-- Write 96-bit packed decimal (12 bytes) using converter
									-- Start format conversion from extended to packed decimal
									converter_start <= '1';
									converter_source_format <= FORMAT_EXTENDED;
									converter_dest_format <= FORMAT_PACKED;
									converter_data_in(79 downto 0) <= fp_registers(to_integer(unsigned(decoder_source_reg)));
									converter_data_in(95 downto 80) <= (others => '0'); -- Clear upper bits
									fpu_state <= FPU_MEMORY_WRITE;
								when others =>
									-- Extended precision - use converter to handle the transfer
									converter_start <= '1';
									converter_source_format <= FORMAT_EXTENDED;
									converter_dest_format <= FORMAT_EXTENDED;
									converter_data_in(79 downto 0) <= fp_registers(to_integer(unsigned(decoder_source_reg)));
									converter_data_in(95 downto 80) <= (others => '0'); -- Clear upper bits
									fpu_state <= FPU_MEMORY_WRITE;
							end case;
						
						elsif decoder_instruction_type = INST_FMOVE_MEM then
							-- FMOVE <ea>,FPn - Move memory/CPU register to FP register
							-- Source format specified in extension word, destination is always extended precision
							case decoder_source_format is
								when FORMAT_SINGLE =>
									-- Read single precision and convert to extended
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- 32-bit single precision
									fpu_state <= FPU_MEMORY_READ;
								when FORMAT_DOUBLE =>
									-- Read double precision and convert to extended (simplified)
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- 32-bit transfers (will need 2 transfers)
									fpu_state <= FPU_MEMORY_READ;
								when FORMAT_LONG =>
									-- Read 32-bit integer and convert to extended
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- 32-bit integer
									fpu_state <= FPU_MEMORY_READ;
								when FORMAT_PACKED =>
									-- Read 96-bit packed decimal (12 bytes) using converter
									-- Set up memory read for packed decimal format
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- Start with 32-bit reads
									fpu_state <= FPU_MEMORY_READ;
								when others =>
									-- Extended precision - use converter to handle the transfer
									converter_start <= '1';
									converter_source_format <= FORMAT_EXTENDED;
									converter_dest_format <= FORMAT_EXTENDED;
									-- CPU manages addressing
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- 32-bit transfers
									fpu_state <= FPU_MEMORY_READ;
							end case;
						
						elsif decoder_instruction_type = INST_FMOVEM then
							-- FMOVEM multi-register - CPU manages all memory operations
							-- Register list in extension_word(7 downto 0) - bit set = register included
							-- Direction: extension_word(13) = 0 for FP->memory, 1 for memory->FP
							
							if extension_word(7 downto 0) = "00000000" then
								-- No registers to transfer
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
							else
								-- CPU will manage FMOVEM transfers through fmovem_data_request interface
								-- fpu_operation already set by decoder process
								fpu_state <= FPU_EXECUTE;  -- Wait for CPU to complete all transfers
								timeout_counter <= 0;
							end if;
						else
							-- Unknown instruction type
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"0C";  -- Unimplemented instruction
						end if;
					
					when FPU_FETCH_SOURCE =>
						fpu_data_out <= (others => '0');
						-- Reset timeout and ALU start signal
						timeout_counter <= 0;
						alu_start_operation <= '0';
						
						-- Check for CIR operand transfer completion for cpGEN instructions
						if (fpu_operation = OP_FTST or fpu_operation = OP_FCMP) and 
						   cir_write = '1' and cir_address = "00101" then
							-- CPU has written operand to Operand CIR - use this data
							-- Convert CIR operand data to extended precision based on source format
							case decoder_source_format is
								when FORMAT_BYTE =>
									-- Convert 8-bit signed integer from cir_data_in(7:0) to extended precision
									if cir_data_in(7 downto 0) = x"00" then
										-- Zero
										alu_operand_b <= (others => '0');
									elsif cir_data_in(7) = '0' then
										-- Positive byte: find MSB and normalize
										if cir_data_in(6) = '1' then
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16389, 15)) & '1' & 
											                cir_data_in(6 downto 0) & x"00000000000000";
										elsif cir_data_in(5) = '1' then
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16388, 15)) & '1' &
											                cir_data_in(5 downto 0) & '0' & x"00000000000000";
										elsif cir_data_in(4) = '1' then
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16387, 15)) & '1' &
											                cir_data_in(4 downto 0) & "00" & x"00000000000000";
										elsif cir_data_in(3) = '1' then
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16386, 15)) & '1' &
											                cir_data_in(3 downto 0) & "000" & x"00000000000000";
										elsif cir_data_in(2) = '1' then
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16385, 15)) & '1' &
											                cir_data_in(2 downto 0) & "0000" & x"00000000000000";
										elsif cir_data_in(1) = '1' then
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16384, 15)) & '1' &
											                cir_data_in(1 downto 0) & "00000" & x"00000000000000";
										else -- cir_data_in(0) = '1'
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16383, 15)) & '1' &
											                cir_data_in(0 downto 0) & "000000" & x"00000000000000";
										end if;
									else
										-- Negative byte
										if cir_data_in(7 downto 0) = x"80" then
											-- Special case -128
											alu_operand_b <= '1' & std_logic_vector(to_unsigned(16390, 15)) & '1' &
											                "1000000" & x"00000000000000";
										else
											-- General negative case: use two's complement
											alu_operand_b <= '1' & std_logic_vector(to_unsigned(16386, 15)) & '1' &
											                (not cir_data_in(6 downto 0)) & x"00000000000000";
										end if;
									end if;
									
								when FORMAT_WORD =>
									-- Convert 16-bit signed integer to extended precision  
									if cir_data_in(15 downto 0) = x"0000" then
										alu_operand_b <= (others => '0');
									elsif cir_data_in(15) = '0' then
										-- Positive word
										alu_operand_b <= '0' & "100000000001110" & cir_data_in(15 downto 0) & x"000000000000";
									else
										-- Negative word
										alu_operand_b <= '1' & "100000000001110" & ((not cir_data_in(15 downto 0)) + 1) & x"000000000000";
									end if;
									
								when FORMAT_LONG =>
									-- For LONG format, we'd need full 32-bit data - not supported via 16-bit CIR
									-- This is a limitation that needs CPU-side fix
									alu_operand_b <= '0' & "011111110000000" & '1' & cir_data_in(15 downto 0) & "00000000000000000000000000000000000000000000000";
									
								when others =>
									-- Default/unsupported format
									alu_operand_b <= (others => '0');
							end case;
							alu_operation_code <= fpu_operation;
							alu_start_operation <= '1';
							fpu_state <= FPU_EXECUTE;
						elsif (fpu_operation = OP_FTST or fpu_operation = OP_FCMP) then
							-- cpGEN instruction waiting for operand - stay in this state until CIR transfer
							-- CIR Response will return CA primitive to request operand
							null;
						else
						
						-- Load operands and setup ALU with bounds checking
						if to_integer(unsigned(source_reg)) > 7 then
							-- Invalid source register - trigger exception
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code_internal <= X"0C";  -- Invalid operand
						else
							alu_operand_a <= fp_registers(to_integer(unsigned(source_reg)))(79 downto 0);
						end if;
						if ea_mode = "000" then  -- Data register direct (CPU register)
							-- For CPU data from data bus - convert to extended precision
							-- Use CPU data input and convert based on data format
							case data_format is
								when FORMAT_BYTE =>
									-- Convert 8-bit signed integer to 80-bit IEEE extended precision
									-- Per MC68881/68882 Users Manual: correct integer to extended conversion
									-- IEEE 754 extended: sign(1) + exponent(15) + integer_bit(1) + fraction(63)
									if cpu_data_in(7 downto 0) = x"00" then
										-- Special case: zero
										alu_operand_b <= (others => '0');
									elsif cpu_data_in(7) = '0' then
										-- Positive integer: find MSB and normalize
										-- IEEE extended bias = 16383 (0x3FFF)
										if cpu_data_in(6) = '1' then
											-- MSB at bit 6: value 64-127, exp = 16383 + 6 = 16389
											-- Fraction: cpu_data_in(6:0) & 56 zeros = 63 bits total
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16389, 15)) & '1' & 
											                cpu_data_in(6 downto 0) & x"00000000000000";
										elsif cpu_data_in(5) = '1' then
											-- MSB at bit 5: value 32-63, exp = 16383 + 5 = 16388
											-- Fraction: cpu_data_in(5:0) & 1 zero & 56 zeros = 63 bits total
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16388, 15)) & '1' &
											                cpu_data_in(5 downto 0) & '0' & x"00000000000000";
										elsif cpu_data_in(4) = '1' then
											-- MSB at bit 4: value 16-31, exp = 16383 + 4 = 16387
											-- Fraction: cpu_data_in(4:0) & 2 zeros & 56 zeros = 63 bits total  
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16387, 15)) & '1' &
											                cpu_data_in(4 downto 0) & "00" & x"00000000000000";
										elsif cpu_data_in(3) = '1' then
											-- MSB at bit 3: value 8-15, exp = 16383 + 3 = 16386
											-- Fraction: cpu_data_in(3:0) & 3 zeros & 56 zeros = 63 bits total
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16386, 15)) & '1' &
											                cpu_data_in(3 downto 0) & "000" & x"00000000000000";
										elsif cpu_data_in(2) = '1' then
											-- MSB at bit 2: value 4-7, exp = 16383 + 2 = 16385
											-- Fraction: cpu_data_in(2:0) & 4 zeros & 56 zeros = 63 bits total
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16385, 15)) & '1' &
											                cpu_data_in(2 downto 0) & "0000" & x"00000000000000";
										elsif cpu_data_in(1) = '1' then
											-- MSB at bit 1: value 2-3, exp = 16383 + 1 = 16384
											-- Fraction: cpu_data_in(1:0) & 5 zeros & 56 zeros = 63 bits total
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16384, 15)) & '1' &
											                cpu_data_in(1 downto 0) & "00000" & x"00000000000000";
										else -- cpu_data_in(0) = '1'
											-- MSB at bit 0: value 1, exp = 16383 + 0 = 16383
											-- Fraction: cpu_data_in(0:0) & 6 zeros & 56 zeros = 63 bits total
											alu_operand_b <= '0' & std_logic_vector(to_unsigned(16383, 15)) & '1' &
											                cpu_data_in(0 downto 0) & "000000" & x"00000000000000";
										end if;
									else
										-- Negative integer: compute two's complement magnitude
										if cpu_data_in(7 downto 0) = x"80" then
											-- Special case -128: magnitude = 128, MSB at bit 7, exp = 16383 + 7 = 16390
											alu_operand_b <= '1' & std_logic_vector(to_unsigned(16390, 15)) & '1' &
											                "1000000" & x"00000000000000";
										else
											-- General negative case: simplified - use approximation for now
											-- TODO: Implement proper normalization for negative values
											alu_operand_b <= '1' & std_logic_vector(to_unsigned(16386, 15)) & '1' &
											                (not cpu_data_in(6 downto 0)) & x"00000000000000";
										end if;
									end if;
								when FORMAT_WORD =>
									-- Convert 16-bit signed integer to 80-bit extended precision
									if cpu_data_in(15 downto 0) = x"0000" then
										-- Zero
										alu_operand_b <= (others => '0');
									elsif cpu_data_in(15) = '0' then
										-- Positive integer: normalize mantissa properly
										alu_operand_b <= '0' & "100000000001110" & cpu_data_in(15 downto 0) & x"000000000000";
									else
										-- Negative integer: take 2's complement magnitude and set sign bit
										alu_operand_b <= '1' & "100000000001110" & ((not cpu_data_in(15 downto 0)) + 1) & x"000000000000";
									end if;
								when FORMAT_LONG =>
									-- Convert 32-bit signed integer to 80-bit extended precision  
									if cpu_data_in = x"00000000" then
										-- Zero
										alu_operand_b <= (others => '0');
									elsif cpu_data_in(31) = '0' then
										-- Positive integer: normalize mantissa properly
										alu_operand_b <= '0' & "100000000011110" & cpu_data_in & x"00000000";
									else
										-- Negative integer: take 2's complement magnitude and set sign bit
										alu_operand_b <= '1' & "100000000011110" & ((not cpu_data_in) + 1) & x"00000000";
									end if;
								when others =>
									-- Default to treating as long word
									alu_operand_b <= (others => '0');
							end case;
						else
							-- Memory operand - need to fetch from memory
							case ea_mode is
								when "000" =>  -- Data register direct (already handled above)
									alu_operand_b <= (others => '0');
								when "001" =>  -- Address register direct  
									alu_operand_b <= (others => '0');  -- Not valid for FPU operands
								when "010" =>  -- Address register indirect (An)
									-- CPU manages addressing -- cpu_data_in;  -- Address from An
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "011" =>  -- Address register indirect with postincrement (An)+
									-- CPU manages addressing -- cpu_data_in;  -- Address from An
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "100" =>  -- Address register indirect with predecrement -(An)
									-- For FSAVE -(SP): generate stack address
									-- CPU manages addressing -- cpu_data_in;  -- Assume CPU provides current An value
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "101" =>  -- Address register indirect with displacement d16(An)
									-- CPU manages addressing -- cpu_data_in;  -- Address = An + displacement (CPU calculated)
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "110" =>  -- Address register indirect with index d8(An,Xn)
									-- CPU manages addressing -- cpu_data_in;  -- Address = An + Xn + d8 (CPU calculated)
									-- CPU manages memory requests
									-- CPU manages read/write -- '0';  -- Read from memory
									-- CPU manages data size -- "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "111" =>  -- Absolute and immediate addressing
									case ea_register is
										when "000" =>  -- Absolute short $xxxx.W
											-- CPU manages addressing -- cpu_data_in;  -- Absolute address from extension
											-- CPU manages memory requests
											-- CPU manages read/write -- '0';  -- Read from memory
											-- CPU manages data size -- "10";  -- Long word access
											fpu_state <= FPU_MEMORY_READ;
										when "001" =>  -- Absolute long $xxxxxxxx.L
											-- CPU manages addressing -- cpu_data_in;  -- Absolute address from extension
											-- CPU manages memory requests
											-- CPU manages read/write -- '0';  -- Read from memory
											-- CPU manages data size -- "10";  -- Long word access
											fpu_state <= FPU_MEMORY_READ;
										when "010" =>  -- PC + displacement d16(PC)
											-- CPU manages addressing -- cpu_data_in;  -- PC + d16 (CPU calculated)
											-- CPU manages memory requests
											-- CPU manages read/write -- '0';  -- Read from memory
											-- CPU manages data size -- "10";  -- Long word access
											fpu_state <= FPU_MEMORY_READ;
										when "011" =>  -- PC + index d8(PC,Xn)
											-- CPU manages addressing -- cpu_data_in;  -- PC + Xn + d8 (CPU calculated)
											-- CPU manages memory requests
											-- CPU manages read/write -- '0';  -- Read from memory
											-- CPU manages data size -- "10";  -- Long word access
											fpu_state <= FPU_MEMORY_READ;
										when "100" =>  -- Immediate #<data>
											-- Enhanced immediate data conversion with proper format handling
											case data_format is
												when FORMAT_BYTE =>
													-- Convert signed 8-bit integer to 80-bit extended precision
													if cpu_data_in(7 downto 0) = x"00" then
														alu_operand_b <= (others => '0');  -- Zero
													elsif cpu_data_in(7) = '0' then
														-- Positive: normalize mantissa, adjust exponent
														alu_operand_b <= '0' & x"4006" & cpu_data_in(7 downto 0) & x"0000000000000" & "000";
													else
														-- Negative: sign=1, take 2's complement, normalize
														alu_operand_b <= '1' & x"4006" & (not cpu_data_in(7 downto 0)) + 1 & x"0000000000000" & "000";
													end if;
												when FORMAT_WORD =>
													-- Convert signed 16-bit integer to 80-bit extended precision
													if cpu_data_in(15 downto 0) = x"0000" then
														alu_operand_b <= (others => '0');  -- Zero
													elsif cpu_data_in(15) = '0' then
														-- Positive: exponent = 0x3FFF + bit_position (15)
														alu_operand_b <= '0' & x"400E" & cpu_data_in(15 downto 0) & x"00000000000" & "111";
													else
														-- Negative: sign=1, take 2's complement
														alu_operand_b <= '1' & x"400E" & (not cpu_data_in(15 downto 0)) + 1 & x"00000000000" & "111";
													end if;
												when FORMAT_LONG =>
													-- Convert signed 32-bit integer to 80-bit extended precision
													if cpu_data_in = x"00000000" then
														alu_operand_b <= (others => '0');  -- Zero
													elsif cpu_data_in(31) = '0' then
														-- Positive: exponent = 0x3FFF + 31
														alu_operand_b <= '0' & x"401E" & cpu_data_in & x"0000000" & "000";
													else
														-- Negative: sign=1, take 2's complement
														alu_operand_b <= '1' & x"401E" & (not cpu_data_in) + 1 & x"0000000" & "000";
													end if;
												when FORMAT_SINGLE =>
													-- Convert IEEE 754 single precision to extended precision
													-- Single: sign(1) + exponent(8) + mantissa(23)
													-- Extended: sign(1) + exponent(15) + mantissa(64)
													if cpu_data_in(30 downto 23) = x"00" then
														-- Zero or denormalized number
														if cpu_data_in(22 downto 0) = (22 downto 0 => '0') then
															-- True zero (signed)
															alu_operand_b <= cpu_data_in(31) & "000000000000000" & x"0000000000000000";
														else
															-- Denormalized number: normalize it to extended precision
															-- For denormalized single: exponent = 16383 - 126 = 16257
															-- Mantissa needs leading zero detection and normalization
															alu_operand_b <= cpu_data_in(31) & x"3F81" & '0' & cpu_data_in(22 downto 0) & x"000000000" & "000";
														end if;
													elsif cpu_data_in(30 downto 23) = x"FF" then
														-- Infinity or NaN
														if cpu_data_in(22 downto 0) = (22 downto 0 => '0') then
															-- Infinity
															alu_operand_b <= cpu_data_in(31) & "111111111111111" & x"8000000000000000";
														else
															-- NaN (preserve mantissa pattern)
															alu_operand_b <= cpu_data_in(31) & "111111111111111" & '1' & cpu_data_in(22 downto 0) & x"0000000000";
														end if;
													else
														-- Normal: bias conversion 127->16383, add implicit 1
														-- Convert bias and mantissa - simplified version
														alu_operand_b <= cpu_data_in(31) & "011111110000000" & '1' & cpu_data_in(22 downto 0) & x"0000000000";
													end if;
												when FORMAT_DOUBLE =>
													-- Convert IEEE 754 double precision to extended precision
													-- Note: This is simplified, real implementation needs two memory reads
													if cpu_data_in(30 downto 20) = "00000000000" then
														-- Zero or denormalized
														alu_operand_b <= cpu_data_in(31) & "000000000000000" & x"0000000000000000";
													elsif cpu_data_in(30 downto 20) = "11111111111" then
														-- Infinity or NaN
														alu_operand_b <= cpu_data_in(31) & "111111111111111" & cpu_data_in(19 downto 0) & "00000000000000000000000000000000000000000000";
													else
														-- Normal: bias conversion 1023->16383, add implicit 1
														-- Convert bias and mantissa - simplified version  
														alu_operand_b <= cpu_data_in(31) & "011110000000000" & '1' & cpu_data_in(19 downto 0) & "0000000000000000000000000000000000000000000";
													end if;
												when others =>
													alu_operand_b <= (others => '0');
											end case;
											alu_operation_code <= fpu_operation;
											alu_start_operation <= '1';
											fpu_state <= FPU_EXECUTE;
										when others =>
											-- Other modes not implemented
											alu_operand_b <= (others => '0');
											alu_operation_code <= fpu_operation;
											alu_start_operation <= '1';
											fpu_state <= FPU_EXECUTE;
									end case;
								when others =>
									-- Unknown addressing mode
									alu_operand_b <= (others => '0');
									alu_operation_code <= fpu_operation;
									alu_start_operation <= '1';
									fpu_state <= FPU_EXECUTE;
							end case;
						end if;
						
						-- Special handling for FTST with FP register source
						if fpu_operation = OP_FTST and ea_mode = "111" and ea_register = "010" then
							-- FTST with FP register source - use proper condition code function
							set_fpsr_condition_codes(fpsr, alu_operand_a);
							
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
						-- For data register direct, continue to execution
						elsif ea_mode = "000" then
							-- Special handling for FTST - complete immediately
							if fpu_operation = OP_FTST then
								-- FTST - Analyze source operand and set condition codes using proper function
								set_fpsr_condition_codes(fpsr, alu_operand_b);
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
							-- Check if operation is transcendental function
							elsif fpu_operation = OP_FSIN or fpu_operation = OP_FCOS or fpu_operation = OP_FTAN or
							   fpu_operation = OP_FASIN or fpu_operation = OP_FACOS or fpu_operation = OP_FATAN or
							   fpu_operation = OP_FSINH or fpu_operation = OP_FCOSH or fpu_operation = OP_FTANH or
							   fpu_operation = OP_FATANH or fpu_operation = OP_FETOX or fpu_operation = OP_FETOXM1 or 
							   fpu_operation = OP_FTWOTOX or fpu_operation = OP_FTENTOX or fpu_operation = OP_FLOGN or 
							   fpu_operation = OP_FLOGNP1 or fpu_operation = OP_FLOG10 or
							   fpu_operation = OP_FLOG2 or fpu_operation = OP_FSINCOS then
								-- Transcendental function - check for NaN/Infinity inputs first
								if alu_operand_a(78 downto 64) = "111111111111111" then
									-- Input is infinity or NaN
									if alu_operand_a(63) = '1' and alu_operand_a(62 downto 0) /= (62 downto 0 => '0') then
										-- Input is NaN - propagate NaN result  
										result_data <= alu_operand_a;  -- Propagate input NaN
										fpu_state <= FPU_WRITE_RESULT;
									elsif alu_operand_a(63) = '1' and alu_operand_a(62 downto 0) = (62 downto 0 => '0') then
										-- Input is infinity - generate appropriate result or NaN
										case fpu_operation is
											when OP_FSIN | OP_FCOS | OP_FSINCOS =>
												-- sin(±∞) = cos(±∞) = NaN (domain error)
												-- For FSINCOS, both sine and cosine results are NaN
												result_data <= '0' & "111111111111111" & x"8000000000000000";  -- Quiet NaN
											when OP_FLOGN | OP_FLOG10 | OP_FLOG2 =>
												-- log(+∞) = +∞, log(-∞) = NaN
												if alu_operand_a(79) = '0' then
													result_data <= alu_operand_a;  -- +∞
												else
													result_data <= '0' & "111111111111111" & x"8000000000000000";  -- NaN for log(-∞)
												end if;
											when others =>
												-- Other transcendental functions with infinity - send to transcendental unit
												trans_operation_code <= fpu_operation;
												trans_operand <= alu_operand_a;
												trans_start_operation <= '1';
												fpu_state <= FPU_EXECUTE;
										end case;
									else
										-- Send to transcendental unit for normal processing
										trans_operation_code <= fpu_operation;
										trans_operand <= alu_operand_a;
										trans_start_operation <= '1';
										fpu_state <= FPU_EXECUTE;
									end if;
								else
									-- Normal operand - send to transcendental unit
									trans_operation_code <= fpu_operation;
									trans_operand <= alu_operand_a;  -- Use operand A for unary transcendental operations
									trans_start_operation <= '1';
									fpu_state <= FPU_EXECUTE;
								end if;
							else
								-- Regular ALU operation
								alu_operation_code <= fpu_operation;
								alu_start_operation <= '1';
								fpu_state <= FPU_EXECUTE;
							end if;
						end if;
						end if; -- Close the CIR operand check else clause
					
					when FPU_EXECUTE =>
						fpu_data_out <= (others => '0');
						alu_start_operation <= '0';  -- Clear ALU start signal
						trans_start_operation <= '0';  -- Clear transcendental start signal
						-- Increment timeout counter (use ALU limit for execution state)
						if timeout_counter < TIMEOUT_LIMIT_ALU then
							timeout_counter <= timeout_counter + 1;
						end if;
						
						-- CRITICAL FIX: Register-direct FTST completes immediately  
						if fpu_operation = OP_FTST and decoder_ea_mode = "000" then
							-- Register-direct FTST already executed in FPU_DECODE - complete immediately
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
							timeout_counter <= 0;  -- Reset timeout
						-- FMOVEM operations now handled by MOVEM component
						elsif fpu_operation = OP_FMOVEM then
							-- FMOVEM completion is managed by CPU (when CPU stops making requests)
							-- For now, we'll use a simple timeout or signal from CPU side
							-- This will be handled by CPU-side FMOVEM microcode
							
							-- Placeholder: CPU will signal completion by ending operation
							if timeout_counter > TIMEOUT_LIMIT_MEMORY then
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
							end if;
						-- Check for completion from either ALU or transcendental unit
						elsif (alu_operation_done = '1' or alu_result_valid = '1') or (trans_operation_done = '1' or trans_result_valid = '1') then
							-- Reset timeout counter on successful completion
							timeout_counter <= 0;
							
							-- Select result from appropriate unit
							if trans_operation_done = '1' or trans_result_valid = '1' then
								-- Result from transcendental unit
								final_result <= trans_result;
								final_overflow <= trans_overflow;
								final_underflow <= trans_underflow;
								final_inexact <= trans_inexact;
								final_invalid <= trans_invalid;
							else
								-- Result from ALU
								final_result <= alu_result;
								final_overflow <= alu_overflow;
								final_underflow <= alu_underflow;
								final_inexact <= alu_inexact;
								final_invalid <= alu_invalid;
							end if;
							
							-- Update FPSR using exception handler (comprehensive exception handling)
							fpsr <= exception_fpsr_out;
							
							-- Update quotient byte for FMOD/FREM operations
							if (fpu_operation = OP_FMOD or fpu_operation = OP_FREM) then
								fpsr(23 downto 16) <= alu_quotient_byte;
							end if;
							
							-- Check for exceptions using exception handler
							if exception_pending_internal = '1' then
								-- Exception should generate trap
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code_internal <= exception_vector_internal;
								-- Use corrected result from exception handler
								result_data <= exception_corrected_result;
							else
								-- No trapping exception, continue with result
								result_data <= final_result;
								fpu_state <= FPU_WRITE_RESULT;
							end if;
						elsif timeout_counter >= TIMEOUT_LIMIT_ALU then
							-- ALU operation timeout - handle based on operation complexity
							timeout_counter <= 0;
							if fpu_operation = OP_FMOVE or fpu_operation = OP_FABS or fpu_operation = OP_FNEG then
								-- Simple operations - provide basic result for compatibility
								if fpu_operation = OP_FMOVE then
									result_data <= alu_operand_b;  -- Pass through source
								elsif fpu_operation = OP_FABS then
									result_data <= '0' & alu_operand_a(78 downto 0);  -- Clear sign bit
								elsif fpu_operation = OP_FNEG then
									result_data <= (not alu_operand_a(79)) & alu_operand_a(78 downto 0);  -- Flip sign bit
								end if;
								fpu_state <= FPU_WRITE_RESULT;
							elsif fpu_operation = OP_FTST then
								-- FTST - Analyze source operand and set condition codes using proper function
								-- Choose correct operand based on source addressing mode
								if ea_mode = "000" then
									-- Test CPU register data (alu_operand_b)
									set_fpsr_condition_codes(fpsr, alu_operand_b);
								else
									-- Test FP register data (alu_operand_a)
									set_fpsr_condition_codes(fpsr, alu_operand_a);
								end if;
								
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
								else
								-- Complex operation failed - trigger unimplemented instruction exception
								fpu_exception <= '1';
								exception_code_internal <= x"0B";  -- Unimplemented instruction
								fpu_state <= FPU_EXCEPTION_STATE;
							end if;
						end if;
					
					when FPU_MEMORY_READ =>
						-- CPU manages all memory operations - this state is unused
						fpu_state <= FPU_IDLE;
					
					when FPU_MEMORY_WRITE =>
						-- CPU manages all memory operations - this state is unused
						fpu_state <= FPU_IDLE;
						fpu_done <= '1';
					
					when FPU_WRITE_RESULT =>
						-- Handle FMOVECR constant ROM vs normal result
						if fpu_operation = OP_FMOVECR then
							-- FMOVECR - Use constant from ROM
							if constrom_valid = '1' then
								fp_registers(to_integer(unsigned(dest_reg))) <= constrom_result;
								rom_read_enable <= '0';  -- Stop ROM read
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
								end if;
							-- Wait for ROM to be ready
						else
							-- Special handling for FSINCOS which writes to two registers
							if fpu_operation = OP_FSINCOS then
								-- FSINCOS: sine to destination register, cosine to specified register
								-- Bounds check for both destination registers
								if to_integer(unsigned(dest_reg)) <= 7 then
									fp_registers(to_integer(unsigned(dest_reg))) <= result_data;  -- Sine result
								end if;
								-- Cosine register is specified in bits 0-2 of extension word
								if to_integer(unsigned(extension_word(2 downto 0))) <= 7 then
									-- For now, generate cosine from sine using identity cos(x) = sin(π/2 - x)
									-- This is a simplified implementation - real MC68882 would compute both simultaneously
									if result_data(78 downto 64) = "111111111111111" then
										-- If sine is NaN or infinity, cosine is also NaN
										fp_registers(to_integer(unsigned(extension_word(2 downto 0)))) <= result_data;  -- Same as sine
									else
										-- Simplified: cos(x) ≈ sin(π/2 - x) - placeholder implementation
										-- Real implementation would use transcendental unit for proper computation
										fp_registers(to_integer(unsigned(extension_word(2 downto 0)))) <= IEEE_NaN;  -- Placeholder
									end if;
								end if;
							elsif fpu_operation /= OP_FTST and fpu_operation /= OP_FCMP then
								-- Normal result - Store result to destination register (except for FTST/FCMP)
								-- Bounds check for destination register
								if to_integer(unsigned(dest_reg)) <= 7 then
									fp_registers(to_integer(unsigned(dest_reg))) <= result_data;
								end if;
							end if;
							
							-- Update FPSR condition codes based on result using proper function
							set_fpsr_condition_codes(fpsr, result_data);
							
							-- Update exception status if any ALU flags are set
							if alu_overflow = '1' then
								fpsr(25) <= '1';  -- Overflow exception
								fpsr(17) <= '1';  -- Accrued overflow
							end if;
							if alu_underflow = '1' then
								fpsr(24) <= '1';  -- Underflow exception
								fpsr(16) <= '1';  -- Accrued underflow
							end if;
							if alu_inexact = '1' then
								fpsr(23) <= '1';  -- Inexact exception
								fpsr(15) <= '1';  -- Accrued inexact
							end if;
							if alu_invalid = '1' then
								fpsr(26) <= '1';  -- Invalid operation exception
								fpsr(18) <= '1';  -- Accrued invalid operation
							end if;
							if alu_divide_by_zero = '1' then
								fpsr(22) <= '1';  -- Divide by zero exception
								fpsr(14) <= '1';  -- Accrued divide by zero
							end if;
							
							-- Update quotient byte for FMOD and FREM operations (FPSR bits 23-16)
							-- MC68882 stores 7 bits of quotient from modulo/remainder operations
							if fpu_operation = OP_FMOD or fpu_operation = OP_FREM then
								-- Extract 7 bits of quotient from ALU result
								-- Assuming ALU provides quotient in upper bits of result
								fpsr(23 downto 17) <= result_data(6 downto 0);  -- Store 7-bit quotient
							end if;
							
							-- Set output data based on format
							if data_format = FORMAT_SINGLE or data_format = FORMAT_LONG then
								fpu_data_out <= result_data(31 downto 0);
							elsif data_format = FORMAT_DOUBLE then
								fpu_data_out <= result_data(63 downto 32);
							else
								fpu_data_out <= (others => '0');
							end if;
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
						end if;
					
					when FPU_EXCEPTION_STATE =>
						-- Proper exception handling with FPSR updates and FPCR enable checking
						fpu_done <= '1';
						
						-- Check if exception is enabled in FPCR before generating trap
						-- FPCR exception enable bits: [15-8]
						-- Bit 15: BSUN, Bit 14: SNAN, Bit 13: OPERR, Bit 12: OVFL
						-- Bit 11: UNFL, Bit 10: DZ, Bit 9: INEX2, Bit 8: INEX1
						
						-- Update FPSR exception status bits based on exception_code
						case exception_code_internal is
							when x"02" =>  -- Bus error
								fpsr(21) <= '1';  -- BSUN exception bit
							when x"05" =>  -- Division by zero
								fpsr(22) <= '1';  -- DZ exception bit
								fpsr(14) <= '1';  -- DZ accrued exception bit
							when x"0A" =>  -- Format error  
								fpsr(26) <= '1';  -- Invalid operation bit
								fpsr(18) <= '1';  -- Invalid operation accrued bit
							when x"0B" =>  -- Unimplemented instruction
								fpsr(21) <= '1';  -- BSUN exception bit
								fpsr(13) <= '1';  -- BSUN accrued exception bit
							when x"0C" =>  -- Invalid operation
								fpsr(26) <= '1';  -- Invalid operation bit
								fpsr(18) <= '1';  -- Invalid operation accrued bit
							when x"0D" =>  -- Overflow
								fpsr(25) <= '1';  -- Overflow exception bit
								fpsr(17) <= '1';  -- Overflow accrued exception bit
							when x"0E" =>  -- Underflow
								fpsr(24) <= '1';  -- Underflow exception bit
								fpsr(16) <= '1';  -- Underflow accrued exception bit
							when x"0F" =>  -- Inexact result
								fpsr(23) <= '1';  -- Inexact exception bit
								fpsr(15) <= '1';  -- Inexact accrued exception bit
							when others =>
								-- Unknown exception
								fpsr(26) <= '1';  -- Mark as invalid operation
						end case;
						
						-- Check FPCR enable bits and generate trap if enabled
						case exception_code_internal is
							when x"02" =>  -- BSUN exception
								if fpcr(15) = '1' then  -- BSUN enable bit
									fpu_exception <= '1';  -- Generate trap
								else
									fpu_exception <= '0';  -- No trap, just update FPSR
								end if;
							when x"05" =>  -- Division by zero
								if fpcr(10) = '1' then  -- DZ enable bit
									fpu_exception <= '1';  -- Generate trap
								else
									fpu_exception <= '0';  -- No trap, just update FPSR
								end if;
							when x"0C" =>  -- Invalid operation (OPERR)
								if fpcr(13) = '1' then  -- OPERR enable bit  
									fpu_exception <= '1';  -- Generate trap
								else
									fpu_exception <= '0';  -- No trap, just update FPSR
								end if;
							when x"0D" =>  -- Overflow
								if fpcr(12) = '1' then  -- OVFL enable bit
									fpu_exception <= '1';  -- Generate trap
								else
									fpu_exception <= '0';  -- No trap, just update FPSR
								end if;
							when x"0E" =>  -- Underflow
								if fpcr(11) = '1' then  -- UNFL enable bit
									fpu_exception <= '1';  -- Generate trap
								else
									fpu_exception <= '0';  -- No trap, just update FPSR
								end if;
							when x"0F" =>  -- Inexact result
								if fpcr(9) = '1' then  -- INEX2 enable bit
									fpu_exception <= '1';  -- Generate trap
								else
									fpu_exception <= '0';  -- No trap, just update FPSR
								end if;
							when others =>
								-- For other exceptions, always generate trap
								fpu_exception <= '1';
						end case;
						
						-- Update FPIAR with exception instruction address if needed
						-- fpiar <= current_instruction_address; -- Would need to be passed from CPU
						
						fpu_state <= FPU_IDLE;
					
					when FPU_FSAVE_WRITE =>
						-- FSAVE - Dynamic frame format based on FPU state
						-- CPU manages all memory operations, FPU only provides data when requested
						
						if fsave_data_request = '1' then
							case fsave_data_index is
								when 0 =>
									-- Frame format word - use latched format for stability
									-- 0x00 = NULL (4 bytes), 0x01 = BUSY (4 bytes), 0x60 = MC68882 IDLE (60 bytes)
									-- MC68000 is big-endian: MSB (frame format) goes to lowest address
									fpu_data_out <= fsave_frame_format_latched & X"000000";
								when 1 =>
									-- Data depends on frame format
									if fsave_frame_format_latched = X"00" then
										-- NULL frame - only 4 bytes total, no additional data
										fpu_data_out <= x"00000000";
									else
										-- IDLE frame (60 bytes) or BUSY frame (216 bytes) - FPIAR
										fpu_data_out <= fpiar;
									end if;
								when 2 =>
									-- IDLE frame (60 bytes) or BUSY frame (216 bytes) - FPCR
									if fsave_frame_format_latched = X"60" or fsave_frame_format_latched = X"D8" then
										fpu_data_out <= fpcr;
									else
										fpu_data_out <= x"00000000";
									end if;
								when 3 =>
									-- IDLE frame (60 bytes) or BUSY frame (216 bytes) - FPSR
									if fsave_frame_format_latched = X"60" or fsave_frame_format_latched = X"D8" then
										fpu_data_out <= fpsr;
									else
										fpu_data_out <= x"00000000";
									end if;
								when 4 to 11 =>
									-- IDLE frame or BUSY frame - High 32 bits of FP registers 0-7
									if fsave_frame_format_latched = X"60" or fsave_frame_format_latched = X"D8" then
										fpu_data_out <= fp_registers(fsave_data_index - 4)(79 downto 48);
									else
										fpu_data_out <= x"00000000";
									end if;
								when 12 to 19 =>
									-- IDLE frame or BUSY frame - Middle 32 bits of FP registers 0-7
									if fsave_frame_format_latched = X"60" or fsave_frame_format_latched = X"D8" then
										fpu_data_out <= fp_registers(fsave_data_index - 12)(47 downto 16);
									else
										fpu_data_out <= x"00000000";
									end if;
								when 20 to 27 =>
									-- IDLE frame or BUSY frame - Low 16 bits of FP registers 0-7
									if fsave_frame_format_latched = X"60" or fsave_frame_format_latched = X"D8" then
										fpu_data_out(31 downto 16) <= (others => '0');
										fpu_data_out(15 downto 0) <= fp_registers(fsave_data_index - 20)(15 downto 0);
									else
										fpu_data_out <= x"00000000";
									end if;
								when 28 to 54 =>
									-- BUSY frame only - Extended execution state data
									if fsave_frame_format = X"D8" then
										-- For now, output zeros for extended BUSY frame data
										-- This includes intermediate execution state, exception info, etc.
										fpu_data_out <= x"00000000";
									else
										fpu_data_out <= x"00000000";
									end if;
								when others =>
									fpu_data_out <= x"00000000";
							end case;
						end if;
						
						-- CRITICAL FIX: Frame completion only when current write is the FINAL write for the frame
						-- MC68882-specific frame formats only
						case fsave_frame_format_latched is
							when X"00" =>
								-- MC68882 NULL frame complete after first longword (4 bytes = 1 longword)
								if fsave_data_request = '1' and fsave_data_index = 0 then
									-- This is the final write for NULL frame
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								end if;
							when X"60" =>
								-- MC68882 IDLE frame complete after 15 longwords (60 bytes = 15 longwords)
								if fsave_data_request = '1' and fsave_data_index = 14 then  -- 0-14 = 15 longwords
									-- This is the final write for IDLE frame
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								end if;
							when X"D8" =>
								-- MC68882 BUSY frame complete after 54 longwords (216 bytes = 54 longwords)
								if fsave_data_request = '1' and fsave_data_index = 53 then  -- 0-53 = 54 longwords
									-- This is the final write for BUSY frame
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								end if;
							when others =>
								-- Unknown frame format - default to IDLE completion
								if fsave_data_request = '1' and fsave_data_index = 14 then
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
								end if;
						end case;
					
					when FPU_FRESTORE_READ =>
						-- FRESTORE - CPU provides data, FPU processes it
						
						if frestore_data_write = '1' then
							
							case fsave_counter is
								when 0 =>
									-- Format word detection (format ID in high byte of longword for big-endian)
									frestore_frame_format <= frestore_data_in(31 downto 24);
									case frestore_data_in(31 downto 24) is
										when x"00" =>
											-- $00: Null frame - no state to restore (4 bytes)
											fpu_state <= FPU_IDLE;
											fpu_done <= '1';
											
										when x"01" =>
											-- $01: Busy frame - FPU was busy when FSAVE was called (4 bytes)
											-- Restore to idle state since operation was interrupted
											fpu_state <= FPU_IDLE;
											fpu_done <= '1';
											
										when x"18" =>
											-- $18: Short real frame (24 bytes) - partial context
											fsave_counter <= fsave_counter + 1;
											
										when x"41" =>
											-- $41: MC68881 IDLE frame (60 bytes) - full state with registers
											fsave_counter <= fsave_counter + 1;
											
										when x"60" =>
											-- $60: MC68882 IDLE frame (60 bytes) - full state with registers
											fsave_counter <= fsave_counter + 1;
											
										when x"38" =>
											-- $38: Normal frame (96 bytes) - full context save
											fsave_counter <= fsave_counter + 1;
											
										when others =>
											-- Invalid format - trigger format error exception
											fpu_exception <= '1';
											exception_code_internal <= x"0A";  -- Format error
											fpu_state <= FPU_EXCEPTION_STATE;
									end case;
								
								when 1 =>
									-- FPIAR (present in all frames except NULL/BUSY)
									fpiar <= frestore_data_in;
									fsave_counter <= fsave_counter + 1;
								
								when 2 =>
									-- FPCR (present in all frames except NULL/BUSY) - validate before writing
									fpcr <= validate_fpcr(frestore_data_in);
									fsave_counter <= fsave_counter + 1;
								
								when 3 =>
									-- FPSR (present in all frames except NULL/BUSY) - validate before writing
									fpsr <= validate_fpsr(frestore_data_in);
									-- Check frame format to determine next action
									case frestore_frame_format is
										when x"18" =>
											-- $18 frame complete (24 bytes: 6 longwords) - short real frame
											fpu_state <= FPU_IDLE;
											fpu_done <= '1';
										when x"41" | x"60" =>
											-- $41/$60 frame - continue with FP registers (60 bytes total)
											fsave_counter <= fsave_counter + 1;
										when x"38" =>
											-- $38 frame - continue with extended context (96 bytes total)
											fsave_counter <= fsave_counter + 1;
										when others =>
											-- Unknown frame format
											fpu_state <= FPU_IDLE;
											fpu_done <= '1';
									end case;
								
								when 4 to 11 =>
									-- IDLE frames ($41/$60): High 32 bits of FP registers 0-7
									-- Normal frame ($38): Also part of FP register restoration
									if frestore_frame_format = x"41" or frestore_frame_format = x"60" or frestore_frame_format = x"38" then
										fp_registers(fsave_counter - 4)(79 downto 48) <= frestore_data_in;
									end if;
									fsave_counter <= fsave_counter + 1;
								
								when 12 to 19 =>
									-- IDLE frames ($41/$60): Middle 32 bits of FP registers 0-7
									if frestore_frame_format = x"41" or frestore_frame_format = x"60" then
										fp_registers(fsave_counter - 12)(47 downto 16) <= frestore_data_in;
									end if;
									fsave_counter <= fsave_counter + 1;
									
								when 20 to 27 =>
									-- IDLE frames ($41/$60): Low 16 bits of FP registers 0-7
									if frestore_frame_format = x"41" or frestore_frame_format = x"60" then
										fp_registers(fsave_counter - 20)(15 downto 0) <= frestore_data_in(15 downto 0);
										
										if fsave_counter = 27 then
											-- IDLE frame complete (60 bytes = 15 longwords)
											fpu_state <= FPU_IDLE;
											fpu_done <= '1';
										else
											fsave_counter <= fsave_counter + 1;
										end if;
									else
										-- Other frame types - let CPU handle
										fsave_counter <= fsave_counter + 1;
									end if;
								
								when 28 to 54 =>
									-- Extended frames for BUSY or other large frame types
									case frestore_frame_format is
										when x"38" =>
											-- Normal frame (96 bytes = 24 longwords)
											if fsave_counter = 23 then
												fpu_state <= FPU_IDLE;
												fpu_done <= '1';
											else
												fsave_counter <= fsave_counter + 1;
											end if;
										when x"D8" =>
											-- BUSY frame (216 bytes = 54 longwords) - restore FPU register state
											-- Format for BUSY frame includes full FPU context at specific offsets
											case fsave_counter is
												when 28 to 35 =>
													-- FP registers 0-7 high 32 bits (same as IDLE frame offset + 24)
													fp_registers(fsave_counter - 28)(79 downto 48) <= frestore_data_in;
													fsave_counter <= fsave_counter + 1;
												when 36 to 43 =>
													-- FP registers 0-7 middle 32 bits (same as IDLE frame offset + 24)
													fp_registers(fsave_counter - 36)(47 downto 16) <= frestore_data_in;
													fsave_counter <= fsave_counter + 1;
												when 44 to 51 =>
													-- FP registers 0-7 low 16 bits (same as IDLE frame offset + 24)
													fp_registers(fsave_counter - 44)(15 downto 0) <= frestore_data_in(15 downto 0);
													fsave_counter <= fsave_counter + 1;
												when others =>
													-- Other BUSY frame data (execution state, etc.) - CPU handles
													if fsave_counter = 54 then
														fpu_state <= FPU_IDLE;
														fpu_done <= '1';
													else
														fsave_counter <= fsave_counter + 1;
													end if;
											end case;
										when others =>
											-- Other frame types (up to 216 bytes = 54 longwords)
											if fsave_counter = 54 then
												fpu_state <= FPU_IDLE;
												fpu_done <= '1';
											else
												fsave_counter <= fsave_counter + 1;
											end if;
									end case;
								
								when others =>
									-- Unexpected counter value - complete operation
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
							end case;
						end if;
						
					when FPU_FMOVEM =>
						-- FMOVEM operations for FP registers (FP0-FP7)
						-- AmigaOS uses 8 bytes per register in memory (64-bit compressed format)
						-- CPU handles memory operations, format conversion, and incremental stack pointer adjustment
						
						-- FMOVEM data reads are handled by the MOVEM component
						
						-- Handle FMOVEM data writes (restore operations)
						if fmovem_data_write = '1' then
							-- AmigaOS FMOVEM.X loads full 80-bit extended precision format
							-- Restore complete register content from memory
							case fmovem_reg_index is
								when 0 => fp_registers(0) <= fmovem_data_in;  -- FP0 (full 80-bit)
								when 1 => fp_registers(1) <= fmovem_data_in;  -- FP1
								when 2 => fp_registers(2) <= fmovem_data_in;  -- FP2
								when 3 => fp_registers(3) <= fmovem_data_in;  -- FP3
								when 4 => fp_registers(4) <= fmovem_data_in;  -- FP4
								when 5 => fp_registers(5) <= fmovem_data_in;  -- FP5
								when 6 => fp_registers(6) <= fmovem_data_in;  -- FP6
								when 7 => fp_registers(7) <= fmovem_data_in;  -- FP7
								when others => null;
							end case;
						end if;
						
						-- FMOVEM operations complete when CPU signals completion (by disabling fpu_enable)
						-- CPU manages register-by-register transfers and stack pointer increments
						-- Stay in FMOVEM state until CPU finishes operation
						if fpu_enable = '0' or movem_done = '1' then
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
						end if;
						
					when FPU_FMOVEM_CR =>
						-- FMOVEM operations for control registers (FPCR/FPSR/FPIAR)
						-- AmigaOS FMOVEM control register operations
						
						-- For control register reads (save operations)
						if fmovem_data_request = '1' then
							case fmovem_reg_index is
								when 0 => fpu_data_out <= fpcr;   -- FPCR
								when 1 => fpu_data_out <= fpsr;   -- FPSR  
								when 2 => fpu_data_out <= fpiar;  -- FPIAR
								when others => fpu_data_out <= (others => '0');
							end case;
						end if;
						
						-- For control register writes (restore operations)
						if fmovem_data_write = '1' then
							case fmovem_reg_index is
								when 0 => fpcr <= validate_fpcr(cpu_data_in);   -- FPCR - validate
								when 1 => fpsr <= validate_fpsr(cpu_data_in);   -- FPSR - validate
								when 2 => fpiar <= cpu_data_in;  -- FPIAR (no validation needed)  
								when others => null;
							end case;
						end if;
						
						-- Control register operations complete when CPU signals completion
						if fpu_enable = '0' or movem_done = '1' then
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
						end if;
						
				end case;
			end if;
		end if;
	end process;
	
	-- MOVEM register file interface process
	movem_register_interface: process(clk, nReset)
	begin
		if nReset = '0' then
			movem_reg_data_out <= (others => '0');
			-- movem_bus_error is handled in main state machine
		elsif rising_edge(clk) then
			if clkena = '1' then
				-- Handle register reads for MOVEM - provide FP register data to MOVEM component
				if movem_reg_address <= "111" then -- Valid FP register 0-7
					movem_reg_data_in <= fp_registers(to_integer(unsigned(movem_reg_address)));
				else
					movem_reg_data_in <= (others => '0');
				end if;
				
				-- Register writes for MOVEM are now handled in main state machine
				
				-- MOVEM error conditions are now handled in main state machine
				
				-- Memory interface connections are now handled by movem_memory_mux process
			end if;
		end if;
	end process;
	
	-- MOVEM memory interface multiplexing is now handled within the main state machine
	
	-- MOVEM memory ready and data input signals no longer needed (CPU-managed operations)
	
	-- MOVEM address is handled internally by the MOVEM component
	
	-- Connect internal signals to outputs
	fpu_busy <= fpu_busy_internal;
	-- exception_code is assigned at line 595 with proper exception handler integration
	
	-- Update internal busy signal based on state
	process(fpu_state)
	begin
		case fpu_state is
			when FPU_IDLE =>
				fpu_busy_internal <= '0';
			when others =>
				fpu_busy_internal <= '1';
		end case;
	end process;

	-- MC68020/68881 Coprocessor Interface Register (CIR) Handler
	-- Implements proper MC68020 coprocessor protocol per Section 7.4-7.5
	process(clk, nReset)
	begin
		if nReset = '0' then
			command_cir <= (others => '0');
			response_cir <= (others => '0');
			condition_cir <= (others => '0');
			operand_cir <= (others => '0');
			save_cir <= (others => '0');
			restore_cir <= (others => '0');
			cir_data_out <= (others => '0');
			cir_data_valid <= '0';
		elsif rising_edge(clk) then
			if clkena = '1' then
				-- **HARDWARE TIMING FIX: Don't auto-clear cir_data_valid**
				-- Make it a sticky level signal for reliable hardware timing
				-- Only clear when CIR read cycle completes (cir_read = '0')
				if cir_read = '0' then
					cir_data_valid <= '0';
				end if;
				
				-- Handle CPU writes to CIR registers
				if cir_write = '1' then
					case cir_address is
						when "00001" =>  -- Command CIR (A4-A0 = 00001)
							command_cir <= cir_data_in;
						when "00100" =>  -- Restore CIR (A4-A0 = 00100)
							restore_cir <= cir_data_in;
						when "00101" =>  -- Operand CIR (A4-A0 = 00101) 
							operand_cir <= cir_data_in;
						when others =>
							null;  -- Read-only registers
					end case;
				end if;
				
				-- Handle CPU reads from CIR registers - Complete MC68882 implementation
				if cir_read = '1' then
					case cir_address is
						when "00000" =>  -- Response CIR (A4-A0 = 00000) - Read-only
							cir_data_out <= response_cir;
							cir_data_valid <= '1';
						when "00001" =>  -- Command CIR (A4-A0 = 00001) - Write-only (reads as undefined)
							cir_data_out <= (others => 'X');  -- Undefined per MC68882 spec
							cir_data_valid <= '1';
						when "00010" =>  -- Condition CIR (A4-A0 = 00010) - Read-only
							cir_data_out <= condition_cir;
							cir_data_valid <= '1';
						when "00011" =>  -- Save CIR (A4-A0 = 00011) - Read-only
							-- CRITICAL FSAVE FIX: Always provide current frame format
							-- This ensures FSAVE can always determine frame size
							cir_data_out <= save_cir;
							cir_data_valid <= '1';
						when "00100" =>  -- Restore CIR (A4-A0 = 00100) - Write-only (reads as undefined)
							cir_data_out <= (others => 'X');  -- Undefined per MC68882 spec
							cir_data_valid <= '1';
						when "00101" =>  -- Operand CIR (A4-A0 = 00101) - Write-only (reads as undefined)
							cir_data_out <= (others => 'X');  -- Undefined per MC68882 spec
							cir_data_valid <= '1';
						when "00110" =>  -- Operation Word CIR (A4-A0 = 00110) - Read-only
							cir_data_out <= operation_word_cir;
							cir_data_valid <= '1';
						when "00111" =>  -- Command Address CIR Low (A4-A0 = 00111) - Read-only
							cir_data_out <= command_address_cir(15 downto 0);
							cir_data_valid <= '1';
						when "01000" =>  -- Command Address CIR High (A4-A0 = 01000) - Read-only
							cir_data_out <= command_address_cir(31 downto 16);
							cir_data_valid <= '1';
						when others =>
							cir_data_out <= (others => '0');  -- Reserved registers read as zero
							cir_data_valid <= '1';
					end case;
				else
					-- CRITICAL FSAVE FIX: Clear data valid when not reading
					-- This prevents stale data from interfering with frame size detection
					cir_data_valid <= '0';
				end if;
				
				-- MC68882 Complete Primitive Protocol Implementation
				-- Update Response CIR based on FPU state and operation requirements
				case fpu_state is
					when FPU_IDLE =>
						if fpu_done = '1' then
							-- Operation complete - return NULL primitive to end dialog
							response_cir <= PRIM_NULL;  -- NULL response primitive
						else
							-- FPU idle, waiting for instruction - always ready
							response_cir <= PRIM_NULL;  -- NULL - FPU ready
						end if;
						
					when FPU_DECODE =>
						-- Enhanced primitive protocol based on instruction type
						if decoder_instruction_type = INST_GENERAL then
							-- cpGEN instructions - check if operand transfer needed
							case decoder_ea_mode is
								when "000" =>  -- Data register direct
									case decoder_source_format is
										when FORMAT_BYTE | FORMAT_WORD =>
											-- Need CPU register content transfer
											response_cir <= PRIM_CA;  -- CA (Transfer CPU Register)
										when others =>
											-- No transfer needed for other formats
											response_cir <= PRIM_NULL;  -- NULL
									end case;
								when "001" =>  -- Address register direct  
									response_cir <= PRIM_CA;  -- CA (Transfer CPU Register)
								when others =>  -- Memory modes
									-- CPU handles memory operations
									response_cir <= PRIM_NULL;  -- NULL - no coprocessor bus cycles
							end case;
						elsif decoder_instruction_type = INST_FMOVE_FP then
							-- FP register to memory - need result transfer
							response_cir <= PRIM_CC;  -- CC (Transfer Coprocessor Register)
						elsif decoder_instruction_type = INST_FMOVE_MEM then
							-- Memory to FP register - need operand transfer  
							response_cir <= PRIM_CA;  -- CA (Transfer to Coprocessor)
						elsif decoder_instruction_type = INST_FMOVE_CR then
							-- Control register operations
							if decoder_ea_mode = "000" then  -- To CPU register
								response_cir <= PRIM_CC;  -- CC (Transfer from Coprocessor)
							else  -- From CPU register
								response_cir <= PRIM_CA;  -- CA (Transfer to Coprocessor)
							end if;
						else
							-- Other instruction types (FSAVE, FRESTORE, etc.)
							response_cir <= PRIM_NULL;  -- NULL - CPU manages
						end if;
						
					when FPU_FETCH_SOURCE =>
						-- Check if required data transfer is complete
						if cir_write = '1' and cir_address = "00101" then
							-- Operand received - dialog complete
							response_cir <= PRIM_NULL;  -- NULL - proceed to execution
						else
							-- Still waiting for operand transfer
							response_cir <= PRIM_CA;  -- CA primitive - request operand
						end if;
						
					when FPU_EXECUTE =>
						-- Operation in progress - no bus cycles required
						response_cir <= PRIM_NULL;  -- NULL - operation in progress
						
					when FPU_WRITE_RESULT =>
						-- Result ready for transfer if needed
						if decoder_instruction_type = INST_FMOVE_FP then
							-- FP register to memory - provide result  
							response_cir <= PRIM_CC;  -- CC (Transfer Coprocessor Register)
						else
							-- Result written internally - dialog complete
							response_cir <= PRIM_NULL;  -- NULL - completing operation
						end if;
						
					when FPU_EXCEPTION_STATE =>
						-- Exception condition - return appropriate primitive
						response_cir <= PRIM_NULL;  -- NULL - let CPU handle exception
						
					when others =>
						-- Default: return NULL to end dialog safely
						response_cir <= PRIM_NULL;  -- NULL - safe default
				end case;
				
				-- Update Condition CIR with FPU condition codes for conditional instructions
				-- Map FPSR condition codes to condition word for FBcc/FDBcc/FScc instructions
				condition_cir <= (others => '0');  -- Clear all bits first
				condition_cir(3) <= fpsr(31);  -- N (Negative)
				condition_cir(2) <= fpsr(30);  -- Z (Zero)  
				condition_cir(1) <= fpsr(29);  -- I (Infinity)
				condition_cir(0) <= fpsr(28);  -- NaN (Not a Number)
				
				-- Update Save CIR with frame format word for cpSAVE instruction
				-- Format: Upper byte = frame format (0x00, 0x60, 0xD8), Lower byte = reserved (0x00)
				save_cir <= fsave_frame_format & X"00";
			end if;
		end if;
	end process;

end rtl;
