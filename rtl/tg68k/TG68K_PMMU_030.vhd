-- TG68K_PMMU_030.vhd
-- MC68030 PMMU Implementation with full page table walker connected to real memory
-- Features: TC/CRP/SRP/TT0/TT1/MMUSR registers, 22-entry ATC, multi-level page tables,
--           transparent translation, fault detection, PMOVE/PTEST/PFLUSH/PLOAD instructions,
--           real page table walking via memory arbiter in cpu_wrapper.v
-- The walker now reads actual descriptors from memory for non-identity address translation.
--
-- RMC / atomic table-search deviation from MC68030 UM 9.5.2:
--   The spec requires RMC asserted for the entire duration of a table search so
--   that no other bus master can interleave. This implementation does not drive
--   a bus-wide RMC lock. The CPU side is handled: while 'walker_active' is high
--   in cpu_wrapper.v, CPU memory access is suppressed (ramsel gated by
--   ~walker_active, line 106). Other Amiga chip-bus masters (Agnus/Paula/
--   Blitter) can still use their normal DMA slots against chip RAM between
--   consecutive walker descriptor reads. In practice, AmigaOS places page
--   tables in fast RAM, which the chipset masters do not access, so the walker
--   has de-facto exclusive access to page-table memory across the walk. This
--   deviation is known and latent; fixing it would require stalling chipset
--   DMA during any table walk, which would corrupt display/audio output.
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
    rmw            : in  std_logic := '0'; -- read-modify-write bus sequence (TAS/CAS/CAS2)
    fc             : in  std_logic_vector(2 downto 0);
    addr_log       : in  std_logic_vector(31 downto 0);
    addr_phys      : out std_logic_vector(31 downto 0);
    cache_inhibit  : out std_logic;
    write_protect  : out std_logic;
    fault          : out std_logic;
    fault_status   : out std_logic_vector(31 downto 0);
    fault_addr     : out std_logic_vector(31 downto 0);  -- BUG #415: Faulting logical address
    fault_fc       : out std_logic_vector(2 downto 0);   -- BUG #414: FC at fault time
    fault_rw       : out std_logic;                       -- BUG #414: RW at fault time (1=read, 0=write)
    fault_is_insn  : out std_logic;                       -- BUG #414: Instruction fetch flag at fault time
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
    mmu_config_ack : in  std_logic;   -- Acknowledgment from kernel when trap is taken
    -- PTEST Support
    ptest_desc_addr : out std_logic_vector(31 downto 0); -- Physical address of last descriptor (for A-bit)
    -- Debug
    debug_mmusr : out std_logic_vector(15 downto 0);
    -- SignalTap debug ports
    debug_tc  : out std_logic_vector(31 downto 0);
    debug_tt0 : out std_logic_vector(31 downto 0);
    debug_tt1 : out std_logic_vector(31 downto 0);
    debug_crp_hi : out std_logic_vector(31 downto 0);
    debug_crp_lo : out std_logic_vector(31 downto 0);
    debug_srp_hi : out std_logic_vector(31 downto 0);
    debug_srp_lo : out std_logic_vector(31 downto 0);
    debug_wstate : out std_logic_vector(4 downto 0);
    debug_atc_buserr : out std_logic_vector(21 downto 0);
    debug_atc_valid  : out std_logic_vector(21 downto 0);
    debug_fault_status : out std_logic_vector(15 downto 0);
    debug_saved_addr   : out std_logic_vector(31 downto 0);
    debug_walk_desc_addr : out std_logic_vector(31 downto 0);
    debug_walk_desc_data : out std_logic_vector(31 downto 0);
    -- Sticky per-level descriptor captures (HIGH word + descriptor address)
    debug_ptr1_desc_addr : out std_logic_vector(31 downto 0);
    debug_ptr1_desc_data : out std_logic_vector(31 downto 0);
    debug_ptr2_desc_addr : out std_logic_vector(31 downto 0);
    debug_ptr2_desc_data : out std_logic_vector(31 downto 0);
    debug_ptr3_desc_addr : out std_logic_vector(31 downto 0);
    debug_ptr3_desc_data : out std_logic_vector(31 downto 0);
    debug_saved_fc       : out std_logic_vector(2 downto 0);
    debug_pending_flags  : out std_logic_vector(15 downto 0);
    -- BUG #446: sticky latch — set on any PMOVE with an undecoded reg_sel.
    -- Useful for SignalTap / post-run forensics: real MC68030 ignores such
    -- writes, and silent ignore hid software bugs in prior triage.
    debug_illegal_reg_sel : out std_logic;
    -- MC68030 UM 9.2.3 MMUDIS: when asserted, the MMU is prevented from searching
    -- the ATC and the execution unit from performing table searches. Logical
    -- addresses pass through as physical addresses. TTRs continue to operate
    -- (MMUDIS does not affect transparent translation). Defaulted to '0' because
    -- the Amiga platform has no MMUDIS source.
    mmudis              : in  std_logic := '0';
    cpu_reset           : in  std_logic := '0'
  );
