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

    component TG68040_Exception_Unit is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            exception_in   : in exception_info_t;
            exception_ack  : out std_logic;
            rte_req        : in std_logic;
            rte_ack        : out std_logic;
            vbr            : in std_logic_vector(31 downto 0);
            ssp            : in std_logic_vector(31 downto 0);
            ssp_out        : out std_logic_vector(31 downto 0);
            ssp_write      : out std_logic;
            sr_in          : in status_register_t;
            sr_out         : out status_register_t;
            sr_write       : out std_logic;
            mem_req        : out std_logic;
            mem_write      : out std_logic;
            mem_addr       : out std_logic_vector(31 downto 0);
            mem_data_out   : out std_logic_vector(31 downto 0);
            mem_data_in    : in std_logic_vector(31 downto 0);
            mem_ready      : in std_logic;
            handler_pc     : out std_logic_vector(31 downto 0);
            handler_valid  : out std_logic;
            pipeline_flush : out std_logic;
            exceptions_processed : out std_logic_vector(31 downto 0);
            rte_count      : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Exception unit signals (Phase 11)
    signal exc_unit_ack : std_logic;
    signal exc_unit_rte_req : std_logic := '0';
    signal exc_unit_rte_ack : std_logic;
    signal exc_unit_ssp_out : std_logic_vector(31 downto 0);
    signal exc_unit_ssp_write : std_logic;
    signal exc_unit_sr_out : status_register_t;
    signal exc_unit_sr_write : std_logic;
    signal exc_unit_mem_req : std_logic;
    signal exc_unit_mem_write : std_logic;
    signal exc_unit_mem_addr : std_logic_vector(31 downto 0);
    signal exc_unit_mem_data_out : std_logic_vector(31 downto 0);
    signal exc_unit_mem_data_in : std_logic_vector(31 downto 0);
    signal exc_unit_handler_pc : std_logic_vector(31 downto 0);
    signal exc_unit_handler_valid : std_logic;
    signal exc_unit_flush : std_logic;
    signal exc_unit_exceptions_processed : std_logic_vector(31 downto 0);
    signal exc_unit_rte_count : std_logic_vector(31 downto 0);

    -- Supervisor Stack Pointer (A7 in supervisor mode)
    signal ssp_register : std_logic_vector(31 downto 0) := (others => '0');

