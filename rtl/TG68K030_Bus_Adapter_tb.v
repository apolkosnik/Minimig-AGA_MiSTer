`timescale 1ns / 1ps
//============================================================================
// TG68K030_Bus_Adapter Testbench
//
// Validates the 32-bit to 16-bit bus width adapter, particularly:
// - DTACK handshaking protocol compliance
// - Long word split transfers
// - Byte/word single transfers
// - UDS/LDS generation
//
// Author: Claude (Anthropic)
// Date: 2025-11-12
//============================================================================

module TG68K030_Bus_Adapter_tb;

    //------------------------------------------------------------------------
    // Clock and Reset
    //------------------------------------------------------------------------
    reg clk;
    reg reset;

    //------------------------------------------------------------------------
    // CPU Side (32-bit)
    //------------------------------------------------------------------------
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_data_write;
    wire [31:0] cpu_data_read;
    reg         cpu_as;
    reg         cpu_write;
    reg   [1:0] cpu_size;  // 00=byte, 01=word, 10=long
    wire        cpu_dtack;

    //------------------------------------------------------------------------
    // System Side (16-bit)
    //------------------------------------------------------------------------
    wire [31:0] sys_addr;
    wire [15:0] sys_data_write;
    reg  [15:0] sys_data_read;
    wire        sys_as;
    wire        sys_uds;
    wire        sys_lds;
    wire        sys_write;
    wire        sys_dtack;

    //------------------------------------------------------------------------
    // Device Under Test
    //------------------------------------------------------------------------
    TG68K030_Bus_Adapter dut (
        .clk(clk),
        .reset(reset),

        // CPU side
        .cpu_addr(cpu_addr),
        .cpu_data_write(cpu_data_write),
        .cpu_data_read(cpu_data_read),
        .cpu_as(cpu_as),
        .cpu_write(cpu_write),
        .cpu_size(cpu_size),
        .cpu_dtack(cpu_dtack),

        // System side
        .sys_addr(sys_addr),
        .sys_data_write(sys_data_write),
        .sys_data_read(sys_data_read),
        .sys_as(sys_as),
        .sys_uds(sys_uds),
        .sys_lds(sys_lds),
        .sys_write(sys_write),
        .sys_dtack(sys_dtack)
    );

    //------------------------------------------------------------------------
    // System Bus Simulator
    //------------------------------------------------------------------------
    reg [15:0] memory_upper;  // Simulated memory for upper word
    reg [15:0] memory_lower;  // Simulated memory for lower word
    reg [2:0] dtack_delay;    // Cycles to delay dtack response

    // System bus DTACK generator with realistic delay
    reg sys_dtack_reg;
    assign sys_dtack = sys_dtack_reg;

    reg [2:0] dtack_counter;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sys_dtack_reg <= 1'b1;  // Idle high
            dtack_counter <= 3'd0;
        end else begin
            if (sys_as == 1'b0) begin
                // AS asserted, count delay
                if (dtack_counter < dtack_delay) begin
                    dtack_counter <= dtack_counter + 3'd1;
                    sys_dtack_reg <= 1'b1;  // Not ready yet
                end else begin
                    sys_dtack_reg <= 1'b0;  // Ready!

                    // Simulate memory read
                    if (~sys_write) begin
                        if (sys_addr[1:0] == 2'b00) begin
                            sys_data_read <= memory_upper;
                        end else begin
                            sys_data_read <= memory_lower;
                        end
                    end

                    // Simulate memory write
                    if (sys_write) begin
                        if (sys_addr[1:0] == 2'b00) begin
                            if (sys_uds == 1'b0) memory_upper[15:8] <= sys_data_write[15:8];
                            if (sys_lds == 1'b0) memory_upper[7:0] <= sys_data_write[7:0];
                        end else begin
                            if (sys_uds == 1'b0) memory_lower[15:8] <= sys_data_write[15:8];
                            if (sys_lds == 1'b0) memory_lower[7:0] <= sys_data_write[7:0];
                        end
                    end
                end
            end else begin
                // AS deasserted, return to idle
                sys_dtack_reg <= 1'b1;
                dtack_counter <= 3'd0;
            end
        end
    end

    //------------------------------------------------------------------------
    // Clock Generator (50 MHz = 20ns period)
    //------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #10 clk = ~clk;
    end

    //------------------------------------------------------------------------
    // Test Monitoring
    //------------------------------------------------------------------------
    integer test_num;
    integer errors;

    task report_test;
        input [200*8-1:0] test_name;
        input pass;
    begin
        if (pass) begin
            $display("[PASS] Test %0d: %0s", test_num, test_name);
        end else begin
            $display("[FAIL] Test %0d: %0s", test_num, test_name);
            errors = errors + 1;
        end
        test_num = test_num + 1;
    end
    endtask

    //------------------------------------------------------------------------
    // CPU Bus Cycle Tasks
    //------------------------------------------------------------------------

    // Read byte from address
    task cpu_read_byte;
        input [31:0] addr;
        output [7:0] data;
    begin
        @(posedge clk);
        #1;
        cpu_addr <= addr;
        cpu_size <= 2'b00;  // Byte
        cpu_write <= 1'b0;
        cpu_as <= 1'b0;

        // Wait for DTACK
        wait(cpu_dtack == 1'b0);
        @(posedge clk);

        // Read data based on byte position
        case (addr[1:0])
            2'b00: data = cpu_data_read[31:24];
            2'b01: data = cpu_data_read[23:16];
            2'b10: data = cpu_data_read[15:8];
            2'b11: data = cpu_data_read[7:0];
        endcase

        #1;
        cpu_as <= 1'b1;

        // Wait for DTACK to go high
        wait(cpu_dtack == 1'b1);
        @(posedge clk);
    end
    endtask

    // Read word from address
    task cpu_read_word;
        input [31:0] addr;
        output [15:0] data;
    begin
        @(posedge clk);
        #1;
        cpu_addr <= addr;
        cpu_size <= 2'b01;  // Word
        cpu_write <= 1'b0;
        cpu_as <= 1'b0;

        // Wait for DTACK
        wait(cpu_dtack == 1'b0);
        @(posedge clk);

        // Read data based on word position
        if (addr[1] == 1'b0)
            data = cpu_data_read[31:16];
        else
            data = cpu_data_read[15:0];

        #1;
        cpu_as <= 1'b1;

        // Wait for DTACK to go high
        wait(cpu_dtack == 1'b1);
        @(posedge clk);
    end
    endtask

    // Read long word from address
    task cpu_read_long;
        input [31:0] addr;
        output [31:0] data;
    begin
        @(posedge clk);
        #1;
        cpu_addr <= addr;
        cpu_size <= 2'b10;  // Long
        cpu_write <= 1'b0;
        cpu_as <= 1'b0;

        // Wait for DTACK
        wait(cpu_dtack == 1'b0);
        @(posedge clk);

        data = cpu_data_read;

        #1;
        cpu_as <= 1'b1;

        // Wait for DTACK to go high
        wait(cpu_dtack == 1'b1);
        @(posedge clk);
    end
    endtask

    // Write long word to address
    task cpu_write_long;
        input [31:0] addr;
        input [31:0] data;
    begin
        @(posedge clk);
        #1;
        cpu_addr <= addr;
        cpu_data_write <= data;
        cpu_size <= 2'b10;  // Long
        cpu_write <= 1'b1;
        cpu_as <= 1'b0;

        // Wait for DTACK
        wait(cpu_dtack == 1'b0);
        @(posedge clk);

        #1;
        cpu_as <= 1'b1;

        // Wait for DTACK to go high
        wait(cpu_dtack == 1'b1);
        @(posedge clk);
    end
    endtask

    //------------------------------------------------------------------------
    // Main Test Sequence
    //------------------------------------------------------------------------
    reg [31:0] read_data;
    reg [15:0] read_word;
    reg [7:0] read_byte;

    initial begin
        $display("=================================================================");
        $display("TG68K030_Bus_Adapter Testbench");
        $display("Testing DTACK handshaking and bus width conversion");
        $display("=================================================================");

        // Initialize
        test_num = 1;
        errors = 0;

        clk = 0;
        reset = 1;
        cpu_addr = 32'h0;
        cpu_data_write = 32'h0;
        cpu_as = 1'b1;
        cpu_write = 1'b0;
        cpu_size = 2'b00;
        sys_data_read = 16'h0;

        // Reset memory
        memory_upper = 16'hDEAD;
        memory_lower = 16'hBEEF;
        dtack_delay = 3'd2;  // 2 cycle delay

        // Release reset
        #100;
        reset = 0;
        #100;

        //--------------------------------------------------------------------
        // Test 1: Long Word Read - Verify DTACK Handshaking
        //--------------------------------------------------------------------
        $display("\n--- Test 1: Long Word Read (DTACK handshaking) ---");
        cpu_read_long(32'h00001000, read_data);
        report_test("Long word read returned data", read_data == 32'hDEADBEEF);

        //--------------------------------------------------------------------
        // Test 2: Long Word Write - Verify Split Transfer
        //--------------------------------------------------------------------
        $display("\n--- Test 2: Long Word Write (split transfer) ---");
        memory_upper = 16'h0000;
        memory_lower = 16'h0000;
        cpu_write_long(32'h00001000, 32'h12345678);
        report_test("Long word write upper", memory_upper == 16'h1234);
        report_test("Long word write lower", memory_lower == 16'h5678);

        //--------------------------------------------------------------------
        // Test 3: Word Read
        //--------------------------------------------------------------------
        $display("\n--- Test 3: Word Read ---");
        memory_upper = 16'hABCD;
        cpu_read_word(32'h00002000, read_word);
        report_test("Word read", read_word == 16'hABCD);

        //--------------------------------------------------------------------
        // Test 4: Byte Read
        //--------------------------------------------------------------------
        $display("\n--- Test 4: Byte Read ---");
        memory_upper = 16'h4321;
        cpu_read_byte(32'h00003000, read_byte);
        report_test("Byte read (upper byte)", read_byte == 8'h43);

        //--------------------------------------------------------------------
        // Test 5: DTACK Timing - Verify Wait State
        //--------------------------------------------------------------------
        $display("\n--- Test 5: DTACK Timing (wait states) ---");
        dtack_delay = 3'd5;  // 5 cycle delay
        memory_upper = 16'hFACE;
        memory_lower = 16'hCAFE;
        cpu_read_long(32'h00004000, read_data);
        report_test("Long word read with wait states", read_data == 32'hFACECAFE);

        //--------------------------------------------------------------------
        // Test 6: Back-to-back Transfers
        //--------------------------------------------------------------------
        $display("\n--- Test 6: Back-to-back Transfers ---");
        dtack_delay = 3'd1;
        memory_upper = 16'h1111;
        memory_lower = 16'h2222;
        cpu_read_long(32'h00005000, read_data);
        report_test("First transfer", read_data == 32'h11112222);

        memory_upper = 16'h3333;
        memory_lower = 16'h4444;
        cpu_read_long(32'h00005004, read_data);
        report_test("Second transfer", read_data == 32'h33334444);

        //--------------------------------------------------------------------
        // Test 7: UDS/LDS Verification
        //--------------------------------------------------------------------
        $display("\n--- Test 7: UDS/LDS Signal Generation ---");
        // This test monitors UDS/LDS during a long word write
        memory_upper = 16'h0000;
        memory_lower = 16'h0000;

        fork
            begin
                cpu_write_long(32'h00006000, 32'hAABBCCDD);
            end
            begin
                // Monitor first cycle (upper word)
                wait(sys_as == 1'b0 && sys_addr[1:0] == 2'b00);
                @(posedge clk);
                #1;
                if (sys_uds == 1'b0 && sys_lds == 1'b0)
                    $display("  Upper word: UDS=%b LDS=%b (both asserted) ✓", sys_uds, sys_lds);

                // Monitor second cycle (lower word)
                wait(sys_as == 1'b0 && sys_addr[1:0] == 2'b10);
                @(posedge clk);
                #1;
                if (sys_uds == 1'b0 && sys_lds == 1'b0)
                    $display("  Lower word: UDS=%b LDS=%b (both asserted) ✓", sys_uds, sys_lds);
            end
        join

        report_test("UDS/LDS generation", memory_upper == 16'hAABB && memory_lower == 16'hCCDD);

        //--------------------------------------------------------------------
        // Results
        //--------------------------------------------------------------------
        #100;
        $display("\n=================================================================");
        if (errors == 0) begin
            $display("ALL TESTS PASSED! (%0d tests)", test_num - 1);
            $display("Bus adapter is functioning correctly.");
        end else begin
            $display("TESTS FAILED: %0d error(s) in %0d tests", errors, test_num - 1);
        end
        $display("=================================================================");

        #100;
        $finish;
    end

    //------------------------------------------------------------------------
    // Waveform Dump
    //------------------------------------------------------------------------
    initial begin
        $dumpfile("TG68K030_Bus_Adapter_tb.vcd");
        $dumpvars(0, TG68K030_Bus_Adapter_tb);
    end

    //------------------------------------------------------------------------
    // Timeout Watchdog
    //------------------------------------------------------------------------
    initial begin
        #100000;  // 100 microseconds
        $display("\n*** ERROR: Testbench timeout! ***");
        $finish;
    end

endmodule
