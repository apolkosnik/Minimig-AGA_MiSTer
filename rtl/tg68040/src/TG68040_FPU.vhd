------------------------------------------------------------------------------
-- TG68040 Floating Point Unit
--
-- Complete FPU integrating register file and arithmetic units
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

entity TG68040_FPU is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Control
        enable         : in std_logic;                      -- Enable FPU
        operation      : in fp_operation_t;                 -- FP operation
        rounding_mode  : in fp_rounding_t;                  -- Rounding mode

        -- Register file interface
        src_reg_a      : in std_logic_vector(2 downto 0);   -- Source register A (FP0-FP7)
        src_reg_b      : in std_logic_vector(2 downto 0);   -- Source register B (FP0-FP7)
        dst_reg        : in std_logic_vector(2 downto 0);   -- Destination register (FP0-FP7)
        write_enable   : in std_logic;                      -- Write result to dst_reg

        -- Data interface (for FMOVE from/to memory)
        data_in        : in std_logic_vector(79 downto 0);  -- Data input (extended precision)
        data_out       : out std_logic_vector(79 downto 0); -- Data output (extended precision)

        -- Status
        result_valid   : out std_logic;                     -- Result valid
        busy           : out std_logic;                     -- FPU busy

        -- Control/Status Registers
        fpsr           : out fpsr_register_t;               -- FP Status Register
        fpcr           : in fpcr_register_t;                -- FP Control Register

        -- Statistics
        operations     : out std_logic_vector(31 downto 0); -- Operation count
        exceptions     : out std_logic_vector(31 downto 0)  -- Exception count
    );
end TG68040_FPU;

architecture rtl of TG68040_FPU is

    -- Component declarations
    component TG68040_FPU_RegFile is
        port(
            clk         : in std_logic;
            reset       : in std_logic;
            read_addr_a : in std_logic_vector(2 downto 0);
            read_data_a : out std_logic_vector(79 downto 0);
            read_addr_b : in std_logic_vector(2 downto 0);
            read_data_b : out std_logic_vector(79 downto 0);
            write_addr  : in std_logic_vector(2 downto 0);
            write_data  : in std_logic_vector(79 downto 0);
            write_en    : in std_logic
        );
    end component;

    component TG68040_FPU_Add is
        port(
            clk          : in std_logic;
            reset        : in std_logic;
            enable       : in std_logic;
            operation    : in std_logic;
            operand_a    : in std_logic_vector(79 downto 0);
            operand_b    : in std_logic_vector(79 downto 0);
            rounding     : in fp_rounding_t;
            result       : out std_logic_vector(79 downto 0);
            result_valid : out std_logic;
            exception    : out fp_exception_t
        );
    end component;

    component TG68040_FPU_Mul is
        port(
            clk          : in std_logic;
            reset        : in std_logic;
            enable       : in std_logic;
            operand_a    : in std_logic_vector(79 downto 0);
            operand_b    : in std_logic_vector(79 downto 0);
            rounding     : in fp_rounding_t;
            result       : out std_logic_vector(79 downto 0);
            result_valid : out std_logic;
            exception    : out fp_exception_t
        );
    end component;

    component TG68040_FPU_Div is
        port(
            clk          : in std_logic;
            reset        : in std_logic;
            enable       : in std_logic;
            dividend     : in std_logic_vector(79 downto 0);
            divisor      : in std_logic_vector(79 downto 0);
            rounding     : in fp_rounding_t;
            result       : out std_logic_vector(79 downto 0);
            result_valid : out std_logic;
            exception    : out fp_exception_t
        );
    end component;

    -- Register file signals
    signal regfile_read_a : std_logic_vector(79 downto 0);
    signal regfile_read_b : std_logic_vector(79 downto 0);
    signal regfile_write_data : std_logic_vector(79 downto 0);
    signal regfile_write_en : std_logic;

    -- Arithmetic unit signals
    signal add_enable : std_logic;
    signal add_operation : std_logic;  -- '0' = ADD, '1' = SUB
    signal add_result : std_logic_vector(79 downto 0);
    signal add_result_valid : std_logic;
    signal add_exception : fp_exception_t;

    signal mul_enable : std_logic;
    signal mul_result : std_logic_vector(79 downto 0);
    signal mul_result_valid : std_logic;
    signal mul_exception : fp_exception_t;

    signal div_enable : std_logic;
    signal div_result : std_logic_vector(79 downto 0);
    signal div_result_valid : std_logic;
    signal div_exception : fp_exception_t;

    -- Operation control
    signal current_operation : fp_operation_t := FP_OP_NOP;
    signal operation_active : std_logic := '0';

    -- Result multiplexing
    signal result_data : std_logic_vector(79 downto 0);
    signal result_exception : fp_exception_t;

    -- FPSR register
    signal fpsr_reg : fpsr_register_t := FPSR_REGISTER_INIT;

    -- Statistics
    signal operation_count : unsigned(31 downto 0) := (others => '0');
    signal exception_count : unsigned(31 downto 0) := (others => '0');

