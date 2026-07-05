-- tb_mmu_captured_badfeed_dispatch.vhd
--
-- Captured-hardware style diagnostic for the MuForce/NetBSD double-fault
-- signature:
--   TC      = $82A08680  (E=1, SRE=1, 1K pages, TIA=8/TIB=6/TIC=8)
--   CRP     = $80000002_$40090000
--   SRP     = $80000002_$40080000
--   fault   = user data read at $00002C00 through CRP
--   target  = final-level indirect descriptor target containing $BADFEED0
--   stack   = supervisor A7 in the $40079Bxx page, translated through SRP
--
-- The handler deliberately only records the frame and STOPs. The purpose of
-- this bench is exception dispatch visibility: if the first fault is followed
-- by a genuine second fault while berr_exception_active='1', the trace reports
-- the live address/FC/RW/is-insn metadata without JTAG sampling ambiguity.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_mmu_captured_badfeed_dispatch is
end entity;

architecture behavioral of tb_mmu_captured_badfeed_dispatch is

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
        variable v : std_logic_vector(value'length - 1 downto 0);
    begin
        v := value;
        for i in 0 to (v'length/4 - 1) loop
            nibble := v(v'length - 1 - i*4 downto v'length - 4 - i*4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
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

    -- Map low physical memory directly and map each captured high page-table
    -- window into a private local 4K window. This preserves the captured
    -- physical root/table addresses without needing a sparse-memory package.
    function mem_word_index(addr : std_logic_vector(31 downto 0)) return integer is
        variable page_word : integer;
    begin
        if is_x(addr) then
            return -1;
        end if;

        if unsigned(addr) < x"00010000" then
            return to_integer(unsigned(addr(16 downto 1)));
        end if;

        page_word := to_integer(unsigned(addr(11 downto 1)));
        case addr(31 downto 12) is
            when x"40080" => return 16#8000# + page_word; -- SRP root
            when x"40090" => return 16#8800# + page_word; -- CRP root
            when x"400A0" => return 16#9000# + page_word; -- CRP B table
            when x"400B0" => return 16#9800# + page_word; -- CRP C table
            when x"400C0" => return 16#A000# + page_word; -- CRP indirect target
            when x"400D0" => return 16#A800# + page_word; -- SRP low B table
            when x"400E0" => return 16#B000# + page_word; -- SRP low C table
            when x"400F0" => return 16#B800# + page_word; -- SRP stack B table
            when x"40100" => return 16#C000# + page_word; -- SRP stack C table
            when x"40110" => return 16#C800# + page_word; -- SRP stack indirect target
            when others   => return -1;
        end case;
    end function;

    function add_bytes(base : std_logic_vector(31 downto 0); offset : natural)
        return std_logic_vector is
    begin
        return std_logic_vector(unsigned(base) + to_unsigned(offset, 32));
    end function;

    constant CLK_PERIOD : time := 10 ns;

    constant SRP_ROOT  : std_logic_vector(31 downto 0) := x"40080000";
    constant CRP_ROOT  : std_logic_vector(31 downto 0) := x"40090000";
    constant CRP_BTAB  : std_logic_vector(31 downto 0) := x"400A0000";
    constant CRP_CTAB  : std_logic_vector(31 downto 0) := x"400B0000";
    constant CRP_BAD   : std_logic_vector(31 downto 0) := x"400C0000";
    constant SRP_BLOW  : std_logic_vector(31 downto 0) := x"400D0000";
    constant SRP_CLOW  : std_logic_vector(31 downto 0) := x"400E0000";
    constant SRP_BSTK  : std_logic_vector(31 downto 0) := x"400F0000";
    constant SRP_CSTK  : std_logic_vector(31 downto 0) := x"40100000";
    constant SRP_STKID : std_logic_vector(31 downto 0) := x"40110000";

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
    signal debug_opcode        : std_logic_vector(15 downto 0);
    signal debug_state         : std_logic_vector(1 downto 0);
    signal debug_micro_state   : integer range 0 to 255;
    signal debug_trap_berr     : std_logic;
    signal debug_trap_mmu_berr : std_logic;
    signal debug_trap_addr_error : std_logic;
    signal debug_trap_vector   : std_logic_vector(31 downto 0);
    signal debug_pmmu_busy     : std_logic;
    signal debug_cpu_halted    : std_logic;
    signal debug_stop          : std_logic;
    signal debug_make_berr     : std_logic;
    signal debug_pmmu_fault    : std_logic;
    signal debug_berr_exception_active : std_logic;
    signal debug_pmmu_fault_dispatched : std_logic;
    signal debug_pmmu_fault_was_cleared : std_logic;
    signal debug_pmmu_fault_rw : std_logic;
    signal debug_pmmu_fault_is_insn : std_logic;
    signal debug_pmmu_fault_fc : std_logic_vector(2 downto 0);
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
    signal debug_pmmu_saved_fc       : std_logic_vector(2 downto 0);
    signal debug_regfile_a7          : std_logic_vector(31 downto 0);
    signal debug_regfile_d0          : std_logic_vector(31 downto 0);

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';

    signal first_fault_seen  : boolean := false;
    signal active_fault_seen : boolean := false;
    signal handler_seen      : boolean := false;

    type mem_type is array(0 to 65535) of std_logic_vector(15 downto 0);

    procedure put32(variable m : inout mem_type;
                    addr : std_logic_vector(31 downto 0);
                    value : std_logic_vector(31 downto 0)) is
        variable idx : integer;
    begin
        idx := mem_word_index(addr);
        assert idx >= 0 report "put32 address outside mapped memory: $" & slv_to_hex(addr)
            severity failure;
        m(idx)     := value(31 downto 16);
        m(idx + 1) := value(15 downto 0);
    end procedure;

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        ------------------------------------------------------------------
        -- Reset/vector table and code in low physical memory.
        ------------------------------------------------------------------
        put32(m, x"00000000", x"00002000"); -- reset SSP, overwritten before fault
        put32(m, x"00000004", x"00000300"); -- reset PC
        put32(m, x"00000008", x"00000200"); -- vector 2 bus/MMU error
        for i in 3 to 63 loop
            put32(m, std_logic_vector(to_unsigned(i * 4, 32)), x"00000280");
        end loop;

        -- Vector 2 handler at $0200: record dispatch/frame fields and STOP.
        -- $0200: MOVE.L #$C0DEC0DE,($0600).W
        m(16#0100#) := x"21FC"; m(16#0101#) := x"C0DE";
        m(16#0102#) := x"C0DE"; m(16#0103#) := x"0600";
        -- $0208: MOVE.L A7,($0604).W
        m(16#0104#) := x"21CF"; m(16#0105#) := x"0604";
        -- $020C: MOVE.W ($0006,SP),D0 ; format/vector
        m(16#0106#) := x"302F"; m(16#0107#) := x"0006";
        -- $0210: MOVE.W D0,($0608).W
        m(16#0108#) := x"31C0"; m(16#0109#) := x"0608";
        -- $0214: MOVE.L ($0002,SP),D1 ; stacked PC
        m(16#010A#) := x"222F"; m(16#010B#) := x"0002";
        -- $0218: MOVE.L D1,($060C).W
        m(16#010C#) := x"21C1"; m(16#010D#) := x"060C";
        -- $021C: MOVE.L ($0010,SP),D2 ; fault address for format B
        m(16#010E#) := x"242F"; m(16#010F#) := x"0010";
        -- $0220: MOVE.L D2,($0610).W
        m(16#0110#) := x"21C2"; m(16#0111#) := x"0610";
        -- $0224: STOP #$2700
        m(16#0112#) := x"4E72"; m(16#0113#) := x"2700";

        -- Unexpected trap handler at $0280.
        m(16#0140#) := x"21FC"; m(16#0141#) := x"BAD0";
        m(16#0142#) := x"BAD0"; m(16#0143#) := x"0620";
        m(16#0144#) := x"4E72"; m(16#0145#) := x"2700";

        -- Setup program at $0300.
        -- PMOVE ($0504).W,CRP
        m(16#0180#) := x"F038"; m(16#0181#) := x"4C00"; m(16#0182#) := x"0504";
        -- PMOVE ($050C).W,SRP
        m(16#0183#) := x"F038"; m(16#0184#) := x"4800"; m(16#0185#) := x"050C";
        -- PFLUSHA
        m(16#0186#) := x"F000"; m(16#0187#) := x"2400";
        -- PMOVE ($0500).W,TC
        m(16#0188#) := x"F038"; m(16#0189#) := x"4000"; m(16#018A#) := x"0500";
        -- NOP settle after enabling translation
        m(16#018B#) := x"4E71"; m(16#018C#) := x"4E71"; m(16#018D#) := x"4E71";
        -- SSP before the user bus-fault push. The current tree still has the
        -- documented user-fault stack leak and pushes 88 bytes, so this lands
        -- the handler at the captured $40079B1C signature.
        m(16#018E#) := x"2E7C"; m(16#018F#) := x"4007"; m(16#0190#) := x"9B74";
        -- Enter user mode so the $2C00 data access uses CRP, not SRP.
        m(16#0191#) := x"46FC"; m(16#0192#) := x"0000";
        -- User data read: MOVE.L $00002C00,D0. Expected first fault.
        m(16#0193#) := x"2039"; m(16#0194#) := x"0000"; m(16#0195#) := x"2C00";
        -- Fallthrough marker if the BADFEED descriptor does not fault.
        m(16#0196#) := x"21FC"; m(16#0197#) := x"0BAD";
        m(16#0198#) := x"F00D"; m(16#0199#) := x"0618";
        m(16#019A#) := x"4E72"; m(16#019B#) := x"2700";

        -- PMOVE source data at $0500.
        put32(m, x"00000500", x"82A08680"); -- TC
        put32(m, x"00000504", x"80000002"); -- CRP_H
        put32(m, x"00000508", x"40090000"); -- CRP_L
        put32(m, x"0000050C", x"80000002"); -- SRP_H
        put32(m, x"00000510", x"40080000"); -- SRP_L

        -- Result area at $0600.
        for i in 16#0300# to 16#031F# loop
            m(i) := x"0000";
        end loop;

        ------------------------------------------------------------------
        -- CRP user tree for $00002C00 and low user instruction fetches.
        ------------------------------------------------------------------
        put32(m, add_bytes(CRP_ROOT, 0 * 4), x"400A0002"); -- root[0] -> B
        put32(m, add_bytes(CRP_BTAB, 0 * 4), x"400B0002"); -- B[0] -> C
        put32(m, add_bytes(CRP_CTAB, 0 * 4), x"00000061"); -- VA $0000 page
        put32(m, add_bytes(CRP_CTAB, 1 * 4), x"00000461"); -- VA $0400 page
        put32(m, add_bytes(CRP_CTAB, 11 * 4), x"400C0002"); -- $2C00 -> indirect
        put32(m, CRP_BAD, x"BADFEED0"); -- captured BADFEED-style invalid target

        ------------------------------------------------------------------
        -- SRP supervisor tree: low vectors/code/result plus $40079Bxx stack.
        ------------------------------------------------------------------
        put32(m, add_bytes(SRP_ROOT, 0 * 4), x"400D0002");  -- root[0] -> low B
        put32(m, add_bytes(SRP_ROOT, 64 * 4), x"400F0002"); -- root[64] -> stack B

        put32(m, add_bytes(SRP_BLOW, 0 * 4), x"400E0002"); -- low B[0] -> low C
        put32(m, add_bytes(SRP_CLOW, 0 * 4), x"00000061"); -- vectors/code
        put32(m, add_bytes(SRP_CLOW, 1 * 4), x"00000461"); -- result/data

        put32(m, add_bytes(SRP_BSTK, 1 * 4), x"40100002"); -- stack B[1] -> C
        put32(m, add_bytes(SRP_CSTK, 16#E6# * 4), x"40110002"); -- stack C[$E6]
        put32(m, SRP_STKID, x"00001C61"); -- stack page -> phys $00001C00

        return m;
    end function;

    signal mem : mem_type := init_mem;

begin

    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
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
            debug_pmove_dn_mode => open, debug_pmove_dn_regnum => open, debug_opcode => debug_opcode,
            debug_state => debug_state, debug_setstate => open, debug_last_opc_read => open,
            debug_data_read => open, debug_direct_data => open, debug_setnextpass => open,
            debug_TG68_PC => debug_TG68_PC, debug_memaddr_reg => open, debug_memaddr_delta => open,
            debug_oddout => open, debug_decodeOPC => open, debug_brief => open,
            debug_moves_bus_pending => open, debug_moves_writeback_pending => open, debug_clkena_lw => open,
            debug_regfile_d0 => debug_regfile_d0, debug_regfile_a0 => open,
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
            debug_regfile_d5 => open, debug_regfile_d6 => open, debug_regfile_d7 => open,
            debug_regfile_a1 => open, debug_regfile_a2 => open, debug_regfile_a3 => open, debug_regfile_a4 => open,
            debug_regfile_a5 => open, debug_regfile_a6 => open, debug_regfile_a7 => debug_regfile_a7,
            debug_regfile_we => open, debug_regfile_waddr => open, debug_regfile_wdata => open,
            debug_trap_illegal => open, debug_trap_priv => open, debug_trap_addr_error => debug_trap_addr_error,
            debug_trap_berr => debug_trap_berr, debug_trap_mmu_berr => debug_trap_mmu_berr,
            debug_trap_vector => debug_trap_vector, debug_pc_add => open, debug_pc_dataa => open,
            debug_pc_datab => open, debug_pmmu_busy => debug_pmmu_busy, debug_cpu_halted => debug_cpu_halted,
            debug_stop => debug_stop, debug_interrupt => open, debug_setendOPC => open, debug_IPL_nr => open,
            debug_micro_state => debug_micro_state, debug_next_micro_state => open, debug_memmask => open,
            debug_sndOPC => open, debug_pmmu_reg_we => open, debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open, debug_pmmu_reg_wdat => open, debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open, debug_make_berr => debug_make_berr,
            debug_pmmu_fault => debug_pmmu_fault, debug_berr_exception_active => debug_berr_exception_active,
            debug_pmmu_fault_dispatched => debug_pmmu_fault_dispatched,
            debug_pmmu_fault_was_cleared => debug_pmmu_fault_was_cleared,
            debug_pmmu_fault_rw => debug_pmmu_fault_rw,
            debug_pmmu_fault_is_insn => debug_pmmu_fault_is_insn,
            debug_pmmu_fault_fc => debug_pmmu_fault_fc,
            debug_trap_format_error => open, debug_format_error_rte_word => open,
            debug_format_error_pc => open, debug_format_error_addr => open, debug_format_error_sr => open,
            debug_pmmu_tc => open, debug_pmmu_tt0 => open, debug_pmmu_tt1 => open,
            debug_pmmu_crp_hi => open, debug_pmmu_crp_lo => open, debug_pmmu_srp_hi => open,
            debug_pmmu_srp_lo => open, debug_pmmu_wstate => open,
            debug_pmmu_atc_buserr => open, debug_pmmu_atc_valid => open,
            debug_pmmu_pending_flags => open,
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
            debug_make_trace => open, debug_trace_pending_grp2 => open, debug_useStackframe2 => open,
            debug_exec_trap_chk => open, debug_set_trap_chk => open, debug_data_write_tmp => open,
            debug_FlagsSR => open, debug_USP => open, debug_MSP => open, debug_ISP => open,
            debug_a7_is_msp => open, debug_interrupt_mode => open, debug_rte_saved_mbit => open,
            debug_rte_format_word => open
        );

    mem_read: process(pmmu_addr_phys, mem)
        variable idx : integer;
    begin
        idx := mem_word_index(pmmu_addr_phys);
        if idx >= 0 then
            data_in <= mem(idx);
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
                phys_word := mem_word_index(pmmu_addr_phys);
                if phys_word >= 0 then
                    if nUDS = '0' and nLDS = '0' then
                        mem(phys_word) <= data_write;
                    elsif nUDS = '0' then
                        mem(phys_word)(15 downto 8) <= data_write(15 downto 8);
                    elsif nLDS = '0' then
                        mem(phys_word)(7 downto 0) <= data_write(7 downto 0);
                    end if;
                else
                    report "CPU write outside mapped memory: phys=$" & slv_to_hex(pmmu_addr_phys) &
                           " log=$" & slv_to_hex(pmmu_addr_log) &
                           " data=$" & slv_to_hex(data_write) severity warning;
                end if;
            end if;

            if pmmu_walker_req = '1' then
                walker_word := mem_word_index(pmmu_walker_addr);
                if walker_word >= 0 then
                    if pmmu_walker_we = '1' then
                        mem(walker_word)     <= pmmu_walker_wdat(31 downto 16);
                        mem(walker_word + 1) <= pmmu_walker_wdat(15 downto 0);
                    else
                        pmmu_walker_data <= mem(walker_word) & mem(walker_word + 1);
                    end if;
                else
                    pmmu_walker_data <= x"00000000";
                    report "Walker access outside mapped memory: addr=$" &
                           slv_to_hex(pmmu_walker_addr) severity warning;
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

    trace_events: process(clk)
        variable prev_fault : std_logic := '0';
        variable prev_active : std_logic := '0';
        variable prev_halted : std_logic := '0';
    begin
        if rising_edge(clk) then
            if nReset = '1' then
                if debug_pmmu_fault = '1' and prev_fault = '0' then
                    if not first_fault_seen then
                        first_fault_seen <= true;
                    end if;
                    if debug_berr_exception_active = '1' then
                        active_fault_seen <= true;
                    end if;
                    report "PMMU_FAULT_RISE: active=" & std_logic'image(debug_berr_exception_active) &
                           " dispatched=" & std_logic'image(debug_pmmu_fault_dispatched) &
                           " was_cleared=" & std_logic'image(debug_pmmu_fault_was_cleared) &
                           " live_log=$" & slv_to_hex(pmmu_addr_log) &
                           " saved_addr=$" & slv_to_hex(debug_pmmu_saved_addr) &
                           " fc=" & slv_to_hex("0" & debug_pmmu_fault_fc) &
                           " rw=" & std_logic'image(debug_pmmu_fault_rw) &
                           " is_insn=" & std_logic'image(debug_pmmu_fault_is_insn) &
                           " mmusr=$" & slv_to_hex(debug_pmmu_fault_status) &
                           " pc=$" & slv_to_hex(debug_TG68_PC) &
                           " a7=$" & slv_to_hex(debug_regfile_a7) &
                           " desc=$" & slv_to_hex(debug_pmmu_walk_desc_addr) &
                           ":" & slv_to_hex(debug_pmmu_walk_desc_data) severity note;
                end if;
                if debug_berr_exception_active /= prev_active then
                    report "BERR_ACTIVE=" & std_logic'image(debug_berr_exception_active) &
                           " pc=$" & slv_to_hex(debug_TG68_PC) &
                           " a7=$" & slv_to_hex(debug_regfile_a7) &
                           " fault=" & std_logic'image(debug_pmmu_fault) severity note;
                end if;
                if debug_TG68_PC = x"00000200" and not handler_seen then
                    handler_seen <= true;
                    report "HANDLER_FETCHED: pc=$00000200 a7=$" &
                           slv_to_hex(debug_regfile_a7) severity note;
                end if;
                if debug_cpu_halted = '1' and prev_halted = '0' then
                    report "CPU_HALTED: pc=$" & slv_to_hex(debug_TG68_PC) &
                           " opcode=$" & slv_to_hex(debug_opcode) &
                           " a7=$" & slv_to_hex(debug_regfile_a7) &
                           " trapvec=$" & slv_to_hex(debug_trap_vector) &
                           " active=" & std_logic'image(debug_berr_exception_active) &
                           " fault=" & std_logic'image(debug_pmmu_fault) &
                           " saved_addr=$" & slv_to_hex(debug_pmmu_saved_addr) &
                           " live_log=$" & slv_to_hex(pmmu_addr_log) &
                           " fc=" & slv_to_hex("0" & debug_pmmu_fault_fc) &
                           " rw=" & std_logic'image(debug_pmmu_fault_rw) &
                           " is_insn=" & std_logic'image(debug_pmmu_fault_is_insn) &
                           " mmusr=$" & slv_to_hex(debug_pmmu_fault_status) severity error;
                end if;
                prev_fault := debug_pmmu_fault;
                prev_active := debug_berr_exception_active;
                prev_halted := debug_cpu_halted;
            end if;
        end if;
    end process;

    main_test: process
        variable handler_marker : std_logic_vector(31 downto 0);
        variable unexpected_marker : std_logic_vector(31 downto 0);
        variable fallthrough_marker : std_logic_vector(31 downto 0);
        variable handler_a7 : std_logic_vector(31 downto 0);
        variable frame_fmt : std_logic_vector(15 downto 0);
        variable frame_pc : std_logic_vector(31 downto 0);
        variable frame_fault : std_logic_vector(31 downto 0);
        variable fail_count : integer := 0;
    begin
        report "=== CAPTURED BADFEED DISPATCH DIAGNOSTIC ===" severity note;
        report "TC=$82A08680 CRP=$80000002_$40090000 SRP=$80000002_$40080000" severity note;

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 500000 loop
            wait until rising_edge(clk);
            handler_marker := mem(16#0300#) & mem(16#0301#);
            unexpected_marker := mem(16#0310#) & mem(16#0311#);
            fallthrough_marker := mem(16#030C#) & mem(16#030D#);
            if unexpected_marker = x"BAD0BAD0" or fallthrough_marker = x"0BADF00D" or
               debug_cpu_halted = '1' or debug_stop = '1' then
                exit;
            end if;
        end loop;

        handler_marker := mem(16#0300#) & mem(16#0301#);
        handler_a7 := mem(16#0302#) & mem(16#0303#);
        frame_fmt := mem(16#0304#);
        frame_pc := mem(16#0306#) & mem(16#0307#);
        frame_fault := mem(16#0308#) & mem(16#0309#);
        unexpected_marker := mem(16#0310#) & mem(16#0311#);
        fallthrough_marker := mem(16#030C#) & mem(16#030D#);

        report "SUMMARY: handler=$" & slv_to_hex(handler_marker) &
               " handler_a7=$" & slv_to_hex(handler_a7) &
               " fmt=$" & slv_to_hex(frame_fmt) &
               " frame_pc=$" & slv_to_hex(frame_pc) &
               " frame_fault=$" & slv_to_hex(frame_fault) &
               " unexpected=$" & slv_to_hex(unexpected_marker) &
               " fallthrough=$" & slv_to_hex(fallthrough_marker) &
               " halted=" & std_logic'image(debug_cpu_halted) &
               " active_fault_seen=" & boolean'image(active_fault_seen) severity note;

        if not first_fault_seen then
            report "FAIL: no PMMU fault was observed" severity error;
            fail_count := fail_count + 1;
        end if;
        if debug_cpu_halted = '1' then
            report "FAIL: double bus fault halt reproduced; see CPU_HALTED trace above" severity error;
            fail_count := fail_count + 1;
        end if;
        if active_fault_seen then
            report "FAIL: a PMMU fault rose while berr_exception_active was already set" severity error;
            fail_count := fail_count + 1;
        end if;
        if unexpected_marker = x"BAD0BAD0" then
            report "FAIL: unexpected trap handler executed" severity error;
            fail_count := fail_count + 1;
        end if;
        if fallthrough_marker = x"0BADF00D" then
            report "FAIL: BADFEED access retired instead of faulting" severity error;
            fail_count := fail_count + 1;
        end if;
        if handler_marker /= x"C0DEC0DE" then
            report "FAIL: vector 2 handler did not execute" severity error;
            fail_count := fail_count + 1;
        end if;
        if handler_a7 /= x"40079B1C" then
            report "FAIL: handler A7 $" & slv_to_hex(handler_a7) &
                   " expected captured $40079B1C signature" severity error;
            fail_count := fail_count + 1;
        end if;
        if frame_fmt /= x"B008" then
            report "FAIL: format/vector $" & slv_to_hex(frame_fmt) &
                   " expected format B, vector 2 ($B008)" severity error;
            fail_count := fail_count + 1;
        end if;
        if frame_fault /= x"00002C00" then
            report "FAIL: frame fault address $" & slv_to_hex(frame_fault) &
                   " expected $00002C00" severity error;
            fail_count := fail_count + 1;
        end if;

        if fail_count = 0 then
            report "PASS: captured BADFEED fault dispatched cleanly; no stacking-time second PMMU fault" severity note;
        else
            assert false report "captured BADFEED dispatch diagnostic failed" severity failure;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
