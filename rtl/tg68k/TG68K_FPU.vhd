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
		cpu_data_in				: in std_logic_vector(31 downto 0);	-- Data from CPU (for register/memory sources)
		cpu_address_in			: in std_logic_vector(31 downto 0);	-- Effective address from CPU (for FSAVE/FRESTORE)
		fpu_data_out			: out std_logic_vector(31 downto 0);	-- Data to CPU (for register destinations)
		
		-- Memory Interface (for effective address operands)
		fpu_address_out			: out std_logic_vector(31 downto 0);	-- Address for memory access
		fpu_memory_request		: out std_logic;						-- Request memory access
		fpu_read_write			: out std_logic;						-- 0=read, 1=write
		fpu_data_size			: out std_logic_vector(1 downto 0);	-- 00=byte, 01=word, 10=long
		cpu_memory_ready		: in std_logic;							-- Memory access completed
		cpu_memory_data			: in std_logic_vector(31 downto 0);	-- Data from memory read
		
		-- Control Signals
		fpu_busy				: out std_logic;						-- FPU is executing multi-cycle operation
		fpu_done				: out std_logic;						-- Operation complete
		fpu_exception			: out std_logic;						-- FPU exception occurred
		exception_code			: buffer std_logic_vector(7 downto 0);	-- Exception type
		
		-- Status and Control Registers
		fpcr_out				: out std_logic_vector(31 downto 0);	-- Floating-Point Control Register
		fpsr_out				: out std_logic_vector(31 downto 0);	-- Floating-Point Status Register  
		fpiar_out				: out std_logic_vector(31 downto 0)	-- Floating-Point Instruction Address Register
	);
end TG68K_FPU;

