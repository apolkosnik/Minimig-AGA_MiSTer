------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 MMU Package (Phase 9)                                           --
--                                                                          --
-- Defines MMU types, constants, and utility functions                     --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- MMU Package Contents:
-- - ATC entry types
-- - Translation table descriptor types
-- - MMU control register definitions
-- - Protection and access control types
-- - Address translation functions
--
-- Version: 1.0 (Phase 9)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package TG68040_MMU_Pack is

    ------------------------------------------------------------------------------
    -- Address Translation Cache (ATC) Entry
    ------------------------------------------------------------------------------
    type atc_entry_t is record
        valid           : std_logic;                        -- Entry is valid
        logical_tag     : std_logic_vector(19 downto 0);   -- Logical address [31:12]
        physical_frame  : std_logic_vector(19 downto 0);   -- Physical page [31:12]
        modified        : std_logic;                        -- Page has been written
        used            : std_logic;                        -- Page has been accessed
        write_protect   : std_logic;                        -- Page is read-only
        user_super      : std_logic;                        -- 0=supervisor, 1=user
        cache_inhibit   : std_logic;                        -- Don't cache this page
        cache_mode      : std_logic_vector(1 downto 0);    -- Cache mode (WT/CB/etc)
        lru_bits        : std_logic_vector(5 downto 0);    -- LRU replacement bits
    end record;

    constant ATC_ENTRY_INIT : atc_entry_t := (
        valid          => '0',
        logical_tag    => (others => '0'),
        physical_frame => (others => '0'),
        modified       => '0',
        used           => '0',
        write_protect  => '0',
        user_super     => '0',
        cache_inhibit  => '0',
        cache_mode     => "00",
        lru_bits       => (others => '0')
    );

    -- ATC array type (64 entries)
    type atc_array_t is array (0 to 63) of atc_entry_t;

    ------------------------------------------------------------------------------
    -- Translation Table Descriptor Types
    ------------------------------------------------------------------------------

    -- Descriptor type field (bits [1:0])
    type descriptor_type_t is (
        DESC_INVALID,           -- 00 - Invalid descriptor (page fault)
        DESC_PAGE,              -- 01 - Page descriptor (leaf)
        DESC_TABLE_SHORT,       -- 10 - Short table descriptor
        DESC_TABLE_LONG         -- 11 - Long table descriptor
    );

    -- Page descriptor (maps to physical page)
    type page_descriptor_t is record
        physical_frame  : std_logic_vector(19 downto 0);   -- Physical page [31:12]
        modified        : std_logic;                        -- M bit
        used            : std_logic;                        -- U bit
        write_protect   : std_logic;                        -- WP bit
        user_super      : std_logic;                        -- U/S bit
        cache_mode      : std_logic_vector(1 downto 0);    -- Cache mode
        cache_inhibit   : std_logic;                        -- CI bit
        valid           : std_logic;                        -- Valid bit
    end record;

    constant PAGE_DESCRIPTOR_INIT : page_descriptor_t := (
        physical_frame => (others => '0'),
        modified       => '0',
        used           => '0',
        write_protect  => '0',
        user_super     => '0',
        cache_mode     => "00",
        cache_inhibit  => '0',
        valid          => '0'
    );

    -- Table descriptor (points to next table level)
    type table_descriptor_t is record
        table_addr      : std_logic_vector(27 downto 0);   -- Table address [31:4]
        write_protect   : std_logic;                        -- WP bit
        used            : std_logic;                        -- U bit
        desc_type       : descriptor_type_t;                -- Descriptor type
    end record;

    constant TABLE_DESCRIPTOR_INIT : table_descriptor_t := (
        table_addr    => (others => '0'),
        write_protect => '0',
        used          => '0',
        desc_type     => DESC_INVALID
    );

    ------------------------------------------------------------------------------
    -- MMU Control Registers
    ------------------------------------------------------------------------------

    -- Translation Control Register (TC)
    type tc_register_t is record
        enable          : std_logic;                        -- MMU enable
        page_size       : std_logic_vector(3 downto 0);    -- Page size (0=4KB)
        fcl_enable      : std_logic;                        -- Function code lookup
        supervisor_mode : std_logic;                        -- Supervisor mode active
    end record;

    constant TC_REGISTER_INIT : tc_register_t := (
        enable          => '0',
        page_size       => x"0",
        fcl_enable      => '0',
        supervisor_mode => '1'
    );

    -- Root Pointer (SRP/URP)
    type root_pointer_t is record
        table_addr      : std_logic_vector(27 downto 0);   -- Root table [31:4]
        limit           : std_logic_vector(14 downto 0);   -- Table limit
        valid           : std_logic;                        -- Pointer valid
    end record;

    constant ROOT_POINTER_INIT : root_pointer_t := (
        table_addr => (others => '0'),
        limit      => (others => '0'),
        valid      => '0'
    );

    -- MMU Status Register (MMUSR)
    type mmusr_register_t is record
        bus_error       : std_logic;                        -- Bus error occurred
        limit_violation : std_logic;                        -- Table limit exceeded
        supervisor_only : std_logic;                        -- Supervisor violation
        write_protect   : std_logic;                        -- Write protect violation
        invalid_desc    : std_logic;                        -- Invalid descriptor
        modified        : std_logic;                        -- Modified bit
        transparent     : std_logic;                        -- Transparent translation
        resident        : std_logic;                        -- Page resident
        write_access    : std_logic;                        -- Was write access
        fault_addr      : std_logic_vector(31 downto 0);   -- Fault address
    end record;

    constant MMUSR_REGISTER_INIT : mmusr_register_t := (
        bus_error       => '0',
        limit_violation => '0',
        supervisor_only => '0',
        write_protect   => '0',
        invalid_desc    => '0',
        modified        => '0',
        transparent     => '0',
        resident        => '0',
        write_access    => '0',
        fault_addr      => (others => '0')
    );

    ------------------------------------------------------------------------------
    -- Access Control Types
    ------------------------------------------------------------------------------

    -- Access type
    type access_type_t is (
        ACCESS_READ,            -- Read access
        ACCESS_WRITE,           -- Write access
        ACCESS_EXECUTE          -- Execute (instruction fetch)
    );

    -- Protection violation type
    type protection_fault_t is (
        FAULT_NONE,             -- No fault
        FAULT_INVALID,          -- Invalid descriptor
        FAULT_WRITE_PROTECT,    -- Write to read-only page
        FAULT_SUPERVISOR,       -- Supervisor access to user page
        FAULT_BUS_ERROR,        -- Bus error during table walk
        FAULT_LIMIT             -- Table limit exceeded
    );

    -- Translation request
    type translation_request_t is record
        logical_addr    : std_logic_vector(31 downto 0);   -- Virtual address
        access_type     : access_type_t;                    -- Read/Write/Execute
        supervisor      : std_logic;                        -- Supervisor mode
        enable          : std_logic;                        -- Request valid
    end record;

    constant TRANSLATION_REQUEST_INIT : translation_request_t := (
        logical_addr => (others => '0'),
        access_type  => ACCESS_READ,
        supervisor   => '1',
        enable       => '0'
    );

    -- Translation response
    type translation_response_t is record
        physical_addr   : std_logic_vector(31 downto 0);   -- Translated address
        cache_inhibit   : std_logic;                        -- Don't cache
        cache_mode      : std_logic_vector(1 downto 0);    -- Cache mode
        ready           : std_logic;                        -- Translation complete
        fault           : protection_fault_t;               -- Fault type
    end record;

    constant TRANSLATION_RESPONSE_INIT : translation_response_t := (
        physical_addr => (others => '0'),
        cache_inhibit => '0',
        cache_mode    => "00",
        ready         => '0',
        fault         => FAULT_NONE
    );

    ------------------------------------------------------------------------------
    -- Utility Functions
    ------------------------------------------------------------------------------

    -- Extract page number from address (bits [31:12])
    function get_page_number(addr : std_logic_vector(31 downto 0))
        return std_logic_vector;

    -- Extract page offset from address (bits [11:0])
    function get_page_offset(addr : std_logic_vector(31 downto 0))
        return std_logic_vector;

    -- Combine page frame and offset to form physical address
    function combine_address(frame : std_logic_vector(19 downto 0);
                            offset : std_logic_vector(11 downto 0))
        return std_logic_vector;

    -- Decode descriptor type from raw descriptor
    function decode_descriptor_type(desc : std_logic_vector(31 downto 0))
        return descriptor_type_t;

    -- Extract physical frame from page descriptor
    function extract_physical_frame(desc : std_logic_vector(31 downto 0))
        return std_logic_vector;

    -- Extract table address from table descriptor
    function extract_table_addr(desc : std_logic_vector(31 downto 0))
        return std_logic_vector;

    -- Check if access is permitted given protection bits
    function check_access_permitted(
        entry_wp    : std_logic;                            -- Write protect bit
        entry_us    : std_logic;                            -- User/Supervisor bit
        access_type : access_type_t;                        -- Access type
        supervisor  : std_logic                             -- Supervisor mode
    ) return std_logic;

    -- Parse page descriptor from memory data
    function parse_page_descriptor(desc : std_logic_vector(31 downto 0))
        return page_descriptor_t;

    -- Parse table descriptor from memory data
    function parse_table_descriptor(desc : std_logic_vector(31 downto 0))
        return table_descriptor_t;

