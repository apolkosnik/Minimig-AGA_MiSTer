`timescale 1ns / 1ps

// Simple test to verify ethernet module behavior with new sel_ethernet_shm logic
module tb_simple_eth_test;

    // Clock and reset
    reg clk;
    reg reset;
    
    // CPU interface signals  
    reg [23:1] cpu_addr;
    reg [15:0] cpu_data_in;
    wire [15:0] cpu_data_out;
    reg cpu_rd;
    reg cpu_hwr;
    reg cpu_lwr;
    reg cpu_uds;
    reg cpu_lds;
    
    // Chip selects
    reg sel_ethernet;
    reg sel_ethernet_shm;
    
    // Ethernet configuration
    reg [7:0] ethernet_base;
    
    // Memory interface
    reg [15:0] ram_data_in;
    
    // DTACK and IRQ
    wire dtack_eth;
    wire eth_irq;

    // Instantiate ethernet interface
    ethernet_interface eth_if (
        .clk(clk),
        .reset(reset),
        .cpu_addr(cpu_addr),
        .cpu_data_in(cpu_data_in),
        .cpu_data_out(cpu_data_out),
        .cpu_rd(cpu_rd),
        .cpu_hwr(cpu_hwr),
        .cpu_lwr(cpu_lwr),
        .cpu_uds(cpu_uds),
        .cpu_lds(cpu_lds),
        .sel_ethernet_shm(sel_ethernet_shm),
        .sel_ethernet(sel_ethernet),
        .ethernet_base(ethernet_base),
        .eth_irq(eth_irq),
        .dtack_eth(dtack_eth),
        .ram_data_in(ram_data_in)
    );

    // Clock generation
    always #5 clk = ~clk;
    
    // Monitor key signals
    always @(posedge clk) begin
        if (sel_ethernet || sel_ethernet_shm) begin
            $display("T=%0t: sel_eth=%b sel_eth_shm=%b addr=0x%06x rd=%b wr=%b dtack=%b", 
                     $time, sel_ethernet, sel_ethernet_shm, {cpu_addr, 1'b0}, 
                     cpu_rd, (cpu_hwr | cpu_lwr), dtack_eth);
        end
    end

    // Test sequence
    initial begin
        $display("=== Simple Ethernet Test ===");
        
        // Initialize signals
        clk = 0;
        reset = 0;
        cpu_addr = 23'h000000;
        cpu_data_in = 16'h0000;
        cpu_rd = 1;
        cpu_hwr = 1;
        cpu_lwr = 1; 
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        sel_ethernet_shm = 0;
        ethernet_base = 8'hEA;
        ram_data_in = 16'h0000;
        
        // Reset sequence
        #20 reset = 1;
        #20;
        
        $display("\n=== Test 1: Register access with sel_ethernet_shm (NEW behavior) ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00 - CR register
        sel_ethernet_shm = 1; // NEW: shared memory handles this
        sel_ethernet = 1;     // OLD: would have handled this
        cpu_rd = 0; // Read operation
        ram_data_in = 16'h2100; // Data from shared memory
        
        repeat(5) @(posedge clk); // Wait several cycles
        
        cpu_rd = 1;
        sel_ethernet = 0;
        sel_ethernet_shm = 0;
        #20;
        
        $display("\n=== Test 2: Register access with ONLY sel_ethernet (should warn) ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00 - CR register
        sel_ethernet_shm = 0; // NEW: shared memory NOT handling this
        sel_ethernet = 1;     // OLD: trying to handle this alone
        cpu_rd = 0; // Read operation
        
        repeat(5) @(posedge clk); // Wait several cycles
        
        cpu_rd = 1;
        sel_ethernet = 0;
        #20;
        
        $display("\n=== Test 3: Non-ethernet access (should be ignored) ===");
        @(negedge clk);
        cpu_addr = 23'h123456; // Non-ethernet address
        sel_ethernet_shm = 0;
        sel_ethernet = 0;
        cpu_rd = 0;
        
        repeat(3) @(posedge clk);
        
        cpu_rd = 1;
        #20;
        
        $display("\n=== Test 4: Register write with shared memory ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00 - CR register
        cpu_data_in = 16'h2200;
        sel_ethernet_shm = 1; // Shared memory handles this
        sel_ethernet = 1;     // Also active but should be ignored
        cpu_hwr = 0; // Write operation
        cpu_uds = 0; // Upper byte
        
        repeat(5) @(posedge clk);
        
        cpu_hwr = 1;
        cpu_uds = 1;
        sel_ethernet = 0;
        sel_ethernet_shm = 0;
        #20;
        
        $display("\n=== Test Results Summary ===");
        $display("Expected behavior:");
        $display("  - Test 1: dtack_eth should be HIGH (inactive) - shared memory handles it");
        $display("  - Test 2: Should see WARNING message and dtack_eth LOW (fallback)");
        $display("  - Test 3: dtack_eth should be HIGH (inactive) - not ethernet");
        $display("  - Test 4: dtack_eth should be HIGH (inactive) - shared memory handles it");
        
        $display("\n=== Test Complete ===");
        #50;
        $finish;
    end

endmodule