------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Branch Prediction Unit (Phase 8)                                --
--                                                                          --
-- Combines BTB and RAS for complete branch prediction                     --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- Branch Prediction Unit:
-- - Combines BTB (Branch Target Buffer) and RAS (Return Address Stack)
-- - Provides prediction in IF stage (combinational lookup)
-- - Updates prediction tables in EX stage (registered)
-- - Detects mispredictions and signals pipeline flush
--
-- Version: 1.0 (Phase 8)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Branch_Pack.all;

entity TG68040_BranchUnit is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Prediction request (IF stage - combinational)
        predict_pc     : in std_logic_vector(31 downto 0);
        predict_instr  : in std_logic_vector(15 downto 0);
        predict_valid  : out std_logic;           -- Have a prediction
        predict_taken  : out std_logic;           -- Predict taken
        predict_target : out std_logic_vector(31 downto 0);  -- Predicted target
        btb_hit        : out std_logic;           -- BTB had entry
        ras_hit        : out std_logic;           -- RAS had entry

        -- Branch resolution (EX stage - registered)
        resolve_en     : in std_logic;            -- Branch in EX stage
        resolve_pc     : in std_logic_vector(31 downto 0);
        resolve_type   : in branch_type_t;
        resolve_taken  : in std_logic;            -- Actual taken
        resolve_target : in std_logic_vector(31 downto 0);  -- Actual target
        resolve_ccr    : in std_logic_vector(7 downto 0);

        -- Misprediction detection (EX stage - combinational)
        mispredict     : out std_logic;           -- Misprediction detected
        correct_target : out std_logic_vector(31 downto 0);  -- Correct target

        -- Prediction from IF (for comparison in EX)
        predicted_taken_if  : in std_logic;
        predicted_target_if : in std_logic_vector(31 downto 0);

        -- Statistics
        branches       : out std_logic_vector(31 downto 0);
        correct_preds  : out std_logic_vector(31 downto 0);
        mispreds       : out std_logic_vector(31 downto 0);
        btb_hits       : out std_logic_vector(31 downto 0);
        btb_misses     : out std_logic_vector(31 downto 0);
        ras_hits_stat  : out std_logic_vector(31 downto 0);
        ras_misses     : out std_logic_vector(31 downto 0)
    );
end TG68040_BranchUnit;

architecture rtl of TG68040_BranchUnit is

    -- BTB signals
    signal btb_lookup_hit    : std_logic;
    signal btb_lookup_target : std_logic_vector(31 downto 0);
    signal btb_lookup_taken  : std_logic;
    signal btb_lookup_type   : branch_type_t;
    signal btb_update_en     : std_logic;
    signal btb_lookups       : std_logic_vector(31 downto 0);
    signal btb_hits_count    : std_logic_vector(31 downto 0);
    signal btb_misses_count  : std_logic_vector(31 downto 0);

    -- RAS signals
    signal ras_push_en       : std_logic;
    signal ras_push_addr     : std_logic_vector(31 downto 0);
    signal ras_pop_en        : std_logic;
    signal ras_pop_addr      : std_logic_vector(31 downto 0);
    signal ras_pop_valid     : std_logic;
    signal ras_repair_en     : std_logic;
    signal ras_repair_tos    : integer range 0 to 7;
    signal ras_pushes        : std_logic_vector(31 downto 0);
    signal ras_pops          : std_logic_vector(31 downto 0);
    signal ras_overflows     : std_logic_vector(31 downto 0);
    signal ras_underflows    : std_logic_vector(31 downto 0);

    -- Internal statistics
    signal stat_branches     : unsigned(31 downto 0) := (others => '0');
    signal stat_correct      : unsigned(31 downto 0) := (others => '0');
    signal stat_mispreds     : unsigned(31 downto 0) := (others => '0');
    signal stat_ras_hits     : unsigned(31 downto 0) := (others => '0');
    signal stat_ras_misses   : unsigned(31 downto 0) := (others => '0');

    -- Prediction state
    signal pred_branch_type  : branch_type_t;
    signal pred_static_taken : std_logic;
    signal pred_displacement : std_logic_vector(31 downto 0);

    -- Components
    component TG68040_BTB is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            lookup_pc      : in std_logic_vector(31 downto 0);
            lookup_hit     : out std_logic;
            lookup_target  : out std_logic_vector(31 downto 0);
            lookup_taken   : out std_logic;
            lookup_type    : out branch_type_t;
            update_en      : in std_logic;
            update_pc      : in std_logic_vector(31 downto 0);
            update_target  : in std_logic_vector(31 downto 0);
            update_taken   : in std_logic;
            update_type    : in branch_type_t;
            lookups        : out std_logic_vector(31 downto 0);
            hits           : out std_logic_vector(31 downto 0);
            misses         : out std_logic_vector(31 downto 0)
        );
    end component;

    component TG68040_RAS is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            push_en        : in std_logic;
            push_addr      : in std_logic_vector(31 downto 0);
            pop_en         : in std_logic;
            pop_addr       : out std_logic_vector(31 downto 0);
            pop_valid      : out std_logic;
            repair_en      : in std_logic;
            repair_tos     : in integer range 0 to 7;
            pushes         : out std_logic_vector(31 downto 0);
            pops           : out std_logic_vector(31 downto 0);
            overflows      : out std_logic_vector(31 downto 0);
            underflows     : out std_logic_vector(31 downto 0)
        );
    end component;

