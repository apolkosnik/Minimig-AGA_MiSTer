-- tb_mmu_library_failure_path.vhd
-- Focused reproducer for the mmu.library failure-path block around:
--   MOVE.L (A0),D0
--   CMP.L  #$DEADF00D,D0
--   BNE.B  ...
--   ADDQ.L #1,(SP)
--   MOVEA.L (8,SP),A1
--   JSR (-$C6,A6)
--
-- The fake library vector at A6-$C6 records A1 and the call-entry A7.
-- Bus/address/F-line handlers write distinct BAD0000x signatures.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_library_failure_path is
end entity;

architecture behavior of tb_mmu_library_failure_path is
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

    constant CLK_PERIOD    : time := 10 ns;
    constant STACK_ADDR    : integer := 16#2000#;
    constant SENTINEL_ADDR : integer := 16#3000#;
    constant ARG_ADDR      : integer := 16#3400#;
    constant RESULT_ADDR   : integer := 16#3600#;
    constant LIB_BASE      : integer := 16#4000#;
    constant LIB_ENTRY     : integer := LIB_BASE - 16#00C6#;

    constant RESULT_A1      : integer := RESULT_ADDR;
    constant RESULT_CALL_A7 : integer := RESULT_ADDR + 4;
    constant RESULT_RET_A7  : integer := RESULT_ADDR + 8;
    constant RESULT_D0      : integer := RESULT_ADDR + 12;
    constant RESULT_EXC     : integer := RESULT_ADDR + 16;

    type mem_array_t is array(0 to 32767) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;
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

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 32767 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 32767 then
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

        impure function mem_read_long(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2) & mem(byte_addr / 2 + 1);
        end function;

        procedure write_long(byte_addr : integer; value : std_logic_vector(31 downto 0)) is
        begin
            mem(byte_addr / 2) := value(31 downto 16);
            mem(byte_addr / 2 + 1) := value(15 downto 0);
        end procedure;

        procedure init_program(sentinel_value : std_logic_vector(31 downto 0)) is
            constant PROG_BASE         : integer := 16#1000#;
            constant BUSERR_HANDLER    : integer := 16#1800#;
            constant ADDRERR_HANDLER   : integer := 16#1820#;
            constant FLINE_HANDLER     : integer := 16#1840#;
        begin
            for i in mem'range loop
                mem(i) := x"4E71";
            end loop;

            mem(0)  := x"0000";
            mem(1)  := std_logic_vector(to_unsigned(STACK_ADDR, 16));
            mem(2)  := x"0000";
            mem(3)  := std_logic_vector(to_unsigned(PROG_BASE, 16));
            mem(4)  := x"0000";
            mem(5)  := std_logic_vector(to_unsigned(BUSERR_HANDLER, 16));
            mem(6)  := x"0000";
            mem(7)  := std_logic_vector(to_unsigned(ADDRERR_HANDLER, 16));
            mem(22) := x"0000";
            mem(23) := std_logic_vector(to_unsigned(FLINE_HANDLER, 16));

            mem(16#1000# / 2) := x"2C7C";  -- MOVEA.L #LIB_BASE,A6
            mem(16#1002# / 2) := x"0000";
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(LIB_BASE, 16));
            mem(16#1006# / 2) := x"2E7C";  -- MOVEA.L #STACK_ADDR,A7
            mem(16#1008# / 2) := x"0000";
            mem(16#100A# / 2) := std_logic_vector(to_unsigned(STACK_ADDR, 16));
            mem(16#100C# / 2) := x"206F";  -- MOVEA.L (4,A7),A0
            mem(16#100E# / 2) := x"0004";
            mem(16#1010# / 2) := x"2010";  -- MOVE.L (A0),D0
            mem(16#1012# / 2) := x"0C80";  -- CMPI.L #$DEADF00D,D0
            mem(16#1014# / 2) := x"DEAD";
            mem(16#1016# / 2) := x"F00D";
            mem(16#1018# / 2) := x"6602";  -- BNE.B failure_call
            mem(16#101A# / 2) := x"5297";  -- ADDQ.L #1,(A7)
            mem(16#101C# / 2) := x"226F";  -- MOVEA.L (8,A7),A1
            mem(16#101E# / 2) := x"0008";
            mem(16#1020# / 2) := x"4EAE";  -- JSR (-$C6,A6)
            mem(16#1022# / 2) := x"FF3A";
            mem(16#1024# / 2) := x"23CF";  -- MOVE.L A7,$RESULT_RET_A7
            mem(16#1026# / 2) := x"0000";
            mem(16#1028# / 2) := std_logic_vector(to_unsigned(RESULT_RET_A7, 16));
            mem(16#102A# / 2) := x"23C0";  -- MOVE.L D0,$RESULT_D0
            mem(16#102C# / 2) := x"0000";
            mem(16#102E# / 2) := std_logic_vector(to_unsigned(RESULT_D0, 16));
            mem(16#1030# / 2) := x"4E72";  -- STOP #$2700
            mem(16#1032# / 2) := x"2700";

            mem(LIB_ENTRY / 2)       := x"23C9"; -- MOVE.L A1,$RESULT_A1
            mem(LIB_ENTRY / 2 + 1)   := x"0000";
            mem(LIB_ENTRY / 2 + 2)   := std_logic_vector(to_unsigned(RESULT_A1, 16));
            mem(LIB_ENTRY / 2 + 3)   := x"23CF"; -- MOVE.L A7,$RESULT_CALL_A7
            mem(LIB_ENTRY / 2 + 4)   := x"0000";
            mem(LIB_ENTRY / 2 + 5)   := std_logic_vector(to_unsigned(RESULT_CALL_A7, 16));
            mem(LIB_ENTRY / 2 + 6)   := x"7000"; -- MOVEQ #0,D0
            mem(LIB_ENTRY / 2 + 7)   := x"4E75"; -- RTS

            mem(16#1800# / 2) := x"23FC"; mem(16#1802# / 2) := x"BAD0";
            mem(16#1804# / 2) := x"0002"; mem(16#1806# / 2) := x"0000";
            mem(16#1808# / 2) := std_logic_vector(to_unsigned(RESULT_EXC, 16));
            mem(16#180A# / 2) := x"4E72"; mem(16#180C# / 2) := x"2700";

            mem(16#1820# / 2) := x"23FC"; mem(16#1822# / 2) := x"BAD0";
            mem(16#1824# / 2) := x"0003"; mem(16#1826# / 2) := x"0000";
            mem(16#1828# / 2) := std_logic_vector(to_unsigned(RESULT_EXC, 16));
            mem(16#182A# / 2) := x"4E72"; mem(16#182C# / 2) := x"2700";

            mem(16#1840# / 2) := x"23FC"; mem(16#1842# / 2) := x"BAD0";
            mem(16#1844# / 2) := x"000B"; mem(16#1846# / 2) := x"0000";
            mem(16#1848# / 2) := std_logic_vector(to_unsigned(RESULT_EXC, 16));
            mem(16#184A# / 2) := x"4E72"; mem(16#184C# / 2) := x"2700";

            write_long(STACK_ADDR, x"00000000");
            write_long(STACK_ADDR + 4, std_logic_vector(to_unsigned(SENTINEL_ADDR, 32)));
            write_long(STACK_ADDR + 8, std_logic_vector(to_unsigned(ARG_ADDR, 32)));
            write_long(SENTINEL_ADDR, sentinel_value);
            write_long(ARG_ADDR, x"CAFEBABE");
            write_long(RESULT_A1, x"DEADBEEF");
            write_long(RESULT_CALL_A7, x"DEADBEEF");
            write_long(RESULT_RET_A7, x"DEADBEEF");
            write_long(RESULT_D0, x"DEADBEEF");
            write_long(RESULT_EXC, x"00000000");
        end procedure;

        procedure run_case(max_cycles : integer := 12000) is
            variable started    : boolean := false;
            variable idle_count : integer := 0;
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to max_cycles loop
                wait until rising_edge(clk);
                if busstate /= "01" then
                    started := true;
                    idle_count := 0;
                elsif started then
                    idle_count := idle_count + 1;
                    if idle_count >= 10 then
                        return;
                    end if;
                end if;
            end loop;

            report "FAIL: timeout waiting for STOP" severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure check_long(test_name : string;
                             addr      : integer;
                             expected  : std_logic_vector(31 downto 0)) is
            variable actual : std_logic_vector(31 downto 0);
        begin
            actual := mem_read_long(addr);
            if actual = expected then
                report "PASS: " & test_name severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;
    begin
        report "=== mmu.library failure-path reproducer ===" severity note;

        init_program(x"FFFFFFFF");
        run_case;
        check_long("sentinel mismatch reached cleanup call with A1 from 8(A7)",
                   RESULT_A1, std_logic_vector(to_unsigned(ARG_ADDR, 32)));
        check_long("sentinel mismatch entered JSR with pushed return address",
                   RESULT_CALL_A7, x"00001FFC");
        check_long("sentinel mismatch returned with original A7",
                   RESULT_RET_A7, x"00002000");
        check_long("sentinel mismatch cleanup returned D0=0",
                   RESULT_D0, x"00000000");
        check_long("sentinel mismatch did not raise bus/address/F-line",
                   RESULT_EXC, x"00000000");
        check_long("sentinel mismatch left (SP) unchanged",
                   STACK_ADDR, x"00000000");

        init_program(x"DEADF00D");
        run_case;
        check_long("sentinel match still reached cleanup call with A1 from 8(A7)",
                   RESULT_A1, std_logic_vector(to_unsigned(ARG_ADDR, 32)));
        check_long("sentinel match entered JSR with pushed return address",
                   RESULT_CALL_A7, x"00001FFC");
        check_long("sentinel match returned with original A7",
                   RESULT_RET_A7, x"00002000");
        check_long("sentinel match cleanup returned D0=0",
                   RESULT_D0, x"00000000");
        check_long("sentinel match did not raise bus/address/F-line",
                   RESULT_EXC, x"00000000");
        check_long("sentinel match incremented (SP) before cleanup call",
                   STACK_ADDR, x"00000001");

        report "mmu.library failure-path tests: " & integer'image(pass_count) &
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
