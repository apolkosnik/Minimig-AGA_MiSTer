------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Burst Controller                                                --
--                                                                          --
-- Implements 4-beat burst transfers for cache line fills                  --
--                                                                          --
-- Features:                                                                --
--   - 4-longword burst transfers (16 bytes total)                         --
--   - Address auto-increment (aligned to 16-byte boundary)                --
--   - BURST signal generation                                             --
--   - Early termination on bus error                                      --
--   - Configurable wait states                                            --
--                                                                          --
-- Burst Sequence:                                                          --
--   Beat 1: Address + BURST=1, capture data[0]                           --
--   Beat 2: Address + 4, capture data[1]                                  --
--   Beat 3: Address + 8, capture data[2]                                  --
--   Beat 4: Address + 12, BURST=0, capture data[3]                       --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_BurstController is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Control interface
        burst_req   : in  std_logic;                      -- Request burst transfer
        burst_addr  : in  std_logic_vector(31 downto 0); -- Starting address (unaligned)
        burst_done  : out std_logic;                      -- Burst complete
        burst_error : out std_logic;                      -- Bus error during burst

        -- Bus interface
        bus_addr    : out std_logic_vector(31 downto 0); -- Address to bus
        bus_burst   : out std_logic;                      -- BURST signal
        bus_as      : out std_logic;                      -- Address strobe
        bus_ds      : out std_logic;                      -- Data strobe
        bus_data_in : in  std_logic_vector(31 downto 0); -- Data from bus
        bus_dsack   : in  std_logic_vector(1 downto 0);  -- Data acknowledge
        bus_berr    : in  std_logic;                      -- Bus error

        -- Data output (4 longwords)
        line_data_0 : out std_logic_vector(31 downto 0); -- First longword
        line_data_1 : out std_logic_vector(31 downto 0); -- Second longword
        line_data_2 : out std_logic_vector(31 downto 0); -- Third longword
        line_data_3 : out std_logic_vector(31 downto 0); -- Fourth longword
        line_valid  : out std_logic                       -- All data valid
    );
end entity TG68K030_BurstController;

architecture rtl of TG68K030_BurstController is

    -- Burst state machine
    type state_t is (
        IDLE,           -- Waiting for burst request
        BURST_START,    -- Assert address and BURST
        BURST_WAIT1,    -- Wait for DSACK on beat 1
        BURST_DATA1,    -- Capture data beat 1
        BURST_WAIT2,    -- Wait for DSACK on beat 2
        BURST_DATA2,    -- Capture data beat 2
        BURST_WAIT3,    -- Wait for DSACK on beat 3
        BURST_DATA3,    -- Capture data beat 3
        BURST_WAIT4,    -- Wait for DSACK on beat 4
        BURST_DATA4,    -- Capture data beat 4
        BURST_COMPLETE, -- All beats complete
        BURST_ERROR_ST  -- Bus error occurred
    );
    signal state : state_t;

    -- Address generation
    signal base_addr    : std_logic_vector(31 downto 0); -- Aligned base address
    signal current_addr : std_logic_vector(31 downto 0); -- Current beat address

    -- Data capture registers
    signal data_reg_0 : std_logic_vector(31 downto 0);
    signal data_reg_1 : std_logic_vector(31 downto 0);
    signal data_reg_2 : std_logic_vector(31 downto 0);
    signal data_reg_3 : std_logic_vector(31 downto 0);

    -- Beat counter
    signal beat_count : integer range 0 to 3;

    -- DSACK detection
    signal dsack_asserted : std_logic;

