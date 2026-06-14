#ifndef __MINIMIG_ETH_H__
#define __MINIMIG_ETH_H__

#include <stdbool.h>
#include <stdint.h>

#include "minimig_eth_abi.h"

// Shared memory layout using the DDR-backed ethernet aperture.
// Uses CPU address space 0xEA0000-0xEAFFFF (64KB) for ethernet communication.

#define ETH_BOARD_ADDR   0xEA0000 // Amiga address space (Zorro II)
#define ETH_BOARD_SIZE   0x10000 // 64KB

// A2065-style dedicated f2sdram2 mailbox window.  This is a reserved high-DDR
// region (just below 0x20000000) that the MiSTer Linux kernel does not use, so
// the FPGA (via the eth_ddr3_mailbox f2sdram2 master) and the ARM (via this
// /dev/mem mmap) access exactly the same bytes.  The RTL single source of truth
// is rtl/eth_dma_addr_map.v: ETH_F2SDRAM_BASE_WORD = ETH_SHMEM_ADDR >> 3.
#define ETH_SHMEM_ADDR   0x1FF00000 // HPS physical base of the f2sdram2 mailbox (== RTL base<<3)
#define ETH_SHMEM_OFFSET   0x00       // Zero, because we map to the beginning of the shared memory
#define ETH_SHMEM_SIZE   0x10000     // 64KB of the mapped address space 0x1FF00000-0x1FF0FFFF
#define ETH_SHM_BOARD_OFFSET 0x0000       // Shared memory offset from 0xEA0000
#define ETH_SHARED_OFFSET   0x1000
#define ETH_SHARED_BASE  (ETH_BOARD_ADDR + ETH_SHARED_OFFSET) // 0x00EA0000 - Amiga Base address for ethernet shared memory
#define ETH_SHARED_SIZE   (ETH_SHMEM_SIZE)    // Full 64KB shared memory region

// Page 0 registers (read) - 32-bit aligned addresses
#define NE_P0_CR          (0x00 * 4)  // Command Register (0x00)
#define NE_P0_CLDA0       (0x01 * 4)  // Current Local DMA Address 0 (0x04)
#define NE_P0_CLDA1       (0x02 * 4)  // Current Local DMA Address 1 (0x08)
#define NE_P0_BNRY        (0x03 * 4)  // Boundary Pointer (0x0C)
#define NE_P0_TSR         (0x04 * 4)  // Transmit Status Register (0x10)
#define NE_P0_NCR         (0x05 * 4)  // Number of Collisions Register (0x14)
#define NE_P0_FIFO        (0x06 * 4)  // FIFO (0x18)
#define NE_P0_ISR         (0x07 * 4)  // Interrupt Status Register (0x1C)
#define NE_P0_CRDA0       (0x08 * 4)  // Current Remote DMA Address 0 (0x20)
#define NE_P0_CRDA1       (0x09 * 4)  // Current Remote DMA Address 1 (0x24)
#define NE_P0_RSR         (0x0C * 4)  // Receive Status Register (0x30)

// Page 0 registers (write) - 32-bit aligned addresses
#define NE_P0_PSTART      (0x01 * 4)  // Page Start Register (0x04)
#define NE_P0_PSTOP       (0x02 * 4)  // Page Stop Register (0x08)
#define NE_P0_TPSR        (0x04 * 4)  // Transmit Page Start Register (0x10)
#define NE_P0_TBCR0       (0x05 * 4)  // Transmit Byte Count Register 0 (0x14)
#define NE_P0_TBCR1       (0x06 * 4)  // Transmit Byte Count Register 1 (0x18)
#define NE_P0_RSAR0       (0x08 * 4)  // Remote Start Address Register 0 (0x20)
#define NE_P0_RSAR1       (0x09 * 4)  // Remote Start Address Register 1 (0x24)
#define NE_P0_RBCR0       (0x0A * 4)  // Remote Byte Count Register 0 (0x28)
#define NE_P0_RBCR1       (0x0B * 4)  // Remote Byte Count Register 1 (0x2C)
#define NE_P0_RCR         (0x0C * 4)  // Receive Configuration Register (0x30)
#define NE_P0_TCR         (0x0D * 4)  // Transmit Configuration Register (0x34)
#define NE_P0_DCR         (0x0E * 4)  // Data Configuration Register (0x38)
#define NE_P0_IMR         (0x0F * 4)  // Interrupt Mask Register (0x3C)

// Page 1 registers - 32-bit aligned addresses
#define NE_P1_PAR0        (0x01 * 4)  // Physical Address Register 0 (0x04)
#define NE_P1_PAR1        (0x02 * 4)  // Physical Address Register 1 (0x08)
#define NE_P1_PAR2        (0x03 * 4)  // Physical Address Register 2 (0x0C)
#define NE_P1_PAR3        (0x04 * 4)  // Physical Address Register 3 (0x10)
#define NE_P1_PAR4        (0x05 * 4)  // Physical Address Register 4 (0x14)
#define NE_P1_PAR5        (0x06 * 4)  // Physical Address Register 5 (0x18)
#define NE_P1_CURR        (0x07 * 4)  // Current Page Register (0x1C)
#define NE_P1_MAR0        (0x08 * 4)  // Multicast Address Register 0 (0x20)
#define NE_P1_MAR1        (0x09 * 4)  // Multicast Address Register 1 (0x24)
#define NE_P1_MAR2        (0x0A * 4)  // Multicast Address Register 2 (0x28)
#define NE_P1_MAR3        (0x0B * 4)  // Multicast Address Register 3 (0x2C)
#define NE_P1_MAR4        (0x0C * 4)  // Multicast Address Register 4 (0x30)
#define NE_P1_MAR5        (0x0D * 4)  // Multicast Address Register 5 (0x34)
#define NE_P1_MAR6        (0x0E * 4)  // Multicast Address Register 6 (0x38)
#define NE_P1_MAR7        (0x0F * 4)  // Multicast Address Register 7 (0x3C)

