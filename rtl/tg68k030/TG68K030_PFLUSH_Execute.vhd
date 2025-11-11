------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PFLUSH Instruction Execution                                    --
--                                                                          --
-- Executes PFLUSH operations to invalidate ATC entries:                   --
--   - PFLUSHA        : Invalidate all 22 ATC entries                      --
--   - PFLUSH FC      : Invalidate entries matching function code          --
--   - PFLUSH FC,EA   : Invalidate entry matching FC and address           --
--                                                                          --
-- Interfaces with:                                                         --
--   - TG68K030_PFLUSH_Decoder (instruction decode)                        --
--   - TG68K030_ATC (Address Translation Cache)                            --
--   - CPU core (EA calculation)                                           --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PFLUSH_Execute is
    port(
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Control inputs from decoder
        pflush_start    : in  std_logic;                      -- Start PFLUSH execution
        pflush_mode     : in  std_logic_vector(1 downto 0);  -- 00=PFLUSHA, 01=FC+EA, 10=FC
        pflush_fc       : in  std_logic_vector(2 downto 0);  -- Function code

        -- Effective address input (for FC,EA mode)
        ea_addr         : in  std_logic_vector(31 downto 0);  -- Calculated EA

        -- ATC invalidation interface
        atc_inv_req     : out std_logic;                      -- Invalidation request
        atc_inv_mode    : out std_logic_vector(1 downto 0);  -- Match mode (same as pflush_mode)
        atc_inv_fc      : out std_logic_vector(2 downto 0);  -- FC to match
        atc_inv_addr    : out std_logic_vector(31 downto 0);  -- Address to match (for FC,EA)
        atc_inv_ack     : in  std_logic;                      -- Invalidation complete

        -- Execution status
        pflush_done     : out std_logic;                      -- Execution complete
        pflush_busy     : out std_logic                       -- Execution in progress
    );
end entity TG68K030_PFLUSH_Execute;

architecture rtl of TG68K030_PFLUSH_Execute is

    -- PFLUSH mode constants (match decoder)
    constant MODE_PFLUSHA  : std_logic_vector(1 downto 0) := "00";
    constant MODE_FC_EA    : std_logic_vector(1 downto 0) := "01";
    constant MODE_FC       : std_logic_vector(1 downto 0) := "10";

    -- State machine
    type state_t is (
        IDLE,           -- Waiting for PFLUSH command
        INVALIDATE,     -- Request ATC invalidation
        WAIT_ACK,       -- Wait for ATC acknowledgement
        DONE            -- Operation complete
    );
    signal state : state_t;

    -- Internal registers
    signal mode_reg  : std_logic_vector(1 downto 0);
    signal fc_reg    : std_logic_vector(2 downto 0);
    signal addr_reg  : std_logic_vector(31 downto 0);

begin

    --------------------------------------------------------------
    -- PFLUSH Execution State Machine
    --------------------------------------------------------------
    exec_fsm: process(clk, reset)
    begin
        if reset = '1' then
            state        <= IDLE;
            mode_reg     <= "00";
            fc_reg       <= "000";
            addr_reg     <= (others => '0');

            atc_inv_req  <= '0';
            pflush_done  <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            atc_inv_req  <= '0';
            pflush_done  <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for PFLUSH command
                ------------------------------------------------------
                when IDLE =>
                    if pflush_start = '1' then
                        -- Capture parameters
                        mode_reg <= pflush_mode;
                        fc_reg   <= pflush_fc;
                        addr_reg <= ea_addr;

                        -- Start invalidation
                        state <= INVALIDATE;
                    end if;

                ------------------------------------------------------
                -- INVALIDATE: Request ATC invalidation
                ------------------------------------------------------
                when INVALIDATE =>
                    atc_inv_req <= '1';
                    state <= WAIT_ACK;

                ------------------------------------------------------
                -- WAIT_ACK: Wait for ATC to complete invalidation
                ------------------------------------------------------
                when WAIT_ACK =>
                    if atc_inv_ack = '1' then
                        state <= DONE;
                    end if;

                ------------------------------------------------------
                -- DONE: Operation complete
                ------------------------------------------------------
                when DONE =>
                    pflush_done <= '1';
                    state <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------

    -- Busy signal
    pflush_busy <= '1' when state /= IDLE else '0';

    -- ATC invalidation interface
    atc_inv_mode <= mode_reg;
    atc_inv_fc   <= fc_reg;
    atc_inv_addr <= addr_reg;

end architecture rtl;
