`timescale 1ns/1ps

// WF68K30L Boot Test - Tests actual WF68K30L core startup
// Focus: Identify why the CPU isn't booting

module test_wf68k30l_boot();

    // Clock and reset
    reg clk = 0;
    reg reset = 1;

    // Clock: 50MHz (20ns period)
    always #10 clk = ~clk;

    // CPU signals from WF68K30L
    wire [31:0] cpu_addr;
    wire [31:0] cpu_data_out;
    reg  [31:0] cpu_data_in;
    wire [1:0]  size;
    wire        as_n;
    wire        rw_n;
    wire        ds_n;
    wire [2:0]  fc;
    wire        reset_out;
    reg  [1:0]  dsack_n;

    // Test control
    integer cycle_count = 0;
    integer vector_fetches = 0;
    reg test_failed = 0;

    // Simple memory model for reset vectors
    reg [31:0] memory [0:1023];

    initial begin
        // Setup reset vectors at address 0
        memory[0] = 32'h00001000;  // Initial SSP = 0x00001000
        memory[1] = 32'h00000400;  // Initial PC  = 0x00000400

        // Put a NOP at PC location
        memory[256] = 32'h4E714E71;  // NOP NOP
        memory[257] = 32'h4E714E71;  // NOP NOP
    end

    // Instantiate WF68K30L
    WF68K30L_TOP cpu (
        .CLK(clk),
        .ADR_OUT(cpu_addr),
        .DATA_IN(cpu_data_in),
        .DATA_OUT(cpu_data_out),
        .DATA_EN(),

        .BERRn(1'b1),
        .RESET_INn(~reset),
        .RESET_OUT(reset_out),
        .HALT_INn(~reset),  // HALT must be asserted during reset
        .HALT_OUTn(),

        .FC_OUT(fc),

        .AVECn(1'b1),
        .IPLn(3'b111),
        .IPENDn(),

        .DSACKn(dsack_n),
        .SIZE(size),
        .ASn(as_n),
        .RWn(rw_n),
        .RMCn(),
        .DSn(ds_n),
        .ECSn(),
        .OCSn(),
        .DBENn(),
        .BUS_EN(),

        .STERMn(1'b1),
        .STATUSn(),
        .REFILLn(),

        .BRn(1'b1),
        .BGn(),
        .BGACKn(1'b1)
    );

    // Memory access handler with DSACK protocol
    reg [3:0] access_delay;
    reg mem_active = 0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            dsack_n <= 2'b11;
            cpu_data_in <= 32'h00000000;
            access_delay <= 0;
            mem_active <= 0;
        end
        else begin
            // Detect new bus cycle (AS asserted)
            if (!as_n && !mem_active) begin
                mem_active <= 1;
                access_delay <= 3;  // 3 cycle delay
                dsack_n <= 2'b11;   // Not ready
                $display("TIME %0t: BUS CYCLE - ADDR=0x%08X SIZE=%b RW=%b FC=%b",
                         $time, cpu_addr, size, rw_n, fc);
            end

            // Handle memory timing
            if (mem_active) begin
                if (access_delay > 0) begin
                    access_delay <= access_delay - 1;
                end
                else begin
                    // Memory ready - provide data
                    if (rw_n) begin  // Read
                        cpu_data_in <= memory[cpu_addr[11:2]];
                        $display("TIME %0t: READ DATA - ADDR=0x%08X DATA=0x%08X",
                                 $time, cpu_addr, memory[cpu_addr[11:2]]);
                    end

                    // Assert DSACK based on SIZE
                    case (size)
                        2'b00: dsack_n <= 2'b10;  // Byte - 8-bit port
                        2'b01: dsack_n <= 2'b01;  // Word - 16-bit port
                        2'b10: dsack_n <= 2'b01;  // 3-byte/Line - treat as word for simple test
                        2'b11: dsack_n <= 2'b00;  // Longword - 32-bit port
                        default: dsack_n <= 2'b11;
                    endcase
                end
            end

            // Clear when AS released
            if (as_n) begin
                dsack_n <= 2'b11;
                mem_active <= 0;
                access_delay <= 0;
            end
        end
    end

    // Monitor and check boot sequence
    reg prev_as_n = 1;

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        prev_as_n <= as_n;

        // Detect bus cycles
        if (prev_as_n && !as_n) begin
            vector_fetches <= vector_fetches + 1;

            // Check for expected boot sequence
            if (vector_fetches == 0 && cpu_addr != 32'h00000000) begin
                $display("ERROR: First fetch should be from 0x00000000, got 0x%08X", cpu_addr);
                test_failed = 1;
            end

            if (vector_fetches == 1 && cpu_addr != 32'h00000004) begin
                $display("ERROR: Second fetch should be from 0x00000004, got 0x%08X", cpu_addr);
                test_failed = 1;
            end
        end

        // Success check
        if (vector_fetches >= 3 && !test_failed) begin
            $display("\n=== BOOT TEST PASSED ===");
            $display("CPU successfully fetched reset vectors and started execution");
            $display("Vector fetches: %0d", vector_fetches);
            $finish;
        end

        // Timeout
        if (cycle_count > 1000) begin
            $display("\n=== BOOT TEST FAILED - TIMEOUT ===");
            $display("Vector fetches: %0d", vector_fetches);
            $display("CPU appears stuck or not starting");
            test_failed = 1;
            $finish;
        end
    end

    // Test sequence
    initial begin
        $display("=== WF68K30L Boot Test ===");
        $display("Testing actual WF68K30L core boot sequence\n");

        // Hold reset for 100 cycles
        reset = 1;
        #2000;

        $display("TIME %0t: Releasing reset", $time);
        reset = 0;

        // Let it run
        #20000;

        if (!test_failed && vector_fetches < 3) begin
            $display("\n=== BOOT TEST INCOMPLETE ===");
            $display("Vector fetches: %0d (expected >= 3)", vector_fetches);
        end

        $finish;
    end

    // Waveform dump
    initial begin
        $dumpfile("wf68k30l_boot.vcd");
        $dumpvars(0, test_wf68k30l_boot);
    end

endmodule
