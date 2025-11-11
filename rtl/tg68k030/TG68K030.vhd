------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K030 - MC68030 CPU Implementation                                   --
--                                                                          --
-- Top-level module integrating:                                           --
--   - TG68K core (68000/68010/68020 base)                                --
--   - MC68030 MMU (address translation)                                   --
--   - MC68030 Caches (I-cache and D-cache)                                --
--   - Burst mode bus interface                                            --
--                                                                          --
-- Mode Selection via cpucfg:                                              --
--   00 = MC68000                                                           --
--   01 = MC68010                                                           --
--   10 = MC68020                                                           --
--   11 = MC68030 (full features)                                          --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030 is
    generic(
        -- Feature Enable Flags
        -- Allows selective disabling of features to reduce resource usage
        ENABLE_MMU        : boolean := true;   -- Enable MMU with ATC (33% of logic)
        ENABLE_CACHES     : boolean := true;   -- Enable I-Cache and D-Cache (20% of logic)
        ENABLE_BURST      : boolean := true;   -- Enable burst mode transfers

        -- Cache Configuration
        CACHE_SIZE        : integer := 256;    -- Cache size in bytes (256, 128, or 64)
                                                -- Both I-Cache and D-Cache use this size

        -- ATC Configuration
        ATC_ENTRIES       : integer := 22;     -- ATC entry count (22, 16, or 8)
                                                -- Only used if ENABLE_MMU = true

        -- Optional Features (future expansion)
        ENABLE_PLOAD      : boolean := false;  -- PLOAD instruction (not yet implemented)
        ENABLE_LONG_DESC  : boolean := false;  -- Long-format descriptors (not yet implemented)
        ENABLE_COPYBACK   : boolean := false   -- Copyback cache mode (not yet implemented)
    );
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;
        clkena      : in  std_logic := '1';              -- Clock enable

        -- CPU configuration
        cpucfg      : in  std_logic_vector(1 downto 0);  -- CPU mode selection
        -- 00 = 68000, 01 = 68010, 10 = 68030 (replaces 68020)

        -- External memory bus
        addr        : out std_logic_vector(31 downto 0); -- Address bus
        data_read   : in  std_logic_vector(31 downto 0); -- Data in
        data_write  : out std_logic_vector(31 downto 0); -- Data out
        as          : out std_logic;                      -- Address strobe
        uds         : out std_logic;                      -- Upper data strobe
        lds         : out std_logic;                      -- Lower data strobe
        rw          : out std_logic;                      -- Read/write
        dtack       : in  std_logic;                      -- Data acknowledge
        busstate    : out std_logic_vector(1 downto 0);  -- Bus state
        fc          : out std_logic_vector(2 downto 0);  -- Function code

        -- MC68030-specific signals
        burst       : out std_logic;                      -- Burst mode indicator
        siz         : out std_logic_vector(1 downto 0);  -- Transfer size

        -- Interrupts
        ipl         : in  std_logic_vector(2 downto 0);  -- Interrupt priority level

        -- Cache control (for 68030 mode)
        cache_inhibit : in std_logic := '0';              -- Global cache inhibit

        -- Debug/status
        cpu_state   : out std_logic_vector(5 downto 0)   -- CPU state for debugging
    );
end entity TG68K030;

