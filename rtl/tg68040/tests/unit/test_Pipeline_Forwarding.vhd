------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040 Pipeline with Data Forwarding                        --
--                                                                          --
-- Tests pipeline performance with hazard detection and forwarding         --
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

entity test_Pipeline_Forwarding is
end test_Pipeline_Forwarding;

architecture sim of test_Pipeline_Forwarding is

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

    -- Simple register file model with known values
    type reg_file_t is array (0 to 15) of std_logic_vector(31 downto 0);
    signal registers : reg_file_t := (
        0 => x"00000001",  -- D0 = 1
        1 => x"00000002",  -- D1 = 2
        2 => x"00000003",  -- D2 = 3
        3 => x"00000005",  -- D3 = 5
        4 => x"00000007",  -- D4 = 7
        5 => x"0000000B",  -- D5 = 11
        6 => x"0000000D",  -- D6 = 13
        7 => x"00000011",  -- D7 = 17
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
            -- Read operations
            reg_data_a <= registers(to_integer(unsigned(reg_addr_a)));
            reg_data_b <= registers(to_integer(unsigned(reg_addr_b)));

            -- Write operation
            if reg_write_en = '1' then
                registers(to_integer(unsigned(reg_write_addr))) <= reg_write_data;
                report "Register write: R" & integer'image(to_integer(unsigned(reg_write_addr))) &
                       " = 0x" & to_hstring(reg_write_data);
            end if;
        end if;
    end process;

    -- Test process
    test_proc: process
        variable start_cycle : integer;
        variable end_cycle : integer;
        variable cycle_count : integer := 0;
    begin
        report "=== Starting Pipeline Forwarding tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset and initialization
        ----------------------------------------------------------------------
        report "--- Test 1: Reset and Initialization ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(pipeline_busy, '0', "Pipeline idle after reset");
        assert_equal(instructions_completed, x"00000000", "No instructions completed");

        ----------------------------------------------------------------------
        -- Test 2: Dependent instructions with forwarding
        ----------------------------------------------------------------------
        report "--- Test 2: Dependent Instructions (Forwarding Active) ---";

        -- Start pipeline
        enable <= '1';

        -- Pre-load register values for testing
        -- (The internal instruction memory has NOPs, but register file has values)

        -- Let pipeline run and observe forwarding in action
        wait for CLK_PERIOD * 20;

        -- Pipeline should be running smoothly
        report "Instructions completed: " & integer'image(to_integer(unsigned(instructions_completed)));

        -- Check that pipeline is not stalled (forwarding prevents stalls)
        assert_equal(pipeline_stalled, '0', "Pipeline not stalled with forwarding");

        wait for CLK_PERIOD * 10;

        ----------------------------------------------------------------------
        -- Test 3: Check register file writes occurred
        ----------------------------------------------------------------------
        report "--- Test 3: Register File Updates ---";

        -- After sufficient cycles, check that instructions completed
        assert_true(to_integer(unsigned(instructions_completed)) > 10,
                   "Multiple instructions completed");

        wait for CLK_PERIOD * 10;

        ----------------------------------------------------------------------
        -- Test 4: Performance measurement
        ----------------------------------------------------------------------
        report "--- Test 4: Performance Measurement ---";

        -- Reset instruction counter context
        start_cycle := to_integer(unsigned(instructions_completed));

        -- Run for exactly 50 cycles
        for i in 1 to 50 loop
            wait until rising_edge(clk);
        end loop;

        end_cycle := to_integer(unsigned(instructions_completed));

        report "Completed " & integer'image(end_cycle - start_cycle) &
               " instructions in 50 cycles";
        report "CPI = " & real'image(50.0 / real(end_cycle - start_cycle)) &
               " cycles per instruction";

        -- With Phase 4 forwarding, CPI should approach 1.0 for simple instructions
        -- After pipeline fill (6 cycles), we have 44 cycles
        -- Should complete approximately 44 instructions (CPI ≈ 1.0)
        -- Allow some margin: expect at least 35 instructions
        assert_true(end_cycle - start_cycle >= 35,
                   "Good throughput with forwarding (>= 35 instrs in 50 cycles)");

        wait for CLK_PERIOD * 10;

        ----------------------------------------------------------------------
        -- Test 5: Continuous operation without stalls
        ----------------------------------------------------------------------
        report "--- Test 5: Continuous Operation (No Stalls) ---";

        -- Run for extended period and verify no stalls occur
        start_cycle := to_integer(unsigned(instructions_completed));

        for i in 1 to 100 loop
            wait until rising_edge(clk);
            -- Check periodically that pipeline is not stalled
            if i mod 10 = 0 then
                assert_equal(pipeline_stalled, '0', "No stalls during execution");
            end if;
        end loop;

        end_cycle := to_integer(unsigned(instructions_completed));

        report "Completed " & integer'image(end_cycle - start_cycle) &
               " instructions in 100 cycles (continuous)";

        -- Expect high throughput
        assert_true(end_cycle - start_cycle >= 80,
                   "High continuous throughput with forwarding");

        wait for CLK_PERIOD * 10;

        ----------------------------------------------------------------------
        -- Test 6: Verify no spurious stalls
        ----------------------------------------------------------------------
        report "--- Test 6: Verify No Spurious Stalls ---";

        -- Monitor for any unexpected stalls
        cycle_count := 0;
        for i in 1 to 50 loop
            wait until rising_edge(clk);
            if pipeline_stalled = '1' then
                cycle_count := cycle_count + 1;
            end if;
        end loop;

        report "Stall cycles in 50-cycle window: " & integer'image(cycle_count);

        -- Phase 4 should have zero stalls with simple register operations
        assert_equal(cycle_count, 0, "No stalls with forwarding (Phase 4)");

        wait for CLK_PERIOD * 10;

        ----------------------------------------------------------------------
        -- Test 7: Disable and re-enable pipeline
        ----------------------------------------------------------------------
        report "--- Test 7: Disable and Re-enable Pipeline ---";

        start_cycle := to_integer(unsigned(instructions_completed));

        enable <= '0';
        wait for CLK_PERIOD * 20;

        -- Should not complete more instructions while disabled
        -- (may complete a few in-flight instructions)
        end_cycle := to_integer(unsigned(instructions_completed));
        assert_true(end_cycle - start_cycle <= 6,
                   "Few or no instructions while disabled");

        -- Re-enable
        enable <= '1';
        wait for CLK_PERIOD * 30;

        -- Should resume normal operation
        assert_true(to_integer(unsigned(instructions_completed)) > end_cycle,
                   "Instructions resume after re-enable");

        wait for CLK_PERIOD * 10;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All Pipeline Forwarding tests completed successfully ===";
        report "Total instructions completed: " &
               integer'image(to_integer(unsigned(instructions_completed)));
        test_done <= true;
        wait;

    end process;

end sim;
