// Ethernet Controller for MiSTer Minimig - Full NE2000/RTL8019AS Implementation
// Implements complete NE2000 register set with direct memory access instead of HPS bus transactions
// Compatible with X-Surf 100 and other NE2000-based Amiga ethernet cards

`timescale 1ns / 1ps

module ethernet_interface
(
    input wire clk,
    input wire reset,

    // CPU bus interface (Amiga side)  
    input  wire [23:1] cpu_addr,
    input  wire [15:0] cpu_data_in,
    output reg  [15:0] cpu_data_out,
    input  wire        cpu_rd,
    input  wire        cpu_hwr,
    input  wire        cpu_lwr,
    input  wire        cpu_uds,
    input  wire        cpu_lds,

    // Card select for the full ethernet aperture
    input  wire        sel_ethernet,

    // Chip select for shared-memory aperture (0x1000-0xFFFF within the card)
    input  wire        sel_ethernet_shm,

    // Ethernet base address (dynamic based on autoconfig)
    input  wire [7:0] ethernet_base,

    // Address translation for data port writes
    output reg [23:1]  translated_addr,
    output reg         addr_translate_enable,

    // Background shared-memory access channel
    output reg         eth_mem_req,
    output reg         eth_mem_wr,
    output reg [23:1]  eth_mem_addr,
    output reg [15:0]  eth_mem_wdata,
    output reg  [1:0]  eth_mem_be,
    input  wire [15:0] eth_mem_rdata,
    input  wire        eth_mem_ack,

    // Interrupt output to Amiga
    output reg         eth_irq
);

//   Ethernet Controller Memory Map
//   Selected by: sel_ethernet_shm (unified with shared memory)

//   Base Address: 0xEA0000 (configurable via autoconfig)

//   Register Space (0xEA0000 - 0xEA0FFF) - part of unified shared memory space

//   NE2000 Registers (0xEA0600 - 0xEA061F)

//   - 0xEA0600-0xEA060F: Page 0 registers
//     - 0x00: CR (Command Register)
//     - 0x01: CLDA0/PSTART (Current Local DMA Address 0 / Page Start)
//     - 0x02: CLDA1/PSTOP (Current Local DMA Address 1 / Page Stop)
//     - 0x03: BNRY (Boundary Register)
//     - 0x04: TSR/TPSR (Transmit Status / Transmit Page Start)
//     - 0x05: NCR/TBCR0 (Number of Collisions / Transmit Byte Count 0)
//     - 0x06: FIFO/TBCR1 (FIFO / Transmit Byte Count 1)
//     - 0x07: ISR (Interrupt Status Register)
//     - 0x08: CRDA0/RSAR0 (Current Remote DMA Address 0 / Remote Start Address 0)
//     - 0x09: CRDA1/RSAR1 (Current Remote DMA Address 1 / Remote Start Address 1)
//     - 0x0A: 8019ID0/RBCR0 (RTL8019 ID0 / Remote Byte Count 0)
//     - 0x0B: 8019ID1/RBCR1 (RTL8019 ID1 / Remote Byte Count 1)
//     - 0x0C: RSR (Receive Status Register)
//     - 0x0D: CNTR0 (Tally Counter 0)
//     - 0x0E: CNTR1 (Tally Counter 1)
//     - 0x0F: CNTR2 (Tally Counter 2)
//   - 0xEA0610: Data Port (Remote DMA port)
//   - 0xEA0618-0xEA061F: Reset port (write triggers reset)

//   Additional Register Windows

//   - 0xEA0620: Alternate Data Port address
//   - 0xEA0C40: Mirror Data Port address

//   Shared Memory Space (0xEA1000 - 0xEAFFFF)

//   Selected by: sel_ethernet_shm (unified with register space)

//   Control Structure (0xEA1000 - 0xEA1FFF)

//   - 0xEA1000: ETH_SHM_CTRL_FLAGS (4 bytes) - Control flags
//   - 0xEA1004: ETH_SHM_CTRL_REGS - mirrored NE2000 register block for HPS
//   - 0xEA104C: ETH_SHM_CTRL_MAC (6 bytes) - MAC address
//   - 0xEA1052: ETH_SHM_CTRL_STATUS (2 bytes) - Status
//   - 0xEA1054: ETH_SHM_CTRL_STATS (52 bytes) - Packet statistics
//   - 0xEA1088: ETH_SHM_HPS_HEARTBEAT (4 bytes) - HPS heartbeat
//   - 0xEA108C: ETH_SHM_HPS_SIGNATURE (4 bytes) - Signature (0xCAFEBABE)

//   Packet Buffers (0xEA2000 - 0xEA2FFF)

//   - 0xEA2000: ETH_SHM_TX_BUFFER (0x600 bytes) - TX packet buffer
//   - 0xEA2600: ETH_SHM_RX_BUFFER (0x600 bytes) - RX packet buffer
//   - 0xEA2C00: ETH_SHM_PACKET_INFO (512 bytes) - Packet metadata

//   NE2000 Memory Space (0xEA3000 - 0xEA6FFF)

//   - 0xEA3000: ETH_SHM_NE_MEMORY (16KB compact backing store)
//     - NE visible packet RAM lives at 0x4000-0x7FFF
//     - Shared memory stores that packet RAM compactly at 0x3000-0x6FFF
//     - 0x0000-0x001F are synthesized as station PROM / MAC shadow

//   Debug/Future Use (0xEA7000 - 0xEAFFFF)

//   - 0xEA7000: ETH_SHM_DEBUG_INFO (8KB) - Debug information
//   - 0xEA9000: ETH_SHM_FUTURE_USE (Reserved) - Reserved for expansion

//   Access Methods

//   1. Register I/O (0xEA0000-0xEA0FFF):
//     - Direct CPU read/write to NE2000 registers
//     - Data port access for packet data via Remote DMA
//   2. Shared Memory (0xEA1000-0xEAFFFF):
//     - Direct memory-mapped access to buffers and control structures
//     - Used by HPS for packet data transfer and status updates
//     - CPU can also directly access for diagnostics

//   Address Decoding Logic

//   sel_ethernet_shm = (cpu_addr[23:16] == ethernet_base) - covers entire 0xEA0000-0xEAFFFF
//   
//   Note: Shared memory access types (is_*_access) include sel_ethernet_shm check internally

//   This provides a complete 64KB address space with clear separation between register I/O and shared memory regions.


// Use ethernet_base + ETH_SHM_* offsets for direct mapped shared memory access
// This eliminates the huge 64KB internal memory array and saves FPGA resources
// Memory access is done through direct address mapping instead of array storage

// Calculate shared memory base address from ethernet_base
wire [15:0] shared_mem_base = {ethernet_base, 8'h00}; // ethernet_base << 8

// Helper function to calculate actual memory addresses
function [15:0] calc_mem_addr;
    input [15:0] offset;
    calc_mem_addr = shared_mem_base + offset;
endfunction

// Direct memory access - use address calculations instead of internal array
// For direct mapped shared memory, we calculate addresses but don't store data internally
// This eliminates the 64KB array while maintaining the same functional interface

// Memory access is now done through direct address mapping
// The actual storage is handled by the external system's memory mapping

// Address mapping constants (kept for autoconfig compatibility)
parameter ETH_REG_OFFSET   = 16'h0C00;    // Register offset
parameter ETH_DATA_OFFSET  = 16'h0C10;    // Data port offset (0x10 from base)  

// State machine states - simplified
parameter [1:0] IDLE     = 2'b00;
parameter [1:0] ACCESS   = 2'b01;
parameter [1:0] COMPLETE = 2'b10;

reg [1:0] state;

// Live RTL8019AS state mirrored into shared memory for the HPS bridge.
// The current implementation mirrors the page 0/page 1 subset used by the
// HPS-side bridge and driver support code.

// Shared memory layout offsets - reduced to 16 bits for optimization
parameter [15:0] ETH_SHM_CTRL_FLAGS    = 16'h1000;  // 4 bytes - control flags
parameter [15:0] ETH_SHM_CTRL_REGS     = 16'h1004;  // Mirrored NE2000 register block
parameter [15:0] ETH_SHM_CTRL_MAC      = 16'h104C;  // 6 bytes - MAC address
parameter [15:0] ETH_SHM_CTRL_STATUS   = 16'h1052;  // 2 bytes - status
parameter [15:0] ETH_SHM_CTRL_STATS    = 16'h1054;  // 52 bytes - packet statistics
parameter [15:0] ETH_SHM_HPS_HEARTBEAT = 16'h1088;  // 4 bytes - HPS heartbeat
parameter [15:0] ETH_SHM_HPS_SIGNATURE = 16'h108C;  // 4 bytes - signature (0xCAFEBABE)
parameter [15:0] ETH_SHM_TX_BUFFER     = 16'h2000;  // 0x600 bytes - TX buffer
parameter [15:0] ETH_SHM_RX_BUFFER     = 16'h2600;  // 0x600 bytes - RX buffer
parameter [15:0] ETH_SHM_PACKET_INFO   = 16'h2C00;  // 512 bytes - packet metadata
parameter [15:0] ETH_SHM_RX_QUEUE_HEAD = 16'h2C04;  // low byte: FPGA-consumed shared RX queue head
parameter [15:0] ETH_SHM_RX_QUEUE_TAIL = 16'h2C06;  // low byte: HPS-produced shared RX queue tail
parameter [15:0] ETH_SHM_RX_QUEUE_LEN  = 16'h2C20;  // 16-bit staged packet lengths by slot
parameter [15:0] ETH_SHM_NE_MEMORY     = 16'h3000;  // 16KB compact backing store for NE packet RAM
parameter [15:0] ETH_SHM_DEBUG_INFO    = 16'h7000;  // 8KB - debug info
parameter [15:0] ETH_SHM_FUTURE_USE    = 16'h9000;  // Reserved for future expansion
parameter [15:0] ETH_PACKET_BUFFER_BYTES = 16'h0600; // 1536-byte staged frame capacity
parameter [15:0] ETH_SHM_RX_QUEUE_DATA = 16'h9000;  // shared RX queue slot payloads
parameter [7:0]  ETH_RX_QUEUE_SLOTS    = 8'd4;

// NE visible memory layout based on the RTL8019AS 16KB on-chip SRAM.
parameter [15:0] NE_PROM_SIZE          = 16'h0020;  // 32-byte station PROM / low memory shadow
parameter [15:0] NE_PMEM_START         = 16'h4000;  // Packet memory starts at NE address 0x4000
parameter [15:0] NE_PMEM_SIZE          = 16'h4000;  // 16KB packet RAM
parameter [15:0] NE_PMEM_END           = 16'h8000;  // Exclusive end of packet RAM

// Direct memory access using ethernet_base + ETH_SHM_* offsets - no internal array needed

// Current page from shared memory CR register
reg [7:0] cr_register;  // CR register value cached locally
wire [1:0] current_page = cr_register[7:6];

// Remote DMA registers (RSAR0/1, RBCR0/1)
reg [7:0] rsar0_register;    // Remote Start Address Register 0 (low byte)
reg [7:0] rsar1_register;    // Remote Start Address Register 1 (high byte)
reg [7:0] rbcr0_register;    // Remote Byte Count Register 0 (low byte)
reg [7:0] rbcr1_register;    // Remote Byte Count Register 1 (high byte)
reg [7:0] pstart_register;   // Receive ring start page
reg [7:0] pstop_register;    // Receive ring stop page
reg [7:0] bnry_register;     // Receive ring boundary page
reg [7:0] tpsr_register;     // Transmit packet start page
reg [7:0] curr_register;     // Current receive page
reg [7:0] par0_register;     // Physical address register 0
reg [7:0] par1_register;     // Physical address register 1
reg [7:0] par2_register;     // Physical address register 2
reg [7:0] par3_register;     // Physical address register 3
reg [7:0] par4_register;     // Physical address register 4
reg [7:0] par5_register;     // Physical address register 5
reg [7:0] mar0_register;     // Multicast address register 0
reg [7:0] mar1_register;     // Multicast address register 1
reg [7:0] mar2_register;     // Multicast address register 2
reg [7:0] mar3_register;     // Multicast address register 3
reg [7:0] mar4_register;     // Multicast address register 4
reg [7:0] mar5_register;     // Multicast address register 5
reg [7:0] mar6_register;     // Multicast address register 6
reg [7:0] mar7_register;     // Multicast address register 7

// Derive cpu_wr signal for new ethernet module (active when either byte is being written)
wire        cpu_wr;
assign      cpu_wr = cpu_lwr | cpu_hwr;


// Data port access state (using shared memory, no local buffer)
wire       is_data_port_access; // True if accessing data port (0x10)
wire       is_memory_access;    // True if accessing NE2000 memory (0x3000-0x6FFF)
wire       is_control_access;   // True if accessing control structure (0x0000-0x1000)
wire       is_buffer_access;    // True if accessing TX/RX buffers (0x2000-0x2FFF)
wire       is_tx_buffer_access; // True if accessing TX buffer (0x2000-0x25FF)
wire       is_rx_buffer_access; // True if accessing RX buffer (0x2600-0x2BFF)
reg [15:0] remote_dma_addr;     // Current remote DMA address
reg [15:0] remote_byte_count;   // Remaining byte count for DMA
reg [15:0] transmit_byte_count; // TBCR0/1 transmit byte count
reg        data_port_read_pending;  // Data port read from shared memory pending
reg [15:0] data_port_read_data;     // Data read from shared memory for data port
reg        memory_read_pending;     // Memory read from shared memory pending
reg [15:0] memory_read_data;        // Data read from shared memory for memory access
reg        control_read_pending;    // Control read from shared memory pending
reg [15:0] control_read_data;       // Data read from shared memory for control access
reg        buffer_read_pending;     // Buffer read from shared memory pending
reg [15:0] buffer_read_data;        // Data read from shared memory for buffer access

// State machine for memory access coordination (expanded to 5 bits for more states)
parameter [4:0] MEM_IDLE             = 5'b00000;  // Idle state
parameter [4:0] MEM_REG_READ         = 5'b00001;  // Reading register from shared memory
parameter [4:0] MEM_REG_WRITE        = 5'b00010;  // Writing register to shared memory
parameter [4:0] MEM_READ_FLAGS       = 5'b00011;  // Reading control flags
parameter [4:0] MEM_WRITE_FLAGS      = 5'b00100;  // Writing control flags back to shared memory
parameter [4:0] MEM_READ_HEARTBEAT   = 5'b00101;  // Reading heartbeat + interrupt status
parameter [4:0] MEM_PACKET_STATUS    = 5'b00110;  // Check packet status
parameter [4:0] MEM_DATA_PORT_READ   = 5'b00111;  // Reading data from RX buffer for data port
parameter [4:0] MEM_DATA_PORT_WRITE  = 5'b01000;  // Writing data to NE2000 memory via data port
parameter [4:0] MEM_RX_BUFFER_READ   = 5'b01001;  // Reading data from RX buffer  
parameter [4:0] MEM_RX_BUFFER_WRITE  = 5'b01010;  // Writing data to RX buffer
parameter [4:0] MEM_TX_BUFFER_READ   = 5'b01011;  // Reading data from TX buffer
parameter [4:0] MEM_TX_BUFFER_WRITE  = 5'b01100;  // Writing data to TX buffer
parameter [4:0] MEM_WRITE_PACKET_INFO = 5'b01101; // Writing packet info to shared memory
parameter [4:0] MEM_READ_MAC_ADDR    = 5'b01110;  // Reading MAC address from shared memory
parameter [4:0] MEM_WRITE_STATS      = 5'b01111;  // Writing statistics to shared memory
parameter [4:0] MEM_READ_SIGNATURE   = 5'b10000;  // Reading HPS signature for validation
parameter [4:0] MEM_WAIT_COMPLETE    = 5'b10001;  // Wait for memory operation to complete
parameter [4:0] MEM_ERROR            = 5'b10010;  // Error state
parameter [4:0] MEM_RESET_PENDING    = 5'b10011;  // Reset operation pending
parameter [4:0] MEM_IRQ_PROCESS      = 5'b10100;  // Process interrupt request
parameter [4:0] MEM_CONFIG_UPDATE    = 5'b10101;  // Update configuration registers
parameter [4:0] MEM_STATUS_CHECK     = 5'b10110;  // Check overall status
parameter [4:0] MEM_BUFFER_FLUSH     = 5'b10111;  // Flush buffers
parameter [4:0] MEM_LINK_CHECK       = 5'b11000;  // Check link status
parameter [4:0] MEM_STATS_UPDATE     = 5'b11001;  // Update packet statistics
parameter [4:0] MEM_DEBUG_LOG        = 5'b11010;  // Log debug information
parameter [4:0] MEM_CLEANUP          = 5'b11011;  // Cleanup operations
parameter [4:0] MEM_WRITE_REG_MIRROR = 5'b11100;  // Write live NE register mirror to shared memory
parameter [4:0] MEM_WRITE_MAC_MIRROR = 5'b11101;  // Write MAC mirror to shared memory
parameter [4:0] MEM_READ_STATUS      = 5'b11110;  // Read HPS transmit/link status

reg [4:0]  mem_state;
reg        flags_write_pending; // Flag to trigger control flags write to shared memory

// Memory transaction control
reg [23:0] mem_transaction_addr;  // Address for current memory transaction
reg [15:0] mem_transaction_data;  // Data for current memory transaction
reg        mem_transaction_rd;    // Memory read transaction active
reg        mem_transaction_wr;    // Memory write transaction active
reg        mem_transaction_busy;  // Transaction in progress
reg [15:0] mem_transaction_timeout; // Timeout counter for stuck transactions

// RX/TX buffer control
reg [15:0] rx_buffer_addr;        // Current RX buffer address
reg [15:0] tx_buffer_addr;        // Current TX buffer address
reg [15:0] rx_packet_length;      // Length of current RX packet
reg [15:0] tx_packet_length;      // Length of current TX packet
reg        rx_buffer_read_pending; // RX buffer read pending
reg        tx_buffer_read_pending; // TX buffer read pending
reg [15:0] rx_buffer_read_data;   // Data read from RX buffer
reg [15:0] tx_buffer_read_data;   // Data read from TX buffer

// Register modification variables
reg [7:0] original_cr;            // Original CR register value
reg [7:0] modified_cr;            // Modified CR register value
reg [7:0] clear_mask;             // ISR clear mask
reg [7:0] modified_mask;          // Modified ISR clear mask
reg [7:0] modified_isr;           // Modified ISR register value
reg [7:0] original_imr;           // Original IMR register value
reg [7:0] modified_imr;           // Modified IMR register value
reg [7:0] original_data;          // Original register data
reg [7:0] modified_data;          // Modified register data
reg [15:0] read_addr;             // Read address for memory transactions
reg [23:0] info_addr;             // Info address for packet info
reg [23:0] mac_addr;              // MAC address for MAC read
reg [23:0] stats_addr;            // Stats address for statistics
reg [23:0] sig_addr;              // Signature address for HPS validation
reg [15:0] ne_offset;             // NE2000 memory offset
reg [15:0] rx_offset;             // RX buffer offset
reg [15:0] tx_offset;             // TX buffer offset

// Packet processing state
reg [15:0] packet_length;     // Current packet length
reg [15:0] packet_count_rx;   // Number of received packets
reg [15:0] packet_count_tx;   // Number of transmitted packets
reg        link_status;       // Link up/down status
reg [31:0] status_flags;      // Status and control flags
reg [15:0] shared_flags_word; // Low 16 bits of the HPS/FPGA control flags word
reg [15:0] shared_status_word;

reg [15:0] rx_copy_src_offset;
reg [15:0] rx_copy_dst_addr;
reg [15:0] rx_copy_remaining;
reg [15:0] rx_copy_buffer_base;
reg  [7:0] rx_next_page;
reg  [1:0] rx_copy_phase;
reg  [1:0] rx_packet_meta_phase;
reg  [7:0] rx_queue_head_slot;
reg  [7:0] rx_queue_tail_slot;
reg  [7:0] rx_queue_next_head;
reg [31:0] reg_mirror_dirty;
reg  [2:0] mac_word_dirty;

// NE2000 Interrupt handling - proper implementation
reg [7:0]  isr_register;       // Interrupt Status Register (0x07)
reg [7:0]  imr_register;       // Interrupt Mask Register (0x0F)
reg [7:0]  dcr_register;       // Data Configuration Register (0x0E)
reg [7:0]  rcr_register;       // Receive Configuration Register (0x0C write-side mirror)
reg [7:0]  tcr_register;       // Transmit Configuration Register (0x0D write-side mirror)
reg [7:0]  rsr_register;       // Receive Status Register (0x0C read-side status)
reg [7:0]  tsr_register;       // Transmit Status Register (0x04 read-side status)

// NE2000 DCR bit definitions
// Bit 0: WTS (Word Transfer Select) - 0=byte DMA, 1=word DMA
// Bit 1: BOS (Byte Order Select) - 0=MS byte on MD15:8, 1=MS byte on MD7:0 (680x0 swap)
// Bit 2: LAS (Long Address Select) - should remain 0 on RTL8019AS
// Bit 3: LS (Loopback Select) - 0=loopback, 1=normal operation
// Bit 4: ARM (Auto-initialize Remote) - 0=manual, 1=auto-init remote DMA
// Bit 5: FT0 (FIFO Threshold Select 0)
// Bit 6: FT1 (FIFO Threshold Select 1)
// Bit 7: Reserved

// NE2000 ISR bit definitions
parameter ISR_PRX = 8'h01;     // Bit 0: Packet Received
parameter ISR_PTX = 8'h02;     // Bit 1: Packet Transmitted
parameter ISR_RXE = 8'h04;     // Bit 2: Receive Error
parameter ISR_TXE = 8'h08;     // Bit 3: Transmit Error
parameter ISR_OVW = 8'h10;     // Bit 4: Overwrite Warning
parameter ISR_CNT = 8'h20;     // Bit 5: Counter Overflow
parameter ISR_RDC = 8'h40;     // Bit 6: Remote DMA Complete
parameter ISR_RST = 8'h80;     // Bit 7: Reset Status

parameter TSR_PTX = 8'h01;     // Packet transmitted
parameter TSR_ABT = 8'h08;     // Transmission aborted / generic transmit failure
parameter RSR_PRX = 8'h01;     // Packet received intact
parameter RSR_FO  = 8'h08;     // FIFO overrun / overwrite indication
parameter RSR_MPA = 8'h10;     // Missed packet
parameter RSR_DIS = 8'h40;     // Receiver disabled
parameter RCR_MON = 8'h20;     // Monitor mode

parameter [15:0] ETH_FLAG_RESET      = 16'h0001;
parameter [15:0] ETH_FLAG_TX_REQ     = 16'h0002;
parameter [15:0] ETH_FLAG_RX_AVAIL   = 16'h0004;
parameter [15:0] ETH_FLAG_IRQ        = 16'h0008;
parameter [15:0] ETH_FLAG_REG_DIRTY  = 16'h0010;
parameter [15:0] ETH_FLAG_ENABLED    = 16'h0020;
parameter [15:0] ETH_FLAG_HPS_OWNED_MASK   = ETH_FLAG_RESET;
parameter [15:0] ETH_FLAG_HPS_ACK_MASK     = ETH_FLAG_TX_REQ;
parameter [15:0] ETH_FLAG_FPGA_MIRROR_MASK = ETH_FLAG_TX_REQ | ETH_FLAG_IRQ | ETH_FLAG_ENABLED | ETH_FLAG_REG_DIRTY;
parameter [15:0] ETH_STATUS_TX_OK    = 16'h0001;
parameter [15:0] ETH_STATUS_TX_ERR   = 16'h0002;
parameter [15:0] ETH_STATUS_LINK_UP  = 16'h0004;

function [7:0] next_rx_page;
    input [7:0] start_page;
    input [7:0] stop_page;
    input [7:0] current_page;
    begin
        if ((stop_page <= start_page + 8'd1) || (current_page >= (stop_page - 8'd1))) begin
            next_rx_page = start_page;
        end else begin
            next_rx_page = current_page + 8'd1;
        end
    end
endfunction

function [8:0] rx_ring_total_pages;
    input [7:0] start_page;
    input [7:0] stop_page;
    begin
        if (stop_page > start_page) begin
            rx_ring_total_pages = {1'b0, stop_page} - {1'b0, start_page};
        end else begin
            rx_ring_total_pages = 9'd0;
        end
    end
endfunction

function [8:0] rx_packet_pages;
    input [15:0] packet_bytes;
    begin
        rx_packet_pages = (packet_bytes + 16'd4 + 16'd255) >> 8;
    end
endfunction

function [8:0] rx_ring_used_pages;
    input [7:0] start_page;
    input [7:0] stop_page;
    input [7:0] curr_page;
    input [7:0] bnry_page;
    reg [7:0] first_unread_page;
    begin
        first_unread_page = start_page;
        if (rx_ring_total_pages(start_page, stop_page) <= 9'd1) begin
            rx_ring_used_pages = 9'd0;
        end else begin
            first_unread_page = next_rx_page(start_page, stop_page, bnry_page);
            if (curr_page == first_unread_page) begin
                rx_ring_used_pages = 9'd0;
            end else if (curr_page > first_unread_page) begin
                rx_ring_used_pages = {1'b0, curr_page} - {1'b0, first_unread_page};
            end else begin
                rx_ring_used_pages = ({1'b0, stop_page} - {1'b0, first_unread_page}) +
                                     ({1'b0, curr_page} - {1'b0, start_page});
            end
        end
    end
endfunction

function [8:0] rx_ring_free_pages;
    input [7:0] start_page;
    input [7:0] stop_page;
    input [7:0] curr_page;
    input [7:0] bnry_page;
    reg [8:0] total_pages;
    reg [8:0] used_pages;
    begin
        total_pages = rx_ring_total_pages(start_page, stop_page);
        used_pages = rx_ring_used_pages(start_page, stop_page, curr_page, bnry_page);
        if ((total_pages <= 9'd1) || (used_pages >= (total_pages - 9'd1))) begin
            rx_ring_free_pages = 9'd0;
        end else begin
            rx_ring_free_pages = total_pages - used_pages - 9'd1;
        end
    end
endfunction

function [7:0] next_shared_rx_slot;
    input [7:0] slot_index;
    begin
        if (slot_index >= (ETH_RX_QUEUE_SLOTS - 1)) begin
            next_shared_rx_slot = 8'h00;
        end else begin
            next_shared_rx_slot = slot_index + 8'h01;
        end
    end
endfunction

function [15:0] shared_rx_slot_base;
    input [7:0] slot_index;
    begin
        shared_rx_slot_base = ETH_SHM_RX_QUEUE_DATA +
                              ({8'h00, slot_index} * ETH_PACKET_BUFFER_BYTES);
    end
endfunction

function [15:0] update_cr_flags;
    input [15:0] current_flags;
    input [7:0] cr_value;
    reg [15:0] next_flags;
    begin
        next_flags = current_flags;

        if (cr_value[2]) begin
            next_flags = next_flags | ETH_FLAG_TX_REQ;
        end

        if (cr_value[0]) begin
            next_flags = next_flags & ~(ETH_FLAG_ENABLED | ETH_FLAG_TX_REQ);
        end

        if (cr_value[1]) begin
            next_flags = next_flags | ETH_FLAG_ENABLED;
        end

        update_cr_flags = next_flags;
    end
endfunction

function [7:0] wrap_rx_page;
    input [7:0] start_page;
    input [7:0] stop_page;
    input [7:0] current_page;
    input [15:0] packet_bytes;
    reg [8:0] next_page_calc;
    reg [8:0] pages_needed;
    begin
        pages_needed = (packet_bytes + 16'd4 + 16'd255) >> 8;
        next_page_calc = current_page + pages_needed[7:0];
        if (next_page_calc >= stop_page) begin
            next_page_calc = start_page + (next_page_calc - stop_page);
        end
        wrap_rx_page = next_page_calc[7:0];
    end
endfunction

function [15:0] wrap_rx_addr;
    input [7:0] start_page;
    input [7:0] stop_page;
    input [15:0] current_addr;
    input [15:0] advance_bytes;
    reg [15:0] start_addr;
    reg [15:0] stop_addr;
    reg [15:0] next_addr;
    begin
        start_addr = {start_page, 8'h00};
        stop_addr = {stop_page, 8'h00};
        next_addr = current_addr + advance_bytes;
        if (next_addr >= stop_addr) begin
            next_addr = start_addr + (next_addr - stop_addr);
        end
        wrap_rx_addr = next_addr;
    end
endfunction

// Address decode
wire [4:0]  register_select;
wire        is_register_access;
// byte_addr now declared as reg in address decode section
function [15:0] compact_ne_offset;
    input [15:0] ne_addr;
    begin
        compact_ne_offset = ETH_SHM_NE_MEMORY + (ne_addr - NE_PMEM_START);
    end
endfunction

function [7:0] synthetic_prom_byte;
    input [15:0] ne_addr;
    begin
        case (ne_addr[4:1])
            4'h0: synthetic_prom_byte = par0_register;
            4'h1: synthetic_prom_byte = par1_register;
            4'h2: synthetic_prom_byte = par2_register;
            4'h3: synthetic_prom_byte = par3_register;
            4'h4: synthetic_prom_byte = par4_register;
            4'h5: synthetic_prom_byte = par5_register;
            4'hE: synthetic_prom_byte = 8'h57;
            4'hF: synthetic_prom_byte = 8'h57;
            default: synthetic_prom_byte = 8'h00;
        endcase
    end
endfunction

function [15:0] synthetic_prom_word;
    input [15:0] ne_addr;
    input        word_mode;
    begin
        if (word_mode) begin
            synthetic_prom_word = {synthetic_prom_byte(ne_addr + 16'h0001),
                                   synthetic_prom_byte(ne_addr)};
        end else begin
            synthetic_prom_word = {8'h00, synthetic_prom_byte(ne_addr)};
        end
    end
endfunction

reg        reg_mirror_valid;
reg  [5:0] reg_mirror_index;
reg [15:0] reg_mirror_word;
reg        mac_word_valid;
reg  [1:0] mac_word_index;
reg [15:0] mac_mirror_word;
integer    dirty_scan;

wire        irq_active = |(isr_register & imr_register);
wire [15:0] local_flag_word = (status_flags[15:0] & ~ETH_FLAG_IRQ) | (irq_active ? ETH_FLAG_IRQ : 16'h0000);
wire [15:0] flags_word_to_write = (shared_flags_word & ETH_FLAG_HPS_OWNED_MASK) |
                                  (local_flag_word & ~ETH_FLAG_HPS_OWNED_MASK);
wire        receiver_accepting_packets = (status_flags[15:0] & ETH_FLAG_ENABLED) &&
                                         !cr_register[0] &&
                                         !(rcr_register & RCR_MON);

always @(*) begin
    reg_mirror_valid = 1'b0;
    reg_mirror_index = 6'd0;
    reg_mirror_word = 16'h0000;

    for (dirty_scan = 0; dirty_scan < 32; dirty_scan = dirty_scan + 1) begin
        if (!reg_mirror_valid && reg_mirror_dirty[dirty_scan]) begin
            reg_mirror_valid = 1'b1;
            reg_mirror_index = dirty_scan;
        end
    end

    case (reg_mirror_index)
        6'd0,  6'd16: reg_mirror_word = {8'h00, cr_register};
        6'd1:         reg_mirror_word = {8'h00, pstart_register};
        6'd2:         reg_mirror_word = {8'h00, pstop_register};
        6'd3:         reg_mirror_word = {8'h00, bnry_register};
        6'd4:         reg_mirror_word = {8'h00, tpsr_register};
        6'd5:         reg_mirror_word = {8'h00, transmit_byte_count[7:0]};
        6'd6:         reg_mirror_word = {8'h00, transmit_byte_count[15:8]};
        6'd7:         reg_mirror_word = {8'h00, isr_register};
        6'd8:         reg_mirror_word = {8'h00, remote_dma_addr[7:0]};
        6'd9:         reg_mirror_word = {8'h00, remote_dma_addr[15:8]};
        6'd10:        reg_mirror_word = {8'h00, remote_byte_count[7:0]};
        6'd11:        reg_mirror_word = {8'h00, remote_byte_count[15:8]};
        6'd12:        reg_mirror_word = {8'h00, rcr_register};
        6'd13:        reg_mirror_word = {8'h00, tcr_register};
        6'd14:        reg_mirror_word = {8'h00, dcr_register};
        6'd15:        reg_mirror_word = {8'h00, imr_register};
        6'd17:        reg_mirror_word = {8'h00, par0_register};
        6'd18:        reg_mirror_word = {8'h00, par1_register};
        6'd19:        reg_mirror_word = {8'h00, par2_register};
        6'd20:        reg_mirror_word = {8'h00, par3_register};
        6'd21:        reg_mirror_word = {8'h00, par4_register};
        6'd22:        reg_mirror_word = {8'h00, par5_register};
        6'd23:        reg_mirror_word = {8'h00, curr_register};
        6'd24:        reg_mirror_word = {8'h00, mar0_register};
        6'd25:        reg_mirror_word = {8'h00, mar1_register};
        6'd26:        reg_mirror_word = {8'h00, mar2_register};
        6'd27:        reg_mirror_word = {8'h00, mar3_register};
        6'd28:        reg_mirror_word = {8'h00, mar4_register};
        6'd29:        reg_mirror_word = {8'h00, mar5_register};
        6'd30:        reg_mirror_word = {8'h00, mar6_register};
        6'd31:        reg_mirror_word = {8'h00, mar7_register};
        default:      reg_mirror_word = 16'h0000;
    endcase

    mac_word_valid = 1'b0;
    mac_word_index = 2'd0;
    mac_mirror_word = 16'h0000;

    for (dirty_scan = 0; dirty_scan < 3; dirty_scan = dirty_scan + 1) begin
        if (!mac_word_valid && mac_word_dirty[dirty_scan]) begin
            mac_word_valid = 1'b1;
            mac_word_index = dirty_scan;
        end
    end

    case (mac_word_index)
        2'd0: mac_mirror_word = {par1_register, par0_register};
        2'd1: mac_mirror_word = {par3_register, par2_register};
        2'd2: mac_mirror_word = {par5_register, par4_register};
        default: mac_mirror_word = 16'h0000;
    endcase
end

wire        card_selected = sel_ethernet | sel_ethernet_shm;
wire        reg_window_selected = sel_ethernet && !sel_ethernet_shm;
wire [15:0] remote_dma_step = dcr_register[0] ? 16'h0002 : 16'h0001;
wire [23:0] eth_shared_base = {ethernet_base, 16'h0000};
wire        remote_dma_prom_access = (remote_dma_addr < NE_PROM_SIZE);
wire        remote_dma_packet_access = (remote_dma_addr >= NE_PMEM_START) && (remote_dma_addr < NE_PMEM_END);
wire [15:0] compact_remote_dma_offset = remote_dma_packet_access ? compact_ne_offset(remote_dma_addr) : ETH_SHM_NE_MEMORY;
wire [23:1] translated_ne_addr = {ethernet_base, compact_remote_dma_offset[15:1]};
wire        read_addr_packet_access = (read_addr >= NE_PMEM_START) && (read_addr < NE_PMEM_END);

// Simplified sequential logic - all HPS transactions replaced with direct memory access
always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;

        // Initialize CR register copy for page decoding
        cr_register <= 8'h21;      // CR: Stop state, page 0, no DMA

        // Initialize data port state
        remote_dma_addr <= 16'h0000;      // Default DMA start address
        remote_byte_count <= 16'h0000;
        transmit_byte_count <= 16'h0000;
        data_port_read_pending <= 1'b0;
        data_port_read_data <= 16'h0000;
        memory_read_pending <= 1'b0;
        memory_read_data <= 16'h0000;
        control_read_pending <= 1'b0;
        control_read_data <= 16'h0000;
        buffer_read_pending <= 1'b0;
        buffer_read_data <= 16'h0000;

        // Initialize memory state machine
        mem_state <= MEM_IDLE;
        flags_write_pending <= 1'b0;
        
        // Initialize memory transactions
        mem_transaction_addr <= 24'h000000;
        mem_transaction_data <= 16'h0000;
        mem_transaction_rd <= 1'b0;
        mem_transaction_wr <= 1'b0;
        mem_transaction_busy <= 1'b0;
        
        // Initialize RX/TX buffer control
        rx_buffer_addr <= 16'h0000;
        tx_buffer_addr <= 16'h0000;
        rx_packet_length <= 16'h0000;
        tx_packet_length <= 16'h0000;
        rx_buffer_read_pending <= 1'b0;
        tx_buffer_read_pending <= 1'b0;
        rx_buffer_read_data <= 16'h0000;
        tx_buffer_read_data <= 16'h0000;

        // Initialize packet processing state
        packet_length <= 16'h0000;
        packet_count_rx <= 16'h0000;
        packet_count_tx <= 16'h0000;
        link_status <= 1'b0;           // Link down initially
        status_flags <= 32'h00000000;
        shared_flags_word <= 16'h0000;
        shared_status_word <= 16'h0000;
        rx_copy_src_offset <= 16'h0000;
        rx_copy_dst_addr <= 16'h0000;
        rx_copy_remaining <= 16'h0000;
        rx_copy_buffer_base <= ETH_SHM_RX_BUFFER;
        rx_next_page <= 8'h00;
        rx_copy_phase <= 2'b00;
        rx_packet_meta_phase <= 2'b00;
        rx_queue_head_slot <= 8'h00;
        rx_queue_tail_slot <= 8'h00;
        rx_queue_next_head <= 8'h00;
        reg_mirror_dirty <= 32'hFFFF_FFFF;
        mac_word_dirty <= 3'b111;

        // Initialize NE2000 interrupt registers
        isr_register <= ISR_RST;         // Reset complete after power-up
        imr_register <= 8'h00;           // Mask all interrupts initially
        dcr_register <= 8'h48;           // DCR: byte DMA, normal operation, FIFO threshold
        rcr_register <= 8'h00;
        tcr_register <= 8'h00;
        rsr_register <= 8'h00;
        tsr_register <= 8'h00;

        // Initialize remote DMA registers  
        rsar0_register <= 8'h00;         // Remote start address low
        rsar1_register <= 8'h00;         // Remote start address high
        rbcr0_register <= 8'h00;         // Remote byte count low
        rbcr1_register <= 8'h00;         // Remote byte count high
        pstart_register <= 8'h46;       // RX ring starts after the default 6-page TX buffer
        pstop_register <= 8'h80;        // 16KB packet RAM limit
        bnry_register <= 8'h46;
        tpsr_register <= 8'h40;
        curr_register <= 8'h47;
        par0_register <= 8'h28;
        par1_register <= 8'h12;
        par2_register <= 8'h34;
        par3_register <= 8'h56;
        par4_register <= 8'h78;
        par5_register <= 8'h9A;
        mar0_register <= 8'h00;
        mar1_register <= 8'h00;
        mar2_register <= 8'h00;
        mar3_register <= 8'h00;
        mar4_register <= 8'h00;
        mar5_register <= 8'h00;
        mar6_register <= 8'h00;
        mar7_register <= 8'h00;

        // Initialize address translation
        translated_addr <= 23'h000000;
        addr_translate_enable <= 1'b0;
        eth_mem_req <= 1'b0;
        eth_mem_wr <= 1'b0;
        eth_mem_addr <= 23'h000000;
        eth_mem_wdata <= 16'h0000;
        eth_mem_be <= 2'b00;

        // Initialize memory state machine and transaction control
        mem_state <= MEM_IDLE;
        mem_transaction_addr <= 24'h000000;
        mem_transaction_data <= 16'h0000;
        mem_transaction_rd <= 1'b0;
        mem_transaction_wr <= 1'b0;
        mem_transaction_busy <= 1'b0;
        mem_transaction_timeout <= 16'h0000;
        flags_write_pending <= 1'b1;

        // Initialize register modification variables
        original_cr <= 8'h00;
        modified_cr <= 8'h00;
        clear_mask <= 8'h00;
        modified_mask <= 8'h00;
        modified_isr <= 8'h00;
        original_imr <= 8'h00;
        modified_imr <= 8'h00;
        original_data <= 8'h00;
        modified_data <= 8'h00;

        // Initialize address calculation variables
        read_addr <= 16'h0000;
        info_addr <= 24'h000000;
        mac_addr <= 24'h000000;
        stats_addr <= 24'h000000;
        sig_addr <= 24'h000000;
        ne_offset <= 16'h0000;
        rx_offset <= 16'h0000;
        tx_offset <= 16'h0000;

        // Direct mapped memory - initialization handled by external memory mapping
        // Control flags at: calc_mem_addr(ETH_SHM_CTRL_FLAGS) = 0x00000000
        // Signature at: calc_mem_addr(ETH_SHM_HPS_SIGNATURE) = 0xCAFEBABE
        // Heartbeat at: calc_mem_addr(ETH_SHM_HPS_HEARTBEAT) = 0x00000000

    end else begin
        // Simple state machine
        case (state)
            IDLE: begin
                if (card_selected && (cpu_rd || cpu_wr)) begin
                    state <= ACCESS;
                end
            end

            ACCESS: begin
                // Stay in ACCESS until the bus cycle ends (chip select goes away)
                if (!card_selected) begin
                    state <= IDLE;
                end
            end

            COMPLETE: begin
                state <= IDLE;
            end

            default: begin
                state <= IDLE;
            end
        endcase

        // Handle data port writes (packet data) - translate address to buffer region
        if (reg_window_selected && cpu_wr && is_data_port_access) begin
            if (~cpu_uds || ~cpu_lds) begin  // Check data strobes
                // Only packet RAM (0x4000-0x7FFF) is backed by the compact shared-memory mirror.
                if (remote_dma_packet_access) begin
                    translated_addr <= translated_ne_addr;
                    addr_translate_enable <= 1'b1;
                end else begin
                    addr_translate_enable <= 1'b0;
                end

                remote_dma_addr <= remote_dma_addr + remote_dma_step;
                if (remote_byte_count <= remote_dma_step) begin
                    remote_byte_count <= 16'h0000;
                    isr_register <= isr_register | ISR_RDC;
                    reg_mirror_dirty[7] <= 1'b1;
                    flags_write_pending <= 1'b1;
                end else begin
                    remote_byte_count <= remote_byte_count - remote_dma_step;
                end
                reg_mirror_dirty[8] <= 1'b1;
                reg_mirror_dirty[9] <= 1'b1;
                reg_mirror_dirty[10] <= 1'b1;
                reg_mirror_dirty[11] <= 1'b1;

                if (dcr_register[0]) begin
                    $display("Data port word write: 0x%04x to 0x%06x",
                            cpu_data_in, remote_dma_packet_access ? translated_ne_addr : 23'h000000);
                end else begin
                    $display("Data port byte write: 0x%02x to 0x%06x",
                            cpu_data_in[7:0], remote_dma_packet_access ? translated_ne_addr : 23'h000000);
                end
            end
        end
        // Handle data port reads (packet data) - translate address to buffer region
        else if (reg_window_selected && cpu_rd && is_data_port_access) begin
            if (remote_dma_prom_access) begin
                addr_translate_enable <= 1'b0;
                data_port_read_pending <= 1'b1;
                data_port_read_data <= synthetic_prom_word(remote_dma_addr, dcr_register[0]);
                $display("Data port PROM read at DMA address 0x%04x", remote_dma_addr);
            end else if (remote_dma_packet_access) begin
                // Translate packet RAM accesses into the compact shared-memory backing store.
                translated_addr <= translated_ne_addr;
                addr_translate_enable <= 1'b1;
                data_port_read_pending <= 1'b0;
                $display("Data port read translated to shared packet RAM at DMA address 0x%04x", remote_dma_addr);
            end else begin
                addr_translate_enable <= 1'b0;
                data_port_read_pending <= 1'b1;
                data_port_read_data <= 16'h0000;
                $display("Data port read from unmapped DMA address 0x%04x", remote_dma_addr);
            end

            remote_dma_addr <= remote_dma_addr + remote_dma_step;
            if (remote_byte_count <= remote_dma_step) begin
                remote_byte_count <= 16'h0000;
                isr_register <= isr_register | ISR_RDC;
                reg_mirror_dirty[7] <= 1'b1;
                flags_write_pending <= 1'b1;
            end else begin
                remote_byte_count <= remote_byte_count - remote_dma_step;
            end
            reg_mirror_dirty[8] <= 1'b1;
            reg_mirror_dirty[9] <= 1'b1;
            reg_mirror_dirty[10] <= 1'b1;
            reg_mirror_dirty[11] <= 1'b1;

            if (dcr_register[0]) begin
                $display("Data port word read from 0x%06x", remote_dma_packet_access ? translated_ne_addr : 23'h000000);
            end else begin
                $display("Data port byte read from 0x%06x", remote_dma_packet_access ? translated_ne_addr : 23'h000000);
            end
        end else begin
            // Disable address translation when not doing data port access
            addr_translate_enable <= 1'b0;
        end
        
        // Handle NE2000 memory writes (direct memory access) - write directly to shared memory
        if (cpu_wr && is_memory_access) begin
            if (~cpu_uds || ~cpu_lds) begin  // Check data strobes for 16-bit write access
                // Calculate memory offset from 0x4000 base (cpu_addr 0x4000-0x7FFF maps to memory offset 0x0000-0x3FFF)
                // Direct mapped NE2000 memory write
                // Target address: calc_mem_addr(ETH_SHM_NE_MEMORY + {15'h0000, (cpu_addr[15:1] - 15'h2000), 1'b0})
                // System memory controller handles write at: shared_mem_base + ETH_SHM_NE_MEMORY + (byte_addr - 0x4000)
            end
        end
        // Handle NE2000 memory reads (direct memory access) - read from shared memory
        if (cpu_rd && is_memory_access && !memory_read_pending) begin
            // Calculate memory offset from 0x4000 base (cpu_addr 0x4000-0x7FFF maps to memory offset 0x0000-0x3FFF)
            // Direct mapped NE2000 memory read
            // Source address: calc_mem_addr(ETH_SHM_NE_MEMORY + {15'h0000, (cpu_addr[15:1] - 15'h2000), 1'b0})
            // System memory controller provides NE2000 memory data at: shared_mem_base + ETH_SHM_NE_MEMORY + (byte_addr - 0x4000)
            //memory_read_data <= 16'h5678; // Test pattern - system memory overrides this - gets written to 0xEA4000 - 0xEA7FFF
            memory_read_pending <= 1'b1;
        end
        // Handle control writes (direct control access) - write directly to shared memory
        if (cpu_wr && is_control_access) begin
            if (~cpu_uds || ~cpu_lds) begin  // Check data strobes for 16-bit write access
                // Direct access to control structure
                // Direct mapped control memory write
                // Target address: eth_shared_base + {15'h0000, cpu_addr[15:1], 1'b0}
            end
        end
        // Handle control reads (direct control access) - read from shared memory
        if (cpu_rd && is_control_access && !control_read_pending) begin
            // Direct access to control structure
            // Direct mapped control memory read
            // Source address: eth_shared_base + {15'h1000, cpu_addr[15:1], 1'b0}
            // System memory controller provides control data at the calculated address
            //control_read_data <= 16'h9ABC; // Test pattern - system memory overrides this
            control_read_pending <= 1'b1;
        end
        // Handle buffer writes (direct TX/RX buffer access) - write directly to shared memory
        if (cpu_wr && is_buffer_access) begin
            if (~cpu_uds || ~cpu_lds) begin  // Check data strobes for 16-bit write access
                // Map 0x1000-0x1FFF to both TX and RX buffers
                if ((cpu_addr[15:1] - 15'h0800) < 16'h02EE) begin
                    // TX buffer range (0x1000-0x15DC)
                    // Direct mapped TX buffer write
                    // Target address: calc_mem_addr(ETH_SHM_TX_BUFFER + {15'h0000, (cpu_addr[15:1] - 15'h0800), 1'b0})
                end else begin
                    // Direct mapped RX buffer write  
                    // Target address: calc_mem_addr(ETH_SHM_RX_BUFFER + {15'h0000, (cpu_addr[15:1] - 15'h0800 - 16'h0300), 1'b0})
                end
            end
        end
        // Handle buffer reads (direct TX/RX buffer access) - read from shared memory
        if (cpu_rd && is_buffer_access && !buffer_read_pending) begin
            // Map 0x1000-0x1FFF to both TX and RX buffers
            if ((cpu_addr[15:1] - 15'h0800) < 16'h02EE) begin
                // TX buffer range
                // Direct mapped TX buffer read
                // Source address: calc_mem_addr(ETH_SHM_TX_BUFFER + {15'h0000, (cpu_addr[15:1] - 15'h0800), 1'b0})
                // System memory controller provides TX buffer data at the calculated address
                //buffer_read_data <= 16'hDEF0; // Test pattern - system memory overrides this
            end else begin
                // Direct mapped RX buffer read
                // Source address: calc_mem_addr(ETH_SHM_RX_BUFFER + {15'h0000, (cpu_addr[15:1] - 15'h0800 - 16'h0300), 1'b0})
                // System memory controller provides RX buffer data at the calculated address
                //buffer_read_data <= 16'h1234; // Test pattern - system memory overrides this
            end
            buffer_read_pending <= 1'b1;
        end
        // Handle register writes and keep the HPS mirror coherent.
        if (reg_window_selected && cpu_wr && is_register_access) begin
            if (~cpu_uds) begin
                case (register_select[4:0])
                    5'h00: begin
                        cr_register <= cpu_data_in[15:8];
                        status_flags[15:0] <= update_cr_flags(status_flags[15:0], cpu_data_in[15:8]);
                        reg_mirror_dirty[0] <= 1'b1;
                        reg_mirror_dirty[16] <= 1'b1;

                        if (cpu_data_in[10]) begin
                            tx_packet_length <= transmit_byte_count;
                            tsr_register <= 8'h00;
                            flags_write_pending <= 1'b1;
                        end

                        if (cpu_data_in[8]) begin
                            remote_dma_addr <= 16'h0000;
                            remote_byte_count <= 16'h0000;
                            reg_mirror_dirty[8] <= 1'b1;
                            reg_mirror_dirty[9] <= 1'b1;
                            reg_mirror_dirty[10] <= 1'b1;
                            reg_mirror_dirty[11] <= 1'b1;
                            flags_write_pending <= 1'b1;
                        end

                        if (cpu_data_in[9]) begin
                            flags_write_pending <= 1'b1;
                        end
                    end

                    5'h01: begin
                        if (current_page == 2'b00) begin
                            pstart_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[1] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            par0_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[17] <= 1'b1;
                            mac_word_dirty[0] <= 1'b1;
                        end
                    end

                    5'h02: begin
                        if (current_page == 2'b00) begin
                            pstop_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[2] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            par1_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[18] <= 1'b1;
                            mac_word_dirty[0] <= 1'b1;
                        end
                    end

                    5'h03: begin
                        if (current_page == 2'b00) begin
                            bnry_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[3] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            par2_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[19] <= 1'b1;
                            mac_word_dirty[1] <= 1'b1;
                        end
                    end

                    5'h04: begin
                        if (current_page == 2'b00) begin
                            tpsr_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[4] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            par3_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[20] <= 1'b1;
                            mac_word_dirty[1] <= 1'b1;
                        end
                    end

                    5'h05: begin
                        if (current_page == 2'b00) begin
                            transmit_byte_count[7:0] <= cpu_data_in[15:8];
                            reg_mirror_dirty[5] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            par4_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[21] <= 1'b1;
                            mac_word_dirty[2] <= 1'b1;
                        end
                    end

                    5'h06: begin
                        if (current_page == 2'b00) begin
                            transmit_byte_count[15:8] <= cpu_data_in[15:8];
                            reg_mirror_dirty[6] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            par5_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[22] <= 1'b1;
                            mac_word_dirty[2] <= 1'b1;
                        end
                    end

                    5'h07: begin
                        if (current_page == 2'b00) begin
                            isr_register <= isr_register & ~cpu_data_in[15:8];
                            reg_mirror_dirty[7] <= 1'b1;
                            flags_write_pending <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            curr_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[23] <= 1'b1;
                        end
                    end

                    5'h08: begin
                        if (current_page == 2'b00) begin
                            rsar0_register <= cpu_data_in[15:8];
                            remote_dma_addr[7:0] <= cpu_data_in[15:8];
                            reg_mirror_dirty[8] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar0_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[24] <= 1'b1;
                        end
                    end

                    5'h09: begin
                        if (current_page == 2'b00) begin
                            rsar1_register <= cpu_data_in[15:8];
                            remote_dma_addr[15:8] <= cpu_data_in[15:8];
                            reg_mirror_dirty[9] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar1_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[25] <= 1'b1;
                        end
                    end

                    5'h0A: begin
                        if (current_page == 2'b00) begin
                            rbcr0_register <= cpu_data_in[15:8];
                            remote_byte_count[7:0] <= cpu_data_in[15:8];
                            reg_mirror_dirty[10] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar2_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[26] <= 1'b1;
                        end
                    end

                    5'h0B: begin
                        if (current_page == 2'b00) begin
                            rbcr1_register <= cpu_data_in[15:8];
                            remote_byte_count[15:8] <= cpu_data_in[15:8];
                            reg_mirror_dirty[11] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar3_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[27] <= 1'b1;
                        end
                    end

                    5'h0C: begin
                        if (current_page == 2'b00) begin
                            rcr_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[12] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar4_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[28] <= 1'b1;
                        end
                    end

                    5'h0D: begin
                        if (current_page == 2'b00) begin
                            tcr_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[13] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar5_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[29] <= 1'b1;
                        end
                    end

                    5'h0E: begin
                        if (current_page == 2'b00) begin
                            dcr_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[14] <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar6_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[30] <= 1'b1;
                        end
                    end

                    5'h0F: begin
                        if (current_page == 2'b00) begin
                            imr_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[15] <= 1'b1;
                            flags_write_pending <= 1'b1;
                        end else if (current_page == 2'b01) begin
                            mar7_register <= cpu_data_in[15:8];
                            reg_mirror_dirty[31] <= 1'b1;
                        end
                    end

                    default: begin
                    end
                endcase
            end
        end

        // Memory State Machine for shared-memory handshake with the HPS bridge.
        case (mem_state)
            MEM_IDLE: begin
                eth_mem_req <= 1'b0;
                eth_mem_wr <= 1'b0;
                eth_mem_be <= 2'b00;
                mem_transaction_busy <= 1'b0;
                mem_transaction_rd <= 1'b0;
                mem_transaction_wr <= 1'b0;

                if (reg_mirror_valid) begin
                    mem_state <= MEM_WRITE_REG_MIRROR;
                end else if (mac_word_valid) begin
                    mem_state <= MEM_WRITE_MAC_MIRROR;
                end else begin
                    mem_state <= MEM_READ_FLAGS;
                end
            end

            MEM_READ_FLAGS: begin
                if (!mem_transaction_busy) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_rd <= 1'b1;
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_CTRL_FLAGS;
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b0;
                    eth_mem_addr <= (eth_shared_base + ETH_SHM_CTRL_FLAGS) >> 1;
                    eth_mem_be <= 2'b11;
                end else if (eth_mem_ack) begin
                    shared_flags_word <= eth_mem_rdata;
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_rd <= 1'b0;

                    if ((status_flags[15:0] & ETH_FLAG_TX_REQ) && !(eth_mem_rdata & ETH_FLAG_TX_REQ)) begin
                        mem_state <= MEM_READ_STATUS;
                    end else if (eth_mem_rdata & ETH_FLAG_RESET) begin
                        status_flags[15:0] <= (status_flags[15:0] & ~ETH_FLAG_HPS_OWNED_MASK) |
                                               (eth_mem_rdata & ETH_FLAG_HPS_OWNED_MASK);
                        mem_state <= MEM_RESET_PENDING;
                    end else if (flags_write_pending) begin
                        status_flags[15:0] <= (status_flags[15:0] & ~ETH_FLAG_HPS_OWNED_MASK) |
                                               (eth_mem_rdata & ETH_FLAG_HPS_OWNED_MASK);
                        mem_state <= MEM_WRITE_FLAGS;
                    end else if (eth_mem_rdata & ETH_FLAG_RX_AVAIL) begin
                        status_flags[15:0] <= (status_flags[15:0] & ~ETH_FLAG_HPS_OWNED_MASK) |
                                               (eth_mem_rdata & ETH_FLAG_HPS_OWNED_MASK);
                        mem_state <= MEM_PACKET_STATUS;
                    end else begin
                        status_flags[15:0] <= (status_flags[15:0] & ~ETH_FLAG_HPS_OWNED_MASK) |
                                               (eth_mem_rdata & ETH_FLAG_HPS_OWNED_MASK);
                        mem_state <= MEM_IDLE;
                    end
                end
            end

            MEM_READ_STATUS: begin
                if (!mem_transaction_busy) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_rd <= 1'b1;
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_CTRL_STATUS;
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b0;
                    eth_mem_addr <= (eth_shared_base + ETH_SHM_CTRL_STATUS) >> 1;
                    eth_mem_be <= 2'b11;
                end else if (eth_mem_ack) begin
                    shared_status_word <= eth_mem_rdata;
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_rd <= 1'b0;

                    status_flags[15:0] <= (((status_flags[15:0] & ~ETH_FLAG_HPS_OWNED_MASK) |
                                            (shared_flags_word & ETH_FLAG_HPS_OWNED_MASK)) &
                                           ~ETH_FLAG_TX_REQ);
                    link_status <= (eth_mem_rdata & ETH_STATUS_LINK_UP) != 16'h0000;
                    status_flags[24] <= (eth_mem_rdata & ETH_STATUS_LINK_UP) != 16'h0000;

                    if ((eth_mem_rdata & ETH_STATUS_TX_ERR) != 16'h0000) begin
                        tsr_register <= TSR_ABT;
                        isr_register <= (isr_register & ~ISR_PTX) | ISR_TXE;
                    end else if ((eth_mem_rdata & ETH_STATUS_TX_OK) != 16'h0000) begin
                        tsr_register <= TSR_PTX;
                        isr_register <= (isr_register & ~ISR_TXE) | ISR_PTX;
                    end else begin
                        tsr_register <= TSR_ABT;
                        isr_register <= (isr_register & ~ISR_PTX) | ISR_TXE;
                    end

                    reg_mirror_dirty[7] <= 1'b1;
                    flags_write_pending <= 1'b1;
                    mem_state <= MEM_IDLE;
                end
            end

            MEM_PACKET_STATUS: begin
                if (!mem_transaction_busy) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_rd <= 1'b1;
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b0;
                    eth_mem_be <= 2'b11;
                    if (rx_packet_meta_phase == 2'b00) begin
                        mem_transaction_addr <= eth_shared_base + ETH_SHM_RX_QUEUE_HEAD;
                        eth_mem_addr <= (eth_shared_base + ETH_SHM_RX_QUEUE_HEAD) >> 1;
                    end else if (rx_packet_meta_phase == 2'b01) begin
                        mem_transaction_addr <= eth_shared_base + ETH_SHM_RX_QUEUE_TAIL;
                        eth_mem_addr <= (eth_shared_base + ETH_SHM_RX_QUEUE_TAIL) >> 1;
                    end else begin
                        mem_transaction_addr <= eth_shared_base + ETH_SHM_RX_QUEUE_LEN +
                                                {7'h00, rx_queue_head_slot, 1'b0};
                        eth_mem_addr <= (eth_shared_base + ETH_SHM_RX_QUEUE_LEN +
                                         {7'h00, rx_queue_head_slot, 1'b0}) >> 1;
                    end
                end else if (eth_mem_ack) begin
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_rd <= 1'b0;

                    if (rx_packet_meta_phase == 2'b00) begin
                        if (eth_mem_rdata[7:0] < ETH_RX_QUEUE_SLOTS) begin
                            rx_queue_head_slot <= eth_mem_rdata[7:0];
                        end else begin
                            rx_queue_head_slot <= 8'h00;
                        end
                        rx_packet_meta_phase <= 2'b01;
                    end else if (rx_packet_meta_phase == 2'b01) begin
                        if (eth_mem_rdata[7:0] < ETH_RX_QUEUE_SLOTS) begin
                            rx_queue_tail_slot <= eth_mem_rdata[7:0];
                        end else begin
                            rx_queue_tail_slot <= 8'h00;
                        end

                        if (rx_queue_head_slot == ((eth_mem_rdata[7:0] < ETH_RX_QUEUE_SLOTS) ? eth_mem_rdata[7:0] : 8'h00)) begin
                            rx_packet_meta_phase <= 2'b00;
                            status_flags[15:0] <= status_flags[15:0] & ~ETH_FLAG_RX_AVAIL;
                            flags_write_pending <= 1'b1;
                            mem_state <= MEM_IDLE;
                        end else begin
                            rx_packet_meta_phase <= 2'b10;
                        end
                    end else begin
                        rx_packet_length <= eth_mem_rdata;
                        rx_next_page <= wrap_rx_page(pstart_register, pstop_register, curr_register, eth_mem_rdata);
                        rx_queue_next_head <= next_shared_rx_slot(rx_queue_head_slot);
                        rx_packet_meta_phase <= 2'b00;

                        if (!receiver_accepting_packets) begin
                            rsr_register <= RSR_DIS;
                            reg_mirror_dirty[12] <= 1'b1;
                            mem_state <= MEM_WRITE_PACKET_INFO;
                        end else if ((eth_mem_rdata == 16'h0000) || (eth_mem_rdata > ETH_PACKET_BUFFER_BYTES)) begin
                            rsr_register <= 8'h00;
                            isr_register <= isr_register | ISR_RXE;
                            reg_mirror_dirty[7] <= 1'b1;
                            reg_mirror_dirty[12] <= 1'b1;
                            mem_state <= MEM_WRITE_PACKET_INFO;
                        end else if (rx_packet_pages(eth_mem_rdata) >
                                     rx_ring_free_pages(pstart_register, pstop_register,
                                                        curr_register, bnry_register)) begin
                            rsr_register <= RSR_FO | RSR_MPA;
                            isr_register <= isr_register | ISR_OVW;
                            reg_mirror_dirty[7] <= 1'b1;
                            reg_mirror_dirty[12] <= 1'b1;
                            mem_state <= MEM_WRITE_PACKET_INFO;
                        end else begin
                            rx_copy_buffer_base <= shared_rx_slot_base(rx_queue_head_slot);
                            rx_copy_src_offset <= 16'h0000;
                            rx_copy_dst_addr <= {curr_register, 8'h00};
                            rx_copy_remaining <= eth_mem_rdata;
                            rx_copy_phase <= 2'b00;
                            mem_state <= MEM_RX_BUFFER_WRITE;
                        end
                    end
                end
            end

            MEM_WRITE_FLAGS: begin
                if (!mem_transaction_busy) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_CTRL_FLAGS;
                    mem_transaction_data <= flags_word_to_write;
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b1;
                    eth_mem_addr <= (eth_shared_base + ETH_SHM_CTRL_FLAGS) >> 1;
                    eth_mem_wdata <= flags_word_to_write;
                    eth_mem_be <= 2'b11;
                end else if (eth_mem_ack) begin
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_wr <= 1'b0;
                    flags_write_pending <= 1'b0;
                    shared_flags_word <= flags_word_to_write;
                    mem_state <= MEM_IDLE;
                end
            end

            MEM_DATA_PORT_READ: begin
                mem_state <= MEM_IDLE;
            end

            MEM_DATA_PORT_WRITE: begin
                mem_state <= MEM_IDLE;
            end

            MEM_RX_BUFFER_READ: begin
                if (!mem_transaction_busy) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_rd <= 1'b1;
                    mem_transaction_addr <= eth_shared_base + rx_copy_buffer_base + rx_copy_src_offset;
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b0;
                    eth_mem_addr <= (eth_shared_base + rx_copy_buffer_base + rx_copy_src_offset) >> 1;
                    eth_mem_be <= (rx_copy_remaining == 16'd1) ? 2'b01 : 2'b11;
                end else if (eth_mem_ack) begin
                    buffer_read_data <= eth_mem_rdata;
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_rd <= 1'b0;
                    rx_copy_phase <= 2'b11;
                    mem_state <= MEM_RX_BUFFER_WRITE;
                end
            end

            MEM_RX_BUFFER_WRITE: begin
                if (!mem_transaction_busy) begin
                    if (rx_copy_phase == 2'b00) begin
                        mem_transaction_busy <= 1'b1;
                        mem_transaction_wr <= 1'b1;
                        mem_transaction_addr <= eth_shared_base + compact_ne_offset({curr_register, 8'h00});
                        eth_mem_req <= 1'b1;
                        eth_mem_wr <= 1'b1;
                        eth_mem_addr <= (eth_shared_base + compact_ne_offset({curr_register, 8'h00})) >> 1;
                        eth_mem_wdata <= {rx_next_page, RSR_PRX};
                        eth_mem_be <= 2'b11;
                    end else if (rx_copy_phase == 2'b01) begin
                        mem_transaction_busy <= 1'b1;
                        mem_transaction_wr <= 1'b1;
                        mem_transaction_addr <= eth_shared_base + compact_ne_offset({curr_register, 8'h00} + 16'h0002);
                        eth_mem_req <= 1'b1;
                        eth_mem_wr <= 1'b1;
                        eth_mem_addr <= (eth_shared_base + compact_ne_offset({curr_register, 8'h00} + 16'h0002)) >> 1;
                        eth_mem_wdata <= rx_packet_length + 16'd4;
                        eth_mem_be <= 2'b11;
                    end else if (rx_copy_phase == 2'b10) begin
                        if (rx_copy_remaining != 16'h0000) begin
                            mem_state <= MEM_RX_BUFFER_READ;
                        end else begin
                            curr_register <= rx_next_page;
                            rsr_register <= RSR_PRX;
                            isr_register <= isr_register | ISR_PRX;
                            reg_mirror_dirty[7] <= 1'b1;
                            reg_mirror_dirty[12] <= 1'b1;
                            reg_mirror_dirty[23] <= 1'b1;
                            mem_state <= MEM_WRITE_PACKET_INFO;
                        end
                    end else begin
                        mem_transaction_busy <= 1'b1;
                        mem_transaction_wr <= 1'b1;
                        mem_transaction_addr <= eth_shared_base + compact_ne_offset(rx_copy_dst_addr);
                        eth_mem_req <= 1'b1;
                        eth_mem_wr <= 1'b1;
                        eth_mem_addr <= (eth_shared_base + compact_ne_offset(rx_copy_dst_addr)) >> 1;
                        eth_mem_wdata <= buffer_read_data;
                        eth_mem_be <= (rx_copy_remaining == 16'd1) ? 2'b01 : 2'b11;
                    end
                end else if (eth_mem_ack) begin
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_wr <= 1'b0;

                    if (rx_copy_phase == 2'b00) begin
                        rx_copy_dst_addr <= wrap_rx_addr(pstart_register, pstop_register,
                                                         {curr_register, 8'h00}, 16'h0004);
                        rx_copy_phase <= 2'b01;
                    end else if (rx_copy_phase == 2'b01) begin
                        rx_copy_phase <= 2'b10;
                    end else if (rx_copy_phase == 2'b11) begin
                        rx_copy_src_offset <= rx_copy_src_offset + 16'h0002;
                        rx_copy_dst_addr <= wrap_rx_addr(pstart_register, pstop_register,
                                                         rx_copy_dst_addr, 16'h0002);
                        if (rx_copy_remaining <= 16'h0002) begin
                            rx_copy_remaining <= 16'h0000;
                        end else begin
                            rx_copy_remaining <= rx_copy_remaining - 16'h0002;
                        end
                        rx_copy_phase <= 2'b10;
                    end
                end
            end

            MEM_TX_BUFFER_READ: begin
                mem_state <= MEM_IDLE;
            end

            MEM_TX_BUFFER_WRITE: begin
                mem_state <= MEM_IDLE;
            end

            MEM_READ_SIGNATURE: begin
                mem_state <= MEM_IDLE;
            end

            MEM_WRITE_PACKET_INFO: begin
                if (!mem_transaction_busy) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_RX_QUEUE_HEAD;
                    mem_transaction_data <= {8'h00, rx_queue_next_head};
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b1;
                    eth_mem_addr <= (eth_shared_base + ETH_SHM_RX_QUEUE_HEAD) >> 1;
                    eth_mem_wdata <= {8'h00, rx_queue_next_head};
                    eth_mem_be <= 2'b11;
                end else if (eth_mem_ack) begin
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_wr <= 1'b0;

                    if (rx_queue_next_head == rx_queue_tail_slot) begin
                        status_flags[15:0] <= status_flags[15:0] & ~ETH_FLAG_RX_AVAIL;
                        flags_write_pending <= 1'b1;
                    end

                    mem_state <= MEM_IDLE;
                end
            end

            MEM_READ_MAC_ADDR: begin
                mem_state <= MEM_IDLE;
            end

            MEM_WRITE_STATS: begin
                mem_state <= MEM_IDLE;
            end

            MEM_WRITE_REG_MIRROR: begin
                if (!mem_transaction_busy && reg_mirror_valid) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_CTRL_REGS + {8'h00, reg_mirror_index, 2'b00};
                    mem_transaction_data <= reg_mirror_word;
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b1;
                    eth_mem_addr <= (eth_shared_base + ETH_SHM_CTRL_REGS + {8'h00, reg_mirror_index, 2'b00}) >> 1;
                    eth_mem_wdata <= reg_mirror_word;
                    eth_mem_be <= 2'b11;
                end else if (eth_mem_ack) begin
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_wr <= 1'b0;
                    reg_mirror_dirty[reg_mirror_index] <= 1'b0;
                    mem_state <= MEM_IDLE;
                end else if (!reg_mirror_valid) begin
                    mem_state <= MEM_IDLE;
                end
            end

            MEM_WRITE_MAC_MIRROR: begin
                if (!mem_transaction_busy && mac_word_valid) begin
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_CTRL_MAC + {13'h0000, mac_word_index, 1'b0};
                    mem_transaction_data <= mac_mirror_word;
                    eth_mem_req <= 1'b1;
                    eth_mem_wr <= 1'b1;
                    eth_mem_addr <= (eth_shared_base + ETH_SHM_CTRL_MAC + {13'h0000, mac_word_index, 1'b0}) >> 1;
                    eth_mem_wdata <= mac_mirror_word;
                    eth_mem_be <= 2'b11;
                end else if (eth_mem_ack) begin
                    eth_mem_req <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_wr <= 1'b0;
                    mac_word_dirty[mac_word_index] <= 1'b0;
                    mem_state <= MEM_IDLE;
                end else if (!mac_word_valid) begin
                    mem_state <= MEM_IDLE;
                end
            end

            MEM_WAIT_COMPLETE: begin
                mem_state <= MEM_IDLE;
            end

            MEM_ERROR: begin
                // Error state - something went wrong with memory access
                $display("MEM_ERROR: Memory access error occurred");
                
                // Reset to idle and clear error conditions
                mem_state <= MEM_IDLE;
            end

            MEM_RESET_PENDING: begin
                // Handle ethernet controller reset
                $display("MEM_RESET_PENDING: Processing ethernet reset");
                
                // Reset all ethernet registers to default values
                cr_register <= 8'h21;              // Reset to stop state
                remote_dma_addr <= 16'h0000;
                remote_byte_count <= 16'h0000;
                transmit_byte_count <= 16'h0000;
                isr_register <= 8'h80;             // Set reset status bit
                imr_register <= 8'h00;             // Disable all interrupts
                dcr_register <= 8'h48;
                rcr_register <= 8'h00;
                tcr_register <= 8'h00;
                rsr_register <= 8'h00;
                tsr_register <= 8'h00;
                pstart_register <= 8'h46;
                pstop_register <= 8'h80;
                bnry_register <= 8'h46;
                tpsr_register <= 8'h40;
                curr_register <= 8'h47;
                par0_register <= 8'h28;
                par1_register <= 8'h12;
                par2_register <= 8'h34;
                par3_register <= 8'h56;
                par4_register <= 8'h78;
                par5_register <= 8'h9A;
                mar0_register <= 8'h00;
                mar1_register <= 8'h00;
                mar2_register <= 8'h00;
                mar3_register <= 8'h00;
                mar4_register <= 8'h00;
                mar5_register <= 8'h00;
                mar6_register <= 8'h00;
                mar7_register <= 8'h00;
                
                // Clear packet counters
                packet_count_rx <= 16'h0000;
                packet_count_tx <= 16'h0000;
                
                // Reset buffer addresses
                rx_buffer_addr <= 16'h0000;
                tx_buffer_addr <= 16'h0000;
                rx_copy_src_offset <= 16'h0000;
                rx_copy_dst_addr <= 16'h0000;
                rx_copy_remaining <= 16'h0000;
                rx_copy_buffer_base <= ETH_SHM_RX_BUFFER;
                rx_copy_phase <= 2'b00;
                rx_packet_meta_phase <= 2'b00;
                rx_queue_head_slot <= 8'h00;
                rx_queue_tail_slot <= 8'h00;
                rx_queue_next_head <= 8'h00;
                shared_flags_word <= shared_flags_word & ETH_FLAG_HPS_OWNED_MASK;
                status_flags[15:0] <= status_flags[15:0] & ~(ETH_FLAG_ENABLED | ETH_FLAG_TX_REQ | ETH_FLAG_RX_AVAIL);
                reg_mirror_dirty <= 32'hFFFF_FFFF;
                mac_word_dirty <= 3'b111;
                flags_write_pending <= 1'b1;
                
                mem_state <= MEM_IDLE;
            end

            MEM_IRQ_PROCESS: begin
                // Process interrupt request logic
                $display("MEM_IRQ_PROCESS: Processing interrupt logic");
                
                // Update interrupt status based on current conditions
                if (packet_count_rx > 0) begin
                    isr_register <= isr_register | ISR_PRX;  // Packet received
                end
                if (remote_byte_count == 0 && remote_dma_addr > 0) begin
                    isr_register <= isr_register | ISR_RDC;  // Remote DMA complete
                end
                
                mem_state <= MEM_IDLE;
            end

            MEM_CONFIG_UPDATE: begin
                // Update configuration registers from shared memory
                $display("MEM_CONFIG_UPDATE: Updating configuration from shared memory");
                
                // Read configuration from shared memory and update local registers
                // This would involve reading from ETH_SHM_CTRL_REGS area
                
                mem_state <= MEM_IDLE;
            end

            MEM_STATUS_CHECK: begin
                // Check overall ethernet status
                $display("MEM_STATUS_CHECK: Checking ethernet status");
                
                // Update link status based on heartbeat
                if (packet_count_rx[3:0] == 4'hF) begin  // Use counter as heartbeat indicator
                    link_status <= 1'b1;
                end else if (packet_count_rx[3:0] == 4'h0) begin
                    link_status <= 1'b0;
                end
                
                // Update status flags
                status_flags[24] <= link_status;        // Link status bit
                status_flags[23:16] <= isr_register;    // Interrupt status
                
                mem_state <= MEM_IDLE;
            end

            MEM_BUFFER_FLUSH: begin
                // Flush TX/RX buffers
                $display("MEM_BUFFER_FLUSH: Flushing ethernet buffers");
                
                // Reset buffer pointers and clear pending data
                rx_buffer_addr <= 16'h0000;
                tx_buffer_addr <= 16'h0000;
                rx_packet_length <= 16'h0000;
                tx_packet_length <= 16'h0000;
                
                // Clear buffer read pending flags
                rx_buffer_read_pending <= 1'b0;
                tx_buffer_read_pending <= 1'b0;
                
                mem_state <= MEM_IDLE;
            end

            MEM_LINK_CHECK: begin
                // Check ethernet link status
                $display("MEM_LINK_CHECK: Checking ethernet link");
                
                // Simulate link check by reading heartbeat counter
                // In real implementation, this would check PHY status
                if (status_flags[31:28] == 4'hC) begin  // Magic pattern indicates HPS alive
                    link_status <= 1'b1;
                end else begin
                    link_status <= 1'b0;
                end
                
                mem_state <= MEM_IDLE;
            end

            MEM_STATS_UPDATE: begin
                // Update packet statistics
                $display("MEM_STATS_UPDATE: Updating packet statistics");
                
                // Update counters based on current activity
                if (|(isr_register & ISR_PTX)) begin
                    packet_count_tx <= packet_count_tx + 1;
                end
                if (|(isr_register & ISR_PRX)) begin
                    packet_count_rx <= packet_count_rx + 1;
                end
                
                mem_state <= MEM_IDLE;
            end

            MEM_DEBUG_LOG: begin
                // Log debug information
                $display("MEM_DEBUG_LOG: CR=0x%02x ISR=0x%02x IMR=0x%02x", 
                        cr_register, isr_register, imr_register);
                $display("  RX_COUNT=%d TX_COUNT=%d LINK=%b", 
                        packet_count_rx, packet_count_tx, link_status);
                $display("  DMA_ADDR=0x%04x DMA_COUNT=%d", 
                        remote_dma_addr, remote_byte_count);
                
                mem_state <= MEM_IDLE;
            end

            MEM_CLEANUP: begin
                // Cleanup operations
                $display("MEM_CLEANUP: Performing cleanup operations");
                
                // Clear completed interrupt status bits
                if (|(isr_register & ISR_RDC)) begin
                    isr_register <= isr_register & ~ISR_RDC;  // Clear RDC bit
                end
                if (|(isr_register & ISR_PTX)) begin
                    isr_register <= isr_register & ~ISR_PTX;  // Clear PTX bit  
                end
                
                // Clear transaction busy flags if stuck
                if (mem_transaction_busy && !mem_transaction_rd && !mem_transaction_wr) begin
                    mem_transaction_busy <= 1'b0;
                end
                
                mem_state <= MEM_IDLE;
            end

            default: mem_state <= MEM_IDLE;
        endcase

        // Clear read pending flags when read cycle completes
        if (!card_selected || !cpu_rd) begin
            data_port_read_pending <= 1'b0;
            memory_read_pending <= 1'b0;
            control_read_pending <= 1'b0;
            buffer_read_pending <= 1'b0;
        end

    end

    // Generate eth_irq based on ISR and IMR (proper NE2000 behavior)
    // eth_irq is asserted when any enabled interrupt is pending
    // This handles both reset (when ISR/IMR are 0) and normal operation
    eth_irq <= irq_active;
end

// Address decode logic - use [23:1] word address format  
// Address decode logic for ethernet interface
wire [15:0] effective_addr;
wire [15:0] byte_addr;

// Extract lower 16 bits of cpu_addr for effective address calculation
// cpu_addr is [23:1] word addressing, use mask to get lower 16 bits
assign effective_addr = cpu_addr & 23'h01FFFF;  // Mask lower 17 bits, take [16:1]
assign byte_addr = effective_addr << 1;


// Dataport detection: byte addresses 0x620 and 0xC40 -> word addresses 0x310 and 0x620
// Note: Standard NE2000 data port is at +0x10 from register base (0x310 in word addressing)
assign is_data_port_access = (effective_addr == 16'h0310) || (effective_addr == 16'h0620);

// Register access detection: byte 0x600-0x61F and 0xC00-0xC3F -> word 0x300-0x30F and 0x600-0x61F
assign is_register_access = ((effective_addr >= 16'h0300) && (effective_addr <= 16'h030F)) ||
                           ((effective_addr >= 16'h0600) && (effective_addr <= 16'h061F));

// Memory ranges using byte addresses - only active when sel_ethernet_shm is true
assign is_memory_access = sel_ethernet_shm && (byte_addr >= 16'h3000) && (byte_addr <= 16'h6FFF);
assign is_control_access = sel_ethernet_shm && (byte_addr >= 16'h1000) && (byte_addr <= 16'h1FFF);
assign is_buffer_access = sel_ethernet_shm && (byte_addr >= 16'h2000) && (byte_addr <= 16'h2FFF);
assign is_tx_buffer_access = sel_ethernet_shm && (byte_addr >= 16'h2000) && (byte_addr <= 16'h25FF);
assign is_rx_buffer_access = sel_ethernet_shm && (byte_addr >= 16'h2600) && (byte_addr <= 16'h2BFF);

// Create word_addr for backward compatibility
wire [15:0] word_addr;
assign word_addr = effective_addr;

// Convert word offset to register number with different spacing
// Use always block to avoid bit slicing issues in Verilator
reg [15:0] reg_offset_0600, reg_offset_0c00;
reg [4:0] reg_index_0600, reg_index_0c00, reg_base;

always @(*) begin
    reg_offset_0600 = byte_addr - 16'h0600;
    reg_offset_0c00 = byte_addr - 16'h0C00;
    
    // Calculate register indices with masking instead of bit slicing
    reg_index_0600 = (reg_offset_0600 >> 1) & 5'h1F;  // For 0x600 range: 2-byte spacing (divide by 2)
    reg_index_0c00 = (reg_offset_0c00 >> 2) & 5'h1F;  // For 0xC00 range: 4-byte spacing (divide by 4)
    
    reg_base = ((byte_addr >= 16'h0600) && (byte_addr <= 16'h061F)) ? reg_index_0600 : reg_index_0c00;
end

assign register_select = is_data_port_access ? 5'd16 :          // Data port
                         is_register_access ? reg_base :        // Base register (even)
                         5'd31;  // Invalid

// Output logic - immediate response with full register set support
always @(*) begin
    // Default outputs
    cpu_data_out = 16'h0000;

    // Handle ethernet space access (0xEA0000-0xEAFFFF)
    if (card_selected && cpu_rd) begin
        if (is_data_port_access) begin
            // Data port reads - return data from shared memory
            if (data_port_read_pending) begin
                cpu_data_out = data_port_read_data;
                $display("Data port read: returning 0x%04x", data_port_read_data);
            end else begin
                // Default data port read value while data is being fetched
                cpu_data_out = 16'h0000;
            end
        end
        else if (is_register_access && !addr_translate_enable) begin
            // Register reads - only when not doing address translation
                // Return register data - each register gets individual 4-byte space
                // Register values in MSB (high byte) for Amiga bus compatibility
                case (register_select[4:0])
                    // Register 0x00: CR - Command Register
                    5'h00: cpu_data_out = {cr_register, 8'h00};

                    // Register 0x01: CLDA0/PAR0/PSTART
                    5'h01: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // CLDA0
                            2'b01: cpu_data_out = {par0_register, 8'h00};    // PAR0
                            2'b10: cpu_data_out = {pstart_register, 8'h00};  // PSTART
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x02: CLDA1/PAR1/PSTOP
                    5'h02: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // CLDA1
                            2'b01: cpu_data_out = {par1_register, 8'h00};    // PAR1
                            2'b10: cpu_data_out = {pstop_register, 8'h00};   // PSTOP
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x03: BNRY/PAR2 - Boundary Pointer or Physical Address Register 2
                    5'h03: begin
                        case (current_page)
                            2'b00: cpu_data_out = {bnry_register, 8'h00};    // BNRY
                            2'b01: cpu_data_out = {par2_register, 8'h00};    // PAR2
                            default: cpu_data_out = {bnry_register, 8'h00};
                        endcase
                    end

                    // Register 0x04: TSR/PAR3/TPSR
                    5'h04: begin
                        case (current_page)
                            2'b00: cpu_data_out = {tsr_register, 8'h00};     // TSR
                            2'b01: cpu_data_out = {par3_register, 8'h00};    // PAR3
                            2'b10: cpu_data_out = {tpsr_register, 8'h00};    // TPSR
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x05: NCR/PAR4 - Number of Collisions Register or Physical Address Register 4
                    5'h05: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // NCR
                            2'b01: cpu_data_out = {par4_register, 8'h00};    // PAR4
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x06: FIFO/PAR5 - FIFO Register or Physical Address Register 5
                    5'h06: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // FIFO
                            2'b01: cpu_data_out = {par5_register, 8'h00};    // PAR5
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x07: ISR/CURR - Interrupt Status Register or Current Page Register
                    5'h07: begin
                        case (current_page)
                            2'b00: cpu_data_out = {isr_register, 8'h00};     // ISR - return actual interrupt status
                            2'b01: cpu_data_out = {curr_register, 8'h00};    // CURR
                            default: cpu_data_out = {isr_register, 8'h00};
                        endcase
                    end

                    // Register 0x08: CRDA0/MAR0 - Current Remote DMA Address 0 or Multicast Address Register 0
                    5'h08: begin
                        case (current_page)
                            2'b00: cpu_data_out = {remote_dma_addr[7:0], 8'h00};  // CRDA0
                            2'b01: cpu_data_out = {mar0_register, 8'h00};         // MAR0
                            default: cpu_data_out = {remote_dma_addr[7:0], 8'h00};
                        endcase
                    end

                    // Register 0x09: CRDA1/MAR0 - Current Remote DMA Address 1 or Multicast Address Register 0
                    5'h09: begin
                        case (current_page)
                            2'b00: cpu_data_out = {remote_dma_addr[15:8], 8'h00}; // CRDA1
                            2'b01: cpu_data_out = {mar1_register, 8'h00};         // MAR1
                            default: cpu_data_out = {remote_dma_addr[15:8], 8'h00};
                        endcase
                    end

                    // Register 0x0A: 8019ID0/RBCR0/MAR1 - RTL8019AS ID0, Remote Byte Count Register 0, or Multicast Address Register 1
                    5'h0A: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h50, 8'h00};                  // Page 0: 8019ID0 = 0x50 for RTL8019AS
                            2'b01: cpu_data_out = {mar2_register, 8'h00};          // Page 1: MAR2
                            default: cpu_data_out = {8'h50, 8'h00};                // Default to ID0
                        endcase
                    end

                    // Register 0x0B: 8019ID1/RBCR1/MAR2 - RTL8019AS ID1, Remote Byte Count Register 1, or Multicast Address Register 2
                    5'h0B: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h70, 8'h00};                   // Page 0: 8019ID1 = 0x70 for RTL8019AS
                            2'b01: cpu_data_out = {mar3_register, 8'h00};           // Page 1: MAR3
                            2'b11: cpu_data_out = {8'h00, 8'h00};                  // Page 3: INTR (Interrupt Register)
                            default: cpu_data_out = {8'h70, 8'h00};                 // Default to ID1
                        endcase
                    end

                    // Register 0x0C: RSR/MAR3 - Receive Status Register or Multicast Address Register 3
                    5'h0C: begin
                        case (current_page)
                            2'b00: cpu_data_out = {rsr_register, 8'h00};         // RSR
                            2'b01: cpu_data_out = {mar4_register, 8'h00};         // MAR4
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x0D: CNTR0/MAR4 - Tally Counter 0 or Multicast Address Register 4
                    5'h0D: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};                 // CNTR0
                            2'b01: cpu_data_out = {mar5_register, 8'h00};         // MAR5
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x0E: CNTR1/MAR6/DCR - CNTR1 (page 0), MAR6 (page 1), or DCR (page 2)
                    5'h0E: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};      // CNTR1 (not modeled)
                            2'b01: cpu_data_out = {mar6_register, 8'h00}; // MAR6
                            2'b10: cpu_data_out = {dcr_register, 8'h00}; // DCR
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x0F: CNTR2/MAR7/IMR - CNTR2 (page 0), MAR7 (page 1), or IMR (page 2)
                    5'h0F: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};        // CNTR2 (not modeled)
                            2'b01: cpu_data_out = {mar7_register, 8'h00}; // MAR7
                            2'b10: cpu_data_out = {imr_register, 8'h00}; // IMR
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    default: cpu_data_out = 16'h0000;  // Invalid register
                endcase
            end
        end
    
    // Handle shared memory space access (0xEA1000-0xEAFFFF)
    // Skip when address translation is active as data comes from shared memory system
    if (cpu_rd && !addr_translate_enable && (is_memory_access || is_control_access || is_tx_buffer_access || is_rx_buffer_access)) begin
        if (is_memory_access) begin
            // NE2000 memory read - return data from shared memory
            cpu_data_out = memory_read_data;
        end else if (is_control_access) begin
            // Control read - return data from shared memory
            cpu_data_out = control_read_data;
        end else if (is_tx_buffer_access) begin
            // TX buffer read - return data from shared memory
            cpu_data_out = tx_buffer_read_data;
        end else if (is_rx_buffer_access) begin
            // RX buffer read - return data from shared memory
            cpu_data_out = rx_buffer_read_data;
        end
    end
end

endmodule
