-- tb_lockup_cache_fill.vhd
-- Testbench for CRITICAL ISSUE #5: Cache Fill Can Starve Walker
-- Tests that cache fills don't indefinitely block page table walker
-- Reproduces deadlock when cache fill hits slow memory while walker needs bus

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_lockup_cache_fill is
end tb_lockup_cache_fill;

architecture behavior of tb_lockup_cache_fill is

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length/4 - 1) loop
            nibble := value(value'length - 1 - i*4 downto value'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    component TG68K_PMMU_030
        port(
          clk            : in  std_logic;
          nreset         : in  std_logic;
          reg_we         : in  std_logic;
          reg_re         : in  std_logic;
          reg_sel        : in  std_logic_vector(4 downto 0);
          reg_wdat       : in  std_logic_vector(31 downto 0);
          reg_rdat       : out std_logic_vector(31 downto 0);
          reg_part       : in  std_logic;
          reg_fd         : in  std_logic;
          ptest_req      : in  std_logic;
          pflush_req     : in  std_logic;
          pload_req      : in  std_logic;
          pmmu_fc        : in  std_logic_vector(2 downto 0);
          pmmu_addr      : in  std_logic_vector(31 downto 0);
          pmmu_brief     : in  std_logic_vector(15 downto 0);
          req            : in  std_logic;
          is_insn        : in  std_logic;
          rw             : in  std_logic;
          fc             : in  std_logic_vector(2 downto 0);
          addr_log       : in  std_logic_vector(31 downto 0);
          addr_phys      : out std_logic_vector(31 downto 0);
          cache_inhibit  : out std_logic;
          write_protect  : out std_logic;
          fault          : out std_logic;
          fault_status   : out std_logic_vector(31 downto 0);
          tc_enable      : out std_logic;
          mem_req        : buffer std_logic;
          mem_we         : out std_logic;
          mem_addr       : out std_logic_vector(31 downto 0);
          mem_wdat       : out std_logic_vector(31 downto 0);
          mem_ack        : in  std_logic;
          mem_berr       : in  std_logic;
          mem_rdat       : in  std_logic_vector(31 downto 0);
          busy           : out std_logic;
          mmu_config_err : out std_logic;
          mmu_config_ack : in  std_logic
        );
    end component;

    constant clk_period : time := 10 ns;
    constant CACHE_LINE_WORDS : integer := 8;  -- 68030 cache fills 8 words sequentially

    signal clk : std_logic := '0';
    signal nreset : std_logic := '0';
    signal reg_we : std_logic := '0';
    signal reg_re : std_logic := '0';
    signal reg_sel : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat : std_logic_vector(31 downto 0);
    signal reg_part : std_logic := '0';
    signal reg_fd : std_logic := '0';
    signal ptest_req : std_logic := '0';
    signal pflush_req : std_logic := '0';
    signal pload_req : std_logic := '0';
    signal pmmu_fc : std_logic_vector(2 downto 0) := (others => '0');
    signal pmmu_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');
    signal req : std_logic := '0';
    signal is_insn : std_logic := '0';
    signal rw : std_logic := '1';
    signal fc : std_logic_vector(2 downto 0) := "101";
    signal addr_log : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys : std_logic_vector(31 downto 0);
    signal cache_inhibit : std_logic;
    signal write_protect : std_logic;
    signal fault : std_logic;
    signal fault_status : std_logic_vector(31 downto 0);
    signal tc_enable : std_logic;
    signal mem_req : std_logic;
    signal mem_we : std_logic;
    signal mem_addr : std_logic_vector(31 downto 0);
    signal mem_wdat : std_logic_vector(31 downto 0);
    signal mem_ack : std_logic := '0';
    signal mem_berr : std_logic := '0';
    signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
    signal busy : std_logic;
    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';
    signal test_running : boolean := true;

    -- Cache fill simulation
    signal cache_fill_start : boolean := false;  -- Control signal from stim
    signal cache_fill_active : boolean := false;  -- Status from cache_fill_proc
    signal cache_fill_count : integer := 0;
    signal cache_fill_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal cache_fill_req : std_logic := '0';
    signal cache_fill_ack : std_logic := '0';
    signal cache_fill_slow_memory : boolean := false;  -- Simulates slow RAM during fill

    -- Bus arbiter
    signal bus_grant_walker : boolean := false;
    signal bus_grant_cache : boolean := false;
    signal walker_starved : boolean := false;
    signal walker_starvation_count : integer := 0;

    type mem_array_t is array (0 to 1023) of std_logic_vector(31 downto 0);
    signal memory : mem_array_t := (others => (others => '0'));

begin

    uut: TG68K_PMMU_030 port map (
        clk => clk,
        nreset => nreset,
        reg_we => reg_we,
        reg_re => reg_re,
        reg_sel => reg_sel,
        reg_wdat => reg_wdat,
        reg_rdat => reg_rdat,
        reg_part => reg_part,
        reg_fd => reg_fd,
        ptest_req => ptest_req,
        pflush_req => pflush_req,
        pload_req => pload_req,
        pmmu_fc => pmmu_fc,
        pmmu_addr => pmmu_addr,
        pmmu_brief => pmmu_brief,
        req => req,
        is_insn => is_insn,
        rw => rw,
        fc => fc,
        addr_log => addr_log,
        addr_phys => addr_phys,
        cache_inhibit => cache_inhibit,
        write_protect => write_protect,
        fault => fault,
        fault_status => fault_status,
        tc_enable => tc_enable,
        mem_req => mem_req,
        mem_we => mem_we,
        mem_addr => mem_addr,
        mem_wdat => mem_wdat,
        mem_ack => mem_ack,
        mem_berr => mem_berr,
        mem_rdat => mem_rdat,
        busy => busy,
        mmu_config_err => mmu_config_err,
        mmu_config_ack => mmu_config_ack
    );

    clk_process :process
    begin
        while test_running loop
            clk <= '0';
            wait for clk_period/2;
            clk <= '1';
            wait for clk_period/2;
        end loop;
        wait;
    end process;

    -- Bus arbiter simulation
    -- Implements priority: cache fill > walker (wrong priority, causes starvation)
    bus_arbiter_proc: process(clk)
    begin
        if rising_edge(clk) then
            -- Default: no grants
            bus_grant_walker <= false;
            bus_grant_cache <= false;

            -- CRITICAL: Cache fill gets priority (THIS IS THE BUG)
            -- If cache fill is active, it starves the walker
            if cache_fill_active and cache_fill_req = '1' then
                bus_grant_cache <= true;
                bus_grant_walker <= false;

                if mem_req = '1' then
                    -- Walker is being starved
                    walker_starved <= true;
                    walker_starvation_count <= walker_starvation_count + 1;
                end if;
            elsif mem_req = '1' then
                -- Walker gets bus
                bus_grant_walker <= true;
                bus_grant_cache <= false;
                walker_starved <= false;
            else
                walker_starved <= false;
            end if;
        end if;
    end process;

    -- Memory controller
    mem_controller_proc: process(clk)
        variable access_delay : integer := 0;
        variable slow_delay_counter : integer := 0;
    begin
        if rising_edge(clk) then
            mem_ack <= '0';
            cache_fill_ack <= '0';

            if bus_grant_cache then
                -- Cache fill access
                if cache_fill_slow_memory then
                    -- Simulate VERY slow memory during cache fill (graphical RAM collision)
                    if slow_delay_counter < 20 then
                        slow_delay_counter := slow_delay_counter + 1;
                    else
                        cache_fill_ack <= '1';
                        slow_delay_counter := 0;
                    end if;
                else
                    -- Normal cache fill
                    if access_delay < 2 then
                        access_delay := access_delay + 1;
                    else
                        cache_fill_ack <= '1';
                        access_delay := 0;
                    end if;
                end if;
            elsif bus_grant_walker then
                -- Walker access
                if access_delay < 2 then
                    access_delay := access_delay + 1;
                else
                    mem_ack <= '1';
                    mem_rdat <= memory(to_integer(unsigned(mem_addr(9 downto 0))));
                    access_delay := 0;
                end if;
            else
                access_delay := 0;
                slow_delay_counter := 0;
            end if;
        end if;
    end process;

    -- Cache fill state machine (simulates 8-word burst read)
    cache_fill_proc: process(clk)
    begin
        if rising_edge(clk) then
            -- Start fill when requested
            if cache_fill_start and not cache_fill_active then
                cache_fill_active <= true;
                cache_fill_count <= 0;
            end if;

            if cache_fill_active then
                cache_fill_req <= '1';

                if cache_fill_ack = '1' then
                    if cache_fill_count < CACHE_LINE_WORDS - 1 then
                        cache_fill_count <= cache_fill_count + 1;
                        cache_fill_addr <= std_logic_vector(unsigned(cache_fill_addr) + 2);
                    else
                        -- Fill complete
                        cache_fill_active <= false;
                        cache_fill_count <= 0;
                        cache_fill_req <= '0';
                    end if;
                end if;
            else
                cache_fill_req <= '0';
            end if;
        end if;
    end process;

    -- Main stimulus
    stim_proc: process
        variable l : line;
        variable cycle_count : integer := 0;
        variable max_starvation : integer := 0;
    begin
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Cache Fill Starvation Test"));
        writeline(output, l);
        write(l, string'("Tests CRITICAL ISSUE #5"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        wait for clk_period;
        nreset <= '1';
        wait for clk_period * 2;

        -- Setup page table
        for i in 0 to 31 loop
            memory(i) <= x"80000000" or std_logic_vector(to_unsigned(i * 4096, 32));
        end loop;

        -- Enable MMU
        reg_sel <= "10000";  -- TC
        reg_wdat <= x"80800000";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- Setup CRP
        reg_sel <= "10011";
        reg_part <= '0';
        reg_wdat <= x"00000000";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        reg_part <= '1';
        reg_wdat <= x"00000001";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- TEST 1: Normal walker without cache fill
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 1: Walker Without Cache Fill"));
        writeline(output, l);

        cache_fill_start <= false;
        addr_log <= x"00012340";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while busy = '1' and cycle_count < 100 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Translation completed in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Translation failed"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 2: Walker with normal-speed cache fill
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 2: Walker + Normal Cache Fill"));
        writeline(output, l);

        cache_fill_slow_memory <= false;

        -- Start cache fill
        cache_fill_start <= true;
        cache_fill_addr <= x"10000000";

        wait for clk_period * 2;

        -- Request translation during cache fill
        addr_log <= x"00023450";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        max_starvation := 0;
        while busy = '1' and cycle_count < 200 loop
            if walker_starvation_count > max_starvation then
                max_starvation := walker_starvation_count;
            end if;
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Translation completed with cache fill active"));
            writeline(output, l);
            write(l, string'("  Completion time: " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
            write(l, string'("  Max starvation: " & integer'image(max_starvation) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Translation did not complete, busy=" & std_logic'image(busy)));
            writeline(output, l);
        end if;

        wait for clk_period * 10;
        cache_fill_start <= false;
        wait for clk_period * 10;

        -- TEST 3: CRITICAL - Walker with SLOW cache fill
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 3: CRITICAL - Walker + Slow Cache Fill"));
        writeline(output, l);
        write(l, string'("Simulating cache fill from slow graphical RAM..."));
        writeline(output, l);

        cache_fill_slow_memory <= true;

        -- Start slow cache fill
        cache_fill_start <= true;
        cache_fill_addr <= x"20000000";

        wait for clk_period * 2;

        -- Request translation during slow cache fill
        addr_log <= x"00034560";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        max_starvation := 0;
        while cycle_count < 500 loop
            if walker_starvation_count > max_starvation then
                max_starvation := walker_starvation_count;
            end if;

            if busy = '0' then
                exit;
            end if;

            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '1' and max_starvation > 100 then
            write(l, string'("  FAIL: DEADLOCK - Walker starved by slow cache fill"));
            writeline(output, l);
            write(l, string'("  Walker blocked for " & integer'image(max_starvation) & " cycles"));
            writeline(output, l);
            write(l, string'("  This confirms CRITICAL ISSUE #5!"));
            writeline(output, l);
        elsif busy = '0' and max_starvation > 50 then
            write(l, string'("  WARNING: Severe starvation but eventual recovery"));
            writeline(output, l);
            write(l, string'("  Starvation time: " & integer'image(max_starvation) & " cycles"));
            writeline(output, l);
            write(l, string'("  Completion time: " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        elsif busy = '0' then
            write(l, string'("  PASS: Walker completed despite slow cache fill"));
            writeline(output, l);
            write(l, string'("  Completion time: " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  UNKNOWN: Test did not complete decisively"));
            writeline(output, l);
        end if;

        cache_fill_start <= false;
        wait for clk_period * 10;

        -- TEST 4: Multiple cache fills
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 4: Multiple Concurrent Cache Fills"));
        writeline(output, l);

        for i in 0 to 2 loop
            cache_fill_slow_memory <= true;

            cache_fill_start <= true;
            cache_fill_addr <= std_logic_vector(to_unsigned(16#30000000# + i * 16#1000#, 32));

            wait for clk_period * 2;

            addr_log <= std_logic_vector(to_unsigned(16#00040000# + i * 8192, 32));
            fc <= "101";
            req <= '1';
            wait for clk_period;
            req <= '0';

            cycle_count := 0;
            while busy = '1' and cycle_count < 300 loop
                wait for clk_period;
                cycle_count := cycle_count + 1;
            end loop;

            cache_fill_start <= false;

            if busy = '1' then
                write(l, string'("  Iteration " & integer'image(i) & ": DEADLOCK"));
                writeline(output, l);
            else
                write(l, string'("  Iteration " & integer'image(i) & ": Completed in " & integer'image(cycle_count) & " cycles"));
                writeline(output, l);
            end if;

            wait for clk_period * 10;
        end loop;

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Cache Fill Starvation Test Complete"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        test_running <= false;
        wait;
    end process;

end behavior;
