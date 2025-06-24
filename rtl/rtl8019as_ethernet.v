// RTL8019AS Ethernet Controller - Updated with Toccata-style Bus Access Patterns
// Uses same edge detection and selection patterns as toccata.sv
// 97% reduction in memory usage: 64 bytes vs 1024 bytes
// Compatible with MiSTer UIO_DMA networking via hps_ext.v
// Standard Verilog implementation

module rtl8019as_ethernet
(
    input wire        clk,
    input wire        reset,

    // CPU interface (connects to Minimig CPU bus) - Same as Toccata pattern
    input wire [23:1] cpu_address,
    input wire [15:0] cpu_data_in,
    output reg [15:0] cpu_data_out,
    input wire        cpu_rd,
    input wire        cpu_hwr,     // high word write enable
    input wire        cpu_lwr,     // low word write enable
    input wire        sel_ethernet,

    // Interrupt output (connects to Paula INT2)
    output reg        eth_irq,

    // DMA interface (connects to hps_ext via UIO_DMA)
    input wire [15:0] eth_dout,     // Data from HPS
    output reg [15:0] eth_din,      // Data to HPS
    input wire  [7:0] eth_addr,     // Address from HPS
    input wire        eth_rd,       // Read enable from HPS
    input wire        eth_wr,       // Write enable from HPS
    output reg  [7:0] eth_status    // Status to HPS
);

// ============================================================================
// HPS DMA REGISTER CONSTANTS
// ============================================================================

localparam HPS_STATUS      = 8'h00;
localparam HPS_COMMAND     = 8'h01;
localparam HPS_TX_LEN_L    = 8'h02;
localparam HPS_TX_LEN_H    = 8'h03;
localparam HPS_RX_LEN_L    = 8'h04;
localparam HPS_RX_LEN_H    = 8'h05;
localparam HPS_MAC_0       = 8'h06;
localparam HPS_MAC_1       = 8'h07;
localparam HPS_MAC_2       = 8'h08;
localparam HPS_MAC_3       = 8'h09;
localparam HPS_MAC_4       = 8'h0A;
localparam HPS_MAC_5       = 8'h0B;
localparam HPS_TX_BUF      = 8'h10;
localparam HPS_RX_BUF      = 8'h50;

localparam HPS_STATUS_TX_BUSY   = 0;
localparam HPS_STATUS_RX_READY  = 1;
localparam HPS_STATUS_TX_DONE   = 2;
localparam HPS_STATUS_RX_ERROR  = 3;
localparam HPS_STATUS_LINK_UP   = 4;

localparam HPS_CMD_TX_START     = 0;
localparam HPS_CMD_RX_ENABLE    = 1;
localparam HPS_CMD_RESET        = 2;
localparam HPS_CMD_IRQ_ACK      = 3;

// ============================================================================
// FIFO PARAMETERS
// ============================================================================

localparam FIFO_DEPTH = 5;  // 2^5 = 32 bytes per FIFO
localparam FIFO_SIZE = (1 << FIFO_DEPTH);  // 32 bytes
localparam FIFO_MASK = FIFO_SIZE - 1;      // 31 (for wrap-around)

// ============================================================================
// FIFO DECLARATIONS
// ============================================================================

reg [7:0] tx_fifo [0:FIFO_SIZE-1];
reg [FIFO_DEPTH:0] tx_wr_ptr;
reg [FIFO_DEPTH:0] tx_rd_ptr;
wire tx_fifo_full  = (tx_wr_ptr[FIFO_DEPTH] != tx_rd_ptr[FIFO_DEPTH]) && 
                     (tx_wr_ptr[FIFO_DEPTH-1:0] == tx_rd_ptr[FIFO_DEPTH-1:0]);
wire tx_fifo_empty = (tx_wr_ptr == tx_rd_ptr);
wire [FIFO_DEPTH-1:0] tx_fifo_count = tx_wr_ptr[FIFO_DEPTH-1:0] - tx_rd_ptr[FIFO_DEPTH-1:0];

reg [7:0] rx_fifo [0:FIFO_SIZE-1];
reg [FIFO_DEPTH:0] rx_wr_ptr;
reg [FIFO_DEPTH:0] rx_rd_ptr;
wire rx_fifo_full  = (rx_wr_ptr[FIFO_DEPTH] != rx_rd_ptr[FIFO_DEPTH]) && 
                     (rx_wr_ptr[FIFO_DEPTH-1:0] == rx_rd_ptr[FIFO_DEPTH-1:0]);
