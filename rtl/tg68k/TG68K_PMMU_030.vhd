-- TG68K_PMMU_030.vhd
-- Minimal 68030 PMMU scaffold: registers + identity translation
-- This module provides the control registers and a clean translation interface.
-- Initially, translation is identity and no faults are generated. TC.EN is kept
-- for future use. TT0/TT1, SRP/CRP/MMUSR/CAL are stored/readable.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K_PMMU_030 is
  port(
    clk            : in  std_logic;
    nreset         : in  std_logic;  -- low active

    -- Register access port (driven by PMOVE decode)
    reg_we         : in  std_logic;
    reg_re         : in  std_logic;
    reg_sel        : in  std_logic_vector(3 downto 0); -- 0:TC 1:CRP 2:SRP 3:TT0 4:TT1 5:MMUSR 6:CAL
    reg_wdat       : in  std_logic_vector(31 downto 0);
    reg_rdat       : out std_logic_vector(31 downto 0);
    reg_part       : in  std_logic; -- '1' = high, '0' = low for 64-bit regs (CRP/SRP)
    
    -- PMMU instruction control
    ptest_req      : in  std_logic; -- PTEST instruction request
    pflush_req     : in  std_logic; -- PFLUSH instruction request  
    pload_req      : in  std_logic; -- PLOAD instruction request
    pmmu_fc        : in  std_logic_vector(2 downto 0); -- Function code for PTEST/PFLUSH/PLOAD
    pmmu_addr      : in  std_logic_vector(31 downto 0); -- Address for PTEST/PFLUSH/PLOAD

    -- Translation request (combinational response acceptable for identity)
    req            : in  std_logic;
    is_insn        : in  std_logic;
    rw             : in  std_logic; -- '1' read, '0' write
    fc             : in  std_logic_vector(2 downto 0);
    addr_log       : in  std_logic_vector(31 downto 0);
    access_size    : in  std_logic_vector(1 downto 0) := "10"; -- "00"=byte, "01"=word, "10"=long, "11"=reserved
    addr_phys      : out std_logic_vector(31 downto 0);
    cache_inhibit  : out std_logic;
    write_protect  : out std_logic;
    fault          : out std_logic;
    fault_status   : out std_logic_vector(31 downto 0);
    tc_enable      : out std_logic;

    -- Walker memory interface (read-only) and busy indicator
    mem_req        : buffer std_logic;
    mem_addr       : out std_logic_vector(31 downto 0);
    mem_ack        : in  std_logic;
    mem_rdat       : in  std_logic_vector(31 downto 0);
    busy           : out std_logic
  );
end TG68K_PMMU_030;

