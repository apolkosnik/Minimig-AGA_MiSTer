-- tb_pmmu_walk_verify.vhd
-- PMMU table-walk bus verification (PTEST).
--
-- Companion to tb_pmmu_bus_verify (which covers PMOVE register transfers). This
-- bench drives a real 2-level table walk and verifies the WALK path:
--   - the descriptor READ addresses the kernel computes (CRP root + index*4,
--     then level-B table + index*4)
--   - the descriptor DATA the walk consumes
--   - the PTEST A-bit return value (physical address of the last descriptor)
--   - the resulting MMUSR
--
-- Harness: kernel-only, with an address-aware walker mock that returns the
-- descriptor stored in mem at pmmu_walker_addr (same mechanism tb_ptest_all_modes
-- uses). The descriptor table is laid out by this bench so every expected
-- address/value is known up front.
--
-- Configuration (matches the field-sum rule IS+TIA+TIB+PS = 32):
--   TC  = $00D08B00  (E=0 so no fetch translation; PS=13/8KB, IS=0, TIA=8, TIB=11)
--   CRP = $0000000200006000 (DT=2 table, level-A table at $6000)
--   PTEST target logical address = $00002000
--     index_A = (LA >> 24) & $FF  = 0  -> descriptor at $6000
--     level-A descriptor $00006402 (DT=2) -> level-B table at $6400
--     index_B = (LA >> 13) & $7FF = 1  -> descriptor at $6404
--     level-B descriptor $00008001 (DT=1 page) -> page frame
--   PTEST A-bit return = $6404 (address of the last/page descriptor)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmmu_walk_verify is
end entity;

