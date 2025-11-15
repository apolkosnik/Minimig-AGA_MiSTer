// minimig_eth.cpp
//
// Minimig NE2000 Ethernet Support for MiSTer
// ARM/HPS side TAP device interface
//
// Copyright (c) 2025
// GPLv3
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <linux/if.h>
#include <linux/if_tun.h>

#include "minimig_eth.h"

// External functions from MiSTer (you'll need to link these)
extern void EnableIO();
extern void DisableIO();
extern uint16_t fpga_spi_fast(uint16_t word);
extern void fpga_spi_fast_block_read_8(uint8_t *buf, uint32_t len);
extern void fpga_spi_fast_block_write_8(const uint8_t *buf, uint32_t len);

// Command codes (from user_io.h)
#define UIO_DMA_WRITE  0x61
#define UIO_DMA_READ   0x62
#define UIO_GET_STATUS 0x63
#define UIO_ETH_CMD    0x64

// Ethernet chip select and mode encoding
#define ETH_CS_BASE    0xF400  // Chip select for ethernet
#define ETH_CS(mode)   (ETH_CS_BASE | (mode))

// Global state
static int tap_fd = -1;
static uint8_t local_mac[6] = {0};
static int eth_enabled = 0;

// Statistics
static uint32_t tx_packets = 0;
static uint32_t rx_packets = 0;
static uint32_t tx_bytes = 0;
static uint32_t rx_bytes = 0;

//-----------------------------------------------------------------------------
// TAP device management
//-----------------------------------------------------------------------------

static int tap_open(const char *dev_name)
{
	struct ifreq ifr;
	int fd, err;

	if ((fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK)) < 0) {
		perror("open /dev/net/tun");
		return -1;
	}

	memset(&ifr, 0, sizeof(ifr));
	ifr.ifr_flags = IFF_TAP | IFF_NO_PI;  // TAP device, no packet info

	if (dev_name && *dev_name) {
		strncpy(ifr.ifr_name, dev_name, IFNAMSIZ-1);
	}

	if ((err = ioctl(fd, TUNSETIFF, (void *)&ifr)) < 0) {
		perror("ioctl TUNSETIFF");
		close(fd);
		return -1;
	}

	printf("[ETH] TAP device '%s' opened (fd=%d)\n", ifr.ifr_name, fd);
	return fd;
}

static void tap_close(int fd)
{
	if (fd >= 0) {
		close(fd);
		printf("[ETH] TAP device closed\n");
	}
}

//-----------------------------------------------------------------------------
// FPGA Communication
//-----------------------------------------------------------------------------

int eth_read_status(eth_status_t *status)
{
	EnableIO();

	// Send command 0x64
	fpga_spi_fast(UIO_ETH_CMD);

	// Read 32-bit status (sent as 2x 16-bit words)
	uint16_t status_hi = fpga_spi_fast(0);  // Byte 1: upper 16 bits
	uint16_t status_lo = fpga_spi_fast(0);  // Byte 2: lower 16 bits

	DisableIO();

	// Parse status word
	uint32_t status_word = ((uint32_t)status_hi << 16) | status_lo;

	status->statusCode = (status_word >> 24) & 0xFF;
	status->reserved   = (status_word >> 16) & 0xFF;
	status->tx_ready   = (status_word >> 18) & 0x01;
	status->isr_ptx    = (status_word >> 17) & 0x01;
	status->isr_prx    = (status_word >> 16) & 0x01;
	status->tbcr       = status_word & 0xFFFF;

	return 0;
}

int eth_read_tx_packet(uint8_t *buffer, uint16_t length)
{
	if (length > ETH_MAX_FRAME_SIZE) {
		fprintf(stderr, "[ETH] TX packet too large: %u bytes\n", length);
		return -1;
	}

	EnableIO();

	// Command 0x61 (DMA read from FPGA)
	fpga_spi_fast(UIO_DMA_WRITE);  // Note: naming is from FPGA perspective

	// Chip select + mode (0xF400 = ethernet, mode 0 = TX read)
	fpga_spi_fast(ETH_CS(ETH_MODE_TX_READ));

	// Start transfer (byte 2)
	fpga_spi_fast(0);

	// Read packet data byte-by-byte (byte 3+)
	fpga_spi_fast_block_read_8(buffer, length);

	DisableIO();

	tx_packets++;
	tx_bytes += length;

	return length;
}

int eth_write_rx_packet(const uint8_t *buffer, uint16_t length)
{
	if (length > ETH_MAX_FRAME_SIZE) {
		fprintf(stderr, "[ETH] RX packet too large: %u bytes\n", length);
		return -1;
	}

	EnableIO();

	// Command 0x61 (DMA write to FPGA)
	fpga_spi_fast(UIO_DMA_WRITE);

	// Chip select + mode (0xF401 = ethernet, mode 1 = RX write)
	fpga_spi_fast(ETH_CS(ETH_MODE_RX_WRITE));

	// Start transfer (byte 2)
	fpga_spi_fast(0);

	// Write packet data byte-by-byte (byte 3+)
	fpga_spi_fast_block_write_8(buffer, length);

	DisableIO();

	rx_packets++;
	rx_bytes += length;

	return length;
}

