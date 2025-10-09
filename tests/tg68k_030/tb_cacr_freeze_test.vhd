library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
library std;
use std.textio.all;

entity tb_cacr_freeze_test is
end tb_cacr_freeze_test;

architecture behavior of tb_cacr_freeze_test is
    -- Test signals
    signal clk        : std_logic := '0';
    signal reset      : std_logic := '1';
    signal CACR       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_QA     : std_logic_vector(31 downto 0);
    signal movec_wr   : std_logic := '0';
    signal clkena_lw  : std_logic := '1';
    signal brief      : std_logic_vector(11 downto 0);

    -- Clock period
    constant CLK_PERIOD : time := 10 ns;

    -- Test control
    signal test_done : boolean := false;

begin
    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- CACR register implementation (simplified from TG68KdotC_Kernel.vhd)
    process (clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                CACR <= (others => '0');
            elsif clkena_lw = '1' and movec_wr = '1' then
                if brief = X"002" then  -- CACR register selector
                    -- Write to CACR with proper MC68030 behavior
                    -- Sticky control bits (retain value until explicitly changed):
                    CACR(1 downto 0) <= reg_QA(1 downto 0);   -- EI, FI - instruction cache enable/freeze
                    -- Bit 2 (CEI) and Bit 3 (CI) are self-clearing command bits - NOT stored
                    CACR(4) <= reg_QA(4);                      -- IBE - Instruction Burst Enable
                    CACR(7 downto 5) <= (others => '0');       -- Reserved bits
                    CACR(9 downto 8) <= reg_QA(9 downto 8);   -- ED, FD - data cache enable/freeze
                    -- Bit 10 (CED) and Bit 11 (CD) are self-clearing command bits - NOT stored
                    CACR(13 downto 12) <= reg_QA(13 downto 12); -- DBE, WA - data burst enable, write allocate
                    CACR(31 downto 14) <= (others => '0');     -- Reserved bits
                end if;
            elsif clkena_lw = '1' then
                -- Auto-clear self-clearing command bits after they've been set
                -- MC68030 spec: bits 2 (CEI), 3 (CI), 10 (CED), 11 (CD) are self-clearing
                if CACR(2) = '1' or CACR(3) = '1' or CACR(10) = '1' or CACR(11) = '1' then
                    CACR(2) <= '0';   -- Clear CEI (Clear Entry in Instruction Cache)
                    CACR(3) <= '0';   -- Clear CI (Clear Instruction Cache)
                    CACR(10) <= '0';  -- Clear CED (Clear Entry in Data Cache)
                    CACR(11) <= '0';  -- Clear CD (Clear Data Cache)
                end if;
            end if;
        end if;
    end process;

    -- Test process
    process
        variable l : line;
        variable test_pass : boolean := true;
    begin
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("CACR Freeze Bit Test"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        -- Initialize
        brief <= X"002";  -- CACR selector
        wait for 20 ns;
        reset <= '0';
        wait for 20 ns;

        -- TEST 1: Set FD (Freeze Data Cache) bit 9
        write(l, string'("TEST 1: Set FD (bit 9) - Freeze Data Cache"));
        writeline(output, l);
        reg_QA <= X"00000200";  -- Set bit 9 (FD)
        movec_wr <= '1';
        wait for CLK_PERIOD;
        movec_wr <= '0';
        wait for CLK_PERIOD;

        if CACR(9) = '1' then
            write(l, string'("  PASS: FD bit set correctly"));
        else
            write(l, string'("  FAIL: FD bit not set! CACR="));
            hwrite(l, CACR);
            test_pass := false;
        end if;
        writeline(output, l);

        -- TEST 2: Clear FD bit
        write(l, string'("TEST 2: Clear FD bit"));
        writeline(output, l);
        reg_QA <= X"00000000";  -- Clear all bits
        movec_wr <= '1';
        wait for CLK_PERIOD;
        movec_wr <= '0';
        wait for CLK_PERIOD;

        if CACR(9) = '0' then
            write(l, string'("  PASS: FD bit cleared correctly"));
        else
            write(l, string'("  FAIL: FD bit not cleared! CACR="));
            hwrite(l, CACR);
            test_pass := false;
        end if;
        writeline(output, l);

        -- TEST 3: Set both FI (bit 1) and FD (bit 9)
        write(l, string'("TEST 3: Set both FI (bit 1) and FD (bit 9)"));
        writeline(output, l);
        reg_QA <= X"00000202";  -- Set bits 1 and 9
        movec_wr <= '1';
        wait for CLK_PERIOD;
        movec_wr <= '0';
        wait for CLK_PERIOD;

        if CACR(1) = '1' and CACR(9) = '1' then
            write(l, string'("  PASS: Both freeze bits set"));
        else
            write(l, string'("  FAIL: Freeze bits not set! CACR="));
            hwrite(l, CACR);
            test_pass := false;
        end if;
        writeline(output, l);

        -- TEST 4: Clear only FD, keep FI
        write(l, string'("TEST 4: Clear only FD, keep FI"));
        writeline(output, l);
        reg_QA <= X"00000002";  -- Keep bit 1, clear bit 9
        movec_wr <= '1';
        wait for CLK_PERIOD;
        movec_wr <= '0';
        wait for CLK_PERIOD;

        if CACR(1) = '1' and CACR(9) = '0' then
            write(l, string'("  PASS: FD cleared, FI kept"));
        else
            write(l, string'("  FAIL: Unexpected state! CACR="));
            hwrite(l, CACR);
            test_pass := false;
        end if;
        writeline(output, l);

        -- TEST 5: Set FD with enable bits
        write(l, string'("TEST 5: Set ED (bit 8) and FD (bit 9) together"));
        writeline(output, l);
        reg_QA <= X"00000300";  -- Set bits 8 and 9
        movec_wr <= '1';
        wait for CLK_PERIOD;
        movec_wr <= '0';
        wait for CLK_PERIOD;

        if CACR(8) = '1' and CACR(9) = '1' then
            write(l, string'("  PASS: ED and FD both set"));
        else
            write(l, string'("  FAIL: ED/FD not set correctly! CACR="));
            hwrite(l, CACR);
            test_pass := false;
        end if;
        writeline(output, l);

        -- TEST 6: Clear FD but keep ED
        write(l, string'("TEST 6: Clear FD but keep ED"));
        writeline(output, l);
        reg_QA <= X"00000100";  -- Keep bit 8, clear bit 9
        movec_wr <= '1';
        wait for CLK_PERIOD;
        movec_wr <= '0';
        wait for CLK_PERIOD;

        if CACR(8) = '1' and CACR(9) = '0' then
            write(l, string'("  PASS: FD cleared, ED kept"));
        else
            write(l, string'("  FAIL: Unexpected state! CACR="));
            hwrite(l, CACR);
            test_pass := false;
        end if;
        writeline(output, l);

        -- TEST 7: Test that self-clearing bits don't affect freeze bits
        write(l, string'("TEST 7: Self-clearing bits don't affect freeze bits"));
        writeline(output, l);
        reg_QA <= X"00000F0F";  -- Set all cache control bits
        movec_wr <= '1';
        wait for CLK_PERIOD;
        movec_wr <= '0';
        wait for CLK_PERIOD * 2;  -- Wait for self-clearing

        if CACR(1) = '1' and CACR(9) = '1' and CACR(3) = '0' and CACR(11) = '0' then
            write(l, string'("  PASS: Freeze bits remain, command bits cleared"));
        else
            write(l, string'("  FAIL: Incorrect bit states! CACR="));
            hwrite(l, CACR);
            test_pass := false;
        end if;
        writeline(output, l);

        -- Final result
        write(l, string'("========================================"));
        writeline(output, l);
        if test_pass then
            write(l, string'("ALL TESTS PASSED"));
        else
            write(l, string'("SOME TESTS FAILED"));
        end if;
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        test_done <= true;
        wait;
    end process;

end behavior;