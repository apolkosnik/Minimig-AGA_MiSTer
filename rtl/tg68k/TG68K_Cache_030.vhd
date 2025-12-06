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
    cacr_ifreeze    : in  std_logic;  -- Cache freeze (inhibit replacements)
    cacr_dfreeze    : in  std_logic;  -- Cache freeze (inhibit replacements)
    cacr_wa        : in  std_logic;  -- Write Allocate (allocate line on write miss)
    
    -- Cache invalidation (68030 via CACR bits)
    inv_req        : in  std_logic;  -- Cache invalidation request
    cache_op_scope : in  std_logic_vector(1 downto 0); -- 00=line, 01=page, 10=all, 11=all
    cache_op_cache : in  std_logic_vector(1 downto 0); -- 00=both, 01=data, 10=insn, 11=both
    cache_op_addr  : in  std_logic_vector(31 downto 0); -- Address for line/page operations
    
    -- Instruction Cache Interface
    i_addr         : in  std_logic_vector(31 downto 0);     -- Logical address from CPU
    i_addr_phys    : in  std_logic_vector(31 downto 0);     -- Physical address from PMMU
    i_req          : in  std_logic;
    i_cache_inhibit : in  std_logic;                         -- Cache inhibit from PMMU
    i_data         : out std_logic_vector(31 downto 0);
    i_hit          : out std_logic;
    i_fill_req     : out std_logic;
    i_fill_addr    : out std_logic_vector(31 downto 0);
    i_fill_data    : in  std_logic_vector(127 downto 0); -- 16-byte cache line
    i_fill_valid   : in  std_logic;

    -- Data Cache Interface
    d_addr         : in  std_logic_vector(31 downto 0);     -- Logical address from CPU
    d_addr_phys    : in  std_logic_vector(31 downto 0);     -- Physical address from PMMU
    d_req          : in  std_logic;
    d_we           : in  std_logic;
    d_cache_inhibit : in  std_logic;                         -- Cache inhibit from PMMU
    d_data_in      : in  std_logic_vector(31 downto 0);
    d_data_out     : out std_logic_vector(31 downto 0);
    d_be           : in  std_logic_vector(3 downto 0);      -- Byte enables (3=byte3, 2=byte2, 1=byte1, 0=byte0)
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

  -- BUG #131 FIX: Latch line index and tag when fill is requested
  -- Must use latched values at fill completion, not current values which may have changed
  signal i_fill_line_idx : integer range 0 to NUM_LINES-1 := 0;
  signal i_fill_tag      : std_logic_vector(TAG_BITS-1 downto 0) := (others => '0');
  signal d_fill_line_idx : integer range 0 to NUM_LINES-1 := 0;
  signal d_fill_tag      : std_logic_vector(TAG_BITS-1 downto 0) := (others => '0');
  
  -- Cache operation address parsing
  signal cache_op_line_idx : integer range 0 to NUM_LINES-1;
  signal cache_op_tag      : std_logic_vector(TAG_BITS-1 downto 0);
  signal cache_op_page_mask : std_logic_vector(TAG_BITS-1 downto 0);

