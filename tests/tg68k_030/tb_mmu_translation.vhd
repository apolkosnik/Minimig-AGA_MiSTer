-- Comprehensive MMU Translation Testbench
-- Tests the complete address translation pipeline through actual CPU instruction execution:
-- - PMOVE to configure CRP, TC (enable MMU)
-- - Page table walker servicing (3-level tables: root -> L1 -> L2)
-- - Identity mapping, address remapping, write protection, cache inhibit, invalid pages
-- - PTEST with MMUSR verification
-- - PFLUSHA with ATC re-fill verification
-- - TT0 transparent translation
-- - Bus error on write-protected page (vector 2)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_translation is
end entity;

architecture behavioral of tb_mmu_translation is

    

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
        -- Normalize to 0-based index so slices like (31 downto 16) work
        variable v : std_logic_vector(value'length - 1 downto 0);
    begin
        v := value;
        for i in 0 to (v'length/4 - 1) loop
            nibble := v(v'length - 1 - i*4 downto v'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

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
    signal debug_micro_state : integer range 0 to 255;
    signal debug_last_opc_read : std_logic_vector(15 downto 0);
    signal debug_regfile_a1 : std_logic_vector(31 downto 0);
    signal debug_setopcode  : std_logic;
    signal debug_clkena_lw  : std_logic;
    signal debug_trap_berr  : std_logic;
    signal debug_make_berr  : std_logic;
    signal debug_pmmu_fault : std_logic;
    signal pmmu_addr_log    : std_logic_vector(31 downto 0);
    signal debug_data_read  : std_logic_vector(31 downto 0);
    signal debug_memmask    : std_logic_vector(5 downto 0);
    signal debug_setnextpass : std_logic;
    signal debug_decodeOPC  : std_logic;
    signal debug_last_data_read : std_logic_vector(31 downto 0);
    signal debug_regfile_we    : std_logic;
    signal debug_regfile_waddr : std_logic_vector(3 downto 0);
    signal debug_regfile_wdata : std_logic_vector(31 downto 0);
    signal debug_regfile_a7    : std_logic_vector(31 downto 0);
    signal debug_trap_mmu_berr : std_logic;
    signal debug_trap_vector   : std_logic_vector(31 downto 0);

    -- PMMU busy (for stalling CPU during ATC miss -> walker startup gap)
    signal pmmu_busy : std_logic;

    -- Memory wait state: simulates minimum 1-cycle memory latency from real hardware.
    -- In cpu_wrapper.v: clkena_in = (~cpu_req | ready) & (~walker | ...)
    -- cpu_req = (busstate != 1), and ready takes at least 1 cycle.
    -- Without this, CPU advances with stale addr_phys during ATC miss detection.
    signal mem_wait : std_logic := '0';

    -- Walker stall control
    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';

    -- Cache inhibit observation
    signal ci_observed : boolean := false;

    -- TTR CI bypass observation (Test 20)
    -- Verifies cache_inhibit is correct in the same cycle as addr_phys for TTR matches
    signal ttr_ci_seen : boolean := false;  -- CI=1 observed during TTR access
    signal ttr_ci_bug  : boolean := false;  -- CI=0 observed during TTR access (stale!)
    signal atc_hit_seen : boolean := false; -- ATC hit observed with correct phys output
    signal atc_hit_pending : boolean := false; -- Registered ATC hit is allowed to stall briefly
    signal atc_hit_bug  : boolean := false; -- ATC hit completed with stale phys

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
        ---------------------------------------------------------------
        -- BUS ERROR HANDLER at $0080 (indices 64-72)
        ---------------------------------------------------------------
        -- $0080: MOVE.L #$BE000000,D7
        m(64) := x"2E3C"; m(65) := x"BE00"; m(66) := x"0000";
        -- $0086: OR.L D6,D7
        m(67) := x"8E86";
        -- $0088: MOVE.L D7,$1F00.L
        m(68) := x"23C7"; m(69) := x"0000"; m(70) := x"1F00";
        -- $008E: JMP $01E0 (Go to Test 13)
        m(71) := x"4EF9"; m(72) := x"0000"; m(73) := x"01E0";

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
        -- PFLUSHA                   ; Clear ATC before enabling MMU
        m(133) := x"F000"; m(134) := x"2400";
        -- PMOVE ($1088).W,TC        ; Enable MMU! Identity maps code+stack.
        -- WinUAE rejects Dn as an MC68030 MMU EA, so load TC from memory.
        m(135) := x"F038"; m(136) := x"4000"; m(137) := x"1088";
        m(138) := x"4E71"; m(139) := x"4E71";

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
        -- PMOVE MMUSR,($1F20).W
        m(164) := x"F038"; m(165) := x"6200"; m(166) := x"1F20";
        m(167) := x"4E71"; m(168) := x"4E71";

        -- Test 7: PTEST W on write-protected page ($3000)
        -- MOVEA.L #$3000,A1
        m(169) := x"227C"; m(170) := x"0000"; m(171) := x"3000";
        -- PTEST W,(A1),#7,FC=5
        m(172) := x"F011"; m(173) := x"9C15";
        -- PMOVE MMUSR,($1F24).W
        m(174) := x"F038"; m(175) := x"6200"; m(176) := x"1F24";
        m(177) := x"4E71"; m(178) := x"4E71";

        -- Test 8: PTEST R on invalid page ($5000)
        -- MOVEA.L #$5000,A1
        m(179) := x"227C"; m(180) := x"0000"; m(181) := x"5000";
        -- PTEST R,(A1),#7,FC=5   (Ext=$9E15, bit 9=1=read)
        m(182) := x"F011"; m(183) := x"9E15";
        -- PMOVE MMUSR,($1F28).W
        m(184) := x"F038"; m(185) := x"6200"; m(186) := x"1F28";
        m(187) := x"4E71"; m(188) := x"4E71";

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
        -- PMOVE ($108C).W,TT0
        -- TT0: base=$FF, mask=$00, E=1, CI=0, RWM=1, FC_Base=101, FC_Mask=000
        m(197) := x"F038"; m(198) := x"0800"; m(199) := x"108C";
        m(200) := x"4E71"; m(201) := x"4E71";
        -- MOVEA.L #$FF000100,A1
        m(202) := x"227C"; m(203) := x"FF00"; m(204) := x"0100";
        -- PTEST R,(A1),#7,FC=5   (should match TT0 -> MMUSR.T set)
        m(205) := x"F011"; m(206) := x"9E15";
        -- PMOVE MMUSR,($1F30).W
        m(207) := x"F038"; m(208) := x"6200"; m(209) := x"1F30";
        m(210) := x"4E71"; m(211) := x"4E71";

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
        -- Test 12: Write to WP page -> internal PMMU bus error (vector 2)
        -- MOVEQ #$0C,D6          (test number marker for handler)
        m(227) := x"7C0C";
        -- MOVE.L #$DEADBEEF,$3000  (WP page -> bus error)
        m(228) := x"23FC"; m(229) := x"DEAD"; m(230) := x"BEEF";
        m(231) := x"0000"; m(232) := x"3000";
        -- Fallthrough: no bus error occurred (test 12 FAILED)
        -- MOVE.L #$FFFFFFFF,$1F00
        m(233) := x"23FC"; m(234) := x"FFFF"; m(235) := x"FFFF";
        m(236) := x"0000"; m(237) := x"1F00";
        -- Fallthrough to Test 13
        m(238) := x"4E71"; m(239) := x"4E71";

        -- Phase 8: Large Page Size (32K) Crash Test (starts at index 240 = $01E0)
        -- Test 13: Switch to 32K pages (TC=$80F09800)
        -- PMOVE ($1090).W,CRP
        m(240) := x"F038"; m(241) := x"4C00"; m(242) := x"1090";
        -- PMOVE ($1098).W,TC
        m(243) := x"F038"; m(244) := x"4000"; m(245) := x"1098";
        m(246) := x"4E71"; m(247) := x"4E71";
        -- NOP (flush pipeline)
        m(248) := x"4E71";
        -- MOVE.L $0,D1 (Read from 0 - should map to 0)
        m(249) := x"2239"; m(250) := x"0000"; m(251) := x"0000";
        -- MOVE.L D1,$1F40 (Save result)
        m(252) := x"23C1"; m(253) := x"0000"; m(254) := x"1F40";
        ---------------------------------------------------------------
        -- Phase 9: All Page Size Tests (Tests 14-19)
        -- Each test: PMOVEFD CRP, PMOVE (abs.W),TC,
        --            NOP, MOVE.L $0,D1, MOVE.L D1,$1Fxx
        -- CRP data placed at $02B6-$02E5 (within code page 2 for PS=8)
        ---------------------------------------------------------------

        -- Test 14: PS=8 (256B pages), TC=$8080CC00, CRP at $02B6
        -- No PFLUSHA: stale ATC entries from previous test cover code page
        -- (identity mapping = stale entries always correct)
        m(255) := x"F038"; m(256) := x"4D00"; m(257) := x"02B6";  -- PMOVEFD ($02B6).W,CRP
        m(258) := x"F038"; m(259) := x"4000"; m(260) := x"109C";  -- PMOVE ($109C).W,TC
        m(261) := x"4E71"; m(262) := x"4E71";
        m(263) := x"4E71";                                          -- NOP
        m(264) := x"2239"; m(265) := x"0000"; m(266) := x"0000";  -- MOVE.L $0.L,D1
        m(267) := x"23C1"; m(268) := x"0000"; m(269) := x"1F44";  -- MOVE.L D1,$1F44.L

        -- Test 15: PS=9 (512B pages), TC=$8090CB00, CRP at $02BE
        m(270) := x"F038"; m(271) := x"4D00"; m(272) := x"02BE";
        m(273) := x"F038"; m(274) := x"4000"; m(275) := x"10A0";
        m(276) := x"4E71"; m(277) := x"4E71";
        m(278) := x"4E71";
        m(279) := x"2239"; m(280) := x"0000"; m(281) := x"0000";
        m(282) := x"23C1"; m(283) := x"0000"; m(284) := x"1F48";

        -- Test 16: PS=10 (1KB pages), TC=$80A0BB00, CRP at $02C6
        m(285) := x"F038"; m(286) := x"4D00"; m(287) := x"02C6";
        m(288) := x"F038"; m(289) := x"4000"; m(290) := x"10A4";
        m(291) := x"4E71"; m(292) := x"4E71";
        m(293) := x"4E71";
        m(294) := x"2239"; m(295) := x"0000"; m(296) := x"0000";
        m(297) := x"23C1"; m(298) := x"0000"; m(299) := x"1F4C";

        -- Test 17: PS=11 (2KB pages), TC=$80B0BA00, CRP at $02CE
        m(300) := x"F038"; m(301) := x"4D00"; m(302) := x"02CE";
        m(303) := x"F038"; m(304) := x"4000"; m(305) := x"10A8";
        m(306) := x"4E71"; m(307) := x"4E71";
        m(308) := x"4E71";
        m(309) := x"2239"; m(310) := x"0000"; m(311) := x"0000";
        m(312) := x"23C1"; m(313) := x"0000"; m(314) := x"1F50";

        -- Test 18: PS=13 (8KB pages), TC=$80D0A900, CRP at $02D6
        m(315) := x"F038"; m(316) := x"4D00"; m(317) := x"02D6";
        m(318) := x"F038"; m(319) := x"4000"; m(320) := x"10AC";
        m(321) := x"4E71"; m(322) := x"4E71";
        m(323) := x"4E71";
        m(324) := x"2239"; m(325) := x"0000"; m(326) := x"0000";
        m(327) := x"23C1"; m(328) := x"0000"; m(329) := x"1F54";

        -- Test 19: PS=14 (16KB pages), TC=$80E09900, CRP at $02DE
        m(330) := x"F038"; m(331) := x"4D00"; m(332) := x"02DE";
        m(333) := x"F038"; m(334) := x"4000"; m(335) := x"10B0";
        m(336) := x"4E71"; m(337) := x"4E71";
        m(338) := x"4E71";
        m(339) := x"2239"; m(340) := x"0000"; m(341) := x"0000";
        m(342) := x"23C1"; m(343) := x"0000"; m(344) := x"1F58";

        -- BRA.W to Test 20 (skip over CRP data)
        -- PC=$02B2, target=$02E6 (index 371), disp=$02E6-$02B4=$0032
        m(345) := x"6000"; m(346) := x"0032";

        ---------------------------------------------------------------
        -- CRP DATA for Tests 14-19 (at $02B6-$02E5)
        -- Each: CRP_H=$00000002 (DT=10), CRP_L=root table address
        ---------------------------------------------------------------
        -- Test 14 CRP at $02B6 (idx 347): root=$4000
        m(347) := x"0000"; m(348) := x"0002"; m(349) := x"0000"; m(350) := x"4000";
        -- Test 15 CRP at $02BE (idx 351): root=$4200
        m(351) := x"0000"; m(352) := x"0002"; m(353) := x"0000"; m(354) := x"4200";
        -- Test 16 CRP at $02C6 (idx 355): root=$4400
        m(355) := x"0000"; m(356) := x"0002"; m(357) := x"0000"; m(358) := x"4400";
        -- Test 17 CRP at $02CE (idx 359): root=$4600
        m(359) := x"0000"; m(360) := x"0002"; m(361) := x"0000"; m(362) := x"4600";
        -- Test 18 CRP at $02D6 (idx 363): root=$4800
        m(363) := x"0000"; m(364) := x"0002"; m(365) := x"0000"; m(366) := x"4800";
        -- Test 19 CRP at $02DE (idx 367): root=$4A00
        m(367) := x"0000"; m(368) := x"0002"; m(369) := x"0000"; m(370) := x"4A00";

        ---------------------------------------------------------------
        -- TEST 20: TTR CI Bypass (at $02E6, index 371)
        -- Verifies that cache_inhibit output is correct in the SAME cycle
        -- as addr_phys when a TTR match occurs with CI=1.
        -- BUG #371 V2: Without combinational CI bypass, cache_inhibit uses
        -- stale cache_inhibit_reg from the previous translation.
        ---------------------------------------------------------------
        -- Set TT1=$FE008507: base=$FE, mask=$00, E=1, CI=1, RWM=1, FC=any
        m(371) := x"F038"; m(372) := x"0C00"; m(373) := x"10B4";  -- PMOVE ($10B4).W,TT1
        m(374) := x"4E71"; m(375) := x"4E71";
        m(376) := x"4E71";                                          -- NOP (pipeline settle)
        -- Read from normal page to ensure cache_inhibit_reg=0
        m(377) := x"2239"; m(378) := x"0000"; m(379) := x"0000";  -- MOVE.L $0,D1
        -- Read from TTR CI=1 region - cache_inhibit must be 1 immediately
        m(380) := x"2239"; m(381) := x"FE00"; m(382) := x"0000";  -- MOVE.L $FE000000,D1
        -- Save result (value doesn't matter, CI timing is checked by observer)
        m(383) := x"23C1"; m(384) := x"0000"; m(385) := x"1F5C";  -- MOVE.L D1,$1F5C
        -- STOP #$2700
        m(386) := x"4E72"; m(387) := x"2700";

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
        -- TEST 13 DATA (32K Pages)
        ---------------------------------------------------------------
        -- Root Table at $7000 (index 14336)
        -- TIA=9 bits. Entry 0 -> L1 at $7800 (DT=2)
        m(14336) := x"0000"; m(14337) := x"7802";

        -- L1 Table at $7800 (index 15360)
        -- TIB=8 bits. Entry 0 -> Page 0 (DT=1)
        m(15360) := x"0000"; m(15361) := x"0001";

        -- CRP Data for Test 13 at $1090 (index 2120)
        m(2120) := x"0000"; m(2121) := x"0002";
        m(2122) := x"0000"; m(2123) := x"7000";

        ---------------------------------------------------------------
        -- PAGE TABLES for Tests 14-19 ($4000-$4B01)
        -- Each test: root table (entry 0 -> L1 ptr, DT=10) + L1 table
        -- (identity-mapping short page descriptors, DT=01)
        ---------------------------------------------------------------

        -- Test 14 (PS=8, 256B pages): Root at $4000, L1 at $4100
        -- Pages needed: 0($0000), 2($0200), 31($1F00)
        m(8192) := x"0000"; m(8193) := x"4102";  -- Root[0] -> L1 at $4100
        m(8320) := x"0000"; m(8321) := x"0001";  -- L1[0]:  page $0000
        m(8324) := x"0000"; m(8325) := x"0201";  -- L1[2]:  page $0200
        m(8382) := x"0000"; m(8383) := x"1F01";  -- L1[31]: page $1F00

        -- Test 15 (PS=9, 512B pages): Root at $4200, L1 at $4300
        -- Pages needed: 0($0000), 1($0200), 15($1E00)
        m(8448) := x"0000"; m(8449) := x"4302";  -- Root[0] -> L1 at $4300
        m(8576) := x"0000"; m(8577) := x"0001";  -- L1[0]:  page $0000
        m(8578) := x"0000"; m(8579) := x"0201";  -- L1[1]:  page $0200
        m(8606) := x"0000"; m(8607) := x"1E01";  -- L1[15]: page $1E00

        -- Test 16 (PS=10, 1KB pages): Root at $4400, L1 at $4500
        -- Pages needed: 0($0000), 7($1C00)
        m(8704) := x"0000"; m(8705) := x"4502";  -- Root[0] -> L1 at $4500
        m(8832) := x"0000"; m(8833) := x"0001";  -- L1[0]: page $0000
        m(8846) := x"0000"; m(8847) := x"1C01";  -- L1[7]: page $1C00

        -- Test 17 (PS=11, 2KB pages): Root at $4600, L1 at $4700
        -- Pages needed: 0($0000), 3($1800)
        m(8960) := x"0000"; m(8961) := x"4702";  -- Root[0] -> L1 at $4700
        m(9088) := x"0000"; m(9089) := x"0001";  -- L1[0]: page $0000
        m(9094) := x"0000"; m(9095) := x"1801";  -- L1[3]: page $1800

        -- Test 18 (PS=13, 8KB pages): Root at $4800, L1 at $4900
        -- Pages needed: 0($0000) - covers $0000-$1FFF (all accessed addrs)
        m(9216) := x"0000"; m(9217) := x"4902";  -- Root[0] -> L1 at $4900
        m(9344) := x"0000"; m(9345) := x"0001";  -- L1[0]: page $0000

        -- Test 19 (PS=14, 16KB pages): Root at $4A00, L1 at $4B00
        -- Pages needed: 0($0000) - covers $0000-$3FFF (all accessed addrs)
        m(9472) := x"0000"; m(9473) := x"4B02";  -- Root[0] -> L1 at $4B00
        m(9600) := x"0000"; m(9601) := x"0001";  -- L1[0]: page $0000

        ---------------------------------------------------------------
        -- CRP DATA at $1080 (index $1080/2 = 2112)
        -- Used by PMOVE ($1080).W,CRP in Phase 1
        ---------------------------------------------------------------
        -- CRP_H = $00000002 (DT=10: valid table descriptor)
        m(2112) := x"0000"; m(2113) := x"0002";
        -- CRP_L = $00006000 (root table at physical $6000)
        m(2114) := x"0000"; m(2115) := x"6000";
        -- TC/TTR data used by legal PMOVE memory EAs.
        m(2116) := x"80C0"; m(2117) := x"7760";
        m(2118) := x"FF00"; m(2119) := x"8150";
        m(2124) := x"80F0"; m(2125) := x"9800";
        m(2126) := x"8080"; m(2127) := x"CC00";
        m(2128) := x"8090"; m(2129) := x"CB00";
        m(2130) := x"80A0"; m(2131) := x"BB00";
        m(2132) := x"80B0"; m(2133) := x"BA00";
        m(2134) := x"80D0"; m(2135) := x"A900";
        m(2136) := x"80E0"; m(2137) := x"9900";
        m(2138) := x"FE00"; m(2139) := x"8507";

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
            debug_SVmode     => open,
            debug_preSVmode  => open,
            debug_FlagsSR_S  => open,
            debug_changeMode => open,
            debug_setopcode  => debug_setopcode,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_state      => debug_state,
            debug_setstate   => open,
            debug_last_opc_read => debug_last_opc_read,
            debug_data_read  => debug_data_read,
            debug_direct_data => open,
            debug_setnextpass => debug_setnextpass,
            debug_TG68_PC    => debug_TG68_PC,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout     => open,
            debug_decodeOPC  => debug_decodeOPC,
            debug_brief      => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw  => debug_clkena_lw,
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
            debug_reg_QA     => open,
            debug_last_data_read => debug_last_data_read,
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
            debug_regfile_a1 => debug_regfile_a1,
            debug_regfile_a2 => open,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
            debug_regfile_a6 => open,
            debug_regfile_a7 => debug_regfile_a7,
            debug_regfile_we => debug_regfile_we,
            debug_regfile_waddr => debug_regfile_waddr,
            debug_regfile_wdata => debug_regfile_wdata,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => open,
            debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr,
            debug_trap_vector => debug_trap_vector,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy  => pmmu_busy,
            debug_micro_state => debug_micro_state,
            debug_next_micro_state => open,
            debug_memmask => debug_memmask,
            debug_sndOPC => open,
            debug_pmmu_reg_we => open,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open,
            debug_make_berr => debug_make_berr,
            debug_pmmu_fault => debug_pmmu_fault
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
            -- CPU writes: only execute when clkena_in='1' (PMMU translation stable).
            -- In real hardware, memory controller waits for ready before writing.
            -- Without this gate, writes fire during stalls with stale pmmu_addr_phys.
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if not is_x(pmmu_addr_phys) and
                   unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    mem(phys_word) <= data_write;
                end if;
            end if;

            -- Walker response: hold ack high while req is high (matches cpu_wrapper protocol)
            if pmmu_walker_req = '1' then
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
    -- MEMORY WAIT STATE: Simulate minimum 1-cycle memory latency
    -- In real hardware (cpu_wrapper.v line 390):
    --   clkena_in = (~cpu_req | chipready|ramready|...) & (~walker|...)
    -- cpu_req = (busstate != 1), ready signals take >= 1 cycle.
    -- After each CPU-active cycle, insert 1 wait cycle. This gives
    -- the PMMU time to detect ATC misses and assert busy before the
    -- CPU can advance with a stale addr_phys_reg.
    ---------------------------------------------------------------
    mem_wait_gen: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                mem_wait <= '0';
            elsif clkena_in = '1' then
                mem_wait <= '1';   -- 1 wait cycle after each CPU advance
            else
                mem_wait <= '0';
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

    -- CPU stall: walker active, walker cooldown, memory wait state, or PMMU busy
    -- mem_wait provides 1-cycle latency; pmmu_busy holds during ATC miss->walk gap
    -- BUG #399 FIX: Release clkena_in when PMMU has a pending fault (debug_pmmu_fault='1').
    -- The real cpu_wrapper.v only gates on pmmu_walker_req_p, not pmmu_busy.
    -- Without this, fault_reg='1' keeps pmmu_busy='1', keeping clkena_in='0' forever,
    -- preventing the kernel from ever seeing the fault and triggering make_berr.
    clkena_in <= '0' when (pmmu_walker_req = '1'
                           or (pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0 or mem_wait = '1') else '1';

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
    -- TTR CI BYPASS OBSERVATION (Test 20)
    -- When addr_out shows a TTR-matched address ($FExxxxxx) during a bus access,
    -- pmmu_cache_inhibit must already be 1 (not stale 0 from previous translation).
    -- Without the combinational CI bypass, cache_inhibit_reg lags by 1 cycle.
    ---------------------------------------------------------------
    ttr_ci_observe: process(clk)
    begin
        if rising_edge(clk) then
            if busstate /= "00" and addr_out(31 downto 24) = x"FE" then
                if pmmu_cache_inhibit = '1' then
                    ttr_ci_seen <= true;
                else
                    ttr_ci_bug <= true;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- ATC HIT OBSERVATION (Test 21)
    -- Observe a later hot-page read from $1100 after the initial fill path has
    -- completed. Registered ATC hits may hold busy for a cycle; they must not
    -- complete with a stale physical address.
    ---------------------------------------------------------------
    atc_hit_observe: process
    begin
        wait until rising_edge(clk);
        wait for 1 ns;
        if atc_hit_pending and not atc_hit_seen and not atc_hit_bug then
            if pmmu_busy = '0' then
                atc_hit_pending <= false;
                if pmmu_addr_phys = x"00001100" then
                    atc_hit_seen <= true;
                else
                    report "ATC_HIT_OBSERVED_BAD: phys=$" & slv_to_hex(pmmu_addr_phys) &
                           " busy=" & std_logic'image(pmmu_busy) &
                           " fc=" & slv_to_hex("0" & FC) &
                           " log=$" & slv_to_hex(pmmu_addr_log)
                    severity note;
                    atc_hit_bug <= true;
                end if;
            end if;
        elsif not atc_hit_seen and not atc_hit_bug and
           busstate /= "00" and nWr = '1' and FC = "101" and pmmu_addr_log = x"00001100" and
           unsigned(debug_TG68_PC) >= x"00000138" then
            if pmmu_busy = '0' and pmmu_addr_phys = x"00001100" then
                atc_hit_seen <= true;
            elsif pmmu_busy = '1' then
                atc_hit_pending <= true;
            else
                report "ATC_HIT_OBSERVED_BAD: phys=$" & slv_to_hex(pmmu_addr_phys) &
                       " busy=" & std_logic'image(pmmu_busy) &
                       " fc=" & slv_to_hex("0" & FC) &
                       " log=$" & slv_to_hex(pmmu_addr_log)
                severity note;
                atc_hit_bug <= true;
            end if;
        end if;
    end process;

    -- DEBUG: Monitor PMMU addr_phys during CRP_L read at $1094-$1096
    ---------------------------------------------------------------
    phys_monitor: process(clk)
        variable prev_phys : std_logic_vector(31 downto 0) := (others => '1');
        variable prev_busy : std_logic := '0';
        variable prev_walker : std_logic := '0';
    begin
        if rising_edge(clk) then
            if unsigned(pmmu_addr_log) >= x"00001090" and unsigned(pmmu_addr_log) <= x"000010A0" then
                if pmmu_addr_phys /= prev_phys or pmmu_busy /= prev_busy or pmmu_walker_req /= prev_walker then
                    report "PHYS_MON: log=0x" & slv_to_hex(pmmu_addr_log) &
                           " phys=0x" & slv_to_hex(pmmu_addr_phys) &
                           " busy=" & std_logic'image(pmmu_busy) &
                           " walk=" & std_logic'image(pmmu_walker_req) &
                           " clk_in=" & std_logic'image(clkena_in) &
                           " din=0x" & slv_to_hex(data_in) &
                           " mwait=" & std_logic'image(mem_wait) &
                           " fault=" & std_logic'image(debug_pmmu_fault)
                    severity note;
                end if;
                prev_phys := pmmu_addr_phys;
                prev_busy := pmmu_busy;
                prev_walker := pmmu_walker_req;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    ---------------------------------------------------------------
    -- PC TRACE (for debugging - reports key PC milestones)
    ---------------------------------------------------------------
    pc_trace: process(clk)
        variable prev_pc : std_logic_vector(31 downto 0) := (others => '1');
        variable cycle_count : integer := 0;
        variable trace_active : boolean := false;
        variable trace_countdown : integer := 0;
    begin
        if rising_edge(clk) then
            cycle_count := cycle_count + 1;

            if not is_x(debug_TG68_PC) then
                -- Activate detailed cycle-by-cycle trace when PC enters PTEST or WP fault range
                -- Trace every cycle (not just PC changes) around the second PTEST and Test 12
                if (unsigned(debug_TG68_PC) >= 16#018A# and
                    unsigned(debug_TG68_PC) <= 16#01A0#) or
                   (unsigned(debug_TG68_PC) >= 16#01C0# and
                    unsigned(debug_TG68_PC) <= 16#01E0#) then
                    trace_active := true;
                    trace_countdown := 100;  -- Continue for 100 cycles after leaving range
                elsif trace_active then
                    trace_countdown := trace_countdown - 1;
                    if trace_countdown <= 0 then
                        trace_active := false;
                    end if;
                end if;

                -- Cycle-by-cycle trace: every rising edge when active
                if trace_active then
                    report "CYC" & integer'image(cycle_count) &
                           " ce=" & std_logic'image(clkena_in) &
                           " lw=" & std_logic'image(debug_clkena_lw) &
                           " st=" & slv_to_hex("000000" & debug_state) &
                           " us=" & integer'image(debug_micro_state) &
                           " PC=$" & slv_to_hex(debug_TG68_PC) &
                           " op=$" & slv_to_hex(debug_opcode) &
                           " lor=$" & slv_to_hex(debug_last_opc_read) &
                           " din=$" & slv_to_hex(data_in) &
                           " sop=" & std_logic'image(debug_setopcode) &
                           " dec=" & std_logic'image(debug_decodeOPC) &
                           " snp=" & std_logic'image(debug_setnextpass) &
                           " mm=" & slv_to_hex("00" & debug_memmask) &
                           " dr=$" & slv_to_hex(debug_data_read) &
                           " ldr=$" & slv_to_hex(debug_last_data_read) &
                           " A1=$" & slv_to_hex(debug_regfile_a1) &
                           " rwe=" & std_logic'image(debug_regfile_we) &
                           " rwa=" & slv_to_hex(debug_regfile_waddr) &
                           " rwd=$" & slv_to_hex(debug_regfile_wdata) &
                           " mb=" & std_logic'image(debug_make_berr) &
                           " tb=" & std_logic'image(debug_trap_berr) &
                           " tmb=" & std_logic'image(debug_trap_mmu_berr) &
                           " pf=" & std_logic'image(debug_pmmu_fault) &
                           " A7=$" & slv_to_hex(debug_regfile_a7) &
                           " tv=$" & slv_to_hex(debug_trap_vector) &
                           " pa=$" & slv_to_hex(pmmu_addr_phys) &
                           " nW=" & std_logic'image(nWr);
                end if;

                -- Update prev_pc for milestone tracking (only on clkena_in transitions)
                if debug_TG68_PC /= prev_pc and clkena_in = '1' then
                    prev_pc := debug_TG68_PC;
                end if;

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
                        report "PC=$00A0: UNEXPECTED trap handler entered, op=$" &
                               slv_to_hex(debug_opcode) severity warning;
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
        for i in 0 to 800 loop
            wait for 100 ns;
            if not is_x(debug_opcode) and debug_opcode = x"4E72" then
                report "CPU reached STOP instruction at " &
                       time'image(now) & " - verifying results";
                exit;
            end if;
            if i = 800 then
                report "WARNING: CPU did not reach STOP after 80us"
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
            report "  Phys $1100: expected $AABB0011, got 0x" & slv_to_hex(val32(31 downto 16)) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(1, "Identity write + remap overwrite at phys $1100", pass);

        -- Test 2: D1 at $1F10 = $12345678 (loaded before remap overwrite)
        -- mem index: $1F10/2 = $0F88 = 3976
        val32 := mem(3976) & mem(3977);
        pass := (val32 = x"12345678");
        if not pass then
            report "  D1@$1F10: expected $12345678, got 0x" & slv_to_hex(val32(31 downto 16)) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(2, "Identity read D1=$12345678", pass);

        -- Test 4: D2 at $1F14 = $AABB0011 (read from remapped page)
        val32 := mem(3978) & mem(3979);
        pass := (val32 = x"AABB0011");
        if not pass then
            report "  D2@$1F14: expected $AABB0011, got 0x" & slv_to_hex(val32(31 downto 16)) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(4, "Remap read D2=$AABB0011 (log $2100 -> phys $1100)", pass);

        -- Test 5: D3 at $1F18 = $AABB0011 (cross-verify: $1100 == $2100)
        val32 := mem(3980) & mem(3981);
        pass := (val32 = x"AABB0011");
        if not pass then
            report "  D3@$1F18: expected $AABB0011, got 0x" & slv_to_hex(val32(31 downto 16)) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(5, "Cross-verify D3=$AABB0011 (both map to phys $1100)", pass);

        -- Test 6: MMUSR at $1F20 - valid page PTEST, no fault bits
        -- mem index: $1F20/2 = $0F90 = 3984
        val32 := mem(3984) & mem(3985);
        pass := (val32(15) = '0' and val32(12) = '0' and val32(10) = '0');
        if not pass then
            report "  MMUSR@$1F20: expected no B/W/I bits, got 0x" & slv_to_hex(val32);
        end if;
        check_test(6, "PTEST W valid page: MMUSR has no fault bits", pass);

        -- Test 7: MMUSR at $1F24 - WP page PTEST W, W bit set
        -- mem index: $1F24/2 = $0F92 = 3986
        val32 := mem(3986) & mem(3987);
        pass := (val32(11) = '1');
        if not pass then
            report "  MMUSR@$1F24: expected W bit (11) set, got 0x" & slv_to_hex(val32);
        end if;
        check_test(7, "PTEST W on WP page: MMUSR.W (bit 11) set", pass);

        -- Test 8: MMUSR at $1F28 - invalid page PTEST, I bit set
        -- mem index: $1F28/2 = $0F94 = 3988
        val32 := mem(3988) & mem(3989);
        pass := (val32(10) = '1');
        if not pass then
            report "  MMUSR@$1F28: expected I bit (10) set, got 0x" & slv_to_hex(val32);
        end if;
        check_test(8, "PTEST R on invalid page: MMUSR.I (bit 10) set", pass);

        -- Test 9: D5 at $1F2C = $AABB0011 (post-PFLUSH re-walk)
        -- mem index: $1F2C/2 = $0F96 = 3990
        val32 := mem(3990) & mem(3991);
        pass := (val32 = x"AABB0011");
        if not pass then
            report "  D5@$1F2C: expected $AABB0011, got 0x" & slv_to_hex(val32(31 downto 16)) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(9, "Post-PFLUSH re-walk reads $AABB0011", pass);

        -- Test 10: MMUSR at $1F30 - TT0 transparent match, T bit set
        -- mem index: $1F30/2 = $0F98 = 3992
        val32 := mem(3992) & mem(3993);
        pass := (val32(6) = '1');
        if not pass then
            report "  MMUSR@$1F30: expected T bit (6) set, got 0x" & slv_to_hex(val32);
            report "  DEBUG A1=" & slv_to_hex(debug_regfile_a1);
        end if;
        check_test(10, "PTEST with TT0 match: MMUSR.T (bit 6) set", pass);

        -- Test 11: Cache inhibit signal observed
        check_test(11, "Cache inhibit observed during CI page access", ci_observed);

        -- Test 12: Bus error marker at $1F00 = $BE00000C
        -- mem index: $1F00/2 = $0F80 = 3968
        val32 := mem(3968) & mem(3969);
        pass := (val32 = x"BE00000C");
        if not pass then
            report "  Marker@$1F00: expected $BE00000C, got 0x" & slv_to_hex(val32(31 downto 16)) & "_" &
                   integer'image(to_integer(unsigned(val32(15 downto 0))));
        end if;
        check_test(12, "WP write triggers bus error (marker $BE00000C)", pass);

        -- Test 13: 32K Page Access
        -- mem index: $1F40/2 = 4000
        val32 := mem(4000) & mem(4001);
        -- Expect to read $00002000 (Initial SSP at address 0)
        pass := (val32 = x"00002000");
        if not pass then
            report "  Test 13: expected $00002000, got 0x" & slv_to_hex(val32);
        end if;
        check_test(13, "Large Page (32K) Access (TC=$80F09800)", pass);

        -- Test 14: PS=8 (256B) Page Access
        -- mem index: $1F44/2 = 4002
        val32 := mem(4002) & mem(4003);
        pass := (val32 = x"00002000");
        if not pass then
            report "  Test 14: expected $00002000, got 0x" & slv_to_hex(val32);
        end if;
        check_test(14, "Page Size 256B (PS=8, TC=$8080CC00)", pass);

        -- Test 15: PS=9 (512B) Page Access
        val32 := mem(4004) & mem(4005);
        pass := (val32 = x"00002000");
        if not pass then
            report "  Test 15: expected $00002000, got 0x" & slv_to_hex(val32);
        end if;
        check_test(15, "Page Size 512B (PS=9, TC=$8090CB00)", pass);

        -- Test 16: PS=10 (1KB) Page Access
        val32 := mem(4006) & mem(4007);
        pass := (val32 = x"00002000");
        if not pass then
            report "  Test 16: expected $00002000, got 0x" & slv_to_hex(val32);
        end if;
        check_test(16, "Page Size 1KB (PS=10, TC=$80A0BB00)", pass);

        -- Test 17: PS=11 (2KB) Page Access
        val32 := mem(4008) & mem(4009);
        pass := (val32 = x"00002000");
        if not pass then
            report "  Test 17: expected $00002000, got 0x" & slv_to_hex(val32);
        end if;
        check_test(17, "Page Size 2KB (PS=11, TC=$80B0BA00)", pass);

        -- Test 18: PS=13 (8KB) Page Access
        val32 := mem(4010) & mem(4011);
        pass := (val32 = x"00002000");
        if not pass then
            report "  Test 18: expected $00002000, got 0x" & slv_to_hex(val32);
        end if;
        check_test(18, "Page Size 8KB (PS=13, TC=$80D0A900)", pass);

        -- Test 19: PS=14 (16KB) Page Access
        val32 := mem(4012) & mem(4013);
        pass := (val32 = x"00002000");
        if not pass then
            report "  Test 19: expected $00002000, got 0x" & slv_to_hex(val32);
        end if;
        check_test(19, "Page Size 16KB (PS=14, TC=$80E09900)", pass);

        -- Test 20: TTR CI bypass timing
        -- ttr_ci_seen=true means CI=1 was observed during TTR access (correct)
        -- ttr_ci_bug=true means CI=0 was observed during TTR access (stale!)
        pass := ttr_ci_seen and not ttr_ci_bug;
        if not pass then
            if ttr_ci_bug then
                report "  Test 20: cache_inhibit was 0 (stale) during TTR CI=1 access!";
            end if;
            if not ttr_ci_seen then
                report "  Test 20: cache_inhibit=1 never observed during TTR access";
            end if;
        end if;
        check_test(20, "TTR CI bypass: cache_inhibit correct on TTR match", pass);

        -- Test 21: ATC hit timing
        pass := atc_hit_seen and not atc_hit_bug;
        if not pass then
            if atc_hit_bug then
                report "  Test 21: ATC-hit read of $1100 completed with stale phys output";
            end if;
            if not atc_hit_seen then
                report "  Test 21: never observed completed ATC-hit read of $1100";
            end if;
        end if;
        check_test(21, "ATC hit: addr_phys correct on cached read", pass);

        -- Test 22: TABLE U-bit writeback - root descriptor at $6000
        -- Initial value: $00006202 (DT=10, U=0). After first walk: U=1 -> $0000620A.
        -- mem indices: $6000/2 = 12288 (high word), 12289 (low word)
        val32 := mem(12288) & mem(12289);
        pass := (val32 = x"0000620A");
        if not pass then
            report "  Root TABLE@$6000: expected $0000620A (U=1), got $" & slv_to_hex(val32);
        end if;
        check_test(22, "TABLE U-bit writeback: root descriptor ($6000) U=1", pass);

        -- Test 23: TABLE U-bit writeback - L1 descriptor at $6200
        -- Initial value: $00006402 (DT=10, U=0). After first walk: U=1 -> $0000640A.
        -- mem indices: $6200/2 = 12544 (high word), 12545 (low word)
        val32 := mem(12544) & mem(12545);
        pass := (val32 = x"0000640A");
        if not pass then
            report "  L1 TABLE@$6200: expected $0000640A (U=1), got $" & slv_to_hex(val32);
        end if;
        check_test(23, "TABLE U-bit writeback: L1 descriptor ($6200) U=1", pass);

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
