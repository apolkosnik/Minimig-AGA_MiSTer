#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <ifaddrs.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>

#include "minimig_eth.h"

#if __has_include("../../MiSTer_Main/Main_MiSTer/shmem.h")
#include "../../MiSTer_Main/Main_MiSTer/shmem.h"
#include "../../MiSTer_Main/Main_MiSTer/hardware.h"
#include "../../MiSTer_Main/Main_MiSTer/user_io.h"
#include "../../MiSTer_Main/Main_MiSTer/spi.h"
#else
#include "../../shmem.h"
#include "../../hardware.h"
#include "../../user_io.h"
#include "../../spi.h"
#endif


#define ETH_DEBUG

#ifdef ETH_DEBUG
    #define eth_debug printf
#else
    #define eth_debug(x,...) void()
#endif


#ifdef ETH_DEBUG
	#define dbg_print printf
	#define dbg_hexdump hexdump
#else
	#define dbg_print(x,...) void()
	#define dbg_hexdump(x,...) void()
#endif

#define SWAP_INT(a) ((((a)&0x000000ff)<<24)|(((a)&0x0000ff00)<<8)|(((a)&0x00ff0000)>>8)|(((a)&0xff000000)>>24))

// The DDR3 physical address for ethernet shared memory
// This corresponds to the ramaddr mapping above
// ramaddr = {1'b0, 1'b0, 4'b1101, 7'b0, offset[14:1]}
// Which gives us physical address 0x1A000000 + offset



static int raw_socket = -1;
static uint8_t *eth_shmem = 0;
static uint32_t hps_heartbeat_counter = 0;
static uint16_t hps_last_tx_complete_seq = 0;
static struct sockaddr_ll sock_addr;
static char bridge_interface[16] = "eth0";

#define ETH_HOST_RX_QUEUE_DEPTH 8

struct host_rx_packet {
    uint16_t len;
    uint8_t data[ETH_PACKET_BUFFER_SIZE];
};

static struct host_rx_packet host_rx_queue[ETH_HOST_RX_QUEUE_DEPTH];
static uint8_t host_rx_queue_head = 0;
static uint8_t host_rx_queue_tail = 0;
static uint8_t host_rx_queue_count = 0;

// Access ethernet shared memory through mapped region
static void eth_write_shared_mem(uint32_t offset, const void *data, uint32_t size)
{
    if (!eth_shmem || eth_shmem == (uint8_t *)-1) {
        eth_debug("eth_write_shared_mem: no eth_shmem!\n");
        return;
    }
    if (offset + size > ETH_SHMEM_SIZE) {
        eth_debug("ETH: Write beyond shared memory bounds: offset=0x%X, size=%d\n", offset, size);
        return;
    }
    
    //eth_debug("ETH: Writing %d bytes to offset 0x%X\n", size, offset);
    memcpy(eth_shmem + offset, data, size);
}

static void eth_read_shared_mem(uint32_t offset, void *data, uint32_t size)
{
    if (!eth_shmem || eth_shmem == (uint8_t *)-1) {
        eth_debug("eth_read_shared_mem: no eth_shmem!\n");
        memset(data, 0, size);
        return;
    }
    
    if (offset + size > ETH_SHMEM_SIZE) {
        eth_debug("ETH: Read beyond shared memory bounds: offset=0x%X, size=%d\n", offset, size);
        memset(data, 0, size);
        return;
    }
    
    //eth_debug("ETH: Reading %d bytes from offset 0x%X\n", size, offset);
    memcpy(data, eth_shmem + offset, size);
}

static void eth_write_shared_u32(uint32_t offset, uint32_t value)
{
    eth_write_shared_mem(offset, &value, 4);
}

static void eth_write_shared_u16(uint32_t offset, uint16_t value)
{
    eth_write_shared_mem(offset, &value, 2);
}

static uint8_t eth_read_shared_reg(uint32_t offset)
{
    // Read 8-bit register value from LSB of 32-bit word
    uint32_t reg_val;
    eth_read_shared_mem(offset, &reg_val, 4);
    return (uint8_t)(reg_val & 0xFF);
}

static uint32_t eth_read_shared_u32(uint32_t offset)
{
    uint32_t value;
    eth_read_shared_mem(offset, &value, 4);
    return value;
}

static uint16_t eth_read_shared_u16(uint32_t offset)
{
    uint16_t value;
    eth_read_shared_mem(offset, &value, 2);
    return value;
}

static bool eth_read_text_file(const char* path, char* buffer, size_t buffer_size)
{
    if (!path || !buffer || buffer_size < 2) {
        return false;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        buffer[0] = '\0';
        return false;
    }

    ssize_t len = read(fd, buffer, buffer_size - 1);
    close(fd);

    if (len <= 0) {
        buffer[0] = '\0';
        return false;
    }

    buffer[len] = '\0';
    while (len > 0 && (buffer[len - 1] == '\n' || buffer[len - 1] == '\r' ||
                       buffer[len - 1] == ' '  || buffer[len - 1] == '\t')) {
        buffer[--len] = '\0';
    }

    return true;
}

static uint16_t eth_detect_link_status_bits(void)
{
    char path[128];
    char value[32];
    uint16_t status = 0;
    bool link_known = false;
    bool link_up = false;

    if (bridge_interface[0]) {
        snprintf(path, sizeof(path), "/sys/class/net/%s/carrier", bridge_interface);
        if (eth_read_text_file(path, value, sizeof(value))) {
            link_known = true;
            link_up = (value[0] == '1');
        }

        if (!link_known) {
            snprintf(path, sizeof(path), "/sys/class/net/%s/operstate", bridge_interface);
            if (eth_read_text_file(path, value, sizeof(value))) {
                link_known = true;
                link_up = !strcmp(value, "up") || !strcmp(value, "unknown");
            }
        }

        if (link_known) {
            if (link_up) {
                status |= ETH_STATUS_LINK_UP;
                snprintf(path, sizeof(path), "/sys/class/net/%s/duplex", bridge_interface);
                if (eth_read_text_file(path, value, sizeof(value)) && !strcmp(value, "full")) {
                    status |= ETH_STATUS_FULL_DUPLEX;
                }
            }
            return status;
        }
    }

    return (raw_socket >= 0) ? ETH_STATUS_LINK_UP : 0;
}

static uint32_t eth_update_shared_flags(uint32_t clear_mask, uint32_t set_mask)
{
    uint32_t flags = eth_read_shared_u32(ETH_CTRL_FLAGS);
    flags = (flags & ~clear_mask) | set_mask;
    eth_write_shared_u32(ETH_CTRL_FLAGS, flags);
    return flags;
}

static uint16_t eth_link_status_bits(void)
{
    static uint16_t cached_bits = 0;
    static uint8_t refresh_divider = 0;

    if ((raw_socket < 0) || (refresh_divider == 0)) {
        cached_bits = eth_detect_link_status_bits();
    }

    if (refresh_divider == 0xFF) {
        refresh_divider = 0;
    } else {
        refresh_divider++;
    }

    return cached_bits;
}

