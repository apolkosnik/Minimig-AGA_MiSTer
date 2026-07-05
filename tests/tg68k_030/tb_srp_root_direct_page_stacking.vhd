-- tb_srp_root_direct_page_stacking.vhd
--
-- Reproduces the EXACT PMMU register state captured live via JTAG at the
-- moment of the real hardware's first MMU fault inside MuForce (the
-- AmigaOS memory-protection debugger that triggers a double bus fault /
-- cpu_halted assertion on real hardware):
--
--   TC     = $82A08680  (E=1, SRE=1, FCL=0, PS=10(1024B pages),
--                         IS=0, TIA=8, TIB=6, TIC=8, TID=0; sums to 32)
--   CRP_H  = $80000002, CRP_L = $40090000  (DT=10, never walked in this
--                                            test: all accesses here are
--                                            supervisor, and SRE=1 routes
--                                            every supervisor access -
--                                            FC=5 data AND FC=6 program -
--                                            through SRP, never CRP)
--   SRP_H  = $80000002, SRP_L = $40080000  (DT=10, root table address)
--   Root table entry 64 (address SRP_L + 64*4 = $40080100) = $40000009
--     This is the EXACT descriptor value captured on real hardware via a
--     PMWR walker-writeback log entry. DT(1:0)="01" (valid, resident,
--     4-byte "early termination" page descriptor at the ROOT level),
--     WP(bit2)=0 (not write protected), base(31:8)=$400000.
--     Root index 64 = logical(31:24) = $40, covering the ENTIRE 16MB
--     span $40000000-$40FFFFFF with ONE descriptor (TIA=8 means each
--     root entry spans 2**24 bytes). This is exactly the region the real
--     supervisor stack pointer ($40079B1C at the moment of the captured
--     fault) lives in.
--
-- THE QUESTION THIS TEST ANSWERS:
--   Given this exact TC/SRP/root-descriptor configuration, does an
--   MC68030 exception dispatch (frame push onto the SRP-translated
--   supervisor stack, vector-table read, handler first-opcode fetch)
--   complete cleanly, or does something in that dispatch sequence
--   itself produce a genuine double bus fault (debug_cpu_halted='1')?
--
-- We already hand-verified (byte for byte, against the captured
-- descriptor chain) that the stack's OWN page is validly mapped
-- (root entry 64, DT=01, valid, non-write-protected). If this
-- simulation ALSO shows a clean dispatch, that conclusively rules out
-- "unmapped/faulting stack translation" as the double-fault cause and
-- implicates something else (vector-table read or handler PC
-- computation) instead. If this simulation instead reproduces a real
-- double fault (debug_cpu_halted asserts), that contradicts the
-- hand analysis and this exact configuration IS the bug.
--
-- ADDRESS-SPACE DESIGN NOTE (read this before editing addresses below):
-- The backing memory model here is only 32KB (16384 words), and (exactly
-- like tb_berr_frame.vhd) every memory access - CPU bus AND PMMU walker -
-- is indexed using ONLY pmmu_addr_phys/pmmu_walker_addr(14 downto 1), i.e.
-- physical addresses alias into this 32KB array using their low 15 bits
-- only, no matter how large the address is. This is intentional and
-- matches the task's instructions; it lets this test exercise translation
-- of real, large ($40xxxxxx-class) logical/physical addresses while still
-- fitting in a small simulation memory - AS LONG AS the chosen logical
-- addresses' low 15 bits don't collide with each other after masking.
--
-- We traced the actual PMMU walker RTL (TG68K_PMMU_030.vhd) to confirm
-- the physical address arithmetic for a root-level "early termination"
-- (DT=01) descriptor: calc_effective_page_shift() for level=0,
-- FCL=0, is_root_pointer=false returns PS+TIB+TIC = 10+6+8 = 24, so
-- physical = (descriptor(31:8)&x"00") + (addr aligned-to-10 minus
-- addr aligned-to-24). Whenever the descriptor's base upper byte
-- equals the logical address's own top byte (i.e. "identity" style
-- descriptors, base = root_index<<24), this reduces to physical ==
-- logical EXACTLY, for the full 16MB span. All three root descriptors
-- used below (index 0, 64, 65) are built this way, so masking to the
-- low 15 bits of the CHOSEN LOGICAL address is sufficient to know
-- exactly where each access lands in the backing array - no separate
-- physical-address bookkeeping is needed.
--
-- Because SRP_L = $40080000 (kept EXACTLY as captured on real hardware)
-- itself aliases (low 15 bits) to array byte offset $0000, the root
-- table's OWN bytes land at:
--   entry 0  (addr $40080000+0*4)   -> array byte $0000-$0003
--   entry 1  (addr $40080000+1*4)   -> array byte $0004-$0007
--   entry 64 (addr $40080000+64*4)  -> array byte $0100-$0103  (FORCED)
--   entry 65 (addr $40080000+65*4)  -> array byte $0104-$0107
-- This forces the memory map below: entries 0/1 double as the boot
-- SSP/reset-PC vector words (read once, before the MMU is even enabled,
-- so reusing those bytes as descriptor storage afterward is harmless),
-- and entry 64/65 land right after the vector table (which only uses
-- vectors 0-63, i.e. bytes $0000-$00FF) - so code/vectors/tables never
-- collide. Full byte map:
--   $0000-$00FF  vector table (vectors 0-63) / doubles as root entries 0-1
--   $0100-$0103  root entry 64 = $40000009 (EXACT real hardware value)
--   $0104-$0107  root entry 65 = $41000005 (our added WP=1 test region;
--                real hardware capture did not include this index, but
--                SOME write-protected page is needed to trigger a fault
--                in a controlled way - entries 0/64 are both WP=0,
--                matching the real captured attributes, and deliberately
--                left writable so vector reads/handler code/stack pushes
--                never fault)
--   $0200-$021B  vector 2 (bus/MMU error) handler code
--   $0280-$028B  unexpected-trap catch-all handler code
--   $0300-$0340  setup code: PMOVE CRP/SRP/TC, set final SSP, trigger fault
--   $0500-$0513  CRP/SRP/TC PMOVE source data
--   $0600-$0613  result/marker area
--   $1000-$1FFF  supervisor stack (SSP = logical $40001800, root entry 64)
--   $3000-$30FF  write-protect fault target (logical $41003000, entry 65)
--
-- Harness pattern reused directly from tb_berr_frame.vhd: direct
-- entity work.TG68KdotC_Kernel instantiation, mem_type 32KB backing
-- array via init_mem, combined memory-write + walker-service process,
-- clkena_in stall generation gated on pmmu_busy, and a test_monitor
-- process waiting for a STOP opcode (or cpu_halted) with a cycle-count
-- timeout.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_srp_root_direct_page_stacking is
end entity;

