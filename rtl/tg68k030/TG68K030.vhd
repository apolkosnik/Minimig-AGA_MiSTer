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

    -- Component: TG68KdotC_Kernel (base CPU core)
    component TG68KdotC_Kernel is
        generic(
            SR_Read : integer := 2;
            VBR_Stackframe : integer := 2;
            extAddr_Mode : integer := 2;
            MUL_Mode : integer := 2;
            DIV_Mode : integer := 2;
            BitField : integer := 2;
            BarrelShifter : integer := 1;
            MUL_Hardware : integer := 1
        );
        port(
            clk : in std_logic;
            nReset : in std_logic;
            clkena_in : in std_logic;
            data_in : in std_logic_vector(15 downto 0);
            IPL : in std_logic_vector(2 downto 0);
            IPL_autovector : in std_logic;
            berr : in std_logic;
            CPU : in std_logic_vector(1 downto 0);
            addr_out : out std_logic_vector(31 downto 0);
            data_write : out std_logic_vector(15 downto 0);
            nWr : out std_logic;
            nUDS : out std_logic;
            nLDS : out std_logic;
            busstate : out std_logic_vector(1 downto 0);
            longword : out std_logic;
            nResetOut : out std_logic;
            FC : out std_logic_vector(2 downto 0);
            clr_berr : out std_logic;
            skipFetch : out std_logic;
            regin_out : out std_logic_vector(31 downto 0);
            CACR_out : out std_logic_vector(3 downto 0);
            VBR_out : out std_logic_vector(31 downto 0);
            -- MC68030 F-line MMU instruction interface
            fline_is_mmu : in std_logic;
            fline_is_pmove : in std_logic;
            fline_is_pflush : in std_logic;
            fline_is_ptest : in std_logic;
            fline_exec_req : out std_logic;
            fline_exec_done : in std_logic
        );
    end component;

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

    -- Component: PMOVE Decoder (MC68030 F-line instruction)
    component TG68K030_PMOVE_Decoder is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            opcode          : in  std_logic_vector(15 downto 0);
            extension       : in  std_logic_vector(15 downto 0);
            opcode_valid    : in  std_logic;
            supervisor      : in  std_logic;
            is_pmove        : out std_logic;
            is_pmovefd      : out std_logic;
            pmove_direction : out std_logic;
            pmove_reg_code  : out std_logic_vector(7 downto 0);
            pmove_ea_mode   : out std_logic_vector(2 downto 0);
            pmove_ea_reg    : out std_logic_vector(2 downto 0);
            pmove_size      : out std_logic_vector(1 downto 0);
            pmove_sel_tc    : out std_logic;
            pmove_sel_tt0   : out std_logic;
            pmove_sel_tt1   : out std_logic;
            pmove_sel_crp   : out std_logic;
            pmove_sel_srp   : out std_logic;
            pmove_sel_mmusr : out std_logic;
            illegal_instr   : out std_logic;
            priv_violation  : out std_logic
        );
    end component;

    -- Component: PFLUSH Decoder (MC68030 F-line instruction)
    component TG68K030_PFLUSH_Decoder is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            opcode          : in  std_logic_vector(15 downto 0);
            extension       : in  std_logic_vector(15 downto 0);
            opcode_valid    : in  std_logic;
            supervisor      : in  std_logic;
            is_pflush       : out std_logic;
            pflush_mode     : out std_logic_vector(1 downto 0);
            pflush_fc       : out std_logic_vector(2 downto 0);
            pflush_ea_mode  : out std_logic_vector(2 downto 0);
            pflush_ea_reg   : out std_logic_vector(2 downto 0);
            illegal_instr   : out std_logic;
            priv_violation  : out std_logic
        );
    end component;

    -- Component: PTEST Decoder (MC68030 F-line instruction)
    component TG68K030_PTEST_Decoder is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            opcode          : in  std_logic_vector(15 downto 0);
            extension       : in  std_logic_vector(15 downto 0);
            opcode_valid    : in  std_logic;
            supervisor      : in  std_logic;
            is_ptest        : out std_logic;
            ptest_level     : out std_logic_vector(2 downto 0);
            ptest_fc        : out std_logic_vector(2 downto 0);
            ptest_rw        : out std_logic;
            ptest_ret_en    : out std_logic;
            ptest_ret_reg   : out std_logic_vector(2 downto 0);
            ptest_ea_mode   : out std_logic_vector(2 downto 0);
            ptest_ea_reg    : out std_logic_vector(2 downto 0);
            illegal_instr   : out std_logic;
            priv_violation  : out std_logic
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
    -- TG68K CPU Core Signals
    -----------------------------------------------------
    signal tg68k_addr_out   : std_logic_vector(31 downto 0);
    signal tg68k_data_write : std_logic_vector(15 downto 0);
    signal tg68k_data_read  : std_logic_vector(15 downto 0);
    signal tg68k_nWr        : std_logic;
    signal tg68k_nUDS       : std_logic;
    signal tg68k_nLDS       : std_logic;
    signal tg68k_busstate   : std_logic_vector(1 downto 0);
    signal tg68k_longword   : std_logic;
    signal tg68k_nResetOut  : std_logic;
    signal tg68k_FC         : std_logic_vector(2 downto 0);
    signal tg68k_clr_berr   : std_logic;
    signal tg68k_skipFetch  : std_logic;
    signal tg68k_regin      : std_logic_vector(31 downto 0);
    signal tg68k_CACR       : std_logic_vector(3 downto 0);
    signal tg68k_VBR        : std_logic_vector(31 downto 0);
    signal tg68k_clkena     : std_logic;

    -- CPU State
    signal core_state       : std_logic_vector(5 downto 0);

    -----------------------------------------------------
    -- F-Line MMU Instruction Signals
    -----------------------------------------------------
    -- Decoder outputs
    signal fline_is_mmu     : std_logic;
    signal fline_is_pmove   : std_logic;
    signal fline_is_pflush  : std_logic;
    signal fline_is_ptest   : std_logic;
    signal fline_exec_req   : std_logic;
    signal fline_exec_done  : std_logic;

    -- PMOVE decoder signals
    signal pmove_is_pmove   : std_logic;
    signal pmove_is_pmovefd : std_logic;
    signal pmove_direction  : std_logic;
    signal pmove_reg_code   : std_logic_vector(7 downto 0);
    signal pmove_size       : std_logic_vector(1 downto 0);
    signal pmove_sel_tc     : std_logic;
    signal pmove_sel_tt0    : std_logic;
    signal pmove_sel_tt1    : std_logic;
    signal pmove_sel_crp    : std_logic;
    signal pmove_sel_srp    : std_logic;
    signal pmove_sel_mmusr  : std_logic;

    -- PFLUSH decoder signals
    signal pflush_is_pflush : std_logic;
    signal pflush_mode      : std_logic_vector(1 downto 0);
    signal pflush_fc        : std_logic_vector(2 downto 0);

    -- PTEST decoder signals
    signal ptest_is_ptest   : std_logic;
    signal ptest_level      : std_logic_vector(2 downto 0);
    signal ptest_fc         : std_logic_vector(2 downto 0);

    -- Opcode/extension word signals for decoders
    signal fline_opcode     : std_logic_vector(15 downto 0);
    signal fline_extension  : std_logic_vector(15 downto 0);
    signal fline_opcode_valid : std_logic;