static void eth_update_shared_status(uint16_t clear_mask, uint16_t set_mask)
{
    uint16_t status = eth_read_shared_u16(ETH_CTRL_STATUS);
    status = (status & ~clear_mask) | set_mask;
    status &= ~(ETH_STATUS_LINK_UP | ETH_STATUS_FULL_DUPLEX);
    status |= eth_link_status_bits();
    eth_write_shared_u16(ETH_CTRL_STATUS, status);
}

static uint8_t read_ne_register(uint8_t page, uint8_t reg);

static bool translate_ne_packet_addr(uint16_t addr, uint32_t* shared_offset)
{
    if (addr >= NE_PMEM_START && addr < NE_PMEM_END) {
        *shared_offset = ETH_NE_MEMORY + (uint32_t)(addr - NE_PMEM_START);
        return true;
    }

    return false;
}

static uint8_t synthetic_prom_byte(uint16_t addr)
{
    uint8_t mac_addr[6];
    uint8_t prom[16] = {0};

    eth_read_shared_mem(ETH_CTRL_MAC, mac_addr, sizeof(mac_addr));
    memcpy(prom, mac_addr, 6);
    prom[14] = 0x57;
    prom[15] = 0x57;

    return prom[(addr >> 1) & 0x0F];
}

static uint32_t ethernet_crc32_le(const uint8_t* data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;

    while (len--) {
        crc ^= *data++;

        for (int bit = 0; bit < 8; bit++) {
            if (crc & 1) {
                crc = (crc >> 1) ^ 0xEDB88320u;
            } else {
                crc >>= 1;
            }
        }
    }

    return crc;
}

static bool multicast_hash_match(const uint8_t dest_mac[6])
{
    uint8_t mar[8];
    uint32_t crc = ethernet_crc32_le(dest_mac, 6);
    uint8_t hash = (crc >> 26) & 0x3F;

    for (int i = 0; i < 8; i++) {
        mar[i] = read_ne_register(1, 0x08 + i);
    }

    return (mar[hash >> 3] & (1u << (hash & 7))) != 0;
}

// Helper functions to access NE2000 memory directly from shared memory
static uint8_t read_ne_memory(uint16_t addr)
{
    uint32_t shared_offset;

    if (addr < NE_PROM_SIZE) {
        return synthetic_prom_byte(addr);
    }

    if (!translate_ne_packet_addr(addr, &shared_offset)) {
        eth_debug("NE2000 memory read from unmapped addr=0x%04X\n", addr);
        return 0xFF;
    }

    uint8_t value;
    eth_read_shared_mem(shared_offset, &value, 1);
    return value;
}

// Helper functions to access NE2000 registers directly from shared memory
static uint8_t read_ne_register(uint8_t page, uint8_t reg)
{
    if (page > 3 || reg > 15) {
        eth_debug("NE2000 register read beyond bounds: page=%d, reg=0x%02X\n", page, reg);
        return 0;
    }
    // Registers are stored as 32-bit aligned values in shared memory
    // Each page has 16 registers, each taking 4 bytes.
    // The FPGA emits each register slot as the 16-bit word {8'h00, value}
    // (rtl/ethernet.v sync_slot_wdata) and the mailbox byte-swaps every 16-bit
    // word on the way to DDR, so in memory the slot is [byte0]=0x00,[byte1]=value
    // (i.e. value lands at bits [15:8] of the little-endian word). Reading byte 0
    // returns the 0x00 pad, which is why CR/RCR/ISR/IMR all logged as 0x00 even
    // though rawCR (=0x..VV..00) plainly carried the real value in byte 1.
    uint32_t offset = (page * 16 + reg) * 4;
    uint32_t word = eth_read_shared_u32(ETH_CTRL_REGS + offset);
    return (uint8_t)((word >> 8) & 0xFF);
}

// DMA is handled entirely by FPGA - no HPS tracking needed

// FPGA mirrors the leading bytes of rtl8019_state. HPS only owns the trailing
// statistics area, so writes are limited to that subset.
static void write_eth_state_stats(const struct rtl8019_state* state) {
    if (!eth_shmem || eth_shmem == (uint8_t *)-1) {
        eth_debug("write_eth_state_stats: no eth_shmem!\n");
        return;
    }
    const size_t stats_offset = offsetof(struct rtl8019_state, tx_packets);
    eth_write_shared_mem(ETH_RTL8019_STATE + stats_offset,
                         ((const uint8_t*)state) + stats_offset,
                         sizeof(struct rtl8019_state) - stats_offset);
}

static void read_eth_state(struct rtl8019_state* state) {
    if (!eth_shmem || eth_shmem == (uint8_t *)-1) {
        eth_debug("read_eth_state: no eth_shmem!\n");
        memset(state, 0, sizeof(struct rtl8019_state));
        return;
    }
    eth_read_shared_mem(ETH_RTL8019_STATE, state, sizeof(struct rtl8019_state));
}

static void read_shared_mac(uint8_t mac_addr[6])
{
    eth_read_shared_mem(ETH_CTRL_MAC, mac_addr, 6);
}

struct tx_request {
    uint16_t addr;
    uint16_t len;
    uint16_t seq;
};

static struct tx_request read_shared_tx_request()
{
    struct tx_request request;

    request.addr = eth_read_shared_u16(ETH_TX_REQUEST_ADDR);
    request.len = eth_read_shared_u16(ETH_TX_REQUEST_LEN);
    request.seq = eth_read_shared_u16(ETH_TX_REQUEST_SEQ);

    return request;
}

static void clear_host_rx_queue()
{
    host_rx_queue_head = 0;
    host_rx_queue_tail = 0;
    host_rx_queue_count = 0;
}

static uint16_t next_shared_rx_slot(uint16_t slot)
{
    return (slot + 1) % ETH_RX_QUEUE_SLOTS;
}

static uint32_t shared_rx_slot_data_offset(uint16_t slot)
{
    return ETH_RX_QUEUE_DATA + slot * ETH_PACKET_BUFFER_SIZE;
}

static uint32_t shared_rx_slot_len_offset(uint16_t slot)
{
    return ETH_RX_QUEUE_LEN + slot * sizeof(uint16_t);
}

static uint16_t read_shared_rx_queue_head()
{
    return eth_read_shared_u16(ETH_RX_QUEUE_HEAD) & 0x00FF;
}

static uint16_t read_shared_rx_queue_tail()
{
    return eth_read_shared_u16(ETH_RX_QUEUE_TAIL) & 0x00FF;
}

static void write_shared_rx_queue_head(uint16_t head)
{
    eth_write_shared_u16(ETH_RX_QUEUE_HEAD, head & 0x00FF);
}

static void write_shared_rx_queue_tail(uint16_t tail)
{
    eth_write_shared_u16(ETH_RX_QUEUE_TAIL, tail & 0x00FF);
}

