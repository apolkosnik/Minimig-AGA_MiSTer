`timescale 1ns / 1ps

// Focused test to verify WARNING message appears
module tb_warning_test;

    reg clk = 0;
    reg reset = 1;
    reg [23:1] cpu_addr;
    reg [15:0] cpu_data_in;
    wire [15:0] cpu_data_out;
    reg cpu_rd, cpu_hwr, cpu_lwr, cpu_uds, cpu_lds;
    reg sel_ethernet, sel_ethernet_shm;
    reg [7:0] ethernet_base = 8'hEA;
    reg [15:0] ram_data_in = 16'h0000;
    wire dtack_eth, eth_irq;

    // Instantiate ethernet interface
    ethernet_interface eth_if (
        .clk(clk), .reset(reset), .cpu_addr(cpu_addr), .cpu_data_in(cpu_data_in),
        .cpu_data_out(cpu_data_out), .cpu_rd(cpu_rd), .cpu_hwr(cpu_hwr), .cpu_lwr(cpu_lwr),
        .cpu_uds(cpu_uds), .cpu_lds(cpu_lds), .sel_ethernet_shm(sel_ethernet_shm),
        .sel_ethernet(sel_ethernet), .ethernet_base(ethernet_base),
        .eth_irq(eth_irq), .dtack_eth(dtack_eth), .ram_data_in(ram_data_in)
    );

    always #5 clk = ~clk;

    initial begin
        $display("=== WARNING Test ===");
        
        // Initialize - inactive state
        cpu_addr = 23'h000000;
        cpu_data_in = 16'h0000;
        cpu_rd = 1; cpu_hwr = 1; cpu_lwr = 1; cpu_uds = 1; cpu_lds = 1;
        sel_ethernet = 0; sel_ethernet_shm = 0;
        
        #30 reset = 0; #10 reset = 1; #20;
        
        $display("\nTest: sel_ethernet=1, sel_ethernet_shm=0, with READ");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00
        sel_ethernet = 1;
        sel_ethernet_shm = 0;
        cpu_rd = 0; // Active READ
        cpu_hwr = 1; cpu_lwr = 1; // No write
        
        @(posedge clk);
        $display("  dtack_eth = %b (should be 0 = ready)", dtack_eth);
        
        @(posedge clk);
        cpu_rd = 1; sel_ethernet = 0; // Deactivate
        #20;
        
        $display("\nTest: sel_ethernet=1, sel_ethernet_shm=0, with WRITE");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00
        sel_ethernet = 1;
        sel_ethernet_shm = 0; 
        cpu_rd = 1; // No read
        cpu_hwr = 0; cpu_uds = 0; // Active WRITE
        
        @(posedge clk);
        $display("  dtack_eth = %b (should be 0 = ready)", dtack_eth);
        
        @(posedge clk);
        cpu_hwr = 1; cpu_uds = 1; sel_ethernet = 0; // Deactivate
        #20;
        
        $display("\nTest: NORMAL case - sel_ethernet=1, sel_ethernet_shm=1");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00
        sel_ethernet = 1;
        sel_ethernet_shm = 1; // Shared memory active
        cpu_rd = 0; // Active READ
        
        @(posedge clk);
        $display("  dtack_eth = %b (should be 1 = inactive)", dtack_eth);
        
        @(posedge clk);
        cpu_rd = 1; sel_ethernet = 0; sel_ethernet_shm = 0;
        #20;
        
        $display("\n=== End Test ===");
        $finish;
    end

endmodule