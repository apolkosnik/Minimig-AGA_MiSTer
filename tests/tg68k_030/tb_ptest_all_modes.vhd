-- tb_ptest_all_modes.vhd
-- Comprehensive PTEST testbench (all EA modes, FC specs, R/W, levels, A-bit)
-- Uses same dynamic ROM pattern as tb_pmove_all_modes.vhd
-- Verifies MMUSR result and optional A-bit register writeback

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_ptest_all_modes is
end entity;

architecture behavioral of tb_ptest_all_modes is

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

    -- Memory: 64K words (128KB)
    type mem_array is array (0 to 65535) of std_logic_vector(15 downto 0);
    shared variable memory : mem_array := (others => x"4E71");

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

    -- PTEST test address (logical address to test)
    constant PTEST_ADDR : std_logic_vector(31 downto 0) := x"00001000";

    -- TT0 configured to match ALL addresses (transparent translation)
    -- Base=$00, Mask=$FF (all don't-care), E=1, CI=0, RWM=1, FC Base=000, FC Mask=111
    constant VAL_TT0_PTEST : std_logic_vector(31 downto 0) := x"00FF8107";

    -- TC with MMU enabled: E=1, PS=12, IS=0, TIA=8, TIB=7, TIC=5, TID=0
    constant VAL_TC_PTEST  : std_logic_vector(31 downto 0) := x"80C08750";

    -- Expected MMUSR after PTEST with TT0 match: T=1 (bit 6) = $0040
    constant VAL_MMUSR_EXPECTED : std_logic_vector(15 downto 0) := x"0040";
    constant VAL_A3_SENTINEL    : std_logic_vector(31 downto 0) := x"DEADBEEF";
    constant FLINE_A3_DST_ADDR  : integer := 16#2FF8#;
    constant FLINE_TAG_DST_ADDR : integer := 16#2FFC#;

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
            debug_pmmu_reg_part => open
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
                    write(l, string'("WRITE addr=$") & slv32_to_hex(addr));
                    write(l, string'(" data=$") & slv16_to_hex(data_out));
                    write(l, string'(" old=$") & slv16_to_hex(old_val));
                    write(l, string'(" new=$") & slv16_to_hex(new_val));
                    write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                    write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                    write(l, string'(" BRF=$") & slv16_to_hex(dbg_brief));
                    write(l, string'(" PBR=$") & slv16_to_hex(dbg_pmmu_brief));
                    write(l, string'(" ST=$") & slv16_to_hex("00000000000000" & dbg_state));
                    writeline(output, l);
                end if;
            end if;

            if busstate = "10" then
                if addr(31 downto 17) = "000000000000000" then
                    mem_addr := to_integer(unsigned(addr(16 downto 1)));
                    old_val := memory(mem_addr);
                    write(l, string'("READ addr=$") & slv32_to_hex(addr));
                    write(l, string'(" data=$") & slv16_to_hex(data_in));
                    write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                    write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                    write(l, string'(" ST=$") & slv16_to_hex("00000000000000" & dbg_state));
                    writeline(output, l);
                end if;
            end if;
        end if;
    end process;

    -- PMMU walker handshake (always ack with zeros - not used for TTR-based PTEST)
    walker_proc: process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' then
                pmmu_walker_ack <= '1';
                pmmu_walker_data <= x"00000000";
            else
                pmmu_walker_ack <= '0';
            end if;
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
                    write(l, string'("EXEC  PC=$") & slv32_to_hex(pc_exec));
                    write(l, string'(" ") & decode_exec_string(opc, pc_int, dbg_brief));
                    write(l, string'(" D0=$") & slv32_to_hex(dbg_reg_d0));
                    write(l, string'(" D3=$") & slv32_to_hex(dbg_reg_d3));
                    write(l, string'(" A2=$") & slv32_to_hex(dbg_reg_a2));
                    write(l, string'(" A3=$") & slv32_to_hex(dbg_reg_a3));
                    write(l, string'(" A4=$") & slv32_to_hex(dbg_reg_a4));
                    write(l, string'(" MST=") & integer'image(dbg_micro_state));
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

        -- Emit PTEST + read MMUSR directly to verification memory
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
            alloc_dst(1, dst_addr);
            -- Emit PTEST
            emit_ptest(pc, ea_mode, ea_reg, level, rw, a_bit, a_reg, fc_spec, disp_or_addr, addr_hi);
            -- Read MMUSR through a WinUAE-valid MC68030 MMU EA.
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "111", "001",
                       std_logic_vector(to_unsigned(dst_addr, 16)),
                       std_logic_vector(to_unsigned(dst_addr / 65536, 16)));
            -- Record expected
            exp_words(0) := expected_mmusr;
            set_desc(desc_str, desc);
            record_test(desc_str, dst_addr, 1, exp_words);
        end procedure;

        -- Variables for memory pre-load addresses
        variable tt0_addr : integer;
        variable tc_addr : integer;
        variable zero_addr : integer;
        variable dst_addr_tmp : integer;
        variable handler_pc : integer;
        variable exp_words_tmp : word_array := (others => (others => '0'));
        variable desc_str_tmp : string(1 to 80);

    begin
        -- Initialize vectors
        memory(0) := x"0000"; memory(1) := x"2000";   -- SSP
        memory(2) := x"0000"; memory(3) := x"0400";   -- PC -> $0400
        memory(4) := x"0000"; memory(5) := x"0100";   -- Bus Error
        memory(6) := x"0000"; memory(7) := x"0110";   -- Address Error
        memory(8) := x"0000"; memory(9) := x"0120";   -- Illegal Instruction
        memory(10) := x"0000"; memory(11):= x"0130";  -- Div-by-Zero
        memory(16) := x"0000"; memory(17):= x"0140";  -- Privilege Violation
        memory(22) := x"0000"; memory(23):= x"0170";  -- F-line
        memory(28) := x"0000"; memory(29):= x"0150";  -- Format Error
        memory(112):= x"0000"; memory(113):= x"0160"; -- MMU Config

        -- Exception handlers (STOP #$2700 + ID)
        memory(16#100#/2) := x"4E72"; memory(16#102#/2) := x"2700"; -- Bus Error
        memory(16#110#/2) := x"4E72"; memory(16#112#/2) := x"2701"; -- Address Error
        memory(16#120#/2) := x"4E72"; memory(16#122#/2) := x"2702"; -- Illegal
        memory(16#130#/2) := x"4E72"; memory(16#132#/2) := x"2703"; -- DivZero
        memory(16#140#/2) := x"4E72"; memory(16#142#/2) := x"2704"; -- Priv
        memory(16#150#/2) := x"4E72"; memory(16#152#/2) := x"2705"; -- Format
        memory(16#160#/2) := x"4E72"; memory(16#162#/2) := x"2706"; -- MMU Config

        -- Clear code area
        for i in 16#1000# to 16#27FF# loop
            memory(i) := x"0000";
        end loop;
        -- Pre-fill destination area with $DEAD sentinel
        for i in 16#2800# to 16#2FFF# loop
            memory(i) := x"DEAD";
        end loop;

        -- F-line handler for the illegal PTEST level=0/A=1 form. It records
        -- whether A3 was preserved, then stops the CPU so the testbench can
        -- verify that vector 11 was actually taken.
        handler_pc := 16#0170#;
        emit_move_l_an_to_abs(handler_pc, 3, std_logic_vector(to_unsigned(FLINE_A3_DST_ADDR, 32)));
        emit_moveq(handler_pc, 3, 11);
        emit_move_w_dn_to_abs(handler_pc, 3, std_logic_vector(to_unsigned(FLINE_TAG_DST_ADDR, 32)));
        emit_word(handler_pc, x"4E72");
        emit_word(handler_pc, x"2707");

        -- Allocate memory for TT0, TC, and zero values
        tt0_addr := 16#2400#;
        write_long(tt0_addr, VAL_TT0_PTEST);
        tc_addr := 16#2408#;
        write_long(tc_addr, VAL_TC_PTEST);
        zero_addr := 16#2410#;
        write_long(zero_addr, x"00000000");

        -- Program starts at $0400
        pc := 16#0400#;

        -- Set D6 = 4 for (d8,An,Xn) index
        emit_moveq(pc, 6, 4);

        -- =====================================================
        -- Phase 1: Enable TT0 and TC for transparent translation
        -- Pre-load all address registers BEFORE enabling MMU
        -- =====================================================

        -- Load A1 = &TT0 value, enable TT0
        emit_movea(pc, 1, std_logic_vector(to_unsigned(tt0_addr, 32)));
        emit_pmove(pc, REG_TT0, DIR_MEM_TO_MMU, "010", "001", x"0000", x"0000");

        -- Set up registers for MMU-active period:
        -- A0 = scratch (for address register pre-loads during tests)
        -- A1 = zero_addr (for disabling MMU later)
        -- A2 = PTEST address ($1000)
        -- A3, A4 = $DEADBEEF (for A-bit verification / trap-preserve checks)
        -- A5 = zero_addr (stable backup for disable)
        -- D0 = 5 (for FC-from-Dn test)
        emit_movea(pc, 1, std_logic_vector(to_unsigned(zero_addr, 32)));
        emit_movea(pc, 2, PTEST_ADDR);
        emit_movea(pc, 3, VAL_A3_SENTINEL);
        emit_movea(pc, 4, VAL_A3_SENTINEL);
        emit_movea(pc, 5, std_logic_vector(to_unsigned(zero_addr, 32)));
        emit_moveq(pc, 0, 5);  -- D0 = 5 (supervisor data FC)

        -- Enable TC - MMU is now active
        emit_movea(pc, 0, std_logic_vector(to_unsigned(tc_addr, 32)));
        emit_pmove(pc, REG_TC, DIR_MEM_TO_MMU, "010", "000", x"0000", x"0000");

        -- =====================================================
        -- Phase 2: PTEST tests (MMU active, TT0 matches everything)
        -- After each PTEST, read MMUSR->D3 and store to memory
        -- =====================================================

        -- Test 1: PTESTR (A2), level=7, imm FC=5 (supervisor data)
        emit_movea(pc, 2, PTEST_ADDR);
        emit_ptest_verify_mmusr(
            "PTESTR (A2), level=7, FC=5",
            "010", "010", "111", '1', '0', "000", "10101", x"0000", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Note: (An)+ and -(An) are ILLEGAL EA modes for PTEST (control modes only)

        -- Test 2: PTESTR (d16,A2), level=7, imm FC=5
        -- d16=$0010, so A2 = $1000 - $10 = $0FF0
        emit_movea(pc, 2, std_logic_vector(unsigned(PTEST_ADDR) - 16));
        emit_ptest_verify_mmusr(
            "PTESTR (d16,A2), level=7, FC=5",
            "101", "010", "111", '1', '0', "000", "10101", x"0010", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 3: PTESTR (d8,A2,D6.W), level=7, imm FC=5
        -- D6=4, brief=$6002 -> D6.W scale=1 disp=2 -> EA = A2 + 4 + 2 = A2 + 6
        -- A2 = $1000 - 6 = $0FFA
        emit_movea(pc, 2, std_logic_vector(unsigned(PTEST_ADDR) - 6));
        emit_ptest_verify_mmusr(
            "PTESTR (d8,A2,D6.W), level=7, FC=5",
            "110", "010", "111", '1', '0', "000", "10101", x"6002", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 4: PTESTR (xxx).W, level=7, imm FC=5
        emit_ptest_verify_mmusr(
            "PTESTR (xxx).W=$1000, level=7, FC=5",
            "111", "000", "111", '1', '0', "000", "10101",
            PTEST_ADDR(15 downto 0), x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 5: PTESTR (xxx).L, level=7, imm FC=5
        emit_ptest_verify_mmusr(
            "PTESTR (xxx).L=$00001000, level=7, FC=5",
            "111", "001", "111", '1', '0', "000", "10101",
            PTEST_ADDR(15 downto 0), PTEST_ADDR(31 downto 16),
            VAL_MMUSR_EXPECTED);

        -- Test 6: PTESTW (A2), level=7, imm FC=5 (write test)
        emit_movea(pc, 2, PTEST_ADDR);
        emit_ptest_verify_mmusr(
            "PTESTW (A2), level=7, FC=5",
            "010", "010", "111", '0', '0', "000", "10101", x"0000", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 7: PTESTR (A2), level=0, imm FC=5
        emit_movea(pc, 2, PTEST_ADDR);
        emit_ptest_verify_mmusr(
            "PTESTR (A2), level=0, FC=5",
            "010", "010", "000", '1', '0', "000", "10101", x"0000", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 8: PTESTR (A2), level=3, imm FC=5
        emit_movea(pc, 2, PTEST_ADDR);
        emit_ptest_verify_mmusr(
            "PTESTR (A2), level=3, FC=5",
            "010", "010", "011", '1', '0', "000", "10101", x"0000", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 9: PTESTR (A2), level=7, FC from D0 (D0=5)
        -- FC spec = 01000 (Dn, reg=D0)
        emit_movea(pc, 2, PTEST_ADDR);
        emit_ptest_verify_mmusr(
            "PTESTR (A2), level=7, FC=D0 (D0=5)",
            "010", "010", "111", '1', '0', "000", "01000", x"0000", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 10: PTESTR (A2), A=1, A3 (physical address writeback)
        -- Verify MMUSR is correct when A-bit is set
        -- NOTE: A-bit register writeback (A3 := phys addr) is not yet fully implemented
        -- in the kernel. Only verifying MMUSR here.
        emit_movea(pc, 2, PTEST_ADDR);
        emit_ptest(pc, "010", "010", "111", '1', '1', "011", "10101", x"0000", x"0000");
        alloc_dst(1, dst_addr_tmp);
        emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "111", "001",
                   std_logic_vector(to_unsigned(dst_addr_tmp, 16)),
                   std_logic_vector(to_unsigned(dst_addr_tmp / 65536, 16)));
        exp_words_tmp := (others => (others => '0'));
        exp_words_tmp(0) := VAL_MMUSR_EXPECTED;
        set_desc(desc_str_tmp, "PTESTR (A2), A=1 A3, MMUSR");
        record_test(desc_str_tmp, dst_addr_tmp, 1, exp_words_tmp);

        -- Test 11: PTESTR (A2), A=1, A4 (physical address writeback)
        -- Same as above but with different A-register
        emit_movea(pc, 2, PTEST_ADDR);
        emit_ptest(pc, "010", "010", "111", '1', '1', "100", "10101", x"0000", x"0000");
        alloc_dst(1, dst_addr_tmp);
        emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "111", "001",
                   std_logic_vector(to_unsigned(dst_addr_tmp, 16)),
                   std_logic_vector(to_unsigned(dst_addr_tmp / 65536, 16)));
        exp_words_tmp := (others => (others => '0'));
        exp_words_tmp(0) := VAL_MMUSR_EXPECTED;
        set_desc(desc_str_tmp, "PTESTR (A2), A=1 A4, MMUSR");
        record_test(desc_str_tmp, dst_addr_tmp, 1, exp_words_tmp);

        -- =====================================================
        -- A7/SP MODE TESTS - WhichAmiga compatibility
        -- =====================================================

        -- Test 12: PTESTR (A7), level=7, imm FC=5
        -- Load A7 with PTEST_ADDR ($1000)
        emit_movea(pc, 7, PTEST_ADDR);
        emit_ptest_verify_mmusr(
            "PTESTR (A7), level=7, FC=5",
            "010", "111", "111", '1', '0', "000", "10101", x"0000", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 13: PTESTR (d16,A7), level=7, imm FC=5
        -- d16=$0010, so A7 = $1000 - $10 = $0FF0
        emit_movea(pc, 7, std_logic_vector(unsigned(PTEST_ADDR) - 16));
        emit_ptest_verify_mmusr(
            "PTESTR (d16,A7), level=7, FC=5",
            "101", "111", "111", '1', '0', "000", "10101", x"0010", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 14: PTESTW (A7), level=7, imm FC=5 (write test with A7)
        emit_movea(pc, 7, PTEST_ADDR);
        emit_ptest_verify_mmusr(
            "PTESTW (A7), level=7, FC=5",
            "010", "111", "111", '0', '0', "000", "10101", x"0000", x"0000",
            VAL_MMUSR_EXPECTED);

        -- Test 15: PTESTR (A2), level=0, A=1, A3
        -- MC68030/WinUAE treat this form as an unimplemented F-line instruction.
        -- The handler records A3 so the testbench can verify the trap was taken
        -- before any A-bit writeback retired.
        emit_movea(pc, 2, PTEST_ADDR);
        emit_movea(pc, 3, VAL_A3_SENTINEL);
        emit_ptest(pc, "010", "010", "000", '1', '1', "011", "10101", x"0000", x"0000");
        exp_words_tmp := (others => (others => '0'));
        exp_words_tmp(0) := VAL_A3_SENTINEL(31 downto 16);
        exp_words_tmp(1) := VAL_A3_SENTINEL(15 downto 0);
        exp_words_tmp(2) := x"000B";
        set_desc(desc_str_tmp, "PTESTR (A2), level=0, A=1 A3 traps via vector 11");
        record_test(desc_str_tmp, FLINE_A3_DST_ADDR, 3, exp_words_tmp);

        -- Print ROM decode
        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("PTEST ALL MODES TEST"));
        writeline(output, l);
        write(l, string'("Tests: (A2), (d16,A2), (d8,A2,D6), (xxx).W, (xxx).L, PTESTW, levels, FC, A-bit"));
        writeline(output, l);
        write(l, string'("Also: PTESTW, level=0/3, FC=D0, A-bit=A3/A4, level=0+A trap"));
        writeline(output, l);
        write(l, string'("Expected MMUSR=$0040 (T=1, transparent TT0 match)"));
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

        -- Run simulation
        wait for 15 us;
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
        write(l, string'("PTEST ALL MODES SUMMARY"));
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
