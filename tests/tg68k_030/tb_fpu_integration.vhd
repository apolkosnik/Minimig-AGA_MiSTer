--------------------------------------------------------------------------------
-- TG68K FPU Integration Test
-- Tests FTST + FSAVE sequence with actual TG68KdotC_Kernel
-- Validates DiagROM FPU detection will work correctly
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.TG68K_Pack.all;

entity tb_fpu_integration is
end tb_fpu_integration;

architecture behavior of tb_fpu_integration is

    -- Component declaration for TG68KdotC_Kernel
    component TG68KdotC_Kernel
        generic(
            SR_Read : integer := 2;
            VBR_Stackframe : integer := 2;
            extAddr_Mode : integer := 2;
            MUL_Mode : integer := 2;
            DIV_Mode : integer := 2;
            BitField : integer := 2;
            BarrelShifter : integer := 2;
            MUL_Hardware : integer := 1;
            FPU_Enable : integer := 1
        );
        port(
            clk : in std_logic;
            nReset : in std_logic;
            clkena_in : in std_logic;
            data_in : in std_logic_vector(31 downto 0);
            IPL : in std_logic_vector(2 downto 0);
            IPL_autovector : in std_logic;
            CPU : in std_logic_vector(1 downto 0);
            addr : out std_logic_vector(31 downto 0);
            data_write : out std_logic_vector(31 downto 0);
            nWr : out std_logic;
            nUDS : out std_logic;
            nLDS : out std_logic;
            busstate : out std_logic_vector(1 downto 0);
            nResetOut : out std_logic;
            FC : out std_logic_vector(2 downto 0);
            clr_berr : out std_logic;
            CACR_out : out std_logic_vector(31 downto 0);
            VBR_out : out std_logic_vector(31 downto 0);
            regin_out : buffer std_logic_vector(31 downto 0);

            -- PMMU signals (required but not used in this test)
            mmu_tt0 : out std_logic_vector(31 downto 0);
            mmu_tt1 : out std_logic_vector(31 downto 0);

            -- Cache interface (required but not used)
            dcache_fill_request : out std_logic;
            dcache_fill_done : in std_logic;
            icache_fill_request : out std_logic;
            icache_fill_done : in std_logic
        );
    end component;

    -- Clock and control
    constant clk_period : time := 10 ns;
    signal clk : std_logic := '0';
    signal nReset : std_logic := '0';
    signal clkena_in : std_logic := '1';
    signal test_running : boolean := true;

    -- CPU interface signals
    signal data_in : std_logic_vector(31 downto 0) := X"00000000";
    signal IPL : std_logic_vector(2 downto 0) := "111";
    signal IPL_autovector : std_logic := '0';
    signal CPU : std_logic_vector(1 downto 0) := "11";  -- 68030 mode
    signal addr : std_logic_vector(31 downto 0);
    signal data_write : std_logic_vector(31 downto 0);
    signal nWr : std_logic;
    signal nUDS : std_logic;
    signal nLDS : std_logic;
    signal busstate : std_logic_vector(1 downto 0);
    signal nResetOut : std_logic;
    signal FC : std_logic_vector(2 downto 0);
    signal clr_berr : std_logic;
    signal CACR_out : std_logic_vector(31 downto 0);
    signal VBR_out : std_logic_vector(31 downto 0);
    signal regin_out : std_logic_vector(31 downto 0);
    signal mmu_tt0 : std_logic_vector(31 downto 0);
    signal mmu_tt1 : std_logic_vector(31 downto 0);
    signal dcache_fill_done : std_logic := '0';
    signal icache_fill_done : std_logic := '0';
    signal dcache_fill_request : std_logic;
    signal icache_fill_request : std_logic;

    -- Memory for instruction fetch
    type mem_t is array(0 to 1023) of std_logic_vector(15 downto 0);
    signal rom : mem_t := (others => X"4E71");  -- NOP

    -- Test control
    signal cycle_count : integer := 0;
    signal ftst_executed : boolean := false;
    signal fsave_started : boolean := false;
    signal test_complete : boolean := false;

