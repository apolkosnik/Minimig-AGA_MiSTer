library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_default_div_rtr_exact is
end entity;

architecture behavior of tb_default_div_rtr_exact is
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
    signal dbg_TG68_PC    : std_logic_vector(31 downto 0);
    signal dbg_FlagsSR    : std_logic_vector(7 downto 0);
    signal dbg_regfile_a7 : std_logic_vector(31 downto 0);
    signal dbg_regfile_we    : std_logic;
    signal dbg_regfile_waddr : std_logic_vector(3 downto 0);
    signal dbg_regfile_wdata : std_logic_vector(31 downto 0);
    signal dbg_trap_vector   : std_logic_vector(31 downto 0);
    signal dbg_micro_state   : integer range 0 to 255;
    signal test_done  : boolean := false;

    constant CLK_PERIOD : time := 10 ns;
    constant LOW_BASE   : integer := 16#00000000#;
    constant LOW_BYTES  : integer := 16#00008000#;
    constant HIGH0_BASE : integer := 16#42000000#;
    constant HIGH0_BYTES : integer := 16#00001000#;
    constant OPC_BASE   : integer := 16#42050000#;
    constant OPC_BYTES  : integer := 16#00001000#;
    constant BOOT_BASE  : integer := 16#43000000#;
    constant BOOT_BYTES : integer := 16#00001000#;
    constant BOOT_PC    : integer := BOOT_BASE;
    constant BOOT_STACK : integer := BOOT_BASE + BOOT_BYTES - 16#40#;

    constant TRACE_VEC_ADDR : integer := 16#00001900#;
    constant EXC4_VEC_ADDR  : integer := 16#000018A0#;
    constant EXC5_VEC_ADDR  : integer := 16#000018B0#;
    constant RESULT_TRACE_SP : integer := 16#42000F00#;
    constant RESULT_EXC4_SP  : integer := 16#42000F04#;
    constant RESULT_EXC5_SP  : integer := 16#42000F08#;
    constant CPUTEST020_VBR_BASE          : integer := BOOT_BASE + 16#0B00#;
    constant CPUTEST020_TABLE_BASE        : integer := BOOT_BASE + 16#0D00#;
    constant CPUTEST020_DEFAULT_HANDLER   : integer := BOOT_BASE + 16#0C90#;
    constant CPUTEST020_EXC4_HANDLER      : integer := BOOT_BASE + 16#0CA4#;
    constant CPUTEST020_EXC5_HANDLER      : integer := BOOT_BASE + 16#0CB8#;
    constant CPUTEST020_DIV_ENTRY_PC      : integer := BOOT_BASE + 16#0100#;
    constant CPUTEST020_HARNESS_RETURN_SP : integer := BOOT_STACK - 4;

    constant USER_SP         : integer := 16#42000400#;
    constant MSP_VALUE       : integer := 16#42000840#;
    constant FRAME_START     : integer := 16#420007B8#;

    type low_mem_t is array (0 to LOW_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high0_mem_t is array (0 to HIGH0_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type opc_mem_t is array (0 to OPC_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type boot_mem_t is array (0 to BOOT_BYTES / 2 - 1) of std_logic_vector(15 downto 0);

    shared variable low_mem   : low_mem_t;
    shared variable high0_mem : high0_mem_t;
    shared variable opc_mem   : opc_mem_t;
    shared variable boot_mem  : boot_mem_t;

    signal rtr_target_seen : std_logic := '0';
    signal rtr_pc_captured : std_logic_vector(31 downto 0) := (others => '0');
    signal rtr_a7_captured : std_logic_vector(31 downto 0) := (others => '0');
    signal last_a7_write_pc   : std_logic_vector(31 downto 0) := (others => '0');
    signal last_a7_write_data : std_logic_vector(31 downto 0) := (others => '0');
    signal last_a7_trap_vec   : std_logic_vector(31 downto 0) := (others => '0');

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
        elsif addr >= BOOT_BASE and addr < BOOT_BASE + BOOT_BYTES then
            idx := (addr - BOOT_BASE) / 2;
            return boot_mem(idx);
        end if;
        return x"4E71";
    end function;

    impure function read_long(addr : integer) return std_logic_vector is
    begin
        return read_word(addr) & read_word(addr + 2);
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
        elsif addr >= BOOT_BASE and addr < BOOT_BASE + BOOT_BYTES then
            idx := (addr - BOOT_BASE) / 2;
            boot_mem(idx) := value;
        end if;
    end procedure;

    procedure write_long(addr : integer; value : std_logic_vector(31 downto 0)) is
    begin
        write_word(addr, value(31 downto 16));
        write_word(addr + 2, value(15 downto 0));
    end procedure;

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
            debug_pmove_dn_regnum => open,
            debug_opcode => open,
            debug_state => open,
            debug_setstate => open,
            debug_last_opc_read => open,
            debug_data_read => open,
            debug_direct_data => open,
            debug_setnextpass => open,
            debug_TG68_PC => dbg_TG68_PC,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout => open,
            debug_decodeOPC => open,
            debug_brief => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw => open,
            debug_regfile_d0 => open,
            debug_regfile_a0 => open,
            debug_fline_context_valid => open,
            debug_trap_1111 => open,
            debug_trapmake => open,
            debug_pmmu_brief => open,
            debug_use_base => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA => open,
            debug_last_data_read => open,
            debug_last_opc_pc => open,
            debug_getbrief => open,
            debug_get_2ndopc => open,
            debug_fline_brief_pending => open,
            debug_fline_opcode_pc => open,
            debug_exe_PC => open,
            debug_memaddr_delta_rega => open,
            debug_memaddr_delta_regb => open,
            debug_addsub_q => open,
            debug_memmaskmux => open,
            debug_fline_opcode_latch => open,
            debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open,
            debug_exec_directPC => open,
            debug_exec_mem_addsub => open,
            debug_set_addrlong => open,
            debug_mdelta_src => open,
            debug_pc_brw => open,
            debug_pc_word => open,
            debug_regfile_d1 => open,
            debug_regfile_d2 => open,
            debug_regfile_d3 => open,
            debug_regfile_d4 => open,
            debug_regfile_d5 => open,
            debug_regfile_d6 => open,
            debug_regfile_d7 => open,
            debug_regfile_a1 => open,
            debug_regfile_a2 => open,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
            debug_regfile_a6 => open,
            debug_regfile_a7 => dbg_regfile_a7,
            debug_regfile_we => dbg_regfile_we,
            debug_regfile_waddr => dbg_regfile_waddr,
            debug_regfile_wdata => dbg_regfile_wdata,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => open,
            debug_trap_berr => open,
            debug_trap_mmu_berr => open,
            debug_trap_vector => dbg_trap_vector,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy => open,
            debug_cpu_halted => open,
            debug_stop => open,
            debug_interrupt => open,
            debug_setendOPC => open,
            debug_IPL_nr => open,
            debug_micro_state => dbg_micro_state,
            debug_next_micro_state => open,
            debug_memmask => open,
            debug_sndOPC => open,
            debug_pmmu_reg_we => open,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open,
            debug_make_berr => open,
            debug_pmmu_fault => open,
            debug_trap_format_error => open,
            debug_format_error_rte_word => open,
            debug_format_error_pc => open,
            debug_format_error_addr => open,
            debug_format_error_sr => open,
            debug_data_write_tmp => open,
            debug_FlagsSR => dbg_FlagsSR
        );

    data_in <= low_mem(to_integer(unsigned(addr_out(14 downto 1))))
               when addr_out(31 downto 0) < x"00008000" else
               high0_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"42000" else
               opc_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"42050" else
               boot_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"43000" else
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
                elsif addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    idx := (addr_i - BOOT_BASE) / 2;
                    if nUDS = '0' then
                        boot_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        boot_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
                if addr_i = RESULT_EXC4_SP or addr_i = RESULT_EXC4_SP + 2 or
                   addr_i = RESULT_EXC5_SP or addr_i = RESULT_EXC5_SP + 2 then
                    report "RESULT_SP_WRITE addr=$" & to_hstring(addr_out) &
                           " data=$" & to_hstring(data_write) &
                           " pc=$" & to_hstring(dbg_TG68_PC) &
                           " a7=$" & to_hstring(dbg_regfile_a7) &
                           " trap=$" & to_hstring(dbg_trap_vector) &
                           " micro=" & integer'image(dbg_micro_state) severity note;
                end if;
            end if;
        end if;
    end process;

    capture: process(clk)
        variable addr_i : integer;
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                rtr_target_seen <= '0';
                rtr_pc_captured <= (others => '0');
                rtr_a7_captured <= (others => '0');
            elsif busstate = "00" and FC(1 downto 0) = "10" then
                addr_i := to_integer(unsigned(addr_out));
                if addr_i = 16#0000703E# and rtr_target_seen = '0' then
                    rtr_target_seen <= '1';
                    rtr_pc_captured <= dbg_TG68_PC;
                    rtr_a7_captured <= dbg_regfile_a7;
                    report "RTR capture: PC=$" & to_hstring(dbg_TG68_PC) &
                           " A7=$" & to_hstring(dbg_regfile_a7) severity note;
                end if;
            end if;
            if dbg_regfile_we = '1' and dbg_regfile_waddr = "1111" then
                last_a7_write_pc <= dbg_TG68_PC;
                last_a7_write_data <= dbg_regfile_wdata;
                last_a7_trap_vec <= dbg_trap_vector;
            end if;
        end if;
    end process;

    test: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable sp_addr    : integer;

        procedure clear_regions is
        begin
            for i in low_mem'range loop
                low_mem(i) := x"4E71";
            end loop;
            for i in high0_mem'range loop
                high0_mem(i) := x"0000";
            end loop;
            for i in opc_mem'range loop
                opc_mem(i) := x"4E71";
            end loop;
            for i in boot_mem'range loop
                boot_mem(i) := x"0000";
            end loop;
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

        procedure emit_jsr_abs(pc : inout integer; value : integer) is
        begin
            emit_word(pc, x"4EB9");
            emit_long(pc, std_logic_vector(to_unsigned(value, 32)));
        end procedure;

        procedure emit_movec_reg_to_ctrl(pc : inout integer; regsel : integer; ctrlsel : integer) is
        begin
            emit_word(pc, x"4E7B");
            emit_word(pc, std_logic_vector(to_unsigned(regsel * 16#1000# + ctrlsel, 16)));
        end procedure;

        procedure emit_set_usp_msp(pc : inout integer; usp_value : integer) is
        begin
            emit_movel_imm_dn(pc, 7, usp_value);
            emit_movec_reg_to_ctrl(pc, 7, 16#0800#);
            emit_movel_imm_dn(pc, 7, MSP_VALUE);
            emit_movec_reg_to_ctrl(pc, 7, 16#0803#);
        end procedure;

        procedure write_bsr_s(addr : integer; target : integer) is
            variable disp8 : integer;
        begin
            disp8 := target - (addr + 2);
            assert disp8 >= -128 and disp8 <= 127
                report "BSR.S target out of range in default exact cputest harness" severity failure;
            write_word(addr, x"61" & std_logic_vector(to_signed(disp8, 8)));
        end procedure;

        procedure install_cputest020_handler(handler_addr : integer;
                                             result_addr  : integer) is
            variable pc : integer := handler_addr;
        begin
            emit_word(pc, x"4FEF");
            emit_word(pc, x"0004");
            emit_word(pc, x"23CF");
            emit_long(pc, std_logic_vector(to_unsigned(result_addr, 32)));
            emit_movea_imm_an(pc, 7, CPUTEST020_HARNESS_RETURN_SP);
            emit_word(pc, x"4E75");
        end procedure;

        procedure install_cputest020_exception_table is
            variable entry_addr : integer;
        begin
            for vector in 2 to 63 loop
                entry_addr := CPUTEST020_TABLE_BASE + (vector - 2) * 2;
                case vector is
                    when 4 =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(entry_addr, 32)));
                        write_bsr_s(entry_addr, CPUTEST020_EXC4_HANDLER);
                    when 5 =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(entry_addr, 32)));
                        write_bsr_s(entry_addr, CPUTEST020_EXC5_HANDLER);
                    when others =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(CPUTEST020_DEFAULT_HANDLER, 32)));
                end case;
            end loop;

            install_cputest020_handler(CPUTEST020_DEFAULT_HANDLER, RESULT_EXC4_SP);
            install_cputest020_handler(CPUTEST020_EXC4_HANDLER, RESULT_EXC4_SP);
            install_cputest020_handler(CPUTEST020_EXC5_HANDLER, RESULT_EXC5_SP);
        end procedure;

        procedure install_cputest020_boot(entry_pc : integer) is
            variable pc : integer := BOOT_PC;
        begin
            emit_movea_imm_an(pc, 0, CPUTEST020_VBR_BASE);
            emit_movec_reg_to_ctrl(pc, 8, 16#0801#);  -- MOVEC A0,VBR
            emit_jsr_abs(pc, entry_pc);
            emit_word(pc, x"4E72");
            emit_word(pc, x"2700");
        end procedure;

        procedure set_reset_vectors is
        begin
            write_long(16#0#, std_logic_vector(to_unsigned(BOOT_STACK, 32)));
            write_long(16#4#, std_logic_vector(to_unsigned(BOOT_PC, 32)));
        end procedure;

        procedure install_exc_stub(vector_num : integer; stub_addr : integer; result_addr : integer) is
        begin
            write_long(vector_num * 4, std_logic_vector(to_unsigned(stub_addr, 32)));
            write_word(stub_addr, x"200F"); -- MOVE.L A7,D0
            write_word(stub_addr + 2, x"33C0"); -- MOVE.W D0,$abs.l (low word)
            write_word(stub_addr + 4, std_logic_vector(to_unsigned((result_addr + 2) / 16#10000#, 16)));
            write_word(stub_addr + 6, std_logic_vector(to_unsigned((result_addr + 2) mod 16#10000#, 16)));
            write_word(stub_addr + 8, x"4840"); -- SWAP D0
            write_word(stub_addr + 10, x"33C0"); -- MOVE.W D0,$abs.l (high word)
            write_word(stub_addr + 12, std_logic_vector(to_unsigned(result_addr / 16#10000#, 16)));
            write_word(stub_addr + 14, std_logic_vector(to_unsigned(result_addr mod 16#10000#, 16)));
            write_word(stub_addr + 16, x"4E72");
            write_word(stub_addr + 18, x"2700");
        end procedure;

        procedure init_common is
        begin
            clear_regions;
            set_reset_vectors;
            install_exc_stub(4, EXC4_VEC_ADDR, RESULT_EXC4_SP);
            install_exc_stub(5, EXC5_VEC_ADDR, RESULT_EXC5_SP);
            write_long(RESULT_TRACE_SP, x"00000000");
            write_long(RESULT_EXC4_SP, x"00000000");
            write_long(RESULT_EXC5_SP, x"00000000");
            rtr_target_seen <= '0';
            rtr_pc_captured <= (others => '0');
            rtr_a7_captured <= (others => '0');
        end procedure;

        procedure init_common_cputest020 is
        begin
            clear_regions;
            set_reset_vectors;
            install_cputest020_exception_table;
            write_long(RESULT_TRACE_SP, x"00000000");
            write_long(RESULT_EXC4_SP, x"00000000");
            write_long(RESULT_EXC5_SP, x"00000000");
            rtr_target_seen <= '0';
            rtr_pc_captured <= (others => '0');
            rtr_a7_captured <= (others => '0');
        end procedure;

        procedure build_common_boot(pc : inout integer) is
        begin
            emit_set_usp_msp(pc, USER_SP);
            emit_movea_imm_an(pc, 0, 0);
            emit_movea_imm_an(pc, 7, FRAME_START);
        end procedure;

        procedure install_frame(sr_value : std_logic_vector(15 downto 0); next_pc : integer) is
        begin
            write_word(FRAME_START, sr_value);
            write_long(FRAME_START + 2, std_logic_vector(to_unsigned(next_pc, 32)));
            write_word(FRAME_START + 6, x"0000");
        end procedure;

        procedure install_default_div_common is
            variable pc : integer := CPUTEST020_DIV_ENTRY_PC;
        begin
            build_common_boot(pc);
            emit_movel_imm_dn(pc, 0, 16#00000022#);
            emit_movel_imm_dn(pc, 1, 16#00000000#);
            emit_movel_imm_dn(pc, 2, -1);
            emit_movel_imm_dn(pc, 3, -256);
            emit_movel_imm_dn(pc, 4, -16#00010000#);
            emit_movel_imm_dn(pc, 5, -16#7FFF7F80#);
            emit_movel_imm_dn(pc, 6, 16#00010101#);
            emit_movel_imm_dn(pc, 7, -16#55555556#);
            emit_movea_imm_an(pc, 1, 16#00000078#);
            emit_movea_imm_an(pc, 2, 16#00007FF0#);
            emit_movea_imm_an(pc, 3, 16#00007FFF#);
            emit_movea_imm_an(pc, 4, -2);
            emit_movea_imm_an(pc, 5, -256);
            emit_movea_imm_an(pc, 6, 16#4204FF00#);
            emit_word(pc, x"4E73");
            install_frame(x"0000", OPC_BASE);
        end procedure;

        procedure install_divl_case is
        begin
            init_common_cputest020;
            install_cputest020_boot(CPUTEST020_DIV_ENTRY_PC);
            install_default_div_common;
            write_word(OPC_BASE + 16#0000#, x"4C40");
            write_word(OPC_BASE + 16#0002#, x"9E54");
            write_word(OPC_BASE + 16#0004#, x"2048");
            write_word(OPC_BASE + 16#0006#, x"4AFC");
        end procedure;

        procedure install_divu_case is
        begin
            init_common_cputest020;
            install_cputest020_boot(CPUTEST020_DIV_ENTRY_PC);
            install_default_div_common;
            write_word(OPC_BASE + 16#0000#, x"80C1");
            write_word(OPC_BASE + 16#0002#, x"2048");
            write_word(OPC_BASE + 16#0004#, x"4AFC");
        end procedure;

        procedure install_divs_mem_case is
            variable pc : integer := BOOT_PC;
        begin
            init_common;
            build_common_boot(pc);
            emit_movel_imm_dn(pc, 0, 16#0000166C#);
            emit_movel_imm_dn(pc, 2, 16#DFFFDFFF#);
            emit_movel_imm_dn(pc, 3, 16#700DFFFF#);
            emit_movel_imm_dn(pc, 4, 16#D5500095#);
            emit_movel_imm_dn(pc, 5, 16#800A8A8A#);
            emit_movel_imm_dn(pc, 6, 16#02000202#);
            emit_movel_imm_dn(pc, 7, 16#5C06FFB5#);
            emit_movea_imm_an(pc, 1, 16#00000080#);
            emit_movea_imm_an(pc, 2, 16#0000801D#);
            emit_movea_imm_an(pc, 3, 16#0000FFFF#);
            emit_movea_imm_an(pc, 4, 16#7FFFFF7A#);
            emit_movea_imm_an(pc, 5, 16#C03FFFFF#);
            emit_movea_imm_an(pc, 6, 16#4204FF00#);
            emit_word(pc, x"4E73");
            install_frame(x"0000", OPC_BASE);

            write_word(16#420043B4#, x"5838");
            write_word(16#420043B6#, x"0000");
            write_word(OPC_BASE + 16#0000#, x"85EF");
            write_word(OPC_BASE + 16#0002#, x"3FB4");
            write_word(OPC_BASE + 16#0004#, x"2048");
            write_word(OPC_BASE + 16#0006#, x"4AFC");
        end procedure;

        procedure install_rtr_case is
            variable pc : integer := BOOT_PC;
        begin
            init_common;
            build_common_boot(pc);
            emit_movel_imm_dn(pc, 0, 16#00000010#);
            emit_movel_imm_dn(pc, 2, -1);
            emit_movel_imm_dn(pc, 3, -256);
            emit_movel_imm_dn(pc, 6, 16#00010101#);
            emit_movel_imm_dn(pc, 7, 16#AAAAAAAA#);
            emit_movea_imm_an(pc, 1, 16#00000078#);
            emit_movea_imm_an(pc, 3, 16#00007FFF#);
            emit_movea_imm_an(pc, 4, -2);
            emit_word(pc, x"4E73");
            install_frame(x"0000", OPC_BASE);

            write_word(OPC_BASE + 16#0000#, x"4E77");
            write_word(USER_SP + 16#0000#, x"C5A0");
            write_word(USER_SP + 16#0002#, x"0000");
            write_word(USER_SP + 16#0004#, x"703E");
            write_word(16#703E#, x"4AFC");
            write_word(16#7040#, x"2048");
        end procedure;

        procedure do_reset is
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';
        end procedure;

        procedure wait_cycles(max_cycles : integer) is
        begin
            for i in 0 to max_cycles loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

    begin
        report "=== exact default DIV/RTR probe ===" severity note;

        install_divl_case;
        do_reset;
        for i in 0 to 30000 loop
            wait until rising_edge(clk);
            exit when read_long(RESULT_EXC4_SP) /= x"00000000";
        end loop;

        sp_addr := to_integer(unsigned(read_long(RESULT_EXC4_SP)));
        if sp_addr /= 0 and read_word(sp_addr) = x"0006" then
            report "PASS: DIVL.L record1/group0/sub0 stacked SR matched $0006" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: DIVL.L record1/group0/sub0 stacked SR mismatch, seen=$" &
                   to_hstring(read_word(sp_addr)) & " sp=$" &
                   integer'image(sp_addr) &
                   " m2=$" & to_hstring(read_word(sp_addr - 2)) &
                   " p2=$" & to_hstring(read_word(sp_addr + 2)) &
                   " p4=$" & to_hstring(read_word(sp_addr + 4)) &
                   " a7=$" & to_hstring(dbg_regfile_a7) &
                   " last_a7_pc=$" & to_hstring(last_a7_write_pc) &
                   " last_a7_data=$" & to_hstring(last_a7_write_data) &
                   " trapvec=$" & to_hstring(dbg_trap_vector) &
                   " last_a7_trap=$" & to_hstring(last_a7_trap_vec) &
                   " ms=" & integer'image(dbg_micro_state) severity error;
            fail_count := fail_count + 1;
        end if;

        install_divu_case;
        do_reset;
        for i in 0 to 30000 loop
            wait until rising_edge(clk);
            exit when read_long(RESULT_EXC5_SP) /= x"00000000";
        end loop;

        sp_addr := to_integer(unsigned(read_long(RESULT_EXC5_SP)));
        if sp_addr /= 0 and read_word(sp_addr) = x"0006" then
            report "PASS: DIVU.W record1/group0/sub0 stacked SR matched $0006" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: DIVU.W record1/group0/sub0 stacked SR mismatch, seen=$" &
                   to_hstring(read_word(sp_addr)) & " sp=$" &
                   integer'image(sp_addr) &
                   " m2=$" & to_hstring(read_word(sp_addr - 2)) &
                   " p2=$" & to_hstring(read_word(sp_addr + 2)) &
                   " p4=$" & to_hstring(read_word(sp_addr + 4)) &
                   " a7=$" & to_hstring(dbg_regfile_a7) &
                   " last_a7_pc=$" & to_hstring(last_a7_write_pc) &
                   " last_a7_data=$" & to_hstring(last_a7_write_data) &
                   " trapvec=$" & to_hstring(dbg_trap_vector) &
                   " last_a7_trap=$" & to_hstring(last_a7_trap_vec) &
                   " ms=" & integer'image(dbg_micro_state) severity error;
            fail_count := fail_count + 1;
        end if;

        install_divs_mem_case;
        do_reset;
        for i in 0 to 30000 loop
            wait until rising_edge(clk);
            exit when read_long(RESULT_EXC4_SP) /= x"00000000";
        end loop;

        sp_addr := to_integer(unsigned(dbg_regfile_a7));
        if sp_addr /= 0 and read_word(sp_addr) = x"0000" then
            report "PASS: DIVS.W record684/group0/sub0 stacked SR matched $0000" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: DIVS.W record684/group0/sub0 stacked SR mismatch, seen=$" &
                   to_hstring(read_word(sp_addr)) & " sp=$" &
                   integer'image(sp_addr) severity error;
            fail_count := fail_count + 1;
        end if;

        install_rtr_case;
        do_reset;
        for i in 0 to 30000 loop
            wait until rising_edge(clk);
            exit when rtr_target_seen = '1';
        end loop;
        if rtr_target_seen = '1' and rtr_a7_captured = x"42000406" then
            report "PASS: RTR record0/group0/sub0 reached target with A7=$42000406" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: RTR record0/group0/sub0 target A7 mismatch, seen=$" &
                   to_hstring(rtr_a7_captured) severity error;
            fail_count := fail_count + 1;
        end if;

        if rtr_target_seen = '1' and rtr_pc_captured = x"0000703E" then
            report "PASS: RTR record0/group0/sub0 fetched target $0000703E" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: RTR record0/group0/sub0 target fetch mismatch, seen pc=$" &
                   to_hstring(rtr_pc_captured) severity error;
            fail_count := fail_count + 1;
        end if;

        report "RESULT: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;
        test_done <= true;
        wait;
    end process;
end architecture;
