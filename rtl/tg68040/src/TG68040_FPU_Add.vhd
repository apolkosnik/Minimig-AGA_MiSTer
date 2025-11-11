------------------------------------------------------------------------------
-- TG68040 Floating Point Adder/Subtractor
--
-- 3-stage pipelined FP addition and subtraction
-- Stage 1: Align operands
-- Stage 2: Add/subtract mantissas
-- Stage 3: Normalize and round
--
-- Copyright (c) 2025 Claude AI (Anthropic)
-- Based on MC68040 User's Manual
--
-- LGPL v3
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_FPU_Pack.all;

entity TG68040_FPU_Add is
    port(
        -- Clock and reset
        clk         : in std_logic;
        reset       : in std_logic;

        -- Control
        enable      : in std_logic;                     -- Enable pipeline
        operation   : in std_logic;                     -- '0' = ADD, '1' = SUB

        -- Operands (extended precision)
        operand_a   : in std_logic_vector(79 downto 0); -- First operand
        operand_b   : in std_logic_vector(79 downto 0); -- Second operand

        -- Rounding mode
        rounding    : in fp_rounding_t;                 -- Rounding mode

        -- Result (extended precision)
        result      : out std_logic_vector(79 downto 0); -- Result
        result_valid : out std_logic;                   -- Result valid (after 3 cycles)

        -- Exceptions
        exception   : out fp_exception_t                -- Exception flags
    );
end TG68040_FPU_Add;

architecture rtl of TG68040_FPU_Add is

    -- Pipeline stage 1: Alignment
    type stage1_t is record
        valid          : std_logic;
        operation      : std_logic;
        fp_a           : fp_extended_t;
        fp_b           : fp_extended_t;
        class_a        : fp_class_t;
        class_b        : fp_class_t;
        exp_diff       : signed(15 downto 0);
        larger_exp     : std_logic_vector(14 downto 0);
        rounding       : fp_rounding_t;
        special_result : fp_extended_t;
        is_special     : std_logic;
    end record;

    constant STAGE1_INIT : stage1_t := (
        valid          => '0',
        operation      => '0',
        fp_a           => FP_EXTENDED_ZERO,
        fp_b           => FP_EXTENDED_ZERO,
        class_a        => FP_ZERO,
        class_b        => FP_ZERO,
        exp_diff       => (others => '0'),
        larger_exp     => (others => '0'),
        rounding       => ROUND_NEAREST,
        special_result => FP_EXTENDED_ZERO,
        is_special     => '0'
    );

    -- Pipeline stage 2: Add/subtract
    type stage2_t is record
        valid          : std_logic;
        result_sign    : std_logic;
        result_exp     : std_logic_vector(14 downto 0);
        mantissa_sum   : unsigned(65 downto 0);  -- Extra bits for carry and rounding
        rounding       : fp_rounding_t;
        is_special     : std_logic;
        special_result : fp_extended_t;
    end record;

    constant STAGE2_INIT : stage2_t := (
        valid          => '0',
        result_sign    => '0',
        result_exp     => (others => '0'),
        mantissa_sum   => (others => '0'),
        rounding       => ROUND_NEAREST,
        is_special     => '0',
        special_result => FP_EXTENDED_ZERO
    );

    -- Pipeline registers
    signal s1 : stage1_t := STAGE1_INIT;
    signal s2 : stage2_t := STAGE2_INIT;

    -- Exception flags
    signal exception_flags : fp_exception_t := FP_EXCEPTION_NONE;

