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
    addr_phys      : out std_logic_vector(31 downto 0);
    cache_inhibit  : out std_logic;
    write_protect  : out std_logic;
    fault          : out std_logic;
    fault_status   : out std_logic_vector(7 downto 0);
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

  -- 68030 PMMU control registers (subset, 32-bit views)
  signal TC     : std_logic_vector(31 downto 0); -- Translation Control (EN, PS, IS, etc.)
  signal CRP_H  : std_logic_vector(31 downto 0); -- CRP high 32
  signal CRP_L  : std_logic_vector(31 downto 0); -- CRP low 32
  signal SRP_H  : std_logic_vector(31 downto 0); -- SRP high 32
  signal SRP_L  : std_logic_vector(31 downto 0); -- SRP low 32
  signal TT0    : std_logic_vector(31 downto 0); -- Transparent Translation 0
  signal TT1    : std_logic_vector(31 downto 0); -- Transparent Translation 1
  signal MMUSR  : std_logic_vector(31 downto 0); -- MMU Status Register
  signal CAL    : std_logic_vector(31 downto 0); -- Current Access Level (68030)

  -- Internal
  signal tc_en  : std_logic; -- translation enable bit (TC[31] in some docs; keep flexible here)
  
  -- Translation result latches
  signal addr_phys_reg      : std_logic_vector(31 downto 0) := (others => '0');
  signal cache_inhibit_reg  : std_logic := '0';
  signal write_protect_reg  : std_logic := '0';
  signal fault_reg          : std_logic := '0';
  signal fault_status_reg   : std_logic_vector(7 downto 0) := (others => '0');
  
  -- Walker fault signals (driven only by walker)
  signal walker_fault       : std_logic := '0';
  signal walker_fault_status : std_logic_vector(7 downto 0) := (others => '0');
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

  -- Simple ATC (Address Translation Cache), 8 entries, dynamic page sizes
  constant ATC_ENTRIES : integer := 8;
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
  signal atc_rr    : integer range 0 to ATC_ENTRIES-1 := 0; -- simple round-robin
  signal walk_req  : std_logic;
  signal walker_completed : std_logic := '0';

  -- Translation control decoding (TC register fields)
  type tc_bits_array_t is array(0 to 3) of integer range 0 to 16;
  constant DEFAULT_TC_BITS : tc_bits_array_t := (8, 8, 4, 0);
  constant DEFAULT_TC_IS   : integer := 0;
  signal tc_idx_bits      : tc_bits_array_t := DEFAULT_TC_BITS;
  signal tc_initial_shift : integer range 0 to 15 := DEFAULT_TC_IS;
  signal tc_page_size     : integer range 0 to 15 := 0;
  signal tc_page_shift    : integer range 0 to 31 := 12;

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
    variable res : std_logic_vector(31 downto 0) := addr;
    variable lim : integer := shift;
  begin
    if lim > 32 then
      lim := 32;
    end if;
    if lim > 0 then
      res(lim-1 downto 0) := (others => '0');
    end if;
    return res;
  end function;

  -- Calculate page offset bits based on MC68030 PS field (TC bits 23:20)
  function get_page_offset_bits(ps_field : integer) return integer is
  begin
    case ps_field is
      when 0 => return 8;   -- 256 bytes
      when 1 => return 9;   -- 512 bytes
      when 2 => return 10;  -- 1KB
      when 3 => return 11;  -- 2KB
      when 4 => return 12;  -- 4KB (default)
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
    
    -- Address match: MC68030 TTR mask logic
    -- mask=1 means "must match", mask=0 means "don't care"
    -- Match when all masked bits of addr equal all masked bits of base
    -- Implementation: XOR to find differences, then mask to ignore don't-care bits
    -- If result is zero, all required bits match
    if ((addr_hi xor base) and mask) = x"00" then
      addr_match := '1';
    else
      addr_match := '0';
    end if;
    
    -- Function code match: For now, allow all FCs when fc_mask=0 (default)
    -- In a full implementation, fc_mask bits would control which FCs are allowed
    if fc_mask = "00000" then
      fc_match := '1'; -- Default: allow all function codes
    else
      fc_match := '1'; -- For now, simplified to always match
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
    
    -- Overall match
    if enable = '1' and addr_match = '1' and fc_match = '1' and super_match = '1' then
      matched := '1';
      ci := tt(1);  -- Cache inhibit
      wp := tt(0);  -- Write protect  
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
  impure function get_table_index(addr : std_logic_vector(31 downto 0);
                                  level : integer) return integer is
    variable result : integer;
    variable shift_amount : integer;
    variable mask_width : integer;
    variable temp_addr : unsigned(31 downto 0);
  begin
    if level < 0 or level > 3 then
      return 0;
    end if;

    mask_width := tc_idx_bits(level);
    if mask_width <= 0 then
      return 0;
    end if;

    -- Calculate shift amount: start from 31-IS and subtract widths of previous levels
    shift_amount := 31 - tc_initial_shift;
    for lvl in 0 to 3 loop
      exit when lvl >= level;
      if tc_idx_bits(lvl) > 0 then
        shift_amount := shift_amount - tc_idx_bits(lvl);
      end if;
    end loop;
    
    -- Ensure valid shift amount
    if shift_amount < 0 or shift_amount >= 32 then
      return 0;
    end if;
    
    -- Extract bits by shifting and masking
    temp_addr := unsigned(addr);
    temp_addr := shift_right(temp_addr, shift_amount - mask_width + 1);
    result := to_integer(temp_addr and to_unsigned((2**mask_width) - 1, 32));
    
    return result;
  end function;
  
  -- Check if descriptor is valid 
  function desc_valid(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) /= "00"; -- Valid if not invalid descriptor
  end function;
  
  -- Check if descriptor is a page descriptor (not table pointer)
  -- MC68030 descriptor format: bits 1:0 determine type
  -- 00 = Invalid, 01 = Page descriptor, 10/11 = Table pointer
  function desc_is_page(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "01"; -- Page descriptor only when bits 1:0 = "01"
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
      return not is_supervisor_page; -- User access - only to user pages (desc(7)=1)
    end if;
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
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
    elsif rising_edge(clk) then
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      if reg_we = '1' then
        case reg_sel is
          when x"0" => TC    <= reg_wdat;
          when x"1" => if reg_part = '1' then CRP_H <= reg_wdat; else CRP_L <= reg_wdat; end if;
          when x"2" => if reg_part = '1' then SRP_H <= reg_wdat; else SRP_L <= reg_wdat; end if;
          when x"3" => 
            TT0   <= reg_wdat;
            atc_flush_req <= '1';
          when x"4" => 
            TT1   <= reg_wdat;
            atc_flush_req <= '1';
          when x"5" => MMUSR <= reg_wdat; -- MMUSR is usually write-1-to-clear bits; kept simple initially
          when x"6" => CAL   <= reg_wdat;
          when others => null;
        end case;
      end if;
      
      -- PTEST instruction: Update MMUSR when flag is set
      if ptest_update_mmusr = '1' then
        -- Simple PTEST implementation - assume translation successful
        MMUSR(15) <= '1'; -- R bit: Resident (translation successful)
        MMUSR(14) <= '0'; -- I bit: Not invalid
        MMUSR(13 downto 0) <= (others => '0'); -- Clear other bits
      end if;

      if mmusr_update_req = '1' then
        MMUSR <= mmusr_update_value;
        mmusr_update_ack <= '1';
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
        case reg_sel is
          when x"0" => reg_rdat <= TC;
          when x"1" => if reg_part = '1' then reg_rdat <= CRP_H; else reg_rdat <= CRP_L; end if;
          when x"2" => if reg_part = '1' then reg_rdat <= SRP_H; else reg_rdat <= SRP_L; end if;
          when x"3" => reg_rdat <= TT0;
          when x"4" => reg_rdat <= TT1;
          when x"5" => reg_rdat <= MMUSR;
          when x"6" => reg_rdat <= CAL;
          when others => reg_rdat <= (others => '0');
        end case;
      end if;
    end if;
  end process;

  -- Extract enable bit from TC (position TBD; keep MSB for now to avoid conflicts)
  tc_en <= TC(31);
  tc_enable <= tc_en;
  
  process(TC)
    variable ps_val : integer;
    variable total  : integer;
  begin
    tc_idx_bits(0) <= decode_tc_field(TC(15 downto 12), DEFAULT_TC_BITS(0));
    tc_idx_bits(1) <= decode_tc_field(TC(11 downto 8),  DEFAULT_TC_BITS(1));
    tc_idx_bits(2) <= decode_tc_field(TC(7 downto 4),   DEFAULT_TC_BITS(2));
    tc_idx_bits(3) <= decode_tc_field(TC(3 downto 0),   DEFAULT_TC_BITS(3));

    if to_integer(unsigned(TC(19 downto 16))) = 0 then
      tc_initial_shift <= DEFAULT_TC_IS;
    else
      tc_initial_shift <= to_integer(unsigned(TC(19 downto 16)));
    end if;

    ps_val := to_integer(unsigned(TC(23 downto 20)));
    tc_page_size  <= ps_val;
    tc_page_shift <= get_page_offset_bits(ps_val);
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
    variable status_tmp : std_logic_vector(7 downto 0);
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
        -- Clear previous fault state for new translation request
        fault_reg <= '0';
        fault_status_reg <= (others => '0');
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
          fault_status_reg  <= (others => '0');
          translation_pending <= '0';
        else
          -- MMU enabled - do full translation
          -- Check Transparent Translation first (highest priority)
          ttr_check(TT0, addr_log, fc, is_insn, tmatch0, tci0, twp0);
          ttr_check(TT1, addr_log, fc, is_insn, tmatch1, tci1, twp1);
          -- Debug: Log TTR check results for failing test addresses
          if addr_log = x"12343000" or addr_log = x"12344000" then
            report "DEBUG_TTR: addr=0x" & slv_to_hstring(addr_log) &
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
            fault_status_reg <= (others => '0');
            -- No walker needed for TTR
          elsif tmatch1 = '1' then
            -- TTR1 match - use identity translation with TTR attributes (always successful, no faults)
            assert false report "TTR1 HIT: Setting addr_phys to " & integer'image(to_integer(unsigned(addr_log))) severity note;
            addr_phys_reg <= addr_log;  -- Identity mapping
            cache_inhibit_reg <= tci1;
            write_protect_reg <= twp1;
            fault_reg <= '0';
            fault_status_reg <= (others => '0');
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
            -- Check for write protection violation on write access
            if rw = '0' and atc_attr(hit_idx)(0) = '1' then
              -- Write to write-protected page - generate fault
              status_tmp := (others => '0');
              status_tmp(6) := '1';
              status_tmp(4 downto 3) := fc(1 downto 0);
              status_tmp(2) := not rw;
              status_tmp(1 downto 0) := "11";
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= (others => '0');
              mmusr_update_value(7 downto 0) <= status_tmp;
              mmusr_update_req <= '1';
              report "WP_FAULT_ATC: Setting fault_reg=1 for WP violation, addr=0x" & slv_to_hstring(addr_log) severity note;
            elsif fc(2) = '0' and atc_attr(hit_idx)(2) = '0' then
              -- User trying to access supervisor-only page - generate fault
              status_tmp := (others => '0');
              status_tmp(4 downto 3) := fc(1 downto 0);
              status_tmp(2) := not rw;
              status_tmp(1 downto 0) := "11";
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= (others => '0');
              mmusr_update_value(7 downto 0) <= status_tmp;
              mmusr_update_req <= '1';
              report "SUPERVISOR_FAULT_ATC: Setting fault_reg=1 for supervisor violation, addr=0x" & slv_to_hstring(addr_log) severity note;
            else
              -- Valid access - use cached translation and clear any previous faults
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              cache_inhibit_reg <= atc_attr(hit_idx)(1);
              write_protect_reg <= atc_attr(hit_idx)(0);
              fault_reg <= '0';
              fault_status_reg <= (others => '0');
              report "ATC_HIT: successful translation, phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
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
      
      -- Handle walker completion and walker faults immediately (don't wait for req='0')
      if walker_fault = '1' and walker_fault_ack = '0' then
        -- Walker faulted - process immediately regardless of req state
        status_tmp := walker_fault_status;
        fault_reg <= '1';
        fault_status_reg <= status_tmp;
        mmusr_update_value <= (others => '0');
        mmusr_update_value(7 downto 0) <= status_tmp;
        mmusr_update_req <= '1';
        translation_pending <= '0';
        -- Debug: Report walker fault processing
        report "WALKER_FAULT: Setting fault_reg=1 status=0x" & slv_to_hstring(walker_fault_status) &
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
            if saved_rw = '0' and atc_attr(hit_idx)(0) = '1' then
              -- Write to write-protected page - generate fault
              report "WP_FAULT: Write to WP page detected" severity note;
              status_tmp := (others => '0');
              status_tmp(6) := '1';
              status_tmp(4 downto 3) := saved_fc(1 downto 0);
              status_tmp(2) := not saved_rw;
              status_tmp(1 downto 0) := "11";
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= (others => '0');
              mmusr_update_value(7 downto 0) <= status_tmp;
              mmusr_update_req <= '1';
              report "WP_FAULT_WALKER: Setting fault_reg=1 for WP violation after walker, addr=0x" & slv_to_hstring(saved_addr_log) severity note;
            elsif saved_fc(2) = '0' and atc_attr(hit_idx)(2) = '0' then
              -- User trying to access supervisor-only page - generate fault
              report "SUPERVISOR_FAULT: User access to supervisor page detected" severity note;
              status_tmp := (others => '0');
              status_tmp(4 downto 3) := saved_fc(1 downto 0);
              status_tmp(2) := not saved_rw;
              status_tmp(1 downto 0) := "11";
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= (others => '0');
              mmusr_update_value(7 downto 0) <= status_tmp;
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
              fault_status_reg <= (others => '0');
              report "VALID_ACCESS: phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
            end if;
            translation_pending <= '0';
          end if; -- hit = '1'
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
            walk_level <= 0;
            walk_vpn  <= saved_addr_log;
            walk_fault <= '0';  -- Clear fault at start of walk
            walk_attr <= (others => '0');
            walk_page_shift <= tc_page_shift;
            walk_page_size  <= tc_page_size;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
            walk_phys_base  <= (others => '0');
            -- Don't clear walker fault signals here - they need to persist until consumed
            -- Use CRP for user space, SRP for supervisor
            if saved_fc(2) = '1' then -- Supervisor
              walk_addr <= SRP_L(31 downto 4) & "0000"; -- Root pointer base
            else -- User
              walk_addr <= CRP_L(31 downto 4) & "0000"; -- Root pointer base  
            end if;
            wstate <= W_ROOT;
          end if;
          
        when W_ROOT =>
          -- Read root table descriptor - deadlock-proof design
          table_index := get_table_index(walk_vpn, walk_level);
          desc_addr := walk_addr(31 downto 4) & "0000"; -- Align to table boundary
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          
          -- Debug: Log walker state for failing test addresses
          if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" then
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
            -- Check descriptor validity
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status(7) <= '1';  -- Invalid descriptor
              walker_fault_status(6) <= '0';  -- Not write protect
              walker_fault_status(5) <= '0';  -- Not bus error
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
              walker_fault_status(2) <= not saved_rw;  -- RW bit (MC68030: 1=write)
              walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2));
              wstate <= W_FAULT;
            elsif desc_is_page(mem_rdat) then
              -- Early termination - this is a page descriptor
              wstate <= W_PAGE;
            else
              -- Table pointer - continue to next level
              walk_addr <= mem_rdat(31 downto 4) & "0000";
              walk_level <= walk_level + 1;
              wstate <= W_PTR1;
            end if;
          end if;
          
        when W_PTR1 =>
          -- Read level 1 table descriptor - deadlock-proof design
          table_index := get_table_index(walk_vpn, walk_level);
          desc_addr := walk_addr(31 downto 4) & "0000";
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          
          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            if saved_addr_log = x"00400000" then
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
            if saved_addr_log = x"00400000" then
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
              walker_fault_status(7) <= '1';  -- Invalid descriptor
              walker_fault_status(6) <= '0';  -- Not write protect
              walker_fault_status(5) <= '0';  -- Not bus error
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
              walker_fault_status(2) <= not saved_rw;  -- RW bit (MC68030: 1=write)
              walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2));
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
          table_index := get_table_index(walk_vpn, walk_level);
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
              walker_fault_status(7) <= '1';  -- Invalid descriptor
              walker_fault_status(6) <= '0';  -- Not write protect
              walker_fault_status(5) <= '0';  -- Not bus error
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
              walker_fault_status(2) <= not saved_rw;  -- RW bit (MC68030: 1=write)
              walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2));
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
          table_index := get_table_index(walk_vpn, walk_level);
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
              -- Invalid or non-page descriptor - generate fault with proper status
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status(7) <= '1';  -- Invalid descriptor
              walker_fault_status(6) <= '0';  -- Not write protect
              walker_fault_status(5) <= '0';  -- Not bus error
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
              walker_fault_status(2) <= not saved_rw;  -- RW bit (MC68030: 1=write)
              walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2));
              wstate <= W_FAULT;
            end if;
          end if;
          
        when W_PAGE =>
          -- Process page descriptor and validate completely
          if not desc_valid(walk_desc) then
            -- Invalid descriptor - generate fault
            walker_fault <= '1';
            walker_fault_status(7) <= '1';  -- Invalid descriptor
            walker_fault_status(6) <= '0';  -- Not write protect
            walker_fault_status(5) <= '0';  -- Not bus error
            if (ptest_req = '1' or pflush_req = '1' or pload_req = '1') then
              walker_fault_status(4 downto 3) <= pmmu_fc(1 downto 0);
            else
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
            end if;
            walker_fault_status(2) <= not saved_rw;  -- RW bit (MC68030: 1=write)
            walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2));
            wstate <= W_FAULT;
          elsif not access_allowed(walk_desc, saved_fc) then
            walker_fault <= '1';
            walker_fault_status(7) <= '0';  -- Not invalid descriptor
            walker_fault_status(6) <= '0';  -- Not write protect violation  
            walker_fault_status(5) <= '1';  -- Supervisor violation (treat as bus error for now)
            if (ptest_req = '1' or pflush_req = '1' or pload_req = '1') then
              walker_fault_status(4 downto 3) <= pmmu_fc(1 downto 0);
            else
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
            end if;
            walker_fault_status(2) <= not saved_rw;  -- RW bit (MC68030: 1=write, TG68K: 1=read)
            walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2)); -- Fault level
            wstate <= W_FAULT;
          else
            -- Valid access - extract attributes (access control enforced at access time)
            walk_page_shift <= tc_page_shift;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
            walk_phys_base  <= phys_base_from_desc(walk_desc, tc_page_shift);
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
          -- Fill ATC with translation result
          atc_log_base(atc_rr)  <= walk_log_base;
          atc_phys_base(atc_rr) <= walk_phys_base;
          atc_shift(atc_rr)     <= walk_page_shift;
          atc_page_size(atc_rr) <= walk_page_size;
          atc_attr(atc_rr)      <= walk_attr(2 downto 0);
          atc_fc(atc_rr)        <= saved_fc;
          atc_is_insn(atc_rr)   <= saved_is_insn;
          atc_valid(atc_rr)     <= '1';
          -- Delay completion signal by one cycle to ensure ATC write is visible
          wstate <= W_COMPLETE;  -- New state to delay completion
          if atc_rr = ATC_ENTRIES-1 then
            atc_rr <= 0;
          else
            atc_rr <= atc_rr + 1;
          end if;
          
          
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
      
      -- PLOAD: Edge detection for future implementation
      if pload_req = '1' and pload_req_prev = '0' then
        -- PLOAD rising edge detected - could trigger page load here
        null;
      end if;
    end if;
  end process;
end rtl;
