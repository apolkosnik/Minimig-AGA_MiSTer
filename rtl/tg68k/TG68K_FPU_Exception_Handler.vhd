------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU Exception Handler                               --
-- Handles IEEE 754 exceptions and result correction                        --
-- Copyright (c) 2025                                                       --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity TG68K_FPU_Exception_Handler is
    port(
        clk : in std_logic;
        reset : in std_logic;
        
        -- Input from FPU ALU/Transcendental
        operation_result : in std_logic_vector(79 downto 0);
        operation_valid : in std_logic;
        operation_type : in std_logic_vector(7 downto 0);  -- Operation being performed
        
        -- Operands for checking
        operand_a : in std_logic_vector(79 downto 0);
        operand_b : in std_logic_vector(79 downto 0);
        
        -- Exception flags from ALU/Transcendental
        overflow_flag : in std_logic;
        underflow_flag : in std_logic;
        inexact_flag : in std_logic;
        invalid_flag : in std_logic;
        divide_by_zero_flag : in std_logic;
        
        -- Control
        fpcr : in std_logic_vector(31 downto 0);  -- FPU Control Register
        fpsr_in : in std_logic_vector(31 downto 0);  -- Current FPSR
        
        -- Outputs
        fpsr_out : out std_logic_vector(31 downto 0);  -- Updated FPSR
        exception_pending : out std_logic;
        exception_vector : out std_logic_vector(7 downto 0);
        corrected_result : out std_logic_vector(79 downto 0)
    );
end TG68K_FPU_Exception_Handler;

architecture rtl of TG68K_FPU_Exception_Handler is
    -- MC68881/68882 FPSR Exception bits (Exception Status Byte - bits 15:8)
    constant FPSR_BSUN     : integer := 15;  -- Branch/Set on Unordered
    constant FPSR_SNAN     : integer := 14;  -- Signaling NaN
    constant FPSR_OPERR    : integer := 13;  -- Operand error
    constant FPSR_OVFL     : integer := 12;  -- Overflow
    constant FPSR_UNFL     : integer := 11;  -- Underflow
    constant FPSR_DZ       : integer := 10;  -- Divide by Zero
    constant FPSR_INEX2    : integer := 9;   -- Inexact operation
    constant FPSR_INEX1    : integer := 8;   -- Inexact decimal input
    
    -- MC68881/68882 FPSR Accrued Exception bits (Accrued Exception Byte - bits 7:0)
    constant FPSR_IOP      : integer := 7;   -- Invalid operation (accrued)
    constant FPSR_OVFL_A   : integer := 6;   -- Overflow (accrued)
    constant FPSR_UNFL_A   : integer := 5;   -- Underflow (accrued)
    constant FPSR_DZ_A     : integer := 4;   -- Divide by Zero (accrued)
    constant FPSR_INEX_A   : integer := 3;   -- Inexact (accrued)
    
    -- MC68881/68882 FPSR Condition Code bits (bits 31:24)
    constant FPSR_N        : integer := 31;  -- Negative
    constant FPSR_Z        : integer := 30;  -- Zero
    constant FPSR_I        : integer := 29;  -- Infinity
    constant FPSR_NAN      : integer := 28;  -- Not a Number
    
    -- MC68881/68882 FPCR Exception Enable bits (bits 15:8)
    constant FPCR_BSUN_EN  : integer := 15;  -- BSUN enable
    constant FPCR_SNAN_EN  : integer := 14;  -- SNAN enable
    constant FPCR_OPERR_EN : integer := 13;  -- OPERR enable
    constant FPCR_OVFL_EN  : integer := 12;  -- Overflow enable
    constant FPCR_UNFL_EN  : integer := 11;  -- Underflow enable
    constant FPCR_DZ_EN    : integer := 10;  -- Divide by Zero enable
    constant FPCR_INEX2_EN : integer := 9;   -- INEX2 enable
    constant FPCR_INEX1_EN : integer := 8;   -- INEX1 enable
    
    -- MC68881/68882 FPCR Mode Control bits (bits 7:4)
    constant FPCR_PREC     : integer := 7;   -- Precision control (bits 7:6)
    constant FPCR_RND      : integer := 5;   -- Rounding mode (bits 5:4)
    
    -- Rounding modes
    constant RND_NEAREST   : std_logic_vector(1 downto 0) := "00";  -- Round to nearest
    constant RND_ZERO      : std_logic_vector(1 downto 0) := "01";  -- Round toward zero
    constant RND_NINF      : std_logic_vector(1 downto 0) := "10";  -- Round toward -infinity
    constant RND_PINF      : std_logic_vector(1 downto 0) := "11";  -- Round toward +infinity
    
    -- IEEE 754 constants for 80-bit extended precision
    constant EXP_BIAS      : integer := 16383;
    constant EXP_MAX       : integer := 32767;
    constant EXP_MIN       : integer := 0;
    
    -- Internal signals
    signal fpsr_work       : std_logic_vector(31 downto 0);
    signal exception_status_byte : std_logic_vector(7 downto 0);
    signal exception_accrued_byte : std_logic_vector(7 downto 0);
    signal condition_codes : std_logic_vector(7 downto 0);
    signal exception_detected : std_logic;
    signal exception_enabled : std_logic;
    signal rounding_mode   : std_logic_vector(1 downto 0);
    signal precision_mode  : std_logic_vector(1 downto 0);
    
    -- Special value detection
    signal is_nan_result   : std_logic;
    signal is_inf_result   : std_logic;
    signal is_zero_result  : std_logic;
    signal is_denorm_result : std_logic;
    signal result_sign     : std_logic;
    
