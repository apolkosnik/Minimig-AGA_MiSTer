------------------------------------------------------------------------------
-- TG68040 Floating Point Unit Package
--
-- Defines types and utility functions for IEEE 754 floating-point arithmetic
--
-- Copyright (c) 2025 Claude AI (Anthropic)
-- Based on MC68040 User's Manual, Chapter 3
--
-- LGPL v3
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package TG68040_FPU_Pack is

    ------------------------------------------------------------------------------
    -- FP Data Formats
    ------------------------------------------------------------------------------

    -- Extended Precision (80-bit) - Internal format
    -- Bit 79: Sign (S)
    -- Bits 78-64: Exponent (15 bits, biased by 16383)
    -- Bit 63: Integer bit (J) - explicit in extended precision
    -- Bits 62-0: Mantissa/Fraction (63 bits)
    type fp_extended_t is record
        sign        : std_logic;                       -- Sign bit
        exponent    : std_logic_vector(14 downto 0);   -- 15-bit exponent (biased by 16383)
        integer_bit : std_logic;                       -- Explicit integer bit (J)
        mantissa    : std_logic_vector(62 downto 0);   -- 63-bit mantissa
    end record;

    constant FP_EXTENDED_ZERO : fp_extended_t := (
        sign        => '0',
        exponent    => (others => '0'),
        integer_bit => '0',
        mantissa    => (others => '0')
    );

    -- FP number classification
    type fp_class_t is (
        FP_ZERO,           -- Zero (+0 or -0)
        FP_DENORMAL,       -- Denormalized number
        FP_NORMAL,         -- Normal number
        FP_INFINITY,       -- Infinity (+∞ or -∞)
        FP_QNAN,           -- Quiet NaN
        FP_SNAN            -- Signaling NaN
    );

    ------------------------------------------------------------------------------
    -- FP Exception Flags
    ------------------------------------------------------------------------------

    type fp_exception_t is record
        inexact        : std_logic;  -- Inexact result
        divide_by_zero : std_logic;  -- Division by zero
        underflow      : std_logic;  -- Underflow
        overflow       : std_logic;  -- Overflow
        invalid_op     : std_logic;  -- Invalid operation (NaN)
        denormal_input : std_logic;  -- Denormalized input
    end record;

    constant FP_EXCEPTION_NONE : fp_exception_t := (
        inexact        => '0',
        divide_by_zero => '0',
        underflow      => '0',
        overflow       => '0',
        invalid_op     => '0',
        denormal_input => '0'
    );

    ------------------------------------------------------------------------------
    -- FP Rounding Modes
    ------------------------------------------------------------------------------

    type fp_rounding_t is (
        ROUND_NEAREST,     -- Round to nearest (default)
        ROUND_ZERO,        -- Round toward zero (truncate)
        ROUND_PLUS_INF,    -- Round toward +infinity
        ROUND_MINUS_INF    -- Round toward -infinity
    );

    ------------------------------------------------------------------------------
    -- FP Control/Status Registers
    ------------------------------------------------------------------------------

    -- FPSR Status Register
    type fpsr_register_t is record
        exception_status  : fp_exception_t;              -- Exception status bits
        accrued_exception : fp_exception_t;              -- Accrued exceptions
        quotient          : std_logic_vector(6 downto 0); -- Quotient bits (for FMOD)
        condition_n       : std_logic;                   -- Negative
        condition_z       : std_logic;                   -- Zero
        condition_i       : std_logic;                   -- Infinity
        condition_nan     : std_logic;                   -- NaN
    end record;

    constant FPSR_REGISTER_INIT : fpsr_register_t := (
        exception_status  => FP_EXCEPTION_NONE,
        accrued_exception => FP_EXCEPTION_NONE,
        quotient          => (others => '0'),
        condition_n       => '0',
        condition_z       => '0',
        condition_i       => '0',
        condition_nan     => '0'
    );

    -- FPCR Control Register
    type fpcr_register_t is record
        rounding_mode      : fp_rounding_t;               -- Rounding mode
        rounding_precision : std_logic_vector(1 downto 0); -- 00=ext, 01=single, 10=double
        exception_enable   : fp_exception_t;              -- Exception enable bits
    end record;

    constant FPCR_REGISTER_INIT : fpcr_register_t := (
        rounding_mode      => ROUND_NEAREST,
        rounding_precision => "00",  -- Extended precision
        exception_enable   => FP_EXCEPTION_NONE
    );

    ------------------------------------------------------------------------------
    -- FP Operations
    ------------------------------------------------------------------------------

    type fp_operation_t is (
        FP_OP_NOP,
        FP_OP_ADD,
        FP_OP_SUB,
        FP_OP_MUL,
        FP_OP_DIV,
        FP_OP_SQRT,
        FP_OP_ABS,
        FP_OP_NEG,
        FP_OP_MOVE,
        FP_OP_CMP,
        FP_OP_TST
    );

    ------------------------------------------------------------------------------
    -- Utility Functions
    ------------------------------------------------------------------------------

    -- Pack extended precision to 80-bit std_logic_vector
    function pack_fp_extended(fp : fp_extended_t) return std_logic_vector;

    -- Unpack 80-bit std_logic_vector to extended precision
    function unpack_fp_extended(data : std_logic_vector(79 downto 0)) return fp_extended_t;

    -- Convert single precision (32-bit) to extended precision
    function single_to_extended(data : std_logic_vector(31 downto 0)) return fp_extended_t;

    -- Convert double precision (64-bit) to extended precision
    function double_to_extended(data : std_logic_vector(63 downto 0)) return fp_extended_t;

    -- Convert extended precision to single precision (32-bit)
    function extended_to_single(fp : fp_extended_t; rounding : fp_rounding_t) return std_logic_vector;

    -- Convert extended precision to double precision (64-bit)
    function extended_to_double(fp : fp_extended_t; rounding : fp_rounding_t) return std_logic_vector;

    -- Classify FP number
    function classify_fp(fp : fp_extended_t) return fp_class_t;

    -- Check if FP number is zero
    function is_fp_zero(fp : fp_extended_t) return boolean;

    -- Check if FP number is NaN
    function is_fp_nan(fp : fp_extended_t) return boolean;

    -- Check if FP number is infinity
    function is_fp_inf(fp : fp_extended_t) return boolean;

    -- Check if FP number is denormalized
    function is_fp_denormal(fp : fp_extended_t) return boolean;

    -- Normalize FP number (find leading one, shift mantissa, adjust exponent)
    function normalize_fp(fp : fp_extended_t) return fp_extended_t;

    -- Count leading zeros in mantissa
    function count_leading_zeros(mantissa : std_logic_vector(62 downto 0)) return natural;

    -- Apply rounding to FP result
    -- guard, round_bit, sticky are the extra precision bits below mantissa
    function round_fp(
        fp        : fp_extended_t;
        guard     : std_logic;
        round_bit : std_logic;
        sticky    : std_logic;
        mode      : fp_rounding_t
    ) return fp_extended_t;

    -- Create FP NaN (Not a Number)
    function create_fp_nan(signaling : boolean) return fp_extended_t;

    -- Create FP infinity
    function create_fp_inf(sign : std_logic) return fp_extended_t;

    -- Create FP zero
    function create_fp_zero(sign : std_logic) return fp_extended_t;

