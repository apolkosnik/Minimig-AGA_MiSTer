-- tb_pload_all_modes.vhd
-- Comprehensive PLOAD testbench (all EA modes, FC specs, R/W)
-- Uses same dynamic ROM pattern as tb_pmove_all_modes.vhd
-- Verifies PLOAD by checking MMUSR via PTEST after each PLOAD
-- Requires working page table walker (page tables in shared memory)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
library work;
use work.TG68K_Pack.all;

entity tb_pload_all_modes is
end entity;

architecture behavioral of tb_pload_all_modes is

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
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal clkena_in : std_logic := '1';

    -- CPU interface signals
    signal data_in   : std_logic_vector(15 downto 0) := (others => '0');
    signal data_out  : std_logic_vector(15 downto 0);
    signal addr      : std_logic_vector(31 downto 0);
    signal nWr       : std_logic;
    signal nUDS      : std_logic;
    signal nLDS      : std_logic;
    signal fc        : std_logic_vector(2 downto 0);
    signal ipl       : std_logic_vector(2 downto 0) := "111";
    signal busstate  : std_logic_vector(1 downto 0);
    signal longword  : std_logic;

    -- PMMU signals
    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    -- Debug register taps
    signal dbg_reg_d0 : std_logic_vector(31 downto 0);
    signal dbg_reg_d1 : std_logic_vector(31 downto 0);
    signal dbg_reg_d2 : std_logic_vector(31 downto 0);
    signal dbg_reg_d3 : std_logic_vector(31 downto 0);
    signal dbg_reg_d6 : std_logic_vector(31 downto 0);
    signal dbg_reg_a0 : std_logic_vector(31 downto 0);
    signal dbg_reg_a1 : std_logic_vector(31 downto 0);
    signal dbg_reg_a2 : std_logic_vector(31 downto 0);
    signal dbg_reg_a3 : std_logic_vector(31 downto 0);
    signal dbg_reg_a4 : std_logic_vector(31 downto 0);
    signal dbg_reg_a5 : std_logic_vector(31 downto 0);
    signal dbg_reg_a7 : std_logic_vector(31 downto 0);
    signal dbg_opcode : std_logic_vector(15 downto 0);
    signal dbg_setopcode : std_logic;
    signal dbg_pc : std_logic_vector(31 downto 0);
    signal dbg_exe_pc : std_logic_vector(31 downto 0);
    signal dbg_brief : std_logic_vector(15 downto 0);
    signal dbg_sndopc : std_logic_vector(15 downto 0);
    signal exec_pc : std_logic_vector(31 downto 0) := (others => '0');
    signal exec_seen : std_logic := '0';
    signal exec_count_sig : integer := 0;
    signal bad_pc : std_logic := '0';
    signal dbg_memmask : std_logic_vector(5 downto 0);
    signal dbg_micro_state : integer range 0 to 255;
    signal dbg_next_micro_state : integer range 0 to 255;
    signal dbg_regfile_we : std_logic;
    signal dbg_regfile_waddr : std_logic_vector(3 downto 0);
    signal dbg_regfile_wdata : std_logic_vector(31 downto 0);
    signal dbg_state : std_logic_vector(1 downto 0);
    signal dbg_last_opc_read : std_logic_vector(15 downto 0);
    signal dbg_data_read : std_logic_vector(31 downto 0);
    signal dbg_last_data_read : std_logic_vector(31 downto 0);
    signal dbg_last_opc_pc : std_logic_vector(31 downto 0);
    signal dbg_fline_brief_pending : std_logic;
    signal dbg_fline_opcode_pc : std_logic_vector(31 downto 0);
    signal dbg_getbrief : std_logic;
    signal dbg_get_2ndopc : std_logic;
    signal dbg_direct_data : std_logic;
    signal dbg_memaddr_reg : std_logic_vector(31 downto 0);
    signal dbg_memaddr_delta : std_logic_vector(31 downto 0);
    signal dbg_pmmu_reg_we : std_logic;
    signal dbg_pmmu_reg_re : std_logic;
    signal dbg_pmmu_reg_sel : std_logic_vector(4 downto 0);
    signal dbg_pmmu_reg_wdat : std_logic_vector(31 downto 0);
    signal dbg_pmmu_reg_part : std_logic;
    signal dbg_memaddr_delta_rega : std_logic_vector(31 downto 0);
    signal dbg_memaddr_delta_regb : std_logic_vector(31 downto 0);
    signal dbg_addsub_q : std_logic_vector(31 downto 0);
    signal dbg_memmaskmux : std_logic_vector(5 downto 0);
    signal dbg_fline_opcode_latch : std_logic_vector(15 downto 0);
    signal dbg_pmmu_ea_mode_latched : std_logic_vector(5 downto 0);
    signal dbg_pmmu_brief : std_logic_vector(15 downto 0);
    signal dbg_exec_direct_delta : std_logic;
    signal dbg_exec_directPC : std_logic;
    signal dbg_exec_mem_addsub : std_logic;
    signal dbg_set_addrlong : std_logic;
    signal dbg_setstate : std_logic_vector(1 downto 0);
    signal dbg_setnextpass : std_logic;
    signal dbg_fline_context_valid : std_logic;
    signal dbg_pmove_dn_mode : std_logic;
    signal dbg_mdelta_src : std_logic_vector(7 downto 0);
    signal dbg_pc_brw : std_logic;
    signal dbg_pc_word : std_logic;
    signal dbg_trapmake : std_logic;
    signal dbg_trap_1111 : std_logic;
    signal dbg_trap_illegal : std_logic;
    signal dbg_trap_priv : std_logic;
    signal dbg_trap_addr_error : std_logic;
    signal dbg_trap_berr : std_logic;
    signal dbg_trap_mmu_berr : std_logic;
    signal dbg_trap_vector : std_logic_vector(31 downto 0);
    signal dbg_pc_add : std_logic_vector(31 downto 0);
    signal dbg_pc_dataa : std_logic_vector(31 downto 0);
    signal dbg_pc_datab : std_logic_vector(31 downto 0);
    signal dbg_pmmu_reg_rdat : std_logic_vector(31 downto 0);
    signal mmusr_capture_idx : integer := 0;

    -- Memory: 64K words (128KB)
    type mem_array is array (0 to 65535) of std_logic_vector(15 downto 0);
    shared variable memory : mem_array := (others => x"4E71");

    -- MMUSR capture: list of verification memory addresses to write captured MMUSR values
    type int_array_t is array (0 to 63) of integer;
    shared variable mmusr_dst_addrs : int_array_t := (others => 0);
    shared variable mmusr_dst_count : integer := 0;

    -- Test control
    signal test_done : std_logic := '0';

    constant CLK_PERIOD : time := 10 ns;

    -- PMOVE reg selectors (brief[14:10])
    constant REG_TT0   : std_logic_vector(4 downto 0) := "00010";
    constant REG_TT1   : std_logic_vector(4 downto 0) := "00011";
    constant REG_TC    : std_logic_vector(4 downto 0) := "10000";
    constant REG_SRP   : std_logic_vector(4 downto 0) := "10010";
    constant REG_CRP   : std_logic_vector(4 downto 0) := "10011";
    constant REG_MMUSR : std_logic_vector(4 downto 0) := "11000";

    constant DIR_MEM_TO_MMU : std_logic := '0';
    constant DIR_MMU_TO_MEM : std_logic := '1';

    -- PLOAD target address (logical address to translate via page table)
    constant PLOAD_ADDR : std_logic_vector(31 downto 0) := x"00001000";

    -- TC: E=1, PS=12(4K), IS=0, TIA=10, TIB=10, TIC=0, TID=0
    -- Sum: 12+0+10+10+0+0 = 32 (correct)
    -- = 1000_0000_1100_0000_1010_1010_0000_0000 = $80C0AA00
    constant VAL_TC_PLOAD : std_logic_vector(31 downto 0) := x"80C0AA00";

    -- CRP: DT=10 (valid short-format table), root table at $4000
    -- HIGH word: Limit=0, L/U=0 (lower limit=0, always passes), DT=10
    -- LOW word: root address = $00004000
    constant VAL_CRP_HI : std_logic_vector(31 downto 0) := x"00000002";
    constant VAL_CRP_LO : std_logic_vector(31 downto 0) := x"00004000";

    -- Page table addresses
    constant ROOT_TABLE : integer := 16#4000#;
    constant L2_TABLE   : integer := 16#5000#;
    constant PTEST_A_DESC_ADDR : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_unsigned(L2_TABLE + 4, 32));
    constant PTEST_A_RESULT_ADDR : integer := 16#28E0#;
    constant FLINE_RESERVED_RESULT_ADDR : integer := 16#28F0#;

    -- Helper types for test records
    type word_array is array (0 to 3) of std_logic_vector(15 downto 0);
    type test_record is record
        desc      : string(1 to 80);
        dest_addr : integer;
        words     : integer;
        exp       : word_array;
    end record;

    constant MAX_TESTS : integer := 64;
    constant VERBOSE : boolean := true;
    constant TRACE_FETCH : boolean := false;
    type test_array is array (0 to MAX_TESTS-1) of test_record;

    function slv16_to_hex(v : std_logic_vector(15 downto 0)) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to 4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to 3 loop
            nibble := v(15 - i*4 downto 12 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    function slv32_to_hex(v : std_logic_vector(31 downto 0)) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to 8);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to 7 loop
            nibble := v(31 - i*4 downto 28 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    function has_x(v : std_logic_vector) return boolean is
    begin
        for i in v'range loop
            if v(i) /= '0' and v(i) /= '1' then
                return true;
            end if;
        end loop;
        return false;
    end function;

    impure function mem_word(addr : integer) return std_logic_vector is
        variable idx : integer;
    begin
        idx := addr / 2;
        if idx >= 0 and idx <= 65535 then
            return memory(idx);
        else
            return x"4E71";
        end if;
    end function;

    function clean_slv(s : std_logic_vector) return std_logic_vector is
        variable v : std_logic_vector(s'range);
    begin
        for i in s'range loop
            if s(i) = '1' then
                v(i) := '1';
            else
                v(i) := '0';
            end if;
        end loop;
        return v;
    end function;

    impure function decode_exec_string(opc : std_logic_vector(15 downto 0); pc_int : integer; ext_word : std_logic_vector(15 downto 0)) return string is
        variable w1 : std_logic_vector(15 downto 0);
        variable w2 : std_logic_vector(15 downto 0);
        variable dn : integer;
        variable an : integer;
        variable mode_i : integer;
        variable reg_i : integer;
        variable sel_i : integer;
        variable dir : std_logic;
        variable ext : std_logic_vector(15 downto 0);
        variable opc_c : std_logic_vector(15 downto 0);
    begin
        opc_c := clean_slv(opc);
        -- F-line instructions (PMOVE, PTEST, PFLUSH, PLOAD)
        if opc_c(15 downto 8) = x"F0" then
            ext := ext_word;
            if ext = x"0000" then
                ext := mem_word(pc_int + 2);
            end if;
            mode_i := to_integer(unsigned(opc_c(5 downto 3)));
            reg_i := to_integer(unsigned(opc_c(2 downto 0)));
            -- PTEST
            if ext(15 downto 13) = "100" then
                if ext(9) = '1' then
                    return "PTESTR EA=(" & integer'image(mode_i) & "," & integer'image(reg_i) & ") ext=$" & slv16_to_hex(ext);
                else
                    return "PTESTW EA=(" & integer'image(mode_i) & "," & integer'image(reg_i) & ") ext=$" & slv16_to_hex(ext);
                end if;
            end if;
            -- PLOAD
            if ext(15 downto 13) = "001" and ext(12 downto 10) = "000" then
                if ext(9) = '1' then
                    return "PLOADR EA=(" & integer'image(mode_i) & "," & integer'image(reg_i) & ") ext=$" & slv16_to_hex(ext);
                else
                    return "PLOADW EA=(" & integer'image(mode_i) & "," & integer'image(reg_i) & ") ext=$" & slv16_to_hex(ext);
                end if;
            end if;
            -- PFLUSH
            if ext(15 downto 13) = "001" and ext(12 downto 10) /= "000" then
                return "PFLUSH EA=(" & integer'image(mode_i) & "," & integer'image(reg_i) & ") ext=$" & slv16_to_hex(ext);
            end if;
            -- PMOVE
            sel_i := to_integer(unsigned(ext(14 downto 10)));
            dir := ext(9);
            if dir = '0' then
                return "PMOVE EA->MMU sel=" & integer'image(sel_i) & " ext=$" & slv16_to_hex(ext);
            else
                return "PMOVE MMU->EA sel=" & integer'image(sel_i) & " ext=$" & slv16_to_hex(ext);
            end if;
        end if;

        -- NOP
        if opc = x"4E71" then return "NOP"; end if;
        -- STOP
        if opc = x"4E72" then
            w1 := mem_word(pc_int + 2);
            return "STOP #$" & slv16_to_hex(w1);
        end if;
        -- MOVEC Rn,Rc
        if opc = x"4E7B" then
            w1 := mem_word(pc_int + 2);
            return "MOVEC ext=$" & slv16_to_hex(w1);
        end if;
        -- MOVEQ #imm,Dn
        if opc_c(15 downto 12) = "0111" then
            dn := to_integer(unsigned(opc_c(11 downto 9)));
            return "MOVEQ #$" & slv16_to_hex("00000000" & opc_c(7 downto 0)) & ",D" & integer'image(dn);
        end if;
        -- MOVEA.L #imm,An
        if opc_c(15 downto 12) = "0010" and opc_c(7 downto 0) = x"7C" then
            an := to_integer(unsigned(opc_c(11 downto 9)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVEA.L #$" & slv16_to_hex(w1) & slv16_to_hex(w2) & ",A" & integer'image(an);
        end if;
        -- MOVE.L (abs).L,Dn
        if opc_c(15 downto 12) = "0010" and opc_c(8 downto 6) = "000" and opc_c(5 downto 3) = "111" and opc_c(2 downto 0) = "001" then
            dn := to_integer(unsigned(opc_c(11 downto 9)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVE.L ($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L,D" & integer'image(dn);
        end if;
        -- MOVE.L Dn,(abs).L
        if opc_c(15 downto 8) = x"23" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then
            dn := to_integer(unsigned(opc_c(2 downto 0)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVE.L D" & integer'image(dn) & ",($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L";
        end if;
        -- MOVE.W Dn,(abs).L
        if opc_c(15 downto 8) = x"33" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then
            dn := to_integer(unsigned(opc_c(2 downto 0)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVE.W D" & integer'image(dn) & ",($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L";
        end if;
        -- MOVE.L An,(abs).L
        if opc_c(15 downto 6) = "0010001111" and opc_c(5 downto 3) = "001" then
            an := to_integer(unsigned(opc_c(2 downto 0)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVE.L A" & integer'image(an) & ",($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L";
        end if;

        return "OPC $" & slv16_to_hex(opc);
    end function;

    impure function instr_len(opc : std_logic_vector(15 downto 0); pc_int : integer; ext_word : std_logic_vector(15 downto 0)) return integer is
        variable mode_i : integer;
        variable reg_i : integer;
        variable opc_c : std_logic_vector(15 downto 0);
    begin
        opc_c := clean_slv(opc);
        -- F-line (PMOVE/PTEST/PFLUSH/PLOAD): base 4 + EA extension
        if opc_c(15 downto 8) = x"F0" then
            mode_i := to_integer(unsigned(opc_c(5 downto 3)));
            reg_i := to_integer(unsigned(opc_c(2 downto 0)));
            case mode_i is
                when 5 => return 6;
                when 6 => return 6;
                when 7 =>
                    if reg_i = 0 then return 6;
                    elsif reg_i = 1 then return 8;
                    else return 4;
                    end if;
                when others => return 4;
            end case;
        end if;
        if opc_c = x"4E71" then return 2; end if;  -- NOP
        if opc_c = x"4E72" then return 4; end if;  -- STOP
        if opc_c = x"4E7B" then return 4; end if;  -- MOVEC
        if opc_c(15 downto 12) = "0111" then return 2; end if;  -- MOVEQ
        -- MOVEA.L #imm,An
        if opc_c(15 downto 12) = "0010" and opc_c(7 downto 0) = x"7C" then return 6; end if;
        -- MOVE.L (abs).L,Dn
        if opc_c(15 downto 12) = "0010" and opc_c(8 downto 6) = "000" and opc_c(5 downto 3) = "111" and opc_c(2 downto 0) = "001" then return 6; end if;
        -- MOVE.L Dn,(abs).L
        if opc_c(15 downto 8) = x"23" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then return 6; end if;
        -- MOVE.W Dn,(abs).L
        if opc_c(15 downto 8) = x"33" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then return 6; end if;
        -- MOVE.L An,(abs).L
        if opc_c(15 downto 6) = "0010001111" and opc_c(5 downto 3) = "001" then return 6; end if;
        return 2;
    end function;

    function words_to_hex(w : word_array; count : integer) return string is
        variable s : string(1 to 16) := (others => ' ');
    begin
        if count = 1 then
            s(1 to 4) := slv16_to_hex(w(0));
            return s(1 to 4);
        elsif count = 2 then
            s(1 to 4) := slv16_to_hex(w(0));
            s(5 to 8) := slv16_to_hex(w(1));
            return s(1 to 8);
        else
            s(1 to 4) := slv16_to_hex(w(0));
            s(5 to 8) := slv16_to_hex(w(1));
            s(9 to 12) := slv16_to_hex(w(2));
            s(13 to 16) := slv16_to_hex(w(3));
            return s(1 to 16);
        end if;
    end function;

    impure function words_at_pc_to_hex(pc_int : integer; count : integer) return string is
        variable s : string(1 to 64) := (others => ' ');
        variable idx : integer := 1;
        variable w : std_logic_vector(15 downto 0);
    begin
        for i in 0 to count-1 loop
            w := mem_word(pc_int + (i * 2));
            s(idx to idx+3) := slv16_to_hex(w);
            idx := idx + 4;
            if i < count-1 then
                s(idx) := ' ';
                idx := idx + 1;
            end if;
        end loop;
        return s(1 to idx-1);
    end function;

    -- Emit a word into memory at PC, increment PC
    procedure emit_word(variable pc : inOut integer; w : std_logic_vector(15 downto 0)) is
    begin
        memory(pc/2) := w;
        pc := pc + 2;
    end procedure;

    -- Emit MOVEA.L #imm,Areg (supports A0-A7)
    procedure emit_movea(variable pc : inOut integer; areg : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := "0010" & std_logic_vector(to_unsigned(areg, 3)) & "001111100";
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit MOVEQ #imm,Dn
    procedure emit_moveq(variable pc : inOut integer; dn : integer; imm : integer) is
        variable opcode : std_logic_vector(15 downto 0);
        variable imm8 : integer;
    begin
        imm8 := imm mod 256;
        opcode := std_logic_vector(to_unsigned(16#7000# + (dn * 512) + imm8, 16));
        emit_word(pc, opcode);
    end procedure;

    -- Emit MOVE.L (abs).L,Dn
    procedure emit_move_l_abs_to_dn(variable pc : inOut integer; dn : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := std_logic_vector(to_unsigned(16#2039# + (dn * 16#0200#), 16));
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit MOVE.L Dn,(abs).L
    procedure emit_move_l_dn_to_abs(variable pc : inOut integer; dn : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := std_logic_vector(to_unsigned(16#23C0# + dn, 16));
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit MOVE.W Dn,(abs).L
    procedure emit_move_w_dn_to_abs(variable pc : inOut integer; dn : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := std_logic_vector(to_unsigned(16#33C0# + dn, 16));
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit MOVE.L An,(abs).L
    procedure emit_move_l_an_to_abs(variable pc : inOut integer; an : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := std_logic_vector(to_unsigned(16#23C8# + an, 16));
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit PMOVE instruction
    procedure emit_pmove(
        variable pc : inOut integer;
        reg_sel : std_logic_vector(4 downto 0);
        direction : std_logic;
        ea_mode : std_logic_vector(2 downto 0);
        ea_reg : std_logic_vector(2 downto 0);
        disp_or_addr : std_logic_vector(15 downto 0);
        addr_hi : std_logic_vector(15 downto 0)
    ) is
        variable opcode : std_logic_vector(15 downto 0);
        variable extension : std_logic_vector(15 downto 0);
    begin
        opcode := "1111000000" & ea_mode & ea_reg;
        extension := "0" & reg_sel & direction & "000000000";
        emit_word(pc, opcode);
        emit_word(pc, extension);
        case ea_mode is
            when "101" => emit_word(pc, disp_or_addr);
            when "110" => emit_word(pc, disp_or_addr);
            when "111" =>
                if ea_reg = "000" then
                    emit_word(pc, disp_or_addr);
                elsif ea_reg = "001" then
                    emit_word(pc, addr_hi);
                    emit_word(pc, disp_or_addr);
                end if;
            when others => null;
        end case;
    end procedure;

    -- Emit PTEST instruction
    -- Extension word: 100 LLL R A RRR FFFFF
    procedure emit_ptest(
        variable pc : inOut integer;
        ea_mode : std_logic_vector(2 downto 0);
        ea_reg : std_logic_vector(2 downto 0);
        level : std_logic_vector(2 downto 0);
        rw : std_logic;
        a_bit : std_logic;
        a_reg : std_logic_vector(2 downto 0);
        fc_spec : std_logic_vector(4 downto 0);
        disp_or_addr : std_logic_vector(15 downto 0);
        addr_hi : std_logic_vector(15 downto 0)
    ) is
        variable opcode : std_logic_vector(15 downto 0);
        variable extension : std_logic_vector(15 downto 0);
    begin
        opcode := "1111000000" & ea_mode & ea_reg;
        extension := "100" & level & rw & a_bit & a_reg & fc_spec;
        emit_word(pc, opcode);
        emit_word(pc, extension);
        case ea_mode is
            when "101" => emit_word(pc, disp_or_addr);
            when "110" => emit_word(pc, disp_or_addr);
            when "111" =>
                if ea_reg = "000" then
                    emit_word(pc, disp_or_addr);
                elsif ea_reg = "001" then
                    emit_word(pc, addr_hi);
                    emit_word(pc, disp_or_addr);
                end if;
            when others => null;
        end case;
    end procedure;

    -- Emit PLOAD instruction
    -- Extension word: 001 000 R 0000 FFFFF
    procedure emit_pload(
        variable pc : inOut integer;
        ea_mode : std_logic_vector(2 downto 0);
        ea_reg : std_logic_vector(2 downto 0);
        rw : std_logic;             -- 1=PLOADR, 0=PLOADW
        fc_spec : std_logic_vector(4 downto 0);
        disp_or_addr : std_logic_vector(15 downto 0);
        addr_hi : std_logic_vector(15 downto 0)
    ) is
        variable opcode : std_logic_vector(15 downto 0);
        variable extension : std_logic_vector(15 downto 0);
    begin
        opcode := "1111000000" & ea_mode & ea_reg;
        extension := "001" & "000" & rw & "0000" & fc_spec;
        emit_word(pc, opcode);
        emit_word(pc, extension);
        case ea_mode is
            when "101" => emit_word(pc, disp_or_addr);
            when "110" => emit_word(pc, disp_or_addr);
            when "111" =>
                if ea_reg = "000" then
                    emit_word(pc, disp_or_addr);
                elsif ea_reg = "001" then
                    emit_word(pc, addr_hi);
                    emit_word(pc, disp_or_addr);
                end if;
            when others => null;
        end case;
    end procedure;

    -- Emit PLOAD with reserved bits 8:5 explicitly set for negative tests.
    procedure emit_pload_reserved(
        variable pc : inOut integer;
        ea_mode : std_logic_vector(2 downto 0);
        ea_reg : std_logic_vector(2 downto 0);
        rw : std_logic;             -- 1=PLOADR, 0=PLOADW
        reserved_bits : std_logic_vector(3 downto 0);
        fc_spec : std_logic_vector(4 downto 0);
        disp_or_addr : std_logic_vector(15 downto 0);
        addr_hi : std_logic_vector(15 downto 0)
    ) is
        variable opcode : std_logic_vector(15 downto 0);
        variable extension : std_logic_vector(15 downto 0);
    begin
        opcode := "1111000000" & ea_mode & ea_reg;
        extension := "001" & "000" & rw & reserved_bits & fc_spec;
        emit_word(pc, opcode);
        emit_word(pc, extension);
        case ea_mode is
            when "101" => emit_word(pc, disp_or_addr);
            when "110" => emit_word(pc, disp_or_addr);
            when "111" =>
                if ea_reg = "000" then
                    emit_word(pc, disp_or_addr);
                elsif ea_reg = "001" then
                    emit_word(pc, addr_hi);
                    emit_word(pc, disp_or_addr);
                end if;
            when others => null;
        end case;
    end procedure;

    -- Emit PFLUSHA (flush all ATC entries)
    -- Extension word: 001_001_00_0000_0000 = $2400
    procedure emit_pflusha(variable pc : inOut integer) is
    begin
        emit_word(pc, x"F000");
        emit_word(pc, x"2400");
    end procedure;

    -- Emit MOVEC Dn,Rc (general register to control register)
    -- SFC=$000, DFC=$001
    procedure emit_movec_dn_to_ctrl(variable pc : inOut integer; dn : integer; ctrl_id : integer) is
    begin
        emit_word(pc, x"4E7B");
        emit_word(pc, std_logic_vector(to_unsigned(dn * 4096 + ctrl_id, 16)));
    end procedure;

    -- Write helpers
    procedure write_word(addr : integer; w : std_logic_vector(15 downto 0)) is
    begin
        memory(addr/2) := w;
    end procedure;

    procedure write_long(addr : integer; v : std_logic_vector(31 downto 0)) is
    begin
        write_word(addr, v(31 downto 16));
        write_word(addr + 2, v(15 downto 0));
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
            CPU => "10",
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
            pmmu_reg_we => dbg_pmmu_reg_we,
            pmmu_reg_re => dbg_pmmu_reg_re,
            pmmu_reg_sel => dbg_pmmu_reg_sel,
            pmmu_reg_wdat => dbg_pmmu_reg_wdat,
            pmmu_reg_part => dbg_pmmu_reg_part,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            cache_op_addr => open,
            pmmu_walker_req => pmmu_walker_req,
            pmmu_walker_we => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
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
            debug_pmove_dn_mode => dbg_pmove_dn_mode,
            debug_pmove_dn_regnum => open,
            debug_opcode => dbg_opcode,
            debug_state => dbg_state,
            debug_setstate => dbg_setstate,
            debug_setnextpass => dbg_setnextpass,
            debug_last_opc_read => dbg_last_opc_read,
            debug_data_read => dbg_data_read,
            debug_last_data_read => dbg_last_data_read,
            debug_last_opc_pc => dbg_last_opc_pc,
            debug_getbrief => dbg_getbrief,
            debug_get_2ndopc => dbg_get_2ndopc,
            debug_direct_data => dbg_direct_data,
            debug_fline_brief_pending => dbg_fline_brief_pending,
            debug_fline_context_valid => dbg_fline_context_valid,
            debug_fline_opcode_pc => dbg_fline_opcode_pc,
            debug_TG68_PC => dbg_pc,
            debug_exe_PC => dbg_exe_pc,
            debug_memaddr_reg => dbg_memaddr_reg,
            debug_memaddr_delta => dbg_memaddr_delta,
            debug_memaddr_delta_rega => dbg_memaddr_delta_rega,
            debug_memaddr_delta_regb => dbg_memaddr_delta_regb,
            debug_addsub_q => dbg_addsub_q,
            debug_memmaskmux => dbg_memmaskmux,
            debug_fline_opcode_latch => dbg_fline_opcode_latch,
            debug_pmmu_ea_mode_latched => dbg_pmmu_ea_mode_latched,
            debug_pmmu_brief => dbg_pmmu_brief,
            debug_exec_direct_delta => dbg_exec_direct_delta,
            debug_exec_directPC => dbg_exec_directPC,
            debug_exec_mem_addsub => dbg_exec_mem_addsub,
            debug_set_addrlong => dbg_set_addrlong,
            debug_mdelta_src => dbg_mdelta_src,
            debug_pc_brw => dbg_pc_brw,
            debug_pc_word => dbg_pc_word,
            debug_oddout => open,
            debug_decodeOPC => open,
            debug_brief => dbg_brief,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw => open,
            debug_regfile_d0 => dbg_reg_d0,
            debug_regfile_d1 => dbg_reg_d1,
            debug_regfile_d2 => dbg_reg_d2,
            debug_regfile_d3 => dbg_reg_d3,
            debug_regfile_d4 => open,
            debug_regfile_d5 => open,
            debug_regfile_d6 => dbg_reg_d6,
            debug_regfile_d7 => open,
            debug_regfile_a0 => dbg_reg_a0,
            debug_regfile_a1 => dbg_reg_a1,
            debug_regfile_a2 => dbg_reg_a2,
            debug_regfile_a3 => dbg_reg_a3,
            debug_regfile_a4 => dbg_reg_a4,
            debug_regfile_a5 => dbg_reg_a5,
            debug_regfile_a6 => open,
            debug_regfile_a7 => dbg_reg_a7,
            debug_regfile_we => dbg_regfile_we,
            debug_regfile_waddr => dbg_regfile_waddr,
            debug_regfile_wdata => dbg_regfile_wdata,
            debug_trap_1111 => dbg_trap_1111,
            debug_trapmake => dbg_trapmake,
            debug_trap_illegal => dbg_trap_illegal,
            debug_trap_priv => dbg_trap_priv,
            debug_trap_addr_error => dbg_trap_addr_error,
            debug_trap_berr => dbg_trap_berr,
            debug_trap_mmu_berr => dbg_trap_mmu_berr,
            debug_trap_vector => dbg_trap_vector,
            debug_pc_add => dbg_pc_add,
            debug_pc_dataa => dbg_pc_dataa,
            debug_pc_datab => dbg_pc_datab,
            debug_use_base => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA => open,
            debug_pmmu_busy => open,
            debug_micro_state => dbg_micro_state,
            debug_next_micro_state => dbg_next_micro_state,
            debug_memmask => dbg_memmask,
            debug_sndOPC => dbg_sndopc,
            debug_pmmu_reg_we => open,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => dbg_pmmu_reg_rdat
        );

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when test_done = '0' else '0';

    -- Memory read (combinational)
    mem_read_proc: process(addr)
        variable mem_addr : integer;
    begin
        if addr(31 downto 17) = "000000000000000" then
            mem_addr := to_integer(unsigned(addr(16 downto 1)));
            data_in <= memory(mem_addr);
        else
            data_in <= x"4E71";
        end if;
    end process;

    -- Memory write (registered)
    mem_write_proc: process(clk)
        variable mem_addr : integer;
        variable old_val  : std_logic_vector(15 downto 0);
        variable new_val  : std_logic_vector(15 downto 0);
        variable l : line;
    begin
        if rising_edge(clk) then
            -- Debug: check write cycles for verification memory
            if busstate = "11" and addr >= x"00002800" and addr < x"00002900" then
                write(l, string'("WRCYC addr=$") & slv32_to_hex(addr) &
                      string'(" nWr=") & std_logic'image(nWr) &
                      string'(" PC=$") & slv32_to_hex(dbg_pc));
                writeline(output, l);
            end if;
            if busstate = "11" and nWr = '0' then
                if addr(31 downto 17) = "000000000000000" then
                    mem_addr := to_integer(unsigned(addr(16 downto 1)));
                    old_val := memory(mem_addr);
                    new_val := old_val;
                    if nUDS = '0' then
                        new_val(15 downto 8) := data_out(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        new_val(7 downto 0) := data_out(7 downto 0);
                    end if;
                    memory(mem_addr) := new_val;
                    -- Debug ALL writes
                    write(l, string'("WRITE addr=$") & slv32_to_hex(addr));
                    write(l, string'(" data=$") & slv16_to_hex(data_out));
                    write(l, string'(" new=$") & slv16_to_hex(new_val));
                    writeline(output, l);
                end if;
            end if;

            if busstate = "10" then
                if addr(31 downto 17) = "000000000000000" then
                    mem_addr := to_integer(unsigned(addr(16 downto 1)));
                    old_val := memory(mem_addr);
                    -- Debug output disabled for performance
                    -- write(l, string'("READ addr=$") & slv32_to_hex(addr));
                    -- write(l, string'(" data=$") & slv16_to_hex(data_in));
                    -- write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                    -- write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                    -- write(l, string'(" ST=$") & slv16_to_hex("00000000000000" & dbg_state));
                    -- writeline(output, l);
                end if;
            end if;
        end if;
    end process;

    -- PMMU walker handshake: serve page table data from shared memory
    walker_proc: process(clk)
        variable word_hi : integer;
        variable l : line;
    begin
        if rising_edge(clk) then
            pmmu_walker_ack <= '0';
            pmmu_walker_data <= x"00000000";
            if pmmu_walker_req = '1' and pmmu_walker_we = '0' then
                -- Read 32-bit word from shared memory (big-endian)
                word_hi := to_integer(unsigned(pmmu_walker_addr(16 downto 1)));
                if word_hi < 65535 then
                    pmmu_walker_data <= memory(word_hi) & memory(word_hi + 1);
                end if;
                pmmu_walker_ack <= '1';
                -- synthesis translate_off
                write(l, string'("WALKER_RD addr=$") & slv32_to_hex(pmmu_walker_addr) &
                      string'(" data=$") & slv16_to_hex(memory(word_hi)) & slv16_to_hex(memory(word_hi + 1)));
                writeline(output, l);
                -- synthesis translate_on
            elsif pmmu_walker_req = '1' and pmmu_walker_we = '1' then
                -- U/M bit update write - just ack it
                pmmu_walker_ack <= '1';
            end if;
        end if;
    end process;

    -- MMUSR capture monitor: detects PTEST completion and writes MMUSR to verification memory
    -- PTEST completes when micro_state transitions from ptest1 (90) to pmmu_dn_read_wait (96)
    -- Capture is delayed by several cycles because PMMU updates MMUSR asynchronously:
    --   busy drops (combinational) -> ptest_update_mmusr (registered) -> MMUSR write (registered)
    mmusr_capture_proc: process(clk)
        variable prev_micro : integer := 0;
        variable capture_countdown : integer := 0;
        variable l : line;
        constant PTEST1_POS : integer := micro_states'pos(ptest1);
        constant PMMU_DN_WAIT_POS : integer := micro_states'pos(pmmu_dn_read_wait);
    begin
        if rising_edge(clk) then
            -- Countdown-based capture: wait N cycles after PTEST completion for MMUSR to stabilize
            if capture_countdown > 0 then
                capture_countdown := capture_countdown - 1;
                if capture_countdown = 0 then
                    if mmusr_capture_idx < mmusr_dst_count then
                        memory(mmusr_dst_addrs(mmusr_capture_idx) / 2) :=
                            dbg_pmmu_reg_rdat(15 downto 0);
                        write(l, string'("MMUSR_CAPTURE[") & integer'image(mmusr_capture_idx) &
                              string'("]: addr=$") &
                              slv32_to_hex(std_logic_vector(to_unsigned(mmusr_dst_addrs(mmusr_capture_idx), 32))) &
                              string'(" mmusr=$") & slv16_to_hex(dbg_pmmu_reg_rdat(15 downto 0)));
                        writeline(output, l);
                        mmusr_capture_idx <= mmusr_capture_idx + 1;
                    end if;
                end if;
            end if;

            -- Detect PTEST completion: ptest1 -> pmmu_dn_read_wait
            -- Guard: ignore transitions during reset (nReset='0') to prevent false captures
            -- from undefined micro_state values during initialization
            if nReset = '1' and prev_micro = PTEST1_POS and dbg_micro_state = PMMU_DN_WAIT_POS then
                capture_countdown := 20;  -- Wait for MMUSR to be updated (PTEST walker may still be running)
            end if;
            prev_micro := dbg_micro_state;
        end if;
    end process;

    -- Instruction fetch trace
    trace_proc: process(clk)
        variable l : line;
        variable opc : std_logic_vector(15 downto 0);
        variable ext : std_logic_vector(15 downto 0);
        variable pc_int : integer;
        variable pc_exec : std_logic_vector(31 downto 0);
        variable pc_exec_clean : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) and nReset = '1' and test_done = '0' then
            if dbg_trapmake = '1' then
                write(l, string'("TRAP  trapmake=1"));
                if dbg_trap_1111 = '1' then write(l, string'(" fline=1")); end if;
                if dbg_trap_illegal = '1' then write(l, string'(" illegal=1")); end if;
                if dbg_trap_priv = '1' then write(l, string'(" priv=1")); end if;
                if dbg_trap_addr_error = '1' then write(l, string'(" addrerr=1")); end if;
                if dbg_trap_berr = '1' then write(l, string'(" berr=1")); end if;
                if dbg_trap_mmu_berr = '1' then write(l, string'(" mmu_berr=1")); end if;
                write(l, string'(" vec=$") & slv32_to_hex(dbg_trap_vector));
                write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                write(l, string'(" MST=") & integer'image(dbg_micro_state));
                writeline(output, l);
            end if;

            if dbg_regfile_we = '1' and dbg_regfile_waddr = "1011" and dbg_pmmu_brief = x"9F75" then
                memory(PTEST_A_RESULT_ADDR / 2) := dbg_regfile_wdata(31 downto 16);
                memory(PTEST_A_RESULT_ADDR / 2 + 1) := dbg_regfile_wdata(15 downto 0);
            end if;

            if TRACE_FETCH and busstate = "00" then
                write(l, string'("FETCH PC=$") & slv32_to_hex(addr));
                write(l, string'(" OPC=$") & slv16_to_hex(data_in));
                write(l, string'(" D0=$") & slv32_to_hex(dbg_reg_d0));
                write(l, string'(" D3=$") & slv32_to_hex(dbg_reg_d3));
                write(l, string'(" D6=$") & slv32_to_hex(dbg_reg_d6));
                write(l, string'(" A0=$") & slv32_to_hex(dbg_reg_a0));
                write(l, string'(" A1=$") & slv32_to_hex(dbg_reg_a1));
                write(l, string'(" A2=$") & slv32_to_hex(dbg_reg_a2));
                write(l, string'(" A3=$") & slv32_to_hex(dbg_reg_a3));
                write(l, string'(" A4=$") & slv32_to_hex(dbg_reg_a4));
                write(l, string'(" A5=$") & slv32_to_hex(dbg_reg_a5));
                write(l, string'(" A7=$") & slv32_to_hex(dbg_reg_a7));
                write(l, string'(" KOPC=$") & slv16_to_hex(dbg_opcode));
                writeline(output, l);
            end if;

            if dbg_setopcode = '1' then
                if dbg_exe_pc = x"00000000" then
                    pc_exec := dbg_pc;
                else
                    pc_exec := dbg_exe_pc;
                end if;
                pc_exec_clean := clean_slv(pc_exec);
                if pc_exec_clean /= x"00000000" then
                    exec_pc <= pc_exec;
                    pc_int := to_integer(unsigned(pc_exec));
                    opc := mem_word(pc_int);
                    exec_seen <= '1';
                    exec_count_sig <= exec_count_sig + 1;
                    -- Show all instructions
                    write(l, string'("EXEC  PC=$") & slv32_to_hex(pc_exec));
                    write(l, string'(" ") & decode_exec_string(opc, pc_int, dbg_brief));
                    write(l, string'(" D3=$") & slv32_to_hex(dbg_reg_d3));
                    write(l, string'(" A2=$") & slv32_to_hex(dbg_reg_a2));
                    writeline(output, l);
                end if;
            end if;
        end if;
    end process;

    -- Fail fast if PC goes out of range
    watchdog_proc: process(clk)
        variable l : line;
    begin
        if rising_edge(clk) and nReset = '1' and test_done = '0' then
            if exec_seen = '1' then
                if has_x(exec_pc) then
                    bad_pc <= '1';
                elsif exec_pc(31 downto 16) /= x"0000" then
                    bad_pc <= '1';
                elsif to_integer(unsigned(exec_pc(15 downto 0))) > 16#8000# then
                    bad_pc <= '1';
                end if;
            end if;
            if bad_pc = '1' then
                write(l, string'("FAIL: PC out of range at $") & slv32_to_hex(exec_pc));
                writeline(output, l);
                test_done <= '1';
            end if;
        end if;
    end process;

    -- Main test process
    test_proc: process
        variable pc : integer;
        variable pc_dump : integer;
        variable opc_dump : std_logic_vector(15 downto 0);
        variable ext_dump : std_logic_vector(15 downto 0);
        variable len_dump : integer;
        variable l : line;
        variable tests : test_array;
        variable test_count : integer := 0;
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable actual : word_array := (others => (others => '0'));
        variable ok : boolean := true;
        variable handler_pc : integer;
        variable dst_addr_tmp : integer;
        variable exp_words_tmp : word_array := (others => (others => '0'));
        variable desc_str_tmp : string(1 to 80);

        variable dst_ptr : integer := 16#2800#;

        -- Helper to pad description
        procedure set_desc(variable dst : out string; src : string) is
            variable tmp : string(1 to 80) := (others => ' ');
        begin
            for i in 1 to src'length loop
                exit when i > 80;
                tmp(i) := src(i);
            end loop;
            dst := tmp;
        end procedure;

        procedure record_test(desc_in : string; dest_addr : integer; words : integer; exp : word_array) is
        begin
            set_desc(tests(test_count).desc, desc_in);
            tests(test_count).dest_addr := dest_addr;
            tests(test_count).words := words;
            tests(test_count).exp := exp;
            test_count := test_count + 1;
        end procedure;

        procedure alloc_dst(words : integer; addr_out : out integer) is
        begin
            addr_out := dst_ptr;
            dst_ptr := dst_ptr + (words * 2);
        end procedure;

        -- Emit PTEST + read MMUSR into D3 + store D3 to verification memory
        -- Records the test with expected MMUSR value
        procedure emit_ptest_verify_mmusr(
            desc : string;
            ea_mode : std_logic_vector(2 downto 0);
            ea_reg : std_logic_vector(2 downto 0);
            level : std_logic_vector(2 downto 0);
            rw : std_logic;
            a_bit : std_logic;
            a_reg : std_logic_vector(2 downto 0);
            fc_spec : std_logic_vector(4 downto 0);
            disp_or_addr : std_logic_vector(15 downto 0);
            addr_hi : std_logic_vector(15 downto 0);
            expected_mmusr : std_logic_vector(15 downto 0)
        ) is
            variable dst_addr : integer;
            variable exp_words : word_array := (others => (others => '0'));
            variable desc_str : string(1 to 80);
        begin
            -- Emit PTEST
            emit_ptest(pc, ea_mode, ea_reg, level, rw, a_bit, a_reg, fc_spec, disp_or_addr, addr_hi);
            -- Write MMUSR directly to verification memory via (xxx).W mode
            alloc_dst(1, dst_addr);
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "111", "000",
                        std_logic_vector(to_unsigned(dst_addr, 16)), x"0000");
            -- Record expected
            exp_words(0) := expected_mmusr;
            set_desc(desc_str, desc);
            record_test(desc_str, dst_addr, 1, exp_words);
        end procedure;


        -- Emit PFLUSHA + PLOAD + PTEST(A2) + verify MMUSR via debug port capture
        -- Pattern: PFLUSHA -> PLOAD(EA) -> reload A2 -> PTEST(A2) -> NOP (monitor captures MMUSR)
        procedure emit_pload_verify_mmusr(
            desc : string;
            ea_mode : std_logic_vector(2 downto 0);
            ea_reg : std_logic_vector(2 downto 0);
            rw : std_logic;
            fc_spec : std_logic_vector(4 downto 0);
            disp_or_addr : std_logic_vector(15 downto 0);
            addr_hi : std_logic_vector(15 downto 0);
            expected_mmusr : std_logic_vector(15 downto 0)
        ) is
            variable dst_addr : integer;
            variable exp_words : word_array := (others => (others => '0'));
            variable desc_str : string(1 to 80);
        begin
            -- PFLUSHA to clear ATC
            emit_pflusha(pc);
            -- PLOAD to load ATC entry via page table walk
            emit_pload(pc, ea_mode, ea_reg, rw, fc_spec, disp_or_addr, addr_hi);
            -- Reload A2 to target address for PTEST verification
            emit_movea(pc, 2, PLOAD_ADDR);
            -- PTEST (A2) to verify ATC was loaded
            emit_ptest(pc, "010", "010", "111", '1', '0', "000", "10101", x"0000", x"0000");
            -- Allocate verification slot; monitor process will fill it via debug port
            alloc_dst(1, dst_addr);
            mmusr_dst_addrs(mmusr_dst_count) := dst_addr;
            mmusr_dst_count := mmusr_dst_count + 1;
            -- NOP to give PTEST time to complete before next PFLUSHA
            emit_word(pc, x"4E71");
            emit_word(pc, x"4E71");
            -- Record expected
            exp_words(0) := expected_mmusr;
            set_desc(desc_str, desc);
            record_test(desc_str, dst_addr, 1, exp_words);
        end procedure;

        -- Variables for setup addresses
        variable crp_addr : integer;
        variable tc_addr : integer;
        variable zero_addr : integer;

    begin
        -- Initialize vectors
        memory(0) := x"0000"; memory(1) := x"2F00";   -- SSP at $2F00
        memory(2) := x"0000"; memory(3) := x"0400";   -- PC -> $0400
        memory(4) := x"0000"; memory(5) := x"0100";   -- Bus Error vector
        memory(6) := x"0000"; memory(7) := x"0110";   -- Address Error
        memory(8) := x"0000"; memory(9) := x"0120";   -- Illegal Instruction
        memory(10) := x"0000"; memory(11):= x"0130";  -- Div-by-Zero
        memory(16) := x"0000"; memory(17):= x"0140";  -- Privilege Violation
        memory(22) := x"0000"; memory(23):= x"0190";  -- F-line ($2C)
        memory(28) := x"0000"; memory(29):= x"0150";  -- Format Error
        memory(112):= x"0000"; memory(113):= x"0160"; -- MMU Config

        -- Exception handlers (STOP #$27xx)
        memory(16#100#/2) := x"4E72"; memory(16#102#/2) := x"2700"; -- Bus Error
        memory(16#110#/2) := x"4E72"; memory(16#112#/2) := x"2701"; -- Address Error
        memory(16#120#/2) := x"4E72"; memory(16#122#/2) := x"2702"; -- Illegal
        memory(16#130#/2) := x"4E72"; memory(16#132#/2) := x"2703"; -- DivZero
        memory(16#140#/2) := x"4E72"; memory(16#142#/2) := x"2704"; -- Priv
        memory(16#150#/2) := x"4E72"; memory(16#152#/2) := x"2705"; -- Format
        memory(16#160#/2) := x"4E72"; memory(16#162#/2) := x"2706"; -- MMU Config
        handler_pc := 16#0190#;
        emit_move_l_an_to_abs(handler_pc, 3, std_logic_vector(to_unsigned(FLINE_RESERVED_RESULT_ADDR, 32)));
        emit_moveq(handler_pc, 3, 11);
        emit_move_w_dn_to_abs(handler_pc, 3, std_logic_vector(to_unsigned(FLINE_RESERVED_RESULT_ADDR + 4, 32)));
        emit_word(handler_pc, x"4E72"); emit_word(handler_pc, x"2709"); -- F-line

        -- Clear code area
        for i in 16#1000# to 16#27FF# loop
            memory(i) := x"0000";
        end loop;
        -- Pre-fill destination area with $DEAD sentinel
        for i in 16#2800# to 16#2FFF# loop
            memory(i) := x"DEAD";
        end loop;

        -- =====================================================
        -- Page Table Setup (in shared memory for walker)
        -- =====================================================
        -- TC: E=1, PS=12(4K pages), IS=0, TIA=10, TIB=10
        --   $80C0AA00
        -- VA $00001000 decomposition:
        --   Root index = VA[31:22] = 0
        --   L2 index   = VA[21:12] = 1
        --   Page offset = VA[11:0]  = $000
        --
        -- Root table at $4000 (1024 entries, 4 bytes each):
        --   Entry 0: short table descriptor -> L2 at $5000
        --            $00005002 (addr=$5000, DT=10)
        --
        -- L2 table at $5000 (1024 entries, 4 bytes each):
        --   Entry 0 at $5000: page $0000 (code/vectors) $00000001
        --   Entry 1 at $5004: page $1000 (PLOAD target) $00001001
        --   Entry 2 at $5008: page $2000 (stack/data)   $00002001
        -- =====================================================

        -- Root table: entry 0 -> L2 table at $5000
        write_long(ROOT_TABLE, x"00005002");

        -- L2 table entries (identity-mapped pages)
        write_long(L2_TABLE,     x"00000001");  -- Entry 0: $0000-$0FFF (code, vectors)
        write_long(L2_TABLE + 4, x"00001001");  -- Entry 1: $1000-$1FFF (PLOAD target)
        write_long(L2_TABLE + 8, x"00002001");  -- Entry 2: $2000-$2FFF (stack, data)

        -- CRP data at $2400 (64-bit: HI then LO)
        crp_addr := 16#2400#;
        write_long(crp_addr,     VAL_CRP_HI);   -- $00000002
        write_long(crp_addr + 4, VAL_CRP_LO);   -- $00004000

        -- TC data at $2408
        tc_addr := 16#2408#;
        write_long(tc_addr, VAL_TC_PLOAD);       -- $80C0AA00

        -- Zero data at $2410 (for disabling MMU)
        zero_addr := 16#2410#;
        write_long(zero_addr, x"00000000");

        -- TT0 data at $2418: transparent for FC=6 (supervisor program fetches)
        -- This makes instruction fetches bypass page table walks.
        -- Only data accesses (FC=5, used by PLOAD/PTEST) hit the page tables.
        -- TT0 = $00FF8160:
        --   Bits 31:24 = $00 (address base - match any high byte)
        --   Bits 23:16 = $FF (address mask - ignore all address bits)
        --   Bit 15 = 1 (E=enabled)
        --   Bits 14:11 = 0000 (reserved)
        --   Bit 10 = 0 (CI=0, no cache inhibit)
        --   Bit 9 = 0 (R/W=read)
        --   Bit 8 = 1 (RWM=1, match both reads and writes)
        --   Bit 7 = 0 (reserved)
        --   Bits 6:4 = 110 (FC base=6, supervisor program)
        --   Bit 3 = 0 (reserved)
        --   Bits 2:0 = 000 (FC mask=exact match)
        -- Result: matches FC=6 only (instruction fetches in supervisor mode)
        write_long(16#2418#, x"00FF8160");

        -- Program starts at $0400
        pc := 16#0400#;

        -- Set D0 = 5 (FC value for supervisor data)
        emit_moveq(pc, 0, 5);
        -- Set D6 = 4 (index register for d8,An,Xn mode)
        emit_moveq(pc, 6, 4);

        -- Set SFC = 5 (for FC=SFC tests)
        emit_movec_dn_to_ctrl(pc, 0, 0);   -- MOVEC D0,SFC
        -- Set DFC = 5 (for FC=DFC tests)
        emit_movec_dn_to_ctrl(pc, 0, 1);   -- MOVEC D0,DFC

        -- =====================================================
        -- Phase 1: Configure CRP and enable TC
        -- =====================================================

        -- PMOVE (A0),CRP - load CRP (64-bit). WinUAE rejects (An)+ for
        -- MC68030 MMU effective addresses, so the setup path must use (An).
        emit_movea(pc, 0, std_logic_vector(to_unsigned(crp_addr, 32)));
        emit_pmove(pc, REG_CRP, DIR_MEM_TO_MMU, "010", "000", x"0000", x"0000");

        -- Enable TT0: transparent for FC=6 (supervisor program fetches)
        -- This prevents instruction fetches from triggering page table walks
        emit_movea(pc, 0, std_logic_vector(to_unsigned(16#2418#, 32)));
        emit_pmove(pc, REG_TT0, DIR_MEM_TO_MMU, "010", "000", x"0000", x"0000");

        -- Set up registers BEFORE enabling MMU
        emit_movea(pc, 2, PLOAD_ADDR);  -- A2 = $1000 (target address)
        emit_movea(pc, 5, std_logic_vector(to_unsigned(zero_addr, 32)));  -- A5 = zero addr

        -- Enable TC - MMU is now active!
        -- Instruction fetches are transparent (TT0/FC=6), data accesses use page tables
        emit_movea(pc, 0, std_logic_vector(to_unsigned(tc_addr, 32)));
        emit_pmove(pc, REG_TC, DIR_MEM_TO_MMU, "010", "000", x"0000", x"0000");

        -- =====================================================
        -- Phase 2: PLOAD tests
        -- Pattern: PFLUSHA -> PLOAD(EA) -> reload A2 -> PTEST(A2) -> read MMUSR -> store
        -- Expected MMUSR after successful PLOAD+PTEST: $0003
        -- (W=0, I=0, M=0, T=0, N=3 from 2-level page table walk)
        -- =====================================================

        -- Test 1: PLOADR (A2), FC=imm 5 (supervisor data)
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADR (A2), FC=imm5",
            "010", "010", '1', "10101", x"0000", x"0000", x"0002");

        -- Test 2: PLOADR (d16,A2), FC=imm 5
        -- d16=$0010, so A2 = $1000 - $10 = $0FF0
        emit_movea(pc, 2, std_logic_vector(unsigned(PLOAD_ADDR) - 16));
        emit_pload_verify_mmusr(
            "PLOADR (d16,A2), FC=imm5",
            "101", "010", '1', "10101", x"0010", x"0000", x"0002");

        -- Test 3: PLOADR (d8,A2,D6.W), FC=imm 5
        -- D6=4, brief=$6002 -> D6.W*1 + disp=2 -> offset=6
        -- A2 = $1000 - 6 = $0FFA
        emit_movea(pc, 2, std_logic_vector(unsigned(PLOAD_ADDR) - 6));
        emit_pload_verify_mmusr(
            "PLOADR (d8,A2,D6.W), FC=imm5",
            "110", "010", '1', "10101", x"6002", x"0000", x"0002");

        -- Test 4: PLOADR (xxx).W, FC=imm 5
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADR (xxx).W=$1000, FC=imm5",
            "111", "000", '1', "10101", PLOAD_ADDR(15 downto 0), x"0000", x"0002");

        -- Test 5: PLOADR (xxx).L, FC=imm 5
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADR (xxx).L=$1000, FC=imm5",
            "111", "001", '1', "10101",
            PLOAD_ADDR(15 downto 0), PLOAD_ADDR(31 downto 16), x"0002");

        -- Test 6: PLOADW (A2), FC=imm 5 (write variant)
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADW (A2), FC=imm5",
            "010", "010", '0', "10101", x"0000", x"0000", x"0202");

        -- Test 7: PLOADR (A2), FC=SFC (SFC=5)
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADR (A2), FC=SFC",
            "010", "010", '1', "00000", x"0000", x"0000", x"0002");

        -- Test 8: PLOADR (A2), FC=D0 (D0=5)
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADR (A2), FC=D0",
            "010", "010", '1', "01000", x"0000", x"0000", x"0002");

        -- =====================================================
        -- A7/SP MODE TESTS - WhichAmiga compatibility
        -- =====================================================

        -- Test 9: PLOADR (A7), FC=imm 5 (stack pointer)
        emit_movea(pc, 7, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADR (A7), FC=imm5",
            "010", "111", '1', "10101", x"0000", x"0000", x"0002");

        -- Test 10: PLOADR (d16,A7), FC=imm 5
        -- d16=$0010, so A7 = $1000 - $10 = $0FF0
        emit_movea(pc, 7, std_logic_vector(unsigned(PLOAD_ADDR) - 16));
        emit_pload_verify_mmusr(
            "PLOADR (d16,A7), FC=imm5",
            "101", "111", '1', "10101", x"0010", x"0000", x"0002");

        -- Test 11: PLOADW (A7), FC=imm 5 (write variant with A7)
        emit_movea(pc, 7, PLOAD_ADDR);
        emit_pload_verify_mmusr(
            "PLOADW (A7), FC=imm5",
            "010", "111", '0', "10101", x"0000", x"0000", x"0202");

        -- Test 12: PTESTR with A=1 returns the final descriptor address in A3.
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_ptest(pc, "010", "010", "111", '1', '1', "011", "10101", x"0000", x"0000");
        -- Store/handler checks below are ordinary physical-memory checks. Disable
        -- translation after the PTEST result has been written to A3 so verification
        -- is not hidden behind a second translated data write.
        emit_pmove(pc, REG_TC, DIR_MEM_TO_MMU, "010", "101", x"0000", x"0000");
        exp_words_tmp := (others => (others => '0'));
        exp_words_tmp(0) := PTEST_A_DESC_ADDR(31 downto 16);
        exp_words_tmp(1) := PTEST_A_DESC_ADDR(15 downto 0);
        set_desc(desc_str_tmp, "PTESTR (A2), A=1 A3 returns final descriptor address");
        record_test(desc_str_tmp, PTEST_A_RESULT_ADDR, 2, exp_words_tmp);

        -- Test 13: PLOAD has no A/register-return field. Bits 8:5 are reserved
        -- and must take vector 11 without corrupting the would-be A-register.
        emit_movea(pc, 2, PLOAD_ADDR);
        emit_movea(pc, 3, x"DEADBEEF");
        emit_pload_reserved(pc, "010", "010", '1', "1011", "10101", x"0000", x"0000");
        exp_words_tmp := (others => (others => '0'));
        exp_words_tmp(0) := x"DEAD";
        exp_words_tmp(1) := x"BEEF";
        exp_words_tmp(2) := x"000B";
        set_desc(desc_str_tmp, "PLOADR reserved bits 8:5 trap via vector 11 and preserve A3");
        record_test(desc_str_tmp, FLINE_RESERVED_RESULT_ADDR, 3, exp_words_tmp);

        -- =====================================================
        -- Phase 3: Disable MMU
        -- =====================================================
        -- Use A5 (stable, never modified) pointing to zero
        emit_pmove(pc, REG_TC, DIR_MEM_TO_MMU, "010", "101", x"0000", x"0000");   -- TC=0
        emit_pmove(pc, REG_TT0, DIR_MEM_TO_MMU, "010", "101", x"0000", x"0000");  -- TT0=0

        -- STOP
        emit_word(pc, x"4E72");
        emit_word(pc, x"2700");

        -- Print ROM decode
        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("PLOAD ALL MODES TEST"));
        writeline(output, l);
        write(l, string'("Tests: (A2), (d16,A2), (d8,A2,D6), (xxx).W, (xxx).L, PLOADW, FC=SFC, FC=D0"));
        writeline(output, l);
        write(l, string'("Verification: PFLUSHA + PLOAD + PTEST(A2) -> check MMUSR"));
        writeline(output, l);
        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("ROM DECODE (from $0400):"));
        writeline(output, l);
        pc_dump := 16#0400#;
        while pc_dump < pc loop
            opc_dump := mem_word(pc_dump);
            ext_dump := mem_word(pc_dump + 2);
            len_dump := instr_len(opc_dump, pc_dump, ext_dump);
            if len_dump <= 0 then
                len_dump := 2;
            end if;
            write(l, string'("ROM $") & slv32_to_hex(std_logic_vector(to_unsigned(pc_dump, 32))));
            write(l, string'(": "));
            write(l, decode_exec_string(opc_dump, pc_dump, ext_dump));
            write(l, string'(" LEN=") & integer'image(len_dump));
            write(l, string'(" OPC=$") & slv16_to_hex(opc_dump));
            write(l, string'(" WORDS=") & words_at_pc_to_hex(pc_dump, len_dump / 2));
            writeline(output, l);
            pc_dump := pc_dump + len_dump;
        end loop;

        -- Release reset
        wait for 100 ns;
        nReset <= '1';

        -- Run simulation (longer time for page table walks and end-of-program trap tests)
        wait for 30 us;
        if exec_seen = '0' then
            write(l, string'("FAIL: No EXEC observed"));
            writeline(output, l);
            fail_count := fail_count + 1;
        end if;
        test_done <= '1';

        -- Check results
        if bad_pc = '1' then
            write(l, string'("ABORT: bad PC detected; skipping verification"));
            writeline(output, l);
            fail_count := fail_count + 1;
        else
            for i in 0 to test_count-1 loop
                actual := (others => (others => '0'));
                ok := true;
                for j in 0 to tests(i).words-1 loop
                    actual(j) := memory((tests(i).dest_addr/2) + j);
                    if actual(j) /= tests(i).exp(j) then
                        ok := false;
                    end if;
                end loop;
                if ok then
                    pass_count := pass_count + 1;
                    if VERBOSE then
                        write(l, string'("TEST ") & integer'image(i) & string'(": ") & tests(i).desc);
                        writeline(output, l);
                        write(l, string'("  Expected: ") & words_to_hex(tests(i).exp, tests(i).words));
                        writeline(output, l);
                        write(l, string'("  Actual  : ") & words_to_hex(actual, tests(i).words));
                        writeline(output, l);
                        write(l, string'("  RESULT  : PASS"));
                        writeline(output, l);
                        write(l, string'(""));
                        writeline(output, l);
                    end if;
                else
                    fail_count := fail_count + 1;
                    write(l, string'("FAIL ") & integer'image(i) & string'(": ") & tests(i).desc);
                    writeline(output, l);
                    write(l, string'("  Expected: ") & words_to_hex(tests(i).exp, tests(i).words));
                    writeline(output, l);
                    write(l, string'("  Actual  : ") & words_to_hex(actual, tests(i).words));
                    writeline(output, l);
                    write(l, string'(""));
                    writeline(output, l);
                end if;
            end loop;
        end if;

        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("PLOAD ALL MODES SUMMARY"));
        writeline(output, l);
        write(l, string'("Total : ") & integer'image(test_count));
        writeline(output, l);
        write(l, string'("Passed: ") & integer'image(pass_count));
        writeline(output, l);
        write(l, string'("Failed: ") & integer'image(fail_count));
        writeline(output, l);
        write(l, string'("=============================================="));
        writeline(output, l);

        wait;
    end process;

end behavioral;
