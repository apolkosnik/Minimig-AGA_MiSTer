-- tb_bsr_push_regression.vhd
-- Regression for FIX C (LC II post-MMU bsr.w/bsr.l):
--   bsr.w / bsr.l must push the return PC to -(A7), atomically with the push
--   write (setstate="11"). The pre-fix kernel fired set(presub) only in the
--   generic idle bsr branch, so the deferred bsr2 push (bsr.w/bsr.l) ran WITHOUT
--   presub: the write used the branch-target EA instead of -(A7), the stack slot
--   stayed $0, and the matching rts popped $0 and derailed.
--
-- Each case checks BOTH halves of the fix:
--   (1) the 32-bit return address is actually at -(A7) (= SSP-4), not $0;
--   (2) rts returns to it and the post-return marker store executes.
-- bsr.s is included as a control (it always worked) to catch over-correction.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_bsr_push_regression is
end entity;

architecture behavior of tb_bsr_push_regression is
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
    type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;

    constant SSP_VALUE : integer := 16#0800#;
    constant MARK_ADDR : integer := 16#0700#;
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
            clk => clk, nReset => nReset, clkena_in => clkena_in,
            data_in => data_in, IPL => "111", IPL_autovector => '1', berr => '0',
            CPU => "10", addr_out => addr_out, data_write => data_write,
            nWr => nWr, nUDS => nUDS, nLDS => nLDS, busstate => busstate, FC => FC,
            longword => open, nResetOut => open, clr_berr => open, skipFetch => open,
            regin_out => open, CACR_out => open, VBR_out => open,
            cache_inv_req => open, cache_op_scope => open, cache_op_cache => open,
            cache_op_addr => open, pmmu_reg_we => open, pmmu_reg_re => open,
            pmmu_reg_sel => open, pmmu_reg_wdat => open, pmmu_reg_part => open,
            pmmu_addr_log => open, pmmu_addr_phys => open, pmmu_cache_inhibit => open,
            pmmu_walker_req => open, pmmu_walker_we => open, pmmu_walker_addr => open,
            pmmu_walker_wdat => open, pmmu_walker_ack => '0',
            pmmu_walker_data => (others => '0'), pmmu_walker_berr => '0',
            debug_SVmode => open, debug_preSVmode => open, debug_FlagsSR_S => open,
            debug_changeMode => open, debug_setopcode => open, debug_exec_directSR => open,
            debug_exec_to_SR => open, debug_pmove_dn_mode => open, debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 16383 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 16383 then
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

        impure function rd_word(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2);
        end function;
        impure function rd_long(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2) & mem(byte_addr / 2 + 1);
        end function;

        -- Build a program: bsr.<form> sub ; <ret>: MOVE.W #marker,($0700).W ; STOP ; sub: rts
        -- form: 0 = bsr.s, 1 = bsr.w, 2 = bsr.l
        procedure run_case(name : string; form : integer;
                           marker : std_logic_vector(15 downto 0)) is
            variable pc       : integer := 16#0400#;
            variable ret_addr : integer;
            variable sub_addr : integer := 16#0480#;  -- in bsr.s signed-8-bit range (+126)
        begin
            for i in 0 to 16383 loop
                mem(i) := x"4E71";
            end loop;
            -- reset vectors
            mem(16#0000# / 2) := x"0000";
            mem(16#0002# / 2) := std_logic_vector(to_unsigned(SSP_VALUE, 16));
            mem(16#0004# / 2) := x"0000";
            mem(16#0006# / 2) := x"0400";
            mem(MARK_ADDR / 2) := x"0000";

            if form = 0 then            -- bsr.s sub  (disp = sub - (pc+2))
                mem(pc/2) := x"6100" or std_logic_vector(to_unsigned((sub_addr - (pc+2)) mod 256, 16));
                pc := pc + 2;
            elsif form = 1 then         -- bsr.w sub
                mem(pc/2)     := x"6100"; pc := pc + 2;
                mem(pc/2)     := std_logic_vector(to_unsigned((sub_addr - (16#0400#+2)) mod 65536, 16)); pc := pc + 2;
            else                        -- bsr.l sub  (61FF + 32-bit disp)
                mem(pc/2)     := x"61FF"; pc := pc + 2;
                mem(pc/2)     := std_logic_vector(to_unsigned(((sub_addr - (16#0400#+2)) / 65536) mod 65536, 16)); pc := pc + 2;
                mem(pc/2)     := std_logic_vector(to_unsigned((sub_addr - (16#0400#+2)) mod 65536, 16)); pc := pc + 2;
            end if;
            ret_addr := pc;             -- return address = next instruction after bsr

            -- <ret>: MOVE.W #marker,($0700).W   (31FC <marker> 0700)
            mem(pc/2) := x"31FC"; pc := pc + 2;
            mem(pc/2) := marker;   pc := pc + 2;
            mem(pc/2) := std_logic_vector(to_unsigned(MARK_ADDR, 16)); pc := pc + 2;
            -- STOP #$2700
            mem(pc/2) := x"4E72"; pc := pc + 2;
            mem(pc/2) := x"2700"; pc := pc + 2;
            -- subroutine: rts
            mem(sub_addr/2) := x"4E75";

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';
            for i in 0 to 8000 loop
                wait until rising_edge(clk);
            end loop;

            -- (1) return PC must be pushed to -(A7) = SSP-4
            if rd_long(SSP_VALUE - 4) = std_logic_vector(to_unsigned(ret_addr, 32)) then
                report "PASS: " & name & " pushed return PC $" &
                       integer'image(ret_addr) & " at SSP-4" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & name & " stack slot SSP-4 = $" &
                       integer'image(to_integer(unsigned(rd_long(SSP_VALUE - 4)))) &
                       " expected $" & integer'image(ret_addr) severity error;
                fail_count := fail_count + 1;
            end if;

            -- (2) rts must return there and run the marker store
            if rd_word(MARK_ADDR) = marker then
                report "PASS: " & name & " rts returned and marker stored" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & name & " marker = $" &
                       integer'image(to_integer(unsigned(rd_word(MARK_ADDR)))) &
                       " (rts did not return correctly)" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;
    begin
        report "=== bsr push regression (FIX C) ===" severity note;
        run_case("bsr.s", 0, x"5A5A");
        run_case("bsr.w", 1, x"BABE");
        run_case("bsr.l", 2, x"D00D");

        report "bsr push regression: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;
        if fail_count = 0 then
            report "OVERALL: ALL TESTS PASSED" severity note;
        else
            report "OVERALL: SOME TESTS FAILED" severity error;
        end if;
        test_done <= true;
        wait;
    end process;
end architecture;
