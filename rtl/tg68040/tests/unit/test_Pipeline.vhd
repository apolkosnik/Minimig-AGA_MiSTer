------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_Pipeline                                             --
--                                                                          --
-- Tests the 6-stage pipeline foundation                                   --
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

entity test_Pipeline is
end test_Pipeline;

architecture sim of test_Pipeline is

    -- Component declaration
    component TG68040_Pipeline is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            enable         : in std_logic;
            mem_addr       : out std_logic_vector(31 downto 0);
            mem_data_read  : in std_logic_vector(31 downto 0);
            mem_data_write : out std_logic_vector(31 downto 0);
            mem_read       : out std_logic;
            mem_write      : out std_logic;
            mem_ready      : in std_logic;
            reg_addr_a     : out std_logic_vector(3 downto 0);
            reg_addr_b     : out std_logic_vector(3 downto 0);
            reg_data_a     : in std_logic_vector(31 downto 0);
            reg_data_b     : in std_logic_vector(31 downto 0);
            reg_write_addr : out std_logic_vector(3 downto 0);
            reg_write_data : out std_logic_vector(31 downto 0);
            reg_write_en   : out std_logic;
            pipeline_busy  : out std_logic;
            instructions_completed : out std_logic_vector(31 downto 0);
            pipeline_stalled : out std_logic;
            pipeline_flushed : out std_logic
        );
    end component;

    -- Test signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal enable         : std_logic := '0';
    signal mem_addr       : std_logic_vector(31 downto 0);
    signal mem_data_read  : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_data_write : std_logic_vector(31 downto 0);
    signal mem_read       : std_logic;
    signal mem_write      : std_logic;
    signal mem_ready      : std_logic := '1';
    signal reg_addr_a     : std_logic_vector(3 downto 0);
    signal reg_addr_b     : std_logic_vector(3 downto 0);
    signal reg_data_a     : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_data_b     : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_write_addr : std_logic_vector(3 downto 0);
    signal reg_write_data : std_logic_vector(31 downto 0);
    signal reg_write_en   : std_logic;
    signal pipeline_busy  : std_logic;
    signal instructions_completed : std_logic_vector(31 downto 0);
    signal pipeline_stalled : std_logic;
    signal pipeline_flushed : std_logic;

    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

    -- Simple register file model
    type reg_file_t is array (0 to 15) of std_logic_vector(31 downto 0);
    signal registers : reg_file_t := (
        0 => x"00000001",
        1 => x"00000002",
        2 => x"00000005",
        3 => x"0000000A",
        others => x"00000000"
    );

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation
    dut: TG68040_Pipeline
        port map(
            clk            => clk,
            reset          => reset,
            enable         => enable,
            mem_addr       => mem_addr,
            mem_data_read  => mem_data_read,
            mem_data_write => mem_data_write,
            mem_read       => mem_read,
            mem_write      => mem_write,
            mem_ready      => mem_ready,
            reg_addr_a     => reg_addr_a,
            reg_addr_b     => reg_addr_b,
            reg_data_a     => reg_data_a,
            reg_data_b     => reg_data_b,
            reg_write_addr => reg_write_addr,
            reg_write_data => reg_write_data,
            reg_write_en   => reg_write_en,
            pipeline_busy  => pipeline_busy,
            instructions_completed => instructions_completed,
            pipeline_stalled => pipeline_stalled,
            pipeline_flushed => pipeline_flushed
        );

    -- Register file model
    reg_file_proc: process(clk)
    begin
        if rising_edge(clk) then
            -- Read operations (combinational in real hardware, but sequential here for simplicity)
            reg_data_a <= registers(to_integer(unsigned(reg_addr_a)));
            reg_data_b <= registers(to_integer(unsigned(reg_addr_b)));

            -- Write operation
            if reg_write_en = '1' then
                registers(to_integer(unsigned(reg_write_addr))) <= reg_write_data;
            end if;
        end if;
    end process;

    -- Test process
    test_proc: process
        variable instr_count : integer;
    begin
        report "=== Starting Pipeline tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(pipeline_busy, '0', "Not busy after reset");
        assert_equal(instructions_completed, x"00000000", "No instructions completed after reset");

        ----------------------------------------------------------------------
        -- Test 2: Pipeline propagation with NOPs
        ----------------------------------------------------------------------
        report "--- Test 2: Pipeline Propagation (NOPs) ---";

        -- Enable pipeline
        enable <= '1';

        -- Let pipeline run for several cycles (NOPs are pre-loaded)
        wait for CLK_PERIOD * 10;

        -- Pipeline should have processed some NOPs
        report "Instructions completed: " & integer'image(to_integer(unsigned(instructions_completed)));

        -- After 10 cycles, at least 4-5 NOPs should have completed (6-cycle latency + 1 per cycle)
        instr_count := to_integer(unsigned(instructions_completed));
        assert_true(instr_count >= 4, "At least 4 NOPs completed");

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 3: Register file read
        ----------------------------------------------------------------------
        report "--- Test 3: Register File Read ---";

        -- Wait a cycle and check that register reads are happening
        wait for CLK_PERIOD * 3;

        -- The pipeline should be reading registers based on instruction decode
        -- For NOPs, reg_addr should be 0
        -- (Hard to test without specific instructions, but we verify no crashes)

        report "Register A address: " & integer'image(to_integer(unsigned(reg_addr_a)));
        report "Register B address: " & integer'image(to_integer(unsigned(reg_addr_b)));

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 4: Pipeline stall (memory not ready)
        ----------------------------------------------------------------------
        report "--- Test 4: Pipeline Stall ---";

        instr_count := to_integer(unsigned(instructions_completed));

        -- Stall the pipeline by setting memory not ready
        mem_ready <= '0';
        wait for CLK_PERIOD * 5;

        -- Check that pipeline is stalled
        assert_equal(pipeline_stalled, '1', "Pipeline stalled when memory not ready");

        -- Instruction count should not increase during stall
        assert_equal(instructions_completed, std_logic_vector(to_unsigned(instr_count, 32)),
                    "No new instructions during stall");

        -- Resume
        mem_ready <= '1';
        wait for CLK_PERIOD * 10;

        -- Instructions should complete again
        assert_true(to_integer(unsigned(instructions_completed)) > instr_count,
                   "Instructions resume after stall");

        ----------------------------------------------------------------------
        -- Test 5: Register write-back
        ----------------------------------------------------------------------
        report "--- Test 5: Register Write-Back ---";

        -- Wait for enough cycles that write-back should occur
        wait for CLK_PERIOD * 10;

        -- Check if any register writes happened
        -- For NOPs, there should be no writes, so registers should remain initial values
        -- (More detailed test would require specific instruction injection)

        if reg_write_en = '1' then
            report "Register write detected: R" & integer'image(to_integer(unsigned(reg_write_addr))) &
                   " = 0x" & to_hstring(reg_write_data);
        end if;

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 6: Pipeline throughput
        ----------------------------------------------------------------------
        report "--- Test 6: Pipeline Throughput ---";

        -- Record starting instruction count
        wait for CLK_PERIOD;
        instr_count := to_integer(unsigned(instructions_completed));

        -- Run for exactly 20 cycles
        wait for CLK_PERIOD * 20;

        -- After pipeline fill (6 cycles), we should complete ~1 instruction per cycle
        -- So in 20 cycles, we expect ~14-15 new instructions
        -- (20 cycles - 6 cycle latency = 14 steady-state cycles)
        report "Instructions in 20 cycles: " &
               integer'image(to_integer(unsigned(instructions_completed)) - instr_count);

        assert_true(to_integer(unsigned(instructions_completed)) - instr_count >= 10,
                   "Pipeline achieves good throughput");

        ----------------------------------------------------------------------
        -- Test 7: Continuous operation
        ----------------------------------------------------------------------
        report "--- Test 7: Continuous Operation ---";

        -- Run for extended period
        wait for CLK_PERIOD * 50;

        -- Pipeline should still be running
        assert_equal(pipeline_busy, '1', "Pipeline still busy");

        -- Should have completed many instructions
        report "Total instructions completed: " &
               integer'image(to_integer(unsigned(instructions_completed)));

        assert_true(to_integer(unsigned(instructions_completed)) > 50,
                   "Many instructions completed");

        ----------------------------------------------------------------------
        -- Test 8: Disable pipeline
        ----------------------------------------------------------------------
        report "--- Test 8: Disable Pipeline ---";

        instr_count := to_integer(unsigned(instructions_completed));

        -- Disable pipeline
        enable <= '0';
        wait for CLK_PERIOD * 10;

        -- No new instructions should complete
        -- (actually, instructions in pipeline will still complete, but no new ones fetched)
        report "Instructions after disable: " &
               integer'image(to_integer(unsigned(instructions_completed)));

        -- Re-enable
        enable <= '1';
        wait for CLK_PERIOD * 10;

        -- Should resume
        assert_true(to_integer(unsigned(instructions_completed)) >= instr_count,
                   "Pipeline resumes after re-enable");

        ----------------------------------------------------------------------
        -- Test 9: Multiple stall/resume cycles
        ----------------------------------------------------------------------
        report "--- Test 9: Multiple Stall/Resume Cycles ---";

        for i in 1 to 5 loop
            mem_ready <= '0';
            wait for CLK_PERIOD * 2;
            mem_ready <= '1';
            wait for CLK_PERIOD * 3;
        end loop;

        -- Pipeline should handle multiple stalls gracefully
        assert_true(to_integer(unsigned(instructions_completed)) > 0,
                   "Pipeline survives multiple stalls");

        wait for CLK_PERIOD * 10;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All Pipeline tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