begin

  -- Address parsing for instruction cache
  -- Use physical address for both index and tag (cache is physically indexed, physically tagged)
  i_line_idx <= to_integer(unsigned(i_addr_phys(ADDR_BITS+OFFSET_BITS-1 downto OFFSET_BITS)));
  i_tag      <= i_addr_phys(31 downto ADDR_BITS+OFFSET_BITS);
  i_offset   <= to_integer(unsigned(i_addr_phys(OFFSET_BITS-1 downto 2))) * 4; -- Word-aligned

  -- Address parsing for data cache
  -- Use physical address for both index and tag (cache is physically indexed, physically tagged)
  d_line_idx <= to_integer(unsigned(d_addr_phys(ADDR_BITS+OFFSET_BITS-1 downto OFFSET_BITS)));
  d_tag      <= d_addr_phys(31 downto ADDR_BITS+OFFSET_BITS);
  d_offset   <= to_integer(unsigned(d_addr_phys(OFFSET_BITS-1 downto 2))) * 4; -- Word-aligned
  
  -- Cache operation address parsing
  cache_op_line_idx <= to_integer(unsigned(cache_op_addr(ADDR_BITS+OFFSET_BITS-1 downto OFFSET_BITS)));
  cache_op_tag      <= cache_op_addr(31 downto ADDR_BITS+OFFSET_BITS);
  -- Page mask for 4KB pages (MC68030 standard page size)
  -- Note: ADDR_BITS + OFFSET_BITS = 8, so we need bits 11:8 = 4 bits of zeros
  -- Using explicit zeros for better synthesis tool compatibility
  cache_op_page_mask <= cache_op_addr(31 downto 12) & "0000";

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
      -- Cache fill completion - BUG #131 FIX: Use LATCHED values, not current
      if i_fill_valid = '1' then
        i_data_array(i_fill_line_idx) <= i_fill_data;
        i_tag_array(i_fill_line_idx) <= i_fill_tag;
        i_valid_array(i_fill_line_idx) <= '1';
        i_fill_req_int <= '0';  -- Clear fill request when data arrives
      end if;
      
      -- Cache invalidation (instruction cache)
      -- Triggered by CACR self-clearing bits: CI (bit 3), CEI (bit 2)
      if inv_req = '1' and (cache_op_cache = "10" or cache_op_cache = "00" or cache_op_cache = "11") then
        case cache_op_scope is
          when "10"|"11" => -- Invalidate all
            for i in 0 to NUM_LINES-1 loop
              i_valid_array(i) <= '0';
            end loop;
          when "01" => -- Invalidate page
            for i in 0 to NUM_LINES-1 loop
              -- Check if cache line tag matches the page
              if i_valid_array(i) = '1' and
                 (i_tag_array(i)(TAG_BITS-1 downto 12-ADDR_BITS-OFFSET_BITS) =
                  cache_op_page_mask(TAG_BITS-1 downto 12-ADDR_BITS-OFFSET_BITS)) then
                i_valid_array(i) <= '0';
              end if;
            end loop;
          when "00" => -- Invalidate specific line
            -- Invalidate line if tag matches
            if i_valid_array(cache_op_line_idx) = '1' and
               i_tag_array(cache_op_line_idx) = cache_op_tag then
              i_valid_array(cache_op_line_idx) <= '0';
            end if;
          when others =>
            null;
        end case;
      end if;
      
      -- Cache miss detection and fill request
      -- BUG #132 FIX: Only start new fill if no fill is already in progress
      -- Otherwise latched values would be overwritten, corrupting the pending fill
      if i_req = '1' and cacr_ie = '1' and i_cache_inhibit = '0' and i_fill_req_int = '0' then
        -- Check for cache miss
        if i_valid_array(i_line_idx) = '0' or i_tag_array(i_line_idx) /= i_tag then
          -- Only request fill if not frozen
          if cacr_ifreeze = '0' then
            i_fill_req_int <= '1';
            -- BUG #131 FIX: Latch line index and tag NOW for use at fill completion
            i_fill_line_idx <= i_line_idx;
            i_fill_tag <= i_tag;
            -- Use physical address for memory fill
            i_fill_addr <= i_addr_phys(31 downto OFFSET_BITS) & (OFFSET_BITS-1 downto 0 => '0');
          end if;
        end if;
      end if;
      
      -- Keep fill request active until data arrives (independent of i_req)
      -- Clear it only when frozen (fill completion is handled by line 139)
      if i_fill_req_int = '1' and cacr_ifreeze = '1' then
        i_fill_req_int <= '0'; -- Cancel fill if frozen
      end if;
      -- Note: Fill completion clears i_fill_req_int at line 139
    end if;
  end process;

  -- Instruction cache hit/miss detection and data output
  -- When cache inhibited, bypass cache (miss) to prevent CPU lockup
  -- Freeze only prevents new fills, but existing cache lines can still hit
  i_hit <= '1' when (cacr_ie = '1' and i_req = '1' and i_cache_inhibit = '0' and
                     i_valid_array(i_line_idx) = '1' and i_tag_array(i_line_idx) = i_tag)
                     else '0';
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
    elsif rising_edge(clk) then
      -- Cache fill completion - BUG #131 FIX: Use LATCHED values, not current
      if d_fill_valid = '1' then
        d_data_array(d_fill_line_idx) <= d_fill_data;
        d_tag_array(d_fill_line_idx) <= d_fill_tag;
        d_valid_array(d_fill_line_idx) <= '1';
        d_fill_req_int <= '0';  -- Clear fill request when data arrives
      end if;
      
      -- Cache invalidation (data cache)
      -- Triggered by CACR self-clearing bits: CD (bit 11), CED (bit 10)
      if inv_req = '1' and (cache_op_cache = "01" or cache_op_cache = "00" or cache_op_cache = "11") then
        case cache_op_scope is
          when "10"|"11" => -- Invalidate all
            for i in 0 to NUM_LINES-1 loop
              d_valid_array(i) <= '0';
            end loop;
          when "01" => -- Invalidate page
            for i in 0 to NUM_LINES-1 loop
              -- Check if cache line tag matches the page
              if d_valid_array(i) = '1' and
                 (d_tag_array(i)(TAG_BITS-1 downto 12-ADDR_BITS-OFFSET_BITS) =
                  cache_op_page_mask(TAG_BITS-1 downto 12-ADDR_BITS-OFFSET_BITS)) then
                d_valid_array(i) <= '0';
              end if;
            end loop;
          when "00" => -- Invalidate specific line
            -- Invalidate line if tag matches
            if d_valid_array(cache_op_line_idx) = '1' and
               d_tag_array(cache_op_line_idx) = cache_op_tag then
              d_valid_array(cache_op_line_idx) <= '0';
            end if;
          when others =>
            null;
        end case;
      end if;
      
      -- Cache access handling
      if d_req = '1' and cacr_de = '1' and d_cache_inhibit = '0' then
        -- Handle write (write-through for now)
        if d_we = '1' and d_valid_array(d_line_idx) = '1' and d_tag_array(d_line_idx) = d_tag then
          -- Update cache line on write hit with byte enable support
          case d_offset is
            when 0  =>  -- Bytes 0-3
              if d_be(0) = '1' then d_data_array(d_line_idx)(7 downto 0)    <= d_data_in(7 downto 0); end if;
              if d_be(1) = '1' then d_data_array(d_line_idx)(15 downto 8)   <= d_data_in(15 downto 8); end if;
              if d_be(2) = '1' then d_data_array(d_line_idx)(23 downto 16)  <= d_data_in(23 downto 16); end if;
              if d_be(3) = '1' then d_data_array(d_line_idx)(31 downto 24)  <= d_data_in(31 downto 24); end if;
            when 4  =>  -- Bytes 4-7
              if d_be(0) = '1' then d_data_array(d_line_idx)(39 downto 32)  <= d_data_in(7 downto 0); end if;
              if d_be(1) = '1' then d_data_array(d_line_idx)(47 downto 40)  <= d_data_in(15 downto 8); end if;
              if d_be(2) = '1' then d_data_array(d_line_idx)(55 downto 48)  <= d_data_in(23 downto 16); end if;
              if d_be(3) = '1' then d_data_array(d_line_idx)(63 downto 56)  <= d_data_in(31 downto 24); end if;
            when 8  =>  -- Bytes 8-11
              if d_be(0) = '1' then d_data_array(d_line_idx)(71 downto 64)  <= d_data_in(7 downto 0); end if;
              if d_be(1) = '1' then d_data_array(d_line_idx)(79 downto 72)  <= d_data_in(15 downto 8); end if;
              if d_be(2) = '1' then d_data_array(d_line_idx)(87 downto 80)  <= d_data_in(23 downto 16); end if;
              if d_be(3) = '1' then d_data_array(d_line_idx)(95 downto 88)  <= d_data_in(31 downto 24); end if;
            when 12 =>  -- Bytes 12-15
              if d_be(0) = '1' then d_data_array(d_line_idx)(103 downto 96)  <= d_data_in(7 downto 0); end if;
              if d_be(1) = '1' then d_data_array(d_line_idx)(111 downto 104) <= d_data_in(15 downto 8); end if;
              if d_be(2) = '1' then d_data_array(d_line_idx)(119 downto 112) <= d_data_in(23 downto 16); end if;
              if d_be(3) = '1' then d_data_array(d_line_idx)(127 downto 120) <= d_data_in(31 downto 24); end if;
            when others => null;
          end case;
        elsif d_we = '0' then
          -- Check for read cache miss
          -- BUG #132 FIX: Only start new fill if no fill is already in progress
          if d_fill_req_int = '0' and (d_valid_array(d_line_idx) = '0' or d_tag_array(d_line_idx) /= d_tag) then
            -- Only request fill if not frozen
            if cacr_dfreeze = '0' then
              d_fill_req_int <= '1';
              -- BUG #131 FIX: Latch line index and tag NOW for use at fill completion
              d_fill_line_idx <= d_line_idx;
              d_fill_tag <= d_tag;
              -- Use physical address for memory fill
              d_fill_addr <= d_addr_phys(31 downto OFFSET_BITS) & (OFFSET_BITS-1 downto 0 => '0');
            end if;
          end if;
        else
          -- Write miss: check if write allocate is enabled
          -- BUG #132 FIX: Only start new fill if no fill is already in progress
          if d_fill_req_int = '0' and cacr_wa = '1' and (d_valid_array(d_line_idx) = '0' or d_tag_array(d_line_idx) /= d_tag) then
            -- Write allocate: request cache line fill before writing
            -- Only request fill if not frozen
            if cacr_dfreeze = '0' then
              d_fill_req_int <= '1';
              -- BUG #131 FIX: Latch line index and tag NOW for use at fill completion
              d_fill_line_idx <= d_line_idx;
              d_fill_tag <= d_tag;
              -- Use physical address for memory fill
              d_fill_addr <= d_addr_phys(31 downto OFFSET_BITS) & (OFFSET_BITS-1 downto 0 => '0');
            end if;
          end if;
        end if;
      end if;
      
      -- Automatic cache coherency: invalidate on external writes
      -- When a write occurs that doesn't hit in cache, invalidate any potentially aliasing lines
      -- This handles cases where external agents (DMA, other CPUs) modify memory
      if d_req = '1' and d_we = '1' and cacr_de = '1' and d_cache_inhibit = '0' then
        -- If write misses in cache, check if any other lines might alias with this physical address
        if not (d_valid_array(d_line_idx) = '1' and d_tag_array(d_line_idx) = d_tag) then
          -- Look for potential aliases in other cache lines (same physical page)
          for i in 0 to NUM_LINES-1 loop
            if d_valid_array(i) = '1' and i /= d_line_idx then
              -- Check if this line is from the same 4KB page
              if d_tag_array(i)(TAG_BITS-1 downto 12-ADDR_BITS-OFFSET_BITS) = 
                 d_tag(TAG_BITS-1 downto 12-ADDR_BITS-OFFSET_BITS) then
                -- Potential alias - invalidate for safety
                d_valid_array(i) <= '0';
              end if;
            end if;
          end loop;
        end if;
      end if;
      
      -- Keep fill request active until data arrives (independent of d_req)
      -- Clear it only when frozen (fill completion is handled by line 251)
      if d_fill_req_int = '1' and cacr_dfreeze = '1' then
        d_fill_req_int <= '0'; -- Cancel fill if frozen
      end if;
      -- Note: Fill completion clears d_fill_req_int at line 251
    end if;
  end process;

  -- Data cache hit/miss detection and data output
  -- When cache inhibited, bypass cache (miss) to prevent CPU lockup
  -- Freeze only prevents new fills, but existing cache lines can still hit
  d_hit <= '1' when (cacr_de = '1' and d_req = '1' and d_cache_inhibit = '0' and
                     d_valid_array(d_line_idx) = '1' and d_tag_array(d_line_idx) = d_tag)
                     else '0';
  d_fill_req <= d_fill_req_int;
  
  -- Extract 32-bit word from 128-bit cache line based on offset
  with d_offset select
    d_data_out <= d_data_array(d_line_idx)(31 downto 0)   when 0,
                  d_data_array(d_line_idx)(63 downto 32)  when 4,
                  d_data_array(d_line_idx)(95 downto 64)  when 8,
                  d_data_array(d_line_idx)(127 downto 96) when 12,
                  (others => '0') when others;

end rtl;