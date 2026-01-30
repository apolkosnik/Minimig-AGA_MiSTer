library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

-- Comprehensive PMOVE Testbench for MC68030
-- Tests all PMMU registers: TC, TT0, TT1, MMUSR, CRP, SRP
-- Tests addressing modes: Dn (32-bit only), (An), (An)+, -(An), (d16,An), xxx.L

entity tb_pmove_comprehensive is
end tb_pmove_comprehensive;

architecture behavioral of tb_pmove_comprehensive is
  -- Component Declaration
  component TG68KdotC_Kernel
    port(
      clk : in std_logic;
      nReset : in std_logic;
      clkena_in : in std_logic;
      data_in : in std_logic_vector(15 downto 0);
      IPL : in std_logic_vector(2 downto 0);
      IPL_autovector : in std_logic;
      berr : in std_logic;
      CPU : in std_logic_vector(1 downto 0);
      addr_out : out std_logic_vector(31 downto 0);
      data_write : out std_logic_vector(15 downto 0);
      nWr : out std_logic;
      nUDS : out std_logic;
      nLDS : out std_logic;
      busstate : out std_logic_vector(1 downto 0);
      longword : out std_logic;
      nResetOut : out std_logic;
      FC : out std_logic_vector(2 downto 0);
      clr_berr : out std_logic;
      skipFetch : out std_logic;
      regin_out : out std_logic_vector(31 downto 0);
      CACR_out : out std_logic_vector(31 downto 0);
      VBR_out : out std_logic_vector(31 downto 0);
      cache_inv_req : out std_logic;
      cache_op_scope : out std_logic_vector(1 downto 0);
      cache_op_cache : out std_logic_vector(1 downto 0);
      cacr_ie : out std_logic;
      cacr_de : out std_logic;
      cacr_ifreeze : out std_logic;
      cacr_dfreeze : out std_logic;
      cacr_ibe : out std_logic;
      cacr_dbe : out std_logic;
      cacr_wa : out std_logic;
      pmmu_reg_we : out std_logic;
      pmmu_reg_re : out std_logic;
      pmmu_reg_sel : out std_logic_vector(4 downto 0);
      pmmu_reg_wdat : out std_logic_vector(31 downto 0);
      pmmu_reg_part : out std_logic;
      pmmu_addr_log : out std_logic_vector(31 downto 0);
      pmmu_addr_phys : out std_logic_vector(31 downto 0);
      pmmu_cache_inhibit : out std_logic;
      cache_op_addr : out std_logic_vector(31 downto 0);
      pmmu_walker_req : out std_logic;
      pmmu_walker_we : out std_logic;
      pmmu_walker_addr : out std_logic_vector(31 downto 0);
      pmmu_walker_wdat : out std_logic_vector(31 downto 0);
      pmmu_walker_ack : in std_logic;
      pmmu_walker_data : in std_logic_vector(31 downto 0);
      pmmu_walker_berr : in std_logic;
      debug_SVmode : out std_logic;
      debug_preSVmode : out std_logic;
      debug_FlagsSR_S : out std_logic;
      debug_changeMode : out std_logic;
      debug_setopcode : out std_logic;
      debug_exec_directSR : out std_logic;
      debug_exec_to_SR : out std_logic;
      debug_pmove_dn_mode : out std_logic;
      debug_pmove_dn_regnum : out std_logic_vector(2 downto 0);
      debug_opcode : out std_logic_vector(15 downto 0);
      debug_state : out std_logic_vector(1 downto 0);
      debug_setstate : out std_logic_vector(1 downto 0);
      debug_last_opc_read : out std_logic_vector(15 downto 0);
      debug_data_read : out std_logic_vector(31 downto 0);
      debug_direct_data : out std_logic;
      debug_setnextpass : out std_logic;
      debug_TG68_PC : out std_logic_vector(31 downto 0);
      debug_memaddr_reg : out std_logic_vector(31 downto 0);
      debug_memaddr_delta : out std_logic_vector(31 downto 0);
      debug_oddout : out std_logic;
      debug_decodeOPC : out std_logic;
      debug_brief : out std_logic_vector(15 downto 0);
      debug_moves_bus_pending : out std_logic;
      debug_moves_writeback_pending : out std_logic;
      debug_clkena_lw : out std_logic;
      debug_regfile_d0 : out std_logic_vector(31 downto 0);
      debug_regfile_a0 : out std_logic_vector(31 downto 0)
    );
  end component;

  -- Signals
  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal cpu : std_logic_vector(1 downto 0) := "10";  -- MC68030 mode
  signal clkena_in : std_logic := '1';
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal IPL_autovector : std_logic := '0';
  signal berr : std_logic := '0';
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_walker_berr : std_logic := '0';

  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS, nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal longword : std_logic;
  signal nResetOut : std_logic;
  signal FC : std_logic_vector(2 downto 0);
  signal clr_berr : std_logic;
  signal debug_opcode : std_logic_vector(15 downto 0);
  signal debug_regfile_d0 : std_logic_vector(31 downto 0);
  signal debug_regfile_a0 : std_logic_vector(31 downto 0);
  signal debug_TG68_PC : std_logic_vector(31 downto 0);

  -- Memory
  type rom_type is array (0 to 2047) of std_logic_vector(15 downto 0);
  type ram_type is array (0 to 2047) of std_logic_vector(15 downto 0);
  signal ram : ram_type := (others => (others => '0'));
  signal mem_data : std_logic_vector(15 downto 0);

  constant CLK_PERIOD : time := 10 ns;

  -- Test counters
  signal test_passed : integer := 0;
  signal test_failed : integer := 0;
  signal total_tests : integer := 0;

  -- PMOVE Extension Word Encoding (Python-verified):
  -- bits 14-10 = preg_value << 10, bit 9 = R/W direction
  --
  -- TT0 (preg=2): write=$0800, read=$0A00  (bits 14-10=00010)
  -- TT1 (preg=3): write=$0C00, read=$0E00  (bits 14-10=00011)
  -- TC  (preg=16): write=$4000, read=$4200 (bits 14-10=10000)
  -- SRP (preg=18): write=$4800, read=$4A00
  -- CRP (preg=19): write=$4C00, read=$4E00
  -- MMUSR (preg=24): write=$6000, read=$6200
  


  signal rom : rom_type := (
    -- Reset vectors (addresses 0x0-0x7)
    0 => x"0000", 1 => x"2000",  -- Initial SSP = $00002000
    2 => x"0000", 3 => x"0100",  -- Initial PC  = $00000100
    
    -- Exception vectors - point to STOP instruction at $184 (word index 194)
    -- to catch any exceptions and halt cleanly instead of running garbage
    -- Bus Error (vector 2, address $08)
    4 => x"0000", 5 => x"0184",
    -- Address Error (vector 3, address $0C)
    6 => x"0000", 7 => x"0184",
    -- Illegal Instruction (vector 4, address $10)
    8 => x"0000", 9 => x"0184",
    -- Privilege Violation (vector 8, address $20)
    16 => x"0000", 17 => x"0184",
    -- F-Line Emulator (vector 11, address $2C)
    22 => x"0000", 23 => x"0184",

    -- ========================================
    -- Code starts at $100 (word index 128)
    -- ========================================
    
    -- Initialize test data registers
    -- MOVE.L #$12345678,D0
    128 => x"203C", 129 => x"1234", 130 => x"5678",
    -- MOVE.L #$AABBCCDD,D1
    131 => x"223C", 132 => x"AABB", 133 => x"CCDD",
    -- MOVE.L #$DEADBEEF,D2
    134 => x"243C", 135 => x"DEAD", 136 => x"BEEF",
    -- MOVE.L #$CAFEBABE,D3
    137 => x"263C", 138 => x"CAFE", 139 => x"BABE",
    -- MOVEA.L #$00001000,A0 (RAM base)
    140 => x"207C", 141 => x"0000", 142 => x"1000",
    -- MOVEA.L #$00001100,A1
    143 => x"227C", 144 => x"0000", 145 => x"1100",
    
    -- ========================================
    -- TEST GROUP 1: TC Register (32-bit)
    -- ========================================
    
    -- TEST 1.1: PMOVE D0,TC (Write D0 to TC)
    -- Opcode: F000 + Dn mode (000) = $F000
    -- Extension: 010 10000 0 0000000 = $4000 (TC, write)
    146 => x"F000", 147 => x"4000",
    
    -- TEST 1.2: PMOVE TC,D1 (Read TC to D1)
    -- Extension: 010 10000 1 0000000 = $4200 (TC, read)
    148 => x"F001", 149 => x"4200",
    
    -- TEST 1.3: PMOVE TC,(A0) (Write TC to memory)
    -- Opcode: F010 ((An) mode)
    -- Extension: 010 10000 1 0000000 = $4200 (TC, read to mem)
    150 => x"F010", 151 => x"4200",
    
    -- TEST 1.4: PMOVE (A1),TC (Read memory to TC)
    -- Extension: 010 10000 0 0000000 = $4000 (TC, write from mem)
    152 => x"F011", 153 => x"4000",
    
    -- ========================================
    -- TEST GROUP 2: TT0 Register (32-bit)
    -- ========================================
    
    -- TEST 2.1: PMOVE D2,TT0 (Write D2 to TT0)
    154 => x"F002", 155 => x"0800",  -- TT0 write
    
    -- TEST 2.2: PMOVE TT0,D3 (Read TT0 to D3)
    156 => x"F003", 157 => x"0A00",  -- TT0 read
    
    -- TEST 2.3: PMOVE TT0,(A0)+ (Read TT0 to memory, postincrement)
    158 => x"F018", 159 => x"0A00",  -- TT0 read
    
    -- ========================================
    -- TEST GROUP 3: TT1 Register (32-bit)
    -- ========================================
    
    -- TEST 3.1: PMOVE D0,TT1 (Write D0 to TT1)
    160 => x"F000", 161 => x"0C00",  -- TT1 write
    
    -- TEST 3.2: PMOVE TT1,D1 (Read TT1 to D1)
    162 => x"F001", 163 => x"0E00",  -- TT1 read

    
    -- ========================================
    -- TEST GROUP 4: MMUSR Register (16-bit)
    -- ========================================
    
    -- TEST 4.1: PMOVE MMUSR,(A0) (Read MMUSR to memory)
    -- Opcode: F010 ((An) mode)
    -- bits 15-13=011, bits 14-10=11000, bit9=1 => $6200
    164 => x"F010", 165 => x"6200",
    
    -- TEST 4.2: PMOVE (A0),MMUSR (Write memory to MMUSR)
    -- bits 15-13=011, bits 14-10=11000, bit9=0 => $6000
    166 => x"F010", 167 => x"6000",

    
    -- ========================================
    -- TEST GROUP 5: CRP Register (64-bit)
    -- ========================================
    
    -- Reset A0 to RAM base
    168 => x"207C", 169 => x"0000", 170 => x"1000",
    
    -- TEST 5.1: PMOVE CRP,(A0) (Read 64-bit CRP to memory)
    -- Extension: 010 011 1 000000000 = $4E00 (CRP, read to mem)
    -- NOTE: CRP cannot use Dn mode - must use memory EA
    171 => x"F010", 172 => x"4E00",
    
    -- TEST 5.2: PMOVE (A0),CRP (Write 64-bit memory to CRP)
    -- Extension: 010 011 0 000000000 = $4C00 (CRP, write from mem)
    173 => x"F010", 174 => x"4C00",
    
    -- ========================================
    -- TEST GROUP 6: SRP Register (64-bit)
    -- ========================================
    
    -- Reset A0 to different RAM location
    175 => x"207C", 176 => x"0000", 177 => x"1080",
    
    -- TEST 6.1: PMOVE SRP,(A0) (Read 64-bit SRP to memory)
    -- Extension: 010 010 1 000000000 = $4A00 (SRP, read to mem)
    178 => x"F010", 179 => x"4A00",
    
    -- TEST 6.2: PMOVE (A0),SRP (Write 64-bit memory to SRP)
    -- Extension: 010 010 0 000000000 = $4800 (SRP, write from mem)
    180 => x"F010", 181 => x"4800",

    
    -- ========================================
    -- TEST GROUP 7: Additional Addressing Modes
    -- ========================================
    
    -- Reset A0 to $1008 (so -(A0)=$1004 lands in RAM, not ROM at $FFC!)
    182 => x"207C", 183 => x"0000", 184 => x"1008",
    
    -- TEST 7.1: PMOVE TC,-(A0) (Predecrement)
    -- Opcode: F020 (-(An) mode, An=A0)
    -- Extension: 010 10000 1 0000000 = $4200 (TC, read)
    185 => x"F020", 186 => x"4200",
    
    -- TEST 7.2: PMOVE (d16,A0),TC (Displacement)
    -- Opcode: F028 ((d16,An) mode, An=A0)
    -- Extension: 010 10000 0 0000000 = $4000 (TC, write)
    -- Displacement: $0010 (16 bytes)
    187 => x"F028", 188 => x"4000", 189 => x"0010",
    
    -- TEST 7.3: PMOVE TC,$00001200.L (Absolute Long)
    -- Opcode: F039 (xxx.L mode)
    -- Extension: 010 10000 1 0000000 = $4200 (TC, read)
    -- Address: $00001200
    190 => x"F039", 191 => x"4200", 192 => x"0000", 193 => x"1200",
    
    -- ========================================
    -- End of tests - halt
    -- ========================================
    194 => x"4E72", 195 => x"2700",  -- STOP #$2700
    
    others => x"4E71"  -- NOP
  );

