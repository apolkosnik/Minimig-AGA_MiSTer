------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Cache Operations (CINV/CPUSH)                                   --
--                                                                          --
-- Implements MC68040 cache control instructions                           --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- CINV - Cache Invalidate
-- Invalidates cache entries without writing back (data loss if modified)
--
-- CPUSH - Cache Push
-- Writes back modified cache lines to memory, then invalidates
--
-- Scope:
-- - LINE: Single cache line containing specified address
-- - PAGE: All lines in 4KB page
-- - ALL: Entire cache
--
-- Cache selector:
-- - DC: Data cache
-- - IC: Instruction cache
-- - BC: Both caches (supervisor only)
--
-- NOTE: Phase 2 implementation is a stub. Sets control signals for
--       future cache controller (Phase 5-7). No actual cache manipulation yet.
--
-- Version: 0.1 (Phase 2 - Stub)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;

entity TG68040_CacheOps is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Control
        enable         : in std_logic;                          -- Start cache operation
        operation      : in cache_op_type_t;                    -- INV or PUSH
        scope          : in cache_op_scope_t;                   -- LINE, PAGE, or ALL
        cache_sel      : in cache_select_t;                     -- DATA, INSN, or BOTH
        address        : in std_logic_vector(31 downto 0);     -- Address for LINE/PAGE ops
        supervisor     : in std_logic;                          -- Supervisor mode

        -- Cache controller interface (future - Phase 5-7)
        cache_op_ctrl  : out cache_op_ctrl_t;                   -- Control to cache
        cache_op_done  : in std_logic;                          -- Operation complete from cache

        -- Status
        done           : out std_logic;                         -- Operation complete
        privilege_err  : out std_logic;                         -- Privilege violation
        busy           : out std_logic                          -- Operation in progress
    );
end TG68040_CacheOps;

architecture rtl of TG68040_CacheOps is

    -- State machine
    type state_t is (
        IDLE,
        CHECK_PRIV,
        ISSUE_OP,
        WAIT_DONE,
        DONE_STATE,
        ERROR_STATE
    );
    signal state : state_t;

    -- Internal signals
    signal op_valid : std_logic;

begin

    -- Main state machine
    process(clk, reset)
    begin
        if reset = '1' then
            state <= IDLE;
            cache_op_ctrl.enable <= '0';
            cache_op_ctrl.op_type <= CACHE_OP_NONE;
            cache_op_ctrl.scope <= SCOPE_LINE;
            cache_op_ctrl.cache_sel <= CACHE_SEL_DATA;
            cache_op_ctrl.address <= (others => '0');
            done <= '0';
            privilege_err <= '0';
            busy <= '0';
            op_valid <= '0';

        elsif rising_edge(clk) then
            -- Default outputs
            cache_op_ctrl.enable <= '0';
            done <= '0';
            privilege_err <= '0';

            case state is
                when IDLE =>
                    busy <= '0';
                    if enable = '1' then
                        busy <= '1';
                        state <= CHECK_PRIV;

                        -- Latch operation parameters
                        cache_op_ctrl.op_type <= operation;
                        cache_op_ctrl.scope <= scope;
                        cache_op_ctrl.cache_sel <= cache_sel;
                        cache_op_ctrl.address <= address;
                    end if;

                when CHECK_PRIV =>
                    -- Cache operations are supervisor only
                    if supervisor = '0' then
                        state <= ERROR_STATE;
                    else
                        -- Check for valid cache selector
                        -- BOTH caches is only allowed in supervisor mode (always ok here)
                        state <= ISSUE_OP;
                    end if;

                when ISSUE_OP =>
                    -- Issue operation to cache controller
                    cache_op_ctrl.enable <= '1';

                    -- For Phase 2 stub: immediately complete
                    -- In Phase 5-7: wait for cache_op_done signal
                    if cache_op_done = '1' then
                        state <= DONE_STATE;
                    else
                        -- Stub: complete immediately
                        state <= DONE_STATE;
                    end if;

                when WAIT_DONE =>
                    -- Wait for cache operation to complete
                    -- (Used in Phase 5-7 when actual cache operations implemented)
                    if cache_op_done = '1' then
                        state <= DONE_STATE;
                    end if;

                when DONE_STATE =>
                    done <= '1';
                    busy <= '0';
                    state <= IDLE;

                when ERROR_STATE =>
                    privilege_err <= '1';
                    busy <= '0';
                    state <= IDLE;

            end case;
        end if;
    end process;

end rtl;
