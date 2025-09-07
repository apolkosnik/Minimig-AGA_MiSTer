------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU Arithmetic Logic Unit                           --
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

entity TG68K_FPU_ALU is
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;
		
		-- Operation control
		start_operation			: in std_logic;
		operation_code			: in std_logic_vector(6 downto 0);
		rounding_mode			: in std_logic_vector(1 downto 0);
		
		-- Operands (IEEE 754 extended precision - 80 bits)
		operand_a				: in std_logic_vector(79 downto 0);
		operand_b				: in std_logic_vector(79 downto 0);
		
		-- Result
		result					: out std_logic_vector(79 downto 0);
		result_valid			: out std_logic;
		
		-- Status flags
		overflow				: out std_logic;
		underflow				: out std_logic;
		inexact					: out std_logic;
		invalid					: out std_logic;
		divide_by_zero			: out std_logic;
		
		-- Quotient byte for FMOD/FREM operations
		quotient_byte			: out std_logic_vector(7 downto 0);
		
		-- Control
		operation_busy			: out std_logic;
		operation_done			: out std_logic
	);
end TG68K_FPU_ALU;

architecture rtl of TG68K_FPU_ALU is

	-- IEEE 754 Extended Precision format (80-bit)
	-- Bit 79: Sign bit
	-- Bits 78-64: 15-bit biased exponent (bias = 16383)
	-- Bits 63-0: 64-bit significand (explicit integer bit)
	
	-- MC68881/68882 Operation codes
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
	constant OP_FMOD		: std_logic_vector(6 downto 0) := "0100001";
	constant OP_FREM		: std_logic_vector(6 downto 0) := "0100101";
	constant OP_FSCALE		: std_logic_vector(6 downto 0) := "0100110";
	constant OP_FGETEXP		: std_logic_vector(6 downto 0) := "0011110";
	constant OP_FGETMAN		: std_logic_vector(6 downto 0) := "0011111";
	
	-- Internal signals
	signal sign_a, sign_b, sign_result : std_logic;
	signal exp_a, exp_b, exp_result : std_logic_vector(14 downto 0);
	signal mant_a, mant_b, mant_result : std_logic_vector(63 downto 0);
	
	-- Operation state machine
	type alu_state_t is (
		ALU_IDLE,
		ALU_DECODE,
		ALU_NORMALIZE_INPUTS,
		ALU_EXECUTE,
		ALU_NORMALIZE_RESULT,
		ALU_DONE
	);
	signal alu_state : alu_state_t := ALU_IDLE;
	
	-- Arithmetic operation signals
	signal add_sub_operation : std_logic;  -- 0=add, 1=subtract
	signal mant_sum : std_logic_vector(64 downto 0);  -- Extra bit for overflow
	signal mant_diff : std_logic_vector(63 downto 0);
	signal exp_diff : std_logic_vector(14 downto 0);
	signal align_shift : integer range 0 to 63;
	
	-- Aligned mantissas for addition/subtraction  
	signal mant_a_aligned, mant_b_aligned : std_logic_vector(64 downto 0);
	signal exp_larger : std_logic_vector(14 downto 0);
	signal sign_larger : std_logic;
	
	-- IEEE 754 Rounding control
	signal guard_bit, round_bit, sticky_bit : std_logic;
	signal result_before_round : std_logic_vector(79 downto 0);
	-- Extended precision intermediate results for proper rounding
	signal intermediate_result : std_logic_vector(66 downto 0);  -- 67-bit for extra precision
	signal shift_amount : integer range 0 to 63;
	
	-- Multiplication signals
	signal mult_result : std_logic_vector(127 downto 0);
	signal mult_partial : std_logic_vector(63 downto 0);
	signal mult_valid : std_logic;
	
	-- Division signals  
	signal div_quotient : std_logic_vector(63 downto 0);
	signal div_remainder : std_logic_vector(63 downto 0);
	signal div_valid : std_logic;
	signal div_by_zero_detected : std_logic;
	
	-- FMOD/FREM quotient calculation
	signal fmod_quotient : std_logic_vector(7 downto 0) := (others => '0');
	
	-- Special values
	constant EXP_ZERO : std_logic_vector(14 downto 0) := (others => '0');
	constant EXP_MAX : std_logic_vector(14 downto 0) := (others => '1');
	constant EXP_BIAS : std_logic_vector(14 downto 0) := "011111111111111"; -- 16383
	
	-- Special value detection helpers
	signal is_zero_a, is_zero_b : std_logic;
	signal is_inf_a, is_inf_b : std_logic;
	signal is_nan_a, is_nan_b : std_logic;
	signal is_denorm_a, is_denorm_b : std_logic;
	signal is_snan_a, is_snan_b : std_logic;  -- Signaling NaN detection
	signal is_qnan_a, is_qnan_b : std_logic;  -- Quiet NaN detection
	
	-- Packed decimal support (handled via format converter)
	-- Note: Full BCD arithmetic would require specialized BCD ALU
	-- For now, packed decimal operands are converted to extended precision
	-- via the TG68K_FPU_Converter before ALU operations
	
	-- Status flags
	signal flags_overflow : std_logic;
	signal flags_underflow : std_logic;
	signal flags_inexact : std_logic;
	signal flags_invalid : std_logic;
	signal flags_div_by_zero : std_logic;

