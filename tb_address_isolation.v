`timescale 1ns / 1ps

module tb_address_isolation;

    // Inputs
    reg clk;
    reg reset;
    reg [23:1] cpu_addr;
    reg [15:0] cpu_data_in;
    reg cpu_rd;
    reg cpu_hwr;
    reg cpu_lwr;
    reg cpu_uds;
    reg cpu_lds;
    reg sel_ethernet_shm;
    reg sel_ethernet;
    reg [7:0] ethernet_base;
    reg [15:0] ram_data_in;

    // Outputs
    wire [15:0] cpu_data_out;
    wire [23:1] cpu_addr_out;
    wire addr_override;
    wire eth_irq;
    wire dtack_eth;

    // Instantiate the Unit Under Test (UUT)
    ethernet_interface uut (
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
        .cpu_addr_out(cpu_addr_out),
        .addr_override(addr_override),
        .eth_irq(eth_irq),
        .dtack_eth(dtack_eth),
        .ram_data_in(ram_data_in)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #10 clk = ~clk;
    end

    // Test sequence
    initial begin
        // Initialize
        reset = 1;
        cpu_addr = 23'h0;
        cpu_data_in = 16'h0;
        cpu_rd = 0;
        cpu_hwr = 0;
        cpu_lwr = 0;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet_shm = 0;
        sel_ethernet = 0;
        ethernet_base = 8'hEA;
        ram_data_in = 16'h0;

        // Wait and release reset
        #100;
        reset = 0;
        #100;

        // Test 1: Access to register space 0xEA0C00 (should be handled)
        $display("\n=== Test 1: Register space access (0xEA0C00) ===");
        cpu_addr = 23'h750600; // 0xEA0C00 >> 1
        cpu_data_in = 16'h1234;
        sel_ethernet = 1;
        cpu_hwr = 1;
        cpu_uds = 0;
        #40;
        cpu_hwr = 0;
        cpu_uds = 1;
        sel_ethernet = 0;
        #100;

        // Test 2: Access to data port 0xEA0C40 (should be handled)
        $display("\n=== Test 2: Data port access (0xEA0C40) ===");
        cpu_addr = 23'h750620; // 0xEA0C40 >> 1
        cpu_data_in = 16'h5678;
        sel_ethernet = 1;
        cpu_hwr = 1;
        cpu_uds = 0;
        #60; // Wait for DTACK delay
        cpu_hwr = 0;
        cpu_uds = 1;
        sel_ethernet = 0;
        #100;

        // Test 3: Access to control space 0xEA1000 (should be handled)
        $display("\n=== Test 3: Control space access (0xEA1000) ===");
        cpu_addr = 23'h750800; // 0xEA1000 >> 1
        cpu_data_in = 16'h9ABC;
        sel_ethernet_shm = 1;
        cpu_hwr = 1;
        cpu_uds = 0;
        #40;
        cpu_hwr = 0;
        cpu_uds = 1;
        sel_ethernet_shm = 0;
        #100;

        // Test 4: Access to NE2000 memory space 0xEA3000 (should NOT trigger our FSM)
        $display("\n=== Test 4: NE2000 memory space access (0xEA3000) - should be isolated ===");
        cpu_addr = 23'h751800; // 0xEA3000 >> 1
        cpu_data_in = 16'hDEF0;
        sel_ethernet_shm = 1;
        cpu_hwr = 1;
        cpu_uds = 0;
        #40;
        cpu_hwr = 0;
        cpu_uds = 1;
        sel_ethernet_shm = 0;
        #100;

        // Test 5: Access to 0xEA4000 (should also be isolated)
        $display("\n=== Test 5: Higher memory space access (0xEA4000) - should be isolated ===");
        cpu_addr = 23'h752000; // 0xEA4000 >> 1
        cpu_data_in = 16'h1357;
        sel_ethernet_shm = 1;
        cpu_hwr = 1;
        cpu_uds = 0;
        #40;
        cpu_hwr = 0;
        cpu_uds = 1;
        sel_ethernet_shm = 0;
        #100;

        $display("\n=== Address isolation test complete ===");
        $finish;
    end

    // Monitor state changes and FSM activity
    initial begin
        $monitor("Time=%0t addr=%h shm=%b eth=%b state=%d mem_state=%d dtack=%b", 
                 $time, cpu_addr, sel_ethernet_shm, sel_ethernet, 
                 uut.state, uut.mem_state, dtack_eth);
    end

endmodule