// Command Register bits
#define NE_CR_STP         0x01      // Stop
#define NE_CR_STA         0x02      // Start
#define NE_CR_TXP         0x04      // Transmit Packet
#define NE_CR_RD0         0x08      // Remote DMA Command bit 0
#define NE_CR_RD1         0x10      // Remote DMA Command bit 1
#define NE_CR_RD2         0x20      // Remote DMA Command bit 2
#define NE_CR_PS0         0x40      // Page Select bit 0
#define NE_CR_PS1         0x80      // Page Select bit 1

// Remote DMA Commands
#define NE_CR_RDMA_NOT    0x00      // Not allowed
#define NE_CR_RDMA_READ   0x08      // Remote read
#define NE_CR_RDMA_WRITE  0x10      // Remote write
#define NE_CR_RDMA_SEND   0x18      // Send packet

// Interrupt Status Register bits
#define NE_ISR_PRX        0x01      // Packet Received
#define NE_ISR_PTX        0x02      // Packet Transmitted
#define NE_ISR_RXE        0x04      // Receive Error
#define NE_ISR_TXE        0x08      // Transmit Error
#define NE_ISR_OVW        0x10      // Overwrite Warning
#define NE_ISR_CNT        0x20      // Counter Overflow
#define NE_ISR_RDC        0x40      // Remote DMA Complete
#define NE_ISR_RST        0x80      // Reset Status

// Transmit Status Register bits
#define NE_TSR_PTX        0x01      // Packet Transmitted
#define NE_TSR_COL        0x04      // Collided
#define NE_TSR_ABT        0x08      // Aborted
#define NE_TSR_CRS        0x10      // Carrier Sense Lost
#define NE_TSR_FU         0x20      // FIFO Underrun
#define NE_TSR_CDH        0x40      // CD Heartbeat
#define NE_TSR_OWC        0x80      // Out of Window Collision

// Receive Status Register bits
#define NE_RSR_PRX        0x01      // Packet Received Intact
#define NE_RSR_CRC        0x02      // CRC Error
#define NE_RSR_FAE        0x04      // Frame Alignment Error
#define NE_RSR_FO         0x08      // FIFO Overrun
#define NE_RSR_MPA        0x10      // Missed Packet
#define NE_RSR_PHY        0x20      // Physical/Multicast Address
#define NE_RSR_DIS        0x40      // Receiver Disabled
#define NE_RSR_DFR        0x80      // Deferring

// Receive Configuration Register bits
#define NE_RCR_SEP        0x01      // Save Error Packets
#define NE_RCR_AR         0x02      // Accept Runt Packets
#define NE_RCR_AB         0x04      // Accept Broadcast
#define NE_RCR_AM         0x08      // Accept Multicast
#define NE_RCR_PRO        0x10      // Promiscuous Physical
#define NE_RCR_MON        0x20      // Monitor Mode

// Transmit Configuration Register bits
#define NE_TCR_CRC        0x01      // Inhibit CRC
#define NE_TCR_LB01       0x02      // Encoded Loopback Control
#define NE_TCR_LB10       0x04      // Encoded Loopback Control
#define NE_TCR_ATD        0x08      // Auto Transmit Disable
#define NE_TCR_OFST       0x10      // Collision Offset Enable

// Data Configuration Register bits
#define NE_DCR_WTS        0x01      // Word Transfer Select
#define NE_DCR_BOS        0x02      // Byte Order Select
#define NE_DCR_LAS        0x04      // Long Address Select
#define NE_DCR_LS         0x08      // Loopback Select
#define NE_DCR_ARM        0x10      // Auto-initialize Remote
#define NE_DCR_FT00       0x20      // FIFO Threshold Select
#define NE_DCR_FT01       0x40      // FIFO Threshold Select

// Memory layout
#define NE_PROM_SIZE      0x0020    // 32-byte station PROM / low memory shadow
#define NE_PMEM_START     0x4000    // Packet memory starts at NE address 0x4000
#define NE_PMEM_SIZE      0x4000    // 16KB packet RAM
#define NE_PMEM_END       (NE_PMEM_START + NE_PMEM_SIZE)
#define NE_MEM_SIZE       NE_PMEM_END
#define NE_PAGE_SIZE      0x100     // 256 bytes per page
#define NE_RX_START       0x46      // RX ring start page (after 6 TX pages)
#define NE_RX_STOP        0x80      // RX buffer stop page
#define NE_TX_START       0x40      // TX buffer start page

// Packet header structure (NE2000 format)
struct ne_packet_header {
    uint8_t status;
    uint8_t next_page;
    uint16_t length;
} __attribute__((packed));

// RTL8019 state structure (minimal HPS state - FPGA handles registers directly)
struct rtl8019_state {
    // Minimal HPS state (FPGA owns all NIC semantics via shared memory)
    uint8_t current_page;  // For debugging only
    
    // Debug snapshot fields mirrored by FPGA
    uint8_t mac_addr[6];
    bool link_up;
    bool enabled;
    
    // HPS transport statistics (host-side ingress/egress bookkeeping)
    uint32_t tx_packets;
    uint32_t rx_packets;
    uint32_t tx_errors;
    uint32_t rx_errors;
};

// Function prototypes
void minimig_eth_init();
void minimig_eth_poll();
void minimig_eth_reset();
void minimig_eth_test();  // Test function for debugging

#endif // __MINIMIG_ETH_H__
