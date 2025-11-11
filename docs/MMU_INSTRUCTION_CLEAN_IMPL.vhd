-- Clean MMU Instruction Implementation for TG68KdotC_Kernel.vhd
-- This file contains clean replacement code for MMU instruction handling
--
-- USAGE: Replace the existing code sections in TG68KdotC_Kernel.vhd with these clean versions
--
-- Date: 2025-11-11
-- Author: Claude Code

-- ==============================================================================
-- SECTION 1: Signal Declarations (add to signal declaration section)
-- ==============================================================================

-- MMU instruction decode signals
signal mmu_inst_detected    : std_logic;
signal mmu_inst_type        : std_logic_vector(2 downto 0);  -- 000=PMOVE, 001=PTEST, 010=PFLUSH, 011=PLOAD
signal mmu_pmove_dir        : std_logic;  -- 0=to MMU, 1=from MMU
signal mmu_pmove_size       : std_logic;  -- 0=32-bit, 1=64-bit
signal mmu_pmove_reg        : std_logic_vector(4 downto 0);
signal mmu_pmove_is_dn      : std_logic;
signal mmu_pmove_is_fd      : std_logic;
signal mmu_ea_illegal       : std_logic;
signal mmu_fc_mode          : std_logic_vector(2 downto 0);  -- 000=DFC, 001=SFC, 01x=reserved, 1xx=immediate
signal mmu_fc_value         : std_logic_vector(2 downto 0);

-- ==============================================================================
-- SECTION 2: F-Line Decode (replace existing WHEN "1111" case)
-- ==============================================================================

WHEN "1111" =>
    --
    -- MC68030 PMMU Instructions
    -- All PMMU instructions use opcode F0xx (opcode[11:8] = "0000")
    -- Differentiated by extension word (brief)
    --
    IF cpu(1)='1' AND opcode(11 downto 8)="0000" THEN
        -- This is a PMMU instruction (F000-F0FF)
        -- ALL PMMU instructions require supervisor mode
        IF SVmode='1' THEN
            -- Fetch extension word to decode instruction type
            IF decodeOPC='1' THEN
                set(get_2ndOPC) <= '1';
                getbrief <= '1';
                next_micro_state <= mmu_decode;  -- New state for MMU decode
            END IF;
        ELSE
            -- Privilege violation
            trap_priv <= '1';
            trapmake <= '1';
        END IF;

    ELSIF cpu(1)='1' AND opcode(8 downto 6)="100" THEN
        -- cpSAVE (not implemented)
        -- ... existing cpSAVE code ...
        trap_1111 <= '1';
        trapmake <= '1';

    ELSIF cpu(1)='1' AND opcode(8 downto 6)="101" THEN
        -- cpRESTORE (not implemented)
        -- ... existing cpRESTORE code ...
        trap_1111 <= '1';
        trapmake <= '1';

    ELSE
        -- Other F-line instructions (FPU, etc.) - not implemented
        trap_1111 <= '1';
        trapmake <= '1';
    END IF;

-- ==============================================================================
-- SECTION 3: MMU Instruction Decode State (add to micro_state CASE)
-- ==============================================================================

