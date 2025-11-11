------------------------------------------------------------------------------
-- TG68040 Floating Point Register File
--
-- 8 x 80-bit FP registers (FP0-FP7) with 2 read ports and 1 write port
--
-- Copyright (c) 2025 Claude AI (Anthropic)
-- Based on MC68040 User's Manual
--
-- LGPL v3
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_FPU_Pack.all;

entity TG68040_FPU_RegFile is
    port(
        -- Clock and reset
        clk         : in std_logic;
        reset       : in std_logic;

        -- Read port A
        read_addr_a : in std_logic_vector(2 downto 0);   -- FP register address (0-7)
        read_data_a : out std_logic_vector(79 downto 0); -- FP register data (80-bit extended)

        -- Read port B
        read_addr_b : in std_logic_vector(2 downto 0);   -- FP register address (0-7)
        read_data_b : out std_logic_vector(79 downto 0); -- FP register data (80-bit extended)

        -- Write port
        write_addr  : in std_logic_vector(2 downto 0);   -- FP register address (0-7)
        write_data  : in std_logic_vector(79 downto 0);  -- FP register data (80-bit extended)
        write_en    : in std_logic                       -- Write enable
    );
end TG68040_FPU_RegFile;

architecture rtl of TG68040_FPU_RegFile is

    -- Register file: 8 x 80-bit registers
    type reg_array_t is array(0 to 7) of std_logic_vector(79 downto 0);
    signal registers : reg_array_t := (others => (others => '0'));

begin

    ------------------------------------------------------------------------------
    -- Read ports (combinational)
    ------------------------------------------------------------------------------
    read_data_a <= registers(to_integer(unsigned(read_addr_a)));
    read_data_b <= registers(to_integer(unsigned(read_addr_b)));

    ------------------------------------------------------------------------------
    -- Write port (registered on rising edge)
    ------------------------------------------------------------------------------
    write_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Reset all registers to +0.0
                for i in 0 to 7 loop
                    registers(i) <= pack_fp_extended(FP_EXTENDED_ZERO);
                end loop;

            elsif write_en = '1' then
                -- Write to selected register
                registers(to_integer(unsigned(write_addr))) <= write_data;
            end if;
        end if;
    end process;

end rtl;
