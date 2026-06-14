`timescale 1ns / 1ps

// Test to reproduce race condition on register reads
module tb_race_condition;

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
    
    // Monitor register reads for stability
    reg [15:0] last_read_value;
    reg [3:0] read_count;
    
    always @(posedge clk) begin
        if (sel_ethernet && cpu_rd) begin
            if (cpu_data_out != last_read_value && read_count > 0) begin
                $display("@%t: *** RACE CONDITION DETECTED! addr=%h, old_value=%h, new_value=%h", 
                         $time, {cpu_addr, 1'b0}, last_read_value, cpu_data_out);
            end
            last_read_value <= cpu_data_out;
            read_count <= read_count + 1;
            
            $display("@%t: READ addr=%h, data=%h, dtack=%b, reg_sel=%h, is_reg=%b", 
                     $time, {cpu_addr, 1'b0}, cpu_data_out, dtack_eth, 
                     uut.register_select, uut.is_register_access);
        end
    end

    // Test sequence
    initial begin
        $display("Starting Race Condition Test");
        
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
        last_read_value = 16'h0000;
        read_count = 0;
        
        // Reset sequence
        #20 reset = 0;  // Release reset for normal operation
        #20;
        
        // Test 1: Read CR register repeatedly to check for stability
        $display("\n=== Test 1: Repeated CR Register Reads ===");
        repeat(10) begin
            @(negedge clk);
            cpu_addr = {ethernet_base, 8'h00, 4'h0, 2'b00}; // CR register
            sel_ethernet = 1;
            cpu_rd = 1;  // Active high read in ethernet module
            cpu_uds = 0;
            cpu_lds = 0;
            @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            cpu_rd = 0;  // Inactive
            cpu_uds = 1;
            cpu_lds = 1;
            sel_ethernet = 0;
            @(posedge clk);
        end
        
        // Test 2: Read different registers in sequence
        $display("\n=== Test 2: Sequential Register Reads ===");
        read_count = 0;
        repeat(16) begin
            @(negedge clk);
            cpu_addr = {ethernet_base, 8'h00, read_count[3:0], 2'b00}; // Different registers
            sel_ethernet = 1;
            cpu_rd = 1;  // Active high read
            cpu_uds = 0;
            cpu_lds = 0;
            @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            cpu_rd = 0;  // Inactive
            cpu_uds = 1;
            cpu_lds = 1;
            sel_ethernet = 0;
            read_count = read_count + 1;
            @(posedge clk);
        end
        
        // Test 3: Read with rapid address changes (simulate bus noise)
        $display("\n=== Test 3: Rapid Address Changes ===");
        repeat(10) begin
            @(negedge clk);
            // Start with one address
            cpu_addr = {ethernet_base, 8'h00, 4'h0, 2'b00}; // CR register
            sel_ethernet = 1;
            cpu_rd = 1;  // Active high read
            cpu_uds = 0;
            cpu_lds = 0;
            
            // Change address quickly (simulate noise/glitch)
            #1;
            cpu_addr = {ethernet_base, 8'h00, 4'hF, 2'b00}; // IMR register
            #1;
            cpu_addr = {ethernet_base, 8'h00, 4'h0, 2'b00}; // Back to CR
            
            @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            cpu_rd = 0;  // Inactive
            cpu_uds = 1;
            cpu_lds = 1;
            sel_ethernet = 0;
            @(posedge clk);
        end
        
        $display("\n=== Race Condition Test Complete ===");
        $finish;
    end

endmodule