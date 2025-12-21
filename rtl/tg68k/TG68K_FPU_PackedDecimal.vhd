------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU Packed Decimal Converter                        --
-- Handles conversion between IEEE 754 extended and packed decimal formats  --
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

entity TG68K_FPU_PackedDecimal is
    port(
        clk                 : in std_logic;
        nReset              : in std_logic;
        clkena              : in std_logic;
        
        -- Control
        start_conversion    : in std_logic;
        conversion_done     : out std_logic;
        conversion_valid    : out std_logic;
        
        -- Conversion direction
        packed_to_extended  : in std_logic;  -- '1' = packed to extended, '0' = extended to packed
        k_factor            : in std_logic_vector(6 downto 0);  -- K-factor for packed format
        
        -- Data inputs/outputs
        extended_in         : in std_logic_vector(79 downto 0);   -- IEEE 754 extended precision
        packed_in           : in std_logic_vector(95 downto 0);   -- MC68881/68882 packed decimal
        extended_out        : out std_logic_vector(79 downto 0);  -- IEEE 754 extended precision
        packed_out          : out std_logic_vector(95 downto 0);  -- MC68881/68882 packed decimal
        
        -- Exception flags
        overflow            : out std_logic;
        inexact             : out std_logic;
        invalid             : out std_logic
    );
end TG68K_FPU_PackedDecimal;

