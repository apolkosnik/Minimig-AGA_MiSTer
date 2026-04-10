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
    signal dbg_pmmu_tc                : std_logic_vector(31 downto 0);
    signal dbg_pmmu_brief             : std_logic_vector(15 downto 0);
    signal dbg_pmmu_reg_sel           : std_logic_vector(4 downto 0);
    signal dbg_pmmu_reg_we            : std_logic;
    signal dbg_pmmu_reg_part          : std_logic;
    signal dbg_pmmu_busy              : std_logic;
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

    constant CLK_PERIOD : time := 10 ns;
    signal test_done    : boolean := false;
    signal stop_reached : boolean := false;

    constant STACK_ADDR      : integer := 16#1100#;
    constant DISABLE_TC_ADDR : integer := 16#1110#;
    constant ROOT_ADDR       : integer := 16#3000#;
    constant RESULT_ADDR     : integer := 16#3040#;
    constant USER_PAGE_ADDR  : integer := 16#F80000#;
    constant EXPECTED_DATA   : std_logic_vector(31 downto 0) := x"DEADF00D";

    type low_mem_array_t  is array (0 to 32767) of std_logic_vector(15 downto 0);
    type page_mem_array_t is array (0 to 16383) of std_logic_vector(15 downto 0);
    shared variable mem    : low_mem_array_t;
    shared variable f8_mem : page_mem_array_t;

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
            debug_SVmode   => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
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
            debug_stop => open,
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
            debug_pmmu_fault => open,
            debug_trap_format_error => open,
            debug_format_error_rte_word => open,
            debug_format_error_pc => open,
            debug_format_error_addr => open,
            debug_format_error_sr => open,
            debug_pmmu_tc => dbg_pmmu_tc,
            debug_pmmu_tt0 => open,
            debug_pmmu_tt1 => open,
            debug_pmmu_crp_hi => open,
            debug_pmmu_crp_lo => open,
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
               mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= mem'high else x"4E71";

    cpu_mem_write: process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
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
            elsif busstate = "00" and addr_out = x"00000442" then
                stop_reached <= true;
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
            if now > 800 ns and cpu_count < 200 then
                report "CPU: t=" & time'image(now) &
                       " bs=" & slv_to_bits(busstate) &
                       " fc=" & slv_to_bits(fc_out) &
                       " st=" & integer'image(to_integer(unsigned(dbg_state_internal))) &
                       " ss=" & integer'image(to_integer(unsigned(dbg_setstate))) &
                       " ms=" & integer'image(dbg_micro_state) &
                       " nms=" & integer'image(dbg_next_micro_state) &
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
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable actual     : std_logic_vector(31 downto 0);
    begin
        for i in mem'range loop
            mem(i) := x"4E71";
        end loop;
        for i in f8_mem'range loop
            f8_mem(i) := x"0000";
        end loop;

        mem(0) := x"0000";
        mem(1) := x"2000"; -- SSP
        mem(2) := x"0000";
        mem(3) := x"0400"; -- PC

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
        --   FC=6 (supervisor prog.) -> $00000059
        -- The supervisor entries must exist or the CPU faults immediately after MMU enable
        -- while still fetching the following instructions from low memory.
        write_long(ROOT_ADDR + 4,  x"00F80059");
        write_long(ROOT_ADDR + 8,  x"00000059");
        write_long(ROOT_ADDR + 20, x"00000059");
        write_long(ROOT_ADDR + 24, x"00000059");

        pc := 16#0400#;
        emit_word(pc, x"2E7C"); emit_long(pc, x"00001100"); -- MOVEA.L #$1100,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4C00");     -- PMOVE.Q (A7),CRP
        emit_word(pc, x"7001");                              -- MOVEQ #1,D0
        emit_word(pc, x"4E7B"); emit_word(pc, x"0000");     -- MOVEC D0,SFC
        emit_word(pc, x"2E7C"); emit_long(pc, x"00001108"); -- MOVEA.L #$1108,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4000");     -- PMOVE.L (A7),TC
        emit_word(pc, x"F000"); emit_word(pc, x"2400");     -- PFLUSHA
        emit_word(pc, x"207C"); emit_long(pc, x"00000000"); -- MOVEA.L #0,A0
        emit_word(pc, x"0EA8"); emit_word(pc, x"4000"); emit_word(pc, x"0004"); -- MOVES.L (4,A0),D4
        emit_word(pc, x"2E7C"); emit_long(pc, x"00003044"); -- MOVEA.L #$3044,A7
        emit_word(pc, x"2F04");                              -- MOVE.L D4,-(A7)
        emit_word(pc, x"2E7C"); emit_long(pc, x"00001110"); -- MOVEA.L #$1110,A7
        emit_word(pc, x"F017"); emit_word(pc, x"4000");     -- PMOVE.L (A7),TC
        emit_word(pc, x"F000"); emit_word(pc, x"2400");     -- PFLUSHA
        emit_word(pc, x"4E72"); emit_word(pc, x"2700");     -- STOP #$2700

        report "=== mmu.library enable probe regression ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 40000 loop
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
