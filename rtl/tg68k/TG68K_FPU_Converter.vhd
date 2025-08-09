------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU Data Format Converter                           --
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

entity TG68K_FPU_Converter is
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;
		
		-- Control
		start_conversion		: in std_logic;
		conversion_done			: out std_logic;
		conversion_valid		: out std_logic;
		
		-- Format specification
		source_format			: in std_logic_vector(2 downto 0);
		dest_format				: in std_logic_vector(2 downto 0);
		
		-- Input data (variable width based on format)
		data_in					: in std_logic_vector(95 downto 0);  -- Max size for packed decimal
		
		-- Output data (always extended precision for internal use)
		data_out				: out std_logic_vector(79 downto 0); -- IEEE extended precision
		
		-- Exception flags
		overflow				: out std_logic;
		underflow				: out std_logic;
		inexact					: out std_logic;
		invalid					: out std_logic
	);
end TG68K_FPU_Converter;

architecture rtl of TG68K_FPU_Converter is

	-- Data format constants
	constant FORMAT_LONG		: std_logic_vector(2 downto 0) := "000";	-- 32-bit integer
	constant FORMAT_SINGLE		: std_logic_vector(2 downto 0) := "001";	-- 32-bit IEEE single
	constant FORMAT_EXTENDED	: std_logic_vector(2 downto 0) := "010";	-- 80-bit IEEE extended
	constant FORMAT_PACKED		: std_logic_vector(2 downto 0) := "011";	-- 96-bit packed decimal
	constant FORMAT_WORD		: std_logic_vector(2 downto 0) := "100";	-- 16-bit integer  
	constant FORMAT_DOUBLE		: std_logic_vector(2 downto 0) := "101";	-- 64-bit IEEE double
	constant FORMAT_BYTE		: std_logic_vector(2 downto 0) := "110";	-- 8-bit integer
	
	-- IEEE format constants
	constant SINGLE_EXP_BIAS	: integer := 127;
	constant DOUBLE_EXP_BIAS	: integer := 1023;
	constant EXTENDED_EXP_BIAS	: integer := 16383;
	
	-- Conversion state machine
	type conv_state_t is (
		CONV_IDLE,
		CONV_EXTRACT,
		CONV_CONVERT,
		CONV_NORMALIZE,
		CONV_PACKED_OUT,
		CONV_DONE
	);
	signal conv_state : conv_state_t := CONV_IDLE;
	
	-- Internal conversion signals
	signal source_sign			: std_logic;
	signal source_exp			: std_logic_vector(14 downto 0);
	signal source_mant			: std_logic_vector(63 downto 0);
	signal dest_sign			: std_logic;
	signal dest_exp				: std_logic_vector(14 downto 0);
	signal dest_mant			: std_logic_vector(63 downto 0);
	signal dest_extended		: std_logic_vector(79 downto 0);
	
	-- Integer conversion signals
	signal int_value			: signed(31 downto 0);
	signal int_negative			: std_logic;
	signal int_magnitude		: std_logic_vector(31 downto 0);
	signal leading_zeros		: integer range 0 to 31;
	
	-- Single precision extraction
	signal single_sign			: std_logic;
	signal single_exp			: std_logic_vector(7 downto 0);
	signal single_mant			: std_logic_vector(22 downto 0);
	
	-- Double precision extraction  
	signal double_sign			: std_logic;
	signal double_exp			: std_logic_vector(10 downto 0);
	signal double_mant			: std_logic_vector(51 downto 0);
	
	-- Status flags
	signal conv_overflow		: std_logic;
	signal conv_underflow		: std_logic;
	signal conv_inexact			: std_logic;
	signal conv_invalid			: std_logic;
	
	-- Packed decimal converter signals
	signal packed_start			: std_logic;
	signal packed_done			: std_logic;
	signal packed_valid			: std_logic;
	signal packed_to_ext		: std_logic;
	signal packed_k_factor		: std_logic_vector(6 downto 0);
	signal packed_ext_out		: std_logic_vector(79 downto 0);
	signal packed_dec_out		: std_logic_vector(95 downto 0);
	signal packed_overflow		: std_logic;
	signal packed_inexact		: std_logic;
	signal packed_invalid		: std_logic;

