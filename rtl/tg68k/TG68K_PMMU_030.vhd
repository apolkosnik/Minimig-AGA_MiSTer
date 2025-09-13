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

    -- Walker memory interface (read-only) and busy indicator
    mem_req        : out std_logic;
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
  
  -- Save the original request for later re-evaluation
  signal saved_addr_log     : std_logic_vector(31 downto 0) := (others => '0');
  signal saved_fc           : std_logic_vector(2 downto 0) := (others => '0');
  signal saved_is_insn      : std_logic := '0';
  signal saved_rw           : std_logic := '0';
  signal translation_pending : std_logic := '0';

  -- Simple ATC (Address Translation Cache), 8 entries, 4KB pages, identity fill for now
  constant ATC_ENTRIES : integer := 8;
  type atc_tag_t  is array(0 to ATC_ENTRIES-1) of std_logic_vector(24 downto 0); -- log_pn[19:0] + FC[2:0] + is_insn + 0
  type atc_ppn_t  is array(0 to ATC_ENTRIES-1) of std_logic_vector(19 downto 0); -- phys page number (4KB pages)
  type atc_attr_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(1 downto 0);  -- {CI, WP}
  type atc_val_t  is array(0 to ATC_ENTRIES-1) of std_logic;

  signal atc_tag   : atc_tag_t;
  signal atc_ppn   : atc_ppn_t;
  signal atc_attr  : atc_attr_t;
  signal atc_valid : atc_val_t;
  signal atc_rr    : integer range 0 to ATC_ENTRIES-1 := 0; -- simple round-robin
  signal walk_req  : std_logic;
  signal walker_completed : std_logic := '0';

  -- MC68030 page table walker FSM
  type walk_state_t is (W_IDLE, W_ROOT, W_PTR1, W_PTR2, W_PTR3, W_PAGE, W_FILL, W_FAULT);
  signal wstate    : walk_state_t := W_IDLE;
  signal ttr_hit_q : std_logic := '0';
  signal hit_q     : std_logic := '0';
  signal tag_q     : std_logic_vector(24 downto 0) := (others => '0');
  
  -- Page table walking state
  signal walk_level     : integer range 0 to 4 := 0; -- Current level being walked  
  signal walk_desc      : std_logic_vector(31 downto 0) := (others => '0'); -- Current descriptor
  signal walk_addr      : std_logic_vector(31 downto 0) := (others => '0'); -- Current table address
  signal walk_vpn       : std_logic_vector(31 downto 0) := (others => '0'); -- Virtual page being walked
  signal walk_fault     : std_logic := '0'; -- Page fault flag
  signal walk_attr      : std_logic_vector(7 downto 0) := (others => '0'); -- Page attributes

  -- helpers
  function mk_tag(addr : std_logic_vector(31 downto 0);
                  fc   : std_logic_vector(2 downto 0);
                  insn : std_logic) return std_logic_vector is
    variable t : std_logic_vector(24 downto 0);
  begin
    -- tag = logical page number [31:12] (20b) :: FC(2:0) :: is_insn :: 0
    t(24 downto 5) := addr(31 downto 12);
    t(4 downto 2)  := fc;
    t(1)           := insn;
    t(0)           := '0';
    return t;
  end function;

  -- very simple TTR match: if (addr[31:16] & mask) == (base & mask) then match; attrs in TTx(1:0) => {CI,WP}
  procedure ttr_check(
      tt        : in  std_logic_vector(31 downto 0);
      addr      : in  std_logic_vector(31 downto 0);
      fc        : in  std_logic_vector(2 downto 0);
      is_insn   : in  std_logic;
      matched   : out std_logic;
      ci        : out std_logic;
      wp        : out std_logic) is
    variable enable  : std_logic;
    variable base    : std_logic_vector(15 downto 0);
    variable mask    : std_logic_vector(15 downto 0);
    variable a_hi    : std_logic_vector(15 downto 0);
  begin
    -- For now: enable in bit31, base in [31:16], mask in [15:0], attrs in [1:0]. Ignore user/super bits.
    enable := tt(31);
    base   := tt(31 downto 16);
    mask   := tt(15 downto 0);
    a_hi   := addr(31 downto 16);
    if enable = '1' and ((a_hi and mask) = (base and mask)) then
      matched := '1';
      ci := tt(1);
      wp := tt(0);
    else
      matched := '0';
      ci := '0';
      wp := '0';
    end if;
  end procedure;
  
  -- Extract table index from virtual address (simplified version)
  function get_table_index(addr : std_logic_vector(31 downto 0);
                          level : integer) return integer is
    variable index : integer;
  begin
    -- Simplified table index extraction for 4KB pages
    case level is
      when 0 => index := to_integer(unsigned(addr(31 downto 24))); -- Top 8 bits
      when 1 => index := to_integer(unsigned(addr(23 downto 16))); -- Next 8 bits  
      when 2 => index := to_integer(unsigned(addr(15 downto 12))); -- Page table index
      when others => index := 0;
    end case;
    return index mod 256; -- Limit to reasonable range
  end function;
  
  -- Check if descriptor is valid 
  function desc_valid(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) /= "00"; -- Valid if not invalid descriptor
  end function;
  
  -- Check if descriptor is a page descriptor (not table pointer)
  function desc_is_page(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1) = '1'; -- Page descriptor has bit 1 set
  end function;
  
  -- Check supervisor/user access permissions
  function access_allowed(desc : std_logic_vector(31 downto 0);
                         fc : std_logic_vector(2 downto 0)) return boolean is
  begin
    -- Simple privilege check - supervisor pages (desc(7)=0) can be accessed by supervisor FC
    -- User pages (desc(7)=1) can be accessed by both user and supervisor
    if desc(7) = '0' then -- Supervisor page
      return fc(2) = '1'; -- Only supervisor access allowed
    else -- User page  
      return true; -- Both user and supervisor access allowed
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
    elsif rising_edge(clk) then
      if reg_we = '1' then
        case reg_sel is
          when x"0" => TC    <= reg_wdat;
          when x"1" => if reg_part = '1' then CRP_H <= reg_wdat; else CRP_L <= reg_wdat; end if;
          when x"2" => if reg_part = '1' then SRP_H <= reg_wdat; else SRP_L <= reg_wdat; end if;
          when x"3" => TT0   <= reg_wdat;
          when x"4" => TT1   <= reg_wdat;
          when x"5" => MMUSR <= reg_wdat; -- MMUSR is usually write-1-to-clear bits; kept simple initially
          when x"6" => CAL   <= reg_wdat;
          when others => null;
        end case;
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
  
  -- Output the latched results
  addr_phys     <= addr_phys_reg;
  cache_inhibit <= cache_inhibit_reg;
  write_protect <= write_protect_reg;
  fault         <= fault_reg;
  fault_status  <= fault_status_reg;

  -- Simplified translation process - always provide immediate result
  process(clk, nreset)
    variable tag_v     : std_logic_vector(24 downto 0) := (others => '0');
    variable hit       : std_logic := '0';
    variable hit_idx   : integer range 0 to ATC_ENTRIES-1 := 0;
    variable tmatch0, tmatch1 : std_logic := '0';
    variable tci0, twp0, tci1, twp1 : std_logic := '0';
    variable ci_v, wp_v : std_logic := '0';
    variable phys    : std_logic_vector(31 downto 0) := (others => '0');
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
    elsif rising_edge(clk) then
      -- Process translation requests first
      if req = '1' then
        -- Initialize variables to clean values
        tag_v := (others => '0');
        hit := '0';
        hit_idx := 0;
        tmatch0 := '0'; tmatch1 := '0';
        tci0 := '0'; twp0 := '0'; tci1 := '0'; twp1 := '0';
        ci_v := '0'; wp_v := '0';
        phys := (others => '0');
        
        -- Save request info for walker
        saved_addr_log <= addr_log;
        saved_fc <= fc;
        saved_is_insn <= is_insn;
        saved_rw <= rw;
        
        -- Translation logic with proper precedence (no conflicting assignments)
        -- 1. Always start with identity as default
        addr_phys_reg     <= addr_log;
        cache_inhibit_reg <= '0';
        write_protect_reg <= '0';
        fault_reg         <= '0';
        fault_status_reg  <= (others => '0');
        
        -- 2. Check Transparent Translation first (highest priority)
        ttr_check(TT0, addr_log, fc, is_insn, tmatch0, tci0, twp0);
        ttr_check(TT1, addr_log, fc, is_insn, tmatch1, tci1, twp1);
        if tmatch0 = '1' then
          -- TTR0 match - use identity but with TTR attributes
          cache_inhibit_reg <= tci0;
          write_protect_reg <= twp0;
        elsif tmatch1 = '1' then
          -- TTR1 match - use identity but with TTR attributes
          cache_inhibit_reg <= tci1;
          write_protect_reg <= twp1;
        elsif tc_en = '1' then
          -- 3. MMU enabled - check ATC
          tag_v := mk_tag(addr_log, fc, is_insn);
          hit := '0';
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' and atc_tag(i) = tag_v then
              hit := '1';
              hit_idx := i;
            end if;
          end loop;
          if hit = '1' then
            -- ATC hit - use cached translation
            addr_phys_reg(31 downto 12) <= atc_ppn(hit_idx);
            addr_phys_reg(11 downto 0)  <= addr_log(11 downto 0);
            cache_inhibit_reg <= atc_attr(hit_idx)(1);
            write_protect_reg <= atc_attr(hit_idx)(0);
          else
            -- ATC miss - request walker to start
            walk_req <= '1';
          end if;
        end if;
        
      -- Handle walker completion (higher priority than clearing walk_req)
      elsif walker_completed = '1' then
        
        -- For the pending translation, update outputs if ATC now has result
        tag_v := mk_tag(saved_addr_log, saved_fc, saved_is_insn);
        hit := '0';
        for i in 0 to ATC_ENTRIES-1 loop
          if atc_valid(i) = '1' and atc_tag(i) = tag_v then
            hit := '1';
            hit_idx := i;
          end if;
        end loop;
        
        if hit = '1' then
          -- Walker filled ATC successfully - update outputs
          addr_phys_reg(31 downto 12) <= atc_ppn(hit_idx);
          addr_phys_reg(11 downto 0)  <= saved_addr_log(11 downto 0);
          cache_inhibit_reg <= atc_attr(hit_idx)(1);
          write_protect_reg <= atc_attr(hit_idx)(0);
          fault_reg <= '0';
        elsif walker_fault = '1' then
          -- Walker faulted
          fault_reg <= '1';
          fault_status_reg <= walker_fault_status;
        end if;
      end if;
      
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
    variable tag_v : std_logic_vector(24 downto 0);
    variable table_index : integer;
    variable desc_addr : std_logic_vector(31 downto 0);
  begin
    if nreset = '0' then
      for i in 0 to ATC_ENTRIES-1 loop
        atc_valid(i) <= '0';
        atc_tag(i)   <= (others => '0');
        atc_ppn(i)   <= (others => '0');
        atc_attr(i)  <= (others => '0');
      end loop;
      atc_rr      <= 0;
      wstate      <= W_IDLE;
      ttr_hit_q   <= '0';
      hit_q       <= '0';
      tag_q       <= (others => '0');
      walk_level  <= 0;
      walk_desc   <= (others => '0');
      walk_addr   <= (others => '0');
      walk_vpn    <= (others => '0');
      walk_fault  <= '0';
      walk_attr   <= (others => '0');
      walker_fault <= '0';
      walker_fault_status <= (others => '0');
      mem_req     <= '0';
      mem_addr    <= (others => '0');
    elsif rising_edge(clk) then
      case wstate is
        when W_IDLE =>
          -- Auto-clear walker_completed flag when idle
          if walker_completed = '1' then
            walker_completed <= '0';
          end if;
          
          -- Start page table walk on ATC miss using saved request parameters
          if walk_req = '1' then
            tag_v := mk_tag(saved_addr_log, saved_fc, saved_is_insn);
            ttr_hit_q <= '0';
            hit_q     <= '0';
            tag_q     <= tag_v;
            walk_level <= 0;
            walk_vpn  <= saved_addr_log;
            walk_fault <= '0';  -- Clear fault at start of walk
            walk_attr <= (others => '0');
            walker_fault <= '0';  -- Clear walker fault
            walker_fault_status <= (others => '0');
            -- Use CRP for user space, SRP for supervisor
            if saved_fc(2) = '1' then -- Supervisor
              walk_addr <= SRP_L(31 downto 4) & "0000"; -- Root pointer base
            else -- User
              walk_addr <= CRP_L(31 downto 4) & "0000"; -- Root pointer base  
            end if;
            wstate <= W_ROOT;
          end if;
          
        when W_ROOT =>
          -- Read root table descriptor
          table_index := get_table_index(walk_vpn, walk_level);
          desc_addr := walk_addr(31 downto 4) & "0000"; -- Align to table boundary
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          mem_req <= '1';
          mem_addr <= desc_addr;
          if mem_ack = '1' then
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_valid(mem_rdat) then
              if desc_is_page(mem_rdat) then
                -- Early termination - this is a page descriptor
                wstate <= W_PAGE;
              else
                -- Table pointer - continue to next level
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                wstate <= W_PTR1;
              end if;
            else
              -- Invalid descriptor - page fault
              walk_fault <= '1';
              wstate <= W_FAULT;
            end if;
          end if;
          
        when W_PTR1 =>
          -- Read level 1 table descriptor
          table_index := get_table_index(walk_vpn, walk_level);
          desc_addr := walk_addr(31 downto 4) & "0000";
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          mem_req <= '1';
          mem_addr <= desc_addr;
          if mem_ack = '1' then
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_valid(mem_rdat) then
              if desc_is_page(mem_rdat) then
                -- Page descriptor found
                wstate <= W_PAGE;
              else
                -- Continue to next level
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                wstate <= W_PTR2;
              end if;
            else
              walk_fault <= '1';
              wstate <= W_FAULT;
            end if;
          end if;
          
        when W_PTR2 =>
          -- Read level 2 table descriptor  
          table_index := get_table_index(walk_vpn, walk_level);
          desc_addr := walk_addr(31 downto 4) & "0000";
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          mem_req <= '1';
          mem_addr <= desc_addr;
          if mem_ack = '1' then
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_valid(mem_rdat) then
              if desc_is_page(mem_rdat) then
                wstate <= W_PAGE;
              else
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                wstate <= W_PTR3;
              end if;
            else
              walk_fault <= '1';
              wstate <= W_FAULT;
            end if;
          end if;
          
        when W_PTR3 =>
          -- Final level - must be page descriptor
          table_index := get_table_index(walk_vpn, walk_level);
          desc_addr := walk_addr(31 downto 4) & "0000";
          desc_addr := std_logic_vector(unsigned(desc_addr) + to_unsigned(table_index * 4, 32));
          mem_req <= '1';
          mem_addr <= desc_addr;
          if mem_ack = '1' then
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_valid(mem_rdat) and desc_is_page(mem_rdat) then
              wstate <= W_PAGE;
            else
              walk_fault <= '1';
              wstate <= W_FAULT;
            end if;
          end if;
          
        when W_PAGE =>
          -- Process page descriptor and check access permissions
          -- Check supervisor/user access
          if not access_allowed(walk_desc, saved_fc) then
            walker_fault <= '1';
            walker_fault_status(7) <= '0';  -- Not invalid descriptor
            walker_fault_status(6) <= '0';  -- Not write protect violation  
            walker_fault_status(5) <= '1';  -- Supervisor violation (treat as bus error for now)
            if (ptest_req = '1' or pflush_req = '1' or pload_req = '1') then
              walker_fault_status(4 downto 3) <= pmmu_fc(1 downto 0);
            else
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
            end if;
            walker_fault_status(2) <= saved_rw;   -- Read/Write bit
            walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2)); -- Fault level
            wstate <= W_FAULT;
          -- Check for write protect violation
          elsif saved_rw = '0' and walk_desc(2) = '1' then -- Write access to write-protected page
            walker_fault <= '1';
            walker_fault_status(7) <= '0';  -- Not invalid descriptor
            walker_fault_status(6) <= '1';  -- Write protect violation
            walker_fault_status(5) <= '0';  -- Not bus error
            if (ptest_req = '1' or pflush_req = '1' or pload_req = '1') then
              walker_fault_status(4 downto 3) <= pmmu_fc(1 downto 0);
            else
              walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
            end if;
            walker_fault_status(2) <= saved_rw;   -- Read/Write bit
            walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2)); -- Fault level
            wstate <= W_FAULT;
          else
            -- Valid access - extract attributes
            walk_attr(1) <= walk_desc(6); -- Cache inhibit
            walk_attr(0) <= walk_desc(2); -- Write protect
            walk_fault <= '0';
            wstate <= W_FILL;
          end if;
          
        when W_FILL =>
          -- Fill ATC with translation result
          atc_tag(atc_rr)   <= tag_q;
          atc_ppn(atc_rr)   <= walk_desc(31 downto 12); -- Physical page number
          atc_attr(atc_rr)  <= walk_attr(1 downto 0);   -- Cache inhibit, write protect
          atc_valid(atc_rr) <= '1';
          if atc_rr = ATC_ENTRIES-1 then
            atc_rr <= 0;
          else
            atc_rr <= atc_rr + 1;
          end if;
          
          -- ATC entry filled successfully - no immediate update needed
          -- Translation will be available on next request through ATC hit
          
          walker_completed <= '1';  -- Signal that walker completed successfully
          wstate <= W_IDLE;
          
        when W_FAULT =>
          -- Page fault occurred - set fault status and return to idle
          -- MC68030 MMU fault status format:
          -- Bit 7: Invalid descriptor
          -- Bit 6: Write protect violation  
          -- Bit 5: Bus error
          -- Bit 4-3: Function code
          -- Bit 2: Read/Write (0=write, 1=read)
          -- Bit 1-0: Level of fault (0=root, 1=ptr1, 2=ptr2, 3=page)
          walker_fault <= '1';
          walker_fault_status(7) <= '1';  -- Invalid descriptor
          walker_fault_status(6) <= '0';  -- Not write protect violation
          walker_fault_status(5) <= '0';  -- Not bus error (MMU fault)
          if (ptest_req = '1' or pflush_req = '1' or pload_req = '1') then
            walker_fault_status(4 downto 3) <= pmmu_fc(1 downto 0);
          else
            walker_fault_status(4 downto 3) <= saved_fc(1 downto 0);
          end if;
          walker_fault_status(2) <= saved_rw;   -- Read/Write bit
          walker_fault_status(1 downto 0) <= std_logic_vector(to_unsigned(walk_level, 2)); -- Fault level
          
          walker_completed <= '1';  -- Signal that walker completed (with fault)
          wstate <= W_IDLE;
          
        when others =>
          wstate <= W_IDLE;
      end case;
    end if;
  end process;

  -- Walker busy indication
  busy <= '1' when (wstate /= W_IDLE) else '0';
  
  -- PMMU instruction handlers