int eth_write_mac_address(const uint8_t *mac_addr)
{
	EnableIO();

	// Command 0x61 (DMA write)
	fpga_spi_fast(UIO_DMA_WRITE);

	// Chip select + mode (0xF402 = ethernet, mode 2 = MAC write)
	fpga_spi_fast(ETH_CS(ETH_MODE_MAC_WRITE));

	// Start transfer
	fpga_spi_fast(0);

	// Write 6 MAC address bytes
	fpga_spi_fast_block_write_8(mac_addr, 6);

	DisableIO();

	printf("[ETH] MAC address set to %02X:%02X:%02X:%02X:%02X:%02X\n",
	       mac_addr[0], mac_addr[1], mac_addr[2],
	       mac_addr[3], mac_addr[4], mac_addr[5]);

	return 0;
}

//-----------------------------------------------------------------------------
// Public API
//-----------------------------------------------------------------------------

int minimig_eth_init(const char *tap_device, const uint8_t *mac_addr)
{
	// Open TAP device
	tap_fd = tap_open(tap_device);
	if (tap_fd < 0) {
		fprintf(stderr, "[ETH] Failed to open TAP device\n");
		return -1;
	}

	// Store MAC address
	if (mac_addr) {
		memcpy(local_mac, mac_addr, 6);
	} else {
		// Generate random MAC (locally administered)
		local_mac[0] = 0x02;  // Locally administered
		for (int i = 1; i < 6; i++) {
			local_mac[i] = rand() & 0xFF;
		}
	}

	// Configure MAC address in NE2000
	if (eth_write_mac_address(local_mac) < 0) {
		fprintf(stderr, "[ETH] Failed to set MAC address\n");
		tap_close(tap_fd);
		tap_fd = -1;
		return -1;
	}

	eth_enabled = 1;
	tx_packets = tx_bytes = 0;
	rx_packets = rx_bytes = 0;

	printf("[ETH] Ethernet initialized successfully\n");
	printf("[ETH] TAP: %s, MAC: %02X:%02X:%02X:%02X:%02X:%02X\n",
	       tap_device ? tap_device : "tap0",
	       local_mac[0], local_mac[1], local_mac[2],
	       local_mac[3], local_mac[4], local_mac[5]);

	return 0;
}

void minimig_eth_shutdown(void)
{
	if (eth_enabled) {
		printf("[ETH] Statistics: TX=%u packets (%u bytes), RX=%u packets (%u bytes)\n",
		       tx_packets, tx_bytes, rx_packets, rx_bytes);

		tap_close(tap_fd);
		tap_fd = -1;
		eth_enabled = 0;
	}
}

void minimig_eth_poll(void)
{
	if (!eth_enabled || tap_fd < 0) return;

	static uint8_t packet_buffer[ETH_MAX_FRAME_SIZE];
	eth_status_t status;

	// Check FPGA status
	if (eth_read_status(&status) < 0) {
		return;
	}

	// Handle TX: Amiga wants to send packet
	if (status.statusCode == ETH_STATUS_TX_PENDING) {
		uint16_t tx_len = status.tbcr;

		if (tx_len > 0 && tx_len <= ETH_MAX_FRAME_SIZE) {
			// Read packet from FPGA
			if (eth_read_tx_packet(packet_buffer, tx_len) > 0) {
				// Write to TAP device
				ssize_t written = write(tap_fd, packet_buffer, tx_len);
				if (written < 0) {
					if (errno != EAGAIN && errno != EWOULDBLOCK) {
						perror("[ETH] TAP write error");
					}
				} else if (written != tx_len) {
					fprintf(stderr, "[ETH] Partial TAP write: %zd/%u bytes\n",
					        written, tx_len);
				}
			}
		}
	}

	// Handle RX: Check if TAP has data for Amiga
	fd_set rfds;
	struct timeval tv = {0, 0};  // Non-blocking

	FD_ZERO(&rfds);
	FD_SET(tap_fd, &rfds);

	int ret = select(tap_fd + 1, &rfds, NULL, NULL, &tv);
	if (ret > 0 && FD_ISSET(tap_fd, &rfds)) {
		// Read from TAP device
		ssize_t rx_len = read(tap_fd, packet_buffer, ETH_MAX_FRAME_SIZE);

		if (rx_len > 0) {
			// Write to FPGA
			eth_write_rx_packet(packet_buffer, rx_len);
		} else if (rx_len < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK) {
				perror("[ETH] TAP read error");
			}
		}
	}
}

int minimig_eth_set_mac(const uint8_t *mac_addr)
{
	if (!eth_enabled) return -1;

	memcpy(local_mac, mac_addr, 6);
	return eth_write_mac_address(local_mac);
}
