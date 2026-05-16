-- tb_cache_030.vhd
-- Comprehensive testbench for TG68K_Cache_030 module
-- Tests cache hit/miss, cache control instructions, and cache line fills

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_cache_030 is
end tb_cache_030;

architecture behavior of tb_cache_030 is

  component TG68K_Cache_030
    port(
      clk            : in  std_logic;
      nreset         : in  std_logic;
      -- Cache Control
      cacr_ie        : in  std_logic;
      cacr_de        : in  std_logic;
      cacr_ifreeze    : in  std_logic;
      cacr_dfreeze    : in  std_logic;
      cacr_wa        : in  std_logic;
      -- Cache Control Instructions
      inv_req        : in  std_logic;
      cache_op_scope : in  std_logic_vector(1 downto 0);
      cache_op_cache : in  std_logic_vector(1 downto 0);
      cache_op_addr  : in  std_logic_vector(31 downto 0);
      -- Instruction Cache Interface
      i_addr         : in  std_logic_vector(31 downto 0);
      i_addr_phys    : in  std_logic_vector(31 downto 0);
      i_fc           : in  std_logic_vector(2 downto 0);
      i_req          : in  std_logic;
      i_cache_inhibit : in  std_logic;
      i_data         : out std_logic_vector(31 downto 0);
      i_hit          : out std_logic;
      i_fill_req     : out std_logic;
      i_fill_addr    : out std_logic_vector(31 downto 0);
      i_fill_data    : in  std_logic_vector(127 downto 0);
      i_fill_valid   : in  std_logic;
      -- Data Cache Interface
      d_addr         : in  std_logic_vector(31 downto 0);
      d_addr_phys    : in  std_logic_vector(31 downto 0);
      d_fc           : in  std_logic_vector(2 downto 0);
      d_req          : in  std_logic;
      d_we           : in  std_logic;
      d_cache_inhibit : in  std_logic;
      d_data_in      : in  std_logic_vector(31 downto 0);
      d_data_out     : out std_logic_vector(31 downto 0);
      d_be           : in  std_logic_vector(3 downto 0);
      d_hit          : out std_logic;
      d_fill_req     : out std_logic;
      d_fill_addr    : out std_logic_vector(31 downto 0);
      d_fill_data    : in  std_logic_vector(127 downto 0);
      d_fill_valid   : in  std_logic
    );
  end component;

  -- Clock period
  constant clk_period : time := 10 ns;
  
  -- Testbench signals
  signal clk : std_logic := '0';
  signal nreset : std_logic := '0';
  
  -- Cache control
  signal cacr_ie : std_logic := '0';
  signal cacr_de : std_logic := '0';
  signal cacr_ifreeze : std_logic := '0';
  signal cacr_dfreeze : std_logic := '0';
  signal cacr_wa : std_logic := '0';

  -- Cache control instructions
  signal inv_req : std_logic := '0';
  signal cache_op_scope : std_logic_vector(1 downto 0) := (others => '0');
  signal cache_op_cache : std_logic_vector(1 downto 0) := (others => '0');
  signal cache_op_addr : std_logic_vector(31 downto 0) := (others => '0');

  -- Instruction cache
  signal i_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal i_addr_phys : std_logic_vector(31 downto 0) := (others => '0');
  signal i_fc : std_logic_vector(2 downto 0) := "010";
  signal i_req : std_logic := '0';
  signal i_cache_inhibit : std_logic := '0';
  signal i_data : std_logic_vector(31 downto 0);
  signal i_hit : std_logic;
  signal i_fill_req : std_logic;
  signal i_fill_addr : std_logic_vector(31 downto 0);
  signal i_fill_data : std_logic_vector(127 downto 0) := (others => '0');
  signal i_fill_valid : std_logic := '0';
  
  -- Data cache
  signal d_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal d_addr_phys : std_logic_vector(31 downto 0) := (others => '0');
  signal d_fc : std_logic_vector(2 downto 0) := "001";
  signal d_req : std_logic := '0';
  signal d_we : std_logic := '0';
  signal d_cache_inhibit : std_logic := '0';
  signal d_data_in : std_logic_vector(31 downto 0) := (others => '0');
  signal d_data_out : std_logic_vector(31 downto 0);
  signal d_be : std_logic_vector(3 downto 0) := "1111";
  signal d_hit : std_logic;
  signal d_fill_req : std_logic;
  signal d_fill_addr : std_logic_vector(31 downto 0);
  signal d_fill_data : std_logic_vector(127 downto 0) := (others => '0');
  signal d_fill_valid : std_logic := '0';

  -- Test control
  signal test_running : boolean := true;

