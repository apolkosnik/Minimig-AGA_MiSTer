------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU MOVEM Implementation                            --
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

entity TG68K_FPU_MOVEM is
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;
		
		-- Control
		start_movem				: in std_logic;
		movem_done				: out std_logic;
		movem_busy				: out std_logic;
		
		-- Operation parameters
		direction				: in std_logic;					-- 0=to memory, 1=from memory
		register_mask			: in std_logic_vector(7 downto 0);	-- Which registers to transfer
		predecrement			: in std_logic;					-- Address mode -(An)
		postincrement			: in std_logic;					-- Address mode (An)+
		
		-- CPU-managed memory interface (CPU handles all memory operations)
		fmovem_data_request		: in std_logic;						-- CPU requests FMOVEM data at specific register
		fmovem_reg_index		: in integer range 0 to 7;			-- Index of FP register (0-7) 
		fmovem_data_write		: in std_logic;						-- CPU writing FMOVEM data to register
		fmovem_data_in			: in std_logic_vector(79 downto 0);	-- Data from CPU for FMOVEM load
		fmovem_data_out			: out std_logic_vector(79 downto 0);	-- Data to CPU for FMOVEM store
		
		-- FPU register file interface
		reg_address				: out std_logic_vector(2 downto 0);
		reg_data_in				: in std_logic_vector(79 downto 0);
		reg_data_out			: out std_logic_vector(79 downto 0);
		reg_write_enable		: out std_logic;
		
		-- Exception flags
		address_error			: out std_logic
	);
end TG68K_FPU_MOVEM;

architecture rtl of TG68K_FPU_MOVEM is

	-- Simplified MOVEM state (CPU manages memory operations)
	type movem_component_state_t is (
		MOVEM_IDLE,
		MOVEM_ACTIVE
	);
	signal movem_state : movem_component_state_t := MOVEM_IDLE;
	
	-- Internal signals (CPU manages addressing and memory operations)
	signal operation_active		: std_logic := '0';

begin

	-- Simplified MOVEM process (CPU manages memory operations)
	movem_process: process(clk, nReset)
	begin
		if nReset = '0' then
			movem_state <= MOVEM_IDLE;
			movem_done <= '0';
			movem_busy <= '0';
			reg_write_enable <= '0';
			address_error <= '0';
			operation_active <= '0';
			
		elsif rising_edge(clk) then
			if clkena = '1' then
				case movem_state is
					when MOVEM_IDLE =>
						movem_done <= '0';
						movem_busy <= '0';
						reg_write_enable <= '0';
						address_error <= '0';
						operation_active <= '0';
						
						if start_movem = '1' then
							-- Start MOVEM operation (CPU will manage actual transfers)
							movem_state <= MOVEM_ACTIVE;
							movem_busy <= '1';
							operation_active <= '1';
						end if;
					
					when MOVEM_ACTIVE =>
						-- Handle CPU data requests for FMOVEM operations
						if fmovem_data_request = '1' then
							-- CPU requesting data from specific FP register
							reg_address <= std_logic_vector(to_unsigned(fmovem_reg_index, 3));
							fmovem_data_out <= reg_data_in;  -- Provide register data to CPU
						end if;
						
						if fmovem_data_write = '1' then
							-- CPU writing data to specific FP register
							reg_address <= std_logic_vector(to_unsigned(fmovem_reg_index, 3));
							reg_data_out <= fmovem_data_in;  -- Store data from CPU to register
							reg_write_enable <= '1';
						else
							reg_write_enable <= '0';
						end if;
						
						-- CPU signals completion by stopping requests
						if start_movem = '0' then
							movem_done <= '1';
							movem_busy <= '0';
							operation_active <= '0';
							movem_state <= MOVEM_IDLE;
						end if;
				end case;
			end if;
		end if;
	end process;

end rtl;