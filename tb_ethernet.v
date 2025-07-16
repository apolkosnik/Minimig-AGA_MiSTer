// Simple testbench for ethernet module
`timescale 1ns / 1ps

module tb_ethernet;

reg clk = 0;
reg reset = 1;

// CPU bus interface
reg [23:1] cpu_addr;
reg [15:0] cpu_data_in;
wire [15:0] cpu_data_out;
reg cpu_rd = 0;
reg cpu_hwr = 0;
reg cpu_lwr = 0;
reg cpu_uds = 1;
reg cpu_lds = 1;

// Chip selects
reg sel_ethernet_shm = 0;
reg sel_ethernet = 0;

// Ethernet base address
reg [7:0] ethernet_base = 8'hEA;

// Outputs
wire eth_irq;
wire dtack_eth;

// RAM data
reg [15:0] ram_data_in = 16'h0000;

// Generate clock
always #5 clk = ~clk;

// Instantiate ethernet module
ethernet_interface dut (
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

// Test sequence
initial begin
    $display("Starting Ethernet Module Test");
    
    // Reset sequence
    #20 reset = 0;
    #10 reset = 1;
    #10;
    
    $display("Reset complete at time %t", $time);
    
    // Test 1: Register read (Command Register at 0xEA0C00)
    $display("Test 1: Register read from Command Register");
    cpu_addr = 23'h750600;  // 0xEA0C00 >> 1 (word address)
    sel_ethernet = 1;
    cpu_rd = 1;
    cpu_uds = 0;
    cpu_lds = 0;
    
    #20;
    
    $display("DTACK: %b, Data out: %h at time %t", dtack_eth, cpu_data_out, $time);
    
    cpu_rd = 0;
    cpu_uds = 1;
    cpu_lds = 1;
    sel_ethernet = 0;
    
    #10;
    
    // Test 2: Data port read (0xEA0C40)
    $display("Test 2: Data port read");
    cpu_addr = 23'h750620;  // 0xEA0C40 >> 1 (word address)
    sel_ethernet = 1;
    cpu_rd = 1;
    cpu_uds = 0;
    cpu_lds = 0;
    
    #20;
    
    $display("DTACK: %b, Data out: %h at time %t", dtack_eth, cpu_data_out, $time);
    
    cpu_rd = 0;
    cpu_uds = 1;
    cpu_lds = 1;
    sel_ethernet = 0;
    
    #10;
    
    // Test 3: Shared memory access (0xEA1000)
    $display("Test 3: Shared memory access");
    cpu_addr = 23'h750800;  // 0xEA1000 >> 1 (word address)
    sel_ethernet_shm = 1;
    cpu_rd = 1;
    cpu_uds = 0;
    cpu_lds = 0;
    ram_data_in = 16'hCAFE;
    
    #20;
    
    $display("Data out: %h at time %t", cpu_data_out, $time);
    
    cpu_rd = 0;
    cpu_uds = 1;
    cpu_lds = 1;
    sel_ethernet_shm = 0;
    
    #20;
    
    $display("Test completed at time %t", $time);
    $finish;
end

endmodule