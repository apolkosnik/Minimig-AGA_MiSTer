library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_basic_cputest_exact is
end entity;

architecture behavior of tb_basic_cputest_exact is
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
    signal test_done  : boolean := false;

    constant CLK_PERIOD      : time := 10 ns;
    constant IMAGE_FILE      : string := "data/cputest_basic_sparse.mem";
    constant LOW_BASE        : integer := 16#00000000#;
    constant LOW_BYTES       : integer := 16#00002000#;
    constant HIGH0_BASE      : integer := 16#42000000#;
    constant HIGH0_BYTES     : integer := 16#00001000#;
    constant OPC_BASE        : integer := 16#42050000#;
    constant OPC_BYTES       : integer := 16#00001000#;
    constant HIGH1_BASE      : integer := 16#4204FE00#;
    constant HIGH1_BYTES     : integer := 16#00000280#;
    constant HIGH2_BASE      : integer := 16#42006900#;
    constant HIGH2_BYTES     : integer := 16#00000580#;
    constant BOOT_PC         : integer := 16#42000E00#;
    constant ISP_VALUE       : integer := 16#420007C0#;
    constant MSP_VALUE       : integer := 16#42000840#;
    constant CHK_USP_VALUE   : integer := 16#42000400#;
    constant JMP_USP_VALUE   : integer := 16#420003FE#;
    constant CHK_FRAME_START : integer := ISP_VALUE - 8;
    constant JMP_FRAME_START : integer := ISP_VALUE - 8;
    constant TRACE_VEC_ADDR  : integer := 16#00001900#;
    constant EXC6_VEC_ADDR   : integer := 16#000018C0#;
    constant EXC11_VEC_ADDR  : integer := 16#00001940#;
    constant RESULT_TRACE_SP : integer := 16#42000F00#;
    constant RESULT_EXC_SP   : integer := 16#42000F04#;

    type low_mem_t is array (0 to LOW_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high0_mem_t is array (0 to HIGH0_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type opc_mem_t is array (0 to OPC_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high1_mem_t is array (0 to HIGH1_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high2_mem_t is array (0 to HIGH2_BYTES / 2 - 1) of std_logic_vector(15 downto 0);

    shared variable low_mem   : low_mem_t;
    shared variable high0_mem : high0_mem_t;
    shared variable opc_mem   : opc_mem_t;
    shared variable high1_mem : high1_mem_t;
    shared variable high2_mem : high2_mem_t;
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

    data_in <= low_mem(to_integer(unsigned(addr_out(14 downto 1))))
               when addr_out(31 downto 0) < x"00002000" else
               high0_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"42000" else
               opc_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"42050" else
               high1_mem(to_integer(unsigned(addr_out(8 downto 1))))
               when addr_out(31 downto 9) = std_logic_vector(to_unsigned(HIGH1_BASE / 16#200#, 23)) else
               high2_mem(to_integer(unsigned(addr_out(10 downto 1))))
               when addr_out(31 downto 11) = std_logic_vector(to_unsigned(HIGH2_BASE / 16#800#, 21)) else
               x"4E71";

    mem_write: process(clk)
        variable addr_i : integer;
        variable idx    : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                addr_i := to_integer(unsigned(addr_out));
                if addr_i >= LOW_BASE and addr_i < LOW_BASE + LOW_BYTES then
                    idx := (addr_i - LOW_BASE) / 2;
                    if nUDS = '0' then
                        low_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        low_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                elsif addr_i >= HIGH0_BASE and addr_i < HIGH0_BASE + HIGH0_BYTES then
                    idx := (addr_i - HIGH0_BASE) / 2;
                    if nUDS = '0' then
                        high0_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        high0_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                elsif addr_i >= OPC_BASE and addr_i < OPC_BASE + OPC_BYTES then
                    idx := (addr_i - OPC_BASE) / 2;
                    if nUDS = '0' then
                        opc_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        opc_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                elsif addr_i >= HIGH1_BASE and addr_i < HIGH1_BASE + HIGH1_BYTES then
                    idx := (addr_i - HIGH1_BASE) / 2;
                    if nUDS = '0' then
                        high1_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        high1_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                elsif addr_i >= HIGH2_BASE and addr_i < HIGH2_BASE + HIGH2_BYTES then
                    idx := (addr_i - HIGH2_BASE) / 2;
                    if nUDS = '0' then
                        high2_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        high2_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

        impure function slv_to_hex(v : std_logic_vector) return string is
            constant hex_chars : string := "0123456789ABCDEF";
            variable padded    : std_logic_vector(((v'length + 3) / 4) * 4 - 1 downto 0) := (others => '0');
            variable result    : string(1 to padded'length / 4);
            variable nibble    : std_logic_vector(3 downto 0);
        begin
            padded(v'length - 1 downto 0) := v;
            for i in 0 to result'length - 1 loop
                nibble := padded(padded'length - 1 - i * 4 downto padded'length - 4 - i * 4);
                result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
            end loop;
            return result;
        end function;

        procedure write_word(addr : integer; value : std_logic_vector(15 downto 0)) is
            variable idx : integer;
        begin
            if addr >= LOW_BASE and addr < LOW_BASE + LOW_BYTES then
                idx := (addr - LOW_BASE) / 2;
                low_mem(idx) := value;
            elsif addr >= HIGH0_BASE and addr < HIGH0_BASE + HIGH0_BYTES then
                idx := (addr - HIGH0_BASE) / 2;
                high0_mem(idx) := value;
            elsif addr >= OPC_BASE and addr < OPC_BASE + OPC_BYTES then
                idx := (addr - OPC_BASE) / 2;
                opc_mem(idx) := value;
            elsif addr >= HIGH1_BASE and addr < HIGH1_BASE + HIGH1_BYTES then
                idx := (addr - HIGH1_BASE) / 2;
                high1_mem(idx) := value;
            elsif addr >= HIGH2_BASE and addr < HIGH2_BASE + HIGH2_BYTES then
                idx := (addr - HIGH2_BASE) / 2;
                high2_mem(idx) := value;
            end if;
        end procedure;

        procedure write_long(addr : integer; value : std_logic_vector(31 downto 0)) is
        begin
            write_word(addr, value(31 downto 16));
            write_word(addr + 2, value(15 downto 0));
        end procedure;

        impure function read_word(addr : integer) return std_logic_vector is
            variable idx : integer;
        begin
            if addr >= LOW_BASE and addr < LOW_BASE + LOW_BYTES then
                idx := (addr - LOW_BASE) / 2;
                return low_mem(idx);
            elsif addr >= HIGH0_BASE and addr < HIGH0_BASE + HIGH0_BYTES then
                idx := (addr - HIGH0_BASE) / 2;
                return high0_mem(idx);
            elsif addr >= OPC_BASE and addr < OPC_BASE + OPC_BYTES then
                idx := (addr - OPC_BASE) / 2;
                return opc_mem(idx);
            elsif addr >= HIGH1_BASE and addr < HIGH1_BASE + HIGH1_BYTES then
                idx := (addr - HIGH1_BASE) / 2;
                return high1_mem(idx);
            elsif addr >= HIGH2_BASE and addr < HIGH2_BASE + HIGH2_BYTES then
                idx := (addr - HIGH2_BASE) / 2;
                return high2_mem(idx);
            end if;
            return x"4E71";
        end function;

        impure function read_long(addr : integer) return std_logic_vector is
        begin
            return read_word(addr) & read_word(addr + 2);
        end function;

        impure function read_byte(addr : integer) return std_logic_vector is
        begin
            if (addr mod 2) = 0 then
                return read_word(addr)(15 downto 8);
            end if;
            return read_word(addr - 1)(7 downto 0);
        end function;

        procedure clear_regions is
        begin
            for i in low_mem'range loop
                low_mem(i) := x"0000";
            end loop;
            for i in high0_mem'range loop
                high0_mem(i) := x"0000";
            end loop;
            for i in opc_mem'range loop
                opc_mem(i) := x"0000";
            end loop;
            for i in high1_mem'range loop
                high1_mem(i) := x"0000";
            end loop;
            for i in high2_mem'range loop
                high2_mem(i) := x"0000";
            end loop;
        end procedure;

        procedure load_sparse_image is
            file f           : text open read_mode is IMAGE_FILE;
            variable l       : line;
            variable addr_sl : std_logic_vector(31 downto 0);
            variable word_sl : std_logic_vector(15 downto 0);
        begin
            clear_regions;
            while not endfile(f) loop
                readline(f, l);
                hread(l, addr_sl);
                hread(l, word_sl);
                write_word(to_integer(unsigned(addr_sl)), word_sl);
            end loop;
        end procedure;

        procedure install_trace_stub is
        begin
            write_long(16#24#, x"00001900");
            write_word(TRACE_VEC_ADDR, x"23CF");
            write_word(TRACE_VEC_ADDR + 2, x"4200");
            write_word(TRACE_VEC_ADDR + 4, x"0F00");
            write_word(TRACE_VEC_ADDR + 6, x"4E73");
        end procedure;

        procedure install_exc_stub(vector_num : integer; stub_addr : integer) is
            variable vector_addr : integer;
        begin
            vector_addr := vector_num * 4;
            write_long(vector_addr, std_logic_vector(to_unsigned(stub_addr, 32)));
            write_word(stub_addr, x"23CF");
            write_word(stub_addr + 2, x"4200");
            write_word(stub_addr + 4, x"0F04");
            write_word(stub_addr + 6, x"4E72");
            write_word(stub_addr + 8, x"2700");
        end procedure;

        procedure set_reset_vectors is
        begin
            write_long(16#0#, std_logic_vector(to_unsigned(ISP_VALUE, 32)));
            write_long(16#4#, std_logic_vector(to_unsigned(BOOT_PC, 32)));
        end procedure;

        procedure emit_word(pc : inout integer; value : std_logic_vector(15 downto 0)) is
        begin
            write_word(pc, value);
            pc := pc + 2;
        end procedure;

        procedure emit_long(pc : inout integer; value : std_logic_vector(31 downto 0)) is
        begin
            emit_word(pc, value(31 downto 16));
            emit_word(pc, value(15 downto 0));
        end procedure;

        procedure emit_moveq0_d1(pc : inout integer) is
        begin
            emit_word(pc, x"7200");
        end procedure;

        procedure emit_movel_imm_dn(pc : inout integer; regnum : integer; value : integer) is
        begin
            emit_word(pc, std_logic_vector(to_unsigned(16#203C# + regnum * 16#0200#, 16)));
            emit_long(pc, std_logic_vector(to_signed(value, 32)));
        end procedure;

        procedure emit_movea_imm_an(pc : inout integer; regnum : integer; value : integer) is
        begin
            emit_word(pc, std_logic_vector(to_unsigned(16#207C# + regnum * 16#0200#, 16)));
            emit_long(pc, std_logic_vector(to_signed(value, 32)));
        end procedure;

        procedure emit_set_usp_msp(pc : inout integer; usp_value : integer) is
        begin
            emit_movel_imm_dn(pc, 7, usp_value);
            emit_word(pc, x"4E7B");
            emit_word(pc, x"7800");
            emit_movel_imm_dn(pc, 7, MSP_VALUE);
            emit_word(pc, x"4E7B");
            emit_word(pc, x"7803");
        end procedure;

        procedure build_common_boot(pc : inout integer;
                                    usp_value : integer;
                                    frame_start : integer) is
        begin
            emit_set_usp_msp(pc, usp_value);
            emit_movea_imm_an(pc, 0, 0);
            emit_movea_imm_an(pc, 7, frame_start);
        end procedure;

        procedure finish_boot is
            variable pc : integer := BOOT_PC;
        begin
            while read_word(pc) /= x"0000" loop
                pc := pc + 2;
            end loop;
            emit_word(pc, x"4E73");
        end procedure;

        procedure install_chk2_boot(opcode_word : std_logic_vector(15 downto 0);
                                    sr_value    : std_logic_vector(15 downto 0)) is
            variable pc : integer := BOOT_PC;
        begin
            build_common_boot(pc, CHK_USP_VALUE, CHK_FRAME_START);
            emit_movel_imm_dn(pc, 0, 16#00000010#);
            emit_moveq0_d1(pc);
            emit_movel_imm_dn(pc, 2, -1);
            emit_movel_imm_dn(pc, 3, -256);
            emit_movel_imm_dn(pc, 4, 16#FFFF0000#);
            emit_movel_imm_dn(pc, 5, 16#80008080#);
            emit_movel_imm_dn(pc, 6, 16#00010101#);
            emit_movel_imm_dn(pc, 7, 16#AAAAAAAA#);
            emit_movea_imm_an(pc, 1, 16#00000078#);
            emit_movea_imm_an(pc, 2, 16#00007FF0#);
            emit_movea_imm_an(pc, 3, 16#00007FFF#);
            emit_movea_imm_an(pc, 4, -2);
            emit_movea_imm_an(pc, 5, -256);
            emit_movea_imm_an(pc, 6, 16#4204FF00#);
            emit_movea_imm_an(pc, 7, CHK_FRAME_START);
            emit_word(pc, x"4E73");

            write_word(CHK_FRAME_START, sr_value);
            write_long(CHK_FRAME_START + 2, x"42050000");
            write_word(CHK_FRAME_START + 6, x"0000");

            write_word(16#42050000#, opcode_word);
            write_word(16#42050002#, x"0800");
            write_word(16#42050004#, x"4E72");
            write_word(16#42050006#, x"2700");
        end procedure;

        procedure install_jmp_boot is
            variable pc : integer := BOOT_PC;
        begin
            build_common_boot(pc, JMP_USP_VALUE, JMP_FRAME_START);
            emit_movel_imm_dn(pc, 0, 16#000000B2#);
            emit_moveq0_d1(pc);
            emit_movel_imm_dn(pc, 2, 16#FFFFFD7F#);
            emit_movel_imm_dn(pc, 3, 16#0FFFDF70#);
            emit_movel_imm_dn(pc, 4, 16#87FFF0C1#);
            emit_movel_imm_dn(pc, 5, 16#80028282#);
            emit_movel_imm_dn(pc, 6, 16#00080808#);
            emit_movel_imm_dn(pc, 7, 16#AAAAAAAA#);
            emit_movea_imm_an(pc, 1, 16#0000008B#);
            emit_movea_imm_an(pc, 2, 16#00008014#);
            emit_movea_imm_an(pc, 3, 16#0000FFFF#);
            emit_movea_imm_an(pc, 4, 16#7FFFFF3A#);
            emit_movea_imm_an(pc, 5, 16#0FFFFFF0#);
            emit_movea_imm_an(pc, 6, 16#4204FEFF#);
            emit_movea_imm_an(pc, 7, JMP_FRAME_START);
            emit_word(pc, x"4E73");

            write_word(JMP_FRAME_START, x"6000");
            write_long(JMP_FRAME_START + 2, x"42050000");
            write_word(JMP_FRAME_START + 6, x"0000");

            write_word(16#42050000#, x"4EEF");
            write_word(16#42050002#, x"65B2");
            write_long(16#420069B0#, x"4AFC2048");
        end procedure;

        procedure init_common is
        begin
            load_sparse_image;
            set_reset_vectors;
            install_trace_stub;
            install_exc_stub(6, EXC6_VEC_ADDR);
            install_exc_stub(11, EXC11_VEC_ADDR);
            write_long(RESULT_TRACE_SP, x"00000000");
            write_long(RESULT_EXC_SP, x"00000000");
        end procedure;

        procedure run_case(expect_trace : boolean;
                           expect_exc   : boolean;
                           max_cycles   : integer := 40000) is
            variable started    : boolean := false;
            variable idle_count : integer := 0;
            variable done_count : integer := 0;
            variable saw_trace  : boolean := false;
            variable saw_exc    : boolean := false;
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);

                saw_trace := saw_trace or (read_long(RESULT_TRACE_SP) /= x"00000000");
                saw_exc := saw_exc or (read_long(RESULT_EXC_SP) /= x"00000000");

                if (not expect_trace or saw_trace) and
                   (not expect_exc or saw_exc) then
                    done_count := done_count + 1;
                    if done_count >= 8 then
                        return;
                    end if;
                else
                    done_count := 0;
                end if;

                if busstate /= "01" then
                    started := true;
                    idle_count := 0;
                elsif started then
                    idle_count := idle_count + 1;
                    if idle_count >= 16 then
                        return;
                    end if;
                end if;
            end loop;

            report "NOTE: run_case exhausted cycle budget without going idle" severity note;
        end procedure;

        procedure check_chk2_stacked(case_name : string; opcode_word : std_logic_vector(15 downto 0)) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc_sr   : std_logic_vector(15 downto 0);
        begin
            init_common;
            install_chk2_boot(opcode_word, x"4000");
            run_case(true, true);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC_SP)));

            if trace_sp /= 0 then
                report "PASS: " & case_name & " took stacked trace" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " did not enter trace handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if exc_sp /= 0 then
                report "PASS: " & case_name & " reached exception 6 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " did not enter exception 6 handler" severity error;
                fail_count := fail_count + 1;
                if trace_sp = 0 then
                    return;
                end if;
            end if;

            if trace_sp = 0 then
                return;
            end if;

            trace_sr := read_word(trace_sp);
            trace_pc := read_long(trace_sp + 2);

            if trace_pc = x"000018C0" then
                report "PASS: " & case_name & " stacked trace PC matched cputest vector address" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " stacked trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $000018C0" severity error;
                fail_count := fail_count + 1;
            end if;

            if exc_sp /= 0 then
                exc_sr := read_word(exc_sp);
                if trace_sr(13) = '1' and
                   ((unsigned(trace_sr) or to_unsigned(16#E000#, 16)) =
                    (unsigned(exc_sr) or to_unsigned(16#E000#, 16))) then
                    report "PASS: " & case_name & " stacked trace SR matched cputest relation" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " stacked trace SR=$" & slv_to_hex(trace_sr) &
                           " exc SR=$" & slv_to_hex(exc_sr) severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;
        end procedure;

        procedure check_chk2_word_standalone is
            variable trace_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
        begin
            init_common;
            install_chk2_boot(x"02D0", x"8000");
            run_case(true, false);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            if trace_sp /= 0 then
                report "PASS: CHK2.W entered standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.W did not enter standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            trace_sr := read_word(trace_sp);
            trace_pc := read_long(trace_sp + 2);

            if trace_sr = x"8000" then
                report "PASS: CHK2.W standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.W standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $8000" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = x"42050004" then
                report "PASS: CHK2.W standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.W standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $42050004" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_exact is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common;
            install_jmp_boot;
            run_case(true, true, 80000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC_SP)));

            if trace_sp /= 0 then
                report "PASS: JMP/0002 record=37 group=3 hit standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP/0002 record=37 group=3 missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if exc_sp /= 0 then
                report "PASS: JMP/0002 record=37 group=3 reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP/0002 record=37 group=3 missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
            end if;
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if trace_sp /= 0 then
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);

                if trace_sr = x"6000" then
                    report "PASS: JMP standalone trace SR matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: JMP standalone trace SR=$" & slv_to_hex(trace_sr) &
                           " expected $6000" severity error;
                    fail_count := fail_count + 1;
                end if;

                if trace_pc = x"42006D72" then
                    report "PASS: JMP standalone trace PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: JMP standalone trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $42006D72" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;

            if low_b = x"FD" then
                report "PASS: JMP low byte $8B matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP byte $8B=$" & slv_to_hex(low_b) & " expected $FD" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_w = x"EB48" then
                report "PASS: JMP low word $8C matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP word $8C=$" & slv_to_hex(low_w) & " expected $EB48" severity error;
                fail_count := fail_count + 1;
            end if;

            if high_b = x"75" then
                report "PASS: JMP byte $4204FEFF matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP byte $4204FEFF=$" & slv_to_hex(high_b) & " expected $75" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

    begin
        check_chk2_stacked("CHK2.B", x"00D0");
        check_chk2_stacked("CHK2.L", x"04D0");
        check_chk2_word_standalone;
        check_jmp_exact;

        report "RESULT: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;
        test_done <= true;
        wait;
    end process;
end architecture;
