library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity tb_pmove is
end tb_pmove;

architecture behavioral of tb_pmove is
  

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length/4 - 1) loop
            nibble := value(value'length - 1 - i*4 downto value'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

-- Component Declaration for the Unit Under Test (UUT)
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
      
      -- Debug
      skipFetch : out std_logic;
      regin_out : out std_logic_vector(31 downto 0);
      CACR_out : out std_logic_vector(31 downto 0);
      VBR_out : out std_logic_vector(31 downto 0);
      
      -- Cache control
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
      
      -- PMMU register interface
      pmmu_reg_we : out std_logic;
      pmmu_reg_re : out std_logic;
      pmmu_reg_sel : out std_logic_vector(4 downto 0);
      pmmu_reg_wdat : out std_logic_vector(31 downto 0);
      pmmu_reg_part : out std_logic;
      
      -- PMMU address interface
      pmmu_addr_log : out std_logic_vector(31 downto 0);
      pmmu_addr_phys : out std_logic_vector(31 downto 0);
      pmmu_cache_inhibit : out std_logic;
      
      -- Cache operation address
      cache_op_addr : out std_logic_vector(31 downto 0);
      
      -- PMMU walker
      pmmu_walker_req : out std_logic;
      pmmu_walker_we : out std_logic;
      pmmu_walker_addr : out std_logic_vector(31 downto 0);
      pmmu_walker_wdat : out std_logic_vector(31 downto 0);
      pmmu_walker_ack : in std_logic;
      pmmu_walker_data : in std_logic_vector(31 downto 0);
      pmmu_walker_berr : in std_logic;

      -- DEBUG signals
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

  -- Inputs
  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal cpu : std_logic_vector(1 downto 0) := "10";
  signal clkena_in : std_logic := '1';
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal IPL_autovector : std_logic := '0';
  signal berr : std_logic := '0';
  
  -- PMMU inputs
  signal pmmu_walker_ack : std_logic := '0';
  signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_walker_berr : std_logic := '0';

  -- Outputs
  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS, nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal longword : std_logic;
  signal nResetOut : std_logic;
  signal FC : std_logic_vector(2 downto 0);
  signal clr_berr : std_logic;
  
  -- Debug Outputs (Signals to ignore/open)
  signal skipFetch : std_logic;
  signal regin_out : std_logic_vector(31 downto 0);
  signal CACR_out : std_logic_vector(31 downto 0);
  signal VBR_out : std_logic_vector(31 downto 0);
  
  -- Cache Control Outputs
  signal cache_inv_req, cacr_ie, cacr_de, cacr_ifreeze, cacr_dfreeze, cacr_ibe, cacr_dbe, cacr_wa : std_logic;
  signal cache_op_scope, cache_op_cache : std_logic_vector(1 downto 0);
  signal cache_op_addr : std_logic_vector(31 downto 0);
  
  -- PMMU Outputs
  signal pmmu_reg_we, pmmu_reg_re, pmmu_reg_part, pmmu_cache_inhibit : std_logic;
  signal pmmu_reg_sel : std_logic_vector(4 downto 0);
  signal pmmu_reg_wdat, pmmu_addr_log, pmmu_addr_phys : std_logic_vector(31 downto 0);
  signal pmmu_walker_req, pmmu_walker_we : std_logic;
  signal pmmu_walker_addr, pmmu_walker_wdat : std_logic_vector(31 downto 0);
  
  -- Debug Signals
  signal debug_moves_bus_pending : std_logic;
  signal debug_brief : std_logic_vector(15 downto 0);
  signal debug_memaddr_reg : std_logic_vector(31 downto 0);
  signal debug_opcode : std_logic_vector(15 downto 0);
  signal debug_regfile_d0 : std_logic_vector(31 downto 0);
  signal debug_regfile_a0 : std_logic_vector(31 downto 0);
  signal debug_clkena_lw : std_logic;
  signal debug_pmove_dn_mode : std_logic;
  signal debug_pmove_dn_regnum : std_logic_vector(2 downto 0);

  -- Internal memory
  type rom_type is array (0 to 1023) of std_logic_vector(15 downto 0);
  type ram_type is array (0 to 1023) of std_logic_vector(15 downto 0);
  signal ram : ram_type := (others => (others => '0'));
  signal mem_data : std_logic_vector(15 downto 0);

  constant CLK_PERIOD : time := 10 ns;

  -- Test Program ROM
  signal rom : rom_type := (
    -- Reset vectors
    0 => x"0000", 1 => x"2000",  -- SP = $00002000
    2 => x"0000", 3 => x"0100",  -- PC = $00000100 (Code starts at $100)
    
    -- Code at $100 (Word index 128)
    -- Init: Set D0=$DEADBEEF, A0=$1000
    128 => x"203C", 129 => x"DEAD", 130 => x"BEEF",  -- MOVE.L #$DEADBEEF,D0
    131 => x"207C", 132 => x"0000", 133 => x"1000",  -- MOVEA.L #$1000,A0
    
    -- TEST 1: PMOVE TC,D0 (Read TC to D0)
    -- Step 1: Write D0 to TC (PMOVE D0,TC)
    134 => x"F000", 135 => x"4000", -- Write D0 (val DEADBEEF) to TC
    
    -- Step 2: Clear D0
    136 => x"4280", -- CLR.L D0
    
    -- Step 3: Read TC to D0 (PMOVE TC,D0)
    137 => x"F000", 138 => x"4200", -- Read TC to D0 (Expect DEADBEEF)
    139 => x"4E71", 140 => x"4E71",

    -- TEST 2: PMOVE MMUSR,(A0) (Read MMUSR to Memory) - 16-bit
    141 => x"F010", 142 => x"6200",
    
    -- TEST 3: PMOVE CRP,(A0) (Read CRP to Memory) - 64-bit
    143 => x"207C", 144 => x"0000", 145 => x"1004",-- UPDATE A0 to $1004
    146 => x"F010", 147 => x"4E00",

    others => x"4E71"
  );

begin
  -- Instantiate the Unit Under Test (UUT)
  uut: TG68KdotC_Kernel port map (
      clk => clk,
      nReset => nReset,
      clkena_in => clkena_in,
      data_in => data_in,
      IPL => IPL,
      IPL_autovector => IPL_autovector,
      berr => berr,
      CPU => cpu,
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
      
      -- Debug
      skipFetch => skipFetch,
      regin_out => regin_out,
      CACR_out => CACR_out,
      VBR_out => VBR_out,
      cache_inv_req => cache_inv_req,
      cache_op_scope => cache_op_scope,
      cache_op_cache => cache_op_cache,
      cache_op_addr => cache_op_addr,
      cacr_ie => cacr_ie,
      cacr_de => cacr_de,
      cacr_ifreeze => cacr_ifreeze,
      cacr_dfreeze => cacr_dfreeze,
      cacr_ibe => cacr_ibe,
      cacr_dbe => cacr_dbe,
      cacr_wa => cacr_wa,
      
      -- PMMU
      pmmu_reg_we => pmmu_reg_we,
      pmmu_reg_re => pmmu_reg_re,
      pmmu_reg_sel => pmmu_reg_sel,
      pmmu_reg_wdat => pmmu_reg_wdat,
      pmmu_reg_part => pmmu_reg_part,
      pmmu_addr_log => pmmu_addr_log,
      pmmu_addr_phys => pmmu_addr_phys,
      pmmu_cache_inhibit => pmmu_cache_inhibit,
      pmmu_walker_req => pmmu_walker_req,
      pmmu_walker_we => pmmu_walker_we,
      pmmu_walker_addr => pmmu_walker_addr,
      pmmu_walker_wdat => pmmu_walker_wdat,
      pmmu_walker_ack => pmmu_walker_ack,
      pmmu_walker_data => pmmu_walker_data,
      pmmu_walker_berr => pmmu_walker_berr,
      
      -- Debug Internal
      debug_SVmode => open, debug_preSVmode => open, debug_FlagsSR_S => open,
      debug_changeMode => open, debug_setopcode => open, debug_exec_directSR => open,
      debug_exec_to_SR => open, debug_state => open, debug_setstate => open,
      debug_last_opc_read => open, debug_data_read => open, debug_direct_data => open,
      debug_setnextpass => open, debug_TG68_PC => open, debug_memaddr_delta => open,
      debug_oddout => open, debug_decodeOPC => open, debug_moves_writeback_pending => open,

      debug_moves_bus_pending => debug_moves_bus_pending,
      debug_brief => debug_brief,
      debug_memaddr_reg => debug_memaddr_reg,
      debug_opcode => debug_opcode,
      debug_regfile_d0 => debug_regfile_d0,
      debug_regfile_a0 => debug_regfile_a0,
      debug_clkena_lw => debug_clkena_lw,
      debug_pmove_dn_mode => debug_pmove_dn_mode,
      debug_pmove_dn_regnum => debug_pmove_dn_regnum
    );

  -- Clock process
  process
  begin
    clk <= '0';
    wait for CLK_PERIOD/2;
    clk <= '1';
    wait for CLK_PERIOD/2;
  end process;

  -- Memory Read Process
  process(addr_out, ram, busstate)
    variable word_addr : integer;
    variable ram_addr : integer;
  begin
    mem_data <= x"4E71"; -- Default NOP
    
    -- Check for uninitialized/X address
    if is_x(addr_out) then
        mem_data <= x"0000"; -- Safe default for reset vector read?
    elsif unsigned(addr_out) < x"00000800" then
         word_addr := to_integer(unsigned(addr_out(10 downto 1)));
         if word_addr <= 1023 then
             mem_data <= rom(word_addr);
         end if;
    elsif unsigned(addr_out) >= x"00001000" and unsigned(addr_out) < x"00001800" then
         ram_addr := to_integer(unsigned(addr_out(10 downto 1)));
         mem_data <= ram(ram_addr);
    end if;
  end process;
  
  data_in <= mem_data;

  -- RAM Write Process
  process(clk)
    variable ram_addr : integer;
  begin
    if rising_edge(clk) then
        if busstate="11" and unsigned(addr_out) >= x"00001000" then
             ram_addr := to_integer(unsigned(addr_out(10 downto 1)));
             ram(ram_addr) <= data_write;
             report "RAM WRITE: addr=$" & integer'image(to_integer(unsigned(addr_out))) & 
                    " data=$" & integer'image(to_integer(unsigned(data_write)));
        end if;
    end if;
  end process;

  -- Stimulus process
  stim_proc: process
  begin
    nReset <= '0';
    wait for 100 ns;
    nReset <= '1';
    wait for 20 ns;

    wait until rising_edge(clk) and debug_opcode = x"F000";
    report "Detected PMOVE Opcode execution";
    
    wait for 2000 ns;
    
    assert debug_regfile_d0 = x"DEADBEEF" 
      report "TEST 1 FAILED: D0=" & integer'image(to_integer(unsigned(debug_regfile_d0))) severity error;
      
    if debug_regfile_d0 = x"DEADBEEF" then
        report "TEST 1 PASSED: D0 Restored";
    end if;

    report "Simulation Finished";
    assert false report "Simulation End" severity failure;
  end process;

end behavioral;
