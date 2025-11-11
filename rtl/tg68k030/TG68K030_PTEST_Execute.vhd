------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PTEST Instruction Execution                                     --
--                                                                          --
-- Executes PTEST operations to test MMU address translation:              --
--   - Performs table walk to specified level                              --
--   - Updates MMUSR with translation results                              --
--   - Optionally stores descriptor address in An                          --
--   - Checks ATC for existing translation                                 --
--   - Does NOT cause exceptions (safe testing)                            --
--                                                                          --
-- Interfaces with:                                                         --
--   - TG68K030_PTEST_Decoder (instruction decode)                         --
--   - TG68K030_MMU (table walk logic)                                     --
--   - TG68K030_ATC (Address Translation Cache lookup)                     --
--   - TG68K030_MMU_Registers (MMUSR update)                               --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PTEST_Execute is
    port(
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Control inputs from decoder
        ptest_start     : in  std_logic;                      -- Start PTEST execution
        ptest_level     : in  std_logic_vector(2 downto 0);  -- Level to test (0-7)
        ptest_fc        : in  std_logic_vector(2 downto 0);  -- Function code
        ptest_rw        : in  std_logic;                      -- 0=read, 1=write
        ptest_ret_en    : in  std_logic;                      -- Return descriptor address
        ptest_ret_reg   : in  std_logic_vector(2 downto 0);  -- An register number

        -- Effective address input
        ea_addr         : in  std_logic_vector(31 downto 0);  -- Address to test

        -- MMU table walk interface
        mmu_walk_req    : out std_logic;                      -- Request table walk
        mmu_walk_level  : out std_logic_vector(2 downto 0);  -- Level to walk to
        mmu_walk_fc     : out std_logic_vector(2 downto 0);  -- Function code
        mmu_walk_addr   : out std_logic_vector(31 downto 0);  -- Address to translate
        mmu_walk_rw     : out std_logic;                      -- Read/write test
        mmu_walk_done   : in  std_logic;                      -- Table walk complete
        mmu_walk_result : in  std_logic_vector(15 downto 0); -- MMUSR result
        mmu_desc_addr   : in  std_logic_vector(31 downto 0); -- Descriptor address

        -- ATC lookup interface
        atc_lookup_req  : out std_logic;                      -- Request ATC lookup
        atc_lookup_fc   : out std_logic_vector(2 downto 0);  -- Function code
        atc_lookup_addr : out std_logic_vector(31 downto 0);  -- Address
        atc_hit         : in  std_logic;                      -- Found in ATC
        atc_lookup_done : in  std_logic;                      -- Lookup complete

        -- MMUSR update interface
        mmusr_update    : out std_logic;                      -- Update MMUSR
        mmusr_data      : out std_logic_vector(15 downto 0); -- New MMUSR value

        -- Return register write interface
        ret_reg_write   : out std_logic;                      -- Write to An
        ret_reg_num     : out std_logic_vector(2 downto 0);  -- An register number
        ret_reg_data    : out std_logic_vector(31 downto 0); -- Descriptor address

        -- Execution status
        ptest_done      : out std_logic;                      -- Execution complete
        ptest_busy      : out std_logic                       -- Execution in progress
    );
end entity TG68K030_PTEST_Execute;

architecture rtl of TG68K030_PTEST_Execute is

    -- State machine
    type state_t is (
        IDLE,           -- Waiting for PTEST command
        ATC_LOOKUP,     -- Check ATC for cached translation
        MMU_WALK,       -- Request MMU table walk
        WAIT_MMU,       -- Wait for MMU table walk completion
        UPDATE_MMUSR,   -- Update MMUSR with results
        WRITE_RETURN,   -- Write descriptor address to An (if requested)
        DONE            -- Operation complete
    );
    signal state : state_t;

    -- Internal registers
    signal level_reg     : std_logic_vector(2 downto 0);
    signal fc_reg        : std_logic_vector(2 downto 0);
    signal rw_reg        : std_logic;
    signal addr_reg      : std_logic_vector(31 downto 0);
    signal ret_en_reg    : std_logic;
    signal ret_reg_num_i : std_logic_vector(2 downto 0);
    signal mmusr_reg     : std_logic_vector(15 downto 0);
    signal desc_addr_reg : std_logic_vector(31 downto 0);
    signal atc_hit_reg   : std_logic;

    -- MMUSR bit positions
    constant MMUSR_C : integer := 6;  -- ATC hit bit

