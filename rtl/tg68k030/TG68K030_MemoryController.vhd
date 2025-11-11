------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Memory Controller                                               --
--                                                                          --
-- Integrates MMU, Caches, and Bus Interface                               --
--                                                                          --
-- Components:                                                              --
--   - MMU for address translation                                         --
--   - I-Cache for instruction accesses                                    --
--   - D-Cache for data accesses                                           --
--   - Bus arbiter for multi-master access                                 --
--   - Burst controller for cache fills                                    --
--                                                                          --
-- Flow:                                                                    --
--   CPU Request → MMU Translation → Cache Lookup → Bus Access (if miss)  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_MemoryController is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -----------------------------------------------------
        -- CPU Interface
        -----------------------------------------------------
        -- Instruction fetch
        cpu_inst_req    : in  std_logic;                      -- Instruction fetch request
        cpu_inst_addr   : in  std_logic_vector(31 downto 0); -- Virtual address
        cpu_inst_fc     : in  std_logic_vector(2 downto 0);  -- Function code
        cpu_inst_data   : out std_logic_vector(31 downto 0); -- Instruction data
        cpu_inst_ready  : out std_logic;                      -- Data ready
        cpu_inst_error  : out std_logic;                      -- Bus/MMU error

        -- Data access
        cpu_data_req    : in  std_logic;                      -- Data access request
        cpu_data_addr   : in  std_logic_vector(31 downto 0); -- Virtual address
        cpu_data_fc     : in  std_logic_vector(2 downto 0);  -- Function code
        cpu_data_rw     : in  std_logic;                      -- 0=read, 1=write
        cpu_data_size   : in  std_logic_vector(1 downto 0);  -- 00=byte, 01=word, 10=long
        cpu_data_in     : in  std_logic_vector(31 downto 0); -- Write data
        cpu_data_out    : out std_logic_vector(31 downto 0); -- Read data
        cpu_data_ready  : out std_logic;                      -- Data ready
        cpu_data_error  : out std_logic;                      -- Bus/MMU error

        -- CPU mode
        cpu_supervisor  : in  std_logic;                      -- Supervisor mode

        -----------------------------------------------------
        -- MMU Registers Interface
        -----------------------------------------------------
        tc_reg      : in  std_logic_vector(31 downto 0);     -- Translation Control
        tt0_reg     : in  std_logic_vector(31 downto 0);     -- Transparent Translation 0
        tt1_reg     : in  std_logic_vector(31 downto 0);     -- Transparent Translation 1
        crp_reg     : in  std_logic_vector(63 downto 0);     -- CPU Root Pointer
        srp_reg     : in  std_logic_vector(63 downto 0);     -- Supervisor Root Pointer

        -----------------------------------------------------
        -- Cache Control Interface
        -----------------------------------------------------
        cacr_reg    : in  std_logic_vector(31 downto 0);     -- Cache Control Register
        icache_enable : in  std_logic;                        -- I-Cache enable
        dcache_enable : in  std_logic;                        -- D-Cache enable
        icache_freeze : in  std_logic;                        -- I-Cache freeze
        dcache_freeze : in  std_logic;                        -- D-Cache freeze

        -----------------------------------------------------
        -- External Memory Bus Interface
        -----------------------------------------------------
        bus_addr    : out std_logic_vector(31 downto 0);     -- Physical address
        bus_data_in : in  std_logic_vector(31 downto 0);     -- Data from memory
        bus_data_out: out std_logic_vector(31 downto 0);     -- Data to memory
        bus_as      : out std_logic;                          -- Address strobe
        bus_ds      : out std_logic;                          -- Data strobe
        bus_rw      : out std_logic;                          -- 0=write, 1=read
        bus_burst   : out std_logic;                          -- Burst transfer
        bus_dsack   : in  std_logic_vector(1 downto 0);      -- Data acknowledge
        bus_berr    : in  std_logic;                          -- Bus error
        bus_fc      : out std_logic_vector(2 downto 0)       -- Function code
    );
