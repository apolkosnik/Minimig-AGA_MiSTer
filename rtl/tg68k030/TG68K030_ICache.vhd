------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Instruction Cache                                               --
--                                                                          --
-- 256-byte direct-mapped instruction cache                                --
--                                                                          --
-- Features:                                                                --
--   - 16 cache lines of 16 bytes each (256 bytes total)                   --
--   - Direct-mapped organization                                          --
--   - Cache line: 16 bytes (4 longwords)                                  --
--   - Tag: 24 bits (address bits 31-8)                                    --
--   - Index: 4 bits (address bits 7-4) - selects 1 of 16 lines          --
--   - Offset: 4 bits (address bits 3-0) - position within line           --
--   - Enable/disable via CACR.EI                                          --
--   - Freeze mode via CACR.FI                                             --
--   - Invalidate all via CACR.CI                                          --
--   - Invalidate entry via CACR.CEI + CAAR                                --
--   - Optional burst mode via CACR.IBE                                    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_ICache is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Control from CACR
        enable      : in  std_logic;                      -- EI bit
        freeze      : in  std_logic;                      -- FI bit
        clear_all   : in  std_logic;                      -- CI pulse
        clear_entry : in  std_logic;                      -- CEI pulse
        burst_en    : in  std_logic;                      -- IBE bit
        clear_addr  : in  std_logic_vector(31 downto 0); -- From CAAR

        -- CPU instruction fetch interface
        cpu_addr    : in  std_logic_vector(31 downto 0); -- Fetch address
        cpu_read    : in  std_logic;                      -- Fetch request
        cpu_size    : in  std_logic_vector(1 downto 0);  -- 00=byte, 01=word, 10=long
        cpu_data    : out std_logic_vector(31 downto 0); -- Instruction data
        cpu_ready   : out std_logic;                      -- Data available
        cpu_hit     : out std_logic;                      -- Cache hit signal

        -- External bus interface (for cache misses)
        bus_req     : out std_logic;                      -- Bus request
        bus_addr    : out std_logic_vector(31 downto 0); -- Address to fetch
        bus_burst   : out std_logic;                      -- Burst request (4 longwords)
        bus_data    : in  std_logic_vector(127 downto 0);-- Burst data (16 bytes)
        bus_ready   : in  std_logic;                      -- Bus data ready
        bus_error   : in  std_logic                       -- Bus error
    );
end entity TG68K030_ICache;

architecture rtl of TG68K030_ICache is

    -- Cache line structure
    type cache_line_t is record
        valid : std_logic;
        tag   : std_logic_vector(23 downto 0);
        data  : std_logic_vector(127 downto 0);  -- 16 bytes
    end record;

    -- Cache array (16 lines)
    type cache_array_t is array (0 to 15) of cache_line_t;
    signal cache_array : cache_array_t;

    -- Address breakdown
    signal addr_tag    : std_logic_vector(23 downto 0);
    signal addr_index  : integer range 0 to 15;
    signal addr_offset : integer range 0 to 15;
    signal addr_word   : integer range 0 to 3;

    -- Cache lookup
    signal cache_hit   : std_logic;
    signal cache_valid : std_logic;
    signal cache_tag_match : std_logic;

    -- State machine
    type state_t is (
        IDLE,           -- Waiting for request
        LOOKUP,         -- Check cache for hit/miss
        BUS_REQUEST,    -- Request external bus
        BUS_WAIT,       -- Wait for bus data
        FILL_CACHE,     -- Update cache line
        DONE            -- Complete, return data
    );
    signal state : state_t;

    -- Internal registers
    signal fetch_addr      : std_logic_vector(31 downto 0);
    signal fetch_size      : std_logic_vector(1 downto 0);
    signal cache_line_data : std_logic_vector(127 downto 0);

