------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Memory Management Unit (MMU)                                    --
--                                                                          --
-- Top-level MMU integrating ATC, Transparent Translation, and Table Walk  --
--                                                                          --
-- Features:                                                                --
--   - 22-entry fully associative Address Translation Cache                --
--   - Transparent translation via TT0 and TT1 registers                   --
--   - Multi-level page table walk (up to 4 levels)                        --
--   - Write protection and supervisor checking                            --
--   - Cache inhibit flag generation                                       --
--   - Enable/disable via TC.E                                             --
--                                                                          --
-- Translation Priority:                                                    --
--   1. Check if MMU enabled (TC.E)                                        --
--   2. Check transparent translation (TT0, then TT1)                      --
--   3. Check ATC for cached translation                                   --
--   4. Perform page table walk on ATC miss                                --
--   5. Load successful translation into ATC                               --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_MMU is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- CPU interface
        cpu_addr    : in  std_logic_vector(31 downto 0); -- Virtual address
        cpu_fc      : in  std_logic_vector(2 downto 0);  -- Function code
        cpu_rw      : in  std_logic;                      -- 0=read, 1=write
        cpu_req     : in  std_logic;                      -- Translation request
        cpu_supervisor : in std_logic;                    -- Supervisor mode

        -- Translation result
        phys_addr   : out std_logic_vector(31 downto 0); -- Physical address
        trans_ready : out std_logic;                      -- Translation ready
        trans_error : out std_logic;                      -- Translation error
        cache_inh   : out std_logic;                      -- Cache inhibit

        -- MMU registers (from TG68K030_MMU_Registers)
        tc_reg      : in  std_logic_vector(31 downto 0); -- Translation Control
        tt0_reg     : in  std_logic_vector(31 downto 0); -- Transparent Translation 0
        tt1_reg     : in  std_logic_vector(31 downto 0); -- Transparent Translation 1
        crp_reg     : in  std_logic_vector(63 downto 0); -- CPU Root Pointer
        srp_reg     : in  std_logic_vector(63 downto 0); -- Supervisor Root Pointer
        mmusr_out   : out std_logic_vector(15 downto 0); -- MMU Status

        -- Cache/ATC control
        atc_flush_all : in  std_logic;                    -- Flush all ATC entries
        atc_flush_fc  : in  std_logic;                    -- Flush by function code
        atc_flush_addr: in  std_logic;                    -- Flush by address
        flush_fc      : in  std_logic_vector(2 downto 0); -- FC for flush
        flush_addr    : in  std_logic_vector(31 downto 0);-- Address for flush

        -- Memory bus interface (for table walks)
        bus_req     : out std_logic;                      -- Bus request
        bus_addr    : out std_logic_vector(31 downto 0); -- Bus address
        bus_data_in : in  std_logic_vector(31 downto 0); -- Bus data
        bus_ready   : in  std_logic;                      -- Bus ready
        bus_error   : in  std_logic                       -- Bus error
    );
end entity TG68K030_MMU;

