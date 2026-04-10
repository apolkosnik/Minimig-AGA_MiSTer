library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rte_ccr_restore is
end entity;

architecture behavior of tb_rte_ccr_restore is
    signal clk        : std_logic := '0';
    signal nReset     : std_logic := '0';
    signal clkena_in  : std_logic := '1';
    signal data_in    : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal busstate   : std_logic_vector(1 downto 0);
    signal FC         : std_logic_vector(2 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 1,
            extAddr_Mode   => 1,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",
            addr_out => addr_out,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            FC => FC,
            longword => open,
            nResetOut => open,
            clr_berr => open,
            skipFetch => open,
            regin_out => open,
            CACR_out => open,
            VBR_out => open,
            cache_inv_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr => open,
            pmmu_reg_we => open,
            pmmu_reg_re => open,
            pmmu_reg_sel => open,
            pmmu_reg_wdat => open,
            pmmu_reg_part => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req => open,
            pmmu_walker_we => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
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

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 8191 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 8191 then
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable wrote_final : boolean := false;
    begin
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset: SSP=$0800, PC=$1000.
        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- TRAP #0 vector -> $1400.
        mem(16#0080# / 2) := x"0000";
        mem(16#0082# / 2) := x"1400";

        -- Initial program: enter test body through RTE, matching cputest 020+.
        mem(16#1000# / 2) := x"4E73"; -- RTE

        -- Format-0 frame: SR=$2079, PC=$1200, fmt/vec=$0000.
        mem(16#0800# / 2) := x"2079";
        mem(16#0802# / 2) := x"0000";
        mem(16#0804# / 2) := x"1200";
        mem(16#0806# / 2) := x"0000";

        -- $1200: read CCR first, then EORI.W #$0079,SR, then read back CCR and SR.
        mem(16#1200# / 2) := x"42C0"; -- MOVE CCR,D0
        mem(16#1202# / 2) := x"33C0"; mem(16#1204# / 2) := x"0000"; mem(16#1206# / 2) := x"3000";
        mem(16#1208# / 2) := x"0A7C"; mem(16#120A# / 2) := x"0079"; -- EORI.W #$0079,SR
        mem(16#120C# / 2) := x"42C0"; -- MOVE CCR,D0
        mem(16#120E# / 2) := x"33C0"; mem(16#1210# / 2) := x"0000"; mem(16#1212# / 2) := x"3002";
        mem(16#1214# / 2) := x"40C0"; -- MOVE SR,D0
        mem(16#1216# / 2) := x"33C0"; mem(16#1218# / 2) := x"0000"; mem(16#121A# / 2) := x"3004";
        mem(16#121C# / 2) := x"4E40"; -- TRAP #0

        mem(16#1400# / 2) := x"4E72";
        mem(16#1402# / 2) := x"2700";

        report "=== RTE low-byte SR restore / EORI.SR regression probe ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 20000 loop
            wait until rising_edge(clk);
            if busstate = "11" and nWr = '0' and addr_out(15 downto 0) = x"3004" then
                wrote_final := true;
                exit;
            end if;
        end loop;

        assert wrote_final report "timeout waiting for final CCR write" severity failure;

        report "RTE CCR readback = $" & to_hstring(mem(16#3000# / 2)) severity note;
        report "EORI CCR readback= $" & to_hstring(mem(16#3002# / 2)) severity note;
        report "EORI SR readback = $" & to_hstring(mem(16#3004# / 2)) severity note;

        test_done <= true;
        wait;
    end process;
end architecture;
