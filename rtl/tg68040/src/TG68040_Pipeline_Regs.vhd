------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Pipeline Register Definitions                                   --
--                                                                          --
-- Defines the pipeline register structures for the 6-stage pipeline       --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- The MC68040 uses a 6-stage pipeline:
-- IF → ID → EA → OF → EX → WB
--
-- Between each stage are pipeline registers that hold the instruction state
-- as it progresses through the pipeline.
--
-- Version: 0.1 (Phase 3)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;

package TG68040_Pipeline_Regs is

    ------------------------------------------------------------------------------
    -- IF/ID Pipeline Register (Between Instruction Fetch and Decode)
    ------------------------------------------------------------------------------
    type if_id_reg_t is record
        valid       : std_logic;                        -- Valid instruction
        pc          : std_logic_vector(31 downto 0);    -- Program counter
        instruction : std_logic_vector(15 downto 0);    -- Fetched instruction
        exception   : std_logic;                        -- Exception occurred
        exc_vector  : std_logic_vector(7 downto 0);    -- Exception vector number
    end record;

    constant IF_ID_REG_INIT : if_id_reg_t := (
        valid       => '0',
        pc          => (others => '0'),
        instruction => (others => '0'),
        exception   => '0',
        exc_vector  => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- ID/EA Pipeline Register (Between Decode and Effective Address)
    ------------------------------------------------------------------------------
    type id_ea_reg_t is record
        valid       : std_logic;                        -- Valid instruction
        pc          : std_logic_vector(31 downto 0);    -- Program counter
        opcode      : std_logic_vector(15 downto 0);    -- Decoded opcode
        instr_type  : instr_type_t;                     -- Instruction type
        src_reg1    : std_logic_vector(3 downto 0);     -- Source register 1
        src_reg2    : std_logic_vector(3 downto 0);     -- Source register 2
        dst_reg     : std_logic_vector(3 downto 0);     -- Destination register
        immediate   : std_logic_vector(31 downto 0);    -- Immediate data
        addr_mode   : std_logic_vector(5 downto 0);     -- Addressing mode
        data_size   : std_logic_vector(1 downto 0);     -- 00=byte, 01=word, 10=long
        exception   : std_logic;                        -- Exception occurred
        exc_vector  : std_logic_vector(7 downto 0);     -- Exception vector
    end record;

    constant ID_EA_REG_INIT : id_ea_reg_t := (
        valid       => '0',
        pc          => (others => '0'),
        opcode      => (others => '0'),
        instr_type  => INSTR_NONE,
        src_reg1    => (others => '0'),
        src_reg2    => (others => '0'),
        dst_reg     => (others => '0'),
        immediate   => (others => '0'),
        addr_mode   => (others => '0'),
        data_size   => "10",  -- Default to long
        exception   => '0',
        exc_vector  => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- EA/OF Pipeline Register (Between Effective Address and Operand Fetch)
    ------------------------------------------------------------------------------
    type ea_of_reg_t is record
        valid       : std_logic;                        -- Valid instruction
        pc          : std_logic_vector(31 downto 0);    -- Program counter
        instr_type  : instr_type_t;                     -- Instruction type
        opcode      : std_logic_vector(15 downto 0);    -- Opcode (for execute)
        ea_addr     : std_logic_vector(31 downto 0);    -- Calculated effective address
        dst_reg     : std_logic_vector(3 downto 0);     -- Destination register
        data_size   : std_logic_vector(1 downto 0);     -- Data size
        use_ea      : std_logic;                        -- Use EA address for fetch
        exception   : std_logic;                        -- Exception occurred
        exc_vector  : std_logic_vector(7 downto 0);     -- Exception vector
    end record;

    constant EA_OF_REG_INIT : ea_of_reg_t := (
        valid       => '0',
        pc          => (others => '0'),
        instr_type  => INSTR_NONE,
        opcode      => (others => '0'),
        ea_addr     => (others => '0'),
        dst_reg     => (others => '0'),
        data_size   => "10",
        use_ea      => '0',
        exception   => '0',
        exc_vector  => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- OF/EX Pipeline Register (Between Operand Fetch and Execute)
    ------------------------------------------------------------------------------
    type of_ex_reg_t is record
        valid       : std_logic;                        -- Valid instruction
        pc          : std_logic_vector(31 downto 0);    -- Program counter
        instr_type  : instr_type_t;                     -- Instruction type
        opcode      : std_logic_vector(15 downto 0);    -- Opcode
        operand1    : std_logic_vector(31 downto 0);    -- Source operand 1
        operand2    : std_logic_vector(31 downto 0);    -- Source operand 2
        dst_reg     : std_logic_vector(3 downto 0);     -- Destination register
        dst_addr    : std_logic_vector(31 downto 0);    -- Destination address (memory)
        data_size   : std_logic_vector(1 downto 0);     -- Data size
        write_reg   : std_logic;                        -- Write to register
        write_mem   : std_logic;                        -- Write to memory
        exception   : std_logic;                        -- Exception occurred
        exc_vector  : std_logic_vector(7 downto 0);     -- Exception vector
    end record;

    constant OF_EX_REG_INIT : of_ex_reg_t := (
        valid       => '0',
        pc          => (others => '0'),
        instr_type  => INSTR_NONE,
        opcode      => (others => '0'),
        operand1    => (others => '0'),
        operand2    => (others => '0'),
        dst_reg     => (others => '0'),
        dst_addr    => (others => '0'),
        data_size   => "10",
        write_reg   => '0',
        write_mem   => '0',
        exception   => '0',
        exc_vector  => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- EX/WB Pipeline Register (Between Execute and Write Back)
    ------------------------------------------------------------------------------
    type ex_wb_reg_t is record
        valid       : std_logic;                        -- Valid instruction
        pc          : std_logic_vector(31 downto 0);    -- Program counter (for exceptions)
        result      : std_logic_vector(31 downto 0);    -- Execution result
        dst_reg     : std_logic_vector(3 downto 0);     -- Destination register
        dst_addr    : std_logic_vector(31 downto 0);    -- Destination memory address
        data_size   : std_logic_vector(1 downto 0);     -- Data size
        write_reg   : std_logic;                        -- Write to register
        write_mem   : std_logic;                        -- Write to memory
        flags       : std_logic_vector(7 downto 0);     -- Condition code flags
        update_flags: std_logic;                        -- Update CCR
        exception   : std_logic;                        -- Exception occurred
        exc_vector  : std_logic_vector(7 downto 0);     -- Exception vector
    end record;

    constant EX_WB_REG_INIT : ex_wb_reg_t := (
        valid        => '0',
        pc           => (others => '0'),
        result       => (others => '0'),
        dst_reg      => (others => '0'),
        dst_addr     => (others => '0'),
        data_size    => "10",
        write_reg    => '0',
        write_mem    => '0',
        flags        => (others => '0'),
        update_flags => '0',
        exception    => '0',
        exc_vector   => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- Pipeline Control Signals
    ------------------------------------------------------------------------------
    type pipeline_ctrl_t is record
        stall_if    : std_logic;    -- Stall IF stage
        stall_id    : std_logic;    -- Stall ID stage
        stall_ea    : std_logic;    -- Stall EA stage
        stall_of    : std_logic;    -- Stall OF stage
        stall_ex    : std_logic;    -- Stall EX stage
        flush_if    : std_logic;    -- Flush IF stage
        flush_id    : std_logic;    -- Flush ID stage
        flush_ea    : std_logic;    -- Flush EA stage
        flush_of    : std_logic;    -- Flush OF stage
        flush_ex    : std_logic;    -- Flush EX stage
    end record;

    constant PIPELINE_CTRL_INIT : pipeline_ctrl_t := (
        stall_if => '0',
        stall_id => '0',
        stall_ea => '0',
        stall_of => '0',
        stall_ex => '0',
        flush_if => '0',
        flush_id => '0',
        flush_ea => '0',
        flush_of => '0',
        flush_ex => '0'
    );

    ------------------------------------------------------------------------------
    -- Pipeline Statistics (for debugging/profiling)
    ------------------------------------------------------------------------------
    type pipeline_stats_t is record
        cycles_total    : unsigned(31 downto 0);    -- Total cycles
        instrs_total    : unsigned(31 downto 0);    -- Total instructions completed
        stalls_total    : unsigned(31 downto 0);    -- Total stall cycles
        flushes_total   : unsigned(31 downto 0);    -- Total flush events
    end record;

    constant PIPELINE_STATS_INIT : pipeline_stats_t := (
        cycles_total  => (others => '0'),
        instrs_total  => (others => '0'),
        stalls_total  => (others => '0'),
        flushes_total => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- Hazard Detection Information (Phase 4)
    ------------------------------------------------------------------------------
    type hazard_info_t is record
        raw_hazard      : std_logic;  -- Read After Write detected
        waw_hazard      : std_logic;  -- Write After Write detected
        war_hazard      : std_logic;  -- Write After Read detected
        stall_required  : std_logic;  -- Must stall pipeline
        forward_ex_a    : std_logic;  -- Forward from EX stage to operand A
        forward_ex_b    : std_logic;  -- Forward from EX stage to operand B
        forward_wb_a    : std_logic;  -- Forward from WB stage to operand A
        forward_wb_b    : std_logic;  -- Forward from WB stage to operand B
    end record;

    constant HAZARD_INFO_INIT : hazard_info_t := (
        raw_hazard     => '0',
        waw_hazard     => '0',
        war_hazard     => '0',
        stall_required => '0',
        forward_ex_a   => '0',
        forward_ex_b   => '0',
        forward_wb_a   => '0',
        forward_wb_b   => '0'
    );

end package TG68040_Pipeline_Regs;