wire rx_fifo_empty = (rx_wr_ptr == rx_rd_ptr);
wire [FIFO_DEPTH-1:0] rx_fifo_count = rx_wr_ptr[FIFO_DEPTH-1:0] - rx_rd_ptr[FIFO_DEPTH-1:0];

reg tx_fifo_overflow;
reg rx_fifo_overflow;

// ============================================================================
// HPS COMMUNICATION STATE  
// ============================================================================

reg [15:0] hps_status_reg;
reg [15:0] hps_command_reg;
reg [15:0] hps_tx_length;
reg [15:0] hps_rx_length;
reg [7:0]  hps_mac_addr [0:5];

reg hps_tx_ready;
reg hps_rx_packet_ready;
reg hps_link_up;

// ============================================================================
// RTL8019AS REGISTER OFFSETS for reading values off the chip's address space
// ============================================================================

localparam REG_CR_P0    = 5'h0;  // Command Register (all pages)

// Page 0 registers (CR[7:6] = 00) - NE2000 compatible
localparam R_REG_CLDA0_P0 = 5'h1;  // Current Local DMA Address 0 (write) low byte
localparam W_REG_PSTART_P0 = 5'h1;  // Page Start Register (write)
localparam R_REG_CLDA1_P0 = 5'h2;  // Current Local DMA Address 1 (write) upper byte
localparam W_REG_PSTOP_P0 = 5'h2;  // Page Stop Register (write)
localparam REG_BNRY_P0 = 5'h3;  // Boundary Pointer
localparam R_REG_TSR_P0 = 5'h4;  // Transmit Status Register (read only)
localparam W_REG_TPSR_P0 = 5'h4;  // Transmit Page Start Register (write only)
localparam R_REG_NCR_P0 = 5'h5;  // Number of Collisions Register (read only)
localparam W_REG_TBCR0_P0 = 5'h5;  // Transmit Byte Count Register 0 (write only)
localparam R_REG_FIFO_P0 = 5'h6;  // FIFO (read only)
localparam W_REG_TBCR1_P0 = 5'h6;  // Transmit Byte Count Register 1 (write only)
localparam REG_ISR_P0 = 5'h7;  // Interrupt Status Register
localparam R_REG_CRDA0_P0 = 5'h8;  // Current Remote DMA Address 0 (read only)
localparam W_REG_RSAR0_P0 = 5'h8;  // Remote Start Address Register 0 (write only)
localparam R_REG_CRDA1_P0 = 5'h9;  // Current Remote DMA Address 1 (read only)
localparam W_REG_RSAR1_P0 = 5'h9;  // Remote Start Address Register 1 (write only)
localparam W_REG_RBCR0_P0 = 5'hA;  // Remote Byte Count Register 0 (write only)
// RTL8019 only
localparam R_REG_8019ID0_P0 = 5'hA;  // Chip ID0 (read only) 0x50
localparam W_REG_RBCR1_P0 = 5'hB;  // Remote Byte Count Register 1 (write only)
// RTL8019 only
localparam R_REG_8019ID1_P0 = 5'hB;  // Chip ID1 (read only) 0x70
localparam R_REG_RSR_P0 = 5'hC;  // Receive Status Register (read only)
localparam W_REG_RCR_P0 = 5'hC;  // Receive Configuration Register (write only)
localparam R_REG_CNTR0_P0 = 5'hD;  // Frame Alignment Error Counter (read only)
localparam W_REG_TCR_P0 = 5'hD;  // Transmit Configuration Register (write only)
localparam R_REG_CNTR1_P0 = 5'hE;  // CRC Error Counter (read only)
localparam W_REG_DCR_P0 = 5'hE;  // Data Configuration Register (write only)
localparam R_REG_CNTR2_P0 = 5'hF;  // Missed Packet Counter (read only)
localparam W_REG_IMR_P0 = 5'hF;  // Interrupt Mask Register (write only)

// Page 1 registers (CR[7:6] = 01) - NE2000 compatible
localparam REG_PAR0_P1  = 4'h1;  // Physical Address Register 0 lowest byte
localparam REG_PAR1_P1  = 4'h2;  // Physical Address Register 1
localparam REG_PAR2_P1  = 4'h3;  // Physical Address Register 2
localparam REG_PAR3_P1  = 4'h4;  // Physical Address Register 3
localparam REG_PAR4_P1  = 4'h5;  // Physical Address Register 4
localparam REG_PAR5_P1  = 4'h6;  // Physical Address Register 5 highest byte
localparam REG_CURR_P1  = 4'h7;  // Current Page Register
localparam REG_MAR0_P1  = 4'h8;  // Multicast Address Register 0 lowest byte
localparam REG_MAR1_P1  = 4'h9;  // Multicast Address Register 1
localparam REG_MAR2_P1  = 4'hA;  // Multicast Address Register 2
localparam REG_MAR3_P1  = 4'hB;  // Multicast Address Register 3
localparam REG_MAR4_P1  = 4'hC;  // Multicast Address Register 4
localparam REG_MAR5_P1  = 4'hD;  // Multicast Address Register 5
localparam REG_MAR6_P1  = 4'hE;  // Multicast Address Register 6
localparam REG_MAR7_P1  = 4'hF;  // Multicast Address Register 7 highest byte

