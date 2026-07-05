-- tb_mmu_stacking_walk_fault.vhd
--
-- NetBSD-exact reproduction of the hardware double-fault-during-stacking halt:
--   TC=$82D08B00 (E, SRE=1, 8K pages, TIA=8/TIB=11), short descriptors,
--   SEPARATE SRP (kernel) and CRP (user) two-level trees. Vectors (VBR=$1000),
--   handler, supervisor code and the SUPERVISOR STACK all live on SRP-WALKED
--   pages (never identity/early-termination). PFLUSHA immediately before the
--   fault guarantees the exception stacking writes MISS the ATC and must
--   table-walk mid-dispatch. The fault itself is the exact NetBSD copyout
--   shape: supervisor MOVES.B with DFC=1 to unmapped user address $1DFFFFF5.
--   Handler = NetBSD-style: fix the PTE, PFLUSH #0,#0,(va), plain RTE.
-- PASS = exactly one fault, write completed after restart, SSP balanced,
--        cpu_halted never asserts.
-- FAIL/halt here = the hardware cascade reproduced in simulation.

--
-- NetBSD demand-paging contract test for MMU fault RESTART semantics
-- (MMU_RESTART_DESIGN.md). The bus-error handler does exactly what
-- NetBSD/amiga does: read fault address from the frame, fix the page
-- table entry, PFLUSH #0,#0,(va) (= NetBSD TBIS), then execute a plain
-- RTE with an UNMODIFIED frame. The faulted instruction must re-execute
-- correctly:
--   Test 1: MOVE.L (A0)+,D2 read fault  -> D2 loaded, A0 incremented ONCE
--   Test 2: MOVE.L D3,-(A2) write fault -> memory written, A2 decremented ONCE
--   Test 3: ADD.L (A5),D5 read fault    -> sum and CCR (X/Z/C) correct
--   Test 4: MOVEM.L D4-D7,(A3) write fault on first transfer -> all 4 stored
--   Test 5: MOVEM.L (A4)+,D4-D7 crossing into an invalid page (fault on the
--           3rd transfer) -> partial loads rolled back, all 4 reloaded,
--           A4 advanced ONCE
-- Page tables: 3-level short format (TC=$80D04780: 8K pages, TIA=4/TIB=7/TIC=8),
-- root entries 0-12,14,15 early-termination identity, entry 13 -> B table ->
-- C table with initially-invalid page descriptors the handler fills in.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_mmu_stacking_walk_fault is
end entity;