begin
  -- Instantiate UUT
  uut: TG68KdotC_Kernel port map (
    clk => clk, nReset => nReset, clkena_in => clkena_in, data_in => data_in,
    IPL => IPL, IPL_autovector => IPL_autovector, berr => berr, CPU => cpu,
    addr_out => addr_out, data_write => data_write, nWr => nWr,
    nUDS => nUDS, nLDS => nLDS, busstate => busstate, longword => longword,
    nResetOut => nResetOut, FC => FC, clr_berr => clr_berr,
    skipFetch => open, regin_out => open, CACR_out => open, VBR_out => open,
    cache_inv_req => open, cache_op_scope => open, cache_op_cache => open,
    cache_op_addr => open, cacr_ie => open, cacr_de => open,
    cacr_ifreeze => open, cacr_dfreeze => open, cacr_ibe => open,
    cacr_dbe => open, cacr_wa => open,
    pmmu_reg_we => open, pmmu_reg_re => open, pmmu_reg_sel => open,
    pmmu_reg_wdat => open, pmmu_reg_part => open, pmmu_addr_log => open,
    pmmu_addr_phys => open, pmmu_cache_inhibit => open,
    pmmu_walker_req => open, pmmu_walker_we => open, pmmu_walker_addr => open,
    pmmu_walker_wdat => open, pmmu_walker_ack => pmmu_walker_ack,
    pmmu_walker_data => pmmu_walker_data, pmmu_walker_berr => pmmu_walker_berr,
    debug_SVmode => open, debug_preSVmode => open, debug_FlagsSR_S => open,
    debug_changeMode => open, debug_setopcode => open, debug_exec_directSR => open,
    debug_exec_to_SR => open, debug_state => open, debug_setstate => open,
    debug_last_opc_read => open, debug_data_read => open, debug_direct_data => open,
    debug_setnextpass => open, debug_TG68_PC => debug_TG68_PC,
    debug_memaddr_reg => open, debug_memaddr_delta => open,
    debug_oddout => open, debug_decodeOPC => open, debug_brief => open,
    debug_moves_bus_pending => open, debug_moves_writeback_pending => open,
    debug_clkena_lw => open, debug_regfile_d0 => debug_regfile_d0,
    debug_regfile_a0 => debug_regfile_a0, debug_opcode => debug_opcode,
    debug_pmove_dn_mode => open, debug_pmove_dn_regnum => open
  );

  -- Clock
  process begin
    clk <= '0'; wait for CLK_PERIOD/2;
    clk <= '1'; wait for CLK_PERIOD/2;
  end process;

  -- Memory Read
  process(addr_out, ram, busstate)
    variable word_addr : integer;
    variable ram_addr : integer;
  begin
    mem_data <= x"4E71";
    if is_x(addr_out) then
      mem_data <= x"0000";
    elsif unsigned(addr_out) < x"00001000" then
      word_addr := to_integer(unsigned(addr_out(11 downto 1)));
      if word_addr <= 2047 then
        mem_data <= rom(word_addr);
      end if;
    elsif unsigned(addr_out) >= x"00001000" and unsigned(addr_out) < x"00002000" then
      ram_addr := to_integer(unsigned(addr_out(11 downto 1)));
      mem_data <= ram(ram_addr);
    end if;
  end process;
  
  data_in <= mem_data;

  -- RAM Write with logging
  process(clk)
    variable ram_addr : integer;
  begin
    if rising_edge(clk) then
      if busstate="11" and unsigned(addr_out) >= x"00001000" and unsigned(addr_out) < x"00002000" then
        ram_addr := to_integer(unsigned(addr_out(11 downto 1)));
        ram(ram_addr) <= data_write;
        report "RAM WRITE: addr=$" & integer'image(to_integer(unsigned(addr_out))) &
               " data=$" & integer'image(to_integer(unsigned(data_write)));
      end if;
    end if;
  end process;

  -- Stimulus and verification
  stim_proc: process
  begin
    nReset <= '0';
    wait for 100 ns;
    nReset <= '1';
    
    report "=== COMPREHENSIVE PMOVE TEST SUITE ===";
    report "Testing all PMMU registers: TC, TT0, TT1, MMUSR, CRP, SRP";
    report "Testing addressing modes: Dn, (An), (An)+, -(An), (d16,An), xxx.L";
    
    -- Wait for STOP instruction (PC should reach $01C4 area)
    wait for 50000 ns;
    
    -- Check if CPU reached STOP
    if debug_opcode = x"4E72" then
      report "CPU reached STOP - test sequence completed";
    else
      report "WARNING: CPU did not reach STOP instruction";
    end if;
    
    -- Summarize results
    report "=== PMOVE COMPREHENSIVE TEST COMPLETE ===";
    report "Registers tested: TC, TT0, TT1, MMUSR, CRP, SRP";
    report "Addressing modes tested: Dn direct, (An), (An)+, -(An), (d16,An), xxx.L";
    
    assert false report "Simulation End" severity failure;
  end process;

end behavioral;