architecture behavioral of tb_pmmu_walk_verify is

    function slv32_to_hexstring(slv : std_logic_vector(31 downto 0)) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable hex : string(1 to 8);
        variable nib : std_logic_vector(3 downto 0);
    begin
        for i in 0 to 7 loop
            nib := slv(31 - i*4 downto 28 - i*4);
            if (nib(3) /= '0' and nib(3) /= '1') or (nib(2) /= '0' and nib(2) /= '1') or
               (nib(1) /= '0' and nib(1) /= '1') or (nib(0) /= '0' and nib(0) /= '1') then
                hex(i+1) := 'X';
            else
                hex(i+1) := hex_chars(to_integer(unsigned(nib)) + 1);
            end if;
        end loop;
        return hex;
    end function;

    function has_unknown(slv : std_logic_vector) return boolean is
    begin
        for i in slv'range loop
            if slv(i) /= '0' and slv(i) /= '1' then return true; end if;
        end loop;
        return false;
    end function;

    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal clkena_in : std_logic := '1';

    signal data_in    : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal busstate   : std_logic_vector(1 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal FC         : std_logic_vector(2 downto 0);
    signal nResetOut  : std_logic;

    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    constant CLK_PERIOD : time := 10 ns;
    constant RESET_HOLDOFF_CYCLES : integer := 12;
    signal test_done    : boolean := false;
    signal holdoff_done : std_logic := '0';
    signal holdoff_cnt  : integer range 0 to RESET_HOLDOFF_CYCLES := 0;

    type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
    signal mem : mem_array_t := (
        0 => x"0000", 1 => x"1000",   -- SSP = $1000
        2 => x"0000", 3 => x"0500",   -- PC  = $500

        -- Program at $500 (word $280)
        16#280# => x"45F9", 16#281# => x"0000", 16#282# => x"3000",  -- LEA $3000,A2 (TC src)
        16#283# => x"47F9", 16#284# => x"0000", 16#285# => x"3010",  -- LEA $3010,A3 (CRP src)
        16#286# => x"F012", 16#287# => x"4000",  -- PMOVE.L (A2),TC
        16#288# => x"F013", 16#289# => x"4C00",  -- PMOVE.Q (A3),CRP
        16#28A# => x"41F9", 16#28B# => x"0000", 16#28C# => x"2000",  -- LEA $2000,A0 (PTEST target)
        16#28D# => x"F010", 16#28E# => x"9F35",  -- PTESTR (A0),#7,A1  (level7,A=1->A1,FC=5)
        16#28F# => x"23C9", 16#290# => x"0000", 16#291# => x"4000",  -- MOVE.L A1,($4000).L
        16#292# => x"49F9", 16#293# => x"0000", 16#294# => x"4008",  -- LEA $4008,A4
        16#295# => x"F014", 16#296# => x"6200",  -- PMOVE.W MMUSR,(A4)
        16#297# => x"F010", 16#298# => x"2015",  -- PLOADW (A0),#5 (load ATC, set M in page descriptor)
        16#299# => x"4E72", 16#29A# => x"2700",  -- STOP

        -- TC source value at $3000 (word $1800): $00D08B00
        16#1800# => x"00D0", 16#1801# => x"8B00",
        -- CRP source value at $3010 (word $1808): $0000000200006000
        16#1808# => x"0000", 16#1809# => x"0002", 16#180A# => x"0000", 16#180B# => x"6000",

        -- Level-A descriptor table at $6000 (word $3000): entry 0 = $00006402 (DT=2 -> $6400)
        16#3000# => x"0000", 16#3001# => x"6402",
        -- Level-B descriptor at $6404 (word $3202): page descriptor $00008001 (DT=1, page $8000)
        16#3202# => x"0000", 16#3203# => x"8001",

        others => x"4E71"
    );

    impure function mem_word(byte_addr : integer) return std_logic_vector is
    begin
        return mem(byte_addr / 2);
    end function;

    type addr_array is array(0 to 15) of std_logic_vector(31 downto 0);
    type word_array is array(0 to 15) of std_logic_vector(15 downto 0);
    signal walk_addr : addr_array := (others => (others => '0'));
    signal walk_data : addr_array := (others => (others => '0'));
    signal walk_cnt  : integer := 0;
    signal wr_addr   : addr_array := (others => (others => '0'));
    signal wr_data   : word_array := (others => (others => '0'));
    signal wr_cnt    : integer := 0;
    -- Walker descriptor write-backs (PLOADW history-bit update).
    signal wb_addr   : addr_array := (others => (others => '0'));
    signal wb_data   : addr_array := (others => (others => '0'));
    signal wb_cnt    : integer := 0;

begin
    clk_process: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read => 2, VBR_Stackframe => 2, extAddr_Mode => 2,
            MUL_Mode => 2, DIV_Mode => 2, BitField => 2,
            MUL_Hardware => 1, BarrelShifter => 2
        )
        port map(
            clk => clk, nReset => nReset, clkena_in => clkena_in,
            data_in => data_in, IPL => "111", IPL_autovector => '1',
            berr => '0', CPU => "10",
            addr_out => addr_out, data_write => data_write,
            nWr => nWr, nUDS => nUDS, nLDS => nLDS, busstate => busstate,
            longword => open, nResetOut => nResetOut, FC => FC,
            clr_berr => open, skipFetch => open, regin_out => open,
            CACR_out => open, VBR_out => open,
            cache_inv_req => open, cache_op_scope => open, cache_op_cache => open,
            cacr_ie => open, cacr_de => open, cacr_ifreeze => open,
            cacr_dfreeze => open, cacr_ibe => open, cacr_dbe => open, cacr_wa => open,
            pmmu_reg_we => open, pmmu_reg_re => open, pmmu_reg_sel => open,
            pmmu_reg_wdat => open, pmmu_reg_part => open,
            pmmu_addr_log => open, pmmu_addr_phys => open,
            pmmu_cache_inhibit => open, cache_op_addr => open,
            pmmu_walker_req => pmmu_walker_req, pmmu_walker_we => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr, pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack => pmmu_walker_ack, pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => '0',
            debug_SVmode => open, debug_preSVmode => open,
            debug_FlagsSR_S => open, debug_changeMode => open,
            debug_setopcode => open, debug_exec_directSR => open,
            debug_exec_to_SR => open, debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open
        );

    mem_read: process(nReset, nResetOut, holdoff_done, busstate, addr_out, mem)
        variable a : integer;
    begin
        data_in <= x"4E71";
        if nReset = '1' and nResetOut = '1' and holdoff_done = '1' and
           (busstate = "00" or busstate = "10") and
           not has_unknown(addr_out(14 downto 1)) then
            a := to_integer(unsigned(addr_out(14 downto 1)));
            data_in <= mem(a);
        end if;
    end process;

    holdoff: process(clk)
    begin
        if rising_edge(clk) then
            if nResetOut /= '1' then
                holdoff_done <= '0'; holdoff_cnt <= 0; clkena_in <= '1';
            elsif holdoff_done = '0' then
                if holdoff_cnt < RESET_HOLDOFF_CYCLES then
                    holdoff_cnt <= holdoff_cnt + 1; clkena_in <= '0';
                else
                    holdoff_done <= '1'; clkena_in <= '1';
                end if;
            else
                clkena_in <= '1';
            end if;
        end if;
    end process;

    -- Address-aware walker mock: returns the descriptor stored in mem at the
    -- requested address (descriptors are below $20000 / within the mem range).
    walker_proc: process(clk)
        variable a : integer;
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' then
                pmmu_walker_ack <= '1';
                if pmmu_walker_addr(31 downto 17) = "000000000000000" and
                   not has_unknown(pmmu_walker_addr(16 downto 0)) then
                    a := to_integer(unsigned(pmmu_walker_addr(16 downto 0)));
                    pmmu_walker_data <= mem_word(a) & mem_word(a + 2);
                else
                    pmmu_walker_data <= x"00000000";
                end if;
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    -- Capture each accepted descriptor fetch (req and ack both high).
    walk_capture: process(clk)
        variable a : integer;
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' and pmmu_walker_ack = '1' and walk_cnt < 16 then
                if not has_unknown(pmmu_walker_addr(16 downto 0)) then
                    a := to_integer(unsigned(pmmu_walker_addr(16 downto 0)));
                    walk_addr(walk_cnt) <= pmmu_walker_addr;
                    walk_data(walk_cnt) <= mem_word(a) & mem_word(a + 2);
                    report "WALK[" & integer'image(walk_cnt) & "] addr=0x" &
                        slv32_to_hexstring(pmmu_walker_addr) & " desc=0x" &
                        slv32_to_hexstring(mem_word(a) & mem_word(a + 2)) severity note;
                    walk_cnt <= walk_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- Capture CPU data writes (A1 store, MMUSR store).
    wr_capture: process(clk)
    begin
        if rising_edge(clk) then
            if nResetOut = '1' and holdoff_done = '1' and busstate = "11" and nWr = '0'
               and wr_cnt < 16 then
                wr_addr(wr_cnt) <= addr_out;
                wr_data(wr_cnt) <= data_write;
                report "WR[" & integer'image(wr_cnt) & "] addr=0x" &
                    slv32_to_hexstring(addr_out) & " data=0x" &
                    slv32_to_hexstring(x"0000" & data_write) severity note;
                wr_cnt <= wr_cnt + 1;
            end if;
        end if;
    end process;

    -- Capture walker descriptor write-backs (PLOADW sets U/M in the descriptor).
    wb_capture: process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' and pmmu_walker_we = '1' and pmmu_walker_ack = '1'
               and wb_cnt < 8 then
                wb_addr(wb_cnt) <= pmmu_walker_addr;
                wb_data(wb_cnt) <= pmmu_walker_wdat;
                report "WB[" & integer'image(wb_cnt) & "] addr=0x" &
                    slv32_to_hexstring(pmmu_walker_addr) & " wdat=0x" &
                    slv32_to_hexstring(pmmu_walker_wdat) severity note;
                wb_cnt <= wb_cnt + 1;
            end if;
        end if;
    end process;

    stim: process
        variable fail : integer := 0;
        variable a1 : std_logic_vector(31 downto 0);
        procedure chk(got, exp : std_logic_vector(31 downto 0); tag : string) is
        begin
            if got /= exp then
                report "FAIL " & tag & ": got 0x" & slv32_to_hexstring(got) &
                    " exp 0x" & slv32_to_hexstring(exp) severity error;
                fail := fail + 1;
            else
                report "PASS " & tag & " 0x" & slv32_to_hexstring(exp) severity note;
            end if;
        end procedure;
    begin
        report "=== PMMU table-walk bus verification (PTEST) ===" severity note;
        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 7000 loop
            wait until rising_edge(clk);
            exit when (wb_cnt >= 2);
        end loop;

        report "captured walk_cnt=" & integer'image(walk_cnt) &
               " wr_cnt=" & integer'image(wr_cnt) severity note;
        assert walk_cnt >= 2 report "Timeout: expected >=2 descriptor fetches" severity failure;
        assert wr_cnt   >= 3 report "Timeout: expected A1 + MMUSR stores" severity failure;

        -- Descriptor read addresses + data along the 2-level walk.
        chk(walk_addr(0), x"00006000", "walk read[0] addr (level-A root+idx)");
        chk(walk_data(0), x"00006402", "walk read[0] descriptor (DT=2 -> $6400)");
        chk(walk_addr(1), x"00006404", "walk read[1] addr (level-B table+idx)");
        chk(walk_data(1), x"00008001", "walk read[1] descriptor (DT=1 page)");

        -- PTEST A-bit return: A1 (stored to $4000) = address of last descriptor.
        chk(wr_addr(0), x"00004000", "A1 store addr");
        a1 := wr_data(0) & wr_data(1);
        chk(a1, x"00006404", "PTEST A-bit descriptor-address return (A1)");

        -- MMUSR after a valid 2-level PTESTR walk: #levels=2, no fault bits.
        chk(wr_addr(2), x"00004008", "MMUSR store addr");
        chk(x"0000" & wr_data(2), x"00000002", "MMUSR after walk (#levels=2, no fault)");

        -- PLOADW history-bit write-backs: the walk sets U (bit 3) in the level-A
        -- table descriptor and U+M (bits 3+4) in the page descriptor, writing
        -- each back to its descriptor address.
        assert wb_cnt >= 2
            report "Timeout: expected 2 PLOADW descriptor write-backs" severity failure;
        chk(wb_addr(0), x"00006000", "PLOADW write-back[0] addr (level-A table descriptor)");
        chk(wb_data(0), x"0000640A", "PLOADW write-back[0] data (U set: $6402 -> $640A)");
        chk(wb_addr(1), x"00006404", "PLOADW write-back[1] addr (page descriptor)");
        chk(wb_data(1), x"00008019", "PLOADW write-back[1] data (U+M set: $8001 -> $8019)");

        if fail = 0 then
            report "ALL PMMU WALK-VERIFY TESTS PASSED" severity note;
        else
            report integer'image(fail) & " PMMU walk-verify checks FAILED" severity failure;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
