------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Data Cache - Real Implementation (Phase 7)                      --
--                                                                          --
-- 4-way set-associative D-cache with write-back and LRU replacement       --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- MC68040 D-Cache:
-- - 4KB size
-- - 4-way set-associative
-- - 64 sets × 4 ways
-- - 16-byte lines (4 longwords)
-- - Pseudo-LRU replacement
-- - Write-back with write-allocate
-- - Dirty bits per line
--
-- Version: 1.0 (Phase 7 - Real)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Cache_Pack.all;

entity TG68040_DCache_Real is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Cache control (from CACR)
        cache_enable   : in std_logic;
        cache_freeze   : in std_logic;
        cache_invalidate : in std_logic;
        cache_flush    : in std_logic;

        -- Memory operation interface (from EX stage)
        mem_req        : in std_logic;
        mem_write      : in std_logic;
        mem_size       : in std_logic_vector(1 downto 0);
        mem_addr       : in std_logic_vector(31 downto 0);
        mem_data_in    : in std_logic_vector(31 downto 0);
        mem_data_out   : out std_logic_vector(31 downto 0);
        mem_ready      : out std_logic;

        -- Bus interface (for cache misses/write-backs)
        bus_req        : out std_logic;
        bus_write      : out std_logic;
        bus_addr       : out std_logic_vector(31 downto 0);
        bus_data_in    : out std_logic_vector(31 downto 0);
        bus_data_out   : in std_logic_vector(31 downto 0);
        bus_ready      : in std_logic;

        -- Statistics
        hit_count      : out std_logic_vector(31 downto 0);
        miss_count     : out std_logic_vector(31 downto 0);
        read_count     : out std_logic_vector(31 downto 0);
        write_count    : out std_logic_vector(31 downto 0)
    );
end TG68040_DCache_Real;

architecture rtl of TG68040_DCache_Real is

    -- Cache state machine
    type cache_state_t is (IDLE, LOOKUP, READ_HIT, WRITE_HIT, MISS,
                           WRITE_BACK, LINE_FILL, FLUSH);
    signal state : cache_state_t := IDLE;

    -- Cache storage
    signal cache_array : cache_array_t := (others => CACHE_SET_INIT);
    signal lru_array : lru_array_t := (others => (others => '0'));

    -- Address fields
    signal tag : std_logic_vector(21 downto 0);
    signal set_index : integer range 0 to 63;
    signal word_offset : integer range 0 to 3;
    signal byte_offset : integer range 0 to 3;

    -- Hit detection
    signal hit : std_logic;
    signal hit_way : integer range 0 to 3;
    signal victim_way : integer range 0 to 3;

    -- Line fill/write-back
    signal fill_addr : std_logic_vector(31 downto 0);
    signal fill_count : integer range 0 to 3;
    signal fill_data : std_logic_vector(127 downto 0);
    signal wb_addr : std_logic_vector(31 downto 0);
    signal wb_count : integer range 0 to 3;

    -- Latched request
    signal req_addr : std_logic_vector(31 downto 0);
    signal req_write : std_logic;
    signal req_size : std_logic_vector(1 downto 0);
    signal req_data : std_logic_vector(31 downto 0);
    signal req_valid : std_logic;

    -- Statistics
    signal hits : unsigned(31 downto 0) := (others => '0');
    signal misses : unsigned(31 downto 0) := (others => '0');
    signal reads : unsigned(31 downto 0) := (others => '0');
    signal writes : unsigned(31 downto 0) := (others => '0');

    -- Flush state
    signal flush_set : integer range 0 to 63;
    signal flush_way : integer range 0 to 3;