end TG68K_PMMU_030;
architecture rtl of TG68K_PMMU_030 is
  function slv_to_hex(value : std_logic_vector) return string is
    constant hex_chars : string := "0123456789ABCDEF";
    variable result : string(1 to value'length/4);
    variable nibble : std_logic_vector(3 downto 0);
  begin
    for i in 0 to (value'length/4 - 1) loop
      nibble := value(value'length - 1 - i*4 downto value'length - 4 - i*4);
      result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
    end loop;
    return result;
  end function;
  -- MC68030 PMMU Control Registers
  -- All registers are PMOVE-only per the MC68030 User's Manual (sections 9.7
  -- and 9.8). MOVEC access to these registers is NOT defined on MC68030; the
  -- kernel MOVEC whitelist correctly excludes them, and MOVEC to TC/TT0/TT1/
  -- MMUSR traps as privilege violation.
  -- Implemented: TC, TT0, TT1, CRP (64-bit), SRP (64-bit), MMUSR
  -- Not implemented: CAL, VAL, SCC, AC (removed — unused by Amiga software)
  
  signal TC     : std_logic_vector(31 downto 0); -- Translation Control (EN, PS, IS, TIA-TID)
  signal CRP_H  : std_logic_vector(31 downto 0); -- CPU Root Pointer high 32 bits
  signal CRP_L  : std_logic_vector(31 downto 0); -- CPU Root Pointer low 32 bits (64-bit total)
  signal SRP_H  : std_logic_vector(31 downto 0); -- Supervisor Root Pointer high 32 bits
  signal SRP_L  : std_logic_vector(31 downto 0); -- Supervisor Root Pointer low 32 bits (64-bit total)
  signal TT0    : std_logic_vector(31 downto 0); -- Transparent Translation Register 0
  signal TT1    : std_logic_vector(31 downto 0); -- Transparent Translation Register 1
  signal MMUSR  : std_logic_vector(15 downto 0); -- MMU Status Register (MC68030 UM 9.7.4: architecturally 16 bits)
  -- NOTE: CAL, VAL, SCC, AC registers are defined in MC68030 but not implemented
  -- They were removed as unused signals to avoid synthesis warnings
  -- Internal
  signal tc_en  : std_logic; -- translation enable bit (TC[31] in some docs; keep flexible here)
  signal tc_table_config_valid : std_logic; -- Valid TC fields for PMMU table-search instructions, independent of TC.E
  -- Walker descriptor address register (must persist across clock cycles for W_*_LOW states)
  signal desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_desc_return_pending : std_logic := '0';
  signal last_mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
  -- MC68030 register write masks (ENABLED for spec compliance)
  -- TC register mask: preserve E(31), SRE(25), FCL(24), and all field bits (23-0), clear reserved bits 30-26
  -- Note: Bit 23 (PS MSB) is forced to 1 in write logic since all valid PS values (8-15) have MSB=1
  constant TC_WRITE_MASK : std_logic_vector(31 downto 0) := "10000011111111111111111111111111";
  -- TTR register mask (MC68030 User's Manual section 9.2.6):
  -- Reserved bits 14-11, 7, 3 are "must be programmed as 0" by spec, but the
  -- hardware preserves whatever software writes and reads it back unchanged.
  -- WinUAE follows the same convention: cpummu30.cpp:436 stores the raw
  -- longword; only mmu030_decode_tt() extracts the documented fields. Our
  -- ttr_check() procedure also consults only the documented bits, so storing
  -- the full 32-bit value is functionally equivalent and matches WinUAE /
  -- real-hardware behavior.
  constant TTR_WRITE_MASK : std_logic_vector(31 downto 0) := (others => '1');
  -- CRP/SRP HIGH mask: preserve L/U (31), Limit (30-16), DT (1:0); clear reserved (15-2)
  -- HIGH word format: L/U[63] + Limit[62:48] + Reserved[47:34] + DT[33:32]
  constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := "11111111111111110000000000000011"; -- 0xFFFF0003
  -- CRP/SRP LOW mask: preserve table address (31-4), clear reserved bits (3-0)
  -- LOW word format: Table Address[31:4] + Reserved[3:0]
  constant CRP_LOW_MASK : std_logic_vector(31 downto 0) := "11111111111111111111111111110000"; -- 0xFFFFFFF0
  
  -- Combinational TTR match signals for zero-latency bypass
  -- BUG #371 FIX: When MMU is first enabled, addr_phys_reg is stale (registered).
  -- TTR transparent translations are identity (phys=log), so we can bypass the register.
  signal ttr0_match_comb : std_logic;
  signal ttr1_match_comb : std_logic;
  signal ttr0_ci_comb    : std_logic;
  signal ttr0_wp_comb    : std_logic;
  signal ttr1_ci_comb    : std_logic;
  signal ttr1_wp_comb    : std_logic;
  signal atc_success_comb : std_logic;
  signal atc_phys_comb    : std_logic_vector(31 downto 0);
  signal atc_ci_comb      : std_logic;
  signal atc_wp_comb      : std_logic;
  -- BUG #416: Track which addr_log/fc produced the current addr_phys_reg.
  -- ATC translations update addr_phys_reg on rising_edge, but addr_log changes
  -- combinationally after the Kernel's assignment in the same edge. This creates
  -- a 1-cycle window where addr_phys_reg is stale (holds translation of the OLD
  -- addr_log). Without gating, the bus starts an access with the wrong physical
  -- address. The busy signal compares these against the current combinational
  -- addr_log/fc to suppress bus access during the stale window.
  signal translated_addr    : std_logic_vector(31 downto 0) := (others => '0');
  signal translated_fc      : std_logic_vector(2 downto 0) := (others => '0');
  signal translated_rw      : std_logic := '1';
  -- Translation context generation. Incremented on MMU register writes that can
  -- change address translation even when addr_log/fc/rw are unchanged.
  signal xlat_cfg_seq       : unsigned(7 downto 0) := (others => '0');
  signal translated_cfg_seq : unsigned(7 downto 0) := (others => '0');
  signal xlat_cfg_seq_seen  : unsigned(7 downto 0) := (others => '0');
  signal xlat_cfg_seq_walk_seen : unsigned(7 downto 0) := (others => '0');
  -- Translation result latches
  signal addr_phys_reg      : std_logic_vector(31 downto 0) := (others => '0');
  signal cache_inhibit_reg  : std_logic := '0';
  signal write_protect_reg  : std_logic := '0';
  signal fault_reg          : std_logic := '0';
  signal fault_status_reg   : std_logic_vector(31 downto 0) := (others => '0');
  signal fault_addr_reg     : std_logic_vector(31 downto 0) := (others => '0');  -- BUG #415: Faulting logical address
  signal fault_fc_reg       : std_logic_vector(2 downto 0) := (others => '0');   -- BUG #414: FC at fault time
  signal fault_rw_reg       : std_logic := '1';                                   -- BUG #414: RW at fault time
  signal fault_is_insn_reg  : std_logic := '0';                                   -- BUG #414: Instruction fetch flag
  signal fault_current_req_match : std_logic := '0';
  
  -- Debug: sticky fault status latch (captures MMUSR at exact moment of fault)
  signal debug_fault_status_latch : std_logic_vector(15 downto 0) := (others => '0');
  signal debug_fault_status_valid : std_logic := '0';  -- Set once, never cleared (sticky)

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
  signal req_prev           : std_logic := '0';
  signal translation_pending : std_logic := '0';
  -- ATC (Address Translation Cache), 22 entries per MC68030 hardware
  -- Uses pseudo-LRU replacement: MRU bit per entry, reset all when full
  constant ATC_ENTRIES : integer := 22;
  type atc_attr_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(3 downto 0);  -- {U_ACC, CI, M, WP} where U_ACC=NOT(S)=user accessible
  type atc_val_t  is array(0 to ATC_ENTRIES-1) of std_logic;
  type atc_base_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(31 downto 0);
  type atc_fc_t   is array(0 to ATC_ENTRIES-1) of std_logic_vector(2 downto 0);
  -- atc_isn_t removed (was for atc_is_insn, now removed)
  -- ATC shift stores the effective page shift for the translation that populated the entry.
  -- This can exceed TC.PS when a page descriptor terminates the walk early (large pages).
  type atc_shift_t is array(0 to ATC_ENTRIES-1) of integer range 0 to 32;
  type atc_page_size_t is array(0 to ATC_ENTRIES-1) of integer range 0 to 15; -- MC68030 PS field value (8-15)
  type atc_level_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(2 downto 0); -- BUG #412: walk level for MMUSR N field
  type atc_fault_status_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(15 downto 0); -- Cached MMUSR fault class for ATC fault entries
  signal atc_log_base : atc_base_t;
  signal atc_phys_base: atc_base_t;
  signal atc_attr  : atc_attr_t;
  signal atc_valid : atc_val_t;
  signal atc_fc    : atc_fc_t;
  -- atc_is_insn removed: FC already encodes instruction vs data (FC=2/6 vs FC=1/5)
  signal atc_shift : atc_shift_t;
  signal atc_page_size : atc_page_size_t;
  signal atc_level : atc_level_t;  -- BUG #412: walk level count for MMUSR N field
  signal atc_mru   : atc_val_t;  -- Pseudo-LRU: MRU bit per entry (1=recently used)
  signal atc_buserr : atc_val_t;  -- Cached fault entry present in ATC; fault class comes from atc_fault_status
  signal atc_fault_status : atc_fault_status_t;
  signal atc_mru_update_req : std_logic := '0';  -- Request MRU update from translation process
  signal atc_mru_update_idx : integer range 0 to ATC_ENTRIES-1 := 0;  -- Index to update
  signal atc_mbit_inval_req : std_logic := '0';  -- Request ATC invalidation for M-bit miss (per WinUAE)
  signal atc_mbit_inval_idx : integer range 0 to ATC_ENTRIES-1 := 0;  -- Index to invalidate
  signal translated_match_dbg : std_logic;
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
  signal tc_config_check_pending : std_logic := '0';
  signal tc_config_check_value   : std_logic_vector(31 downto 0) := (others => '0');
  signal tc_config_valid         : std_logic := '1';
  -- BUG #446: sticky latch for illegal-reg_sel observations (see port).
  signal pmmu_illegal_reg_sel_seen : std_logic := '0';
  -- MC68030 page table walker FSM
  -- Added W_*_LOW states for reading LOW word of long-format (64-bit) descriptors
  -- Added W_INDIRECT states for indirect descriptor support (MC68030 spec section 9.5.3.2)
  -- BUG #164 FIX: Added W_INDIRECT_LOW for long-format indirect descriptor targets
  -- Added W_PTR4, W_PTR4_LOW for 5-level table walks when FCL=1 and all TI fields used
  type walk_state_t is (W_IDLE, W_ROOT, W_ROOT_LOW, W_PTR1, W_PTR1_LOW, W_PTR2, W_PTR2_LOW, W_PTR3, W_PTR3_LOW, W_PTR4, W_PTR4_LOW, W_INDIRECT, W_INDIRECT_LOW, W_PAGE, W_TABLE_UPDATE, W_UPDATE_DESC, W_PLOAD_FLUSH, W_FILL, W_COMPLETE, W_FAULT);
  signal wstate    : walk_state_t := W_IDLE;
  
  -- Walker bookkeeping
  signal walk_log_base  : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_phys_base : std_logic_vector(31 downto 0) := (others => '0');
  -- Effective page shift for the current translation (may exceed TC.PS for large pages).
  signal walk_page_shift: integer range 0 to 32 := 12;
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
  signal ptest_done : std_logic := '0';  -- Handshake: translation process signals completion
  signal ptest_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal ptest_rw : std_logic := '1';  -- '1'=PTESTR (read), '0'=PTESTW (write), from brief(9)
  signal ptest_level : std_logic_vector(2 downto 0) := "000";  -- BUG #413: PTEST level from brief(12:10)
  -- BUG #396: PTEST/PLOAD walk must NOT update addr_phys_reg.
  -- ptest_active clears after the command is accepted; pload_active is held until
  -- the translation process can start or discard the preload request.
  -- This flag persists through the entire walk so walker_completed can skip addr_phys_reg.
  signal instr_walk_pending : std_logic := '0';
  signal ptest_walk_pending : std_logic := '0';  -- Table-search PTEST active: update MMUSR only, never alter the ATC
  signal ptest_walk_no_update : std_logic := '0';  -- Kept for non-mutating walks; MC68030 PTEST table searches leave this deasserted
  -- PLOAD operation state
  signal pload_active : std_logic := '0';
  signal pload_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pload_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal pload_rw : std_logic := '1';  -- '1'=PLOADR (read), '0'=PLOADW (write), from brief(9)
  signal pload_flush_pending : std_logic := '0';  -- PLOAD flush-before-walk: flush existing ATC entry
  -- PFLUSH operation state
  signal pflush_active : std_logic := '0';
  signal pflush_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pflush_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal pflush_mode : std_logic_vector(2 downto 0) := (others => '0');  -- MODE field from brief(12:10)
  signal pflush_mask : std_logic_vector(2 downto 0) := (others => '0');  -- FC0-FC2 comparison mask from brief(7:5); FC3 is unsupported on MC68030
  
  -- Page table walking state
  signal walk_level     : integer range 0 to 5 := 0; -- Current level being walked (0-4 for FCL=0, 0-5 for FCL=1)
  signal walk_desc      : std_logic_vector(31 downto 0) := (others => '0'); -- Current descriptor (short format or HIGH word)
  signal walk_desc_high : std_logic_vector(31 downto 0) := (others => '0'); -- HIGH word (all formats)
  signal walk_desc_low  : std_logic_vector(31 downto 0) := (others => '0'); -- LOW word (long format only)
  -- Sticky per-level descriptor captures for fault forensics
  signal ptr1_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr1_desc_data_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr2_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr2_desc_data_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr3_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr3_desc_data_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_desc_is_long : std_logic := '0'; -- 1=long format (DT=11), 0=short format (DT=10/01)
  signal walk_page_from_indirect : std_logic := '0'; -- Page descriptor was reached through one indirect descriptor
  signal walk_parent_dt_long : std_logic := '0'; -- BUG #409: 1=parent DT=11, entries are 8 bytes (stride 8)
  -- BUG #387 FIX: Walker timeout counter to detect stuck memory requests
  signal walker_timeout_counter : integer range 0 to 1023 := 0;
  constant WALKER_TIMEOUT_CYCLES : integer := 500; -- Timeout after 500 cycles without mem_ack
  signal walk_addr      : std_logic_vector(31 downto 0) := (others => '0'); -- Current table address
  signal walk_vpn       : std_logic_vector(31 downto 0) := (others => '0'); -- Virtual page being walked
  signal walk_fault     : std_logic := '0'; -- Page fault flag
  signal walk_attr      : std_logic_vector(7 downto 0) := (others => '0'); -- Page attributes
  signal walk_supervisor : std_logic := '0'; -- BUG #157 FIX: Cumulative S bit from TABLE descriptors
  signal walk_write_protect : std_logic := '0'; -- Cumulative WP bit from TABLE descriptors (per MC68030 spec 9.5.2)
  signal walk_is_root_pointer : std_logic := '0'; -- Root pointer DT=01 early termination (no S/WP/U/M checks)
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
  signal walk_next_state    : walk_state_t := W_IDLE;  -- Continuation state after TABLE U-bit writeback
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
    if shift <= 0 then
      return addr; -- No alignment needed
    end if;
    if shift >= 32 then
      return x"00000000"; -- Aligned to >= 4GB boundary (all bits masked)
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
      rmw       : in  std_logic;  -- read-modify-write sequence; requires TTR RWM=1
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
      if rmw = '1' and tt(8) = '0' then
        -- MC68030 UM 9.2.6: RMW cycles are transparent only when RWM=1.
        matched := '0';
        ci := '0';
        wp := '0';
      elsif tt(8) = '0' then  -- RWM=0: R/W field is USED (check access type)
        if tt(9) = '1' and rw = '0' then
          -- R/W=1 (read-only transparent) but this is a write - no match
          matched := '0';
          ci := '0';
          wp := '0';
        elsif tt(9) = '0' and rw = '1' then
          -- R/W=0 (write-only transparent) but this is a read - no match
          matched := '0';
          ci := '0';
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
    ttr_check(tt, addr, fc, is_insn, '1', '0', matched, dummy_ci, dummy_wp);  -- Default to read for simple match check
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
    variable addr_mask : unsigned(31 downto 0);
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
    -- Apply Initial Shift (IS): ignore top IS bits per MC68030 spec
    temp_addr := unsigned(addr);
    if initial_shift > 0 then
      addr_mask := shift_right(not to_unsigned(0, 32), initial_shift);
      temp_addr := temp_addr AND addr_mask;
    end if;
    -- Extract bits by shifting right and masking
    temp_addr := shift_right(temp_addr, shift_amount);
    result := to_integer(temp_addr AND to_unsigned((2**mask_width) - 1, 32));
    return result;
  end function;
  -- MC68030 Function Code Lookup (TC.FCL):
  -- When FCL=1, FC[2:0] indexes the FIRST table (8 entries).
  -- Then TIA/TIB/TIC/TID index subsequent tables using ORIGINAL address bits.
  -- Per MC68030 spec: FCL adds a separate FC-indexed level, NOT address bit replacement.
  -- The bit-sum rule stays unchanged: IS + PS + TIA + TIB + TIC + TID = 32.
  --
  -- This function now returns the original address unchanged.
  -- FCL handling is done at table index calculation time, not address modification.
  function fcl_search_addr(addr : std_logic_vector(31 downto 0);
                           fc   : std_logic_vector(2 downto 0);
                           fcl  : std_logic) return std_logic_vector is
  begin
    -- Return original address - FCL is handled by get_fcl_table_index
    return addr;
  end function;
  -- MC68030 Function Code Lookup table index calculation
  -- When FCL=1 and level=0: Return FC directly (3-bit index into 8-entry table)
  -- When FCL=1 and level>0: Use TIA/TIB/TIC/TID from original address (shifted by 1 level)
  -- When FCL=0: Normal TIA/TIB/TIC/TID indexing
  function get_fcl_table_index(addr : std_logic_vector(31 downto 0);
                               fc   : std_logic_vector(2 downto 0);
                               fcl  : std_logic;
                               level : integer;
                               initial_shift : integer;
                               page_size : integer;
                               idx_bits : tc_bits_array_t) return integer is
  begin
    if fcl = '1' then
      if level = 0 then
        -- FCL=1, first level: FC indexes the root table (8 entries max)
        return to_integer(unsigned(fc));
      else
        -- FCL=1, subsequent levels: shift TIx usage by 1
        -- level 1 uses TIA (idx_bits(0)), level 2 uses TIB (idx_bits(1)), etc.
        return get_table_index(addr, level - 1, initial_shift, page_size, idx_bits);
      end if;
    else
      -- FCL=0: Normal indexing
      return get_table_index(addr, level, initial_shift, page_size, idx_bits);
    end if;
  end function;
  -- Check if current level is the final table level before page descriptor
  -- Returns true if the next TI field is 0 (no more levels to walk)
  -- FCL shifts which TI field corresponds to each walker level:
  --   FCL=0: level 1 uses TIB, level 2 uses TIC, level 3 uses TID
  --   FCL=1: level 1 uses TIA, level 2 uses TIB, level 3 uses TIC, level 4 uses TID
  -- This function checks if the NEXT level's TI field is zero
  function is_final_table_level(fcl : std_logic; level : integer; idx_bits : tc_bits_array_t) return boolean is
    variable check_idx : integer;
  begin
    -- Map level to the TI field index that would be used for the NEXT level
    -- We need to check if the next level exists (has non-zero TI bits)
    if fcl = '1' then
      -- FCL=1: level N uses idx_bits(N-1), so next level uses idx_bits(N)
      check_idx := level;
    else
      -- FCL=0: level N uses idx_bits(N), so next level uses idx_bits(N+1)
      check_idx := level + 1;
    end if;
    if check_idx > 3 then
      -- Beyond TID (idx 3), always final - no more TI fields
      return true;
    else
      return idx_bits(check_idx) = 0;
    end if;
  end function;
  -- Early-termination limit checking uses the NEXT logical-address index field.
  -- Root-pointer DT=01 is special:
  --   * WinUAE skips the root-pointer limit check when TC.FCL is set because
  --     there is no memory-resident FC-table descriptor to apply the limit to.
  function early_term_limit_applies(
    is_root_pointer : std_logic;
    fcl             : std_logic;
    level           : integer;
    idx_bits        : tc_bits_array_t
  ) return boolean is
  begin
    if is_root_pointer = '1' then
      if fcl = '1' then
        return false;
      end if;
      return idx_bits(0) /= 0;
    end if;
    return not is_final_table_level(fcl, level, idx_bits);
  end function;
  function early_term_limit_level(
    is_root_pointer : std_logic;
    level           : integer
  ) return integer is
  begin
    if is_root_pointer = '1' then
      return 0;
    end if;
    return level + 1;
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
  function tc_config_invalid(tc : std_logic_vector(31 downto 0)) return boolean is
    variable ps_val : integer;
  begin
    if tc(31) = '0' then
      return false;
    end if;
    ps_val := to_integer(unsigned(tc(23 downto 20)));
    if ps_val < 8 then
      return true;
    end if;
    if tc_total_bits(tc) /= 32 then
      return true;
    end if;
    return false;
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
  -- Leveled PTEST can stop on a table descriptor with S/W accumulated, but with
  -- no B/L/I fault classification. This matches WinUAE's MMUSR stop-search state.
  function encode_mmusr_ptest(
    supervisor_violation : std_logic;
    write_protect : std_logic;
    modified : std_logic;
    transparent : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    result := (others => '0');
    result(13) := supervisor_violation;   -- Bit 13: S
    result(11) := write_protect;          -- Bit 11: W
    result(9)  := modified;               -- Bit 9: M
    result(6)  := transparent;            -- Bit 6: T
    result(2 downto 0) := level;          -- Bits 2-0: N
    return result;
  end function;
  function encode_ptest_table_status(
    fc : std_logic_vector(2 downto 0);
    accum_supervisor : std_logic;
    current_supervisor : std_logic;
    accum_write_protect : std_logic;
    current_write_protect : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable supervisor_violation : std_logic := '0';
  begin
    if fc(2) = '0' and (accum_supervisor = '1' or current_supervisor = '1') then
      supervisor_violation := '1';
    end if;
    return encode_mmusr_ptest(
      supervisor_violation => supervisor_violation,
      write_protect => accum_write_protect or current_write_protect,
      modified => '0',
      transparent => '0',
      level => level
    );
  end function;
  function page_descriptor_count(
    level : integer;
    from_indirect : std_logic;
    root_pointer : std_logic
  ) return std_logic_vector is
    variable count : integer;
  begin
    if root_pointer = '1' then
      count := 0;
    else
      count := level + 1;
      if from_indirect = '1' then
        count := count + 1;
      end if;
    end if;
    return std_logic_vector(to_unsigned(count, 3));
  end function;
  -- Calculate effective page shift for early termination
  -- MC68030 spec: When a page descriptor (DT=01) is found before the final table level,
  -- the remaining index bits become part of the page offset, creating a larger "super page".
  -- For early termination at level L, effective page shift = PS + TID + TIC + TIB + ... (remaining levels)
  -- walk_level: 0=ROOT, 1=PTR1, 2=PTR2, 3=PTR3
  function calc_effective_page_shift(
    base_page_shift : integer;      -- TC.PS value (8-15)
    level : integer;                -- walk_level where page descriptor was found
    idx_bits : tc_bits_array_t;     -- tc_idx_bits: (0)=TIA, (1)=TIB, (2)=TIC, (3)=TID
    fcl : std_logic                 -- TC.FCL (Function Code Lookup)
  ) return integer is
    variable result : integer;
  begin
    result := base_page_shift;
    -- Add remaining index bits based on termination level
    -- FCL=0:
    --   Level 0 (TIA): add TIB + TIC + TID
    --   Level 1 (TIB): add TIC + TID
    --   Level 2 (TIC): add TID
    --   Level 3 (TID): add none
    -- FCL=1:
    --   Level 0 (FC):  add TIA + TIB + TIC + TID
    --   Level 1 (TIA): add TIB + TIC + TID
    --   Level 2 (TIB): add TIC + TID
    --   Level 3 (TIC): add TID
    --   Level 4 (TID): add none
    if fcl = '1' then
      if level <= 3 then
        result := result + idx_bits(3);  -- TID
      end if;
      if level <= 2 then
        result := result + idx_bits(2);  -- TIC
      end if;
      if level <= 1 then
        result := result + idx_bits(1);  -- TIB
      end if;
      if level = 0 then
        result := result + idx_bits(0);  -- TIA
      end if;
    else
      if level <= 2 then
        result := result + idx_bits(3);  -- TID
      end if;
      if level <= 1 then
        result := result + idx_bits(2);  -- TIC
      end if;
      if level = 0 then
        result := result + idx_bits(1);  -- TIB
      end if;
    end if;
    return result;
  end function;
begin
  -- Connect internal register to output port
  ptest_desc_addr <= ptest_desc_addr_reg;
  -- BUG #371 FIX: Combinational TTR match for zero-latency addr_phys bypass
  -- When MMU is first enabled, addr_phys_reg is stale (from previous cycle).
  -- TTR transparent translations always produce phys=log (identity mapping),
  -- so we can compute the match combinationally and bypass the registered result.
  process(TT0, TT1, addr_log, fc, is_insn, rw, rmw)
    variable m0, m1 : std_logic;
    variable ci0, wp0, ci1, wp1 : std_logic;
  begin
    m0 := '0'; m1 := '0';
    ci0 := '0'; wp0 := '0';
    ci1 := '0'; wp1 := '0';
    ttr_check(TT0, addr_log, fc, is_insn, rw, rmw, m0, ci0, wp0);
    ttr_check(TT1, addr_log, fc, is_insn, rw, rmw, m1, ci1, wp1);
    ttr0_match_comb <= m0;
    ttr1_match_comb <= m1;
    ttr0_ci_comb <= ci0;
    ttr0_wp_comb <= wp0;
    ttr1_ci_comb <= ci1;
    ttr1_wp_comb <= wp1;
  end process;
  -- Successful ATC hits can also bypass the registered translation result.
  -- This keeps addr_phys/cache attributes aligned with the current request and
  -- avoids stalling a clean cached access behind the previous cycle's output.
  process(addr_log, fc, rw, tc_en, mmudis, atc_valid, atc_flush_req, atc_fc,
          atc_shift, atc_log_base, atc_phys_base, atc_attr, atc_buserr)
    variable aligned_addr : std_logic_vector(31 downto 0);
    variable phys_base    : unsigned(31 downto 0);
    variable offset       : unsigned(31 downto 0);
    variable phys_result  : unsigned(31 downto 0);
  begin
    atc_success_comb <= '0';
    atc_phys_comb    <= (others => '0');
    atc_ci_comb      <= '0';
    atc_wp_comb      <= '0';

    if tc_en = '1' and mmudis = '0' then
      for i in 0 to ATC_ENTRIES-1 loop
        if atc_valid(i) = '1' and atc_flush_req = '0' then
          aligned_addr := align_addr(addr_log, atc_shift(i));
          if atc_fc(i) = fc and aligned_addr = atc_log_base(i) then
            if rw = '1' or atc_attr(i)(1) = '1' or atc_attr(i)(0) = '1' or atc_buserr(i) = '1' then
              -- Only bypass successful cached translations. Faulting ATC entries
              -- still go through the registered path so the fault handshake can
              -- latch MMUSR/fault state before the CPU is released.
              if atc_buserr(i) = '0' and
                 not (rw = '0' and atc_attr(i)(0) = '1') and
                 not (fc(2) = '0' and atc_attr(i)(3) = '0') then
                phys_base := unsigned(atc_phys_base(i));
                offset    := unsigned(addr_log) - unsigned(atc_log_base(i));
                phys_result := phys_base + offset;
                atc_success_comb <= '1';
                atc_phys_comb    <= std_logic_vector(phys_result);
                atc_ci_comb      <= atc_attr(i)(2);
                atc_wp_comb      <= atc_attr(i)(0);
              end if;
            end if;
          end if;
        end if;
      end loop;
    end if;
  end process;
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
      -- MC68030 hard reset clears TC. Disabled TC images are not configuration
      -- checked, so PS=0 is legal while E=0 and must read back as zero.
      TC    <= (others => '0');
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
      xlat_cfg_seq <= (others => '0');
      -- ptest_addr, ptest_fc, ptest_rw now driven by edge detection process (BUG #397)
      mmu_config_error <= '0';
      tc_config_check_pending <= '0';
      tc_config_check_value <= (others => '0');
      tc_config_valid <= '1';
      pmmu_illegal_reg_sel_seen <= '0';
    elsif rising_edge(clk) then
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      -- BUG #154 FIX: Clear mmu_config_error when kernel acknowledges the trap
      -- This prevents infinite exception loops - the error latches until the
      -- kernel takes the trap and pulses mmu_config_ack
      if mmu_config_ack = '1' then
        mmu_config_error <= '0';
      end if;
      -- Pipeline TC consistency validation so PMOVE data returning from RAM does
      -- not feed the full TC field-sum check and exception latch in one cycle.
      if tc_config_check_pending = '1' then
        tc_config_check_pending <= '0';
        tc_e := tc_config_check_value(31);
        ps_val := to_integer(unsigned(tc_config_check_value(23 downto 20)));
        if tc_e = '0' then
          tc_config_valid <= '1';
        elsif ps_val < 8 then
          -- MC68030 UM 9.7.2: on MMU configuration exception the TC image is
          -- loaded, but the E bit is cleared.
          tc_config_valid <= '1';
          mmu_config_error <= '1';
          TC(31) <= '0';
          -- synthesis translate_off
          report "MMU_CONFIG: Invalid PS field=" & integer'image(ps_val) &
                 " (must be 8-15), raising configuration exception" severity warning;
          -- synthesis translate_on
        else
          total_bits := tc_total_bits(tc_config_check_value);
          if total_bits /= 32 then
            -- MC68030 UM 9.7.2: on MMU configuration exception the TC image is
            -- loaded, but the E bit is cleared.
            tc_config_valid <= '1';
            mmu_config_error <= '1';
            TC(31) <= '0';
            -- synthesis translate_off
            report "MMU_CONFIG: Field sum=" & integer'image(total_bits) &
                   " (must be 32), raising configuration exception" severity warning;
            -- synthesis translate_on
          else
            tc_config_valid <= '1';
          end if;
        end if;
      end if;
      -- Handle MMUSR updates with MC68030-compliant priority (MMUSR register only)
      -- IMPORTANT: These only affect MMUSR, not other registers!
      if cpu_reset = '1' then
        -- MC68030 RESET (soft reset / RESET instruction) clears the translation
        -- enable bit in TC and the enable bits in both TTRs. Preserve the rest
        -- of the register contents. Per MC68030 UM 9.2.2 (PDF 14324-14326)
        -- and WinUAE cpummu30.cpp L2690-2700, soft reset does NOT invalidate
        -- ATC entries; only a hard reset (nreset='0') flushes the ATC.
        -- Software that re-enables translation after RESET is expected to
        -- issue PFLUSHA explicitly if it cannot reuse the existing ATC entries.
        TC(31) <= '0';
        tc_config_valid <= '1';
        TT0(15) <= '0';
        TT1(15) <= '0';
        ptest_active <= '0';
        xlat_cfg_seq <= xlat_cfg_seq + 1;
      elsif ptest_update_mmusr = '1' then
        -- Highest priority: PTEST instruction (MC68030 specification)
        -- BUG #397: addr/fc/rw captured in edge detection process (not here)
        ptest_active <= '1';
        -- Translation process will update MMUSR. This must remain true even
        -- when TC.E=0 because MC68030 TTRs operate independently of table
        -- translation.
        null;
      elsif mmusr_update_req = '1' then
        -- Medium priority: Translation engine update (automatic updates)
        MMUSR <= mmusr_update_value(15 downto 0);
        mmusr_update_ack <= '1';
      end if;
      -- BUG FIX: Clear ptest_active when translation process signals completion
      if ptest_done = '1' then
        ptest_active <= '0';
        -- (PMMU_PTEST_DONE report disabled for sim speed)
      end if;
      -- Handle direct register writes (TC, CRP, SRP, TT0, TT1, etc.)
      -- CRITICAL FIX: These are INDEPENDENT of MMUSR updates and execute concurrently
      -- BUG #12: Was using "elsif" which blocked all register writes when MMUSR updates active
      -- SWITCHED TO LEVEL: Use level-triggered logic instead of edge detection
      if reg_we = '1' then
        -- MC68030 Specification: MMU register access requires supervisor mode
        -- Privilege check is performed by TG68KdotC_Kernel before asserting reg_we,
        -- so no additional FC check is needed here
        -- Invalidate "fresh translation" key when translation context changes.
        if reg_sel = "00010" or reg_sel = "00011" or reg_sel = "10000" or
           reg_sel = "10010" or reg_sel = "10011" then
          xlat_cfg_seq <= xlat_cfg_seq + 1;
        end if;
        -- synthesis translate_off
        report "PMMU_REG_WRITE: sel=" & integer'image(to_integer(unsigned(reg_sel))) &
               " wdat_hi=" & integer'image(to_integer(unsigned(reg_wdat(31 downto 16)))) &
               " wdat_lo=" & integer'image(to_integer(unsigned(reg_wdat(15 downto 0)))) &
               " part=" & std_logic'image(reg_part);
        -- synthesis translate_on
        case reg_sel is
          when "00010" =>  -- TT0: P-reg 0x02
            -- TT0 register write - MC68030 Transparent Translation Register per User's Manual section 9.2.6
            -- MC68030 TT0/TT1 bit layout:
            -- 31-24: Logical Address Base, 23-16: Logical Address Mask
            -- 15: E (Enable), 14-11: Reserved, 10: CI (Cache Inhibit), 9: RW, 8: RWM
            -- 7: Reserved, 6-4: FC Base, 3: Reserved, 2-0: FC Mask
            TT0 <= reg_wdat and TTR_WRITE_MASK;
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
            TT1 <= reg_wdat and TTR_WRITE_MASK;
            -- TT1 changes invalidate ATC unless PMOVEFD (flush disable)
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "10000" =>  -- TC: P-reg 0x10
            -- MC68030 TC Register Write
            -- MC68030 TC bit layout per User's Manual section 9.2.1:
            -- 31: E (Enable), 30-26: Reserved, 25: SRE, 24: FCL
            -- 23-20: PS (Page Size), 19-16: IS (Initial Shift), 15-12: TIA, 11-8: TIB, 7-4: TIC, 3-0: TID
            -- Reserved bits: 30-26 only (all other bits are valid control fields)
            tc_write_val := reg_wdat and TC_WRITE_MASK;
            -- BUG #445: mmu_config_error is a sticky latch.
            -- A valid TC write (or TC.E=0) does NOT clear it; only mmu_config_ack
            -- (from the kernel taking vector 56) or reset clears the latch.
            -- MC68030 UM 9.7.2 / 9.7.5.3: TC consistency checks are only
            -- performed when the new value has E=1. With E=0, translation is
            -- disabled and software is allowed to load TC images like $00000000
            -- without taking vector 56. WinUAE follows the same rule by
            -- returning early when translation is disabled.
            tc_config_check_value <= tc_write_val;
            tc_config_check_pending <= '1';
            tc_config_valid <= not tc_write_val(31);
            TC <= tc_write_val;
            report "BUG387_TC_WRITE: tc_val=0x" &
                   integer'image(to_integer(unsigned(tc_write_val(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(tc_write_val(15 downto 0)))) severity note;
            -- TC changes invalidate ATC unless PMOVEFD (flush disable)
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "10010" =>  -- SRP: P-reg 0x12
            -- SRP register write - MC68030 Long-Format Root Pointer (same format as CRP)
            if reg_part = '1' then
              -- SRP HIGH WORD (bits 63-32): L/U[63] + Limit[62:48] + Reserved[47:34] + DT[33:32]
              -- MC68030 UM 9.5.1.1: DT is a 2-bit field (codes $0..$3), reserved bits 47-34
              report "PMMU_REG_WRITE: SRP_H reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              SRP_H <= reg_wdat and CRP_HIGH_MASK;
              -- MC68030 MMU Configuration Exception: DT=0 (invalid descriptor)
              -- Per spec: Register is loaded BEFORE exception is taken.
              -- BUG #445: sticky latch — valid DT does not clear it (see TC write).
              if reg_wdat(1 downto 0) = "00" then
                mmu_config_error <= '1';
                -- synthesis translate_off
                report "MMU_CONFIG: SRP_H DT=00 (invalid descriptor type)" severity warning;
                -- synthesis translate_on
              end if;
            else
              -- SRP LOW WORD (bits 31-0): Table Address[31:4] + Reserved[3:0]
              -- MC68030 spec: Table address bits 31-4, reserved bits 3-0 must be zero
              report "PMMU_REG_WRITE: SRP_L reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              SRP_L <= reg_wdat and CRP_LOW_MASK;
            end if;
            if reg_fd = '0' then  -- Only flush if NOT PMOVEFD
              atc_flush_req <= '1'; -- SRP changes invalidate all cached translations
            end if;
          when "10011" =>  -- CRP: P-reg 0x13
            -- CRP register write - MC68030 Long-Format Root Pointer per User's Manual section 9.2.2
            if reg_part = '1' then
              -- CRP HIGH WORD (bits 63-32): L/U[63] + Limit[62:48] + Reserved[47:34] + DT[33:32]
              -- MC68030 UM 9.5.1.1: DT is a 2-bit field (codes $0..$3), reserved bits 47-34
              report "PMMU_REG_WRITE: CRP_H reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              CRP_H <= reg_wdat and CRP_HIGH_MASK;
              -- MC68030 MMU Configuration Exception: DT=0 (invalid descriptor)
              -- Per spec: Register is loaded BEFORE exception is taken.
              -- BUG #445: sticky latch — valid DT does not clear it (see TC write).
              if reg_wdat(1 downto 0) = "00" then
                mmu_config_error <= '1';
                -- synthesis translate_off
                report "MMU_CONFIG: CRP_H DT=00 (invalid descriptor type)" severity warning;
                -- synthesis translate_on
              end if;
            else
              -- CRP LOW WORD (bits 31-0): Table Address[31:4] + Reserved[3:0]
              -- MC68030 spec: Table address bits 31-4, reserved bits 3-0 must be zero
              report "PMMU_REG_WRITE: CRP_L reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              CRP_L <= reg_wdat and CRP_LOW_MASK;
            end if;
            -- CRP changes invalidate ATC unless PMOVEFD (flush disable)
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "11000" =>
            -- MC68030 UM 9.6.3.4: PMOVE to MMUSR is a direct 16-bit store
            -- MMUSR is fully read-write via PMOVE (software clears before PTEST)
            MMUSR <= reg_wdat(15 downto 0);
          when others =>
            -- MC68030 UM 9.6 (PDF line 15301-15303): "PMOVE for unsupported
            -- registers (CAL, VAL, SCC, BAD, BACx, DRP, and AC)" is on the list
            -- of instructions that "must be avoided or emulated in the
            -- exception routine for F-line unimplemented instructions."
            -- The kernel's PMOVE decode already F-line traps any reg_sel
            -- outside the MC68030 set at TG68KdotC_Kernel.vhd (before the PMMU
            -- sees reg_we). The "when others" branch here should therefore be
            -- unreachable in real use; keep the sticky debug latch for
            -- SignalTap but do NOT raise mmu_config_error (vector 56) — that
            -- would be the wrong exception vector per the spec.
            -- synthesis translate_off
            assert false
              report "PMMU: illegal PMOVE reg_sel = " &
                     integer'image(to_integer(unsigned(reg_sel))) &
                     " on write (reg_wdat=0x" & slv_to_hex(reg_wdat) & ")"
              severity error;
            -- synthesis translate_on
            pmmu_illegal_reg_sel_seen <= '1';
          end case;
      end if;
      -- Sticky debug latch on illegal reg_sel during reads; no trap raised
      -- here (kernel F-line trap already handles it).
      if reg_re = '1' then
        case reg_sel is
          when "00010" | "00011" | "10000" | "10010" | "10011" | "11000" =>
            null;
          when others =>
            pmmu_illegal_reg_sel_seen <= '1';
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
              X"0000" & MMUSR when reg_sel = "11000" else
              (others => '0');
  debug_mmusr <= MMUSR;
  -- BUG #446: Expose the sticky illegal-reg_sel latch.
  debug_illegal_reg_sel <= pmmu_illegal_reg_sel_seen;

  -- BUG #446: Read-side observability. Undecoded reg_sel on a PMOVE read
  -- returns zero (see mux above) — catch it in simulation so unit tests fail
  -- loudly rather than silently consuming garbage.
  -- synthesis translate_off
  process(clk)
  begin
    if rising_edge(clk) then
      if reg_re = '1' then
        case reg_sel is
          when "00010" | "00011" | "10000" | "10010" | "10011" | "11000" =>
            null; -- legal
          when others =>
            assert false
              report "PMMU: illegal PMOVE reg_sel = " &
                     integer'image(to_integer(unsigned(reg_sel))) &
                     " on read"
              severity error;
        end case;
      end if;
    end if;
  end process;
  -- synthesis translate_on
  -- SignalTap debug outputs
  debug_tc  <= TC;
  debug_tt0 <= TT0;
  debug_tt1 <= TT1;
  debug_crp_hi <= CRP_H;
  debug_crp_lo <= CRP_L;
  debug_srp_hi <= SRP_H;
  debug_srp_lo <= SRP_L;
  debug_wstate <= std_logic_vector(to_unsigned(walk_state_t'pos(wstate), 5));
  debug_walk_desc_addr <= desc_addr_reg;
  debug_walk_desc_data <= last_mem_rdat;
  -- ATC debug: expose buserr and valid flags for all 22 entries
  gen_atc_debug: for i in 0 to ATC_ENTRIES-1 generate
    debug_atc_buserr(i) <= atc_buserr(i);
    debug_atc_valid(i)  <= atc_valid(i);
  end generate;
  debug_fault_status <= debug_fault_status_latch;
  debug_saved_addr   <= saved_addr_log;
  debug_saved_fc     <= saved_fc;
  debug_ptr1_desc_addr <= ptr1_desc_addr_reg;
  debug_ptr1_desc_data <= ptr1_desc_data_reg;
  debug_ptr2_desc_addr <= ptr2_desc_addr_reg;
  debug_ptr2_desc_data <= ptr2_desc_data_reg;
  debug_ptr3_desc_addr <= ptr3_desc_addr_reg;
  debug_ptr3_desc_data <= ptr3_desc_data_reg;
  -- DEBUG: Monitor all PMMU register reads (disabled for simulation speed)
  -- process(reg_sel, reg_part, TC, TT0, TT1, SRP_H, SRP_L, CRP_H, CRP_L, MMUSR)
  -- begin ... end process;
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
  -- Keep translation disabled while the stored TC image itself is invalid.
  -- The raw TC contents are still preserved for PMOVE readback and vector-56
  -- forensics, but the handler must run under identity/TTR semantics instead
  -- of briefly re-enabling an illegal translation context after ack.
  tc_en <= '1' when TC(31) = '1' and mmu_config_error = '0' and tc_config_valid = '1' else '0';
  -- PMMU instructions can perform table searches regardless of TC.E; keep only
  -- the configuration-error/validation gate separate from normal translation enable.
  tc_table_config_valid <= '1' when mmu_config_error = '0' and tc_config_valid = '1' else '0';
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
  
  -- Output the current translation result.
  -- BUG #129 FIX: Add combinational bypass for identity translation when table
  -- translation is disabled so cache-facing outputs stay in sync with the logical
  -- address in the same cycle.
  -- BUG #371 FIX: Also bypass for TTR transparent translations (phys=log identity
  -- mapping); TT0/TT1 operate independently of TC.E and MMUDIS on MC68030.
  -- TTR/disabled translations can bypass the registered path because the result is
  -- identity. ATC hits stay on the registered path: busy remains asserted until
  -- addr_phys_reg is refreshed for the current request, avoiding stale physical
  -- addresses without putting the full ATC compare tree on the bus address output.
  -- MC68030 UM Figure 9-32: FC=7 (CPU space) is always unmapped (identity).
  addr_phys     <= addr_log when fc = "111"
                   else addr_log when (ttr0_match_comb = '1' or ttr1_match_comb = '1')
                   else addr_log when tc_en = '0'
                   else addr_log when mmudis = '1'  -- MC68030 UM 9.2.3
                   else addr_phys_reg;
  -- BUG #126 V2 FIX: Combinational bypass for cache_inhibit when MMU disabled
  -- Without this, cache_inhibit_reg retains stale value (pmmu_req='0' when MMU off)
  -- BUG #371 V2 FIX: Also bypass for TTR matches - cache_inhibit and write_protect
  -- must be consistent with addr_phys in the same cycle, otherwise the cache sees
  -- the correct I/O address but stale CI=0 from the previous RAM access and
  -- incorrectly caches I/O data.
  -- MC68030 UM 9.3 (PDF line 14399): "If both registers match, the CI bits are
  -- ORed together to generate the CIOUT signal." OR the WP bits on dual match
  -- for consistency (spec is silent on WP for TTRs but UM 9.5.1.1 line 14571
  -- prescribes OR for WP bits encountered during a table search).
  cache_inhibit <= '1' when fc = "111"  -- CPU space always cache-inhibited
                   else (ttr0_ci_comb or ttr1_ci_comb) when (ttr0_match_comb = '1' and ttr1_match_comb = '1')
                   else ttr0_ci_comb when ttr0_match_comb = '1'
                   else ttr1_ci_comb when ttr1_match_comb = '1'
                   else '0' when tc_en = '0'
                   else '0' when mmudis = '1'  -- MC68030 UM 9.2.3
                   else cache_inhibit_reg;
  write_protect <= '0' when fc = "111"  -- CPU space never write-protected
                   else (ttr0_wp_comb or ttr1_wp_comb) when (ttr0_match_comb = '1' and ttr1_match_comb = '1')
                   else ttr0_wp_comb when ttr0_match_comb = '1'
                   else ttr1_wp_comb when ttr1_match_comb = '1'
                   else '0' when tc_en = '0'
                   else '0' when mmudis = '1'  -- MC68030 UM 9.2.3
                   else write_protect_reg;
  -- A latched fault describes one bus transfer. Once the CPU starts exception
  -- stacking, the logical address/FC/RW tuple changes and the old fault must
  -- not keep the wrapper unstalled or look like a fresh double-bus-fault.
  fault_current_req_match <= '1' when fault_fc_reg = fc and
                                      fault_rw_reg = rw and
                                      fault_is_insn_reg = is_insn and
                                      (addr_log = fault_addr_reg or
                                       addr_log = std_logic_vector(unsigned(fault_addr_reg) + 2)) else
                             '0';
  fault         <= '0' when fc = "111" else
                   fault_reg when translated_cfg_seq = xlat_cfg_seq and
                                  fault_current_req_match = '1' else
                   '0';  -- CPU space never faults; stale-context faults are ignored
  fault_status  <= fault_status_reg;
  fault_addr    <= fault_addr_reg;     -- BUG #415: Faulting logical address
  fault_fc      <= fault_fc_reg;       -- BUG #414: FC at fault time
  fault_rw      <= fault_rw_reg;       -- BUG #414: RW at fault time
  fault_is_insn <= fault_is_insn_reg;  -- BUG #414: Instruction fetch flag
  translated_match_dbg <= '1' when translated_addr = addr_log and
                                   translated_fc = fc and
                                   translated_rw = rw and
                                   translated_cfg_seq = xlat_cfg_seq else '0';
  debug_pending_flags <= req & translation_pending & walk_req & walker_completed &
                         walker_fault & walker_fault_ack_pending &
                         walker_completed_ack & fault_reg & tc_en & mmudis &
                         rw & is_insn & fc & translated_match_dbg;
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
      translated_addr <= (others => '0');  -- BUG #416
      translated_fc <= (others => '0');    -- BUG #416
      translated_rw <= '1';
      translated_cfg_seq <= (others => '0');
      cache_inhibit_reg <= '0';
      write_protect_reg <= '0';
      fault_reg <= '0';
      fault_status_reg <= (others => '0');
      fault_addr_reg <= (others => '0');
      fault_fc_reg <= (others => '0');
      fault_rw_reg <= '1';
      debug_fault_status_latch <= (others => '0');
      debug_fault_status_valid <= '0';
      fault_is_insn_reg <= '0';
      saved_addr_log <= (others => '0');
      saved_fc <= (others => '0');
      saved_is_insn <= '0';
      saved_rw <= '0';
      req_prev <= '0';
      translation_pending <= '0';
      walk_req <= '0';
      walker_fault_ack <= '0';
      walker_completed_ack <= '0';
      walker_fault_ack_pending <= '0';
      xlat_cfg_seq_seen <= (others => '0');
      mmusr_update_req <= '0';
      mmusr_update_value <= (others => '0');
      ptest_done <= '0';
      instr_walk_pending <= '0';
      ptest_walk_pending <= '0';
      ptest_walk_no_update <= '0';
      ptest_desc_addr_reg <= (others => '0');
      ptest_desc_return_pending <= '0';
      atc_mru_update_req <= '0';
      atc_mru_update_idx <= 0;
      atc_mbit_inval_req <= '0';
      atc_mbit_inval_idx <= 0;
      pload_flush_pending <= '0';
    elsif rising_edge(clk) then
      status_tmp := fault_status_reg;
      req_prev <= req;
      -- Clear ptest_done pulse (it's only set for one cycle)
      ptest_done <= '0';
      -- Clear MRU update request pulse
      atc_mru_update_req <= '0';
      atc_mbit_inval_req <= '0';
      if mmusr_update_ack = '1' then
        mmusr_update_req <= '0';
      end if;
      if ptest_update_mmusr = '1' then
        ptest_desc_addr_reg <= (others => '0');
        ptest_desc_return_pending <= '0';
      end if;
      -- A PMOVE to TC/CRP/SRP/TTx changes the translation context. Drop any
      -- fault/completion bookkeeping left from the old context so it cannot be
      -- replayed against the first access after MMU enable or root-pointer change.
      if xlat_cfg_seq_seen /= xlat_cfg_seq then
        xlat_cfg_seq_seen <= xlat_cfg_seq;
        fault_reg <= '0';
        fault_status_reg <= (others => '0');
        fault_addr_reg <= (others => '0');
        fault_fc_reg <= (others => '0');
        fault_rw_reg <= '1';
        fault_is_insn_reg <= '0';
        translation_pending <= '0';
        walk_req <= '0';
        instr_walk_pending <= '0';
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';
        ptest_desc_return_pending <= '0';
        pload_flush_pending <= '0';
        -- The walker process aborts and clears its own fault/completion state
        -- on the same context sequence change. Do not leave an acknowledge
        -- asserted here: a stuck ack masks the next real walker fault, which
        -- makes PTEST fault results disappear before MMUSR can be updated.
        walker_fault_ack <= '0';
        walker_fault_ack_pending <= '0';
        walker_completed_ack <= '0';
      -- Clear faults at start of each new translation request (MC68030 behavior)
      -- Each translation request starts with clean fault state
      -- Faults are only set if the current translation fails
      -- Process translation requests first
      elsif req = '1' then
        -- Hold the first latched fault only while the CPU is still presenting
        -- the same bus transfer. Longword accesses can advance addr_log to the
        -- second word (+2) while req remains high, but exception-entry stack
        -- writes reuse req with different FC/RW/is_insn and must retranslate.
        if fault_reg = '1' and req_prev = '1' and
           fault_fc_reg = fc and
           fault_rw_reg = rw and
           fault_is_insn_reg = is_insn and
           (addr_log = fault_addr_reg or
            addr_log = std_logic_vector(unsigned(fault_addr_reg) + 2)) then
          null;
        else
          -- Clear previous fault state for a NEW translation request ONLY if not from walker
          -- Don't clear walker faults that are still pending acknowledgment
          if walker_fault = '0' and walker_fault_ack_pending = '0' then
            fault_reg <= '0';
            fault_status_reg <= (others => '0');
          end if;
          -- (debug XLAT_REQ report removed for sim speed)
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
          
          -- Translation logic with proper precedence (no conflicting assignments):
          -- FC=7 is always unmapped, then TT0/TT1, then table-disabled/MMUDIS
          -- identity handling, then ATC/walker translation.
          if fc = "111" then
            -- MC68030 UM 9.5.5.1, Figure 9-32: FC=7 (CPU space) is UNMAPPED.
            -- CPU space accesses (interrupt acknowledge, breakpoint, etc.) are
            -- never translated by the MMU, even when translation is enabled.
            -- Use identity translation with cache inhibit (CPU space is I/O).
            addr_phys_reg      <= addr_log;
            translated_addr    <= addr_log;
            translated_fc      <= fc;
            translated_rw      <= rw;
            translated_cfg_seq <= xlat_cfg_seq;
            cache_inhibit_reg  <= '1';  -- CPU space is always cache-inhibited
            write_protect_reg  <= '0';
            fault_reg          <= '0';
            fault_status_reg   <= (others => '0');
            translation_pending <= '0';
          else
            ttr_check(TT0, addr_log, fc, is_insn, rw, rmw, tmatch0, tci0, twp0);
            ttr_check(TT1, addr_log, fc, is_insn, rw, rmw, tmatch1, tci1, twp1);
            if tmatch0 = '1' and tmatch1 = '1' then
              -- Dual transparent-translation hit: combine the attributes so the
              -- registered state and MMUSR agree with the combinational outputs.
              addr_phys_reg      <= addr_log;  -- Identity mapping
              translated_addr    <= addr_log;  -- BUG #416
              translated_fc      <= fc;        -- BUG #416
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= (tci0 or tci1);
              write_protect_reg  <= (twp0 or twp1);
              fault_reg          <= '0';
              fault_status_reg <= encode_mmusr_success(
                write_protect => (twp0 or twp1),
                modified => '0',
                transparent => '1',
                level => "000"
              );
              translation_pending <= '0';
              -- No walker needed for TTR
            elsif tmatch0 = '1' then
              -- TTR0 match - use identity translation with TTR attributes (always successful, no faults)
              addr_phys_reg      <= addr_log;  -- Identity mapping
              translated_addr    <= addr_log;  -- BUG #416
              translated_fc      <= fc;        -- BUG #416
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= tci0;
              write_protect_reg  <= twp0;
              fault_reg          <= '0';
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
              translation_pending <= '0';
              -- No walker needed for TTR
            elsif tmatch1 = '1' then
              -- TTR1 match - use identity translation with TTR attributes (always successful, no faults)
             --  -- assert false report "TTR1 HIT: Setting addr_phys to 0x" & slv_to_hstring(addr_log) severity note;
              addr_phys_reg      <= addr_log;  -- Identity mapping
              translated_addr    <= addr_log;  -- BUG #416
              translated_fc      <= fc;        -- BUG #416
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= tci1;
              write_protect_reg  <= twp1;
              fault_reg          <= '0';
              -- Set successful transparent translation MMUSR with MC68030 format
              fault_status_reg <= encode_mmusr_success(
                write_protect => twp1,     -- WP bit from TTR attributes
                modified => '0',           -- No descriptor access for TTR
                transparent => '1',        -- This IS a transparent translation
                level => "000"             -- No table walk for TTR
              );
              translation_pending <= '0';
              -- No walker needed for TTR
            elsif tc_en = '0' then
              -- Table translation disabled and no TTR matched: plain identity mapping.
              addr_phys_reg      <= addr_log;
              translated_addr    <= addr_log;
              translated_fc      <= fc;
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= '0';
              write_protect_reg  <= '0';
              fault_reg          <= '0';
              fault_status_reg   <= encode_mmusr_success(
                write_protect => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              translation_pending <= '0';
            elsif mmudis = '1' then
              -- MC68030 UM 9.2.3: MMUDIS asserted and no TTR match → identity
              -- translation; ATC searches and table searches are suppressed.
              addr_phys_reg      <= addr_log;
              translated_addr    <= addr_log;
              translated_fc      <= fc;
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= '0';
              write_protect_reg  <= '0';
              fault_reg          <= '0';
              fault_status_reg   <= encode_mmusr_success(
                write_protect => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              translation_pending <= '0';
            else
              -- No TTR match, tc_en='1', MMUDIS='0' - check ATC and potentially start walker
              hit := '0';
              for i in 0 to ATC_ENTRIES-1 loop
            -- BUG #415: Skip ATC lookup when flush is pending (1-cycle race window)
            -- atc_flush_req is set in register write process on edge N, but ATC entries
            -- aren't cleared until edge N+1 (walker process). Without this guard, the
            -- translation process could match a stale entry during that 1-cycle window.
            if atc_valid(i) = '1' and atc_flush_req = '0' then
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
              -- BUG #410: On write, skip ATC entries where M=0 (unless WP=1, which faults anyway)
              -- This forces a re-walk that sets M in the physical page descriptor
              -- Per MC68030 spec and WinUAE cpummu30.cpp line 2078
              if atc_fc(i) = fc and
                 aligned_addr = atc_log_base(i) then
                if rw = '1' or atc_attr(i)(1) = '1' or atc_attr(i)(0) = '1' or atc_buserr(i) = '1' then
                  hit := '1';
                  hit_idx := i;
                else
                  -- Write with M=0, WP=0, no buserr: invalidate entry (per WinUAE line 2086)
                  -- This prevents repeated scanning of stale entries on subsequent accesses
                  atc_mbit_inval_req <= '1';
                  atc_mbit_inval_idx <= i;
                end if;
              end if;
            end if;
          end loop;
          -- (BUG #410 M-bit check is integrated into ATC match condition above)
          if hit = '1' then
            -- ATC hit - request pseudo-LRU history bit update (handled in walker process)
            atc_mru_update_idx <= hit_idx;
            atc_mru_update_req <= '1';
            -- If a previous translation_pending bit survived after the walker had
            -- already gone idle, a valid ATC hit is a complete translation for the
            -- current request. Clear the stale pending bit so the next ATC miss can
            -- start a new walk instead of deadlocking with busy asserted.
            if translation_pending = '1' and wstate = W_IDLE and walk_req = '0' and
               walker_completed = '0' and walker_fault = '0' then
              translation_pending <= '0';
            end if;
            -- Use cached translation but check access violations
            -- But don't overwrite walker faults that are still pending
            if walker_fault = '1' and walker_fault_ack_pending = '1' then
              -- Walker fault is pending - don't overwrite with ATC results
             --  -- report "ATC_SKIP: Skipping ATC processing due to pending walker fault, addr=0x" & slv_to_hstring(addr_log) severity note;
            elsif atc_buserr(hit_idx) = '1' then
              -- Cached ATC fault entry: replay the original MMUSR fault class.
              status_tmp := x"0000" & atc_fault_status(hit_idx);
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              -- Debug: capture fault status in sticky latch
              if debug_fault_status_valid = '0' then
                debug_fault_status_latch <= status_tmp(15 downto 0);
                debug_fault_status_valid <= '1';
              end if;
              fault_addr_reg <= addr_log;
              fault_fc_reg <= fc;
              fault_rw_reg <= rw;
              fault_is_insn_reg <= is_insn;
              -- Normal CPU translations use this status for the exception
              -- frame/debug path only.  Like WinUAE, the architectural MMUSR
              -- register is only changed by PTEST or PMOVE MMUSR.
              -- Fault ATC entries intentionally do not preserve a usable physical
              -- address or final page attributes. Mirror the direct walker fault
              -- path so replay cannot probe/fill the cache via stale zeroed data.
              addr_phys_reg <= addr_log;
              translated_addr <= addr_log;
              translated_fc   <= fc;
              translated_rw   <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg <= '1';
              write_protect_reg <= '1';
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
                level => "000"                         -- N is only defined for PTEST table searches
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              fault_addr_reg <= addr_log;       -- BUG #415: Latch faulting logical address
              fault_fc_reg <= fc;               -- BUG #414: Latch FC at fault time
              fault_rw_reg <= rw;               -- BUG #414: Latch RW at fault time
              fault_is_insn_reg <= is_insn;     -- BUG #414: Latch instruction fetch flag
              -- Do not update architectural MMUSR for ordinary CPU faults.
              -- Debug: capture fault status in sticky latch
              if debug_fault_status_valid = '0' then
                debug_fault_status_latch <= status_tmp(15 downto 0);
                debug_fault_status_valid <= '1';
              end if;
              -- CRITICAL FIX: Output address even on fault
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);  -- Provide faulting address
              translated_addr <= addr_log;  -- BUG #416
              translated_fc   <= fc;        -- BUG #416
              translated_rw   <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg <= atc_attr(hit_idx)(2);  -- BUG FIX: bit 2 is CI, not bit 1 (M)
              write_protect_reg <= '1';  -- Mark as write-protected
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
                level => "000"                         -- N is only defined for PTEST table searches
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              fault_addr_reg <= addr_log;       -- BUG #415: Latch faulting logical address
              fault_fc_reg <= fc;               -- BUG #414: Latch FC at fault time
              fault_rw_reg <= rw;               -- BUG #414: Latch RW at fault time
              fault_is_insn_reg <= is_insn;     -- BUG #414: Latch instruction fetch flag
              -- Do not update architectural MMUSR for ordinary CPU faults.
              -- Debug: capture fault status in sticky latch
              if debug_fault_status_valid = '0' then
                debug_fault_status_latch <= status_tmp(15 downto 0);
                debug_fault_status_valid <= '1';
              end if;
              -- CRITICAL FIX: Output address even on supervisor fault
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              translated_addr <= addr_log;  -- BUG #416
              translated_fc   <= fc;        -- BUG #416
              translated_rw   <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
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
                translated_addr <= addr_log;  -- BUG #416
                translated_fc   <= fc;        -- BUG #416
                translated_rw   <= rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= atc_attr(hit_idx)(0);
                fault_reg <= '0';
                -- Set successful translation MMUSR with MC68030 format
                fault_status_reg <= encode_mmusr_success(
                  write_protect => atc_attr(hit_idx)(0),   -- WP bit from page attributes
                  modified => atc_attr(hit_idx)(1),        -- M bit from page descriptor
                  transparent => '0',                      -- Not a transparent translation
                  level => "000"                          -- N is only defined for PTEST table searches
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
          end if; -- tc_en = '0' vs enabled translation path
        end if; -- fault hold vs new translation
        
      end if; -- req = '1'
      -- Handle PTEST requests - perform translation and update MMUSR
      if ptest_active = '1' then
        -- PTEST request active - perform translation to test page (update MMUSR, don't cache)
        -- synthesis translate_off
        -- report "PTEST_HANDLER: active=1 tc_en=" & std_logic'image(tc_en) &
        --        " xlat_pend=" & std_logic'image(translation_pending) &
        --        " rw=" & std_logic'image(ptest_rw) &
        --        " TT0_E=" & std_logic'image(TT0(15)) severity note;
        -- synthesis translate_on
        if translation_pending = '0' then
          -- Check Transparent Translation first
          ttr_check(TT0, ptest_addr, ptest_fc, '0', ptest_rw, '0', tmatch0, tci0, twp0);  -- Use PTEST R/W from brief(9)
          ttr_check(TT1, ptest_addr, ptest_fc, '0', ptest_rw, '0', tmatch1, tci1, twp1);  -- Use PTEST R/W from brief(9)
          -- synthesis translate_off
          -- report "PTEST_TTR: tmatch0=" & std_logic'image(tmatch0) &
          --        " tmatch1=" & std_logic'image(tmatch1) &
          --        " addr31_24=" & std_logic'image(ptest_addr(31)) & std_logic'image(ptest_addr(30)) &
          --          std_logic'image(ptest_addr(29)) & std_logic'image(ptest_addr(28)) &
          --          std_logic'image(ptest_addr(27)) & std_logic'image(ptest_addr(26)) &
          --          std_logic'image(ptest_addr(25)) & std_logic'image(ptest_addr(24)) &
          --        " fc=" & std_logic'image(ptest_fc(2)) & std_logic'image(ptest_fc(1)) & std_logic'image(ptest_fc(0)) &
          --        " TT0_base=" & std_logic'image(TT0(31)) & std_logic'image(TT0(30)) &
          --          std_logic'image(TT0(29)) & std_logic'image(TT0(28)) &
          --          std_logic'image(TT0(27)) & std_logic'image(TT0(26)) &
          --          std_logic'image(TT0(25)) & std_logic'image(TT0(24)) &
          --        " TT0_fcb=" & std_logic'image(TT0(6)) & std_logic'image(TT0(5)) & std_logic'image(TT0(4)) &
          --        " TT0_fcm=" & std_logic'image(TT0(2)) & std_logic'image(TT0(1)) & std_logic'image(TT0(0))
          --        severity note;
          -- synthesis translate_on
          if tmatch0 = '1' and tmatch1 = '1' then
            -- Dual transparent-translation hit: combine attributes so PTEST
            -- observes the same result as the live transparent path.
            mmusr_update_value <= encode_mmusr_success(
              write_protect => (twp0 or twp1),
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';
          elsif tmatch0 = '1' then
            -- synthesis translate_off
            report "PTEST_TTR0_HIT: ptest_addr=" & slv_to_hex(ptest_addr) & " fc=" &
                   std_logic'image(ptest_fc(2)) & std_logic'image(ptest_fc(1)) & std_logic'image(ptest_fc(0)) severity note;
            -- synthesis translate_on
            -- TTR0 match - PTEST succeeds with transparent translation
            mmusr_update_value <= encode_mmusr_success(
              write_protect => twp0,
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';  -- BUG FIX: Signal PTEST completion after TTR0 match
          elsif tmatch1 = '1' then
            -- TTR1 match - PTEST succeeds with transparent translation
            mmusr_update_value <= encode_mmusr_success(
              write_protect => twp1,
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';  -- BUG FIX: Signal PTEST completion after TTR1 match
          elsif ptest_level = "000" then
            -- BUG #413: PTEST level=0 - ATC-only search (no table walk)
            -- Per MC68030 spec and WinUAE mmu030_ptest_atc_search():
            -- Search ATC for matching entry, report status in MMUSR
            hit := '0';
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_valid(i) = '1' then
                aligned_addr := align_addr(ptest_addr, atc_shift(i));
                if atc_fc(i) = ptest_fc and
                   aligned_addr = atc_log_base(i) then
                  hit := '1';
                  hit_idx := i;
                end if;
              end if;
            end loop;
            if hit = '1' then
              -- ATC hit - report entry status in MMUSR
              if atc_buserr(hit_idx) = '1' then
                -- Cached fault entry: report the original MMUSR fault class.
                mmusr_update_value <= x"0000" & atc_fault_status(hit_idx);
              else
                -- Normal ATC hit - report WP and M from ATC attributes.
                -- MC68030 UM 9.7.4 Table 9-3 (line 15636): for PTEST Level 0
                -- the N field is always cleared to zero; it does NOT report the
                -- level of the walk that originally populated this ATC entry.
                mmusr_update_value <= encode_mmusr_success(
                  write_protect => atc_attr(hit_idx)(0),   -- WP
                  modified => atc_attr(hit_idx)(1),        -- M
                  transparent => '0',
                  level => "000"                            -- N=0 for PTEST Level 0
                );
              end if;
            else
              -- ATC miss - set Invalid bit in MMUSR
              mmusr_update_value <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',                          -- Not in ATC
                modified => '0',
                transparent => '0',
                level => "000"
              );
            end if;
            mmusr_update_req <= '1';
            ptest_done <= '1';
          elsif tc_table_config_valid = '1' then
            -- No TTR match, level>0 - trigger walker to test translation
            -- synthesis translate_off
            report "PTEST_WALK: ptest_addr=" & slv_to_hex(ptest_addr) &
                   " fc=" & std_logic'image(ptest_fc(2)) & std_logic'image(ptest_fc(1)) & std_logic'image(ptest_fc(0)) &
                   " TT0=" & slv_to_hex(TT0) severity note;
            -- synthesis translate_on
            saved_addr_log <= ptest_addr;
            saved_fc <= ptest_fc;
            saved_is_insn <= '0';
            saved_rw <= ptest_rw;  -- BUG #17 FIX: PTEST R/W from brief(9): 0=PTESTW(write), 1=PTESTR(read)
            walk_req <= '1';
            translation_pending <= '1';
            instr_walk_pending <= '1';  -- BUG #396: Mark walk as PTEST-initiated
            ptest_walk_pending <= '1';
            ptest_desc_return_pending <= '1';
            -- M68000 PRM p.603 (PTEST description): "No descriptor bits are
            -- modified by this instruction." PTEST must leave U and M bits
            -- untouched on both table and page descriptors.
            ptest_walk_no_update <= '1';
            ptest_done <= '1';  -- BUG FIX: Signal PTEST completion after triggering walker
            -- report "PTEST: Triggered walker for addr=0x" & slv_to_hstring(ptest_addr) &
                  --  -- " fc=" & slv_to_string(ptest_fc) severity note;
          else
            -- TC validation is still pending or a configuration exception is active.
            -- Complete the PMMU instruction without starting a malformed walk.
            mmusr_update_value <= encode_mmusr_fault(
              bus_error => '0',
              limit_violation => '0',
              supervisor_violation => '0',
              write_protect => '0',
              invalid => '1',
              modified => '0',
              transparent => '0',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';
          end if;
        end if;
      end if;
      -- Handle PLOAD requests - flush existing ATC entry then walk to fill ATC
      -- Per MC68030 spec and WinUAE: PLOAD always flushes the page from ATC first,
      -- then unconditionally performs a table walk to (re)fill the ATC entry.
      if pload_active = '1' then
        if tc_table_config_valid = '1' and translation_pending = '0' then
          -- Always trigger walker to load fresh translation
          -- The walker process handles flushing the old ATC entry via pload_flush_pending
          saved_addr_log <= pload_addr;
          saved_fc <= pload_fc;
          saved_is_insn <= '0';
          saved_rw <= pload_rw;
          walk_req <= '1';
          translation_pending <= '1';
          instr_walk_pending <= '1';
          pload_flush_pending <= '1';  -- Tell walker to flush page before filling ATC
        end if;
      end if;
      
      -- Handle walker completion and walker faults immediately (don't wait for req='0')
      if walker_fault = '1' and walker_fault_ack = '0' then
        -- Walker faulted - process immediately regardless of req state
        status_tmp := walker_fault_status;
        if ptest_walk_pending = '0' then
          -- WinUAE only stamps MMUSR.N for PTEST/table-search requests.
          -- Ordinary translation faults, including cached BADFEED entries, keep N=0.
          status_tmp(2 downto 0) := "000";
        end if;
        -- BUG #396b: PTEST/PLOAD walks must NOT set fault_reg or corrupt addr_phys_reg.
        -- Walker faults during PTEST/PLOAD should only update MMUSR, not trigger CPU bus error.
        -- Without this guard, PTEST W on a WP page causes walker_fault -> fault_reg=1 ->
        -- make_berr=1 -> setinterrupt -> spurious bus error exception.
        -- BUG #404: Skip when addr_log has moved past saved_addr_log
        if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
          fault_reg <= '1';
          fault_status_reg <= status_tmp;
          -- Debug: capture fault status in sticky latch
          if debug_fault_status_valid = '0' then
            debug_fault_status_latch <= status_tmp(15 downto 0);
            debug_fault_status_valid <= '1';
          end if;
          fault_addr_reg <= saved_addr_log;     -- BUG #415: Latch faulting logical address
          fault_fc_reg <= saved_fc;             -- BUG #414: Latch FC at fault time
          fault_rw_reg <= saved_rw;             -- BUG #414: Latch RW at fault time
          fault_is_insn_reg <= saved_is_insn;   -- BUG #414: Latch instruction fetch flag
          -- CRITICAL FIX: On fault, output the faulting logical address
          -- This prevents the CPU from using garbage/uninitialized addresses
          addr_phys_reg <= saved_addr_log;  -- Pass through faulting address
          translated_addr <= saved_addr_log;  -- BUG #416
          translated_fc   <= saved_fc;        -- BUG #416
          translated_rw   <= saved_rw;
          translated_cfg_seq <= xlat_cfg_seq;
          cache_inhibit_reg <= '1';  -- Inhibit cache on faults
          write_protect_reg <= '1';  -- Protect on faults
        end if;
        mmusr_update_value <= status_tmp;
        -- MC68030 UM 9.7.3: PLOAD does not alter MMUSR; only PTEST updates it
        if ptest_walk_pending = '1' then
          if ptest_desc_return_pending = '1' then
            ptest_desc_addr_reg <= desc_addr_reg;
            ptest_desc_return_pending <= '0';
          end if;
          mmusr_update_req <= '1';
        end if;
        translation_pending <= '0';
        instr_walk_pending <= '0';  -- Clear PTEST/PLOAD flag on walker fault too
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';  -- Clear any non-mutating-walk override
        pload_flush_pending <= '0';  -- Clear PLOAD flush flag on fault
        -- Acknowledge the fault and track pending state
        walker_fault_ack <= '1';
        walker_fault_ack_pending <= '1';
      elsif walker_completed = '1' then
        if ptest_desc_return_pending = '1' then
          ptest_desc_addr_reg <= desc_addr_reg;
          ptest_desc_return_pending <= '0';
        end if;
        -- Walker completed - clear PLOAD flush flag if set
        pload_flush_pending <= '0';
        -- Walker completed successfully - clear any previous fault status
        -- A successful walker completion means this specific translation succeeded
        -- First check if the completed request would have been handled by TTR
        ttr_check(TT0, saved_addr_log, saved_fc, saved_is_insn, saved_rw, '0', tmatch0, tci0, twp0);
        ttr_check(TT1, saved_addr_log, saved_fc, saved_is_insn, saved_rw, '0', tmatch1, tci1, twp1);
        if tmatch0 = '1' or tmatch1 = '1' then
          -- This request hits TTR - don't override TTR results that are already set
          -- TTR results already handled in main translation logic. The walker
          -- completion still satisfies the pending request, so clear the pending
          -- bit here as well.
          translation_pending <= '0';
        else
          -- No TTR hit - check ATC for walker results
          hit := '0';
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              aligned_addr := align_addr(saved_addr_log, atc_shift(i));
              if atc_fc(i) = saved_fc and
                 aligned_addr = atc_log_base(i) then
                hit := '1';
                hit_idx := i;
              end if;
            end if;
          end loop;
          if hit = '1' then
            -- BUG #435: Check if this is a bus error ATC entry (cached fault from W_FAULT)
            -- W_FAULT caches buserr entries AND sets walker_completed. The walker_fault
            -- handler runs first (higher priority), but walker_completed fires on the next
            -- cycle. Without this check, buserr entries are treated as valid translations,
            -- clearing fault_reg and setting addr_phys_reg to garbage (0x00000000).
            if atc_buserr(hit_idx) = '1' then
              -- Bus error entry - do NOT treat as valid translation
              -- fault_reg was already set by the walker_fault handler, preserve it
              -- addr_phys_reg was already set to saved_addr_log by fault handler
              -- Just update MMUSR for PTEST visibility using the cached original status.
              status_tmp := x"0000" & atc_fault_status(hit_idx);
              mmusr_update_value <= status_tmp;
              -- MC68030 UM 9.7.3: PLOAD does not alter MMUSR
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            -- Walker filled ATC successfully - check access violations for the original request
            -- BUG #17 FIX: saved_rw='0' is WRITE, saved_rw='1' is READ
            elsif saved_rw = '0' and atc_attr(hit_idx)(0) = '1' then
              -- Write to write-protected page - generate fault
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '1',                   -- This is a WP fault
                invalid => '0',                         -- Descriptor was valid
                modified => '0',
                transparent => '0',
                level => "000"                         -- N is only defined for PTEST table searches
              );
              -- BUG #396: PTEST/PLOAD walks must NOT update addr_phys_reg or fault_reg.
              -- These are instruction-initiated walks that only test/preload the ATC.
              -- Updating addr_phys_reg corrupts the ongoing code fetch translation.
              -- BUG #404: When the current addr_log has moved past saved_addr_log
              -- (e.g., addr auto-incremented during a longword bus cycle), the req='1'
              -- block above already set addr_phys_reg for the CURRENT address.
              -- Don't overwrite it with the stale saved_addr_log result.
              if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
                fault_reg <= '1';
                fault_status_reg <= status_tmp;
                fault_addr_reg <= saved_addr_log;     -- BUG #415: Latch faulting logical address
                fault_fc_reg <= saved_fc;             -- BUG #414: Latch FC at fault time
                fault_rw_reg <= saved_rw;             -- BUG #414: Latch RW at fault time
                fault_is_insn_reg <= saved_is_insn;   -- BUG #414: Latch instruction fetch flag
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                addr_phys_reg <= std_logic_vector(phys_result);
                translated_addr <= saved_addr_log;  -- BUG #416
                translated_fc   <= saved_fc;        -- BUG #416
                translated_rw   <= saved_rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= '1';
              end if;
              mmusr_update_value <= status_tmp;
              -- MC68030 UM 9.7.3: PLOAD does not alter MMUSR
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            elsif saved_fc(2) = '0' and atc_attr(hit_idx)(3) = '0' then
              -- User trying to access supervisor-only page - generate fault
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '1',            -- This is a supervisor violation
                write_protect => atc_attr(hit_idx)(0),  -- From translated attributes
                invalid => '0',                         -- Descriptor was valid
                modified => '0',
                transparent => '0',
                level => "000"                         -- N is only defined for PTEST table searches
              );
              -- BUG #396: Skip addr_phys_reg update for PTEST/PLOAD walks
              -- BUG #404: Skip when addr_log has moved past saved_addr_log
              if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
                fault_reg <= '1';
                fault_status_reg <= status_tmp;
                fault_addr_reg <= saved_addr_log;     -- BUG #415: Latch faulting logical address
                fault_fc_reg <= saved_fc;             -- BUG #414: Latch FC at fault time
                fault_rw_reg <= saved_rw;             -- BUG #414: Latch RW at fault time
                fault_is_insn_reg <= saved_is_insn;   -- BUG #414: Latch instruction fetch flag
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                addr_phys_reg <= std_logic_vector(phys_result);
                translated_addr <= saved_addr_log;  -- BUG #416
                translated_fc   <= saved_fc;        -- BUG #416
                translated_rw   <= saved_rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= atc_attr(hit_idx)(0);
              end if;
              mmusr_update_value <= status_tmp;
              -- MC68030 UM 9.7.3: PLOAD does not alter MMUSR
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            else
              -- Valid access - update outputs and clear faults for successful translation
              -- BUG #396: Skip addr_phys_reg update for PTEST/PLOAD walks
              -- BUG #404: Skip when addr_log has moved past saved_addr_log
              if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                addr_phys_reg <= std_logic_vector(phys_result);
                translated_addr <= saved_addr_log;  -- BUG #416
                translated_fc   <= saved_fc;        -- BUG #416
                translated_rw   <= saved_rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= atc_attr(hit_idx)(0);
                fault_reg <= '0';
              end if;
              -- Set successful translation MMUSR with MC68030 format
              status_tmp := encode_mmusr_success(
                write_protect => atc_attr(hit_idx)(0),   -- WP bit from page attributes
                modified => atc_attr(hit_idx)(1),        -- M bit from page descriptor
                transparent => '0',                      -- Not a transparent translation
                level => "000"                          -- N is only defined for PTEST table searches
              );
              fault_status_reg <= status_tmp;
              -- BUG #374 FIX: Update MMUSR on successful walker completion
              mmusr_update_value <= status_tmp;
              -- MC68030 UM 9.7.3: PLOAD does not alter MMUSR
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            end if;
          else
            -- No ATC hit found after walker completion - this shouldn't happen normally
            -- But clear translation_pending anyway to prevent deadlock
            -- BUG #396: Skip addr_phys_reg update for PTEST/PLOAD walks
            -- BUG #404: Skip when addr_log has moved past saved_addr_log
            if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
              addr_phys_reg <= saved_addr_log;  -- Pass through logical address as fallback
              translated_addr <= saved_addr_log;  -- BUG #416
              translated_fc   <= saved_fc;        -- BUG #416
              translated_rw   <= saved_rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg <= '1';  -- Inhibit cache when walker fails to populate ATC
              write_protect_reg <= '0';  -- No protection info available
              -- BUG #142 FIX: Do NOT clear fault_reg if walker just faulted!
              if walker_fault_ack_pending = '0' then
                fault_reg <= '0';
              end if;
            end if;
          end if; -- hit = '1'
          -- Always clear translation_pending when walker completes, regardless of result
          translation_pending <= '0';
        end if; -- else tmatch0
        -- BUG #396: Clear instr_walk_pending on walker completion
        instr_walk_pending <= '0';
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';  -- Clear any non-mutating-walk override
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

      -- Stale-pending recovery: if the walker is idle and there is no completion
      -- or fault left to consume, a pending bit by itself cannot make progress.
      -- This can happen when the CPU address moves while a fault/completion
      -- handshake is resolving; an ATC miss with translation_pending still set
      -- will otherwise never assert walk_req, leaving busy high forever.
      if translation_pending = '1' and wstate = W_IDLE and walk_req = '0' and
         walker_completed = '0' and walker_fault = '0' and
         walker_fault_ack_pending = '0' then
        translation_pending <= '0';
        instr_walk_pending <= '0';
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';
        ptest_desc_return_pending <= '0';
        pload_flush_pending <= '0';
      end if;
      
      -- Clear walk request when walker starts (to avoid continuous requests)
      if wstate /= W_IDLE then
        walk_req <= '0';
      end if;
      -- Debug sticky latch: captured at fault sites above (alongside fault_reg <= '1')
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
    variable limit_fault : boolean;  -- BUG FIX: Track limit violations within same process cycle
    variable limit_value : unsigned(14 downto 0);
    variable rp_high : std_logic_vector(31 downto 0);
    -- Pseudo-LRU ATC replacement
    variable replace_idx : integer range 0 to ATC_ENTRIES-1;
    variable found_invalid : boolean;
    variable found_match : boolean;
    variable all_mru_set : boolean;
    -- Early termination offset calculation
    variable early_term_desc_addr : std_logic_vector(31 downto 0);
    variable early_term_page_addr : std_logic_vector(31 downto 0);
    variable early_term_offset    : std_logic_vector(31 downto 0);
    -- Decode page attributes into variables before reusing them in this cycle.
    -- Using the walk_attr signal directly in W_PAGE would read the previous page's
    -- latched value because signal assignments don't take effect until the process suspends.
    variable page_user_access     : std_logic;
    variable page_cache_inhibit   : std_logic;
    variable page_modified        : std_logic;
    variable page_write_protect   : std_logic;
  begin
    if nreset = '0' then
      for i in 0 to ATC_ENTRIES-1 loop
        atc_valid(i)     <= '0';
        atc_log_base(i)  <= (others => '0');
        atc_phys_base(i) <= (others => '0');
        atc_fc(i)        <= (others => '0');
        atc_shift(i)     <= 12;
        atc_page_size(i) <= 12;  -- MC68030: PS=12 (4KB pages)
        atc_attr(i)      <= (others => '0');
        atc_level(i)     <= (others => '0');  -- BUG #412: walk level for MMUSR
        atc_buserr(i)    <= '0';  -- BUG #436: Initialize bus error flag
        atc_fault_status(i) <= (others => '0');
      end loop;
      for i in 0 to ATC_ENTRIES-1 loop
        atc_mru(i)   <= '0';
      end loop;
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
      walk_is_root_pointer <= '0';  -- Root pointer DT=01 flag
      walker_timeout_counter <= 0;  -- BUG #387: Reset timeout counter
      xlat_cfg_seq_walk_seen <= (others => '0');
      ptr1_desc_addr_reg <= (others => '0');
      ptr1_desc_data_reg <= (others => '0');
      ptr2_desc_addr_reg <= (others => '0');
      ptr2_desc_data_reg <= (others => '0');
      ptr3_desc_addr_reg <= (others => '0');
      ptr3_desc_data_reg <= (others => '0');
      last_mem_rdat <= (others => '0');
      walk_page_from_indirect <= '0';
    elsif rising_edge(clk) then
      if xlat_cfg_seq_walk_seen /= xlat_cfg_seq then
        xlat_cfg_seq_walk_seen <= xlat_cfg_seq;
        -- A register write changed the translation context. Any in-flight walk
        -- was based on the old TC/root/TTR state, so abort it before it can fill
        -- a stale ATC entry after the flush.
        wstate <= W_IDLE;
        mem_req <= '0';
        mem_we <= '0';
        mem_addr <= (others => '0');
        mem_wdat <= (others => '0');
        walk_fault <= '0';
        walker_fault <= '0';
        walker_fault_status <= (others => '0');
        walker_completed <= '0';
        walker_timeout_counter <= 0;
        desc_update_needed <= '0';
      else
        if mem_ack = '1' then
          last_mem_rdat <= mem_rdat;
        end if;
        -- BUG #387 FIX: Timeout mechanism to prevent walker deadlocks
        -- Monitor mem_req without mem_ack and force fault after timeout
        if wstate = W_IDLE then
          walker_timeout_counter <= 0;  -- Reset counter when idle
        elsif mem_req = '1' and mem_ack = '0' and mem_berr = '0' then
          -- Waiting for memory response - increment timeout counter
          if walker_timeout_counter < 1023 then
            walker_timeout_counter <= walker_timeout_counter + 1;
          end if;
        elsif mem_ack = '1' or mem_berr = '1' then
          -- Got response - reset timeout counter
          walker_timeout_counter <= 0;
        end if;
        -- Check for timeout condition BEFORE case statement to prevent override
        if walker_timeout_counter >= WALKER_TIMEOUT_CYCLES and mem_req = '1' then
          -- Timeout exceeded - force bus error fault and transition to W_FAULT
          walk_fault <= '1';
          walker_fault <= '1';
          walker_fault_status <= encode_mmusr_fault(
            bus_error => '1',                -- B bit: timeout is a bus error
            limit_violation => '0',
            supervisor_violation => '0',
            write_protect => '0',
            invalid => '1',                  -- No valid translation available
            modified => '0',
            transparent => '0',
            level => std_logic_vector(to_unsigned(walk_level, 3))
          );
          mem_req <= '0';  -- Stop requesting memory
          walker_timeout_counter <= 0;  -- Reset counter
          wstate <= W_FAULT;  -- Transition to fault state (which will set walker_completed)
        else
          -- Normal walker state machine (only runs if not in timeout)
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
            -- WinUAE flushes the target page before the PLOAD table search.
            -- Do this at walk start so cached fault entries are removed even
            -- if the following table walk faults before reaching W_PAGE.
            if pload_flush_pending = '1' then
              for i in 0 to ATC_ENTRIES-1 loop
                if atc_valid(i) = '1' then
                  if align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                    atc_valid(i) <= '0';
                    atc_mru(i) <= '0';
                    atc_buserr(i) <= '0';
                    atc_fault_status(i) <= (others => '0');
                  end if;
                end if;
              end loop;
            end if;
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
            desc_addr_reg <= (others => '0');
            walk_desc <= (others => '0');
            walk_desc_high <= (others => '0');
            walk_desc_low <= (others => '0');
            walk_desc_is_long <= '0';
            walk_page_from_indirect <= '0';
            indirect_addr <= (others => '0');
            indirect_target_long <= '0';
            walk_limit_valid <= '0';  -- BUG #155: Clear limit tracking at walk start
            walk_supervisor <= '0';  -- BUG #157: Clear cumulative S bit at walk start
            walk_write_protect <= '0';  -- Clear cumulative WP bit at walk start
            walk_is_root_pointer <= '0';  -- Not a root pointer early termination by default
            ptr1_desc_addr_reg <= (others => '0');
            ptr1_desc_data_reg <= (others => '0');
            ptr2_desc_addr_reg <= (others => '0');
            ptr2_desc_data_reg <= (others => '0');
            ptr3_desc_addr_reg <= (others => '0');
            ptr3_desc_data_reg <= (others => '0');
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
              -- BUG #409: Root pointer DT determines stride for root table
              -- CRP_H/SRP_H format: L/U[31], Limit[30:16], Reserved[15:2], DT[1:0]
              walk_parent_dt_long <= SRP_H(1) and SRP_H(0); -- DT=11 -> 8-byte entries
              -- MC68030 spec: Root pointer DT=00 means invalid - fault immediately, no memory read
              if SRP_H(1 downto 0) = "00" then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '0',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => "000"
                );
                wstate <= W_FAULT;
              elsif SRP_H(1 downto 0) = "01" then
                -- MC68030: Root pointer DT=01 is early termination page descriptor.
                -- The root pointer itself IS the page descriptor - no memory read needed.
                -- Per WinUAE cpummu30.cpp line 1278-1281 and MC68030 spec.
                walk_desc_high <= SRP_H;
                walk_desc_low <= SRP_L;
                walk_desc <= SRP_L;
                walk_desc_is_long <= '1';  -- Root pointers are always 64-bit (long format)
                walk_is_root_pointer <= '1';  -- Skip S/WP/U/M checks at root level
                wstate <= W_PAGE;
              else
                walk_is_root_pointer <= '0';
                wstate <= W_ROOT;
              end if;
            else -- User or supervisor without SRE
              walk_addr <= CRP_L(31 downto 4) & "0000"; -- CPU Root Pointer (LOW word = table address)
              -- BUG #409: Root pointer DT determines stride for root table
              walk_parent_dt_long <= CRP_H(1) and CRP_H(0); -- DT=11 -> 8-byte entries
              -- MC68030 spec: Root pointer DT=00 means invalid - fault immediately, no memory read
              if CRP_H(1 downto 0) = "00" then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '0',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => "000"
                );
                wstate <= W_FAULT;
              elsif CRP_H(1 downto 0) = "01" then
                -- MC68030: Root pointer DT=01 is early termination page descriptor.
                walk_desc_high <= CRP_H;
                walk_desc_low <= CRP_L;
                walk_desc <= CRP_L;
                walk_desc_is_long <= '1';
                walk_is_root_pointer <= '1';
                wstate <= W_PAGE;
              else
                walk_is_root_pointer <= '0';
                wstate <= W_ROOT;
              end if;
            end if;
          end if;
          
        when W_ROOT =>
          -- Read root table descriptor - deadlock-proof design
          limit_fault := false;  -- BUG FIX: Reset limit fault tracker
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          -- MC68030 Root Pointer Limit Check
          -- CRP_H/SRP_H HIGH-word layout: L/U[31], Limit[30:16], Reserved[15:2], DT[1:0]
          -- MC68030 UM 9.5.2 line 14877-14879 and 9.5.1.2 line 14654-14656:
          -- "The root pointer includes a limit field that applies when the
          --  function code lookup is not used (the FCL bit of the TC register
          --  is zero)." / "when the FCL field of the TC register is set, the
          --  L/U and LIMIT fields of the root pointer registers are unused."
          -- Skip the check entirely under FCL=1; the root table is indexed by
          -- the 3-bit FC (0..7), which is always within bounds.
          if tc_fcl = '0' then
            -- Select appropriate root pointer HIGH word based on FC and SRE
            if saved_fc(2) = '1' and tc_sre = '1' then
              rp_high := SRP_H;  -- Supervisor Root Pointer
            else
              rp_high := CRP_H;  -- CPU Root Pointer
            end if;
            lu_flag := rp_high(31);           -- L/U: 1=lower limit, 0=upper limit
            limit_value := unsigned(rp_high(30 downto 16));  -- 15-bit LIMIT
            if lu_flag = '1' then
              -- Lower limit: table_index must be >= limit.
              -- Edge case: L/U=1 and LIMIT=0 effectively disables the check
              -- (to_unsigned(x,15) < 0 is always false).
              if to_unsigned(table_index, 15) < limit_value then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '1',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => std_logic_vector(to_unsigned(walk_level, 3))
                );
                wstate <= W_FAULT;
                limit_fault := true;
              end if;
            else
              -- Upper limit: table_index must be <= limit.
              -- Edge case: L/U=0 and LIMIT=$7FFF effectively disables the check.
              if to_unsigned(table_index, 15) > limit_value then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '1',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => std_logic_vector(to_unsigned(walk_level, 3))
                );
                wstate <= W_FAULT;
                limit_fault := true;
              end if;
            end if;
          end if;
          desc_addr_v := walk_addr(31 downto 4) & "0000"; -- Align to table boundary
          -- BUG #409: Stride depends on parent descriptor DT (4 bytes for DT=10, 8 bytes for DT=11)
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
          -- Debug: Log walker state for failing test addresses
          if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
            -- report "DEBUG_WALKER: W_ROOT addr=0x" & slv_to_hstring(saved_addr_log) &
                   -- " level=" & integer'image(walk_level) &
                   -- " table_index=" & integer'image(table_index) &
                   -- " desc_addr=0x" & slv_to_hstring(desc_addr_v)
             --  -- severity note;
          end if;
          -- Simple memory request - always deassert req after ack
          if mem_req = '0' and not limit_fault then
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
              invalid => '1',                  -- No valid translation available
              modified => '0',
              transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got response - process HIGH word of descriptor
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;  -- Save HIGH word for long format
            ptr1_desc_addr_reg <= desc_addr_reg;
            ptr1_desc_data_reg <= mem_rdat;
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
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              -- Debug: Track invalid descriptor
              -- report "INVALID_DESC_ROOT: Invalid descriptor at level=" & integer'image(walk_level) &
                     -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
            elsif walk_parent_dt_long = '1' then
              -- Current entry is long because the parent selected 8-byte descriptors.
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
            elsif is_final_table_level(tc_fcl, 0, tc_idx_bits) then
              -- DT=10 at the final level is a short-format indirect descriptor.
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);
                wstate <= W_INDIRECT;
              end if;
            else
              -- Short-format table descriptor; DT selects the next table format.
              -- TABLE descriptor U-bit writeback: set U before continuing
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR1;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop: stop after ptest_level descriptors read
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';  -- Short format
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                walk_level <= walk_level + 1;
                -- BUG #155 FIX: Short format has NO limit field
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects 8-byte descriptors in the next table
                wstate <= W_PTR1;
              end if;
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete descriptor
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_ROOT_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;
            -- Now we have both HIGH (walk_desc_high) and LOW (walk_desc_low) words
            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Page descriptor - go to W_PAGE for processing
             --  -- report "W_ROOT_LOW: Long-format page descriptor, continuing to W_PAGE" severity note;
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 0, tc_idx_bits) then
              -- DT=11 at the final level is a long-format indirect descriptor.
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_INDIRECT;
              end if;
            else
              -- Table descriptor - extract address from LOW word and continue
              -- TABLE descriptor U-bit writeback (U is bit 3 of HIGH word)
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR1;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                -- BUG #155 FIX: Save limit from long-format table descriptor for next level
                walk_limit_valid <= '1';  -- Long format always has limit
                walk_limit_lu    <= walk_desc_high(31);  -- L/U flag
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));  -- 15-bit limit
                -- BUG #157 FIX: Accumulate S bit from long-format TABLE descriptor
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT=11 selects 8-byte descriptors in the next table
                wstate <= W_PTR1;
              end if;
            end if;
          end if;
        when W_PTR1 =>
          -- Read level 1 table descriptor - deadlock-proof design
          limit_fault := false;  -- BUG FIX: Reset limit fault tracker
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          -- BUG #409: Stride depends on parent descriptor DT (4 bytes for DT=10, 8 bytes for DT=11)
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
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
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              else
                -- Upper limit: table_index must be <= limit
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              end if;
            end if;
            -- Only proceed if no limit violation
            if not limit_fault then
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got response - process HIGH word of descriptor
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;  -- Save HIGH word for long format
            ptr2_desc_addr_reg <= desc_addr_reg;
            ptr2_desc_data_reg <= mem_rdat;
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
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
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
            elsif walk_parent_dt_long = '1' then
              -- Current entry is long because the parent selected 8-byte descriptors.
             --  -- report "W_PTR1: Long-format descriptor detected (DT=11), reading LOW word" severity note;
              walk_desc_is_long <= '1';
              wstate <= W_PTR1_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Page descriptor found (short format)
              walk_desc_is_long <= '0';  -- Short format
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 1, tc_idx_bits) then
              -- No more TI levels after this (FCL-aware check)
              -- DT=10 at final level = short-format indirect descriptor
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';  -- Short format indirect
                indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address (4-byte aligned)
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects a long-format indirect target
               --  -- report "W_PTR1: Short indirect descriptor detected (DT=10, final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
                wstate <= W_INDIRECT;
              end if;
            else
              -- Continue to next level (short format table descriptor)
              -- TABLE descriptor U-bit writeback
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR2;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects 8-byte descriptors in the next table
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';  -- Short format
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                -- BUG #155 FIX: Short format has NO limit field
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects 8-byte descriptors in the next table
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                wstate <= W_PTR2;
              end if;
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete descriptor
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_PTR1_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;
            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Page descriptor
             --  -- report "W_PTR1_LOW: Long-format page descriptor, continuing to W_PAGE" severity note;
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 1, tc_idx_bits) then
              -- No more TI levels after this (FCL-aware check)
              -- DT=11 at final level = long-format indirect descriptor
              -- Target address is in LOW word bits 31:2 (longword aligned)
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT selects indirect target format
               --  -- report "W_PTR1_LOW: Long indirect descriptor (DT=11, final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
                wstate <= W_INDIRECT;
              end if;
            else
              -- Table descriptor - extract address from LOW word and continue
              -- TABLE descriptor U-bit writeback (U is bit 3 of HIGH word)
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR2;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                -- BUG #155 FIX: Save limit from long-format table descriptor for next level
                walk_limit_valid <= '1';  -- Long format always has limit
                walk_limit_lu    <= walk_desc_high(31);  -- L/U flag
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));  -- 15-bit limit
                -- BUG #157 FIX: Accumulate S bit from long-format TABLE descriptor
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT=11 selects 8-byte descriptors in the next table
                wstate <= W_PTR2;
              end if;
            end if;
          end if;
        when W_PTR2 =>
          -- Read level 2 table descriptor - deadlock-proof design
          limit_fault := false;  -- BUG FIX: Reset limit fault tracker
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          -- BUG #409: Stride depends on parent descriptor DT (4 bytes for DT=10, 8 bytes for DT=11)
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
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
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              else
                -- Upper limit: table_index must be <= limit
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              end if;
            end if;
            -- Only proceed if no limit violation
            if not limit_fault then
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got response - process HIGH word of descriptor
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;  -- Save HIGH word for long format
            ptr3_desc_addr_reg <= desc_addr_reg;
            ptr3_desc_data_reg <= mem_rdat;
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
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
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
            elsif walk_parent_dt_long = '1' then
              -- Current entry is long because the parent selected 8-byte descriptors.
             --  -- report "W_PTR2: Long-format descriptor detected (DT=11), reading LOW word" severity note;
              walk_desc_is_long <= '1';
              wstate <= W_PTR2_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Short format page descriptor
              walk_desc_is_long <= '0';  -- Short format
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 2, tc_idx_bits) then
              -- No more TI levels after this (FCL-aware check)
              -- DT=10 at final level = short-format indirect descriptor
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';  -- Short format indirect
                indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address (4-byte aligned)
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects a long-format indirect target
               --  -- report "W_PTR2: Short indirect descriptor detected (DT=10, final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
                wstate <= W_INDIRECT;
              end if;
            else
              -- Short format table descriptor
              -- TABLE descriptor U-bit writeback
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR3;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects 8-byte descriptors in the next table
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';  -- Short format
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                -- BUG #155 FIX: Short format has NO limit field
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects 8-byte descriptors in the next table
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                wstate <= W_PTR3;
              end if;
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete descriptor
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_PTR2_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;
            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Page descriptor
             --  -- report "W_PTR2_LOW: Long-format page descriptor, continuing to W_PAGE" severity note;
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 2, tc_idx_bits) then
              -- No more TI levels after this (FCL-aware check)
              -- DT=11 at final level = long-format indirect descriptor
              -- Target address is in LOW word bits 31:2 (longword aligned)
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT selects indirect target format
               --  -- report "W_PTR2_LOW: Long indirect descriptor (DT=11, final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
                wstate <= W_INDIRECT;
              end if;
            else
              -- Table descriptor - extract address from LOW word and continue
              -- TABLE descriptor U-bit writeback (U is bit 3 of HIGH word)
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR3;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                -- BUG #155 FIX: Save limit from long-format table descriptor for next level
                walk_limit_valid <= '1';  -- Long format always has limit
                walk_limit_lu    <= walk_desc_high(31);  -- L/U flag
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));  -- 15-bit limit
                -- BUG #157 FIX: Accumulate S bit from long-format TABLE descriptor
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT=11 selects 8-byte descriptors in the next table
                wstate <= W_PTR3;
              end if;
            end if;
          end if;
        when W_PTR3 =>
          limit_fault := false;  -- BUG FIX: Reset limit fault tracker
          -- Final level - must be page descriptor - deadlock-proof design
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          -- BUG #409: Stride depends on parent descriptor DT (4 bytes for DT=10, 8 bytes for DT=11)
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
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
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              else
                -- Upper limit: table_index must be <= limit
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              end if;
            end if;
            -- Only proceed if no limit violation (wstate unchanged means OK)
            if not limit_fault then
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
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
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              -- Debug: Track invalid descriptor
              -- report "INVALID_DESC_PTR3: Invalid descriptor at level=" & integer'image(walk_level) &
                     -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                    --  -- " desc=0x" & slv_to_hstring(mem_rdat) severity note;
              wstate <= W_FAULT;
            elsif walk_parent_dt_long = '1' then
              -- Current entry is long because the parent selected 8-byte descriptors.
             --  -- report "W_PTR3: Long-format descriptor detected (DT=11), reading LOW word" severity note;
              walk_desc_is_long <= '1';
              wstate <= W_PTR3_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Short format page descriptor
              walk_desc_is_long <= '0';  -- Short format
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 3, tc_idx_bits) then
              -- DT=10 at final level = short-format indirect descriptor (MC68030 spec section 9.5.3.2)
              -- The descriptor points to another descriptor (the target) that will be used
              -- Target address is in bits 31:2 (must be 4-byte aligned)
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';  -- Short format indirect
                indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address (4-byte aligned)
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects a long-format indirect target
               --  -- report "W_PTR3: Short indirect descriptor detected (DT=10, final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
                wstate <= W_INDIRECT;
              end if;
            else
              -- FCL=1 and TID!=0: Continue to W_PTR4 (5th level)
              -- TABLE descriptor U-bit writeback
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR4;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects 8-byte descriptors in the next table
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';  -- Short format table descriptor
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';  -- Short format has no limit
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects 8-byte descriptors in the next table
                walk_write_protect <= walk_write_protect or mem_rdat(2);  -- BUG #438: Accumulate WP from short-format table descriptors
                wstate <= W_PTR4;
              end if;
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete long-format descriptor
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
           --  -- report "W_PTR3_LOW: Got LOW word=0x" & slv_to_hstring(mem_rdat) severity note;
            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Long-format page descriptor
             --  -- report "W_PTR3_LOW: Long-format page descriptor, continuing to W_PAGE" severity note;
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 3, tc_idx_bits) then
              -- At final level with DT=11, this is a LONG INDIRECT descriptor
              -- Target address is in LOW word bits 31:2 (longword aligned)
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";  -- Extract target address
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT selects indirect target format
               --  -- report "W_PTR3_LOW: Long indirect descriptor (final level), target addr=0x" & slv_to_hstring(mem_rdat(31 downto 2) & "00") severity note;
                wstate <= W_INDIRECT;
              end if;
            else
              -- FCL=1 and TID!=0: Continue to W_PTR4 (5th level)
              -- TABLE descriptor U-bit writeback (U is bit 3 of HIGH word)
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR4;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              -- PTEST level early-stop
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                -- Save limit from long-format table descriptor for next level
                walk_limit_valid <= '1';  -- Long format always has limit
                walk_limit_lu    <= walk_desc_high(31);  -- L/U flag
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));  -- 15-bit limit
                -- Accumulate S bit from long-format TABLE descriptor
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);  -- Accumulate WP from table descriptors
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT=11 selects 8-byte descriptors in the next table
                wstate <= W_PTR4;
              end if;
            end if;
          end if;
        when W_PTR4 =>
          limit_fault := false;  -- BUG FIX: Reset limit fault tracker
          -- Level 4 (TID when FCL=1) - always final level before page descriptor
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          -- BUG #409: Stride depends on parent descriptor DT (4 bytes for DT=10, 8 bytes for DT=11)
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
          -- Simple memory request - always deassert req after ack
          if mem_req = '0' then
            -- Check limit from previous level's long-format table descriptor
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                -- Lower limit: table_index must be >= limit
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              else
                -- Upper limit: table_index must be <= limit
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;  -- BUG FIX: Track limit violation
                end if;
              end if;
            end if;
            -- Only proceed if no limit violation (wstate unchanged means OK)
            if not limit_fault then
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;  -- Save for use in W_PTR4_LOW state
            end if;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
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
              walk_desc_is_long <= '0';
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              wstate <= W_FAULT;
            elsif walk_parent_dt_long = '1' then
              -- Current entry is long because the parent selected 8-byte descriptors.
              walk_desc_is_long <= '1';
              wstate <= W_PTR4_LOW;
            elsif desc_is_page(mem_rdat) then
              -- Short format page descriptor
              walk_desc_is_long <= '0';
              wstate <= W_PAGE;
            else
              -- DT=10 at final level = short-format indirect descriptor
              -- W_PTR4 is always final level (TID is last TI field)
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);  -- DT=11 selects a long-format indirect target
                wstate <= W_INDIRECT;
              end if;
            end if;
          end if;
        when W_PTR4_LOW =>
          -- Read LOW word of long-format descriptor at desc_addr_reg+4
          -- W_PTR4 is always final level, so DT=11 is long-format indirect descriptor
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            -- Got LOW word - save it and process complete descriptor
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
            -- Determine next state based on descriptor type
            if desc_is_page(walk_desc_high) then
              -- Long-format page descriptor
              wstate <= W_PAGE;
            else
              -- DT=11 at final level = long-format indirect descriptor
              -- Target address is in LOW word bits 31:2 (longword aligned)
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);  -- DT selects indirect target format
                wstate <= W_INDIRECT;
              end if;
            end if;
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
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
              walk_page_from_indirect <= '1';
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
                level => std_logic_vector(to_unsigned(walk_level + 2, 3))
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
                level => std_logic_vector(to_unsigned(walk_level + 2, 3))
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level + 1, 3))
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
          -- Process page descriptor and validate completely.
          -- Long-format descriptors carry DT/S/WP/etc. in HIGH and the
          -- physical page base in LOW. Validating LOW would misread aligned
          -- page bases ending in ...00 as DT=00 invalid descriptors.
          if (walk_desc_is_long = '1' and not desc_valid(walk_desc_high)) or
             (walk_desc_is_long = '0' and not desc_valid(walk_desc)) then
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
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
            );
            -- Debug: Track invalid descriptor
            -- report "INVALID_DESC_PAGE: Invalid page descriptor at level=" & integer'image(walk_level) &
                   -- " addr=0x" & slv_to_hstring(saved_addr_log) &
                  --  -- " desc=0x" & slv_to_hstring(walk_desc) severity note;
            wstate <= W_FAULT;
          elsif saved_fc(2) = '0' and
                (walk_supervisor = '1' or get_supervisor_bit(walk_desc_high, walk_desc_is_long) = '1') and
                walk_is_root_pointer = '0' then
            -- User accesses fault if any long table or long page descriptor marked the mapping supervisor-only.
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',
              limit_violation => '0',
              supervisor_violation => '1',     -- This is a supervisor violation
              write_protect => walk_desc_high(2) or walk_write_protect,
              invalid => '0',                  -- Descriptor is valid
              modified => '0',
              transparent => '0',
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
            );
            wstate <= W_FAULT;
          -- BUG #437 FIX: Per WinUAE cpummu30.cpp line 1496-1497 + 1643-1647:
          -- WP violations do NOT abort the walk. The walk completes normally,
          -- creating an ATC entry with WP=1 and bus_error=false. The ATC-level
          -- WP check (line 1531) then produces vector 2 for writes.
          -- Previously, we aborted the walk and cached buserr=1, which caused:
          -- 1. Walker WP faults to take the internal PMMU bus-fault path instead of the 68030 vector-2 path
          -- 2. Subsequent reads to the same page to also fault (buserr ATC entry blocks all accesses)
          else
            -- MC68030 Early termination: ATC always operates at TC.PS page granularity.
            -- Per MC68030 spec and WinUAE: when a page descriptor terminates the walk
            -- early, the remaining unused table index bits from the logical address are
            -- folded into the physical address. The ATC entry covers one TC.PS-sized page.
            -- This means a large early-terminated region generates separate ATC entries
            -- for each TC.PS-sized chunk as they are accessed.
            walk_page_shift <= tc_page_shift;  -- Always TC.PS granularity
            walk_page_size  <= tc_page_size;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);  -- TC.PS aligned
            -- Physical address = descriptor base + unused logical address bits
            -- unused_offset = addr AND (effective_mask XOR page_mask)
            -- effective_mask zeros bits below effective_shift, page_mask zeros bits below page_shift
            -- XOR gives bits BETWEEN page_shift and effective_shift (the skipped index fields)
            early_term_desc_addr := align_addr(saved_addr_log, calc_effective_page_shift(tc_page_shift, walk_level, tc_idx_bits, tc_fcl));
            early_term_page_addr := align_addr(saved_addr_log, tc_page_shift);
            -- The offset to add = page-aligned addr - effective-aligned addr
            -- This extracts exactly the bits between tc_page_shift and effective_shift
            early_term_offset := std_logic_vector(unsigned(early_term_page_addr) - unsigned(early_term_desc_addr));
            if walk_desc_is_long = '1' then
              early_term_desc_addr := walk_desc_low(31 downto 8) & x"00";
              walk_phys_base <= std_logic_vector(
                unsigned(early_term_desc_addr) + unsigned(early_term_offset));
            else
              early_term_desc_addr := walk_desc_high(31 downto 8) & x"00";
              walk_phys_base <= std_logic_vector(
                unsigned(early_term_desc_addr) + unsigned(early_term_offset));
            end if;
            -- MC68030 early termination limit check (MC68030 UM 9.5.1 LIMIT / 9.5.3.1):
            -- "If an early termination page descriptor is a long format, the limit
            --  field is applied to the next index field of the logical address."
            -- If there is no next index field (current level is the deepest, or the
            -- next TI field is zero), the check is undefined and must be skipped.
            -- is_final_table_level() encodes this for both FCL=0 and FCL=1.
            limit_fault := false;
            if walk_desc_is_long = '1'
               and early_term_limit_applies(walk_is_root_pointer, tc_fcl, walk_level, tc_idx_bits) then
              table_index := get_fcl_table_index(
                walk_vpn,
                saved_fc,
                tc_fcl,
                early_term_limit_level(walk_is_root_pointer, walk_level),
                tc_initial_shift,
                tc_page_size,
                tc_idx_bits
              );
              if walk_desc_high(31) = '1' and to_unsigned(table_index, 15) < unsigned(walk_desc_high(30 downto 16)) then
                -- Lower limit violation: index < limit
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                  write_protect => '0', invalid => '1', modified => '0',
                  transparent => '0', level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer));
                wstate <= W_FAULT;
                limit_fault := true;  -- BUG FIX: Prevent U/M logic from overwriting fault
              elsif walk_desc_high(31) = '0' and to_unsigned(table_index, 15) > unsigned(walk_desc_high(30 downto 16)) then
                -- Upper limit violation: index > limit
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                  write_protect => '0', invalid => '1', modified => '0',
                  transparent => '0', level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer));
                wstate <= W_FAULT;
                limit_fault := true;  -- BUG FIX: Prevent U/M logic from overwriting fault
              end if;
            end if;
            -- Extract attributes - bit positions are same in both formats.
            -- Decode them into variables first so same-cycle MMUSR/PTEST decisions
            -- see the current page instead of the previous walk_attr latch contents.
            -- U_ACC must reflect supervisor-only protection from long table and long page descriptors.
            page_user_access   := not (walk_supervisor or get_supervisor_bit(walk_desc_high, walk_desc_is_long));
            page_cache_inhibit := walk_desc_high(6);
            page_modified      := walk_desc_high(4);
            page_write_protect := walk_desc_high(2) or walk_write_protect;
            walk_attr(3) <= page_user_access;   -- U_ACC = NOT(S): 1=user accessible, 0=supervisor-only
            walk_attr(2) <= page_cache_inhibit; -- Cache inhibit (CI)
            walk_attr(1) <= page_modified;      -- Modified (M)
            walk_attr(0) <= page_write_protect; -- WP from page + accumulated table WP
            -- MC68030 UM 9.6 (PDF line 15292): shared/global ATC entries are a
            -- MC68851 feature, not an MC68030 feature. The MC68030 therefore
            -- has only PFLUSHA and PFLUSH forms; no per-entry global attribute
            -- participates in attribute extraction or flush filtering.
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
            -- Root-pointer early termination uses a register-resident descriptor, so there is
            -- no memory-resident U/M bit to write back. Other table-search walks use the
            -- normal descriptor history-bit update path.
            if limit_fault then
              null;  -- BUG FIX: Limit violation already set wstate <= W_FAULT, don't overwrite
            elsif ptest_walk_no_update = '1' or walk_is_root_pointer = '1' then
              -- Skip history-bit writeback only for non-mutating walks or register-only root pointers.
              if ptest_walk_pending = '1' then
                walker_fault <= '1';
                -- MC68030 UM 9.7.4 line 15636-15638: MMUSR N = "actual number of
                -- tables accessed during the search". A root-pointer DT=01 early
                -- termination reads no memory-resident table (the descriptor is
                -- the CRP/SRP register itself, UM 9.5.1.2 line 14649-14656), so
                -- N must be 0 in that case rather than walk_level+1.
                if walk_is_root_pointer = '1' then
                  walker_fault_status <= encode_mmusr_success(
                    write_protect => page_write_protect,
                    modified => page_modified,
                    transparent => '0',
                    level => "000"
                  );
                else
                  walker_fault_status <= encode_mmusr_success(
                    write_protect => page_write_protect,
                    modified => page_modified,
                    transparent => '0',
                    level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
                  );
                end if;
                wstate <= W_FAULT;
              elsif pload_flush_pending = '1' then
                wstate <= W_PLOAD_FLUSH;
              else
                wstate <= W_FILL;
              end if;
            -- BUG #437: M-bit update requires WP check (per WinUAE line 1502: !write_protected)
            -- U-bit: always set if not already set (no WP check needed)
            -- M-bit: only set for writes to non-write-protected pages
            elsif walk_desc_high(3) = '0' or (saved_rw = '0' and walk_desc_high(4) = '0' and walk_desc_high(2) = '0' and walk_write_protect = '0') then
              -- Need to update descriptor with U/M bits
              desc_update_needed <= '1';
              -- Prepare updated descriptor: set U bit, and M bit if write AND not WP
              -- MC68030 UM 9.8 line 15744-15746: PLOADW "updates all history
              -- information in the translation tables (used and modified bits)
              -- as if a write operation to that address had occurred." Allow M
              -- update for PLOADW; suppress only for PTEST (ptest_walk_pending).
              -- PTEST never reaches this line because ptest_walk_no_update='1'
              -- routes it through the earlier no-update branch, but guarding on
              -- ptest_walk_pending here documents the intent for readers.
              desc_update_data <= walk_desc_high(31 downto 5) &
                                  (walk_desc_high(4) or ((not saved_rw) and (not ptest_walk_pending) and (not walk_desc_high(2)) and (not walk_write_protect))) &  -- M bit: set if write, not WP, not PTEST
                                  '1' &  -- U bit: always set
                                  walk_desc_high(2 downto 0);
              wstate <= W_UPDATE_DESC;
            else
              -- U and M bits already set appropriately, go straight to fill
              if ptest_walk_pending = '1' then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_success(
                  write_protect => page_write_protect,
                  modified => page_modified,
                  transparent => '0',
                  level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
                );
                wstate <= W_FAULT;
              elsif pload_flush_pending = '1' then
                wstate <= W_PLOAD_FLUSH;
              else
                wstate <= W_FILL;
              end if;
            end if;
          end if;
        when W_TABLE_UPDATE =>
          -- Write back TABLE descriptor HIGH word with U bit set
          -- desc_addr_reg holds HIGH word address (set when descriptor was read)
          -- desc_update_data holds updated HIGH word with U=1
          -- walk_next_state holds continuation state (W_PTR1..W_PTR4)
          if mem_req = '0' then
            mem_req <= '1';
            mem_we <= '1';
            mem_addr <= desc_addr_reg;
            mem_wdat <= desc_update_data;
          elsif mem_berr = '1' then
            -- Bus error during TABLE U-bit writeback
            mem_req <= '0';
            mem_we <= '0';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            mem_req <= '0';
            mem_we <= '0';
            -- Check PTEST early-stop after TABLE U-bit writeback
            -- walk_level was already incremented before entering this state
            if ptest_walk_pending = '1' and
               to_unsigned(walk_level, 3) >= unsigned(ptest_level) then
              walker_fault <= '1';
              walker_fault_status <= encode_ptest_table_status(
                fc => saved_fc,
                accum_supervisor => walk_supervisor,
                current_supervisor => '0',
                accum_write_protect => walk_write_protect,
                current_write_protect => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              wstate <= W_FAULT;
            else
              wstate <= walk_next_state;
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
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
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
            if ptest_walk_pending = '1' then
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_success(
                write_protect => desc_update_data(2) or walk_write_protect,
                modified => desc_update_data(4),
                transparent => '0',
                level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
              );
              wstate <= W_FAULT;
            elsif pload_flush_pending = '1' then
              wstate <= W_PLOAD_FLUSH;
            else
              wstate <= W_FILL;
            end if;
          end if;
        when W_PLOAD_FLUSH =>
          -- PLOAD flush-before-fill: invalidate existing ATC entries for this page
          -- Per MC68030 spec and WinUAE: PLOAD always flushes old entry before filling
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              if align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
              end if;
            end if;
          end loop;
          wstate <= W_FILL;  -- Next cycle: fill with updated atc_valid
        when W_FILL =>
          -- Fill ATC with translation result using pseudo-LRU replacement
          -- Keep the ATC associative state canonical: if this page/FC is already
          -- resident, replace that entry before using the normal invalid/MRU
          -- replacement path. This prevents stale cached faults from coexisting
          -- with a fresh successful walk after history-bit writeback.
          found_match := false;
          found_invalid := false;
          replace_idx := 0;
          -- Step 1: Search for an existing entry covering this logical page/FC.
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' and not found_match and atc_fc(i) = saved_fc and
               align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
              replace_idx := i;
              found_match := true;
            end if;
          end loop;
          -- Step 2: Search for an invalid (empty) entry
          if not found_match then
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_valid(i) = '0' and not found_invalid then
                replace_idx := i;
                found_invalid := true;
              end if;
            end loop;
          end if;
          -- Step 3: If no invalid entry, find first entry with MRU=0
          if not found_match and not found_invalid then
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_mru(i) = '0' then
                replace_idx := i;
                exit;
              end if;
            end loop;
          end if;
          -- Invalidate any duplicate entries for the same page/FC.
          for i in 0 to ATC_ENTRIES-1 loop
            if i /= replace_idx and atc_valid(i) = '1' and atc_fc(i) = saved_fc and
               align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
              atc_valid(i) <= '0';
              atc_mru(i) <= '0';
              atc_buserr(i) <= '0';
              atc_fault_status(i) <= (others => '0');
            end if;
          end loop;
          -- Fill the selected entry
          atc_log_base(replace_idx)  <= walk_log_base;
          atc_phys_base(replace_idx) <= align_addr(walk_phys_base, walk_page_shift);
          atc_shift(replace_idx)     <= walk_page_shift;
          atc_page_size(replace_idx) <= walk_page_size;
          atc_attr(replace_idx)      <= walk_attr(3 downto 0);
          atc_fc(replace_idx)        <= saved_fc;
          atc_level(replace_idx)     <= page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer);
          atc_valid(replace_idx)     <= '1';
          atc_buserr(replace_idx)    <= '0';  -- BUG #436: Clear bus error flag for successful walk
          atc_fault_status(replace_idx) <= (others => '0');
          -- Pseudo-LRU: set MRU bit, reset all if all become set
          atc_mru(replace_idx) <= '1';
          all_mru_set := true;
          for i in 0 to ATC_ENTRIES-1 loop
            if i /= replace_idx and atc_mru(i) = '0' then
              all_mru_set := false;
            end if;
          end loop;
          if all_mru_set then
            -- All MRU bits now set - reset all except current entry
            for i in 0 to ATC_ENTRIES-1 loop
              if i /= replace_idx then
                atc_mru(i) <= '0';
              end if;
            end loop;
          end if;
          -- Delay completion signal by one cycle to ensure ATC write is visible
          wstate <= W_COMPLETE;
          
          
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
          mem_req <= '0';  -- BUG FIX: Clear any outstanding memory request to prevent leak
         --  -- report "W_FAULT: Setting walker_completed=1 with fault status=0x" & slv_to_hstring(walker_fault_status) severity note;
          if ptest_walk_pending = '1' then
            -- PTEST updates MMUSR only; it must not populate the ATC on success or failure.
            wstate <= W_IDLE;
          else
            -- Cache the original MMUSR fault class in the ATC so repeated hits
            -- replay the same B/L/S/W/I combination without re-walking.
            found_match := false;
            found_invalid := false;
            replace_idx := 0;
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_valid(i) = '1' and not found_match and atc_fc(i) = saved_fc and
                 align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                replace_idx := i;
                found_match := true;
              end if;
            end loop;
            if not found_match then
              for i in 0 to ATC_ENTRIES-1 loop
                if atc_valid(i) = '0' and not found_invalid then
                  replace_idx := i;
                  found_invalid := true;
                end if;
              end loop;
            end if;
            if not found_match and not found_invalid then
              for i in 0 to ATC_ENTRIES-1 loop
                if atc_mru(i) = '0' then
                  replace_idx := i;
                  exit;
                end if;
              end loop;
            end if;
            for i in 0 to ATC_ENTRIES-1 loop
              if i /= replace_idx and atc_valid(i) = '1' and atc_fc(i) = saved_fc and
                 align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
                atc_fault_status(i) <= (others => '0');
              end if;
            end loop;
            atc_log_base(replace_idx)  <= walk_log_base;
            atc_phys_base(replace_idx) <= (others => '0');  -- No valid physical address
            atc_shift(replace_idx)     <= walk_page_shift;
            atc_page_size(replace_idx) <= walk_page_size;
            atc_attr(replace_idx)      <= (others => '0');  -- No valid attributes
            atc_fc(replace_idx)        <= saved_fc;
            atc_level(replace_idx)     <= (others => '0');
            atc_valid(replace_idx)     <= '1';
            atc_buserr(replace_idx)    <= '1';  -- Mark as cached fault entry
            atc_fault_status(replace_idx) <= walker_fault_status(15 downto 3) & "000";
            atc_mru(replace_idx) <= '1';
            walker_completed <= '1';  -- Signal that walker completed (with fault)
            wstate <= W_IDLE;
          end if;
          
        when others =>
          wstate <= W_IDLE;
        end case;
        end if;  -- End timeout vs normal state machine conditional
      end if;  -- End context-change abort vs normal walker state machine
      -- Handle ATC MRU update requests from translation process (ATC hits)
      if atc_mru_update_req = '1' then
        atc_mru(atc_mru_update_idx) <= '1';
        -- Check if all MRU bits are now set - if so, reset all except current
        all_mru_set := true;
        for i in 0 to ATC_ENTRIES-1 loop
          if i /= atc_mru_update_idx and atc_mru(i) = '0' then
            all_mru_set := false;
          end if;
        end loop;
        if all_mru_set then
          for i in 0 to ATC_ENTRIES-1 loop
            if i /= atc_mru_update_idx then
              atc_mru(i) <= '0';
            end if;
          end loop;
        end if;
      end if;
      -- Handle ATC M-bit invalidation requests from translation process
      -- Per WinUAE cpummu30.cpp line 2086: on write with M=0, invalidate the entry
      -- to avoid repeated scanning of stale entries
      if atc_mbit_inval_req = '1' then
        atc_valid(atc_mbit_inval_idx) <= '0';
        atc_mru(atc_mbit_inval_idx) <= '0';
        atc_buserr(atc_mbit_inval_idx) <= '0';
        atc_fault_status(atc_mbit_inval_idx) <= (others => '0');
      end if;
      -- PFLUSH instruction: Clear ATC when flag is set and walker is idle
      if atc_flush_req = '1' then
        for i in 0 to ATC_ENTRIES-1 loop
          atc_valid(i) <= '0';
          atc_mru(i) <= '0';
          atc_buserr(i) <= '0';
          atc_fault_status(i) <= (others => '0');
        end loop;
      end if;
      if pflush_clear_atc = '1' and wstate = W_IDLE then
        -- MC68030 PFLUSH variants (brief word bits 12:10):
        --   001 = PFLUSHA
        --   100 = PFLUSH  <fc>,#mask
        --   110 = PFLUSH  <fc>,#mask,<ea>
        -- MC68030 UM 9.6: the 68851 shared-entry derivatives are not supported.
        if pflush_mode = "001" then
          -- PFLUSHA: flush all ATC entries
          for i in 0 to ATC_ENTRIES-1 loop
            atc_valid(i) <= '0';
            atc_mru(i) <= '0';
            atc_buserr(i) <= '0';
            atc_fault_status(i) <= (others => '0');
          end loop;
        elsif pflush_mode = "100" then
          -- PFLUSH FC,MASK: flush entries matching FC under mask, regardless of address.
          -- mask=0 matches any FC. FC3 is not implemented on MC68030; decode rejects
          -- brief(8)='1', so only the real 3-bit FC participates here.
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              if ((atc_fc(i) xor pflush_fc) and pflush_mask) = "000" then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
                atc_fault_status(i) <= (others => '0');
              end if;
            end if;
          end loop;
        else
          -- PFLUSH FC,MASK,<ea> (mode=110): FC match AND address match.
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              if ((atc_fc(i) xor pflush_fc) and pflush_mask) = "000" and
                 align_addr(pflush_addr, atc_shift(i)) = atc_log_base(i) then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
                atc_fault_status(i) <= (others => '0');
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
  process(wstate, addr_log, fc, rw, rmw, is_insn, TT0, TT1, tc_en, translation_pending, walker_fault, walker_completed, walker_fault_ack_pending, translated_addr, translated_fc, translated_rw, translated_cfg_seq, xlat_cfg_seq, req, fault_reg, fault_current_req_match, pload_active, ptest_update_mmusr, ptest_active, ptest_walk_pending, ptest_desc_return_pending, mmusr_update_req)
    variable tmatch0, tmatch1 : std_logic;
    variable dummy_ci, dummy_wp : std_logic;
  begin
    -- Normal CPU translation is idle when TC.E is clear, but PTEST/PLOAD can
    -- still perform manual table searches with TC.E=0.
    if ptest_update_mmusr = '1' or ptest_active = '1' or ptest_desc_return_pending = '1' or mmusr_update_req = '1' then
      -- Hold the CPU while a PTEST command is being accepted/processed. Without
      -- this, the A-bit writeback can sample stale desc_addr_reg before the
      -- table search starts. Also hold until the resulting MMUSR update has
      -- been committed so a following PMOVE MMUSR cannot read the old value.
      busy <= '1';
    elsif tc_en = '0' and pload_active = '0' and ptest_walk_pending = '0'
       and translation_pending = '0' and wstate = W_IDLE then
      busy <= '0';
    else
      -- BUG #421 FIX: Use ttr_check with actual rw signal instead of ttr_match which
      -- hardcodes rw='1'. With RWM=0 TTRs, ttr_match would report a match for writes
      -- when the TTR only matches reads. This caused busy='0' (TTR handles it) while
      -- the translation process started a walker (TTR doesn't match writes), allowing
      -- the CPU to proceed with a stale physical address.
      ttr_check(TT0, addr_log, fc, is_insn, rw, rmw, tmatch0, dummy_ci, dummy_wp);
      ttr_check(TT1, addr_log, fc, is_insn, rw, rmw, tmatch1, dummy_ci, dummy_wp);
      -- Not busy if TTR hit, fault is ready to report, or (walker idle with no pending walker work AND
      -- either no translation is active, or addr_phys_reg is fresh).
      -- BUG #416: Without the translated_addr/fc check, ATC hits leave busy='0'
      -- for one cycle while addr_phys_reg still holds the OLD translation. The bus
      -- starts an access with a stale physical address, causing data corruption and
      -- cascading failures leading to double bus fault and total CPU lockup.
      -- The check is only applied when req='1' (active bus access needing translation).
      -- When req='0' (e.g. execute state), no bus access happens so stale addr is harmless;
      -- checking it when req='0' would deadlock because the translation process only
      -- updates translated_addr when req='1'.
      --
      -- BUG #428 FIX: When fault_reg='1' for the current request, the translation
      -- is "done" (it faulted).
      -- Report busy='0' so clkena_lw can fire and make_berr captures the fault.
      -- Without this, the walker_fault handshake (3-4 cycles) holds busy='1'.
      -- During that window, clkena_in fires (cpu_wrapper releases for faults) but
      -- clkena_lw stays '0' (busy blocks it). The memmask shift at clkena_in changes
      -- addr_log combinationally, breaking translated_addr match. When the handshake
      -- completes, busy='1' persists (addr mismatch) and fault_reg clears (new
      -- translation for new addr) -> permanent deadlock, berr never dispatched.
      if (pload_active = '0' and
          (tmatch0 = '1' or tmatch1 = '1' or
          (fault_reg = '1' and translated_cfg_seq = xlat_cfg_seq and fault_current_req_match = '1') or
          (translation_pending = '0' and wstate = W_IDLE and walker_fault = '0' and walker_fault_ack_pending = '0' and
           (req = '0' or (translated_addr = addr_log and translated_fc = fc and translated_rw = rw and translated_cfg_seq = xlat_cfg_seq))))) then
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
      pflush_active <= '0';
      pflush_clear_atc <= '0';
      ptest_req_prev <= '0';
      pflush_req_prev <= '0';
      pload_req_prev <= '0';
      reg_we_prev <= '0';  -- BUG #16 FIX
      reg_re_prev <= '0';  -- BUG #16 FIX
      ptest_addr <= (others => '0');  -- BUG #397: driven from this process
      ptest_fc <= (others => '0');    -- BUG #397: driven from this process
      ptest_rw <= '1';               -- BUG #397: driven from this process
      ptest_level <= "000";          -- BUG #413: driven from this process
      pload_active <= '0';
      pload_addr <= (others => '0');
      pload_fc <= (others => '0');
      pload_rw <= '1';
    elsif rising_edge(clk) then
      -- Update previous values for edge detection
      ptest_req_prev <= ptest_req;
      pflush_req_prev <= pflush_req;
      pload_req_prev <= pload_req;
      reg_we_prev <= reg_we;  -- BUG #16 FIX
      reg_re_prev <= reg_re;  -- BUG #16 FIX
      
      -- PTEST: Set flag on rising edge only (prevents multiple triggers)
      -- BUG #397: Capture addr/fc/rw HERE at edge time, not one cycle later
      -- in the register process. By the register process cycle, micro_state
      -- may have moved past ptest1, so pmmu_cmd_addr is no longer OP1out.
      if ptest_req = '1' and ptest_req_prev = '0' then
        ptest_update_mmusr <= '1';
        ptest_addr <= pmmu_addr;
        ptest_fc <= pmmu_fc;
        ptest_rw <= pmmu_brief(9);
        ptest_level <= pmmu_brief(12 downto 10);  -- BUG #413: capture PTEST level
      else
        ptest_update_mmusr <= '0';
      end if;
      
      -- PFLUSH: Edge detection and parameter capture
      if pflush_req = '1' and pflush_req_prev = '0' then
        pflush_active <= '1';
        pflush_addr <= pmmu_addr;
        pflush_fc <= pmmu_fc;
        pflush_mode <= pmmu_brief(12 downto 10);  -- Capture PFLUSH MODE field from brief word
        pflush_mask <= pmmu_brief(7 downto 5);  -- Capture FC0-FC2 comparison mask; FC3/bit8 is unsupported on MC68030
        pflush_clear_atc <= '1';
      elsif pflush_active = '1' then
        -- Keep the clear request live until the flush logic can service it.
        -- A one-cycle pulse is lost if a walker is still active when PFLUSH fires.
        if wstate = W_IDLE then
          pflush_active <= '0';
          pflush_clear_atc <= '0';
        else
          pflush_clear_atc <= '1';
        end if;
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
        -- Keep the request live while a previous translation is still draining.
        -- WinUAE flushes the ATC page and immediately performs the table search;
        -- losing this edge leaves a cached fault entry live across RTE.
        if translation_pending = '0' then
          pload_active <= '0';
        end if;
      end if;
    end if;
  end process;
  -- MMU Configuration Exception output
  mmu_config_err <= mmu_config_error;
end rtl;
