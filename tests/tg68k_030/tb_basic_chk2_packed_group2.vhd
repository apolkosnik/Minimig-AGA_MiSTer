-- tb_basic_chk2_packed_group2.vhd
-- Exact packed-state reproducer for BASIC CHK2.B/CHK2.L /0001 record=0
-- group=2 subcase=0. These use the shared packed base state with opcode
-- patches 00D0/0800 and 04D0/0800 and expect CHK vector 6 with a stacked
-- Group 2 trace frame because T0 is active.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_basic_chk2_packed_group2 is
end entity;

architecture behavior of tb_basic_chk2_packed_group2 is
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
    constant HIGH_BYTES   : integer := 16#00060000#;
    constant BOOT_PC      : integer := 16#42001000#;
    constant TRACE_VEC    : integer := 16#00003000#;
    constant CHK_VEC      : integer := 16#00003200#;
    constant RESULT_ADDR  : integer := 16#00006000#;
    constant ISP_VALUE    : integer := 16#420007C0#;
    constant MSP_VALUE    : integer := 16#42000840#;
    constant USP_VALUE    : integer := 16#42000400#;
    constant FRAME_START  : integer := ISP_VALUE - 8;
    constant CHK_FRAME    : integer := ISP_VALUE - 12;
    constant TRACE_FRAME  : integer := ISP_VALUE - 24;
    constant RTE_PC       : integer := 16#42050000#;

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

        variable frame_sr    : std_logic_vector(15 downto 0);
        variable frame_pc_hi : std_logic_vector(15 downto 0);
        variable frame_pc_lo : std_logic_vector(15 downto 0);
        variable frame_fv    : std_logic_vector(15 downto 0);
        variable frame_ia_hi : std_logic_vector(15 downto 0);
        variable frame_ia_lo : std_logic_vector(15 downto 0);
        variable frame_pc    : std_logic_vector(31 downto 0);
        variable frame_ia    : std_logic_vector(31 downto 0);

        impure function mem_read(byte_addr : integer) return std_logic_vector is
        begin
            if byte_addr >= LOW_BASE and byte_addr < LOW_BASE + LOW_BYTES then
                return low_mem((byte_addr - LOW_BASE) / 2);
            elsif byte_addr >= HIGH_BASE and byte_addr < HIGH_BASE + HIGH_BYTES then
                return high_mem((byte_addr - HIGH_BASE) / 2);
            end if;
            return x"4E71";
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

        procedure init_case(opcode_word : std_logic_vector(15 downto 0)) is
            variable idx : integer;
        begin
            for i in low_mem'range loop
                low_mem(i) := x"4E71";
            end loop;
            for i in high_mem'range loop
                high_mem(i) := x"4E71";
            end loop;

            low_mem(0) := x"4200";
            low_mem(1) := x"0840";
            low_mem(2) := x"4200";
            low_mem(3) := x"1000";

            low_mem(16#0018# / 2) := x"0000";
            low_mem(16#001A# / 2) := std_logic_vector(to_unsigned(CHK_VEC, 16));
            low_mem(16#0024# / 2) := x"0000";
            low_mem(16#0026# / 2) := std_logic_vector(to_unsigned(TRACE_VEC, 16));

            low_mem(RESULT_ADDR / 2) := x"0000";
            low_mem(RESULT_ADDR / 2 + 1) := x"0000";

            write_result_handler(TRACE_VEC, MARK_TRACE);
            write_result_handler(CHK_VEC, MARK_CHK);

            idx := (BOOT_PC - HIGH_BASE) / 2;

            high_mem(idx) := x"2E3C";
            high_mem(idx + 1) := std_logic_vector(to_unsigned(USP_VALUE / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(USP_VALUE mod 16#10000#, 16));
            high_mem(idx + 3) := x"4E7B";
            high_mem(idx + 4) := x"7800";
            idx := idx + 5;

            high_mem(idx) := x"2E3C";
            high_mem(idx + 1) := std_logic_vector(to_unsigned(MSP_VALUE / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(MSP_VALUE mod 16#10000#, 16));
            high_mem(idx + 3) := x"4E7B";
            high_mem(idx + 4) := x"7803";
            idx := idx + 5;

            high_mem(idx) := x"203C";
            high_mem(idx + 1) := x"0000";
            high_mem(idx + 2) := x"0010";
            idx := idx + 3;

            high_mem(idx) := x"243C";
            high_mem(idx + 1) := x"FFFF";
            high_mem(idx + 2) := x"FFFF";
            idx := idx + 3;

            high_mem(idx) := x"263C";
            high_mem(idx + 1) := x"FFFF";
            high_mem(idx + 2) := x"FF00";
            idx := idx + 3;

            high_mem(idx) := x"2C3C";
            high_mem(idx + 1) := x"0001";
            high_mem(idx + 2) := x"0101";
            idx := idx + 3;

            high_mem(idx) := x"2E3C";
            high_mem(idx + 1) := x"AAAA";
            high_mem(idx + 2) := x"AAAA";
            idx := idx + 3;

            high_mem(idx) := x"227C";
            high_mem(idx + 1) := x"0000";
            high_mem(idx + 2) := x"0078";
            idx := idx + 3;

            high_mem(idx) := x"267C";
            high_mem(idx + 1) := x"0000";
            high_mem(idx + 2) := x"7FFF";
            idx := idx + 3;

            high_mem(idx) := x"287C";
            high_mem(idx + 1) := x"FFFF";
            high_mem(idx + 2) := x"FFFE";
            idx := idx + 3;

            high_mem(idx) := x"2E7C";
            high_mem(idx + 1) := std_logic_vector(to_unsigned(FRAME_START / 16#10000#, 16));
            high_mem(idx + 2) := std_logic_vector(to_unsigned(FRAME_START mod 16#10000#, 16));
            high_mem(idx + 3) := x"4E73";

            high_mem((FRAME_START - HIGH_BASE) / 2) := x"4000";
            high_mem((FRAME_START - HIGH_BASE) / 2 + 1) := std_logic_vector(to_unsigned(RTE_PC / 16#10000#, 16));
            high_mem((FRAME_START - HIGH_BASE) / 2 + 2) := std_logic_vector(to_unsigned(RTE_PC mod 16#10000#, 16));
            high_mem((FRAME_START - HIGH_BASE) / 2 + 3) := x"0000";

            idx := (RTE_PC - HIGH_BASE) / 2;
            high_mem(idx) := opcode_word;
            high_mem(idx + 1) := x"0800";
            high_mem(idx + 2) := x"33FC";
            high_mem(idx + 3) := MARK_FALLTHROUGH;
            high_mem(idx + 4) := x"0000";
            high_mem(idx + 5) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
            high_mem(idx + 6) := x"60FE";
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

        procedure check_case(case_name   : string;
                             opcode_word : std_logic_vector(15 downto 0)) is
        begin
            init_case(opcode_word);
            run_case;

            if mem_read(RESULT_ADDR) = MARK_TRACE then
                report "PASS: " & case_name & " reached stacked trace handler" severity note;
                pass_count := pass_count + 1;
            elsif mem_read(RESULT_ADDR) = MARK_CHK then
                report "FAIL: " & case_name & " stopped in CHK handler without stacked trace" severity error;
                fail_count := fail_count + 1;
                return;
            else
                report "FAIL: " & case_name & " produced no recognized result marker" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            load_frame(TRACE_FRAME);
            if frame_fv = x"2024" then
                report "PASS: " & case_name & " trace format/vector" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " trace format/vector mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
            if frame_pc = x"00003200" then
                report "PASS: " & case_name & " trace stacked PC" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " trace stacked PC mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
            if frame_ia = x"00003200" then
                report "PASS: " & case_name & " trace instruction address" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " trace instruction address mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            load_frame(CHK_FRAME);
            if frame_fv = x"2018" then
                report "PASS: " & case_name & " CHK format/vector" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " CHK format/vector mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
            if frame_pc = x"42050004" then
                report "PASS: " & case_name & " CHK stacked PC" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " CHK stacked PC mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
            if frame_ia = x"42050000" then
                report "PASS: " & case_name & " CHK instruction address" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " CHK instruction address mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;
    begin
        report "=== MC68030 BASIC packed CHK2 Group 2 reproducer ===" severity note;

        check_case("packed CHK2.B T0", x"00D0");
        check_case("packed CHK2.L T0", x"04D0");

        report "packed CHK2 Group 2 tests: " & integer'image(pass_count) &
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
