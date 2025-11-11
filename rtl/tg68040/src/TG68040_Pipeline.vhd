------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Pipeline Controller (Phase 3 - Basic Version)                   --
--                                                                          --
-- Implements the 6-stage MC68040 pipeline without hazard detection        --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- 6-Stage Pipeline: IF → ID → EA → OF → EX → WB
--
-- Phase 3 Simplifications:
-- - No hazard detection (Phase 4)
-- - Simple instructions only
-- - Flush on all branches
-- - Direct memory access (no cache)
--
-- Version: 0.1 (Phase 3 - Basic)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;
use work.TG68040_Pipeline_Regs.all;
use work.TG68040_Branch_Pack.all;
use work.TG68040_MMU_Pack.all;
use work.TG68040_FPU_Pack.all;
use work.TG68040_Exception_Pack.all;

entity TG68040_Pipeline is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Control
        enable         : in std_logic;                          -- Pipeline enable

        -- Memory interface (simplified for Phase 3)
        mem_addr       : out std_logic_vector(31 downto 0);     -- Memory address
        mem_data_read  : in std_logic_vector(31 downto 0);      -- Data read
        mem_data_write : out std_logic_vector(31 downto 0);     -- Data to write
        mem_read       : out std_logic;                         -- Read enable
        mem_write      : out std_logic;                         -- Write enable
        mem_ready      : in std_logic;                          -- Memory ready

        -- Register file interface
        reg_addr_a     : out std_logic_vector(3 downto 0);      -- Register A address
        reg_addr_b     : out std_logic_vector(3 downto 0);      -- Register B address
        reg_data_a     : in std_logic_vector(31 downto 0);      -- Register A data
        reg_data_b     : in std_logic_vector(31 downto 0);      -- Register B data
        reg_write_addr : out std_logic_vector(3 downto 0);      -- Write register address
        reg_write_data : out std_logic_vector(31 downto 0);     -- Write data
        reg_write_en   : out std_logic;                         -- Write enable

        -- Status
        pipeline_busy  : out std_logic;                         -- Pipeline has valid instructions
        instructions_completed : out std_logic_vector(31 downto 0);  -- Instruction counter

        -- Debug/Statistics
        pipeline_stalled : out std_logic;                       -- Pipeline is stalled
        pipeline_flushed : out std_logic                        -- Pipeline was flushed
    );
end TG68040_Pipeline;

