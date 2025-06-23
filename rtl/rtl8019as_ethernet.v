// RTL8019AS Ethernet Controller with HPS DMA Integration
// Eventually it will be compatible with Ariadne II/ X-Surf drivers via UIO_DMA interface
// Updated for MiSTer HPS communication

module rtl8019as_ethernet
(
    input wire        clk,
    input wire        reset,

    // CPU interface (connects to Minimig CPU bus)
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
// CONSTANTS
// ============================================================================

localparam RTL8019_CHIP_ID0 = 8'h50;
localparam RTL8019_CHIP_ID1 = 8'h70;

// HPS DMA register addresses (0x00-0x7F via hps_ext)
localparam HPS_STATUS      = 8'h00;  // Status register
localparam HPS_COMMAND     = 8'h01;  // Command register
localparam HPS_TX_LEN_L    = 8'h02;  // TX packet length low
localparam HPS_TX_LEN_H    = 8'h03;  // TX packet length high
localparam HPS_RX_LEN_L    = 8'h04;  // RX packet length low
localparam HPS_RX_LEN_H    = 8'h05;  // RX packet length high
localparam HPS_MAC_0       = 8'h06;  // MAC address byte 0
localparam HPS_MAC_1       = 8'h07;  // MAC address byte 1
localparam HPS_MAC_2       = 8'h08;  // MAC address byte 2
localparam HPS_MAC_3       = 8'h09;  // MAC address byte 3
localparam HPS_MAC_4       = 8'h0A;  // MAC address byte 4
localparam HPS_MAC_5       = 8'h0B;  // MAC address byte 5
localparam HPS_TX_BUF      = 8'h10;  // TX buffer start (0x10-0x4F)
localparam HPS_RX_BUF      = 8'h50;  // RX buffer start (0x50-0x7F)

// HPS Status register bits
localparam HPS_STATUS_TX_BUSY   = 0;
localparam HPS_STATUS_RX_READY  = 1;
localparam HPS_STATUS_TX_DONE   = 2;
localparam HPS_STATUS_RX_ERROR  = 3;
localparam HPS_STATUS_LINK_UP   = 4;

// HPS Command register bits
localparam HPS_CMD_TX_START     = 0;
localparam HPS_CMD_RX_ENABLE    = 1;
localparam HPS_CMD_RESET        = 2;
localparam HPS_CMD_IRQ_ACK      = 3;

localparam PAGE0 = 2'h0;
localparam PAGE1 = 2'h1;
localparam PAGE2 = 2'h2;
localparam PAGE3 = 2'h3;

// ============================================================================
// RTL8019AS Register Address Definitions
// ============================================================================

localparam REG_CR    = 4'h0;  // Command Register (all pages)

// Page 0 registers (CR[7:6] = 00) - NE2000 compatible
localparam R_REG_CLDA0 = 4'h1;  // Current Local DMA Address 0 low byte
localparam W_REG_PSTART = 4'h1;  // Page Start Register (write)
localparam R_REG_CLDA1 = 4'h2;  // Current Local DMA Address 1 upper byte
localparam W_REG_PSTOP  = 4'h2;  // Page Stop Register (write)
localparam REG_BNRY  = 4'h3;  // Boundary Pointer
localparam R_REG_TSR   = 4'h4;  // Transmit Status Register (read only)
localparam W_REG_TPSR  = 4'h4;  // Transmit Page Start Register (write only)
localparam R_REG_NCR   = 4'h5;  // Number of Collisions Register (read only)
localparam W_REG_TBCR0 = 4'h5;  // Transmit Byte Count Register 0 (write only)
localparam R_REG_FIFO  = 4'h6;  // FIFO (read only)
localparam W_REG_TBCR1 = 4'h6;  // Transmit Byte Count Register 1 (write only)
localparam REG_ISR   = 4'h7;  // Interrupt Status Register
localparam R_REG_CRDA0 = 4'h8;  // Current Remote DMA Address 0 (read only)
localparam W_REG_RSAR0 = 4'h8;  // Remote Start Address Register 0 (write only)
localparam R_REG_CRDA1 = 4'h9;  // Current Remote DMA Address 1 (read only)
localparam W_REG_RSAR1 = 4'h9;  // Remote Start Address Register 1 (write only)
localparam W_REG_RBCR0 = 4'hA;  // Remote Byte Count Register 0 (write only)
localparam R_REG_8019ID0   = 4'hA;  // Chip ID0 (read only) 0x50
localparam W_REG_RBCR1 = 4'hB;  // Remote Byte Count Register 1 (write only)
localparam R_REG_8019ID1   = 4'hB;  // Chip ID1 (read only) 0x70
localparam R_REG_RSR   = 4'hC;  // Receive Status Register (read only)
localparam W_REG_RCR   = 4'hC;  // Receive Configuration Register (write only)
localparam R_REG_CNTR0 = 4'hD;  // Frame Alignment Error Counter (read only)
localparam W_REG_TCR   = 4'hD;  // Transmit Configuration Register (write only)
localparam R_REG_CNTR1 = 4'hE;  // CRC Error Counter (read only)
localparam W_REG_DCR   = 4'hE;  // Data Configuration Register (write only)
localparam R_REG_CNTR2 = 4'hF;  // Missed Packet Counter (read only)
localparam W_REG_IMR   = 4'hF;  // Interrupt Mask Register (write only)

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

// ============================================================================
// ADDRESS DECODING
// ============================================================================

// CPU data strobe decoding
wire word_access = cpu_hwr && cpu_lwr;
wire access_upper_byte = cpu_hwr && !cpu_lwr;
wire access_lower_byte = !cpu_hwr && cpu_lwr;
wire any_access = cpu_hwr || cpu_lwr;
    
// RTL8019AS is typically at 0x300 base for x-surf 100
wire at_ethernet_offset = (cpu_address[10:8] == 3'h3);
wire sel_chip = sel_ethernet && at_ethernet_offset;
wire [4:0] full_reg_addr = cpu_address[5:1];
wire [3:0] reg_addr = cpu_address[4:1];
wire [1:0] page = cr[7:6];


// ============================================================================
// REGISTER STORAGE
// ============================================================================

reg [7:0] cr;          // Command Register
reg [7:0] isr;         // Interrupt Status Register
reg [7:0] imr;         // Interrupt Mask Register
reg [7:0] dcr;         // Data Configuration Register
reg [7:0] tcr;         // Transmit Configuration Register
reg [7:0] rcr;         // Receive Configuration Register
reg [7:0] tsr;         // Transmit Status Register
reg [7:0] rsr;         // Receive Status Register
reg [7:0] tpsr;        // Transmit Page Start Register
reg [7:0] tbcr0, tbcr1; // Transmit Byte Count
reg [7:0] pstart;      // Page Start Register
reg [7:0] pstop;       // Page Stop Register
reg [7:0] bnry;        // Boundary Pointer
reg [7:0] curr;        // Current Page Register

// DMA registers
reg [7:0] rsar0, rsar1; // Remote Start Address
reg [7:0] rbcr0, rbcr1; // Remote Byte Count
reg [15:0] crda;        // Current Remote DMA Address

// MAC address (Amiga big endian)
reg [47:0] mac_addr_be;

// Error counters
reg [7:0] frame_err_cnt;
reg [7:0] crc_err_cnt;
reg [7:0] missed_pkt_cnt;

// Multicast address hash table
reg [63:0] multicast_addr;

// ============================================================================
// HPS COMMUNICATION STATE
// ============================================================================

reg [15:0] hps_status_reg;
reg [15:0] hps_command_reg;
reg [15:0] hps_tx_length;
reg [15:0] hps_rx_length;
reg [7:0]  hps_mac_addr [0:5];

// HPS communication flags
reg hps_tx_ready;
reg hps_rx_packet_ready;
reg hps_link_up;
reg hps_irq_pending;

// ============================================================================
// STATE VARIABLES
// ============================================================================

reg dma_in_progress;
reg tx_in_progress;
reg rx_in_progress;
reg [15:0] tx_length;
reg [15:0] rx_length;

// Packet buffer for DMA operations
//reg [7:0] packet_buffer [0:2047]; // 2KB buffer
reg [7:0] packet_buffer [0:511]; // 512B buffer

// ============================================================================
// MAIN CONTROL LOGIC
// ============================================================================

always @(posedge clk) begin
    if (reset) begin
        // Reset all registers to proper NE2000 defaults
        cr <= 8'h21;          // Page 0, stopped
        isr <= 8'h80;         // Reset complete
        imr <= 8'h00;         // No interrupts
        dcr <= 8'h49;         // 16-bit mode, normal operation
        tcr <= 8'h00;         // Normal transmit
        rcr <= 8'h00;         // Reject all initially
        tsr <= 8'h00;
        rsr <= 8'h00;

        // Page setup
        pstart <= 8'h46;      // Start at page 0x46
        pstop <= 8'h80;       // Stop at page 0x80
        bnry <= 8'h46;        // Boundary at start
        curr <= 8'h47;        // Current page next

        tpsr <= 8'h40;        // TX starts at page 0x40
        tbcr0 <= 8'h00;
        tbcr1 <= 8'h00;

        rsar0 <= 8'h00;
        rsar1 <= 8'h00;
        rbcr0 <= 8'h00;
        rbcr1 <= 8'h00;
        crda <= 16'h0000;

        // Default MAC - Ariadne II compatible
        mac_addr_be <= 48'h001122334455;
        
        // Initialize HPS MAC array
        hps_mac_addr[0] <= 8'h00;
        hps_mac_addr[1] <= 8'h11;
        hps_mac_addr[2] <= 8'h22;
        hps_mac_addr[3] <= 8'h33;
        hps_mac_addr[4] <= 8'h44;
        hps_mac_addr[5] <= 8'h55;

        // Clear counters
        frame_err_cnt <= 8'h00;
        crc_err_cnt <= 8'h00;
        missed_pkt_cnt <= 8'h00;
        multicast_addr <= 64'h0000000000000000;

        // State
        eth_irq <= 1'b0;
        dma_in_progress <= 1'b0;
        tx_in_progress <= 1'b0;
        rx_in_progress <= 1'b0;
        tx_length <= 16'h0000;
        rx_length <= 16'h0000;

        // HPS communication
        hps_status_reg <= 16'h0010; // Link up
        hps_command_reg <= 16'h0000;
        hps_tx_length <= 16'h0000;
        hps_rx_length <= 16'h0000;
        hps_tx_ready <= 1'b0;
        hps_rx_packet_ready <= 1'b0;
        hps_link_up <= 1'b1;
        hps_irq_pending <= 1'b0;

        eth_din <= 16'h0000;
        eth_status <= 8'h10; // Link up

    end else begin

        // ====================================================================
        // HPS DMA INTERFACE HANDLING
        // ====================================================================

        // Update HPS status register
        hps_status_reg[HPS_STATUS_TX_BUSY] <= tx_in_progress;
        hps_status_reg[HPS_STATUS_RX_READY] <= hps_rx_packet_ready;
        hps_status_reg[HPS_STATUS_TX_DONE] <= hps_tx_ready;
        hps_status_reg[HPS_STATUS_LINK_UP] <= hps_link_up;

        // Update status output to HPS
        eth_status <= hps_status_reg[7:0];

        // Handle HPS writes
        if (eth_wr) begin
            case (eth_addr)
                HPS_STATUS: begin
                    // Status register (mostly read-only, but can clear some flags)
                    if (eth_dout[HPS_STATUS_TX_DONE]) hps_tx_ready <= 1'b0;
                    if (eth_dout[HPS_STATUS_RX_READY]) hps_rx_packet_ready <= 1'b0;
                end

                HPS_COMMAND: begin
                    hps_command_reg <= eth_dout;
                    
                    if (eth_dout[HPS_CMD_RESET]) begin
                        // Reset ethernet controller
                        hps_tx_ready <= 1'b0;
                        hps_rx_packet_ready <= 1'b0;
                        tx_in_progress <= 1'b0;
                        rx_in_progress <= 1'b0;
                        hps_irq_pending <= 1'b0;
                    end

                    if (eth_dout[HPS_CMD_TX_START] && !tx_in_progress) begin
                        // Start transmission
                        tx_in_progress <= 1'b1;
                        tx_length <= hps_tx_length;
                        hps_tx_ready <= 1'b0;
                        // Trigger RTL8019AS transmission
                        tsr[0] <= 1'b0; // Clear PTX
                        isr[1] <= 1'b0; // Clear PTXE
                    end

                    if (eth_dout[HPS_CMD_IRQ_ACK]) begin
                        hps_irq_pending <= 1'b0;
                    end
                end

                HPS_TX_LEN_L: hps_tx_length[7:0] <= eth_dout[7:0];
                HPS_TX_LEN_H: hps_tx_length[15:8] <= eth_dout[7:0];
                HPS_RX_LEN_L: hps_rx_length[7:0] <= eth_dout[7:0];
                HPS_RX_LEN_H: hps_rx_length[15:8] <= eth_dout[7:0];

                HPS_MAC_0: begin
                    hps_mac_addr[0] <= eth_dout[7:0];
                    mac_addr_be[47:40] <= eth_dout[7:0];
                end
                HPS_MAC_1: begin
                    hps_mac_addr[1] <= eth_dout[7:0];
                    mac_addr_be[39:32] <= eth_dout[7:0];
                end
                HPS_MAC_2: begin
                    hps_mac_addr[2] <= eth_dout[7:0];
                    mac_addr_be[31:24] <= eth_dout[7:0];
                end
                HPS_MAC_3: begin
                    hps_mac_addr[3] <= eth_dout[7:0];
                    mac_addr_be[23:16] <= eth_dout[7:0];
                end
                HPS_MAC_4: begin
                    hps_mac_addr[4] <= eth_dout[7:0];
                    mac_addr_be[15:8] <= eth_dout[7:0];
                end
                HPS_MAC_5: begin
                    hps_mac_addr[5] <= eth_dout[7:0];
                    mac_addr_be[7:0] <= eth_dout[7:0];
                end

                default: begin
                    // Handle TX/RX buffer writes
                    if (eth_addr >= HPS_TX_BUF && eth_addr < HPS_RX_BUF) begin
                        // TX buffer write
                        packet_buffer[{tpsr, 6'b000000} + ((eth_addr - HPS_TX_BUF) * 2)] <= eth_dout[7:0];
                        packet_buffer[{tpsr, 6'b000000} + ((eth_addr - HPS_TX_BUF) * 2) + 1] <= eth_dout[15:8];
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
                    // Handle RX buffer reads
                    if (eth_addr >= HPS_RX_BUF) begin
                        eth_din <= {
                            packet_buffer[{pstart, 6'b000000} + ((eth_addr - HPS_RX_BUF) * 2) + 1],
                            packet_buffer[{pstart, 6'b000000} + ((eth_addr - HPS_RX_BUF) * 2)]
                        };
                    end else begin
                        eth_din <= 16'h0000;
                    end
                end
            endcase
        end

        // ====================================================================
        // PACKET TRANSMISSION COMPLETION
        // ====================================================================

        // if (tx_in_progress) begin
        //     // Simulate transmission delay
        //     static reg [7:0] tx_delay = 0;
        //     tx_delay <= tx_delay + 1;
            
        //     if (tx_delay == 8'hFF) begin
        //         // Transmission complete
        //         tx_in_progress <= 1'b0;
        //         hps_tx_ready <= 1'b1;
        //         tsr[0] <= 1'b1; // PTX - packet transmitted
        //         isr[1] <= 1'b1; // PTXE interrupt
        //         hps_irq_pending <= 1'b1;
        //         tx_delay <= 0;
        //     end
        // end

        // ====================================================================
        // PACKET RECEPTION SIMULATION
        // ====================================================================

        // // Simulate receiving packets periodically
        // static reg [23:0] rx_timer = 0;
        // rx_timer <= rx_timer + 1;

        // if (rx_timer == 24'hFFFFFF && rcr[2] && !hps_rx_packet_ready) begin // If RX enabled
        //     // Simulate receiving a packet
        //     hps_rx_length <= 16'h0040; // 64 byte packet
        //     hps_rx_packet_ready <= 1'b1;
        //     hps_irq_pending <= 1'b1;

        //     // Fill RX buffer with dummy data (in real implementation, this comes from HPS)
        //     for (integer i = 0; i < 32; i = i + 1) begin
        //         packet_buffer[{pstart, 6'b000000} + (i * 2)] <= 8'hAA + i[7:0];
        //         packet_buffer[{pstart, 6'b000000} + (i * 2) + 1] <= 8'h55 + i[7:0];
        //     end

        //     // Update RTL8019AS receive status
        //     rsr[0] <= 1'b1; // PRX - packet received
        //     isr[0] <= 1'b1; // PRXE interrupt

        //     rx_timer <= 24'h000000;
        // end

        // ====================================================================
        // CPU ACCESS HANDLING (RTL8019AS Register Emulation)
        // ====================================================================

        if (sel_chip) begin

            // ***** CPU WRITE OPERATIONS *****
            if (any_access) begin

                case (full_reg_addr)
                    5'h10, 5'h11, 5'h12, 5'h13, 5'h14, 5'h15, 5'h16, 5'h17: begin // Data port - DMA write
                        if (dma_in_progress && ({rbcr1, rbcr0} > 0)) begin
                            if (dcr[0]) begin // 16-bit mode
                                packet_buffer[crda] <= cpu_data_in[15:8];     // Upper byte first for Amiga
                                packet_buffer[crda + 1] <= cpu_data_in[7:0];  // Lower byte
                                crda <= crda + 2;
                                {rbcr1, rbcr0} <= {rbcr1, rbcr0} - 2;
                            end else begin // 8-bit mode
                                packet_buffer[crda] <= cpu_data_in[15:8]; // Use upper byte for Amiga
                                crda <= crda + 1;
                                {rbcr1, rbcr0} <= {rbcr1, rbcr0} - 1;
                            end

                            if ({rbcr1, rbcr0} <= (dcr[0] ? 2 : 1)) begin
                                dma_in_progress <= 1'b0;
                                isr[6] <= 1'b1; // DMA complete
                            end
                        end
                    end

                    5'h18, 5'h19, 5'h1A, 5'h1B, 5'h1C, 5'h1D, 5'h1E, 5'h1F: begin // Reset port
                        cr <= 8'h21;
                        isr <= 8'h80;
                    end

                    default: begin
                        // Use proper byte for Amiga (upper byte)
                        reg [7:0] write_data;
                        write_data = cpu_data_in[15:8];

                        case (page)
                            PAGE0: begin // Page 0 - write
                                case (reg_addr)
                                    REG_CR: begin // Command Register
                                        cr <= write_data;

                                        // Handle command bits
                                        case (write_data[5:3])
                                            3'b001: begin // Remote read DMA
                                                crda <= {rsar1, rsar0};
                                                dma_in_progress <= 1'b1;
                                            end
                                            3'b010: begin // Remote write DMA
                                                crda <= {rsar1, rsar0};
                                                dma_in_progress <= 1'b1;
                                            end
                                            3'b011: begin // Send packet
                                                if (!tx_in_progress) begin
                                                    tx_length <= {tbcr1, tbcr0};
                                                    tx_in_progress <= 1'b1;
                                                    // Copy packet data to HPS buffer would happen here
                                                    hps_tx_length <= {tbcr1, tbcr0};
                                                end
                                            end
                                            3'b100: begin // Abort DMA
                                                dma_in_progress <= 1'b0;
                                                isr[6] <= 1'b1;
                                            end
                                        endcase

                                        // Start bit
                                        if (write_data[1]) begin
                                            isr[7] <= 1'b0; // Clear reset
                                        end
                                    end

                                    W_REG_PSTART: pstart <= write_data;
                                    W_REG_PSTOP: pstop <= write_data;
                                    REG_BNRY: bnry <= write_data;
                                    W_REG_TPSR: tpsr <= write_data;
                                    W_REG_TBCR0: tbcr0 <= write_data;
                                    W_REG_TBCR1: tbcr1 <= write_data;
                                    REG_ISR: isr <= isr & ~write_data; // Clear on write
                                    W_REG_RSAR0: rsar0 <= write_data;
                                    W_REG_RSAR1: rsar1 <= write_data;
                                    W_REG_RBCR0: rbcr0 <= write_data;
                                    W_REG_RBCR1: rbcr1 <= write_data;
                                    W_REG_RCR: rcr <= write_data;
                                    W_REG_TCR: tcr <= write_data;
                                    W_REG_DCR: dcr <= write_data;
                                    W_REG_IMR: imr <= write_data;
                                endcase
                            end

                            PAGE1: begin // Page 1 - MAC address
                                case (reg_addr)
                                    REG_CR: cr <= write_data;
                                    REG_PAR0_P1: mac_addr_be[47:40] <= write_data;
                                    REG_PAR1_P1: mac_addr_be[39:32] <= write_data;
                                    REG_PAR2_P1: mac_addr_be[31:24] <= write_data;
                                    REG_PAR3_P1: mac_addr_be[23:16] <= write_data;
                                    REG_PAR4_P1: mac_addr_be[15:8] <= write_data;
                                    REG_PAR5_P1: mac_addr_be[7:0] <= write_data;
                                    REG_CURR_P1: curr <= write_data;
                                    REG_MAR0_P1: multicast_addr[7:0] <= write_data;
                                    REG_MAR1_P1: multicast_addr[15:8] <= write_data;
                                    REG_MAR2_P1: multicast_addr[23:16] <= write_data;
                                    REG_MAR3_P1: multicast_addr[31:24] <= write_data;
                                    REG_MAR4_P1: multicast_addr[39:32] <= write_data;
                                    REG_MAR5_P1: multicast_addr[47:40] <= write_data;
                                    REG_MAR6_P1: multicast_addr[55:48] <= write_data;
                                    REG_MAR7_P1: multicast_addr[63:56] <= write_data;
                                endcase
                            end

                            PAGE2: begin // Page 2 - read-only, only CR writable
                                case (reg_addr)
                                    REG_CR: cr <= write_data;
                                endcase
                            end

                            PAGE3: begin // Page 3 - RTL8019AS enhanced
                                case (reg_addr)
                                    REG_CR: cr <= write_data;
                                    // Other page 3 registers would go here
                                endcase
                            end
                        endcase
                    end
                endcase
            end

            // ***** CPU READ OPERATIONS *****
            if (cpu_rd) begin

                case (full_reg_addr)
                    5'h1E: begin // ID register
                        cpu_data_out <= {RTL8019_CHIP_ID0, RTL8019_CHIP_ID1};
                    end

                    5'h1F: begin // Signature port
                        cpu_data_out <= {8'h57, 8'h57}; // RTL8019AS signature
                    end

                    5'h10: begin // Data port - DMA read
                        if (dma_in_progress && ({rbcr1, rbcr0} > 0)) begin
                            if (dcr[0]) begin // 16-bit mode
                                cpu_data_out <= {packet_buffer[crda], packet_buffer[crda + 1]};
                                crda <= crda + 2;
                                {rbcr1, rbcr0} <= {rbcr1, rbcr0} - 2;
                            end else begin // 8-bit mode
                                cpu_data_out <= {packet_buffer[crda], 8'h00};
                                crda <= crda + 1;
                                {rbcr1, rbcr0} <= {rbcr1, rbcr0} - 1;
                            end

                            if ({rbcr1, rbcr0} <= (dcr[0] ? 2 : 1)) begin
                                dma_in_progress <= 1'b0;
                                isr[6] <= 1'b1;
                            end
                        end else begin
                            cpu_data_out <= 16'h0000;
                        end
                    end

                    default: begin
                        case (page)
                            PAGE0: begin // Page 0 - read
                                case (reg_addr)
                                    REG_CR: cpu_data_out <= {cr, 8'h00};
                                    R_REG_CLDA0: cpu_data_out <= {crda[7:0], 8'h00};
                                    R_REG_CLDA1: cpu_data_out <= {crda[15:8], 8'h00};
                                    REG_BNRY: cpu_data_out <= {bnry, 8'h00};
                                    R_REG_TSR: cpu_data_out <= {(tsr | 8'h20), 8'h00}; // Set bit 5 (always 1)
                                    R_REG_NCR: cpu_data_out <= {8'h00, 8'h00};
                                    R_REG_FIFO: cpu_data_out <= {8'h00, 8'h00};
                                    REG_ISR: cpu_data_out <= {isr, 8'h00};
                                    R_REG_CRDA0: cpu_data_out <= {crda[7:0], 8'h00};
                                    R_REG_CRDA1: cpu_data_out <= {crda[15:8], 8'h00};
                                    R_REG_8019ID0: cpu_data_out <= {RTL8019_CHIP_ID0, 8'h00};
                                    R_REG_8019ID1: cpu_data_out <= {RTL8019_CHIP_ID1, 8'h00};
                                    R_REG_RSR: cpu_data_out <= {rsr, 8'h00};
                                    R_REG_CNTR0: cpu_data_out <= {frame_err_cnt, 8'h00};
                                    R_REG_CNTR1: cpu_data_out <= {crc_err_cnt, 8'h00};
                                    R_REG_CNTR2: cpu_data_out <= {missed_pkt_cnt, 8'h00};
                                    default: cpu_data_out <= 16'h0000;
                                endcase
                            end

                            PAGE1: begin // Page 1 - read
                                case (reg_addr)
                                    REG_CR: cpu_data_out <= {cr, 8'h00};
                                    REG_PAR0_P1: cpu_data_out <= {mac_addr_be[47:40], 8'h00};
                                    REG_PAR1_P1: cpu_data_out <= {mac_addr_be[39:32], 8'h00};
                                    REG_PAR2_P1: cpu_data_out <= {mac_addr_be[31:24], 8'h00};
                                    REG_PAR3_P1: cpu_data_out <= {mac_addr_be[23:16], 8'h00};
                                    REG_PAR4_P1: cpu_data_out <= {mac_addr_be[15:8], 8'h00};
                                    REG_PAR5_P1: cpu_data_out <= {mac_addr_be[7:0], 8'h00};
                                    REG_CURR_P1: cpu_data_out <= {curr, 8'h00};
                                    REG_MAR0_P1: cpu_data_out <= {multicast_addr[7:0], 8'h00};
                                    REG_MAR1_P1: cpu_data_out <= {multicast_addr[15:8], 8'h00};
                                    REG_MAR2_P1: cpu_data_out <= {multicast_addr[23:16], 8'h00};
                                    REG_MAR3_P1: cpu_data_out <= {multicast_addr[31:24], 8'h00};
                                    REG_MAR4_P1: cpu_data_out <= {multicast_addr[39:32], 8'h00};
                                    REG_MAR5_P1: cpu_data_out <= {multicast_addr[47:40], 8'h00};
                                    REG_MAR6_P1: cpu_data_out <= {multicast_addr[55:48], 8'h00};
                                    REG_MAR7_P1: cpu_data_out <= {multicast_addr[63:56], 8'h00};
                                    default: cpu_data_out <= 16'h0000;
                                endcase
                            end

                            PAGE2: begin // Page 2 - RTL8019AS specific
                                case (reg_addr)
                                    REG_CR: cpu_data_out <= {cr, 8'h00};
                                    // Mirror some page 0 registers
                                    4'h1: cpu_data_out <= {pstart, 8'h00};
                                    4'h2: cpu_data_out <= {pstop, 8'h00};
                                    4'h4: cpu_data_out <= {tpsr, 8'h00};
                                    4'hC: cpu_data_out <= {rcr, 8'h00};
                                    4'hD: cpu_data_out <= {tcr, 8'h00};
                                    4'hE: cpu_data_out <= {dcr, 8'h00};
                                    4'hF: cpu_data_out <= {imr, 8'h00};
                                    default: cpu_data_out <= 16'h0000;
                                endcase
                            end

                            PAGE3: begin // Page 3 - RTL8019AS enhanced
                                case (reg_addr)
                                    REG_CR: cpu_data_out <= {cr, 8'h00};
                                    // RTL8019AS specific registers would go here
                                    default: cpu_data_out <= 16'h0000;
                                endcase
                            end

                            default: cpu_data_out <= 16'h0000;
                        endcase
                    end
                endcase

            end
            else begin
                cpu_data_out <= 16'h0000;
            end

        end else begin
            cpu_data_out <= 16'h0000;
        end

        // ====================================================================
        // INTERRUPT HANDLING
        // ====================================================================

        // Generate interrupt when conditions are met
        eth_irq <= |(isr & imr) && !cr[0] && cr[1]; // IRQ when enabled, started, and not stopped
    end
end

endmodule
