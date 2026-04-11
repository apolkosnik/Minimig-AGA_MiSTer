------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU Instruction Decoder                             --
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

entity TG68K_FPU_Decoder is
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		
		-- Input instruction words
		opcode					: in std_logic_vector(15 downto 0);	-- First instruction word
		extension_word			: in std_logic_vector(15 downto 0);	-- Extension word
		
		-- Decoder enable
		decode_enable			: in std_logic;
		
		-- Decoded instruction fields
		instruction_type		: out std_logic_vector(3 downto 0);	-- Type of FPU instruction
		operation_code			: out std_logic_vector(6 downto 0);	-- 7-bit operation code
		source_format			: out std_logic_vector(2 downto 0);	-- Source data format
		dest_format				: out std_logic_vector(2 downto 0);	-- Destination data format
		source_reg				: out std_logic_vector(2 downto 0);	-- Source FP register
		dest_reg				: out std_logic_vector(2 downto 0);	-- Destination FP register
		ea_mode					: out std_logic_vector(2 downto 0);	-- Effective address mode
		ea_register				: out std_logic_vector(2 downto 0);	-- Effective address register
		
		-- Control signals
		needs_extension_word	: out std_logic;						-- Instruction needs extension word
		valid_instruction		: out std_logic;						-- Instruction is valid FPU instruction
		privileged_instruction	: out std_logic;						-- Instruction requires supervisor mode
		
		-- Exception flags
		illegal_instruction		: out std_logic;						-- Illegal instruction detected
		unsupported_instruction	: out std_logic							-- Instruction not implemented
	);
end TG68K_FPU_Decoder;

architecture rtl of TG68K_FPU_Decoder is

	-- MC68881/68882 Instruction Types
	constant INST_GENERAL		: std_logic_vector(3 downto 0) := "0000";	-- General instruction
	constant INST_FMOVE_FP		: std_logic_vector(3 downto 0) := "0001";	-- FMOVE FPn,<ea>
	constant INST_FMOVE_MEM		: std_logic_vector(3 downto 0) := "0010";	-- FMOVE <ea>,FPn
	constant INST_FMOVEM		: std_logic_vector(3 downto 0) := "0011";	-- FMOVEM
	constant INST_FMOVE_CR		: std_logic_vector(3 downto 0) := "0100";	-- FMOVE control register
	constant INST_FMOVEM_CR		: std_logic_vector(3 downto 0) := "1001";	-- FMOVEM control registers
	constant INST_FBCC			: std_logic_vector(3 downto 0) := "0101";	-- FBcc (branch)
	constant INST_FSAVE			: std_logic_vector(3 downto 0) := "0110";	-- FSAVE
	constant INST_FRESTORE		: std_logic_vector(3 downto 0) := "0111";	-- FRESTORE
	constant INST_FTRAP			: std_logic_vector(3 downto 0) := "1000";	-- FTRAPcc
	
	-- Data format constants
	constant FORMAT_LONG		: std_logic_vector(2 downto 0) := "000";	-- 32-bit integer
	constant FORMAT_SINGLE		: std_logic_vector(2 downto 0) := "001";	-- 32-bit IEEE single
	constant FORMAT_EXTENDED	: std_logic_vector(2 downto 0) := "010";	-- 80-bit IEEE extended
	constant FORMAT_PACKED		: std_logic_vector(2 downto 0) := "011";	-- 96-bit packed decimal
	constant FORMAT_WORD		: std_logic_vector(2 downto 0) := "100";	-- 16-bit integer  
	constant FORMAT_DOUBLE		: std_logic_vector(2 downto 0) := "101";	-- 64-bit IEEE double
	constant FORMAT_BYTE		: std_logic_vector(2 downto 0) := "110";	-- 8-bit integer
	
	-- Internal decode signals
	signal coprocessor_id		: std_logic_vector(2 downto 0);
	signal inst_type_bits		: std_logic_vector(2 downto 0);
	signal format_field			: std_logic_vector(2 downto 0);
	signal opmode_field			: std_logic_vector(6 downto 0);
	signal rm_field				: std_logic_vector(2 downto 0);
	signal rn_field				: std_logic_vector(2 downto 0);
	signal instruction_type_int	: std_logic_vector(3 downto 0);
	
	-- Instruction validity checks
	signal valid_f_line			: std_logic;
	signal valid_coprocessor_id	: std_logic;
	signal valid_format			: std_logic;
	signal valid_opmode			: std_logic;

