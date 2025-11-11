------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PTEST Instruction Decoder                                       --
--                                                                          --
-- Decodes PTEST instructions for testing MMU address translations         --
--                                                                          --
-- PTEST format (F-line coprocessor instruction):                          --
--   First word:  1111 0000 00mm mrrr  (F-line opcode + EA)                --
--   Second word: 100R RRRR LLLL LFFF  (PTEST extension: R=return, L=level) --
--                                                                          --
-- Features:                                                                --
--   - Level extraction (0-7)                                               --
--   - Function code extraction (0-7)                                       --
--   - R/W bit (read=0, write=1)                                            --
--   - Return register enable and selection (An)                           --
--   - EA mode support                                                      --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_PTEST_Decoder is
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
        is_ptest        : out std_logic;                      -- This is a PTEST instruction
        ptest_level     : out std_logic_vector(2 downto 0);  -- Level (0-7)
        ptest_fc        : out std_logic_vector(2 downto 0);  -- Function code (0-7)
        ptest_rw        : out std_logic;                      -- 0=read, 1=write
        ptest_ret_en    : out std_logic;                      -- Return register enable
        ptest_ret_reg   : out std_logic_vector(2 downto 0);  -- Return register (An, 0-7)
        ptest_ea_mode   : out std_logic_vector(2 downto 0);  -- EA mode field
        ptest_ea_reg    : out std_logic_vector(2 downto 0);  -- EA register field

        -- Exception outputs
        illegal_instr   : out std_logic;                      -- Illegal instruction
        priv_violation  : out std_logic                       -- Privilege violation
    );
end entity TG68K030_PTEST_Decoder;

architecture rtl of TG68K030_PTEST_Decoder is

    -- F-line opcode detection
    constant FLINE_PREFIX : std_logic_vector(9 downto 0) := "1111000000";

    -- PTEST coprocessor subfunction ID in extension word
    constant PTEST_CP_ID : std_logic_vector(2 downto 0) := "100";

    -- Internal signals
    signal is_fline         : std_logic;
    signal is_ptest_cp      : std_logic;
    signal level            : std_logic_vector(2 downto 0);
    signal function_code    : std_logic_vector(2 downto 0);
    signal rw_bit           : std_logic;
    signal return_enable    : std_logic;
    signal return_reg       : std_logic_vector(2 downto 0);
    signal ea_mode          : std_logic_vector(2 downto 0);
    signal ea_reg           : std_logic_vector(2 downto 0);
    signal reserved_ok      : std_logic;

begin

    --------------------------------------------------------------
    -- Decode Process
    --------------------------------------------------------------
    decode_proc: process(opcode, extension, opcode_valid)
    begin
        -- Default values
        is_fline    <= '0';
        is_ptest_cp <= '0';

        -- Check for F-line opcode (bits 15-6 = 1111000000)
        if opcode(15 downto 6) = FLINE_PREFIX then
            is_fline <= '1';
        end if;

        -- Check for PTEST coprocessor ID (bits 15-13 = 100)
        if extension(15 downto 13) = PTEST_CP_ID then
            is_ptest_cp <= '1';
        end if;

        -- Extract fields from extension word
        -- Extension format: 100R RRRR LLLL LFFF X
        --   R = return register enable
        --   RRRR = return register number (An)
        --   LLLL = level (4 bits, but only 0-7 valid)
        --   FFF = function code
        --   X = R/W bit
        return_enable <= extension(12);
        return_reg    <= extension(11 downto 9);
        level         <= extension(8 downto 6);
        function_code <= extension(5 downto 3);
        rw_bit        <= extension(2);

        -- Check reserved bits (bits 1-0 must be 0)
        if extension(1 downto 0) = "00" then
            reserved_ok <= '1';
        else
            reserved_ok <= '0';
        end if;

        -- Extract EA fields from opcode
        ea_mode <= opcode(5 downto 3);
        ea_reg  <= opcode(2 downto 0);

    end process;

    --------------------------------------------------------------
    -- PTEST Detection and Validation
    --------------------------------------------------------------
    valid_proc: process(is_fline, is_ptest_cp, reserved_ok, opcode_valid, supervisor)
        variable is_valid_ptest : std_logic;
    begin
        -- PTEST is valid if:
        -- 1. F-line opcode detected
        -- 2. PTEST coprocessor ID correct (100)
        -- 3. Reserved bits are zero
        -- 4. Opcode is available
        is_valid_ptest := is_fline and is_ptest_cp and reserved_ok and opcode_valid;

        -- Outputs
        is_ptest <= is_valid_ptest;

        -- Privilege check: PTEST is supervisor-only
        if is_valid_ptest = '1' and supervisor = '0' then
            priv_violation <= '1';
        else
            priv_violation <= '0';
        end if;

        -- Illegal instruction if F-line but not valid PTEST
        if is_fline = '1' and opcode_valid = '1' then
            if is_ptest_cp = '0' or reserved_ok = '0' then
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
    ptest_level    <= level;
    ptest_fc       <= function_code;
    ptest_rw       <= rw_bit;
    ptest_ret_en   <= return_enable;
    ptest_ret_reg  <= return_reg;
    ptest_ea_mode  <= ea_mode;
    ptest_ea_reg   <= ea_reg;

end architecture rtl;
