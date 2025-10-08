-- WF68K30L Boot Test in VHDL
-- Tests actual WF68K30L core startup with HALT fix

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity test_wf68k30l_boot_vhdl is
end test_wf68k30l_boot_vhdl;

architecture testbench of test_wf68k30l_boot_vhdl is
    -- Clock and reset
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';

    -- CPU signals
    signal cpu_addr : std_logic_vector(31 downto 0);
    signal cpu_data_out : std_logic_vector(31 downto 0);
    signal cpu_data_in : std_logic_vector(31 downto 0) := (others => '0');
    signal size : std_logic_vector(1 downto 0);
    signal as_n : std_logic;
    signal rw_n : std_logic;
    signal ds_n : std_logic;
    signal fc : std_logic_vector(2 downto 0);
    signal reset_out : std_logic;
    signal dsack_n : std_logic_vector(1 downto 0) := "11";

    -- Test control
    signal test_complete : boolean := false;
    signal vector_fetches : integer := 0;

    -- Clock period
    constant CLK_PERIOD : time := 20 ns; -- 50MHz

    component WF68K30L_TOP is
        port (
            CLK : in std_logic;
            ADR_OUT : out std_logic_vector(31 downto 0);
            DATA_IN : in std_logic_vector(31 downto 0);
            DATA_OUT : out std_logic_vector(31 downto 0);
            DATA_EN : out std_logic;
            BERRn : in std_logic;
            RESET_INn : in std_logic;
            RESET_OUT : out std_logic;
            HALT_INn : in std_logic;
            HALT_OUTn : out std_logic;
            FC_OUT : out std_logic_vector(2 downto 0);
            AVECn : in std_logic;
            IPLn : in std_logic_vector(2 downto 0);
            DSACKn : in std_logic_vector(1 downto 0);
            SIZE : out std_logic_vector(1 downto 0);
            ASn : out std_logic;
            RWn : out std_logic;
            DSn : out std_logic;
            STERMn : in std_logic;
            BRn : in std_logic;
            BGACKn : in std_logic
        );
    end component;

begin
    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_complete else '0';

    -- CPU instantiation
    cpu: WF68K30L_TOP
        port map (
            CLK => clk,
            ADR_OUT => cpu_addr,
            DATA_IN => cpu_data_in,
            DATA_OUT => cpu_data_out,
            DATA_EN => open,
            BERRn => '1',
            RESET_INn => not reset,
            RESET_OUT => reset_out,
            HALT_INn => '1',  -- HALT fix: keep CPU running!
            HALT_OUTn => open,
            FC_OUT => fc,
            AVECn => '1',
            IPLn => "111",
            DSACKn => dsack_n,
            SIZE => size,
            ASn => as_n,
            RWn => rw_n,
            DSn => ds_n,
            STERMn => '1',
            BRn => '1',
            BGACKn => '1'
        );

    -- Test process
    test_proc: process
    begin
        report "=== WF68K30L Boot Test (VHDL) ===";
        report "Testing HALT fix - CPU should start executing";

        -- Hold reset
        wait for 100 ns;

        -- Release reset
        report "Releasing reset...";
        reset <= '0';

        -- Wait for first bus cycle
        wait for 200 ns;

        if as_n = '0' then
            report "SUCCESS: CPU started! AS is active, address = 0x" &
                   to_hstring(unsigned(cpu_addr));
            report "PASS: HALT fix is working - CPU is executing";
        else
            report "FAIL: CPU did not start - AS still inactive" severity error;
        end if;

        test_complete <= true;
        wait for 50 ns;
        report "Test complete";
        wait;
    end process;

    -- Simple memory model
    mem_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' and as_n = '0' then
                -- Provide reset vectors
                if unsigned(cpu_addr) < 8 then
                    cpu_data_in <= x"00001000";  -- SSP
                    dsack_n <= "00";  -- Longword acknowledge
                    vector_fetches <= vector_fetches + 1;
                else
                    cpu_data_in <= x"4E714E71";  -- NOP NOP
                    dsack_n <= "00";
                end if;
            else
                dsack_n <= "11";  -- No acknowledge
            end if;
        end if;
    end process;

end testbench;
