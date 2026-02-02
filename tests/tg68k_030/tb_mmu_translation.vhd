-- Comprehensive MMU Translation Testbench
-- Tests the complete address translation pipeline through actual CPU instruction execution:
-- - PMOVE to configure CRP, TC (enable MMU)
-- - Page table walker servicing (3-level tables: root -> L1 -> L2)
-- - Identity mapping, address remapping, write protection, cache inhibit, invalid pages
-- - PTEST with MMUSR verification
-- - PFLUSHA with ATC re-fill verification
-- - TT0 transparent translation
-- - Bus error on write-protected page (vector 61)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_translation is
end entity;

architecture behavioral of tb_mmu_translation is

    -- Clock
    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal test_done : boolean := false;

    -- CPU interface
    signal clkena_in   : std_logic := '1';
    signal data_in     : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write  : std_logic_vector(15 downto 0);
    signal addr_out    : std_logic_vector(31 downto 0);
    signal busstate    : std_logic_vector(1 downto 0);
    signal nWr         : std_logic;
    signal nUDS        : std_logic;
    signal nLDS        : std_logic;
    signal FC          : std_logic_vector(2 downto 0);

    -- Walker interface
    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_walker_berr : std_logic := '0';

    -- PMMU outputs
    signal pmmu_addr_phys    : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;

    -- Debug
    signal debug_TG68_PC    : std_logic_vector(31 downto 0);
    signal debug_opcode     : std_logic_vector(15 downto 0);
    signal debug_state      : std_logic_vector(1 downto 0);
    signal debug_regfile_d0 : std_logic_vector(31 downto 0);
    signal debug_regfile_a0 : std_logic_vector(31 downto 0);

    -- Walker stall control
    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';

    -- Cache inhibit observation
    signal ci_observed : boolean := false;

    -- Memory model: 16384 x 16-bit words = 32KB ($0000-$7FFF)
    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    -- TC=$80C07760: E=1, SRE=0, FCL=0, PS=12(4KB), IS=0, TIA=7, TIB=7, TIC=6, TID=0
    -- CRP: $00000002 $00006000 (DT=10, root table at $6000)
    -- TT0=$FF008150: base=$FF, mask=$00, E=1, CI=0, RWM=1, FC_Base=101, FC_Mask=000
    --
    -- Page table layout:
    --   Root at $6000: entry 0 -> L1 at $6200 (DT=10)
    --   L1 at $6200:   entry 0 -> L2 at $6400 (DT=10)
    --   L2 at $6400:   6 page descriptors (DT=01 short format)
    --     [0] $0000 identity (code)    [1] $1000 identity (data)
    --     [2] $1000 remap ($2xxx->$1xxx)  [3] $3000 write-protected
    --     [4] $4000 cache-inhibited    [5] invalid (DT=00)

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");  -- Default: NOP
    begin
        ---------------------------------------------------------------
        -- VECTOR TABLE ($0000-$00FF, indices 0-127)
        ---------------------------------------------------------------
        -- Vector 0: Initial SSP = $00002000
        m(0) := x"0000"; m(1) := x"2000";
        -- Vector 1: Reset PC = $00000100
        m(2) := x"0000"; m(3) := x"0100";
        -- Vector 2: Bus Error -> $0080
        m(4) := x"0000"; m(5) := x"0080";
        -- Vectors 3-63: unexpected trap handler at $00A0
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00A0";
        end loop;
        -- Override vector 61 (MMU bus error) -> $0080 (bus error handler)
        m(122) := x"0000"; m(123) := x"0080";

        ---------------------------------------------------------------
        -- BUS ERROR HANDLER at $0080 (indices 64-72)
        ---------------------------------------------------------------
        -- $0080: MOVE.L #$BE000000,D7
        m(64) := x"2E3C"; m(65) := x"BE00"; m(66) := x"0000";
        -- $0086: OR.L D6,D7
        m(67) := x"8E86";
        -- $0088: MOVE.L D7,$1F00.L
        m(68) := x"23C7"; m(69) := x"0000"; m(70) := x"1F00";
        -- $008E: STOP #$2700
        m(71) := x"4E72"; m(72) := x"2700";

        ---------------------------------------------------------------
        -- UNEXPECTED TRAP HANDLER at $00A0 (indices 80-87)
        ---------------------------------------------------------------
        -- $00A0: MOVE.L #$FF000000,D7
        m(80) := x"2E3C"; m(81) := x"FF00"; m(82) := x"0000";
        -- $00A6: MOVE.L D7,$1F00.L
        m(83) := x"23C7"; m(84) := x"0000"; m(85) := x"1F00";
        -- $00AC: STOP #$2700
        m(86) := x"4E72"; m(87) := x"2700";

        ---------------------------------------------------------------
        -- MAIN PROGRAM at $0100 (index 128)
        ---------------------------------------------------------------

        -- Phase 1: MMU Setup (MMU disabled, identity mapping for all)
        -- Using absolute short EA mode for CRP: .W sign-extends to $00001080
        -- (abs.L has ld_nn bug that only reads 1 address word; (An) has EA recovery bug)
        -- CRP data pre-loaded in RAM at $1080 (see DATA section below)
        -- PMOVE ($1080).W,CRP     ; F038=EA abs.W (mode=111,reg=000), 4C00=CRP write
        m(128) := x"F038"; m(129) := x"4C00"; m(130) := x"1080";
        -- NOP padding to maintain instruction indices for subsequent code
        m(131) := x"4E71"; m(132) := x"4E71";
        -- MOVE.L #$80C07760,D0     ; TC: E=1, PS=12, IS=0, TIA=7, TIB=7, TIC=6, TID=0
        m(133) := x"203C"; m(134) := x"80C0"; m(135) := x"7760";
        -- PFLUSHA                   ; Clear ATC before enabling MMU
        m(136) := x"F000"; m(137) := x"2400";
        -- PMOVE D0,TC              ; Enable MMU! Identity maps code+stack.
        -- Opcode: F000 (EA=D0), Extension: 4000 (TC, write Dn->MMU, 32-bit)
        m(138) := x"F000"; m(139) := x"4000";

        -- Phase 2: Basic Translation Verification (starts at index 140 = byte $0118)
        -- Test 1: MOVE.L #$12345678,$1100   (identity: log $1100 -> phys $1100)
        m(140) := x"23FC"; m(141) := x"1234"; m(142) := x"5678";
        m(143) := x"0000"; m(144) := x"1100";
        -- Test 2: MOVE.L $1100,D1           (read back from identity page)
        m(145) := x"2239"; m(146) := x"0000"; m(147) := x"1100";
        -- Test 3: MOVE.L #$AABB0011,$2100   (remap: log $2100 -> phys $1100)
        m(148) := x"23FC"; m(149) := x"AABB"; m(150) := x"0011";
        m(151) := x"0000"; m(152) := x"2100";
        -- Test 4: MOVE.L $2100,D2           (read from remapped page)
        m(153) := x"2439"; m(154) := x"0000"; m(155) := x"2100";
        -- Test 5: MOVE.L $1100,D3           (cross-verify: both map to phys $1100)
        m(156) := x"2639"; m(157) := x"0000"; m(158) := x"1100";

        -- Phase 3: PTEST with MMUSR verification (starts at index 159 = byte $013E)
        -- Test 6: PTEST W on valid writable page ($1000)
        -- MOVEA.L #$1000,A1
        m(159) := x"227C"; m(160) := x"0000"; m(161) := x"1000";
        -- PTEST W,(A1),#7,FC=5
        -- Ext: 100_111_0_0_000_10_101 = $9C15
        -- (15:13=PTEST, 12:10=level7, 9=0=write, 4:3=10=immFC, 2:0=101=FC5)
        m(162) := x"F011"; m(163) := x"9C15";
        -- PMOVE MMUSR,D4   (Opcode=F004, Ext=$6200)
        m(164) := x"F004"; m(165) := x"6200";
        -- MOVE.L D4,$1F20.L
        m(166) := x"23C4"; m(167) := x"0000"; m(168) := x"1F20";

        -- Test 7: PTEST W on write-protected page ($3000)
        -- MOVEA.L #$3000,A1
        m(169) := x"227C"; m(170) := x"0000"; m(171) := x"3000";
        -- PTEST W,(A1),#7,FC=5
        m(172) := x"F011"; m(173) := x"9C15";
        -- PMOVE MMUSR,D4
        m(174) := x"F004"; m(175) := x"6200";
        -- MOVE.L D4,$1F24.L
        m(176) := x"23C4"; m(177) := x"0000"; m(178) := x"1F24";

        -- Test 8: PTEST R on invalid page ($5000)
        -- MOVEA.L #$5000,A1
        m(179) := x"227C"; m(180) := x"0000"; m(181) := x"5000";
        -- PTEST R,(A1),#7,FC=5   (Ext=$9E15, bit 9=1=read)
        m(182) := x"F011"; m(183) := x"9E15";
        -- PMOVE MMUSR,D4
        m(184) := x"F004"; m(185) := x"6200";
        -- MOVE.L D4,$1F28.L
        m(186) := x"23C4"; m(187) := x"0000"; m(188) := x"1F28";

        -- Phase 4: PFLUSH + ATC Re-fill (starts at index 189 = byte $017A)
        -- Test 9: PFLUSHA then re-access (forces fresh table walk)
        -- PFLUSHA
        m(189) := x"F000"; m(190) := x"2400";
        -- MOVE.L $1100,D5         (triggers fresh walk for page 1)
        m(191) := x"2A39"; m(192) := x"0000"; m(193) := x"1100";
        -- MOVE.L D5,$1F2C.L
        m(194) := x"23C5"; m(195) := x"0000"; m(196) := x"1F2C";

        -- Phase 5: TT0 Transparent Translation (starts at index 197 = byte $018A)
        -- Test 10: Set TT0 and verify via PTEST
        -- MOVE.L #$FF008150,D0
        -- TT0: base=$FF, mask=$00, E=1, CI=0, RWM=1, FC_Base=101, FC_Mask=000
        m(197) := x"203C"; m(198) := x"FF00"; m(199) := x"8150";
        -- PMOVE D0,TT0           (Opcode=F000, Ext=$0800 = TT0 write)
        m(200) := x"F000"; m(201) := x"0800";
        -- MOVEA.L #$FF000100,A1
        m(202) := x"227C"; m(203) := x"FF00"; m(204) := x"0100";
        -- PTEST R,(A1),#7,FC=5   (should match TT0 -> MMUSR.T set)
        m(205) := x"F011"; m(206) := x"9E15";
        -- PMOVE MMUSR,D4
        m(207) := x"F004"; m(208) := x"6200";
        -- MOVE.L D4,$1F30.L
        m(209) := x"23C4"; m(210) := x"0000"; m(211) := x"1F30";

        -- Phase 6: Cache Inhibit page access (starts at index 212 = byte $01A8)
        -- Test 11: MOVE.L $4000,D5  (CI page - observe pmmu_cache_inhibit)
        m(212) := x"2A39"; m(213) := x"0000"; m(214) := x"4000";
        -- MOVE.L D5,$1F34.L
        m(215) := x"23C5"; m(216) := x"0000"; m(217) := x"1F34";

        -- Save main results before fault test
        -- MOVE.L D1,$1F10.L      (Test 2 result)
        m(218) := x"23C1"; m(219) := x"0000"; m(220) := x"1F10";
        -- MOVE.L D2,$1F14.L      (Test 4 result)
        m(221) := x"23C2"; m(222) := x"0000"; m(223) := x"1F14";
        -- MOVE.L D3,$1F18.L      (Test 5 result)
        m(224) := x"23C3"; m(225) := x"0000"; m(226) := x"1F18";

        -- Phase 7: Write-Protected Fault Test (starts at index 227 = byte $01C6)
        -- Test 12: Write to WP page -> MMU bus error (vector 61)
        -- MOVEQ #$0C,D6          (test number marker for handler)
        m(227) := x"7C0C";
        -- MOVE.L #$DEADBEEF,$3000  (WP page -> bus error)
        m(228) := x"23FC"; m(229) := x"DEAD"; m(230) := x"BEEF";
        m(231) := x"0000"; m(232) := x"3000";
        -- Fallthrough: no bus error occurred (test 12 FAILED)
        -- MOVE.L #$FFFFFFFF,$1F00
        m(233) := x"23FC"; m(234) := x"FFFF"; m(235) := x"FFFF";
        m(236) := x"0000"; m(237) := x"1F00";
        -- STOP #$2700
        m(238) := x"4E72"; m(239) := x"2700";

        ---------------------------------------------------------------
        -- PAGE TABLES ($6000-$6FFF)
        ---------------------------------------------------------------
        -- Root table at $6000 (index $6000/2 = 12288)
        -- Entry 0: table ptr -> L1 at $6200  (addr[31:2]=$6200>>2=$1880, DT=10)
        -- Descriptor = $6200 | 2 = $00006202
        m(12288) := x"0000"; m(12289) := x"6202";

        -- L1 table at $6200 (index $6200/2 = 12544)
        -- Entry 0: table ptr -> L2 at $6400  (DT=10)
        m(12544) := x"0000"; m(12545) := x"6402";

        -- L2 table at $6400 (index $6400/2 = 12800)
        -- Entry 0: page $0000 identity (code), DT=01
        m(12800) := x"0000"; m(12801) := x"0001";
        -- Entry 1: page $1000 identity (data), DT=01
        m(12802) := x"0000"; m(12803) := x"1001";
        -- Entry 2: page $1000 REMAP (log $2xxx -> phys $1xxx), DT=01
        m(12804) := x"0000"; m(12805) := x"1001";
        -- Entry 3: page $3000 write-protected (WP=1 bit2), DT=01
        m(12806) := x"0000"; m(12807) := x"3005";
        -- Entry 4: page $4000 cache-inhibited (CI=1 bit6), DT=01
        m(12808) := x"0000"; m(12809) := x"4041";
        -- Entry 5: INVALID (DT=00)
        m(12810) := x"0000"; m(12811) := x"0000";

        ---------------------------------------------------------------
        -- CRP DATA at $1080 (index $1080/2 = 2112)
        -- Used by PMOVE (A0)+,CRP in Phase 1
        ---------------------------------------------------------------
        -- CRP_H = $00000002 (DT=10: valid table descriptor)
        m(2112) := x"0000"; m(2113) := x"0002";
        -- CRP_L = $00006000 (root table at physical $6000)
        m(2114) := x"0000"; m(2115) := x"6000";

        return m;
    end function;

    signal mem : mem_type := init_mem;