begin

	-- Instantiate packed decimal converter
	PACKED_CONVERTER: entity work.TG68K_FPU_PackedDecimal
	port map(
		clk => clk,
		nReset => nReset,
		clkena => clkena,
		
		-- Control
		start_conversion => packed_start,
		conversion_done => packed_done,
		conversion_valid => packed_valid,
		
		-- Direction and K-factor
		packed_to_extended => packed_to_ext,
		k_factor => packed_k_factor,
		
		-- Data
		extended_in => dest_extended,
		packed_in => data_in,
		extended_out => packed_ext_out,
		packed_out => packed_dec_out,
		
		-- Exceptions
		overflow => packed_overflow,
		inexact => packed_inexact,
		invalid => packed_invalid
	);

	-- Assign concatenated signal
	dest_extended <= dest_sign & dest_exp & dest_mant;

	-- Main conversion process
	conversion_process: process(clk, nReset)
		variable temp_exp : integer;
		variable norm_shift : integer;
	begin
		if nReset = '0' then
			conv_state <= CONV_IDLE;
			conversion_done <= '0';
			conversion_valid <= '0';
			data_out <= (others => '0');
			conv_overflow <= '0';
			conv_underflow <= '0';
			conv_inexact <= '0';
			conv_invalid <= '0';
			
		elsif rising_edge(clk) then
			if clkena = '1' then
				case conv_state is
					when CONV_IDLE =>
						conversion_done <= '0';
						conversion_valid <= '0';
						conv_overflow <= '0';
						conv_underflow <= '0';
						conv_inexact <= '0';
						conv_invalid <= '0';
						
						if start_conversion = '1' then
							conv_state <= CONV_EXTRACT;
						end if;
					
					when CONV_EXTRACT =>
						-- Extract fields based on source format
						case source_format is
							when FORMAT_BYTE =>
								-- 8-bit signed integer
								int_value <= resize(signed(data_in(7 downto 0)), 32);
								conv_state <= CONV_CONVERT;
								
							when FORMAT_WORD =>
								-- 16-bit signed integer
								int_value <= resize(signed(data_in(15 downto 0)), 32);
								conv_state <= CONV_CONVERT;
								
							when FORMAT_LONG =>
								-- 32-bit signed integer
								int_value <= signed(data_in(31 downto 0));
								conv_state <= CONV_CONVERT;
								
							when FORMAT_SINGLE =>
								-- IEEE 754 single precision
								single_sign <= data_in(31);
								single_exp <= data_in(30 downto 23);
								single_mant <= data_in(22 downto 0);
								conv_state <= CONV_CONVERT;
								
							when FORMAT_DOUBLE =>
								-- IEEE 754 double precision
								double_sign <= data_in(63);
								double_exp <= data_in(62 downto 52);
								double_mant <= data_in(51 downto 0);
								conv_state <= CONV_CONVERT;
								
							when FORMAT_EXTENDED =>
								-- Already in extended precision
								dest_sign <= data_in(79);
								dest_exp <= data_in(78 downto 64);
								dest_mant <= data_in(63 downto 0);
								conv_state <= CONV_DONE;
								
							when FORMAT_PACKED =>
								-- Use dedicated packed decimal converter
								packed_to_ext <= '1';  -- Packed to extended conversion
								packed_k_factor <= "0000000";  -- Default K-factor (could be parameterized)
								packed_start <= '1';
								conv_state <= CONV_CONVERT;
								
							when others =>
								conv_invalid <= '1';
								conv_state <= CONV_DONE;
						end case;
					
					when CONV_CONVERT =>
						case source_format is
							when FORMAT_BYTE | FORMAT_WORD | FORMAT_LONG =>
								-- Integer to extended conversion
								if int_value = 0 then
									-- Zero
									dest_sign <= '0';
									dest_exp <= (others => '0');
									dest_mant <= (others => '0');
								else
									-- Determine sign and magnitude
									if int_value < 0 then
										dest_sign <= '1';
										int_magnitude <= std_logic_vector(-int_value);
									else
										dest_sign <= '0';
										int_magnitude <= std_logic_vector(int_value);
									end if;
									
									-- Find leading zeros for normalization
									leading_zeros <= 0;
									for i in 31 downto 0 loop
										if int_magnitude(i) = '1' then
											leading_zeros <= 31 - i;
											exit;
										end if;
									end loop;
									
									conv_state <= CONV_NORMALIZE;
								end if;
								
							when FORMAT_SINGLE =>
								-- Single to extended conversion
								dest_sign <= single_sign;
								
								if single_exp = X"00" then
									-- Zero or denormalized
									dest_exp <= (others => '0');
									dest_mant <= (others => '0');
								elsif single_exp = X"FF" then
									-- Infinity or NaN
									dest_exp <= (others => '1');
									if single_mant = (22 downto 0 => '0') then
										-- Infinity
										dest_mant <= (63 => '1', others => '0');  -- Explicit integer bit for infinity
									else
										-- NaN - preserve mantissa bits and set explicit integer bit
										dest_mant <= '1' & single_mant & (39 downto 0 => '0');
									end if;
								else
									-- Normal number
									temp_exp := to_integer(unsigned(single_exp)) - SINGLE_EXP_BIAS + EXTENDED_EXP_BIAS;
									dest_exp <= std_logic_vector(to_unsigned(temp_exp, 15));
									-- Add explicit leading 1 and extend mantissa (single has 23-bit mantissa)
									dest_mant <= '1' & single_mant & (39 downto 0 => '0');
								end if;
								conv_state <= CONV_DONE;
								
							when FORMAT_DOUBLE =>
								-- Double to extended conversion
								dest_sign <= double_sign;
								
								if double_exp = "00000000000" then
									-- Zero or denormalized
									dest_exp <= (others => '0');
									dest_mant <= (others => '0');
								elsif double_exp = "11111111111" then
									-- Infinity or NaN
									dest_exp <= (others => '1');
									if double_mant = (51 downto 0 => '0') then
										-- Infinity
										dest_mant <= (63 => '1', others => '0');  -- Explicit integer bit for infinity
									else
										-- NaN - preserve mantissa bits and set explicit integer bit
										dest_mant <= '1' & double_mant & (10 downto 0 => '0');
									end if;
								else
									-- Normal number
									temp_exp := to_integer(unsigned(double_exp)) - DOUBLE_EXP_BIAS + EXTENDED_EXP_BIAS;
									dest_exp <= std_logic_vector(to_unsigned(temp_exp, 15));
									-- Add explicit leading 1 and extend mantissa (double has 52-bit mantissa)
									dest_mant <= '1' & double_mant & (10 downto 0 => '0');
								end if;
								conv_state <= CONV_DONE;
								
							when FORMAT_PACKED =>
								-- Wait for packed decimal converter
								packed_start <= '0';  -- Clear start signal
								if packed_done = '1' then
									-- Get result from packed decimal converter
									dest_sign <= packed_ext_out(79);
									dest_exp <= packed_ext_out(78 downto 64);
									dest_mant <= packed_ext_out(63 downto 0);
									conv_overflow <= packed_overflow;
									conv_inexact <= packed_inexact;
									conv_invalid <= packed_invalid;
									conv_state <= CONV_DONE;
								end if;
								
							when others =>
								conv_invalid <= '1';
								conv_state <= CONV_DONE;
						end case;
					
					when CONV_NORMALIZE =>
						-- Normalize integer conversion
						if int_magnitude = X"00000000" then
							dest_exp <= (others => '0');
							dest_mant <= (others => '0');
						else
							-- Calculate exponent: bias + (31 - leading_zeros)
							temp_exp := EXTENDED_EXP_BIAS + (31 - leading_zeros);
							dest_exp <= std_logic_vector(to_unsigned(temp_exp, 15));
							
							-- Normalize mantissa by shifting left to remove leading zeros
							-- IEEE 754 extended precision has explicit integer bit
							if leading_zeros = 0 then
								-- Already normalized (MSB is 1)
								dest_mant <= int_magnitude & X"00000000";  -- 32-bit int + 32-bit padding
							elsif leading_zeros <= 31 then
								-- Shift left to normalize
								dest_mant <= std_logic_vector(shift_left(unsigned(int_magnitude & X"00000000"), leading_zeros));
							else
								-- Should not happen for valid 32-bit integers
								dest_mant <= (others => '0');
							end if;
						end if;
						conv_state <= CONV_DONE;
					
					when CONV_DONE =>
						-- Output result in requested destination format
						case dest_format is
							when FORMAT_EXTENDED =>
								-- Already in extended format
								data_out <= dest_sign & dest_exp & dest_mant;
								conversion_done <= '1';
								conversion_valid <= '1';
								conv_state <= CONV_IDLE;
							when FORMAT_PACKED =>
								-- Start conversion to packed decimal
								packed_to_ext <= '0';  -- Extended to packed conversion
								packed_k_factor <= "0000000";  -- Default K-factor
								packed_start <= '1';
								conv_state <= CONV_PACKED_OUT;
							when others =>
								-- Default: output as extended precision
								data_out <= dest_sign & dest_exp & dest_mant;
								conversion_done <= '1';
								conversion_valid <= '1';
								conv_state <= CONV_IDLE;
						end case;
					
					when CONV_PACKED_OUT =>
						-- Wait for packed decimal converter
						packed_start <= '0';  -- Clear start signal
						if packed_done = '1' then
							-- Output packed decimal result (truncate to 80 bits for data_out)
							data_out <= packed_dec_out(79 downto 0);
							conv_overflow <= conv_overflow or packed_overflow;
							conv_inexact <= conv_inexact or packed_inexact;
							conv_invalid <= conv_invalid or packed_invalid;
							conversion_done <= '1';
							conversion_valid <= '1';
							conv_state <= CONV_IDLE;
						end if;
				end case;
			end if;
		end if;
	end process;
	
	-- Output status flags
	overflow <= conv_overflow;
	underflow <= conv_underflow;
	inexact <= conv_inexact;
	invalid <= conv_invalid;

end rtl;