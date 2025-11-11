------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Page Table Walk                                                 --
--                                                                          --
-- Multi-level page table traversal for virtual-to-physical translation    --
--                                                                          --
-- Features:                                                                --
--   - Up to 4-level table hierarchy (A, B, C, D)                          --
--   - Configurable table sizes via TC register                            --
--   - Descriptor validation and permission checking                       --
--   - Early termination descriptors                                       --
--   - Write protection and supervisor checking                            --
--   - Exception generation on translation failures                        --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PageTableWalk is
    port(
        -- Clock and reset
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Control
        start       : in  std_logic;                      -- Start translation
        abort_walk  : in  std_logic;                      -- Abort current walk

        -- Input address and context
        virt_addr   : in  std_logic_vector(31 downto 0); -- Virtual address
        fc          : in  std_logic_vector(2 downto 0);  -- Function code
        supervisor  : in  std_logic;                      -- Supervisor mode
        rw          : in  std_logic;                      -- 0=read, 1=write

        -- MMU registers
        tc_reg      : in  std_logic_vector(31 downto 0); -- Translation Control
        crp_reg     : in  std_logic_vector(63 downto 0); -- CPU Root Pointer
        srp_reg     : in  std_logic_vector(63 downto 0); -- Supervisor Root Pointer

        -- Memory bus interface (for descriptor fetches)
        bus_req     : out std_logic;                      -- Bus request
        bus_addr    : out std_logic_vector(31 downto 0); -- Descriptor address
        bus_data_in : in  std_logic_vector(31 downto 0); -- Descriptor data
        bus_ready   : in  std_logic;                      -- Bus ready
        bus_error   : in  std_logic;                      -- Bus error

        -- Translation result
        phys_addr   : out std_logic_vector(31 downto 0); -- Physical address
        write_protect : out std_logic;                    -- Write protected
        super_only  : out std_logic;                      -- Supervisor only
        cache_inh   : out std_logic;                      -- Cache inhibit
        modified    : out std_logic;                      -- Modified flag
        used        : out std_logic;                      -- Used flag

        -- Status
        done        : out std_logic;                      -- Translation complete
        error       : out std_logic;                      -- Translation error
        error_code  : out std_logic_vector(3 downto 0)   -- Error type
    );
end entity TG68K030_PageTableWalk;

architecture rtl of TG68K030_PageTableWalk is

    -- TC register field extraction
    signal tc_enable    : std_logic;
    signal tc_sre       : std_logic;                      -- Supervisor root enable
    signal tc_fcl       : std_logic;                      -- Function code lookup
    signal tc_ps        : std_logic_vector(3 downto 0);  -- Page size
    signal tc_is        : std_logic_vector(3 downto 0);  -- Initial shift
    signal tc_tia       : std_logic_vector(3 downto 0);  -- Table A index
    signal tc_tib       : std_logic_vector(3 downto 0);  -- Table B index
    signal tc_tic       : std_logic_vector(3 downto 0);  -- Table C index
    signal tc_tid       : std_logic_vector(3 downto 0);  -- Table D index

    -- Root pointer selection
    signal root_ptr     : std_logic_vector(63 downto 0);
    signal root_addr    : std_logic_vector(31 downto 0);

    -- Descriptor fields
    signal desc_dt      : std_logic_vector(1 downto 0);  -- Descriptor type
    signal desc_wp      : std_logic;                      -- Write protect
    signal desc_u       : std_logic;                      -- Used
    signal desc_s       : std_logic;                      -- Supervisor
    signal desc_ci      : std_logic;                      -- Cache inhibit
    signal desc_m       : std_logic;                      -- Modified
    signal desc_addr    : std_logic_vector(31 downto 0); -- Table/page address

    -- Table walk state
    type state_t is (
        IDLE,               -- Waiting for request
        INIT,               -- Initialize walk
        FETCH_A,            -- Fetch A table descriptor
        WAIT_A,             -- Wait for A descriptor
        CHECK_A,            -- Check A descriptor
        FETCH_B,            -- Fetch B table descriptor
        WAIT_B,             -- Wait for B descriptor
        CHECK_B,            -- Check B descriptor
        FETCH_C,            -- Fetch C table descriptor
        WAIT_C,             -- Wait for C descriptor
        CHECK_C,            -- Check C descriptor
        FETCH_D,            -- Fetch D table descriptor
        WAIT_D,             -- Wait for D descriptor
        CHECK_D,            -- Check D descriptor
        CONSTRUCT_ADDR,     -- Build final physical address
        COMPLETE,           -- Translation complete
        ERROR_STATE         -- Translation error
    );
    signal state : state_t;

    -- Working registers
    signal current_addr : std_logic_vector(31 downto 0); -- Current table address
    signal virt_index   : std_logic_vector(31 downto 0); -- Remaining virtual bits
    signal shift_count  : integer range 0 to 31;          -- Current bit shift
    signal level        : integer range 0 to 4;           -- Current table level

    -- Accumulated flags (collected during walk)
    signal accum_wp     : std_logic;
    signal accum_s      : std_logic;
    signal accum_ci     : std_logic;
    signal accum_m      : std_logic;
    signal accum_u      : std_logic;

    -- Error codes
    constant ERR_INVALID_DESC   : std_logic_vector(3 downto 0) := "0001";
    constant ERR_BUS_ERROR      : std_logic_vector(3 downto 0) := "0010";
    constant ERR_WRITE_PROTECT  : std_logic_vector(3 downto 0) := "0011";
    constant ERR_SUPER_VIOLATION: std_logic_vector(3 downto 0) := "0100";
    constant ERR_LIMIT_VIOLATION: std_logic_vector(3 downto 0) := "0101";

