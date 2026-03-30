-- tb_basic_jmp_sp_disp_entry.vhd
-- Focused reproducer for the packaged BASIC/JMP split-2 form seen on
-- hardware: the first post-RTE instruction is JMP ($65B2,SP), with distinct
-- USP/ISP/MSP shadows so the active stack selection stays visible.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_basic_jmp_sp_disp_entry is
end entity;

architecture behavior of tb_basic_jmp_sp_disp_entry is
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

    constant CLK_PERIOD  : time := 10 ns;
    constant TRACE_VEC   : integer := 16#3000#;
    constant ILL_VEC     : integer := 16#3100#;
    constant RESULT_ADDR : integer := 16#6000#;
    constant JMP_SP_DISP : integer := 16#65B2#;
    constant ISP_VALUE   : integer := 16#07C0#;
    constant MSP_VALUE   : integer := 16#0840#;
    constant USP_VALUE   : integer := 16#03FE#;
    constant FRAME_START : integer := ISP_VALUE - 8;
    constant RTE_PC      : integer := 16#1200#;

    constant MARK_TRACE   : std_logic_vector(15 downto 0) := x"1111";
    constant MARK_ILLEGAL : std_logic_vector(15 downto 0) := x"3333";

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

        impure function sr_with_ccr(sr_high : std_logic_vector(15 downto 0);
                                    ccr     : integer) return std_logic_vector is
        begin
            return sr_high or std_logic_vector(to_unsigned(ccr, 16));
        end function;

        impure function active_stack_value(sr_value : std_logic_vector(15 downto 0))
            return integer is
        begin
            if sr_value(13) = '0' then
                return USP_VALUE;
            elsif sr_value(12) = '1' then
                return MSP_VALUE;
            else
                return ISP_VALUE;
            end if;
        end function;

        impure function target_addr(sr_value : std_logic_vector(15 downto 0))
            return integer is
        begin
            return active_stack_value(sr_value) + JMP_SP_DISP;
        end function;

        procedure write_result_handler(base_addr : integer;
                                       marker    : std_logic_vector(15 downto 0)) is
        begin
            mem(base_addr / 2) := x"33FC";
            mem(base_addr / 2 + 1) := marker;
            mem(base_addr / 2 + 2) := x"0000";
            mem(base_addr / 2 + 3) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
            mem(base_addr / 2 + 4) := x"4E72";
            mem(base_addr / 2 + 5) := x"2700";
        end procedure;

        procedure write_target_stub(base_addr : integer) is
        begin
            mem(base_addr / 2) := x"2048"; -- MOVEA.L A0,A0
            mem(base_addr / 2 + 1) := x"4AFC"; -- ILLEGAL
        end procedure;

        procedure init_case(sr_value : std_logic_vector(15 downto 0)) is
        begin
            for i in 0 to 16383 loop
                mem(i) := x"4E71";
            end loop;

            mem(0) := x"0000";
            mem(1) := x"0800";
            mem(2) := x"0000";
            mem(3) := x"1000";

            mem(16#0010# / 2) := x"0000";
            mem(16#0012# / 2) := std_logic_vector(to_unsigned(ILL_VEC, 16));
            mem(16#0024# / 2) := x"0000";
            mem(16#0026# / 2) := std_logic_vector(to_unsigned(TRACE_VEC, 16));

            mem(RESULT_ADDR / 2) := x"0000";
            mem(RESULT_ADDR / 2 + 1) := x"0000";

            write_result_handler(TRACE_VEC, MARK_TRACE);
            write_result_handler(ILL_VEC, MARK_ILLEGAL);

            write_target_stub(USP_VALUE + JMP_SP_DISP);
            write_target_stub(ISP_VALUE + JMP_SP_DISP);
            write_target_stub(MSP_VALUE + JMP_SP_DISP);

            mem(16#1000# / 2) := x"2E3C";
            mem(16#1002# / 2) := x"0000";
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(USP_VALUE, 16));
            mem(16#1006# / 2) := x"4E7B";
            mem(16#1008# / 2) := x"7800";

            mem(16#100A# / 2) := x"2E3C";
            mem(16#100C# / 2) := x"0000";
            mem(16#100E# / 2) := std_logic_vector(to_unsigned(MSP_VALUE, 16));
            mem(16#1010# / 2) := x"4E7B";
            mem(16#1012# / 2) := x"7803";

            mem(16#1014# / 2) := x"2E7C";
            mem(16#1016# / 2) := x"0000";
            mem(16#1018# / 2) := std_logic_vector(to_unsigned(FRAME_START, 16));
            mem(16#101A# / 2) := x"4E73";

            mem(FRAME_START / 2) := sr_value;
            mem(FRAME_START / 2 + 1) := x"0000";
            mem(FRAME_START / 2 + 2) := std_logic_vector(to_unsigned(RTE_PC, 16));
            mem(FRAME_START / 2 + 3) := x"0000";

            mem(RTE_PC / 2) := x"4EEF";
            mem(RTE_PC / 2 + 1) := x"65B2";
        end procedure;

        impure function frame_addr(sr_value : std_logic_vector(15 downto 0)) return integer is
        begin
            if sr_value(12) = '1' then
                return MSP_VALUE - 12;
            else
                return ISP_VALUE - 12;
            end if;
        end function;

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

        procedure run_case(max_cycles : integer := 20000) is
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
                    if idle_count >= 12 then
                        return;
                    end if;
                end if;
            end loop;

            report "FAIL: timeout waiting for STOP" severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure check_case(case_name : string;
                             sr_value  : std_logic_vector(15 downto 0)) is
            variable marker          : std_logic_vector(15 downto 0);
            variable expected_target : integer;
        begin
            init_case(sr_value);
            run_case;
            marker := mem_read(RESULT_ADDR);
            expected_target := target_addr(sr_value);

            if marker = MARK_TRACE then
                report "PASS: " & case_name & " took trace" severity note;
                pass_count := pass_count + 1;
            elsif marker = MARK_ILLEGAL then
                report "FAIL: " & case_name & " reached target ILLEGAL before trace" severity error;
                fail_count := fail_count + 1;
                return;
            else
                report "FAIL: " & case_name & " produced no recognized result marker" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            load_frame(frame_addr(sr_value));

            if frame_sr = sr_value then
                report "PASS: " & case_name & " saved SR" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " saved SR mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if frame_fv = x"2024" then
                report "PASS: " & case_name & " format/vector" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " format/vector mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if frame_pc = std_logic_vector(to_unsigned(expected_target, 32)) then
                report "PASS: " & case_name & " stacked PC target" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " stacked PC mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if frame_ia = std_logic_vector(to_unsigned(RTE_PC, 32)) then
                report "PASS: " & case_name & " instruction address" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " instruction address mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure run_variant(prefix : string;
                              sr_high : std_logic_vector(15 downto 0)) is
        begin
            for ccr in 0 to 31 loop
                check_case(prefix & " CCR=" & integer'image(ccr),
                           sr_with_ccr(sr_high, ccr));
            end loop;
        end procedure;
    begin
        report "=== MC68030 BASIC JMP (d16,SP) cputest-entry coverage ===" severity note;

        run_variant("user T1", x"8000");
        run_variant("user T0", x"4000");
        run_variant("user M1 T1", x"9000");
        run_variant("user M1 T0", x"5000");
        run_variant("supervisor T1", x"A000");
        run_variant("supervisor T0", x"6000");
        run_variant("supervisor M1 T1", x"B000");
        run_variant("supervisor M1 T0", x"7000");

        report "BASIC JMP (d16,SP) cputest-entry tests: " &
               integer'image(pass_count) & " PASSED, " &
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