static bool enqueue_host_rx_packet(const uint8_t* data, uint16_t len)
{
    if (len > ETH_PACKET_BUFFER_SIZE || host_rx_queue_count >= ETH_HOST_RX_QUEUE_DEPTH) {
        return false;
    }

    memcpy(host_rx_queue[host_rx_queue_tail].data, data, len);
    host_rx_queue[host_rx_queue_tail].len = len;
    host_rx_queue_tail = (host_rx_queue_tail + 1) % ETH_HOST_RX_QUEUE_DEPTH;
    host_rx_queue_count++;
    return true;
}

static bool enqueue_shared_rx_packet(const uint8_t* data, uint16_t len, uint32_t* flags,
                                     struct rtl8019_state* state)
{
    uint16_t head = read_shared_rx_queue_head();
    uint16_t tail = read_shared_rx_queue_tail();
    uint16_t next_tail = next_shared_rx_slot(tail);

    if (next_tail == head) {
        return false;
    }

    eth_write_shared_mem(shared_rx_slot_data_offset(tail), data, len);
    eth_write_shared_u16(shared_rx_slot_len_offset(tail), len);
    write_shared_rx_queue_tail(next_tail);
    *flags = eth_update_shared_flags(0, ETH_FLAG_RX_AVAIL);

    eth_debug("ETH: Enqueued shared RX packet slot=%u len=%u head=%u tail->%u\n",
              tail, len, head, next_tail);

    if (state) {
        state->rx_packets++;
        write_eth_state_stats(state);
    }
    return true;
}

static bool rx_path_active(uint32_t flags)
{
    uint8_t cr_reg;
    uint8_t rcr_reg;

    if (!(flags & ETH_FLAG_ENABLED)) {
        return false;
    }

    cr_reg = read_ne_register(0, 0x00);
    rcr_reg = read_ne_register(0, 0x0C);

    if (cr_reg & 0x01) {
        return false;
    }

    if (rcr_reg & NE_RCR_MON) {
        return false;
    }

    return true;
}

static void drain_disabled_rx_socket()
{
    uint8_t buffer[ETH_PACKET_BUFFER_SIZE];

    if (raw_socket < 0) {
        return;
    }

    for (;;) {
        ssize_t len = recv(raw_socket, buffer, sizeof(buffer), 0);
        if (len <= 0) {
            break;
        }
    }
}

static bool pump_host_rx_queue(uint32_t* flags, struct rtl8019_state* state)
{
    if (host_rx_queue_count == 0) {
        return false;
    }

    struct host_rx_packet packet = host_rx_queue[host_rx_queue_head];
    if (!enqueue_shared_rx_packet(packet.data, packet.len, flags, state)) {
        return false;
    }

    host_rx_queue_head = (host_rx_queue_head + 1) % ETH_HOST_RX_QUEUE_DEPTH;
    host_rx_queue_count--;
    return true;
}

// Initialize ethernet emulation
void minimig_eth_init()
{
    // Map the ethernet shared memory region
    eth_debug("ETH: Initializing ethernet emulation...\n");
    eth_shmem = (uint8_t *)shmem_map(ETH_SHMEM_ADDR, ETH_SHMEM_SIZE);
    if (!eth_shmem) {
        eth_debug("Failed to map ethernet shared memory!\n");
        return;
    }

    eth_debug("Initializing RTL8019 ethernet emulation\n");

    // HPS only initializes its own staging/debug regions. FPGA owns the live
    // NE2000 register mirrors, MAC mirror, and enabled/IRQ/TX flags.
    minimig_eth_reset();
    
    // Initialize packet buffers with pattern for testing (LSB format)
    //uint8_t test_pattern[16] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
    //                            0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99};
    //eth_write_shared_mem(ETH_RX_BUFFER, test_pattern, 16);
    
    eth_debug("ETH: Shared memory initialized with signature 0x%08X\n", ETH_HPS_SIGNATURE_MAGIC);
    
    // Try to open raw socket for ethernet bridging
    eth_debug("ETH: Opening raw socket for bridging...\n");
    raw_socket = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (raw_socket < 0) {
        eth_debug("ETH: Warning: Could not open raw socket for ethernet bridging: %s\n", strerror(errno));
        eth_update_shared_status(0xFFFF, 0);
        return;
    }
    eth_debug("ETH: Raw socket opened successfully\n");
    
    // Find and bind to ethernet interface
    struct ifaddrs *ifaddr, *ifa;
    if (getifaddrs(&ifaddr) == -1) {
        eth_debug("Failed to get interface addresses\n");
        close(raw_socket);
        raw_socket = -1;
        eth_update_shared_status(0xFFFF, 0);
        return;
    }
    
    bool interface_found = false;
    for (ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL) continue;
        
        if (ifa->ifa_addr->sa_family == AF_PACKET &&
            !(ifa->ifa_flags & IFF_LOOPBACK) &&
            (ifa->ifa_flags & IFF_UP)) {
            strncpy(bridge_interface, ifa->ifa_name, sizeof(bridge_interface) - 1);
            bridge_interface[sizeof(bridge_interface) - 1] = '\0';
            interface_found = true;
            break;
        }
    }
    freeifaddrs(ifaddr);
    
    if (!interface_found) {
        eth_debug("ETH: Warning: No ethernet interface found for bridging\n");
        close(raw_socket);
        raw_socket = -1;
        eth_update_shared_status(0xFFFF, 0);
        return;
    }
    eth_debug("ETH: Found ethernet interface: %s\n", bridge_interface);
    
    // Get interface index
    struct ifreq ifr;
    strncpy(ifr.ifr_name, bridge_interface, IFNAMSIZ-1);
    if (ioctl(raw_socket, SIOCGIFINDEX, &ifr) < 0) {
        eth_debug("Failed to get interface index: %s\n", strerror(errno));
        close(raw_socket);
        raw_socket = -1;
        eth_update_shared_status(0xFFFF, 0);
        return;
    }
    
    // Bind socket to interface
    memset(&sock_addr, 0, sizeof(sock_addr));
    sock_addr.sll_family = AF_PACKET;
    sock_addr.sll_protocol = htons(ETH_P_ALL);
    sock_addr.sll_ifindex = ifr.ifr_ifindex;
    
    if (bind(raw_socket, (struct sockaddr*)&sock_addr, sizeof(sock_addr)) < 0) {
        eth_debug("ETH: Failed to bind raw socket: %s\n", strerror(errno));
        close(raw_socket);
        raw_socket = -1;
        eth_update_shared_status(0xFFFF, 0);
        return;
    }
    eth_debug("ETH: Socket bound to interface successfully\n");

    // Put the bridge interface in promiscuous mode so the host NIC delivers
    // frames addressed to the Amiga's station MAC (which differs from the host
    // NIC's own hardware MAC). Without this the kernel/NIC filter only passes
    // up broadcast/multicast and unicast for the host's own MAC, so broadcast
    // ARP reaches the Amiga but unicast replies (ping, TCP) addressed to the
    // Amiga MAC are dropped before this socket sees them (observed: RX stays 0).
    // PACKET_ADD_MEMBERSHIP/PACKET_MR_PROMISC is auto-cleared when the socket
    // closes, unlike SIOCSIFFLAGS|IFF_PROMISC.
    {
        struct packet_mreq mreq;
        memset(&mreq, 0, sizeof(mreq));
        mreq.mr_ifindex = ifr.ifr_ifindex;
        mreq.mr_type    = PACKET_MR_PROMISC;
        if (setsockopt(raw_socket, SOL_PACKET, PACKET_ADD_MEMBERSHIP,
                       &mreq, sizeof(mreq)) < 0) {
            eth_debug("ETH: Warning: could not enable promiscuous mode on %s: %s "
                      "(unicast RX to the Amiga MAC may be dropped)\n",
                      bridge_interface, strerror(errno));
        } else {
            eth_debug("ETH: Promiscuous mode enabled on %s "
                      "(receives unicast for the Amiga station MAC)\n",
                      bridge_interface);
        }
    }

    eth_update_shared_status(ETH_STATUS_LINK_UP, 0);

    // Print summary of ethernet initialization
    uint8_t shared_mac[6];
    read_shared_mac(shared_mac);

    eth_debug("===============================================\n");
    eth_debug("ETH: X-Surf 100 Ethernet Initialized!\n");
    eth_debug("ETH: Amiga Address: 0x%06X\n", ETH_BOARD_ADDR);
    eth_debug("ETH: HPS Memory:    0x%08X\n", ETH_SHMEM_ADDR);
    eth_debug("ETH: MAC Address:   %02X:%02X:%02X:%02X:%02X:%02X\n",
           shared_mac[0], shared_mac[1], shared_mac[2],
           shared_mac[3], shared_mac[4], shared_mac[5]);
    eth_debug("ETH: Interface:     %s\n", bridge_interface);
    eth_debug("===============================================\n");
    
    // Set socket to non-blocking
    int flags = fcntl(raw_socket, F_GETFL, 0);
    fcntl(raw_socket, F_SETFL, flags | O_NONBLOCK);
    
    eth_debug("RTL8019 ethernet emulation initialized on interface %s\n", bridge_interface);
}

