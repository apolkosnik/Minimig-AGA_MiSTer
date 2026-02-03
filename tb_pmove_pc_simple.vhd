library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.std_logic_unsigned.all;

entity tb_pmove_pc_simple is
end tb_pmove_pc_simple;

architecture behavior of tb_pmove_pc_simple is
    -- Component declaration
    component TG68KdotC_Kernel
        port(
            clk : in std_logic;
            nReset : in std_logic;
            clkena_in : in std_logic;
            data_read : in std_logic_vector(15 downto 0);
            IPL : in std_logic_vector(2 downto 0);
            IPL_autovector : in std_logic;
            CPU : in std_logic_vector(1 downto 0);
            addr : out std_logic_vector(31 downto 0);
            data_write : out std_logic_vector(15 downto 0);
            nWr : out std_logic;
            nUDS : out std_logic;
            nLDS : out std_logic;
            busstate : out std_logic_vector(1 downto 0);
            nResetOut : out std_logic;
            FC : out std_logic_vector(2 downto 0);
            clr_berr : out std_logic;
            CACR_out : out std_logic_vector(3 downto 0);
            VBR_out : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Signals
    signal clk : std_logic := '0';
    signal nReset : std_logic := '0';
    signal clkena_in : std_logic := '1';
    signal data_read : std_logic_vector(15 downto 0) := (others => '0');
    signal IPL : std_logic_vector(2 downto 0) := "111";
    signal IPL_autovector : std_logic := '0';
    signal CPU : std_logic_vector(1 downto 0) := "11"; -- 68030
    signal addr : std_logic_vector(31 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal nWr : std_logic;
    signal nUDS : std_logic;
    signal nLDS : std_logic;
    signal busstate : std_logic_vector(1 downto 0);
    signal nResetOut : std_logic;
    signal FC : std_logic_vector(2 downto 0);
    signal clr_berr : std_logic;
    signal CACR_out : std_logic_vector(3 downto 0);
    signal VBR_out : std_logic_vector(31 downto 0);

    -- Memory
    type memory_type is array(0 to 16383) of std_logic_vector(15 downto 0);
    signal memory : memory_type := (others => X"4E71");

    -- Test control
    signal test_done : boolean := false;
    signal last_fetch_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal fetch_count : integer := 0;

begin
    -- Clock: 50 MHz
    clk_process: process
    begin
        while not test_done loop
            clk <= '0';
            wait for 10 ns;
            clk <= '1';
            wait for 10 ns;
        end loop;
        wait;
    end process;

    -- DUT
    uut: TG68KdotC_Kernel
        port map (
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_read => data_read,
            IPL => IPL,
            IPL_autovector => IPL_autovector,
            CPU => CPU,
            addr => addr,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            nResetOut => nResetOut,
            FC => FC,
            clr_berr => clr_berr,
            CACR_out => CACR_out,
            VBR_out => VBR_out
        );

    -- Memory initialization
    init_memory: process
    begin
        -- Clear to NOPs
        for i in 0 to 16383 loop
            memory(i) <= X"4E71";
        end loop;

        -- Load test program at word address 0
        -- This will be fetched as the reset vector points to address 0
        memory(0) <= X"203C";  -- MOVE.L #$12345678,D0
        memory(1) <= X"1234";
        memory(2) <= X"5678";
        memory(3) <= X"F010";  -- PMOVE D0,TT0
        memory(4) <= X"0A00";
        memory(5) <= X"2078";  -- MOVEA.L $3000,A0
        memory(6) <= X"3000";
        memory(7) <= X"F028";  -- PMOVE TT0,(4,A0)  <- TEST THIS!
        memory(8) <= X"0A00";  -- Extension word
        memory(9) <= X"0004";  -- Displacement
        memory(10) <= X"4E71"; -- NOP <- Should execute here (PC = $14)
        memory(11) <= X"4AFC"; -- ILLEGAL <- Should NOT reach (PC = $16)

        wait;
    end process;

    -- Memory read
    mem_read: process(clk)
        variable addr_word : integer;
    begin
        if rising_edge(clk) then
            if clkena_in = '1' then
                addr_word := to_integer(unsigned(addr(14 downto 1)));
                if addr_word >= 0 and addr_word < 16384 then
                    data_read <= memory(addr_word);
                else
                    data_read <= X"4E71";
                end if;
            end if;
        end if;
    end process;

    -- Track fetches
    track_fetches: process(clk)
    begin
        if rising_edge(clk) and clkena_in = '1' then
            -- Instruction fetch detected
            if busstate = "01" and addr /= last_fetch_addr then
                report "FETCH " & integer'image(fetch_count) &
                       ": ADDR=$" & integer'image(to_integer(unsigned(addr(15 downto 0)))) &
                       " DATA=$" & integer'image(to_integer(unsigned(data_read))) &
                       " FC=" & integer'image(to_integer(unsigned(FC)));

                last_fetch_addr <= addr;
                fetch_count <= fetch_count + 1;

                -- Check for the critical addresses
                if addr(15 downto 0) = X"0014" then
                    report "*** SUCCESS: PC reached $14 (NOP after PMOVE)";
                    report "*** PMOVE advanced PC by correct amount (6 bytes)";
                elsif addr(15 downto 0) = X"0016" then
                    report "*** FAILURE: PC reached $16 (ILLEGAL)";
                    report "*** PMOVE advanced PC by 8 bytes instead of 6!";
                    report "*** BUG #95 CONFIRMED";
                end if;
            end if;
        end if;
    end process;

    -- Test sequence
    test_seq: process
    begin
        -- Reset
        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        report "========================================";
        report "TEST: PMOVE TT0,(4,A0) PC Increment";
        report "Instruction at $0E: F028 0A00 0004 (6 bytes)";
        report "Expected next PC: $14";
        report "Bug: PC goes to $16";
        report "========================================";

        -- Wait for test to complete or timeout
        wait for 50 us;

        if not test_done then
            report "*** TIMEOUT: Test did not complete";
            report "*** Last fetch: ADDR=$" & integer'image(to_integer(unsigned(last_fetch_addr(15 downto 0))));
        end if;

        test_done <= true;
        wait for 100 ns;
        assert false report "Simulation finished" severity failure;
    end process;

end behavior;
