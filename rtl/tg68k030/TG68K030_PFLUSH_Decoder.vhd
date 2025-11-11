------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PFLUSH Instruction Decoder                                      --
--                                                                          --
-- Decodes PFLUSH instructions for invalidating ATC entries                --
--                                                                          --
-- PFLUSH variants:                                                         --
--   PFLUSHA              - Flush all ATC entries                          --
--   PFLUSH FC            - Flush entries matching function code           --
--   PFLUSH FC,EA         - Flush entry matching FC and address            --
--                                                                          --
-- PFLUSH format (F-line coprocessor instruction):                         --
--   First word:  1111 0000 00xx xxxx  (F-line opcode + EA for FC,EA)     --
--   Second word: 0010 mmxx xxxx ff00  (MMU extension: mode + FC)          --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PFLUSH_Decoder is
    port(
        -- Clock and reset
        clk             : in  std_logic;
        reset           : in  std_logic;

        -- Instruction inputs
        opcode          : in  std_logic_vector(15 downto 0);  -- First word
        extension       : in  std_logic_vector(15 downto 0);  -- Second word (extension)
        opcode_valid    : in  std_logic;                      -- Opcode available

        -- CPU state
        supervisor      : in  std_logic;                      -- Supervisor mode

        -- Decode outputs
        is_pflush       : out std_logic;                      -- This is a PFLUSH instruction
        pflush_mode     : out std_logic_vector(1 downto 0);  -- 00=PFLUSHA, 01=FC,EA, 10=FC
        pflush_fc       : out std_logic_vector(2 downto 0);  -- Function code
        pflush_ea_mode  : out std_logic_vector(2 downto 0);  -- EA mode field (for FC,EA)
        pflush_ea_reg   : out std_logic_vector(2 downto 0);  -- EA register field (for FC,EA)

        -- Exception outputs
        illegal_instr   : out std_logic;                      -- Illegal instruction
        priv_violation  : out std_logic                       -- Privilege violation
    );
end entity TG68K030_PFLUSH_Decoder;

architecture rtl of TG68K030_PFLUSH_Decoder is

    -- F-line opcode detection
    constant FLINE_PREFIX : std_logic_vector(9 downto 0) := "1111000000";

    -- MMU coprocessor ID in extension word
    constant MMU_CP_ID : std_logic_vector(2 downto 0) := "010";

    -- PFLUSH mode codes (from extension word bits 12-11)
    constant MODE_PFLUSHA  : std_logic_vector(1 downto 0) := "00";  -- Flush all
    constant MODE_FC_EA    : std_logic_vector(1 downto 0) := "01";  -- Flush FC,EA
    constant MODE_FC       : std_logic_vector(1 downto 0) := "10";  -- Flush FC only

    -- Internal signals
    signal is_fline         : std_logic;
    signal is_mmu_cp        : std_logic;
    signal mode_bits        : std_logic_vector(1 downto 0);
    signal function_code    : std_logic_vector(2 downto 0);
    signal ea_mode          : std_logic_vector(2 downto 0);
    signal ea_reg           : std_logic_vector(2 downto 0);
    signal mode_valid       : std_logic;

begin

    --------------------------------------------------------------
    -- Decode Process
    --------------------------------------------------------------
    decode_proc: process(opcode, extension, opcode_valid)
    begin
        -- Default values
        is_fline    <= '0';
        is_mmu_cp   <= '0';

        -- Check for F-line opcode (bits 15-6 = 1111000000)
        if opcode(15 downto 6) = FLINE_PREFIX then
            is_fline <= '1';
        end if;

        -- Check for MMU coprocessor ID (bits 15-13 = 010)
        if extension(15 downto 13) = MMU_CP_ID then
            is_mmu_cp <= '1';
        end if;

        -- Extract fields from extension word
        mode_bits     <= extension(12 downto 11);  -- Mode: 00=PFLUSHA, 01=FC+EA, 10=FC
        function_code <= extension(4 downto 2);     -- Function code (3 bits)

        -- Extract EA fields from opcode (used only for FC,EA mode)
        ea_mode <= opcode(5 downto 3);
        ea_reg  <= opcode(2 downto 0);

    end process;

    --------------------------------------------------------------
    -- Mode Validation
    --------------------------------------------------------------
    mode_valid_proc: process(mode_bits)
    begin
        -- Valid modes: 00 (PFLUSHA), 01 (FC,EA), 10 (FC)
        -- Invalid modes: 11
        case mode_bits is
            when MODE_PFLUSHA =>
                mode_valid <= '1';
            when MODE_FC_EA =>
                mode_valid <= '1';
            when MODE_FC =>
                mode_valid <= '1';
            when others =>
                mode_valid <= '0';  -- Invalid mode
        end case;
    end process;

    --------------------------------------------------------------
    -- PFLUSH Detection and Validation
    --------------------------------------------------------------
    valid_proc: process(is_fline, is_mmu_cp, mode_valid, opcode_valid, supervisor, mode_bits, ea_mode)
        variable is_valid_pflush : std_logic;
        variable pflusha_special : std_logic;
    begin
        -- PFLUSHA has special encoding requirements:
        -- - First word must be exactly 0xF000 (EA fields = 000)
        -- - Extension word bits 12-11 = 00, bit 10 = 1 (0x2400)
        pflusha_special := '0';
        if mode_bits = MODE_PFLUSHA then
            -- PFLUSHA requires extension bit 10 = 1 (makes it 0x24xx)
            -- This is different from other modes (which use 0x20xx or 0x30xx)
            if extension(10) = '1' and opcode(5 downto 0) = "000000" then
                pflusha_special := '1';
            end if;
        else
            pflusha_special := '1';  -- Not PFLUSHA, no special check
        end if;

        -- PFLUSH is valid if:
        -- 1. F-line opcode detected
        -- 2. MMU coprocessor ID correct
        -- 3. Valid mode bits
        -- 4. Opcode is available
        -- 5. Special PFLUSHA encoding if mode=00
        is_valid_pflush := is_fline and is_mmu_cp and mode_valid and opcode_valid and pflusha_special;

        -- Outputs
        is_pflush <= is_valid_pflush;

        -- Privilege check: PFLUSH is supervisor-only
        if is_valid_pflush = '1' and supervisor = '0' then
            priv_violation <= '1';
        else
            priv_violation <= '0';
        end if;

        -- Illegal instruction if F-line but not valid PFLUSH
        if is_fline = '1' and opcode_valid = '1' then
            if is_mmu_cp = '0' or mode_valid = '0' or pflusha_special = '0' then
                illegal_instr <= '1';
            else
                illegal_instr <= '0';
            end if;
        else
            illegal_instr <= '0';
        end if;
    end process;

    --------------------------------------------------------------
    -- Output Assignments
    --------------------------------------------------------------
    pflush_mode    <= mode_bits;
    pflush_fc      <= function_code;
    pflush_ea_mode <= ea_mode;
    pflush_ea_reg  <= ea_reg;

end architecture rtl;
