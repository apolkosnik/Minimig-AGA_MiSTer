library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity tb_moves_validation is
end tb_moves_validation;

architecture tb of tb_moves_validation is
  -- Clock and reset
  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  constant CLK_PERIOD : time := 10 ns;

  -- CPU signals
  signal clkena_in : std_logic := '1';
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS, nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal FC : std_logic_vector(2 downto 0);
  signal CPU : std_logic_vector(1 downto 0) := "10";  -- 68030

  -- PMMU walker (unused but required)
  signal pmmu_walker_req : std_logic;
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

  -- Test control
  signal test_done : std_logic := '0';
  signal test_done_timeout : std_logic := '0';
  signal test_done_validation : std_logic := '0';
  constant VERBOSE : boolean := true;
  constant FC_DFC : std_logic_vector(2 downto 0) := "110";
  constant FC_SFC : std_logic_vector(2 downto 0) := "101";

  type test_status_t is (pending, pass, fail);
  type test_status_array_t is array (1 to 6) of test_status_t;
  signal test_status : test_status_array_t := (others => pending);

  -- Memory
  type mem_array is array(0 to 8191) of std_logic_vector(15 downto 0);
  signal mem : mem_array := (others => x"4E71"); -- Default to NOP instead of 0xFFFF

  -- Expected values for validation
  signal expected_write_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal expected_write_data : std_logic_vector(31 downto 0) := (others => '0');
  signal expected_write_size : integer := 0;  -- 1=byte, 2=word, 4=long
  signal expected_write_test : integer range 0 to 6 := 0;
  signal expected_write_word_index : integer range 0 to 1 := 0;
  signal expecting_write : boolean := false;

  signal expected_read_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal expected_read_data : std_logic_vector(15 downto 0) := (others => '0');
  signal expected_read_size : integer := 0;  -- 1=byte, 2=word
  signal expected_read_test : integer range 0 to 6 := 0;
  signal expecting_read : boolean := false;

