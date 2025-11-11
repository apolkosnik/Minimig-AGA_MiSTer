------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Bus Arbiter                                                     --
--                                                                          --
-- Arbitrates between multiple bus masters:                                --
--   1. MMU (page table walks) - highest priority                          --
--   2. CPU Data Access - high priority                                    --
--   3. CPU Instruction Fetch - medium priority                            --
--   4. Cache Fills (burst) - lowest priority                              --
--                                                                          --
-- Features:                                                                --
--   - Fixed priority arbitration                                          --
--   - Fair access (prevents starvation)                                   --
--   - Burst atomicity (once started, completes)                           --
--   - Grant/acknowledge protocol                                          --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_BusArbiter is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -----------------------------------------------------
        -- Request inputs from bus masters
        -----------------------------------------------------
        -- MMU (highest priority)
        mmu_req     : in  std_logic;                      -- MMU table walk request
        mmu_grant   : out std_logic;                      -- Grant to MMU
        mmu_done    : in  std_logic;                      -- MMU cycle complete

        -- CPU Data
        cpu_data_req  : in  std_logic;                    -- CPU data access request
        cpu_data_grant: out std_logic;                    -- Grant to CPU data
        cpu_data_done : in  std_logic;                    -- CPU data cycle complete

        -- CPU Instruction
        cpu_inst_req  : in  std_logic;                    -- CPU instruction fetch request
        cpu_inst_grant: out std_logic;                    -- Grant to CPU instruction
        cpu_inst_done : in  std_logic;                    -- CPU instruction cycle complete

        -- I-Cache Fill
        icache_req    : in  std_logic;                    -- I-Cache fill request
        icache_grant  : out std_logic;                    -- Grant to I-Cache
        icache_done   : in  std_logic;                    -- I-Cache fill complete

        -- D-Cache Fill
        dcache_req    : in  std_logic;                    -- D-Cache fill request
        dcache_grant  : out std_logic;                    -- Grant to D-Cache
        dcache_done   : in  std_logic;                    -- D-Cache fill complete

        -----------------------------------------------------
        -- Bus status
        -----------------------------------------------------
        bus_busy      : out std_logic;                    -- Bus currently granted
        burst_active  : in  std_logic                     -- Burst in progress (no preempt)
    );
end entity TG68K030_BusArbiter;

architecture rtl of TG68K030_BusArbiter is

    -- Bus master enumeration
    type bus_master_t is (
        MASTER_NONE,      -- No master
        MASTER_MMU,       -- MMU table walk
        MASTER_CPU_DATA,  -- CPU data access
        MASTER_CPU_INST,  -- CPU instruction fetch
        MASTER_ICACHE,    -- I-Cache fill
        MASTER_DCACHE     -- D-Cache fill
    );

    signal current_master : bus_master_t;
    signal next_master    : bus_master_t;

    -- Fairness counters (prevent starvation)
    signal cpu_inst_wait_count : unsigned(3 downto 0);  -- Cycles waiting
    signal icache_wait_count   : unsigned(3 downto 0);
    signal dcache_wait_count   : unsigned(3 downto 0);

    -- Fairness thresholds
    constant CPU_INST_THRESHOLD : unsigned(3 downto 0) := to_unsigned(8, 4);
    constant CACHE_THRESHOLD    : unsigned(3 downto 0) := to_unsigned(12, 4);

    -- Request latched flags (to prevent starvation)
    signal cpu_inst_pending : std_logic;
    signal icache_pending   : std_logic;
    signal dcache_pending   : std_logic;

