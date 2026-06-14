`timescale 1ns / 1ps

// Test for ethernet register redirection to DDR3 shared memory
// Tests that register access goes through sel_ethernet_shm instead of sel_ethernet
module tb_register_redirect_test;

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
    wire sel_ethernet;
    wire sel_ethernet_shm;
    
    // Ethernet configuration
    reg [7:0] ethernet_base;
    reg ethernet_ena;
    
    // Memory interface
    reg [15:0] ram_data_in;
    wire [28:1] ramaddr;
    wire ramsel;
    wire ramshared;
    
    // DTACK and IRQ
    wire dtack_eth;
    wire eth_irq;
    
    // CPU wrapper inputs (simplified)
    wire [31:0] cpu_addr_32 = {8'h00, cpu_addr, 1'b0};
    reg cpu_req = 1;
    reg sel_nmi_vector = 0;
    reg sel_zram = 0;
    reg sel_chipram = 0; 
    reg sel_kickram = 0;
    reg sel_dd = 0;
    reg sel_rtg = 0;

    // Instantiate cpu_wrapper to test address mapping
    cpu_wrapper cpu_wrap (
        .reset(reset),
        .reset_out(),
        .clk(clk),
        .ph1(1'b1),
        .ph2(1'b0),
        .cpucfg(2'b00),
        .fastramcfg(3'b000),
        .cachecfg(3'b000),
        .bootrom(1'b0),
        .chip_addr(),
        .chip_dout(16'h0000),
        .chip_din(),
        .chip_as(),
        .chip_uds(),
        .chip_lds(),
        .chip_rw(),
        .chip_dtack(1'b0),
        .chip_ipl(3'b111),
        .fastchip_dout(16'h0000),
        .fastchip_sel(),
        .fastchip_lds(),
        .fastchip_uds(),
        .fastchip_rnw(),
        .fastchip_lw(),
        .fastchip_selack(1'b0),
        .fastchip_ready(1'b0),
        .ramsel(ramsel),
        .ramaddr(ramaddr),
        .ramdin(),
        .ramdout(16'h0000),
        .ramready(1'b1),
        .ramlds(),
        .ramuds(),
        .ramshared(ramshared),
        .toccata_ena(),
        .toccata_base(),
        .sel_ethernet(sel_ethernet),
        .ethernet_ena(ethernet_ena),
        .ethernet_base(ethernet_base),
        .sel_ethernet_shm(sel_ethernet_shm),
        .eth_irq(eth_irq),
        .cpustate(),
        .cacr(),
        .nmi_addr()
    );

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
    
    // Monitor address mapping
    always @(posedge clk) begin
        if (sel_ethernet_shm) begin
            $display("SEL_ETHERNET_SHM: CPU addr=0x%06x -> RAM addr=0x%07x, shared=%b", 
                     {cpu_addr, 1'b0}, {ramaddr, 1'b0}, ramshared);
        end
        if (sel_ethernet && !sel_ethernet_shm) begin
            $display("WARNING: SEL_ETHERNET without SEL_ETHERNET_SHM at addr=0x%06x", {cpu_addr, 1'b0});
        end
    end

    // Test sequence
    initial begin
        $display("Starting Register Redirection Test");
        
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
        ethernet_base = 8'hEA;
        ethernet_ena = 1;
        ram_data_in = 16'h0000;
        
        // Reset sequence
        #20 reset = 1;
        #20;
        
        $display("\n=== Test 1: CR Register Read (0xEA0C00) ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00 - CR register
        cpu_rd = 0; // Read operation
        ram_data_in = 16'h2100; // Simulate data from shared memory
        @(posedge clk);
        @(posedge clk);
        cpu_rd = 1;
        #20;
        
        $display("\n=== Test 2: CR Register Write (0xEA0C00) ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h00}; // 0xEA0C00 - CR register  
        cpu_data_in = 16'h2200; // Write data
        cpu_hwr = 0; // Write operation
        cpu_uds = 0; // Upper byte active
        @(posedge clk);
        @(posedge clk);
        cpu_hwr = 1;
        cpu_uds = 1;
        #20;
        
        $display("\n=== Test 3: Data Port Access (0xEA0C40) ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 7'h20}; // 0xEA0C40 - data port
        cpu_data_in = 16'hCAFE;
        cpu_hwr = 0;
        cpu_uds = 0;
        @(posedge clk);
        @(posedge clk);
        cpu_hwr = 1;
        cpu_uds = 1;
        #20;
        
        $display("\n=== Test 4: Shared Memory Access (0xEA1004) ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h10, 7'h02}; // 0xEA1004 - direct shared memory
        cpu_data_in = 16'hDEAD;
        cpu_hwr = 0;
        cpu_uds = 0;
        @(posedge clk);
        @(posedge clk);
        cpu_hwr = 1;
        cpu_uds = 1;
        #20;

        $display("\n=== Test 5: Non-ethernet Access (0x123456) ===");
        @(negedge clk);
        cpu_addr = 23'h123456; // Non-ethernet address
        cpu_data_in = 16'hBEEF;
        cpu_hwr = 0;
        cpu_uds = 0;
        @(posedge clk);
        @(posedge clk);
        cpu_hwr = 1;
        cpu_uds = 1;
        #20;
        
        $display("\n=== Address Mapping Summary ===");
        $display("Expected mappings:");
        $display("  0xEA0C00 (CR reg)  -> 0xEA1004 (shared memory)");
        $display("  0xEA0C04 (reg 1)   -> 0xEA1005 (shared memory)");
        $display("  0xEA0C40 (data)    -> 0xEA1004 (shared memory)");
        $display("  0xEA1004 (direct)  -> 0xEA1004 (shared memory)");
        
        $display("\n=== Test Complete ===");
        #50;
        $finish;
    end

endmodule