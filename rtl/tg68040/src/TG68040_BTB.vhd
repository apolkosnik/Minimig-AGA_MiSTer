------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Branch Target Buffer (Phase 8)                                  --
--                                                                          --
-- Caches branch targets for fast branch prediction                        --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- BTB (Branch Target Buffer):
-- - 64 entries (direct-mapped)
-- - Indexed by PC[7:2]
-- - Tagged by PC[31:8]
-- - Stores: target address, taken/not-taken, branch type
--
-- Version: 1.0 (Phase 8)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Branch_Pack.all;

entity TG68040_BTB is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Lookup (IF stage - combinational)
        lookup_pc      : in std_logic_vector(31 downto 0);
        lookup_hit     : out std_logic;
        lookup_target  : out std_logic_vector(31 downto 0);
        lookup_taken   : out std_logic;
        lookup_type    : out branch_type_t;

        -- Update (EX stage - registered)
        update_en      : in std_logic;
        update_pc      : in std_logic_vector(31 downto 0);
        update_target  : in std_logic_vector(31 downto 0);
        update_taken   : in std_logic;
        update_type    : in branch_type_t;

        -- Statistics
        lookups        : out std_logic_vector(31 downto 0);
        hits           : out std_logic_vector(31 downto 0);
        misses         : out std_logic_vector(31 downto 0)
    );
end TG68040_BTB;

architecture rtl of TG68040_BTB is

    ------------------------------------------------------------------------------
    -- BTB Entry Structure
    ------------------------------------------------------------------------------
    type btb_entry_t is record
        valid  : std_logic;
        tag    : std_logic_vector(23 downto 0);  -- PC[31:8]
        target : std_logic_vector(31 downto 0);
        taken  : std_logic;
        btype  : branch_type_t;
    end record;

    constant BTB_ENTRY_INIT : btb_entry_t := (
        valid  => '0',
        tag    => (others => '0'),
        target => (others => '0'),
        taken  => '0',
        btype  => BRANCH_NONE
    );

    ------------------------------------------------------------------------------
    -- BTB Array (64 entries)
    ------------------------------------------------------------------------------
    type btb_array_t is array (0 to 63) of btb_entry_t;
    signal btb_array : btb_array_t := (others => BTB_ENTRY_INIT);

    ------------------------------------------------------------------------------
    -- Statistics
    ------------------------------------------------------------------------------
    signal stat_lookups : unsigned(31 downto 0) := (others => '0');
    signal stat_hits    : unsigned(31 downto 0) := (others => '0');
    signal stat_misses  : unsigned(31 downto 0) := (others => '0');

begin

    -- Output statistics
    lookups <= std_logic_vector(stat_lookups);
    hits <= std_logic_vector(stat_hits);
    misses <= std_logic_vector(stat_misses);

    ------------------------------------------------------------------------------
    -- BTB Lookup (Combinational - for IF stage)
    ------------------------------------------------------------------------------
    btb_lookup: process(lookup_pc, btb_array)
        variable index : integer range 0 to 63;
        variable tag : std_logic_vector(23 downto 0);
    begin
        -- Extract index and tag
        index := to_integer(unsigned(lookup_pc(7 downto 2)));
        tag := lookup_pc(31 downto 8);

        -- Check for hit
        if btb_array(index).valid = '1' and btb_array(index).tag = tag then
            lookup_hit <= '1';
            lookup_target <= btb_array(index).target;
            lookup_taken <= btb_array(index).taken;
            lookup_type <= btb_array(index).btype;
        else
            lookup_hit <= '0';
            lookup_target <= (others => '0');
            lookup_taken <= '0';
            lookup_type <= BRANCH_NONE;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- BTB Update (Registered - from EX stage)
    ------------------------------------------------------------------------------
    btb_update: process(clk)
        variable index : integer range 0 to 63;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Reset BTB
                btb_array <= (others => BTB_ENTRY_INIT);
                stat_lookups <= (others => '0');
                stat_hits <= (others => '0');
                stat_misses <= (others => '0');

            else
                -- Update entry
                if update_en = '1' then
                    index := to_integer(unsigned(update_pc(7 downto 2)));

                    btb_array(index).valid <= '1';
                    btb_array(index).tag <= update_pc(31 downto 8);
                    btb_array(index).target <= update_target;
                    btb_array(index).taken <= update_taken;
                    btb_array(index).btype <= update_type;
                end if;

                -- Update statistics (on lookup - tracked in pipeline)
                -- Statistics are managed externally
            end if;
        end if;
    end process;

end rtl;
