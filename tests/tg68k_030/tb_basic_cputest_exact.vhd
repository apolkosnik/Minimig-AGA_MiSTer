library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_basic_cputest_exact is
    generic (
        suite_select : integer := 0;
        group_first  : integer := 0;
        group_last   : integer := 15;
        timing_select : integer := 0
    );
end entity;

architecture behavior of tb_basic_cputest_exact is
    alias dbg_ea_data : std_logic_vector(31 downto 0) is
        << signal .tb_basic_cputest_exact.dut.ea_data : std_logic_vector(31 downto 0) >>;
    alias dbg_op2out : std_logic_vector(31 downto 0) is
        << signal .tb_basic_cputest_exact.dut.op2out : std_logic_vector(31 downto 0) >>;
    signal clk        : std_logic := '0';
    signal nReset     : std_logic := '0';
    signal clkena_in  : std_logic := '1';
    signal mem_wait   : std_logic := '0';
    signal data_in    : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal busstate   : std_logic_vector(1 downto 0);
    signal FC         : std_logic_vector(2 downto 0);
    signal test_done  : boolean := false;
    signal dbg_opcode           : std_logic_vector(15 downto 0);
    signal dbg_setopcode        : std_logic;
    signal dbg_last_opc_read    : std_logic_vector(15 downto 0);
    signal dbg_data_read        : std_logic_vector(31 downto 0);
    signal dbg_last_data_read   : std_logic_vector(31 downto 0);
    signal dbg_reg_QA           : std_logic_vector(31 downto 0);
    signal dbg_memaddr_reg      : std_logic_vector(31 downto 0);
    signal dbg_memaddr_delta    : std_logic_vector(31 downto 0);
    signal dbg_memmaskmux       : std_logic_vector(5 downto 0);
    signal dbg_direct_data      : std_logic;
    signal dbg_regfile_a0       : std_logic_vector(31 downto 0);
    signal dbg_regfile_d0       : std_logic_vector(31 downto 0);
    signal dbg_regfile_a2       : std_logic_vector(31 downto 0);
    signal dbg_regfile_d7       : std_logic_vector(31 downto 0);
    signal dbg_regfile_a7       : std_logic_vector(31 downto 0);
    signal dbg_FlagsSR          : std_logic_vector(7 downto 0);
    signal dbg_TG68_PC          : std_logic_vector(31 downto 0);
    signal dbg_pc_add           : std_logic_vector(31 downto 0);
    signal dbg_pc_brw           : std_logic;
    signal dbg_pc_word          : std_logic;
    signal dbg_exe_PC           : std_logic_vector(31 downto 0);
    signal dbg_micro_state      : integer range 0 to 255;
    signal dbg_next_micro_state : integer range 0 to 255;
    signal dbg_state            : std_logic_vector(1 downto 0);
    signal dbg_setstate         : std_logic_vector(1 downto 0);
    signal dbg_use_stackframe2  : std_logic;
    signal dbg_data_write_tmp   : std_logic_vector(31 downto 0);
    signal trace_handler_seen   : std_logic := '0';
    signal first_trace_frame_valid : std_logic := '0';
    signal first_trace_frame_sr    : std_logic_vector(15 downto 0) := (others => '0');
    signal first_trace_frame_pc    : std_logic_vector(31 downto 0) := (others => '0');
    signal first_trace_frame_fv    : std_logic_vector(15 downto 0) := (others => '0');
    signal first_trace_frame_ia    : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_posttrace_fetches : integer range 0 to 31 := 0;
    signal jmp_fetch_seen       : std_logic := '0';
    signal jmp_target_captured  : std_logic := '0';
    signal jmp_target_fetch_addr   : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_opcode : std_logic_vector(15 downto 0) := (others => '0');
    signal jmp_target_fetch_a7     : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_regqa  : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_mreg   : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_mdelta : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_sr     : std_logic_vector(7 downto 0) := (others => '0');
    signal jmp_target_fetch_tg68pc : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_pcadd  : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_pcbrw  : std_logic := '0';
    signal jmp_target_fetch_pcword : std_logic := '0';
    signal jmp_target_fetch_exepc  : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_dataread : std_logic_vector(31 downto 0) := (others => '0');
    signal jmp_target_fetch_lastopc  : std_logic_vector(15 downto 0) := (others => '0');
    signal jmp_target_fetch_micro  : integer range 0 to 255 := 0;
    signal jmp_target_fetch_next   : integer range 0 to 255 := 0;
    signal chk2_dbg_captured    : std_logic := '0';
    signal chk2_dbg_a0          : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_a2          : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_d7          : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_a7          : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_regqa       : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_mreg        : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_mdelta      : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_dread       : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_dwt         : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_addr        : std_logic_vector(31 downto 0) := (others => '0');
    signal chk2_dbg_din         : std_logic_vector(15 downto 0) := (others => '0');

    constant CLK_PERIOD      : time := 10 ns;
    constant LOW_IMAGE_FILE  : string := "data/cputest_basic_lmem.mem";
    constant IMAGE_FILE      : string := "data/cputest_basic_sparse.mem";
    constant LOW_BASE        : integer := 16#00000000#;
    constant LOW_BYTES       : integer := 16#00008000#;
    constant HIGH0_BASE      : integer := 16#42000000#;
    constant HIGH0_BYTES     : integer := 16#00001000#;
    constant OPC_BASE        : integer := 16#42050000#;
    constant OPC_BYTES       : integer := 16#00001000#;
    constant HIGH1_BASE      : integer := 16#4204FE00#;
    constant HIGH1_BYTES     : integer := 16#00000280#;
    constant HIGH2_BASE      : integer := 16#42006900#;
    constant HIGH2_BYTES     : integer := 16#00000580#;
    constant BOOT_BASE       : integer := 16#43000000#;
    constant BOOT_BYTES      : integer := 16#00001000#;
    constant BOOT_PC         : integer := BOOT_BASE;
    constant BOOT_STACK      : integer := BOOT_BASE + BOOT_BYTES - 16#40#;
    constant ISP_VALUE       : integer := 16#420007C0#;
    constant MSP_VALUE       : integer := 16#42000840#;
    constant CHK_USP_VALUE   : integer := 16#42000400#;
    constant JMP_USP_VALUE   : integer := 16#420003FE#;
    constant CHK_FRAME_START : integer := ISP_VALUE - 8;
    constant JMP_FRAME_START : integer := ISP_VALUE - 8;
    constant JMP_STAGE1_FRAME_START : integer := ISP_VALUE - 8;
    constant JMP_STAGE2_FRAME_START : integer := ISP_VALUE - 24;
    constant JMP_STAGE3_FRAME_START : integer := ISP_VALUE - 40;
    constant TRACE_VEC_ADDR  : integer := 16#00001900#;
    constant EXC4_VEC_ADDR   : integer := 16#000018A0#;
    constant EXC6_VEC_ADDR   : integer := 16#000018C0#;
    constant EXC11_VEC_ADDR  : integer := 16#00001940#;
    constant EXC11_CHAIN3_ADDR : integer := 16#00001960#;
    constant TRACE_VEC_JSR_ENTRY_ADDR : integer := 16#00001880#;
    constant EXC6_VEC_JSR_ENTRY_ADDR  : integer := 16#00001888#;
    constant EXC11_VEC_JSR_ENTRY_ADDR : integer := 16#00001890#;
    constant RESULT_TRACE_SP : integer := 16#42000F00#;
    constant RESULT_EXC4_SP  : integer := 16#42000F04#;
    constant RESULT_EXC6_SP  : integer := 16#42000F08#;
    constant RESULT_EXC11_SP : integer := 16#42000F0C#;
    constant RESULT_NOEXC_CCR : integer := 16#42000F20#;
    constant JMP_STAGE2_PC   : integer := BOOT_BASE + 16#0400#;
    constant JMP_STAGE3_PC   : integer := BOOT_BASE + 16#0800#;
    constant CPUTEST020_VBR_BASE         : integer := BOOT_BASE + 16#0B00#;
    constant CPUTEST020_TABLE_BASE       : integer := BOOT_BASE + 16#0D00#;
    constant CPUTEST020_DEFAULT_HANDLER  : integer := BOOT_BASE + 16#0C90#;
    constant CPUTEST020_EXC4_HANDLER     : integer := BOOT_BASE + 16#0CA4#;
    constant CPUTEST020_EXC6_HANDLER     : integer := BOOT_BASE + 16#0CB8#;
    constant CPUTEST020_TRACE_HANDLER    : integer := BOOT_BASE + 16#0CCC#;
    constant CPUTEST020_EXC11_HANDLER    : integer := BOOT_BASE + 16#0CD8#;
    constant CPUTEST020_CHK_ENTRY_PC     : integer := BOOT_BASE + 16#0100#;
    constant CPUTEST020_JMP_ENTRY_PC     : integer := BOOT_BASE + 16#0200#;
    constant CPUTEST020_HARNESS_RETURN_SP : integer := BOOT_STACK - 4;

    type low_mem_t is array (0 to LOW_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high0_mem_t is array (0 to HIGH0_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type opc_mem_t is array (0 to OPC_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high1_mem_t is array (0 to HIGH1_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high2_mem_t is array (0 to HIGH2_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type boot_mem_t is array (0 to BOOT_BYTES / 2 - 1) of std_logic_vector(15 downto 0);

    shared variable low_mem   : low_mem_t;
    shared variable high0_mem : high0_mem_t;
    shared variable opc_mem   : opc_mem_t;
    shared variable high1_mem : high1_mem_t;
    shared variable high2_mem : high2_mem_t;
    shared variable boot_mem  : boot_mem_t;

    function high2_word_index(addr : std_logic_vector(31 downto 0)) return integer is
    begin
        return (to_integer(unsigned(addr)) - HIGH2_BASE) / 2;
    end function;

    impure function mem_read_word_now(addr : integer) return std_logic_vector is
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
        elsif addr >= BOOT_BASE and addr < BOOT_BASE + BOOT_BYTES then
            idx := (addr - BOOT_BASE) / 2;
            return boot_mem(idx);
        end if;
        return x"4E71";
    end function;

    impure function mem_read_long_now(addr : integer) return std_logic_vector is
    begin
        return mem_read_word_now(addr) & mem_read_word_now(addr + 2);
    end function;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    waitstate_gen: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' or timing_select = 0 then
                mem_wait <= '0';
            elsif clkena_in = '1' then
                mem_wait <= '1';
            else
                mem_wait <= '0';
            end if;
        end if;
    end process;

    clkena_in <= '0' when timing_select /= 0 and mem_wait = '1' else '1';

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
            debug_setopcode => dbg_setopcode,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_opcode => dbg_opcode,
            debug_state => dbg_state,
            debug_setstate => dbg_setstate,
            debug_last_opc_read => dbg_last_opc_read,
            debug_data_read => dbg_data_read,
            debug_direct_data => dbg_direct_data,
            debug_setnextpass => open,
            debug_TG68_PC => dbg_TG68_PC,
            debug_memaddr_reg => dbg_memaddr_reg,
            debug_memaddr_delta => dbg_memaddr_delta,
            debug_oddout => open,
            debug_decodeOPC => open,
            debug_brief => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw => open,
            debug_regfile_d0 => dbg_regfile_d0,
            debug_regfile_a0 => dbg_regfile_a0,
            debug_fline_context_valid => open,
            debug_trap_1111 => open,
            debug_trapmake => open,
            debug_pmmu_brief => open,
            debug_use_base => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA => dbg_reg_QA,
            debug_last_data_read => dbg_last_data_read,
            debug_last_opc_pc => open,
            debug_getbrief => open,
            debug_get_2ndopc => open,
            debug_fline_brief_pending => open,
            debug_fline_opcode_pc => open,
            debug_exe_PC => dbg_exe_PC,
            debug_memaddr_delta_rega => open,
            debug_memaddr_delta_regb => open,
            debug_addsub_q => open,
            debug_memmaskmux => dbg_memmaskmux,
            debug_fline_opcode_latch => open,
            debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open,
            debug_exec_directPC => open,
            debug_exec_mem_addsub => open,
            debug_set_addrlong => open,
            debug_mdelta_src => open,
            debug_pc_brw => dbg_pc_brw,
            debug_pc_word => dbg_pc_word,
            debug_regfile_d1 => open,
            debug_regfile_d2 => open,
            debug_regfile_d3 => open,
            debug_regfile_d4 => open,
            debug_regfile_d5 => open,
            debug_regfile_d6 => open,
            debug_regfile_d7 => dbg_regfile_d7,
            debug_regfile_a1 => open,
            debug_regfile_a2 => dbg_regfile_a2,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
            debug_regfile_a6 => open,
            debug_regfile_a7 => dbg_regfile_a7,
            debug_regfile_we => open,
            debug_regfile_waddr => open,
            debug_regfile_wdata => open,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => open,
            debug_trap_berr => open,
            debug_trap_mmu_berr => open,
            debug_trap_vector => open,
            debug_pc_add => dbg_pc_add,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy => open,
            debug_cpu_halted => open,
            debug_stop => open,
            debug_interrupt => open,
            debug_setendOPC => open,
            debug_IPL_nr => open,
            debug_micro_state => dbg_micro_state,
            debug_next_micro_state => dbg_next_micro_state,
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
            debug_pmmu_tc => open,
            debug_pmmu_tt0 => open,
            debug_pmmu_tt1 => open,
            debug_pmmu_crp_hi => open,
            debug_pmmu_crp_lo => open,
            debug_pmmu_srp_hi => open,
            debug_pmmu_srp_lo => open,
            debug_pmmu_wstate => open,
            debug_pmmu_atc_buserr => open,
            debug_pmmu_atc_valid => open,
            debug_pmmu_fault_status => open,
            debug_pmmu_saved_addr => open,
            debug_pmmu_walk_desc_addr => open,
            debug_pmmu_walk_desc_data => open,
            debug_pmmu_ptr1_desc_addr => open,
            debug_pmmu_ptr1_desc_data => open,
            debug_pmmu_ptr2_desc_addr => open,
            debug_pmmu_ptr2_desc_data => open,
            debug_pmmu_ptr3_desc_addr => open,
            debug_pmmu_ptr3_desc_data => open,
            debug_pmmu_saved_fc => open,
            debug_make_trace => open,
            debug_trace_pending_grp2 => open,
            debug_useStackframe2 => dbg_use_stackframe2,
            debug_exec_trap_chk => open,
            debug_set_trap_chk => open,
            debug_data_write_tmp => dbg_data_write_tmp,
            debug_FlagsSR => dbg_FlagsSR
        );

    data_in <= low_mem(to_integer(unsigned(addr_out(14 downto 1))))
               when addr_out(31 downto 0) < x"00008000" else
               high0_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"42000" else
               opc_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"42050" else
               high1_mem(to_integer(unsigned(addr_out(8 downto 1))))
               when addr_out(31 downto 9) = std_logic_vector(to_unsigned(HIGH1_BASE / 16#200#, 23)) else
               high2_mem(high2_word_index(addr_out))
               when addr_out(31 downto 11) = std_logic_vector(to_unsigned(HIGH2_BASE / 16#800#, 21)) else
               boot_mem(to_integer(unsigned(addr_out(11 downto 1))))
               when addr_out(31 downto 12) = x"43000" else
               x"4E71";

    mem_write: process(clk)
        variable addr_i       : integer;
        variable idx          : integer;
        variable trace_sp_slv : std_logic_vector(31 downto 0);
        variable trace_sp_int : integer;
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                trace_handler_seen <= '0';
                first_trace_frame_valid <= '0';
            elsif busstate = "10" then
                addr_i := to_integer(unsigned(addr_out));
                if addr_i >= 16#0000008A# and addr_i < 16#0000008E# then
                    report "LOW_JMP_RD: addr=$" & to_hstring(addr_out) &
                           " din=$" & to_hstring(data_in) &
                           " opcode=$" & to_hstring(dbg_opcode) &
                           " lastopc=$" & to_hstring(dbg_last_opc_read) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) severity note;
                end if;
                if addr_i >= 16#4204FEFE# and addr_i < 16#4204FF00# then
                    report "HIGH1_JMP_RD: addr=$" & to_hstring(addr_out) &
                           " din=$" & to_hstring(data_in) &
                           " opcode=$" & to_hstring(dbg_opcode) &
                           " lastopc=$" & to_hstring(dbg_last_opc_read) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) severity note;
                end if;
            elsif busstate = "11" and nWr = '0' and clkena_in = '1' then
                addr_i := to_integer(unsigned(addr_out));
                if dbg_micro_state = 56 and first_trace_frame_valid = '0' and
                   addr_i >= ISP_VALUE - 16#0100# and addr_i < MSP_VALUE + 16#0100# then
                    first_trace_frame_sr <= data_write;
                    first_trace_frame_pc <= mem_read_long_now(addr_i + 2);
                    first_trace_frame_fv <= mem_read_word_now(addr_i + 6);
                    first_trace_frame_ia <= mem_read_long_now(addr_i + 8);
                    first_trace_frame_valid <= '1';
                end if;
                if addr_i = RESULT_TRACE_SP then
                    trace_handler_seen <= '1';
                end if;
                if addr_i = RESULT_TRACE_SP + 2 and first_trace_frame_valid = '0' then
                    trace_sp_slv := mem_read_word_now(RESULT_TRACE_SP) & data_write;
                    if trace_sp_slv(31 downto 16) /= x"0000" and trace_sp_slv(15 downto 0) /= x"0000" then
                        trace_sp_int := to_integer(unsigned(trace_sp_slv));
                        first_trace_frame_sr <= mem_read_word_now(trace_sp_int);
                        first_trace_frame_pc <= mem_read_long_now(trace_sp_int + 2);
                        first_trace_frame_fv <= mem_read_word_now(trace_sp_int + 6);
                        first_trace_frame_ia <= mem_read_long_now(trace_sp_int + 8);
                        first_trace_frame_valid <= '1';
                    end if;
                end if;
                if addr_i >= 16#0000008A# and addr_i < 16#0000008E# then
                    report "LOW_JMP_WR: addr=$" & to_hstring(addr_out) &
                           " data=$" & to_hstring(data_write) &
                           " uds=" & std_logic'image(nUDS) &
                           " lds=" & std_logic'image(nLDS) &
                           " opcode=$" & to_hstring(dbg_opcode) &
                           " lastopc=$" & to_hstring(dbg_last_opc_read) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) severity note;
                end if;
                if addr_i >= 16#4204FEFE# and addr_i < 16#4204FF00# then
                    report "HIGH1_JMP_WR: addr=$" & to_hstring(addr_out) &
                           " data=$" & to_hstring(data_write) &
                           " uds=" & std_logic'image(nUDS) &
                           " lds=" & std_logic'image(nLDS) &
                           " opcode=$" & to_hstring(dbg_opcode) &
                           " lastopc=$" & to_hstring(dbg_last_opc_read) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) severity note;
                end if;
                if addr_i >= 16#42006D70# and addr_i < 16#42006E74# then
                    report "TARGET_MEM_WR: addr=$" & to_hstring(addr_out) &
                           " data=$" & to_hstring(data_write) &
                           " uds=" & std_logic'image(nUDS) &
                           " lds=" & std_logic'image(nLDS) severity note;
                end if;
                if addr_i >= 16#420007B0# and addr_i < 16#420007C2# then
                    report "TRACE_STACK_WR: addr=$" & to_hstring(addr_out) &
                           " data=$" & to_hstring(data_write) &
                           " uds=" & std_logic'image(nUDS) &
                           " lds=" & std_logic'image(nLDS) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) &
                           " use2=" & std_logic'image(dbg_use_stackframe2) &
                           " dwt=$" & to_hstring(dbg_data_write_tmp) severity note;
                end if;
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

    chk2_capture: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                chk2_dbg_captured <= '0';
            elsif dbg_opcode /= x"00D0" and dbg_opcode /= x"00D1" and dbg_opcode /= x"00D7" and dbg_opcode /= x"00E8" and dbg_opcode /= x"00F3" and
                  dbg_opcode /= x"02D0" and dbg_opcode /= x"02E8" and dbg_opcode /= x"02F5" and
                  dbg_opcode /= x"04D0" and dbg_opcode /= x"04E8" and dbg_opcode /= x"04F0" then
                chk2_dbg_captured <= '0';
            elsif dbg_micro_state = 70 and chk2_dbg_captured = '0' then
                chk2_dbg_captured <= '1';
                chk2_dbg_a0 <= dbg_regfile_a0;
                chk2_dbg_a2 <= dbg_regfile_a2;
                chk2_dbg_d7 <= dbg_regfile_d7;
                chk2_dbg_a7 <= dbg_regfile_a7;
                chk2_dbg_regqa <= dbg_reg_QA;
                chk2_dbg_mreg <= dbg_memaddr_reg;
                chk2_dbg_mdelta <= dbg_memaddr_delta;
                chk2_dbg_dread <= dbg_data_read;
                chk2_dbg_dwt <= dbg_data_write_tmp;
                chk2_dbg_addr <= addr_out;
                chk2_dbg_din <= data_in;
                report "CHK2CAP opc=$" & to_hstring(dbg_opcode) &
                       " a0=$" & to_hstring(dbg_regfile_a0) &
                       " d0=$" & to_hstring(dbg_regfile_d0) &
                       " a2=$" & to_hstring(dbg_regfile_a2) &
                       " d7=$" & to_hstring(dbg_regfile_d7) &
                       " a7=$" & to_hstring(dbg_regfile_a7) &
                       " regqa=$" & to_hstring(dbg_reg_QA) &
                       " mreg=$" & to_hstring(dbg_memaddr_reg) &
                       " mdelta=$" & to_hstring(dbg_memaddr_delta) &
                       " dread=$" & to_hstring(dbg_data_read) &
                       " ldread=$" & to_hstring(dbg_last_data_read) &
                       " mmux=$" & to_hstring(dbg_memmaskmux) &
                       " dir=" & std_logic'image(dbg_direct_data) &
                       " ea=$" & to_hstring(dbg_ea_data) &
                       " op2=$" & to_hstring(dbg_op2out) &
                       " st=" & std_logic'image(dbg_state(1)) & std_logic'image(dbg_state(0)) &
                       " nst=" & std_logic'image(dbg_setstate(1)) & std_logic'image(dbg_setstate(0)) &
                       " dwt=$" & to_hstring(dbg_data_write_tmp) &
                       " addr=$" & to_hstring(addr_out) &
                       " din=$" & to_hstring(data_in) severity note;
            end if;
        end if;
    end process;

    chk2_bus_trace: process(clk)
    begin
        if rising_edge(clk) then
            if (dbg_opcode = x"00D0" or dbg_opcode = x"00D1" or dbg_opcode = x"00D7" or dbg_opcode = x"00E8" or dbg_opcode = x"00F3" or
                dbg_opcode = x"02D0" or dbg_opcode = x"02E8" or dbg_opcode = x"02F5" or
                dbg_opcode = x"04D0" or dbg_opcode = x"04E8" or dbg_opcode = x"04F0") and
               (dbg_micro_state = 66 or dbg_micro_state = 67 or dbg_micro_state = 68 or
                dbg_next_micro_state = 66 or dbg_next_micro_state = 67 or dbg_next_micro_state = 68) and
               nWr = '1' and (nUDS = '0' or nLDS = '0') then
                report "CHK2BUS opc=$" & to_hstring(dbg_opcode) &
                       " micro=" & integer'image(dbg_micro_state) &
                       " next=" & integer'image(dbg_next_micro_state) &
                       " addr=$" & to_hstring(addr_out) &
                       " din=$" & to_hstring(data_in) &
                       " a0=$" & to_hstring(dbg_regfile_a0) &
                       " d0=$" & to_hstring(dbg_regfile_d0) &
                       " a2=$" & to_hstring(dbg_regfile_a2) &
                       " d7=$" & to_hstring(dbg_regfile_d7) &
                       " regqa=$" & to_hstring(dbg_reg_QA) &
                       " mreg=$" & to_hstring(dbg_memaddr_reg) &
                       " mdelta=$" & to_hstring(dbg_memaddr_delta) &
                       " dread=$" & to_hstring(dbg_data_read) &
                       " ldread=$" & to_hstring(dbg_last_data_read) &
                       " mmux=$" & to_hstring(dbg_memmaskmux) &
                       " dir=" & std_logic'image(dbg_direct_data) &
                       " ea=$" & to_hstring(dbg_ea_data) &
                       " op2=$" & to_hstring(dbg_op2out) &
                       " st=" & std_logic'image(dbg_state(1)) & std_logic'image(dbg_state(0)) &
                       " nst=" & std_logic'image(dbg_setstate(1)) & std_logic'image(dbg_setstate(0)) &
                       " dwt=$" & to_hstring(dbg_data_write_tmp) severity note;
            end if;
        end if;
    end process;

    jmp_posttrace_probe: process(clk)
        variable addr_i : integer;
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                jmp_posttrace_fetches <= 0;
            elsif trace_handler_seen = '1' and busstate = "00" and FC(1 downto 0) = "10" then
                addr_i := to_integer(unsigned(addr_out));
                if jmp_posttrace_fetches < 12 then
                    report "POSTTRACE_FETCH: addr=$" & to_hstring(addr_out) &
                           " din=$" & to_hstring(data_in) &
                           " opcode=$" & to_hstring(dbg_opcode) &
                           " setopc=" & std_logic'image(dbg_setopcode) &
                           " lastopc=$" & to_hstring(dbg_last_opc_read) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) severity note;
                    jmp_posttrace_fetches <= jmp_posttrace_fetches + 1;
                end if;
            end if;
        end if;
    end process;

    jmp_probe: process(clk)
        variable addr_u : unsigned(31 downto 0);
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                jmp_fetch_seen <= '0';
                jmp_target_captured <= '0';
                jmp_target_fetch_addr <= (others => '0');
                jmp_target_fetch_opcode <= (others => '0');
                jmp_target_fetch_a7 <= (others => '0');
                jmp_target_fetch_regqa <= (others => '0');
                jmp_target_fetch_mreg <= (others => '0');
                jmp_target_fetch_mdelta <= (others => '0');
                jmp_target_fetch_sr <= (others => '0');
                jmp_target_fetch_tg68pc <= (others => '0');
                jmp_target_fetch_pcadd <= (others => '0');
                jmp_target_fetch_pcbrw <= '0';
                jmp_target_fetch_pcword <= '0';
                jmp_target_fetch_exepc <= (others => '0');
                jmp_target_fetch_dataread <= (others => '0');
                jmp_target_fetch_lastopc <= (others => '0');
                jmp_target_fetch_micro <= 0;
                jmp_target_fetch_next <= 0;
            elsif busstate = "00" and FC(1 downto 0) = "10" then
                addr_u := unsigned(addr_out);
                if addr_out = x"42050000" then
                    jmp_fetch_seen <= '1';
                elsif jmp_fetch_seen = '1' and jmp_target_captured = '0' and
                      (addr_u < unsigned'(x"42050000") or addr_u >= unsigned'(x"42050008")) then
                    jmp_target_captured <= '1';
                    jmp_target_fetch_addr <= addr_out;
                    jmp_target_fetch_opcode <= data_in;
                    jmp_target_fetch_a7 <= dbg_regfile_a7;
                    jmp_target_fetch_regqa <= dbg_reg_QA;
                    jmp_target_fetch_mreg <= dbg_memaddr_reg;
                    jmp_target_fetch_mdelta <= dbg_memaddr_delta;
                    jmp_target_fetch_sr <= dbg_FlagsSR;
                    jmp_target_fetch_tg68pc <= dbg_TG68_PC;
                    jmp_target_fetch_pcadd <= dbg_pc_add;
                    jmp_target_fetch_pcbrw <= dbg_pc_brw;
                    jmp_target_fetch_pcword <= dbg_pc_word;
                    jmp_target_fetch_exepc <= dbg_exe_PC;
                    jmp_target_fetch_dataread <= dbg_data_read;
                    jmp_target_fetch_lastopc <= dbg_last_opc_read(15 downto 0);
                    jmp_target_fetch_micro <= dbg_micro_state;
                    jmp_target_fetch_next <= dbg_next_micro_state;
                    report "JMP_FETCH_CAPTURE: addr=$" & to_hstring(addr_out) &
                           " din=$" & to_hstring(data_in) &
                           " dbg_data_read=$" & to_hstring(dbg_data_read) &
                           " dbg_last_opc=$" & to_hstring(dbg_last_opc_read(15 downto 0)) &
                           " dbg_opcode=$" & to_hstring(dbg_opcode) &
                           " a7=$" & to_hstring(dbg_regfile_a7) &
                           " regqa=$" & to_hstring(dbg_reg_QA) &
                           " srh=$" & to_hstring(dbg_FlagsSR) severity note;
                    report "JMP_FETCH_PC: pc=$" & to_hstring(dbg_TG68_PC) &
                           " pc_add=$" & to_hstring(dbg_pc_add) &
                           " pc_brw=" & std_logic'image(dbg_pc_brw) &
                           " pc_word=" & std_logic'image(dbg_pc_word) &
                           " memdelta=$" & to_hstring(dbg_memaddr_delta) severity note;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable saved_reset_ssp : std_logic_vector(31 downto 0) := (others => '0');
        variable saved_reset_pc  : std_logic_vector(31 downto 0) := (others => '0');

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

        function sr_from_extraccr(extraccr : integer) return std_logic_vector is
            variable sr_mask : integer := 0;
        begin
            if (extraccr mod 2) = 1 then
                sr_mask := sr_mask + 16#2000#;
            end if;
            if ((extraccr / 2) mod 2) = 1 then
                sr_mask := sr_mask + 16#4000#;
            end if;
            if ((extraccr / 4) mod 2) = 1 then
                sr_mask := sr_mask + 16#8000#;
            end if;
            if ((extraccr / 8) mod 2) = 1 then
                sr_mask := sr_mask + 16#1000#;
            end if;
            return std_logic_vector(to_unsigned(sr_mask, 16));
        end function;

        function sr_from_cputest_group(ccrmode : integer;
                                       ccr     : integer;
                                       extraccr : integer) return std_logic_vector is
            variable maxccr : integer := ccrmode mod 64;
            variable sr_val : integer := 0;
        begin
            if maxccr >= 32 then
                sr_val := ccr mod 256;
            elsif (ccr mod 2) = 1 then
                sr_val := 16#1F#;
            end if;
            sr_val := sr_val + to_integer(unsigned(sr_from_extraccr(extraccr)));
            return std_logic_vector(to_unsigned(sr_val, 16));
        end function;

        function stack_mark_valid(mark : std_logic_vector(31 downto 0)) return boolean is
            variable mark_i : integer;
        begin
            if mark = x"00000000" then
                return false;
            end if;
            mark_i := to_integer(unsigned(mark));
            return (mark_i >= ISP_VALUE - 16#0100#) and (mark_i < MSP_VALUE + 16#0100#);
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

        procedure write_byte(addr : integer; value : std_logic_vector(7 downto 0)) is
            variable word_addr : integer;
            variable idx       : integer;
            variable word_val  : std_logic_vector(15 downto 0);
        begin
            word_addr := addr - (addr mod 2);
            if word_addr >= LOW_BASE and word_addr < LOW_BASE + LOW_BYTES then
                idx := (word_addr - LOW_BASE) / 2;
                word_val := low_mem(idx);
            elsif word_addr >= HIGH0_BASE and word_addr < HIGH0_BASE + HIGH0_BYTES then
                idx := (word_addr - HIGH0_BASE) / 2;
                word_val := high0_mem(idx);
            elsif word_addr >= OPC_BASE and word_addr < OPC_BASE + OPC_BYTES then
                idx := (word_addr - OPC_BASE) / 2;
                word_val := opc_mem(idx);
            elsif word_addr >= HIGH1_BASE and word_addr < HIGH1_BASE + HIGH1_BYTES then
                idx := (word_addr - HIGH1_BASE) / 2;
                word_val := high1_mem(idx);
            elsif word_addr >= HIGH2_BASE and word_addr < HIGH2_BASE + HIGH2_BYTES then
                idx := (word_addr - HIGH2_BASE) / 2;
                word_val := high2_mem(idx);
            elsif word_addr >= BOOT_BASE and word_addr < BOOT_BASE + BOOT_BYTES then
                idx := (word_addr - BOOT_BASE) / 2;
                word_val := boot_mem(idx);
            else
                return;
            end if;

            if (addr mod 2) = 0 then
                write_word(word_addr, value & word_val(7 downto 0));
            else
                write_word(word_addr, word_val(15 downto 8) & value);
            end if;
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
            for i in boot_mem'range loop
                boot_mem(i) := x"0000";
            end loop;
        end procedure;

        procedure load_word_image(filename : string) is
            file f           : text;
            variable l       : line;
            variable addr_sl : std_logic_vector(31 downto 0);
            variable word_sl : std_logic_vector(15 downto 0);
        begin
            file_open(f, filename, read_mode);
            while not endfile(f) loop
                readline(f, l);
                hread(l, addr_sl);
                hread(l, word_sl);
                write_word(to_integer(unsigned(addr_sl)), word_sl);
            end loop;
            file_close(f);
        end procedure;

        procedure load_sparse_image is
        begin
            clear_regions;
            load_word_image(LOW_IMAGE_FILE);
            load_word_image(IMAGE_FILE);
        end procedure;

        procedure install_trace_stub is
        begin
            write_long(16#24#, x"00001900");
            write_word(TRACE_VEC_ADDR, x"23CF");
            write_word(TRACE_VEC_ADDR + 2, x"4200");
            write_word(TRACE_VEC_ADDR + 4, x"0F00");
            write_word(TRACE_VEC_ADDR + 6, x"4E73");
        end procedure;

        procedure install_trace_jsr_stub is
        begin
            write_long(16#24#, std_logic_vector(to_unsigned(TRACE_VEC_JSR_ENTRY_ADDR, 32)));
            write_word(TRACE_VEC_JSR_ENTRY_ADDR, x"4EB9");
            write_long(TRACE_VEC_JSR_ENTRY_ADDR + 2, std_logic_vector(to_unsigned(TRACE_VEC_ADDR, 32)));

            write_word(TRACE_VEC_ADDR, x"40E7");
            write_word(TRACE_VEC_ADDR + 2, x"4FEF");
            write_word(TRACE_VEC_ADDR + 4, x"0006");
            write_word(TRACE_VEC_ADDR + 6, x"23CF");
            write_word(TRACE_VEC_ADDR + 8, x"4200");
            write_word(TRACE_VEC_ADDR + 10, x"0F00");
            write_word(TRACE_VEC_ADDR + 12, x"4E73");
        end procedure;

        procedure install_exc_stub(vector_num : integer;
                                   stub_addr  : integer;
                                   result_addr : integer) is
            variable vector_addr : integer;
        begin
            vector_addr := vector_num * 4;
            write_long(vector_addr, std_logic_vector(to_unsigned(stub_addr, 32)));
            write_word(stub_addr, x"23CF");
            write_word(stub_addr + 2, x"4200");
            write_word(stub_addr + 4, std_logic_vector(to_unsigned(result_addr mod 16#10000#, 16)));
            write_word(stub_addr + 6, x"4E72");
            write_word(stub_addr + 8, x"2700");
        end procedure;

        procedure install_exc_jsr_stub(vector_num  : integer;
                                       entry_addr  : integer;
                                       stub_addr   : integer;
                                       result_addr : integer) is
            variable vector_addr : integer;
        begin
            vector_addr := vector_num * 4;
            write_long(vector_addr, std_logic_vector(to_unsigned(entry_addr, 32)));
            write_word(entry_addr, x"4EB9");
            write_long(entry_addr + 2, std_logic_vector(to_unsigned(stub_addr, 32)));

            write_word(stub_addr, x"40E7");
            write_word(stub_addr + 2, x"4FEF");
            write_word(stub_addr + 4, x"0006");
            write_word(stub_addr + 6, x"23CF");
            write_word(stub_addr + 8, x"4200");
            write_word(stub_addr + 10, std_logic_vector(to_unsigned(result_addr mod 16#10000#, 16)));
            write_word(stub_addr + 12, x"4E72");
            write_word(stub_addr + 14, x"2700");
        end procedure;

        procedure install_exc_chain_stub(vector_num : integer;
                                         stub_addr  : integer;
                                         next_pc    : integer;
                                         do_stop    : boolean;
                                         result_addr : integer;
                                         restore_sr : std_logic_vector(15 downto 0)) is
            variable vector_addr : integer;
            variable pc          : integer;
        begin
            vector_addr := vector_num * 4;
            write_long(vector_addr, std_logic_vector(to_unsigned(stub_addr, 32)));
            pc := stub_addr;
            write_word(pc, x"23CF");
            pc := pc + 2;
            write_long(pc, std_logic_vector(to_unsigned(result_addr, 32)));
            pc := pc + 4;
            if do_stop then
                write_word(pc, x"4E72");
                write_word(pc + 2, x"2700");
            else
                write_word(pc, x"46FC");
                write_word(pc + 2, restore_sr);
                pc := pc + 4;
                write_word(pc, x"4EF9");
                write_long(pc + 2, std_logic_vector(to_unsigned(next_pc, 32)));
            end if;
        end procedure;

        procedure set_reset_vectors is
        begin
            write_long(16#0#, std_logic_vector(to_unsigned(BOOT_STACK, 32)));
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

        procedure emit_jmp_abs(pc : inout integer; value : integer) is
        begin
            emit_word(pc, x"4EF9");
            emit_long(pc, std_logic_vector(to_unsigned(value, 32)));
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

        procedure emit_jsr_abs(pc : inout integer; value : integer) is
        begin
            emit_word(pc, x"4EB9");
            emit_long(pc, std_logic_vector(to_unsigned(value, 32)));
        end procedure;

        procedure emit_movec_reg_to_ctrl(pc : inout integer;
                                         regsel : integer;
                                         ctrlsel : integer) is
        begin
            emit_word(pc, x"4E7B");
            emit_word(pc, std_logic_vector(to_unsigned(regsel * 16#1000# + ctrlsel, 16)));
        end procedure;

        procedure emit_movea_imm_an(pc : inout integer; regnum : integer; value : integer) is
        begin
            emit_word(pc, std_logic_vector(to_unsigned(16#207C# + regnum * 16#0200#, 16)));
            emit_long(pc, std_logic_vector(to_signed(value, 32)));
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
                report "BSR.S target out of range in exact BASIC cputest harness" severity failure;
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

        procedure install_cputest020_trace_handler is
            variable pc : integer := CPUTEST020_TRACE_HANDLER;
        begin
            emit_word(pc, x"4FEF");
            emit_word(pc, x"0004");
            emit_word(pc, x"23CF");
            emit_long(pc, std_logic_vector(to_unsigned(RESULT_TRACE_SP, 32)));
            emit_word(pc, x"4E73");
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
                    when 6 =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(entry_addr, 32)));
                        write_bsr_s(entry_addr, CPUTEST020_EXC6_HANDLER);
                    when 8 =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(entry_addr, 32)));
                        write_bsr_s(entry_addr, CPUTEST020_DEFAULT_HANDLER);
                    when 9 =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(entry_addr, 32)));
                        write_bsr_s(entry_addr, CPUTEST020_TRACE_HANDLER);
                    when 11 =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(entry_addr, 32)));
                        write_bsr_s(entry_addr, CPUTEST020_EXC11_HANDLER);
                    when others =>
                        write_long(CPUTEST020_VBR_BASE + vector * 4,
                                   std_logic_vector(to_unsigned(CPUTEST020_DEFAULT_HANDLER, 32)));
                end case;
            end loop;

            install_cputest020_handler(CPUTEST020_DEFAULT_HANDLER, RESULT_EXC4_SP);
            install_cputest020_handler(CPUTEST020_EXC4_HANDLER, RESULT_EXC4_SP);
            install_cputest020_handler(CPUTEST020_EXC6_HANDLER, RESULT_EXC6_SP);
            install_cputest020_trace_handler;
            install_cputest020_handler(CPUTEST020_EXC11_HANDLER, RESULT_EXC11_SP);
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
                                    ext_word    : std_logic_vector(15 downto 0);
                                    d0_value    : integer;
                                    sr_value    : std_logic_vector(15 downto 0)) is
            variable pc : integer := BOOT_PC;
        begin
            build_common_boot(pc, CHK_USP_VALUE, CHK_FRAME_START);
            emit_movel_imm_dn(pc, 0, d0_value);
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
            write_word(16#42050002#, ext_word);
            -- The BASIC packed records do not execute into a fresh STOP tail.
            -- By record 1 / group 4 the opcode area already contains persistent
            -- bytepatches from earlier records in the same mnemonic stream.
            write_word(16#42050004#, x"0000");
            write_word(16#42050006#, x"6100");
            write_word(16#42050008#, x"0000");
            write_word(16#4205000A#, x"A69C");
            write_word(16#4205000C#, x"00A3");
            write_word(16#4205000E#, x"B100");
        end procedure;

        procedure install_jmp_stage_boot(stage_pc    : integer;
                                         frame_start : integer;
                                         sr_value    : std_logic_vector(15 downto 0)) is
            variable pc : integer := stage_pc;
        begin
            build_common_boot(pc, JMP_USP_VALUE, frame_start);
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
            emit_movea_imm_an(pc, 7, frame_start);
            emit_word(pc, x"4E73");

            write_word(frame_start, sr_value);
            write_long(frame_start + 2, x"42050000");
            write_word(frame_start + 6, x"0000");
        end procedure;

        procedure install_jmp_boot(sr_value : std_logic_vector(15 downto 0)) is
        begin
            install_jmp_stage_boot(BOOT_PC, JMP_FRAME_START, sr_value);

            -- For BASIC, low memory is not restored between records. The sparse
            -- image already contains the live low-memory prestate seen by this
            -- record, so only the cumulative opcode/tmem patches need to be
            -- applied here.
            write_word(16#42050000#, x"4EEF");
            write_word(16#42050002#, x"65B2");
            write_word(16#42050004#, x"4F04");
            write_word(16#42050006#, x"6100");
            write_word(16#42050008#, x"0000");
            write_word(16#4205000A#, x"A69C");
            write_word(16#4205000C#, x"00A3");
            write_word(16#4205000E#, x"B100");
            write_word(16#4204FEF8#, x"FF00");
            write_word(16#4204FEFA#, x"0000");
            write_word(16#4204FEFC#, x"B200");
            write_word(16#4204FEFE#, x"0010");
        end procedure;

        procedure install_chk2_cputest020_boot(opcode_word : std_logic_vector(15 downto 0);
                                               ext_word    : std_logic_vector(15 downto 0);
                                               d0_value    : integer;
                                               sr_value    : std_logic_vector(15 downto 0)) is
            variable pc : integer := CPUTEST020_CHK_ENTRY_PC;
        begin
            install_cputest020_boot(CPUTEST020_CHK_ENTRY_PC);
            build_common_boot(pc, CHK_USP_VALUE, CHK_FRAME_START);
            emit_movel_imm_dn(pc, 0, d0_value);
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
            write_word(16#42050002#, ext_word);
            write_word(16#42050004#, x"0000");
            write_word(16#42050006#, x"6100");
            write_word(16#42050008#, x"0000");
            write_word(16#4205000A#, x"A69C");
            write_word(16#4205000C#, x"00A3");
            write_word(16#4205000E#, x"B100");
        end procedure;

        procedure install_chk2_cputest020_record_boot(sr_value    : std_logic_vector(15 downto 0);
                                                      endpc_value : integer;
                                                      d0_value    : integer;
                                                      d2_value    : integer;
                                                      d3_value    : integer;
                                                      d4_value    : integer;
                                                      d5_value    : integer;
                                                      d6_value    : integer;
                                                      d7_value    : integer;
                                                      a1_value    : integer;
                                                      a2_value    : integer;
                                                      a3_value    : integer;
                                                      a4_value    : integer;
                                                      a5_value    : integer;
                                                      code0       : integer;
                                                      code2       : integer;
                                                      code4       : integer := -1;
                                                      code6       : integer := -1;
                                                      code8       : integer := -1) is
            variable pc : integer := CPUTEST020_CHK_ENTRY_PC;
        begin
            install_cputest020_boot(CPUTEST020_CHK_ENTRY_PC);
            build_common_boot(pc, CHK_USP_VALUE, CHK_FRAME_START);
            emit_movel_imm_dn(pc, 0, d0_value);
            emit_moveq0_d1(pc);
            emit_movel_imm_dn(pc, 2, d2_value);
            emit_movel_imm_dn(pc, 3, d3_value);
            emit_movel_imm_dn(pc, 4, d4_value);
            emit_movel_imm_dn(pc, 5, d5_value);
            emit_movel_imm_dn(pc, 6, d6_value);
            emit_movel_imm_dn(pc, 7, d7_value);
            emit_movea_imm_an(pc, 1, a1_value);
            emit_movea_imm_an(pc, 2, a2_value);
            emit_movea_imm_an(pc, 3, a3_value);
            emit_movea_imm_an(pc, 4, a4_value);
            emit_movea_imm_an(pc, 5, a5_value);
            emit_movea_imm_an(pc, 6, 16#4204FF00#);
            emit_movea_imm_an(pc, 7, CHK_FRAME_START);
            emit_word(pc, x"4E73");

            write_word(CHK_FRAME_START, sr_value);
            write_long(CHK_FRAME_START + 2, x"42050000");
            write_word(CHK_FRAME_START + 6, x"0000");

            write_word(16#42050000#, std_logic_vector(to_unsigned(code0, 16)));
            write_word(16#42050002#, std_logic_vector(to_unsigned(code2, 16)));
            if code4 >= 0 then
                write_word(16#42050004#, std_logic_vector(to_unsigned(code4, 16)));
            end if;
            if code6 >= 0 then
                write_word(16#42050006#, std_logic_vector(to_unsigned(code6, 16)));
            end if;
            if code8 >= 0 then
                write_word(16#42050008#, std_logic_vector(to_unsigned(code8, 16)));
            end if;

        end procedure;

        procedure install_jmp_cputest020_boot(sr_value : std_logic_vector(15 downto 0)) is
            variable pc : integer := CPUTEST020_JMP_ENTRY_PC;
        begin
            install_cputest020_boot(CPUTEST020_JMP_ENTRY_PC);
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

            write_word(JMP_FRAME_START, sr_value);
            write_long(JMP_FRAME_START + 2, x"42050000");
            write_word(JMP_FRAME_START + 6, x"0000");

            write_word(16#42050000#, x"4EEF");
            write_word(16#42050002#, x"65B2");
            write_word(16#42050004#, x"4F04");
            write_word(16#42050006#, x"6100");
            write_word(16#42050008#, x"0000");
            write_word(16#4205000A#, x"A69C");
            write_word(16#4205000C#, x"00A3");
            write_word(16#4205000E#, x"B100");
            write_word(16#4204FEF8#, x"FF00");
            write_word(16#4204FEFA#, x"0000");
            write_word(16#4204FEFC#, x"B200");
            write_word(16#4204FEFE#, x"0010");
        end procedure;

        procedure install_jmp_cputest020_boot_custom(sr_value     : std_logic_vector(15 downto 0);
                                                     a1_value     : integer;
                                                     opcode_high  : std_logic_vector(15 downto 0);
                                                     opcode_low   : std_logic_vector(15 downto 0)) is
            variable pc : integer := CPUTEST020_JMP_ENTRY_PC;
        begin
            install_cputest020_boot(CPUTEST020_JMP_ENTRY_PC);
            build_common_boot(pc, JMP_USP_VALUE, JMP_FRAME_START);
            emit_movel_imm_dn(pc, 0, 16#000000B2#);
            emit_moveq0_d1(pc);
            emit_movel_imm_dn(pc, 2, 16#FFFFFD7F#);
            emit_movel_imm_dn(pc, 3, 16#0FFFDF70#);
            emit_movel_imm_dn(pc, 4, 16#87FFF0C1#);
            emit_movel_imm_dn(pc, 5, 16#80028282#);
            emit_movel_imm_dn(pc, 6, 16#00080808#);
            emit_movel_imm_dn(pc, 7, 16#AAAAAAAA#);
            emit_movea_imm_an(pc, 1, a1_value);
            emit_movea_imm_an(pc, 2, 16#00008014#);
            emit_movea_imm_an(pc, 3, 16#0000FFFF#);
            emit_movea_imm_an(pc, 4, 16#7FFFFF3A#);
            emit_movea_imm_an(pc, 5, 16#0FFFFFF0#);
            emit_movea_imm_an(pc, 6, 16#4204FEFF#);
            emit_movea_imm_an(pc, 7, JMP_FRAME_START);
            emit_word(pc, x"4E73");

            write_word(JMP_FRAME_START, sr_value);
            write_long(JMP_FRAME_START + 2, x"42050000");
            write_word(JMP_FRAME_START + 6, x"0000");

            write_word(16#42050000#, opcode_high);
            write_word(16#42050002#, opcode_low);
        end procedure;

        procedure install_jmp_cputest020_direct_a7_boot(active_a7 : integer;
                                                        sr_value  : std_logic_vector(15 downto 0)) is
            variable pc : integer := OPC_BASE;
        begin
            install_cputest020_boot(OPC_BASE);
            emit_set_usp_msp(pc, JMP_USP_VALUE);
            emit_movea_imm_an(pc, 0, 0);
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
            emit_word(pc, x"46FC");
            emit_word(pc, sr_value);
            emit_movea_imm_an(pc, 7, active_a7);
            emit_word(pc, x"4EEF");
            emit_word(pc, x"65B2");
            emit_word(pc, x"4E72");
            emit_word(pc, x"2700");
        end procedure;

        procedure install_jmp_cputest020_record16_boot(sr_value : std_logic_vector(15 downto 0)) is
        begin
            install_jmp_cputest020_boot_custom(sr_value, 16#00000088#, x"4EE9", x"0000");
            write_long(16#00000088#, x"4AFC2048");
        end procedure;

        procedure install_jmp_cputest020_record18_boot(sr_value : std_logic_vector(15 downto 0)) is
        begin
            install_jmp_cputest020_boot_custom(sr_value, 16#0000008A#, x"4EE9", x"0000");
            write_word(16#0000008A#, x"4AFC");
            write_word(16#0000008C#, x"2048");
        end procedure;

        procedure install_jmp_chain_boots is
        begin
            install_jmp_stage_boot(BOOT_PC, JMP_STAGE1_FRAME_START, x"2000");
            install_jmp_stage_boot(JMP_STAGE2_PC, JMP_STAGE2_FRAME_START, x"4000");
            install_jmp_stage_boot(JMP_STAGE3_PC, JMP_STAGE3_FRAME_START, x"6000");

            write_word(16#0000008A#, x"4AFC");
            write_word(16#0000008C#, x"2048");
            write_word(16#42050000#, x"4EEF");
            write_word(16#42050002#, x"65B2");
            write_long(16#420069B0#, x"4AFC2048");

            install_exc_chain_stub(11, EXC11_VEC_ADDR, JMP_STAGE2_PC, false, RESULT_EXC11_SP, x"2700");
            install_exc_chain_stub(4, EXC4_VEC_ADDR, JMP_STAGE3_PC, false, RESULT_EXC4_SP, x"2700");
            install_exc_chain_stub(11, EXC11_CHAIN3_ADDR, 0, true, RESULT_EXC11_SP, x"2700");
            write_long(11 * 4, std_logic_vector(to_unsigned(EXC11_VEC_ADDR, 32)));
        end procedure;

        procedure init_common is
        begin
            load_sparse_image;
            saved_reset_ssp := read_long(16#0#);
            saved_reset_pc := read_long(16#4#);
            set_reset_vectors;
            install_trace_stub;
            install_exc_stub(4, EXC4_VEC_ADDR, RESULT_EXC4_SP);
            install_exc_stub(6, EXC6_VEC_ADDR, RESULT_EXC6_SP);
            install_exc_stub(11, EXC11_VEC_ADDR, RESULT_EXC11_SP);
            write_long(RESULT_TRACE_SP, x"00000000");
            write_long(RESULT_EXC4_SP, x"00000000");
            write_long(RESULT_EXC6_SP, x"00000000");
            write_long(RESULT_EXC11_SP, x"00000000");
        end procedure;

        procedure init_common_no_stubs is
        begin
            load_sparse_image;
            saved_reset_ssp := read_long(16#0#);
            saved_reset_pc := read_long(16#4#);
            set_reset_vectors;
            write_long(RESULT_TRACE_SP, x"00000000");
            write_long(RESULT_EXC4_SP, x"00000000");
            write_long(RESULT_EXC6_SP, x"00000000");
            write_long(RESULT_EXC11_SP, x"00000000");
        end procedure;

        procedure init_common_cputest020 is
        begin
            load_sparse_image;
            saved_reset_ssp := read_long(16#0#);
            saved_reset_pc := read_long(16#4#);
            set_reset_vectors;
            install_cputest020_exception_table;
            write_long(RESULT_TRACE_SP, x"00000000");
            write_long(RESULT_EXC4_SP, x"00000000");
            write_long(RESULT_EXC6_SP, x"00000000");
            write_long(RESULT_EXC11_SP, x"00000000");
        end procedure;

        procedure rearm_cputest020 is
        begin
            for i in boot_mem'range loop
                boot_mem(i) := x"0000";
            end loop;
            set_reset_vectors;
            install_cputest020_exception_table;
            write_long(RESULT_TRACE_SP, x"00000000");
            write_long(RESULT_EXC4_SP, x"00000000");
            write_long(RESULT_EXC6_SP, x"00000000");
            write_long(RESULT_EXC11_SP, x"00000000");
        end procedure;

        procedure run_case(expect_trace : boolean;
                           expect_exc   : boolean;
                           max_cycles   : integer := 120000) is
            variable started    : boolean := false;
            variable idle_count : integer := 0;
            variable done_count : integer := 0;
            variable saw_trace  : boolean := false;
            variable saw_exc    : boolean := false;
            variable vectors_restored : boolean := false;
            variable boot_fetch_seen : boolean := false;
            variable boot_fetch_count : integer := 0;
            variable test_fetch_seen : boolean := false;
            variable test_fetch_reported : boolean := false;
            variable addr_i : integer;
            variable trace_mark : std_logic_vector(31 downto 0);
            variable exc_mark   : std_logic_vector(31 downto 0);
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);

                addr_i := to_integer(unsigned(addr_out));
                if not boot_fetch_seen and busstate = "00" and FC(1 downto 0) = "10" and
                   addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_seen := true;
                    boot_fetch_count := 1;
                elsif boot_fetch_seen and not vectors_restored and
                      busstate = "00" and FC(1 downto 0) = "10" and
                      addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_count := boot_fetch_count + 1;
                end if;

                if not vectors_restored and boot_fetch_seen and boot_fetch_count >= 2 then
                    write_long(16#0#, saved_reset_ssp);
                    write_long(16#4#, saved_reset_pc);
                    vectors_restored := true;
                end if;

                if vectors_restored and busstate = "00" and FC(1 downto 0) = "10" and
                   addr_i >= OPC_BASE and addr_i < OPC_BASE + 8 then
                    test_fetch_seen := true;
                    if not test_fetch_reported then
                        report "RUNCASE_FETCH: addr=$" & to_hstring(addr_out) &
                               " opcode=$" & to_hstring(dbg_opcode) &
                               " lastopc=$" & to_hstring(dbg_last_opc_read) &
                               " srh=$" & to_hstring(dbg_FlagsSR) &
                               " micro=" & integer'image(dbg_micro_state) &
                               " next=" & integer'image(dbg_next_micro_state) severity note;
                        test_fetch_reported := true;
                    end if;
                end if;

                trace_mark := read_long(RESULT_TRACE_SP);
                if test_fetch_seen then
                    saw_trace := saw_trace or stack_mark_valid(trace_mark);
                    saw_exc := saw_exc or stack_mark_valid(read_long(RESULT_EXC4_SP)) or
                               stack_mark_valid(read_long(RESULT_EXC6_SP)) or
                               stack_mark_valid(read_long(RESULT_EXC11_SP));
                end if;

                if test_fetch_seen and
                   (not expect_trace or saw_trace) and
                   (not expect_exc or saw_exc) then
                    done_count := done_count + 1;
                    if done_count >= 8 then
                        return;
                    end if;
                else
                    done_count := 0;
                end if;

                if test_fetch_seen and busstate /= "01" then
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
            report "RUNCASE_TIMEOUT: vectors_restored=" & boolean'image(vectors_restored) &
                   " boot_fetch_seen=" & boolean'image(boot_fetch_seen) &
                   " boot_fetch_count=" & integer'image(boot_fetch_count) &
                   " test_fetch_seen=" & boolean'image(test_fetch_seen) &
                   " started=" & boolean'image(started) &
                   " addr=$" & to_hstring(addr_out) &
                   " opcode=$" & to_hstring(dbg_opcode) &
                   " lastopc=$" & to_hstring(dbg_last_opc_read) &
                   " micro=" & integer'image(dbg_micro_state) &
                   " next=" & integer'image(dbg_next_micro_state) &
                   " trace=$" & to_hstring(read_long(RESULT_TRACE_SP)) &
                   " exc4=$" & to_hstring(read_long(RESULT_EXC4_SP)) &
                   " exc6=$" & to_hstring(read_long(RESULT_EXC6_SP)) &
                   " exc11=$" & to_hstring(read_long(RESULT_EXC11_SP)) severity note;
        end procedure;

        procedure run_until_prog_fetch(fetch_addr : integer;
                                       max_cycles : integer := 120000) is
            variable vectors_restored : boolean := false;
            variable boot_fetch_seen  : boolean := false;
            variable boot_fetch_count : integer := 0;
            variable addr_i           : integer;
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);

                addr_i := to_integer(unsigned(addr_out));
                if not boot_fetch_seen and busstate = "00" and FC(1 downto 0) = "10" and
                   addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_seen := true;
                    boot_fetch_count := 1;
                elsif boot_fetch_seen and not vectors_restored and
                      busstate = "00" and FC(1 downto 0) = "10" and
                      addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_count := boot_fetch_count + 1;
                end if;

                if not vectors_restored and boot_fetch_seen and boot_fetch_count >= 2 then
                    write_long(16#0#, saved_reset_ssp);
                    write_long(16#4#, saved_reset_pc);
                    vectors_restored := true;
                end if;

                if vectors_restored and busstate = "00" and FC(1 downto 0) = "10" and
                   addr_i = fetch_addr then
                    report "RUNUNTIL_FETCH: addr=$" & to_hstring(addr_out) &
                           " opcode=$" & to_hstring(dbg_opcode) &
                           " lastopc=$" & to_hstring(dbg_last_opc_read) &
                           " srh=$" & to_hstring(dbg_FlagsSR) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) severity note;
                    return;
                end if;
            end loop;

            report "FAIL: run_until_prog_fetch timed out waiting for PC=$" &
                   slv_to_hex(std_logic_vector(to_unsigned(fetch_addr, 32))) severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure run_until_word_store(store_addr   : integer;
                                       store_seen   : out boolean;
                                       stored_word  : out std_logic_vector(15 downto 0);
                                       max_cycles   : integer := 120000) is
            variable vectors_restored : boolean := false;
            variable boot_fetch_seen  : boolean := false;
            variable boot_fetch_count : integer := 0;
            variable addr_i           : integer;
        begin
            store_seen := false;
            stored_word := (others => '0');
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);

                addr_i := to_integer(unsigned(addr_out));
                if not boot_fetch_seen and busstate = "00" and FC(1 downto 0) = "10" and
                   addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_seen := true;
                    boot_fetch_count := 1;
                elsif boot_fetch_seen and not vectors_restored and
                      busstate = "00" and FC(1 downto 0) = "10" and
                      addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_count := boot_fetch_count + 1;
                end if;

                if not vectors_restored and boot_fetch_seen and boot_fetch_count >= 2 then
                    write_long(16#0#, saved_reset_ssp);
                    write_long(16#4#, saved_reset_pc);
                    vectors_restored := true;
                end if;

                if vectors_restored and busstate = "11" and nWr = '0' and addr_i = store_addr then
                    stored_word := data_write;
                    store_seen := true;
                    report "RUNUNTIL_STORE: addr=$" & to_hstring(addr_out) &
                           " data=$" & to_hstring(data_write) &
                           " uds=" & std_logic'image(nUDS) &
                           " lds=" & std_logic'image(nLDS) &
                           " lastopc=$" & to_hstring(dbg_last_opc_read) &
                           " opcode=$" & to_hstring(dbg_opcode) &
                           " srh=$" & to_hstring(dbg_FlagsSR) &
                           " micro=" & integer'image(dbg_micro_state) &
                           " next=" & integer'image(dbg_next_micro_state) severity note;
                    return;
                end if;
            end loop;

            report "FAIL: run_until_word_store timed out waiting for store=$" &
                   slv_to_hex(std_logic_vector(to_unsigned(store_addr, 32))) severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure run_jmp_mem_case(max_cycles : integer := 120000) is
            variable started    : boolean := false;
            variable idle_count : integer := 0;
            variable done_count : integer := 0;
            variable vectors_restored : boolean := false;
            variable boot_fetch_seen  : boolean := false;
            variable boot_fetch_count : integer := 0;
            variable addr_i : integer;
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);

                addr_i := to_integer(unsigned(addr_out));
                if not boot_fetch_seen and busstate = "00" and FC(1 downto 0) = "10" and
                   addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_seen := true;
                    boot_fetch_count := 1;
                elsif boot_fetch_seen and not vectors_restored and
                      busstate = "00" and FC(1 downto 0) = "10" and
                      addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_count := boot_fetch_count + 1;
                end if;

                if not vectors_restored and boot_fetch_seen and boot_fetch_count >= 2 then
                    write_long(16#0#, saved_reset_ssp);
                    write_long(16#4#, saved_reset_pc);
                    vectors_restored := true;
                end if;

                if read_byte(16#0000008B#) = x"FD" and
                   read_word(16#0000008C#) = x"EB48" and
                   read_byte(16#4204FEFF#) = x"75" then
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

            report "NOTE: run_jmp_mem_case exhausted cycle budget" severity note;
            report "JMP_MEM_TIMEOUT: vectors_restored=" & boolean'image(vectors_restored) &
                   " boot_fetch_seen=" & boolean'image(boot_fetch_seen) &
                   " boot_fetch_count=" & integer'image(boot_fetch_count) &
                   " addr=$" & to_hstring(addr_out) &
                   " opcode=$" & to_hstring(dbg_opcode) &
                   " lastopc=$" & to_hstring(dbg_last_opc_read) &
                   " micro=" & integer'image(dbg_micro_state) &
                   " next=" & integer'image(dbg_next_micro_state) &
                   " low8b=$" & to_hstring(read_byte(16#0000008B#)) &
                   " low8c=$" & to_hstring(read_word(16#0000008C#)) &
                   " highff=$" & to_hstring(read_byte(16#4204FEFF#)) severity note;
        end procedure;

        procedure check_chk2_stacked(case_name : string; opcode_word : std_logic_vector(15 downto 0)) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc_sr   : std_logic_vector(15 downto 0);
        begin
            init_common;
            install_chk2_boot(opcode_word, x"0800", 16#00000010#, x"4000");
            run_case(true, true);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));

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

        procedure check_chk2_stacked_exact(case_name : string;
                                           opcode_word : std_logic_vector(15 downto 0);
                                           ext_word    : std_logic_vector(15 downto 0);
                                           d0_value    : integer;
                                           sr_value    : std_logic_vector(15 downto 0)) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc_sr   : std_logic_vector(15 downto 0);
        begin
            init_common;
            install_chk2_boot(opcode_word, ext_word, d0_value, sr_value);
            run_case(true, true);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));

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

        procedure check_chk2_standalone(case_name    : string;
                                        opcode_word  : std_logic_vector(15 downto 0);
                                        ext_word     : std_logic_vector(15 downto 0);
                                        d0_value     : integer;
                                        expected_sr  : std_logic_vector(15 downto 0)) is
            variable trace_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
        begin
            init_common;
            install_chk2_boot(opcode_word, ext_word, d0_value, x"8000");
            run_case(true, false);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            if trace_sp /= 0 then
                report "PASS: " & case_name & " entered standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " did not enter standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            trace_sr := read_word(trace_sp);
            trace_pc := read_long(trace_sp + 2);

            if trace_sr = expected_sr then
                report "PASS: " & case_name & " standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $" & slv_to_hex(expected_sr) severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = x"42050004" then
                report "PASS: " & case_name & " standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $42050004" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_chk2_noexc_exact(case_name    : string;
                                         opcode_word  : std_logic_vector(15 downto 0);
                                         ext_word     : std_logic_vector(15 downto 0);
                                         d0_value     : integer;
                                         sr_value     : std_logic_vector(15 downto 0)) is
            variable trace_sp : integer;
            variable exc4_sp  : integer;
            variable exc6_sp  : integer;
            variable exc11_sp : integer;
        begin
            init_common;
            install_chk2_boot(opcode_word, ext_word, d0_value, sr_value);
            run_case(false, false);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc4_sp := to_integer(unsigned(read_long(RESULT_EXC4_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if trace_sp = 0 then
                report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpectedly entered trace handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if exc4_sp = 0 and exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: " & case_name & " stayed out of exception handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpectedly entered an exception handler" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_chk2_noexc_exact_ccr(case_name    : string;
                                             opcode_word  : std_logic_vector(15 downto 0);
                                             ext_word     : std_logic_vector(15 downto 0);
                                             d0_value     : integer;
                                             sr_value     : std_logic_vector(15 downto 0);
                                             expected_ccr : std_logic_vector(15 downto 0)) is
            variable trace_sp   : integer;
            variable exc4_sp    : integer;
            variable exc6_sp    : integer;
            variable exc11_sp   : integer;
            variable actual_ccr : std_logic_vector(15 downto 0);
            variable store_seen : boolean;
        begin
            init_common;
            install_chk2_boot(opcode_word, ext_word, d0_value, sr_value);
            write_word(RESULT_NOEXC_CCR, x"FFFF");
            write_word(16#42050004#, x"42F9");
            write_long(16#42050006#, std_logic_vector(to_unsigned(RESULT_NOEXC_CCR, 32)));
            write_word(16#4205000A#, x"4AFC");
            run_until_word_store(RESULT_NOEXC_CCR, store_seen, actual_ccr, 120000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc4_sp := to_integer(unsigned(read_long(RESULT_EXC4_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if trace_sp = 0 and exc4_sp = 0 and exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: " & case_name & " stayed out of handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpectedly entered a handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if store_seen then
                report "PASS: " & case_name & " reached CCR fallthrough probe" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " never reached CCR fallthrough probe" severity error;
                fail_count := fail_count + 1;
            end if;

            if actual_ccr = expected_ccr then
                report "PASS: " & case_name & " final CCR matched expectation" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " final CCR=$" & slv_to_hex(actual_ccr) &
                       " expected $" & slv_to_hex(expected_ccr) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_chk2_exc1_exact(case_name     : string;
                                        opcode_word   : std_logic_vector(15 downto 0);
                                        ext_word      : std_logic_vector(15 downto 0);
                                        d0_value      : integer;
                                        sr_value      : std_logic_vector(15 downto 0);
                                        expect_trace  : boolean;
                                        expected_sr   : std_logic_vector(15 downto 0)) is
            variable trace_sp : integer;
            variable exc6_sp  : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
        begin
            init_common;
            install_chk2_boot(opcode_word, ext_word, d0_value, sr_value);
            run_case(expect_trace, false);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: " & case_name & " stayed out of exception handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpectedly entered an exception handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if expect_trace then
                if trace_sp /= 0 then
                    report "PASS: " & case_name & " entered standalone trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " missed standalone trace handler" severity error;
                    fail_count := fail_count + 1;
                    return;
                end if;

                if first_trace_frame_valid = '1' then
                    trace_sr := first_trace_frame_sr;
                    trace_pc := first_trace_frame_pc;
                else
                    trace_sr := read_word(trace_sp);
                    trace_pc := read_long(trace_sp + 2);
                end if;

                if trace_sr = expected_sr then
                    report "PASS: " & case_name & " standalone trace SR matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace SR=$" & slv_to_hex(trace_sr) &
                           " expected $" & slv_to_hex(expected_sr) severity error;
                    fail_count := fail_count + 1;
                end if;

                if trace_pc = x"42050004" then
                    report "PASS: " & case_name & " standalone trace PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $42050004" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                if trace_sp = 0 then
                    report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " unexpectedly entered the trace handler" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;
        end procedure;

        procedure check_chk2_exc6_exact(case_name    : string;
                                        opcode_word  : std_logic_vector(15 downto 0);
                                        ext_word     : std_logic_vector(15 downto 0);
                                        d0_value     : integer;
                                        sr_value     : std_logic_vector(15 downto 0);
                                        expect_trace : boolean) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc_sr   : std_logic_vector(15 downto 0);
        begin
            init_common;
            install_chk2_boot(opcode_word, ext_word, d0_value, sr_value);
            run_case(expect_trace, true);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));

            if exc_sp /= 0 then
                report "PASS: " & case_name & " reached exception 6 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " missed exception 6 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if expect_trace then
                if trace_sp /= 0 then
                    report "PASS: " & case_name & " took stacked trace" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " missed stacked trace" severity error;
                    fail_count := fail_count + 1;
                    return;
                end if;

                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
                exc_sr := read_word(exc_sp);

                if trace_pc = x"000018C0" then
                    report "PASS: " & case_name & " stacked trace PC matched cputest vector address" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " stacked trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $000018C0" severity error;
                    fail_count := fail_count + 1;
                end if;

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
            else
                if trace_sp = 0 then
                    report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " unexpectedly entered the trace handler" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;
        end procedure;

        procedure prime_jmp_record37_expected_old_values is
        begin
            write_byte(16#0000008B#, x"FC");
            write_word(16#0000008C#, x"2048");
            write_byte(16#4204FEFF#, x"54");
        end procedure;

        procedure check_jmp_exact_case(case_name      : string;
                                       sr_value       : std_logic_vector(15 downto 0);
                                       expect_trace   : boolean;
                                       preload_record18_lowmem : boolean := false;
                                       prime_expected_old_values : boolean := false) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable trace_pc_hi : std_logic_vector(15 downto 0);
            variable trace_pc_lo : std_logic_vector(15 downto 0);
            variable trace_fv    : std_logic_vector(15 downto 0);
            variable trace_ia    : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common;
            if preload_record18_lowmem then
                write_word(16#0000008A#, x"4AFC");
                write_word(16#0000008C#, x"2048");
            end if;
            install_jmp_boot(sr_value);
            if prime_expected_old_values then
                prime_jmp_record37_expected_old_values;
            end if;
            run_case(expect_trace, true, 120000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if exc_sp /= 0 then
                report "PASS: " & case_name & " reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
            end if;
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if expect_trace then
                if trace_sp /= 0 then
                    report "PASS: " & case_name & " hit standalone trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " missed standalone trace handler" severity error;
                    fail_count := fail_count + 1;
                    return;
                end if;

                if first_trace_frame_valid = '1' then
                    trace_sr := first_trace_frame_sr;
                    trace_pc := first_trace_frame_pc;
                    trace_pc_hi := first_trace_frame_pc(31 downto 16);
                    trace_pc_lo := first_trace_frame_pc(15 downto 0);
                    trace_fv := first_trace_frame_fv;
                    trace_ia := first_trace_frame_ia;
                else
                    trace_sr := read_word(trace_sp);
                    trace_pc := read_long(trace_sp + 2);
                    trace_pc_hi := read_word(trace_sp + 2);
                    trace_pc_lo := read_word(trace_sp + 4);
                    trace_fv := read_word(trace_sp + 6);
                    trace_ia := read_long(trace_sp + 8);
                end if;

                if trace_sr = sr_value then
                    report "PASS: " & case_name & " standalone trace SR matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace SR=$" & slv_to_hex(trace_sr) &
                           " expected $" & slv_to_hex(sr_value) severity error;
                    fail_count := fail_count + 1;
                end if;

                if trace_pc = x"42006D72" then
                    report "PASS: " & case_name & " standalone trace PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $42006D72" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                if trace_sp = 0 then
                    report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " unexpectedly entered the trace handler" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;

            if low_b = x"FD" then
                report "PASS: " & case_name & " low byte $8B matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " byte $8B=$" & slv_to_hex(low_b) & " expected $FD" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_w = x"EB48" then
                report "PASS: " & case_name & " low word $8C matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " word $8C=$" & slv_to_hex(low_w) & " expected $EB48" severity error;
                fail_count := fail_count + 1;
            end if;

            if high_b = x"75" then
                report "PASS: " & case_name & " byte $4204FEFF matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " byte $4204FEFF=$" & slv_to_hex(high_b) & " expected $75" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_literal_a7_case(case_name      : string;
                                            sr_value       : std_logic_vector(15 downto 0);
                                            literal_a7     : integer;
                                            expected_fetch : integer) is
            variable prev_fail : integer;
            variable exc4_sp   : integer;
            variable exc11_sp  : integer;
            variable low_b     : std_logic_vector(7 downto 0);
            variable low_w     : std_logic_vector(15 downto 0);
            variable high_b    : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;
            install_jmp_cputest020_direct_a7_boot(literal_a7, sr_value);
            write_word(16#0000008A#, x"4AFC");
            write_word(16#0000008C#, x"2048");
            write_byte(16#4204FEFF#, x"54");
            write_long(16#420069B0#, x"4AFC2048");

            prev_fail := fail_count;
            run_until_prog_fetch(expected_fetch, 120000);
            if fail_count = prev_fail then
                report "PASS: " & case_name & " fetched literal A7 target $" &
                       slv_to_hex(std_logic_vector(to_unsigned(expected_fetch, 32))) severity note;
                pass_count := pass_count + 1;
            else
                return;
            end if;

            for i in 0 to 256 loop
                wait until rising_edge(clk);
                if read_long(RESULT_EXC4_SP) /= x"00000000" or read_long(RESULT_EXC11_SP) /= x"00000000" then
                    exit;
                end if;
            end loop;

            exc4_sp := to_integer(unsigned(read_long(RESULT_EXC4_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc4_sp /= 0 then
                report "PASS: " & case_name & " took vector 4 from literal A7 target" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " missed vector 4 after literal A7 target" severity error;
                fail_count := fail_count + 1;
            end if;

            if exc11_sp /= 0 then
                report "NOTE: " & case_name & " later reached vector 11 after the literal target path" severity note;
            end if;

            if low_b = x"FC" and low_w = x"2048" and high_b = x"54" then
                report "PASS: " & case_name & " left the packed ORI side effects untouched" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " changed low/high memory to low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) &
                       " instead of preserving FC/2048/54" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_exact is
        begin
            check_jmp_exact_case("JMP/0002 record=37 group=1", sr_from_extraccr(1), false);
            check_jmp_exact_case("JMP/0002 record=37 group=3", sr_from_extraccr(3), true);
            check_jmp_exact_case("JMP/0002 record=37 group=5", sr_from_extraccr(5), true);
            check_jmp_exact_case("JMP/0002 record=37 group=7", sr_from_extraccr(7), true);
            check_jmp_exact_case(
                "JMP/0002 record18-lowmem -> group=1",
                sr_from_extraccr(1),
                false,
                true);
            check_jmp_exact_case(
                "JMP/0002 record18-lowmem -> group=3",
                sr_from_extraccr(3),
                true,
                true);
            check_jmp_exact_case(
                "JMP/0002 memwrite-old-values -> group=1",
                sr_from_extraccr(1),
                false,
                false,
                true);
            check_jmp_exact_case(
                "JMP/0002 memwrite-old-values -> group=3",
                sr_from_extraccr(3),
                true,
                false,
                true);
            check_jmp_literal_a7_case(
                "JMP/0002 literal active A7=$420003FE",
                sr_from_extraccr(1),
                JMP_USP_VALUE,
                16#420069B0#);
        end procedure;

        procedure check_chk2_exc1_cputest020_exact(case_name     : string;
                                                   opcode_word   : std_logic_vector(15 downto 0);
                                                   ext_word      : std_logic_vector(15 downto 0);
                                                   d0_value      : integer;
                                                   sr_value      : std_logic_vector(15 downto 0);
                                                   expect_trace  : boolean;
                                                   expected_sr   : std_logic_vector(15 downto 0)) is
            variable trace_sp : integer;
            variable exc6_sp  : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
        begin
            init_common_cputest020;
            install_chk2_cputest020_boot(opcode_word, ext_word, d0_value, sr_value);
            run_case(expect_trace, false, 160000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: " & case_name & " stayed out of exception handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpectedly entered an exception handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if expect_trace then
                if trace_sp /= 0 then
                    report "PASS: " & case_name & " entered standalone trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " missed standalone trace handler" severity error;
                    fail_count := fail_count + 1;
                    return;
                end if;

                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);

                if trace_sr = expected_sr then
                    report "PASS: " & case_name & " standalone trace SR matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace SR=$" & slv_to_hex(trace_sr) &
                           " expected $" & slv_to_hex(expected_sr) severity error;
                    fail_count := fail_count + 1;
                end if;

                if trace_pc = x"42050004" then
                    report "PASS: " & case_name & " standalone trace PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $42050004" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                if trace_sp = 0 then
                    report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " unexpectedly entered the trace handler" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;
        end procedure;

        procedure check_chk2_exc1_cputest020_record(case_name    : string;
                                                    expected_sr  : std_logic_vector(15 downto 0);
                                                    expected_pc  : std_logic_vector(31 downto 0);
                                                    sr_value     : std_logic_vector(15 downto 0);
                                                    endpc_value  : integer;
                                                    d0_value     : integer;
                                                    d2_value     : integer;
                                                    d3_value     : integer;
                                                    d4_value     : integer;
                                                    d5_value     : integer;
                                                    d6_value     : integer;
                                                    d7_value     : integer;
                                                    a1_value     : integer;
                                                    a2_value     : integer;
                                                    a3_value     : integer;
                                                    a4_value     : integer;
                                                    a5_value     : integer;
                                                    code0        : integer;
                                                    code2        : integer;
                                                    code4        : integer := -1;
                                                    code6        : integer := -1;
                                                    code8        : integer := -1) is
            variable trace_sp : integer;
            variable exc6_sp  : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
        begin
            init_common_cputest020;
            install_chk2_cputest020_record_boot(
                sr_value, endpc_value,
                d0_value, d2_value, d3_value, d4_value, d5_value, d6_value, d7_value,
                a1_value, a2_value, a3_value, a4_value, a5_value,
                code0, code2, code4, code6, code8);
            run_case(true, false, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: " & case_name & " stayed out of exception handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpectedly entered an exception handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_sp /= 0 then
                report "PASS: " & case_name & " entered standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if first_trace_frame_valid = '1' then
                trace_sr := first_trace_frame_sr;
                trace_pc := first_trace_frame_pc;
            else
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
            end if;

            if trace_sr = expected_sr then
                report "PASS: " & case_name & " standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $" & slv_to_hex(expected_sr) severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = expected_pc then
                report "PASS: " & case_name & " standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $" & slv_to_hex(expected_pc) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_chk2_noexc_cputest020_record(case_name    : string;
                                                     expected_sr  : std_logic_vector(15 downto 0);
                                                     expected_pc  : std_logic_vector(31 downto 0);
                                                     ccrmode      : integer;
                                                     ccr          : integer;
                                                     extraccr     : integer;
                                                     d0_value     : integer;
                                                     d2_value     : integer;
                                                     d3_value     : integer;
                                                     d4_value     : integer;
                                                     d5_value     : integer;
                                                     d6_value     : integer;
                                                     d7_value     : integer;
                                                     a1_value     : integer;
                                                     a2_value     : integer;
                                                     a3_value     : integer;
                                                     a4_value     : integer;
                                                     a5_value     : integer;
                                                     code0        : integer;
                                                     code2        : integer;
                                                     code4        : integer := -1;
                                                     code6        : integer := -1;
                                                     code8        : integer := -1;
                                                     check_pc     : boolean := true) is
            variable trace_sp  : integer;
            variable exc6_sp   : integer;
            variable exc11_sp  : integer;
            variable actual_sr : std_logic_vector(15 downto 0);
            variable endpc_i   : integer;
            variable store_seen : boolean;
        begin
            endpc_i := to_integer(unsigned(expected_pc));
            init_common_cputest020;
            install_chk2_cputest020_record_boot(
                sr_from_cputest_group(ccrmode, ccr, extraccr), endpc_i,
                d0_value, d2_value, d3_value, d4_value, d5_value, d6_value, d7_value,
                a1_value, a2_value, a3_value, a4_value, a5_value,
                code0, code2, code4, code6, code8);
            write_word(RESULT_NOEXC_CCR, x"0000");
            write_word(endpc_i, x"42F9");
            write_long(endpc_i + 2, std_logic_vector(to_unsigned(RESULT_NOEXC_CCR, 32)));
            write_word(endpc_i + 6, x"4AFC");
            run_until_word_store(RESULT_NOEXC_CCR, store_seen, actual_sr, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if trace_sp = 0 and exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: " & case_name & " stayed out of handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " unexpectedly entered a handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if actual_sr = expected_sr then
                report "PASS: " & case_name & " final SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " final SR=$" & slv_to_hex(actual_sr) &
                       " expected $" & slv_to_hex(expected_sr) severity error;
                fail_count := fail_count + 1;
            end if;

            if check_pc then
                if store_seen then
                    report "PASS: " & case_name & " final PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " never reached fallthrough probe at $" &
                           slv_to_hex(expected_pc) severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;
        end procedure;

        procedure check_chk2_exc6_cputest020_exact(case_name    : string;
                                                   opcode_word  : std_logic_vector(15 downto 0);
                                                   ext_word     : std_logic_vector(15 downto 0);
                                                   d0_value     : integer;
                                                   sr_value     : std_logic_vector(15 downto 0);
                                                   expect_trace : boolean) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc_sr   : std_logic_vector(15 downto 0);
        begin
            init_common_cputest020;
            install_chk2_cputest020_boot(opcode_word, ext_word, d0_value, sr_value);
            run_case(expect_trace, true, 160000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));

            if exc_sp /= 0 then
                report "PASS: " & case_name & " reached exception 6 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " missed exception 6 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if expect_trace then
                if trace_sp /= 0 then
                    report "PASS: " & case_name & " took stacked trace" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " missed stacked trace" severity error;
                    fail_count := fail_count + 1;
                    return;
                end if;

                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
                exc_sr := read_word(exc_sp);

                if trace_pc = std_logic_vector(to_unsigned(CPUTEST020_TABLE_BASE + (6 - 2) * 2, 32)) then
                    report "PASS: " & case_name & " stacked trace PC matched exceptiontable020 entry" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " stacked trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $" &
                           slv_to_hex(std_logic_vector(to_unsigned(CPUTEST020_TABLE_BASE + (6 - 2) * 2, 32))) severity error;
                    fail_count := fail_count + 1;
                end if;

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
            else
                if trace_sp = 0 then
                    report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " unexpectedly entered the trace handler" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;
        end procedure;

        procedure check_chk2_exc6_cputest020_record(case_name    : string;
                                                    expected_sr  : std_logic_vector(15 downto 0);
                                                    expected_pc  : std_logic_vector(31 downto 0);
                                                    sr_value     : std_logic_vector(15 downto 0);
                                                    endpc_value  : integer;
                                                    expect_trace : boolean;
                                                    d0_value     : integer;
                                                    d2_value     : integer;
                                                    d3_value     : integer;
                                                    d4_value     : integer;
                                                    d5_value     : integer;
                                                    d6_value     : integer;
                                                    d7_value     : integer;
                                                    a1_value     : integer;
                                                    a2_value     : integer;
                                                    a3_value     : integer;
                                                    a4_value     : integer;
                                                    a5_value     : integer;
                                                    code0        : integer;
                                                    code2        : integer;
                                                    code4        : integer := -1;
                                                    code6        : integer := -1;
                                                    code8        : integer := -1) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc_sr   : std_logic_vector(15 downto 0);
            variable exc_pc   : std_logic_vector(31 downto 0);
        begin
            init_common_cputest020;
            install_chk2_cputest020_record_boot(
                sr_value, endpc_value,
                d0_value, d2_value, d3_value, d4_value, d5_value, d6_value, d7_value,
                a1_value, a2_value, a3_value, a4_value, a5_value,
                code0, code2, code4, code6, code8);
            run_case(true, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));

            if exc_sp /= 0 then
                report "PASS: " & case_name & " reached exception 6 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " missed exception 6 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            exc_sr := read_word(exc_sp);
            exc_pc := read_long(exc_sp + 2);

            if exc_sr = expected_sr then
                report "PASS: " & case_name & " exception SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " exception SR=$" & slv_to_hex(exc_sr) &
                       " expected $" & slv_to_hex(expected_sr) severity error;
                fail_count := fail_count + 1;
            end if;

            if exc_pc = expected_pc then
                report "PASS: " & case_name & " exception PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " exception PC=$" & slv_to_hex(exc_pc) &
                       " expected $" & slv_to_hex(expected_pc) severity error;
                fail_count := fail_count + 1;
            end if;

            if expect_trace then
                if trace_sp /= 0 then
                    report "PASS: " & case_name & " took stacked trace" severity note;
                    pass_count := pass_count + 1;
                    trace_sr := read_word(trace_sp);
                    trace_pc := read_long(trace_sp + 2);
                    if trace_pc = std_logic_vector(to_unsigned(CPUTEST020_TABLE_BASE + (6 - 2) * 2, 32)) then
                        report "PASS: " & case_name & " stacked trace PC matched exceptiontable020 entry" severity note;
                        pass_count := pass_count + 1;
                    else
                        report "FAIL: " & case_name & " stacked trace PC=$" & slv_to_hex(trace_pc) &
                               " expected $" &
                               slv_to_hex(std_logic_vector(to_unsigned(CPUTEST020_TABLE_BASE + (6 - 2) * 2, 32))) severity error;
                        fail_count := fail_count + 1;
                    end if;
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
                else
                    report "FAIL: " & case_name & " missed stacked trace" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                if trace_sp = 0 then
                    report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " unexpectedly entered the trace handler" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;
        end procedure;

        procedure check_jmp_cputest020_case(case_name    : string;
                                            sr_value     : std_logic_vector(15 downto 0);
                                            expect_trace : boolean;
                                            prime_expected_old_values : boolean := false) is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;
            install_jmp_cputest020_boot(sr_value);
            if prime_expected_old_values then
                prime_jmp_record37_expected_old_values;
            end if;
            run_case(expect_trace, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc_sp /= 0 then
                report "PASS: " & case_name & " reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if expect_trace then
                if trace_sp /= 0 then
                    report "PASS: " & case_name & " hit standalone trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " missed standalone trace handler" severity error;
                    fail_count := fail_count + 1;
                    return;
                end if;

                if first_trace_frame_valid = '1' then
                    trace_sr := first_trace_frame_sr;
                    trace_pc := first_trace_frame_pc;
                else
                    trace_sr := read_word(trace_sp);
                    trace_pc := read_long(trace_sp + 2);
                end if;

                if trace_sr = sr_value then
                    report "PASS: " & case_name & " standalone trace SR matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace SR=$" & slv_to_hex(trace_sr) &
                           " expected $" & slv_to_hex(sr_value) severity error;
                    fail_count := fail_count + 1;
                end if;

                if trace_pc = x"42006D72" then
                    report "PASS: " & case_name & " standalone trace PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " standalone trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $42006D72" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                if trace_sp = 0 then
                    report "PASS: " & case_name & " stayed out of the trace handler" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: " & case_name & " unexpectedly entered the trace handler" severity error;
                    fail_count := fail_count + 1;
                end if;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: " & case_name & " memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_cputest020_group1_after_record18 is
            variable trace_sp : integer;
            variable exc11_sp : integer;
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;

            install_jmp_cputest020_record18_boot(sr_from_extraccr(1));
            run_case(false, false, 200000);

            rearm_cputest020;
            install_jmp_cputest020_boot(sr_from_extraccr(1));
            run_case(false, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc11_sp /= 0 then
                report "PASS: JMP record18 -> group1 runtime020 reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group1 runtime020 missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp = 0 then
                report "PASS: JMP record18 -> group1 runtime020 stayed out of the trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group1 runtime020 unexpectedly entered the trace handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: JMP record18 -> group1 runtime020 memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group1 runtime020 memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_cputest020_group1_oldvalue_preload is
            variable trace_sp : integer;
            variable exc11_sp : integer;
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;
            install_jmp_cputest020_boot(sr_from_extraccr(1));
            prime_jmp_record37_expected_old_values;
            run_case(false, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc11_sp /= 0 then
                report "PASS: JMP old-value preload -> group1 runtime020 reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group1 runtime020 missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp = 0 then
                report "PASS: JMP old-value preload -> group1 runtime020 stayed out of the trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group1 runtime020 unexpectedly entered the trace handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: JMP old-value preload -> group1 runtime020 memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group1 runtime020 memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_cputest020_group3_after_record18 is
            variable trace_sp : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;

            install_jmp_cputest020_record18_boot(sr_from_extraccr(3));
            run_case(false, false, 200000);

            rearm_cputest020;
            install_jmp_cputest020_boot(sr_from_extraccr(3));
            run_case(true, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc11_sp /= 0 then
                report "PASS: JMP record18 -> group3 runtime020 reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group3 runtime020 missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp /= 0 then
                report "PASS: JMP record18 -> group3 runtime020 hit standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group3 runtime020 missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if first_trace_frame_valid = '1' then
                trace_sr := first_trace_frame_sr;
                trace_pc := first_trace_frame_pc;
            else
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
            end if;

            if trace_sr = x"6000" then
                report "PASS: JMP record18 -> group3 runtime020 standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group3 runtime020 standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $6000" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = x"42006D72" then
                report "PASS: JMP record18 -> group3 runtime020 standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group3 runtime020 standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $42006D72" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: JMP record18 -> group3 runtime020 memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record18 -> group3 runtime020 memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_cputest020_group3_oldvalue_preload is
            variable trace_sp : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;
            install_jmp_cputest020_boot(sr_from_extraccr(3));
            prime_jmp_record37_expected_old_values;
            run_case(true, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc11_sp /= 0 then
                report "PASS: JMP old-value preload -> group3 runtime020 reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group3 runtime020 missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp /= 0 then
                report "PASS: JMP old-value preload -> group3 runtime020 hit standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group3 runtime020 missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if first_trace_frame_valid = '1' then
                trace_sr := first_trace_frame_sr;
                trace_pc := first_trace_frame_pc;
            else
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
            end if;

            if trace_sr = x"6000" then
                report "PASS: JMP old-value preload -> group3 runtime020 standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group3 runtime020 standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $6000" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = x"42006D72" then
                report "PASS: JMP old-value preload -> group3 runtime020 standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group3 runtime020 standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $42006D72" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: JMP old-value preload -> group3 runtime020 memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP old-value preload -> group3 runtime020 memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_cputest020_group0_precursor is
            variable low_b  : std_logic_vector(7 downto 0);
            variable low_w  : std_logic_vector(15 downto 0);
            variable high_b : std_logic_vector(7 downto 0);
            variable trace_sp : integer;
            variable exc4_sp  : integer;
            variable exc11_sp : integer;
        begin
            init_common_cputest020;
            install_jmp_cputest020_boot(sr_from_extraccr(0));
            run_case(false, false, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc4_sp := to_integer(unsigned(read_long(RESULT_EXC4_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if trace_sp = 0 and exc4_sp = 0 and exc11_sp = 0 then
                report "PASS: JMP record=37 group=0 runtime020 stayed out of handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP record=37 group=0 runtime020 unexpectedly entered handlers" severity error;
                fail_count := fail_count + 1;
            end if;

            report "NOTE: JMP record=37 group=0 runtime020 left low_b=$" & slv_to_hex(low_b) &
                   " low_w=$" & slv_to_hex(low_w) &
                   " high_b=$" & slv_to_hex(high_b) severity note;
        end procedure;

        procedure check_jmp_cputest020_cumulative34_37 is
            variable trace_sp : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;

            -- Record 34 leaves persistent tmem deltas that survive into record 37.
            -- Low memory stays at the sparse-image baseline here; earlier forcing
            -- $0000008A/$0000008C to $4AFC/$2048 was a bench-only artifact.
            write_byte(16#4204FEF9#, x"00");
            write_word(16#4204FEFA#, x"0000");
            write_byte(16#4204FEFC#, x"B2");
            write_byte(16#4204FEFD#, x"00");
            write_byte(16#4204FEFE#, x"00");

            -- Now replay the real failing BASIC case on top of the record-34 tmem state.
            install_jmp_cputest020_boot(sr_from_extraccr(3));
            run_case(true, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc11_sp /= 0 then
                report "PASS: JMP cumulative record34-state -> 37 reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP cumulative record34-state -> 37 missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp /= 0 then
                report "PASS: JMP cumulative record34-state -> 37 hit standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP cumulative record34-state -> 37 missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if first_trace_frame_valid = '1' then
                trace_sr := first_trace_frame_sr;
                trace_pc := first_trace_frame_pc;
            else
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
            end if;

            if trace_sr = x"6000" then
                report "PASS: JMP cumulative record34-state -> 37 standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP cumulative record34-state -> 37 standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $6000" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = x"42006D72" then
                report "PASS: JMP cumulative record34-state -> 37 standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP cumulative record34-state -> 37 standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $42006D72" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: JMP cumulative record34-state -> 37 memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP cumulative record34-state -> 37 memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_cputest020_same_record_1_3 is
            variable low_b1   : std_logic_vector(7 downto 0);
            variable low_w1   : std_logic_vector(15 downto 0);
            variable high_b1  : std_logic_vector(7 downto 0);
            variable trace_sp : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b3   : std_logic_vector(7 downto 0);
            variable low_w3   : std_logic_vector(15 downto 0);
            variable high_b3  : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;

            install_jmp_cputest020_boot(sr_from_extraccr(1));
            run_case(false, true, 200000);

            low_b1 := read_byte(16#0000008B#);
            low_w1 := read_word(16#0000008C#);
            high_b1 := read_byte(16#4204FEFF#);

            if low_b1 = x"FD" and low_w1 = x"EB48" and high_b1 = x"75" then
                report "PASS: JMP same-record group1 produced cputest side effects before validate restore" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP same-record group1 produced low_b=$" & slv_to_hex(low_b1) &
                       " low_w=$" & slv_to_hex(low_w1) &
                       " high_b=$" & slv_to_hex(high_b1) &
                       " before validate restore" severity error;
                fail_count := fail_count + 1;
            end if;

            -- Mirror validate_test() restoring CT_MEMWRITE locations to the
            -- encoded old values after group 1 finishes.
            write_byte(16#0000008B#, x"FC");
            write_word(16#0000008C#, x"2048");
            write_byte(16#4204FEFF#, x"54");

            rearm_cputest020;
            install_jmp_cputest020_boot(sr_from_extraccr(3));
            run_case(true, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b3 := read_byte(16#0000008B#);
            low_w3 := read_word(16#0000008C#);
            high_b3 := read_byte(16#4204FEFF#);

            if exc11_sp /= 0 then
                report "PASS: JMP same-record group1->3 reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP same-record group1->3 missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp /= 0 then
                report "PASS: JMP same-record group1->3 hit standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP same-record group1->3 missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if first_trace_frame_valid = '1' then
                trace_sr := first_trace_frame_sr;
                trace_pc := first_trace_frame_pc;
            else
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
            end if;

            if trace_sr = x"6000" then
                report "PASS: JMP same-record group1->3 standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP same-record group1->3 standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $6000" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = x"42006D72" then
                report "PASS: JMP same-record group1->3 standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP same-record group1->3 standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $42006D72" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b3 = x"FD" and low_w3 = x"EB48" and high_b3 = x"75" then
                report "PASS: JMP same-record group1->3 memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP same-record group1->3 memory side effects low_b=$" & slv_to_hex(low_b3) &
                       " low_w=$" & slv_to_hex(low_w3) &
                       " high_b=$" & slv_to_hex(high_b3) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_cputest020_precursor_sequence is
            variable low88 : std_logic_vector(31 downto 0);
            variable low8a : std_logic_vector(15 downto 0);
            variable low8c : std_logic_vector(15 downto 0);
            variable trace_sp : integer;
            variable exc11_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
        begin
            init_common_cputest020;

            install_jmp_cputest020_record16_boot(sr_from_extraccr(3));
            run_case(false, false, 200000);
            low88 := read_long(16#00000088#);
            if low88 = x"00002048" then
                report "PASS: JMP runtime020 precursor record16 left low $88 longword at $00002048" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP runtime020 precursor record16 low $88 longword=$" & slv_to_hex(low88) &
                       " expected $00002048" severity error;
                fail_count := fail_count + 1;
            end if;

            rearm_cputest020;
            install_jmp_cputest020_record18_boot(sr_from_extraccr(3));
            run_case(false, false, 200000);
            low8a := read_word(16#0000008A#);
            low8c := read_word(16#0000008C#);
            if low8a = x"4AFC" and low8c = x"2048" then
                report "PASS: JMP runtime020 precursor record18 rebuilt low $8A/$8C code words" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP runtime020 precursor record18 low words 8A=$" & slv_to_hex(low8a) &
                       " 8C=$" & slv_to_hex(low8c) &
                       " expected 4AFC/2048" severity error;
                fail_count := fail_count + 1;
            end if;

            rearm_cputest020;
            install_jmp_cputest020_boot(sr_from_extraccr(3));
            run_case(true, true, 200000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if exc11_sp /= 0 then
                report "PASS: JMP runtime020 precursor chain reached exception 11 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP runtime020 precursor chain missed exception 11 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp /= 0 then
                report "PASS: JMP runtime020 precursor chain hit standalone trace handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP runtime020 precursor chain missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if first_trace_frame_valid = '1' then
                trace_sr := first_trace_frame_sr;
                trace_pc := first_trace_frame_pc;
            else
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
            end if;

            if trace_sr = x"6000" then
                report "PASS: JMP runtime020 precursor chain standalone trace SR matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP runtime020 precursor chain standalone trace SR=$" & slv_to_hex(trace_sr) &
                       " expected $6000" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_pc = x"42006D72" then
                report "PASS: JMP runtime020 precursor chain standalone trace PC matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP runtime020 precursor chain standalone trace PC=$" & slv_to_hex(trace_pc) &
                       " expected $42006D72" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: JMP runtime020 precursor chain memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: JMP runtime020 precursor chain memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_chk2_b_cputest020_precursor_chain is
            variable trace_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc6_sp  : integer;
            variable exc11_sp : integer;
        begin
            init_common_cputest020;
            install_chk2_cputest020_boot(x"00D0", x"0800", 16#00000010#, sr_from_extraccr(4));
            run_case(true, true, 160000);

            rearm_cputest020;
            install_chk2_cputest020_boot(x"00D0", x"4800", 16#00000622#, sr_from_extraccr(4));
            run_case(true, false, 160000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: CHK2.B runtime020 precursor chain stage1 stayed out of exception handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.B runtime020 precursor chain stage1 unexpectedly entered exception handlers" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_sp /= 0 then
                report "PASS: CHK2.B runtime020 precursor chain stage1 entered standalone trace handler" severity note;
                pass_count := pass_count + 1;
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
                if trace_sr = x"8004" then
                    report "PASS: CHK2.B runtime020 precursor chain stage1 standalone trace SR matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: CHK2.B runtime020 precursor chain stage1 standalone trace SR=$" & slv_to_hex(trace_sr) &
                           " expected $8004" severity error;
                    fail_count := fail_count + 1;
                end if;
                if trace_pc = x"42050004" then
                    report "PASS: CHK2.B runtime020 precursor chain stage1 standalone trace PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: CHK2.B runtime020 precursor chain stage1 standalone trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $42050004" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                report "FAIL: CHK2.B runtime020 precursor chain stage1 missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_chk2_l_cputest020_precursor_chain is
            variable trace_sp : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc6_sp  : integer;
            variable exc11_sp : integer;
        begin
            init_common_cputest020;
            install_chk2_cputest020_boot(x"04D0", x"0800", 16#00000010#, sr_from_extraccr(4));
            run_case(true, true, 160000);

            rearm_cputest020;
            install_chk2_cputest020_boot(x"04D0", x"7800", 16#00000422#, sr_from_extraccr(4));
            run_case(true, false, 160000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: CHK2.L runtime020 precursor chain stage1 stayed out of exception handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.L runtime020 precursor chain stage1 unexpectedly entered exception handlers" severity error;
                fail_count := fail_count + 1;
            end if;

            if trace_sp /= 0 then
                report "PASS: CHK2.L runtime020 precursor chain stage1 entered standalone trace handler" severity note;
                pass_count := pass_count + 1;
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
                if trace_sr = x"8000" then
                    report "PASS: CHK2.L runtime020 precursor chain stage1 standalone trace SR matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: CHK2.L runtime020 precursor chain stage1 standalone trace SR=$" & slv_to_hex(trace_sr) &
                           " expected $8000" severity error;
                    fail_count := fail_count + 1;
                end if;
                if trace_pc = x"42050004" then
                    report "PASS: CHK2.L runtime020 precursor chain stage1 standalone trace PC matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: CHK2.L runtime020 precursor chain stage1 standalone trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $42050004" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                report "FAIL: CHK2.L runtime020 precursor chain stage1 missed standalone trace handler" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_chk2_w_cputest020_precursor_chain is
            variable trace_sp : integer;
            variable exc6_sp  : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable exc_sr   : std_logic_vector(15 downto 0);
        begin
            init_common_cputest020;
            install_chk2_cputest020_boot(x"02D0", x"0800", 16#00000010#, sr_from_extraccr(4));
            run_case(true, false, 160000);

            rearm_cputest020;
            install_chk2_cputest020_boot(x"02D0", x"A800", 16#00000422#, sr_from_extraccr(4));
            run_case(true, true, 160000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));

            if exc6_sp /= 0 then
                report "PASS: CHK2.W runtime020 precursor chain stage1 reached exception 6 handler" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.W runtime020 precursor chain stage1 missed exception 6 handler" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            if trace_sp /= 0 then
                report "PASS: CHK2.W runtime020 precursor chain stage1 took stacked trace" severity note;
                pass_count := pass_count + 1;
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
                exc_sr := read_word(exc6_sp);
                if trace_pc = std_logic_vector(to_unsigned(CPUTEST020_TABLE_BASE + (6 - 2) * 2, 32)) then
                    report "PASS: CHK2.W runtime020 precursor chain stage1 stacked trace PC matched exceptiontable020 entry" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: CHK2.W runtime020 precursor chain stage1 stacked trace PC=$" & slv_to_hex(trace_pc) &
                           " expected $" &
                           slv_to_hex(std_logic_vector(to_unsigned(CPUTEST020_TABLE_BASE + (6 - 2) * 2, 32))) severity error;
                    fail_count := fail_count + 1;
                end if;
                if trace_sr(13) = '1' and
                   ((unsigned(trace_sr) or to_unsigned(16#E000#, 16)) =
                    (unsigned(exc_sr) or to_unsigned(16#E000#, 16))) then
                    report "PASS: CHK2.W runtime020 precursor chain stage1 stacked trace SR matched cputest relation" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: CHK2.W runtime020 precursor chain stage1 stacked trace SR=$" & slv_to_hex(trace_sr) &
                           " exc SR=$" & slv_to_hex(exc_sr) severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                report "FAIL: CHK2.W runtime020 precursor chain stage1 missed stacked trace" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure run_cputest020_runtime_suite is
        begin
            check_chk2_noexc_cputest020_record(
                "CHK2.B record57 group0 sub1 runtime020",
                x"0014", x"42050004", 16#02#, 1, 0,
                16#00000130#, 16#7FFFFFFD#, 16#3FFFFF88#, -178, 16#00080808#, 16#00080808#, 16#7EE4E70A#,
                16#0000008B#, 16#00008014#, 16#0000FFFF#, -178, -261121,
                16#00D7#, 16#8800#);
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group0 sub0 runtime020",
                x"0001", x"4204FFFE", sr_from_cputest_group(16#02#, 0, 0), 16#42050004#, false,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group0 sub1 runtime020",
                x"0011", x"42050002", sr_from_cputest_group(16#02#, 1, 0), 16#42050004#, false,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
            check_chk2_noexc_cputest020_record(
                "CHK2.B record6 group0 sub0 runtime020",
                x"0004", x"42050004", 16#02#, 0, 0,
                16#0000062E#, -36993, -162817, -721418027, -2146669428, 16#02000202#, -227420747,
                16#00000083#, 16#00007FF1#, 16#00007FFF#, -250, 16#3FFFFFC0#,
                16#00D0#, 16#8800#);
            check_chk2_noexc_cputest020_record(
                "CHK2.B record6 group0 sub1 runtime020",
                x"0014", x"42050004", 16#02#, 1, 0,
                16#0000062E#, -36993, -162817, -721418027, -2146669428, 16#02000202#, -227420747,
                16#00000083#, 16#00007FF1#, 16#00007FFF#, -250, 16#3FFFFFC0#,
                16#00D0#, 16#8800#);
            check_chk2_exc1_cputest020_exact(
                "CHK2.B group4 runtime020",
                x"00D0", x"4800", 16#00000022#, sr_from_extraccr(4), true, x"8004");
            check_chk2_exc1_cputest020_record(
                "CHK2.B record57 group4 runtime020",
                x"8004", x"42050004", sr_from_extraccr(4), 16#42050004#,
                16#00000130#, 16#7FFFFFFD#, 16#3FFFFF88#, -178, 16#00080808#, 16#00080808#, 16#7EE4E70A#,
                16#0000008B#, 16#00008014#, 16#0000FFFF#, -178, -261121,
                16#00D7#, 16#8800#);
            check_chk2_exc1_cputest020_record(
                "CHK2.B record6 group4 sub0 runtime020",
                x"8004", x"42050004", sr_from_extraccr(4), 16#42050004#,
                16#0000062E#, -36993, -162817, -721418027, -2146669428, 16#02000202#, -227420747,
                16#00000083#, 16#00007FF1#, 16#00007FFF#, -250, 16#3FFFFFC0#,
                16#00D0#, 16#8800#);
            check_chk2_noexc_cputest020_record(
                "CHK2.B record6 group4 sub1 runtime020",
                x"0014", x"42050004", 16#02#, 1, 4,
                16#0000062E#, -36993, -162817, -721418027, -2146669428, 16#02000202#, -227420747,
                16#00000083#, 16#00007FF1#, 16#00007FFF#, -250, 16#3FFFFFC0#,
                16#00D0#, 16#8800#);
            check_chk2_exc1_cputest020_record(
                "CHK2.B record82 group4 runtime020",
                x"8000", x"42050006", sr_from_extraccr(4), 16#42050006#,
                16#0000019C#, 2147483645, -2080375044, -2139095160, -2147319166, 2105376, 1671079101,
                16#0000008C#, 16#00007FE9#, 16#0000FFFF#, 2147483490, -1069547521,
                16#00E8#, 16#0800#, 16#279A#);
            check_chk2_exc1_cputest020_record(
                "CHK2.B record170 group4 runtime020",
                x"8004", x"42050008", sr_from_extraccr(4), 16#42050008#,
                16#00000436#, -33153, -233834497, -2147451051, -2147055994, 4210752, 2081657452,
                16#0000007D#, 16#00007FEC#, 16#0000FFFF#, -234, -261121,
                16#00F3#, 16#8800#, 16#F3E0#, 16#0000#);
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group4 sub0 runtime020",
                x"8001", x"4204FFFE", sr_from_cputest_group(16#02#, 0, 4), 16#42050004#, true,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group4 sub1 runtime020",
                x"0011", x"42050002", sr_from_cputest_group(16#02#, 1, 4), 16#42050004#, true,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
            check_chk2_noexc_cputest020_record(
                "CHK2.L record83 group0 sub1 runtime020",
                x"0018", x"42050006", 16#02#, 1, 0,
                16#00000166#, 16#7FFF7F79#, -200282113, -2145419327, -2147319166, 268439568, -927469233,
                16#0000008A#, 16#00007FF5#, 16#00007FFF#, 2147483450, 67108863,
                16#04E8#, 16#E800#, 16#0000#);
            check_chk2_exc1_cputest020_exact(
                "CHK2.L group4 runtime020",
                x"04D0", x"7800", 16#00000022#, sr_from_extraccr(4), true, x"8000");
            check_chk2_exc1_cputest020_record(
                "CHK2.L record83 group4 runtime020",
                x"8008", x"42050006", sr_from_extraccr(4), 16#42050006#,
                16#00000166#, 2147450745, -200282113, -2145419327, -2147319166, 268439568, -927469233,
                16#0000008A#, 16#00007FF5#, 16#00007FFF#, 2147483450, 67108863,
                16#04E8#, 16#E800#, 16#0000#);
            check_chk2_exc1_cputest020_record(
                "CHK2.L record168 group4 runtime020",
                x"8008", x"42050008", sr_from_extraccr(4), 16#42050008#,
                16#00000316#, -35, -311041, -708771691, 460551, 536879136, 0,
                16#0000007E#, 16#00008017#, 16#00007FFF#, 2147483570, -66846721,
                16#04F0#, 16#F800#, 16#8F60#, 16#0000#);
            check_chk2_exc6_cputest020_exact(
                "CHK2.W group4 runtime020",
                x"02D0", x"A800", 16#00000022#, sr_from_extraccr(4), true);
            check_chk2_exc1_cputest020_record(
                "CHK2.W record78 group4 runtime020",
                x"8000", x"42050006", sr_from_extraccr(4), 16#42050006#,
                16#00000154#, -570425345, 1077919743, -2113930096, 197379, 526344, 926253494,
                16#0000008E#, 16#00007FFC#, 16#00007FFF#, -178, -16711681,
                16#02E8#, 16#0800#, 16#42CF#);
            check_chk2_exc1_cputest020_record(
                "CHK2.W record171 group4 runtime020",
                x"8000", x"4205000A", sr_from_extraccr(4), 16#4205000A#,
                16#000002F2#, 2113896315, -1833985, -1073734699, 592137, 8421504, -1899855006,
                16#00000083#, 16#00007FFF#, 16#00007FFF#, -138, -1021,
                16#02F5#, 16#E800#, 16#B170#, 16#0000#, 16#5EF0#);
            check_chk2_noexc_cputest020_record(
                "CHK2.W record78 group0 sub1 runtime020",
                x"0010", x"42050006", 16#02#, 1, 0,
                16#00000154#, -570425345, 16#403FBFFF#, -2113930096, 197379, 526344, 926253494,
                16#0000008E#, 16#00007FFC#, 16#00007FFF#, -178, -16711681,
                16#02E8#, 16#0800#, 16#42CF#, check_pc => false);
            check_jmp_cputest020_case(
                "JMP/0002 record=37 group=1 runtime020",
                sr_from_extraccr(1),
                false);
            check_jmp_cputest020_case(
                "JMP/0002 record=37 group=3 runtime020",
                sr_from_extraccr(3),
                true);
            check_jmp_cputest020_group1_after_record18;
            check_jmp_cputest020_group3_after_record18;
            check_jmp_cputest020_group1_oldvalue_preload;
            check_jmp_cputest020_group3_oldvalue_preload;
            check_jmp_cputest020_same_record_1_3;
            check_jmp_cputest020_cumulative34_37;
            check_jmp_cputest020_precursor_sequence;
            check_chk2_b_cputest020_precursor_chain;
            check_chk2_l_cputest020_precursor_chain;
            check_chk2_w_cputest020_precursor_chain;
        end procedure;

        procedure run_cputest020_runtime_jmp_suite is
        begin
            check_jmp_cputest020_group0_precursor;
            check_jmp_cputest020_case(
                "JMP/0002 record=37 group=1 runtime020",
                sr_from_extraccr(1),
                false);
            check_jmp_cputest020_case(
                "JMP/0002 record=37 group=3 runtime020",
                sr_from_extraccr(3),
                true);
            check_jmp_cputest020_group1_after_record18;
            check_jmp_cputest020_group3_after_record18;
            check_jmp_cputest020_group1_oldvalue_preload;
            check_jmp_cputest020_group3_oldvalue_preload;
            check_jmp_cputest020_same_record_1_3;
            check_jmp_cputest020_cumulative34_37;
            check_jmp_cputest020_precursor_sequence;
        end procedure;

        procedure check_jmp_realhandler_case(case_name : string;
                                             sr_value  : std_logic_vector(15 downto 0)) is
            variable low_b  : std_logic_vector(7 downto 0);
            variable low_w  : std_logic_vector(15 downto 0);
            variable high_b : std_logic_vector(7 downto 0);
        begin
            init_common_no_stubs;
            install_jmp_boot(sr_value);
            run_jmp_mem_case(120000);

            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: " & case_name & " real handlers matched cputest side effects" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " real handlers low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_jsr_stub_case(case_name : string;
                                          sr_value  : std_logic_vector(15 downto 0)) is
            variable low_b  : std_logic_vector(7 downto 0);
            variable low_w  : std_logic_vector(15 downto 0);
            variable high_b : std_logic_vector(7 downto 0);
        begin
            init_common_no_stubs;
            install_trace_jsr_stub;
            install_exc_jsr_stub(11, EXC11_VEC_JSR_ENTRY_ADDR, EXC11_VEC_ADDR, RESULT_EXC11_SP);
            install_exc_jsr_stub(6, EXC6_VEC_JSR_ENTRY_ADDR, EXC6_VEC_ADDR, RESULT_EXC6_SP);
            install_jmp_boot(sr_value);
            run_case(true, true, 120000);

            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: " & case_name & " jsr-stub handlers matched cputest side effects" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & " jsr-stub low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_jmp_exact_chained is
            variable trace_sp : integer;
            variable exc_sp   : integer;
            variable trace_sr : std_logic_vector(15 downto 0);
            variable trace_pc : std_logic_vector(31 downto 0);
            variable low_b    : std_logic_vector(7 downto 0);
            variable low_w    : std_logic_vector(15 downto 0);
            variable high_b   : std_logic_vector(7 downto 0);
            variable vectors_restored : boolean := false;
            variable boot_fetch_seen  : boolean := false;
            variable boot_fetch_count : integer := 0;
            variable stage1_done      : boolean := false;
            variable stage2_done      : boolean := false;
            variable stage3_done      : boolean := false;
            variable stage2_cleared   : boolean := false;
            variable stage3_cleared   : boolean := false;
            variable addr_i           : integer;
            variable exc4_mark        : std_logic_vector(31 downto 0);
            variable exc11_mark       : std_logic_vector(31 downto 0);
        begin
            init_common;
            install_jmp_chain_boots;

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 120000 loop
                wait until rising_edge(clk);

                addr_i := to_integer(unsigned(addr_out));
                exc4_mark := read_long(RESULT_EXC4_SP);
                exc11_mark := read_long(RESULT_EXC11_SP);
                if not boot_fetch_seen and busstate = "00" and FC(1 downto 0) = "10" and
                   addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_seen := true;
                    boot_fetch_count := 1;
                elsif boot_fetch_seen and not vectors_restored and
                      busstate = "00" and FC(1 downto 0) = "10" and
                      addr_i >= BOOT_BASE and addr_i < BOOT_BASE + BOOT_BYTES then
                    boot_fetch_count := boot_fetch_count + 1;
                end if;

                if not vectors_restored and boot_fetch_seen and boot_fetch_count >= 2 then
                    write_long(16#0#, saved_reset_ssp);
                    write_long(16#4#, saved_reset_pc);
                    write_long(4 * 4, std_logic_vector(to_unsigned(EXC4_VEC_ADDR, 32)));
                    write_long(11 * 4, std_logic_vector(to_unsigned(EXC11_VEC_ADDR, 32)));
                    vectors_restored := true;
                end if;

                if vectors_restored then
                    if (not stage1_done) and exc11_mark /= x"00000000" and
                       to_integer(unsigned(exc11_mark)) >= ISP_VALUE - 16#0100# and
                       to_integer(unsigned(exc11_mark)) < MSP_VALUE + 16#0100# then
                        stage1_done := true;
                        report "CHAIN: stage1 exception seen sp=$" & slv_to_hex(exc11_mark) severity note;
                        write_word(16#0000008A#, x"4AFC");
                        write_word(16#0000008C#, x"2048");
                        write_word(16#4204FEFE#, x"CD54");
                        write_long(11 * 4, std_logic_vector(to_unsigned(EXC11_CHAIN3_ADDR, 32)));
                    elsif stage1_done and (not stage2_cleared) and busstate = "00" and
                          FC(1 downto 0) = "10" and addr_i = JMP_STAGE2_PC then
                        report "CHAIN: entered stage2 boot pc=$" & slv_to_hex(std_logic_vector(to_unsigned(addr_i, 32))) severity note;
                        write_long(RESULT_TRACE_SP, x"00000000");
                        write_long(RESULT_EXC4_SP, x"00000000");
                        write_long(RESULT_EXC11_SP, x"00000000");
                        stage2_cleared := true;
                    elsif stage2_cleared and (not stage2_done) and exc4_mark /= x"00000000" and
                          to_integer(unsigned(exc4_mark)) >= ISP_VALUE - 16#0100# and
                          to_integer(unsigned(exc4_mark)) < MSP_VALUE + 16#0100# then
                        stage2_done := true;
                        report "CHAIN: stage2 exception seen sp=$" & slv_to_hex(exc4_mark) severity note;
                    elsif stage2_done and (not stage3_cleared) and busstate = "00" and
                          FC(1 downto 0) = "10" and addr_i = JMP_STAGE3_PC then
                        report "CHAIN: entered stage3 boot pc=$" & slv_to_hex(std_logic_vector(to_unsigned(addr_i, 32))) severity note;
                        write_long(RESULT_TRACE_SP, x"00000000");
                        write_long(RESULT_EXC11_SP, x"00000000");
                        stage3_cleared := true;
                    elsif stage3_cleared and (not stage3_done) and exc11_mark /= x"00000000" and
                          to_integer(unsigned(exc11_mark)) >= ISP_VALUE - 16#0100# and
                          to_integer(unsigned(exc11_mark)) < MSP_VALUE + 16#0100# then
                        stage3_done := true;
                        report "CHAIN: stage3 exception seen sp=$" & slv_to_hex(exc11_mark) severity note;
                        exit;
                    end if;
                end if;
            end loop;

            if stage3_done then
                report "PASS: chained JMP record 37 reached final exception" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: chained JMP record 37 did not complete group 1->2->3 sequence" severity error;
                fail_count := fail_count + 1;
                return;
            end if;

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));
            low_b := read_byte(16#0000008B#);
            low_w := read_word(16#0000008C#);
            high_b := read_byte(16#4204FEFF#);

            if trace_sp /= 0 then
                trace_sr := read_word(trace_sp);
                trace_pc := read_long(trace_sp + 2);
                if trace_sr = x"6000" and trace_pc = x"42006D72" then
                    report "PASS: chained JMP record 37 final trace matched cputest" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: chained JMP record 37 final trace SR=$" & slv_to_hex(trace_sr) &
                           " PC=$" & slv_to_hex(trace_pc) &
                           " expected SR=$6000 PC=$42006D72" severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                report "FAIL: chained JMP record 37 missed final trace handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if exc_sp /= 0 then
                report "PASS: chained JMP record 37 final exception handler hit" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: chained JMP record 37 missed final exception handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if low_b = x"FD" and low_w = x"EB48" and high_b = x"75" then
                report "PASS: chained JMP record 37 memory side effects matched cputest" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: chained JMP record 37 memory side effects low_b=$" & slv_to_hex(low_b) &
                       " low_w=$" & slv_to_hex(low_w) &
                       " high_b=$" & slv_to_hex(high_b) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure run_chk2_bl_exact_suite is
        begin
            for extraccr in group_first to group_last loop
                if extraccr = 4 then
                    check_chk2_exc1_exact(
                        "CHK2.B record1 group" & integer'image(extraccr),
                        x"00D0", x"4800", 16#00000022#, sr_from_extraccr(extraccr), true, x"8004");
                    check_chk2_exc1_exact(
                        "CHK2.L record1 group" & integer'image(extraccr),
                        x"04D0", x"7800", 16#00000022#, sr_from_extraccr(extraccr), true, x"8000");
                elsif ((extraccr >= 5) and (extraccr <= 7)) or (extraccr >= 12) then
                    check_chk2_exc1_exact(
                        "CHK2.B record1 group" & integer'image(extraccr),
                        x"00D0", x"4800", 16#00000022#, sr_from_extraccr(extraccr), false, x"0000");
                    check_chk2_exc1_exact(
                        "CHK2.L record1 group" & integer'image(extraccr),
                        x"04D0", x"7800", 16#00000022#, sr_from_extraccr(extraccr), false, x"0000");
                else
                    check_chk2_noexc_exact(
                        "CHK2.B record1 group" & integer'image(extraccr),
                        x"00D0", x"4800", 16#00000022#, sr_from_extraccr(extraccr));
                    check_chk2_noexc_exact(
                        "CHK2.L record1 group" & integer'image(extraccr),
                        x"04D0", x"7800", 16#00000022#, sr_from_extraccr(extraccr));
                end if;
            end loop;
        end procedure;

        procedure run_chk2_w_exact_suite is
        begin
            for extraccr in group_first to group_last loop
                if (extraccr = 0) or (extraccr = 1) or (extraccr = 8) or (extraccr = 9) then
                    check_chk2_exc6_exact(
                        "CHK2.W record1 group" & integer'image(extraccr),
                        x"02D0", x"A800", 16#00000022#, sr_from_extraccr(extraccr), false);
                else
                    check_chk2_exc6_exact(
                        "CHK2.W record1 group" & integer'image(extraccr),
                        x"02D0", x"A800", 16#00000022#, sr_from_extraccr(extraccr), true);
                end if;
            end loop;
        end procedure;

        procedure run_chk2_b_record21_runtime_suite is
        begin
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group0 sub0 runtime020",
                x"0001", x"4204FFFE", sr_from_cputest_group(16#02#, 0, 0), 16#42050004#, false,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group0 sub1 runtime020",
                x"0011", x"42050002", sr_from_cputest_group(16#02#, 1, 0), 16#42050004#, false,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group4 sub0 runtime020",
                x"8001", x"4204FFFE", sr_from_cputest_group(16#02#, 0, 4), 16#42050004#, true,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
            check_chk2_exc6_cputest020_record(
                "CHK2.B record21 group4 sub1 runtime020",
                x"0011", x"42050002", sr_from_cputest_group(16#02#, 1, 4), 16#42050004#, true,
                16#0000007C#, -1, 16#3FFFFF88#, -16218, 16#00010101#, 16#00020202#, -1431655766,
                16#0000007D#, 16#00008003#, 16#00007FFF#, -218, -256,
                16#00D1#, 16#9800#);
        end procedure;

        procedure run_chk2_b_default_probe_suite is
            variable pc         : integer := BOOT_PC;
            variable trace_sp   : integer;
            variable exc4_sp    : integer;
            variable exc6_sp    : integer;
            variable exc11_sp   : integer;
            variable actual_ccr : std_logic_vector(15 downto 0);
            variable store_seen : boolean;
        begin
            init_common;
            build_common_boot(pc, CHK_USP_VALUE, CHK_FRAME_START);
            emit_movel_imm_dn(pc, 0, 16#00000022#);
            emit_moveq0_d1(pc);
            emit_movel_imm_dn(pc, 2, -1);
            emit_movel_imm_dn(pc, 3, -256);
            emit_movel_imm_dn(pc, 4, 16#FFFF0000#);
            emit_movel_imm_dn(pc, 5, 16#80008080#);
            emit_movel_imm_dn(pc, 6, 16#00010101#);
            emit_movel_imm_dn(pc, 7, 16#AAAAAAAA#);
            emit_movea_imm_an(pc, 0, 16#00000022#);
            emit_movea_imm_an(pc, 1, 16#00000078#);
            emit_movea_imm_an(pc, 2, 16#00007FF0#);
            emit_movea_imm_an(pc, 3, 16#00007FFF#);
            emit_movea_imm_an(pc, 4, -2);
            emit_movea_imm_an(pc, 5, -256);
            emit_movea_imm_an(pc, 6, 16#4204FF00#);
            emit_movea_imm_an(pc, 7, CHK_FRAME_START);
            emit_word(pc, x"4E73");

            write_word(CHK_FRAME_START, x"0000");
            write_long(CHK_FRAME_START + 2, x"42050000");
            write_word(CHK_FRAME_START + 6, x"0000");

            write_byte(16#00000022#, x"0C");
            write_byte(16#00000023#, x"00");
            write_word(16#42050000#, x"00D0");
            write_word(16#42050002#, x"8800");
            write_word(RESULT_NOEXC_CCR, x"FFFF");
            write_word(16#42050004#, x"42F9");
            write_long(16#42050006#, std_logic_vector(to_unsigned(RESULT_NOEXC_CCR, 32)));
            write_word(16#4205000A#, x"4AFC");

            run_until_word_store(RESULT_NOEXC_CCR, store_seen, actual_ccr, 120000);

            trace_sp := to_integer(unsigned(read_long(RESULT_TRACE_SP)));
            exc4_sp := to_integer(unsigned(read_long(RESULT_EXC4_SP)));
            exc6_sp := to_integer(unsigned(read_long(RESULT_EXC6_SP)));
            exc11_sp := to_integer(unsigned(read_long(RESULT_EXC11_SP)));

            if trace_sp = 0 and exc4_sp = 0 and exc6_sp = 0 and exc11_sp = 0 then
                report "PASS: CHK2.B direct A0=$22 lowmem[$22]=$0C,$00 stayed out of handlers" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.B direct A0=$22 lowmem[$22]=$0C,$00 unexpectedly entered a handler" severity error;
                fail_count := fail_count + 1;
            end if;

            if store_seen then
                report "PASS: CHK2.B direct A0=$22 lowmem[$22]=$0C,$00 reached CCR probe" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.B direct A0=$22 lowmem[$22]=$0C,$00 never reached CCR probe" severity error;
                fail_count := fail_count + 1;
            end if;

            if actual_ccr = x"0000" then
                report "PASS: CHK2.B direct A0=$22 lowmem[$22]=$0C,$00 final CCR matched hardware expectation" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: CHK2.B direct A0=$22 lowmem[$22]=$0C,$00 final CCR=$" &
                       slv_to_hex(actual_ccr) & " expected $0000" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

    begin
        case suite_select is
            when 1 =>
                run_chk2_bl_exact_suite;
            when 2 =>
                run_chk2_w_exact_suite;
            when 3 =>
                check_jmp_exact;
            when 4 =>
                check_jmp_exact_chained;
            when 5 =>
                check_jmp_realhandler_case("JMP/0002 record=37 group=3 real-handler", sr_from_extraccr(3));
            when 6 =>
                check_jmp_jsr_stub_case("JMP/0002 record=37 group=3 jsr-stub", sr_from_extraccr(3));
            when 7 =>
                run_cputest020_runtime_suite;
            when 8 =>
                run_cputest020_runtime_jmp_suite;
            when 9 =>
                run_chk2_b_record21_runtime_suite;
            when 10 =>
                run_chk2_b_default_probe_suite;
            when others =>
                run_chk2_bl_exact_suite;
                run_chk2_w_exact_suite;
                check_jmp_exact;
                check_jmp_exact_chained;
        end case;

        report "RESULT: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;
        test_done <= true;
        wait;
    end process;
end architecture;
