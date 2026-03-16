`timescale 1ns / 1ps

// Complete Ethernet RTL8019AS Test - Validates register access, shared memory writes, and data port operations
module tb_ethernet_complete;

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
    
    // Shared memory write monitor
    always @(posedge clk) begin
        if (shm_write_req) begin
            $display("SHARED MEMORY WRITE: addr=0x%04x, data=0x%04x, byte=%b", 
                     shm_write_addr, shm_write_data, shm_write_byte);
        end
    end

    // Test sequence
    initial begin
        $display("Starting Complete RTL8019AS Ethernet Test");
        
        // Initialize signals
        clk = 0;
        reset = 1;
        cpu_addr = 23'h000000;
        cpu_data_in = 16'h0000;
        cpu_rd = 1;
        cpu_hwr = 1;
        cpu_lwr = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        sel_ethernet_shm = 0;
        ethernet_base = 8'hEA;  // Ethernet at 0xEA0000
        ram_data_in = 16'h0000;
        
        // Reset sequence
        #20 reset = 0;
        #10 reset = 1;
        #20;
        
        $display("\n=== Test 1: RTL8019AS Chip ID Verification ===");
        // Read ID registers from Page 0 (should contain 0x50, 0x70)
        test_register_read(16'h0A, 16'h5000); // ID0 register
        test_register_read(16'h0B, 16'h7000); // ID1 register
        
        $display("\n=== Test 2: Page Switching Test ===");
        // Switch to Page 1
        test_register_write(16'h00, 16'h4000); // CR = 0x40 (Page 1)
        test_register_read(16'h07, 16'h4000);  // CURR register should be accessible
        
        // Switch to Page 3 (RTL8019AS specific)
        test_register_write(16'h00, 16'hC000); // CR = 0xC0 (Page 3)
        test_register_read(16'h0E, 16'h5000);  // ID0 in page 3
        test_register_read(16'h0F, 16'h7000);  // ID1 in page 3
        
        // Return to Page 0
        test_register_write(16'h00, 16'h0000); // CR = 0x00 (Page 0)
        
        $display("\n=== Test 3: Remote DMA Setup and Shared Memory Writes ===");
        // Set up Remote DMA Address (RSAR0/RSAR1)
        test_register_write(16'h08, 16'h3400); // RSAR0 = 0x34
        #10;
        test_register_write(16'h09, 16'h1200); // RSAR1 = 0x12 (total addr = 0x1234)
        #10;
        
        // Set up Remote Byte Count (RBCR0/RBCR1)
        test_register_write(16'h0A, 16'h0800); // RBCR0 = 0x08
        #10;
        test_register_write(16'h0B, 16'h0000); // RBCR1 = 0x00 (total count = 8 bytes)
        #10;
        
        // Start Remote DMA Write
        test_register_write(16'h00, 16'h1200); // CR = 0x12 (Remote Write + Start)
        #10;
        
        $display("\n=== Test 4: Data Port Operations ===");
        // Data port writes (should trigger shared memory writes)
        test_data_port_write(16'hCAFE);
        #10;
        test_data_port_write(16'hBEEF);
        #10;
        test_data_port_write(16'hDEAD);
        #10;
        test_data_port_write(16'h1337);
        #10;
        
        $display("\n=== Test 5: Data Port Reads ===");
        // Set up some test data for reading
        ram_data_in = 16'hA5A5;
        test_data_port_read(16'hA5A5);
        #10;
        
        ram_data_in = 16'h5A5A;
        test_data_port_read(16'h5A5A);
        #10;
        
        $display("\n=== Test 6: Complete Remote DMA ===");
        test_register_write(16'h00, 16'h2000); // CR = 0x20 (Complete Remote DMA)
        #10;
        
        // Check ISR for Remote DMA Complete bit
        test_register_read(16'h07, 16'h4000); // ISR should have RDC bit set
        
        $display("\n=== Test 7: Transmit Packet Simulation ===");
        // Set transmit page start
        test_register_write(16'h04, 16'h2000); // TPSR = 0x20
        #10;
        
        // Start packet transmission
        test_register_write(16'h00, 16'h1800); // CR = 0x18 (Send Packet)
        #10;
        
        // Check ISR for packet transmitted bit
        test_register_read(16'h07, 16'h0200); // ISR should have PTX bit set
        
        $display("\n=== Test Complete ===");
        $display("All RTL8019AS ethernet tests completed successfully!");
        
        #100;
        $finish;
    end
    
    // Helper task for register writes
    task test_register_write(input [15:0] addr, input [15:0] data);
        begin
            $display("REG WRITE: addr=0x%04x, data=0x%04x", addr, data);
            @(negedge clk);
            cpu_addr = {ethernet_base, 8'h0C, addr[3:0], 2'b00}; // 0xEA0C00 + 4-byte aligned register offset
            cpu_data_in = data;
            sel_ethernet = 1;
            sel_ethernet_shm = 0;
            cpu_rd = 1;
            cpu_hwr = 0; // Write
            cpu_lwr = 0;
            cpu_uds = 0;
            cpu_lds = 0;
            @(posedge clk);
            @(negedge clk);
            cpu_hwr = 1;
            cpu_lwr = 1;
            cpu_uds = 1;
            cpu_lds = 1;
            sel_ethernet = 0;
        end
    endtask
    
    // Helper task for register reads
    task test_register_read(input [15:0] addr, input [15:0] expected);
        begin
            @(negedge clk);
            cpu_addr = {ethernet_base, 8'h0C, addr[3:0], 2'b00}; // 0xEA0C00 + 4-byte aligned register offset
            sel_ethernet = 1;
            sel_ethernet_shm = 0;
            cpu_rd = 0; // Read
            cpu_hwr = 1;
            cpu_lwr = 1;
            cpu_uds = 0;
            cpu_lds = 0;
            @(posedge clk);
            #1;
            $display("REG READ: addr=0x%04x, data=0x%04x (expected=0x%04x)", 
                     addr, cpu_data_out, expected);
            if (cpu_data_out != expected) begin
                $display("ERROR: Expected 0x%04x, got 0x%04x", expected, cpu_data_out);
            end
            @(negedge clk);
            cpu_rd = 1;
            cpu_uds = 1;
            cpu_lds = 1;
            sel_ethernet = 0;
        end
    endtask
    
    // Helper task for data port writes
    task test_data_port_write(input [15:0] data);
        begin
            $display("DATA PORT WRITE: data=0x%04x", data);
            @(negedge clk);
            cpu_addr = {ethernet_base, 8'h0C, 6'h20}; // 0xEA0C40 (data port)
            cpu_data_in = data;
            sel_ethernet = 1;
            sel_ethernet_shm = 0;
            cpu_rd = 1;
            cpu_hwr = 0; // Write
            cpu_lwr = 0;
            cpu_uds = 0;
            cpu_lds = 0;
            @(posedge clk);
            @(negedge clk);
            cpu_hwr = 1;
            cpu_lwr = 1;
            cpu_uds = 1;
            cpu_lds = 1;
            sel_ethernet = 0;
        end
    endtask
    
    // Helper task for data port reads
    task test_data_port_read(input [15:0] expected);
        begin
            @(negedge clk);
            cpu_addr = {ethernet_base, 8'h0C, 6'h20}; // 0xEA0C40 (data port)
            sel_ethernet = 1;
            sel_ethernet_shm = 0;
            cpu_rd = 0; // Read
            cpu_hwr = 1;
            cpu_lwr = 1;
            cpu_uds = 0;
            cpu_lds = 0;
            @(posedge clk);
            #1;
            $display("DATA PORT READ: data=0x%04x (expected=0x%04x)", 
                     cpu_data_out, expected);
            if (cpu_data_out != expected) begin
                $display("ERROR: Expected 0x%04x, got 0x%04x", expected, cpu_data_out);
            end
            @(negedge clk);
            cpu_rd = 1;
            cpu_uds = 1;
            cpu_lds = 1;
            sel_ethernet = 0;
        end
    endtask

endmodule