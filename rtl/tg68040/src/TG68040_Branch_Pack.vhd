------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Branch Package (Phase 8)                                        --
--                                                                          --
-- Branch types, prediction, and utility functions                         --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- Branch Handling:
-- - Static branch prediction (backward taken, forward not-taken)
-- - Branch type detection
-- - Branch target calculation
--
-- Version: 1.0 (Phase 8)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package TG68040_Branch_Pack is

    ------------------------------------------------------------------------------
    -- Branch Type Enumeration
    ------------------------------------------------------------------------------
    type branch_type_t is (
        BRANCH_NONE,       -- Not a branch
        BRANCH_COND,       -- Conditional branch (Bcc)
        BRANCH_UNCOND,     -- Unconditional branch (BRA)
        BRANCH_JSR,        -- Jump to subroutine
        BRANCH_RTS,        -- Return from subroutine
        BRANCH_JMP,        -- Jump
        BRANCH_DBCC        -- Decrement and branch
    );

    ------------------------------------------------------------------------------
    -- Branch Condition Codes (for Bcc)
    ------------------------------------------------------------------------------
    type branch_condition_t is (
        COND_T,    -- True (always)
        COND_F,    -- False (never)
        COND_HI,   -- High (unsigned >)
        COND_LS,   -- Low or same (unsigned <=)
        COND_CC,   -- Carry clear (unsigned >=)
        COND_CS,   -- Carry set (unsigned <)
        COND_NE,   -- Not equal
        COND_EQ,   -- Equal
        COND_VC,   -- Overflow clear
        COND_VS,   -- Overflow set
        COND_PL,   -- Plus (positive)
        COND_MI,   -- Minus (negative)
        COND_GE,   -- Greater or equal (signed >=)
        COND_LT,   -- Less than (signed <)
        COND_GT,   -- Greater than (signed >)
        COND_LE    -- Less or equal (signed <=)
    );

    ------------------------------------------------------------------------------
    -- Branch Information Record
    ------------------------------------------------------------------------------
    type branch_info_t is record
        is_branch         : std_logic;                        -- Is this a branch?
        branch_type       : branch_type_t;                    -- Branch type
        condition         : branch_condition_t;               -- Condition code
        displacement      : std_logic_vector(31 downto 0);    -- Branch displacement
        target_addr       : std_logic_vector(31 downto 0);    -- Target address
        predicted_taken   : std_logic;                        -- Static prediction
        predicted_target  : std_logic_vector(31 downto 0);    -- Predicted target
    end record;

    constant BRANCH_INFO_INIT : branch_info_t := (
        is_branch        => '0',
        branch_type      => BRANCH_NONE,
        condition        => COND_F,
        displacement     => (others => '0'),
        target_addr      => (others => '0'),
        predicted_taken  => '0',
        predicted_target => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- Branch Statistics
    ------------------------------------------------------------------------------
    type branch_stats_t is record
        total_branches       : unsigned(31 downto 0);
        taken_branches       : unsigned(31 downto 0);
        not_taken_branches   : unsigned(31 downto 0);
        correct_predictions  : unsigned(31 downto 0);
        incorrect_predictions: unsigned(31 downto 0);
        btb_hits            : unsigned(31 downto 0);
        btb_misses          : unsigned(31 downto 0);
        ras_hits            : unsigned(31 downto 0);
        ras_misses          : unsigned(31 downto 0);
    end record;

    constant BRANCH_STATS_INIT : branch_stats_t := (
        total_branches        => (others => '0'),
        taken_branches        => (others => '0'),
        not_taken_branches    => (others => '0'),
        correct_predictions   => (others => '0'),
        incorrect_predictions => (others => '0'),
        btb_hits             => (others => '0'),
        btb_misses           => (others => '0'),
        ras_hits             => (others => '0'),
        ras_misses           => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- Branch Detection Functions
    ------------------------------------------------------------------------------

    -- Decode branch type from opcode
    function decode_branch_type(
        opcode : std_logic_vector(15 downto 0)
    ) return branch_type_t;

    -- Decode branch condition from opcode
    function decode_branch_condition(
        opcode : std_logic_vector(15 downto 0)
    ) return branch_condition_t;

    -- Extract branch displacement
    function get_branch_displacement(
        opcode : std_logic_vector(15 downto 0);
        extension : std_logic_vector(31 downto 0)
    ) return std_logic_vector;

    -- Calculate branch target address
    function calculate_branch_target(
        pc : std_logic_vector(31 downto 0);
        displacement : std_logic_vector(31 downto 0);
        branch_type : branch_type_t
    ) return std_logic_vector;

    ------------------------------------------------------------------------------
    -- Branch Prediction Functions
    ------------------------------------------------------------------------------

    -- Predict branch direction (static prediction)
    function predict_branch_taken(
        branch_type : branch_type_t;
        displacement : std_logic_vector(31 downto 0)
    ) return std_logic;

    -- Evaluate branch condition
    function evaluate_branch_condition(
        condition : branch_condition_t;
        ccr : std_logic_vector(7 downto 0)
    ) return std_logic;

end package TG68040_Branch_Pack;

package body TG68040_Branch_Pack is

    ------------------------------------------------------------------------------
    -- Decode Branch Type
    ------------------------------------------------------------------------------
    function decode_branch_type(
        opcode : std_logic_vector(15 downto 0)
    ) return branch_type_t is
    begin
        -- Check opcode patterns
        case opcode(15 downto 12) is
            when x"6" =>
                -- Bcc family
                if opcode(11 downto 8) = x"0" and opcode(7 downto 0) = x"00" then
                    return BRANCH_UNCOND;  -- BRA.W (word displacement)
                elsif opcode(11 downto 8) = x"0" and opcode(7 downto 0) = x"FF" then
                    return BRANCH_UNCOND;  -- BRA.L (long displacement)
                elsif opcode(11 downto 8) = x"0" then
                    return BRANCH_UNCOND;  -- BRA.B (byte displacement)
                else
                    return BRANCH_COND;    -- Bcc (conditional)
                end if;

            when x"4" =>
                if opcode(11 downto 6) = "111011" then
                    case opcode(5 downto 0) is
                        when "010001" => return BRANCH_JSR;  -- JSR
                        when "010101" => return BRANCH_RTS;  -- RTS
                        when "011001" => return BRANCH_JMP;  -- JMP
                        when others => return BRANCH_NONE;
                    end case;
                end if;
                return BRANCH_NONE;

            when x"5" =>
                if opcode(11 downto 8) = x"1" then
                    return BRANCH_DBCC;  -- DBcc
                end if;
                return BRANCH_NONE;

            when others =>
                return BRANCH_NONE;
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Decode Branch Condition
    ------------------------------------------------------------------------------
    function decode_branch_condition(
        opcode : std_logic_vector(15 downto 0)
    ) return branch_condition_t is
        variable cond : std_logic_vector(3 downto 0);
    begin
        cond := opcode(11 downto 8);

        case cond is
            when x"0" => return COND_T;   -- True (BRA/BSR)
            when x"1" => return COND_F;   -- False (never)
            when x"2" => return COND_HI;  -- High
            when x"3" => return COND_LS;  -- Low or same
            when x"4" => return COND_CC;  -- Carry clear
            when x"5" => return COND_CS;  -- Carry set
            when x"6" => return COND_NE;  -- Not equal
            when x"7" => return COND_EQ;  -- Equal
            when x"8" => return COND_VC;  -- Overflow clear
            when x"9" => return COND_VS;  -- Overflow set
            when x"A" => return COND_PL;  -- Plus
            when x"B" => return COND_MI;  -- Minus
            when x"C" => return COND_GE;  -- Greater or equal
            when x"D" => return COND_LT;  -- Less than
            when x"E" => return COND_GT;  -- Greater than
            when x"F" => return COND_LE;  -- Less or equal
            when others => return COND_F;
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Get Branch Displacement
    ------------------------------------------------------------------------------
    function get_branch_displacement(
        opcode : std_logic_vector(15 downto 0);
        extension : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable disp : std_logic_vector(31 downto 0);
    begin
        if opcode(7 downto 0) = x"00" then
            -- 16-bit displacement (word)
            if extension(15) = '1' then
                disp := x"FFFF" & extension(15 downto 0);  -- Sign extend
            else
                disp := x"0000" & extension(15 downto 0);
            end if;
        elsif opcode(7 downto 0) = x"FF" then
            -- 32-bit displacement (long)
            disp := extension;
        else
            -- 8-bit displacement (byte)
            if opcode(7) = '1' then
                disp := x"FFFFFF" & opcode(7 downto 0);  -- Sign extend
            else
                disp := x"000000" & opcode(7 downto 0);
            end if;
        end if;

        return disp;
    end function;

    ------------------------------------------------------------------------------
    -- Calculate Branch Target
    ------------------------------------------------------------------------------
    function calculate_branch_target(
        pc : std_logic_vector(31 downto 0);
        displacement : std_logic_vector(31 downto 0);
        branch_type : branch_type_t
    ) return std_logic_vector is
        variable target : std_logic_vector(31 downto 0);
    begin
        case branch_type is
            when BRANCH_COND | BRANCH_UNCOND | BRANCH_DBCC =>
                -- PC-relative: target = PC + 2 + displacement
                target := std_logic_vector(unsigned(pc) + 2 + unsigned(displacement));

            when BRANCH_JSR | BRANCH_JMP =>
                -- Absolute or address register indirect (simplified)
                target := displacement;

            when BRANCH_RTS =>
                -- Return address (from stack/RAS)
                target := (others => '0');  -- Will be filled by RAS

            when others =>
                target := pc;  -- Sequential
        end case;

        return target;
    end function;

    ------------------------------------------------------------------------------
    -- Static Branch Prediction
    ------------------------------------------------------------------------------
    function predict_branch_taken(
        branch_type : branch_type_t;
        displacement : std_logic_vector(31 downto 0)
    ) return std_logic is
    begin
        case branch_type is
            when BRANCH_UNCOND | BRANCH_JSR | BRANCH_JMP =>
                return '1';  -- Always taken

            when BRANCH_RTS =>
                return '1';  -- Predict taken (RAS provides target)

            when BRANCH_COND | BRANCH_DBCC =>
                -- Static prediction based on displacement sign
                if displacement(31) = '1' then
                    return '1';  -- Backward branch: predict taken (loops)
                else
                    return '0';  -- Forward branch: predict not-taken (if-then)
                end if;

            when others =>
                return '0';  -- Not a branch
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Evaluate Branch Condition
    ------------------------------------------------------------------------------
    function evaluate_branch_condition(
        condition : branch_condition_t;
        ccr : std_logic_vector(7 downto 0)
    ) return std_logic is
        variable C : std_logic;  -- Carry
        variable V : std_logic;  -- Overflow
        variable Z : std_logic;  -- Zero
        variable N : std_logic;  -- Negative
    begin
        -- Extract condition code flags
        C := ccr(0);
        V := ccr(1);
        Z := ccr(2);
        N := ccr(3);

        case condition is
            when COND_T  => return '1';                      -- Always true
            when COND_F  => return '0';                      -- Always false
            when COND_HI => return not C and not Z;          -- High
            when COND_LS => return C or Z;                   -- Low or same
            when COND_CC => return not C;                    -- Carry clear
            when COND_CS => return C;                        -- Carry set
            when COND_NE => return not Z;                    -- Not equal
            when COND_EQ => return Z;                        -- Equal
            when COND_VC => return not V;                    -- Overflow clear
            when COND_VS => return V;                        -- Overflow set
            when COND_PL => return not N;                    -- Plus
            when COND_MI => return N;                        -- Minus
            when COND_GE => return (N and V) or (not N and not V);  -- >=
            when COND_LT => return (N and not V) or (not N and V);  -- <
            when COND_GT => return (N and V and not Z) or (not N and not V and not Z);  -- >
            when COND_LE => return Z or (N and not V) or (not N and V);  -- <=
            when others => return '0';
        end case;
    end function;

end package body TG68040_Branch_Pack;
