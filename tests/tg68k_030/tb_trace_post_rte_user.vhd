-- tb_trace_post_rte_user.vhd
-- Verifies that after Group 1/2 trap exception entry + handler RTE +
-- (optional) stacked T0 trace exception + trace handler RTE, the CPU
-- successfully returns to USER mode with USP intact.
--
-- The existing tb_group2_t0_trace and friends only check the stacked-frame
-- field contents while the handler is still running (handlers STOP rather
-- than RTE). That permits bugs in the supervisor->user changeMode path
-- (USP corruption, S-bit not cleared) to slip through. Toni Wilen's
-- cputest exercises the full RTE-back-to-user path and reports
-- "A7 expected $42000400 but got $420003fc" / SR stuck in supervisor
-- when the changeMode is broken; this testbench reproduces that
-- check inside ModelSim.
--
-- Five sub-tests:
--   T1: TRAP #0 with T0=0 -> single trap+RTE.  Sanity baseline.
--   T2: TRAP #0 with T0=1 -> trap+RTE + T0 trace fire after RTE +
--       trace+RTE.  Matches cputest's CHK.L sequence.
--   T3: TRAP #0 that traps with T0=1 -> Group 2 trap entry with stacked
--       trace -> trace handler RTE -> TRAP handler RTE.  Exercises the
--       trace_stk_grp2 path.
--
-- For each sub-test we run the CPU until a known user-mode marker write
-- lands in memory, then check:
--   * marker present at known address (proves user code resumed)
--   * S bit is 0 (back in user mode)
--   * A7 (regfile A7) equals the initial USP (no leak)
--   * Internal USP shadow matches expected
--
-- The test deliberately does NOT use STOP handlers; both vectors RTE
-- back so the full trap+RTE pipeline is exercised.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_trace_post_rte_user is
end entity;

architecture behavior of tb_trace_post_rte_user is
    signal clk        : std_logic := '0';
    signal nReset     : std_logic := '0';
    signal clkena_in  : std_logic := '1';
    signal data_in    : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal busstate   : std_logic_vector(1 downto 0);
    signal FC         : std_logic_vector(2 downto 0);
    signal IPL_sig    : std_logic_vector(2 downto 0) := "111";

    signal debug_SVmode     : std_logic;
    signal debug_FlagsSR_S  : std_logic;
    signal debug_regfile_a7 : std_logic_vector(31 downto 0);
    signal debug_USP        : std_logic_vector(31 downto 0);
    signal debug_ISP        : std_logic_vector(31 downto 0);
    signal debug_MSP        : std_logic_vector(31 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 32767) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;

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

begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 1,
            extAddr_Mode   => 1,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk            => clk,
            nReset         => nReset,
            clkena_in      => clkena_in,
            data_in        => data_in,
            IPL            => IPL_sig,
            IPL_autovector => '1',
            berr           => '0',
            CPU            => "10",
            addr_out       => addr_out,
            data_write     => data_write,
            nWr            => nWr,
            nUDS           => nUDS,
            nLDS           => nLDS,
            busstate       => busstate,
            FC             => FC,
            longword       => open,
            nResetOut      => open,
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
            pmmu_addr_log  => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req  => open,
            pmmu_walker_we   => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack  => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode        => debug_SVmode,
            debug_preSVmode     => open,
            debug_FlagsSR_S     => debug_FlagsSR_S,
            debug_regfile_a7    => debug_regfile_a7,
            debug_USP           => debug_USP,
            debug_MSP           => debug_MSP,
            debug_ISP           => debug_ISP,
            debug_changeMode    => open,
            debug_setopcode     => open,
            debug_exec_directSR => open,
            debug_exec_to_SR    => open,
            debug_pmove_dn_mode   => open,
            debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 32767 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 32767 then
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable v_pass_count : integer := 0;
        variable v_fail_count : integer := 0;
        variable v_marker     : std_logic_vector(31 downto 0);

        procedure init_memory is
        begin
            for i in 0 to 32767 loop
                mem(i) := x"4E71";
            end loop;
            -- Reset SSP = $4000, reset PC = $1000
            mem(0) := x"0000"; mem(1) := x"4000";
            mem(2) := x"0000"; mem(3) := x"1000";
        end procedure;

        procedure setup_vector(vec_offset : integer; handler_addr : integer) is
        begin
            mem(vec_offset / 2)     := std_logic_vector(to_unsigned(handler_addr / 65536, 16));
            mem(vec_offset / 2 + 1) := std_logic_vector(to_unsigned(handler_addr mod 65536, 16));
        end procedure;

        -- Handler that immediately RTEs.  No register saves; just pop the
        -- frame and return.  Used for both the Group 1/2 vector and the
        -- T0 trace vector so the full trap+RTE chain is exercised.
        procedure setup_rte_handler(handler_addr : integer) is
        begin
            mem(handler_addr / 2)     := x"4E73";  -- RTE
        end procedure;

        -- Illegal-instruction handlers that intend to continue execution must
        -- advance the stacked format-0 PC. WinUAE stacks regs.instruction_pc
        -- for vector 4, so a plain RTE correctly re-enters the same ILLEGAL.
        procedure setup_skip_illegal_rte_handler(handler_addr : integer) is
        begin
            mem(handler_addr / 2)     := x"54AF";  -- ADDQ.L #2,2(A7)
            mem(handler_addr / 2 + 1) := x"0002";
            mem(handler_addr / 2 + 2) := x"4E73";  -- RTE
        end procedure;

        procedure setup_skip_priv_sr_rte_handler(handler_addr : integer) is
        begin
            mem(handler_addr / 2)     := x"58AF";  -- ADDQ.L #4,2(A7)
            mem(handler_addr / 2 + 1) := x"0002";
            mem(handler_addr / 2 + 2) := x"4E73";  -- RTE
        end procedure;

        procedure clear_marker(marker_addr : integer) is
        begin
            mem(marker_addr / 2)     := x"DEAD";
            mem(marker_addr / 2 + 1) := x"BEEF";
        end procedure;

        procedure read_marker(marker_addr : integer) is
        begin
            v_marker := mem(marker_addr / 2) & mem(marker_addr / 2 + 1);
        end procedure;

        procedure do_reset is
        begin
            nReset  <= '0';
            IPL_sig <= "111";
            wait for 100 ns;
            nReset  <= '1';
            for i in 0 to 2000 loop
                wait until rising_edge(clk);
                if addr_out(15 downto 0) = x"1000" then
                    exit;
                end if;
            end loop;
        end procedure;

        -- Run until either the marker has been written or timeout. Marker
        -- write proves user code resumed after all RTEs.
        procedure run_until_marker(marker_addr : integer; timeout_cycles : integer := 30000) is
            variable cur : std_logic_vector(31 downto 0);
        begin
            for i in 0 to timeout_cycles loop
                wait until rising_edge(clk);
                cur := mem(marker_addr / 2) & mem(marker_addr / 2 + 1);
                if cur = x"AABBCCDD" then
                    return;
                end if;
            end loop;
            report "TIMEOUT waiting for user-code marker at $" &
                   slv_to_hex(std_logic_vector(to_unsigned(marker_addr, 32))) severity error;
            v_fail_count := v_fail_count + 1;
        end procedure;

        procedure check_eq32(test_name : string;
                             actual    : std_logic_vector(31 downto 0);
                             expected  : std_logic_vector(31 downto 0)) is
        begin
            if actual = expected then
                report "  PASS: " & test_name severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & ": expected $" &
                       slv_to_hex(expected) & ", got $" & slv_to_hex(actual) severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_bit(test_name : string;
                            actual    : std_logic;
                            expected  : std_logic) is
        begin
            if actual = expected then
                report "  PASS: " & test_name severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & ": expected " & std_logic'image(expected) &
                       ", got " & std_logic'image(actual) severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        -- Common post-RTE checks: marker, S=0, A7=USP intact.
        procedure verify_post_rte(test_name   : string;
                                  marker_addr : integer;
                                  expected_a7 : std_logic_vector(31 downto 0)) is
        begin
            read_marker(marker_addr);
            check_eq32(test_name & ": user marker at $" &
                       slv_to_hex(std_logic_vector(to_unsigned(marker_addr, 32))),
                       v_marker, x"AABBCCDD");
            check_bit (test_name & ": SVmode=0 (user mode after RTE)",
                       debug_SVmode, '0');
            check_bit (test_name & ": FlagsSR.S=0 (user mode after RTE)",
                       debug_FlagsSR_S, '0');
            check_eq32(test_name & ": A7 = expected USP (no stack leak)",
                       debug_regfile_a7, expected_a7);
            check_eq32(test_name & ": USP shadow = expected USP",
                       debug_USP, expected_a7);
        end procedure;

    begin
        report "============================================================" severity note;
        report "Trace Post-RTE User-Mode Return Regression"                    severity note;
        report "Verifies trap entry + handler RTE leaves CPU in user mode"     severity note;
        report "with USP intact and (when applicable) T0 preserved."           severity note;
        report "============================================================" severity note;

        ------------------------------------------------------------------
        -- TEST 1: TRAP #0 with T0=0 (baseline; no trace involved)
        ------------------------------------------------------------------
        report "" severity note;
        report "TEST 1: TRAP #0, T0=0 - baseline single trap+RTE" severity note;
        init_memory;
        setup_vector(16#80#, 16#2000#);   -- vector 32 (TRAP #0) -> $2000
        setup_rte_handler(16#2000#);
        clear_marker(16#5000#);
        -- User program at $1000:
        --   $1000: MOVEA.L #$3F00,A0
        --   $1006: MOVE A0,USP            ; set USP to $3F00
        --   $1008: MOVE.W #$0000,SR       ; user mode, T0=0 (still privileged
        --                                 ; until first user-mode write succeeds)
        --   $100C: TRAP #0                ; vector 32, resumes at next word
        --   $100E: MOVE.L #$AABBCCDD,$5000.L  ; marker after RTE
        --   $1018: BRA *                  ; spin
        mem(16#1000# / 2) := x"207C";  -- MOVEA.L #imm32,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3F00";
        mem(16#1006# / 2) := x"4E60";  -- MOVE A0,USP
        mem(16#1008# / 2) := x"46FC";  -- MOVE.W #imm,SR
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"4E40";  -- TRAP #0
        mem(16#100E# / 2) := x"23FC";  -- MOVE.L #imm32,abs.L
        mem(16#1010# / 2) := x"AABB";
        mem(16#1012# / 2) := x"CCDD";
        mem(16#1014# / 2) := x"0000";
        mem(16#1016# / 2) := x"5000";
        mem(16#1018# / 2) := x"60FE";  -- BRA *
        do_reset;
        run_until_marker(16#5000#);
        verify_post_rte("T1", 16#5000#, x"00003F00");

        ------------------------------------------------------------------
        -- TEST 2: TRAP #0 with T0=1 - exercises post-RTE trace flow
        ------------------------------------------------------------------
        report "" severity note;
        report "TEST 2: TRAP #0 with T0=1" severity note;
        report "        TRAP handler RTE -> T0 trace fires -> trace RTE" severity note;
        init_memory;
        setup_vector(16#80#, 16#2000#);   -- vector 32 (TRAP #0) -> $2000
        setup_vector(16#24#, 16#2100#);   -- vector 9 (trace)   -> $2100
        setup_rte_handler(16#2000#);
        setup_rte_handler(16#2100#);
        clear_marker(16#5000#);
        mem(16#1000# / 2) := x"207C";  -- MOVEA.L #$3F00,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3F00";
        mem(16#1006# / 2) := x"4E60";  -- MOVE A0,USP
        mem(16#1008# / 2) := x"46FC";  -- MOVE.W #$4000,SR  (T0=1, S=0)
        mem(16#100A# / 2) := x"4000";
        mem(16#100C# / 2) := x"4E71";  -- NOP (let T0 settle)
        mem(16#100E# / 2) := x"4E40";  -- TRAP #0
        mem(16#1010# / 2) := x"23FC";  -- MOVE.L #$AABBCCDD, $5000.L
        mem(16#1012# / 2) := x"AABB";
        mem(16#1014# / 2) := x"CCDD";
        mem(16#1016# / 2) := x"0000";
        mem(16#1018# / 2) := x"5000";
        mem(16#101A# / 2) := x"60FE";  -- BRA *
        do_reset;
        run_until_marker(16#5000#);
        verify_post_rte("T2", 16#5000#, x"00003F00");

        ------------------------------------------------------------------
        -- TEST 3: TRAP #0 with T0=1, second vector placement. Covers the same
        --         Group 2 stacked-trace path without requiring handler PC repair.
        ------------------------------------------------------------------
        report "" severity note;
        report "TEST 3: TRAP #0 with T0=1 (stacked trace + Group 2 RTE)" severity note;
        init_memory;
        setup_vector(16#80#, 16#2000#);   -- vector 32 (TRAP #0) -> $2000
        setup_vector(16#24#, 16#2100#);   -- vector 9 (trace) -> $2100
        setup_rte_handler(16#2000#);
        setup_rte_handler(16#2100#);
        clear_marker(16#5000#);
        -- T0=1, then TRAP #0: handler RTE should resume at the following
        -- marker write, with A7 restored from USP.
        mem(16#1000# / 2) := x"207C";  -- MOVEA.L #$3F00,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3F00";
        mem(16#1006# / 2) := x"4E60";  -- MOVE A0,USP
        mem(16#1008# / 2) := x"46FC";  -- MOVE.W #$4000,SR (T0=1,S=0)
        mem(16#100A# / 2) := x"4000";
        mem(16#100C# / 2) := x"4E71";  -- NOP
        mem(16#100E# / 2) := x"4E40";  -- TRAP #0
        mem(16#1010# / 2) := x"4E71";  -- NOP after TRAP
        mem(16#1012# / 2) := x"4E71";  -- NOP after trace
        mem(16#1014# / 2) := x"4E71";  -- NOP before marker
        mem(16#1016# / 2) := x"4E71";
        mem(16#1018# / 2) := x"23FC";  -- MOVE.L #$AABBCCDD, $5000.L
        mem(16#101A# / 2) := x"AABB";
        mem(16#101C# / 2) := x"CCDD";
        mem(16#101E# / 2) := x"0000";
        mem(16#1020# / 2) := x"5000";
        mem(16#1022# / 2) := x"60FE";  -- BRA *
        do_reset;
        run_until_marker(16#5000#);
        verify_post_rte("T3", 16#5000#, x"00003F00");

        ------------------------------------------------------------------
        -- TEST 4: cputest CHK.L pattern reproduction
        --   CHK.L D0,D0 (D0=$10, in range, no trap)
        --   ILLEGAL  -> vector 4 (Group 1) handler advances stacked PC, then RTE
        --   then T0 trace fires (RTE is COF), trace handler RTE
        --   On real hardware this sequence corrupts USP (A7 = USP-4) and
        --   leaves the CPU in supervisor mode (Toni Wilen cputest report).
        ------------------------------------------------------------------
        report "" severity note;
        report "TEST 4: CHK.L D0,D0 + ILLEGAL with T0=1 (cputest CHK.L)" severity note;
        init_memory;
        setup_vector(16#10#, 16#2000#);   -- vector 4 (illegal) -> $2000
        setup_vector(16#24#, 16#2100#);   -- vector 9 (trace)   -> $2100
        setup_skip_illegal_rte_handler(16#2000#);
        setup_rte_handler(16#2100#);
        clear_marker(16#5000#);
        -- User program:
        --   MOVEA.L #$3F00,A0 / MOVE A0,USP   -- properly seed USP
        --   MOVE.W #$4000,SR                  -- T0=1, S=0 (enter user mode)
        --   NOP                               -- T0 armed before tested seq
        --   MOVE.L #$00000010,D0              -- D0 = $10 (in CHK.L range)
        --   CHK.L D0,D0                       -- in range: no trap, CC update
        --   ILLEGAL                            -- vector 4 trap
        --   MOVE.L #$AABBCCDD,$5000.L         -- marker after both RTEs
        --   BRA *
        mem(16#1000# / 2) := x"207C";  -- MOVEA.L #$3F00,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3F00";
        mem(16#1006# / 2) := x"4E60";  -- MOVE A0,USP
        mem(16#1008# / 2) := x"46FC";  -- MOVE.W #$4000,SR (T0=1,S=0)
        mem(16#100A# / 2) := x"4000";
        mem(16#100C# / 2) := x"4E71";  -- NOP (let T0 settle)
        mem(16#100E# / 2) := x"203C";  -- MOVE.L #$10,D0
        mem(16#1010# / 2) := x"0000";
        mem(16#1012# / 2) := x"0010";
        mem(16#1014# / 2) := x"4100";  -- CHK.L D0,D0  (no trap, D0=$10)
        mem(16#1016# / 2) := x"4AFC";  -- ILLEGAL
        mem(16#1018# / 2) := x"23FC";  -- MOVE.L #$AABBCCDD, $5000.L
        mem(16#101A# / 2) := x"AABB";
        mem(16#101C# / 2) := x"CCDD";
        mem(16#101E# / 2) := x"0000";
        mem(16#1020# / 2) := x"5000";
        mem(16#1022# / 2) := x"60FE";  -- BRA *
        do_reset;
        run_until_marker(16#5000#);
        verify_post_rte("T4", 16#5000#, x"00003F00");

        ------------------------------------------------------------------
        -- TEST 5: cputest CHK2.L-flavored pattern
        --   T0=1, then CHK2.L (a0),d0 with a0=0 (bounds at mem[0..7]) -> trap vector 6
        --   Group 2 stacked trace fires; both handlers RTE
        ------------------------------------------------------------------
        report "" severity note;
        report "TEST 5: CHK2.L with T0=1 (cputest CHK2.L style)" severity note;
        init_memory;
        setup_vector(16#18#, 16#2000#);   -- vector 6 (CHK)   -> $2000
        setup_vector(16#24#, 16#2100#);   -- vector 9 (trace) -> $2100
        setup_rte_handler(16#2000#);
        setup_rte_handler(16#2100#);
        clear_marker(16#5000#);
        -- Set bounds at $6000 so CHK2 traps for D0=$10:
        -- (A0)=$00000005 (low) / (A0+4)=$00000008 (high). D0=$10 > high -> trap.
        mem(16#6000# / 2) := x"0000"; mem(16#6001# / 2) := x"0005";
        mem(16#6002# / 2) := x"0000"; mem(16#6003# / 2) := x"0008";
        mem(16#1000# / 2) := x"207C";  -- MOVEA.L #$3F00,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3F00";
        mem(16#1006# / 2) := x"4E60";  -- MOVE A0,USP
        mem(16#1008# / 2) := x"203C";  -- MOVE.L #$10,D0
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"0010";
        mem(16#100E# / 2) := x"307C";  -- MOVEA.W #$6000,A0
        mem(16#1010# / 2) := x"6000";
        mem(16#1012# / 2) := x"46FC";  -- MOVE.W #$4000,SR (T0=1,S=0)
        mem(16#1014# / 2) := x"4000";
        mem(16#1016# / 2) := x"4E71";  -- NOP (T0 settle)
        mem(16#1018# / 2) := x"04D0";  -- CHK2.L (A0),D0  (D0=$10 > high=$08 -> trap)
        mem(16#101A# / 2) := x"0800";
        mem(16#101C# / 2) := x"23FC";  -- MOVE.L #$AABBCCDD, $5000.L
        mem(16#101E# / 2) := x"AABB";
        mem(16#1020# / 2) := x"CCDD";
        mem(16#1022# / 2) := x"0000";
        mem(16#1024# / 2) := x"5000";
        mem(16#1026# / 2) := x"60FE";  -- BRA *
        do_reset;
        run_until_marker(16#5000#);
        verify_post_rte("T5", 16#5000#, x"00003F00");

        ------------------------------------------------------------------
        -- TEST 6: user RTS returns directly to privileged SR instruction.
        -- The live black-screen capture showed vector-8 frame PC landing two
        -- bytes early on the preceding RTS. The handler skips the 4-byte
        -- ORI.W #imm,SR by adjusting the stacked PC; stale opcode_pc returns
        -- into the middle of the sequence and the marker is never reached.
        ------------------------------------------------------------------
        report "" severity note;
        report "TEST 6: RTS -> ORI.W #imm,SR privilege frame PC" severity note;
        init_memory;
        setup_vector(16#20#, 16#2000#);   -- vector 8 (privilege) -> $2000
        setup_skip_priv_sr_rte_handler(16#2000#);
        clear_marker(16#5000#);
        mem(16#1000# / 2) := x"207C";  -- MOVEA.L #$3F00,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3F00";
        mem(16#1006# / 2) := x"4E60";  -- MOVE A0,USP
        mem(16#1008# / 2) := x"46FC";  -- MOVE.W #$0000,SR (user mode)
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"4EB9";  -- JSR $00001100
        mem(16#100E# / 2) := x"0000";
        mem(16#1010# / 2) := x"1100";
        mem(16#1012# / 2) := x"007C";  -- ORI.W #$0700,SR (privileged)
        mem(16#1014# / 2) := x"0700";
        mem(16#1016# / 2) := x"23FC";  -- MOVE.L #$AABBCCDD, $5000.L
        mem(16#1018# / 2) := x"AABB";
        mem(16#101A# / 2) := x"CCDD";
        mem(16#101C# / 2) := x"0000";
        mem(16#101E# / 2) := x"5000";
        mem(16#1020# / 2) := x"60FE";  -- BRA *
        mem(16#1100# / 2) := x"4E75";  -- RTS
        do_reset;
        run_until_marker(16#5000#);
        verify_post_rte("T6", 16#5000#, x"00003F00");

        ------------------------------------------------------------------
        -- TEST 7: direct jump to an entry whose previous word is RTS.
        -- Kickstart has exactly this shape at $F80CC0/$F80CC2. The privilege
        -- frame must stack the ORI.W PC, not the preceding RTS word.
        ------------------------------------------------------------------
        report "" severity note;
        report "TEST 7: JMP entry+2 after RTS -> ORI.W #imm,SR PC" severity note;
        init_memory;
        setup_vector(16#20#, 16#2000#);   -- vector 8 (privilege) -> $2000
        setup_skip_priv_sr_rte_handler(16#2000#);
        clear_marker(16#5000#);
        mem(16#1000# / 2) := x"207C";  -- MOVEA.L #$3F00,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3F00";
        mem(16#1006# / 2) := x"4E60";  -- MOVE A0,USP
        mem(16#1008# / 2) := x"46FC";  -- MOVE.W #$0000,SR (user mode)
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"4EF9";  -- JMP $00001020
        mem(16#100E# / 2) := x"0000";
        mem(16#1010# / 2) := x"1020";
        mem(16#101E# / 2) := x"4E75";  -- Previous function ends with RTS
        mem(16#1020# / 2) := x"007C";  -- ORI.W #$0700,SR (privileged entry)
        mem(16#1022# / 2) := x"0700";
        mem(16#1024# / 2) := x"23FC";  -- MOVE.L #$AABBCCDD, $5000.L
        mem(16#1026# / 2) := x"AABB";
        mem(16#1028# / 2) := x"CCDD";
        mem(16#102A# / 2) := x"0000";
        mem(16#102C# / 2) := x"5000";
        mem(16#102E# / 2) := x"60FE";  -- BRA *
        do_reset;
        run_until_marker(16#5000#);
        verify_post_rte("T7", 16#5000#, x"00003F00");

        ------------------------------------------------------------------
        -- Summary
        ------------------------------------------------------------------
        report "" severity note;
        report "============================================================" severity note;
        report "POST-RTE USER-MODE RETURN: " &
               integer'image(v_pass_count) & " passed, " &
               integer'image(v_fail_count) & " failed" severity note;
        if v_fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        report "============================================================" severity note;

        test_done <= true;
        wait;
    end process;
end architecture;
