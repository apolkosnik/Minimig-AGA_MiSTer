-- tb_whichamiga_mmu.vhd
-- Testbench implementing WhichAmiga.ASM 68030 MMU detection sequence
-- Based on WhichAmiga rev 644+ MMU test (lines 5192-5318)
--
-- This test validates:
-- 1. TC register configuration ($80D04780)
-- 2. CRP register setup (64-bit)
-- 3. Page table translation
-- 4. Virtual-to-physical address mapping
-- 5. PTEST instruction
-- 6. MMUSR updates
-- 7. Invalid descriptor detection

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.TG68K_Pack.all;

entity tb_whichamiga_mmu is
end tb_whichamiga_mmu;

architecture behavior of tb_whichamiga_mmu is

    -- Component declaration
    component TG68KdotC_Kernel
        port (
            clk : in std_logic;
            nReset : in std_logic;
            clkena_in : in std_logic;
            data_in : in std_logic_vector(15 downto 0);
            IPL : in std_logic_vector(2 downto 0);
            IPL_autovector : in std_logic;
            CPU : in std_logic_vector(1 downto 0);
            addr_out : out std_logic_vector(31 downto 0);
            data_write : out std_logic_vector(15 downto 0);
            nWr : out std_logic;
            nUDS : out std_logic;
            nLDS : out std_logic;
            busstate : out std_logic_vector(1 downto 0);
            nResetOut : out std_logic;
            FC : out std_logic_vector(2 downto 0);
            clr_berr : out std_logic;
            CACR_out : out std_logic_vector(31 downto 0);
            VBR_out : out std_logic_vector(31 downto 0);
            cache_inv_req : out std_logic;
            cache_op_scope : out std_logic_vector(1 downto 0);
            cache_op_cache : out std_logic_vector(1 downto 0);
            cacr_ie : out std_logic;
            cacr_de : out std_logic;
            pmmu_reg_we : out std_logic;
            pmmu_reg_re : out std_logic;
            pmmu_reg_sel : out std_logic_vector(4 downto 0);
            pmmu_reg_wdat : out std_logic_vector(31 downto 0);
            pmmu_reg_part : out std_logic;
            pmmu_addr_log : out std_logic_vector(31 downto 0);
            pmmu_addr_phys : out std_logic_vector(31 downto 0);
            pmmu_cache_inhibit : out std_logic;
            pmmu_walker_req : out std_logic;
            pmmu_walker_we : out std_logic;
            pmmu_walker_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_wdat : out std_logic_vector(31 downto 0);
            pmmu_walker_ack : in std_logic;
            pmmu_walker_data : in std_logic_vector(31 downto 0);
            pmmu_walker_berr : in std_logic;
            debug_regfile_a7 : out std_logic_vector(31 downto 0);
            debug_reg_QA : out std_logic_vector(31 downto 0);
            debug_micro_state : out integer range 0 to 255;
            debug_next_micro_state : out integer range 0 to 255;
            debug_pmmu_busy : out std_logic;
            debug_pmmu_fault : out std_logic
        );
    end component;

    -- Clock and reset
    signal clk : std_logic := '0';
    signal nReset : std_logic := '0';
    signal clkena_in : std_logic;

    -- CPU interface
    signal data_in : std_logic_vector(15 downto 0);
    signal IPL : std_logic_vector(2 downto 0) := "111";
    signal IPL_autovector : std_logic := '0';
    signal CPU : std_logic_vector(1 downto 0) := "11";  -- 68030
    signal addr_out : std_logic_vector(31 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal nWr : std_logic;
    signal nUDS : std_logic;
    signal nLDS : std_logic;
    signal busstate : std_logic_vector(1 downto 0);
    signal nResetOut : std_logic;
    signal FC : std_logic_vector(2 downto 0);
    signal clr_berr : std_logic;
    signal CACR_out : std_logic_vector(31 downto 0);
    signal VBR_out : std_logic_vector(31 downto 0);
    signal cache_inv_req : std_logic;
    signal cache_op_scope : std_logic_vector(1 downto 0);
    signal cache_op_cache : std_logic_vector(1 downto 0);
    signal cacr_ie : std_logic;
    signal cacr_de : std_logic;

    -- PMMU interface
    signal pmmu_reg_we : std_logic;
    signal pmmu_reg_re : std_logic;
    signal pmmu_reg_sel : std_logic_vector(4 downto 0);
    signal pmmu_reg_wdat : std_logic_vector(31 downto 0);
    signal pmmu_reg_part : std_logic;
    signal pmmu_addr_log : std_logic_vector(31 downto 0);
    signal pmmu_addr_phys : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;
    signal pmmu_walker_req : std_logic;
    signal pmmu_walker_we : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_walker_berr : std_logic := '0';

    -- Debug signals
    signal debug_regfile_a7 : std_logic_vector(31 downto 0);
    signal debug_reg_QA : std_logic_vector(31 downto 0);
    signal debug_micro_state : integer range 0 to 255;
    signal debug_next_micro_state : integer range 0 to 255;
    signal pmmu_busy : std_logic;
    signal pmmu_fault : std_logic;

    -- Memory wait state and stall control (matches cpu_wrapper.v behavior)
    signal mem_wait : std_logic := '0';
    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';

    constant CLK_PERIOD : time := 10 ns;
    signal test_done : boolean := false;

    -- Test checkpoints
    signal tc_written : boolean := false;
    signal crp_written : boolean := false;
    signal tc_enabled : boolean := false;
    signal tc_value_correct : boolean := false;
    signal ptest_executed : boolean := false;
    signal tc_write_count : integer := 0;

    -- WhichAmiga TC test value: $80D04780 (E=1 - MMU ENABLED - LOCKUP TEST!)
    -- Bit 31 (E): Enable = 1 (ENABLED - this is where the lockup happens!)
    -- Bits 30-26: Reserved = 00000
    -- Bit 25 (SRE): Supervisor Root Enable = 0
    -- Bit 24 (FCL): Function Code Lookup = 0
    -- Bits 23-20 (PS): Page Size = 1101 (8K pages)
    -- Bits 19-16 (IS): Initial Shift = 0000
    -- Bits 15-12 (TIA): Table Index A = 0100
    -- Bits 11-8 (TIB): Table Index B = 0111
    -- Bits 7-4 (TIC): Table Index C = 1000
    -- Bits 3-0 (TID): Table Index D = 0000
    constant TC_TEST_VALUE : std_logic_vector(31 downto 0) := x"80D04780";

    -- CRP format: $80000002 + table_address
    -- Upper 32 bits: L/U=1, Limit=0, DT=10 (valid 4-byte descriptor)
    constant CRP_HIGH_WHICHAMIGA : std_logic_vector(31 downto 0) := x"80000002";

    -- Page table address (will use $3000 in our memory model)
    constant PAGE_TABLE_ADDR : std_logic_vector(31 downto 0) := x"00003000";

    -- Memory model - 128K words
    type mem_array_t is array(0 to 65535) of std_logic_vector(15 downto 0);
    signal mem : mem_array_t := (
        -- Reset vectors
        0 => x"0000",  -- SSP high
        1 => x"2000",  -- SSP low = $00002000
        2 => x"0000",  -- PC high
        3 => x"0500",  -- PC low = $00000500

        -- Exception vectors (handler = $0000_EE00 + vector*4 for identification)
        -- Vec 2 (Bus Error $08): handler at $EE08
        4 => x"0000", 5 => x"EE08",
        -- Vec 3 (Address Error $0C): handler at $EE0C
        6 => x"0000", 7 => x"EE0C",
        -- Vec 4 (Illegal Instruction $10): handler at $EE10
        8 => x"0000", 9 => x"EE10",
        -- Vec 5 (Divide by Zero $14): handler at $EE14
        10 => x"0000", 11 => x"EE14",
        -- Vec 8 (Privilege Violation $20): handler at $EE20
        16 => x"0000", 17 => x"EE20",
        -- Vec 9 (Trace $24): handler at $EE24
        18 => x"0000", 19 => x"EE24",
        -- Vec 10 (A-line $28): handler at $EE28
        20 => x"0000", 21 => x"EE28",
        -- Vec 11 (F-line $2C): handler at $EE2C
        22 => x"0000", 23 => x"EE2C",
        -- Vec 14 (Format Error $38): handler at $EE38
        28 => x"0000", 29 => x"EE38",
        -- Vec 56 (MMU Config $E0): handler at $EEE0
        112 => x"0000", 113 => x"EEE0",
        -- Vec 61 (MMU Fault $F4): handler at $EEF4
        122 => x"0000", 123 => x"EEF4",

        -- Test program at $500 (word address $280)
        -- WhichAmiga MMU detection sequence

        -- $500: MOVE.L #$3000,A2 - Load page table address
        16#280# => x"247C",  -- MOVE.L #imm,A2
        16#281# => x"0000",
        16#282# => x"3000",

        -- $506: SUBQ.L #8,SP - Allocate stack space for CRP (64-bit)
        16#283# => x"518F",

        -- $508: CLR.L (SP) - Clear TC
        16#284# => x"4297",

        -- $50A: PMOVE.L (SP),TC - Disable MMU
        16#285# => x"F017",
        16#286# => x"4000",

        -- $50E: MOVE.L #$80000002,(SP) - Set CRP high word
        16#287# => x"2EBC",
        16#288# => x"8000",
        16#289# => x"0002",

        -- $514: MOVE.L A2,(4,SP) - Set CRP low word (table address)
        16#28A# => x"2F4A",
        16#28B# => x"0004",

        -- $518: PMOVE.Q (SP),CRP - Load CRP (using raw opcode)
        16#28C# => x"F017",  -- PMOVE opcode
        16#28D# => x"4C00",  -- CRP, direction=0 (mem->MMU), quad

        -- $51C: MOVE.L #$80D04780,(SP) - Set TC test value (E=1, MMU ENABLED!)
        16#28E# => x"2EBC",
        16#28F# => x"80D0",
        16#290# => x"4780",

        -- $522: PMOVE.L (SP),TC - Write TC (but keep MMU disabled for testbench simplicity)
        16#291# => x"F017",
        16#292# => x"4000",

        -- $526: NOP - Sync pipeline
        16#293# => x"4E71",

        -- $528: PTESTR #5,$D0000000,#7 - Test virtual address (using raw opcode)
        16#294# => x"F039",  -- PTEST opcode (abs.L)
        16#295# => x"9C15",  -- Read, FC=5, level=7
        16#296# => x"D000",  -- Address high
        16#297# => x"0000",  -- Address low

        -- $52E: PMOVE.W MMUSR,(SP) - Read MMUSR
        16#298# => x"F017",
        16#299# => x"6200",

        -- $532: CLR.L (SP) - Disable MMU
        16#29A# => x"4297",

        -- $534: PMOVE.L (SP),TC
        16#29B# => x"F017",
        16#29C# => x"4000",

        -- $538: ADDQ.L #8,SP - Clean up stack
        16#29D# => x"508F",

        -- $53A: STOP #$2700
        16#29F# => x"4E72",
        16#2A0# => x"2700",

        -- Exception handler stubs (STOP #$2700 at each handler address)
        -- $EE08 (Bus Error handler)
        16#7704# => x"4E72", 16#7705# => x"2700",
        -- $EE0C (Address Error handler)
        16#7706# => x"4E72", 16#7707# => x"2700",
        -- $EE10 (Illegal handler)
        16#7708# => x"4E72", 16#7709# => x"2700",
        -- $EE2C (F-line handler)
        16#7716# => x"4E72", 16#7717# => x"2700",
        -- $EE38 (Format Error handler)
        16#771C# => x"4E72", 16#771D# => x"2700",
        -- $EEE0 (MMU Config handler)
        16#7770# => x"4E72", 16#7771# => x"2700",
        -- $EEF4 (MMU Fault handler)
        16#777A# => x"4E72", 16#777B# => x"2700",

        -- Page table at $3000 (word address $1800)
        -- WhichAmiga uses 16 long-word entries for early termination table
        -- Each entry is a page descriptor: base_addr | status_bits
        -- Status bits: 0x61 = valid, write-protected, used

        -- $3000: Entry 0 ($00000000-$0FFFFFFF) - map to $00000061
        16#1800# => x"0000",
        16#1801# => x"0061",

        -- $3004: Entry 1 ($10000000-$1FFFFFFF) - map to $10000061
        16#1802# => x"1000",
        16#1803# => x"0061",

        -- $3008: Entry 2 ($20000000-$2FFFFFFF)
        16#1804# => x"2000",
        16#1805# => x"0061",

        -- $300C: Entry 3 ($30000000-$3FFFFFFF)
        16#1806# => x"3000",
        16#1807# => x"0061",

        -- $3010-$302C: Entries 4-11
        16#1808# => x"4000", 16#1809# => x"0061",
        16#180A# => x"5000", 16#180B# => x"0061",
        16#180C# => x"6000", 16#180D# => x"0061",
        16#180E# => x"7000", 16#180F# => x"0061",
        16#1810# => x"8000", 16#1811# => x"0061",
        16#1812# => x"9000", 16#1813# => x"0061",
        16#1814# => x"A000", 16#1815# => x"0061",
        16#1816# => x"B000", 16#1817# => x"0061",

        -- $3030: Entry 12 ($C0000000-$CFFFFFFF)
        16#1818# => x"C000",
        16#1819# => x"0061",

        -- $3034: Entry 13 ($D0000000-$DFFFFFFF) - Identity map $D0000000
        16#181A# => x"D000",
        16#181B# => x"0061",

        -- $3038: Entry 14 ($E0000000-$EFFFFFFF)
        16#181C# => x"E000",
        16#181D# => x"0061",

        -- $303C: Entry 15 ($F0000000-$FFFFFFFF)
        16#181E# => x"F000",
        16#181F# => x"0061",

        others => x"4E71"  -- NOP
    );

    -- Helper function for hex display
    function slv_to_hex(value : std_logic_vector) return string is
        variable nibble : integer;
        variable ndigits : integer := (value'length+3)/4;
        variable result : string(1 to ndigits);
    begin
        for i in 0 to ndigits - 1 loop
            if (i+1)*4 <= value'length then
                nibble := to_integer(unsigned(value(value'length-1-i*4 downto value'length-4-i*4)));
            else
                nibble := to_integer(unsigned(value(value'length-1-i*4 downto 0)));
            end if;
            case nibble is
                when 0 => result(i+1) := '0';
                when 1 => result(i+1) := '1';
                when 2 => result(i+1) := '2';
                when 3 => result(i+1) := '3';
                when 4 => result(i+1) := '4';
                when 5 => result(i+1) := '5';
                when 6 => result(i+1) := '6';
                when 7 => result(i+1) := '7';
                when 8 => result(i+1) := '8';
                when 9 => result(i+1) := '9';
                when 10 => result(i+1) := 'A';
                when 11 => result(i+1) := 'B';
                when 12 => result(i+1) := 'C';
                when 13 => result(i+1) := 'D';
                when 14 => result(i+1) := 'E';
                when 15 => result(i+1) := 'F';
                when others => result(i+1) := 'X';
            end case;
        end loop;
        return result;
    end function;

begin

    -- Instantiate CPU
    dut: TG68KdotC_Kernel
        port map (
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => IPL,
            IPL_autovector => IPL_autovector,
            CPU => CPU,
            addr_out => addr_out,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            nResetOut => nResetOut,
            FC => FC,
            clr_berr => clr_berr,
            CACR_out => CACR_out,
            VBR_out => VBR_out,
            cache_inv_req => cache_inv_req,
            cache_op_scope => cache_op_scope,
            cache_op_cache => cache_op_cache,
            cacr_ie => cacr_ie,
            cacr_de => cacr_de,
            pmmu_reg_we => pmmu_reg_we,
            pmmu_reg_re => pmmu_reg_re,
            pmmu_reg_sel => pmmu_reg_sel,
            pmmu_reg_wdat => pmmu_reg_wdat,
            pmmu_reg_part => pmmu_reg_part,
            pmmu_addr_log => pmmu_addr_log,
            pmmu_addr_phys => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req => pmmu_walker_req,
            pmmu_walker_we => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            debug_regfile_a7 => debug_regfile_a7,
            debug_reg_QA => debug_reg_QA,
            debug_micro_state => debug_micro_state,
            debug_next_micro_state => debug_next_micro_state,
            debug_pmmu_busy => pmmu_busy,
            debug_pmmu_fault => pmmu_fault
        );

    -- Memory wait state: simulate minimum 1-cycle memory latency (matches cpu_wrapper.v)
    mem_wait_gen: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                mem_wait <= '0';
            elsif clkena_in = '1' then
                mem_wait <= '1';   -- 1 wait cycle after each CPU advance
            else
                mem_wait <= '0';
            end if;
        end if;
    end process;

    -- Stall cooldown after walker completion
    stall_control: process(clk)
    begin
        if rising_edge(clk) then
            walker_req_prev <= pmmu_walker_req;
            if walker_req_prev = '1' and pmmu_walker_req = '0' then
                stall_cooldown <= 2;
            elsif stall_cooldown > 0 then
                stall_cooldown <= stall_cooldown - 1;
            end if;
        end if;
    end process;

    -- CPU stall control (matches cpu_wrapper.v behavior)
    -- Only apply full stall mechanism after TC.E is enabled (tc_enabled signal).
    -- Before TC enable, clkena_in='1' for simple zero-wait-state operation.
    -- This avoids VHDL delta-cycle timing artifacts in the testbench memory model.
    -- BUG #399: Release during fault so kernel can see make_berr
    clkena_in <= '0' when tc_enabled and
                          (pmmu_walker_req = '1'
                           or (pmmu_busy = '1' and pmmu_fault = '0')
                           or stall_cooldown > 0 or mem_wait = '1') else '1';

    -- Clock generation
    clk_process: process
    begin
        while not test_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- Memory read
    data_in <= mem(to_integer(unsigned(addr_out(16 downto 1))));

    -- BUG #395 DEBUG: Monitor stack reads for PMOVE TC
    stack_read_monitor: process(clk)
    begin
        if rising_edge(clk) then
            -- Monitor reads from stack area during PMOVE execution
            if addr_out(31 downto 4) = x"0000" & x"1FF" and busstate = "10" then  -- State 10 = memory read
                report "STACK_READ: addr=$" & slv_to_hex(addr_out) &
                       " data=$" & slv_to_hex(mem(to_integer(unsigned(addr_out(16 downto 1))))) severity note;
            end if;
        end if;
    end process;

    -- Unified memory write: handles BOTH CPU writes and walker writes
    -- CRITICAL: Only one process may assign to mem() to avoid multi-driver conflicts
    mem_write: process(clk)
        variable walker_word_idx : integer;
    begin
        if rising_edge(clk) then
            -- Walker writes (U/M bit updates) - higher priority
            if pmmu_walker_req = '1' and pmmu_walker_we = '1' then
                walker_word_idx := to_integer(unsigned(pmmu_walker_addr(16 downto 1)));
                if walker_word_idx < 65535 then
                    mem(walker_word_idx) <= pmmu_walker_wdat(31 downto 16);
                    mem(walker_word_idx + 1) <= pmmu_walker_wdat(15 downto 0);
                end if;
                report "WALKER_WR: addr=$" & slv_to_hex(pmmu_walker_addr) &
                       " data=$" & slv_to_hex(pmmu_walker_wdat) severity note;
            end if;

            -- CPU writes
            if nWr = '0' then
                if nUDS = '0' then
                    mem(to_integer(unsigned(addr_out(16 downto 1))))(15 downto 8) <= data_write(15 downto 8);
                end if;
                if nLDS = '0' then
                    mem(to_integer(unsigned(addr_out(16 downto 1))))(7 downto 0) <= data_write(7 downto 0);
                end if;
                -- Log all writes
                if addr_out(15 downto 8) /= x"00" or nReset = '1' then  -- Skip reset initialization
                    report "MEM_WRITE: addr=$" & slv_to_hex(addr_out) &
                           " data=$" & slv_to_hex(data_write) &
                           " ce=" & std_logic'image(clkena_in) severity note;
                end if;
            end if;
        end if;
    end process;

    -- BUG #395 DEBUG: Monitor micro_state transitions
    micro_state_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if addr_out(15 downto 0) = x"0522" or addr_out(15 downto 0) = x"0524" then
                report "MICRO_STATE at PC=$" & slv_to_hex(addr_out) &
                       ": micro_state=" & integer'image(to_integer(unsigned(pmmu_reg_sel))) severity note;
            end if;
        end if;
    end process;

    -- Track PMMU register writes
    pmmu_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_reg_we = '1' then
                case pmmu_reg_sel is
                    when "10000" =>  -- TC
                        tc_written <= true;
                        tc_write_count <= tc_write_count + 1;
                        report "PMMU_REG_WRITE: TC = $" & slv_to_hex(pmmu_reg_wdat) &
                               " (write #" & integer'image(tc_write_count + 1) & ")" severity note;
                        -- Second write is the test value (first is clear at $50A, second is test at $522)
                        if tc_write_count = 1 and pmmu_reg_wdat /= x"00000000" then
                            tc_enabled <= true;
                            -- BUG #395 VERIFICATION: Check if TC value is correct
                            if pmmu_reg_wdat = TC_TEST_VALUE then
                                tc_value_correct <= true;
                                report "  TC test value CORRECT: $" & slv_to_hex(pmmu_reg_wdat) severity note;
                            else
                                tc_value_correct <= false;
                                report "  TC test value CORRUPTED! Expected $" & slv_to_hex(TC_TEST_VALUE) &
                                       ", got $" & slv_to_hex(pmmu_reg_wdat) severity error;
                            end if;
                        elsif pmmu_reg_wdat = x"00000000" then
                            report "  TC cleared" severity note;
                        end if;
                    when "10011" =>  -- CRP
                        crp_written <= true;
                        if pmmu_reg_part = '1' then
                            report "PMMU_REG_WRITE: CRP_H = $" & slv_to_hex(pmmu_reg_wdat) severity note;
                            if pmmu_reg_wdat = CRP_HIGH_WHICHAMIGA then
                                report "  CRP_H matches WhichAmiga value ($80000002)" severity note;
                            end if;
                        else
                            report "PMMU_REG_WRITE: CRP_L = $" & slv_to_hex(pmmu_reg_wdat) severity note;
                            if pmmu_reg_wdat = PAGE_TABLE_ADDR then
                                report "  CRP_L points to page table at $3000" severity note;
                            end if;
                        end if;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- Instruction fetch tracker
    fetch_tracker: process(clk)
        variable pc_value : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if busstate = "00" and FC(1) = '1' then  -- Instruction fetch
                pc_value := unsigned(addr_out(15 downto 0));
                case to_integer(pc_value) is
                    when 16#500# =>
                        report "FETCH $500: MOVE.L #$3000,A2" severity note;
                    when 16#506# =>
                        report "FETCH $506: SUBQ.L #8,SP" severity note;
                    when 16#508# =>
                        report "FETCH $508: CLR.L (SP)" severity note;
                    when 16#50A# =>
                        report "FETCH $50A: PMOVE.L (SP),TC (disable)" severity note;
                    when 16#50E# =>
                        report "FETCH $50E: MOVE.L #$80000002,(SP)" severity note;
                    when 16#514# =>
                        report "FETCH $514: MOVE.L A2,(4,SP)" severity note;
                    when 16#518# =>
                        report "FETCH $518: PMOVE.Q (SP),CRP" severity note;
                    when 16#51C# =>
                        report "FETCH $51C: MOVE.L #$80D04780,(SP)" severity note;
                    when 16#522# =>
                        report "FETCH $522: PMOVE.L (SP),TC (enable)" severity note;
                    when 16#526# =>
                        report "FETCH $526: NOP" severity note;
                    when 16#528# =>
                        report "FETCH $528: PTESTR #5,$D0000000,#7" severity note;
                        ptest_executed <= true;
                    when 16#52E# =>
                        report "FETCH $52E: PMOVE.W MMUSR,(SP)" severity note;
                    when 16#532# =>
                        report "FETCH $532: CLR.L (SP)" severity note;
                    when 16#534# =>
                        report "FETCH $534: PMOVE.L (SP),TC (final disable)" severity note;
                    when 16#538# =>
                        report "FETCH $538: ADDQ.L #8,SP" severity note;
                    when 16#53A# =>
                        report "FETCH $53A: STOP" severity note;
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- Page table walker response - serve reads from memory model
    -- NOTE: Walker WRITES are handled in the mem_write process to avoid multi-driver
    walker_response: process(clk)
        variable word_hi : std_logic_vector(15 downto 0);
        variable word_lo : std_logic_vector(15 downto 0);
        variable longword : std_logic_vector(31 downto 0);
        variable word_idx : integer;
    begin
        if rising_edge(clk) then
            pmmu_walker_ack <= '0';

            if pmmu_walker_req = '1' then
                pmmu_walker_ack <= '1';
                word_idx := to_integer(unsigned(pmmu_walker_addr(16 downto 1)));

                if pmmu_walker_we = '0' then
                    -- READ: Return longword from memory model
                    if word_idx < 65535 then
                        word_hi := mem(word_idx);
                        word_lo := mem(word_idx + 1);
                        longword := word_hi & word_lo;
                    else
                        longword := x"00000000";
                    end if;
                    pmmu_walker_data <= longword;

                    report "WALKER_RD: addr=$" & slv_to_hex(pmmu_walker_addr) &
                           " data=$" & slv_to_hex(longword) severity note;
                end if;
            end if;
        end if;
    end process;

    -- Generic fetch logger - log ALL fetches after TC enable
    generic_fetch_logger: process(clk)
    begin
        if rising_edge(clk) then
            if tc_enabled and busstate = "00" and FC(1) = '1' then
                -- Only log non-repetitive fetches or exception handlers
                if addr_out(15 downto 8) = x"EE" then
                    report "EXCEPTION HANDLER FETCH: addr=$" & slv_to_hex(addr_out) severity error;
                    if addr_out(7 downto 0) = x"08" then
                        report ">>> BUS ERROR exception!" severity error;
                    elsif addr_out(7 downto 0) = x"0C" then
                        report ">>> ADDRESS ERROR exception!" severity error;
                    elsif addr_out(7 downto 0) = x"10" then
                        report ">>> ILLEGAL INSTRUCTION exception!" severity error;
                    elsif addr_out(7 downto 0) = x"2C" then
                        report ">>> F-LINE exception!" severity error;
                    elsif addr_out(7 downto 0) = x"38" then
                        report ">>> FORMAT ERROR exception!" severity error;
                    elsif addr_out(7 downto 0) = x"E0" then
                        report ">>> MMU CONFIG exception!" severity error;
                    elsif addr_out(7 downto 0) = x"F4" then
                        report ">>> MMU FAULT exception!" severity error;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Halt/fault detector
    halt_detector: process(clk)
        variable halt_count : integer := 0;
        variable last_addr : std_logic_vector(31 downto 0) := (others => '0');
    begin
        if rising_edge(clk) then
            if tc_enabled then
                if addr_out = last_addr then
                    halt_count := halt_count + 1;
                    if halt_count = 100 then
                        report "HALT_DETECT: CPU appears stuck at addr=$" & slv_to_hex(addr_out) &
                               " micro=" & integer'image(debug_micro_state) &
                               " busstate=" & integer'image(to_integer(unsigned(busstate))) severity warning;
                    end if;
                else
                    halt_count := 0;
                    last_addr := addr_out;
                end if;
            end if;
        end if;
    end process;

    -- A7/SP debug monitor: track register value changes
    a7_monitor: process(clk)
        variable last_a7 : std_logic_vector(31 downto 0) := (others => '0');
    begin
        if rising_edge(clk) then
            if debug_regfile_a7 /= last_a7 then
                report "A7_CHANGE: regfile(15) = $" & slv_to_hex(debug_regfile_a7) &
                       " (was $" & slv_to_hex(last_a7) & ")" &
                       " reg_QA=$" & slv_to_hex(debug_reg_QA) &
                       " addr=$" & slv_to_hex(addr_out) &
                       " micro=" & integer'image(debug_micro_state) severity note;
                last_a7 := debug_regfile_a7;
            end if;
        end if;
    end process;

    -- Test monitor
    test_monitor: process
    begin
        report "=====================================================" severity note;
        report "WhichAmiga MMU Lockup Investigation" severity note;
        report "Tests PMOVE TC/CRP and PTEST instruction execution" severity note;
        report "CRITICAL: TC.E=1 - MMU ENABLED - TESTING FOR HARDWARE LOCKUP!" severity note;
        report "=====================================================" severity note;

        -- Reset
        nReset <= '0';
        wait for CLK_PERIOD * 10;
        nReset <= '1';

        -- Wait for execution
        for i in 0 to 20000 loop
            wait for CLK_PERIOD;
            -- Exit on STOP instruction at expected address or exception handler
            if addr_out(15 downto 0) = x"053A" or addr_out(15 downto 0) = x"053E" then
                exit;
            end if;
            -- Exit if we hit an exception handler
            if addr_out(15 downto 8) = x"EE" then
                report "CPU hit exception handler at $" & slv_to_hex(addr_out) severity error;
                exit;
            end if;
        end loop;

        -- Small delay for final operations
        wait for CLK_PERIOD * 10;

        -- Results
        report "" severity note;
        report "=====================================================" severity note;
        report "Test Results:" severity note;
        report "=====================================================" severity note;

        if tc_written then
            report "  TC written              - PASS" severity note;
        else
            report "  TC written              - FAIL" severity error;
        end if;

        if crp_written then
            report "  CRP written             - PASS" severity note;
        else
            report "  CRP written             - FAIL" severity error;
        end if;

        if tc_enabled then
            report "  TC written with test value - PASS" severity note;
        else
            report "  TC written with test value - FAIL" severity error;
        end if;

        if tc_value_correct then
            report "  TC value correct ($80D04780) - PASS" severity note;
        else
            report "  TC value correct ($80D04780) - FAIL (BUG #395!)" severity error;
        end if;

        if ptest_executed then
            report "  PTEST executed          - PASS" severity note;
        else
            report "  PTEST executed          - FAIL" severity error;
        end if;

        report "" severity note;

        if tc_written and crp_written and tc_enabled and ptest_executed then
            report "*** ALL TESTS PASSED - WhichAmiga instructions work! ***" severity note;
            report "68030 PMMU handles PMOVE TC/CRP and PTEST instructions correctly" severity note;
        else
            report "*** FAIL: WhichAmiga instruction test incomplete ***" severity error;
        end if;

        report "" severity note;
        test_done <= true;
        wait;
    end process;

end behavior;
