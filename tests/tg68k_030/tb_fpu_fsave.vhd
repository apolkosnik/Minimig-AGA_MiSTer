--------------------------------------------------------------------------------
-- TG68K_FPU FSAVE Detection Test
-- Tests the exact sequence used by DiagROM to detect MC68882:
--   1. FTST to set FPSR condition codes
--   2. FSAVE to read frame size
-- Expected: 60-byte IDLE frame (format 0x60) for MC68882 detection
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.TG68K_Pack.all;

entity tb_fpu_fsave is
end tb_fpu_fsave;

architecture behavior of tb_fpu_fsave is

    -- Component declaration for TG68K_FPU
    component TG68K_FPU
        port(
            clk                  : in std_logic;
            nReset               : in std_logic;
            clkena               : in std_logic;
            opcode               : in std_logic_vector(15 downto 0);
            extension_word       : in std_logic_vector(15 downto 0);
            fpu_enable           : in std_logic;
            supervisor_mode      : in std_logic;
            cpu_data_in          : in std_logic_vector(31 downto 0);
            cpu_address_in       : in std_logic_vector(31 downto 0);
            fpu_data_out         : out std_logic_vector(31 downto 0);
            fsave_data_request   : in std_logic;
            fsave_data_index     : in integer range 0 to 54;
            frestore_data_write  : in std_logic;
            frestore_data_in     : in std_logic_vector(31 downto 0);
            fmovem_data_request  : in std_logic;
            fmovem_reg_index     : in integer range 0 to 7;
            fmovem_data_write    : in std_logic;
            fmovem_data_in       : in std_logic_vector(79 downto 0);
            fmovem_data_out      : out std_logic_vector(79 downto 0);
            fpu_busy             : out std_logic;
            fpu_done             : buffer std_logic;
            fpu_exception        : buffer std_logic;
            exception_code       : out std_logic_vector(7 downto 0);
            fpcr_out             : out std_logic_vector(31 downto 0);
            fpsr_out             : out std_logic_vector(31 downto 0);
            fpiar_out            : out std_logic_vector(31 downto 0);
            fsave_frame_size     : out integer range 4 to 216;
            fsave_size_valid     : out std_logic;
            cir_address          : in std_logic_vector(4 downto 0);
            cir_write            : in std_logic;
            cir_read             : in std_logic;
            cir_data_in          : in std_logic_vector(15 downto 0);
            cir_data_out         : out std_logic_vector(15 downto 0);
            cir_data_valid       : buffer std_logic
        );
    end component;

    -- Clock and control
    constant clk_period : time := 10 ns;
    signal clk : std_logic := '0';
    signal nReset : std_logic := '0';
    signal clkena : std_logic := '1';
    signal test_running : boolean := true;

    -- FPU interface signals
    signal opcode : std_logic_vector(15 downto 0) := X"0000";
    signal extension_word : std_logic_vector(15 downto 0) := X"0000";
    signal fpu_enable : std_logic := '0';
    signal supervisor_mode : std_logic := '1';
    signal cpu_data_in : std_logic_vector(31 downto 0) := X"00000000";
    signal cpu_address_in : std_logic_vector(31 downto 0) := X"00000000";
    signal fpu_data_out : std_logic_vector(31 downto 0);
    signal fsave_data_request : std_logic := '0';
    signal fsave_data_index : integer range 0 to 54 := 0;
    signal frestore_data_write : std_logic := '0';
    signal frestore_data_in : std_logic_vector(31 downto 0) := X"00000000";
    signal fmovem_data_request : std_logic := '0';
    signal fmovem_reg_index : integer range 0 to 7 := 0;
    signal fmovem_data_write : std_logic := '0';
    signal fmovem_data_in : std_logic_vector(79 downto 0) := (others => '0');
    signal fmovem_data_out : std_logic_vector(79 downto 0);
    signal fpu_busy : std_logic;
    signal fpu_done : std_logic;
    signal fpu_exception : std_logic;
    signal exception_code : std_logic_vector(7 downto 0);
    signal fpcr_out : std_logic_vector(31 downto 0);
    signal fpsr_out : std_logic_vector(31 downto 0);
    signal fpiar_out : std_logic_vector(31 downto 0);
    signal fsave_frame_size : integer range 4 to 216;
    signal fsave_size_valid : std_logic;
    signal cir_address : std_logic_vector(4 downto 0) := "00000";
    signal cir_write : std_logic := '0';
    signal cir_read : std_logic := '0';
    signal cir_data_in : std_logic_vector(15 downto 0) := X"0000";
    signal cir_data_out : std_logic_vector(15 downto 0);
    signal cir_data_valid : std_logic;

    -- Test state machine
    type test_state_t is (IDLE, EXEC_FTST, WAIT_FTST, EXEC_FSAVE, COLLECT_FSAVE, CHECK_RESULTS, DONE);
    signal test_state : test_state_t := IDLE;
    signal wait_counter : integer := 0;

    -- FSAVE data collection
    type fsave_data_t is array(0 to 54) of std_logic_vector(31 downto 0);
    signal fsave_data : fsave_data_t := (others => (others => '0'));
    signal fsave_count : integer := 0;

