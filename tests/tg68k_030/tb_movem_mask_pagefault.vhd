-- tb_movem_mask_pagefault.vhd
-- BUG #458 regression - a PMMU fault on the SECOND opcode word (MOVEM's
-- register mask) must be a RESTARTABLE instruction fault.
--
-- Pre-fix, the decodeOPC/get_2ndOPC consumption site was missing from
-- insn_fetch_consumer: the fault classified as a consumer-less insn-space
-- fault (no restart, no squash), sndOPC latched garbage, and a store-MOVEM
-- ran to completion pushing a garbage register set before the deferred bus
-- error dispatched with a post-MOVEM PC - RTE then resumed AFTER the
-- corruption.
--
-- Layout (1K pages, TC=$82A08680, tables as in the softfix benches):
--   $03FE: MOVEM.L D0-D2,-(A6)   <- last word of mapped page 0
--   $0400: mask $E000            <- first word of page 1, descriptor INVALID
--   $0402: STOP #$2700           <- executed after the re-run completes
-- The vector-2 handler counts entries, writes a valid identity descriptor
-- for page 1 into the level-C table ($6E04), PFLUSHAs and RTEs.
--
-- Post-fix: exactly one fault, MOVEM re-executes from scratch:
--   A6 = $1E00-12 = $1DF4, ($1DF4/$1DF8/$1DFC) = D0/D1/D2, no stores below.
-- Pre-fix: garbage mask -> wrong store count/addresses -> checks fail.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_movem_mask_pagefault is
end entity;

