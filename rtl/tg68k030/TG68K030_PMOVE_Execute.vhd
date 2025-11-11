------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PMOVE Instruction Execution                                     --
--                                                                          --
-- Executes PMOVE operations:                                              --
--   - PMOVE <ea>,MMU_reg  : Load MMU register from effective address      --
--   - PMOVE MMU_reg,<ea>  : Store MMU register to effective address       --
--   - PMOVEFD variants    : Same but with Flush Disable flag set          --
--                                                                          --
-- Interfaces with:                                                         --
--   - TG68K030_PMOVE_Decoder (instruction decode)                         --
--   - TG68K030_MMU_Registers (register access)                            --
--   - CPU core (EA calculation, memory access)                            --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PMOVE_Execute is
    port(
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Control inputs from decoder
        pmove_start     : in  std_logic;                      -- Start PMOVE execution
        pmove_direction : in  std_logic;                      -- 0=write to MMU, 1=read from MMU
        pmove_fd        : in  std_logic;                      -- Flush disable flag
        pmove_size      : in  std_logic_vector(1 downto 0);  -- 01=word, 10=long, 11=quad

        -- Register selection (one-hot)
        pmove_sel_tc    : in  std_logic;
        pmove_sel_tt0   : in  std_logic;
        pmove_sel_tt1   : in  std_logic;
        pmove_sel_crp   : in  std_logic;
        pmove_sel_srp   : in  std_logic;
        pmove_sel_mmusr : in  std_logic;

        -- Memory interface (from EA calculation)
        mem_addr        : in  std_logic_vector(31 downto 0);  -- Effective address
        mem_data_in     : in  std_logic_vector(63 downto 0);  -- Data from memory
        mem_data_out    : out std_logic_vector(63 downto 0);  -- Data to memory
        mem_read        : out std_logic;                      -- Memory read request
        mem_write       : out std_logic;                      -- Memory write request
        mem_size        : out std_logic_vector(1 downto 0);  -- Transfer size
        mem_ready       : in  std_logic;                      -- Memory operation complete

        -- MMU register interface
        mmu_data_in     : in  std_logic_vector(63 downto 0);  -- Data from MMU registers
        mmu_data_out    : out std_logic_vector(63 downto 0);  -- Data to MMU registers
        mmu_reg_addr    : out std_logic_vector(3 downto 0);  -- Register address
        mmu_read        : out std_logic;                      -- MMU register read
        mmu_write       : out std_logic;                      -- MMU register write
        mmu_size        : out std_logic_vector(1 downto 0);  -- Register access size

        -- ATC flush control
        atc_flush       : out std_logic;                      -- Flush ATC (when FD=0)
        atc_flush_all   : out std_logic;                      -- Flush entire ATC

        -- Execution status
        pmove_done      : out std_logic;                      -- Execution complete
        pmove_busy      : out std_logic                       -- Execution in progress
    );
end entity TG68K030_PMOVE_Execute;

architecture rtl of TG68K030_PMOVE_Execute is

    -- MMU register addresses (for mmu_reg_addr)
    constant ADDR_TC    : std_logic_vector(3 downto 0) := X"0";
    constant ADDR_TT0   : std_logic_vector(3 downto 0) := X"2";
    constant ADDR_TT1   : std_logic_vector(3 downto 0) := X"3";
    constant ADDR_CRP   : std_logic_vector(3 downto 0) := X"4";
    constant ADDR_SRP   : std_logic_vector(3 downto 0) := X"5";
    constant ADDR_MMUSR : std_logic_vector(3 downto 0) := X"6";

    -- State machine
    type state_t is (
        IDLE,           -- Waiting for PMOVE command
        READ_MMU,       -- Reading from MMU register
        WRITE_MEM,      -- Writing to memory
        READ_MEM,       -- Reading from memory
        WRITE_MMU,      -- Writing to MMU register
        FLUSH_ATC,      -- Flushing ATC (if needed)
        DONE            -- Operation complete
    );
    signal state : state_t;

    -- Internal registers
    signal reg_addr     : std_logic_vector(3 downto 0);
    signal data_buffer  : std_logic_vector(63 downto 0);
    signal size_reg     : std_logic_vector(1 downto 0);
    signal flush_needed : std_logic;

