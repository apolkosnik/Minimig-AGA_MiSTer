------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 MMU Integration Module                                          --
--                                                                          --
-- Integrates MMU with PFLUSH and PTEST instructions                       --
--                                                                          --
-- Connects:                                                                --
--   - PFLUSH_Execute → ATC flush operations                               --
--   - PTEST_Execute → MMU table walk and ATC lookup                       --
--   - MMU_Registers → MMU control registers                               --
--                                                                          --
-- This module acts as an adapter between the instruction execution         --
-- modules and the MMU/ATC hardware.                                        --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_MMU_Integration is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -----------------------------------------------------
        -- PFLUSH Interface (from TG68K030_PFLUSH_Execute)
        -----------------------------------------------------
        pflush_inv_req  : in  std_logic;                      -- Invalidation request
        pflush_inv_mode : in  std_logic_vector(1 downto 0);  -- 00=all, 01=FC+EA, 10=FC
        pflush_inv_fc   : in  std_logic_vector(2 downto 0);  -- Function code
        pflush_inv_addr : in  std_logic_vector(31 downto 0); -- Address to invalidate
        pflush_inv_ack  : out std_logic;                      -- Invalidation complete

        -----------------------------------------------------
        -- PTEST Interface (from TG68K030_PTEST_Execute)
        -----------------------------------------------------
        -- Table walk request
        ptest_walk_req    : in  std_logic;                      -- Request table walk
        ptest_walk_level  : in  std_logic_vector(2 downto 0);  -- Level to test
        ptest_walk_fc     : in  std_logic_vector(2 downto 0);  -- Function code
        ptest_walk_addr   : in  std_logic_vector(31 downto 0); -- Address to test
        ptest_walk_rw     : in  std_logic;                      -- 0=read, 1=write
        ptest_walk_done   : out std_logic;                      -- Walk complete
        ptest_walk_result : out std_logic_vector(15 downto 0); -- MMUSR result
        ptest_desc_addr   : out std_logic_vector(31 downto 0); -- Descriptor address

        -- ATC lookup request
        ptest_atc_req     : in  std_logic;                      -- ATC lookup request
        ptest_atc_fc      : in  std_logic_vector(2 downto 0);  -- Function code
        ptest_atc_addr    : in  std_logic_vector(31 downto 0); -- Address
        ptest_atc_hit     : out std_logic;                      -- Found in ATC
        ptest_atc_done    : out std_logic;                      -- Lookup complete

        -----------------------------------------------------
        -- MMU Interface (to TG68K030_MMU)
        -----------------------------------------------------
        -- Flush control
        mmu_flush_all   : out std_logic;
        mmu_flush_fc    : out std_logic;
        mmu_flush_addr  : out std_logic;
        mmu_flush_fc_val: out std_logic_vector(2 downto 0);
        mmu_flush_addr_val: out std_logic_vector(31 downto 0);

        -- Translation request (for PTEST)
        mmu_trans_req   : out std_logic;
        mmu_trans_addr  : out std_logic_vector(31 downto 0);
        mmu_trans_fc    : out std_logic_vector(2 downto 0);
        mmu_trans_rw    : out std_logic;
        mmu_trans_ready : in  std_logic;
        mmu_trans_error : in  std_logic;
        mmu_phys_addr   : in  std_logic_vector(31 downto 0);

        -- ATC lookup (for PTEST)
        atc_lookup_en   : out std_logic;
        atc_lookup_addr : out std_logic_vector(31 downto 0);
        atc_lookup_fc   : out std_logic_vector(2 downto 0);
        atc_hit         : in  std_logic;
        atc_phys_addr   : in  std_logic_vector(31 downto 0);
        atc_wp          : in  std_logic;
        atc_super       : in  std_logic;
        atc_ci          : in  std_logic;
        atc_modified    : in  std_logic;
        atc_used        : in  std_logic;

        -- MMU status
        mmu_status      : in  std_logic_vector(15 downto 0)   -- Current MMUSR
    );
end entity TG68K030_MMU_Integration;

architecture rtl of TG68K030_MMU_Integration is

    -- PFLUSH mode constants
    constant MODE_PFLUSHA  : std_logic_vector(1 downto 0) := "00";
    constant MODE_FC_EA    : std_logic_vector(1 downto 0) := "01";
    constant MODE_FC       : std_logic_vector(1 downto 0) := "10";

    -- PTEST state machine
    type ptest_state_t is (
        IDLE,
        ATC_LOOKUP,
        TABLE_WALK,
        WAIT_TRANS,
        BUILD_MMUSR,
        DONE
    );
    signal ptest_state : ptest_state_t;

    -- PTEST working registers
    signal ptest_level_reg  : std_logic_vector(2 downto 0);
    signal ptest_atc_hit_reg: std_logic;
    signal ptest_mmusr_reg  : std_logic_vector(15 downto 0);
    signal ptest_desc_reg   : std_logic_vector(31 downto 0);

