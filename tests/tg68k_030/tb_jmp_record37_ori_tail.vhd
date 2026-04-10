library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_jmp_record37_ori_tail is
end entity;

architecture behavior of tb_jmp_record37_ori_tail is
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
    signal FC         : std_logic_vector(2 downto 0);
    signal test_done  : boolean := false;

    constant CLK_PERIOD : time := 10 ns;
    constant LOW_BASE   : integer := 16#00000000#;
    constant LOW_BYTES  : integer := 16#00002000#;
    constant HIGH_BASE  : integer := 16#42000000#;
    constant HIGH_BYTES : integer := 16#00002000#;
    constant BOOT_PC    : integer := 16#42001000#;
    constant SSP_VALUE  : integer := 16#42000840#;

    type low_mem_t is array (0 to LOW_BYTES / 2 - 1) of std_logic_vector(15 downto 0);
    type high_mem_t is array (0 to HIGH_BYTES / 2 - 1) of std_logic_vector(15 downto 0);

    shared variable low_mem  : low_mem_t;
    shared variable high_mem : high_mem_t;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 1,
            extAddr_Mode   => 1,
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
            FC => FC,
            longword => open,
            nResetOut => open,
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

    data_in <= low_mem(to_integer(unsigned(addr_out(14 downto 1))))
               when addr_out(31 downto 0) < x"00002000" else
               high_mem(to_integer(unsigned(addr_out(12 downto 1))))
               when addr_out(31 downto 13) = std_logic_vector(to_unsigned(HIGH_BASE / 16#2000#, 19)) else
               x"4E71";

    mem_write: process(clk)
        variable addr_i : integer;
        variable idx    : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                addr_i := to_integer(unsigned(addr_out));
                if addr_i >= LOW_BASE and addr_i < LOW_BASE + LOW_BYTES then
                    idx := (addr_i - LOW_BASE) / 2;
                    if nUDS = '0' then
                        low_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        low_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                elsif addr_i >= HIGH_BASE and addr_i < HIGH_BASE + HIGH_BYTES then
                    idx := (addr_i - HIGH_BASE) / 2;
                    if nUDS = '0' then
                        high_mem(idx)(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        high_mem(idx)(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

        impure function slv_to_hex(v : std_logic_vector) return string is
            constant hex_chars : string := "0123456789ABCDEF";
            variable padded    : std_logic_vector(((v'length + 3) / 4) * 4 - 1 downto 0) := (others => '0');
            variable result    : string(1 to padded'length / 4);
            variable nibble    : std_logic_vector(3 downto 0);
        begin
            padded(v'length - 1 downto 0) := v;
            for i in 0 to result'length - 1 loop
                nibble := padded(padded'length - 1 - i * 4 downto padded'length - 4 - i * 4);
                result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
            end loop;
            return result;
        end function;

        procedure write_word(addr : integer; value : std_logic_vector(15 downto 0)) is
            variable idx : integer;
        begin
            if addr < LOW_BASE + LOW_BYTES then
                idx := (addr - LOW_BASE) / 2;
                low_mem(idx) := value;
            elsif addr >= HIGH_BASE and addr < HIGH_BASE + HIGH_BYTES then
                idx := (addr - HIGH_BASE) / 2;
                high_mem(idx) := value;
            end if;
        end procedure;

        procedure write_long(addr : integer; value : std_logic_vector(31 downto 0)) is
        begin
            write_word(addr, value(31 downto 16));
            write_word(addr + 2, value(15 downto 0));
        end procedure;

        impure function read_word(addr : integer) return std_logic_vector is
            variable idx : integer;
        begin
            if addr < LOW_BASE + LOW_BYTES then
                idx := (addr - LOW_BASE) / 2;
                return low_mem(idx);
            elsif addr >= HIGH_BASE and addr < HIGH_BASE + HIGH_BYTES then
                idx := (addr - HIGH_BASE) / 2;
                return high_mem(idx);
            end if;
            return x"4E71";
        end function;

        impure function read_byte(addr : integer) return std_logic_vector is
            variable word_v : std_logic_vector(15 downto 0);
        begin
            word_v := read_word(addr - (addr mod 2));
            if (addr mod 2) = 0 then
                return word_v(15 downto 8);
            end if;
            return word_v(7 downto 0);
        end function;

        procedure init_case is
            variable pc : integer := BOOT_PC;
        begin
            for i in low_mem'range loop
                low_mem(i) := x"4E71";
            end loop;
            for i in high_mem'range loop
                high_mem(i) := x"4E71";
            end loop;

            write_long(16#00000000#, std_logic_vector(to_unsigned(SSP_VALUE, 32)));
            write_long(16#00000004#, std_logic_vector(to_unsigned(BOOT_PC, 32)));

            write_word(16#0000008A#, x"4AFC");
            write_word(16#0000008C#, x"2048");
            write_word(16#0000008E#, x"4B16");
            write_word(16#4204FEFE#, x"CD54");

            write_word(pc, x"227C"); pc := pc + 2; -- MOVEA.L #$0000008B,A1
            write_long(pc, x"0000008B"); pc := pc + 4;
            write_word(pc, x"2C7C"); pc := pc + 2; -- MOVEA.L #$4204FEFF,A6
            write_long(pc, x"4204FEFF"); pc := pc + 4;

            -- Focused tail from BASIC/JMP/0002 record=37 after the real jump target.
            write_word(pc, x"0011"); pc := pc + 2; -- ORI.B #$79,(A1)
            write_word(pc, x"F279"); pc := pc + 2;
            write_word(pc, x"0099"); pc := pc + 2; -- ORI.L #$00EB004B,(A1)+
            write_word(pc, x"00EB"); pc := pc + 2;
            write_word(pc, x"004B"); pc := pc + 2;
            write_word(pc, x"0016"); pc := pc + 2; -- ORI.B #$65,(A6)
            write_word(pc, x"0065"); pc := pc + 2;
            write_word(pc, x"4E72"); pc := pc + 2; -- STOP #$2700
            write_word(pc, x"2700");
        end procedure;
    begin
        init_case;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';
        wait for 20 us;

        if read_byte(16#0000008B#) = x"FD" then
            report "PASS: ORI.B #$79,(A1) preserved destination byte and produced $FD" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: byte $8B=$" & slv_to_hex(read_byte(16#0000008B#)) & " expected $FD" severity error;
            fail_count := fail_count + 1;
        end if;

        if read_word(16#0000008C#) = x"EB48" then
            report "PASS: ORI.L #$00EB004B,(A1)+ preserved odd-aligned long merge at $8C" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: word $8C=$" & slv_to_hex(read_word(16#0000008C#)) & " expected $EB48" severity error;
            fail_count := fail_count + 1;
        end if;

        if read_byte(16#4204FEFF#) = x"75" then
            report "PASS: ORI.B #$65,(A6) preserved the high-memory byte update" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: byte $4204FEFF=$" & slv_to_hex(read_byte(16#4204FEFF#)) & " expected $75" severity error;
            fail_count := fail_count + 1;
        end if;

        report "RESULT: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;

        test_done <= true;
        wait;
    end process;
end architecture;