begin

    -- Instantiate CPU
    uut: TG68KdotC_Kernel
        generic map(
            SR_Read => 2,
            VBR_Stackframe => 2,
            extAddr_Mode => 2,
            MUL_Mode => 2,
            DIV_Mode => 2,
            BitField => 2,
            BarrelShifter => 2,
            MUL_Hardware => 1,
            FPU_Enable => 1
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => IPL,
            IPL_autovector => IPL_autovector,
            CPU => CPU,
            addr => addr,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            nResetOut => nResetOut,
            FC => FC,
            clr_berr => clr_berr,
            CACR_out => CACR_out,
            VBR_out => VBR_out,
            regin_out => regin_out,
            mmu_tt0 => mmu_tt0,
            mmu_tt1 => mmu_tt1,
            dcache_fill_request => dcache_fill_request,
            dcache_fill_done => dcache_fill_done,
            icache_fill_request => icache_fill_request,
            icache_fill_done => icache_fill_done
        );

    -- Clock generation
    clk_process: process
    begin
        while test_running loop
            clk <= '0';
            wait for clk_period/2;
            clk <= '1';
            wait for clk_period/2;
        end loop;
        wait;
    end process;

    -- Initialize ROM with test program
    init_rom: process
    begin
        -- Address 0x000: Reset SP (will be read as long)
        rom(0) <= X"0000";
        rom(1) <= X"1000";

        -- Address 0x004: Reset PC (will be read as long)
        rom(2) <= X"0000";
        rom(3) <= X"0100";

        -- Address 0x100: FTST.B D0 (F201 583A)
        rom(128) <= X"F201";
        rom(129) <= X"583A";

        -- Address 0x104: FSAVE -(A7) (F327)
        rom(130) <= X"F327";

        -- Address 0x106: STOP #$2700
        rom(131) <= X"4E72";
        rom(132) <= X"2700";

        wait;
    end process;

    -- Memory interface
    mem_interface: process(clk)
        variable word_addr : integer;
    begin
        if rising_edge(clk) then
            if clkena_in = '1' then
                -- Simple ROM read
                if busstate = "01" then  -- Read cycle
                    word_addr := to_integer(unsigned(addr(10 downto 1)));
                    if word_addr < 1024 then
                        if nUDS = '0' and nLDS = '0' then
                            -- Word access
                            data_in <= rom(word_addr) & rom(word_addr);
                        elsif nUDS = '0' then
                            -- Upper byte
                            data_in <= rom(word_addr) & X"0000";
                        elsif nLDS = '0' then
                            -- Lower byte
                            data_in <= X"0000" & rom(word_addr);
                        end if;
                    else
                        data_in <= X"00000000";
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Test monitor
    test_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '1' and clkena_in = '1' then
                cycle_count <= cycle_count + 1;

                -- Monitor instruction fetch
                if busstate = "01" and FC = "010" then  -- Program fetch
                    if addr(15 downto 0) = X"0100" and not ftst_executed then
                        report "Fetching FTST.B instruction at 0x100";
                        ftst_executed <= true;
                    elsif addr(15 downto 0) = X"0104" and ftst_executed and not fsave_started then
                        report "Fetching FSAVE instruction at 0x104";
                        fsave_started <= true;
                    elsif addr(15 downto 0) = X"0106" and fsave_started and not test_complete then
                        report "Test sequence complete - reached STOP";
                        test_complete <= true;
                    end if;
                end if;

                -- Monitor stack writes (FSAVE frame)
                if nWr = '0' and busstate = "10" then  -- Write cycle
                    if FC = "101" or FC = "110" then  -- Supervisor data
                        report "FSAVE writing to stack at address " &
                               integer'image(to_integer(unsigned(addr))) &
                               " data=" & integer'image(to_integer(unsigned(data_write)));
                    end if;
                end if;

                -- Timeout
                if cycle_count > 10000 then
                    report "TIMEOUT: Test did not complete in 10000 cycles" severity error;
                    test_running <= false;
                end if;

                if test_complete then
                    report "========================================";
                    report "FPU Integration Test Complete";
                    report "FTST executed: " & boolean'image(ftst_executed);
                    report "FSAVE started: " & boolean'image(fsave_started);
                    report "Total cycles: " & integer'image(cycle_count);
                    report "========================================";
                    test_running <= false;
                end if;
            end if;
        end if;
    end process;

    -- Test control
    test_process: process
    begin
        -- Reset
        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';
        wait for 50 ns;

        report "========== FPU Integration Test ==========";
        report "Testing FTST + FSAVE sequence with real CPU";
        report "==========================================";

        -- Wait for test to complete
        wait until not test_running;

        wait;
    end process;

end behavior;