begin

    --------------------------------------------------------------
    -- PTEST Execution State Machine
    --------------------------------------------------------------
    exec_fsm: process(clk, reset)
    begin
        if reset = '1' then
            state          <= IDLE;
            level_reg      <= "000";
            fc_reg         <= "000";
            rw_reg         <= '0';
            addr_reg       <= (others => '0');
            ret_en_reg     <= '0';
            ret_reg_num_i  <= "000";
            mmusr_reg      <= (others => '0');
            desc_addr_reg  <= (others => '0');
            atc_hit_reg    <= '0';

            atc_lookup_req <= '0';
            mmu_walk_req   <= '0';
            mmusr_update   <= '0';
            ret_reg_write  <= '0';
            ptest_done     <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            atc_lookup_req <= '0';
            mmu_walk_req   <= '0';
            mmusr_update   <= '0';
            ret_reg_write  <= '0';
            ptest_done     <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for PTEST command
                ------------------------------------------------------
                when IDLE =>
                    if ptest_start = '1' then
                        -- Capture parameters
                        level_reg     <= ptest_level;
                        fc_reg        <= ptest_fc;
                        rw_reg        <= ptest_rw;
                        addr_reg      <= ea_addr;
                        ret_en_reg    <= ptest_ret_en;
                        ret_reg_num_i <= ptest_ret_reg;

                        -- Start with ATC lookup
                        state <= ATC_LOOKUP;
                    end if;

                ------------------------------------------------------
                -- ATC_LOOKUP: Check if translation is in ATC
                ------------------------------------------------------
                when ATC_LOOKUP =>
                    atc_lookup_req <= '1';

                    if atc_lookup_done = '1' then
                        atc_hit_reg <= atc_hit;
                        -- Proceed to MMU walk regardless (to get descriptor address)
                        state <= MMU_WALK;
                    end if;

                ------------------------------------------------------
                -- MMU_WALK: Request table walk from MMU
                ------------------------------------------------------
                when MMU_WALK =>
                    mmu_walk_req <= '1';
                    state <= WAIT_MMU;

                ------------------------------------------------------
                -- WAIT_MMU: Wait for MMU table walk to complete
                ------------------------------------------------------
                when WAIT_MMU =>
                    if mmu_walk_done = '1' then
                        -- Capture results
                        mmusr_reg     <= mmu_walk_result;
                        desc_addr_reg <= mmu_desc_addr;

                        -- Set ATC hit bit if found in ATC
                        if atc_hit_reg = '1' then
                            mmusr_reg(MMUSR_C) <= '1';
                        end if;

                        state <= UPDATE_MMUSR;
                    end if;

                ------------------------------------------------------
                -- UPDATE_MMUSR: Update MMUSR with results
                ------------------------------------------------------
                when UPDATE_MMUSR =>
                    mmusr_update <= '1';

                    -- Check if we need to write return register
                    if ret_en_reg = '1' then
                        state <= WRITE_RETURN;
                    else
                        state <= DONE;
                    end if;

                ------------------------------------------------------
                -- WRITE_RETURN: Write descriptor address to An
                ------------------------------------------------------
                when WRITE_RETURN =>
                    ret_reg_write <= '1';
                    state <= DONE;

                ------------------------------------------------------
                -- DONE: Operation complete
                ------------------------------------------------------
                when DONE =>
                    ptest_done <= '1';
                    state <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------

    -- Busy signal
    ptest_busy <= '1' when state /= IDLE else '0';

    -- MMU table walk interface
    mmu_walk_level <= level_reg;
    mmu_walk_fc    <= fc_reg;
    mmu_walk_addr  <= addr_reg;
    mmu_walk_rw    <= rw_reg;

    -- ATC lookup interface
    atc_lookup_fc   <= fc_reg;
    atc_lookup_addr <= addr_reg;

    -- MMUSR update
    mmusr_data <= mmusr_reg;

    -- Return register write
    ret_reg_num  <= ret_reg_num_i;
    ret_reg_data <= desc_addr_reg;

end architecture rtl;
