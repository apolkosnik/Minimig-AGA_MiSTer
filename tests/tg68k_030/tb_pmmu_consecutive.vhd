-- CPU-level regression for adjacent MC68030 PMMU instructions.
-- Exercises F-line context retirement, register selection, and write data with
-- no intervening non-MMU instruction under several bus acknowledgement delays.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity tb_pmmu_consecutive is
end entity;

architecture behavior of tb_pmmu_consecutive is
    constant CLK_PERIOD  : time := 10 ns;
    constant SOURCE0     : integer := 16#2300#;
    constant SOURCE1     : integer := 16#2304#;
    constant RESULT0     : integer := 16#2400#;
    constant RESULT1     : integer := 16#2404#;
    constant MMUSR0      : integer := 16#2408#;
    constant MMUSR1      : integer := 16#240A#;
    constant TT0_VALUE   : std_logic_vector(31 downto 0) := x"00FF8107";
    constant TT1_VALUE   : std_logic_vector(31 downto 0) := x"5A5A0252";

    signal clk           : std_logic := '0';
    signal nReset        : std_logic := '0';
    signal clkena_in     : std_logic := '1';
    signal beat_valid_in : std_logic := '1';
    signal data_in       : std_logic_vector(15 downto 0);
    signal data_write    : std_logic_vector(15 downto 0);
    signal addr_out      : std_logic_vector(31 downto 0);
    signal nWr           : std_logic;
    signal nUDS          : std_logic;
    signal nLDS          : std_logic;
    signal busstate      : std_logic_vector(1 downto 0);
    signal FC            : std_logic_vector(2 downto 0);
    signal berr_in       : std_logic := '0';
    signal pmmu_reg_we   : std_logic;
    signal pmmu_reg_sel  : std_logic_vector(4 downto 0);
    signal pmmu_reg_wdat : std_logic_vector(31 downto 0);
    signal wait_mode     : integer range 0 to 2 := 0;
    signal wait_phase    : integer range 0 to 7 := 0;
    signal fault_extension_enable : std_logic := '0';
    signal invalid_decode_seen    : std_logic := '0';
    signal invalid_decode_advanced : std_logic := '0';
    signal debug_fline_context_valid : std_logic;
    signal debug_micro_state      : integer range 0 to 255;
    signal debug_next_micro_state : integer range 0 to 255;
    signal test_done     : boolean := false;

    type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
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
            beat_valid => beat_valid_in,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '1',
            berr => berr_in,
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
            pmmu_reg_we => pmmu_reg_we,
            pmmu_reg_re => open,
            pmmu_reg_sel => pmmu_reg_sel,
            pmmu_reg_wdat => pmmu_reg_wdat,
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
            debug_pmove_dn_regnum => open,
            debug_fline_context_valid => debug_fline_context_valid,
            debug_micro_state => debug_micro_state,
            debug_next_micro_state => debug_next_micro_state
        );

    berr_in <= '1' when fault_extension_enable = '1' and busstate = "00" and
                        nWr = '1' and addr_out = x"0000100C"
               else '0';
    beat_valid_in <= '0' when fault_extension_enable = '1' and busstate = "00" and
                              nWr = '1' and addr_out = x"0000100C"
                     else '1';

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 16383
               else x"4E71";

    -- Internal execute cycles are never stalled. Bus cycles use increasingly
    -- sparse deterministic acknowledgements to expose live/latched mismatches.
    ack_driver: process(clk)
    begin
        if falling_edge(clk) then
            if nReset = '0' then
                wait_phase <= 0;
                clkena_in <= '1';
            elsif busstate(1) = '0' or wait_mode = 0 then
                wait_phase <= 0;
                clkena_in <= '1';
            else
                if wait_phase = 7 then
                    wait_phase <= 0;
                else
                    wait_phase <= wait_phase + 1;
                end if;

                if (wait_mode = 1 and (wait_phase mod 3) = 2) or
                   (wait_mode = 2 and (wait_phase = 1 or wait_phase = 6)) then
                    clkena_in <= '1';
                else
                    clkena_in <= '0';
                end if;
            end if;
        end if;
    end process;

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if clkena_in = '1' and busstate = "11" and nWr = '0' and
               to_integer(unsigned(addr_out(15 downto 1))) <= 16383 then
                if nUDS = '0' then
                    mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) :=
                        data_write(15 downto 8);
                end if;
                if nLDS = '0' then
                    mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) :=
                        data_write(7 downto 0);
                end if;
            end if;
        end if;
    end process;

    invalid_context_guard: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                invalid_decode_seen <= '0';
                invalid_decode_advanced <= '0';
            elsif fault_extension_enable = '1' and
                  debug_micro_state = micro_states'pos(pmove_decode) and
                  debug_fline_context_valid = '0' then
                invalid_decode_seen <= '1';
                if debug_next_micro_state /= micro_states'pos(pmove_decode) then
                    invalid_decode_advanced <= '1';
                end if;
            end if;
        end if;
    end process;

    test: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

        impure function read_long(byte_addr : integer) return std_logic_vector is
        begin
            return mem(byte_addr / 2) & mem(byte_addr / 2 + 1);
        end function;

        procedure init_program is
        begin
            for i in 0 to 16383 loop
                mem(i) := x"4E71";
            end loop;

            mem(0) := x"0000"; mem(1) := x"2000"; -- initial SSP
            mem(2) := x"0000"; mem(3) := x"1000"; -- initial PC

            mem(SOURCE0 / 2) := TT0_VALUE(31 downto 16);
            mem(SOURCE0 / 2 + 1) := TT0_VALUE(15 downto 0);
            mem(SOURCE1 / 2) := TT1_VALUE(31 downto 16);
            mem(SOURCE1 / 2 + 1) := TT1_VALUE(15 downto 0);
            mem(RESULT0 / 2) := x"DEAD";
            mem(RESULT0 / 2 + 1) := x"BEEF";
            mem(RESULT1 / 2) := x"DEAD";
            mem(RESULT1 / 2 + 1) := x"BEEF";
            mem(MMUSR0 / 2) := x"DEAD";
            mem(MMUSR1 / 2) := x"BEEF";

            mem(16#1000# / 2) := x"207C"; -- MOVEA.L #SOURCE0,A0
            mem(16#1002# / 2) := x"0000";
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(SOURCE0, 16));
            mem(16#1006# / 2) := x"227C"; -- MOVEA.L #SOURCE1,A1
            mem(16#1008# / 2) := x"0000";
            mem(16#100A# / 2) := std_logic_vector(to_unsigned(SOURCE1, 16));
            mem(16#100C# / 2) := x"247C"; -- MOVEA.L #RESULT0,A2
            mem(16#100E# / 2) := x"0000";
            mem(16#1010# / 2) := std_logic_vector(to_unsigned(RESULT0, 16));
            mem(16#1012# / 2) := x"267C"; -- MOVEA.L #RESULT1,A3
            mem(16#1014# / 2) := x"0000";
            mem(16#1016# / 2) := std_logic_vector(to_unsigned(RESULT1, 16));
            mem(16#1018# / 2) := x"287C"; -- MOVEA.L #$1000,A4 (PTEST EA)
            mem(16#101A# / 2) := x"0000";
            mem(16#101C# / 2) := x"1000";
            mem(16#101E# / 2) := x"2A7C"; -- MOVEA.L #MMUSR0,A5
            mem(16#1020# / 2) := x"0000";
            mem(16#1022# / 2) := std_logic_vector(to_unsigned(MMUSR0, 16));
            mem(16#1024# / 2) := x"2C7C"; -- MOVEA.L #MMUSR1,A6
            mem(16#1026# / 2) := x"0000";
            mem(16#1028# / 2) := std_logic_vector(to_unsigned(MMUSR1, 16));

            -- Adjacent F-line operations with different selectors, directions,
            -- command engines, and completion latencies.
            mem(16#102A# / 2) := x"F010"; -- PMOVE (A0),TT0
            mem(16#102C# / 2) := x"0800";
            mem(16#102E# / 2) := x"F011"; -- PMOVE (A1),TT1
            mem(16#1030# / 2) := x"0C00";
            mem(16#1032# / 2) := x"F012"; -- PMOVE TT0,(A2)
            mem(16#1034# / 2) := x"0A00";
            mem(16#1036# / 2) := x"F013"; -- PMOVE TT1,(A3)
            mem(16#1038# / 2) := x"0E00";
            mem(16#103A# / 2) := x"F014"; -- PTESTR (A4),level 0,FC=5
            mem(16#103C# / 2) := x"8215";
            mem(16#103E# / 2) := x"F015"; -- PMOVE MMUSR,(A5)
            mem(16#1040# / 2) := x"6200";
            mem(16#1042# / 2) := x"F000"; -- PFLUSHA
            mem(16#1044# / 2) := x"2400";
            mem(16#1046# / 2) := x"F014"; -- PTESTR again: edge must re-arm
            mem(16#1048# / 2) := x"8215";
            mem(16#104A# / 2) := x"F016"; -- PMOVE MMUSR,(A6)
            mem(16#104C# / 2) := x"6200";
            mem(16#104E# / 2) := x"4E72"; -- STOP #$2700
            mem(16#1050# / 2) := x"2700";
        end procedure;

        procedure init_control_program is
        begin
            init_program;
            -- Same operations and operands, with one non-F-line retirement
            -- between each PMMU instruction.
            mem(16#102A# / 2) := x"F010";
            mem(16#102C# / 2) := x"0800";
            mem(16#102E# / 2) := x"4E71";
            mem(16#1030# / 2) := x"F011";
            mem(16#1032# / 2) := x"0C00";
            mem(16#1034# / 2) := x"4E71";
            mem(16#1036# / 2) := x"F012";
            mem(16#1038# / 2) := x"0A00";
            mem(16#103A# / 2) := x"4E71";
            mem(16#103C# / 2) := x"F013";
            mem(16#103E# / 2) := x"0E00";
            mem(16#1040# / 2) := x"4E72";
            mem(16#1042# / 2) := x"2700";
        end procedure;

        procedure init_fault_extension_program is
        begin
            for i in 0 to 16383 loop
                mem(i) := x"4E71";
            end loop;

            mem(0) := x"0000"; mem(1) := x"2000"; -- initial SSP
            mem(2) := x"0000"; mem(3) := x"1000"; -- initial PC
            mem(4) := x"0000"; mem(5) := x"1200"; -- bus-error vector
            mem(SOURCE0 / 2) := TT0_VALUE(31 downto 16);
            mem(SOURCE0 / 2 + 1) := TT0_VALUE(15 downto 0);

            mem(16#1000# / 2) := x"207C"; -- MOVEA.L #SOURCE0,A0
            mem(16#1002# / 2) := x"0000";
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(SOURCE0, 16));
            mem(16#1006# / 2) := x"F010"; -- PMOVE (A0),TT0; seeds old brief
            mem(16#1008# / 2) := x"0800";
            mem(16#100A# / 2) := x"F010"; -- extension fetch at $100C faults
            mem(16#100C# / 2) := x"0800";
            mem(16#100E# / 2) := x"4E72";
            mem(16#1010# / 2) := x"2700";
            mem(16#1200# / 2) := x"4E72"; -- bus-error handler: STOP
            mem(16#1202# / 2) := x"2700";
        end procedure;

        procedure run_case(mode : integer) is
            variable started    : boolean := false;
            variable idle_count : integer := 0;
        begin
            wait_mode <= mode;
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 30000 loop
                wait until rising_edge(clk);
                if busstate /= "01" then
                    started := true;
                    idle_count := 0;
                elsif started and clkena_in = '1' then
                    idle_count := idle_count + 1;
                    if idle_count >= 20 then
                        return;
                    end if;
                end if;
            end loop;

            report "FAIL: timeout in wait mode " & integer'image(mode) severity error;
            fail_count := fail_count + 1;
        end procedure;

        procedure check_case(case_name : string; mode : integer) is
        begin
            if read_long(RESULT0) = TT0_VALUE and read_long(RESULT1) = TT1_VALUE and
               (case_name /= "adjacent PMOVE sequence" or
                (mem(MMUSR0 / 2) = x"0040" and mem(MMUSR1 / 2) = x"0040")) then
                report "PASS: " & case_name & ", wait mode " & integer'image(mode) severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & case_name & ", wait mode " & integer'image(mode) &
                       " TT0=$" & integer'image(to_integer(unsigned(read_long(RESULT0)))) &
                       " TT1=$" & integer'image(to_integer(unsigned(read_long(RESULT1)))) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;
    begin
        report "=== Consecutive PMMU instruction regression ===" severity note;

        init_fault_extension_program;
        fault_extension_enable <= '1';
        run_case(0);
        fault_extension_enable <= '0';
        if invalid_decode_seen = '1' and invalid_decode_advanced = '0' then
            report "PASS: fault-released F-line extension cannot dispatch stale context" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: invalid F-line context advanced through PMMU decode" severity error;
            fail_count := fail_count + 1;
        end if;

        for mode in 1 to 2 loop
            init_control_program;
            run_case(mode);
            check_case("NOP-separated PMOVE control", mode);
        end loop;

        for mode in 0 to 2 loop
            init_program;
            run_case(mode);
            check_case("adjacent PMOVE sequence", mode);
        end loop;

        report "Consecutive PMMU tests: " & integer'image(pass_count) &
               " PASSED, " & integer'image(fail_count) & " FAILED" severity note;
        assert fail_count = 0 report "Consecutive PMMU instruction regression failed" severity failure;
        test_done <= true;
        wait;
    end process;
end architecture;