// Reset HPS-owned ethernet staging/debug state.
void minimig_eth_reset()
{
    eth_debug("ETH: RTL8019 RESET triggered!\n");

    // HPS reset only clears HPS-owned staging/debug state. The FPGA owns the
    // live NE2000 register state and mirrors it back into shared memory.
    struct rtl8019_state state;
    read_eth_state(&state);
    state.tx_packets = 0;
    state.rx_packets = 0;
    state.tx_errors = 0;
    state.rx_errors = 0;

    uint16_t reset_tx_request_seq = eth_read_shared_u16(ETH_TX_REQUEST_SEQ);
    uint16_t reset_tx_complete_seq = eth_read_shared_u16(ETH_TX_COMPLETE_SEQ);
    bool preserve_pending_tx =
        (reset_tx_request_seq != 0) && (reset_tx_request_seq != reset_tx_complete_seq);

    clear_host_rx_queue();

    if (preserve_pending_tx) {
        hps_last_tx_complete_seq = reset_tx_complete_seq;
        eth_debug("ETH: Preserving pending TX request seq=%u across HPS reset\n",
                  reset_tx_request_seq);
    } else {
        hps_last_tx_complete_seq = 0;
        memset(eth_shmem + ETH_TX_BUFFER, 0, ETH_PACKET_BUFFER_SIZE);
        eth_write_shared_u16(ETH_TX_REQUEST_ADDR, 0);
        eth_write_shared_u16(ETH_TX_REQUEST_LEN, 0);
        eth_write_shared_u16(ETH_TX_REQUEST_SEQ, 0);
        eth_write_shared_u16(ETH_TX_COMPLETE_SEQ, 0);
    }

    memset(eth_shmem + ETH_RX_BUFFER, 0, ETH_PACKET_BUFFER_SIZE);
    memset(eth_shmem + ETH_RX_QUEUE_DATA, 0, ETH_RX_QUEUE_SLOTS * ETH_PACKET_BUFFER_SIZE);
    memset(eth_shmem + ETH_RX_QUEUE_LEN, 0, ETH_RX_QUEUE_SLOTS * sizeof(uint16_t));
    write_shared_rx_queue_head(0);
    write_shared_rx_queue_tail(0);

    write_eth_state_stats(&state);
    eth_update_shared_status(0xFFFF, 0);
    eth_update_shared_flags(ETH_FLAG_RESET | ETH_FLAG_RX_AVAIL, 0);
    eth_write_shared_u32(ETH_HPS_SIGNATURE, ETH_HPS_SIGNATURE_MAGIC);
    hps_heartbeat_counter = 0;
    eth_write_shared_u32(ETH_HPS_HEARTBEAT, hps_heartbeat_counter);
}

// Transmit packet to host ethernet
static bool transmit_packet(const struct tx_request* request)
{
    struct rtl8019_state state;
    read_eth_state(&state);
    if (raw_socket < 0) {
        state.tx_errors++;
        write_eth_state_stats(&state);
        return false;
    }

    uint16_t addr = request->addr;
    uint16_t length = request->len;

    if ((request->seq == 0) || (length == 0) || (length > ETH_PACKET_BUFFER_SIZE)) {
        eth_debug("Invalid packet length: %d\n", length);
        state.tx_errors++;
        write_eth_state_stats(&state);
        return false;
    }

    if ((addr < NE_PMEM_START) || ((uint32_t)addr + length > NE_PMEM_END)) {
        eth_debug("Packet exceeds memory bounds\n");
        state.tx_errors++;
        write_eth_state_stats(&state);
        return false;
    }

    // Debug: Show first 32 bytes of transmitted packet
    eth_debug("ETH: Transmitting request seq=%u from addr 0x%04X, length %d bytes:\n",
              request->seq, addr, length);
    eth_debug("ETH: TX Data: ");
    for (int i = 0; i < 32 && i < length; i++) {
        uint8_t byte_val = eth_shmem[ETH_TX_BUFFER + i];
        eth_debug("%02X ", byte_val);
        if ((i + 1) % 16 == 0) eth_debug("\nETH: TX Data: ");
    }
    eth_debug("\n");

    // Send the packet staged by the FPGA background DMA path.
    uint8_t* packet_data = eth_shmem + ETH_TX_BUFFER;
    ssize_t sent = send(raw_socket, packet_data, length, 0);
    if (sent < 0) {
        eth_debug("ETH: Failed to send packet: %s\n", strerror(errno));
        state.tx_errors++;
        write_eth_state_stats(&state);
        return false;
    } else if (sent != length) {
        eth_debug("ETH: Short send: expected %u bytes, sent %zd bytes\n", length, sent);
        state.tx_errors++;
        write_eth_state_stats(&state);
        return false;
    } else {
        eth_debug("ETH: Transmitted packet of %d bytes (total TX: %d)\n", length, state.tx_packets + 1);
        state.tx_packets++;
    }

    write_eth_state_stats(&state);
    return true;
}

