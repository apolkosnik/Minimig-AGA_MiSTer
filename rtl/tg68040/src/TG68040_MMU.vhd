------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Memory Management Unit (MMU) - Phase 9                          --
--                                                                          --
-- Complete MMU combining I-ATC, D-ATC, and control registers              --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- MC68040 MMU Features:
-- - Separate I-ATC and D-ATC (64 entries each)
-- - Translation Control Register (TC)
-- - Root Pointers (SRP/URP)
-- - MMU Status Register (MMUSR)
-- - Phase 9A: Stub with 1:1 translation
-- - Phase 9B+: Full table walk
--
-- Version: 1.0 (Phase 9A - Stub)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_MMU_Pack.all;

entity TG68040_MMU is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- MMU Control Registers
        tc_reg         : in tc_register_t;                  -- Translation Control
        srp_reg        : in root_pointer_t;                 -- Supervisor Root Pointer
        urp_reg        : in root_pointer_t;                 -- User Root Pointer
        mmusr_reg      : out mmusr_register_t;              -- MMU Status

        -- Instruction translation (IF stage)
        itrans_req     : in translation_request_t;
        itrans_resp    : out translation_response_t;

        -- Data translation (EA/MEM stages)
        dtrans_req     : in translation_request_t;
        dtrans_resp    : out translation_response_t;

        -- Invalidation/Flush control
        invalidate_all : in std_logic;                      -- Invalidate both ATCs
        invalidate_i   : in std_logic;                      -- Invalidate I-ATC only
        invalidate_d   : in std_logic;                      -- Invalidate D-ATC only
        flush_d        : in std_logic;                      -- Flush D-ATC (write-back)

        -- Statistics
        iatc_lookups   : out std_logic_vector(31 downto 0);
        iatc_hits      : out std_logic_vector(31 downto 0);
        iatc_misses    : out std_logic_vector(31 downto 0);
        datc_lookups   : out std_logic_vector(31 downto 0);
        datc_hits      : out std_logic_vector(31 downto 0);
        datc_misses    : out std_logic_vector(31 downto 0)
    );
end TG68040_MMU;

architecture rtl of TG68040_MMU is

    -- I-ATC signals
    signal iatc_invalidate_addr : std_logic_vector(31 downto 0);
    signal iatc_invalidate_en : std_logic;

    -- D-ATC signals
    signal datc_invalidate_addr : std_logic_vector(31 downto 0);
    signal datc_invalidate_en : std_logic;

    -- MMU status register
    signal mmusr : mmusr_register_t := MMUSR_REGISTER_INIT;

    -- Component declarations
    component TG68040_IATC is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            mmu_enable     : in std_logic;
            supervisor     : in std_logic;
            trans_req      : in translation_request_t;
            trans_resp     : out translation_response_t;
            invalidate_all : in std_logic;
            invalidate_addr : in std_logic_vector(31 downto 0);
            invalidate_en  : in std_logic;
            lookups        : out std_logic_vector(31 downto 0);
            hits           : out std_logic_vector(31 downto 0);
            misses         : out std_logic_vector(31 downto 0)
        );
    end component;

    component TG68040_DATC is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            mmu_enable     : in std_logic;
            supervisor     : in std_logic;
            trans_req      : in translation_request_t;
            trans_resp     : out translation_response_t;
            invalidate_all : in std_logic;
            invalidate_addr : in std_logic_vector(31 downto 0);
            invalidate_en  : in std_logic;
            flush_all      : in std_logic;
            lookups        : out std_logic_vector(31 downto 0);
            hits           : out std_logic_vector(31 downto 0);
            misses         : out std_logic_vector(31 downto 0)
        );
    end component;

