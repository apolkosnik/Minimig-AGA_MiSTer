------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Data Address Translation Cache (D-ATC) - Phase 9                --
--                                                                          --
-- Wrapper around generic ATC specialized for data addresses               --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- Data ATC:
-- - Wraps generic ATC for data address translation
-- - Integrated with D-Cache for coordinated operation
-- - Handles modified bit updates for write accesses
-- - Phase 9A: Stub with 1:1 translation (passthrough)
-- - Phase 9B+: Full table walk integration
--
-- Version: 1.0 (Phase 9A - Stub)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_MMU_Pack.all;

entity TG68040_DATC is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- MMU control
        mmu_enable     : in std_logic;                      -- MMU enabled
        supervisor     : in std_logic;                      -- Supervisor mode

        -- Translation request (from EA/MEM stages)
        trans_req      : in translation_request_t;
        trans_resp     : out translation_response_t;

        -- Invalidation control
        invalidate_all : in std_logic;
        invalidate_addr : in std_logic_vector(31 downto 0);
        invalidate_en  : in std_logic;

        -- Flush control (for write-back cache)
        flush_all      : in std_logic;

        -- Statistics
        lookups        : out std_logic_vector(31 downto 0);
        hits           : out std_logic_vector(31 downto 0);
        misses         : out std_logic_vector(31 downto 0)
    );
end TG68040_DATC;

architecture stub of TG68040_DATC is

    -- ATC instance signals
    signal atc_lookup_addr : std_logic_vector(31 downto 0);
    signal atc_lookup_en : std_logic;
    signal atc_lookup_hit : std_logic;
    signal atc_lookup_entry : atc_entry_t;
    signal atc_update_en : std_logic;
    signal atc_update_logical : std_logic_vector(31 downto 0);
    signal atc_update_entry : atc_entry_t;
    signal atc_replacements : std_logic_vector(31 downto 0);

    -- Component declaration
    component TG68040_ATC is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            lookup_addr    : in std_logic_vector(31 downto 0);
            lookup_en      : in std_logic;
            lookup_hit     : out std_logic;
            lookup_entry   : out atc_entry_t;
            update_en      : in std_logic;
            update_logical : in std_logic_vector(31 downto 0);
            update_entry   : in atc_entry_t;
            invalidate_all : in std_logic;
            invalidate_entry : in std_logic;
            invalidate_addr  : in std_logic_vector(31 downto 0);
            lookups        : out std_logic_vector(31 downto 0);
            hits           : out std_logic_vector(31 downto 0);
            misses         : out std_logic_vector(31 downto 0);
            replacements   : out std_logic_vector(31 downto 0)
        );
    end component;

