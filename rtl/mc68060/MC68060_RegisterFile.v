//------------------------------------------------------------------------------
// MC68060 Register File
// Contains D0-D7 (data registers) and A0-A7 (address registers)
// Dual-port read, single-port write with forwarding
//------------------------------------------------------------------------------

module MC68060_RegisterFile
(
    input  wire        clk,
    input  wire        nreset,

    // Read port 1
    input  wire [2:0]  read_addr1,
    output reg  [31:0] read_data1,

    // Read port 2
    input  wire [2:0]  read_addr2,
    output reg  [31:0] read_data2,

    // Write port
    input  wire [2:0]  write_addr,
    input  wire [31:0] write_data,
    input  wire        write_enable
);

// Register file: 8 data registers (D0-D7) + 8 address registers (A0-A7)
// For simplicity, we treat them as a unified 16-register file
// In a real implementation, we'd separate D and A registers
reg [31:0] registers [0:15];

integer i;

// Asynchronous read with forwarding
always @(*) begin
    if (write_enable && (read_addr1 == write_addr))
        read_data1 = write_data;  // Forwarding
    else
        read_data1 = registers[read_addr1];
end

always @(*) begin
    if (write_enable && (read_addr2 == write_addr))
        read_data2 = write_data;  // Forwarding
    else
        read_data2 = registers[read_addr2];
end

// Synchronous write
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        for (i = 0; i < 16; i = i + 1) begin
            registers[i] <= 32'h0;
        end
    end else if (write_enable) begin
        registers[write_addr] <= write_data;
    end
end

endmodule