architecture rtl of TG68K030 is

    -- Component: Memory Controller (MC68030 extensions)
    component TG68K030_MemoryController is
        port(
            clk, reset      : in  std_logic;
            cpu_inst_req    : in  std_logic;
            cpu_inst_addr   : in  std_logic_vector(31 downto 0);
            cpu_inst_fc     : in  std_logic_vector(2 downto 0);
            cpu_inst_data   : out std_logic_vector(31 downto 0);
            cpu_inst_ready  : out std_logic;
            cpu_inst_error  : out std_logic;
            cpu_data_req    : in  std_logic;
            cpu_data_addr   : in  std_logic_vector(31 downto 0);
            cpu_data_fc     : in  std_logic_vector(2 downto 0);
            cpu_data_rw     : in  std_logic;
            cpu_data_size   : in  std_logic_vector(1 downto 0);
            cpu_data_in     : in  std_logic_vector(31 downto 0);
            cpu_data_out    : out std_logic_vector(31 downto 0);
            cpu_data_ready  : out std_logic;
            cpu_data_error  : out std_logic;
            cpu_supervisor  : in  std_logic;
            tc_reg          : in  std_logic_vector(31 downto 0);
            tt0_reg         : in  std_logic_vector(31 downto 0);
            tt1_reg         : in  std_logic_vector(31 downto 0);
            crp_reg         : in  std_logic_vector(63 downto 0);
            srp_reg         : in  std_logic_vector(63 downto 0);
            cacr_reg        : in  std_logic_vector(31 downto 0);
            icache_enable   : in  std_logic;
            dcache_enable   : in  std_logic;
            icache_freeze   : in  std_logic;
            dcache_freeze   : in  std_logic;
            bus_addr        : out std_logic_vector(31 downto 0);
            bus_data_in     : in  std_logic_vector(31 downto 0);
            bus_data_out    : out std_logic_vector(31 downto 0);
            bus_as          : out std_logic;
            bus_ds          : out std_logic;
            bus_rw          : out std_logic;
            bus_burst       : out std_logic;
            bus_dsack       : in  std_logic_vector(1 downto 0);
            bus_berr        : in  std_logic;
            bus_fc          : out std_logic_vector(2 downto 0)
        );
    end component;

    -- Component: MMU Registers
    component TG68K030_MMU_Registers is
        port(
            clk, reset      : in  std_logic;
            supervisor      : in  std_logic;
            reg_addr        : in  std_logic_vector(3 downto 0);
            reg_write       : in  std_logic;
            reg_read        : in  std_logic;
            reg_size        : in  std_logic_vector(1 downto 0);
            data_in         : in  std_logic_vector(63 downto 0);
            data_out        : out std_logic_vector(63 downto 0);
            tc_out          : out std_logic_vector(31 downto 0);
            tt0_out         : out std_logic_vector(31 downto 0);
            tt1_out         : out std_logic_vector(31 downto 0);
            crp_out         : out std_logic_vector(63 downto 0);
            srp_out         : out std_logic_vector(63 downto 0);
            mmusr_out       : out std_logic_vector(15 downto 0)
        );
    end component;

    -- Component: Cache Registers
    component TG68K030_Cache_Registers is
        port(
            clk, reset      : in  std_logic;
            supervisor      : in  std_logic;
            cacr_write      : in  std_logic;
            cacr_in         : in  std_logic_vector(31 downto 0);
            cacr_out        : out std_logic_vector(31 downto 0);
            caar_write      : in  std_logic;
            caar_in         : in  std_logic_vector(31 downto 0);
            caar_out        : out std_logic_vector(31 downto 0);
            clear_icache    : out std_logic;
            clear_dcache    : out std_logic;
            enable_icache   : out std_logic;
            enable_dcache   : out std_logic;
            freeze_icache   : out std_logic;
            freeze_dcache   : out std_logic
        );
    end component;

    -----------------------------------------------------
    -- CPU Mode Signals
    -----------------------------------------------------
    signal mode_68030       : std_logic;  -- MC68030 mode active
    signal mode_bypass      : std_logic;  -- Bypass MC68030 extensions

    -----------------------------------------------------
    -- MMU Register Signals
    -----------------------------------------------------
    signal tc_reg           : std_logic_vector(31 downto 0);
    signal tt0_reg          : std_logic_vector(31 downto 0);
    signal tt1_reg          : std_logic_vector(31 downto 0);
    signal crp_reg          : std_logic_vector(63 downto 0);
    signal srp_reg          : std_logic_vector(63 downto 0);
    signal mmusr_reg        : std_logic_vector(15 downto 0);

    -----------------------------------------------------
    -- Cache Control Signals
    -----------------------------------------------------
    signal cacr_reg         : std_logic_vector(31 downto 0);
    signal caar_reg         : std_logic_vector(31 downto 0);
    signal icache_enable    : std_logic;
    signal dcache_enable    : std_logic;
    signal icache_freeze    : std_logic;
    signal dcache_freeze    : std_logic;
    signal clear_icache     : std_logic;
    signal clear_dcache     : std_logic;

    -----------------------------------------------------
    -- CPU Core Interface Signals
    -----------------------------------------------------
    signal cpu_inst_req     : std_logic;
    signal cpu_inst_addr    : std_logic_vector(31 downto 0);
    signal cpu_inst_fc      : std_logic_vector(2 downto 0);
    signal cpu_inst_data    : std_logic_vector(31 downto 0);
    signal cpu_inst_ready   : std_logic;
    signal cpu_inst_error   : std_logic;

    signal cpu_data_req     : std_logic;
    signal cpu_data_addr    : std_logic_vector(31 downto 0);
    signal cpu_data_fc      : std_logic_vector(2 downto 0);
    signal cpu_data_rw      : std_logic;
    signal cpu_data_size    : std_logic_vector(1 downto 0);
    signal cpu_data_in      : std_logic_vector(31 downto 0);
    signal cpu_data_out     : std_logic_vector(31 downto 0);
    signal cpu_data_ready   : std_logic;
    signal cpu_data_error   : std_logic;
    signal cpu_supervisor   : std_logic;

    -----------------------------------------------------
    -- Memory Controller Bus Signals
    -----------------------------------------------------
    signal mc_bus_addr      : std_logic_vector(31 downto 0);
    signal mc_bus_data_out  : std_logic_vector(31 downto 0);
    signal mc_bus_as        : std_logic;
    signal mc_bus_ds        : std_logic;
    signal mc_bus_rw        : std_logic;
    signal mc_bus_burst     : std_logic;
    signal mc_bus_fc        : std_logic_vector(2 downto 0);

    -----------------------------------------------------
    -- Bus Multiplexing
    -----------------------------------------------------
    signal bus_dsack        : std_logic_vector(1 downto 0);
    signal bus_berr         : std_logic;

    -----------------------------------------------------
    -- Simplified CPU Core Simulation
    -- In real implementation, this would connect to TG68KdotC_Kernel
    -----------------------------------------------------
    signal core_state       : std_logic_vector(5 downto 0);