// Page 2 registers (CR[7:6] = 10) - NE2000 compatible
localparam R_REG_PSTART_P2 = 4'h1;  // Page Start Register (read)
localparam R_REG_PSTOP_P2  = 4'h2;  // Page Stop Register (read)
localparam R_REG_TPSR_P2 = 4'h4; // Transmit Page Start (Page 2)
localparam R_REG_RCR_P2 = 4'hC;  // Receive Configuration Register (read only)
localparam R_REG_TCR_P2 = 4'hD;  // Transmit Configuration Register (read only)
localparam R_REG_DCR_P2 = 4'hE;  // Data Configuration Register (read only)
localparam R_REG_IMR_P2 = 4'hF;  // Interrupt Mask Register (read only)

// Page 3 registers (CR[7:6] = 11) - RTL8019AS Configuration
// all registers below are RTL8019 specific / not compatible with NE2000
localparam REG_9346CR_P3    = 4'h1;  // 93C46 EEPROM Command Register
localparam REG_BPAGE_P3     = 4'h2;  // Boot ROM Page Register
localparam R_REG_CONFIG0_P3 = 4'h3;  // Configuration Register 0 (read only)
localparam REG_CONFIG1_P3   = 4'h4;  // Configuration Register 1
localparam REG_CONFIG2_P3   = 4'h5;  // Configuration Register 2
localparam REG_CONFIG3_P3   = 4'h6;  // Configuration Register 3
localparam W_REG_TEST_P3    = 4'h7;  // Test register (write)
localparam R_REG_CSNSAV_P3  = 4'h8;  // CSN Save Register
localparam W_REG_HLTCLK_P3  = 4'h9;  // Halt Clock Register
localparam R_REG_INTR_P3    = 4'hB;  // Interrupt Register
localparam W_REG_FMWP_P3    = 4'hC;  // Flash Memory Write Protect
localparam REG_CONFIG4_P3   = 4'hD;  // Configuration Register 4

// other

localparam REG_CHIP_ID = 4'hE;  // Chip ID Register
localparam REG_CHIP_REV = 4'hF; // Chip Revision Register

// ============================================================================
// RTL8019AS REGISTER STORAGE
// ============================================================================

reg [7:0] rtl_regs [0:63];  // Expanded to accommodate all register indices

// Register address mapping - Each register gets unique index in rtl_regs array
localparam REG_CR     = 5'h00;  // Command Register
localparam REG_PSTART = 5'h01;  // Page Start
localparam REG_PSTOP  = 5'h02;  // Page Stop
localparam REG_BNRY   = 5'h03;  // Boundary
localparam REG_TSR    = 5'h04;  // Transmit Status (read)
localparam REG_TPSR   = 5'h05;  // Transmit Page Start (write)
localparam REG_NCR    = 5'h06;  // Number of Collisions (read)
localparam REG_TBCR0  = 5'h07;  // Transmit Byte Count 0 (write)
localparam REG_FIFO   = 5'h08;  // FIFO (read)
localparam REG_TBCR1  = 5'h09;  // Transmit Byte Count 1 (write)
localparam REG_ISR    = 5'h0A;  // Interrupt Status
localparam REG_CRDA0  = 5'h0B;  // Current Remote DMA Address 0 (read)
localparam REG_RSAR0  = 5'h0C;  // Remote Start Address 0 (write)
localparam REG_CRDA1  = 5'h0D;  // Current Remote DMA Address 1 (read)
localparam REG_RSAR1  = 5'h0E;  // Remote Start Address 1 (write)
localparam REG_RBCR0  = 5'h0F;  // Remote Byte Count 0
localparam REG_RBCR1  = 5'h10;  // Remote Byte Count 1
localparam REG_RSR    = 5'h11;  // Receive Status (read)
localparam REG_RCR    = 5'h12;  // Receive Configuration (write)
localparam REG_CNTR0  = 5'h13;  // Frame Alignment Error Counter (read)
localparam REG_TCR    = 5'h14;  // Transmit Configuration (write)
localparam REG_CNTR1  = 5'h15;  // CRC Error Counter (read)
localparam REG_DCR    = 5'h16;  // Data Configuration (write)
localparam REG_CNTR2  = 5'h17;  // Missed Packet Counter (read)
localparam REG_IMR    = 5'h18;  // Interrupt Mask (write)