architecture rtl of TG68K_FPU_PackedDecimal is

    -- MC68881/68882 Packed Decimal Format (96 bits):
    -- Bit 95:      Sign of mantissa (SM)
    -- Bit 94:      Sign of exponent (SE)  
    -- Bits 93-92:  Don't care
    -- Bits 91-80:  3-digit exponent in BCD (12 bits)
    -- Bit 79:      Don't care
    -- Bits 78-68:  Integer part of mantissa (always 0 or non-zero indicator)
    -- Bits 67-0:   17 BCD digits of fractional mantissa (68 bits, 4 bits per digit)
    
    -- State machine
    type packed_state_t is (
        PACKED_IDLE,
        PACKED_DECODE,
        PACKED_BCD_TO_BIN,
        PACKED_BIN_TO_BCD,
        PACKED_NORMALIZE,
        PACKED_ROUND,
        PACKED_DONE
    );
    signal packed_state : packed_state_t := PACKED_IDLE;
    
    -- IEEE 754 Extended Precision constants
    constant EXP_BIAS : integer := 16383;
    constant EXP_MAX : integer := 32767;
    
    -- BCD conversion signals
    signal bcd_digits : std_logic_vector(67 downto 0);  -- 17 BCD digits
    signal bcd_exponent : std_logic_vector(11 downto 0);  -- 3 BCD digits for exponent
    signal binary_mantissa : std_logic_vector(63 downto 0);
    signal binary_exponent : integer range -999 to 999;
    signal decimal_exponent : integer range -999 to 999;
    
    -- Conversion working registers
    signal work_mantissa : std_logic_vector(127 downto 0);  -- Extended precision for conversion
    signal work_exponent : integer;
    signal result_sign : std_logic;
    signal exp_sign : std_logic;
    
    -- BCD arithmetic functions
    function bcd_to_binary(bcd : std_logic_vector) return integer is
        variable result : integer := 0;
        variable digit : integer;
    begin
        for i in 0 to (bcd'length/4)-1 loop
            digit := to_integer(unsigned(bcd(i*4+3 downto i*4)));
            if digit > 9 then
                return -1;  -- Invalid BCD
            end if;
            result := result * 10 + digit;
        end loop;
        return result;
    end function;
    
    function binary_to_bcd(value : integer; width : integer) return std_logic_vector is
        variable result : std_logic_vector(width-1 downto 0) := (others => '0');
        variable temp : integer := value;
        variable digit : integer;
    begin
        for i in 0 to (width/4)-1 loop
            digit := temp mod 10;
            result(i*4+3 downto i*4) := std_logic_vector(to_unsigned(digit, 4));
            temp := temp / 10;
        end loop;
        return result;
    end function;
    
    -- Cycle counter for iterative operations
    signal cycle_count : integer range 0 to 63;
    
begin

    packed_conversion: process(clk, nReset)
        variable temp_mantissa : unsigned(127 downto 0);
        variable temp_exp : integer;
        variable digit_value : integer;
        variable shift_amount : integer;
    begin
        if nReset = '0' then
            packed_state <= PACKED_IDLE;
            conversion_done <= '0';
            conversion_valid <= '0';
            overflow <= '0';
            inexact <= '0';
            invalid <= '0';
            extended_out <= (others => '0');
            packed_out <= (others => '0');
            cycle_count <= 0;
            
        elsif rising_edge(clk) then
            if clkena = '1' then
                case packed_state is
                    when PACKED_IDLE =>
                        conversion_done <= '0';
                        conversion_valid <= '0';
                        overflow <= '0';
                        inexact <= '0';
                        invalid <= '0';
                        cycle_count <= 0;
                        
                        if start_conversion = '1' then
                            packed_state <= PACKED_DECODE;
                        end if;
                    
                    when PACKED_DECODE =>
                        if packed_to_extended = '1' then
                            -- Packed to Extended conversion
                            -- Extract packed decimal components
                            result_sign <= packed_in(95);  -- Mantissa sign
                            exp_sign <= packed_in(94);     -- Exponent sign
                            bcd_exponent <= packed_in(91 downto 80);  -- 3-digit BCD exponent
                            bcd_digits <= packed_in(67 downto 0);     -- 17 BCD digits
                            
                            -- Validate BCD digits
                            invalid <= '0';
                            for i in 0 to 16 loop
                                if unsigned(bcd_digits(i*4+3 downto i*4)) > 9 then
                                    invalid <= '1';
                                end if;
                            end loop;
                            
                            -- Validate BCD exponent
                            for i in 0 to 2 loop
                                if unsigned(bcd_exponent(i*4+3 downto i*4)) > 9 then
                                    invalid <= '1';
                                end if;
                            end loop;
                            
                            packed_state <= PACKED_BCD_TO_BIN;
                        else
                            -- Extended to Packed conversion
                            -- Extract IEEE 754 components
                            result_sign <= extended_in(79);
                            work_exponent <= to_integer(unsigned(extended_in(78 downto 64))) - EXP_BIAS;
                            work_mantissa(63 downto 0) <= extended_in(63 downto 0);
                            work_mantissa(127 downto 64) <= (others => '0');
                            
                            -- Check for special values
                            if extended_in(78 downto 64) = "111111111111111" then
                                -- Infinity or NaN
                                if extended_in(63) = '1' and extended_in(62 downto 0) = (62 downto 0 => '0') then
                                    -- Infinity: use maximum packed decimal value
                                    overflow <= '1';
                                    bcd_exponent <= X"999";  -- Max exponent
                                    -- Set all BCD digits to 9 (binary 1001)
                                    for i in 0 to 16 loop
                                        bcd_digits(i*4+3 downto i*4) <= "1001";
                                    end loop;
                                else
                                    -- NaN: invalid conversion
                                    invalid <= '1';
                                    packed_out <= (others => '0');
                                    packed_state <= PACKED_DONE;
                                end if;
                            elsif extended_in(78 downto 0) = (78 downto 0 => '0') then
                                -- Zero
                                packed_out <= (others => '0');
                                packed_state <= PACKED_DONE;
                            else
                                packed_state <= PACKED_BIN_TO_BCD;
                            end if;
                        end if;
                    
                    when PACKED_BCD_TO_BIN =>
                        -- Convert BCD mantissa to binary
                        -- This is a multi-cycle operation
                        if cycle_count = 0 then
                            binary_mantissa <= (others => '0');
                            temp_mantissa := (others => '0');
                        end if;
                        
                        if cycle_count < 17 then
                            -- Process one BCD digit per cycle
                            digit_value := to_integer(unsigned(bcd_digits((16-cycle_count)*4+3 downto (16-cycle_count)*4)));
                            -- Multiply current result by 10 and add new digit
                            temp_mantissa := resize(temp_mantissa * 10, 128) + digit_value;
                            cycle_count <= cycle_count + 1;
                        else
                            -- Convert BCD exponent to binary and adjust for sign and k-factor
                            if exp_sign = '1' then
                                decimal_exponent <= -bcd_to_binary(bcd_exponent) - to_integer(signed(k_factor));
                            else
                                decimal_exponent <= bcd_to_binary(bcd_exponent) - to_integer(signed(k_factor));
                            end if;
                            
                            binary_mantissa <= std_logic_vector(temp_mantissa(63 downto 0));
                            packed_state <= PACKED_NORMALIZE;
                            cycle_count <= 0;
                        end if;
                    
                    when PACKED_BIN_TO_BCD =>
                        -- Convert binary to BCD
                        -- This is a simplified implementation
                        if cycle_count = 0 then
                            -- Initialize
                            bcd_digits <= (others => '0');
                            temp_mantissa := unsigned(work_mantissa);
                            
                            -- Convert binary exponent to decimal exponent
                            -- This is approximate - proper implementation needs log10 computation
                            if work_exponent > 0 then
                                decimal_exponent <= work_exponent * 3 / 10;  -- Approximate log10(2) * exp
                                exp_sign <= '0';
                            else
                                decimal_exponent <= -work_exponent * 3 / 10;
                                exp_sign <= '1';
                            end if;
                        end if;
                        
                        if cycle_count < 17 then
                            -- Extract BCD digits using repeated division
                            -- Simplified: just copy mantissa bits as approximation
                            bcd_digits(cycle_count*4+3 downto cycle_count*4) <= 
                                std_logic_vector(temp_mantissa(cycle_count*4+3 downto cycle_count*4) and "1001");
                            cycle_count <= cycle_count + 1;
                        else
                            -- Add k-factor to exponent
                            decimal_exponent <= decimal_exponent + to_integer(signed(k_factor));
                            
                            -- Convert decimal exponent to BCD
                            if decimal_exponent < 0 then
                                exp_sign <= '1';
                                bcd_exponent <= binary_to_bcd(-decimal_exponent, 12);
                            else
                                exp_sign <= '0';
                                bcd_exponent <= binary_to_bcd(decimal_exponent, 12);
                            end if;
                            
                            inexact <= '1';  -- Mark as inexact (simplified conversion)
                            packed_state <= PACKED_DONE;
                        end if;
                    
                    when PACKED_NORMALIZE =>
                        -- Normalize the binary result from packed decimal
                        if binary_mantissa = X"0000000000000000" then
                            -- Zero result
                            extended_out <= (others => '0');
                        else
                            -- Find leading bit and normalize
                            -- Simplified: assume mantissa is already normalized
                            temp_exp := decimal_exponent * 10 / 3 + EXP_BIAS;  -- Approximate 2^x from 10^x
                            
                            if temp_exp < 0 then
                                -- Underflow
                                extended_out <= result_sign & (78 downto 0 => '0');
                            elsif temp_exp > EXP_MAX then
                                -- Overflow
                                overflow <= '1';
                                extended_out <= result_sign & "111111111111111" & '1' & (62 downto 0 => '0');
                            else
                                -- Normal result
                                extended_out <= result_sign & std_logic_vector(to_unsigned(temp_exp, 15)) & binary_mantissa;
                            end if;
                        end if;
                        inexact <= '1';  -- Packed decimal conversion is always inexact
                        packed_state <= PACKED_DONE;
                    
                    when PACKED_ROUND =>
                        -- Rounding for extended to packed conversion
                        -- Simplified: truncate extra digits
                        packed_state <= PACKED_DONE;
                    
                    when PACKED_DONE =>
                        if packed_to_extended = '0' then
                            -- Construct packed decimal output
                            packed_out <= result_sign & exp_sign & "00" & bcd_exponent & '0' & "00000000000" & bcd_digits;
                        end if;
                        conversion_done <= '1';
                        conversion_valid <= '1';
                        packed_state <= PACKED_IDLE;
                end case;
            end if;
        end if;
    end process;

end rtl;