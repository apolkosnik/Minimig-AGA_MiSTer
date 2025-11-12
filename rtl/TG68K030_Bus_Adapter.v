//--------------------------------------------------------------------------//
//--------------------------------------------------------------------------//
//                                                                          //
// TG68K030 Bus Width Adapter                                               //
//                                                                          //
// Converts between 32-bit TG68K030 bus and 16-bit Minimig system bus      //
//                                                                          //
// Features:                                                                //
//   - Byte, word, and long word transfer support                          //
//   - Automatic data routing based on address and size                    //
//   - Two-cycle long word transfers (split into 2x16-bit)                 //
//   - Proper UDS/LDS generation                                            //
//   - Transparent pass-through for byte/word operations                   //
//                                                                          //
// Author: Claude (Anthropic AI)                                            //
// Date: 2025-11-11                                                         //
//                                                                          //
//--------------------------------------------------------------------------//
//--------------------------------------------------------------------------//

module TG68K030_Bus_Adapter
(
    input             clk,
    input             reset,

    // 32-bit CPU side (TG68K030)
    input      [31:0] cpu_addr,        // CPU address
    input      [31:0] cpu_data_write,  // CPU write data
    output reg [31:0] cpu_data_read,   // CPU read data
    input             cpu_as,           // CPU address strobe (active low)
    input             cpu_write,        // CPU write (0=read, 1=write)
    input       [1:0] cpu_size,         // CPU transfer size (00=byte, 01=word, 10=long)
    output reg        cpu_dtack,        // CPU data acknowledge (active low)

    // 16-bit System side (Minimig)
    output reg [31:0] sys_addr,        // System address
    output reg [15:0] sys_data_write,  // System write data
    input      [15:0] sys_data_read,   // System read data
    output reg        sys_as,           // System address strobe (active low)
    output reg        sys_uds,          // System upper data strobe (active low)
    output reg        sys_lds,          // System lower data strobe (active low)
    output reg        sys_rw,           // System read/write (0=write, 1=read)
    input             sys_dtack         // System data acknowledge (active low)
);

//--------------------------------------------------------------------------
// State Machine
//--------------------------------------------------------------------------

localparam IDLE         = 3'b000;
localparam LONG_UPPER   = 3'b001;
localparam LONG_WAIT    = 3'b010;  // Wait for dtack deassert between long word cycles
localparam LONG_LOWER   = 3'b011;
localparam WAIT_READY   = 3'b100;

reg [2:0] state;
reg [15:0] data_buffer;  // Buffer for long word upper 16 bits

//--------------------------------------------------------------------------
// Data Routing - Write Path
//--------------------------------------------------------------------------

always @(*) begin
    case (state)
        IDLE, WAIT_READY: begin
            case (cpu_size)
                2'b00: begin // Byte
                    case (cpu_addr[1:0])
                        2'b00: sys_data_write = {cpu_data_write[31:24], 8'h00};
                        2'b01: sys_data_write = {8'h00, cpu_data_write[23:16]};
                        2'b10: sys_data_write = {cpu_data_write[15:8], 8'h00};
                        2'b11: sys_data_write = {8'h00, cpu_data_write[7:0]};
                    endcase
                end
                2'b01: begin // Word
                    sys_data_write = cpu_addr[1] ? cpu_data_write[15:0] : cpu_data_write[31:16];
                end
                default: sys_data_write = 16'h0000;
            endcase
        end

        LONG_UPPER: begin
            sys_data_write = cpu_data_write[31:16]; // Upper word
        end

        LONG_WAIT: begin
            sys_data_write = cpu_data_write[15:0];  // Prepare lower word during wait
        end

        LONG_LOWER: begin
            sys_data_write = cpu_data_write[15:0];  // Lower word
        end
    endcase
end

//--------------------------------------------------------------------------
// Data Routing - Read Path
//--------------------------------------------------------------------------

