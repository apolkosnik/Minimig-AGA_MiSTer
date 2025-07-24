------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU Constant ROM                                    --
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

entity TG68K_FPU_ConstantROM is
	port(
		clk				: in std_logic;
		nReset			: in std_logic;
		
		-- ROM address (7-bit offset from FMOVECR instruction)
		rom_offset		: in std_logic_vector(6 downto 0);
		read_enable		: in std_logic;
		
		-- Output constant (IEEE 754 extended precision - 80 bits)
		constant_out	: out std_logic_vector(79 downto 0);
		constant_valid	: out std_logic
	);
end TG68K_FPU_ConstantROM;

architecture rtl of TG68K_FPU_ConstantROM is

	-- MC68881/68882 Constant ROM addresses
	constant ROM_PI			: std_logic_vector(6 downto 0) := "0000000";	-- π
	constant ROM_LOG10_2	: std_logic_vector(6 downto 0) := "0110000";	-- Log₁₀(2)
	constant ROM_E			: std_logic_vector(6 downto 0) := "0110001";	-- e
	constant ROM_LOG2_E		: std_logic_vector(6 downto 0) := "0110010";	-- Log₂(e)
	constant ROM_LOG10_E	: std_logic_vector(6 downto 0) := "0110011";	-- Log₁₀(e)
	constant ROM_ZERO		: std_logic_vector(6 downto 0) := "0001111";	-- 0.0
	constant ROM_LN_2		: std_logic_vector(6 downto 0) := "0110100";	-- ln(2)
	constant ROM_LN_10		: std_logic_vector(6 downto 0) := "0110101";	-- ln(10)
	constant ROM_1E0		: std_logic_vector(6 downto 0) := "0001000";	-- 10⁰
	constant ROM_1E1		: std_logic_vector(6 downto 0) := "0001001";	-- 10¹
	constant ROM_1E2		: std_logic_vector(6 downto 0) := "0001010";	-- 10²
	constant ROM_1E4		: std_logic_vector(6 downto 0) := "0001011";	-- 10⁴
	constant ROM_1E8		: std_logic_vector(6 downto 0) := "0110110";	-- 10⁸
	constant ROM_1E16		: std_logic_vector(6 downto 0) := "0110111";	-- 10¹⁶
	constant ROM_1E32		: std_logic_vector(6 downto 0) := "0111000";	-- 10³²
	constant ROM_1E64		: std_logic_vector(6 downto 0) := "0111001";	-- 10⁶⁴
	constant ROM_1E128		: std_logic_vector(6 downto 0) := "0111010";	-- 10¹²⁸
	constant ROM_1E256		: std_logic_vector(6 downto 0) := "0111011";	-- 10²⁵⁶
	constant ROM_1E512		: std_logic_vector(6 downto 0) := "0111100";	-- 10⁵¹²
	constant ROM_1E1024		: std_logic_vector(6 downto 0) := "0111101";	-- 10¹⁰²⁴
	constant ROM_1E2048		: std_logic_vector(6 downto 0) := "0111110";	-- 10²⁰⁴⁸
	constant ROM_1E4096		: std_logic_vector(6 downto 0) := "0111111";	-- 10⁴⁰⁹⁶

	-- IEEE 754 Extended Precision Constants (80-bit)
	-- Format: Sign(1) | Exponent(15) | Mantissa(64)
	constant CONST_PI		: std_logic_vector(79 downto 0) := x"4000C90FDAA22168C235";	-- π
	constant CONST_LOG10_2	: std_logic_vector(79 downto 0) := x"3FFD9A209A84FBCFF799";	-- Log₁₀(2)
	constant CONST_E		: std_logic_vector(79 downto 0) := x"4000ADF85458A2BB4A9B";	-- e
	constant CONST_LOG2_E	: std_logic_vector(79 downto 0) := x"3FFFB8AA3B295C17F0BC";	-- Log₂(e)
	constant CONST_LOG10_E	: std_logic_vector(79 downto 0) := x"3FFDDE5BD8A937287195";	-- Log₁₀(e)
	constant CONST_ZERO		: std_logic_vector(79 downto 0) := x"00000000000000000000";	-- 0.0
	constant CONST_LN_2		: std_logic_vector(79 downto 0) := x"3FFEB17217F7D1CF79AC";	-- ln(2)
	constant CONST_LN_10	: std_logic_vector(79 downto 0) := x"400093546D8F9BBD9ED8";	-- ln(10)
	constant CONST_ONE		: std_logic_vector(79 downto 0) := x"3FFF8000000000000000";	-- 1.0
	constant CONST_TEN		: std_logic_vector(79 downto 0) := x"4002A000000000000000";	-- 10.0
	constant CONST_1E2		: std_logic_vector(79 downto 0) := x"4005C800000000000000";	-- 100.0
	constant CONST_1E4		: std_logic_vector(79 downto 0) := x"400C9C40000000000000";	-- 10000.0
	constant CONST_1E8		: std_logic_vector(79 downto 0) := x"4019BEBC200000000000";	-- 1E8
	constant CONST_1E16		: std_logic_vector(79 downto 0) := x"40348E1BC9BF04000000";	-- 1E16
	constant CONST_1E32		: std_logic_vector(79 downto 0) := x"40693B8B5B5056E16B3C";	-- 1E32
	constant CONST_1E64		: std_logic_vector(79 downto 0) := x"40D384F03E93FF9F4DAA";	-- 1E64
	constant CONST_1E128	: std_logic_vector(79 downto 0) := x"41A893BA47C980E98CE0";	-- 1E128
	constant CONST_1E256	: std_logic_vector(79 downto 0) := x"4351AA7EEBFB9DF9DE8E";	-- 1E256