begin

    --------------------------------------------------------------
    -- Address Breakdown
    --------------------------------------------------------------
    addr_tag    <= cpu_addr(31 downto 8);
    addr_index  <= to_integer(unsigned(cpu_addr(7 downto 4)));
    addr_offset <= to_integer(unsigned(cpu_addr(3 downto 0)));
    addr_word   <= to_integer(unsigned(cpu_addr(3 downto 2)));

    --------------------------------------------------------------
    -- Cache Lookup Logic
    --------------------------------------------------------------
    cache_valid     <= cache_array(addr_index).valid;
    cache_tag_match <= '1' when cache_array(addr_index).tag = addr_tag else '0';
    cache_hit       <= cache_valid and cache_tag_match and enable;

    --------------------------------------------------------------
    -- Cache Control (Invalidation)
    --------------------------------------------------------------
    cache_control_proc: process(clk, reset)
        variable clear_index : integer range 0 to 15;
    begin
        if reset = '1' then
            -- Reset: invalidate all lines
            for i in 0 to 15 loop
                cache_array(i).valid <= '0';
                cache_array(i).tag   <= (others => '0');
                cache_array(i).data  <= (others => '0');
            end loop;

        elsif rising_edge(clk) then

            -- Clear all cache lines (CACR.CI)
            if clear_all = '1' then
                for i in 0 to 15 loop
                    cache_array(i).valid <= '0';
                end loop;
            end if;

            -- Clear specific entry (CACR.CEI + CAAR)
            if clear_entry = '1' then
                clear_index := to_integer(unsigned(clear_addr(7 downto 4)));
                cache_array(clear_index).valid <= '0';
            end if;

            -- Cache line fill (from bus, during FILL_CACHE state)
            if state = FILL_CACHE and freeze = '0' and enable = '1' then
                cache_array(addr_index).valid <= '1';
                cache_array(addr_index).tag   <= addr_tag;
                cache_array(addr_index).data  <= bus_data;
            end if;

        end if;
    end process;

    --------------------------------------------------------------
    -- Cache State Machine
    --------------------------------------------------------------
    cache_fsm: process(clk, reset)
    begin
        if reset = '1' then
            state          <= IDLE;
            fetch_addr     <= (others => '0');
            fetch_size     <= "00";
            cache_line_data <= (others => '0');

            cpu_ready      <= '0';
            bus_req        <= '0';
            bus_burst      <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            cpu_ready  <= '0';
            bus_req    <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for fetch request
                ------------------------------------------------------
                when IDLE =>
                    if cpu_read = '1' then
                        fetch_addr <= cpu_addr;
                        fetch_size <= cpu_size;
                        state <= LOOKUP;
                    end if;

                ------------------------------------------------------
                -- LOOKUP: Check cache for hit/miss
                ------------------------------------------------------
                when LOOKUP =>
                    if enable = '0' then
                        -- Cache disabled, go straight to bus
                        state <= BUS_REQUEST;

                    elsif cache_hit = '1' then
                        -- Cache hit! Get data from cache
                        cache_line_data <= cache_array(addr_index).data;
                        state <= DONE;

                    else
                        -- Cache miss, need to fetch from bus
                        state <= BUS_REQUEST;
                    end if;

                ------------------------------------------------------
                -- BUS_REQUEST: Request data from external bus
                ------------------------------------------------------
                when BUS_REQUEST =>
                    bus_req <= '1';

                    -- Use burst mode if enabled (fetch entire 16-byte line)
                    if burst_en = '1' and enable = '1' then
                        bus_burst <= '1';
                    else
                        bus_burst <= '0';
                    end if;

                    state <= BUS_WAIT;

                ------------------------------------------------------
                -- BUS_WAIT: Wait for external bus to provide data
                ------------------------------------------------------
                when BUS_WAIT =>
                    if bus_error = '1' then
                        -- Bus error, return to idle
                        -- (In real CPU, this would cause exception)
                        state <= IDLE;

                    elsif bus_ready = '1' then
                        -- Bus data ready
                        cache_line_data <= bus_data;

                        -- Update cache if enabled and not frozen
                        if enable = '1' and freeze = '0' then
                            state <= FILL_CACHE;
                        else
                            state <= DONE;
                        end if;
                    end if;

                ------------------------------------------------------
                -- FILL_CACHE: Update cache line
                ------------------------------------------------------
                when FILL_CACHE =>
                    -- Cache update happens in cache_control_proc
                    state <= DONE;

                ------------------------------------------------------
                -- DONE: Return data to CPU
                ------------------------------------------------------
                when DONE =>
                    cpu_ready <= '1';
                    state <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------
    -- Data Output Selection
    --------------------------------------------------------------
    data_out_proc: process(cache_line_data, addr_word, addr_offset, fetch_size)
        variable longword : std_logic_vector(31 downto 0);
    begin
        -- Select longword from cache line based on address bits [3:2]
        case addr_word is
            when 0 => longword := cache_line_data(31 downto 0);
            when 1 => longword := cache_line_data(63 downto 32);
            when 2 => longword := cache_line_data(95 downto 64);
            when 3 => longword := cache_line_data(127 downto 96);
            when others => longword := (others => '0');
        end case;

        -- Handle different fetch sizes (byte, word, long)
        case fetch_size is
            when "00" =>  -- Byte
                -- Select byte based on bits [1:0]
                case addr_offset mod 4 is
                    when 0 => cpu_data <= X"000000" & longword(31 downto 24);
                    when 1 => cpu_data <= X"000000" & longword(23 downto 16);
                    when 2 => cpu_data <= X"000000" & longword(15 downto 8);
                    when 3 => cpu_data <= X"000000" & longword(7 downto 0);
                    when others => cpu_data <= (others => '0');
                end case;

            when "01" =>  -- Word (16-bit)
                if (addr_offset mod 4) < 2 then
                    cpu_data <= X"0000" & longword(31 downto 16);
                else
                    cpu_data <= X"0000" & longword(15 downto 0);
                end if;

            when "10" | "11" =>  -- Long (32-bit)
                cpu_data <= longword;

            when others =>
                cpu_data <= (others => '0');
        end case;
    end process;

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------
    cpu_hit  <= cache_hit;
    bus_addr <= fetch_addr;

end architecture rtl;
