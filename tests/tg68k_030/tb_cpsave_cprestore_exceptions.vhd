-- tb_cpsave_cprestore_exceptions.vhd
-- Maintained regression for the old BUG302 cpSAVE/cpRESTORE side patch:
-- valid user-mode cpSAVE/cpRESTORE must raise vector 8, while invalid-EA
-- and generic missing-coprocessor F-line forms remain vector 11.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpsave_cprestore_exceptions is
end entity;

architecture behavioral of tb_cpsave_cprestore_exceptions is
    function slv_to_hex(v : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to v'length / 4);
        variable nibble : integer;
    begin
        for i in 0 to v'length / 4 - 1 loop
            nibble := to_integer(unsigned(v(v'length - 1 - i * 4 downto v'length - 4 - i * 4)));
            result(i + 1) := hex_chars(nibble + 1);
        end loop;
        return result;
    end function;

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

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
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
            pmmu_walker_req => open,
            pmmu_walker_we => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0'
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 8191 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 8191 then
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
        procedure init_case(
            fault_opcode : std_logic_vector(15 downto 0);
            fault_ext    : std_logic_vector(15 downto 0);
            has_ext      : boolean;
            user_mode    : boolean
        ) is
            variable cont_addr : integer;
        begin
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000.
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Vector 8 (privilege violation) -> $1100.
            mem(16) := x"0000";
            mem(17) := x"1100";

            -- Vector 11 (F-line) -> $1180.
            mem(22) := x"0000";
            mem(23) := x"1180";

            -- Common program:
            --   MOVEA.L #$1400,A0
            --   MOVE    #$0000,SR     ; user-mode cases only
            --   <fault opcode>
            --   <fault extension>     ; optional
            --   MOVEQ   #$7E,D0
            --   MOVE.W  D0,($130C).L
            --   STOP    #$2700
            mem(16#1000# / 2) := x"207C";
            mem(16#1002# / 2) := x"0000";
            mem(16#1004# / 2) := x"1400";
            if user_mode then
                mem(16#1006# / 2) := x"46FC";
                mem(16#1008# / 2) := x"0000";
            else
                mem(16#1006# / 2) := x"4E71";
                mem(16#1008# / 2) := x"4E71";
            end if;
            mem(16#100A# / 2) := fault_opcode;
            if has_ext then
                mem(16#100C# / 2) := fault_ext;
                cont_addr := 16#100E#;
            else
                cont_addr := 16#100C#;
            end if;
            mem(cont_addr / 2) := x"707E";
            mem((cont_addr + 2) / 2) := x"33C0";
            mem((cont_addr + 4) / 2) := x"0000";
            mem((cont_addr + 6) / 2) := x"130C";
            mem((cont_addr + 8) / 2) := x"4E72";
            mem((cont_addr + 10) / 2) := x"2700";

            -- Privilege handler at $1100:
            --   save stacked PC, format/vector, and A0; write marker $0008; STOP
            mem(16#1100# / 2) := x"202F";
            mem(16#1102# / 2) := x"0002";
            mem(16#1104# / 2) := x"23C0";
            mem(16#1106# / 2) := x"0000";
            mem(16#1108# / 2) := x"1300";
            mem(16#110A# / 2) := x"302F";
            mem(16#110C# / 2) := x"0006";
            mem(16#110E# / 2) := x"33C0";
            mem(16#1110# / 2) := x"0000";
            mem(16#1112# / 2) := x"1304";
            mem(16#1114# / 2) := x"23C8";
            mem(16#1116# / 2) := x"0000";
            mem(16#1118# / 2) := x"1310";
            mem(16#111A# / 2) := x"7008";
            mem(16#111C# / 2) := x"33C0";
            mem(16#111E# / 2) := x"0000";
            mem(16#1120# / 2) := x"1308";
            mem(16#1122# / 2) := x"4E72";
            mem(16#1124# / 2) := x"2700";

            -- F-line handler at $1180:
            --   save stacked PC, format/vector, and A0; write marker $000B; STOP
            mem(16#1180# / 2) := x"202F";
            mem(16#1182# / 2) := x"0002";
            mem(16#1184# / 2) := x"23C0";
            mem(16#1186# / 2) := x"0000";
            mem(16#1188# / 2) := x"1300";
            mem(16#118A# / 2) := x"302F";
            mem(16#118C# / 2) := x"0006";
            mem(16#118E# / 2) := x"33C0";
            mem(16#1190# / 2) := x"0000";
            mem(16#1192# / 2) := x"1304";
            mem(16#1194# / 2) := x"23C8";
            mem(16#1196# / 2) := x"0000";
            mem(16#1198# / 2) := x"1310";
            mem(16#119A# / 2) := x"700B";
            mem(16#119C# / 2) := x"33C0";
            mem(16#119E# / 2) := x"0000";
            mem(16#11A0# / 2) := x"1308";
            mem(16#11A2# / 2) := x"4E72";
            mem(16#11A4# / 2) := x"2700";
        end procedure;

        procedure run_case(
            constant case_name        : in string;
            constant fault_opcode     : in std_logic_vector(15 downto 0);
            constant fault_ext        : in std_logic_vector(15 downto 0);
            constant has_ext          : in boolean;
            constant user_mode        : in boolean;
            constant expected_marker  : in std_logic_vector(15 downto 0);
            constant expected_vector  : in std_logic_vector(15 downto 0)
        ) is
            variable handler_marker : std_logic_vector(15 downto 0);
            variable fail_marker    : std_logic_vector(15 downto 0);
            variable stacked_pc     : std_logic_vector(31 downto 0);
            variable format_vector  : std_logic_vector(15 downto 0);
            variable saved_a0       : std_logic_vector(31 downto 0);
        begin
            init_case(fault_opcode, fault_ext, has_ext, user_mode);
            report "=== " & case_name & " ===" severity note;

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 4000 loop
                wait until rising_edge(clk);
                handler_marker := mem(16#1308# / 2);
                fail_marker := mem(16#130C# / 2);
                if handler_marker = expected_marker or fail_marker = x"007E" then
                    exit;
                end if;
            end loop;

            handler_marker := mem(16#1308# / 2);
            fail_marker := mem(16#130C# / 2);
            stacked_pc := mem(16#1300# / 2) & mem(16#1302# / 2);
            format_vector := mem(16#1304# / 2);
            saved_a0 := mem(16#1310# / 2) & mem(16#1312# / 2);

            if fail_marker = x"007E" then
                report "FAIL: " & case_name & " executed instead of trapping" severity failure;
            elsif handler_marker /= expected_marker then
                report "FAIL: " & case_name & " reached marker $" & slv_to_hex(handler_marker) &
                       " instead of $" & slv_to_hex(expected_marker) severity failure;
            elsif stacked_pc /= x"0000100A" then
                report "FAIL: " & case_name & " stacked PC=$" & slv_to_hex(stacked_pc) &
                       ", expected $0000100A" severity failure;
            elsif format_vector /= expected_vector then
                report "FAIL: " & case_name & " format/vector=$" & slv_to_hex(format_vector) &
                       ", expected $" & slv_to_hex(expected_vector) severity failure;
            elsif saved_a0 /= x"00001400" then
                report "FAIL: " & case_name & " modified A0 before trapping; saved A0=$" &
                       slv_to_hex(saved_a0) severity failure;
            else
                report "PASS: " & case_name & " trapped with vector $" &
                       slv_to_hex(expected_vector) & " and preserved A0" severity note;
            end if;
        end procedure;
    begin
        run_case("cpSAVE -(A0) in user mode", x"F320", x"4E71", false, true, x"0008", x"0020");
		nReset <= '0';
		wait until rising_edge(clk);
		wait until rising_edge(clk);

        run_case("cpSAVE (A0)+ in user mode", x"F318", x"4E71", false, true, x"000B", x"002C");
		nReset <= '0';
		wait until rising_edge(clk);
		wait until rising_edge(clk);

        run_case("cpRESTORE (A0)+ in user mode", x"F358", x"4E71", false, true, x"0008", x"0020");
		nReset <= '0';
		wait until rising_edge(clk);
		wait until rising_edge(clk);

        run_case("cpRESTORE -(A0) in user mode", x"F360", x"4E71", false, true, x"000B", x"002C");
		nReset <= '0';
		wait until rising_edge(clk);
		wait until rising_edge(clk);

        run_case("unimplemented CpID0 F-line in user mode", x"F180", x"4E71", false, true, x"000B", x"002C");
		nReset <= '0';
		wait until rising_edge(clk);
		wait until rising_edge(clk);

        run_case("unimplemented CpID0 F-line in supervisor mode", x"F180", x"4E71", false, false, x"000B", x"002C");
		nReset <= '0';
		wait until rising_edge(clk);
		wait until rising_edge(clk);

		test_done <= true;
        wait;
    end process;
end architecture;