begin

    --------------------------------------------------------------
    -- Register Address Decoder
    --------------------------------------------------------------
    addr_decode_proc: process(pmove_sel_tc, pmove_sel_tt0, pmove_sel_tt1,
                             pmove_sel_crp, pmove_sel_srp, pmove_sel_mmusr)
    begin
        -- Default
        reg_addr <= X"0";

        -- One-hot decode to address
        if pmove_sel_tc = '1' then
            reg_addr <= ADDR_TC;
        elsif pmove_sel_tt0 = '1' then
            reg_addr <= ADDR_TT0;
        elsif pmove_sel_tt1 = '1' then
            reg_addr <= ADDR_TT1;
        elsif pmove_sel_crp = '1' then
            reg_addr <= ADDR_CRP;
        elsif pmove_sel_srp = '1' then
            reg_addr <= ADDR_SRP;
        elsif pmove_sel_mmusr = '1' then
            reg_addr <= ADDR_MMUSR;
        end if;
    end process;

    --------------------------------------------------------------
    -- PMOVE Execution State Machine
    --------------------------------------------------------------
    exec_fsm: process(clk, reset)
    begin
        if reset = '1' then
            state        <= IDLE;
            data_buffer  <= (others => '0');
            size_reg     <= "00";
            flush_needed <= '0';

            mem_read     <= '0';
            mem_write    <= '0';
            mmu_read     <= '0';
            mmu_write    <= '0';
            atc_flush    <= '0';
            pmove_done   <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            mem_read     <= '0';
            mem_write    <= '0';
            mmu_read     <= '0';
            mmu_write    <= '0';
            atc_flush    <= '0';
            pmove_done   <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for PMOVE command
                ------------------------------------------------------
                when IDLE =>
                    if pmove_start = '1' then
                        size_reg <= pmove_size;

                        -- Determine if ATC flush is needed
                        -- Flush on writes to TC, TT0, TT1, CRP, SRP (unless FD=1)
                        if pmove_fd = '0' and pmove_direction = '0' then
                            if pmove_sel_tc = '1' or pmove_sel_tt0 = '1' or
                               pmove_sel_tt1 = '1' or pmove_sel_crp = '1' or
                               pmove_sel_srp = '1' then
                                flush_needed <= '1';
                            else
                                flush_needed <= '0';
                            end if;
                        else
                            flush_needed <= '0';
                        end if;

                        -- Branch based on direction
                        if pmove_direction = '1' then
                            -- Read from MMU, write to memory
                            state <= READ_MMU;
                        else
                            -- Read from memory, write to MMU
                            state <= READ_MEM;
                        end if;
                    end if;

                ------------------------------------------------------
                -- READ_MMU: Read data from MMU register
                ------------------------------------------------------
                when READ_MMU =>
                    mmu_read <= '1';
                    state <= WRITE_MEM;

                ------------------------------------------------------
                -- WRITE_MEM: Write data to memory
                ------------------------------------------------------
                when WRITE_MEM =>
                    -- Get data from MMU
                    data_buffer <= mmu_data_in;
                    mem_write <= '1';

                    if mem_ready = '1' then
                        state <= DONE;
                    end if;

                ------------------------------------------------------
                -- READ_MEM: Read data from memory
                ------------------------------------------------------
                when READ_MEM =>
                    mem_read <= '1';

                    if mem_ready = '1' then
                        data_buffer <= mem_data_in;
                        state <= WRITE_MMU;
                    end if;

                ------------------------------------------------------
                -- WRITE_MMU: Write data to MMU register
                ------------------------------------------------------
                when WRITE_MMU =>
                    mmu_write <= '1';

                    -- Check if ATC flush needed
                    if flush_needed = '1' then
                        state <= FLUSH_ATC;
                    else
                        state <= DONE;
                    end if;

                ------------------------------------------------------
                -- FLUSH_ATC: Flush the ATC (if needed)
                ------------------------------------------------------
                when FLUSH_ATC =>
                    atc_flush <= '1';
                    state <= DONE;

                ------------------------------------------------------
                -- DONE: Operation complete
                ------------------------------------------------------
                when DONE =>
                    pmove_done <= '1';
                    state <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------

    -- Busy signal
    pmove_busy <= '1' when state /= IDLE else '0';

    -- MMU register interface
    mmu_reg_addr <= reg_addr;
    mmu_data_out <= data_buffer;
    mmu_size     <= size_reg;

    -- Memory interface
    mem_data_out <= data_buffer;
    mem_size     <= size_reg;

    -- ATC flush (currently flush all; could be refined)
    atc_flush_all <= '1';

end architecture rtl;