architecture rtl of TG68040_Pipeline is

    -- Pipeline registers
    signal if_id : if_id_reg_t := IF_ID_REG_INIT;
    signal id_ea : id_ea_reg_t := ID_EA_REG_INIT;
    signal ea_of : ea_of_reg_t := EA_OF_REG_INIT;
    signal of_ex : of_ex_reg_t := OF_EX_REG_INIT;
    signal ex_wb : ex_wb_reg_t := EX_WB_REG_INIT;

    -- Pipeline control
    signal ctrl : pipeline_ctrl_t := PIPELINE_CTRL_INIT;

    -- Program counter
    signal pc : unsigned(31 downto 0) := (others => '0');
    signal pc_next : unsigned(31 downto 0);

    -- Pipeline statistics
    signal stats : pipeline_stats_t := PIPELINE_STATS_INIT;

    -- Internal signals
    signal instr_complete : std_logic;
    signal any_valid : std_logic;
    signal global_stall : std_logic;
    signal global_flush : std_logic;

    -- Hazard detection (Phase 4)
    signal hazard_info : hazard_info_t := HAZARD_INFO_INIT;
    signal hazard_stall : std_logic;

    -- Forwarding multiplexer outputs
    signal operand1_forwarded : std_logic_vector(31 downto 0);
    signal operand2_forwarded : std_logic_vector(31 downto 0);

    -- Instruction Cache signals (Phase 5)
    signal icache_fetch_req : std_logic;
    signal icache_fetch_addr : std_logic_vector(31 downto 0);
    signal icache_fetch_data : std_logic_vector(15 downto 0);
    signal icache_fetch_ready : std_logic;
    signal icache_hit_count : std_logic_vector(31 downto 0);
    signal icache_miss_count : std_logic_vector(31 downto 0);
    signal icache_access_count : std_logic_vector(31 downto 0);

    -- Data Cache signals (Phase 6)
    signal dcache_mem_req : std_logic;
    signal dcache_mem_write : std_logic;
    signal dcache_mem_size : std_logic_vector(1 downto 0);
    signal dcache_mem_addr : std_logic_vector(31 downto 0);
    signal dcache_mem_data_in : std_logic_vector(31 downto 0);
    signal dcache_mem_data_out : std_logic_vector(31 downto 0);
    signal dcache_mem_ready : std_logic;
    signal dcache_hit_count : std_logic_vector(31 downto 0);
    signal dcache_miss_count : std_logic_vector(31 downto 0);
    signal dcache_read_count : std_logic_vector(31 downto 0);
    signal dcache_write_count : std_logic_vector(31 downto 0);

    -- Branch Prediction signals (Phase 8)
    signal branch_predict_valid : std_logic;
    signal branch_predict_taken : std_logic;
    signal branch_predict_target : std_logic_vector(31 downto 0);
    signal branch_btb_hit : std_logic;
    signal branch_ras_hit : std_logic;
    signal branch_resolve_en : std_logic;
    signal branch_resolve_type : branch_type_t;
    signal branch_resolve_taken : std_logic;
    signal branch_resolve_target : std_logic_vector(31 downto 0);
    signal branch_mispredict : std_logic;
    signal branch_correct_target : std_logic_vector(31 downto 0);
    signal branch_count : std_logic_vector(31 downto 0);
    signal branch_correct_count : std_logic_vector(31 downto 0);
    signal branch_mispredict_count : std_logic_vector(31 downto 0);
    signal ccr_register : std_logic_vector(7 downto 0) := (others => '0');

    -- MMU signals (Phase 9)
    signal mmu_tc_reg : tc_register_t := TC_REGISTER_INIT;
    signal mmu_srp_reg : root_pointer_t := ROOT_POINTER_INIT;
    signal mmu_urp_reg : root_pointer_t := ROOT_POINTER_INIT;
    signal mmu_mmusr_reg : mmusr_register_t;
    signal mmu_itrans_req : translation_request_t := TRANSLATION_REQUEST_INIT;
    signal mmu_itrans_resp : translation_response_t;
    signal mmu_dtrans_req : translation_request_t := TRANSLATION_REQUEST_INIT;
    signal mmu_dtrans_resp : translation_response_t;
    signal mmu_invalidate_all : std_logic := '0';
    signal mmu_invalidate_i : std_logic := '0';
    signal mmu_invalidate_d : std_logic := '0';
    signal mmu_flush_d : std_logic := '0';
    signal mmu_iatc_lookups : std_logic_vector(31 downto 0);
    signal mmu_iatc_hits : std_logic_vector(31 downto 0);
    signal mmu_iatc_misses : std_logic_vector(31 downto 0);
    signal mmu_datc_lookups : std_logic_vector(31 downto 0);
    signal mmu_datc_hits : std_logic_vector(31 downto 0);
    signal mmu_datc_misses : std_logic_vector(31 downto 0);

    -- FPU signals (Phase 10)
    signal fpu_enable : std_logic := '0';
    signal fpu_operation : fp_operation_t := FP_OP_NOP;
    signal fpu_rounding_mode : fp_rounding_t := ROUND_NEAREST;
    signal fpu_src_reg_a : std_logic_vector(2 downto 0) := (others => '0');
    signal fpu_src_reg_b : std_logic_vector(2 downto 0) := (others => '0');
    signal fpu_dst_reg : std_logic_vector(2 downto 0) := (others => '0');
    signal fpu_write_enable : std_logic := '0';
    signal fpu_data_in : std_logic_vector(79 downto 0) := (others => '0');
    signal fpu_data_out : std_logic_vector(79 downto 0);
    signal fpu_result_valid : std_logic;
    signal fpu_busy : std_logic;
    signal fpu_fpsr : fpsr_register_t;
    signal fpu_fpcr : fpcr_register_t := FPCR_REGISTER_INIT;
    signal fpu_operations : std_logic_vector(31 downto 0);
    signal fpu_exceptions : std_logic_vector(31 downto 0);

    -- Exception signals (Phase 11)
    -- Exception detection in each pipeline stage
    signal if_exception : exception_info_t := EXCEPTION_INFO_NONE;
    signal id_exception : exception_info_t := EXCEPTION_INFO_NONE;
    signal ea_exception : exception_info_t := EXCEPTION_INFO_NONE;
    signal of_exception : exception_info_t := EXCEPTION_INFO_NONE;
    signal ex_exception : exception_info_t := EXCEPTION_INFO_NONE;

    -- Exception arbitration
    signal exception_pending : exception_info_t := EXCEPTION_INFO_NONE;
    signal exception_active : std_logic := '0';

    -- Status register
    signal sr_register : status_register_t := SR_INIT;

    -- Vector Base Register (VBR)
    signal vbr_register : std_logic_vector(31 downto 0) := (others => '0');

    -- Exception statistics
    signal exception_count : std_logic_vector(31 downto 0) := (others => '0');
    signal interrupt_count : std_logic_vector(31 downto 0) := (others => '0');

    -- Component declarations
    component TG68040_ICache is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            cache_enable   : in std_logic;
            cache_freeze   : in std_logic;
            cache_invalidate : in std_logic;
            fetch_req      : in std_logic;
            fetch_addr     : in std_logic_vector(31 downto 0);
            fetch_data     : out std_logic_vector(15 downto 0);
            fetch_ready    : out std_logic;
            mem_req        : out std_logic;
            mem_addr       : out std_logic_vector(31 downto 0);
            mem_data       : in std_logic_vector(127 downto 0);
            mem_ready      : in std_logic;
            hit_count      : out std_logic_vector(31 downto 0);
            miss_count     : out std_logic_vector(31 downto 0);
            access_count   : out std_logic_vector(31 downto 0)
        );
    end component;

    component TG68040_DCache is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            cache_enable   : in std_logic;
            cache_freeze   : in std_logic;
            cache_invalidate : in std_logic;
            cache_flush    : in std_logic;
            mem_req        : in std_logic;
            mem_write      : in std_logic;
            mem_size       : in std_logic_vector(1 downto 0);
            mem_addr       : in std_logic_vector(31 downto 0);
            mem_data_in    : in std_logic_vector(31 downto 0);
            mem_data_out   : out std_logic_vector(31 downto 0);
            mem_ready      : out std_logic;
            bus_req        : out std_logic;
            bus_write      : out std_logic;
            bus_addr       : out std_logic_vector(31 downto 0);
            bus_data_in    : out std_logic_vector(127 downto 0);
            bus_data_out   : in std_logic_vector(127 downto 0);
            bus_ready      : in std_logic;
            hit_count      : out std_logic_vector(31 downto 0);
            miss_count     : out std_logic_vector(31 downto 0);
            read_count     : out std_logic_vector(31 downto 0);
            write_count    : out std_logic_vector(31 downto 0)
        );
    end component;

    component TG68040_HazardUnit is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            id_ea_valid    : in std_logic;
            id_ea_src_reg1 : in std_logic_vector(3 downto 0);
            id_ea_src_reg2 : in std_logic_vector(3 downto 0);
            id_ea_dst_reg  : in std_logic_vector(3 downto 0);
            id_ea_write    : in std_logic;
            ea_of_valid    : in std_logic;
            ea_of_dst_reg  : in std_logic_vector(3 downto 0);
            ea_of_write    : in std_logic;
            of_ex_valid    : in std_logic;
            of_ex_dst_reg  : in std_logic_vector(3 downto 0);
            of_ex_write    : in std_logic;
            of_ex_read_mem : in std_logic;
            ex_wb_valid    : in std_logic;
            ex_wb_dst_reg  : in std_logic_vector(3 downto 0);
            ex_wb_write    : in std_logic;
            hazard_info    : out hazard_info_t;
            stall_pipeline : out std_logic
        );
    end component;

    component TG68040_BranchUnit is
        port(
            clk                 : in std_logic;
            reset               : in std_logic;
            predict_pc          : in std_logic_vector(31 downto 0);
            predict_instr       : in std_logic_vector(15 downto 0);
            predict_valid       : out std_logic;
            predict_taken       : out std_logic;
            predict_target      : out std_logic_vector(31 downto 0);
            btb_hit             : out std_logic;
            ras_hit             : out std_logic;
            resolve_en          : in std_logic;
            resolve_pc          : in std_logic_vector(31 downto 0);
            resolve_type        : in branch_type_t;
            resolve_taken       : in std_logic;
            resolve_target      : in std_logic_vector(31 downto 0);
            resolve_ccr         : in std_logic_vector(7 downto 0);
            mispredict          : out std_logic;
            correct_target      : out std_logic_vector(31 downto 0);
            predicted_taken_if  : in std_logic;
            predicted_target_if : in std_logic_vector(31 downto 0);
            branches            : out std_logic_vector(31 downto 0);
            correct_preds       : out std_logic_vector(31 downto 0);
            mispreds            : out std_logic_vector(31 downto 0);
            btb_hits            : out std_logic_vector(31 downto 0);
            btb_misses          : out std_logic_vector(31 downto 0);
            ras_hits_stat       : out std_logic_vector(31 downto 0);
            ras_misses          : out std_logic_vector(31 downto 0)
        );
    end component;

    component TG68040_MMU is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            tc_reg         : in tc_register_t;
            srp_reg        : in root_pointer_t;
            urp_reg        : in root_pointer_t;
            mmusr_reg      : out mmusr_register_t;
            itrans_req     : in translation_request_t;
            itrans_resp    : out translation_response_t;
            dtrans_req     : in translation_request_t;
            dtrans_resp    : out translation_response_t;
            invalidate_all : in std_logic;
            invalidate_i   : in std_logic;
            invalidate_d   : in std_logic;
            flush_d        : in std_logic;
            iatc_lookups   : out std_logic_vector(31 downto 0);
            iatc_hits      : out std_logic_vector(31 downto 0);
            iatc_misses    : out std_logic_vector(31 downto 0);
            datc_lookups   : out std_logic_vector(31 downto 0);
            datc_hits      : out std_logic_vector(31 downto 0);
            datc_misses    : out std_logic_vector(31 downto 0)
        );
    end component;

    component TG68040_FPU is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            enable         : in std_logic;
            operation      : in fp_operation_t;
            rounding_mode  : in fp_rounding_t;
            src_reg_a      : in std_logic_vector(2 downto 0);
            src_reg_b      : in std_logic_vector(2 downto 0);
            dst_reg        : in std_logic_vector(2 downto 0);
            write_enable   : in std_logic;
            data_in        : in std_logic_vector(79 downto 0);
            data_out       : out std_logic_vector(79 downto 0);
            result_valid   : out std_logic;
            busy           : out std_logic;
            fpsr           : out fpsr_register_t;
            fpcr           : in fpcr_register_t;
            operations     : out std_logic_vector(31 downto 0);
            exceptions     : out std_logic_vector(31 downto 0)
        );
    end component;

