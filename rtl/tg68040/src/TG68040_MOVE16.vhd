------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 MOVE16 Instruction Implementation                               --
--                                                                          --
-- Implements the MC68040 MOVE16 instruction (16-byte block move)          --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- The MOVE16 instruction moves 16 bytes (one cache line) between memory
-- locations. It requires 16-byte address alignment and operates atomically.
--
-- Addressing modes:
-- - (An)+, (xxx).L - Postincrement source
-- - (xxx).L, (An)+ - Postincrement destination
-- - (An), (xxx).L  - No postincrement
-- - (xxx).L, (An)  - No postincrement
--
-- Timing: Transfers 16 bytes as 4 consecutive longword operations
-- (Phase 2 simple implementation - burst transfers in Phase 13)
--
-- Version: 0.1 (Phase 2)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;

entity TG68040_MOVE16 is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Control
        enable         : in std_logic;                          -- Start MOVE16 operation
        mode           : in move16_mode_t;                      -- Addressing mode
        reg_num        : in std_logic_vector(2 downto 0);      -- Register number (An)
        abs_addr       : in std_logic_vector(31 downto 0);     -- Absolute address

        -- Register file interface
        reg_data_in    : in std_logic_vector(31 downto 0);     -- Register value (An)
        reg_data_out   : out std_logic_vector(31 downto 0);    -- Updated register (for postincrement)
        reg_write_en   : out std_logic;                         -- Write enable for register update

        -- Memory interface
        mem_addr       : out std_logic_vector(31 downto 0);    -- Memory address
        mem_data_write : out std_logic_vector(31 downto 0);    -- Data to write
        mem_data_read  : in std_logic_vector(31 downto 0);     -- Data read
        mem_write      : out std_logic;                         -- Write enable
        mem_read       : out std_logic;                         -- Read enable
        mem_ready      : in std_logic;                          -- Memory operation complete

        -- Status
        done           : out std_logic;                         -- Operation complete
        addr_error     : out std_logic;                         -- Address alignment error
        busy           : out std_logic                          -- Operation in progress
    );
end TG68040_MOVE16;

architecture rtl of TG68040_MOVE16 is

    -- State machine
    type state_t is (
        IDLE,
        CHECK_ALIGN,
        CALC_ADDR,
        TRANSFER_0,     -- Transfer longword 0 (bytes 0-3)
        TRANSFER_1,     -- Transfer longword 1 (bytes 4-7)
        TRANSFER_2,     -- Transfer longword 2 (bytes 8-11)
        TRANSFER_3,     -- Transfer longword 3 (bytes 12-15)
        UPDATE_REG,
        DONE_STATE,
        ERROR_STATE
    );
    signal state : state_t;

    -- Internal registers
    signal source_addr : std_logic_vector(31 downto 0);
    signal dest_addr   : std_logic_vector(31 downto 0);
    signal transfer_count : integer range 0 to 3;
    signal buffer_0 : std_logic_vector(31 downto 0);
    signal buffer_1 : std_logic_vector(31 downto 0);
    signal buffer_2 : std_logic_vector(31 downto 0);
    signal buffer_3 : std_logic_vector(31 downto 0);
    signal do_postinc : std_logic;
    signal source_is_reg : std_logic;  -- 1 if source uses An, 0 if dest uses An

