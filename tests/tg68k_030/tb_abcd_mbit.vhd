-- tb_abcd_mbit.vhd
-- Test ABCD.B D0,D0 with M=1 in various modes
-- Specifically tests: supervisor M=1 (SR=$3000) which fails in cputester
-- Tests the M-bit swap (ISP<->MSP) during MOVE to SR

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_abcd_mbit is
end entity;

architecture behavior of tb_abcd_mbit is
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal clkena_in : std_logic := '1';
    signal data_in   : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out  : std_logic_vector(31 downto 0);
    signal nWr       : std_logic;
    signal nUDS      : std_logic;
    signal nLDS      : std_logic;
    signal busstate  : std_logic_vector(1 downto 0);
    signal FC        : std_logic_vector(2 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 32767) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

    signal test_done : boolean := false;
    signal cycle_count : integer := 0;

    -- Stall injection for simulating integration-level behavior
    signal stall_enable : boolean := false;
    signal stall_pattern : integer := 0;
    signal clkena_gated : std_logic;
begin
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    process(clk)
    begin
        if rising_edge(clk) then
            cycle_count <= cycle_count + 1;
        end if;
    end process;

    -- Optional stall injection: every N cycles, insert a stall
    process(clk)
    begin
        if rising_edge(clk) then
            if stall_enable and (cycle_count mod stall_pattern = 0) then
                clkena_gated <= '0';
            else
                clkena_gated <= '1';
            end if;
        end if;
    end process;

    -- Use gated clock enable when stall testing is active
    clkena_in <= clkena_gated when stall_enable else '1';

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 1,
            extAddr_Mode   => 1,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",
            addr_out => addr_out,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            FC => FC,
            longword => open,
            nResetOut => open,
            clr_berr => open,
            skipFetch => open,
            regin_out => open,
            CACR_out => open,
            VBR_out => open,
            cache_inv_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr => open,
            pmmu_reg_we => open,
            pmmu_reg_re => open,
            pmmu_reg_sel => open,
            pmmu_reg_wdat => open,
            pmmu_reg_part => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req => open,
            pmmu_walker_we => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
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

    bus_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "00" then
                report "[" & integer'image(cycle_count) & "] FETCH $" &
                    integer'image(to_integer(unsigned(addr_out)));
            elsif busstate = "11" and nWr = '0' then
                report "[" & integer'image(cycle_count) & "] WRITE $" &
                    integer'image(to_integer(unsigned(addr_out))) &
                    " =$" & integer'image(to_integer(unsigned(data_write)));
            end if;
        end if;
    end process;

    test: process
        variable found : boolean;
        variable idx : integer;

        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure check_d0_result(test_name : string; addr_hi, addr_lo : integer; expected_lo_byte : std_logic_vector(7 downto 0)) is
        begin
            report test_name & ": D0 at mem = $" &
                integer'image(to_integer(unsigned(mem(addr_hi)))) &
                ":" & integer'image(to_integer(unsigned(mem(addr_lo))));
            if mem(addr_lo)(7 downto 0) = expected_lo_byte then
                report "PASS: " & test_name severity note;
            else
                report "FAIL: " & test_name & " - expected $" &
                    integer'image(to_integer(unsigned(expected_lo_byte))) &
                    " got $" & integer'image(to_integer(unsigned(mem(addr_lo)(7 downto 0)))) severity error;
            end if;
        end procedure;

        procedure wait_for_sentinel(addr : integer; label_str : string; max_cycles : integer := 5000) is
        begin
            found := false;
            for i in 1 to max_cycles loop
                wait until rising_edge(clk);
                if busstate = "00" and to_integer(unsigned(addr_out)) = addr then
                    found := true;
                    exit;
                end if;
            end loop;
            if not found then
                report "TIMEOUT: " & label_str & " - never reached $" & integer'image(addr) severity error;
            end if;
        end procedure;

    begin
        report "========================================================";
        report "ABCD M-bit Interaction Test";
        report "========================================================";

        for i in 0 to 32767 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset: SSP=$F000, PC=$1000
        mem(0) := x"0000"; mem(1) := x"F000";
        mem(2) := x"0000"; mem(3) := x"1000";

        -- ============================================================
        -- Program at $1000 (supervisor mode after reset, M=0)
        -- ============================================================
        idx := 16#800#;

        -- Test 1: ABCD in supervisor mode, M=0 (baseline)
        -- MOVE.L #$10, D0
        mem(idx) := x"203C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0010";
        idx := idx + 3;  -- $1006
        -- ABCD.B D0,D0
        mem(idx) := x"C100";
        idx := idx + 1;  -- $1008
        -- MOVE.L D0, ($6000)
        mem(idx) := x"23C0"; mem(idx+1) := x"0000"; mem(idx+2) := x"6000";
        idx := idx + 3;  -- $100E
        -- NOP sentinel
        mem(idx) := x"4E71";
        idx := idx + 1;  -- $1010

        -- Test 2: Switch to M=1 via MOVE to SR, then ABCD
        -- First initialize MSP via MOVEC: $4E7B (MOVEC Rn,Rc)
        -- MOVEC D1,MSP: opcode=$4E7B, ext=$1803 (D1, MSP=$803)
        -- First set D1 = $E000 (stack area for MSP)
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"E000";
        idx := idx + 3;  -- $1016
        -- MOVEC D1, MSP ($4E7B $1803)
        mem(idx) := x"4E7B"; mem(idx+1) := x"1803";
        idx := idx + 2;  -- $101A

        -- Set D0 = $10 again
        mem(idx) := x"203C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0010";
        idx := idx + 3;  -- $1020

        -- MOVE #$3000, SR  - switch to M=1 in supervisor mode
        -- $46FC $3000
        mem(idx) := x"46FC"; mem(idx+1) := x"3000";
        idx := idx + 2;  -- $1024

        -- ABCD.B D0,D0
        mem(idx) := x"C100";
        idx := idx + 1;  -- $1026

        -- MOVE.L D0, ($6010) - store result
        mem(idx) := x"23C0"; mem(idx+1) := x"0000"; mem(idx+2) := x"6010";
        idx := idx + 3;  -- $102C

        -- MOVE.L A7, ($6014) - store A7 (should be MSP=$E000)
        mem(idx) := x"23CF"; mem(idx+1) := x"0000"; mem(idx+2) := x"6014";
        idx := idx + 3;  -- $1032

        -- NOP sentinel
        mem(idx) := x"4E71";  -- $1032
        idx := idx + 1;  -- $1034

        -- Test 3: Switch back to M=0, then ABCD
        -- MOVE #$2000, SR  - M=0, S=1
        mem(idx) := x"46FC"; mem(idx+1) := x"2000";
        idx := idx + 2;  -- $1038

        -- Set D0 = $10 again
        mem(idx) := x"203C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0010";
        idx := idx + 3;  -- $103E

        -- ABCD.B D0,D0
        mem(idx) := x"C100";
        idx := idx + 1;  -- $1040

        -- MOVE.L D0, ($6020)
        mem(idx) := x"23C0"; mem(idx+1) := x"0000"; mem(idx+2) := x"6020";
        idx := idx + 3;  -- $1046

        -- NOP sentinel
        mem(idx) := x"4E71";  -- $1046
        idx := idx + 1;

        -- Test 4: ABCD with clkena_in stalls (simulate integration)
        -- Set D0 = $10
        mem(idx) := x"203C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0010";
        idx := idx + 3;
        -- MOVE #$3000, SR - M=1 again
        mem(idx) := x"46FC"; mem(idx+1) := x"3000";
        idx := idx + 2;
        -- ABCD.B D0,D0
        mem(idx) := x"C100";
        idx := idx + 1;
        -- MOVE.L D0, ($6030)
        mem(idx) := x"23C0"; mem(idx+1) := x"0000"; mem(idx+2) := x"6030";
        idx := idx + 3;
        -- NOP sentinel at calculated address
        mem(idx) := x"4E71";
        -- Save sentinel address: idx * 2 = address
        -- idx starts at 16#800# for $1000, so current idx offset from 16#800# gives byte offset
        -- Actually: mem index = addr/2, so addr = idx * 2

        -- Release reset
        wait_cycles(5);
        nReset <= '1';

        -- ============================================================
        -- Test 1: Baseline supervisor M=0
        -- ============================================================
        report "--- Test 1: ABCD.B D0,D0 supervisor M=0 (baseline) ---";
        wait_for_sentinel(16#100E#, "Test 1");
        wait_cycles(10);
        check_d0_result("Test1 ABCD M=0", 16#3000#, 16#3001#, x"20");

        -- ============================================================
        -- Test 2: Supervisor M=1 (MOVE #$3000,SR)
        -- ============================================================
        report "--- Test 2: ABCD.B D0,D0 supervisor M=1 ($3000) ---";
        wait_for_sentinel(16#1032#, "Test 2");
        wait_cycles(10);
        check_d0_result("Test2 ABCD M=1", 16#3008#, 16#3009#, x"20");

        -- Check A7 (should be MSP=$E000)
        report "A7 at $6014: $" & integer'image(to_integer(unsigned(mem(16#300A#)))) &
            ":" & integer'image(to_integer(unsigned(mem(16#300B#))));
        if mem(16#300A#) = x"0000" and mem(16#300B#) = x"E000" then
            report "PASS: A7=$E000 (MSP correct after M 0->1)" severity note;
        else
            report "INFO: A7 not $E000 after M change" severity warning;
        end if;

        -- ============================================================
        -- Test 3: Back to M=0
        -- ============================================================
        report "--- Test 3: ABCD.B D0,D0 back to M=0 ($2000) ---";
        wait_for_sentinel(16#1046#, "Test 3");
        wait_cycles(10);
        check_d0_result("Test3 ABCD back to M=0", 16#3010#, 16#3011#, x"20");

        -- ============================================================
        -- Test 4: ABCD M=1 with clkena_in stalls (every 3 cycles)
        -- ============================================================
        report "--- Test 4: ABCD.B D0,D0 M=1 with stalls ---";
        stall_enable <= true;
        stall_pattern <= 3;
        -- The sentinel for test 4 depends on the code layout
        -- Test 4 code starts at idx after test 3 sentinel
        -- Let me just wait for a write to $6030
        found := false;
        for i in 1 to 20000 loop
            wait until rising_edge(clk);
            if busstate = "11" and nWr = '0' and
               to_integer(unsigned(addr_out)) = 16#6032# then
                -- Low word of MOVE.L D0,($6030) is at $6032
                found := true;
                exit;
            end if;
        end loop;
        stall_enable <= false;
        wait_cycles(20);
        if found then
            check_d0_result("Test4 ABCD M=1 stalled", 16#3018#, 16#3019#, x"20");
        else
            report "FAIL: Test 4 timeout - stalled execution didn't complete" severity error;
        end if;

        report "========================================================";
        report "All ABCD M-bit tests complete";
        report "========================================================";

        test_done <= true;
        wait;
    end process;

end architecture;
