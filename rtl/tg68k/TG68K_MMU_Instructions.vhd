-- TG68K_MMU_Instructions.vhd
-- Clean implementation of MC68030 MMU instructions (PMOVE, PTEST, PFLUSH, PLOAD)
-- Based on MC68030 User's Manual specifications
--
-- This module provides a clean decoder and state machine for MMU instructions.
-- It is designed to be instantiated within TG68KdotC_Kernel.
--
-- Author: Claude Code
-- Date: 2025-11-11
-- License: Same as TG68K (open source)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity TG68K_MMU_Instructions is
  port(
    -- Clock and Reset
    clk            : in  std_logic;
    reset          : in  std_logic;

    -- Instruction Input
    opcode         : in  std_logic_vector(15 downto 0);  -- Current instruction opcode
    brief          : in  std_logic_vector(15 downto 0);  -- Extension word
    brief_valid    : in  std_logic;                      -- Extension word is valid

    -- CPU State
    supervisor     : in  std_logic;                      -- Supervisor mode flag

    -- Control Signals
    decode_enable  : in  std_logic;                      -- Enable instruction decode
    execute_enable : in  std_logic;                      -- Enable instruction execution

    -- Status Outputs
    is_mmu_inst    : out std_logic;                      -- This is an MMU instruction
    inst_valid     : out std_logic;                      -- Instruction is valid (no illegal conditions)
    inst_complete  : out std_logic;                      -- Instruction completed
    priv_violation : out std_logic;                      -- Privilege violation detected
    illegal_inst   : out std_logic;                      -- Illegal instruction detected

    -- Instruction Type Decode
    is_pmove       : out std_logic;
    is_ptest       : out std_logic;
    is_pflush      : out std_logic;
    is_pload       : out std_logic;

    -- PMOVE Specifics
    pmove_direction : out std_logic;                     -- 0=to MMU, 1=from MMU
    pmove_size      : out std_logic;                     -- 0=32-bit, 1=64-bit
    pmove_register  : out std_logic_vector(4 downto 0);  -- Register selector
    pmove_is_dn     : out std_logic;                     -- Dn direct mode
    pmove_is_fd     : out std_logic;                     -- PMOVEFD (flush disable)

    -- PTEST Specifics
    ptest_rw        : out std_logic;                     -- 0=write, 1=read
    ptest_level     : out std_logic_vector(2 downto 0);  -- Level (0-7)
    ptest_return    : out std_logic;                     -- Return address in An
    ptest_an        : out std_logic_vector(2 downto 0);  -- An for return address

    -- PFLUSH Specifics
    pflush_mode     : out std_logic_vector(12 downto 8); -- Mode bits from brief
    pflush_all      : out std_logic;                     -- PFLUSHA
    pflush_all_ng   : out std_logic;                     -- PFLUSHAN (non-global)

    -- PLOAD Specifics
    pload_rw        : out std_logic;                     -- 0=write, 1=read

    -- Function Code (common to PTEST, PFLUSH, PLOAD)
    fc_immediate    : out std_logic;                     -- FC is immediate
    fc_use_sfc      : out std_logic;                     -- Use SFC
    fc_use_dfc      : out std_logic;                     -- Use DFC
    fc_value        : out std_logic_vector(2 downto 0);  -- Immediate FC value

    -- EA Mode Info
    ea_mode         : out std_logic_vector(5 downto 0);  -- EA mode from opcode[5:0]
    ea_requires_calc : out std_logic;                    -- EA needs calculation (not Dn)

    -- Microcode State Control
    next_state_req  : out micro_states;                  -- Requested next microcode state
    state_valid     : out std_logic                      -- next_state_req is valid
  );
end TG68K_MMU_Instructions;