architecture behavioral of tb_srp_root_direct_page_stacking is

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

    signal pmmu_addr_phys    : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;
    signal pmmu_addr_log    : std_logic_vector(31 downto 0);
    signal pmmu_busy : std_logic;

    signal debug_TG68_PC    : std_logic_vector(31 downto 0);
    signal debug_opcode     : std_logic_vector(15 downto 0);
    signal debug_regfile_a7 : std_logic_vector(31 downto 0);
    signal debug_trap_berr  : std_logic;
    signal debug_make_berr  : std_logic;
    signal debug_pmmu_fault : std_logic;
    signal debug_state       : std_logic_vector(1 downto 0);
    signal debug_clkena_lw   : std_logic;
    signal debug_memmask     : std_logic_vector(5 downto 0);
    signal debug_memmaskmux  : std_logic_vector(5 downto 0);
    signal debug_micro_state : integer range 0 to 255;
    signal debug_cpu_halted  : std_logic;
    signal fault_trace_active : boolean := false;

    signal mem_wait : std_logic := '0';
    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';

    -- Latched state at the moment cpu_halted is FIRST observed (or, if it
    -- never asserts, these simply retain their reset-time value and are
    -- unused by the final report).
    signal halted_seen        : boolean := false;
    signal halted_pc           : std_logic_vector(31 downto 0) := (others => '0');
    signal halted_micro_state  : integer range 0 to 255 := 0;
    signal halted_opcode       : std_logic_vector(15 downto 0) := (others => '0');

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");  -- default: NOP
    begin
        ---------------------------------------------------------------
        -- VECTOR TABLE ($0000-$00FF) -- doubles as root table entries 0/1
        ---------------------------------------------------------------
        -- Vector 0 (initial SSP): reused as root entry 0 descriptor.
        -- $00000001: DT=01 (valid page descriptor, early termination),
        -- WP=0, base=$000000 -> identity-maps logical $00000000-$00FFFFFF.
        -- As a boot-time SSP value this is odd ($1) but harmless: the
        -- MC68030 permits misaligned data addresses (no address-error trap
        -- for odd word/long accesses past the 68000/68010), A7 is never
        -- dereferenced before our own setup code overwrites it below, and
        -- nothing ever re-reads physical address 0 as "the reset vector"
        -- again after the one-time boot fetch.
        m(0) := x"0000"; m(1) := x"0001";
        -- Vector 1 (reset PC): reused as root entry 1 (never walked - no
        -- logical address in this test uses root index 1 - so its value
        -- as a "descriptor" is irrelevant; it just needs to be a valid
        -- code address for boot).
        m(2) := x"0000"; m(3) := x"0300";  -- reset PC = setup code at $0300
        -- Vector 2 (bus/MMU error) -> handler at $0200
        m(4) := x"0000"; m(5) := x"0200";
        -- Vectors 3-63: unexpected trap -> handler at $0280
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"0280";
        end loop;

        ---------------------------------------------------------------
        -- ROOT TABLE ENTRIES 64 and 65 ($0100-$0107)
        -- Forced location: SRP_L=$40080000 aliases (low 15 bits) to
        -- array byte $0000, so entry N sits at byte N*4.
        ---------------------------------------------------------------
        -- Entry 64 (logical $40xxxxxx): EXACT real-hardware captured
        -- descriptor value. DT=01, WP=0, base=$400000.
        m(128) := x"4000"; m(129) := x"0009";
        -- Entry 65 (logical $41xxxxxx): added for this test so we have a
        -- controlled write-protected region to trigger a real fault from
        -- (the real hardware capture only gave us ONE descriptor, entry
        -- 64, which is WP=0 -- deliberately so, since the stack itself
        -- must be writable). DT=01, WP=1 (bit2=1), base=$410000.
        m(130) := x"4100"; m(131) := x"0005";

        ---------------------------------------------------------------
        -- VECTOR 2 (BUS/MMU ERROR) HANDLER at $0200
        -- Reads the fixed, format-independent frame fields (format/vector
        -- at SP+$06, faulted PC at SP+$02 - both are at the SAME offset
        -- in EVERY MC68030 exception frame, unlike SSW/fault-address
        -- whose offsets differ between Format $A and Format $B), saves
        -- them for inspection, writes a distinct success marker, then
        -- STOPs (deliberately does NOT RTE - returning would just
        -- re-execute and re-fault the same write-protected access).
        ---------------------------------------------------------------
        -- $0200: MOVE.W ($0006,SP),D0   ; format/vector word
        m(256) := x"302F"; m(257) := x"0006";
        -- $0204: MOVE.W D0,($0608).W
        m(258) := x"31C0"; m(259) := x"0608";
        -- $0208: MOVE.L ($0002,SP),D1   ; faulted PC
        m(260) := x"222F"; m(261) := x"0002";
        -- $020C: MOVE.L D1,($060C).W
        m(262) := x"21C1"; m(263) := x"060C";
        -- $0210: MOVE.L #$CAFEBABE,($0600).W  ; success marker
        m(264) := x"21FC"; m(265) := x"CAFE"; m(266) := x"BABE"; m(267) := x"0600";
        -- $0218: STOP #$2700
        m(268) := x"4E72"; m(269) := x"2700";

        ---------------------------------------------------------------
        -- UNEXPECTED TRAP HANDLER at $0280 (catches any exception OTHER
        -- than the deliberate vector-2 WP fault - proves dispatch went to
        -- the WRONG vector rather than genuinely halting)
        ---------------------------------------------------------------
        -- $0280: MOVE.L #$FF000000,D7
        m(320) := x"2E3C"; m(321) := x"FF00"; m(322) := x"0000";
        -- $0286: MOVE.L D7,($0604).W
        m(323) := x"21C7"; m(324) := x"0604";
        -- $028A: STOP #$2700
        m(325) := x"4E72"; m(326) := x"2700";

        ---------------------------------------------------------------
        -- SETUP CODE at $0300 (runs with TC.E=0, MMU disabled, identity
        -- addressing - standard boot state)
        ---------------------------------------------------------------
        -- PMOVE ($0504).W,CRP   ; load CRP = $80000002_$40090000 (real
        -- captured value; never actually walked in this test since every
        -- access here is supervisor and SRE=1 routes supervisor accesses
        -- through SRP - loaded anyway for full fidelity to the captured
        -- hardware PMMU state)
        m(384) := x"F038"; m(385) := x"4C00"; m(386) := x"0504";
        m(387) := x"4E71"; m(388) := x"4E71";  -- NOP padding
        -- PMOVE ($050C).W,SRP   ; load SRP = $80000002_$40080000 (real
        -- captured value). SRP selector = reg_sel "10010" -> extension
        -- word bits 14:10="10010" -> $4800 (derived the same way CRP's
        -- $4C00 / TC's $4000 selectors are built - see
        -- TG68K_PMMU_030.vhd reg_sel decode comments).
        m(389) := x"F038"; m(390) := x"4800"; m(391) := x"050C";
        m(392) := x"4E71"; m(393) := x"4E71";  -- NOP padding
        -- PFLUSHA  ; clear ATC before enabling MMU
        m(394) := x"F000"; m(395) := x"2400";
        -- PMOVE ($0500).W,TC    ; load TC=$82A08680 -> enables MMU with
        -- E=1, SRE=1. From this instruction onward EVERY supervisor
        -- access (including this code's own subsequent instruction
        -- fetches) is translated through SRP.
        m(396) := x"F038"; m(397) := x"4000"; m(398) := x"0500";
        -- NOP padding to preserve prefetch/pipeline settle across the
        -- MMU-enable boundary (matching tb_berr_frame.vhd's identical
        -- 3-NOP pattern after PMOVE TC).
        m(399) := x"4E71"; m(400) := x"4E71"; m(401) := x"4E71";
        -- MOVEA.L #$40001800,A7  ; final supervisor stack pointer.
        -- Logical $40001800 is in the root-entry-64-covered region
        -- (top byte $40); since entry 64's descriptor base ($40000000)
        -- matches the logical address's own top byte, translation is a
        -- pure identity pass-through (physical == logical), so this
        -- lands at array byte $1800 (masked low 15 bits) - a region
        -- reserved purely for the stack, with 2KB of headroom below for
        -- the exception frame push that is about to happen.
        m(402) := x"2E7C"; m(403) := x"4000"; m(404) := x"1800";
        m(405) := x"4E71";  -- NOP settle after A7 change
        -- MOVE.L #$DEADBEEF,$41003000.L  ; deliberate write to the
        -- write-protected region (root entry 65, WP=1). This is the
        -- SAME instruction shape as tb_berr_frame.vhd's proven Test 1
        -- (MOVE.L #imm,(abs.L) to a WP page), just targeting a
        -- large/SRP-translated address instead of a small/CRP-translated
        -- one. Expected: MMU detects the write-protect violation and
        -- dispatches vector 2 (bus/MMU error) - the frame push for THAT
        -- dispatch is exactly the SRP-translated supervisor-stack access
        -- this whole test exists to validate.
        m(406) := x"23FC"; m(407) := x"DEAD"; m(408) := x"BEEF";
        m(409) := x"4100"; m(410) := x"3000";
        -- Fallthrough safety net: should NEVER execute if the write
        -- above correctly faults. If somehow reached, it means the WP
        -- write did NOT fault - a DIFFERENT bug from what this test is
        -- designed to catch, but worth flagging distinctly rather than
        -- silently reporting a false PASS.
        m(411) := x"21FC"; m(412) := x"0BAD"; m(413) := x"C0DE"; m(414) := x"0610";
        m(415) := x"4E72"; m(416) := x"2700";  -- STOP

        ---------------------------------------------------------------
        -- CRP/SRP/TC PMOVE SOURCE DATA at $0500-$0513
        ---------------------------------------------------------------
        m(640) := x"82A0"; m(641) := x"8680";  -- TC = $82A08680
        m(642) := x"8000"; m(643) := x"0002";  -- CRP_H = $80000002
        m(644) := x"4009"; m(645) := x"0000";  -- CRP_L = $40090000
        m(646) := x"8000"; m(647) := x"0002";  -- SRP_H = $80000002
        m(648) := x"4008"; m(649) := x"0000";  -- SRP_L = $40080000

        ---------------------------------------------------------------
        -- RESULT/MARKER AREA at $0600-$0613 (explicitly zeroed so the
        -- test can distinguish "never written" from any of the markers)
        ---------------------------------------------------------------
        m(768) := x"0000"; m(769) := x"0000";  -- $0600: handler success marker
        m(770) := x"0000"; m(771) := x"0000";  -- $0604: unexpected-trap marker
        m(772) := x"0000";                     -- $0608: saved format/vector word
        m(773) := x"0000";                     -- spare
        m(774) := x"0000"; m(775) := x"0000";  -- $060C: saved faulted PC
        m(776) := x"0000"; m(777) := x"0000";  -- $0610: fallthrough-safety marker

        return m;
    end function;

    signal mem : mem_type := init_mem;

begin
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';

    uut: entity work.TG68KdotC_Kernel
        port map (
            clk          => clk,
            nReset       => nReset,
            clkena_in    => clkena_in,
            data_in      => data_in,
            IPL          => "111",
            IPL_autovector => '1',
            CPU          => "10",  -- 68030 mode
            addr_out     => addr_out,
            data_write   => data_write,
            nWr          => nWr,
            nUDS         => nUDS,
            nLDS         => nLDS,
            busstate     => busstate,
            FC           => FC,
            longword     => open,
            clr_berr     => open,
            berr         => '0',
            pmmu_addr_phys  => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req  => pmmu_walker_req,
            pmmu_walker_we   => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack  => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            pmmu_addr_log    => pmmu_addr_log,
            debug_pmmu_busy  => pmmu_busy,
            debug_TG68_PC    => debug_TG68_PC,
            debug_opcode     => debug_opcode,
            debug_trap_berr  => debug_trap_berr,
            debug_make_berr  => debug_make_berr,
            debug_pmmu_fault => debug_pmmu_fault,
            debug_regfile_a7 => debug_regfile_a7,
            debug_state      => debug_state,
            debug_clkena_lw  => debug_clkena_lw,
            debug_memmask    => debug_memmask,
            debug_memmaskmux => debug_memmaskmux,
            debug_micro_state => debug_micro_state,
            debug_cpu_halted  => debug_cpu_halted
        );

    -- Memory read
    process(pmmu_addr_phys, mem)
        variable phys_word : integer;
    begin
        phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
        data_in <= mem(phys_word);
    end process;

    -- Combined memory write + walker service process.
    -- IMPORTANT: All writes to mem must be in a single process to avoid
    -- VHDL multiple-driver resolution issues (two processes driving the same
    -- signal resolves to 'X' for any bit where the drivers disagree).
    process(clk)
        variable phys_word : integer;
        variable walk_word : integer;
    begin
        if rising_edge(clk) then
            -- CPU memory write (gated by clkena_in for valid PMMU physical address)
            if busstate = "11" and nWr = '0' and clkena_in = '1' and (nUDS = '0' or nLDS = '0') then
                phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                -- synthesis translate_off
                report "MEM_WR: phys=$" & slv_to_hex(pmmu_addr_phys) &
                       " log=$" & slv_to_hex(pmmu_addr_log) &
                       " data=$" & slv_to_hex(data_write) &
                       " UDS=" & std_logic'image(nUDS) &
                       " LDS=" & std_logic'image(nLDS) &
                       " clkena=" & std_logic'image(clkena_in);
                -- synthesis translate_on
                if nUDS = '0' then
                    mem(phys_word)(15 downto 8) <= data_write(15 downto 8);
                end if;
                if nLDS = '0' then
                    mem(phys_word)(7 downto 0) <= data_write(7 downto 0);
                end if;
            end if;

            -- Walker memory service
            walker_req_prev <= pmmu_walker_req;
            if stall_cooldown > 0 then
                stall_cooldown <= stall_cooldown - 1;
            end if;

            if pmmu_walker_req = '1' and pmmu_walker_ack = '0' then
                walk_word := to_integer(unsigned(pmmu_walker_addr(14 downto 1)));
                if pmmu_walker_we = '1' then
                    -- Descriptor writeback (U/M bits)
                    mem(walk_word)(15 downto 8) <= pmmu_walker_wdat(31 downto 24);
                    mem(walk_word)(7 downto 0)  <= pmmu_walker_wdat(23 downto 16);
                    mem(walk_word+1)(15 downto 8) <= pmmu_walker_wdat(15 downto 8);
                    mem(walk_word+1)(7 downto 0)  <= pmmu_walker_wdat(7 downto 0);
                    pmmu_walker_ack <= '1';
                else
                    -- Descriptor read
                    pmmu_walker_data <= mem(walk_word) & mem(walk_word + 1);
                    pmmu_walker_ack <= '1';
                end if;
                stall_cooldown <= 2;
            elsif pmmu_walker_req = '0' then
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    -- Memory wait state: insert 1 wait cycle after each CPU advance
    -- Gives PMMU time to detect ATC misses before CPU advances with stale addr_phys_reg
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

    -- Release clkena_in when PMMU has a pending fault (debug_pmmu_fault='1').
    -- Without this, fault_reg='1' keeps pmmu_busy='1', keeping clkena_in='0' forever,
    -- preventing the kernel from ever seeing the fault and triggering make_berr.
    clkena_in <= '0' when (pmmu_walker_req = '1'
                           or (pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0 or mem_wait = '1') else '1';

    ---------------------------------------------------------------
    -- Latch cpu_halted the FIRST time it is observed, along with PC/
    -- micro_state/opcode at that exact moment, so the final report can
    -- state precisely what the CPU was doing when it (allegedly) died.
    ---------------------------------------------------------------
    halted_latch: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                halted_seen <= false;
            elsif not is_x(debug_cpu_halted) and debug_cpu_halted = '1' and not halted_seen then
                halted_seen <= true;
                halted_pc <= debug_TG68_PC;
                halted_micro_state <= debug_micro_state;
                halted_opcode <= debug_opcode;
                report "*** DEBUG_CPU_HALTED ASSERTED *** PC=$" & slv_to_hex(debug_TG68_PC) &
                       " micro_state=" & integer'image(debug_micro_state) &
                       " opcode=$" & slv_to_hex(debug_opcode) &
                       " A7=$" & slv_to_hex(debug_regfile_a7) severity error;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Debug Monitor: trace PC at key milestones
    ---------------------------------------------------------------
    debug_mon: process(clk)
        variable prev_pc : std_logic_vector(31 downto 0) := (others => '0');
        variable prev_fault : std_logic := '0';
        variable prev_berr : std_logic := '0';
    begin
        if rising_edge(clk) then
            if not is_x(debug_TG68_PC) and clkena_in = '1' then
                if debug_TG68_PC /= prev_pc then
                    if debug_TG68_PC = x"00000300" or debug_TG68_PC = x"0000030A"
                       or debug_TG68_PC = x"00000318" or debug_TG68_PC = x"00000324"
                       or debug_TG68_PC = x"0000032C" or debug_TG68_PC = x"00000200"
                       or debug_TG68_PC = x"00000280" or debug_TG68_PC = x"00000336" then
                        report "PC milestone: $" & slv_to_hex(debug_TG68_PC) &
                               " opcode=$" & slv_to_hex(debug_opcode) &
                               " fault=" & std_logic'image(debug_pmmu_fault) &
                               " berr=" & std_logic'image(debug_trap_berr) &
                               " busy=" & std_logic'image(pmmu_busy) &
                               " A7=$" & slv_to_hex(debug_regfile_a7);
                    end if;
                    prev_pc := debug_TG68_PC;
                end if;
            end if;
            if not is_x(debug_pmmu_fault) and debug_pmmu_fault /= prev_fault then
                report "PMMU FAULT changed to " & std_logic'image(debug_pmmu_fault) &
                       " at PC=$" & slv_to_hex(debug_TG68_PC) &
                       " addr_log=$" & slv_to_hex(pmmu_addr_log) &
                       " phys=$" & slv_to_hex(pmmu_addr_phys) &
                       " A7=$" & slv_to_hex(debug_regfile_a7);
                prev_fault := debug_pmmu_fault;
            end if;
            if not is_x(debug_trap_berr) and debug_trap_berr /= prev_berr then
                report "TRAP_BERR changed to " & std_logic'image(debug_trap_berr) &
                       " at PC=$" & slv_to_hex(debug_TG68_PC);
                prev_berr := debug_trap_berr;
            end if;
        end if;
    end process;

    -- Per-cycle trace around fault time (mirrors tb_berr_frame.vhd's
    -- BUG #428 diagnostic trace, extended to also show cpu_halted).
    fault_trace: process(clk)
        variable cycle_count : integer := 0;
    begin
        if rising_edge(clk) then
            if not is_x(debug_pmmu_fault) then
                if debug_pmmu_fault = '1' and not fault_trace_active then
                    fault_trace_active <= true;
                    cycle_count := 0;
                end if;
                if fault_trace_active then
                    cycle_count := cycle_count + 1;
                    report "TRACE[" & integer'image(cycle_count) & "]:" &
                           " st=" & slv_to_hex("000000" & debug_state) &
                           " clw=" & std_logic'image(debug_clkena_lw) &
                           " cin=" & std_logic'image(clkena_in) &
                           " mw=" & std_logic'image(mem_wait) &
                           " fault=" & std_logic'image(debug_pmmu_fault) &
                           " mberr=" & std_logic'image(debug_make_berr) &
                           " tberr=" & std_logic'image(debug_trap_berr) &
                           " halted=" & std_logic'image(debug_cpu_halted) &
                           " busy=" & std_logic'image(pmmu_busy) &
                           " mm=" & slv_to_hex("00" & debug_memmask) &
                           " mmx=" & slv_to_hex("00" & debug_memmaskmux) &
                           " alog=$" & slv_to_hex(pmmu_addr_log) &
                           " A7=$" & slv_to_hex(debug_regfile_a7);
                    if cycle_count > 40 then
                        fault_trace_active <= false;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Test Monitor
    ---------------------------------------------------------------
    test_monitor: process
        variable val16 : std_logic_vector(15 downto 0);
        variable val32 : std_logic_vector(31 downto 0);
        variable handler_marker    : std_logic_vector(31 downto 0);
        variable unexpected_marker : std_logic_vector(31 downto 0);
        variable fallthrough_marker : std_logic_vector(31 downto 0);
        variable fmt_vec  : std_logic_vector(15 downto 0);
        variable saved_pc : std_logic_vector(31 downto 0);
        variable reached_stop : boolean := false;
        variable pass  : boolean;
        variable tests_passed : integer := 0;
        variable tests_failed : integer := 0;

        procedure check_test(test_id : integer; test_name : string; passed : boolean) is
        begin
            if passed then
                tests_passed := tests_passed + 1;
                report "TEST " & integer'image(test_id) & ": " & test_name & " -> PASSED";
            else
                tests_failed := tests_failed + 1;
                report "TEST " & integer'image(test_id) & ": " & test_name & " -> FAILED" severity error;
            end if;
        end procedure;

    begin
        report "=== SRP ROOT-LEVEL DIRECT-PAGE STACKING TEST ===";
        report "Reproducing real hardware TC=$82A08680 SRP_H=$80000002 SRP_L=$40080000";
        report "with root entry 64 = $40000009 (exact captured descriptor).";
        report "Question: does exception dispatch through the SRP-translated";
        report "supervisor stack complete cleanly, or does it double-fault?";

        nReset <= '0';
        wait for CLK_PERIOD * 5;
        nReset <= '1';

        -- Wait for STOP (either the handler's or the fallthrough safety
        -- net's) OR for debug_cpu_halted to assert, whichever comes first.
        -- Generous timeout: this walk is SHORTER than tb_berr_frame's
        -- (root-level early termination needs only one descriptor read
        -- per fresh translation, vs. a full A->B->C chain there), but we
        -- still allow ample margin and confirm actual completion time
        -- below in the transcript.
        for i in 0 to 3000 loop
            wait for 100 ns;
            if not is_x(debug_opcode) and debug_opcode = x"4E72" then
                report "CPU reached STOP at " & time'image(now);
                reached_stop := true;
                exit;
            end if;
            if halted_seen then
                report "CPU HALTED (detected by monitor loop) at " & time'image(now);
                exit;
            end if;
        end loop;

        wait for 200 ns;

        ---------------------------------------------------------------
        -- Gather final state
        ---------------------------------------------------------------
        handler_marker     := mem(768) & mem(769);
        unexpected_marker  := mem(770) & mem(771);
        fmt_vec            := mem(772);
        saved_pc           := mem(774) & mem(775);
        fallthrough_marker := mem(776) & mem(777);

        report "========================================";
        report "FINAL STATE DUMP:";
        report "  reached_stop        = " & boolean'image(reached_stop);
        report "  halted_seen         = " & boolean'image(halted_seen);
        report "  debug_cpu_halted    = " & std_logic'image(debug_cpu_halted);
        report "  final debug_TG68_PC = $" & slv_to_hex(debug_TG68_PC);
        report "  final micro_state   = " & integer'image(debug_micro_state);
        report "  final debug_opcode  = $" & slv_to_hex(debug_opcode);
        if halted_seen then
            report "  halted_pc           = $" & slv_to_hex(halted_pc);
            report "  halted_micro_state  = " & integer'image(halted_micro_state);
            report "  halted_opcode       = $" & slv_to_hex(halted_opcode);
        end if;
        report "  handler_marker ($0600)     = $" & slv_to_hex(handler_marker) &
               "  (expect $CAFEBABE if vector-2 handler ran cleanly)";
        report "  unexpected_marker ($0604)  = $" & slv_to_hex(unexpected_marker) &
               "  (expect $00000000 - anything else is a stray/wrong-vector dispatch)";
        report "  fallthrough_marker ($0610) = $" & slv_to_hex(fallthrough_marker) &
               "  (expect $00000000 - $0BADC0DE would mean the WP write never faulted)";
        report "  saved format/vector ($0608) = $" & slv_to_hex(fmt_vec) &
               "  (expect low 12 bits = $008 -> vector 2)";
        report "  saved faulted PC ($060C)    = $" & slv_to_hex(saved_pc);
        report "========================================";

        ---------------------------------------------------------------
        -- Test 1: The CPU must never assert debug_cpu_halted. This is
        -- THE definitive double-bus-fault signal; asserting it means
        -- this exact SRP/root-descriptor configuration reproduces the
        -- real hardware bug.
        ---------------------------------------------------------------
        pass := not halted_seen;
        check_test(1, "debug_cpu_halted never asserted (no double bus fault)", pass);

        ---------------------------------------------------------------
        -- Test 2: The CPU must reach a STOP instruction (not stall
        -- forever without either halting or dispatching).
        ---------------------------------------------------------------
        pass := reached_stop;
        check_test(2, "CPU reached a STOP instruction within timeout", pass);

        ---------------------------------------------------------------
        -- Test 3: The vector-2 (bus/MMU error) handler must have
        -- actually executed and written its distinct success marker -
        -- proving the full dispatch chain (frame push through the
        -- SRP-translated stack, vector-table read, handler opcode
        -- fetch) completed, not merely that cpu_halted stayed low.
        ---------------------------------------------------------------
        pass := (handler_marker = x"CAFEBABE");
        check_test(3, "Vector-2 handler executed (marker = $CAFEBABE)", pass);

        ---------------------------------------------------------------
        -- Test 4: No OTHER exception vector fired (would indicate the
        -- dispatch went somewhere unexpected rather than genuinely
        -- halting or cleanly reaching vector 2).
        ---------------------------------------------------------------
        pass := (unexpected_marker = x"00000000");
        check_test(4, "No unexpected/stray exception vector fired", pass);

        ---------------------------------------------------------------
        -- Test 5: The WP write must have actually faulted (fallthrough
        -- safety-net marker must NOT be set). If this fails, the test's
        -- own fault trigger is broken and tests 1-4 are not meaningful.
        ---------------------------------------------------------------
        pass := (fallthrough_marker = x"00000000");
        check_test(5, "WP write correctly faulted (did not fall through)", pass);

        ---------------------------------------------------------------
        -- Test 6: The saved format/vector word's low 12 bits must equal
        -- $008 (vector number 2), confirming dispatch went to the bus/
        -- MMU error vector specifically (Format nibble may be $A or $B
        -- depending on bus-cycle granularity - both are valid framings
        -- of vector 2 and are not what this test is evaluating).
        ---------------------------------------------------------------
        pass := (fmt_vec(11 downto 0) = x"008");
        check_test(6, "Dispatch used vector 2 (bus/MMU error)", pass);
        if not pass then
            report "  Got format/vector=$" & slv_to_hex(fmt_vec);
        end if;

        ---------------------------------------------------------------
        -- Summary
        ---------------------------------------------------------------
        report "========================================";
        report "TOTAL: " & integer'image(tests_passed + tests_failed) &
               " tests, " & integer'image(tests_passed) & " passed, " &
               integer'image(tests_failed) & " failed";
        if tests_failed = 0 then
            report "*** PASS: SRP root-level dispatch completed cleanly - no double fault ***";
        else
            report "*** FAIL: SRP root-level dispatch did NOT complete cleanly ***" severity error;
        end if;
        report "========================================";

        test_done <= true;
        wait;
    end process;

end behavioral;
