-- tb_moves_d16an_pc.vhd
-- Maintained regression for the old MOVES_BUG_FIX patch:
-- MOVES with (d16,An) must retire to the immediately following instruction
-- instead of over-incrementing the PC after consuming the displacement word.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_moves_d16an_pc is
end entity;

architecture behavioral of tb_moves_d16an_pc is
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
    signal read_hi_ok : std_logic := '0';
    signal read_lo_ok : std_logic := '0';

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;

    procedure init_memory is
    begin
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;
    end procedure;

    procedure wait_cycles(count : natural) is
    begin
        for i in 1 to count loop
            wait until rising_edge(clk);
        end loop;
    end procedure;
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

    read_track: process(clk)
        variable addr_int : integer;
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                read_hi_ok <= '0';
                read_lo_ok <= '0';
            elsif busstate = "10" and FC = "101" then
                addr_int := to_integer(unsigned(addr_out(23 downto 0)));
                if addr_int = 16#1410# then
                    read_hi_ok <= '1';
                elsif addr_int = 16#1412# then
                    read_lo_ok <= '1';
                end if;
            end if;
        end if;
    end process;

    test: process
        variable write_data   : std_logic_vector(31 downto 0);
        variable write_marker : std_logic_vector(15 downto 0);
        variable read_marker  : std_logic_vector(15 downto 0);
    begin
        report "=== MOVES (d16,An) PC retire regression ===" severity note;

        -- Case 1: MOVES.L D2,($10,A0) must fall through to the marker store.
        init_memory;
        mem(0) := x"0000";
        mem(1) := x"2000";
        mem(2) := x"0000";
        mem(3) := x"1000";
        mem(16#1000# / 2) := x"7005";  -- MOVEQ #5,D0
        mem(16#1002# / 2) := x"4E7B";  -- MOVEC D0,SFC
        mem(16#1004# / 2) := x"0000";
        mem(16#1006# / 2) := x"7201";  -- MOVEQ #1,D1
        mem(16#1008# / 2) := x"4E7B";  -- MOVEC D1,DFC
        mem(16#100A# / 2) := x"1001";
        mem(16#100C# / 2) := x"207C";  -- MOVEA.L #$1400,A0
        mem(16#100E# / 2) := x"0000";
        mem(16#1010# / 2) := x"1400";
        mem(16#1012# / 2) := x"243C";  -- MOVE.L #$12345678,D2
        mem(16#1014# / 2) := x"1234";
        mem(16#1016# / 2) := x"5678";
        mem(16#1018# / 2) := x"0EA8";  -- MOVES.L D2,($10,A0)
        mem(16#101A# / 2) := x"2800";
        mem(16#101C# / 2) := x"0010";
        mem(16#101E# / 2) := x"7601";  -- MOVEQ #1,D3
        mem(16#1020# / 2) := x"33C3";  -- MOVE.W D3,($1500).L
        mem(16#1022# / 2) := x"0000";
        mem(16#1024# / 2) := x"1500";
        mem(16#1026# / 2) := x"4E72";  -- STOP #$2700
        mem(16#1028# / 2) := x"2700";

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 6000 loop
            wait until rising_edge(clk);
            if mem(16#1500# / 2) = x"0001" then
                exit;
            end if;
        end loop;
        wait_cycles(4);

        write_data := mem(16#1410# / 2) & mem(16#1412# / 2);
        write_marker := mem(16#1500# / 2);

        if write_data /= x"12345678" then
            report "FAIL: MOVES.L D2,($10,A0) stored $" & slv_to_hex(write_data) &
                   " instead of $12345678" severity failure;
        elsif write_marker /= x"0001" then
            report "FAIL: MOVES.L D2,($10,A0) did not retire to the next instruction" severity failure;
        else
            report "PASS: MOVES.L D2,($10,A0) stored data and retired to the next instruction" severity note;
        end if;

        -- Case 2: MOVES.L ($10,A0),D7 must also fall through cleanly.
        nReset <= '0';
        wait_cycles(4);
        init_memory;
        mem(0) := x"0000";
        mem(1) := x"2000";
        mem(2) := x"0000";
        mem(3) := x"1000";
        mem(16#1410# / 2) := x"89AB";
        mem(16#1412# / 2) := x"CDEF";
        mem(16#1000# / 2) := x"7005";  -- MOVEQ #5,D0
        mem(16#1002# / 2) := x"4E7B";  -- MOVEC D0,SFC
        mem(16#1004# / 2) := x"0000";
        mem(16#1006# / 2) := x"7201";  -- MOVEQ #1,D1
        mem(16#1008# / 2) := x"4E7B";  -- MOVEC D1,DFC
        mem(16#100A# / 2) := x"1001";
        mem(16#100C# / 2) := x"207C";  -- MOVEA.L #$1400,A0
        mem(16#100E# / 2) := x"0000";
        mem(16#1010# / 2) := x"1400";
        mem(16#1012# / 2) := x"0EA8";  -- MOVES.L ($10,A0),D7
        mem(16#1014# / 2) := x"7000";
        mem(16#1016# / 2) := x"0010";
        mem(16#1018# / 2) := x"0C87";  -- CMPI.L #$89ABCDEF,D7
        mem(16#101A# / 2) := x"89AB";
        mem(16#101C# / 2) := x"CDEF";
        mem(16#101E# / 2) := x"6700";  -- BEQ.W success
        mem(16#1020# / 2) := x"000C";
        mem(16#1022# / 2) := x"7A04";  -- MOVEQ #4,D5
        mem(16#1024# / 2) := x"33C5";  -- MOVE.W D5,($1508).L
        mem(16#1026# / 2) := x"0000";
        mem(16#1028# / 2) := x"1508";
        mem(16#102A# / 2) := x"4E72";  -- STOP #$2700
        mem(16#102C# / 2) := x"2700";
        mem(16#102E# / 2) := x"7A03";  -- MOVEQ #3,D5
        mem(16#1030# / 2) := x"33C5";  -- MOVE.W D5,($1508).L
        mem(16#1032# / 2) := x"0000";
        mem(16#1034# / 2) := x"1508";
        mem(16#1036# / 2) := x"4E72";  -- STOP #$2700
        mem(16#1038# / 2) := x"2700";

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 6000 loop
            wait until rising_edge(clk);
            if mem(16#1508# / 2) = x"0003" or mem(16#1508# / 2) = x"0004" then
                exit;
            end if;
        end loop;
        wait_cycles(4);

        read_marker := mem(16#1508# / 2);

        if read_hi_ok /= '1' or read_lo_ok /= '1' then
            report "FAIL: MOVES.L ($10,A0),D7 did not perform both SFC reads at $1410/$1412" severity failure;
        elsif read_marker = x"0004" then
            report "FAIL: MOVES.L ($10,A0),D7 did not expose the loaded longword to the next CMPI/BEQ sequence" severity failure;
        elsif read_marker /= x"0003" then
            report "FAIL: MOVES.L ($10,A0),D7 did not retire to the next instruction" severity failure;
        else
            report "PASS: MOVES.L ($10,A0),D7 exposed the loaded longword to the next instruction and retired cleanly" severity note;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