begin

    ------------------------------------------------------------------------------
    -- Register File
    ------------------------------------------------------------------------------
    regfile_inst: TG68040_FPU_RegFile
        port map(
            clk         => clk,
            reset       => reset,
            read_addr_a => src_reg_a,
            read_data_a => regfile_read_a,
            read_addr_b => src_reg_b,
            read_data_b => regfile_read_b,
            write_addr  => dst_reg,
            write_data  => regfile_write_data,
            write_en    => regfile_write_en
        );

    ------------------------------------------------------------------------------
    -- FP Adder/Subtractor
    ------------------------------------------------------------------------------
    adder_inst: TG68040_FPU_Add
        port map(
            clk          => clk,
            reset        => reset,
            enable       => add_enable,
            operation    => add_operation,
            operand_a    => regfile_read_a,
            operand_b    => regfile_read_b,
            rounding     => rounding_mode,
            result       => add_result,
            result_valid => add_result_valid,
            exception    => add_exception
        );

    ------------------------------------------------------------------------------
    -- FP Multiplier
    ------------------------------------------------------------------------------
    multiplier_inst: TG68040_FPU_Mul
        port map(
            clk          => clk,
            reset        => reset,
            enable       => mul_enable,
            operand_a    => regfile_read_a,
            operand_b    => regfile_read_b,
            rounding     => rounding_mode,
            result       => mul_result,
            result_valid => mul_result_valid,
            exception    => mul_exception
        );

    ------------------------------------------------------------------------------
    -- FP Divider (stub)
    ------------------------------------------------------------------------------
    divider_inst: TG68040_FPU_Div
        port map(
            clk          => clk,
            reset        => reset,
            enable       => div_enable,
            dividend     => regfile_read_a,
            divisor      => regfile_read_b,
            rounding     => rounding_mode,
            result       => div_result,
            result_valid => div_result_valid,
            exception    => div_exception
        );

    ------------------------------------------------------------------------------
    -- Operation Control and Unit Enable
    ------------------------------------------------------------------------------
    operation_control: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                current_operation <= FP_OP_NOP;
                operation_active <= '0';
                add_enable <= '0';
                mul_enable <= '0';
                div_enable <= '0';

            elsif enable = '1' then
                current_operation <= operation;

                -- Enable appropriate arithmetic unit based on operation
                case operation is
                    when FP_OP_ADD =>
                        add_enable <= '1';
                        add_operation <= '0';  -- Addition
                        mul_enable <= '0';
                        div_enable <= '0';
                        operation_active <= '1';

                    when FP_OP_SUB =>
                        add_enable <= '1';
                        add_operation <= '1';  -- Subtraction
                        mul_enable <= '0';
                        div_enable <= '0';
                        operation_active <= '1';

                    when FP_OP_MUL =>
                        add_enable <= '0';
                        mul_enable <= '1';
                        div_enable <= '0';
                        operation_active <= '1';

                    when FP_OP_DIV =>
                        add_enable <= '0';
                        mul_enable <= '0';
                        div_enable <= '1';
                        operation_active <= '1';

                    when FP_OP_MOVE =>
                        -- Simple move operation (no arithmetic)
                        add_enable <= '0';
                        mul_enable <= '0';
                        div_enable <= '0';
                        operation_active <= '1';

                    when FP_OP_ABS | FP_OP_NEG =>
                        -- Unary operations (implemented in future)
                        add_enable <= '0';
                        mul_enable <= '0';
                        div_enable <= '0';
                        operation_active <= '1';

                    when others =>
                        add_enable <= '0';
                        mul_enable <= '0';
                        div_enable <= '0';
                        operation_active <= '0';
                end case;

            else
                add_enable <= '0';
                mul_enable <= '0';
                div_enable <= '0';
                operation_active <= '0';
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Result Multiplexing
    ------------------------------------------------------------------------------
    result_mux: process(current_operation, add_result, add_result_valid, add_exception,
                        mul_result, mul_result_valid, mul_exception,
                        div_result, div_result_valid, div_exception,
                        regfile_read_a, data_in)
    begin
        -- Default values
        result_data <= (others => '0');
        result_valid <= '0';
        result_exception <= FP_EXCEPTION_NONE;

        case current_operation is
            when FP_OP_ADD | FP_OP_SUB =>
                result_data <= add_result;
                result_valid <= add_result_valid;
                result_exception <= add_exception;

            when FP_OP_MUL =>
                result_data <= mul_result;
                result_valid <= mul_result_valid;
                result_exception <= mul_exception;

            when FP_OP_DIV =>
                result_data <= div_result;
                result_valid <= div_result_valid;
                result_exception <= div_exception;

            when FP_OP_MOVE =>
                -- Move from register A or data_in
                result_data <= regfile_read_a;
                result_valid <= '1';
                result_exception <= FP_EXCEPTION_NONE;

            when FP_OP_ABS =>
                -- Absolute value: clear sign bit
                result_data <= '0' & regfile_read_a(78 downto 0);
                result_valid <= '1';
                result_exception <= FP_EXCEPTION_NONE;

            when FP_OP_NEG =>
                -- Negate: flip sign bit
                result_data <= (not regfile_read_a(79)) & regfile_read_a(78 downto 0);
                result_valid <= '1';
                result_exception <= FP_EXCEPTION_NONE;

            when others =>
                result_data <= (others => '0');
                result_valid <= '0';
                result_exception <= FP_EXCEPTION_NONE;
        end case;
    end process;

    ------------------------------------------------------------------------------
    -- Register File Writeback
    ------------------------------------------------------------------------------
    regfile_write_data <= result_data;
    regfile_write_en <= write_enable and result_valid;

    ------------------------------------------------------------------------------
    -- FPSR Status Register Update
    ------------------------------------------------------------------------------
    fpsr_update: process(clk)
        variable fp_result : fp_extended_t;
        variable fp_class : fp_class_t;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                fpsr_reg <= FPSR_REGISTER_INIT;

            elsif result_valid = '1' then
                -- Update exception status
                fpsr_reg.exception_status <= result_exception;

                -- Accumulate exceptions
                if result_exception.inexact = '1' then
                    fpsr_reg.accrued_exception.inexact <= '1';
                end if;
                if result_exception.divide_by_zero = '1' then
                    fpsr_reg.accrued_exception.divide_by_zero <= '1';
                end if;
                if result_exception.underflow = '1' then
                    fpsr_reg.accrued_exception.underflow <= '1';
                end if;
                if result_exception.overflow = '1' then
                    fpsr_reg.accrued_exception.overflow <= '1';
                end if;
                if result_exception.invalid_op = '1' then
                    fpsr_reg.accrued_exception.invalid_op <= '1';
                end if;

                -- Update condition codes
                fp_result := unpack_fp_extended(result_data);
                fp_class := classify_fp(fp_result);

                -- Set condition flags
                fpsr_reg.condition_n <= fp_result.sign;  -- Negative
                fpsr_reg.condition_z <= '1' when fp_class = FP_ZERO else '0';  -- Zero
                fpsr_reg.condition_i <= '1' when fp_class = FP_INFINITY else '0';  -- Infinity
                fpsr_reg.condition_nan <= '1' when (fp_class = FP_QNAN or fp_class = FP_SNAN) else '0';  -- NaN
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Statistics
    ------------------------------------------------------------------------------
    stats_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                operation_count <= (others => '0');
                exception_count <= (others => '0');

            else
                -- Count operations
                if enable = '1' and operation /= FP_OP_NOP then
                    operation_count <= operation_count + 1;
                end if;

                -- Count exceptions
                if result_valid = '1' then
                    if result_exception.inexact = '1' or
                       result_exception.divide_by_zero = '1' or
                       result_exception.underflow = '1' or
                       result_exception.overflow = '1' or
                       result_exception.invalid_op = '1' then
                        exception_count <= exception_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Outputs
    ------------------------------------------------------------------------------
    data_out <= regfile_read_a;  -- For FMOVE to memory
    fpsr <= fpsr_reg;
    busy <= operation_active;
    operations <= std_logic_vector(operation_count);
    exceptions <= std_logic_vector(exception_count);

end rtl;
