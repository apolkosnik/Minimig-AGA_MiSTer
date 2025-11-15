// minimig_eth.h
//
// Minimig NE2000 Ethernet Support for MiSTer
// ARM/HPS side TAP device interface
//
// Copyright (c) 2025
// GPLv3
//

#ifndef MINIMIG_ETH_H
#define MINIMIG_ETH_H

#include <stdint.h>

// NE2000 Status Codes (from FPGA)
#define ETH_STATUS_IDLE       0xFE
#define ETH_STATUS_TX_PENDING 0xA5
#define ETH_STATUS_TX_DONE    0x12

// Ethernet command modes for 0x64
#define ETH_MODE_TX_READ   0  // Read TX buffer (FPGA -> ARM)
#define ETH_MODE_RX_WRITE  1  // Write RX buffer (ARM -> FPGA)
#define ETH_MODE_MAC_WRITE 2  // Write MAC address
#define ETH_MODE_STATUS    3  // Status query (unused, status comes from 0x64 byte 0)

// Maximum ethernet frame size
#define ETH_MAX_FRAME_SIZE 1536

// NE2000 status word structure (32-bit from FPGA)
typedef struct {
	uint8_t  statusCode;    // [31:24] Status code
	uint8_t  reserved;      // [23:16] Reserved
	uint8_t  tx_ready:1;    // [18] TX buffer ready
	uint8_t  isr_ptx:1;     // [17] Packet transmitted interrupt
	uint8_t  isr_prx:1;     // [16] Packet received interrupt
	uint8_t  pad:5;         // [15:19] Padding
	uint16_t tbcr;          // [15:0] Transmit byte count
} __attribute__((packed)) eth_status_t;

// Function declarations
int  minimig_eth_init(const char *tap_device, const uint8_t *mac_addr);
void minimig_eth_shutdown(void);
void minimig_eth_poll(void);
int  minimig_eth_set_mac(const uint8_t *mac_addr);

// Internal functions
int  eth_read_status(eth_status_t *status);
int  eth_read_tx_packet(uint8_t *buffer, uint16_t length);
int  eth_write_rx_packet(const uint8_t *buffer, uint16_t length);
int  eth_write_mac_address(const uint8_t *mac_addr);

#endif // MINIMIG_ETH_H