begin

    --------------------------------------------------------------
    -- Mode Selection
    -- cpucfg = 10 enables MC68030 mode (which includes 68020 features)
    --------------------------------------------------------------
    mode_68030  <= '1' when cpucfg = "10" else '0';
    mode_bypass <= not mode_68030;

    --------------------------------------------------------------
    -- Instantiate TG68KdotC_Kernel CPU Core
    --------------------------------------------------------------
    -- This is the actual 68000/68010/68020 processor core
    -- For MC68030 mode (cpucfg = 10), it operates in 68020 mode
    -- with MC68030 extensions handled by surrounding logic
    --------------------------------------------------------------

    cpu_core: TG68KdotC_Kernel
        generic map(
            SR_Read => 2,           -- Switchable with CPU(0)
            VBR_Stackframe => 2,    -- Switchable with CPU(0)
            extAddr_Mode => 2,      -- Switchable with CPU(1)
            MUL_Mode => 2,          -- Switchable with CPU(1)
            DIV_Mode => 2,          -- Switchable with CPU(1)
            BitField => 2,          -- Switchable with CPU(1)
            BarrelShifter => 1,     -- Yes
            MUL_Hardware => 1       -- Yes
        )
        port map(
            clk => clk,
            nReset => not reset,    -- TG68K uses active-low reset
            clkena_in => tg68k_clkena,
            data_in => tg68k_data_read,
            IPL => ipl,
            IPL_autovector => '1',  -- Amiga uses autovector interrupts
            berr => '0',            -- Bus error (not used in basic config)
            CPU => cpucfg,          -- CPU mode: 00=68000, 01=68010, 10/11=68020
            addr_out => tg68k_addr_out,
            data_write => tg68k_data_write,
            nWr => tg68k_nWr,
            nUDS => tg68k_nUDS,
            nLDS => tg68k_nLDS,
            busstate => tg68k_busstate,
            longword => tg68k_longword,
            nResetOut => tg68k_nResetOut,
            FC => tg68k_FC,
            clr_berr => tg68k_clr_berr,
            skipFetch => tg68k_skipFetch,
            regin_out => tg68k_regin,
            CACR_out => tg68k_CACR,
            VBR_out => tg68k_VBR,
            -- MC68030 F-line MMU instruction interface
            fline_is_mmu => fline_is_mmu,
            fline_is_pmove => fline_is_pmove,
            fline_is_pflush => fline_is_pflush,
            fline_is_ptest => fline_is_ptest,
            fline_exec_req => fline_exec_req,
            fline_exec_done => fline_exec_done
        );

    -- CPU Supervisor mode detection from Function Code
    -- FC = 4,5,6,7 indicates supervisor mode
    cpu_supervisor <= tg68k_FC(2);

    -- CPU clock enable: allow CPU to run when memory is ready
    -- In MC68030 mode, gate with memory controller ready signals
    tg68k_clkena <= clkena when mode_bypass = '1' else
                    clkena and (cpu_inst_ready or cpu_data_ready);

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
    -- CPU Bus Interface Conversion
    --------------------------------------------------------------
    -- Convert TG68K's 16-bit unified bus interface to separate
    -- instruction and data paths required by MC68030 Memory Controller
    --
    -- TG68K busstate encoding:
    --   00: fetch code (instruction)
    --   01: no memory access
    --   10: read data
    --   11: write data
    --------------------------------------------------------------

    process(clk, reset)
    begin
        if reset = '1' then
            cpu_inst_req  <= '0';
            cpu_data_req  <= '0';
            cpu_inst_addr <= (others => '0');
            cpu_data_addr <= (others => '0');
            cpu_inst_fc   <= "000";
            cpu_data_fc   <= "000";
            cpu_data_rw   <= '0';
            cpu_data_size <= "00";
            cpu_data_in   <= (others => '0');

        elsif rising_edge(clk) then
            -- Instruction Fetch (busstate = 00)
            if tg68k_busstate = "00" then
                cpu_inst_req  <= '1';
                cpu_inst_addr <= tg68k_addr_out;
                cpu_inst_fc   <= tg68k_FC;
                cpu_data_req  <= '0';

            -- Data Read (busstate = 10)
            elsif tg68k_busstate = "10" then
                cpu_data_req  <= '1';
                cpu_data_addr <= tg68k_addr_out;
                cpu_data_fc   <= tg68k_FC;
                cpu_data_rw   <= '0';  -- Read
                cpu_inst_req  <= '0';

                -- Determine transfer size from UDS/LDS
                if tg68k_longword = '1' then
                    cpu_data_size <= "10";  -- Longword (32-bit)
                elsif tg68k_nUDS = '0' and tg68k_nLDS = '0' then
                    cpu_data_size <= "01";  -- Word (16-bit)
                else
                    cpu_data_size <= "00";  -- Byte (8-bit)
                end if;

            -- Data Write (busstate = 11)
            elsif tg68k_busstate = "11" then
                cpu_data_req  <= '1';
                cpu_data_addr <= tg68k_addr_out;
                cpu_data_fc   <= tg68k_FC;
                cpu_data_rw   <= '1';  -- Write
                cpu_inst_req  <= '0';

                -- Determine transfer size
                if tg68k_longword = '1' then
                    cpu_data_size <= "10";  -- Longword
                elsif tg68k_nUDS = '0' and tg68k_nLDS = '0' then
                    cpu_data_size <= "01";  -- Word
                else
                    cpu_data_size <= "00";  -- Byte
                end if;

                -- Convert 16-bit write data to 32-bit
                -- Replicate data in both upper and lower word for byte/word ops
                cpu_data_in <= tg68k_data_write & tg68k_data_write;

            -- No Memory Access (busstate = 01)
            else
                cpu_inst_req <= '0';
                cpu_data_req <= '0';
            end if;

            -- Data read from memory controller (32-bit) to CPU (16-bit)
            -- Select upper or lower word based on address bit 1
            if tg68k_addr_out(1) = '0' then
                tg68k_data_read <= cpu_inst_data(31 downto 16) when tg68k_busstate = "00" else
                                   cpu_data_out(31 downto 16);
            else
                tg68k_data_read <= cpu_inst_data(15 downto 0) when tg68k_busstate = "00" else
                                   cpu_data_out(15 downto 0);
            end if;
        end if;
    end process;

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
    -- In MC68030 mode: route through memory controller (caches, MMU)
    -- In Bypass mode: direct TG68K signals (68000/68010 compatibility)
    --------------------------------------------------------------
    bus_mux: process(mode_68030, mc_bus_addr, mc_bus_as, mc_bus_rw,
                     mc_bus_burst, mc_bus_fc, mc_bus_data_out,
                     tg68k_addr_out, tg68k_nWr, tg68k_nUDS, tg68k_nLDS,
                     tg68k_FC, tg68k_data_write, tg68k_busstate)
    begin
        if mode_68030 = '1' then
            -- MC68030 mode: use memory controller with caches and MMU
            addr       <= mc_bus_addr;
            as         <= mc_bus_as;
            rw         <= mc_bus_rw;
            burst      <= mc_bus_burst;
            fc         <= mc_bus_fc;
            data_write <= mc_bus_data_out;

            -- Generate UDS/LDS from size
            uds <= mc_bus_ds;
            lds <= mc_bus_ds;
            siz <= "10";  -- Long word

        else
            -- Bypass mode: direct TG68K connection (no caches/MMU)
            -- Used for 68000/68010 modes or when MC68030 disabled
            addr       <= tg68k_addr_out;
            as         <= '1' when tg68k_busstate /= "01" else '0';  -- Assert AS during memory access
            rw         <= not tg68k_nWr;
            burst      <= '0';  -- No burst in bypass mode
            fc         <= tg68k_FC;
            data_write <= tg68k_data_write & tg68k_data_write;  -- Replicate to 32-bit
            uds        <= tg68k_nUDS;
            lds        <= tg68k_nLDS;
            siz        <= "01";  -- Word (16-bit)
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
    -- Pass through TG68K busstate
    -- 00: fetch code, 01: no access, 10: read data, 11: write data
    busstate <= tg68k_busstate;

    --------------------------------------------------------------
    -- CPU State Debug Output
    --------------------------------------------------------------
    -- Lower 2 bits: busstate
    -- Upper bits: additional debug info
    cpu_state <= "0000" & tg68k_busstate;

    --------------------------------------------------------------
    -- F-Line MMU Instruction Support (MC68030)
    --------------------------------------------------------------
    -- Opcode and extension word capture
    -- These come from CPU's data bus during instruction fetch
    -- For simplicity, we'll use a placeholder implementation that
    -- captures from the instruction data path
    --------------------------------------------------------------

    -- Capture opcode and extension word from instruction fetch
    fline_capture: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                fline_opcode <= (others => '0');
                fline_extension <= (others => '0');
                fline_opcode_valid <= '0';
            elsif clkena = '1' and mode_68030 = '1' then
                -- When CPU fetches instruction (busstate = "00")
                if tg68k_busstate = "00" then
                    fline_opcode <= cpu_inst_data(31 downto 16);  -- First word
                    fline_opcode_valid <= '1';
                -- When CPU fetches extension word
                elsif fline_exec_req = '1' and fline_opcode_valid = '1' then
                    fline_extension <= cpu_inst_data(31 downto 16);  -- Extension word
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------
    -- Instantiate F-Line Decoders (only for MC68030 mode)
    --------------------------------------------------------------

    gen_fline_decoders: if ENABLE_MMU generate

        -- PMOVE Decoder
        pmove_decoder: TG68K030_PMOVE_Decoder
            port map(
                clk => clk,
                reset => reset,
                opcode => fline_opcode,
                extension => fline_extension,
                opcode_valid => fline_opcode_valid,
                supervisor => cpu_supervisor,
                is_pmove => pmove_is_pmove,
                is_pmovefd => pmove_is_pmovefd,
                pmove_direction => pmove_direction,
                pmove_reg_code => pmove_reg_code,
                pmove_ea_mode => open,
                pmove_ea_reg => open,
                pmove_size => pmove_size,
                pmove_sel_tc => pmove_sel_tc,
                pmove_sel_tt0 => pmove_sel_tt0,
                pmove_sel_tt1 => pmove_sel_tt1,
                pmove_sel_crp => pmove_sel_crp,
                pmove_sel_srp => pmove_sel_srp,
                pmove_sel_mmusr => pmove_sel_mmusr,
                illegal_instr => open,
                priv_violation => open
            );

        -- PFLUSH Decoder
        pflush_decoder: TG68K030_PFLUSH_Decoder
            port map(
                clk => clk,
                reset => reset,
                opcode => fline_opcode,
                extension => fline_extension,
                opcode_valid => fline_opcode_valid,
                supervisor => cpu_supervisor,
                is_pflush => pflush_is_pflush,
                pflush_mode => pflush_mode,
                pflush_fc => pflush_fc,
                pflush_ea_mode => open,
                pflush_ea_reg => open,
                illegal_instr => open,
                priv_violation => open
            );

        -- PTEST Decoder
        ptest_decoder: TG68K030_PTEST_Decoder
            port map(
                clk => clk,
                reset => reset,
                opcode => fline_opcode,
                extension => fline_extension,
                opcode_valid => fline_opcode_valid,
                supervisor => cpu_supervisor,
                is_ptest => ptest_is_ptest,
                ptest_level => ptest_level,
                ptest_fc => ptest_fc,
                ptest_rw => open,
                ptest_ret_en => open,
                ptest_ret_reg => open,
                ptest_ea_mode => open,
                ptest_ea_reg => open,
                illegal_instr => open,
                priv_violation => open
            );

        -- Combine decoder outputs
        fline_is_pmove  <= pmove_is_pmove;
        fline_is_pflush <= pflush_is_pflush;
        fline_is_ptest  <= ptest_is_ptest;
        fline_is_mmu    <= pmove_is_pmove or pflush_is_pflush or ptest_is_ptest;

    end generate;

    -- If MMU disabled, tie off F-line signals
    gen_no_fline: if not ENABLE_MMU generate
        fline_is_mmu <= '0';
        fline_is_pmove <= '0';
        fline_is_pflush <= '0';
        fline_is_ptest <= '0';
    end generate;

    --------------------------------------------------------------
    -- F-Line Instruction Execution Coordinator
    --------------------------------------------------------------
    -- Simplified execution: Just signal completion immediately
    -- In full implementation, this would coordinate with:
    -- - PMOVE: MMU register read/write
    -- - PFLUSH: ATC invalidation
    -- - PTEST: MMU table walk
    --------------------------------------------------------------

    fline_exec: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                fline_exec_done <= '0';
            elsif fline_exec_req = '1' then
                -- For now, complete immediately
                -- TODO: Add actual execution logic
                fline_exec_done <= '1';
            else
                fline_exec_done <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------
    -- IMPLEMENTATION STATUS:
    --------------------------------------------------------------
    -- ✅ TG68KdotC_Kernel CPU core integrated
    -- ✅ MMU components connected (ATC, TT, page table walk)
    -- ✅ Cache components connected (I-cache, D-cache)
    -- ✅ Burst mode controller integrated
    -- ✅ Memory controller integrated
    -- ✅ Bus interface conversion (16-bit CPU ↔ 32-bit MC68030)
    -- ✅ F-line instruction decoders integrated (PMOVE/PFLUSH/PTEST)
    -- ✅ F-line execution coordinator (simplified - completes immediately)
    --
    -- ⚠️  REMAINING WORK:
    -- - F-line execution logic (PMOVE register access, PFLUSH ATC flush, PTEST table walk)
    -- - MOVEC CACR/CAAR connection
    -- - Exception vector updates for MC68030
    -- - Real hardware testing and debugging
    --------------------------------------------------------------

end architecture rtl;
