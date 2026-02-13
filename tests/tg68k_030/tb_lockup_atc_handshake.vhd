-- tb_lockup_atc_handshake.vhd
-- Testbench for CRITICAL ISSUE #4: ATC Completion Handshake Deadlock
-- Tests that walker_completed pulse is properly caught by translation process
-- Reproduces deadlock when translation process is stalled during 1-cycle pulse

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_lockup_atc_handshake is
end tb_lockup_atc_handshake;

architecture behavior of tb_lockup_atc_handshake is

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
    signal inject_ack_delay : boolean := false;
    signal ack_delay_cycles : integer := 0;
    signal completion_pulse_missed : boolean := false;  -- Set by completion_monitor_proc
    signal clear_completion_flag : boolean := false;     -- Control from stim_proc

    -- Monitoring signals
    signal busy_history : std_logic_vector(15 downto 0) := (others => '0');
    signal mem_req_history : std_logic_vector(15 downto 0) := (others => '0');

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

    -- Memory simulator with controllable delays
    mem_sim_proc: process(clk)
        variable delay_counter : integer := 0;
    begin
        if rising_edge(clk) then
            -- Shift history for debugging
            busy_history <= busy_history(14 downto 0) & busy;
            mem_req_history <= mem_req_history(14 downto 0) & mem_req;

            mem_ack <= '0';

            if mem_req = '1' then
                if inject_ack_delay and delay_counter < ack_delay_cycles then
                    -- Inject delay to test handshake timing
                    delay_counter := delay_counter + 1;
                    mem_ack <= '0';
                else
                    -- Respond
                    mem_ack <= '1';
                    mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(7 downto 0))));
                    delay_counter := 0;
                end if;
            else
                delay_counter := 0;
            end if;
        end if;
    end process;

    -- Detect missed completion pulse
    -- This simulates the condition where walker_completed='1' for 1 cycle
    -- but translation process doesn't catch it
    completion_monitor_proc: process(clk)
        variable busy_prev : std_logic := '0';
        variable req_prev : std_logic := '0';
    begin
        if rising_edge(clk) then
            -- Clear flag when requested from stim_proc
            if clear_completion_flag then
                completion_pulse_missed <= false;
            end if;

            -- Detect pattern: busy goes low while req still high
            -- This indicates internal handshake completion
            if busy_prev = '1' and busy = '0' and req = '1' then
                -- This is suspicious - translation should have been acknowledged
                completion_pulse_missed <= true;
            end if;

            -- Detect stuck busy signal
            if busy = '1' and mem_req = '0' and req = '0' then
                -- Busy high but no active request - deadlock indicator
                completion_pulse_missed <= true;
            end if;

            busy_prev := busy;
            req_prev := req;
        end if;
    end process;

    -- Main stimulus
    stim_proc: process
        variable l : line;
        variable cycle_count : integer := 0;
        variable deadlock_detected : boolean := false;
    begin
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("ATC Completion Handshake Test"));
        writeline(output, l);
        write(l, string'("Tests CRITICAL ISSUE #4"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        wait for clk_period;
        nreset <= '1';
        wait for clk_period * 2;

        -- Setup page table
        page_table_mem(0) <= x"00001000";  -- CRP pointer
        page_table_mem(4) <= x"80000001";  -- Valid root descriptor
        page_table_mem(8) <= x"80002001";  -- Valid pointer descriptor
        page_table_mem(12) <= x"00003001"; -- Page descriptor

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

        -- TEST 1: Normal completion handshake
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 1: Normal Completion Handshake"));
        writeline(output, l);

        inject_ack_delay <= false;
        clear_completion_flag <= true;
        wait for clk_period;
        clear_completion_flag <= false;

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

        if busy = '0' and fault = '0' and not completion_pulse_missed then
            write(l, string'("  PASS: Translation completed normally in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Handshake issue detected"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 2: Delayed memory acknowledgment
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 2: Delayed Memory Response"));
        writeline(output, l);
        write(l, string'("Testing handshake with slow memory..."));
        writeline(output, l);

        inject_ack_delay <= true;
        ack_delay_cycles <= 10;
        clear_completion_flag <= true;
        wait for clk_period;
        clear_completion_flag <= false;

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
            write(l, string'("  PASS: Delayed memory handled correctly"));
            writeline(output, l);
            write(l, string'("  Completion time: " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Handshake failed with delayed memory"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 3: CRITICAL - Rapid sequential translations
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 3: CRITICAL - Rapid Sequential Translations"));
        writeline(output, l);
        write(l, string'("Testing for missed completion pulses..."));
        writeline(output, l);

        inject_ack_delay <= false;
        deadlock_detected := false;

        for i in 0 to 9 loop
            clear_completion_flag <= true;
        wait for clk_period;
        clear_completion_flag <= false;

            addr_log <= std_logic_vector(to_unsigned(16#00030000# + i * 4096, 32));
            fc <= "101";
            req <= '1';
            wait for clk_period;
            req <= '0';

            cycle_count := 0;
            while busy = '1' and cycle_count < 150 loop
                wait for clk_period;
                cycle_count := cycle_count + 1;
            end loop;

            if busy = '1' then
                write(l, string'("  Iteration " & integer'image(i) & ": DEADLOCK after " & integer'image(cycle_count) & " cycles"));
                writeline(output, l);
                write(l, string'("  busy=" & std_logic'image(busy) & ", mem_req=" & std_logic'image(mem_req)));
                writeline(output, l);
                deadlock_detected := true;
                exit;
            elsif completion_pulse_missed then
                write(l, string'("  Iteration " & integer'image(i) & ": Completion pulse issue detected"));
                writeline(output, l);
            else
                write(l, string'("  Iteration " & integer'image(i) & ": OK (" & integer'image(cycle_count) & " cycles)"));
                writeline(output, l);
            end if;

            wait for clk_period * 2;
        end loop;

        if deadlock_detected then
            write(l, string'("  FAIL: Handshake deadlock in rapid translations"));
            writeline(output, l);
            write(l, string'("  This confirms CRITICAL ISSUE #4!"));
            writeline(output, l);
        else
            write(l, string'("  PASS: All rapid translations completed"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 4: Translation with variable delays
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 4: Variable Memory Delays"));
        writeline(output, l);

        inject_ack_delay <= true;

        for i in 0 to 4 loop
            ack_delay_cycles <= i * 5;  -- 0, 5, 10, 15, 20 cycles
            clear_completion_flag <= true;
        wait for clk_period;
        clear_completion_flag <= false;

            addr_log <= std_logic_vector(to_unsigned(16#00040000# + i * 8192, 32));
            fc <= "101";
            req <= '1';
            wait for clk_period;
            req <= '0';

            cycle_count := 0;
            while busy = '1' and cycle_count < 200 loop
                wait for clk_period;
                cycle_count := cycle_count + 1;
            end loop;

            if busy = '1' then
                write(l, string'("  Delay=" & integer'image(ack_delay_cycles) & ": DEADLOCK"));
                writeline(output, l);
            elsif completion_pulse_missed then
                write(l, string'("  Delay=" & integer'image(ack_delay_cycles) & ": Handshake issue (" & integer'image(cycle_count) & " cycles)"));
                writeline(output, l);
            else
                write(l, string'("  Delay=" & integer'image(ack_delay_cycles) & ": OK (" & integer'image(cycle_count) & " cycles)"));
                writeline(output, l);
            end if;

            wait for clk_period * 5;
        end loop;

        wait for clk_period * 10;

        -- TEST 5: Overlapping requests (stress test)
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 5: Overlapping Translation Requests"));
        writeline(output, l);
        write(l, string'("Testing for handshake race conditions..."));
        writeline(output, l);

        inject_ack_delay <= true;
        ack_delay_cycles <= 8;

        for i in 0 to 4 loop
            addr_log <= std_logic_vector(to_unsigned(16#00050000# + i * 4096, 32));
            fc <= "101";
            req <= '1';
            wait for clk_period;
            req <= '0';

            -- Don't wait for completion - issue next request quickly
            wait for clk_period * 15;  -- Shorter than typical translation time

            if busy = '1' then
                write(l, string'("  Iteration " & integer'image(i) & ": Previous translation still busy"));
                writeline(output, l);

                -- Wait for this one to complete
                cycle_count := 0;
                while busy = '1' and cycle_count < 200 loop
                    wait for clk_period;
                    cycle_count := cycle_count + 1;
                end loop;

                if busy = '1' then
                    write(l, string'("  DEADLOCK in overlapping request test"));
                    writeline(output, l);
                    exit;
                end if;
            end if;
        end loop;

        write(l, string'("  Overlapping request test completed"));
        writeline(output, l);

        wait for clk_period * 10;

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("ATC Handshake Test Complete"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        test_running <= false;
        wait;
    end process;

end behavior;
