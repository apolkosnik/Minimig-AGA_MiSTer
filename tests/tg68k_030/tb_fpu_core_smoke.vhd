library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity tb_fpu_core_smoke is
end tb_fpu_core_smoke;

architecture sim of tb_fpu_core_smoke is
    constant CLK_PERIOD : time := 10 ns;

    signal clk : std_logic := '0';
    signal nReset : std_logic := '0';
    signal clkena : std_logic := '1';
    signal opcode : std_logic_vector(15 downto 0) := (others => '0');
    signal extension_word : std_logic_vector(15 downto 0) := (others => '0');
    signal fpu_enable : std_logic := '0';
    signal cpu_data_in : std_logic_vector(31 downto 0) := (others => '0');
    signal fpu_data_out : std_logic_vector(31 downto 0);
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
    signal cir_data_out : std_logic_vector(15 downto 0);
    signal cir_data_valid : std_logic;
    signal alu_start_operation : std_logic := '0';
    signal alu_operation_code : std_logic_vector(6 downto 0) := (others => '0');
    signal alu_operand_a : std_logic_vector(79 downto 0) := (others => '0');
    signal alu_operand_b : std_logic_vector(79 downto 0) := (others => '0');
    signal alu_result : std_logic_vector(79 downto 0);
    signal alu_result_valid : std_logic;
    signal alu_overflow : std_logic;
    signal alu_underflow : std_logic;
    signal alu_inexact : std_logic;
    signal alu_invalid : std_logic;
    signal alu_divide_by_zero : std_logic;
    signal alu_quotient_byte : std_logic_vector(7 downto 0);
    signal alu_operation_busy : std_logic;
    signal alu_operation_done : std_logic;
    signal test_done : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68K_FPU
        generic map(
            Enable_Transcendental => 0,
            Enable_Packed_Decimal => 0
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena => clkena,
            opcode => opcode,
            extension_word => extension_word,
            fpu_enable => fpu_enable,
            supervisor_mode => '1',
            cpu_data_in => cpu_data_in,
            cpu_address_in => x"00001000",
            fpu_data_out => fpu_data_out,
            fsave_data_request => '0',
            fsave_data_index => 0,
            frestore_data_write => '0',
            frestore_data_in => (others => '0'),
            fmovem_data_request => '0',
            fmovem_reg_index => 0,
            fmovem_data_write => '0',
            fmovem_data_in => (others => '0'),
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
            cir_address => (others => '0'),
            cir_write => '0',
            cir_read => '0',
            cir_data_in => (others => '0'),
            cir_data_out => cir_data_out,
            cir_data_valid => cir_data_valid
        );

    alu_dut: entity work.TG68K_FPU_ALU
        port map(
            clk => clk,
            nReset => nReset,
            clkena => clkena,
            start_operation => alu_start_operation,
            operation_code => alu_operation_code,
            rounding_mode => "00",
            operand_a => alu_operand_a,
            operand_b => alu_operand_b,
            result => alu_result,
            result_valid => alu_result_valid,
            overflow => alu_overflow,
            underflow => alu_underflow,
            inexact => alu_inexact,
            invalid => alu_invalid,
            divide_by_zero => alu_divide_by_zero,
            quotient_byte => alu_quotient_byte,
            operation_busy => alu_operation_busy,
            operation_done => alu_operation_done
        );

    process
        procedure run_ftst_long(
            constant value : in std_logic_vector(31 downto 0);
            constant expected_cc : in std_logic_vector(3 downto 0);
            constant label_text : in string
        ) is
            variable cycles : integer := 0;
        begin
            opcode <= x"F200";          -- cpGEN, D0 source
            extension_word <= x"003A";  -- FTST.L D0, validated against WinUAE opmode 0x3a
            cpu_data_in <= value;
            fpu_enable <= '1';
            wait until rising_edge(clk);
            while fpu_done = '1' and cycles < 10 loop
                wait until rising_edge(clk);
                cycles := cycles + 1;
            end loop;
            cycles := 0;
            while fpu_done /= '1' and cycles < 80 loop
                wait until rising_edge(clk);
                cycles := cycles + 1;
            end loop;
            assert fpu_done = '1'
                report "FAIL: FPU core did not complete " & label_text
                severity failure;
            assert fpu_exception = '0'
                report "FAIL: FPU core raised exception " & label_text
                severity failure;
            assert fpsr_out(27 downto 24) = expected_cc
                report "FAIL: FTST.L " & label_text & " FPSR cc mismatch"
                severity failure;
            report "PASS: FTST.L " & label_text & " updated FPSR condition codes";
            fpu_enable <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
        end procedure;

        procedure run_transcendental_disabled(
            constant label_text : in string
        ) is
            variable cycles : integer := 0;
        begin
            opcode <= x"F200";          -- cpGEN, D0 source
            extension_word <= x"000E";  -- FSIN.L D0
            cpu_data_in <= x"00000001";
            fpu_enable <= '1';
            wait until rising_edge(clk);
            while fpu_done = '1' and cycles < 10 loop
                wait until rising_edge(clk);
                cycles := cycles + 1;
            end loop;
            cycles := 0;
            while fpu_done /= '1' and cycles < 80 loop
                wait until rising_edge(clk);
                cycles := cycles + 1;
            end loop;
            assert fpu_done = '1'
                report "FAIL: FPU core did not complete disabled " & label_text
                severity failure;
            assert exception_code = x"0C"
                report "FAIL: disabled " & label_text & " did not report unimplemented instruction"
                severity failure;
            report "PASS: disabled " & label_text & " reports unimplemented instruction";
            fpu_enable <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
        end procedure;

        procedure run_alu_binary_direct(
            constant label_text : in string;
            constant op_code : in std_logic_vector(6 downto 0);
            constant operand_a : in std_logic_vector(79 downto 0);
            constant operand_b : in std_logic_vector(79 downto 0);
            constant expected_result : in std_logic_vector(79 downto 0);
            constant max_cycles : in integer
        ) is
            variable cycles : integer := 0;
        begin
            alu_operand_a <= operand_a;
            alu_operand_b <= operand_b;
            alu_operation_code <= op_code;
            alu_start_operation <= '1';
            wait until rising_edge(clk);
            alu_start_operation <= '0';

            while alu_operation_done /= '1' and cycles < max_cycles loop
                wait until rising_edge(clk);
                cycles := cycles + 1;
            end loop;
            assert alu_operation_done = '1'
                report "FAIL: ALU " & label_text & " did not complete"
                severity failure;
            assert alu_result_valid = '1'
                report "FAIL: ALU " & label_text & " did not assert result_valid"
                severity failure;
            assert alu_invalid = '0' and alu_overflow = '0' and alu_underflow = '0'
                report "FAIL: ALU " & label_text & " raised unexpected exception flag"
                severity failure;
            assert alu_result = expected_result
                report "FAIL: ALU " & label_text & " result mismatch"
                severity failure;
            report "PASS: ALU " & label_text;
            wait until rising_edge(clk);
            wait until rising_edge(clk);
        end procedure;
    begin
        wait for 40 ns;
        nReset <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        run_ftst_long(x"00000000", "0100", "zero");
        run_ftst_long(x"00000001", "0000", "positive");
        run_ftst_long(x"FFFFFFFF", "1000", "negative");
        run_transcendental_disabled("FSIN.L");
        run_alu_binary_direct("FMUL 1.5 * 1.0", "0100011",
                              x"3FFFC000000000000000", x"3FFF8000000000000000",
                              x"3FFFC000000000000000", 120);
        run_alu_binary_direct("FDIV 1.5 / 1.0", "0100000",
                              x"3FFFC000000000000000", x"3FFF8000000000000000",
                              x"3FFFC000000000000000", 140);
        run_alu_binary_direct("FSGLMUL 1.5 * 1.0", "0100111",
                              x"3FFFC000000000000000", x"3FFF8000000000000000",
                              x"3FFFC000000000000000", 120);
        run_alu_binary_direct("FSGLDIV 1.5 / 1.0", "0100100",
                              x"3FFFC000000000000000", x"3FFF8000000000000000",
                              x"3FFFC000000000000000", 140);

        test_done <= true;
        report "FPU core smoke test complete";
        wait;
    end process;
end sim;
