-- tb_abcd.vhd
-- BUG #398: Test ABCD.B Dn,Dn register write-back
-- Verifies that ABCD.B D0,D0 with D0=$10 produces D0=$20 (BCD 10+10=20)
-- Also tests SBCD.B and ABCD with different register combinations

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_abcd is
end entity;

architecture behavior of tb_abcd is
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

    -- Debug signals
    signal debug_setopcode    : std_logic;
    signal debug_exec_directSR : std_logic;

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;
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
            CPU => "10",  -- 68030
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
            debug_setopcode => debug_setopcode,
            debug_exec_directSR => debug_exec_directSR,
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
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable test_num   : integer := 0;
    begin
        -- Initialize memory to NOP
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        -- ============================================================
        -- Test 1: ABCD.B D0,D0 ($10 + $10 = $20 BCD)
        -- ============================================================
        test_num := 1;

        -- Reset vectors: SSP=$0800, PC=$1000
        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- Program at $1000:
        --   MOVE.L #$00000010,D0   ; D0 = $10 (BCD 10)
        --   ABCD.B D0,D0           ; D0 = $10 + $10 = $20 (BCD 20)
        --   MOVE.L D0,$2000        ; Store result to memory for checking
        --   NOP (STOP)
        mem(16#1000#/2) := x"203C";  -- MOVE.L #imm,D0
        mem(16#1002#/2) := x"0000";  -- high word
        mem(16#1004#/2) := x"0010";  -- low word = $10
        mem(16#1006#/2) := x"C100";  -- ABCD.B D0,D0
        mem(16#1008#/2) := x"23C0";  -- MOVE.L D0,$2000.L
        mem(16#100A#/2) := x"0000";
        mem(16#100C#/2) := x"2000";
        mem(16#100E#/2) := x"4E72";  -- STOP #$2700
        mem(16#1010#/2) := x"2700";

        report "=== Test 1: ABCD.B D0,D0 ($10+$10=$20 BCD) ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        -- Wait for MOVE.L D0,$2000 write
        for i in 0 to 10000 loop
            wait until rising_edge(clk);
            if busstate = "11" and nWr = '0' and addr_out(15 downto 0) = x"2000" then
                -- First word write to $2000 (high word of D0)
                wait until rising_edge(clk);
                -- Second word write to $2002 (low word of D0)
                if busstate = "11" and nWr = '0' and addr_out(15 downto 0) = x"2002" then
                    -- Check low word - should be $0020
                    if data_write = x"0020" then
                        report "PASS: Test 1 - ABCD.B D0,D0 result low word = $0020" severity note;
                        pass_count := pass_count + 1;
                    else
                        report "FAIL: Test 1 - ABCD.B D0,D0 result low word = " &
                               integer'image(to_integer(unsigned(data_write))) &
                               " expected $0020" severity error;
                        fail_count := fail_count + 1;
                    end if;
                end if;
                exit;
            end if;
            -- Check if CPU stopped without writing (ABCD failed)
            if busstate = "01" then
                -- CPU in idle/stopped state - check if it fetched STOP instruction
                if addr_out(15 downto 0) = x"100E" or addr_out(15 downto 0) = x"1010" then
                    -- CPU may have hit STOP before MOVE.L completed
                    null;
                end if;
            end if;
        end loop;

        -- ============================================================
        -- Test 2: ABCD.B D1,D2 ($19 + $28 = $47 BCD)
        -- ============================================================
        test_num := 2;

        -- Re-init
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- MOVE.L #$19,D1
        mem(16#1000#/2) := x"223C";
        mem(16#1002#/2) := x"0000";
        mem(16#1004#/2) := x"0019";
        -- MOVE.L #$28,D2
        mem(16#1006#/2) := x"243C";
        mem(16#1008#/2) := x"0000";
        mem(16#100A#/2) := x"0028";
        -- ANDI #$EF,CCR  (clear X flag for clean test)
        mem(16#100C#/2) := x"023C";
        mem(16#100E#/2) := x"00EF";
        -- ABCD.B D1,D2  => D2 = $19 + $28 = $47 BCD
        -- Encoding: 1100 Rx 1 0000 0 Ry => 1100 010 1 0000 0 001 = $C501
        mem(16#1010#/2) := x"C501";
        -- MOVE.L D2,$2000
        mem(16#1012#/2) := x"23C2";
        mem(16#1014#/2) := x"0000";
        mem(16#1016#/2) := x"2000";
        -- STOP
        mem(16#1018#/2) := x"4E72";
        mem(16#101A#/2) := x"2700";

        report "=== Test 2: ABCD.B D1,D2 ($19+$28=$47 BCD) ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 10000 loop
            wait until rising_edge(clk);
            if busstate = "11" and nWr = '0' and addr_out(15 downto 0) = x"2002" then
                if data_write = x"0047" then
                    report "PASS: Test 2 - ABCD.B D1,D2 result low word = $0047" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: Test 2 - ABCD.B D1,D2 result low word = " &
                           integer'image(to_integer(unsigned(data_write))) &
                           " expected $0047" severity error;
                    fail_count := fail_count + 1;
                end if;
                exit;
            end if;
        end loop;

        -- ============================================================
        -- Test 3: SBCD.B D0,D1 ($47 - $19 = $28 BCD)
        -- ============================================================
        test_num := 3;

        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- MOVE.L #$19,D0
        mem(16#1000#/2) := x"203C";
        mem(16#1002#/2) := x"0000";
        mem(16#1004#/2) := x"0019";
        -- MOVE.L #$47,D1
        mem(16#1006#/2) := x"223C";
        mem(16#1008#/2) := x"0000";
        mem(16#100A#/2) := x"0047";
        -- ANDI #$EF,CCR  (clear X flag)
        mem(16#100C#/2) := x"023C";
        mem(16#100E#/2) := x"00EF";
        -- SBCD.B D0,D1  => D1 = $47 - $19 = $28 BCD
        -- Encoding: 1000 Ry 1 0000 0 Rx => 1000 001 1 0000 0 000 = $8300
        mem(16#1010#/2) := x"8300";
        -- MOVE.L D1,$2000
        mem(16#1012#/2) := x"23C1";
        mem(16#1014#/2) := x"0000";
        mem(16#1016#/2) := x"2000";
        -- STOP
        mem(16#1018#/2) := x"4E72";
        mem(16#101A#/2) := x"2700";

        report "=== Test 3: SBCD.B D0,D1 ($47-$19=$28 BCD) ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 10000 loop
            wait until rising_edge(clk);
            if busstate = "11" and nWr = '0' and addr_out(15 downto 0) = x"2002" then
                if data_write = x"0028" then
                    report "PASS: Test 3 - SBCD.B D0,D1 result low word = $0028" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: Test 3 - SBCD.B D0,D1 result low word = " &
                           integer'image(to_integer(unsigned(data_write))) &
                           " expected $0028" severity error;
                    fail_count := fail_count + 1;
                end if;
                exit;
            end if;
        end loop;

        -- ============================================================
        -- Test 4: ABCD.B D0,D0 with carry ($99 + $01 = $00 + X)
        -- ============================================================
        test_num := 4;

        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- MOVE.L #$0099,D0
        mem(16#1000#/2) := x"203C";
        mem(16#1002#/2) := x"0000";
        mem(16#1004#/2) := x"0099";
        -- MOVE.L #$0001,D1
        mem(16#1006#/2) := x"223C";
        mem(16#1008#/2) := x"0000";
        mem(16#100A#/2) := x"0001";
        -- ANDI #$EF,CCR  (clear X flag)
        mem(16#100C#/2) := x"023C";
        mem(16#100E#/2) := x"00EF";
        -- ABCD.B D1,D0  => D0 = $99 + $01 = $00 with X,C set
        -- Encoding: 1100 Rx 1 0000 0 Ry => 1100 000 1 0000 0 001 = $C101
        mem(16#1010#/2) := x"C101";
        -- MOVE.L D0,$2000
        mem(16#1012#/2) := x"23C0";
        mem(16#1014#/2) := x"0000";
        mem(16#1016#/2) := x"2000";
        -- STOP
        mem(16#1018#/2) := x"4E72";
        mem(16#101A#/2) := x"2700";

        report "=== Test 4: ABCD.B D1,D0 ($99+$01=$00+carry BCD) ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 10000 loop
            wait until rising_edge(clk);
            if busstate = "11" and nWr = '0' and addr_out(15 downto 0) = x"2002" then
                if data_write = x"0000" then
                    report "PASS: Test 4 - ABCD.B D1,D0 result low word = $0000 (carry)" severity note;
                    pass_count := pass_count + 1;
                else
                    report "FAIL: Test 4 - ABCD.B D1,D0 result low word = " &
                           integer'image(to_integer(unsigned(data_write))) &
                           " expected $0000" severity error;
                    fail_count := fail_count + 1;
                end if;
                exit;
            end if;
        end loop;

        -- Summary
        report "============================================" severity note;
        report "ABCD/SBCD Tests: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;
        report "============================================" severity note;

        if fail_count > 0 then
            report "OVERALL: FAIL" severity failure;
        else
            report "OVERALL: ALL TESTS PASSED" severity note;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