begin

    -- Extract rounding and precision modes from FPCR
    rounding_mode <= fpcr(FPCR_RND downto FPCR_RND-1);
    precision_mode <= fpcr(FPCR_PREC downto FPCR_PREC-1);
    
    -- Detect special values in result
    detect_special: process(operation_result)
    begin
        result_sign <= operation_result(79);
        
        -- Check for NaN
        if operation_result(78 downto 64) = "111111111111111" and 
           (operation_result(63) = '0' or operation_result(62 downto 0) /= (62 downto 0 => '0')) then
            is_nan_result <= '1';
        else
            is_nan_result <= '0';
        end if;
        
        -- Check for Infinity
        if operation_result(78 downto 64) = "111111111111111" and 
           operation_result(63) = '1' and operation_result(62 downto 0) = (62 downto 0 => '0') then
            is_inf_result <= '1';
        else
            is_inf_result <= '0';
        end if;
        
        -- Check for Zero
        if operation_result(78 downto 0) = (78 downto 0 => '0') then
            is_zero_result <= '1';
        else
            is_zero_result <= '0';
        end if;
        
        -- Check for Denormalized
        if operation_result(78 downto 64) = (14 downto 0 => '0') and 
           operation_result(63 downto 0) /= (63 downto 0 => '0') then
            is_denorm_result <= '1';
        else
            is_denorm_result <= '0';
        end if;
    end process;

    -- Main exception handling process
    exception_handler: process(clk, reset)
        variable exp_a, exp_b, exp_result : integer;
        variable sign_a, sign_b : std_logic;
        variable mantissa_a, mantissa_b : std_logic_vector(63 downto 0);
        variable is_zero_a, is_zero_b : std_logic;
        variable is_inf_a, is_inf_b : std_logic;
        variable is_nan_a, is_nan_b : std_logic;
        variable is_snan_a, is_snan_b : std_logic;
        variable is_denorm_a, is_denorm_b : std_logic;
        variable highest_priority_exception : integer;
        variable trap_enabled : std_logic;
        variable v_exception_status_byte : std_logic_vector(7 downto 0);
        variable v_exception_accrued_byte : std_logic_vector(7 downto 0);
        variable v_condition_codes : std_logic_vector(7 downto 0);
    begin
        if reset = '1' then
            fpsr_out <= (others => '0');
            exception_pending <= '0';
            exception_vector <= (others => '0');
            corrected_result <= (others => '0');
            exception_status_byte <= (others => '0');
            exception_accrued_byte <= (others => '0');
            condition_codes <= (others => '0');
            
        elsif rising_edge(clk) then
            -- Initialize with current FPSR
            fpsr_work <= fpsr_in;
            exception_detected <= '0';
            exception_enabled <= '0';
            corrected_result <= operation_result;
            v_exception_status_byte := (others => '0');
            v_exception_accrued_byte := (others => '0');
            v_condition_codes := fpsr_in(31 downto 24);
            trap_enabled := '0';
            highest_priority_exception := 0;
            
            if operation_valid = '1' then
                -- Extract operand components
                sign_a := operand_a(79);
                exp_a := to_integer(unsigned(operand_a(78 downto 64)));
                mantissa_a := operand_a(63 downto 0);
                
                sign_b := operand_b(79);
                exp_b := to_integer(unsigned(operand_b(78 downto 64)));
                mantissa_b := operand_b(63 downto 0);
                
                -- Comprehensive special value detection
                -- Zero detection
                is_zero_a := '0';
                is_zero_b := '0';
                if exp_a = 0 and mantissa_a = (63 downto 0 => '0') then
                    is_zero_a := '1';
                end if;
                if exp_b = 0 and mantissa_b = (63 downto 0 => '0') then
                    is_zero_b := '1';
                end if;
                
                -- Infinity detection
                is_inf_a := '0';
                is_inf_b := '0';
                if exp_a = EXP_MAX and mantissa_a(63) = '1' and mantissa_a(62 downto 0) = (62 downto 0 => '0') then
                    is_inf_a := '1';
                end if;
                if exp_b = EXP_MAX and mantissa_b(63) = '1' and mantissa_b(62 downto 0) = (62 downto 0 => '0') then
                    is_inf_b := '1';
                end if;
                
                -- NaN detection (including signaling NaN)
                is_nan_a := '0';
                is_snan_a := '0';
                is_nan_b := '0';
                is_snan_b := '0';
                if exp_a = EXP_MAX and (mantissa_a(63) = '0' or mantissa_a(62 downto 0) /= (62 downto 0 => '0')) then
                    is_nan_a := '1';
                    if mantissa_a(62) = '0' then  -- Signaling NaN has MSB of fraction = 0
                        is_snan_a := '1';
                    end if;
                end if;
                if exp_b = EXP_MAX and (mantissa_b(63) = '0' or mantissa_b(62 downto 0) /= (62 downto 0 => '0')) then
                    is_nan_b := '1';
                    if mantissa_b(62) = '0' then  -- Signaling NaN has MSB of fraction = 0
                        is_snan_b := '1';
                    end if;
                end if;
                
                -- Denormalized detection
                is_denorm_a := '0';
                is_denorm_b := '0';
                if exp_a = 0 and mantissa_a /= (63 downto 0 => '0') then
                    is_denorm_a := '1';
                end if;
                if exp_b = 0 and mantissa_b /= (63 downto 0 => '0') then
                    is_denorm_b := '1';
                end if;
                
                -- Result exponent for overflow/underflow checking
                exp_result := to_integer(unsigned(operation_result(78 downto 64)));
                
                -- Check exceptions from ALU/Transcendental flags first
                if invalid_flag = '1' then
                    v_exception_status_byte(FPSR_OPERR - 8) := '1';
                    v_exception_accrued_byte(FPSR_IOP) := '1';
                    -- Generate quiet NaN
                    corrected_result <= '0' & "111111111111111" & "11" & (61 downto 0 => '0');
                end if;
                
                if divide_by_zero_flag = '1' then
                    v_exception_status_byte(FPSR_DZ - 8) := '1';
                    v_exception_accrued_byte(FPSR_DZ_A) := '1';
                    -- Result should be signed infinity
                    corrected_result <= (sign_a xor sign_b) & "111111111111111" & '1' & (62 downto 0 => '0');
                end if;
                
                if overflow_flag = '1' then
                    v_exception_status_byte(FPSR_OVFL - 8) := '1';
                    v_exception_accrued_byte(FPSR_OVFL_A) := '1';
                    -- Result correction based on rounding mode
                    case rounding_mode is
                        when RND_NEAREST | RND_ZERO =>
                            -- Return signed infinity
                            corrected_result <= result_sign & "111111111111111" & '1' & (62 downto 0 => '0');
                        when RND_NINF =>
                            if result_sign = '1' then
                                -- Negative overflow rounds to -infinity
                                corrected_result <= '1' & "111111111111111" & '1' & (62 downto 0 => '0');
                            else
                                -- Positive overflow rounds to largest positive
                                corrected_result <= '0' & "111111111111110" & (63 downto 0 => '1');
                            end if;
                        when RND_PINF =>
                            if result_sign = '0' then
                                -- Positive overflow rounds to +infinity
                                corrected_result <= '0' & "111111111111111" & '1' & (62 downto 0 => '0');
                            else
                                -- Negative overflow rounds to largest negative
                                corrected_result <= '1' & "111111111111110" & (63 downto 0 => '1');
                            end if;
                        when others =>
                            corrected_result <= result_sign & "111111111111111" & '1' & (62 downto 0 => '0');
                    end case;
                end if;
                
                if underflow_flag = '1' then
                    v_exception_status_byte(FPSR_UNFL - 8) := '1';
                    v_exception_accrued_byte(FPSR_UNFL_A) := '1';
                    -- Result correction: flush to zero or denormalized based on mode
                    if fpcr(11) = '0' then  -- Flush to zero mode
                        corrected_result <= result_sign & (78 downto 0 => '0');
                    end if;
                    -- Otherwise keep denormalized result
                end if;
                
                if inexact_flag = '1' then
                    v_exception_status_byte(FPSR_INEX2 - 8) := '1';
                    v_exception_accrued_byte(FPSR_INEX_A) := '1';
                end if;
                
                -- Additional exception checks based on operation
                -- Check for signaling NaN
                if is_snan_a = '1' or is_snan_b = '1' then
                    v_exception_status_byte(FPSR_SNAN - 8) := '1';
                    v_exception_accrued_byte(FPSR_IOP) := '1';
                    -- Convert to quiet NaN
                    if is_snan_a = '1' then
                        corrected_result <= operand_a(79) & operand_a(78 downto 63) & '1' & operand_a(61 downto 0);
                    else
                        corrected_result <= operand_b(79) & operand_b(78 downto 63) & '1' & operand_b(61 downto 0);
                    end if;
                end if;
                
                -- Update condition codes based on result
                v_condition_codes := (others => '0');
                if is_nan_result = '1' then
                    v_condition_codes(FPSR_NAN - 24) := '1';
                elsif is_zero_result = '1' then
                    v_condition_codes(FPSR_Z - 24) := '1';
                elsif is_inf_result = '1' then
                    v_condition_codes(FPSR_I - 24) := '1';
                    v_condition_codes(FPSR_N - 24) := result_sign;
                else
                    v_condition_codes(FPSR_N - 24) := result_sign;
                end if;
                
                -- Determine highest priority exception and check if trap enabled
                -- Priority order: BSUN, SNAN, OPERR, OVFL, UNFL, DZ, INEX2, INEX1
                for i in 7 downto 0 loop
                    if v_exception_status_byte(i) = '1' then
                        highest_priority_exception := i + 8;  -- Convert to FPSR bit position
                        if fpcr(i + 8) = '1' then  -- Check if trap enabled
                            trap_enabled := '1';
                            exception_enabled <= '1';
                            -- MC68881/68882 exception vectors start at 48 (0x30)
                            -- Vector = 48 + exception_number
                            case i is
                                when 7 => exception_vector <= X"37";  -- BSUN
                                when 6 => exception_vector <= X"36";  -- SNAN  
                                when 5 => exception_vector <= X"35";  -- OPERR
                                when 4 => exception_vector <= X"34";  -- OVFL
                                when 3 => exception_vector <= X"33";  -- UNFL
                                when 2 => exception_vector <= X"32";  -- DZ
                                when 1 => exception_vector <= X"31";  -- INEX2
                                when 0 => exception_vector <= X"30";  -- INEX1
                                when others => exception_vector <= X"30";
                            end case;
                            exit;  -- Stop at highest priority
                        end if;
                    end if;
                end loop;
                
                -- Exception vector assignment is already handled above in the priority loop
                -- No need for duplicate logic that would override the correct F-line vectors
                
                -- Update FPSR
                fpsr_work(31 downto 24) <= v_condition_codes;  -- Condition Code Byte
                fpsr_work(23 downto 16) <= fpsr_in(23 downto 16);  -- Quotient Byte (unchanged)
                fpsr_work(15 downto 8) <= fpsr_in(15 downto 8) or v_exception_status_byte;  -- Exception Status Byte
                fpsr_work(7 downto 0) <= fpsr_in(7 downto 0) or v_exception_accrued_byte;  -- Accrued Exception Byte
                
                exception_detected <= v_exception_status_byte(7) or v_exception_status_byte(6) or 
                                    v_exception_status_byte(5) or v_exception_status_byte(4) or 
                                    v_exception_status_byte(3) or v_exception_status_byte(2) or 
                                    v_exception_status_byte(1) or v_exception_status_byte(0);
            end if;
            
            -- Assign variables to signals at end of process
            exception_status_byte <= v_exception_status_byte;
            exception_accrued_byte <= v_exception_accrued_byte;
            condition_codes <= v_condition_codes;
            
            fpsr_out <= fpsr_work;
            exception_pending <= exception_detected and exception_enabled;
        end if;
    end process;

end rtl;