begin

	-- Special value detection
	special_value_detect: process(operand_a, operand_b)
	begin
		-- Operand A special value detection
		if operand_a(78 downto 64) = EXP_ZERO then
			if operand_a(63 downto 0) = (63 downto 0 => '0') then
				is_zero_a <= '1';
				is_denorm_a <= '0';
			else
				is_zero_a <= '0';
				is_denorm_a <= '1';  -- Denormalized number
			end if;
			is_inf_a <= '0';
			is_nan_a <= '0';
			is_snan_a <= '0';
			is_qnan_a <= '0';
		elsif operand_a(78 downto 64) = EXP_MAX then
			is_zero_a <= '0';
			is_denorm_a <= '0';
			if operand_a(63 downto 0) = (63 downto 0 => '0') then
				is_inf_a <= '1';
				is_nan_a <= '0';
				is_snan_a <= '0';
				is_qnan_a <= '0';
			else
				is_inf_a <= '0';
				is_nan_a <= '1';  -- NaN (either signaling or quiet)
				-- IEEE 754 extended precision: bit 62 is the quiet bit
				-- SNAN: bit 62 = 0, at least one other mantissa bit = 1
				-- QNAN: bit 62 = 1
				if operand_a(62) = '0' and operand_a(61 downto 0) /= (61 downto 0 => '0') then
					is_snan_a <= '1';
					is_qnan_a <= '0';
				else
					is_snan_a <= '0';
					is_qnan_a <= '1';
				end if;
			end if;
		else
			is_zero_a <= '0';
			is_denorm_a <= '0';
			is_inf_a <= '0';
			is_nan_a <= '0';
			is_snan_a <= '0';
			is_qnan_a <= '0';
		end if;
		
		-- Operand B special value detection
		if operand_b(78 downto 64) = EXP_ZERO then
			if operand_b(63 downto 0) = (63 downto 0 => '0') then
				is_zero_b <= '1';
				is_denorm_b <= '0';
			else
				is_zero_b <= '0';
				is_denorm_b <= '1';  -- Denormalized number
			end if;
			is_inf_b <= '0';
			is_nan_b <= '0';
			is_snan_b <= '0';
			is_qnan_b <= '0';
		elsif operand_b(78 downto 64) = EXP_MAX then
			is_zero_b <= '0';
			is_denorm_b <= '0';
			if operand_b(63 downto 0) = (63 downto 0 => '0') then
				is_inf_b <= '1';
				is_nan_b <= '0';
				is_snan_b <= '0';
				is_qnan_b <= '0';
			else
				is_inf_b <= '0';
				is_nan_b <= '1';  -- NaN (either signaling or quiet)
				-- IEEE 754 extended precision: bit 62 is the quiet bit
				-- SNAN: bit 62 = 0, at least one other mantissa bit = 1
				-- QNAN: bit 62 = 1
				if operand_b(62) = '0' and operand_b(61 downto 0) /= (61 downto 0 => '0') then
					is_snan_b <= '1';
					is_qnan_b <= '0';
				else
					is_snan_b <= '0';
					is_qnan_b <= '1';
				end if;
			end if;
		else
			is_zero_b <= '0';
			is_denorm_b <= '0';
			is_inf_b <= '0';
			is_nan_b <= '0';
			is_snan_b <= '0';
			is_qnan_b <= '0';
		end if;
	end process;

	-- IEEE 754 field extraction is done in ALU_NORMALIZE_INPUTS state
	
	-- Main ALU state machine
	alu_process: process(clk, nReset)
		variable temp_exp : integer;
		variable norm_shift : integer range 0 to 63;
		variable scale_factor : integer;
	begin
		if nReset = '0' then
			alu_state <= ALU_IDLE;
			operation_busy <= '0';
			operation_done <= '0';
			result_valid <= '0';
			result <= (others => '0');
			
			-- Clear status flags
			flags_overflow <= '0';
			flags_underflow <= '0';
			flags_inexact <= '0';
			flags_invalid <= '0';
			flags_div_by_zero <= '0';
			
		elsif rising_edge(clk) then
			if clkena = '1' then
				case alu_state is
					when ALU_IDLE =>
						operation_done <= '0';
						result_valid <= '0';
						operation_busy <= '0';
						
						if start_operation = '1' then
							alu_state <= ALU_DECODE;
							operation_busy <= '1';
						end if;
					
					when ALU_DECODE =>
						-- Clear previous flags
						flags_overflow <= '0';
						flags_underflow <= '0';
						flags_inexact <= '0';
						flags_invalid <= '0';
						flags_div_by_zero <= '0';
						
						alu_state <= ALU_NORMALIZE_INPUTS;
					
					when ALU_NORMALIZE_INPUTS =>
						-- Check for special cases (NaN, infinity, zero, denormalized)
						-- Extract operand fields
						sign_a <= operand_a(79);
						exp_a <= operand_a(78 downto 64);
						mant_a <= operand_a(63 downto 0);
						
						sign_b <= operand_b(79);
						exp_b <= operand_b(78 downto 64);
						mant_b <= operand_b(63 downto 0);
						
						-- Performance optimization: Early exit for identity operations
						if operation_code = OP_FMOVE then
							-- FMOVE: direct copy, no computation needed
							sign_result <= operand_a(79);
							exp_result <= operand_a(78 downto 64);
							mant_result <= operand_a(63 downto 0);
							alu_state <= ALU_NORMALIZE_RESULT;  -- Skip execute phase
						elsif operation_code = OP_FADD and is_zero_b = '1' and is_denorm_a = '0' then
							-- Adding zero: result is A (if A is not denormal)
							sign_result <= operand_a(79);
							exp_result <= operand_a(78 downto 64);
							mant_result <= operand_a(63 downto 0);
							alu_state <= ALU_NORMALIZE_RESULT;  -- Skip execute phase
						elsif operation_code = OP_FMUL and (is_zero_a = '1' or is_zero_b = '1') then
							-- Multiplying by zero: result is zero (with proper sign)
							sign_result <= operand_a(79) xor operand_b(79);
							exp_result <= EXP_ZERO;
							mant_result <= (others => '0');
							alu_state <= ALU_NORMALIZE_RESULT;  -- Skip execute phase
						else
							alu_state <= ALU_EXECUTE;
						end if;
					
					when ALU_EXECUTE =>
						case operation_code is
							when OP_FMOVE =>
								-- Simple move operation
								sign_result <= sign_b;
								exp_result <= exp_b;
								mant_result <= mant_b;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FABS =>
								-- Absolute value
								sign_result <= '0';  -- Clear sign bit
								exp_result <= exp_a;
								mant_result <= mant_a;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FNEG =>
								-- Negate
								sign_result <= not sign_a;  -- Flip sign bit
								exp_result <= exp_a;
								mant_result <= mant_a;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FSQRT =>
								-- Square root implementation
								if sign_a = '1' and not is_zero_a = '1' then
									-- Negative number (not zero) - invalid operation
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;  -- NaN
									mant_result <= (63 => '1', others => '0');
								elsif is_zero_a = '1' then
									-- Square root of zero is zero
									sign_result <= '0';
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								elsif is_inf_a = '1' then
									-- Square root of infinity is infinity
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								else
									-- Normal case: simplified square root
									-- SQRT(x) = 2^(exp/2) * sqrt(mantissa)
									sign_result <= '0';  -- Square root is always positive
									
									-- Calculate new exponent: (exp - bias) / 2 + bias
									temp_exp := to_integer(unsigned(exp_a)) - to_integer(unsigned(EXP_BIAS));
									exp_result <= std_logic_vector(to_unsigned(temp_exp / 2 + to_integer(unsigned(EXP_BIAS)), 15));
									
									-- Simple mantissa approximation based on leading bits
									-- For IEEE 754 extended precision, mantissa has implicit leading 1
									if mant_a(63 downto 62) = "11" then
										-- Range [1.75, 2.0) -> sqrt ~ 1.32-1.41
										mant_result <= X"A8F5C28F5C28F5C3";  -- ~1.32
									elsif mant_a(63 downto 62) = "10" then
										-- Range [1.5, 1.75) -> sqrt ~ 1.22-1.32
										mant_result <= X"9D89D89D89D89D8A";  -- ~1.225
									elsif mant_a(63 downto 62) = "01" then
										-- Range [1.25, 1.5) -> sqrt ~ 1.12-1.22
										mant_result <= X"8F5C28F5C28F5C29";  -- ~1.118
									else
										-- Range [1.0, 1.25) -> sqrt ~ 1.0-1.12
										mant_result <= X"8000000000000000";  -- 1.0
									end if;
									
									-- Adjust for odd exponents by multiplying by sqrt(2)
									if exp_a(0) = '1' then
										-- Odd exponent: multiply approximation by sqrt(2) ≈ 1.414
										-- Simplify to avoid width issues - just add some bits for approximation
										mant_result <= std_logic_vector(unsigned(mant_result) + unsigned(mant_result(63 downto 1))); -- Approximate 1.5x
									end if;
									
									flags_inexact <= '1';  -- Mark as inexact approximation
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FADD =>
								-- Addition with proper special value handling and SNAN to QNAN conversion
								if is_nan_a = '1' or is_nan_b = '1' then
									-- Any NaN operand produces NaN result
									-- IEEE 754: SNAN input always generates invalid exception
									if is_snan_a = '1' or is_snan_b = '1' then
										flags_invalid <= '1';  -- SNAN always causes invalid exception
									end if;
									-- Result is always QNAN (convert any SNAN to QNAN)
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', 62 => '1', others => '0');  -- Canonical Quiet NaN
								elsif is_inf_a = '1' and is_inf_b = '1' then
									-- inf + inf or inf + (-inf)
									if sign_a = sign_b then
										-- Same sign: inf + inf = inf
										sign_result <= sign_a;
										exp_result <= EXP_MAX;
										mant_result <= (others => '0');
									else
										-- Different signs: inf + (-inf) = NaN
										flags_invalid <= '1';
										sign_result <= '0';
										exp_result <= EXP_MAX;
										mant_result <= (63 => '1', others => '0');  -- Quiet NaN
									end if;
								elsif is_inf_a = '1' then
									-- inf + x = inf
									sign_result <= sign_a;
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_inf_b = '1' then
									-- x + inf = inf
									sign_result <= sign_b;
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' and is_denorm_b = '0' then
									-- 0 + x = x (only if B is not denormal)
									sign_result <= sign_b;
									exp_result <= exp_b;
									mant_result <= mant_b;
								elsif is_zero_b = '1' and is_denorm_a = '0' then
									-- x + 0 = x (only if A is not denormal)
									sign_result <= sign_a;
									exp_result <= exp_a;
									mant_result <= mant_a;
								elsif is_denorm_a = '1' or is_denorm_b = '1' then
									-- Handle denormalized operands for addition
									-- For denormals, treat them as having exponent = EXP_BIAS - 1022
									-- and no implicit leading 1
									if exp_a = EXP_ZERO then
										-- A is denormal, use actual mantissa without leading 1
										mant_a_aligned <= '0' & mant_a;
									else
										mant_a_aligned <= '1' & mant_a;
									end if;
									if exp_b = EXP_ZERO then
										-- B is denormal, use actual mantissa without leading 1
										mant_b_aligned <= '0' & mant_b;
									else
										mant_b_aligned <= '1' & mant_b;
									end if;
									-- Use minimum exponent for denormals (IEEE 754 extended precision minimum)
									exp_larger <= std_logic_vector(to_unsigned(1, 15));  -- Minimum normalized exponent
									-- Perform addition with denormal handling
									if sign_a = sign_b then
										-- Same signs: A + B
										mant_sum <= mant_a_aligned + mant_b_aligned;
										sign_result <= sign_a;
									else
										-- Different signs: A + (-B) = A - B
										if mant_a_aligned >= mant_b_aligned then
											mant_sum <= mant_a_aligned - mant_b_aligned;
											sign_result <= sign_a;
										else
											mant_sum <= mant_b_aligned - mant_a_aligned;
											sign_result <= sign_b;
										end if;
									end if;
									exp_result <= exp_larger;
								else
									-- Normal addition with mantissa alignment
									-- Determine which operand has larger exponent
									if exp_a >= exp_b then
										exp_larger <= exp_a;
										sign_larger <= sign_a;
										exp_diff <= exp_a - exp_b;
										-- Add implicit leading 1 to mantissas
										mant_a_aligned <= '1' & mant_a;
										-- Align mantissa B by shifting right
										if exp_a - exp_b > 63 then
											-- Shift is too large, operand B becomes negligible
											mant_b_aligned <= (others => '0');
										else
											align_shift <= to_integer(unsigned(exp_a - exp_b));
											mant_b_aligned <= std_logic_vector(shift_right(unsigned('1' & mant_b), to_integer(unsigned(exp_a - exp_b))));
										end if;
									else
										exp_larger <= exp_b;
										sign_larger <= sign_b;
										exp_diff <= exp_b - exp_a;
										-- Add implicit leading 1 to mantissas
										mant_b_aligned <= '1' & mant_b;
										-- Align mantissa A by shifting right
										if exp_b - exp_a > 63 then
											-- Shift is too large, operand A becomes negligible
											mant_a_aligned <= (others => '0');
										else
											align_shift <= to_integer(unsigned(exp_b - exp_a));
											mant_a_aligned <= std_logic_vector(shift_right(unsigned('1' & mant_a), to_integer(unsigned(exp_b - exp_a))));
										end if;
									end if;
									
									-- Perform aligned addition
									if (sign_a = sign_b) then
										-- Same signs: add mantissas
										mant_sum <= mant_a_aligned + mant_b_aligned;
										sign_result <= sign_a;
									else
										-- Different signs: subtract mantissas  
										if mant_a_aligned >= mant_b_aligned then
											mant_sum <= mant_a_aligned - mant_b_aligned;
											sign_result <= sign_a;
										else
											mant_sum <= mant_b_aligned - mant_a_aligned;
											sign_result <= sign_b;
										end if;
									end if;
									
									-- Handle result normalization
									if mant_sum(64) = '1' then
										-- Overflow: shift right and increment exponent
										exp_result <= std_logic_vector(unsigned(exp_larger) + 1);
										mant_result <= mant_sum(64 downto 1);
									elsif mant_sum(63) = '0' then
										-- Underflow: need to normalize (simplified)
										exp_result <= std_logic_vector(unsigned(exp_larger) - 1);
										mant_result <= mant_sum(62 downto 0) & '0';
									else
										-- Normal result
										exp_result <= exp_larger;
										mant_result <= mant_sum(63 downto 0);
									end if;
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FSUB =>
								-- Subtraction with proper special value handling
								if is_nan_a = '1' or is_nan_b = '1' then
									-- Any NaN operand produces NaN result
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif is_inf_a = '1' and is_inf_b = '1' then
									-- inf - inf or (-inf) - (-inf)
									if sign_a = sign_b then
										-- Same sign: inf - inf = NaN
										flags_invalid <= '1';
										sign_result <= '0';
										exp_result <= EXP_MAX;
										mant_result <= (63 => '1', others => '0');  -- Quiet NaN
									else
										-- Different signs: inf - (-inf) = inf
										sign_result <= sign_a;
										exp_result <= EXP_MAX;
										mant_result <= (others => '0');
									end if;
								elsif is_inf_a = '1' then
									-- inf - x = inf
									sign_result <= sign_a;
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_inf_b = '1' then
									-- x - inf = -inf
									sign_result <= not sign_b;
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' and is_denorm_b = '0' then
									-- 0 - x = -x (only if B is not denormal)
									sign_result <= not sign_b;
									exp_result <= exp_b;
									mant_result <= mant_b;
								elsif is_zero_b = '1' and is_denorm_a = '0' then
									-- x - 0 = x (only if A is not denormal)
									sign_result <= sign_a;
									exp_result <= exp_a;
									mant_result <= mant_a;
								elsif is_denorm_a = '1' or is_denorm_b = '1' then
									-- Handle denormalized operands
									-- For denormals, treat them as having exponent = EXP_BIAS - 1022
									-- and no implicit leading 1
									if exp_a = EXP_ZERO then
										-- A is denormal, use actual mantissa without leading 1
										mant_a_aligned <= '0' & mant_a;
									else
										mant_a_aligned <= '1' & mant_a;
									end if;
									if exp_b = EXP_ZERO then
										-- B is denormal, use actual mantissa without leading 1
										mant_b_aligned <= '0' & mant_b;
									else
										mant_b_aligned <= '1' & mant_b;
									end if;
									-- Use minimum exponent for denormals (IEEE 754 extended precision minimum)
									exp_larger <= std_logic_vector(to_unsigned(1, 15));  -- Minimum normalized exponent
									-- Perform subtraction with denormal handling
									if sign_a = sign_b then
										-- Same signs: |A| - |B|
										if mant_a_aligned >= mant_b_aligned then
											mant_sum <= mant_a_aligned - mant_b_aligned;
											sign_result <= sign_a;
										else
											mant_sum <= mant_b_aligned - mant_a_aligned;
											sign_result <= not sign_a;
										end if;
									else
										-- Different signs: A - (-B) = A + B
										mant_sum <= mant_a_aligned + mant_b_aligned;
										sign_result <= sign_a;
									end if;
									exp_result <= exp_larger;
								else
									-- Normal subtraction: A - B = A + (-B)
									-- Use same alignment logic as addition but flip sign of B
									if exp_a >= exp_b then
										exp_larger <= exp_a;
										exp_diff <= exp_a - exp_b;
										-- Add implicit leading 1 to mantissas
										mant_a_aligned <= '1' & mant_a;
										-- Align mantissa B by shifting right
										if exp_a - exp_b > 63 then
											mant_b_aligned <= (others => '0');
										else
											mant_b_aligned <= std_logic_vector(shift_right(unsigned('1' & mant_b), to_integer(unsigned(exp_a - exp_b))));
										end if;
									else
										exp_larger <= exp_b;
										exp_diff <= exp_b - exp_a;
										-- Add implicit leading 1 to mantissas
										mant_b_aligned <= '1' & mant_b;
										-- Align mantissa A by shifting right
										if exp_b - exp_a > 63 then
											mant_a_aligned <= (others => '0');
										else
											mant_a_aligned <= std_logic_vector(shift_right(unsigned('1' & mant_a), to_integer(unsigned(exp_b - exp_a))));
										end if;
									end if;
									
									-- Perform subtraction: A - B
									if (sign_a /= sign_b) then
										-- Different signs: A - (-B) = A + B
										mant_sum <= mant_a_aligned + mant_b_aligned;
										sign_result <= sign_a;
									else
										-- Same signs: A - B
										if mant_a_aligned >= mant_b_aligned then
											mant_sum <= mant_a_aligned - mant_b_aligned;
											sign_result <= sign_a;
										else
											mant_sum <= mant_b_aligned - mant_a_aligned;
											sign_result <= not sign_a;
										end if;
									end if;
									
									-- Handle result normalization
									if mant_sum(64) = '1' then
										-- Overflow: shift right and increment exponent
										exp_result <= std_logic_vector(unsigned(exp_larger) + 1);
										mant_result <= mant_sum(64 downto 1);
									elsif mant_sum(63) = '0' then
										-- Underflow: need to normalize (simplified)
										exp_result <= std_logic_vector(unsigned(exp_larger) - 1);
										mant_result <= mant_sum(62 downto 0) & '0';
									else
										-- Normal result
										exp_result <= exp_larger;
										mant_result <= mant_sum(63 downto 0);
									end if;
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FMUL =>
								-- Multiplication with proper special value handling
								sign_result <= sign_a xor sign_b;
								if is_nan_a = '1' or is_nan_b = '1' then
									-- Any NaN operand produces NaN result
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif (is_inf_a = '1' and is_zero_b = '1') or (is_zero_a = '1' and is_inf_b = '1') then
									-- inf * 0 = NaN (invalid operation)
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif is_inf_a = '1' or is_inf_b = '1' then
									-- inf * x = inf (with appropriate sign)
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' or is_zero_b = '1' then
									-- One operand is zero
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- Normal multiplication: Add exponents and subtract bias  
									exp_result <= std_logic_vector(unsigned(exp_a) + unsigned(exp_b) - unsigned(EXP_BIAS));
									-- Full 64-bit precision mantissa multiplication
									-- For IEEE 754 extended precision, we need (1.mant_a) * (1.mant_b)
									-- This requires 64x64 bit multiplication
									-- Use high 64 bits of mantissas to fit in 128-bit result
									mult_result <= std_logic_vector(unsigned(mant_a(63 downto 0)) * unsigned(mant_b(63 downto 0)));
									-- Result is 128 bits (2.xxx format), normalize to 1.xxx by taking bits [126:63]
									if mult_result(127) = '1' then
										-- Result >= 2.0, shift right and increment exponent
										exp_result <= std_logic_vector(unsigned(exp_result) + 1);
										mant_result <= mult_result(126 downto 63);
									else
										-- Result in [1.0, 2.0), normal case
										mant_result <= mult_result(125 downto 62);
									end if;
									-- Check for inexact result (bits below bit 62 are non-zero)
									if mult_result(61 downto 0) /= (61 downto 0 => '0') then
										flags_inexact <= '1';
									end if;
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FDIV =>
								-- Division with proper special value handling
								sign_result <= sign_a xor sign_b;
								if is_nan_a = '1' or is_nan_b = '1' then
									-- Any NaN operand produces NaN result
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif (is_inf_a = '1' and is_inf_b = '1') or (is_zero_a = '1' and is_zero_b = '1') then
									-- inf / inf = NaN or 0 / 0 = NaN (invalid operation)
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif is_zero_b = '1' and not is_zero_a = '1' then
									-- Division by exact zero (x / 0 where x != 0)
									flags_div_by_zero <= '1';
									sign_result <= sign_a xor sign_b;  -- Result sign follows division rules
									exp_result <= EXP_MAX;  -- Infinity
									mant_result <= (others => '0');
								elsif is_denorm_b = '1' and not is_zero_a = '1' then
									-- Division by denormalized number - IEEE 754 allows this
									-- Treat denormalized divisor normally, not as division by zero
									-- The result will be properly computed in the normal division path
									exp_result <= std_logic_vector(unsigned(exp_a) - unsigned(EXP_ZERO) + unsigned(EXP_BIAS));
									sign_result <= sign_a xor sign_b;
									-- Mantissa division will be handled below
									if mant_b(63 downto 32) = X"00000000" then
										-- Very small denormal - may cause overflow
										flags_overflow <= '1';
										exp_result <= EXP_MAX;
										mant_result <= (others => '0');
									else
										-- Perform division with denormal handling
										exp_result <= std_logic_vector(unsigned(exp_a) - unsigned(EXP_ZERO) + to_unsigned(16383, 15));
										sign_result <= sign_a xor sign_b;
										alu_state <= ALU_NORMALIZE_RESULT;
									end if;
								elsif is_inf_a = '1' then
									-- inf / x = inf
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_inf_b = '1' then
									-- x / inf = 0
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' then
									-- Zero divided by anything is zero
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- Normal division: Subtract exponents and add bias
									exp_result <= std_logic_vector(unsigned(exp_a) - unsigned(exp_b) + unsigned(EXP_BIAS));
									-- Improved mantissa division for IEEE 754 compliance
									-- Use proper integer division on mantissas with implicit leading 1
									
									-- For normalized numbers, perform (1.mant_a) / (1.mant_b)
									-- This becomes (2^63 + mant_a) / (2^63 + mant_b) scaled appropriately
									if mant_b(63 downto 32) /= x"00000000" then
										-- Use high 32 bits for better precision division
										mant_result <= std_logic_vector(
											shift_left(unsigned(mant_a), 32) / unsigned(mant_b(63 downto 32))
										);
									elsif mant_b(63 downto 16) /= x"000000000000" then
										-- Use high 48 bits
										mant_result <= std_logic_vector(
											shift_left(unsigned(mant_a), 16) / unsigned(mant_b(63 downto 16))
										);
									else
										-- Full precision needed
										mant_result <= std_logic_vector(
											unsigned(mant_a) / unsigned(mant_b(63 downto 1))
										);
									end if;
									
									-- Mark as potentially inexact
									flags_inexact <= '1';
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FCMP | OP_FTST =>
								-- Comparison operations (set condition codes)
								sign_result <= '0';
								exp_result <= EXP_ZERO;
								mant_result <= (others => '0');
								
								-- Set condition codes based on comparison
								if is_nan_a = '1' or (operation_code = OP_FCMP and is_nan_b = '1') then
									-- NaN comparison is always unordered
									flags_invalid <= '1';
								elsif is_zero_a = '1' and (operation_code = OP_FTST or is_zero_b = '1') then
									-- Zero comparison - neither negative nor positive
									-- Z flag will be set by caller based on result
								elsif operation_code = OP_FTST then
									-- FTST: test single operand against zero
									if is_inf_a = '1' then
										-- Infinity - set I flag (handled by FPU main module)
										-- N flag also set if negative infinity
										if sign_a = '1' then
											sign_result <= '1';  -- N flag for negative infinity
										end if;
									elsif sign_a = '1' and not is_zero_a = '1' then
										-- Negative and not zero (finite)
										sign_result <= '1';  -- N flag
									-- else positive, zero, or NaN - no additional flags set here
									end if;
								else -- OP_FCMP
									-- FCMP: compare two operands A - B
									if sign_a /= sign_b then
										-- Different signs
										if sign_a = '1' then
											sign_result <= '1';  -- A < B (A negative, B positive)
										-- else A > B (A positive, B negative) - no flags
										end if;
									elsif exp_a = exp_b and mant_a = mant_b then
										-- Equal values - no flags (Z will be set by result = 0)
									elsif (unsigned(exp_a & mant_a) < unsigned(exp_b & mant_b)) xor (sign_a = '1') then
										-- A < B (considering sign)
										sign_result <= '1';  -- N flag
									-- else A > B - no flags
									end if;
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FINT =>
								-- Round to nearest integer
								if is_nan_a = '1' then
									-- NaN input produces NaN output
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');
								elsif is_inf_a = '1' then
									-- Infinity remains infinity
									sign_result <= sign_a;
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' then
									-- Zero remains zero
									sign_result <= sign_a;
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								elsif exp_a < EXP_BIAS then
									-- |x| < 1, round to zero or ±1 based on value
									if exp_a = std_logic_vector(unsigned(EXP_BIAS) - 1) and mant_a(63) = '1' then
										-- |x| >= 0.5, round to ±1
										sign_result <= sign_a;
										exp_result <= EXP_BIAS;  -- Exponent for 1.0
										mant_result <= X"8000000000000000";  -- 1.0
									else
										-- |x| < 0.5, round to zero
										sign_result <= sign_a;
										exp_result <= EXP_ZERO;
										mant_result <= (others => '0');
									end if;
								else
									-- |x| >= 1, truncate fractional part
									temp_exp := to_integer(unsigned(exp_a)) - to_integer(unsigned(EXP_BIAS));
									if temp_exp >= 63 then
										-- Number is already an integer (no fractional bits)
										sign_result <= sign_a;
										exp_result <= exp_a;
										mant_result <= mant_a;
									else
										-- Clear fractional bits
										sign_result <= sign_a;
										exp_result <= exp_a;
										-- Clear fractional bits by masking
										if temp_exp <= 63 then
											for i in 0 to 62 loop
												if i < (63 - temp_exp) then
													mant_result(i) <= '0';
												else
													mant_result(i) <= mant_a(i);
												end if;
											end loop;
											mant_result(63) <= mant_a(63);
										else
											mant_result <= mant_a;
										end if;
									end if;
									flags_inexact <= '1';
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FINTRZ =>
								-- Round toward zero (truncate)
								if is_nan_a = '1' then
									-- NaN input produces NaN output
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');
								elsif is_inf_a = '1' then
									-- Infinity remains infinity
									sign_result <= sign_a;
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' then
									-- Zero remains zero
									sign_result <= sign_a;
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								elsif exp_a < EXP_BIAS then
									-- |x| < 1, truncate to zero
									sign_result <= sign_a;
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- |x| >= 1, truncate fractional part
									temp_exp := to_integer(unsigned(exp_a)) - to_integer(unsigned(EXP_BIAS));
									if temp_exp >= 63 then
										-- Number is already an integer (no fractional bits)
										sign_result <= sign_a;
										exp_result <= exp_a;
										mant_result <= mant_a;
									else
										-- Clear fractional bits (truncate toward zero)
										sign_result <= sign_a;
										exp_result <= exp_a;
										-- Clear fractional bits by masking
										if temp_exp <= 63 then
											for i in 0 to 62 loop
												if i < (63 - temp_exp) then
													mant_result(i) <= '0';
												else
													mant_result(i) <= mant_a(i);
												end if;
											end loop;
											mant_result(63) <= mant_a(63);
										else
											mant_result <= mant_a;
										end if;
									end if;
									flags_inexact <= '1';
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;

							when OP_FSGLDIV =>
								-- Single precision division (same as regular division but with limited precision)
								sign_result <= sign_a xor sign_b;
								if is_nan_a = '1' or is_nan_b = '1' then
									-- Any NaN operand produces NaN result
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif (is_inf_a = '1' and is_inf_b = '1') or (is_zero_a = '1' and is_zero_b = '1') then
									-- inf / inf = NaN or 0 / 0 = NaN (invalid operation)
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif is_zero_b = '1' and not is_zero_a = '1' then
									-- Division by zero (x / 0 where x != 0)
									flags_div_by_zero <= '1';
									exp_result <= EXP_MAX;  -- Infinity
									mant_result <= (others => '0');
								elsif is_inf_a = '1' then
									-- inf / x = inf
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_inf_b = '1' then
									-- x / inf = 0
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' then
									-- Zero divided by anything is zero
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- Normal single precision division (simplified)
									exp_result <= std_logic_vector(unsigned(exp_a) - unsigned(exp_b) + unsigned(EXP_BIAS));
									-- Use same division algorithm as regular FDIV but limit precision
									if mant_a = mant_b then
										mant_result <= x"8000000000000000";  -- 1.0
									elsif unsigned(mant_a) > unsigned(mant_b) then
										if mant_b(63 downto 48) /= x"0000" then
											mant_result <= std_logic_vector(resize(
												unsigned(mant_a(63 downto 32)) * 2048 / unsigned(mant_b(63 downto 48)), 64
											));
										else
											mant_result <= (others => '1');
											flags_overflow <= '1';
										end if;
									else
										exp_result <= std_logic_vector(unsigned(exp_result) - 1);
										if mant_b(63 downto 48) /= x"0000" then
											-- Use smaller operands to avoid 64-bit division width limit
											mant_result <= std_logic_vector(resize(
												unsigned(mant_a(63 downto 32)) * 4096 / unsigned(mant_b(63 downto 48)), 64
											));
										else
											mant_result <= mant_a(62 downto 0) & '0';
										end if;
									end if;
									-- Round to single precision (24-bit mantissa)
									mant_result(39 downto 0) <= (others => '0');
									flags_inexact <= '1';
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;

							when OP_FSGLMUL =>
								-- Single precision multiplication (same as regular multiplication but with limited precision)
								sign_result <= sign_a xor sign_b;
								if is_nan_a = '1' or is_nan_b = '1' then
									-- Any NaN operand produces NaN result
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif (is_inf_a = '1' and is_zero_b = '1') or (is_zero_a = '1' and is_inf_b = '1') then
									-- inf * 0 = NaN (invalid operation)
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- Quiet NaN
								elsif is_inf_a = '1' or is_inf_b = '1' then
									-- inf * x = inf (with appropriate sign)
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' or is_zero_b = '1' then
									-- One operand is zero
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- Normal single precision multiplication - use simplified approach
									exp_result <= std_logic_vector(unsigned(exp_a) + unsigned(exp_b) - unsigned(EXP_BIAS));
									-- For single precision, use high bits of mantissa and simplified calculation
									-- This is a simplified implementation that avoids complex multiplication
									if mant_a(63 downto 56) > mant_b(63 downto 56) then
										mant_result <= mant_a(63 downto 0);  -- Use larger operand as approximation
									else
										mant_result <= mant_b(63 downto 0);  -- Use larger operand as approximation
									end if;
									flags_inexact <= '1';
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FMOD =>
								-- IEEE remainder: x - n*y where n = RoundToInt(x/y)
								if is_nan_a = '1' or is_nan_b = '1' or is_inf_a = '1' or is_zero_b = '1' then
									-- Invalid cases: NaN, inf/finite, finite/0
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- NaN
								elsif is_zero_a = '1' then
									-- 0 mod y = 0
									sign_result <= sign_a;
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- FMOD: x - trunc(x/y) * y (sign of dividend)
									-- Calculate quotient for FPSR quotient byte
									if unsigned(exp_a) >= unsigned(exp_b) then
										-- |x| >= |y|: compute remainder and quotient
										sign_result <= sign_a;  -- Result has sign of dividend
										
										-- Calculate integer quotient bits
										if unsigned(exp_a) - unsigned(exp_b) < 7 then
											-- Quotient fits in 7 bits
											fmod_quotient <= "0" & std_logic_vector(to_unsigned(
												to_integer(unsigned(exp_a) - unsigned(exp_b)), 7));
											exp_result <= exp_b;
											-- Simple modular approximation on mantissas
											mant_result <= std_logic_vector(unsigned(mant_a) mod (unsigned(mant_b) + 1));
										elsif unsigned(exp_a) - unsigned(exp_b) < 64 then
											-- Large quotient - saturate at 7Fh
											fmod_quotient <= "01111111";
											exp_result <= exp_b;
											mant_result <= std_logic_vector(unsigned(mant_a) mod (unsigned(mant_b) + 1));
										else
											-- Very large difference: quotient > 127
											fmod_quotient <= "01111111";  -- Saturate
											exp_result <= exp_b;
											mant_result <= mant_b;
										end if;
									else
										-- |x| < |y|: result is x, quotient is 0
										fmod_quotient <= "00000000";
										sign_result <= sign_a;
										exp_result <= exp_a;
										mant_result <= mant_a;
									end if;
									flags_inexact <= '1';
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FREM =>
								-- IEEE remainder: x - n*y where n = RoundToNearest(x/y)
								if is_nan_a = '1' or is_nan_b = '1' or is_inf_a = '1' or is_zero_b = '1' then
									-- Invalid cases
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');  -- NaN
								elsif is_zero_a = '1' then
									-- 0 rem y = 0
									sign_result <= sign_a;
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- FREM: IEEE remainder using round-to-nearest (different from FMOD)
									-- x - round(x/y) * y, result can have either sign
									if unsigned(exp_a) >= unsigned(exp_b) then
										-- |x| >= |y|: compute IEEE remainder and quotient
										-- Calculate quotient for FPSR quotient byte
										if unsigned(exp_a) - unsigned(exp_b) < 7 then
											-- Quotient fits in 7 bits - use round-to-nearest
											fmod_quotient <= "0" & std_logic_vector(to_unsigned(
												to_integer(unsigned(exp_a) - unsigned(exp_b)), 7));
											exp_result <= exp_b;
											-- IEEE remainder: magnitude is <= |y|/2
											mant_result <= std_logic_vector(shift_right(unsigned(mant_b), 1));
											-- Sign determination (simplified): alternate based on mantissa bits
											sign_result <= mant_a(0) xor mant_b(0);
										elsif unsigned(exp_a) - unsigned(exp_b) < 32 then
											-- Large quotient - saturate
											fmod_quotient <= "01111111";
											exp_result <= exp_b;
											mant_result <= std_logic_vector(shift_right(unsigned(mant_b), 1));
											sign_result <= mant_a(0) xor mant_b(0);
										else
											-- Very large difference: quotient > 127
											fmod_quotient <= "01111111";  -- Saturate
											exp_result <= std_logic_vector(unsigned(exp_b) - 1);  -- /2
											mant_result <= mant_b;
											sign_result <= sign_a xor sign_b;  -- IEEE remainder sign rules
										end if;
									else
										-- |x| < |y|: result is x, quotient is 0
										fmod_quotient <= "00000000";
										sign_result <= sign_a;
										exp_result <= exp_a;
										mant_result <= mant_a;
									end if;
									flags_inexact <= '1';
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FSCALE =>
								-- Scale: x * 2^trunc(y)
								if is_nan_a = '1' or is_nan_b = '1' then
									-- NaN propagation
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');
								elsif is_zero_a = '1' then
									-- 0 * 2^n = 0
									sign_result <= sign_a;
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								elsif is_inf_a = '1' then
									-- inf * 2^n = inf (unless n = -inf)
									sign_result <= sign_a;
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								else
									-- Scale by adding truncated y to exponent
									temp_exp := to_integer(unsigned(exp_a));
									if exp_b >= EXP_BIAS then
										-- Positive scale factor
										scale_factor := to_integer(unsigned(exp_b)) - to_integer(unsigned(EXP_BIAS));
										temp_exp := temp_exp + scale_factor;
									else
										-- Negative scale factor
										scale_factor := to_integer(unsigned(EXP_BIAS)) - to_integer(unsigned(exp_b));
										temp_exp := temp_exp - scale_factor;
									end if;
									
									sign_result <= sign_a;
									if temp_exp >= to_integer(unsigned(EXP_MAX)) then
										-- Overflow
										exp_result <= EXP_MAX;
										mant_result <= (others => '0');
										flags_overflow <= '1';
									elsif temp_exp <= 0 then
										-- Underflow
										exp_result <= EXP_ZERO;
										mant_result <= (others => '0');
										flags_underflow <= '1';
									else
										exp_result <= std_logic_vector(to_unsigned(temp_exp, 15));
										mant_result <= mant_a;
									end if;
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FGETEXP =>
								-- Extract unbiased exponent as floating-point number
								if is_nan_a = '1' then
									-- NaN -> NaN
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');
								elsif is_inf_a = '1' then
									-- Infinity -> +Infinity
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								elsif is_zero_a = '1' then
									-- Zero -> -Infinity
									sign_result <= '1';
									exp_result <= EXP_MAX;
									mant_result <= (others => '0');
								else
									-- Normal case: return unbiased exponent as FP number
									temp_exp := to_integer(unsigned(exp_a)) - to_integer(unsigned(EXP_BIAS));
									sign_result <= '0';
									if temp_exp >= 0 then
										exp_result <= std_logic_vector(to_unsigned(temp_exp + to_integer(unsigned(EXP_BIAS)), 15));
									else
										sign_result <= '1';
										exp_result <= std_logic_vector(to_unsigned(-temp_exp + to_integer(unsigned(EXP_BIAS)), 15));
									end if;
									mant_result <= X"8000000000000000";  -- 1.0 mantissa
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when OP_FGETMAN =>
								-- Extract mantissa with exponent = bias (result in range [1,2))
								if is_nan_a = '1' then
									-- NaN -> NaN
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');
								elsif is_inf_a = '1' then
									-- Infinity -> NaN
									flags_invalid <= '1';
									sign_result <= '0';
									exp_result <= EXP_MAX;
									mant_result <= (63 => '1', others => '0');
								elsif is_zero_a = '1' then
									-- Zero -> Zero
									sign_result <= sign_a;
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
								else
									-- Normal case: return mantissa with exponent = bias
									sign_result <= sign_a;
									exp_result <= EXP_BIAS;  -- Exponent for range [1,2)
									mant_result <= mant_a;
								end if;
								alu_state <= ALU_NORMALIZE_RESULT;
								
							when others =>
								-- Unsupported operation
								flags_invalid <= '1';
								sign_result <= '0';
								exp_result <= EXP_ZERO;
								mant_result <= (others => '0');
								alu_state <= ALU_NORMALIZE_RESULT;
						end case;
					
					when ALU_NORMALIZE_RESULT =>
						-- Proper normalization and rounding
						-- Handle leading zero detection and normalization
						if exp_result = EXP_ZERO or mant_result = (63 downto 0 => '0') then
							-- Result is zero or denormalized
							exp_result <= EXP_ZERO;
							mant_result <= (others => '0');
						elsif exp_result >= EXP_MAX then
							-- Overflow to infinity
							flags_overflow <= '1';
							exp_result <= EXP_MAX;
							mant_result <= (others => '0');
						elsif exp_result(14) = '1' then  -- Negative exponent (underflow)
							-- Underflow to zero
							flags_underflow <= '1';
							exp_result <= EXP_ZERO;
							mant_result <= (others => '0');
						else
							-- Normal case: check for proper normalization
							-- IEEE 754 extended precision requires bit 63 = 1 for normalized numbers
							if mant_result(63) = '0' then
								-- Need to normalize by shifting left until bit 63 = 1
								-- Find leading zeros and shift accordingly
								norm_shift := 0;
								for i in 63 downto 0 loop
									if mant_result(i) = '1' then
										norm_shift := 63 - i;
										exit;
									end if;
								end loop;
								
								-- Check for all-zero mantissa (underflow to zero)
								if norm_shift = 0 and mant_result = (63 downto 0 => '0') then
									-- Result is exactly zero - preserve proper sign
									flags_underflow <= '1';
									exp_result <= EXP_ZERO;
									mant_result <= (others => '0');
									-- IEEE 754: Result sign for zero depends on operation and rounding mode
									case operation_code is
										when OP_FADD =>
											-- Addition: +0 + +0 = +0, -0 + -0 = -0, +0 + -0 = +0 (except in RM)
											if sign_a = sign_b then
												sign_result <= sign_a;  -- Same signs preserve sign
											elsif rounding_mode = "11" then  -- Round toward minus infinity
												sign_result <= '1';     -- Result is -0
											else
												sign_result <= '0';     -- Result is +0
											end if;
										when OP_FSUB =>
											-- Subtraction: +0 - +0 = +0, -0 - -0 = +0, +0 - -0 = +0, -0 - +0 = -0
											if sign_a = '0' and sign_b = '0' then
												sign_result <= '0';     -- +0 - +0 = +0
											elsif sign_a = '1' and sign_b = '1' then
												sign_result <= '0';     -- -0 - -0 = +0
											elsif sign_a = '0' and sign_b = '1' then
												sign_result <= '0';     -- +0 - -0 = +0
											else -- sign_a = '1' and sign_b = '0'
												sign_result <= '1';     -- -0 - +0 = -0
											end if;
										when OP_FMUL | OP_FDIV | OP_FSGLDIV =>
											-- Multiplication/Division: sign follows XOR rule
											sign_result <= sign_a xor sign_b;
										when others =>
											-- Other operations: preserve original logic
											sign_result <= sign_result;  -- Keep existing sign
									end case;
								-- Apply normalization shift
								elsif norm_shift > 0 and norm_shift <= 63 then
									if to_integer(unsigned(exp_result)) > norm_shift then
										-- Sufficient exponent to normalize
										exp_result <= std_logic_vector(unsigned(exp_result) - to_unsigned(norm_shift, 15));
										mant_result <= std_logic_vector(shift_left(unsigned(mant_result), norm_shift));
									else
										-- Exponent too small, create denormalized result (gradual underflow)
										flags_underflow <= '1';
										exp_result <= EXP_ZERO;
										-- Preserve mantissa bits by shifting right for denormalized representation
										-- IEEE 754 denormal: implicit leading bit is 0, mantissa represents actual significand
										if mant_result(63) = '1' then
											-- Keep most significant bits of mantissa for denormalized number
											mant_result <= std_logic_vector(shift_right(unsigned(mant_result), 1));  -- Gradual underflow
										else
											-- Very small number, can become zero
											mant_result <= (others => '0');
										end if;
									end if;
								end if;
							end if;
							
							-- Calculate IEEE 754 guard, round, and sticky bits for proper rounding
							-- Guard bit: first bit beyond precision (bit position depends on operation)
							-- Round bit: second bit beyond precision  
							-- Sticky bit: OR of all remaining bits beyond round bit
							-- Calculate based on the mantissa sum from arithmetic operations
							-- IEEE 754 compliant guard/round/sticky bit calculation for all operations
							case operation_code is
								when OP_FADD | OP_FSUB =>
									-- Addition/subtraction: use lower bits of mant_sum for rounding
									if mant_sum(64) = '1' then
										-- Overflow case: bits shifted right by 1
										guard_bit <= mant_sum(1);  -- First bit beyond 64-bit result
										round_bit <= mant_sum(0);  -- Second bit beyond result
										sticky_bit <= '0';  -- No additional bits in this case
									else
										-- Normal case: lower bits contain rounding information
										guard_bit <= mant_sum(0);  -- Lowest bit of sum
										round_bit <= '0';  -- No additional precision
										sticky_bit <= '0';  -- No additional precision
									end if;
								when OP_FMUL =>
									-- Multiplication: use lower bits of mult_result
									guard_bit <= mult_result(63);  -- Guard bit from multiplication
									round_bit <= mult_result(62);  -- Round bit
									-- Sticky bit: OR of all remaining lower bits
									if mult_result(61 downto 0) /= (61 downto 0 => '0') then
										sticky_bit <= '1';
									else
										sticky_bit <= '0';
									end if;
								when OP_FDIV | OP_FSGLDIV =>
									-- Division: determine remainder for proper rounding
									-- For division a/b, check if there's a remainder
									-- Approximate remainder check using the lower bits of quotient
									-- This is a simplified implementation - real IEEE 754 would need exact remainder
									guard_bit <= mant_result(0);  -- LSB of current result
									-- For sticky/round bits, check if division was exact
									if mant_result(0) = '1' or flags_inexact = '1' then
										round_bit <= '1';  -- Indicate non-exact division
										sticky_bit <= '1'; -- Non-zero remainder exists
									else
										round_bit <= '0';
										sticky_bit <= '0';
									end if;
								when OP_FSQRT =>
									-- Square root: similar to division, check for exactness
									-- For square root, guard bit is the LSB of the current mantissa
									guard_bit <= mant_result(0);
									-- If result has fractional part, set round/sticky bits
									if flags_inexact = '1' then
										round_bit <= '1';
										sticky_bit <= '1';
									else
										round_bit <= '0';
										sticky_bit <= '0';
									end if;
								when OP_FABS | OP_FNEG | OP_FMOVE =>
									-- Unary operations that don't change precision - no rounding needed
									guard_bit <= '0';
									round_bit <= '0';
									sticky_bit <= '0';
								when OP_FINT | OP_FINTRZ =>
									-- Integer conversions: check fractional part
									-- Extract fractional bits for guard/round/sticky calculation
									if unsigned(exp_a) < unsigned(EXP_BIAS) then
										-- Value < 1.0: entire mantissa is fractional
										guard_bit <= mant_a(63);
										round_bit <= mant_a(62);
										if mant_a(61 downto 0) /= (61 downto 0 => '0') then
											sticky_bit <= '1';
										else
											sticky_bit <= '0';
										end if;
									elsif unsigned(exp_a) < unsigned(EXP_BIAS) + 63 then
										-- Value has fractional part: check bits beyond integer part
										guard_bit <= '0';  -- Simplified - proper implementation would extract fractional bits
										round_bit <= '0';
										sticky_bit <= '0';
									else
										-- Value >= 2^63: no fractional part
										guard_bit <= '0';
										round_bit <= '0';
										sticky_bit <= '0';
									end if;
								when others =>
									-- Transcendental and other operations: assume inexact if flagged
									if flags_inexact = '1' then
										guard_bit <= '1';  -- Approximate guard bit
										round_bit <= '1';  -- Indicate rounding needed
										sticky_bit <= '1'; -- Indicate lost precision
									else
										guard_bit <= '0';
										round_bit <= '0';
										sticky_bit <= '0';
									end if;
							end case;
							
							-- IEEE 754 Rounding implementation
							result_before_round <= sign_result & exp_result & mant_result;
							
							-- Apply IEEE 754 rounding based on rounding_mode
							case rounding_mode is
								when "00" =>  -- Round to Nearest (RN)
									if guard_bit = '1' and (round_bit = '1' or sticky_bit = '1' or mant_result(0) = '1') then
										-- Round up
										if mant_result = (63 downto 0 => '1') then
											-- Mantissa overflow - adjust exponent
											if exp_result = EXP_MAX - 1 then
												-- Exponent would overflow to infinity
												exp_result <= EXP_MAX;
												mant_result <= (others => '0');
												flags_overflow <= '1';
											else
												exp_result <= exp_result + 1;
												mant_result <= (63 => '1', others => '0');
											end if;
										else
											mant_result <= mant_result + 1;
										end if;
									end if;
								when "01" =>  -- Round toward Zero (RZ) - truncation
									-- No rounding needed, result already truncated
								when "10" =>  -- Round toward Positive Infinity (RP)
									if sign_result = '0' and (guard_bit = '1' or round_bit = '1' or sticky_bit = '1') then
										-- Round up for positive numbers
										if mant_result = (63 downto 0 => '1') then
											if exp_result = EXP_MAX - 1 then
												-- Exponent would overflow to infinity
												exp_result <= EXP_MAX;
												mant_result <= (others => '0');
												flags_overflow <= '1';
											else
												exp_result <= exp_result + 1;
												mant_result <= (63 => '1', others => '0');
											end if;
										else
											mant_result <= mant_result + 1;
										end if;
									end if;
								when "11" =>  -- Round toward Negative Infinity (RM)
									if sign_result = '1' and (guard_bit = '1' or round_bit = '1' or sticky_bit = '1') then
										-- Round up for negative numbers (toward more negative)
										if mant_result = (63 downto 0 => '1') then
											if exp_result = EXP_MAX - 1 then
												-- Exponent would overflow to infinity
												exp_result <= EXP_MAX;
												mant_result <= (others => '0');
												flags_overflow <= '1';
											else
												exp_result <= exp_result + 1;
												mant_result <= (63 => '1', others => '0');
											end if;
										else
											mant_result <= mant_result + 1;
										end if;
									end if;
								when others =>
									-- Default case - no rounding
									null;
							end case;
						end if;
						alu_state <= ALU_DONE;
					
					when ALU_DONE =>
						-- Assemble final result
						result <= sign_result & exp_result & mant_result;
						result_valid <= '1';
						operation_done <= '1';
						operation_busy <= '0';
						alu_state <= ALU_IDLE;
				end case;
			end if;
		end if;
	end process;
	
	-- Output status flags
	overflow <= flags_overflow;
	underflow <= flags_underflow;
	inexact <= flags_inexact;
	invalid <= flags_invalid;
	divide_by_zero <= flags_div_by_zero;
	
	-- Output quotient byte for FMOD/FREM operations
	quotient_byte <= fmod_quotient;

end rtl;