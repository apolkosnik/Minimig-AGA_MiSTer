------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Address Translation Cache (ATC) - Phase 9                       --
--                                                                          --
-- 64-entry fully associative translation cache with LRU replacement       --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- Address Translation Cache:
-- - 64 entries, fully associative
-- - LRU replacement policy
-- - Tag = logical address [31:12] (20 bits)
-- - Data = physical frame [31:12] + protection bits
-- - Phase 9A: Stub with 1:1 translation (always hit)
--
-- Version: 1.0 (Phase 9A - Stub)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_MMU_Pack.all;

entity TG68040_ATC is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Lookup interface (combinational)
        lookup_addr    : in std_logic_vector(31 downto 0);
        lookup_en      : in std_logic;
        lookup_hit     : out std_logic;
        lookup_entry   : out atc_entry_t;

        -- Update interface (registered)
        update_en      : in std_logic;
        update_logical : in std_logic_vector(31 downto 0);
        update_entry   : in atc_entry_t;

        -- Invalidation interface
        invalidate_all : in std_logic;
        invalidate_entry : in std_logic;
        invalidate_addr  : in std_logic_vector(31 downto 0);

        -- Statistics
        lookups        : out std_logic_vector(31 downto 0);
        hits           : out std_logic_vector(31 downto 0);
        misses         : out std_logic_vector(31 downto 0);
        replacements   : out std_logic_vector(31 downto 0)
    );
end TG68040_ATC;

architecture stub of TG68040_ATC is

    -- ATC storage (64 entries)
    signal atc_array : atc_array_t := (others => ATC_ENTRY_INIT);

    -- LRU tracking (simple counter-based)
    type lru_array_t is array (0 to 63) of unsigned(5 downto 0);
    signal lru_counters : lru_array_t := (others => (others => '0'));
    signal lru_victim : integer range 0 to 63 := 0;

    -- Statistics
    signal stat_lookups : unsigned(31 downto 0) := (others => '0');
    signal stat_hits : unsigned(31 downto 0) := (others => '0');
    signal stat_misses : unsigned(31 downto 0) := (others => '0');
    signal stat_replacements : unsigned(31 downto 0) := (others => '0');

    -- Internal signals
    signal hit_entry : atc_entry_t;
    signal hit_index : integer range 0 to 63;
    signal hit_found : std_logic;

begin

    -- Output statistics
    lookups <= std_logic_vector(stat_lookups);
    hits <= std_logic_vector(stat_hits);
    misses <= std_logic_vector(stat_misses);
    replacements <= std_logic_vector(stat_replacements);

    ------------------------------------------------------------------------------
    -- Lookup Logic (Combinational)
    ------------------------------------------------------------------------------
    lookup_proc: process(lookup_addr, lookup_en, atc_array)
        variable page_number : std_logic_vector(19 downto 0);
        variable found : std_logic;
        variable entry_idx : integer range 0 to 63;
    begin
        page_number := get_page_number(lookup_addr);
        found := '0';
        entry_idx := 0;
        hit_entry <= ATC_ENTRY_INIT;

        if lookup_en = '1' then
            -- Search all 64 entries (fully associative)
            for i in 0 to 63 loop
                if atc_array(i).valid = '1' and
                   atc_array(i).logical_tag = page_number then
                    found := '1';
                    entry_idx := i;
                    hit_entry <= atc_array(i);
                    exit;
                end if;
            end loop;
        end if;

        hit_found <= found;
        hit_index <= entry_idx;
        lookup_hit <= found;
        lookup_entry <= hit_entry;
    end process;

    ------------------------------------------------------------------------------
    -- Update and Replacement Logic (Registered)
    ------------------------------------------------------------------------------
    update_proc: process(clk)
        variable page_number : std_logic_vector(19 downto 0);
        variable found : std_logic;
        variable victim : integer range 0 to 63;
        variable max_lru : unsigned(5 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Clear all entries
                atc_array <= (others => ATC_ENTRY_INIT);
                lru_counters <= (others => (others => '0'));
                lru_victim <= 0;
                stat_lookups <= (others => '0');
                stat_hits <= (others => '0');
                stat_misses <= (others => '0');
                stat_replacements <= (others => '0');

            else
                -- Invalidate all entries
                if invalidate_all = '1' then
                    for i in 0 to 63 loop
                        atc_array(i).valid <= '0';
                    end loop;
                end if;

                -- Invalidate specific entry
                if invalidate_entry = '1' then
                    page_number := get_page_number(invalidate_addr);
                    for i in 0 to 63 loop
                        if atc_array(i).valid = '1' and
                           atc_array(i).logical_tag = page_number then
                            atc_array(i).valid <= '0';
                        end if;
                    end loop;
                end if;

                -- Update entry (on table walk complete or TLB fill)
                if update_en = '1' then
                    page_number := get_page_number(update_logical);
                    found := '0';

                    -- Check if entry already exists (update in place)
                    for i in 0 to 63 loop
                        if atc_array(i).valid = '1' and
                           atc_array(i).logical_tag = page_number then
                            atc_array(i) <= update_entry;
                            atc_array(i).logical_tag <= page_number;
                            lru_counters(i) <= (others => '0');  -- Reset LRU
                            found := '1';
                            exit;
                        end if;
                    end loop;

                    -- If not found, find LRU victim and replace
                    if found = '0' then
                        victim := 0;
                        max_lru := lru_counters(0);

                        for i in 1 to 63 loop
                            if lru_counters(i) > max_lru then
                                max_lru := lru_counters(i);
                                victim := i;
                            end if;
                        end loop;

                        -- Replace LRU entry
                        atc_array(victim) <= update_entry;
                        atc_array(victim).logical_tag <= page_number;
                        lru_counters(victim) <= (others => '0');
                        stat_replacements <= stat_replacements + 1;
                        lru_victim <= victim;
                    end if;
                end if;

                -- Update LRU counters (increment all except recently used)
                if lookup_en = '1' then
                    stat_lookups <= stat_lookups + 1;

                    if hit_found = '1' then
                        stat_hits <= stat_hits + 1;
                        -- Reset LRU for hit entry
                        lru_counters(hit_index) <= (others => '0');

                        -- Increment all others (saturating)
                        for i in 0 to 63 loop
                            if i /= hit_index and lru_counters(i) /= 63 then
                                lru_counters(i) <= lru_counters(i) + 1;
                            end if;
                        end loop;
                    else
                        stat_misses <= stat_misses + 1;

                        -- Increment all LRU counters on miss (saturating)
                        for i in 0 to 63 loop
                            if lru_counters(i) /= 63 then
                                lru_counters(i) <= lru_counters(i) + 1;
                            end if;
                        end loop;
                    end if;
                end if;
            end if;
        end if;
    end process;

end stub;
