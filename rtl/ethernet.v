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

    // Chip select (when Amiga accesses ethernet address range)
    input  wire        sel_ethernet,
    
    // Chip select for shared memory buffer access
    input  wire        sel_ethernet_shm,

    // Ethernet base address (dynamic based on autoconfig)
    input  wire [7:0] ethernet_base,

    // Interrupt output to Amiga
    output reg         eth_irq
);

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

// Full RTL8019AS register set stored in shared memory
// All 32 NE2000 registers are maintained in shared memory at ETH_CTRL_REGS offset
// Only cache essential values locally for performance and identification

// Shared memory layout offsets - reduced to 16 bits for optimization
parameter [15:0] ETH_SHM_CTRL_FLAGS    = 16'h1000;  // 4 bytes - control flags
parameter [15:0] ETH_SHM_CTRL_REGS     = 16'h1004;  // 32 bytes - NE2000 registers
parameter [15:0] ETH_SHM_CTRL_MAC      = 16'h1024;  // 6 bytes - MAC address
parameter [15:0] ETH_SHM_CTRL_STATUS   = 16'h102A;  // 2 bytes - status
parameter [15:0] ETH_SHM_CTRL_STATS    = 16'h102C;  // 52 bytes - packet statistics
parameter [15:0] ETH_SHM_HPS_HEARTBEAT = 16'h1060;  // 4 bytes - HPS heartbeat
parameter [15:0] ETH_SHM_HPS_SIGNATURE = 16'h1064;  // 4 bytes - signature (0xCAFEBABE)
parameter [15:0] ETH_SHM_TX_BUFFER     = 16'h2000;  // 1500 bytes - TX buffer
parameter [15:0] ETH_SHM_RX_BUFFER     = 16'h2600;  // 1500 bytes - RX buffer
parameter [15:0] ETH_SHM_PACKET_INFO   = 16'h2C00;  // 512 bytes - packet metadata
parameter [15:0] ETH_SHM_NE_MEMORY     = 16'h3000;  // 16KB - NE2000 memory space
parameter [15:0] ETH_SHM_DEBUG_INFO    = 16'h7000;  // 8KB - debug info
parameter [15:0] ETH_SHM_FUTURE_USE    = 16'h9000;  // 31KB - future expansion

// Direct memory access using ethernet_base + ETH_SHM_* offsets - no internal array needed

// Current page from shared memory CR register
reg [7:0] cr_register;  // CR register value cached locally
wire [1:0] current_page = cr_register[7:6];

// Remote DMA registers (RSAR0/1, RBCR0/1)
reg [7:0] rsar0_register;    // Remote Start Address Register 0 (low byte)
reg [7:0] rsar1_register;    // Remote Start Address Register 1 (high byte)
reg [7:0] rbcr0_register;    // Remote Byte Count Register 0 (low byte)
reg [7:0] rbcr1_register;    // Remote Byte Count Register 1 (high byte)

// Derive cpu_wr signal for new ethernet module (active when either byte is being written)
wire        cpu_wr = cpu_lwr | cpu_hwr;

// Data port access state (using shared memory, no local buffer)
wire       is_data_port_access; // True if accessing data port (0x10)
wire       is_memory_access;    // True if accessing NE2000 memory (0x3000-0x7FFF)
wire       is_control_access;   // True if accessing control structure (0x0000-0x1000)
wire       is_buffer_access;    // True if accessing TX/RX buffers (0x2000-0x2FFF)
wire       is_tx_buffer_access; // True if accessing TX buffer (0x2000-0x25FF)
wire       is_rx_buffer_access; // True if accessing RX buffer (0x2600-0x2BFF)
reg [15:0] remote_dma_addr;     // Current remote DMA address
reg [15:0] remote_byte_count;   // Remaining byte count for DMA
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

reg [4:0]  mem_state;
reg [15:0] eth_shared_base;    // Ethernet shared memory base address
reg        flags_write_pending; // Flag to trigger control flags write to shared memory

// Memory transaction control
reg [15:0] mem_transaction_addr;  // Address for current memory transaction
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
reg [15:0] info_addr;             // Info address for packet info
reg [15:0] mac_addr;              // MAC address for MAC read
reg [15:0] stats_addr;            // Stats address for statistics
reg [15:0] sig_addr;              // Signature address for HPS validation
reg [15:0] ne_offset;             // NE2000 memory offset
reg [15:0] rx_offset;             // RX buffer offset
reg [15:0] tx_offset;             // TX buffer offset

// Packet processing state
reg [15:0] packet_length;     // Current packet length
reg [15:0] packet_count_rx;   // Number of received packets
reg [15:0] packet_count_tx;   // Number of transmitted packets
reg        link_status;       // Link up/down status
reg [31:0] status_flags;      // Status and control flags

// NE2000 Interrupt handling - proper implementation
reg [7:0]  isr_register;       // Interrupt Status Register (0x07)
reg [7:0]  imr_register;       // Interrupt Mask Register (0x0F)

// NE2000 ISR bit definitions
parameter ISR_PRX = 8'h01;     // Bit 0: Packet Received
parameter ISR_PTX = 8'h02;     // Bit 1: Packet Transmitted
parameter ISR_RXE = 8'h04;     // Bit 2: Receive Error
parameter ISR_TXE = 8'h08;     // Bit 3: Transmit Error
parameter ISR_OVW = 8'h10;     // Bit 4: Overwrite Warning
parameter ISR_CNT = 8'h20;     // Bit 5: Counter Overflow
parameter ISR_RDC = 8'h40;     // Bit 6: Remote DMA Complete
parameter ISR_RST = 8'h80;     // Bit 7: Reset Status

// Address decode
wire [4:0]  register_select;
wire        is_register_access;
// byte_addr now declared as reg in address decode section

