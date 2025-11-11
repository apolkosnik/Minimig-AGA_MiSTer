------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PTEST Instruction - Top Level                                   --
--                                                                          --
-- Complete PTEST instruction implementation combining:                    --
--   - TG68K030_PTEST_Decoder  (instruction decode)                        --
--   - TG68K030_PTEST_Execute  (execution logic)                           --
--                                                                          --
-- This module can be instantiated in TG68K030_Kernel to add PTEST         --
-- support for testing MMU address translations without side effects.      --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PTEST is
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

        -- Exception outputs
        is_ptest        : out std_logic;                      -- PTEST instruction detected
        illegal_instr   : out std_logic;                      -- Illegal instruction
        priv_violation  : out std_logic                       -- Privilege violation
    );
end entity TG68K030_PTEST;

architecture rtl of TG68K030_PTEST is

    -- Component declarations
    component TG68K030_PTEST_Decoder is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            opcode          : in  std_logic_vector(15 downto 0);
            extension       : in  std_logic_vector(15 downto 0);
            opcode_valid    : in  std_logic;
            supervisor      : in  std_logic;
            is_ptest        : out std_logic;
            ptest_level     : out std_logic_vector(2 downto 0);
            ptest_fc        : out std_logic_vector(2 downto 0);
            ptest_rw        : out std_logic;
            ptest_ret_en    : out std_logic;
            ptest_ret_reg   : out std_logic_vector(2 downto 0);
            ptest_ea_mode   : out std_logic_vector(2 downto 0);
            ptest_ea_reg    : out std_logic_vector(2 downto 0);
            illegal_instr   : out std_logic;
            priv_violation  : out std_logic
        );
    end component;

    component TG68K030_PTEST_Execute is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            ptest_start     : in  std_logic;
            ptest_level     : in  std_logic_vector(2 downto 0);
            ptest_fc        : in  std_logic_vector(2 downto 0);
            ptest_rw        : in  std_logic;
            ptest_ret_en    : in  std_logic;
            ptest_ret_reg   : in  std_logic_vector(2 downto 0);
            ea_addr         : in  std_logic_vector(31 downto 0);
            mmu_walk_req    : out std_logic;
            mmu_walk_level  : out std_logic_vector(2 downto 0);
            mmu_walk_fc     : out std_logic_vector(2 downto 0);
            mmu_walk_addr   : out std_logic_vector(31 downto 0);
            mmu_walk_rw     : out std_logic;
            mmu_walk_done   : in  std_logic;
            mmu_walk_result : in  std_logic_vector(15 downto 0);
            mmu_desc_addr   : in  std_logic_vector(31 downto 0);
            atc_lookup_req  : out std_logic;
            atc_lookup_fc   : out std_logic_vector(2 downto 0);
            atc_lookup_addr : out std_logic_vector(31 downto 0);
            atc_hit         : in  std_logic;
            atc_lookup_done : in  std_logic;
            mmusr_update    : out std_logic;
            mmusr_data      : out std_logic_vector(15 downto 0);
            ret_reg_write   : out std_logic;
            ret_reg_num     : out std_logic_vector(2 downto 0);
            ret_reg_data    : out std_logic_vector(31 downto 0);
            ptest_done      : out std_logic;
            ptest_busy      : out std_logic
        );
    end component;

    -- Internal signals connecting decoder to executor
    signal dec_is_ptest        : std_logic;
    signal dec_level           : std_logic_vector(2 downto 0);
    signal dec_fc              : std_logic_vector(2 downto 0);
    signal dec_rw              : std_logic;
    signal dec_ret_en          : std_logic;
    signal dec_ret_reg         : std_logic_vector(2 downto 0);

begin

    --------------------------------------------------------------
    -- PTEST Decoder Instance
    --------------------------------------------------------------
    decoder: TG68K030_PTEST_Decoder
        port map(
            clk             => clk,
            reset           => reset,
            opcode          => opcode,
            extension       => extension,
            opcode_valid    => opcode_valid,
            supervisor      => supervisor,
            is_ptest        => dec_is_ptest,
            ptest_level     => dec_level,
            ptest_fc        => dec_fc,
            ptest_rw        => dec_rw,
            ptest_ret_en    => dec_ret_en,
            ptest_ret_reg   => dec_ret_reg,
            ptest_ea_mode   => ea_mode,
            ptest_ea_reg    => ea_reg,
            illegal_instr   => illegal_instr,
            priv_violation  => priv_violation
        );

    --------------------------------------------------------------
    -- PTEST Executor Instance
    --------------------------------------------------------------
    executor: TG68K030_PTEST_Execute
        port map(
            clk             => clk,
            reset           => reset,
            ptest_start     => execute_start,
            ptest_level     => dec_level,
            ptest_fc        => dec_fc,
            ptest_rw        => dec_rw,
            ptest_ret_en    => dec_ret_en,
            ptest_ret_reg   => dec_ret_reg,
            ea_addr         => ea_addr,
            mmu_walk_req    => mmu_walk_req,
            mmu_walk_level  => mmu_walk_level,
            mmu_walk_fc     => mmu_walk_fc,
            mmu_walk_addr   => mmu_walk_addr,
            mmu_walk_rw     => mmu_walk_rw,
            mmu_walk_done   => mmu_walk_done,
            mmu_walk_result => mmu_walk_result,
            mmu_desc_addr   => mmu_desc_addr,
            atc_lookup_req  => atc_lookup_req,
            atc_lookup_fc   => atc_lookup_fc,
            atc_lookup_addr => atc_lookup_addr,
            atc_hit         => atc_hit,
            atc_lookup_done => atc_lookup_done,
            mmusr_update    => mmusr_update,
            mmusr_data      => mmusr_data,
            ret_reg_write   => ret_reg_write,
            ret_reg_num     => ret_reg_num,
            ret_reg_data    => ret_reg_data,
            ptest_done      => execute_done,
            ptest_busy      => execute_busy
        );

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------
    is_ptest <= dec_is_ptest;

end architecture rtl;