begin

  -- Instantiate UUT
  uut: TG68K_Cache_030 port map (
    clk => clk,
    nreset => nreset,
    cacr_ie => cacr_ie,
    cacr_de => cacr_de,
    cacr_ifreeze => cacr_ifreeze,
    cacr_dfreeze => cacr_dfreeze,
    cacr_wa => cacr_wa,
    inv_req => inv_req,
    cache_op_scope => cache_op_scope,
    cache_op_cache => cache_op_cache,
    cache_op_addr => cache_op_addr,
    i_addr => i_addr,
    i_addr_phys => i_addr_phys,
    i_fc => i_fc,
    i_req => i_req,
    i_cache_inhibit => i_cache_inhibit,
    i_data => i_data,
    i_hit => i_hit,
    i_fill_req => i_fill_req,
    i_fill_addr => i_fill_addr,
    i_fill_data => i_fill_data,
    i_fill_valid => i_fill_valid,
    d_addr => d_addr,
    d_addr_phys => d_addr_phys,
    d_fc => d_fc,
    d_req => d_req,
    d_we => d_we,
    d_cache_inhibit => d_cache_inhibit,
    d_data_in => d_data_in,
    d_data_out => d_data_out,
    d_be => d_be,
    d_hit => d_hit,
    d_fill_req => d_fill_req,
    d_fill_addr => d_fill_addr,
    d_fill_data => d_fill_data,
    d_fill_valid => d_fill_valid
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

  -- Memory fill simulation (provides cache line data)
  fill_process: process(clk)
    variable i_fill_delay : integer := 0;
    variable d_fill_delay : integer := 0;
  begin
    if rising_edge(clk) then
      -- Instruction cache fill
      if i_fill_req = '1' and i_fill_valid = '0' then
        if i_fill_delay = 0 then
          i_fill_delay := 3; -- Simulate memory latency
        elsif i_fill_delay = 1 then
          -- Generate test data based on address (create 128-bit pattern)
          i_fill_data <= i_fill_addr & 
                        std_logic_vector(unsigned(i_fill_addr) + x"04040404") & 
                        std_logic_vector(unsigned(i_fill_addr) + x"08080808") & 
                        std_logic_vector(unsigned(i_fill_addr) + x"0C0C0C0C");
          i_fill_valid <= '1';
          i_fill_delay := 0;
        else
          i_fill_delay := i_fill_delay - 1;
        end if;
      else
        i_fill_valid <= '0';
      end if;
      
      -- Data cache fill
      if d_fill_req = '1' and d_fill_valid = '0' then
        if d_fill_delay = 0 then
          d_fill_delay := 3;
        elsif d_fill_delay = 1 then
          d_fill_data <= d_fill_addr & 
                        std_logic_vector(unsigned(d_fill_addr) + x"04040404") & 
                        std_logic_vector(unsigned(d_fill_addr) + x"08080808") & 
                        std_logic_vector(unsigned(d_fill_addr) + x"0C0C0C0C");
          d_fill_valid <= '1';
          d_fill_delay := 0;
        else
          d_fill_delay := d_fill_delay - 1;
        end if;
      else
        d_fill_valid <= '0';
      end if;
    end if;
  end process;

  -- Test stimulus
  stim_proc: process
    variable l : line;
    
    procedure wait_cycles(count : integer) is
    begin
      for i in 1 to count loop
        wait until rising_edge(clk);
      end loop;
    end procedure;
    
    procedure test_i_access(addr : std_logic_vector(31 downto 0)) is
    begin
      i_addr <= addr;
      i_addr_phys <= addr;  -- No MMU translation in this test
      i_req <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk); -- Give one cycle for miss detection
      -- Keep i_req high for testing - caller must clear it
    end procedure;
    
    procedure test_d_read(addr : std_logic_vector(31 downto 0)) is
    begin
      d_addr <= addr;
      d_addr_phys <= addr;  -- No MMU translation in this test
      d_req <= '1';
      d_we <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk); -- Give one cycle for miss detection
      -- Keep d_req high for testing - caller must clear it
    end procedure;
    
    procedure test_d_write(addr : std_logic_vector(31 downto 0); data : std_logic_vector(31 downto 0)) is
    begin
      d_addr <= addr;
      d_addr_phys <= addr;  -- No MMU translation in this test
      d_data_in <= data;
      d_req <= '1';
      d_we <= '1';
      wait until rising_edge(clk);
      d_req <= '0';
      d_we <= '0';
      wait_cycles(5);
    end procedure;

    procedure report_test(name : string; pass : boolean) is
    begin
      write(l, string'("TEST: "));
      write(l, name);
      if pass then
        write(l, string'(" - PASS"));
      else
        write(l, string'(" - FAIL"));
      end if;
      writeline(output, l);
    end procedure;

  begin
    write(l, string'("======================================"));
    writeline(output, l);
    write(l, string'("TG68K_Cache_030 Comprehensive Test"));
    writeline(output, l);
    write(l, string'("======================================"));
    writeline(output, l);

    -- Reset
    nreset <= '0';
    wait_cycles(5);
    nreset <= '1';
    wait_cycles(5);

    -- TEST 1: Cache Disabled
    write(l, string'("TEST 1: Cache Disabled Operation"));
    writeline(output, l);
    
    cacr_ie <= '0';
    cacr_de <= '0';
    test_i_access(x"00001000");
    report_test("I-Cache Disabled", i_hit = '0');
    
    test_d_read(x"00002000");
    report_test("D-Cache Disabled", d_hit = '0');

    -- TEST 2: Cache Enabled - First Access (Miss)
    write(l, string'("TEST 2: Cache Enabled - Cold Start"));
    writeline(output, l);
    
    cacr_ie <= '1';
    cacr_de <= '1';
    
    test_i_access(x"00001000");
    -- Check while i_req is still high
    report_test("I-Cache Cold Miss", i_hit = '0' and i_fill_req = '1');
    i_req <= '0';
    wait_cycles(1);
    
    test_d_read(x"00002000");
    report_test("D-Cache Cold Miss", d_hit = '0' and d_fill_req = '1');
    d_req <= '0';
    wait_cycles(1);

    -- TEST 3: Cache Hit on Second Access
    write(l, string'("TEST 3: Cache Hit Testing"));
    writeline(output, l);
    
    wait_cycles(20); -- Let fills complete fully
    
    test_i_access(x"00001000"); -- Same address
    -- i_hit should be combinational when cache is hit
    report_test("I-Cache Hit", i_hit = '1');
    i_req <= '0';
    wait_cycles(1);
    
    test_d_read(x"00002000"); -- Same address  
    report_test("D-Cache Hit", d_hit = '1');
    d_req <= '0';
    wait_cycles(1);

    -- TEST 4: Different Cache Lines
    write(l, string'("TEST 4: Multiple Cache Lines"));
    writeline(output, l);
    
    -- First ensure line x"00001000" is filled
    wait_cycles(10);
    
    test_i_access(x"00001004"); -- Same line, different word (line is 16 bytes, so 0x1000-0x100F)
    report_test("I-Cache Same Line", i_hit = '1');
    i_req <= '0';
    wait_cycles(1);
    
    test_i_access(x"00001100"); -- Different line
    i_req <= '0';
    wait_cycles(20); -- Let fill complete
    test_i_access(x"00001100"); -- Same line again
    report_test("I-Cache New Line", i_hit = '1');
    i_req <= '0';
    wait_cycles(1);

    -- TEST 5: Data Cache Write Operations
    write(l, string'("TEST 5: Data Cache Write Testing"));
    writeline(output, l);
    
    test_d_write(x"00002000", x"DEADBEEF");
    report_test("D-Cache Write", true); -- Just check it doesn't crash
    
    wait_cycles(2); -- Let write complete
    test_d_read(x"00002000");
    report_test("D-Cache Read After Write", d_hit = '1');
    d_req <= '0';
    wait_cycles(1);

    -- TEST 6: Cache Control Instructions
    write(l, string'("TEST 6: Cache Control Instructions"));
    writeline(output, l);
    
    -- Test CINV (Cache Invalidate)
    inv_req <= '1';
    cache_op_scope <= "10"; -- All
    cache_op_cache <= "00"; -- Both caches
    wait_cycles(1);
    inv_req <= '0';
    wait_cycles(5);
    
    test_i_access(x"00001000"); -- Should miss after invalidate
    report_test("CINV Invalidate", i_hit = '0');
    i_req <= '0';
    wait_cycles(1);

    -- TEST 7: Simultaneous I/D Misses
    write(l, string'("TEST 7: Simultaneous I/D Miss Ownership"));
    writeline(output, l);
    wait_cycles(10); -- Let the post-invalidate refill settle before overlap testing

    i_addr <= x"00004000";
    i_addr_phys <= x"00004000";
    d_addr <= x"00005000";
    d_addr_phys <= x"00005000";
    i_req <= '1';
    d_req <= '1';
    d_we <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("I/D Fill Requests Overlap", i_fill_req = '1' and d_fill_req = '1');
    report_test("I/D Fill Addresses Stay Distinct",
      i_fill_addr = x"00004000" and d_fill_addr = x"00005000");
    i_req <= '0';
    d_req <= '0';
    wait_cycles(20);

    test_i_access(x"00004000");
    report_test("I-Fill Completes After Overlap", i_hit = '1');
    i_req <= '0';
    wait_cycles(1);

    test_d_read(x"00005000");
    report_test("D-Fill Completes After Overlap", d_hit = '1');
    d_req <= '0';
    wait_cycles(1);

    -- TEST 8: Cache Freeze
    write(l, string'("TEST 8: Cache Freeze Testing"));
    writeline(output, l);
    
    cacr_ifreeze <= '1';
    wait_cycles(1); -- Let freeze take effect
    test_i_access(x"00003000"); -- New address with freeze
    report_test("iCache Freeze", i_fill_req = '0'); -- Should not request fill
    i_req <= '0';
    wait_cycles(1);
    
    cacr_ifreeze <= '0';
    test_i_access(x"00003000"); -- Same address without freeze
    report_test("iCache Unfreeze", i_fill_req = '1'); -- Should request fill
    i_req <= '0';
    wait_cycles(1);

    cacr_dfreeze <= '1';
    wait_cycles(1); -- Let freeze take effect
    test_d_read(x"00003000"); -- New address with freeze
    report_test("dCache Freeze", d_fill_req = '0'); -- Should not request fill
    d_req <= '0';
    wait_cycles(1);

    cacr_dfreeze <= '0';
    test_d_read(x"00003000"); -- Same address without freeze
    report_test("dCache Unfreeze", d_fill_req = '1'); -- Should request fill
    d_req <= '0';
    wait_cycles(1);

    -- TEST 9: 68030 Logical Cache Tags
    write(l, string'("TEST 9: Logical Address and FC Tagging"));
    writeline(output, l);

    inv_req <= '1';
    cache_op_scope <= "10"; -- All
    cache_op_cache <= "00"; -- Both caches
    wait_cycles(1);
    inv_req <= '0';
    wait_cycles(5);

    i_fc <= "010"; -- user program
    i_addr <= x"00006000";
    i_addr_phys <= x"10006000";
    i_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("I-Cache Logical Cold Miss", i_hit = '0' and i_fill_addr = x"10006000");
    i_req <= '0';
    wait_cycles(20);

    i_addr <= x"00006000";
    i_addr_phys <= x"20006000";
    i_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("I-Cache Same Logical Different Physical Hit", i_hit = '1');
    i_req <= '0';
    wait_cycles(1);

    i_fc <= "110"; -- supervisor program must not hit user-program tag
    i_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("I-Cache FC2 Tag Miss", i_hit = '0');
    i_req <= '0';
    wait_cycles(1);

    inv_req <= '1';
    cache_op_scope <= "10";
    cache_op_cache <= "00";
    wait_cycles(1);
    inv_req <= '0';
    wait_cycles(5);

    d_fc <= "001"; -- user data
    d_addr <= x"00007000";
    d_addr_phys <= x"10007000";
    d_req <= '1';
    d_we <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("D-Cache Logical Cold Miss", d_hit = '0' and d_fill_addr = x"10007000");
    d_req <= '0';
    wait_cycles(20);

    d_addr <= x"00007000";
    d_addr_phys <= x"20007000";
    d_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("D-Cache Same Logical Different Physical Hit", d_hit = '1');
    d_req <= '0';
    wait_cycles(1);

    d_fc <= "101"; -- supervisor data must not hit user-data tag
    d_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("D-Cache FC Tag Miss", d_hit = '0');
    d_req <= '0';
    wait_cycles(1);

    -- TEST 10: WinUAE-compatible write-miss behavior
    write(l, string'("TEST 10: Data Write Miss Does Not Launch Fill"));
    writeline(output, l);

    inv_req <= '1';
    cache_op_scope <= "10";
    cache_op_cache <= "00";
    wait_cycles(1);
    inv_req <= '0';
    wait_cycles(5);

    cacr_wa <= '1';
    d_fc <= "001";
    d_addr <= x"00008000";
    d_addr_phys <= x"10008000";
    d_data_in <= x"A5A55A5A";
    d_req <= '1';
    d_we <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("D-Cache WA Write Miss No Fill", d_hit = '0' and d_fill_req = '0');
    d_req <= '0';
    d_we <= '0';
    cacr_wa <= '0';
    wait_cycles(5);

    -- TEST 11: Cache-inhibit blocks new allocation, not existing hits
    write(l, string'("TEST 11: Cache-Inhibit Allows Existing Hits"));
    writeline(output, l);

    i_fc <= "010";
    i_cache_inhibit <= '0';
    i_addr <= x"00009000";
    i_addr_phys <= x"10009000";
    i_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("I-Cache CI Prime Miss", i_hit = '0' and i_fill_req = '1');
    i_req <= '0';
    wait_cycles(20);

    i_cache_inhibit <= '1';
    i_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("I-Cache CI Existing Hit", i_hit = '1');
    i_req <= '0';
    i_cache_inhibit <= '0';
    wait_cycles(1);

    d_fc <= "001";
    d_cache_inhibit <= '0';
    d_addr <= x"0000A000";
    d_addr_phys <= x"1000A000";
    d_req <= '1';
    d_we <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("D-Cache CI Prime Miss", d_hit = '0' and d_fill_req = '1');
    d_req <= '0';
    wait_cycles(20);

    d_cache_inhibit <= '1';
    d_req <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report_test("D-Cache CI Existing Hit", d_hit = '1');
    d_req <= '0';
    d_cache_inhibit <= '0';
    wait_cycles(1);


    wait_cycles(20);
    write(l, string'("======================================"));
    writeline(output, l);
    write(l, string'("Cache Tests Completed"));
    writeline(output, l);
    write(l, string'("======================================"));
    writeline(output, l);

    test_running <= false;
    wait;
  end process;

end behavior;
