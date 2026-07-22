-- STOP #imm supervisor-to-user stack regression.
-- STOP loads the entire SR before entering the stopped state. When it clears
-- S, A7 must select USP; the interrupt that resumes the core must then switch
-- to ISP, stack the user SR there, and fetch the handler as supervisor code.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_stop_to_user_stack is
end entity;

architecture behavioral of tb_stop_to_user_stack is
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
    signal ipl_sig    : std_logic_vector(2 downto 0) := "111";
    signal debug_stop : std_logic;
    signal debug_s    : std_logic;
    signal debug_sv   : std_logic;
    signal debug_pre_sv : std_logic;

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;

    procedure wait_cycles(count : natural) is
    begin
        for i in 1 to count loop
            wait until rising_edge(clk);
        end loop;
    end procedure;
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
            IPL => ipl_sig,
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
            debug_SVmode => debug_sv,
            debug_preSVmode => debug_pre_sv,
            debug_FlagsSR_S => debug_s,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_stop => debug_stop
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
        variable saw_stop    : boolean := false;
        variable saw_handler : boolean := false;
        variable saw_priv_handler : boolean := false;
        variable done_seen   : boolean := false;
        variable handler_fc  : std_logic_vector(2 downto 0) := "000";
        variable active_a7   : std_logic_vector(31 downto 0);
    begin
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset ISP/PC, plus level-7 autovector to handler $1100.
        mem(0) := x"0000"; mem(1) := x"0800";
        mem(2) := x"0000"; mem(3) := x"1000";
        mem(16#007C# / 2) := x"0000";
        mem(16#007E# / 2) := x"1100";
        mem(16#0020# / 2) := x"0000";
        mem(16#0022# / 2) := x"1200";

        -- Establish three distinct stack aliases, enter MSP supervisor state,
        -- then STOP with S=0. The handler must run on ISP, not either of the
        -- stopped-state aliases.
        mem(16#1000# / 2) := x"203C";  -- MOVE.L #$0980,D0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0980";
        mem(16#1006# / 2) := x"4E7B";  -- MOVEC D0,ISP
        mem(16#1008# / 2) := x"0804";
        mem(16#100A# / 2) := x"223C";  -- MOVE.L #$0A80,D1
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"0A80";
        mem(16#1010# / 2) := x"4E7B";  -- MOVEC D1,MSP
        mem(16#1012# / 2) := x"1803";
        mem(16#1014# / 2) := x"243C";  -- MOVE.L #$0B80,D2
        mem(16#1016# / 2) := x"0000";
        mem(16#1018# / 2) := x"0B80";
        mem(16#101A# / 2) := x"4E7B";  -- MOVEC D2,USP
        mem(16#101C# / 2) := x"2800";
        mem(16#101E# / 2) := x"46FC";  -- MOVE.W #$3000,SR (S=1, M=1)
        mem(16#1020# / 2) := x"3000";
        mem(16#1022# / 2) := x"4E72";  -- STOP #$0000 (select USP)
        mem(16#1024# / 2) := x"0000";
        mem(16#1026# / 2) := x"4E72";  -- STOP #$2700 from user mode: vector 8
        mem(16#1028# / 2) := x"2700";

        -- Interrupt handler records its active A7, then returns to user mode.
        mem(16#1100# / 2) := x"200F";  -- MOVE.L A7,D0
        mem(16#1102# / 2) := x"23C0";  -- MOVE.L D0,($1600).L
        mem(16#1104# / 2) := x"0000";
        mem(16#1106# / 2) := x"1600";
        mem(16#1108# / 2) := x"33FC";  -- MOVE.W #$600D,($1608).L
        mem(16#110A# / 2) := x"600D";
        mem(16#110C# / 2) := x"0000";
        mem(16#110E# / 2) := x"1608";
        mem(16#1110# / 2) := x"4E73";  -- RTE to the user STOP at $1026

        -- Privilege-violation handler marks successful rejection of user STOP.
        mem(16#1200# / 2) := x"33FC";  -- MOVE.W #$600E,($160A).L
        mem(16#1202# / 2) := x"600E";
        mem(16#1204# / 2) := x"0000";
        mem(16#1206# / 2) := x"160A";
        mem(16#1208# / 2) := x"60FE";

        report "=== STOP #$0000 supervisor-to-user stack test ===" severity note;
        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 8000 loop
            wait until rising_edge(clk);
            if debug_stop = '1' then
                saw_stop := true;
                exit;
            end if;
        end loop;
        if not saw_stop then
            report "FAIL: CPU did not enter STOP" severity failure;
        end if;

        wait_cycles(4);
        if debug_s /= '0' or debug_sv /= '0' or debug_pre_sv /= '0' then
            report "FAIL: STOP #$0000 did not leave the core in user state; S=" &
                   std_logic'image(debug_s) & " SV=" & std_logic'image(debug_sv) &
                   " preSV=" & std_logic'image(debug_pre_sv) severity failure;
        end if;

        ipl_sig <= "000";
        for i in 0 to 4000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1100" then
                saw_handler := true;
                handler_fc := FC;
                exit;
            end if;
        end loop;
        ipl_sig <= "111";
        if not saw_handler then
            report "FAIL: level-7 interrupt did not resume STOP / reach handler" severity failure;
        end if;

        for i in 0 to 8000 loop
            wait until rising_edge(clk);
            if mem(16#1608# / 2) = x"600D" then
                done_seen := true;
                exit;
            end if;
        end loop;
        if not done_seen then
            report "FAIL: handler did not publish its active A7" severity failure;
        end if;

        active_a7 := mem(16#1600# / 2) & mem(16#1602# / 2);
        if active_a7(15 downto 8) /= x"09" then
            report "FAIL: interrupt after STOP #$0000 used a non-ISP stack" severity failure;
        elsif handler_fc /= "110" then
            report "FAIL: interrupt handler fetch FC was not supervisor-program" severity failure;
        end if;

        for i in 0 to 8000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1200" then
                saw_priv_handler := true;
                exit;
            end if;
        end loop;
        if not saw_priv_handler then
            report "FAIL: user-mode STOP did not take privilege vector 8" severity failure;
        else
            done_seen := false;
            for i in 0 to 8000 loop
                wait until rising_edge(clk);
                if mem(16#160A# / 2) = x"600E" then
                    done_seen := true;
                    exit;
                end if;
            end loop;
            if not done_seen then
                report "FAIL: user STOP privilege handler did not complete" severity failure;
            else
                report "PASS: STOP selected user state, wakeup used ISP/FC=110, and user STOP trapped" severity note;
            end if;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
