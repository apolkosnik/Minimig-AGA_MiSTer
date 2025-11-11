------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 RAS Unit Tests (Phase 8)                                        --
--                                                                          --
-- Tests for Return Address Stack functionality                            --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity test_RAS is
end test_RAS;

architecture test of test_RAS is

    -- Component under test
    component TG68040_RAS is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            push_en        : in std_logic;
            push_addr      : in std_logic_vector(31 downto 0);
            pop_en         : in std_logic;
            pop_addr       : out std_logic_vector(31 downto 0);
            pop_valid      : out std_logic;
            repair_en      : in std_logic;
            repair_tos     : in integer range 0 to 7;
            pushes         : out std_logic_vector(31 downto 0);
            pops           : out std_logic_vector(31 downto 0);
            overflows      : out std_logic_vector(31 downto 0);
            underflows     : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Signals
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal push_en : std_logic;
    signal push_addr : std_logic_vector(31 downto 0);
    signal pop_en : std_logic;
    signal pop_addr : std_logic_vector(31 downto 0);
    signal pop_valid : std_logic;
    signal repair_en : std_logic;
    signal repair_tos : integer range 0 to 7;
    signal pushes : std_logic_vector(31 downto 0);
    signal pops : std_logic_vector(31 downto 0);
    signal overflows : std_logic_vector(31 downto 0);
    signal underflows : std_logic_vector(31 downto 0);

    -- Test control
    signal test_done : boolean := false;
    constant CLK_PERIOD : time := 10 ns;

begin

    -- Clock generation
    clk_process: process
    begin
        while not test_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- DUT instantiation
    dut: TG68040_RAS
        port map(
            clk        => clk,
            reset      => reset,
            push_en    => push_en,
            push_addr  => push_addr,
            pop_en     => pop_en,
            pop_addr   => pop_addr,
            pop_valid  => pop_valid,
            repair_en  => repair_en,
            repair_tos => repair_tos,
            pushes     => pushes,
            pops       => pops,
            overflows  => overflows,
            underflows => underflows
        );

    -- Test stimulus
    test_proc: process
    begin
        -- Test 1: Reset
        report "Test 1: Reset";
        reset <= '1';
        push_en <= '0';
        pop_en <= '0';
        repair_en <= '0';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;

        -- Test 2: Pop from empty stack (underflow)
        report "Test 2: Pop from empty stack";
        pop_en <= '1';
        wait for CLK_PERIOD;
        assert pop_valid = '0' report "Pop should fail on empty stack" severity error;
        assert unsigned(underflows) = 1 report "Underflow count should be 1" severity error;
        pop_en <= '0';
        wait for CLK_PERIOD;

        -- Test 3: Push single address
        report "Test 3: Push single address";
        push_en <= '1';
        push_addr <= x"00001000";
        wait for CLK_PERIOD;
        assert unsigned(pushes) = 1 report "Push count should be 1" severity error;
        push_en <= '0';
        wait for CLK_PERIOD;

        -- Test 4: Pop single address
        report "Test 4: Pop single address";
        pop_en <= '1';
        wait for CLK_PERIOD;
        assert pop_valid = '1' report "Pop should succeed" severity error;
        assert pop_addr = x"00001000" report "Wrong address popped" severity error;
        assert unsigned(pops) = 2 report "Pop count should be 2 (1 underflow + 1 success)" severity error;
        pop_en <= '0';
        wait for CLK_PERIOD;

        -- Test 5: Push multiple addresses
        report "Test 5: Push multiple addresses";
        for i in 0 to 4 loop
            push_en <= '1';
            push_addr <= std_logic_vector(to_unsigned(16#2000# + i * 4, 32));
            wait for CLK_PERIOD;
        end loop;
        push_en <= '0';
        wait for CLK_PERIOD;

        -- Test 6: Pop in LIFO order
        report "Test 6: Pop in LIFO order";
        for i in 4 downto 0 loop
            pop_en <= '1';
            wait for CLK_PERIOD;
            assert pop_valid = '1' report "Pop should succeed" severity error;
            assert pop_addr = std_logic_vector(to_unsigned(16#2000# + i * 4, 32))
                report "Wrong address popped: expected " &
                       integer'image(16#2000# + i * 4) &
                       " got " & integer'image(to_integer(unsigned(pop_addr))) severity error;
            pop_en <= '0';
            wait for CLK_PERIOD;
        end loop;

        -- Test 7: Fill stack completely (8 entries)
        report "Test 7: Fill stack completely";
        for i in 0 to 7 loop
            push_en <= '1';
            push_addr <= std_logic_vector(to_unsigned(16#3000# + i * 4, 32));
            wait for CLK_PERIOD;
        end loop;
        push_en <= '0';
        wait for CLK_PERIOD;

        -- Test 8: Overflow (push when full)
        report "Test 8: Push when full (overflow)";
        push_en <= '1';
        push_addr <= x"00009000";
        wait for CLK_PERIOD;
        assert unsigned(overflows) = 1 report "Overflow count should be 1" severity error;
        push_en <= '0';
        wait for CLK_PERIOD;

        -- Test 9: Verify stack contents after overflow
        report "Test 9: Verify stack after overflow (oldest should be gone)";
        -- After overflow, oldest entry (3000) should be replaced by newest (9000)
        -- Stack should have: 9000, 301C, 3018, 3014, 3010, 300C, 3008, 3004 (TOS)
        -- But entry 0 (3000) is overwritten
        for i in 1 to 7 loop
            pop_en <= '1';
            wait for CLK_PERIOD;
            assert pop_valid = '1' report "Pop should succeed" severity error;
            pop_en <= '0';
            wait for CLK_PERIOD;
        end loop;

        -- Test 10: Simultaneous push and pop (tail call optimization)
        report "Test 10: Simultaneous push and pop";
        -- First push something
        push_en <= '1';
        push_addr <= x"00005000";
        wait for CLK_PERIOD;
        push_en <= '0';
        wait for CLK_PERIOD;

        -- Now push and pop simultaneously
        push_en <= '1';
        pop_en <= '1';
        push_addr <= x"00006000";
        wait for CLK_PERIOD;
        assert pop_valid = '1' report "Pop should succeed on simultaneous" severity error;
        push_en <= '0';
        pop_en <= '0';
        wait for CLK_PERIOD;

        -- Test 11: Repair mechanism
        report "Test 11: Repair mechanism";
        -- Push a few addresses
        for i in 0 to 3 loop
            push_en <= '1';
            push_addr <= std_logic_vector(to_unsigned(16#7000# + i * 4, 32));
            wait for CLK_PERIOD;
        end loop;
        push_en <= '0';
        wait for CLK_PERIOD;

        -- Repair to specific TOS
        repair_en <= '1';
        repair_tos <= 2;
        wait for CLK_PERIOD;
        repair_en <= '0';
        wait for CLK_PERIOD;

        -- Verify TOS is now at position 2
        pop_en <= '1';
        wait for CLK_PERIOD;
        assert pop_valid = '1' report "Pop should succeed after repair" severity error;
        pop_en <= '0';
        wait for CLK_PERIOD;

        -- Test 12: Reset clears stack
        report "Test 12: Reset clears stack";
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;

        pop_en <= '1';
        wait for CLK_PERIOD;
        assert pop_valid = '0' report "Stack should be empty after reset" severity error;
        pop_en <= '0';
        wait for CLK_PERIOD;

        -- All tests complete
        report "All RAS tests passed!";
        test_done <= true;
        wait;
    end process;

end test;
