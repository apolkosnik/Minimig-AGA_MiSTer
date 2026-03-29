-- tb_basic_group2_user_trace.vhd
-- Maintained MC68030 BASIC-style user-mode stacked trace coverage for
-- TRAP and TRAPcc.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_basic_group2_user_trace is
end entity;

architecture behavior of tb_basic_group2_user_trace is
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
            mem(16#0026# / 2) := x"2100";
            mem(16#2100# / 2) := x"4E72";
            mem(16#2102# / 2) := x"2700";
            mem(16#2200# / 2) := x"4E72";
            mem(16#2202# / 2) := x"2700";
            mem(16#2300# / 2) := x"4E72";
            mem(16#2302# / 2) := x"2700";

            for i in 16#07E0# / 2 to 16#0800# / 2 - 1 loop
                mem(i) := x"DEAD";
            end loop;
        end procedure;

        procedure run_case(max_cycles : integer := 12000) is
            variable started    : boolean := false;
            variable idle_count : integer := 0;
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);
                if busstate /= "01" then
                    started := true;
                    idle_count := 0;
                elsif started then
                    idle_count := idle_count + 1;
                    if idle_count >= 10 then
                        return;
                    end if;
                end if;
            end loop;

            report "FAIL: timeout waiting for STOP" severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure load_frame0(sp_addr : integer) is
        begin
            frame_sr    := mem_read(sp_addr);
            frame_pc_hi := mem_read(sp_addr + 2);
            frame_pc_lo := mem_read(sp_addr + 4);
            frame_fv    := mem_read(sp_addr + 6);
            frame_pc    := frame_pc_hi & frame_pc_lo;
            frame_ia    := (others => '0');
        end procedure;

        procedure load_frame2(sp_addr : integer) is
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

        procedure check_frame0(
            test_name   : string;
            sp_addr     : integer;
            expected_sr : std_logic_vector(15 downto 0);
            expected_fv : std_logic_vector(15 downto 0);
            expected_pc : std_logic_vector(31 downto 0)
        ) is
        begin
            load_frame0(sp_addr);
            if frame_sr = expected_sr then
                report "PASS: " & test_name & " saved SR" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " saved SR mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
            if frame_fv = expected_fv then
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
        end procedure;

        procedure check_frame2(
            test_name   : string;
            sp_addr     : integer;
            expected_sr : std_logic_vector(15 downto 0);
            expected_fv : std_logic_vector(15 downto 0);
            expected_pc : std_logic_vector(31 downto 0);
            expected_ia : std_logic_vector(31 downto 0)
        ) is
        begin
            load_frame2(sp_addr);
            if frame_sr = expected_sr then
                report "PASS: " & test_name & " saved SR" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " saved SR mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
            if frame_fv = expected_fv then
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

        procedure check_frame2_no_sr(
            test_name   : string;
            sp_addr     : integer;
            expected_fv : std_logic_vector(15 downto 0);
            expected_pc : std_logic_vector(31 downto 0);
            expected_ia : std_logic_vector(31 downto 0)
        ) is
        begin
            load_frame2(sp_addr);
            if frame_fv = expected_fv then
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

    begin
        report "=== MC68030 BASIC TRAP/TRAPcc User Trace Coverage ===" severity note;

        report "=== Test 1: TRAP #5 with SR=$8000 ===" severity note;
        init_common;
        mem(16#0094# / 2) := x"0000";
        mem(16#0096# / 2) := x"2200";
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"8000";
        mem(16#1004# / 2) := x"4E45";
        mem(16#1006# / 2) := x"4E71";
        run_case;
        check_frame2_no_sr("TRAP #5 trace", 16#07EC#, x"2024", x"00002200", x"00002200");
        check_frame0("TRAP #5 frame", 16#07F8#, x"8000", x"0094", x"00001006");

        report "=== Test 2: TRAPLT.W with SR=$8008 ===" severity note;
        init_common;
        mem(16#001C# / 2) := x"0000";
        mem(16#001E# / 2) := x"2300";
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"8008";
        mem(16#1004# / 2) := x"5DFA";
        mem(16#1006# / 2) := x"0000";
        mem(16#1008# / 2) := x"4E71";
        run_case;
        check_frame2_no_sr("TRAPcc trace", 16#07E8#, x"2024", x"00002300", x"00002300");
        check_frame2("TRAPcc frame", 16#07F4#, x"8008", x"201C", x"00001008", x"00001004");

        report "BASIC TRAP tests: " & integer'image(pass_count) & " PASSED, " &
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
