-- tb_mmu_restart_moves_dfc.vhd
-- Regression for the live NetBSD-style failure shape: supervisor code uses
-- MOVES.B with DFC=1 to write user logical $1DFFFFF5. The target walks through
-- CRP=$4FAA6000, so the first root descriptor access must be $4FAA6074. The
-- bus-error frame stacks on an SRE=1 supervisor stack translated through
-- SRP=$4052C000, the handler repairs an indirect target descriptor, PFLUSHes,
-- and executes an unmodified RTE. The restarted MOVES.B must perform exactly
-- one byte write to the repaired physical page and must not corrupt the CRP
-- root descriptor address to the hardware-captured $4FFF6074 pattern.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_mmu_restart_moves_dfc is
end entity;

architecture behavioral of tb_mmu_restart_moves_dfc is

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
        variable v : std_logic_vector(value'length - 1 downto 0);
    begin
        v := value;
        for i in 0 to (v'length/4 - 1) loop
            nibble := v(v'length - 1 - i*4 downto v'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    function is_x(value : std_logic_vector) return boolean is
    begin
        for i in value'range loop
            if value(i) /= '0' and value(i) /= '1' then
                return true;
            end if;
        end loop;
        return false;
    end function;

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
    signal pmmu_walker_berr : std_logic := '0';

    signal pmmu_addr_phys     : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;
    signal pmmu_addr_log      : std_logic_vector(31 downto 0);

    signal debug_TG68_PC       : std_logic_vector(31 downto 0);
    signal debug_trap_berr     : std_logic;
    signal debug_trap_mmu_berr : std_logic;
    signal debug_trap_addr_error : std_logic;
    signal debug_trap_vector   : std_logic_vector(31 downto 0);
    signal debug_pmmu_fault    : std_logic;
    signal debug_pmmu_busy     : std_logic;
    signal debug_cpu_halted    : std_logic;
    signal debug_pmmu_fault_status : std_logic_vector(15 downto 0);
    signal debug_pmmu_saved_addr   : std_logic_vector(31 downto 0);
    signal debug_pmmu_walk_desc_addr : std_logic_vector(31 downto 0);
    signal debug_pmmu_walk_desc_data : std_logic_vector(31 downto 0);
    signal debug_pmmu_ptr1_desc_addr : std_logic_vector(31 downto 0);
    signal debug_pmmu_ptr1_desc_data : std_logic_vector(31 downto 0);
    signal debug_pmmu_ptr2_desc_addr : std_logic_vector(31 downto 0);
    signal debug_pmmu_ptr2_desc_data : std_logic_vector(31 downto 0);
    signal debug_pmmu_ptr3_desc_addr : std_logic_vector(31 downto 0);
    signal debug_pmmu_ptr3_desc_data : std_logic_vector(31 downto 0);
    signal debug_regfile_d0 : std_logic_vector(31 downto 0);
    signal debug_regfile_d2 : std_logic_vector(31 downto 0);
    signal debug_regfile_a0 : std_logic_vector(31 downto 0);
    signal debug_stop      : std_logic;

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';
    signal saw_handler_pc  : boolean := false;
    signal saw_done_marker : boolean := false;
    signal saw_crp_root_desc : boolean := false;
    signal saw_corrupt_crp_root_desc : boolean := false;

    signal crp_root_desc : std_logic_vector(31 downto 0) := x"4FAA7002";
    signal crp_ptr1_desc : std_logic_vector(31 downto 0) := x"4FAA8002";
    signal crp_indirect_desc : std_logic_vector(31 downto 0) := x"00007002";
    signal srp_low_root_desc : std_logic_vector(31 downto 0) := x"00006802";
    signal srp_stack_root_desc : std_logic_vector(31 downto 0) := x"00006902";

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        -- Reset vectors
        m(0) := x"0000"; m(1) := x"2000";
        m(2) := x"0000"; m(3) := x"0100";
        m(4) := x"0000"; m(5) := x"0080"; -- vector 2
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00C0";
        end loop;

        -- Vector 2 handler: mark entry, save frame base, repair the indirect
        -- target descriptor for $1DFFFFF5, PFLUSH that page, RTE unmodified.
        m(64) := x"23FC"; m(65) := x"0000"; m(66) := x"0002"; m(67) := x"0000"; m(68) := x"1F00";
        m(69) := x"23CF"; m(70) := x"0000"; m(71) := x"1F24"; -- MOVE.L A7,$1F24.L
        m(72) := x"23FC"; m(73) := x"0000"; m(74) := x"7C61"; -- MOVE.L #$00007C61,$7000.L
        m(75) := x"0000"; m(76) := x"7000";
        m(77) := x"227C"; m(78) := x"1DFF"; m(79) := x"FFF5"; -- MOVEA.L #$1DFFFFF5,A1
        m(80) := x"F011"; m(81) := x"3810";                   -- PFLUSH #0,#0,(A1)
        m(82) := x"4E73";                                     -- RTE

        -- Unexpected trap handler
        m(96) := x"23FC"; m(97) := x"00FF"; m(98) := x"0000";
        m(99) := x"0000"; m(100) := x"1F00";
        m(101) := x"4E72"; m(102) := x"2700";

        -- Program: load live-trace CRP/SRP, enable MMU, set DFC=1, put SSP
        -- on an SRP-translated supervisor stack, then fault a MOVES.B copyout
        -- write through CRP. The post-RTE restart writes the byte and reaches
        -- the done marker.
        m(128) := x"2E7C"; m(129) := x"0000"; m(130) := x"1080";
        m(131) := x"F017"; m(132) := x"4C00";
        m(133) := x"2E7C"; m(134) := x"0000"; m(135) := x"1088";
        m(136) := x"F017"; m(137) := x"4800";
        m(138) := x"F000"; m(139) := x"2400";
        m(140) := x"F038"; m(141) := x"4000"; m(142) := x"1090";
        m(143) := x"4E71"; m(144) := x"4E71";
        m(145) := x"7001";                                     -- MOVEQ #1,D0
        m(146) := x"4E7B"; m(147) := x"0001";                   -- MOVEC D0,DFC
        m(148) := x"243C"; m(149) := x"1234"; m(150) := x"56A5"; -- MOVE.L #$123456A5,D2
        m(151) := x"2E7C"; m(152) := x"0BAF"; m(153) := x"A000"; -- MOVEA.L #$0BAFA000,A7
        m(154) := x"0E39"; m(155) := x"2800";                   -- MOVES.B D2,($1DFFFFF5).L
        m(156) := x"1DFF"; m(157) := x"FFF5";
        m(158) := x"23FC"; m(159) := x"C0DE"; m(160) := x"700D"; -- MOVE.L #$C0DE700D,$1F2C.L
        m(161) := x"0000"; m(162) := x"1F2C";
        m(163) := x"60FE";                                     -- BRA.S *

        -- CRP / SRP
        m(2112) := x"8000"; m(2113) := x"0002"; m(2114) := x"4FAA"; m(2115) := x"6000";
        m(2116) := x"8000"; m(2117) := x"0002"; m(2118) := x"4052"; m(2119) := x"C000";
        m(2120) := x"82A0"; m(2121) := x"8680";

        -- SRP low tree for vectors/code/handler/result/PTE target:
        -- high SRP root slot 0 is supplied by the walker model below and
        -- points here to table $6800.
        m(13312) := x"0000"; m(13313) := x"6E02";
        m(14080) := x"0000"; m(14081) := x"0061"; -- slot 0, logical $0000 -> phys $0000
        m(14088) := x"0000"; m(14089) := x"1061"; -- slot 4, logical $1000 -> phys $1000
        m(14094) := x"0000"; m(14095) := x"1C61"; -- slot 7, logical $1C00 -> phys $1C00
        m(14136) := x"0000"; m(14137) := x"7061"; -- slot 28, logical $7000 -> phys $7000

        -- CRP target final-level indirect target: BADFEED0 sentinel, not a
        -- page descriptor, until the handler repairs it to $00007C61.
        m(14336) := x"BADF"; m(14337) := x"EED0";
        m(16#3FFA#) := x"0000"; -- physical $7FF4, odd target byte becomes low byte $A5

        -- SRP stack tree: high SRP root slot $0B is supplied by the walker
        -- model and points to table $6900. TIB slot $2B points to final table
        -- $6F00, and TIC slot $E7 maps logical $0BAF9C00 to physical $6000.
        m(13526) := x"0000"; m(13527) := x"6F02";
        m(14670) := x"0000"; m(14671) := x"6061";

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
            clk => clk, nReset => nReset, clkena_in => clkena_in, data_in => data_in,
            IPL => "111", IPL_autovector => '1', berr => '0', CPU => "10",
            addr_out => addr_out, data_write => data_write, nWr => nWr, nUDS => nUDS, nLDS => nLDS,
            busstate => busstate, longword => open, nResetOut => open, FC => FC, clr_berr => open,
            skipFetch => open, regin_out => open, CACR_out => open, VBR_out => open,
            cache_inv_req => open, cache_op_scope => open, cache_op_cache => open, cache_op_addr => open,
            cacr_ie => open, cacr_de => open, cacr_ifreeze => open, cacr_dfreeze => open,
            cacr_ibe => open, cacr_dbe => open, cacr_wa => open,
            pmmu_reg_we => open, pmmu_reg_re => open, pmmu_reg_sel => open, pmmu_reg_wdat => open, pmmu_reg_part => open,
            pmmu_addr_log => pmmu_addr_log, pmmu_addr_phys => pmmu_addr_phys, pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req => pmmu_walker_req, pmmu_walker_we => pmmu_walker_we, pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat, pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data, pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode => open, debug_preSVmode => open, debug_FlagsSR_S => open, debug_changeMode => open,
            debug_setopcode => open, debug_exec_directSR => open, debug_exec_to_SR => open,
            debug_pmove_dn_mode => open, debug_pmove_dn_regnum => open, debug_opcode => open,
            debug_state => open, debug_setstate => open, debug_last_opc_read => open, debug_data_read => open,
            debug_direct_data => open, debug_setnextpass => open, debug_TG68_PC => debug_TG68_PC,
            debug_memaddr_reg => open, debug_memaddr_delta => open, debug_oddout => open, debug_decodeOPC => open,
            debug_brief => open, debug_moves_bus_pending => open, debug_moves_writeback_pending => open,
            debug_clkena_lw => open, debug_regfile_d0 => debug_regfile_d0, debug_regfile_a0 => debug_regfile_a0,
            debug_fline_context_valid => open, debug_trap_1111 => open, debug_trapmake => open,
            debug_pmmu_brief => open, debug_use_base => open, debug_rf_source_addr => open,
            debug_pmove_ea_latched => open, debug_reg_QA => open, debug_last_data_read => open,
            debug_last_opc_pc => open, debug_getbrief => open, debug_get_2ndopc => open,
            debug_fline_brief_pending => open, debug_fline_opcode_pc => open, debug_exe_PC => open,
            debug_memaddr_delta_rega => open, debug_memaddr_delta_regb => open, debug_addsub_q => open,
            debug_memmaskmux => open, debug_fline_opcode_latch => open, debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open, debug_exec_directPC => open, debug_exec_mem_addsub => open,
            debug_set_addrlong => open, debug_mdelta_src => open, debug_pc_brw => open, debug_pc_word => open,
            debug_regfile_d1 => open, debug_regfile_d2 => debug_regfile_d2, debug_regfile_d3 => open, debug_regfile_d4 => open,
            debug_regfile_d5 => open, debug_regfile_d6 => open, debug_regfile_d7 => open, debug_regfile_a1 => open,
            debug_regfile_a2 => open, debug_regfile_a3 => open, debug_regfile_a4 => open, debug_regfile_a5 => open,
            debug_regfile_a6 => open, debug_regfile_a7 => open, debug_regfile_we => open, debug_regfile_waddr => open,
            debug_regfile_wdata => open, debug_trap_illegal => open, debug_trap_priv => open,
            debug_trap_addr_error => debug_trap_addr_error, debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr, debug_trap_vector => debug_trap_vector,
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
            debug_pmmu_fault_status => debug_pmmu_fault_status,
            debug_pmmu_saved_addr => debug_pmmu_saved_addr,
            debug_pmmu_walk_desc_addr => debug_pmmu_walk_desc_addr,
            debug_pmmu_walk_desc_data => debug_pmmu_walk_desc_data,
            debug_pmmu_ptr1_desc_addr => debug_pmmu_ptr1_desc_addr,
            debug_pmmu_ptr1_desc_data => debug_pmmu_ptr1_desc_data,
            debug_pmmu_ptr2_desc_addr => debug_pmmu_ptr2_desc_addr,
            debug_pmmu_ptr2_desc_data => debug_pmmu_ptr2_desc_data,
            debug_pmmu_ptr3_desc_addr => debug_pmmu_ptr3_desc_addr,
            debug_pmmu_ptr3_desc_data => debug_pmmu_ptr3_desc_data,
            debug_pmmu_saved_fc => open
        );

    mem_read: process(pmmu_addr_phys, mem)
    begin
        if is_x(pmmu_addr_phys) then
            data_in <= x"4E71";
        elsif unsigned(pmmu_addr_phys) < x"00008000" then
            data_in <= mem(to_integer(unsigned(pmmu_addr_phys(14 downto 1))));
        else
            data_in <= x"4E71";
        end if;
    end process;

    mem_and_walker: process(clk)
        variable phys_word   : integer;
        variable walker_word : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if not is_x(pmmu_addr_phys) and unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    if nUDS = '0' then
                        mem(phys_word)(15 downto 8) <= data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(phys_word)(7 downto 0) <= data_write(7 downto 0);
                    end if;
                end if;
            end if;

            if pmmu_walker_req = '1' then
                if not is_x(pmmu_walker_addr) then
                    if pmmu_walker_addr = x"4FAA6074" then
                        saw_crp_root_desc <= true;
                        if pmmu_walker_we = '1' then
                            crp_root_desc <= pmmu_walker_wdat;
                        else
                            pmmu_walker_data <= crp_root_desc;
                        end if;
                    elsif pmmu_walker_addr = x"4FFF6074" then
                        saw_corrupt_crp_root_desc <= true;
                        pmmu_walker_data <= x"00000000";
                    elsif pmmu_walker_addr = x"4FAA70FC" then
                        if pmmu_walker_we = '1' then
                            crp_ptr1_desc <= pmmu_walker_wdat;
                        else
                            pmmu_walker_data <= crp_ptr1_desc;
                        end if;
                    elsif pmmu_walker_addr = x"4FAA83FC" then
                        if pmmu_walker_we = '1' then
                            crp_indirect_desc <= pmmu_walker_wdat;
                        else
                            pmmu_walker_data <= crp_indirect_desc;
                        end if;
                    elsif pmmu_walker_addr = x"4052C000" then
                        if pmmu_walker_we = '1' then
                            srp_low_root_desc <= pmmu_walker_wdat;
                        else
                            pmmu_walker_data <= srp_low_root_desc;
                        end if;
                    elsif pmmu_walker_addr = x"4052C02C" then
                        if pmmu_walker_we = '1' then
                            srp_stack_root_desc <= pmmu_walker_wdat;
                        else
                            pmmu_walker_data <= srp_stack_root_desc;
                        end if;
                    elsif unsigned(pmmu_walker_addr) < x"00008000" then
                        walker_word := to_integer(unsigned(pmmu_walker_addr(14 downto 1)));
                        if pmmu_walker_we = '1' then
                            mem(walker_word)     <= pmmu_walker_wdat(31 downto 16);
                            mem(walker_word + 1) <= pmmu_walker_wdat(15 downto 0);
                        else
                            pmmu_walker_data <= mem(walker_word) & mem(walker_word + 1);
                        end if;
                    else
                        pmmu_walker_data <= x"00000000";
                    end if;
                else
                    pmmu_walker_data <= x"00000000";
                end if;
                pmmu_walker_ack <= '1';
            else
                pmmu_walker_ack <= '0';
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

    stall_control: process(clk)
    begin
        if rising_edge(clk) then
            walker_req_prev <= pmmu_walker_req;
            if walker_req_prev = '1' and pmmu_walker_req = '0' then
                stall_cooldown <= 2;
            elsif stall_cooldown > 0 then
                stall_cooldown <= stall_cooldown - 1;
            end if;
        end if;
    end process;

    clkena_in <= '0' when (pmmu_walker_req = '1'
                           or (debug_pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0
                           or mem_wait = '1') else '1';

    trace_flow: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '1' then
                if debug_TG68_PC = x"00000080" and not saw_handler_pc then
                    saw_handler_pc <= true;
                    report "MOVES_DFC_TRACE: entered vector2 handler" severity note;
                elsif (mem(16#0F96#) & mem(16#0F97#)) = x"C0DE700D" and not saw_done_marker then
                    saw_done_marker <= true;
                    report "MOVES_DFC_TRACE: restarted MOVES.B completed" severity note;
                end if;
            end if;
        end if;
    end process;

    main_test: process
        variable frame_a7 : std_logic_vector(31 downto 0);
        variable marker   : std_logic_vector(31 downto 0);
        variable done_mark : std_logic_vector(31 downto 0);
        variable pte_target : std_logic_vector(31 downto 0);
        variable moved_word : std_logic_vector(15 downto 0);
        variable frame_word : integer;
        variable frame_ssw : std_logic_vector(15 downto 0);
        variable frame_pc : std_logic_vector(31 downto 0);
        variable frame_fault_addr : std_logic_vector(31 downto 0);
    begin
        report "=== MMU RESTART MOVES.B DFC WRITE TEST ===" severity note;
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 50000 loop
            wait until rising_edge(clk);
            done_mark := mem(16#0F96#) & mem(16#0F97#); -- $1F2C
            if debug_cpu_halted = '1' or done_mark = x"C0DE700D" then
                exit;
            end if;
        end loop;

        frame_a7 := mem(16#0F92#) & mem(16#0F93#); -- $1F24
        marker   := mem(16#0F80#) & mem(16#0F81#); -- $1F00
        done_mark := mem(16#0F96#) & mem(16#0F97#); -- $1F2C
        pte_target := mem(16#3800#) & mem(16#3801#); -- physical $7000
        moved_word := mem(16#3FFA#); -- physical $7FF4, low byte is logical $1DFFFFF5
        -- The high logical stack page $0BAF9C00 maps to physical $6000.
        frame_word := 16#3000# + to_integer(unsigned(frame_a7(9 downto 1)));
        frame_ssw := mem(frame_word + 5);
        frame_pc := mem(frame_word + 1) & mem(frame_word + 2);
        frame_fault_addr := mem(frame_word + 8) & mem(frame_word + 9);

        if debug_cpu_halted = '1' then
            report "FAIL: cpu_halted asserted"
                   & " PC=$" & slv_to_hex(debug_TG68_PC)
                   & " trapvec=$" & slv_to_hex(debug_trap_vector)
                   & " trap_berr=" & std_logic'image(debug_trap_berr)
                   & " trap_mmu_berr=" & std_logic'image(debug_trap_mmu_berr)
                   & " trap_addr=" & std_logic'image(debug_trap_addr_error)
                   & " pmmu_fault=" & std_logic'image(debug_pmmu_fault)
                   & " mmusr=$" & slv_to_hex(debug_pmmu_fault_status)
                   & " fault_addr=$" & slv_to_hex(debug_pmmu_saved_addr)
	                   & " desc_addr=$" & slv_to_hex(debug_pmmu_walk_desc_addr)
	                   & " desc_data=$" & slv_to_hex(debug_pmmu_walk_desc_data)
	                   & " marker=$" & slv_to_hex(marker)
	                   & " done=$" & slv_to_hex(done_mark)
	                   & " frame_a7=$" & slv_to_hex(frame_a7)
            severity failure;
        elsif done_mark /= x"C0DE700D" then
            report "FAIL: restarted MOVES.B did not reach done marker, PC=$" & slv_to_hex(debug_TG68_PC)
                   & " D0=$" & slv_to_hex(debug_regfile_d0)
                   & " D2=$" & slv_to_hex(debug_regfile_d2)
                   & " marker=$" & slv_to_hex(marker)
                   & " done=$" & slv_to_hex(done_mark)
                   & " frame_a7=$" & slv_to_hex(frame_a7)
                   & " frame_ssw=$" & slv_to_hex(frame_ssw)
                   & " frame_pc=$" & slv_to_hex(frame_pc)
                   & " frame_fault=$" & slv_to_hex(frame_fault_addr)
                   severity failure;
        elsif marker /= x"00000002" or not saw_handler_pc then
            report "FAIL: vector 2 handler was not observed"
                   & " marker=$" & slv_to_hex(marker)
                   & " saw_handler=" & boolean'image(saw_handler_pc)
                   & " frame_a7=$" & slv_to_hex(frame_a7)
                   severity failure;
        elsif not saw_crp_root_desc then
            report "FAIL: CRP root descriptor read at $4FAA6074 was not observed"
                   & " last_desc_addr=$" & slv_to_hex(debug_pmmu_walk_desc_addr)
                   & " last_desc_data=$" & slv_to_hex(debug_pmmu_walk_desc_data)
                   severity failure;
        elsif saw_corrupt_crp_root_desc then
            report "FAIL: observed corrupted CRP root descriptor address $4FFF6074"
                   severity failure;
        elsif moved_word /= x"00A5" then
            report "FAIL: restarted MOVES.B did not write low byte $A5 at physical $7FF5"
                   & " word=$" & slv_to_hex(moved_word)
                   & " D2=$" & slv_to_hex(debug_regfile_d2)
                   & " frame_a7=$" & slv_to_hex(frame_a7)
                   & " marker=$" & slv_to_hex(marker)
                   & " frame_ssw=$" & slv_to_hex(frame_ssw)
                   & " frame_pc=$" & slv_to_hex(frame_pc)
                   & " frame_fault=$" & slv_to_hex(frame_fault_addr)
                   & " saw_handler=" & boolean'image(saw_handler_pc)
                   & " saw_done=" & boolean'image(saw_done_marker)
                   & " trapvec=$" & slv_to_hex(debug_trap_vector)
                   & " trap_berr=" & std_logic'image(debug_trap_berr)
                   & " trap_mmu_berr=" & std_logic'image(debug_trap_mmu_berr)
                   & " trap_addr=" & std_logic'image(debug_trap_addr_error)
                   & " MMUSR=$" & slv_to_hex(debug_pmmu_fault_status)
                   severity failure;
        elsif frame_fault_addr /= x"1DFFFFF5" or frame_pc /= x"00000134" or
              frame_ssw(8) /= '1' or frame_ssw(7) /= '0' or frame_ssw(6) /= '0' or
              frame_ssw(5 downto 4) /= "01" or frame_ssw(2 downto 0) /= "001" then
            report "FAIL: stacked frame does not describe the original MOVES.B DFC write fault"
                   & " frame_a7=$" & slv_to_hex(frame_a7)
                   & " frame_ssw=$" & slv_to_hex(frame_ssw)
                   & " frame_pc=$" & slv_to_hex(frame_pc)
                   & " frame_fault=$" & slv_to_hex(frame_fault_addr)
                   severity failure;
        elsif pte_target(31 downto 8) /= x"00007C" or pte_target(1 downto 0) /= "01" then
            report "FAIL: handler did not repair indirect target descriptor"
                   & " pte=$" & slv_to_hex(pte_target)
                   severity failure;
        else
            report "PASS: MOVES.B DFC write fault restarted after live CRP/SRP walk"
                   & " frame_a7=$" & slv_to_hex(frame_a7)
                   & " word=$" & slv_to_hex(moved_word)
                   & " pte=$" & slv_to_hex(pte_target)
            severity note;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
