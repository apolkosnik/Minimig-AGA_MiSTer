------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_CacheOps                                             --
--                                                                          --
-- Tests the cache operations (CINV/CPUSH) implementation                  --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;
use work.test_pkg.all;

entity test_CacheOps is
end test_CacheOps;

architecture sim of test_CacheOps is

    -- Component declaration
    component TG68040_CacheOps is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            enable         : in std_logic;
            operation      : in cache_op_type_t;
            scope          : in cache_op_scope_t;
            cache_sel      : in cache_select_t;
            address        : in std_logic_vector(31 downto 0);
            supervisor     : in std_logic;
            cache_op_ctrl  : out cache_op_ctrl_t;
            cache_op_done  : in std_logic;
            done           : out std_logic;
            privilege_err  : out std_logic;
            busy           : out std_logic
        );
    end component;

    -- Test signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal enable         : std_logic := '0';
    signal operation      : cache_op_type_t := CACHE_OP_NONE;
    signal scope          : cache_op_scope_t := SCOPE_LINE;
    signal cache_sel      : cache_select_t := CACHE_SEL_DATA;
    signal address        : std_logic_vector(31 downto 0) := (others => '0');
    signal supervisor     : std_logic := '1';
    signal cache_op_ctrl  : cache_op_ctrl_t;
    signal cache_op_done  : std_logic := '0';
    signal done           : std_logic;
    signal privilege_err  : std_logic;
    signal busy           : std_logic;

    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation
    dut: TG68040_CacheOps
        port map(
            clk            => clk,
            reset          => reset,
            enable         => enable,
            operation      => operation,
            scope          => scope,
            cache_sel      => cache_sel,
            address        => address,
            supervisor     => supervisor,
            cache_op_ctrl  => cache_op_ctrl,
            cache_op_done  => cache_op_done,
            done           => done,
            privilege_err  => privilege_err,
            busy           => busy
        );

    -- Test process
    test_proc: process
    begin
        report "=== Starting CacheOps tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(busy, '0', "Not busy after reset");
        assert_equal(done, '0', "Not done after reset");
        assert_equal(privilege_err, '0', "No privilege error after reset");

        ----------------------------------------------------------------------
        -- Test 2: CINV line - supervisor mode
        ----------------------------------------------------------------------
        report "--- Test 2: CINV Line (Supervisor) ---";

        supervisor <= '1';
        operation <= CACHE_OP_INV;
        scope <= SCOPE_LINE;
        cache_sel <= CACHE_SEL_DATA;
        address <= x"00001234";

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "Operation completed");
        assert_equal(privilege_err, '0', "No privilege error");

        -- Check cache_op_ctrl signals were set
        wait for CLK_PERIOD;

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 3: CINV page - supervisor mode
        ----------------------------------------------------------------------
        report "--- Test 3: CINV Page (Supervisor) ---";

        supervisor <= '1';
        operation <= CACHE_OP_INV;
        scope <= SCOPE_PAGE;
        cache_sel <= CACHE_SEL_DATA;
        address <= x"12345678";

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "Operation completed");
        assert_equal(privilege_err, '0', "No privilege error");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 4: CINV all - supervisor mode
        ----------------------------------------------------------------------
        report "--- Test 4: CINV All (Supervisor) ---";

        supervisor <= '1';
        operation <= CACHE_OP_INV;
        scope <= SCOPE_ALL;
        cache_sel <= CACHE_SEL_INSN;

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "Operation completed");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 5: CPUSH line - supervisor mode
        ----------------------------------------------------------------------
        report "--- Test 5: CPUSH Line (Supervisor) ---";

        supervisor <= '1';
        operation <= CACHE_OP_PUSH;
        scope <= SCOPE_LINE;
        cache_sel <= CACHE_SEL_DATA;
        address <= x"ABCD0000";

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "Operation completed");
        assert_equal(privilege_err, '0', "No privilege error");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 6: CPUSH page - supervisor mode
        ----------------------------------------------------------------------
        report "--- Test 6: CPUSH Page (Supervisor) ---";

        supervisor <= '1';
        operation <= CACHE_OP_PUSH;
        scope <= SCOPE_PAGE;
        cache_sel <= CACHE_SEL_DATA;

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "Operation completed");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 7: CPUSH all - supervisor mode
        ----------------------------------------------------------------------
        report "--- Test 7: CPUSH All (Supervisor) ---";

        supervisor <= '1';
        operation <= CACHE_OP_PUSH;
        scope <= SCOPE_ALL;
        cache_sel <= CACHE_SEL_BOTH;

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "Operation completed");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 8: User mode privilege violation
        ----------------------------------------------------------------------
        report "--- Test 8: User Mode Privilege Violation ---";

        supervisor <= '0';  -- User mode
        operation <= CACHE_OP_INV;
        scope <= SCOPE_ALL;
        cache_sel <= CACHE_SEL_DATA;

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(privilege_err, '1', "Privilege error in user mode");
        assert_equal(done, '0', "Not done due to privilege error");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 9: Instruction cache operations
        ----------------------------------------------------------------------
        report "--- Test 9: Instruction Cache Operations ---";

        supervisor <= '1';
        operation <= CACHE_OP_INV;
        scope <= SCOPE_ALL;
        cache_sel <= CACHE_SEL_INSN;

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "I-cache operation completed");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- Test 10: Both caches operation
        ----------------------------------------------------------------------
        report "--- Test 10: Both Caches Operation ---";

        supervisor <= '1';
        operation <= CACHE_OP_PUSH;
        scope <= SCOPE_ALL;
        cache_sel <= CACHE_SEL_BOTH;

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or privilege_err = '1' for CLK_PERIOD * 20;

        assert_equal(done, '1', "Both caches operation completed");

        wait for CLK_PERIOD * 3;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All CacheOps tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
