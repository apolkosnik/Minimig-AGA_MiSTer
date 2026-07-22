-- tb_moves_stress.vhd
-- MOVES stress suite: MOVES.B/W/L in both directions through every legal
-- addressing mode, with PER-BUS-CYCLE FUNCTION-CODE verification (SFC on
-- reads, DFC on writes, and the reversion of the FC on the immediately
-- following normal access), destination/source correctness incl. partial-
-- register and sign-extension semantics, pointer-update exactness for
-- (An)+/-(An), privilege enforcement, illegal-EA enforcement, CPU/MMU
-- register trash checks, and back-to-back interaction stress. An exotic
-- DFC=3 discipline makes any FC leak in the whole run countable: no
-- legitimate non-MOVES cycle may ever present FC=011.
-- Real TG68KdotC_Kernel + real TG68K_PMMU_030.
-- Uses memory data tables (no immediate-long sources to memory)
-- Prints per-test expected vs actual values to stdout

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_moves_stress is
end entity;

architecture behavioral of tb_moves_stress is

    

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
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);

    -- Debug register taps
    signal dbg_reg_d0 : std_logic_vector(31 downto 0);
    signal dbg_reg_d1 : std_logic_vector(31 downto 0);
    signal dbg_reg_d2 : std_logic_vector(31 downto 0);
    signal dbg_reg_d3 : std_logic_vector(31 downto 0);
    signal dbg_reg_d6 : std_logic_vector(31 downto 0);
    signal dbg_reg_a0 : std_logic_vector(31 downto 0);
    signal dbg_reg_a1 : std_logic_vector(31 downto 0);
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

    -- FC shadows: per-word FC of the LAST write into the dst window
    -- ($2800-$2FFF) and the LAST data read from the src window ($2400-$27FF).
    type fc_array is array (0 to 1023) of std_logic_vector(2 downto 0);
    shared variable fc_shadow_w : fc_array := (others => "111");
    shared variable fc_shadow_r : fc_array := (others => "111");
    -- Exotic-FC discipline counters
    signal fc3_write_count : integer := 0;  -- data writes with FC=011 (only MOVES/DFC=3 may)
    signal fc3_read_count  : integer := 0;  -- data reads  with FC=011 (never legal here)
    signal fc3_fetch_count : integer := 0;  -- fetches     with FC=011 (never legal)
    signal fc2_read_count  : integer := 0;  -- data reads  with FC=010 (only MOVES/SFC=2 may)

    -- Test control
    signal test_done : std_logic := '0';
    signal test_failures : integer := -1;

    constant CLK_PERIOD : time := 10 ns;

    -- PMOVE reg selectors (brief[14:10])
    constant REG_TT0   : std_logic_vector(4 downto 0) := "00010";  -- 2
    constant REG_TT1   : std_logic_vector(4 downto 0) := "00011";  -- 3
    constant REG_TC    : std_logic_vector(4 downto 0) := "10000";  -- 16
    constant REG_SRP   : std_logic_vector(4 downto 0) := "10010";  -- 18
    constant REG_CRP   : std_logic_vector(4 downto 0) := "10011";  -- 19
    constant REG_MMUSR : std_logic_vector(4 downto 0) := "11000";  -- 24

    constant DIR_MEM_TO_MMU : std_logic := '0';
    constant DIR_MMU_TO_MEM : std_logic := '1';

    -- Unique test values for SP/legal-memory EA tests
    -- TC: bit 31 (E) must be 0 to avoid enabling MMU, bits 30-26 RESERVED (must be 0)
    -- TC write mask: $83FFFFFF - bits 30-26 forced to 0 by hardware
    -- TT0/TT1 write mask: $FFFF8777 - bits 14-11, 7, 3 reserved (forced to 0)
    -- TT0/TT1: bit 15 (E) should be 0 to avoid enabling transparent translation
    -- CRP/SRP write masks: HI word bits 15-1 forced to 0, LO word bits 3-0 forced to 0
    -- CRP/SRP: DT field (bits 1:0 of HI word) must not be "00" to avoid config error
    constant VAL_TC      : std_logic_vector(31 downto 0) := x"02345678";  -- E=0, bits 30-26 clear
    constant VAL_TT0     : std_logic_vector(31 downto 0) := x"87650321";  -- E=0, bits 14-11,7,3 clear
    constant VAL_TT1     : std_logic_vector(31 downto 0) := x"A5A50252";  -- E=0, bits 14-11,7,3 clear
    constant VAL_CRP_HI  : std_logic_vector(31 downto 0) := x"11220001";  -- DT=01, bits 15-1 clear
    constant VAL_CRP_LO  : std_logic_vector(31 downto 0) := x"55667780";  -- Bits 3-0 clear
    constant VAL_SRP_HI  : std_logic_vector(31 downto 0) := x"99AA0002";  -- DT=10, bits 15-1 clear
    constant VAL_SRP_LO  : std_logic_vector(31 downto 0) := x"DDEEFF00";  -- Bits 3-0 already clear

    -- DIFFERENT values for memory mode tests (must differ from Dn values above
    -- so that false positives from prior Dn writes are caught)
    -- TC: bit 31 (E) must be 0 to avoid enabling MMU, bits 30-26 RESERVED (must be 0)
    -- TC write mask: $83FFFFFF - bits 30-26 forced to 0 by hardware
    -- TT0/TT1 write mask: $FFFF8777 - bits 14-11, 7, 3 reserved (forced to 0)
    -- TT0/TT1: bit 15 (E) should be 0 to avoid enabling transparent translation
    -- CRP/SRP write masks: HI word bits 15-1 forced to 0, LO word bits 3-0 forced to 0
    -- CRP/SRP: DT field (bits 1:0 of HI word) must not be "00" to avoid config error
    constant VAL_TC_MEM      : std_logic_vector(31 downto 0) := x"01234567";  -- Bits 30-26 clear
    constant VAL_TT0_MEM     : std_logic_vector(31 downto 0) := x"76540210";  -- Bits 14-11,7,3 clear
    constant VAL_TT1_MEM     : std_logic_vector(31 downto 0) := x"5A5A0252";  -- Bits 14-11,7,3 clear
    constant VAL_CRP_HI_MEM  : std_logic_vector(31 downto 0) := x"AABB0001";  -- DT=01, bits 15-1 clear
    constant VAL_CRP_LO_MEM  : std_logic_vector(31 downto 0) := x"EEFF1120";  -- Bits 3-0 clear
    constant VAL_SRP_HI_MEM  : std_logic_vector(31 downto 0) := x"33440002";  -- DT=10, bits 15-1 clear
    constant VAL_SRP_LO_MEM  : std_logic_vector(31 downto 0) := x"778899A0";  -- Bits 3-0 clear

    -- PTEST setup values for populating MMUSR with non-zero value
    -- TT0 configured to match ALL addresses (transparent translation)
    -- Base=$00, Mask=$FF (all don't-care), E=1, CI=0, RWM=1, FC Base=000, FC Mask=111
    constant VAL_TT0_PTEST   : std_logic_vector(31 downto 0) := x"00FF8107";
    -- TC with MMU enabled and valid config: E=1, PS=12, IS=0, TIA=8, TIB=7, TIC=5, TID=0
    -- Total = 12+0+8+7+5 = 32 (valid)
    constant VAL_TC_PTEST    : std_logic_vector(31 downto 0) := x"80C08750";
    -- Expected MMUSR after PTEST with TT0 match: T=1 (bit 6) = $0040
    constant VAL_MMUSR_EXPECTED : std_logic_vector(15 downto 0) := x"0040";
    -- Destination memory pre-filled with $DEAD to prove PMOVE actually writes

    -- Helper types for test records
    type word_array is array (0 to 3) of std_logic_vector(15 downto 0);
    type test_record is record
        desc      : string(1 to 80);
        dest_addr : integer;  -- byte address
        words     : integer;  -- number of 16-bit words to compare
        exp       : word_array;
    end record;

    constant MAX_TESTS : integer := 256;
    constant VERBOSE : boolean := true;  -- true: print all tests, false: only failures + summary
    constant TRACE_FETCH : boolean := true; -- print each fetched instruction with key regs
    type test_array is array (0 to MAX_TESTS-1) of test_record;
    type int_arr is array (0 to 63) of integer;
    type fc_exp_arr is array (0 to 63) of std_logic_vector(2 downto 0);

    -- Helper function: 16-bit hex string
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

    function pmove_reg_name(sel : integer) return string is
    begin
        case sel is
            when 2  => return "TT0";
            when 3  => return "TT1";
            when 16 => return "TC";
            when 18 => return "SRP";
            when 19 => return "CRP";
            when 24 => return "MMUSR";
            when others => return "UNIMP(" & integer'image(sel) & ")";
        end case;
    end function;

    impure function pmove_ea_string(mode : integer; reg : integer; reg_sel : integer; pc_int : integer) return string is
        variable w1 : std_logic_vector(15 downto 0);
        variable w2 : std_logic_vector(15 downto 0);
    begin
        case mode is
            when 0 =>
                if reg_sel = 18 or reg_sel = 19 then
                    return "D" & integer'image(reg) & ":D" & integer'image(reg + 1);
                else
                    return "D" & integer'image(reg);
                end if;
            when 2 =>
                return "(A" & integer'image(reg) & ")";
            when 3 =>
                return "(A" & integer'image(reg) & ")+";
            when 4 =>
                return "-(A" & integer'image(reg) & ")";
            when 5 =>
                w1 := mem_word(pc_int + 4);
                return "($" & slv16_to_hex(w1) & ",A" & integer'image(reg) & ")";
            when 6 =>
                w1 := mem_word(pc_int + 4);
                return "(d8,A" & integer'image(reg) & ",Xn) $" & slv16_to_hex(w1);
            when 7 =>
                if reg = 0 then
                    w1 := mem_word(pc_int + 4);
                    return "($" & slv16_to_hex(w1) & ").W";
                elsif reg = 1 then
                    w1 := mem_word(pc_int + 4);
                    w2 := mem_word(pc_int + 6);
                    return "($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L";
                else
                    return "(EA?)";
                end if;
            when others =>
                return "(EA?)";
        end case;
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
            -- Check instruction type from ext(15:13)
            if ext(15 downto 13) = "100" then
                -- PTEST
                if ext(9) = '1' then
                    return "PTESTR (A" & integer'image(reg_i) & ")";
                else
                    return "PTESTW (A" & integer'image(reg_i) & ")";
                end if;
            end if;
            sel_i := to_integer(unsigned(ext(14 downto 10)));
            dir := ext(9);
            if dir = '0' then
                return "PMOVE " & pmove_ea_string(mode_i, reg_i, sel_i, pc_int) & "," & pmove_reg_name(sel_i);
            else
                return "PMOVE " & pmove_reg_name(sel_i) & "," & pmove_ea_string(mode_i, reg_i, sel_i, pc_int);
            end if;
        end if;

        -- NOP
        if opc = x"4E71" then
            return "NOP";
        end if;

        -- STOP
        if opc = x"4E72" then
            w1 := mem_word(pc_int + 2);
            return "STOP #" & slv16_to_hex(w1);
        end if;

        -- MOVEQ #imm,Dn (0x7nxx)
        if opc_c(15 downto 12) = "0111" then
            dn := to_integer(unsigned(opc_c(11 downto 9)));
            return "MOVEQ #" & slv16_to_hex("00000000" & opc_c(7 downto 0)) & ",D" & integer'image(dn);
        end if;

        -- MOVEA.L #imm,An (0x2n7C)
        if opc_c(15 downto 12) = "0010" and opc_c(7 downto 0) = x"7C" then
            an := to_integer(unsigned(opc_c(11 downto 9)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVEA.L #$" & slv16_to_hex(w1) & slv16_to_hex(w2) & ",A" & integer'image(an);
        end if;

        -- MOVEA.L (abs).L,An (0x2Ex9)
        if opc_c(15 downto 12) = "0010" and opc_c(8 downto 6) = "001" and opc_c(5 downto 3) = "111" and opc_c(2 downto 0) = "001" then
            an := to_integer(unsigned(opc_c(11 downto 9)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVEA.L ($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L,A" & integer'image(an);
        end if;

        -- MOVE.L (abs).L,Dn (0x2039 + dn*0x200)
        if opc_c(15 downto 12) = "0010"
           and opc_c(8 downto 6) = "000"
           and opc_c(5 downto 3) = "111"
           and opc_c(2 downto 0) = "001" then
            dn := to_integer(unsigned(opc_c(11 downto 9)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVE.L ($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L,D" & integer'image(dn);
        end if;

        -- MOVE.L Dn,(abs).L (0x23C0 + dn)
        if opc_c(15 downto 8) = x"23" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then
            dn := to_integer(unsigned(opc_c(2 downto 0)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVE.L D" & integer'image(dn) & ",($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L";
        end if;

        -- MOVE.W Dn,(abs).L (0x33C0 + dn)
        if opc_c(15 downto 8) = x"33" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then
            dn := to_integer(unsigned(opc_c(2 downto 0)));
            w1 := mem_word(pc_int + 2);
            w2 := mem_word(pc_int + 4);
            return "MOVE.W D" & integer'image(dn) & ",($" & slv16_to_hex(w1) & slv16_to_hex(w2) & ").L";
        end if;

        -- Fallback
        return "OPC $" & slv16_to_hex(opc);
    end function;

    impure function instr_len(opc : std_logic_vector(15 downto 0); pc_int : integer; ext_word : std_logic_vector(15 downto 0)) return integer is
        variable mode_i : integer;
        variable reg_i : integer;
        variable ext : std_logic_vector(15 downto 0);
        variable opc_c : std_logic_vector(15 downto 0);
    begin
        opc_c := clean_slv(opc);
        -- PMOVE length: base 4 + EA extension
        if opc_c(15 downto 8) = x"F0" then
            ext := ext_word;
            if ext = x"0000" then
                ext := mem_word(pc_int + 2);
            end if;
            mode_i := to_integer(unsigned(opc_c(5 downto 3)));
            reg_i := to_integer(unsigned(opc_c(2 downto 0)));
            case mode_i is
                when 5 => return 6; -- (d16,An)
                when 6 => return 6; -- (d8,An,Xn)
                when 7 =>
                    if reg_i = 0 then
                        return 6; -- (xxx).W
                    elsif reg_i = 1 then
                        return 8; -- (xxx).L
                    else
                        return 4;
                    end if;
                when others =>
                    return 4;
            end case;
        end if;

        -- NOP
        if opc_c = x"4E71" then
            return 2;
        end if;

        -- STOP
        if opc_c = x"4E72" then
            return 4;
        end if;

        -- MOVEQ
        if opc_c(15 downto 12) = "0111" then
            return 2;
        end if;

        -- MOVEA.L #imm,An
        if opc_c(15 downto 12) = "0010" and opc_c(7 downto 0) = x"7C" then
            return 6;
        end if;

        -- MOVEA.L (abs).L,An
        if opc_c(15 downto 12) = "0010" and opc_c(8 downto 6) = "001" and opc_c(5 downto 3) = "111" and opc_c(2 downto 0) = "001" then
            return 6;
        end if;

        -- MOVE.L (abs).L,Dn
        if opc_c(15 downto 12) = "0010"
           and opc_c(8 downto 6) = "000"
           and opc_c(5 downto 3) = "111"
           and opc_c(2 downto 0) = "001" then
            return 6;
        end if;

        -- MOVE.L Dn,(abs).L
        if opc_c(15 downto 8) = x"23" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then
            return 6;
        end if;

        -- MOVE.W Dn,(abs).L
        if opc_c(15 downto 8) = x"33" and opc_c(7 downto 6) = "11" and opc_c(5 downto 3) = "000" then
            return 6;
        end if;

        return 2;
    end function;

    -- Helper: format 1/2/4 words as hex string from array
    function words_to_hex(w : word_array; count : integer) return string is
        variable s : string(1 to 16) := (others => ' ');
        variable idx : integer := 1;
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

    -- Helper: format N instruction words from memory (space-separated)
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
    procedure emit_word(variable pc : inout integer; w : std_logic_vector(15 downto 0)) is
    begin
        memory(pc/2) := w;
        pc := pc + 2;
    end procedure;

    -- Emit MOVEA.L #imm,Areg
    procedure emit_movea(variable pc : inout integer; areg : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        case areg is
            when 0 => opcode := x"207C";
            when 1 => opcode := x"227C";
            when 2 => opcode := x"247C";
            when 3 => opcode := x"267C";
            when 4 => opcode := x"287C";
            when 5 => opcode := x"2A7C";
            when 6 => opcode := x"2C7C";
            when 7 => opcode := x"2E7C";
            when others => opcode := x"207C";
        end case;
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit MOVEQ #imm,Dn (imm is 8-bit)
    procedure emit_moveq(variable pc : inout integer; dn : integer; imm : integer) is
        variable opcode : std_logic_vector(15 downto 0);
        variable imm8   : integer;
    begin
        imm8 := imm mod 256;
        opcode := std_logic_vector(to_unsigned(16#7000# + (dn * 512) + imm8, 16));
        emit_word(pc, opcode);
    end procedure;

    -- Emit MOVE.L (abs).L,Dn
    procedure emit_move_l_abs_to_dn(variable pc : inout integer; dn : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := std_logic_vector(to_unsigned(16#2039# + (dn * 16#0200#), 16));
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit MOVE.L Dn,(abs).L
    procedure emit_move_l_dn_to_abs(variable pc : inout integer; dn : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := std_logic_vector(to_unsigned(16#23C0# + dn, 16));
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit MOVE.W Dn,(abs).L
    procedure emit_move_w_dn_to_abs(variable pc : inout integer; dn : integer; addr32 : std_logic_vector(31 downto 0)) is
        variable opcode : std_logic_vector(15 downto 0);
    begin
        opcode := std_logic_vector(to_unsigned(16#33C0# + dn, 16));
        emit_word(pc, opcode);
        emit_word(pc, addr32(31 downto 16));
        emit_word(pc, addr32(15 downto 0));
    end procedure;

    -- Emit PMOVE instruction
    procedure emit_pmove(
        variable pc : inout integer;
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
        opcode := "1111000000" & ea_mode & ea_reg; -- F000 + EA
        extension := "0" & reg_sel & direction & "000000000";
        emit_word(pc, opcode);
        emit_word(pc, extension);

        case ea_mode is
            when "101" => -- (d16,An)
                emit_word(pc, disp_or_addr);
            when "110" => -- (d8,An,Xn)
                emit_word(pc, disp_or_addr);
            when "111" =>
                if ea_reg = "000" then
                    emit_word(pc, disp_or_addr); -- (xxx).W
                elsif ea_reg = "001" then
                    emit_word(pc, addr_hi);      -- (xxx).L
                    emit_word(pc, disp_or_addr);
                end if;
            when others =>
                null;
        end case;
    end procedure;

    -- Write 16/32/64-bit test values into memory
    procedure write_word(addr : integer; w : std_logic_vector(15 downto 0)) is
    begin
        memory(addr/2) := w;
    end procedure;

    procedure write_long(addr : integer; v : std_logic_vector(31 downto 0)) is
    begin
        write_word(addr, v(31 downto 16));
        write_word(addr + 2, v(15 downto 0));
    end procedure;

    procedure write_quad(addr : integer; hi : std_logic_vector(31 downto 0); lo : std_logic_vector(31 downto 0)) is
    begin
        write_long(addr, hi);
        write_long(addr + 4, lo);
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
            CPU => "10",  -- 68020/030 with PMMU
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
            pmmu_walker_wdat => pmmu_walker_wdat,
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
            debug_regfile_a2 => open,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
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
            debug_pmmu_reg_rdat => open
        );

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when test_done = '0' else '0';

    -- Memory read (combinational)
    mem_read_proc: process(addr)
        variable mem_addr : integer;
    begin
        -- Map only the low 128KB (64K words). Anything above that is out-of-range.
        if addr(31 downto 17) = "000000000000000" then
            mem_addr := to_integer(unsigned(addr(16 downto 1)));
            data_in <= memory(mem_addr);
        else
            data_in <= x"4E71";
        end if;
    end process;

    -- Memory write (registered)
    mem_write_proc: process(clk)
        variable wr_prev_active : std_logic := '0';
        variable wr_prev_addr : std_logic_vector(31 downto 0) := (others => '1');
        variable mem_addr : integer;
        variable old_val  : std_logic_vector(15 downto 0);
        variable new_val  : std_logic_vector(15 downto 0);
        variable l : line;
    begin
        if rising_edge(clk) then
            if busstate /= "11" then
                wr_prev_active := '0';
            end if;
            if busstate = "11" and nWr = '0' then
                -- Only allow writes into the low 128KB (64K words).
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
                    if mem_addr >= 16#1400# and mem_addr <= 16#17FF# then
                        fc_shadow_w(mem_addr - 16#1400#) := fc;
                    end if;
                    if fc = "011" and (wr_prev_active = '0' or wr_prev_addr /= addr) then
                        fc3_write_count <= fc3_write_count + 1;
                    end if;
                    wr_prev_active := '1';
                    wr_prev_addr := addr;
                    write(l, string'("WRITE addr=$") & slv32_to_hex(addr));
                    write(l, string'(" data=$") & slv16_to_hex(data_out));
                    write(l, string'(" old=$") & slv16_to_hex(old_val));
                    write(l, string'(" new=$") & slv16_to_hex(new_val));
                    write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                    write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                    write(l, string'(" BRF=$") & slv16_to_hex(dbg_brief));
                    write(l, string'(" PBR=$") & slv16_to_hex(dbg_pmmu_brief));
                    write(l, string'(" MM=$") & slv16_to_hex("0000000000" & dbg_memmask));
                    write(l, string'(" MMX=$") & slv16_to_hex("0000000000" & dbg_memmaskmux));
                    write(l, string'(" ST=$") & slv16_to_hex("00000000000000" & dbg_state));
                    write(l, string'(" BS=") & slv16_to_hex("00000000000000" & busstate));
                    write(l, string'(" nWr=") & std_logic'image(nWr));
                    if longword = '1' then
                        write(l, string'(" SZ=L"));
                    elsif nUDS = '0' and nLDS = '0' then
                        write(l, string'(" SZ=W"));
                    else
                        write(l, string'(" SZ=B"));
                    end if;
                    write(l, string'(" nUDS=") & std_logic'image(nUDS));
                    write(l, string'(" nLDS=") & std_logic'image(nLDS));
                    writeline(output, l);
                else
                    write(l, string'("WRITE-OOB addr=$") & slv32_to_hex(addr));
                    write(l, string'(" data=$") & slv16_to_hex(data_out));
                    write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                    write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                    if longword = '1' then
                        write(l, string'(" SZ=L"));
                    elsif nUDS = '0' and nLDS = '0' then
                        write(l, string'(" SZ=W"));
                    else
                        write(l, string'(" SZ=B"));
                    end if;
                    write(l, string'(" nUDS=") & std_logic'image(nUDS));
                    write(l, string'(" nLDS=") & std_logic'image(nLDS));
                    writeline(output, l);
                end if;
            end if;

            if busstate = "10" then
                if addr(31 downto 17) = "000000000000000" then
                    mem_addr := to_integer(unsigned(addr(16 downto 1)));
                    old_val := memory(mem_addr);
                    write(l, string'("READ addr=$") & slv32_to_hex(addr));
                    write(l, string'(" data=$") & slv16_to_hex(data_in));
                    write(l, string'(" mem=$") & slv16_to_hex(old_val));
                    write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                    write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                    write(l, string'(" BRF=$") & slv16_to_hex(dbg_brief));
                    write(l, string'(" PBR=$") & slv16_to_hex(dbg_pmmu_brief));
                    write(l, string'(" MM=$") & slv16_to_hex("0000000000" & dbg_memmask));
                    write(l, string'(" MMX=$") & slv16_to_hex("0000000000" & dbg_memmaskmux));
                    write(l, string'(" ST=$") & slv16_to_hex("00000000000000" & dbg_state));
                    write(l, string'(" BS=") & slv16_to_hex("00000000000000" & busstate));
                    write(l, string'(" nWr=") & std_logic'image(nWr));
                    if longword = '1' then
                        write(l, string'(" SZ=L"));
                    elsif nUDS = '0' and nLDS = '0' then
                        write(l, string'(" SZ=W"));
                    else
                        write(l, string'(" SZ=B"));
                    end if;
                    write(l, string'(" nUDS=") & std_logic'image(nUDS));
                    write(l, string'(" nLDS=") & std_logic'image(nLDS));
                    writeline(output, l);
                else
                    write(l, string'("READ-OOB addr=$") & slv32_to_hex(addr));
                    write(l, string'(" data=$") & slv16_to_hex(data_in));
                    write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                    write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                    if longword = '1' then
                        write(l, string'(" SZ=L"));
                    elsif nUDS = '0' and nLDS = '0' then
                        write(l, string'(" SZ=W"));
                    else
                        write(l, string'(" SZ=B"));
                    end if;
                    write(l, string'(" nUDS=") & std_logic'image(nUDS));
                    write(l, string'(" nLDS=") & std_logic'image(nLDS));
                    writeline(output, l);
                end if;
            end if;
        end if;
    end process;

    -- PMMU walker handshake (always ack)
    -- FC monitor: shadow the FC of data reads from the src window and count
    -- exotic-FC cycles (FC=011 must only ever appear on MOVES writes with
    -- DFC=3; FC=010 data reads only on MOVES reads with SFC=2).
    fc_monitor: process(clk)
        variable ridx : integer;
        variable rd_prev_active : std_logic := '0';
        variable rd_prev_addr : std_logic_vector(31 downto 0) := (others => '1');
    begin
        if rising_edge(clk) then
            if nReset = '1' and clkena_in = '1' then
                if busstate /= "10" then
                    rd_prev_active := '0';
                end if;
                if busstate = "10" then
                    if addr(31 downto 17) = "000000000000000" then
                        ridx := to_integer(unsigned(addr(16 downto 1)));
                        if ridx >= 16#1200# and ridx <= 16#15FF# then
                            fc_shadow_r(ridx - 16#1200#) := fc;
                        end if;
                    end if;
                    if rd_prev_active = '0' or rd_prev_addr /= addr then
                        if fc = "011" then
                            fc3_read_count <= fc3_read_count + 1;
                        elsif fc = "010" then
                            fc2_read_count <= fc2_read_count + 1;
                        end if;
                    end if;
                    rd_prev_active := '1';
                    rd_prev_addr := addr;
                elsif busstate = "00" then
                    if fc = "011" then
                        fc3_fetch_count <= fc3_fetch_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Memory-backed walker: serves table reads from tb memory and applies
    -- U/M history-bit writebacks to it, so descriptor side effects are
    -- directly checkable by the result comparator.
    walker_proc: process(clk)
        variable widx : integer;
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' then
                if not is_x(pmmu_walker_addr) and unsigned(pmmu_walker_addr(31 downto 0)) < 131072 then
                    widx := to_integer(unsigned(pmmu_walker_addr(16 downto 1)));
                    if pmmu_walker_we = '1' then
                        memory(widx)     := pmmu_walker_wdat(31 downto 16);
                        memory(widx + 1) := pmmu_walker_wdat(15 downto 0);
                    else
                        pmmu_walker_data <= memory(widx) & memory(widx + 1);
                    end if;
                else
                    pmmu_walker_data <= x"00000000";
                end if;
                pmmu_walker_ack <= '1';
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    -- Stall the CPU while the walker owns the bus (mirrors cpu_wrapper).
    clkena_stall: process(pmmu_walker_req)
    begin
        if pmmu_walker_req = '1' then
            clkena_in <= '0';
        else
            clkena_in <= '1';
        end if;
    end process;

    -- Instruction fetch trace with key registers
    trace_proc: process(clk)
        variable l : line;
        variable opc : std_logic_vector(15 downto 0);
        variable ext : std_logic_vector(15 downto 0);
        variable pc_int : integer;
        variable pc_exec : std_logic_vector(31 downto 0);
        variable pc_exec_clean : std_logic_vector(31 downto 0);
        variable mode_i : integer;
        variable sel_i : integer;
        variable dir : std_logic;
    begin
        if rising_edge(clk) and nReset = '1' and test_done = '0' then
            if dbg_trapmake = '1' then
                write(l, string'("TRAP  trapmake=1"));
                if dbg_trap_1111 = '1' then
                    write(l, string'(" fline=1"));
                else
                    write(l, string'(" fline=0"));
                end if;
                if dbg_trap_illegal = '1' then
                    write(l, string'(" illegal=1"));
                end if;
                if dbg_trap_priv = '1' then
                    write(l, string'(" priv=1"));
                end if;
                if dbg_trap_addr_error = '1' then
                    write(l, string'(" addrerr=1"));
                end if;
                if dbg_trap_berr = '1' then
                    write(l, string'(" berr=1"));
                end if;
                if dbg_trap_mmu_berr = '1' then
                    write(l, string'(" mmu_berr=1"));
                end if;
                write(l, string'(" vec=$") & slv32_to_hex(dbg_trap_vector));
                write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                write(l, string'(" LOPC=$") & slv16_to_hex(dbg_last_opc_read));
                write(l, string'(" DREAD=$") & slv32_to_hex(dbg_data_read));
                write(l, string'(" STATE=$") & slv16_to_hex("00000000000000" & dbg_state));
                write(l, string'(" SETST=$") & slv16_to_hex("00000000000000" & dbg_setstate));
                write(l, string'(" PMBR=$") & slv16_to_hex(dbg_pmmu_brief));
                write(l, string'(" MST=") & integer'image(dbg_micro_state));
                write(l, string'(" NST=") & integer'image(dbg_next_micro_state));
                write(l, string'(" PCA=$") & slv32_to_hex(dbg_pc_add));
                write(l, string'(" PCDa=$") & slv32_to_hex(dbg_pc_dataa));
                write(l, string'(" PCDb=$") & slv32_to_hex(dbg_pc_datab));
                if dbg_pmmu_reg_we = '1' then
                    write(l, string'(" PWR dat=$") & slv32_to_hex(dbg_pmmu_reg_wdat));
                    write(l, string'(" sel=$") & slv16_to_hex("00000000000" & dbg_pmmu_reg_sel));
                    write(l, string'(" part=") & std_logic'image(dbg_pmmu_reg_part));
                end if;
                writeline(output, l);
            end if;

            if dbg_getbrief = '1' or dbg_get_2ndopc = '1' then
                write(l, string'("GBR"));
                if dbg_getbrief = '1' then
                    write(l, string'(" gb=1"));
                else
                    write(l, string'(" gb=0"));
                end if;
                if dbg_get_2ndopc = '1' then
                    write(l, string'(" g2=1"));
                else
                    write(l, string'(" g2=0"));
                end if;
                write(l, string'(" PC=$") & slv32_to_hex(dbg_pc));
                write(l, string'(" OPC=$") & slv16_to_hex(dbg_opcode));
                write(l, string'(" DREAD=$") & slv32_to_hex(dbg_data_read));
                write(l, string'(" LRD=$") & slv32_to_hex(dbg_last_data_read));
                write(l, string'(" LOPCPC=$") & slv32_to_hex(dbg_last_opc_pc));
                write(l, string'(" FBP=") & std_logic'image(dbg_fline_brief_pending));
                write(l, string'(" FCV=") & std_logic'image(dbg_fline_context_valid));
                write(l, string'(" FOPCPC=$") & slv32_to_hex(dbg_fline_opcode_pc));
                write(l, string'(" ST=$") & slv16_to_hex("00000000000000" & dbg_state));
                if dbg_setnextpass = '1' then
                    write(l, string'(" SNP=1"));
                else
                    write(l, string'(" SNP=0"));
                end if;
                if dbg_pc_word = '1' then
                    write(l, string'(" PCW=1"));
                else
                    write(l, string'(" PCW=0"));
                end if;
                if dbg_pc_brw = '1' then
                    write(l, string'(" PCBRW=1"));
                else
                    write(l, string'(" PCBRW=0"));
                end if;
                writeline(output, l);
            end if;
            if TRACE_FETCH and busstate = "00" then
                write(l, string'("FETCH PC=$") & slv32_to_hex(addr));
                write(l, string'(" OPC=$") & slv16_to_hex(data_in));
                write(l, string'(" BRF=$") & slv16_to_hex(dbg_brief));
                write(l, string'(" PBR=$") & slv16_to_hex(dbg_pmmu_brief));
                write(l, string'(" SND=$") & slv16_to_hex(dbg_sndopc));
                write(l, string'(" FBP=") & std_logic'image(dbg_fline_brief_pending));
                write(l, string'(" FCV=") & std_logic'image(dbg_fline_context_valid));
                if dbg_setnextpass = '1' then
                    write(l, string'(" SNP=1"));
                else
                    write(l, string'(" SNP=0"));
                end if;
                write(l, string'(" PCDb=$") & slv32_to_hex(dbg_pc_datab));
                write(l, string'(" D0=$") & slv32_to_hex(dbg_reg_d0));
                write(l, string'(" D1=$") & slv32_to_hex(dbg_reg_d1));
                write(l, string'(" D2=$") & slv32_to_hex(dbg_reg_d2));
                write(l, string'(" D3=$") & slv32_to_hex(dbg_reg_d3));
                write(l, string'(" D6=$") & slv32_to_hex(dbg_reg_d6));
                write(l, string'(" A0=$") & slv32_to_hex(dbg_reg_a0));
                write(l, string'(" A1=$") & slv32_to_hex(dbg_reg_a1));
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
                    write(l, string'(" LEN=") & integer'image(instr_len(opc, pc_int, dbg_brief)));
                    write(l, string'(" OPC=$") & slv16_to_hex(opc));
                    write(l, string'(" WORDS=") & words_at_pc_to_hex(pc_int, instr_len(opc, pc_int, dbg_brief) / 2));
                    write(l, string'(" BRF=$") & slv16_to_hex(dbg_brief));
                    write(l, string'(" PBR=$") & slv16_to_hex(dbg_pmmu_brief));
                    write(l, string'(" SND=$") & slv16_to_hex(dbg_sndopc));
                    write(l, string'(" D0=$") & slv32_to_hex(dbg_reg_d0));
                    write(l, string'(" D1=$") & slv32_to_hex(dbg_reg_d1));
                    write(l, string'(" D2=$") & slv32_to_hex(dbg_reg_d2));
                    write(l, string'(" D3=$") & slv32_to_hex(dbg_reg_d3));
                    write(l, string'(" D6=$") & slv32_to_hex(dbg_reg_d6));
                    write(l, string'(" A0=$") & slv32_to_hex(dbg_reg_a0));
                    write(l, string'(" A1=$") & slv32_to_hex(dbg_reg_a1));
                    write(l, string'(" A7=$") & slv32_to_hex(dbg_reg_a7));
                    write(l, string'(" MST=") & integer'image(dbg_micro_state));
                    write(l, string'(" NST=") & integer'image(dbg_next_micro_state));
                    writeline(output, l);
                end if;

                if dbg_trapmake = '1' then
                    write(l, string'("TRAP  trapmake=1"));
                    if dbg_trap_1111 = '1' then
                        write(l, string'(" fline=1"));
                    else
                        write(l, string'(" fline=0"));
                    end if;
                    writeline(output, l);
                end if;

                if opc(15 downto 12) = "1111" then
                    mode_i := to_integer(unsigned(opc(5 downto 3)));
                    sel_i := to_integer(unsigned(dbg_brief(14 downto 10)));
                    dir := dbg_brief(9);
                    if mode_i = 0 and (sel_i = 18 or sel_i = 19) then
                        write(l, string'("EXECDBG PMOVE reg=") & pmove_reg_name(sel_i));
                        if dir = '1' then
                            write(l, string'(" dir=MMU->EA"));
                        else
                            write(l, string'(" dir=EA->MMU"));
                        end if;
                        write(l, string'(" mstate=") & integer'image(dbg_micro_state));
                        write(l, string'(" nstate=") & integer'image(dbg_next_micro_state));
                        write(l, string'(" memmask=$") & slv16_to_hex("0000000000" & dbg_memmask));
                        if dbg_regfile_we = '1' then
                            write(l, string'(" rf_we=1"));
                        else
                            write(l, string'(" rf_we=0"));
                        end if;
                        write(l, string'(" rf_wa=$") & slv16_to_hex("000000000000" & dbg_regfile_waddr));
                        write(l, string'(" rf_wd=$") & slv32_to_hex(dbg_regfile_wdata));
                        write(l, string'(" state=$") & slv16_to_hex("00000000000000" & dbg_state));
                        write(l, string'(" lastopc=$") & slv16_to_hex(dbg_last_opc_read));
                        write(l, string'(" lopcpc=$") & slv32_to_hex(dbg_last_opc_pc));
                        write(l, string'(" d_read=$") & slv32_to_hex(dbg_data_read));
                        write(l, string'(" lrd=$") & slv32_to_hex(dbg_last_data_read));
                        write(l, string'(" fbp=") & std_logic'image(dbg_fline_brief_pending));
                        write(l, string'(" fcv=") & std_logic'image(dbg_fline_context_valid));
                        write(l, string'(" fopcpc=$") & slv32_to_hex(dbg_fline_opcode_pc));
                        if dbg_getbrief = '1' then
                            write(l, string'(" gbr=1"));
                        else
                            write(l, string'(" gbr=0"));
                        end if;
                        if dbg_get_2ndopc = '1' then
                            write(l, string'(" g2=1"));
                        else
                            write(l, string'(" g2=0"));
                        end if;
                        if dbg_direct_data = '1' then
                            write(l, string'(" direct=1"));
                        else
                            write(l, string'(" direct=0"));
                        end if;
                        write(l, string'(" ma_reg=$") & slv32_to_hex(dbg_memaddr_reg));
                        write(l, string'(" ma_delta=$") & slv32_to_hex(dbg_memaddr_delta));
                        write(l, string'(" mrega=$") & slv32_to_hex(dbg_memaddr_delta_rega));
                        write(l, string'(" mregb=$") & slv32_to_hex(dbg_memaddr_delta_regb));
                        write(l, string'(" addsub=$") & slv32_to_hex(dbg_addsub_q));
                        write(l, string'(" mmux=$") & slv16_to_hex("0000000000" & dbg_memmaskmux));
                        write(l, string'(" fline=$") & slv16_to_hex(dbg_fline_opcode_latch));
                        if dbg_fline_context_valid = '1' then
                            write(l, string'(" fctx=1"));
                        else
                            write(l, string'(" fctx=0"));
                        end if;
                        if dbg_pmove_dn_mode = '1' then
                            write(l, string'(" dn=1"));
                        else
                            write(l, string'(" dn=0"));
                        end if;
                        write(l, string'(" pmmu_ea=$") & slv16_to_hex("0000000000" & dbg_pmmu_ea_mode_latched));
                        write(l, string'(" pmmu_br=$") & slv16_to_hex(dbg_pmmu_brief));
                        write(l, string'(" pca=$") & slv32_to_hex(dbg_pc_add));
                        write(l, string'(" pcda=$") & slv32_to_hex(dbg_pc_dataa));
                        write(l, string'(" pcdb=$") & slv32_to_hex(dbg_pc_datab));
                        if dbg_exec_direct_delta = '1' then
                            write(l, string'(" ex_dird=1"));
                        else
                            write(l, string'(" ex_dird=0"));
                        end if;
                        if dbg_exec_directPC = '1' then
                            write(l, string'(" ex_dpc=1"));
                        else
                            write(l, string'(" ex_dpc=0"));
                        end if;
                        if dbg_exec_mem_addsub = '1' then
                            write(l, string'(" ex_madd=1"));
                        else
                            write(l, string'(" ex_madd=0"));
                        end if;
                        if dbg_set_addrlong = '1' then
                            write(l, string'(" set_al=1"));
                        else
                            write(l, string'(" set_al=0"));
                        end if;
                        write(l, string'(" setst=$") & slv16_to_hex("00000000000000" & dbg_setstate));
                        write(l, string'(" msrc=$") & slv16_to_hex("00000000" & dbg_mdelta_src));
                        if dbg_pc_brw = '1' then
                            write(l, string'(" pcbrw=1"));
                        else
                            write(l, string'(" pcbrw=0"));
                        end if;
                        if dbg_pc_word = '1' then
                            write(l, string'(" pcw=1"));
                        else
                            write(l, string'(" pcw=0"));
                        end if;
                        if dbg_pmmu_reg_we = '1' then
                            write(l, string'(" pmmu_we=1"));
                        else
                            write(l, string'(" pmmu_we=0"));
                        end if;
                        if dbg_pmmu_reg_re = '1' then
                            write(l, string'(" pmmu_re=1"));
                        else
                            write(l, string'(" pmmu_re=0"));
                        end if;
                        write(l, string'(" pmmu_sel=$") & slv16_to_hex("00000000000" & dbg_pmmu_reg_sel));
                        write(l, string'(" pmmu_wd=$") & slv32_to_hex(dbg_pmmu_reg_wdat));
                        if dbg_pmmu_reg_part = '1' then
                            write(l, string'(" pmmu_part=1"));
                        else
                            write(l, string'(" pmmu_part=0"));
                        end if;
                        writeline(output, l);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Fail fast if PC goes out of expected range or becomes unknown
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
                write(l, string'("FAIL: PC out of range or unknown at EXEC PC=$") & slv32_to_hex(exec_pc));
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
        variable j : integer;

        variable src_ptr : integer := 16#2400#;
        variable dst_ptr : integer := 16#2800#;
        variable t_src, t_dst : integer;
        variable t_s0, t_s1, t_s2, t_s3 : integer;
        variable t_d0, t_d1 : integer;
        variable expw : word_array := (others => (others => '0'));
        variable wfc_addr : int_arr := (others => 0);
        variable wfc_val  : fc_exp_arr := (others => "111");
        variable wfc_n    : integer := 0;
        variable rfc_addr : int_arr := (others => 0);
        variable rfc_val  : fc_exp_arr := (others => "111");
        variable rfc_n    : integer := 0;

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

        procedure alloc_src(words : integer; addr_out : out integer) is
        begin
            addr_out := src_ptr;
            src_ptr := src_ptr + (words * 2);
        end procedure;

        procedure alloc_dst(words : integer; addr_out : out integer) is
        begin
            addr_out := dst_ptr;
            dst_ptr := dst_ptr + (words * 2);
        end procedure;

        procedure emit_pmove_mem_pair(
            reg_sel : std_logic_vector(4 downto 0);
            reg_name : string;
            val_hi : std_logic_vector(31 downto 0);
            val_lo : std_logic_vector(31 downto 0);
            words : integer;
            mode_name : string;
            ea_mode : std_logic_vector(2 downto 0);
            ea_reg_src : std_logic_vector(2 downto 0);
            ea_reg_dst : std_logic_vector(2 downto 0);
            disp_src : std_logic_vector(15 downto 0);
            disp_dst : std_logic_vector(15 downto 0);
            abs_hi_src : std_logic_vector(15 downto 0);
            abs_hi_dst : std_logic_vector(15 downto 0);
            src_addr : integer;
            dst_addr : integer
        ) is
            variable exp_words : word_array := (others => (others => '0'));
            variable desc_str : string(1 to 80);
        begin
            -- Fill source memory for mem->MMU (unless MMUSR, which is read-only)
            if reg_sel /= REG_MMUSR then
                if words = 1 then
                    write_word(src_addr, val_lo(15 downto 0));
                elsif words = 2 then
                    write_long(src_addr, val_hi);
                else
                    write_quad(src_addr, val_hi, val_lo);
                end if;
            end if;

            -- Load An bases for modes that use An (including A7/SP)
            -- BUG #395 FIX: Check if using A7 (register 7) and load A7 instead of A0/A1
            if ea_mode = "010" or ea_mode = "011" or ea_mode = "100" or ea_mode = "101" or ea_mode = "110" then
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr, 32)));  -- Load A7 for destination
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr, 32)));
                end if;

                if ea_reg_src = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(src_addr, 32)));  -- Load A7 for source
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_src)), std_logic_vector(to_unsigned(src_addr, 32)));
                end if;
            end if;

            -- Adjust bases for -(An)
            if ea_mode = "100" then
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr + (words * 2), 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr + (words * 2), 32)));
                end if;

                if ea_reg_src = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(src_addr + (words * 2), 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_src)), std_logic_vector(to_unsigned(src_addr + (words * 2), 32)));
                end if;
            end if;

            -- Adjust bases for (d16,An)
            if ea_mode = "101" then
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr - to_integer(unsigned(disp_dst)), 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr - to_integer(unsigned(disp_dst)), 32)));
                end if;

                if ea_reg_src = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(src_addr - to_integer(unsigned(disp_src)), 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_src)), std_logic_vector(to_unsigned(src_addr - to_integer(unsigned(disp_src)), 32)));
                end if;
            end if;

            -- Adjust bases for (d8,An,Xn)
            if ea_mode = "110" then
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr - 6, 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr - 6, 32)));
                end if;

                if ea_reg_src = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(src_addr - 6, 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_src)), std_logic_vector(to_unsigned(src_addr - 6, 32)));
                end if;
            end if;

            -- PMOVE (mem->MMU)
            emit_pmove(pc, reg_sel, DIR_MEM_TO_MMU, ea_mode, ea_reg_src, disp_src, abs_hi_src);

            -- BUG #395 FIX: If src and dst use the same address register, reload it with dst_addr
            -- before the second PMOVE. The earlier MOVEA loaded src_addr last, so the dst write
            -- would use the wrong address without this reload.
            if (ea_mode = "010" or ea_mode = "011") and ea_reg_src = ea_reg_dst then
                -- (An) and (An)+ modes: reload with base address
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr, 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr, 32)));
                end if;
            elsif ea_mode = "100" and ea_reg_src = ea_reg_dst then
                -- -(An) mode: reload with dst_addr + offset (CPU will predecrement)
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr + (words * 2), 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr + (words * 2), 32)));
                end if;
            elsif ea_mode = "101" and ea_reg_src = ea_reg_dst then
                -- (d16,An): reload with base address (dst_addr - displacement)
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr - to_integer(unsigned(disp_dst)), 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr - to_integer(unsigned(disp_dst)), 32)));
                end if;
            elsif ea_mode = "110" and ea_reg_src = ea_reg_dst then
                -- (d8,An,Xn): reload with base address
                if ea_reg_dst = "111" then
                    emit_movea(pc, 7, std_logic_vector(to_unsigned(dst_addr - 6, 32)));
                else
                    emit_movea(pc, to_integer(unsigned(ea_reg_dst)), std_logic_vector(to_unsigned(dst_addr - 6, 32)));
                end if;
            end if;

            -- PMOVE (MMU->mem)
            emit_pmove(pc, reg_sel, DIR_MMU_TO_MEM, ea_mode, ea_reg_dst, disp_dst, abs_hi_dst);

            -- Record expected output at destination
            if words = 1 then
                exp_words(0) := val_lo(15 downto 0);
            elsif words = 2 then
                exp_words(0) := val_hi(31 downto 16);
                exp_words(1) := val_hi(15 downto 0);
            else
                exp_words(0) := val_hi(31 downto 16);
                exp_words(1) := val_hi(15 downto 0);
                exp_words(2) := val_lo(31 downto 16);
                exp_words(3) := val_lo(15 downto 0);
            end if;

            set_desc(desc_str, "PMOVE " & mode_name & "," & reg_name & " then PMOVE " & reg_name & "," & mode_name);
            record_test(desc_str, dst_addr, words, exp_words);
        end procedure;

        -- Emit level-0 PTEST instruction: PTESTR (A2), immediate FC=5.
        -- WinUAE reports transparent TTR hits through the level-0 ATC/TTR
        -- search path; nonzero levels use the table-walk path and report the
        -- no-table setup here as invalid.
        -- Extension word: 100 000 1 0 000 10 101 = $8215
        procedure emit_ptest_a2 is
        begin
            emit_word(pc, x"F012");  -- F-line + EA=(A2) [mode=010, reg=010]
            emit_word(pc, x"8215");  -- PTESTR, level=0, A=0, imm FC=5 (super data)
        end procedure;

        -- Set up PTEST to populate MMUSR with non-zero value ($0040 = T bit)
        -- Uses memory-mode PMOVE (An) because Dn is not a WinUAE-valid PMOVE EA.
        -- Pre-loads ALL address registers BEFORE enabling MMU to minimize
        -- instructions executed during MMU-active period
        procedure emit_ptest_mmusr_setup is
            variable tt0_addr : integer;
            variable tc_addr : integer;
            variable zero_addr : integer;
        begin
            -- Allocate and store all values in memory FIRST
            alloc_src(2, tt0_addr);
            write_long(tt0_addr, VAL_TT0_PTEST);
            alloc_src(2, tc_addr);
            write_long(tc_addr, VAL_TC_PTEST);
            alloc_src(2, zero_addr);
            write_long(zero_addr, x"00000000");

            -- Pre-load address registers: A1=TT0 data, set TT0 first
            emit_movea(pc, 1, std_logic_vector(to_unsigned(tt0_addr, 32)));
            emit_pmove(pc, REG_TT0, DIR_MEM_TO_MMU, "010", "001", x"0000", x"0000");  -- PMOVE (A1),TT0

            -- Pre-load A1=zero (for TC/TT0 disable), A2=$1000 (PTEST addr), A3=TC data
            emit_movea(pc, 1, std_logic_vector(to_unsigned(zero_addr, 32)));
            emit_movea(pc, 2, x"00001000");
            emit_movea(pc, 3, std_logic_vector(to_unsigned(tc_addr, 32)));

            -- Enable MMU via (A3)
            emit_pmove(pc, REG_TC, DIR_MEM_TO_MMU, "010", "011", x"0000", x"0000");  -- PMOVE (A3),TC

            -- PTESTR (A2) - tests address $1000, updates MMUSR with T=1 (transparent)
            emit_ptest_a2;

            -- Disable MMU immediately via (A1) which points to zero
            emit_pmove(pc, REG_TC, DIR_MEM_TO_MMU, "010", "001", x"0000", x"0000");  -- PMOVE (A1),TC (zero)

            -- Disable TT0 via (A1) (still points to zero)
            emit_pmove(pc, REG_TT0, DIR_MEM_TO_MMU, "010", "001", x"0000", x"0000");  -- PMOVE (A1),TT0 (zero)
        end procedure;

        -- Emit PMOVE tests for all memory modes for a given register
        procedure emit_all_mem_modes(
            reg_sel : std_logic_vector(4 downto 0);
            reg_name : string;
            val_hi : std_logic_vector(31 downto 0);
            val_lo : std_logic_vector(31 downto 0);
            words : integer
        ) is
            variable src_addr : integer;
            variable dst_addr : integer;
            variable src_addr_slv : std_logic_vector(31 downto 0);
            variable dst_addr_slv : std_logic_vector(31 downto 0);
            variable src_hi : std_logic_vector(15 downto 0);
            variable dst_hi : std_logic_vector(15 downto 0);
        begin
            -- (A1) src, (A0) dst
            alloc_src(words, src_addr);
            alloc_dst(words, dst_addr);
            emit_pmove_mem_pair(reg_sel, reg_name, val_hi, val_lo, words, "(A1)/(A0)", "010", "001", "000", x"0000", x"0000", x"0000", x"0000", src_addr, dst_addr);

            -- (d16,A1) src, (d16,A0) dst
            alloc_src(words, src_addr);
            alloc_dst(words, dst_addr);
            emit_pmove_mem_pair(reg_sel, reg_name, val_hi, val_lo, words, "(d16,A1)/(d16,A0)", "101", "001", "000", x"0010", x"0010", x"0000", x"0000", src_addr, dst_addr);

            -- (d8,A1,D6.W) src, (d8,A0,D6.W) dst - D6.W index, disp=2 => brief ext = 0x6002
            alloc_src(words, src_addr);
            alloc_dst(words, dst_addr);
            emit_pmove_mem_pair(reg_sel, reg_name, val_hi, val_lo, words, "(d8,A1,D6)/(d8,A0,D6)", "110", "001", "000", x"6002", x"6002", x"0000", x"0000", src_addr, dst_addr);

            -- (xxx).W
            alloc_src(words, src_addr);
            alloc_dst(words, dst_addr);
            emit_pmove_mem_pair(reg_sel, reg_name, val_hi, val_lo, words, "(xxx).W", "111", "000", "000", std_logic_vector(to_unsigned(src_addr, 16)), std_logic_vector(to_unsigned(dst_addr, 16)), x"0000", x"0000", src_addr, dst_addr);

            -- (xxx).L
            alloc_src(words, src_addr);
            alloc_dst(words, dst_addr);
            src_addr_slv := std_logic_vector(to_unsigned(src_addr, 32));
            dst_addr_slv := std_logic_vector(to_unsigned(dst_addr, 32));
            src_hi := src_addr_slv(31 downto 16);
            dst_hi := dst_addr_slv(31 downto 16);
            emit_pmove_mem_pair(reg_sel, reg_name, val_hi, val_lo, words, "(xxx).L", "111", "001", "001",
                                src_addr_slv(15 downto 0), dst_addr_slv(15 downto 0), src_hi, dst_hi, src_addr, dst_addr);
        end procedure;

        procedure emit_mmusr_mem_modes is
            variable dst_addr : integer;
            variable exp_words : word_array := (others => (others => '0'));
            variable desc_str : string(1 to 80);
        begin
            -- MMUSR populated by PTEST: $0040 (T=1, transparent TT0 match)
            exp_words(0) := VAL_MMUSR_EXPECTED;

            -- (A0)
            alloc_dst(1, dst_addr);
            emit_movea(pc, 0, std_logic_vector(to_unsigned(dst_addr, 32)));
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "010", "000", x"0000", x"0000");
            set_desc(desc_str, "PMOVE MMUSR,(A0)");
            record_test(desc_str, dst_addr, 1, exp_words);

            -- (d16,A0)
            alloc_dst(1, dst_addr);
            emit_movea(pc, 0, std_logic_vector(to_unsigned(dst_addr - 16, 32)));
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "101", "000", x"0010", x"0000");
            set_desc(desc_str, "PMOVE MMUSR,(d16,A0)");
            record_test(desc_str, dst_addr, 1, exp_words);

            -- (d8,A0,D6.W), disp=2
            alloc_dst(1, dst_addr);
            emit_movea(pc, 0, std_logic_vector(to_unsigned(dst_addr - 6, 32)));
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "110", "000", x"6002", x"0000");
            set_desc(desc_str, "PMOVE MMUSR,(d8,A0,D6)");
            record_test(desc_str, dst_addr, 1, exp_words);

            -- (xxx).W
            alloc_dst(1, dst_addr);
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "111", "000", std_logic_vector(to_unsigned(dst_addr, 16)), x"0000");
            set_desc(desc_str, "PMOVE MMUSR,(xxx).W");
            record_test(desc_str, dst_addr, 1, exp_words);

            -- (xxx).L
            alloc_dst(1, dst_addr);
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "111", "001", std_logic_vector(to_unsigned(dst_addr, 16)), std_logic_vector(to_unsigned(dst_addr / 65536, 16)));
            set_desc(desc_str, "PMOVE MMUSR,(xxx).L");
            record_test(desc_str, dst_addr, 1, exp_words);
        end procedure;

        -- BUG #395 FIX VALIDATION: Test PMOVE with (A7)/SP modes
        -- Critical test for WhichAmiga which uses PMOVE.L (SP),TC
        procedure emit_all_a7_modes(
            reg_sel : std_logic_vector(4 downto 0);
            reg_name : string;
            val_hi : std_logic_vector(31 downto 0);
            val_lo : std_logic_vector(31 downto 0);
            words : integer
        ) is
            variable src_addr : integer;
            variable dst_addr : integer;
        begin
            -- (A7) src, (A7) dst - BUG #395: This is the mode WhichAmiga uses!
            alloc_src(words, src_addr);
            alloc_dst(words, dst_addr);
            emit_pmove_mem_pair(reg_sel, reg_name, val_hi, val_lo, words, "(A7)/(A7)", "010", "111", "111", x"0000", x"0000", x"0000", x"0000", src_addr, dst_addr);

            -- (d16,A7) src, (d16,A7) dst
            alloc_src(words, src_addr);
            alloc_dst(words, dst_addr);
            emit_pmove_mem_pair(reg_sel, reg_name, val_hi, val_lo, words, "(d16,A7)/(d16,A7)", "101", "111", "111", x"0010", x"0010", x"0000", x"0000", src_addr, dst_addr);
        end procedure;

        -- ================= MMU stress-suite helpers =================
        -- FC source fields (brief 4:0)
        -- "10001" = immediate FC 1 (user data); "10101" = immediate FC 5
        -- (supervisor data); "01001" = FC in D1; "00000" = FC in SFC.

        -- Emit an F-line MMU instruction: opcode F000|EA, extension word.
        procedure emit_mmu_ea(
            ea_mode : std_logic_vector(2 downto 0);
            ea_reg  : std_logic_vector(2 downto 0);
            brief   : std_logic_vector(15 downto 0)) is
        begin
            emit_word(pc, "1111000000" & ea_mode & ea_reg);
            emit_word(pc, brief);
        end procedure;

        -- MOVE.L An,(xxx).L
        procedure emit_move_l_an_to_abs(an : integer; addr : integer) is
        begin
            emit_word(pc, "0010001111001" & std_logic_vector(to_unsigned(an, 3)));
            emit_word(pc, std_logic_vector(to_unsigned(addr / 65536, 16)));
            emit_word(pc, std_logic_vector(to_unsigned(addr mod 65536, 16)));
        end procedure;

        -- MOVE.L #imm,Dn
        procedure emit_move_imm_dn(dn : integer; v : std_logic_vector(31 downto 0)) is
        begin
            emit_word(pc, "0010" & std_logic_vector(to_unsigned(dn, 3)) & "000111100");
            emit_word(pc, v(31 downto 16));
            emit_word(pc, v(15 downto 0));
        end procedure;

        -- PMOVE MMUSR,(xxx).L into a fresh dst slot + expectation record.
        procedure check_mmusr(desc : string; exp16 : std_logic_vector(15 downto 0)) is
            variable d : integer;
            variable expw : word_array := (others => (others => '0'));
        variable wfc_addr : int_arr := (others => 0);
        variable wfc_val  : fc_exp_arr := (others => "111");
        variable wfc_n    : integer := 0;
        variable rfc_addr : int_arr := (others => 0);
        variable rfc_val  : fc_exp_arr := (others => "111");
        variable rfc_n    : integer := 0;
        begin
            alloc_dst(1, d);
            emit_pmove(pc, REG_MMUSR, DIR_MMU_TO_MEM, "111", "001",
                       std_logic_vector(to_unsigned(d mod 65536, 16)),
                       std_logic_vector(to_unsigned(d / 65536, 16)));
            expw(0) := exp16;
            record_test(desc, d, 1, expw);
        end procedure;

        -- Post-run memory expectation for a descriptor (walker U/M writeback).
        procedure check_desc(desc : string; byte_addr : integer; exp32 : std_logic_vector(31 downto 0)) is
            variable expw : word_array := (others => (others => '0'));
        variable wfc_addr : int_arr := (others => 0);
        variable wfc_val  : fc_exp_arr := (others => "111");
        variable wfc_n    : integer := 0;
        variable rfc_addr : int_arr := (others => 0);
        variable rfc_val  : fc_exp_arr := (others => "111");
        variable rfc_n    : integer := 0;
        begin
            expw(0) := exp32(31 downto 16);
            expw(1) := exp32(15 downto 0);
            record_test(desc, byte_addr, 2, expw);
        end procedure;

        -- PMOVE <reg>,(xxx).L readback + record (32-bit regs).
        procedure check_reg32(desc : string; reg_sel : std_logic_vector(4 downto 0); exp32 : std_logic_vector(31 downto 0)) is
            variable d : integer;
            variable expw : word_array := (others => (others => '0'));
        variable wfc_addr : int_arr := (others => 0);
        variable wfc_val  : fc_exp_arr := (others => "111");
        variable wfc_n    : integer := 0;
        variable rfc_addr : int_arr := (others => 0);
        variable rfc_val  : fc_exp_arr := (others => "111");
        variable rfc_n    : integer := 0;
        begin
            alloc_dst(2, d);
            emit_pmove(pc, reg_sel, DIR_MMU_TO_MEM, "111", "001",
                       std_logic_vector(to_unsigned(d mod 65536, 16)),
                       std_logic_vector(to_unsigned(d / 65536, 16)));
            expw(0) := exp32(31 downto 16);
            expw(1) := exp32(15 downto 0);
            record_test(desc, d, 2, expw);
        end procedure;

        -- PMOVE CRP/SRP,(xxx).L readback + record (64-bit regs).
        procedure check_reg64(desc : string; reg_sel : std_logic_vector(4 downto 0);
                              exp_hi : std_logic_vector(31 downto 0); exp_lo : std_logic_vector(31 downto 0)) is
            variable d : integer;
            variable expw : word_array := (others => (others => '0'));
        variable wfc_addr : int_arr := (others => 0);
        variable wfc_val  : fc_exp_arr := (others => "111");
        variable wfc_n    : integer := 0;
        variable rfc_addr : int_arr := (others => 0);
        variable rfc_val  : fc_exp_arr := (others => "111");
        variable rfc_n    : integer := 0;
        begin
            alloc_dst(4, d);
            emit_pmove(pc, reg_sel, DIR_MMU_TO_MEM, "111", "001",
                       std_logic_vector(to_unsigned(d mod 65536, 16)),
                       std_logic_vector(to_unsigned(d / 65536, 16)));
            expw(0) := exp_hi(31 downto 16); expw(1) := exp_hi(15 downto 0);
            expw(2) := exp_lo(31 downto 16); expw(3) := exp_lo(15 downto 0);
            record_test(desc, d, 4, expw);
        end procedure;

        -- Illegal-form emitter: instruction words + NOP landing pad (the
        -- F-line handler advances the stacked PC by 4; extra words of the
        -- form must themselves be NOPs so any over/undershoot lands safely).
        procedure emit_illegal2(w0 : std_logic_vector(15 downto 0); w1 : std_logic_vector(15 downto 0)) is
        begin
            emit_word(pc, w0);
            emit_word(pc, w1);
            emit_word(pc, x"4E71");
            emit_word(pc, x"4E71");
            emit_word(pc, x"4E71");
        end procedure;
        -- ---- MOVES suite helpers ----
        -- (expectation recorders are declared after the variables they use;
        --  see expect_wfc / expect_rfc below the main variable block)
        procedure emit_moves(
            sz      : std_logic_vector(1 downto 0);   -- 00=B 01=W 10=L
            ea_mode : std_logic_vector(2 downto 0);
            ea_reg  : std_logic_vector(2 downto 0);
            a_reg   : std_logic;                      -- 1 = An, 0 = Dn
            rn      : integer;
            to_mem  : std_logic) is                   -- 1 = Rn->ea (DFC), 0 = ea->Rn (SFC)
        begin
            emit_word(pc, "00001110" & sz & ea_mode & ea_reg);
            emit_word(pc, a_reg & std_logic_vector(to_unsigned(rn, 3)) & to_mem & "00000000000");
        end procedure;

        procedure emit_movec_sfc(dn : integer) is
        begin
            emit_word(pc, x"4E7B");
            emit_word(pc, std_logic_vector(to_unsigned(dn, 4)) & x"000");
        end procedure;

        procedure emit_movec_dfc(dn : integer) is
        begin
            emit_word(pc, x"4E7B");
            emit_word(pc, std_logic_vector(to_unsigned(dn, 4)) & x"001");
        end procedure;

        -- Register an expected FC for the LAST write to / read of a slot.
        procedure expect_wfc(byte_addr : integer; f : std_logic_vector(2 downto 0)) is
        begin
            wfc_addr(wfc_n) := byte_addr;
            wfc_val(wfc_n)  := f;
            wfc_n := wfc_n + 1;
        end procedure;
        procedure expect_rfc(byte_addr : integer; f : std_logic_vector(2 downto 0)) is
        begin
            rfc_addr(rfc_n) := byte_addr;
            rfc_val(rfc_n)  := f;
            rfc_n := rfc_n + 1;
        end procedure;
        -- ============================================================
    begin
        -- Initialize vectors
        memory(0) := x"0000"; memory(1) := x"3F00";  -- SSP (Vec 0 @ $00) - above the dst area
        memory(2) := x"0000"; memory(3) := x"0400";  -- PC (Vec 1 @ $04) -> Start at $0400
        memory(4) := x"0000"; memory(5) := x"0100";  -- Bus Error (Vec 2 @ $08) -> $100
        memory(6) := x"0000"; memory(7) := x"0110";  -- Address Error (Vec 3 @ $0C) -> $110
        memory(8) := x"0000"; memory(9) := x"0220";  -- Illegal Instruction (Vec 4 @ $10) -> counting handler
        memory(10) := x"0000"; memory(11):= x"0130"; -- Div-by-Zero (Vec 5 @ $14) -> $130
        memory(16) := x"0000"; memory(17):= x"0210"; -- Privilege Violation (Vec 8 @ $20) -> counting handler
        memory(28) := x"0000"; memory(29):= x"0150"; -- Format Error (Vec 14 @ $38) -> $150
        memory(112):= x"0000"; memory(113):= x"0160"; -- Vector 56 (MMU Config) @ $E0 -> $160
        -- F-line (vector 11 @ $2C) -> counting skip handler at $0200: the
        -- illegal-form battery expects EXACTLY one increment per form.
        memory(22) := x"0000"; memory(23) := x"0200";
        memory(16#0200#/2) := x"58AF"; memory(16#0202#/2) := x"0002";  -- ADDQ.L #4,(2,A7)
        memory(16#0204#/2) := x"5278"; memory(16#0206#/2) := x"2FE0";  -- ADDQ.W #1,($2FE0).W
        memory(16#0208#/2) := x"4E73";                                 -- RTE
        -- Privilege-violation counting handler at $0210: force S back on in
        -- the stacked SR, skip the privileged instruction, count.
        memory(16#0210#/2) := x"0057"; memory(16#0212#/2) := x"2000";  -- ORI.W #$2000,(A7)
        memory(16#0214#/2) := x"58AF"; memory(16#0216#/2) := x"0002";  -- ADDQ.L #4,(2,A7)
        memory(16#0218#/2) := x"5278"; memory(16#021A#/2) := x"2FE2";  -- ADDQ.W #1,($2FE2).W
        memory(16#021C#/2) := x"4E73";                                 -- RTE
        -- Illegal-instruction counting handler at $0220: skip + count.
        memory(16#0220#/2) := x"58AF"; memory(16#0222#/2) := x"0002";  -- ADDQ.L #4,(2,A7)
        memory(16#0224#/2) := x"5278"; memory(16#0226#/2) := x"2FE4";  -- ADDQ.W #1,($2FE4).W
        memory(16#0228#/2) := x"4E73";                                 -- RTE

        -- Handlers (STOP #$2700 + ID)
        memory(16#100#/2) := x"4E72"; memory(16#102#/2) := x"2700"; -- Bus Error
        memory(16#110#/2) := x"4E72"; memory(16#112#/2) := x"2701"; -- Address Error
        memory(16#120#/2) := x"4E72"; memory(16#122#/2) := x"2702"; -- Illegal
        memory(16#130#/2) := x"4E72"; memory(16#132#/2) := x"2703"; -- DivZero
        memory(16#140#/2) := x"4E72"; memory(16#142#/2) := x"2704"; -- Priv
        memory(16#150#/2) := x"4E72"; memory(16#152#/2) := x"2705"; -- Format
        memory(16#160#/2) := x"4E72"; memory(16#162#/2) := x"2706"; -- MMU Config

        -- Clear code + source data area
        for i in 16#1000# to 16#27FF# loop
            memory(i) := x"0000";
        end loop;
        -- Pre-fill destination area with $DEAD sentinel so that tests prove
        -- PMOVE actually writes (not just reading back pre-existing zeros).
        -- alloc_dst hands out BYTE addresses $2800+, i.e. WORD indices $1400+.
        for i in 16#1400# to 16#17FF# loop
            memory(i) := x"DEAD";
        end loop;
        memory(16#2FE0#/2) := x"0000";  -- F-line hit counter (cleared after sentinel fill)
        memory(16#2FE2#/2) := x"0000";  -- privilege-violation counter
        memory(16#2FE4#/2) := x"0000";  -- illegal-instruction counter

        -- 3-level page tables for the walking phases (TC geometry PS=12,
        -- IS=0, TIA=8, TIB=7, TIC=5, TID=0; E stays 0 - MC68030 executes
        -- PTEST/PLOAD regardless of TC.E). All test LAs use root[0]/B[0].
        write_long(16#8000#, x"00008402");  -- root[0] -> B table
        write_long(16#8400#, x"00008802");  -- B[0] -> C table
        write_long(16#8814#, x"0000F001");  -- C[5]  LA $05000 valid (abs.W reachable)
        write_long(16#8840#, x"0000A001");  -- C[16] LA $10000 valid
        write_long(16#8844#, x"0000B005");  -- C[17] LA $11000 write-protected
        write_long(16#8848#, x"00000000");  -- C[18] LA $12000 invalid
        write_long(16#884C#, x"0000C001");  -- C[19] LA $13000 valid
        write_long(16#8850#, x"0000D001");  -- C[20] LA $14000 valid
        write_long(16#8854#, x"0000E001");  -- C[21] LA $15000 valid
        write_long(16#8858#, x"00012001");  -- C[22] LA $16000 valid
        write_long(16#885C#, x"00013001");  -- C[23] LA $17000 valid (PTEST-purity: never PLOADed)

        -- Program starts at $0400
        pc := 16#0400#;

        -- Set D6 index for (d8,An,Xn)
        emit_moveq(pc, 6, 4);

        -- =====================================================================
        -- P0: canaries + FC registers + MMU-register baselines for trash checks
        -- =====================================================================
        emit_move_imm_dn(2, x"D2D2C0DE");
        emit_move_imm_dn(3, x"D3D3C0DE");
        emit_move_imm_dn(4, x"D4D4C0DE");
        emit_move_imm_dn(5, x"D5D5C0DE");
        emit_move_imm_dn(7, x"D7D7C0DE");
        emit_movea(pc, 4, x"A4A4C0DE");
        emit_movea(pc, 5, x"A5A5C0DE");
        emit_movea(pc, 6, x"A6A6C0DE");
        emit_moveq(pc, 6, 4);                       -- D6 = (d8,An,Xn) index
        emit_move_imm_dn(0, x"00000001");
        emit_movec_sfc(0);                          -- SFC = 1
        emit_movec_dfc(0);                          -- DFC = 1
        alloc_src(2, t_src); write_long(t_src, x"00895ABC");
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_src, 32)));
        emit_pmove(pc, REG_TC, DIR_MEM_TO_MMU, "010", "000", x"0000", x"0000");
        alloc_src(2, t_src); write_long(t_src, x"76540210");
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_src, 32)));
        emit_pmove(pc, REG_TT0, DIR_MEM_TO_MMU, "010", "000", x"0000", x"0000");

        -- =====================================================================
        -- P1: MOVES writes (Rn -> ea): all modes/sizes, DFC=1 on every cycle
        -- =====================================================================
        emit_move_imm_dn(1, x"A55A0FF0");
        emit_movea(pc, 3, x"0BADCAFE");
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("10", "010", "000", '0', 1, '1');                     -- MOVES.L D1,(A0)
        expw := (others => (others => '0')); expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("P1 MOVES.L D1,(A0)", t_d0, 2, expw);
        expect_wfc(t_d0, "001");
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("01", "010", "000", '0', 1, '1');                     -- MOVES.W D1,(A0)
        expw(0) := x"0FF0"; expw(1) := x"DEAD";
        record_test("P1 MOVES.W D1,(A0)", t_d0, 2, expw);
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("00", "010", "000", '0', 1, '1');                     -- MOVES.B D1,(A0) even
        expw(0) := x"F0AD"; expw(1) := x"DEAD";
        record_test("P1 MOVES.B even", t_d0, 2, expw);
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0 + 1, 32)));
        emit_moves("00", "010", "000", '0', 1, '1');                     -- MOVES.B D1,(A0) odd
        expw(0) := x"DEF0"; expw(1) := x"DEAD";
        record_test("P1 MOVES.B odd", t_d0, 2, expw);
        alloc_dst(2, t_d0); alloc_dst(2, t_d1);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("10", "011", "000", '0', 1, '1');                     -- MOVES.L D1,(A0)+
        emit_move_l_an_to_abs(0, t_d1);
        expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("P1 MOVES.L (A0)+ value", t_d0, 2, expw);
        expw(0) := std_logic_vector(to_unsigned((t_d0 + 4) / 65536, 16));
        expw(1) := std_logic_vector(to_unsigned((t_d0 + 4) mod 65536, 16));
        record_test("P1 (A0)+ pointer advanced +4", t_d1, 2, expw);
        alloc_dst(2, t_d0); alloc_dst(2, t_d1);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0 + 4, 32)));
        emit_moves("10", "100", "000", '0', 1, '1');                     -- MOVES.L D1,-(A0)
        emit_move_l_an_to_abs(0, t_d1);
        expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("P1 MOVES.L -(A0) value", t_d0, 2, expw);
        expw(0) := std_logic_vector(to_unsigned(t_d0 / 65536, 16));
        expw(1) := std_logic_vector(to_unsigned(t_d0 mod 65536, 16));
        record_test("P1 -(A0) pointer decremented -4", t_d1, 2, expw);
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0 - 16, 32)));
        emit_moves("10", "101", "000", '0', 1, '1'); emit_word(pc, x"0010");  -- (d16,A0)
        expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("P1 MOVES.L (d16,A0)", t_d0, 2, expw);
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0 - 6, 32)));
        emit_moves("10", "110", "000", '0', 1, '1'); emit_word(pc, x"6002");  -- (d8,A0,D6)
        record_test("P1 MOVES.L (d8,A0,D6)", t_d0, 2, expw);
        alloc_dst(2, t_d0);
        emit_moves("10", "111", "000", '0', 1, '1');
        emit_word(pc, std_logic_vector(to_unsigned(t_d0, 16)));               -- (xxx).W
        record_test("P1 MOVES.L (xxx).W", t_d0, 2, expw);
        alloc_dst(2, t_d0);
        emit_moves("10", "111", "001", '0', 1, '1');
        emit_word(pc, std_logic_vector(to_unsigned(t_d0 / 65536, 16)));
        emit_word(pc, std_logic_vector(to_unsigned(t_d0 mod 65536, 16)));     -- (xxx).L
        record_test("P1 MOVES.L (xxx).L", t_d0, 2, expw);
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("10", "010", "000", '1', 3, '1');                     -- MOVES.L A3,(A0)
        expw(0) := x"0BAD"; expw(1) := x"CAFE";
        record_test("P1 MOVES.L A3,(A0) A-source", t_d0, 2, expw);
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("01", "010", "000", '1', 3, '1');                     -- MOVES.W A3,(A0)
        expw(0) := x"CAFE"; expw(1) := x"DEAD";
        record_test("P1 MOVES.W A3,(A0) A-source", t_d0, 2, expw);

        -- =====================================================================
        -- P2: MOVES reads (ea -> Rn): partial-register merge, An sign-extend,
        -- pointer updates, all modes; SFC=1 on every cycle
        -- =====================================================================
        alloc_src(2, t_s0); write_long(t_s0, x"12345678");
        alloc_src(1, t_s1); write_word(t_s1, x"8000");
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_s0, 32)));
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_s1, 32)));
        emit_move_imm_dn(1, x"FFFFFFFF");
        emit_moves("00", "010", "000", '0', 1, '0');                     -- MOVES.B (A0),D1
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"FFFF"; expw(1) := x"FF12";
        record_test("P2 MOVES.B read merges low byte", t_d0, 2, expw);
        emit_move_imm_dn(1, x"FFFFFFFF");
        emit_moves("01", "010", "000", '0', 1, '0');                     -- MOVES.W (A0),D1
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"FFFF"; expw(1) := x"1234";
        record_test("P2 MOVES.W read merges low word", t_d0, 2, expw);
        emit_moves("10", "010", "000", '0', 1, '0');                     -- MOVES.L (A0),D1
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"1234"; expw(1) := x"5678";
        record_test("P2 MOVES.L read full", t_d0, 2, expw);
        expect_rfc(t_s0, "001");
        emit_moves("00", "010", "001", '1', 3, '0');                     -- MOVES.B (A1),A3
        alloc_dst(2, t_d0); emit_move_l_an_to_abs(3, t_d0);
        expw(0) := x"FFFF"; expw(1) := x"FF80";
        record_test("P2 MOVES.B to An SIGN-EXTENDS", t_d0, 2, expw);
        expect_rfc(t_s1, "001");
        emit_moves("01", "010", "001", '1', 3, '0');                     -- MOVES.W (A1),A3
        alloc_dst(2, t_d0); emit_move_l_an_to_abs(3, t_d0);
        expw(0) := x"FFFF"; expw(1) := x"8000";
        record_test("P2 MOVES.W to An SIGN-EXTENDS", t_d0, 2, expw);
        expect_rfc(t_s1, "001");
        emit_moves("10", "010", "000", '1', 3, '0');                     -- MOVES.L (A0),A3
        alloc_dst(2, t_d0); emit_move_l_an_to_abs(3, t_d0);
        expw(0) := x"1234"; expw(1) := x"5678";
        record_test("P2 MOVES.L to An full", t_d0, 2, expw);
        emit_moves("10", "011", "000", '0', 1, '0');                     -- MOVES.L (A0)+,D1
        alloc_dst(2, t_d0); emit_move_l_an_to_abs(0, t_d0);
        expw(0) := std_logic_vector(to_unsigned((t_s0 + 4) / 65536, 16));
        expw(1) := std_logic_vector(to_unsigned((t_s0 + 4) mod 65536, 16));
        record_test("P2 read (A0)+ pointer +4", t_d0, 2, expw);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_s0 + 4, 32)));
        emit_moves("10", "100", "000", '0', 1, '0');                     -- MOVES.L -(A0),D1
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"1234"; expw(1) := x"5678";
        record_test("P2 read -(A0) value", t_d0, 2, expw);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_s0 - 16, 32)));
        emit_moves("10", "101", "000", '0', 1, '0'); emit_word(pc, x"0010");
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        record_test("P2 read (d16,A0)", t_d0, 2, expw);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_s0 - 6, 32)));
        emit_moves("10", "110", "000", '0', 1, '0'); emit_word(pc, x"6002");
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        record_test("P2 read (d8,A0,D6)", t_d0, 2, expw);
        emit_moves("10", "111", "000", '0', 1, '0');
        emit_word(pc, std_logic_vector(to_unsigned(t_s0, 16)));
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        record_test("P2 read (xxx).W", t_d0, 2, expw);
        emit_moves("10", "111", "001", '0', 1, '0');
        emit_word(pc, std_logic_vector(to_unsigned(t_s0 / 65536, 16)));
        emit_word(pc, std_logic_vector(to_unsigned(t_s0 mod 65536, 16)));
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        record_test("P2 read (xxx).L", t_d0, 2, expw);

        -- =====================================================================
        -- P3: exotic-FC discipline - SFC=2, DFC=3; every MOVES cycle must
        -- carry them, and NOTHING else in the whole run may.
        -- =====================================================================
        emit_move_imm_dn(0, x"00000002"); emit_movec_sfc(0);
        emit_move_imm_dn(0, x"00000003"); emit_movec_dfc(0);
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("10", "010", "000", '0', 1, '1');                     -- write under DFC=3  [fc3w+2]
        expw(0) := x"1234"; expw(1) := x"5678";
        record_test("P3 MOVES.L write under DFC=3", t_d0, 2, expw);
        expect_wfc(t_d0, "011");
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("10", "010", "000", '0', 1, '1');                     -- [fc3w+2]
        record_test("P3 second DFC=3 write", t_d0, 2, expw);
        expect_wfc(t_d0, "011");
        alloc_src(2, t_s2); write_long(t_s2, x"0FC0FFEE");
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_s2, 32)));
        emit_moves("10", "010", "001", '0', 1, '0');                     -- read under SFC=2  [fc2r+2]
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"0FC0"; expw(1) := x"FFEE";
        record_test("P3 MOVES.L read under SFC=2", t_d0, 2, expw);
        expect_rfc(t_s2, "010");
        emit_moves("10", "010", "001", '0', 1, '0');                     -- [fc2r+2]
        record_test("P3 second SFC=2 read", t_d0, 2, expw);
        emit_move_imm_dn(0, x"00000001");
        emit_movec_sfc(0); emit_movec_dfc(0);                            -- back to 1/1

        -- =====================================================================
        -- P4: privilege enforcement - MOVES and MOVEC from user mode take
        -- privilege violations and perform NO access.
        -- =====================================================================
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_word(pc, x"027C"); emit_word(pc, x"DFFF");                  -- ANDI.W #$DFFF,SR (drop S)
        emit_moves("10", "010", "000", '0', 1, '1');                     -- priv violation #1 (skipped)
        emit_word(pc, x"4E71"); emit_word(pc, x"4E71");
        emit_word(pc, x"027C"); emit_word(pc, x"DFFF");                  -- drop S again
        emit_movec_sfc(0);                                               -- priv violation #2 (skipped)
        emit_word(pc, x"4E71"); emit_word(pc, x"4E71");
        expw(0) := x"DEAD"; expw(1) := x"DEAD";
        record_test("P4 user MOVES performed no write", t_d0, 2, expw);
        expw := (others => (others => '0')); expw(0) := x"0002";
        record_test("P4 privilege violations = 2", 16#2FE2#, 1, expw);

        -- =====================================================================
        -- P5: illegal EA battery - Dn, An, (d16,PC), #imm F-line... no:
        -- MOVES illegal EAs take ILLEGAL INSTRUCTION (vector 4).
        -- =====================================================================
        emit_word(pc, x"0E80"); emit_word(pc, x"1800");                  -- MOVES.L Dn-EA
        emit_word(pc, x"4E71"); emit_word(pc, x"4E71"); emit_word(pc, x"4E71");
        emit_word(pc, x"0E88"); emit_word(pc, x"1800");                  -- An-EA
        emit_word(pc, x"4E71"); emit_word(pc, x"4E71"); emit_word(pc, x"4E71");
        emit_word(pc, x"0EBA"); emit_word(pc, x"1800");                  -- (d16,PC)
        emit_word(pc, x"4E71"); emit_word(pc, x"4E71"); emit_word(pc, x"4E71");
        emit_word(pc, x"0EBC"); emit_word(pc, x"1800");                  -- #imm
        emit_word(pc, x"4E71"); emit_word(pc, x"4E71"); emit_word(pc, x"4E71");
        expw := (others => (others => '0')); expw(0) := x"0004";
        record_test("P5 illegal-EA traps = 4", 16#2FE4#, 1, expw);

        -- =====================================================================
        -- P6: back-to-back stress
        -- =====================================================================
        -- 6a: four consecutive MOVES.L writes (SFC/DFC=1)
        emit_move_imm_dn(1, x"A55A0FF0");
        alloc_dst(2, t_d0); alloc_dst(2, t_d1);
        alloc_dst(2, t_s0); alloc_dst(2, t_s1);   -- reuse as dst slots 3/4
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_d1, 32)));
        emit_movea(pc, 2, std_logic_vector(to_unsigned(t_s0, 32)));
        emit_movea(pc, 3, std_logic_vector(to_unsigned(t_s1, 32)));
        emit_moves("10", "010", "000", '0', 1, '1');
        emit_moves("10", "010", "001", '0', 1, '1');
        emit_moves("10", "010", "010", '0', 1, '1');
        emit_moves("10", "010", "011", '0', 1, '1');
        expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("6a b2b write 1", t_d0, 2, expw);
        record_test("6a b2b write 2", t_d1, 2, expw);
        record_test("6a b2b write 3", t_s0, 2, expw);
        record_test("6a b2b write 4", t_s1, 2, expw);
        expect_wfc(t_s1, "001");
        -- 6b: read/write ping-pong copies
        alloc_src(2, t_s0); write_long(t_s0, x"C0DE0001");
        alloc_src(2, t_s1); write_long(t_s1, x"C0DE0002");
        alloc_dst(2, t_d0); alloc_dst(2, t_d1);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_s0, 32)));
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_movea(pc, 2, std_logic_vector(to_unsigned(t_s1, 32)));
        emit_movea(pc, 3, std_logic_vector(to_unsigned(t_d1, 32)));
        emit_moves("10", "010", "000", '0', 1, '0');
        emit_moves("10", "010", "001", '0', 1, '1');
        emit_moves("10", "010", "010", '0', 1, '0');
        emit_moves("10", "010", "011", '0', 1, '1');
        expw(0) := x"C0DE"; expw(1) := x"0001";
        record_test("6b ping-pong copy 1", t_d0, 2, expw);
        expw(1) := x"0002";
        record_test("6b ping-pong copy 2", t_d1, 2, expw);
        -- 6c: size alternation b2b into one region (reload D1 - 6b's reads
        -- deliberately clobbered it)
        emit_move_imm_dn(1, x"A55A0FF0");
        alloc_dst(4, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_d0 + 2, 32)));
        emit_movea(pc, 2, std_logic_vector(to_unsigned(t_d0 + 4, 32)));
        emit_moves("00", "010", "000", '0', 1, '1');                     -- .B -> $F0AD
        emit_moves("01", "010", "001", '0', 1, '1');                     -- .W -> $0FF0
        emit_moves("10", "010", "010", '0', 1, '1');                     -- .L
        expw(0) := x"F0AD"; expw(1) := x"0FF0"; expw(2) := x"A55A"; expw(3) := x"0FF0";
        record_test("6c size alternation B/W/L", t_d0, 4, expw);
        -- 6d: MOVEC DFC interleave - the new DFC applies to the NEXT MOVES
        alloc_dst(2, t_d0); alloc_dst(2, t_d1);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_d1, 32)));
        emit_moves("10", "010", "000", '0', 1, '1');                     -- DFC=1
        emit_move_imm_dn(0, x"00000003");
        emit_movec_dfc(0);
        emit_moves("10", "010", "001", '0', 1, '1');                     -- DFC=3  [fc3w+2]
        expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("6d DFC switch write 1", t_d0, 2, expw);
        record_test("6d DFC switch write 2", t_d1, 2, expw);
        expect_wfc(t_d0, "001");
        expect_wfc(t_d1, "011");
        -- 6e: FC REVERSION on the very next normal write
        alloc_dst(2, t_d0); alloc_dst(2, t_d1);
        emit_movea(pc, 2, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_movea(pc, 3, std_logic_vector(to_unsigned(t_d1, 32)));
        emit_moves("10", "010", "010", '0', 1, '1');                     -- MOVES DFC=3  [fc3w+2]
        emit_word(pc, x"2681");                                          -- MOVE.L D1,(A3) normal
        expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("6e MOVES write", t_d0, 2, expw);
        record_test("6e normal write after MOVES", t_d1, 2, expw);
        expect_wfc(t_d0, "011");
        expect_wfc(t_d1, "101");                                         -- MUST revert to FC5
        -- 6f: FC REVERSION on the very next normal read
        emit_move_imm_dn(0, x"00000002"); emit_movec_sfc(0);             -- SFC=2
        alloc_src(2, t_s0); write_long(t_s0, x"0DEC0DE1");
        alloc_src(2, t_s1); write_long(t_s1, x"0DEC0DE2");
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_s0, 32)));
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_s1, 32)));
        emit_moves("10", "010", "000", '0', 1, '0');                     -- MOVES read SFC=2 [fc2r+2]
        emit_word(pc, x"2011");                                          -- MOVE.L (A1),D0 normal
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"0DEC"; expw(1) := x"0DE2";
        record_test("6f normal read value after MOVES", t_d0, 2, expw);
        expect_rfc(t_s0, "010");
        expect_rfc(t_s1, "101");                                         -- MUST revert to FC5
        -- 6g: streaming (An)+ x4 (the zeropage shape)  [fc3w+8]
        emit_move_imm_dn(1, x"A55A0FF0");
        alloc_dst(4, t_d0); alloc_dst(4, t_d1);                          -- 16 contiguous bytes
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_moves("10", "011", "000", '0', 1, '1');
        emit_moves("10", "011", "000", '0', 1, '1');
        emit_moves("10", "011", "000", '0', 1, '1');
        emit_moves("10", "011", "000", '0', 1, '1');
        alloc_dst(2, t_s0); emit_move_l_an_to_abs(0, t_s0);
        expw(0) := x"A55A"; expw(1) := x"0FF0"; expw(2) := x"A55A"; expw(3) := x"0FF0";
        record_test("6g stream words 0-3", t_d0, 4, expw);
        record_test("6g stream words 4-7", t_d1, 4, expw);
        expw := (others => (others => '0'));
        expw(0) := std_logic_vector(to_unsigned((t_d0 + 16) / 65536, 16));
        expw(1) := std_logic_vector(to_unsigned((t_d0 + 16) mod 65536, 16));
        record_test("6g stream pointer +16", t_s0, 2, expw);
        expect_wfc(t_d0, "011");
        expect_wfc(t_d1, "011");
        -- 6h: descending -(An) x4  [fc3w+8]
        alloc_dst(4, t_d0); alloc_dst(4, t_d1);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d1 + 8, 32)));
        emit_moves("10", "100", "000", '0', 1, '1');
        emit_moves("10", "100", "000", '0', 1, '1');
        emit_moves("10", "100", "000", '0', 1, '1');
        emit_moves("10", "100", "000", '0', 1, '1');
        alloc_dst(2, t_s0); emit_move_l_an_to_abs(0, t_s0);
        expw(0) := x"A55A"; expw(1) := x"0FF0"; expw(2) := x"A55A"; expw(3) := x"0FF0";
        record_test("6h descend words 0-3", t_d0, 4, expw);
        record_test("6h descend words 4-7", t_d1, 4, expw);
        expw := (others => (others => '0'));
        expw(0) := std_logic_vector(to_unsigned(t_d0 / 65536, 16));
        expw(1) := std_logic_vector(to_unsigned(t_d0 mod 65536, 16));
        record_test("6h descend pointer -16", t_s0, 2, expw);
        -- 6i: shared-register hazard chain  [fc2r+4, fc3w+4]
        alloc_src(2, t_s0); write_long(t_s0, x"11112222");
        alloc_src(2, t_s1);                                              -- written by the chain
        alloc_src(2, t_s2); write_long(t_s2, x"33334444");
        alloc_src(2, t_s3);                                              -- written by the chain
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_s0, 32)));
        emit_moves("10", "011", "000", '0', 1, '0');                     -- MOVES.L (A0)+,D1
        emit_moves("10", "011", "000", '0', 1, '1');                     -- MOVES.L D1,(A0)+
        emit_moves("10", "011", "000", '0', 1, '0');
        emit_moves("10", "011", "000", '0', 1, '1');
        expw(0) := x"1111"; expw(1) := x"2222";
        record_test("6i hazard copy 1", t_s1, 2, expw);
        expw(0) := x"3333"; expw(1) := x"4444";
        record_test("6i hazard copy 2", t_s3, 2, expw);
        -- 6k: same-address size stack (DFC=3; reload D1 after 6i)  [fc3w+4]
        emit_move_imm_dn(1, x"A55A0FF0");
        alloc_dst(2, t_d0);
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_move_imm_dn(0, x"000000EE");
        emit_moves("10", "010", "000", '0', 1, '1');                     -- .L $A55A0FF0
        emit_moves("01", "010", "000", '0', 0, '1');                     -- .W D0 -> $00EE
        emit_moves("00", "010", "000", '0', 0, '1');                     -- .B D0 -> byte $EE
        expw(0) := x"EEEE"; expw(1) := x"0FF0";
        record_test("6k same-addr L/W/B stack", t_d0, 2, expw);
        -- 6l: cross-class interleave with PMOVE  [fc3w+2, fc2r+2]
        alloc_dst(2, t_d0);
        alloc_dst(2, t_d1);
        alloc_src(2, t_s0); write_long(t_s0, x"5EED0BAD");
        emit_movea(pc, 0, std_logic_vector(to_unsigned(t_d0, 32)));
        emit_movea(pc, 1, std_logic_vector(to_unsigned(t_d1, 32)));
        emit_movea(pc, 2, std_logic_vector(to_unsigned(t_s0, 32)));
        emit_pmove(pc, REG_TT0, DIR_MMU_TO_MEM, "010", "000", x"0000", x"0000");  -- PMOVE TT0,(A0)
        emit_moves("10", "010", "001", '0', 1, '1');                              -- MOVES.L D1,(A1)
        emit_pmove(pc, REG_TT0, DIR_MEM_TO_MMU, "010", "000", x"0000", x"0000");  -- PMOVE (A0),TT0
        emit_moves("10", "010", "010", '0', 1, '0');                              -- MOVES.L (A2),D1
        alloc_dst(2, t_s1); emit_move_l_dn_to_abs(pc, 1, std_logic_vector(to_unsigned(t_s1, 32)));
        expw(0) := x"7654"; expw(1) := x"0210";
        record_test("6l PMOVE TT0 dump amid MOVES", t_d0, 2, expw);
        expw(0) := x"A55A"; expw(1) := x"0FF0";
        record_test("6l MOVES write amid PMOVEs", t_d1, 2, expw);
        expw(0) := x"5EED"; expw(1) := x"0BAD";
        record_test("6l MOVES read amid PMOVEs", t_s1, 2, expw);

        -- =====================================================================
        -- P7: trash checks
        -- =====================================================================
        check_reg32("P7 TC survived MOVES storm",  REG_TC,  x"00895ABC");
        check_reg32("P7 TT0 survived (6l rewrote same value)", REG_TT0, x"76540210");
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 2, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"D2D2"; expw(1) := x"C0DE";
        record_test("P7 canary D2", t_d0, 2, expw);
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 3, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"D3D3"; record_test("P7 canary D3", t_d0, 2, expw);
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 4, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"D4D4"; record_test("P7 canary D4", t_d0, 2, expw);
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 5, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"D5D5"; record_test("P7 canary D5", t_d0, 2, expw);
        alloc_dst(2, t_d0); emit_move_l_dn_to_abs(pc, 7, std_logic_vector(to_unsigned(t_d0, 32)));
        expw(0) := x"D7D7"; record_test("P7 canary D7", t_d0, 2, expw);
        alloc_dst(2, t_d0); emit_move_l_an_to_abs(4, t_d0);
        expw(0) := x"A4A4"; record_test("P7 canary A4", t_d0, 2, expw);
        alloc_dst(2, t_d0); emit_move_l_an_to_abs(5, t_d0);
        expw(0) := x"A5A5"; record_test("P7 canary A5", t_d0, 2, expw);
        alloc_dst(2, t_d0); emit_move_l_an_to_abs(6, t_d0);
        expw(0) := x"A6A6"; record_test("P7 canary A6", t_d0, 2, expw);
        alloc_dst(1, t_d0);
        expw := (others => (others => '0')); expw(0) := x"DEAD";
        record_test("P7 untouched dst sentinel", t_d0, 1, expw);

        -- STOP
        emit_word(pc, x"4E72");
        emit_word(pc, x"2700");

        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("MMU INSTRUCTION STRESS SUITE"));
        writeline(output, l);
        write(l, string'("Tests: (A1)/(A0), (d16,A1/A0), (d8,A1/A0,D6), (xxx).W, (xxx).L"));
        writeline(output, l);
        write(l, string'("SP modes: (A7), (d16,A7) - validates WhichAmiga PMOVE.L (SP),TC"));
        writeline(output, l);
        write(l, string'("Regs: TC, TT0, TT1, CRP, SRP, MMUSR ($0040 via PTEST T-bit)"));
        writeline(output, l);
        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("CODE @ $0448-$0458: "));
        write(l, slv16_to_hex(memory(16#0448#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#044A#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#044C#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#044E#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#0450#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#0452#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#0454#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#0456#/2)) & string'(" "));
        write(l, slv16_to_hex(memory(16#0458#/2)));
        writeline(output, l);
        write(l, string'("ROM DECODE (from $0400):"));
        writeline(output, l);
        -- Decode the program built in memory
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

        -- Run simulation (cap runtime)
        wait for 1500 us;
        if exec_seen = '0' then
            write(l, string'("FAIL: No EXEC observed (core never executed any instruction)"));
            writeline(output, l);
            fail_count := fail_count + 1;
        end if;
        test_done <= '1';

        -- Check results (skip if we already detected a bad PC)
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

        -- FC-shadow comparisons (write side)
        for i in 0 to wfc_n-1 loop
            if fc_shadow_w(wfc_addr(i)/2 - 16#1400#) = wfc_val(i) then
                pass_count := pass_count + 1;
            else
                fail_count := fail_count + 1;
                write(l, string'("FAIL WFC @$") & slv32_to_hex(std_logic_vector(to_unsigned(wfc_addr(i), 32))));
                write(l, string'(" expected fc=") & integer'image(to_integer(unsigned(wfc_val(i)))));
                write(l, string'(" got fc=") & integer'image(to_integer(unsigned(fc_shadow_w(wfc_addr(i)/2 - 16#1400#)))));
                writeline(output, l);
            end if;
        end loop;
        -- FC-shadow comparisons (read side)
        for i in 0 to rfc_n-1 loop
            if fc_shadow_r(rfc_addr(i)/2 - 16#1200#) = rfc_val(i) then
                pass_count := pass_count + 1;
            else
                fail_count := fail_count + 1;
                write(l, string'("FAIL RFC @$") & slv32_to_hex(std_logic_vector(to_unsigned(rfc_addr(i), 32))));
                write(l, string'(" expected fc=") & integer'image(to_integer(unsigned(rfc_val(i)))));
                write(l, string'(" got fc=") & integer'image(to_integer(unsigned(fc_shadow_r(rfc_addr(i)/2 - 16#1200#)))));
                writeline(output, l);
            end if;
        end loop;
        -- Exotic-FC discipline: exact counts, zero tolerance for leaks.
        if fc3_write_count = 34 then pass_count := pass_count + 1; else
            fail_count := fail_count + 1;
            write(l, string'("FAIL FC3-WRITE count=") & integer'image(fc3_write_count) & string'(" expected 34"));
            writeline(output, l);
        end if;
        if fc2_read_count = 12 then pass_count := pass_count + 1; else
            fail_count := fail_count + 1;
            write(l, string'("FAIL FC2-READ count=") & integer'image(fc2_read_count) & string'(" expected 12"));
            writeline(output, l);
        end if;
        if fc3_read_count = 0 then pass_count := pass_count + 1; else
            fail_count := fail_count + 1;
            write(l, string'("FAIL FC3-READ leak count=") & integer'image(fc3_read_count));
            writeline(output, l);
        end if;
        if fc3_fetch_count = 0 then pass_count := pass_count + 1; else
            fail_count := fail_count + 1;
            write(l, string'("FAIL FC3-FETCH leak count=") & integer'image(fc3_fetch_count));
            writeline(output, l);
        end if;

        write(l, string'("=============================================="));
        writeline(output, l);
        write(l, string'("SUMMARY"));
        writeline(output, l);
        write(l, string'("Passed: ") & integer'image(pass_count));
        writeline(output, l);
        write(l, string'("Failed: ") & integer'image(fail_count));
        writeline(output, l);
        write(l, string'("=============================================="));
        writeline(output, l);

        test_failures <= fail_count;
        wait for 0 ns;
        assert fail_count = 0
            report "tb_moves_stress failed" severity failure;
        wait;
    end process;

end behavioral;
