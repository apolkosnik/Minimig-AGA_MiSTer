`timescale 1ns / 1ps

// Test data port writes to shared memory
module tb_data_port_writes;

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
    
    // Ethernet base address
    reg [7:0] ethernet_base;
    
    // Address override outputs
    wire [23:1] cpu_addr_out;
    wire addr_override;
    
    // Shared memory write interface
    wire shm_write_req;
    wire [15:0] shm_write_addr;
    wire [15:0] shm_write_data;
    wire shm_write_byte;
    
    // DTACK and IRQ
    wire dtack_eth;
    wire eth_irq;
    
    // RAM data input
    reg [15:0] ram_data_in;

    // Instantiate the ethernet interface
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
        .shm_write_req(shm_write_req),
        .shm_write_addr(shm_write_addr),
        .shm_write_data(shm_write_data),
        .shm_write_byte(shm_write_byte),
        .eth_irq(eth_irq),
        .dtack_eth(dtack_eth),
        .ram_data_in(ram_data_in)
    );

    // Clock generation
    always #5 clk = ~clk;
    
    // Monitor shared memory writes and register updates
    always @(posedge clk) begin
        if (shm_write_req) begin
            $display("@%t: SHARED MEM WRITE - addr=0x%04x, data=0x%04x, byte=%b", 
                     $time, shm_write_addr, shm_write_data, shm_write_byte);
        end
        
        if (uut.pending_shm_valid && uut.is_data_port_access) begin
            $display("@%t: PENDING DATA PORT - addr=0x%04x, data=0x%04x, rsa=0x%04x", 
                     $time, uut.pending_shm_addr, uut.pending_shm_data, uut.remote_dma_addr);
        end
        
        if (sel_ethernet && uut.cpu_wr) begin
            $display("@%t: CPU WRITE - addr=0x%06x, data=0x%04x, is_reg=%b, is_data=%b, reg_sel=%h", 
                     $time, {cpu_addr, 1'b0}, cpu_data_in, uut.is_register_access, uut.is_data_port_access, uut.register_select);
            $display("       addr_bits: cpu_addr[7:1]=0x%02x, cpu_addr[7:6]=0x%01x", cpu_addr[7:1], cpu_addr[7:6]);
        end
    end

    // Test sequence
    initial begin
        $display("Starting Data Port Write Test");
        
        // Initialize signals
        clk = 0;
        reset = 1;
        cpu_addr = 23'h000000;
        cpu_data_in = 16'h0000;
        cpu_rd = 0;
        cpu_hwr = 1;
        cpu_lwr = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        sel_ethernet_shm = 0;
        ethernet_base = 8'hEA;
        ram_data_in = 16'h0000;
        
        // Reset sequence
        #20 reset = 0;  // Release reset for normal operation
        #20;
        
        // Test 1: Set up remote DMA address (RSAR)
        $display("\n=== Setup Remote DMA Address ===");
        
        // Write RSAR0 = 0x00  
        @(negedge clk);
        cpu_addr = {ethernet_base, 15'h0010}; // RSAR0 at word address 0x750010 (byte 0xEA0020)
        cpu_data_in = 16'h0000;  // RSAR0 = 0x00
        sel_ethernet = 1;
        cpu_hwr = 0;
        cpu_lwr = 0;
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        cpu_hwr = 1;
        cpu_lwr = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        @(posedge clk);
        
        // Write RSAR1 = 0x40 (remote DMA address = 0x4000)
        @(negedge clk);
        cpu_addr = {ethernet_base, 15'h0012}; // RSAR1 at word address 0x750012 (byte 0xEA0024)
        cpu_data_in = 16'h4000;  // RSAR1 = 0x40 (high byte)
        sel_ethernet = 1;
        cpu_hwr = 0;
        cpu_lwr = 0;
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        cpu_hwr = 1;
        cpu_lwr = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        @(posedge clk);
        
        $display("Remote DMA Address should now be 0x4000");
        $display("Actual remote_dma_addr = 0x%04x", uut.remote_dma_addr);
        
        // Test 2: Write to data port
        $display("\n=== Data Port Writes ===");
        
        // Write to data port - should go to 0x3000 + 0x4000 = 0x7000
        @(negedge clk);
        cpu_addr = {ethernet_base, 15'h0620}; // Data port at word address 0x750620 (byte 0xEA0C40)
        cpu_data_in = 16'hDEAD;  // Test data
        sel_ethernet = 1;
        cpu_hwr = 0;
        cpu_lwr = 0;
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        cpu_hwr = 1;
        cpu_lwr = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        
        // Wait for state machine
        repeat(10) @(posedge clk);
        
        // Second write to data port - should go to 0x3000 + 0x4002 = 0x7002 (auto-increment)
        @(negedge clk);
        cpu_addr = {ethernet_base, 15'h0620}; // Data port at word address 0x750620 (byte 0xEA0C40)
        cpu_data_in = 16'hBEEF;  // Test data
        sel_ethernet = 1;
        cpu_hwr = 0;
        cpu_lwr = 0;
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        cpu_hwr = 1;
        cpu_lwr = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        
        // Wait for state machine
        repeat(10) @(posedge clk);
        
        $display("\n=== Data Port Write Test Complete ===");
        $display("Expected: Data writes to 0x7000 and 0x7002 (0x3000 + remote_dma_addr)");
        $finish;
    end

endmodule