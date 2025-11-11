------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Return Address Stack (Phase 8)                                  --
--                                                                          --
-- Predicts return addresses for subroutine returns                        --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- RAS (Return Address Stack):
-- - 8-entry stack
-- - Push on JSR (jump to subroutine)
-- - Pop on RTS (return from subroutine)
-- - Handles overflow (discard oldest) and underflow (invalid prediction)
--
-- Version: 1.0 (Phase 8)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68040_RAS is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Push (JSR in EX stage)
        push_en        : in std_logic;
        push_addr      : in std_logic_vector(31 downto 0);

        -- Pop (RTS prediction in IF stage)
        pop_en         : in std_logic;
        pop_addr       : out std_logic_vector(31 downto 0);
        pop_valid      : out std_logic;

        -- Repair (on misprediction - restore TOS)
        repair_en      : in std_logic;
        repair_tos     : in integer range 0 to 7;

        -- Statistics
        pushes         : out std_logic_vector(31 downto 0);
        pops           : out std_logic_vector(31 downto 0);
        overflows      : out std_logic_vector(31 downto 0);
        underflows     : out std_logic_vector(31 downto 0)
    );
end TG68040_RAS;

architecture rtl of TG68040_RAS is

    ------------------------------------------------------------------------------
    -- RAS Array (8 entries)
    ------------------------------------------------------------------------------
    type ras_array_t is array (0 to 7) of std_logic_vector(31 downto 0);
    signal ras_array : ras_array_t := (others => (others => '0'));

    ------------------------------------------------------------------------------
    -- Stack Pointer (Top of Stack)
    ------------------------------------------------------------------------------
    signal tos : integer range 0 to 7 := 0;
    signal valid_count : integer range 0 to 8 := 0;

    ------------------------------------------------------------------------------
    -- Statistics
    ------------------------------------------------------------------------------
    signal stat_pushes : unsigned(31 downto 0) := (others => '0');
    signal stat_pops : unsigned(31 downto 0) := (others => '0');
    signal stat_overflows : unsigned(31 downto 0) := (others => '0');
    signal stat_underflows : unsigned(31 downto 0) := (others => '0');

begin

    -- Output statistics
    pushes <= std_logic_vector(stat_pushes);
    pops <= std_logic_vector(stat_pops);
    overflows <= std_logic_vector(stat_overflows);
    underflows <= std_logic_vector(stat_underflows);

    ------------------------------------------------------------------------------
    -- RAS Operations
    ------------------------------------------------------------------------------
    ras_proc: process(clk)
        variable next_tos : integer range 0 to 7;
        variable prev_tos : integer range 0 to 7;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Reset stack
                tos <= 0;
                valid_count <= 0;
                pop_valid <= '0';
                stat_pushes <= (others => '0');
                stat_pops <= (others => '0');
                stat_overflows <= (others => '0');
                stat_underflows <= (others => '0');

            elsif repair_en = '1' then
                -- Repair stack after misprediction
                tos <= repair_tos;
                pop_valid <= '0';

            else
                -- Default
                pop_valid <= '0';

                -- Calculate helper values
                next_tos := (tos + 1) mod 8;
                if tos = 0 then
                    prev_tos := 7;
                else
                    prev_tos := tos - 1;
                end if;

                -- Handle push and pop
                if push_en = '1' and pop_en = '1' then
                    -- Push and pop simultaneously (tail call)
                    -- Replace TOS with new address
                    if valid_count > 0 then
                        ras_array(prev_tos) <= push_addr;
                        pop_addr <= ras_array(prev_tos);
                        pop_valid <= '1';
                    else
                        -- Stack was empty, just push
                        ras_array(tos) <= push_addr;
                        tos <= next_tos;
                        valid_count <= 1;
                        pop_addr <= (others => '0');
                        pop_valid <= '0';
                        stat_underflows <= stat_underflows + 1;
                    end if;
                    stat_pushes <= stat_pushes + 1;
                    stat_pops <= stat_pops + 1;

                elsif push_en = '1' then
                    -- Push return address
                    ras_array(tos) <= push_addr;
                    tos <= next_tos;

                    if valid_count < 8 then
                        -- Normal push
                        valid_count <= valid_count + 1;
                    else
                        -- Overflow: we're overwriting oldest entry
                        stat_overflows <= stat_overflows + 1;
                    end if;

                    stat_pushes <= stat_pushes + 1;

                elsif pop_en = '1' then
                    -- Pop return address
                    if valid_count > 0 then
                        -- Normal pop
                        pop_addr <= ras_array(prev_tos);
                        pop_valid <= '1';
                        tos <= prev_tos;
                        valid_count <= valid_count - 1;
                    else
                        -- Underflow: stack is empty
                        pop_addr <= (others => '0');
                        pop_valid <= '0';
                        stat_underflows <= stat_underflows + 1;
                    end if;

                    stat_pops <= stat_pops + 1;
                end if;
            end if;
        end if;
    end process;

end rtl;