begin

    -- Output MMU status register
    mmusr_reg <= mmusr;

    ------------------------------------------------------------------------------
    -- Instruction ATC (I-ATC)
    ------------------------------------------------------------------------------
    iatc_inst: TG68040_IATC
        port map(
            clk            => clk,
            reset          => reset,
            mmu_enable     => tc_reg.enable,
            supervisor     => tc_reg.supervisor_mode,
            trans_req      => itrans_req,
            trans_resp     => itrans_resp,
            invalidate_all => invalidate_all or invalidate_i,
            invalidate_addr => iatc_invalidate_addr,
            invalidate_en  => iatc_invalidate_en,
            lookups        => iatc_lookups,
            hits           => iatc_hits,
            misses         => iatc_misses
        );

    ------------------------------------------------------------------------------
    -- Data ATC (D-ATC)
    ------------------------------------------------------------------------------
    datc_inst: TG68040_DATC
        port map(
            clk            => clk,
            reset          => reset,
            mmu_enable     => tc_reg.enable,
            supervisor     => tc_reg.supervisor_mode,
            trans_req      => dtrans_req,
            trans_resp     => dtrans_resp,
            invalidate_all => invalidate_all or invalidate_d,
            invalidate_addr => datc_invalidate_addr,
            invalidate_en  => datc_invalidate_en,
            flush_all      => flush_d,
            lookups        => datc_lookups,
            hits           => datc_hits,
            misses         => datc_misses
        );

    ------------------------------------------------------------------------------
    -- MMU Control and Status
    ------------------------------------------------------------------------------
    mmu_control_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mmusr <= MMUSR_REGISTER_INIT;
                iatc_invalidate_en <= '0';
                datc_invalidate_en <= '0';

            else
                -- Default: no invalidation
                iatc_invalidate_en <= '0';
                datc_invalidate_en <= '0';

                -- Update MMUSR based on translation results
                -- Instruction translation faults
                if itrans_resp.ready = '1' and itrans_resp.fault /= FAULT_NONE then
                    mmusr.fault_addr <= itrans_req.logical_addr;
                    mmusr.write_access <= '0';  -- Instruction fetch (read)

                    case itrans_resp.fault is
                        when FAULT_INVALID =>
                            mmusr.invalid_desc <= '1';
                        when FAULT_SUPERVISOR =>
                            mmusr.supervisor_only <= '1';
                        when FAULT_BUS_ERROR =>
                            mmusr.bus_error <= '1';
                        when FAULT_LIMIT =>
                            mmusr.limit_violation <= '1';
                        when others =>
                            null;
                    end case;
                end if;

                -- Data translation faults
                if dtrans_resp.ready = '1' and dtrans_resp.fault /= FAULT_NONE then
                    mmusr.fault_addr <= dtrans_req.logical_addr;
                    mmusr.write_access <=
                        '1' when dtrans_req.access_type = ACCESS_WRITE else '0';

                    case dtrans_resp.fault is
                        when FAULT_INVALID =>
                            mmusr.invalid_desc <= '1';
                        when FAULT_WRITE_PROTECT =>
                            mmusr.write_protect <= '1';
                        when FAULT_SUPERVISOR =>
                            mmusr.supervisor_only <= '1';
                        when FAULT_BUS_ERROR =>
                            mmusr.bus_error <= '1';
                        when FAULT_LIMIT =>
                            mmusr.limit_violation <= '1';
                        when others =>
                            null;
                    end case;
                end if;

                -- Clear fault bits when no fault
                if itrans_resp.ready = '1' and itrans_resp.fault = FAULT_NONE and
                   dtrans_resp.ready = '1' and dtrans_resp.fault = FAULT_NONE then
                    mmusr.bus_error <= '0';
                    mmusr.limit_violation <= '0';
                    mmusr.supervisor_only <= '0';
                    mmusr.write_protect <= '0';
                    mmusr.invalid_desc <= '0';
                end if;

                -- Set resident bit if translation succeeded
                if tc_reg.enable = '1' then
                    if itrans_resp.ready = '1' and itrans_resp.fault = FAULT_NONE then
                        mmusr.resident <= '1';
                    elsif dtrans_resp.ready = '1' and dtrans_resp.fault = FAULT_NONE then
                        mmusr.resident <= '1';
                    end if;
                else
                    -- MMU disabled: transparent translation
                    mmusr.transparent <= '1';
                    mmusr.resident <= '1';
                end if;
            end if;
        end if;
    end process;

end rtl;