end entity TG68K030_MemoryController;

architecture rtl of TG68K030_MemoryController is

    -- Component declarations
    component TG68K030_MMU is
        port(
            clk, reset      : in  std_logic;
            cpu_addr        : in  std_logic_vector(31 downto 0);
            cpu_fc          : in  std_logic_vector(2 downto 0);
            cpu_rw          : in  std_logic;
            cpu_req         : in  std_logic;
            cpu_supervisor  : in  std_logic;
            phys_addr       : out std_logic_vector(31 downto 0);
            trans_ready     : out std_logic;
            trans_error     : out std_logic;
            cache_inh       : out std_logic;
            tc_reg          : in  std_logic_vector(31 downto 0);
            tt0_reg         : in  std_logic_vector(31 downto 0);
            tt1_reg         : in  std_logic_vector(31 downto 0);
            crp_reg         : in  std_logic_vector(63 downto 0);
            srp_reg         : in  std_logic_vector(63 downto 0);
            mmusr_out       : out std_logic_vector(15 downto 0);
            atc_flush_all   : in  std_logic;
            atc_flush_fc    : in  std_logic;
            atc_flush_addr  : in  std_logic;
            flush_fc        : in  std_logic_vector(2 downto 0);
            flush_addr      : in  std_logic_vector(31 downto 0);
            bus_req         : out std_logic;
            bus_addr        : out std_logic_vector(31 downto 0);
            bus_data_in     : in  std_logic_vector(31 downto 0);
            bus_ready       : in  std_logic;
            bus_error       : in  std_logic
        );
    end component;

    component TG68K030_ICache is
        port(
            clk, reset      : in  std_logic;
            enable          : in  std_logic;
            freeze          : in  std_logic;
            clear           : in  std_logic;
            cpu_addr        : in  std_logic_vector(31 downto 0);
            cpu_req         : in  std_logic;
            cpu_data        : out std_logic_vector(31 downto 0);
            hit             : out std_logic;
            fill_req        : out std_logic;
            fill_addr       : out std_logic_vector(31 downto 0);
            fill_data_0     : in  std_logic_vector(31 downto 0);
            fill_data_1     : in  std_logic_vector(31 downto 0);
            fill_data_2     : in  std_logic_vector(31 downto 0);
            fill_data_3     : in  std_logic_vector(31 downto 0);
            fill_valid      : in  std_logic
        );
    end component;

    component TG68K030_DCache is
        port(
            clk, reset      : in  std_logic;
            enable          : in  std_logic;
            freeze          : in  std_logic;
            clear           : in  std_logic;
            cpu_addr        : in  std_logic_vector(31 downto 0);
            cpu_req         : in  std_logic;
            cpu_rw          : in  std_logic;
            cpu_size        : in  std_logic_vector(1 downto 0);
            cpu_data_in     : in  std_logic_vector(31 downto 0);
            cpu_data_out    : out std_logic_vector(31 downto 0);
            hit             : out std_logic;
            write_req       : out std_logic;
            write_addr      : out std_logic_vector(31 downto 0);
            write_data      : out std_logic_vector(31 downto 0);
            write_done      : in  std_logic;
            fill_req        : out std_logic;
            fill_addr       : out std_logic_vector(31 downto 0);
            fill_data       : in  std_logic_vector(31 downto 0);
            fill_valid      : in  std_logic
        );
    end component;

    component TG68K030_BusArbiter is
        port(
            clk, reset      : in  std_logic;
            mmu_req         : in  std_logic;
            mmu_grant       : out std_logic;
            mmu_done        : in  std_logic;
            cpu_data_req    : in  std_logic;
            cpu_data_grant  : out std_logic;
            cpu_data_done   : in  std_logic;
            cpu_inst_req    : in  std_logic;
            cpu_inst_grant  : out std_logic;
            cpu_inst_done   : in  std_logic;
            icache_req      : in  std_logic;
            icache_grant    : out std_logic;
            icache_done     : in  std_logic;
            dcache_req      : in  std_logic;
            dcache_grant    : out std_logic;
            dcache_done     : in  std_logic;
            bus_busy        : out std_logic;
            burst_active    : in  std_logic
        );
    end component;

    component TG68K030_BurstController is
        port(
            clk, reset      : in  std_logic;
            burst_req       : in  std_logic;
            burst_addr      : in  std_logic_vector(31 downto 0);
            burst_done      : out std_logic;
            burst_error     : out std_logic;
            bus_addr        : out std_logic_vector(31 downto 0);
            bus_burst       : out std_logic;
            bus_as          : out std_logic;
            bus_ds          : out std_logic;
            bus_data_in     : in  std_logic_vector(31 downto 0);
            bus_dsack       : in  std_logic_vector(1 downto 0);
            bus_berr        : in  std_logic;
            line_data_0     : out std_logic_vector(31 downto 0);
            line_data_1     : out std_logic_vector(31 downto 0);
            line_data_2     : out std_logic_vector(31 downto 0);
            line_data_3     : out std_logic_vector(31 downto 0);
            line_valid      : out std_logic
        );
    end component;

    -----------------------------------------------------
    -- MMU Signals
    -----------------------------------------------------
    signal mmu_inst_req     : std_logic;
    signal mmu_inst_phys    : std_logic_vector(31 downto 0);
    signal mmu_inst_ready   : std_logic;
    signal mmu_inst_error   : std_logic;
    signal mmu_inst_ci      : std_logic;

    signal mmu_data_req     : std_logic;
    signal mmu_data_phys    : std_logic_vector(31 downto 0);
    signal mmu_data_ready   : std_logic;
    signal mmu_data_error   : std_logic;
    signal mmu_data_ci      : std_logic;

    signal mmu_bus_req      : std_logic;
    signal mmu_bus_addr     : std_logic_vector(31 downto 0);
    signal mmu_bus_ready    : std_logic;
    signal mmu_bus_done     : std_logic;

    -----------------------------------------------------
    -- Cache Signals
    -----------------------------------------------------
    signal icache_hit       : std_logic;
    signal icache_data      : std_logic_vector(31 downto 0);
    signal icache_fill_req  : std_logic;
    signal icache_fill_addr : std_logic_vector(31 downto 0);

    signal dcache_hit       : std_logic;
    signal dcache_data_out  : std_logic_vector(31 downto 0);
    signal dcache_write_req : std_logic;
    signal dcache_write_addr: std_logic_vector(31 downto 0);
    signal dcache_write_data: std_logic_vector(31 downto 0);
    signal dcache_write_done: std_logic;
    signal dcache_fill_req  : std_logic;
    signal dcache_fill_addr : std_logic_vector(31 downto 0);

    -----------------------------------------------------
    -- Bus Arbiter Signals
    -----------------------------------------------------
    signal arb_mmu_grant    : std_logic;
    signal arb_cpu_data_grant : std_logic;
    signal arb_cpu_data_req : std_logic;
    signal arb_cpu_data_done: std_logic;
    signal arb_cpu_inst_grant : std_logic;
    signal arb_icache_grant : std_logic;
    signal arb_dcache_grant : std_logic;
    signal arb_bus_busy     : std_logic;

    -----------------------------------------------------
    -- Burst Controller Signals
    -----------------------------------------------------
    signal burst_req        : std_logic;
    signal burst_addr       : std_logic_vector(31 downto 0);
    signal burst_done       : std_logic;
    signal burst_error      : std_logic;
    signal burst_data_0     : std_logic_vector(31 downto 0);
    signal burst_data_1     : std_logic_vector(31 downto 0);
    signal burst_data_2     : std_logic_vector(31 downto 0);
    signal burst_data_3     : std_logic_vector(31 downto 0);
    signal burst_valid      : std_logic;
    signal burst_active     : std_logic;

    -----------------------------------------------------
    -- Bus Multiplexing Signals
    -----------------------------------------------------
    signal bus_req_inst     : std_logic;
    signal bus_req_data     : std_logic;

    -----------------------------------------------------
    -- State Machine for Instruction Fetch
    -----------------------------------------------------
    type inst_state_t is (IDLE, MMU_TRANS, CACHE_CHECK, BUS_ACCESS, WAIT_BURST, DONE);
    signal inst_state : inst_state_t;

    -----------------------------------------------------
    -- State Machine for Data Access
    -----------------------------------------------------
    type data_state_t is (IDLE, MMU_TRANS, CACHE_CHECK, BUS_ACCESS, WRITE_THROUGH, DONE);
    signal data_state : data_state_t;

