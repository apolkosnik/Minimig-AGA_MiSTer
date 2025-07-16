// Testbench for data port write simulation - verify shared memory access
`timescale 1ns / 1ps

module tb_data_port_write;

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

// Monitor signals
wire cpu_wr = cpu_hwr | cpu_lwr;

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
    $display("Starting Data Port Write Simulation");
    $display("Testing address translation and shared memory access");
    
    // Reset sequence
    #20 reset = 1;  // Assert reset
    #10 reset = 0;  // Release reset 
    #10;
    
    $display("Reset complete at time %t", $time);
    
    // Test 1: Switch to Page 1 to access RSAR registers
    $display("\nTest 1: Switch to Page 1 for RSAR Access");
    
    // First, set Command Register to Page 1 (bits 7-6 = 01)
    cpu_addr = 23'h750600;  // 0xEA0C00 >> 1 (CR)
    sel_ethernet = 1;
    cpu_data_in = 16'h4000;  // Page 1 command (bits 7-6 = 01)
    cpu_hwr = 1;
    cpu_uds = 0;
    
    #20;
    $display("CR Page 1 Write: addr=0x%06x, data=0x%04x", {cpu_addr, 1'b0}, cpu_data_in);
    $display("  cr_register = 0x%02x, cr[7:6] = %b, current_page = %d", dut.cr_register, dut.cr_register[7:6], dut.current_page);
    
    cpu_hwr = 0;
    cpu_uds = 1;
    sel_ethernet = 0;
    #20;  // Wait one clock cycle for page update to take effect
    $display("  After delay: cr_register = 0x%02x, cr[7:6] = %b, current_page = %d", dut.cr_register, dut.cr_register[7:6], dut.current_page);
    
    // Test 2: Setup Remote DMA Address (RSAR0/RSAR1)
    $display("\nTest 2: Setup Remote DMA Address (RSAR0/RSAR1)");
    
    // Write to RSAR0 (Remote Start Address 0) - register 8 
    cpu_addr = 23'h750610;  // 0xEA0C20 >> 1 (RSAR0)
    sel_ethernet = 1;
    cpu_data_in = 16'h3400;  // DMA address low = 0x34
    cpu_hwr = 1;
    cpu_uds = 0;  // Writing high byte
    
    #20;
    $display("RSAR0 Write: addr=0x%06x, data=0x%04x, dtack=%b", 
             {cpu_addr, 1'b0}, cpu_data_in, dtack_eth);
    $display("  remote_dma_addr = 0x%04x", dut.remote_dma_addr);
    
    cpu_hwr = 0;
    cpu_uds = 1;
    sel_ethernet = 0;
    #20;  // Wait for register write to take effect
    $display("  After RSAR0: remote_dma_addr = 0x%04x, current_page = %d", 
             dut.remote_dma_addr, dut.current_page);
    
    // Write to RSAR1 (Remote Start Address 1) - register 9
    cpu_addr = 23'h750612;  // 0xEA0C24 >> 1 (RSAR1)
    sel_ethernet = 1;
    cpu_data_in = 16'h1200;  // DMA address high = 0x12
    cpu_hwr = 1;
    cpu_uds = 0;
    
    #20;
    $display("RSAR1 Write: addr=0x%06x, data=0x%04x, dtack=%b", 
             {cpu_addr, 1'b0}, cpu_data_in, dtack_eth);
    $display("  remote_dma_addr = 0x%04x", dut.remote_dma_addr);
    
    cpu_hwr = 0;
    cpu_uds = 1;
    sel_ethernet = 0;
    #20;  // Wait for register write to take effect
    $display("  After RSAR1: remote_dma_addr = 0x%04x", dut.remote_dma_addr);
    
    // Test 3: Setup byte count registers
    $display("\nTest 3: Setup Remote Byte Count (RBCR0/RBCR1)");
    
    // Write to RBCR0 - register 10
    cpu_addr = 23'h750614;  // 0xEA0C28 >> 1 (RBCR0)
    sel_ethernet = 1;
    cpu_data_in = 16'h0400;  // 4 bytes
    cpu_hwr = 1;
    cpu_uds = 0;
    
    #20;
    $display("RBCR0 Write: addr=0x%06x, data=0x%04x", {cpu_addr, 1'b0}, cpu_data_in);
    
    cpu_hwr = 0;
    cpu_uds = 1;
    sel_ethernet = 0;
    #10;
    
    // Write to RBCR1 - register 11
    cpu_addr = 23'h750616;  // 0xEA0C2C >> 1 (RBCR1)
    sel_ethernet = 1;
    cpu_data_in = 16'h0000;  // High byte of count
    cpu_hwr = 1;
    cpu_uds = 0;
    
    #20;
    $display("RBCR1 Write: addr=0x%06x, data=0x%04x", {cpu_addr, 1'b0}, cpu_data_in);
    
    cpu_hwr = 0;
    cpu_uds = 1;
    sel_ethernet = 0;
    #10;
    
    // Test 4: Start Remote DMA by writing to Command Register
    $display("\nTest 4: Start Remote DMA Write");
    
    // Write to CR (Command Register) - register 0x00
    cpu_addr = 23'h750600;  // 0xEA0C00 >> 1 (CR)
    sel_ethernet = 1;
    cpu_data_in = 16'h1200;  // Remote Write DMA command (bits 5-3 = 010)
    cpu_hwr = 1;
    cpu_uds = 0;
    
    #20;
    $display("CR Write: addr=0x%06x, data=0x%04x (Start Remote DMA)", {cpu_addr, 1'b0}, cpu_data_in);
    
    cpu_hwr = 0;
    cpu_uds = 1;
    sel_ethernet = 0;
    #10;
    
    // Test 5: Write data to data port
    $display("\nTest 5: Data Port Writes with Address Translation");
    
    // Write first word to data port at 0xEA0C40
    cpu_addr = 23'h750620;  // 0xEA0C40 >> 1 (Data Port)
    sel_ethernet = 1;
    cpu_data_in = 16'hCAFE;  // Test data
    cpu_hwr = 1;
    cpu_lwr = 1;
    cpu_uds = 0;
    cpu_lds = 0;
    
    #20;
    $display("Data Port Write 1: addr=0x%06x, data=0x%04x", {cpu_addr, 1'b0}, cpu_data_in);
    $display("  Data port write completed");
    
    cpu_hwr = 0;
    cpu_lwr = 0;
    cpu_uds = 1;
    cpu_lds = 1;
    sel_ethernet = 0;
    #10;
    
    // Write second word to data port
    cpu_addr = 23'h750620;  // 0xEA0C40 >> 1 (Data Port)
    sel_ethernet = 1;
    cpu_data_in = 16'hBEEF;  // Test data
    cpu_hwr = 1;
    cpu_lwr = 1;
    cpu_uds = 0;
    cpu_lds = 0;
    
    #20;
    $display("Data Port Write 2: addr=0x%06x, data=0x%04x", {cpu_addr, 1'b0}, cpu_data_in);
    $display("  Data port write completed");
    
    cpu_hwr = 0;
    cpu_lwr = 0;
    cpu_uds = 1;
    cpu_lds = 1;
    sel_ethernet = 0;
    #10;
    
    // Test 6: Check if translation points to correct shared memory region
    $display("\nTest 6: Address Translation Analysis");
    $display("Expected NE2000 memory region: 0xEA4000-0xEA7FFF");
    $display("Data should be written to shared memory via translated addresses");
    
    #50;
    $display("\nSimulation completed at time %t", $time);
    $finish;
end

// Monitor data port writes
always @(posedge clk) begin
    if (sel_ethernet && cpu_wr && cpu_addr == 23'h750620) begin
        $display("*** DATA PORT WRITE DETECTED ***");
        $display("  Address: 0x%06x (Data Port)", {cpu_addr, 1'b0});
        $display("  Data: 0x%04x", cpu_data_in);
        $display("  This should trigger shared memory write via NE2000 Remote DMA");
    end
end

endmodule