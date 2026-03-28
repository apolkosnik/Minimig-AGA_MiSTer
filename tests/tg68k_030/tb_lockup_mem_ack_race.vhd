-- tb_lockup_mem_ack_race.vhd
-- Testbench for CRITICAL ISSUE #6: Memory Request Acknowledgment Race
-- Tests that mem_req/mem_ack handshaking doesn't get out of sync
-- Reproduces deadlock when mem_ack pulse is missed due to timing

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_lockup_mem_ack_race is
end tb_lockup_mem_ack_race;

architecture behavior of tb_lockup_mem_ack_race is

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
    signal inject_ack_glitch : boolean := false;
    signal skip_ack_pulse : boolean := false;
    signal double_ack_pulse : boolean := false;
    signal early_ack_pulse : boolean := false;
    signal clear_race_flags : boolean := false;  -- Control from stim_proc

    -- Monitoring (only driven by race_detector_proc)
    signal mem_req_prev : std_logic := '0';
    signal ack_race_detected : boolean := false;
    signal req_without_ack_count : integer := 0;
    signal stuck_req_detected : boolean := false;

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

    -- Memory simulator with controllable ack behavior
    mem_sim_proc: process(clk)
        variable ack_counter : integer := 0;
        variable skip_next : boolean := false;
        variable send_double : boolean := false;
    begin
        if rising_edge(clk) then
            mem_req_prev <= mem_req;

            -- Default: no ack
            mem_ack <= '0';

            -- Test mode: Early ack (before req goes high)
            if early_ack_pulse and mem_req = '0' and mem_req_prev = '0' then
                mem_ack <= '1';  -- Ack when there's no request!
                mem_rdat <= x"DEADBEEF";
            -- Test mode: Skip ack pulse
            elsif skip_ack_pulse and mem_req = '1' and not skip_next then
                skip_next := true;
                mem_ack <= '0';  -- Miss the ack deliberately
            -- Test mode: Double ack pulse
            elsif double_ack_pulse and mem_req = '1' and not send_double then
                mem_ack <= '1';
                mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(7 downto 0))));
                send_double := true;  -- Will send another next cycle
            elsif double_ack_pulse and send_double then
                mem_ack <= '1';  -- Second ack pulse
                send_double := false;
            -- Normal operation
            elsif mem_req = '1' and mem_req_prev = '1' then
                if ack_counter < 2 then
                    ack_counter := ack_counter + 1;
                else
                    if not skip_next then
                        mem_ack <= '1';
                        mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(7 downto 0))));
                    else
                        skip_next := false;
                    end if;
                    ack_counter := 0;
                end if;
            else
                ack_counter := 0;
                skip_next := false;
            end if;
        end if;
    end process;

    -- Race condition detector
    race_detector_proc: process(clk)
    begin
        if rising_edge(clk) then
            -- Clear flags when requested from stim_proc
            if clear_race_flags then
                ack_race_detected <= false;
                stuck_req_detected <= false;
                req_without_ack_count <= 0;
            else
                -- Detect stuck mem_req (request stays high too long without ack)
                if mem_req = '1' and mem_ack = '0' then
                    req_without_ack_count <= req_without_ack_count + 1;

                    if req_without_ack_count > 50 then
                        stuck_req_detected <= true;
                        ack_race_detected <= true;
                    end if;
                else
                    req_without_ack_count <= 0;
                end if;

                -- Detect ack without req (race condition)
                if mem_ack = '1' and mem_req = '0' then
                    ack_race_detected <= true;
                end if;
            end if;
        end if;
    end process;

    -- Main stimulus
    stim_proc: process
        variable l : line;
        variable cycle_count : integer := 0;
        variable test_passed : boolean;
    begin
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Memory Ack Race Condition Test"));
        writeline(output, l);
        write(l, string'("Tests CRITICAL ISSUE #6"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        wait for clk_period;
        nreset <= '1';
        wait for clk_period * 2;

        -- Setup page table
        for i in 0 to 15 loop
            page_table_mem(i) <= x"80000000" or std_logic_vector(to_unsigned(i * 256 + 1, 32));
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

        -- TEST 1: Normal handshaking
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 1: Normal mem_req/mem_ack Handshake"));
        writeline(output, l);

        inject_ack_glitch <= false;
        skip_ack_pulse <= false;
        clear_race_flags <= true;
        wait for clk_period;
        clear_race_flags <= false;

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

        if busy = '0' and fault = '0' and not ack_race_detected then
            write(l, string'("  PASS: Normal handshaking works correctly"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Race detected in normal operation"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 2: CRITICAL - Missed ack pulse
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 2: CRITICAL - Missed ACK Pulse"));
        writeline(output, l);
        write(l, string'("Simulating missed mem_ack due to timing..."));
        writeline(output, l);

        skip_ack_pulse <= true;
        clear_race_flags <= true;
        wait for clk_period;
        clear_race_flags <= false;

        addr_log <= x"00023450";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while cycle_count < 200 loop
            if stuck_req_detected then
                exit;
            end if;

            if busy = '0' then
                exit;
            end if;

            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        skip_ack_pulse <= false;

        if stuck_req_detected then
            write(l, string'("  FAIL: DEADLOCK - mem_req stuck high after missed ack"));
            writeline(output, l);
            write(l, string'("  mem_req was high for " & integer'image(req_without_ack_count) & " cycles"));
            writeline(output, l);
            write(l, string'("  This confirms CRITICAL ISSUE #6!"));
            writeline(output, l);
        elsif busy = '0' and cycle_count < 100 then
            write(l, string'("  PASS: System recovered from missed ack"));
            writeline(output, l);
            write(l, string'("  Recovery time: " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  UNKNOWN: Test timeout or unclear state"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 3: Double ack pulse
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 3: Double ACK Pulse"));
        writeline(output, l);
        write(l, string'("Testing response to spurious ack..."));
        writeline(output, l);

        double_ack_pulse <= true;
        clear_race_flags <= true;
        wait for clk_period;
        clear_race_flags <= false;

        addr_log <= x"00034560";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while busy = '1' and cycle_count < 150 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        double_ack_pulse <= false;

        if busy = '1' then
            write(l, string'("  FAIL: Double ack caused deadlock"));
            writeline(output, l);
        elsif ack_race_detected then
            write(l, string'("  WARNING: Race detected but system recovered"));
            writeline(output, l);
        else
            write(l, string'("  PASS: Double ack handled correctly"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 4: Early ack pulse (before request)
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 4: Early ACK Pulse"));
        writeline(output, l);
        write(l, string'("Testing ack before req (timing glitch)..."));
        writeline(output, l);

        early_ack_pulse <= true;
        wait for clk_period * 3;
        early_ack_pulse <= false;

        clear_race_flags <= true;
        wait for clk_period;
        clear_race_flags <= false;

        addr_log <= x"00045670";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while busy = '1' and cycle_count < 150 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '1' or stuck_req_detected then
            write(l, string'("  FAIL: Early ack caused deadlock"));
            writeline(output, l);
        else
            write(l, string'("  PASS: Early ack ignored correctly"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 5: Rapid sequential requests
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 5: Rapid Sequential Requests"));
        writeline(output, l);
        write(l, string'("Stress testing handshake protocol..."));
        writeline(output, l);

        test_passed := true;

        for i in 0 to 9 loop
            clear_race_flags <= true;
            wait for clk_period;
            clear_race_flags <= false;

            addr_log <= std_logic_vector(to_unsigned(16#00050000# + i * 4096, 32));
            fc <= "101";
            req <= '1';
            wait for clk_period;
            req <= '0';

            cycle_count := 0;
            while busy = '1' and cycle_count < 100 loop
                if stuck_req_detected then
                    write(l, string'("  Iteration " & integer'image(i) & ": DEADLOCK"));
                    writeline(output, l);
                    test_passed := false;
                    exit;
                end if;

                wait for clk_period;
                cycle_count := cycle_count + 1;
            end loop;

            if stuck_req_detected or busy = '1' then
                test_passed := false;
                exit;
            end if;

            wait for clk_period;
        end loop;

        if test_passed then
            write(l, string'("  PASS: All rapid requests completed correctly"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Handshake failure in rapid requests"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 6: Interleaved requests with varying delays
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 6: Varied Timing Patterns"));
        writeline(output, l);

        for i in 0 to 4 loop
            clear_race_flags <= true;
            wait for clk_period;
            clear_race_flags <= false;

            addr_log <= std_logic_vector(to_unsigned(16#00060000# + i * 8192, 32));
            fc <= "101";
            req <= '1';
            wait for clk_period;
            req <= '0';

            -- Variable wait before checking completion
            wait for clk_period * (5 + i * 3);

            cycle_count := 0;
            while busy = '1' and cycle_count < 100 loop
                wait for clk_period;
                cycle_count := cycle_count + 1;
            end loop;

            if stuck_req_detected or busy = '1' then
                write(l, string'("  Pattern " & integer'image(i) & ": FAIL"));
                writeline(output, l);
            else
                write(l, string'("  Pattern " & integer'image(i) & ": PASS"));
                writeline(output, l);
            end if;

            wait for clk_period * 5;
        end loop;

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Memory Ack Race Test Complete"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        test_running <= false;
        wait;
    end process;

end behavior;