begin

    -- State machine
    process(clk, reset)
    begin
        if reset = '1' then
            state <= IDLE;
            source_addr <= (others => '0');
            dest_addr <= (others => '0');
            transfer_count <= 0;
            buffer_0 <= (others => '0');
            buffer_1 <= (others => '0');
            buffer_2 <= (others => '0');
            buffer_3 <= (others => '0');
            do_postinc <= '0';
            source_is_reg <= '0';
            reg_data_out <= (others => '0');
            reg_write_en <= '0';
            mem_addr <= (others => '0');
            mem_data_write <= (others => '0');
            mem_write <= '0';
            mem_read <= '0';
            done <= '0';
            addr_error <= '0';
            busy <= '0';

        elsif rising_edge(clk) then
            -- Default outputs
            reg_write_en <= '0';
            mem_write <= '0';
            mem_read <= '0';
            done <= '0';
            addr_error <= '0';

            case state is
                when IDLE =>
                    busy <= '0';
                    if enable = '1' then
                        busy <= '1';
                        transfer_count <= 0;

                        -- Determine source and destination addresses based on mode
                        case mode is
                            when MOVE16_AN_INC_TO_ABS =>
                                source_addr <= reg_data_in;
                                dest_addr <= abs_addr;
                                do_postinc <= '1';
                                source_is_reg <= '1';

                            when MOVE16_ABS_TO_AN_INC =>
                                source_addr <= abs_addr;
                                dest_addr <= reg_data_in;
                                do_postinc <= '1';
                                source_is_reg <= '0';

                            when MOVE16_AN_TO_ABS =>
                                source_addr <= reg_data_in;
                                dest_addr <= abs_addr;
                                do_postinc <= '0';
                                source_is_reg <= '1';

                            when MOVE16_ABS_TO_AN =>
                                source_addr <= abs_addr;
                                dest_addr <= reg_data_in;
                                do_postinc <= '0';
                                source_is_reg <= '0';
                        end case;

                        state <= CHECK_ALIGN;
                    end if;

                when CHECK_ALIGN =>
                    -- Check both addresses are 16-byte aligned
                    if is_aligned_16(source_addr) and is_aligned_16(dest_addr) then
                        state <= TRANSFER_0;
                        mem_addr <= source_addr;
                        mem_read <= '1';
                    else
                        -- Address error - misaligned
                        state <= ERROR_STATE;
                    end if;

                when TRANSFER_0 =>
                    -- Read first longword from source
                    if mem_ready = '1' then
                        buffer_0 <= mem_data_read;
                        state <= TRANSFER_1;
                        mem_addr <= std_logic_vector(unsigned(source_addr) + 4);
                        mem_read <= '1';
                    else
                        mem_addr <= source_addr;
                        mem_read <= '1';
                    end if;

                when TRANSFER_1 =>
                    -- Read second longword from source
                    if mem_ready = '1' then
                        buffer_1 <= mem_data_read;
                        state <= TRANSFER_2;
                        mem_addr <= std_logic_vector(unsigned(source_addr) + 8);
                        mem_read <= '1';
                    else
                        mem_addr <= std_logic_vector(unsigned(source_addr) + 4);
                        mem_read <= '1';
                    end if;

                when TRANSFER_2 =>
                    -- Read third longword from source
                    if mem_ready = '1' then
                        buffer_2 <= mem_data_read;
                        state <= TRANSFER_3;
                        mem_addr <= std_logic_vector(unsigned(source_addr) + 12);
                        mem_read <= '1';
                    else
                        mem_addr <= std_logic_vector(unsigned(source_addr) + 8);
                        mem_read <= '1';
                    end if;

                when TRANSFER_3 =>
                    -- Read fourth longword from source, then start writing
                    if mem_ready = '1' then
                        buffer_3 <= mem_data_read;
                        -- Now write all 4 longwords to destination
                        transfer_count <= 0;
                        state <= CALC_ADDR;
                    else
                        mem_addr <= std_logic_vector(unsigned(source_addr) + 12);
                        mem_read <= '1';
                    end if;

                when CALC_ADDR =>
                    -- Calculate write address and write data
                    case transfer_count is
                        when 0 =>
                            mem_addr <= dest_addr;
                            mem_data_write <= buffer_0;
                            mem_write <= '1';
                        when 1 =>
                            mem_addr <= std_logic_vector(unsigned(dest_addr) + 4);
                            mem_data_write <= buffer_1;
                            mem_write <= '1';
                        when 2 =>
                            mem_addr <= std_logic_vector(unsigned(dest_addr) + 8);
                            mem_data_write <= buffer_2;
                            mem_write <= '1';
                        when 3 =>
                            mem_addr <= std_logic_vector(unsigned(dest_addr) + 12);
                            mem_data_write <= buffer_3;
                            mem_write <= '1';
                    end case;

                    -- Wait for write to complete
                    if mem_ready = '1' then
                        if transfer_count < 3 then
                            transfer_count <= transfer_count + 1;
                        else
                            -- All transfers complete
                            if do_postinc = '1' then
                                state <= UPDATE_REG;
                            else
                                state <= DONE_STATE;
                            end if;
                        end if;
                    end if;

                when UPDATE_REG =>
                    -- Update register with postincrement (+16)
                    if source_is_reg = '1' then
                        reg_data_out <= std_logic_vector(unsigned(source_addr) + 16);
                    else
                        reg_data_out <= std_logic_vector(unsigned(dest_addr) + 16);
                    end if;
                    reg_write_en <= '1';
                    state <= DONE_STATE;

                when DONE_STATE =>
                    done <= '1';
                    busy <= '0';
                    state <= IDLE;

                when ERROR_STATE =>
                    addr_error <= '1';
                    busy <= '0';
                    state <= IDLE;

            end case;
        end if;
    end process;

end rtl;