begin

    --------------------------------------------------------------
    -- Extract TC register fields
    --------------------------------------------------------------
    tc_enable <= tc_reg(31);
    tc_sre    <= tc_reg(25);
    tc_fcl    <= tc_reg(24);
    tc_ps     <= tc_reg(23 downto 20);
    tc_is     <= tc_reg(19 downto 16);
    tc_tia    <= tc_reg(15 downto 12);
    tc_tib    <= tc_reg(11 downto 8);
    tc_tic    <= tc_reg(7 downto 4);
    tc_tid    <= tc_reg(3 downto 0);

    --------------------------------------------------------------
    -- Root Pointer Selection
    --------------------------------------------------------------
    root_selection: process(tc_sre, fc, supervisor, crp_reg, srp_reg)
    begin
        -- Use SRP if supervisor and SRE enabled and FC indicates supervisor space
        if tc_sre = '1' and supervisor = '1' and fc(2) = '1' then
            root_ptr <= srp_reg;
        else
            root_ptr <= crp_reg;
        end if;
    end process;

    root_addr <= root_ptr(31 downto 0);

    --------------------------------------------------------------
    -- Descriptor Field Extraction
    --------------------------------------------------------------
    desc_dt   <= bus_data_in(1 downto 0);
    desc_wp   <= bus_data_in(2);
    desc_u    <= bus_data_in(3);
    desc_m    <= bus_data_in(4);
    desc_ci   <= bus_data_in(6);
    desc_s    <= bus_data_in(8);
    desc_addr <= bus_data_in(31 downto 4) & "0000";  -- Mask lower 4 bits

    --------------------------------------------------------------
    -- Table Walk State Machine
    --------------------------------------------------------------
    walk_fsm: process(clk, reset)
        variable index_bits  : integer range 0 to 15;
        variable index_val   : unsigned(31 downto 0);
        variable offset_val  : unsigned(31 downto 0);
        variable next_addr   : unsigned(31 downto 0);
    begin
        if reset = '1' then
            state         <= IDLE;
            current_addr  <= (others => '0');
            virt_index    <= (others => '0');
            shift_count   <= 0;
            level         <= 0;

            accum_wp      <= '0';
            accum_s       <= '0';
            accum_ci      <= '0';
            accum_m       <= '0';
            accum_u       <= '0';

            bus_req       <= '0';
            done          <= '0';
            error         <= '0';
            error_code    <= (others => '0');

        elsif rising_edge(clk) then
            -- Default: clear single-cycle signals
            bus_req <= '0';
            done    <= '0';

            case state is

                ------------------------------------------------------
                -- IDLE: Wait for translation request
                ------------------------------------------------------
                when IDLE =>
                    if start = '1' and tc_enable = '1' then
                        -- Initialize walk
                        current_addr <= root_addr;
                        virt_index   <= virt_addr;
                        shift_count  <= to_integer(unsigned(tc_is));
                        level        <= 0;

                        -- Reset accumulated flags
                        accum_wp <= '0';
                        accum_s  <= '0';
                        accum_ci <= '0';
                        accum_m  <= '0';
                        accum_u  <= '0';

                        error <= '0';
                        state <= INIT;

                    elsif start = '1' and tc_enable = '0' then
                        -- MMU disabled, direct mapping
                        phys_addr     <= virt_addr;
                        write_protect <= '0';
                        super_only    <= '0';
                        cache_inh     <= '0';
                        modified      <= '0';
                        used          <= '0';
                        done          <= '1';
                    end if;

                ------------------------------------------------------
                -- INIT: Determine first table level
                ------------------------------------------------------
                when INIT =>
                    if tc_tia /= "0000" then
                        state <= FETCH_A;
                    elsif tc_tib /= "0000" then
                        state <= FETCH_B;
                    elsif tc_tic /= "0000" then
                        state <= FETCH_C;
                    elsif tc_tid /= "0000" then
                        state <= FETCH_D;
                    else
                        -- No table levels, error
                        error      <= '1';
                        error_code <= ERR_INVALID_DESC;
                        state      <= ERROR_STATE;
                    end if;

                ------------------------------------------------------
                -- FETCH_A: Fetch A-level table descriptor
                ------------------------------------------------------
                when FETCH_A =>
                    -- Extract index bits for A table
                    index_bits := to_integer(unsigned(tc_tia));
                    if index_bits > 0 then
                        index_val := shift_right(unsigned(virt_index), 32 - shift_count - index_bits);
                        index_val := index_val and (shift_left(to_unsigned(1, 32), index_bits) - 1);

                        -- Calculate descriptor address: table_base + (index * 4)
                        next_addr := unsigned(current_addr) + (index_val * 4);
                        bus_addr  <= std_logic_vector(next_addr);
                        bus_req   <= '1';

                        shift_count <= shift_count + index_bits;
                        level       <= 1;
                        state       <= WAIT_A;
                    else
                        state <= FETCH_B;
                    end if;

                ------------------------------------------------------
                -- WAIT_A: Wait for A descriptor
                ------------------------------------------------------
                when WAIT_A =>
                    if abort_walk = '1' then
                        state <= IDLE;

                    elsif bus_error = '1' then
                        error      <= '1';
                        error_code <= ERR_BUS_ERROR;
                        state      <= ERROR_STATE;

                    elsif bus_ready = '1' then
                        state <= CHECK_A;
                    end if;

                ------------------------------------------------------
                -- CHECK_A: Validate A descriptor
                ------------------------------------------------------
                when CHECK_A =>
                    -- Check descriptor type
                    if desc_dt = "00" then
                        -- Invalid descriptor
                        error      <= '1';
                        error_code <= ERR_INVALID_DESC;
                        state      <= ERROR_STATE;

                    elsif desc_dt = "11" then
                        -- Reserved, treat as invalid
                        error      <= '1';
                        error_code <= ERR_INVALID_DESC;
                        state      <= ERROR_STATE;

                    else
                        -- Valid descriptor (01 or 10)
                        -- Accumulate protection flags
                        accum_wp <= accum_wp or desc_wp;
                        accum_s  <= accum_s or desc_s;
                        accum_ci <= accum_ci or desc_ci;
                        accum_m  <= accum_m or desc_m;
                        accum_u  <= accum_u or desc_u;

                        -- Check if early termination page descriptor
                        if desc_dt = "01" and shift_count >= to_integer(unsigned(tc_ps)) then
                            -- This is a page descriptor
                            current_addr <= desc_addr;
                            state        <= CONSTRUCT_ADDR;
                        else
                            -- Table descriptor, continue to B level
                            current_addr <= desc_addr;
                            if tc_tib /= "0000" then
                                state <= FETCH_B;
                            elsif tc_tic /= "0000" then
                                state <= FETCH_C;
                            elsif tc_tid /= "0000" then
                                state <= FETCH_D;
                            else
                                state <= CONSTRUCT_ADDR;
                            end if;
                        end if;
                    end if;

                ------------------------------------------------------
                -- FETCH_B: Fetch B-level table descriptor
                ------------------------------------------------------
                when FETCH_B =>
                    index_bits := to_integer(unsigned(tc_tib));
                    if index_bits > 0 then
                        index_val := shift_right(unsigned(virt_index), 32 - shift_count - index_bits);
                        index_val := index_val and (shift_left(to_unsigned(1, 32), index_bits) - 1);

                        next_addr := unsigned(current_addr) + (index_val * 4);
                        bus_addr  <= std_logic_vector(next_addr);
                        bus_req   <= '1';

                        shift_count <= shift_count + index_bits;
                        level       <= 2;
                        state       <= WAIT_B;
                    else
                        state <= FETCH_C;
                    end if;

                ------------------------------------------------------
                -- WAIT_B: Wait for B descriptor
                ------------------------------------------------------
                when WAIT_B =>
                    if abort_walk = '1' then
                        state <= IDLE;
                    elsif bus_error = '1' then
                        error      <= '1';
                        error_code <= ERR_BUS_ERROR;
                        state      <= ERROR_STATE;
                    elsif bus_ready = '1' then
                        state <= CHECK_B;
                    end if;

                ------------------------------------------------------
                -- CHECK_B: Validate B descriptor
                ------------------------------------------------------
                when CHECK_B =>
                    if desc_dt = "00" or desc_dt = "11" then
                        error      <= '1';
                        error_code <= ERR_INVALID_DESC;
                        state      <= ERROR_STATE;
                    else
                        accum_wp <= accum_wp or desc_wp;
                        accum_s  <= accum_s or desc_s;
                        accum_ci <= accum_ci or desc_ci;
                        accum_m  <= accum_m or desc_m;
                        accum_u  <= accum_u or desc_u;

                        if desc_dt = "01" and shift_count >= to_integer(unsigned(tc_ps)) then
                            current_addr <= desc_addr;
                            state        <= CONSTRUCT_ADDR;
                        else
                            current_addr <= desc_addr;
                            if tc_tic /= "0000" then
                                state <= FETCH_C;
                            elsif tc_tid /= "0000" then
                                state <= FETCH_D;
                            else
                                state <= CONSTRUCT_ADDR;
                            end if;
                        end if;
                    end if;

                ------------------------------------------------------
                -- FETCH_C: Fetch C-level table descriptor
                ------------------------------------------------------
                when FETCH_C =>
                    index_bits := to_integer(unsigned(tc_tic));
                    if index_bits > 0 then
                        index_val := shift_right(unsigned(virt_index), 32 - shift_count - index_bits);
                        index_val := index_val and (shift_left(to_unsigned(1, 32), index_bits) - 1);

                        next_addr := unsigned(current_addr) + (index_val * 4);
                        bus_addr  <= std_logic_vector(next_addr);
                        bus_req   <= '1';

                        shift_count <= shift_count + index_bits;
                        level       <= 3;
                        state       <= WAIT_C;
                    else
                        state <= FETCH_D;
                    end if;

                ------------------------------------------------------
                -- WAIT_C: Wait for C descriptor
                ------------------------------------------------------
                when WAIT_C =>
                    if abort_walk = '1' then
                        state <= IDLE;
                    elsif bus_error = '1' then
                        error      <= '1';
                        error_code <= ERR_BUS_ERROR;
                        state      <= ERROR_STATE;
                    elsif bus_ready = '1' then
                        state <= CHECK_C;
                    end if;

                ------------------------------------------------------
                -- CHECK_C: Validate C descriptor
                ------------------------------------------------------
                when CHECK_C =>
                    if desc_dt = "00" or desc_dt = "11" then
                        error      <= '1';
                        error_code <= ERR_INVALID_DESC;
                        state      <= ERROR_STATE;
                    else
                        accum_wp <= accum_wp or desc_wp;
                        accum_s  <= accum_s or desc_s;
                        accum_ci <= accum_ci or desc_ci;
                        accum_m  <= accum_m or desc_m;
                        accum_u  <= accum_u or desc_u;

                        if desc_dt = "01" and shift_count >= to_integer(unsigned(tc_ps)) then
                            current_addr <= desc_addr;
                            state        <= CONSTRUCT_ADDR;
                        else
                            current_addr <= desc_addr;
                            if tc_tid /= "0000" then
                                state <= FETCH_D;
                            else
                                state <= CONSTRUCT_ADDR;
                            end if;
                        end if;
                    end if;

                ------------------------------------------------------
                -- FETCH_D: Fetch D-level table descriptor (page)
                ------------------------------------------------------
                when FETCH_D =>
                    index_bits := to_integer(unsigned(tc_tid));
                    if index_bits > 0 then
                        index_val := shift_right(unsigned(virt_index), 32 - shift_count - index_bits);
                        index_val := index_val and (shift_left(to_unsigned(1, 32), index_bits) - 1);

                        next_addr := unsigned(current_addr) + (index_val * 4);
                        bus_addr  <= std_logic_vector(next_addr);
                        bus_req   <= '1';

                        shift_count <= shift_count + index_bits;
                        level       <= 4;
                        state       <= WAIT_D;
                    else
                        state <= CONSTRUCT_ADDR;
                    end if;

                ------------------------------------------------------
                -- WAIT_D: Wait for D descriptor (page descriptor)
                ------------------------------------------------------
                when WAIT_D =>
                    if abort_walk = '1' then
                        state <= IDLE;
                    elsif bus_error = '1' then
                        error      <= '1';
                        error_code <= ERR_BUS_ERROR;
                        state      <= ERROR_STATE;
                    elsif bus_ready = '1' then
                        state <= CHECK_D;
                    end if;

                ------------------------------------------------------
                -- CHECK_D: Validate D descriptor (must be page)
                ------------------------------------------------------
                when CHECK_D =>
                    if desc_dt = "00" or desc_dt = "11" then
                        error      <= '1';
                        error_code <= ERR_INVALID_DESC;
                        state      <= ERROR_STATE;
                    else
                        -- Final page descriptor
                        accum_wp <= accum_wp or desc_wp;
                        accum_s  <= accum_s or desc_s;
                        accum_ci <= accum_ci or desc_ci;
                        accum_m  <= accum_m or desc_m;
                        accum_u  <= accum_u or desc_u;

                        current_addr <= desc_addr;
                        state        <= CONSTRUCT_ADDR;
                    end if;

                ------------------------------------------------------
                -- CONSTRUCT_ADDR: Build final physical address
                ------------------------------------------------------
                when CONSTRUCT_ADDR =>
                    -- Check permissions before completing
                    if rw = '1' and accum_wp = '1' then
                        -- Write to write-protected page
                        error      <= '1';
                        error_code <= ERR_WRITE_PROTECT;
                        state      <= ERROR_STATE;

                    elsif supervisor = '0' and accum_s = '1' then
                        -- User access to supervisor-only page
                        error      <= '1';
                        error_code <= ERR_SUPER_VIOLATION;
                        state      <= ERROR_STATE;

                    else
                        -- Construct physical address:
                        -- Upper bits from page descriptor, lower bits from virtual address
                        offset_val := unsigned(virt_addr) and (shift_left(to_unsigned(1, 32),
                                                                to_integer(unsigned(tc_ps))) - 1);
                        phys_addr <= std_logic_vector(unsigned(current_addr) or offset_val);

                        -- Output accumulated flags
                        write_protect <= accum_wp;
                        super_only    <= accum_s;
                        cache_inh     <= accum_ci;
                        modified      <= accum_m;
                        used          <= accum_u;

                        state <= COMPLETE;
                    end if;

                ------------------------------------------------------
                -- COMPLETE: Translation successful
                ------------------------------------------------------
                when COMPLETE =>
                    done  <= '1';
                    state <= IDLE;

                ------------------------------------------------------
                -- ERROR_STATE: Translation failed
                ------------------------------------------------------
                when ERROR_STATE =>
                    error <= '1';
                    state <= IDLE;

            end case;

            -- Global abort
            if abort_walk = '1' then
                state <= IDLE;
            end if;

        end if;
    end process;

end architecture rtl;
