library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_tt0_displacement is
end tb_pmove_tt0_displacement;

architecture behavior of tb_pmove_tt0_displacement is

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
    signal clkena : std_logic := '1';
    signal data_in : std_logic_vector(15 downto 0) := (others => '0');
    signal addr : std_logic_vector(31 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal nWr : std_logic;
    signal nUDS, nLDS : std_logic;
    signal busstate : std_logic_vector(1 downto 0);

    -- PMMU signals
    signal pmmu_reg_wdat : std_logic_vector(31 downto 0);
    signal pmmu_reg_sel : std_logic_vector(4 downto 0);
    signal pmmu_reg_we : std_logic;
    signal pmmu_reg_re : std_logic;
    signal pmmu_walker_req : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    -- Memory simulation
    type memory_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    signal memory : memory_t := (others => X"0000");

    signal instruction_phase : integer := 0;
    signal cycle_count : integer := 0;

    constant CLK_PERIOD : time := 20 ns;

begin

    clk <= not clk after CLK_PERIOD/2;

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
            CPU => "10",  -- 68020/030
            addr_out => addr,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            longword => open,
            nResetOut => open,
            FC => open,
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

    -- Memory simulation
    process(clk)
    begin
        if rising_edge(clk) then
            if clkena = '1' then
                -- Read from memory
                if busstate = "00" or busstate = "10" then  -- Fetch or read
                    data_in <= memory(to_integer(unsigned(addr(13 downto 1))));
                end if;

                -- Write to memory
                if busstate = "11" and nWr = '0' then  -- Write
                    if nUDS = '0' then
                        memory(to_integer(unsigned(addr(13 downto 1))))(15 downto 8) <= data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        memory(to_integer(unsigned(addr(13 downto 1))))(7 downto 0) <= data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Test stimulus
    process
    begin
        -- Load test program
        -- Address $000: RESET vector
        memory(0) <= X"0000";
        memory(1) <= X"1000";
        memory(2) <= X"0000";
        memory(3) <= X"0400";

        -- Address $400: Test program
        -- MOVE.L #$12345678,D0  ; Load test value
        memory(512) <= X"203C";
        memory(513) <= X"1234";
        memory(514) <= X"5678";

        -- PMOVE D0,TT0         ; dc.w $f010,$0a00
        memory(515) <= X"F010";
        memory(516) <= X"0A00";

        -- MOVE.L #$3000,A7     ; Set stack pointer
        memory(517) <= X"2E7C";
        memory(518) <= X"0000";
        memory(519) <= X"3000";

        -- PMOVE TT0,(-4,A7)    ; dc.w $f02f,$0a00,$fffc
        memory(520) <= X"F02F";
        memory(521) <= X"0A00";
        memory(522) <= X"FFFC";

        -- ILLEGAL (to stop)
        memory(523) <= X"4AFC";

        -- Reset CPU
        reset <= '0';
        wait for 100 ns;
        reset <= '1';
        wait for 100 ns;

        -- Run for enough cycles
        wait for 50 us;

        -- Check results
        report "Test complete" severity note;
        report "Cycle count: " & integer'image(cycle_count) severity note;
        report "Final addr: " & integer'image(to_integer(unsigned(addr))) severity note;
        report "Memory at $2FFC: " & integer'image(to_integer(unsigned(memory(6143)))) & " (should be high word of TT0)" severity note;
        report "Memory at $2FFE: " & integer'image(to_integer(unsigned(memory(6144)))) & " (should be low word of TT0)" severity note;

        -- Check if TT0 value ($12345678) was written
        if memory(6143) = X"1234" and memory(6144) = X"5678" then
            report "SUCCESS: PMOVE TT0,(-4,A7) worked correctly!" severity note;
        else
            report "FAIL: Wrong data written. Expected $12345678" severity error;
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

end behavior;
