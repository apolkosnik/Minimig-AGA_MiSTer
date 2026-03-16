`timescale 1ns / 1ps

// Trace shared memory write issues
module tb_trace_shm;

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
    
    // Debug tracing
    always @(posedge clk) begin
        if (sel_ethernet && (cpu_hwr == 0 || cpu_lwr == 0)) begin
            $display("DEBUG @%t: WRITE cpu_addr=0x%06x, data=0x%04x, is_reg=%b, is_data=%b", 
                     $time, {cpu_addr, 1'b0}, cpu_data_in, uut.is_register_access, uut.is_data_port_access);
            $display("       shm_state=%d, pending_valid=%b, pending_addr=0x%04x", 
                     uut.shm_write_state, uut.pending_shm_valid, uut.pending_shm_addr);
        end
        if (shm_write_req) begin
            $display("*** SHARED MEMORY WRITE @%t: addr=0x%04x, data=0x%04x, byte=%b", 
                     $time, shm_write_addr, shm_write_data, shm_write_byte);
        end
        if (uut.pending_shm_valid) begin
            $display("    pending_shm set: addr=0x%04x, data=0x%04x", 
                     uut.pending_shm_addr, uut.pending_shm_data);
        end
    end

    // Test sequence
    initial begin
        $display("Starting Shared Memory Write Trace");
        
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
        
        $display("\n=== Test CR Register Write ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h0C, 4'h0, 2'b00}; // 0xEA0C00 - CR register
        cpu_data_in = 16'h1200;  // CR = 0x12
        sel_ethernet = 1;
        cpu_rd = 1;
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
        repeat(5) @(posedge clk);
        
        $display("\n=== Test RSAR0 Register Write ===");
        @(negedge clk);
        cpu_addr = 23'h750610; // 0xEA0C20 - RSAR0 (register 8 at 4-byte aligned offset)
        cpu_data_in = 16'h3400;  // RSAR0 = 0x34
        sel_ethernet = 1;
        cpu_rd = 1;
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
        repeat(5) @(posedge clk);
        
        $display("\n=== Test Data Port Write ===");
        @(negedge clk);
        cpu_addr = 23'h750620; // 0xEA0C40 - data port
        cpu_data_in = 16'hCAFE;
        sel_ethernet = 1;
        cpu_rd = 1;
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
        repeat(5) @(posedge clk);
        
        $display("\n=== Trace Complete ===");
        #50;
        $finish;
    end

endmodule