library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_jmp_65b2_trace_regression is
end entity;

architecture behavior of tb_jmp_65b2_trace_regression is
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
    clk <= not clk after CLK_PERIOD/2 when not test_done;

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

        impure function mem_read(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2);
        end function;

        procedure init_program(trace_sr : std_logic_vector(15 downto 0)) is
            constant frame_addr : integer := 16#07F8#;
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

            mem(16#3000# / 2) := x"4E72";
            mem(16#3002# / 2) := x"2700";

            mem(16#1000# / 2) := x"7C00";  -- MOVEQ #0,D6
            mem(16#1002# / 2) := x"2E7C";  -- MOVEA.L #frame_addr,A7
            mem(16#1004# / 2) := x"0000";
            mem(16#1006# / 2) := x"07F8";
            mem(16#1008# / 2) := x"4E73";  -- RTE

            mem(frame_addr / 2) := trace_sr;
            mem(frame_addr / 2 + 1) := x"0000";
            mem(frame_addr / 2 + 2) := x"1100";
            mem(frame_addr / 2 + 3) := x"0000";

            -- JMP (d8,PC,Xn) full-format ext $65B2, BD.l=$00001E80, OD.w=$0004.
            -- With D6=0, ptr@$1E80=$1FFC, +4 -> $2000.
            mem(16#1100# / 2) := x"4EFB";
            mem(16#1102# / 2) := x"65B2";
            mem(16#1104# / 2) := x"0000";
            mem(16#1106# / 2) := x"1E80";
            mem(16#1108# / 2) := x"0004";

            mem(16#1E80# / 2) := x"0000";
            mem(16#1E82# / 2) := x"1FFC";

            mem(16#2000# / 2) := x"4E71";
            mem(16#2002# / 2) := x"4E72";
            mem(16#2004# / 2) := x"2700";
        end procedure;

        procedure run_case(
            case_name : string;
            trace_sr  : std_logic_vector(15 downto 0)) is
        begin
            init_program(trace_sr);

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';
            for i in 0 to 20000 loop
                wait until rising_edge(clk);
            end loop;

            if mem_read(16#07F4#) = trace_sr then
                report "PASS: " & case_name & " stacked SR" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " stacked SR bad" severity error;
                fail_count := fail_count + 1;
            end if;

            if mem_read(16#07F6#) = x"0000" and mem_read(16#07F8#) = x"2000" then
                report "PASS: " & case_name & " stacked PC target" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " stacked PC bad" severity error;
                fail_count := fail_count + 1;
            end if;

            if mem_read(16#07FA#) = x"2024" then
                report "PASS: " & case_name & " format/vector" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " format/vector bad" severity error;
                fail_count := fail_count + 1;
            end if;

            if mem_read(16#07FC#) = x"0000" and mem_read(16#07FE#) = x"1100" then
                report "PASS: " & case_name & " instruction address" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " instruction address bad" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;
    begin
        report "=== Case 1: T1 trace on JMP 4EFB/65B2 after RTE ===" severity note;
        run_case("T1 JMP", x"A000");

        report "=== Case 2: T0 trace on JMP 4EFB/65B2 after RTE ===" severity note;
        run_case("T0 JMP", x"6000");

        report "JMP 65B2 trace regression: " & integer'image(pass_count) & " PASSED, " &
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
