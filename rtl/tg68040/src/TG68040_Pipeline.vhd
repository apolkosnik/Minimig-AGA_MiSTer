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
            ex_wb_valid    : in std_logic;
            ex_wb_dst_reg  : in std_logic_vector(3 downto 0);
            ex_wb_write    : in std_logic;
            hazard_info    : out hazard_info_t;
            stall_pipeline : out std_logic
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

    -- Next PC calculation
    pc_next <= pc + 2 when global_stall = '0' else pc;

    ------------------------------------------------------------------------------
    -- Hazard Detection Unit (Phase 4)
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
            ex_wb_valid    => ex_wb.valid,
            ex_wb_dst_reg  => ex_wb.dst_reg,
            ex_wb_write    => ex_wb.write_reg,
            hazard_info    => hazard_info,
            stall_pipeline => hazard_stall
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
    -- IF Stage: Instruction Fetch (with I-Cache, Phase 5)
    ------------------------------------------------------------------------------
    -- Cache fetch request (combinational)
    icache_fetch_req <= '1' when (enable = '1' and ctrl.stall_if = '0' and ctrl.flush_if = '0') else '0';
    icache_fetch_addr <= std_logic_vector(pc);

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

                    of_ex.write_mem <= '0';

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
    -- Pipeline Control Logic
    ------------------------------------------------------------------------------
    control_logic: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ctrl <= PIPELINE_CTRL_INIT;

            elsif enable = '1' then
                -- Default: no stalls or flushes
                ctrl <= PIPELINE_CTRL_INIT;

                -- Stall logic (Phase 3 - very simple)
                -- Stall if memory not ready
                if mem_ready = '0' then
                    ctrl.stall_if <= '1';
                    ctrl.stall_id <= '1';
                    ctrl.stall_ea <= '1';
                    ctrl.stall_of <= '1';
                    ctrl.stall_ex <= '1';
                end if;

                -- Flush logic will be added when branches are implemented
                -- For Phase 3, no automatic flushing
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
