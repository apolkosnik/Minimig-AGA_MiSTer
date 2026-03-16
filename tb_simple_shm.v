`timescale 1ns / 1ps

// Simple test to verify basic shared memory write
module tb_simple_shm;

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
    
    // Monitor all state changes
    always @(posedge clk) begin
        if (!reset) begin
            $display("@%t: RESET ACTIVE", $time);
        end
        else if (sel_ethernet && uut.cpu_wr) begin
            $display("@%t: WRITE ACTIVE - addr=%h, data=%h, is_reg=%b, cpu_wr=%b, reg_sel=%h, cr_page=%b", 
                     $time, cpu_addr, cpu_data_in, uut.is_register_access, uut.cpu_wr, 
                     uut.register_select, uut.cr_register[7:6]);
            $display("       shm_state=%d, pending_valid=%b, pending_addr=%h, cr_reg=%h", 
                     uut.shm_write_state, uut.pending_shm_valid, uut.pending_shm_addr, uut.cr_register);
        end
        
        if (uut.pending_shm_valid) begin
            $display("@%t: PENDING SET - addr=%h, data=%h", $time, uut.pending_shm_addr, uut.pending_shm_data);
        end
        
        if (shm_write_req) begin
            $display("@%t: SHM WRITE REQ - addr=%h, data=%h", $time, shm_write_addr, shm_write_data);
        end
    end

    // Test sequence
    initial begin
        $display("Starting Simple Shared Memory Test");
        
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
        #10 reset = 0;
        #20 reset = 1;
        #10;
        
        $display("\n=== Write to CR Register ===");
        @(negedge clk);
        cpu_addr = {ethernet_base, 8'h00, 4'h0, 2'b00}; // CR register at offset 0x00
        cpu_data_in = 16'h2100;  // Keep same CR value
        sel_ethernet = 1;
        cpu_hwr = 0;
        cpu_lwr = 0;
        cpu_uds = 0;
        cpu_lds = 0;
        
        // Hold for multiple cycles
        repeat(3) @(posedge clk);
        
        @(negedge clk);
        cpu_hwr = 1;
        cpu_lwr = 1;
        sel_ethernet = 0;
        
        // Wait for state machine and check if pending gets set
        repeat(15) @(posedge clk);
        
        $display("\n=== Test Complete ===");
        $finish;
    end

endmodule