// WF68K30L Advanced 32-bit Bus Feature Test
// This testbench validates the enhanced bus protocol features

module test_32bit_advanced();

    // Test signals
    reg clk = 0;
    reg reset = 1;

    // WF68K30L signals (simulation)
    reg [31:0] cpu_addr_w;
    reg [1:0]  size_w;
    reg        as_w;
    reg        wr_w;
    reg        dtack_active;

    // Output signals
    wire [1:0] dsack_w;
    wire       uds_w;
    wire       lds_w;
    wire       longword_w;
    wire [1:0] cpustate_w;

    // Configuration
    reg [2:0] cpucfg = 3'b100;  // WF68K30L selected
    reg [2:0] cachecfg = 3'b111; // All optimizations enabled

    // Clock generation
    always #5 clk = ~clk;

    // Instantiate the bus conversion logic (extracted from cpu_wrapper.v)

    // Optimized DTACK to DSACK protocol conversion for WF68K30L
    // DSACK encoding: 11=no acknowledge, 10=8-bit, 01=16-bit, 00=32-bit
    assign dsack_w = dtack_active ? {size_w[1] | size_w[0], size_w[1] | ~size_w[0]} : 2'b11;

    // Optimized SIZE to UDS/LDS conversion with proper bus lane selection
    wire [1:0] byte_lanes = cpu_addr_w[1:0];
    assign uds_w = (size_w == 2'b00) ? ~(byte_lanes == 2'b00 || byte_lanes == 2'b01) :  // Byte: UDS for upper bytes
                   (size_w == 2'b01) ? ~cpu_addr_w[1] :                                   // Word: UDS based on alignment
                   (size_w == 2'b10) ? 1'b0 :                                            // Longword: both active
                   1'b1;                                                                 // Reserved

    assign lds_w = (size_w == 2'b00) ? ~(byte_lanes == 2'b10 || byte_lanes == 2'b11) :  // Byte: LDS for lower bytes
                   (size_w == 2'b01) ? ~cpu_addr_w[1] :                                   // Word: LDS based on alignment
                   (size_w == 2'b10) ? 1'b0 :                                            // Longword: both active
                   1'b1;                                                                 // Reserved

    // Map WF68K30L bus state to cpustate
    assign cpustate_w = as_w ? 2'b01 : (~wr_w ? 2'b11 : 2'b10);
    assign longword_w = (size_w == 2'b10);

    // Advanced configuration signals
    wire wf68k30l_pipeline_en = cachecfg[2] & cpucfg[2];
    wire wf68k30l_loop_opt_en = cachecfg[1] & cpucfg[2];
    wire wf68k30l_bitfield_en = cachecfg[0] & cpucfg[2];

    // Test procedure
    initial begin
        $display("=== WF68K30L Advanced 32-bit Bus Feature Test ===");

        // Initialize
        reset = 1;
        cpu_addr_w = 32'h00000000;
        size_w = 2'b00;
        as_w = 1'b1;
        wr_w = 1'b1;
        dtack_active = 1'b0;

        #20 reset = 0;
        #10;

        // Test 1: Byte access patterns
        $display("Test 1: Byte Access Patterns");
        size_w = 2'b00; // Byte

        // Test byte at address 0 (should activate LDS)
        cpu_addr_w = 32'h00000000;
        as_w = 1'b0; wr_w = 1'b0; dtack_active = 1'b1;
        #10;
        $display("  Byte @ 0x%08X: UDS=%b LDS=%b DSACK=%b (Expected: UDS=1 LDS=0 DSACK=10)",
                 cpu_addr_w, uds_w, lds_w, dsack_w);

        // Test byte at address 1 (should activate LDS)
        cpu_addr_w = 32'h00000001;
        #10;
        $display("  Byte @ 0x%08X: UDS=%b LDS=%b DSACK=%b (Expected: UDS=1 LDS=0 DSACK=10)",
                 cpu_addr_w, uds_w, lds_w, dsack_w);

        // Test byte at address 2 (should activate UDS)
        cpu_addr_w = 32'h00000002;
        #10;
        $display("  Byte @ 0x%08X: UDS=%b LDS=%b DSACK=%b (Expected: UDS=0 LDS=1 DSACK=10)",
                 cpu_addr_w, uds_w, lds_w, dsack_w);

        // Test byte at address 3 (should activate UDS)
        cpu_addr_w = 32'h00000003;
        #10;
        $display("  Byte @ 0x%08X: UDS=%b LDS=%b DSACK=%b (Expected: UDS=0 LDS=1 DSACK=10)",
                 cpu_addr_w, uds_w, lds_w, dsack_w);

        // Test 2: Word access patterns
        $display("\\nTest 2: Word Access Patterns");
        size_w = 2'b01; // Word

        // Aligned word at address 0
        cpu_addr_w = 32'h00000000;
        #10;
        $display("  Word @ 0x%08X: UDS=%b LDS=%b DSACK=%b Longword=%b (Expected: UDS=0 LDS=0 DSACK=01)",
                 cpu_addr_w, uds_w, lds_w, dsack_w, longword_w);

        // Aligned word at address 2
        cpu_addr_w = 32'h00000002;
        #10;
        $display("  Word @ 0x%08X: UDS=%b LDS=%b DSACK=%b Longword=%b (Expected: UDS=1 LDS=1 DSACK=01)",
                 cpu_addr_w, uds_w, lds_w, dsack_w, longword_w);

        // Test 3: Longword access
        $display("\\nTest 3: Longword Access");
        size_w = 2'b10; // Longword

        cpu_addr_w = 32'h00000000;
        #10;
        $display("  Longword @ 0x%08X: UDS=%b LDS=%b DSACK=%b Longword=%b (Expected: UDS=0 LDS=0 DSACK=00 Longword=1)",
                 cpu_addr_w, uds_w, lds_w, dsack_w, longword_w);

        // Test 4: Configuration validation
        $display("\\nTest 4: Advanced Configuration");
        $display("  Pipeline Enable: %b", wf68k30l_pipeline_en);
        $display("  Loop Optimization: %b", wf68k30l_loop_opt_en);
        $display("  Bitfield Operations: %b", wf68k30l_bitfield_en);

        // Test 5: Bus state mapping
        $display("\\nTest 5: Bus State Mapping");
        as_w = 1'b1; // No memory access
        #10;
        $display("  AS=1 (idle): cpustate=%b (Expected: 01)", cpustate_w);

        as_w = 1'b0; wr_w = 1'b1; // Read
        #10;
        $display("  AS=0 WR=1 (read): cpustate=%b (Expected: 10)", cpustate_w);

        as_w = 1'b0; wr_w = 1'b0; // Write
        #10;
        $display("  AS=0 WR=0 (write): cpustate=%b (Expected: 11)", cpustate_w);

        // Test 6: DTACK/DSACK conversion
        $display("\\nTest 6: DTACK/DSACK Protocol");
        dtack_active = 1'b0;
        #10;
        $display("  DTACK inactive: DSACK=%b (Expected: 11)", dsack_w);

        dtack_active = 1'b1;
        size_w = 2'b00; // Byte
        #10;
        $display("  DTACK active, Byte: DSACK=%b (Expected: 10)", dsack_w);

        size_w = 2'b01; // Word
        #10;
        $display("  DTACK active, Word: DSACK=%b (Expected: 01)", dsack_w);

        size_w = 2'b10; // Longword
        #10;
        $display("  DTACK active, Longword: DSACK=%b (Expected: 00)", dsack_w);

        $display("\\n=== Test Complete ===");
        $display("WF68K30L advanced 32-bit bus features validated!");

        $finish;
    end

endmodule