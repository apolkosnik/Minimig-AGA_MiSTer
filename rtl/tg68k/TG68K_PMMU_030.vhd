-- TG68K_PMMU_030.vhd
-- MC68030 PMMU Implementation with full page table walker connected to real memory
-- Features: TC/CRP/SRP/TT0/TT1/MMUSR registers, 8-entry ATC, multi-level page tables,
--           transparent translation, fault detection, PMOVE/PTEST/PFLUSH/PLOAD instructions,
--           real page table walking via memory arbiter in cpu_wrapper.v
-- The walker now reads actual descriptors from memory for non-identity address translation.

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
    reg_sel        : in  std_logic_vector(4 downto 0); -- brief(14:10): 00010=TT0 00011=TT1 10000=TC 10010=SRP 10011=CRP 11000=MMUSR
    reg_wdat       : in  std_logic_vector(31 downto 0);
    reg_rdat       : out std_logic_vector(31 downto 0);
    reg_part       : in  std_logic; -- '1' = high, '0' = low for 64-bit regs (CRP/SRP)
    reg_fd         : in  std_logic; -- '1' = flush disable (PMOVEFD)
    
    -- PMMU instruction control
    ptest_req      : in  std_logic; -- PTEST instruction request
    pflush_req     : in  std_logic; -- PFLUSH instruction request
    pload_req      : in  std_logic; -- PLOAD instruction request
    pmmu_fc        : in  std_logic_vector(2 downto 0); -- Function code for PTEST/PFLUSH/PLOAD
    pmmu_addr      : in  std_logic_vector(31 downto 0); -- Address for PTEST/PFLUSH/PLOAD
    pmmu_brief     : in  std_logic_vector(15 downto 0); -- Brief/extension word for instruction modes

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
    fault_status   : out std_logic_vector(31 downto 0);
    tc_enable      : out std_logic;

    -- Walker memory interface (read/write) and busy indicator
    mem_req        : buffer std_logic;
    mem_we         : out std_logic;  -- Write enable for descriptor updates (U/M bits)
    mem_addr       : out std_logic_vector(31 downto 0);
    mem_wdat       : out std_logic_vector(31 downto 0);  -- Write data for descriptor updates
    mem_ack        : in  std_logic;
    mem_berr       : in  std_logic;  -- Bus error during table walk (sets MMUSR B bit)
    mem_rdat       : in  std_logic_vector(31 downto 0);
    busy           : out std_logic;

    -- MMU Configuration Exception (MC68030 vector 56)
    mmu_config_err : out std_logic;
    mmu_config_ack : in  std_logic   -- Acknowledgment from kernel when trap is taken
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
  -- NOTE: CAL, VAL, SCC, AC registers are defined in MC68030 but not implemented
  -- They were removed as unused signals to avoid synthesis warnings

  -- Internal
  signal tc_en  : std_logic; -- translation enable bit (TC[31] in some docs; keep flexible here)

  -- Walker descriptor address register (must persist across clock cycles for W_*_LOW states)
  signal desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');

  -- MC68030 register write masks (workaround for VHDL synthesis issues)
  -- TC register mask: preserve E(31), SRE(25), FCL(24), and all field bits (23-0), clear reserved bits 30-26
  -- Note: Bit 23 (PS MSB) is forced to 1 in write logic since all valid PS values (8-15) have MSB=1
  constant TC_WRITE_MASK : std_logic_vector(31 downto 0) := "10000011111111111111111111111111";

  -- TTR register mask (MC68030 User's Manual section 9.2.6):
  -- Preserve: Address(31:16), E(15), CI(10), RW(9), RWM(8), FC_Base(6:4), FC_Mask(2:0)
  -- Clear reserved: bits 14-11, 7, 3
  constant TTR_WRITE_MASK : std_logic_vector(31 downto 0) := "11111111111111111000011101110111"; -- 0xFFFF8777

  -- CRP/SRP HIGH mask: preserve L/U (31), Limit (30-16), DT (1:0); clear reserved (15-2)
  -- HIGH word format: L/U[63] + Limit[62:48] + Reserved[47:34] + DT[33:32]
  constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := "11111111111111110000000000000011"; -- 0xFFFF0003

  -- CRP/SRP LOW mask: preserve table address (31-4), clear reserved bits (3-0)
  -- LOW word format: Table Address[31:4] + Reserved[3:0]
  constant CRP_LOW_MASK : std_logic_vector(31 downto 0) := "11111111111111111111111111110000"; -- 0xFFFFFFF0
  
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

  -- Simple ATC (Address Translation Cache), 8 entries, dynamic page sizes
  constant ATC_ENTRIES : integer := 8;
  type atc_attr_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(3 downto 0);  -- {U_ACC, CI, M, WP} where U_ACC=NOT(S)=user accessible
  type atc_val_t  is array(0 to ATC_ENTRIES-1) of std_logic;
  type atc_base_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(31 downto 0);
  type atc_fc_t   is array(0 to ATC_ENTRIES-1) of std_logic_vector(2 downto 0);
  type atc_isn_t  is array(0 to ATC_ENTRIES-1) of std_logic;
  -- ATC shift stores the effective page shift for the translation that populated the entry.
  -- This can exceed TC.PS when a page descriptor terminates the walk early (large pages).
  type atc_shift_t is array(0 to ATC_ENTRIES-1) of integer range 0 to 31;
  type atc_page_size_t is array(0 to ATC_ENTRIES-1) of integer range 0 to 15; -- MC68030 PS field value (8-15)

  signal atc_log_base : atc_base_t;
  signal atc_phys_base: atc_base_t;
  signal atc_attr  : atc_attr_t;
  signal atc_valid : atc_val_t;
  signal atc_fc    : atc_fc_t;
  signal atc_is_insn : atc_isn_t;
  signal atc_shift : atc_shift_t;
  signal atc_page_size : atc_page_size_t;
  signal atc_global : atc_val_t;  -- G bit: global page (survives PFLUSHAN)
  signal atc_rr    : integer range 0 to ATC_ENTRIES-1 := 0; -- simple round-robin
  signal walk_req  : std_logic;
  signal walker_completed : std_logic := '0';

  -- Translation control decoding (TC register fields)
  type tc_bits_array_t is array(0 to 3) of integer range 0 to 16;
  constant DEFAULT_TC_BITS : tc_bits_array_t := (8, 8, 4, 0);
  constant DEFAULT_TC_IS   : integer := 0;
  signal tc_idx_bits      : tc_bits_array_t := DEFAULT_TC_BITS;
  signal tc_initial_shift : integer range 0 to 15 := DEFAULT_TC_IS;
  signal tc_page_size     : integer range 0 to 15 := 12;  -- MC68030: PS values 8-15 (0-7 reserved)
  signal tc_page_shift    : integer range 8 to 15 := 12;  -- MC68030: offset bits 8-15
  signal tc_sre           : std_logic := '0';  -- Supervisor Root Enable
  signal tc_fcl           : std_logic := '0';  -- Function Code Lookup

  -- MMUSR update handshake between translation pipeline and register file
  signal mmusr_update_req   : std_logic := '0';
  signal mmusr_update_ack   : std_logic := '0';
  signal mmusr_update_value : std_logic_vector(31 downto 0) := (others => '0');

  -- MMU Configuration Exception tracking
  signal mmu_config_error   : std_logic := '0';

  -- MC68030 page table walker FSM
  -- Added W_*_LOW states for reading LOW word of long-format (64-bit) descriptors
  -- Added W_INDIRECT states for indirect descriptor support (MC68030 spec section 9.5.3.2)
  -- BUG #164 FIX: Added W_INDIRECT_LOW for long-format indirect descriptor targets
  type walk_state_t is (W_IDLE, W_ROOT, W_ROOT_LOW, W_PTR1, W_PTR1_LOW, W_PTR2, W_PTR2_LOW, W_PTR3, W_PTR3_LOW, W_INDIRECT, W_INDIRECT_LOW, W_PAGE, W_UPDATE_DESC, W_FILL, W_COMPLETE, W_FAULT);
  signal wstate    : walk_state_t := W_IDLE;
  
  -- Walker bookkeeping
  signal walk_log_base  : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_phys_base : std_logic_vector(31 downto 0) := (others => '0');
  -- Effective page shift for the current translation (may exceed TC.PS for large pages).
  signal walk_page_shift: integer range 0 to 31 := 12;
  signal walk_page_size : integer range 0 to 15 := 12;  -- MC68030: PS values 8-15
  
  -- PMMU instruction communication flags (to avoid multiple drivers)
  signal ptest_update_mmusr : std_logic := '0';
  signal pflush_clear_atc   : std_logic := '0';
  signal atc_flush_req      : std_logic := '0';
  
  -- Edge detection for PMMU instructions
  signal ptest_req_prev  : std_logic := '0';
  signal pflush_req_prev : std_logic := '0';
  signal pload_req_prev  : std_logic := '0';
  -- BUG #16 FIX: Edge detection for PMOVE register access
  signal reg_we_prev     : std_logic := '0';
  signal reg_re_prev     : std_logic := '0';

  -- PTEST operation state
  signal ptest_active : std_logic := '0';
  signal ptest_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal ptest_rw : std_logic := '1';  -- '1'=PTESTR (read), '0'=PTESTW (write), from brief(9)

  -- PLOAD operation state
  signal pload_active : std_logic := '0';
  signal pload_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pload_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal pload_rw : std_logic := '1';  -- '1'=PLOADR (read), '0'=PLOADW (write), from brief(9)

  -- PFLUSH operation state
  signal pflush_active : std_logic := '0';
  signal pflush_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pflush_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal pflush_mode : std_logic_vector(12 downto 8) := (others => '0');  -- From brief word
  
  -- Page table walking state
  signal walk_level     : integer range 0 to 4 := 0; -- Current level being walked
  signal walk_desc      : std_logic_vector(31 downto 0) := (others => '0'); -- Current descriptor (short format or HIGH word)
  signal walk_desc_high : std_logic_vector(31 downto 0) := (others => '0'); -- HIGH word (all formats)
  signal walk_desc_low  : std_logic_vector(31 downto 0) := (others => '0'); -- LOW word (long format only)
  signal walk_desc_is_long : std_logic := '0'; -- 1=long format (DT=11), 0=short format (DT=10/01)
  signal walk_addr      : std_logic_vector(31 downto 0) := (others => '0'); -- Current table address
  signal walk_vpn       : std_logic_vector(31 downto 0) := (others => '0'); -- Virtual page being walked
  signal walk_fault     : std_logic := '0'; -- Page fault flag
  signal walk_attr      : std_logic_vector(7 downto 0) := (others => '0'); -- Page attributes
  signal walk_global    : std_logic := '0'; -- G bit from long-format descriptor (bit 10)
  signal walk_supervisor : std_logic := '0'; -- BUG #157 FIX: Cumulative S bit from TABLE descriptors
  signal indirect_addr  : std_logic_vector(31 downto 0) := (others => '0'); -- Target address for indirect descriptor
  signal indirect_target_long : std_logic := '0'; -- BUG #164 FIX: DT=11 indirect -> long-format target

  -- BUG #155 FIX: MC68030 table descriptor limit checking (applies to next level index)
  -- Only long-format (DT=11) table descriptors have limit fields
  -- SHORT format (DT=10) has NO limit field - walk_limit_valid stays '0'
  signal walk_limit_valid : std_logic := '0';  -- '1' if previous descriptor had limit field
  -- MC68030 Root/Table Descriptor L/U semantics:
  -- L/U=1 selects LOWER-limit checking (index must be >= LIMIT)
  -- L/U=0 selects UPPER-limit checking (index must be <= LIMIT)
  signal walk_limit_lu    : std_logic := '0';
  signal walk_limit_value : unsigned(14 downto 0) := (others => '0');  -- 15-bit limit value

  -- MC68030 U/M bit tracking (Issue #3, #4)
  -- U (Used) bit 3: Set when page is accessed (any access)
  -- M (Modified) bit 4: Set when page is written
  signal desc_update_needed : std_logic := '0';  -- Need to write back descriptor with U/M
  signal desc_update_data   : std_logic_vector(31 downto 0) := (others => '0'); -- Updated descriptor

  -- Debug helper functions commented out for synthesis (Quartus doesn't respect translate_off)
  -- synthesis translate_off
  -- function slv_to_hstring(value : std_logic_vector) return string is
  --   constant hex_chars   : string := "0123456789ABCDEF";
  --   constant nibble_count: integer := (value'length + 3) / 4;
  --   variable result      : string(1 to nibble_count);
  --   variable nibble_val  : integer range 0 to 15;
  --   variable bit_val     : std_logic;
  --   variable bit_index   : integer;
  --   variable idx         : integer;
  --   variable has_unknown : boolean;
  -- begin
  --   for i in result'range loop
  --     result(i) := '0';
  --   end loop;
  --   for nib in 0 to nibble_count - 1 loop
  --     nibble_val  := 0;
  --     has_unknown := false;
  --     for bit in 0 to 3 loop
  --       nibble_val := nibble_val * 2;
  --       bit_index  := nib * 4 + bit;
  --       if bit_index < value'length then
  --         idx     := value'high - bit_index;
  --         bit_val := value(idx);
  --         case bit_val is
  --           when '0' | 'L' => null;
  --           when '1' | 'H' => nibble_val := nibble_val + 1;
  --           when others    => has_unknown := true;
  --         end case;
  --       end if;
  --     end loop;
  --     if has_unknown then
  --       result(nib + 1) := 'X';
  --     else
  --       result(nib + 1) := hex_chars(nibble_val + 1);
  --     end if;
  --   end loop;
  --   return result;
  -- end function;
  -- function slv_to_string(value : std_logic_vector) return string is
  --   variable result : string(1 to value'length);
  --   variable idx    : integer;
  -- begin
  --   for i in 0 to value'length - 1 loop
  --     idx := value'high - i;
  --     case value(idx) is
  --       when '0' | 'L' => result(i + 1) := '0';
  --       when '1' | 'H' => result(i + 1) := '1';
  --       when 'Z'       => result(i + 1) := 'Z';
  --       when 'W'       => result(i + 1) := 'W';
  --       when 'U'       => result(i + 1) := 'U';
  --       when 'X'       => result(i + 1) := 'X';
  --       when others    => result(i + 1) := '?';
  --     end case;
  --   end loop;
  --   return result;
  -- end function;
  -- synthesis translate_on

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
  -- MC68030 Page Size Encoding (from MC68030 User's Manual):
  -- 1000 (8)  -> 256 bytes  (8-bit offset)
  -- 1001 (9)  -> 512 bytes  (9-bit offset)
  -- 1010 (10) -> 1KB        (10-bit offset)
  -- 1011 (11) -> 2KB        (11-bit offset)
  -- 1100 (12) -> 4KB        (12-bit offset)
  -- 1101 (13) -> 8KB        (13-bit offset)
  -- 1110 (14) -> 16KB       (14-bit offset)
  -- 1111 (15) -> 32KB       (15-bit offset)
  -- All other values (0-7) are RESERVED and cause MMU configuration exception
  function get_page_offset_bits(ps_field : integer) return integer is
  begin
    -- MC68030: PS field value directly encodes the number of offset bits!
    -- Valid range: 8-15 (corresponding to 256B-32KB pages)
    if ps_field >= 8 and ps_field <= 15 then
      return ps_field;  -- PS value IS the number of offset bits
    else
      -- Reserved value - should trigger MMU configuration exception
      -- For now, return default 12 (4KB) to prevent synthesis errors
      return 12;  -- Default to 4KB for reserved/invalid values
    end if;
  end function;

  function page_shift_from_tc(ps : integer) return integer is
  begin
    return get_page_offset_bits(ps);
  end function;

  -- MC68030 IMPORTANT: Page descriptors do NOT have a PS field
  -- Page size is ALWAYS determined by TC.PS register, never by descriptor bits
  -- Descriptor bits 3:2 are U (Used) and WP (Write Protect), NOT page size

  function phys_base_from_desc(desc : std_logic_vector(31 downto 0);
                               shift : integer) return std_logic_vector is
    variable base : std_logic_vector(31 downto 0);
  begin
    base(31 downto 8) := desc(31 downto 8);
    base(7 downto 0)  := (others => '0');
    return align_addr(base, shift);
  end function;

  -- MC68030 TTR format: proper transparent translation register implementation
  -- MC68030 TTR format (per MC68030 User's Manual section 9.2.6):
  -- Bits 31-24: Logical Address Base
  -- Bits 23-16: Logical Address Mask
  -- Bit 15: Enable
  -- Bits 14-11: Reserved
  -- Bit 10: Cache Inhibit
  -- Bit 9: RW (R/W attribute)
  -- Bit 8: RWM (R/W mask)
  -- Bit 7: Reserved
  -- Bits 6-4: Function Code Base
  -- Bit 3: Reserved
  -- Bits 2-0: Function Code Mask
  procedure ttr_check(
      tt        : in  std_logic_vector(31 downto 0);
      addr      : in  std_logic_vector(31 downto 0);
      fc        : in  std_logic_vector(2 downto 0);
      is_insn   : in  std_logic;
      rw        : in  std_logic;  -- '1'=read, '0'=write
      matched   : out std_logic;
      ci        : out std_logic;
      wp        : out std_logic) is
    variable enable     : std_logic;
    variable base       : std_logic_vector(7 downto 0);
    variable mask       : std_logic_vector(7 downto 0);
    variable addr_hi    : std_logic_vector(7 downto 0);
    variable fc_base    : std_logic_vector(2 downto 0);  -- FC Base from bits 6:4
    variable fc_mask    : std_logic_vector(2 downto 0);  -- FC Mask from bits 2:0
    variable addr_match : std_logic;
    variable fc_match   : std_logic;
  begin
    -- MC68030 TTR format (per MC68030 User's Manual section 9.2.6):
    -- Bits 31-24: Logical Address Base
    -- Bits 23-16: Logical Address Mask
    -- Bit 15: Enable (E)
    -- Bits 14-11: Reserved (must be 0)
    -- Bit 10: Cache Inhibit (CI)
    -- Bit 9: R/W (read/write attribute)
    -- Bit 8: RWM (R/W mask)
    -- Bit 7: Reserved
    -- Bits 6-4: Function Code Base
    -- Bit 3: Reserved
    -- Bits 2-0: Function Code Mask
    enable     := tt(15);           -- E bit: TTR enable
    base       := tt(31 downto 24); -- Base address (bits 31:24)
    mask       := tt(23 downto 16); -- Address mask (bits 23:16)
    -- NOTE: Bits 14-11 are RESERVED in MC68030 TTR - no supervisor field exists!
    -- Supervisor/user matching is done via FC Base and FC Mask fields only
    fc_base    := tt(6 downto 4);   -- Function Code Base
    fc_mask    := tt(2 downto 0);   -- Function Code Mask
    addr_hi    := addr(31 downto 24); -- Address high byte

    -- Early exit if TTR is disabled - prevents any false matches
    if enable = '0' then
      matched := '0';
      ci := '0';
      wp := '0';
      return;
    end if;

    -- Address match: MC68030 TTR mask logic
    -- MC68030: mask=0 means "must match", mask=1 means "don't care" (ignore)
    -- Match when all non-masked bits of addr equal all non-masked bits of base
    -- Implementation: XOR to find differences, then AND with NOT mask to check only required bits
    -- If result is zero, all required bits match
    if ((addr_hi XOR base) AND (NOT mask)) = x"00" then
      addr_match := '1';
    else
      addr_match := '0';
    end if;

    -- Function code match: MC68030 TTR FC implementation
    -- FC Base (bits 6:4) specifies which function codes to match
    -- FC Mask (bits 2:0) specifies which FC bits to ignore
    -- Match when: (actual_fc XOR fc_base) AND (NOT fc_mask) == "000"
    -- This allows flexible matching: mask=111 matches any FC, mask=000 requires exact match
    -- NOTE: Supervisor/user matching is done here via FC - FC bit 2 = 1 for supervisor
    if ((fc XOR fc_base) AND (NOT fc_mask)) = "000" then
      fc_match := '1';
    else
      fc_match := '0';
    end if;

    -- Overall match - check address and FC (no separate supervisor field in MC68030 TTR)
    if enable = '1' AND addr_match = '1' AND fc_match = '1' then
      matched := '1';
      -- MC68030 TTR CI field (bit 10): Cache Inhibit
      -- 0=cacheable, 1=cache inhibit
      if tt(10) = '1' then
        ci := '1';  -- Cache inhibit
      else
        ci := '0';  -- Cacheable
      end if;
      -- MC68030 TTR R/W field (per User's Manual section 9.2.6):
      -- Bit 8 (RWM): 0 = R/W field used, 1 = R/W field ignored
      -- Bit 9 (R/W): 0 = write accesses transparent, 1 = read accesses transparent
      -- When RWM=1, both read and write accesses are transparently translated
      if tt(8) = '0' then  -- RWM=0: R/W field is USED (check access type)
        if tt(9) = '1' and rw = '0' then
          -- R/W=1 (read-only transparent) but this is a write - no match
          matched := '0';
          wp := '0';
        elsif tt(9) = '0' and rw = '1' then
          -- R/W=0 (write-only transparent) but this is a read - no match
          matched := '0';
          wp := '0';
        else
          wp := '0';  -- Access type matches
        end if;
      else  -- RWM=1: R/W field is IGNORED (both reads and writes allowed)
        wp := '0';  -- No write protection, both access types allowed
      end if;
      -- Debug for write protection test (commented out for synthesis)
      -- if addr(31 downto 12) = x"00002" then
      --   report "TTR_MATCH_DEBUG: addr=0x" & slv_to_hstring(addr) &
      --          " base=0x" & slv_to_hstring("000000" & base) &
      --          " mask=0x" & slv_to_hstring("000000" & mask) &
      --          " addr_hi=0x" & slv_to_hstring("000000" & addr_hi) &
      --          " enable=" & std_logic'image(enable) &
      --          " addr_match=" & std_logic'image(addr_match) &
      --          " fc_match=" & std_logic'image(fc_match) &
     --  --          " tt_reg=0x" & slv_to_hstring(tt) severity note;
      -- end if;
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
    ttr_check(tt, addr, fc, is_insn, '1', matched, dummy_ci, dummy_wp);  -- Default to read for simple match check
  end procedure;
  
  -- Extract table index from virtual address (MC68030 compliant)
  -- BUG FIX: Added page_size parameter - was missing, causing wrong index extraction
  function get_table_index(addr : std_logic_vector(31 downto 0);
                          level : integer;
                          initial_shift : integer;
                          page_size : integer;
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
    -- Address format after ignoring IS bits: [TIA] [TIB] [TIC] [TID] [Page Offset (PS bits)]
    -- Each level's index bits are extracted from specific positions
    --
    -- Shift amount = Page Size + sum of all TIx bits BELOW this level
    -- Level 0 (TIA): shift = PS + TIB + TIC + TID
    -- Level 1 (TIB): shift = PS + TIC + TID
    -- Level 2 (TIC): shift = PS + TID
    -- Level 3 (TID): shift = PS

    -- Start with page size (page offset bits at bottom)
    remaining_bits := page_size;

    -- Add bits from ALL levels that come BELOW this one (level 3 is lowest, level 0 is highest)
    -- Level 0 adds: TIB + TIC + TID
    -- Level 1 adds: TIC + TID
    -- Level 2 adds: TID
    -- Level 3 adds: nothing (already at bottom)
    if level < 1 then remaining_bits := remaining_bits + idx_bits(1); end if;
    if level < 2 then remaining_bits := remaining_bits + idx_bits(2); end if;
    if level < 3 then remaining_bits := remaining_bits + idx_bits(3); end if;

    -- The shift amount positions this level's index bits at bit 0
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

  -- MC68030 Function Code Lookup (TC.FCL):
  -- When FCL=1, the table search uses FC[2:0] as the top bits of the logical address.
  -- This effectively replaces A[31:29] with FC[2:0], preserving a 32-bit search key:
  --   search_addr = {FC[2:0], A[28:0]}
  function fcl_search_addr(addr : std_logic_vector(31 downto 0);
                           fc   : std_logic_vector(2 downto 0);
                           fcl  : std_logic) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    if fcl = '1' then
      result := fc & addr(28 downto 0);
    else
      result := addr;
    end if;
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

  -- Check if descriptor is long format (DT=11, 64-bit)
  function desc_is_long(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "11"; -- DT=11 means long format (8 bytes)
  end function;

  -- Calculate TC bit sum per MC68030 spec: add PS+IS and TIx fields
  -- stopping at the first TIx that is zero (remaining TIx are ignored).
  -- IS defaults to DEFAULT_TC_IS when zero; PS is validated separately.
  function tc_total_bits(tc : std_logic_vector(31 downto 0)) return integer is
    variable ps_val : integer;
    variable is_val : integer;
    variable tia_val, tib_val, tic_val, tid_val : integer;
    variable total_bits : integer;
  begin
    ps_val := to_integer(unsigned(tc(23 downto 20)));
    is_val := to_integer(unsigned(tc(19 downto 16)));
    if is_val = 0 then
      is_val := DEFAULT_TC_IS;
    end if;
    tia_val := to_integer(unsigned(tc(15 downto 12)));
    tib_val := to_integer(unsigned(tc(11 downto 8)));
    tic_val := to_integer(unsigned(tc(7 downto 4)));
    tid_val := to_integer(unsigned(tc(3 downto 0)));

    total_bits := get_page_offset_bits(ps_val) + is_val;
    if tia_val /= 0 then
      total_bits := total_bits + tia_val;
      if tib_val /= 0 then
        total_bits := total_bits + tib_val;
        if tic_val /= 0 then
          total_bits := total_bits + tic_val;
          if tid_val /= 0 then
            total_bits := total_bits + tid_val;
          end if;
        end if;
      end if;
    end if;
    return total_bits;
  end function;

  -- Check if descriptor is short format (DT=10, 32-bit)
  function desc_is_short(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "10"; -- DT=10 means short format (4 bytes)
  end function;

  -- Get supervisor bit from descriptor (MC68030 compliant)
  -- Returns: '1' if supervisor-only page, '0' if user-accessible
  function get_supervisor_bit(desc_high : std_logic_vector(31 downto 0);
                              is_long : std_logic) return std_logic is
  begin
    if is_long = '1' then
      return desc_high(8); -- Long format: S bit at position 8
    else
      return '0';          -- Short format: no S bit, treat as user-accessible (S=0)
    end if;
  end function;

  -- Get table/page address from descriptor (MC68030 compliant)
  function get_desc_address(desc_high : std_logic_vector(31 downto 0);
                            desc_low  : std_logic_vector(31 downto 0);
                            is_long   : std_logic) return std_logic_vector is
  begin
    if is_long = '1' then
      return desc_low(31 downto 4) & "0000";  -- Long format: address from LOW word
    else
      return desc_high(31 downto 4) & "0000"; -- Short format: address from only word
    end if;
  end function;

  -- Check supervisor/user access permissions (MC68030 compliant with long format support)
  function access_allowed(desc_high : std_logic_vector(31 downto 0);
                         fc : std_logic_vector(2 downto 0);
                         is_long : std_logic) return boolean is
    variable is_supervisor_fc : boolean;
    variable s_bit : std_logic;
  begin
    -- MC68030 function code definitions:
    -- FC2=0: User space, FC2=1: Supervisor space
    is_supervisor_fc := (fc(2) = '1');

    -- Get S bit from correct position based on format
    s_bit := get_supervisor_bit(desc_high, is_long);

    -- MC68030 access control rules:
    -- S=1: Supervisor-only page (user cannot access)
    -- S=0: User-accessible page (both supervisor and user can access)
    -- Short format has no S bit, so S=0 (all pages user-accessible)
    if is_supervisor_fc then
      return true;  -- Supervisor can access everything
    else
      return (s_bit = '0');  -- User can only access pages with S=0
    end if;
  end function;
  
  -- MC68030 MMUSR encoding functions
  -- MMUSR Bit Assignments (MC68030 User's Manual section 9.2.7):
  -- Bit 15: B (Bus Error)
  -- Bit 14: L (Limit Violation)
  -- Bit 13: S (Supervisor-Only violation)
  -- Bit 12: Reserved (0)
  -- Bit 11: W (Write Protected)
  -- Bit 10: I (Invalid descriptor)
  -- Bit 9: M (Modified)
  -- Bits 8-7: Reserved (0)
  -- Bit 6: T (Transparent Access via TT0/TT1)
  -- Bits 5-3: Reserved (0)
  -- Bits 2-0: N (Number of Levels accessed, 0-7)
  function encode_mmusr_fault(
    bus_error : std_logic;
    limit_violation : std_logic;
    supervisor_violation : std_logic;
    write_protect : std_logic;
    invalid : std_logic;
    modified : std_logic;
    transparent : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    -- Initialize all bits to zero first
    result := (others => '0');
    -- Then set the individual fields per MC68030 MMUSR format
    result(15) := bus_error;              -- Bit 15: B (Bus Error)
    result(14) := limit_violation;        -- Bit 14: L (Limit Violation)
    result(13) := supervisor_violation;   -- Bit 13: S (Supervisor-Only)
    -- Bit 12: Reserved (already 0)
    result(11) := write_protect;          -- Bit 11: W (Write Protected)
    result(10) := invalid;                -- Bit 10: I (Invalid descriptor)
    result(9) := modified;                -- Bit 9: M (Modified)
    -- Bits 8-7: Reserved (already 0)
    result(6) := transparent;             -- Bit 6: T (Transparent Access)
    -- Bits 5-3: Reserved (already 0)
    result(2 downto 0) := level;          -- Bits 2-0: N (Number of Levels, 0-7)
    return result;
  end function;
  
  -- MC68030 MMUSR Success Encoding per User's Manual section 9.2.7
  -- For successful translations (no faults), MMUSR contains:
  -- Bits 15-13: Fault bits (B,L,S) = 0, Bit 12: Reserved, Bit 11: W, Bit 10: I = 0
  -- Bit 9: M (Modified), Bits 8-7: Reserved, Bit 6: T (Transparent)
  -- Bits 5-3: Reserved, Bits 2-0: N (Number of Levels)
  function encode_mmusr_success(
    write_protect : std_logic;
    modified : std_logic;
    transparent : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    result := (others => '0');
    -- Fault bits (15-13) are 0 for success
    -- Bit 12: Reserved (already 0)
    result(11) := write_protect;  -- Bit 11: W (Write Protected)
    result(10) := '0';            -- Bit 10: I (Invalid = 0 for successful translation)
    result(9) := modified;        -- Bit 9: M (Modified bit from descriptor)
    -- Bits 8-7: Reserved (already 0)
    result(6) := transparent;     -- Bit 6: T (Transparent Access)
    -- Bits 5-3: Reserved (already 0)
    result(2 downto 0) := level;  -- Bits 2-0: N (Number of Levels for page walk)
    return result;
  end function;

begin

  -- Reset and register writes
  process(clk, nreset)
    -- Variables for TC validation (MMU configuration exception detection)
    variable tc_e : std_logic;
    variable tc_write_val : std_logic_vector(31 downto 0);  -- BUG #48: TC value with conditional E bit
    variable ps_val : integer;
    variable is_val : integer;
    variable tia_val, tib_val, tic_val, tid_val : integer;
    variable total_bits : integer;
    variable page_offset_bits : integer;
  begin
    if nreset = '0' then
      -- MC68030: Initialize TC to 0 - MMU disabled (E=0), PS=0
      -- Software configures all fields before enabling
      TC    <= x"00000000";
      CRP_H <= (others => '0');
      CRP_L <= (others => '0');
      SRP_H <= (others => '0');
      SRP_L <= (others => '0');
      TT0   <= (others => '0');
      TT1   <= (others => '0');
      MMUSR <= (others => '0');
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      ptest_active <= '0';
      ptest_addr <= (others => '0');
      ptest_fc <= (others => '0');
      mmu_config_error <= '0';
    elsif rising_edge(clk) then
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      -- BUG #154 FIX: Clear mmu_config_error when kernel acknowledges the trap
      -- This prevents infinite exception loops - the error latches until the
      -- kernel takes the trap and pulses mmu_config_ack
      if mmu_config_ack = '1' then
        mmu_config_error <= '0';
      end if;

      -- Handle MMUSR updates with MC68030-compliant priority (MMUSR register only)
      -- IMPORTANT: These only affect MMUSR, not other registers!
      if ptest_update_mmusr = '1' then
        -- Highest priority: PTEST instruction (MC68030 specification)
        ptest_active <= '1';
        ptest_addr <= pmmu_addr;
        ptest_fc <= pmmu_fc;
        -- BUG #14 FIX: MC68030 spec - brief(9): 0=PTESTW(write), 1=PTESTR(read)
        -- rw signal: 0=write, 1=read, so direct assignment (no NOT)
        ptest_rw <= pmmu_brief(9);
        if tc_en = '0' then
          -- MMU disabled - PTEST always succeeds with identity translation
          MMUSR <= encode_mmusr_success(
            write_protect => '0',        -- No write protect for identity
            modified => '0',             -- No modification tracking for identity
            transparent => '0',          -- Not transparent (MMU disabled)
            level => "000"               -- No table walk for identity translation
          );
        else
          -- MMU enabled - will be handled by main translation logic
          null; -- Translation process will update MMUSR
        end if;
      elsif mmusr_update_req = '1' then
        -- Medium priority: Translation engine update (automatic updates)
        MMUSR <= mmusr_update_value;
        mmusr_update_ack <= '1';
      end if;

      -- Handle direct register writes (TC, CRP, SRP, TT0, TT1, etc.)
      -- CRITICAL FIX: These are INDEPENDENT of MMUSR updates and execute concurrently
      -- BUG #12: Was using "elsif" which blocked all register writes when MMUSR updates active
      -- SWITCHED TO LEVEL: Use level-triggered logic instead of edge detection
      if reg_we = '1' then
        -- MC68030 Specification: MMU register access requires supervisor mode
        -- Privilege check is performed by TG68KdotC_Kernel before asserting reg_we,
        -- so no additional FC check is needed here
        -- report "PMMU_REG_WRITE: sel=0x" & slv_to_hstring(reg_sel) &
               -- " wdat=0x" & slv_to_hstring(reg_wdat) &
              --  -- " part=" & std_logic'image(reg_part) severity note;
        case reg_sel is
          when "00010" =>  -- TT0: P-reg 0x02
            -- TT0 register write - MC68030 Transparent Translation Register per User's Manual section 9.2.6
            -- MC68030 TT0/TT1 bit layout:
            -- 31-24: Logical Address Base, 23-16: Logical Address Mask
            -- 15: E (Enable), 14-11: Reserved, 10: CI (Cache Inhibit), 9: RW, 8: RWM
            -- 7: Reserved, 6-4: FC Base, 3: Reserved, 2-0: FC Mask
            TT0 <= (reg_wdat and TTR_WRITE_MASK);
            -- TT0 changes invalidate ATC unless PMOVEFD (flush disable)
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
            -- report "TT0_WRITE_SPEC_COMPLIANT: input=0x" & slv_to_hstring(reg_wdat) &
                  --  -- " reserved bits 14-11,7,3 masked to zero" severity note;
          when "00011" =>  -- TT1: P-reg 0x03
            -- TT1 register write - MC68030 Transparent Translation Register (same layout as TT0)
            -- MC68030 TT0/TT1 bit layout:
            -- 31-24: Logical Address Base, 23-16: Logical Address Mask
            -- 15: E (Enable), 14-11: Reserved, 10: CI (Cache Inhibit), 9: RW, 8: RWM
            -- 7: Reserved, 6-4: FC Base, 3: Reserved, 2-0: FC Mask
            TT1 <= (reg_wdat and TTR_WRITE_MASK);
            -- TT1 changes invalidate ATC unless PMOVEFD (flush disable)
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "10000" =>  -- TC: P-reg 0x10
            -- MC68030 TC Register Write - exact specification compliance
            -- MC68030 TC bit layout per User's Manual section 9.2.1:
            -- 31: E (Enable), 30-26: Reserved, 25: SRE, 24: FCL
            -- 23-20: PS (Page Size), 19-16: IS (Initial Shift), 15-12: TIA, 11-8: TIB, 7-4: TIC, 3-0: TID
            -- Reserved bits: 30-26 only (all other bits are valid control fields)

            -- BUG #48 FIX: Validate configuration BEFORE writing TC to prevent lockup
            -- If configuration is invalid and E=1, clear E bit to prevent MMU activation
            -- This prevents system lockup from invalid MMU config while still taking exception
            tc_write_val := reg_wdat and TC_WRITE_MASK;
            tc_e := reg_wdat(31);

            if tc_e = '1' then
              -- Only validate when MMU is being enabled
              -- MC68030: PS field bit 23 must be 1 for valid page sizes (PS=8-15 all have MSB=1)
              tc_write_val(23) := '1';
              ps_val := to_integer(unsigned(reg_wdat(23 downto 20)));

              -- Check 1: PS field must be 8-15 (values 0-7 are reserved)
              if ps_val < 8 then
                -- Invalid PS - clear E bit to prevent MMU activation
                tc_write_val(31) := '0';
                mmu_config_error <= '1';
               --  -- report "MMU_CONFIG_EXCEPTION: Invalid PS field=" & integer'image(ps_val) & " (must be 8-15), E bit cleared" severity warning;
              else
                -- Check 2: Field sum must equal 32 per MC68030 spec (stop adding TIx at first zero)
                total_bits := tc_total_bits(reg_wdat);

                if total_bits /= 32 then
                  -- Invalid field sum - clear E bit to prevent MMU activation
                  tc_write_val(31) := '0';
                  mmu_config_error <= '1';
                 --  -- report "MMU_CONFIG_EXCEPTION: Field sum=" & integer'image(total_bits) & " (must be 32), E bit cleared" severity warning;
                else
                  -- BUG #146: Valid TC write - clear any previous config error
                  mmu_config_error <= '0';
                end if;
              end if;
            else
              -- BUG #148 FIX: TC write with E=0 (MMU disabled) clears any previous config error
              -- This allows exception handlers to acknowledge the error by disabling the MMU
              mmu_config_error <= '0';
            end if;

            -- Write TC with potentially cleared E bit (prevents lockup on invalid config)
            TC <= tc_write_val;

            -- TC changes invalidate ATC unless PMOVEFD (flush disable)
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "10010" =>  -- SRP: P-reg 0x12
            -- SRP register write - MC68030 Long-Format Root Pointer (same format as CRP)
            if reg_part = '1' then
              -- SRP HIGH WORD (bits 63-32): L/U[63] + Limit[62:48] + Reserved[47:33] + DT[32]
              -- MC68030 spec: L/U bit 63, Limit bits 62-48, reserved bits 47-33 (zero), DT bit 32
              SRP_H <= (reg_wdat and CRP_HIGH_MASK);

              -- MC68030 MMU Configuration Exception: DT=0 (invalid descriptor)
              -- Per spec: Register is loaded BEFORE exception is taken
              if reg_wdat(1 downto 0) = "00" then
                mmu_config_error <= '1';
               --  -- report "MMU_CONFIG_EXCEPTION: SRP_H DT=00 (invalid descriptor type)" severity warning;
              else
                -- BUG #146: Valid SRP_H write (DT!=00) - clear any previous config error
                mmu_config_error <= '0';
              end if;
            else
              -- SRP LOW WORD (bits 31-0): Table Address[31:4] + Reserved[3:0]
              -- MC68030 spec: Table address bits 31-4, reserved bits 3-0 must be zero
              SRP_L <= (reg_wdat and CRP_LOW_MASK);
              -- BUG #148 FIX: Do NOT clear mmu_config_error on low word write
              -- If high word had DT=00, error must remain latched until explicitly acknowledged
              -- (via valid high word write or TC write with E=0)
            end if;
            if reg_fd = '0' then  -- Only flush if NOT PMOVEFD
              atc_flush_req <= '1'; -- SRP changes invalidate all cached translations
            end if;
          when "10011" =>  -- CRP: P-reg 0x13
            -- CRP register write - MC68030 Long-Format Root Pointer per User's Manual section 9.2.2
            if reg_part = '1' then
              -- CRP HIGH WORD (bits 63-32): L/U[63] + Limit[62:48] + Reserved[47:33] + DT[32]
              -- MC68030 spec: L/U bit 63, Limit bits 62-48, reserved bits 47-33 (zero), DT bit 32
              CRP_H <= (reg_wdat and CRP_HIGH_MASK);

              -- MC68030 MMU Configuration Exception: DT=0 (invalid descriptor)
              -- Per spec: Register is loaded BEFORE exception is taken
              if reg_wdat(1 downto 0) = "00" then
                mmu_config_error <= '1';
               --  -- report "MMU_CONFIG_EXCEPTION: CRP_H DT=00 (invalid descriptor type)" severity warning;
              else
                -- BUG #146: Valid CRP_H write (DT!=00) - clear any previous config error
                mmu_config_error <= '0';
              end if;
            else
              -- CRP LOW WORD (bits 31-0): Table Address[31:4] + Reserved[3:0]
              -- MC68030 spec: Table address bits 31-4, reserved bits 3-0 must be zero
              CRP_L <= (reg_wdat and CRP_LOW_MASK);
              -- BUG #148 FIX: Do NOT clear mmu_config_error on low word write
              -- If high word had DT=00, error must remain latched until explicitly acknowledged
              -- (via valid high word write or TC write with E=0)
            end if;
            -- CRP changes invalidate ATC unless PMOVEFD (flush disable)
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "11000" =>
            -- BUG #15 FIX: MMUSR register - MC68030 MMUSR write-1-to-clear semantics
            -- MC68030 spec: MMUSR is 16-bit (upper 16 bits always read as zero)
            -- Writing '1' to bits 15:13 (fault status bits) and bit 9 (Modified) clears them
            -- Bits 15:13 = Bus Error, Limit Violation, Supervisor Violation
            -- Bit 9 = Modified (also write-1-to-clear per MC68030 spec)
            -- All other bits are read-only and ignore writes
            if reg_wdat(15) = '1' then
              MMUSR(15) <= '0';  -- Clear Bus Error bit
            end if;
            if reg_wdat(14) = '1' then
              MMUSR(14) <= '0';  -- Clear Limit Violation bit
            end if;
            if reg_wdat(13) = '1' then
              MMUSR(13) <= '0';  -- Clear Supervisor Violation bit
            end if;
            if reg_wdat(9) = '1' then
              MMUSR(9) <= '0';  -- Clear Modified bit
            end if;
          when others => null;
          end case;
      end if;
    end if;
  end process;

  -- BUG #83 FIX: Register reads must be COMBINATIONAL, not registered!
  -- The registers (TT0, TT1, TC, etc.) are always valid, so output them
  -- immediately based on reg_sel. Using a registered output caused first
  -- PMOVE MMU->Dn reads to return 0 (stale data).
  -- BUG #178 FIX: Use correct extension word P-register selectors (bits 14-10):
  --   TT0: 00010 (0x02), TT1: 00011 (0x03), TC: 10000 (0x10)
  --   SRP: 10010 (0x12), CRP: 10011 (0x13), MMUSR: 11000 (0x18)
  reg_rdat <= TT0                          when reg_sel = "00010" else
              TT1                          when reg_sel = "00011" else
              TC                           when reg_sel = "10000" else
              SRP_H                        when reg_sel = "10010" and reg_part = '1' else
              SRP_L                        when reg_sel = "10010" and reg_part = '0' else
              CRP_H                        when reg_sel = "10011" and reg_part = '1' else
              CRP_L                        when reg_sel = "10011" and reg_part = '0' else
              X"0000" & MMUSR(15 downto 0) when reg_sel = "11000" else
              (others => '0');

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
    -- MC68030 TIx field decoding:
    -- IMPORTANT: TIx=0 means "terminate table tree at this level" per MC68030 spec
    -- DO NOT substitute defaults - 0 has semantic meaning for table tree termination!
    -- The walker checks idx_bits(level) <= 0 to determine if that level exists
    tia_bits := to_integer(unsigned(TC(15 downto 12)));
    tib_bits := to_integer(unsigned(TC(11 downto 8)));
    tic_bits := to_integer(unsigned(TC(7 downto 4)));
    tid_bits := to_integer(unsigned(TC(3 downto 0)));

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

    -- Page Size (PS) field - MC68030 valid range is 8-15 (1000-1111 binary)
    -- Values 0-7 are RESERVED and should cause MMU configuration exception
    ps_val := to_integer(unsigned(TC(23 downto 20)));

    -- MC68030 Specification compliance check
    if ps_val < 8 then
      -- report "TC_PS_ERROR: Reserved page size value " & integer'image(ps_val) &
             -- " (valid range: 8-15). MC68030 should generate MMU configuration exception." &
             -- " Defaulting to PS=12 (4KB pages) for synthesis compatibility."
       --  -- severity error;
      ps_val := 12; -- Default to 4KB to prevent synthesis errors
    end if;

    page_offset_bits := get_page_offset_bits(ps_val);
    tc_page_size  <= ps_val;
    tc_page_shift <= page_offset_bits;
    
    -- MC68030 Requirement: Sum PS+IS+TIx until first TIx=0 (remaining TIx ignored)
    total_bits := tc_total_bits(TC);
    
    -- MC68030 Constraints validation:
    -- 1. Total bits must equal 32 (only when MMU is enabled - TC.E = 1)
    -- 2. TIA must be > 0 (root table must have at least 1 bit)
    -- 3. If TIB > 0, it must be >= 2 (minimum 4 entries per table)
    -- 4. Page size must be valid (0-7)
    if TC(31) = '1' and total_bits /= 32 then
      -- report "TC_VALIDATION_ERROR: Field sum " & integer'image(total_bits) & " != 32" &
             -- " (IS=" & integer'image(is_bits) &
             -- " TIA=" & integer'image(tia_bits) &
             -- " TIB=" & integer'image(tib_bits) &
             -- " TIC=" & integer'image(tic_bits) &
             -- " TID=" & integer'image(tid_bits) &
             -- " PS_bits=" & integer'image(page_offset_bits) & ")"
       --  -- severity warning;
    end if;
    
    if TC(31) = '1' and tia_bits = 0 then
      -- report "TC_VALIDATION_ERROR: TIA field must be > 0 (root table needs at least 1 bit)"
       --  -- severity warning;
    end if;
    
    if TC(31) = '1' and tib_bits > 0 and tib_bits < 2 then
      -- report "TC_VALIDATION_ERROR: TIB field must be >= 2 when used (minimum 4 table entries)"
       --  -- severity warning;
    end if;

    -- Page size validation already done above with proper error reporting
    -- No need to re-check here
  end process;
  
  -- Output the latched results
  -- BUG #129 FIX: Add combinational bypass for identity translation when MMU disabled
  -- This eliminates the 1-cycle lag that caused cache to sample stale physical address
  -- When MMU is disabled (tc_en='0'), use logical address directly (same cycle)
  -- When MMU is enabled, use registered translation result (allows for page table walks)
  addr_phys     <= addr_log when tc_en = '0' else addr_phys_reg;
  -- BUG #126 V2 FIX: Combinational bypass for cache_inhibit when MMU disabled
  -- Without this, cache_inhibit_reg retains stale value (pmmu_req='0' when MMU off)
  cache_inhibit <= '0' when tc_en = '0' else cache_inhibit_reg;
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
          -- report "DEBUG_REQUEST: Starting translation for addr=0x" & slv_to_hstring(addr_log) &
                 -- " fc=" & slv_to_string(fc) & " rw=" & std_logic'image(rw) &
                 -- " tc_en=" & std_logic'image(tc_en)
           --  -- severity note;
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
            write_protect => '0',        -- No write protect for identity
            modified => '0',             -- No modification tracking for identity
            transparent => '0',          -- Not transparent (MMU disabled)
            level => "000"               -- No table walk for identity translation
          );
          translation_pending <= '0';
        else
          -- MMU enabled - do full translation
          -- Check Transparent Translation first (highest priority)
          ttr_check(TT0, addr_log, fc, is_insn, rw, tmatch0, tci0, twp0);
          ttr_check(TT1, addr_log, fc, is_insn, rw, tmatch1, tci1, twp1);
          -- Debug: Log TTR check results for write protection test address
          if addr_log = x"00002000" then
            -- report "DEBUG_TTR_WP: addr=0x" & slv_to_hstring(addr_log) &
                   -- " TT0=0x" & slv_to_hstring(TT0) &
                   -- " TT1=0x" & slv_to_hstring(TT1) &
                   -- " tmatch0=" & std_logic'image(tmatch0) &
                   -- " tmatch1=" & std_logic'image(tmatch1)
             --  -- severity note;
          end if;
          if tmatch0 = '1' then
            -- TTR0 match - use identity translation with TTR attributes (always successful, no faults)
            addr_phys_reg <= addr_log;  -- Identity mapping
            cache_inhibit_reg <= tci0;
            write_protect_reg <= twp0;
            fault_reg <= '0';
            -- Set successful transparent translation MMUSR with MC68030 format
            fault_status_reg <= encode_mmusr_success(
              write_protect => twp0,     -- WP bit from TTR attributes
              modified => '0',           -- No descriptor access for TTR
              transparent => '1',        -- This IS a transparent translation
              level => "000"             -- No table walk for TTR
            );
            if addr_log = x"00002000" then
             --  -- report "TTR0_STATUS: Setting transparent status for addr=0x" & slv_to_hstring(addr_log) severity note;
            end if;
            -- No walker needed for TTR
          elsif tmatch1 = '1' then
            -- TTR1 match - use identity translation with TTR attributes (always successful, no faults)
           --  -- assert false report "TTR1 HIT: Setting addr_phys to 0x" & slv_to_hstring(addr_log) severity note;
            addr_phys_reg <= addr_log;  -- Identity mapping
            cache_inhibit_reg <= tci1;
            write_protect_reg <= twp1;
            fault_reg <= '0';
            -- Set successful transparent translation MMUSR with MC68030 format
            fault_status_reg <= encode_mmusr_success(
              write_protect => twp1,     -- WP bit from TTR attributes
              modified => '0',           -- No descriptor access for TTR
              transparent => '1',        -- This IS a transparent translation
              level => "000"             -- No table walk for TTR
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
                -- report "DEBUG_ATC_CHECK: addr=0x" & slv_to_hstring(addr_log) &
                       -- " ATC[" & integer'image(i) & "] base=0x" & slv_to_hstring(atc_log_base(i)) &
                       -- " shift=" & integer'image(atc_shift(i)) &
                       -- " aligned=0x" & slv_to_hstring(aligned_addr) &
                       -- " fc_match=" & std_logic'image(atc_fc(i)(0)) & std_logic'image(atc_fc(i)(1)) & std_logic'image(atc_fc(i)(2)) &
                       -- " vs " & std_logic'image(fc(0)) & std_logic'image(fc(1)) & std_logic'image(fc(2))
                 --  -- severity note;
              end if;
              if atc_fc(i) = fc and
                 atc_is_insn(i) = is_insn and
                 aligned_addr = atc_log_base(i) then
                hit := '1';
                hit_idx := i;
                -- Debug: Log ATC hit for failing test addresses
                if addr_log = x"12343000" or addr_log = x"12344000" then
                  -- report "DEBUG_ATC_HIT: addr=0x" & slv_to_hstring(addr_log) &
                         -- " hit ATC[" & integer'image(i) & "] base=0x" & slv_to_hstring(atc_log_base(i)) &
                         -- " shift=" & integer'image(atc_shift(i)) &
                         -- " aligned_addr=0x" & slv_to_hstring(aligned_addr) &
                         -- " fc=" & slv_to_string(fc) & " vs atc_fc=" & slv_to_string(atc_fc(i))
                   --  -- severity note;
                end if;
              end if;
            end if;
          end loop;
          if hit = '1' then
            -- ATC hit - use cached translation but check access violations
            -- But don't overwrite walker faults that are still pending
            if walker_fault = '1' and walker_fault_ack_pending = '1' then
              -- Walker fault is pending - don't overwrite with ATC results
             --  -- report "ATC_SKIP: Skipping ATC processing due to pending walker fault, addr=0x" & slv_to_hstring(addr_log) severity note;
            elsif rw = '0' and atc_attr(hit_idx)(0) = '1' then
              -- Write to write-protected page - generate fault (rw='0' is WRITE)
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '1',                   -- This is a WP fault
                invalid => '0',                         -- Descriptor was valid
                modified => '0',
                transparent => '0',
                level => "011"                          -- Page level (3 bits)
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              -- CRITICAL FIX: Output address even on fault
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);  -- Provide faulting address
              cache_inhibit_reg <= atc_attr(hit_idx)(2);  -- BUG FIX: bit 2 is CI, not bit 1 (M)
              write_protect_reg <= '1';  -- Mark as write-protected
              -- report "WP_FAULT_ATC: Setting fault_reg=1 for WP violation, addr=0x" & slv_to_hstring(addr_log) &
                    --  -- " phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
            elsif fc(2) = '0' and atc_attr(hit_idx)(3) = '0' then
              -- User trying to access supervisor-only page - generate fault
              -- atc_attr(3) = U_ACC = NOT(S): 0 means supervisor-only, 1 means user accessible
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '1',            -- This is a supervisor violation
                write_protect => atc_attr(hit_idx)(0),  -- From cached attributes
                invalid => '0',                         -- Descriptor was valid
                modified => '0',
                transparent => '0',
                level => "011"                          -- Page level (3 bits)
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              -- CRITICAL FIX: Output address even on supervisor fault
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              cache_inhibit_reg <= atc_attr(hit_idx)(2);  -- BUG FIX: bit 2 is CI, not bit 1 (M)
              write_protect_reg <= atc_attr(hit_idx)(0);
              -- report "SUPERVISOR_FAULT_ATC: Setting fault_reg=1 for supervisor violation, addr=0x" & slv_to_hstring(addr_log) &
                    --  -- " phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
            else
              -- Valid access - use cached translation and clear any previous faults
              -- But don't overwrite walker faults that are still pending
              if walker_fault = '1' and walker_fault_ack_pending = '1' then
                -- Walker fault is pending - don't overwrite with successful ATC results
               --  -- report "ATC_SUCCESS_SKIP: Skipping ATC success due to pending walker fault, addr=0x" & slv_to_hstring(addr_log) severity note;
              else
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                -- Debug address calculation for PS=0 test
                if addr_log = x"00001100" then
                  -- report "DEBUG_ATC_CALC: addr=0x" & slv_to_hstring(addr_log) &
                         -- " phys_base=0x" & slv_to_hstring(std_logic_vector(phys_base)) &
                         -- " log_base=0x" & slv_to_hstring(atc_log_base(hit_idx)) &
                         -- " offset=0x" & slv_to_hstring(std_logic_vector(offset)) &
                         -- " phys_result=0x" & slv_to_hstring(std_logic_vector(phys_result))
                   --  -- severity note;
                end if;
                addr_phys_reg <= std_logic_vector(phys_result);
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= atc_attr(hit_idx)(0);
                fault_reg <= '0';
                -- Set successful translation MMUSR with MC68030 format
                fault_status_reg <= encode_mmusr_success(
                  write_protect => atc_attr(hit_idx)(0),   -- WP bit from page attributes
                  modified => atc_attr(hit_idx)(1),        -- M bit from page descriptor
                  transparent => '0',                      -- Not a transparent translation
                  level => "011"                           -- Page translation (3 levels typical)
                );
               --  -- report "ATC_HIT: successful translation, phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
              end if;
            end if;
          else
            -- ATC miss - request walker to start (only if no TTR hit and not already pending)
            if tmatch0 = '0' and tmatch1 = '0' and translation_pending = '0' then
              -- Debug: Log ATC miss for failing test addresses
              if addr_log = x"12343000" or addr_log = x"12344000" then
                -- report "DEBUG_ATC_MISS: addr=0x" & slv_to_hstring(addr_log) &
                       -- " starting walker"
                 --  -- severity note;
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
                -- report "DEBUG_NO_WALKER: addr=0x" & slv_to_hstring(addr_log) &
                       -- " tmatch0=" & std_logic'image(tmatch0) &
                       -- " tmatch1=" & std_logic'image(tmatch1) &
                       -- " translation_pending=" & std_logic'image(translation_pending)
                 --  -- severity note;
              end if;
            end if;
          end if;
          end if; -- TTR check
        end if; -- tc_en = '0' vs '1'
        
      end if; -- req = '1'

      -- Handle PTEST requests - perform translation and update MMUSR
      if ptest_active = '1' then
        -- PTEST request active - perform translation to test page (update MMUSR, don't cache)
        if tc_en = '1' and translation_pending = '0' then
          -- Check Transparent Translation first
          ttr_check(TT0, ptest_addr, ptest_fc, '0', ptest_rw, tmatch0, tci0, twp0);  -- Use PTEST R/W from brief(9)
          ttr_check(TT1, ptest_addr, ptest_fc, '0', ptest_rw, tmatch1, tci1, twp1);  -- Use PTEST R/W from brief(9)

          if tmatch0 = '1' then
            -- TTR0 match - PTEST succeeds with transparent translation
            mmusr_update_value <= encode_mmusr_success(
              write_protect => twp0,
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
          elsif tmatch1 = '1' then
            -- TTR1 match - PTEST succeeds with transparent translation
            mmusr_update_value <= encode_mmusr_success(
              write_protect => twp1,
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
          else
            -- No TTR match - trigger walker to test translation
            saved_addr_log <= ptest_addr;
            saved_fc <= ptest_fc;
            saved_is_insn <= '0';
            saved_rw <= ptest_rw;  -- BUG #17 FIX: PTEST R/W from brief(9): 0=PTESTW(write), 1=PTESTR(read)
            walk_req <= '1';
            translation_pending <= '1';
            -- report "PTEST: Triggered walker for addr=0x" & slv_to_hstring(ptest_addr) &
                  --  -- " fc=" & slv_to_string(ptest_fc) severity note;
          end if;
        end if;
      end if;

      -- Handle PLOAD requests - trigger translation to pre-load ATC
      if pload_active = '1' then
        -- PLOAD request active - perform translation to fill ATC
        if tc_en = '1' and translation_pending = '0' then
          -- Check Transparent Translation first
          ttr_check(TT0, pload_addr, pload_fc, '0', pload_rw, tmatch0, tci0, twp0);  -- Use PLOAD R/W from brief(9)
          ttr_check(TT1, pload_addr, pload_fc, '0', pload_rw, tmatch1, tci1, twp1);  -- Use PLOAD R/W from brief(9)
          
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
              saved_rw <= pload_rw;  -- BUG #17 FIX: PLOAD R/W from brief(9): 0=PLOADW(write), 1=PLOADR(read)
              walk_req <= '1';
              translation_pending <= '1';
              -- report "PLOAD: Triggered walker for addr=0x" & slv_to_hstring(pload_addr) &
                    --  -- " fc=" & slv_to_string(pload_fc) severity note;
            else
              -- ATC hit - PLOAD complete (translation already cached)
              -- report "PLOAD: ATC hit for addr=0x" & slv_to_hstring(pload_addr) &
                    --  -- " hit_idx=" & integer'image(hit_idx) severity note;
            end if;
          else
            -- TTR match - PLOAD complete (no need to cache transparent translations)
           --  -- report "PLOAD: TTR match for addr=0x" & slv_to_hstring(pload_addr) severity note;
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
        -- CRITICAL FIX: On fault, output the faulting logical address
        -- This prevents the CPU from using garbage/uninitialized addresses
        addr_phys_reg <= saved_addr_log;  -- Pass through faulting address
        cache_inhibit_reg <= '1';  -- Inhibit cache on faults
        write_protect_reg <= '1';  -- Protect on faults
        -- Debug: Report walker fault processing with corruption tracking
        -- report "WALKER_FAULT: Setting fault_reg=1 walker_status=0x" & slv_to_hstring(walker_fault_status) &
               -- " status_tmp=0x" & slv_to_hstring(status_tmp) &
               -- " addr=0x" & slv_to_hstring(saved_addr_log) &
               -- " addr_phys_out=0x" & slv_to_hstring(saved_addr_log)
         --  -- severity note;
        -- Acknowledge the fault and track pending state
        walker_fault_ack <= '1';
        walker_fault_ack_pending <= '1';
      elsif walker_completed = '1' then
        -- Walker completed successfully - clear any previous fault status
        -- A successful walker completion means this specific translation succeeded
        
        -- First check if the completed request would have been handled by TTR
        ttr_check(TT0, saved_addr_log, saved_fc, saved_is_insn, saved_rw, tmatch0, tci0, twp0);
        ttr_check(TT1, saved_addr_log, saved_fc, saved_is_insn, saved_rw, tmatch1, tci1, twp1);
        
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
            -- report "ATC_HIT: addr=0x" & slv_to_hstring(saved_addr_log) &
                   -- " fc=" & slv_to_string(saved_fc) &
                   -- " rw=" & std_logic'image(saved_rw) &
                   -- " hit_idx=" & integer'image(hit_idx) &
                   -- " attr=" & slv_to_string(atc_attr(hit_idx)) &
                   -- " base=0x" & slv_to_hstring(atc_phys_base(hit_idx)) &
                   -- " shift=" & integer'image(atc_shift(hit_idx)) &
                   -- " page_size=" & integer'image(atc_page_size(hit_idx))
             --  -- severity note;
              
            -- Walker filled ATC successfully - check access violations for the original request
            -- BUG #17 FIX: saved_rw='0' is WRITE, saved_rw='1' is READ
            if saved_rw = '0' and atc_attr(hit_idx)(0) = '1' then
              -- Write to write-protected page - generate fault
             --  -- report "WP_FAULT: Write to WP page detected" severity note;
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '1',                   -- This is a WP fault
                invalid => '0',                         -- Descriptor was valid
                modified => '0',
                transparent => '0',
                level => "011"                          -- Page level (3 bits)
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              -- CRITICAL FIX: Output address even on write-protect fault
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              cache_inhibit_reg <= atc_attr(hit_idx)(2);  -- BUG FIX: bit 2 is CI, not bit 1 (M)
              write_protect_reg <= '1';
              -- report "WP_FAULT_WALKER: Setting fault_reg=1 for WP violation after walker, addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
            elsif saved_fc(2) = '0' and atc_attr(hit_idx)(3) = '0' then
              -- User trying to access supervisor-only page - generate fault
              -- atc_attr(3) = U_ACC = NOT(S): 0 means supervisor-only, 1 means user accessible
             --  -- report "SUPERVISOR_FAULT: User access to supervisor page detected" severity note;
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '1',            -- This is a supervisor violation
                write_protect => atc_attr(hit_idx)(0),  -- From translated attributes
                invalid => '0',                         -- Descriptor was valid
                modified => '0',
                transparent => '0',
                level => "011"                          -- Page level (3 bits)
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              mmusr_update_req <= '1';
              -- CRITICAL FIX: Output address even on supervisor fault
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              cache_inhibit_reg <= atc_attr(hit_idx)(2);  -- BUG FIX: bit 2 is CI, not bit 1 (M)
              write_protect_reg <= atc_attr(hit_idx)(0);
              -- report "SUPERVISOR_FAULT_WALKER: Setting fault_reg=1 for supervisor violation after walker, addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
            else
              -- Valid access - update outputs and clear faults for successful translation
             --  -- report "VALID_ACCESS: Translation successful" severity note;
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              cache_inhibit_reg <= atc_attr(hit_idx)(2);
              write_protect_reg <= atc_attr(hit_idx)(0);
              fault_reg <= '0';
              -- Set successful translation MMUSR with MC68030 format
              fault_status_reg <= encode_mmusr_success(
                write_protect => atc_attr(hit_idx)(0),   -- WP bit from page attributes
                modified => atc_attr(hit_idx)(1),        -- M bit from page descriptor
                transparent => '0',                      -- Not a transparent translation
                level => "011"                           -- Page translation (3 levels typical)
              );
             --  -- report "VALID_ACCESS: phys=0x" & slv_to_hstring(std_logic_vector(phys_result)) severity note;
            end if;
          else
            -- No ATC hit found after walker completion - this shouldn't happen normally
            -- But clear translation_pending anyway to prevent deadlock
            -- CRITICAL FIX: Output logical address as fallback to prevent garbage addresses
            addr_phys_reg <= saved_addr_log;  -- Pass through logical address as fallback
            cache_inhibit_reg <= '1';  -- Inhibit cache when walker fails to populate ATC
            write_protect_reg <= '0';  -- No protection info available
            -- BUG #142 FIX: Do NOT clear fault_reg if walker just faulted!
            -- walker_fault_ack_pending='1' means walker_fault handler just set fault_reg='1'
            -- Clearing it here would make the fault invisible to the CPU, causing infinite loop
            if walker_fault_ack_pending = '0' then
              fault_reg <= '0';  -- Only clear fault if not a faulted walker completion
            end if;
            -- report "WALKER_COMPLETED: No ATC hit found after walker completion" &
                   -- " walker_fault_ack_pending=" & std_logic'image(walker_fault_ack_pending) &
                  --  -- " addr=0x" & slv_to_hstring(saved_addr_log) severity warning;
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
         --  -- report "FAULT_ACK: Cleared walker fault acknowledgment" severity note;
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
    variable desc_addr_v : std_logic_vector(31 downto 0);  -- Local variable for address calculation
    variable tmatch0, tmatch1 : std_logic;
    variable tci0, twp0, tci1, twp1 : std_logic;
    -- For CRP/SRP limit checking
    variable lu_flag : std_logic;
    variable limit_value : unsigned(14 downto 0);
    variable rp_high : std_logic_vector(31 downto 0);
  begin
    if nreset = '0' then
      for i in 0 to ATC_ENTRIES-1 loop
        atc_valid(i)     <= '0';
        atc_log_base(i)  <= (others => '0');
        atc_phys_base(i) <= (others => '0');
        atc_fc(i)        <= (others => '0');
        atc_is_insn(i)   <= '0';
        atc_shift(i)     <= 12;
        atc_page_size(i) <= 12;  -- MC68030: PS=12 (4KB pages)
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
      walk_page_size <= 12;  -- MC68030: PS=12 (4KB pages)
      walker_fault <= '0';
      walker_fault_status <= (others => '0');
      walker_completed <= '0';
      mem_req     <= '0';
      mem_we      <= '0';
      mem_addr    <= (others => '0');
      mem_wdat    <= (others => '0');
      desc_update_needed <= '0';
      desc_update_data   <= (others => '0');
      walk_limit_valid <= '0';  -- BUG #155: Reset limit tracking
      walk_limit_lu    <= '0';
      walk_limit_value <= (others => '0');
    elsif rising_edge(clk) then
      -- Deadlock-proof state machine - no timeouts needed
      
      case wstate is
        when W_IDLE =>
          -- Don't auto-clear walker_completed here - let translation handler clear it

          -- BUG #149 FIX: Clear walker_fault when acknowledged to prevent pmmu_busy deadlock
          -- Without this, walker_fault stays high forever after a fault, keeping busy='1'
          -- which causes the CPU to hang in ptest1/pload1 waiting for pmmu_busy='0'
          if walker_fault = '1' and walker_fault_ack = '1' then
            walker_fault <= '0';
          end if;

          -- Start page table walk on ATC miss using saved request parameters
          if walk_req = '1' then
            -- Debug: Log walker startup for failing test addresses
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
              -- report "DEBUG_WALKER_START: addr=0x" & slv_to_hstring(saved_addr_log) &
                     -- " fc=" & slv_to_string(saved_fc) & " rw=" & std_logic'image(saved_rw)
               --  -- severity note;
            end if;
            walk_level <= 0;
            walk_vpn  <= saved_addr_log;
            walk_fault <= '0';  -- Clear fault at start of walk
            walk_attr <= (others => '0');
            mem_we <= '0';  -- Clear write enable at start of walk
            desc_update_needed <= '0';  -- Clear descriptor update flag
            walk_limit_valid <= '0';  -- BUG #155: Clear limit tracking at walk start
            walk_supervisor <= '0';  -- BUG #157: Clear cumulative S bit at walk start
            -- Initialize with TC default, will be updated from descriptor
            walk_page_shift <= tc_page_shift;
            walk_page_size  <= tc_page_size;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
            walk_phys_base  <= (others => '0');
            -- Don't clear walker fault signals here - they need to persist until consumed
            -- MC68030 Root Pointer Selection:
            -- Use SRP for supervisor access only when both FC2=1 AND TC.SRE=1
            -- Otherwise use CRP for all accesses
            -- MC68030 Root Pointer: LOW word (bits 31-0) contains table address, HIGH word contains limit/DT
            if saved_fc(2) = '1' and tc_sre = '1' then -- Supervisor with SRE enabled
              walk_addr <= SRP_L(31 downto 4) & "0000"; -- Supervisor Root Pointer (LOW word = table address)
             --  -- report "ROOT_POINTER: Using SRP for supervisor access with SRE=1" severity note;
            else -- User or supervisor without SRE
              walk_addr <= CRP_L(31 downto 4) & "0000"; -- CPU Root Pointer (LOW word = table address)
              if saved_fc(2) = '1' then
               --  -- report "ROOT_POINTER: Using CRP for supervisor access with SRE=0" severity note;
              else
               --  -- report "ROOT_POINTER: Using CRP for user access" severity note;
              end if;
            end if;
            wstate <= W_ROOT;
          end if;
          
        when W_ROOT =>
          -- Read root table descriptor - deadlock-proof design
          table_index := get_table_index(fcl_search_addr(walk_vpn, saved_fc, tc_fcl), walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);

          -- MC68030 Root Pointer Limit Check (only for root level)
          -- CRP_H/SRP_H format: L/U[31], Limit[30:16], Reserved[15:1], DT[0]
          -- Select appropriate root pointer HIGH word based on FC and SRE
          if saved_fc(2) = '1' and tc_sre = '1' then
            rp_high := SRP_H;  -- Supervisor Root Pointer
          else
            rp_high := CRP_H;  -- CPU Root Pointer
          end if;

          -- Extract L/U flag and limit value from HIGH word
          lu_flag := rp_high(31);           -- L/U semantics: 1=lower limit, 0=upper limit
          limit_value := unsigned(rp_high(30 downto 16));  -- Bits 62-48 (LIMIT)

          -- Check if table_index is within bounds based on L/U flag
          if lu_flag = '1' then
            -- Lower limit: table_index must be >= limit
            if to_unsigned(table_index, 15) < limit_value then
              -- Limit violation - generate fault
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '1',  -- This is a limit violation
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '0',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              -- report "LIMIT_VIOLATION: table_index=" & integer'image(table_index) &
                     -- " limit(lower)=" & integer'image(to_integer(limit_value)) &
                     -- " (L/U=1, must be >= limit)" severity note;
              wstate <= W_FAULT;
            end if;
          else
            -- Upper limit: table_index must be <= limit
            if to_unsigned(table_index, 15) > limit_value then
              -- Limit violation - generate fault
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '1',  -- This is a limit violation
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '0',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              -- report "LIMIT_VIOLATION: table_index=" & integer'image(table_index) &
                     -- " limit(upper)=" & integer'image(to_integer(limit_value)) &
                     -- " (L/U=0, must be <= limit)" severity note;
              wstate <= W_FAULT;
            end if;
          end if;

          desc_addr_v := walk_addr(31 downto 4) & "0000"; -- Align to table boundary
          desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));

          -- Debug: Log walker state for failing test addresses
          if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
            -- report "DEBUG_WALKER: W_ROOT addr=0x" & slv_to_hstring(saved_addr_log) &
                   -- " level=" & integer'image(walk_level) &
                   -- " table_index=" & integer'image(table_index) &
                   -- " desc_addr=0x" & slv_to_hstring(desc_addr_v)
             --  -- severity note;
          end if;

          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= desc_addr_v;
            desc_addr_reg <= desc_addr_v;  -- BUG #151 FIX: Save for W_ROOT_LOW to read LOW word at +4
          elsif mem_berr = '1' then
            -- Bus error during table walk - set MMUSR B bit per MC68030 spec
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1',                -- B bit: external BERR during table search
              limit_violation => '0',
              supervisor_violation => '0',
              write_protect => '0',
              invalid => '0',                  -- Not invalid - actual bus error
              modified => '0',
              transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got response - process HIGH word of descriptor
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;  -- Save HIGH word for long format
            mem_req <= '0';
            -- Debug: Log descriptor read for failing test addresses
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
              -- report "DEBUG_W_ROOT_DESC: addr=0x" & slv_to_hstring(saved_addr_log) &
                     -- " descriptor_high=0x" & slv_to_hstring(mem_rdat) &
                     -- " bits_1_0=" & std_logic'image(mem_rdat(1)) & std_logic'image(mem_rdat(0))
               --  -- severity note;
            end if;
            -- Check descriptor validity
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              if saved_addr_log = x"12345000" then
               --  -- report "DEBUG_INVALID: descriptor is invalid (bits 1:0 = 00)" severity note;
              end if;
              walk_desc_is_long <= '0';  -- Clear format flag
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',                -- BUG #153 FIX: B bit is for external BERR only
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',                  -- DT=00: Only I bit should be set per MC68030 spec
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              -- Debug: Track invalid descriptor
              -- report "INVALID_DESC_ROOT: Invalid descriptor at level=" & integer'image(walk_level) &
                     -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
            elsif desc_is_long(mem_rdat) then
              -- Long format (DT=11) - need to read LOW word at addr+4
             --  -- report "W_ROOT: Long-format descriptor detected (DT=11), reading LOW word" severity note;
              walk_desc_is_long <= '1';
              wstate <= W_ROOT_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Early termination - this is a page descriptor (short format, DT=01)
              if saved_addr_log = x"12345000" then
               --  -- report "DEBUG_PAGE: descriptor is page (bits 1:0 = 01)" severity note;
              end if;
              walk_desc_is_long <= '0';  -- Short format
              wstate <= W_PAGE;
            else
              -- Table pointer (short format, DT=10) - continue to next level
              if saved_addr_log = x"12345000" then
               --  -- report "DEBUG_TABLE: descriptor is table pointer (DT=10), continuing to W_PTR1" severity note;
              end if;
              walk_desc_is_long <= '0';  -- Short format
              walk_addr <= mem_rdat(31 downto 4) & "0000";
              walk_level <= walk_level + 1;
              -- BUG #155 FIX: Short format has NO limit field
              walk_limit_valid <= '0';
              wstate <= W_PTR1;
            end if;
          end if;

        when W_ROOT_LOW =>
          -- Read LOW word of long-format descriptor at desc_addr_reg+4
          -- desc_addr_reg was saved in W_ROOT state when memory request was issued
          if mem_req = '0' then
            -- Request LOW word at descriptor address + 4
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
           --  -- report "W_ROOT_LOW: Reading LOW word at addr=0x" & slv_to_hstring(std_logic_vector(unsigned(desc_addr_reg) + 4)) severity note;
          elsif mem_berr = '1' then
            -- Bus error during table walk
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete descriptor
            walk_desc_low <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_ROOT_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;

            -- Now we have both HIGH (walk_desc_high) and LOW (walk_desc_low) words
            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Page descriptor - go to W_PAGE for processing
             --  -- report "W_ROOT_LOW: Long-format page descriptor, continuing to W_PAGE" severity note;
              wstate <= W_PAGE;
            else
              -- Table descriptor - extract address from LOW word and continue
              walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
              walk_level <= walk_level + 1;
              -- BUG #155 FIX: Save limit from long-format table descriptor for next level
              walk_limit_valid <= '1';  -- Long format always has limit
              walk_limit_lu    <= walk_desc_high(31);  -- L/U flag
              walk_limit_value <= unsigned(walk_desc_high(30 downto 16));  -- 15-bit limit
              -- BUG #157 FIX: Accumulate S bit from long-format TABLE descriptor
              -- Per MC68030 spec, S bit only exists in TABLE descriptors, not PAGE descriptors
              walk_supervisor <= walk_supervisor or walk_desc_high(8);
             --  -- report "W_ROOT_LOW: Long-format table descriptor, continuing to W_PTR1" severity note;
              wstate <= W_PTR1;
            end if;
          end if;

        when W_PTR1 =>
          -- Read level 1 table descriptor - deadlock-proof design
          table_index := get_table_index(fcl_search_addr(walk_vpn, saved_fc, tc_fcl), walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));

          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            -- BUG #155 FIX: Check limit from previous level's long-format table descriptor
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                -- Lower limit: table_index must be >= limit
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '0', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                end if;
              else
                -- Upper limit: table_index must be <= limit
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '0', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                end if;
              end if;
            end if;
            -- Only proceed if no limit violation (wstate unchanged means OK)
            if wstate = W_PTR1 then
              if saved_addr_log = x"00400000" or saved_addr_log = x"12345000" then
                -- report "W_PTR1: idx=" & integer'image(table_index) & " addr=0x" & slv_to_hstring(desc_addr_v)
                 --  -- severity note;
              end if;
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;  -- Save for use in W_PTR1_LOW state
            end if;
          elsif mem_berr = '1' then
            -- Bus error during table walk
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got response - process HIGH word of descriptor
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;  -- Save HIGH word for long format
            mem_req <= '0';
            -- Debug: Log descriptor read for Large Page Translation
            if saved_addr_log = x"00400000" or saved_addr_log = x"12345000" then
              -- report "W_PTR1_DESC: addr=0x" & slv_to_hstring(saved_addr_log) &
                     -- " descriptor_high=0x" & slv_to_hstring(mem_rdat) &
                     -- " bits_1_0=" & std_logic'image(mem_rdat(1)) & std_logic'image(mem_rdat(0))
               --  -- severity note;
            end if;
            -- Force a known transition to prevent falling through to "when others"
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              walk_desc_is_long <= '0';  -- Clear format flag
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',                -- BUG #153 FIX: B bit is for external BERR only
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',                  -- DT=00: Only I bit should be set per MC68030 spec
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              -- Debug: Track invalid descriptor
              -- report "INVALID_DESC_PTR1: Invalid descriptor at level=" & integer'image(walk_level) &
                     -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
              -- Debug: Log walker fault for Large Page Translation
              if saved_addr_log = x"00400000" then
                -- report "W_PTR1_FAULT: addr=0x" & slv_to_hstring(saved_addr_log) &
                       -- " invalid descriptor=0x" & slv_to_hstring(mem_rdat) &
                       -- " at level=" & integer'image(walk_level)
                 --  -- severity note;
              end if;
            elsif desc_is_long(mem_rdat) then
              -- Long format (DT=11) - need to read LOW word at addr+4
             --  -- report "W_PTR1: Long-format descriptor detected (DT=11), reading LOW word" severity note;
              walk_desc_is_long <= '1';
              wstate <= W_PTR1_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Page descriptor found (short format)
              walk_desc_is_long <= '0';  -- Short format
              wstate <= W_PAGE;
            elsif tc_idx_bits(2) = 0 then
              -- TIC=0 means W_PTR1 is the final level (MC68030 spec section 9.5.3.2)
              -- DT=10 at final level = short-format indirect descriptor
              walk_desc_is_long <= '0';  -- Short format indirect
              indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address (4-byte aligned)
              indirect_target_long <= '0';  -- BUG #164 FIX: DT=10 -> short-format target
             --  -- report "W_PTR1: Short indirect descriptor detected (DT=10, TIC=0 final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
              wstate <= W_INDIRECT;
            else
              -- Continue to next level (short format table descriptor)
              walk_desc_is_long <= '0';  -- Short format
              walk_addr <= mem_rdat(31 downto 4) & "0000";
              walk_level <= walk_level + 1;
              -- BUG #155 FIX: Short format has NO limit field
              walk_limit_valid <= '0';
              wstate <= W_PTR2;
            end if;
          end if;

        when W_PTR1_LOW =>
          -- Read LOW word of long-format descriptor at desc_addr_reg+4
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
           --  -- report "W_PTR1_LOW: Reading LOW word at addr=0x" & slv_to_hstring(std_logic_vector(unsigned(desc_addr_reg) + 4)) severity note;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete descriptor
            walk_desc_low <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_PTR1_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;

            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Page descriptor
             --  -- report "W_PTR1_LOW: Long-format page descriptor, continuing to W_PAGE" severity note;
              wstate <= W_PAGE;
            elsif tc_idx_bits(2) = 0 then
              -- TIC=0 means W_PTR1 is the final level (MC68030 spec section 9.5.3.2)
              -- DT=11 at final level = long-format indirect descriptor
              -- Target address is in LOW word bits 31:2 (longword aligned)
              indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address
              indirect_target_long <= '1';  -- BUG #164 FIX: DT=11 -> long-format target
             --  -- report "W_PTR1_LOW: Long indirect descriptor (DT=11, TIC=0 final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
              wstate <= W_INDIRECT;
            else
              -- Table descriptor - extract address from LOW word and continue
              walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
              walk_level <= walk_level + 1;
              -- BUG #155 FIX: Save limit from long-format table descriptor for next level
              walk_limit_valid <= '1';  -- Long format always has limit
              walk_limit_lu    <= walk_desc_high(31);  -- L/U flag
              walk_limit_value <= unsigned(walk_desc_high(30 downto 16));  -- 15-bit limit
              -- BUG #157 FIX: Accumulate S bit from long-format TABLE descriptor
              walk_supervisor <= walk_supervisor or walk_desc_high(8);
             --  -- report "W_PTR1_LOW: Long-format table descriptor, continuing to W_PTR2" severity note;
              wstate <= W_PTR2;
            end if;
          end if;

        when W_PTR2 =>
          -- Read level 2 table descriptor - deadlock-proof design
          table_index := get_table_index(fcl_search_addr(walk_vpn, saved_fc, tc_fcl), walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));

          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            -- BUG #155 FIX: Check limit from previous level's long-format table descriptor
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                -- Lower limit: table_index must be >= limit
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '0', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                end if;
              else
                -- Upper limit: table_index must be <= limit
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '0', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                end if;
              end if;
            end if;
            -- Only proceed if no limit violation (wstate unchanged means OK)
            if wstate = W_PTR2 then
              if saved_addr_log = x"00400000" then
                -- report "W_PTR2: idx=" & integer'image(table_index) & " addr=0x" & slv_to_hstring(desc_addr_v)
                 --  severity note;
              end if;
              -- Debug: Log W_PTR2 access for failing test addresses
              if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" then
                -- report "DEBUG_W_PTR2: addr=0x" & slv_to_hstring(saved_addr_log) &
                       -- " level=" & integer'image(walk_level) &
                       -- " table_index=" & integer'image(table_index) &
                       -- " desc_addr=0x" & slv_to_hstring(desc_addr_v)
                 --  severity note;
              end if;
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;  -- Save for use in W_PTR2_LOW state
            end if;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got response - process HIGH word of descriptor
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;  -- Save HIGH word for long format
            mem_req <= '0';
            -- Debug: Log descriptor read for failing test addresses
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" then
              -- report "DEBUG_W_PTR2_DESC: addr=0x" & slv_to_hstring(saved_addr_log) &
                     -- " descriptor_high=0x" & slv_to_hstring(mem_rdat) &
                     -- " bits_1_0=" & std_logic'image(mem_rdat(1)) & std_logic'image(mem_rdat(0))
               --  severity note;
            end if;
            -- Check descriptor validity
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              walk_desc_is_long <= '0';  -- Clear format flag
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',                -- BUG #153 FIX: B bit is for external BERR only
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',                  -- DT=00: Only I bit should be set per MC68030 spec
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              -- Debug: Track invalid descriptor
              -- report "INVALID_DESC_PTR2: Invalid descriptor at level=" & integer'image(walk_level) &
                     -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
              -- Debug: Log walker fault for failing test addresses
              if saved_addr_log = x"12343000" then
                -- report "DEBUG_WALKER_FAULT_PTR2: addr=0x" & slv_to_hstring(saved_addr_log) &
                       -- " invalid descriptor=0x" & slv_to_hstring(mem_rdat) &
                       -- " at level=" & integer'image(walk_level)
                 --  severity note;
              end if;
            elsif desc_is_long(mem_rdat) then
              -- Long format (DT=11) - need to read LOW word at addr+4
             --  -- report "W_PTR2: Long-format descriptor detected (DT=11), reading LOW word" severity note;
              walk_desc_is_long <= '1';
              wstate <= W_PTR2_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Short format page descriptor
              walk_desc_is_long <= '0';  -- Short format
              wstate <= W_PAGE;
            elsif tc_idx_bits(3) = 0 then
              -- TID=0 means W_PTR2 is the final level (MC68030 spec section 9.5.3.2)
              -- DT=10 at final level = short-format indirect descriptor
              walk_desc_is_long <= '0';  -- Short format indirect
              indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address (4-byte aligned)
              indirect_target_long <= '0';  -- BUG #164 FIX: DT=10 -> short-format target
             --  -- report "W_PTR2: Short indirect descriptor detected (DT=10, TID=0 final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
              wstate <= W_INDIRECT;
            else
              -- Short format table descriptor
              walk_desc_is_long <= '0';  -- Short format
              walk_addr <= mem_rdat(31 downto 4) & "0000";
              walk_level <= walk_level + 1;
              -- BUG #155 FIX: Short format has NO limit field
              walk_limit_valid <= '0';
              wstate <= W_PTR3;
            end if;
          end if;

        when W_PTR2_LOW =>
          -- Read LOW word of long-format descriptor at desc_addr_reg+4
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
           --  -- report "W_PTR2_LOW: Reading LOW word at addr=0x" & slv_to_hstring(std_logic_vector(unsigned(desc_addr_reg) + 4)) severity note;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete descriptor
            walk_desc_low <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_PTR2_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;

            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Page descriptor
             --  -- report "W_PTR2_LOW: Long-format page descriptor, continuing to W_PAGE" severity note;
              wstate <= W_PAGE;
            elsif tc_idx_bits(3) = 0 then
              -- TID=0 means W_PTR2 is the final level (MC68030 spec section 9.5.3.2)
              -- DT=11 at final level = long-format indirect descriptor
              -- Target address is in LOW word bits 31:2 (longword aligned)
              indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address
              indirect_target_long <= '1';  -- BUG #164 FIX: DT=11 -> long-format target
             --  -- report "W_PTR2_LOW: Long indirect descriptor (DT=11, TID=0 final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
              wstate <= W_INDIRECT;
            else
              -- Table descriptor - extract address from LOW word and continue
              walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
              walk_level <= walk_level + 1;
              -- BUG #155 FIX: Save limit from long-format table descriptor for next level
              walk_limit_valid <= '1';  -- Long format always has limit
              walk_limit_lu    <= walk_desc_high(31);  -- L/U flag
              walk_limit_value <= unsigned(walk_desc_high(30 downto 16));  -- 15-bit limit
              -- BUG #157 FIX: Accumulate S bit from long-format TABLE descriptor
              walk_supervisor <= walk_supervisor or walk_desc_high(8);
             --  -- report "W_PTR2_LOW: Long-format table descriptor, continuing to W_PTR3" severity note;
              wstate <= W_PTR3;
            end if;
          end if;

        when W_PTR3 =>
          -- Final level - must be page descriptor - deadlock-proof design
          table_index := get_table_index(fcl_search_addr(walk_vpn, saved_fc, tc_fcl), walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));

          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            -- BUG #155 FIX: Check limit from previous level's long-format table descriptor
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                -- Lower limit: table_index must be >= limit
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '0', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                end if;
              else
                -- Upper limit: table_index must be <= limit
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '0', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                end if;
              end if;
            end if;
            -- Only proceed if no limit violation (wstate unchanged means OK)
            if wstate = W_PTR3 then
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;  -- Save for use in W_PTR3_LOW state
            end if;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got response - process HIGH word of descriptor
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;  -- Save HIGH word for long format
            mem_req <= '0';
            if mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor - fault immediately
              walk_desc_is_long <= '0';  -- Clear format flag
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',                -- BUG #153 FIX: B bit is for external BERR only
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',                  -- DT=00: Only I bit should be set per MC68030 spec
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              -- Debug: Track invalid descriptor
              -- report "INVALID_DESC_PTR3: Invalid descriptor at level=" & integer'image(walk_level) &
                     -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
            elsif desc_is_long(mem_rdat) then
              -- Long format (DT=11) - need to read LOW word at addr+4
             --  -- report "W_PTR3: Long-format descriptor detected (DT=11), reading LOW word" severity note;
              walk_desc_is_long <= '1';
              wstate <= W_PTR3_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Short format page descriptor
              walk_desc_is_long <= '0';  -- Short format
              wstate <= W_PAGE;
            else
              -- DT=10 at final level = short-format indirect descriptor (MC68030 spec section 9.5.3.2)
              -- The descriptor points to another descriptor (the target) that will be used
              -- Target address is in bits 31:2 (must be 4-byte aligned)
              walk_desc_is_long <= '0';  -- Short format indirect
              indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address (4-byte aligned)
              indirect_target_long <= '0';  -- BUG #164 FIX: DT=10 -> short-format target
             --  -- report "W_PTR3: Short indirect descriptor detected (DT=10), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
              wstate <= W_INDIRECT;
            end if;
          end if;

        when W_PTR3_LOW =>
          -- Read LOW word of long-format descriptor at desc_addr_reg+4
          -- At final level with DT=11, this is a long-format indirect descriptor (MC68030 spec 9.5.3.2)
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
           --  -- report "W_PTR3_LOW: Reading LOW word at addr=0x" & slv_to_hstring(std_logic_vector(unsigned(desc_addr_reg) + 4)) severity note;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process
            walk_desc_low <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_PTR3_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;

            -- At final level with DT=11, this is a LONG INDIRECT descriptor
            -- Target address is in LOW word bits 31:2 (longword aligned)
            -- Note: walk_desc_high has DT=11 (that's how we got here from W_PTR3)
            indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address
            indirect_target_long <= '1';  -- BUG #164 FIX: DT=11 -> long-format target
           --  -- report "W_PTR3_LOW: Long indirect descriptor, target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
            wstate <= W_INDIRECT;
          end if;

        when W_INDIRECT =>
          -- Fetch target descriptor from indirect descriptor pointer (MC68030 spec 9.5.3.2)
          -- Target descriptor is always 4 bytes (short format page descriptor expected)
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= indirect_addr;
            desc_addr_reg <= indirect_addr;  -- BUG #152 FIX: Save for W_UPDATE_DESC U/M bit writeback
           --  -- report "W_INDIRECT: Fetching target descriptor at addr=0x" & slv_to_hstring(indirect_addr) severity note;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got target descriptor - validate it
            mem_req <= '0';
           --  -- report "W_INDIRECT: Got target descriptor=0x" & slv_to_hstring(mem_rdat) severity note;

            -- Check target descriptor type - must be page (DT=01)
            -- MC68030: Nested indirect (target DT=10/11) causes bus error
            if mem_rdat(1 downto 0) = "01" then
              -- Valid page descriptor - check if short or long format target
              walk_desc_high <= mem_rdat;
              if indirect_target_long = '0' then
                -- BUG #164: Short-format target - done, proceed to W_PAGE
                walk_desc <= mem_rdat;
                walk_desc_is_long <= '0';
                wstate <= W_PAGE;
              else
                -- BUG #164 FIX: Long-format target - need LOW word
                walk_desc_is_long <= '1';
                wstate <= W_INDIRECT_LOW;
              end if;
            elsif mem_rdat(1 downto 0) = "00" then
              -- Invalid descriptor (DT=00)
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',                -- BUG #153 FIX: B bit is for external BERR only
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',                  -- DT=00: Only I bit should be set
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
             --  -- report "W_INDIRECT: Invalid target descriptor (DT=00)" severity note;
              wstate <= W_FAULT;
            else
              -- Nested indirect (DT=10 or DT=11) - invalid per MC68030 spec
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',                -- BUG #153 FIX: B bit is for external BERR only
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',                  -- Nested indirect sets I bit per MC68030 spec
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
             --  -- report "W_INDIRECT: Nested indirect descriptor - invalid" severity note;
              wstate <= W_FAULT;
            end if;
          end if;

        when W_INDIRECT_LOW =>
          -- BUG #164 FIX: Read LOW word of long-format target page descriptor
          -- Per MC68030 spec 9.5.3.2: DT=11 indirect -> long-format page descriptor target
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(indirect_addr) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word of long-format page descriptor target
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;  -- For W_PAGE: walk_desc has LOW word for address extraction
            mem_req <= '0';
            -- Proceed to W_PAGE with complete long-format page descriptor
            wstate <= W_PAGE;
          end if;

        when W_PAGE =>
          -- Process page descriptor and validate completely
          if not desc_valid(walk_desc) then
            -- Invalid page descriptor (DT=00)
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',                -- BUG #153 FIX: B bit is for external BERR only
              limit_violation => '0',
              supervisor_violation => '0',
              write_protect => '0',
              invalid => '1',                  -- DT=00: Only I bit should be set per MC68030 spec
              modified => '0',
              transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            -- Debug: Track invalid descriptor
            -- report "INVALID_DESC_PAGE: Invalid page descriptor at level=" & integer'image(walk_level) &
                   -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                  --  -- " desc=0x" & slv_to_hstring(walk_desc) severity note;
            wstate <= W_FAULT;
          elsif saved_fc(2) = '0' and walk_supervisor = '1' then
            -- BUG #157 FIX: Supervisor violation check uses cumulative S bit from TABLE descriptors
            -- Per MC68030 spec: S bit only exists in TABLE descriptors, not PAGE descriptors
            -- User code (FC2=0) cannot access pages reached through supervisor-only tables
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',
              limit_violation => '0',
              supervisor_violation => '1',     -- This is a supervisor violation
              write_protect => walk_desc_high(2),   -- Include WP from page descriptor (same position in both formats)
              invalid => '0',                  -- Descriptor is valid
              modified => '0',
              transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif saved_rw = '0' and walk_desc_high(2) = '1' then
            -- Write protection violation - write to write-protected page (saved_rw='0' is WRITE)
            -- WP is at bit 2 in both short and long formats
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',
              limit_violation => '0',
              supervisor_violation => '0',
              write_protect => '1',            -- This is a write protection fault
              invalid => '0',                  -- Descriptor is valid
              modified => '0',
              transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
           --  -- report "WP_FAULT_WALKER: Write to WP page detected during walk, addr=0x" & slv_to_hstring(saved_addr_log) severity note;
          else
            -- MC68030: Page size is ALWAYS from TC register, never from descriptor
            -- Descriptor bits 3:2 are U (Used) and WP (Write Protect), NOT page size
            walk_page_shift <= tc_page_shift;
            walk_page_size  <= tc_page_size;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
            -- Extract physical address based on descriptor format
            if walk_desc_is_long = '1' then
              -- Long format: page address from LOW word bits 31-8
              walk_phys_base <= walk_desc_low(31 downto 8) & x"00";
            else
              -- Short format: page address from HIGH word bits 31-8
              walk_phys_base <= walk_desc_high(31 downto 8) & x"00";
            end if;
            -- Extract attributes - bit positions are same in both formats
            -- BUG #157 FIX: U_ACC uses cumulative S bit from TABLE descriptors, not page descriptor
            walk_attr(3) <= NOT walk_supervisor; -- U_ACC = NOT(S): 1=user accessible, 0=supervisor-only
            walk_attr(2) <= walk_desc_high(6); -- Cache inhibit (CI)
            walk_attr(1) <= walk_desc_high(4); -- Modified (M)
            walk_attr(0) <= walk_desc_high(2); -- Write protect (WP)
            -- G bit (Global) is at bit 10 in long-format descriptors only
            -- Short-format has no G bit, so non-global by default
            if walk_desc_is_long = '1' then
              walk_global <= walk_desc_high(10);  -- G bit for PFLUSHAN semantics
            else
              walk_global <= '0';  -- Short format = non-global
            end if;
            walk_fault <= '0';

            -- Debug: Log attribute extraction for long-format descriptors
            if walk_desc_is_long = '1' then
              -- report "W_PAGE: Long-format descriptor, S=" & std_logic'image(get_supervisor_bit(walk_desc_high, walk_desc_is_long)) &
                     -- " CI=" & std_logic'image(walk_desc_high(6)) &
                     -- " M=" & std_logic'image(walk_desc_high(4)) &
                     -- " WP=" & std_logic'image(walk_desc_high(2))
               --  severity note;
            end if;

            -- MC68030 Issue #3/#4: U (Used) and M (Modified) bit tracking
            -- U bit (bit 3): Set on any page access if not already set
            -- M bit (bit 4): Set on write access if not already set
            -- Note: These bits are in walk_desc_high for both short and long formats
            if walk_desc_high(3) = '0' or (saved_rw = '0' and walk_desc_high(4) = '0') then
              -- Need to update descriptor with U/M bits
              desc_update_needed <= '1';
              -- Prepare updated descriptor: set U bit, and M bit if write
              desc_update_data <= walk_desc_high(31 downto 5) &
                                  (walk_desc_high(4) or (not saved_rw)) &  -- M bit: set if write (saved_rw='0')
                                  '1' &  -- U bit: always set
                                  walk_desc_high(2 downto 0);
              wstate <= W_UPDATE_DESC;
            else
              -- U and M bits already set appropriately, go straight to fill
              wstate <= W_FILL;
            end if;
          end if;

        when W_UPDATE_DESC =>
          -- Write back descriptor with U/M bits set (MC68030 Issue #3/#4)
          -- desc_addr_reg holds the address of the page descriptor (HIGH word)
          -- desc_update_data holds the updated descriptor value
          if mem_req = '0' then
            mem_req <= '1';
            mem_we <= '1';  -- Write operation
            mem_addr <= desc_addr_reg;  -- Address of descriptor to update
            mem_wdat <= desc_update_data;  -- Updated descriptor with U/M bits set
          elsif mem_berr = '1' then
            -- Bus error during U/M bit write
            mem_req <= '0';
            mem_we <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '0', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Write completed, proceed to fill ATC
            mem_req <= '0';
            mem_we <= '0';
            desc_update_needed <= '0';
            -- Update walk_desc_high with the written values for ATC fill
            -- This ensures the M bit is reflected in the ATC entry
            walk_attr(1) <= desc_update_data(4);  -- Update M bit in walk_attr
            wstate <= W_FILL;
          end if;

        when W_FILL =>
          -- Fill ATC with translation result
          atc_log_base(atc_rr)  <= walk_log_base;
          atc_phys_base(atc_rr) <= walk_phys_base;
          atc_shift(atc_rr)     <= walk_page_shift;
          atc_page_size(atc_rr) <= walk_page_size;
          atc_attr(atc_rr)      <= walk_attr(3 downto 0);
          atc_fc(atc_rr)        <= saved_fc;
          atc_is_insn(atc_rr)   <= saved_is_insn;
          atc_global(atc_rr)    <= walk_global;  -- G bit for PFLUSHAN semantics
          atc_valid(atc_rr)     <= '1';
          -- Debug: Log ATC fill for large page test
          if saved_addr_log = x"00400000" then
            -- report "DEBUG_ATC_FILL: addr=0x" & slv_to_hstring(saved_addr_log) &
                   -- " filling ATC[" & integer'image(atc_rr) & "]" &
                   -- " shift=" & integer'image(walk_page_shift) &
                   -- " page_size=" & integer'image(walk_page_size)
             --  severity note;
          end if;
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
          -- report "WALKER_COMPLETED: addr=0x" & slv_to_hstring(saved_addr_log) & 
                 -- " fc=" & slv_to_string(saved_fc) & 
                 -- " rw=" & std_logic'image(saved_rw) &
                 -- " desc=0x" & slv_to_hstring(walk_desc) &
                 -- " attr=" & slv_to_string(walk_attr) &
                 -- " fault=" & std_logic'image(walk_fault)
           --  severity note;
          
          wstate <= W_IDLE;
          
        when W_FAULT =>
          -- Page fault occurred - fault status already set in previous state
          -- Hold walker_fault signal until main process acknowledges it
          -- Don't clear walker_fault here - let main process clear it when consumed
         --  -- report "W_FAULT: Setting walker_completed=1 with fault status=0x" & slv_to_hstring(walker_fault_status) severity note;
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
        -- MC68030 PFLUSH variants:
        -- pflush_mode(12:8) = pmmu_brief(12:8) determines flush type:
        -- Bits 12-10 = MODE:
        --   001 = PFLUSHA/PFLUSHAN (flush all, A bit in bit 9)
        --   100 = PFLUSH FC,MASK (flush by FC, no EA)
        --   110 = PFLUSH FC,MASK,<ea> (flush by FC with EA)
        -- Bit 9 = A/N: 0=flush all, 1=flush all except global (for MODE=001)
        -- Bit 8 = reserved (0)

        if pflush_mode(12 downto 10) = "001" and pflush_mode(9) = '0' then
          -- PFLUSHA - flush all ATC entries (MODE=001, A=0)
          for i in 0 to ATC_ENTRIES-1 loop
            atc_valid(i) <= '0';
          end loop;
        elsif pflush_mode(12 downto 10) = "001" and pflush_mode(9) = '1' then
          -- PFLUSHAN - flush all non-global entries per MC68030 spec (MODE=001, A=1)
          -- Global pages (G bit = 1) survive PFLUSHAN
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_global(i) = '0' then
              atc_valid(i) <= '0';  -- Only flush non-global entries
            end if;
          end loop;
        else
          -- PFLUSH FC,MASK or PFLUSH FC,MASK,<ea> - flush by FC (with optional EA)
          -- MODE=100: PFLUSH FC,MASK (no EA) or PFLUSHN FC,MASK
          -- MODE=110: PFLUSH FC,MASK,<ea> or PFLUSHN FC,MASK,<ea>
          -- pflush_mode(9) = N bit: 0=flush all, 1=flush only non-global
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              -- Check if this entry matches the flush criteria
              if atc_fc(i) = pflush_fc and align_addr(pflush_addr, atc_shift(i)) = atc_log_base(i) then
                -- Check N bit (bit 9 of extension word = pflush_mode(9))
                if pflush_mode(9) = '0' or atc_global(i) = '0' then
                  -- N=0: flush regardless of global bit
                  -- N=1: only flush non-global entries
                  atc_valid(i) <= '0';
                end if;
              end if;
            end if;
          end loop;
        end if;
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
      reg_we_prev <= '0';  -- BUG #16 FIX
      reg_re_prev <= '0';  -- BUG #16 FIX
    elsif rising_edge(clk) then
      -- Update previous values for edge detection
      ptest_req_prev <= ptest_req;
      pflush_req_prev <= pflush_req;
      pload_req_prev <= pload_req;
      reg_we_prev <= reg_we;  -- BUG #16 FIX
      reg_re_prev <= reg_re;  -- BUG #16 FIX
      
      -- PTEST: Set flag on rising edge only (prevents multiple triggers)
      if ptest_req = '1' and ptest_req_prev = '0' then
        ptest_update_mmusr <= '1';
      else
        ptest_update_mmusr <= '0';
      end if;
      
      -- PFLUSH: Edge detection and parameter capture
      if pflush_req = '1' and pflush_req_prev = '0' then
        pflush_active <= '1';
        pflush_addr <= pmmu_addr;
        pflush_fc <= pmmu_fc;
        pflush_mode <= pmmu_brief(12 downto 8);  -- Capture PFLUSH mode from brief word
        pflush_clear_atc <= '1';
      elsif pflush_active = '1' then
        -- PFLUSH operation active - clear after one cycle
        pflush_active <= '0';
        pflush_clear_atc <= '0';
      else
        pflush_clear_atc <= '0';
      end if;
      
      -- PLOAD: Edge detection and implementation
      if pload_req = '1' and pload_req_prev = '0' then
        -- PLOAD rising edge detected - activate page pre-loading
        -- BUG #14 FIX: MC68030 spec - pmmu_brief(9): 0=PLOADW (write), 1=PLOADR (read)
        -- rw signal: 0=write, 1=read, so direct assignment (no NOT)
        pload_active <= '1';
        pload_addr <= pmmu_addr;
        pload_fc <= pmmu_fc;
        pload_rw <= pmmu_brief(9);
        -- PLOADR vs PLOADW affects access permissions tested during load
      elsif pload_active = '1' then
        -- PLOAD operation active - clear after one cycle
        pload_active <= '0';
      end if;
    end if;
  end process;

  -- MMU Configuration Exception output
  mmu_config_err <= mmu_config_error;

end rtl;
