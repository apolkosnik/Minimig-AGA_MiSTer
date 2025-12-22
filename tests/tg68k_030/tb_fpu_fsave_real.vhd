--------------------------------------------------------------------------------
-- TG68K FPU FSAVE Real Integration Test
-- Tests FTST + FSAVE sequence using complete TG68K component
-- This tests the ACTUAL CPU with FPU, PMMU, and Cache - not simplified logic
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_fpu_fsave_real is
end tb_fpu_fsave_real;

architecture behavior of tb_fpu_fsave_real is

    -- TG68K component (complete CPU with PMMU, Cache, FPU)
    component TG68K
        generic(
            CPU : std_logic_vector(1 downto 0) := "01";
            FPU_Enable : integer := 1
        );
        port(
            CLK : in std_logic;
            RESET : inout std_logic;
            HALT : inout std_logic;
            BERR : in std_logic;
            IPL : in std_logic_vector(2 downto 0);
            ADDR : buffer std_logic_vector(31 downto 0);
            FC : out std_logic_vector(2 downto 0);
            DATA : inout std_logic_vector(15 downto 0);
            AS : out std_logic;
            UDS : out std_logic;
            LDS : out std_logic;
            RW : out std_logic;
            DTACK : in std_logic;
            E : out std_logic;
            VPA : in std_logic;
            VMA : out std_logic;
            cache_req : buffer std_logic;
            cache_addr : buffer std_logic_vector(31 downto 0);
            cache_data : in  std_logic_vector(15 downto 0);
            cache_ack : in  std_logic;
            cache_burst : buffer std_logic;
            cache_burst_len : buffer std_logic_vector(2 downto 0);
            cache_hit : out std_logic;
            cache_miss : out std_logic
        );
    end component;

    -- Clock and basic signals
    constant clk_period : time := 20 ns;
    signal CLK : std_logic := '0';
    signal RESET : std_logic := 'H';
    signal HALT : std_logic := 'H';
    signal BERR : std_logic := '1';
    signal IPL : std_logic_vector(2 downto 0) := "111";
    signal ADDR : std_logic_vector(31 downto 0) := (others => '0');
    signal FC : std_logic_vector(2 downto 0) := (others => '0');
    signal DATA : std_logic_vector(15 downto 0) := (others => 'Z');
    signal AS : std_logic := '1';
    signal UDS : std_logic := '1';
    signal LDS : std_logic := '1';
    signal RW : std_logic := '1';
    signal DTACK : std_logic := '1';
    signal E : std_logic := '1';
    signal VPA : std_logic := '1';
    signal VMA : std_logic := '1';

    -- Cache signals
    signal cache_req : std_logic := '0';
    signal cache_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal cache_data : std_logic_vector(15 downto 0) := X"0000";
    signal cache_ack : std_logic := '0';
    signal cache_burst : std_logic := '0';
    signal cache_burst_len : std_logic_vector(2 downto 0) := "000";
    signal cache_hit : std_logic := '0';
    signal cache_miss : std_logic := '0';

    -- Memory simulation
    type memory_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    signal memory : memory_t := (others => X"4E71");  -- Fill with NOPs

    -- Test control
    signal test_running : boolean := true;
    signal memory_accesses : integer := 0;
    signal total_cycles : integer := 0;

    -- Test state tracking
    signal ftst_fetched : boolean := false;
    signal fsave_fetched : boolean := false;
    signal fsave_writes : integer := 0;
    signal first_fsave_word : std_logic_vector(15 downto 0) := X"0000";

