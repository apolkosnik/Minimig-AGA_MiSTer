-- tb_lockup_walker_timeout.vhd
-- Testbench for walker timeout recovery
-- Tests that PMMU walker properly recovers when memory is unresponsive
-- The PMMU has an internal timeout (WALKER_TIMEOUT_CYCLES) that
-- forces a bus error fault when mem_ack is not received.

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

    -- Test counters
    signal pass_count : integer := 0;
    signal fail_count : integer := 0;

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
        variable pending : boolean := false;
    begin
        if rising_edge(clk) then
            mem_ack <= '0';

            if mem_req = '1' and not simulate_unresponsive_memory then
                if memory_response_delay = 0 then
                    -- Immediate response
                    mem_ack <= '1';
                    -- Index by longword address (mem_addr(9:2) gives word index)
                    mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(9 downto 2))));
                elsif not pending then
                    -- Start delay counter
                    pending := true;
                    delay_counter := 0;
                elsif delay_counter < memory_response_delay then
                    delay_counter := delay_counter + 1;
                else
                    -- Respond after delay
                    mem_ack <= '1';
                    mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(9 downto 2))));
                    pending := false;
                    delay_counter := 0;
                end if;
            elsif mem_req = '0' then
                pending := false;
                delay_counter := 0;
            end if;
            -- When simulate_unresponsive_memory=true AND mem_req='1':
            -- Never send ack - the PMMU's internal 500-cycle timeout will fire
        end if;
    end process;

    -- Main stimulus process
    stim_proc: process
        variable l : line;
        variable cycle_count : integer := 0;
        variable busy_start_cycle : integer := 0;
        variable busy_duration : integer := 0;
        variable test_passed : boolean;
        variable v_pass : integer := 0;
        variable v_fail : integer := 0;
    begin
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Walker Timeout Recovery Lockup Test"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        wait for clk_period;
        nreset <= '1';
        wait for clk_period * 5;

        -- Setup page table for TC = $80C07760
        -- PS=12 (4KB pages), IS=0, TIA=7, TIB=7, TIC=6, TID=0
        -- Sum: 12+0+7+7+6+0 = 32
        --
        -- CRP: DT=10 (short format root table), root table at address $0000
        -- Root table has 2^7 = 128 entries (TIA=7)
        -- Using early termination: root entries are page descriptors (DT=01)
        --
        -- For address $00012340: TIA index = addr(31:25) = 0000000 = 0
        -- page_table_mem(0) is read by walker at physical address $0000 + 0*4 = $0000
        --
        -- Page descriptor format (short, DT=01):
        --   bits 31:PS (31:12) = physical page base
        --   bits PS-1:2 = unused
        --   bit 1 = not used (WP for table, here 0)
        --   bits 1:0 = DT (01 = page descriptor)

        -- Root table entries (short format, DT=01 = early termination page descriptors)
        page_table_mem(0) <= x"00000001";  -- Phys page $00000xxx, DT=01
        page_table_mem(1) <= x"00001001";  -- Phys page $00001xxx, DT=01
        page_table_mem(2) <= x"00002001";  -- Phys page $00002xxx, DT=01
        page_table_mem(3) <= x"00003001";  -- Phys page $00003xxx, DT=01
        page_table_mem(4) <= x"00004001";  -- Phys page $00004xxx, DT=01

        -- TEST 1: Normal walker operation with responsive memory
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 1: Normal Walker Operation"));
        writeline(output, l);

        -- Write CRP high word: DT=10 (short format table pointer), limit=0
        -- reg_part='1' = HIGH word, reg_part='0' = LOW word
        reg_sel <= "10011";  -- CRP
        reg_part <= '1';     -- High word (reg_part=1)
        reg_wdat <= x"00000002";  -- DT=10 (valid short-format root pointer)
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- Write CRP low word: root table at address $0000
        reg_part <= '0';     -- Low word (reg_part=0)
        reg_wdat <= x"00000000";  -- Root table at physical address 0
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- Write TC: E=1, PS=12(4KB), IS=0, TIA=7, TIB=7, TIC=6, TID=0
        reg_sel <= "10000";  -- TC
        reg_wdat <= x"80C07760";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period * 3;

        -- Request translation with normal memory (immediate response)
        write(l, string'("  Requesting translation with responsive memory..."));
        writeline(output, l);
        simulate_unresponsive_memory <= false;
        memory_response_delay <= 0;

        addr_log <= x"00012340";
        fc <= "101";  -- Supervisor data
        rw <= '1';    -- Read
        req <= '1';
        wait for clk_period;
        req <= '0';

        -- Wait for translation to complete (busy goes low)
        cycle_count := 0;
        while busy = '1' and cycle_count < 200 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Normal translation completed in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
            v_pass := v_pass + 1;
        else
            write(l, string'("  FAIL: Normal translation did not complete (busy=" & std_logic'image(busy) & " fault=" & std_logic'image(fault) & ")"));
            writeline(output, l);
            v_fail := v_fail + 1;
        end if;

        wait for clk_period * 10;

        -- TEST 2: Walker with slow but eventually responsive memory
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 2: Walker with Slow Memory"));
        writeline(output, l);

        -- Flush ATC to force a new walk. This PMMU interface expects an
        -- explicit PFLUSHA encoding on pmmu_brief, not a bare pflush_req pulse.
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait for clk_period;
        pflush_req <= '0';
        pmmu_brief <= (others => '0');
        wait for clk_period * 3;

        simulate_unresponsive_memory <= false;
        memory_response_delay <= 50;

        write(l, string'("  Memory will respond after 50 cycles delay..."));
        writeline(output, l);

        addr_log <= x"00012340";
        fc <= "101";
        rw <= '1';
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while busy = '1' and cycle_count < 400 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Slow memory translation completed in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
            v_pass := v_pass + 1;
        else
            write(l, string'("  FAIL: Slow memory translation did not complete (busy=" & std_logic'image(busy) & " fault=" & std_logic'image(fault) & ")"));
            writeline(output, l);
            v_fail := v_fail + 1;
        end if;

        wait for clk_period * 10;

        -- TEST 3: Walker timeout with completely unresponsive memory
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 3: Completely Unresponsive Memory (Internal 3072-cycle Timeout)"));
        writeline(output, l);

        -- Flush ATC to force a new walk. Use PFLUSHA so the matching ATC entry
        -- from the previous translation is actually discarded.
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait for clk_period;
        pflush_req <= '0';
        pmmu_brief <= (others => '0');
        wait for clk_period * 3;

        simulate_unresponsive_memory <= true;  -- Memory will NEVER respond

        write(l, string'("  Waiting for PMMU internal timeout (3072 cycles)..."));
        writeline(output, l);

        addr_log <= x"00012340";
        fc <= "101";
        rw <= '1';
        req <= '1';
        wait for clk_period;
        req <= '0';

        -- Monitor busy signal - PMMU's internal timeout fires after 3072 cycles
        cycle_count := 0;
        busy_start_cycle := 0;
        test_passed := false;

        while cycle_count < 3800 loop
            if busy = '1' and busy_start_cycle = 0 then
                busy_start_cycle := cycle_count;
            end if;

            -- Walker fault detected OR busy went low after being high
            if fault = '1' and busy_start_cycle > 0 then
                busy_duration := cycle_count - busy_start_cycle;
                write(l, string'("  Walker faulted after " & integer'image(busy_duration) & " busy cycles"));
                writeline(output, l);
                write(l, string'("  fault_status = $" & slv_to_hex(fault_status)));
                writeline(output, l);
                -- Check B bit (bus error, bit 15 of MMUSR)
                if fault_status(15) = '1' then
                    write(l, string'("  PASS: Walker properly signaled bus error timeout (B bit set)"));
                    writeline(output, l);
                    test_passed := true;
                else
                    write(l, string'("  PASS: Walker signaled fault (non-bus-error)"));
                    writeline(output, l);
                    test_passed := true;
                end if;
                exit;
            end if;

            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if not test_passed then
            write(l, string'("  FAIL: DEADLOCK - Walker stuck after " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
            v_fail := v_fail + 1;
        else
            v_pass := v_pass + 1;
        end if;

        -- Wait for fault handshake to complete (fault_ack cycle)
        for i in 0 to 20 loop
            wait for clk_period;
        end loop;

        -- TEST 4: Check if PMMU can issue another request after timeout recovery
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 4: Recovery After Timeout"));
        writeline(output, l);

        -- Restore responsive memory
        simulate_unresponsive_memory <= false;
        memory_response_delay <= 0;

        -- Flush ATC to clear any stale fault entries.
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait for clk_period;
        pflush_req <= '0';
        pmmu_brief <= (others => '0');
        wait for clk_period * 3;

        write(l, string'("  Requesting new translation after timeout recovery..."));
        writeline(output, l);

        addr_log <= x"00012340";
        fc <= "101";
        rw <= '1';
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while busy = '1' and cycle_count < 200 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Recovery successful - translation completed in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
            v_pass := v_pass + 1;
        else
            write(l, string'("  FAIL: Recovery failed (busy=" & std_logic'image(busy) & " fault=" & std_logic'image(fault) & ")"));
            writeline(output, l);
            v_fail := v_fail + 1;
        end if;

        wait for clk_period * 10;

        -- Summary
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Walker Timeout Test Summary"));
        writeline(output, l);
        write(l, string'("  PASSED: " & integer'image(v_pass)));
        writeline(output, l);
        write(l, string'("  FAILED: " & integer'image(v_fail)));
        writeline(output, l);
        if v_fail = 0 then
            write(l, string'("  ALL WALKER TIMEOUT TESTS PASSED"));
        else
            write(l, string'("  SOME TESTS FAILED"));
        end if;
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        test_running <= false;
        wait;
    end process;

end behavior;