begin

    --------------------------------------------------------------
    -- Bus Arbiter State Machine
    --------------------------------------------------------------
    arbiter_fsm: process(clk, reset)
    begin
        if reset = '1' then
            current_master <= MASTER_NONE;
            cpu_inst_wait_count <= (others => '0');
            icache_wait_count   <= (others => '0');
            dcache_wait_count   <= (others => '0');
            cpu_inst_pending    <= '0';
            icache_pending      <= '0';
            dcache_pending      <= '0';

        elsif rising_edge(clk) then

            -- Latch pending requests
            if cpu_inst_req = '1' then
                cpu_inst_pending <= '1';
            end if;
            if icache_req = '1' then
                icache_pending <= '1';
            end if;
            if dcache_req = '1' then
                dcache_pending <= '1';
            end if;

            -- Check if current master is done
            case current_master is
                when MASTER_MMU =>
                    if mmu_done = '1' then
                        current_master <= MASTER_NONE;
                        -- Reset wait counters on bus release
                        cpu_inst_wait_count <= (others => '0');
                        icache_wait_count   <= (others => '0');
                        dcache_wait_count   <= (others => '0');
                    end if;

                when MASTER_CPU_DATA =>
                    if cpu_data_done = '1' then
                        current_master <= MASTER_NONE;
                        cpu_inst_wait_count <= (others => '0');
                        icache_wait_count   <= (others => '0');
                        dcache_wait_count   <= (others => '0');
                    end if;

                when MASTER_CPU_INST =>
                    if cpu_inst_done = '1' then
                        current_master   <= MASTER_NONE;
                        cpu_inst_pending <= '0';
                        cpu_inst_wait_count <= (others => '0');
                    end if;

                when MASTER_ICACHE =>
                    if icache_done = '1' then
                        current_master <= MASTER_NONE;
                        icache_pending <= '0';
                        icache_wait_count <= (others => '0');
                    end if;

                when MASTER_DCACHE =>
                    if dcache_done = '1' then
                        current_master <= MASTER_NONE;
                        dcache_pending <= '0';
                        dcache_wait_count <= (others => '0');
                    end if;

                when MASTER_NONE =>
                    -- Bus is free, select next master
                    current_master <= next_master;

                    -- Clear pending flag for granted master
                    if next_master = MASTER_CPU_INST then
                        cpu_inst_pending <= '0';
                    elsif next_master = MASTER_ICACHE then
                        icache_pending <= '0';
                    elsif next_master = MASTER_DCACHE then
                        dcache_pending <= '0';
                    end if;

            end case;

            -- Increment wait counters for pending low-priority requests
            if current_master /= MASTER_NONE and current_master /= MASTER_CPU_INST then
                if cpu_inst_pending = '1' and cpu_inst_wait_count < CPU_INST_THRESHOLD then
                    cpu_inst_wait_count <= cpu_inst_wait_count + 1;
                end if;
            end if;

            if current_master /= MASTER_NONE and current_master /= MASTER_ICACHE then
                if icache_pending = '1' and icache_wait_count < CACHE_THRESHOLD then
                    icache_wait_count <= icache_wait_count + 1;
                end if;
            end if;

            if current_master /= MASTER_NONE and current_master /= MASTER_DCACHE then
                if dcache_pending = '1' and dcache_wait_count < CACHE_THRESHOLD then
                    dcache_wait_count <= dcache_wait_count + 1;
                end if;
            end if;

        end if;
    end process;

    --------------------------------------------------------------
    -- Priority Arbiter (Combinational)
    --------------------------------------------------------------
    priority_arbiter: process(mmu_req, cpu_data_req, cpu_inst_req, cpu_inst_pending,
                              icache_req, icache_pending, icache_wait_count,
                              dcache_req, dcache_pending, dcache_wait_count,
                              cpu_inst_wait_count, burst_active)
    begin
        -- Default: no master selected
        next_master <= MASTER_NONE;

        -- Priority 1: MMU (always highest)
        if mmu_req = '1' then
            next_master <= MASTER_MMU;

        -- Priority 2: CPU Data (performance critical)
        elsif cpu_data_req = '1' then
            next_master <= MASTER_CPU_DATA;

        -- Priority 3: CPU Instruction (fairness check)
        -- If instruction fetch has been waiting too long, boost priority
        elsif (cpu_inst_req = '1' or cpu_inst_pending = '1') and
              (cpu_inst_wait_count >= CPU_INST_THRESHOLD or
               (cpu_inst_req = '1' and icache_req = '0' and dcache_req = '0')) then
            next_master <= MASTER_CPU_INST;

        -- Priority 4: I-Cache Fill (fairness check)
        elsif (icache_req = '1' or icache_pending = '1') and
              icache_wait_count >= CACHE_THRESHOLD then
            next_master <= MASTER_ICACHE;

        -- Priority 5: D-Cache Fill (fairness check)
        elsif (dcache_req = '1' or dcache_pending = '1') and
              dcache_wait_count >= CACHE_THRESHOLD then
            next_master <= MASTER_DCACHE;

        -- Priority 6: CPU Instruction (normal priority)
        elsif cpu_inst_req = '1' or cpu_inst_pending = '1' then
            next_master <= MASTER_CPU_INST;

        -- Priority 7: I-Cache Fill (normal priority)
        elsif icache_req = '1' or icache_pending = '1' then
            -- Only grant if no burst active (bursts are atomic)
            if burst_active = '0' then
                next_master <= MASTER_ICACHE;
            end if;

        -- Priority 8: D-Cache Fill (lowest priority)
        elsif dcache_req = '1' or dcache_pending = '1' then
            if burst_active = '0' then
                next_master <= MASTER_DCACHE;
            end if;

        end if;
    end process;

    --------------------------------------------------------------
    -- Grant Signal Generation
    --------------------------------------------------------------
    grant_gen: process(current_master)
    begin
        -- Default: no grants
        mmu_grant      <= '0';
        cpu_data_grant <= '0';
        cpu_inst_grant <= '0';
        icache_grant   <= '0';
        dcache_grant   <= '0';

        -- Assert grant for current master
        case current_master is
            when MASTER_MMU =>
                mmu_grant <= '1';

            when MASTER_CPU_DATA =>
                cpu_data_grant <= '1';

            when MASTER_CPU_INST =>
                cpu_inst_grant <= '1';

            when MASTER_ICACHE =>
                icache_grant <= '1';

            when MASTER_DCACHE =>
                dcache_grant <= '1';

            when MASTER_NONE =>
                -- No grants
                null;
        end case;
    end process;

    --------------------------------------------------------------
    -- Bus Busy Signal
    --------------------------------------------------------------
    bus_busy <= '1' when current_master /= MASTER_NONE else '0';

end architecture rtl;
