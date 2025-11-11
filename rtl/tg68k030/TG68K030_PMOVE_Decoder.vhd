------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PMOVE Instruction Decoder                                       --
--                                                                          --
-- Decodes PMOVE instructions for accessing MMU control registers          --
--                                                                          --
-- PMOVE format (F-line coprocessor instruction):                          --
--   First word:  1111 0000 00xx xxxx  (F-line opcode + EA)                --
--   Second word: 010x xxxx xxxx xxxx  (MMU extension word)                --
--                                                                          --
-- Features:                                                                --
--   - F-line opcode detection (bits 15-6 = 1111000000)                   --
--   - MMU coprocessor ID detection (bits 15-13 = 010)                    --
--   - Register code decoding (8 bits)                                     --
--   - R/W direction (bit 8)                                               --
--   - Flush Disable flag (bit 12) for PMOVEFD                            --
--   - Effective addressing mode support                                   --
--   - Word/Long/Quad size handling                                        --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PMOVE_Decoder is
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
        is_pmove        : out std_logic;                      -- This is a PMOVE instruction
        is_pmovefd      : out std_logic;                      -- PMOVEFD variant (flush disable)
        pmove_direction : out std_logic;                      -- 0=write to MMU, 1=read from MMU
        pmove_reg_code  : out std_logic_vector(7 downto 0);  -- MMU register code
        pmove_ea_mode   : out std_logic_vector(2 downto 0);  -- EA mode field
        pmove_ea_reg    : out std_logic_vector(2 downto 0);  -- EA register field
        pmove_size      : out std_logic_vector(1 downto 0);  -- 00=invalid, 01=word, 10=long, 11=quad

        -- MMU register outputs (decoded from reg_code)
        pmove_sel_tc    : out std_logic;                      -- TC register selected
        pmove_sel_tt0   : out std_logic;                      -- TT0 register selected
        pmove_sel_tt1   : out std_logic;                      -- TT1 register selected
        pmove_sel_crp   : out std_logic;                      -- CRP register selected
        pmove_sel_srp   : out std_logic;                      -- SRP register selected
        pmove_sel_mmusr : out std_logic;                      -- MMUSR register selected

        -- Exception outputs
        illegal_instr   : out std_logic;                      -- Illegal instruction
        priv_violation  : out std_logic                       -- Privilege violation
    );
end entity TG68K030_PMOVE_Decoder;

