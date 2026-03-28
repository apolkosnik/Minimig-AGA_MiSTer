-- tb_t0_trace.vhd
-- MC68030 T0 (trace on change of flow) regression bench.
-- Covers settled T0 behavior:
--   - real control-flow changes trace
--   - instruction traps trace when they actually trap
--   - non-trapping DIV instructions do not trace
--   - DBcc traces only when the branch is actually taken

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_t0_trace is
end entity;

architecture behavior of tb_t0_trace is
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
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable trace_fired : boolean;
        variable trap_seen   : boolean;
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
            mem(16#0024#/2) := x"0000";
            mem(16#0026#/2) := x"3000";
        end procedure;

        procedure setup_trace_handler is
        begin
            mem(16#3000#/2) := x"33FC";
            mem(16#3002#/2) := x"DEAD";
            mem(16#3004#/2) := x"0000";
            mem(16#3006#/2) := x"7000";
            mem(16#3008#/2) := x"4E73";
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

        procedure run_test_with_trap(
            constant max_cycles : in integer;
            variable saw_trace  : out boolean;
            variable saw_trap   : out boolean;
            variable saw_result : out boolean;
            variable result_word : out std_logic_vector(15 downto 0)
        ) is
            variable v_saw_trace  : boolean := false;
            variable v_saw_trap   : boolean := false;
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
                    elsif addr_out(15 downto 0) = x"7200" then
                        v_saw_trap := true;
                    elsif addr_out(15 downto 0) = x"5000" then
                        v_saw_result := true;
                        v_result_word := data_write;
                    end if;
                end if;

                if v_saw_result then
                    for j in 0 to 50 loop
                        wait until rising_edge(clk);
                        if busstate = "11" and nWr = '0' then
                            if addr_out(15 downto 0) = x"7000" then
                                v_saw_trace := true;
                            elsif addr_out(15 downto 0) = x"7200" then
                                v_saw_trap := true;
                            end if;
                        end if;
                    end loop;
                    exit;
                end if;
            end loop;

            saw_trace := v_saw_trace;
            saw_trap := v_saw_trap;
            saw_result := v_saw_result;
            result_word := v_result_word;
        end procedure;

    begin
        report "=== MC68030 T0 Trace Regression ===" severity note;

        report "=== Test 1: T0 + BRA -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"6004";
        mem(16#100C#/2) := x"33FC";
        mem(16#100E#/2) := x"1234";
        mem(16#1010#/2) := x"0000";
        mem(16#1012#/2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired then
            report "PASS: Test 1 - trace fired on BRA with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 1 - trace did not fire on BRA with T0=1" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 2: T0 + MOVE.L -> expect NO trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"203C";
        mem(16#1008#/2) := x"1234";
        mem(16#100A#/2) := x"5678";
        mem(16#100C#/2) := x"33C0";
        mem(16#100E#/2) := x"0000";
        mem(16#1010#/2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if not trace_fired then
            report "PASS: Test 2 - no trace on MOVE.L with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 2 - spurious trace on MOVE.L with T0=1" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 3: T0 + JSR -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"4EB9";
        mem(16#1008#/2) := x"0000";
        mem(16#100A#/2) := x"2000";
        mem(16#2000#/2) := x"33FC";
        mem(16#2002#/2) := x"5678";
        mem(16#2004#/2) := x"0000";
        mem(16#2006#/2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired then
            report "PASS: Test 3 - trace fired on JSR with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 3 - trace did not fire on JSR with T0=1" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 4: T0 + MOVE to SR -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"46FC";
        mem(16#1008#/2) := x"6000";
        mem(16#100A#/2) := x"33FC";
        mem(16#100C#/2) := x"AAAA";
        mem(16#100E#/2) := x"0000";
        mem(16#1010#/2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if trace_fired then
            report "PASS: Test 4 - trace fired on MOVE to SR with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 4 - trace did not fire on MOVE to SR with T0=1" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 5: T0 + DIVU -> expect NO trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"203C";
        mem(16#1008#/2) := x"0000";
        mem(16#100A#/2) := x"0064";
        mem(16#100C#/2) := x"80FC";
        mem(16#100E#/2) := x"000A";
        mem(16#1010#/2) := x"33C0";
        mem(16#1012#/2) := x"0000";
        mem(16#1014#/2) := x"5000";
        run_test(10000, trace_fired, result_seen, result_val);
        if (not trace_fired) and result_seen and result_val = x"000A" then
            report "PASS: Test 5 - no trace on DIVU.W with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 5 - DIVU.W trace/result mismatch" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 6: T0 + DBRA taken -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"7001";
        mem(16#1008#/2) := x"51C8";
        mem(16#100A#/2) := x"0008";
        mem(16#100C#/2) := x"33FC";
        mem(16#100E#/2) := x"13F0";
        mem(16#1010#/2) := x"0000";
        mem(16#1012#/2) := x"5000";
        mem(16#1014#/2) := x"33FC";
        mem(16#1016#/2) := x"1313";
        mem(16#1018#/2) := x"0000";
        mem(16#101A#/2) := x"5000";
        run_test(12000, trace_fired, result_seen, result_val);
        if trace_fired and result_seen and result_val = x"1313" then
            report "PASS: Test 6 - trace fired on taken DBRA" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 6 - taken DBRA trace/result mismatch (trace=" &
                   boolean'image(trace_fired) & ", result_seen=" &
                   boolean'image(result_seen) & ", result=$" &
                   integer'image(to_integer(unsigned(result_val))) & ")" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 7: T0 + DBRA expired -> expect NO trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"7000";
        mem(16#1008#/2) := x"51C8";
        mem(16#100A#/2) := x"0004";
        mem(16#100C#/2) := x"33FC";
        mem(16#100E#/2) := x"1414";
        mem(16#1010#/2) := x"0000";
        mem(16#1012#/2) := x"5000";
        run_test(12000, trace_fired, result_seen, result_val);
        if (not trace_fired) and result_seen and result_val = x"1414" then
            report "PASS: Test 7 - no trace on expired DBRA" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 7 - expired DBRA trace/result mismatch (trace=" &
                   boolean'image(trace_fired) & ", result_seen=" &
                   boolean'image(result_seen) & ", result=$" &
                   integer'image(to_integer(unsigned(result_val))) & ")" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 8: T0 + DIVU.L -> expect NO trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"203C";
        mem(16#1008#/2) := x"0000";
        mem(16#100A#/2) := x"0064";
        mem(16#100C#/2) := x"243C";
        mem(16#100E#/2) := x"0000";
        mem(16#1010#/2) := x"000A";
        mem(16#1012#/2) := x"4C42";
        mem(16#1014#/2) := x"0000";
        mem(16#1016#/2) := x"33FC";
        mem(16#1018#/2) := x"2222";
        mem(16#101A#/2) := x"0000";
        mem(16#101C#/2) := x"5000";
        run_test(15000, trace_fired, result_seen, result_val);
        if (not trace_fired) and result_seen and result_val = x"2222" then
            report "PASS: Test 8 - no trace on DIVU.L with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 8 - DIVU.L trace/result mismatch" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 9: T0 + DIVS.L -> expect NO trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"203C";
        mem(16#1008#/2) := x"0000";
        mem(16#100A#/2) := x"0064";
        mem(16#100C#/2) := x"243C";
        mem(16#100E#/2) := x"0000";
        mem(16#1010#/2) := x"000A";
        mem(16#1012#/2) := x"4C42";
        mem(16#1014#/2) := x"0800";
        mem(16#1016#/2) := x"33FC";
        mem(16#1018#/2) := x"2323";
        mem(16#101A#/2) := x"0000";
        mem(16#101C#/2) := x"5000";
        run_test(15000, trace_fired, result_seen, result_val);
        if (not trace_fired) and result_seen and result_val = x"2323" then
            report "PASS: Test 9 - no trace on DIVS.L with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 9 - DIVS.L trace/result mismatch" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 10: T0 + TRAP #0 -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#0080#/2) := x"0000";
        mem(16#0082#/2) := x"3200";
        mem(16#3200#/2) := x"33FC";
        mem(16#3202#/2) := x"CAFE";
        mem(16#3204#/2) := x"0000";
        mem(16#3206#/2) := x"7200";
        mem(16#3208#/2) := x"4E73";
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"4E40";
        mem(16#1008#/2) := x"33FC";
        mem(16#100A#/2) := x"BBBB";
        mem(16#100C#/2) := x"0000";
        mem(16#100E#/2) := x"5000";
        run_test_with_trap(15000, trace_fired, trap_seen, result_seen, result_val);
        if trace_fired and trap_seen and result_seen and result_val = x"BBBB" then
            report "PASS: Test 10 - trace fired on TRAP #0 with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 10 - TRAP #0 trace/result mismatch (trace=" &
                   boolean'image(trace_fired) & ", trap_seen=" &
                   boolean'image(trap_seen) & ", result_seen=" &
                   boolean'image(result_seen) & ", result=$" &
                   integer'image(to_integer(unsigned(result_val))) & ")" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 11: T0 + TRAPLT taken -> expect trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#001C#/2) := x"0000";
        mem(16#001E#/2) := x"3200";
        mem(16#3200#/2) := x"33FC";
        mem(16#3202#/2) := x"21A1";
        mem(16#3204#/2) := x"0000";
        mem(16#3206#/2) := x"7200";
        mem(16#3208#/2) := x"4E73";
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"70FF";
        mem(16#1008#/2) := x"5DFA";
        mem(16#100A#/2) := x"0000";
        mem(16#100C#/2) := x"33FC";
        mem(16#100E#/2) := x"2121";
        mem(16#1010#/2) := x"0000";
        mem(16#1012#/2) := x"5000";
        run_test_with_trap(15000, trace_fired, trap_seen, result_seen, result_val);
        if trace_fired and trap_seen and result_seen and result_val = x"2121" then
            report "PASS: Test 11 - trace fired on taken TRAPcc with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 11 - taken TRAPcc trace/result mismatch (trace=" &
                   boolean'image(trace_fired) & ", trap_seen=" &
                   boolean'image(trap_seen) & ", result_seen=" &
                   boolean'image(result_seen) & ", result=$" &
                   integer'image(to_integer(unsigned(result_val))) & ")" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== Test 12: T0 + TRAPLT not-taken -> expect NO trace ===" severity note;
        init_common;
        setup_trace_handler;
        mem(16#001C#/2) := x"0000";
        mem(16#001E#/2) := x"3200";
        mem(16#3200#/2) := x"33FC";
        mem(16#3202#/2) := x"21A1";
        mem(16#3204#/2) := x"0000";
        mem(16#3206#/2) := x"7200";
        mem(16#3208#/2) := x"4E73";
        mem(16#1000#/2) := x"46FC";
        mem(16#1002#/2) := x"6000";
        mem(16#1004#/2) := x"4E71";
        mem(16#1006#/2) := x"7001";
        mem(16#1008#/2) := x"5DFA";
        mem(16#100A#/2) := x"0000";
        mem(16#100C#/2) := x"33FC";
        mem(16#100E#/2) := x"2424";
        mem(16#1010#/2) := x"0000";
        mem(16#1012#/2) := x"5000";
        run_test_with_trap(15000, trace_fired, trap_seen, result_seen, result_val);
        if (not trace_fired) and (not trap_seen) and result_seen and result_val = x"2424" then
            report "PASS: Test 12 - no trace on not-taken TRAPcc with T0=1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 12 - not-taken TRAPcc trace/result mismatch (trace=" &
                   boolean'image(trace_fired) & ", trap_seen=" &
                   boolean'image(trap_seen) & ", result_seen=" &
                   boolean'image(result_seen) & ", result=$" &
                   integer'image(to_integer(unsigned(result_val))) & ")" severity error;
            fail_count := fail_count + 1;
        end if;

        if fail_count = 0 then
            report "OVERALL: ALL TESTS PASSED" severity note;
        else
            report "OVERALL: SOME TESTS FAILED" severity error;
        end if;
        report "SUMMARY: passed=" & integer'image(pass_count) &
               " failed=" & integer'image(fail_count) severity note;

        test_done <= true;
        wait;
    end process;
end architecture;
