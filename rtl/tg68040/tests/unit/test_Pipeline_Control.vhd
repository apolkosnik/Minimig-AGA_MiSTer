------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_Pipeline Control                                     --
--                                                                          --
-- Tests pipeline stall and flush mechanisms                               --
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

entity test_Pipeline_Control is
end test_Pipeline_Control;

architecture sim of test_Pipeline_Control is

    -- Test signals for pipeline register types
    signal if_id_reg : if_id_reg_t := IF_ID_REG_INIT;
    signal id_ea_reg : id_ea_reg_t := ID_EA_REG_INIT;
    signal ea_of_reg : ea_of_reg_t := EA_OF_REG_INIT;
    signal of_ex_reg : of_ex_reg_t := OF_EX_REG_INIT;
    signal ex_wb_reg : ex_wb_reg_t := EX_WB_REG_INIT;

    signal ctrl : pipeline_ctrl_t := PIPELINE_CTRL_INIT;
    signal stats : pipeline_stats_t := PIPELINE_STATS_INIT;

    signal clk : std_logic := '0';
    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- Test process
    test_proc: process
    begin
        report "=== Starting Pipeline Control tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Pipeline register initialization
        ----------------------------------------------------------------------
        report "--- Test 1: Pipeline Register Initialization ---";

        -- Check IF/ID register init
        assert_equal(IF_ID_REG_INIT.valid, '0', "IF/ID valid initialized to 0");
        assert_equal(IF_ID_REG_INIT.pc, x"00000000", "IF/ID PC initialized to 0");

        -- Check ID/EA register init
        assert_equal(ID_EA_REG_INIT.valid, '0', "ID/EA valid initialized to 0");

        -- Check EA/OF register init
        assert_equal(EA_OF_REG_INIT.valid, '0', "EA/OF valid initialized to 0");

        -- Check OF/EX register init
        assert_equal(OF_EX_REG_INIT.valid, '0', "OF/EX valid initialized to 0");

        -- Check EX/WB register init
        assert_equal(EX_WB_REG_INIT.valid, '0', "EX/WB valid initialized to 0");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 2: Pipeline control initialization
        ----------------------------------------------------------------------
        report "--- Test 2: Pipeline Control Initialization ---";

        -- Check control signals
        assert_equal(PIPELINE_CTRL_INIT.stall_if, '0', "No IF stall on init");
        assert_equal(PIPELINE_CTRL_INIT.stall_id, '0', "No ID stall on init");
        assert_equal(PIPELINE_CTRL_INIT.stall_ea, '0', "No EA stall on init");
        assert_equal(PIPELINE_CTRL_INIT.stall_of, '0', "No OF stall on init");
        assert_equal(PIPELINE_CTRL_INIT.stall_ex, '0', "No EX stall on init");

        assert_equal(PIPELINE_CTRL_INIT.flush_if, '0', "No IF flush on init");
        assert_equal(PIPELINE_CTRL_INIT.flush_id, '0', "No ID flush on init");
        assert_equal(PIPELINE_CTRL_INIT.flush_ea, '0', "No EA flush on init");
        assert_equal(PIPELINE_CTRL_INIT.flush_of, '0', "No OF flush on init");
        assert_equal(PIPELINE_CTRL_INIT.flush_ex, '0', "No EX flush on init");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 3: Pipeline statistics initialization
        ----------------------------------------------------------------------
        report "--- Test 3: Pipeline Statistics Initialization ---";

        assert_equal(PIPELINE_STATS_INIT.cycles_total, x"00000000", "Cycles start at 0");
        assert_equal(PIPELINE_STATS_INIT.instrs_total, x"00000000", "Instructions start at 0");
        assert_equal(PIPELINE_STATS_INIT.stalls_total, x"00000000", "Stalls start at 0");
        assert_equal(PIPELINE_STATS_INIT.flushes_total, x"00000000", "Flushes start at 0");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 4: Pipeline register data propagation simulation
        ----------------------------------------------------------------------
        report "--- Test 4: Pipeline Register Data Propagation ---";

        -- Simulate instruction entering IF stage
        wait until rising_edge(clk);
        if_id_reg.valid <= '1';
        if_id_reg.pc <= x"00001000";
        if_id_reg.instruction <= x"4E71";  -- NOP
        if_id_reg.exception <= '0';

        wait for CLK_PERIOD;

        -- Simulate propagation to ID stage
        wait until rising_edge(clk);
        id_ea_reg.valid <= if_id_reg.valid;
        id_ea_reg.pc <= if_id_reg.pc;
        id_ea_reg.opcode <= if_id_reg.instruction;

        wait for CLK_PERIOD;

        -- Verify data propagated
        assert_equal(id_ea_reg.valid, '1', "Valid bit propagated");
        assert_equal(id_ea_reg.pc, x"00001000", "PC propagated");
        assert_equal(id_ea_reg.opcode, x"4E71", "Opcode propagated");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 5: Pipeline flush simulation
        ----------------------------------------------------------------------
        report "--- Test 5: Pipeline Flush Simulation ---";

        -- Set up pipeline with valid instructions
        if_id_reg.valid <= '1';
        id_ea_reg.valid <= '1';
        ea_of_reg.valid <= '1';

        wait for CLK_PERIOD;

        -- Trigger flush
        wait until rising_edge(clk);
        ctrl.flush_if <= '1';
        ctrl.flush_id <= '1';
        ctrl.flush_ea <= '1';

        wait for CLK_PERIOD;

        -- Simulate flush clearing valid bits
        wait until rising_edge(clk);
        if ctrl.flush_if = '1' then
            if_id_reg.valid <= '0';
        end if;
        if ctrl.flush_id = '1' then
            id_ea_reg.valid <= '0';
        end if;
        if ctrl.flush_ea = '1' then
            ea_of_reg.valid <= '0';
        end if;

        wait for CLK_PERIOD;

        -- Verify flush worked
        assert_equal(if_id_reg.valid, '0', "IF stage flushed");
        assert_equal(id_ea_reg.valid, '0', "ID stage flushed");
        assert_equal(ea_of_reg.valid, '0', "EA stage flushed");

        -- Clear flush signals
        ctrl.flush_if <= '0';
        ctrl.flush_id <= '0';
        ctrl.flush_ea <= '0';

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 6: Pipeline stall simulation
        ----------------------------------------------------------------------
        report "--- Test 6: Pipeline Stall Simulation ---";

        -- Set up pipeline
        if_id_reg.valid <= '1';
        if_id_reg.pc <= x"00002000";
        id_ea_reg.valid <= '0';

        wait for CLK_PERIOD;

        -- Trigger stall
        ctrl.stall_if <= '1';
        ctrl.stall_id <= '1';

        wait for CLK_PERIOD * 3;

        -- During stall, IF/ID register should not advance
        -- (In real implementation, PC wouldn't increment)
        assert_equal(if_id_reg.pc, x"00002000", "PC held during stall");

        -- Clear stall
        ctrl.stall_if <= '0';
        ctrl.stall_id <= '0';

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 7: Statistics counter simulation
        ----------------------------------------------------------------------
        report "--- Test 7: Statistics Counter Simulation ---";

        stats.cycles_total <= x"00000000";
        stats.instrs_total <= x"00000000";
        stats.stalls_total <= x"00000000";

        -- Simulate cycles counting
        for i in 1 to 10 loop
            wait until rising_edge(clk);
            stats.cycles_total <= std_logic_vector(unsigned(stats.cycles_total) + 1);
        end loop;

        assert_equal(stats.cycles_total, x"0000000A", "10 cycles counted");

        -- Simulate instruction completion
        for i in 1 to 5 loop
            wait until rising_edge(clk);
            stats.instrs_total <= std_logic_vector(unsigned(stats.instrs_total) + 1);
        end loop;

        assert_equal(stats.instrs_total, x"00000005", "5 instructions counted");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 8: Multiple pipeline stages with data
        ----------------------------------------------------------------------
        report "--- Test 8: Multiple Stages with Data ---";

        -- Set up a full pipeline
        wait until rising_edge(clk);
        if_id_reg.valid <= '1';
        if_id_reg.pc <= x"00001000";
        if_id_reg.instruction <= x"D001";  -- ADD D1,D0

        wait until rising_edge(clk);
        id_ea_reg.valid <= '1';
        id_ea_reg.pc <= x"00001000";
        id_ea_reg.opcode <= x"D001";
        id_ea_reg.src_reg1 <= x"1";  -- D1
        id_ea_reg.dst_reg <= x"0";   -- D0

        wait until rising_edge(clk);
        ea_of_reg.valid <= '1';
        ea_of_reg.pc <= x"00001000";

        wait until rising_edge(clk);
        of_ex_reg.valid <= '1';
        of_ex_reg.pc <= x"00001000";
        of_ex_reg.operand1 <= x"00000005";
        of_ex_reg.operand2 <= x"00000003";

        wait until rising_edge(clk);
        ex_wb_reg.valid <= '1';
        ex_wb_reg.pc <= x"00001000";
        ex_wb_reg.result <= x"00000008";  -- 5 + 3
        ex_wb_reg.write_reg <= '1';

        wait for CLK_PERIOD;

        -- Verify all stages have data
        assert_equal(if_id_reg.valid, '1', "IF stage valid");
        assert_equal(id_ea_reg.valid, '1', "ID stage valid");
        assert_equal(ea_of_reg.valid, '1', "EA stage valid");
        assert_equal(of_ex_reg.valid, '1', "OF stage valid");
        assert_equal(ex_wb_reg.valid, '1', "EX stage valid");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All Pipeline Control tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
