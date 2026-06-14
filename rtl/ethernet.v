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
    
    // Data acknowledge for local RTL8019 register/data-port accesses
    output reg         dtack_eth
);

//   Ethernet Controller Memory Map
// #define ETH_SHMEM_ADDR   0x28EA0000 // HPS physical address for the FPGA/HPS mailbox

//   Base Address: 0xEA0000 (configurable via autoconfig)

//   Register Space (0xEA0000 - 0xEA0FFF) - local Amiga CPU I/O aperture

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
//   - 0xEA0C60-0xEA0C78: Debug snapshot registers
//     - 0xEA0C60: Remote DMA address low
//     - 0xEA0C64: Remote DMA address high
//     - 0xEA0C68: Remote byte count low
//     - 0xEA0C6C: Remote byte count high
//     - 0xEA0C70: DMA/data-port status bits
//     - 0xEA0C74: HPS communication status word
//     - 0xEA0C78: Last sampled HPS heartbeat low word
//   - 0xEA0C7C: Reset Port

//   FPGA/HPS Mailbox Space (0xEA1000 - 0xEAFFFF)
//
//   This is not exposed as an Amiga CPU memory target. cpu_wrapper exports
//   sel_ethernet_shm only as a marker for the top-level DTACK mux and for
//   diagnostics. The live transport below is accessed by HPS at 0x28EA0000
//   and by this module through the private eth_dma_* master path.

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
//     - +0x0000: TX packet length (HPS debug/bridge)
//     - +0x0002: staged RX packet length
//     - +0x0004: staged RX status byte (NE2000 RSR-compatible)

//   Legacy NE2000 Memory Mirror (0xEA3000 - 0xEA6FFF)

//   - 0xEA3000: ETH_SHM_NE_MEMORY (16KB) - legacy/debug mirror region.
//     The authoritative RTL8019 packet RAM now lives locally in this module.
//     - Remote DMA addresses below 0x0020 are handled locally as PROM/shadow RAM.
//     - Remote DMA addresses 0x4000-0x7FFF are handled locally through packet_ram[].
//     - Remote DMA addresses 0x0020-0x3FFF and 0x8000+ are unmapped and read as 0xFF.

//   Reserved / Debug / Future Use (0xEA7000 - 0xEAFFFF)

//   - 0xEAB000: ETH_SHM_DEBUG_INFO (4KB) - Debug information
//   - 0xEAC000: ETH_SHM_FUTURE_USE (16KB) - Reserved for expansion

//   Access Methods

//   1. Register I/O (0xEA0000-0xEA0FFF):
//     - Direct CPU read/write to NE2000 registers
//     - Data port access for packet data via Remote DMA
//   2. FPGA/HPS mailbox (0xEA1000-0xEAFFFF logical offsets):
//     - Used by HPS for packet data transfer and status updates
//     - Used by this module through eth_dma_* background transfers
//     - Amiga CPU accesses are deliberately not routed into this DDR window

//   Address Decoding Logic

//   sel_ethernet selects the full configured 64KB card aperture. Only
//   0xEA0C00-0xEA0C7F has RTL8019 behavior; unused and mailbox offsets are
//   acknowledged as harmless dummy cycles so CPU probes cannot hang the bus.
//   sel_ethernet_shm marks 0xEA1000-0xEAFFFF for diagnostics and HPS/FPGA
//   mailbox separation.
//   
//   This keeps the RTL8019 CPU-visible device small while still retaining the
//   64KB HPS transport ABI.

parameter [15:0] ETH_SHM_CTRL_FLAGS  = 16'h1000;
parameter [15:0] ETH_SHM_CTRL_REGS   = 16'h1004;
parameter [15:0] ETH_SHM_CTRL_MAC    = 16'h104C;
parameter [15:0] ETH_SHM_CTRL_STATUS = 16'h1052;
parameter [15:0] ETH_SHM_HPS_HEARTBEAT = 16'h1088;
parameter [15:0] ETH_SHM_HPS_SIGNATURE = 16'h108C;
parameter [15:0] ETH_RTL8019_STATE   = 16'h1100;
parameter [15:0] ETH_PACKET_BUFFER_SIZE = 16'h0600;
parameter [15:0] ETH_SHM_TX_BUFFER   = 16'h2000;
parameter [15:0] ETH_SHM_RX_BUFFER   = 16'h2600;
parameter [15:0] ETH_SHM_PACKET_INFO = 16'h2C00;
parameter [15:0] ETH_SHM_TX_REQUEST_ADDR = 16'h2C00;
parameter [15:0] ETH_SHM_TX_REQUEST_LEN  = 16'h2C02;
parameter [15:0] ETH_SHM_RX_QUEUE_HEAD   = 16'h2C04;
parameter [15:0] ETH_SHM_RX_QUEUE_TAIL   = 16'h2C06;
parameter [15:0] ETH_SHM_TX_REQUEST_SEQ  = 16'h2C08;
parameter [15:0] ETH_SHM_TX_COMPLETE_SEQ = 16'h2C0A;
parameter [15:0] ETH_SHM_RX_QUEUE_LEN    = 16'h2C20;
parameter [15:0] ETH_SHM_RX_QUEUE_DATA   = 16'h9000;
parameter [15:0] ETH_RX_QUEUE_SLOTS      = 16'h0004;
parameter [15:0] ETH_FLAG_TX_REQ     = 16'h0002;
parameter [15:0] ETH_FLAG_RX_AVAIL   = 16'h0004;
parameter [15:0] ETH_FLAG_IRQ        = 16'h0008;
parameter [15:0] ETH_FLAG_ENABLED    = 16'h0020;
parameter [15:0] ETH_STATUS_FPGA_SAMPLED    = 16'h0100;
parameter [15:0] ETH_STATUS_FPGA_SIGNATURE  = 16'h0200;
parameter [15:0] ETH_STATUS_FPGA_HEARTBEAT  = 16'h0400;
parameter [15:0] ETH_STATUS_FPGA_HB_CHANGED = 16'h0800;
parameter [15:0] ETH_STATUS_FPGA_COMM_OK    = 16'h1000;
parameter [15:0] ETH_STATUS_FPGA_RX_ACTIVE  = 16'h2000;
parameter [15:0] ETH_STATUS_FPGA_TX_PENDING = 16'h4000;
parameter [15:0] NE_PMEM_START       = 16'h4000;
parameter [15:0] NE_PMEM_END         = 16'h8000;
parameter [7:0]  NE_PAGE_BASE = 8'h40;
parameter [7:0]  DEFAULT_TX_PAGE = 8'h40;
parameter [7:0]  DEFAULT_RX_START_PAGE = 8'h46;
parameter [7:0]  DEFAULT_RX_STOP_PAGE = 8'h80;
parameter [7:0]  BG_POLL_RELOAD = 8'd63;
parameter [9:0]  ETH_DMA_TIMEOUT_CYCLES = 10'd511;
parameter [9:0]  DATA_PORT_TIMEOUT_CYCLES = 10'd511;
parameter [7:0]  DEFAULT_MAC0 = 8'h52;
parameter [7:0]  DEFAULT_MAC1 = 8'h54;
parameter [7:0]  DEFAULT_MAC2 = 8'h05;
parameter [7:0]  DEFAULT_MAC3 = 8'h04;
parameter [7:0]  DEFAULT_MAC4 = 8'h03;
parameter [7:0]  DEFAULT_MAC5 = 8'h02;
parameter [7:0]  HPS_POLL_RELOAD = 8'hFF;
localparam [15:0] ETH_SHM_HPS_HEARTBEAT_HI = ETH_SHM_HPS_HEARTBEAT + 16'h0002;
localparam [15:0] ETH_SHM_HPS_SIGNATURE_HI = ETH_SHM_HPS_SIGNATURE + 16'h0002;
localparam [15:0] ETH_RX_QUEUE_INDEX_MASK = ETH_RX_QUEUE_SLOTS - 16'h0001;

reg [7:0]  cr_register;
wire [1:0] current_page = cr_register[7:6];

