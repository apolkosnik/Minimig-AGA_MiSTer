------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Instruction Cache - Real Implementation (Phase 7)               --
--                                                                          --
-- 4-way set-associative I-cache with LRU replacement                      --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- MC68040 I-Cache:
-- - 4KB size
-- - 4-way set-associative
-- - 64 sets × 4 ways
-- - 16-byte lines (4 longwords)
-- - Pseudo-LRU replacement
-- - Read-only (no dirty bits)
--
-- Version: 1.0 (Phase 7 - Real)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Cache_Pack.all;

entity TG68040_ICache_Real is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Cache control (from CACR)
        cache_enable   : in std_logic;
        cache_freeze   : in std_logic;
        cache_invalidate : in std_logic;

        -- Fetch interface (from IF stage)
        fetch_req      : in std_logic;
        fetch_addr     : in std_logic_vector(31 downto 0);
        fetch_data     : out std_logic_vector(15 downto 0);
        fetch_ready    : out std_logic;

        -- Memory bus interface (for cache misses)
        mem_req        : out std_logic;
        mem_addr       : out std_logic_vector(31 downto 0);
        mem_data       : in std_logic_vector(31 downto 0);
        mem_ready      : in std_logic;

        -- Statistics
        hit_count      : out std_logic_vector(31 downto 0);
        miss_count     : out std_logic_vector(31 downto 0);
        access_count   : out std_logic_vector(31 downto 0)
    );
end TG68040_ICache_Real;

architecture rtl of TG68040_ICache_Real is

    -- Cache state machine
    type cache_state_t is (IDLE, LOOKUP, HIT, MISS, LINE_FILL);
    signal state : cache_state_t := IDLE;

    -- Cache storage
    signal cache_array : cache_array_t := (others => CACHE_SET_INIT);
    signal lru_array : lru_array_t := (others => (others => '0'));

    -- Address fields
    signal tag : std_logic_vector(21 downto 0);
    signal set_index : integer range 0 to 63;
    signal word_offset : integer range 0 to 3;

    -- Hit detection
    signal hit : std_logic;
    signal hit_way : integer range 0 to 3;
    signal victim_way : integer range 0 to 3;

    -- Line fill
    signal fill_addr : std_logic_vector(31 downto 0);
    signal fill_count : integer range 0 to 3;
    signal fill_data : std_logic_vector(127 downto 0);

    -- Statistics
    signal stats : cache_stats_t := CACHE_STATS_INIT;

    -- Latched request
    signal req_addr : std_logic_vector(31 downto 0);
    signal req_valid : std_logic;