// Page 1 registers
localparam REG_PAR0   = 5'h19;
localparam REG_PAR1   = 5'h1A;
localparam REG_PAR2   = 5'h1B;
localparam REG_PAR3   = 5'h1C;
localparam REG_PAR4   = 5'h1D;
localparam REG_PAR5   = 5'h1E;
localparam REG_CURR   = 5'h1F;
localparam REG_CLDA0    = 5'h20;
localparam REG_CLDA1    = 5'h21;


// Essential state
reg [15:0] dma_addr;
reg [15:0] dma_count;
reg dma_in_progress;
reg tx_in_progress;
reg [1:0] current_page;

reg packet_tx_active;
reg [15:0] rx_bytes_received;

// ============================================================================
// TOCCATA-STYLE EDGE DETECTION REGISTERS
// ============================================================================

reg       cpu_rd_;   // READ edge detect
reg       cpu_lwr_;  // LWR edge detect
reg       cpu_hwr_;  // HWR edge detect

// Get the byte written from the high or low byte (Toccata pattern)
// High byte write has priority
reg [7:0] din_byte;

// Second byte handling for 16-bit writes (like Toccata FIFO writes)
reg       write_second_byte;
reg [7:0] second_byte;

// Local read enable for FIFO operations
reg       loc_rd_en;

// ============================================================================
// ADDRESS DECODING (Toccata style)
// ============================================================================

