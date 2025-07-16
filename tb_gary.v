// Simple testbench for gary module address decoding
`timescale 1ns / 1ps

module tb_gary;

reg clk = 0;
reg reset = 1;

// CPU address bus
reg [23:1] cpu_address_in;
reg [20:1] dma_address_in = 20'h00000;

// Control signals
reg a1k = 0;
reg bootrom = 0;
reg cpu_rd = 1;
reg cpu_hwr = 0;
reg cpu_lwr = 0;
reg cpu_hlt = 0;
reg ovl = 0;
reg dbr = 0;
reg dbwe = 0;

// Configuration
reg [3:0] memory_config = 4'b0000;
reg ecs = 1;
reg hdc_ena = 1;
reg toccata_ena = 1;
reg [7:0] toccata_base = 8'hE9;
reg ethernet_ena = 1;
reg [7:0] ethernet_base = 8'hEA;

// Data buses
reg [15:0] cpu_data_out = 16'h0000;
reg [15:0] custom_data_out = 16'h0000;
reg [15:0] ram_data_out = 16'h0000;
wire [15:0] cpu_data_in;
wire [15:0] custom_data_in;
wire [15:0] ram_data_in;

// Address output
wire [23:1] ram_address_out;

// Control outputs
wire ram_rd, ram_hwr, ram_lwr;
wire dbs, xbs;

// Chip selects
wire sel_reg;
wire [3:0] sel_chip;
wire [2:0] sel_slow;
wire sel_kick, sel_kick1mb, sel_kick256kmirror;
wire sel_cia, sel_cia_a, sel_cia_b;
wire sel_rtg, sel_rtc, sel_ide, sel_gayle;
wire sel_toccata, sel_ethernet;
wire rom_readonly;

// Generate clock
always #5 clk = ~clk;

// Instantiate gary module
gary dut (
    .cpu_address_in(cpu_address_in),
    .dma_address_in(dma_address_in),
    .ram_address_out(ram_address_out),
    .cpu_data_out(cpu_data_out),
    .cpu_data_in(cpu_data_in),
    .custom_data_out(custom_data_out),
    .custom_data_in(custom_data_in),
    .ram_data_out(ram_data_out),
    .ram_data_in(ram_data_in),
    .a1k(a1k),
    .bootrom(bootrom),
    .clk(clk),
    .reset(reset),
    .cpu_rd(cpu_rd),
    .cpu_hwr(cpu_hwr),
    .cpu_lwr(cpu_lwr),
    .cpu_hlt(cpu_hlt),
    .ovl(ovl),
    .dbr(dbr),
    .dbwe(dbwe),
    .dbs(dbs),
    .xbs(xbs),
    .memory_config(memory_config),
    .ecs(ecs),
    .hdc_ena(hdc_ena),
    .toccata_ena(toccata_ena),
    .toccata_base(toccata_base),
    .ethernet_ena(ethernet_ena),
    .ethernet_base(ethernet_base),
    .ram_rd(ram_rd),
    .ram_hwr(ram_hwr),
    .ram_lwr(ram_lwr),
    .sel_reg(sel_reg),
    .sel_chip(sel_chip),
    .sel_slow(sel_slow),
    .sel_kick(sel_kick),
    .sel_kick1mb(sel_kick1mb),
    .sel_kick256kmirror(sel_kick256kmirror),
    .sel_cia(sel_cia),
    .sel_cia_a(sel_cia_a),
    .sel_cia_b(sel_cia_b),
    .sel_rtg(sel_rtg),
    .sel_rtc(sel_rtc),
    .sel_ide(sel_ide),
    .sel_gayle(sel_gayle),
    .sel_toccata(sel_toccata),
    .sel_ethernet(sel_ethernet),
    .rom_readonly(rom_readonly)
);

// Test sequence
initial begin
    $display("Starting Gary Address Decoder Test");
    
    // Reset sequence
    #20 reset = 0;
    #10 reset = 1;
    #10;
    
    $display("Reset complete at time %t", $time);
    
    // Test 1: Ethernet register space (0xEA0C00-0xEA0C3F)
    $display("Test 1: Ethernet register space");
    cpu_address_in = 23'h750600;  // 0xEA0C00 >> 1
    #10;
    $display("Address: 0x%h, sel_ethernet: %b at time %t", 
             {cpu_address_in, 1'b0}, sel_ethernet, $time);
    
    // Test 2: Ethernet data port (0xEA0C40-0xEA0C41)
    $display("Test 2: Ethernet data port");
    cpu_address_in = 23'h750620;  // 0xEA0C40 >> 1
    #10;
    $display("Address: 0x%h, sel_ethernet: %b at time %t", 
             {cpu_address_in, 1'b0}, sel_ethernet, $time);
    
    // Test 3: Ethernet shared memory (should NOT trigger sel_ethernet)
    $display("Test 3: Ethernet shared memory");
    cpu_address_in = 23'h750800;  // 0xEA1000 >> 1
    #10;
    $display("Address: 0x%h, sel_ethernet: %b at time %t", 
             {cpu_address_in, 1'b0}, sel_ethernet, $time);
    
    // Test 4: Toccata register space
    $display("Test 4: Toccata register space");
    cpu_address_in = 23'h748000;  // 0xE90000 >> 1
    #10;
    $display("Address: 0x%h, sel_toccata: %b at time %t", 
             {cpu_address_in, 1'b0}, sel_toccata, $time);
    
    // Test 5: CIA space
    $display("Test 5: CIA space");
    cpu_address_in = 23'h5F8000;  // 0xBF0000 >> 1
    #10;
    $display("Address: 0x%h, sel_cia: %b, sel_cia_a: %b at time %t", 
             {cpu_address_in, 1'b0}, sel_cia, sel_cia_a, $time);
    
    // Test 6: Chipram space
    $display("Test 6: Chipram space");
    cpu_address_in = 23'h010000;  // 0x020000 >> 1
    #10;
    $display("Address: 0x%h, sel_chip: %b at time %t", 
             {cpu_address_in, 1'b0}, sel_chip, $time);
    
    #20;
    $display("Gary address decoder test completed at time %t", $time);
    $finish;
end

endmodule