architecture rtl of TG68K_FPU is

	-- MC68881/68882 Floating Point Register File (8 x 80-bit registers)
	-- Stored as 80-bit IEEE 754 extended precision values
	type fp_reg_t is array(0 to 7) of std_logic_vector(79 downto 0);
	signal fp_registers : fp_reg_t := (others => (others => '0'));
	
	-- Control and Status Registers
	signal fpcr : std_logic_vector(31 downto 0) := X"00000000";	-- Floating-Point Control Register (MC68882 defaults)
	signal fpsr : std_logic_vector(31 downto 0) := X"00000000";	-- Floating-Point Status Register (MC68882 defaults)
	signal fpiar : std_logic_vector(31 downto 0) := (others => '0');	-- Floating-Point Instruction Address Register
	
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
		FPU_FSAVE_WRITE,
		FPU_FRESTORE_READ
	);
	signal fpu_state : fpu_state_t := FPU_IDLE;
	signal next_state : fpu_state_t;
	signal fpu_busy_internal : std_logic := '0';
	
	-- MOVEM operation state machine and signals
	type movem_state_t is (
		MOVEM_IDLE,
		MOVEM_FIND_NEXT,
		MOVEM_TRANSFER,
		MOVEM_TRANSFER_HIGH,
		MOVEM_TRANSFER_MID,
		MOVEM_TRANSFER_LOW
	);
	signal movem_state : movem_state_t := MOVEM_IDLE;
	signal movem_register_list : std_logic_vector(7 downto 0);
	signal movem_direction : std_logic;  -- 0=store to memory, 1=load from memory
	signal movem_address : std_logic_vector(31 downto 0);
	signal movem_current_reg : integer range 0 to 7;
	signal movem_temp_reg : std_logic_vector(79 downto 0);  -- Temporary storage for 80-bit register
	
	-- Timeout counter to prevent infinite wait states
	signal timeout_counter : integer range 0 to 255 := 0;
	-- Improved timeout limits for different operation types
	constant TIMEOUT_LIMIT_MEMORY : integer := 128;  -- Memory operations (bus access)
	constant TIMEOUT_LIMIT_ALU : integer := 64;      -- ALU operations (arithmetic)
	constant TIMEOUT_LIMIT_FSAVE : integer := 32;    -- FSAVE/FRESTORE frame operations
	
	-- FSAVE/FRESTORE operation signals
	signal fsave_counter : integer range 0 to 31 := 0;  -- Word counter for complete state frame
	signal fsave_address : std_logic_vector(31 downto 0);
	signal fsave_data : std_logic_vector(31 downto 0);
	
	-- Instruction decode signals from decoder
	signal decoder_instruction_type	: std_logic_vector(3 downto 0);
	signal decoder_operation_code		: std_logic_vector(6 downto 0);
	signal decoder_source_format		: std_logic_vector(2 downto 0);
	signal decoder_dest_format			: std_logic_vector(2 downto 0);
	signal decoder_source_reg			: std_logic_vector(2 downto 0);
	signal decoder_dest_reg				: std_logic_vector(2 downto 0);
	signal decoder_ea_mode				: std_logic_vector(2 downto 0);
	signal decoder_ea_register			: std_logic_vector(2 downto 0);
	signal decoder_needs_extension		: std_logic;
	signal decoder_valid_instruction	: std_logic;
	signal decoder_privileged			: std_logic;
	signal decoder_illegal				: std_logic;
	signal decoder_unsupported			: std_logic;
	
	-- Internal decode signals
	signal fpu_opcode : std_logic_vector(15 downto 0);
	signal fpu_operation : std_logic_vector(6 downto 0);	-- 7-bit operation field
	signal source_reg : std_logic_vector(2 downto 0);		-- Source FP register
	signal dest_reg : std_logic_vector(2 downto 0);		-- Destination FP register
	signal data_format : std_logic_vector(2 downto 0);		-- Data format (byte, word, long, single, double, extended, packed)
	signal ea_mode : std_logic_vector(2 downto 0);			-- Effective address mode
	signal ea_register : std_logic_vector(2 downto 0);		-- Effective address register
	
	-- Operation execution signals
	signal execute_op : std_logic;
	signal operation_done : std_logic;
	signal current_exception : std_logic;
	signal exception_type : std_logic_vector(7 downto 0);
	
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
	signal alu_invalid : std_logic;
	signal alu_divide_by_zero : std_logic;
	signal alu_operation_busy : std_logic;
	signal alu_operation_done : std_logic;
	
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
	signal convert_to_extended : std_logic;
	signal convert_from_extended : std_logic;
	signal convert_done : std_logic;
	signal converted_data : std_logic_vector(79 downto 0);
	
	-- Constant ROM signals
	signal rom_offset : std_logic_vector(6 downto 0);
	signal rom_read_enable : std_logic;
	signal constrom_result : std_logic_vector(79 downto 0);
	signal constrom_valid : std_logic;
	
	-- MC68881/68882 Operation Codes (7-bit field from instruction word)
	-- Basic operations (fully implemented)
	constant OP_FMOVE		: std_logic_vector(6 downto 0) := "0000000";
	constant OP_FINT		: std_logic_vector(6 downto 0) := "0000001";
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
	
	-- Transcendental functions (extended library - basic placeholder support)
	constant OP_FSINH		: std_logic_vector(6 downto 0) := "0000010";
	constant OP_FLOGNP1		: std_logic_vector(6 downto 0) := "0000110";
	constant OP_FETOXM1		: std_logic_vector(6 downto 0) := "0001000";
	constant OP_FTANH		: std_logic_vector(6 downto 0) := "0001001";
	constant OP_FATAN		: std_logic_vector(6 downto 0) := "0001010";
	constant OP_FASIN		: std_logic_vector(6 downto 0) := "0001100";
	constant OP_FATANH		: std_logic_vector(6 downto 0) := "0001101";
	constant OP_FSIN		: std_logic_vector(6 downto 0) := "0001110";
	constant OP_FTAN		: std_logic_vector(6 downto 0) := "0001111";
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
	constant OP_FMOVECR		: std_logic_vector(6 downto 0) := "0010111";
	
	-- Instruction type constants (matching decoder)
	constant INST_GENERAL		: std_logic_vector(3 downto 0) := "0000";	-- General instruction
	constant INST_FMOVE_FP		: std_logic_vector(3 downto 0) := "0001";	-- FMOVE FPn,<ea>
	constant INST_FMOVE_MEM		: std_logic_vector(3 downto 0) := "0010";	-- FMOVE <ea>,FPn
	constant INST_FMOVEM		: std_logic_vector(3 downto 0) := "0011";	-- FMOVEM
	constant INST_FMOVE_CR		: std_logic_vector(3 downto 0) := "0100";	-- FMOVE control register
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
	FPU_ALU: TG68K_FPU_ALU
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

	-- Output assignments
	fpcr_out <= fpcr;
	fpsr_out <= fpsr;  
	fpiar_out <= fpiar;
	-- fpu_data_out is now handled within the state machine process
	
	-- Instruction decode process - now uses decoder outputs
	decode_process: process(fpu_enable, opcode, decoder_operation_code, decoder_source_format, 
							decoder_source_reg, decoder_dest_reg, decoder_ea_mode, decoder_ea_register)
	begin
		if fpu_enable = '1' then
			fpu_opcode <= opcode;
			
			-- Use decoded values from instruction decoder
			fpu_operation <= decoder_operation_code;
			data_format <= decoder_source_format;
			source_reg <= decoder_source_reg;
			dest_reg <= decoder_dest_reg;
			ea_mode <= decoder_ea_mode;
			ea_register <= decoder_ea_register;
		else
			fpu_opcode <= (others => '0');
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
			exception_code <= (others => '0');
			execute_op <= '0';
			-- Initialize MOVEM state machine
			movem_state <= MOVEM_IDLE;
			movem_current_reg <= 0;
			movem_register_list <= (others => '0');
			-- Initialize timeout counter
			timeout_counter <= 0;
			-- Initialize FSAVE signals
			fsave_counter <= 0;
			fsave_address <= (others => '0');
			fsave_data <= (others => '0');
			-- Initialize control registers with proper MC68882 defaults
			fpcr <= X"00000000";  -- MC68882 FPCR default: round-to-nearest, extended precision, no exceptions enabled
			fpsr <= X"00000000";  -- MC68882 FPSR default: no exceptions, CCNAN=0
			fpiar <= (others => '0');
			-- Initialize FP register file to zero
			fp_registers <= (others => (others => '0'));
			-- Initialize memory interface
			fpu_address_out <= (others => '0');
			fpu_data_out <= (others => '0');
			fpu_memory_request <= '0';
			fpu_read_write <= '0';
			fpu_data_size <= "00";
		elsif rising_edge(clk) then
			if clkena = '1' then
				-- Default assignments
				fpu_data_out <= (others => '0');
				
				case fpu_state is
					when FPU_IDLE =>
						fpu_done <= '0';
						fpu_exception <= '0';
						execute_op <= '0';
						
						if fpu_enable = '1' then
							fpu_state <= FPU_DECODE;
						end if;
					
					when FPU_DECODE =>
						-- Reset timeout counter at start of decode
						timeout_counter <= 0;
						-- Update FPIAR with current instruction address at start of instruction
						-- This should be the PC of the F-line instruction being executed
						fpiar <= cpu_address_in;
						
						-- Check decoder outputs for validity
						if decoder_illegal = '1' then
							-- Illegal instruction
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code <= X"10";  -- Illegal instruction
						elsif decoder_unsupported = '1' then
							-- Unsupported instruction (transcendental functions, etc.)
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code <= X"0C";  -- Unimplemented instruction
						elsif decoder_valid_instruction = '0' then
							-- Invalid F-line instruction
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code <= X"10";  -- Illegal instruction
						elsif decoder_instruction_type = INST_FSAVE then
							-- FSAVE - Save FPU state to memory for proper FPU detection
							-- Write a proper MC68882-compatible 60-byte null state frame
							fsave_counter <= 0;
							fsave_address <= cpu_address_in;  -- Start address (-(A7) means pre-decrement)
							fpu_state <= FPU_FSAVE_WRITE;
						elsif decoder_instruction_type = INST_FRESTORE then
							-- FRESTORE - Restore FPU state from memory
							-- Read state information from memory
							fpu_state <= FPU_FRESTORE_READ;
						elsif decoder_instruction_type = INST_FMOVE_CR then
							-- FMOVE control register - FMOVE FPCR/FPSR/FPIAR,<ea> or FMOVE <ea>,FPCR/FPSR/FPIAR
							-- Check direction bit in extension word (bit 13)
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
									when "001" =>  -- FPCR
										fpcr <= cpu_data_in;
									when "010" =>  -- FPSR
										fpsr <= cpu_data_in;
									when "100" =>  -- FPIAR
										fpiar <= cpu_data_in;
									when others =>
										null;
								end case;
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
						      fpu_operation = OP_FATANH or fpu_operation = OP_FETOX or fpu_operation = OP_FTWOTOX or
						      fpu_operation = OP_FTENTOX or fpu_operation = OP_FLOGN or fpu_operation = OP_FLOG10 or
						      fpu_operation = OP_FLOG2 or fpu_operation = OP_FMOVECR or fpu_operation = OP_FMOD or
						      fpu_operation = OP_FREM or fpu_operation = OP_FSCALE or fpu_operation = OP_FGETEXP or
						      fpu_operation = OP_FGETMAN then
								if fpu_operation = OP_FMOVECR then
									-- FMOVECR - Move from constant ROM
									rom_offset <= extension_word(6 downto 0);  -- ROM offset from extension word
									rom_read_enable <= '1';
									fpu_state <= FPU_WRITE_RESULT;  -- Skip fetch, go directly to write result
								else
									fpu_state <= FPU_FETCH_SOURCE;
								end if;
							else
								-- Other operations not yet implemented
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								exception_code <= X"0C";  -- Unimplemented instruction
							end if;
						
						elsif decoder_instruction_type = INST_FMOVE_FP then
							-- FMOVE FPn,<ea> - Move FP register to memory/CPU register
							-- Source format is always extended precision from FP register
							-- Destination format specified in extension word bits 12-10
							movem_temp_reg <= fp_registers(to_integer(unsigned(decoder_source_reg)));
							case decoder_dest_format is
								when FORMAT_SINGLE =>
									-- Convert to single precision and write
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '1';  -- Write to memory
									fpu_data_size <= "10";  -- 32-bit single precision
									-- Simple extended to single conversion (for now)
									fpu_data_out <= fp_registers(to_integer(unsigned(decoder_source_reg)))(79) & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(71 downto 65) & "1" & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(63 downto 41);
									fpu_state <= FPU_MEMORY_WRITE;
								when FORMAT_DOUBLE =>
									-- Convert to double precision and write (simplified)
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '1';  -- Write to memory
									fpu_data_size <= "10";  -- 32-bit transfers (will need 2 transfers)
									-- Write high 32 bits first (sign + 11-bit exp + 20 high mantissa bits)
									fpu_data_out <= fp_registers(to_integer(unsigned(decoder_source_reg)))(79) & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(74 downto 65) & '0' & 
													fp_registers(to_integer(unsigned(decoder_source_reg)))(63 downto 44);
									fpu_state <= FPU_MEMORY_WRITE;
								when FORMAT_LONG =>
									-- Convert to 32-bit integer and write
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '1';  -- Write to memory
									fpu_data_size <= "10";  -- 32-bit integer
									-- Simple conversion: just take mantissa high bits (simplified)
									fpu_data_out <= fp_registers(to_integer(unsigned(decoder_source_reg)))(63 downto 32);
									fpu_state <= FPU_MEMORY_WRITE;
								when FORMAT_PACKED =>
									-- Write 96-bit packed decimal (12 bytes) - basic implementation
									-- For now, treat packed decimal as invalid operation
									-- TODO: Implement full packed decimal conversion
									fpu_state <= FPU_EXCEPTION_STATE;
									fpu_exception <= '1';
									exception_code <= X"30";  -- Operand error for unsupported packed decimal
								when others =>
									-- Extended precision - write all 80 bits in 3 transfers
									movem_address <= cpu_address_in;
									movem_current_reg <= to_integer(unsigned(decoder_source_reg));
									movem_direction <= '0';  -- Store to memory
									movem_state <= MOVEM_TRANSFER_HIGH;
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '1';  -- Write to memory
									fpu_data_size <= "10";  -- 32-bit transfers
									fpu_data_out <= fp_registers(to_integer(unsigned(decoder_source_reg)))(79 downto 48);
									fpu_state <= FPU_MEMORY_WRITE;
							end case;
						
						elsif decoder_instruction_type = INST_FMOVE_MEM then
							-- FMOVE <ea>,FPn - Move memory/CPU register to FP register
							-- Source format specified in extension word, destination is always extended precision
							case decoder_source_format is
								when FORMAT_SINGLE =>
									-- Read single precision and convert to extended
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- 32-bit single precision
									fpu_state <= FPU_MEMORY_READ;
								when FORMAT_DOUBLE =>
									-- Read double precision and convert to extended (simplified)
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- 32-bit transfers (will need 2 transfers)
									fpu_state <= FPU_MEMORY_READ;
								when FORMAT_LONG =>
									-- Read 32-bit integer and convert to extended
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- 32-bit integer
									fpu_state <= FPU_MEMORY_READ;
								when FORMAT_PACKED =>
									-- Read 96-bit packed decimal (12 bytes) - basic implementation
									-- For now, treat packed decimal as invalid operation
									-- TODO: Implement full packed decimal conversion
									fpu_state <= FPU_EXCEPTION_STATE;
									fpu_exception <= '1';
									exception_code <= X"30";  -- Operand error for unsupported packed decimal
								when others =>
									-- Extended precision - read all 80 bits in 3 transfers
									movem_address <= cpu_address_in;
									movem_current_reg <= to_integer(unsigned(decoder_dest_reg));
									movem_direction <= '1';  -- Load from memory
									movem_state <= MOVEM_TRANSFER_HIGH;
									fpu_address_out <= cpu_address_in;
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- 32-bit transfers
									fpu_state <= FPU_MEMORY_READ;
							end case;
						
						elsif decoder_instruction_type = INST_FMOVEM then
							-- FMOVEM multi-register - FMOVEM <list>,<ea> or FMOVEM <ea>,<list>
							-- Handles transfer of multiple FP registers to/from memory (full 80-bit precision)
							-- Register list in extension_word(7 downto 0) - bit set = register included
							-- Direction: extension_word(13) = 0 for FP->memory, 1 for memory->FP
							-- Initialize MOVEM operation if not already in progress
							if movem_state = MOVEM_IDLE then
								movem_register_list <= extension_word(7 downto 0);
								movem_direction <= extension_word(13);  -- 0=store, 1=load
								movem_address <= cpu_data_in;  -- Base address
								-- Start register depends on addressing mode
								if extension_word(11) = '1' then
									-- Predecrement mode: start from register 7
									movem_current_reg <= 7;
								else
									-- Postincrement mode: start from register 0
									movem_current_reg <= 0;
								end if;
								if extension_word(7 downto 0) = "00000000" then
									-- No registers to transfer
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
										else
									movem_state <= MOVEM_FIND_NEXT;
								end if;
							elsif movem_state = MOVEM_FIND_NEXT then
								-- Find next register in list (scan from current position)
								if movem_register_list(movem_current_reg) = '1' then
									-- Found register to transfer - start with high 32 bits (exponent + high mantissa)
									movem_temp_reg <= fp_registers(movem_current_reg);
									if movem_direction = '0' then
										-- Store to memory - start with high 32 bits
										fpu_address_out <= movem_address;
										fpu_memory_request <= '1';
										fpu_read_write <= '1';  -- Write to memory
										fpu_data_size <= "10";  -- 32-bit transfers
										fpu_data_out <= fp_registers(movem_current_reg)(79 downto 48);  -- High 32 bits (sign+exp+high mantissa)
										movem_state <= MOVEM_TRANSFER_HIGH;
										fpu_state <= FPU_MEMORY_WRITE;
									else
										-- Load from memory - start with high 32 bits
										fpu_address_out <= movem_address;
										fpu_memory_request <= '1';
										fpu_read_write <= '0';  -- Read from memory
										fpu_data_size <= "10";  -- 32-bit transfers
										movem_state <= MOVEM_TRANSFER_HIGH;
										fpu_state <= FPU_MEMORY_READ;
									end if;
								else
									-- Move to next register (scan direction depends on predecrement/postincrement)
									if extension_word(11) = '1' then
										-- Predecrement mode: scan registers 7->0
										if movem_current_reg > 0 then
											movem_current_reg <= movem_current_reg - 1;
										else
											-- All registers processed
											movem_state <= MOVEM_IDLE;
											fpu_state <= FPU_IDLE;
											fpu_done <= '1';
														end if;
									else
										-- Postincrement mode: scan registers 0->7
										if movem_current_reg < 7 then
											movem_current_reg <= movem_current_reg + 1;
										else
											-- All registers processed
											movem_state <= MOVEM_IDLE;
											fpu_state <= FPU_IDLE;
											fpu_done <= '1';
														end if;
									end if;
								end if;
							elsif movem_state = MOVEM_TRANSFER_HIGH then
								-- High 32 bits transferred, now transfer middle 32 bits
								fpu_address_out <= std_logic_vector(unsigned(movem_address) + 4);
								fpu_memory_request <= '1';
								if movem_direction = '0' then
									-- Store middle 32 bits
									fpu_data_out <= movem_temp_reg(47 downto 16);  -- Middle 32 bits of mantissa
									movem_state <= MOVEM_TRANSFER_MID;
									fpu_state <= FPU_MEMORY_WRITE;
								else
									-- Load middle 32 bits
									movem_temp_reg(79 downto 48) <= cpu_memory_data;  -- Store high bits just read
									movem_state <= MOVEM_TRANSFER_MID;
									fpu_state <= FPU_MEMORY_READ;
								end if;
								
							elsif movem_state = MOVEM_TRANSFER_MID then
								-- Middle 32 bits transferred, now transfer low 16 bits  
								fpu_address_out <= std_logic_vector(unsigned(movem_address) + 8);
								fpu_memory_request <= '1';
								fpu_data_size <= "01";  -- 16-bit transfer for last part
								if movem_direction = '0' then
									-- Store low 16 bits (pad with zeros for 32-bit bus)
									fpu_data_out <= X"0000" & movem_temp_reg(15 downto 0);  -- Low 16 bits of mantissa
									movem_state <= MOVEM_TRANSFER_LOW;
									fpu_state <= FPU_MEMORY_WRITE;
								else
									-- Load low 16 bits
									movem_temp_reg(47 downto 16) <= cpu_memory_data;  -- Store middle bits just read
									movem_state <= MOVEM_TRANSFER_LOW;
									fpu_state <= FPU_MEMORY_READ;
								end if;
								
							elsif movem_state = MOVEM_TRANSFER_LOW then
								-- Low 16 bits transferred, complete the register transfer
								if movem_direction = '1' then
									-- Store the completed register for load operations
									movem_temp_reg(15 downto 0) <= cpu_memory_data(15 downto 0);  -- Store low bits just read
									fp_registers(movem_current_reg) <= movem_temp_reg(79 downto 0);  -- Update register
								end if;
								-- Clear bit in register list and advance address by 10 bytes (80-bit = exactly 10 bytes)
								movem_register_list(movem_current_reg) <= '0';
								if extension_word(11) = '1' then
									-- Predecrement mode: address decreases
									movem_address <= std_logic_vector(unsigned(movem_address) - 10);
								else
									-- Postincrement mode: address increases  
									movem_address <= std_logic_vector(unsigned(movem_address) + 10);
								end if;
								-- Move to next register (direction depends on addressing mode)
								movem_state <= MOVEM_FIND_NEXT;
								
							elsif movem_state = MOVEM_TRANSFER then
								-- Legacy transfer state (should not be used with multi-cycle)
								-- Clear bit in register list and advance address
								movem_register_list(movem_current_reg) <= '0';
								movem_address <= std_logic_vector(unsigned(movem_address) + 10);  -- 80-bit = 10 bytes
								-- Move to next register
								if movem_current_reg < 7 then
									movem_current_reg <= movem_current_reg + 1;
									movem_state <= MOVEM_FIND_NEXT;
								else
									-- All registers processed
									movem_state <= MOVEM_IDLE;
									fpu_state <= FPU_IDLE;
									fpu_done <= '1';
										end if;
							end if;
						else
							-- Unknown instruction type
							fpu_state <= FPU_EXCEPTION_STATE;
							fpu_exception <= '1';
							exception_code <= X"0C";  -- Unimplemented instruction
						end if;
					
					when FPU_FETCH_SOURCE =>
						-- Reset timeout and ALU start signal
						timeout_counter <= 0;
						alu_start_operation <= '0';
						
						-- Load operands and setup ALU
						alu_operand_a <= fp_registers(to_integer(unsigned(source_reg)))(79 downto 0);
						if ea_mode = "000" then  -- Data register direct (CPU register)
							-- For FTST.B D1 - convert CPU data from data bus to extended precision
							-- Use CPU data input and convert based on data format
							case data_format is
								when FORMAT_BYTE =>
									-- Convert 8-bit signed integer to 80-bit extended precision
									-- IEEE 754 extended: sign(1) + exponent(15) + mantissa(64)
									if cpu_data_in(7 downto 0) = x"00" then
										-- Zero
										alu_operand_b <= (others => '0');
									elsif cpu_data_in(7) = '0' then
										-- Positive integer: normalize mantissa to 1.xxxx format
										-- For byte value, MSB should be in bit 63 of mantissa (explicit integer bit)
										alu_operand_b <= '0' & x"4006" & cpu_data_in(7 downto 0) & x"00000000000000";
									else
										-- Negative integer: take 2's complement magnitude and set sign bit
										alu_operand_b <= '1' & x"4006" & ((not cpu_data_in(7 downto 0)) + 1) & x"00000000000000";
									end if;
								when FORMAT_WORD =>
									-- Convert 16-bit signed integer to 80-bit extended precision
									if cpu_data_in(15 downto 0) = x"0000" then
										-- Zero
										alu_operand_b <= (others => '0');
									elsif cpu_data_in(15) = '0' then
										-- Positive integer: normalize mantissa properly
										alu_operand_b <= '0' & x"400E" & cpu_data_in(15 downto 0) & x"000000000000";
									else
										-- Negative integer: take 2's complement magnitude and set sign bit
										alu_operand_b <= '1' & x"400E" & ((not cpu_data_in(15 downto 0)) + 1) & x"000000000000";
									end if;
								when FORMAT_LONG =>
									-- Convert 32-bit signed integer to 80-bit extended precision  
									if cpu_data_in = x"00000000" then
										-- Zero
										alu_operand_b <= (others => '0');
									elsif cpu_data_in(31) = '0' then
										-- Positive integer: normalize mantissa properly
										alu_operand_b <= '0' & x"401E" & cpu_data_in & x"00000000";
									else
										-- Negative integer: take 2's complement magnitude and set sign bit
										alu_operand_b <= '1' & x"401E" & ((not cpu_data_in) + 1) & x"00000000";
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
									fpu_address_out <= cpu_data_in;  -- Address from An
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "011" =>  -- Address register indirect with postincrement (An)+
									fpu_address_out <= cpu_data_in;  -- Address from An
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "100" =>  -- Address register indirect with predecrement -(An)
									-- For FSAVE -(SP): generate stack address
									fpu_address_out <= cpu_data_in;  -- Assume CPU provides current An value
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "101" =>  -- Address register indirect with displacement d16(An)
									fpu_address_out <= cpu_data_in;  -- Address = An + displacement (CPU calculated)
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "110" =>  -- Address register indirect with index d8(An,Xn)
									fpu_address_out <= cpu_data_in;  -- Address = An + Xn + d8 (CPU calculated)
									fpu_memory_request <= '1';
									fpu_read_write <= '0';  -- Read from memory
									fpu_data_size <= "10";  -- Long word access
									fpu_state <= FPU_MEMORY_READ;
								when "111" =>  -- Absolute and immediate addressing
									case ea_register is
										when "000" =>  -- Absolute short $xxxx.W
											fpu_address_out <= cpu_data_in;  -- Absolute address from extension
											fpu_memory_request <= '1';
											fpu_read_write <= '0';  -- Read from memory
											fpu_data_size <= "10";  -- Long word access
											fpu_state <= FPU_MEMORY_READ;
										when "001" =>  -- Absolute long $xxxxxxxx.L
											fpu_address_out <= cpu_data_in;  -- Absolute address from extension
											fpu_memory_request <= '1';
											fpu_read_write <= '0';  -- Read from memory
											fpu_data_size <= "10";  -- Long word access
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
														-- Zero or denormalized
														alu_operand_b <= cpu_data_in(31) & x"0000" & x"000000000000000" & "000";
													elsif cpu_data_in(30 downto 23) = x"FF" then
														-- Infinity or NaN
														alu_operand_b <= cpu_data_in(31) & x"7FFF" & cpu_data_in(22 downto 0) & x"0000000000";
													else
														-- Normal: bias conversion 127->16383, add implicit 1
														alu_operand_b <= cpu_data_in(31) & (x"3F80" + ("0" & cpu_data_in(30 downto 23))) & '1' & cpu_data_in(22 downto 0) & x"000000000" & "000";
													end if;
												when FORMAT_DOUBLE =>
													-- Convert IEEE 754 double precision to extended precision
													-- Note: This is simplified, real implementation needs two memory reads
													if cpu_data_in(30 downto 20) = "00000000000" then
														-- Zero or denormalized
														alu_operand_b <= cpu_data_in(31) & x"0000" & x"000000000000000" & "000";
													elsif cpu_data_in(30 downto 20) = "11111111111" then
														-- Infinity or NaN
														alu_operand_b <= cpu_data_in(31) & x"7FFF" & cpu_data_in(19 downto 0) & x"0000000000" & "000";
													else
														-- Normal: bias conversion 1023->16383, add implicit 1
														alu_operand_b <= cpu_data_in(31) & (x"3C00" + ("0000" & cpu_data_in(30 downto 20))) & '1' & cpu_data_in(19 downto 0) & x"0000000000" & "00";
													end if;
												when others =>
													alu_operand_b <= (others => '0');
											end case;
											alu_operation_code <= fpu_operation;
											alu_start_operation <= '1';
											fpu_state <= FPU_EXECUTE;
										when others =>
											-- Other modes (PC relative, etc.) not implemented
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
						
						-- For data register direct, continue to execution
						if ea_mode = "000" then
							-- Check if operation is transcendental function
							if fpu_operation = OP_FSIN or fpu_operation = OP_FCOS or fpu_operation = OP_FTAN or
							   fpu_operation = OP_FASIN or fpu_operation = OP_FACOS or fpu_operation = OP_FATAN or
							   fpu_operation = OP_FSINH or fpu_operation = OP_FCOSH or fpu_operation = OP_FTANH or
							   fpu_operation = OP_FATANH or fpu_operation = OP_FETOX or fpu_operation = OP_FTWOTOX or
							   fpu_operation = OP_FTENTOX or fpu_operation = OP_FLOGN or fpu_operation = OP_FLOG10 or
							   fpu_operation = OP_FLOG2 then
								-- Transcendental function - send to transcendental unit
								trans_operation_code <= fpu_operation;
								trans_operand <= alu_operand_a;  -- Use operand A for unary transcendental operations
								trans_start_operation <= '1';
								fpu_state <= FPU_EXECUTE;
							else
								-- Regular ALU operation
								alu_operation_code <= fpu_operation;
								alu_start_operation <= '1';
								fpu_state <= FPU_EXECUTE;
							end if;
						end if;
					
					when FPU_EXECUTE =>
						alu_start_operation <= '0';  -- Clear ALU start signal
						trans_start_operation <= '0';  -- Clear transcendental start signal
						-- Increment timeout counter (use ALU limit for execution state)
						if timeout_counter < TIMEOUT_LIMIT_ALU then
							timeout_counter <= timeout_counter + 1;
						end if;
						
						-- Check for completion from either ALU or transcendental unit
						if (alu_operation_done = '1' or alu_result_valid = '1') or (trans_operation_done = '1' or trans_result_valid = '1') then
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
							
							-- Update FPSR status register based on final results
							-- FPSR bits: [31:24]=condition codes, [23:16]=quotient, [15:8]=exception status, [7:0]=accrued exceptions
							
							-- Set condition codes based on result
							if final_result = x"00000000000000000000" then
								-- Zero result: set Z flag
								fpsr(26) <= '1';  -- Z (Zero)
								fpsr(27) <= '0';  -- N (Negative)
								fpsr(25) <= '0';  -- I (Infinity)
								fpsr(24) <= '0';  -- NaN
							elsif final_result(79) = '1' then
								-- Negative result: set N flag
								fpsr(26) <= '0';  -- Z
								fpsr(27) <= '1';  -- N (Negative)
								fpsr(25) <= '0';  -- I
								fpsr(24) <= '0';  -- NaN
							elsif final_result(78 downto 64) = x"7FFF" then
								-- Infinity: set I flag
								fpsr(26) <= '0';  -- Z
								fpsr(27) <= final_result(79);  -- N (sign of infinity)
								fpsr(25) <= '1';  -- I (Infinity)
								fpsr(24) <= '0';  -- NaN
							else
								-- Normal positive result
								fpsr(26) <= '0';  -- Z
								fpsr(27) <= '0';  -- N
								fpsr(25) <= '0';  -- I
								fpsr(24) <= '0';  -- NaN
							end if;
							
							-- Set exception flags and handle exceptions
							fpsr(15) <= alu_invalid;        -- BSUN (Invalid operation)
							fpsr(14) <= '0';                -- SNAN (Signaling NaN - not implemented)
							fpsr(13) <= '0';                -- OPERR (Operand error - not implemented)
							fpsr(12) <= alu_overflow;       -- OVFL (Overflow)
							fpsr(11) <= alu_underflow;      -- UNFL (Underflow)
							fpsr(10) <= alu_divide_by_zero; -- DZ (Divide by zero)
							fpsr(9) <= alu_inexact;         -- INEX2 (Inexact result)
							fpsr(8) <= '0';                 -- INEX1 (Inexact decimal input - not implemented)
							
							-- Accumulate exception flags (bits 7:0 mirror bits 15:8)
							fpsr(7) <= fpsr(7) or alu_invalid;
							fpsr(6) <= fpsr(6);  -- SNAN accumulate
							fpsr(5) <= fpsr(5);  -- OPERR accumulate  
							fpsr(4) <= fpsr(4) or alu_overflow;
							fpsr(3) <= fpsr(3) or alu_underflow;
							fpsr(2) <= fpsr(2) or alu_divide_by_zero;
							fpsr(1) <= fpsr(1) or alu_inexact;
							fpsr(0) <= fpsr(0);  -- INEX1 accumulate
							
							-- Check for exceptions that should trap
							if (alu_invalid = '1' and fpcr(15) = '1') or      -- BSUN enable
							   (alu_overflow = '1' and fpcr(12) = '1') or     -- OVFL enable
							   (alu_underflow = '1' and fpcr(11) = '1') or    -- UNFL enable
							   (alu_divide_by_zero = '1' and fpcr(10) = '1') or -- DZ enable
							   (alu_inexact = '1' and fpcr(9) = '1') then      -- INEX2 enable
								-- Exception should generate trap - follow IEEE 754 priority order
								fpu_state <= FPU_EXCEPTION_STATE;
								fpu_exception <= '1';
								-- IEEE 754 exception priority: Invalid > Divide by Zero > Overflow > Underflow > Inexact
								if alu_invalid = '1' then
									exception_code <= X"0C";  -- Invalid operation (highest priority)
								elsif alu_divide_by_zero = '1' then
									exception_code <= X"05";  -- Division by zero
								elsif alu_overflow = '1' then
									exception_code <= X"0D";  -- Overflow
								elsif alu_underflow = '1' then
									exception_code <= X"0E";  -- Underflow
								else
									exception_code <= X"0F";  -- Inexact result (lowest priority)
								end if;
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
								-- FTST - Analyze source operand and set condition codes
								-- Clear previous condition codes first
								fpsr(31 downto 28) <= "0000";
								
								-- Analyze the source operand (alu_operand_a)
								if alu_operand_a(78 downto 64) = "111111111111111" then
									-- Infinity or NaN
									if alu_operand_a(63) = '1' and alu_operand_a(62 downto 0) = (62 downto 0 => '0') then
										-- Infinity
										fpsr(29) <= '1';  -- I (Infinity) bit
										if alu_operand_a(79) = '1' then
											fpsr(31) <= '1';  -- N (Negative) bit for -Infinity
										end if;
									else
										-- NaN
										fpsr(28) <= '1';  -- NaN bit
									end if;
								elsif alu_operand_a(78 downto 64) = (14 downto 0 => '0') and alu_operand_a(63 downto 0) = (63 downto 0 => '0') then
									-- Zero
									fpsr(30) <= '1';  -- Z (Zero) bit
								else
									-- Normal number - check sign
									if alu_operand_a(79) = '1' then
										fpsr(31) <= '1';  -- N (Negative) bit
									end if;
								end if;
								
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
								else
								-- Complex operation failed - trigger unimplemented instruction exception
								fpu_exception <= '1';
								exception_code <= x"0B";  -- Unimplemented instruction
								fpu_state <= FPU_EXCEPTION_STATE;
							end if;
						end if;
					
					when FPU_MEMORY_READ =>
						-- Wait for memory read to complete with timeout protection
						if cpu_memory_ready = '1' then
							-- Memory data available, convert and proceed to execution
							alu_operand_b <= x"3FFF" & cpu_memory_data & x"00000000";  -- Simple conversion
							alu_operation_code <= fpu_operation;
							alu_start_operation <= '1';
							fpu_memory_request <= '0';  -- Clear request
							timeout_counter <= 0;  -- Reset timeout
							fpu_state <= FPU_EXECUTE;
						elsif timeout_counter >= TIMEOUT_LIMIT_MEMORY then
							-- Memory read timeout - distinguish from real bus errors
							fpu_memory_request <= '0';  -- Clear request
							timeout_counter <= 0;
							fpu_exception <= '1';
							exception_code <= x"04";  -- Timeout error (not standard bus error)
							fpu_state <= FPU_EXCEPTION_STATE;
						else
							timeout_counter <= timeout_counter + 1;
						end if;
					
					when FPU_MEMORY_WRITE =>
						-- Wait for memory write to complete with timeout protection
						if cpu_memory_ready = '1' then
							fpu_memory_request <= '0';  -- Clear request
							timeout_counter <= 0;  -- Reset timeout
							fpu_state <= FPU_IDLE;
							fpu_done <= '1';
						elsif timeout_counter >= TIMEOUT_LIMIT_MEMORY then
							-- Memory write timeout - distinguish from real bus errors
							fpu_memory_request <= '0';  -- Clear request
							timeout_counter <= 0;
							fpu_exception <= '1';
							exception_code <= x"04";  -- Timeout error (not standard bus error)
							fpu_state <= FPU_EXCEPTION_STATE;
						else
							timeout_counter <= timeout_counter + 1;
						end if;
					
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
							-- Normal result - Store result to destination register (except for FTST/FCMP)
							if fpu_operation /= OP_FTST and fpu_operation /= OP_FCMP then
								fp_registers(to_integer(unsigned(dest_reg))) <= result_data;
							end if;
							
							-- Update FPSR condition codes based on result
							-- FPSR bits: [31-28] = CC, [27-24] = quotient, [23-16] = exception status, [15-8] = accrued exceptions, [7-0] = exception enable
							-- CC bits: N(3), Z(2), I(1), NaN(0)
							fpsr(31 downto 28) <= "0000";  -- Clear condition codes first
							
							-- Check for special values in result
							if result_data(78 downto 64) = "111111111111111" then
								-- Infinity or NaN
								if result_data(63 downto 0) = (63 downto 0 => '0') then
									-- Infinity
									fpsr(29) <= '1';  -- I (Infinity) bit
									if result_data(79) = '1' then
										fpsr(31) <= '1';  -- N (Negative) bit for -Infinity
									end if;
								else
									-- NaN
									fpsr(28) <= '1';  -- NaN bit
								end if;
							elsif result_data(78 downto 64) = (14 downto 0 => '0') and result_data(63 downto 0) = (63 downto 0 => '0') then
								-- Zero
								fpsr(30) <= '1';  -- Z (Zero) bit
								if result_data(79) = '1' then
									fpsr(31) <= '1';  -- N (Negative) bit for -0
								end if;
							else
								-- Normal number
								if result_data(79) = '1' then
									fpsr(31) <= '1';  -- N (Negative) bit
								end if;
							end if;
							
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
						-- Proper exception handling with FPSR updates
						fpu_done <= '1';
						
						-- Update FPSR exception status bits based on exception_code
						case exception_code is
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
						
						-- Update FPIAR with exception instruction address if needed
						-- fpiar <= current_instruction_address; -- Would need to be passed from CPU
						
						fpu_state <= FPU_IDLE;
					
					when FPU_FSAVE_WRITE =>
						-- Write proper MC68882 state frame for FPU detection
						-- MC68882 Frame Formats:
						-- $00000000 = Null frame (4 bytes) - no FPU present
						-- $18000000 = Idle frame (28 bytes) - FPU idle with no registers saved
						-- $41000000 = Idle frame with registers (216 bytes) - FPU idle with all registers
						-- $60180000 = Busy frame (92 bytes) - FPU executing instruction
						
						-- For AmigaOS detection, use idle frame with minimal state
						case fsave_counter is
							when 0 =>
								-- Frame format word - MC68882 idle frame (28 bytes)
								fsave_data <= x"18000000";  -- $18 = idle frame, 28 bytes total
							when 1 =>
								-- Next instruction address (FPIAR) - current PC or instruction address
								fsave_data <= fpiar;
							when 2 =>
								-- FPCR (Floating-Point Control Register)
								fsave_data <= fpcr;
							when 3 =>
								-- FPSR (Floating-Point Status Register) 
								fsave_data <= fpsr;
							when 4 =>
								-- FPIAR again (MC68882 format requirement)
								fsave_data <= fpiar;
							when 5 =>
								-- Reserved/padding
								fsave_data <= x"00000000";
							when 6 =>
								-- Reserved/padding  
								fsave_data <= x"00000000";
							when others =>
								-- Should not reach here with 28-byte frame
								fsave_data <= x"00000000";
						end case;
						
						-- Set up memory write with pre-decrement addressing
						fpu_address_out <= std_logic_vector(unsigned(fsave_address) - 4 * (fsave_counter + 1));
						fpu_data_out <= fsave_data;
						fpu_memory_request <= '1';
						fpu_read_write <= '1';  -- Write
						fpu_data_size <= "10";  -- Long word
						
						if cpu_memory_ready = '1' then
							fpu_memory_request <= '0';
							timeout_counter <= 0;  -- Reset timeout on successful transfer
							if fsave_counter < 6 then  -- Write 7 longwords (28 bytes) for idle frame
								fsave_counter <= fsave_counter + 1;
							else
								-- MC68882 idle frame complete - AmigaOS should now detect FPU
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
							end if;
						elsif timeout_counter >= TIMEOUT_LIMIT_FSAVE then
							-- FSAVE operation timeout
							fpu_memory_request <= '0';
							timeout_counter <= 0;
							fpu_exception <= '1';
							exception_code <= x"04";  -- Timeout error
							fpu_state <= FPU_EXCEPTION_STATE;
						else
							timeout_counter <= timeout_counter + 1;
						end if;
					
					when FPU_FRESTORE_READ =>
						-- FRESTORE - Read and restore complete FPU state
						fpu_address_out <= std_logic_vector(unsigned(cpu_address_in) + 4 * fsave_counter);
						fpu_memory_request <= '1';
						fpu_read_write <= '0';  -- Read
						fpu_data_size <= "10";  -- Long word
						
						if cpu_memory_ready = '1' then
							fpu_memory_request <= '0';
							-- Restore state based on longword number
							case fsave_counter is
								when 0 =>
									-- Format word - validate it's a valid state frame
									if cpu_memory_data(31 downto 24) = x"00" then
										-- Null frame - no state to restore, just complete
										fpu_state <= FPU_IDLE;
										fpu_done <= '1';
									elsif cpu_memory_data(31 downto 24) = x"18" then
										-- Idle frame - no registers to restore
										null;
									elsif cpu_memory_data(31 downto 24) = x"41" then
										-- Idle frame with registers
										null;
									elsif cpu_memory_data(31 downto 24) = x"60" then
										-- Busy frame 
										null;
									else
										-- Invalid format - trigger format error exception
										fpu_exception <= '1';
										exception_code <= x"0A";  -- Format error
									end if;
								when 1 =>
									-- Restore FPIAR
									fpiar <= cpu_memory_data;
								when 2 =>
									-- Restore FPCR
									fpcr <= cpu_memory_data;
								when 3 =>
									-- Restore FPSR
									fpsr <= cpu_memory_data;
								when 4 to 11 =>
									-- Restore high 32 bits of FP registers 0-7
									fp_registers(fsave_counter - 4)(79 downto 48) <= cpu_memory_data;
								when 12 to 19 =>
									-- Restore middle 32 bits of FP registers 0-7
									fp_registers(fsave_counter - 12)(47 downto 16) <= cpu_memory_data;
								when 20 to 27 =>
									-- Restore low 16 bits of FP registers 0-7
									fp_registers(fsave_counter - 20)(15 downto 0) <= cpu_memory_data(15 downto 0);
								when others =>
									null;
							end case;
							
							if fsave_counter < 27 then
								fsave_counter <= fsave_counter + 1;
							else
								-- All state restored
								fpu_state <= FPU_IDLE;
								fpu_done <= '1';
								end if;
						end if;
				end case;
			end if;
		end if;
	end process;
	
	-- Connect internal busy signal to output
	fpu_busy <= fpu_busy_internal;
	
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

end rtl;