begin

    -- Instantiate 68030 CPU with FPU
    cpu: TG68K
        generic map(
            CPU => "11",       -- 68030 mode
            FPU_Enable => 1    -- FPU enabled
        )
        port map(
            CLK => CLK,
            RESET => RESET,
            HALT => HALT,
            BERR => BERR,
            IPL => IPL,
            ADDR => ADDR,
            FC => FC,
            DATA => DATA,
            AS => AS,
            UDS => UDS,
            LDS => LDS,
            RW => RW,
            DTACK => DTACK,
            E => E,
            VPA => VPA,
            VMA => VMA,
            cache_req => cache_req,
            cache_addr => cache_addr,
            cache_data => cache_data,
            cache_ack => cache_ack,
            cache_burst => cache_burst,
            cache_burst_len => cache_burst_len,
            cache_hit => cache_hit,
            cache_miss => cache_miss
        );

    -- Clock generation
    clk_process: process
    begin
        while test_running loop
            CLK <= '0';
            wait for clk_period/2;
            CLK <= '1';
            wait for clk_period/2;
            total_cycles <= total_cycles + 1;
        end loop;
        wait;
    end process;

    -- Initialize memory with test program
    init_memory: process
    begin
        -- Reset vectors
        memory(0) <= X"0000";   -- Initial SP (high word)
        memory(1) <= X"2000";   -- Initial SP (low word)
        memory(2) <= X"0000";   -- Initial PC (high word)
        memory(3) <= X"0100";   -- Initial PC (low word) = 0x100

        -- Program at 0x100
        -- FTST.B D0 = F201 583A
        memory(128) <= X"F201";
        memory(129) <= X"583A";

        -- FSAVE -(A7) = F327
        memory(130) <= X"F327";

        -- STOP #$2700
        memory(131) <= X"4E72";
        memory(132) <= X"2700";

        wait;
    end process;

    -- Memory interface
    memory_interface: process(CLK)
        variable addr_int : integer;
        variable data_out : std_logic_vector(15 downto 0);
        variable prev_as : std_logic := '1';
    begin
        if falling_edge(CLK) then
            prev_as := AS;

            -- Default: no acknowledge
            DTACK <= '1';
            DATA <= (others => 'Z');

            if AS = '0' and (UDS = '0' or LDS = '0') then
                addr_int := to_integer(unsigned(ADDR(13 downto 1)));

                if addr_int < 8192 then
                    if RW = '1' then
                        -- Read cycle
                        data_out := memory(addr_int);
                        DATA <= data_out;
                        DTACK <= '0';
                        if prev_as = '1' then
                            memory_accesses <= memory_accesses + 1;
                        end if;
                    else
                        -- Write cycle
                        if UDS = '0' then
                            memory(addr_int)(15 downto 8) <= DATA(15 downto 8);
                        end if;
                        if LDS = '0' then
                            memory(addr_int)(7 downto 0) <= DATA(7 downto 0);
                        end if;
                        DTACK <= '0';
                        if prev_as = '1' then
                            memory_accesses <= memory_accesses + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Monitor test execution
    test_monitor: process(CLK)
        variable write_count : integer := 0;
    begin
        if rising_edge(CLK) then
            if AS = '0' and RW = '1' and FC = "010" then  -- Program fetch
                if ADDR(15 downto 0) = X"0100" and not ftst_fetched then
                    report "Fetching FTST.B instruction at 0x100";
                    ftst_fetched <= true;
                elsif ADDR(15 downto 0) = X"0104" and ftst_fetched and not fsave_fetched then
                    report "Fetching FSAVE instruction at 0x104";
                    fsave_fetched <= true;
                elsif ADDR(15 downto 0) = X"0106" and fsave_fetched then
                    report "Fetching STOP instruction - test sequence complete";
                end if;
            end if;

            -- Monitor FSAVE stack writes
            if AS = '0' and RW = '0' then  -- Write cycle
                if FC = "101" or FC = "110" then  -- Supervisor stack
                    if fsave_fetched then
                        if fsave_writes = 0 then
                            first_fsave_word <= DATA;
                            report "FSAVE first word write: " &
                                   integer'image(to_integer(unsigned(DATA))) &
                                   " to address " &
                                   integer'image(to_integer(unsigned(ADDR)));
                        end if;
                        fsave_writes <= fsave_writes + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Test control process
    test_control: process
        variable frame_format : std_logic_vector(7 downto 0);
        variable frame_size : integer;
        variable test_pass : boolean := false;
    begin
        -- Assert reset
        RESET <= '0';
        wait for 100 ns;
        RESET <= 'H';  -- Release reset
        wait for 50 ns;

        report "========== FPU FSAVE Real Integration Test ==========";
        report "Testing FTST + FSAVE with complete TG68K (FPU+PMMU+Cache)";
        report "====================================================";

        -- Wait for test to complete or timeout
        for i in 1 to 100000 loop
            wait for clk_period;

            -- Check if we've written FSAVE frame
            if fsave_writes >= 2 then
                -- Extract frame format from first word (upper byte)
                frame_format := first_fsave_word(15 downto 8);

                -- Calculate frame size from number of writes
                frame_size := fsave_writes * 2;  -- 2 bytes per word write

                report "====================================================";
                report "FSAVE frame written:";
                report "  Frame format: 0x" & integer'image(to_integer(unsigned(frame_format)));
                report "  Frame size: " & integer'image(frame_size) & " bytes";
                report "  Number of writes: " & integer'image(fsave_writes);
                report "====================================================";

                -- Check result
                if frame_format = X"60" and frame_size = 60 then
                    report "*** PASS: IDLE frame (0x60, 60 bytes) ***";
                    report "*** DiagROM will detect MC68882 FPU ***";
                    test_pass := true;
                elsif frame_format = X"00" and frame_size = 4 then
                    report "*** FAIL: NULL frame (0x00, 4 bytes) ***";
                    report "*** FTST did not set FPSR - FPU not working ***";
                    test_pass := false;
                else
                    report "*** UNEXPECTED: Frame format=0x" &
                           integer'image(to_integer(unsigned(frame_format))) &
                           " size=" & integer'image(frame_size) & " bytes ***";
                    test_pass := false;
                end if;

                exit;
            end if;

            if i = 100000 then
                report "*** TIMEOUT: FSAVE did not complete in 100000 cycles ***" severity error;
                test_pass := false;
            end if;
        end loop;

        report "====================================================";
        report "Test statistics:";
        report "  Total cycles: " & integer'image(total_cycles);
        report "  Memory accesses: " & integer'image(memory_accesses);
        report "====================================================";

        test_running <= false;

        if test_pass then
            report "TEST PASSED" severity note;
        else
            report "TEST FAILED" severity error;
        end if;

        wait;
    end process;

end behavior;