architecture rtl of TG68K030_MMU is

    -- Component declarations
    component TG68K030_ATC is
        port(
            clk, reset      : in  std_logic;
            lookup_addr     : in  std_logic_vector(31 downto 0);
            lookup_fc       : in  std_logic_vector(2 downto 0);
            lookup_en       : in  std_logic;
            hit             : out std_logic;
            phys_addr       : out std_logic_vector(31 downto 0);
            write_protect   : out std_logic;
            super_only      : out std_logic;
            cache_inhibit   : out std_logic;
            modified        : out std_logic;
            used            : out std_logic;
            load_entry      : in  std_logic;
            load_virt_addr  : in  std_logic_vector(31 downto 0);
            load_phys_addr  : in  std_logic_vector(31 downto 0);
            load_fc         : in  std_logic_vector(2 downto 0);
            load_wp         : in  std_logic;
            load_super      : in  std_logic;
            load_ci         : in  std_logic;
            load_modified   : in  std_logic;
            load_used       : in  std_logic;
            flush_all       : in  std_logic;
            flush_by_fc     : in  std_logic;
            flush_fc        : in  std_logic_vector(2 downto 0);
            flush_by_addr   : in  std_logic;
            flush_addr      : in  std_logic_vector(31 downto 0)
        );
    end component;

    component TG68K030_TransparentTranslation is
        port(
            tt0_reg     : in  std_logic_vector(31 downto 0);
            tt1_reg     : in  std_logic_vector(31 downto 0);
            virt_addr   : in  std_logic_vector(31 downto 0);
            fc          : in  std_logic_vector(2 downto 0);
            supervisor  : in  std_logic;
            rw          : in  std_logic;
            tt_match    : out std_logic;
            tt_ci       : out std_logic;
            tt_which    : out std_logic_vector(1 downto 0)
        );
    end component;

    component TG68K030_PageTableWalk is
        port(
            clk, reset      : in  std_logic;
            start           : in  std_logic;
            abort_walk      : in  std_logic;
            virt_addr       : in  std_logic_vector(31 downto 0);
            fc              : in  std_logic_vector(2 downto 0);
            supervisor      : in  std_logic;
            rw              : in  std_logic;
            tc_reg          : in  std_logic_vector(31 downto 0);
            crp_reg         : in  std_logic_vector(63 downto 0);
            srp_reg         : in  std_logic_vector(63 downto 0);
            bus_req         : out std_logic;
            bus_addr        : out std_logic_vector(31 downto 0);
            bus_data_in     : in  std_logic_vector(31 downto 0);
            bus_ready       : in  std_logic;
            bus_error       : in  std_logic;
            phys_addr       : out std_logic_vector(31 downto 0);
            write_protect   : out std_logic;
            super_only      : out std_logic;
            cache_inh       : out std_logic;
            modified        : out std_logic;
            used            : out std_logic;
            done            : out std_logic;
            error           : out std_logic;
            error_code      : out std_logic_vector(3 downto 0)
        );
    end component;

    -- MMU state machine
    type mmu_state_t is (
        IDLE,               -- Waiting for request
        CHECK_TT,           -- Check transparent translation
        CHECK_ATC,          -- Check ATC
        TABLE_WALK,         -- Perform table walk
        LOAD_ATC,           -- Load result into ATC
        COMPLETE,           -- Translation complete
        ERROR_STATE         -- Translation error
    );
    signal state : mmu_state_t;

    -- TC register fields
    signal tc_enable : std_logic;

    -- Transparent translation signals
    signal tt_match  : std_logic;
    signal tt_ci     : std_logic;
    signal tt_which  : std_logic_vector(1 downto 0);

    -- ATC signals
    signal atc_lookup_en   : std_logic;
    signal atc_hit         : std_logic;
    signal atc_phys_addr   : std_logic_vector(31 downto 0);
    signal atc_wp          : std_logic;
    signal atc_super       : std_logic;
    signal atc_ci          : std_logic;
    signal atc_modified    : std_logic;
    signal atc_used        : std_logic;
    signal atc_load        : std_logic;

    -- Page table walk signals
    signal walk_start      : std_logic;
    signal walk_abort      : std_logic;
    signal walk_done       : std_logic;
    signal walk_error      : std_logic;
    signal walk_error_code : std_logic_vector(3 downto 0);
    signal walk_phys_addr  : std_logic_vector(31 downto 0);
    signal walk_wp         : std_logic;
    signal walk_super      : std_logic;
    signal walk_ci         : std_logic;
    signal walk_modified   : std_logic;
    signal walk_used       : std_logic;

    -- Working registers
    signal trans_virt_addr : std_logic_vector(31 downto 0);
    signal trans_fc        : std_logic_vector(2 downto 0);
    signal trans_rw        : std_logic;