begin

    ---------------------------------------------------------------
    -- CLOCK GENERATION
    ---------------------------------------------------------------
    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    ---------------------------------------------------------------
    -- UUT: TG68KdotC_Kernel (68030 mode)
    ---------------------------------------------------------------
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
            IPL              => "111",
            IPL_autovector   => '1',
            berr             => '0',
            CPU              => "11",
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
            pmmu_addr_log    => open,
            pmmu_addr_phys   => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req  => pmmu_walker_req,
            pmmu_walker_we   => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack  => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode     => open,
            debug_preSVmode  => open,
            debug_FlagsSR_S  => open,
            debug_changeMode => open,
            debug_setopcode  => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
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
            debug_clkena_lw  => open,
            debug_regfile_d0 => debug_regfile_d0,
            debug_regfile_a0 => debug_regfile_a0,
            debug_opcode     => debug_opcode,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_fline_context_valid => open,
            debug_trap_1111  => open,
            debug_trapmake   => open,
            debug_pmmu_brief => open,
            debug_use_base   => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA     => open
        );

    ---------------------------------------------------------------
    -- MEMORY READ: Drive data_in from physical address
    -- Before MMU enable: pmmu_addr_phys = addr_out (identity)
    -- After MMU enable: pmmu_addr_phys = translated physical address
    ---------------------------------------------------------------
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

    ---------------------------------------------------------------
    -- UNIFIED MEMORY WRITE + WALKER RESPONSE
    -- Single process to avoid multiple drivers on mem signal.
    -- Handles CPU writes, walker reads/writes, and walker handshake.
    ---------------------------------------------------------------
    mem_and_walker: process(clk)
        variable phys_word   : integer;
        variable walker_word : integer;
    begin
        if rising_edge(clk) then
            -- CPU writes (busstate "11" = data write, nWr = '0')
            if busstate = "11" and nWr = '0' then
                if not is_x(pmmu_addr_phys) and
                   unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    mem(phys_word) <= data_write;
                end if;
            end if;

            -- Walker response: service page table walker requests
            if pmmu_walker_req = '1' and pmmu_walker_ack = '0' then
                if not is_x(pmmu_walker_addr) and
                   unsigned(pmmu_walker_addr) < x"00008000" then
                    walker_word := to_integer(unsigned(pmmu_walker_addr(14 downto 1)));
                    if pmmu_walker_we = '1' then
                        -- U/M bit descriptor update (write 32-bit)
                        mem(walker_word)     <= pmmu_walker_wdat(31 downto 16);
                        mem(walker_word + 1) <= pmmu_walker_wdat(15 downto 0);
                    else
                        -- Read: assemble 32-bit from two 16-bit words
                        pmmu_walker_data <= mem(walker_word) & mem(walker_word + 1);
                    end if;
                else
                    -- Out of range: return invalid descriptor
                    pmmu_walker_data <= x"00000000";
                end if;
                pmmu_walker_ack <= '1';
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- CPU STALL CONTROL: Stall CPU during walker activity
    -- Replicates cpu_wrapper.v behavior: clkena_in gated when
    -- walker is active or during 2-cycle cooldown after walker done
    ---------------------------------------------------------------
    stall_control: process(clk)
    begin
        if rising_edge(clk) then
            walker_req_prev <= pmmu_walker_req;
            -- Start cooldown when walker request deasserts
            if walker_req_prev = '1' and pmmu_walker_req = '0' then
                stall_cooldown <= 2;
            elsif stall_cooldown > 0 then
                stall_cooldown <= stall_cooldown - 1;
            end if;
        end if;
    end process;

    clkena_in <= '0' when (pmmu_walker_req = '1' or stall_cooldown > 0) else '1';

    ---------------------------------------------------------------
    -- CACHE INHIBIT OBSERVATION
    ---------------------------------------------------------------
    ci_observe: process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_cache_inhibit = '1' and busstate /= "00" then
                ci_observed <= true;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- PC TRACE (for debugging - reports key PC milestones)
    ---------------------------------------------------------------
    pc_trace: process(clk)
    begin
        if rising_edge(clk) then
            if not is_x(debug_TG68_PC) then
                case to_integer(unsigned(debug_TG68_PC)) is
                    when 16#0100# =>
                        report "PC=$0100: Program start (MMU setup)";
                    when 16#0118# =>
                        report "PC=$0118: Test 1 - Identity write $1100";
                    when 16#013E# =>
                        report "PC=$013E: Test 6 - PTEST on valid page";
                    when 16#017A# =>
                        report "PC=$017A: Test 9 - PFLUSHA + re-access";
                    when 16#018A# =>
                        report "PC=$018A: Test 10 - TT0 setup";
                    when 16#01A8# =>
                        report "PC=$01A8: Test 11 - CI page access";
                    when 16#01C6# =>
                        report "PC=$01C6: Test 12 - WP fault test";
                    when 16#0080# =>
                        report "PC=$0080: Bus error handler entered";
                    when 16#00A0# =>
                        report "PC=$00A0: UNEXPECTED trap handler entered"
                            severity warning;
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- TEST MONITOR: Reset, wait for completion, verify results
    ---------------------------------------------------------------
    test_monitor: process
        variable tests_passed : integer := 0;
        variable tests_failed : integer := 0;
        variable val32 : std_logic_vector(31 downto 0);
        variable pass : boolean;

        procedure check_test(
            test_id   : integer;
            test_name : string;
            passed    : boolean
        ) is
        begin
            if passed then
                tests_passed := tests_passed + 1;
                report "TEST " & integer'image(test_id) & ": " & test_name & " -> PASSED";
            else
                tests_failed := tests_failed + 1;
                report "TEST " & integer'image(test_id) & ": " & test_name & " -> FAILED"
                    severity error;
            end if;
        end procedure;

    begin
        report "=========================================================";
        report "COMPREHENSIVE MMU TRANSLATION TEST SUITE";
        report "=========================================================";
        report "TC=$80C07760 (PS=12, IS=0, TIA=7, TIB=7, TIC=6, TID=0)";
        report "CRP=$00000002_$00006000 (root at $6000, 3-level walk)";
        report "Pages: identity, identity, remap, WP, CI, invalid";

        -- Reset
        nReset <= '0';
        wait for CLK_PERIOD * 5;
        nReset <= '1';

        -- Wait for STOP instruction or timeout
        -- Active polling: check every 100ns if CPU hit STOP
        for i in 0 to 2000 loop
            wait for 100 ns;
            if not is_x(debug_opcode) and debug_opcode = x"4E72" then
                report "CPU reached STOP instruction at " &
                       time'image(now) & " - verifying results";
                exit;
            end if;
            if i = 2000 then
                report "WARNING: CPU did not reach STOP after 200us"
                    severity warning;
            end if;
        end loop;

        wait for 100 ns;  -- Let signals settle

        report "=========================================================";
        report "VERIFICATION RESULTS";
        report "=========================================================";

        -- Test 1+3: Physical $1100 should have $AABB0011 (overwritten by remap)
        -- mem index: $1100/2 = 2176
        val32 := mem(2176) & mem(2177);
        pass := (val32 = x"AABB0011");
        if not pass then
            report "  Phys $1100: expected $AABB0011, got 0x" &
                   integer'image(to_integer(unsigned(val32(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(1, "Identity write + remap overwrite at phys $1100", pass);

        -- Test 2: D1 at $1F10 = $12345678 (loaded before remap overwrite)
        -- mem index: $1F10/2 = 3848
        val32 := mem(3848) & mem(3849);
        pass := (val32 = x"12345678");
        if not pass then
            report "  D1@$1F10: expected $12345678, got 0x" &
                   integer'image(to_integer(unsigned(val32(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(2, "Identity read D1=$12345678", pass);

        -- Test 4: D2 at $1F14 = $AABB0011 (read from remapped page)
        val32 := mem(3850) & mem(3851);
        pass := (val32 = x"AABB0011");
        if not pass then
            report "  D2@$1F14: expected $AABB0011, got 0x" &
                   integer'image(to_integer(unsigned(val32(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(4, "Remap read D2=$AABB0011 (log $2100 -> phys $1100)", pass);

        -- Test 5: D3 at $1F18 = $AABB0011 (cross-verify: $1100 == $2100)
        val32 := mem(3852) & mem(3853);
        pass := (val32 = x"AABB0011");
        if not pass then
            report "  D3@$1F18: expected $AABB0011, got 0x" &
                   integer'image(to_integer(unsigned(val32(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(5, "Cross-verify D3=$AABB0011 (both map to phys $1100)", pass);

        -- Test 6: MMUSR at $1F20 - valid page PTEST, no fault bits
        val32 := mem(3856) & mem(3857);
        pass := (val32(15) = '0' and val32(12) = '0' and val32(10) = '0');
        if not pass then
            report "  MMUSR@$1F20: expected no B/W/I bits, got 0x" &
                   integer'image(to_integer(unsigned(val32)));
        end if;
        check_test(6, "PTEST W valid page: MMUSR has no fault bits", pass);

        -- Test 7: MMUSR at $1F24 - WP page PTEST W, W bit set
        val32 := mem(3858) & mem(3859);
        pass := (val32(12) = '1');
        if not pass then
            report "  MMUSR@$1F24: expected W bit (12) set, got 0x" &
                   integer'image(to_integer(unsigned(val32)));
        end if;
        check_test(7, "PTEST W on WP page: MMUSR.W (bit 12) set", pass);

        -- Test 8: MMUSR at $1F28 - invalid page PTEST, I bit set
        val32 := mem(3860) & mem(3861);
        pass := (val32(10) = '1');
        if not pass then
            report "  MMUSR@$1F28: expected I bit (10) set, got 0x" &
                   integer'image(to_integer(unsigned(val32)));
        end if;
        check_test(8, "PTEST R on invalid page: MMUSR.I (bit 10) set", pass);

        -- Test 9: D5 at $1F2C = $AABB0011 (post-PFLUSH re-walk)
        val32 := mem(3862) & mem(3863);
        pass := (val32 = x"AABB0011");
        if not pass then
            report "  D5@$1F2C: expected $AABB0011, got 0x" &
                   integer'image(to_integer(unsigned(val32(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(9, "Post-PFLUSH re-walk reads $AABB0011", pass);

        -- Test 10: MMUSR at $1F30 - TT0 transparent match, T bit set
        val32 := mem(3864) & mem(3865);
        pass := (val32(8) = '1');
        if not pass then
            report "  MMUSR@$1F30: expected T bit (8) set, got 0x" &
                   integer'image(to_integer(unsigned(val32)));
        end if;
        check_test(10, "PTEST with TT0 match: MMUSR.T (bit 8) set", pass);

        -- Test 11: Cache inhibit signal observed
        check_test(11, "Cache inhibit observed during CI page access", ci_observed);

        -- Test 12: Bus error marker at $1F00 = $BE00000C
        val32 := mem(3840) & mem(3841);
        pass := (val32 = x"BE00000C");
        if not pass then
            report "  Marker@$1F00: expected $BE00000C, got 0x" &
                   integer'image(to_integer(unsigned(val32(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(12, "WP write triggers bus error (marker $BE00000C)", pass);

        -- Summary
        report "=========================================================";
        report "TOTAL: " & integer'image(tests_passed + tests_failed) &
               " tests, " & integer'image(tests_passed) & " passed, " &
               integer'image(tests_failed) & " failed";
        if tests_failed = 0 then
            report "*** ALL MMU TRANSLATION TESTS PASSED ***";
        else
            report "*** " & integer'image(tests_failed) & " MMU TESTS FAILED ***"
                severity error;
        end if;
        report "=========================================================";

        test_done <= true;
        wait;
    end process;

end behavioral;
