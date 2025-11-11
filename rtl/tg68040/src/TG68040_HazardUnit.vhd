------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Hazard Detection Unit (Phase 4)                                 --
--                                                                          --
-- Detects pipeline hazards and generates forwarding control signals       --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- Hazard Types:
-- - RAW (Read After Write): Later instruction reads register before
--   earlier instruction writes it
-- - WAW (Write After Write): Two instructions write same register
-- - WAR (Write After Read): Later instruction writes register before
--   earlier instruction reads it
--
-- Solutions:
-- - Data Forwarding: Bypass register file, forward from EX or WB
-- - Pipeline Stall: Insert bubbles when forwarding not possible
--
-- Version: 0.1 (Phase 4)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;
use work.TG68040_Pipeline_Regs.all;

entity TG68040_HazardUnit is
    port(
        -- Clock (for registered outputs, if needed)
        clk            : in std_logic;
        reset          : in std_logic;

        -- ID/EA stage (instruction being decoded)
        id_ea_valid    : in std_logic;
        id_ea_src_reg1 : in std_logic_vector(3 downto 0);
        id_ea_src_reg2 : in std_logic_vector(3 downto 0);
        id_ea_dst_reg  : in std_logic_vector(3 downto 0);
        id_ea_write    : in std_logic;

        -- EA/OF stage
        ea_of_valid    : in std_logic;
        ea_of_dst_reg  : in std_logic_vector(3 downto 0);
        ea_of_write    : in std_logic;

        -- OF/EX stage (instruction in execute)
        of_ex_valid    : in std_logic;
        of_ex_dst_reg  : in std_logic_vector(3 downto 0);
        of_ex_write    : in std_logic;
        of_ex_read_mem : in std_logic;  -- Load instruction (Phase 6)

        -- EX/WB stage (instruction in write-back)
        ex_wb_valid    : in std_logic;
        ex_wb_dst_reg  : in std_logic_vector(3 downto 0);
        ex_wb_write    : in std_logic;

        -- Hazard outputs
        hazard_info    : out hazard_info_t;

        -- Control outputs
        stall_pipeline : out std_logic
    );
end TG68040_HazardUnit;

architecture rtl of TG68040_HazardUnit is

    -- Internal hazard detection signals
    signal raw_ex_a : std_logic;
    signal raw_ex_b : std_logic;
    signal raw_wb_a : std_logic;
    signal raw_wb_b : std_logic;
    signal waw_ex   : std_logic;
    signal waw_wb   : std_logic;
    signal load_use : std_logic;  -- Load-use hazard (Phase 6)