begin

    --------------------------------------------------------------
    -- Instantiate MMU for Instructions
    --------------------------------------------------------------
    mmu_inst: TG68K030_MMU
        port map(
            clk            => clk,
            reset          => reset,
            cpu_addr       => cpu_inst_addr,
            cpu_fc         => cpu_inst_fc,
            cpu_rw         => '1',  -- Always read for instructions
            cpu_req        => mmu_inst_req,
            cpu_supervisor => cpu_supervisor,
            phys_addr      => mmu_inst_phys,
            trans_ready    => mmu_inst_ready,
            trans_error    => mmu_inst_error,
            cache_inh      => mmu_inst_ci,
            tc_reg         => tc_reg,
            tt0_reg        => tt0_reg,
            tt1_reg        => tt1_reg,
            crp_reg        => crp_reg,
            srp_reg        => srp_reg,
            mmusr_out      => open,
            atc_flush_all  => '0',
            atc_flush_fc   => '0',
            atc_flush_addr => '0',
            flush_fc       => "000",
            flush_addr     => (others => '0'),
            bus_req        => mmu_bus_req,
            bus_addr       => mmu_bus_addr,
            bus_data_in    => bus_data_in,
            bus_ready      => mmu_bus_ready,
            bus_error      => bus_berr
        );

    --------------------------------------------------------------
    -- Instantiate MMU for Data
    --------------------------------------------------------------
    mmu_data: TG68K030_MMU
        port map(
            clk            => clk,
            reset          => reset,
            cpu_addr       => cpu_data_addr,
            cpu_fc         => cpu_data_fc,
            cpu_rw         => cpu_data_rw,
            cpu_req        => mmu_data_req,
            cpu_supervisor => cpu_supervisor,
            phys_addr      => mmu_data_phys,
            trans_ready    => mmu_data_ready,
            trans_error    => mmu_data_error,
            cache_inh      => mmu_data_ci,
            tc_reg         => tc_reg,
            tt0_reg        => tt0_reg,
            tt1_reg        => tt1_reg,
            crp_reg        => crp_reg,
            srp_reg        => srp_reg,
            mmusr_out      => open,
            atc_flush_all  => '0',
            atc_flush_fc   => '0',
            atc_flush_addr => '0',
            flush_fc       => "000",
            flush_addr     => (others => '0'),
            bus_req        => open,  -- Share MMU bus with inst MMU
            bus_addr       => open,
            bus_data_in    => bus_data_in,
            bus_ready      => mmu_bus_ready,
            bus_error      => bus_berr
        );

    --------------------------------------------------------------
    -- Instantiate I-Cache
    --------------------------------------------------------------
    icache: TG68K030_ICache
        port map(
            clk         => clk,
            reset       => reset,
            enable      => icache_enable,
            freeze      => icache_freeze,
            clear       => '0',
            cpu_addr    => mmu_inst_phys,
            cpu_req     => mmu_inst_ready,
            cpu_data    => icache_data,
            hit         => icache_hit,
            fill_req    => icache_fill_req,
            fill_addr   => icache_fill_addr,
            fill_data_0 => burst_data_0,
            fill_data_1 => burst_data_1,
            fill_data_2 => burst_data_2,
            fill_data_3 => burst_data_3,
            fill_valid  => burst_valid
        );

    --------------------------------------------------------------
    -- Instantiate D-Cache
    --------------------------------------------------------------
    dcache: TG68K030_DCache
        port map(
            clk          => clk,
            reset        => reset,
            enable       => dcache_enable,
            freeze       => dcache_freeze,
            clear        => '0',
            cpu_addr     => mmu_data_phys,
            cpu_req      => mmu_data_ready,
            cpu_rw       => cpu_data_rw,
            cpu_size     => cpu_data_size,
            cpu_data_in  => cpu_data_in,
            cpu_data_out => dcache_data_out,
            hit          => dcache_hit,
            write_req    => dcache_write_req,
            write_addr   => dcache_write_addr,
            write_data   => dcache_write_data,
            write_done   => dcache_write_done,
            fill_req     => dcache_fill_req,
            fill_addr    => dcache_fill_addr,
            fill_data    => bus_data_in,
            fill_valid   => '0'  -- D-cache doesn't use burst fills
        );

    --------------------------------------------------------------
    -- Instantiate Bus Arbiter
    --------------------------------------------------------------
    arbiter: TG68K030_BusArbiter
        port map(
            clk            => clk,
            reset          => reset,
            mmu_req        => mmu_bus_req,
            mmu_grant      => arb_mmu_grant,
            mmu_done       => mmu_bus_done,
            cpu_data_req   => arb_cpu_data_req,
            cpu_data_grant => arb_cpu_data_grant,
            cpu_data_done  => arb_cpu_data_done,
            cpu_inst_req   => bus_req_inst,
            cpu_inst_grant => arb_cpu_inst_grant,
            cpu_inst_done  => '0',  -- Managed by state machine
            icache_req     => icache_fill_req,
            icache_grant   => arb_icache_grant,
            icache_done    => burst_done,
            dcache_req     => dcache_write_req,
            dcache_grant   => arb_dcache_grant,
            dcache_done    => dcache_write_done,
            bus_busy       => arb_bus_busy,
            burst_active   => burst_active
        );

    --------------------------------------------------------------
    -- Instantiate Burst Controller
    --------------------------------------------------------------
    burst_ctrl: TG68K030_BurstController
        port map(
            clk          => clk,
            reset        => reset,
            burst_req    => burst_req,
            burst_addr   => burst_addr,
            burst_done   => burst_done,
            burst_error  => burst_error,
            bus_addr     => open,  -- Connected through mux
            bus_burst    => burst_active,
            bus_as       => open,
            bus_ds       => open,
            bus_data_in  => bus_data_in,
            bus_dsack    => bus_dsack,
            bus_berr     => bus_berr,
            line_data_0  => burst_data_0,
            line_data_1  => burst_data_1,
            line_data_2  => burst_data_2,
            line_data_3  => burst_data_3,
            line_valid   => burst_valid
        );

    --------------------------------------------------------------
    -- Instruction Fetch State Machine
    --------------------------------------------------------------
    inst_fsm: process(clk, reset)
    begin
        if reset = '1' then
            inst_state     <= IDLE;
            mmu_inst_req   <= '0';
            bus_req_inst   <= '0';
            cpu_inst_ready <= '0';
            cpu_inst_error <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            cpu_inst_ready <= '0';

            case inst_state is
                when IDLE =>
                    if cpu_inst_req = '1' then
                        mmu_inst_req <= '1';
                        inst_state   <= MMU_TRANS;
                    end if;

                when MMU_TRANS =>
                    if mmu_inst_ready = '1' then
                        mmu_inst_req <= '0';
                        if mmu_inst_error = '1' then
                            cpu_inst_error <= '1';
                            inst_state     <= DONE;
                        else
                            inst_state <= CACHE_CHECK;
                        end if;
                    end if;

                when CACHE_CHECK =>
                    if mmu_inst_ci = '0' and icache_enable = '1' and icache_hit = '1' then
                        -- Cache hit
                        cpu_inst_data  <= icache_data;
                        cpu_inst_ready <= '1';
                        inst_state     <= DONE;
                    else
                        -- Cache miss or cache inhibit
                        bus_req_inst <= '1';
                        inst_state   <= BUS_ACCESS;
                    end if;

                when BUS_ACCESS =>
                    if arb_cpu_inst_grant = '1' then
                        if icache_fill_req = '1' then
                            -- Start burst fill
                            burst_req  <= '1';
                            burst_addr <= icache_fill_addr;
                            inst_state <= WAIT_BURST;
                        else
                            -- Single access
                            cpu_inst_data  <= bus_data_in;
                            cpu_inst_ready <= '1';
                            bus_req_inst   <= '0';
                            inst_state     <= DONE;
                        end if;
                    end if;

                when WAIT_BURST =>
                    burst_req <= '0';
                    if burst_done = '1' then
                        if burst_error = '1' then
                            cpu_inst_error <= '1';
                        else
                            cpu_inst_data  <= icache_data;  -- From filled cache
                            cpu_inst_ready <= '1';
                        end if;
                        bus_req_inst <= '0';
                        inst_state   <= DONE;
                    end if;

                when DONE =>
                    inst_state <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- Data Access State Machine
    --------------------------------------------------------------
    data_fsm: process(clk, reset)
    begin
        if reset = '1' then
            data_state      <= IDLE;
            mmu_data_req    <= '0';
            arb_cpu_data_req <= '0';
            cpu_data_ready  <= '0';
            cpu_data_error  <= '0';

        elsif rising_edge(clk) then
            cpu_data_ready <= '0';

            case data_state is
                when IDLE =>
                    if cpu_data_req = '1' then
                        mmu_data_req <= '1';
                        data_state   <= MMU_TRANS;
                    end if;

                when MMU_TRANS =>
                    if mmu_data_ready = '1' then
                        mmu_data_req <= '0';
                        if mmu_data_error = '1' then
                            cpu_data_error <= '1';
                            data_state     <= DONE;
                        else
                            data_state <= CACHE_CHECK;
                        end if;
                    end if;

                when CACHE_CHECK =>
                    if mmu_data_ci = '0' and dcache_enable = '1' and dcache_hit = '1' then
                        -- Cache hit
                        if cpu_data_rw = '0' then
                            -- Read hit
                            cpu_data_out   <= dcache_data_out;
                            cpu_data_ready <= '1';
                            data_state     <= DONE;
                        else
                            -- Write hit (write-through)
                            data_state <= WRITE_THROUGH;
                        end if;
                    else
                        -- Cache miss or inhibit
                        arb_cpu_data_req <= '1';
                        data_state       <= BUS_ACCESS;
                    end if;

                when BUS_ACCESS =>
                    if arb_cpu_data_grant = '1' then
                        cpu_data_out     <= bus_data_in;
                        cpu_data_ready   <= '1';
                        arb_cpu_data_req <= '0';
                        arb_cpu_data_done <= '1';
                        data_state       <= DONE;
                    end if;

                when WRITE_THROUGH =>
                    if dcache_write_done = '1' then
                        cpu_data_ready <= '1';
                        data_state     <= DONE;
                    end if;

                when DONE =>
                    data_state <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- Bus Multiplexing
    --------------------------------------------------------------
    bus_fc <= cpu_inst_fc when arb_cpu_inst_grant = '1' else
              cpu_data_fc when arb_cpu_data_grant = '1' else
              "111";  -- CPU space for MMU

    bus_rw <= '1' when arb_cpu_inst_grant = '1' else
              cpu_data_rw;

end architecture rtl;
