`timescale 1ns / 1ps

module tb_ethernet_simple;

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

        // Test register write to CR (0xEA0C00)
        $display("\n=== Testing CR register write ===");
        cpu_addr = 23'h750600; // 0xEA0C00 >> 1
        cpu_data_in = 16'h2100; // CR = 0x21
        sel_ethernet = 1;
        cpu_hwr = 1;
        cpu_uds = 0;
        #20;
        cpu_hwr = 0;
        cpu_uds = 1;
        sel_ethernet = 0;
        #100;

        // Test data port write (0xEA0C40)
        $display("\n=== Testing data port write ===");
        cpu_addr = 23'h750620; // 0xEA0C40 >> 1
        cpu_data_in = 16'hDEAD;
        sel_ethernet = 1;
        cpu_hwr = 1;
        cpu_lwr = 1;
        cpu_uds = 0;
        cpu_lds = 0;
        #20;
        
        // Check DTACK behavior
        $display("DTACK should be high (stalled): dtack_eth = %b", dtack_eth);
        #40; // Wait for 2 cycle delay
        $display("DTACK should be low (ready): dtack_eth = %b", dtack_eth);
        
        cpu_hwr = 0;
        cpu_lwr = 0;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        #100;

        $display("\n=== Test complete ===");
        $finish;
    end

    // Create intermediate signals for monitoring
    wire cpu_wr = cpu_hwr | cpu_lwr;
    
    // Monitor important signals
    initial begin
        $monitor("Time=%0t addr=%h data_in=%h wr=%b rd=%b dtack=%b addr_override=%b", 
                 $time, cpu_addr, cpu_data_in, cpu_wr, cpu_rd, dtack_eth, addr_override);
    end

endmodule