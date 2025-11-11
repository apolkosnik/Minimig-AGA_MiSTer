------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Data Cache                                                       --
--                                                                          --
-- 256-byte direct-mapped data cache with write-through policy             --
--                                                                          --
-- Features:                                                                --
--   - 16 cache lines of 16 bytes each (256 bytes total)                   --
--   - Direct-mapped organization                                          --
--   - Write-through policy (all writes go to bus)                         --
--   - Optional write allocate via CACR.WA                                 --
--   - Enable/disable via CACR.ED                                          --
--   - Freeze mode via CACR.FD                                             --
--   - Invalidate all via CACR.CD                                          --
--   - Invalidate entry via CACR.CDE + CAAR                                --
--   - Optional burst mode via CACR.DBE                                    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_DCache is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Control from CACR
        enable      : in  std_logic;                      -- ED bit
        freeze      : in  std_logic;                      -- FD bit
        clear_all   : in  std_logic;                      -- CD pulse
        clear_entry : in  std_logic;                      -- CDE pulse
        burst_en    : in  std_logic;                      -- DBE bit
        write_alloc : in  std_logic;                      -- WA bit
        clear_addr  : in  std_logic_vector(31 downto 0); -- From CAAR

        -- CPU data access interface
        cpu_addr    : in  std_logic_vector(31 downto 0); -- Access address
        cpu_read    : in  std_logic;                      -- Read request
        cpu_write   : in  std_logic;                      -- Write request
        cpu_size    : in  std_logic_vector(1 downto 0);  -- 00=byte, 01=word, 10=long
        cpu_data_in : in  std_logic_vector(31 downto 0); -- Write data
        cpu_data_out: out std_logic_vector(31 downto 0); -- Read data
        cpu_ready   : out std_logic;                      -- Operation complete
        cpu_hit     : out std_logic;                      -- Cache hit signal

        -- External bus interface
        bus_req     : out std_logic;                      -- Bus request
        bus_addr    : out std_logic_vector(31 downto 0); -- Address
        bus_read    : out std_logic;                      -- Bus read
        bus_write   : out std_logic;                      -- Bus write
        bus_burst   : out std_logic;                      -- Burst request
        bus_size    : out std_logic_vector(1 downto 0);  -- Transfer size
        bus_data_in : in  std_logic_vector(127 downto 0);-- Burst read data
        bus_data_out: out std_logic_vector(31 downto 0); -- Write data
        bus_ready   : in  std_logic;                      -- Bus ready
        bus_error   : in  std_logic                       -- Bus error
    );
end entity TG68K030_DCache;

