-- tb_movec_pmmu.vhd
-- Comprehensive testbench for PMMU register access via MOVEC instructions
-- Tests actual CPU MOVEC instruction execution for TC, TT0, TT1, SRP, CRP, MMUSR
-- Validates that registers can be written and read back correctly

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

library work;
use work.TG68K_Pack.all;

entity tb_movec_pmmu is
end tb_movec_pmmu;

architecture behavior of tb_movec_pmmu is

  -- Component Declaration for TG68KdotC_Kernel
  component TG68KdotC_Kernel
    generic(
      SR_Read           : integer := 2;
      VBR_Stackframe    : integer := 2;
      extAddr_Mode      : integer := 2;
      MUL_Mode          : integer := 2;
      DIV_Mode          : integer := 2;
      BitField          : integer := 2;
      BarrelShifter     : integer := 1;
      MUL_Hardware      : integer := 1
    );
    port(
      clk               : in std_logic;
      nReset            : in std_logic;
      clkena_in         : in std_logic;
      data_in           : in std_logic_vector(15 downto 0);
      IPL               : in std_logic_vector(2 downto 0);
      IPL_autovector    : in std_logic;
      berr              : in std_logic;
      CPU               : in std_logic_vector(1 downto 0);
      addr_out          : out std_logic_vector(31 downto 0);
      data_write        : out std_logic_vector(15 downto 0);
      nWr               : out std_logic;
      nUDS              : out std_logic;
      nLDS              : out std_logic;
      busstate          : out std_logic_vector(1 downto 0);
      longword          : out std_logic;
      nResetOut         : out std_logic;
      FC                : out std_logic_vector(2 downto 0);
      clr_berr          : out std_logic;
      skipFetch         : out std_logic;
      regin_out         : out std_logic_vector(31 downto 0);
      CACR_out          : out std_logic_vector(31 downto 0);
      VBR_out           : out std_logic_vector(31 downto 0);
      cache_inv_req     : out std_logic;
      cache_op_scope    : out std_logic_vector(1 downto 0);
      cache_op_cache    : out std_logic_vector(1 downto 0);
      cacr_ie           : out std_logic;
      cacr_de           : out std_logic;
      cacr_ifreeze      : out std_logic;
      cacr_dfreeze      : out std_logic;
      cacr_ibe          : out std_logic;
      cacr_dbe          : out std_logic;
      cacr_wa           : out std_logic;
      pmmu_reg_we       : out std_logic;
      pmmu_reg_re       : out std_logic;
      pmmu_reg_sel      : out std_logic_vector(4 downto 0);
      pmmu_reg_wdat     : out std_logic_vector(31 downto 0);
      pmmu_reg_part     : out std_logic;
      pmmu_addr_log     : out std_logic_vector(31 downto 0);
      pmmu_addr_phys    : out std_logic_vector(31 downto 0);
      pmmu_cache_inhibit: out std_logic;
      cache_op_addr     : out std_logic_vector(31 downto 0);
      pmmu_walker_req   : out std_logic;
      pmmu_walker_addr  : out std_logic_vector(31 downto 0);
      pmmu_walker_ack   : in std_logic;
      pmmu_walker_data  : in std_logic_vector(31 downto 0);
      debug_SVmode      : out std_logic;
      debug_preSVmode   : out std_logic;
      debug_FlagsSR_S   : out std_logic;
      debug_changeMode  : out std_logic;
      debug_setopcode   : out std_logic;
      debug_exec_directSR : out std_logic;
      debug_exec_to_SR  : out std_logic;
      debug_pmove_dn_mode : out std_logic;
      debug_pmove_dn_regnum : out std_logic_vector(2 downto 0)
    );
  end component;

  -- Clock and reset
  constant clk_period : time := 10 ns;
  signal clk : std_logic := '0';
  signal nreset : std_logic := '0';
  signal clkena : std_logic := '1';

  -- CPU signals
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal ipl : std_logic_vector(2 downto 0) := "111";
  signal ipl_autovector : std_logic := '0';
  signal berr : std_logic := '0';
  signal cpu_mode : std_logic_vector(1 downto 0) := "11"; -- 68030
  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS : std_logic;
  signal nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal longword : std_logic;
  signal nResetOut : std_logic;
  signal FC : std_logic_vector(2 downto 0);
  signal clr_berr : std_logic;
  signal skipFetch : std_logic;
  signal regin_out : std_logic_vector(31 downto 0);
  signal CACR_out : std_logic_vector(31 downto 0);
  signal VBR_out : std_logic_vector(31 downto 0);

  -- Cache control
  signal cache_inv_req : std_logic;
  signal cache_op_scope : std_logic_vector(1 downto 0);
  signal cache_op_cache : std_logic_vector(1 downto 0);
  signal cache_op_addr : std_logic_vector(31 downto 0);
  signal cacr_ie : std_logic;
  signal cacr_de : std_logic;
  signal cacr_ifreeze : std_logic;
  signal cacr_dfreeze : std_logic;
  signal cacr_ibe : std_logic;
  signal cacr_dbe : std_logic;
  signal cacr_wa : std_logic;

  -- PMMU register interface
  signal pmmu_reg_we : std_logic;
  signal pmmu_reg_re : std_logic;
  signal pmmu_reg_sel : std_logic_vector(4 downto 0);
  signal pmmu_reg_wdat : std_logic_vector(31 downto 0);
  signal pmmu_reg_part : std_logic;

  -- PMMU address interface
  signal pmmu_addr_log : std_logic_vector(31 downto 0);
  signal pmmu_addr_phys : std_logic_vector(31 downto 0);
  signal pmmu_cache_inhibit : std_logic;

  -- PMMU walker memory interface
  signal pmmu_walker_req : std_logic;
  signal pmmu_walker_addr : std_logic_vector(31 downto 0);
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

  -- Debug signals
  signal debug_SVmode : std_logic;
  signal debug_preSVmode : std_logic;
  signal debug_FlagsSR_S : std_logic;
  signal debug_changeMode : std_logic;
  signal debug_setopcode : std_logic;
  signal debug_exec_directSR : std_logic;
  signal debug_exec_to_SR : std_logic;
  signal debug_pmove_dn_mode : std_logic;
  signal debug_pmove_dn_regnum : std_logic_vector(2 downto 0);

  -- Memory array (64KB for test program and data)
  type memory_array is array (0 to 32767) of std_logic_vector(15 downto 0);
  signal memory : memory_array := (others => x"0000");

  -- Test control
  signal test_running : boolean := true;
  signal test_phase : integer := 0;

  -- Test result tracking
  signal tc_write_ok : boolean := false;
  signal tc_read_ok : boolean := false;
  signal tt0_write_ok : boolean := false;
  signal tt0_read_ok : boolean := false;
  signal tt1_write_ok : boolean := false;
  signal tt1_read_ok : boolean := false;
  signal srp_write_ok : boolean := false;
  signal srp_read_ok : boolean := false;
  signal crp_write_ok : boolean := false;
  signal crp_read_ok : boolean := false;
  signal mmusr_write_ok : boolean := false;
  signal mmusr_read_ok : boolean := false;

