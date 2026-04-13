-- tb_mmu_library_enable_probe.vhd
-- Focused reproducer for the mmu.library enable/probe/restore path around
-- mmu.library_V4.asm lines 3992-4039:
--   PMOVE.Q (SP),CRP
--   MOVEC   Dn,SFC
--   PMOVE.L (SP),TC
--   PFLUSHA
--   MOVES.L (4,Ax),Dn
--   PMOVE.L (SP),TC
--   PFLUSHA

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_library_enable_probe is
end entity;

architecture behavior of tb_mmu_library_enable_probe is
    function sl_to_char(v : std_logic) return character is
    begin
        case v is
            when '0' => return '0';
            when '1' => return '1';
            when 'Z' => return 'Z';
            when 'U' => return 'U';
            when 'X' => return 'X';
            when 'W' => return 'W';
            when 'L' => return 'L';
            when 'H' => return 'H';
            when '-' => return '-';
            when others => return '?';
        end case;
    end function;

    function slv_to_bits(value : std_logic_vector) return string is
        variable result : string(1 to value'length);
    begin
        for i in value'range loop
            result(value'length - i) := sl_to_char(value(i));
        end loop;
        return result;
    end function;

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length / 4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length / 4) - 1 loop
            nibble := value(value'length - 1 - i * 4 downto value'length - 4 - i * 4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    signal clk          : std_logic := '0';
    signal nReset       : std_logic := '0';
    signal clkena_in    : std_logic := '1';
    signal data_in      : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write   : std_logic_vector(15 downto 0);
    signal addr_out     : std_logic_vector(31 downto 0);
    signal busstate     : std_logic_vector(1 downto 0);
    signal nWr          : std_logic;
    signal nUDS         : std_logic;
    signal nLDS         : std_logic;
    signal fc_out       : std_logic_vector(2 downto 0);
    signal pmmu_addr_log_out  : std_logic_vector(31 downto 0);
    signal pmmu_addr_phys_out : std_logic_vector(31 downto 0);
    signal dbg_moves_bus_pending      : std_logic;
    signal dbg_moves_writeback_pending : std_logic;
    signal dbg_pmmu_saved_fc          : std_logic_vector(2 downto 0);
    signal dbg_svmode                : std_logic;
    signal dbg_presvmode             : std_logic;
    signal dbg_flagssr_s             : std_logic;
    signal dbg_changemode            : std_logic;
    signal dbg_pmmu_tc                : std_logic_vector(31 downto 0);
    signal dbg_pmmu_crp_hi            : std_logic_vector(31 downto 0);
    signal dbg_pmmu_crp_lo            : std_logic_vector(31 downto 0);
    signal dbg_pmmu_brief             : std_logic_vector(15 downto 0);
    signal dbg_pmmu_reg_sel           : std_logic_vector(4 downto 0);
    signal dbg_pmmu_reg_we            : std_logic;
    signal dbg_pmmu_reg_part          : std_logic;
    signal dbg_pmmu_busy              : std_logic;
    signal dbg_pmmu_fault             : std_logic;
    signal dbg_pmmu_wstate            : std_logic_vector(4 downto 0);
    signal dbg_setnextpass            : std_logic;
    signal dbg_setendopc              : std_logic;
    signal dbg_getbrief               : std_logic;
    signal dbg_fline_brief_pending    : std_logic;
    signal dbg_fline_context_valid    : std_logic;
    signal dbg_opcode                 : std_logic_vector(15 downto 0);
    signal dbg_state_internal         : std_logic_vector(1 downto 0);
    signal dbg_setstate               : std_logic_vector(1 downto 0);
    signal dbg_micro_state            : integer range 0 to 255;
    signal dbg_next_micro_state       : integer range 0 to 255;
    signal dbg_setopcode             : std_logic;
    signal dbg_decodeOPC             : std_logic;
    signal dbg_clkena_lw             : std_logic;
    signal dbg_tg68_pc               : std_logic_vector(31 downto 0);
    signal dbg_exe_pc                : std_logic_vector(31 downto 0);
    signal dbg_memmaskmux            : std_logic_vector(5 downto 0);
    signal dbg_last_opc_read         : std_logic_vector(15 downto 0);
    signal dbg_last_data_read        : std_logic_vector(31 downto 0);
    signal dbg_data_read             : std_logic_vector(31 downto 0);
    signal dbg_direct_data           : std_logic;
    signal dbg_trap_1111             : std_logic;
    signal dbg_trapmake              : std_logic;
    signal dbg_trap_illegal          : std_logic;
    signal dbg_trap_priv             : std_logic;
    signal dbg_trap_addr_error       : std_logic;
    signal dbg_trap_berr             : std_logic;
    signal dbg_stop                  : std_logic;
    signal dbg_regfile_d4            : std_logic_vector(31 downto 0);
    signal dbg_regfile_a0            : std_logic_vector(31 downto 0);
    signal dbg_regfile_a7            : std_logic_vector(31 downto 0);
    signal dbg_regfile_we            : std_logic;
    signal dbg_regfile_waddr         : std_logic_vector(3 downto 0);
    signal dbg_regfile_wdata         : std_logic_vector(31 downto 0);
    signal pmmu_req     : std_logic;
    signal pmmu_we      : std_logic;
    signal pmmu_addr    : std_logic_vector(31 downto 0);
    signal pmmu_wdat    : std_logic_vector(31 downto 0);
    signal pmmu_ack     : std_logic := '0';
    signal pmmu_rdat    : std_logic_vector(31 downto 0) := (others => '0');
    signal clear_monitors : std_logic := '0';
    signal mem_wait     : std_logic := '0';
    signal walker_req_prev : std_logic := '0';
    signal stall_cooldown : integer range 0 to 3 := 0;

    constant CLK_PERIOD : time := 10 ns;
    signal test_done    : boolean := false;
    signal stop_reached : boolean := false;
    signal remapped_fetch_seen : boolean := false;
    signal probe_window_active : boolean := false;
    signal expected_ud1_low_seen : boolean := false;
    signal expected_ud1_high_seen : boolean := false;
    signal unexpected_ud1_seen : boolean := false;
    signal unexpected_ud1_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal rtc_supv_phys_seen : boolean := false;
    signal rtc_supv_wrong_phys_seen : boolean := false;
    signal rtc_supv_phys_addr : std_logic_vector(31 downto 0) := (others => '0');

    constant STACK_ADDR      : integer := 16#1100#;
    constant INVALID_TC_ADDR : integer := 16#1120#;
    constant DISABLE_TC_ADDR : integer := 16#1110#;
    constant ROOT_ADDR       : integer := 16#3000#;
    constant RESULT_ADDR     : integer := 16#3040#;
    constant INVALID_RESULT_ADDR : integer := 16#3050#;
    constant INVALID_HANDLER_ADDR : integer := 16#0500#;
    constant SUPV_PROG_PHYS_BASE : integer := 16#8000#;
    constant USER_PAGE_ADDR  : integer := 16#F80000#;
    constant EXPECTED_DATA   : std_logic_vector(31 downto 0) := x"DEADF00D";
    constant INVALID_TC_VALUE : std_logic_vector(31 downto 0) := x"810F9800";
    constant INVALID_TC_STORED : std_logic_vector(31 downto 0) := x"010F9800";
    constant INVALID_MARKER  : std_logic_vector(31 downto 0) := x"1BADB002";
    constant INVALID_FALLTHRU_MARKER : std_logic_vector(31 downto 0) := x"BAD0EC00";
    constant RTC_SRE_TC_ADDR : integer := 16#1130#;
    constant RTC_CRP_ADDR    : integer := 16#1140#;
    constant RTC_SRP_ADDR    : integer := 16#1150#;
    constant RTC_DISABLE_TC_ADDR : integer := 16#1160#;
    constant RTC_RESULT_ADDR : integer := 16#3060#;
    constant RTC_CRP_ROOT_ADDR : integer := 16#3100#;
    constant RTC_SRP_ROOT_ADDR : integer := 16#3200#;
    constant RTC_EXPECTED_DATA : std_logic_vector(31 downto 0) := x"1234ABCD";
    constant RTC_WRONG_DATA  : std_logic_vector(31 downto 0) := x"89ABCDEF";
    constant RTC_SRE_TC_VALUE : std_logic_vector(31 downto 0) := x"82A08680";

    type low_mem_array_t  is array (0 to 32767) of std_logic_vector(15 downto 0);
    type page_mem_array_t is array (0 to 16383) of std_logic_vector(15 downto 0);
    shared variable mem    : low_mem_array_t;
    shared variable f8_mem : page_mem_array_t;
    shared variable dc_mem : low_mem_array_t;

    procedure emit_word(variable pc : inout integer; w : std_logic_vector(15 downto 0)) is
    begin
        mem(pc / 2) := w;
        pc := pc + 2;
    end procedure;

    procedure emit_long(variable pc : inout integer; v : std_logic_vector(31 downto 0)) is
    begin
        emit_word(pc, v(31 downto 16));
        emit_word(pc, v(15 downto 0));
    end procedure;

    procedure emit_word_at(addr : integer; w : std_logic_vector(15 downto 0)) is
    begin
        mem(addr / 2) := w;
    end procedure;

    procedure emit_long_at(addr : integer; v : std_logic_vector(31 downto 0)) is
    begin
        emit_word_at(addr, v(31 downto 16));
        emit_word_at(addr + 2, v(15 downto 0));
    end procedure;

    impure function read_long(addr : integer) return std_logic_vector is
    begin
        return mem(addr / 2) & mem(addr / 2 + 1);
    end function;

    procedure write_long(addr : integer; v : std_logic_vector(31 downto 0)) is
    begin
        mem(addr / 2) := v(31 downto 16);
        mem(addr / 2 + 1) := v(15 downto 0);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 2,
            extAddr_Mode   => 2,
            MUL_Mode       => 2,
            DIV_Mode       => 2,
            BitField       => 2,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk            => clk,
            nReset         => nReset,
            clkena_in      => clkena_in,
            data_in        => data_in,
            IPL            => "111",
            IPL_autovector => '1',
            berr           => '0',
            CPU            => "10",
            addr_out       => addr_out,
            data_write     => data_write,
            nWr            => nWr,
            nUDS           => nUDS,
            nLDS           => nLDS,
            busstate       => busstate,
            longword       => open,
            nResetOut      => open,
            FC             => fc_out,
            clr_berr       => open,
            skipFetch      => open,
            regin_out      => open,
            CACR_out       => open,
            VBR_out        => open,
            cache_inv_req  => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr  => open,
            pmmu_reg_we    => open,
            pmmu_reg_re    => open,
            pmmu_reg_sel   => open,
            pmmu_reg_wdat  => open,
            pmmu_reg_part  => open,
            pmmu_addr_log  => pmmu_addr_log_out,
            pmmu_addr_phys => pmmu_addr_phys_out,
            pmmu_cache_inhibit => open,
            pmmu_walker_req  => pmmu_req,
            pmmu_walker_we   => pmmu_we,
            pmmu_walker_addr => pmmu_addr,
            pmmu_walker_wdat => pmmu_wdat,
            pmmu_walker_ack  => pmmu_ack,
            pmmu_walker_data => pmmu_rdat,
            pmmu_walker_berr => '0',
            debug_SVmode   => dbg_svmode,
            debug_preSVmode => dbg_presvmode,
            debug_FlagsSR_S => dbg_flagssr_s,
            debug_changeMode => dbg_changemode,
            debug_setopcode => dbg_setopcode,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_opcode => dbg_opcode,
            debug_state => dbg_state_internal,
            debug_setstate => dbg_setstate,
            debug_last_opc_read => dbg_last_opc_read,
            debug_data_read => dbg_data_read,
            debug_direct_data => dbg_direct_data,
            debug_setnextpass => dbg_setnextpass,
            debug_TG68_PC => dbg_tg68_pc,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout => open,
            debug_decodeOPC => dbg_decodeOPC,
            debug_brief => open,
            debug_moves_bus_pending => dbg_moves_bus_pending,
            debug_moves_writeback_pending => dbg_moves_writeback_pending,
            debug_clkena_lw => dbg_clkena_lw,
            debug_regfile_d0 => open,
            debug_regfile_a0 => dbg_regfile_a0,
            debug_fline_context_valid => dbg_fline_context_valid,
            debug_trap_1111 => dbg_trap_1111,
            debug_trapmake => dbg_trapmake,
            debug_pmmu_brief => dbg_pmmu_brief,
            debug_use_base => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA => open,
            debug_last_data_read => dbg_last_data_read,
            debug_last_opc_pc => open,
            debug_getbrief => dbg_getbrief,
            debug_get_2ndopc => open,
            debug_fline_brief_pending => dbg_fline_brief_pending,
            debug_fline_opcode_pc => open,
            debug_exe_PC => dbg_exe_pc,
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
            debug_pc_brw => open,
            debug_pc_word => open,
            debug_regfile_d1 => open,
            debug_regfile_d2 => open,
            debug_regfile_d3 => open,
            debug_regfile_d4 => dbg_regfile_d4,
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
            debug_trap_illegal => dbg_trap_illegal,
            debug_trap_priv => dbg_trap_priv,
            debug_trap_addr_error => dbg_trap_addr_error,
            debug_trap_berr => dbg_trap_berr,
            debug_trap_mmu_berr => open,
            debug_trap_vector => open,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy => dbg_pmmu_busy,
            debug_cpu_halted => open,
            debug_stop => dbg_stop,
            debug_interrupt => open,
            debug_setendOPC => dbg_setendopc,
            debug_IPL_nr => open,
            debug_micro_state => dbg_micro_state,
            debug_next_micro_state => dbg_next_micro_state,
            debug_memmask => open,
            debug_sndOPC => open,
            debug_pmmu_reg_we => dbg_pmmu_reg_we,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => dbg_pmmu_reg_sel,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => dbg_pmmu_reg_part,
            debug_pmmu_reg_rdat => open,
            debug_make_berr => open,
            debug_pmmu_fault => dbg_pmmu_fault,
            debug_trap_format_error => open,
            debug_format_error_rte_word => open,
            debug_format_error_pc => open,
            debug_format_error_addr => open,
            debug_format_error_sr => open,
            debug_pmmu_tc => dbg_pmmu_tc,
            debug_pmmu_tt0 => open,
            debug_pmmu_tt1 => open,
            debug_pmmu_crp_hi => dbg_pmmu_crp_hi,
            debug_pmmu_crp_lo => dbg_pmmu_crp_lo,
            debug_pmmu_srp_hi => open,
            debug_pmmu_srp_lo => open,
            debug_pmmu_wstate => dbg_pmmu_wstate,
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
            debug_pmmu_saved_fc => dbg_pmmu_saved_fc
        );

    data_in <= f8_mem(to_integer(unsigned(addr_out(14 downto 1))))
               when addr_out(23 downto 16) = x"F8" and to_integer(unsigned(addr_out(14 downto 1))) <= f8_mem'high else
               dc_mem(to_integer(unsigned(addr_out(15 downto 1))))
               when addr_out(23 downto 16) = x"DC" and to_integer(unsigned(addr_out(15 downto 1))) <= dc_mem'high else
               mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= mem'high else x"4E71";

    -- Approximate wrapper timing with a minimum one-cycle memory delay plus
    -- PMMU walker stall/cooldown so PMOVE retirement sees non-zero-wait-state behavior.
    mem_wait_gen: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                mem_wait <= '0';
            elsif clkena_in = '1' then
                mem_wait <= '1';
            else
                mem_wait <= '0';
            end if;
        end if;
    end process;

    stall_control: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                walker_req_prev <= '0';
                stall_cooldown <= 0;
            else
                walker_req_prev <= pmmu_req;
                if walker_req_prev = '1' and pmmu_req = '0' then
                    stall_cooldown <= 2;
                elsif stall_cooldown > 0 then
                    stall_cooldown <= stall_cooldown - 1;
                end if;
            end if;
        end if;
    end process;

    clkena_in <= '0' when (pmmu_req = '1'
                           or (dbg_pmmu_busy = '1' and dbg_pmmu_fault = '0')
                           or stall_cooldown > 0
                           or mem_wait = '1')
                 else '1';

    cpu_mem_write: process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if addr_out(23 downto 16) = x"F8" then
                    idx := to_integer(unsigned(addr_out(14 downto 1)));
                    if idx <= f8_mem'high then
                        if nUDS = '0' then
                            f8_mem(idx)(15 downto 8) := data_write(15 downto 8);
                        end if;
                        if nLDS = '0' then
                            f8_mem(idx)(7 downto 0) := data_write(7 downto 0);
                        end if;
                    end if;
                else
                    idx := to_integer(unsigned(addr_out(15 downto 1)));
                    if idx <= mem'high then
                        if nUDS = '0' then
                            mem(idx)(15 downto 8) := data_write(15 downto 8);
                        end if;
                        if nLDS = '0' then
                            mem(idx)(7 downto 0) := data_write(7 downto 0);
                        end if;
                    end if;
                end if;
            end if;

            if clear_monitors = '1' then
                stop_reached <= false;
                remapped_fetch_seen <= false;
                probe_window_active <= false;
                expected_ud1_low_seen <= false;
                expected_ud1_high_seen <= false;
                unexpected_ud1_seen <= false;
                unexpected_ud1_addr <= (others => '0');
                rtc_supv_phys_seen <= false;
                rtc_supv_wrong_phys_seen <= false;
                rtc_supv_phys_addr <= (others => '0');
            else
                if dbg_pmmu_tc = x"81F09800" then
                    probe_window_active <= true;
                elsif dbg_pmmu_tc(31) = '0' then
                    probe_window_active <= false;
                end if;

                if busstate = "00" and dbg_tg68_pc = x"00000442" then
                    stop_reached <= true;
                end if;

                if busstate = "00" and dbg_tg68_pc = x"0000041A" and addr_out = x"0000841A" then
                    remapped_fetch_seen <= true;
                end if;

                if probe_window_active and busstate = "10" and fc_out = "001" then
                    if pmmu_addr_log_out = x"00000004" and pmmu_addr_phys_out = x"00F80004" then
                        expected_ud1_low_seen <= true;
                    elsif pmmu_addr_log_out = x"00000006" and pmmu_addr_phys_out = x"00F80006" then
                        expected_ud1_high_seen <= true;
                    elsif not unexpected_ud1_seen then
                        unexpected_ud1_seen <= true;
                        unexpected_ud1_addr <= pmmu_addr_log_out;
                    end if;
                end if;

                if busstate = "10" and fc_out = "101" and pmmu_addr_log_out = x"00DC0000" then
                    rtc_supv_phys_addr <= pmmu_addr_phys_out;
                    if pmmu_addr_phys_out = x"00DC0000" then
                        rtc_supv_phys_seen <= true;
                    elsif pmmu_addr_phys_out = x"00F80000" then
                        rtc_supv_wrong_phys_seen <= true;
                    end if;
                end if;
            end if;
        end if;
    end process;

    debug_trace: process(clk)
        variable cpu_count   : integer := 0;
        variable pmmu_count  : integer := 0;
        variable moves_count : integer := 0;
        variable reg_count   : integer := 0;
    begin
        if rising_edge(clk) then
            if now > 2800 ns and now < 3200 ns and cpu_count < 80 then
                report "CPU: t=" & time'image(now) &
                       " bs=" & slv_to_bits(busstate) &
                       " fc=" & slv_to_bits(fc_out) &
                       " sfc=" & slv_to_bits(dbg_pmmu_saved_fc) &
                       " st=" & integer'image(to_integer(unsigned(dbg_state_internal))) &
                       " ss=" & integer'image(to_integer(unsigned(dbg_setstate))) &
                       " ms=" & integer'image(dbg_micro_state) &
                       " nms=" & integer'image(dbg_next_micro_state) &
                       " sv=" & std_logic'image(dbg_svmode) &
                       " psv=" & std_logic'image(dbg_presvmode) &
                       " fs=" & std_logic'image(dbg_flagssr_s) &
                       " cm=" & std_logic'image(dbg_changemode) &
                       " so=" & std_logic'image(dbg_setopcode) &
                       " dec=" & std_logic'image(dbg_decodeOPC) &
                       " clw=" & std_logic'image(dbg_clkena_lw) &
                       " gbr=" & std_logic'image(dbg_getbrief) &
                       " fbp=" & std_logic'image(dbg_fline_brief_pending) &
                       " snp=" & std_logic'image(dbg_setnextpass) &
                       " eop=" & std_logic'image(dbg_setendopc) &
                       " tm=" & std_logic'image(dbg_trapmake) &
                       " f11=" & std_logic'image(dbg_trap_1111) &
                       " ill=" & std_logic'image(dbg_trap_illegal) &
                       " prv=" & std_logic'image(dbg_trap_priv) &
                       " aerr=" & std_logic'image(dbg_trap_addr_error) &
                       " berr=" & std_logic'image(dbg_trap_berr) &
                       " fl=" & std_logic'image(dbg_fline_context_valid) &
                       " pb=" & std_logic'image(dbg_pmmu_busy) &
                       " ws=" & slv_to_bits(dbg_pmmu_wstate) &
                       " opc=$" & slv_to_hex(dbg_opcode) &
                       " brief=$" & slv_to_hex(dbg_pmmu_brief) &
                       " lor=$" & slv_to_hex(dbg_last_opc_read) &
                       " ldr=$" & slv_to_hex(dbg_last_data_read) &
                       " dr=$" & slv_to_hex(dbg_data_read) &
                       " dd=" & std_logic'image(dbg_direct_data) &
                       " din=$" & slv_to_hex(data_in) &
                       " pc=$" & slv_to_hex(dbg_tg68_pc) &
                       " epc=$" & slv_to_hex(dbg_exe_pc) &
                       " plog=$" & slv_to_hex(pmmu_addr_log_out) &
                       " pphy=$" & slv_to_hex(pmmu_addr_phys_out) &
                       " mm=" & slv_to_bits(dbg_memmaskmux) &
                       " addr=" & slv_to_bits(addr_out) &
                       " nWr=" & std_logic'image(nWr) severity note;
                cpu_count := cpu_count + 1;
            end if;
            if now > 100 ns and pmmu_count < 80 and pmmu_req = '1' then
                report "PMMU: t=" & time'image(now) &
                       " we=" & std_logic'image(pmmu_we) &
                       " addr=" & slv_to_bits(pmmu_addr) &
                       " wdat=" & slv_to_bits(pmmu_wdat) &
                       " saved_fc=" & slv_to_bits(dbg_pmmu_saved_fc) &
                       " brief=$" & slv_to_hex(dbg_pmmu_brief) &
                       " regsel=" & slv_to_bits(dbg_pmmu_reg_sel) &
                       " regwe=" & std_logic'image(dbg_pmmu_reg_we) &
                       " part=" & std_logic'image(dbg_pmmu_reg_part) &
                       " tc=$" & slv_to_hex(dbg_pmmu_tc) severity note;
                pmmu_count := pmmu_count + 1;
            end if;
            if now > 800 ns and moves_count < 80 and
               (dbg_moves_bus_pending = '1' or dbg_moves_writeback_pending = '1') then
                report "MOVES: t=" & time'image(now) &
                       " bus_pending=" & std_logic'image(dbg_moves_bus_pending) &
                       " wb_pending=" & std_logic'image(dbg_moves_writeback_pending) &
                       " fc=" & slv_to_bits(fc_out) &
                       " addr=" & slv_to_bits(addr_out) severity note;
                moves_count := moves_count + 1;
            end if;
            if now > 800 ns and reg_count < 200 and dbg_regfile_we = '1' then
                report "REG: t=" & time'image(now) &
                       " waddr=" & slv_to_bits(dbg_regfile_waddr) &
                       " wdata=$" & slv_to_hex(dbg_regfile_wdata) &
                       " a0=$" & slv_to_hex(dbg_regfile_a0) &
                       " a7=$" & slv_to_hex(dbg_regfile_a7) &
                       " d4=$" & slv_to_hex(dbg_regfile_d4) severity note;
                reg_count := reg_count + 1;
            end if;
        end if;
    end process;

    pmmu_mem_model: process(clk)
        variable word_addr : integer;
    begin
        if rising_edge(clk) then
            pmmu_ack <= '0';
            if pmmu_req = '1' then
                if pmmu_addr(23 downto 16) = x"F8" then
                    word_addr := to_integer(unsigned(pmmu_addr(14 downto 1)));
                    if word_addr + 1 <= f8_mem'high then
                        if pmmu_we = '1' then
                            f8_mem(word_addr) := pmmu_wdat(31 downto 16);
                            f8_mem(word_addr + 1) := pmmu_wdat(15 downto 0);
                        end if;
                        pmmu_rdat <= f8_mem(word_addr) & f8_mem(word_addr + 1);
                    else
                        pmmu_rdat <= (others => '0');
                    end if;
                else
                    word_addr := to_integer(unsigned(pmmu_addr(15 downto 1)));
                    if word_addr + 1 <= mem'high then
                        if pmmu_we = '1' then
                            mem(word_addr) := pmmu_wdat(31 downto 16);
                            mem(word_addr + 1) := pmmu_wdat(15 downto 0);
                        end if;
                        pmmu_rdat <= mem(word_addr) & mem(word_addr + 1);
                    else
                        pmmu_rdat <= (others => '0');
                    end if;
                end if;
                pmmu_ack <= '1';
            end if;
        end if;
    end process;

    test: process
        variable pc         : integer;
        variable phys_pc    : integer;
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable actual     : std_logic_vector(31 downto 0);
        procedure init_mem_defaults is
        begin
            for i in mem'range loop
                mem(i) := x"4E71";
            end loop;
            for i in f8_mem'range loop
                f8_mem(i) := x"0000";
            end loop;
            for i in dc_mem'range loop
                dc_mem(i) := x"0000";
            end loop;

            mem(0) := x"0000";
            mem(1) := x"2000"; -- SSP
            mem(2) := x"0000";
            mem(3) := x"0400"; -- PC
        end procedure;
    begin
        init_mem_defaults;

        write_long(INVALID_TC_ADDR, INVALID_TC_VALUE);
        write_long(INVALID_RESULT_ADDR, x"BAADF00D");

        pc := 16#0400#;
        emit_word(pc, x"2E7C"); emit_long(pc, std_logic_vector(to_unsigned(INVALID_TC_ADDR, 32))); -- MOVEA.L #invalid_tc,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4000");     -- PMOVE.L (A7),TC
        emit_word(pc, x"F000"); emit_word(pc, x"2400");     -- PFLUSHA
        emit_word(pc, x"23FC"); emit_long(pc, INVALID_MARKER); emit_long(pc, std_logic_vector(to_unsigned(INVALID_RESULT_ADDR, 32)));
        emit_word(pc, x"60FE");                              -- BRA.S * (stay alive if we get here)

        report "=== invalid TC config exception control ===" severity note;

        clear_monitors <= '1';
        nReset <= '0';
        wait for 100 ns;
        clear_monitors <= '0';
        nReset <= '1';

        for i in 0 to 12000 loop
            wait until rising_edge(clk);
            exit when read_long(INVALID_RESULT_ADDR) = INVALID_MARKER;
        end loop;

        actual := read_long(INVALID_RESULT_ADDR);
        if actual = INVALID_MARKER then
            report "PASS: invalid TC stayed rejected and MMU remained disabled" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: invalid TC path did not complete, got=$" & slv_to_hex(actual) severity error;
            fail_count := fail_count + 1;
        end if;

        if dbg_pmmu_tc = INVALID_TC_STORED then
            report "PASS: invalid TC stored with E cleared $" & slv_to_hex(INVALID_TC_STORED) severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: invalid TC stored as $" & slv_to_hex(dbg_pmmu_tc) &
                   " expected $" & slv_to_hex(INVALID_TC_STORED) severity error;
            fail_count := fail_count + 1;
        end if;

        if dbg_pmmu_tc(31) = '0' then
            report "PASS: invalid TC cleared E bit in register image" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: invalid TC did not clear TC.E in register image" severity error;
            fail_count := fail_count + 1;
        end if;

        clear_monitors <= '1';
        nReset <= '0';
        wait for 100 ns;
        clear_monitors <= '0';
        init_mem_defaults;

        write_long(STACK_ADDR + 0, x"80000002");
        write_long(STACK_ADDR + 4, std_logic_vector(to_unsigned(ROOT_ADDR, 32)));
        write_long(INVALID_TC_ADDR, INVALID_TC_VALUE);
        write_long(INVALID_RESULT_ADDR, x"BAADF00D");

        pc := 16#0400#;
        emit_word(pc, x"2E7C"); emit_long(pc, std_logic_vector(to_unsigned(STACK_ADDR, 32))); -- MOVEA.L #stack,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4C00");     -- PMOVE.Q (A7),CRP
        emit_word(pc, x"2E7C"); emit_long(pc, std_logic_vector(to_unsigned(INVALID_TC_ADDR, 32))); -- MOVEA.L #invalid_tc,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4000");     -- PMOVE.L (A7),TC
        emit_word(pc, x"F000"); emit_word(pc, x"2400");     -- PFLUSHA
        emit_word(pc, x"23FC"); emit_long(pc, INVALID_MARKER); emit_long(pc, std_logic_vector(to_unsigned(INVALID_RESULT_ADDR, 32)));
        emit_word(pc, x"60FE");                              -- BRA.S * (stay alive if we get here)

        report "=== invalid TC after CRP load config exception control ===" severity note;

        nReset <= '1';

        for i in 0 to 12000 loop
            wait until rising_edge(clk);
            exit when read_long(INVALID_RESULT_ADDR) = INVALID_MARKER;
        end loop;

        actual := read_long(INVALID_RESULT_ADDR);
        if actual = INVALID_MARKER then
            report "PASS: invalid TC after CRP stayed rejected and MMU remained disabled" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: invalid TC after CRP path did not complete, got=$" & slv_to_hex(actual) severity error;
            fail_count := fail_count + 1;
        end if;

        if dbg_pmmu_crp_hi = x"80000002" and dbg_pmmu_crp_lo = std_logic_vector(to_unsigned(ROOT_ADDR, 32)) then
            report "PASS: PMOVE.Q (A7),CRP loaded expected root pointer under wait states" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: CRP loaded as hi=$" & slv_to_hex(dbg_pmmu_crp_hi) &
                   " lo=$" & slv_to_hex(dbg_pmmu_crp_lo) severity error;
            fail_count := fail_count + 1;
        end if;

        if dbg_pmmu_tc = INVALID_TC_STORED and dbg_pmmu_tc(31) = '0' then
            report "PASS: invalid TC remained rejected after CRP load" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: invalid TC after CRP stored as $" & slv_to_hex(dbg_pmmu_tc) severity error;
            fail_count := fail_count + 1;
        end if;

        clear_monitors <= '1';
        nReset <= '0';
        wait for 100 ns;
        clear_monitors <= '0';
        init_mem_defaults;

        write_long(STACK_ADDR + 0, x"80000002");
        write_long(STACK_ADDR + 4, std_logic_vector(to_unsigned(ROOT_ADDR, 32)));
        write_long(STACK_ADDR + 8, x"81F09800");
        write_long(DISABLE_TC_ADDR, x"00000000");
        write_long(RESULT_ADDR, x"BAADF00D");
        f8_mem(2) := EXPECTED_DATA(31 downto 16);
        f8_mem(3) := EXPECTED_DATA(15 downto 0);

        -- Exact mmu.library root layout for TC=$81F09800 with FCL=1:
        --   FC=1 (user data)        -> $00F80059 so MOVES via SFC=1 reads from $00F80004
        --   FC=2 (user program)     -> $00000059
        --   FC=5 (supervisor data)  -> $00000059
        --   FC=6 (supervisor prog.) -> $00008059
        -- FC=6 intentionally remaps the first post-enable supervisor fetches to
        -- physical $8000 so this bench catches stale or untranslated fetches.
        write_long(ROOT_ADDR + 4,  x"00F80059");
        write_long(ROOT_ADDR + 8,  x"00000059");
        write_long(ROOT_ADDR + 20, x"00000059");
        write_long(ROOT_ADDR + 24, x"00008059");

        pc := 16#0400#;
        emit_word(pc, x"2E7C"); emit_long(pc, x"00001100"); -- MOVEA.L #$1100,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4C00");     -- PMOVE.Q (A7),CRP
        emit_word(pc, x"7001");                              -- MOVEQ #1,D0
        emit_word(pc, x"4E7B"); emit_word(pc, x"0000");     -- MOVEC D0,SFC
        emit_word(pc, x"2E7C"); emit_long(pc, x"00001108"); -- MOVEA.L #$1108,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4000");     -- PMOVE.L (A7),TC
        emit_word(pc, x"4AFC");                              -- ILLEGAL if FC=6 fetch does not remap
        phys_pc := SUPV_PROG_PHYS_BASE + 16#041A#;
        emit_word_at(phys_pc + 16#00#, x"F000"); emit_word_at(phys_pc + 16#02#, x"2400"); -- PFLUSHA
        emit_word_at(phys_pc + 16#04#, x"207C"); emit_long_at(phys_pc + 16#06#, x"00000000"); -- MOVEA.L #0,A0
        emit_word_at(phys_pc + 16#0A#, x"0EA8"); emit_word_at(phys_pc + 16#0C#, x"4000"); emit_word_at(phys_pc + 16#0E#, x"0004"); -- MOVES.L (4,A0),D4
        emit_word_at(phys_pc + 16#10#, x"2E7C"); emit_long_at(phys_pc + 16#12#, x"00003044"); -- MOVEA.L #$3044,A7
        emit_word_at(phys_pc + 16#16#, x"2F04"); -- MOVE.L D4,-(A7)
        emit_word_at(phys_pc + 16#18#, x"2E7C"); emit_long_at(phys_pc + 16#1A#, x"00001110"); -- MOVEA.L #$1110,A7
        emit_word_at(phys_pc + 16#1E#, x"F017"); emit_word_at(phys_pc + 16#20#, x"4000"); -- PMOVE.L (A7),TC
        emit_word_at(phys_pc + 16#22#, x"F000"); emit_word_at(phys_pc + 16#24#, x"2400"); -- PFLUSHA
        emit_word_at(phys_pc + 16#26#, x"4E72"); emit_word_at(phys_pc + 16#28#, x"2700"); -- STOP #$2700

        report "=== mmu.library enable probe regression ===" severity note;

        nReset <= '1';

        for i in 0 to 80000 loop
            wait until rising_edge(clk);
            exit when stop_reached;
        end loop;

        if not stop_reached then
            report "FAIL: timed out before STOP" severity error;
            fail_count := fail_count + 1;
        end if;

        actual := read_long(RESULT_ADDR);
        if actual = EXPECTED_DATA then
            report "PASS: MOVES.L probe read translated data" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: MOVES.L probe expected=$" & slv_to_hex(EXPECTED_DATA) &
                   " got=$" & slv_to_hex(actual) severity error;
            fail_count := fail_count + 1;
        end if;

        if remapped_fetch_seen then
            report "PASS: first post-enable supervisor fetch used remapped physical address" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: supervisor fetch after MMU enable did not hit remapped FC=6 page" severity error;
            fail_count := fail_count + 1;
        end if;

        if expected_ud1_low_seen and expected_ud1_high_seen then
            report "PASS: probe window saw intended FC=1 MOVES accesses at logical $00000004/$00000006" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: probe window missed intended FC=1 MOVES beat(s) at logical $00000004/$00000006" severity error;
            fail_count := fail_count + 1;
        end if;

        if not unexpected_ud1_seen then
            report "PASS: no stray FC=1 translations occurred during probe window" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: stray FC=1 translation observed during probe window at logical $" &
                   slv_to_hex(unexpected_ud1_addr) severity error;
            fail_count := fail_count + 1;
        end if;

        clear_monitors <= '1';
        nReset <= '0';
        wait for 100 ns;
        clear_monitors <= '0';
        init_mem_defaults;

        write_long(RTC_CRP_ADDR + 0, x"80000002");
        write_long(RTC_CRP_ADDR + 4, std_logic_vector(to_unsigned(RTC_CRP_ROOT_ADDR, 32)));
        write_long(RTC_SRP_ADDR + 0, x"80000002");
        write_long(RTC_SRP_ADDR + 4, std_logic_vector(to_unsigned(RTC_SRP_ROOT_ADDR, 32)));
        write_long(RTC_SRE_TC_ADDR, RTC_SRE_TC_VALUE);
        write_long(RTC_DISABLE_TC_ADDR, x"00000000");
        write_long(RTC_RESULT_ADDR, x"BAADF00D");
        write_long(RTC_CRP_ROOT_ADDR + 0, x"001C0061"); -- 00DC0000 -> 00F80000 via CRP
        write_long(RTC_SRP_ROOT_ADDR + 0, x"00000061"); -- 00DC0000 -> 00DC0000 via SRP
        f8_mem(0) := RTC_WRONG_DATA(31 downto 16);
        f8_mem(1) := RTC_WRONG_DATA(15 downto 0);
        dc_mem(0) := RTC_EXPECTED_DATA(31 downto 16);
        dc_mem(1) := RTC_EXPECTED_DATA(15 downto 0);

        pc := 16#0400#;
        emit_word(pc, x"2E7C"); emit_long(pc, std_logic_vector(to_unsigned(RTC_CRP_ADDR, 32))); -- MOVEA.L #crp,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4C00");     -- PMOVE.Q (A7),CRP
        emit_word(pc, x"2E7C"); emit_long(pc, std_logic_vector(to_unsigned(RTC_SRP_ADDR, 32))); -- MOVEA.L #srp,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4800");     -- PMOVE.Q (A7),SRP
        emit_word(pc, x"2E7C"); emit_long(pc, std_logic_vector(to_unsigned(RTC_SRE_TC_ADDR, 32))); -- MOVEA.L #tc,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4000");     -- PMOVE.L (A7),TC
        emit_word(pc, x"F000"); emit_word(pc, x"2400");     -- PFLUSHA
        emit_word(pc, x"2839"); emit_long(pc, x"00DC0000"); -- MOVE.L $00DC0000,D4
        emit_word(pc, x"23C4"); emit_long(pc, std_logic_vector(to_unsigned(RTC_RESULT_ADDR, 32))); -- MOVE.L D4,result
        emit_word(pc, x"2E7C"); emit_long(pc, std_logic_vector(to_unsigned(RTC_DISABLE_TC_ADDR, 32))); -- MOVEA.L #tc0,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4000");     -- PMOVE.L (A7),TC
        emit_word(pc, x"F000"); emit_word(pc, x"2400");     -- PFLUSHA
        emit_word(pc, x"4E72"); emit_word(pc, x"2700");     -- STOP #$2700

        report "=== supervisor RTC via SRP regression ===" severity note;

        nReset <= '1';

        for i in 0 to 50000 loop
            wait until rising_edge(clk);
            exit when dbg_stop = '1';
        end loop;

        actual := read_long(RTC_RESULT_ADDR);
        if actual = RTC_EXPECTED_DATA then
            report "PASS: supervisor data read at logical $00DC0000 used SRP mapping" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: supervisor data read at logical $00DC0000 expected=$" &
                   slv_to_hex(RTC_EXPECTED_DATA) & " got=$" & slv_to_hex(actual) severity error;
            fail_count := fail_count + 1;
        end if;

        if rtc_supv_phys_seen then
            report "PASS: supervisor data translation reached physical $00DC0000" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: supervisor data translation did not hit physical $00DC0000, last=$" &
                   slv_to_hex(rtc_supv_phys_addr) severity error;
            fail_count := fail_count + 1;
        end if;

        if not rtc_supv_wrong_phys_seen then
            report "PASS: supervisor data translation avoided CRP's $00F80000 mapping" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: supervisor data translation incorrectly used CRP-style physical $00F80000" severity error;
            fail_count := fail_count + 1;
        end if;

        test_done <= true;

        if fail_count = 0 then
            report "RESULT: " & integer'image(pass_count) & " passed, 0 failed" severity note;
        else
            assert false report "RESULT: " & integer'image(pass_count) & " passed, " &
                                 integer'image(fail_count) & " failed" severity failure;
        end if;
        wait;
    end process;
end architecture;
