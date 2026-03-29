-- tb_moves_privilege.vhd
-- Maintained regression: MOVES must raise vector 8 when executed from user mode.
-- The saved PC must point to the first word of the faulting MOVES instruction.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_moves_privilege is
end entity;

architecture behavioral of tb_moves_privilege is
    function slv_to_hex(v : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to v'length/4);
        variable nibble : integer;
    begin
        for i in 0 to v'length/4-1 loop
            nibble := to_integer(unsigned(v(v'length-1-i*4 downto v'length-4-i*4)));
            result(i+1) := hex_chars(nibble+1);
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
    clk <= not clk after CLK_PERIOD/2 when not test_done;

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
        variable handler_marker : std_logic_vector(15 downto 0);
        variable fail_marker    : std_logic_vector(15 downto 0);
        variable stacked_pc     : std_logic_vector(31 downto 0);
        variable format_vector  : std_logic_vector(15 downto 0);
        variable target_word    : std_logic_vector(15 downto 0);
    begin
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset vectors: SSP=$2000, PC=$1000.
        mem(0) := x"0000";
        mem(1) := x"2000";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- Privilege violation vector (vector 8 => offset $20) -> handler at $1100.
        mem(16) := x"0000";
        mem(17) := x"1100";

        -- Test program:
        --   MOVEA.L #$1200,A0
        --   MOVEQ   #$5A,D0
        --   MOVE    #$0000,SR      ; enter user mode
        --   MOVES.B D0,(A0)        ; must take vector 8 before any write
        --   MOVEQ   #2,D0
        --   MOVE.W  D0,($130C).L   ; failure marker if MOVES executed
        --   BRA.S   *-2
        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1200";
        mem(16#1006# / 2) := x"705A";
        mem(16#1008# / 2) := x"46FC";
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"0E10";
        mem(16#100E# / 2) := x"0800";
        mem(16#1010# / 2) := x"7002";
        mem(16#1012# / 2) := x"33C0";
        mem(16#1014# / 2) := x"0000";
        mem(16#1016# / 2) := x"130C";
        mem(16#1018# / 2) := x"60FE";

        -- Privilege handler:
        --   MOVE.L 2(A7),D0
        --   MOVE.L D0,($1300).L
        --   MOVE.W 6(A7),D0
        --   MOVE.W D0,($1304).L
        --   MOVEQ  #1,D0
        --   MOVE.W D0,($1308).L
        --   STOP   #$2700
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
        mem(16#1114# / 2) := x"7001";
        mem(16#1116# / 2) := x"33C0";
        mem(16#1118# / 2) := x"0000";
        mem(16#111A# / 2) := x"1308";
        mem(16#111C# / 2) := x"4E72";
        mem(16#111E# / 2) := x"2700";

        report "=== MOVES user-mode privilege test ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 4000 loop
            wait until rising_edge(clk);
            handler_marker := mem(16#1308# / 2);
            fail_marker := mem(16#130C# / 2);
            if handler_marker = x"0001" or fail_marker = x"0002" then
                exit;
            end if;
        end loop;

        handler_marker := mem(16#1308# / 2);
        fail_marker := mem(16#130C# / 2);
        stacked_pc := mem(16#1300# / 2) & mem(16#1302# / 2);
        format_vector := mem(16#1304# / 2);
        target_word := mem(16#1200# / 2);

        report "Handler marker : $" & integer'image(to_integer(unsigned(handler_marker))) severity note;
        report "Failure marker : $" & integer'image(to_integer(unsigned(fail_marker))) severity note;

        if fail_marker = x"0002" then
            report "FAIL: MOVES executed in user mode instead of trapping" severity failure;
        elsif handler_marker /= x"0001" then
            report "FAIL: MOVES privilege handler was not reached" severity failure;
        elsif stacked_pc /= x"0000100C" then
            report "FAIL: Stacked PC was $" & slv_to_hex(stacked_pc) & ", expected $0000100C" severity failure;
        elsif format_vector /= x"0020" then
            report "FAIL: Format/vector word was $" & slv_to_hex(format_vector) & ", expected $0020" severity failure;
        elsif target_word /= x"4E71" then
            report "FAIL: MOVES modified target memory before privilege trap; word=$" & slv_to_hex(target_word) severity failure;
        else
            report "PASS: MOVES in user mode raised vector 8 with PC=$0000100C and format/vector=$0020" severity note;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