architecture rtl of TG68K030_DCache is

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
        READ_HIT,       -- Cache read hit
        READ_MISS,      -- Cache read miss, fetch from bus
        WRITE_HIT,      -- Cache write hit (update cache + bus)
        WRITE_MISS_ALLOC, -- Cache write miss with allocate
        WRITE_MISS_NOALLOC, -- Cache write miss without allocate
        BUS_REQUEST,    -- Request external bus
        BUS_WAIT,       -- Wait for bus data
        FILL_CACHE,     -- Update cache line
        DONE            -- Complete
    );
    signal state : state_t;

    -- Internal registers
    signal access_addr     : std_logic_vector(31 downto 0);
    signal access_size     : std_logic_vector(1 downto 0);
    signal access_data     : std_logic_vector(31 downto 0);
    signal is_write        : std_logic;
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
    -- Cache Control (Invalidation and Update)
    --------------------------------------------------------------
    cache_control_proc: process(clk, reset)
        variable clear_index : integer range 0 to 15;
        variable write_data : std_logic_vector(127 downto 0);
        variable word_index : integer range 0 to 3;
    begin
        if reset = '1' then
            -- Reset: invalidate all lines
            for i in 0 to 15 loop
                cache_array(i).valid <= '0';
                cache_array(i).tag   <= (others => '0');
                cache_array(i).data  <= (others => '0');
            end loop;

        elsif rising_edge(clk) then

            -- Clear all cache lines (CACR.CD)
            if clear_all = '1' then
                for i in 0 to 15 loop
                    cache_array(i).valid <= '0';
                end loop;
            end if;

            -- Clear specific entry (CACR.CDE + CAAR)
            if clear_entry = '1' then
                clear_index := to_integer(unsigned(clear_addr(7 downto 4)));
                cache_array(clear_index).valid <= '0';
            end if;

            -- Cache line fill (from bus read)
            if state = FILL_CACHE and freeze = '0' and enable = '1' then
                cache_array(addr_index).valid <= '1';
                cache_array(addr_index).tag   <= addr_tag;
                cache_array(addr_index).data  <= bus_data_in;
            end if;

            -- Write hit: update cache line
            if state = WRITE_HIT and enable = '1' then
                write_data := cache_array(addr_index).data;
                word_index := addr_word;

                -- Update appropriate longword in cache line
                case access_size is
                    when "00" =>  -- Byte
                        case addr_offset mod 4 is
                            when 0 => write_data(word_index*32+31 downto word_index*32+24) := access_data(7 downto 0);
                            when 1 => write_data(word_index*32+23 downto word_index*32+16) := access_data(7 downto 0);
                            when 2 => write_data(word_index*32+15 downto word_index*32+8)  := access_data(7 downto 0);
                            when 3 => write_data(word_index*32+7  downto word_index*32+0)  := access_data(7 downto 0);
                            when others => null;
                        end case;

                    when "01" =>  -- Word
                        if (addr_offset mod 4) < 2 then
                            write_data(word_index*32+31 downto word_index*32+16) := access_data(15 downto 0);
                        else
                            write_data(word_index*32+15 downto word_index*32+0)  := access_data(15 downto 0);
                        end if;

                    when "10" | "11" =>  -- Long
                        write_data(word_index*32+31 downto word_index*32) := access_data;

                    when others => null;
                end case;

                cache_array(addr_index).data <= write_data;
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
            access_addr    <= (others => '0');
            access_size    <= "00";
            access_data    <= (others => '0');
            is_write       <= '0';
            cache_line_data <= (others => '0');

            cpu_ready      <= '0';
            bus_req        <= '0';
            bus_read       <= '0';
            bus_write      <= '0';
            bus_burst      <= '0';

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            cpu_ready  <= '0';
            bus_req    <= '0';
            bus_read   <= '0';
            bus_write  <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for access request
                ------------------------------------------------------
                when IDLE =>
                    if cpu_read = '1' or cpu_write = '1' then
                        access_addr <= cpu_addr;
                        access_size <= cpu_size;
                        access_data <= cpu_data_in;
                        is_write    <= cpu_write;
                        state <= LOOKUP;
                    end if;

                ------------------------------------------------------
                -- LOOKUP: Check cache for hit/miss
                ------------------------------------------------------
                when LOOKUP =>
                    if is_write = '1' then
                        -- Write operation
                        if enable = '1' and cache_hit = '1' then
                            state <= WRITE_HIT;  -- Write hit
                        elsif write_alloc = '1' then
                            state <= WRITE_MISS_ALLOC;  -- Miss with allocate
                        else
                            state <= WRITE_MISS_NOALLOC;  -- Miss without allocate
                        end if;

                    else
                        -- Read operation
                        if enable = '1' and cache_hit = '1' then
                            cache_line_data <= cache_array(addr_index).data;
                            state <= READ_HIT;  -- Read hit
                        else
                            state <= READ_MISS;  -- Read miss
                        end if;
                    end if;

                ------------------------------------------------------
                -- READ_HIT: Return data from cache
                ------------------------------------------------------
                when READ_HIT =>
                    cpu_ready <= '1';
                    state <= IDLE;

                ------------------------------------------------------
                -- READ_MISS: Fetch from bus
                ------------------------------------------------------
                when READ_MISS =>
                    state <= BUS_REQUEST;

                ------------------------------------------------------
                -- WRITE_HIT: Update cache and write through to bus
                ------------------------------------------------------
                when WRITE_HIT =>
                    -- Cache update happens in cache_control_proc
                    -- Also need to write to bus (write-through)
                    bus_write <= '1';
                    bus_req   <= '1';
                    state <= BUS_WAIT;

                ------------------------------------------------------
                -- WRITE_MISS_ALLOC: Fetch line, then write
                ------------------------------------------------------
                when WRITE_MISS_ALLOC =>
                    -- First fetch the cache line
                    state <= BUS_REQUEST;

                ------------------------------------------------------
                -- WRITE_MISS_NOALLOC: Write to bus only
                ------------------------------------------------------
                when WRITE_MISS_NOALLOC =>
                    bus_write <= '1';
                    bus_req   <= '1';
                    state <= BUS_WAIT;

                ------------------------------------------------------
                -- BUS_REQUEST: Request external bus
                ------------------------------------------------------
                when BUS_REQUEST =>
                    bus_req <= '1';

                    if is_write = '1' then
                        bus_write <= '1';
                    else
                        bus_read <= '1';

                        -- Use burst for reads if enabled
                        if burst_en = '1' and enable = '1' then
                            bus_burst <= '1';
                        end if;
                    end if;

                    state <= BUS_WAIT;

                ------------------------------------------------------
                -- BUS_WAIT: Wait for bus completion
                ------------------------------------------------------
                when BUS_WAIT =>
                    if bus_error = '1' then
                        state <= IDLE;  -- Error, abort

                    elsif bus_ready = '1' then
                        if is_write = '0' then
                            -- Read complete
                            cache_line_data <= bus_data_in;

                            if enable = '1' and freeze = '0' then
                                state <= FILL_CACHE;
                            else
                                state <= DONE;
                            end if;
                        else
                            -- Write complete
                            state <= DONE;
                        end if;
                    end if;

                ------------------------------------------------------
                -- FILL_CACHE: Update cache line
                ------------------------------------------------------
                when FILL_CACHE =>
                    state <= DONE;

                ------------------------------------------------------
                -- DONE: Complete operation
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
    data_out_proc: process(cache_line_data, addr_word, addr_offset, access_size)
        variable longword : std_logic_vector(31 downto 0);
    begin
        -- Select longword from cache line
        case addr_word is
            when 0 => longword := cache_line_data(31 downto 0);
            when 1 => longword := cache_line_data(63 downto 32);
            when 2 => longword := cache_line_data(95 downto 64);
            when 3 => longword := cache_line_data(127 downto 96);
            when others => longword := (others => '0');
        end case;

        -- Handle different access sizes
        case access_size is
            when "00" =>  -- Byte
                case addr_offset mod 4 is
                    when 0 => cpu_data_out <= X"000000" & longword(31 downto 24);
                    when 1 => cpu_data_out <= X"000000" & longword(23 downto 16);
                    when 2 => cpu_data_out <= X"000000" & longword(15 downto 8);
                    when 3 => cpu_data_out <= X"000000" & longword(7 downto 0);
                    when others => cpu_data_out <= (others => '0');
                end case;

            when "01" =>  -- Word
                if (addr_offset mod 4) < 2 then
                    cpu_data_out <= X"0000" & longword(31 downto 16);
                else
                    cpu_data_out <= X"0000" & longword(15 downto 0);
                end if;

            when "10" | "11" =>  -- Long
                cpu_data_out <= longword;

            when others =>
                cpu_data_out <= (others => '0');
        end case;
    end process;

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------
    cpu_hit      <= cache_hit;
    bus_addr     <= access_addr;
    bus_size     <= access_size;
    bus_data_out <= access_data;

end architecture rtl;
