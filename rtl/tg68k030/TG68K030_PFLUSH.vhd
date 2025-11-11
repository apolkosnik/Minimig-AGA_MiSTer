------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PFLUSH Instruction - Top Level                                  --
--                                                                          --
-- Complete PFLUSH instruction implementation combining:                   --
--   - TG68K030_PFLUSH_Decoder  (instruction decode)                       --
--   - TG68K030_PFLUSH_Execute  (execution logic)                          --
--                                                                          --
-- This module can be instantiated in TG68K030_Kernel to add PFLUSH        --
-- support for invalidating ATC (Address Translation Cache) entries.       --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PFLUSH is
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

        -- ATC invalidation interface
        atc_inv_req     : out std_logic;                      -- Invalidation request
        atc_inv_mode    : out std_logic_vector(1 downto 0);  -- Match mode
        atc_inv_fc      : out std_logic_vector(2 downto 0);  -- Function code
        atc_inv_addr    : out std_logic_vector(31 downto 0);  -- Address (for FC,EA mode)
        atc_inv_ack     : in  std_logic;                      -- Invalidation complete

        -- Exception outputs
        is_pflush       : out std_logic;                      -- PFLUSH instruction detected
        illegal_instr   : out std_logic;                      -- Illegal instruction
        priv_violation  : out std_logic                       -- Privilege violation
    );
end entity TG68K030_PFLUSH;

architecture rtl of TG68K030_PFLUSH is

    -- Component declarations
    component TG68K030_PFLUSH_Decoder is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            opcode          : in  std_logic_vector(15 downto 0);
            extension       : in  std_logic_vector(15 downto 0);
            opcode_valid    : in  std_logic;
            supervisor      : in  std_logic;
            is_pflush       : out std_logic;
            pflush_mode     : out std_logic_vector(1 downto 0);
            pflush_fc       : out std_logic_vector(2 downto 0);
            pflush_ea_mode  : out std_logic_vector(2 downto 0);
            pflush_ea_reg   : out std_logic_vector(2 downto 0);
            illegal_instr   : out std_logic;
            priv_violation  : out std_logic
        );
    end component;

    component TG68K030_PFLUSH_Execute is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            pflush_start    : in  std_logic;
            pflush_mode     : in  std_logic_vector(1 downto 0);
            pflush_fc       : in  std_logic_vector(2 downto 0);
            ea_addr         : in  std_logic_vector(31 downto 0);
            atc_inv_req     : out std_logic;
            atc_inv_mode    : out std_logic_vector(1 downto 0);
            atc_inv_fc      : out std_logic_vector(2 downto 0);
            atc_inv_addr    : out std_logic_vector(31 downto 0);
            atc_inv_ack     : in  std_logic;
            pflush_done     : out std_logic;
            pflush_busy     : out std_logic
        );
    end component;

    -- Internal signals connecting decoder to executor
    signal dec_is_pflush       : std_logic;
    signal dec_mode            : std_logic_vector(1 downto 0);
    signal dec_fc              : std_logic_vector(2 downto 0);

begin

    --------------------------------------------------------------
    -- PFLUSH Decoder Instance
    --------------------------------------------------------------
    decoder: TG68K030_PFLUSH_Decoder
        port map(
            clk             => clk,
            reset           => reset,
            opcode          => opcode,
            extension       => extension,
            opcode_valid    => opcode_valid,
            supervisor      => supervisor,
            is_pflush       => dec_is_pflush,
            pflush_mode     => dec_mode,
            pflush_fc       => dec_fc,
            pflush_ea_mode  => ea_mode,
            pflush_ea_reg   => ea_reg,
            illegal_instr   => illegal_instr,
            priv_violation  => priv_violation
        );

    --------------------------------------------------------------
    -- PFLUSH Executor Instance
    --------------------------------------------------------------
    executor: TG68K030_PFLUSH_Execute
        port map(
            clk             => clk,
            reset           => reset,
            pflush_start    => execute_start,
            pflush_mode     => dec_mode,
            pflush_fc       => dec_fc,
            ea_addr         => ea_addr,
            atc_inv_req     => atc_inv_req,
            atc_inv_mode    => atc_inv_mode,
            atc_inv_fc      => atc_inv_fc,
            atc_inv_addr    => atc_inv_addr,
            atc_inv_ack     => atc_inv_ack,
            pflush_done     => execute_done,
            pflush_busy     => execute_busy
        );

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------
    is_pflush <= dec_is_pflush;

end architecture rtl;
