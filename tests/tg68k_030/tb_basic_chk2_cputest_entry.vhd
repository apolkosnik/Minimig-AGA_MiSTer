-- tb_basic_chk2_cputest_entry.vhd
-- Reproduces the packaged WinUAE cputest/basic CHK2 no-trap trace split more
-- closely: both the simple (A0) form and the split-2 PC-indexed form are the
-- first instruction after an RTE frame.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_basic_chk2_cputest_entry is
end entity;

architecture behavior of tb_basic_chk2_cputest_entry is
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
    constant CHK_VEC     : integer := 16#3200#;
    constant BOUNDS_ADDR : integer := 16#3400#;
    constant RESULT_ADDR : integer := 16#6000#;
    constant ISP_VALUE   : integer := 16#0800#;
    constant MSP_VALUE   : integer := 16#0A00#;
    constant USP_VALUE   : integer := 16#0400#;
    constant FRAME_START : integer := 16#07F8#;
    constant RTE_PC      : integer := 16#1200#;

    constant MARK_TRACE  : std_logic_vector(15 downto 0) := x"1111";
    constant MARK_FALLTHROUGH : std_logic_vector(15 downto 0) := x"2222";
    constant MARK_CHK    : std_logic_vector(15 downto 0) := x"3333";

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

        impure function expected_chk2_sr(sr_value : std_logic_vector(15 downto 0))
            return std_logic_vector is
            variable result : std_logic_vector(15 downto 0);
        begin
            -- These maintained CHK2 entry cases all use in-range, non-equal
            -- bounds/value pairs. WinUAE's 68020/030 path clears C/Z first,
            -- recomputes them to 0 here, and leaves only X preserved.
            result := sr_value;
            result(3 downto 0) := "0000";
            return result;
        end function;

        impure function compare_value(opcode_word : std_logic_vector(15 downto 0))
            return std_logic_vector is
        begin
            return x"00000015";
        end function;

        impure function pc_index_ext(opcode_word : std_logic_vector(15 downto 0))
            return std_logic_vector is
        begin
            case opcode_word is
                when x"00FB" =>
                    return x"0800";
                when x"02FB" =>
                    return x"D800";
                when others =>
                    return x"A800";
            end case;
        end function;

        impure function next_pc(opcode_word : std_logic_vector(15 downto 0)) return integer is
        begin
            if opcode_word(5 downto 0) = "111011" then
                return RTE_PC + 6;
            else
                return RTE_PC + 4;
            end if;
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

        procedure init_case(sr_value    : std_logic_vector(15 downto 0);
                            opcode_word : std_logic_vector(15 downto 0)) is
            variable d0_value : std_logic_vector(31 downto 0);
        begin
            for i in 0 to 16383 loop
                mem(i) := x"4E71";
            end loop;

            d0_value := compare_value(opcode_word);

            mem(0) := x"0000";
            mem(1) := x"0800";
            mem(2) := x"0000";
            mem(3) := x"1000";

            mem(16#0024# / 2) := x"0000";
            mem(16#0026# / 2) := std_logic_vector(to_unsigned(TRACE_VEC, 16));
            mem(16#0018# / 2) := x"0000";
            mem(16#001A# / 2) := std_logic_vector(to_unsigned(CHK_VEC, 16));

            mem(RESULT_ADDR / 2) := x"0000";
            mem(RESULT_ADDR / 2 + 1) := x"0000";

            write_result_handler(TRACE_VEC, MARK_TRACE);
            write_result_handler(CHK_VEC, MARK_CHK);

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

            mem(16#1014# / 2) := x"2A7C";
            mem(16#1016# / 2) := x"0000";
            mem(16#1018# / 2) := x"001C";

            mem(16#101A# / 2) := x"247C";
            mem(16#101C# / 2) := x"0000";
            mem(16#101E# / 2) := x"001C";

            mem(16#1020# / 2) := x"207C";
            mem(16#1022# / 2) := x"0000";
            mem(16#1024# / 2) := std_logic_vector(to_unsigned(BOUNDS_ADDR, 16));

            mem(16#1026# / 2) := x"203C";
            mem(16#1028# / 2) := d0_value(31 downto 16);
            mem(16#102A# / 2) := d0_value(15 downto 0);

            mem(16#102C# / 2) := x"2E7C";
            mem(16#102E# / 2) := x"0000";
            mem(16#1030# / 2) := std_logic_vector(to_unsigned(FRAME_START, 16));
            mem(16#1032# / 2) := x"4E73";

            mem(FRAME_START / 2) := sr_value;
            mem(FRAME_START / 2 + 1) := x"0000";
            mem(FRAME_START / 2 + 2) := std_logic_vector(to_unsigned(RTE_PC, 16));
            mem(FRAME_START / 2 + 3) := x"0000";

            mem(RTE_PC / 2) := opcode_word;
            mem(RTE_PC / 2 + 1) := x"0800";
            if opcode_word(5 downto 0) = "111011" then
                mem(RTE_PC / 2 + 2) := pc_index_ext(opcode_word);
                mem(RTE_PC / 2 + 3) := x"33FC"; -- MOVE.W #MARK_FALLTHROUGH,$RESULT
                mem(RTE_PC / 2 + 4) := MARK_FALLTHROUGH;
                mem(RTE_PC / 2 + 5) := x"0000";
                mem(RTE_PC / 2 + 6) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
                mem(RTE_PC / 2 + 7) := x"42F9"; -- MOVE CCR,$RESULT+2
                mem(RTE_PC / 2 + 8) := x"0000";
                mem(RTE_PC / 2 + 9) := std_logic_vector(to_unsigned(RESULT_ADDR + 2, 16));
                mem(RTE_PC / 2 + 10) := x"4E72";
                mem(RTE_PC / 2 + 11) := x"2700";
            else
                mem(RTE_PC / 2 + 2) := x"33FC"; -- MOVE.W #MARK_FALLTHROUGH,$RESULT
                mem(RTE_PC / 2 + 3) := MARK_FALLTHROUGH;
                mem(RTE_PC / 2 + 4) := x"0000";
                mem(RTE_PC / 2 + 5) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
                mem(RTE_PC / 2 + 6) := x"42F9"; -- MOVE CCR,$RESULT+2
                mem(RTE_PC / 2 + 7) := x"0000";
                mem(RTE_PC / 2 + 8) := std_logic_vector(to_unsigned(RESULT_ADDR + 2, 16));
                mem(RTE_PC / 2 + 9) := x"4E72";
                mem(RTE_PC / 2 + 10) := x"2700";
            end if;
        end procedure;

        procedure program_bounds(opcode_word : std_logic_vector(15 downto 0)) is
        begin
            case opcode_word is
                when x"00D0" =>
                    mem(BOUNDS_ADDR / 2) := x"1020";
                when x"02D0" =>
                    mem(BOUNDS_ADDR / 2) := x"0010";
                    mem(BOUNDS_ADDR / 2 + 1) := x"0020";
                when x"04D0" =>
                    mem(BOUNDS_ADDR / 2) := x"0000";
                    mem(BOUNDS_ADDR / 2 + 1) := x"0010";
                    mem(BOUNDS_ADDR / 2 + 2) := x"0000";
                    mem(BOUNDS_ADDR / 2 + 3) := x"0020";
                when x"00FB" =>
                    mem(16#1216# / 2) := x"0010";
                    mem(16#1218# / 2) := x"2010";
                    mem(16#121A# / 2) := x"2010";
                    mem(16#121C# / 2) := x"2000";
                when x"02FB" =>
                    mem(16#1220# / 2) := x"0010";
                    mem(16#1222# / 2) := x"0020";
                when others =>
                    mem(16#1220# / 2) := x"0000";
                    mem(16#1222# / 2) := x"0010";
                    mem(16#1224# / 2) := x"0000";
                    mem(16#1226# / 2) := x"0020";
            end case;
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

        procedure check_trace_case(case_name   : string;
                                   sr_value    : std_logic_vector(15 downto 0);
                                   opcode_word : std_logic_vector(15 downto 0)) is
            variable marker : std_logic_vector(15 downto 0);
        begin
            init_case(sr_value, opcode_word);
            program_bounds(opcode_word);
            run_case;

            marker := mem_read(RESULT_ADDR);
            if marker = MARK_TRACE then
                report "PASS: " & case_name & " took trace" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpected result marker while expecting trace"
                    severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            load_frame(frame_addr(sr_value));

            if frame_sr = expected_chk2_sr(sr_value) then
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

            if frame_pc = std_logic_vector(to_unsigned(next_pc(opcode_word), 32)) then
                report "PASS: " & case_name & " stacked PC" severity note;
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

        procedure check_no_trace_case(case_name   : string;
                                      sr_value    : std_logic_vector(15 downto 0);
                                      opcode_word : std_logic_vector(15 downto 0)) is
            variable marker : std_logic_vector(15 downto 0);
        begin
            init_case(sr_value, opcode_word);
            program_bounds(opcode_word);
            run_case;

            marker := mem_read(RESULT_ADDR);
            if marker = MARK_FALLTHROUGH then
                report "PASS: " & case_name & " completed without trace" severity note;
                pass_count := pass_count + 1;
                if mem_read(RESULT_ADDR + 2)(7 downto 0) =
                   expected_chk2_sr(sr_value)(7 downto 0) then
                    report "PASS: " & case_name & " final SR" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " final SR mismatch" severity error;
                    fail_count := fail_count + 1;
                end if;
            elsif marker = MARK_CHK then
                report "FAIL: " & case_name & " took unexpected CHK trap" severity error;
                fail_count := fail_count + 1;
            else
                report "FAIL: " & case_name &
                       " unexpected result marker while expecting fallthrough"
                    severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure run_size(opcode_word : std_logic_vector(15 downto 0);
                           size_name   : string) is
        begin
            report "=== " & size_name & " T1 cases ===" severity note;
            for ccr in 0 to 31 loop
                check_trace_case(size_name & " user T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"8000", ccr), opcode_word);
                check_trace_case(size_name & " user M1 T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"9000", ccr), opcode_word);
                check_trace_case(size_name & " supervisor T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"A000", ccr), opcode_word);
                check_trace_case(size_name & " supervisor M1 T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"B000", ccr), opcode_word);
            end loop;

            report "=== " & size_name & " T0 controls ===" severity note;
            for ccr in 0 to 31 loop
                check_no_trace_case(size_name & " user T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"4000", ccr), opcode_word);
                check_no_trace_case(size_name & " user M1 T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"5000", ccr), opcode_word);
                check_no_trace_case(size_name & " supervisor T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"6000", ccr), opcode_word);
                check_no_trace_case(size_name & " supervisor M1 T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"7000", ccr), opcode_word);
            end loop;
        end procedure;
    begin
        report "=== MC68030 BASIC CHK2 cputest-entry coverage ===" severity note;

        report "=== Split 0001: CHK2 (A0) after RTE ===" severity note;
        run_size(x"00D0", "CHK2.B (A0)");
        run_size(x"02D0", "CHK2.W (A0)");
        run_size(x"04D0", "CHK2.L (A0)");

        report "=== Split 0002: CHK2 PC-index after RTE ===" severity note;
        run_size(x"00FB", "CHK2.B (d8,PC,Xn)");
        run_size(x"02FB", "CHK2.W (d8,PC,Xn)");
        run_size(x"04FB", "CHK2.L (d8,PC,Xn)");

        report "BASIC CHK2 cputest-entry tests: " & integer'image(pass_count) &
               " PASSED, " & integer'image(fail_count) & " FAILED" severity note;
        if fail_count = 0 then
            report "OVERALL: ALL TESTS PASSED" severity note;
        else
            report "OVERALL: SOME TESTS FAILED" severity error;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