begin

    --------------------------------------------------------------
    -- PFLUSH to ATC Flush Mapping
    --------------------------------------------------------------
    -- This is purely combinational - no state needed
    --------------------------------------------------------------
    pflush_mapping: process(pflush_inv_req, pflush_inv_mode, pflush_inv_fc, pflush_inv_addr)
    begin
        -- Default: no flush
        mmu_flush_all      <= '0';
        mmu_flush_fc       <= '0';
        mmu_flush_addr     <= '0';
        mmu_flush_fc_val   <= (others => '0');
        mmu_flush_addr_val <= (others => '0');
        pflush_inv_ack     <= '0';

        if pflush_inv_req = '1' then
            case pflush_inv_mode is
                -- PFLUSHA: Flush all entries
                when MODE_PFLUSHA =>
                    mmu_flush_all  <= '1';
                    pflush_inv_ack <= '1';

                -- PFLUSH FC,EA: Flush by function code and address
                when MODE_FC_EA =>
                    mmu_flush_addr     <= '1';
                    mmu_flush_fc_val   <= pflush_inv_fc;
                    mmu_flush_addr_val <= pflush_inv_addr;
                    pflush_inv_ack     <= '1';

                -- PFLUSH FC: Flush by function code only
                when MODE_FC =>
                    mmu_flush_fc       <= '1';
                    mmu_flush_fc_val   <= pflush_inv_fc;
                    pflush_inv_ack     <= '1';

                when others =>
                    pflush_inv_ack <= '1';
            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- PTEST State Machine
    --------------------------------------------------------------
    -- Handles the multi-step PTEST operation:
    -- 1. Check ATC for cached translation
    -- 2. Perform table walk (regardless of ATC hit)
    -- 3. Build MMUSR with results
    --------------------------------------------------------------
    ptest_fsm: process(clk, reset)
    begin
        if reset = '1' then
            ptest_state       <= IDLE;
            ptest_level_reg   <= "000";
            ptest_atc_hit_reg <= '0';
            ptest_mmusr_reg   <= (others => '0');
            ptest_desc_reg    <= (others => '0');

            mmu_trans_req     <= '0';
            atc_lookup_en     <= '0';
            ptest_walk_done   <= '0';
            ptest_atc_done    <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            mmu_trans_req   <= '0';
            atc_lookup_en   <= '0';
            ptest_walk_done <= '0';
            ptest_atc_done  <= '0';

            case ptest_state is

                ------------------------------------------------------
                -- IDLE: Wait for PTEST request
                ------------------------------------------------------
                when IDLE =>
                    if ptest_atc_req = '1' then
                        -- ATC lookup requested
                        ptest_state <= ATC_LOOKUP;

                    elsif ptest_walk_req = '1' then
                        -- Table walk requested (capture level)
                        ptest_level_reg <= ptest_walk_level;
                        ptest_state     <= TABLE_WALK;
                    end if;

                ------------------------------------------------------
                -- ATC_LOOKUP: Check ATC for cached translation
                ------------------------------------------------------
                when ATC_LOOKUP =>
                    -- Request ATC lookup
                    atc_lookup_en   <= '1';
                    atc_lookup_addr <= ptest_atc_addr;
                    atc_lookup_fc   <= ptest_atc_fc;

                    -- Capture ATC hit status
                    ptest_atc_hit_reg <= atc_hit;
                    ptest_atc_hit     <= atc_hit;

                    -- Complete immediately
                    ptest_atc_done <= '1';
                    ptest_state    <= IDLE;

                ------------------------------------------------------
                -- TABLE_WALK: Start MMU table walk
                ------------------------------------------------------
                when TABLE_WALK =>
                    mmu_trans_req  <= '1';
                    mmu_trans_addr <= ptest_walk_addr;
                    mmu_trans_fc   <= ptest_walk_fc;
                    mmu_trans_rw   <= ptest_walk_rw;

                    ptest_state <= WAIT_TRANS;

                ------------------------------------------------------
                -- WAIT_TRANS: Wait for translation to complete
                ------------------------------------------------------
                when WAIT_TRANS =>
                    if mmu_trans_ready = '1' or mmu_trans_error = '1' then
                        -- Translation complete (success or error)
                        ptest_state <= BUILD_MMUSR;
                    end if;

                ------------------------------------------------------
                -- BUILD_MMUSR: Construct MMUSR result
                ------------------------------------------------------
                when BUILD_MMUSR =>
                    -- Start with current MMU status
                    ptest_mmusr_reg <= mmu_status;

                    -- Set ATC hit bit (bit 6) if we found it earlier
                    if ptest_atc_hit_reg = '1' then
                        ptest_mmusr_reg(6) <= '1';
                    end if;

                    -- For PTEST, we don't have a real descriptor address
                    -- in this simplified implementation. In a full
                    -- implementation, the page table walk would return
                    -- the address of the last descriptor fetched.
                    ptest_desc_reg <= mmu_phys_addr;

                    ptest_state <= DONE;

                ------------------------------------------------------
                -- DONE: Complete PTEST operation
                ------------------------------------------------------
                when DONE =>
                    ptest_walk_done <= '1';
                    ptest_state     <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- PTEST Output Assignments
    --------------------------------------------------------------
    ptest_walk_result <= ptest_mmusr_reg;
    ptest_desc_addr   <= ptest_desc_reg;

end architecture rtl;
