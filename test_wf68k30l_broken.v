// WF68K30L Power-On Sequence Testbench - BROKEN VERSION
// Demonstrates the startup failure with the original incorrect SIZE signal interpretation
// This shows what happens with the buggy code before my fixes

`timescale 1ns/1ps

module test_wf68k30l_broken();

    // Basic test signals
    reg clk = 0;
    reg reset = 1;
    reg [2:0] cpucfg = 3'b100;     // WF68K30L selected (cpucfg[2] = 1)
    reg [2:0] cachecfg = 3'b000;   // No cache optimizations for testing
    reg [2:0] chip_ipl = 3'b111;   // No interrupts during startup

    // Clock generation - 50MHz system clock
    always #10 clk = ~clk;

    // Memory model for reset vector area (0x00000000 - 0x0000001F)
    reg [31:0] reset_memory [0:7];

    // CPU interface signals (from cpu_wrapper.v)
    wire [31:0] cpu_addr_w;
    wire [31:0] cpu_dout_w;
    reg  [31:0] cpu_din;
    wire [1:0]  size_w;
    wire        as_w;
    wire        wr_w;
    wire        ds_w;
    wire        rmc_w;
    wire [2:0]  fc_w;
    wire        reset_out_w;

    // Bus protocol signals
    wire [1:0]  dsack_w;
    wire        uds_w;
    wire        lds_w;
    wire        longword_w;
    wire [1:0]  cpustate_w;

    // Memory access control
    reg         dtack_active = 0;
    reg         mem_access_pending = 0;
    reg [3:0]   access_delay_counter = 0;

    // Test control
    integer     cycle_count = 0;
    integer     reset_vector_fetches = 0;
    reg         test_passed = 0;
    reg         test_failed = 0;

    //=================================================================
    // BROKEN WF68K30L bus conversion logic (ORIGINAL BUGGY CODE!)
    //=================================================================

    // BROKEN DSACK generation for WF68K30L (incorrect SIZE handling)
    // This was the original broken formula that caused startup failures
    assign dsack_w = dtack_active ? {size_w[1] | size_w[0], size_w[1] | ~size_w[0]} : 2'b11;

    // BROKEN SIZE to UDS/LDS conversion (incorrect longword detection)
    wire [1:0] byte_lanes = cpu_addr_w[1:0];
    assign uds_w = (size_w == 2'b00) ? ~(byte_lanes == 2'b00 || byte_lanes == 2'b01) :  // Byte: UDS for upper bytes
                   (size_w == 2'b01) ? ~cpu_addr_w[1] :                                   // Word: UDS based on alignment
                   (size_w == 2'b10) ? 1'b0 :                                            // BROKEN: Should be 2'b11!
                   1'b1;                                                                 // Reserved

    assign lds_w = (size_w == 2'b00) ? ~(byte_lanes == 2'b10 || byte_lanes == 2'b11) :  // Byte: LDS for lower bytes
                   (size_w == 2'b01) ? ~cpu_addr_w[1] :                                   // Word: LDS based on alignment
                   (size_w == 2'b10) ? 1'b0 :                                            // BROKEN: Should be 2'b11!
                   1'b1;                                                                 // Reserved

    // Map WF68K30L bus state to cpustate (invert AS since WF68K30L uses active low)
    assign cpustate_w = as_w ? 2'b01 : (~wr_w ? 2'b11 : 2'b10);
    assign longword_w = (size_w == 2'b10);  // BROKEN: Should be 2'b11!

    //=================================================================
    // Mock WF68K30L CPU Core - Behavioral Model
    //=================================================================

    reg [31:0] mock_addr;
    reg [1:0]  mock_size;
    reg        mock_as;
    reg        mock_rw;
    reg        mock_ds;
    reg        mock_rmc;
    reg [2:0]  mock_fc;
    reg [31:0] mock_dout;
    reg        mock_reset_out;

    // State machine for MC68030 startup sequence
    reg [3:0] cpu_state;
    parameter
        CPU_RESET       = 4'h0,
        CPU_FETCH_SSP_H = 4'h1,  // Fetch high word of initial SSP from 0x000000
        CPU_FETCH_SSP_L = 4'h2,  // Fetch low word of initial SSP from 0x000002
        CPU_FETCH_PC_H  = 4'h3,  // Fetch high word of initial PC from 0x000004
        CPU_FETCH_PC_L  = 4'h4,  // Fetch low word of initial PC from 0x000006
        CPU_RUNNING     = 4'h5,  // Normal operation
        CPU_FAILED      = 4'hF;  // Failed startup

    reg [31:0] initial_ssp, initial_pc;
    reg [7:0]  bus_timeout_counter;

    // Assign mock CPU outputs to testbench wires
    assign cpu_addr_w = mock_addr;
    assign size_w = mock_size;
    assign as_w = mock_as;
    assign wr_w = mock_rw;
    assign ds_w = mock_ds;
    assign rmc_w = mock_rmc;
    assign fc_w = mock_fc;
    assign cpu_dout_w = mock_dout;
    assign reset_out_w = mock_reset_out;

    //=================================================================
    // Initialize reset vector memory
    //=================================================================
    initial begin
        // Set up realistic reset vectors for Amiga
        reset_memory[0] = 32'h00080000;  // Initial SSP = 512KB
        reset_memory[1] = 32'h00F80000;  // Initial PC = ROM start
        reset_memory[2] = 32'h00000000;  // Unused
        reset_memory[3] = 32'h00000000;  // Unused
        reset_memory[4] = 32'h00000000;  // Unused
        reset_memory[5] = 32'h00000000;  // Unused
        reset_memory[6] = 32'h00000000;  // Unused
        reset_memory[7] = 32'h00000000;  // Unused
    end

    //=================================================================
    // Mock WF68K30L CPU Behavior
    //=================================================================
    always @(posedge clk) begin
        if (reset) begin
            // Reset state
            cpu_state <= CPU_RESET;
            mock_addr <= 32'h00000000;
            mock_size <= 2'b00;
            mock_as <= 1'b1;      // Inactive (active low)
            mock_rw <= 1'b1;      // Read
            mock_ds <= 1'b1;      // Inactive
            mock_rmc <= 1'b1;     // Inactive
            mock_fc <= 3'b110;    // Supervisor data
            mock_dout <= 32'h00000000;
            mock_reset_out <= 1'b0;  // Assert reset output
            initial_ssp <= 32'h00000000;
            initial_pc <= 32'h00000000;
            bus_timeout_counter <= 8'h00;
        end
        else begin
            case (cpu_state)
                CPU_RESET: begin
                    // Coming out of reset - start fetching reset vectors
                    mock_reset_out <= 1'b1;  // Release reset output
                    cpu_state <= CPU_FETCH_SSP_H;
                    bus_timeout_counter <= 8'h00;
                end

                CPU_FETCH_SSP_H: begin
                    // Fetch initial SSP (32-bit read from 0x000000)
                    mock_addr <= 32'h00000000;
                    mock_size <= 2'b11;      // 32-bit longword (WILL FAIL WITH BROKEN CODE!)
                    mock_as <= 1'b0;         // Assert address strobe
                    mock_rw <= 1'b1;         // Read operation
                    mock_ds <= 1'b0;         // Assert data strobe
                    mock_fc <= 3'b110;       // Supervisor data access

                    // Wait for DSACK response
                    if (dsack_w != 2'b11) begin
                        // Got acknowledgment - capture data
                        initial_ssp <= cpu_din;
                        mock_as <= 1'b1;         // Deassert strobes
                        mock_ds <= 1'b1;
                        cpu_state <= CPU_FETCH_PC_H;
                        reset_vector_fetches <= reset_vector_fetches + 1;
                        $display("TIME %0t: SSP fetch successful: 0x%08X", $time, cpu_din);
                    end
                    else begin
                        bus_timeout_counter <= bus_timeout_counter + 1;
                        if (bus_timeout_counter > 100) begin
                            $display("TIME %0t: ERROR - SSP fetch timeout! DSACK=%b SIZE=%b", $time, dsack_w, size_w);
                            $display("TIME %0t: BROKEN SIZE INTERPRETATION - SIZE=11 should generate DSACK=00 but got DSACK=%b", $time, dsack_w);
                            cpu_state <= CPU_FAILED;
                            test_failed <= 1;
                        end
                    end
                end

                CPU_FETCH_PC_H: begin
                    // This will never be reached with broken code
                    cpu_state <= CPU_FAILED;
                    test_failed <= 1;
                end

                CPU_RUNNING: begin
                    // This will never be reached with broken code
                    mock_as <= 1'b1;
                    mock_ds <= 1'b1;
                end

                CPU_FAILED: begin
                    // Startup failed - stay in failed state
                    mock_as <= 1'b1;
                    mock_ds <= 1'b1;
                end
            endcase
        end
    end

    //=================================================================
    // Memory Model with Realistic Timing
    //=================================================================
    always @(posedge clk) begin
        if (reset) begin
            dtack_active <= 0;
            mem_access_pending <= 0;
            access_delay_counter <= 0;
            cpu_din <= 32'h00000000;
        end
        else begin
            // Detect memory access request
            if (!as_w && !mem_access_pending) begin
                mem_access_pending <= 1;
                access_delay_counter <= 4;  // 4 cycle memory latency
                dtack_active <= 0;
                $display("TIME %0t: Memory access started - ADDR=0x%08X SIZE=%b", $time, cpu_addr_w, size_w);
            end

            // Handle memory access timing
            if (mem_access_pending) begin
                if (access_delay_counter > 0) begin
                    access_delay_counter <= access_delay_counter - 1;
                end
                else begin
                    // Memory access ready - provide data and assert DTACK
                    if (cpu_addr_w >= 32'h00000000 && cpu_addr_w < 32'h00000020) begin
                        // Reset vector area
                        case (cpu_addr_w[4:2])
                            3'b000: cpu_din <= reset_memory[0];  // 0x000000-0x000003
                            3'b001: cpu_din <= reset_memory[1];  // 0x000004-0x000007
                            3'b010: cpu_din <= reset_memory[2];  // 0x000008-0x00000B
                            3'b011: cpu_din <= reset_memory[3];  // 0x00000C-0x00000F
                            3'b100: cpu_din <= reset_memory[4];  // 0x000010-0x000013
                            3'b101: cpu_din <= reset_memory[5];  // 0x000014-0x000017
                            3'b110: cpu_din <= reset_memory[6];  // 0x000018-0x00001B
                            3'b111: cpu_din <= reset_memory[7];  // 0x00001C-0x00001F
                        endcase
                        dtack_active <= 1;
                        $display("TIME %0t: Memory data ready - DATA=0x%08X DSACK=%b (BROKEN!)", $time, cpu_din, dsack_w);
                    end
                    else begin
                        // Invalid address
                        cpu_din <= 32'hDEADBEEF;
                        dtack_active <= 1;
                        $display("TIME %0t: Invalid memory access - ADDR=0x%08X", $time, cpu_addr_w);
                    end
                end
            end

            // Clear DTACK when AS is deasserted
            if (as_w) begin
                dtack_active <= 0;
                mem_access_pending <= 0;
                access_delay_counter <= 0;
            end
        end
    end

    //=================================================================
    // Test Control and Monitoring
    //=================================================================
    reg        prev_as_w;
    reg [1:0]  prev_size_w;
    reg [1:0]  prev_dsack_w;

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;

        // Display critical signals on changes
        if (!reset && cycle_count > 0) begin
            if (as_w != prev_as_w || size_w != prev_size_w || dsack_w != prev_dsack_w) begin
                $display("TIME %0t: BUS ACTIVITY - AS=%b SIZE=%b UDS=%b LDS=%b DSACK=%b LONGWORD=%b (BROKEN!)",
                        $time, as_w, size_w, uds_w, lds_w, dsack_w, longword_w);
            end
        end

        // Store previous values
        prev_as_w <= as_w;
        prev_size_w <= size_w;
        prev_dsack_w <= dsack_w;
    end

    //=================================================================
    // Main Test Sequence
    //=================================================================
    initial begin
        $display("=================================================================");
        $display("WF68K30L Power-On Sequence Test - BROKEN VERSION");
        $display("Demonstrating the startup failure with incorrect SIZE interpretation");
        $display("=================================================================");

        // Generate VCD file for waveform analysis
        $dumpfile("wf68k30l_broken.vcd");
        $dumpvars(0, test_wf68k30l_broken);

        // Initial reset period
        reset = 1;
        #200;

        $display("TIME %0t: Releasing reset...", $time);
        reset = 0;

        // Wait for startup completion or timeout
        wait (test_passed || test_failed || cycle_count > 5000);

        #100; // Allow final transactions to complete

        // Test Results
        $display("=================================================================");
        $display("TEST RESULTS - BROKEN VERSION:");
        $display("=================================================================");
        if (test_passed) begin
            $display("UNEXPECTED: Test passed - this should have failed!");
        end
        else if (test_failed) begin
            $display("EXPECTED FAILURE: WF68K30L startup failed as expected!");
            $display("  - CPU State: %0d", cpu_state);
            $display("  - Reset vector fetches: %0d", reset_vector_fetches);
            $display("  - Last DSACK value: %b", dsack_w);
            $display("  - Last SIZE value: %b", size_w);
            $display("  - ROOT CAUSE: SIZE=11 (longword) incorrectly treated as SIZE=10 (3-byte)");
            $display("  - EXPLANATION: The broken formula generates wrong DSACK for 32-bit transfers");
            $display("  - SOLUTION: Fix SIZE signal interpretation to use 2'b11 for longword detection");
        end
        else begin
            $display("TIMEOUT: Test timed out after %0d cycles", cycle_count);
            $display("  - CPU State: %0d", cpu_state);
            $display("  - This indicates a protocol deadlock");
        end
        $display("=================================================================");

        $finish;
    end

    // Timeout safety
    initial begin
        #100000;  // 100µs timeout
        $display("EMERGENCY TIMEOUT: Test exceeded maximum time limit");
        $finish;
    end

endmodule