-- TG68K_Cache_030.vhd
-- MC68030 Cache Implementation (256-byte Instruction Cache + 256-byte Data Cache)
-- This implements the basic structure of the 68030's on-chip caches
-- Both caches are direct-mapped with 16-byte cache lines (16 lines per cache)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K_Cache_030 is
  port(
    clk            : in  std_logic;
    nreset         : in  std_logic;  -- low active

    -- Cache Control (from CACR register)
    cacr_ie        : in  std_logic;  -- Instruction cache enable
    cacr_de        : in  std_logic;  -- Data cache enable  
    cacr_freeze    : in  std_logic;  -- Cache freeze (inhibit replacements)
    
    -- Cache Control Instructions
    cinv_req       : in  std_logic;  -- CINV (Cache Invalidate) request
    cpush_req      : in  std_logic;  -- CPUSH (Cache Push) request
    cache_op_scope : in  std_logic_vector(1 downto 0); -- 00=line, 01=page, 10=all, 11=all
    cache_op_cache : in  std_logic_vector(1 downto 0); -- 00=both, 01=data, 10=insn, 11=both
    
    -- Instruction Cache Interface
    i_addr         : in  std_logic_vector(31 downto 0);
    i_req          : in  std_logic;
    i_data         : out std_logic_vector(31 downto 0);
    i_hit          : out std_logic;
    i_fill_req     : out std_logic;
    i_fill_addr    : out std_logic_vector(31 downto 0);
    i_fill_data    : in  std_logic_vector(127 downto 0); -- 16-byte cache line
    i_fill_valid   : in  std_logic;
    
    -- Data Cache Interface  
    d_addr         : in  std_logic_vector(31 downto 0);
    d_req          : in  std_logic;
    d_we           : in  std_logic;
    d_data_in      : in  std_logic_vector(31 downto 0);
    d_data_out     : out std_logic_vector(31 downto 0);
    d_hit          : out std_logic;
    d_fill_req     : out std_logic;
    d_fill_addr    : out std_logic_vector(31 downto 0);
    d_fill_data    : in  std_logic_vector(127 downto 0); -- 16-byte cache line
    d_fill_valid   : in  std_logic
  );
end TG68K_Cache_030;

architecture rtl of TG68K_Cache_030 is

  -- Cache parameters
  constant CACHE_SIZE      : integer := 256;   -- 256 bytes per cache
  constant LINE_SIZE       : integer := 16;    -- 16 bytes per line
  constant NUM_LINES       : integer := CACHE_SIZE / LINE_SIZE; -- 16 lines
  constant ADDR_BITS       : integer := 4;     -- log2(16) = 4 bits for line index
  constant OFFSET_BITS     : integer := 4;     -- log2(16) = 4 bits for byte offset
  constant TAG_BITS        : integer := 32 - ADDR_BITS - OFFSET_BITS; -- 24 bits

  -- Instruction Cache Arrays
  type i_data_array_t is array(0 to NUM_LINES-1) of std_logic_vector(127 downto 0);
  type i_tag_array_t is array(0 to NUM_LINES-1) of std_logic_vector(TAG_BITS-1 downto 0);
  type i_valid_array_t is array(0 to NUM_LINES-1) of std_logic;

  signal i_data_array  : i_data_array_t;
  signal i_tag_array   : i_tag_array_t;
  signal i_valid_array : i_valid_array_t;

  -- Data Cache Arrays  
  type d_data_array_t is array(0 to NUM_LINES-1) of std_logic_vector(127 downto 0);
  type d_tag_array_t is array(0 to NUM_LINES-1) of std_logic_vector(TAG_BITS-1 downto 0);
  type d_valid_array_t is array(0 to NUM_LINES-1) of std_logic;

  signal d_data_array  : d_data_array_t;
  signal d_tag_array   : d_tag_array_t;
  signal d_valid_array : d_valid_array_t;

  -- Cache line parsing
  signal i_line_idx    : integer range 0 to NUM_LINES-1;
  signal i_tag         : std_logic_vector(TAG_BITS-1 downto 0);
  signal i_offset      : integer range 0 to LINE_SIZE-1;
  
  signal d_line_idx    : integer range 0 to NUM_LINES-1;
  signal d_tag         : std_logic_vector(TAG_BITS-1 downto 0);
  signal d_offset      : integer range 0 to LINE_SIZE-1;
  
  -- Internal signals to track fill request state (VHDL-93 compatibility)
  signal i_fill_req_int : std_logic := '0';
  signal d_fill_req_int : std_logic := '0';
  
  -- Edge detection for cache control instructions (prevents continuous operation)
  signal cinv_req_prev  : std_logic := '0';
  signal cpush_req_prev : std_logic := '0';

