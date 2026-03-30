library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_jmp_65b2_index_target is
end entity;

architecture behavior of tb_jmp_65b2_index_target is
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

    constant CLK_PERIOD      : time := 10 ns;
    constant LOW_BASE        : integer := 16#00000000#;
    constant LOW_BYTES       : integer := 16#00010000#;
    constant HIGH_BASE       : integer := 16#42000000#;
    constant HIGH_BYTES      : integer := 16#00100000#;
    constant TRACE_VEC       : integer := 16#00003000#;
    constant ILL_VEC         : integer := 16#00003100#;
    constant RESULT_ADDR     : integer := 16#00006000#;
    constant TRACE_PATCH_A   : integer := 16#0000008A#;
    constant TRACE_PATCH_B   : integer := 16#0000008C#;
    constant RTE_PC          : integer := 16#42050000#;
    constant FRAME_START     : integer := 16#420007B8#;
    constant TARGET_ADDR     : integer := 16#42006D8C#;
    constant POINTER_SCALE4  : integer := 16#00003EA0#;
    constant D6_PACKAGED     : integer := 16#00080808#;

    constant MARK_TRACE      : std_logic_vector(15 downto 0) := x"1111";
    constant MARK_ILLEGAL    : std_logic_vector(15 downto 0) := x"3333";

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

        impure function mem_read(byte_addr : integer) return std_logic_vector is
        begin
            if byte_addr >= LOW_BASE and byte_addr < LOW_BASE + LOW_BYTES then
                return low_mem((byte_addr - LOW_BASE) / 2);
            elsif byte_addr >= HIGH_BASE and byte_addr < HIGH_BASE + HIGH_BYTES then
                return high_mem((byte_addr - HIGH_BASE) / 2);
            end if;
            return x"4E71";
        end function;

        procedure write_long(byte_addr : integer;
                             value     : integer) is
        begin
            low_mem(byte_addr / 2) := std_logic_vector(to_unsigned(value / 16#10000#, 16));
            low_mem(byte_addr / 2 + 1) := std_logic_vector(to_unsigned(value mod 16#10000#, 16));
        end procedure;

        procedure init_case is
            variable idx : integer;
        begin
            for i in low_mem'range loop
                low_mem(i) := x"4E71";
            end loop;
            for i in high_mem'range loop
                high_mem(i) := x"4E71";
            end loop;

            low_mem(0) := x"4200";
            low_mem(1) := x"0800";
            low_mem(2) := x"0000";
            low_mem(3) := x"1000";

            low_mem(16#0010# / 2) := x"0000";
            low_mem(16#0012# / 2) := std_logic_vector(to_unsigned(ILL_VEC, 16));
            low_mem(16#0024# / 2) := x"0000";
            low_mem(16#0026# / 2) := std_logic_vector(to_unsigned(TRACE_VEC, 16));

            low_mem(RESULT_ADDR / 2) := x"0000";
            low_mem(RESULT_ADDR / 2 + 1) := x"0000";

            low_mem(TRACE_PATCH_A / 2) := x"00FC";
            low_mem(TRACE_PATCH_B / 2) := x"2048";

            -- Trace handler: mark success and perform the same low-memory writes
            -- that the packaged BASIC/JMP 0002 subrecord expects at $008B/$008C.
            low_mem(TRACE_VEC / 2) := x"33FC";
            low_mem(TRACE_VEC / 2 + 1) := MARK_TRACE;
            low_mem(TRACE_VEC / 2 + 2) := x"0000";
            low_mem(TRACE_VEC / 2 + 3) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
            low_mem(TRACE_VEC / 2 + 4) := x"13FC";
            low_mem(TRACE_VEC / 2 + 5) := x"00FD";
            low_mem(TRACE_VEC / 2 + 6) := x"0000";
            low_mem(TRACE_VEC / 2 + 7) := x"008B";
            low_mem(TRACE_VEC / 2 + 8) := x"33FC";
            low_mem(TRACE_VEC / 2 + 9) := x"EB48";
            low_mem(TRACE_VEC / 2 + 10) := x"0000";
            low_mem(TRACE_VEC / 2 + 11) := x"008C";
            low_mem(TRACE_VEC / 2 + 12) := x"4E72";
            low_mem(TRACE_VEC / 2 + 13) := x"2700";

            low_mem(ILL_VEC / 2) := x"33FC";
            low_mem(ILL_VEC / 2 + 1) := MARK_ILLEGAL;
            low_mem(ILL_VEC / 2 + 2) := x"0000";
            low_mem(ILL_VEC / 2 + 3) := std_logic_vector(to_unsigned(RESULT_ADDR, 16));
            low_mem(ILL_VEC / 2 + 4) := x"4E72";
            low_mem(ILL_VEC / 2 + 5) := x"2700";

            write_long(POINTER_SCALE4, TARGET_ADDR - 4);

            idx := (16#42001000# - HIGH_BASE) / 2;
            high_mem(idx) := x"2C3C"; -- MOVE.L #$00080808,D6
            high_mem(idx + 1) := x"0008";
            high_mem(idx + 2) := x"0808";
            high_mem(idx + 3) := x"2E7C"; -- MOVEA.L #FRAME_START,A7
            high_mem(idx + 4) := std_logic_vector(to_unsigned(FRAME_START / 16#10000#, 16));
            high_mem(idx + 5) := std_logic_vector(to_unsigned(FRAME_START mod 16#10000#, 16));
            high_mem(idx + 6) := x"4E73"; -- RTE

            high_mem((FRAME_START - HIGH_BASE) / 2) := x"6000"; -- supervisor T0
            high_mem((FRAME_START - HIGH_BASE) / 2 + 1) := std_logic_vector(to_unsigned(RTE_PC / 16#10000#, 16));
            high_mem((FRAME_START - HIGH_BASE) / 2 + 2) := std_logic_vector(to_unsigned(RTE_PC mod 16#10000#, 16));
            high_mem((FRAME_START - HIGH_BASE) / 2 + 3) := x"0000";

            high_mem((RTE_PC - HIGH_BASE) / 2) := x"4EFB";
            high_mem((RTE_PC - HIGH_BASE) / 2 + 1) := x"65B2";
            high_mem((RTE_PC - HIGH_BASE) / 2 + 2) := x"0000";
            high_mem((RTE_PC - HIGH_BASE) / 2 + 3) := x"1E80";
            high_mem((RTE_PC - HIGH_BASE) / 2 + 4) := x"0004";

            idx := (TARGET_ADDR - HIGH_BASE) / 2;
            high_mem(idx) := x"2048"; -- MOVEA.L A0,A0
            high_mem(idx + 1) := x"4AFC"; -- ILLEGAL
            high_mem(idx + 2) := x"4AFC"; -- ILLEGAL
        end procedure;

        procedure run_case is
            variable idle_count : integer := 0;
            variable started    : boolean := false;
        begin
            init_case;

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 50000 loop
                wait until rising_edge(clk);
                if busstate /= "01" then
                    started := true;
                    idle_count := 0;
                elsif started then
                    idle_count := idle_count + 1;
                    if idle_count >= 16 and mem_read(RESULT_ADDR) /= x"0000" then
                        exit;
                    end if;
                end if;
            end loop;

            if mem_read(RESULT_ADDR) = MARK_TRACE then
                report "PASS: packaged D6 target took trace before ILLEGAL" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: packaged D6 target marker mismatch got=" &
                       integer'image(to_integer(unsigned(mem_read(RESULT_ADDR)))) severity error;
                fail_count := fail_count + 1;
            end if;

            if mem_read(TRACE_PATCH_A) = x"00FD" then
                report "PASS: trace handler patched $008B byte" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: trace handler did not patch $008B byte" severity error;
                fail_count := fail_count + 1;
            end if;

            if mem_read(TRACE_PATCH_B) = x"EB48" then
                report "PASS: trace handler patched $008C word" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: trace handler did not patch $008C word" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;
    begin
        report "=== Packaged BASIC JMP 4EFB/65B2 target and trace side effects ===" severity note;
        run_case;

        report "JMP 65B2 packaged-target regression: " & integer'image(pass_count) &
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
