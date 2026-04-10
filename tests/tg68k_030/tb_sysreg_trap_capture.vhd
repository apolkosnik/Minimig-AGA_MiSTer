library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sysreg_trap_capture is
end entity;

architecture behavior of tb_sysreg_trap_capture is
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

    function hex_char(nib : std_logic_vector(3 downto 0)) return character is
    begin
        case nib is
            when "0000" => return '0';
            when "0001" => return '1';
            when "0010" => return '2';
            when "0011" => return '3';
            when "0100" => return '4';
            when "0101" => return '5';
            when "0110" => return '6';
            when "0111" => return '7';
            when "1000" => return '8';
            when "1001" => return '9';
            when "1010" => return 'A';
            when "1011" => return 'B';
            when "1100" => return 'C';
            when "1101" => return 'D';
            when "1110" => return 'E';
            when others => return 'F';
        end case;
    end function;

    function hex16(value : std_logic_vector(15 downto 0)) return string is
        variable s : string(1 to 4);
    begin
        s(1) := hex_char(value(15 downto 12));
        s(2) := hex_char(value(11 downto 8));
        s(3) := hex_char(value(7 downto 4));
        s(4) := hex_char(value(3 downto 0));
        return s;
    end function;
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
        procedure init_common(initial_sr : std_logic_vector(15 downto 0)) is
        begin
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            mem(0) := x"0000";
            mem(1) := x"0800";
            mem(2) := x"0000";
            mem(3) := x"1000";

            mem(16#0010# / 2) := x"0000";
            mem(16#0012# / 2) := x"1400";
            mem(16#0024# / 2) := x"0000";
            mem(16#0026# / 2) := x"1400";

            mem(16#1000# / 2) := x"4E73"; -- RTE
            mem(16#0800# / 2) := initial_sr;
            mem(16#0802# / 2) := x"0000";
            mem(16#0804# / 2) := x"1200";
            mem(16#0806# / 2) := x"0000";

            mem(16#1400# / 2) := x"4E72";
            mem(16#1402# / 2) := x"2700";
        end procedure;

        procedure run_until_trap(variable trap_seen : out boolean) is
            variable seen : boolean := false;
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 20000 loop
                wait until rising_edge(clk);
                if addr_out(15 downto 0) = x"1400" then
                    seen := true;
                    exit;
                end if;
            end loop;

            trap_seen := seen;
        end procedure;

        variable trap_seen : boolean;
    begin
        report "=== system-register trap-capture probe ===" severity note;

        init_common(x"0000");
        mem(16#1200# / 2) := x"0A3C";
        mem(16#1202# / 2) := x"002A"; -- EORI.B #$2A,CCR
        mem(16#1204# / 2) := x"2048"; -- MOVEA.L A0,A0
        mem(16#1206# / 2) := x"4AFC"; -- ILLEGAL
        run_until_trap(trap_seen);
        assert trap_seen report "timeout on EORI.B #$2A,CCR probe" severity failure;
        report "EORI.B #$2A,CCR user + MOVEA trapped SR = $" & hex16(mem(16#0800# / 2)) severity note;

        init_common(x"2000");
        mem(16#1200# / 2) := x"0A7C";
        mem(16#1202# / 2) := x"0079"; -- EORI.W #$0079,SR
        mem(16#1204# / 2) := x"2048"; -- MOVEA.L A0,A0
        mem(16#1206# / 2) := x"4AFC"; -- ILLEGAL
        run_until_trap(trap_seen);
        assert trap_seen report "timeout on EORI.W #$0079,SR probe" severity failure;
        report "EORI.W #$0079,SR supervisor + MOVEA trapped SR = $" & hex16(mem(16#0800# / 2)) severity note;

        init_common(x"0000");
        mem(16#1200# / 2) := x"74FF"; -- MOVEQ #-1,D2
        mem(16#1202# / 2) := x"44C2"; -- MOVE.W D2,CCR
        mem(16#1204# / 2) := x"2048"; -- MOVEA.L A0,A0
        mem(16#1206# / 2) := x"4AFC"; -- ILLEGAL
        run_until_trap(trap_seen);
        assert trap_seen report "timeout on MOVE.W D2,CCR probe" severity failure;
        report "MOVE.W D2,CCR user + MOVEA trapped SR = $" & hex16(mem(16#0800# / 2)) severity note;

        init_common(x"2000");
        mem(16#1200# / 2) := x"263C"; -- MOVE.L #$0000AAAA,D3
        mem(16#1202# / 2) := x"0000";
        mem(16#1204# / 2) := x"AAAA";
        mem(16#1206# / 2) := x"46C3"; -- MOVE.W D3,SR
        mem(16#1208# / 2) := x"2048"; -- MOVEA.L A0,A0
        mem(16#120A# / 2) := x"4AFC"; -- ILLEGAL
        run_until_trap(trap_seen);
        assert trap_seen report "timeout on MOVE.W D3,SR probe" severity failure;
        report "MOVE.W D3,SR + MOVEA trapped SR = $" & hex16(mem(16#0800# / 2)) severity note;

        init_common(x"0000");
        mem(16#1000# / 2) := x"4E77"; -- RTR
        mem(16#0800# / 2) := x"00A0"; -- stacked CCR image with unused bits set
        mem(16#0802# / 2) := x"0000";
        mem(16#0804# / 2) := x"1200";
        mem(16#1200# / 2) := x"2048"; -- MOVEA.L A0,A0
        mem(16#1202# / 2) := x"4AFC"; -- ILLEGAL
        run_until_trap(trap_seen);
        assert trap_seen report "timeout on RTR probe" severity failure;
        report "RTR stacked CCR + MOVEA trapped SR = $" & hex16(mem(16#0800# / 2)) severity note;

        test_done <= true;
        wait;
    end process;
end architecture;
