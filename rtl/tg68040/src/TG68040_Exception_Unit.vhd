------------------------------------------------------------------------------
-- TG68040 Exception Unit
--
-- Implements MC68040 exception processing including:
-- - Stack frame creation (Format 0, 2, 7)
-- - VBR-based vector lookup
-- - PC/SR save to stack
-- - Mode switching (user → supervisor)
-- - Exception entry FSM
--
-- Copyright (c) 2025 Claude AI (Anthropic)
-- Based on MC68040 User's Manual, Chapter 6: Exception Processing
--
-- LGPL v3
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Exception_Pack.all;

entity TG68040_Exception_Unit is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Exception input
        exception_in   : in exception_info_t;           -- Exception to process
        exception_ack  : out std_logic;                 -- Exception acknowledged

        -- Control registers
        vbr            : in std_logic_vector(31 downto 0);   -- Vector Base Register
        ssp            : in std_logic_vector(31 downto 0);   -- Supervisor Stack Pointer
        ssp_out        : out std_logic_vector(31 downto 0);  -- Updated SSP
        ssp_write      : out std_logic;                      -- Write SSP

        -- Status register input/output
        sr_in          : in status_register_t;          -- Current SR
        sr_out         : out status_register_t;         -- Updated SR
        sr_write       : out std_logic;                 -- Write SR

        -- Memory interface for stack writes
        mem_req        : out std_logic;                 -- Memory request
        mem_write      : out std_logic;                 -- Write enable
        mem_addr       : out std_logic_vector(31 downto 0);  -- Address
        mem_data       : out std_logic_vector(31 downto 0);  -- Data to write
        mem_ready      : in std_logic;                  -- Memory ready

        -- PC output
        handler_pc     : out std_logic_vector(31 downto 0);  -- Exception handler PC
        handler_valid  : out std_logic;                      -- Handler PC is valid

        -- Pipeline control
        pipeline_flush : out std_logic;                 -- Flush pipeline

        -- Statistics
        exceptions_processed : out std_logic_vector(31 downto 0)
    );
end TG68040_Exception_Unit;

architecture rtl of TG68040_Exception_Unit is

    -- Exception entry state machine
    type exc_state_t is (
        IDLE,                   -- No exception
        SAVE_SR,                -- Save SR to stack (word 0)
        SAVE_PC,                -- Save PC to stack (word 1)
        SAVE_FORMAT_VECTOR,     -- Save format/vector word (word 2)
        SAVE_FAULT_ADDR,        -- Save fault address (Format 7, word 3)
        FETCH_VECTOR,           -- Fetch handler address from vector table
        UPDATE_REGS,            -- Update SR and SSP
        COMPLETE                -- Exception entry complete
    );

    signal state : exc_state_t := IDLE;
    signal next_state : exc_state_t;

    -- Exception being processed
    signal current_exception : exception_info_t := EXCEPTION_INFO_NONE;

    -- Stack pointer tracking
    signal ssp_current : unsigned(31 downto 0);
    signal ssp_offset : unsigned(31 downto 0);

    -- Stack frame information
    signal frame_size : natural;
    signal words_written : natural;

    -- Memory write control
    signal mem_write_pending : std_logic;
    signal mem_addr_reg : std_logic_vector(31 downto 0);
    signal mem_data_reg : std_logic_vector(31 downto 0);

    -- Vector address
    signal vector_addr : std_logic_vector(31 downto 0);
    signal handler_pc_reg : std_logic_vector(31 downto 0);

    -- Updated status register
    signal sr_new : status_register_t;

    -- Statistics
    signal exception_count : unsigned(31 downto 0) := (others => '0');