WHEN mmu_decode =>
    --
    -- MC68030 MMU Instruction Decode
    -- Extension word (brief) is now valid
    -- Decode instruction type from brief[15:13]:
    --   000 = PMOVE (TT0/TT1)
    --   001 = PFLUSH or PMOVEFD
    --   010 = PLOAD or PMOVE (TC/CRP/SRP)
    --   100 = PTEST
    --   110 = PMOVE (MMUSR)
    --

    -- Check for valid PMOVE register selectors first
    IF ((brief(15 downto 13) = "000" AND (brief(14 downto 10) = "00010" OR brief(14 downto 10) = "00011")) OR     -- TT0/TT1
        (brief(15 downto 13) = "010" AND (brief(14 downto 10) = "10000" OR brief(14 downto 10) = "10010" OR brief(14 downto 10) = "10011")) OR -- TC/CRP/SRP
        (brief(15 downto 13) = "110" AND brief(14 downto 10) = "11000")) THEN                                      -- MMUSR

        -- This is PMOVE
        -- Validate EA mode (Control Alterable only - no An, (An)+, PC-rel, Imm)
        IF opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN
            -- Illegal EA mode
            trap_illegal <= '1';
            trapmake <= '1';
        ELSE
            -- Valid PMOVE instruction
            next_micro_state <= mmu_pmove;
        END IF;

    ELSIF brief(15 downto 13) = "001" AND brief(9 downto 8) = "00" AND brief(14 downto 10) /= "00000" THEN
        -- PMOVEFD (flush disable variant)
        IF opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN
            trap_illegal <= '1';
            trapmake <= '1';
        ELSE
            next_micro_state <= mmu_pmove;
        END IF;

    ELSIF brief(15 downto 13) = "001" THEN
        -- PFLUSH
        IF opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN
            trap_illegal <= '1';
            trapmake <= '1';
        ELSE
            next_micro_state <= mmu_pflush;
        END IF;

    ELSIF brief(15 downto 13) = "010" THEN
        -- PLOAD
        IF opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN
            trap_illegal <= '1';
            trapmake <= '1';
        ELSE
            next_micro_state <= mmu_pload;
        END IF;

    ELSIF brief(15 downto 13) = "100" THEN
        -- PTEST
        IF opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR
           (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN
            trap_illegal <= '1';
            trapmake <= '1';
        ELSE
            next_micro_state <= mmu_ptest;
        END IF;

    ELSE
        -- Invalid MMU instruction
        trap_1111 <= '1';
        trapmake <= '1';
    END IF;

-- ==============================================================================
-- SECTION 4: PMOVE Implementation (add to micro_state CASE)
-- ==============================================================================

WHEN mmu_pmove =>
    --
    -- PMOVE Instruction Execution
    -- brief(9) = direction: 0=write to MMU, 1=read from MMU
    -- brief(8) = size: 0=.L (32-bit), 1=.D (64-bit, CRP/SRP only)
    -- brief(14:10) = register selector
    --

    IF opcode(5 downto 3) = "000" THEN
        -- Dn mode - register-to-register transfer
        -- Direction from brief(9)
        setstate <= "01";  -- Ensure register file access

        IF brief(9) = '0' THEN
            -- PMOVE Dn,<MMU> - Write Dn to MMU register
            pmmu_reg_we <= '1';
            pmmu_reg_sel <= brief(14 downto 10);
            pmmu_reg_wdat <= data_read;  -- From Dn
            pmmu_reg_part <= '1';  -- High part for 64-bit
            pmmu_reg_fd <= brief(15 downto 13)="001" and brief(9 downto 8)="00"; -- PMOVEFD flag

            IF brief(8) = '1' THEN
                -- 64-bit transfer (CRP/SRP) - need second word
                next_micro_state <= mmu_pmove_dn_low_wr;
            ELSE
                -- 32-bit transfer - complete
                next_micro_state <= idle;
            END IF;

        ELSE
            -- PMOVE <MMU>,Dn - Read MMU register to Dn
            pmmu_reg_re <= '1';
            pmmu_reg_sel <= brief(14 downto 10);
            pmmu_reg_part <= '1';  -- High part for 64-bit
            set(Regwrena) <= '1';
            -- data_write gets pmmu_reg_rdat

            IF brief(8) = '1' THEN
                -- 64-bit transfer (CRP/SRP) - need second word
                next_micro_state <= mmu_pmove_dn_low_rd;
            ELSE
                -- 32-bit transfer - complete
                next_micro_state <= idle;
            END IF;
        END IF;

    ELSE
        -- Memory mode - need EA calculation
        IF brief(9) = '0' THEN
            -- PMOVE <ea>,<MMU> - Read from memory, write to MMU
            set(ea_build) <= '1';
            set(ea_data_OP1) <= '1';

            -- Determine transfer size
            IF brief(14 downto 10) = "11000" THEN
                datatype <= "01";  -- Word for MMUSR
            ELSE
                datatype <= "10";  -- Longword for others
            END IF;

            setstate <= "10";  -- Memory read
            next_micro_state <= mmu_pmove_mem_rd;

        ELSE
            -- PMOVE <MMU>,<ea> - Read from MMU, write to memory
            set(ea_build) <= '1';
            set(OP1addr) <= '1';
            pmmu_reg_re <= '1';
            pmmu_reg_sel <= brief(14 downto 10);
            pmmu_reg_part <= '1';  -- High part for 64-bit
            next_micro_state <= mmu_pmove_mem_wr;
        END IF;
    END IF;

WHEN mmu_pmove_dn_low_wr =>
    -- Write LOW word of 64-bit register from Dn+1
    pmmu_reg_we <= '1';
    pmmu_reg_sel <= brief(14 downto 10);
    pmmu_reg_wdat <= data_read;  -- From Dn+1 (incremented by register file)
    pmmu_reg_part <= '0';  -- Low part
    next_micro_state <= idle;

WHEN mmu_pmove_dn_low_rd =>
    -- Read LOW word of 64-bit register to Dn+1
    pmmu_reg_re <= '1';
    pmmu_reg_sel <= brief(14 downto 10);
    pmmu_reg_part <= '0';  -- Low part
    set(Regwrena) <= '1';
    next_micro_state <= idle;

WHEN mmu_pmove_mem_rd =>
    -- Memory read completed, write to MMU register
    pmmu_reg_we <= '1';
    pmmu_reg_sel <= brief(14 downto 10);
    pmmu_reg_wdat <= ea_data;  -- From memory
    pmmu_reg_part <= '1';  -- High part
    pmmu_reg_fd <= brief(15 downto 13)="001" and brief(9 downto 8)="00"; -- PMOVEFD

    -- Check if 64-bit register (CRP/SRP)
    IF brief(14 downto 10)="10010" OR brief(14 downto 10)="10011" THEN
        -- Need to read LOW word
        set(mem_addsub) <= '1';  -- Advance EA by 4
        set(OP1addr) <= '1';
        setstate <= "10";  -- Read
        datatype <= "10";  -- Longword
        next_micro_state <= mmu_pmove_mem_rd_low;
    ELSE
        -- Single word transfer complete
        next_micro_state <= idle;
    END IF;

WHEN mmu_pmove_mem_rd_low =>
    -- Read LOW word from memory
    pmmu_reg_we <= '1';
    pmmu_reg_sel <= brief(14 downto 10);
    pmmu_reg_wdat <= ea_data;
    pmmu_reg_part <= '0';  -- Low part
    next_micro_state <= idle;

WHEN mmu_pmove_mem_wr =>
    -- Write to memory from MMU register
    -- pmmu_reg_rdat now has register data
    datatype <= "10";  -- Longword (or word for MMUSR)
    setstate <= "11";  -- Write

    -- Check if 64-bit register
    IF brief(14 downto 10)="10010" OR brief(14 downto 10)="10011" THEN
        -- Need to write LOW word
        set(mem_addsub) <= '1';  -- Advance EA
        pmmu_reg_re <= '1';
        pmmu_reg_sel <= brief(14 downto 10);
        pmmu_reg_part <= '0';  -- Read LOW part next
        next_micro_state <= mmu_pmove_mem_wr_low;
    ELSE
        next_micro_state <= idle;
    END IF;

WHEN mmu_pmove_mem_wr_low =>
    -- Write LOW word to memory
    setstate <= "11";  -- Write
    datatype <= "10";  -- Longword
    next_micro_state <= idle;

-- ==============================================================================
-- SECTION 5: PTEST Implementation
-- ==============================================================================

WHEN mmu_ptest =>
    --
    -- PTEST Instruction Execution
    -- Tests address translation and updates MMUSR
    -- brief(12:10) = level
    -- brief(9) = R/W (0=write, 1=read)
    -- brief(8) = A (address return flag)
    -- brief(7:5) = An number (if A=1)
    -- brief(4:0) = FC encoding
    --

    -- Build EA to get test address
    set(ea_build) <= '1';
    datatype <= "10";  -- Longword address
    setstate <= "10";  -- Read address

    -- Signal PMMU module to perform test
    pmmu_ptest_req <= '1';
    pmmu_fc <= fc_value;  -- Determined from brief[4:0]
    pmmu_addr <= OP1out;  -- EA address
    pmmu_brief <= brief;  -- Pass full brief for level, R/W, etc.

    next_micro_state <= idle;

-- ==============================================================================
-- SECTION 6: PFLUSH Implementation
-- ==============================================================================

WHEN mmu_pflush =>
    --
    -- PFLUSH Instruction Execution
    -- Flush ATC entries
    -- brief(12:8) determines mode:
    --   00000 = PFLUSHA (flush all)
    --   01000 = PFLUSHAN (flush all non-global)
    --   Others = PFLUSH with FC/address
    --

    IF brief(12 downto 8) = "00000" OR brief(12 downto 8) = "01000" THEN
        -- PFLUSHA or PFLUSHAN - no EA needed
        pmmu_pflush_req <= '1';
        pmmu_brief <= brief;
        next_micro_state <= idle;
    ELSE
        -- PFLUSH with EA
        set(ea_build) <= '1';
        datatype <= "10";
        setstate <= "10";
        pmmu_pflush_req <= '1';
        pmmu_fc <= fc_value;  -- From brief
        pmmu_addr <= OP1out;
        pmmu_brief <= brief;
        next_micro_state <= idle;
    END IF;

-- ==============================================================================
-- SECTION 7: PLOAD Implementation
-- ==============================================================================

WHEN mmu_pload =>
    --
    -- PLOAD Instruction Execution
    -- Preload ATC entry
    -- brief(9) = R/W (0=write, 1=read)
    -- brief[12:10] or brief[4:0] = FC
    --

    -- Build EA to get address
    set(ea_build) <= '1';
    datatype <= "10";
    setstate <= "10";

    -- Signal PMMU module
    pmmu_pload_req <= '1';
    pmmu_fc <= fc_value;  -- From brief
    pmmu_addr <= OP1out;
    pmmu_brief <= brief;

    next_micro_state <= idle;

-- ==============================================================================
-- SECTION 8: FC (Function Code) Decoding Helper
-- ==============================================================================
-- This should be in the combinatorial section

-- Decode function code for PTEST/PFLUSH/PLOAD
-- FC encoding (brief[4:0] for PTEST/PLOAD, brief[10:8] for PFLUSH):
--   1xxxx = Immediate FC in bits [2:0]
--   01xxx = Use SFC
--   00xxx = Use DFC

PROCESS(brief, SFC, DFC)
    VARIABLE fc_bits : std_logic_vector(4 downto 0);
BEGIN
    -- Select FC bits based on instruction
    -- (This is simplified - actual selection needs instruction type)
    fc_bits := brief(4 downto 0);

    IF fc_bits(4) = '1' THEN
        -- Immediate FC
        fc_value <= fc_bits(2 downto 0);
    ELSIF fc_bits(3) = '1' THEN
        -- SFC
        fc_value <= SFC;
    ELSE
        -- DFC
        fc_value <= DFC;
    END IF;
END PROCESS;

-- ==============================================================================
-- SECTION 9: Microstate Enumeration (add to TG68K_Pack.vhd)
-- ==============================================================================
-- Add these states to the micro_states enumeration:
--   mmu_decode,           -- MMU instruction decode
--   mmu_pmove,            -- PMOVE execution
--   mmu_pmove_dn_low_wr,  -- PMOVE Dn low word write
--   mmu_pmove_dn_low_rd,  -- PMOVE Dn low word read
--   mmu_pmove_mem_rd,     -- PMOVE memory read
--   mmu_pmove_mem_rd_low, -- PMOVE memory read low word
--   mmu_pmove_mem_wr,     -- PMOVE memory write
--   mmu_pmove_mem_wr_low, -- PMOVE memory write low word
--   mmu_ptest,            -- PTEST execution
--   mmu_pflush,           -- PFLUSH execution
--   mmu_pload,            -- PLOAD execution

