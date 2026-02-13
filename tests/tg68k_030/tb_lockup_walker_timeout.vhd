-- tb_lockup_walker_timeout.vhd
-- Testbench for CRITICAL ISSUE #2: Walker Timeout Recovery Incomplete
-- Tests that PMMU walker properly recovers when memory is unresponsive
-- Reproduces deadlock condition where timeout sets error but CPU stays stalled

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_lockup_walker_timeout is
end tb_lockup_walker_timeout;

architecture behavior of tb_lockup_walker_timeout is

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
    constant TIMEOUT_THRESHOLD : integer := 500;  -- Cycles before timeout expected

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

    -- Test control signals
    signal simulate_unresponsive_memory : boolean := false;
    signal memory_response_delay : integer := 0;

    -- Page table in memory (simulated)
    type mem_array_t is array (0 to 255) of std_logic_vector(31 downto 0);
    signal page_table_mem : mem_array_t := (others => (others => '0'));

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

    -- Memory simulator - can delay or ignore responses
    mem_sim_proc: process(clk)
        variable delay_counter : integer := 0;
    begin
        if rising_edge(clk) then
            mem_ack <= '0';

            if mem_req = '1' and not simulate_unresponsive_memory then
                if memory_response_delay = 0 then
                    -- Immediate response
                    mem_ack <= '1';
                    mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(7 downto 0))));
                elsif delay_counter < memory_response_delay then
                    -- Delayed response
                    delay_counter := delay_counter + 1;
                else
                    -- Respond after delay
                    mem_ack <= '1';
                    mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(7 downto 0))));
                    delay_counter := 0;
                end if;
            elsif mem_req = '1' and simulate_unresponsive_memory then
                -- Completely unresponsive - never send ack
                mem_ack <= '0';
            else
                delay_counter := 0;
            end if;
        end if;
    end process;

    -- Main stimulus process
    stim_proc: process
        variable l : line;
        variable cycle_count : integer := 0;
        variable busy_start_cycle : integer := 0;
        variable busy_duration : integer := 0;
        variable test_passed : boolean;
    begin
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Walker Timeout Recovery Lockup Test"));
        writeline(output, l);
        write(l, string'("Tests CRITICAL ISSUE #2"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        wait for clk_period;
        nreset <= '1';
        wait for clk_period * 2;

        -- Setup page table
        page_table_mem(0) <= x"00001000";  -- CRP pointer
        page_table_mem(4) <= x"80000001";  -- Valid descriptor
        page_table_mem(8) <= x"00002001";  -- Page descriptor

        -- TEST 1: Normal walker operation with responsive memory
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 1: Normal Walker Operation"));
        writeline(output, l);
        write(l, string'("Setting up TC and CRP registers..."));
        writeline(output, l);

        -- Write TC (enable MMU, 8KB page size)
        reg_sel <= "10000";  -- TC
        reg_wdat <= x"80800000";  -- E=1, SRE=0, FCL=0, PS=0 (8KB pages)
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- Write CRP high word
        reg_sel <= "10011";  -- CRP
        reg_part <= '0';  -- High word
        reg_wdat <= x"00000000";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- Write CRP low word
        reg_part <= '1';  -- Low word
        reg_wdat <= x"00000001";  -- Valid descriptor, points to address 0
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- Request translation with normal memory
        write(l, string'("Requesting translation with responsive memory..."));
        writeline(output, l);
        simulate_unresponsive_memory <= false;
        memory_response_delay <= 2;  -- Small delay

        addr_log <= x"00012340";
        fc <= "101";  -- Supervisor data
        req <= '1';
        wait for clk_period;
        req <= '0';

        -- Wait for translation to complete
        cycle_count := 0;
        while busy = '1' and cycle_count < 100 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Normal translation completed in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Normal translation did not complete"));
            writeline(output, l);
        end if;

        wait for clk_period * 5;

        -- TEST 2: Walker with slow but eventually responsive memory
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 2: Walker with Slow Memory"));
        writeline(output, l);
        write(l, string'("Memory will respond after 50 cycles delay..."));
        writeline(output, l);

        simulate_unresponsive_memory <= false;
        memory_response_delay <= 50;

        addr_log <= x"00023450";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while busy = '1' and cycle_count < 200 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Slow memory translation completed in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Slow memory translation did not complete, busy=" & std_logic'image(busy)));
            writeline(output, l);
        end if;

        wait for clk_period * 5;

        -- TEST 3: Walker timeout with completely unresponsive memory
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 3: CRITICAL - Completely Unresponsive Memory"));
        writeline(output, l);
        write(l, string'("This tests walker timeout recovery when memory never responds..."));
        writeline(output, l);

        simulate_unresponsive_memory <= true;  -- Memory will NEVER respond

        addr_log <= x"00034560";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        busy_start_cycle := 0;
        test_passed := false;

        -- Monitor busy signal for up to 600 cycles
        while cycle_count < 600 loop
            if busy = '1' and busy_start_cycle = 0 then
                busy_start_cycle := cycle_count;
            end if;

            if busy = '0' and busy_start_cycle > 0 then
                -- Walker recovered!
                busy_duration := cycle_count - busy_start_cycle;
                write(l, string'("  Walker recovered after " & integer'image(busy_duration) & " busy cycles"));
                writeline(output, l);

                if fault = '1' or mem_berr = '1' then
                    write(l, string'("  PASS: Walker properly signaled error (fault=" & std_logic'image(fault) & ")"));
                    writeline(output, l);
                    test_passed := true;
                else
                    write(l, string'("  WARNING: Walker recovered but no fault signaled"));
                    writeline(output, l);
                end if;

                exit;
            end if;

            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if not test_passed and busy = '1' then
            write(l, string'("  FAIL: DEADLOCK DETECTED - Walker stuck busy after " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
            write(l, string'("  This confirms CRITICAL ISSUE #2: Incomplete timeout recovery"));
            writeline(output, l);
        elsif not test_passed then
            write(l, string'("  FAIL: Walker recovered but did not signal fault properly"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 4: Check if CPU can issue another request after timeout
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 4: CPU Recovery After Timeout"));
        writeline(output, l);
        write(l, string'("Attempting new translation after timeout..."));
        writeline(output, l);

        -- Restore responsive memory
        simulate_unresponsive_memory <= false;
        memory_response_delay <= 2;

        addr_log <= x"00045670";
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
            write(l, string'("  PASS: CPU successfully issued new request after timeout recovery"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: CPU cannot recover - system remains deadlocked"));
            writeline(output, l);
            write(l, string'("  This confirms the walker timeout recovery is incomplete!"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Walker Timeout Test Complete"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        test_running <= false;
        wait;
    end process;

end behavior;
