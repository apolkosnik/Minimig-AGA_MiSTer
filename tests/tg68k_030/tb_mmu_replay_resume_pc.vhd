-- tb_mmu_replay_resume_pc.vhd
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
use std.textio.all;

entity tb_mmu_replay_resume_pc is
    generic (
        REPLAY_REFAULT : boolean := false;
        TRACE_ENABLE   : boolean := false;
        TRACE_FILE     : string := "/tmp/tg68k_mmu_replay_refault.trace"
    );
end entity;

architecture behavioral of tb_mmu_replay_resume_pc is

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
    signal debug_regfile_d1 : std_logic_vector(31 downto 0);
    signal debug_regfile_d2 : std_logic_vector(31 downto 0);
    signal debug_regfile_d3 : std_logic_vector(31 downto 0);
    signal debug_regfile_d4 : std_logic_vector(31 downto 0);
    signal debug_regfile_d5 : std_logic_vector(31 downto 0);
    signal debug_regfile_d6 : std_logic_vector(31 downto 0);
    signal debug_regfile_d7 : std_logic_vector(31 downto 0);
    signal debug_regfile_a0 : std_logic_vector(31 downto 0);
    signal debug_regfile_a1 : std_logic_vector(31 downto 0);
    signal debug_regfile_a2 : std_logic_vector(31 downto 0);
    signal debug_regfile_a3 : std_logic_vector(31 downto 0);
    signal debug_regfile_a4 : std_logic_vector(31 downto 0);
    signal debug_regfile_a5 : std_logic_vector(31 downto 0);
    signal debug_regfile_a6 : std_logic_vector(31 downto 0);
    signal debug_regfile_a7 : std_logic_vector(31 downto 0);
    signal debug_setopcode : std_logic;
    signal debug_decodeOPC : std_logic;
    signal debug_setnextpass : std_logic;
    signal debug_opcode : std_logic_vector(15 downto 0);
    signal debug_exe_PC : std_logic_vector(31 downto 0);
    signal debug_last_opc_pc : std_logic_vector(31 downto 0);
    signal debug_FlagsSR : std_logic_vector(7 downto 0);
    signal debug_pmmu_reg_we : std_logic;
    signal debug_pmmu_reg_sel : std_logic_vector(4 downto 0);
    signal debug_pmmu_reg_wdat : std_logic_vector(31 downto 0);
    signal debug_pmmu_reg_part : std_logic;
    signal debug_pmmu_saved_fc : std_logic_vector(2 downto 0);
    signal debug_pmmu_fault_rw : std_logic;
    signal debug_pmmu_fault_is_insn : std_logic;
    signal debug_pmmu_fault_fc : std_logic_vector(2 downto 0);
    signal debug_pmmu_wstate : std_logic_vector(4 downto 0);
    signal debug_pmmu_atc_buserr : std_logic_vector(21 downto 0);
    signal debug_pmmu_atc_valid : std_logic_vector(21 downto 0);
    signal debug_pmmu_pending_flags : std_logic_vector(15 downto 0);
    signal debug_rte_fmt_a_state1 : std_logic_vector(15 downto 0);
    signal debug_rte_fmt_a_ssw : std_logic_vector(15 downto 0);
    signal debug_rte_fmt_a_fault_addr : std_logic_vector(31 downto 0);
    signal debug_rte_fmt_a_data_out : std_logic_vector(31 downto 0);
    signal debug_rte_fmt_a_replay_needed : std_logic;
    signal debug_stop      : std_logic;
    signal debug_micro_state : integer range 0 to 255;
    signal debug_next_micro_state : integer range 0 to 255;
    signal debug_state      : std_logic_vector(1 downto 0);
    signal saw_rte_final_stack_read : boolean := false;
    signal saw_replay_write : boolean := false;

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';
    signal saw_handler_pc  : boolean := false;
    signal saw_done_marker : boolean := false;
    signal saw_crp_root_desc : boolean := false;
    signal saw_corrupt_crp_root_desc : boolean := false;
    signal dropped_repair_words : integer range 0 to 2 := 0;
    signal handler_entry_count : integer range 0 to 15 := 0;

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
        if REPLAY_REFAULT then
            -- Force the first RTE retry to execute in restored user context.
            -- The memory model drops only the first descriptor repair below,
            -- so the retry faults once and the second handler pass repairs it.
            m(72) := x"4257";                                  -- CLR.W (A7): stacked SR = user
            m(73) := x"2F7C"; m(74) := x"1DFF"; m(75) := x"FC00";
            m(76) := x"0002";                                  -- MOVE.L #$1DFFFC00,2(A7)
            m(77) := x"23FC"; m(78) := x"0000"; m(79) := x"7C61";
            m(80) := x"0000"; m(81) := x"7000";               -- MOVE.L #$00007C61,$7000.L
            m(82) := x"227C"; m(83) := x"1DFF"; m(84) := x"FFF5";
            m(85) := x"F011"; m(86) := x"3810";               -- PFLUSH #0,#0,(A1)
            m(87) := x"4E73";                                  -- RTE
        else
            m(72) := x"23FC"; m(73) := x"0000"; m(74) := x"7C61"; -- MOVE.L #$00007C61,$7000.L
            m(75) := x"0000"; m(76) := x"7000";
            m(77) := x"227C"; m(78) := x"1DFF"; m(79) := x"FFF5"; -- MOVEA.L #$1DFFFFF5,A1
            m(80) := x"F011"; m(81) := x"3810";                   -- PFLUSH #0,#0,(A1)
            m(82) := x"4E73";                                     -- RTE
        end if;

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
        m(154) := x"207C"; m(155) := x"1DFF"; m(156) := x"FFF5"; -- MOVEA.L #$1DFFFFF5,A0
        m(157) := x"0E10"; m(158) := x"2800";                   -- MOVES.B D2,(A0) [4-byte NetBSD copyout shape]
        m(159) := x"23FC"; m(160) := x"C0DE"; m(161) := x"700D"; -- MOVE.L #$C0DE700D,$1F2C.L (canary: skipped word = derail)
        m(162) := x"0000"; m(163) := x"1F2C";
        m(164) := x"60FE";                                     -- BRA.S *

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
        if REPLAY_REFAULT then
            -- User continuation on the repaired $1DFFFC00 page. Keep its
            -- completion marker on that same CRP-mapped page.
            m(16#3E00#) := x"23FC"; m(16#3E01#) := x"C0DE";
            m(16#3E02#) := x"700D"; m(16#3E03#) := x"1DFF";
            m(16#3E04#) := x"FC20"; m(16#3E05#) := x"60FE";
        end if;

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
            debug_setopcode => debug_setopcode, debug_exec_directSR => open, debug_exec_to_SR => open,
            debug_pmove_dn_mode => open, debug_pmove_dn_regnum => open, debug_opcode => debug_opcode,
            debug_state => debug_state, debug_setstate => open,
            debug_last_opc_read => open, debug_data_read => open,
            debug_direct_data => open, debug_setnextpass => debug_setnextpass,
            debug_TG68_PC => debug_TG68_PC,
            debug_memaddr_reg => open, debug_memaddr_delta => open, debug_oddout => open,
            debug_decodeOPC => debug_decodeOPC,
            debug_brief => open, debug_moves_bus_pending => open, debug_moves_writeback_pending => open,
            debug_clkena_lw => open, debug_regfile_d0 => debug_regfile_d0, debug_regfile_a0 => debug_regfile_a0,
            debug_fline_context_valid => open, debug_trap_1111 => open, debug_trapmake => open,
            debug_pmmu_brief => open, debug_use_base => open, debug_rf_source_addr => open,
            debug_pmove_ea_latched => open, debug_reg_QA => open, debug_last_data_read => open,
            debug_last_opc_pc => debug_last_opc_pc, debug_getbrief => open, debug_get_2ndopc => open,
            debug_fline_brief_pending => open, debug_fline_opcode_pc => open, debug_exe_PC => debug_exe_PC,
            debug_memaddr_delta_rega => open, debug_memaddr_delta_regb => open, debug_addsub_q => open,
            debug_memmaskmux => open, debug_fline_opcode_latch => open,
            debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open, debug_exec_directPC => open, debug_exec_mem_addsub => open,
            debug_set_addrlong => open, debug_mdelta_src => open, debug_pc_brw => open, debug_pc_word => open,
            debug_regfile_d1 => debug_regfile_d1, debug_regfile_d2 => debug_regfile_d2,
            debug_regfile_d3 => debug_regfile_d3, debug_regfile_d4 => debug_regfile_d4,
            debug_regfile_d5 => debug_regfile_d5, debug_regfile_d6 => debug_regfile_d6,
            debug_regfile_d7 => debug_regfile_d7, debug_regfile_a1 => debug_regfile_a1,
            debug_regfile_a2 => debug_regfile_a2, debug_regfile_a3 => debug_regfile_a3,
            debug_regfile_a4 => debug_regfile_a4, debug_regfile_a5 => debug_regfile_a5,
            debug_regfile_a6 => debug_regfile_a6, debug_regfile_a7 => debug_regfile_a7,
            debug_regfile_we => open, debug_regfile_waddr => open,
            debug_regfile_wdata => open, debug_trap_illegal => open, debug_trap_priv => open,
            debug_trap_addr_error => debug_trap_addr_error, debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr, debug_trap_vector => debug_trap_vector,
            debug_pc_add => open, debug_pc_dataa => open, debug_pc_datab => open, debug_pmmu_busy => debug_pmmu_busy,
            debug_cpu_halted => debug_cpu_halted, debug_stop => debug_stop, debug_interrupt => open,
            debug_setendOPC => open, debug_IPL_nr => open, debug_micro_state => debug_micro_state,
            debug_next_micro_state => debug_next_micro_state,
            debug_memmask => open, debug_sndOPC => open, debug_pmmu_reg_we => debug_pmmu_reg_we,
            debug_pmmu_reg_re => open, debug_pmmu_reg_sel => debug_pmmu_reg_sel,
            debug_pmmu_reg_wdat => debug_pmmu_reg_wdat, debug_pmmu_reg_part => debug_pmmu_reg_part,
            debug_pmmu_reg_rdat => open, debug_make_berr => open,
            debug_pmmu_fault => debug_pmmu_fault,
            debug_trap_format_error => open, debug_format_error_rte_word => open, debug_format_error_pc => open,
            debug_format_error_addr => open, debug_format_error_sr => open, debug_pmmu_tc => open,
            debug_pmmu_tt0 => open, debug_pmmu_tt1 => open, debug_pmmu_crp_hi => open, debug_pmmu_crp_lo => open,
            debug_pmmu_srp_hi => open, debug_pmmu_srp_lo => open, debug_pmmu_wstate => debug_pmmu_wstate,
            debug_pmmu_atc_buserr => debug_pmmu_atc_buserr,
            debug_pmmu_atc_valid => debug_pmmu_atc_valid,
            debug_pmmu_pending_flags => debug_pmmu_pending_flags,
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
            debug_pmmu_saved_fc => debug_pmmu_saved_fc,
            debug_pmmu_fault_rw => debug_pmmu_fault_rw,
            debug_pmmu_fault_is_insn => debug_pmmu_fault_is_insn,
            debug_pmmu_fault_fc => debug_pmmu_fault_fc,
            debug_FlagsSR => debug_FlagsSR,
            debug_rte_fmt_a_state1 => debug_rte_fmt_a_state1,
            debug_rte_fmt_a_ssw => debug_rte_fmt_a_ssw,
            debug_rte_fmt_a_fault_addr => debug_rte_fmt_a_fault_addr,
            debug_rte_fmt_a_data_out => debug_rte_fmt_a_data_out,
            debug_rte_fmt_a_replay_needed => debug_rte_fmt_a_replay_needed
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
            if nReset = '0' then
                dropped_repair_words <= 0;
                handler_entry_count <= 0;
            elsif busstate = "11" and nWr = '0' and clkena_in = '1' then
                if not is_x(pmmu_addr_phys) and unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    if nWr = '0' and pmmu_addr_log = x"1DFFFFF5" and FC = "001" and
                       nUDS = '1' and nLDS = '0' then
                        saw_replay_write <= true;
                    end if;
                    if pmmu_addr_phys = x"00001F00" and handler_entry_count < 15 then
                        handler_entry_count <= handler_entry_count + 1;
                    end if;
                    if REPLAY_REFAULT and
                       (pmmu_addr_phys = x"00007000" or pmmu_addr_phys = x"00007002") and
                       dropped_repair_words < 2 then
                        report "REPLAY_REFAULT: dropped descriptor repair beat at $" &
                               slv_to_hex(pmmu_addr_phys)
                               severity note;
                        dropped_repair_words <= dropped_repair_words + 1;
                    else
                        if nUDS = '0' then
                            mem(phys_word)(15 downto 8) <= data_write(15 downto 8);
                        end if;
                        if nLDS = '0' then
                            mem(phys_word)(7 downto 0) <= data_write(7 downto 0);
                        end if;
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

    trace_writer: process
        file trace_output : text;
        variable open_status : file_open_status;
        variable row : line;
        variable sequence_number : natural := 0;
        variable cycle_number : natural := 0;
        variable emit_decode : boolean;
        variable previous_fault : std_logic := '0';
        variable previous_trap : std_logic := '0';
        variable previous_micro_state : integer range 0 to 255 := 0;
        variable previous_atc_valid : std_logic_vector(21 downto 0) := (others => '0');
        variable previous_atc_buserr : std_logic_vector(21 downto 0) := (others => '0');

        procedure start_event(
            variable output_row : inout line;
            constant event_kind : in string;
            constant event_sequence : in natural;
            constant event_cycle : in natural
        ) is
        begin
            write(output_row, string'("M68KTRACE|v=1|source=tg68k|kind="));
            write(output_row, event_kind);
            write(output_row, string'("|seq="));
            write(output_row, event_sequence);
            write(output_row, string'("|cycle="));
            write(output_row, event_cycle);
        end procedure;

        function logic_string(value : std_logic) return string is
        begin
            if value = '0' then
                return "0";
            elsif value = '1' then
                return "1";
            else
                return "x";
            end if;
        end function;

        function transfer_size(
            uds_value : std_logic;
            lds_value : std_logic
        ) return string is
        begin
            if uds_value = '0' and lds_value = '0' then
                return "w";
            elsif uds_value = '0' or lds_value = '0' then
                return "b";
            else
                return "none";
            end if;
        end function;
    begin
        if not TRACE_ENABLE then
            wait;
        end if;

        file_open(open_status, trace_output, TRACE_FILE, write_mode);
        assert open_status = open_ok
            report "Unable to open M68K trace file: " & TRACE_FILE
            severity failure;

        write(row, string'("M68KTRACE|v=1|source=tg68k|case="));
        if REPLAY_REFAULT then
            write(row, string'("mmu-replay-refault"));
        else
            write(row, string'("mmu-replay-resume"));
        end if;
        writeline(trace_output, row);

        loop
            wait until rising_edge(clk);
            cycle_number := cycle_number + 1;
            exit when test_done;

            emit_decode := nReset = '1' and clkena_in = '1' and debug_setopcode = '1';

            if nReset = '1' and clkena_in = '1' and busstate /= "01" and
               (nUDS = '0' or nLDS = '0') then
                start_event(row, "bus", sequence_number, cycle_number);
                write(row, string'("|logical=")); write(row, slv_to_hex(pmmu_addr_log));
                write(row, string'("|physical=")); write(row, slv_to_hex(pmmu_addr_phys));
                write(row, string'("|fc=")); write(row, to_integer(unsigned(FC)));
                if nWr = '0' then
                    write(row, string'("|rw=w|data="));
                    if nUDS = '0' and nLDS = '1' then
                        write(row, slv_to_hex(data_write(15 downto 8)));
                    elsif nUDS = '1' and nLDS = '0' then
                        write(row, slv_to_hex(data_write(7 downto 0)));
                    else
                        write(row, slv_to_hex(data_write));
                    end if;
                else
                    write(row, string'("|rw=r|data="));
                    if nUDS = '0' and nLDS = '1' then
                        write(row, slv_to_hex(data_in(15 downto 8)));
                    elsif nUDS = '1' and nLDS = '0' then
                        write(row, slv_to_hex(data_in(7 downto 0)));
                    else
                        write(row, slv_to_hex(data_in));
                    end if;
                end if;
                write(row, string'("|size=")); write(row, transfer_size(nUDS, nLDS));
                write(row, string'("|uds=")); write(row, logic_string(nUDS));
                write(row, string'("|lds=")); write(row, logic_string(nLDS));
                if FC(0) = '0' then
                    write(row, string'("|space=i"));
                else
                    write(row, string'("|space=d"));
                end if;
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;

            if nReset = '1' and pmmu_walker_req = '1' and pmmu_walker_ack = '1' then
                start_event(row, "walk", sequence_number, cycle_number);
                write(row, string'("|addr=")); write(row, slv_to_hex(pmmu_walker_addr));
                if pmmu_walker_we = '1' then
                    write(row, string'("|rw=w|data=")); write(row, slv_to_hex(pmmu_walker_wdat));
                else
                    write(row, string'("|rw=r|data=")); write(row, slv_to_hex(pmmu_walker_data));
                end if;
                write(row, string'("|wstate=")); write(row, slv_to_hex("000" & debug_pmmu_wstate));
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;

            if nReset = '1' and clkena_in = '1' and debug_pmmu_reg_we = '1' then
                start_event(row, "pmmu_reg", sequence_number, cycle_number);
                write(row, string'("|sel=")); write(row, slv_to_hex("000" & debug_pmmu_reg_sel));
                write(row, string'("|part=")); write(row, logic_string(debug_pmmu_reg_part));
                write(row, string'("|data=")); write(row, slv_to_hex(debug_pmmu_reg_wdat));
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;

            if nReset = '1' and debug_pmmu_fault = '1' and previous_fault = '0' then
                start_event(row, "fault", sequence_number, cycle_number);
                write(row, string'("|logical=")); write(row, slv_to_hex(debug_pmmu_saved_addr));
                write(row, string'("|fc=")); write(row, to_integer(unsigned(debug_pmmu_fault_fc)));
                if debug_pmmu_fault_rw = '1' then
                    write(row, string'("|rw=r"));
                else
                    write(row, string'("|rw=w"));
                end if;
                write(row, string'("|is_insn=")); write(row, logic_string(debug_pmmu_fault_is_insn));
                write(row, string'("|mmusr=")); write(row, slv_to_hex(debug_pmmu_fault_status));
                write(row, string'("|pending=")); write(row, slv_to_hex(debug_pmmu_pending_flags));
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;

            if nReset = '1' and debug_trap_mmu_berr = '1' and previous_trap = '0' then
                start_event(row, "trap", sequence_number, cycle_number);
                write(row, string'("|vector=")); write(row, slv_to_hex(debug_trap_vector));
                write(row, string'("|logical=")); write(row, slv_to_hex(debug_pmmu_saved_addr));
                write(row, string'("|fc=")); write(row, to_integer(unsigned(debug_pmmu_saved_fc)));
                write(row, string'("|mmusr=")); write(row, slv_to_hex(debug_pmmu_fault_status));
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;

            if nReset = '1' and debug_micro_state = 125 and previous_micro_state /= 125 then
                start_event(row, "replay", sequence_number, cycle_number);
                write(row, string'("|logical=")); write(row, slv_to_hex(debug_rte_fmt_a_fault_addr));
                write(row, string'("|ssw=")); write(row, slv_to_hex(debug_rte_fmt_a_ssw));
                write(row, string'("|state1=")); write(row, slv_to_hex(debug_rte_fmt_a_state1));
                write(row, string'("|data=")); write(row, slv_to_hex(debug_rte_fmt_a_data_out));
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;

            if nReset = '1' and
               (debug_pmmu_atc_valid /= previous_atc_valid or
                debug_pmmu_atc_buserr /= previous_atc_buserr) then
                start_event(row, "atc", sequence_number, cycle_number);
                write(row, string'("|op=map|valid=")); write(row, slv_to_hex("00" & debug_pmmu_atc_valid));
                write(row, string'("|buserr=")); write(row, slv_to_hex("00" & debug_pmmu_atc_buserr));
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;

            previous_fault := debug_pmmu_fault;
            previous_trap := debug_trap_mmu_berr;
            previous_micro_state := debug_micro_state;
            previous_atc_valid := debug_pmmu_atc_valid;
            previous_atc_buserr := debug_pmmu_atc_buserr;

            -- setopcode also pulses on internal passes. After the edge,
            -- decodeOPC identifies an actual new instruction decode.
            wait for 0 ns;
            wait for 0 ns;
            if emit_decode and debug_decodeOPC = '1' then
                start_event(row, "decode", sequence_number, cycle_number);
                write(row, string'("|pc=")); write(row, slv_to_hex(debug_exe_PC));
                write(row, string'("|op=")); write(row, slv_to_hex(debug_opcode));
                write(row, string'("|srh=")); write(row, slv_to_hex(debug_FlagsSR));
                write(row, string'("|tg_pc=")); write(row, slv_to_hex(debug_TG68_PC));
                write(row, string'("|tg_last_pc=")); write(row, slv_to_hex(debug_last_opc_pc));
                write(row, string'("|tg_state=")); write(row, slv_to_hex("000000" & debug_state));
                write(row, string'("|tg_micro=")); write(row, debug_micro_state);
                write(row, string'("|tg_setnext=")); write(row, logic_string(debug_setnextpass));
                writeline(trace_output, row);
                sequence_number := sequence_number + 1;
            end if;
        end loop;
    end process;

    trace_flow: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '1' then
                if debug_micro_state = 48 and debug_next_micro_state = 125 and
                   debug_state = "10" then
                    saw_rte_final_stack_read <= true;
                    assert FC = "101"
                        report "FAIL: final Format A frame read used non-supervisor FC=" &
                               integer'image(to_integer(unsigned(FC))) &
                               " next_micro=" & integer'image(debug_next_micro_state)
                        severity failure;
                    assert pmmu_addr_log(31 downto 12) = x"0BAF9"
                        report "FAIL: final Format A frame read left supervisor stack for $" &
                               slv_to_hex(pmmu_addr_log)
                        severity failure;
                    assert debug_pmmu_fault = '0'
                        report "FAIL: final Format A frame read raised PMMU fault at $" &
                               slv_to_hex(pmmu_addr_log) & " FC=" &
                               integer'image(to_integer(unsigned(FC)))
                        severity failure;
                end if;
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
        variable frame_sr : std_logic_vector(15 downto 0);
        variable frame_pc : std_logic_vector(31 downto 0);
        variable frame_fault_addr : std_logic_vector(31 downto 0);
    begin
        report "=== MMU RESTART MOVES.B DFC WRITE TEST ===" severity note;
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 50000 loop
            wait until rising_edge(clk);
            if REPLAY_REFAULT then
                done_mark := mem(16#3E10#) & mem(16#3E11#); -- physical $7C20
            else
                done_mark := mem(16#0F96#) & mem(16#0F97#); -- $1F2C
            end if;
            if debug_cpu_halted = '1' or done_mark = x"C0DE700D" then
                exit;
            end if;
        end loop;

        frame_a7 := mem(16#0F92#) & mem(16#0F93#); -- $1F24
        marker   := mem(16#0F80#) & mem(16#0F81#); -- $1F00
        if REPLAY_REFAULT then
            done_mark := mem(16#3E10#) & mem(16#3E11#); -- physical $7C20
        else
            done_mark := mem(16#0F96#) & mem(16#0F97#); -- $1F2C
        end if;
        pte_target := mem(16#3800#) & mem(16#3801#); -- physical $7000
        moved_word := mem(16#3FFA#); -- physical $7FF4, low byte is logical $1DFFFFF5
        -- The high logical stack page $0BAF9C00 maps to physical $6000.
        frame_word := 16#3000# + to_integer(unsigned(frame_a7(9 downto 1)));
        frame_sr := mem(frame_word);
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
        elsif not saw_rte_final_stack_read then
            report "FAIL: did not observe final translated-stack Format A read"
                   severity failure;
        elsif not saw_replay_write then
            report "FAIL: Format A replay did not issue its saved user byte write"
                   severity failure;
        elsif REPLAY_REFAULT and handler_entry_count < 2 then
            report "FAIL: Format A replay did not fault a second time"
                   & " handler_count=" & integer'image(handler_entry_count)
                   & " dropped_repairs=" & integer'image(dropped_repair_words)
                   severity failure;
		elsif REPLAY_REFAULT and (frame_sr /= x"0000" or frame_pc /= x"1DFFFC00" or
		      frame_fault_addr /= x"1DFFFFF5" or frame_ssw(8) /= '1' or
		      frame_ssw(7) /= '0' or frame_ssw(6) /= '0' or
		      frame_ssw(5 downto 4) /= "01" or frame_ssw(2 downto 0) /= "001") then
			report "FAIL: replay fault did not stack the restored user context"
			       & " frame_sr=$" & slv_to_hex(frame_sr)
			       & " frame_pc=$" & slv_to_hex(frame_pc)
			       & " frame_ssw=$" & slv_to_hex(frame_ssw)
			       & " frame_fault=$" & slv_to_hex(frame_fault_addr)
			       & " handler_count=" & integer'image(handler_entry_count)
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
		elsif (not REPLAY_REFAULT) and (frame_fault_addr /= x"1DFFFFF5" or frame_pc /= x"0000013E" or
		      frame_ssw(8) /= '1' or frame_ssw(7) /= '0' or frame_ssw(6) /= '0' or
		      frame_ssw(5 downto 4) /= "01" or frame_ssw(2 downto 0) /= "001") then
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