begin

    ------------------------------------------------------------------------------
    -- Exception Entry State Machine
    ------------------------------------------------------------------------------
    exception_fsm: process(clk)
        variable format_vector_word : std_logic_vector(15 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                current_exception <= EXCEPTION_INFO_NONE;
                ssp_current <= unsigned(ssp);
                words_written <= 0;
                mem_write_pending <= '0';
                handler_valid <= '0';
                exception_ack <= '0';
                pipeline_flush <= '0';
                sr_write <= '0';
                ssp_write <= '0';
                exception_count <= (others => '0');

            else
                -- Default outputs
                exception_ack <= '0';
                handler_valid <= '0';
                pipeline_flush <= '0';
                sr_write <= '0';
                ssp_write <= '0';

                case state is
                    when IDLE =>
                        -- Wait for exception
                        if exception_in.valid = '1' then
                            -- Latch exception
                            current_exception <= exception_in;
                            exception_ack <= '1';

                            -- Calculate frame size
                            frame_size <= get_frame_size(exception_in.frame_format);

                            -- Initialize SSP (pre-decrement for stack writes)
                            ssp_current <= unsigned(ssp);
                            words_written <= 0;

                            -- Flush pipeline immediately
                            pipeline_flush <= '1';

                            -- Start saving to stack
                            state <= SAVE_SR;
                        end if;

                    when SAVE_SR =>
                        -- Save Status Register to stack
                        -- SSP is pre-decremented (SSP = SSP - 2 for word write)
                        ssp_current <= ssp_current - 2;
                        mem_addr_reg <= std_logic_vector(ssp_current - 2);
                        mem_data_reg <= x"0000" & current_exception.fault_sr;  -- SR is 16-bit, pad to 32
                        mem_write_pending <= '1';
                        words_written <= words_written + 1;
                        state <= SAVE_PC;

                    when SAVE_PC =>
                        -- Save PC to stack (longword)
                        if mem_ready = '1' and mem_write_pending = '1' then
                            mem_write_pending <= '0';
                            ssp_current <= ssp_current - 4;
                            mem_addr_reg <= std_logic_vector(ssp_current - 4);
                            mem_data_reg <= current_exception.fault_pc;
                            mem_write_pending <= '1';
                            words_written <= words_written + 1;
                            state <= SAVE_FORMAT_VECTOR;
                        end if;

                    when SAVE_FORMAT_VECTOR =>
                        -- Save format/vector word
                        if mem_ready = '1' and mem_write_pending = '1' then
                            mem_write_pending <= '0';
                            ssp_current <= ssp_current - 2;
                            mem_addr_reg <= std_logic_vector(ssp_current - 2);

                            -- Create format/vector word
                            format_vector_word := create_format_vector_word(
                                current_exception.frame_format,
                                current_exception.vector
                            );
                            mem_data_reg <= x"0000" & format_vector_word;
                            mem_write_pending <= '1';
                            words_written <= words_written + 1;

                            -- Check if we need to save fault address (Format 7)
                            if current_exception.frame_format = FRAME_FORMAT_7 then
                                state <= SAVE_FAULT_ADDR;
                            else
                                state <= FETCH_VECTOR;
                            end if;
                        end if;

                    when SAVE_FAULT_ADDR =>
                        -- Save fault address for Format 7 (access error frame)
                        if mem_ready = '1' and mem_write_pending = '1' then
                            mem_write_pending <= '0';
                            ssp_current <= ssp_current - 4;
                            mem_addr_reg <= std_logic_vector(ssp_current - 4);
                            mem_data_reg <= current_exception.fault_addr;
                            mem_write_pending <= '1';
                            words_written <= words_written + 1;
                            state <= FETCH_VECTOR;
                        end if;

                    when FETCH_VECTOR =>
                        -- Calculate vector address: VBR + (vector × 4)
                        if mem_ready = '1' and mem_write_pending = '1' then
                            mem_write_pending <= '0';

                            -- Vector address = VBR + (vector number × 4)
                            vector_addr <= std_logic_vector(
                                unsigned(vbr) +
                                (unsigned(current_exception.vector) & "00")  -- Multiply by 4
                            );

                            -- For baseline implementation, use a simple stub handler address
                            -- Real implementation would read from memory at vector_addr
                            -- For now: handler = VBR + (vector × 4) + 0x1000 (stub offset)
                            handler_pc_reg <= std_logic_vector(
                                unsigned(vbr) +
                                (unsigned(current_exception.vector) & "00") +
                                x"00001000"  -- Stub: handlers at VBR + 0x1000 + vector offset
                            );

                            state <= UPDATE_REGS;
                        end if;

                    when UPDATE_REGS =>
                        -- Update Status Register and Stack Pointer
                        -- SR changes:
                        -- - Set supervisor mode
                        -- - Clear trace bits (disable tracing during exception)
                        -- - Update interrupt mask (for interrupts)

                        sr_new <= sr_in;
                        sr_new.supervisor_mode <= '1';  -- Enter supervisor mode
                        sr_new.trace_t1 <= '0';         -- Clear trace T1
                        sr_new.trace_t0 <= '0';         -- Clear trace T0

                        -- For interrupts, update interrupt mask
                        if is_interrupt(current_exception.exc_type) then
                            sr_new.interrupt_mask <= get_interrupt_level(current_exception.exc_type);
                        end if;

                        sr_out <= sr_new;
                        sr_write <= '1';

                        -- Update SSP
                        ssp_out <= std_logic_vector(ssp_current);
                        ssp_write <= '1';

                        state <= COMPLETE;

                    when COMPLETE =>
                        -- Exception entry complete
                        -- Output handler PC
                        handler_pc <= handler_pc_reg;
                        handler_valid <= '1';

                        -- Increment statistics
                        exception_count <= exception_count + 1;

                        -- Return to IDLE
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Memory Interface
    ------------------------------------------------------------------------------
    mem_req <= mem_write_pending;
    mem_write <= mem_write_pending;
    mem_addr <= mem_addr_reg;
    mem_data <= mem_data_reg;

    ------------------------------------------------------------------------------
    -- Statistics Output
    ------------------------------------------------------------------------------
    exceptions_processed <= std_logic_vector(exception_count);

end architecture rtl;
