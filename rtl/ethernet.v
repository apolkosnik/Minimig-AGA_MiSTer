// Ethernet Controller for MiSTer Minimig - Full NE2000/RTL8019AS Implementation
// Implements complete NE2000 register set with direct memory access instead of HPS bus transactions
// Compatible with X-Surf 100 and other NE2000-based Amiga ethernet cards

`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */
module ethernet_interface
(
    input wire clk,
    input wire reset,

    // CPU bus interface (Amiga side)  
    input  wire [15:1] cpu_addr,
    input  wire [15:0] cpu_data_in,
    output reg  [15:0] cpu_data_out,
    input  wire        cpu_rd,
    input  wire        cpu_hwr,
    input  wire        cpu_lwr,
    input  wire        cpu_as,
    input  wire        cpu_uds,
    input  wire        cpu_lds,

    // Chip select for entire ethernet address space (shared memory)
    input  wire        sel_ethernet_shm,
    
    // Chip select for ethernet register space
    input  wire        sel_ethernet,

    // External shared-memory DMA path
    input  wire        eth_dma_ready,
    input  wire [15:0] eth_dma_rdata,
    output reg         eth_dma_req,
    output reg         eth_dma_write,
    output reg  [15:1] eth_dma_addr,
    output reg  [15:0] eth_dma_wdata,
    output reg         eth_dma_uds,
    output reg         eth_dma_lds,

    // Interrupt output to Amiga
    output reg         eth_irq,
    
    // Data acknowledge - prevents bus cycle completion during shared memory access
    output reg         dtack_eth
);

//   Ethernet Controller Memory Map
// #define ETH_SHMEM_ADDR   0x28EA0000 // HPS physical address mapped to Amiga 0xEA0000
//   Selected by: sel_ethernet_shm (unified with shared memory)

//   Base Address: 0xEA0000 (configurable via autoconfig)

//   Register Space (0xEA0000 - 0xEA0FFF) - part of unified shared memory space

//   NE2000 Registers (0xEA0C00 - 0xEA0C3F) - Simplified Implementation

//   - 0xEA0C00-0xEA0C3C: NE2000 registers with 4-byte spacing
//     - 0xEA0C00: CR (Command Register)
//     - 0xEA0C04: CLDA0/PSTART (Current Local DMA Address 0 / Page Start)
//     - 0xEA0C08: CLDA1/PSTOP (Current Local DMA Address 1 / Page Stop)
//     - 0xEA0C0C: BNRY (Boundary Register)
//     - 0xEA0C10: TSR/TPSR (Transmit Status / Transmit Page Start)
//     - 0xEA0C14: NCR/TBCR0 (Number of Collisions / Transmit Byte Count 0)
//     - 0xEA0C18: FIFO/TBCR1 (FIFO / Transmit Byte Count 1)
//     - 0xEA0C1C: ISR (Interrupt Status Register)
//     - 0xEA0C20: CRDA0/RSAR0 (Current Remote DMA Address 0 / Remote Start Address 0)
//     - 0xEA0C24: CRDA1/RSAR1 (Current Remote DMA Address 1 / Remote Start Address 1)
//     - 0xEA0C28: 8019ID0/RBCR0 (RTL8019 ID0 / Remote Byte Count 0)
//     - 0xEA0C2C: 8019ID1/RBCR1 (RTL8019 ID1 / Remote Byte Count 1)
//     - 0xEA0C30: RSR (Receive Status Register)
//     - 0xEA0C34: CNTR0 (Tally Counter 0)
//     - 0xEA0C38: CNTR1 (Tally Counter 1)
//     - 0xEA0C3C: CNTR2 (Tally Counter 2)
//   - 0xEA0C40: Data Port (Remote DMA port)

//   Shared Memory Space (0xEA1000 - 0xEAFFFF)

//   Selected by: sel_ethernet_shm (unified with register space)

//   Control Structure (0xEA1000 - 0xEA1FFF)

//   - 0xEA1000: ETH_SHM_CTRL_FLAGS (4 bytes) - Control flags
//   - 0xEA1004: ETH_SHM_CTRL_REGS (72 bytes) - NE2000 registers (all pages + extra) - START HERE
//   - 0xEA104C: ETH_SHM_CTRL_MAC (6 bytes) - MAC address  
//   - 0xEA1052: ETH_SHM_CTRL_STATUS (2 bytes) - Status
//   - 0xEA1054: ETH_SHM_CTRL_STATS (52 bytes) - Packet statistics
//   - 0xEA1088: ETH_SHM_HPS_HEARTBEAT (4 bytes) - HPS heartbeat
//   - 0xEA108C: ETH_SHM_HPS_SIGNATURE (4 bytes) - Signature (0xCAFEBABE)

//   Packet Buffers (0xEA2000 - 0xEA2FFF)

//   - 0xEA2000: ETH_SHM_TX_BUFFER (1500 bytes) - TX packet buffer
//   - 0xEA2600: ETH_SHM_RX_BUFFER (1500 bytes) - RX packet buffer
//   - 0xEA2C00: ETH_SHM_PACKET_INFO (512 bytes) - Packet metadata

//   NE2000 Memory Space (0xEA3000 - 0xEAAFFF)

//   - 0xEA3000: ETH_SHM_NE_MEMORY (32KB) - compact backing store for RTL8019
//     packet RAM at NE addresses 0x4000-0xBFFF.
//     - Remote DMA addresses below 0x0020 are handled locally as PROM/shadow RAM.
//     - Remote DMA addresses 0x0020-0x3FFF are unmapped and read as 0xFF.

//   Debug/Future Use (0xEAB000 - 0xEAFFFF)

//   - 0xEAB000: ETH_SHM_DEBUG_INFO (4KB) - Debug information
//   - 0xEAC000: ETH_SHM_FUTURE_USE (16KB) - Reserved for expansion

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


// The direct shared-memory window is handled by cpu_wrapper/ddram_ctrl.
// This module only owns the local register window and the remote-DMA data port.

parameter [15:0] ETH_SHM_CTRL_FLAGS  = 16'h1000;
parameter [15:0] ETH_SHM_CTRL_REGS   = 16'h1004;
parameter [15:0] ETH_SHM_CTRL_MAC    = 16'h104C;
parameter [15:0] ETH_RTL8019_STATE   = 16'h1100;
parameter [15:0] ETH_SHM_RX_BUFFER   = 16'h2600;
parameter [15:0] ETH_SHM_PACKET_INFO = 16'h2C00;
parameter [15:0] ETH_SHM_NE_MEMORY   = 16'h3000;
parameter [15:0] ETH_FLAG_TX_REQ     = 16'h0002;
parameter [15:0] ETH_FLAG_RX_AVAIL   = 16'h0004;
parameter [15:0] ETH_FLAG_IRQ        = 16'h0008;
parameter [15:0] ETH_FLAG_ENABLED    = 16'h0020;
parameter [15:0] NE_PMEM_START       = 16'h4000;
parameter [15:0] NE_PMEM_END         = 16'hC000;
parameter [7:0]  NE_PAGE_BASE = 8'h40;
parameter [7:0]  BG_POLL_RELOAD = 8'd63;
parameter [9:0]  ETH_DMA_TIMEOUT_CYCLES = 10'd511;
parameter [7:0]  DEFAULT_MAC0 = 8'h52;
parameter [7:0]  DEFAULT_MAC1 = 8'h54;
parameter [7:0]  DEFAULT_MAC2 = 8'h05;
parameter [7:0]  DEFAULT_MAC3 = 8'h04;
parameter [7:0]  DEFAULT_MAC4 = 8'h03;
parameter [7:0]  DEFAULT_MAC5 = 8'h02;

reg [7:0]  cr_register;
wire [1:0] current_page = cr_register[7:6];

wire       cpu_wr = cpu_lwr | cpu_hwr;
wire [7:0] cpu_write_byte = ~cpu_uds ? cpu_data_in[15:8] : cpu_data_in[7:0];
wire       is_data_port_access;
wire       is_register_access;
wire       is_reset_port_access;

reg [15:0] remote_dma_addr;
reg [15:0] remote_byte_count;
reg        data_port_read_pending;
reg        data_port_write_pending;
reg        data_port_transfer_done;
reg        data_port_cycle_active;
reg        data_port_bus_active_prev;
reg [15:0] data_port_read_data;
reg [15:0] data_port_byte_addr;
reg        data_port_word_mode;
reg        tx_complete_pending;

// NE2000 Interrupt handling - proper implementation
reg [7:0]  isr_register;       // Interrupt Status Register (0x07)
reg [7:0]  imr_register;       // Interrupt Mask Register (0x0F)
reg [7:0]  dcr_register;
reg [7:0]  pstart_register;
reg [7:0]  pstop_register;
reg [7:0]  bnry_register;
reg [7:0]  tpsr_register;
reg [15:0] tbcr_register;
reg [7:0]  tsr_register;
reg [7:0]  rsr_register;
reg [7:0]  curr_register;
reg [7:0]  tcr_register;
reg [7:0]  rcr_register;
reg [7:0]  rtl8019_config0;
reg [7:0]  rtl8019_config1;
reg [7:0]  rtl8019_config2;
reg [7:0]  rtl8019_config3;
reg [7:0]  rtl8019_e9346cr;
reg        rx_poll_enabled;
reg        shm_sync_enabled;
reg        tx_request_pending;
reg [15:0] mirrored_fpga_flags;
reg [7:0]  par_registers [0:5];
reg [7:0]  mar_registers [0:7];
reg [7:0]  reset_port_latch;
reg [4:0]  bg_state;
reg [7:0]  bg_poll_counter;
reg        bg_dma_inflight;
reg [15:0] bg_flags_word;
reg [15:0] bg_rx_total_length;
reg [15:0] bg_rx_src_offset;
reg [15:0] bg_rx_dst_offset;
reg [15:0] bg_rx_bytes_remaining;
reg [7:0]  bg_rx_next_page;
reg [15:0] bg_source_word;
reg [5:0]  bg_sync_slot;
reg        bg_polling_rx_flags;
reg        bg_clear_rx_avail;
reg [7:0]  prom_shadow [0:31];
reg [15:0] debug_heartbeat;
reg [15:0] debug_local_wait_cycles;
reg [15:0] debug_dma_wait_cycles;
reg [14:0] debug_sticky_flags_lo;
reg        debug_dma_timeout_sticky;
reg [9:0]  eth_dma_wait_counter;
integer    i;

// NE2000 DCR bit definitions
// Bit 0: WTS (Word Transfer Select) - 0=byte DMA, 1=word DMA
// Bit 1: BOS (Byte Order Select) - 0=MSB first, 1=LSB first (8086 mode)
// Bit 2: LAS (Long Address Select) - 0=dual 16-bit DMA, 1=single 32-bit DMA
// Bit 3: LS (Loopback Select) - 0=normal, 1=loopback
// Bit 4: ARM (Auto-initialize Remote) - 0=manual, 1=auto-init remote DMA
// Bit 5: FT0 (FIFO Threshold Select 0)
// Bit 6: FT1 (FIFO Threshold Select 1)
// Bit 7: Reserved

// NE2000 ISR bit definitions
parameter ISR_PRX = 8'h01;     // Bit 0: Packet received
parameter ISR_PTX = 8'h02;     // Bit 1: Packet transmitted
parameter ISR_OVW = 8'h10;     // Bit 4: Receive ring overrun
parameter ISR_RDC = 8'h40;     // Bit 6: Remote DMA Complete
parameter ISR_RST = 8'h80;     // Bit 7: Reset status
parameter TSR_PTX = 8'h01;     // Bit 0: Packet transmitted without error
parameter RSR_PRX = 8'h01;     // Bit 0: Packet received without error

localparam [4:0] BG_IDLE             = 5'd0;
localparam [4:0] BG_READ_FLAGS_REQ   = 5'd1;
localparam [4:0] BG_READ_FLAGS_WAIT  = 5'd2;
localparam [4:0] BG_READ_RX_LEN_REQ  = 5'd3;
localparam [4:0] BG_READ_RX_LEN_WAIT = 5'd4;
localparam [4:0] BG_WRITE_HDR0_REQ   = 5'd5;
localparam [4:0] BG_WRITE_HDR0_WAIT  = 5'd6;
localparam [4:0] BG_WRITE_HDR1_REQ   = 5'd7;
localparam [4:0] BG_WRITE_HDR1_WAIT  = 5'd8;
localparam [4:0] BG_READ_PAYLOAD_REQ = 5'd9;
localparam [4:0] BG_READ_PAYLOAD_WAIT= 5'd10;
localparam [4:0] BG_WRITE_PAYLOAD_REQ= 5'd11;
localparam [4:0] BG_WRITE_PAYLOAD_WAIT=5'd12;
localparam [4:0] BG_CLEAR_FLAG_REQ   = 5'd13;
localparam [4:0] BG_CLEAR_FLAG_WAIT  = 5'd14;
localparam [4:0] BG_SYNC_WORD_REQ    = 5'd15;
localparam [4:0] BG_SYNC_WORD_WAIT   = 5'd16;

wire [7:0] cr_write_value = cpu_write_byte;
wire       rtl8019_config_write_enable = (rtl8019_e9346cr[7:6] == 2'b11);

task automatic apply_nic_reset;
    begin
        cr_register <= 8'h21;
        remote_dma_addr <= 16'h0000;
        remote_byte_count <= 16'h0000;
        data_port_read_pending <= 1'b0;
        data_port_write_pending <= 1'b0;
        data_port_transfer_done <= 1'b0;
        data_port_cycle_active <= 1'b0;
        data_port_bus_active_prev <= 1'b0;
        data_port_read_data <= 16'h0000;
        data_port_byte_addr <= 16'h0000;
        data_port_word_mode <= 1'b0;
        tx_complete_pending <= 1'b0;
        isr_register <= ISR_RST;
        imr_register <= 8'h00;
        dcr_register <= 8'h80;
        pstart_register <= 8'h40;
        pstop_register <= 8'h80;
        bnry_register <= 8'h40;
        tpsr_register <= 8'h40;
        tbcr_register <= 16'h0000;
        tsr_register <= 8'h00;
        rsr_register <= 8'h00;
        curr_register <= 8'h41;
        tcr_register <= 8'h00;
        rcr_register <= 8'h00;
        rtl8019_config0 <= 8'h00;
        rtl8019_config1 <= 8'h80;
        rtl8019_config2 <= 8'h40;
        rtl8019_config3 <= 8'h40;
        rtl8019_e9346cr <= 8'h00;
        rx_poll_enabled <= 1'b0;
        shm_sync_enabled <= 1'b0;
        tx_request_pending <= 1'b0;
        mirrored_fpga_flags <= 16'h0000;
        bg_state <= BG_IDLE;
        bg_poll_counter <= 8'h00;
        bg_dma_inflight <= 1'b0;
        bg_flags_word <= 16'h0000;
        bg_rx_total_length <= 16'h0000;
        bg_rx_src_offset <= 16'h0000;
        bg_rx_dst_offset <= 16'h0000;
        bg_rx_bytes_remaining <= 16'h0000;
        bg_rx_next_page <= 8'h00;
        bg_source_word <= 16'h0000;
        bg_sync_slot <= 6'd0;
        bg_polling_rx_flags <= 1'b0;
        bg_clear_rx_avail <= 1'b0;
        eth_dma_req <= 1'b0;
        eth_dma_write <= 1'b0;
        eth_dma_addr <= 15'h0000;
        eth_dma_wdata <= 16'h0000;
        eth_dma_uds <= 1'b1;
        eth_dma_lds <= 1'b1;
        eth_irq <= 1'b0;
        eth_dma_wait_counter <= 10'd0;
        par_registers[0] <= DEFAULT_MAC0;
        par_registers[1] <= DEFAULT_MAC1;
        par_registers[2] <= DEFAULT_MAC2;
        par_registers[3] <= DEFAULT_MAC3;
        par_registers[4] <= DEFAULT_MAC4;
        par_registers[5] <= DEFAULT_MAC5;
        for (i = 0; i < 8; i = i + 1) begin
            mar_registers[i] <= 8'h00;
        end
        prom_shadow[0] <= DEFAULT_MAC0;
        prom_shadow[1] <= DEFAULT_MAC0;
        prom_shadow[2] <= DEFAULT_MAC1;
        prom_shadow[3] <= DEFAULT_MAC1;
        prom_shadow[4] <= DEFAULT_MAC2;
        prom_shadow[5] <= DEFAULT_MAC2;
        prom_shadow[6] <= DEFAULT_MAC3;
        prom_shadow[7] <= DEFAULT_MAC3;
        prom_shadow[8] <= DEFAULT_MAC4;
        prom_shadow[9] <= DEFAULT_MAC4;
        prom_shadow[10] <= DEFAULT_MAC5;
        prom_shadow[11] <= DEFAULT_MAC5;
        prom_shadow[12] <= 8'h00;
        prom_shadow[13] <= 8'h00;
        prom_shadow[14] <= 8'h00;
        prom_shadow[15] <= 8'h00;
        prom_shadow[16] <= 8'h00;
        prom_shadow[17] <= 8'h00;
        prom_shadow[18] <= 8'h00;
        prom_shadow[19] <= 8'h00;
        prom_shadow[20] <= 8'h00;
        prom_shadow[21] <= 8'h00;
        prom_shadow[22] <= 8'h00;
        prom_shadow[23] <= 8'h00;
        prom_shadow[24] <= 8'h00;
        prom_shadow[25] <= 8'h00;
        prom_shadow[26] <= 8'h00;
        prom_shadow[27] <= 8'h00;
        prom_shadow[28] <= 8'h57;
        prom_shadow[29] <= 8'h57;
        prom_shadow[30] <= 8'h57;
        prom_shadow[31] <= 8'h57;
    end
endtask

task automatic complete_data_port_transfer;
    input [15:0] dma_read_word;
    reg [15:0] read_word;
    begin
        read_word = maybe_swap_word(dma_read_word, dcr_register[1]);

        if (!eth_dma_write) begin
            if (data_port_word_mode) begin
                data_port_read_data <= read_word;
            end else begin
                // Mirror byte reads onto both lanes so either UDS or LDS byte access works.
                data_port_read_data <= data_port_byte_addr[0] ?
                    {read_word[7:0], read_word[7:0]} :
                    {read_word[15:8], read_word[15:8]};
            end
        end

        if (data_port_word_mode) begin
            remote_dma_addr <= data_port_byte_addr + 16'h0002;
            if (remote_byte_count > 16'h0002) begin
                remote_byte_count <= remote_byte_count - 16'h0002;
            end else begin
                remote_byte_count <= 16'h0000;
                isr_register <= isr_register | ISR_RDC;
                if (shm_sync_enabled || tx_request_pending) begin
                    shm_sync_enabled <= 1'b1;
                    bg_sync_slot <= 6'd0;
                end
            end
        end else begin
            remote_dma_addr <= data_port_byte_addr + 16'h0001;
            if (remote_byte_count > 16'h0001) begin
                remote_byte_count <= remote_byte_count - 16'h0001;
            end else begin
                remote_byte_count <= 16'h0000;
                isr_register <= isr_register | ISR_RDC;
                if (shm_sync_enabled || tx_request_pending) begin
                    shm_sync_enabled <= 1'b1;
                    bg_sync_slot <= 6'd0;
                end
            end
        end

        eth_dma_req <= 1'b0;
        data_port_read_pending <= 1'b0;
        data_port_write_pending <= 1'b0;
        data_port_transfer_done <= 1'b1;
    end
endtask

/* verilator lint_off UNUSEDSIGNAL */
function [14:0] ne_pmem_word_offset;
    input [15:0] addr;
    reg [15:0] normalized_addr;
    begin
        normalized_addr = addr - NE_PMEM_START;
        ne_pmem_word_offset = normalized_addr[15:1];
    end
endfunction

function [7:0] sanitize_ring_page;
    input [7:0] page;
    input [7:0] pstart;
    input [7:0] pstop;
    begin
        if ((page < pstart) || (page >= pstop)) begin
            sanitize_ring_page = pstart;
        end else begin
            sanitize_ring_page = page;
        end
    end
endfunction

function [15:0] maybe_swap_word;
    input [15:0] word_value;
    input        swap_bytes;
    begin
        maybe_swap_word = swap_bytes ? {word_value[7:0], word_value[15:8]} : word_value;
    end
endfunction

function [7:0] wrap_ring_page_add;
    input [7:0] page;
    input [7:0] pages;
    input [7:0] pstart;
    input [7:0] pstop;
    reg [8:0] next_page;
    reg [7:0] wrapped_page;
    begin
        next_page = {1'b0, page} + {1'b0, pages};
        if (next_page >= {1'b0, pstop}) begin
            wrapped_page = pstart + next_page[7:0] - pstop;
            wrap_ring_page_add = wrapped_page;
        end else begin
            wrap_ring_page_add = next_page[7:0];
        end
    end
endfunction

function [15:0] ring_page_byte_offset;
    input [7:0] page;
    begin
        ring_page_byte_offset = {page - NE_PAGE_BASE, 8'h00};
    end
endfunction

function [15:0] hps_u16_from_dma;
    input [15:0] data;
    begin
        hps_u16_from_dma = {data[7:0], data[15:8]};
    end
endfunction

function [15:0] format_reg_read_data;
    input [7:0] value;
    input       uds_n;
    input       lds_n;
    begin
        if (!uds_n && lds_n) begin
            format_reg_read_data = {value, 8'h00};
        end else if (uds_n && !lds_n) begin
            format_reg_read_data = {8'h00, value};
        end else begin
            // Mirror register bytes on word/unspecified reads so monitor and
            // driver code that samples either lane still sees the value.
            format_reg_read_data = {value, value};
        end
    end
endfunction

function [7:0] rx_page_count_for_length;
    input [15:0] length;
    reg [15:0] rounded_length;
    begin
        rounded_length = length + 16'h0103;
        rx_page_count_for_length = rounded_length[15:8];
    end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

localparam [15:0] ETH_FPGA_FLAG_MASK = ETH_FLAG_TX_REQ | ETH_FLAG_IRQ | ETH_FLAG_ENABLED;
localparam [15:0] ETH_HPS_FLAG_MASK = ETH_FLAG_RX_AVAIL;

function [7:0] shm_ctrl_reg_value;
    input [4:0] slot;
    begin
        case (slot)
            5'h00: shm_ctrl_reg_value = cr_register;
            5'h01: shm_ctrl_reg_value = pstart_register;
            5'h02: shm_ctrl_reg_value = pstop_register;
            5'h03: shm_ctrl_reg_value = bnry_register;
            5'h04: shm_ctrl_reg_value = tpsr_register;
            5'h05: shm_ctrl_reg_value = tbcr_register[7:0];
            5'h06: shm_ctrl_reg_value = tbcr_register[15:8];
            5'h07: shm_ctrl_reg_value = isr_register;
            5'h08: shm_ctrl_reg_value = remote_dma_addr[7:0];
            5'h09: shm_ctrl_reg_value = remote_dma_addr[15:8];
            5'h0A: shm_ctrl_reg_value = remote_byte_count[7:0];
            5'h0B: shm_ctrl_reg_value = remote_byte_count[15:8];
            5'h0C: shm_ctrl_reg_value = rcr_register;
            5'h0D: shm_ctrl_reg_value = tcr_register;
            5'h0E: shm_ctrl_reg_value = dcr_register;
            5'h0F: shm_ctrl_reg_value = imr_register;
            5'h11: shm_ctrl_reg_value = par_registers[0];
            5'h12: shm_ctrl_reg_value = par_registers[1];
            5'h13: shm_ctrl_reg_value = par_registers[2];
            5'h14: shm_ctrl_reg_value = par_registers[3];
            5'h15: shm_ctrl_reg_value = par_registers[4];
            5'h16: shm_ctrl_reg_value = par_registers[5];
            5'h17: shm_ctrl_reg_value = curr_register;
            5'h18: shm_ctrl_reg_value = mar_registers[0];
            5'h19: shm_ctrl_reg_value = mar_registers[1];
            5'h1A: shm_ctrl_reg_value = mar_registers[2];
            5'h1B: shm_ctrl_reg_value = mar_registers[3];
            5'h1C: shm_ctrl_reg_value = mar_registers[4];
            5'h1D: shm_ctrl_reg_value = mar_registers[5];
            5'h1E: shm_ctrl_reg_value = mar_registers[6];
            5'h1F: shm_ctrl_reg_value = mar_registers[7];
            default: shm_ctrl_reg_value = 8'h00;
        endcase
    end
endfunction

/* verilator lint_off UNUSEDSIGNAL */
function [14:0] sync_slot_word_addr;
    input [5:0] slot;
    reg [15:0] byte_addr;
    begin
        case (slot)
            6'd0, 6'd1, 6'd2, 6'd3, 6'd4, 6'd5, 6'd6, 6'd7,
            6'd8, 6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15,
            6'd16, 6'd17, 6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23,
            6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29, 6'd30, 6'd31:
                byte_addr = ETH_SHM_CTRL_REGS + {9'b000000000, slot[4:0], 2'b00};
            6'd32: byte_addr = ETH_SHM_CTRL_MAC + 16'h0000;
            6'd33: byte_addr = ETH_SHM_CTRL_MAC + 16'h0002;
            6'd34: byte_addr = ETH_SHM_CTRL_MAC + 16'h0004;
            6'd35: byte_addr = ETH_RTL8019_STATE + 16'h0000;
            6'd36: byte_addr = ETH_RTL8019_STATE + 16'h0002;
            6'd37: byte_addr = ETH_RTL8019_STATE + 16'h0004;
            6'd38: byte_addr = ETH_RTL8019_STATE + 16'h0006;
            6'd39: byte_addr = ETH_RTL8019_STATE + 16'h0008;
            6'd40: byte_addr = ETH_RTL8019_STATE + 16'h000A;
            default: byte_addr = ETH_SHM_CTRL_REGS;
        endcase
        sync_slot_word_addr = byte_addr[15:1];
    end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

function [15:0] sync_slot_wdata;
    input [5:0] slot;
    reg [7:0] state_page_byte;
    reg [7:0] state_enabled_byte;
    begin
        state_page_byte = {6'b000000, current_page};
        state_enabled_byte = cr_register[1] ? 8'h01 : 8'h00;
        case (slot)
            6'd0, 6'd1, 6'd2, 6'd3, 6'd4, 6'd5, 6'd6, 6'd7,
            6'd8, 6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15,
            6'd16, 6'd17, 6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23,
            6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29, 6'd30, 6'd31:
                sync_slot_wdata = {8'h00, shm_ctrl_reg_value(slot[4:0])};
            6'd32: sync_slot_wdata = {par_registers[1], par_registers[0]};
            6'd33: sync_slot_wdata = {par_registers[3], par_registers[2]};
            6'd34: sync_slot_wdata = {par_registers[5], par_registers[4]};
            6'd35: sync_slot_wdata = {par_registers[0], state_page_byte};
            6'd36: sync_slot_wdata = {par_registers[2], par_registers[1]};
            6'd37: sync_slot_wdata = {par_registers[4], par_registers[3]};
            6'd38: sync_slot_wdata = {8'h01, par_registers[5]};
            6'd39: sync_slot_wdata = {8'h00, state_enabled_byte};
            6'd40: sync_slot_wdata = 16'h0000;
            default: sync_slot_wdata = 16'h0000;
        endcase
    end
endfunction

wire [14:0] remote_dma_pmem_word_offset = ne_pmem_word_offset(remote_dma_addr);
wire [1:0]  tcr_loopback_mode = tcr_register[2:1];
wire        rcr_monitor_mode = rcr_register[5];
wire        dcr_word_mode = dcr_register[0];
wire        dcr_byte_swap = dcr_register[1];
wire        remote_dma_prom_region = (remote_dma_addr < 16'h0020);
wire        remote_dma_pmem_region = (remote_dma_addr >= NE_PMEM_START) && (remote_dma_addr < NE_PMEM_END);
wire        irq_pending = |(isr_register & imr_register);
wire [15:0] fpga_owned_flags =
    (tx_request_pending ? ETH_FLAG_TX_REQ : 16'h0000) |
    (irq_pending ? ETH_FLAG_IRQ : 16'h0000) |
    (cr_register[1] ? ETH_FLAG_ENABLED : 16'h0000);
wire        receiver_active = rx_poll_enabled && cr_register[1] && !rcr_monitor_mode;
localparam USE_DEBUG_ISSP = 1'b1;

// ISSP source bits:
//   [0] inhibit background Ethernet DMA/sync engine
//   [1] synchronous clear for debug counters and sticky flags
wire [1:0]  debug_source;
wire        debug_bg_disable = debug_source[0];
wire        debug_clear = debug_source[1];
wire [15:0] bg_flags_write_word =
    (bg_flags_word & (bg_clear_rx_avail ? 16'h0000 : ETH_HPS_FLAG_MASK)) |
    fpga_owned_flags;
wire        data_port_dma_complete_now = eth_dma_req && eth_dma_ready && !bg_dma_inflight;
wire        data_port_dma_timeout_now =
    eth_dma_req && !eth_dma_ready &&
    (eth_dma_wait_counter == ETH_DMA_TIMEOUT_CYCLES) &&
    (data_port_read_pending || data_port_write_pending ||
     (sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr)));
wire        local_remote_dma_active =
    ((cr_register[4:3] != 2'b00) && (remote_byte_count != 16'h0000)) ||
    data_port_read_pending || data_port_write_pending;
wire [15:0] bg_rx_length_from_dma = hps_u16_from_dma(eth_dma_rdata);
wire [4:0]  prom_byte_index = remote_dma_addr[4:0];
wire [4:0]  prom_word_index = {remote_dma_addr[4:1], 1'b0};
wire [15:0] prom_read_word = {prom_shadow[prom_word_index], prom_shadow[prom_word_index + 5'd1]};
wire [7:0]  prom_read_byte = prom_shadow[prom_byte_index];
wire [7:0]  bg_rx_page_start_calc =
    sanitize_ring_page(curr_register, pstart_register, pstop_register);
wire [15:0] bg_rx_dst_offset_calc = ring_page_byte_offset(bg_rx_page_start_calc);
wire [7:0]  bg_rx_page_count_calc = rx_page_count_for_length(bg_rx_length_from_dma);
wire [7:0]  bg_rx_next_page_calc =
    wrap_ring_page_add(bg_rx_page_start_calc, bg_rx_page_count_calc, pstart_register, pstop_register);
/* verilator lint_off UNUSEDSIGNAL */
wire [15:0] bg_rx_len_byte_addr = ETH_SHM_PACKET_INFO + 16'h0002;
wire [15:0] bg_hdr0_byte_addr = ETH_SHM_NE_MEMORY + bg_rx_dst_offset;
wire [15:0] bg_hdr1_byte_addr = ETH_SHM_NE_MEMORY + bg_rx_dst_offset + 16'h0002;
wire [15:0] bg_payload_src_byte_addr = ETH_SHM_RX_BUFFER + bg_rx_src_offset;
wire [15:0] bg_payload_dst_byte_addr =
    ETH_SHM_NE_MEMORY + bg_rx_dst_offset + 16'h0004 + bg_rx_src_offset;
/* verilator lint_on UNUSEDSIGNAL */
wire [14:0] bg_flags_word_addr = ETH_SHM_CTRL_FLAGS[15:1];
wire [14:0] bg_rx_len_word_addr = bg_rx_len_byte_addr[15:1];
wire [14:0] bg_hdr0_word_addr = bg_hdr0_byte_addr[15:1];
wire [14:0] bg_hdr1_word_addr = bg_hdr1_byte_addr[15:1];
wire [14:0] bg_payload_src_word_addr = bg_payload_src_byte_addr[15:1];
wire [14:0] bg_payload_dst_word_addr = bg_payload_dst_byte_addr[15:1];
wire        data_port_bus_active =
    sel_ethernet && !sel_ethernet_shm && is_data_port_access &&
    !cpu_as && (cpu_rd || cpu_wr);
wire        data_port_cycle_start = data_port_bus_active && !data_port_bus_active_prev;
wire        data_port_cycle_end = !data_port_bus_active && data_port_bus_active_prev;

// ISSP probe map:
// [127:112] remote_dma_addr
// [111:96]  remote_byte_count
// [95:80]   sticky flags
// [79:65]   eth_dma_addr
// [64:50]   cpu_addr
// [49:42]   CR
// [41:34]   ISR
// [33:26]   IMR
// [25:18]   CURR
// [17:13]   bg_state
// [12:0]    live flags
wire [15:0] debug_sticky_flags = {debug_dma_timeout_sticky, debug_sticky_flags_lo};

/* verilator lint_off UNUSEDSIGNAL */
wire [127:0] debug_probe = {
    remote_dma_addr,
    remote_byte_count,
    debug_sticky_flags,
    eth_dma_addr,
    cpu_addr,
    cr_register,
    isr_register,
    imr_register,
    curr_register,
    bg_state,
    cpu_rd,
    cpu_wr,
    sel_ethernet,
    sel_ethernet_shm,
    is_data_port_access,
    dtack_eth,
    eth_irq,
    eth_dma_req,
    eth_dma_ready,
    eth_dma_write,
    bg_dma_inflight,
    data_port_read_pending,
    data_port_write_pending
};
/* verilator lint_on UNUSEDSIGNAL */

generate
if (USE_DEBUG_ISSP) begin : gen_eth_debug_issp
    ethernet_issp #(
        .PROBE_WIDTH(128),
        .SOURCE_WIDTH(2),
        .INSTANCE_ID("ETHDBG")
    ) eth_debug_issp (
        .clk(clk),
        .probe(debug_probe),
        .source(debug_source)
    );
end else begin : gen_eth_debug_issp_tieoff
    assign debug_source = 2'b00;
end
endgenerate

always @(posedge clk) begin
    if (reset || debug_clear) begin
        debug_heartbeat <= 16'h0000;
        debug_local_wait_cycles <= 16'h0000;
        debug_dma_wait_cycles <= 16'h0000;
        debug_sticky_flags_lo <= 15'h0000;
    end else begin
        debug_heartbeat <= debug_heartbeat + 16'h0001;

        if (sel_ethernet && !sel_ethernet_shm && (cpu_rd || cpu_wr) && dtack_eth &&
            (debug_local_wait_cycles != 16'hFFFF)) begin
            debug_local_wait_cycles <= debug_local_wait_cycles + 16'h0001;
        end

        if (eth_dma_req && !eth_dma_ready && (debug_dma_wait_cycles != 16'hFFFF)) begin
            debug_dma_wait_cycles <= debug_dma_wait_cycles + 16'h0001;
        end

        if (sel_ethernet && !sel_ethernet_shm && (cpu_rd || cpu_wr) && dtack_eth) begin
            debug_sticky_flags_lo[0] <= 1'b1;
        end
        if (eth_dma_req && !eth_dma_ready) begin
            debug_sticky_flags_lo[1] <= 1'b1;
        end
        if (sel_ethernet && sel_ethernet_shm) begin
            debug_sticky_flags_lo[2] <= 1'b1;
        end
        if (sel_ethernet && cpu_wr && is_register_access) begin
            debug_sticky_flags_lo[3] <= 1'b1;
        end
        if (sel_ethernet && (cpu_rd || cpu_wr) && is_data_port_access) begin
            debug_sticky_flags_lo[4] <= 1'b1;
        end
        if (eth_dma_req && sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr)) begin
            debug_sticky_flags_lo[5] <= 1'b1;
        end
        if (bg_polling_rx_flags) begin
            debug_sticky_flags_lo[6] <= 1'b1;
        end
        if (shm_sync_enabled) begin
            debug_sticky_flags_lo[7] <= 1'b1;
        end
        if (tx_request_pending) begin
            debug_sticky_flags_lo[8] <= 1'b1;
        end
        if (eth_irq) begin
            debug_sticky_flags_lo[9] <= 1'b1;
        end
        if (isr_register[6]) begin
            debug_sticky_flags_lo[10] <= 1'b1;
        end
        if (isr_register[4]) begin
            debug_sticky_flags_lo[11] <= 1'b1;
        end
        if (isr_register[0]) begin
            debug_sticky_flags_lo[12] <= 1'b1;
        end
        if (isr_register[1]) begin
            debug_sticky_flags_lo[13] <= 1'b1;
        end
        if (debug_bg_disable) begin
            debug_sticky_flags_lo[14] <= 1'b1;
        end
    end
end

// Address decode
wire [4:0]  register_select;
always @(posedge clk) begin
    if (reset) begin
        apply_nic_reset();
        reset_port_latch <= 8'h00;
        debug_dma_timeout_sticky <= 1'b0;
        dtack_eth <= 1'b1;
    end else begin
        data_port_bus_active_prev <= data_port_bus_active;

        if (debug_clear) begin
            debug_dma_timeout_sticky <= 1'b0;
        end

        if (sel_ethernet && (cpu_rd || cpu_wr)) begin
            if (sel_ethernet_shm) begin
                dtack_eth <= 1'b1;
            end else if (is_data_port_access) begin
                dtack_eth <= (data_port_cycle_active && data_port_transfer_done) ? 1'b0 : 1'b1;
            end else begin
                dtack_eth <= 1'b0;
            end
        end else begin
            dtack_eth <= 1'b1;
        end

        if (data_port_cycle_start) begin
            data_port_cycle_active <= 1'b1;
            data_port_transfer_done <= 1'b0;
        end else if (data_port_cycle_end ||
                     (data_port_cycle_active &&
                      (!sel_ethernet || sel_ethernet_shm || !is_data_port_access))) begin
            data_port_cycle_active <= 1'b0;
            data_port_transfer_done <= 1'b0;
        end

        if (sel_ethernet && cpu_wr && is_reset_port_access && (!cpu_uds || !cpu_lds)) begin
            reset_port_latch <= cpu_write_byte;
        end else if (sel_ethernet && cpu_wr && is_register_access &&
                     (!cpu_uds || !cpu_lds)) begin
            case (register_select[4:0])
                5'h00: begin
                    cr_register <= cr_write_value;
                    if (cr_write_value[0]) begin
                        isr_register <= isr_register | ISR_RST;
                    end else begin
                        isr_register <= isr_register & ~ISR_RST;
                    end
                    if ((cr_write_value[4:3] != 2'b00) && (remote_byte_count == 16'h0000)) begin
                        isr_register <= (cr_write_value[0] ? (isr_register | ISR_RST)
                                                          : (isr_register & ~ISR_RST)) | ISR_RDC;
                    end
                    if (cr_write_value[2] &&
                        (tbcr_register != 16'h0000) &&
                        (tpsr_register >= pstart_register) &&
                        (tpsr_register < pstop_register)) begin
                        tx_complete_pending <= 1'b1;
                        tsr_register <= 8'h00;
                        tx_request_pending <= 1'b1;
                        shm_sync_enabled <= 1'b1;
                        bg_sync_slot <= 6'd0;
                    end
                end
                5'h01: begin
                    case (current_page)
                        2'b00: pstart_register <= cpu_write_byte;
                        2'b01: par_registers[0] <= cpu_write_byte;
                        2'b11: rtl8019_e9346cr <= {cpu_write_byte[7:1], rtl8019_e9346cr[0]};
                        default: begin
                        end
                    endcase
                end
                5'h02: begin
                    case (current_page)
                        2'b00: pstop_register <= cpu_write_byte;
                        2'b01: par_registers[1] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h03: begin
                    case (current_page)
                        2'b00: bnry_register <= cpu_write_byte;
                        2'b01: par_registers[2] <= cpu_write_byte;
                        2'b11: if (rtl8019_config_write_enable) begin
                            rtl8019_config0 <= {cpu_write_byte[7:6], rtl8019_config0[5:0]};
                        end
                        default: begin
                        end
                    endcase
                end
                5'h04: begin
                    case (current_page)
                        2'b00: tpsr_register <= cpu_write_byte;
                        2'b01: par_registers[3] <= cpu_write_byte;
                        2'b11: if (rtl8019_config_write_enable) begin
                            rtl8019_config1 <= {cpu_write_byte[7], rtl8019_config1[6:0]};
                        end
                        default: begin
                        end
                    endcase
                end
                5'h05: begin
                    case (current_page)
                        2'b00: tbcr_register[7:0] <= cpu_write_byte;
                        2'b01: par_registers[4] <= cpu_write_byte;
                        2'b11: if (rtl8019_config_write_enable) begin
                            rtl8019_config2 <= {cpu_write_byte[7:5], rtl8019_config2[4:0]};
                        end
                        default: begin
                        end
                    endcase
                end
                5'h06: begin
                    case (current_page)
                        2'b00: tbcr_register[15:8] <= cpu_write_byte;
                        2'b01: par_registers[5] <= cpu_write_byte;
                        2'b11: if (rtl8019_config_write_enable) begin
                            rtl8019_config3 <= {rtl8019_config3[7:3], cpu_write_byte[2:1], rtl8019_config3[0]};
                        end
                        default: begin
                        end
                    endcase
                end
                5'h07: begin
                    case (current_page)
                        2'b00: isr_register <= isr_register & ~cpu_write_byte;
                        2'b01: curr_register <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h08: begin
                    case (current_page)
                        2'b00: remote_dma_addr[7:0] <= cpu_write_byte;
                        2'b01: mar_registers[0] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h09: begin
                    case (current_page)
                        2'b00: remote_dma_addr[15:8] <= cpu_write_byte;
                        2'b01: mar_registers[1] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h0A: begin
                    case (current_page)
                        2'b00: remote_byte_count[7:0] <= cpu_write_byte;
                        2'b01: mar_registers[2] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h0B: begin
                    case (current_page)
                        2'b00: remote_byte_count[15:8] <= cpu_write_byte;
                        2'b01: mar_registers[3] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h0C: begin
                    case (current_page)
                        2'b00: begin
                            rcr_register <= cpu_write_byte;
                            rx_poll_enabled <= 1'b1;
                        end
                        2'b01: mar_registers[4] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h0D: begin
                    case (current_page)
                        2'b00: tcr_register <= cpu_write_byte;
                        2'b01: mar_registers[5] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h0E: begin
                    case (current_page)
                        2'b00: dcr_register <= {1'b1, cpu_write_byte[6:0]};
                        2'b01: mar_registers[6] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                5'h0F: begin
                    case (current_page)
                        2'b00: imr_register <= cpu_write_byte;
                        2'b01: mar_registers[7] <= cpu_write_byte;
                        default: begin
                        end
                    endcase
                end
                default: begin
                end
            endcase

            if (shm_sync_enabled || tx_request_pending) begin
                shm_sync_enabled <= 1'b1;
                bg_sync_slot <= 6'd0;
            end
        end

        if (sel_ethernet && cpu_rd && is_reset_port_access && !sel_ethernet_shm) begin
            apply_nic_reset();
        end

        if (tx_complete_pending) begin
            tx_complete_pending <= 1'b0;
            cr_register <= {cr_register[7:3], 1'b0, cr_register[1:0]};
            tsr_register <= TSR_PTX;
            if ((tcr_loopback_mode != 2'b00) && receiver_active) begin
                rsr_register <= RSR_PRX;
                bnry_register <= curr_register;
                if ((curr_register + 8'h01) >= pstop_register) begin
                    curr_register <= pstart_register;
                end else begin
                    curr_register <= curr_register + 8'h01;
                end
                isr_register <= isr_register | ISR_PTX | ISR_PRX;
            end else begin
                isr_register <= isr_register | ISR_PTX;
            end
            shm_sync_enabled <= 1'b1;
            bg_sync_slot <= 6'd0;
        end

        if (eth_dma_req && !eth_dma_ready) begin
            if (eth_dma_wait_counter != ETH_DMA_TIMEOUT_CYCLES) begin
                eth_dma_wait_counter <= eth_dma_wait_counter + 10'd1;
            end else begin
                eth_dma_wait_counter <= 10'd0;
                debug_dma_timeout_sticky <= 1'b1;

                if (data_port_read_pending || data_port_write_pending ||
                    (sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr))) begin
                    if (bg_dma_inflight) begin
                        bg_dma_inflight <= 1'b0;
                        bg_state <= BG_IDLE;
                        bg_polling_rx_flags <= 1'b0;
                        bg_clear_rx_avail <= 1'b0;
                        bg_poll_counter <= BG_POLL_RELOAD;
                    end
                    complete_data_port_transfer(16'hFFFF);
                end else if (bg_dma_inflight) begin
                    eth_dma_req <= 1'b0;
                    bg_dma_inflight <= 1'b0;
                    bg_state <= BG_IDLE;
                    bg_polling_rx_flags <= 1'b0;
                    bg_clear_rx_avail <= 1'b0;
                    bg_poll_counter <= BG_POLL_RELOAD;
                end else begin
                    eth_dma_req <= 1'b0;
                end
            end
        end else begin
            eth_dma_wait_counter <= 10'd0;
        end

        if (eth_dma_req && eth_dma_ready) begin
            if (bg_dma_inflight) begin
                bg_dma_inflight <= 1'b0;
                eth_dma_req <= 1'b0;

                case (bg_state)
                    BG_READ_FLAGS_WAIT: begin
                        bg_flags_word <= hps_u16_from_dma(eth_dma_rdata);
                        if (bg_polling_rx_flags &&
                            ((hps_u16_from_dma(eth_dma_rdata) & ETH_FLAG_RX_AVAIL) != 16'h0000)) begin
                            bg_state <= BG_READ_RX_LEN_REQ;
                        end else if (tx_request_pending &&
                                     ((mirrored_fpga_flags & ETH_FLAG_TX_REQ) != 16'h0000) &&
                                     ((hps_u16_from_dma(eth_dma_rdata) & ETH_FLAG_TX_REQ) == 16'h0000)) begin
                            tx_request_pending <= 1'b0;
                            mirrored_fpga_flags <= hps_u16_from_dma(eth_dma_rdata) & ETH_FPGA_FLAG_MASK;
                            bg_state <= BG_IDLE;
                            bg_poll_counter <= BG_POLL_RELOAD;
                        end else if ((hps_u16_from_dma(eth_dma_rdata) & ETH_FPGA_FLAG_MASK) != fpga_owned_flags) begin
                            bg_clear_rx_avail <= 1'b0;
                            bg_state <= BG_CLEAR_FLAG_REQ;
                        end else begin
                            mirrored_fpga_flags <= hps_u16_from_dma(eth_dma_rdata) & ETH_FPGA_FLAG_MASK;
                            bg_state <= BG_IDLE;
                            bg_poll_counter <= BG_POLL_RELOAD;
                        end
                    end

                    BG_READ_RX_LEN_WAIT: begin
                        bg_rx_total_length <= bg_rx_length_from_dma + 16'h0004;
                        bg_rx_src_offset <= 16'h0000;
                        bg_rx_bytes_remaining <= bg_rx_length_from_dma;
                        bg_rx_dst_offset <= bg_rx_dst_offset_calc;
                        bg_rx_next_page <= bg_rx_next_page_calc;
                        bg_clear_rx_avail <= 1'b1;

                        if (bg_rx_length_from_dma == 16'h0000) begin
                            bg_state <= BG_CLEAR_FLAG_REQ;
                        end else if (bg_rx_next_page_calc == bnry_register) begin
                            isr_register <= isr_register | ISR_OVW;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                            bg_state <= BG_CLEAR_FLAG_REQ;
                        end else begin
                            bg_state <= BG_WRITE_HDR0_REQ;
                        end
                    end

                    BG_WRITE_HDR0_WAIT: begin
                        bg_state <= BG_WRITE_HDR1_REQ;
                    end

                    BG_WRITE_HDR1_WAIT: begin
                        if (bg_rx_bytes_remaining != 16'h0000) begin
                            bg_state <= BG_READ_PAYLOAD_REQ;
                        end else begin
                            rsr_register <= RSR_PRX;
                            isr_register <= isr_register | ISR_PRX;
                            curr_register <= bg_rx_next_page;
                            bg_state <= BG_CLEAR_FLAG_REQ;
                        end
                    end

                    BG_READ_PAYLOAD_WAIT: begin
                        bg_source_word <= eth_dma_rdata;
                        bg_state <= BG_WRITE_PAYLOAD_REQ;
                    end

                    BG_WRITE_PAYLOAD_WAIT: begin
                        if (bg_rx_bytes_remaining > 16'h0002) begin
                            bg_rx_src_offset <= bg_rx_src_offset + 16'h0002;
                            bg_rx_bytes_remaining <= bg_rx_bytes_remaining - 16'h0002;
                            bg_state <= BG_READ_PAYLOAD_REQ;
                        end else begin
                            bg_rx_src_offset <= bg_rx_src_offset + bg_rx_bytes_remaining;
                            bg_rx_bytes_remaining <= 16'h0000;
                            rsr_register <= RSR_PRX;
                            isr_register <= isr_register | ISR_PRX;
                            curr_register <= bg_rx_next_page;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                            bg_state <= BG_CLEAR_FLAG_REQ;
                        end
                    end

                    BG_CLEAR_FLAG_WAIT: begin
                        mirrored_fpga_flags <= fpga_owned_flags;
                        bg_clear_rx_avail <= 1'b0;
                        bg_state <= BG_IDLE;
                        bg_poll_counter <= BG_POLL_RELOAD;
                    end

                    BG_SYNC_WORD_WAIT: begin
                        if (bg_sync_slot == 6'd40) begin
                            bg_sync_slot <= 6'd0;
                            shm_sync_enabled <= 1'b0;
                        end else begin
                            bg_sync_slot <= bg_sync_slot + 6'd1;
                        end
                        bg_state <= BG_IDLE;
                    end

                    default: begin
                        bg_state <= BG_IDLE;
                        bg_poll_counter <= BG_POLL_RELOAD;
                    end
                endcase
            end else begin
                complete_data_port_transfer(eth_dma_rdata);
            end
        end

        if (data_port_cycle_start && cpu_wr &&
            !data_port_transfer_done &&
            !data_port_dma_complete_now && !data_port_dma_timeout_now &&
            !data_port_write_pending && !data_port_read_pending && !eth_dma_req) begin
            if (~cpu_uds || ~cpu_lds) begin
                if (remote_dma_prom_region) begin
                    data_port_transfer_done <= 1'b1;
                    if (dcr_word_mode) begin
                        if (dcr_byte_swap) begin
                            if (!cpu_uds) prom_shadow[{remote_dma_addr[4:1], 1'b0}] <= cpu_data_in[7:0];
                            if (!cpu_lds) prom_shadow[{remote_dma_addr[4:1], 1'b1}] <= cpu_data_in[15:8];
                        end else begin
                            if (!cpu_uds) prom_shadow[{remote_dma_addr[4:1], 1'b0}] <= cpu_data_in[15:8];
                            if (!cpu_lds) prom_shadow[{remote_dma_addr[4:1], 1'b1}] <= cpu_data_in[7:0];
                        end
                    end else if (!remote_dma_addr[0]) begin
                        prom_shadow[remote_dma_addr[4:0]] <= cpu_write_byte;
                    end else begin
                        prom_shadow[remote_dma_addr[4:0]] <= cpu_write_byte;
                    end
                    data_port_word_mode <= dcr_word_mode;
                    data_port_byte_addr <= remote_dma_addr;
                    eth_dma_req <= 1'b0;
                    eth_dma_write <= 1'b0;
                    eth_dma_uds <= 1'b1;
                    eth_dma_lds <= 1'b1;
                    if (dcr_word_mode) begin
                        remote_dma_addr <= remote_dma_addr + 16'h0002;
                        if (remote_byte_count > 16'h0002) begin
                            remote_byte_count <= remote_byte_count - 16'h0002;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            if (shm_sync_enabled || tx_request_pending) begin
                                shm_sync_enabled <= 1'b1;
                                bg_sync_slot <= 6'd0;
                            end
                        end
                    end else begin
                        remote_dma_addr <= remote_dma_addr + 16'h0001;
                        if (remote_byte_count > 16'h0001) begin
                            remote_byte_count <= remote_byte_count - 16'h0001;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            if (shm_sync_enabled || tx_request_pending) begin
                                shm_sync_enabled <= 1'b1;
                                bg_sync_slot <= 6'd0;
                            end
                        end
                    end
                end else if (remote_dma_pmem_region) begin
                    data_port_write_pending <= 1'b1;
                    data_port_transfer_done <= 1'b0;
                    data_port_word_mode <= dcr_word_mode;
                    data_port_byte_addr <= remote_dma_addr;
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= ETH_SHM_NE_MEMORY[15:1] + remote_dma_pmem_word_offset;

                    if (dcr_word_mode) begin
                        eth_dma_wdata <= dcr_byte_swap ? {cpu_data_in[7:0], cpu_data_in[15:8]}
                                                       : cpu_data_in;
                        eth_dma_uds <= 1'b0;
                        eth_dma_lds <= 1'b0;
                    end else begin
                        eth_dma_wdata <= remote_dma_addr[0] ? {8'h00, (~cpu_uds ? cpu_data_in[15:8] : cpu_data_in[7:0])}
                                                           : {(~cpu_uds ? cpu_data_in[15:8] : cpu_data_in[7:0]), 8'h00};
                        eth_dma_uds <= remote_dma_addr[0] ? 1'b1 : 1'b0;
                        eth_dma_lds <= remote_dma_addr[0] ? 1'b0 : 1'b1;
                    end
                end else begin
                    data_port_transfer_done <= 1'b1;
                    data_port_word_mode <= dcr_word_mode;
                    data_port_byte_addr <= remote_dma_addr;
                    eth_dma_req <= 1'b0;
                    eth_dma_write <= 1'b0;
                    eth_dma_uds <= 1'b1;
                    eth_dma_lds <= 1'b1;
                    if (dcr_word_mode) begin
                        remote_dma_addr <= remote_dma_addr + 16'h0002;
                        if (remote_byte_count > 16'h0002) begin
                            remote_byte_count <= remote_byte_count - 16'h0002;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            if (shm_sync_enabled || tx_request_pending) begin
                                shm_sync_enabled <= 1'b1;
                                bg_sync_slot <= 6'd0;
                            end
                        end
                    end else begin
                        remote_dma_addr <= remote_dma_addr + 16'h0001;
                        if (remote_byte_count > 16'h0001) begin
                            remote_byte_count <= remote_byte_count - 16'h0001;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            if (shm_sync_enabled || tx_request_pending) begin
                                shm_sync_enabled <= 1'b1;
                                bg_sync_slot <= 6'd0;
                            end
                        end
                    end
                end
            end
        end else if (data_port_cycle_start && cpu_rd &&
                     !data_port_transfer_done &&
                     !data_port_dma_complete_now && !data_port_dma_timeout_now &&
                     !data_port_read_pending && !data_port_write_pending && !eth_dma_req) begin
            if (remote_dma_prom_region) begin
                data_port_transfer_done <= 1'b1;
                if (dcr_word_mode) begin
                    data_port_read_data <= maybe_swap_word(prom_read_word, dcr_byte_swap);
                    remote_dma_addr <= remote_dma_addr + 16'h0002;
                    if (remote_byte_count > 16'h0002) begin
                        remote_byte_count <= remote_byte_count - 16'h0002;
                    end else begin
                        remote_byte_count <= 16'h0000;
                        isr_register <= isr_register | ISR_RDC;
                    end
                end else begin
                    data_port_read_data <= {prom_read_byte, prom_read_byte};
                    remote_dma_addr <= remote_dma_addr + 16'h0001;
                    if (remote_byte_count > 16'h0001) begin
                        remote_byte_count <= remote_byte_count - 16'h0001;
                    end else begin
                        remote_byte_count <= 16'h0000;
                        isr_register <= isr_register | ISR_RDC;
                    end
                end
            end else if (remote_dma_pmem_region) begin
                data_port_read_pending <= 1'b1;
                data_port_transfer_done <= 1'b0;
                data_port_word_mode <= dcr_word_mode;
                data_port_byte_addr <= remote_dma_addr;
                eth_dma_req <= 1'b1;
                eth_dma_write <= 1'b0;
                eth_dma_addr <= ETH_SHM_NE_MEMORY[15:1] + remote_dma_pmem_word_offset;
                eth_dma_wdata <= 16'h0000;
                eth_dma_uds <= remote_dma_addr[0] ? 1'b1 : 1'b0;
                eth_dma_lds <= remote_dma_addr[0] ? 1'b0 : 1'b1;
            end else begin
                data_port_transfer_done <= 1'b1;
                if (dcr_word_mode) begin
                    data_port_read_data <= 16'hFFFF;
                    remote_dma_addr <= remote_dma_addr + 16'h0002;
                    if (remote_byte_count > 16'h0002) begin
                        remote_byte_count <= remote_byte_count - 16'h0002;
                    end else begin
                        remote_byte_count <= 16'h0000;
                        isr_register <= isr_register | ISR_RDC;
                    end
                end else begin
                    data_port_read_data <= 16'hFFFF;
                    remote_dma_addr <= remote_dma_addr + 16'h0001;
                    if (remote_byte_count > 16'h0001) begin
                        remote_byte_count <= remote_byte_count - 16'h0001;
                    end else begin
                        remote_byte_count <= 16'h0000;
                        isr_register <= isr_register | ISR_RDC;
                    end
                end
            end
        end

        // Keep data-port pending state alive until the DMA side completes or
        // times out. Real bus strobes can drop before the async memory path
        // answers, and clearing these flags early loses RDC completion.

        if (bg_state == BG_IDLE) begin
            if (!debug_bg_disable && receiver_active && (bg_poll_counter != 8'h00)) begin
                bg_poll_counter <= bg_poll_counter - 8'h01;
            end
            if (!debug_bg_disable &&
                !eth_dma_req &&
                !local_remote_dma_active &&
                !(sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr))) begin
                if (((shm_sync_enabled || tx_request_pending) &&
                     (mirrored_fpga_flags != fpga_owned_flags)) ||
                    (tx_request_pending &&
                     ((mirrored_fpga_flags & ETH_FLAG_TX_REQ) != 16'h0000)) ||
                    (receiver_active && (bg_poll_counter == 8'h00))) begin
                    bg_polling_rx_flags <= receiver_active && (bg_poll_counter == 8'h00);
                    bg_clear_rx_avail <= 1'b0;
                    bg_state <= BG_READ_FLAGS_REQ;
                end else if (shm_sync_enabled) begin
                    bg_state <= BG_SYNC_WORD_REQ;
                end
            end
        end else if (debug_bg_disable && !eth_dma_req && !bg_dma_inflight &&
                     !local_remote_dma_active &&
                     !(sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr))) begin
            bg_state <= BG_IDLE;
            bg_polling_rx_flags <= 1'b0;
            bg_clear_rx_avail <= 1'b0;
            bg_poll_counter <= BG_POLL_RELOAD;
        end else if (!eth_dma_req && !bg_dma_inflight &&
                     !local_remote_dma_active &&
                     !(sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr))) begin
            case (bg_state)
                BG_READ_FLAGS_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_flags_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_FLAGS_WAIT;
                end

                BG_READ_RX_LEN_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_rx_len_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_RX_LEN_WAIT;
                end

                BG_WRITE_HDR0_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_hdr0_word_addr;
                    eth_dma_wdata <= {RSR_PRX, bg_rx_next_page};
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_HDR0_WAIT;
                end

                BG_WRITE_HDR1_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_hdr1_word_addr;
                    eth_dma_wdata <= {bg_rx_total_length[7:0], bg_rx_total_length[15:8]};
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_HDR1_WAIT;
                end

                BG_READ_PAYLOAD_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_payload_src_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_PAYLOAD_WAIT;
                end

                BG_WRITE_PAYLOAD_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_payload_dst_word_addr;
                    if (bg_rx_bytes_remaining > 16'h0001) begin
                        eth_dma_wdata <= bg_source_word;
                        eth_dma_uds <= 1'b0;
                        eth_dma_lds <= 1'b0;
                    end else begin
                        eth_dma_wdata <= {bg_source_word[15:8], 8'h00};
                        eth_dma_uds <= 1'b0;
                        eth_dma_lds <= 1'b1;
                    end
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_PAYLOAD_WAIT;
                end

                BG_CLEAR_FLAG_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_flags_word_addr;
                    eth_dma_wdata <= {bg_flags_write_word[7:0], bg_flags_write_word[15:8]};
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_CLEAR_FLAG_WAIT;
                end

                BG_SYNC_WORD_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= sync_slot_word_addr(bg_sync_slot);
                    eth_dma_wdata <= sync_slot_wdata(bg_sync_slot);
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_SYNC_WORD_WAIT;
                end

                default: begin
                    bg_state <= BG_IDLE;
                    bg_poll_counter <= BG_POLL_RELOAD;
                end
            endcase
        end

        eth_irq <= |(isr_register & imr_register);
    end
end

// Address decode logic for the local 64KB ethernet aperture.
wire [15:0] effective_addr;
wire [15:0] byte_addr;

assign effective_addr = {1'b0, cpu_addr};
assign byte_addr = effective_addr << 1;  // Convert to byte address


// The RTL8019 data and reset ports alias over full register blocks.
// Longword monitor reads can hit the second word within those blocks, so
// decode the entire windows instead of only the first entry.
assign is_data_port_access = (byte_addr >= 16'h0C40) && (byte_addr <= 16'h0C5F);
assign is_reset_port_access = (byte_addr >= 16'h0C60) && (byte_addr <= 16'h0C7F);

// Register access detection: Only 0xEA1C00-0xEA1C3F range (byte addresses)
// Removed 0xEA1600 range for simplification
assign is_register_access = ((byte_addr >= 16'h0C00) && (byte_addr <= 16'h0C3F));

// Convert word offset to register number for 0xC00 range only
reg [4:0] reg_index_0c00;

always @(*) begin
    reg_index_0c00 = byte_addr[6:2];
end

assign register_select = is_data_port_access ? 5'd16 :                // Data port
                         (is_register_access || is_reset_port_access) ? reg_index_0c00 :  // Register/reset index
                         5'd31;  // Invalid

// Output logic - immediate response with full register set support
always @(*) begin
    // Default outputs
    cpu_data_out = 16'h0000;

    // Handle ethernet register and data port access - ONLY if handled locally by FPGA
    if (sel_ethernet && cpu_rd && !sel_ethernet_shm) begin
        if (is_data_port_access) begin
            cpu_data_out = data_port_read_data;
        end
        else if (is_register_access || is_reset_port_access) begin
            // Register reads - always handle register reads regardless of address translation
                // Return register data - each register gets individual 4-byte space
                // Register values in MSB (high byte) for Amiga bus compatibility
                case (register_select[4:0])
                    // Register 0x00: CR - Command Register
                    5'h00: begin
                        cpu_data_out = format_reg_read_data(cr_register, cpu_uds, cpu_lds);
                    end

                    // Register 0x01: CLDA0/PAR0 - Current Local DMA Address 0 or Physical Address Register 0
                    5'h01: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(par_registers[0], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(pstart_register, cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(rtl8019_e9346cr, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x02: CLDA1/PAR1 - Current Local DMA Address 1 or Physical Address Register 1
                    5'h02: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(par_registers[1], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(pstop_register, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x03: BNRY/PAR2 - Boundary Pointer or Physical Address Register 2
                    5'h03: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(bnry_register, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(par_registers[2], cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(rtl8019_config0, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(bnry_register, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x04: TSR/PAR3 - Transmit Status Register or Physical Address Register 3
                    5'h04: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(tsr_register, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(par_registers[3], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(tpsr_register, cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(rtl8019_config1, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(tsr_register, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x05: NCR/PAR4 - Number of Collisions Register or Physical Address Register 4
                    5'h05: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(par_registers[4], cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(rtl8019_config2, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x06: FIFO/PAR5 - FIFO Register or Physical Address Register 5
                    5'h06: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(par_registers[5], cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(rtl8019_config3, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x07: ISR/CURR - Interrupt Status Register or Current Page Register
                    5'h07: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(isr_register, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(curr_register, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(isr_register, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x08: CRDA0/MAR0 - Current Remote DMA Address 0 or Multicast Address Register 0
                    5'h08: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(remote_dma_addr[7:0], cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[0], cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(remote_dma_addr[7:0], cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x09: CRDA1/MAR1 - Current Remote DMA Address 1 or Multicast Address Register 1
                    5'h09: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(remote_dma_addr[15:8], cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[1], cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(remote_dma_addr[15:8], cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x0A: 8019ID0/MAR2 - RTL8019AS ID0 or Multicast Address Register 2
                    5'h0A: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h50, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[2], cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(8'h50, cpu_uds, cpu_lds);
                            default: cpu_data_out = 16'h0000;
                        endcase
                    end

                    // Register 0x0B: 8019ID1/MAR3 - RTL8019AS ID1 or Multicast Address Register 3
                    5'h0B: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h70, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[3], cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(8'h70, cpu_uds, cpu_lds);
                            default: cpu_data_out = 16'h0000;
                        endcase
                    end

                    // Register 0x0C: RSR/MAR4 - Receive Status Register or Multicast Address Register 4
                    5'h0C: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(rsr_register, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[4], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(rcr_register, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(rsr_register, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x0D: CNTR0/MAR5 - Tally Counter 0 or Multicast Address Register 5
                    5'h0D: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[5], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(tcr_register, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x0E: CNTR1/MAR6 - Tally Counter 1 or Multicast Address Register 6
                    5'h0E: begin
                        case (current_page)
                            2'b00: cpu_data_out = 16'h0000;
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[6], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(dcr_register, cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(8'h50, cpu_uds, cpu_lds);
                            default: cpu_data_out = 16'h0000;
                        endcase
                    end

                    // Register 0x0F: IMR/MAR7 - Interrupt Mask Register or Multicast Address Register 7
                    5'h0F: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[7], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(imr_register, cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(8'h70, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(8'h00, cpu_uds, cpu_lds);
                        endcase
                    end
                    5'h1F: begin
                        cpu_data_out = format_reg_read_data(reset_port_latch, cpu_uds, cpu_lds);
                    end

                    default: cpu_data_out = 16'h0000;  // Invalid register
                endcase
            end
        end
end

endmodule
/* verilator lint_on DECLFILENAME */

/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module ethernet_issp
#(
    parameter PROBE_WIDTH = 128,
    parameter SOURCE_WIDTH = 2,
    parameter INSTANCE_ID = "ETHDBG"
)
(
    input  wire                    clk,
    input  wire [PROBE_WIDTH-1:0]  probe,
    output wire [SOURCE_WIDTH-1:0] source
);

`ifdef ALTERA_RESERVED_QIS
    altsource_probe altsource_probe_component (
        .probe(probe),
        .source(source),
        .source_clk(clk),
        .source_ena(1'b1)
        // synopsys translate_off
        ,
        .clr(),
        .ena(),
        .ir_in(),
        .ir_out(),
        .jtag_state_cdr(),
        .jtag_state_cir(),
        .jtag_state_e1dr(),
        .jtag_state_sdr(),
        .jtag_state_tlr(),
        .jtag_state_udr(),
        .jtag_state_uir(),
        .raw_tck(),
        .tdi(),
        .tdo(),
        .usr1()
        // synopsys translate_on
    );
    defparam
        altsource_probe_component.enable_metastability = "NO",
        altsource_probe_component.instance_id = INSTANCE_ID,
        altsource_probe_component.probe_width = PROBE_WIDTH,
        altsource_probe_component.sld_auto_instance_index = "YES",
        altsource_probe_component.source_initial_value = "0",
        altsource_probe_component.source_width = SOURCE_WIDTH;
`elsif SYNTHESIS
    altsource_probe altsource_probe_component (
        .probe(probe),
        .source(source),
        .source_clk(clk),
        .source_ena(1'b1)
        // synopsys translate_off
        ,
        .clr(),
        .ena(),
        .ir_in(),
        .ir_out(),
        .jtag_state_cdr(),
        .jtag_state_cir(),
        .jtag_state_e1dr(),
        .jtag_state_sdr(),
        .jtag_state_tlr(),
        .jtag_state_udr(),
        .jtag_state_uir(),
        .raw_tck(),
        .tdi(),
        .tdo(),
        .usr1()
        // synopsys translate_on
    );
    defparam
        altsource_probe_component.enable_metastability = "NO",
        altsource_probe_component.instance_id = INSTANCE_ID,
        altsource_probe_component.probe_width = PROBE_WIDTH,
        altsource_probe_component.sld_auto_instance_index = "YES",
        altsource_probe_component.source_initial_value = "0",
        altsource_probe_component.source_width = SOURCE_WIDTH;
`else
    assign source = {SOURCE_WIDTH{1'b0}};
`endif

endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
