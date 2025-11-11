------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: Load-Use Hazard Detection                                    --
--                                                                          --
-- Tests the load-use hazard detection in the hazard unit                  --
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

entity test_LoadUseHazard is
end test_LoadUseHazard;

architecture sim of test_LoadUseHazard is

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
            of_ex_read_mem : in std_logic;
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
    signal of_ex_read_mem : std_logic := '0';
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
            of_ex_read_mem => of_ex_read_mem,
            ex_wb_valid    => ex_wb_valid,
            ex_wb_dst_reg  => ex_wb_dst_reg,
            ex_wb_write    => ex_wb_write,
            hazard_info    => hazard_info,
            stall_pipeline => stall_pipeline
        );

    -- Test process
    test_proc: process
    begin
        report "=== Starting Load-Use Hazard tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '0', "No load-use hazard after reset");
        assert_equal(hazard_info.stall_for_load, '0', "No stall after reset");
        assert_equal(stall_pipeline, '0', "No pipeline stall after reset");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 2: No hazard (no load in EX)
        ----------------------------------------------------------------------
        report "--- Test 2: No Hazard (No Load) ---";

        -- ID stage reads D1
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"1";  -- D1

        -- EX stage writes D1, but NOT a load
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"1";  -- D1
        of_ex_write <= '1';
        of_ex_read_mem <= '0';  -- Not a load

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '0', "No load-use hazard (not a load)");
        assert_equal(hazard_info.stall_for_load, '0', "No stall");
        assert_equal(stall_pipeline, '0', "No pipeline stall");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 3: Load-use hazard (operand A)
        ----------------------------------------------------------------------
        report "--- Test 3: Load-Use Hazard (Operand A) ---";

        -- ID stage reads D0
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"0";  -- D0

        -- EX stage has load writing to D0
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"0";  -- D0
        of_ex_write <= '1';
        of_ex_read_mem <= '1';  -- Load instruction

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '1', "Load-use hazard detected");
        assert_equal(hazard_info.stall_for_load, '1', "Stall asserted");
        assert_equal(stall_pipeline, '1', "Pipeline stall asserted");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 4: Load-use hazard (operand B)
        ----------------------------------------------------------------------
        report "--- Test 4: Load-Use Hazard (Operand B) ---";

        -- ID stage reads D2 in operand B
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"1";  -- D1
        id_ea_src_reg2 <= x"2";  -- D2

        -- EX stage has load writing to D2
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"2";  -- D2
        of_ex_write <= '1';
        of_ex_read_mem <= '1';  -- Load instruction

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '1', "Load-use hazard on operand B");
        assert_equal(hazard_info.stall_for_load, '1', "Stall asserted");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 5: Load-use hazard (both operands)
        ----------------------------------------------------------------------
        report "--- Test 5: Load-Use Hazard (Both Operands) ---";

        -- ID stage reads D3 in both operands
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"3";  -- D3
        id_ea_src_reg2 <= x"3";  -- D3

        -- EX stage has load writing to D3
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"3";  -- D3
        of_ex_write <= '1';
        of_ex_read_mem <= '1';  -- Load instruction

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '1', "Load-use hazard on both operands");
        assert_equal(hazard_info.stall_for_load, '1', "Stall asserted");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 6: No hazard (different registers)
        ----------------------------------------------------------------------
        report "--- Test 6: No Hazard (Different Registers) ---";

        -- ID stage reads D4, D5
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"4";  -- D4
        id_ea_src_reg2 <= x"5";  -- D5

        -- EX stage has load writing to D6
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"6";  -- D6
        of_ex_write <= '1';
        of_ex_read_mem <= '1';  -- Load instruction

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '0', "No load-use hazard (different registers)");
        assert_equal(hazard_info.stall_for_load, '0', "No stall");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 7: No hazard (load doesn't write)
        ----------------------------------------------------------------------
        report "--- Test 7: No Hazard (Load Doesn't Write) ---";

        -- ID stage reads D7
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"7";  -- D7

        -- EX stage has load to D7 but doesn't write
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"7";  -- D7
        of_ex_write <= '0';  -- Doesn't write
        of_ex_read_mem <= '1';  -- Load instruction

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '0', "No load-use hazard (load doesn't write)");
        assert_equal(hazard_info.stall_for_load, '0', "No stall");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 8: No hazard (EX stage not valid)
        ----------------------------------------------------------------------
        report "--- Test 8: No Hazard (EX Not Valid) ---";

        -- ID stage reads D0
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"0";  -- D0

        -- EX stage not valid
        of_ex_valid <= '0';
        of_ex_dst_reg <= x"0";  -- D0
        of_ex_write <= '1';
        of_ex_read_mem <= '1';  -- Load instruction

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '0', "No load-use hazard (EX not valid)");
        assert_equal(hazard_info.stall_for_load, '0', "No stall");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 9: No hazard (ID stage not valid)
        ----------------------------------------------------------------------
        report "--- Test 9: No Hazard (ID Not Valid) ---";

        -- ID stage not valid
        id_ea_valid <= '0';
        id_ea_src_reg1 <= x"1";  -- D1

        -- EX stage has load writing to D1
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"1";  -- D1
        of_ex_write <= '1';
        of_ex_read_mem <= '1';  -- Load instruction

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '0', "No load-use hazard (ID not valid)");
        assert_equal(hazard_info.stall_for_load, '0', "No stall");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 10: Sequence - load followed by use
        ----------------------------------------------------------------------
        report "--- Test 10: Sequence - Load Followed by Use ---";

        -- Cycle 1: Load in EX
        of_ex_valid <= '1';
        of_ex_dst_reg <= x"2";  -- D2
        of_ex_write <= '1';
        of_ex_read_mem <= '1';

        -- Instruction using D2 in ID
        id_ea_valid <= '1';
        id_ea_src_reg1 <= x"2";  -- D2

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '1', "Cycle 1: Hazard detected");
        assert_equal(stall_pipeline, '1', "Cycle 1: Pipeline stalled");

        -- Cycle 2: Stall, load moves to WB
        of_ex_valid <= '0';  -- Bubble inserted
        of_ex_read_mem <= '0';

        wait for CLK_PERIOD * 2;

        assert_equal(hazard_info.load_use_hazard, '0', "Cycle 2: Hazard resolved");
        assert_equal(stall_pipeline, '0', "Cycle 2: Pipeline resumes");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All Load-Use Hazard tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