begin

    -- Outputs
    pipeline_busy <= any_valid;
    pipeline_stalled <= global_stall;
    pipeline_flushed <= global_flush;
    instructions_completed <= std_logic_vector(stats.instrs_total);

    -- Global control signals
    any_valid <= if_id.valid or id_ea.valid or ea_of.valid or of_ex.valid or ex_wb.valid;
    global_stall <= ctrl.stall_if or ctrl.stall_id or ctrl.stall_ea or ctrl.stall_of or ctrl.stall_ex;
    global_flush <= ctrl.flush_if or ctrl.flush_id or ctrl.flush_ea or ctrl.flush_of or ctrl.flush_ex;

    -- Next PC calculation (Phase 8: with branch prediction)
    pc_next <= unsigned(branch_correct_target) when branch_mispredict = '1' else  -- Misprediction
               unsigned(branch_predict_target) when (branch_predict_valid = '1' and branch_predict_taken = '1' and global_stall = '0') else  -- Predicted taken
               pc + 2 when global_stall = '0' else  -- Sequential
               pc;  -- Stalled

    ------------------------------------------------------------------------------
    -- Hazard Detection Unit (Phase 4+6)
    ------------------------------------------------------------------------------
    hazard_unit: TG68040_HazardUnit
        port map(
            clk            => clk,
            reset          => reset,
            id_ea_valid    => id_ea.valid,
            id_ea_src_reg1 => id_ea.src_reg1,
            id_ea_src_reg2 => id_ea.src_reg2,
            id_ea_dst_reg  => id_ea.dst_reg,
            id_ea_write    => '1',  -- Simplified: assume all INSTR_OTHER write
            ea_of_valid    => ea_of.valid,
            ea_of_dst_reg  => ea_of.dst_reg,
            ea_of_write    => '1',  -- Simplified
            of_ex_valid    => of_ex.valid,
            of_ex_dst_reg  => of_ex.dst_reg,
            of_ex_write    => of_ex.write_reg,
            of_ex_read_mem => of_ex.read_mem,  -- Phase 6
            ex_wb_valid    => ex_wb.valid,
            ex_wb_dst_reg  => ex_wb.dst_reg,
            ex_wb_write    => ex_wb.write_reg,
            hazard_info    => hazard_info,
            stall_pipeline => hazard_stall
        );

    ------------------------------------------------------------------------------
    -- Branch Prediction Unit (Phase 8)
    ------------------------------------------------------------------------------
    branch_unit: TG68040_BranchUnit
        port map(
            clk                 => clk,
            reset               => reset,
            predict_pc          => std_logic_vector(pc),
            predict_instr       => icache_fetch_data,
            predict_valid       => branch_predict_valid,
            predict_taken       => branch_predict_taken,
            predict_target      => branch_predict_target,
            btb_hit             => branch_btb_hit,
            ras_hit             => branch_ras_hit,
            resolve_en          => branch_resolve_en,
            resolve_pc          => of_ex.pc,
            resolve_type        => branch_resolve_type,
            resolve_taken       => branch_resolve_taken,
            resolve_target      => branch_resolve_target,
            resolve_ccr         => ccr_register,
            mispredict          => branch_mispredict,
            correct_target      => branch_correct_target,
            predicted_taken_if  => of_ex.predicted_taken,
            predicted_target_if => of_ex.predicted_target,
            branches            => branch_count,
            correct_preds       => branch_correct_count,
            mispreds            => branch_mispredict_count,
            btb_hits            => open,
            btb_misses          => open,
            ras_hits_stat       => open,
            ras_misses          => open
        );

    ------------------------------------------------------------------------------
    -- MMU (Phase 9)
    ------------------------------------------------------------------------------
    mmu_inst: TG68040_MMU
        port map(
            clk            => clk,
            reset          => reset,
            tc_reg         => mmu_tc_reg,
            srp_reg        => mmu_srp_reg,
            urp_reg        => mmu_urp_reg,
            mmusr_reg      => mmu_mmusr_reg,
            itrans_req     => mmu_itrans_req,
            itrans_resp    => mmu_itrans_resp,
            dtrans_req     => mmu_dtrans_req,
            dtrans_resp    => mmu_dtrans_resp,
            invalidate_all => mmu_invalidate_all,
            invalidate_i   => mmu_invalidate_i,
            invalidate_d   => mmu_invalidate_d,
            flush_d        => mmu_flush_d,
            iatc_lookups   => mmu_iatc_lookups,
            iatc_hits      => mmu_iatc_hits,
            iatc_misses    => mmu_iatc_misses,
            datc_lookups   => mmu_datc_lookups,
            datc_hits      => mmu_datc_hits,
            datc_misses    => mmu_datc_misses
        );

    ------------------------------------------------------------------------------
    -- FPU (Phase 10)
    ------------------------------------------------------------------------------
    fpu_inst: TG68040_FPU
        port map(
            clk            => clk,
            reset          => reset,
            enable         => fpu_enable,
            operation      => fpu_operation,
            rounding_mode  => fpu_rounding_mode,
            src_reg_a      => fpu_src_reg_a,
            src_reg_b      => fpu_src_reg_b,
            dst_reg        => fpu_dst_reg,
            write_enable   => fpu_write_enable,
            data_in        => fpu_data_in,
            data_out       => fpu_data_out,
            result_valid   => fpu_result_valid,
            busy           => fpu_busy,
            fpsr           => fpu_fpsr,
            fpcr           => fpu_fpcr,
            operations     => fpu_operations,
            exceptions     => fpu_exceptions
        );

    ------------------------------------------------------------------------------
    -- Instruction Cache (Phase 5)
    ------------------------------------------------------------------------------
    icache: TG68040_ICache
        port map(
            clk            => clk,
            reset          => reset,
            cache_enable   => '1',  -- Always enabled for Phase 5
            cache_freeze   => '0',  -- Not frozen
            cache_invalidate => '0',  -- No invalidation for now
            fetch_req      => icache_fetch_req,
            fetch_addr     => icache_fetch_addr,
            fetch_data     => icache_fetch_data,
            fetch_ready    => icache_fetch_ready,
            mem_req        => open,  -- Unused in stub
            mem_addr       => open,  -- Unused in stub
            mem_data       => (others => '0'),
            mem_ready      => '0',
            hit_count      => icache_hit_count,
            miss_count     => icache_miss_count,
            access_count   => icache_access_count
        );

    ------------------------------------------------------------------------------
    -- D-ATC Translation (Phase 9)
    ------------------------------------------------------------------------------
    -- Create D-ATC translation request (combinational)
    -- Translation happens for memory operations in EA/MEM stages
    mmu_dtrans_req.logical_addr <= ea_of.ea_addr;
    mmu_dtrans_req.access_type <= ACCESS_WRITE when ea_of.use_ea = '1' and of_ex.write_mem = '1' else ACCESS_READ;
    mmu_dtrans_req.supervisor <= '1';  -- Simplified: always supervisor mode
    mmu_dtrans_req.enable <= ea_of.use_ea;  -- Enable when EA is valid for memory ops

    -- D-Cache access uses physical address from D-ATC
    dcache_mem_addr <= mmu_dtrans_resp.physical_addr;
    dcache_mem_req <= ea_of.use_ea and mmu_dtrans_resp.ready when mmu_dtrans_resp.fault = FAULT_NONE else '0';

    ------------------------------------------------------------------------------
    -- Data Cache (Phase 6)
    ------------------------------------------------------------------------------
    dcache: TG68040_DCache
        port map(
            clk            => clk,
            reset          => reset,
            cache_enable   => '1',  -- Always enabled for Phase 6
            cache_freeze   => '0',  -- Not frozen
            cache_invalidate => '0',  -- No invalidation for now
            cache_flush    => '0',  -- No flush for now
            mem_req        => dcache_mem_req,
            mem_write      => dcache_mem_write,
            mem_size       => dcache_mem_size,
            mem_addr       => dcache_mem_addr,
            mem_data_in    => dcache_mem_data_in,
            mem_data_out   => dcache_mem_data_out,
            mem_ready      => dcache_mem_ready,
            bus_req        => open,  -- Unused in stub
            bus_write      => open,  -- Unused in stub
            bus_addr       => open,  -- Unused in stub
            bus_data_in    => open,  -- Unused in stub
            bus_data_out   => (others => '0'),
            bus_ready      => '0',
            hit_count      => dcache_hit_count,
            miss_count     => dcache_miss_count,
            read_count     => dcache_read_count,
            write_count    => dcache_write_count
        );

    ------------------------------------------------------------------------------
    -- Data Forwarding Multiplexers (Phase 4)
    ------------------------------------------------------------------------------
    -- Operand A forwarding (priority: EX > WB > RegFile)
    operand1_forwarded <=
        of_ex.result when hazard_info.forward_ex_a = '1' else
        ex_wb.result when hazard_info.forward_wb_a = '1' else
        reg_data_a;

    -- Operand B forwarding (priority: EX > WB > RegFile)
    operand2_forwarded <=
        of_ex.result when hazard_info.forward_ex_b = '1' else
        ex_wb.result when hazard_info.forward_wb_b = '1' else
        reg_data_b;

    ------------------------------------------------------------------------------
    -- IF Stage: Instruction Fetch (with I-Cache + MMU, Phase 5 + 9)
    ------------------------------------------------------------------------------
    -- I-ATC translation request (combinational, Phase 9)
    mmu_itrans_req.logical_addr <= std_logic_vector(pc);
    mmu_itrans_req.access_type <= ACCESS_EXECUTE;
    mmu_itrans_req.supervisor <= '1';  -- Simplified: always supervisor mode
    mmu_itrans_req.enable <= '1' when (enable = '1' and ctrl.stall_if = '0' and ctrl.flush_if = '0') else '0';

    -- Cache fetch request (combinational)
    -- Use physical address from I-ATC for cache lookup
    icache_fetch_req <= '1' when (enable = '1' and ctrl.stall_if = '0' and ctrl.flush_if = '0' and mmu_itrans_resp.ready = '1') else '0';
    icache_fetch_addr <= mmu_itrans_resp.physical_addr;

    -- IF stage process
    if_stage: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                if_id <= IF_ID_REG_INIT;
                pc <= (others => '0');

            elsif enable = '1' then
                if ctrl.flush_if = '1' then
                    -- Flush this stage
                    if_id.valid <= '0';

                elsif ctrl.stall_if = '0' then
                    -- Fetch from I-cache (Phase 5)
                    -- Stub always returns ready in 1 cycle
                    if icache_fetch_ready = '1' then
                        if_id.valid <= '1';
                        if_id.pc <= std_logic_vector(pc);
                        if_id.instruction <= icache_fetch_data;
                        if_id.exception <= '0';

                        -- Phase 8: Store branch prediction
                        if_id.predicted_taken <= branch_predict_taken;
                        if_id.predicted_target <= branch_predict_target;
                        if_id.btb_hit <= branch_btb_hit;
                        if_id.ras_hit <= branch_ras_hit;

                        -- Update PC
                        pc <= pc_next;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- ID Stage: Instruction Decode
    ------------------------------------------------------------------------------
    id_stage: process(clk)
        variable opcode_high : std_logic_vector(3 downto 0);
        variable branch_type_var : branch_type_t;
        variable branch_info_var : branch_info_t;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                id_ea <= ID_EA_REG_INIT;

            elsif enable = '1' then
                if ctrl.flush_id = '1' then
                    id_ea.valid <= '0';

                elsif ctrl.stall_id = '0' then
                    -- Transfer data from IF/ID
                    id_ea.valid <= if_id.valid;
                    id_ea.pc <= if_id.pc;
                    id_ea.opcode <= if_id.instruction;
                    opcode_high := if_id.instruction(15 downto 12);

                    -- Phase 8: Detect branches
                    branch_type_var := decode_branch_type(if_id.instruction);
                    if branch_type_var /= BRANCH_NONE then
                        branch_info_var.is_branch := '1';
                        branch_info_var.branch_type := branch_type_var;
                        branch_info_var.condition := decode_branch_condition(if_id.instruction);
                        branch_info_var.displacement := get_branch_displacement(if_id.instruction, (others => '0'));
                        branch_info_var.target_addr := calculate_branch_target(
                            if_id.pc, branch_info_var.displacement, branch_type_var);
                        branch_info_var.predicted_taken := if_id.predicted_taken;
                        branch_info_var.predicted_target := if_id.predicted_target;
                    else
                        branch_info_var := BRANCH_INFO_INIT;
                    end if;
                    id_ea.branch_info <= branch_info_var;
                    id_ea.predicted_taken <= if_id.predicted_taken;
                    id_ea.predicted_target <= if_id.predicted_target;

                    -- Phase 10: Detect FP instructions (F-line instructions)
                    -- F-line instructions have bits 15-12 = "1111" (0xF)
                    if opcode_high = x"F" then
                        -- FP instruction detected
                        -- For Phase 10 baseline: simple FADD stub
                        -- Real decode would extract operation, source/dest FP regs
                        fpu_enable <= '1';
                        fpu_operation <= FP_OP_ADD;  -- Stub: always ADD for now
                        fpu_src_reg_a <= if_id.instruction(2 downto 0);   -- Source FP reg
                        fpu_src_reg_b <= if_id.instruction(9 downto 7);   -- Dest FP reg (also src2)
                        fpu_dst_reg <= if_id.instruction(9 downto 7);     -- Dest FP reg
                        fpu_write_enable <= '1';
                        fpu_rounding_mode <= ROUND_NEAREST;

                        -- Mark as FP instruction (don't execute in integer pipeline)
                        id_ea.instr_type <= INSTR_NONE;
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');
                    else
                        -- Non-FP instruction
                        fpu_enable <= '0';
                    end if;

                    -- Simple decode (Phase 3 - basic instruction set)
                    if if_id.instruction = x"4E71" then
                        -- NOP instruction
                        id_ea.instr_type <= INSTR_NONE;
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');

                    elsif opcode_high = x"D" or opcode_high = x"9" then
                        -- ADD/SUB Dn,Dn (simplified)
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);   -- Source Dn
                        id_ea.src_reg2 <= "0" & if_id.instruction(11 downto 9);  -- Dest Dn (also src2)
                        id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);   -- Dest Dn

                    elsif opcode_high = x"3" or opcode_high = x"2" or opcode_high = x"1" then
                        -- MOVE instruction (simplified - register direct only)
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source reg
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);  -- Dest reg

                    elsif opcode_high = x"4" then
                        -- Miscellaneous instructions (RTS, etc.)
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');

                    else
                        -- Other/unknown instruction - treat as NOP for Phase 3
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');
                    end if;

                    id_ea.immediate <= (others => '0');
                    id_ea.exception <= if_id.exception;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- EA Stage: Effective Address Calculation
    ------------------------------------------------------------------------------
    ea_stage: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ea_of <= EA_OF_REG_INIT;

            elsif enable = '1' then
                if ctrl.flush_ea = '1' then
                    ea_of.valid <= '0';

                elsif ctrl.stall_ea = '0' then
                    -- Transfer data from ID/EA
                    ea_of.valid <= id_ea.valid;
                    ea_of.pc <= id_ea.pc;
                    ea_of.instr_type <= id_ea.instr_type;
                    ea_of.opcode <= id_ea.opcode;
                    ea_of.dst_reg <= id_ea.dst_reg;

                    -- Phase 8: Propagate branch information
                    ea_of.branch_info <= id_ea.branch_info;
                    ea_of.predicted_taken <= id_ea.predicted_taken;
                    ea_of.predicted_target <= id_ea.predicted_target;

                    -- Calculate effective address (simplified for Phase 3)
                    -- For now, just pass through - real EA calc in future phases
                    ea_of.ea_addr <= id_ea.immediate;
                    ea_of.use_ea <= '0';  -- Don't use EA for simple register ops

                    ea_of.exception <= id_ea.exception;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- OF Stage: Operand Fetch
    ------------------------------------------------------------------------------
    of_stage: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                of_ex <= OF_EX_REG_INIT;

            elsif enable = '1' then
                if ctrl.flush_of = '1' then
                    of_ex.valid <= '0';

                elsif ctrl.stall_of = '0' then
                    -- Transfer data from EA/OF
                    of_ex.valid <= ea_of.valid;
                    of_ex.pc <= ea_of.pc;
                    of_ex.instr_type <= ea_of.instr_type;
                    of_ex.opcode <= ea_of.opcode;
                    of_ex.dst_reg <= ea_of.dst_reg;

                    -- Phase 8: Propagate branch information for resolution in EX
                    of_ex.branch_info <= ea_of.branch_info;
                    of_ex.predicted_taken <= ea_of.predicted_taken;
                    of_ex.predicted_target <= ea_of.predicted_target;
                    of_ex.ccr <= ccr_register;

                    -- Fetch operands with forwarding (Phase 4)
                    -- Use forwarded data if hazard detected, else register file
                    of_ex.operand1 <= operand1_forwarded;
                    of_ex.operand2 <= operand2_forwarded;

                    -- Determine if we need to write back
                    if ea_of.instr_type = INSTR_OTHER then
                        of_ex.write_reg <= '1';
                    else
                        of_ex.write_reg <= '0';
                    end if;

                    -- Memory operations (stub for Phase 6)
                    of_ex.write_mem <= '0';  -- No memory writes yet
                    of_ex.read_mem <= '0';   -- No memory reads yet

                    of_ex.exception <= ea_of.exception;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- EX Stage: Execute
    ------------------------------------------------------------------------------
    ex_stage: process(clk)
        variable opcode_high : std_logic_vector(3 downto 0);
        variable alu_result : unsigned(31 downto 0);
        variable alu_carry : std_logic;
        variable branch_actual_taken : std_logic;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ex_wb <= EX_WB_REG_INIT;

            elsif enable = '1' then
                if ctrl.flush_ex = '1' then
                    ex_wb.valid <= '0';

                elsif ctrl.stall_ex = '0' then
                    -- Transfer data from OF/EX
                    ex_wb.valid <= of_ex.valid;
                    ex_wb.pc <= of_ex.pc;
                    ex_wb.dst_reg <= of_ex.dst_reg;

                    -- Phase 8: Branch resolution
                    branch_resolve_en <= of_ex.branch_info.is_branch;
                    branch_resolve_type <= of_ex.branch_info.branch_type;
                    branch_resolve_target <= of_ex.branch_info.target_addr;

                    -- Evaluate branch condition for conditional branches
                    if of_ex.branch_info.branch_type = BRANCH_COND or
                       of_ex.branch_info.branch_type = BRANCH_DBCC then
                        branch_actual_taken := evaluate_branch_condition(
                            of_ex.branch_info.condition, of_ex.ccr);
                        branch_resolve_taken <= branch_actual_taken;
                    else
                        -- Unconditional branches always taken
                        branch_resolve_taken <= '1';
                    end if;

                    opcode_high := of_ex.opcode(15 downto 12);

                    -- Execute operation (Phase 3 - basic ALU operations)
                    if of_ex.instr_type = INSTR_NONE then
                        -- NOP - no result
                        ex_wb.result <= (others => '0');
                        ex_wb.flags <= (others => '0');

                    elsif opcode_high = x"D" then
                        -- ADD operation
                        alu_result := unsigned(of_ex.operand1) + unsigned(of_ex.operand2);
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Simple flag generation (N, Z, V, C)
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow (simplified)
                        ex_wb.flags(0) <= '0';  -- Carry (simplified)

                    elsif opcode_high = x"9" then
                        -- SUB operation
                        alu_result := unsigned(of_ex.operand2) - unsigned(of_ex.operand1);
                        ex_wb.result <= std_logic_vector(alu_result);
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow (simplified)
                        ex_wb.flags(0) <= '0';  -- Carry (simplified)

                    elsif opcode_high = x"3" or opcode_high = x"2" or opcode_high = x"1" then
                        -- MOVE operation - pass through operand1
                        ex_wb.result <= of_ex.operand1;
                        ex_wb.flags(3) <= of_ex.operand1(31);  -- Negative
                        if of_ex.operand1 = x"00000000" then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    else
                        -- Unknown operation - pass operand1
                        ex_wb.result <= of_ex.operand1;
                        ex_wb.flags <= (others => '0');
                    end if;

                    ex_wb.write_reg <= of_ex.write_reg;
                    ex_wb.write_mem <= of_ex.write_mem;
                    ex_wb.update_flags <= '1';  -- Update flags for all operations

                    -- Phase 8: Update CCR register for next cycle
                    if ex_wb.update_flags = '1' then
                        ccr_register <= ex_wb.flags;
                    end if;

                    ex_wb.exception <= of_ex.exception;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- WB Stage: Write Back
    ------------------------------------------------------------------------------
    wb_stage: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                reg_write_en <= '0';
                reg_write_addr <= (others => '0');
                reg_write_data <= (others => '0');
                instr_complete <= '0';

            elsif enable = '1' then
                instr_complete <= '0';

                if ex_wb.valid = '1' and ex_wb.exception = '0' then
                    -- Write back to register file
                    if ex_wb.write_reg = '1' then
                        reg_write_en <= '1';
                        reg_write_addr <= ex_wb.dst_reg;
                        reg_write_data <= ex_wb.result;
                    else
                        reg_write_en <= '0';
                    end if;

                    -- Instruction completed
                    instr_complete <= '1';
                else
                    reg_write_en <= '0';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Pipeline Control Logic (Phase 3+4+6+8)
    ------------------------------------------------------------------------------
    control_logic: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ctrl <= PIPELINE_CTRL_INIT;

            elsif enable = '1' then
                -- Default: no stalls or flushes
                ctrl <= PIPELINE_CTRL_INIT;

                -- Stall logic
                -- Stall if memory not ready
                if mem_ready = '0' then
                    ctrl.stall_if <= '1';
                    ctrl.stall_id <= '1';
                    ctrl.stall_ea <= '1';
                    ctrl.stall_of <= '1';
                    ctrl.stall_ex <= '1';
                end if;

                -- Stall for load-use hazards (Phase 6)
                if hazard_info.stall_for_load = '1' then
                    ctrl.stall_if <= '1';
                    ctrl.stall_id <= '1';
                    ctrl.stall_ea <= '1';
                end if;

                -- Phase 9: Stall for MMU translation
                -- Stall IF if I-ATC translation not ready
                if mmu_itrans_req.enable = '1' and mmu_itrans_resp.ready = '0' then
                    ctrl.stall_if <= '1';
                end if;

                -- Stall EA if D-ATC translation not ready
                if mmu_dtrans_req.enable = '1' and mmu_dtrans_resp.ready = '0' then
                    ctrl.stall_ea <= '1';
                end if;

                -- Handle MMU faults (generate exception)
                if mmu_itrans_resp.ready = '1' and mmu_itrans_resp.fault /= FAULT_NONE then
                    -- I-ATC fault: flush pipeline
                    ctrl.flush_if <= '1';
                    ctrl.flush_id <= '1';
                end if;

                if mmu_dtrans_resp.ready = '1' and mmu_dtrans_resp.fault /= FAULT_NONE then
                    -- D-ATC fault: flush EA stage and later
                    ctrl.flush_ea <= '1';
                    ctrl.flush_of <= '1';
                end if;

                -- Phase 8: Flush on branch misprediction
                -- When a misprediction is detected in EX stage, flush IF, ID, EA, OF stages
                -- (instructions that came after the branch)
                if branch_mispredict = '1' then
                    ctrl.flush_if <= '1';
                    ctrl.flush_id <= '1';
                    ctrl.flush_ea <= '1';
                    ctrl.flush_of <= '1';
                    -- Don't flush EX - let the branch complete
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Statistics Tracking
    ------------------------------------------------------------------------------
    stats_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                stats <= PIPELINE_STATS_INIT;

            elsif enable = '1' then
                -- Count cycles
                stats.cycles_total <= stats.cycles_total + 1;

                -- Count completed instructions
                if instr_complete = '1' then
                    stats.instrs_total <= stats.instrs_total + 1;
                end if;

                -- Count stalls
                if global_stall = '1' then
                    stats.stalls_total <= stats.stalls_total + 1;
                end if;

                -- Count flushes
                if global_flush = '1' then
                    stats.flushes_total <= stats.flushes_total + 1;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------------
    -- Memory Interface (Stub for Phase 3)
    ------------------------------------------------------------------------------
    mem_addr <= ea_of.ea_addr;
    mem_read <= '0';  -- Will be set when implementing memory operations
    mem_write <= '0';
    mem_data_write <= (others => '0');

    ------------------------------------------------------------------------------
    -- Register File Interface (Stub for Phase 3)
    ------------------------------------------------------------------------------
    reg_addr_a <= id_ea.src_reg1;
    reg_addr_b <= id_ea.src_reg2;

end rtl;
