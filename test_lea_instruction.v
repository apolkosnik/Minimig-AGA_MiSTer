`timescale 1ns / 1ps

module test_lea_instruction;

// Clock and reset
reg clk;
reg reset;

// TG68K interface signals
wire [31:0] cpu_addr;
wire [15:0] cpu_data_out;
reg  [15:0] cpu_data_in;
wire        cpu_as;
wire        cpu_uds;
wire        cpu_lds;
wire        cpu_rw;
wire [2:0]  cpu_fc;
wire [2:0]  cpu_state;
wire        cpu_reset_out;
reg         cpu_dtack;
reg  [2:0]  cpu_ipl;

// Clock generation
initial begin
    clk = 0;
    forever #10 clk = ~clk; // 50MHz clock
end

// Instantiate TG68K CPU
TG68K cpu_inst (
    .clk(clk),
    .reset(~reset),
    .clkena_in(1'b1),
    .data_in(cpu_data_in),
    .IPL(cpu_ipl),
    .dtack(cpu_dtack),
    .addr(cpu_addr),
    .data_out(cpu_data_out),
    .as(cpu_as),
    .uds(cpu_uds),
    .lds(cpu_lds),
    .rw(cpu_rw),
    .drive_data(),
    .wr(),
    .wr_high(),
    .fc(cpu_fc)
);

// Memory array for test
reg [15:0] memory [0:1023];

// Handle memory reads
always @(posedge clk) begin
    if (~cpu_as && cpu_rw) begin
        cpu_data_in <= memory[cpu_addr[10:1]];
        cpu_dtack <= 1'b0;
    end else begin
        cpu_dtack <= 1'b1;
    end
end

// Test stimulus
initial begin
    $dumpfile("test_lea.vcd");
    $dumpvars(0, test_lea_instruction);
    
    // Initialize
    reset = 1'b0;
    cpu_ipl = 3'b111;
    cpu_dtack = 1'b1;
    
    // Clear memory
    for (integer i = 0; i < 1024; i = i + 1) begin
        memory[i] = 16'h0000;
    end
    
    // Set up reset vector
    memory[0] = 16'h0000; // Initial SSP high
    memory[1] = 16'h0400; // Initial SSP low = $00000400
    memory[2] = 16'h0000; // Initial PC high
    memory[3] = 16'h0100; // Initial PC low = $00000100
    
    // Place LEA $2000,A7 instruction at $100
    // LEA opcode: 0100 1111 11 111 001 = 0x4FF9
    // Absolute long addressing: $2000 as 32-bit
    memory[16'h80] = 16'h4FF9; // LEA.L $xxxx,A7
    memory[16'h81] = 16'h0000; // High word of address
    memory[16'h82] = 16'h2000; // Low word of address = $2000
    
    // Reset sequence
    #100 reset = 1'b1;
    #200 reset = 1'b0;
    #100 reset = 1'b1;
    
    // Wait for instruction execution
    #1000;
    
    // Check results
    $display("Test completed");
    $display("A7 should be $00002000");
    
    #100 $finish;
end

// Monitor CPU state
always @(posedge clk) begin
    if (cpu_as == 1'b0 && cpu_rw == 1'b0) begin
        $display("Time %t: Write to %08X = %04X", $time, cpu_addr, cpu_data_out);
    end
    if (cpu_as == 1'b0 && cpu_rw == 1'b1) begin
        $display("Time %t: Read from %08X = %04X", $time, cpu_addr, cpu_data_in);
    end
end

endmodule