begin
  test_done <= test_done_timeout or test_done_validation;

  -- DUT
  cpu_dut: entity work.TG68KdotC_Kernel
    port map (
      clk => clk,
      nReset => nReset,
      clkena_in => clkena_in,
      data_in => data_in,
      IPL => "111",
      IPL_autovector => '0',
      berr => '0',
      CPU => CPU,
      addr_out => addr_out,
      data_write => data_write,
      nWr => nWr,
      nUDS => nUDS,
      nLDS => nLDS,
      busstate => busstate,
      longword => open,
      nResetOut => open,
      FC => FC,
      clr_berr => open,
      skipFetch => open,
      regin_out => open,
      CACR_out => open,
      VBR_out => open,
      cache_inv_req => open,
      cache_op_scope => open,
      cache_op_cache => open,
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
      cache_op_addr => open,
      pmmu_walker_req => pmmu_walker_req,
      pmmu_walker_we => open,
      pmmu_walker_addr => open,
      pmmu_walker_wdat => open,
      pmmu_walker_ack => pmmu_walker_ack,
      pmmu_walker_data => pmmu_walker_data,
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
      debug_opcode => open,
      debug_state => open, debug_setstate => open,
      debug_last_opc_read => open, debug_data_read => open,
      debug_direct_data => open, debug_setnextpass => open,
      debug_TG68_PC => open, debug_memaddr_reg => open,
      debug_memaddr_delta => open, debug_oddout => open,
      debug_decodeOPC => open
    );

  -- Clock
  clk_process: process
  begin
    if test_done = '0' then
      clk <= '0';
      wait for CLK_PERIOD/2;
      clk <= '1';
      wait for CLK_PERIOD/2;
    else
      wait;
    end if;
  end process;

  -- Memory initialization
  mem_init: process
  begin
    wait for 1 ns;

    -- Exception vectors
    mem(0) <= x"0000";
    mem(1) <= x"2000";  -- SSP
    mem(2) <= x"0000";
    mem(3) <= x"0000";  -- Vector 1 address (used by MOVE.L (abs),A7 as pointer)
    -- Put JMP to $100 at address 8 (word 4) because kernel fetches here next
    mem(4) <= x"4EF9";
    mem(5) <= x"0000";
    mem(6) <= x"0100";  -- Reset PC at address 12? No, JMP 0x100.
    -- Ensure address $4 has $0 so MOVE loads from $0
    mem(2) <= x"0000";
    mem(3) <= x"0000";
    -- At address $100, we have the first instruction
    mem(16#100# / 2) <= x"46FC";  -- MOVE #$2700,SR
    mem(16#102# / 2) <= x"2700";
    mem(16#104# / 2) <= x"203C";  -- MOVE.L #$00000005,D0
    mem(16#106# / 2) <= x"0000";
    mem(16#108# / 2) <= x"0005";
    mem(16#10A# / 2) <= x"4E7B";  -- MOVEC D0,SFC
    mem(16#10C# / 2) <= x"0000";
    mem(16#10E# / 2) <= x"203C";  -- MOVE.L #$00000006,D0
    mem(16#110# / 2) <= x"0000";
    mem(16#112# / 2) <= x"0006";
    mem(16#114# / 2) <= x"4E7B";  -- MOVEC D0,DFC
    mem(16#116# / 2) <= x"0001";

    -- TEST 1: MOVES.B D1,(A0) - Write byte with DFC
    mem(16#118# / 2) <= x"207C";  -- MOVEA.L #$3000,A0
    mem(16#11A# / 2) <= x"0000";
    mem(16#11C# / 2) <= x"3000";
    mem(16#11E# / 2) <= x"323C";  -- MOVE.W #$00AB,D1
    mem(16#120# / 2) <= x"00AB";
    mem(16#122# / 2) <= x"0E10";  -- MOVES.B D1,(A0)
    mem(16#124# / 2) <= x"1800";  -- Reg: D1(001), dr=1(Write) -> 0001 1000 = $1800
    mem(16#126# / 2) <= x"4E71";  -- NOP (test 1 marker)

    -- TEST 2: MOVES.W D2,(A0)+ - Write word with DFC, postincrement
    mem(16#128# / 2) <= x"343C";  -- MOVE.W #$1234,D2
    mem(16#12A# / 2) <= x"1234";
    mem(16#12C# / 2) <= x"0E18";  -- MOVES.W D2,(A0)+
    mem(16#12E# / 2) <= x"2800";  -- Reg: D2(010), dr=1(Write) -> 0010 1000 = $2800
    mem(16#130# / 2) <= x"4E71";  -- NOP (test 2 marker)

    -- TEST 3: MOVES.L D3,-(A0) - Write long with DFC, predecrement
    mem(16#132# / 2) <= x"263C";  -- MOVE.L #$DEADBEEF,D3
    mem(16#134# / 2) <= x"DEAD";
    mem(16#136# / 2) <= x"BEEF";
    mem(16#138# / 2) <= x"0E20";  -- MOVES.L D3,-(A0)
    mem(16#13A# / 2) <= x"3800";  -- Reg: D3(011), dr=1(Write) -> 0011 1000 = $3800
    mem(16#13C# / 2) <= x"4E71";  -- NOP (test 3 marker)

    -- TEST 4: MOVES.B (A0),D4 - Read byte with SFC
    mem(16#13E# / 2) <= x"207C";  -- MOVEA.L #$3010,A0
    mem(16#140# / 2) <= x"0000";
    mem(16#142# / 2) <= x"3010";
    mem(16#144# / 2) <= x"0E10";  -- MOVES.B (A0),D4
    mem(16#146# / 2) <= x"4000";  -- Reg: D4(100), dr=0(Read) -> 0100 0000 = $4000
    mem(16#148# / 2) <= x"4E71";  -- NOP (test 4 marker)

    -- TEST 5: MOVES.W (A0)+,D5 - Read word with SFC
    mem(16#14A# / 2) <= x"0E18";  -- MOVES.W (A0)+,D5
    mem(16#14C# / 2) <= x"5000";  -- Reg: D5(101), dr=0(Read) -> 0101 0000 = $5000
    mem(16#14E# / 2) <= x"4E71";  -- NOP (test 5 marker)

    -- TEST 6: Privilege test - MOVES in user mode should trap
    mem(16#150# / 2) <= x"46FC";  -- MOVE #$0000,SR (user mode)
    mem(16#152# / 2) <= x"0000";
    mem(16#154# / 2) <= x"0E10";  -- MOVES.B D0,(A0) - should trap
    mem(16#156# / 2) <= x"0000";
    mem(16#158# / 2) <= x"FFFF";  -- Should not reach

    -- Test data at $3010
    mem(16#3010# / 2) <= x"CAFE";
    mem(16#3012# / 2) <= x"BABE";

    wait;
  end process;

  -- Memory read
  mem_read: process(addr_out, busstate)
    variable addr_idx : integer;
  begin
    if busstate /= "11" then
      addr_idx := to_integer(unsigned(addr_out(13 downto 1)));
      if addr_idx < 8192 then
        data_in <= mem(addr_idx);
      else
        data_in <= x"FFFF";
      end if;
    end if;
  end process;

  -- Memory write capture
  mem_write: process(clk)
    variable addr_idx : integer;
  begin
    if rising_edge(clk) then
      if busstate = "11" and nWr = '0' then
        addr_idx := to_integer(unsigned(addr_out(13 downto 1)));
        if addr_idx < 8192 then
          if nUDS = '0' then
            mem(addr_idx)(15 downto 8) <= data_write(15 downto 8);
          end if;
          if nLDS = '0' then
            mem(addr_idx)(7 downto 0) <= data_write(7 downto 0);
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Test validation process
  test_validation: process(clk)
    variable last_pc : std_logic_vector(31 downto 0) := (others => '0');
    variable cycle_count : integer := 0;
    variable expected_addr : std_logic_vector(31 downto 0);
    variable expected_word : std_logic_vector(15 downto 0);
    variable lane_ok : boolean;
    variable data_ok : boolean;
  begin
    if rising_edge(clk) then
      cycle_count := cycle_count + 1;

      -- Report instruction fetches for debugging
      if busstate /= "01" then -- Not idle
          report "BUS CYCLE: state=" & integer'image(to_integer(unsigned(busstate))) &
                 " addr=$" & integer'image(to_integer(unsigned(addr_out))) &
                 " FC=" & integer'image(to_integer(unsigned(FC))) &
                 " nReset=" & std_logic'image(nReset) severity note;
      end if;

      if VERBOSE and busstate = "00" and FC = FC_DFC and addr_out /= last_pc then
        if unsigned(addr_out) >= x"00000100" and unsigned(addr_out) < x"00000200" then
          report "Fetch PC=$" & integer'image(to_integer(unsigned(addr_out))) &
                 " data=$" & integer'image(to_integer(unsigned(data_in))) &
                 " cycle=" & integer'image(cycle_count) severity note;
        end if;
      end if;

      -- Track test progress by PC and set expectations
      if busstate = "00" and FC = FC_DFC and addr_out /= last_pc then
        last_pc := addr_out;

        case addr_out is
          when x"00000122" =>
            if test_status(1) = pending then
              expecting_write <= true;
              expected_write_test <= 1;
              expected_write_addr <= x"00003000";
              expected_write_data <= x"000000AB";
              expected_write_size <= 1;
              expected_write_word_index <= 0;
            end if;
          when x"0000012C" =>
            if test_status(2) = pending then
              expecting_write <= true;
              expected_write_test <= 2;
              expected_write_addr <= x"00003000";
              expected_write_data <= x"00001234";
              expected_write_size <= 2;
              expected_write_word_index <= 0;
            end if;
          when x"00000138" =>
            if test_status(3) = pending then
              expecting_write <= true;
              expected_write_test <= 3;
              expected_write_addr <= x"00002FFE";
              expected_write_data <= x"DEADBEEF";
              expected_write_size <= 4;
              expected_write_word_index <= 0;
            end if;
          when x"00000144" =>
            if test_status(4) = pending then
              expecting_read <= true;
              expected_read_test <= 4;
              expected_read_addr <= x"00003010";
              expected_read_data <= x"00CA";
              expected_read_size <= 1;
            end if;
          when x"0000014A" =>
            if test_status(5) = pending then
              expecting_read <= true;
              expected_read_test <= 5;
              expected_read_addr <= x"00003010";
              expected_read_data <= x"CAFE";
              expected_read_size <= 2;
            end if;
          when others =>
            null;
        end case;
      end if;

      -- Validate MOVES writes
      if expecting_write and busstate = "11" and nWr = '0' then
        expected_addr := expected_write_addr;
        if expected_write_size = 4 and expected_write_word_index = 1 then
          expected_addr := std_logic_vector(unsigned(expected_write_addr) + 2);
        end if;

        if addr_out /= expected_addr then
          if test_status(expected_write_test) = pending then
            report "TEST " & integer'image(expected_write_test) &
                   " FAILED: write address mismatch. Expected $" &
                   integer'image(to_integer(unsigned(expected_addr))) &
                   " got $" & integer'image(to_integer(unsigned(addr_out))) severity error;
            test_status(expected_write_test) <= fail;
          end if;
          expecting_write <= false;
          expected_write_word_index <= 0;
        else
          if FC /= FC_DFC then
            if test_status(expected_write_test) = pending then
              report "TEST " & integer'image(expected_write_test) &
                     " FAILED: FC mismatch on write. Expected 6 got " &
                     integer'image(to_integer(unsigned(FC))) severity error;
              test_status(expected_write_test) <= fail;
            end if;
            expecting_write <= false;
            expected_write_word_index <= 0;
          else
            lane_ok := true;
            data_ok := false;
            expected_word := (others => '0');

            case expected_write_size is
              when 1 =>
                expected_word := x"00" & expected_write_data(7 downto 0);
                if addr_out(0) = '0' then
                  lane_ok := (nUDS = '0');
                  data_ok := (data_write(15 downto 8) = expected_write_data(7 downto 0));
                else
                  lane_ok := (nLDS = '0');
                  data_ok := (data_write(7 downto 0) = expected_write_data(7 downto 0));
                end if;
              when 2 =>
                expected_word := expected_write_data(15 downto 0);
                lane_ok := (nUDS = '0' and nLDS = '0');
                data_ok := (data_write = expected_write_data(15 downto 0));
              when 4 =>
                lane_ok := (nUDS = '0' and nLDS = '0');
                if expected_write_word_index = 0 then
                  expected_word := expected_write_data(31 downto 16);
                else
                  expected_word := expected_write_data(15 downto 0);
                end if;
                data_ok := (data_write = expected_word);
              when others =>
                data_ok := false;
            end case;

            if lane_ok and data_ok then
              if expected_write_size = 4 and expected_write_word_index = 0 then
                expected_write_word_index <= 1;
              else
                if test_status(expected_write_test) = pending then
                  report "TEST " & integer'image(expected_write_test) &
                         " PASSED: MOVES write validated" severity note;
                  test_status(expected_write_test) <= pass;
                end if;
                expecting_write <= false;
                expected_write_word_index <= 0;
              end if;
            else
              if test_status(expected_write_test) = pending then
                if not lane_ok then
                  report "TEST " & integer'image(expected_write_test) &
                         " FAILED: write byte lanes incorrect" severity error;
                else
                  report "TEST " & integer'image(expected_write_test) &
                         " FAILED: write data mismatch. Expected $" &
                         integer'image(to_integer(unsigned(expected_word))) &
                         " got $" & integer'image(to_integer(unsigned(data_write))) severity error;
                end if;
                test_status(expected_write_test) <= fail;
              end if;
              expecting_write <= false;
              expected_write_word_index <= 0;
            end if;
          end if;
        end if;
      end if;

      -- Validate MOVES reads
      if expecting_read and busstate = "10" then
        if addr_out /= expected_read_addr then
          if test_status(expected_read_test) = pending then
            report "TEST " & integer'image(expected_read_test) &
                   " FAILED: read address mismatch. Expected $" &
                   integer'image(to_integer(unsigned(expected_read_addr))) &
                   " got $" & integer'image(to_integer(unsigned(addr_out))) severity error;
            test_status(expected_read_test) <= fail;
          end if;
          expecting_read <= false;
        else
          if FC /= FC_SFC then
            if test_status(expected_read_test) = pending then
              report "TEST " & integer'image(expected_read_test) &
                     " FAILED: FC mismatch on read. Expected 5 got " &
                     integer'image(to_integer(unsigned(FC))) severity error;
              test_status(expected_read_test) <= fail;
            end if;
            expecting_read <= false;
          else
            lane_ok := true;
            data_ok := false;
            if expected_read_size = 1 then
              if addr_out(0) = '0' then
                lane_ok := (nUDS = '0');
                data_ok := (data_in(15 downto 8) = expected_read_data(7 downto 0));
              else
                lane_ok := (nLDS = '0');
                data_ok := (data_in(7 downto 0) = expected_read_data(7 downto 0));
              end if;
            elsif expected_read_size = 2 then
              lane_ok := (nUDS = '0' and nLDS = '0');
              data_ok := (data_in = expected_read_data);
            end if;

            if lane_ok and data_ok then
              if test_status(expected_read_test) = pending then
                report "TEST " & integer'image(expected_read_test) &
                       " PASSED: MOVES read validated" severity note;
                test_status(expected_read_test) <= pass;
              end if;
            else
              if test_status(expected_read_test) = pending then
                if not lane_ok then
                  report "TEST " & integer'image(expected_read_test) &
                         " FAILED: read byte lanes incorrect" severity error;
                else
                  report "TEST " & integer'image(expected_read_test) &
                         " FAILED: read data mismatch. Expected $" &
                         integer'image(to_integer(unsigned(expected_read_data))) &
                         " got $" & integer'image(to_integer(unsigned(data_in))) severity error;
                end if;
                test_status(expected_read_test) <= fail;
              end if;
            end if;
            expecting_read <= false;
          end if;
        end if;
      end if;

      -- Detect privilege violation
      if busstate = "10" and addr_out = x"00000020" and test_done = '0' then
        if test_status(6) = pending then
          report "TEST 6 PASSED: Privilege violation trapped for MOVES in user mode" severity note;
          test_status(6) <= pass;
        end if;
        test_done_validation <= '1';
      end if;

      -- Error: reached illegal instruction
      if busstate = "00" and addr_out = x"00000158" and test_done = '0' then
        if test_status(6) = pending then
          report "TEST 6 FAILED: Did not trap on MOVES in user mode!" severity error;
          test_status(6) <= fail;
        end if;
        test_done_validation <= '1';
      end if;
    end if;
  end process;

  -- Reset
  reset_proc: process
  begin
    nReset <= '0';
    wait for 50 ns;
    nReset <= '1';
    report "=== MOVES VALIDATION TEST STARTED ===" severity note;
    wait;
  end process;

  -- Timeout
  timeout: process
  begin
    wait for 20 us;
    if test_done = '0' then
      report "TEST TIMEOUT!" severity error;
      test_done_timeout <= '1';
    end if;
    wait;
  end process;

  -- Results
  results: process
    variable passed : integer := 0;
    variable failed : integer := 0;
  begin
    wait until test_done = '1';
    wait for 100 ns;
    passed := 0;
    failed := 0;
    report "======================================" severity note;
    report "MOVES VALIDATION TEST COMPLETE" severity note;
    report "======================================" severity note;

    if test_status(1) = pass then
      report "TEST 1: PASS - MOVES.B D1,(A0)" severity note;
      passed := passed + 1;
    elsif test_status(1) = fail then
      report "TEST 1: FAIL - MOVES.B D1,(A0)" severity error;
      failed := failed + 1;
    else
      report "TEST 1: FAIL - MOVES.B D1,(A0) (not observed)" severity error;
      failed := failed + 1;
    end if;

    if test_status(2) = pass then
      report "TEST 2: PASS - MOVES.W D2,(A0)+" severity note;
      passed := passed + 1;
    elsif test_status(2) = fail then
      report "TEST 2: FAIL - MOVES.W D2,(A0)+" severity error;
      failed := failed + 1;
    else
      report "TEST 2: FAIL - MOVES.W D2,(A0)+ (not observed)" severity error;
      failed := failed + 1;
    end if;

    if test_status(3) = pass then
      report "TEST 3: PASS - MOVES.L D3,-(A0)" severity note;
      passed := passed + 1;
    elsif test_status(3) = fail then
      report "TEST 3: FAIL - MOVES.L D3,-(A0)" severity error;
      failed := failed + 1;
    else
      report "TEST 3: FAIL - MOVES.L D3,-(A0) (not observed)" severity error;
      failed := failed + 1;
    end if;

    if test_status(4) = pass then
      report "TEST 4: PASS - MOVES.B (A0),D4" severity note;
      passed := passed + 1;
    elsif test_status(4) = fail then
      report "TEST 4: FAIL - MOVES.B (A0),D4" severity error;
      failed := failed + 1;
    else
      report "TEST 4: FAIL - MOVES.B (A0),D4 (not observed)" severity error;
      failed := failed + 1;
    end if;

    if test_status(5) = pass then
      report "TEST 5: PASS - MOVES.W (A0)+,D5" severity note;
      passed := passed + 1;
    elsif test_status(5) = fail then
      report "TEST 5: FAIL - MOVES.W (A0)+,D5" severity error;
      failed := failed + 1;
    else
      report "TEST 5: FAIL - MOVES.W (A0)+,D5 (not observed)" severity error;
      failed := failed + 1;
    end if;

    if test_status(6) = pass then
      report "TEST 6: PASS - MOVES traps in user mode" severity note;
      passed := passed + 1;
    elsif test_status(6) = fail then
      report "TEST 6: FAIL - MOVES traps in user mode" severity error;
      failed := failed + 1;
    else
      report "TEST 6: FAIL - MOVES traps in user mode (not observed)" severity error;
      failed := failed + 1;
    end if;

    report "======================================" severity note;
    report "Tests passed: " & integer'image(passed) severity note;
    report "Tests failed: " & integer'image(failed) severity note;
    report "======================================" severity note;

    if failed = 0 then
      report "ALL TESTS PASSED!" severity note;
    else
      report "SOME TESTS FAILED!" severity error;
    end if;

    wait;
  end process;

end tb;
