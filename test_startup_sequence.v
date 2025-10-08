// WF68K30L Startup Sequence Test
// Verifies reset, chipram access, DSACK, and initial vector fetch

`timescale 1ns/1ps

module test_startup_sequence();

// Clock and reset
reg clk = 0;
reg reset = 1;
always #17.6 clk = ~clk; // 28.375 MHz

// Signals from cpu_wrapper
wire [31:0] chip_addr;
wire [31:0] chip_dout;
reg  [31:0] chip_din;
wire        chip_as;
wire        chip_uds;
wire        chip_lds;
wire        chip_rw;
reg         chip_dtack = 1; // Active low

// RAM interface
reg  [31:0] ram_dout = 32'h00000000;
reg         ram_ready = 0;

// Configuration
reg [1:0] cpucfg = 2'b11; // WF68K30L
reg [2:0] cachecfg = 3'b000;
reg [2:0] fastramcfg = 3'b000;
reg       bootrom = 0;

// Test memory - initial vectors
reg [31:0] boot_memory [0:7];
initial begin
    boot_memory[0] = 32'h00001000; // Initial SSP
    boot_memory[1] = 32'h00000400; // Initial PC
    boot_memory[2] = 32'hDEADBEEF;
    boot_memory[3] = 32'hCAFEBABE;
end

// Instantiate cpu_wrapper
cpu_wrapper dut (
    .reset(reset),
    .clk(clk),
    .ph1(1'b0),
    .ph2(1'b0),

    .cpucfg(cpucfg),
    .cachecfg(cachecfg),
    .fastramcfg(fastramcfg),
    .bootrom(bootrom),

    .chip_addr(chip_addr),
    .chip_dout(chip_dout),
    .chip_din(chip_din),
    .chip_as(chip_as),
    .chip_uds(chip_uds),
    .chip_lds(chip_lds),
    .chip_rw(chip_rw),
    .chip_dtack(chip_dtack),
    .chip_ipl(3'b111),

    .ramsel(),
    .ramaddr(),
    .ramdin(),
    .ramdout(ram_dout),
    .ramlds(),
    .ramuds(),
    .ramready(ram_ready),
    .ramshared(),

    .fastchip_dout(32'h0),
    .fastchip_sel(),
    .fastchip_lds(),
    .fastchip_uds(),
    .fastchip_rnw(),
    .fastchip_selack(1'b0),
    .fastchip_ready(1'b0),
    .fastchip_lw(),

    .nmi_addr(32'h0000007C),
    .cpustate(),
    .cacr(),
    .cpu_longword()
);

// Simulate chipram response
always @(posedge clk) begin
    if (~chip_as) begin
        // Address strobe active - memory access
        chip_dtack <= #30 0; // Assert after 30ns
        chip_din <= boot_memory[chip_addr[4:2]];
    end else begin
        chip_dtack <= 1;
    end
end

// Test sequence
integer cycle = 0;
initial begin
    $dumpfile("startup.vcd");
    $dumpvars(0, test_startup_sequence);

    $display("=== WF68K30L Startup Test ===");
    $display("Time\tReset\tAS\tAddr\t\tData\t\tDTACK\tState");

    // Hold reset for 100ns
    #100;
    reset = 0;
    $display("%0t\tReset released", $time);

    // Monitor for 2000ns
    repeat(100) begin
        @(posedge clk);
        cycle = cycle + 1;
        if (~chip_as) begin
            $display("%0t\t%b\t%b\t%08h\t%08h\t%b\tCycle %0d",
                     $time, reset, chip_as, chip_addr, chip_din, chip_dtack, cycle);
        end
    end

    $display("\n=== Test Complete ===");
    $finish;
end

// Timeout watchdog
initial begin
    #5000;
    $display("ERROR: Test timeout!");
    $finish;
end

endmodule