begin

    -- Outputs
    pipeline_busy <= any_valid;
    pipeline_stalled <= global_stall;
    pipeline_flushed <= global_flush;
    instructions_completed <= std_logic_vector(stats.instrs_total);

    -- Global control signals
    any_valid <= if_id.valid or id_ea.valid or ea_of.valid or of_ex.valid or ex_wb.valid;
    global_stall <= ctrl.stall_if or ctrl.stall_id or ctrl.stall_ea or ctrl.stall_of or ctrl.stall_ex;
    global_flush <= ctrl.flush_if or ctrl.flush_id or ctrl.flush_ea or ctrl.flush_of or ctrl.flush_ex or exc_unit_flush;

    -- Next PC calculation (Phase 8 + Phase 11: with branch prediction and exception handling)
    pc_next <= unsigned(exc_unit_handler_pc) when exc_unit_handler_valid = '1' else  -- Exception handler (highest priority)
               unsigned(branch_correct_target) when branch_mispredict = '1' else     -- Misprediction
               unsigned(branch_predict_target) when (branch_predict_valid = '1' and branch_predict_taken = '1' and global_stall = '0') else  -- Predicted taken
               pc + 2 when global_stall = '0' else  -- Sequential
               pc;  -- Stalled

    ------------------------------------------------------------------------------
    -- Exception Unit Register Updates (Phase 11)
    ------------------------------------------------------------------------------
    -- Update SR and SSP when exception unit signals changes
    exception_reg_update: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                sr_register <= SR_INIT;
                ssp_register <= (others => '0');
                exception_count <= (others => '0');
            else
                -- Update SR when exception unit writes it
                if exc_unit_sr_write = '1' then
                    sr_register <= exc_unit_sr_out;
                end if;

                -- Update SSP when exception unit writes it
                if exc_unit_ssp_write = '1' then
                    ssp_register <= exc_unit_ssp_out;
                end if;

                -- Track exception count
                if exc_unit_ack = '1' then
                    exception_count <= std_logic_vector(unsigned(exception_count) + 1);
                end if;
            end if;
        end if;
    end process;

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
    -- Exception Unit (Phase 11)
    ------------------------------------------------------------------------------
    exception_unit: TG68040_Exception_Unit
        port map(
            clk            => clk,
            reset          => reset,
            exception_in   => exception_pending,
            exception_ack  => exc_unit_ack,
            rte_req        => exc_unit_rte_req,
            rte_ack        => exc_unit_rte_ack,
            vbr            => vbr_register,
            ssp            => ssp_register,
            ssp_out        => exc_unit_ssp_out,
            ssp_write      => exc_unit_ssp_write,
            sr_in          => sr_register,
            sr_out         => exc_unit_sr_out,
            sr_write       => exc_unit_sr_write,
            mem_req        => exc_unit_mem_req,
            mem_write      => exc_unit_mem_write,
            mem_addr       => exc_unit_mem_addr,
            mem_data_out   => exc_unit_mem_data_out,
            mem_data_in    => exc_unit_mem_data_in,
            mem_ready      => mem_ready,
            handler_pc     => exc_unit_handler_pc,
            handler_valid  => exc_unit_handler_valid,
            pipeline_flush => exc_unit_flush,
            exceptions_processed => exc_unit_exceptions_processed,
            rte_count      => exc_unit_rte_count
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
    -- Exception Detection and Arbitration (Phase 11)
    ------------------------------------------------------------------------------

    -- Exception detection process (combinational)
    -- Detects exceptions in each pipeline stage and arbitrates priorities
    exception_detection: process(all)
        variable temp_exception : exception_info_t;
        variable opcode : std_logic_vector(15 downto 0);
        variable opcode_high : std_logic_vector(3 downto 0);
        variable is_privileged : boolean;
        variable is_illegal : boolean;
        variable ea_addr : std_logic_vector(31 downto 0);
        variable is_misaligned : boolean;
    begin
        -- Initialize all exception signals
        if_exception <= EXCEPTION_INFO_NONE;
        id_exception <= EXCEPTION_INFO_NONE;
        ea_exception <= EXCEPTION_INFO_NONE;
        of_exception <= EXCEPTION_INFO_NONE;
        ex_exception <= EXCEPTION_INFO_NONE;

        ----------------------------------------------------------------------
        -- IF Stage Exception Detection
        ----------------------------------------------------------------------
        -- Bus error on instruction fetch (from MMU)
        if mmu_itrans_resp.ready = '1' and mmu_itrans_resp.fault /= FAULT_NONE then
            if_exception.valid <= '1';
            if_exception.exc_type <= EXC_BUS_ERROR;
            if_exception.vector <= VECTOR_BUS_ERROR;
            if_exception.priority <= PRIORITY_BUS_ERROR;
            if_exception.frame_format <= FRAME_FORMAT_7;  -- Access error frame
            if_exception.fault_addr <= mmu_itrans_resp.fault_address;
            if_exception.fault_pc <= std_logic_vector(pc);
            if_exception.fault_sr <= pack_sr(sr_register);
        end if;

        ----------------------------------------------------------------------
        -- ID Stage Exception Detection
        ----------------------------------------------------------------------
        if id_ea.valid = '1' then
            opcode := id_ea.opcode;
            opcode_high := opcode(15 downto 12);
            is_privileged := false;
            is_illegal := false;

            -- Detect privileged instructions
            -- Privileged instructions include: MOVE to SR, MOVE from SR, STOP, RESET, RTE, etc.
            if opcode = x"46FC" then
                -- MOVE #imm,SR - privileged
                is_privileged := true;
            elsif opcode = x"4E70" then
                -- RESET - privileged
                is_privileged := true;
            elsif opcode = x"4E72" then
                -- STOP - privileged
                is_privileged := true;
            elsif opcode = x"4E73" then
                -- RTE - privileged
                is_privileged := true;
            elsif opcode(15 downto 6) = "0100011011" then
                -- MOVE to SR - privileged (01000110 11xxxxxx)
                is_privileged := true;
            elsif opcode(15 downto 8) = x"F5" then
                -- CPUSHA, CINVA, etc. - privileged
                is_privileged := true;
            end if;

            -- Check if running in user mode (supervisor_mode = '0')
            if is_privileged and sr_register.supervisor_mode = '0' then
                -- Privilege violation
                id_exception.valid <= '1';
                id_exception.exc_type <= EXC_PRIVILEGE_VIOLATION;
                id_exception.vector <= VECTOR_PRIVILEGE_VIOLATION;
                id_exception.priority <= PRIORITY_PRIVILEGE;
                id_exception.frame_format <= FRAME_FORMAT_2;  -- Instruction exception frame
                id_exception.fault_pc <= id_ea.pc;
                id_exception.fault_sr <= pack_sr(sr_register);
            end if;

            -- Detect illegal instructions
            -- For Phase 11, we'll detect a few obvious illegal patterns
            if opcode(15 downto 12) = x"A" then
                -- Line A emulator trap (not illegal, but unimplemented)
                is_illegal := true;
            elsif opcode = x"4AFC" then
                -- ILLEGAL instruction
                is_illegal := true;
            end if;

            -- Only report illegal if no privilege violation (privilege has higher priority)
            if is_illegal and id_exception.valid = '0' then
                id_exception.valid <= '1';
                id_exception.exc_type <= EXC_ILLEGAL_INSTRUCTION;
                id_exception.vector <= VECTOR_ILLEGAL_INSTRUCTION;
                id_exception.priority <= PRIORITY_ILLEGAL;
                id_exception.frame_format <= FRAME_FORMAT_2;  -- Instruction exception frame
                id_exception.fault_pc <= id_ea.pc;
                id_exception.fault_sr <= pack_sr(sr_register);
            end if;
        end if;

        ----------------------------------------------------------------------
        -- EA Stage Exception Detection
        ----------------------------------------------------------------------
        -- Address error on misaligned access
        if ea_of.valid = '1' and ea_of.use_ea = '1' then
            ea_addr := ea_of.ea_addr;
            is_misaligned := false;

            -- Check for misaligned word/longword access
            -- MC68040 requires word (16-bit) accesses to be aligned to 2-byte boundaries
            -- and longword (32-bit) accesses to be aligned to 4-byte boundaries
            -- For this baseline, we'll check longword alignment only
            if ea_addr(1 downto 0) /= "00" then
                is_misaligned := true;
            end if;

            if is_misaligned then
                ea_exception.valid <= '1';
                ea_exception.exc_type <= EXC_ADDRESS_ERROR;
                ea_exception.vector <= VECTOR_ADDRESS_ERROR;
                ea_exception.priority <= PRIORITY_ADDRESS_ERROR;
                ea_exception.frame_format <= FRAME_FORMAT_7;  -- Access error frame
                ea_exception.fault_addr <= ea_addr;
                ea_exception.fault_pc <= ea_of.pc;
                ea_exception.fault_sr <= pack_sr(sr_register);
            end if;
        end if;

        ----------------------------------------------------------------------
        -- OF Stage Exception Detection
        ----------------------------------------------------------------------
        -- FP exceptions (reported from FPU)
        if of_ex.valid = '1' and fpu_fpsr.exception_status /= "00000000" then
            -- FP exception detected
            of_exception.valid <= '1';
            of_exception.exc_type <= EXC_FP_EXCEPTION;
            of_exception.vector <= x"30";  -- FP exception base vector (48)
            of_exception.priority <= PRIORITY_FP_EXCEPTION;
            of_exception.frame_format <= FRAME_FORMAT_0;  -- Normal frame for FP exceptions
            of_exception.fault_pc <= of_ex.pc;
            of_exception.fault_sr <= pack_sr(sr_register);
        end if;

        ----------------------------------------------------------------------
        -- EX Stage Exception Detection
        ----------------------------------------------------------------------
        -- Divide by zero detection
        if ex_wb.valid = '1' then
            opcode := of_ex.opcode;
            opcode_high := opcode(15 downto 12);

            -- Check for divide instructions (DIV/DIVU)
            -- DIV: opcode 1000xxx111xxxxxx (0x8xxx with specific bits)
            -- DIVU: opcode 1000xxx011xxxxxx
            if opcode_high = x"8" and
               (opcode(8 downto 6) = "011" or opcode(8 downto 6) = "111") then
                -- Check if divisor (operand1) is zero
                if of_ex.operand1 = x"00000000" then
                    ex_exception.valid <= '1';
                    ex_exception.exc_type <= EXC_DIVIDE_BY_ZERO;
                    ex_exception.vector <= VECTOR_DIVIDE_BY_ZERO;
                    ex_exception.priority <= PRIORITY_DIVIDE_BY_ZERO;
                    ex_exception.frame_format <= FRAME_FORMAT_0;  -- Normal frame
                    ex_exception.fault_pc <= ex_wb.pc;
                    ex_exception.fault_sr <= pack_sr(sr_register);
                end if;
            end if;
        end if;

        ----------------------------------------------------------------------
        -- Exception Priority Arbitration
        ----------------------------------------------------------------------
        -- Select highest priority exception from all stages
        -- Priority order: IF > ID > EA > OF > EX (earlier stages have priority for same level)

        temp_exception := EXCEPTION_INFO_NONE;

        -- Start with EX stage (lowest priority position)
        if ex_exception.valid = '1' then
            temp_exception := ex_exception;
        end if;

        -- Check OF stage
        if of_exception.valid = '1' then
            if exception_has_higher_priority(of_exception, temp_exception) then
                temp_exception := of_exception;
            end if;
        end if;

        -- Check EA stage
        if ea_exception.valid = '1' then
            if exception_has_higher_priority(ea_exception, temp_exception) then
                temp_exception := ea_exception;
            end if;
        end if;

        -- Check ID stage
        if id_exception.valid = '1' then
            if exception_has_higher_priority(id_exception, temp_exception) then
                temp_exception := id_exception;
            end if;
        end if;

        -- Check IF stage (highest priority position)
        if if_exception.valid = '1' then
            if exception_has_higher_priority(if_exception, temp_exception) then
                temp_exception := if_exception;
            end if;
        end if;

        -- Output the winning exception
        exception_pending <= temp_exception;
    end process;

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
                    -- Default: no immediate value (will be overridden by instructions that use it)
                    id_ea.immediate <= (others => '0');

                    -- Phase 12: CMPI instruction (simplified - immediate in lower byte)
                    if if_id.instruction(15 downto 8) = x"0C" then
                        -- CMPI #<data>,Dn (simplified)
                        -- Format: 0000 1100 SS 000 RRR
                        -- For simplification, treat bits 7-0 as 8-bit immediate (will be extended)
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= (others => '0');  -- No source register
                        id_ea.src_reg2 <= "0" & if_id.instruction(2 downto 0);  -- Dest register (for comparison)
                        id_ea.dst_reg <= (others => '0');  -- No destination (flags only)

                        -- Sign-extend 8-bit immediate to 32 bits (simplified)
                        if if_id.instruction(7) = '1' then
                            id_ea.immediate <= x"FFFFFF" & if_id.instruction(7 downto 0);
                        else
                            id_ea.immediate <= x"000000" & if_id.instruction(7 downto 0);
                        end if;

                    -- Phase 12G: Bit manipulation instructions (BTST, BCHG, BCLR, BSET)
                    elsif opcode_high = x"0" and if_id.instruction(5 downto 3) = "000" then
                        -- Bit operations with register bit number
                        -- Format: 0000 RRR OP 000 RRR
                        -- OP: 100=BTST, 101=BCHG, 110=BCLR, 111=BSET
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(11 downto 9);  -- Bit number register (Dn)
                        id_ea.src_reg2 <= "0" & if_id.instruction(2 downto 0);   -- Data register (Dn)
                        if if_id.instruction(8 downto 6) = "100" then
                            -- BTST: test only, no writeback
                            id_ea.dst_reg <= (others => '0');
                        else
                            -- BCHG, BCLR, BSET: write back modified value
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);
                        end if;

                    -- Phase 11D: RTE instruction detection
                    elsif if_id.instruction = x"4E73" then
                        -- RTE (Return from Exception) instruction
                        -- This is a privileged instruction and triggers RTE
                        exc_unit_rte_req <= '1';
                        id_ea.instr_type <= INSTR_NONE;
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');

                    -- Phase 12: MOVEQ instruction (MVIS)
                    elsif opcode_high = x"7" and if_id.instruction(8) = '0' then
                        -- MOVEQ #<data>,Dn
                        -- Format: 0111 RRR0 DDDDDDDD
                        -- Sign-extend 8-bit immediate to 32 bits
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= (others => '0');  -- No source register
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);  -- Destination Dn (D0-D7)

                        -- Sign-extend 8-bit immediate to 32 bits
                        if if_id.instruction(7) = '1' then
                            -- Negative number (bit 7 = 1)
                            id_ea.immediate <= x"FFFFFF" & if_id.instruction(7 downto 0);
                        else
                            -- Positive number (bit 7 = 0)
                            id_ea.immediate <= x"000000" & if_id.instruction(7 downto 0);
                        end if;

                    -- Phase 12D: DBcc instruction (Decrement and Branch conditionally)
                    elsif opcode_high = x"5" and if_id.instruction(7 downto 3) = "11001" then
                        -- DBcc Dn,<displacement>
                        -- Format: 0101 CCCC 11001 RRR
                        -- Operation: if !cc then Dn-1 → Dn; if Dn ≠ -1 then PC+d → PC
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Dn to test/decrement
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Write back to same Dn

                    -- Phase 12D: Scc instruction (Set According to Condition)
                    elsif opcode_high = x"5" and if_id.instruction(7 downto 6) = "11" and if_id.instruction(5 downto 3) /= "001" then
                        -- Scc <ea>
                        -- Format: 0101 CCCC 11 MMMRRR
                        -- Operation: if cc then 0xFF → <ea> else 0x00 → <ea>
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Destination Dn (byte operation)
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Write back to same Dn

                    elsif if_id.instruction = x"4E71" then
                        -- NOP instruction
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_NONE;
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');

                    elsif opcode_high = x"D" or opcode_high = x"9" then
                        exc_unit_rte_req <= '0';
                        -- Phase 12: Distinguish ADD/SUB vs ADDA/SUBA
                        if if_id.instruction(8 downto 6) = "011" or if_id.instruction(8 downto 6) = "111" then
                            -- ADDA/SUBA (opmode 011 for word, 111 for long)
                            -- Format: 1101/1001 RRR 0/1 11 MMM RRR (destination is An)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);   -- Source Dn
                            id_ea.src_reg2 <= "1" & if_id.instruction(11 downto 9);  -- Dest An (also src2)
                            id_ea.dst_reg <= "1" & if_id.instruction(11 downto 9);   -- Dest An
                        else
                            -- ADD/SUB Dn,Dn (data register operations)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);   -- Source Dn
                            id_ea.src_reg2 <= "0" & if_id.instruction(11 downto 9);  -- Dest Dn (also src2)
                            id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);   -- Dest Dn
                        end if;

                    elsif opcode_high = x"3" or opcode_high = x"2" or opcode_high = x"1" then
                        exc_unit_rte_req <= '0';
                        -- Phase 12F: Distinguish MOVE vs MOVEA
                        if (opcode_high = x"3" or opcode_high = x"2") and if_id.instruction(8 downto 6) = "001" then
                            -- MOVEA instruction (Move to Address register)
                            -- Format: 00SS AAA 001 MMM RRR (SS: 11=word, 10=long)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source Dn
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "1" & if_id.instruction(11 downto 9);  -- Dest An
                        else
                            -- MOVE instruction (simplified - register direct only)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source reg
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);  -- Dest reg
                        end if;

                    -- Phase 12: CMP instruction (0xBxxx, but check opmode to distinguish from EOR)
                    elsif opcode_high = x"B" and if_id.instruction(8 downto 6) = "000" then
                        -- CMP Dn,Dn (longword)
                        -- Format: 1011 DDD 0SS 000 SSS
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);   -- Source Dn
                        id_ea.src_reg2 <= "0" & if_id.instruction(11 downto 9);  -- Dest Dn
                        id_ea.dst_reg <= (others => '0');  -- No destination (flags only)

                    -- Phase 12A: CMPA instruction (0xBxxx with opmode 011 or 111)
                    elsif opcode_high = x"B" and (if_id.instruction(8 downto 6) = "011" or if_id.instruction(8 downto 6) = "111") then
                        -- CMPA Dn,An (longword) - Compare Address
                        -- Format: 1011 AAA 0/1 11 MMM RRR
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);   -- Source Dn
                        id_ea.src_reg2 <= "1" & if_id.instruction(11 downto 9);  -- Dest An
                        id_ea.dst_reg <= (others => '0');  -- No destination (flags only)

                    -- Phase 12: EOR instruction (0xBxxx with opmode 1xx)
                    elsif opcode_high = x"B" and if_id.instruction(8) = '1' then
                        -- EOR Dn,Dn (longword) - Exclusive OR
                        -- Format: 1011 DDD 1SS MMM RRR (Dn ^ <ea> → <ea>)
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(11 downto 9);  -- Source Dn (data)
                        id_ea.src_reg2 <= "0" & if_id.instruction(2 downto 0);   -- Dest Dn (also src2)
                        id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);    -- Dest Dn

                    -- Phase 12F: EXG instruction (0xCxxx with bit 8 = 1)
                    elsif opcode_high = x"C" and if_id.instruction(8) = '1' then
                        -- EXG - Exchange registers
                        -- Format: 1100 RRR 1 OPMODE RRR
                        -- Opmode: 01000 (Dx,Dy), 01001 (Ax,Ay), 10001 (Dx,Ay)
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        -- For EXG, we need both registers as sources and destinations
                        -- We'll handle the register type based on opmode in execution
                        if if_id.instruction(7 downto 3) = "01000" then
                            -- EXG Dx,Dy (data-data)
                            id_ea.src_reg1 <= "0" & if_id.instruction(11 downto 9);  -- Rx (data)
                            id_ea.src_reg2 <= "0" & if_id.instruction(2 downto 0);   -- Ry (data)
                            id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);   -- Will write to both
                        elsif if_id.instruction(7 downto 3) = "01001" then
                            -- EXG Ax,Ay (address-address)
                            id_ea.src_reg1 <= "1" & if_id.instruction(11 downto 9);  -- Rx (address)
                            id_ea.src_reg2 <= "1" & if_id.instruction(2 downto 0);   -- Ry (address)
                            id_ea.dst_reg <= "1" & if_id.instruction(11 downto 9);   -- Will write to both
                        else
                            -- EXG Dx,Ay (data-address) - opmode 10001
                            id_ea.src_reg1 <= "0" & if_id.instruction(11 downto 9);  -- Rx (data)
                            id_ea.src_reg2 <= "1" & if_id.instruction(2 downto 0);   -- Ry (address)
                            id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);   -- Will write to both
                        end if;

                    -- Phase 12: AND instruction (0xCxxx with opmode 0xx for Dn & <ea> → Dn)
                    elsif opcode_high = x"C" and if_id.instruction(8) = '0' then
                        -- AND Dn,Dn (longword) - Logical AND
                        -- Format: 1100 DDD 0SS MMM RRR (Dn & <ea> → Dn)
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);   -- Source Dn
                        id_ea.src_reg2 <= "0" & if_id.instruction(11 downto 9);  -- Dest Dn (also src2)
                        id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);   -- Dest Dn

                    -- Phase 12: OR instruction (0x8xxx with opmode 0xx for Dn | <ea> → Dn)
                    elsif opcode_high = x"8" and if_id.instruction(8) = '0' then
                        -- OR Dn,Dn (longword) - Logical OR
                        -- Format: 1000 DDD 0SS MMM RRR (Dn | <ea> → Dn)
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);   -- Source Dn
                        id_ea.src_reg2 <= "0" & if_id.instruction(11 downto 9);  -- Dest Dn (also src2)
                        id_ea.dst_reg <= "0" & if_id.instruction(11 downto 9);   -- Dest Dn

                    elsif opcode_high = x"4" then
                        exc_unit_rte_req <= '0';
                        -- Phase 12: Check for various 0x4xxx instructions
                        if if_id.instruction(15 downto 8) = x"4A" then
                            -- TST (Test) instruction
                            -- Format: 01001010 SS 000 RRR (data register direct)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source register to test
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= (others => '0');  -- No destination (flags only)
                        elsif if_id.instruction(15 downto 8) = x"46" then
                            -- NOT (Logical complement) instruction
                            -- Format: 01000110 SS 000 RRR (~<ea> → <ea>)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source register
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Dest = source
                        elsif if_id.instruction(15 downto 8) = x"44" then
                            -- NEG (Negate) instruction
                            -- Format: 01000100 SS 000 RRR (0 - <ea> → <ea>)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source register
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Dest = source
                        elsif if_id.instruction(15 downto 8) = x"40" then
                            -- NEGX (Negate with Extend) instruction (Phase 12A)
                            -- Format: 01000000 SS 000 RRR (0 - <ea> - X → <ea>)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source register
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Dest = source
                        elsif if_id.instruction(15 downto 8) = x"42" then
                            -- CLR (Clear) instruction
                            -- Format: 01000010 SS 000 RRR (0 → <ea>)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= (others => '0');  -- No source (always zero)
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Dest register
                        elsif if_id.instruction(15 downto 8) = x"48" and if_id.instruction(7 downto 3) = "01000" then
                            -- Phase 12F: SWAP instruction
                            -- Format: 01001000 01000 RRR (Swap words of Dn)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source register
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Dest = source
                        elsif if_id.instruction(15 downto 8) = x"48" and (if_id.instruction(7 downto 3) = "10000" or if_id.instruction(7 downto 3) = "11000") then
                            -- Phase 12F: EXT instruction
                            -- Format: 01001000 1X000 RRR (X=0: byte→word, X=1: word→long)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source register
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Dest = source
                        elsif if_id.instruction(15 downto 8) = x"49" and if_id.instruction(7 downto 3) = "11000" then
                            -- Phase 12F: EXTB.L instruction (byte→long)
                            -- Format: 01001001 11000 RRR
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Source register
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);   -- Dest = source
                        else
                            -- Other miscellaneous instructions (RTS, etc.)
                            id_ea.instr_type <= INSTR_OTHER;
                            id_ea.src_reg1 <= (others => '0');
                            id_ea.src_reg2 <= (others => '0');
                            id_ea.dst_reg <= (others => '0');
                        end if;

                    -- Phase 12: Bcc (branch) instructions (MVIS)
                    -- These are already detected by branch unit, just mark as INSTR_NONE
                    elsif opcode_high = x"6" then
                        -- Bcc family (BRA, Bcc)
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_NONE;  -- No ALU operation (handled by branch unit)
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');

                    -- Phase 12B: Shift/Rotate instructions
                    elsif opcode_high = x"E" then
                        -- Shift/Rotate family (ASL, ASR, LSL, LSR, ROL, ROR, ROXL, ROXR)
                        -- Format: 1110 CCC D SS i 00 RRR
                        -- CCC: Count (immediate or register)
                        -- D: Direction (0=right, 1=left)
                        -- SS: Size (00=byte, 01=word, 10=long)
                        -- i: 0=immediate, 1=register
                        -- RRR: Register
                        exc_unit_rte_req <= '0';
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= "0" & if_id.instruction(2 downto 0);  -- Data register
                        if if_id.instruction(5) = '1' then
                            -- Register count: Dy specified in bits 11-9
                            id_ea.src_reg2 <= "0" & if_id.instruction(11 downto 9);  -- Count register
                        else
                            -- Immediate count in bits 11-9 (000=8, 001-111=1-7)
                            id_ea.src_reg2 <= (others => '0');
                        end if;
                        id_ea.dst_reg <= "0" & if_id.instruction(2 downto 0);  -- Dest = source
                        -- Store immediate count in immediate field for easy access
                        if if_id.instruction(5) = '0' then
                            if if_id.instruction(11 downto 9) = "000" then
                                id_ea.immediate <= x"00000008";  -- Count = 8
                            else
                                id_ea.immediate <= x"0000000" & "0" & if_id.instruction(11 downto 9);  -- Count = 1-7
                            end if;
                        else
                            id_ea.immediate <= (others => '0');
                        end if;

                    else
                        exc_unit_rte_req <= '0';
                        -- Other/unknown instruction - treat as NOP for Phase 3
                        id_ea.instr_type <= INSTR_OTHER;
                        id_ea.src_reg1 <= (others => '0');
                        id_ea.src_reg2 <= (others => '0');
                        id_ea.dst_reg <= (others => '0');
                    end if;

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
                    -- Phase 12: For MOVEQ and CMPI, use immediate value from ea_addr
                    if ea_of.opcode(15 downto 12) = x"7" and ea_of.opcode(8) = '0' then
                        -- MOVEQ: use immediate value from EA stage
                        of_ex.operand1 <= ea_of.ea_addr;
                        of_ex.operand2 <= (others => '0');
                    elsif ea_of.opcode(15 downto 8) = x"0C" then
                        -- CMPI: use immediate value from EA stage, register in operand2
                        of_ex.operand1 <= ea_of.ea_addr;  -- Immediate value
                        of_ex.operand2 <= operand2_forwarded;  -- Register value
                    elsif ea_of.opcode(15 downto 12) = x"E" then
                        -- Phase 12B: Shift/Rotate instructions
                        of_ex.operand1 <= operand1_forwarded;  -- Data register
                        if ea_of.opcode(5) = '0' then
                            -- Immediate shift count from ea_addr
                            of_ex.operand2 <= ea_of.ea_addr;
                        else
                            -- Register shift count (use lower 6 bits only)
                            of_ex.operand2 <= operand2_forwarded;
                        end if;
                    else
                        -- Normal register operands with forwarding
                        of_ex.operand1 <= operand1_forwarded;
                        of_ex.operand2 <= operand2_forwarded;
                    end if;

                    -- Determine if we need to write back
                    -- Phase 12: CMP, TST, CMPI, CMPA, and BTST don't write to registers (flags only)
                    if ea_of.instr_type = INSTR_OTHER then
                        -- Check if it's CMP, CMPA, TST, CMPI, or BTST (flags only, no writeback)
                        if (ea_of.opcode(15 downto 12) = x"B" and (ea_of.opcode(8 downto 6) = "000" or
                                                                     ea_of.opcode(8 downto 6) = "011" or
                                                                     ea_of.opcode(8 downto 6) = "111")) or
                           (ea_of.opcode(15 downto 8) = x"4A") or
                           (ea_of.opcode(15 downto 8) = x"0C") or
                           (ea_of.opcode(15 downto 12) = x"0" and ea_of.opcode(8 downto 6) = "100" and ea_of.opcode(5 downto 3) = "000") then
                            of_ex.write_reg <= '0';  -- CMP, CMPA, TST, CMPI, or BTST: no register write
                        else
                            of_ex.write_reg <= '1';  -- Normal instruction: write result
                        end if;
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
                        -- ADD/ADDA operation
                        alu_result := unsigned(of_ex.operand1) + unsigned(of_ex.operand2);
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Phase 12: ADDA doesn't affect flags (opmode 011 or 111)
                        if of_ex.opcode(8 downto 6) = "011" or of_ex.opcode(8 downto 6) = "111" then
                            -- ADDA - don't update flags
                            ex_wb.flags <= (others => '0');
                        else
                            -- ADD - update flags (N, Z, V, C) with proper overflow/carry
                            ex_wb.flags(3) <= alu_result(31);  -- Negative
                            if alu_result = 0 then
                                ex_wb.flags(2) <= '1';  -- Zero
                            else
                                ex_wb.flags(2) <= '0';
                            end if;
                            -- Overflow: (A[31] == B[31]) AND (A[31] != Result[31])
                            ex_wb.flags(1) <= (of_ex.operand1(31) xnor of_ex.operand2(31)) and
                                              (of_ex.operand1(31) xor alu_result(31));
                            -- Carry: Carry out from bit 31
                            ex_wb.flags(0) <= alu_result(32);
                        end if;

                    elsif opcode_high = x"9" then
                        -- SUB/SUBA operation
                        alu_result := unsigned(of_ex.operand2) - unsigned(of_ex.operand1);
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Phase 12: SUBA doesn't affect flags (opmode 011 or 111)
                        if of_ex.opcode(8 downto 6) = "011" or of_ex.opcode(8 downto 6) = "111" then
                            -- SUBA - don't update flags
                            ex_wb.flags <= (others => '0');
                        else
                            -- SUB - update flags (N, Z, V, C) with proper overflow/carry
                            ex_wb.flags(3) <= alu_result(31);  -- Negative
                            if alu_result = 0 then
                                ex_wb.flags(2) <= '1';  -- Zero
                            else
                                ex_wb.flags(2) <= '0';
                            end if;
                            -- Overflow: (Dest[31] != Source[31]) AND (Dest[31] != Result[31])
                            ex_wb.flags(1) <= (of_ex.operand2(31) xor of_ex.operand1(31)) and
                                              (of_ex.operand2(31) xor alu_result(31));
                            -- Carry: Borrow occurred (inverted - set if no borrow)
                            ex_wb.flags(0) <= not alu_result(32);
                        end if;

                    elsif opcode_high = x"3" or opcode_high = x"2" or opcode_high = x"1" then
                        -- MOVE/MOVEA operation - pass through operand1
                        ex_wb.result <= of_ex.operand1;
                        -- Phase 12F: MOVEA doesn't affect flags (opmode 001)
                        if (opcode_high = x"3" or opcode_high = x"2") and of_ex.opcode(8 downto 6) = "001" then
                            -- MOVEA - no flag updates
                            ex_wb.flags <= (others => '0');
                        else
                            -- MOVE - update flags
                            ex_wb.flags(3) <= of_ex.operand1(31);  -- Negative
                            if of_ex.operand1 = x"00000000" then
                                ex_wb.flags(2) <= '1';  -- Zero
                            else
                                ex_wb.flags(2) <= '0';
                            end if;
                            ex_wb.flags(1) <= '0';  -- Overflow cleared
                            ex_wb.flags(0) <= '0';  -- Carry cleared
                        end if;

                    -- Phase 12: MOVEQ instruction (MVIS)
                    elsif opcode_high = x"7" and of_ex.opcode(8) = '0' then
                        -- MOVEQ #<data>,Dn
                        -- Move immediate (already sign-extended) to data register
                        ex_wb.result <= of_ex.operand1;
                        -- Set flags according to MC68040 spec:
                        -- N = MSB of result, Z = result is zero, V = 0, C = 0, X unchanged
                        ex_wb.flags(3) <= of_ex.operand1(31);  -- Negative
                        if of_ex.operand1 = x"00000000" then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12: CMP instruction (MVIS)
                    elsif opcode_high = x"B" and of_ex.opcode(8 downto 6) = "000" then
                        -- CMP Dn,Dn - Compare (Dest - Source)
                        -- Result not stored, only flags updated
                        alu_result := unsigned(of_ex.operand2) - unsigned(of_ex.operand1);
                        ex_wb.result <= (others => '0');  -- No result stored
                        -- Set flags: N, Z, V, C according to subtraction with proper overflow/carry
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        -- Overflow: (Dest[31] != Source[31]) AND (Dest[31] != Result[31])
                        ex_wb.flags(1) <= (of_ex.operand2(31) xor of_ex.operand1(31)) and
                                          (of_ex.operand2(31) xor alu_result(31));
                        -- Carry: Borrow occurred (inverted)
                        ex_wb.flags(0) <= not alu_result(32);

                    -- Phase 12A: CMPA instruction (Compare Address)
                    elsif opcode_high = x"B" and (of_ex.opcode(8 downto 6) = "011" or of_ex.opcode(8 downto 6) = "111") then
                        -- CMPA Dn,An - Compare Address (An - Dn)
                        -- Result not stored, only flags updated
                        alu_result := unsigned(of_ex.operand2) - unsigned(of_ex.operand1);
                        ex_wb.result <= (others => '0');  -- No result stored
                        -- Set flags: N, Z, V, C according to subtraction with proper overflow/carry
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        -- Overflow: (Dest[31] != Source[31]) AND (Dest[31] != Result[31])
                        ex_wb.flags(1) <= (of_ex.operand2(31) xor of_ex.operand1(31)) and
                                          (of_ex.operand2(31) xor alu_result(31));
                        -- Carry: Borrow occurred (inverted)
                        ex_wb.flags(0) <= not alu_result(32);

                    -- Phase 12: CMPI instruction (Phase 12A)
                    elsif opcode_high = x"0" and of_ex.opcode(15 downto 8) = x"0C" then
                        -- CMPI #<data>,Dn - Compare immediate with register
                        -- Result not stored, only flags updated
                        alu_result := unsigned(of_ex.operand2) - unsigned(of_ex.operand1);
                        ex_wb.result <= (others => '0');  -- No result stored
                        -- Set flags: N, Z, V, C according to subtraction with proper overflow/carry
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        -- Overflow: (Dest[31] != Source[31]) AND (Dest[31] != Result[31])
                        ex_wb.flags(1) <= (of_ex.operand2(31) xor of_ex.operand1(31)) and
                                          (of_ex.operand2(31) xor alu_result(31));
                        -- Carry: Borrow occurred (inverted)
                        ex_wb.flags(0) <= not alu_result(32);

                    -- Phase 12: TST instruction (MVIS)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"4A" then
                        -- TST - Test operand against zero
                        -- Result not stored, only flags updated
                        ex_wb.result <= (others => '0');  -- No result stored
                        -- Set flags: N, Z according to operand, V=0, C=0
                        ex_wb.flags(3) <= of_ex.operand1(31);  -- Negative
                        if of_ex.operand1 = x"00000000" then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12: AND instruction (Phase 12A)
                    elsif opcode_high = x"C" and of_ex.opcode(8) = '0' then
                        -- AND Dn,Dn - Logical AND
                        alu_result := unsigned(of_ex.operand1) and unsigned(of_ex.operand2);
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Set flags: N, Z according to result, V=0, C=0
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12: OR instruction (Phase 12A)
                    elsif opcode_high = x"8" and of_ex.opcode(8) = '0' then
                        -- OR Dn,Dn - Logical OR
                        alu_result := unsigned(of_ex.operand1) or unsigned(of_ex.operand2);
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Set flags: N, Z according to result, V=0, C=0
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12: EOR instruction (Phase 12A)
                    elsif opcode_high = x"B" and of_ex.opcode(8) = '1' then
                        -- EOR Dn,Dn - Exclusive OR
                        alu_result := unsigned(of_ex.operand1) xor unsigned(of_ex.operand2);
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Set flags: N, Z according to result, V=0, C=0
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12: NOT instruction (Phase 12A)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"46" then
                        -- NOT - Logical complement
                        alu_result := not unsigned(of_ex.operand1);
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Set flags: N, Z according to result, V=0, C=0
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12A: NEGX instruction (Negate with Extend)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"40" then
                        -- NEGX - Negate with Extend (0 - operand - X)
                        -- X bit is bit 4 of CCR (simplified - using bit 0 as placeholder)
                        if of_ex.ccr(0) = '1' then
                            alu_result := unsigned(not of_ex.operand1) + 1 - 1;  -- Include X bit
                        else
                            alu_result := unsigned(not of_ex.operand1) + 1;  -- No X bit
                        end if;
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Set flags: N, Z, V, C, X according to result
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        -- Overflow: Set when result would be outside signed 32-bit range
                        -- NEGX = 0 - operand - X, overflow when:
                        -- - operand = 0x80000000 and X = 0 (trying to produce +2^31)
                        -- - operand = 0x7FFFFFFF and X = 1 (trying to produce +2^31)
                        if (of_ex.operand1 = x"80000000" and of_ex.ccr(0) = '0') or
                           (of_ex.operand1 = x"7FFFFFFF" and of_ex.ccr(0) = '1') then
                            ex_wb.flags(1) <= '1';  -- Overflow set
                        else
                            ex_wb.flags(1) <= '0';  -- Overflow cleared
                        end if;
                        if alu_result = 0 then
                            ex_wb.flags(0) <= '0';  -- Carry and X cleared if result is zero
                        else
                            ex_wb.flags(0) <= '1';  -- Carry and X set if result is non-zero
                        end if;

                    -- Phase 12: NEG instruction (Phase 12A)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"44" then
                        -- NEG - Negate (0 - operand)
                        alu_result := unsigned(not of_ex.operand1) + 1;  -- Two's complement
                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Set flags: N, Z, V, C according to result
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        -- Overflow: Set when negating 0x80000000 (most negative value)
                        -- Because -(-2147483648) = +2147483648 which doesn't fit in signed 32-bit
                        if of_ex.operand1 = x"80000000" then
                            ex_wb.flags(1) <= '1';  -- Overflow set
                        else
                            ex_wb.flags(1) <= '0';  -- Overflow cleared
                        end if;
                        if alu_result = 0 then
                            ex_wb.flags(0) <= '0';  -- Carry cleared if result is zero
                        else
                            ex_wb.flags(0) <= '1';  -- Carry set if result is non-zero
                        end if;

                    -- Phase 12: CLR instruction (Phase 12A)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"42" then
                        -- CLR - Clear (0 → destination)
                        ex_wb.result <= (others => '0');
                        -- Set flags: N=0, Z=1, V=0, C=0
                        ex_wb.flags(3) <= '0';  -- Negative cleared
                        ex_wb.flags(2) <= '1';  -- Zero set
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12F: SWAP instruction
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"48" and of_ex.opcode(7 downto 3) = "01000" then
                        -- SWAP - Swap upper and lower words
                        ex_wb.result <= of_ex.operand1(15 downto 0) & of_ex.operand1(31 downto 16);
                        -- Set flags: N, Z based on result; V, C cleared
                        ex_wb.flags(3) <= of_ex.operand1(15);  -- Negative (new MSB is old bit 15)
                        if of_ex.operand1(15 downto 0) & of_ex.operand1(31 downto 16) = x"00000000" then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12F: EXT.W instruction (byte → word)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"48" and of_ex.opcode(7 downto 3) = "10000" then
                        -- EXT.W - Sign-extend byte to word (bit 7 → bits 8-15)
                        if of_ex.operand1(7) = '1' then
                            ex_wb.result <= of_ex.operand1(31 downto 16) & x"FF" & of_ex.operand1(7 downto 0);
                        else
                            ex_wb.result <= of_ex.operand1(31 downto 16) & x"00" & of_ex.operand1(7 downto 0);
                        end if;
                        -- Set flags: N, Z based on result; V, C cleared
                        ex_wb.flags(3) <= of_ex.operand1(7);  -- Negative
                        if of_ex.operand1(7 downto 0) = x"00" or (of_ex.operand1(7) = '1' and of_ex.operand1(7 downto 0) = x"80") then
                            ex_wb.flags(2) <= '1';  -- Zero if byte is 0
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12F: EXT.L instruction (word → long)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"48" and of_ex.opcode(7 downto 3) = "11000" then
                        -- EXT.L - Sign-extend word to long (bit 15 → bits 16-31)
                        if of_ex.operand1(15) = '1' then
                            ex_wb.result <= x"FFFF" & of_ex.operand1(15 downto 0);
                        else
                            ex_wb.result <= x"0000" & of_ex.operand1(15 downto 0);
                        end if;
                        -- Set flags: N, Z based on result; V, C cleared
                        ex_wb.flags(3) <= of_ex.operand1(15);  -- Negative
                        if of_ex.operand1(15 downto 0) = x"0000" then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12F: EXTB.L instruction (byte → long)
                    elsif opcode_high = x"4" and of_ex.opcode(15 downto 8) = x"49" and of_ex.opcode(7 downto 3) = "11000" then
                        -- EXTB.L - Sign-extend byte to long (bit 7 → bits 8-31)
                        if of_ex.operand1(7) = '1' then
                            ex_wb.result <= x"FFFFFF" & of_ex.operand1(7 downto 0);
                        else
                            ex_wb.result <= x"000000" & of_ex.operand1(7 downto 0);
                        end if;
                        -- Set flags: N, Z based on result; V, C cleared
                        ex_wb.flags(3) <= of_ex.operand1(7);  -- Negative
                        if of_ex.operand1(7 downto 0) = x"00" then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared
                        ex_wb.flags(0) <= '0';  -- Carry cleared

                    -- Phase 12B: Shift and Rotate instructions
                    elsif opcode_high = x"E" then
                        -- Get shift count (modulo 64 for register, 1-8 for immediate)
                        variable shift_count : integer range 0 to 63;
                        variable operation : std_logic_vector(2 downto 0);  -- bits 4:3 define operation
                        variable direction : std_logic;  -- bit 8: 0=right, 1=left

                        shift_count := to_integer(unsigned(of_ex.operand2(5 downto 0)));  -- Use lower 6 bits
                        operation := of_ex.opcode(4 downto 3);  -- 00=AS, 01=LS, 10=ROXS, 11=ROS
                        direction := of_ex.opcode(8);  -- 0=right, 1=left

                        -- Perform shift/rotate based on operation and direction
                        if operation = "00" then
                            -- Arithmetic Shift (AS)
                            if direction = '1' then
                                -- ASL: Arithmetic Shift Left
                                if shift_count = 0 then
                                    alu_result := unsigned(of_ex.operand1);
                                    ex_wb.flags(0) <= '0';  -- Carry cleared for 0 shift
                                elsif shift_count < 32 then
                                    alu_result := shift_left(unsigned(of_ex.operand1), shift_count);
                                    ex_wb.flags(0) <= of_ex.operand1(32 - shift_count);  -- Last bit shifted out
                                else
                                    alu_result := (others => '0');
                                    ex_wb.flags(0) <= '0';
                                end if;
                            else
                                -- ASR: Arithmetic Shift Right (preserves sign)
                                if shift_count = 0 then
                                    alu_result := unsigned(of_ex.operand1);
                                    ex_wb.flags(0) <= '0';  -- Carry cleared for 0 shift
                                elsif shift_count < 32 then
                                    alu_result := unsigned(shift_right(signed(of_ex.operand1), shift_count));
                                    ex_wb.flags(0) <= of_ex.operand1(shift_count - 1);  -- Last bit shifted out
                                else
                                    -- Shift by 32+ fills with sign bit
                                    if of_ex.operand1(31) = '1' then
                                        alu_result := (others => '1');
                                    else
                                        alu_result := (others => '0');
                                    end if;
                                    ex_wb.flags(0) <= of_ex.operand1(31);
                                end if;
                            end if;
                        elsif operation = "01" then
                            -- Logical Shift (LS)
                            if direction = '1' then
                                -- LSL: Logical Shift Left
                                if shift_count = 0 then
                                    alu_result := unsigned(of_ex.operand1);
                                    ex_wb.flags(0) <= '0';
                                elsif shift_count < 32 then
                                    alu_result := shift_left(unsigned(of_ex.operand1), shift_count);
                                    ex_wb.flags(0) <= of_ex.operand1(32 - shift_count);
                                else
                                    alu_result := (others => '0');
                                    ex_wb.flags(0) <= '0';
                                end if;
                            else
                                -- LSR: Logical Shift Right
                                if shift_count = 0 then
                                    alu_result := unsigned(of_ex.operand1);
                                    ex_wb.flags(0) <= '0';
                                elsif shift_count < 32 then
                                    alu_result := shift_right(unsigned(of_ex.operand1), shift_count);
                                    ex_wb.flags(0) <= of_ex.operand1(shift_count - 1);
                                else
                                    alu_result := (others => '0');
                                    ex_wb.flags(0) <= '0';
                                end if;
                            end if;
                        elsif operation = "11" then
                            -- Rotate (RO)
                            if direction = '1' then
                                -- ROL: Rotate Left
                                if shift_count = 0 then
                                    alu_result := unsigned(of_ex.operand1);
                                    ex_wb.flags(0) <= '0';
                                else
                                    alu_result := rotate_left(unsigned(of_ex.operand1), shift_count mod 32);
                                    ex_wb.flags(0) <= alu_result(0);  -- Bit rotated to LSB
                                end if;
                            else
                                -- ROR: Rotate Right
                                if shift_count = 0 then
                                    alu_result := unsigned(of_ex.operand1);
                                    ex_wb.flags(0) <= '0';
                                else
                                    alu_result := rotate_right(unsigned(of_ex.operand1), shift_count mod 32);
                                    ex_wb.flags(0) <= alu_result(31);  -- Bit rotated to MSB
                                end if;
                            end if;
                        else
                            -- ROXL/ROXR: Rotate through Extend (33-bit rotate through X)
                            -- X bit is CCR bit 4 (using bit 0 as simplified representation)
                            variable x_bit : std_logic;
                            variable temp_val : unsigned(32 downto 0);  -- 33-bit value
                            variable actual_count : integer range 0 to 63;

                            x_bit := of_ex.ccr(0);  -- Current X bit
                            actual_count := shift_count mod 33;  -- 33-bit rotation period

                            if direction = '1' then
                                -- ROXL: Rotate left through X
                                -- Form 33-bit value: {operand[31:0], X}
                                temp_val := unsigned(of_ex.operand1) & x_bit;
                                -- Rotate left by actual_count
                                temp_val := rotate_left(temp_val, actual_count);
                                -- Extract result and new X/C
                                alu_result := temp_val(32 downto 1);
                                ex_wb.flags(0) <= temp_val(0);  -- X bit (also C)
                            else
                                -- ROXR: Rotate right through X
                                -- Form 33-bit value: {X, operand[31:0]}
                                temp_val := x_bit & unsigned(of_ex.operand1);
                                -- Rotate right by actual_count
                                temp_val := rotate_right(temp_val, actual_count);
                                -- Extract result and new X/C
                                alu_result := temp_val(31 downto 0);
                                ex_wb.flags(0) <= temp_val(32);  -- X bit (also C)
                            end if;
                        end if;

                        ex_wb.result <= std_logic_vector(alu_result);
                        -- Set flags: N, Z, V=0, C (already set above)
                        ex_wb.flags(3) <= alu_result(31);  -- Negative
                        if alu_result = 0 then
                            ex_wb.flags(2) <= '1';  -- Zero
                        else
                            ex_wb.flags(2) <= '0';
                        end if;
                        ex_wb.flags(1) <= '0';  -- Overflow cleared

                    -- Phase 12G: Bit manipulation instructions
                    elsif opcode_high = x"0" and of_ex.opcode(5 downto 3) = "000" then
                        -- BTST, BCHG, BCLR, BSET
                        -- Bit number is in operand1 (modulo 32 for data registers)
                        variable bit_num : integer range 0 to 31;
                        variable bit_mask : unsigned(31 downto 0);
                        variable operation : std_logic_vector(2 downto 0);

                        bit_num := to_integer(unsigned(of_ex.operand1(4 downto 0)));  -- Mod 32
                        bit_mask := shift_left(to_unsigned(1, 32), bit_num);
                        operation := of_ex.opcode(8 downto 6);  -- 100=BTST, 101=BCHG, 110=BCLR, 111=BSET

                        -- Test bit and set Z flag (Z=1 if bit was 0, Z=0 if bit was 1)
                        if (unsigned(of_ex.operand2) and bit_mask) = 0 then
                            ex_wb.flags(2) <= '1';  -- Z=1: bit was 0
                        else
                            ex_wb.flags(2) <= '0';  -- Z=0: bit was 1
                        end if;
                        ex_wb.flags(3) <= '0';  -- N cleared
                        ex_wb.flags(1) <= '0';  -- V cleared
                        ex_wb.flags(0) <= '0';  -- C cleared

                        if operation = "100" then
                            -- BTST: Test only, no modification
                            ex_wb.result <= of_ex.operand2;
                        elsif operation = "101" then
                            -- BCHG: Change bit (toggle)
                            ex_wb.result <= std_logic_vector(unsigned(of_ex.operand2) xor bit_mask);
                        elsif operation = "110" then
                            -- BCLR: Clear bit
                            ex_wb.result <= std_logic_vector(unsigned(of_ex.operand2) and not bit_mask);
                        else  -- operation = "111"
                            -- BSET: Set bit
                            ex_wb.result <= std_logic_vector(unsigned(of_ex.operand2) or bit_mask);
                        end if;

                    -- Phase 12D: DBcc instruction (Decrement and Branch conditionally)
                    elsif opcode_high = x"5" and of_ex.opcode(7 downto 3) = "11001" then
                        -- DBcc Dn,<displacement>
                        variable condition : branch_condition_t;
                        variable condition_result : std_logic;
                        variable counter : unsigned(15 downto 0);

                        -- Decode condition from opcode bits [11:8]
                        condition := decode_branch_condition(of_ex.opcode);
                        condition_result := evaluate_branch_condition(condition, of_ex.ccr);

                        if condition_result = '1' then
                            -- Condition TRUE: no operation, continue to next instruction
                            ex_wb.result <= of_ex.operand1;  -- Keep register unchanged
                            ex_wb.flags <= (others => '0');  -- No flag updates
                        else
                            -- Condition FALSE: decrement lower 16 bits
                            counter := unsigned(of_ex.operand1(15 downto 0)) - 1;
                            -- Result: upper 16 bits unchanged, lower 16 bits decremented
                            ex_wb.result <= of_ex.operand1(31 downto 16) & std_logic_vector(counter);
                            ex_wb.flags <= (others => '0');  -- No flag updates

                            -- TODO: Branch logic needs to be implemented
                            -- If counter ≠ 0xFFFF after decrement, should branch to PC + displacement
                            -- This requires integration with the Branch Unit (Phase 8)
                            -- For now, we just do the decrement part
                        end if;

                    -- Phase 12D: Scc instruction (Set According to Condition)
                    elsif opcode_high = x"5" and of_ex.opcode(7 downto 6) = "11" and of_ex.opcode(5 downto 3) /= "001" then
                        -- Scc <ea>
                        variable condition : branch_condition_t;
                        variable condition_result : std_logic;

                        -- Decode condition from opcode bits [11:8]
                        condition := decode_branch_condition(of_ex.opcode);
                        condition_result := evaluate_branch_condition(condition, of_ex.ccr);

                        if condition_result = '1' then
                            -- Condition TRUE: Set destination byte to 0xFF
                            -- Upper 3 bytes unchanged
                            ex_wb.result <= of_ex.operand1(31 downto 8) & x"FF";
                        else
                            -- Condition FALSE: Set destination byte to 0x00
                            -- Upper 3 bytes unchanged
                            ex_wb.result <= of_ex.operand1(31 downto 8) & x"00";
                        end if;
                        ex_wb.flags <= (others => '0');  -- No flag updates

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

                -- Phase 11: Flush on exception entry
                -- When exception unit signals flush, flush entire pipeline
                if exc_unit_flush = '1' then
                    ctrl.flush_if <= '1';
                    ctrl.flush_id <= '1';
                    ctrl.flush_ea <= '1';
                    ctrl.flush_of <= '1';
                    ctrl.flush_ex <= '1';
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
    -- Memory Interface (Stub for Phase 3 + Exception Unit Phase 11)
    ------------------------------------------------------------------------------
    mem_addr <= ea_of.ea_addr;
    mem_read <= '0';  -- Will be set when implementing memory operations
    mem_write <= '0';
    mem_data_write <= (others => '0');

    -- Connect exception unit memory data input to memory read data
    exc_unit_mem_data_in <= mem_data_read;

    ------------------------------------------------------------------------------
    -- Register File Interface (Stub for Phase 3)
    ------------------------------------------------------------------------------
    reg_addr_a <= id_ea.src_reg1;
    reg_addr_b <= id_ea.src_reg2;

end rtl;