architecture rtl of TG68K_MMU_Instructions is

  -- Internal decode signals
  signal mmu_detected     : std_logic;
  signal pmove_detected   : std_logic;
  signal ptest_detected   : std_logic;
  signal pflush_detected  : std_logic;
  signal pload_detected   : std_logic;

  -- Register selector validation
  signal valid_tt0_tt1    : std_logic;  -- brief[15:13]="000", brief[14:10]=0x02/0x03
  signal valid_tc_crp_srp : std_logic;  -- brief[15:13]="010", brief[14:10]=0x10/0x12/0x13
  signal valid_mmusr      : std_logic;  -- brief[15:13]="110", brief[14:10]=0x18
  signal valid_pmove_reg  : std_logic;  -- Any valid PMOVE register

  -- EA mode validation
  signal ea_is_dn         : std_logic;  -- opcode[5:3]="000"
  signal ea_is_an         : std_logic;  -- opcode[5:3]="001" (ILLEGAL)
  signal ea_is_an_inc     : std_logic;  -- opcode[5:3]="011" (ILLEGAL)
  signal ea_is_imm        : std_logic;  -- opcode[5:3]="111", opcode[2:0]="100" (ILLEGAL)
  signal ea_is_pc_rel     : std_logic;  -- opcode[5:3]="111", opcode[2:1]="01" (ILLEGAL)
  signal ea_is_illegal    : std_logic;
  signal ea_is_control_alt: std_logic;  -- Legal control alterable mode

  -- PMOVEFD detection
  signal is_pmovefd       : std_logic;

  -- Function code decode (PTEST, PFLUSH, PLOAD)
  signal fc_bits          : std_logic_vector(4 downto 0);
  signal fc_imm           : std_logic;
  signal fc_sfc           : std_logic;
  signal fc_dfc           : std_logic;

