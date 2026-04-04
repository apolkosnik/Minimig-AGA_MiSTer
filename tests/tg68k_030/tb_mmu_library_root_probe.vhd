-- tb_mmu_library_root_probe.vhd
-- Focused MMU-library-style root pointer probe regression.
--
-- Covers the MC68030 PMMU roundtrip pattern that uses:
--   MOVE.L   #$80000002,(SP)
--   PMOVE.Q  CRP,(8,SP)
--   PMOVE.Q  (SP),CRP
-- and the same sequence for SRP.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_library_root_probe is
end entity;

architecture behavior of tb_mmu_library_root_probe is
    signal clk        : std_logic := '0';
    signal nReset     : std_logic := '0';
    signal clkena_in  : std_logic := '1';
    signal data_in    : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal busstate   : std_logic_vector(1 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    constant REG_SRP    : std_logic_vector(4 downto 0) := "10010";
    constant REG_CRP    : std_logic_vector(4 downto 0) := "10011";
    constant DIR_MEM_TO_MMU : std_logic := '0';
    constant DIR_MMU_TO_MEM : std_logic := '1';

    constant CRP_HI     : std_logic_vector(31 downto 0) := x"80000002";
    constant CRP_LO     : std_logic_vector(31 downto 0) := x"00012340";
    constant SRP_HI     : std_logic_vector(31 downto 0) := x"80000002";
    constant SRP_LO     : std_logic_vector(31 downto 0) := x"00056780";
    constant SENTINEL   : std_logic_vector(31 downto 0) := x"DEADBEEF";

    constant CRP_SRC_ADDR    : integer := 16#2800#;
    constant CRP_SAVE_ADDR   : integer := 16#2808#;
    constant SRP_SRC_ADDR    : integer := 16#2820#;
    constant SRP_SAVE_ADDR   : integer := 16#2828#;
    constant CRP_RESULT_ADDR : integer := 16#2A00#;
    constant SRP_RESULT_ADDR : integer := 16#2A10#;

    type mem_array_t is array (0 to 16383) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

    signal test_done    : boolean := false;
    signal stop_reached : boolean := false;

    procedure emit_word(variable pc : inout integer; w : std_logic_vector(15 downto 0)) is
    begin
        mem(pc / 2) := w;
        pc := pc + 2;
    end procedure;

    procedure emit_long(variable pc : inout integer; v : std_logic_vector(31 downto 0)) is
    begin
        emit_word(pc, v(31 downto 16));
        emit_word(pc, v(15 downto 0));
    end procedure;

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
        opcode := "1111000000" & ea_mode & ea_reg;
        extension := "0" & reg_sel & direction & "000000000";
        emit_word(pc, opcode);
        emit_word(pc, extension);
        case ea_mode is
            when "101" =>
                emit_word(pc, disp_or_addr);
            when "111" =>
                if ea_reg = "000" then
                    emit_word(pc, disp_or_addr);
                elsif ea_reg = "001" then
                    emit_word(pc, addr_hi);
                    emit_word(pc, disp_or_addr);
                end if;
            when others =>
                null;
        end case;
    end procedure;

    procedure emit_pflusha(variable pc : inout integer) is
    begin
        emit_word(pc, x"F000");
        emit_word(pc, x"2400");
    end procedure;

    procedure write_long(addr : integer; v : std_logic_vector(31 downto 0)) is
    begin
        mem(addr / 2) := v(31 downto 16);
        mem(addr / 2 + 1) := v(15 downto 0);
    end procedure;

    impure function read_long(addr : integer) return std_logic_vector is
    begin
        return mem(addr / 2) & mem(addr / 2 + 1);
    end function;

    function slv32_to_hex(v : std_logic_vector(31 downto 0)) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable s : string(1 to 8);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to 7 loop
            nibble := v(31 - i * 4 downto 28 - i * 4);
            s(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return s;
    end function;

    procedure check_long(
        constant test_name : in string;
        constant addr      : in integer;
        constant expected  : in std_logic_vector(31 downto 0);
        variable pass_cnt  : inout integer;
        variable fail_cnt  : inout integer
    ) is
        variable actual : std_logic_vector(31 downto 0);
    begin
        actual := read_long(addr);
        if actual = expected then
            report "PASS: " & test_name severity note;
            pass_cnt := pass_cnt + 1;
        else
            report "FAIL: " & test_name &
                   " expected=$" & slv32_to_hex(expected) &
                   " got=$" & slv32_to_hex(actual) severity error;
            fail_cnt := fail_cnt + 1;
        end if;
    end procedure;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 2,
            extAddr_Mode   => 2,
            MUL_Mode       => 2,
            DIV_Mode       => 2,
            BitField       => 2,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",
            addr_out => addr_out,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            longword => open,
            nResetOut => open,
            FC => open,
            clr_berr => open,
            skipFetch => open,
            regin_out => open,
            CACR_out => open,
            VBR_out => open,
            cache_inv_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr => open,
            pmmu_reg_we => open,
            pmmu_reg_re => open,
            pmmu_reg_sel => open,
            pmmu_reg_wdat => open,
            pmmu_reg_part => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req => open,
            pmmu_walker_we => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 16383 else x"4E71";

    mem_write: process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                idx := to_integer(unsigned(addr_out(15 downto 1)));
                if idx <= 16383 then
                    if nUDS = '0' then
                        mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            elsif busstate = "00" and addr_out = x"0000043E" then
                stop_reached <= true;
            end if;
        end if;
    end process;

    test: process
        variable pc         : integer;
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
    begin
        for i in mem'range loop
            mem(i) := x"4E71";
        end loop;

        mem(0) := x"0000";
        mem(1) := std_logic_vector(to_unsigned(CRP_SRC_ADDR, 16)); -- SSP = $2800
        mem(2) := x"0000";
        mem(3) := x"0400"; -- PC = $0400

        write_long(CRP_SRC_ADDR, CRP_HI);
        write_long(CRP_SRC_ADDR + 4, CRP_LO);
        write_long(CRP_SAVE_ADDR, SENTINEL);
        write_long(CRP_SAVE_ADDR + 4, SENTINEL);

        write_long(SRP_SRC_ADDR, SRP_HI);
        write_long(SRP_SRC_ADDR + 4, SRP_LO);
        write_long(SRP_SAVE_ADDR, SENTINEL);
        write_long(SRP_SAVE_ADDR + 4, SENTINEL);

        write_long(CRP_RESULT_ADDR, SENTINEL);
        write_long(CRP_RESULT_ADDR + 4, SENTINEL);
        write_long(SRP_RESULT_ADDR, SENTINEL);
        write_long(SRP_RESULT_ADDR + 4, SENTINEL);

        pc := 16#0400#;
        emit_pflusha(pc);
        emit_pmove(pc, REG_CRP, DIR_MEM_TO_MMU, "010", "111", x"0000", x"0000");  -- (A7),CRP
        emit_pmove(pc, REG_CRP, DIR_MMU_TO_MEM, "101", "111", x"0008", x"0000");  -- CRP,(8,A7)
        emit_pflusha(pc);
        emit_pmove(pc, REG_CRP, DIR_MEM_TO_MMU, "010", "111", x"0000", x"0000");  -- (A7),CRP
        emit_pmove(pc, REG_CRP, DIR_MMU_TO_MEM, "111", "001",
                   std_logic_vector(to_unsigned(CRP_RESULT_ADDR, 16)), x"0000");

        emit_word(pc, x"4FF9"); -- LEA $00002820,A7
        emit_long(pc, x"00002820");

        emit_pmove(pc, REG_SRP, DIR_MEM_TO_MMU, "010", "111", x"0000", x"0000");  -- (A7),SRP
        emit_pmove(pc, REG_SRP, DIR_MMU_TO_MEM, "101", "111", x"0008", x"0000");  -- SRP,(8,A7)
        emit_pflusha(pc);
        emit_pmove(pc, REG_SRP, DIR_MEM_TO_MMU, "010", "111", x"0000", x"0000");  -- (A7),SRP
        emit_pmove(pc, REG_SRP, DIR_MMU_TO_MEM, "111", "001",
                   std_logic_vector(to_unsigned(SRP_RESULT_ADDR, 16)), x"0000");

        emit_word(pc, x"4E72"); -- STOP #$2700
        emit_word(pc, x"2700");

        report "=== MMU library root probe regression ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 30000 loop
            wait until rising_edge(clk);
            exit when stop_reached;
        end loop;

        if not stop_reached then
            report "FAIL: timed out before STOP" severity error;
            fail_count := fail_count + 1;
        else
            for i in 0 to 32 loop
                wait until rising_edge(clk);
            end loop;
        end if;

        check_long("CRP saved high longword", CRP_SAVE_ADDR, CRP_HI, pass_count, fail_count);
        check_long("CRP saved low longword", CRP_SAVE_ADDR + 4, CRP_LO, pass_count, fail_count);
        check_long("CRP readback high longword", CRP_RESULT_ADDR, CRP_HI, pass_count, fail_count);
        check_long("CRP readback low longword", CRP_RESULT_ADDR + 4, CRP_LO, pass_count, fail_count);

        check_long("SRP saved high longword", SRP_SAVE_ADDR, SRP_HI, pass_count, fail_count);
        check_long("SRP saved low longword", SRP_SAVE_ADDR + 4, SRP_LO, pass_count, fail_count);
        check_long("SRP readback high longword", SRP_RESULT_ADDR, SRP_HI, pass_count, fail_count);
        check_long("SRP readback low longword", SRP_RESULT_ADDR + 4, SRP_LO, pass_count, fail_count);

        report "MMU library root probe tests: " & integer'image(pass_count) &
               " PASSED, " & integer'image(fail_count) & " FAILED" severity note;

        if fail_count = 0 then
            report "OVERALL: ALL TESTS PASSED" severity note;
        else
            report "OVERALL: SOME TESTS FAILED" severity error;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