begin

    -- Output statistics
    branches <= std_logic_vector(stat_branches);
    correct_preds <= std_logic_vector(stat_correct);
    mispreds <= std_logic_vector(stat_mispreds);
    btb_hits <= btb_hits_count;
    btb_misses <= btb_misses_count;
    ras_hits_stat <= std_logic_vector(stat_ras_hits);
    ras_misses <= std_logic_vector(stat_ras_misses);

    ------------------------------------------------------------------------------
    -- BTB Instance
    ------------------------------------------------------------------------------
    btb_inst: TG68040_BTB
        port map(
            clk           => clk,
            reset         => reset,
            lookup_pc     => predict_pc,
            lookup_hit    => btb_lookup_hit,
            lookup_target => btb_lookup_target,
            lookup_taken  => btb_lookup_taken,
            lookup_type   => btb_lookup_type,
            update_en     => btb_update_en,
            update_pc     => resolve_pc,
            update_target => resolve_target,
            update_taken  => resolve_taken,
            update_type   => resolve_type,
            lookups       => btb_lookups,
            hits          => btb_hits_count,
            misses        => btb_misses_count
        );

    ------------------------------------------------------------------------------
    -- RAS Instance
    ------------------------------------------------------------------------------
    ras_inst: TG68040_RAS
        port map(
            clk           => clk,
            reset         => reset,
            push_en       => ras_push_en,
            push_addr     => ras_push_addr,
            pop_en        => ras_pop_en,
            pop_addr      => ras_pop_addr,
            pop_valid     => ras_pop_valid,
            repair_en     => ras_repair_en,
            repair_tos    => ras_repair_tos,
            pushes        => ras_pushes,
            pops          => ras_pops,
            overflows     => ras_overflows,
            underflows    => ras_underflows
        );

    ------------------------------------------------------------------------------
    -- Prediction Logic (IF Stage - Combinational)
    ------------------------------------------------------------------------------
    prediction_proc: process(predict_pc, predict_instr, btb_lookup_hit, btb_lookup_taken,
                             btb_lookup_target, btb_lookup_type, ras_pop_valid, ras_pop_addr)
        variable branch_type : branch_type_t;
        variable displacement : std_logic_vector(31 downto 0);
        variable static_taken : std_logic;
    begin
        -- Detect branch type from instruction
        branch_type := decode_branch_type(predict_instr);

        -- Get displacement (using 0 as extension for now - would need more words in real impl)
        displacement := get_branch_displacement(predict_instr, (others => '0'));

        -- Static prediction
        static_taken := predict_branch_taken(branch_type, displacement);

        -- Store for later use
        pred_branch_type <= branch_type;
        pred_static_taken <= static_taken;
        pred_displacement <= displacement;

        -- Default outputs
        predict_valid <= '0';
        predict_taken <= '0';
        predict_target <= (others => '0');
        btb_hit <= '0';
        ras_hit <= '0';
        ras_pop_en <= '0';

        -- Check if this is a branch
        if branch_type /= BRANCH_NONE then
            predict_valid <= '1';

            -- RTS: Use RAS if available
            if branch_type = BRANCH_RTS then
                if ras_pop_valid = '1' then
                    predict_taken <= '1';
                    predict_target <= ras_pop_addr;
                    ras_hit <= '1';
                    ras_pop_en <= '1';
                else
                    -- RAS miss - predict not taken (conservative)
                    predict_taken <= '0';
                    predict_target <= std_logic_vector(unsigned(predict_pc) + 2);
                end if;

            -- BTB hit: Use BTB prediction
            elsif btb_lookup_hit = '1' then
                predict_taken <= btb_lookup_taken;
                predict_target <= btb_lookup_target;
                btb_hit <= '1';

            -- BTB miss: Use static prediction
            else
                predict_taken <= static_taken;
                if static_taken = '1' then
                    predict_target <= calculate_branch_target(predict_pc, displacement, branch_type);
                else
                    predict_target <= std_logic_vector(unsigned(predict_pc) + 2);
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Branch Resolution and Misprediction Detection (EX Stage)
    ------------------------------------------------------------------------------
    resolution_proc: process(clk)
        variable actual_taken : std_logic;
        variable actual_target : std_logic_vector(31 downto 0);
        variable condition_result : std_logic;
        variable branch_condition : branch_condition_t;
        variable is_mispredict : std_logic;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mispredict <= '0';
                correct_target <= (others => '0');
                btb_update_en <= '0';
                ras_push_en <= '0';
                ras_repair_en <= '0';
                stat_branches <= (others => '0');
                stat_correct <= (others => '0');
                stat_mispreds <= (others => '0');
                stat_ras_hits <= (others => '0');
                stat_ras_misses <= (others => '0');

            elsif resolve_en = '1' then
                -- Branch in EX stage - resolve it
                stat_branches <= stat_branches + 1;

                -- Determine actual branch outcome
                if resolve_type = BRANCH_COND or resolve_type = BRANCH_DBCC then
                    -- Conditional branch - evaluate condition
                    branch_condition := decode_branch_condition(resolve_pc & x"0000");  -- Simplified
                    condition_result := evaluate_branch_condition(branch_condition, resolve_ccr);
                    actual_taken := condition_result;
                else
                    -- Unconditional branches always taken
                    actual_taken := '1';
                end if;

                actual_target := resolve_target;

                -- Check for misprediction
                is_mispredict := '0';
                if predicted_taken_if /= actual_taken then
                    -- Direction misprediction
                    is_mispredict := '1';
                elsif actual_taken = '1' and predicted_target_if /= actual_target then
                    -- Target misprediction
                    is_mispredict := '1';
                end if;

                -- Output misprediction
                mispredict <= is_mispredict;

                if is_mispredict = '1' then
                    if actual_taken = '1' then
                        correct_target <= actual_target;
                    else
                        -- Not taken - go to next instruction
                        correct_target <= std_logic_vector(unsigned(resolve_pc) + 2);
                    end if;
                    stat_mispreds <= stat_mispreds + 1;
                else
                    stat_correct <= stat_correct + 1;
                end if;

                -- Update BTB (on all branches)
                btb_update_en <= '1';

                -- Update RAS
                if resolve_type = BRANCH_JSR then
                    -- Push return address
                    ras_push_en <= '1';
                    ras_push_addr <= std_logic_vector(unsigned(resolve_pc) + 2);
                else
                    ras_push_en <= '0';
                end if;

                -- RAS statistics (if this was an RTS)
                if resolve_type = BRANCH_RTS then
                    if is_mispredict = '0' then
                        stat_ras_hits <= stat_ras_hits + 1;
                    else
                        stat_ras_misses <= stat_ras_misses + 1;
                    end if;
                end if;

            else
                -- No branch - reset outputs
                mispredict <= '0';
                btb_update_en <= '0';
                ras_push_en <= '0';
                ras_repair_en <= '0';
            end if;
        end if;
    end process;

end rtl;