architecture behavioral of tb_mmu_stacking_walk_fault is

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
    signal debug_state         : std_logic_vector(1 downto 0);
    signal debug_micro_state   : integer range 0 to 255;
    signal debug_clkena_lw     : std_logic;
    signal debug_trap_berr     : std_logic;
    signal debug_trap_mmu_berr : std_logic;
    signal debug_make_berr     : std_logic;
    signal debug_pmmu_fault    : std_logic;
    signal debug_trap_vector   : std_logic_vector(31 downto 0);
    signal debug_cpu_halted    : std_logic;
    signal debug_stop_sig      : std_logic;
    signal debug_pmmu_busy     : std_logic;
    signal debug_SVmode        : std_logic;

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';
    signal ipl_n : std_logic_vector(2 downto 0) := "111";

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
        variable w : integer;
    begin
        -- Reset vectors (always fetched from phys 0): SSP=$3F00, PC=$0100
        m(0) := x"0000"; m(1) := x"3F00";
        m(2) := x"0000"; m(3) := x"0100";

        ------------------------------------------------------------------
        -- Vector table at VBR=$1000 (phys $1000, SRP-walked page K0)
        ------------------------------------------------------------------
        for i in 0 to 63 loop
            m(16#0800# + i*2)     := x"0000";
            m(16#0800# + i*2 + 1) := x"04C0";  -- unexpected handler
        end loop;
        m(16#0800# + 4) := x"0000"; m(16#0800# + 5) := x"0400";  -- vector 2
        m(16#0800# + 60) := x"0000"; m(16#0800# + 61) := x"04E0"; -- vector 30 (autovector lvl 6)
        m(16#0270#) := x"52B9"; m(16#0271#) := x"0000"; m(16#0272#) := x"2F18";  -- $04E0: ADDQ.L #1,$2F18 (irq count)
        m(16#0273#) := x"4E73";                                   -- RTE

        ------------------------------------------------------------------
        -- Main program at $0100 (VA=PA via SRP-walked page K0)
        ------------------------------------------------------------------
        w := 128;
        m(w) := x"207C"; m(w+1) := x"0000"; m(w+2) := x"1000"; w := w+3;  -- MOVEA.L #$1000,A0
        m(w) := x"4E7B"; m(w+1) := x"8801"; w := w+2;                     -- MOVEC A0,VBR
        m(w) := x"7001"; w := w+1;                                        -- MOVEQ #1,D0
        m(w) := x"4E7B"; m(w+1) := x"0001"; w := w+2;                     -- MOVEC D0,DFC (user data space)
        m(w) := x"F038"; m(w+1) := x"4800"; m(w+2) := x"1080"; w := w+3;  -- PMOVE ($1080).W,SRP
        m(w) := x"F038"; m(w+1) := x"4C00"; m(w+2) := x"1090"; w := w+3;  -- PMOVE ($1090).W,CRP
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"F038"; m(w+1) := x"4000"; m(w+2) := x"1088"; w := w+3;  -- PMOVE ($1088).W,TC (MMU ON, SRE=1)
        m(w) := x"4E71"; w := w+1;                                        -- NOP
        m(w) := x"46FC"; m(w+1) := x"2000"; w := w+2;                     -- MOVE #$2000,SR (supervisor, IPL mask 0)
        m(w) := x"745A"; w := w+1;                                        -- MOVEQ #$5A,D2
        m(w) := x"227C"; m(w+1) := x"1DFF"; m(w+2) := x"FFF5"; w := w+3;  -- MOVEA.L #$1DFFFFF5,A1
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA (stack page NOT in ATC)
        m(w) := x"0E11"; m(w+1) := x"2800"; w := w+2;                     -- MOVES.B D2,(A1)  FAULT (fc=1 write)
        -- NOTE (2026-07-03): instruction-fetch restart was tried and reverted
        -- (see TG68KdotC_Kernel.vhd mmu_restart_dispatch comment - it caused an
        -- infinite loop on speculative readahead faults, matching a real
        -- hardware NetBSD hang). The branch-at-page-end/straddle sections below
        -- specifically exercised THAT reverted feature and are no longer
        -- reachable; this test now only validates the DATA-fault-onto-a-
        -- walked-kernel-stack scenario, which IS what NetBSD needs and remains
        -- fully supported. Jump straight to the done marker.
        m(w) := x"4EF9"; m(w+1) := x"0000"; m(w+2) := x"0180"; w := w+3;  -- JMP $0180 (done block)
        -- Return point from branch loop at fixed $0170: enable mapping flag, then straddle test
        w := 184;
        m(w) := x"23FC"; m(w+1) := x"0000"; m(w+2) := x"0001";
        m(w+3) := x"0000"; m(w+4) := x"2F20"; w := w+5;                   -- MOVE.L #1,$2F20 (allow mapping now)
        m(w) := x"4EF9"; m(w+1) := x"0000"; m(w+2) := x"9FFC"; w := w+3;  -- JMP $9FFC (straddle test)
        -- Done block at fixed $0180
        w := 192;
        m(w) := x"23FC"; m(w+1) := x"C0DE"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"2F00"; w := w+5;                   -- MOVE.L #$C0DE600D,$2F00 (done)
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S *

        ------------------------------------------------------------------
        -- Extension-word page-straddle test: MOVE.L #$11223344,D3 with the
        -- opcode+first extension in VA page 4 ($9FFC, phys $1FFC) and the
        -- SECOND extension word in VA page 5 ($A000) which is UNMAPPED
        -- until the handler maps it. Then store D3 and jump back.
        ------------------------------------------------------------------
        m(16#0FFE#) := x"263C"; m(16#0FFF#) := x"1122";  -- VA $9FFC: MOVE.L #...,D3 (opcode+ext1)
        m(16#1000#) := x"3344";                          -- VA $A000: ext2 (phys $2000)
        m(16#1001#) := x"23C3"; m(16#1002#) := x"0000"; m(16#1003#) := x"2F1C";  -- MOVE.L D3,$2F1C
        m(16#1004#) := x"4EF9"; m(16#1005#) := x"0000"; m(16#1006#) := x"0180";  -- JMP $0180 (done block)

        ------------------------------------------------------------------
        -- NetBSD-style bus error handler at $0400 (SRP-walked page K0)
        ------------------------------------------------------------------
        w := 512;
        m(w) := x"48E7"; m(w+1) := x"C0C0"; w := w+2;                     -- MOVEM.L D0-D1/A0-A1,-(SP)
        m(w) := x"226F"; m(w+1) := x"0020"; w := w+2;                     -- MOVEA.L $20(SP),A1 (fault addr)
        m(w) := x"52B9"; m(w+1) := x"0000"; m(w+2) := x"2F10"; w := w+3;  -- ADDQ.L #1,$2F10 (fault count)
        m(w) := x"23CF"; m(w+1) := x"0000"; m(w+2) := x"2F14"; w := w+3;  -- MOVE.L A7,$2F14 (balance)
        m(w) := x"2009"; w := w+1;                                        -- MOVE.L A1,D0
        m(w) := x"0800"; m(w+1) := x"001C"; w := w+2;                     -- BTST #28,D0 (user $1Dxxxxxx?)
        m(w) := x"670C"; w := w+1;                                        -- BEQ.S srp_case (target $428)
        m(w) := x"41F8"; m(w+1) := x"6FFC"; w := w+2;                     -- LEA ($6FFC).W,A0 (CRP slot $7FF)
        m(w) := x"20BC"; m(w+1) := x"0000"; m(w+2) := x"4001"; w := w+3;  -- MOVE.L #$00004001,(A0)
        m(w) := x"601E"; w := w+1;                                        -- BRA.S flush (target $446)
        -- srp_case: refuse (count as spurious) while flag $2F20 == 0 - models uvm_fault failure
        m(w) := x"4AB9"; m(w+1) := x"0000"; m(w+2) := x"2F20"; w := w+3;  -- TST.L $2F20
        m(w) := x"660C"; w := w+1;                                        -- BNE.S do_map (target $43C)
        m(w) := x"52B9"; m(w+1) := x"0000"; m(w+2) := x"2F24"; w := w+3;  -- ADDQ.L #1,$2F24 (spurious count)
        m(w) := x"4CDF"; m(w+1) := x"0303"; w := w+2;                     -- MOVEM.L (SP)+,regs
        m(w) := x"4E73"; w := w+1;                                        -- RTE (refused, unmodified)
        m(w) := x"41F8"; m(w+1) := x"6014"; w := w+2;                     -- do_map: LEA ($6014).W,A0 (SRP B slot 5)
        m(w) := x"20BC"; m(w+1) := x"0000"; m(w+2) := x"2001"; w := w+3;  -- MOVE.L #$00002001,(A0)
        m(w) := x"F011"; m(w+1) := x"3810"; w := w+2;                     -- flush: PFLUSH #0,#0,(A1)
        m(w) := x"4CDF"; m(w+1) := x"0303"; w := w+2;                     -- MOVEM.L (SP)+,D0-D1/A0-A1
        m(w) := x"4E73"; w := w+1;                                        -- RTE (unmodified frame)

        -- Unexpected trap handler at $04C0
        w := 608;
        m(w) := x"23FC"; m(w+1) := x"DEAD"; m(w+2) := x"DEAD";
        m(w+3) := x"0000"; m(w+4) := x"2F08"; w := w+5;                   -- MOVE.L #$DEADDEAD,$2F08
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP #$2700

        ------------------------------------------------------------------
        -- PMOVE source data (phys $1080..$1097, page K0)
        ------------------------------------------------------------------
        m(16#0840#) := x"8000"; m(16#0841#) := x"0002";  -- SRP_H
        m(16#0842#) := x"0000"; m(16#0843#) := x"4000";  -- SRP_L (kernel root @$4000)
        m(16#0844#) := x"82D0"; m(16#0845#) := x"8B00";  -- TC (E,SRE,8K,TIA=8,TIB=11)
        m(16#0848#) := x"8000"; m(16#0849#) := x"0002";  -- CRP_H
        m(16#084A#) := x"0000"; m(16#084B#) := x"4400";  -- CRP_L (user root @$4400)

        ------------------------------------------------------------------
        -- Results area (phys $2F00.., page K1) zeroed
        ------------------------------------------------------------------
        for i in 16#1780# to 16#1797# loop
            m(i) := x"0000";
        end loop;

        ------------------------------------------------------------------
        -- Page tables: zero phys $4000-$7FFF (both trees + user page)
        ------------------------------------------------------------------
        for i in 16#2000# to 16#3FFF# loop
            m(i) := x"0000";
        end loop;
        -- SRP root (256 x 4B @$4000): entry 0 -> B-table @$6000 (short table)
        m(16#2000#) := x"0000"; m(16#2001#) := x"6002";
        -- SRP B-table @$6000: entry 0 (VA $0000) -> page K0 phys $0000
        m(16#3000#) := x"0000"; m(16#3001#) := x"0001";
        --                entry 1 (VA $2000, incl. supervisor stack) -> page K1 phys $2000
        m(16#3002#) := x"0000"; m(16#3003#) := x"2001";
        --                entry 2 (VA $4000: page tables) -> phys $4000
        m(16#3004#) := x"0000"; m(16#3005#) := x"4001";
        --                entry 3 (VA $6000: page tables + user data page) -> phys $6000
        m(16#3006#) := x"0000"; m(16#3007#) := x"6001";
        --                entry 4 (VA $8000: straddle code page) -> phys $0000
        m(16#3008#) := x"0000"; m(16#3009#) := x"0001";
        --                entry 6 (VA $C000: branch-loop page) -> phys $4000
        m(16#300C#) := x"0000"; m(16#300D#) := x"4001";
        --                entry 7 (VA $E000) NEVER MAPPED (spurious-prefetch victim)
        --                entry 5 (VA $A000) INVALID until handler maps -> phys $2000
        -- CRP root (256 x 4B @$4400): entry $1D -> B-table @$5000 (short table)
        m(16#223A#) := x"0000"; m(16#223B#) := x"5002";
        -- CRP B-table @$5000: entry $7FF (@$6FFC) INVALID until the handler fixes it

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
            clk              => clk,
            nReset           => nReset,
            clkena_in        => clkena_in,
            data_in          => data_in,
            IPL              => ipl_n,
            IPL_autovector   => '1',
            berr             => '0',
            CPU              => "10",
            addr_out         => addr_out,
            data_write       => data_write,
            nWr              => nWr,
            nUDS             => nUDS,
            nLDS             => nLDS,
            busstate         => busstate,
            longword         => open,
            nResetOut        => open,
            FC               => FC,
            clr_berr         => open,
            skipFetch        => open,
            regin_out        => open,
            CACR_out         => open,
            VBR_out          => open,
            cache_inv_req    => open,
            cache_op_scope   => open,
            cache_op_cache   => open,
            cache_op_addr    => open,
            cacr_ie          => open,
            cacr_de          => open,
            cacr_ifreeze     => open,
            cacr_dfreeze     => open,
            cacr_ibe         => open,
            cacr_dbe         => open,
            cacr_wa          => open,
            pmmu_reg_we      => open,
            pmmu_reg_re      => open,
            pmmu_reg_sel     => open,
            pmmu_reg_wdat    => open,
            pmmu_reg_part    => open,
            pmmu_addr_log    => pmmu_addr_log,
            pmmu_addr_phys   => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req  => pmmu_walker_req,
            pmmu_walker_we   => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack  => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode     => debug_SVmode,
            debug_preSVmode  => open,
            debug_FlagsSR_S  => open,
            debug_changeMode => open,
            debug_setopcode  => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_opcode     => open,
            debug_state      => debug_state,
            debug_setstate   => open,
            debug_last_opc_read => open,
            debug_data_read  => open,
            debug_direct_data => open,
            debug_setnextpass => open,
            debug_TG68_PC    => debug_TG68_PC,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout     => open,
            debug_decodeOPC  => open,
            debug_brief      => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw  => debug_clkena_lw,
            debug_regfile_d0 => open,
            debug_regfile_a0 => open,
            debug_fline_context_valid => open,
            debug_trap_1111  => open,
            debug_trapmake   => open,
            debug_pmmu_brief => open,
            debug_use_base   => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA     => open,
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
            debug_regfile_a7 => open,
            debug_regfile_we => open,
            debug_regfile_waddr => open,
            debug_regfile_wdata => open,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => open,
            debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr,
            debug_trap_vector => debug_trap_vector,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy  => debug_pmmu_busy,
            debug_cpu_halted => debug_cpu_halted,
            debug_stop       => debug_stop_sig,
            debug_interrupt  => open,
            debug_setendOPC  => open,
            debug_IPL_nr     => open,
            debug_micro_state => debug_micro_state,
            debug_next_micro_state => open,
            debug_memmask => open,
            debug_sndOPC => open,
            debug_pmmu_reg_we => open,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open,
            debug_make_berr => debug_make_berr,
            debug_pmmu_fault => debug_pmmu_fault,
            debug_trap_format_error => open,
            debug_format_error_rte_word => open,
            debug_format_error_pc => open,
            debug_format_error_addr => open,
            debug_format_error_sr => open,
            debug_pmmu_tc  => open,
            debug_pmmu_tt0 => open,
            debug_pmmu_tt1 => open,
            debug_pmmu_crp_hi => open,
            debug_pmmu_crp_lo => open,
            debug_pmmu_srp_hi => open,
            debug_pmmu_srp_lo => open,
            debug_pmmu_wstate => open,
            debug_pmmu_atc_buserr => open,
            debug_pmmu_atc_valid  => open,
            debug_pmmu_fault_status => open,
            debug_pmmu_saved_addr   => open,
            debug_pmmu_walk_desc_addr => open,
            debug_pmmu_walk_desc_data => open,
            debug_pmmu_ptr1_desc_addr => open,
            debug_pmmu_ptr1_desc_data => open,
            debug_pmmu_ptr2_desc_addr => open,
            debug_pmmu_ptr2_desc_data => open,
            debug_pmmu_ptr3_desc_addr => open,
            debug_pmmu_ptr3_desc_data => open,
            debug_pmmu_saved_fc       => open
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
                    if nUDS = '0' and nLDS = '0' then
                        mem(phys_word) <= data_write;
                    elsif nUDS = '0' then
                        mem(phys_word)(15 downto 8) <= data_write(15 downto 8);
                    elsif nLDS = '0' then
                        mem(phys_word)(7 downto 0) <= data_write(7 downto 0);
                    end if;
                    if unsigned(pmmu_addr_phys(14 downto 1)) >= x"2000" then
                        report "TBMEM: cpu write phys=" & slv_to_hex(pmmu_addr_phys(15 downto 0)) &
                               " data=" & slv_to_hex(data_write) &
                               " uds=" & std_logic'image(nUDS) & " lds=" & std_logic'image(nLDS) severity note;
                    end if;
                elsif not is_x(pmmu_addr_phys) then
                    report "TBMEM: cpu write OUT OF RANGE phys=" & slv_to_hex(pmmu_addr_phys) &
                           " data=" & slv_to_hex(data_write) severity note;
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

    read_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "10" and clkena_in = '1' and not is_x(pmmu_addr_log) then
                if pmmu_addr_log(31 downto 28) = x"D" then
                    report "TBMEM: cpu read log=" & slv_to_hex(pmmu_addr_log) &
                           " phys=" & slv_to_hex(pmmu_addr_phys) &
                           " data=" & slv_to_hex(data_in) severity note;
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

    irq_driver: process(clk)
        variable armed : boolean := true;
        variable cnt   : integer := 0;
    begin
        if rising_edge(clk) then
            if debug_pmmu_fault = '1' and armed then
                cnt := 300;      -- hold level 6 through dispatch + handler entry
                armed := false;  -- one shot per run
            end if;
            if cnt > 0 then
                cnt := cnt - 1;
                ipl_n <= "001";  -- level 6 (active low)
            else
                ipl_n <= "111";
            end if;
        end if;
    end process;

    clkena_in <= '0' when (pmmu_walker_req = '1'
                           or (debug_pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0
                           or mem_wait = '1') else '1';

    main_test: process
        variable fault_count : std_logic_vector(31 downto 0);
        variable done_mark   : std_logic_vector(31 downto 0);
        variable unexp_mark  : std_logic_vector(31 downto 0);
        variable h_a7        : std_logic_vector(31 downto 0);
        variable wr_byte     : std_logic_vector(7 downto 0);
        variable fails       : integer := 0;
    begin
        report "=== STACKING-ONTO-WALKED-PAGE FAULT REPRODUCTION (NetBSD copyout shape) ===" severity note;

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 500000 loop
            wait until rising_edge(clk);
            done_mark := mem(16#1780#) & mem(16#1781#);
            unexp_mark := mem(16#1784#) & mem(16#1785#);
            if done_mark = x"C0DE600D" or unexp_mark = x"DEADDEAD"
               or debug_cpu_halted = '1' or debug_stop_sig = '1' then
                exit;
            end if;
        end loop;

        fault_count := mem(16#1788#) & mem(16#1789#);
        done_mark   := mem(16#1780#) & mem(16#1781#);
        unexp_mark  := mem(16#1784#) & mem(16#1785#);
        h_a7        := mem(16#178A#) & mem(16#178B#);
        wr_byte     := mem(16#2FFA#)(7 downto 0);

        report "DIAG: done=$" & slv_to_hex(done_mark) & " faults=$" & slv_to_hex(fault_count) &
               " unexpected=$" & slv_to_hex(unexp_mark) & " halted=" & std_logic'image(debug_cpu_halted) severity note;
        report "DIAG: handler A7=$" & slv_to_hex(h_a7) & " written byte=$" & slv_to_hex(wr_byte) severity note;

        if debug_cpu_halted = '1' then
            report "FAIL: CPU HALTED (double fault during stacking) - HARDWARE CASCADE REPRODUCED" severity error;
            fails := fails + 1;
        end if;
        if unexp_mark = x"DEADDEAD" then
            report "FAIL: unexpected exception vector taken" severity error;
            fails := fails + 1;
        end if;
        if done_mark /= x"C0DE600D" then
            report "FAIL: program did not complete" severity error;
            fails := fails + 1;
        end if;
        if fault_count /= x"00000001" then
            report "FAIL: fault count=$" & slv_to_hex(fault_count) & " expected exactly 1 (copyout onto walked kernel stack)" severity error;
            fails := fails + 1;
        end if;
        if wr_byte /= x"5A" then
            report "FAIL: MOVES.B write not completed after restart, byte=$" & slv_to_hex(wr_byte) severity error;
            fails := fails + 1;
        end if;
        -- SSP $3F00 - format $B frame $5C - MOVEM 16 = $3E94
        if h_a7 /= x"00003E94" then
            report "FAIL: handler A7=$" & slv_to_hex(h_a7) & " expected $00003E94 (stacking imbalance)" severity error;
            fails := fails + 1;
        end if;

        if fails = 0 then
            report "PASS: fault dispatch with stacking onto SRP-walked kernel stack recovered cleanly" severity note;
        else
            report "FAIL: " & integer'image(fails) & " checks failed" severity error;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