wire       cpu_wr = cpu_lwr | cpu_hwr;
wire [7:0] cpu_write_byte = ~cpu_uds ? cpu_data_in[15:8] : cpu_data_in[7:0];
wire       is_data_port_access;
wire       is_register_access;
wire       is_debug_port_access;
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
reg [7:0]  cntr0_register;
reg [7:0]  cntr1_register;
reg [7:0]  cntr2_register;
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
reg [15:0] tx_stage_addr;
reg [15:0] tx_stage_len;
reg [15:0] tx_request_seq;
reg [15:0] mirrored_fpga_flags;
reg [7:0]  par_registers [0:5];
reg [7:0]  mar_registers [0:7];
reg [7:0]  reset_port_latch;
reg [5:0]  bg_state;
reg [7:0]  bg_poll_counter;
reg [7:0]  hps_poll_counter;
reg        bg_dma_inflight;
reg [15:0] bg_flags_word;
reg [15:0] bg_rx_queue_head;
reg [15:0] bg_rx_queue_tail;
reg [15:0] bg_rx_queue_next_head;
reg [15:0] bg_rx_total_length;
reg [15:0] bg_rx_src_offset;
reg [15:0] bg_rx_dst_offset;
reg [15:0] bg_rx_bytes_remaining;
reg [7:0]  bg_rx_next_page;
reg [7:0]  bg_rx_status;
reg [15:0] bg_source_word;
reg [5:0]  bg_sync_slot;
reg        bg_polling_rx_flags;
reg        bg_clear_rx_avail;
reg [7:0]  prom_shadow [0:31];
reg [12:0] pmem_addr;
reg [15:0] pmem_wdata;
reg [1:0]  pmem_byteena;
reg        pmem_wren;
wire [15:0] pmem_q;
// FPGA debug disabled to reduce Quartus build time.
// reg [15:0] debug_heartbeat;
// reg [15:0] debug_local_wait_cycles;
// reg [15:0] debug_dma_wait_cycles;
// reg [14:0] debug_sticky_flags_lo;
reg        debug_dma_timeout_sticky;
reg [9:0]  eth_dma_wait_counter;
reg [9:0]  data_port_wait_counter;
reg        tx_stage_pending;
reg [15:0] bg_tx_src_offset;
reg [15:0] bg_tx_bytes_remaining;
reg        local_pmem_read_wait;
reg [15:0] bg_hps_heartbeat_lo;
reg [15:0] bg_hps_signature_lo;
reg [31:0] hps_heartbeat_seen;
reg [31:0] hps_signature_seen;
reg        hps_status_sampled;
reg        hps_heartbeat_change_seen;
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
parameter RSR_MPA = 8'h10;     // Bit 4: Missed packet
parameter RSR_PHY = 8'h20;     // Bit 5: Physical/multicast address match

localparam [5:0] BG_IDLE                = 6'd0;
localparam [5:0] BG_READ_FLAGS_REQ      = 6'd1;
localparam [5:0] BG_READ_FLAGS_WAIT     = 6'd2;
localparam [5:0] BG_READ_RX_LEN_REQ     = 6'd3;
localparam [5:0] BG_READ_RX_LEN_WAIT    = 6'd4;
localparam [5:0] BG_WRITE_HDR0_REQ      = 6'd7;
localparam [5:0] BG_WRITE_HDR1_REQ      = 6'd9;
localparam [5:0] BG_READ_PAYLOAD_REQ    = 6'd11;
localparam [5:0] BG_READ_PAYLOAD_WAIT   = 6'd12;
localparam [5:0] BG_WRITE_PAYLOAD_REQ   = 6'd13;
localparam [5:0] BG_CLEAR_FLAG_REQ      = 6'd15;
localparam [5:0] BG_CLEAR_FLAG_WAIT     = 6'd16;
localparam [5:0] BG_SYNC_WORD_REQ       = 6'd17;
localparam [5:0] BG_SYNC_WORD_WAIT      = 6'd18;
localparam [5:0] BG_WRITE_TX_LEN_REQ    = 6'd19;
localparam [5:0] BG_WRITE_TX_LEN_WAIT   = 6'd20;
localparam [5:0] BG_WRITE_TX_BUF_REQ    = 6'd21;
localparam [5:0] BG_WRITE_TX_BUF_WAIT   = 6'd22;
localparam [5:0] BG_READ_HPS_HB_LO_REQ  = 6'd23;
localparam [5:0] BG_READ_HPS_HB_LO_WAIT = 6'd24;
localparam [5:0] BG_READ_HPS_HB_HI_REQ  = 6'd25;
localparam [5:0] BG_READ_HPS_HB_HI_WAIT = 6'd26;
localparam [5:0] BG_READ_HPS_SIG_LO_REQ = 6'd27;
localparam [5:0] BG_READ_HPS_SIG_LO_WAIT= 6'd28;
localparam [5:0] BG_READ_HPS_SIG_HI_REQ = 6'd29;
localparam [5:0] BG_READ_HPS_SIG_HI_WAIT= 6'd30;
localparam [5:0] BG_WRITE_STATUS_REQ    = 6'd31;
localparam [5:0] BG_WRITE_STATUS_WAIT   = 6'd32;
localparam [5:0] BG_READ_TX_BUF_REQ     = 6'd33;
localparam [5:0] BG_READ_TX_BUF_WAIT1   = 6'd34;
localparam [5:0] BG_READ_TX_BUF_WAIT2   = 6'd35;
localparam [5:0] BG_WRITE_TX_ADDR_REQ   = 6'd36;
localparam [5:0] BG_WRITE_TX_ADDR_WAIT  = 6'd37;
localparam [5:0] BG_WRITE_TX_SEQ_REQ    = 6'd38;
localparam [5:0] BG_WRITE_TX_SEQ_WAIT   = 6'd39;
localparam [5:0] BG_READ_TX_DONE_REQ    = 6'd40;
localparam [5:0] BG_READ_TX_DONE_WAIT   = 6'd41;
localparam [5:0] BG_READ_RX_HEAD_REQ    = 6'd42;
localparam [5:0] BG_READ_RX_HEAD_WAIT   = 6'd43;
localparam [5:0] BG_READ_RX_TAIL_REQ    = 6'd44;
localparam [5:0] BG_READ_RX_TAIL_WAIT   = 6'd45;
localparam [5:0] BG_WRITE_RX_HEAD_REQ   = 6'd46;
localparam [5:0] BG_WRITE_RX_HEAD_WAIT  = 6'd47;

