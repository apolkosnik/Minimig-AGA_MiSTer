------------------------------------------------------------------------------
-- TG68040 Floating Point Multiplier
--
-- 3-stage pipelined FP multiplication
-- Stage 1: Unpack and classify operands
-- Stage 2: Multiply mantissas, add exponents
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

entity TG68040_FPU_Mul is
    port(
        -- Clock and reset
        clk         : in std_logic;
        reset       : in std_logic;

        -- Control
        enable      : in std_logic;                     -- Enable pipeline

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
end TG68040_FPU_Mul;

architecture rtl of TG68040_FPU_Mul is

    -- Pipeline stage 1: Unpack and classify
    type stage1_t is record
        valid          : std_logic;
        fp_a           : fp_extended_t;
        fp_b           : fp_extended_t;
        class_a        : fp_class_t;
        class_b        : fp_class_t;
        rounding       : fp_rounding_t;
        special_result : fp_extended_t;
        is_special     : std_logic;
    end record;

    constant STAGE1_INIT : stage1_t := (
        valid          => '0',
        fp_a           => FP_EXTENDED_ZERO,
        fp_b           => FP_EXTENDED_ZERO,
        class_a        => FP_ZERO,
        class_b        => FP_ZERO,
        rounding       => ROUND_NEAREST,
        special_result => FP_EXTENDED_ZERO,
        is_special     => '0'
    );

    -- Pipeline stage 2: Multiply mantissas
    type stage2_t is record
        valid          : std_logic;
        result_sign    : std_logic;
        result_exp     : signed(16 downto 0);  -- Extra bit for overflow
        mantissa_product : unsigned(127 downto 0);  -- 64-bit x 64-bit product
        rounding       : fp_rounding_t;
        is_special     : std_logic;
        special_result : fp_extended_t;
    end record;

    constant STAGE2_INIT : stage2_t := (
        valid          => '0',
        result_sign    => '0',
        result_exp     => (others => '0'),
        mantissa_product => (others => '0'),
        rounding       => ROUND_NEAREST,
        is_special     => '0',
        special_result => FP_EXTENDED_ZERO
    );

    -- Pipeline registers
    signal s1 : stage1_t := STAGE1_INIT;
    signal s2 : stage2_t := STAGE2_INIT;

    -- Exception flags
    signal exception_flags : fp_exception_t := FP_EXCEPTION_NONE;

    -- Extended precision exponent bias
    constant EXP_BIAS : signed(16 downto 0) := to_signed(16383, 17);

begin

    ------------------------------------------------------------------------------
    -- Stage 1: Unpack and classify operands
    ------------------------------------------------------------------------------
    stage1_proc: process(clk)
        variable fp_a_var : fp_extended_t;
        variable fp_b_var : fp_extended_t;
        variable class_a_var : fp_class_t;
        variable class_b_var : fp_class_t;
        variable result_sign_var : std_logic;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                s1 <= STAGE1_INIT;

            elsif enable = '1' then
                s1.valid <= '1';
                s1.rounding <= rounding;

                -- Unpack operands
                fp_a_var := unpack_fp_extended(operand_a);
                fp_b_var := unpack_fp_extended(operand_b);

                s1.fp_a <= fp_a_var;
                s1.fp_b <= fp_b_var;

                -- Result sign is XOR of operand signs
                result_sign_var := fp_a_var.sign xor fp_b_var.sign;

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

                -- Check for infinity × zero = NaN (invalid operation)
                elsif (class_a_var = FP_INFINITY and class_b_var = FP_ZERO) or
                      (class_a_var = FP_ZERO and class_b_var = FP_INFINITY) then
                    s1.special_result <= create_fp_nan(false);
                    s1.is_special <= '1';

                -- Check for infinity (inf × finite = inf)
                elsif class_a_var = FP_INFINITY or class_b_var = FP_INFINITY then
                    s1.special_result <= create_fp_inf(result_sign_var);
                    s1.is_special <= '1';

                -- Check for zero (0 × anything = 0)
                elsif class_a_var = FP_ZERO or class_b_var = FP_ZERO then
                    s1.special_result <= create_fp_zero(result_sign_var);
                    s1.is_special <= '1';
                end if;

            else
                s1.valid <= '0';
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Stage 2: Multiply mantissas and add exponents
    ------------------------------------------------------------------------------
    stage2_proc: process(clk)
        variable mantissa_a : unsigned(63 downto 0);
        variable mantissa_b : unsigned(63 downto 0);
        variable product : unsigned(127 downto 0);
        variable exp_a : signed(16 downto 0);
        variable exp_b : signed(16 downto 0);
        variable exp_sum : signed(16 downto 0);
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
                    s2.result_exp <= (others => '0');
                    s2.mantissa_product <= (others => '0');
                else
                    -- Calculate result sign
                    s2.result_sign <= s1.fp_a.sign xor s1.fp_b.sign;

                    -- Multiply mantissas (64-bit x 64-bit = 128-bit)
                    -- Include integer bit in mantissa
                    mantissa_a := unsigned(s1.fp_a.integer_bit & s1.fp_a.mantissa);
                    mantissa_b := unsigned(s1.fp_b.integer_bit & s1.fp_b.mantissa);
                    product := mantissa_a * mantissa_b;
                    s2.mantissa_product <= product;

                    -- Add exponents and subtract bias
                    -- result_exp = exp_a + exp_b - bias
                    exp_a := signed('0' & '0' & s1.fp_a.exponent);
                    exp_b := signed('0' & '0' & s1.fp_b.exponent);
                    exp_sum := exp_a + exp_b - EXP_BIAS;
                    s2.result_exp <= exp_sum;
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
        variable rounded_fp : fp_extended_t;
        variable guard, round_bit, sticky : std_logic;
        variable exp_adjust : signed(16 downto 0);
        variable normalized_exp : signed(16 downto 0);
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
                    -- Build result
                    result_fp.sign := s2.result_sign;

                    -- Normalize: product is 128 bits, we need top 64 bits + rounding bits
                    -- Product bit 127 is the MSB (should be 0 or 1)
                    -- Product bit 126 is next bit (integer bit position)
                    -- If bit 127 is 1, we have overflow and need to shift right
                    -- If bit 126 is 1, we're normalized
                    -- If bit 126 is 0, we need to shift left (shouldn't happen with normalized inputs)

                    if s2.mantissa_product(127) = '1' then
                        -- Overflow: shift right by 1, increment exponent
                        result_fp.integer_bit := '1';
                        result_fp.mantissa := std_logic_vector(s2.mantissa_product(126 downto 64));
                        guard := s2.mantissa_product(63);
                        round_bit := s2.mantissa_product(62);
                        -- Sticky bit is OR of all lower bits
                        if s2.mantissa_product(61 downto 0) /= 0 then
                            sticky := '1';
                        else
                            sticky := '0';
                        end if;
                        exp_adjust := to_signed(1, 17);

                    elsif s2.mantissa_product(126) = '1' then
                        -- Already normalized
                        result_fp.integer_bit := '1';
                        result_fp.mantissa := std_logic_vector(s2.mantissa_product(125 downto 63));
                        guard := s2.mantissa_product(62);
                        round_bit := s2.mantissa_product(61);
                        -- Sticky bit is OR of all lower bits
                        if s2.mantissa_product(60 downto 0) /= 0 then
                            sticky := '1';
                        else
                            sticky := '0';
                        end if;
                        exp_adjust := to_signed(0, 17);

                    else
                        -- Product is less than 1.0 (shouldn't happen with normalized inputs)
                        -- Shift left by 1, decrement exponent
                        result_fp.integer_bit := s2.mantissa_product(125);
                        result_fp.mantissa := std_logic_vector(s2.mantissa_product(124 downto 62));
                        guard := s2.mantissa_product(61);
                        round_bit := s2.mantissa_product(60);
                        if s2.mantissa_product(59 downto 0) /= 0 then
                            sticky := '1';
                        else
                            sticky := '0';
                        end if;
                        exp_adjust := to_signed(-1, 17);
                    end if;

                    -- Adjust exponent
                    normalized_exp := s2.result_exp + exp_adjust;

                    -- Check for overflow (result too large)
                    if normalized_exp > to_signed(32766, 17) then
                        -- Overflow: return infinity
                        result <= pack_fp_extended(create_fp_inf(s2.result_sign));
                        exception_flags.overflow <= '1';
                        exception_flags.inexact <= '1';

                    -- Check for underflow (result too small)
                    elsif normalized_exp < to_signed(0, 17) then
                        -- Underflow: return zero (denormals not supported yet)
                        result <= pack_fp_extended(create_fp_zero(s2.result_sign));
                        exception_flags.underflow <= '1';
                        exception_flags.inexact <= '1';

                    else
                        -- Normal result
                        result_fp.exponent := std_logic_vector(normalized_exp(14 downto 0));

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
