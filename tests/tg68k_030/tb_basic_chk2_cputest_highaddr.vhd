-- tb_basic_chk2_cputest_highaddr.vhd
-- Full-address reproducer for the packaged BASIC CHK2 split-2 family. This
-- keeps the real 0x420xxxxx code and stack addresses from the BASIC header
-- while exercising the PC-indexed CHK2.B/W/L first-post-RTE path.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_basic_chk2_cputest_highaddr is
end entity;

architecture behavior of tb_basic_chk2_cputest_highaddr is
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

    constant CLK_PERIOD   : time := 10 ns;
    constant LOW_BASE     : integer := 16#00000000#;
    constant LOW_BYTES    : integer := 16#00010000#;
    constant HIGH_BASE    : integer := 16#42000000#;
    constant HIGH_BYTES   : integer := 16#00100000#;
    constant TRACE_VEC    : integer := 16#00003000#;
    constant CHK_VEC      : integer := 16#00003200#;
    constant BOUNDS_ADDR  : integer := 16#42003400#;
    constant RESULT_ADDR  : integer := 16#00006000#;
    constant ISP_VALUE    : integer := 16#420007C0#;
    constant MSP_VALUE    : integer := 16#42000840#;
    constant USP_VALUE    : integer := 16#42000400#;
    constant FRAME_START  : integer := ISP_VALUE - 8;
    constant RTE_PC       : integer := 16#42050000#;
    constant CACR_VALUE   : integer := 16#00002111#;

    constant MARK_TRACE       : std_logic_vector(15 downto 0) := x"1111";
    constant MARK_FALLTHROUGH : std_logic_vector(15 downto 0) := x"2222";
    constant MARK_CHK         : std_logic_vector(15 downto 0) := x"3333";

    type mem_array_t is array(natural range <>) of std_logic_vector(15 downto 0);
    shared variable low_mem  : mem_array_t(0 to LOW_BYTES / 2 - 1);
    shared variable high_mem : mem_array_t(0 to HIGH_BYTES / 2 - 1);
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

    data_in <= low_mem(to_integer(unsigned(addr_out(15 downto 1))))
               when addr_out(31 downto 16) = x"0000" else
               high_mem(to_integer(unsigned(addr_out(19 downto 1))))
               when addr_out(31 downto 20) = x"420" else
               x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if addr_out(31 downto 16) = x"0000" then
                    if nUDS = '0' then
                        low_mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        low_mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                elsif addr_out(31 downto 20) = x"420" then
                    if nUDS = '0' then
                        high_mem(to_integer(unsigned(addr_out(19 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        high_mem(to_integer(unsigned(addr_out(19 downto 1))))(7 downto 0) := data_write(7 downto 0);
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
            if byte_addr >= LOW_BASE and byte_addr < LOW_BASE + LOW_BYTES then
                return low_mem((byte_addr - LOW_BASE) / 2);
            elsif byte_addr >= HIGH_BASE and byte_addr < HIGH_BASE + HIGH_BYTES then
                return high_mem((byte_addr - HIGH_BASE) / 2);
            end if;
            return x"4E71";
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
            low_mem(base_addr / 2) := x"33FC";
            low_mem(base_addr / 2 + 1) := marker;
            low_mem(base_addr / 2 + 2) := x"0000";
            low_mem(base_addr / 2 + 3) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
            low_mem(base_addr / 2 + 4) := x"4E72";
            low_mem(base_addr / 2 + 5) := x"2700";
        end procedure;

        procedure init_case(sr_value     : std_logic_vector(15 downto 0);
                            opcode_word  : std_logic_vector(15 downto 0);
                            cache_enable : boolean) is
            variable d0_value : std_logic_vector(31 downto 0);
            variable idx      : integer;
        begin
            for i in low_mem'range loop
                low_mem(i) := x"4E71";
            end loop;
            for i in high_mem'range loop
                high_mem(i) := x"4E71";
            end loop;

            d0_value := compare_value(opcode_word);

            low_mem(0) := x"4200";
            low_mem(1) := x"0800";
            low_mem(2) := x"4200";
            low_mem(3) := x"1000";

            low_mem(16#0024# / 2) := x"0000";
            low_mem(16#0026# / 2) := std_logic_vector(to_unsigned(TRACE_VEC, 16));
            low_mem(16#0018# / 2) := x"0000";
            low_mem(16#001A# / 2) := std_logic_vector(to_unsigned(CHK_VEC, 16));

            low_mem(RESULT_ADDR / 2) := x"0000";
            low_mem(RESULT_ADDR / 2 + 1) := x"0000";

            write_result_handler(TRACE_VEC, MARK_TRACE);
            write_result_handler(CHK_VEC, MARK_CHK);

            idx := (16#42001000# - HIGH_BASE) / 2;
            high_mem(idx) := x"2E3C";
            high_mem(idx + 1) := std_logic_vector(to_unsigned(USP_VALUE / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(USP_VALUE mod 16#10000#, 16));
            high_mem(idx + 3) := x"4E7B";
            high_mem(idx + 4) := x"7800";

            idx := (16#4200100A# - HIGH_BASE) / 2;
            high_mem(idx) := x"2E3C";
            high_mem(idx + 1) := std_logic_vector(to_unsigned(MSP_VALUE / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(MSP_VALUE mod 16#10000#, 16));
            high_mem(idx + 3) := x"4E7B";
            high_mem(idx + 4) := x"7803";

            idx := (16#42001014# - HIGH_BASE) / 2;
            if cache_enable then
                high_mem(idx) := x"2E3C";
                high_mem(idx + 1) := std_logic_vector(to_unsigned(CACR_VALUE / 16#10000#, 16));
                high_mem(idx + 2) := std_logic_vector(to_unsigned(CACR_VALUE mod 16#10000#, 16));
                high_mem(idx + 3) := x"4E7B";
                high_mem(idx + 4) := x"7002";
                idx := idx + 5;
            end if;

            high_mem(idx) := x"2A7C";
            high_mem(idx + 1) := x"0000";
            high_mem(idx + 2) := x"001C";

            idx := (16#4200101A# - HIGH_BASE) / 2;
            high_mem(idx) := x"247C";
            high_mem(idx + 1) := x"0000";
            high_mem(idx + 2) := x"001C";

            idx := (16#42001020# - HIGH_BASE) / 2;
            high_mem(idx) := x"207C";
            high_mem(idx + 1) := std_logic_vector(to_unsigned(BOUNDS_ADDR / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(BOUNDS_ADDR mod 16#10000#, 16));

            idx := (16#42001026# - HIGH_BASE) / 2;
            high_mem(idx) := x"203C";
            high_mem(idx + 1) := d0_value(31 downto 16);
            high_mem(idx + 2) := d0_value(15 downto 0);

            idx := (16#4200102C# - HIGH_BASE) / 2;
            high_mem(idx) := x"2E7C";
            high_mem(idx + 1) := std_logic_vector(to_unsigned(FRAME_START / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(FRAME_START mod 16#10000#, 16));
            high_mem(idx + 3) := x"4E73";

            idx := (FRAME_START - HIGH_BASE) / 2;
            high_mem(idx) := sr_value;
            high_mem(idx + 1) := std_logic_vector(to_unsigned(RTE_PC / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(RTE_PC mod 16#10000#, 16));
            high_mem(idx + 3) := x"0000";

            idx := (RTE_PC - HIGH_BASE) / 2;
            high_mem(idx) := opcode_word;
            high_mem(idx + 1) := x"0800";
            high_mem(idx + 2) := pc_index_ext(opcode_word);
            high_mem(idx + 3) := x"33FC";
            high_mem(idx + 4) := MARK_FALLTHROUGH;
            high_mem(idx + 5) := x"0000";
            high_mem(idx + 6) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
            high_mem(idx + 7) := x"42F9";
            high_mem(idx + 8) := x"0000";
            high_mem(idx + 9) := std_logic_vector(to_unsigned(RESULT_ADDR + 2, 16));
            high_mem(idx + 10) := x"60FE";
        end procedure;

        procedure program_bounds(opcode_word : std_logic_vector(15 downto 0)) is
            variable idx : integer;
        begin
            case opcode_word is
                when x"00FB" =>
                    idx := (RTE_PC + 16#16# - HIGH_BASE) / 2;
                    high_mem(idx) := x"0010";
                    high_mem(idx + 1) := x"2010";
                    high_mem(idx + 2) := x"2010";
                    high_mem(idx + 3) := x"2000";
                when x"02FB" =>
                    idx := (RTE_PC + 16#20# - HIGH_BASE) / 2;
                    high_mem(idx) := x"0010";
                    high_mem(idx + 1) := x"0020";
                when others =>
                    idx := (RTE_PC + 16#20# - HIGH_BASE) / 2;
                    high_mem(idx) := x"0000";
                    high_mem(idx + 1) := x"0010";
                    high_mem(idx + 2) := x"0000";
                    high_mem(idx + 3) := x"0020";
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
            variable marker_seen  : boolean := false;
            variable settle_count : integer := 0;
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);
                if mem_read(RESULT_ADDR) /= x"0000" then
                    if not marker_seen then
                        marker_seen := true;
                        settle_count := 0;
                    else
                        settle_count := settle_count + 1;
                    end if;
                    if settle_count >= 8 then
                        return;
                    end if;
                end if;
            end loop;

            report "FAIL: timeout waiting for result marker" severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure check_trace_case(case_name    : string;
                                   sr_value     : std_logic_vector(15 downto 0);
                                   opcode_word  : std_logic_vector(15 downto 0);
                                   cache_enable : boolean) is
            variable marker : std_logic_vector(15 downto 0);
        begin
            init_case(sr_value, opcode_word, cache_enable);
            program_bounds(opcode_word);
            run_case;

            marker := mem_read(RESULT_ADDR);
            if marker = MARK_TRACE then
                report "PASS: " & case_name & " took trace" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name &
                       " unexpected result marker while expecting trace" severity error;
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

        procedure check_no_trace_case(case_name    : string;
                                      sr_value     : std_logic_vector(15 downto 0);
                                      opcode_word  : std_logic_vector(15 downto 0);
                                      cache_enable : boolean) is
            variable marker : std_logic_vector(15 downto 0);
        begin
            init_case(sr_value, opcode_word, cache_enable);
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
                       " unexpected result marker while expecting fallthrough" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure run_size(opcode_word  : std_logic_vector(15 downto 0);
                           size_name    : string;
                           cache_enable : boolean) is
        begin
            report "=== " & size_name & " T1 cases ===" severity note;
            for ccr in 0 to 31 loop
                check_trace_case(size_name & " user T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"8000", ccr), opcode_word, cache_enable);
                check_trace_case(size_name & " user M1 T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"9000", ccr), opcode_word, cache_enable);
                check_trace_case(size_name & " supervisor T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"A000", ccr), opcode_word, cache_enable);
                check_trace_case(size_name & " supervisor M1 T1 CCR=" & integer'image(ccr),
                                 sr_with_ccr(x"B000", ccr), opcode_word, cache_enable);
            end loop;

            report "=== " & size_name & " T0 controls ===" severity note;
            for ccr in 0 to 31 loop
                check_no_trace_case(size_name & " user T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"4000", ccr), opcode_word, cache_enable);
                check_no_trace_case(size_name & " user M1 T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"5000", ccr), opcode_word, cache_enable);
                check_no_trace_case(size_name & " supervisor T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"6000", ccr), opcode_word, cache_enable);
                check_no_trace_case(size_name & " supervisor M1 T0 CCR=" & integer'image(ccr),
                                    sr_with_ccr(x"7000", ccr), opcode_word, cache_enable);
            end loop;
        end procedure;
    begin
        report "=== MC68030 BASIC CHK2 full-address split-2 coverage ===" severity note;

        run_size(x"00FB", "cache off CHK2.B (d8,PC,Xn)", false);
        run_size(x"02FB", "cache off CHK2.W (d8,PC,Xn)", false);
        run_size(x"04FB", "cache off CHK2.L (d8,PC,Xn)", false);

        run_size(x"00FB", "cache on CHK2.B (d8,PC,Xn)", true);
        run_size(x"02FB", "cache on CHK2.W (d8,PC,Xn)", true);
        run_size(x"04FB", "cache on CHK2.L (d8,PC,Xn)", true);

        report "BASIC CHK2 full-address split-2 tests: " & integer'image(pass_count) &
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