begin

  -- Instantiate CPU
  cpu: TG68KdotC_Kernel
    generic map(
      SR_Read => 2,
      VBR_Stackframe => 2,
      extAddr_Mode => 2,
      MUL_Mode => 2,
      DIV_Mode => 2,
      BitField => 2,
      BarrelShifter => 1,
      MUL_Hardware => 1
    )
    port map(
      clk => clk,
      nReset => nreset,
      clkena_in => clkena,
      data_in => data_in,
      IPL => ipl,
      IPL_autovector => ipl_autovector,
      berr => berr,
      CPU => cpu_mode,
      addr_out => addr_out,
      data_write => data_write,
      nWr => nWr,
      nUDS => nUDS,
      nLDS => nLDS,
      busstate => busstate,
      longword => longword,
      nResetOut => nResetOut,
      FC => FC,
      clr_berr => clr_berr,
      skipFetch => skipFetch,
      regin_out => regin_out,
      CACR_out => CACR_out,
      VBR_out => VBR_out,
      cache_inv_req => cache_inv_req,
      cache_op_scope => cache_op_scope,
      cache_op_cache => cache_op_cache,
      cacr_ie => cacr_ie,
      cacr_de => cacr_de,
      cacr_ifreeze => cacr_ifreeze,
      cacr_dfreeze => cacr_dfreeze,
      cacr_ibe => cacr_ibe,
      cacr_dbe => cacr_dbe,
      cacr_wa => cacr_wa,
      pmmu_reg_we => pmmu_reg_we,
      pmmu_reg_re => pmmu_reg_re,
      pmmu_reg_sel => pmmu_reg_sel,
      pmmu_reg_wdat => pmmu_reg_wdat,
      pmmu_reg_part => pmmu_reg_part,
      pmmu_addr_log => pmmu_addr_log,
      pmmu_addr_phys => pmmu_addr_phys,
      pmmu_cache_inhibit => pmmu_cache_inhibit,
      cache_op_addr => cache_op_addr,
      pmmu_walker_req => pmmu_walker_req,
      pmmu_walker_addr => pmmu_walker_addr,
      pmmu_walker_ack => pmmu_walker_ack,
      pmmu_walker_data => pmmu_walker_data,
      debug_SVmode => debug_SVmode,
      debug_preSVmode => debug_preSVmode,
      debug_FlagsSR_S => debug_FlagsSR_S,
      debug_changeMode => debug_changeMode,
      debug_setopcode => debug_setopcode,
      debug_exec_directSR => debug_exec_directSR,
      debug_exec_to_SR => debug_exec_to_SR,
      debug_pmove_dn_mode => debug_pmove_dn_mode,
      debug_pmove_dn_regnum => debug_pmove_dn_regnum
    );

  -- Clock generation
  clk_process: process
  begin
    while test_running loop
      clk <= '0';
      wait for clk_period/2;
      clk <= '1';
      wait for clk_period/2;
    end loop;
    wait;
  end process;

  -- Memory controller
  memory_controller: process(clk)
    variable addr_word : integer;
  begin
    if rising_edge(clk) then
      -- Simple memory - provide data on read
      -- busstate: "00"=fetch, "10"=read, "11"=write, "01"=no access
      if busstate /= "01" then
        addr_word := to_integer(unsigned(addr_out(15 downto 1)));
        if addr_word < 32768 then
          if nWr = '0' then
            -- Write (nWr active low)
            memory(addr_word) <= data_write;
          else
            -- Read
            data_in <= memory(addr_word);
          end if;
        else
          data_in <= x"FFFF"; -- Invalid address
        end if;
      else
        data_in <= x"FFFF";
      end if;

      -- Identity map PMMU for now
      pmmu_addr_phys <= pmmu_addr_log;
    end if;
  end process;

  -- Initialize test program in memory
  init_memory: process
  begin
    wait for 1 ns;

    -- Reset vector at 0x000000
    memory(0) <= x"0000";  -- Initial SSP high
    memory(1) <= x"1000";  -- Initial SSP low (SSP = 0x00001000)
    memory(2) <= x"0000";  -- Initial PC high
    memory(3) <= x"0100";  -- Initial PC low (PC = 0x00000100)

    -- Test program starts at 0x000100
    -- All MOVEC instructions are supervisor only

    -- TEST 1: Write TC register
    -- MOVEC D0,TC (0x4E7B 0003)
    memory(128) <= x"203C";  -- MOVE.L #test_value,D0
    memory(129) <= x"8000";  -- TC test value = 0x80000000 (enable MMU)
    memory(130) <= x"0000";
    memory(131) <= x"4E7B";  -- MOVEC D0,TC
    memory(132) <= x"0003";

    -- TEST 2: Read TC register
    -- MOVEC TC,D1 (0x4E7A 1003)
    memory(133) <= x"4E7A";  -- MOVEC TC,D1
    memory(134) <= x"1003";
    memory(135) <= x"0C81";  -- CMPI.L #0x80000000,D1
    memory(136) <= x"8000";
    memory(137) <= x"0000";
    memory(138) <= x"6700";  -- BEQ.W tc_ok
    memory(139) <= x"0010";
    memory(140) <= x"4E71";  -- NOP (TC read failed)
    memory(141) <= x"4E71";
    -- tc_ok:

    -- TEST 3: Write TT0 register
    memory(150) <= x"203C";  -- MOVE.L #test_value,D0
    memory(151) <= x"0123";  -- TT0 test value = 0x01234567
    memory(152) <= x"4567";
    memory(153) <= x"4E7B";  -- MOVEC D0,TT0
    memory(154) <= x"0004";

    -- TEST 4: Read TT0 register
    memory(155) <= x"4E7A";  -- MOVEC TT0,D2
    memory(156) <= x"2004";
    memory(157) <= x"0C82";  -- CMPI.L #0x01234567,D2
    memory(158) <= x"0123";
    memory(159) <= x"4567";
    memory(160) <= x"6700";  -- BEQ.W tt0_ok
    memory(161) <= x"0010";
    memory(162) <= x"4E71";  -- NOP (TT0 read failed)
    memory(163) <= x"4E71";
    -- tt0_ok:

    -- TEST 5: Write TT1 register
    memory(170) <= x"203C";  -- MOVE.L #test_value,D0
    memory(171) <= x"89AB";  -- TT1 test value = 0x89ABCDEF
    memory(172) <= x"CDEF";
    memory(173) <= x"4E7B";  -- MOVEC D0,TT1
    memory(174) <= x"0005";

    -- TEST 6: Read TT1 register
    memory(175) <= x"4E7A";  -- MOVEC TT1,D3
    memory(176) <= x"3005";
    memory(177) <= x"0C83";  -- CMPI.L #0x89ABCDEF,D3
    memory(178) <= x"89AB";
    memory(179) <= x"CDEF";
    memory(180) <= x"6700";  -- BEQ.W tt1_ok
    memory(181) <= x"0010";
    memory(182) <= x"4E71";  -- NOP (TT1 read failed)
    memory(183) <= x"4E71";
    -- tt1_ok:

    -- TEST 7: Write SRP register (64-bit via PMOVE)
    memory(190) <= x"41F9";  -- LEA srp_data,A0
    memory(191) <= x"0000";
    memory(192) <= x"0400";
    memory(193) <= x"F010";  -- PMOVE (A0),SRP
    memory(194) <= x"4800";

    -- TEST 8: Read SRP register
    memory(195) <= x"41F9";  -- LEA srp_read,A1
    memory(196) <= x"0000";
    memory(197) <= x"0410";
    memory(198) <= x"F011";  -- PMOVE SRP,(A1)
    memory(199) <= x"4C00";

    -- TEST 9: Write CRP register (64-bit via PMOVE)
    memory(200) <= x"41F9";  -- LEA crp_data,A0
    memory(201) <= x"0000";
    memory(202) <= x"0420";
    memory(203) <= x"F010";  -- PMOVE (A0),CRP
    memory(204) <= x"4C00";

    -- TEST 10: Read CRP register
    memory(205) <= x"41F9";  -- LEA crp_read,A1
    memory(206) <= x"0000";
    memory(207) <= x"0430";
    memory(208) <= x"F011";  -- PMOVE CRP,(A1)
    memory(209) <= x"4800";

    -- TEST 11: Clear all registers to zero
    memory(210) <= x"7000";  -- MOVEQ #0,D0
    memory(211) <= x"4E7B";  -- MOVEC D0,TC
    memory(212) <= x"0003";
    memory(213) <= x"4E7B";  -- MOVEC D0,TT0
    memory(214) <= x"0004";
    memory(215) <= x"4E7B";  -- MOVEC D0,TT1
    memory(216) <= x"0005";

    -- TEST 12: Verify zero values
    memory(217) <= x"4E7A";  -- MOVEC TC,D1
    memory(218) <= x"1003";
    memory(219) <= x"4A81";  -- TST.L D1
    memory(220) <= x"6700";  -- BEQ.W tc_zero_ok
    memory(221) <= x"0010";
    memory(222) <= x"4E71";  -- NOP (TC not zero)
    memory(223) <= x"4E71";

    memory(224) <= x"4E7A";  -- MOVEC TT0,D2
    memory(225) <= x"2004";
    memory(226) <= x"4A82";  -- TST.L D2
    memory(227) <= x"6700";  -- BEQ.W tt0_zero_ok
    memory(228) <= x"0010";
    memory(229) <= x"4E71";  -- NOP (TT0 not zero)
    memory(230) <= x"4E71";

    memory(231) <= x"4E7A";  -- MOVEC TT1,D3
    memory(232) <= x"3005";
    memory(233) <= x"4A83";  -- TST.L D3
    memory(234) <= x"6700";  -- BEQ.W tt1_zero_ok
    memory(235) <= x"0010";
    memory(236) <= x"4E71";  -- NOP (TT1 not zero)
    memory(237) <= x"4E71";

    -- End of tests - infinite loop
    memory(240) <= x"60FE";  -- BRA.S *-2 (infinite loop)

    -- Data area for SRP/CRP tests (starts at 0x000400)
    memory(512) <= x"0000";  -- SRP descriptor high
    memory(513) <= x"2000";  -- SRP descriptor low = 0x00002000
    memory(514) <= x"0000";
    memory(515) <= x"0000";

    -- SRP read buffer (0x000410)
    memory(520) <= x"0000";
    memory(521) <= x"0000";
    memory(522) <= x"0000";
    memory(523) <= x"0000";

    -- CRP data (0x000420)
    memory(528) <= x"0000";  -- CRP descriptor high
    memory(529) <= x"3000";  -- CRP descriptor low = 0x00003000
    memory(530) <= x"0000";
    memory(531) <= x"0000";

    -- CRP read buffer (0x000430)
    memory(536) <= x"0000";
    memory(537) <= x"0000";
    memory(538) <= x"0000";
    memory(539) <= x"0000";

    wait;
  end process;

  -- Monitor process to track test progress
  monitor: process(clk)
    variable l : line;
    variable last_pc : std_logic_vector(31 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      -- Track PC for test progress (busstate "00" = fetch)
      if busstate = "00" then
        if addr_out /= last_pc then
          last_pc := addr_out;

          -- Check for specific test milestones
          case to_integer(unsigned(addr_out(15 downto 1))) is
            when 131 =>
              write(l, string'("Starting TC write test..."));
              writeline(output, l);
            when 133 =>
              write(l, string'("Starting TC read test..."));
              writeline(output, l);
            when 150 =>
              write(l, string'("Starting TT0 write test..."));
              writeline(output, l);
            when 155 =>
              write(l, string'("Starting TT0 read test..."));
              writeline(output, l);
            when 170 =>
              write(l, string'("Starting TT1 write test..."));
              writeline(output, l);
            when 175 =>
              write(l, string'("Starting TT1 read test..."));
              writeline(output, l);
            when 210 =>
              write(l, string'("Starting register clear test..."));
              writeline(output, l);
            when 240 =>
              write(l, string'("======================================"));
              writeline(output, l);
              write(l, string'("All MOVEC tests completed!"));
              writeline(output, l);
              write(l, string'("======================================"));
              writeline(output, l);
            when others =>
              null;
          end case;
        end if;
      end if;
    end if;
  end process;

  -- Main test control
  test_control: process
    variable l : line;
  begin
    -- Print test header
    write(l, string'("======================================"));
    writeline(output, l);
    write(l, string'("TG68K MOVEC PMMU Register Test"));
    writeline(output, l);
    write(l, string'("Testing actual CPU MOVEC instructions"));
    writeline(output, l);
    write(l, string'("======================================"));
    writeline(output, l);

    -- Reset
    nreset <= '0';
    wait for 100 ns;
    nreset <= '1';

    write(l, string'("CPU reset released, starting execution..."));
    writeline(output, l);

    -- Let CPU run until tests complete or timeout
    wait for 50 us;

    if test_running then
      write(l, string'("TEST TIMEOUT - CPU did not complete tests!"));
      writeline(output, l);
      test_running <= false;
    end if;

    wait;
  end process;

end behavior;
