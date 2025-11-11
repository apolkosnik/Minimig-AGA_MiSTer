------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_HazardUnit                                           --
--                                                                          --
-- Tests the hazard detection and data forwarding logic                    --
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
use work.TG68040_Pipeline_Regs.all;
use work.test_pkg.all;

entity test_HazardUnit is
end test_HazardUnit;

architecture sim of test_HazardUnit is

    -- Component declaration
    component TG68040_HazardUnit is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            id_ea_valid    : in std_logic;
            id_ea_src_reg1 : in std_logic_vector(3 downto 0);
            id_ea_src_reg2 : in std_logic_vector(3 downto 0);
            id_ea_dst_reg  : in std_logic_vector(3 downto 0);
            id_ea_write    : in std_logic;
            ea_of_valid    : in std_logic;
            ea_of_dst_reg  : in std_logic_vector(3 downto 0);
            ea_of_write    : in std_logic;
            of_ex_valid    : in std_logic;
            of_ex_dst_reg  : in std_logic_vector(3 downto 0);
            of_ex_write    : in std_logic;
            ex_wb_valid    : in std_logic;
            ex_wb_dst_reg  : in std_logic_vector(3 downto 0);
            ex_wb_write    : in std_logic;
            hazard_info    : out hazard_info_t;
            stall_pipeline : out std_logic
        );
    end component;

    -- Test signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal id_ea_valid    : std_logic := '0';
    signal id_ea_src_reg1 : std_logic_vector(3 downto 0) := (others => '0');
    signal id_ea_src_reg2 : std_logic_vector(3 downto 0) := (others => '0');
    signal id_ea_dst_reg  : std_logic_vector(3 downto 0) := (others => '0');
    signal id_ea_write    : std_logic := '0';
    signal ea_of_valid    : std_logic := '0';
    signal ea_of_dst_reg  : std_logic_vector(3 downto 0) := (others => '0');
    signal ea_of_write    : std_logic := '0';
    signal of_ex_valid    : std_logic := '0';
    signal of_ex_dst_reg  : std_logic_vector(3 downto 0) := (others => '0');
    signal of_ex_write    : std_logic := '0';
    signal ex_wb_valid    : std_logic := '0';
    signal ex_wb_dst_reg  : std_logic_vector(3 downto 0) := (others => '0');
    signal ex_wb_write    : std_logic := '0';
    signal hazard_info    : hazard_info_t;
    signal stall_pipeline : std_logic;

    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation
    dut: TG68040_HazardUnit
        port map(
            clk            => clk,
            reset          => reset,
            id_ea_valid    => id_ea_valid,
            id_ea_src_reg1 => id_ea_src_reg1,
            id_ea_src_reg2 => id_ea_src_reg2,
            id_ea_dst_reg  => id_ea_dst_reg,
            id_ea_write    => id_ea_write,
            ea_of_valid    => ea_of_valid,
            ea_of_dst_reg  => ea_of_dst_reg,
            ea_of_write    => ea_of_write,
            of_ex_valid    => of_ex_valid,
            of_ex_dst_reg  => of_ex_dst_reg,
            of_ex_write    => of_ex_write,
            ex_wb_valid    => ex_wb_valid,
            ex_wb_dst_reg  => ex_wb_dst_reg,
            ex_wb_write    => ex_wb_write,
            hazard_info    => hazard_info,
            stall_pipeline => stall_pipeline
        );

    -- Test process
    test_proc: process
    begin
        report "=== Starting HazardUnit tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '0', "No RAW hazard after reset");
        assert_equal(hazard_info.waw_hazard, '0', "No WAW hazard after reset");
        assert_equal(hazard_info.war_hazard, '0', "No WAR hazard after reset");
        assert_equal(stall_pipeline, '0', "No stall after reset");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 2: No hazard (different registers)
        ----------------------------------------------------------------------
        report "--- Test 2: No Hazard (Different Registers) ---";

        -- ID stage reads D1, D2
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"1";  -- D1
        id_ea_src_reg2 <= x"2";  -- D2

        -- EX stage writes D0 (no conflict)
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"0";  -- D0
        of_ex_write <= '1';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '0', "No RAW hazard - different registers");
        assert_equal(hazard_info.forward_ex_a, '0', "No forwarding needed");
        assert_equal(hazard_info.forward_ex_b, '0', "No forwarding needed");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 3: RAW hazard with EX forwarding (operand A)
        ----------------------------------------------------------------------
        report "--- Test 3: RAW Hazard - EX Forwarding (Operand A) ---";

        -- ID stage reads D0 (will cause hazard)
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"0";  -- D0 (same as EX writes)
        id_ea_src_reg2 <= x"2";  -- D2

        -- EX stage writes D0 (conflict!)
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"0";  -- D0
        of_ex_write <= '1';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '1', "RAW hazard detected");
        assert_equal(hazard_info.forward_ex_a, '1', "Forward from EX to operand A");
        assert_equal(hazard_info.forward_ex_b, '0', "No forwarding for operand B");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 4: RAW hazard with EX forwarding (operand B)
        ----------------------------------------------------------------------
        report "--- Test 4: RAW Hazard - EX Forwarding (Operand B) ---";

        -- ID stage reads D3 in operand B
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"1";  -- D1
        id_ea_src_reg2 <= x"3";  -- D3 (will cause hazard)

        -- EX stage writes D3 (conflict!)
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"3";  -- D3
        of_ex_write <= '1';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '1', "RAW hazard detected");
        assert_equal(hazard_info.forward_ex_a, '0', "No forwarding for operand A");
        assert_equal(hazard_info.forward_ex_b, '1', "Forward from EX to operand B");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 5: RAW hazard with WB forwarding (operand A)
        ----------------------------------------------------------------------
        report "--- Test 5: RAW Hazard - WB Forwarding (Operand A) ---";

        -- ID stage reads D4
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"4";  -- D4
        id_ea_src_reg2 <= x"2";  -- D2

        -- EX stage idle
        of_ex_valid <= '0';
        of_ex_write <= '0';

        -- WB stage writes D4 (conflict!)
        ex_wb_valid <= '1';
        ex_wb_dst_reg <= x"4";  -- D4
        ex_wb_write <= '1';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '1', "RAW hazard detected");
        assert_equal(hazard_info.forward_wb_a, '1', "Forward from WB to operand A");
        assert_equal(hazard_info.forward_ex_a, '0', "No EX forwarding");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 6: RAW hazard with both operands (EX forwarding)
        ----------------------------------------------------------------------
        report "--- Test 6: RAW Hazard - Both Operands ---";

        -- ID stage reads D5 in both operands
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"5";  -- D5
        id_ea_src_reg2 <= x"5";  -- D5

        -- EX stage writes D5 (conflict on both!)
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"5";  -- D5
        of_ex_write <= '1';

        -- WB stage idle
        ex_wb_valid <= '0';
        ex_wb_write <= '0';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '1', "RAW hazard detected");
        assert_equal(hazard_info.forward_ex_a, '1', "Forward from EX to operand A");
        assert_equal(hazard_info.forward_ex_b, '1', "Forward from EX to operand B");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 7: Priority (EX over WB)
        ----------------------------------------------------------------------
        report "--- Test 7: Forwarding Priority (EX over WB) ---";

        -- ID stage reads D6
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"6";  -- D6
        id_ea_src_reg2 <= x"1";  -- D1

        -- Both EX and WB stages write D6 (EX should have priority)
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"6";  -- D6
        of_ex_write <= '1';

        ex_wb_valid <= '1';
        ex_wb_dst_reg <= x"6";  -- D6 (same register!)
        ex_wb_write <= '1';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '1', "RAW hazard detected");
        assert_equal(hazard_info.forward_ex_a, '1', "Forward from EX (priority)");
        assert_equal(hazard_info.forward_wb_a, '0', "No WB forwarding (EX has priority)");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 8: WAW hazard detection
        ----------------------------------------------------------------------
        report "--- Test 8: WAW Hazard Detection ---";

        -- ID stage will write D7
        id_ea_valid <= '1';
        id_ea_dst_reg <= x"7";  -- D7
        id_ea_write <= '1';

        -- EX stage also writes D7 (WAW hazard)
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"7";  -- D7
        of_ex_write <= '1';

        -- Clear sources to avoid RAW
        id_ea_src_reg1 <= x"0";
        id_ea_src_reg2 <= x"1";

        ex_wb_valid <= '0';
        ex_wb_write <= '0';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.waw_hazard, '1', "WAW hazard detected");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 9: Register 0 (should not cause hazards)
        ----------------------------------------------------------------------
        report "--- Test 9: Register 0 (No Hazard) ---";

        -- ID stage reads D0
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"0";  -- Register 0
        id_ea_src_reg2 <= x"0";  -- Register 0

        -- EX stage writes D0 (but R0 typically hardwired to 0 in some archs)
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"0";  -- Register 0
        of_ex_write <= '1';

        ex_wb_valid <= '0';
        ex_wb_write <= '0';

        wait for CLK_PERIOD * 2;

        -- For MC68040, D0 is a normal register, so this SHOULD cause hazard
        -- (unlike MIPS where R0 is hardwired to zero)
        assert_equal(hazard_info.raw_hazard, '1', "RAW hazard for D0");
        assert_equal(hazard_info.forward_ex_a, '1', "Forward D0 normally");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 10: Multiple stages with different registers
        ----------------------------------------------------------------------
        report "--- Test 10: Multiple Stages, Different Registers ---";

        -- ID stage reads D1, D2
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"1";  -- D1
        id_ea_src_reg2 <= x"2";  -- D2

        -- EX stage writes D3
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"3";  -- D3
        of_ex_write <= '1';

        -- WB stage writes D4
        ex_wb_valid <= '1';
        ex_wb_dst_reg <= x"4";  -- D4
        ex_wb_write <= '1';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '0', "No hazards with different registers");
        assert_equal(hazard_info.forward_ex_a, '0', "No forwarding");
        assert_equal(hazard_info.forward_ex_b, '0', "No forwarding");
        assert_equal(hazard_info.forward_wb_a, '0', "No forwarding");
        assert_equal(hazard_info.forward_wb_b, '0', "No forwarding");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 11: Stall requirement (Phase 4: none needed with forwarding)
        ----------------------------------------------------------------------
        report "--- Test 11: No Stall Required ---";

        -- Even with hazards, Phase 4 uses forwarding, so no stalls
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"5";  -- D5
        id_ea_src_reg2 <= x"5";  -- D5

        of_ex_valid <= '1';
        of_ex_dst_reg <= x"5";  -- D5
        of_ex_write <= '1';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.raw_hazard, '1', "RAW hazard present");
        assert_equal(stall_pipeline, '0', "No stall required (forwarding handles it)");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All HazardUnit tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