begin

    -- Output statistics
    hit_count <= std_logic_vector(hits);
    miss_count <= std_logic_vector(misses);
    read_count <= std_logic_vector(reads);
    write_count <= std_logic_vector(writes);

    ------------------------------------------------------------------------------
    -- Main Cache Process
    ------------------------------------------------------------------------------
    cache_proc: process(clk)
        variable temp_data : std_logic_vector(31 downto 0);
        variable line_data : std_logic_vector(127 downto 0);
        variable hit_detected : std_logic;
        variable hit_way_var : integer range 0 to 3;
        variable byte_pos : integer;
        variable word_in_line : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Reset state
                state <= IDLE;
                mem_ready <= '0';
                bus_req <= '0';
                bus_write <= '0';
                hits <= (others => '0');
                misses <= (others => '0');
                reads <= (others => '0');
                writes <= (others => '0');
                req_valid <= '0';
                hit <= '0';

            elsif cache_invalidate = '1' then
                -- Invalidate all cache lines (clears valid and dirty bits)
                for s in 0 to 63 loop
                    for w in 0 to 3 loop
                        cache_array(s)(w).valid <= '0';
                        cache_array(s)(w).dirty <= '0';
                    end loop;
                end loop;
                state <= IDLE;
                mem_ready <= '0';

            elsif cache_flush = '1' then
                -- Flush all dirty lines
                flush_set <= 0;
                flush_way <= 0;
                state <= FLUSH;
                mem_ready <= '0';

            else
                case state is
                    --------------------------------------------------------------
                    -- IDLE: Wait for memory request
                    --------------------------------------------------------------
                    when IDLE =>
                        mem_ready <= '0';
                        bus_req <= '0';
                        bus_write <= '0';

                        if cache_enable = '1' and mem_req = '1' then
                            -- Latch request
                            req_addr <= mem_addr;
                            req_write <= mem_write;
                            req_size <= mem_size;
                            req_data <= mem_data_in;
                            req_valid <= '1';

                            -- Extract address fields
                            tag <= get_tag(mem_addr);
                            set_index <= get_set_index(mem_addr);
                            word_offset <= get_word_offset(mem_addr);
                            byte_offset <= get_byte_offset(mem_addr);

                            state <= LOOKUP;

                        elsif cache_enable = '0' and mem_req = '1' then
                            -- Cache disabled - pass through to bus
                            bus_req <= '1';
                            bus_write <= mem_write;
                            bus_addr <= mem_addr;
                            if mem_write = '1' then
                                bus_data_in <= mem_data_in;
                            end if;
                            req_addr <= mem_addr;
                            req_write <= mem_write;
                            req_valid <= '1';
                            state <= LINE_FILL;  -- Reuse for pass-through
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
                                exit;
                            end if;
                        end loop;

                        hit <= hit_detected;
                        hit_way <= hit_way_var;

                        if hit_detected = '1' then
                            if req_write = '1' then
                                state <= WRITE_HIT;
                            else
                                state <= READ_HIT;
                            end if;
                        else
                            state <= MISS;
                        end if;

                    --------------------------------------------------------------
                    -- READ_HIT: Return data from cache
                    --------------------------------------------------------------
                    when READ_HIT =>
                        -- Extract requested data
                        line_data := cache_array(set_index)(hit_way).data;
                        temp_data := line_data(word_offset * 32 + 31 downto word_offset * 32);

                        -- Extract correct size
                        case req_size is
                            when "00" =>  -- Byte
                                byte_pos := byte_offset;
                                mem_data_out <= x"000000" & temp_data(byte_pos * 8 + 7 downto byte_pos * 8);

                            when "01" =>  -- Word
                                word_in_line := to_integer(unsigned(req_addr(1 downto 1)));
                                mem_data_out <= x"0000" & temp_data(word_in_line * 16 + 15 downto word_in_line * 16);

                            when "10" =>  -- Longword
                                mem_data_out <= temp_data;

                            when others =>
                                mem_data_out <= (others => '0');
                        end case;

                        mem_ready <= '1';

                        -- Update LRU
                        if cache_freeze = '0' then
                            lru_array(set_index) <= update_lru_bits(
                                lru_array(set_index), hit_way);
                        end if;

                        -- Update statistics
                        hits <= hits + 1;
                        reads <= reads + 1;

                        state <= IDLE;
                        req_valid <= '0';

                    --------------------------------------------------------------
                    -- WRITE_HIT: Update cache line and set dirty bit
                    --------------------------------------------------------------
                    when WRITE_HIT =>
                        -- Read current line data
                        line_data := cache_array(set_index)(hit_way).data;
                        temp_data := line_data(word_offset * 32 + 31 downto word_offset * 32);

                        -- Update based on size
                        case req_size is
                            when "00" =>  -- Byte
                                byte_pos := byte_offset;
                                temp_data(byte_pos * 8 + 7 downto byte_pos * 8) := req_data(7 downto 0);

                            when "01" =>  -- Word
                                word_in_line := to_integer(unsigned(req_addr(1 downto 1)));
                                temp_data(word_in_line * 16 + 15 downto word_in_line * 16) := req_data(15 downto 0);

                            when "10" =>  -- Longword
                                temp_data := req_data;

                            when others =>
                                null;
                        end case;

                        -- Write back to cache line
                        line_data(word_offset * 32 + 31 downto word_offset * 32) := temp_data;
                        cache_array(set_index)(hit_way).data <= line_data;

                        -- Mark as dirty
                        if cache_freeze = '0' then
                            cache_array(set_index)(hit_way).dirty <= '1';

                            -- Update LRU
                            lru_array(set_index) <= update_lru_bits(
                                lru_array(set_index), hit_way);
                        end if;

                        mem_ready <= '1';

                        -- Update statistics
                        hits <= hits + 1;
                        writes <= writes + 1;

                        state <= IDLE;
                        req_valid <= '0';

                    --------------------------------------------------------------
                    -- MISS: Find victim and check if write-back needed
                    --------------------------------------------------------------
                    when MISS =>
                        -- Find LRU way to replace
                        victim_way <= get_lru_way(lru_array(set_index));

                        -- Check if victim is dirty
                        if cache_array(set_index)(get_lru_way(lru_array(set_index))).dirty = '1' and
                           cache_array(set_index)(get_lru_way(lru_array(set_index))).valid = '1' then
                            -- Need to write back dirty line first
                            wb_addr <= cache_array(set_index)(get_lru_way(lru_array(set_index))).tag &
                                      std_logic_vector(to_unsigned(set_index, 6)) & "0000";
                            wb_count <= 0;
                            state <= WRITE_BACK;
                        else
                            -- No write-back needed, go directly to line fill
                            fill_addr <= align_to_line(req_addr);
                            fill_count <= 0;
                            bus_req <= '1';
                            bus_write <= '0';
                            bus_addr <= align_to_line(req_addr);
                            state <= LINE_FILL;
                        end if;

                        -- Update statistics
                        misses <= misses + 1;
                        if req_write = '1' then
                            writes <= writes + 1;
                        else
                            reads <= reads + 1;
                        end if;

                    --------------------------------------------------------------
                    -- WRITE_BACK: Write dirty line to memory
                    --------------------------------------------------------------
                    when WRITE_BACK =>
                        bus_req <= '1';
                        bus_write <= '1';
                        bus_addr <= wb_addr;
                        bus_data_in <= cache_array(set_index)(victim_way).data(
                            wb_count * 32 + 31 downto wb_count * 32);

                        if bus_ready = '1' then
                            if wb_count < 3 then
                                wb_count <= wb_count + 1;
                                wb_addr <= std_logic_vector(unsigned(wb_addr) + 4);
                            else
                                -- Write-back complete
                                cache_array(set_index)(victim_way).dirty <= '0';
                                bus_req <= '0';
                                bus_write <= '0';

                                -- Proceed to line fill
                                fill_addr <= align_to_line(req_addr);
                                fill_count <= 0;
                                bus_req <= '1';
                                bus_write <= '0';
                                bus_addr <= align_to_line(req_addr);
                                state <= LINE_FILL;
                            end if;
                        end if;

                    --------------------------------------------------------------
                    -- LINE_FILL: Fetch line from memory
                    --------------------------------------------------------------
                    when LINE_FILL =>
                        if bus_ready = '1' then
                            -- Store received longword
                            case fill_count is
                                when 0 =>
                                    fill_data(31 downto 0) <= bus_data_out;
                                when 1 =>
                                    fill_data(63 downto 32) <= bus_data_out;
                                when 2 =>
                                    fill_data(95 downto 64) <= bus_data_out;
                                when 3 =>
                                    fill_data(127 downto 96) <= bus_data_out;
                            end case;

                            if fill_count < 3 then
                                fill_count <= fill_count + 1;
                                fill_addr <= std_logic_vector(unsigned(fill_addr) + 4);
                                bus_addr <= std_logic_vector(unsigned(fill_addr) + 4);
                            else
                                -- Line fill complete
                                bus_req <= '0';

                                if cache_enable = '1' and cache_freeze = '0' then
                                    -- Update cache line
                                    cache_array(set_index)(victim_way).valid <= '1';
                                    cache_array(set_index)(victim_way).tag <= tag;
                                    cache_array(set_index)(victim_way).data <= fill_data;
                                    cache_array(set_index)(victim_way).dirty <= '0';

                                    -- If this was a write miss, update the line now
                                    if req_write = '1' then
                                        line_data := fill_data;
                                        temp_data := line_data(word_offset * 32 + 31 downto word_offset * 32);

                                        case req_size is
                                            when "00" =>
                                                byte_pos := byte_offset;
                                                temp_data(byte_pos * 8 + 7 downto byte_pos * 8) := req_data(7 downto 0);
                                            when "01" =>
                                                word_in_line := to_integer(unsigned(req_addr(1 downto 1)));
                                                temp_data(word_in_line * 16 + 15 downto word_in_line * 16) := req_data(15 downto 0);
                                            when "10" =>
                                                temp_data := req_data;
                                            when others => null;
                                        end case;

                                        line_data(word_offset * 32 + 31 downto word_offset * 32) := temp_data;
                                        cache_array(set_index)(victim_way).data <= line_data;
                                        cache_array(set_index)(victim_way).dirty <= '1';
                                    else
                                        -- Read miss - return data
                                        temp_data := fill_data(word_offset * 32 + 31 downto word_offset * 32);
                                        case req_size is
                                            when "00" =>
                                                byte_pos := byte_offset;
                                                mem_data_out <= x"000000" & temp_data(byte_pos * 8 + 7 downto byte_pos * 8);
                                            when "01" =>
                                                word_in_line := to_integer(unsigned(req_addr(1 downto 1)));
                                                mem_data_out <= x"0000" & temp_data(word_in_line * 16 + 15 downto word_in_line * 16);
                                            when "10" =>
                                                mem_data_out <= temp_data;
                                            when others =>
                                                mem_data_out <= (others => '0');
                                        end case;
                                    end if;

                                    -- Update LRU
                                    lru_array(set_index) <= update_lru_bits(
                                        lru_array(set_index), victim_way);
                                end if;

                                mem_ready <= '1';
                                state <= IDLE;
                                req_valid <= '0';
                            end if;
                        end if;

                    --------------------------------------------------------------
                    -- FLUSH: Write back all dirty lines
                    --------------------------------------------------------------
                    when FLUSH =>
                        -- Check if current line is dirty
                        if cache_array(flush_set)(flush_way).dirty = '1' and
                           cache_array(flush_set)(flush_way).valid = '1' then
                            -- Write back this line
                            wb_addr <= cache_array(flush_set)(flush_way).tag &
                                      std_logic_vector(to_unsigned(flush_set, 6)) & "0000";
                            wb_count <= 0;
                            state <= WRITE_BACK;
                        else
                            -- Skip this line, move to next
                            if flush_way < 3 then
                                flush_way <= flush_way + 1;
                            elsif flush_set < 63 then
                                flush_set <= flush_set + 1;
                                flush_way <= 0;
                            else
                                -- Flush complete
                                state <= IDLE;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end rtl;