architecture behavioral of tb_movem_mask_pagefault is

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
    signal debug_trap_vector   : std_logic_vector(31 downto 0);
    signal debug_pmmu_fault    : std_logic;
    signal debug_pmmu_busy     : std_logic;
    signal debug_cpu_halted    : std_logic;
    signal debug_regfile_d0 : std_logic_vector(31 downto 0);
    signal debug_regfile_d1 : std_logic_vector(31 downto 0);
    signal debug_regfile_d2 : std_logic_vector(31 downto 0);
    signal debug_regfile_a6 : std_logic_vector(31 downto 0);
    signal debug_stop      : std_logic;
    signal debug_pmmu_fault_status : std_logic_vector(15 downto 0);
    signal debug_pmmu_saved_addr   : std_logic_vector(31 downto 0);
    signal debug_pmmu_walk_desc_addr : std_logic_vector(31 downto 0);
    signal debug_pmmu_walk_desc_data : std_logic_vector(31 downto 0);

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';
    signal handler_entries : integer := 0;
    signal handler_seen    : boolean := false;

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        -- Reset vectors: SSP=$2000, PC=$0100, vector 2 -> $0080, rest -> $00C0
        m(0) := x"0000"; m(1) := x"2000";
        m(2) := x"0000"; m(3) := x"0100";
        m(4) := x"0000"; m(5) := x"0080";
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00C0";
        end loop;

        -- Vector 2 handler at $0080: count, map page 1, flush, return
        m(64) := x"52B8"; m(65) := x"1F80";                   -- ADDQ.L #1,($1F80).W
        m(66) := x"23FC"; m(67) := x"0000"; m(68) := x"0461"; -- MOVE.L #$00000461,
        m(69) := x"0000"; m(70) := x"6E04";                   --        ($00006E04).L
        m(71) := x"F000"; m(72) := x"2400";                   -- PFLUSHA
        m(73) := x"4E73";                                     -- RTE

        -- Unexpected trap handler at $00C0
        m(96) := x"23FC"; m(97) := x"00FF"; m(98) := x"0000";
        m(99) := x"0000"; m(100) := x"1F00";
        m(101) := x"4E72"; m(102) := x"2700";

        -- Main program at $0100 (stays supervisor)
        m(128) := x"2E7C"; m(129) := x"0000"; m(130) := x"1080"; -- MOVEA.L #$1080,A7
        m(131) := x"F017"; m(132) := x"4C00";                    -- PMOVE (A7),CRP
        m(133) := x"2E7C"; m(134) := x"0000"; m(135) := x"1088"; -- MOVEA.L #$1088,A7
        m(136) := x"F017"; m(137) := x"4800";                    -- PMOVE (A7),SRP
        m(138) := x"F000"; m(139) := x"2400";                    -- PFLUSHA
        m(140) := x"F038"; m(141) := x"4000"; m(142) := x"1090"; -- PMOVE ($1090).W,TC
        m(143) := x"4E71"; m(144) := x"4E71";
        m(145) := x"2E7C"; m(146) := x"0000"; m(147) := x"2000"; -- MOVEA.L #$2000,A7
        m(148) := x"203C"; m(149) := x"1111"; m(150) := x"1111"; -- MOVE.L #$11111111,D0
        m(151) := x"223C"; m(152) := x"2222"; m(153) := x"2222"; -- MOVE.L #$22222222,D1
        m(154) := x"243C"; m(155) := x"3333"; m(156) := x"3333"; -- MOVE.L #$33333333,D2
        m(157) := x"2C7C"; m(158) := x"0000"; m(159) := x"1E00"; -- MOVEA.L #$1E00,A6
        m(160) := x"4EF8"; m(161) := x"03FE";                    -- JMP ($03FE).W

        -- $03FE: MOVEM.L D0-D2,-(A6)  (opcode = last word of page 0)
        m(511) := x"48E6";
        -- $0400: mask $E000 (D0-D2 predecrement order) - PAGE 1, INVALID
        m(512) := x"E000";
        -- $0402: STOP #$2700 (runs after the re-executed MOVEM completes)
        m(513) := x"4E72"; m(514) := x"2700";

        -- CRP / SRP / TC images
        m(2112) := x"8000"; m(2113) := x"0002"; m(2114) := x"0000"; m(2115) := x"6000";
        m(2116) := x"8000"; m(2117) := x"0002"; m(2118) := x"0000"; m(2119) := x"6000";
        m(2120) := x"82A0"; m(2121) := x"8680";

        -- Root slot 0 -> table $6800; level-B slot 0 -> level-C table $6E00
        m(12288) := x"0000"; m(12289) := x"6802";
        m(13312) := x"0000"; m(13313) := x"6E02";
        -- Level-C (1K pages): slot 0 = code page 0 identity
        m(14080) := x"0000"; m(14081) := x"0061";
        -- Slot 1 ($0400-$07FF): EXPLICITLY INVALID (DT=00) - the mask page
        m(14082) := x"0000"; m(14083) := x"0000";
        -- Slot 7 ($1C00-$1FFF): stack/data page identity
        m(14094) := x"0000"; m(14095) := x"1C61";

        -- Pre-clear the MOVEM landing zone ($1DE0-$1DFF) and the counter
        for i in 0 to 15 loop
            m(3824 + i) := x"0000";  -- words $1DE0..$1DFE
        end loop;
        m(4032) := x"0000"; m(4033) := x"0000";  -- counter long at $1F80

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
            debug_clkena_lw => open, debug_regfile_d0 => debug_regfile_d0, debug_regfile_a0 => open,
            debug_fline_context_valid => open, debug_trap_1111 => open, debug_trapmake => open,
            debug_pmmu_brief => open, debug_use_base => open, debug_rf_source_addr => open,
            debug_pmove_ea_latched => open, debug_reg_QA => open, debug_last_data_read => open,
            debug_last_opc_pc => open, debug_getbrief => open, debug_get_2ndopc => open,
            debug_fline_brief_pending => open, debug_fline_opcode_pc => open, debug_exe_PC => open,
            debug_memaddr_delta_rega => open, debug_memaddr_delta_regb => open, debug_addsub_q => open,
            debug_memmaskmux => open, debug_fline_opcode_latch => open, debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open, debug_exec_directPC => open, debug_exec_mem_addsub => open,
            debug_set_addrlong => open, debug_mdelta_src => open, debug_pc_brw => open, debug_pc_word => open,
            debug_regfile_d1 => debug_regfile_d1, debug_regfile_d2 => debug_regfile_d2,
            debug_regfile_d3 => open, debug_regfile_d4 => open,
            debug_regfile_d5 => open, debug_regfile_d6 => open, debug_regfile_d7 => open, debug_regfile_a1 => open,
            debug_regfile_a2 => open, debug_regfile_a3 => open, debug_regfile_a4 => open, debug_regfile_a5 => open,
            debug_regfile_a6 => debug_regfile_a6, debug_regfile_a7 => open, debug_regfile_we => open,
            debug_regfile_waddr => open,
            debug_regfile_wdata => open, debug_trap_illegal => open, debug_trap_priv => open,
            debug_trap_addr_error => open, debug_trap_berr => open,
            debug_trap_mmu_berr => open, debug_trap_vector => debug_trap_vector,
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
            debug_pmmu_ptr1_desc_addr => open,
            debug_pmmu_ptr1_desc_data => open,
            debug_pmmu_ptr2_desc_addr => open,
            debug_pmmu_ptr2_desc_data => open,
            debug_pmmu_ptr3_desc_addr => open,
            debug_pmmu_ptr3_desc_data => open,
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
                if not is_x(pmmu_walker_addr) and unsigned(pmmu_walker_addr) < x"00008000" then
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
                if debug_TG68_PC = x"00000080" and not handler_seen then
                    handler_seen <= true;
                    handler_entries <= handler_entries + 1;
                    report "MOVEM_TRACE: entered vector2 handler #"
                           & integer'image(handler_entries + 1) severity note;
                elsif debug_TG68_PC /= x"00000080" and handler_seen then
                    handler_seen <= false;
                end if;
            end if;
        end if;
    end process;

    main_test: process
        variable stored0, stored1, stored2 : std_logic_vector(31 downto 0);
        variable below0, below1 : std_logic_vector(31 downto 0);
        variable counter : std_logic_vector(31 downto 0);
    begin
        report "=== BUG #458: MOVEM MASK-WORD PAGE FAULT MUST RESTART ===" severity note;
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 40000 loop
            wait until rising_edge(clk);
            if debug_cpu_halted = '1' or debug_stop = '1' then
                exit;
            end if;
        end loop;

        counter := mem(4032) & mem(4033);                    -- $1F80
        stored0 := mem(16#0EFA#) & mem(16#0EFB#);            -- $1DF4
        stored1 := mem(16#0EFC#) & mem(16#0EFD#);            -- $1DF8
        stored2 := mem(16#0EFE#) & mem(16#0EFF#);            -- $1DFC
        below0  := mem(16#0EF6#) & mem(16#0EF7#);            -- $1DEC
        below1  := mem(16#0EF8#) & mem(16#0EF9#);            -- $1DF0

        if debug_cpu_halted = '1' then
            report "FAIL: cpu_halted asserted PC=$" & slv_to_hex(debug_TG68_PC)
                   & " trapvec=$" & slv_to_hex(debug_trap_vector)
                   & " handler_entries=" & integer'image(handler_entries)
                   & " A6=$" & slv_to_hex(debug_regfile_a6)
                   & " mmusr=$" & slv_to_hex(debug_pmmu_fault_status)
                   & " fault_addr=$" & slv_to_hex(debug_pmmu_saved_addr)
                   & " desc_addr=$" & slv_to_hex(debug_pmmu_walk_desc_addr)
                   & " desc_data=$" & slv_to_hex(debug_pmmu_walk_desc_data)
                   severity failure;
        elsif debug_stop /= '1' then
            report "FAIL: never reached STOP, PC=$" & slv_to_hex(debug_TG68_PC)
                   & " handler_entries=" & integer'image(handler_entries)
                   & " A6=$" & slv_to_hex(debug_regfile_a6) severity failure;
        else
            if handler_entries /= 1 then
                report "FAIL (BUG #458): expected exactly 1 restartable fault, got "
                       & integer'image(handler_entries) severity failure;
            end if;
            if debug_regfile_a6 /= x"00001DF4" then
                report "FAIL (BUG #458): A6=$" & slv_to_hex(debug_regfile_a6)
                       & " (garbage-mask MOVEM ran before the fault?)" severity failure;
            else
                report "PASS: A6 = $1DF4 (exactly 3 longs pushed)" severity note;
            end if;
            if stored0 /= x"11111111" or stored1 /= x"22222222" or stored2 /= x"33333333" then
                report "FAIL (BUG #458): stored set wrong: $" & slv_to_hex(stored0)
                       & " $" & slv_to_hex(stored1) & " $" & slv_to_hex(stored2)
                       severity failure;
            else
                report "PASS: D0-D2 stored correctly at $1DF4-$1DFF" severity note;
            end if;
            if below0 /= x"00000000" or below1 /= x"00000000" then
                report "FAIL (BUG #458): stores below $1DF4 - garbage mask stored extra regs"
                       severity failure;
            else
                report "PASS: no stray stores below the real frame" severity note;
            end if;
            if debug_regfile_d0 = x"11111111" and debug_regfile_d1 = x"22222222" and
               debug_regfile_d2 = x"33333333" then
                report "PASS: D0-D2 unchanged" severity note;
            else
                report "FAIL: D0-D2 modified" severity failure;
            end if;
            report "PASS: BUG #458 regression complete - MOVEM mask fault restarted cleanly"
                   severity note;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
