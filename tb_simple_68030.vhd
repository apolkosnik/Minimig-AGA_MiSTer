-- Simple 68030 CPU="10" test based on working tb_pmove_tt0_displacement
-- Tests basic execution: MOVEQ instructions
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_simple_68030 is
end tb_simple_68030;

architecture behavior of tb_simple_68030 is

    component TG68KdotC_Kernel
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
            CACR_out : out std_logic_vector(31 downto 0);
            VBR_out : out std_logic_vector(31 downto 0);
            cache_cinv_req : out std_logic;
            cache_cpush_req : out std_logic;
            cache_op_scope : out std_logic_vector(1 downto 0);
            cache_op_cache : out std_logic_vector(1 downto 0);
            cacr_ie : out std_logic;
            cacr_de : out std_logic;
            cacr_ifreeze : out std_logic;
            cacr_dfreeze : out std_logic;
            cacr_ibe : out std_logic;
            cacr_dbe : out std_logic;
            cacr_wa : out std_logic;
            pmmu_reg_we : out std_logic;
            pmmu_reg_re : out std_logic;
            pmmu_reg_sel : out std_logic_vector(4 downto 0);
            pmmu_reg_wdat : out std_logic_vector(31 downto 0);
            pmmu_reg_part : out std_logic;
            pmmu_addr_log : out std_logic_vector(31 downto 0);
            pmmu_addr_phys : out std_logic_vector(31 downto 0);
            pmmu_cache_inhibit : out std_logic;
            cache_op_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_req : out std_logic;
            pmmu_walker_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_ack : in std_logic;
            pmmu_walker_data : in std_logic_vector(31 downto 0);
            debug_SVmode : out std_logic;
            debug_preSVmode : out std_logic;
            debug_FlagsSR_S : out std_logic;
            debug_changeMode : out std_logic;
            debug_setopcode : out std_logic;
            debug_exec_directSR : out std_logic;
            debug_exec_to_SR : out std_logic;
            debug_pmove_dn_mode : out std_logic;
            debug_pmove_dn_regnum : out std_logic_vector(2 downto 0)
        );
    end component;

    signal clk : std_logic := '0';
    signal reset : std_logic := '0';
    signal clkena : std_logic;  -- Computed, not constant!
    signal data_in : std_logic_vector(15 downto 0) := (others => '0');
    signal addr : std_logic_vector(31 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal nWr : std_logic;
    signal nUDS, nLDS : std_logic;
    signal busstate : std_logic_vector(1 downto 0);
    signal FC : std_logic_vector(2 downto 0);
    signal nResetOut : std_logic;

    -- PMMU signals
    signal pmmu_reg_wdat : std_logic_vector(31 downto 0);
    signal pmmu_reg_sel : std_logic_vector(4 downto 0);
    signal pmmu_reg_we : std_logic;
    signal pmmu_reg_re : std_logic;
    signal pmmu_walker_req : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    -- PMMU register file simulation
    type pmmu_regs_t is array(0 to 31) of std_logic_vector(31 downto 0);
    signal pmmu_regs : pmmu_regs_t := (others => (others => '0'));

    -- Memory simulation
    type memory_t is array(0 to 8191) of std_logic_vector(15 downto 0);

    -- Memory initialization function
    function init_memory return memory_t is
        variable result : memory_t := (others => X"0000");
    begin
        -- Reset vectors
        result(0) := X"0000";
        result(1) := X"1000";  -- SSP = $00001000
        result(2) := X"0000";
        result(3) := X"0400";  -- PC = $00000400

        -- Test program at $400
        result(512) := X"7001";  -- MOVEQ #1,D0
        result(513) := X"7202";  -- MOVEQ #2,D1
        result(514) := X"4E71";  -- NOP
        result(515) := X"4E71";  -- NOP
        result(516) := X"4AFC";  -- ILLEGAL

        return result;
    end function;

    signal memory : memory_t := init_memory;

    signal cycle_count : integer := 0;
    signal test_passed : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

begin

    clk <= not clk after CLK_PERIOD/2;

    -- CPU clock enable: stall CPU when PMMU walker is active
    clkena <= not pmmu_walker_req;

    uut: TG68KdotC_Kernel
        generic map(
            SR_Read => 2,
            VBR_Stackframe => 2,
            extAddr_Mode => 2,
            MUL_Mode => 2,
            DIV_Mode => 2,
            BitField => 2,
            BarrelShifter => 1,
            MUL_Hardware => 1
        )
        port map(
            clk => clk,
            nReset => reset,
            clkena_in => clkena,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '0',
            berr => '0',
            CPU => "10",  -- 68030 with PMMU
            addr_out => addr,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            longword => open,
            nResetOut => nResetOut,
            FC => FC,
            clr_berr => open,
            skipFetch => open,
            regin_out => open,
            CACR_out => open,
            VBR_out => open,
            cache_cinv_req => open,
            cache_cpush_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cacr_ie => open,
            cacr_de => open,
            cacr_ifreeze => open,
            cacr_dfreeze => open,
            cacr_ibe => open,
            cacr_dbe => open,
            cacr_wa => open,
            pmmu_reg_we => pmmu_reg_we,
            pmmu_reg_re => pmmu_reg_re,
            pmmu_reg_sel => pmmu_reg_sel,
            pmmu_reg_wdat => pmmu_reg_wdat,
            pmmu_reg_part => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            cache_op_addr => open,
            pmmu_walker_req => pmmu_walker_req,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open
        );

    -- Memory read - COMBINATIONAL for immediate response
    process(addr, busstate)
        variable addr_idx : integer;
    begin
        if busstate /= "11" then  -- Read on any non-write state
            addr_idx := to_integer(unsigned(addr(13 downto 1)));
            if addr_idx < 8192 then
                data_in <= memory(addr_idx);
            else
                data_in <= X"4E71";  -- NOP for out of range
            end if;
        end if;
    end process;

    -- Memory write - CLOCKED
    process(clk)
    begin
        if rising_edge(clk) then
            if clkena = '1' and busstate = "11" and nWr = '0' then
                if nUDS = '0' then
                    memory(to_integer(unsigned(addr(13 downto 1))))(15 downto 8) <= data_write(15 downto 8);
                end if;
                if nLDS = '0' then
                    memory(to_integer(unsigned(addr(13 downto 1))))(7 downto 0) <= data_write(7 downto 0);
                end if;
            end if;
        end if;
    end process;

    -- Monitor fetches and critical signals
    process(clk)
        variable fetch_count : integer := 0;
    begin
        if rising_edge(clk) then
            -- Report reset status change
            if reset'event then
                report "RESET changed to " & std_logic'image(reset);
            end if;
            if nResetOut'event then
                report "nResetOut changed to " & std_logic'image(nResetOut);
            end if;

            -- Monitor fetches (busstate="00" = fetch code)
            if busstate = "00" then
                fetch_count := fetch_count + 1;
                if fetch_count <= 20 then
                    report "FETCH #" & integer'image(fetch_count) &
                           ": addr=$" & integer'image(to_integer(unsigned(addr(15 downto 0)))) &
                           " data=$" & integer'image(to_integer(unsigned(data_in))) &
                           " FC=" & integer'image(to_integer(unsigned(FC))) &
                           " clkena=" & std_logic'image(clkena) &
                           " pmmu_walker_req=" & std_logic'image(pmmu_walker_req) &
                           " reset=" & std_logic'image(reset) &
                           " nResetOut=" & std_logic'image(nResetOut);
                end if;

                -- Check for test pass condition
                if addr(15 downto 0) = X"040A" then
                    report "===== SUCCESS: Reached $40A (ILLEGAL after test program) =====";
                    test_passed <= true;
                end if;

                if addr(15 downto 0) = X"0400" then
                    report "===== GREAT: Reached $400 (start of test program) =====";
                end if;
            end if;
        end if;
    end process;

    -- Test stimulus
    process
    begin
        -- Debug: Print memory contents
        report "MEM[0]=$" & integer'image(to_integer(unsigned(memory(0))));
        report "MEM[1]=$" & integer'image(to_integer(unsigned(memory(1))));
        report "MEM[2]=$" & integer'image(to_integer(unsigned(memory(2))));
        report "MEM[3]=$" & integer'image(to_integer(unsigned(memory(3))));
        report "MEM[512]=$" & integer'image(to_integer(unsigned(memory(512))));

        -- Reset CPU
        reset <= '0';
        wait for 100 ns;
        reset <= '1';
        wait for 100 ns;

        -- Run for enough cycles
        wait for 50 us;

        -- Check results
        if test_passed then
            report "===== TEST PASSED =====" severity note;
        else
            report "===== TEST FAILED: Did not reach expected address =====" severity error;
        end if;

        wait;
    end process;

    -- Cycle counter
    process(clk)
    begin
        if rising_edge(clk) and clkena = '1' then
            cycle_count <= cycle_count + 1;
        end if;
    end process;

    -- PMMU walker response - immediately acknowledge with invalid descriptor
    process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' then
                pmmu_walker_ack <= '1';
                pmmu_walker_data <= X"00000000";  -- Invalid descriptor (MMU disabled)
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

end behavior;