begin

    -- Instantiate FPU
    uut: TG68K_FPU
        port map(
            clk => clk,
            nReset => nReset,
            clkena => clkena,
            opcode => opcode,
            extension_word => extension_word,
            fpu_enable => fpu_enable,
            supervisor_mode => supervisor_mode,
            cpu_data_in => cpu_data_in,
            cpu_address_in => cpu_address_in,
            fpu_data_out => fpu_data_out,
            fsave_data_request => fsave_data_request,
            fsave_data_index => fsave_data_index,
            frestore_data_write => frestore_data_write,
            frestore_data_in => frestore_data_in,
            fmovem_data_request => fmovem_data_request,
            fmovem_reg_index => fmovem_reg_index,
            fmovem_data_write => fmovem_data_write,
            fmovem_data_in => fmovem_data_in,
            fmovem_data_out => fmovem_data_out,
            fpu_busy => fpu_busy,
            fpu_done => fpu_done,
            fpu_exception => fpu_exception,
            exception_code => exception_code,
            fpcr_out => fpcr_out,
            fpsr_out => fpsr_out,
            fpiar_out => fpiar_out,
            fsave_frame_size => fsave_frame_size,
            fsave_size_valid => fsave_size_valid,
            cir_address => cir_address,
            cir_write => cir_write,
            cir_read => cir_read,
            cir_data_in => cir_data_in,
            cir_data_out => cir_data_out,
            cir_data_valid => cir_data_valid
        );

    -- Clock generation
    clk_process: process
    begin
        while test_running loop
            clk <= '0';
            wait for clk_period/2;
            clk <= '1';
            wait for clk_period/2;
        end loop;
        wait;
    end process;

    -- Test sequence
    test_process: process
        variable frame_format : std_logic_vector(7 downto 0);
        variable frame_size_bytes : integer;
        variable test_pass : boolean := false;
    begin
        -- Reset
        nReset <= '0';
        wait for 50 ns;
        nReset <= '1';
        wait for 50 ns;

        report "========== FPU FSAVE Detection Test ==========";
        report "Simulating DiagROM detection sequence:";
        report "  1. FTST.B to set FPSR";
        report "  2. FSAVE to check frame size";
        report "==============================================";

        -- Test 1: Execute FTST.B (opcode F201 583A - FTST.B format)
        report ">>> Executing FTST.B to set FPSR condition codes...";
        test_state <= EXEC_FTST;
        opcode <= X"F201";           -- FTST instruction prefix
        extension_word <= X"583A";   -- FTST.B format specifier
        cpu_data_in <= X"00000042";  -- Test value (byte = 0x42)

        -- Enable FPU and wait for it to start
        fpu_enable <= '1';
        wait for 5 * clk_period;

        -- Wait for FTST to complete - keep fpu_enable high
        test_state <= WAIT_FTST;
        wait_counter <= 0;
        while fpu_done = '0' and wait_counter < 1000 loop
            wait for clk_period;
            wait_counter <= wait_counter + 1;
        end loop;

        if fpu_done = '1' then
            report "FTST completed. FPSR = 0x" & integer'image(to_integer(unsigned(fpsr_out)));
        else
            report "ERROR: FTST timed out!";
        end if;

        -- Small delay before FSAVE
        fpu_enable <= '0';
        wait for 10 * clk_period;

        -- Test 2: Execute FSAVE
        report ">>> Executing FSAVE to check frame format...";
        test_state <= EXEC_FSAVE;

        -- Check frame size before FSAVE starts
        report "Frame size before FSAVE: " & integer'image(fsave_frame_size) & " bytes";
        report "Frame size valid: " & std_logic'image(fsave_size_valid);
        frame_size_bytes := fsave_frame_size;

        -- Collect FSAVE data
        test_state <= COLLECT_FSAVE;
        fsave_count <= 0;

        -- Request FSAVE data for expected frame
        for i in 0 to (fsave_frame_size/4 - 1) loop
            fsave_data_request <= '1';
            fsave_data_index <= i;
            wait for clk_period;
            fsave_data(i) <= fpu_data_out;
            fsave_count <= i + 1;
            fsave_data_request <= '0';
            wait for clk_period;
        end loop;

        -- Analyze results
        test_state <= CHECK_RESULTS;
        frame_format := fsave_data(0)(31 downto 24);

        report "========== FSAVE Results ==========";
        report "Frame format: " & integer'image(to_integer(unsigned(frame_format)));
        report "Frame size: " & integer'image(frame_size_bytes) & " bytes";
        report "FPSR value: " & integer'image(to_integer(unsigned(fpsr_out)));
        report "First longword: " & integer'image(to_integer(unsigned(fsave_data(0))));

        -- Check results
        if frame_format = X"60" and frame_size_bytes = 60 then
            report "*** PASS: MC68882 IDLE frame (0x60, 60 bytes) - DiagROM will detect FPU ***";
            test_pass := true;
        elsif frame_format = X"00" and frame_size_bytes = 4 then
            report "*** FAIL: NULL frame (0x00, 4 bytes) - FTST did not preserve FPSR ***";
            report "*** DiagROM will NOT detect FPU ***";
            test_pass := false;
        elsif frame_format = X"D8" and frame_size_bytes = 216 then
            report "*** UNEXPECTED: BUSY frame (0xD8, 216 bytes) ***";
            test_pass := false;
        else
            report "*** FAIL: Unknown frame format or size ***";
            test_pass := false;
        end if;

        report "===================================";

        test_state <= DONE;
        test_running <= false;

        if test_pass then
            report "TEST PASSED" severity note;
        else
            report "TEST FAILED" severity error;
        end if;

        wait;
    end process;

end behavior;
