------------------------------------------------------------------------------
-- Test: MC68030 MMU Instructions Integration
--
-- Tests the integration of PFLUSH and PTEST instructions with the MMU:
--   - PFLUSHA flushes all ATC entries
--   - PFLUSH FC flushes entries by function code
--   - PFLUSH FC,EA flushes specific address
--   - PTEST checks ATC and performs table walk
--   - PTEST updates MMUSR correctly
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity test_mmu_instructions is
end entity test_mmu_instructions;

architecture testbench of test_mmu_instructions is

    -- Component: MMU Integration
    component TG68K030_MMU_Integration is
        port(
            clk, reset          : in  std_logic;
            pflush_inv_req      : in  std_logic;
            pflush_inv_mode     : in  std_logic_vector(1 downto 0);
            pflush_inv_fc       : in  std_logic_vector(2 downto 0);
            pflush_inv_addr     : in  std_logic_vector(31 downto 0);
            pflush_inv_ack      : out std_logic;
            ptest_walk_req      : in  std_logic;
            ptest_walk_level    : in  std_logic_vector(2 downto 0);
            ptest_walk_fc       : in  std_logic_vector(2 downto 0);
            ptest_walk_addr     : in  std_logic_vector(31 downto 0);
            ptest_walk_rw       : in  std_logic;
            ptest_walk_done     : out std_logic;
            ptest_walk_result   : out std_logic_vector(15 downto 0);
            ptest_desc_addr     : out std_logic_vector(31 downto 0);
            ptest_atc_req       : in  std_logic;
            ptest_atc_fc        : in  std_logic_vector(2 downto 0);
            ptest_atc_addr      : in  std_logic_vector(31 downto 0);
            ptest_atc_hit       : out std_logic;
            ptest_atc_done      : out std_logic;
            mmu_flush_all       : out std_logic;
            mmu_flush_fc        : out std_logic;
            mmu_flush_addr      : out std_logic;
            mmu_flush_fc_val    : out std_logic_vector(2 downto 0);
            mmu_flush_addr_val  : out std_logic_vector(31 downto 0);
            mmu_trans_req       : out std_logic;
            mmu_trans_addr      : out std_logic_vector(31 downto 0);
            mmu_trans_fc        : out std_logic_vector(2 downto 0);
            mmu_trans_rw        : out std_logic;
            mmu_trans_ready     : in  std_logic;
            mmu_trans_error     : in  std_logic;
            mmu_phys_addr       : in  std_logic_vector(31 downto 0);
            atc_lookup_en       : out std_logic;
            atc_lookup_addr     : out std_logic_vector(31 downto 0);
            atc_lookup_fc       : out std_logic_vector(2 downto 0);
            atc_hit             : in  std_logic;
            atc_phys_addr       : in  std_logic_vector(31 downto 0);
            atc_wp              : in  std_logic;
            atc_super           : in  std_logic;
            atc_ci              : in  std_logic;
            atc_modified        : in  std_logic;
            atc_used            : in  std_logic;
            mmu_status          : in  std_logic_vector(15 downto 0)
        );
    end component;

    -- Component: ATC
    component TG68K030_ATC is
        port(
            clk, reset      : in  std_logic;
            lookup_addr     : in  std_logic_vector(31 downto 0);
            lookup_fc       : in  std_logic_vector(2 downto 0);
            lookup_en       : in  std_logic;
            hit             : out std_logic;
            phys_addr       : out std_logic_vector(31 downto 0);
            write_protect   : out std_logic;
            super_only      : out std_logic;
            cache_inhibit   : out std_logic;
            modified        : out std_logic;
            used            : out std_logic;
            load_entry      : in  std_logic;
            load_virt_addr  : in  std_logic_vector(31 downto 0);
            load_phys_addr  : in  std_logic_vector(31 downto 0);
            load_fc         : in  std_logic_vector(2 downto 0);
            load_wp         : in  std_logic;
            load_super      : in  std_logic;
            load_ci         : in  std_logic;
            load_modified   : in  std_logic;
            load_used       : in  std_logic;
            flush_all       : in  std_logic;
            flush_by_fc     : in  std_logic;
            flush_fc        : in  std_logic_vector(2 downto 0);
            flush_by_addr   : in  std_logic;
            flush_addr      : in  std_logic_vector(31 downto 0)
        );
    end component;

    -- Clock and reset
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- PFLUSH signals
    signal pflush_inv_req  : std_logic := '0';
    signal pflush_inv_mode : std_logic_vector(1 downto 0) := "00";
    signal pflush_inv_fc   : std_logic_vector(2 downto 0) := "000";
    signal pflush_inv_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal pflush_inv_ack  : std_logic;

    -- PTEST signals
    signal ptest_walk_req    : std_logic := '0';
    signal ptest_walk_level  : std_logic_vector(2 downto 0) := "000";
    signal ptest_walk_fc     : std_logic_vector(2 downto 0) := "000";
    signal ptest_walk_addr   : std_logic_vector(31 downto 0) := (others => '0');
    signal ptest_walk_rw     : std_logic := '0';
    signal ptest_walk_done   : std_logic;
    signal ptest_walk_result : std_logic_vector(15 downto 0);
    signal ptest_desc_addr   : std_logic_vector(31 downto 0);
    signal ptest_atc_req     : std_logic := '0';
    signal ptest_atc_fc      : std_logic_vector(2 downto 0) := "000";
    signal ptest_atc_addr    : std_logic_vector(31 downto 0) := (others => '0');
    signal ptest_atc_hit     : std_logic;
    signal ptest_atc_done    : std_logic;

    -- MMU signals
    signal mmu_flush_all      : std_logic;
    signal mmu_flush_fc       : std_logic;
    signal mmu_flush_addr     : std_logic;
    signal mmu_flush_fc_val   : std_logic_vector(2 downto 0);
    signal mmu_flush_addr_val : std_logic_vector(31 downto 0);
    signal mmu_trans_req      : std_logic;
    signal mmu_trans_addr     : std_logic_vector(31 downto 0);
    signal mmu_trans_fc       : std_logic_vector(2 downto 0);
    signal mmu_trans_rw       : std_logic;
    signal mmu_trans_ready    : std_logic := '0';
    signal mmu_trans_error    : std_logic := '0';
    signal mmu_phys_addr      : std_logic_vector(31 downto 0) := (others => '0');
    signal mmu_status         : std_logic_vector(15 downto 0) := (others => '0');

    -- ATC signals
    signal atc_lookup_en   : std_logic;
    signal atc_lookup_addr : std_logic_vector(31 downto 0);
    signal atc_lookup_fc   : std_logic_vector(2 downto 0);
    signal atc_hit         : std_logic;
    signal atc_phys_addr   : std_logic_vector(31 downto 0);
    signal atc_wp          : std_logic;
    signal atc_super       : std_logic;
    signal atc_ci          : std_logic;
    signal atc_modified    : std_logic;
    signal atc_used        : std_logic;

    -- ATC load signals
    signal atc_load_entry     : std_logic := '0';
    signal atc_load_virt_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal atc_load_phys_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal atc_load_fc        : std_logic_vector(2 downto 0) := "000";
    signal atc_load_wp        : std_logic := '0';
    signal atc_load_super     : std_logic := '0';
    signal atc_load_ci        : std_logic := '0';
    signal atc_load_modified  : std_logic := '0';
    signal atc_load_used      : std_logic := '0';

    -- Test control
    signal test_done : boolean := false;
    constant CLK_PERIOD : time := 10 ns;
    signal test_num : integer := 0;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- Instantiate integration module
    integ_inst: TG68K030_MMU_Integration
        port map(
            clk                => clk,
            reset              => reset,
            pflush_inv_req     => pflush_inv_req,
            pflush_inv_mode    => pflush_inv_mode,
            pflush_inv_fc      => pflush_inv_fc,
            pflush_inv_addr    => pflush_inv_addr,
            pflush_inv_ack     => pflush_inv_ack,
            ptest_walk_req     => ptest_walk_req,
            ptest_walk_level   => ptest_walk_level,
            ptest_walk_fc      => ptest_walk_fc,
            ptest_walk_addr    => ptest_walk_addr,
            ptest_walk_rw      => ptest_walk_rw,
            ptest_walk_done    => ptest_walk_done,
            ptest_walk_result  => ptest_walk_result,
            ptest_desc_addr    => ptest_desc_addr,
            ptest_atc_req      => ptest_atc_req,
            ptest_atc_fc       => ptest_atc_fc,
            ptest_atc_addr     => ptest_atc_addr,
            ptest_atc_hit      => ptest_atc_hit,
            ptest_atc_done     => ptest_atc_done,
            mmu_flush_all      => mmu_flush_all,
            mmu_flush_fc       => mmu_flush_fc,
            mmu_flush_addr     => mmu_flush_addr,
            mmu_flush_fc_val   => mmu_flush_fc_val,
            mmu_flush_addr_val => mmu_flush_addr_val,
            mmu_trans_req      => mmu_trans_req,
            mmu_trans_addr     => mmu_trans_addr,
            mmu_trans_fc       => mmu_trans_fc,
            mmu_trans_rw       => mmu_trans_rw,
            mmu_trans_ready    => mmu_trans_ready,
            mmu_trans_error    => mmu_trans_error,
            mmu_phys_addr      => mmu_phys_addr,
            atc_lookup_en      => atc_lookup_en,
            atc_lookup_addr    => atc_lookup_addr,
            atc_lookup_fc      => atc_lookup_fc,
            atc_hit            => atc_hit,
            atc_phys_addr      => atc_phys_addr,
            atc_wp             => atc_wp,
            atc_super          => atc_super,
            atc_ci             => atc_ci,
            atc_modified       => atc_modified,
            atc_used           => atc_used,
            mmu_status         => mmu_status
        );

    -- Instantiate ATC
    atc_inst: TG68K030_ATC
        port map(
            clk            => clk,
            reset          => reset,
            lookup_addr    => atc_lookup_addr,
            lookup_fc      => atc_lookup_fc,
            lookup_en      => atc_lookup_en,
            hit            => atc_hit,
            phys_addr      => atc_phys_addr,
            write_protect  => atc_wp,
            super_only     => atc_super,
            cache_inhibit  => atc_ci,
            modified       => atc_modified,
            used           => atc_used,
            load_entry     => atc_load_entry,
            load_virt_addr => atc_load_virt_addr,
            load_phys_addr => atc_load_phys_addr,
            load_fc        => atc_load_fc,
            load_wp        => atc_load_wp,
            load_super     => atc_load_super,
            load_ci        => atc_load_ci,
            load_modified  => atc_load_modified,
            load_used      => atc_load_used,
            flush_all      => mmu_flush_all,
            flush_by_fc    => mmu_flush_fc,
            flush_fc       => mmu_flush_fc_val,
            flush_by_addr  => mmu_flush_addr,
            flush_addr     => mmu_flush_addr_val
        );

    -- Test process
    test_proc: process
        variable l : line;

        procedure report_test(test_name : string) is
        begin
            test_num <= test_num + 1;
            write(l, string'("Test "));
            write(l, test_num + 1);
            write(l, string'(": "));
            write(l, test_name);
            writeline(output, l);
        end procedure;

        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

    begin
        -- Reset
        reset <= '1';
        wait_cycles(5);
        reset <= '0';
        wait_cycles(2);

        ---------------------------------------------------------------
        -- Setup: Load some entries into ATC
        ---------------------------------------------------------------
        report_test("Setup: Load 5 entries into ATC");

        -- Entry 1: User data, 0x10000000 → 0x20000000
        atc_load_virt_addr <= X"10000000";
        atc_load_phys_addr <= X"20000000";
        atc_load_fc        <= "001";  -- User data
        atc_load_wp        <= '0';
        atc_load_super     <= '0';
        atc_load_ci        <= '0';
        atc_load_modified  <= '0';
        atc_load_used      <= '1';
        atc_load_entry     <= '1';
        wait_cycles(1);
        atc_load_entry     <= '0';
        wait_cycles(1);

        -- Entry 2: Supervisor data, 0x11000000 → 0x21000000
        atc_load_virt_addr <= X"11000000";
        atc_load_phys_addr <= X"21000000";
        atc_load_fc        <= "101";  -- Supervisor data
        atc_load_entry     <= '1';
        wait_cycles(1);
        atc_load_entry     <= '0';
        wait_cycles(1);

        -- Entry 3: Supervisor program, 0x12000000 → 0x22000000
        atc_load_virt_addr <= X"12000000";
        atc_load_phys_addr <= X"22000000";
        atc_load_fc        <= "110";  -- Supervisor program
        atc_load_entry     <= '1';
        wait_cycles(1);
        atc_load_entry     <= '0';
        wait_cycles(1);

        -- Entry 4: User program, 0x13000000 → 0x23000000
        atc_load_virt_addr <= X"13000000";
        atc_load_phys_addr <= X"23000000";
        atc_load_fc        <= "010";  -- User program
        atc_load_entry     <= '1';
        wait_cycles(1);
        atc_load_entry     <= '0';
        wait_cycles(1);

        -- Entry 5: Supervisor data, 0x14000000 → 0x24000000
        atc_load_virt_addr <= X"14000000";
        atc_load_phys_addr <= X"24000000";
        atc_load_fc        <= "101";  -- Supervisor data
        atc_load_entry     <= '1';
        wait_cycles(1);
        atc_load_entry     <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 1: PTEST ATC lookup - entry present
        ---------------------------------------------------------------
        report_test("PTEST ATC lookup - entry present");
        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"10000000";
        ptest_atc_fc   <= "001";
        wait_cycles(1);
        ptest_atc_req  <= '0';

        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '1' report "Expected ATC hit" severity error;

        ---------------------------------------------------------------
        -- Test 2: PTEST ATC lookup - entry not present
        ---------------------------------------------------------------
        report_test("PTEST ATC lookup - entry not present");
        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"99000000";
        ptest_atc_fc   <= "001";
        wait_cycles(1);
        ptest_atc_req  <= '0';

        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '0' report "Expected ATC miss" severity error;

        ---------------------------------------------------------------
        -- Test 3: PFLUSH FC (supervisor data = 101)
        ---------------------------------------------------------------
        report_test("PFLUSH FC - flush supervisor data entries");
        pflush_inv_req  <= '1';
        pflush_inv_mode <= "10";  -- FC only
        pflush_inv_fc   <= "101"; -- Supervisor data
        wait_cycles(1);
        pflush_inv_req  <= '0';
        wait until pflush_inv_ack = '1';
        wait_cycles(2);

        -- Verify entry 2 and 5 flushed (supervisor data)
        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"11000000";
        ptest_atc_fc   <= "101";
        wait_cycles(1);
        ptest_atc_req  <= '0';
        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '0' report "Expected entry 2 flushed" severity error;

        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"14000000";
        ptest_atc_fc   <= "101";
        wait_cycles(1);
        ptest_atc_req  <= '0';
        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '0' report "Expected entry 5 flushed" severity error;

        -- Verify entry 1 NOT flushed (user data)
        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"10000000";
        ptest_atc_fc   <= "001";
        wait_cycles(1);
        ptest_atc_req  <= '0';
        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '1' report "Expected entry 1 to remain" severity error;

        ---------------------------------------------------------------
        -- Test 4: PFLUSH FC,EA (specific address)
        ---------------------------------------------------------------
        report_test("PFLUSH FC,EA - flush specific address");
        pflush_inv_req  <= '1';
        pflush_inv_mode <= "01";  -- FC + EA
        pflush_inv_fc   <= "001";
        pflush_inv_addr <= X"10000000";
        wait_cycles(1);
        pflush_inv_req  <= '0';
        wait until pflush_inv_ack = '1';
        wait_cycles(2);

        -- Verify entry 1 flushed
        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"10000000";
        ptest_atc_fc   <= "001";
        wait_cycles(1);
        ptest_atc_req  <= '0';
        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '0' report "Expected entry 1 flushed" severity error;

        -- Verify entry 3 and 4 still present (different addresses)
        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"12000000";
        ptest_atc_fc   <= "110";
        wait_cycles(1);
        ptest_atc_req  <= '0';
        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '1' report "Expected entry 3 to remain" severity error;

        ---------------------------------------------------------------
        -- Test 5: PFLUSHA - flush all entries
        ---------------------------------------------------------------
        report_test("PFLUSHA - flush all entries");
        pflush_inv_req  <= '1';
        pflush_inv_mode <= "00";  -- Flush all
        wait_cycles(1);
        pflush_inv_req  <= '0';
        wait until pflush_inv_ack = '1';
        wait_cycles(2);

        -- Verify all entries flushed
        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"12000000";
        ptest_atc_fc   <= "110";
        wait_cycles(1);
        ptest_atc_req  <= '0';
        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '0' report "Expected entry 3 flushed" severity error;

        ptest_atc_req  <= '1';
        ptest_atc_addr <= X"13000000";
        ptest_atc_fc   <= "010";
        wait_cycles(1);
        ptest_atc_req  <= '0';
        wait until ptest_atc_done = '1';
        wait_cycles(1);
        assert ptest_atc_hit = '0' report "Expected entry 4 flushed" severity error;

        ---------------------------------------------------------------
        -- Test 6: PTEST with table walk (simulated)
        ---------------------------------------------------------------
        report_test("PTEST with table walk");
        ptest_walk_req   <= '1';
        ptest_walk_level <= "000";
        ptest_walk_fc    <= "001";
        ptest_walk_addr  <= X"50000000";
        ptest_walk_rw    <= '0';
        wait_cycles(1);
        ptest_walk_req   <= '0';

        -- Simulate MMU response
        wait until mmu_trans_req = '1';
        wait_cycles(3);  -- Simulate translation time
        mmu_trans_ready <= '1';
        mmu_phys_addr   <= X"60000000";
        mmu_status      <= X"0008";  -- Some status bits
        wait_cycles(1);
        mmu_trans_ready <= '0';

        wait until ptest_walk_done = '1';
        wait_cycles(1);
        assert ptest_walk_result(3) = '1' report "Expected MMUSR bit 3 set" severity error;

        ---------------------------------------------------------------
        -- All tests complete
        ---------------------------------------------------------------
        wait_cycles(5);
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);
        write(l, string'("All MMU Instruction Integration tests passed!"));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);

        test_done <= true;
        wait;
    end process;

end architecture testbench;