end package TG68040_FPU_Pack;

package body TG68040_FPU_Pack is

    ------------------------------------------------------------------------------
    -- Pack extended precision to 80-bit std_logic_vector
    ------------------------------------------------------------------------------
    function pack_fp_extended(fp : fp_extended_t) return std_logic_vector is
        variable result : std_logic_vector(79 downto 0);
    begin
        result(79) := fp.sign;
        result(78 downto 64) := fp.exponent;
        result(63) := fp.integer_bit;
        result(62 downto 0) := fp.mantissa;
        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Unpack 80-bit std_logic_vector to extended precision
    ------------------------------------------------------------------------------
    function unpack_fp_extended(data : std_logic_vector(79 downto 0)) return fp_extended_t is
        variable result : fp_extended_t;
    begin
        result.sign := data(79);
        result.exponent := data(78 downto 64);
        result.integer_bit := data(63);
        result.mantissa := data(62 downto 0);
        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Convert single precision to extended precision
    ------------------------------------------------------------------------------
    function single_to_extended(data : std_logic_vector(31 downto 0)) return fp_extended_t is
        variable result : fp_extended_t;
        variable exp_single : unsigned(7 downto 0);
        variable exp_extended : unsigned(14 downto 0);
    begin
        result.sign := data(31);
        exp_single := unsigned(data(30 downto 23));

        -- Check for special values
        if exp_single = x"00" then
            -- Zero or denormalized
            result.exponent := (others => '0');
            result.integer_bit := '0';
            result.mantissa := data(22 downto 0) & x"000000000" & '0';
        elsif exp_single = x"FF" then
            -- Infinity or NaN
            result.exponent := (others => '1');
            result.integer_bit := '1';
            result.mantissa := data(22 downto 0) & x"000000000" & '0';
        else
            -- Normal number
            -- Convert exponent: bias_single = 127, bias_extended = 16383
            -- exp_extended = exp_single - 127 + 16383 = exp_single + 16256
            exp_extended := exp_single + to_unsigned(16256, 15);
            result.exponent := std_logic_vector(exp_extended);
            result.integer_bit := '1';  -- Implicit integer bit becomes explicit
            result.mantissa := data(22 downto 0) & x"000000000" & '0';
        end if;

        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Convert double precision to extended precision
    ------------------------------------------------------------------------------
    function double_to_extended(data : std_logic_vector(63 downto 0)) return fp_extended_t is
        variable result : fp_extended_t;
        variable exp_double : unsigned(10 downto 0);
        variable exp_extended : unsigned(14 downto 0);
    begin
        result.sign := data(63);
        exp_double := unsigned(data(62 downto 52));

        -- Check for special values
        if exp_double = "00000000000" then
            -- Zero or denormalized
            result.exponent := (others => '0');
            result.integer_bit := '0';
            result.mantissa := data(51 downto 0) & "00000000000";
        elsif exp_double = "11111111111" then
            -- Infinity or NaN
            result.exponent := (others => '1');
            result.integer_bit := '1';
            result.mantissa := data(51 downto 0) & "00000000000";
        else
            -- Normal number
            -- Convert exponent: bias_double = 1023, bias_extended = 16383
            -- exp_extended = exp_double - 1023 + 16383 = exp_double + 15360
            exp_extended := exp_double + to_unsigned(15360, 15);
            result.exponent := std_logic_vector(exp_extended);
            result.integer_bit := '1';  -- Implicit integer bit becomes explicit
            result.mantissa := data(51 downto 0) & "00000000000";
        end if;

        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Convert extended precision to single precision
    ------------------------------------------------------------------------------
    function extended_to_single(fp : fp_extended_t; rounding : fp_rounding_t) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
        variable exp_extended : unsigned(14 downto 0);
        variable exp_single : unsigned(7 downto 0);
        variable mantissa_rounded : std_logic_vector(22 downto 0);
    begin
        result(31) := fp.sign;
        exp_extended := unsigned(fp.exponent);

        -- Check for special values
        if exp_extended = "000000000000000" then
            -- Zero or denormalized
            result(30 downto 0) := (others => '0');
        elsif exp_extended = "111111111111111" then
            -- Infinity or NaN
            result(30 downto 23) := x"FF";
            result(22 downto 0) := fp.mantissa(62 downto 40);
        else
            -- Normal number
            -- Convert exponent back: exp_single = exp_extended - 16256
            if exp_extended < to_unsigned(16256, 15) then
                -- Underflow
                result(30 downto 0) := (others => '0');
            elsif exp_extended > to_unsigned(16256 + 254, 15) then
                -- Overflow - return infinity
                result(30 downto 23) := x"FF";
                result(22 downto 0) := (others => '0');
            else
                exp_single := exp_extended(7 downto 0) - to_unsigned(128, 8);
                result(30 downto 23) := std_logic_vector(exp_single);
                -- TODO: Apply rounding
                result(22 downto 0) := fp.mantissa(62 downto 40);
            end if;
        end if;

        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Convert extended precision to double precision
    ------------------------------------------------------------------------------
    function extended_to_double(fp : fp_extended_t; rounding : fp_rounding_t) return std_logic_vector is
        variable result : std_logic_vector(63 downto 0);
        variable exp_extended : unsigned(14 downto 0);
        variable exp_double : unsigned(10 downto 0);
    begin
        result(63) := fp.sign;
        exp_extended := unsigned(fp.exponent);

        -- Check for special values
        if exp_extended = "000000000000000" then
            -- Zero or denormalized
            result(62 downto 0) := (others => '0');
        elsif exp_extended = "111111111111111" then
            -- Infinity or NaN
            result(62 downto 52) := "11111111111";
            result(51 downto 0) := fp.mantissa(62 downto 11);
        else
            -- Normal number
            -- Convert exponent back: exp_double = exp_extended - 15360
            if exp_extended < to_unsigned(15360, 15) then
                -- Underflow
                result(62 downto 0) := (others => '0');
            elsif exp_extended > to_unsigned(15360 + 2046, 15) then
                -- Overflow - return infinity
                result(62 downto 52) := "11111111111";
                result(51 downto 0) := (others => '0');
            else
                exp_double := exp_extended(10 downto 0) - to_unsigned(1024, 11);
                result(62 downto 52) := std_logic_vector(exp_double);
                -- TODO: Apply rounding
                result(51 downto 0) := fp.mantissa(62 downto 11);
            end if;
        end if;

        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Classify FP number
    ------------------------------------------------------------------------------
    function classify_fp(fp : fp_extended_t) return fp_class_t is
        variable exp_all_zero : boolean;
        variable exp_all_one : boolean;
        variable mantissa_zero : boolean;
    begin
        exp_all_zero := (fp.exponent = "000000000000000");
        exp_all_one := (fp.exponent = "111111111111111");
        mantissa_zero := (fp.mantissa = (62 downto 0 => '0'));

        if exp_all_zero then
            if mantissa_zero and fp.integer_bit = '0' then
                return FP_ZERO;
            else
                return FP_DENORMAL;
            end if;
        elsif exp_all_one then
            if mantissa_zero and fp.integer_bit = '1' then
                return FP_INFINITY;
            elsif fp.mantissa(62) = '1' then
                return FP_QNAN;  -- Quiet NaN (MSB of mantissa = 1)
            else
                return FP_SNAN;  -- Signaling NaN
            end if;
        else
            return FP_NORMAL;
        end if;
    end function;

    ------------------------------------------------------------------------------
    -- Check if FP number is zero
    ------------------------------------------------------------------------------
    function is_fp_zero(fp : fp_extended_t) return boolean is
    begin
        return (fp.exponent = "000000000000000" and
                fp.mantissa = (62 downto 0 => '0') and
                fp.integer_bit = '0');
    end function;

    ------------------------------------------------------------------------------
    -- Check if FP number is NaN
    ------------------------------------------------------------------------------
    function is_fp_nan(fp : fp_extended_t) return boolean is
    begin
        return (fp.exponent = "111111111111111" and
                fp.mantissa /= (62 downto 0 => '0'));
    end function;

    ------------------------------------------------------------------------------
    -- Check if FP number is infinity
    ------------------------------------------------------------------------------
    function is_fp_inf(fp : fp_extended_t) return boolean is
    begin
        return (fp.exponent = "111111111111111" and
                fp.mantissa = (62 downto 0 => '0') and
                fp.integer_bit = '1');
    end function;

    ------------------------------------------------------------------------------
    -- Check if FP number is denormalized
    ------------------------------------------------------------------------------
    function is_fp_denormal(fp : fp_extended_t) return boolean is
    begin
        return (fp.exponent = "000000000000000" and
                fp.mantissa /= (62 downto 0 => '0'));
    end function;

    ------------------------------------------------------------------------------
    -- Count leading zeros in mantissa
    ------------------------------------------------------------------------------
    function count_leading_zeros(mantissa : std_logic_vector(62 downto 0)) return natural is
        variable count : natural := 0;
    begin
        for i in 62 downto 0 loop
            if mantissa(i) = '1' then
                return count;
            end if;
            count := count + 1;
        end loop;
        return 63;  -- All zeros
    end function;

    ------------------------------------------------------------------------------
    -- Normalize FP number
    ------------------------------------------------------------------------------
    function normalize_fp(fp : fp_extended_t) return fp_extended_t is
        variable result : fp_extended_t;
        variable shift : natural;
        variable exp_unsigned : unsigned(14 downto 0);
    begin
        result := fp;

        -- If integer bit is already 1, number is already normalized
        if fp.integer_bit = '1' then
            return result;
        end if;

        -- Count leading zeros in mantissa
        shift := count_leading_zeros(fp.mantissa);

        if shift = 63 then
            -- All zeros - return zero
            result.exponent := (others => '0');
            result.integer_bit := '0';
            result.mantissa := (others => '0');
        elsif shift = 0 then
            -- MSB of mantissa is 1, shift left by 1 to make integer bit = 1
            result.integer_bit := fp.mantissa(62);
            result.mantissa := fp.mantissa(61 downto 0) & '0';
            exp_unsigned := unsigned(fp.exponent) - 1;
            result.exponent := std_logic_vector(exp_unsigned);
        else
            -- Shift mantissa left to make MSB = 1, then shift once more for integer bit
            result.mantissa := fp.mantissa(62 - shift downto 0) & (shift - 1 downto 0 => '0');
            result.integer_bit := fp.mantissa(62 - shift);
            exp_unsigned := unsigned(fp.exponent) - to_unsigned(shift + 1, 15);
            result.exponent := std_logic_vector(exp_unsigned);
        end if;

        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Apply rounding to FP result
    ------------------------------------------------------------------------------
    function round_fp(
        fp        : fp_extended_t;
        guard     : std_logic;
        round_bit : std_logic;
        sticky    : std_logic;
        mode      : fp_rounding_t
    ) return fp_extended_t is
        variable result : fp_extended_t;
        variable round_up : boolean;
        variable mantissa_rounded : unsigned(63 downto 0);
    begin
        result := fp;
        round_up := false;

        -- Determine if we should round up based on mode
        case mode is
            when ROUND_NEAREST =>
                -- Round to nearest, ties to even
                if round_bit = '1' then
                    if guard = '1' or sticky = '1' then
                        -- More than halfway - round up
                        round_up := true;
                    elsif fp.mantissa(0) = '1' then
                        -- Exactly halfway, round to even (round up if LSB is 1)
                        round_up := true;
                    end if;
                end if;

            when ROUND_ZERO =>
                -- Round toward zero (truncate)
                round_up := false;

            when ROUND_PLUS_INF =>
                -- Round toward +infinity
                if fp.sign = '0' and (guard = '1' or round_bit = '1' or sticky = '1') then
                    round_up := true;
                end if;

            when ROUND_MINUS_INF =>
                -- Round toward -infinity
                if fp.sign = '1' and (guard = '1' or round_bit = '1' or sticky = '1') then
                    round_up := true;
                end if;
        end case;

        -- Apply rounding
        if round_up then
            mantissa_rounded := unsigned(fp.integer_bit & fp.mantissa) + 1;

            -- Check for overflow in mantissa (carry into bit 64)
            if mantissa_rounded(64) = '1' then
                -- Mantissa overflowed, shift right and increment exponent
                result.integer_bit := '1';
                result.mantissa := (62 downto 0 => '0');
                result.exponent := std_logic_vector(unsigned(fp.exponent) + 1);
            else
                result.integer_bit := mantissa_rounded(63);
                result.mantissa := std_logic_vector(mantissa_rounded(62 downto 0));
            end if;
        end if;

        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Create FP NaN
    ------------------------------------------------------------------------------
    function create_fp_nan(signaling : boolean) return fp_extended_t is
        variable result : fp_extended_t;
    begin
        result.sign := '0';
        result.exponent := (others => '1');
        result.integer_bit := '1';
        if signaling then
            result.mantissa := (62 => '0', others => '1');  -- Signaling NaN
        else
            result.mantissa := (62 => '1', others => '0');  -- Quiet NaN
        end if;
        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Create FP infinity
    ------------------------------------------------------------------------------
    function create_fp_inf(sign : std_logic) return fp_extended_t is
        variable result : fp_extended_t;
    begin
        result.sign := sign;
        result.exponent := (others => '1');
        result.integer_bit := '1';
        result.mantissa := (others => '0');
        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Create FP zero
    ------------------------------------------------------------------------------
    function create_fp_zero(sign : std_logic) return fp_extended_t is
        variable result : fp_extended_t;
    begin
        result.sign := sign;
        result.exponent := (others => '0');
        result.integer_bit := '0';
        result.mantissa := (others => '0');
        return result;
    end function;

end package body TG68040_FPU_Pack;
