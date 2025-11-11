------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PMOVE Instruction - Top Level                                   --
--                                                                          --
-- Complete PMOVE instruction implementation combining:                    --
--   - TG68K030_PMOVE_Decoder  (instruction decode)                        --
--   - TG68K030_PMOVE_Execute  (execution logic)                           --
--                                                                          --
-- This module can be instantiated in TG68K030_Kernel to add PMOVE         --
-- support for accessing MMU control registers.                            --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PMOVE is
    port(
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Instruction interface
        opcode          : in  std_logic_vector(15 downto 0);  -- First instruction word
        extension       : in  std_logic_vector(15 downto 0);  -- Extension word
        opcode_valid    : in  std_logic;                      -- Opcode is valid

        -- CPU state
        supervisor      : in  std_logic;                      -- Supervisor mode

        -- Execution control
        execute_start   : in  std_logic;                      -- Start execution
        execute_done    : out std_logic;                      -- Execution complete
        execute_busy    : out std_logic;                      -- Execution in progress

        -- Effective address interface
        ea_addr         : in  std_logic_vector(31 downto 0);  -- Calculated EA
        ea_mode         : out std_logic_vector(2 downto 0);   -- EA mode (for calculation)
        ea_reg          : out std_logic_vector(2 downto 0);   -- EA register (for calculation)

        -- Memory interface
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
        atc_flush       : out std_logic;                      -- Flush ATC
        atc_flush_all   : out std_logic;                      -- Flush entire ATC

        -- Exception outputs
        is_pmove        : out std_logic;                      -- PMOVE instruction detected
        illegal_instr   : out std_logic;                      -- Illegal instruction
        priv_violation  : out std_logic                       -- Privilege violation
    );
end entity TG68K030_PMOVE;

architecture rtl of TG68K030_PMOVE is

    -- Component declarations
    component TG68K030_PMOVE_Decoder is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            opcode          : in  std_logic_vector(15 downto 0);
            extension       : in  std_logic_vector(15 downto 0);
            opcode_valid    : in  std_logic;
            supervisor      : in  std_logic;
            is_pmove        : out std_logic;
            is_pmovefd      : out std_logic;
            pmove_direction : out std_logic;
            pmove_reg_code  : out std_logic_vector(7 downto 0);
            pmove_ea_mode   : out std_logic_vector(2 downto 0);
            pmove_ea_reg    : out std_logic_vector(2 downto 0);
            pmove_size      : out std_logic_vector(1 downto 0);
            pmove_sel_tc    : out std_logic;
            pmove_sel_tt0   : out std_logic;
            pmove_sel_tt1   : out std_logic;
            pmove_sel_crp   : out std_logic;
            pmove_sel_srp   : out std_logic;
            pmove_sel_mmusr : out std_logic;
            illegal_instr   : out std_logic;
            priv_violation  : out std_logic
        );
    end component;

    component TG68K030_PMOVE_Execute is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            pmove_start     : in  std_logic;
            pmove_direction : in  std_logic;
            pmove_fd        : in  std_logic;
            pmove_size      : in  std_logic_vector(1 downto 0);
            pmove_sel_tc    : in  std_logic;
            pmove_sel_tt0   : in  std_logic;
            pmove_sel_tt1   : in  std_logic;
            pmove_sel_crp   : in  std_logic;
            pmove_sel_srp   : in  std_logic;
            pmove_sel_mmusr : in  std_logic;
            mem_addr        : in  std_logic_vector(31 downto 0);
            mem_data_in     : in  std_logic_vector(63 downto 0);
            mem_data_out    : out std_logic_vector(63 downto 0);
            mem_read        : out std_logic;
            mem_write       : out std_logic;
            mem_size        : out std_logic_vector(1 downto 0);
            mem_ready       : in  std_logic;
            mmu_data_in     : in  std_logic_vector(63 downto 0);
            mmu_data_out    : out std_logic_vector(63 downto 0);
            mmu_reg_addr    : out std_logic_vector(3 downto 0);
            mmu_read        : out std_logic;
            mmu_write       : out std_logic;
            mmu_size        : out std_logic_vector(1 downto 0);
            atc_flush       : out std_logic;
            atc_flush_all   : out std_logic;
            pmove_done      : out std_logic;
            pmove_busy      : out std_logic
        );
    end component;

    -- Internal signals connecting decoder to executor
    signal dec_is_pmove        : std_logic;
    signal dec_is_pmovefd      : std_logic;
    signal dec_direction       : std_logic;
    signal dec_reg_code        : std_logic_vector(7 downto 0);
    signal dec_size            : std_logic_vector(1 downto 0);
    signal dec_sel_tc          : std_logic;
    signal dec_sel_tt0         : std_logic;
    signal dec_sel_tt1         : std_logic;
    signal dec_sel_crp         : std_logic;
    signal dec_sel_srp         : std_logic;
    signal dec_sel_mmusr       : std_logic;

begin

    --------------------------------------------------------------
    -- PMOVE Decoder Instance
    --------------------------------------------------------------
    decoder: TG68K030_PMOVE_Decoder
        port map(
            clk             => clk,
            reset           => reset,
            opcode          => opcode,
            extension       => extension,
            opcode_valid    => opcode_valid,
            supervisor      => supervisor,
            is_pmove        => dec_is_pmove,
            is_pmovefd      => dec_is_pmovefd,
            pmove_direction => dec_direction,
            pmove_reg_code  => dec_reg_code,
            pmove_ea_mode   => ea_mode,
            pmove_ea_reg    => ea_reg,
            pmove_size      => dec_size,
            pmove_sel_tc    => dec_sel_tc,
            pmove_sel_tt0   => dec_sel_tt0,
            pmove_sel_tt1   => dec_sel_tt1,
            pmove_sel_crp   => dec_sel_crp,
            pmove_sel_srp   => dec_sel_srp,
            pmove_sel_mmusr => dec_sel_mmusr,
            illegal_instr   => illegal_instr,
            priv_violation  => priv_violation
        );

    --------------------------------------------------------------
    -- PMOVE Executor Instance
    --------------------------------------------------------------
    executor: TG68K030_PMOVE_Execute
        port map(
            clk             => clk,
            reset           => reset,
            pmove_start     => execute_start,
            pmove_direction => dec_direction,
            pmove_fd        => dec_is_pmovefd,
            pmove_size      => dec_size,
            pmove_sel_tc    => dec_sel_tc,
            pmove_sel_tt0   => dec_sel_tt0,
            pmove_sel_tt1   => dec_sel_tt1,
            pmove_sel_crp   => dec_sel_crp,
            pmove_sel_srp   => dec_sel_srp,
            pmove_sel_mmusr => dec_sel_mmusr,
            mem_addr        => ea_addr,
            mem_data_in     => mem_data_in,
            mem_data_out    => mem_data_out,
            mem_read        => mem_read,
            mem_write       => mem_write,
            mem_size        => mem_size,
            mem_ready       => mem_ready,
            mmu_data_in     => mmu_data_in,
            mmu_data_out    => mmu_data_out,
            mmu_reg_addr    => mmu_reg_addr,
            mmu_read        => mmu_read,
            mmu_write       => mmu_write,
            mmu_size        => mmu_size,
            atc_flush       => atc_flush,
            atc_flush_all   => atc_flush_all,
            pmove_done      => execute_done,
            pmove_busy      => execute_busy
        );

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------
    is_pmove <= dec_is_pmove;

end architecture rtl;