// Receive packet from host ethernet
void receive_packet()
{
    uint32_t flags = eth_read_shared_u32(ETH_CTRL_FLAGS);
    struct rtl8019_state state;
    uint8_t rcr;
    uint8_t mac_addr[6];
    read_eth_state(&state);
    if (raw_socket < 0) return;

    if (!rx_path_active(flags)) {
        if (host_rx_queue_count != 0) {
            clear_host_rx_queue();
        }
        drain_disabled_rx_socket();
        return;
    }

    rcr = read_ne_register(0, 0x0C);
    read_shared_mac(mac_addr);

    while (pump_host_rx_queue(&flags, &state)) {
    }

    for (;;) {
        uint8_t buffer[ETH_PACKET_BUFFER_SIZE];
        ssize_t len = recv(raw_socket, buffer, sizeof(buffer), 0);

        if (len <= 0) {
            break;
        }

        // Filter out non-ethernet frames.
        if (len < 14) {
            continue;
        }

        if (len > ETH_PACKET_BUFFER_SIZE) {
            eth_debug("ETH: Dropping oversized RX packet (%zd bytes)\n", len);
            state.rx_errors++;
            continue;
        }

        if ((len < 60) && !(rcr & NE_RCR_AR)) {
            continue;
        }

        // Respect the RTL8019 receive filter so we don't queue the whole LAN.
        bool accept = false;

        if (rcr & NE_RCR_PRO) {
            accept = true;
        }
        else if (memcmp(buffer, "\xFF\xFF\xFF\xFF\xFF\xFF", 6) == 0) {
            accept = (rcr & NE_RCR_AB) != 0;
        }
        else if (buffer[0] & 0x01) {
            accept = (rcr & NE_RCR_AM) && multicast_hash_match(buffer);
        }
        else if (memcmp(buffer, mac_addr, 6) == 0) {
            accept = true;
        }

        if (!accept) {
            continue;
        }

        uint16_t packet_len = (uint16_t)len;

        if (enqueue_shared_rx_packet(buffer, packet_len, &flags, &state)) {
        } else if (!enqueue_host_rx_packet(buffer, packet_len)) {
            eth_debug("ETH: RX software queue full, dropping packet of %u bytes\n", packet_len);
            state.rx_errors++;
        } else {
            eth_debug("ETH: Deferred RX packet of %u bytes in host queue (depth: %u)\n",
                      packet_len, host_rx_queue_count);
        }

        // Debug: Show first 32 bytes of received packet
        eth_debug("ETH: RX Data: ");
        for (int i = 0; i < 32 && i < len; i++) {
            eth_debug("%02X ", buffer[i]);
            if ((i + 1) % 16 == 0) eth_debug("\nETH: RX Data: ");
        }
        eth_debug("\n");
    }

    write_eth_state_stats(&state);
}

// Main polling function
void minimig_eth_poll()
{
    static int poll_count = 0;

	if (!eth_shmem)
	{
		eth_shmem = (uint8_t *)shmem_map(ETH_SHMEM_ADDR, ETH_SHMEM_SIZE);
		if (!eth_shmem) eth_shmem = (uint8_t *)-1;
	}
	else if(eth_shmem != (uint8_t *)-1)
	{
        // Check for control flags from FPGA via shared memory
        uint32_t flags = eth_read_shared_u32(ETH_CTRL_FLAGS);
        
        // Update heartbeat counter every poll
        hps_heartbeat_counter++;
        eth_write_shared_u32(ETH_HPS_HEARTBEAT, hps_heartbeat_counter);
        eth_write_shared_u32(ETH_HPS_SIGNATURE, ETH_HPS_SIGNATURE_MAGIC);
        eth_update_shared_status(ETH_STATUS_LINK_UP, 0);
        
        // Reduced monitoring: only log when a new TX mailbox request appears.
        static uint16_t last_tx_request_seq = 0;
        uint16_t tx_request_seq = eth_read_shared_u16(ETH_TX_REQUEST_SEQ);
        bool tx_sequence_pending =
            (tx_request_seq != 0) && (tx_request_seq != hps_last_tx_complete_seq);
        if (tx_request_seq != last_tx_request_seq) {
            eth_debug("ETH: TX mailbox activity detected! seq=%u\n", tx_request_seq);
            last_tx_request_seq = tx_request_seq;
        }
        
        // Debug output every 10000 polls (reduced frequency)
        if (++poll_count % 10000 == 0) {
            struct rtl8019_state state;
            uint8_t cr_reg = read_ne_register(0, 0x00);
            uint8_t curr_reg = read_ne_register(1, 0x07);
            uint8_t bnry_reg = read_ne_register(0, 0x03);   // BNRY: driver's RX read pointer; if it tracks CURR the driver is draining the ring
            uint8_t rcr_reg = read_ne_register(0, 0x0C);   // RCR: bit5=MON(monitor), bit4=PRO, bit3=AM, bit2=AB
            uint8_t isr_reg = read_ne_register(0, 0x07);   // ISR: bit0=PRX bit1=PTX bit3=TXE bit4=OVW bit6=RDC bit7=RST
            uint8_t imr_reg = read_ne_register(0, 0x0F);   // IMR enable mask; (ISR & IMR)!=0 drives the X-Surf IRQ
            uint16_t status = eth_read_shared_u16(ETH_CTRL_STATUS);
            uint32_t raw_cr_word = eth_read_shared_u32(ETH_CTRL_REGS);
            uint16_t tx_complete_seq = eth_read_shared_u16(ETH_TX_COMPLETE_SEQ);
            read_eth_state(&state);

            // Read enabled status from shared memory. RX_ACTIVE in the FPGA
            // status word (bit 0x2000) reflects receiver_active = rx_poll &&
            // CR.STA && !RCR.MON; print RCR + that bit to diagnose why RX may be
            // off while the NIC is enabled.
            bool enabled = (flags & ETH_FLAG_ENABLED) != 0;
            bool rx_active = (status & 0x2000) != 0;

            eth_debug("ETH: Poll #%d, flags=0x%08X, status=0x%04X, enabled=%d, rxact=%d, CR=0x%02X, RCR=0x%02X, ISR=0x%02X, IMR=0x%02X, rawCR=0x%08X, CURR=0x%02X, BNRY=0x%02X, P=%u, TX:%d, RX:%d, TXSEQ:%u/%u, HB:%d\n",
                   poll_count, flags, status, enabled, rx_active, cr_reg, rcr_reg, isr_reg, imr_reg, raw_cr_word,
                   curr_reg, bnry_reg, state.current_page, state.tx_packets, state.rx_packets,
                   tx_request_seq, tx_complete_seq, hps_heartbeat_counter);
            //minimig_eth_test();
        }
        
        // FPGA handles all register management directly via shared memory

        // Handle transmit request
        if ((flags & ETH_FLAG_TX_REQ) || tx_sequence_pending) {
            struct tx_request request = read_shared_tx_request();
            if ((request.seq != 0) && (request.seq != hps_last_tx_complete_seq)) {
                eth_update_shared_status(ETH_STATUS_TX_OK | ETH_STATUS_TX_ERR, 0);
                bool tx_ok = transmit_packet(&request);
                eth_write_shared_u16(ETH_TX_COMPLETE_SEQ, request.seq);
                hps_last_tx_complete_seq = request.seq;
                eth_update_shared_status(ETH_STATUS_TX_OK | ETH_STATUS_TX_ERR,
                                         tx_ok ? ETH_STATUS_TX_OK : ETH_STATUS_TX_ERR);
            } else if (request.seq == hps_last_tx_complete_seq) {
                eth_write_shared_u16(ETH_TX_COMPLETE_SEQ, request.seq);
            }
            flags = eth_update_shared_flags(ETH_FLAG_HPS_ACK_MASK, 0);
        }
        
        // Handle reset request
        if (flags & ETH_FLAG_RESET) {
            minimig_eth_reset();
            flags = eth_read_shared_u32(ETH_CTRL_FLAGS);
        }
        
        // Check for incoming packets
        receive_packet();
    }
}