begin

	-- Extract fields from instruction words
	extract_fields: process(opcode, extension_word)
	begin
		-- First instruction word (F-line): 1111 ccc ttt mmmmmm rrr
		--   ccc = coprocessor ID (001 for FPU)
		--   ttt = instruction type
		--   mmm = effective address mode
		--   rrr = effective address register
		
		coprocessor_id <= opcode(11 downto 9);
		inst_type_bits <= opcode(8 downto 6);
		ea_mode <= opcode(5 downto 3);
		ea_register <= opcode(2 downto 0);
		
		-- Extension word formats vary by instruction type
		-- For general instructions: 0 R/M 0 fff SSS ooooooo 0 DF nnn (per WinUAE table68k)
		--   R/M = register/memory bit (bit 14)
		--   fff = source specifier (bits 15-13)
		--   SSS = source format (bits 12-10)
		--   ooooooo = opmode (operation) (bits 9-3)
		--   DF = destination format (bits 2-1)
		--   nnn = destination register (bits 2-0)
		
		if inst_type_bits = "000" then  -- General instruction (always has extension)
			-- FIXED: Always use extension_word for format/opcode fields
			-- All general FPU instructions (including register-direct) need extension word
			format_field <= extension_word(12 downto 10);	-- Source format from extension word
			opmode_field <= extension_word(6 downto 0);		-- CRITICAL FIX: Operation is bits 6:0, not 9:3!
			rm_field <= extension_word(15 downto 13);		-- Source specifier (corrected bit range)
			rn_field <= extension_word(2 downto 0);			-- Destination register
		else
			format_field <= "000";
			opmode_field <= "0000000";
			rm_field <= "000";
			rn_field <= "000";
		end if;
	end process;
	
	-- Instruction type decode
	instruction_decode: process(opcode, extension_word, inst_type_bits, coprocessor_id)
	begin
		-- Default values
		instruction_type_int <= INST_GENERAL;
		needs_extension_word <= '1';
		privileged_instruction <= '0';
		
		if opcode(15 downto 12) = "1111" and coprocessor_id = "001" then
			case inst_type_bits is
				when "000" =>  -- General instructions (dyadic, monadic) + AmigaOS FMOVEM
					-- Check for AmigaOS FMOVEM operations (context switching)
					-- F225xxxx = FMOVEM to memory (save FP registers or control registers)
					-- F21Dxxxx = FMOVEM from memory (restore FP registers or control registers)
					if (opcode(5 downto 3) = "010" and opcode(2 downto 0) = "101") or  -- F225 pattern (FMOVEM to memory)
					   (opcode(5 downto 3) = "001" and opcode(2 downto 0) = "101") then -- F21D pattern (FMOVEM from memory)
						-- Check extension word to determine if this is FP registers or control registers
						-- This will be handled in the main FPU logic after extension word is available
						instruction_type_int <= INST_FMOVEM;   -- Treat as FMOVEM operation
						needs_extension_word <= '1';
					else
						instruction_type_int <= INST_GENERAL;
						-- FIXED: Always consume the extension word for F-line general ops
						-- All general FPU instructions need extension word for opmode and format
						needs_extension_word <= '1';
					end if;
					
				when "001" =>  -- FDBcc, FTRAPcc, FScc
					if opcode(5 downto 3) = "001" then      -- FDBcc
						instruction_type_int <= INST_FBCC;
					elsif opcode(5 downto 3) = "111" then   -- FTRAPcc or FScc
						if opcode(2 downto 0) = "010" or opcode(2 downto 0) = "011" then
							instruction_type_int <= INST_FTRAP;  -- FTRAPcc
						else
							instruction_type_int <= INST_FBCC;   -- FScc
						end if;
					else
						instruction_type_int <= INST_FBCC;       -- Other conditional ops
					end if;
					needs_extension_word <= '1';
					
				when "010" =>  -- FBcc (word displacement)
					instruction_type_int <= INST_FBCC;
					needs_extension_word <= '1';
					
				when "011" =>  -- FBcc (long displacement)  
					instruction_type_int <= INST_FBCC;
					needs_extension_word <= '1';
					
				when "100" =>  -- FSAVE
					instruction_type_int <= INST_FSAVE;
					needs_extension_word <= '0';
					privileged_instruction <= '1';
					
				when "101" =>  -- FRESTORE
					instruction_type_int <= INST_FRESTORE;
					needs_extension_word <= '0';
					privileged_instruction <= '1';
					
				when "110" =>  -- FMOVE to memory or FMOVEM
					if extension_word(15) = '0' then
						instruction_type_int <= INST_FMOVE_FP;   -- FMOVE FPn,<ea>
					else
						-- FMOVEM instruction - check for control register vs FP register
						if (opcode(15 downto 8) = X"F2") and 
						   (extension_word(15) = '1') and
						   (extension_word(14) = '1') then
							-- Check if this is control register FMOVEM
							if extension_word(12 downto 10) /= "000" and extension_word(7 downto 0) = "00000000" then
								instruction_type_int <= INST_FMOVEM_CR;  -- FMOVEM control registers
								privileged_instruction <= '1';  -- Control register access requires supervisor mode
							elsif extension_word(12 downto 8) = "00000" then
								instruction_type_int <= INST_FMOVEM;     -- Valid FP register FMOVEM
							else
								-- Invalid FMOVEM format - will be caught by validity check
								null;
							end if;
						else
							-- Invalid FMOVEM format - will be caught by validity check
							null;
						end if;
					end if;
					needs_extension_word <= '1';
					
				when "111" =>  -- FMOVE from memory or FMOVE control register
					if extension_word(15 downto 13) = "100" then
						instruction_type_int <= INST_FMOVE_CR;   -- FMOVE control register
						privileged_instruction <= '1';  -- Control register access requires supervisor mode
					else
						instruction_type_int <= INST_FMOVE_MEM;  -- FMOVE <ea>,FPn
					end if;
					needs_extension_word <= '1';
					
				when others =>
					instruction_type_int <= INST_GENERAL;
					needs_extension_word <= '1';
			end case;
		else
			instruction_type_int <= INST_GENERAL;
			needs_extension_word <= '0';
		end if;
	end process;
	
	-- Validity checks
	validity_check: process(decode_enable, opcode, coprocessor_id, format_field, opmode_field)
	begin
		-- Check F-line prefix
		if opcode(15 downto 12) = "1111" then
			valid_f_line <= '1';
		else
			valid_f_line <= '0';
		end if;
		
		-- Check coprocessor ID (must be 001 for FPU)
		if coprocessor_id = "001" then
			valid_coprocessor_id <= '1';
		else
			valid_coprocessor_id <= '0';
		end if;
		
		-- Check format field validity
		case format_field is
			when FORMAT_LONG | FORMAT_SINGLE | FORMAT_EXTENDED | 
				 FORMAT_PACKED | FORMAT_WORD | FORMAT_DOUBLE | FORMAT_BYTE =>
				valid_format <= '1';
			when others =>
				valid_format <= '0';
		end case;
		
		-- Enhanced opmode validity check (per WinUAE table68k)
		-- Valid operation ranges: 0x00-0x3F for most operations, specific patterns for transcendental
		-- Use range checks instead of case ranges for VHDL compatibility
		if (opmode_field >= "0000000" and opmode_field <= "0001111") or  -- Basic arithmetic (0x00-0x0F)
		   (opmode_field >= "0100000" and opmode_field <= "0101111") or  -- Comparison ops (0x20-0x2F)
		   (opmode_field >= "0001100" and opmode_field <= "0011111") then -- Transcendental (0x0C-0x1F)
			valid_opmode <= '1';
		else
			valid_opmode <= '0';
		end if;
		
		-- Overall validity (enhanced with comprehensive validation)
		valid_instruction <= decode_enable and valid_f_line and valid_coprocessor_id and valid_format and valid_opmode;
		illegal_instruction <= decode_enable and not (valid_f_line and valid_coprocessor_id and valid_format and valid_opmode);
		
		-- Mark unimplemented instructions
		-- Transcendental functions are now supported
		case opmode_field is
			when others =>
				unsupported_instruction <= '0';
		end case;
	end process;
	
	-- Output assignments
	instruction_type <= instruction_type_int;
	operation_code <= opmode_field;
	source_format <= format_field when instruction_type_int = INST_GENERAL else FORMAT_EXTENDED;
	dest_format <= FORMAT_EXTENDED;  -- Internal operations use extended precision
	source_reg <= rm_field;
	dest_reg <= rn_field;

end rtl;