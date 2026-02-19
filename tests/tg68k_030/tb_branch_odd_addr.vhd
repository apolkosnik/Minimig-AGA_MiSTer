-- tb_branch_odd_addr.vhd
-- Comprehensive test for branches to odd addresses and ISP/MSP integrity
-- Tests: BCC, BSR, DBCC, JMP, JSR, RTE, RTR, RTS with odd target addresses
-- Validates:
--   1. Address error exception (vector 3) fires for each instruction type
--   2. ISP does not overwrite MSP during supervisor->user transitions
--   3. ISP does not overwrite MSP during user->supervisor transitions
--   4. M-bit swap integrity across exception handling

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_branch_odd_addr is
end entity;

architecture behavior of tb_branch_odd_addr is
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
    -- 64K words = 128KB address space
    type mem_array_t is array(0 to 65535) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

    signal test_done : boolean := false;
    signal test_passed : integer := 0;
    signal test_failed : integer := 0;
    signal cycle_count : integer := 0;

begin
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    process(clk)
    begin
        if rising_edge(clk) then
            cycle_count <= cycle_count + 1;
        end if;
    end process;

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
            CPU => "10",  -- 68030
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

    -- Memory read: use addr_out(16:1) for word address (128KB space)
    data_in <= mem(to_integer(unsigned(addr_out(16 downto 1))))
               when to_integer(unsigned(addr_out(16 downto 1))) <= 65535 else x"4E71";

    -- Memory write
    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(16 downto 1))) <= 65535 then
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(16 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(16 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Bus monitor disabled for performance (enable for debugging)
    -- bus_monitor: process(clk)
    -- begin
    --     if rising_edge(clk) then
    --         if busstate = "11" and nWr = '0' then
    --             report "[" & integer'image(cycle_count) & "] WRITE";
    --         end if;
    --     end if;
    -- end process;

    test: process
        variable found_exception : boolean;
        variable found_target    : boolean;
        variable found_sentinel  : boolean;
        variable vec_read        : std_logic_vector(9 downto 0);
        variable idx             : integer;

        -- Result storage addresses
        -- $8000-$8FFF: test result area
        constant RESULT_BASE : integer := 16#4000#;  -- word address for $8000

        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- Wait for either: address error exception, odd-address fetch, sentinel, or timeout
        -- Returns: found_exception=true if vector 3 ($0C) was read from vector table
        --          found_target=true if instruction fetch at odd address detected
        --          found_sentinel=true if sentinel_addr was fetched
        procedure wait_for_exception_or_sentinel(
            sentinel_addr : integer;
            max_cycles    : integer := 1500
        ) is
        begin
            found_exception := false;
            found_target := false;
            found_sentinel := false;
            for i in 1 to max_cycles loop
                wait until rising_edge(clk);

                -- Detect vector table read for address error (vector 3 at $0C)
                if busstate = "10" and
                   to_integer(unsigned(addr_out)) = 16#0C# then
                    found_exception := true;
                end if;

                -- Detect instruction fetch at an odd address (no exception fired)
                if busstate = "00" and addr_out(0) = '1' and not found_exception then
                    found_target := true;
                    exit;
                end if;

                -- Detect sentinel address fetch
                if busstate = "00" and
                   to_integer(unsigned(addr_out)) = sentinel_addr then
                    found_sentinel := true;
                    exit;
                end if;

                -- Exit if we see the address error handler
                if busstate = "00" and
                   to_integer(unsigned(addr_out)) = 16#3000# and found_exception then
                    found_sentinel := true;
                    exit;
                end if;
            end loop;
        end procedure;

        -- Check test result: expect address error exception
        procedure check_addr_error(test_name : string) is
        begin
            if found_exception then
                report "PASS: " & test_name & " - address error exception fired" severity note;
                test_passed <= test_passed + 1;
            elsif found_target then
                report "FAIL: " & test_name & " - CPU fetched from odd address without exception (trap_addr_error not implemented)" severity error;
                test_failed <= test_failed + 1;
            else
                report "FAIL: " & test_name & " - timeout, no exception and no odd fetch detected" severity error;
                test_failed <= test_failed + 1;
            end if;
        end procedure;

        -- Check that a memory location has an expected 32-bit value
        procedure check_mem32(
            test_name : string;
            byte_addr : integer;
            expected  : std_logic_vector(31 downto 0)
        ) is
            variable word_addr : integer;
            variable actual_hi : std_logic_vector(15 downto 0);
            variable actual_lo : std_logic_vector(15 downto 0);
            variable actual_32 : std_logic_vector(31 downto 0);
        begin
            word_addr := byte_addr / 2;
            actual_hi := mem(word_addr);
            actual_lo := mem(word_addr + 1);
            actual_32 := actual_hi & actual_lo;
            if actual_32 = expected then
                report "PASS: " & test_name severity note;
                test_passed <= test_passed + 1;
            else
                report "FAIL: " & test_name &
                    " - expected $" & integer'image(to_integer(unsigned(expected))) &
                    " got $" & integer'image(to_integer(unsigned(actual_32))) severity error;
                test_failed <= test_failed + 1;
            end if;
        end procedure;

        procedure wait_for_addr(target_addr : integer; label_str : string; max_cycles : integer := 8000) is
        begin
            found_sentinel := false;
            for i in 1 to max_cycles loop
                wait until rising_edge(clk);
                if busstate = "00" and to_integer(unsigned(addr_out)) = target_addr then
                    found_sentinel := true;
                    exit;
                end if;
            end loop;
            if not found_sentinel then
                report "TIMEOUT: " & label_str & " - never reached $" & integer'image(target_addr) severity error;
            end if;
        end procedure;

        procedure init_memory is
        begin
            for i in 0 to 65535 loop
                mem(i) := x"4E71";  -- Fill with NOPs
            end loop;

            -- ============================================================
            -- Exception vectors (at address $000)
            -- ============================================================
            -- Vector 0: Reset SSP = $0800
            mem(0) := x"0000"; mem(1) := x"0800";
            -- Vector 1: Reset PC = $1000
            mem(2) := x"0000"; mem(3) := x"1000";

            -- Vector 3: Address Error ($0C) -> handler at $3000
            mem(16#0C#/2)     := x"0000";
            mem(16#0C#/2 + 1) := x"3000";

            -- Vector 32: TRAP #0 ($80) -> handler at $4000
            mem(16#80#/2)     := x"0000";
            mem(16#80#/2 + 1) := x"4000";

            -- ============================================================
            -- Address error handler at $3000
            -- Just executes STOP #$2700 so we can detect completion
            -- ============================================================
            mem(16#3000#/2) := x"4E72";  -- STOP #$2700
            mem(16#3002#/2) := x"2700";

            -- ============================================================
            -- TRAP #0 handler at $4000
            -- Reads back ISP/MSP/USP and stores them, then STOP
            -- ============================================================
            idx := 16#4000#/2;
            -- MOVEC ISP,D3: $4E7A $3804
            mem(idx) := x"4E7A"; mem(idx+1) := x"3804";
            idx := idx + 2;
            -- MOVE.L D3, ($8010): $23C3 $0000 $8010
            mem(idx) := x"23C3"; mem(idx+1) := x"0000"; mem(idx+2) := x"8010";
            idx := idx + 3;
            -- MOVEC MSP,D4: $4E7A $4803
            mem(idx) := x"4E7A"; mem(idx+1) := x"4803";
            idx := idx + 2;
            -- MOVE.L D4, ($8014): $23C4 $0000 $8014
            mem(idx) := x"23C4"; mem(idx+1) := x"0000"; mem(idx+2) := x"8014";
            idx := idx + 3;
            -- MOVEC USP,D5: $4E7A $5800
            mem(idx) := x"4E7A"; mem(idx+1) := x"5800";
            idx := idx + 2;
            -- MOVE.L D5, ($8018): $23C5 $0000 $8018
            mem(idx) := x"23C5"; mem(idx+1) := x"0000"; mem(idx+2) := x"8018";
            idx := idx + 3;
            -- MOVE.L A7, ($801C): $23CF $0000 $801C
            mem(idx) := x"23CF"; mem(idx+1) := x"0000"; mem(idx+2) := x"801C";
            idx := idx + 3;
            -- STOP #$2700
            mem(idx) := x"4E72"; mem(idx+1) := x"2700";
        end procedure;

    begin
        report "==========================================================";
        report "Comprehensive Odd-Address Branch & ISP/MSP Integrity Test";
        report "==========================================================";
        report "";

        -- ============================================================
        -- PART A: Odd-Address Branch Tests (Supervisor M=0)
        -- Each test attempts a branch to an odd address and checks
        -- whether an address error exception (vector 3) fires.
        -- MC68030 spec: instruction fetch at odd address = address error
        -- ============================================================

        -- ============================================================
        -- Test A1: JMP (xxx).L to odd address
        -- ============================================================
        report "--- Test A1: JMP to odd address ---";
        init_memory;

        -- Program at $1000
        idx := 16#1000#/2;
        -- JMP $00002001: $4EF9 $0000 $2001
        mem(idx) := x"4EF9"; mem(idx+1) := x"0000"; mem(idx+2) := x"2001";
        idx := idx + 3;
        -- Sentinel after JMP (should not be reached)
        -- NOP at $1006
        mem(idx) := x"4E71";

        -- Put a NOP at $2000 (even version of odd target) to detect non-exception
        mem(16#2000#/2) := x"4E71";
        -- STOP at $2002
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A1: JMP to odd address");
        wait_cycles(20);

        -- ============================================================
        -- Test A2: JSR (xxx).L to odd address
        -- ============================================================
        report "--- Test A2: JSR to odd address ---";
        init_memory;

        idx := 16#1000#/2;
        -- JSR $00002001: $4EB9 $0000 $2001
        mem(idx) := x"4EB9"; mem(idx+1) := x"0000"; mem(idx+2) := x"2001";
        idx := idx + 3;
        mem(idx) := x"4E71";  -- sentinel at $1006

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A2: JSR to odd address");
        wait_cycles(20);

        -- ============================================================
        -- Test A3: BRA.W to odd address
        -- BRA.W: $6000 $displacement (displacement from PC+2)
        -- PC at $1000, target = $2001, disp = $2001 - ($1000+2) = $0FFF
        -- ============================================================
        report "--- Test A3: BRA.W to odd address ---";
        init_memory;

        idx := 16#1000#/2;
        -- BRA.W $0FFF: $6000 $0FFF -> target = $1002 + $0FFF = $2001
        mem(idx) := x"6000"; mem(idx+1) := x"0FFF";
        idx := idx + 2;
        mem(idx) := x"4E71";  -- sentinel at $1004

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A3: BRA.W to odd address");
        wait_cycles(20);

        -- ============================================================
        -- Test A4: BSR.W to odd address
        -- BSR.W: $6100 $displacement
        -- PC at $1000, target = $2001, disp = $2001 - ($1000+2) = $0FFF
        -- ============================================================
        report "--- Test A4: BSR.W to odd address ---";
        init_memory;

        idx := 16#1000#/2;
        -- BSR.W $0FFF: $6100 $0FFF -> target = $1002 + $0FFF = $2001
        mem(idx) := x"6100"; mem(idx+1) := x"0FFF";
        idx := idx + 2;
        mem(idx) := x"4E71";  -- sentinel at $1004

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A4: BSR.W to odd address");
        wait_cycles(20);

        -- ============================================================
        -- Test A5: BCC.W (BEQ) to odd address, condition TRUE
        -- Set Z flag first via CMP, then BEQ
        -- ============================================================
        report "--- Test A5: BEQ.W to odd address (condition true) ---";
        init_memory;

        idx := 16#1000#/2;
        -- MOVEQ #0,D0: $7000 (sets Z flag)
        mem(idx) := x"7000";
        idx := idx + 1;
        -- TST.L D0: $4A80 (explicitly sets Z)
        mem(idx) := x"4A80";
        idx := idx + 1;
        -- BEQ.W displacement: $6700 $disp
        -- PC at $1004, target $2001, disp = $2001 - ($1004+2) = $0FFB
        mem(idx) := x"6700"; mem(idx+1) := x"0FFB";
        idx := idx + 2;
        -- Sentinel at $1008 (should not be reached if branch taken)
        mem(idx) := x"4E72"; mem(idx+1) := x"2700";  -- STOP

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A5: BEQ.W to odd address (Z=1)");
        wait_cycles(20);

        -- ============================================================
        -- Test A6: DBCC (DBF D0) to odd address
        -- DBF always decrements and branches until D0.W = -1
        -- ============================================================
        report "--- Test A6: DBF to odd address ---";
        init_memory;

        idx := 16#1000#/2;
        -- MOVEQ #1,D0: $7001 (D0=1, so DBF will branch once)
        mem(idx) := x"7001";
        idx := idx + 1;
        -- DBF D0, displacement: $51C8 $disp
        -- PC at $1002, disp = $2001 - ($1002+2) = $0FFD
        mem(idx) := x"51C8"; mem(idx+1) := x"0FFD";
        idx := idx + 2;
        -- Sentinel at $1006 (reached when D0.W=-1)
        mem(idx) := x"4E72"; mem(idx+1) := x"2700";

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A6: DBF to odd address");
        wait_cycles(20);

        -- ============================================================
        -- Test A7: RTS with odd return address on stack
        -- Push odd PC onto stack, then RTS
        -- ============================================================
        report "--- Test A7: RTS with odd return address ---";
        init_memory;

        idx := 16#1000#/2;
        -- Move stack down to make room: SUBA.L #8,A7 not needed, just push
        -- PEA $2001: push long $00002001 onto stack
        -- PEA (xxx).L: $4879 $0000 $2001
        mem(idx) := x"4879"; mem(idx+1) := x"0000"; mem(idx+2) := x"2001";
        idx := idx + 3;
        -- RTS: $4E75
        mem(idx) := x"4E75";
        idx := idx + 1;
        -- Sentinel at $1008
        mem(idx) := x"4E71";

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A7: RTS with odd return address");
        wait_cycles(20);

        -- ============================================================
        -- Test A8: RTR with odd return address on stack
        -- RTR pops CCR then PC
        -- ============================================================
        report "--- Test A8: RTR with odd return address ---";
        init_memory;

        idx := 16#1000#/2;
        -- Build stack frame for RTR: CCR(word) + PC(long)
        -- MOVEA.L #$07F4,A7: set SP to frame base
        -- Frame: $07F4=CCR, $07F6=PC_hi, $07F8=PC_lo
        mem(idx) := x"2E7C"; mem(idx+1) := x"0000"; mem(idx+2) := x"07F4";
        idx := idx + 3;  -- $1006
        -- Store CCR word at $07F4
        -- MOVE.W #$0000, ($07F4): $31FC $0000 $07F4
        mem(idx) := x"31FC"; mem(idx+1) := x"0000"; mem(idx+2) := x"07F4";
        idx := idx + 3;  -- $100C
        -- Store PC high at $07F6
        mem(idx) := x"31FC"; mem(idx+1) := x"0000"; mem(idx+2) := x"07F6";
        idx := idx + 3;  -- $1012
        -- Store PC low at $07F8: $2001 (odd!)
        mem(idx) := x"31FC"; mem(idx+1) := x"2001"; mem(idx+2) := x"07F8";
        idx := idx + 3;  -- $1018
        -- Restore SP to frame base
        mem(idx) := x"2E7C"; mem(idx+1) := x"0000"; mem(idx+2) := x"07F4";
        idx := idx + 3;  -- $101E
        -- RTR: $4E77
        mem(idx) := x"4E77";
        idx := idx + 1;

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A8: RTR with odd return address");
        wait_cycles(20);

        -- ============================================================
        -- Test A9: RTE with odd return address in stack frame
        -- Build Format $0 frame with odd PC on stack, then RTE
        -- ============================================================
        report "--- Test A9: RTE with odd return address ---";
        init_memory;

        idx := 16#1000#/2;
        -- Set SP to frame: frame is 8 bytes (4 words): SR, PC_hi, PC_lo, fmt/vec
        -- Frame base at $07F0
        mem(idx) := x"2E7C"; mem(idx+1) := x"0000"; mem(idx+2) := x"07F0";
        idx := idx + 3;  -- $1006
        -- Build frame at $07F0:
        -- $07F0: SR = $2700 (supervisor, no interrupts)
        mem(16#07F0#/2) := x"2700";
        -- $07F2: PC high = $0000
        mem(16#07F2#/2) := x"0000";
        -- $07F4: PC low = $2001 (odd!)
        mem(16#07F4#/2) := x"2001";
        -- $07F6: format/vector = $0000 (Format $0, vector 0)
        mem(16#07F6#/2) := x"0000";
        -- Restore SP
        mem(idx) := x"2E7C"; mem(idx+1) := x"0000"; mem(idx+2) := x"07F0";
        idx := idx + 3;  -- $100C
        -- RTE: $4E73
        mem(idx) := x"4E73";
        idx := idx + 1;

        mem(16#2000#/2) := x"4E71";
        mem(16#2002#/2) := x"4E72";
        mem(16#2004#/2) := x"2700";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_exception_or_sentinel(16#2002#, 5000);
        check_addr_error("A9: RTE with odd return address");
        wait_cycles(20);

        -- ============================================================
        -- PART B: ISP/MSP Integrity During Mode Transitions
        -- These tests verify that ISP and MSP are not corrupted
        -- when transitioning between supervisor and user mode.
        --
        -- Key design: pre-place RTE frames at natural stack positions
        -- (where A7 already points) to avoid MOVEA.L changing ISP/MSP.
        -- ============================================================
        report "";
        report "==========================================================";
        report "PART B: ISP/MSP Integrity During Mode Transitions";
        report "==========================================================";

        -- ============================================================
        -- Test B1: RTE supervisor(M=0) -> user -> TRAP back
        -- After reset: ISP=A7=$0800
        -- Set MSP=$0A00, USP=$0C00 via MOVEC
        -- Pre-place RTE frame at $0800 (where A7 already points)
        -- RTE pops frame -> ISP=$0808, changeMode saves ISP, loads USP
        -- User TRAP #0 -> supervisor, pushes to ISP -> ISP=$0800
        -- ============================================================
        report "--- Test B1: RTE S(M=0)->U->S round trip ---";
        init_memory;

        -- Pre-place RTE frame at $0800 (reset SSP)
        -- MC68030 frame: SR, PC_hi, PC_lo, format/vector
        mem(16#0800#/2) := x"0000";  -- SR: user mode (S=0)
        mem(16#0802#/2) := x"0000";  -- PC high
        mem(16#0804#/2) := x"2000";  -- PC low: user code at $2000
        mem(16#0806#/2) := x"0000";  -- Format $0

        -- User code at $2000: TRAP #0
        mem(16#2000#/2) := x"4E40";

        -- Supervisor code at $1000: set MSP and USP, then RTE
        idx := 16#1000#/2;
        -- MOVE.L #$0A00,D1 / MOVEC D1,MSP
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0A00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1803";
        idx := idx + 2;
        -- MOVE.L #$0C00,D1 / MOVEC D1,USP
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0C00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1800";
        idx := idx + 2;
        -- RTE: A7=$0800 points to our pre-placed frame
        mem(idx) := x"4E73";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        -- Wait for TRAP handler at $4000
        wait_for_addr(16#4000#, "B1: TRAP handler");
        wait_cycles(200);

        -- After RTE: ISP advanced from $0800 to $0808 (8-byte frame consumed)
        -- changeMode (S->U): saves ISP=$0808
        -- TRAP from user: changeMode (U->S): loads ISP=$0808, pushes 8-byte frame
        -- ISP = $0808 - 8 = $0800
        check_mem32("B1: ISP after S->U->S ($0800)", 16#8010#, x"00000800");
        check_mem32("B1: MSP preserved ($0A00)", 16#8014#, x"00000A00");
        check_mem32("B1: USP preserved ($0C00)", 16#8018#, x"00000C00");
        wait_cycles(20);

        -- ============================================================
        -- Test B2: RTE supervisor(M=1) -> user -> TRAP back
        -- After reset: ISP=A7=$0800
        -- Set MSP=$0A00. MOVE #$3000,SR swaps A7 to MSP=$0A00
        -- Pre-place RTE frame at $0A00 (MSP)
        -- RTE restores SR=$0000 (user mode), deferred swap
        -- User TRAP #0 -> supervisor M=0 -> ISP
        -- ============================================================
        report "--- Test B2: RTE S(M=1)->U->S round trip ---";
        init_memory;

        -- Pre-place RTE frame at $0A00 (where MSP will be)
        mem(16#0A00#/2) := x"0000";  -- SR: user mode
        mem(16#0A02#/2) := x"0000";  -- PC high
        mem(16#0A04#/2) := x"2000";  -- PC low: user code
        mem(16#0A06#/2) := x"0000";  -- Format $0

        mem(16#2000#/2) := x"4E40";  -- TRAP #0

        idx := 16#1000#/2;
        -- Set MSP=$0A00
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0A00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1803";
        idx := idx + 2;
        -- Set USP=$0C00
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0C00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1800";
        idx := idx + 2;
        -- MOVE #$3000,SR -> M=1, swaps A7 from ISP($0800) to MSP($0A00)
        mem(idx) := x"46FC"; mem(idx+1) := x"3000";
        idx := idx + 2;
        -- RTE: A7=MSP=$0A00 points to our frame
        mem(idx) := x"4E73";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_addr(16#4000#, "B2: TRAP handler");
        wait_cycles(200);

        -- After TRAP from user: supervisor M=0, A7=ISP
        -- ISP was $0800 before the M=1 switch, should be restored
        -- TRAP pushes 8-byte frame to ISP -> ISP = $0800 - 8 = $07F8
        check_mem32("B2: ISP after S(M=1)->U->S ($07F8)", 16#8010#, x"000007F8");
        check_mem32("B2: MSP preserved", 16#8014#, x"00000A08");
        check_mem32("B2: USP preserved ($0C00)", 16#8018#, x"00000C00");
        wait_cycles(20);

        -- ============================================================
        -- Test B3: MOVE to SR: S=1,M=1 -> S=0 (user mode)
        -- Verify ISP not corrupted when M-bit change happens
        -- simultaneously with S-bit change to user mode
        -- ============================================================
        report "--- Test B3: MOVE to SR S=1,M=1 -> S=0 ---";
        init_memory;

        mem(16#2000#/2) := x"4E40";  -- TRAP #0 (user code)

        idx := 16#1000#/2;
        -- Set MSP=$0A00
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0A00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1803";
        idx := idx + 2;
        -- Set USP=$0C00
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0C00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1800";
        idx := idx + 2;
        -- Switch to M=1: MOVE #$3000,SR
        mem(idx) := x"46FC"; mem(idx+1) := x"3000";
        idx := idx + 2;
        -- Now A7=MSP=$0A00
        -- Switch to user mode: MOVE #$0000,SR
        -- changeMode saves MSP, loads USP. M-bit swap should NOT fire.
        mem(idx) := x"46FC"; mem(idx+1) := x"0000";
        idx := idx + 2;
        -- Now in user mode, next instruction at PC+4 from MOVE to SR
        -- But after MOVE to SR with S=0, we need valid user code here
        -- The next instruction fetch will be from the current PC
        -- Actually, MOVE #imm,SR is at idx-2, so PC is now at idx*2
        -- We need user code right here:
        mem(idx) := x"4E40";  -- TRAP #0
        idx := idx + 1;

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_addr(16#4000#, "B3: TRAP handler");
        wait_cycles(200);

        -- After TRAP: supervisor M=0, A7=ISP
        -- ISP was $0800, TRAP pushes 8 bytes -> $07F8
        check_mem32("B3: ISP after S(M=1)->U->S ($07F8)", 16#8010#, x"000007F8");
        check_mem32("B3: MSP preserved ($0A00)", 16#8014#, x"00000A00");
        check_mem32("B3: USP preserved ($0C00)", 16#8018#, x"00000C00");
        wait_cycles(20);

        -- ============================================================
        -- Test B4: RTE Format $1 dual-frame M=1 -> M=0
        -- BUG #411 scenario: first frame has M=1, second has M=0
        -- format1_chain_active prevents premature ISP/MSP swap
        -- ============================================================
        report "--- Test B4: RTE Format $1 dual-frame M=1 -> M=0 ---";
        init_memory;

        -- Pre-place dual frame at $0800 (ISP)
        -- First frame (Format $1, throwaway):
        mem(16#0800#/2) := x"3000";  -- SR: S=1, M=1
        mem(16#0802#/2) := x"0000";
        mem(16#0804#/2) := x"FFFE";  -- PC (throwaway)
        mem(16#0806#/2) := x"1000";  -- Format $1

        -- Second frame (Format $0, real return) at MSP ($0A00):
        -- Format $1 with M=1 swaps A7 from ISP to MSP, so Frame 2 is read from MSP
        mem(16#0A00#/2) := x"2700";  -- SR: S=1, M=0
        mem(16#0A02#/2) := x"0000";
        mem(16#0A04#/2) := x"2000";  -- PC: $2000
        mem(16#0A06#/2) := x"0000";  -- Format $0

        -- Code at $2000: read ISP/MSP and store, then STOP
        idx := 16#2000#/2;
        mem(idx) := x"4E7A"; mem(idx+1) := x"3804";  -- MOVEC ISP,D3
        idx := idx + 2;
        mem(idx) := x"23C3"; mem(idx+1) := x"0000"; mem(idx+2) := x"8010";
        idx := idx + 3;
        mem(idx) := x"4E7A"; mem(idx+1) := x"4803";  -- MOVEC MSP,D4
        idx := idx + 2;
        mem(idx) := x"23C4"; mem(idx+1) := x"0000"; mem(idx+2) := x"8014";
        idx := idx + 3;
        mem(idx) := x"23CF"; mem(idx+1) := x"0000"; mem(idx+2) := x"801C";  -- MOVE.L A7,($801C)
        idx := idx + 3;
        mem(idx) := x"4E72"; mem(idx+1) := x"2700";  -- STOP

        -- Supervisor code at $1000: set MSP, then RTE
        idx := 16#1000#/2;
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0A00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1803";  -- MOVEC D1,MSP
        idx := idx + 2;
        -- A7=ISP=$0800, frame is there. RTE.
        mem(idx) := x"4E73";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_addr(16#2000#, "B4: RTE return address");
        wait_cycles(200);

        -- After dual-frame RTE:
        -- ISP consumed Frame 1 (8 bytes from $0800): ISP=$0808
        -- MSP consumed Frame 2 (8 bytes from $0A00): MSP=$0A08
        -- Deferred M-bit swap (M:1->0): A7 swaps from MSP back to ISP
        -- Final: A7=ISP=$0808
        check_mem32("B4: ISP after dual-frame ($0808)", 16#8010#, x"00000808");
        check_mem32("B4: MSP after dual-frame ($0A08)", 16#8014#, x"00000A08");
        check_mem32("B4: A7=ISP ($0808)", 16#801C#, x"00000808");
        wait_cycles(20);

        -- ============================================================
        -- Test B5: RTE to user mode with M=1 in restored SR
        -- M bit is meaningless in user mode - should not cause ISP/MSP swap
        -- ============================================================
        report "--- Test B5: RTE to user mode with M=1 in SR ---";
        init_memory;

        -- Frame at $0800: SR has S=0, M=1 (user mode, M meaningless)
        mem(16#0800#/2) := x"1000";  -- SR: S=0, M=1
        mem(16#0802#/2) := x"0000";
        mem(16#0804#/2) := x"2000";  -- PC: $2000
        mem(16#0806#/2) := x"0000";  -- Format $0

        mem(16#2000#/2) := x"4E40";  -- TRAP #0

        idx := 16#1000#/2;
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0A00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1803";  -- MSP=$0A00
        idx := idx + 2;
        mem(idx) := x"223C"; mem(idx+1) := x"0000"; mem(idx+2) := x"0C00";
        idx := idx + 3;
        mem(idx) := x"4E7B"; mem(idx+1) := x"1800";  -- USP=$0C00
        idx := idx + 2;
        -- A7=ISP=$0800, frame is there. RTE.
        mem(idx) := x"4E73";

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        wait_for_addr(16#4000#, "B5: TRAP handler");
        wait_cycles(200);

        -- RTE pops 8 bytes: ISP=$0808, S->U changeMode saves ISP=$0808
        -- User SR has M=1. Per MC68030 spec, TRAP preserves M bit.
        -- TRAP U->S: M=1 -> loads MSP($0A00), pushes 8 bytes -> MSP=$09F8
        -- ISP stays in shadow at $0808 (TRAP used MSP, not ISP)
        check_mem32("B5: ISP saved during S->U ($0808)", 16#8010#, x"00000808");
        check_mem32("B5: MSP after TRAP frame push ($09F8)", 16#8014#, x"000009F8");
        check_mem32("B5: USP preserved ($0C00)", 16#8018#, x"00000C00");
        wait_cycles(20);

        -- ============================================================
        -- Summary
        -- ============================================================
        report "";
        report "==========================================================";
        report "TEST SUMMARY";
        report "==========================================================";
        wait_cycles(5);
        report "  PASSED: " & integer'image(test_passed);
        report "  FAILED: " & integer'image(test_failed);
        report "  TOTAL:  " & integer'image(test_passed + test_failed);
        if test_failed = 0 then
            report "  *** ALL TESTS PASSED ***" severity note;
        else
            report "  *** SOME TESTS FAILED ***" severity error;
        end if;
        report "==========================================================";

        test_done <= true;
        wait;
    end process;

end architecture;
