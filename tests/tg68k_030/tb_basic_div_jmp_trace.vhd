-- tb_basic_div_jmp_trace.vhd
-- Maintained MC68030 BASIC-style divide and JMP trace coverage.
-- Covers successful DIVU.W, DIVS.W, DIVL.L bucket behavior and sweeps the
-- legal BASIC trace SR combinations for JMP with distinct USP/ISP/MSP shadows.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_basic_div_jmp_trace is
end entity;

architecture behavior of tb_basic_div_jmp_trace is
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

        variable frame_sr     : std_logic_vector(15 downto 0);
        variable frame_pc_hi  : std_logic_vector(15 downto 0);
        variable frame_pc_lo  : std_logic_vector(15 downto 0);
        variable frame_fv     : std_logic_vector(15 downto 0);
        variable frame_ia_hi  : std_logic_vector(15 downto 0);
        variable frame_ia_lo  : std_logic_vector(15 downto 0);
        variable frame_pc     : std_logic_vector(31 downto 0);
        variable frame_ia     : std_logic_vector(31 downto 0);

        impure function mem_read(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2);
        end function;

        impure function mem_read_long(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2) & mem(byte_addr / 2 + 1);
        end function;

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

            mem(16#3000# / 2) := x"23C0";
            mem(16#3002# / 2) := x"0000";
            mem(16#3004# / 2) := x"7000";
            mem(16#3006# / 2) := x"4E72";
            mem(16#3008# / 2) := x"2700";

            for i in 16#07F0# / 2 to 16#0800# / 2 - 1 loop
                mem(i) := x"DEAD";
            end loop;
            mem(16#7000# / 2) := x"0000";
            mem(16#7002# / 2) := x"0000";
        end procedure;

        procedure run_case(run_cycles : integer := 2000) is
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to run_cycles loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure load_frame(sp_addr : integer) is
        begin
            frame_sr    := mem_read(sp_addr);
            frame_pc_hi := mem_read(sp_addr + 2);
            frame_pc_lo := mem_read(sp_addr + 4);
            frame_fv    := mem_read(sp_addr + 6);
            frame_ia_hi := mem_read(sp_addr + 8);
            frame_ia_lo := mem_read(sp_addr + 10);
            frame_pc    := frame_pc_hi & frame_pc_lo;
            frame_ia    := frame_ia_hi & frame_ia_lo;
        end procedure;

        procedure check_trace_frame(
            test_name    : string;
            sp_addr      : integer;
            expected_sr  : std_logic_vector(15 downto 0);
            expected_pc  : std_logic_vector(31 downto 0);
            expected_ia  : std_logic_vector(31 downto 0)
        ) is
        begin
            load_frame(sp_addr);

            if frame_sr = expected_sr then
                report "PASS: " & test_name & " saved SR" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " saved SR mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if frame_fv = x"2024" then
                report "PASS: " & test_name & " format/vector" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " format/vector mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if frame_pc = expected_pc then
                report "PASS: " & test_name & " stacked PC" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " stacked PC mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if frame_ia = expected_ia then
                report "PASS: " & test_name & " instruction address" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " instruction address mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_result(test_name : string; expected : std_logic_vector(31 downto 0)) is
            variable actual : std_logic_vector(31 downto 0);
        begin
            actual := mem_read_long(16#7000#);
            if actual = expected then
                report "PASS: " & test_name & " D0 result" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " D0 result mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure program_jmp_case(sr_word : std_logic_vector(15 downto 0)) is
        begin
            mem(16#1000# / 2) := x"223C";
            mem(16#1002# / 2) := x"0000";
            mem(16#1004# / 2) := x"0A00";
            mem(16#1006# / 2) := x"4E7B";
            mem(16#1008# / 2) := x"1803";
            mem(16#100A# / 2) := x"223C";
            mem(16#100C# / 2) := x"0000";
            mem(16#100E# / 2) := x"0C00";
            mem(16#1010# / 2) := x"4E7B";
            mem(16#1012# / 2) := x"1800";
            mem(16#1014# / 2) := x"46FC";
            mem(16#1016# / 2) := sr_word;
            mem(16#1018# / 2) := x"4EF9";
            mem(16#101A# / 2) := x"0000";
            mem(16#101C# / 2) := x"2000";
            mem(16#2000# / 2) := x"4E71";
        end procedure;

    begin
        report "=== MC68030 BASIC DIV/JMP Trace Coverage ===" severity note;

        report "=== Test 1: DIVU.W success with SR=$8000 ===" severity note;
        init_common;
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0064";
        mem(16#1006# / 2) := x"46FC";
        mem(16#1008# / 2) := x"8000";
        mem(16#100A# / 2) := x"80FC";
        mem(16#100C# / 2) := x"000A";
        mem(16#100E# / 2) := x"4E71";
        run_case;
        check_trace_frame("DIVU.W user T1", 16#07F4#, x"8000", x"0000100E", x"0000100A");
        check_result("DIVU.W user T1", x"0000000A");

        report "=== Test 2: DIVS.W success with SR=$8000 ===" severity note;
        init_common;
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0064";
        mem(16#1006# / 2) := x"46FC";
        mem(16#1008# / 2) := x"8000";
        mem(16#100A# / 2) := x"81FC";
        mem(16#100C# / 2) := x"000A";
        mem(16#100E# / 2) := x"4E71";
        run_case;
        check_trace_frame("DIVS.W user T1", 16#07F4#, x"8000", x"0000100E", x"0000100A");
        check_result("DIVS.W user T1", x"0000000A");

        report "=== Test 3: DIVU.L success with SR=$8000 ===" severity note;
        init_common;
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0064";
        mem(16#1006# / 2) := x"243C";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"000A";
        mem(16#100C# / 2) := x"46FC";
        mem(16#100E# / 2) := x"8000";
        mem(16#1010# / 2) := x"4C42";
        mem(16#1012# / 2) := x"0000";
        mem(16#1014# / 2) := x"4E71";
        run_case;
        check_trace_frame("DIVU.L user T1", 16#07F4#, x"8000", x"00001014", x"00001010");
        check_result("DIVU.L user T1", x"0000000A");

        report "=== Test 4: DIVS.L success with SR=$8000 ===" severity note;
        init_common;
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0064";
        mem(16#1006# / 2) := x"243C";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"000A";
        mem(16#100C# / 2) := x"46FC";
        mem(16#100E# / 2) := x"8000";
        mem(16#1010# / 2) := x"4C42";
        mem(16#1012# / 2) := x"0800";
        mem(16#1014# / 2) := x"4E71";
        run_case;
        check_trace_frame("DIVS.L user T1", 16#07F4#, x"8000", x"00001014", x"00001010");
        check_result("DIVS.L user T1", x"0000000A");

        report "=== Test 5: JMP with SR=$8000 ===" severity note;
        init_common;
        program_jmp_case(x"8000");
        run_case;
        check_trace_frame("JMP user T1 M=0", 16#07F4#, x"8000", x"00002000", x"00001018");

        report "=== Test 6: JMP with SR=$4000 ===" severity note;
        init_common;
        program_jmp_case(x"4000");
        run_case;
        check_trace_frame("JMP user T0 M=0", 16#07F4#, x"4000", x"00002000", x"00001018");

        report "=== Test 7: JMP with SR=$9000 ===" severity note;
        init_common;
        program_jmp_case(x"9000");
        run_case;
        check_trace_frame("JMP user T1 M=1", 16#09F4#, x"9000", x"00002000", x"00001018");

        report "=== Test 8: JMP with SR=$5000 ===" severity note;
        init_common;
        program_jmp_case(x"5000");
        run_case;
        check_trace_frame("JMP user T0 M=1", 16#09F4#, x"5000", x"00002000", x"00001018");

        report "=== Test 9: JMP with SR=$A000 ===" severity note;
        init_common;
        program_jmp_case(x"A000");
        run_case;
        check_trace_frame("JMP supervisor T1 M=0", 16#07F4#, x"A000", x"00002000", x"00001018");

        report "=== Test 10: JMP with SR=$6000 ===" severity note;
        init_common;
        program_jmp_case(x"6000");
        run_case;
        check_trace_frame("JMP supervisor T0 M=0", 16#07F4#, x"6000", x"00002000", x"00001018");

        report "=== Test 11: JMP with SR=$B000 ===" severity note;
        init_common;
        program_jmp_case(x"B000");
        run_case;
        check_trace_frame("JMP supervisor T1 M=1", 16#09F4#, x"B000", x"00002000", x"00001018");

        report "=== Test 12: JMP with SR=$7000 ===" severity note;
        init_common;
        program_jmp_case(x"7000");
        run_case;
        check_trace_frame("JMP supervisor T0 M=1", 16#09F4#, x"7000", x"00002000", x"00001018");

        report "BASIC DIV/JMP tests: " & integer'image(pass_count) & " PASSED, " &
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
