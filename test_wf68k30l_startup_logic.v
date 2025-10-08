// Test WF68K30L startup logic without full CPU simulation
// Verifies: reset sequence, chipram access, DSACK timeout, cchip/ckick enables

`timescale 1ns/1ps

module test_wf68k30l_startup_logic();

reg clk = 0;
reg reset = 1;
always #17.6 clk = ~clk; // 28.375 MHz

// CPU wrapper configuration
reg [1:0] cpucfg = 2'b11; // WF68K30L
reg [2:0] cachecfg = 3'b000;

// Simulate WF68K30L signals
reg        as_w = 1;      // AS inactive
reg        wr_w = 1;      // Read
reg  [1:0] size_w = 2'b11; // Longword
reg [31:0] cpu_addr = 32'h00000000;

// Chipram control signals (from cpu_wrapper logic)
reg turbochip_d = 0;
reg turbokick_d = 0;
reg dcache_d = 0;

// Calculate cpustate from AS and WR
wire [1:0] cpustate_w = as_w ? 2'b01 : (~wr_w ? 2'b11 : 2'b10);

// Calculate cchip and ckick with NEW logic
wire cchip_new = (cpucfg == 2'b11) | (turbochip_d & (!cpustate_w | dcache_d));
wire ckick_new = (cpucfg == 2'b11) | (turbokick_d & (!cpustate_w | dcache_d));

// OLD buggy logic for comparison
wire cchip_old = (turbochip_d | (cpucfg == 2'b11)) & (!cpustate_w | dcache_d);
wire ckick_old = (turbokick_d | (cpucfg == 2'b11)) & (!cpustate_w | dcache_d);

// DSACK timeout logic (not implemented in actual cpu_wrapper, just for test demonstration)
reg [3:0] dsack_timeout_counter = 0;
wire dsack_timeout = (dsack_timeout_counter == 4'd15);

always @(posedge clk) begin
    if (reset || as_w) begin
        dsack_timeout_counter <= 4'd0;
    end else if (~dsack_timeout && ~as_w) begin
        dsack_timeout_counter <= dsack_timeout_counter + 4'd1;
    end
end

// Test chipram access determination
wire sel_chipram_new = !cpu_addr[31:21] && cchip_new;
wire sel_chipram_old = !cpu_addr[31:21] && cchip_old;

integer test_num = 0;
integer pass_count = 0;
integer fail_count = 0;

task check_test;
    input integer test_id;
    input string description;
    input logic expected;
    input logic actual;
    begin
        test_num = test_num + 1;
        if (actual == expected) begin
            $display("  [PASS] Test %0d: %s", test_id, description);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Test %0d: %s (expected=%b, got=%b)",
                     test_id, description, expected, actual);
            fail_count = fail_count + 1;
        end
    end
endtask

initial begin
    $display("\n=== WF68K30L Startup Logic Tests ===\n");

    // TEST 1: Reset state
    $display("TEST 1: Reset State");
    #10;
    check_test(1, "cpustate should be IDLE (01) at reset", 1'b1, cpustate_w == 2'b01);
    check_test(2, "cchip_new should be HIGH for WF68K30L", 1'b1, cchip_new);
    check_test(3, "ckick_new should be HIGH for WF68K30L", 1'b1, ckick_new);
    check_test(4, "cchip_old is BROKEN (blocked by !cpustate)", 1'b0, cchip_old);
    check_test(5, "sel_chipram_new allows access to 0x000000", 1'b1, sel_chipram_new);
    check_test(6, "sel_chipram_old BLOCKS access (BUG!)", 1'b0, sel_chipram_old);

    // Release reset
    $display("\nTEST 2: After Reset Release");
    #20;
    reset = 0;
    #20;
    check_test(7, "cchip_new still HIGH after reset", 1'b1, cchip_new);
    check_test(8, "chipram still accessible", 1'b1, sel_chipram_new);

    // Simulate bus cycle
    $display("\nTEST 3: First Bus Cycle (Vector Fetch)");
    #20;
    as_w = 0; // Assert AS
    cpu_addr = 32'h00000000;
    wr_w = 1; // Read
    #20;
    check_test(9, "cpustate should be READ (10)", 1'b1, cpustate_w == 2'b10);
    check_test(10, "cchip_new still HIGH during read", 1'b1, cchip_new);
    check_test(11, "chipram accessible during vector fetch", 1'b1, sel_chipram_new);

    // Test DSACK timeout
    $display("\nTEST 4: DSACK Timeout Counter");
    @(posedge clk); // Wait for clock edge
    @(posedge clk); // Give counter time to increment
    check_test(12, "Counter should increment during AS active", 1'b1, dsack_timeout_counter > 0);

    // Wait for timeout (need 15 clock cycles)
    repeat(15) @(posedge clk);
    check_test(13, "Timeout should trigger after 15 cycles", 1'b1, dsack_timeout);

    // End bus cycle
    $display("\nTEST 5: Bus Cycle End");
    as_w = 1; // Deassert AS
    @(posedge clk); // Wait for register update
    @(posedge clk); // Wait one more clock for reset to take effect
    check_test(14, "Counter resets when AS deasserted", 1'b1, dsack_timeout_counter == 0);
    check_test(15, "cpustate back to IDLE", 1'b1, cpustate_w == 2'b01);

    // Test different memory regions
    $display("\nTEST 6: Address Decode");
    cpu_addr = 32'h00100000; // Still chipram
    #20;
    check_test(16, "0x100000 in chipram range", 1'b1, sel_chipram_new);

    cpu_addr = 32'h00200000; // Beyond chipram
    #20;
    check_test(17, "0x200000 outside chipram", 1'b0, sel_chipram_new);

    // Summary
    $display("\n=== Test Summary ===");
    $display("PASSED: %0d/%0d", pass_count, test_num);
    $display("FAILED: %0d/%0d", fail_count, test_num);

    if (fail_count == 0)
        $display("\n✓ All tests PASSED!");
    else
        $display("\n✗ Some tests FAILED!");

    $finish;
end

endmodule
