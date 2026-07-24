-- tb_cacr_clearu.vhd
-- BUG #453 regression - one MOVEC write of CACR with CI+CD set (the AmigaOS
-- CacheClearU() shape, $0909 with both enables) must emit BOTH invalidate
-- operations: an all-scope I-cache op AND an all-scope D-cache op.
-- Pre-fix the self-clear wiped all four command bits at the first clkena_lw,
-- so only the priority-encoder winner (CI) was ever emitted and the D-cache
-- invalidate was silently dropped.
--
-- Also covers CEI+CED ($0404) the same way.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_cacr_clearu is
end entity;

architecture behavioral of tb_cacr_clearu is

    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal test_done : boolean := false;

    signal clkena_in   : std_logic := '1';
    signal data_in     : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write  : std_logic_vector(15 downto 0);
    signal addr_out    : std_logic_vector(31 downto 0);
    signal busstate    : std_logic_vector(1 downto 0);
    signal nWr         : std_logic;
    signal nUDS        : std_logic;
    signal nLDS        : std_logic;
    signal FC          : std_logic_vector(2 downto 0);

    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    signal pmmu_addr_phys     : std_logic_vector(31 downto 0);
    signal pmmu_addr_log      : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;

    signal cache_inv_req    : std_logic;
    signal cache_op_scope   : std_logic_vector(1 downto 0);
    signal cache_op_cache   : std_logic_vector(1 downto 0);
    signal cacr_ie          : std_logic;
    signal cacr_de          : std_logic;

    signal debug_TG68_PC    : std_logic_vector(31 downto 0);
    signal debug_cpu_halted : std_logic;
    signal debug_stop       : std_logic;
    signal debug_pmmu_busy  : std_logic;
    signal debug_pmmu_fault : std_logic;

    signal mem_wait : std_logic := '0';

    -- op observation (phase 0 = after first MOVEC $0909, phase 1 = $0404)
    signal phase        : integer := 0;
    signal saw_i_all    : boolean := false;
    signal saw_d_all    : boolean := false;
    signal saw_i_entry  : boolean := false;
    signal saw_d_entry  : boolean := false;

    type mem_type is array(0 to 8191) of std_logic_vector(15 downto 0);

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        m(0) := x"0000"; m(1) := x"2000";  -- SSP
        m(2) := x"0000"; m(3) := x"0100";  -- PC
        for i in 2 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00C0";
        end loop;
        -- Unexpected trap handler: STOP
        m(96) := x"4E72"; m(97) := x"2700";

        -- Program at $0100 (supervisor throughout)
        m(128) := x"203C"; m(129) := x"0000"; m(130) := x"0101"; -- MOVE.L #$0101,D0 (EI+ED)
        m(131) := x"4E7B"; m(132) := x"0002";                    -- MOVEC D0,CACR
        m(133) := x"4E71"; m(134) := x"4E71";
        m(135) := x"203C"; m(136) := x"0000"; m(137) := x"0909"; -- MOVE.L #$0909,D0 (CI+CD+EI+ED)
        m(138) := x"4E7B"; m(139) := x"0002";                    -- MOVEC D0,CACR  <- CacheClearU
        m(140) := x"4E71"; m(141) := x"4E71"; m(142) := x"4E71"; m(143) := x"4E71";
        -- marker: bump phase via write to $1F00
        m(144) := x"31FC"; m(145) := x"0001"; m(146) := x"1F00"; -- MOVE.W #1,($1F00).W
        m(147) := x"203C"; m(148) := x"0000"; m(149) := x"0505"; -- MOVE.L #$0505,D0 (CEI+CED+EI+ED)
        m(150) := x"4E7B"; m(151) := x"0002";                    -- MOVEC D0,CACR
        m(152) := x"4E71"; m(153) := x"4E71"; m(154) := x"4E71"; m(155) := x"4E71";
        m(156) := x"4E72"; m(157) := x"2700";                    -- STOP #$2700
        return m;
    end function;

    signal mem : mem_type := init_mem;