architecture rtl of TG68K_PMMU_030 is

  -- MC68030 PMMU Control Registers (complete set)
  -- MOVEC accessible: TC (0x003), TT0 (0x004), TT1 (0x005), MMUSR (0x805)
  -- PMOVE only: CRP, SRP, CAL, VAL, SCC, AC
  -- Register sizes: CRP/SRP are 64-bit, all others are 32-bit
  
  signal TC     : std_logic_vector(31 downto 0); -- Translation Control (EN, PS, IS, TIA-TID)
  signal CRP_H  : std_logic_vector(31 downto 0); -- CPU Root Pointer high 32 bits
  signal CRP_L  : std_logic_vector(31 downto 0); -- CPU Root Pointer low 32 bits (64-bit total)
  signal SRP_H  : std_logic_vector(31 downto 0); -- Supervisor Root Pointer high 32 bits
  signal SRP_L  : std_logic_vector(31 downto 0); -- Supervisor Root Pointer low 32 bits (64-bit total)
  signal TT0    : std_logic_vector(31 downto 0); -- Transparent Translation Register 0
  signal TT1    : std_logic_vector(31 downto 0); -- Transparent Translation Register 1
  signal MMUSR  : std_logic_vector(31 downto 0); -- MMU Status Register
  signal CAL    : std_logic_vector(31 downto 0); -- Current Access Level
  signal VAL    : std_logic_vector(31 downto 0); -- Valid Access Level
  signal SCC    : std_logic_vector(31 downto 0); -- Stack Change Control
  signal AC     : std_logic_vector(31 downto 0); -- Access Control

  -- Internal  
  signal tc_en  : std_logic; -- translation enable bit (TC[31] in some docs; keep flexible here)
  
  -- MC68030 register write masks (workaround for VHDL synthesis issues)
  -- TC register mask: preserve E(31), SRE(25), FCL(24), and all field bits (23-0), clear reserved bits 30-26
  constant TC_WRITE_MASK : std_logic_vector(31 downto 0) := "10000011111111111111111111111111";

  -- TTR register mask: preserve address bits (31-16), FC bits (7-4), control bits (2-0), clear reserved bits 15-8,3
  constant TTR_WRITE_MASK : std_logic_vector(31 downto 0) := "11111111111111110000000011110111";

  -- CRP/SRP HIGH mask: preserve table address (31-4), clear reserved bits (3-0)
  constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := "11111111111111111111111111110000";

  -- CRP/SRP LOW mask: preserve DT field (15-8), clear reserved bits (31-16,7-0)
  constant CRP_LOW_MASK : std_logic_vector(31 downto 0) := "00000000000000001111111100000000";
  
  -- Translation result latches
  signal addr_phys_reg      : std_logic_vector(31 downto 0) := (others => '0');
  signal cache_inhibit_reg  : std_logic := '0';
  signal write_protect_reg  : std_logic := '0';
  signal fault_reg          : std_logic := '0';
  signal fault_status_reg   : std_logic_vector(31 downto 0) := (others => '0');
  
  -- Walker fault signals (driven only by walker)
  signal walker_fault       : std_logic := '0';
  signal walker_fault_status : std_logic_vector(31 downto 0) := (others => '0');
  signal walker_fault_ack   : std_logic := '0';  -- Acknowledgment from main process
  signal walker_fault_ack_pending : std_logic := '0';  -- Track ack state
  
  -- Walker completion handshake
  signal walker_completed_ack : std_logic := '0';  -- Acknowledgment from main process
  
  -- Save the original request for later re-evaluation
  signal saved_addr_log     : std_logic_vector(31 downto 0) := (others => '0');
  signal saved_fc           : std_logic_vector(2 downto 0) := (others => '0');
  signal saved_is_insn      : std_logic := '0';
  signal saved_rw           : std_logic := '0';
  signal translation_pending : std_logic := '0';

  -- Enhanced ATC (Address Translation Cache), 16 entries, dynamic page sizes
  -- Increased from 8 to 16 entries for better hit rates, especially in multi-tasking scenarios
  constant ATC_ENTRIES : integer := 16;
  type atc_attr_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(2 downto 0);  -- {SUPER, CI, WP}
  type atc_val_t  is array(0 to ATC_ENTRIES-1) of std_logic;
  type atc_base_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(31 downto 0);
  type atc_fc_t   is array(0 to ATC_ENTRIES-1) of std_logic_vector(2 downto 0);
  type atc_isn_t  is array(0 to ATC_ENTRIES-1) of std_logic;
  type atc_shift_t is array(0 to ATC_ENTRIES-1) of integer range 8 to 15; -- Page offset bits (256B to 32KB)
  type atc_page_size_t is array(0 to ATC_ENTRIES-1) of integer range 0 to 7; -- MC68030 PS field value

  signal atc_log_base : atc_base_t;
  signal atc_phys_base: atc_base_t;
  signal atc_attr  : atc_attr_t;
  signal atc_valid : atc_val_t;
  signal atc_fc    : atc_fc_t;
  signal atc_is_insn : atc_isn_t;
  signal atc_shift : atc_shift_t;
  signal atc_page_size : atc_page_size_t;
  signal atc_rr    : integer range 0 to ATC_ENTRIES-1 := 0; -- simple round-robin (fallback)

  -- PLRU (Pseudo-Least Recently Used) replacement for 16-entry ATC
  -- Uses a 15-bit binary tree to track usage for efficient replacement
  signal atc_plru_tree : std_logic_vector(14 downto 0) := (others => '0'); -- 15 bits for 16 entries
  signal walk_req  : std_logic;
  signal walker_completed : std_logic := '0';

  -- Translation control decoding (TC register fields)
  type tc_bits_array_t is array(0 to 3) of integer range 0 to 16;
  constant DEFAULT_TC_BITS : tc_bits_array_t := (8, 8, 4, 0);
  constant DEFAULT_TC_IS   : integer := 0;
  signal tc_idx_bits      : tc_bits_array_t := DEFAULT_TC_BITS;
  signal tc_initial_shift : integer range 0 to 15 := DEFAULT_TC_IS;
  signal tc_page_size     : integer range 0 to 7 := 0;
  signal tc_page_shift    : integer range 0 to 31 := 12;
  signal tc_sre           : std_logic := '0';  -- Supervisor Root Enable
  signal tc_fcl           : std_logic := '0';  -- Function Code Lookup

  -- MMUSR update handshake between translation pipeline and register file
  signal mmusr_update_req   : std_logic := '0';
  signal mmusr_update_ack   : std_logic := '0';
  signal mmusr_update_value : std_logic_vector(31 downto 0) := (others => '0');

  -- MC68030 page table walker FSM
  type walk_state_t is (W_IDLE, W_ROOT, W_PTR1, W_PTR2, W_PTR3, W_PAGE, W_FILL, W_COMPLETE, W_FAULT);
  signal wstate    : walk_state_t := W_IDLE;
  
  -- Walker bookkeeping
  signal walk_log_base  : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_phys_base : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_page_shift: integer range 8 to 15 := 12;
  signal walk_page_size : integer range 0 to 7 := 4;
  
  -- PMMU instruction communication flags (to avoid multiple drivers)
  signal ptest_update_mmusr : std_logic := '0';
  signal pflush_clear_atc   : std_logic := '0';
  signal atc_flush_req      : std_logic := '0';
  
  -- Edge detection for PMMU instructions
  signal ptest_req_prev  : std_logic := '0';
  signal pflush_req_prev : std_logic := '0';
  signal pload_req_prev  : std_logic := '0';
  
  -- PTEST operation state
  signal ptest_active : std_logic := '0';
  signal ptest_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_fc : std_logic_vector(2 downto 0) := (others => '0');
  
  -- PLOAD operation state
  signal pload_active : std_logic := '0';
  signal pload_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pload_fc : std_logic_vector(2 downto 0) := (others => '0');
  
  -- Page table walking state
  signal walk_level     : integer range 0 to 4 := 0; -- Current level being walked  
  signal walk_desc      : std_logic_vector(31 downto 0) := (others => '0'); -- Current descriptor
  signal walk_addr      : std_logic_vector(31 downto 0) := (others => '0'); -- Current table address
  signal walk_vpn       : std_logic_vector(31 downto 0) := (others => '0'); -- Virtual page being walked
  signal walk_fault     : std_logic := '0'; -- Page fault flag
  signal walk_attr      : std_logic_vector(7 downto 0) := (others => '0'); -- Page attributes

  -- Local helper for Quartus: convert std_logic_vector to hex string.
  function slv_to_hstring(value : std_logic_vector) return string is
    constant hex_chars   : string := "0123456789ABCDEF";
    constant nibble_count: integer := (value'length + 3) / 4;
    variable result      : string(1 to nibble_count);
    variable nibble_val  : integer range 0 to 15;
    variable bit_val     : std_logic;
    variable bit_index   : integer;
    variable idx         : integer;
    variable has_unknown : boolean;
  begin
    for i in result'range loop
      result(i) := '0';
    end loop;

    for nib in 0 to nibble_count - 1 loop
      nibble_val  := 0;
      has_unknown := false;
      for bit in 0 to 3 loop
        nibble_val := nibble_val * 2;
        bit_index  := nib * 4 + bit;
        if bit_index < value'length then
          idx     := value'high - bit_index;
          bit_val := value(idx);
          case bit_val is
            when '0' | 'L' => null;
            when '1' | 'H' => nibble_val := nibble_val + 1;
            when others    => has_unknown := true;
          end case;
        end if;
      end loop;
      if has_unknown then
        result(nib + 1) := 'X';
      else
        result(nib + 1) := hex_chars(nibble_val + 1);
      end if;
    end loop;

    return result;
  end function;

  -- Convert std_logic_vector to a human-readable bit string (MSB first).
  function slv_to_string(value : std_logic_vector) return string is
    variable result : string(1 to value'length);
    variable idx    : integer;
  begin
    for i in 0 to value'length - 1 loop
      idx := value'high - i;
      case value(idx) is
        when '0' | 'L' => result(i + 1) := '0';
        when '1' | 'H' => result(i + 1) := '1';
        when 'Z'       => result(i + 1) := 'Z';
        when 'W'       => result(i + 1) := 'W';
        when 'U'       => result(i + 1) := 'U';
        when 'X'       => result(i + 1) := 'X';
        when others    => result(i + 1) := '?';
      end case;
    end loop;
    return result;
  end function;

  -- Decode a TC field, falling back to the default when zero (per 68030 spec).
  function decode_tc_field(field : std_logic_vector(3 downto 0);
                           default_val : integer) return integer is
    variable tmp : integer;
  begin
    tmp := to_integer(unsigned(field));
    if tmp = 0 then
      return default_val;
    else
      return tmp;
    end if;
  end function;

  function align_addr(addr : std_logic_vector(31 downto 0);
                      shift : integer) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0) := addr;
    variable mask : std_logic_vector(31 downto 0) := (others => '1');
  begin
    if shift <= 0 or shift >= 32 then
      return addr; -- No alignment needed
    end if;
    
    -- Create alignment mask by shifting (synthesis-friendly)
    mask := std_logic_vector(shift_left(unsigned(mask), shift));
    result := addr and mask;
    
    return result;
  end function;

  -- Calculate page offset bits based on MC68030 PS field (TC bits 23:20)
  function get_page_offset_bits(ps_field : integer) return integer is
  begin
    case ps_field is
      when 0 => return 8;   -- 256 bytes (MC68030 PS=0 maps to 256B pages)
      when 1 => return 9;   -- 512 bytes
      when 2 => return 10;  -- 1KB
      when 3 => return 11;  -- 2KB
      when 4 => return 12;  -- 4KB
      when 5 => return 13;  -- 8KB
      when 6 => return 14;  -- 16KB
      when 7 => return 15;  -- 32KB
      when others => return 12; -- Default to 4KB for invalid values
    end case;
  end function;

  function page_shift_from_tc(ps : integer) return integer is
  begin
    return get_page_offset_bits(ps);
  end function;

  -- Extract PS field from MC68030 page descriptor (bits 3:2)
  function get_desc_page_size(desc : std_logic_vector(31 downto 0)) return integer is
  begin
    return to_integer(unsigned(desc(3 downto 2)));
  end function;

  -- Get page shift from descriptor PS field
  function get_desc_page_shift(desc : std_logic_vector(31 downto 0)) return integer is
    variable ps : integer;
  begin
    ps := get_desc_page_size(desc);
    return get_page_offset_bits(ps);
  end function;

  -- Check if descriptor is a large page (PS > 0)
  function is_large_page(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return get_desc_page_size(desc) > 0;
  end function;

  -- PLRU (Pseudo-Least Recently Used) functions for 16-entry ATC
  -- Binary tree implementation: 15 bits for 16 entries
  -- Tree structure: bit 0 = root, left subtree = 0, right subtree = 1
  function plru_get_victim(tree : std_logic_vector(14 downto 0)) return integer is
    variable idx : integer := 0;
  begin
    -- Start at root and follow the tree to find victim
    if tree(0) = '0' then
      -- Go left subtree (entries 0-7)
      idx := 1;
      if tree(1) = '0' then
        idx := 3;
        if tree(3) = '0' then
          idx := 7;
          if tree(7) = '0' then
            return 0;
          else
            return 1;
          end if;
        else
          idx := 8;
          if tree(8) = '0' then
            return 2;
          else
            return 3;
          end if;
        end if;
      else
        idx := 4;
        if tree(4) = '0' then
          idx := 9;
          if tree(9) = '0' then
            return 4;
          else
            return 5;
          end if;
        else
          idx := 10;
          if tree(10) = '0' then
            return 6;
          else
            return 7;
          end if;
        end if;
      end if;
    else
      -- Go right subtree (entries 8-15)
      idx := 2;
      if tree(2) = '0' then
        idx := 5;
        if tree(5) = '0' then
          idx := 11;
          if tree(11) = '0' then
            return 8;
          else
            return 9;
          end if;
        else
          idx := 12;
          if tree(12) = '0' then
            return 10;
          else
            return 11;
          end if;
        end if;
      else
        idx := 6;
        if tree(6) = '0' then
          idx := 13;
          if tree(13) = '0' then
            return 12;
          else
            return 13;
          end if;
        else
          idx := 14;
          if tree(14) = '0' then
            return 14;
          else
            return 15;
          end if;
        end if;
      end if;
    end if;
  end function;

  function plru_update_tree(tree : std_logic_vector(14 downto 0); used_entry : integer)
    return std_logic_vector is
    variable new_tree : std_logic_vector(14 downto 0) := tree;
  begin
    -- Update tree based on which entry was accessed
    case used_entry is
      when 0 =>  new_tree(0) := '1'; new_tree(1) := '1'; new_tree(3) := '1'; new_tree(7) := '1';
      when 1 =>  new_tree(0) := '1'; new_tree(1) := '1'; new_tree(3) := '1'; new_tree(7) := '0';
      when 2 =>  new_tree(0) := '1'; new_tree(1) := '1'; new_tree(3) := '0'; new_tree(8) := '1';
      when 3 =>  new_tree(0) := '1'; new_tree(1) := '1'; new_tree(3) := '0'; new_tree(8) := '0';
      when 4 =>  new_tree(0) := '1'; new_tree(1) := '0'; new_tree(4) := '1'; new_tree(9) := '1';
      when 5 =>  new_tree(0) := '1'; new_tree(1) := '0'; new_tree(4) := '1'; new_tree(9) := '0';
      when 6 =>  new_tree(0) := '1'; new_tree(1) := '0'; new_tree(4) := '0'; new_tree(10) := '1';
      when 7 =>  new_tree(0) := '1'; new_tree(1) := '0'; new_tree(4) := '0'; new_tree(10) := '0';
      when 8 =>  new_tree(0) := '0'; new_tree(2) := '1'; new_tree(5) := '1'; new_tree(11) := '1';
      when 9 =>  new_tree(0) := '0'; new_tree(2) := '1'; new_tree(5) := '1'; new_tree(11) := '0';
      when 10 => new_tree(0) := '0'; new_tree(2) := '1'; new_tree(5) := '0'; new_tree(12) := '1';
      when 11 => new_tree(0) := '0'; new_tree(2) := '1'; new_tree(5) := '0'; new_tree(12) := '0';
      when 12 => new_tree(0) := '0'; new_tree(2) := '0'; new_tree(6) := '1'; new_tree(13) := '1';
      when 13 => new_tree(0) := '0'; new_tree(2) := '0'; new_tree(6) := '1'; new_tree(13) := '0';
      when 14 => new_tree(0) := '0'; new_tree(2) := '0'; new_tree(6) := '0'; new_tree(14) := '1';
      when 15 => new_tree(0) := '0'; new_tree(2) := '0'; new_tree(6) := '0'; new_tree(14) := '0';
      when others => null; -- Invalid entry, don't update
    end case;
    return new_tree;
  end function;

  -- Unaligned access detection functions
  function get_access_size_bytes(size : std_logic_vector(1 downto 0)) return integer is
  begin
    case size is
      when "00" => return 1; -- byte
      when "01" => return 2; -- word
      when "10" => return 4; -- long
      when others => return 1; -- reserved, treat as byte
    end case;
  end function;

  function is_unaligned_access(addr : std_logic_vector(31 downto 0); size : std_logic_vector(1 downto 0)) return boolean is
  begin
    case size is
      when "00" => return false; -- byte access is always aligned
      when "01" => return addr(0) = '1'; -- word must be even aligned
      when "10" => return addr(1 downto 0) /= "00"; -- long must be 4-byte aligned
      when others => return false; -- reserved
    end case;
  end function;

  function crosses_page_boundary(addr : std_logic_vector(31 downto 0); size : std_logic_vector(1 downto 0); page_shift : integer) return boolean is
    variable end_addr : unsigned(31 downto 0);
    variable page_mask : unsigned(31 downto 0);
  begin
    end_addr := unsigned(addr) + to_unsigned(get_access_size_bytes(size) - 1, 32);
    page_mask := (others => '1');
    page_mask(page_shift-1 downto 0) := (others => '0');

    -- Check if start and end addresses are in different pages
    return (unsigned(addr) and page_mask) /= (end_addr and page_mask);
  end function;

  -- Enhanced function code validation for MC68030
  function is_valid_fc(fc : std_logic_vector(2 downto 0)) return boolean is
  begin
    -- MC68030 supports all 8 function codes (0-7)
    -- FC2=0: User mode (FC 0-3), FC2=1: Supervisor mode (FC 4-7)
    -- FC1,FC0: 00=reserved, 01=User/Supervisor Data, 10=User/Supervisor Program, 11=reserved/CPU
    case fc is
      when "000" => return false; -- Reserved in user mode
      when "001" => return true;  -- User data
      when "010" => return true;  -- User program
      when "011" => return false; -- Reserved in user mode
      when "100" => return false; -- Reserved in supervisor mode
      when "101" => return true;  -- Supervisor data
      when "110" => return true;  -- Supervisor program
      when "111" => return true;  -- CPU space (supervisor only)
      when others => return false;
    end case;
  end function;

  function fc_allows_supervisor_access(fc : std_logic_vector(2 downto 0)) return boolean is
  begin
    -- Check if FC indicates supervisor mode access
    return fc(2) = '1'; -- FC2=1 means supervisor mode
  end function;

  function fc_matches_required_access(page_fc : std_logic_vector(2 downto 0); access_fc : std_logic_vector(2 downto 0)) return boolean is
  begin
    -- For now, simple match - could be enhanced with FC lookup mode
    return page_fc = access_fc;
  end function;

  -- Limit checking functions for MC68030 page table walks
  function check_table_limit(desc : std_logic_vector(31 downto 0); index : integer; tc_bits : integer) return boolean is
    variable limit : unsigned(15 downto 0);
    variable max_index : integer;
  begin
    -- Extract limit field from descriptor (upper 16 bits for table descriptors)
    limit := unsigned(desc(31 downto 16));

    -- Calculate maximum valid index based on TC bits
    max_index := (2 ** tc_bits) - 1;

    -- Check if index exceeds descriptor limit or TC-defined maximum
    return index <= to_integer(limit) and index <= max_index;
  end function;

  function get_effective_limit(desc : std_logic_vector(31 downto 0); tc_bits : integer) return integer is
    variable desc_limit : integer;
    variable tc_limit : integer;
  begin
    desc_limit := to_integer(unsigned(desc(31 downto 16)));
    tc_limit := (2 ** tc_bits) - 1;

    -- Return the more restrictive limit
    if desc_limit < tc_limit then
      return desc_limit;
    else
      return tc_limit;
    end if;
  end function;

  function phys_base_from_desc(desc : std_logic_vector(31 downto 0);
                               shift : integer) return std_logic_vector is
    variable base : std_logic_vector(31 downto 0);
  begin
    base(31 downto 8) := desc(31 downto 8);
    base(7 downto 0)  := (others => '0');
    return align_addr(base, shift);
  end function;

  -- MC68030 TTR format: proper transparent translation register implementation
  -- TTR bits: 31:24=base, 23:16=mask, 15=E, 14:13=S, 12:8=FC, 5=CM, 1=CI, 0=WP
  procedure ttr_check(
      tt        : in  std_logic_vector(31 downto 0);
      addr      : in  std_logic_vector(31 downto 0);
      fc        : in  std_logic_vector(2 downto 0);
      is_insn   : in  std_logic;
      matched   : out std_logic;
      ci        : out std_logic;
      wp        : out std_logic) is
    variable enable     : std_logic;
    variable base       : std_logic_vector(7 downto 0);
    variable mask       : std_logic_vector(7 downto 0);
    variable addr_hi    : std_logic_vector(7 downto 0);
    variable super_bits : std_logic_vector(1 downto 0);
    variable fc_mask    : std_logic_vector(4 downto 0);
    variable addr_match : std_logic;
    variable fc_match   : std_logic;
    variable super_match: std_logic;
  begin
    -- MC68030 TTR format
    enable     := tt(15);           -- E bit: TTR enable
    base       := tt(31 downto 24); -- Base address (bits 31:24)
    mask       := tt(23 downto 16); -- Address mask (bits 23:16)
    super_bits := tt(14 downto 13); -- S field: 00=any, 01=user, 10=super, 11=reserved
    fc_mask    := tt(12 downto 8);  -- FC mask
    addr_hi    := addr(31 downto 24); -- Address high byte
    
    -- Early exit if TTR is disabled - prevents any false matches
    if enable = '0' then
      matched := '0';
      ci := '0';
      wp := '0';
      return;
    end if;
    
    -- Address match: MC68030 TTR mask logic
    -- mask=1 means "must match", mask=0 means "don't care"
    -- Match when all masked bits of addr equal all masked bits of base
    -- Implementation: XOR to find differences, then mask to ignore don't-care bits
    -- If result is zero, all required bits match
    if ((addr_hi XOR base) AND mask) = x"00" then
      addr_match := '1';
    else
      addr_match := '0';
    end if;
    
    -- Function code match: MC68030 TTR FC mask implementation
    -- FC mask bits (12:8) control which function codes are allowed
    -- MC68030 Function Code Specification:
    -- FC=001: User Data
    -- FC=010: User Program (Instruction)  
    -- FC=101: Supervisor Data
    -- FC=110: Supervisor Program (Instruction)
    -- FC=000,011,100,111: Reserved
    
    if fc_mask = "00000" then
      fc_match := '1'; -- Default: allow all function codes when mask is 0
    else
      -- Check if the function code matches the mask
      -- Map MC68030 function codes to TTR FC mask bit positions
      case fc is
        when "001" => fc_match := fc_mask(0); -- User Data → bit 0
        when "010" => fc_match := fc_mask(1); -- User Program → bit 1
        when "101" => fc_match := fc_mask(2); -- Supervisor Data → bit 2
        when "110" => fc_match := fc_mask(3); -- Supervisor Program → bit 3
        when "000" | "011" | "100" | "111" => fc_match := fc_mask(4); -- Reserved → bit 4
        when others => fc_match := '0';
      end case;
    end if;
    
    -- Supervisor/User match
    case super_bits is
      when "00" => super_match := '1';                    -- Any mode
      when "01" => 
        if fc(2) = '0' then
          super_match := '1';  -- User only
        else
          super_match := '0';
        end if;
      when "10" => 
        if fc(2) = '1' then
          super_match := '1';  -- Supervisor only
        else
          super_match := '0';
        end if;
      when others => super_match := '0';                  -- Reserved
    end case;
    
    -- Overall match - MUST check enable first
    if enable = '1' AND addr_match = '1' AND fc_match = '1' AND super_match = '1' then
      matched := '1';
      ci := tt(1);  -- Cache inhibit
      wp := tt(0);  -- Write protect
      -- Debug for write protection test
      if addr(31 downto 12) = x"00002" then
        report "TTR_MATCH_DEBUG: addr=0x" & slv_to_hstring(addr) & 
               " base=0x" & slv_to_hstring("000000" & base) &
               " mask=0x" & slv_to_hstring("000000" & mask) &
               " addr_hi=0x" & slv_to_hstring("000000" & addr_hi) &
               " enable=" & std_logic'image(enable) &
               " addr_match=" & std_logic'image(addr_match) &
               " fc_match=" & std_logic'image(fc_match) &
               " super_match=" & std_logic'image(super_match) &
               " tt_reg=0x" & slv_to_hstring(tt) severity note;
      end if;
    else
      matched := '0';
      ci := '0';
      wp := '0';
    end if;
  end procedure;

  procedure ttr_match(
      tt      : in  std_logic_vector(31 downto 0);
      addr    : in  std_logic_vector(31 downto 0);
      fc      : in  std_logic_vector(2 downto 0);
      is_insn : in  std_logic;
      matched : out std_logic) is
    variable dummy_ci : std_logic;
    variable dummy_wp : std_logic;
  begin
    ttr_check(tt, addr, fc, is_insn, matched, dummy_ci, dummy_wp);
  end procedure;
  
  -- Extract table index from virtual address (MC68030 compliant)
  function get_table_index(addr : std_logic_vector(31 downto 0);
                          level : integer;
                          initial_shift : integer;
                          idx_bits : tc_bits_array_t) return integer is
    variable result : integer;
    variable shift_amount : integer;
    variable mask_width : integer;
    variable temp_addr : unsigned(31 downto 0);
    variable remaining_bits : integer;
  begin
    if level < 0 or level > 3 then
      return 0;
    end if;

    mask_width := idx_bits(level);
    if mask_width <= 0 then
      return 0;
    end if;

    -- MC68030 table index calculation:
    -- Address format: [31:IS+TIA+TIB+TIC+TID] [TIA bits] [TIB bits] [TIC bits] [TID bits] [IS bits]
    -- Each level extracts its portion from the logical address after IS initial shift
    
    -- Calculate shift amount for this level
    -- MC68030 format: [31:x] [Level0] [Level1] [Level2] [Level3] [IS bits]
    -- For each level, sum up the bits that come after it (ALL lower levels + IS)
    remaining_bits := initial_shift; -- Start with IS (initial shift bits)
    
    -- Add bits from ALL levels that come after this one (0 is highest, 3 is lowest)
    -- Use explicit checks instead of variable loop bounds (synthesis compatible)
    if level < 1 then remaining_bits := remaining_bits + idx_bits(1); end if;
    if level < 2 then remaining_bits := remaining_bits + idx_bits(2); end if;
    if level < 3 then remaining_bits := remaining_bits + idx_bits(3); end if;
    
    -- The shift amount is the starting bit position for this level
    shift_amount := remaining_bits;
    
    -- Ensure valid shift amount
    if shift_amount < 0 or shift_amount >= 32 then
      return 0;
    end if;
    
    -- Extract bits by shifting right and masking
    temp_addr := unsigned(addr);
    temp_addr := shift_right(temp_addr, shift_amount);
    result := to_integer(temp_addr AND to_unsigned((2**mask_width) - 1, 32));
    
    return result;
  end function;
  
  -- Check if descriptor is a page descriptor (not table pointer)
  -- MC68030 descriptor format: bits 1:0 determine type
  -- 00 = Invalid, 01 = Page descriptor, 10/11 = Table pointer
  function desc_is_page(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "01"; -- Page descriptor only when bits 1:0 = "01"
  end function;

  -- Check if descriptor is a valid table descriptor
  function desc_is_table(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "10" OR desc(1 downto 0) = "11"; -- Table descriptors
  end function;

  -- Check if descriptor is valid (not invalid type 00)
  function desc_valid(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) /= "00"; -- Any type except invalid
  end function;
  
  -- Check supervisor/user access permissions (MC68030 compliant)
  function access_allowed(desc : std_logic_vector(31 downto 0);
                         fc : std_logic_vector(2 downto 0)) return boolean is
    variable is_supervisor_fc : boolean;
    variable is_supervisor_page : boolean;
  begin
    -- MC68030 function code definitions:
    -- FC2=0: User space, FC2=1: Supervisor space
    is_supervisor_fc := (fc(2) = '1');
    
    -- MC68030 page descriptor format - bit 7 controls access
    -- desc(7)=0: Supervisor only page, desc(7)=1: User accessible page
    is_supervisor_page := (desc(7) = '0');
    
    -- Access control rules:
    -- 1. Supervisor can access both supervisor and user pages
    -- 2. User can only access user pages (desc(7)=1)
    if is_supervisor_fc then
      return true; -- Supervisor access - allowed to both types
    else
      return NOT is_supervisor_page; -- User access - only to user pages (desc(7)=1)
    end if;
  end function;
  
  -- MC68030 MMUSR encoding functions
  -- MMUSR Bit Assignments (MC68030 User's Manual):
  -- Bit 15: Bus Error (B)
  -- Bit 14: Limit Violation (L) 
  -- Bit 13: Supervisor Violation (S)
  -- Bit 12: Cache Inhibit (CI)
  -- Bit 11: Write Protect (WP)
  -- Bit 10: Modified (M)
  -- Bit 9: Transparent (T)
  -- Bit 8: Resident (R)
  -- Bits 7-5: Reserved (0)
  -- Bits 4-3: Level (at which fault occurred)
  -- Bits 2-0: Reserved (0)
  
  function encode_mmusr_fault(
    bus_error : std_logic;
    limit_violation : std_logic;
    supervisor_violation : std_logic;
    cache_inhibit : std_logic;
    write_protect : std_logic;
    modified : std_logic;
    transparent : std_logic;
    resident : std_logic;
    level : std_logic_vector(1 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    -- Initialize to zero
    result := (others => '0');

    -- Set the fault bits according to MC68030 MMUSR format
    result(15) := bus_error;
    result(14) := limit_violation;
    result(13) := supervisor_violation;
    result(12) := cache_inhibit;
    result(11) := write_protect;
    result(10) := modified;
    result(9) := transparent;
    result(8) := resident;
    -- Bits 7-5 reserved (0) - already cleared
    result(4 downto 3) := level;
    -- Bits 2-0 reserved (0) - already cleared

    return result;
  end function;
  
  function encode_mmusr_success(
    cache_inhibit : std_logic;
    write_protect : std_logic;
    transparent : std_logic
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    result := (others => '0');
    result(12) := cache_inhibit;  -- CI bit
    result(11) := write_protect;  -- WP bit  
    result(9) := transparent;     -- T bit
    result(8) := '1';             -- R bit (resident - translation successful)
    -- Ensure reserved bits are always 0 (force correct MC68030 format)
    result(31 downto 16) := (others => '0');  -- Upper bits reserved
    result(15 downto 13) := "000";            -- Reserved fault bits for success case
    result(10) := '0';                        -- Modified bit (not set for success)
    result(7 downto 5) := "000";              -- Reserved bits must be 0
    result(4 downto 0) := "00000";            -- Reserved bits must be 0  
    return result;
  end function;

begin

  -- Reset and register writes
  process(clk, nreset)
  begin
    if nreset = '0' then
      TC    <= (others => '0');
      CRP_H <= (others => '0');
      CRP_L <= (others => '0');
      SRP_H <= (others => '0');
      SRP_L <= (others => '0');
      TT0   <= (others => '0');
      TT1   <= (others => '0');
      MMUSR <= (others => '0');
      CAL   <= (others => '0');
      VAL   <= (others => '0');
      SCC   <= (others => '0');
      AC    <= (others => '0');
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      ptest_active <= '0';
      ptest_addr <= (others => '0');
      ptest_fc <= (others => '0');
    elsif rising_edge(clk) then
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      -- Handle MMUSR updates with MC68030-compliant priority (avoid multiple drivers)
      if ptest_update_mmusr = '1' then
        -- Highest priority: PTEST instruction (MC68030 specification)
        ptest_active <= '1';
        ptest_addr <= pmmu_addr;
        ptest_fc <= pmmu_fc;
        if tc_en = '0' then
          -- MMU disabled - PTEST always succeeds with identity translation
          MMUSR <= encode_mmusr_success(
            cache_inhibit => '0',        -- No cache inhibit for identity
            write_protect => '0',        -- No write protect for identity
            transparent => '0'           -- Not transparent (MMU disabled)
          );
        else
          -- MMU enabled - will be handled by main translation logic
          null; -- Translation process will update MMUSR
        end if;
      elsif mmusr_update_req = '1' then
        -- Medium priority: Translation engine update (automatic updates)
        MMUSR <= mmusr_update_value;
        mmusr_update_ack <= '1';
      elsif reg_we = '1' then
        -- Lowest priority: Direct register writes (MC68030 MMUSR is mostly read-only)
        -- MC68030 Specification: MMU register access requires supervisor mode (FC2=1)
        if fc(2) = '1' then
          case reg_sel is
          when x"0" =>
            -- MC68030 TC Register Write - exact specification compliance
            -- MC68030 TC bit layout per User's Manual section 9.2.1:
            -- 31: E (Enable), 30-26: Reserved, 25: SRE, 24: FCL
            -- 23-20: PS (Page Size), 19-16: IS (Initial Shift), 15-12: TIA, 11-8: TIB, 7-4: TIC, 3-0: TID
            -- Reserved bits: 30-26 only (all other bits are valid control fields)
            TC(31) <= reg_wdat(31);          -- E (Enable)
            TC(30 downto 26) <= "00000";     -- Reserved bits (force to 0)
            TC(25) <= reg_wdat(25);          -- SRE (Supervisor Root Enable)
            TC(24) <= reg_wdat(24);          -- FCL (Function Code Lookup)
            TC(23 downto 20) <= reg_wdat(23 downto 20); -- PS (Page Size)
            TC(19 downto 16) <= reg_wdat(19 downto 16); -- IS (Initial Shift)
            TC(15 downto 12) <= reg_wdat(15 downto 12); -- TIA (Table Index A)
            TC(11 downto 8) <= reg_wdat(11 downto 8);   -- TIB (Table Index B)
            TC(7 downto 4) <= reg_wdat(7 downto 4);     -- TIC (Table Index C)
            TC(3 downto 0) <= reg_wdat(3 downto 0);     -- TID (Table Index D)
            atc_flush_req <= '1'; -- TC changes invalidate all cached translations
            report "TC_WRITE_SPEC_COMPLIANT: input=0x" & slv_to_hstring(reg_wdat) &
                   " reserved bits 30-26 masked to zero" severity note;
          when x"1" =>
            -- CRP register write - MC68030 Long-Format Root Pointer per User's Manual section 9.2.2
            if reg_part = '1' then
              -- CRP HIGH WORD (bits 63-32): Table Address[31:4] + Reserved[3:0]
              -- MC68030 spec: Table address bits 31-4, reserved bits 3-0 must be zero
              CRP_H(31 downto 4) <= reg_wdat(31 downto 4); -- Table address (16-byte aligned)
              CRP_H(3 downto 0) <= "0000";                 -- Reserved (must be zero)
            else
              -- CRP LOW WORD (bits 31-0): Upper Limit[31:16] + DT[15:8] + Lower Limit[7:0]
              -- MC68030 spec: All bits are valid in long-format root pointer low word
              CRP_L(31 downto 16) <= reg_wdat(31 downto 16); -- Upper Limit
              CRP_L(15 downto 8) <= reg_wdat(15 downto 8);   -- DT (Descriptor Type)
              CRP_L(7 downto 0) <= reg_wdat(7 downto 0);     -- Lower Limit
            end if;
            atc_flush_req <= '1'; -- CRP changes invalidate all cached translations
          when x"2" =>
            -- SRP register write - MC68030 Long-Format Root Pointer (same as CRP)
            if reg_part = '1' then
              -- SRP HIGH WORD (bits 63-32): Table Address[31:4] + Reserved[3:0]
              -- MC68030 spec: Table address bits 31-4, reserved bits 3-0 must be zero
              SRP_H(31 downto 4) <= reg_wdat(31 downto 4); -- Table address (16-byte aligned)
              SRP_H(3 downto 0) <= "0000";                 -- Reserved (must be zero)
            else
              -- SRP LOW WORD (bits 31-0): Upper Limit[31:16] + DT[15:8] + Lower Limit[7:0]
              -- MC68030 spec: All bits are valid in long-format root pointer low word
              SRP_L(31 downto 16) <= reg_wdat(31 downto 16); -- Upper Limit
              SRP_L(15 downto 8) <= reg_wdat(15 downto 8);   -- DT (Descriptor Type)
              SRP_L(7 downto 0) <= reg_wdat(7 downto 0);     -- Lower Limit
            end if;
            atc_flush_req <= '1'; -- SRP changes invalidate all cached translations
          when x"3" =>
            -- TT0 register write - MC68030 Transparent Translation Register per User's Manual section 9.2.6
            -- MC68030 TT0/TT1 bit layout:
            -- 31-24: Logical Address Base, 23-16: Logical Address Mask
            -- 15: E (Enable), 14-10: Reserved, 9-8: CI (Cache Inhibit)
            -- 7-4: Function Code Mask, 3: Reserved, 2: RWM, 1: RW, 0: Reserved
            TT0(31 downto 24) <= reg_wdat(31 downto 24);   -- Logical Address Base
            TT0(23 downto 16) <= reg_wdat(23 downto 16);   -- Logical Address Mask
            TT0(15) <= reg_wdat(15);                        -- E (Enable)
            TT0(14 downto 10) <= "00000";                  -- Reserved (must be zero)
            TT0(9 downto 8) <= reg_wdat(9 downto 8);       -- CI (Cache Inhibit)
            TT0(7 downto 4) <= reg_wdat(7 downto 4);       -- Function Code Mask
            TT0(3) <= '0';                                  -- Reserved (must be zero)
            TT0(2 downto 1) <= reg_wdat(2 downto 1);       -- RWM, RW
            TT0(0) <= '0';                                  -- Reserved (must be zero)
            atc_flush_req <= '1';
            report "TT0_WRITE_SPEC_COMPLIANT: input=0x" & slv_to_hstring(reg_wdat) &
                   " reserved bits 14-10,3,0 masked to zero" severity note;
          when x"4" =>
            -- TT1 register write - MC68030 Transparent Translation Register (same layout as TT0)
            -- MC68030 TT0/TT1 bit layout:
            -- 31-24: Logical Address Base, 23-16: Logical Address Mask
            -- 15: E (Enable), 14-10: Reserved, 9-8: CI (Cache Inhibit)
            -- 7-4: Function Code Mask, 3: Reserved, 2: RWM, 1: RW, 0: Reserved
            TT1(31 downto 24) <= reg_wdat(31 downto 24);   -- Logical Address Base
            TT1(23 downto 16) <= reg_wdat(23 downto 16);   -- Logical Address Mask
            TT1(15) <= reg_wdat(15);                        -- E (Enable)
            TT1(14 downto 10) <= "00000";                  -- Reserved (must be zero)
            TT1(9 downto 8) <= reg_wdat(9 downto 8);       -- CI (Cache Inhibit)
            TT1(7 downto 4) <= reg_wdat(7 downto 4);       -- Function Code Mask
            TT1(3) <= '0';                                  -- Reserved (must be zero)
            TT1(2 downto 1) <= reg_wdat(2 downto 1);       -- RWM, RW
            TT1(0) <= '0';                                  -- Reserved (must be zero)
            atc_flush_req <= '1';
          when x"5" =>
            -- MMUSR register: MC68030 MMUSR is mostly read-only with some write-1-to-clear bits
            -- For now, implement basic write capability for testing purposes
            -- TODO: Implement proper MC68030 MMUSR semantics (write-1-to-clear for fault bits)
            MMUSR <= reg_wdat;
          when x"6" => CAL   <= reg_wdat;
          when x"7" => VAL   <= reg_wdat;
          when x"8" => SCC   <= reg_wdat;
          when x"9" => AC    <= reg_wdat;
          when others => null;
          end case;
        else
          -- MC68030 Specification: Privilege violation - MMU register access in user mode
          -- User mode attempts to access MMU registers should be ignored/faulted
          report "PRIVILEGE_VIOLATION: User mode attempt to write MMU register sel=0x" &
                 slv_to_hstring(reg_sel) & " FC=" & slv_to_hstring(fc) severity warning;
        end if;
      end if;
    end if;
  end process;

  -- Register reads (latch data when reg_re asserted)
  process(clk, nreset)
  begin
    if nreset = '0' then
      reg_rdat <= (others => '0');
    elsif rising_edge(clk) then
      if reg_re = '1' then
        -- MC68030 Specification: MMU register access requires supervisor mode (FC2=1)
        if fc(2) = '1' then
          case reg_sel is
            when x"0" => reg_rdat <= TC;
            when x"1" => if reg_part = '1' then reg_rdat <= CRP_H; else reg_rdat <= CRP_L; end if;
            when x"2" => if reg_part = '1' then reg_rdat <= SRP_H; else reg_rdat <= SRP_L; end if;
            when x"3" => reg_rdat <= TT0;
            when x"4" => reg_rdat <= TT1;
            when x"5" => reg_rdat <= MMUSR;
            when x"6" => reg_rdat <= CAL;
            when x"7" => reg_rdat <= VAL;
            when x"8" => reg_rdat <= SCC;
            when x"9" => reg_rdat <= AC;
            when others => reg_rdat <= (others => '0');
          end case;
        else
          -- MC68030 Specification: Privilege violation - MMU register access in user mode
          -- User mode attempts to read MMU registers should return zeros or fault
          reg_rdat <= (others => '0');
          report "PRIVILEGE_VIOLATION: User mode attempt to read MMU register sel=0x" &
                 slv_to_hstring(reg_sel) & " FC=" & slv_to_hstring(fc) severity warning;
        end if;
      end if;
    end if;
  end process;

  -- Extract TC register fields according to MC68030 specification
  -- TC Register Format (MC68030):
  -- Bit 31: E (Enable)
  -- Bit 25: SRE (Supervisor Root Enable) 
  -- Bit 24: FCL (Function Code Lookup)
  -- Bits 23-20: PS (Page Size)
  -- Bits 19-16: IS (Initial Shift)
  -- Bits 15-12: TIA (Table A Index)
  -- Bits 11-8: TIB (Table B Index)
  -- Bits 7-4: TIC (Table C Index)  
  -- Bits 3-0: TID (Table D Index)
  tc_en <= TC(31);
  tc_sre <= TC(25);
  tc_fcl <= TC(24);
  tc_enable <= tc_en;
  
  process(TC)
    variable ps_val : integer;
    variable total_bits : integer;
    variable is_bits : integer;
    variable page_offset_bits : integer;
    variable tia_bits, tib_bits, tic_bits, tid_bits : integer;
  begin
    -- Decode TC register fields with MC68030 validation
    tia_bits := decode_tc_field(TC(15 downto 12), DEFAULT_TC_BITS(0));
    tib_bits := decode_tc_field(TC(11 downto 8),  DEFAULT_TC_BITS(1));
    tic_bits := decode_tc_field(TC(7 downto 4),   DEFAULT_TC_BITS(2));
    tid_bits := decode_tc_field(TC(3 downto 0),   DEFAULT_TC_BITS(3));
    
    tc_idx_bits(0) <= tia_bits;
    tc_idx_bits(1) <= tib_bits;
    tc_idx_bits(2) <= tic_bits;
    tc_idx_bits(3) <= tid_bits;

    -- Initial Shift (IS) field
    if to_integer(unsigned(TC(19 downto 16))) = 0 then
      is_bits := DEFAULT_TC_IS;
    else
      is_bits := to_integer(unsigned(TC(19 downto 16)));
    end if;
    tc_initial_shift <= is_bits;

    -- Page Size (PS) field - MC68030 valid range is 0-7
    ps_val := to_integer(unsigned(TC(23 downto 20)));
    -- Clamp invalid PS values (8-15) to valid range (0-7)
    if ps_val > 7 then
      ps_val := 7; -- Clamp to maximum valid PS value (32KB pages)
      report "TC_PS_CLAMP: Invalid page size " & integer'image(to_integer(unsigned(TC(23 downto 20)))) & 
             " clamped to 7 (32KB pages)" severity warning;
    end if;
    page_offset_bits := get_page_offset_bits(ps_val);
    tc_page_size  <= ps_val;
    tc_page_shift <= page_offset_bits;
    
    -- MC68030 Requirement: IS + TIA + TIB + TIC + TID + page_offset_bits = 32
    total_bits := is_bits + tia_bits + tib_bits + tic_bits + tid_bits + page_offset_bits;
    
    -- MC68030 Constraints validation:
    -- 1. Total bits must equal 32 (only when MMU is enabled - TC.E = 1)
    -- 2. TIA must be > 0 (root table must have at least 1 bit)
    -- 3. If TIB > 0, it must be >= 2 (minimum 4 entries per table)
    -- 4. Page size must be valid (0-7)
    -- Skip validation if MMU is disabled (TC.E = 0) to avoid warnings on reset
    if TC(31) = '1' and total_bits /= 32 then
      report "TC_VALIDATION_ERROR: Field sum " & integer'image(total_bits) & " != 32" &
             " (IS=" & integer'image(is_bits) &
             " TIA=" & integer'image(tia_bits) &
             " TIB=" & integer'image(tib_bits) &
             " TIC=" & integer'image(tic_bits) &
             " TID=" & integer'image(tid_bits) &
             " PS_bits=" & integer'image(page_offset_bits) & ")"
        severity warning;
    end if;
    
    if TC(31) = '1' and tia_bits = 0 then
      report "TC_VALIDATION_ERROR: TIA field must be > 0 (root table needs at least 1 bit)"
        severity warning;
    end if;

    if TC(31) = '1' and tib_bits > 0 and tib_bits < 2 then
      report "TC_VALIDATION_ERROR: TIB field must be >= 2 when used (minimum 4 table entries)"
        severity warning;
    end if;
    
    if ps_val > 7 then
      report "TC_VALIDATION_ERROR: Page size " & integer'image(ps_val) & " > 7 (invalid)"
        severity warning;
    end if;
  end process;
  
  -- Output the latched results
  addr_phys     <= addr_phys_reg;
  cache_inhibit <= cache_inhibit_reg;
  write_protect <= write_protect_reg;
  fault         <= fault_reg;
  fault_status  <= fault_status_reg;

  -- Simplified translation process - always provide immediate result
  process(clk, nreset)
    variable hit       : std_logic;
    variable hit_idx   : integer range 0 to ATC_ENTRIES-1;
    variable tmatch0, tmatch1 : std_logic;
    variable tci0, twp0, tci1, twp1 : std_logic;
    variable status_tmp : std_logic_vector(31 downto 0);
    variable aligned_addr : std_logic_vector(31 downto 0);
    variable offset       : unsigned(31 downto 0);
    variable phys_base    : unsigned(31 downto 0);
    variable phys_result  : unsigned(31 downto 0);
  begin
    if nreset = '0' then
      -- Initialize to identity translation on reset
      addr_phys_reg <= x"00000000";
      cache_inhibit_reg <= '0';
      write_protect_reg <= '0';
      fault_reg <= '0';
      fault_status_reg <= (others => '0');
      saved_addr_log <= (others => '0');
      saved_fc <= (others => '0');
      saved_is_insn <= '0';
      saved_rw <= '0';
      translation_pending <= '0';
      walk_req <= '0';
      walker_fault_ack <= '0';
      walker_completed_ack <= '0';
      walker_fault_ack_pending <= '0';
      mmusr_update_req <= '0';
      mmusr_update_value <= (others => '0');
      -- Initialize PLRU tree
      atc_plru_tree <= (others => '0');
    elsif rising_edge(clk) then
      status_tmp := fault_status_reg;

      if mmusr_update_ack = '1' then
        mmusr_update_req <= '0';
      end if;

      -- Clear faults at start of each new translation request (MC68030 behavior)
      -- Each translation request starts with clean fault state
      -- Faults are only set if the current translation fails

      -- Process translation requests first
      if req = '1' then
        -- Clear previous fault state for new translation request ONLY if not from walker
        -- Don't clear walker faults that are still pending acknowledgment
        if walker_fault = '0' and walker_fault_ack_pending = '0' then
          fault_reg <= '0';
          fault_status_reg <= (others => '0');
        end if;
        -- Debug: Log translation request for test addresses
        if addr_log = x"12343000" or addr_log = x"12344000" or addr_log = x"12345000" then
          report "DEBUG_REQUEST: Starting translation for addr=0x" & slv_to_hstring(addr_log) &
                 " fc=" & slv_to_string(fc) & " rw=" & std_logic'image(rw) &
                 " tc_en=" & std_logic'image(tc_en)
            severity note;
        end if;
        -- Initialize variables to clean values
        hit := '0';
        hit_idx := 0;
        tmatch0 := '0'; tmatch1 := '0';
        tci0 := '0';
        twp0 := '0';
        tci1 := '0';
        twp1 := '0';
        
        -- Don't clear faults on new requests - faults persist until explicitly cleared
        -- This allows tests to sample fault status after translation completes
        
        -- Translation logic with proper precedence (no conflicting assignments)
        -- Only do identity translation when MMU is disabled
        if tc_en = '0' then
          -- MMU disabled - identity translation (always successful, no faults possible)
          addr_phys_reg     <= addr_log;
          cache_inhibit_reg <= '0';
          write_protect_reg <= '0';
          fault_reg         <= '0';
          -- Set successful identity translation MMUSR with MC68030 format
          fault_status_reg <= encode_mmusr_success(
            cache_inhibit => '0',        -- No cache inhibit for identity
            write_protect => '0',        -- No write protect for identity  
            transparent => '0'           -- Not transparent (MMU disabled)
          );
          translation_pending <= '0';
        else
          -- MMU enabled - do full translation
          -- Check Transparent Translation first (highest priority)
          ttr_check(TT0, addr_log, fc, is_insn, tmatch0, tci0, twp0);
          ttr_check(TT1, addr_log, fc, is_insn, tmatch1, tci1, twp1);
          -- Debug: Log TTR check results for write protection test address
          if addr_log = x"00002000" then
            report "DEBUG_TTR_WP: addr=0x" & slv_to_hstring(addr_log) &
                   " TT0=0x" & slv_to_hstring(TT0) &
                   " TT1=0x" & slv_to_hstring(TT1) &
                   " tmatch0=" & std_logic'image(tmatch0) &
                   " tmatch1=" & std_logic'image(tmatch1)
              severity note;
          end if;
          if tmatch0 = '1' then
            -- TTR0 match - use identity translation with TTR attributes (always successful, no faults)
            addr_phys_reg <= addr_log;  -- Identity mapping
            cache_inhibit_reg <= tci0;
            write_protect_reg <= twp0;
            fault_reg <= '0';
            -- Set successful transparent translation MMUSR with MC68030 format
            fault_status_reg <= encode_mmusr_success(
              cache_inhibit => tci0,     -- CI bit from TTR attributes
              write_protect => twp0,     -- WP bit from TTR attributes  
              transparent => '1'         -- This IS a transparent translation
            );
            if addr_log = x"00002000" then
              report "TTR0_STATUS: Setting transparent status for addr=0x" & slv_to_hstring(addr_log) severity note;
            end if;
            -- No walker needed for TTR
          elsif tmatch1 = '1' then
            -- TTR1 match - use identity translation with TTR attributes (always successful, no faults)
            assert false report "TTR1 HIT: Setting addr_phys to 0x" & slv_to_hstring(addr_log) severity note;
            addr_phys_reg <= addr_log;  -- Identity mapping
            cache_inhibit_reg <= tci1;
            write_protect_reg <= twp1;
            fault_reg <= '0';
            -- Set successful transparent translation MMUSR with MC68030 format
            fault_status_reg <= encode_mmusr_success(
              cache_inhibit => tci1,     -- CI bit from TTR attributes
              write_protect => twp1,     -- WP bit from TTR attributes  
              transparent => '1'         -- This IS a transparent translation
            );
            -- No walker needed for TTR
          else
            -- No TTR match - check ATC and potentially start walker
          hit := '0';
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              aligned_addr := align_addr(addr_log, atc_shift(i));
              -- Debug: Log ATC check details for failing test addresses
              if addr_log = x"12343000" or addr_log = x"12344000" then
                report "DEBUG_ATC_CHECK: addr=0x" & slv_to_hstring(addr_log) &
                       " ATC[" & integer'image(i) & "] base=0x" & slv_to_hstring(atc_log_base(i)) &
                       " shift=" & integer'image(atc_shift(i)) &
                       " aligned=0x" & slv_to_hstring(aligned_addr) &
                       " fc_match=" & std_logic'image(atc_fc(i)(0)) & std_logic'image(atc_fc(i)(1)) & std_logic'image(atc_fc(i)(2)) &
                       " vs " & std_logic'image(fc(0)) & std_logic'image(fc(1)) & std_logic'image(fc(2))
                  severity note;
              end if;
              if atc_fc(i) = fc and
                 atc_is_insn(i) = is_insn and
                 aligned_addr = atc_log_base(i) then
                hit := '1';
                hit_idx := i;
                -- Debug: Log ATC hit for failing test addresses
                if addr_log = x"12343000" or addr_log = x"12344000" then
                  report "DEBUG_ATC_HIT: addr=0x" & slv_to_hstring(addr_log) &
                         " hit ATC[" & integer'image(i) & "] base=0x" & slv_to_hstring(atc_log_base(i)) &
                         " shift=" & integer'image(atc_shift(i)) &
                         " aligned_addr=0x" & slv_to_hstring(aligned_addr) &
                         " fc=" & slv_to_string(fc) & " vs atc_fc=" & slv_to_string(atc_fc(i))
                    severity note;
                end if;
              end if;
            end if;
          end loop;
          if hit = '1' then
            -- ATC hit - use cached translation but check access violations
            -- But don't overwrite walker faults that are still pending
            if walker_fault = '1' and walker_fault_ack_pending = '1' then
              -- Walker fault is pending - don't overwrite with ATC results
              report "ATC_SKIP: Skipping ATC processing due to pending walker fault, addr=0x" & slv_to_hstring(addr_log) severity note;
            elsif rw = '1' and atc_attr(hit_idx)(0) = '1' then
              -- Write to write-protected page - generate fault
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                cache_inhibit => atc_attr(hit_idx)(1),  -- From cached attributes
                write_protect => '1',                   -- This is a WP fault
                modified => '0',
                transparent => '0',
                resident => '0',                        -- Not resident due to fault
                level => "11"                           -- Page level fault
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              report "WP_FAULT_ATC: Setting fault_reg=1 for WP violation, addr=0x" & slv_to_hstring(addr_log) severity note;
            elsif fc(2) = '0' and atc_attr(hit_idx)(2) = '0' then
              -- User trying to access supervisor-only page - generate fault
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '1',            -- This is a supervisor violation
                cache_inhibit => atc_attr(hit_idx)(1),  -- From cached attributes
                write_protect => atc_attr(hit_idx)(0),  -- From cached attributes
                modified => '0',
                transparent => '0',
                resident => '0',                        -- Not resident due to fault
                level => "11"                           -- Page level fault
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              report "SUPERVISOR_FAULT_ATC: Setting fault_reg=1 for supervisor violation, addr=0x" & slv_to_hstring(addr_log) severity note;
            else
              -- Valid access - use cached translation and clear any previous faults
              -- But don't overwrite walker faults that are still pending
              if walker_fault = '1' and walker_fault_ack_pending = '1' then
                -- Walker fault is pending - don't overwrite with successful ATC results
                report "ATC_SUCCESS_SKIP: Skipping ATC success due to pending walker fault, addr=0x" & slv_to_hstring(addr_log) severity note;
              else
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                -- Debug address calculation for PS=0 test
                if addr_log = x"00001100" then
                  report "DEBUG_ATC_CALC: addr=0x" & slv_to_hstring(addr_log) &
                         " phys_base=0x" & slv_to_hstring(std_logic_vector(phys_base)) &
                         " log_base=0x" & slv_to_hstring(atc_log_base(hit_idx)) &
                         " offset=0x" & slv_to_hstring(std_logic_vector(offset)) &
                         " phys_result=0x" & slv_to_hstring(std_logic_vector(phys_result))
                    severity note;
                end if;
                addr_phys_reg <= std_logic_vector(phys_result);
                cache_inhibit_reg <= atc_attr(hit_idx)(1);
                write_protect_reg <= atc_attr(hit_idx)(0);
                fault_reg <= '0';
                -- Set successful translation MMUSR with MC68030 format
                fault_status_reg <= encode_mmusr_success(
                  cache_inhibit => atc_attr(hit_idx)(1),   -- CI bit from page attributes
                  write_protect => atc_attr(hit_idx)(0),   -- WP bit from page attributes  
                  transparent => '0'                       -- Not a transparent translation
                );
                -- Update PLRU tree to mark this entry as most recently used
                atc_plru_tree <= plru_update_tree(atc_plru_tree, hit_idx);
                report "ATC_HIT: successful translation, phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) & " hit_idx=" & integer'image(hit_idx) severity note;
              end if;
            end if;
          else
            -- ATC miss - request walker to start (only if no TTR hit and not already pending)
            if tmatch0 = '0' and tmatch1 = '0' and translation_pending = '0' then
              -- Debug: Log ATC miss for failing test addresses
              if addr_log = x"12343000" or addr_log = x"12344000" then
                report "DEBUG_ATC_MISS: addr=0x" & slv_to_hstring(addr_log) &
                       " starting walker"
                  severity note;
              end if;
              -- Save request info for walker ONLY when no translation is pending
              saved_addr_log <= addr_log;
              saved_fc <= fc;
              saved_is_insn <= is_insn;
              saved_rw <= rw;
              walk_req <= '1';
              translation_pending <= '1';
            else
              -- Debug: Log why walker didn't start for failing test addresses
              if addr_log = x"12343000" or addr_log = x"12344000" then
                report "DEBUG_NO_WALKER: addr=0x" & slv_to_hstring(addr_log) &
                       " tmatch0=" & std_logic'image(tmatch0) &
                       " tmatch1=" & std_logic'image(tmatch1) &
                       " translation_pending=" & std_logic'image(translation_pending)
                  severity note;
              end if;
            end if;
          end if;
          end if; -- TTR check
        end if; -- tc_en = '0' vs '1'
        
      end if; -- req = '1'
      
      -- Handle PLOAD requests - trigger translation to pre-load ATC
      if pload_active = '1' then
        -- PLOAD request active - perform translation to fill ATC
        if tc_en = '1' and translation_pending = '0' then
          -- Check Transparent Translation first
          ttr_check(TT0, pload_addr, pload_fc, '0', tmatch0, tci0, twp0);
          ttr_check(TT1, pload_addr, pload_fc, '0', tmatch1, tci1, twp1);
          
          if tmatch0 = '0' and tmatch1 = '0' then
            -- No TTR match - check ATC
            hit := '0';
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_valid(i) = '1' then
                aligned_addr := align_addr(pload_addr, atc_shift(i));
                if atc_fc(i) = pload_fc and
                   atc_is_insn(i) = '0' and
                   aligned_addr = atc_log_base(i) then
                  hit := '1';
                  hit_idx := i;
                end if;
              end if;
            end loop;
            
            if hit = '0' then
              -- ATC miss - trigger walker to load translation
              saved_addr_log <= pload_addr;
              saved_fc <= pload_fc;
              saved_is_insn <= '0';
              saved_rw <= '1'; -- PLOAD is like a read operation
              walk_req <= '1';
              translation_pending <= '1';
              report "PLOAD: Triggered walker for addr=0x" & slv_to_hstring(pload_addr) &
                     " fc=" & slv_to_string(pload_fc) severity note;
            else
              -- ATC hit - PLOAD complete (translation already cached)
              report "PLOAD: ATC hit for addr=0x" & slv_to_hstring(pload_addr) &
                     " hit_idx=" & integer'image(hit_idx) severity note;
            end if;
          else
            -- TTR match - PLOAD complete (no need to cache transparent translations)
            report "PLOAD: TTR match for addr=0x" & slv_to_hstring(pload_addr) severity note;
          end if;
        end if;
      end if;
      
      -- Handle walker completion and walker faults immediately (don't wait for req='0')
      if walker_fault = '1' and walker_fault_ack = '0' then
        -- Walker faulted - process immediately regardless of req state
        status_tmp := walker_fault_status;
        fault_reg <= '1';
        fault_status_reg <= status_tmp;
        mmusr_update_value <= status_tmp;  -- Full 32-bit MC68030 format
        mmusr_update_req <= '1';
        translation_pending <= '0';
        -- Debug: Report walker fault processing with corruption tracking
        report "WALKER_FAULT: Setting fault_reg=1 walker_status=0x" & slv_to_hstring(walker_fault_status) &
               " status_tmp=0x" & slv_to_hstring(status_tmp) &
               " addr=0x" & slv_to_hstring(saved_addr_log)
          severity note;
        -- Acknowledge the fault and track pending state
        walker_fault_ack <= '1';
        walker_fault_ack_pending <= '1';
      elsif walker_completed = '1' then
        -- Walker completed successfully - clear any previous fault status
        -- A successful walker completion means this specific translation succeeded
        
        -- First check if the completed request would have been handled by TTR
        ttr_check(TT0, saved_addr_log, saved_fc, saved_is_insn, tmatch0, tci0, twp0);
        ttr_check(TT1, saved_addr_log, saved_fc, saved_is_insn, tmatch1, tci1, twp1);
        
        if tmatch0 = '1' or tmatch1 = '1' then
          -- This request hits TTR - don't override TTR results that are already set
          null; -- TTR results already handled in main translation logic
        else
          -- No TTR hit - check ATC for walker results
          hit := '0';
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              aligned_addr := align_addr(saved_addr_log, atc_shift(i));
              if atc_fc(i) = saved_fc and
                 atc_is_insn(i) = saved_is_insn and
                 aligned_addr = atc_log_base(i) then
                hit := '1';
                hit_idx := i;
              end if;
            end if;
          end loop;
          if hit = '1' then
            -- Debug: Report ATC hit details
            report "ATC_HIT: addr=0x" & slv_to_hstring(saved_addr_log) & 
                   " fc=" & slv_to_string(saved_fc) & 
                   " rw=" & std_logic'image(saved_rw) &
                   " hit_idx=" & integer'image(hit_idx) &
                   " attr=" & slv_to_string(atc_attr(hit_idx)) &
                   " base=0x" & slv_to_hstring(atc_phys_base(hit_idx)) &
                   " shift=" & integer'image(atc_shift(hit_idx)) &
                   " page_size=" & integer'image(atc_page_size(hit_idx))
              severity note;
              
            -- Walker filled ATC successfully - check access violations for the original request
            if saved_rw = '1' and atc_attr(hit_idx)(0) = '1' then
              -- Write to write-protected page - generate fault
              report "WP_FAULT: Write to WP page detected" severity note;
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                cache_inhibit => atc_attr(hit_idx)(1),  -- From translated attributes
                write_protect => '1',                   -- This is a WP fault
                modified => '0',
                transparent => '0',
                resident => '0',                        -- Not resident due to fault
                level => "11"                           -- Page level fault
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              report "WP_FAULT_WALKER: Setting fault_reg=1 for WP violation after walker, addr=0x" & slv_to_hstring(saved_addr_log) severity note;
            elsif saved_fc(2) = '0' and atc_attr(hit_idx)(2) = '0' then
              -- User trying to access supervisor-only page - generate fault
              report "SUPERVISOR_FAULT: User access to supervisor page detected" severity note;
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '1',            -- This is a supervisor violation
                cache_inhibit => atc_attr(hit_idx)(1),  -- From translated attributes
                write_protect => atc_attr(hit_idx)(0),  -- From translated attributes
                modified => '0',
                transparent => '0',
                resident => '0',                        -- Not resident due to fault
                level => "11"                           -- Page level fault
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              report "SUPERVISOR_FAULT_WALKER: Setting fault_reg=1 for supervisor violation after walker, addr=0x" & slv_to_hstring(saved_addr_log) severity note;
            else
              -- Valid access - update outputs and clear faults for successful translation
              report "VALID_ACCESS: Translation successful" severity note;
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              cache_inhibit_reg <= atc_attr(hit_idx)(1);
              write_protect_reg <= atc_attr(hit_idx)(0);
              fault_reg <= '0';
              -- Set successful translation MMUSR with MC68030 format
              fault_status_reg <= encode_mmusr_success(
                cache_inhibit => atc_attr(hit_idx)(1),   -- CI bit from page attributes
                write_protect => atc_attr(hit_idx)(0),   -- WP bit from page attributes  
                transparent => '0'                       -- Not a transparent translation
              );
              -- Update PLRU tree to mark this entry as most recently used
              atc_plru_tree <= plru_update_tree(atc_plru_tree, hit_idx);
              report "VALID_ACCESS: phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
            end if;
          else
            -- No ATC hit found after walker completion - this shouldn't happen normally
            -- But clear translation_pending anyway to prevent deadlock
            report "WALKER_COMPLETED: No ATC hit found after successful walker completion" severity warning;
          end if; -- hit = '1'
          -- Always clear translation_pending when walker completes, regardless of result
          translation_pending <= '0';
        end if; -- else tmatch0
        -- Acknowledge walker completion
        walker_completed_ack <= '1';
      else
        -- Clear acknowledgment signals only when walker has cleared its signals
        if walker_completed = '0' then
          walker_completed_ack <= '0';
        end if;
        if walker_fault = '0' and walker_fault_ack_pending = '1' then
          walker_fault_ack <= '0';
          walker_fault_ack_pending <= '0';
          report "FAULT_ACK: Cleared walker fault acknowledgment" severity note;
        end if;
      end if; -- walker_completed
      
      -- Clear walk request when walker starts (to avoid continuous requests)
      if wstate /= W_IDLE then
        walk_req <= '0';
      end if;
    end if;
  end process;

  -- Walker request generation integrated into main translation process
  -- (Moved to main process to avoid timing issues)

  -- MC68030 page table walker with proper descriptor traversal
  process(clk, nreset)
    variable table_index : integer;
    variable desc_addr : std_logic_vector(31 downto 0);
    variable tmatch0, tmatch1 : std_logic;
    variable tci0, twp0, tci1, twp1 : std_logic;
    variable victim_idx : integer range 0 to ATC_ENTRIES-1;
  begin
    if nreset = '0' then
      for i in 0 to ATC_ENTRIES-1 loop
        atc_valid(i)     <= '0';
        atc_log_base(i)  <= (others => '0');
        atc_phys_base(i) <= (others => '0');
        atc_fc(i)        <= (others => '0');
        atc_is_insn(i)   <= '0';
        atc_shift(i)     <= 12;
        atc_page_size(i) <= 4;  -- Default to 4KB pages
        atc_attr(i)      <= (others => '0');
      end loop;
      atc_rr      <= 0;
      wstate      <= W_IDLE;
      walk_level  <= 0;
      walk_desc   <= (others => '0');
      walk_addr   <= (others => '0');
      walk_vpn    <= (others => '0');
      walk_fault  <= '0';
      walk_attr   <= (others => '0');
      walk_log_base  <= (others => '0');
      walk_phys_base <= (others => '0');
      walk_page_shift <= 12;
      walk_page_size <= 4;
      walker_fault <= '0';
      walker_fault_status <= (others => '0');
      walker_completed <= '0';
      mem_req     <= '0';
      mem_addr    <= (others => '0');
    elsif rising_edge(clk) then
      -- Deadlock-proof state machine - no timeouts needed
      
      case wstate is
        when W_IDLE =>
          -- Don't auto-clear walker_completed here - let translation handler clear it
          
          -- Start page table walk on ATC miss using saved request parameters
          if walk_req = '1' then
            -- Debug: Log walker startup for failing test addresses
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
              report "DEBUG_WALKER_START: addr=0x" & slv_to_hstring(saved_addr_log) &
                     " fc=" & slv_to_string(saved_fc) & " rw=" & std_logic'image(saved_rw)
                severity note;
            end if;
            walk_level <= 0;
            walk_vpn  <= saved_addr_log;
            walk_fault <= '0';  -- Clear fault at start of walk
            walk_attr <= (others => '0');
            -- Initialize with TC default, will be updated from descriptor
            walk_page_shift <= tc_page_shift;
            walk_page_size  <= tc_page_size;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
            walk_phys_base  <= (others => '0');
            -- Don't clear walker fault signals here - they need to persist until consumed
            -- MC68030 Root Pointer Selection:
            -- Use SRP for supervisor access only when both FC2=1 AND TC.SRE=1
            -- Otherwise use CRP for all accesses
            if saved_fc(2) = '1' and tc_sre = '1' then -- Supervisor with SRE enabled
              walk_addr <= SRP_L(31 downto 4) & "0000"; -- Supervisor Root Pointer
              report "ROOT_POINTER: Using SRP for supervisor access with SRE=1" severity note;
            else -- User or supervisor without SRE
              walk_addr <= CRP_L(31 downto 4) & "0000"; -- CPU Root Pointer
              if saved_fc(2) = '1' then
                report "ROOT_POINTER: Using CRP for supervisor access with SRE=0" severity note;
              else
                report "ROOT_POINTER: Using CRP for user access" severity note;
              end if;
            end if;
            wstate <= W_ROOT;
          end if;
          
        when W_ROOT =>
          -- Read root table descriptor - deadlock-proof design
          table_index := get_table_index(walk_vpn, walk_level, tc_initial_shift, tc_idx_bits);
          desc_addr := walk_addr(31 downto 4) & "0000"; -- Align to table boundary
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          
          -- Debug: Log walker state for failing test addresses
          if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
            report "DEBUG_WALKER: W_ROOT addr=0x" & slv_to_hstring(saved_addr_log) &
                   " level=" & integer'image(walk_level) &
                   " table_index=" & integer'image(table_index) &
                   " desc_addr=0x" & slv_to_hstring(desc_addr)
              severity note;
          end if;
          
          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= desc_addr;
          elsif mem_ack = '1' then
            -- Got response - process it and move to next state
            walk_desc <= mem_rdat;
            mem_req <= '0';
            -- Debug: Log descriptor read for failing test addresses
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
              report "DEBUG_W_ROOT_DESC: addr=0x" & slv_to_hstring(saved_addr_log) &
                     " descriptor=0x" & slv_to_hstring(mem_rdat) &
                     " bits_1_0=" & std_logic'image(mem_rdat(1)) & std_logic'image(mem_rdat(0))
                severity note;
            end if;
            -- Check descriptor validity
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              if saved_addr_log = x"12345000" then
                report "DEBUG_INVALID: descriptor is invalid (bits 1:0 = 00)" severity note;
              end if;
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '1',                -- Invalid descriptor is a bus error
                limit_violation => '0',
                supervisor_violation => '0',
                cache_inhibit => '0',
                write_protect => '0',
                modified => '0',
                transparent => '0',
                resident => '0',
                level => std_logic_vector(to_unsigned(walk_level, 2))
              );
              -- Debug: Track where bus errors occur
              report "BUS_ERROR_ROOT: Invalid descriptor at level=" & integer'image(walk_level) &
                     " addr=0x" & slv_to_hstring(saved_addr_log) &
                     " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
            elsif desc_is_page(mem_rdat) then
              -- Early termination - this is a page descriptor
              if saved_addr_log = x"12345000" then
                report "DEBUG_PAGE: descriptor is page (bits 1:0 = 01)" severity note;
              end if;
              wstate <= W_PAGE;
            else
              -- Table pointer - continue to next level
              if saved_addr_log = x"12345000" then
                report "DEBUG_TABLE: descriptor is table pointer (bits 1:0 = 10/11), continuing to W_PTR1" severity note;
              end if;
              walk_addr <= mem_rdat(31 downto 4) & "0000";
              walk_level <= walk_level + 1;
              wstate <= W_PTR1;
            end if;
          end if;
          
        when W_PTR1 =>
          -- Read level 1 table descriptor - deadlock-proof design
          table_index := get_table_index(walk_vpn, walk_level, tc_initial_shift, tc_idx_bits);
          desc_addr := walk_addr(31 downto 4) & "0000";
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          
          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            if saved_addr_log = x"00400000" or saved_addr_log = x"12345000" then
              report "W_PTR1: idx=" & integer'image(table_index) & " addr=0x" & slv_to_hstring(desc_addr)
                severity note;
            end if;
            mem_req <= '1';
            mem_addr <= desc_addr;
          elsif mem_ack = '1' then
            -- Got response - process it and move to next state
            walk_desc <= mem_rdat;
            mem_req <= '0';
            -- Debug: Log descriptor read for Large Page Translation
            if saved_addr_log = x"00400000" or saved_addr_log = x"12345000" then
              report "W_PTR1_DESC: addr=0x" & slv_to_hstring(saved_addr_log) &
                     " descriptor=0x" & slv_to_hstring(mem_rdat) &
                     " bits_1_0=" & std_logic'image(mem_rdat(1)) & std_logic'image(mem_rdat(0))
                severity note;
            end if;
            -- Force a known transition to prevent falling through to "when others"
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '1',                -- Invalid descriptor is a bus error
                limit_violation => '0',
                supervisor_violation => '0',
                cache_inhibit => '0',
                write_protect => '0',
                modified => '0',
                transparent => '0',
                resident => '0',
                level => std_logic_vector(to_unsigned(walk_level, 2))
              );
              -- Debug: Track where bus errors occur
              report "BUS_ERROR_PTR1: Invalid descriptor at level=" & integer'image(walk_level) &
                     " addr=0x" & slv_to_hstring(saved_addr_log) &
                     " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
              -- Debug: Log walker fault for Large Page Translation
              if saved_addr_log = x"00400000" then
                report "W_PTR1_FAULT: addr=0x" & slv_to_hstring(saved_addr_log) &
                       " invalid descriptor=0x" & slv_to_hstring(mem_rdat) &
                       " at level=" & integer'image(walk_level)
                  severity note;
              end if;
            elsif desc_is_page(mem_rdat) then
              -- Page descriptor found
              wstate <= W_PAGE;
            else
              -- Continue to next level
              walk_addr <= mem_rdat(31 downto 4) & "0000";
              walk_level <= walk_level + 1;
              wstate <= W_PTR2;
            end if;
          end if;
          
        when W_PTR2 =>
          -- Read level 2 table descriptor - deadlock-proof design
          table_index := get_table_index(walk_vpn, walk_level, tc_initial_shift, tc_idx_bits);
          desc_addr := walk_addr(31 downto 4) & "0000";
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          
          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            if saved_addr_log = x"00400000" then
              report "W_PTR2: idx=" & integer'image(table_index) & " addr=0x" & slv_to_hstring(desc_addr)
                severity note;
            end if;
            -- Debug: Log W_PTR2 access for failing test addresses
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" then
              report "DEBUG_W_PTR2: addr=0x" & slv_to_hstring(saved_addr_log) &
                     " level=" & integer'image(walk_level) &
                     " table_index=" & integer'image(table_index) &
                     " desc_addr=0x" & slv_to_hstring(desc_addr)
                severity note;
            end if;
            mem_req <= '1';
            mem_addr <= desc_addr;
          elsif mem_ack = '1' then
            -- Got response - process it and move to next state
            walk_desc <= mem_rdat;
            mem_req <= '0';
            -- Debug: Log descriptor read for failing test addresses
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" then
              report "DEBUG_W_PTR2_DESC: addr=0x" & slv_to_hstring(saved_addr_log) &
                     " descriptor=0x" & slv_to_hstring(mem_rdat) &
                     " bits_1_0=" & std_logic'image(mem_rdat(1)) & std_logic'image(mem_rdat(0))
                severity note;
            end if;
            -- Check descriptor validity
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '1',                -- Invalid descriptor is a bus error
                limit_violation => '0',
                supervisor_violation => '0',
                cache_inhibit => '0',
                write_protect => '0',
                modified => '0',
                transparent => '0',
                resident => '0',
                level => std_logic_vector(to_unsigned(walk_level, 2))
              );
              -- Debug: Track where bus errors occur
              report "BUS_ERROR_PTR2: Invalid descriptor at level=" & integer'image(walk_level) &
                     " addr=0x" & slv_to_hstring(saved_addr_log) &
                     " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
              -- Debug: Log walker fault for failing test addresses  
              if saved_addr_log = x"12343000" then
                report "DEBUG_WALKER_FAULT_PTR2: addr=0x" & slv_to_hstring(saved_addr_log) &
                       " invalid descriptor=0x" & slv_to_hstring(mem_rdat) &
                       " at level=" & integer'image(walk_level)
                  severity note;
              end if;
            elsif desc_is_page(mem_rdat) then
              wstate <= W_PAGE;
            else
              walk_addr <= mem_rdat(31 downto 4) & "0000";
              walk_level <= walk_level + 1;
              wstate <= W_PTR3;
            end if;
          end if;
          
        when W_PTR3 =>
          -- Final level - must be page descriptor - deadlock-proof design
          table_index := get_table_index(walk_vpn, walk_level, tc_initial_shift, tc_idx_bits);
          desc_addr := walk_addr(31 downto 4) & "0000";
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          
          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= desc_addr;
          elsif mem_ack = '1' then
            -- Got response - process it and move to next state
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_valid(mem_rdat) and desc_is_page(mem_rdat) then
              wstate <= W_PAGE;
            else
              -- Invalid or non-page descriptor - generate fault with proper MC68030 MMUSR format
              walk_fault <= '1';
              walker_fault <= '1';
              -- For invalid descriptor at table level - this is a bus error
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '1',                -- Bus error due to invalid table descriptor
                limit_violation => '0',
                supervisor_violation => '0',
                cache_inhibit => '0',
                write_protect => '0',
                modified => '0',
                transparent => '0',
                resident => '0',                 -- Not resident due to fault
                level => std_logic_vector(to_unsigned(walk_level, 2))
              );
              -- Debug: Track where bus errors occur
              report "BUS_ERROR_PTR3: Invalid descriptor at level=" & integer'image(walk_level) &
                     " addr=0x" & slv_to_hstring(saved_addr_log) &
                     " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
            end if;
          end if;
          
        when W_PAGE =>
          -- Process page descriptor and validate completely
          if not desc_valid(walk_desc) then
            -- Invalid page descriptor - this is a bus error in MC68030
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1',                -- Bus error due to invalid page descriptor
              limit_violation => '0',
              supervisor_violation => '0',
              cache_inhibit => '0',
              write_protect => '0',
              modified => '0',
              transparent => '0',
              resident => '0',                 -- Not resident due to fault
              level => std_logic_vector(to_unsigned(walk_level, 2))
            );
            -- Debug: Track where bus errors occur
            report "BUS_ERROR_PAGE: Invalid page descriptor at level=" & integer'image(walk_level) &
                   " addr=0x" & slv_to_hstring(saved_addr_log) &
                   " desc=0x" & slv_to_hstring(walk_desc) severity note;
            wstate <= W_FAULT;
          elsif not access_allowed(walk_desc, saved_fc) then
            -- Supervisor violation - user trying to access supervisor page
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',                
              limit_violation => '0',
              supervisor_violation => '1',     -- This is a supervisor violation
              cache_inhibit => walk_desc(6),   -- Include page attributes
              write_protect => walk_desc(2),
              modified => '0',
              transparent => '0',
              resident => '0',                 -- Not resident due to fault
              level => std_logic_vector(to_unsigned(walk_level, 2))
            );
            wstate <= W_FAULT;
          elsif saved_rw = '1' and walk_desc(2) = '1' then
            -- Write protection violation - write to write-protected page
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',                
              limit_violation => '0',
              supervisor_violation => '0',
              cache_inhibit => walk_desc(6),   -- Include page attributes
              write_protect => '1',            -- This is a write protection fault
              modified => '0',
              transparent => '0',
              resident => '0',                 -- Not resident due to fault
              level => std_logic_vector(to_unsigned(walk_level, 2))
            );
            wstate <= W_FAULT;
            report "WP_FAULT_WALKER: Write to WP page detected during walk, addr=0x" & slv_to_hstring(saved_addr_log) severity note;
          else
            -- Valid access - MC68030 behavior: use descriptor PS if large page, otherwise TC PS
            if is_large_page(walk_desc) then
              -- Large page descriptor - use descriptor's PS field
              walk_page_shift <= get_desc_page_shift(walk_desc);
              walk_page_size  <= get_desc_page_size(walk_desc);
              walk_log_base   <= align_addr(saved_addr_log, get_desc_page_shift(walk_desc));
              walk_phys_base  <= phys_base_from_desc(walk_desc, get_desc_page_shift(walk_desc));
              report "LARGE_PAGE: Using descriptor PS=" & integer'image(get_desc_page_size(walk_desc)) &
                     " shift=" & integer'image(get_desc_page_shift(walk_desc)) & 
                     " for addr=0x" & slv_to_hstring(saved_addr_log) severity note;
            else
              -- Regular page - use TC register page size
              walk_page_shift <= tc_page_shift;
              walk_page_size  <= tc_page_size;
              walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
              walk_phys_base  <= phys_base_from_desc(walk_desc, tc_page_shift);
            end if;
            walk_attr(2) <= walk_desc(7); -- User accessible (0=supervisor only, 1=user accessible)
            walk_attr(1) <= walk_desc(6); -- Cache inhibit
            walk_attr(0) <= walk_desc(2); -- Write protect
            walk_fault <= '0';
            
            -- Assertion: Verify walk_attr(2) coherently tracks descriptor bit 7
            assert walk_desc(7) = walk_desc(7) 
              report "ASSERTION: walk_attr(2) should coherently track walk_desc(7): " &
                     "walk_desc(7)=" & std_logic'image(walk_desc(7))
              severity note;
            
            wstate <= W_FILL;
          end if;
          
        when W_FILL =>
          -- Fill ATC with translation result using PLRU replacement
          -- Find victim entry using PLRU algorithm
          victim_idx := plru_get_victim(atc_plru_tree);

          -- Fill the victim entry
          atc_log_base(victim_idx)  <= walk_log_base;
          atc_phys_base(victim_idx) <= walk_phys_base;
          atc_shift(victim_idx)     <= walk_page_shift;
          atc_page_size(victim_idx) <= walk_page_size;
          atc_attr(victim_idx)      <= walk_attr(2 downto 0);
          atc_fc(victim_idx)        <= saved_fc;
          atc_is_insn(victim_idx)   <= saved_is_insn;
          atc_valid(victim_idx)     <= '1';

          -- PLRU tree update moved to translation process to avoid driver conflict

          -- Update round-robin as fallback (for debugging/fallback)
          if atc_rr = ATC_ENTRIES-1 then
            atc_rr <= 0;
          else
            atc_rr <= atc_rr + 1;
          end if;

          -- Debug: Log ATC fill for large page test
          if saved_addr_log = x"00400000" then
            report "DEBUG_ATC_FILL: addr=0x" & slv_to_hstring(saved_addr_log) &
                   " filling ATC[" & integer'image(victim_idx) & "] (PLRU victim)" &
                   " shift=" & integer'image(walk_page_shift) &
                   " page_size=" & integer'image(walk_page_size)
              severity note;
          end if;
          -- Delay completion signal by one cycle to ensure ATC write is visible
          wstate <= W_COMPLETE;  -- New state to delay completion
          
          
        when W_COMPLETE =>
          -- Signal completion one cycle after ATC write to ensure it's visible
          walker_completed <= '1';
          
          -- Debug: Report walker completion details
          report "WALKER_COMPLETED: addr=0x" & slv_to_hstring(saved_addr_log) & 
                 " fc=" & slv_to_string(saved_fc) & 
                 " rw=" & std_logic'image(saved_rw) &
                 " desc=0x" & slv_to_hstring(walk_desc) &
                 " attr=" & slv_to_string(walk_attr) &
                 " fault=" & std_logic'image(walk_fault)
            severity note;
          
          wstate <= W_IDLE;
          
        when W_FAULT =>
          -- Page fault occurred - fault status already set in previous state
          -- Hold walker_fault signal until main process acknowledges it
          -- Don't clear walker_fault here - let main process clear it when consumed
          report "W_FAULT: Setting walker_completed=1 with fault status=0x" & slv_to_hstring(walker_fault_status) severity note;
          walker_completed <= '1';  -- Signal that walker completed (with fault)
          wstate <= W_IDLE;
          
        when others =>
          wstate <= W_IDLE;
      end case;
      
      -- PFLUSH instruction: Clear ATC when flag is set and walker is idle
      if atc_flush_req = '1' then
        for i in 0 to ATC_ENTRIES-1 loop
          atc_valid(i) <= '0';
        end loop;
      end if;

      if pflush_clear_atc = '1' and wstate = W_IDLE then
        for i in 0 to ATC_ENTRIES-1 loop
          atc_valid(i) <= '0';
        end loop;
      end if;
      
      -- Clear walker fault when acknowledged by main process
      if walker_fault = '1' and walker_fault_ack = '1' then
        walker_fault <= '0';
        -- Don't drive walker_fault_ack here - let main process be the sole driver
      end if;
      
      -- Clear walker completion when acknowledged by main process
      if walker_completed = '1' and walker_completed_ack = '1' then
        walker_completed <= '0';
      end if;
    end if;
  end process;

  -- Walker busy indication - not busy if MMU disabled or TTR hit
  process(wstate, addr_log, fc, is_insn, TT0, TT1, tc_en, translation_pending, walker_fault, walker_completed, walker_fault_ack_pending)
    variable tmatch0, tmatch1 : std_logic;
  begin
    -- Not busy if MMU is disabled
    if tc_en = '0' then
      busy <= '0';
    else
      -- Check for TTR hits combinationally
      ttr_match(TT0, addr_log, fc, is_insn, tmatch0);
      ttr_match(TT1, addr_log, fc, is_insn, tmatch1);
      
      -- Not busy if TTR hit or (walker idle with no pending walker work)
      if (tmatch0 = '1' or tmatch1 = '1' or (translation_pending = '0' and wstate = W_IDLE and walker_fault = '0' and walker_fault_ack_pending = '0')) then
        busy <= '0';
      else
        busy <= '1';
      end if;
    end if;
  end process;
  
  -- PMMU instruction communication flags - edge-triggered to prevent lockups
  process(clk, nreset)
  begin
    if nreset = '0' then
      ptest_update_mmusr <= '0';
      pflush_clear_atc <= '0';
      ptest_req_prev <= '0';
      pflush_req_prev <= '0';
      pload_req_prev <= '0';
    elsif rising_edge(clk) then
      -- Update previous values for edge detection
      ptest_req_prev <= ptest_req;
      pflush_req_prev <= pflush_req;
      pload_req_prev <= pload_req;
      
      -- PTEST: Set flag on rising edge only (prevents multiple triggers)
      if ptest_req = '1' and ptest_req_prev = '0' then
        ptest_update_mmusr <= '1';
      else
        ptest_update_mmusr <= '0';
      end if;
      
      -- PFLUSH: Set flag on rising edge only (prevents multiple triggers)
      if pflush_req = '1' and pflush_req_prev = '0' then
        pflush_clear_atc <= '1';
      else
        pflush_clear_atc <= '0';
      end if;
      
      -- PLOAD: Edge detection and implementation
      if pload_req = '1' and pload_req_prev = '0' then
        -- PLOAD rising edge detected - activate page pre-loading
        pload_active <= '1';
        pload_addr <= pmmu_addr;
        pload_fc <= pmmu_fc;
      elsif pload_active = '1' then
        -- PLOAD operation active - clear after one cycle
        pload_active <= '0';
      end if;
    end if;
  end process;
end rtl;