begin

    ------------------------------------------------------------------------------
    -- Generic ATC Instance
    ------------------------------------------------------------------------------
    atc_inst: TG68040_ATC
        port map(
            clk            => clk,
            reset          => reset,
            lookup_addr    => atc_lookup_addr,
            lookup_en      => atc_lookup_en,
            lookup_hit     => atc_lookup_hit,
            lookup_entry   => atc_lookup_entry,
            update_en      => atc_update_en,
            update_logical => atc_update_logical,
            update_entry   => atc_update_entry,
            invalidate_all => invalidate_all or flush_all,  -- Flush also invalidates
            invalidate_entry => invalidate_en,
            invalidate_addr  => invalidate_addr,
            lookups        => lookups,
            hits           => hits,
            misses         => misses,
            replacements   => atc_replacements
        );

    ------------------------------------------------------------------------------
    -- Translation Logic (Phase 9A: Stub with 1:1 mapping)
    ------------------------------------------------------------------------------
    translation_proc: process(clk)
        variable page_offset : std_logic_vector(11 downto 0);
        variable physical_addr : std_logic_vector(31 downto 0);
        variable access_permitted : std_logic;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                trans_resp <= TRANSLATION_RESPONSE_INIT;
                atc_update_en <= '0';

            else
                -- Default: not ready
                trans_resp.ready <= '0';
                trans_resp.fault <= FAULT_NONE;
                atc_update_en <= '0';

                if trans_req.enable = '1' then
                    atc_lookup_addr <= trans_req.logical_addr;
                    atc_lookup_en <= '1';

                    -- Phase 9A Stub: MMU disabled or 1:1 translation
                    if mmu_enable = '0' then
                        -- MMU disabled: direct passthrough (1:1)
                        trans_resp.physical_addr <= trans_req.logical_addr;
                        trans_resp.cache_inhibit <= '0';
                        trans_resp.cache_mode <= "01";  -- Copyback
                        trans_resp.ready <= '1';
                        trans_resp.fault <= FAULT_NONE;

                    elsif atc_lookup_hit = '1' then
                        -- ATC hit: use cached translation
                        page_offset := get_page_offset(trans_req.logical_addr);
                        physical_addr := combine_address(
                            atc_lookup_entry.physical_frame,
                            page_offset
                        );

                        -- Check access permissions
                        access_permitted := check_access_permitted(
                            atc_lookup_entry.write_protect,
                            atc_lookup_entry.user_super,
                            trans_req.access_type,
                            trans_req.supervisor
                        );

                        if access_permitted = '1' then
                            trans_resp.physical_addr <= physical_addr;
                            trans_resp.cache_inhibit <= atc_lookup_entry.cache_inhibit;
                            trans_resp.cache_mode <= atc_lookup_entry.cache_mode;
                            trans_resp.ready <= '1';
                            trans_resp.fault <= FAULT_NONE;

                            -- Update modified bit on write access
                            if trans_req.access_type = ACCESS_WRITE then
                                atc_update_logical <= trans_req.logical_addr;
                                atc_update_entry <= atc_lookup_entry;
                                atc_update_entry.modified <= '1';  -- Set M bit
                                atc_update_en <= '1';
                            end if;
                        else
                            -- Protection violation
                            trans_resp.physical_addr <= (others => '0');
                            trans_resp.ready <= '1';
                            if trans_req.access_type = ACCESS_WRITE and
                               atc_lookup_entry.write_protect = '1' then
                                trans_resp.fault <= FAULT_WRITE_PROTECT;
                            else
                                trans_resp.fault <= FAULT_SUPERVISOR;
                            end if;
                        end if;

                    else
                        -- ATC miss: Phase 9A stub does 1:1 translation
                        -- In Phase 9C, this will trigger table walk
                        page_offset := get_page_offset(trans_req.logical_addr);
                        physical_addr := trans_req.logical_addr;  -- 1:1 for stub

                        -- Create entry for ATC update
                        atc_update_logical <= trans_req.logical_addr;
                        atc_update_entry.valid <= '1';
                        atc_update_entry.logical_tag <= get_page_number(trans_req.logical_addr);
                        atc_update_entry.physical_frame <= get_page_number(trans_req.logical_addr);  -- 1:1
                        atc_update_entry.modified <=
                            '1' when trans_req.access_type = ACCESS_WRITE else '0';
                        atc_update_entry.used <= '1';
                        atc_update_entry.write_protect <= '0';
                        atc_update_entry.user_super <= trans_req.supervisor;
                        atc_update_entry.cache_inhibit <= '0';
                        atc_update_entry.cache_mode <= "01";  -- Copyback
                        atc_update_entry.lru_bits <= (others => '0');
                        atc_update_en <= '1';

                        -- Return 1:1 translation
                        trans_resp.physical_addr <= physical_addr;
                        trans_resp.cache_inhibit <= '0';
                        trans_resp.cache_mode <= "01";
                        trans_resp.ready <= '1';
                        trans_resp.fault <= FAULT_NONE;
                    end if;
                else
                    atc_lookup_en <= '0';
                end if;
            end if;
        end if;
    end process;

end stub;