begin

    --------------------------------------------------------------
    -- Mode Selection
    -- cpucfg = 10 enables MC68030 mode (which includes 68020 features)
    --------------------------------------------------------------
    mode_68030  <= '1' when cpucfg = "10" else '0';
    mode_bypass <= not mode_68030;

    --------------------------------------------------------------
    -- Instantiate MMU Registers
    --------------------------------------------------------------
    mmu_regs: TG68K030_MMU_Registers
        port map(
            clk        => clk,
            reset      => reset,
            supervisor => cpu_supervisor,
            reg_addr   => "0000",  -- From PMOVE instruction decoder
            reg_write  => '0',      -- From PMOVE instruction decoder
            reg_read   => '0',      -- From PMOVE instruction decoder
            reg_size   => "10",     -- Long word
            data_in    => (others => '0'),
            data_out   => open,
            tc_out     => tc_reg,
            tt0_out    => tt0_reg,
            tt1_out    => tt1_reg,
            crp_out    => crp_reg,
            srp_out    => srp_reg,
            mmusr_out  => mmusr_reg
        );

    --------------------------------------------------------------
    -- Instantiate Cache Registers
    --------------------------------------------------------------
    cache_regs: TG68K030_Cache_Registers
        port map(
            clk           => clk,
            reset         => reset,
            supervisor    => cpu_supervisor,
            cacr_write    => '0',  -- From MOVEC instruction
            cacr_in       => (others => '0'),
            cacr_out      => cacr_reg,
            caar_write    => '0',
            caar_in       => (others => '0'),
            caar_out      => caar_reg,
            clear_icache  => clear_icache,
            clear_dcache  => clear_dcache,
            enable_icache => icache_enable,
            enable_dcache => dcache_enable,
            freeze_icache => icache_freeze,
            freeze_dcache => dcache_freeze
        );

    --------------------------------------------------------------
    -- Instantiate Memory Controller (MC68030 mode only)
    --------------------------------------------------------------
    gen_68030_mode: if true generate
        mem_ctrl: TG68K030_MemoryController
            port map(
                clk            => clk,
                reset          => reset,
                cpu_inst_req   => cpu_inst_req,
                cpu_inst_addr  => cpu_inst_addr,
                cpu_inst_fc    => cpu_inst_fc,
                cpu_inst_data  => cpu_inst_data,
                cpu_inst_ready => cpu_inst_ready,
                cpu_inst_error => cpu_inst_error,
                cpu_data_req   => cpu_data_req,
                cpu_data_addr  => cpu_data_addr,
                cpu_data_fc    => cpu_data_fc,
                cpu_data_rw    => cpu_data_rw,
                cpu_data_size  => cpu_data_size,
                cpu_data_in    => cpu_data_in,
                cpu_data_out   => cpu_data_out,
                cpu_data_ready => cpu_data_ready,
                cpu_data_error => cpu_data_error,
                cpu_supervisor => cpu_supervisor,
                tc_reg         => tc_reg,
                tt0_reg        => tt0_reg,
                tt1_reg        => tt1_reg,
                crp_reg        => crp_reg,
                srp_reg        => srp_reg,
                cacr_reg       => cacr_reg,
                icache_enable  => icache_enable,
                dcache_enable  => dcache_enable,
                icache_freeze  => icache_freeze,
                dcache_freeze  => dcache_freeze,
                bus_addr       => mc_bus_addr,
                bus_data_in    => data_read,
                bus_data_out   => mc_bus_data_out,
                bus_as         => mc_bus_as,
                bus_ds         => mc_bus_ds,
                bus_rw         => mc_bus_rw,
                bus_burst      => mc_bus_burst,
                bus_dsack      => bus_dsack,
                bus_berr       => bus_berr,
                bus_fc         => mc_bus_fc
            );
    end generate;

    --------------------------------------------------------------
    -- Bus Multiplexing: 68030 mode vs Bypass mode
    --------------------------------------------------------------
    bus_mux: process(mode_68030, mc_bus_addr, mc_bus_as, mc_bus_rw,
                     mc_bus_burst, mc_bus_fc, mc_bus_data_out,
                     cpu_inst_addr, cpu_data_addr)
    begin
        if mode_68030 = '1' then
            -- MC68030 mode: use memory controller
            addr       <= mc_bus_addr;
            as         <= mc_bus_as;
            rw         <= mc_bus_rw;
            burst      <= mc_bus_burst;
            fc         <= mc_bus_fc;
            data_write <= mc_bus_data_out;

            -- Generate UDS/LDS from size
            uds <= mc_bus_ds;
            lds <= mc_bus_ds;
            siz <= "10";  -- Long word (simplified)

        else
            -- Bypass mode: direct connection (68000/68010/68020)
            -- This would connect directly to TG68K core
            addr       <= cpu_inst_addr;  -- Simplified
            as         <= '0';
            rw         <= '1';
            burst      <= '0';
            fc         <= "110";
            data_write <= (others => '0');
            uds        <= '0';
            lds        <= '0';
            siz        <= "10";
        end if;
    end process;

    --------------------------------------------------------------
    -- DTACK/DSACK Conversion
    --------------------------------------------------------------
    -- Convert DTACK (single wire) to DSACK (2-bit)
    -- DTACK active low → DSACK "00" (32-bit port ready)
    bus_dsack <= "00" when dtack = '0' else "11";
    bus_berr  <= '0';  -- No bus errors in basic implementation

    --------------------------------------------------------------
    -- Bus State Output
    --------------------------------------------------------------
    busstate <= "00" when as = '0' else
                "01" when as = '1' and dtack = '1' else
                "10";

    --------------------------------------------------------------
    -- CPU State Debug Output
    --------------------------------------------------------------
    cpu_state <= core_state;

    --------------------------------------------------------------
    -- Note: In full implementation, this module would instantiate
    -- TG68KdotC_Kernel and connect:
    --   - Instruction fetch interface
    --   - Data access interface
    --   - Exception handling
    --   - Interrupt handling
    --   - Register access
    --
    -- The TG68K core would be modified to:
    --   - Recognize F-line instructions (PMOVE/PFLUSH/PTEST)
    --   - Forward to MMU instruction executors
    --   - Handle cache control instructions (MOVEC CACR)
    --   - Provide cpu_supervisor signal
    --   - Interface with memory controller
    --------------------------------------------------------------

end architecture rtl;