--  process(clk, nreset)
--    variable tag_v : std_logic_vector(24 downto 0);
--  begin
--    if nreset = '0' then
--      -- Reset handled above
--      null;
--    elsif rising_edge(clk) then
--      -- PTEST: Test page translation and update MMUSR
--      if ptest_req = '1' then
--        -- Update MMUSR based on current fault status
--        if walk_fault = '1' then
--          MMUSR(15) <= '0'; -- R bit: Not resident (page fault occurred)
--          MMUSR(14) <= walk_attr(7); -- I bit: Invalid descriptor
--          MMUSR(13) <= '0'; -- M bit: Modified (not implemented)
--          MMUSR(12) <= '0'; -- T bit: Transparent translation not used for faults
--          MMUSR(11) <= walk_attr(5); -- S bit: Supervisor violation
--          MMUSR(10) <= walk_attr(1); -- CM bit: Cache mode (cache inhibit)
--          MMUSR(9)  <= '0'; -- G bit: Global (not implemented)
--          MMUSR(8)  <= '0'; -- U1 bit: User defined 1
--          MMUSR(7)  <= '0'; -- U0 bit: User defined 0  
--          MMUSR(6 downto 4) <= walk_attr(4 downto 2); -- FC and R/W bits
--          MMUSR(3 downto 0) <= "00" & walk_attr(1 downto 0); -- Number of levels traversed
--        else
--          MMUSR(15) <= '1'; -- R bit: Resident (page is resident)
--          MMUSR(14) <= '0'; -- I bit: Invalid (translation is valid)  
--          MMUSR(13) <= '0'; -- M bit: Modified (not implemented)
--          MMUSR(12) <= '0'; -- T bit: Transparent translation used check needed
--          MMUSR(11) <= '0'; -- S bit: No supervisor violation
--          MMUSR(10) <= walk_attr(1); -- CM bit: Cache mode
--          MMUSR(9)  <= '0'; -- G bit: Global (not implemented)
--          MMUSR(8)  <= '0'; -- U1 bit: User defined 1
--          MMUSR(7)  <= '0'; -- U0 bit: User defined 0
--          MMUSR(6 downto 4) <= pmmu_fc(2 downto 0); -- Function code used for PTEST
--          MMUSR(3 downto 0) <= "00" & std_logic_vector(to_unsigned(walk_level, 2)); -- Levels traversed
--        end if;
--      end if;
--      
--      -- PFLUSH: Flush ATC entries
--      if pflush_req = '1' then
--        -- For now, flush all ATC entries (PFLUSH with no arguments)
--        -- Real implementation would support selective flushing
--        for i in 0 to ATC_ENTRIES-1 loop
--          atc_valid(i) <= '0';
--        end loop;
--      end if;
--      
--      -- PLOAD: Load page into ATC  
--      if pload_req = '1' then
--        -- For now, just trigger a translation which will load the page
--        -- Real implementation would force a page table walk and ATC load
--        -- ATC updates moved to page table walker process to avoid multiple drivers
--        null;
--      end if;
--    end if;
--  end process;
--
end rtl;