begin

  ----------------------------------------------------------------------------
  -- MMU Instruction Detection
  ----------------------------------------------------------------------------
  -- All MMU instructions have opcode[15:8] = F0xx
  mmu_detected <= '1' when opcode(15 downto 8) = X"F0" else '0';

  ----------------------------------------------------------------------------
  -- EA Mode Decode
  ----------------------------------------------------------------------------
  ea_is_dn      <= '1' when opcode(5 downto 3) = "000" else '0';
  ea_is_an      <= '1' when opcode(5 downto 3) = "001" else '0';
  ea_is_an_inc  <= '1' when opcode(5 downto 3) = "011" else '0';
  ea_is_imm     <= '1' when opcode(5 downto 3) = "111" and opcode(2 downto 0) = "100" else '0';
  ea_is_pc_rel  <= '1' when opcode(5 downto 3) = "111" and opcode(2 downto 1) = "01" else '0';

  -- EA is illegal if it's An, (An)+, Immediate, or PC-relative
  ea_is_illegal <= ea_is_an or ea_is_an_inc or ea_is_imm or ea_is_pc_rel;

  -- EA is control alterable if it's NOT illegal and NOT Dn
  ea_is_control_alt <= not ea_is_illegal and not ea_is_dn;

  ea_requires_calc <= ea_is_control_alt;
  ea_mode <= opcode(5 downto 0);

  ----------------------------------------------------------------------------
  -- Register Selector Validation (for PMOVE)
  ----------------------------------------------------------------------------
  -- TT0/TT1: brief[15:13]="000" AND (brief[14:10]="00010" OR brief[14:10]="00011")
  valid_tt0_tt1 <= '1' when brief(15 downto 13) = "000" and
                             (brief(14 downto 10) = "00010" or brief(14 downto 10) = "00011")
                   else '0';

  -- TC/CRP/SRP: brief[15:13]="010" AND (brief[14:10]="10000" OR "10010" OR "10011")
  valid_tc_crp_srp <= '1' when brief(15 downto 13) = "010" and
                                (brief(14 downto 10) = "10000" or
                                 brief(14 downto 10) = "10010" or
                                 brief(14 downto 10) = "10011")
                      else '0';

  -- MMUSR: brief[15:13]="110" AND brief[14:10]="11000"
  valid_mmusr <= '1' when brief(15 downto 13) = "110" and brief(14 downto 10) = "11000"
                 else '0';

  -- PMOVEFD: brief[15:13]="001" AND brief[9:8]="00" AND brief[14:10] is valid reg
  is_pmovefd <= '1' when brief(15 downto 13) = "001" and
                         brief(9 downto 8) = "00" and
                         brief(14 downto 10) /= "00000"
                else '0';

  -- Any valid PMOVE register (excluding PMOVEFD for now)
  valid_pmove_reg <= (valid_tt0_tt1 or valid_tc_crp_srp or valid_mmusr) and not is_pmovefd;

  ----------------------------------------------------------------------------
  -- Instruction Type Detection
  ----------------------------------------------------------------------------
  -- PMOVE: Valid register selector OR PMOVEFD
  pmove_detected <= '1' when brief_valid = '1' and (valid_pmove_reg = '1' or is_pmovefd = '1')
                    else '0';

  -- PTEST: brief[15:13]="100"
  ptest_detected <= '1' when brief_valid = '1' and brief(15 downto 13) = "100"
                    else '0';

  -- PFLUSH: brief[15:13]="001" AND NOT PMOVEFD
  pflush_detected <= '1' when brief_valid = '1' and
                              brief(15 downto 13) = "001" and
                              is_pmovefd = '0'
                     else '0';

  -- PLOAD: brief[15:13]="010" AND NOT valid PMOVE register
  pload_detected <= '1' when brief_valid = '1' and
                             brief(15 downto 13) = "010" and
                             valid_pmove_reg = '0'
                    else '0';

  ----------------------------------------------------------------------------
  -- Output Assignment
  ----------------------------------------------------------------------------
  is_mmu_inst <= mmu_detected;
  is_pmove    <= pmove_detected;
  is_ptest    <= ptest_detected;
  is_pflush   <= pflush_detected;
  is_pload    <= pload_detected;

  -- Privilege check: All MMU instructions require supervisor mode
  priv_violation <= mmu_detected and not supervisor when decode_enable = '1' else '0';

  -- Illegal instruction: EA mode not allowed
  illegal_inst <= mmu_detected and ea_is_illegal when decode_enable = '1' else '0';

  -- Instruction is valid if detected, privileged, and legal EA
  inst_valid <= mmu_detected and supervisor and not ea_is_illegal when decode_enable = '1' else '0';

  ----------------------------------------------------------------------------
  -- PMOVE Decode
  ----------------------------------------------------------------------------
  pmove_direction <= brief(9);  -- 0=to MMU, 1=from MMU
  pmove_size      <= brief(8);  -- 0=.L (32-bit), 1=.D (64-bit)
  pmove_register  <= brief(14 downto 10);
  pmove_is_dn     <= ea_is_dn;
  pmove_is_fd     <= is_pmovefd;

  ----------------------------------------------------------------------------
  -- PTEST Decode
  ----------------------------------------------------------------------------
  ptest_rw     <= brief(9);     -- 0=PTESTW (write), 1=PTESTR (read)
  ptest_level  <= brief(12 downto 10);
  ptest_return <= brief(8);     -- A bit
  ptest_an     <= brief(7 downto 5);

  ----------------------------------------------------------------------------
  -- PFLUSH Decode
  ----------------------------------------------------------------------------
  pflush_mode   <= brief(12 downto 8);
  pflush_all    <= '1' when brief(12 downto 8) = "00000" else '0';  -- PFLUSHA
  pflush_all_ng <= '1' when brief(12 downto 8) = "01000" else '0';  -- PFLUSHAN

  ----------------------------------------------------------------------------
  -- PLOAD Decode
  ----------------------------------------------------------------------------
  pload_rw <= brief(9);  -- 0=PLOADW (write), 1=PLOADR (read)

  ----------------------------------------------------------------------------
  -- Function Code Decode (common to PTEST, PFLUSH, PLOAD)
  ----------------------------------------------------------------------------
  -- FC encoding (from brief[4:0] or brief[12:10]):
  -- - 1xxxx = Immediate FC in bits [2:0]
  -- - 01xxx = Use SFC
  -- - 00xxx = Use DFC

  -- For PTEST/PLOAD: FC in brief[4:0]
  -- For PFLUSH: FC in brief[10:8] when not PFLUSHA/PFLUSHAN
  fc_bits <= brief(4 downto 0) when (ptest_detected = '1' or pload_detected = '1')
             else "00" & brief(10 downto 8);  -- PFLUSH uses bits 10:8

  fc_imm  <= fc_bits(4);                      -- Immediate if bit 4 = 1
  fc_sfc  <= not fc_bits(4) and fc_bits(3);  -- SFC if bits[4:3] = "01"
  fc_dfc  <= not fc_bits(4) and not fc_bits(3); -- DFC if bits[4:3] = "00"

  fc_immediate <= fc_imm;
  fc_use_sfc   <= fc_sfc;
  fc_use_dfc   <= fc_dfc;
  fc_value     <= fc_bits(2 downto 0);  -- Immediate FC value

  ----------------------------------------------------------------------------
  -- State Machine Control
  ----------------------------------------------------------------------------
  -- This is intentionally simple - just decode and provide information.
  -- The actual state machine is in the kernel.
  -- We just indicate when instruction is complete (synchronous operation).

  inst_complete <= '0';  -- Instructions complete via kernel state machine
  next_state_req <= idle;  -- Default
  state_valid <= '0';  -- Not used in this simple decoder

end rtl;
