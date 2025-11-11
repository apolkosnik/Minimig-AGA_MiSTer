------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Address Translation Cache (ATC)                                 --
--                                                                          --
-- 22-entry fully associative translation cache                            --
--                                                                          --
-- Features:                                                                --
--   - 22 entries (fully associative)                                      --
--   - Caches virtual→physical address translations                        --
--   - Stores page attributes (WP, S, CI, M, U)                            --
--   - Function code matching                                              --
--   - PFLUSH invalidation support                                         --
--   - FIFO replacement policy                                             --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_ATC is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Lookup interface
        lookup_req  : in  std_logic;                      -- Lookup request
        lookup_vaddr: in  std_logic_vector(31 downto 0); -- Virtual address
        lookup_fc   : in  std_logic_vector(2 downto 0);  -- Function code
        lookup_hit  : out std_logic;                      -- Hit signal
        lookup_paddr: out std_logic_vector(31 downto 0); -- Physical address
        lookup_wp   : out std_logic;                      -- Write protected
        lookup_s    : out std_logic;                      -- Supervisor only
        lookup_ci   : out std_logic;                      -- Cache inhibit
        lookup_m    : out std_logic;                      -- Modified
        lookup_u    : out std_logic;                      -- Used

        -- Load interface (from table walk)
        load_req    : in  std_logic;                      -- Load new entry
        load_vaddr  : in  std_logic_vector(31 downto 0); -- Virtual address
        load_paddr  : in  std_logic_vector(31 downto 0); -- Physical address
        load_fc     : in  std_logic_vector(2 downto 0);  -- Function code
        load_wp     : in  std_logic;                      -- Write protected
        load_s      : in  std_logic;                      -- Supervisor only
        load_ci     : in  std_logic;                      -- Cache inhibit
        load_m      : in  std_logic;                      -- Modified
        load_u      : in  std_logic;                      -- Used

        -- Invalidation interface (from PFLUSH)
        inv_all     : in  std_logic;                      -- Invalidate all (PFLUSHA)
        inv_fc      : in  std_logic;                      -- Invalidate by FC
        inv_fc_ea   : in  std_logic;                      -- Invalidate by FC+EA
        inv_fc_val  : in  std_logic_vector(2 downto 0);  -- FC to invalidate
        inv_ea_val  : in  std_logic_vector(31 downto 0)  -- EA to invalidate
    );
end entity TG68K030_ATC;

architecture rtl of TG68K030_ATC is

    -- ATC entry structure
    type atc_entry_t is record
        valid        : std_logic;
        logical_addr : std_logic_vector(23 downto 0);  -- Virtual address [31:8]
        physical_addr: std_logic_vector(23 downto 0);  -- Physical address [31:8]
        function_code: std_logic_vector(2 downto 0);
        write_protect: std_logic;
        supervisor   : std_logic;
        cache_inhibit: std_logic;
        modified     : std_logic;
        used         : std_logic;
    end record;

    -- ATC array (22 entries)
    type atc_array_t is array (0 to 21) of atc_entry_t;
    signal atc_array : atc_array_t;

    -- FIFO replacement pointer
    signal fifo_ptr : integer range 0 to 21;

    -- Lookup result
    signal hit_index : integer range 0 to 21;
    signal hit_found : std_logic;

begin

    --------------------------------------------------------------
    -- ATC Lookup Logic (Fully Associative Search)
    --------------------------------------------------------------
    lookup_proc: process(lookup_req, lookup_vaddr, lookup_fc, atc_array)
        variable vaddr_tag : std_logic_vector(23 downto 0);
        variable found     : std_logic;
        variable index     : integer range 0 to 21;
    begin
        vaddr_tag := lookup_vaddr(31 downto 8);
        found     := '0';
        index     := 0;

        if lookup_req = '1' then
            -- Search all 22 entries in parallel
            for i in 0 to 21 loop
                if atc_array(i).valid = '1' and
                   atc_array(i).logical_addr = vaddr_tag and
                   atc_array(i).function_code = lookup_fc then
                    found := '1';
                    index := i;
                    exit;  -- First match wins
                end if;
            end loop;
        end if;

        hit_found <= found;
        hit_index <= index;
    end process;

    -- Output lookup results
    lookup_hit   <= hit_found;
    lookup_paddr <= atc_array(hit_index).physical_addr & lookup_vaddr(7 downto 0)
                    when hit_found = '1' else (others => '0');
    lookup_wp    <= atc_array(hit_index).write_protect when hit_found = '1' else '0';
    lookup_s     <= atc_array(hit_index).supervisor    when hit_found = '1' else '0';
    lookup_ci    <= atc_array(hit_index).cache_inhibit when hit_found = '1' else '0';
    lookup_m     <= atc_array(hit_index).modified      when hit_found = '1' else '0';
    lookup_u     <= atc_array(hit_index).used          when hit_found = '1' else '0';

    --------------------------------------------------------------
    -- ATC Load and Invalidation Logic
    --------------------------------------------------------------
    atc_control: process(clk, reset)
    begin
        if reset = '1' then
            -- Reset: invalidate all entries
            for i in 0 to 21 loop
                atc_array(i).valid <= '0';
                atc_array(i).logical_addr  <= (others => '0');
                atc_array(i).physical_addr <= (others => '0');
                atc_array(i).function_code <= "000";
                atc_array(i).write_protect <= '0';
                atc_array(i).supervisor    <= '0';
                atc_array(i).cache_inhibit <= '0';
                atc_array(i).modified      <= '0';
                atc_array(i).used          <= '0';
            end loop;

            fifo_ptr <= 0;

        elsif rising_edge(clk) then

            ------------------------------------------------------
            -- Invalidation (PFLUSH)
            ------------------------------------------------------

            -- PFLUSHA: Invalidate all entries
            if inv_all = '1' then
                for i in 0 to 21 loop
                    atc_array(i).valid <= '0';
                end loop;
            end if;

            -- PFLUSH FC: Invalidate entries matching function code
            if inv_fc = '1' then
                for i in 0 to 21 loop
                    if atc_array(i).function_code = inv_fc_val then
                        atc_array(i).valid <= '0';
                    end if;
                end loop;
            end if;

            -- PFLUSH FC,EA: Invalidate specific entry
            if inv_fc_ea = '1' then
                for i in 0 to 21 loop
                    if atc_array(i).logical_addr = inv_ea_val(31 downto 8) and
                       atc_array(i).function_code = inv_fc_val then
                        atc_array(i).valid <= '0';
                    end if;
                end loop;
            end if;

            ------------------------------------------------------
            -- Load new entry (from table walk)
            ------------------------------------------------------
            if load_req = '1' then
                -- Use FIFO replacement policy
                atc_array(fifo_ptr).valid         <= '1';
                atc_array(fifo_ptr).logical_addr  <= load_vaddr(31 downto 8);
                atc_array(fifo_ptr).physical_addr <= load_paddr(31 downto 8);
                atc_array(fifo_ptr).function_code <= load_fc;
                atc_array(fifo_ptr).write_protect <= load_wp;
                atc_array(fifo_ptr).supervisor    <= load_s;
                atc_array(fifo_ptr).cache_inhibit <= load_ci;
                atc_array(fifo_ptr).modified      <= load_m;
                atc_array(fifo_ptr).used          <= load_u;

                -- Advance FIFO pointer
                if fifo_ptr = 21 then
                    fifo_ptr <= 0;
                else
                    fifo_ptr <= fifo_ptr + 1;
                end if;
            end if;

        end if;
    end process;

end architecture rtl;