begin

    --------------------------------------------------------------
    -- Extract TC enable bit
    --------------------------------------------------------------
    tc_enable <= tc_reg(31);

    --------------------------------------------------------------
    -- Instantiate ATC
    --------------------------------------------------------------
    atc_inst: TG68K030_ATC
        port map(
            clk            => clk,
            reset          => reset,
            lookup_addr    => cpu_addr,
            lookup_fc      => cpu_fc,
            lookup_en      => atc_lookup_en,
            hit            => atc_hit,
            phys_addr      => atc_phys_addr,
            write_protect  => atc_wp,
            super_only     => atc_super,
            cache_inhibit  => atc_ci,
            modified       => atc_modified,
            used           => atc_used,
            load_entry     => atc_load,
            load_virt_addr => trans_virt_addr,
            load_phys_addr => walk_phys_addr,
            load_fc        => trans_fc,
            load_wp        => walk_wp,
            load_super     => walk_super,
            load_ci        => walk_ci,
            load_modified  => walk_modified,
            load_used      => walk_used,
            flush_all      => atc_flush_all,
            flush_by_fc    => atc_flush_fc,
            flush_fc       => flush_fc,
            flush_by_addr  => atc_flush_addr,
            flush_addr     => flush_addr
        );

    --------------------------------------------------------------
    -- Instantiate Transparent Translation
    --------------------------------------------------------------
    tt_inst: TG68K030_TransparentTranslation
        port map(
            tt0_reg    => tt0_reg,
            tt1_reg    => tt1_reg,
            virt_addr  => cpu_addr,
            fc         => cpu_fc,
            supervisor => cpu_supervisor,
            rw         => cpu_rw,
            tt_match   => tt_match,
            tt_ci      => tt_ci,
            tt_which   => tt_which
        );

    --------------------------------------------------------------
    -- Instantiate Page Table Walk
    --------------------------------------------------------------
    walk_inst: TG68K030_PageTableWalk
        port map(
            clk           => clk,
            reset         => reset,
            start         => walk_start,
            abort_walk    => walk_abort,
            virt_addr     => trans_virt_addr,
            fc            => trans_fc,
            supervisor    => cpu_supervisor,
            rw            => trans_rw,
            tc_reg        => tc_reg,
            crp_reg       => crp_reg,
            srp_reg       => srp_reg,
            bus_req       => bus_req,
            bus_addr      => bus_addr,
            bus_data_in   => bus_data_in,
            bus_ready     => bus_ready,
            bus_error     => bus_error,
            phys_addr     => walk_phys_addr,
            write_protect => walk_wp,
            super_only    => walk_super,
            cache_inh     => walk_ci,
            modified      => walk_modified,
            used          => walk_used,
            done          => walk_done,
            error         => walk_error,
            error_code    => walk_error_code
        );

    --------------------------------------------------------------
    -- MMU Translation State Machine
    --------------------------------------------------------------
    mmu_fsm: process(clk, reset)
    begin
        if reset = '1' then
            state          <= IDLE;
            trans_virt_addr <= (others => '0');
            trans_fc       <= (others => '0');
            trans_rw       <= '0';

            atc_lookup_en  <= '0';
            atc_load       <= '0';
            walk_start     <= '0';
            walk_abort     <= '0';

            trans_ready    <= '0';
            trans_error    <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            atc_lookup_en <= '0';
            atc_load      <= '0';
            walk_start    <= '0';
            trans_ready   <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for translation request
                ------------------------------------------------------
                when IDLE =>
                    if cpu_req = '1' then
                        trans_virt_addr <= cpu_addr;
                        trans_fc        <= cpu_fc;
                        trans_rw        <= cpu_rw;

                        if tc_enable = '0' then
                            -- MMU disabled: direct mapping
                            phys_addr   <= cpu_addr;
                            cache_inh   <= '0';
                            trans_ready <= '1';
                            trans_error <= '0';
                            -- Stay in IDLE

                        else
                            -- MMU enabled: check transparent translation
                            state <= CHECK_TT;
                        end if;
                    end if;

                ------------------------------------------------------
                -- CHECK_TT: Check transparent translation
                ------------------------------------------------------
                when CHECK_TT =>
                    if tt_match = '1' then
                        -- Transparent translation hit: bypass MMU
                        phys_addr   <= trans_virt_addr;  -- Direct mapping
                        cache_inh   <= tt_ci;
                        trans_ready <= '1';
                        trans_error <= '0';
                        state       <= IDLE;

                    else
                        -- No transparent match: check ATC
                        atc_lookup_en <= '1';
                        state         <= CHECK_ATC;
                    end if;

                ------------------------------------------------------
                -- CHECK_ATC: Check ATC for cached translation
                ------------------------------------------------------
                when CHECK_ATC =>
                    if atc_hit = '1' then
                        -- ATC hit!
                        -- Check permissions
                        if trans_rw = '1' and atc_wp = '1' then
                            -- Write to write-protected page
                            trans_error <= '1';
                            state       <= ERROR_STATE;

                        elsif cpu_supervisor = '0' and atc_super = '1' then
                            -- User access to supervisor page
                            trans_error <= '1';
                            state       <= ERROR_STATE;

                        else
                            -- Permission OK
                            phys_addr   <= atc_phys_addr;
                            cache_inh   <= atc_ci;
                            trans_ready <= '1';
                            trans_error <= '0';
                            state       <= IDLE;
                        end if;

                    else
                        -- ATC miss: perform table walk
                        walk_start <= '1';
                        state      <= TABLE_WALK;
                    end if;

                ------------------------------------------------------
                -- TABLE_WALK: Wait for table walk to complete
                ------------------------------------------------------
                when TABLE_WALK =>
                    if walk_done = '1' then
                        -- Table walk successful
                        state <= LOAD_ATC;

                    elsif walk_error = '1' then
                        -- Table walk failed
                        trans_error <= '1';
                        state       <= ERROR_STATE;
                    end if;

                ------------------------------------------------------
                -- LOAD_ATC: Load translation result into ATC
                ------------------------------------------------------
                when LOAD_ATC =>
                    atc_load <= '1';
                    state    <= COMPLETE;

                ------------------------------------------------------
                -- COMPLETE: Translation complete
                ------------------------------------------------------
                when COMPLETE =>
                    phys_addr   <= walk_phys_addr;
                    cache_inh   <= walk_ci;
                    trans_ready <= '1';
                    trans_error <= '0';
                    state       <= IDLE;

                ------------------------------------------------------
                -- ERROR_STATE: Translation error
                ------------------------------------------------------
                when ERROR_STATE =>
                    trans_error <= '1';
                    trans_ready <= '0';
                    state       <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- MMUSR Output (MMU Status Register)
    --------------------------------------------------------------
    mmusr_update: process(clk, reset)
    begin
        if reset = '1' then
            mmusr_out <= (others => '0');

        elsif rising_edge(clk) then
            if state = ERROR_STATE then
                -- Update MMUSR with error information
                mmusr_out(15)          <= '1';  -- Bus error
                mmusr_out(14)          <= walk_error;
                mmusr_out(13 downto 10) <= walk_error_code;
                mmusr_out(9)           <= trans_rw;
                mmusr_out(8)           <= cpu_supervisor;
                mmusr_out(2 downto 0)  <= trans_fc;

            elsif state = COMPLETE or (state = CHECK_ATC and atc_hit = '1') then
                -- Update MMUSR with successful translation
                mmusr_out(15)          <= '0';  -- No error
                mmusr_out(7)           <= walk_wp or atc_wp;
                mmusr_out(6)           <= walk_super or atc_super;
                mmusr_out(5)           <= walk_ci or atc_ci;
                mmusr_out(4)           <= walk_modified or atc_modified;
                mmusr_out(3)           <= '1';  -- Resident (page in memory)
            end if;
        end if;
    end process;

end architecture rtl;
