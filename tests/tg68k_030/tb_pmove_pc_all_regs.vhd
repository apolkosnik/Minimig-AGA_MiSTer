-- tb_pmove_pc_all_regs.vhd
-- Comprehensive PMOVE PC increment test for all 68030 PMMU registers
-- Tests: TC, TT0, TT1, CRP, SRP, MMUSR
-- Directions: MMU->memory, memory->MMU
-- Addressing modes: (An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L
-- Uses actual instruction decode and execution through TG68KdotC_Kernel
-- CPU="10" (68020 mode with PMMU enabled)

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use ieee.numeric_std.all;use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_pmove_pc_all_regs is
end tb_pmove_pc_all_regs;

architecture behavioral of tb_pmove_pc_all_regs is

    

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length/4 - 1) loop
            nibble := value(value'length - 1 - i*4 downto value'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

-- Clock and reset
    signal clk          : std_logic := '0';
    signal nReset       : std_logic := '0';  -- Active low reset
    signal clkena_in    : std_logic := '1';

    -- CPU interface signals
    signal data_in      : std_logic_vector(15 downto 0) := (others => '0');
    signal data_out     : std_logic_vector(15 downto 0);
    signal addr         : std_logic_vector(31 downto 0);
    signal nWr          : std_logic;
    signal nUDS         : std_logic;
    signal nLDS         : std_logic;
    signal fc           : std_logic_vector(2 downto 0);
    signal ipl          : std_logic_vector(2 downto 0) := "111";
    signal busstate     : std_logic_vector(1 downto 0);
    signal longword     : std_logic;

    -- PMMU signals
    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    -- Memory - 64K words (128KB)
    type mem_array is array(0 to 65535) of std_logic_vector(15 downto 0);
    shared variable memory : mem_array := (others => x"4E71");  -- Fill with NOPs

    -- Test control
    signal test_phase   : integer := 0;
    signal cycle_count  : integer := 0;
    signal test_done    : std_logic := '0';

    -- PC tracking
    signal last_pc      : std_logic_vector(31 downto 0) := (others => '0');

    -- Debug signals for tracing test 12
    signal dbg_state       : std_logic_vector(1 downto 0);
    signal dbg_opcode      : std_logic_vector(15 downto 0);
    signal dbg_last_opc    : std_logic_vector(15 downto 0);
    signal dbg_TG68_PC     : std_logic_vector(31 downto 0);
    signal dbg_pmmu_brief  : std_logic_vector(15 downto 0);
    signal dbg_clkena_lw   : std_logic;
    signal dbg_setopcode   : std_logic;
    signal dbg_trace_active : boolean := false;
    signal dbg_micro_state : integer range 0 to 255;
    signal dbg_next_micro_state : integer range 0 to 255;
    signal dbg_memmask     : std_logic_vector(5 downto 0);
    signal dbg_setstate    : std_logic_vector(1 downto 0);
    signal dbg_memaddr_reg : std_logic_vector(31 downto 0);
    signal dbg_memaddr_delta : std_logic_vector(31 downto 0);
    signal dbg_fline_ctx_valid : std_logic;
    signal dbg_data_read : std_logic_vector(31 downto 0);
    signal pc_captured  : std_logic := '0';
    signal instruction_start_pc : std_logic_vector(31 downto 0) := (others => '0');
    signal expected_next_pc : std_logic_vector(31 downto 0) := (others => '0');

    -- Test results
    signal tests_passed : integer := 0;
    signal tests_failed : integer := 0;
    signal current_test : integer := 0;

    -- Constants for register encodings (bits 14:10 of extension word)
    constant REG_TT0   : std_logic_vector(4 downto 0) := "00010";  -- 0x02
    constant REG_TT1   : std_logic_vector(4 downto 0) := "00011";  -- 0x03
    constant REG_TC    : std_logic_vector(4 downto 0) := "10000";  -- 0x10
    constant REG_SRP   : std_logic_vector(4 downto 0) := "10010";  -- 0x12
    constant REG_CRP   : std_logic_vector(4 downto 0) := "10011";  -- 0x13
    constant REG_MMUSR : std_logic_vector(4 downto 0) := "11000";  -- 0x18

    -- Direction bit (bit 9 of extension word)
    constant DIR_MEM_TO_MMU : std_logic := '0';
    constant DIR_MMU_TO_MEM : std_logic := '1';

    -- Test tracking structure
    type test_record is record
        start_pc    : integer;
        instr_size  : integer;  -- Expected instruction size in bytes
        reg_name    : string(1 to 5);
        direction   : string(1 to 7);
        ea_mode     : string(1 to 10);
    end record;

    type test_array is array(0 to 127) of test_record;
    signal test_info : test_array;
    signal num_tests : integer := 0;

    -- Helper function to convert to hex string
    function to_hex_string(val : std_logic_vector) return string is
        variable v : std_logic_vector(val'length-1 downto 0) := val;
        variable result : string(1 to val'length/4);
        variable nibble : std_logic_vector(3 downto 0);
        variable hex_char : character;
    begin
        for i in result'range loop
            nibble := v((v'length - (i-1)*4 - 1) downto (v'length - i*4));
            case to_integer(unsigned(nibble)) is
                when 0 => hex_char := '0';
                when 1 => hex_char := '1';
                when 2 => hex_char := '2';
                when 3 => hex_char := '3';
                when 4 => hex_char := '4';
                when 5 => hex_char := '5';
                when 6 => hex_char := '6';
                when 7 => hex_char := '7';
                when 8 => hex_char := '8';
                when 9 => hex_char := '9';
                when 10 => hex_char := 'A';
                when 11 => hex_char := 'B';
                when 12 => hex_char := 'C';
                when 13 => hex_char := 'D';
                when 14 => hex_char := 'E';
                when 15 => hex_char := 'F';
                when others => hex_char := 'X';
            end case;
            result(i) := hex_char;
        end loop;
        return result;
    end function;

    -- Procedure to emit a word to memory
    procedure emit_word(variable pc : inout integer; word : std_logic_vector(15 downto 0)) is
    begin
        memory(pc/2) := word;
        pc := pc + 2;
    end procedure;

    -- Procedure to emit PMOVE instruction
    -- Returns instruction size in bytes
    procedure emit_pmove(
        variable pc : inout integer;
        reg_sel : std_logic_vector(4 downto 0);
        direction : std_logic;  -- 0=mem->MMU, 1=MMU->mem
        ea_mode : std_logic_vector(2 downto 0);
        ea_reg : std_logic_vector(2 downto 0);
        disp_or_addr : std_logic_vector(15 downto 0);
        addr_hi : std_logic_vector(15 downto 0);  -- For (xxx).L mode
        variable instr_size : out integer
    ) is
        variable opcode : std_logic_vector(15 downto 0);
        variable extension : std_logic_vector(15 downto 0);
    begin
        -- Build opcode: F000 + EA
        opcode := "1111000000" & ea_mode & ea_reg;

        -- Build extension word: reg_sel(4:0) & direction & "000000000"
        -- Actually format is: 000 & reg_sel(4:0) & direction & 0000000
        -- Wait, let me check the actual format...
        -- Extension: bits 15:13 = 000, bits 12:10 = reg_sel(4:2), bits 9 = direction
        -- Actually looking at the kernel: brief(14:10) for register, brief(9) for direction
        -- Extension format: 0 & reg_sel(4:0) & direction & "000000000"
        extension := "0" & reg_sel & direction & "000000000";

        emit_word(pc, opcode);
        emit_word(pc, extension);
        instr_size := 4;

        -- Add displacement/address words based on EA mode
        case ea_mode is
            when "000" =>  -- Invalid for MC68030 PMOVE - no extra words
                null;
            when "010" =>  -- (An) - no extra words
                null;
            when "011" =>  -- Invalid for MC68030 PMOVE - no extra words
                null;
            when "100" =>  -- Invalid for MC68030 PMOVE - no extra words
                null;
            when "101" =>  -- (d16,An) - 1 displacement word
                emit_word(pc, disp_or_addr);
                instr_size := 6;
            when "110" =>  -- (d8,An,Xn) - 1 brief extension word
                emit_word(pc, disp_or_addr);  -- Brief extension
                instr_size := 6;
            when "111" =>
                case ea_reg is
                    when "000" =>  -- (xxx).W - 1 address word
                        emit_word(pc, disp_or_addr);
                        instr_size := 6;
                    when "001" =>  -- (xxx).L - 2 address words
                        emit_word(pc, addr_hi);
                        emit_word(pc, disp_or_addr);
                        instr_size := 8;
                    when others =>
                        null;
                end case;
            when others =>
                null;
        end case;
    end procedure;

begin

    -- Instantiate the CPU
    UUT: entity work.TG68KdotC_Kernel
        port map (
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => ipl,
            IPL_autovector => '0',
            berr => '0',
            CPU => "10",  -- 68020 mode with PMMU enabled
            addr_out => addr,
            data_write => data_out,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            longword => longword,
            nResetOut => open,
            FC => fc,
            clr_berr => open,
            skipFetch => open,
            regin_out => open,
            CACR_out => open,
            VBR_out => open,
            cache_inv_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cacr_ie => open,
            cacr_de => open,
            cacr_ifreeze => open,
            cacr_dfreeze => open,
            cacr_ibe => open,
            cacr_dbe => open,
            cacr_wa => open,
            pmmu_reg_we => open,
            pmmu_reg_re => open,
            pmmu_reg_sel => open,
            pmmu_reg_wdat => open,
            pmmu_reg_part => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            cache_op_addr => open,
            pmmu_walker_req => pmmu_walker_req,
            pmmu_walker_we => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => '0',
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => dbg_setopcode,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_opcode => dbg_opcode,
            debug_state => dbg_state,
            debug_setstate => dbg_setstate,
            debug_last_opc_read => dbg_last_opc,
            debug_data_read => dbg_data_read,
            debug_direct_data => open,
            debug_setnextpass => open,
            debug_TG68_PC => dbg_TG68_PC,
            debug_memaddr_reg => dbg_memaddr_reg,
            debug_memaddr_delta => dbg_memaddr_delta,
            debug_oddout => open,
            debug_decodeOPC => open,
            debug_brief => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw => dbg_clkena_lw,
            debug_regfile_d0 => open,
            debug_regfile_d1 => open,
            debug_regfile_d2 => open,
            debug_regfile_d3 => open,
            debug_regfile_d4 => open,
            debug_regfile_d5 => open,
            debug_regfile_d6 => open,
            debug_regfile_d7 => open,
            debug_regfile_a0 => open,
            debug_regfile_a1 => open,
            debug_regfile_a2 => open,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
            debug_regfile_a6 => open,
            debug_regfile_a7 => open,
            debug_regfile_we => open,
            debug_regfile_waddr => open,
            debug_regfile_wdata => open,
            debug_fline_context_valid => dbg_fline_ctx_valid,
            debug_trap_1111 => open,
            debug_trapmake => open,
            debug_pmmu_brief => dbg_pmmu_brief,
            debug_use_base => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA => open,
            debug_pmmu_busy => open,
            debug_micro_state => dbg_micro_state,
            debug_next_micro_state => dbg_next_micro_state,
            debug_memmask => dbg_memmask
        );

    -- Clock generation: 10ns period (100 MHz)
    clk <= not clk after 5 ns when test_done = '0' else '0';

    -- Memory read process (combinational for immediate response)
    mem_read_proc: process(addr)
        variable mem_addr : integer;
    begin
        mem_addr := to_integer(unsigned(addr(16 downto 1)));
        if mem_addr < 65536 then
            data_in <= memory(mem_addr);
        else
            data_in <= x"4E71";  -- NOP for out of range
        end if;
    end process;

    -- Memory write process (registered)
    mem_write_proc: process(clk)
        variable mem_addr : integer;
    begin
        if rising_edge(clk) then
            mem_addr := to_integer(unsigned(addr(16 downto 1)));
            -- Memory write
            if busstate = "11" and nWr = '0' then  -- Write cycle
                if mem_addr < 65536 then
                    memory(mem_addr) := data_out;
                end if;
            end if;
        end if;
    end process;

    -- PMMU walker handshake process
    -- Immediately ack any walker request to prevent hangs if MMU gets enabled
    walker_proc: process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' then
                pmmu_walker_ack <= '1';
                pmmu_walker_data <= x"00000000";  -- Return invalid descriptor (will cause bus error or fault)
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    -- Main test process
    test_proc: process
        variable pc : integer;
        variable instr_size : integer;
        variable l : line;
        variable test_idx : integer := 0;

        -- Helper to record a test
        procedure record_test(
            start : integer;
            size : integer;
            reg : string(1 to 5);
            dir : string(1 to 7);
            mode : string(1 to 10)
        ) is
        begin
            test_info(test_idx).start_pc <= start;
            test_info(test_idx).instr_size <= size;
            test_info(test_idx).reg_name <= reg;
            test_info(test_idx).direction <= dir;
            test_info(test_idx).ea_mode <= mode;
            test_idx := test_idx + 1;
            num_tests <= test_idx;
        end procedure;

        -- Helper to emit PMOVE and record test
        procedure emit_and_record(
            variable pc : inout integer;
            reg_sel : std_logic_vector(4 downto 0);
            reg_name : string(1 to 5);
            direction : std_logic;
            dir_name : string(1 to 7);
            ea_mode : std_logic_vector(2 downto 0);
            ea_reg : std_logic_vector(2 downto 0);
            mode_name : string(1 to 10);
            disp_or_addr : std_logic_vector(15 downto 0);
            addr_hi : std_logic_vector(15 downto 0)
        ) is
            variable start_pc : integer;
            variable size : integer;
        begin
            start_pc := pc;
            emit_pmove(pc, reg_sel, direction, ea_mode, ea_reg, disp_or_addr, addr_hi, size);
            record_test(start_pc, size, reg_name, dir_name, mode_name);
        end procedure;

    begin
        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("PMOVE PC INCREMENT TEST - WINUAE MC68030 EAS"));
        writeline(output, l);
        write(l, string'("Registers: TC, TT0, TT1, CRP, SRP, MMUSR"));
        writeline(output, l);
        write(l, string'("Modes: (An), (d16,An),"));
        writeline(output, l);
        write(l, string'("       (d8,An,Xn), (xxx).W, (xxx).L"));
        writeline(output, l);
        write(l, string'("=============================================="));
        writeline(output, l);

        -- Initialize memory with test program
        -- Reset vector at $0
        memory(0) := x"0000";  -- Initial SSP high
        memory(1) := x"1000";  -- Initial SSP low = $00001000
        memory(2) := x"0000";  -- Initial PC high
        memory(3) := x"0400";  -- Initial PC low = $00000400

        -- Set up stack area at $1000
        for i in 16#800# to 16#8FF# loop
            memory(i) := x"0000";
        end loop;

        -- Data area at $2000 for memory operations
        -- IMPORTANT: Use safe values to avoid enabling MMU with garbage!
        -- TC/CRP/SRP mem->MMU tests would load these values into control registers.
        -- TC.EN (bit31) must be 0 to keep MMU disabled.
        -- Use 0x5A5A as test pattern - bit 15 is 0, so TC.EN stays 0 when used as high word.
        for i in 16#1000# to 16#10FF# loop
            memory(i) := x"5A5A";
        end loop;

        -- Program starts at $400
        pc := 16#400#;

        -- Initialize A0 = $2000 for (An) modes
        -- MOVEA.L #$2000,A0
        emit_word(pc, x"207C");  -- MOVEA.L #imm,A0
        emit_word(pc, x"0000");
        emit_word(pc, x"2000");

        -- Initialize A1 = $2100 for another base
        -- MOVEA.L #$2100,A1
        emit_word(pc, x"227C");  -- MOVEA.L #imm,A1
        emit_word(pc, x"0000");
        emit_word(pc, x"2100");

        -- Initialize D0 with test data
        -- MOVE.L #$12345678,D0
        emit_word(pc, x"203C");
        emit_word(pc, x"1234");
        emit_word(pc, x"5678");

        -- Initialize D1 with more test data (for CRP/SRP high word)
        -- MOVE.L #$87654321,D1
        emit_word(pc, x"223C");
        emit_word(pc, x"8765");
        emit_word(pc, x"4321");

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("--- Emitting PMOVE instructions ---"));
        writeline(output, l);

        -- ============================================================
        -- TC REGISTER TESTS (32-bit)
        -- ============================================================
        write(l, string'("TC Register (32-bit):"));
        writeline(output, l);

        -- TC: MMU->mem with various EA modes
        emit_and_record(pc, REG_TC, "TC   ", DIR_MMU_TO_MEM, "MMU>mem", "010", "000", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MMU_TO_MEM, "MMU>mem", "101", "000", "(d16,An)  ", x"0010", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MMU_TO_MEM, "MMU>mem", "110", "000", "(d8,An,Xn)", x"0008", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MMU_TO_MEM, "MMU>mem", "111", "000", "(xxx).W   ", x"2000", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MMU_TO_MEM, "MMU>mem", "111", "001", "(xxx).L   ", x"2000", x"0000");

        -- TC: mem->MMU with various EA modes
        emit_and_record(pc, REG_TC, "TC   ", DIR_MEM_TO_MMU, "mem>MMU", "010", "001", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MEM_TO_MMU, "mem>MMU", "101", "001", "(d16,An)  ", x"0020", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MEM_TO_MMU, "mem>MMU", "110", "001", "(d8,An,Xn)", x"0010", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MEM_TO_MMU, "mem>MMU", "111", "000", "(xxx).W   ", x"2000", x"0000");
        emit_and_record(pc, REG_TC, "TC   ", DIR_MEM_TO_MMU, "mem>MMU", "111", "001", "(xxx).L   ", x"2000", x"0000");

        -- ============================================================
        -- TT0 REGISTER TESTS (32-bit)
        -- ============================================================
        write(l, string'("TT0 Register (32-bit):"));
        writeline(output, l);

        emit_and_record(pc, REG_TT0, "TT0  ", DIR_MMU_TO_MEM, "MMU>mem", "010", "000", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_TT0, "TT0  ", DIR_MMU_TO_MEM, "MMU>mem", "101", "000", "(d16,An)  ", x"0030", x"0000");
        emit_and_record(pc, REG_TT0, "TT0  ", DIR_MMU_TO_MEM, "MMU>mem", "111", "001", "(xxx).L   ", x"2000", x"0000");
        emit_and_record(pc, REG_TT0, "TT0  ", DIR_MEM_TO_MMU, "mem>MMU", "010", "001", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_TT0, "TT0  ", DIR_MEM_TO_MMU, "mem>MMU", "101", "001", "(d16,An)  ", x"0040", x"0000");
        emit_and_record(pc, REG_TT0, "TT0  ", DIR_MEM_TO_MMU, "mem>MMU", "111", "001", "(xxx).L   ", x"2000", x"0000");

        -- ============================================================
        -- TT1 REGISTER TESTS (32-bit)
        -- ============================================================
        write(l, string'("TT1 Register (32-bit):"));
        writeline(output, l);

        emit_and_record(pc, REG_TT1, "TT1  ", DIR_MMU_TO_MEM, "MMU>mem", "010", "000", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_TT1, "TT1  ", DIR_MMU_TO_MEM, "MMU>mem", "101", "000", "(d16,An)  ", x"0050", x"0000");
        emit_and_record(pc, REG_TT1, "TT1  ", DIR_MMU_TO_MEM, "MMU>mem", "111", "001", "(xxx).L   ", x"2000", x"0000");
        emit_and_record(pc, REG_TT1, "TT1  ", DIR_MEM_TO_MMU, "mem>MMU", "010", "001", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_TT1, "TT1  ", DIR_MEM_TO_MMU, "mem>MMU", "101", "001", "(d16,An)  ", x"0060", x"0000");
        emit_and_record(pc, REG_TT1, "TT1  ", DIR_MEM_TO_MMU, "mem>MMU", "111", "001", "(xxx).L   ", x"2000", x"0000");

        -- ============================================================
        -- CRP REGISTER TESTS (64-bit - 2 longwords)
        -- ============================================================
        write(l, string'("CRP Register (64-bit):"));
        writeline(output, l);

        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MMU_TO_MEM, "MMU>mem", "010", "000", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MMU_TO_MEM, "MMU>mem", "101", "000", "(d16,An)  ", x"0070", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MMU_TO_MEM, "MMU>mem", "110", "000", "(d8,An,Xn)", x"0008", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MMU_TO_MEM, "MMU>mem", "111", "000", "(xxx).W   ", x"2000", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MMU_TO_MEM, "MMU>mem", "111", "001", "(xxx).L   ", x"2000", x"0000");

        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MEM_TO_MMU, "mem>MMU", "010", "001", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MEM_TO_MMU, "mem>MMU", "101", "001", "(d16,An)  ", x"0080", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MEM_TO_MMU, "mem>MMU", "110", "001", "(d8,An,Xn)", x"0010", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MEM_TO_MMU, "mem>MMU", "111", "000", "(xxx).W   ", x"2000", x"0000");
        emit_and_record(pc, REG_CRP, "CRP  ", DIR_MEM_TO_MMU, "mem>MMU", "111", "001", "(xxx).L   ", x"2000", x"0000");

        -- ============================================================
        -- SRP REGISTER TESTS (64-bit - 2 longwords)
        -- ============================================================
        write(l, string'("SRP Register (64-bit):"));
        writeline(output, l);

        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MMU_TO_MEM, "MMU>mem", "010", "000", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MMU_TO_MEM, "MMU>mem", "101", "000", "(d16,An)  ", x"0090", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MMU_TO_MEM, "MMU>mem", "110", "000", "(d8,An,Xn)", x"0008", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MMU_TO_MEM, "MMU>mem", "111", "000", "(xxx).W   ", x"2000", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MMU_TO_MEM, "MMU>mem", "111", "001", "(xxx).L   ", x"2000", x"0000");

        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MEM_TO_MMU, "mem>MMU", "010", "001", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MEM_TO_MMU, "mem>MMU", "101", "001", "(d16,An)  ", x"00A0", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MEM_TO_MMU, "mem>MMU", "110", "001", "(d8,An,Xn)", x"0010", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MEM_TO_MMU, "mem>MMU", "111", "000", "(xxx).W   ", x"2000", x"0000");
        emit_and_record(pc, REG_SRP, "SRP  ", DIR_MEM_TO_MMU, "mem>MMU", "111", "001", "(xxx).L   ", x"2000", x"0000");

        -- ============================================================
        -- MMUSR REGISTER TESTS (16-bit)
        -- Note: MMUSR can only be written TO memory (MMU->mem)
        -- ============================================================
        write(l, string'("MMUSR Register (16-bit, MMU->mem only):"));
        writeline(output, l);

        emit_and_record(pc, REG_MMUSR, "MMUSR", DIR_MMU_TO_MEM, "MMU>mem", "010", "000", "(An)      ", x"0000", x"0000");
        emit_and_record(pc, REG_MMUSR, "MMUSR", DIR_MMU_TO_MEM, "MMU>mem", "101", "000", "(d16,An)  ", x"00B0", x"0000");
        emit_and_record(pc, REG_MMUSR, "MMUSR", DIR_MMU_TO_MEM, "MMU>mem", "110", "000", "(d8,An,Xn)", x"0008", x"0000");
        emit_and_record(pc, REG_MMUSR, "MMUSR", DIR_MMU_TO_MEM, "MMU>mem", "111", "000", "(xxx).W   ", x"2000", x"0000");
        emit_and_record(pc, REG_MMUSR, "MMUSR", DIR_MMU_TO_MEM, "MMU>mem", "111", "001", "(xxx).L   ", x"2000", x"0000");

        -- End program with STOP
        emit_word(pc, x"4E72");  -- STOP #imm
        emit_word(pc, x"2700");  -- SR value

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("Program ends at PC=$") & to_hex_string(std_logic_vector(to_unsigned(pc, 16))));
        writeline(output, l);
        write(l, string'("Total tests: ") & integer'image(test_idx));
        writeline(output, l);
        write(l, string'(""));
        writeline(output, l);

        -- Wait for delta cycle
        wait for 0 ns;

        -- Release reset (active low)
        wait for 100 ns;
        nReset <= '1';

        write(l, string'("--- Starting CPU execution ---"));
        writeline(output, l);

        -- Run simulation
        wait for 2000 us;

        test_done <= '1';

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("TEST SUMMARY"));
        writeline(output, l);
        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("Tests Passed: ") & integer'image(tests_passed));
        writeline(output, l);
        write(l, string'("Tests Failed: ") & integer'image(tests_failed));
        writeline(output, l);

        if tests_failed = 0 and tests_passed > 0 then
            write(l, string'("RESULT: ALL TESTS PASSED"));
            writeline(output, l);
        elsif tests_passed = 0 and tests_failed = 0 then
            write(l, string'("RESULT: NO TESTS COMPLETED (timeout or error)"));
            writeline(output, l);
        else
            write(l, string'("RESULT: SOME TESTS FAILED"));
            writeline(output, l);
        end if;

        wait;
    end process;

    -- PC monitoring and validation process
    pc_monitor: process(clk)
        variable l : line;
        variable fetch_addr : integer;
        variable test_start : integer;
        variable test_size : integer;
        variable expected_next : integer;
        variable active_test : integer := -1;  -- -1 means no active test
        variable test_validated : boolean := false;
    begin
        if rising_edge(clk) and nReset = '1' and test_done = '0' then
            cycle_count <= cycle_count + 1;

            -- Track instruction fetches

            if busstate = "00" then  -- Fetch cycle
                fetch_addr := to_integer(unsigned(addr));

                -- Only start monitoring after we reach the test program area
                if fetch_addr >= 16#400# then
                    -- Check if this fetch is the start of a new test instruction
                    for i in 0 to num_tests-1 loop
                        if fetch_addr = test_info(i).start_pc then
                            -- If we had a previous test, validate it
                            if active_test >= 0 and not test_validated then
                                test_start := test_info(active_test).start_pc;
                                test_size := test_info(active_test).instr_size;
                                expected_next := test_start + test_size;

                                if fetch_addr = expected_next then
                                    tests_passed <= tests_passed + 1;
                                    write(l, string'("  PASS: PC=$") &
                                          to_hex_string(std_logic_vector(to_unsigned(fetch_addr, 16))));
                                    writeline(output, l);
                                elsif fetch_addr > expected_next then
                                    tests_failed <= tests_failed + 1;
                                    write(l, string'("  FAIL: OVER by ") &
                                          integer'image(fetch_addr - expected_next) &
                                          string'(" Expected $") &
                                          to_hex_string(std_logic_vector(to_unsigned(expected_next, 16))) &
                                          string'(" got $") &
                                          to_hex_string(std_logic_vector(to_unsigned(fetch_addr, 16))));
                                    writeline(output, l);
                                else
                                    tests_failed <= tests_failed + 1;
                                    write(l, string'("  FAIL: UNDER by ") &
                                          integer'image(expected_next - fetch_addr) &
                                          string'(" Expected $") &
                                          to_hex_string(std_logic_vector(to_unsigned(expected_next, 16))) &
                                          string'(" got $") &
                                          to_hex_string(std_logic_vector(to_unsigned(fetch_addr, 16))));
                                    writeline(output, l);
                                end if;
                                test_validated := true;
                            end if;

                            -- Starting a new test
                            active_test := i;
                            test_validated := false;
                            test_start := test_info(i).start_pc;
                            test_size := test_info(i).instr_size;
                            current_test <= i;

                            write(l, string'("TEST ") & integer'image(i) & string'(": ") &
                                  test_info(i).reg_name & string'(" ") &
                                  test_info(i).direction & string'(" ") &
                                  test_info(i).ea_mode &
                                  string'(" PC=$") & to_hex_string(addr(15 downto 0)) &
                                  string'(" size=") & integer'image(test_size));
                            writeline(output, l);
                            exit;
                        end if;
                    end loop;
                end if;

                last_pc <= addr;
            end if;
        end if;
    end process;

    -- Debug trace process for test 12
    dbg_trace: process(clk)
        variable l : line;
        variable dbg_cycle : integer := 0;
    begin
        if rising_edge(clk) and nReset = '1' and test_done = '0' then
            -- Activate trace when near test 33 (CRP mem>MMU, after test 32 at PC=$04CA size=8)
            if busstate = "00" and to_integer(unsigned(addr)) >= 16#04CA# and not dbg_trace_active then
                dbg_trace_active <= true;
                dbg_cycle := 0;
            end if;

            if dbg_trace_active and dbg_cycle < 200 then
                write(l, string'("DBG "));
                write(l, dbg_cycle);
                write(l, string'(" st=") & to_hex_string("000000" & dbg_state));
                write(l, string'(" ss=") & to_hex_string("000000" & dbg_setstate));
                write(l, string'(" us="));
                write(l, dbg_micro_state);
                write(l, string'(" ns="));
                write(l, dbg_next_micro_state);
                write(l, string'(" mm=") & to_hex_string("00" & dbg_memmask));
                write(l, string'(" bs=") & to_hex_string("000000" & busstate));
                write(l, string'(" addr=") & to_hex_string(addr));
                write(l, string'(" mr=") & to_hex_string(dbg_memaddr_reg));
                write(l, string'(" md=") & to_hex_string(dbg_memaddr_delta));
                write(l, string'(" pc=") & to_hex_string(dbg_TG68_PC));
                write(l, string'(" opc=") & to_hex_string(dbg_opcode));
                write(l, string'(" lor=") & to_hex_string(dbg_last_opc));
                write(l, string'(" din=") & to_hex_string(data_in));
                write(l, string'(" br=") & to_hex_string(dbg_pmmu_brief));
                write(l, string'(" dr=") & to_hex_string(dbg_data_read));
                write(l, string'(" fc="));
                if dbg_fline_ctx_valid = '1' then
                    write(l, string'("1"));
                else
                    write(l, string'("0"));
                end if;
                write(l, string'(" cl="));
                if dbg_clkena_lw = '1' then
                    write(l, string'("1"));
                else
                    write(l, string'("0"));
                end if;
                write(l, string'(" so="));
                if dbg_setopcode = '1' then
                    write(l, string'("1"));
                else
                    write(l, string'("0"));
                end if;
                writeline(output, l);
                dbg_cycle := dbg_cycle + 1;
            end if;
        end if;
    end process;

end behavioral;