always @(*) begin
    if (state == LONG_LOWER && sys_dtack == 1'b0) begin
        // Complete long word read
        cpu_data_read = {data_buffer, sys_data_read};
    end
    else begin
        case (cpu_size)
            2'b00: begin // Byte
                case (cpu_addr[1:0])
                    2'b00: cpu_data_read = {sys_data_read[15:8], 24'h000000};
                    2'b01: cpu_data_read = {8'h00, sys_data_read[7:0], 16'h0000};
                    2'b10: cpu_data_read = {16'h0000, sys_data_read[15:8], 8'h00};
                    2'b11: cpu_data_read = {24'h000000, sys_data_read[7:0]};
                endcase
            end
            2'b01: begin // Word
                cpu_data_read = cpu_addr[1] ? {16'h0000, sys_data_read} : {sys_data_read, 16'h0000};
            end
            2'b10: begin // Long
                cpu_data_read = {data_buffer, sys_data_read};
            end
            default: cpu_data_read = 32'h00000000;
        endcase
    end
end

//--------------------------------------------------------------------------
// UDS/LDS Generation
//--------------------------------------------------------------------------

always @(*) begin
    sys_uds = 1'b1;  // Default: inactive (active low)
    sys_lds = 1'b1;

    if (sys_as == 1'b0) begin
        case (state)
            IDLE, WAIT_READY: begin
                case (cpu_size)
                    2'b00: begin // Byte
                        case (cpu_addr[1:0])
                            2'b00: sys_uds = 1'b0;       // Upper byte of first word
                            2'b01: sys_lds = 1'b0;       // Lower byte of first word
                            2'b10: sys_uds = 1'b0;       // Upper byte of second word
                            2'b11: sys_lds = 1'b0;       // Lower byte of second word
                        endcase
                    end
                    2'b01: begin // Word
                        sys_uds = 1'b0;
                        sys_lds = 1'b0;
                    end
                    default: begin
                        sys_uds = 1'b1;
                        sys_lds = 1'b1;
                    end
                endcase
            end

            LONG_UPPER, LONG_LOWER: begin
                // Both strobes for long word transfers
                sys_uds = 1'b0;
                sys_lds = 1'b0;
            end

            LONG_WAIT: begin
                // No strobes during wait state
                sys_uds = 1'b1;
                sys_lds = 1'b1;
            end
        endcase
    end
end

//--------------------------------------------------------------------------
// State Machine
//--------------------------------------------------------------------------

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        cpu_dtack <= 1'b1;  // Inactive (active low)
        sys_as <= 1'b1;
        sys_rw <= 1'b1;
        sys_addr <= 32'h00000000;
        data_buffer <= 16'h0000;
    end
    else begin
        case (state)
            IDLE: begin
                cpu_dtack <= 1'b1;
                sys_as <= 1'b1;

                if (cpu_as == 1'b0) begin  // CPU requests transfer
                    sys_as <= 1'b0;
                    sys_rw <= ~cpu_write;
                    sys_addr <= cpu_addr;

                    if (cpu_size == 2'b10) begin
                        // Long word - requires 2 cycles
                        state <= LONG_UPPER;
                    end
                    else begin
                        // Byte or word - single cycle
                        state <= WAIT_READY;
                    end
                end
            end

            LONG_UPPER: begin
                if (sys_dtack == 1'b0) begin
                    // Upper word complete
                    if (cpu_write == 1'b0) begin
                        // Read: save upper 16 bits
                        data_buffer <= sys_data_read;
                    end

                    // Deassert AS and wait for dtack to go high
                    sys_as <= 1'b1;
                    state <= LONG_WAIT;
                end
            end

            LONG_WAIT: begin
                // Wait for dtack to deassert before starting second transfer
                if (sys_dtack == 1'b1) begin
                    // dtack deasserted, start second transfer
                    sys_addr <= sys_addr + 32'd2;  // Increment address by 2
                    sys_as <= 1'b0;                 // Assert AS for second cycle
                    state <= LONG_LOWER;
                end
            end

            LONG_LOWER: begin
                if (sys_dtack == 1'b0) begin
                    // Lower word complete
                    // For reads, data_buffer[15:0] + sys_data_read[15:0] = full 32-bit
                    cpu_dtack <= 1'b0;  // Signal CPU completion
                    sys_as <= 1'b1;     // De-assert system AS
                    state <= IDLE;
                end
            end

            WAIT_READY: begin
                if (sys_dtack == 1'b0) begin
                    // Transfer complete
                    cpu_dtack <= 1'b0;
                    sys_as <= 1'b1;
                    state <= IDLE;
                end
            end
        endcase

        // Return to idle when CPU deasserts AS
        if (cpu_as == 1'b1 && state != IDLE) begin
            state <= IDLE;
            cpu_dtack <= 1'b1;
            sys_as <= 1'b1;
        end
    end
end

endmodule