begin

  -- Address parsing for instruction cache
  i_line_idx <= to_integer(unsigned(i_addr(ADDR_BITS+OFFSET_BITS-1 downto OFFSET_BITS)));
  i_tag      <= i_addr(31 downto ADDR_BITS+OFFSET_BITS);
  i_offset   <= to_integer(unsigned(i_addr(OFFSET_BITS-1 downto 2))) * 4; -- Word-aligned

  -- Address parsing for data cache
  d_line_idx <= to_integer(unsigned(d_addr(ADDR_BITS+OFFSET_BITS-1 downto OFFSET_BITS)));
  d_tag      <= d_addr(31 downto ADDR_BITS+OFFSET_BITS);  
  d_offset   <= to_integer(unsigned(d_addr(OFFSET_BITS-1 downto 2))) * 4; -- Word-aligned

  -- Instruction Cache Logic
  process(clk, nreset)
  begin
    if nreset = '0' then
      -- Clear valid bits
      for i in 0 to NUM_LINES-1 loop
        i_valid_array(i) <= '0';
      end loop;
      i_fill_req_int <= '0';
      i_fill_addr <= (others => '0');
    elsif rising_edge(clk) then
      -- Cache fill completion
      if i_fill_valid = '1' then
        i_data_array(i_line_idx) <= i_fill_data;
        i_tag_array(i_line_idx) <= i_tag;
        i_valid_array(i_line_idx) <= '1';
        i_fill_req_int <= '0';  -- Clear fill request when data arrives
      end if;
      
      -- Cache invalidation (edge-triggered to prevent continuous clearing)
      if cinv_req = '1' and cinv_req_prev = '0' and (cache_op_cache = "10" or cache_op_cache = "00" or cache_op_cache = "11") then
        case cache_op_scope is
          when "10"|"11" => -- Invalidate all
            for i in 0 to NUM_LINES-1 loop
              i_valid_array(i) <= '0';
            end loop;
          when "01" => -- Invalidate page (simplified: invalidate all for now)
            for i in 0 to NUM_LINES-1 loop
              i_valid_array(i) <= '0';
            end loop;
          when "00" => -- Invalidate line
            i_valid_array(i_line_idx) <= '0';
          when others =>
            null;
        end case;
      end if;
      
      -- Update edge detection signals
      cinv_req_prev <= cinv_req;
      cpush_req_prev <= cpush_req;
      
      -- Cache miss detection and fill request
      if i_req = '1' and cacr_ie = '1' then
        -- Check for cache miss
        if i_valid_array(i_line_idx) = '0' or i_tag_array(i_line_idx) /= i_tag then
          -- Only request fill if not frozen
          if cacr_freeze = '0' then
            i_fill_req_int <= '1';
            i_fill_addr <= i_addr(31 downto OFFSET_BITS) & (OFFSET_BITS-1 downto 0 => '0');
          end if;
        end if;
      end if;
      
      -- Keep fill request active until data arrives (independent of i_req)
      -- But clear it if cache is frozen
      if i_fill_req_int = '1' and i_fill_valid = '0' then
        if cacr_freeze = '1' then
          i_fill_req_int <= '0'; -- Cancel fill if frozen
        else
          i_fill_req_int <= '1';
        end if;
      end if;
    end if;
  end process;

  -- Instruction cache hit/miss detection and data output
  i_hit <= '1' when (cacr_ie = '1' and i_req = '1' and i_valid_array(i_line_idx) = '1' and i_tag_array(i_line_idx) = i_tag) else '0';
  i_fill_req <= i_fill_req_int;
  
  -- Extract 32-bit word from 128-bit cache line based on offset
  with i_offset select
    i_data <= i_data_array(i_line_idx)(31 downto 0)   when 0,
              i_data_array(i_line_idx)(63 downto 32)  when 4,
              i_data_array(i_line_idx)(95 downto 64)  when 8,
              i_data_array(i_line_idx)(127 downto 96) when 12,
              (others => '0') when others;

  -- Data Cache Logic (similar to instruction cache but with write support)
  process(clk, nreset)
  begin
    if nreset = '0' then
      -- Clear valid bits
      for i in 0 to NUM_LINES-1 loop
        d_valid_array(i) <= '0';
      end loop;
      d_fill_req_int <= '0';
      d_fill_addr <= (others => '0');
      -- Reset edge detection signals
      cinv_req_prev <= '0';
      cpush_req_prev <= '0';
    elsif rising_edge(clk) then
      -- Cache fill completion
      if d_fill_valid = '1' then
        d_data_array(d_line_idx) <= d_fill_data;
        d_tag_array(d_line_idx) <= d_tag;
        d_valid_array(d_line_idx) <= '1';
        d_fill_req_int <= '0';  -- Clear fill request when data arrives
      end if;
      
      -- Cache invalidation (edge-triggered to prevent continuous clearing)
      if cinv_req = '1' and cinv_req_prev = '0' and (cache_op_cache = "01" or cache_op_cache = "00" or cache_op_cache = "11") then
        case cache_op_scope is
          when "10"|"11" => -- Invalidate all
            for i in 0 to NUM_LINES-1 loop
              d_valid_array(i) <= '0';
            end loop;
          when "01" => -- Invalidate page (simplified: invalidate all for now)  
            for i in 0 to NUM_LINES-1 loop
              d_valid_array(i) <= '0';
            end loop;
          when "00" => -- Invalidate line
            d_valid_array(d_line_idx) <= '0';
          when others =>
            null;
        end case;
      end if;
      
      -- Cache access handling
      if d_req = '1' and cacr_de = '1' then
        -- Handle write (write-through for now)
        if d_we = '1' and d_valid_array(d_line_idx) = '1' and d_tag_array(d_line_idx) = d_tag then
          -- Update cache line on write hit  
          case d_offset is
            when 0  => d_data_array(d_line_idx)(31 downto 0)   <= d_data_in;
            when 4  => d_data_array(d_line_idx)(63 downto 32)  <= d_data_in;
            when 8  => d_data_array(d_line_idx)(95 downto 64)  <= d_data_in;
            when 12 => d_data_array(d_line_idx)(127 downto 96) <= d_data_in;
            when others => null;
          end case;
        elsif d_we = '0' then
          -- Check for read cache miss
          if d_valid_array(d_line_idx) = '0' or d_tag_array(d_line_idx) /= d_tag then
            -- Only request fill if not frozen
            if cacr_freeze = '0' then
              d_fill_req_int <= '1';
              d_fill_addr <= d_addr(31 downto OFFSET_BITS) & (OFFSET_BITS-1 downto 0 => '0');
            end if;
          end if;
        end if;
      end if;
      
      -- Keep fill request active until data arrives (independent of d_req)
      -- But clear it if cache is frozen
      if d_fill_req_int = '1' and d_fill_valid = '0' then
        if cacr_freeze = '1' then
          d_fill_req_int <= '0'; -- Cancel fill if frozen
        else
          d_fill_req_int <= '1';
        end if;
      end if;
    end if;
  end process;

  -- Data cache hit/miss detection and data output
  d_hit <= '1' when (cacr_de = '1' and d_req = '1' and d_valid_array(d_line_idx) = '1' and d_tag_array(d_line_idx) = d_tag) else '0';
  d_fill_req <= d_fill_req_int;
  
  -- Extract 32-bit word from 128-bit cache line based on offset
  with d_offset select
    d_data_out <= d_data_array(d_line_idx)(31 downto 0)   when 0,
                  d_data_array(d_line_idx)(63 downto 32)  when 4,
                  d_data_array(d_line_idx)(95 downto 64)  when 8,
                  d_data_array(d_line_idx)(127 downto 96) when 12,
                  (others => '0') when others;

end rtl;