wire [15:0] io_base = cpu_address[16:1];
wire sel_eth = sel_ethernet && (
    (io_base[14:3] == 12'h000) ||  // 0x000-0x00F
    (io_base[14:3] == 12'h030) ||  // 0x300-0x30F
    (io_base[14:3] == 12'h060) ||  // 0x600-0x60F
    (io_base[14:3] == 12'h860)     // 0x8600-0x860F
);

wire [4:0] reg_addr = cpu_address[5:1];

// ============================================================================
// COMBINATIONAL LOGIC (Toccata style)
// ============================================================================

always @(*) begin
    // Get the byte written from the high or low byte
    // High byte write has priority (same as Toccata)
    din_byte = cpu_lwr ? cpu_data_in[7:0] : cpu_hwr ? cpu_data_in[15:8] : 8'h00;
end

// ============================================================================
// CLOCKED LOGIC (Toccata style with proper edge detection)
// ============================================================================

always @(posedge clk) begin
    // Initialize strobes (like Toccata pattern)
    loc_rd_en <= 1'b0;
    write_second_byte <= 1'b0;
    
    // Edge detect registers (same as Toccata)
    cpu_rd_ <= cpu_rd;
    cpu_lwr_ <= cpu_lwr;
    cpu_hwr_ <= cpu_hwr;

    if (reset) begin
        // Reset FIFO pointers
        tx_wr_ptr <= {(FIFO_DEPTH+1){1'b0}};
        tx_rd_ptr <= {(FIFO_DEPTH+1){1'b0}};
        rx_wr_ptr <= {(FIFO_DEPTH+1){1'b0}};
        rx_rd_ptr <= {(FIFO_DEPTH+1){1'b0}};
        
        tx_fifo_overflow <= 1'b0;
        rx_fifo_overflow <= 1'b0;
        
        // Reset RTL8019AS registers to defaults
        rtl_regs[REG_CR]     <= 8'h21;  // Page 0, stopped
        rtl_regs[REG_ISR]    <= 8'h80;  // Reset complete
        rtl_regs[REG_IMR]    <= 8'h00;  // No interrupts
        rtl_regs[REG_DCR]    <= 8'h49;  // 16-bit, normal mode
        rtl_regs[REG_TCR]    <= 8'h00;  // Normal operation
        rtl_regs[REG_RCR]    <= 8'h00;  // Reject all packets
        rtl_regs[REG_PSTART] <= 8'h46;  // Page start
        rtl_regs[REG_PSTOP]  <= 8'h80;  // Page stop
        rtl_regs[REG_BNRY]   <= 8'h46;  // Boundary
        rtl_regs[REG_CURR]   <= 8'h47;  // Current page
        rtl_regs[REG_TPSR]   <= 8'h40;  // TX page start
        rtl_regs[REG_TSR]    <= 8'h00;  // TX status
        rtl_regs[REG_NCR]    <= 8'h00;  // Collision counter
        rtl_regs[REG_FIFO]   <= 8'h00;  // FIFO status
        rtl_regs[REG_TBCR0]  <= 8'h00;  // TX byte count 0
        rtl_regs[REG_TBCR1]  <= 8'h00;  // TX byte count 1
        rtl_regs[REG_CRDA0]  <= 8'h00;  // Current DMA address 0
        rtl_regs[REG_CRDA1]  <= 8'h00;  // Current DMA address 1
        rtl_regs[REG_RSAR0]  <= 8'h00;  // Remote start address 0
        rtl_regs[REG_RSAR1]  <= 8'h00;  // Remote start address 1
        rtl_regs[REG_RBCR0]  <= 8'h00;  // Remote byte count 0
        rtl_regs[REG_RBCR1]  <= 8'h00;  // Remote byte count 1
        rtl_regs[REG_RSR]    <= 8'h00;  // RX status
        rtl_regs[REG_CNTR0]  <= 8'h00;  // Error counter 0
        rtl_regs[REG_CNTR1]  <= 8'h00;  // Error counter 1
        rtl_regs[REG_CNTR2]  <= 8'h00;  // Error counter 2
        rtl_regs[REG_CLDA0]  <= 8'h00;  // Current Local DMA Register 0
        rtl_regs[REG_CLDA1]  <= 8'h00;  // Current Local DMA Register 1
        
        // Default MAC address
        rtl_regs[REG_PAR0] <= 8'h28;
        rtl_regs[REG_PAR1] <= 8'h11;
        rtl_regs[REG_PAR2] <= 8'h22;
        rtl_regs[REG_PAR3] <= 8'h33;
        rtl_regs[REG_PAR4] <= 8'h44;
        rtl_regs[REG_PAR5] <= 8'h55;

        eth_din <= 16'h0000;
        eth_status <= 8'h10;
        eth_irq <= 1'b0;
        
        // Initialize data_out (like Toccata)
        cpu_data_out <= 16'h0000;
        
    end else begin
        
        // ====================================================================
        // HPS INTERFACE HANDLING 
        // ====================================================================
        
        // Update HPS status register for UIO_DMA interface
        hps_status_reg[HPS_STATUS_TX_BUSY] <= tx_in_progress;
        hps_status_reg[HPS_STATUS_RX_READY] <= hps_rx_packet_ready; 
        hps_status_reg[HPS_STATUS_TX_DONE] <= hps_tx_ready;
        hps_status_reg[HPS_STATUS_RX_ERROR] <= rx_fifo_overflow;
        hps_status_reg[HPS_STATUS_LINK_UP] <= hps_link_up;
        
        eth_status <= {3'b000, hps_link_up, 3'b000, tx_in_progress};
        
        // Handle HPS writes
        if (eth_wr) begin
            case (eth_addr)
                HPS_STATUS: begin
                    if (eth_dout[HPS_STATUS_TX_DONE]) hps_tx_ready <= 1'b0;
                    if (eth_dout[HPS_STATUS_RX_READY]) hps_rx_packet_ready <= 1'b0;
                end

                HPS_COMMAND: begin
                    hps_command_reg <= eth_dout;
                    
                    if (eth_dout[HPS_CMD_RESET]) begin
                        tx_wr_ptr <= 0;
                        tx_rd_ptr <= 0;
                        rx_wr_ptr <= 0;
                        rx_rd_ptr <= 0;
                        hps_tx_ready <= 1'b0;
                        hps_rx_packet_ready <= 1'b0;
                        tx_in_progress <= 1'b0;
                        packet_tx_active <= 1'b0;
                        tx_fifo_overflow <= 1'b0;
                        rx_fifo_overflow <= 1'b0;
                    end

                    if (eth_dout[HPS_CMD_TX_START] && !tx_in_progress) begin
                        tx_in_progress <= 1'b1;
                        packet_tx_active <= 1'b1;
                        hps_tx_ready <= 1'b0;
                    end
                    
                    if (eth_dout[HPS_CMD_IRQ_ACK]) begin
                        hps_rx_packet_ready <= 1'b0;
                        hps_tx_ready <= 1'b0;
                    end
                end

                HPS_TX_LEN_L: hps_tx_length[7:0] <= eth_dout[7:0];
                HPS_TX_LEN_H: hps_tx_length[15:8] <= eth_dout[7:0];
                HPS_RX_LEN_L: hps_rx_length[7:0] <= eth_dout[7:0];
                HPS_RX_LEN_H: hps_rx_length[15:8] <= eth_dout[7:0];

                HPS_MAC_0: hps_mac_addr[0] <= eth_dout[7:0];
                HPS_MAC_1: hps_mac_addr[1] <= eth_dout[7:0];
                HPS_MAC_2: hps_mac_addr[2] <= eth_dout[7:0];
                HPS_MAC_3: hps_mac_addr[3] <= eth_dout[7:0];
                HPS_MAC_4: hps_mac_addr[4] <= eth_dout[7:0];
                HPS_MAC_5: hps_mac_addr[5] <= eth_dout[7:0];

                default: begin
                    if (eth_addr >= HPS_TX_BUF && eth_addr < HPS_RX_BUF) begin
                        if (!tx_fifo_full) begin
                            tx_fifo[tx_wr_ptr[FIFO_DEPTH-1:0]] <= eth_dout[15:8]; // Upper byte first
                            tx_wr_ptr <= tx_wr_ptr + 1'b1;
                        end
                        if (!tx_fifo_full) begin
                            tx_fifo[tx_wr_ptr[FIFO_DEPTH-1:0]] <= eth_dout[7:0];  // Lower byte second
                            tx_wr_ptr <= tx_wr_ptr + 1'b1;
                        end
                    end
                    else if (eth_addr >= HPS_RX_BUF) begin
                        if (!rx_fifo_full) begin
                            rx_fifo[rx_wr_ptr[FIFO_DEPTH-1:0]] <= eth_dout[15:8]; // Upper byte first
                            rx_wr_ptr <= rx_wr_ptr + 1'b1;
                            rx_bytes_received <= rx_bytes_received + 16'd1;
                        end
                        if (!rx_fifo_full) begin
                            rx_fifo[rx_wr_ptr[FIFO_DEPTH-1:0]] <= eth_dout[7:0];  // Lower byte second
                            rx_wr_ptr <= rx_wr_ptr + 1'b1;
                            rx_bytes_received <= rx_bytes_received + 16'd1;
                        end
                        
                        if (rx_bytes_received >= hps_rx_length && hps_rx_length > 0) begin
                            hps_rx_packet_ready <= 1'b1;
                            rx_bytes_received <= 16'h0000;
                            rtl_regs[REG_ISR] <= rtl_regs[REG_ISR] | 8'h01; // PRX
                        end
                    end
                end
            endcase
        end

        // Handle HPS reads  
        if (eth_rd) begin
            case (eth_addr)
                HPS_STATUS:   eth_din <= hps_status_reg;
                HPS_COMMAND:  eth_din <= hps_command_reg;
                HPS_TX_LEN_L: eth_din <= {8'h00, hps_tx_length[7:0]};
                HPS_TX_LEN_H: eth_din <= {8'h00, hps_tx_length[15:8]};
                HPS_RX_LEN_L: eth_din <= {8'h00, hps_rx_length[7:0]};
                HPS_RX_LEN_H: eth_din <= {8'h00, hps_rx_length[15:8]};
                HPS_MAC_0:    eth_din <= {8'h00, hps_mac_addr[0]};
                HPS_MAC_1:    eth_din <= {8'h00, hps_mac_addr[1]};
                HPS_MAC_2:    eth_din <= {8'h00, hps_mac_addr[2]};
                HPS_MAC_3:    eth_din <= {8'h00, hps_mac_addr[3]};
                HPS_MAC_4:    eth_din <= {8'h00, hps_mac_addr[4]};
                HPS_MAC_5:    eth_din <= {8'h00, hps_mac_addr[5]};

                default: begin
                    if (eth_addr >= HPS_TX_BUF && eth_addr < HPS_RX_BUF) begin
                        if (tx_fifo_count >= 2) begin
                            eth_din <= {tx_fifo[tx_rd_ptr[FIFO_DEPTH-1:0]], 
                                       tx_fifo[(tx_rd_ptr + 1'b1) & FIFO_MASK]};
                            tx_rd_ptr <= tx_rd_ptr + 2'd2;
                        end else if (!tx_fifo_empty) begin
                            eth_din <= {tx_fifo[tx_rd_ptr[FIFO_DEPTH-1:0]], 8'h00};
                            tx_rd_ptr <= tx_rd_ptr + 1'b1;
                        end else begin
                            eth_din <= 16'h0000;
                        end
                    end
                    else begin
                        eth_din <= 16'h0000;
                    end
                end
            endcase
        end
        
        // Automatic TX completion detection
        if (packet_tx_active && tx_fifo_empty) begin
            packet_tx_active <= 1'b0;
            tx_in_progress <= 1'b0;
            hps_tx_ready <= 1'b1;
            rtl_regs[REG_ISR] <= rtl_regs[REG_ISR] | 8'h02; // PTX
        end
        
        // ====================================================================
        // TOCCATA-STYLE CPU BUS HANDLING
        // ====================================================================
        
        // Handle second byte to FIFO first (like Toccata FIFO writes)
        if (write_second_byte == 1'b1) begin
            // Write second byte to the TX FIFO
            if (!tx_fifo_full) begin
                tx_fifo[tx_wr_ptr[FIFO_DEPTH-1:0]] <= second_byte;
                tx_wr_ptr <= tx_wr_ptr + 1'b1;
            end
            write_second_byte <= 1'b0;
            if (dma_count > 16'h0000) begin
                dma_count <= dma_count - 16'd1;
                dma_addr <= dma_addr + 16'd1;
            end
        end else if (sel_eth == 1'b1) begin
            // When selected start answering (Toccata pattern)

            // =================================================================
            // WRITE data into the registers
            // =================================================================
            if (cpu_lwr || cpu_hwr) begin // Might need to trigger on both
                case (cpu_address[5:1])
                    5'h00: begin // CR register
                        rtl_regs[REG_CR] <= din_byte;
                        current_page <= din_byte[7:6];
                        
                        // Handle DMA commands
                        case (din_byte[5:3])
                            3'b001, 3'b010: begin // Remote read/write DMA
                                dma_addr <= {rtl_regs[REG_RSAR1], rtl_regs[REG_RSAR0]};
                                dma_count <= {rtl_regs[REG_RBCR1], rtl_regs[REG_RBCR0]};
                                dma_in_progress <= 1'b1;
                            end
                            3'b011: begin // Send packet
                                packet_tx_active <= 1'b1;
                                tx_in_progress <= 1'b1;
                            end
                            3'b100: begin // Abort DMA
                                dma_in_progress <= 1'b0;
                                rtl_regs[REG_ISR] <= rtl_regs[REG_ISR] | 8'h40; // RDC
                            end
                        endcase
                    end
                    
                    5'h01: rtl_regs[REG_PSTART] <= din_byte;
                    5'h02: rtl_regs[REG_PSTOP] <= din_byte;
                    5'h03: rtl_regs[REG_BNRY] <= din_byte;
                    5'h04: rtl_regs[REG_TPSR] <= din_byte;   // TPSR (write)
                    5'h05: rtl_regs[REG_TBCR0] <= din_byte;  // TBCR0 (write)
                    5'h06: rtl_regs[REG_TBCR1] <= din_byte;  // TBCR1 (write)
                    5'h07: rtl_regs[REG_ISR] <= rtl_regs[REG_ISR] & ~din_byte; // Clear bits by writing 1
                    5'h08: rtl_regs[REG_RSAR0] <= din_byte;  // RSAR0 (write)
                    5'h09: rtl_regs[REG_RSAR1] <= din_byte;  // RSAR1 (write)
                    5'h0A: rtl_regs[REG_RBCR0] <= din_byte;
                    5'h0B: rtl_regs[REG_RBCR1] <= din_byte;
                    5'h0C: rtl_regs[REG_RCR] <= din_byte;    // RCR (write)
                    5'h0D: rtl_regs[REG_TCR] <= din_byte;    // TCR (write)
                    5'h0E: rtl_regs[REG_DCR] <= din_byte;    // DCR (write)
                    5'h0F: rtl_regs[REG_IMR] <= din_byte;    // IMR (write)
                    
                    5'h10: begin // Data port - TX FIFO writes (like Toccata FIFO)
                        if (dma_in_progress && dma_count > 16'h0000) begin
                            // Write value only when presented in the lower byte (edge detected)
                            if (cpu_lwr == 1'b1 && cpu_lwr_ == 1'b0) begin
                                // Write byte to the TX FIFO
                                if (!tx_fifo_full) begin
                                    tx_fifo[tx_wr_ptr[FIFO_DEPTH-1:0]] <= cpu_data_in[7:0];
                                    tx_wr_ptr <= tx_wr_ptr + 1'b1;
                                end
                                dma_count <= dma_count - 16'd1;
                                dma_addr <= dma_addr + 16'd1;
                            end

                            if (cpu_hwr == 1'b1 && cpu_hwr_ == 1'b0) begin
                                // Write high byte to FIFO as well (Toccata pattern)
                                write_second_byte <= 1'b1;
                                second_byte <= cpu_data_in[15:8];
                            end

                            // End DMA when count reaches zero
                            if (dma_count <= 16'd1) begin
                                dma_in_progress <= 1'b0;
                                rtl_regs[REG_ISR] <= rtl_regs[REG_ISR] | 8'h40; // RDC
                            end
                        end
                    end
                endcase
            end

            // =================================================================
            // READ data from the registers - CONSECUTIVE BYTES FOR WORD READS
            // =================================================================
            else if (cpu_rd == 1'b1) begin
                case (cpu_address[5:1]) // Word address
                    // 68000 Word Access Pattern: cpu_data_out <= {addr_N, addr_N+1}

                    // Each word read returns two consecutive byte registers
                    5'h00: cpu_data_out <= {rtl_regs[REG_CR], rtl_regs[REG_CLDA0]};      // {0x21, 0x46} = 0x2146
                    5'h01: cpu_data_out <= {rtl_regs[REG_CLDA1], rtl_regs[REG_BNRY]};     // {0x80, 0x46} = 0x8046
                    5'h02: cpu_data_out <= {rtl_regs[REG_TSR], rtl_regs[REG_NCR]};      // {0x00, 0x00} = 0x0000
                    5'h03: cpu_data_out <= {rtl_regs[REG_FIFO], rtl_regs[REG_ISR]};     // {0x00, 0x00} = 0x0000
                    5'h04: cpu_data_out <= {rtl_regs[REG_CRDA0], rtl_regs[REG_CRDA1]};    // {0x00, 0x00} = 0x0000
                    5'h05: cpu_data_out <= {8'h50, 8'h70};      // {0x00, 0x00} = 0x0000
                    5'h06: cpu_data_out <= {rtl_regs[REG_RSR], rtl_regs[REG_CNTR0]};       // {0x00, 0x00} = 0x0000
                    5'h07: cpu_data_out <= {rtl_regs[REG_CNTR1], rtl_regs[REG_CNTR2]};      // {0x33, 0x44} = 0x3344
                    5'h08: begin // Data port (like Toccata FIFO read)
                        if (dma_in_progress && dma_count > 16'h0000 && !rx_fifo_empty) begin
                            // For DMA reads, return consecutive bytes from FIFO
                            if (rx_fifo_count >= 2) begin
                                // Return two consecutive FIFO bytes: {current_byte, next_byte}
                                cpu_data_out <= {rx_fifo[rx_rd_ptr[FIFO_DEPTH-1:0]], rx_fifo[(rx_rd_ptr + 1'b1) & FIFO_MASK]};
                            end else begin
                                // Only one byte available, put in upper byte
                                cpu_data_out <= {rx_fifo[rx_rd_ptr[FIFO_DEPTH-1:0]], 8'h00};
                            end
                            // Edge detect the read to advance pointer (like Toccata)
                            if (cpu_rd_ == 1'b0) begin
                                loc_rd_en <= 1'b1;
                            end
                        end else begin
                            cpu_data_out <= {cpu_address[4:1], cpu_address[4:1]}; // Debug pattern
                        end
                    end
                    
                    default: cpu_data_out <= {cpu_address[4:1], cpu_address[4:1]}; // Debug pattern
                endcase
            end
        end else begin
            // Make sure no data is on the output when not selected (Toccata pattern)
            cpu_data_out <= 16'h0000;
        end
        
        // Handle local read enable (like Toccata FIFO read)
        if (loc_rd_en == 1'b1) begin
            if (dma_in_progress && !rx_fifo_empty) begin
                if (rx_fifo_count >= 2) begin
                    // Advance by 2 bytes for word read
                    rx_rd_ptr <= rx_rd_ptr + 2'd2;
                    if (dma_count > 16'd1) begin
                        dma_count <= dma_count - 16'd2;
                        dma_addr <= dma_addr + 16'd2;
                    end else begin
                        dma_count <= 16'h0000;
                    end
                end else begin
                    // Only one byte available, advance by 1
                    rx_rd_ptr <= rx_rd_ptr + 1'b1;
                    if (dma_count > 16'h0000) begin
                        dma_count <= dma_count - 16'd1;
                        dma_addr <= dma_addr + 16'd1;
                    end
                end
                
                if (dma_count <= 16'd2) begin
                    dma_in_progress <= 1'b0;
                    rtl_regs[REG_ISR] <= rtl_regs[REG_ISR] | 8'h40; // RDC
                end
            end
        end
        
        // ====================================================================
        // INTERRUPT HANDLING
        // ====================================================================
        
        eth_irq <= |(rtl_regs[REG_ISR] & rtl_regs[REG_IMR]) && rtl_regs[REG_CR][1] && !rtl_regs[REG_CR][0];
        
        // Clear overflow flags when FIFOs are reset or drained
        if (tx_fifo_empty) tx_fifo_overflow <= 1'b0;
        if (rx_fifo_empty) rx_fifo_overflow <= 1'b0;
        
    end
end

endmodule