begin

    ------------------------------------------------------------------------------
    -- Stage 1: Unpack and align operands
    ------------------------------------------------------------------------------
    stage1_proc: process(clk)
        variable fp_a_var : fp_extended_t;
        variable fp_b_var : fp_extended_t;
        variable class_a_var : fp_class_t;
        variable class_b_var : fp_class_t;
        variable exp_a : signed(15 downto 0);
        variable exp_b : signed(15 downto 0);
        variable exp_diff_var : signed(15 downto 0);
        variable effective_op : std_logic;  -- Effective operation: '0' = add, '1' = sub
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1 <= STAGE1_INIT;

            elsif enable = '1' then
                s1.valid <= '1';
                s1.operation <= operation;
                s1.rounding <= rounding;

                -- Unpack operands
                fp_a_var := unpack_fp_extended(operand_a);
                fp_b_var := unpack_fp_extended(operand_b);

                -- For subtraction, negate operand B
                if operation = '1' then
                    fp_b_var.sign := not fp_b_var.sign;
                end if;

                s1.fp_a <= fp_a_var;
                s1.fp_b <= fp_b_var;

                -- Classify operands
                class_a_var := classify_fp(fp_a_var);
                class_b_var := classify_fp(fp_b_var);
                s1.class_a <= class_a_var;
                s1.class_b <= class_b_var;

                -- Handle special cases
                s1.is_special <= '0';

                -- Check for NaN
                if class_a_var = FP_QNAN or class_a_var = FP_SNAN then
                    s1.special_result <= fp_a_var;
                    s1.is_special <= '1';
                elsif class_b_var = FP_QNAN or class_b_var = FP_SNAN then
                    s1.special_result <= fp_b_var;
                    s1.is_special <= '1';

                -- Check for infinity
                elsif class_a_var = FP_INFINITY and class_b_var = FP_INFINITY then
                    if fp_a_var.sign = fp_b_var.sign then
                        -- Same sign: inf + inf = inf
                        s1.special_result <= fp_a_var;
                        s1.is_special <= '1';
                    else
                        -- Different signs: inf - inf = NaN (invalid)
                        s1.special_result <= create_fp_nan(false);
                        s1.is_special <= '1';
                    end if;
                elsif class_a_var = FP_INFINITY then
                    s1.special_result <= fp_a_var;
                    s1.is_special <= '1';
                elsif class_b_var = FP_INFINITY then
                    s1.special_result <= fp_b_var;
                    s1.is_special <= '1';

                -- Check for zero
                elsif class_a_var = FP_ZERO and class_b_var = FP_ZERO then
                    -- Both zero: result is zero with sign based on rounding mode
                    if fp_a_var.sign = fp_b_var.sign then
                        s1.special_result <= create_fp_zero(fp_a_var.sign);
                    else
                        -- +0 - 0 or -0 + 0: result is +0 (except round toward -inf)
                        if rounding = ROUND_MINUS_INF then
                            s1.special_result <= create_fp_zero('1');
                        else
                            s1.special_result <= create_fp_zero('0');
                        end if;
                    end if;
                    s1.is_special <= '1';
                elsif class_a_var = FP_ZERO then
                    s1.special_result <= fp_b_var;
                    s1.is_special <= '1';
                elsif class_b_var = FP_ZERO then
                    s1.special_result <= fp_a_var;
                    s1.is_special <= '1';
                end if;

                -- Calculate exponent difference for alignment
                exp_a := signed('0' & fp_a_var.exponent);
                exp_b := signed('0' & fp_b_var.exponent);
                exp_diff_var := exp_a - exp_b;
                s1.exp_diff <= exp_diff_var;

                -- Determine larger exponent
                if exp_diff_var >= 0 then
                    s1.larger_exp <= fp_a_var.exponent;
                else
                    s1.larger_exp <= fp_b_var.exponent;
                end if;

            else
                s1.valid <= '0';
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Stage 2: Add or subtract aligned mantissas
    ------------------------------------------------------------------------------
    stage2_proc: process(clk)
        variable mantissa_a : unsigned(65 downto 0);
        variable mantissa_b : unsigned(65 downto 0);
        variable mantissa_sum_var : unsigned(65 downto 0);
        variable effective_sub : boolean;
        variable shift_amount : natural;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s2 <= STAGE2_INIT;

            elsif s1.valid = '1' then
                s2.valid <= '1';
                s2.rounding <= s1.rounding;
                s2.is_special <= s1.is_special;
                s2.special_result <= s1.special_result;

                -- Pass through special cases
                if s1.is_special = '1' then
                    s2.result_sign <= s1.special_result.sign;
                    s2.result_exp <= s1.special_result.exponent;
                    s2.mantissa_sum <= (others => '0');
                else
                    -- Align mantissas based on exponent difference
                    -- Add guard, round, and sticky bits (3 extra bits)
                    mantissa_a := unsigned(s1.fp_a.integer_bit & s1.fp_a.mantissa & "00");
                    mantissa_b := unsigned(s1.fp_b.integer_bit & s1.fp_b.mantissa & "00");

                    -- Shift smaller mantissa right
                    if s1.exp_diff > 0 then
                        -- A is larger, shift B right
                        shift_amount := to_integer(s1.exp_diff);
                        if shift_amount > 65 then
                            shift_amount := 65;
                        end if;
                        mantissa_b := shift_right(mantissa_b, shift_amount);
                    elsif s1.exp_diff < 0 then
                        -- B is larger, shift A right
                        shift_amount := to_integer(-s1.exp_diff);
                        if shift_amount > 65 then
                            shift_amount := 65;
                        end if;
                        mantissa_a := shift_right(mantissa_a, shift_amount);
                    end if;

                    -- Determine effective operation
                    effective_sub := (s1.fp_a.sign /= s1.fp_b.sign);

                    if effective_sub then
                        -- Effective subtraction
                        if mantissa_a >= mantissa_b then
                            mantissa_sum_var := mantissa_a - mantissa_b;
                            s2.result_sign <= s1.fp_a.sign;
                        else
                            mantissa_sum_var := mantissa_b - mantissa_a;
                            s2.result_sign <= s1.fp_b.sign;
                        end if;
                    else
                        -- Effective addition
                        mantissa_sum_var := mantissa_a + mantissa_b;
                        s2.result_sign <= s1.fp_a.sign;
                    end if;

                    s2.mantissa_sum <= mantissa_sum_var;
                    s2.result_exp <= s1.larger_exp;
                end if;

            else
                s2.valid <= '0';
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Stage 3: Normalize and round result
    ------------------------------------------------------------------------------
    stage3_proc: process(clk)
        variable result_fp : fp_extended_t;
        variable normalized_fp : fp_extended_t;
        variable rounded_fp : fp_extended_t;
        variable guard, round_bit, sticky : std_logic;
        variable leading_zeros : natural;
        variable exp_adjust : signed(15 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                result_valid <= '0';
                result <= (others => '0');
                exception_flags <= FP_EXCEPTION_NONE;

            elsif s2.valid = '1' then
                result_valid <= '1';
                exception_flags <= FP_EXCEPTION_NONE;

                -- Handle special cases
                if s2.is_special = '1' then
                    result <= pack_fp_extended(s2.special_result);
                else
                    -- Check for zero result
                    if s2.mantissa_sum = 0 then
                        result <= pack_fp_extended(create_fp_zero(s2.result_sign));
                    else
                        -- Build result
                        result_fp.sign := s2.result_sign;
                        result_fp.exponent := s2.result_exp;

                        -- Normalize: find leading 1
                        if s2.mantissa_sum(65) = '1' then
                            -- Overflow (carry out): shift right, increment exponent
                            result_fp.integer_bit := '1';
                            result_fp.mantissa := std_logic_vector(s2.mantissa_sum(64 downto 2));
                            guard := s2.mantissa_sum(1);
                            round_bit := s2.mantissa_sum(0);
                            sticky := '0';
                            exp_adjust := to_signed(1, 16);
                        elsif s2.mantissa_sum(64) = '1' then
                            -- Already normalized
                            result_fp.integer_bit := '1';
                            result_fp.mantissa := std_logic_vector(s2.mantissa_sum(63 downto 1));
                            guard := s2.mantissa_sum(0);
                            round_bit := '0';
                            sticky := '0';
                            exp_adjust := to_signed(0, 16);
                        else
                            -- Need to shift left to normalize
                            leading_zeros := 0;
                            for i in 63 downto 0 loop
                                if s2.mantissa_sum(i) = '1' then
                                    leading_zeros := 63 - i;
                                    exit;
                                end if;
                            end loop;

                            if leading_zeros > 63 then
                                -- All zeros (shouldn't happen)
                                result <= pack_fp_extended(create_fp_zero(s2.result_sign));
                                result_valid <= '1';
                                return;
                            end if;

                            -- Shift left to normalize
                            result_fp.integer_bit := '1';
                            result_fp.mantissa := std_logic_vector(
                                shift_left(s2.mantissa_sum(63 downto 1), leading_zeros)(62 downto 0)
                            );
                            guard := '0';
                            round_bit := '0';
                            sticky := '0';
                            exp_adjust := to_signed(-leading_zeros - 1, 16);
                        end if;

                        -- Adjust exponent
                        result_fp.exponent := std_logic_vector(
                            signed('0' & s2.result_exp) + exp_adjust
                        );

                        -- Apply rounding
                        rounded_fp := round_fp(result_fp, guard, round_bit, sticky, s2.rounding);

                        -- Check for inexact
                        if guard = '1' or round_bit = '1' or sticky = '1' then
                            exception_flags.inexact <= '1';
                        end if;

                        result <= pack_fp_extended(rounded_fp);
                    end if;
                end if;

            else
                result_valid <= '0';
            end if;
        end if;
    end process;

    -- Output exception flags
    exception <= exception_flags;

end rtl;