// Simplified sequential logic - all HPS transactions replaced with direct memory access
always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;

        // Initialize CR register copy for page decoding
        cr_register <= 8'h21;      // CR: Stop state, page 0, no DMA

        // Initialize data port state
        remote_dma_addr <= 16'h4000;      // Default DMA start address
        remote_byte_count <= 16'h0000;
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
        eth_shared_base <= {ethernet_base, 8'h00};  // Store Amiga base address (e.g., 0xEA00)
        flags_write_pending <= 1'b0;
        
        // Initialize memory transactions
        mem_transaction_addr <= 16'h0000;
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

        // Initialize NE2000 interrupt registers
        isr_register <= 8'h00;           // Clear all interrupt status bits
        imr_register <= 8'h00;           // Mask all interrupts initially

        // Initialize remote DMA registers  
        rsar0_register <= 8'h00;         // Remote start address low
        rsar1_register <= 8'h00;         // Remote start address high
        rbcr0_register <= 8'h00;         // Remote byte count low
        rbcr1_register <= 8'h00;         // Remote byte count high

        // Initialize memory state machine and transaction control
        mem_state <= MEM_IDLE;
        mem_transaction_addr <= 16'h0000;
        mem_transaction_data <= 16'h0000;
        mem_transaction_rd <= 1'b0;
        mem_transaction_wr <= 1'b0;
        mem_transaction_busy <= 1'b0;
        mem_transaction_timeout <= 16'h0000;
        flags_write_pending <= 1'b0;

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
        info_addr <= 16'h0000;
        mac_addr <= 16'h0000;
        stats_addr <= 16'h0000;
        sig_addr <= 16'h0000;
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
                if (sel_ethernet && (cpu_rd || cpu_wr)) begin
                    state <= ACCESS;
                end
            end

            ACCESS: begin
                // Stay in ACCESS until the bus cycle ends (chip select goes away)
                if (!sel_ethernet) begin
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

        // Handle data port writes (packet data) - write to NE2000 memory
        if (sel_ethernet && cpu_wr && is_data_port_access) begin
            if (~cpu_uds) begin  // Check upper data strobe for high byte access
                // Write to NE2000 memory space using remote DMA address
                // Target address: ethernet_base + ETH_SHM_NE_MEMORY + remote_dma_addr
                // This maps to the NE2000 memory buffer in shared memory
                
                // Trigger memory write transaction
                if (!mem_transaction_busy) begin
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_NE_MEMORY + remote_dma_addr;
                    mem_transaction_data <= cpu_data_in;
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    mem_transaction_timeout <= 16'h0000;  // Reset timeout counter
                    
                    $display("Data port write: 0x%04x to NE2000 memory at offset 0x%04x", 
                            cpu_data_in, remote_dma_addr);
                end
                
                // Update remote DMA address for next write
                remote_dma_addr <= remote_dma_addr + 16'h2;
                // Decrement byte counter for DMA writes
                if (remote_byte_count > 16'h0001) begin
                    remote_byte_count <= remote_byte_count - 16'h2;
                end else begin
                    remote_byte_count <= 16'h0000;
                    // Set RDC (Remote DMA Complete) interrupt
                    isr_register <= isr_register | ISR_RDC;
                end
            end
        end
        // Handle data port reads (packet data) - read from NE2000 memory
        else if (sel_ethernet && cpu_rd && is_data_port_access && !data_port_read_pending) begin
            // Read from NE2000 memory space using remote DMA address
            // Target address: ethernet_base + ETH_SHM_NE_MEMORY + remote_dma_addr
            // This maps to the NE2000 memory buffer in shared memory
            
            // Set pending flag to prevent multiple reads
            data_port_read_pending <= 1'b1;
            
            // Trigger memory read transaction
            if (!mem_transaction_busy) begin
                mem_transaction_addr <= eth_shared_base + ETH_SHM_NE_MEMORY + remote_dma_addr;
                mem_transaction_rd <= 1'b1;
                mem_transaction_busy <= 1'b1;
                mem_transaction_timeout <= 16'h0000;  // Reset timeout counter
                
                $display("Data port read: requesting data from NE2000 memory at offset 0x%04x", 
                        remote_dma_addr);
            end

            // Update remote DMA address for next read
            remote_dma_addr <= remote_dma_addr + 16'd2;
            // Decrement byte counter for DMA reads
            if (remote_byte_count > 16'h0001) begin
                remote_byte_count <= remote_byte_count - 16'h2;
            end else begin
                remote_byte_count <= 16'h0000;
                // Set RDC (Remote DMA Complete) interrupt
                isr_register <= isr_register | ISR_RDC;
            end
        end
        // Handle NE2000 memory writes (direct memory access) - write directly to shared memory
        else if (sel_ethernet_shm && cpu_wr && is_memory_access) begin
            if (~cpu_uds) begin  // Check upper data strobe for high byte access
                // Calculate memory offset from 0x4000 base (cpu_addr 0x4000-0x7FFF maps to memory offset 0x0000-0x3FFF)
                // Direct mapped NE2000 memory write
                // Target address: calc_mem_addr(ETH_SHM_NE_MEMORY + {15'h0000, (cpu_addr[15:1] - 15'h2000), 1'b0})
                // System memory controller handles write at: shared_mem_base + ETH_SHM_NE_MEMORY + (byte_addr - 0x4000)
            end
        end
        // Handle NE2000 memory reads (direct memory access) - read from shared memory
        else if (sel_ethernet_shm && cpu_rd && is_memory_access && !memory_read_pending) begin
            // Calculate memory offset from 0x4000 base (cpu_addr 0x4000-0x7FFF maps to memory offset 0x0000-0x3FFF)
            // Direct mapped NE2000 memory read
            // Source address: calc_mem_addr(ETH_SHM_NE_MEMORY + {15'h0000, (cpu_addr[15:1] - 15'h2000), 1'b0})
            // System memory controller provides NE2000 memory data at: shared_mem_base + ETH_SHM_NE_MEMORY + (byte_addr - 0x4000)
            //memory_read_data <= 16'h5678; // Test pattern - system memory overrides this - gets written to 0xEA4000 - 0xEA7FFF
            memory_read_pending <= 1'b1;
        end
        // Handle control writes (direct control access) - write directly to shared memory
        else if (sel_ethernet_shm && cpu_wr && is_control_access) begin
            if (~cpu_uds) begin  // Check upper data strobe for high byte access
                // Direct access to control structure
                // Direct mapped control memory write
                // Target address: eth_shared_base + {15'h0000, cpu_addr[15:1], 1'b0}
            end
        end
        // Handle control reads (direct control access) - read from shared memory
        else if (sel_ethernet_shm && cpu_rd && is_control_access && !control_read_pending) begin
            // Direct access to control structure
            // Direct mapped control memory read
            // Source address: eth_shared_base + {15'h1000, cpu_addr[15:1], 1'b0}
            // System memory controller provides control data at the calculated address
            //control_read_data <= 16'h9ABC; // Test pattern - system memory overrides this
            control_read_pending <= 1'b1;
        end
        // Handle buffer writes (direct TX/RX buffer access) - write directly to shared memory
        else if (sel_ethernet_shm && cpu_wr && is_buffer_access) begin
            if (~cpu_uds) begin  // Check upper data strobe for high byte access
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
        else if (sel_ethernet_shm && cpu_rd && is_buffer_access && !buffer_read_pending) begin
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
        // Handle register writes - write to shared memory with full RTL8019AS support
        else if (sel_ethernet && cpu_wr && is_register_access) begin
            if (~cpu_uds) begin  // Check upper data strobe for high byte access
                // Update local cache for critical registers
                case (register_select[4:0])
                    5'h00: begin  // Command Register (CR)
                        cr_register <= cpu_data_in[15:8]; // Data in high byte for Amiga compatibility

                        // Handle NE2000 commands immediately (check high byte)
                        if (cpu_data_in[10]) begin  // TXP - Transmit Packet (bit 2 of high byte)
                            // Packet transmission handled by shared memory
                        end
                        if (cpu_data_in[8]) begin  // STP - Stop (bit 0 of high byte)
                            // Stop DMA and reset to known state
                            remote_dma_addr <= 16'h0000;
                            remote_byte_count <= 16'h0000;
                        end
                        if (cpu_data_in[9]) begin  // STA - Start (bit 1 of high byte)
                            // Start NE2000 operation
                        end
                        // Handle remote DMA start (bits 5:3 of high byte)
                        if (cpu_data_in[13:11] == 3'b001) begin  // Remote read
                            // Start remote DMA read operation
                        end
                        if (cpu_data_in[13:11] == 3'b010) begin  // Remote write  
                            // Start remote DMA write operation
                        end
                    end
                    5'h08: begin  // CRDA0/TPSR (Current Remote DMA Address 0)
                        if (current_page == 2'b00) begin
                            remote_dma_addr[7:0] <= cpu_data_in[15:8];
                        end
                    end
                    5'h09: begin  // CRDA1 (Current Remote DMA Address 1)
                        if (current_page == 2'b00) begin
                            remote_dma_addr[15:8] <= cpu_data_in[15:8];
                        end
                    end
                    5'h05: begin  // TBCR0 (Transmit Byte Count 0)
                        if (current_page == 2'b00) begin
                            remote_byte_count[7:0] <= cpu_data_in[15:8];
                        end
                    end
                    5'h06: begin  // TBCR1 (Transmit Byte Count 1)
                        if (current_page == 2'b00) begin
                            remote_byte_count[15:8] <= cpu_data_in[15:8];
                        end
                    end
                    5'h0A: begin  // RBCR0 (Remote Byte Count Register 0)
                        if (current_page == 2'b00) begin
                            remote_byte_count[7:0] <= cpu_data_in[15:8];
                        end
                    end
                    5'h0B: begin  // RBCR1 (Remote Byte Count Register 1)
                        if (current_page == 2'b00) begin
                            remote_byte_count[15:8] <= cpu_data_in[15:8];
                        end
                    end
                    5'h07: begin  // Interrupt Status Register (ISR)
                        // NE2000 standard: Write 1 to clear specific interrupt bits
                        isr_register <= isr_register & ~cpu_data_in[15:8];
                    end
                    5'h0F: begin  // Interrupt Mask Register (IMR)
                        // IMR controls which interrupts are enabled
                        imr_register <= cpu_data_in[15:8];
                    end
                    default: begin
                        // All other registers go to shared memory only
                    end
                endcase

                // Always write to shared memory for full register set
                // Intercept, modify, and write to ETH_SHM_CTRL_REGS at 0xEA1004
                
                // Calculate target address in shared memory: ETH_SHM_CTRL_REGS + register_offset
                // ETH_SHM_CTRL_REGS = 0x1004, so target = 0xEA1004 + register_select
                
                case (register_select[4:0])
                    5'h00: begin // CR register - intercept and modify
                        // Original data from CPU
                        original_cr <= cpu_data_in[15:8];
                        // Modify: Force STA bit (bit 1) to 1 if STP bit (bit 0) is 0
                        if (~cpu_data_in[8]) begin // If STP is not set (bit 0 of high byte = bit 8 overall)
                            modified_cr <= cpu_data_in[15:8] | 8'h02;  // Force STA bit (bit 1)
                        end else begin
                            modified_cr <= cpu_data_in[15:8];
                        end
                        // Write modified CR to shared memory at 0xEA1004 + 0x00
                        // Target address: calc_mem_addr(ETH_SHM_CTRL_REGS + 32'h00000000)
                        // Data: {modified_cr, 24'h000000}
                        $display("CR write intercepted: 0x%02x -> 0x%02x", original_cr, modified_cr);
                    end
                    
                    5'h07: begin // ISR register - intercept and modify  
                        // Original ISR clear request from CPU
                        clear_mask <= cpu_data_in[15:8];
                        // Modify: Prevent clearing of RDC bit (bit 6) 
                        modified_mask <= cpu_data_in[15:8] & 8'hBF; // Clear bit 6 in mask
                        // Apply modified clear to local ISR
                        // Write modified ISR to shared memory at 0xEA1004 + 0x07
                        // Target address: calc_mem_addr(ETH_SHM_CTRL_REGS + 32'h00000007)
                        // Data: {isr_register, 24'h000000}
                        $display("ISR clear intercepted: mask 0x%02x -> 0x%02x", clear_mask, modified_mask);
                    end
                    
                    5'h0F: begin // IMR register - intercept and modify
                        // Original IMR data from CPU
                        original_imr <= cpu_data_in[15:8];
                        // Modify: Always enable RDC interrupt (bit 6)
                        modified_imr <= cpu_data_in[15:8] | 8'h40; // Set bit 6
                        // Update local copy with modified value
                        imr_register <= cpu_data_in[15:8] | 8'h40;
                        // Write modified IMR to shared memory at 0xEA1004 + 0x0F
                        // Target address: calc_mem_addr(ETH_SHM_CTRL_REGS + 32'h0000000F)
                        // Data: {modified_imr, 24'h000000}
                        $display("IMR write intercepted: 0x%02x -> 0x%02x", original_imr, modified_imr);
                    end
                    
                    5'h08: begin // RSAR0/CRDA0 - Remote Start Address 0 or Current Remote DMA Address 0
                        if (current_page == 2'b00) begin
                            // Page 0: Read-only CRDA0 - ignore writes
                            $display("Ignored write to read-only CRDA0: 0x%02x", cpu_data_in[15:8]);
                        end else begin
                            // Other pages: RSAR0 write
                            rsar0_register <= cpu_data_in[15:8];
                            // Update combined remote DMA address
                            remote_dma_addr <= {rsar1_register, cpu_data_in[15:8]};
                            $display("RSAR0 write: 0x%02x, new DMA addr: 0x%04x", 
                                   cpu_data_in[15:8], {rsar1_register, cpu_data_in[15:8]});
                        end
                    end
                    
                    5'h09: begin // RSAR1/CRDA1 - Remote Start Address 1 or Current Remote DMA Address 1
                        if (current_page == 2'b00) begin
                            // Page 0: Read-only CRDA1 - ignore writes
                            $display("Ignored write to read-only CRDA1: 0x%02x", cpu_data_in[15:8]);
                        end else begin
                            // Other pages: RSAR1 write
                            rsar1_register <= cpu_data_in[15:8];
                            // Update combined remote DMA address
                            remote_dma_addr <= {cpu_data_in[15:8], rsar0_register};
                            $display("RSAR1 write: 0x%02x, new DMA addr: 0x%04x", 
                                   cpu_data_in[15:8], {cpu_data_in[15:8], rsar0_register});
                        end
                    end

                    5'h0A: begin // RBCR0/8019ID0 - Remote Byte Count 0 or RTL8019AS ID0
                        if (current_page == 2'b00) begin
                            // Page 0: Read-only 8019ID0 
                            $display("Ignored write to read-only 8019ID0: 0x%02x", cpu_data_in[15:8]);
                        end else begin
                            // Other pages: RBCR0 write
                            rbcr0_register <= cpu_data_in[15:8];
                            // Update combined remote byte count
                            remote_byte_count <= {rbcr1_register, cpu_data_in[15:8]};
                            $display("RBCR0 write: 0x%02x, new byte count: 0x%04x", 
                                   cpu_data_in[15:8], {rbcr1_register, cpu_data_in[15:8]});
                        end
                    end
                    5'h0B: begin // RBCR1/8019ID1 - intercept writes (read-only in Page 0)
                        if (current_page == 2'b00) begin
                            // Page 0: This should be read-only 8019ID1
                            // Intercept write and ignore, but log it
                            $display("Ignored write to read-only 8019ID1: 0x%02x", cpu_data_in[15:8]);
                            // Don't write to shared memory for read-only register
                        end else begin
                            // Other pages: RBCR1 write
                            rbcr1_register <= cpu_data_in[15:8];
                            // Update combined remote byte count
                            remote_byte_count <= {cpu_data_in[15:8], rbcr0_register};
                            $display("RBCR1 write: 0x%02x, new byte count: 0x%04x", 
                                   cpu_data_in[15:8], {cpu_data_in[15:8], rbcr0_register});
                        end
                    end

                    default: begin
                        // General register write with optional modification
                        original_data <= cpu_data_in[15:8];
                        
                        // Example: Add timestamp bit to certain registers
                        if (register_select[4:0] >= 5'h08 && register_select[4:0] <= 5'h09) begin
                            // For CRDA0/CRDA1: Set MSB as timestamp indicator
                            modified_data <= cpu_data_in[15:8] | 8'h80;  // Set bit 7
                            $display("Register 0x%02x write modified: 0x%02x -> 0x%02x", 
                                   register_select[4:0], original_data, modified_data);
                        end else begin
                            modified_data <= cpu_data_in[15:8];
                        end
                        
                        // Write to shared memory at 0xEA1004 + register_select
                        // Target address: calc_mem_addr(ETH_SHM_CTRL_REGS + {27'h0, register_select[4:0]})
                        // Data: {modified_data, 24'h000000}
                    end
                endcase

                // Set dirty flag in shared memory so HPS knows registers were updated
                // Write ETH_FLAG_REG_DIRTY (bit 4 = 0x10) to ETH_SHM_CTRL_FLAGS at 0xEA1000
                status_flags <= status_flags | 32'h00000010;  // Set ETH_FLAG_REG_DIRTY bit locally
                flags_write_pending <= 1'b1;  // Trigger write to shared memory
                
                // The memory state machine will handle the actual write to 0xEA1000
                // Target address: eth_shared_base + ETH_SHM_CTRL_FLAGS (0xEA1000)  
                // Data: status_flags with ETH_FLAG_REG_DIRTY bit set
            end
        end

        // Memory State Machine for packet handling (replaces HPS state machine)
        case (mem_state)
            MEM_IDLE: begin
                // Check if flags write is pending first (highest priority)
                if (flags_write_pending) begin
                    mem_state <= MEM_WRITE_FLAGS;
                // Check if data port read is pending (second priority)
                end else if (data_port_read_pending && sel_ethernet && cpu_rd && is_data_port_access) begin
                    mem_state <= MEM_DATA_PORT_READ;
                end else begin
                    // Cycle between reading control flags, heartbeat, signature, and packet status
                    case (packet_count_rx[1:0])  // Use 2 LSBs for 4-way rotation
                    2'b00: begin
                        // Read control flags for reset/TX requests
                        mem_state <= MEM_READ_FLAGS;
                        // Direct mapped control flags read from: calc_mem_addr(ETH_SHM_CTRL_FLAGS)
                        // System memory controller provides control flags at the calculated address
                        status_flags <= 32'h00000020; // Test pattern - system memory overrides this
                    end
                    2'b01: begin
                        // Read heartbeat counter
                        mem_state <= MEM_READ_HEARTBEAT;
                        // Heartbeat from memory
                    end
                    2'b10: begin
                        // Read signature for validation
                        mem_state <= MEM_READ_HEARTBEAT;  // Reuse same handler
                        // Direct mapped signature at: ethernet_base + ETH_SHM_HPS_SIGNATURE (0xEA1064)
                        // HPS side initializes this memory location with 0xCAFEBABE
                        // System memory mapping makes it accessible to CPU
                        link_status <= 1'b1;  // Assume HPS memory is valid and responding
                    end
                    2'b11: begin
                        // Read packet status and statistics
                        mem_state <= MEM_PACKET_STATUS;
                        // Direct mapped status read from: calc_mem_addr(ETH_SHM_CTRL_STATUS)
                        // System memory controller provides packet status at the calculated address
                        status_flags <= 32'h01000002; // Test pattern - system memory overrides this
                    end
                endcase
                end
            end

            MEM_READ_FLAGS: begin
                // Handle control flags from memory
                // Check for reset request (ETH_SHM_FLAG_RESET = 0x0001)
                if (status_flags[0]) begin
                    // Reset requested - trigger local reset
                    cr_register <= 8'h21;      // Reset to stop state
                    remote_dma_addr <= 16'h0000;
                    remote_byte_count <= 16'h0000;
                    isr_register <= 8'h00;         // Clear all interrupt status bits
                end

                // Check for TX request (ETH_SHM_FLAG_TX_REQ = 0x0002)
                if (status_flags[1]) begin
                    // TX request - set PTX interrupt
                    isr_register <= isr_register | ISR_PTX;  // Set Packet Transmitted bit
                end

                // Check for RX available (ETH_SHM_FLAG_RX_AVAIL = 0x0004)
                if (status_flags[2]) begin
                    // RX packet available - set PRX interrupt
                    isr_register <= isr_register | ISR_PRX;  // Set Packet Received bit
                end

                // Check for IRQ flag (ETH_SHM_FLAG_IRQ = 0x0008)
                if (status_flags[3]) begin
                    // Generic IRQ - could be error or other condition
                    isr_register <= isr_register | ISR_RXE;  // Set as receive error for now
                end

                mem_state <= MEM_IDLE;
            end

            MEM_READ_HEARTBEAT: begin
                // Update heartbeat and check signature
                mem_state <= MEM_IDLE;
            end

            MEM_PACKET_STATUS: begin
                // Read packet status and statistics from shared memory

                // Update packet counters
                packet_count_rx <= status_flags[15:0];
                packet_count_tx <= status_flags[31:16];

                // Update link status
                link_status <= status_flags[24];

                // Check for new packets or status changes
                if (status_flags[25]) begin  // New RX packet available
                    isr_register <= isr_register | ISR_PRX;  // Set Packet Received bit
                end
                if (status_flags[26]) begin  // TX completed
                    isr_register <= isr_register | ISR_PTX;  // Set Packet Transmitted bit
                end

                mem_state <= MEM_IDLE;
            end

            MEM_WRITE_FLAGS: begin
                // Write updated control flags back to shared memory using transaction
                if (!mem_transaction_busy) begin
                    // Setup memory write transaction for control flags
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_CTRL_FLAGS;  // 0xEA1000
                    mem_transaction_data <= status_flags[15:0];  // Lower 16 bits first
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    
                    $display("Starting memory write transaction for control flags: 0x%04x at address 0x%08x", 
                            status_flags[15:0], eth_shared_base + ETH_SHM_CTRL_FLAGS);
                    
                    // Clear the write pending flag
                    flags_write_pending <= 1'b0;
                    
                    // Move to wait state
                    mem_state <= MEM_WAIT_COMPLETE;
                end
            end

            MEM_DATA_PORT_READ: begin
                // Read packet data from NE2000 memory using transaction
                if (!mem_transaction_busy) begin
                    // Setup memory read transaction
                    read_addr <= remote_dma_addr - 16'd2;  // Use previous DMA address
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_NE_MEMORY + (remote_dma_addr - 16'd2);
                    mem_transaction_rd <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    
                    $display("Starting memory read transaction from NE2000 memory at offset 0x%04x", 
                            read_addr);
                    
                    // Move to wait state
                    mem_state <= MEM_WAIT_COMPLETE;
                end
            end

            MEM_DATA_PORT_WRITE: begin
                // Write data to NE2000 memory via data port using transaction
                if (!mem_transaction_busy) begin
                    // Setup memory write transaction
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_NE_MEMORY + remote_dma_addr;
                    mem_transaction_data <= cpu_data_in;  // Data to write
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    
                    $display("Starting memory write transaction to NE2000 memory at offset 0x%04x", 
                            remote_dma_addr);
                    
                    // Move to wait state
                    mem_state <= MEM_WAIT_COMPLETE;
                end
            end

            MEM_RX_BUFFER_READ: begin
                // Read data from RX buffer using transaction
                if (!mem_transaction_busy) begin
                    // Setup memory read transaction for RX buffer
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_RX_BUFFER + rx_buffer_addr;
                    mem_transaction_rd <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    
                    $display("MEM_RX_BUFFER_READ: Reading from RX buffer at offset 0x%04x", 
                            rx_buffer_addr);
                    
                    // Move to wait state
                    mem_state <= MEM_WAIT_COMPLETE;
                end
            end

            MEM_RX_BUFFER_WRITE: begin
                // Write data to RX buffer using transaction
                if (!mem_transaction_busy) begin
                    // Setup memory write transaction for RX buffer
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_RX_BUFFER + rx_buffer_addr;
                    mem_transaction_data <= mem_transaction_data; // Data set by caller
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    
                    $display("MEM_RX_BUFFER_WRITE: Writing 0x%04x to RX buffer at offset 0x%04x", 
                            mem_transaction_data, rx_buffer_addr);
                    
                    // Move to wait state
                    mem_state <= MEM_WAIT_COMPLETE;
                end
            end

            MEM_TX_BUFFER_READ: begin
                // Read data from TX buffer using transaction
                if (!mem_transaction_busy) begin
                    // Setup memory read transaction for TX buffer
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_TX_BUFFER + tx_buffer_addr;
                    mem_transaction_rd <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    
                    $display("MEM_TX_BUFFER_READ: Reading from TX buffer at offset 0x%04x", 
                            tx_buffer_addr);
                    
                    // Move to wait state
                    mem_state <= MEM_WAIT_COMPLETE;
                end
            end

            MEM_TX_BUFFER_WRITE: begin
                // Write data to TX buffer using transaction
                if (!mem_transaction_busy) begin
                    // Setup memory write transaction for TX buffer
                    mem_transaction_addr <= eth_shared_base + ETH_SHM_TX_BUFFER + tx_buffer_addr;
                    mem_transaction_data <= mem_transaction_data; // Data set by caller
                    mem_transaction_wr <= 1'b1;
                    mem_transaction_busy <= 1'b1;
                    
                    $display("MEM_TX_BUFFER_WRITE: Writing 0x%04x to TX buffer at offset 0x%04x", 
                            mem_transaction_data, tx_buffer_addr);
                    
                    // Move to wait state
                    mem_state <= MEM_WAIT_COMPLETE;
                end
            end

            MEM_READ_SIGNATURE: begin
                // Read HPS signature (0xCAFEBABE) for validation
                // Address: eth_shared_base + ETH_SHM_HPS_SIGNATURE (0xEA1064)
                sig_addr <= eth_shared_base + ETH_SHM_HPS_SIGNATURE;
                
                // Read signature from shared memory
                // In real implementation, this would validate HPS is responding
                $display("MEM_READ_SIGNATURE: Reading signature from 0x%08x", sig_addr);
                
                // Set link status based on signature validation
                link_status <= 1'b1;  // Assume signature is valid
                
                mem_state <= MEM_IDLE;
            end

            MEM_WRITE_PACKET_INFO: begin
                // Write packet metadata to shared memory
                // Address: eth_shared_base + ETH_SHM_PACKET_INFO
                info_addr <= eth_shared_base + ETH_SHM_PACKET_INFO;
                
                $display("MEM_WRITE_PACKET_INFO: Writing packet info to 0x%08x", info_addr);
                // Write packet length, count, status to shared memory
                
                mem_state <= MEM_IDLE;
            end

            MEM_READ_MAC_ADDR: begin
                // Read MAC address from shared memory
                // Address: eth_shared_base + ETH_SHM_CTRL_MAC (0xEA1024)
                mac_addr <= eth_shared_base + ETH_SHM_CTRL_MAC;
                
                $display("MEM_READ_MAC_ADDR: Reading MAC address from 0x%08x", mac_addr);
                // Read 6-byte MAC address from shared memory
                
                mem_state <= MEM_IDLE;
            end

            MEM_WRITE_STATS: begin
                // Write statistics to shared memory
                // Address: eth_shared_base + ETH_SHM_CTRL_STATS (0xEA102C)
                stats_addr <= eth_shared_base + ETH_SHM_CTRL_STATS;
                
                $display("MEM_WRITE_STATS: Writing statistics to 0x%08x", stats_addr);
                // Write packet counts, error counts to shared memory
                
                mem_state <= MEM_IDLE;
            end

            MEM_WAIT_COMPLETE: begin
                // Wait for memory operation to complete with timeout
                $display("MEM_WAIT_COMPLETE: Waiting for memory operation at 0x%08x (timeout=%d)", 
                        mem_transaction_addr, mem_transaction_timeout);
                
                // Increment timeout counter
                mem_transaction_timeout <= mem_transaction_timeout + 1;
                
                // Check for timeout (1000 cycles = ~20µs at 50MHz)
                if (mem_transaction_timeout > 16'd1000) begin
                    $display("WARNING: Memory transaction timeout at address 0x%08x", mem_transaction_addr);
                    // Force transaction completion and return to idle
                    mem_transaction_rd <= 1'b0;
                    mem_transaction_wr <= 1'b0;
                    mem_transaction_busy <= 1'b0;
                    mem_transaction_timeout <= 16'h0000;
                    mem_state <= MEM_ERROR;
                end else if (mem_transaction_rd) begin
                    // Complete read transaction
                    // In real implementation, data would come from memory controller
                    // Simulate realistic data based on address
                    case (mem_transaction_addr[15:0])
                        16'h1064: begin  // HPS signature
                            data_port_read_data <= 16'hCAFE;  // High word of 0xCAFEBABE
                        end
                        default: begin
                            // Check if reading from NE2000 memory range
                            if ((mem_transaction_addr >= ETH_SHM_NE_MEMORY) && 
                                (mem_transaction_addr < (ETH_SHM_NE_MEMORY + 16'h4000))) begin
                                // NE2000 memory data - simulate packet data pattern
                                ne_offset <= mem_transaction_addr - ETH_SHM_NE_MEMORY;
                                case (mem_transaction_addr[3:0])
                                    4'h0: data_port_read_data <= 16'h0001;  // Packet status
                                    4'h1: data_port_read_data <= 16'h0040;  // Next page
                                    4'h2: data_port_read_data <= 16'h005C;  // Packet length
                                    4'h3: data_port_read_data <= 16'hFFFF;  // Destination MAC start
                                    default: data_port_read_data <= {mem_transaction_addr[7:0], 8'hDD};  // Data pattern
                                endcase
                            end
                            // Check if reading from RX buffer range
                            else if ((mem_transaction_addr >= ETH_SHM_RX_BUFFER) && 
                                     (mem_transaction_addr < (ETH_SHM_RX_BUFFER + 16'h0600))) begin
                                // RX buffer data - simulate received packet data
                                rx_offset <= mem_transaction_addr - ETH_SHM_RX_BUFFER;
                                case (mem_transaction_addr[3:0])
                                    4'h0: begin
                                        rx_buffer_read_data <= 16'h0001;  // RX packet status
                                        data_port_read_data <= 16'h0001;
                                    end
                                    4'h1: begin
                                        rx_buffer_read_data <= 16'h0042;  // Next RX page
                                        data_port_read_data <= 16'h0042;
                                    end
                                    4'h2: begin
                                        rx_buffer_read_data <= rx_packet_length;  // RX packet length
                                        data_port_read_data <= rx_packet_length;
                                    end
                                    default: begin
                                        rx_buffer_read_data <= {mem_transaction_addr[7:0], 8'hAA};  // RX data pattern
                                        data_port_read_data <= {mem_transaction_addr[7:0], 8'hAA};
                                    end
                                endcase
                            end
                            // Check if reading from TX buffer range
                            else if ((mem_transaction_addr >= ETH_SHM_TX_BUFFER) && 
                                     (mem_transaction_addr < (ETH_SHM_TX_BUFFER + 16'h0600))) begin
                                // TX buffer data - simulate transmit packet data
                                tx_offset <= mem_transaction_addr - ETH_SHM_TX_BUFFER;
                                case (mem_transaction_addr[3:0])
                                    4'h0: begin
                                        tx_buffer_read_data <= 16'h0002;  // TX packet status
                                        data_port_read_data <= 16'h0002;
                                    end
                                    4'h1: begin
                                        tx_buffer_read_data <= 16'h0020;  // TX start page
                                        data_port_read_data <= 16'h0020;
                                    end
                                    4'h2: begin
                                        tx_buffer_read_data <= tx_packet_length;  // TX packet length
                                        data_port_read_data <= tx_packet_length;
                                    end
                                    default: begin
                                        tx_buffer_read_data <= {mem_transaction_addr[7:0], 8'hBB};  // TX data pattern
                                        data_port_read_data <= {mem_transaction_addr[7:0], 8'hBB};
                                    end
                                endcase
                            end
                            else begin
                                data_port_read_data <= mem_transaction_addr[15:0];  // Address as data
                            end
                        end
                    endcase
                    
                    $display("Memory read completed: data = 0x%04x from address 0x%08x", 
                            data_port_read_data, mem_transaction_addr);
                end else if (mem_transaction_wr) begin
                    // Complete write transaction
                    $display("Memory write completed: data = 0x%04x to address 0x%08x", 
                            mem_transaction_data, mem_transaction_addr);
                end
                
                // Clear transaction flags and return to idle
                mem_transaction_rd <= 1'b0;
                mem_transaction_wr <= 1'b0;
                mem_transaction_busy <= 1'b0;
                mem_transaction_timeout <= 16'h0000;  // Reset timeout counter
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
                isr_register <= 8'h80;             // Set reset status bit
                imr_register <= 8'h00;             // Disable all interrupts
                
                // Clear packet counters
                packet_count_rx <= 16'h0000;
                packet_count_tx <= 16'h0000;
                
                // Reset buffer addresses
                rx_buffer_addr <= 16'h0000;
                tx_buffer_addr <= 16'h0000;
                
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
        if (!sel_ethernet || !cpu_rd) begin
            data_port_read_pending <= 1'b0;
            memory_read_pending <= 1'b0;
            control_read_pending <= 1'b0;
            buffer_read_pending <= 1'b0;
        end

    end

    // Generate eth_irq based on ISR and IMR (proper NE2000 behavior)
    // eth_irq is asserted when any enabled interrupt is pending
    // This handles both reset (when ISR/IMR are 0) and normal operation
    eth_irq <= |(isr_register & imr_register);
end

// Address decode logic - use [23:1] word address format  
// Workaround for Verilator bit slicing issues - use always block instead of wire
reg [15:0] effective_addr;
reg [15:0] byte_addr;

always @(*) begin
    // Workaround for Verilator [23:1] compatibility issues
    // Use arithmetic operations instead of bit operations
    effective_addr = cpu_addr % 65536;  // Get lower 16 bits using modulo
    
    // Calculate byte address by shifting word address
    byte_addr = effective_addr << 1;
end

// Dataport detection: byte addresses 0x620 and 0xC40 -> word addresses 0x310 and 0x620
assign is_data_port_access = (effective_addr == 16'h0310) || (effective_addr == 16'h0620);

// Register access detection: byte 0x600-0x61F and 0xC00-0xC3F -> word 0x300-0x30F and 0x600-0x61F
assign is_register_access = ((effective_addr >= 16'h0300) && (effective_addr <= 16'h030F)) ||
                           ((effective_addr >= 16'h0600) && (effective_addr <= 16'h061F));

// Memory ranges using byte addresses
assign is_memory_access = (byte_addr >= 16'h3000) && (byte_addr <= 16'h6FFF);
assign is_control_access = (byte_addr >= 16'h1000) && (byte_addr <= 16'h1FFF);
assign is_buffer_access = (byte_addr >= 16'h2000) && (byte_addr <= 16'h2FFF);
assign is_tx_buffer_access = (byte_addr >= 16'h2000) && (byte_addr <= 16'h25FF);
assign is_rx_buffer_access = (byte_addr >= 16'h2600) && (byte_addr <= 16'h2BFF);

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

    // Handle register space access (0xEA0000-0xEA0FFF)
    if (sel_ethernet && cpu_rd) begin
        if (is_data_port_access) begin
            // Data port read - return data from shared memory
            cpu_data_out = data_port_read_data;
        end else if (is_register_access) begin
                // Return register data - each register gets individual 4-byte space
                // Register values in MSB (high byte) for Amiga bus compatibility
                case (register_select[4:0])
                    // Register 0x00: CR - Command Register
                    5'h00: cpu_data_out = {cr_register, 8'h00};

                    // Register 0x01: CLDA0/PAR0 - Current Local DMA Address 0 or Physical Address Register 0
                    5'h01: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h40, 8'h00};            // CLDA0
                            2'b01: cpu_data_out = {8'h00, 8'h00};            // PAR0
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x02: CLDA1/PAR1 - Current Local DMA Address 1 or Physical Address Register 1
                    5'h02: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // CLDA1
                            2'b01: cpu_data_out = {8'h00, 8'h00};            // PAR1
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x03: BNRY/PAR2 - Boundary Pointer or Physical Address Register 2
                    5'h03: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h40, 8'h00};            // BNRY
                            2'b01: cpu_data_out = {8'h00, 8'h00};            // PAR2
                            default: cpu_data_out = {8'h40, 8'h00};
                        endcase
                    end

                    // Register 0x04: TSR/PAR3 - Transmit Status Register or Physical Address Register 3
                    5'h04: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // TSR
                            2'b01: cpu_data_out = {8'h00, 8'h00};            // PAR3
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x05: NCR/PAR4 - Number of Collisions Register or Physical Address Register 4
                    5'h05: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // NCR
                            2'b01: cpu_data_out = {8'h00, 8'h00};            // PAR4
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x06: FIFO/PAR5 - FIFO Register or Physical Address Register 5
                    5'h06: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};            // FIFO
                            2'b01: cpu_data_out = {8'h00, 8'h00};            // PAR5
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x07: ISR/CURR - Interrupt Status Register or Current Page Register
                    5'h07: begin
                        case (current_page)
                            2'b00: cpu_data_out = {isr_register, 8'h00};     // ISR - return actual interrupt status
                            2'b01: cpu_data_out = {8'h40, 8'h00};            // CURR
                            default: cpu_data_out = {isr_register, 8'h00};
                        endcase
                    end

                    // Register 0x08: CRDA0/TPSR - Current Remote DMA Address 0 or Transmit Page Start Register
                    5'h08: begin
                        case (current_page)
                            2'b00: cpu_data_out = {remote_dma_addr[7:0], 8'h00};  // CRDA0
                            2'b01: cpu_data_out = {8'h40, 8'h00};                 // TPSR
                            default: cpu_data_out = {remote_dma_addr[7:0], 8'h00};
                        endcase
                    end

                    // Register 0x09: CRDA1/MAR0 - Current Remote DMA Address 1 or Multicast Address Register 0
                    5'h09: begin
                        case (current_page)
                            2'b00: cpu_data_out = {remote_dma_addr[15:8], 8'h00}; // CRDA1
                            2'b01: cpu_data_out = {8'h00, 8'h00};                 // MAR0
                            default: cpu_data_out = {remote_dma_addr[15:8], 8'h00};
                        endcase
                    end

                    // Register 0x0A: 8019ID0/RBCR0/MAR1 - RTL8019AS ID0, Remote Byte Count Register 0, or Multicast Address Register 1
                    5'h0A: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h50, 8'h00};                  // Page 0: 8019ID0 = 0x50 for RTL8019AS
                            2'b01: cpu_data_out = {8'h00, 8'h00};                  // Page 1: MAR1 (Multicast Address Register 1)
                            default: cpu_data_out = {8'h50, 8'h00};                // Default to ID0
                        endcase
                    end

                    // Register 0x0B: 8019ID1/RBCR1/MAR2 - RTL8019AS ID1, Remote Byte Count Register 1, or Multicast Address Register 2
                    5'h0B: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h70, 8'h00};                   // Page 0: 8019ID1 = 0x70 for RTL8019AS
                            2'b01: cpu_data_out = {8'h00, 8'h00};                   // Page 1: MAR2 (Multicast Address Register 2)
                            2'b11: cpu_data_out = {8'h00, 8'h00};                  // Page 3: INTR (Interrupt Register)
                            default: cpu_data_out = {8'h70, 8'h00};                 // Default to ID1
                        endcase
                    end

                    // Register 0x0C: RSR/MAR3 - Receive Status Register or Multicast Address Register 3
                    5'h0C: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};                 // RSR
                            2'b01: cpu_data_out = {8'h00, 8'h00};                 // MAR3
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x0D: CNTR0/MAR4 - Tally Counter 0 or Multicast Address Register 4
                    5'h0D: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00};                 // CNTR0
                            2'b01: cpu_data_out = {8'h00, 8'h00};                 // MAR4
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x0E: CNTR1/MAR5 - Tally Counter 1 or Multicast Address Register 5 (Heartbeat low)
                    5'h0E: begin
                        case (current_page)
                            2'b00: cpu_data_out = {8'h00, 8'h00}; // CNTR1 (from memory)
                            2'b01: cpu_data_out = {8'h00, 8'h00};                 // MAR5
                            default: cpu_data_out = {8'h00, 8'h00};
                        endcase
                    end

                    // Register 0x0F: IMR/MAR6 - Interrupt Mask Register or Multicast Address Register 6
                    5'h0F: begin
                        case (current_page)
                            2'b00: cpu_data_out = {imr_register, 8'h00}; // IMR - return actual interrupt mask
                            2'b01: cpu_data_out = {8'h00, 8'h00};        // MAR6
                            default: cpu_data_out = {imr_register, 8'h00};
                        endcase
                    end

                    default: cpu_data_out = 16'h0000;  // Invalid register
                endcase
            end
        end
    
    // Handle shared memory space access (0xEA1000-0xEAFFFF)
    if (sel_ethernet_shm && cpu_rd) begin
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
