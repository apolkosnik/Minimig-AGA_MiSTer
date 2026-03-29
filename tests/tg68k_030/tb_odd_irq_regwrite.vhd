-- tb_odd_irq_regwrite.vhd
-- Reproducer for WinUAE cputest ODD_IRQ retire-before-interrupt behavior on
-- internal register-writeback instructions. Unlike the earlier fetch-trigger
-- reproducer, this bench mirrors execute_test020(): a level-1 interrupt is
-- already pending, reset/setup run with IPL=7, and RTE restores the test SR/PC
-- immediately before the instruction under test.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_odd_irq_regwrite is
end entity;

architecture behavior of tb_odd_irq_regwrite is
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
    signal IPL_sig    : std_logic_vector(2 downto 0) := "111";

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
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
            IPL => IPL_sig,
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
               when to_integer(unsigned(addr_out(15 downto 1))) <= 16383 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 16383 then
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
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable saw_irq_vector  : boolean;
        variable saw_addr_error  : boolean;

        impure function mem_read_long(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2) & mem(byte_addr / 2 + 1);
        end function;

        procedure init_common(
            init_d4 : std_logic_vector(31 downto 0);
            opcode  : std_logic_vector(15 downto 0);
            test_sr : std_logic_vector(15 downto 0)
        ) is
        begin
            for i in 0 to 16383 loop
                mem(i) := x"4E71";
            end loop;

            mem(0) := x"0000";
            mem(1) := x"0800";
            mem(2) := x"0000";
            mem(3) := x"1000";

            mem(16#000C# / 2) := x"0000";
            mem(16#000E# / 2) := x"3000";
            mem(16#0064# / 2) := x"0000";
            mem(16#0066# / 2) := x"0123";

            mem(16#3000# / 2) := x"23C4";
            mem(16#3002# / 2) := x"0000";
            mem(16#3004# / 2) := x"7000";
            mem(16#3006# / 2) := x"4E72";
            mem(16#3008# / 2) := x"2700";

            mem(16#1000# / 2) := x"283C";
            mem(16#1002# / 2) := init_d4(31 downto 16);
            mem(16#1004# / 2) := init_d4(15 downto 0);
            mem(16#1006# / 2) := x"2E7C";
            mem(16#1008# / 2) := x"0000";
            mem(16#100A# / 2) := x"07F8";
            mem(16#100C# / 2) := x"4E73";

            mem(16#07F8# / 2) := test_sr;
            mem(16#07FA# / 2) := x"0000";
            mem(16#07FC# / 2) := x"2000";
            mem(16#07FE# / 2) := x"0000";

            mem(16#2000# / 2) := opcode;
            mem(16#2002# / 2) := x"6000";

            mem(16#7000# / 2) := x"0000";
            mem(16#7002# / 2) := x"0000";
            IPL_sig <= "110";
        end procedure;

        procedure do_reset is
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';
        end procedure;

        procedure wait_for_stop_and_monitor(max_cycles : integer := 12000) is
            variable started    : boolean := false;
            variable idle_count : integer := 0;
        begin
            saw_irq_vector := false;
            saw_addr_error := false;

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);

                if addr_out(15 downto 0) = x"0064" then
                    saw_irq_vector := true;
                elsif addr_out(15 downto 0) = x"000C" then
                    saw_addr_error := true;
                end if;

                if busstate /= "01" then
                    started := true;
                    idle_count := 0;
                elsif started then
                    idle_count := idle_count + 1;
                    if idle_count >= 10 then
                        IPL_sig <= "111";
                        return;
                    end if;
                end if;
            end loop;

            IPL_sig <= "111";
            report "FAIL: timeout waiting for ODD_IRQ stop" severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure check_case(
            test_name : string;
            expected  : std_logic_vector(31 downto 0)
        ) is
            variable actual : std_logic_vector(31 downto 0);
        begin
            if saw_irq_vector then
                report "PASS: " & test_name & " saw level-1 autovector fetch" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " missed level-1 autovector fetch" severity error;
                fail_count := fail_count + 1;
            end if;

            if saw_addr_error then
                report "PASS: " & test_name & " saw odd-vector address error" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " missed odd-vector address error" severity error;
                fail_count := fail_count + 1;
            end if;

            actual := mem_read_long(16#7000#);
            if actual = expected then
                report "PASS: " & test_name & " retired D4 before IRQ" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " D4 was not retired before IRQ" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

    begin
        report "=== MC68030 ODD_IRQ Register-Write Coverage ===" severity note;

        report "=== Test 1: EXT.W D4 ===" severity note;
        init_common(x"00000080", x"4884", x"0000");
        do_reset;
        wait_for_stop_and_monitor;
        check_case("EXT.W", x"0000FF80");

        report "=== Test 2: EXT.L D4 ===" severity note;
        init_common(x"00008000", x"48C4", x"0000");
        do_reset;
        wait_for_stop_and_monitor;
        check_case("EXT.L", x"FFFF8000");

        report "=== Test 3: EXTB.L D4 ===" severity note;
        init_common(x"00000080", x"49C4", x"0000");
        do_reset;
        wait_for_stop_and_monitor;
        check_case("EXTB.L", x"FFFFFF80");

        report "=== Test 4: SWAP D4 ===" severity note;
        init_common(x"12345678", x"4844", x"0000");
        do_reset;
        wait_for_stop_and_monitor;
        check_case("SWAP", x"56781234");

        report "ODD_IRQ reg-write tests: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;
        if fail_count = 0 then
            report "OVERALL: ALL TESTS PASSED" severity note;
        else
            report "OVERALL: SOME TESTS FAILED" severity error;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
