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
		
		-- Memory interface
		memory_address			: inout std_logic_vector(31 downto 0);
		memory_data_in			: in std_logic_vector(79 downto 0);
		memory_data_out			: out std_logic_vector(79 downto 0);
		memory_read				: out std_logic;
		memory_write			: out std_logic;
		memory_ready			: in std_logic;
		
		-- FPU register file interface
		reg_address				: out std_logic_vector(2 downto 0);
		reg_data_in				: in std_logic_vector(79 downto 0);
		reg_data_out			: out std_logic_vector(79 downto 0);
		reg_write_enable		: out std_logic;
		
		-- Exception flags
		bus_error				: in std_logic;
		address_error			: out std_logic
	);
end TG68K_FPU_MOVEM;

architecture rtl of TG68K_FPU_MOVEM is

	-- MOVEM state machine
	type movem_state_t is (
		MOVEM_IDLE,
		MOVEM_INIT,
		MOVEM_CHECK_MASK,
		MOVEM_SETUP_TRANSFER,
		MOVEM_WAIT_MEMORY,
		MOVEM_COMPLETE_TRANSFER,
		MOVEM_UPDATE_ADDRESS,
		MOVEM_NEXT_REGISTER,
		MOVEM_DONE_STATE,
		MOVEM_ERROR
	);
	signal movem_state : movem_state_t := MOVEM_IDLE;
	
	-- Internal signals
	signal current_register		: integer range 0 to 7;
	signal register_mask_work	: std_logic_vector(7 downto 0);
	signal transfer_count		: integer range 0 to 8;
	signal current_address		: std_logic_vector(31 downto 0);
	signal transfer_direction	: std_logic;
	signal addr_mode_predec		: std_logic;
	signal addr_mode_postinc	: std_logic;
	
	-- Transfer control
	signal transfer_active		: std_logic;
	signal transfer_complete	: std_logic;
	signal memory_cycle_active	: std_logic;
	
	-- Error detection
	signal alignment_error		: std_logic;
	signal bus_error_detected	: std_logic;
	
	-- Constants
	constant FP_REG_SIZE		: integer := 10;  -- 80 bits = 10 bytes per FP register

begin

	-- Main MOVEM state machine
	movem_process: process(clk, nReset)
		variable reg_found : boolean;
	begin
		if nReset = '0' then
			movem_state <= MOVEM_IDLE;
			movem_done <= '0';
			movem_busy <= '0';
			memory_read <= '0';
			memory_write <= '0';
			reg_write_enable <= '0';
			address_error <= '0';
			transfer_active <= '0';
			current_register <= 0;
			transfer_count <= 0;
			
		elsif rising_edge(clk) then
			if clkena = '1' then
				case movem_state is
					when MOVEM_IDLE =>
						movem_done <= '0';
						movem_busy <= '0';
						memory_read <= '0';
						memory_write <= '0';
						reg_write_enable <= '0';
						address_error <= '0';
						transfer_active <= '0';
						
						if start_movem = '1' then
							-- Initialize MOVEM operation
							movem_state <= MOVEM_INIT;
							movem_busy <= '1';
						end if;
					
					when MOVEM_INIT =>
						-- Initialize operation parameters
						register_mask_work <= register_mask;
						current_address <= memory_address;
						transfer_direction <= direction;
						addr_mode_predec <= predecrement;
						addr_mode_postinc <= postincrement;
						transfer_count <= 0;
						
						-- Check address alignment (must be even for 80-bit transfers)
						if current_address(0) = '1' then
							address_error <= '1';
							movem_state <= MOVEM_ERROR;
						else
							-- Start with register 0 for postincrement, register 7 for predecrement
							if predecrement = '1' then
								current_register <= 7;
							else
								current_register <= 0;
							end if;
							movem_state <= MOVEM_CHECK_MASK;
						end if;
					
					when MOVEM_CHECK_MASK =>
						-- Check if any registers remain to transfer
						reg_found := false;
						
						if addr_mode_predec = '1' then
							-- Predecrement: scan from current_register down to 0
							for i in current_register downto 0 loop
								if register_mask_work(i) = '1' then
									current_register <= i;
									reg_found := true;
									exit;
								end if;
							end loop;
						else
							-- Postincrement: scan from current_register up to 7
							for i in current_register to 7 loop
								if register_mask_work(i) = '1' then
									current_register <= i;
									reg_found := true;
									exit;
								end if;
							end loop;
						end if;
						
						if reg_found then
							movem_state <= MOVEM_SETUP_TRANSFER;
						else
							-- No more registers to transfer
							movem_state <= MOVEM_DONE_STATE;
						end if;
					
					when MOVEM_SETUP_TRANSFER =>
						-- Setup the memory transfer for current register
						reg_address <= std_logic_vector(to_unsigned(current_register, 3));
						
						if transfer_direction = '0' then
							-- To memory: read from FP register, write to memory
							memory_data_out <= reg_data_in;
							memory_write <= '1';
							memory_read <= '0';
						else
							-- From memory: read from memory, write to FP register
							memory_write <= '0';
							memory_read <= '1';
						end if;
						
						transfer_active <= '1';
						movem_state <= MOVEM_WAIT_MEMORY;
					
					when MOVEM_WAIT_MEMORY =>
						-- Wait for memory operation to complete
						if memory_ready = '1' then
							movem_state <= MOVEM_COMPLETE_TRANSFER;
						elsif bus_error = '1' then
							bus_error_detected <= '1';
							movem_state <= MOVEM_ERROR;
						end if;
						-- Stay in this state until memory responds
					
					when MOVEM_COMPLETE_TRANSFER =>
						-- Complete the transfer
						memory_read <= '0';
						memory_write <= '0';
						transfer_active <= '0';
						
						if transfer_direction = '1' then
							-- From memory: write data to FP register
							reg_data_out <= memory_data_in;
							reg_write_enable <= '1';
						else
							-- To memory: data already written, just clear write enable
							reg_write_enable <= '0';
						end if;
						
						-- Clear the register from mask
						register_mask_work(current_register) <= '0';
						transfer_count <= transfer_count + 1;
						
						movem_state <= MOVEM_UPDATE_ADDRESS;
					
					when MOVEM_UPDATE_ADDRESS =>
						-- Update address for next transfer
						reg_write_enable <= '0';
						
						if addr_mode_predec = '1' then
							-- Predecrement: subtract register size
							current_address <= current_address - FP_REG_SIZE;
						elsif addr_mode_postinc = '1' then
							-- Postincrement: add register size
							current_address <= current_address + FP_REG_SIZE;
						end if;
						
						movem_state <= MOVEM_NEXT_REGISTER;
					
					when MOVEM_NEXT_REGISTER =>
						-- Move to next register
						if addr_mode_predec = '1' then
							if current_register > 0 then
								current_register <= current_register - 1;
							end if;
						else
							if current_register < 7 then
								current_register <= current_register + 1;
							end if;
						end if;
						
						movem_state <= MOVEM_CHECK_MASK;
					
					when MOVEM_DONE_STATE =>
						-- MOVEM operation completed successfully
						memory_address <= current_address;  -- Update final address
						movem_done <= '1';
						movem_busy <= '0';
						movem_state <= MOVEM_IDLE;
					
					when MOVEM_ERROR =>
						-- Error occurred during MOVEM
						memory_read <= '0';
						memory_write <= '0';
						reg_write_enable <= '0';
						transfer_active <= '0';
						movem_done <= '1';  -- Signal completion (with error)
						movem_busy <= '0';
						movem_state <= MOVEM_IDLE;
				end case;
			end if;
		end if;
	end process;

end rtl;