architecture rtl of TG68K030_PMOVE_Decoder is

    -- F-line opcode detection
    constant FLINE_PREFIX : std_logic_vector(9 downto 0) := "1111000000";

    -- MMU coprocessor ID in extension word
    constant MMU_CP_ID : std_logic_vector(2 downto 0) := "010";

    -- MMU register codes (from extension word bits 7-0)
    constant REG_CODE_TC    : std_logic_vector(7 downto 0) := X"00";
    constant REG_CODE_SRP   : std_logic_vector(7 downto 0) := X"02";
    constant REG_CODE_CRP   : std_logic_vector(7 downto 0) := X"03";
    constant REG_CODE_TT0   : std_logic_vector(7 downto 0) := X"10";
    constant REG_CODE_TT1   : std_logic_vector(7 downto 0) := X"11";
    constant REG_CODE_MMUSR : std_logic_vector(7 downto 0) := X"18";

    -- Internal signals
    signal is_fline         : std_logic;
    signal is_mmu_cp        : std_logic;
    signal flush_disable    : std_logic;
    signal direction        : std_logic;
    signal reg_code         : std_logic_vector(7 downto 0);
    signal ea_mode          : std_logic_vector(2 downto 0);
    signal ea_reg           : std_logic_vector(2 downto 0);

    -- Register selection
    signal sel_tc           : std_logic;
    signal sel_tt0          : std_logic;
    signal sel_tt1          : std_logic;
    signal sel_crp          : std_logic;
    signal sel_srp          : std_logic;
    signal sel_mmusr        : std_logic;
    signal sel_valid        : std_logic;

    -- Size determination
    signal data_size        : std_logic_vector(1 downto 0);

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
        flush_disable <= extension(12);  -- FD bit
        direction     <= extension(8);   -- R/W direction
        reg_code      <= extension(7 downto 0);

        -- Extract EA fields from opcode
        ea_mode <= opcode(5 downto 3);
        ea_reg  <= opcode(2 downto 0);

    end process;

    --------------------------------------------------------------
    -- Register Selection Decode
    --------------------------------------------------------------
    reg_select_proc: process(reg_code)
    begin
        -- Default: no register selected
        sel_tc    <= '0';
        sel_tt0   <= '0';
        sel_tt1   <= '0';
        sel_crp   <= '0';
        sel_srp   <= '0';
        sel_mmusr <= '0';
        sel_valid <= '0';

        case reg_code is
            when REG_CODE_TC =>
                sel_tc    <= '1';
                sel_valid <= '1';
            when REG_CODE_TT0 =>
                sel_tt0   <= '1';
                sel_valid <= '1';
            when REG_CODE_TT1 =>
                sel_tt1   <= '1';
                sel_valid <= '1';
            when REG_CODE_CRP =>
                sel_crp   <= '1';
                sel_valid <= '1';
            when REG_CODE_SRP =>
                sel_srp   <= '1';
                sel_valid <= '1';
            when REG_CODE_MMUSR =>
                sel_mmusr <= '1';
                sel_valid <= '1';
            when others =>
                -- Invalid register code
                sel_valid <= '0';
        end case;
    end process;

    --------------------------------------------------------------
    -- Data Size Determination
    --------------------------------------------------------------
    size_proc: process(sel_tc, sel_tt0, sel_tt1, sel_crp, sel_srp, sel_mmusr)
    begin
        -- Determine data size based on register type
        -- 00 = invalid, 01 = word (16-bit), 10 = long (32-bit), 11 = quad (64-bit)

        if sel_mmusr = '1' then
            -- MMUSR is 16-bit (word)
            data_size <= "01";
        elsif sel_tc = '1' or sel_tt0 = '1' or sel_tt1 = '1' then
            -- TC, TT0, TT1 are 32-bit (long)
            data_size <= "10";
        elsif sel_crp = '1' or sel_srp = '1' then
            -- CRP, SRP are 64-bit (quad)
            data_size <= "11";
        else
            -- Invalid
            data_size <= "00";
        end if;
    end process;

    --------------------------------------------------------------
    -- PMOVE Detection and Validation
    --------------------------------------------------------------
    valid_proc: process(is_fline, is_mmu_cp, sel_valid, opcode_valid, supervisor)
        variable is_valid_pmove : std_logic;
    begin
        -- PMOVE is valid if:
        -- 1. F-line opcode detected
        -- 2. MMU coprocessor ID correct
        -- 3. Valid register code
        -- 4. Opcode is available
        is_valid_pmove := is_fline and is_mmu_cp and sel_valid and opcode_valid;

        -- Outputs
        is_pmove <= is_valid_pmove;

        -- Privilege check: PMOVE is supervisor-only
        if is_valid_pmove = '1' and supervisor = '0' then
            priv_violation <= '1';
        else
            priv_violation <= '0';
        end if;

        -- Illegal instruction if F-line but not valid PMOVE
        if is_fline = '1' and opcode_valid = '1' then
            if is_mmu_cp = '0' or sel_valid = '0' then
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
    is_pmovefd      <= flush_disable;
    pmove_direction <= direction;
    pmove_reg_code  <= reg_code;
    pmove_ea_mode   <= ea_mode;
    pmove_ea_reg    <= ea_reg;
    pmove_size      <= data_size;

    pmove_sel_tc    <= sel_tc;
    pmove_sel_tt0   <= sel_tt0;
    pmove_sel_tt1   <= sel_tt1;
    pmove_sel_crp   <= sel_crp;
    pmove_sel_srp   <= sel_srp;
    pmove_sel_mmusr <= sel_mmusr;

end architecture rtl;
