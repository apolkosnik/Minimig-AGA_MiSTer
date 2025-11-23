//------------------------------------------------------------------------------
// MC68060 Effective Address Calculation Unit
// Handles all MC68000 addressing modes
//------------------------------------------------------------------------------

module MC68060_EffectiveAddress
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    // Addressing mode and register from instruction
    input  wire [2:0]  ea_mode,        // Addressing mode
    input  wire [2:0]  ea_reg,         // Register number
    input  wire [1:0]  ea_size,        // 00=byte, 01=word, 10=long

    // Extension words for complex modes
    input  wire [15:0] extension1,     // First extension word (displacement/index)
    input  wire [15:0] extension2,     // Second extension word (for absolute long)

    // Register file access
    input  wire [31:0] areg_value,     // Value from address register An
    input  wire [31:0] dreg_value,     // Value from data register Dn (for index)

    // PC for PC-relative modes
    input  wire [31:0] pc_in,

    // Outputs
    output reg  [31:0] ea_out,         // Calculated effective address
    output reg         ea_is_areg,     // EA is address register direct
    output reg         ea_is_dreg,     // EA is data register direct
    output reg  [3:0]  ea_reg_num,     // Register number (extended to 4 bits)

    // Register update for (An)+/-(An)
    output reg         areg_update,    // Address register needs update
    output reg  [3:0]  areg_update_num,// Which address register to update
    output reg  [31:0] areg_update_val,// New value for address register

    output reg         valid_out
);

// MC68000 addressing modes
localparam MODE_DREG_DIRECT    = 3'b000;  // Dn
localparam MODE_AREG_DIRECT    = 3'b001;  // An
localparam MODE_AREG_INDIRECT  = 3'b010;  // (An)
localparam MODE_AREG_POSTINC   = 3'b011;  // (An)+
localparam MODE_AREG_PREDEC    = 3'b100;  // -(An)
localparam MODE_AREG_DISP      = 3'b101;  // d16(An)
localparam MODE_AREG_INDEX     = 3'b110;  // d8(An,Xn)
localparam MODE_SPECIAL        = 3'b111;  // Special modes (abs, PC-rel, imm)

// Special mode sub-modes (when ea_mode == 111)
localparam SPECIAL_ABS_SHORT   = 3'b000;  // xxx.W
localparam SPECIAL_ABS_LONG    = 3'b001;  // xxx.L
localparam SPECIAL_PC_DISP     = 3'b010;  // d16(PC)
localparam SPECIAL_PC_INDEX    = 3'b011;  // d8(PC,Xn)
localparam SPECIAL_IMMEDIATE   = 3'b100;  // #<data>

// Size increment for postincrement/predecrement
wire [31:0] size_increment = (ea_size == 2'b00) ? 32'd1 :   // Byte
                             (ea_size == 2'b01) ? 32'd2 :   // Word
                                                  32'd4;    // Long

// Sign-extended displacement from extension word
wire [31:0] displacement_16 = {{16{extension1[15]}}, extension1[15:0]};
wire [31:0] displacement_8  = {{24{extension1[7]}}, extension1[7:0]};

// Index register value (from extension word bit 15: 0=Dn, 1=An)
wire        index_is_areg = extension1[15];
wire [2:0]  index_reg_num = extension1[14:12];
wire        index_long    = extension1[11];  // 0=word, 1=long
wire [31:0] index_value   = index_long ? dreg_value : {{16{dreg_value[15]}}, dreg_value[15:0]};

// Absolute addresses
wire [31:0] abs_short = {{16{extension1[15]}}, extension1[15:0]};
wire [31:0] abs_long  = {extension1[15:0], extension2[15:0]};

always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        ea_out <= 32'h0;
        ea_is_areg <= 1'b0;
        ea_is_dreg <= 1'b0;
        ea_reg_num <= 4'h0;
        areg_update <= 1'b0;
        areg_update_num <= 4'h0;
        areg_update_val <= 32'h0;
        valid_out <= 1'b0;
    end else if (enable) begin
        // Default: no register update
        areg_update <= 1'b0;
        areg_update_num <= 4'h0;
        areg_update_val <= 32'h0;
        ea_is_areg <= 1'b0;
        ea_is_dreg <= 1'b0;
        valid_out <= 1'b1;

        case (ea_mode)
            MODE_DREG_DIRECT: begin
                // Data register direct - no memory access
                ea_out <= dreg_value;
                ea_is_dreg <= 1'b1;
                ea_reg_num <= {1'b0, ea_reg};  // D0-D7 (registers 0-7)
            end

            MODE_AREG_DIRECT: begin
                // Address register direct - no memory access
                ea_out <= areg_value;
                ea_is_areg <= 1'b1;
                ea_reg_num <= {1'b1, ea_reg};  // A0-A7 (registers 8-15)
            end

            MODE_AREG_INDIRECT: begin
                // Address register indirect: (An)
                ea_out <= areg_value;
            end

            MODE_AREG_POSTINC: begin
                // Address register indirect with postincrement: (An)+
                ea_out <= areg_value;
                // Update register AFTER use
                areg_update <= 1'b1;
                areg_update_num <= {1'b1, ea_reg};
                areg_update_val <= areg_value + size_increment;
            end

            MODE_AREG_PREDEC: begin
                // Address register indirect with predecrement: -(An)
                // Update register BEFORE use
                areg_update <= 1'b1;
                areg_update_num <= {1'b1, ea_reg};
                areg_update_val <= areg_value - size_increment;
                ea_out <= areg_value - size_increment;
            end

            MODE_AREG_DISP: begin
                // Address register indirect with displacement: d16(An)
                ea_out <= areg_value + displacement_16;
            end

            MODE_AREG_INDEX: begin
                // Address register indirect with index: d8(An,Xn)
                ea_out <= areg_value + displacement_8 + index_value;
            end

            MODE_SPECIAL: begin
                // Special modes - determined by ea_reg field
                case (ea_reg)
                    SPECIAL_ABS_SHORT: begin
                        // Absolute short address: xxx.W
                        ea_out <= abs_short;
                    end

                    SPECIAL_ABS_LONG: begin
                        // Absolute long address: xxx.L
                        ea_out <= abs_long;
                    end

                    SPECIAL_PC_DISP: begin
                        // PC relative with displacement: d16(PC)
                        ea_out <= pc_in + displacement_16;
                    end

                    SPECIAL_PC_INDEX: begin
                        // PC relative with index: d8(PC,Xn)
                        ea_out <= pc_in + displacement_8 + index_value;
                    end

                    SPECIAL_IMMEDIATE: begin
                        // Immediate data: #<data>
                        // For immediate, extension word contains the data
                        if (ea_size == 2'b00 || ea_size == 2'b01) begin
                            // Byte or word
                            ea_out <= {16'h0, extension1};
                        end else begin
                            // Long - use both extension words
                            ea_out <= {extension1, extension2};
                        end
                        ea_is_dreg <= 1'b1;  // Treat as register direct (no memory access)
                    end

                    default: begin
                        ea_out <= 32'h0;
                    end
                endcase
            end

            default: begin
                ea_out <= 32'h0;
            end
        endcase
    end else begin
        valid_out <= 1'b0;
    end
end

endmodule