begin

    -- Output statistics
    hit_count <= std_logic_vector(stats.hits);
    miss_count <= std_logic_vector(stats.misses);
    access_count <= std_logic_vector(stats.accesses);

    ------------------------------------------------------------------------------
    -- Main Cache Process
    ------------------------------------------------------------------------------
    cache_proc: process(clk)
        variable temp_data : std_logic_vector(31 downto 0);
        variable hit_detected : std_logic;
        variable hit_way_var : integer range 0 to 3;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Reset state
                state <= IDLE;
                fetch_ready <= '0';
                mem_req <= '0';
                stats <= CACHE_STATS_INIT;
                req_valid <= '0';
                hit <= '0';

                -- Don't reset cache array - would be too large
                -- Instead rely on valid bits being 0

            elsif cache_invalidate = '1' then
                -- Invalidate all cache lines
                for s in 0 to 63 loop
                    for w in 0 to 3 loop
                        cache_array(s)(w).valid <= '0';
                    end loop;
                end loop;
                state <= IDLE;
                fetch_ready <= '0';
                stats <= CACHE_STATS_INIT;

            else
                case state is
                    --------------------------------------------------------------
                    -- IDLE: Wait for fetch request
                    --------------------------------------------------------------
                    when IDLE =>
                        fetch_ready <= '0';
                        mem_req <= '0';

                        if cache_enable = '1' and fetch_req = '1' then
                            -- Latch request
                            req_addr <= fetch_addr;
                            req_valid <= '1';
                            state <= LOOKUP;

                            -- Extract address fields
                            tag <= get_tag(fetch_addr);
                            set_index <= get_set_index(fetch_addr);
                            word_offset <= get_word_offset(fetch_addr);

                            -- Update statistics
                            stats.accesses <= stats.accesses + 1;
                        elsif cache_enable = '0' and fetch_req = '1' then
                            -- Cache disabled - pass through to memory
                            mem_req <= '1';
                            mem_addr <= fetch_addr;
                            req_addr <= fetch_addr;
                            req_valid <= '1';
                            state <= LINE_FILL;
                            fill_count <= 0;
                        end if;

                    --------------------------------------------------------------
                    -- LOOKUP: Check all 4 ways for hit
                    --------------------------------------------------------------
                    when LOOKUP =>
                        hit_detected := '0';
                        hit_way_var := 0;

                        -- Check all 4 ways in parallel
                        for w in 0 to 3 loop
                            if cache_array(set_index)(w).valid = '1' and
                               cache_array(set_index)(w).tag = tag then
                                hit_detected := '1';
                                hit_way_var := w;
                                exit;  -- Found hit
                            end if;
                        end loop;

                        hit <= hit_detected;
                        hit_way <= hit_way_var;

                        if hit_detected = '1' then
                            state <= HIT;
                        else
                            state <= MISS;
                        end if;

                    --------------------------------------------------------------
                    -- HIT: Return data from cache
                    --------------------------------------------------------------
                    when HIT =>
                        -- Extract requested word from cache line
                        temp_data := cache_array(set_index)(hit_way).data(
                            word_offset * 32 + 31 downto word_offset * 32);

                        -- Return low 16 bits (instruction is 16 bits)
                        fetch_data <= temp_data(15 downto 0);
                        fetch_ready <= '1';

                        -- Update LRU
                        if cache_freeze = '0' then
                            lru_array(set_index) <= update_lru_bits(
                                lru_array(set_index), hit_way);
                        end if;

                        -- Update statistics
                        stats.hits <= stats.hits + 1;

                        -- Return to idle
                        state <= IDLE;
                        req_valid <= '0';

                    --------------------------------------------------------------
                    -- MISS: Find victim and start line fill
                    --------------------------------------------------------------
                    when MISS =>
                        -- Find LRU way to replace
                        victim_way <= get_lru_way(lru_array(set_index));

                        -- Start line fill
                        fill_addr <= align_to_line(req_addr);
                        fill_count <= 0;
                        mem_req <= '1';
                        mem_addr <= align_to_line(req_addr);

                        -- Update statistics
                        stats.misses <= stats.misses + 1;

                        state <= LINE_FILL;

                    --------------------------------------------------------------
                    -- LINE_FILL: Fetch 4 longwords from memory
                    --------------------------------------------------------------
                    when LINE_FILL =>
                        if mem_ready = '1' then
                            -- Store received longword
                            case fill_count is
                                when 0 =>
                                    fill_data(31 downto 0) <= mem_data;
                                when 1 =>
                                    fill_data(63 downto 32) <= mem_data;
                                when 2 =>
                                    fill_data(95 downto 64) <= mem_data;
                                when 3 =>
                                    fill_data(127 downto 96) <= mem_data;
                            end case;

                            if fill_count < 3 then
                                -- Continue filling
                                fill_count <= fill_count + 1;
                                fill_addr <= std_logic_vector(unsigned(fill_addr) + 4);
                                mem_addr <= std_logic_vector(unsigned(fill_addr) + 4);
                                mem_req <= '1';
                            else
                                -- Line fill complete
                                mem_req <= '0';

                                if cache_enable = '1' and cache_freeze = '0' then
                                    -- Update cache line
                                    cache_array(set_index)(victim_way).valid <= '1';
                                    cache_array(set_index)(victim_way).tag <= tag;
                                    cache_array(set_index)(victim_way).data <=
                                        fill_data(127 downto 96) & fill_data(95 downto 64) &
                                        fill_data(63 downto 32) & fill_data(31 downto 0);

                                    -- Update LRU
                                    lru_array(set_index) <= update_lru_bits(
                                        lru_array(set_index), victim_way);
                                end if;

                                -- Return requested word
                                temp_data := fill_data(word_offset * 32 + 31 downto word_offset * 32);
                                fetch_data <= temp_data(15 downto 0);
                                fetch_ready <= '1';

                                state <= IDLE;
                                req_valid <= '0';
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end rtl;