begin

    ------------------------------------------------------------------------------
    -- Combinational Hazard Detection
    ------------------------------------------------------------------------------
    hazard_detect: process(id_ea_valid, id_ea_src_reg1, id_ea_src_reg2,
                          id_ea_dst_reg, id_ea_write,
                          ea_of_valid, ea_of_dst_reg, ea_of_write,
                          of_ex_valid, of_ex_dst_reg, of_ex_write, of_ex_read_mem,
                          ex_wb_valid, ex_wb_dst_reg, ex_wb_write)
    begin
        -- Default: no hazards
        raw_ex_a <= '0';
        raw_ex_b <= '0';
        raw_wb_a <= '0';
        raw_wb_b <= '0';
        waw_ex <= '0';
        waw_wb <= '0';
        load_use <= '0';

        ----------------------------------------------------------------------
        -- RAW Hazard Detection: EX stage
        ----------------------------------------------------------------------
        -- Check if OF stage reads register that EX stage will write
        if id_ea_valid = '1' and of_ex_valid = '1' and of_ex_write = '1' then
            -- Check operand A
            if id_ea_src_reg1 = of_ex_dst_reg and id_ea_src_reg1 /= "0000" then
                raw_ex_a <= '1';
            end if;

            -- Check operand B
            if id_ea_src_reg2 = of_ex_dst_reg and id_ea_src_reg2 /= "0000" then
                raw_ex_b <= '1';
            end if;
        end if;

        ----------------------------------------------------------------------
        -- RAW Hazard Detection: WB stage
        ----------------------------------------------------------------------
        -- Check if OF stage reads register that WB stage will write
        if id_ea_valid = '1' and ex_wb_valid = '1' and ex_wb_write = '1' then
            -- Check operand A (only if not already forwarding from EX)
            if id_ea_src_reg1 = ex_wb_dst_reg and id_ea_src_reg1 /= "0000" and raw_ex_a = '0' then
                raw_wb_a <= '1';
            end if;

            -- Check operand B (only if not already forwarding from EX)
            if id_ea_src_reg2 = ex_wb_dst_reg and id_ea_src_reg2 /= "0000" and raw_ex_b = '0' then
                raw_wb_b <= '1';
            end if;
        end if;

        ----------------------------------------------------------------------
        -- WAW Hazard Detection
        ----------------------------------------------------------------------
        -- Two instructions writing to same register
        -- Check against EX stage
        if id_ea_valid = '1' and id_ea_write = '1' and
           of_ex_valid = '1' and of_ex_write = '1' then
            if id_ea_dst_reg = of_ex_dst_reg and id_ea_dst_reg /= "0000" then
                waw_ex <= '1';
            end if;
        end if;

        -- Check against WB stage
        if id_ea_valid = '1' and id_ea_write = '1' and
           ex_wb_valid = '1' and ex_wb_write = '1' then
            if id_ea_dst_reg = ex_wb_dst_reg and id_ea_dst_reg /= "0000" then
                waw_wb <= '1';
            end if;
        end if;

        ----------------------------------------------------------------------
        -- Load-Use Hazard Detection (Phase 6)
        ----------------------------------------------------------------------
        -- A load instruction in EX stage followed by an instruction that
        -- uses the loaded value creates a 1-cycle stall
        if of_ex_valid = '1' and of_ex_read_mem = '1' and of_ex_write = '1' then
            -- There's a load in EX stage that will write to a register
            if id_ea_valid = '1' then
                -- Check if ID/EA stage reads the register being loaded
                if (id_ea_src_reg1 = of_ex_dst_reg and id_ea_src_reg1 /= "0000") or
                   (id_ea_src_reg2 = of_ex_dst_reg and id_ea_src_reg2 /= "0000") then
                    load_use <= '1';
                end if;
            end if;
        end if;

    end process;

    ------------------------------------------------------------------------------
    -- Forwarding Control Generation
    ------------------------------------------------------------------------------
    forwarding_control: process(raw_ex_a, raw_ex_b, raw_wb_a, raw_wb_b,
                                 waw_ex, waw_wb, load_use)
        variable hazard_out : hazard_info_t;
    begin
        -- Initialize
        hazard_out := HAZARD_INFO_INIT;

        -- Set RAW hazard flag
        if raw_ex_a = '1' or raw_ex_b = '1' or raw_wb_a = '1' or raw_wb_b = '1' then
            hazard_out.raw_hazard := '1';
        end if;

        -- Set WAW hazard flag
        if waw_ex = '1' or waw_wb = '1' then
            hazard_out.waw_hazard := '1';
        end if;

        -- WAR hazards don't occur in this in-order pipeline
        hazard_out.war_hazard := '0';

        -- Set load-use hazard flag (Phase 6)
        hazard_out.load_use_hazard := load_use;
        hazard_out.stall_for_load := load_use;

        -- Set forwarding control signals
        hazard_out.forward_ex_a := raw_ex_a;
        hazard_out.forward_ex_b := raw_ex_b;
        hazard_out.forward_wb_a := raw_wb_a;
        hazard_out.forward_wb_b := raw_wb_b;

        -- Determine if stall required
        -- Phase 4: Handle most hazards with forwarding
        -- Phase 6: Load-use hazards require 1-cycle stall
        hazard_out.stall_required := load_use;

        -- Output
        hazard_info <= hazard_out;
        stall_pipeline <= hazard_out.stall_required;

    end process;

end rtl;
