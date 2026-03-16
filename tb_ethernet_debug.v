`timescale 1ns / 1ps

// Debug Ethernet Address Decoding
module tb_ethernet_debug;

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
    
    // Debug output
    always @(posedge clk) begin
        if (sel_ethernet) begin
            $display("DEBUG: cpu_addr=0x%06x, reg_sel=%d, is_reg=%b, is_data_port=%b, cpu_rd=%b", 
                     {cpu_addr, 1'b0}, uut.register_select, uut.is_register_access, 
                     uut.is_data_port_access, cpu_rd);
            $display("       cr_reg=0x%02x, id0=0x%02x, id1=0x%02x, cpu_data_out=0x%04x",
                     uut.cr_register, uut.id0_register, uut.id1_register, cpu_data_out);
        end
    end

    // Test sequence
    initial begin
        $display("Starting Ethernet Address Decoding Debug");
        
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
        ethernet_base = 8'hEA;
        ram_data_in = 16'h0000;
        
        // Reset sequence
        #20 reset = 0;
        #10 reset = 1;
        #20;
        
        $display("\n=== Testing Address Decoding ===");
        
        // Test register read at 0xEA0C0A (ID0 register)
        $display("\nTest 1: Reading ID0 register at 0xEA0C0A");
        @(negedge clk);
        cpu_addr = 23'h750614;  // 0xEA0C28 for register 0xA in 4-byte aligned layout
        sel_ethernet = 1;
        cpu_rd = 0; // Active low read
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        #1;
        @(negedge clk);
        cpu_rd = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        
        // Test register read at 0xEA0C0B (ID1 register)  
        $display("\nTest 2: Reading ID1 register at 0xEA0C0B");
        @(negedge clk);
        cpu_addr = 23'h750605;  // 0xEA0C0B (word address)
        sel_ethernet = 1;
        cpu_rd = 0; // Active low read
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        #1;
        @(negedge clk);
        cpu_rd = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        
        // Test register read at 0xEA0C00 (CR register)
        $display("\nTest 3: Reading CR register at 0xEA0C00");
        @(negedge clk);
        cpu_addr = 23'h750600;  // 0xEA0C00
        sel_ethernet = 1;
        cpu_rd = 0; // Active low read
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        #1;
        @(negedge clk);
        cpu_rd = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        
        // Test data port access at 0xEA0C40
        $display("\nTest 4: Data port access at 0xEA0C40");
        @(negedge clk);
        cpu_addr = 23'h750620;  // 0xEA0C40
        sel_ethernet = 1;
        cpu_rd = 0; // Active low read
        cpu_uds = 0;
        cpu_lds = 0;
        @(posedge clk);
        #1;
        @(negedge clk);
        cpu_rd = 1;
        cpu_uds = 1;
        cpu_lds = 1;
        sel_ethernet = 0;
        
        $display("\n=== Debug Complete ===");
        #50;
        $finish;
    end

endmodule