end package TG68040_MMU_Pack;

------------------------------------------------------------------------------
-- Package Body
------------------------------------------------------------------------------
package body TG68040_MMU_Pack is

    -- Extract page number (VPN) from logical address
    function get_page_number(addr : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return addr(31 downto 12);
    end function;

    -- Extract page offset from logical address
    function get_page_offset(addr : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return addr(11 downto 0);
    end function;

    -- Combine page frame and offset
    function combine_address(frame : std_logic_vector(19 downto 0);
                            offset : std_logic_vector(11 downto 0))
        return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
    begin
        result := frame & offset;
        return result;
    end function;

    -- Decode descriptor type from bits [1:0]
    function decode_descriptor_type(desc : std_logic_vector(31 downto 0))
        return descriptor_type_t is
        variable dtype : std_logic_vector(1 downto 0);
    begin
        dtype := desc(1 downto 0);
        case dtype is
            when "00" => return DESC_INVALID;
            when "01" => return DESC_PAGE;
            when "10" => return DESC_TABLE_SHORT;
            when "11" => return DESC_TABLE_LONG;
            when others => return DESC_INVALID;
        end case;
    end function;

    -- Extract physical frame from page descriptor
    function extract_physical_frame(desc : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return desc(31 downto 12);
    end function;

    -- Extract table address from table descriptor
    function extract_table_addr(desc : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return desc(31 downto 4);
    end function;

    -- Check if access is permitted
    function check_access_permitted(
        entry_wp    : std_logic;
        entry_us    : std_logic;
        access_type : access_type_t;
        supervisor  : std_logic
    ) return std_logic is
    begin
        -- Write to write-protected page
        if access_type = ACCESS_WRITE and entry_wp = '1' then
            return '0';
        end if;

        -- User access to supervisor page
        if supervisor = '0' and entry_us = '0' then
            return '0';
        end if;

        -- Access permitted
        return '1';
    end function;

    -- Parse page descriptor
    function parse_page_descriptor(desc : std_logic_vector(31 downto 0))
        return page_descriptor_t is
        variable pd : page_descriptor_t;
    begin
        pd.physical_frame := desc(31 downto 12);
        pd.modified       := desc(7);
        pd.used           := desc(6);
        pd.write_protect  := desc(5);
        pd.user_super     := desc(4);
        pd.cache_mode     := desc(3 downto 2);
        pd.cache_inhibit  := desc(1);
        pd.valid          := desc(0);
        return pd;
    end function;

    -- Parse table descriptor
    function parse_table_descriptor(desc : std_logic_vector(31 downto 0))
        return table_descriptor_t is
        variable td : table_descriptor_t;
    begin
        td.table_addr    := desc(31 downto 4);
        td.write_protect := desc(3);
        td.used          := desc(2);
        td.desc_type     := decode_descriptor_type(desc);
        return td;
    end function;

end package body TG68040_MMU_Pack;