begin

    --------------------------------------------------------------
    -- DSACK Detection
    --------------------------------------------------------------
    -- DSACK is asserted when not "11" (waiting)
    dsack_asserted <= '1' when bus_dsack /= "11" else '0';

    --------------------------------------------------------------
    -- Base Address Calculation
    --------------------------------------------------------------
    -- Align to 16-byte boundary (clear lower 4 bits)
    base_addr <= burst_addr(31 downto 4) & "0000";

    --------------------------------------------------------------
    -- Burst State Machine
    --------------------------------------------------------------
    burst_fsm: process(clk, reset)
    begin
        if reset = '1' then
            state        <= IDLE;
            current_addr <= (others => '0');
            data_reg_0   <= (others => '0');
            data_reg_1   <= (others => '0');
            data_reg_2   <= (others => '0');
            data_reg_3   <= (others => '0');
            beat_count   <= 0;

            bus_as       <= '0';
            bus_ds       <= '0';
            bus_burst    <= '0';
            burst_done   <= '0';
            burst_error  <= '0';
            line_valid   <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            burst_done   <= '0';
            line_valid   <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for burst request
                ------------------------------------------------------
                when IDLE =>
                    if burst_req = '1' then
                        -- Calculate aligned base address
                        current_addr <= base_addr;
                        beat_count   <= 0;
                        burst_error  <= '0';

                        state <= BURST_START;
                    end if;

                ------------------------------------------------------
                -- BURST_START: Assert address and BURST signal
                ------------------------------------------------------
                when BURST_START =>
                    bus_addr  <= current_addr;
                    bus_as    <= '1';
                    bus_ds    <= '1';
                    bus_burst <= '1';  -- Indicate burst transfer

                    state <= BURST_WAIT1;

                ------------------------------------------------------
                -- BURST_WAIT1: Wait for DSACK on beat 1
                ------------------------------------------------------
                when BURST_WAIT1 =>
                    if bus_berr = '1' then
                        -- Bus error, abort burst
                        burst_error <= '1';
                        state       <= BURST_ERROR_ST;

                    elsif dsack_asserted = '1' then
                        -- DSACK received, capture data
                        state <= BURST_DATA1;
                    end if;

                ------------------------------------------------------
                -- BURST_DATA1: Capture data from beat 1
                ------------------------------------------------------
                when BURST_DATA1 =>
                    data_reg_0   <= bus_data_in;
                    current_addr <= std_logic_vector(unsigned(current_addr) + 4);
                    beat_count   <= 1;

                    -- Deassert strobes briefly
                    bus_as <= '0';
                    bus_ds <= '0';

                    state <= BURST_WAIT2;

                ------------------------------------------------------
                -- BURST_WAIT2: Wait for DSACK on beat 2
                ------------------------------------------------------
                when BURST_WAIT2 =>
                    bus_addr <= current_addr;
                    bus_as   <= '1';
                    bus_ds   <= '1';
                    -- BURST remains asserted

                    if bus_berr = '1' then
                        burst_error <= '1';
                        state       <= BURST_ERROR_ST;

                    elsif dsack_asserted = '1' then
                        state <= BURST_DATA2;
                    end if;

                ------------------------------------------------------
                -- BURST_DATA2: Capture data from beat 2
                ------------------------------------------------------
                when BURST_DATA2 =>
                    data_reg_1   <= bus_data_in;
                    current_addr <= std_logic_vector(unsigned(current_addr) + 4);
                    beat_count   <= 2;

                    bus_as <= '0';
                    bus_ds <= '0';

                    state <= BURST_WAIT3;

                ------------------------------------------------------
                -- BURST_WAIT3: Wait for DSACK on beat 3
                ------------------------------------------------------
                when BURST_WAIT3 =>
                    bus_addr <= current_addr;
                    bus_as   <= '1';
                    bus_ds   <= '1';
                    -- BURST remains asserted

                    if bus_berr = '1' then
                        burst_error <= '1';
                        state       <= BURST_ERROR_ST;

                    elsif dsack_asserted = '1' then
                        state <= BURST_DATA3;
                    end if;

                ------------------------------------------------------
                -- BURST_DATA3: Capture data from beat 3
                ------------------------------------------------------
                when BURST_DATA3 =>
                    data_reg_2   <= bus_data_in;
                    current_addr <= std_logic_vector(unsigned(current_addr) + 4);
                    beat_count   <= 3;

                    bus_as <= '0';
                    bus_ds <= '0';

                    state <= BURST_WAIT4;

                ------------------------------------------------------
                -- BURST_WAIT4: Wait for DSACK on beat 4 (last)
                ------------------------------------------------------
                when BURST_WAIT4 =>
                    bus_addr  <= current_addr;
                    bus_as    <= '1';
                    bus_ds    <= '1';
                    bus_burst <= '0';  -- Deassert BURST on last beat

                    if bus_berr = '1' then
                        burst_error <= '1';
                        state       <= BURST_ERROR_ST;

                    elsif dsack_asserted = '1' then
                        state <= BURST_DATA4;
                    end if;

                ------------------------------------------------------
                -- BURST_DATA4: Capture data from beat 4 (last)
                ------------------------------------------------------
                when BURST_DATA4 =>
                    data_reg_3 <= bus_data_in;

                    bus_as <= '0';
                    bus_ds <= '0';

                    state <= BURST_COMPLETE;

                ------------------------------------------------------
                -- BURST_COMPLETE: All beats successful
                ------------------------------------------------------
                when BURST_COMPLETE =>
                    burst_done <= '1';
                    line_valid <= '1';

                    state <= IDLE;

                ------------------------------------------------------
                -- BURST_ERROR_ST: Bus error occurred
                ------------------------------------------------------
                when BURST_ERROR_ST =>
                    bus_as     <= '0';
                    bus_ds     <= '0';
                    bus_burst  <= '0';

                    burst_done  <= '1';  -- Complete with error
                    burst_error <= '1';

                    state <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------
    bus_addr <= current_addr;

    line_data_0 <= data_reg_0;
    line_data_1 <= data_reg_1;
    line_data_2 <= data_reg_2;
    line_data_3 <= data_reg_3;

end architecture rtl;
