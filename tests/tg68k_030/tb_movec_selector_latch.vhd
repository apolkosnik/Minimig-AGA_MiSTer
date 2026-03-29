-- tb_movec_selector_latch.vhd
-- Regression: MOVEC must use the control-register selector captured with its
-- own extension word, not a later fetched immediate. This covers the late
-- source-branch fix where a following BSET #3,... immediate word ($0003)
-- could clobber a live brief decode and turn MOVEC CACR accesses into selector
-- $003 instead of the intended $002.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_movec_selector_latch is
end entity;

architecture behavior of tb_movec_selector_latch is
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
    signal cacr_out   : std_logic_vector(31 downto 0);

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
    clk <= not clk after CLK_PERIOD/2 when not test_done;

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
            CACR_out => cacr_out,
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
        constant CASE1_ADDR_HI : natural := 16#1F10# / 2;
        constant CASE1_ADDR_LO : natural := 16#1F12# / 2;
        constant CASE2_ADDR_HI : natural := 16#1F20# / 2;
        constant CASE2_ADDR_LO : natural := 16#1F22# / 2;
        variable case1_store_seen : boolean;
        variable case2_store_seen : boolean;
    begin
        -- ============================================================
        -- Case 1: MOVEC D0,CACR must ignore following BSET #3 immediate
        -- ============================================================
        init_memory;

        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- MOVE.L #$00000101,D0
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0101";
        -- MOVEC D0,CACR
        mem(16#1006# / 2) := x"4E7B";
        mem(16#1008# / 2) := x"0002";
        -- BSET #3,D0 (immediate word $0003 is the stale-brief hazard)
        mem(16#100A# / 2) := x"08C0";
        mem(16#100C# / 2) := x"0003";
        -- MOVE.L D0,$1F10.L
        mem(16#100E# / 2) := x"23C0";
        mem(16#1010# / 2) := x"0000";
        mem(16#1012# / 2) := x"1F10";
        -- STOP #$2700
        mem(16#1014# / 2) := x"4E72";
        mem(16#1016# / 2) := x"2700";

        report "=== MOVEC selector latch write-side test ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        case1_store_seen := false;
        for i in 0 to 12000 loop
            wait until rising_edge(clk);
            if mem(CASE1_ADDR_HI) /= x"4E71" or mem(CASE1_ADDR_LO) /= x"4E71" then
                case1_store_seen := true;
                exit;
            end if;
        end loop;
        wait_cycles(4);

        if not case1_store_seen then
            report "FAIL: write-side MOVEC selector test did not reach the D0 store" severity failure;
        elsif cacr_out /= x"00000101" then
            report "FAIL: MOVEC D0,CACR did not retain selector $002 across later immediate fetches" severity failure;
        elsif mem(CASE1_ADDR_HI) /= x"0000" or mem(CASE1_ADDR_LO) /= x"0109" then
            report "FAIL: BSET #3,D0 sequence did not preserve expected D0=$00000109" severity failure;
        else
            report "PASS: MOVEC D0,CACR kept latched selector across BSET immediate $0003" severity note;
        end if;

        -- ============================================================
        -- Case 2: MOVEC CACR,D1 must ignore following BSET #3 immediate
        -- ============================================================
        init_memory;

        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- MOVE.L #$00000101,D0
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0101";
        -- MOVEC D0,CACR
        mem(16#1006# / 2) := x"4E7B";
        mem(16#1008# / 2) := x"0002";
        -- MOVEQ #0,D1
        mem(16#100A# / 2) := x"7200";
        -- MOVEC CACR,D1
        mem(16#100C# / 2) := x"4E7A";
        mem(16#100E# / 2) := x"1002";
        -- BSET #3,D0 (again uses immediate word $0003)
        mem(16#1010# / 2) := x"08C0";
        mem(16#1012# / 2) := x"0003";
        -- MOVE.L D1,$1F20.L
        mem(16#1014# / 2) := x"23C1";
        mem(16#1016# / 2) := x"0000";
        mem(16#1018# / 2) := x"1F20";
        -- STOP #$2700
        mem(16#101A# / 2) := x"4E72";
        mem(16#101C# / 2) := x"2700";

        report "=== MOVEC selector latch read-side test ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        case2_store_seen := false;
        for i in 0 to 14000 loop
            wait until rising_edge(clk);
            if mem(CASE2_ADDR_HI) /= x"4E71" or mem(CASE2_ADDR_LO) /= x"4E71" then
                case2_store_seen := true;
                exit;
            end if;
        end loop;
        wait_cycles(4);

        if not case2_store_seen then
            report "FAIL: read-side MOVEC selector test did not reach the D1 store" severity failure;
        elsif mem(CASE2_ADDR_HI) /= x"0000" or mem(CASE2_ADDR_LO) /= x"0101" then
            report "FAIL: MOVEC CACR,D1 did not retain selector $002 across later immediate fetches" severity failure;
        else
            report "PASS: MOVEC CACR,D1 kept latched selector across BSET immediate $0003" severity note;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