begin

    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    uut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read => 2, VBR_Stackframe => 2, extAddr_Mode => 2,
            MUL_Mode => 2, DIV_Mode => 2, BitField => 2,
            MUL_Hardware => 1, BarrelShifter => 2
        )
        port map(
            clk => clk, nReset => nReset, clkena_in => clkena_in, data_in => data_in,
            IPL => "111", IPL_autovector => '1', berr => '0', CPU => "10",
            addr_out => addr_out, data_write => data_write, nWr => nWr, nUDS => nUDS, nLDS => nLDS,
            busstate => busstate, longword => open, nResetOut => open, FC => FC, clr_berr => open,
            skipFetch => open, regin_out => open, CACR_out => open, VBR_out => open,
            cache_inv_req => cache_inv_req, cache_op_scope => cache_op_scope,
            cache_op_cache => cache_op_cache, cache_op_addr => open,
            cacr_ie => cacr_ie, cacr_de => cacr_de, cacr_ifreeze => open, cacr_dfreeze => open,
            cacr_ibe => open, cacr_dbe => open, cacr_wa => open,
            pmmu_reg_we => open, pmmu_reg_re => open, pmmu_reg_sel => open, pmmu_reg_wdat => open, pmmu_reg_part => open,
            pmmu_addr_log => pmmu_addr_log, pmmu_addr_phys => pmmu_addr_phys, pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req => pmmu_walker_req, pmmu_walker_we => pmmu_walker_we, pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat, pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data, pmmu_walker_berr => '0',
            debug_SVmode => open, debug_preSVmode => open, debug_FlagsSR_S => open, debug_changeMode => open,
            debug_setopcode => open, debug_exec_directSR => open, debug_exec_to_SR => open,
            debug_pmove_dn_mode => open, debug_pmove_dn_regnum => open, debug_opcode => open,
            debug_state => open, debug_setstate => open, debug_last_opc_read => open, debug_data_read => open,
            debug_direct_data => open, debug_setnextpass => open, debug_TG68_PC => debug_TG68_PC,
            debug_memaddr_reg => open, debug_memaddr_delta => open, debug_oddout => open, debug_decodeOPC => open,
            debug_brief => open, debug_moves_bus_pending => open, debug_moves_writeback_pending => open,
            debug_clkena_lw => open, debug_regfile_d0 => open, debug_regfile_a0 => open,
            debug_fline_context_valid => open, debug_trap_1111 => open, debug_trapmake => open,
            debug_pmmu_brief => open, debug_use_base => open, debug_rf_source_addr => open,
            debug_pmove_ea_latched => open, debug_reg_QA => open, debug_last_data_read => open,
            debug_last_opc_pc => open, debug_getbrief => open, debug_get_2ndopc => open,
            debug_fline_brief_pending => open, debug_fline_opcode_pc => open, debug_exe_PC => open,
            debug_memaddr_delta_rega => open, debug_memaddr_delta_regb => open, debug_addsub_q => open,
            debug_memmaskmux => open, debug_fline_opcode_latch => open, debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open, debug_exec_directPC => open, debug_exec_mem_addsub => open,
            debug_set_addrlong => open, debug_mdelta_src => open, debug_pc_brw => open, debug_pc_word => open,
            debug_regfile_d1 => open, debug_regfile_d2 => open, debug_regfile_d3 => open, debug_regfile_d4 => open,
            debug_regfile_d5 => open, debug_regfile_d6 => open, debug_regfile_d7 => open, debug_regfile_a1 => open,
            debug_regfile_a2 => open, debug_regfile_a3 => open, debug_regfile_a4 => open, debug_regfile_a5 => open,
            debug_regfile_a6 => open, debug_regfile_a7 => open, debug_regfile_we => open, debug_regfile_waddr => open,
            debug_regfile_wdata => open, debug_trap_illegal => open, debug_trap_priv => open,
            debug_trap_addr_error => open, debug_trap_berr => open,
            debug_trap_mmu_berr => open, debug_trap_vector => open,
            debug_pc_add => open, debug_pc_dataa => open, debug_pc_datab => open, debug_pmmu_busy => debug_pmmu_busy,
            debug_cpu_halted => debug_cpu_halted, debug_stop => debug_stop, debug_interrupt => open,
            debug_setendOPC => open, debug_IPL_nr => open, debug_micro_state => open, debug_next_micro_state => open,
            debug_memmask => open, debug_sndOPC => open, debug_pmmu_reg_we => open, debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open, debug_pmmu_reg_wdat => open, debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open, debug_make_berr => open, debug_pmmu_fault => debug_pmmu_fault,
            debug_trap_format_error => open, debug_format_error_rte_word => open, debug_format_error_pc => open,
            debug_format_error_addr => open, debug_format_error_sr => open, debug_pmmu_tc => open,
            debug_pmmu_tt0 => open, debug_pmmu_tt1 => open, debug_pmmu_crp_hi => open, debug_pmmu_crp_lo => open,
            debug_pmmu_srp_hi => open, debug_pmmu_srp_lo => open, debug_pmmu_wstate => open,
            debug_pmmu_atc_buserr => open, debug_pmmu_atc_valid => open,
            debug_pmmu_fault_status => open, debug_pmmu_saved_addr => open,
            debug_pmmu_walk_desc_addr => open, debug_pmmu_walk_desc_data => open,
            debug_pmmu_ptr1_desc_addr => open, debug_pmmu_ptr1_desc_data => open,
            debug_pmmu_ptr2_desc_addr => open, debug_pmmu_ptr2_desc_data => open,
            debug_pmmu_ptr3_desc_addr => open, debug_pmmu_ptr3_desc_data => open,
            debug_pmmu_saved_fc => open
        );

    mem_read: process(pmmu_addr_phys, mem)
    begin
        if unsigned(pmmu_addr_phys(15 downto 0)) < x"4000" then
            data_in <= mem(to_integer(unsigned(pmmu_addr_phys(13 downto 1))));
        else
            data_in <= x"4E71";
        end if;
    end process;

    mem_write: process(clk)
        variable w : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if unsigned(pmmu_addr_phys(15 downto 0)) < x"4000" then
                    w := to_integer(unsigned(pmmu_addr_phys(13 downto 1)));
                    if nUDS = '0' then mem(w)(15 downto 8) <= data_write(15 downto 8); end if;
                    if nLDS = '0' then mem(w)(7 downto 0)  <= data_write(7 downto 0); end if;
                    -- phase marker
                    if pmmu_addr_phys(15 downto 0) = x"1F00" then
                        phase <= 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

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

    clkena_in <= '0' when mem_wait = '1' else '1';

    -- Observe emitted invalidate operations
    op_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '1' and cache_inv_req = '1' then
                if phase = 0 then
                    if cache_op_scope = "10" and cache_op_cache = "10" then
                        saw_i_all <= true;
                    elsif cache_op_scope = "10" and cache_op_cache = "01" then
                        saw_d_all <= true;
                    end if;
                else
                    if cache_op_scope = "00" and cache_op_cache = "10" then
                        saw_i_entry <= true;
                    elsif cache_op_scope = "00" and cache_op_cache = "01" then
                        saw_d_entry <= true;
                    end if;
                end if;
            end if;
        end if;
    end process;

    main_test: process
    begin
        report "=== BUG #453: CACR CI+CD / CEI+CED MUST BOTH EMIT ===" severity note;
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 20000 loop
            wait until rising_edge(clk);
            if debug_cpu_halted = '1' or debug_stop = '1' then
                exit;
            end if;
        end loop;

        if debug_cpu_halted = '1' then
            report "FAIL: cpu_halted" severity failure;
        elsif debug_stop /= '1' then
            report "FAIL: never reached STOP" severity failure;
        else
            if not saw_i_all then
                report "FAIL (BUG #453): CACR $0909 emitted no I-cache all-invalidate"
                       severity failure;
            else
                report "PASS: CI emitted (I-cache all-invalidate)" severity note;
            end if;
            if not saw_d_all then
                report "FAIL (BUG #453): CACR $0909 dropped the D-cache all-invalidate (CacheClearU shape)"
                       severity failure;
            else
                report "PASS: CD emitted (D-cache all-invalidate)" severity note;
            end if;
            if not saw_i_entry then
                report "FAIL (BUG #453): CACR $0505 emitted no I-cache entry-invalidate"
                       severity failure;
            else
                report "PASS: CEI emitted (I-cache entry-invalidate)" severity note;
            end if;
            if not saw_d_entry then
                report "FAIL (BUG #453): CACR $0505 dropped the D-cache entry-invalidate"
                       severity failure;
            else
                report "PASS: CED emitted (D-cache entry-invalidate)" severity note;
            end if;
            report "PASS: BUG #453 regression complete" severity note;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
