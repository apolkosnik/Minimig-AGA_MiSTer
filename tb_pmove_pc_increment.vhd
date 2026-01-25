library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_pmove_pc_increment is
end tb_pmove_pc_increment;

architecture behavior of tb_pmove_pc_increment is
    -- Component declarations
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

    -- Memory array
    type memory_type is array(0 to 65535) of std_logic_vector(15 downto 0);
    signal memory : memory_type := (others => X"4E71"); -- NOP

    -- PC tracking
    signal last_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal pc_increment : std_logic_vector(31 downto 0) := (others => '0');

    -- Test control
    signal test_done : boolean := false;
    signal instruction_count : integer := 0;

begin
    -- Clock generation (50 MHz)
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

    -- DUT instantiation
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
        -- Initialize all memory to NOP
        for i in 0 to 65535 loop
            memory(i) <= X"4E71"; -- NOP
        end loop;

        -- Program memory starting at $20014 (word address $10010)
        -- $20014: PMOVE TT0,(4,A0)
        memory(16#10010#) <= X"F028";  -- PMOVE opcode with (d16,An) mode
        memory(16#10011#) <= X"0A00";  -- Extension word: TT0, direction bit
        memory(16#10012#) <= X"0004";  -- Displacement: 4

        -- $2001A: NOP (should execute this)
        memory(16#1001A# / 2) <= X"4E71";

        -- $2001C: ILLEGAL (should NOT reach this)
        memory(16#1001C# / 2) <= X"4AFC";

        -- Setup A0 to point to valid memory
        -- We'll use address $3000 as target
        memory(16#1500#) <= X"0000";  -- Will store TT0 value here
        memory(16#1501#) <= X"0000";

        wait;
    end process;

    -- Memory read process
    mem_read: process(clk)
        variable addr_int : integer;
    begin
        if rising_edge(clk) then
            if clkena_in = '1' then
                -- Read from memory (word-addressed)
                addr_int := to_integer(unsigned(addr(16 downto 1)));
                if addr_int >= 0 and addr_int < 65536 then
                    data_read <= memory(addr_int);
                else
                    data_read <= X"4E71"; -- NOP for out of range
                end if;
            end if;
        end if;
    end process;

    -- Memory write process
    mem_write: process(clk)
        variable addr_int : integer;
    begin
        if rising_edge(clk) then
            if clkena_in = '1' and nWr = '0' then
                addr_int := to_integer(unsigned(addr(16 downto 1)));
                if addr_int >= 0 and addr_int < 65536 then
                    if nUDS = '0' and nLDS = '0' then
                        memory(addr_int) <= data_write;
                    elsif nUDS = '0' then
                        memory(addr_int)(15 downto 8) <= data_write(15 downto 8);
                    elsif nLDS = '0' then
                        memory(addr_int)(7 downto 0) <= data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- PC tracking and reporting
    pc_track: process(clk)
    begin
        if rising_edge(clk) then
            if clkena_in = '1' then
                -- Detect PC changes during instruction fetch (busstate = "01")
                if busstate = "01" and addr /= last_addr then
                    pc_increment <= std_logic_vector(unsigned(addr) - unsigned(last_addr));

                    report "PC INCREMENT: " &
                           "From $" & to_hstring(last_addr) &
                           " to $" & to_hstring(addr) &
                           " (+" & integer'image(to_integer(unsigned(addr) - unsigned(last_addr))) & " bytes)" &
                           " FC=" & to_string(FC) &
                           " Data=$" & to_hstring(data_read);

                    last_addr <= addr;
                    instruction_count <= instruction_count + 1;
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
        wait for 100 ns;

        -- Wait for reset to complete
        wait until nResetOut = '1';
        wait for 100 ns;

        report "========================================";
        report "TEST: PMOVE TT0,(4,A0) PC Increment";
        report "========================================";
        report "Instruction at $20014: F028 0A00 0004";
        report "Expected: PC should advance to $2001A (6 bytes)";
        report "Bug: PC advances to $2001C (8 bytes)";
        report "========================================";

        -- Initialize A0 to point to valid memory ($3000 - 4 = $2FFC)
        -- We need to setup A0 via supervisor stack or register manipulation
        -- For simplicity, we'll just let the PMOVE execute and track PC

        -- Set PC to start of test program ($20014)
        -- This requires the CPU to fetch from that address
        -- We'll wait for the CPU to stabilize after reset and then monitor

        -- Wait for 50 instruction fetches to see the PMOVE execution
        for i in 1 to 100 loop
            wait until rising_edge(clk) and clkena_in = '1';

            -- Check if we've reached the ILLEGAL instruction
            if addr = X"0002001C" and busstate = "01" then
                report "========================================";
                report "FAILURE: Reached $2001C (ILLEGAL)";
                report "PC advanced by 8 bytes instead of 6!";
                report "========================================";
                test_done <= true;
                wait for 100 ns;
                assert false report "Test FAILED - PC increment bug confirmed!" severity error;
            end if;

            -- Check if we've reached the NOP at $2001A
            if addr = X"0002001A" and busstate = "01" then
                report "========================================";
                report "SUCCESS: Reached $2001A (NOP)";
                report "PC advanced correctly by 6 bytes!";
                report "========================================";
                test_done <= true;
                wait for 100 ns;
                assert false report "Test PASSED - PC increment correct!" severity note;
            end if;
        end loop;

        if not test_done then
            report "========================================";
            report "TEST INCOMPLETE: Did not reach expected addresses";
            report "Last address: $" & to_hstring(addr);
            report "========================================";
        end if;

        wait for 500 ns;
        test_done <= true;
        wait;
    end process;

end behavior;
