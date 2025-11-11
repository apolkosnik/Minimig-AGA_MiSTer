------------------------------------------------------------------------------
-- TG68040 Exception Package
--
-- Defines exception types, priorities, vectors, and stack frames
-- for MC68040 exception processing
--
-- Copyright (c) 2025 Claude AI (Anthropic)
-- Based on MC68040 User's Manual, Chapter 6: Exception Processing
--
-- LGPL v3
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package TG68040_Exception_Pack is

    ------------------------------------------------------------------------------
    -- Exception Type Enumeration
    ------------------------------------------------------------------------------
    type exception_type_t is (
        EXC_NONE,                   -- No exception
        -- Group 0 (Highest Priority)
        EXC_RESET,                  -- Reset (vector 0)
        EXC_BUS_ERROR,              -- Bus Error (vector 2)
        EXC_ADDRESS_ERROR,          -- Address Error (vector 3)
        -- Group 1
        EXC_TRACE,                  -- Trace (vector 9)
        EXC_ILLEGAL_INSTRUCTION,    -- Illegal Instruction (vector 4)
        EXC_PRIVILEGE_VIOLATION,    -- Privilege Violation (vector 8)
        EXC_FP_PROTOCOL_VIOLATION,  -- FP Protocol Violation (vector 13)
        -- Group 2
        EXC_CHK,                    -- CHK, CHK2 Instruction (vector 6)
        EXC_FP_EXCEPTION,           -- FP exceptions (vectors 48-54)
        EXC_DIVIDE_BY_ZERO,         -- Divide by Zero (vector 5)
        EXC_TRAP,                   -- TRAP #n (vectors 32-47)
        EXC_TRAPV,                  -- TRAPV (vector 7)
        -- Interrupts
        EXC_INTERRUPT_L1,           -- Level 1 Interrupt (vector 25)
        EXC_INTERRUPT_L2,           -- Level 2 Interrupt (vector 26)
        EXC_INTERRUPT_L3,           -- Level 3 Interrupt (vector 27)
        EXC_INTERRUPT_L4,           -- Level 4 Interrupt (vector 28)
        EXC_INTERRUPT_L5,           -- Level 5 Interrupt (vector 29)
        EXC_INTERRUPT_L6,           -- Level 6 Interrupt (vector 30)
        EXC_INTERRUPT_L7,           -- Level 7 Interrupt / NMI (vector 31)
        -- Line Emulators
        EXC_LINE_A,                 -- Line A Emulator (vector 10)
        EXC_LINE_F,                 -- Line F Emulator (vector 11)
        -- Format and Uninitialized
        EXC_FORMAT_ERROR,           -- Format Error (vector 14)
        EXC_UNINITIALIZED_INT,      -- Uninitialized Interrupt (vector 15)
        EXC_SPURIOUS_INT,           -- Spurious Interrupt (vector 24)
        -- User-defined
        EXC_USER_DEFINED            -- User Defined (vectors 64-255)
    );

    ------------------------------------------------------------------------------
    -- Exception Priority Levels
    ------------------------------------------------------------------------------
    -- Lower number = higher priority
    -- Used for simultaneous exception arbitration
    constant PRIORITY_RESET              : std_logic_vector(3 downto 0) := x"0";
    constant PRIORITY_BUS_ERROR          : std_logic_vector(3 downto 0) := x"1";
    constant PRIORITY_ADDRESS_ERROR      : std_logic_vector(3 downto 0) := x"1";
    constant PRIORITY_TRACE              : std_logic_vector(3 downto 0) := x"2";
    constant PRIORITY_INTERRUPT          : std_logic_vector(3 downto 0) := x"3";
    constant PRIORITY_ILLEGAL            : std_logic_vector(3 downto 0) := x"4";
    constant PRIORITY_PRIVILEGE          : std_logic_vector(3 downto 0) := x"4";
    constant PRIORITY_FP_PROTOCOL        : std_logic_vector(3 downto 0) := x"5";
    constant PRIORITY_FP_EXCEPTION       : std_logic_vector(3 downto 0) := x"5";
    constant PRIORITY_CHK                : std_logic_vector(3 downto 0) := x"6";
    constant PRIORITY_TRAP               : std_logic_vector(3 downto 0) := x"6";
    constant PRIORITY_TRAPV              : std_logic_vector(3 downto 0) := x"6";
    constant PRIORITY_DIVIDE_BY_ZERO     : std_logic_vector(3 downto 0) := x"7";

    ------------------------------------------------------------------------------
    -- Exception Vector Numbers
    ------------------------------------------------------------------------------
    -- Vector number is used to calculate vector offset (vector × 4)
    constant VECTOR_RESET_SSP           : std_logic_vector(7 downto 0) := x"00";
    constant VECTOR_RESET_PC            : std_logic_vector(7 downto 0) := x"01";
    constant VECTOR_BUS_ERROR           : std_logic_vector(7 downto 0) := x"02";
    constant VECTOR_ADDRESS_ERROR       : std_logic_vector(7 downto 0) := x"03";
    constant VECTOR_ILLEGAL_INSTRUCTION : std_logic_vector(7 downto 0) := x"04";
    constant VECTOR_DIVIDE_BY_ZERO      : std_logic_vector(7 downto 0) := x"05";
    constant VECTOR_CHK                 : std_logic_vector(7 downto 0) := x"06";
    constant VECTOR_TRAPV               : std_logic_vector(7 downto 0) := x"07";
    constant VECTOR_PRIVILEGE_VIOLATION : std_logic_vector(7 downto 0) := x"08";
    constant VECTOR_TRACE               : std_logic_vector(7 downto 0) := x"09";
    constant VECTOR_LINE_A              : std_logic_vector(7 downto 0) := x"0A";
    constant VECTOR_LINE_F              : std_logic_vector(7 downto 0) := x"0B";
    constant VECTOR_FP_PROTOCOL         : std_logic_vector(7 downto 0) := x"0D";
    constant VECTOR_FORMAT_ERROR        : std_logic_vector(7 downto 0) := x"0E";
    constant VECTOR_UNINITIALIZED_INT   : std_logic_vector(7 downto 0) := x"0F";
    constant VECTOR_SPURIOUS_INT        : std_logic_vector(7 downto 0) := x"18";
    constant VECTOR_INTERRUPT_L1        : std_logic_vector(7 downto 0) := x"19";
    constant VECTOR_INTERRUPT_L2        : std_logic_vector(7 downto 0) := x"1A";
    constant VECTOR_INTERRUPT_L3        : std_logic_vector(7 downto 0) := x"1B";
    constant VECTOR_INTERRUPT_L4        : std_logic_vector(7 downto 0) := x"1C";
    constant VECTOR_INTERRUPT_L5        : std_logic_vector(7 downto 0) := x"1D";
    constant VECTOR_INTERRUPT_L6        : std_logic_vector(7 downto 0) := x"1E";
    constant VECTOR_INTERRUPT_L7        : std_logic_vector(7 downto 0) := x"1F";
    constant VECTOR_TRAP_BASE           : std_logic_vector(7 downto 0) := x"20";  -- TRAP #0-15 are 0x20-0x2F

    ------------------------------------------------------------------------------
    -- Stack Frame Formats
    ------------------------------------------------------------------------------
    type stack_frame_format_t is (
        FRAME_FORMAT_0,  -- 4-word normal exception frame
        FRAME_FORMAT_1,  -- 4-word throwaway frame (RTE exception)
        FRAME_FORMAT_2,  -- 6-word instruction exception frame
        FRAME_FORMAT_7   -- 30-word access error frame (bus/address error)
    );

    ------------------------------------------------------------------------------
    -- Status Register (SR) Structure
    ------------------------------------------------------------------------------
    -- SR is 16 bits:
    -- Bits 15-13: T1, T0, S (Trace mode and Supervisor mode)
    -- Bits 12-8: Reserved (0), M (Master/interrupt state), I2, I1, I0 (Interrupt mask)
    -- Bits 7-5: Reserved (0)
    -- Bits 4-0: X, N, Z, V, C (Condition codes)
    type status_register_t is record
        -- Trace and supervisor mode
        trace_t1        : std_logic;                      -- Bit 15: Trace on any instruction
        trace_t0        : std_logic;                      -- Bit 14: Trace on change of flow
        supervisor_mode : std_logic;                      -- Bit 13: Supervisor mode (1) or user mode (0)
        -- Interrupt mask (bits 10-8)
        interrupt_mask  : std_logic_vector(2 downto 0);  -- Bits 10-8: I2, I1, I0 (levels 0-7)
        -- Condition codes
        condition_x     : std_logic;                      -- Bit 4: Extend
        condition_n     : std_logic;                      -- Bit 3: Negative
        condition_z     : std_logic;                      -- Bit 2: Zero
        condition_v     : std_logic;                      -- Bit 1: Overflow
        condition_c     : std_logic;                      -- Bit 0: Carry
    end record;

    constant SR_INIT : status_register_t := (
        trace_t1        => '0',
        trace_t0        => '0',
        supervisor_mode => '1',  -- Start in supervisor mode
        interrupt_mask  => "111", -- Start with interrupts masked (level 7)
        condition_x     => '0',
        condition_n     => '0',
        condition_z     => '0',
        condition_v     => '0',
        condition_c     => '0'
    );

    ------------------------------------------------------------------------------
    -- Exception Information Record
    ------------------------------------------------------------------------------
    -- Contains all information about a detected exception
    type exception_info_t is record
        valid           : std_logic;                       -- Exception is valid
        exc_type        : exception_type_t;                -- Exception type
        vector          : std_logic_vector(7 downto 0);    -- Vector number (0-255)
        priority        : std_logic_vector(3 downto 0);    -- Priority level (0=highest)
        frame_format    : stack_frame_format_t;            -- Stack frame format
        fault_addr      : std_logic_vector(31 downto 0);   -- Faulting address (for bus/address errors)
        fault_pc        : std_logic_vector(31 downto 0);   -- PC at time of fault
        fault_sr        : std_logic_vector(15 downto 0);   -- SR at time of fault
        trap_number     : std_logic_vector(3 downto 0);    -- TRAP #n number (0-15)
    end record;

    constant EXCEPTION_INFO_NONE : exception_info_t := (
        valid        => '0',
        exc_type     => EXC_NONE,
        vector       => (others => '0'),
        priority     => (others => '1'),  -- Lowest priority
        frame_format => FRAME_FORMAT_0,
        fault_addr   => (others => '0'),
        fault_pc     => (others => '0'),
        fault_sr     => (others => '0'),
        trap_number  => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- Utility Functions
    ------------------------------------------------------------------------------

    -- Get exception priority from exception type
    function get_exception_priority(exc_type : exception_type_t) return std_logic_vector;

    -- Get exception vector from exception type
    function get_exception_vector(exc_type : exception_type_t; trap_num : std_logic_vector(3 downto 0)) return std_logic_vector;

    -- Get stack frame format from exception type
    function get_frame_format(exc_type : exception_type_t) return stack_frame_format_t;

    -- Get frame size in bytes
    function get_frame_size(format : stack_frame_format_t) return natural;

    -- Check if exception is an interrupt
    function is_interrupt(exc_type : exception_type_t) return boolean;

    -- Get interrupt level from exception type (1-7)
    function get_interrupt_level(exc_type : exception_type_t) return std_logic_vector;

    -- Pack status register to 16-bit word
    function pack_sr(sr : status_register_t) return std_logic_vector;

    -- Unpack 16-bit word to status register
    function unpack_sr(data : std_logic_vector(15 downto 0)) return status_register_t;

    -- Create format/vector word for stack frame
    -- Format: bits 15-12, Vector: bits 11-2 (vector number bits 9-0), bits 1-0 unused
    function create_format_vector_word(format : stack_frame_format_t; vector : std_logic_vector(7 downto 0)) return std_logic_vector;

    -- Compare exception priorities (returns true if exc_a has higher priority than exc_b)
    function exception_has_higher_priority(exc_a : exception_info_t; exc_b : exception_info_t) return boolean;

end package TG68040_Exception_Pack;

------------------------------------------------------------------------------
-- Package Body
------------------------------------------------------------------------------

package body TG68040_Exception_Pack is

    ------------------------------------------------------------------------------
    -- Get exception priority from exception type
    ------------------------------------------------------------------------------
    function get_exception_priority(exc_type : exception_type_t) return std_logic_vector is
    begin
        case exc_type is
            when EXC_RESET =>
                return PRIORITY_RESET;
            when EXC_BUS_ERROR =>
                return PRIORITY_BUS_ERROR;
            when EXC_ADDRESS_ERROR =>
                return PRIORITY_ADDRESS_ERROR;
            when EXC_TRACE =>
                return PRIORITY_TRACE;
            when EXC_INTERRUPT_L1 | EXC_INTERRUPT_L2 | EXC_INTERRUPT_L3 | EXC_INTERRUPT_L4 |
                 EXC_INTERRUPT_L5 | EXC_INTERRUPT_L6 | EXC_INTERRUPT_L7 =>
                return PRIORITY_INTERRUPT;
            when EXC_ILLEGAL_INSTRUCTION =>
                return PRIORITY_ILLEGAL;
            when EXC_PRIVILEGE_VIOLATION =>
                return PRIORITY_PRIVILEGE;
            when EXC_FP_PROTOCOL_VIOLATION =>
                return PRIORITY_FP_PROTOCOL;
            when EXC_FP_EXCEPTION =>
                return PRIORITY_FP_EXCEPTION;
            when EXC_CHK =>
                return PRIORITY_CHK;
            when EXC_TRAP | EXC_TRAPV =>
                return PRIORITY_TRAP;
            when EXC_DIVIDE_BY_ZERO =>
                return PRIORITY_DIVIDE_BY_ZERO;
            when others =>
                return x"F";  -- Lowest priority
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Get exception vector from exception type
    ------------------------------------------------------------------------------
    function get_exception_vector(exc_type : exception_type_t; trap_num : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        case exc_type is
            when EXC_RESET =>
                return VECTOR_RESET_PC;
            when EXC_BUS_ERROR =>
                return VECTOR_BUS_ERROR;
            when EXC_ADDRESS_ERROR =>
                return VECTOR_ADDRESS_ERROR;
            when EXC_ILLEGAL_INSTRUCTION =>
                return VECTOR_ILLEGAL_INSTRUCTION;
            when EXC_DIVIDE_BY_ZERO =>
                return VECTOR_DIVIDE_BY_ZERO;
            when EXC_CHK =>
                return VECTOR_CHK;
            when EXC_TRAPV =>
                return VECTOR_TRAPV;
            when EXC_PRIVILEGE_VIOLATION =>
                return VECTOR_PRIVILEGE_VIOLATION;
            when EXC_TRACE =>
                return VECTOR_TRACE;
            when EXC_LINE_A =>
                return VECTOR_LINE_A;
            when EXC_LINE_F =>
                return VECTOR_LINE_F;
            when EXC_FP_PROTOCOL_VIOLATION =>
                return VECTOR_FP_PROTOCOL;
            when EXC_FORMAT_ERROR =>
                return VECTOR_FORMAT_ERROR;
            when EXC_UNINITIALIZED_INT =>
                return VECTOR_UNINITIALIZED_INT;
            when EXC_SPURIOUS_INT =>
                return VECTOR_SPURIOUS_INT;
            when EXC_INTERRUPT_L1 =>
                return VECTOR_INTERRUPT_L1;
            when EXC_INTERRUPT_L2 =>
                return VECTOR_INTERRUPT_L2;
            when EXC_INTERRUPT_L3 =>
                return VECTOR_INTERRUPT_L3;
            when EXC_INTERRUPT_L4 =>
                return VECTOR_INTERRUPT_L4;
            when EXC_INTERRUPT_L5 =>
                return VECTOR_INTERRUPT_L5;
            when EXC_INTERRUPT_L6 =>
                return VECTOR_INTERRUPT_L6;
            when EXC_INTERRUPT_L7 =>
                return VECTOR_INTERRUPT_L7;
            when EXC_TRAP =>
                -- TRAP #0-15 are vectors 0x20-0x2F
                return std_logic_vector(unsigned(VECTOR_TRAP_BASE) + unsigned(trap_num));
            when others =>
                return x"00";
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Get stack frame format from exception type
    ------------------------------------------------------------------------------
    function get_frame_format(exc_type : exception_type_t) return stack_frame_format_t is
    begin
        case exc_type is
            when EXC_BUS_ERROR | EXC_ADDRESS_ERROR =>
                return FRAME_FORMAT_7;  -- 30-word access error frame
            when EXC_ILLEGAL_INSTRUCTION | EXC_PRIVILEGE_VIOLATION =>
                return FRAME_FORMAT_2;  -- 6-word instruction exception frame
            when others =>
                return FRAME_FORMAT_0;  -- 4-word normal frame
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Get frame size in bytes
    ------------------------------------------------------------------------------
    function get_frame_size(format : stack_frame_format_t) return natural is
    begin
        case format is
            when FRAME_FORMAT_0 | FRAME_FORMAT_1 =>
                return 8;   -- 4 words = 8 bytes
            when FRAME_FORMAT_2 =>
                return 12;  -- 6 words = 12 bytes
            when FRAME_FORMAT_7 =>
                return 60;  -- 30 words = 60 bytes
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Check if exception is an interrupt
    ------------------------------------------------------------------------------
    function is_interrupt(exc_type : exception_type_t) return boolean is
    begin
        case exc_type is
            when EXC_INTERRUPT_L1 | EXC_INTERRUPT_L2 | EXC_INTERRUPT_L3 | EXC_INTERRUPT_L4 |
                 EXC_INTERRUPT_L5 | EXC_INTERRUPT_L6 | EXC_INTERRUPT_L7 =>
                return true;
            when others =>
                return false;
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Get interrupt level from exception type (1-7)
    ------------------------------------------------------------------------------
    function get_interrupt_level(exc_type : exception_type_t) return std_logic_vector is
    begin
        case exc_type is
            when EXC_INTERRUPT_L1 => return "001";
            when EXC_INTERRUPT_L2 => return "010";
            when EXC_INTERRUPT_L3 => return "011";
            when EXC_INTERRUPT_L4 => return "100";
            when EXC_INTERRUPT_L5 => return "101";
            when EXC_INTERRUPT_L6 => return "110";
            when EXC_INTERRUPT_L7 => return "111";
            when others           => return "000";
        end case;
    end function;

    ------------------------------------------------------------------------------
    -- Pack status register to 16-bit word
    ------------------------------------------------------------------------------
    function pack_sr(sr : status_register_t) return std_logic_vector is
        variable result : std_logic_vector(15 downto 0);
    begin
        result := (others => '0');
        result(15) := sr.trace_t1;
        result(14) := sr.trace_t0;
        result(13) := sr.supervisor_mode;
        result(10 downto 8) := sr.interrupt_mask;
        result(4) := sr.condition_x;
        result(3) := sr.condition_n;
        result(2) := sr.condition_z;
        result(1) := sr.condition_v;
        result(0) := sr.condition_c;
        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Unpack 16-bit word to status register
    ------------------------------------------------------------------------------
    function unpack_sr(data : std_logic_vector(15 downto 0)) return status_register_t is
        variable result : status_register_t;
    begin
        result.trace_t1        := data(15);
        result.trace_t0        := data(14);
        result.supervisor_mode := data(13);
        result.interrupt_mask  := data(10 downto 8);
        result.condition_x     := data(4);
        result.condition_n     := data(3);
        result.condition_z     := data(2);
        result.condition_v     := data(1);
        result.condition_c     := data(0);
        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Create format/vector word for stack frame
    ------------------------------------------------------------------------------
    function create_format_vector_word(format : stack_frame_format_t; vector : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable result : std_logic_vector(15 downto 0);
        variable format_bits : std_logic_vector(3 downto 0);
    begin
        -- Get format bits
        case format is
            when FRAME_FORMAT_0 => format_bits := x"0";
            when FRAME_FORMAT_1 => format_bits := x"1";
            when FRAME_FORMAT_2 => format_bits := x"2";
            when FRAME_FORMAT_7 => format_bits := x"7";
        end case;

        -- Build format/vector word
        result(15 downto 12) := format_bits;
        result(11 downto 4) := vector;  -- Vector number (8 bits)
        result(3 downto 0) := x"0";     -- Reserved
        return result;
    end function;

    ------------------------------------------------------------------------------
    -- Compare exception priorities
    ------------------------------------------------------------------------------
    function exception_has_higher_priority(exc_a : exception_info_t; exc_b : exception_info_t) return boolean is
    begin
        -- Invalid exceptions have lowest priority
        if exc_a.valid = '0' then
            return false;
        elsif exc_b.valid = '0' then
            return true;
        end if;

        -- Compare priority values (lower number = higher priority)
        return unsigned(exc_a.priority) < unsigned(exc_b.priority);
    end function;

end package body TG68040_Exception_Pack;
