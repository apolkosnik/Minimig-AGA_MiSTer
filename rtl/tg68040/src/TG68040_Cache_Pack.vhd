------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Cache Package (Phase 7)                                         --
--                                                                          --
-- Common cache structures and functions for I-cache and D-cache           --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- MC68040 Cache Organization:
-- - 4KB size
-- - 4-way set-associative
-- - 64 sets
-- - 16-byte lines (4 longwords)
-- - Pseudo-LRU replacement
--
-- Version: 1.0 (Phase 7)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package TG68040_Cache_Pack is

    ------------------------------------------------------------------------------
    -- Cache Configuration Constants
    ------------------------------------------------------------------------------
    constant CACHE_SIZE : integer := 4096;          -- 4KB
    constant LINE_SIZE : integer := 16;              -- 16 bytes per line
    constant NUM_WAYS : integer := 4;                -- 4-way set-associative
    constant NUM_SETS : integer := 64;               -- 64 sets
    constant NUM_LINES : integer := 256;             -- Total lines (64 × 4)

    constant TAG_BITS : integer := 22;               -- Bits 31-10
    constant SET_BITS : integer := 6;                -- Bits 9-4
    constant WORD_BITS : integer := 2;               -- Bits 3-2
    constant BYTE_BITS : integer := 2;               -- Bits 1-0

    ------------------------------------------------------------------------------
    -- Cache Line Structure
    ------------------------------------------------------------------------------
    type cache_line_t is record
        valid       : std_logic;                        -- Valid bit
        dirty       : std_logic;                        -- Dirty bit (D-cache only)
        tag         : std_logic_vector(21 downto 0);    -- Tag (bits 31-10)
        data        : std_logic_vector(127 downto 0);   -- 16 bytes (4 longwords)
    end record;

    constant CACHE_LINE_INIT : cache_line_t := (
        valid => '0',
        dirty => '0',
        tag   => (others => '0'),
        data  => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- Cache Set Structure (4 ways)
    ------------------------------------------------------------------------------
    type cache_set_t is array (0 to 3) of cache_line_t;

    constant CACHE_SET_INIT : cache_set_t := (
        others => CACHE_LINE_INIT
    );

    ------------------------------------------------------------------------------
    -- Cache Array Structure (64 sets)
    ------------------------------------------------------------------------------
    type cache_array_t is array (0 to 63) of cache_set_t;

    ------------------------------------------------------------------------------
    -- LRU State (3 bits per set for pseudo-LRU tree)
    ------------------------------------------------------------------------------
    type lru_array_t is array (0 to 63) of std_logic_vector(2 downto 0);

    ------------------------------------------------------------------------------
    -- Address Extraction Functions
    ------------------------------------------------------------------------------

    -- Extract tag from address (bits 31-10)
    function get_tag(addr : std_logic_vector(31 downto 0)) return std_logic_vector;

    -- Extract set index from address (bits 9-4)
    function get_set_index(addr : std_logic_vector(31 downto 0)) return integer;

    -- Extract word offset from address (bits 3-2)
    function get_word_offset(addr : std_logic_vector(31 downto 0)) return integer;

    -- Extract byte offset from address (bits 1-0)
    function get_byte_offset(addr : std_logic_vector(31 downto 0)) return integer;

    -- Align address to cache line boundary (16 bytes)
    function align_to_line(addr : std_logic_vector(31 downto 0)) return std_logic_vector;

    ------------------------------------------------------------------------------
    -- LRU Functions (Pseudo-LRU Tree)
    ------------------------------------------------------------------------------

    -- Get LRU way to replace based on 3-bit tree
    function get_lru_way(lru_bits : std_logic_vector(2 downto 0)) return integer;

    -- Update LRU bits when a way is accessed
    function update_lru_bits(
        lru_bits : std_logic_vector(2 downto 0);
        way_accessed : integer range 0 to 3
    ) return std_logic_vector;

    ------------------------------------------------------------------------------
    -- Cache Statistics Type
    ------------------------------------------------------------------------------
    type cache_stats_t is record
        hits        : unsigned(31 downto 0);
        misses      : unsigned(31 downto 0);
        accesses    : unsigned(31 downto 0);
        writebacks  : unsigned(31 downto 0);    -- D-cache only
    end record;

    constant CACHE_STATS_INIT : cache_stats_t := (
        hits       => (others => '0'),
        misses     => (others => '0'),
        accesses   => (others => '0'),
        writebacks => (others => '0')
    );

end package TG68040_Cache_Pack;

package body TG68040_Cache_Pack is

    ------------------------------------------------------------------------------
    -- Address Extraction Functions
    ------------------------------------------------------------------------------

    function get_tag(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return addr(31 downto 10);
    end function;

    function get_set_index(addr : std_logic_vector(31 downto 0)) return integer is
    begin
        return to_integer(unsigned(addr(9 downto 4)));
    end function;

    function get_word_offset(addr : std_logic_vector(31 downto 0)) return integer is
    begin
        return to_integer(unsigned(addr(3 downto 2)));
    end function;

    function get_byte_offset(addr : std_logic_vector(31 downto 0)) return integer is
    begin
        return to_integer(unsigned(addr(1 downto 0)));
    end function;

    function align_to_line(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return addr(31 downto 4) & "0000";
    end function;

    ------------------------------------------------------------------------------
    -- LRU Functions (Pseudo-LRU Tree)
    ------------------------------------------------------------------------------
    --
    -- Tree Structure:
    --              bit0
    --             /    \
    --           /        \
    --        bit1        bit2
    --       /    \      /    \
    --     Way0  Way1  Way2  Way3
    --
    -- bit0: 0 = left subtree more recent, 1 = right subtree more recent
    -- bit1: 0 = Way0 more recent, 1 = Way1 more recent
    -- bit2: 0 = Way2 more recent, 1 = Way3 more recent
    ------------------------------------------------------------------------------

    function get_lru_way(lru_bits : std_logic_vector(2 downto 0)) return integer is
    begin
        -- Find least recently used way
        if lru_bits(0) = '0' then
            -- Replace from right subtree (Way 2 or 3)
            if lru_bits(2) = '0' then
                return 2;  -- Way 2 is LRU
            else
                return 3;  -- Way 3 is LRU
            end if;
        else
            -- Replace from left subtree (Way 0 or 1)
            if lru_bits(1) = '0' then
                return 0;  -- Way 0 is LRU
            else
                return 1;  -- Way 1 is LRU
            end if;
        end if;
    end function;

    function update_lru_bits(
        lru_bits : std_logic_vector(2 downto 0);
        way_accessed : integer range 0 to 3
    ) return std_logic_vector is
        variable new_lru : std_logic_vector(2 downto 0);
    begin
        new_lru := lru_bits;

        case way_accessed is
            when 0 =>
                -- Way 0 accessed: mark left subtree more recent
                new_lru(0) := '1';  -- Left subtree more recent
                new_lru(1) := '1';  -- Way 0 more recent than Way 1

            when 1 =>
                -- Way 1 accessed: mark left subtree more recent
                new_lru(0) := '1';  -- Left subtree more recent
                new_lru(1) := '0';  -- Way 1 more recent than Way 0

            when 2 =>
                -- Way 2 accessed: mark right subtree more recent
                new_lru(0) := '0';  -- Right subtree more recent
                new_lru(2) := '1';  -- Way 2 more recent than Way 3

            when 3 =>
                -- Way 3 accessed: mark right subtree more recent
                new_lru(0) := '0';  -- Right subtree more recent
                new_lru(2) := '0';  -- Way 3 more recent than Way 2
        end case;

        return new_lru;
    end function;

end package body TG68040_Cache_Pack;
