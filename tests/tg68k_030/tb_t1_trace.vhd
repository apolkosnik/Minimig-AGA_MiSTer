-- tb_t1_trace.vhd
-- MC68030 T1 (trace on every instruction) regression bench.
-- Covers settled T1 behavior with only legal trace-mode combinations.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_t1_trace is
end entity;

architecture behavior of tb_t1_trace is
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
        variable pass_count  : integer := 0;
        variable fail_count  : integer := 0;
        variable trace_fired : boolean;
        variable result_seen : boolean;
        variable result_val  : std_logic_vector(15 downto 0);

        procedure init_common is
        begin
            for i in 0 to 16383 loop
                mem(i) := x"4E71";
            end loop;
            mem(0) := x"0000";
            mem(1) := x"0800";
            mem(2) := x"0000";
            mem(3) := x"1000";
            mem(16#0024# / 2) := x"0000";
            mem(16#0026# / 2) := x"3000";
        end procedure;

        procedure setup_trace_handler is
        begin
            mem(16#3000# / 2) := x"33FC";
            mem(16#3002# / 2) := x"DEAD";
            mem(16#3004# / 2) := x"0000";
            mem(16#3006# / 2) := x"7000";
            mem(16#3008# / 2) := x"4E73";
        end procedure;

        procedure setup_counting_trace_handler is
        begin
            mem(16#3000# / 2) := x"5279";
            mem(16#3002# / 2) := x"0000";
            mem(16#3004# / 2) := x"7100";
            mem(16#3006# / 2) := x"33FC";
            mem(16#3008# / 2) := x"DEAD";
            mem(16#300A# / 2) := x"0000";
            mem(16#300C# / 2) := x"7000";
            mem(16#300E# / 2) := x"4E73";
        end procedure;

        procedure setup_stop_handler is
        begin
            mem(16#3000# / 2) := x"4E72";
            mem(16#3002# / 2) := x"2700";
        end procedure;

        procedure run_test(
            constant max_cycles : in integer;
            variable saw_trace  : out boolean;
            variable saw_result : out boolean;
            variable result_word : out std_logic_vector(15 downto 0)
        ) is
            variable v_saw_trace  : boolean := false;
            variable v_saw_result : boolean := false;
            variable v_result_word : std_logic_vector(15 downto 0) := (others => '0');
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);
                if busstate = "11" and nWr = '0' then
                    if addr_out(15 downto 0) = x"7000" then
                        v_saw_trace := true;
                    elsif addr_out(15 downto 0) = x"5000" then
                        v_saw_result := true;
                        v_result_word := data_write;
                    end if;
                end if;

                if v_saw_result then
                    for j in 0 to 50 loop
                        wait until rising_edge(clk);
                        if busstate = "11" and nWr = '0' and addr_out(15 downto 0) = x"7000" then
                            v_saw_trace := true;
                        end if;
                    end loop;
                    exit;
                end if;
            end loop;

            saw_trace := v_saw_trace;
            saw_result := v_saw_result;
            result_word := v_result_word;
        end procedure;

        procedure run_cycles(max_cycles : integer) is
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';
            for i in 0 to max_cycles loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        impure function mem_read(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2);
        end function;

    begin
        report "=== MC68030 T1 Trace Regression ===" severity note;

        report "=== Test 1: T1 + NOP -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"4E71";
        mem(16#1006# / 2) := x"33FC";
        mem(16#1008# / 2) := x"1111";
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired then
            report "PASS: Test 1 - T1=1 traces NOP" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 1 - T1=1 did NOT trace NOP" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 2: T1=0 T0=0 + NOP -> expect NO trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"2000";
        mem(16#1004# / 2) := x"4E71";
        mem(16#1006# / 2) := x"33FC";
        mem(16#1008# / 2) := x"2222";
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if not trace_fired then
            report "PASS: Test 2 - no trace with T1=0, T0=0" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 2 - spurious trace with T1=0, T0=0" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 3: T1 + MOVE.L -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"203C";
        mem(16#1006# / 2) := x"1234";
        mem(16#1008# / 2) := x"5678";
        mem(16#100A# / 2) := x"33C0";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired then
            report "PASS: Test 3 - T1=1 traces MOVE.L" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 3 - T1=1 did NOT trace MOVE.L" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 4: T1 + BRA -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"6004";
        mem(16#100A# / 2) := x"33FC";
        mem(16#100C# / 2) := x"3333";
        mem(16#100E# / 2) := x"0000";
        mem(16#1010# / 2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired then
            report "PASS: Test 4 - T1=1 traces BRA" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 4 - T1=1 did NOT trace BRA" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 5: T1 + MOVEQ -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"722A";
        mem(16#1006# / 2) := x"33C1";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"5000";
        mem(16#100C# / 2) := x"4E72";
        mem(16#100E# / 2) := x"2700";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired then
            report "PASS: Test 5 - T1=1 traces MOVEQ" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 5 - T1=1 did NOT trace MOVEQ" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 6: T1 exception entry clears T1 in handler ===" severity note;
        init_common;
        setup_counting_trace_handler;
        mem(16#7100# / 2) := x"0000";
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"4E71";
        mem(16#1006# / 2) := x"46FC";
        mem(16#1008# / 2) := x"2000";
        mem(16#100A# / 2) := x"4E71";
        mem(16#100C# / 2) := x"33FC";
        mem(16#100E# / 2) := x"6666";
        mem(16#1010# / 2) := x"0000";
        mem(16#1012# / 2) := x"5000";
        mem(16#1014# / 2) := x"4E72";
        mem(16#1016# / 2) := x"2700";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired and result_seen then
            report "PASS: Test 6 - T1 exception entry clears T1, execution completed" severity note;
            pass_count := pass_count + 1;
        else
            if not trace_fired then
                report "FAIL: Test 6 - trace did not fire" severity error;
            end if;
            if not result_seen then
                report "FAIL: Test 6 - CPU stuck in trace loop" severity error;
            end if;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 7: Format $2 stack frame verification ===" severity note;
        init_common;
        setup_stop_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"4E71";
        mem(16#1006# / 2) := x"4E71";
        run_cycles(10000);
        if mem_read(16#07F4#) = x"A000" and
           mem_read(16#07F6#) = x"0000" and
           mem_read(16#07F8#) = x"1006" and
           mem_read(16#07FA#) = x"2024" and
           mem_read(16#07FC#) = x"0000" and
           mem_read(16#07FE#) = x"1004" then
            report "PASS: Test 7 - Format $2 frame fields are correct" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 7 - trace Format $2 frame contents mismatch" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 8: JMP trace frame verification ===" severity note;
        init_common;
        mem(16#3000# / 2) := x"5379";
        mem(16#3002# / 2) := x"0000";
        mem(16#3004# / 2) := x"6000";
        mem(16#3006# / 2) := x"4A79";
        mem(16#3008# / 2) := x"0000";
        mem(16#300A# / 2) := x"6000";
        mem(16#300C# / 2) := x"6704";
        mem(16#300E# / 2) := x"4E73";
        mem(16#3010# / 2) := x"4E71";
        mem(16#3012# / 2) := x"4E72";
        mem(16#3014# / 2) := x"2700";
        mem(16#6000# / 2) := x"0002";
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"4E71";
        mem(16#1006# / 2) := x"4EF9";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"2000";
        mem(16#2000# / 2) := x"4E71";
        run_cycles(20000);
        if mem_read(16#07F4#) = x"A000" and
           mem_read(16#07F6#) = x"0000" and
           mem_read(16#07F8#) = x"2000" and
           mem_read(16#07FA#) = x"2024" and
           mem_read(16#07FC#) = x"0000" and
           mem_read(16#07FE#) = x"1006" then
            report "PASS: Test 8 - JMP trace frame fields are correct" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 8 - JMP trace frame contents mismatch" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 9: CCR flags preserved in trace frame ===" severity note;
        init_common;
        setup_stop_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A018";
        mem(16#1004# / 2) := x"4E71";
        mem(16#1006# / 2) := x"4E71";
        run_cycles(10000);
        if mem_read(16#07F4#) = x"A018" then
            report "PASS: Test 9 - Stacked SR preserves legal CCR flags" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 9 - Stacked SR lost legal CCR flags" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 10: N flag from MOVE.L preserved in trace frame ===" severity note;
        init_common;
        setup_stop_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A000";
        mem(16#1004# / 2) := x"203C";
        mem(16#1006# / 2) := x"8000";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"4E71";
        mem(16#100C# / 2) := x"4E71";
        run_cycles(10000);
        if mem_read(16#07F4#) = x"A008" then
            report "PASS: Test 10 - Stacked SR preserves N flag from MOVE.L" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 10 - Stacked SR lost N flag from MOVE.L" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 11: reserved SR/CCR bits preserved in trace frame ===" severity note;
        init_common;
        setup_stop_handler;
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A8E0";
        mem(16#1004# / 2) := x"4E71";
        mem(16#1006# / 2) := x"4E71";
        run_cycles(10000);
        if mem_read(16#07F4#) = x"A8E0" then
            report "PASS: Test 11 - Stacked SR preserves unused SR/CCR bits" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 11 - Stacked SR lost unused SR/CCR bits" severity error;
            fail_count := fail_count + 1;
        end if;

        report "============================================" severity note;
        report "T1 Trace Tests: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;
        report "============================================" severity note;
        if fail_count = 0 then
            report "OVERALL: ALL TESTS PASSED" severity note;
        else
            report "OVERALL: SOME TESTS FAILED" severity error;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