// Test helper: reports current shared state. The older destructive pattern test
// is intentionally disabled because it corrupts FPGA-owned mirrors.
void minimig_eth_test()
{
    eth_debug("\n===============================================\n");
    eth_debug("ETH: Starting Ethernet Test with Address Patterns...\n");
    eth_debug("===============================================\n");
    
    // Initialize shared memory if needed
    if (!eth_shmem) {
        eth_shmem = (uint8_t *)shmem_map(ETH_SHMEM_ADDR, ETH_SHMEM_SIZE);
        if (!eth_shmem) eth_shmem = (uint8_t *)-1;
    }
    
    if (eth_shmem == (uint8_t *)-1) {
        eth_debug("  FAIL: Cannot map shared memory at 0x%08X\n", ETH_SHMEM_ADDR);
        return;
    }

    {
        uint8_t shared_mac[6];
        uint32_t flags = eth_read_shared_u32(ETH_CTRL_FLAGS);
        struct rtl8019_state state;

        read_shared_mac(shared_mac);
        read_eth_state(&state);

        eth_debug("ETH TEST: destructive shared-memory pattern mode is disabled.\n");
        eth_debug("  Flags: 0x%08X\n", flags);
        eth_debug("  MAC:   %02X:%02X:%02X:%02X:%02X:%02X\n",
               shared_mac[0], shared_mac[1], shared_mac[2],
               shared_mac[3], shared_mac[4], shared_mac[5]);
        eth_debug("  Curr page: %u, enabled: %u, TX stats: %u, RX stats: %u\n",
               state.current_page, (flags & ETH_FLAG_ENABLED) ? 1 : 0,
               state.tx_packets, state.rx_packets);
        eth_debug("  Use extra/xsurftest.asm and ABI consistency checks for active validation.\n");
        return;
    }
    
    eth_debug("ETH TEST: Reading previous values and writing address-decodable patterns\n");
    eth_debug("  Base HPS Address: 0x%08X\n", ETH_SHMEM_ADDR);
    //eth_debug("  Shared Offset:    0x%04X\n", ETH_SHMEM_OFFSET);
    eth_debug("  Amiga Base:       0x%08X\n", ETH_BOARD_ADDR);
    
    // Read previous values but don't display yet
    // We'll only show them if they differ from the new test patterns
    
    // Region 1: Control Flags
    uint32_t prev_flags = eth_read_shared_u32(ETH_CTRL_FLAGS);
    uint32_t expected_flags = 0x01000000 | ETH_CTRL_FLAGS;
    
    // Region 2: Control Registers - Store first 8 and last 2 for comparison
    uint32_t prev_regs[18];
    for (int i = 0; i < 18; i++) {
        prev_regs[i] = eth_read_shared_u32(ETH_CTRL_REGS + i*4);
    }
    
    // Region 3: MAC Address
    uint8_t prev_mac[6];
    eth_read_shared_mem(ETH_CTRL_MAC, prev_mac, 6);
    uint8_t expected_mac[6] = {0x03, 0x10, 0x4C, 0xDE, 0xAD, 0xBE};
    
    // Region 4: Heartbeat and Signature
    uint32_t prev_heartbeat = eth_read_shared_u32(ETH_HPS_HEARTBEAT);
    uint32_t prev_signature = eth_read_shared_u32(ETH_HPS_SIGNATURE);
    uint32_t expected_heartbeat = 0x04000000 | ETH_HPS_HEARTBEAT;
    uint32_t expected_signature = ETH_HPS_SIGNATURE_MAGIC;
    
    // Region 5-7: Buffer patterns
    uint32_t prev_tx = eth_read_shared_u32(ETH_TX_BUFFER);
    uint32_t prev_rx = eth_read_shared_u32(ETH_RX_BUFFER);
    uint32_t prev_ne = eth_read_shared_u32(ETH_NE_MEMORY);
    uint32_t expected_tx = 0x05000000 | ETH_TX_BUFFER;
    uint32_t expected_rx = 0x06000000 | ETH_RX_BUFFER;
    uint32_t expected_ne = 0x07000000 | ETH_NE_MEMORY;
    
    // Check if any values need to be shown (differ from expected)
    bool has_changes = false;
    has_changes |= (prev_flags != expected_flags);
    has_changes |= (prev_signature != expected_signature);
    has_changes |= (prev_tx != expected_tx);
    has_changes |= (prev_rx != expected_rx);
    has_changes |= (prev_ne != expected_ne);
    has_changes |= (memcmp(prev_mac, expected_mac, 6) != 0);
    
    // Check registers for changes
    for (int i = 0; i < 18; i++) {
        uint32_t expected_reg = 0x02000000 | (i << 16) | (ETH_CTRL_REGS + i*4);
        has_changes |= (prev_regs[i] != expected_reg);
    }
    
    if (has_changes) {
        eth_debug("\n--- PREVIOUS VALUES (showing only changed items) ---\n");
        
        // Show only changed values
        if (prev_flags != expected_flags) {
            eth_debug("  [0x%04X] Control Flags     = 0x%08X (was) -> 0x%08X (new)\n", 
                   ETH_CTRL_FLAGS, prev_flags, expected_flags);
        }
        
        // Show changed registers
        bool reg_header_shown = false;
        for (int i = 0; i < 18; i++) {
            uint32_t expected_reg = 0x02000000 | (i << 16) | (ETH_CTRL_REGS + i*4);
            if (prev_regs[i] != expected_reg) {
                if (!reg_header_shown) {
                    eth_debug("  Control Registers (changed):\n");
                    reg_header_shown = true;
                }
                eth_debug("    [0x%04X] Reg[%02d] = 0x%08X -> 0x%08X\n", 
                       ETH_CTRL_REGS + i*4, i, prev_regs[i], expected_reg);
            }
        }
        
        // Show MAC if changed
        if (memcmp(prev_mac, expected_mac, 6) != 0) {
            eth_debug("  [0x%04X] MAC Address       = %02X:%02X:%02X:%02X:%02X:%02X -> %02X:%02X:%02X:%02X:%02X:%02X\n",
                   ETH_CTRL_MAC, 
                   prev_mac[0], prev_mac[1], prev_mac[2], prev_mac[3], prev_mac[4], prev_mac[5],
                   expected_mac[0], expected_mac[1], expected_mac[2], expected_mac[3], expected_mac[4], expected_mac[5]);
        }
        
        // Show heartbeat/signature if changed
        if (prev_heartbeat != expected_heartbeat) {
            eth_debug("  [0x%04X] Heartbeat         = 0x%08X -> 0x%08X\n", 
                   ETH_HPS_HEARTBEAT, prev_heartbeat, expected_heartbeat);
        }
        if (prev_signature != expected_signature) {
            eth_debug("  [0x%04X] Signature         = 0x%08X -> 0x%08X\n", 
                   ETH_HPS_SIGNATURE, prev_signature, expected_signature);
        }
        
        // Show buffers if changed
        if (prev_tx != expected_tx) {
            eth_debug("  [0x%04X] TX Buffer         = 0x%08X -> 0x%08X\n", 
                   ETH_TX_BUFFER, prev_tx, expected_tx);
        }
        if (prev_rx != expected_rx) {
            eth_debug("  [0x%04X] RX Buffer         = 0x%08X -> 0x%08X\n", 
                   ETH_RX_BUFFER, prev_rx, expected_rx);
        }
        if (prev_ne != expected_ne) {
            eth_debug("  [0x%04X] NE2000 Memory     = 0x%08X -> 0x%08X\n", 
                   ETH_NE_MEMORY, prev_ne, expected_ne);
        }
    } else {
        eth_debug("\n--- NO CHANGES DETECTED (test patterns already present) ---\n");
    }
    
    eth_debug("\n--- WRITING NEW TEST PATTERNS ---\n");
    
    // Write recognizable patterns to each memory region
    // Pattern: 0xAABBCCDD where AA=region_id, BB=subregion, CC/DD=offset_encoded
    
    // Region 1: Control Flags (0x1000)
    uint32_t pattern = 0x01000000 | ETH_CTRL_FLAGS;  // Region 1, offset encoded
    eth_write_shared_u32(ETH_CTRL_FLAGS, pattern);
    eth_debug("  [0x%04X] Control Flags     = 0x%08X (new) (Amiga: 0x%06X)\n", 
           ETH_CTRL_FLAGS, pattern, ETH_BOARD_ADDR +ETH_CTRL_FLAGS);
    
    // Region 2: Control Registers (0x1004-0x104B) - Now 18 registers (72 bytes)
    eth_debug("  Writing 18 control registers (72 bytes):\n");
    for (int i = 0; i < 18; i++) {
        pattern = 0x02000000 | (i << 16) | (ETH_CTRL_REGS + i*4);
        eth_write_shared_u32(ETH_CTRL_REGS + i*4, pattern);
        if (i < 8 || i >= 16) {  // Show first 8 and last 2 (extended registers)
            eth_debug("    [0x%04X] Reg[%02d] = 0x%08X (new)\n", 
                   ETH_CTRL_REGS + i*4, i, pattern);
        } else if (i == 8) {
            eth_debug("    ... (regs 8-15) ...\n");
        }
    }
    eth_debug("  [0x%04X] Control Regs[0-17] = 72 bytes total (Amiga: 0x%06X)\n", 
           ETH_CTRL_REGS, ETH_BOARD_ADDR +ETH_CTRL_REGS);
    
    // Region 3: MAC Address (0x1024)
    uint8_t test_mac[6] = {0x03, 0x10, 0x4C, 0xDE, 0xAD, 0xBE};
    eth_write_shared_mem(ETH_CTRL_MAC, test_mac, 6);
    eth_debug("  [0x%04X] MAC Address       = 03:10:4C:DE:AD:BE (Amiga: 0x%06X)\n",
           ETH_CTRL_MAC, ETH_BOARD_ADDR +ETH_CTRL_MAC);
    
    // Region 4: Heartbeat and Signature
    pattern = 0x04000000 | ETH_HPS_HEARTBEAT;
    eth_write_shared_u32(ETH_HPS_HEARTBEAT, pattern);
    eth_write_shared_u32(ETH_HPS_SIGNATURE, ETH_HPS_SIGNATURE_MAGIC);
    eth_debug("  [0x%04X] Heartbeat         = 0x%08X (Amiga: 0x%06X)\n",
           ETH_HPS_HEARTBEAT, pattern, ETH_BOARD_ADDR +ETH_HPS_HEARTBEAT);
    eth_debug("  [0x%04X] Signature         = 0x%08X (Amiga: 0x%06X)\n",
           ETH_HPS_SIGNATURE, ETH_HPS_SIGNATURE_MAGIC, ETH_BOARD_ADDR +ETH_HPS_SIGNATURE);
    
    // Region 5: TX Buffer (0x2000) - Write address pattern every 256 bytes
    eth_debug("  [0x%04X] TX Buffer patterns...\n", ETH_TX_BUFFER);
    for (int i = 0; i < 1500; i += 256) {
        pattern = 0x05000000 | (ETH_TX_BUFFER + i);
        eth_write_shared_u32(ETH_TX_BUFFER + i, pattern);
        if (i < 512) {  // Only show first few
            eth_debug("    [+0x%04X] = 0x%08X (Amiga: 0x%06X)\n", 
                   i, pattern, ETH_BOARD_ADDR +ETH_TX_BUFFER + i);
        }
    }
    
    // Region 6: RX Buffer (0x2600) - Write address pattern every 256 bytes
    eth_debug("  [0x%04X] RX Buffer patterns...\n", ETH_RX_BUFFER);
    for (int i = 0; i < 1500; i += 256) {
        pattern = 0x06000000 | (ETH_RX_BUFFER + i);
        eth_write_shared_u32(ETH_RX_BUFFER + i, pattern);
        if (i < 512) {  // Only show first few
            eth_debug("    [+0x%04X] = 0x%08X (Amiga: 0x%06X)\n", 
                   i, pattern, ETH_BOARD_ADDR +ETH_RX_BUFFER + i);
        }
    }
    
    // Region 7: NE2000 Memory (0x3000) - Write pattern every 1KB
    eth_debug("  [0x%04X] NE2000 Memory patterns...\n", ETH_NE_MEMORY);
    for (int i = 0; i < 16384; i += 1024) {
        pattern = 0x07000000 | ((ETH_NE_MEMORY + i) & 0xFFFF);
        eth_write_shared_u32(ETH_NE_MEMORY + i, pattern);
        if (i < 4096) {  // Only show first 4KB
            eth_debug("    [+0x%04X] = 0x%08X (Amiga: 0x%06X)\n", 
                   i, pattern, ETH_BOARD_ADDR +ETH_NE_MEMORY + i);
        }
    }
    
    // Region 8: Debug Info (0x7000)
    pattern = 0x08000000 | ETH_DEBUG_INFO;
    eth_write_shared_u32(ETH_DEBUG_INFO, pattern);
    eth_debug("  [0x%04X] Debug Info        = 0x%08X (Amiga: 0x%06X)\n",
           ETH_DEBUG_INFO, pattern, ETH_BOARD_ADDR +ETH_DEBUG_INFO);
    
    // Region 9: Future Use (0x9000)
    pattern = 0x09000000 | ETH_FUTURE_USE;
    eth_write_shared_u32(ETH_FUTURE_USE, pattern);
    eth_debug("  [0x%04X] Future Use        = 0x%08X (Amiga: 0x%06X)\n",
           ETH_FUTURE_USE, pattern, ETH_BOARD_ADDR +ETH_FUTURE_USE);
    
    eth_debug("\n--- VERIFICATION ---\n");
    
    // Verify patterns were written correctly
    bool all_pass = true;
    
    // Verify Control Flags
    uint32_t readback = eth_read_shared_u32(ETH_CTRL_FLAGS);
    if (readback != expected_flags) {
        eth_debug("  Control Flags: FAIL (expected 0x%08X, got 0x%08X)\n", expected_flags, readback);
        all_pass = false;
    }
    
    // Verify Registers
    bool reg_fail = false;
    for (int i = 0; i < 18; i++) {
        uint32_t reg_val = eth_read_shared_u32(ETH_CTRL_REGS + i*4);
        uint32_t expected = 0x02000000 | (i << 16) | (ETH_CTRL_REGS + i*4);
        if (reg_val != expected) {
            if (!reg_fail) {
                eth_debug("  Register verification failures:\n");
                reg_fail = true;
            }
            eth_debug("    Reg[%02d]: FAIL (expected 0x%08X, got 0x%08X)\n", i, expected, reg_val);
            all_pass = false;
        }
    }
    
    // Verify MAC address
    uint8_t new_mac[6];
    eth_read_shared_mem(ETH_CTRL_MAC, new_mac, 6);
    if (memcmp(new_mac, expected_mac, 6) != 0) {
        eth_debug("  MAC Address: FAIL (expected %02X:%02X:%02X:%02X:%02X:%02X, got %02X:%02X:%02X:%02X:%02X:%02X)\n",
               expected_mac[0], expected_mac[1], expected_mac[2], expected_mac[3], expected_mac[4], expected_mac[5],
               new_mac[0], new_mac[1], new_mac[2], new_mac[3], new_mac[4], new_mac[5]);
        all_pass = false;
    }
    
    // Verify Signature
    readback = eth_read_shared_u32(ETH_HPS_SIGNATURE);
    if (readback != expected_signature) {
        eth_debug("  Signature: FAIL (expected 0x%08X, got 0x%08X)\n", expected_signature, readback);
        all_pass = false;
    }
    
    // Verify Buffers
    uint32_t new_tx = eth_read_shared_u32(ETH_TX_BUFFER);
    uint32_t new_rx = eth_read_shared_u32(ETH_RX_BUFFER);
    uint32_t new_ne = eth_read_shared_u32(ETH_NE_MEMORY);
    
    if (new_tx != expected_tx) {
        eth_debug("  TX Buffer: FAIL (expected 0x%08X, got 0x%08X)\n", expected_tx, new_tx);
        all_pass = false;
    }
    if (new_rx != expected_rx) {
        eth_debug("  RX Buffer: FAIL (expected 0x%08X, got 0x%08X)\n", expected_rx, new_rx);
        all_pass = false;
    }
    if (new_ne != expected_ne) {
        eth_debug("  NE Memory: FAIL (expected 0x%08X, got 0x%08X)\n", expected_ne, new_ne);
        all_pass = false;
    }
    
    if (all_pass) {
        eth_debug("  All memory regions verified successfully - PASS\n");
    } else {
        eth_debug("  Some memory regions failed verification - see above\n");
    }
    
    // Test 2: Check register initialization - read from shared memory
    eth_debug("\nETH TEST 2: Register check\n");
    uint8_t cr_reg = eth_read_shared_reg(ETH_CTRL_REGS + (0x00 * 4));
    uint8_t isr_reg = eth_read_shared_reg(ETH_CTRL_REGS + (0x07 * 4));
    eth_debug("  CR  (0x00) = 0x%02X (pattern: 0x%08X)\n", cr_reg, 0x02000000 | ETH_CTRL_REGS);
    eth_debug("  ISR (0x07) = 0x%02X (pattern: 0x%08X)\n", isr_reg, 0x02070000 | (ETH_CTRL_REGS + 0x1C));
    
    // Read MAC address from shared memory
    uint8_t shared_mac[6];
    eth_read_shared_mem(ETH_CTRL_MAC, shared_mac, 6);
    eth_debug("  MAC = %02X:%02X:%02X:%02X:%02X:%02X\n",
           shared_mac[0], shared_mac[1], shared_mac[2],
           shared_mac[3], shared_mac[4], shared_mac[5]);
    
    // Test 3: Check control flags
    eth_debug("\nETH TEST 3: Control flags\n");
    uint32_t flags = eth_read_shared_u32(ETH_CTRL_FLAGS);
    eth_debug("  Flags = 0x%08X\n", flags);
    eth_debug("  - Reset:    %s\n", (flags & ETH_FLAG_RESET) ? "YES" : "NO");
    eth_debug("  - TX Req:   %s\n", (flags & ETH_FLAG_TX_REQ) ? "YES" : "NO");
    eth_debug("  - RX Avail: %s\n", (flags & ETH_FLAG_RX_AVAIL) ? "YES" : "NO");
    eth_debug("  - IRQ:      %s\n", (flags & ETH_FLAG_IRQ) ? "YES" : "NO");
    eth_debug("  - Enabled:  %s\n", (flags & ETH_FLAG_ENABLED) ? "YES" : "NO");
    
    // Test 4: Socket status
    eth_debug("ETH TEST 4: Network socket\n");
    if (raw_socket >= 0) {
        eth_debug("  PASS: Raw socket is open (fd=%d)\n", raw_socket);
        eth_debug("  Interface: %s\n", bridge_interface);
    } else {
        eth_debug("  FAIL: No raw socket available\n");
    }
    
    eth_debug("===============================================\n");
    eth_debug("ETH: Test Complete\n");
    eth_debug("===============================================\n\n");
}