begin

	-- ROM lookup process
	rom_process: process(clk, nReset)
	begin
		if nReset = '0' then
			constant_out <= (others => '0');
			constant_valid <= '0';
		elsif rising_edge(clk) then
			constant_valid <= '0';
			
			if read_enable = '1' then
				case rom_offset is
					when ROM_PI =>
						constant_out <= CONST_PI;
						constant_valid <= '1';
					when ROM_LOG10_2 =>
						constant_out <= CONST_LOG10_2;
						constant_valid <= '1';
					when ROM_E =>
						constant_out <= CONST_E;
						constant_valid <= '1';
					when ROM_LOG2_E =>
						constant_out <= CONST_LOG2_E;
						constant_valid <= '1';
					when ROM_LOG10_E =>
						constant_out <= CONST_LOG10_E;
						constant_valid <= '1';
					when ROM_ZERO =>
						constant_out <= CONST_ZERO;
						constant_valid <= '1';
					when ROM_LN_2 =>
						constant_out <= CONST_LN_2;
						constant_valid <= '1';
					when ROM_LN_10 =>
						constant_out <= CONST_LN_10;
						constant_valid <= '1';
					when ROM_1E0 =>
						constant_out <= CONST_ONE;
						constant_valid <= '1';
					when ROM_1E1 =>
						constant_out <= CONST_TEN;
						constant_valid <= '1';
					when ROM_1E2 =>
						constant_out <= CONST_1E2;
						constant_valid <= '1';
					when ROM_1E4 =>
						constant_out <= CONST_1E4;
						constant_valid <= '1';
					when ROM_1E8 =>
						constant_out <= CONST_1E8;
						constant_valid <= '1';
					when ROM_1E16 =>
						constant_out <= CONST_1E16;
						constant_valid <= '1';
					when ROM_1E32 =>
						constant_out <= CONST_1E32;
						constant_valid <= '1';
					when ROM_1E64 =>
						constant_out <= CONST_1E64;
						constant_valid <= '1';
					when ROM_1E128 =>
						constant_out <= CONST_1E128;
						constant_valid <= '1';
					when ROM_1E256 =>
						constant_out <= CONST_1E256;
						constant_valid <= '1';
					when others =>
						-- Return zero for undefined constants
						constant_out <= CONST_ZERO;
						constant_valid <= '1';
				end case;
			end if;
		end if;
	end process;

end rtl;