wire [7:0] cr_write_value = cpu_write_byte;
wire       rtl8019_config_write_enable = (rtl8019_e9346cr[7:6] == 2'b11);
wire [2:0] cr_remote_dma_cmd = cr_register[5:3];
wire [2:0] cr_write_remote_dma_cmd = cr_write_value[5:3];
wire       cr_remote_dma_read = (cr_remote_dma_cmd == 3'b001);
wire       cr_remote_dma_write = (cr_remote_dma_cmd == 3'b010);
wire       cr_write_remote_dma_read = (cr_write_remote_dma_cmd == 3'b001);
wire       cr_write_remote_dma_write = (cr_write_remote_dma_cmd == 3'b010);
wire       cr_write_remote_dma_abort = (cr_write_remote_dma_cmd == 3'b100);

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
        local_pmem_read_wait <= 1'b0;
        data_port_byte_addr <= 16'h0000;
        data_port_word_mode <= 1'b0;
        tx_complete_pending <= 1'b0;
        isr_register <= ISR_RST;
        imr_register <= 8'h00;
        dcr_register <= 8'h80;
        pstart_register <= DEFAULT_RX_START_PAGE;
        pstop_register <= DEFAULT_RX_STOP_PAGE;
        bnry_register <= DEFAULT_RX_START_PAGE;
        tpsr_register <= DEFAULT_TX_PAGE;
        tbcr_register <= 16'h0000;
        tsr_register <= 8'h00;
        rsr_register <= 8'h00;
        cntr0_register <= 8'h00;
        cntr1_register <= 8'h00;
        cntr2_register <= 8'h00;
        curr_register <= DEFAULT_RX_START_PAGE + 8'h01;
        tcr_register <= 8'h00;
        rcr_register <= 8'h00;
        rtl8019_config0 <= 8'h00;
        rtl8019_config1 <= 8'h80;
        rtl8019_config2 <= 8'h40;
        rtl8019_config3 <= 8'h40;
        rtl8019_e9346cr <= 8'h00;
        rx_poll_enabled <= 1'b0;
        shm_sync_enabled <= 1'b1;
        tx_request_pending <= 1'b0;
        tx_stage_addr <= {DEFAULT_TX_PAGE, 8'h00};
        tx_stage_len <= 16'h0000;
        tx_request_seq <= 16'h0000;
        mirrored_fpga_flags <= 16'h0000;
        bg_state <= BG_IDLE;
        bg_poll_counter <= 8'h00;
        hps_poll_counter <= 8'h00;
        bg_dma_inflight <= 1'b0;
        bg_flags_word <= 16'h0000;
        bg_rx_queue_head <= 16'h0000;
        bg_rx_queue_tail <= 16'h0000;
        bg_rx_queue_next_head <= 16'h0000;
        bg_rx_total_length <= 16'h0000;
        bg_rx_src_offset <= 16'h0000;
        bg_rx_dst_offset <= 16'h0000;
        bg_rx_bytes_remaining <= 16'h0000;
        bg_rx_next_page <= 8'h00;
        bg_rx_status <= 8'h00;
        bg_source_word <= 16'h0000;
        bg_sync_slot <= 6'd0;
        bg_polling_rx_flags <= 1'b0;
        bg_clear_rx_avail <= 1'b0;
        tx_stage_pending <= 1'b0;
        bg_tx_src_offset <= 16'h0000;
        bg_tx_bytes_remaining <= 16'h0000;
        bg_hps_heartbeat_lo <= 16'h0000;
        bg_hps_signature_lo <= 16'h0000;
        hps_heartbeat_seen <= 32'h00000000;
        hps_signature_seen <= 32'h00000000;
        hps_status_sampled <= 1'b0;
        hps_heartbeat_change_seen <= 1'b0;
        eth_dma_req <= 1'b0;
        eth_dma_write <= 1'b0;
        eth_dma_addr <= 15'h0000;
        eth_dma_wdata <= 16'h0000;
        eth_dma_uds <= 1'b1;
        eth_dma_lds <= 1'b1;
        eth_irq <= 1'b0;
        eth_dma_wait_counter <= 10'd0;
        data_port_wait_counter <= 10'd0;
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

        // Capture the read result for data-port READ completions. This used to
        // gate on !eth_dma_write back when the data port itself drove eth_dma,
        // but eth_dma_write now belongs to the background FSM and is frequently
        // left high after a bg mailbox write. Gating on it caused data-port
        // reads that completed while the bg was active to skip capturing pmem_q,
        // returning stale 0x0000 (xsurftest "Testing 16bit memory" read back all
        // zeros). Use the data-port's own direction instead.
        if (!data_port_write_pending) begin
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
                shm_sync_enabled <= 1'b1;
                bg_sync_slot <= 6'd0;
            end
        end else begin
            remote_dma_addr <= data_port_byte_addr + 16'h0001;
            if (remote_byte_count > 16'h0001) begin
                remote_byte_count <= remote_byte_count - 16'h0001;
            end else begin
                remote_byte_count <= 16'h0000;
                isr_register <= isr_register | ISR_RDC;
                shm_sync_enabled <= 1'b1;
                bg_sync_slot <= 6'd0;
            end
        end

        eth_dma_req <= 1'b0;
        data_port_read_pending <= 1'b0;
        data_port_write_pending <= 1'b0;
        local_pmem_read_wait <= 1'b0;
        data_port_transfer_done <= 1'b1;
    end
endtask

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

function [7:0] hps_u8_from_dma;
    input [7:0] data;
    begin
        hps_u8_from_dma = data;
    end
endfunction

function [15:0] build_hps_status_word;
    input sampled;
    input signature_valid_in;
    input hb_nonzero;
    input hb_changed;
    input rx_active;
    input tx_pending;
    begin
        build_hps_status_word =
            (sampled ? ETH_STATUS_FPGA_SAMPLED : 16'h0000) |
            (signature_valid_in ? ETH_STATUS_FPGA_SIGNATURE : 16'h0000) |
            (hb_nonzero ? ETH_STATUS_FPGA_HEARTBEAT : 16'h0000) |
            (hb_changed ? ETH_STATUS_FPGA_HB_CHANGED : 16'h0000) |
            ((sampled && signature_valid_in && hb_changed) ? ETH_STATUS_FPGA_COMM_OK : 16'h0000) |
            (rx_active ? ETH_STATUS_FPGA_RX_ACTIVE : 16'h0000) |
            (tx_pending ? ETH_STATUS_FPGA_TX_PENDING : 16'h0000);
    end
endfunction

function [15:0] build_hps_status_dma_word;
    input sampled;
    input signature_valid_in;
    input hb_nonzero;
    input hb_changed;
    input rx_active;
    input tx_pending;
    reg [15:0] status_word;
    begin
        status_word = build_hps_status_word(sampled, signature_valid_in, hb_nonzero, hb_changed, rx_active, tx_pending);
        build_hps_status_dma_word = {status_word[7:0], status_word[15:8]};
    end
endfunction

function packet_ram_addr_valid;
    input [15:0] ne_addr;
    begin
        packet_ram_addr_valid = (ne_addr >= NE_PMEM_START) && (ne_addr < NE_PMEM_END);
    end
endfunction

/* verilator lint_off UNUSEDSIGNAL */
function [12:0] packet_ram_word_addr;
    input [15:0] ne_addr;
    reg [15:0] pmem_byte_addr;
    begin
        pmem_byte_addr = ne_addr - NE_PMEM_START;
        packet_ram_word_addr = pmem_byte_addr[13:1];
    end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

function [1:0] packet_ram_byteena_for_byte;
    input        addr_lsb;
    begin
        packet_ram_byteena_for_byte = addr_lsb ? 2'b01 : 2'b10;
    end
endfunction

function [15:0] packet_ram_wdata_for_byte;
    input        addr_lsb;
    input [7:0]  value;
    begin
        packet_ram_wdata_for_byte = addr_lsb ? {8'h00, value} : {value, 8'h00};
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

/* verilator lint_off UNUSEDSIGNAL */
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

eth_packet_ram packet_ram_inst (
    .clk(clk),
    .addr(pmem_addr),
    .wren(pmem_wren),
    .byteena(pmem_byteena),
    .wdata(pmem_wdata),
    .q(pmem_q)
);

// FPGA debug disabled to reduce Quartus build time.
// localparam USE_DEBUG_ISSP = 1'b1;

// ISSP source bits:
//   [0] inhibit background Ethernet DMA/sync engine
//   [1] synchronous clear for debug counters and sticky flags
// wire [1:0]  debug_source;
wire        debug_bg_disable = 1'b0;
wire        debug_clear = 1'b0;
wire [15:0] bg_flags_write_word =
    (bg_flags_word & (bg_clear_rx_avail ? 16'h0000 : ETH_HPS_FLAG_MASK)) |
    fpga_owned_flags;
wire        hps_signature_valid = (hps_signature_seen == 32'hCAFEBABE);
wire [15:0] hps_comm_status_word = build_hps_status_word(
    hps_status_sampled,
    hps_signature_valid,
    (hps_heartbeat_seen != 32'h00000000),
    hps_heartbeat_change_seen,
    receiver_active,
    tx_request_pending
);
wire        data_port_dma_complete_now = eth_dma_req && eth_dma_ready && !bg_dma_inflight;
wire        data_port_dma_timeout_now =
    eth_dma_req && !eth_dma_ready &&
    (eth_dma_wait_counter == ETH_DMA_TIMEOUT_CYCLES) &&
    (data_port_read_pending || data_port_write_pending ||
     (sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr)));
wire        local_remote_dma_active =
    (((cr_remote_dma_read || cr_remote_dma_write) &&
      ((remote_byte_count != 16'h0000) ||
       data_port_read_pending || data_port_write_pending || eth_dma_req || data_port_cycle_active))) ||
    data_port_read_pending || data_port_write_pending;
wire [15:0] bg_dma_hps_word = hps_u16_from_dma(eth_dma_rdata);
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
wire [1:0]  bg_rx_slot = bg_rx_queue_head[1:0];
wire [1:0]  bg_rx_next_slot = bg_rx_slot + 2'd1;
wire [15:0] bg_rx_slot_data_base =
    ETH_SHM_RX_QUEUE_DATA +
    (bg_rx_slot[1] ? (ETH_PACKET_BUFFER_SIZE << 1) : 16'h0000) +
    (bg_rx_slot[0] ? ETH_PACKET_BUFFER_SIZE : 16'h0000);
wire [15:0] tx_next_request_seq =
    (tx_request_seq == 16'hFFFF) ? 16'h0001 : (tx_request_seq + 16'h0001);
/* verilator lint_off UNUSEDSIGNAL */
wire [15:0] bg_rx_head_byte_addr = ETH_SHM_RX_QUEUE_HEAD;
wire [15:0] bg_rx_tail_byte_addr = ETH_SHM_RX_QUEUE_TAIL;
wire [15:0] bg_rx_len_byte_addr = ETH_SHM_RX_QUEUE_LEN + {13'h0000, bg_rx_slot, 1'b0};
wire [15:0] bg_payload_src_byte_addr = bg_rx_slot_data_base + bg_rx_src_offset;
wire [15:0] bg_tx_addr_byte_addr = ETH_SHM_TX_REQUEST_ADDR;
wire [15:0] bg_tx_len_byte_addr = ETH_SHM_TX_REQUEST_LEN;
wire [15:0] bg_tx_seq_byte_addr = ETH_SHM_TX_REQUEST_SEQ;
wire [15:0] bg_tx_complete_seq_byte_addr = ETH_SHM_TX_COMPLETE_SEQ;
wire [15:0] bg_tx_dst_byte_addr = ETH_SHM_TX_BUFFER + bg_tx_src_offset;
/* verilator lint_on UNUSEDSIGNAL */
wire [14:0] bg_flags_word_addr = ETH_SHM_CTRL_FLAGS[15:1];
wire [14:0] bg_status_word_addr = ETH_SHM_CTRL_STATUS[15:1];
wire [14:0] bg_rx_head_word_addr = bg_rx_head_byte_addr[15:1];
wire [14:0] bg_rx_tail_word_addr = bg_rx_tail_byte_addr[15:1];
wire [14:0] bg_rx_len_word_addr = bg_rx_len_byte_addr[15:1];
wire [14:0] bg_payload_src_word_addr = bg_payload_src_byte_addr[15:1];
wire [14:0] bg_tx_addr_word_addr = bg_tx_addr_byte_addr[15:1];
wire [14:0] bg_tx_len_word_addr = bg_tx_len_byte_addr[15:1];
wire [14:0] bg_tx_seq_word_addr = bg_tx_seq_byte_addr[15:1];
wire [14:0] bg_tx_complete_seq_word_addr = bg_tx_complete_seq_byte_addr[15:1];
wire [14:0] bg_tx_dst_word_addr = bg_tx_dst_byte_addr[15:1];
wire [14:0] bg_hps_hb_lo_word_addr = ETH_SHM_HPS_HEARTBEAT[15:1];
wire [14:0] bg_hps_hb_hi_word_addr = ETH_SHM_HPS_HEARTBEAT_HI[15:1];
wire [14:0] bg_hps_sig_lo_word_addr = ETH_SHM_HPS_SIGNATURE[15:1];
wire [14:0] bg_hps_sig_hi_word_addr = ETH_SHM_HPS_SIGNATURE_HI[15:1];
wire        data_port_select_active =
    sel_ethernet && !sel_ethernet_shm && is_data_port_access &&
    !cpu_as;
wire        data_port_bus_active = data_port_select_active && (cpu_rd || cpu_wr);
wire        data_port_cycle_start =
    data_port_bus_active && !data_port_bus_active_prev && !data_port_cycle_active;
wire        data_port_cycle_end = !data_port_select_active && data_port_cycle_active;
wire        data_port_cycle_timeout_now =
    data_port_cycle_active && !data_port_transfer_done &&
    (data_port_wait_counter == DATA_PORT_TIMEOUT_CYCLES);
// The background FSM contends with the CPU data-port ONLY for the shared
// single-port packet RAM, which it drives solely in the RX header/payload
// write states and the TX-buffer read states.  Its HPS-poll and mailbox
// traffic use eth_dma (DDR) and never touch packet RAM, so the CPU data-port
// must NOT be gated on general eth_dma_req activity -- only on actual bg
// packet-RAM access.  (Gating on eth_dma_req stalled the CPU during the now-
// active HPS poll and broke xsurftest's 16-bit memory test.  bg cannot enter
// these states while a data-port cycle is pending -- the bg request block is
// gated by !local_remote_dma_active -- so there is no RAM-port collision.)
wire        bg_pmem_active =
    (bg_state == BG_WRITE_HDR0_REQ)    ||
    (bg_state == BG_WRITE_HDR1_REQ)    ||
    (bg_state == BG_WRITE_PAYLOAD_REQ) ||
    (bg_state == BG_READ_TX_BUF_REQ)   ||
    (bg_state == BG_READ_TX_BUF_WAIT1) ||
    (bg_state == BG_READ_TX_BUF_WAIT2);
wire        data_port_cycle_launch_ok =
    (data_port_cycle_start || data_port_cycle_active) &&
    !data_port_transfer_done &&
    !data_port_cycle_timeout_now &&
    !data_port_dma_complete_now && !data_port_dma_timeout_now &&
    !data_port_write_pending && !data_port_read_pending && !bg_pmem_active;
wire [7:0]  debug_status_byte = {
    debug_dma_timeout_sticky,
    bg_dma_inflight,
    data_port_cycle_active,
    data_port_transfer_done,
    data_port_write_pending,
    data_port_read_pending,
    eth_dma_req,
    local_remote_dma_active
};

// ---------------------------------------------------------------------------
// Live ISSP debug instance (In-System Sources & Probes over JTAG).
// Focused on the HPS<->FPGA mailbox round trip so we can confirm, without the
// HPS daemon log, whether the FPGA actually sees what the HPS writes to the
// 0x1FF00000 mailbox.
//
// eth_dbg_probe (128 bits), MSB..LSB:
//   [127:120] debug_status_byte  (timeout_sticky, bg_dma_inflight,
//                                 dp_cycle_active, dp_transfer_done,
//                                 dp_write_pending, dp_read_pending,
//                                 eth_dma_req, local_remote_dma_active)
//   [119:114] bg_state           (background mailbox FSM state)
//   [113]     hps_signature_valid (hps_signature_seen == 0xCAFEBABE)
//   [112]     hps_heartbeat_change_seen
//   [111:96]  remote_byte_count
//   [95:80]   tx_request_seq
//   [79:64]   hps_comm_status_word
//   [63:32]   hps_heartbeat_seen   <- advancing => FPGA reads HPS via mailbox
//   [31:0]    hps_signature_seen   <- 0xCAFEBABE => round trip works both ways
//
// Key check: read instance "ETHDBG"; if [31:0]==CAFEBABE and [63:32] advances
// between reads, the f2sdram2 mailbox round trip is healthy on hardware.
// ---------------------------------------------------------------------------
/* verilator lint_off UNUSEDSIGNAL */
wire [127:0] eth_dbg_probe = {
    debug_status_byte,            // [127:120]
    bg_state,                     // [119:114]
    hps_signature_valid,          // [113]
    hps_heartbeat_change_seen,    // [112]
    remote_byte_count,            // [111:96]
    tx_request_seq,               // [95:80]
    hps_comm_status_word,         // [79:64]
    hps_heartbeat_seen,           // [63:32]
    hps_signature_seen            // [31:0]
};
wire [1:0] eth_dbg_source;        // JTAG-driven source (reserved; observe-only)
/* verilator lint_on UNUSEDSIGNAL */

ethernet_issp #(
    .PROBE_WIDTH(128),
    .SOURCE_WIDTH(2),
    .INSTANCE_ID("ETHDBG")
) eth_debug_issp (
    .clk(clk),
    .probe(eth_dbg_probe),
    .source(eth_dbg_source)
);

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
// wire [15:0] debug_sticky_flags = {debug_dma_timeout_sticky, debug_sticky_flags_lo};

// /* verilator lint_off UNUSEDSIGNAL */
// wire [127:0] debug_probe = {
//     remote_dma_addr,
//     remote_byte_count,
//     debug_sticky_flags,
//     eth_dma_addr,
//     cpu_addr,
//     cr_register,
//     isr_register,
//     imr_register,
//     curr_register,
//     bg_state[4:0],
//     cpu_rd,
//     cpu_wr,
//     sel_ethernet,
//     sel_ethernet_shm,
//     is_data_port_access,
//     dtack_eth,
//     eth_irq,
//     eth_dma_req,
//     eth_dma_ready,
//     eth_dma_write,
//     bg_dma_inflight,
//     data_port_read_pending,
//     data_port_write_pending
// };
// /* verilator lint_on UNUSEDSIGNAL */

// generate
// if (USE_DEBUG_ISSP) begin : gen_eth_debug_issp
//     ethernet_issp #(
//         .PROBE_WIDTH(128),
//         .SOURCE_WIDTH(2),
//         .INSTANCE_ID("ETHDBG")
//     ) eth_debug_issp (
//         .clk(clk),
//         .probe(debug_probe),
//         .source(debug_source)
//     );
// end else begin : gen_eth_debug_issp_tieoff
//     assign debug_source = 2'b00;
// end
// endgenerate

// always @(posedge clk) begin
//     if (reset || debug_clear) begin
//         debug_heartbeat <= 16'h0000;
//         debug_local_wait_cycles <= 16'h0000;
//         debug_dma_wait_cycles <= 16'h0000;
//         debug_sticky_flags_lo <= 15'h0000;
//     end else begin
//         debug_heartbeat <= debug_heartbeat + 16'h0001;
//
//         if (sel_ethernet && !sel_ethernet_shm && (cpu_rd || cpu_wr) && dtack_eth &&
//             (debug_local_wait_cycles != 16'hFFFF)) begin
//             debug_local_wait_cycles <= debug_local_wait_cycles + 16'h0001;
//         end
//
//         if (eth_dma_req && !eth_dma_ready && (debug_dma_wait_cycles != 16'hFFFF)) begin
//             debug_dma_wait_cycles <= debug_dma_wait_cycles + 16'h0001;
//         end
//
//         if (sel_ethernet && !sel_ethernet_shm && (cpu_rd || cpu_wr) && dtack_eth) begin
//             debug_sticky_flags_lo[0] <= 1'b1;
//         end
//         if (eth_dma_req && !eth_dma_ready) begin
//             debug_sticky_flags_lo[1] <= 1'b1;
//         end
//         if (sel_ethernet && sel_ethernet_shm) begin
//             debug_sticky_flags_lo[2] <= 1'b1;
//         end
//         if (sel_ethernet && cpu_wr && is_register_access) begin
//             debug_sticky_flags_lo[3] <= 1'b1;
//         end
//         if (sel_ethernet && (cpu_rd || cpu_wr) && is_data_port_access) begin
//             debug_sticky_flags_lo[4] <= 1'b1;
//         end
//         if (eth_dma_req && sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr)) begin
//             debug_sticky_flags_lo[5] <= 1'b1;
//         end
//         if (bg_polling_rx_flags) begin
//             debug_sticky_flags_lo[6] <= 1'b1;
//         end
//         if (shm_sync_enabled) begin
//             debug_sticky_flags_lo[7] <= 1'b1;
//         end
//         if (tx_request_pending) begin
//             debug_sticky_flags_lo[8] <= 1'b1;
//         end
//         if (eth_irq) begin
//             debug_sticky_flags_lo[9] <= 1'b1;
//         end
//         if (isr_register[6]) begin
//             debug_sticky_flags_lo[10] <= 1'b1;
//         end
//         if (isr_register[4]) begin
//             debug_sticky_flags_lo[11] <= 1'b1;
//         end
//         if (isr_register[0]) begin
//             debug_sticky_flags_lo[12] <= 1'b1;
//         end
//         if (isr_register[1]) begin
//             debug_sticky_flags_lo[13] <= 1'b1;
//         end
//         if (debug_bg_disable) begin
//             debug_sticky_flags_lo[14] <= 1'b1;
//         end
//     end
// end

always @* begin
    pmem_addr = 13'h0000;
    pmem_wdata = 16'h0000;
    pmem_byteena = 2'b00;
    pmem_wren = 1'b0;

    if (bg_state == BG_WRITE_HDR0_REQ) begin
        pmem_addr = packet_ram_word_addr(NE_PMEM_START + bg_rx_dst_offset);
        pmem_wdata = {bg_rx_status, bg_rx_next_page};
        pmem_byteena = 2'b11;
        pmem_wren = 1'b1;
    end else if (bg_state == BG_WRITE_HDR1_REQ) begin
        pmem_addr = packet_ram_word_addr(NE_PMEM_START + bg_rx_dst_offset + 16'h0002);
        pmem_wdata = {bg_rx_total_length[7:0], bg_rx_total_length[15:8]};
        pmem_byteena = 2'b11;
        pmem_wren = 1'b1;
    end else if (bg_state == BG_WRITE_PAYLOAD_REQ) begin
        pmem_addr = packet_ram_word_addr(NE_PMEM_START + bg_rx_dst_offset + 16'h0004 + bg_rx_src_offset);
        if (bg_rx_bytes_remaining > 16'h0001) begin
            pmem_wdata = bg_source_word;
            pmem_byteena = 2'b11;
        end else begin
            pmem_wdata = {bg_source_word[15:8], 8'h00};
            pmem_byteena = 2'b10;
        end
        pmem_wren = 1'b1;
    end else if (data_port_cycle_launch_ok && cpu_wr && remote_dma_pmem_region &&
                 (~cpu_uds || ~cpu_lds)) begin
        pmem_addr = packet_ram_word_addr(remote_dma_addr);
        if (dcr_word_mode) begin
            pmem_wdata = dcr_byte_swap ? {cpu_data_in[7:0], cpu_data_in[15:8]} : cpu_data_in;
            pmem_byteena = 2'b11;
        end else begin
            pmem_wdata = packet_ram_wdata_for_byte(remote_dma_addr[0], cpu_write_byte);
            pmem_byteena = packet_ram_byteena_for_byte(remote_dma_addr[0]);
        end
        pmem_wren = 1'b1;
    end else if (data_port_read_pending) begin
        pmem_addr = packet_ram_word_addr(data_port_byte_addr);
    end else if ((bg_state == BG_READ_TX_BUF_REQ) || (bg_state == BG_READ_TX_BUF_WAIT1) ||
                 (bg_state == BG_READ_TX_BUF_WAIT2)) begin
        pmem_addr = packet_ram_word_addr(tx_stage_addr + bg_tx_src_offset);
    end else if (data_port_cycle_launch_ok && cpu_rd && remote_dma_pmem_region) begin
        pmem_addr = packet_ram_word_addr(remote_dma_addr);
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
            if (is_data_port_access && !sel_ethernet_shm) begin
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
            data_port_wait_counter <= 10'd0;
            data_port_word_mode <= dcr_word_mode;
            data_port_byte_addr <= remote_dma_addr;
        end else if (data_port_cycle_end ||
                     (data_port_cycle_active &&
                      (!sel_ethernet || sel_ethernet_shm || !is_data_port_access))) begin
            data_port_cycle_active <= 1'b0;
            data_port_transfer_done <= 1'b0;
            data_port_wait_counter <= 10'd0;
        end else if (data_port_cycle_active && !data_port_transfer_done) begin
            if (data_port_wait_counter != DATA_PORT_TIMEOUT_CYCLES) begin
                data_port_wait_counter <= data_port_wait_counter + 10'd1;
            end
        end else begin
            data_port_wait_counter <= 10'd0;
        end

        if (data_port_cycle_timeout_now) begin
            debug_dma_timeout_sticky <= 1'b1;
            data_port_read_data <= 16'hFFFF;
            data_port_read_pending <= 1'b0;
            data_port_write_pending <= 1'b0;
            local_pmem_read_wait <= 1'b0;
            data_port_transfer_done <= 1'b1;
            if (!bg_dma_inflight) begin
                eth_dma_req <= 1'b0;
                eth_dma_write <= 1'b0;
                eth_dma_uds <= 1'b1;
                eth_dma_lds <= 1'b1;
            end
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
                    if (cr_write_remote_dma_abort) begin
                        data_port_read_pending <= 1'b0;
                        data_port_write_pending <= 1'b0;
                        data_port_transfer_done <= 1'b0;
                        data_port_cycle_active <= 1'b0;
                        local_pmem_read_wait <= 1'b0;
                        // Abort the CPU's remote DMA, but do NOT stomp the shared
                        // eth_dma master if it is owned by a PURE background
                        // mailbox transfer (bg_dma_inflight with no CPU data-port
                        // op). The driver issues remote-DMA-abort (CR RD=100)
                        // constantly; clearing eth_dma_req mid-background-transfer
                        // left bg_dma_inflight stuck with eth_dma_req low (ISSP:
                        // bg in *_WAIT, req=0), wedging the mailbox and then
                        // blocking CPU remote DMA -> driver I/O error.
                        if (!bg_dma_inflight || data_port_read_pending || data_port_write_pending) begin
                            eth_dma_req <= 1'b0;
                            eth_dma_write <= 1'b0;
                            eth_dma_uds <= 1'b1;
                            eth_dma_lds <= 1'b1;
                            eth_dma_wait_counter <= 10'd0;
                        end
                        isr_register <= (cr_write_value[0] ? (isr_register | ISR_RST)
                                                          : (isr_register & ~ISR_RST)) | ISR_RDC;
                    end else if ((cr_write_remote_dma_read || cr_write_remote_dma_write) &&
                                 (remote_byte_count == 16'h0000)) begin
                        isr_register <= (cr_write_value[0] ? (isr_register | ISR_RST)
                                                          : (isr_register & ~ISR_RST)) | ISR_RDC;
                    end
                    // TPSR (transmit page) is independent of the RX ring; on a
                    // standard NE2000 the TX buffer (page 0x40) sits BELOW
                    // PSTART (0x46). Bound the transmit by the physical packet
                    // RAM page range [NE_PAGE_BASE, NE_PMEM_END>>8), not by the
                    // RX ring [PSTART, PSTOP) -- the latter wrongly dropped a
                    // transmit from page 0x40 (TSR/ISR.PTX never set).
                    if (cr_write_value[2] &&
                        (tbcr_register != 16'h0000) &&
                        (tpsr_register >= NE_PAGE_BASE) &&
                        (tpsr_register < NE_PMEM_END[15:8])) begin
                        tsr_register <= 8'h00;
                        if (tcr_loopback_mode != 2'b00) begin
                            tx_complete_pending <= 1'b1;
                            tx_stage_pending <= 1'b0;
                            tx_request_pending <= 1'b0;
                        end else begin
                            // Complete-on-command: report PTX immediately when the
                            // transmit is issued, exactly like a real NE2000
                            // accepting the frame. The packet still stages to the
                            // HPS mailbox in the background (tx_stage_pending), but
                            // Amiga-side TX completion does not wait on the slow
                            // word-by-word mailbox copy (a 1500-byte frame is
                            // hundreds of eth_dma round trips) -- which otherwise
                            // overran the driver's transmit timeout ("No IRQ
                            // received / Transmit timeout"). The HPS picks up the
                            // published TX_REQUEST_SEQ once staging finishes.
                            tx_complete_pending <= 1'b1;
                            tx_stage_pending <= 1'b1;
                            tx_request_pending <= 1'b0;
                            tx_stage_addr <= {tpsr_register, 8'h00};
                            tx_stage_len <= tbcr_register;
                            bg_tx_src_offset <= 16'h0000;
                            bg_tx_bytes_remaining <= tbcr_register;
                        end
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

            shm_sync_enabled <= 1'b1;
            bg_sync_slot <= 6'd0;
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
                isr_register <= isr_register | ISR_PTX;
            end else begin
                isr_register <= isr_register | ISR_PTX;
            end
            shm_sync_enabled <= 1'b1;
            bg_sync_slot <= 6'd0;
        end

        if (data_port_read_pending && local_pmem_read_wait) begin
            local_pmem_read_wait <= 1'b0;
        end else if (data_port_read_pending && !bg_pmem_active && remote_dma_pmem_region) begin
            complete_data_port_transfer(pmem_q);
        end

        // The CPU-facing data-port path keeps a bounded eth_dma timeout so the
        // 68k can never hang. The background mailbox DMA (bg_dma_inflight, no
        // data-port access) has NO timeout: it simply waits for the mailbox to
        // complete. Abandoning + re-issuing a background transfer here used to
        // race the clk_audio mailbox FSM (which only samples a new request while
        // idle) and permanently desync the clk_sys<->clk_audio handshake, which
        // ISSP showed as bg_dma_inflight stuck with eth_dma_req low.
        if (eth_dma_req && !eth_dma_ready &&
            (data_port_read_pending || data_port_write_pending ||
             (sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr)))) begin
            if (eth_dma_wait_counter != ETH_DMA_TIMEOUT_CYCLES) begin
                eth_dma_wait_counter <= eth_dma_wait_counter + 10'd1;
            end else begin
                eth_dma_wait_counter <= 10'd0;
                debug_dma_timeout_sticky <= 1'b1;
                if (bg_dma_inflight) begin
                    bg_dma_inflight <= 1'b0;
                    bg_state <= BG_IDLE;
                    bg_polling_rx_flags <= 1'b0;
                    bg_clear_rx_avail <= 1'b0;
                    bg_poll_counter <= BG_POLL_RELOAD;
                end
                complete_data_port_transfer(16'hFFFF);
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
                        bg_flags_word <= bg_dma_hps_word;
                        if (bg_polling_rx_flags) begin
                            bg_state <= BG_READ_RX_HEAD_REQ;
                        end else if ((bg_dma_hps_word & ETH_FPGA_FLAG_MASK) != fpga_owned_flags) begin
                            bg_clear_rx_avail <= 1'b0;
                            bg_state <= BG_CLEAR_FLAG_REQ;
                        end else begin
                            mirrored_fpga_flags <= bg_dma_hps_word & ETH_FPGA_FLAG_MASK;
                            bg_state <= BG_IDLE;
                            bg_poll_counter <= BG_POLL_RELOAD;
                        end
                    end

                    BG_READ_RX_HEAD_WAIT: begin
                        bg_rx_queue_head <= bg_dma_hps_word & ETH_RX_QUEUE_INDEX_MASK;
                        bg_state <= BG_READ_RX_TAIL_REQ;
                    end

                    BG_READ_RX_TAIL_WAIT: begin
                        bg_rx_queue_tail <= bg_dma_hps_word & ETH_RX_QUEUE_INDEX_MASK;
                        if (bg_rx_queue_head[1:0] == bg_dma_hps_word[1:0]) begin
                            bg_polling_rx_flags <= 1'b0;
                            bg_clear_rx_avail <= (bg_flags_word & ETH_FLAG_RX_AVAIL) != 16'h0000;
                            if ((bg_flags_word & ETH_FLAG_RX_AVAIL) != 16'h0000) begin
                                bg_state <= BG_CLEAR_FLAG_REQ;
                            end else begin
                                bg_state <= BG_IDLE;
                                bg_poll_counter <= BG_POLL_RELOAD;
                            end
                        end else begin
                            bg_state <= BG_READ_RX_LEN_REQ;
                        end
                    end

                    BG_READ_RX_LEN_WAIT: begin
                        bg_rx_total_length <= bg_rx_length_from_dma + 16'h0004;
                        bg_rx_src_offset <= 16'h0000;
                        bg_rx_bytes_remaining <= bg_rx_length_from_dma;
                        bg_rx_dst_offset <= bg_rx_dst_offset_calc;
                        bg_rx_next_page <= bg_rx_next_page_calc;
                        bg_rx_queue_next_head <= {14'h0000, bg_rx_next_slot};
                        bg_rx_status <= RSR_PRX | RSR_PHY;
                        bg_clear_rx_avail <= (bg_rx_next_slot == bg_rx_queue_tail[1:0]);

                        if (bg_rx_length_from_dma == 16'h0000) begin
                            bg_state <= BG_WRITE_RX_HEAD_REQ;
                        end else if (bg_rx_next_page_calc == bnry_register) begin
                            rsr_register <= RSR_MPA;
                            isr_register <= isr_register | ISR_OVW;
                            cntr2_register <= cntr2_register + 8'h01;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                            bg_state <= BG_WRITE_RX_HEAD_REQ;
                        end else begin
                            bg_state <= BG_WRITE_HDR0_REQ;
                        end
                    end

                    BG_READ_PAYLOAD_WAIT: begin
                        bg_source_word <= eth_dma_rdata;
                        bg_state <= BG_WRITE_PAYLOAD_REQ;
                    end

                    BG_WRITE_TX_LEN_WAIT: begin
                        if (bg_tx_bytes_remaining != 16'h0000) begin
                            bg_state <= BG_READ_TX_BUF_REQ;
                        end else begin
                            bg_state <= BG_WRITE_TX_SEQ_REQ;
                        end
                    end

                    BG_WRITE_TX_BUF_WAIT: begin
                        if (bg_tx_bytes_remaining > 16'h0002) begin
                            bg_tx_src_offset <= bg_tx_src_offset + 16'h0002;
                            bg_tx_bytes_remaining <= bg_tx_bytes_remaining - 16'h0002;
                            bg_state <= BG_READ_TX_BUF_REQ;
                        end else begin
                            bg_tx_src_offset <= bg_tx_src_offset + bg_tx_bytes_remaining;
                            bg_tx_bytes_remaining <= 16'h0000;
                            bg_state <= BG_WRITE_TX_SEQ_REQ;
                        end
                    end

                    BG_WRITE_TX_ADDR_WAIT: begin
                        bg_state <= BG_WRITE_TX_LEN_REQ;
                    end

                    BG_WRITE_TX_SEQ_WAIT: begin
                        // Background staging finished: the frame is now fully
                        // published to the HPS mailbox (addr/len/payload/seq) and
                        // the HPS can pick up TX_REQUEST_SEQ and transmit. PTX was
                        // already reported at command time (complete-on-command),
                        // so just clear the staging state here.
                        tx_request_seq <= tx_next_request_seq;
                        tx_stage_pending <= 1'b0;
                        tx_request_pending <= 1'b0;
                        bg_polling_rx_flags <= 1'b0;
                        bg_clear_rx_avail <= 1'b0;
                        bg_state <= BG_READ_FLAGS_REQ;
                    end

                    BG_READ_TX_DONE_WAIT: begin
                        if ((tx_request_seq != 16'h0000) &&
                            (hps_u16_from_dma(eth_dma_rdata) == tx_request_seq)) begin
                            tx_stage_pending <= 1'b0;
                            tx_request_pending <= 1'b0;
                            tx_complete_pending <= 1'b1;
                            bg_polling_rx_flags <= 1'b0;
                            bg_clear_rx_avail <= 1'b0;
                            bg_state <= BG_READ_FLAGS_REQ;
                        end else begin
                            bg_state <= BG_IDLE;
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

                    BG_READ_HPS_HB_LO_WAIT: begin
                        bg_hps_heartbeat_lo <= hps_u16_from_dma(eth_dma_rdata);
                        bg_state <= BG_READ_HPS_HB_HI_REQ;
                    end

                    BG_READ_HPS_HB_HI_WAIT: begin
                        if (hps_status_sampled &&
                            ({hps_u16_from_dma(eth_dma_rdata), bg_hps_heartbeat_lo} != hps_heartbeat_seen)) begin
                            hps_heartbeat_change_seen <= 1'b1;
                        end
                        hps_heartbeat_seen <= {hps_u16_from_dma(eth_dma_rdata), bg_hps_heartbeat_lo};
                        hps_status_sampled <= 1'b1;
                        bg_state <= BG_READ_HPS_SIG_LO_REQ;
                    end

                    BG_READ_HPS_SIG_LO_WAIT: begin
                        bg_hps_signature_lo <= hps_u16_from_dma(eth_dma_rdata);
                        bg_state <= BG_READ_HPS_SIG_HI_REQ;
                    end

                    BG_READ_HPS_SIG_HI_WAIT: begin
                        // Latch the signature read result, then issue the status
                        // write through the dedicated BG_WRITE_STATUS_REQ state.
                        // Do NOT assert eth_dma_req inline here.  This block runs in
                        // the same cycle the previous (read) transfer completed, and
                        // line ~1470 is deasserting eth_dma_req.  Re-asserting it in
                        // the same cycle keeps eth_dma_req continuously high, so the
                        // clk_audio mailbox never sees the rising edge it needs to
                        // flip req_toggle (eth_ddr3_mailbox.v: "if (eth_dma_req &&
                        // !req_d)") -> the write is silently dropped and the FSM
                        // deadlocks (ISSP: bg stuck at BG_WRITE_STATUS_WAIT, MBOX
                        // state=idle, wr_acc=0).  Routing through the _REQ block
                        // (guarded by !eth_dma_req && !bg_dma_inflight) guarantees
                        // the same req-low gap every read transaction gets.
                        hps_signature_seen <= {hps_u16_from_dma(eth_dma_rdata), bg_hps_signature_lo};
                        bg_state <= BG_WRITE_STATUS_REQ;
                    end

                    BG_WRITE_STATUS_WAIT: begin
                        hps_poll_counter <= HPS_POLL_RELOAD;
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

        if (data_port_cycle_launch_ok && cpu_wr) begin
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
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                        end
                    end else begin
                        remote_dma_addr <= remote_dma_addr + 16'h0001;
                        if (remote_byte_count > 16'h0001) begin
                            remote_byte_count <= remote_byte_count - 16'h0001;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                        end
                    end
                end else if (remote_dma_pmem_region) begin
                    data_port_transfer_done <= 1'b1;
                    data_port_word_mode <= dcr_word_mode;
                    data_port_byte_addr <= remote_dma_addr;
                    if (dcr_word_mode) begin
                        remote_dma_addr <= remote_dma_addr + 16'h0002;
                        if (remote_byte_count > 16'h0002) begin
                            remote_byte_count <= remote_byte_count - 16'h0002;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                        end
                    end else begin
                        remote_dma_addr <= remote_dma_addr + 16'h0001;
                        if (remote_byte_count > 16'h0001) begin
                            remote_byte_count <= remote_byte_count - 16'h0001;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                        end
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
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                        end
                    end else begin
                        remote_dma_addr <= remote_dma_addr + 16'h0001;
                        if (remote_byte_count > 16'h0001) begin
                            remote_byte_count <= remote_byte_count - 16'h0001;
                        end else begin
                            remote_byte_count <= 16'h0000;
                            isr_register <= isr_register | ISR_RDC;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                        end
                    end
                end
            end
        end else if (data_port_cycle_launch_ok && cpu_rd) begin
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
                        shm_sync_enabled <= 1'b1;
                        bg_sync_slot <= 6'd0;
                    end
                end else begin
                    data_port_read_data <= {prom_read_byte, prom_read_byte};
                    remote_dma_addr <= remote_dma_addr + 16'h0001;
                    if (remote_byte_count > 16'h0001) begin
                        remote_byte_count <= remote_byte_count - 16'h0001;
                    end else begin
                        remote_byte_count <= 16'h0000;
                        isr_register <= isr_register | ISR_RDC;
                        shm_sync_enabled <= 1'b1;
                        bg_sync_slot <= 6'd0;
                    end
                end
            end else if (remote_dma_pmem_region) begin
                data_port_word_mode <= dcr_word_mode;
                data_port_byte_addr <= remote_dma_addr;
                local_pmem_read_wait <= 1'b1;
                data_port_read_pending <= 1'b1;
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
                        shm_sync_enabled <= 1'b1;
                        bg_sync_slot <= 6'd0;
                    end
                end else begin
                    data_port_read_data <= 16'hFFFF;
                    remote_dma_addr <= remote_dma_addr + 16'h0001;
                    if (remote_byte_count > 16'h0001) begin
                        remote_byte_count <= remote_byte_count - 16'h0001;
                    end else begin
                        remote_byte_count <= 16'h0000;
                        isr_register <= isr_register | ISR_RDC;
                        shm_sync_enabled <= 1'b1;
                        bg_sync_slot <= 6'd0;
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
            if (!debug_bg_disable && (hps_poll_counter != 8'h00)) begin
                hps_poll_counter <= hps_poll_counter - 8'h01;
            end
            if (!debug_bg_disable &&
                !eth_dma_req &&
                !local_remote_dma_active &&
                !(sel_ethernet && is_data_port_access && (cpu_rd || cpu_wr))) begin
                if (bg_clear_rx_avail) begin
                    bg_state <= BG_CLEAR_FLAG_REQ;
                end else if (tx_stage_pending) begin
                    bg_state <= BG_WRITE_TX_ADDR_REQ;
                end else if (tx_request_pending &&
                             ((mirrored_fpga_flags & ETH_FLAG_TX_REQ) != 16'h0000)) begin
                    bg_state <= BG_READ_TX_DONE_REQ;
                end else if (((shm_sync_enabled || tx_request_pending) &&
                     (mirrored_fpga_flags != fpga_owned_flags)) ||
                    (receiver_active && (bg_poll_counter == 8'h00))) begin
                    bg_polling_rx_flags <= receiver_active && (bg_poll_counter == 8'h00);
                    bg_clear_rx_avail <= 1'b0;
                    bg_state <= BG_READ_FLAGS_REQ;
                end else if (hps_poll_counter == 8'h00) begin
                    bg_state <= BG_READ_HPS_HB_LO_REQ;
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

                BG_READ_RX_HEAD_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_rx_head_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_RX_HEAD_WAIT;
                end

                BG_READ_RX_TAIL_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_rx_tail_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_RX_TAIL_WAIT;
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
                    bg_state <= BG_WRITE_HDR1_REQ;
                end

                    BG_WRITE_HDR1_REQ: begin
                        if (bg_rx_bytes_remaining != 16'h0000) begin
                            bg_state <= BG_READ_PAYLOAD_REQ;
                        end else begin
                            rsr_register <= bg_rx_status;
                            isr_register <= isr_register | ISR_PRX;
                            curr_register <= bg_rx_next_page;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                            bg_state <= BG_WRITE_RX_HEAD_REQ;
                        end
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
                        if (bg_rx_bytes_remaining > 16'h0001) begin
                            bg_rx_src_offset <= bg_rx_src_offset + 16'h0002;
                            bg_rx_bytes_remaining <= bg_rx_bytes_remaining - 16'h0002;
                            bg_state <= BG_READ_PAYLOAD_REQ;
                    end else begin
                        bg_rx_src_offset <= bg_rx_src_offset + bg_rx_bytes_remaining;
                        bg_rx_bytes_remaining <= 16'h0000;
                        rsr_register <= bg_rx_status;
                        isr_register <= isr_register | ISR_PRX;
                            curr_register <= bg_rx_next_page;
                            shm_sync_enabled <= 1'b1;
                            bg_sync_slot <= 6'd0;
                            bg_state <= BG_WRITE_RX_HEAD_REQ;
                        end
                    end

                    BG_WRITE_RX_HEAD_WAIT: begin
                        bg_rx_queue_head <= bg_rx_queue_next_head;
                        bg_polling_rx_flags <= 1'b0;
                        bg_state <= BG_CLEAR_FLAG_REQ;
                    end

                BG_WRITE_TX_LEN_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_tx_len_word_addr;
                    eth_dma_wdata <= {tx_stage_len[7:0], tx_stage_len[15:8]};
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_TX_LEN_WAIT;
                end

                BG_WRITE_TX_ADDR_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_tx_addr_word_addr;
                    eth_dma_wdata <= {tx_stage_addr[7:0], tx_stage_addr[15:8]};
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_TX_ADDR_WAIT;
                end

                BG_READ_TX_BUF_REQ: begin
                    bg_state <= BG_READ_TX_BUF_WAIT1;
                end

                BG_READ_TX_BUF_WAIT1: begin
                    bg_state <= BG_READ_TX_BUF_WAIT2;
                end

                BG_READ_TX_BUF_WAIT2: begin
                    bg_source_word <= pmem_q;
                    bg_state <= BG_WRITE_TX_BUF_REQ;
                end

                BG_WRITE_TX_BUF_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_tx_dst_word_addr;
                    if (bg_tx_bytes_remaining > 16'h0001) begin
                        eth_dma_wdata <= bg_source_word;
                        eth_dma_uds <= 1'b0;
                        eth_dma_lds <= 1'b0;
                    end else begin
                        eth_dma_wdata <= {bg_source_word[15:8], 8'h00};
                        eth_dma_uds <= 1'b0;
                        eth_dma_lds <= 1'b1;
                    end
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_TX_BUF_WAIT;
                end

                BG_WRITE_RX_HEAD_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_rx_head_word_addr;
                    eth_dma_wdata <= {bg_rx_queue_next_head[7:0], bg_rx_queue_next_head[15:8]};
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_RX_HEAD_WAIT;
                end

                BG_WRITE_TX_SEQ_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_tx_seq_word_addr;
                    eth_dma_wdata <= {tx_next_request_seq[7:0], tx_next_request_seq[15:8]};
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_TX_SEQ_WAIT;
                end

                BG_READ_TX_DONE_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_tx_complete_seq_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_TX_DONE_WAIT;
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

                BG_READ_HPS_HB_LO_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_hps_hb_lo_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_HPS_HB_LO_WAIT;
                end

                BG_READ_HPS_HB_HI_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_hps_hb_hi_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_HPS_HB_HI_WAIT;
                end

                BG_READ_HPS_SIG_LO_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_hps_sig_lo_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_HPS_SIG_LO_WAIT;
                end

                BG_READ_HPS_SIG_HI_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b0;
                    eth_dma_addr <= bg_hps_sig_hi_word_addr;
                    eth_dma_wdata <= 16'h0000;
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_READ_HPS_SIG_HI_WAIT;
                end

                BG_WRITE_STATUS_REQ: begin
                    eth_dma_req <= 1'b1;
                    eth_dma_write <= 1'b1;
                    eth_dma_addr <= bg_status_word_addr;
                    eth_dma_wdata <= build_hps_status_dma_word(
                        hps_status_sampled,
                        hps_signature_valid,
                        (hps_heartbeat_seen != 32'h00000000),
                        hps_heartbeat_change_seen,
                        receiver_active,
                        tx_request_pending
                    );
                    eth_dma_uds <= 1'b0;
                    eth_dma_lds <= 1'b0;
                    bg_dma_inflight <= 1'b1;
                    bg_state <= BG_WRITE_STATUS_WAIT;
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


// The RTL8019 data port aliases over its register block so longword monitor
// reads can hit the second word within that slot. Reg 0x17 (0xEA0C5C) is carved
// out below as the link/media-status register, so the alias stops at 0xC5B.
assign is_data_port_access = (byte_addr >= 16'h0C40) && (byte_addr <= 16'h0C5B);

// RTL8019/X-Surf link/media-status register at reg 0x17 (0xEA0C5C). The X-Surf
// TestPrg reads it after a transmit: bit0 = link up, bits[2:1] = speed/duplex
// (00=10H, 01=10F, 10=100H, 11=100F). It must NOT be treated as remote-DMA data
// (which read 0 -> "link down!") and must have no data-port side effects.
wire is_link_status = (byte_addr >= 16'h0C5C) && (byte_addr <= 16'h0C5F);
assign is_debug_port_access = (byte_addr >= 16'h0C60) && (byte_addr <= 16'h0C7B);
assign is_reset_port_access = (byte_addr >= 16'h0C7C) && (byte_addr <= 16'h0C7F);

// X-Surf card-level interrupt-status register at board offset 0x40 (0xEA0040).
// The X-Surf TestPrg and the Roadshow driver read this byte; bit 7 reflects the
// NIC interrupt-request line. Without this the offset read open-bus 0xFF, whose
// bit 7 made the test report "Interrupt Bit ist schon gesetzt / Falsche Karte".
wire is_xsurf_int_status = (byte_addr == 16'h0040) || (byte_addr == 16'h0041);

// Register access detection: Only 0xEA1C00-0xEA1C3F range (byte addresses)
// Removed 0xEA1600 range for simplification
assign is_register_access = ((byte_addr >= 16'h0C00) && (byte_addr <= 16'h0C3F));

// Convert word offset to register number for 0xC00 range only
reg [4:0] reg_index_0c00;

always @(*) begin
    reg_index_0c00 = byte_addr[6:2];
end

assign register_select = is_data_port_access ? 5'd16 :                // Data port
                         (is_register_access || is_debug_port_access || is_reset_port_access) ? reg_index_0c00 :  // Register/debug/reset index
                         5'd31;  // Invalid

// Output logic - immediate response with full register set support
always @(*) begin
    // Default outputs
    cpu_data_out = 16'h0000;

    // Handle the whole configured Ethernet card aperture. Only the RTL8019
    // register/data/debug/reset block has behavior; all other card offsets
    // read as open-bus 0xFFFF but still terminate the CPU cycle.
    if (sel_ethernet && cpu_rd) begin
        cpu_data_out = 16'hFFFF;

        if (!sel_ethernet_shm && is_xsurf_int_status) begin
            // bit 7 of each byte lane = NIC interrupt-request line state.
            cpu_data_out = irq_pending ? 16'h8080 : 16'h0000;
        end
        else if (!sel_ethernet_shm && is_link_status) begin
            // bit0 = link up, bits[2:1] = 01 -> 10 Mbit/s full duplex.
            cpu_data_out = 16'h0303;
        end
        else if (!sel_ethernet_shm && is_data_port_access) begin
            cpu_data_out = data_port_read_data;
        end
        else if (!sel_ethernet_shm &&
                 (is_register_access || is_debug_port_access || is_reset_port_access)) begin
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
                            2'b00: cpu_data_out = format_reg_read_data(cntr0_register, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[5], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(tcr_register, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(cntr0_register, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x0E: CNTR1/MAR6 - Tally Counter 1 or Multicast Address Register 6
                    5'h0E: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(cntr1_register, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[6], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(dcr_register, cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(8'h50, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(cntr1_register, cpu_uds, cpu_lds);
                        endcase
                    end

                    // Register 0x0F: CNTR2/IMR/MAR7 - Tally Counter 2, Interrupt Mask Register or MAR7
                    5'h0F: begin
                        case (current_page)
                            2'b00: cpu_data_out = format_reg_read_data(cntr2_register, cpu_uds, cpu_lds);
                            2'b01: cpu_data_out = format_reg_read_data(mar_registers[7], cpu_uds, cpu_lds);
                            2'b10: cpu_data_out = format_reg_read_data(imr_register, cpu_uds, cpu_lds);
                            2'b11: cpu_data_out = format_reg_read_data(8'h70, cpu_uds, cpu_lds);
                            default: cpu_data_out = format_reg_read_data(cntr2_register, cpu_uds, cpu_lds);
                        endcase
                    end
                    5'h18: begin
                        cpu_data_out = format_reg_read_data(remote_dma_addr[7:0], cpu_uds, cpu_lds);
                    end
                    5'h19: begin
                        cpu_data_out = format_reg_read_data(remote_dma_addr[15:8], cpu_uds, cpu_lds);
                    end
                    5'h1A: begin
                        cpu_data_out = format_reg_read_data(remote_byte_count[7:0], cpu_uds, cpu_lds);
                    end
                    5'h1B: begin
                        cpu_data_out = format_reg_read_data(remote_byte_count[15:8], cpu_uds, cpu_lds);
                    end
                    5'h1C: begin
                        cpu_data_out = format_reg_read_data(debug_status_byte, cpu_uds, cpu_lds);
                    end
                    5'h1D: begin
                        cpu_data_out = hps_comm_status_word;
                    end
                    5'h1E: begin
                        cpu_data_out = hps_heartbeat_seen[15:0];
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

module eth_packet_ram (
    input  wire        clk,
    input  wire [12:0] addr,
    input  wire        wren,
    input  wire [1:0]  byteena,
    input  wire [15:0] wdata,
    output reg  [15:0] q
);
    (* ramstyle = "M10K" *) reg [7:0] mem_l [0:8191];
    (* ramstyle = "M10K" *) reg [7:0] mem_u [0:8191];

    always @(posedge clk) begin
        if (wren) begin
            if (byteena[0]) mem_l[addr] <= wdata[7:0];
            if (byteena[1]) mem_u[addr] <= wdata[15:8];
        end
        q <= {mem_u[addr], mem_l[addr]};
    end
endmodule

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
