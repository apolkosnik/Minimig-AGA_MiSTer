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
#include <linux/filter.h>
#include <ifaddrs.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <time.h>
#include <stdint.h>

#include "minimig_eth.h"
#include "eth_gso.h"

// recv() scratch buffer large enough to hold a fully GRO/LRO-coalesced superframe
// (kernel gso_max ~64KB) so software GSO can re-split it; see the RX intake loop.
#define ETH_RX_JUMBO_SIZE 65600

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


//#define ETH_DEBUG

#ifdef ETH_DEBUG
    #define eth_debug printf
#else
    #define eth_debug(x,...) void()
#endif

// Per-frame trace (the "Enqueued"/"RX Data"/"Transmitting" hex dumps). This runs
// once or several times PER PACKET, so under load it is pure overhead (and on a
// slow console it throttles the very path we are trying to speed up). Leave it
// OFF by default; define ETH_TRACE to restore the verbose per-frame logging.
//#define ETH_TRACE
#ifdef ETH_TRACE
    #define eth_trace printf
#else
    #define eth_trace(x,...) void()
#endif

// Performance summary line. INDEPENDENT of ETH_DEBUG so the once-per-second
// ETHPERF line prints even in a quiet production build (where ETH_DEBUG is off).
// Comment out to silence.
#define ETH_PERF
#ifdef ETH_PERF
    #define eth_perf printf
#else
    #define eth_perf(x,...) void()
#endif

// RX broadcast denoise: a busy LAN floods the Amiga with broadcast traffic
// (SSDP/mDNS/LLMNR/discovery), and every frame interrupts the 68020 and runs
// the TCP/IP stack just to discard it -- stealing CPU from real transfers.
// With this on, broadcast frames are forwarded only when they are actually
// useful to the Amiga (ARP, DHCP/BOOTP, NetBIOS name/datagram, and broadcast
// non-UDP IP); other broadcast floods are dropped on the HPS side. Unicast and
// multicast are unaffected. Comment this out to forward all broadcast as before.
#define ETH_RX_BROADCAST_DENOISE

// RX kernel filter (H4): attach a cBPF program to the raw socket so the kernel
// drops frames the Amiga can't use BEFORE they reach userspace, instead of
// recv()-ing the whole promiscuous LAN and filtering in the daemon. Passes
// unicast to the Amiga's station MAC plus broadcast/multicast (group bit);
// detached automatically while the Amiga driver is promiscuous (RCR.PRO).
// Comment out to recv() everything as before.
#define ETH_RX_KERNEL_FILTER


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

#define ETH_HOST_RX_QUEUE_DEPTH 32   // deeper host-side spill queue for RX bursts

struct host_rx_packet {
    uint16_t len;
    uint8_t data[ETH_PACKET_BUFFER_SIZE];
};

static struct host_rx_packet host_rx_queue[ETH_HOST_RX_QUEUE_DEPTH];
static uint8_t host_rx_queue_head = 0;
static uint8_t host_rx_queue_tail = 0;
static uint8_t host_rx_queue_count = 0;

// ---------------------------------------------------------------------------
// Lightweight throughput instrumentation to find the real HW bottleneck.
// Counts are free; one summary line is emitted ~once per second. The defer/drop
// counters are the key signal: they only grow when the FPGA RX queue is full,
// i.e. the Amiga (data-port PIO + FPGA bg) cannot drain as fast as the host
// delivers -> the bottleneck is the Amiga/FPGA side, not this daemon.
// ---------------------------------------------------------------------------
static uint64_t g_perf_rx_frames = 0, g_perf_rx_bytes = 0;
static uint64_t g_perf_rx_defer  = 0, g_perf_rx_drop  = 0;
// RX frames dropped for exceeding max Ethernet (1518B). >0 means the host NIC is
// still coalescing receives (GRO/LRO) into oversized superframes the NE2000 ring
// cannot hold -- a server-dependent corruption that never occurs on real X-Surf HW.
static uint64_t g_perf_rx_oversize = 0;
// Segments produced by software-GSO re-segmentation of GRO/LRO-coalesced
// superframes (keeps host receive offload on; see eth_gso.h / the RX intake).
static uint64_t g_perf_rx_seg = 0;
// Frames whose IPv4/L4 checksums were normalized in software before delivery to
// the Amiga.  This makes host RX offload/GRO checksum metadata irrelevant to the
// emulated NIC: the Amiga always sees ordinary wire-valid Ethernet frames.
static uint64_t g_perf_rx_csum_fix = 0;
// Valid short frames Linux delivered with Ethernet padding stripped and we
// restored to the 60-byte minimum before handing them to the emulated RTL8019.
static uint64_t g_perf_rx_padded = 0;
// AF_PACKET echo copies that Linux reports for frames transmitted by this host.
// Feeding these back into the emulated NIC causes duplicate packets, e.g. ping
// reporting (DUP!).
static uint64_t g_perf_rx_echo_drop = 0;
// Accepted RX frames that were exact near-immediate duplicates at the raw socket.
// These are usually bridge/promisc recirculation copies presented as inbound
// PACKET_HOST, so PACKET_OUTGOING filtering does not catch them.
static uint64_t g_perf_rx_dup_drop = 0;
static uint64_t g_perf_tx_frames = 0, g_perf_tx_bytes = 0;
static uint64_t g_perf_polls     = 0;
static uint64_t g_perf_bcast_drop = 0;   // broadcast frames denoised (not forwarded)
// Amiga's advertised TCP receive window, observed on its outgoing ACKs. This is
// the download throughput cap (throughput ~= rwnd / RTT); g_perf_tx_win_min is
// reset each ETHPERF interval, g_perf_tx_zerowin counts zero-window stalls.
static uint32_t g_perf_tx_win_min  = 0xFFFFFFFF;
static uint32_t g_perf_tx_win_last = 0;
static uint64_t g_perf_tx_zerowin  = 0;
// TX frames the FPGA staged (TX_REQUEST_SEQ bumped) that the daemon never got to
// send because the single shared TX buffer was overwritten before it drained it.
// A download's ACK storm is the suspected trigger; lost ACKs -> server RTO/abort.
static uint64_t g_perf_tx_miss     = 0;
// Download loss signal: the daemon sniffs the wire, so it sees the SERVER's TCP
// segments to the Amiga. When the server RE-sends data already past the flow's
// high-water mark, the server believes a segment was lost -> that is REAL RX
// loss wherever it happened (kernel, HPS->FPGA hand-off, or the Amiga). This is
// the one signal sockDrop/ovwDrop/defer/drop cannot show: a delivered-but-
// corrupt frame is dropped by the Amiga's TCP (bad checksum) without tripping
// any drop counter, yet the server still retransmits. retx>0 during a download
// == frames are being lost; retx==0 with low KB/s == pure window/RTT dynamics.
static uint64_t g_perf_rx_retx     = 0;
// Splits the cause of retx: counts the Amiga's OUTGOING duplicate ACKs (same ack
// number repeated on a flow). A dup-ACK means the Amiga's TCP received an
// out-of-order segment with a hole, i.e. a segment was LOST on the way IN -- so
// dupAck>0 alongside retx == the FPGA/daemon delivery is still dropping/corrupting
// a segment (data loss). retx>0 with dupAck~0 == the Amiga's ACKs aren't reaching
// the server (ACK loss) or pure RTO. This tells us which half of the path to fix.
static uint64_t g_perf_dup_ack     = 0;
// Forward seq holes the DAEMON itself sees on the inbound stream: a segment
// arrived ahead of the expected next byte, so the bytes between were never
// recv()'d. With sockDrop=0 that means they were lost UPSTREAM of us (wire /
// switch / sender) -- it EXONERATES the FPGA path. rxGap~0 while dupAck>0 means
// the daemon got everything but the Amiga didn't => loss is in OUR delivery.
static uint64_t g_perf_rx_gap      = 0;
// Daemon send() failures: the Amiga's outgoing frame (often an ACK) never left
// the HPS. txDrop>0 with retx>0 and dupAck~0 == ACKs lost on egress, not on RX.
static uint64_t g_perf_tx_drop     = 0;
// Integrity probe: the FPGA bg publishes a running 16-bit byte-sum of every RX
// payload byte it writes into the ring (sync slot 40, shm 0x110A, byte-swapped)
// AND a count of frames it has delivered (sync slot 41, shm 0x110C). We keep the
// same running sum + count for the frames we enqueue, and compare the two sums
// ONLY when the bg's count equals ours (it has delivered exactly the frames we
// enqueued) and is stable across the read -- then both sums cover the identical
// frame set, so an inequality is a real shm->ring (bg write) corruption rather
// than a reset/origin offset. A match here while retxDat>0 proves the loss is
// DOWNSTREAM of the bg write (data-port read or the Amiga), not FPGA delivery.
static uint64_t g_perf_deliv_bad   = 0;
static uint32_t g_sent_csum_run    = 0;   // daemon running byte-sum (16-bit)
static uint16_t g_sent_frame_count = 0;   // daemon RX frames enqueued (count tag, matches bg slot 41)
static int      g_csum_calibrated  = 0;   // origin-aligned to the bg counters on first caught-up sample
static uint16_t g_perf_csum_bg     = 0;   // last bg running byte-sum read (for the ETHPERF line)
static uint16_t g_perf_cnt_bg      = 0;   // last bg frame count read
static uint16_t g_perf_deliv_bad_frame = 0; // bg frame count at the first detected divergence
static int      g_rx_verify        = 0;   // OFF by default (the slot read-back is a heavy O(len) uncached diagnostic
                                          // that perturbs the RX hot path); set MINIMIG_ETH_RX_VERIFY=1 to enable
static uint64_t g_perf_wr_bad      = 0;   // frames whose slot read-back != intended (the uncached COPY dropped bytes)
static uint32_t g_rx_settle_us     = 0;   // MINIMIG_ETH_RX_SETTLE_US: spin this long after the payload write, before
                                          // advancing the tail, so the slot commits to SDRAM for the f2sdram read port
                                          // (closes the HPS->FPGA cross-port visibility race wrBad=0 proved is the cause)
// Delivery PACING (burst-overrun test): a real 10 Mbit NE2000 spaces frames ~1.2ms
// apart; our bg delivers a window's worth (~3 segments) back-to-back in us, which
// may overrun Roadshow's TCP input -> ~half the frames dropped -> retxDat -> the
// 301-vs-1026 kbit/s gap. Enforce a MINIMUM interval between consecutive RX
// deliveries (tail advances): throttles the microbursts but adds ZERO latency to
// already-spaced frames (between bursts / the fast regime), so it can only help.
// Tune ETH_RX_PACE_US (sweep e.g. 400 / 800 / 1500); 0 disables. Env override:
// MINIMIG_ETH_RX_PACE_US.
#define ETH_RX_PACE_US 0
static uint32_t g_rx_pace_us       = ETH_RX_PACE_US;
// Read-side probe (FPGA slots 42/43): ringWr = bytes the bg WROTE into the NE2000
// ring; dpRd = bytes the 68k READ back via the data port. Equal at a ring drain
// iff the 68k reads the ring intact. rdBad counts drains where they diverged.
static uint16_t g_perf_ring_wr     = 0;
static uint16_t g_perf_dp_rd       = 0;
static uint64_t g_perf_rd_bad      = 0;
// Per-frame read-corruption probe (FPGA slot 44): count of even-length payload
// reads where the 68k pulled different bytes than the bg wrote. >0 = data-port
// READ corruption PROVEN; ==0 = the 68k reads the ring intact (loss is Amiga/TCP).
static uint16_t g_perf_rd_corrupt  = 0;
static uint16_t g_perf_rd_checked  = 0;   // payload reads compared; 0 => probe never armed (rdCorrupt inconclusive)
static uint16_t g_perf_rd_bad_exp  = 0;   // last mismatched expected payload checksum
static uint16_t g_perf_rd_bad_act  = 0;   // last mismatched actual payload checksum
// WRITE/storage read-back probe (FPGA slots 46/47): the bg re-reads each 1-page
// frame's payload through PORT A and compares it to the checksum it intended to
// write. rbBad>0 = the M10K WRITE/storage dropped/corrupted bytes; rbBad==0 while
// the 68k still sees corruption isolates the fault to the port-B READ path.
static uint16_t g_perf_rb_bad      = 0;   // frames where port-A read-back != frame_wr_csum
static uint16_t g_perf_rb_csum_run = 0;   // running port-A read-back byte-sum, all probed frames
static uint16_t g_perf_tx_mirror_csum   = 0; // TXM: Amiga data-port writes captured into FPGA mirror
static uint16_t g_perf_tx_mirror_frames = 0;
static uint16_t g_perf_tx_drain_csum    = 0; // TXD: FPGA mirror drained into ETH_TX_BUFFER
static uint16_t g_perf_tx_drain_frames  = 0;
static uint16_t g_perf_tx_mirror_bytes  = 0;
static uint16_t g_perf_tx_drain_bytes   = 0;
static uint16_t g_tx_hps_csum_run       = 0; // TXH: HPS bytes read from ETH_TX_BUFFER
static uint16_t g_tx_hps_frame_count    = 0;
static uint16_t g_tx_hps_byte_count     = 0;
// DIAGNOSTIC: outgoing TX frames (usually Amiga ACKs) whose IP or TCP checksum is
// INVALID as staged in shm. Such a frame is send()'d on the wire but silently
// dropped by the peer's stack on checksum -> the server keeps retransmitting
// (retx/retxAck/retxDat) while NO drop counter trips and txMiss/txDrop stay 0.
// txBadCsum>0 during a download proves the ACK CONTENT is corrupted (TX-buffer
// reuse race / dual-port read-during-write of packet RAM page 0x40), not merely
// delayed -- which the sub-ms FPGA/daemon scheduling delays cannot explain at a
// ~200ms RTO. This is observe-only: the frame is still sent unchanged.
static uint64_t g_perf_tx_bad_csum = 0;
// Outgoing frames whose IPv4/L4 checksums were written in software before
// AF_PACKET send().  Packet sockets do not provide CHECKSUM_PARTIAL metadata, so
// never rely on eth0 TX checksum offload to finish an Amiga frame.
static uint64_t g_perf_tx_csum_fix = 0;
// DIAGNOSTIC (HPS-bottleneck probe): is the daemon itself slowing RX? Per ETHPERF
// interval we record the worst-case microseconds spent in one receive_packet()
// call (recvMaxUs), the most RX frames drained in one such call (recvFrMax), and
// the worst single-frame shm copy time (copyMaxUs). If the HPS were the cap,
// recvMaxUs would be large (ms) and TX(ACK) would stall behind it; small values
// confirm the HPS keeps up and the bottleneck is downstream (Amiga). Observe-only.
static uint64_t g_perf_recv_us_max    = 0;
static uint64_t g_perf_recv_frames_max = 0;
static uint64_t g_perf_rx_copy_us_max = 0;
static inline uint64_t eth_mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

#define ETH_RX_DEDUPE_SLOTS     32
#define ETH_RX_DEDUPE_WINDOW_US 20000

struct eth_rx_dedupe_entry {
    uint64_t t_us;
    uint32_t hash;
    uint32_t len;
    uint16_t ethertype;
};

static struct eth_rx_dedupe_entry g_rx_dedupe[ETH_RX_DEDUPE_SLOTS];
static uint8_t g_rx_dedupe_next = 0;
static uint32_t g_rx_dedupe_window_us = ETH_RX_DEDUPE_WINDOW_US;

static uint32_t eth_rx_frame_hash(const uint8_t *data, size_t len)
{
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        h ^= data[i];
        h *= 16777619u;
    }
    return h ? h : 1u;
}

static bool eth_rx_is_near_duplicate(const uint8_t *data, size_t len)
{
    if (g_rx_dedupe_window_us == 0 || len < 14) {
        return false;
    }

    uint64_t now = eth_mono_us();
    uint32_t hash = eth_rx_frame_hash(data, len);
    uint16_t ethertype = ((uint16_t)data[12] << 8) | data[13];

    for (unsigned i = 0; i < ETH_RX_DEDUPE_SLOTS; i++) {
        const struct eth_rx_dedupe_entry *e = &g_rx_dedupe[i];
        if (e->t_us != 0 &&
            e->hash == hash &&
            e->len == len &&
            e->ethertype == ethertype &&
            (now - e->t_us) <= g_rx_dedupe_window_us) {
            return true;
        }
    }

    struct eth_rx_dedupe_entry *slot = &g_rx_dedupe[g_rx_dedupe_next];
    slot->t_us = now;
    slot->hash = hash;
    slot->len = (uint32_t)len;
    slot->ethertype = ethertype;
    g_rx_dedupe_next = (uint8_t)((g_rx_dedupe_next + 1) % ETH_RX_DEDUPE_SLOTS);
    return false;
}

// Daemon-side TCP receive-window CLAMP. The download bottleneck is NOT loss
// (Amiga reports 0 dropped / 0 overruns, rxGap=0, txBadCsum=0): it is the slow
// 68020 ACK pacing racing the server's ~200ms RTO while the Amiga advertises a
// huge 65535 window, so the server runs far ahead and RTO-retransmits the
// un-acked backlog (~2/3 of the bandwidth wasted). Rewriting the window the Amiga
// advertises in its outgoing TCP segments down to ETH_TX_WINDOW_CLAMP bytes (and
// recomputing the TCP checksum) makes the server pace itself to what the Amiga
// can drain, shrinking the un-acked backlog and the RTO bursts. 8KB keeps the
// pipe full (8KB/30ms RTT = ~266 KB/s ceiling, far above the ~40 KB/s the Amiga
// moves) while bounding the backlog under one RTO. 0 disables. NOTE: assumes no
// TCP window scaling -- valid here since amigaWin maxes at 65535 (scale 0).
#define ETH_TX_WINDOW_CLAMP 0
//32768
static uint64_t g_perf_tx_win_clamped = 0;

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

static void eth_shared_readback_fence(uint32_t offset)
{
    if (!eth_shmem || eth_shmem == (uint8_t *)-1 || offset >= ETH_SHMEM_SIZE) {
        return;
    }

    volatile uint8_t *shared = (volatile uint8_t *)eth_shmem;
    volatile uint8_t sink = shared[offset];
    (void)sink;
    __sync_synchronize();
}

static void eth_write_shared_rx_payload(uint32_t offset, const uint8_t *data, uint32_t size)
{
    if (!eth_shmem || eth_shmem == (uint8_t *)-1) {
        eth_debug("eth_write_shared_rx_payload: no eth_shmem!\n");
        return;
    }
    if (offset + size > ETH_SHMEM_SIZE) {
        eth_debug("ETH: RX payload write beyond shared memory bounds: offset=0x%X, size=%d\n",
                  offset, size);
        return;
    }

    volatile uint8_t *dst = (volatile uint8_t *)eth_shmem + offset;
    for (uint32_t i = 0; i < size; i++) {
        dst[i] = data[i];
    }
    __sync_synchronize();
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

static bool eth_copy_interface_name(const char *name)
{
    if (!name || !name[0]) {
        return false;
    }

    size_t len = strlen(name);
    if (len >= sizeof(bridge_interface)) {
        return false;
    }

    memcpy(bridge_interface, name, len + 1);
    return true;
}

static bool eth_interface_has_sysfs_file(const char *name, const char *leaf)
{
    char path[128];
    snprintf(path, sizeof(path), "/sys/class/net/%s/%s", name, leaf);
    return access(path, F_OK) == 0;
}

static bool eth_name_has_prefix(const char *name, const char *prefix)
{
    return strncmp(name, prefix, strlen(prefix)) == 0;
}

static bool eth_interface_is_auto_bad(const char *name)
{
    if (eth_interface_has_sysfs_file(name, "bridge") ||
        eth_interface_has_sysfs_file(name, "tun_flags")) {
        return true;
    }

    return eth_name_has_prefix(name, "br-")     ||
           eth_name_has_prefix(name, "docker") ||
           eth_name_has_prefix(name, "veth")   ||
           eth_name_has_prefix(name, "virbr")  ||
           eth_name_has_prefix(name, "tap")    ||
           eth_name_has_prefix(name, "tun");
}

static bool eth_interface_has_afpacket_addr(const char *name)
{
    struct ifaddrs *ifaddr = NULL;
    bool found = false;

    if (getifaddrs(&ifaddr) == -1) {
        return false;
    }

    for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || strcmp(ifa->ifa_name, name) != 0) {
            continue;
        }
        if (ifa->ifa_addr->sa_family == AF_PACKET) {
            found = true;
            break;
        }
    }

    freeifaddrs(ifaddr);
    return found;
}

static bool eth_interface_is_usable(int fd, const char *name)
{
    if (!name || !name[0]) {
        return false;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);

    if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) {
        return false;
    }
    if (!(ifr.ifr_flags & IFF_UP) || (ifr.ifr_flags & IFF_LOOPBACK)) {
        return false;
    }
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) {
        return false;
    }

    return eth_interface_has_afpacket_addr(name);
}

static bool eth_select_bridge_interface(int fd)
{
    const char *env_iface = getenv("MINIMIG_ETH_IFACE");
    if (env_iface && env_iface[0]) {
        if (!eth_copy_interface_name(env_iface)) {
            eth_perf("ETH: MINIMIG_ETH_IFACE='%s' is too long\n", env_iface);
            return false;
        }
        if (!eth_interface_is_usable(fd, bridge_interface)) {
            eth_perf("ETH: MINIMIG_ETH_IFACE='%s' is not a usable UP AF_PACKET interface\n",
                     bridge_interface);
            return false;
        }
        eth_perf("ETH: Using interface %s from MINIMIG_ETH_IFACE\n", bridge_interface);
        return true;
    }

    if (eth_interface_is_usable(fd, bridge_interface)) {
        eth_perf("ETH: Using default interface %s\n", bridge_interface);
        return true;
    }

    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) == -1) {
        return false;
    }

    const char *chosen = NULL;
    for (int pass = 0; pass < 3 && !chosen; pass++) {
        for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_PACKET) {
                continue;
            }
            if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) {
                continue;
            }
            if (!eth_interface_is_usable(fd, ifa->ifa_name)) {
                continue;
            }

            bool has_device = eth_interface_has_sysfs_file(ifa->ifa_name, "device");
            bool auto_bad = eth_interface_is_auto_bad(ifa->ifa_name);
            if (pass == 0 && (!has_device || auto_bad)) {
                continue;
            }
            if (pass == 1 && auto_bad) {
                continue;
            }

            chosen = ifa->ifa_name;
            break;
        }
    }

    bool ok = chosen && eth_copy_interface_name(chosen);
    freeifaddrs(ifaddr);

    if (ok) {
        eth_perf("ETH: Using auto-selected interface %s\n", bridge_interface);
    }
    return ok;
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

// Decide whether a broadcast frame is worth forwarding to the Amiga. Keeps the
// control/discovery traffic the Amiga TCP/IP stack actually needs (ARP, DHCP,
// NetBIOS) and broadcast non-UDP IP; drops the rest (SSDP/mDNS/LLMNR/large
// discovery floods) so they never burn 68020 cycles. data[] is the raw frame.
static bool broadcast_is_essential(const uint8_t* data, uint16_t len)
{
    if (len < 14) return false;
    uint16_t eth_type = (uint16_t)((data[12] << 8) | data[13]);

    if (eth_type == 0x0806) return true;    // ARP - always needed
    if (eth_type != 0x0800) return false;   // non-IP broadcast -> junk

    if (len < 14 + 20) return true;         // too short to parse -> keep (safe)
    uint8_t ihl = (uint8_t)((data[14] & 0x0F) * 4);
    if (ihl < 20) ihl = 20;
    uint8_t proto = data[23];
    if (proto != 17) return true;           // broadcast non-UDP IP (rare) -> keep

    uint32_t udp_off = (uint32_t)(14 + ihl);
    if ((uint32_t)len < udp_off + 4) return true;   // can't read ports -> keep
    uint16_t dport = (uint16_t)((data[udp_off + 2] << 8) | data[udp_off + 3]);

    // Essential broadcast UDP services the Amiga may rely on.
    if (dport == 67 || dport == 68)   return true;   // DHCP / BOOTP
    if (dport == 137 || dport == 138) return true;   // NetBIOS name / datagram

    return false;   // SSDP(1900)/mDNS(5353)/LLMNR(5355)/WS-Discovery/floods -> drop
}

// Extract the TCP advertised receive window from an Amiga-outgoing frame, or -1
// if it is not IPv4/TCP. NOTE: this is the raw 16-bit window field; if the stack
// negotiated window scaling the effective window is larger, but retro stacks
// usually don't, so this is the real receive window in practice.
static int tcp_adv_window(const uint8_t* d, uint16_t len)
{
    if (len < 14 + 20 + 20) return -1;
    if (((d[12] << 8) | d[13]) != 0x0800) return -1;     // not IPv4
    uint8_t ihl = (uint8_t)((d[14] & 0x0F) * 4);
    if (ihl < 20) return -1;
    if (d[23] != 6) return -1;                            // not TCP
    uint32_t tcp = (uint32_t)(14 + ihl);
    if ((uint32_t)len < tcp + 16) return -1;
    return (d[tcp + 14] << 8) | d[tcp + 15];              // TCP window field
}

// Track inbound (server->Amiga) TCP data segments and count retransmissions of
// data we have already seen. A server only resends bytes it believes were lost,
// so a non-zero rate is a direct, ground-truth measurement of RX loss -- the
// thing the drop counters miss when a frame is delivered but corrupt. Tiny
// fixed flow table; signed sequence diff handles 32-bit wrap. A seq ahead of the
// high-water mark just advances it (could be a segment the sniffer missed, not a
// server loss), so only seq BEHIND the mark is counted as a retransmit.
#define ETH_RETX_FLOWS 16
static struct { uint8_t valid; uint32_t key; uint32_t next_seq; } g_retx_flow[ETH_RETX_FLOWS];

// Retransmit CLASSIFIER -- resolves the retx contradiction. A direction-
// INDEPENDENT connection key ties the server->Amiga data flow to the Amiga->
// server ACK flow in one entry: in_seq_hi = highest server data byte seen,
// out_ack_hi = highest ack number the Amiga sent. On a server retransmit (seq
// behind in_seq_hi): if seq < out_ack_hi the Amiga ALREADY ACKed it -> the
// server never got that ACK (ACK-LOSS, retxAck); else the Amiga has NOT ACKed it
// (DATA-LOSS, retxDat). This says directly whether to chase the ACK path or the
// ring->Amiga delivery.
static uint64_t g_perf_retx_ack = 0;   // server resent already-ACKed data -> ACK-loss
static uint64_t g_perf_retx_dat = 0;   // server resent not-yet-ACKed data -> data-loss
#define ETH_CONN_FLOWS 16
static struct {
    uint8_t  valid, have_in, have_ack;
    uint32_t key, in_seq_hi, out_ack_hi;
} g_conn[ETH_CONN_FLOWS];

static inline uint32_t eth_conn_key(uint32_t a1, uint32_t a2, uint16_t p1, uint16_t p2)
{
    uint32_t k = (a1 ^ a2) ^ ((uint32_t)(p1 ^ p2) * 2654435761u);  // commutative -> same both directions
    return k ? k : 1;
}

static void tcp_track_download(const uint8_t* d, uint16_t len)
{
    if (len < 14 + 20) return;
    if (((d[12] << 8) | d[13]) != 0x0800) return;        // IPv4 only
    const uint8_t* ip = d + 14;
    if ((ip[0] >> 4) != 4) return;
    uint16_t ihl = (uint16_t)((ip[0] & 0x0F) * 4);
    if (ihl < 20 || ip[9] != 6) return;                  // TCP only
    if ((uint32_t)14 + ihl + 20 > len) return;
    uint16_t tot = (uint16_t)((ip[2] << 8) | ip[3]);
    const uint8_t* tcp = ip + ihl;
    uint16_t thl = (uint16_t)(((tcp[12] >> 4) & 0x0F) * 4);
    if (thl < 20 || (uint32_t)ihl + thl > tot) return;
    uint32_t payload = (uint32_t)tot - ihl - thl;
    if (payload == 0) return;                            // pure ACK -> not data
    uint32_t seq   = ((uint32_t)tcp[4] << 24) | ((uint32_t)tcp[5] << 16) |
                     ((uint32_t)tcp[6] << 8)  |  (uint32_t)tcp[7];
    uint32_t saddr = ((uint32_t)ip[12] << 24) | ((uint32_t)ip[13] << 16) |
                     ((uint32_t)ip[14] << 8)  |  (uint32_t)ip[15];
    uint32_t daddr = ((uint32_t)ip[16] << 24) | ((uint32_t)ip[17] << 16) |
                     ((uint32_t)ip[18] << 8)  |  (uint32_t)ip[19];
    uint16_t sport = (uint16_t)((tcp[0] << 8) | tcp[1]);
    uint16_t dport = (uint16_t)((tcp[2] << 8) | tcp[3]);
    uint32_t key   = saddr ^ (daddr * 2654435761u) ^ (((uint32_t)sport << 16) | dport);
    if (key == 0) key = 1;
    unsigned slot = key % ETH_RETX_FLOWS;
    if (!g_retx_flow[slot].valid || g_retx_flow[slot].key != key) {
        g_retx_flow[slot].valid    = 1;
        g_retx_flow[slot].key      = key;
        g_retx_flow[slot].next_seq = seq + payload;
        return;
    }
    int32_t diff = (int32_t)(seq - g_retx_flow[slot].next_seq);
    if (diff < 0) {
        g_perf_rx_retx++;                                // server resent old data
    } else {
        if (diff > 0) g_perf_rx_gap++;                   // hole in OUR inbound view -> lost upstream
        g_retx_flow[slot].next_seq = seq + payload;      // new data, advance mark
    }

    // Classify the retransmit against what the Amiga has ACKed (shared conn table).
    {
        uint32_t ck = eth_conn_key(saddr, daddr, sport, dport);
        unsigned cs = ck % ETH_CONN_FLOWS;
        if (!g_conn[cs].valid || g_conn[cs].key != ck) {
            g_conn[cs].valid = 1; g_conn[cs].key = ck;
            g_conn[cs].in_seq_hi = seq + payload; g_conn[cs].have_in = 1;
            g_conn[cs].have_ack = 0; g_conn[cs].out_ack_hi = 0;
        } else if ((int32_t)(seq - g_conn[cs].in_seq_hi) < 0) {   // retransmit
            if (g_conn[cs].have_ack && (int32_t)(seq - g_conn[cs].out_ack_hi) < 0)
                g_perf_retx_ack++;                       // Amiga already ACKed it -> ACK-loss
            else
                g_perf_retx_dat++;                       // Amiga hadn't ACKed it -> data-loss
        } else {
            g_conn[cs].in_seq_hi = seq + payload;
            g_conn[cs].have_in = 1;
        }
    }
}

// Count the Amiga's OUTGOING TRUE duplicate ACKs (see g_perf_dup_ack). A real
// RFC-5681 dup-ACK carries NO data, repeats the same ack number, AND advertises
// the SAME window -- that excludes window-update ACKs (same ack, growing window)
// which would otherwise inflate the count during a healthy download. A true
// dup-ACK means the Amiga received an OUT-OF-ORDER segment (a hole), i.e. our
// delivery dropped or reordered an in-bound segment.
static struct { uint8_t valid; uint32_t key; uint32_t last_ack; uint16_t last_win; } g_dack_flow[ETH_RETX_FLOWS];

static void tcp_track_outgoing_ack(const uint8_t* d, uint16_t len)
{
    if (len < 14 + 20) return;
    if (((d[12] << 8) | d[13]) != 0x0800) return;        // IPv4 only
    const uint8_t* ip = d + 14;
    if ((ip[0] >> 4) != 4) return;
    uint16_t ihl = (uint16_t)((ip[0] & 0x0F) * 4);
    if (ihl < 20 || ip[9] != 6) return;                  // TCP only
    if ((uint32_t)14 + ihl + 20 > len) return;
    uint16_t tot = (uint16_t)((ip[2] << 8) | ip[3]);
    const uint8_t* tcp = ip + ihl;
    if (!(tcp[13] & 0x10)) return;                       // ACK flag not set
    uint16_t thl = (uint16_t)(((tcp[12] >> 4) & 0x0F) * 4);
    if (thl < 20 || (uint32_t)ihl + thl > tot) return;
    uint32_t payload = (uint32_t)tot - ihl - thl;        // data this ACK carries
    uint32_t ack   = ((uint32_t)tcp[8] << 24) | ((uint32_t)tcp[9] << 16) |
                     ((uint32_t)tcp[10] << 8) |  (uint32_t)tcp[11];
    uint16_t win   = (uint16_t)((tcp[14] << 8) | tcp[15]);
    uint32_t saddr = ((uint32_t)ip[12] << 24) | ((uint32_t)ip[13] << 16) |
                     ((uint32_t)ip[14] << 8)  |  (uint32_t)ip[15];
    uint32_t daddr = ((uint32_t)ip[16] << 24) | ((uint32_t)ip[17] << 16) |
                     ((uint32_t)ip[18] << 8)  |  (uint32_t)ip[19];
    uint16_t sport = (uint16_t)((tcp[0] << 8) | tcp[1]);
    uint16_t dport = (uint16_t)((tcp[2] << 8) | tcp[3]);
    // Retransmit classifier: record the highest ack the Amiga has sent for this
    // connection (shared, direction-independent conn table; see tcp_track_download).
    {
        uint32_t ck = eth_conn_key(saddr, daddr, sport, dport);
        unsigned cs = ck % ETH_CONN_FLOWS;
        if (!g_conn[cs].valid || g_conn[cs].key != ck) {
            g_conn[cs].valid = 1; g_conn[cs].key = ck;
            g_conn[cs].out_ack_hi = ack; g_conn[cs].have_ack = 1;
            g_conn[cs].have_in = 0; g_conn[cs].in_seq_hi = 0;
        } else {
            if (!g_conn[cs].have_ack || (int32_t)(ack - g_conn[cs].out_ack_hi) > 0)
                g_conn[cs].out_ack_hi = ack;
            g_conn[cs].have_ack = 1;
        }
    }
    uint32_t key   = saddr ^ (daddr * 2654435761u) ^ (((uint32_t)sport << 16) | dport);
    if (key == 0) key = 1;
    unsigned slot = key % ETH_RETX_FLOWS;
    if (!g_dack_flow[slot].valid || g_dack_flow[slot].key != key) {
        g_dack_flow[slot].valid    = 1;
        g_dack_flow[slot].key      = key;
        g_dack_flow[slot].last_ack = ack;
        g_dack_flow[slot].last_win = win;
        return;
    }
    // True dup-ACK: same ack, no data, and the window did NOT grow. Requiring
    // win<=last (not ==) is the fix for the bulk phase: a real dup-ACK is
    // triggered by an out-of-order segment that just consumed buffer, so its
    // window is the SAME or SMALLER; only a genuine window-UPDATE grows it. The
    // earlier "win==last" missed dup-ACKs whose window shrank, hiding bulk-phase
    // data loss behind dupAck=0.
    if (payload == 0 && ack == g_dack_flow[slot].last_ack && win <= g_dack_flow[slot].last_win)
        g_perf_dup_ack++;
    g_dack_flow[slot].last_ack = ack;
    g_dack_flow[slot].last_win = win;
}

// Helper functions to access NE2000 memory directly from shared memory
static uint8_t read_ne_memory(uint16_t addr) __attribute__((unused));
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

    uint64_t copy_t0 = eth_mono_us();   // HPS-bottleneck probe: time the shm publish
    eth_write_shared_rx_payload(shared_rx_slot_data_offset(tail), data, len);
    eth_write_shared_u16(shared_rx_slot_len_offset(tail), len);
    // CRITICAL: the FPGA reads this slot the moment it observes the advanced
    // tail, over a NON-coherent HPS->FPGA path. Without a barrier the ARM write
    // buffer can let the tail update reach DDR before the payload memcpy does,
    // so the bg copies a half-written slot into the NE2000 ring -> a corrupt
    // frame the Amiga's TCP silently drops (bad checksum). It only misfires when
    // slots are written back-to-back (download bursts), is RX-only, and is
    // invisible to drop counters and to the synchronous-write simulation. Order
    // payload+len ahead of the tail, and the tail ahead of the RX_AVAIL wake.
    __sync_synchronize();
    eth_shared_readback_fence(shared_rx_slot_len_offset(tail));
    if (len != 0) {
        eth_shared_readback_fence(shared_rx_slot_data_offset(tail) + len - 1);
    }
    // Cross-port settling: wrBad=0 proves the payload IS in DDR from the ARM's
    // view, yet the bg's f2sdram read still sees stale bytes (csBG!=csTX) when
    // slots are reused fast. The ARM-side barriers above don't guarantee the write
    // has committed to the SDRAM array for the FPGA's f2sdram read port. Spin a
    // tunable settle window before exposing the slot (advancing the tail) so the
    // commit lands first. 0 = off (default).
    if (g_rx_settle_us) {
        uint64_t t0 = eth_mono_us();
        while ((eth_mono_us() - t0) < g_rx_settle_us) { __sync_synchronize(); }
    }
    // Delivery pacing: enforce a minimum interval between consecutive tail advances
    // (= deliveries to the Amiga). Only throttles back-to-back microbursts; frames
    // already >= pace apart pass with no delay.
    if (g_rx_pace_us) {
        static uint64_t last_deliver_us = 0;
        if (last_deliver_us) {
            while ((eth_mono_us() - last_deliver_us) < g_rx_pace_us) { __sync_synchronize(); }
        }
        last_deliver_us = eth_mono_us();
    }
    write_shared_rx_queue_tail(next_tail);
    __sync_synchronize();
    eth_shared_readback_fence(ETH_RX_QUEUE_TAIL);
    {
        uint64_t copy_us = eth_mono_us() - copy_t0;
        if (copy_us > g_perf_rx_copy_us_max) g_perf_rx_copy_us_max = copy_us;
    }
    *flags = eth_update_shared_flags(0, ETH_FLAG_RX_AVAIL);
    g_perf_rx_frames++;
    g_perf_rx_bytes += len;
    // Integrity probe: running byte-sum of frame bytes we hand to the shm queue
    // (matches the bg's slot-40 sum of what it writes into the ring).
    //
    // SPLIT TEST (MINIMIG_ETH_RX_VERIFY=1): the csBG!=csTX verdict proved the bg
    // pulls DIFFERENT bytes from shm than we sent on large download frames. That is
    // either (A) our uncached staged->slot copy dropping bytes, or (B) the bg's
    // f2sdram read seeing a partially-written slot (the HPS->FPGA non-coherent
    // ordering the barriers above are meant to close, but only guarantee ARM-side
    // completion, not f2sdram-read-side visibility). To split them: after the copy
    // + barriers, read the slot BACK through our own /dev/mem view and sum THAT.
    //   intended != slot_readback  -> (A) the copy itself is broken (daemon fix)
    //   intended == slot_readback but csBG != csTX -> (B) f2sdram read race (FPGA fix)
    // Use the read-back (actual DDR, ARM view) for g_sent_csum_run so the running
    // csBG-vs-csTX compare isolates the f2sdram READ path. Gated (O(len) uncached
    // reads add bus traffic that can perturb the very race) -- enable for the run.
    {
        uint32_t intended = 0;
        for (uint16_t i = 0; i < len; i++) intended += data[i];
        uint32_t slot_sum = intended;
        if (g_rx_verify && len != 0) {
            volatile uint8_t *slot = (volatile uint8_t *)eth_shmem + shared_rx_slot_data_offset(tail);
            uint32_t rb = 0;
            for (uint16_t i = 0; i < len; i++) rb += slot[i];
            slot_sum = rb;
            if ((rb & 0xFFFF) != (intended & 0xFFFF)) g_perf_wr_bad++;
        }
        g_sent_csum_run = (g_sent_csum_run + slot_sum) & 0xFFFF;
        g_sent_frame_count++;   // count tag: matches the bg's slot-41 frame counter
    }

    eth_trace("ETH: Enqueued shared RX packet slot=%u len=%u head=%u tail->%u\n",
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

    // Reference the queued packet in place; enqueue copies its bytes into shared
    // DDR (it never mutates the queue), so there is no need to copy the whole
    // ~1.5 KB host_rx_packet struct by value first.
    const struct host_rx_packet* packet = &host_rx_queue[host_rx_queue_head];
    if (!enqueue_shared_rx_packet(packet->data, packet->len, flags, state)) {
        return false;
    }

    host_rx_queue_head = (host_rx_queue_head + 1) % ETH_HOST_RX_QUEUE_DEPTH;
    host_rx_queue_count--;
    return true;
}

// Deliver one <=MTU frame to the Amiga under strict FIFO: drain anything already
// deferred into shm first, fast-path this frame to shm only when nothing is queued
// ahead of it, else defer it to the host queue (preserves in-order delivery so the
// Amiga's TCP doesn't see reordering -> dup-ACKs -> cwnd collapse).
static void deliver_rx_frame(const uint8_t* data, uint16_t len,
                             uint32_t* flags, struct rtl8019_state* state)
{
    while (pump_host_rx_queue(flags, state)) {
    }
    bool queued = (host_rx_queue_count == 0) &&
                  enqueue_shared_rx_packet(data, len, flags, state);
    if (!queued) {
        if (!enqueue_host_rx_packet(data, len)) {
            g_perf_rx_drop++;
            eth_debug("ETH: RX software queue full, dropping packet of %u bytes\n", len);
            state->rx_errors++;
        } else {
            g_perf_rx_defer++;
            eth_debug("ETH: Deferred RX packet of %u bytes in host queue (depth: %u)\n",
                      len, host_rx_queue_count);
        }
    }
}

// Sink for software-GSO re-segmentation: each <=MTU segment is loss-tracked and
// delivered in order, exactly like a natively received frame.
struct eth_gso_deliver_ctx {
    uint32_t* flags;
    struct rtl8019_state* state;
};
static void eth_gso_deliver_seg(void* ctx, const uint8_t* frame, int len)
{
    struct eth_gso_deliver_ctx* c = (struct eth_gso_deliver_ctx*)ctx;
    g_perf_rx_csum_fix++;
    tcp_track_download(frame, (uint16_t)len);
    deliver_rx_frame(frame, (uint16_t)len, c->flags, c->state);
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

    // Integrity-probe split test: MINIMIG_ETH_RX_VERIFY=1 makes enqueue read each
    // slot back from DDR after the copy+barriers and compare to the intended sum,
    // so wrBad isolates an uncached COPY bug from an f2sdram READ visibility race.
    {
        const char *v = getenv("MINIMIG_ETH_RX_VERIFY");
        if (v && v[0]) g_rx_verify = (v[0] != '0') ? 1 : 0;   // default ON; env only needed to disable
        eth_debug("ETH: MINIMIG_ETH_RX_VERIFY=%d\n", g_rx_verify);
        const char *s = getenv("MINIMIG_ETH_RX_SETTLE_US");
        if (s && s[0]) {
            unsigned long us = strtoul(s, 0, 0);
            if (us > 1000) us = 1000;   // cap: this spins in the RX hot path
            g_rx_settle_us = (uint32_t)us;
        }
        eth_debug("ETH: MINIMIG_ETH_RX_SETTLE_US=%u\n", g_rx_settle_us);
        const char *p = getenv("MINIMIG_ETH_RX_PACE_US");
        if (p && p[0]) {
            unsigned long us = strtoul(p, 0, 0);
            if (us > 20000) us = 20000;   // cap the busy-spin
            g_rx_pace_us = (uint32_t)us;
        }
        eth_debug("ETH: MINIMIG_ETH_RX_PACE_US=%u\n", g_rx_pace_us);
        const char *d = getenv("MINIMIG_ETH_RX_DEDUPE_US");
        if (d && d[0]) {
            unsigned long us = strtoul(d, 0, 0);
            if (us > 1000000) us = 1000000;
            g_rx_dedupe_window_us = (uint32_t)us;
        }
        eth_debug("ETH: MINIMIG_ETH_RX_DEDUPE_US=%u\n", g_rx_dedupe_window_us);
    }

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
    
    // Find and bind to a deterministic ethernet interface. The old first-UP
    // getifaddrs() choice could bind to a bridge/tap/veth layer and receive
    // duplicate inbound copies that looked legitimate to AF_PACKET.
    if (!eth_select_bridge_interface(raw_socket)) {
        eth_debug("ETH: Warning: No ethernet interface found for bridging\n");
        close(raw_socket);
        raw_socket = -1;
        eth_update_shared_status(0xFFFF, 0);
        return;
    }
    eth_debug("ETH: Selected ethernet interface: %s\n", bridge_interface);

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

#ifdef PACKET_IGNORE_OUTGOING
    {
        int ignore_outgoing = 1;
        if (setsockopt(raw_socket, SOL_PACKET, PACKET_IGNORE_OUTGOING,
                       &ignore_outgoing, sizeof(ignore_outgoing)) < 0) {
            eth_debug("ETH: Warning: PACKET_IGNORE_OUTGOING failed: %s\n",
                      strerror(errno));
        }
    }
#endif

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

    // Enlarge the kernel receive buffer so a TCP download BURST (the server can
    // now send a full ~64 KB window back-to-back once the Amiga advertises a big
    // receive window) is absorbed instead of overflowing the socket and being
    // dropped before our recv() loop drains it. Such drops are invisible to the
    // FPGA/daemon counters but collapse TCP (loss -> cwnd=1 -> stalls/errors).
    {
        int rcvbuf = 4 * 1024 * 1024;   // 4 MB
        // SO_RCVBUFFORCE (root) bypasses net.core.rmem_max; fall back to SO_RCVBUF.
        if (setsockopt(raw_socket, SOL_SOCKET, SO_RCVBUFFORCE, &rcvbuf, sizeof(rcvbuf)) < 0 &&
            setsockopt(raw_socket, SOL_SOCKET, SO_RCVBUF,      &rcvbuf, sizeof(rcvbuf)) < 0) {
            eth_debug("ETH: Warning: could not enlarge SO_RCVBUF: %s\n", strerror(errno));
        } else {
            int got = 0; socklen_t gl = sizeof(got);
            getsockopt(raw_socket, SOL_SOCKET, SO_RCVBUF, &got, &gl);
            eth_debug("ETH: RX socket buffer set to %d bytes\n", got);
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

static uint16_t eth_frame_byte_sum16(const uint8_t* d, uint16_t len)
{
    uint16_t sum = 0;
    for (uint16_t i = 0; i < len; i++) {
        sum = (uint16_t)(sum + d[i]);
    }
    return sum;
}

static uint32_t ip_csum_add(const uint8_t* data, uint16_t len, uint32_t sum)
{
    uint16_t i = 0;

    for (; i + 1 < len; i += 2) {
        sum += (uint32_t)((data[i] << 8) | data[i + 1]);
    }
    if (i < len) {
        sum += (uint32_t)(data[i] << 8);
    }

    return sum;
}

static bool ip_csum_valid(uint32_t sum)
{
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (uint16_t)sum == 0xFFFF;
}

static uint16_t ip_csum_finish(uint32_t sum)
{
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (uint16_t)(~sum);
}

static uint32_t ipv4_pseudo_csum(const uint8_t* ip, uint8_t proto, uint16_t len)
{
    uint32_t sum = 0;

    sum = ip_csum_add(ip + 12, 8, sum);    // source + destination IPv4
    sum += proto;
    sum += len;
    return sum;
}

static bool eth_ipv4_l2_offset(const uint8_t* d, size_t len, uint16_t* l2_out)
{
    if (len < 14) return false;
    uint16_t ethertype = (uint16_t)((d[12] << 8) | d[13]);
    uint16_t l2 = 14;

    if (ethertype == 0x8100 || ethertype == 0x88A8) {         // 802.1Q / 802.1ad
        if (len < 18) return false;
        ethertype = (uint16_t)((d[16] << 8) | d[17]);
        l2 = 18;
    }

    if (ethertype != 0x0800) return false;
    *l2_out = l2;
    return true;
}

static bool eth_ipv4_is_fragment(const uint8_t* ip)
{
    return ((ip[6] & 0x3F) != 0) || (ip[7] != 0);
}

static bool eth_rx_needs_gso(const uint8_t* d, size_t len)
{
    uint16_t l2;
    if (!eth_ipv4_l2_offset(d, len, &l2)) {
        return len > 1518;
    }
    if (len < (size_t)l2 + 20) {
        return false;
    }

    const uint8_t* ip = d + l2;
    if ((ip[0] >> 4) != 4) return false;
    uint16_t ihl = (uint16_t)((ip[0] & 0x0F) * 4);
    if (ihl < 20 || len < (size_t)l2 + ihl) return false;
    uint16_t ip_total = (uint16_t)((ip[2] << 8) | ip[3]);

    return (len > (size_t)l2 + ETH_GSO_MTU) ||
           (ip[9] == 6 && !eth_ipv4_is_fragment(ip) && ip_total > ETH_GSO_MTU);
}

// Normalize IPv4 header and common L4 checksums in-place. This is deliberately
// software-only: AF_PACKET send/receive gives us packet bytes, not the skb
// checksum metadata used by eth0 RX/TX offload. The Amiga must only see and
// transmit frames whose checksum fields are valid on the wire.
static bool eth_fix_ipv4_checksums(uint8_t* d, uint16_t len)
{
    uint16_t l2;
    if (!eth_ipv4_l2_offset(d, len, &l2)) return false;
    if (len < (uint16_t)(l2 + 20)) return false;

    uint8_t* ip = d + l2;
    if ((ip[0] >> 4) != 4) return false;
    uint16_t ihl = (uint16_t)((ip[0] & 0x0F) * 4);
    if (ihl < 20 || len < (uint16_t)(l2 + ihl)) return false;
    uint16_t tot = (uint16_t)((ip[2] << 8) | ip[3]);
    if (tot < ihl || (uint32_t)l2 + tot > len) return false;

    bool changed = false;

    uint16_t old_ip = (uint16_t)((ip[10] << 8) | ip[11]);
    ip[10] = 0;
    ip[11] = 0;
    uint16_t new_ip = ip_csum_finish(ip_csum_add(ip, ihl, 0));
    ip[10] = (uint8_t)(new_ip >> 8);
    ip[11] = (uint8_t)new_ip;
    changed |= (old_ip != new_ip);

    if (eth_ipv4_is_fragment(ip)) return changed;

    uint8_t* l4 = ip + ihl;
    uint16_t l4_len = (uint16_t)(tot - ihl);

    if (ip[9] == 6) {                                        // TCP
        if (l4_len < 20) return changed;
        uint16_t thl = (uint16_t)(((l4[12] >> 4) & 0x0F) * 4);
        if (thl < 20 || thl > l4_len) return changed;
        uint16_t old = (uint16_t)((l4[16] << 8) | l4[17]);
        l4[16] = 0;
        l4[17] = 0;
        uint32_t sum = ipv4_pseudo_csum(ip, 6, l4_len);
        sum = ip_csum_add(l4, l4_len, sum);
        uint16_t now = ip_csum_finish(sum);
        l4[16] = (uint8_t)(now >> 8);
        l4[17] = (uint8_t)now;
        changed |= (old != now);
    } else if (ip[9] == 17) {                                // UDP
        if (l4_len < 8) return changed;
        uint16_t udp_len = (uint16_t)((l4[4] << 8) | l4[5]);
        if (udp_len < 8 || udp_len > l4_len) return changed;
        uint16_t old = (uint16_t)((l4[6] << 8) | l4[7]);
        l4[6] = 0;
        l4[7] = 0;
        uint32_t sum = ipv4_pseudo_csum(ip, 17, udp_len);
        sum = ip_csum_add(l4, udp_len, sum);
        uint16_t now = ip_csum_finish(sum);
        if (now == 0) now = 0xFFFF;                          // UDP zero means "not used"
        l4[6] = (uint8_t)(now >> 8);
        l4[7] = (uint8_t)now;
        changed |= (old != now);
    } else if (ip[9] == 1) {                                 // ICMP
        if (l4_len < 4) return changed;
        uint16_t old = (uint16_t)((l4[2] << 8) | l4[3]);
        l4[2] = 0;
        l4[3] = 0;
        uint16_t now = ip_csum_finish(ip_csum_add(l4, l4_len, 0));
        l4[2] = (uint8_t)(now >> 8);
        l4[3] = (uint8_t)now;
        changed |= (old != now);
    }

    return changed;
}

// Verify the IPv4 header and common transport checksums of a staged outgoing
// frame exactly as the receiver would. This catches corrupt DNS/UDP and ping/ICMP
// traffic too; the old TCP-only probe let DNS break while txBadCsum stayed zero.
// Observe-only -- never alters the frame or the decision to send.
static bool tx_frame_checksums_ok(const uint8_t* d, uint16_t len)
{
    uint16_t l2;
    if (!eth_ipv4_l2_offset(d, len, &l2)) return true;       // not IPv4
    if (len < (uint16_t)(l2 + 20)) return true;              // too short for IPv4
    const uint8_t* ip = d + l2;
    uint16_t ihl = (uint16_t)((ip[0] & 0x0F) * 4);
    if (ihl < 20 || (uint32_t)l2 + ihl > len) return true;   // malformed -> skip
    uint16_t tot = (uint16_t)((ip[2] << 8) | ip[3]);         // IP total length
    if (tot < ihl || (uint32_t)l2 + tot > len) return true;  // length past frame -> skip

    if (!ip_csum_valid(ip_csum_add(ip, ihl, 0))) return false;
    if (eth_ipv4_is_fragment(ip)) return true;

    const uint8_t* l4 = ip + ihl;
    uint16_t l4_len = (uint16_t)(tot - ihl);

    if (ip[9] == 6) {                                        // TCP
        if (l4_len < 20) return true;                        // malformed -> skip
        uint32_t sum = ipv4_pseudo_csum(ip, 6, l4_len);
        sum = ip_csum_add(l4, l4_len, sum);
        if (!ip_csum_valid(sum)) return false;
    } else if (ip[9] == 17) {                                // UDP
        if (l4_len < 8) return true;                         // malformed -> skip
        uint16_t udp_len = (uint16_t)((l4[4] << 8) | l4[5]);
        uint16_t udp_sum = (uint16_t)((l4[6] << 8) | l4[7]);
        if (udp_sum == 0) return true;                       // optional in IPv4
        if (udp_len < 8 || udp_len > l4_len) return true;    // malformed -> skip
        uint32_t sum = ipv4_pseudo_csum(ip, 17, udp_len);
        sum = ip_csum_add(l4, udp_len, sum);
        if (!ip_csum_valid(sum)) return false;
    } else if (ip[9] == 1) {                                 // ICMP
        if (l4_len < 4) return true;                         // malformed -> skip
        if (!ip_csum_valid(ip_csum_add(l4, l4_len, 0))) return false;
    }
    return true;
}

// Clamp the TCP receive window the Amiga advertises in an outgoing segment down
// to ETH_TX_WINDOW_CLAMP, recomputing the TCP checksum. Modifies the frame in the
// given buffer. Returns true if it changed the window. Only IPv4/TCP frames whose
// window exceeds the clamp are touched; everything else is left untouched.
static bool tx_clamp_window(uint8_t* d, uint16_t len)
{
#if ETH_TX_WINDOW_CLAMP > 0
    if (len < 14 + 20) return false;
    if (((d[12] << 8) | d[13]) != 0x0800) return false;       // not IPv4
    uint8_t* ip = d + 14;
    uint16_t ihl = (uint16_t)((ip[0] & 0x0F) * 4);
    if (ihl < 20 || (uint32_t)14 + ihl + 20 > len) return false;
    if (ip[9] != 6) return false;                             // not TCP
    uint16_t tot = (uint16_t)((ip[2] << 8) | ip[3]);
    if (tot < (uint16_t)(ihl + 20) || (uint32_t)14 + tot > len) return false;

    uint8_t* tcp = ip + ihl;
    uint16_t win = (uint16_t)((tcp[14] << 8) | tcp[15]);
    if (win <= ETH_TX_WINDOW_CLAMP) return false;             // already small enough

    tcp[14] = (uint8_t)((ETH_TX_WINDOW_CLAMP >> 8) & 0xFF);   // new window
    tcp[15] = (uint8_t)(ETH_TX_WINDOW_CLAMP & 0xFF);

    // Recompute ONLY the TCP checksum (the IP header is unchanged). Zero the
    // field, sum pseudo-header + segment, store the one's-complement.
    tcp[16] = 0; tcp[17] = 0;
    uint16_t tcp_len = (uint16_t)(tot - ihl);
    uint32_t t = 0;
    t += ((uint32_t)ip[12] << 8) | ip[13];                    // src IP
    t += ((uint32_t)ip[14] << 8) | ip[15];
    t += ((uint32_t)ip[16] << 8) | ip[17];                    // dst IP
    t += ((uint32_t)ip[18] << 8) | ip[19];
    t += 6;                                                   // protocol
    t += tcp_len;                                             // TCP length
    for (uint16_t i = 0; i + 1 < tcp_len; i += 2)
        t += (uint32_t)((tcp[i] << 8) | tcp[i + 1]);
    if (tcp_len & 1) t += (uint32_t)(tcp[tcp_len - 1] << 8);  // odd-length pad
    while (t >> 16) t = (t & 0xFFFF) + (t >> 16);
    uint16_t csum = (uint16_t)(~t);
    tcp[16] = (uint8_t)((csum >> 8) & 0xFF);
    tcp[17] = (uint8_t)(csum & 0xFF);
    return true;
#else
    (void)d; (void)len;
    return false;
#endif
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

#ifdef ETH_TRACE
    // Per-frame trace (off by default): first 32 bytes of transmitted packet.
    // The whole dump (loop included) is compiled out unless tracing is enabled.
    eth_trace("ETH: Transmitting request seq=%u from addr 0x%04X, length %d bytes:\n",
              request->seq, addr, length);
    eth_trace("ETH: TX Data: ");
    for (int i = 0; i < 32 && i < length; i++) {
        uint8_t byte_val = eth_shmem[ETH_TX_BUFFER + i];
        eth_trace("%02X ", byte_val);
        if ((i + 1) % 16 == 0) eth_trace("\nETH: TX Data: ");
    }
    eth_trace("\n");
#endif

    // Send the packet staged by the FPGA background DMA path.
    uint8_t* packet_data = eth_shmem + ETH_TX_BUFFER;
    // Observe the Amiga's advertised TCP receive window (download throughput cap).
    {
        int win = tcp_adv_window(packet_data, length);
        if (win >= 0) {
            g_perf_tx_win_last = (uint32_t)win;
            if ((uint32_t)win < g_perf_tx_win_min) g_perf_tx_win_min = (uint32_t)win;
            if (win == 0) g_perf_tx_zerowin++;
        }
    }
    // Split retx cause: dup-ACKs from the Amiga mean a missing in-bound segment.
    tcp_track_outgoing_ack(packet_data, length);
    // DIAGNOSTIC: is the staged frame (usually an ACK) well-formed before HPS
    // normalization? If not, count it, but still repair the copy below before
    // AF_PACKET send so eth0 TX checksum offload state cannot decide correctness.
    bool tx_staged_csum_ok = tx_frame_checksums_ok(packet_data, length);
    if (!tx_staged_csum_ok) {
        g_perf_tx_bad_csum++;
        static int csum_dumped = 0;
        if (csum_dumped < 6) {
            csum_dumped++;
            eth_debug("ETH: TX staged bad checksum #%llu seq=%u len=%u first40:",
                      (unsigned long long)g_perf_tx_bad_csum, request->seq, length);
            for (int i = 0; i < 40 && i < length; i++)
                eth_debug(" %02X", packet_data[i]);
            eth_debug("\n");
        }
    }
    uint16_t tx_hps_frame_sum = eth_frame_byte_sum16(packet_data, length);
    // Pace the download: clamp the advertised TCP window on the COPY we send to
    // the server (the observations above used the Amiga's unmodified frame).
    uint8_t tx_send_buf[ETH_PACKET_BUFFER_SIZE];
    const uint8_t* tx_out = packet_data;
    if (length <= ETH_PACKET_BUFFER_SIZE) {
        memcpy(tx_send_buf, packet_data, length);
        if (tx_clamp_window(tx_send_buf, length)) g_perf_tx_win_clamped++;
        if (eth_fix_ipv4_checksums(tx_send_buf, length)) g_perf_tx_csum_fix++;
        tx_out = tx_send_buf;
    }
    if (!tx_frame_checksums_ok(tx_out, length)) {
        eth_debug("ETH: refusing TX frame with invalid checksum after software normalization, seq=%u len=%u\n",
                  request->seq, length);
        state.tx_errors++;
        g_perf_tx_drop++;
        write_eth_state_stats(&state);
        return false;
    }
    ssize_t sent = send(raw_socket, tx_out, length, 0);
    if (sent < 0) {
        eth_debug("ETH: Failed to send packet: %s\n", strerror(errno));
        state.tx_errors++;
        g_perf_tx_drop++;                 // egress loss: ACK/data never left the HPS
        write_eth_state_stats(&state);
        return false;
    } else if (sent != length) {
        eth_debug("ETH: Short send: expected %u bytes, sent %zd bytes\n", length, sent);
        state.tx_errors++;
        g_perf_tx_drop++;                 // egress loss: partial send
        write_eth_state_stats(&state);
        return false;
    } else {
        g_tx_hps_csum_run = (uint16_t)(g_tx_hps_csum_run + tx_hps_frame_sum);
        g_tx_hps_byte_count = (uint16_t)(g_tx_hps_byte_count + length);
        g_tx_hps_frame_count = (uint16_t)(g_tx_hps_frame_count + 1);
        eth_trace("ETH: Transmitted packet of %d bytes (total TX: %d)\n", length, state.tx_packets + 1);
        state.tx_packets++;
    }

    write_eth_state_stats(&state);
    return true;
}

#ifdef ETH_RX_KERNEL_FILTER
// Keep a cBPF receive filter installed on the raw socket that matches the
// Amiga's current station MAC plus broadcast/multicast, so the kernel discards
// everything else without waking the daemon. Cheap to call every poll: it only
// (re)attaches when the MAC or promiscuous state actually changes.
static bool    g_kfilter_active = false;
static bool    g_kfilter_pro    = false;
static uint8_t g_kfilter_mac[6] = {0, 0, 0, 0, 0, 0};

static void eth_update_socket_filter(const uint8_t mac[6], bool promiscuous)
{
    if (raw_socket < 0) return;

    if (promiscuous) {
        if (g_kfilter_active) {
            setsockopt(raw_socket, SOL_SOCKET, SO_DETACH_FILTER, NULL, 0);
            g_kfilter_active = false;
            eth_debug("ETH: kernel RX filter detached (promiscuous)\n");
        }
        g_kfilter_pro = true;
        return;
    }

    bool mac_known = (mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5]) != 0;
    if (!mac_known) return;   // wait until the FPGA mirrors the station MAC

    if (g_kfilter_active && !g_kfilter_pro && memcmp(mac, g_kfilter_mac, 6) == 0)
        return;               // already installed for this MAC

    uint32_t mac03 = ((uint32_t)mac[0] << 24) | ((uint32_t)mac[1] << 16) |
                     ((uint32_t)mac[2] << 8)  |  (uint32_t)mac[3];
    uint32_t mac45 = ((uint32_t)mac[4] << 8)  |  (uint32_t)mac[5];

    // dst[4:5]==mac45 && dst[0:3]==mac03 -> accept (unicast to Amiga);
    // else if (dst[0] & 1) -> accept (broadcast/multicast); else drop.
    struct sock_filter code[] = {
        BPF_STMT(BPF_LD  | BPF_H | BPF_ABS, 4),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, mac45, 0, 3),
        BPF_STMT(BPF_LD  | BPF_W | BPF_ABS, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, mac03, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, 0xFFFF),
        BPF_STMT(BPF_LD  | BPF_B | BPF_ABS, 0),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, 1, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, 0xFFFF),
        BPF_STMT(BPF_RET | BPF_K, 0),
    };
    struct sock_fprog prog;
    prog.len    = (unsigned short)(sizeof(code) / sizeof(code[0]));
    prog.filter = code;

    if (setsockopt(raw_socket, SOL_SOCKET, SO_ATTACH_FILTER, &prog, sizeof(prog)) < 0) {
        eth_debug("ETH: SO_ATTACH_FILTER failed: %s (continuing unfiltered)\n", strerror(errno));
        g_kfilter_active = false;
        return;
    }
    memcpy(g_kfilter_mac, mac, 6);
    g_kfilter_active = true;
    g_kfilter_pro = false;
    eth_debug("ETH: kernel RX filter installed for %02X:%02X:%02X:%02X:%02X:%02X (+bcast/mcast)\n",
              mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}
#endif // ETH_RX_KERNEL_FILTER

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

#ifdef ETH_RX_KERNEL_FILTER
    // Keep the in-kernel receive filter in sync with the Amiga's MAC / promisc.
    eth_update_socket_filter(mac_addr, (rcr & NE_RCR_PRO) != 0);
#endif

    while (pump_host_rx_queue(&flags, &state)) {
    }

    for (;;) {
        // Large enough to hold a fully GRO/LRO-coalesced superframe so software GSO
        // can re-split it below. recv() returns the full frame (no MSG_TRUNC needed,
        // the buffer exceeds the kernel gso_max). static: one reused scratch buffer,
        // off the stack (the daemon polls single-threaded).
        static uint8_t buffer[ETH_RX_JUMBO_SIZE];
        struct sockaddr_ll from;
        socklen_t from_len = sizeof(from);
        ssize_t len = recvfrom(raw_socket, buffer, sizeof(buffer), 0,
                               (struct sockaddr*)&from, &from_len);

        if (len <= 0) {
            break;
        }

        if (from_len >= sizeof(from) &&
            (from.sll_pkttype == PACKET_OUTGOING
#ifdef PACKET_LOOPBACK
             || from.sll_pkttype == PACKET_LOOPBACK
#endif
            )) {
            g_perf_rx_echo_drop++;
            continue;
        }

        // Filter out non-ethernet frames.
        if (len < 14) {
            continue;
        }

        // AF_PACKET often presents valid Ethernet frames with the wire padding
        // stripped (ARP, TCP SYN/ACK/FIN/ACK, small UDP/DNS). A real RTL8019 sees
        // those as legal minimum-size frames, not runts. Re-pad before applying
        // NE2000 filtering/delivery so small control traffic is not silently
        // choked while larger ping/data packets keep working.
        if (len < 60) {
            memset(buffer + len, 0, (size_t)(60 - len));
            len = 60;
            g_perf_rx_padded++;
        }

        // Respect the RTL8019 receive filter so we don't queue the whole LAN.
        bool accept = false;

        if (rcr & NE_RCR_PRO) {
            accept = true;
        }
        else if (memcmp(buffer, "\xFF\xFF\xFF\xFF\xFF\xFF", 6) == 0) {
            accept = (rcr & NE_RCR_AB) != 0;
#ifdef ETH_RX_BROADCAST_DENOISE
            // Forward only broadcast the Amiga actually needs; drop LAN floods
            // on the HPS side so they never interrupt/burden the 68020.
            if (accept && !broadcast_is_essential(buffer, (uint16_t)len)) {
                accept = false;
                g_perf_bcast_drop++;
            }
#endif
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

        if (eth_rx_is_near_duplicate(buffer, (size_t)len)) {
            g_perf_rx_dup_drop++;
            continue;
        }

        // Host RX offload can hand an AF_PACKET socket a GRO/LRO coalesced TCP
        // superframe instead of wire-sized Ethernet frames. A real RTL8029/X-Surf
        // never sees that. Split by either captured L2 length OR IPv4 total length,
        // because some GRO paths leave IP total-length stale while appending the
        // coalesced payload bytes to the skb.
        if (eth_rx_needs_gso(buffer, (size_t)len)) {
            struct eth_gso_deliver_ctx dctx = { &flags, &state };
            int nseg = eth_gso_resegment(buffer, (int)len, eth_gso_deliver_seg, &dctx);
            if (nseg > 0) {
                g_perf_rx_seg += (uint64_t)nseg;
            } else {
                // Not an in-order IPv4/TCP data superframe (jumbo, non-TCP, fragment,
                // SYN/RST): cannot be delivered intact -> drop (TCP retransmits).
                g_perf_rx_oversize++;
                eth_debug("ETH: dropping unsegmentable oversized RX frame (%zd bytes)\n", len);
                state.rx_errors++;
            }
            continue;
        }

        if (len > ETH_PACKET_BUFFER_SIZE) {
            g_perf_rx_oversize++;
            eth_debug("ETH: dropping oversized non-GSO RX frame (%zd bytes)\n", len);
            state.rx_errors++;
            continue;
        }

        uint16_t packet_len = (uint16_t)len;
        if (eth_fix_ipv4_checksums(buffer, packet_len)) g_perf_rx_csum_fix++;

        // Ground-truth RX loss measurement: count server retransmits on the
        // download stream (see tcp_track_download). Done on every accepted
        // frame; non-TCP / pure-ACK frames are ignored inside the helper.
        tcp_track_download(buffer, packet_len);
        deliver_rx_frame(buffer, packet_len, &flags, &state);

#ifdef ETH_TRACE
        // Per-frame trace (off by default): first 32 bytes of received packet.
        // The whole dump (loop included) is compiled out unless tracing is enabled.
        eth_trace("ETH: RX Data: ");
        for (int i = 0; i < 32 && i < len; i++) {
            eth_trace("%02X ", buffer[i]);
            if ((i + 1) % 16 == 0) eth_trace("\nETH: RX Data: ");
        }
        eth_trace("\n");
#endif
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
        
        // Heartbeat/signature/status only need to refresh fast enough for the
        // FPGA's liveness sampling (it reads them on a slow cadence). Updating
        // every poll burned ~3 shared-DDR writes x ~27k polls/s for no benefit;
        // refresh every 64 polls (~hundreds/s) instead. The signature/status are
        // constants, so rewriting them less often is harmless.
        static uint32_t hb_throttle = 0;
        if ((hb_throttle++ & 0x3F) == 0) {
            hps_heartbeat_counter++;
            eth_write_shared_u32(ETH_HPS_HEARTBEAT, hps_heartbeat_counter);
            eth_write_shared_u32(ETH_HPS_SIGNATURE, ETH_HPS_SIGNATURE_MAGIC);
            eth_update_shared_status(ETH_STATUS_LINK_UP, 0);
        }

        // --- throughput measurement: one summary line per second ---
        g_perf_polls++;
        {
            static struct timespec perf_last = {0, 0};
            struct timespec perf_now;
            clock_gettime(CLOCK_MONOTONIC, &perf_now);
            if (perf_last.tv_sec == 0 && perf_last.tv_nsec == 0) perf_last = perf_now;
            double perf_dt = (perf_now.tv_sec - perf_last.tv_sec) +
                             (perf_now.tv_nsec - perf_last.tv_nsec) / 1e9;
            if (perf_dt >= 1.0) {
                static uint64_t p_rxf = 0, p_rxb = 0, p_txf = 0, p_txb = 0;
                static uint64_t p_pl = 0, p_df = 0, p_dr = 0, p_bc = 0;
                static uint8_t  p_ovw = 0;
                double rxf = (g_perf_rx_frames - p_rxf) / perf_dt;
                double rxk = (g_perf_rx_bytes  - p_rxb) / perf_dt / 1024.0;
                double txf = (g_perf_tx_frames - p_txf) / perf_dt;
                double txk = (g_perf_tx_bytes  - p_txb) / perf_dt / 1024.0;
                double pls = (g_perf_polls     - p_pl)  / perf_dt;
                double bcd = (g_perf_bcast_drop - p_bc) / perf_dt;
                // NE2000 RX ring health: CNTR2 (reg 0x0D) counts RX-ring overflow
                // drops (the FPGA bg increments it when the ring is full and a
                // frame is discarded); CURR vs BNRY shows how full the ring is.
                // If ovwDrop climbs during a download, the Amiga isn't draining
                // the ring fast enough -> frames lost -> TCP backs off (drop-
                // driven slowness). If ovwDrop stays 0 and rx KB/s is still low,
                // the limit is the Amiga's TCP receive window, not the path.
                uint8_t ovw  = read_ne_register(0, 0x0D);   // CNTR2 (overflow drops)
                uint8_t curr = read_ne_register(1, 0x07);   // FPGA write page
                uint8_t bnry = read_ne_register(0, 0x03);   // driver read page
                uint8_t ovw_delta = (uint8_t)(ovw - p_ovw);
                static uint64_t p_zw = 0;
                // Amiga advertised receive window this interval (min seen / last).
                // 0xFFFFFFFF min means no TCP ACK was observed this second.
                long amiga_win_min = (g_perf_tx_win_min == 0xFFFFFFFF) ? -1
                                     : (long)g_perf_tx_win_min;
                // Kernel raw-socket stats: tp_drops = frames the KERNEL dropped
                // because the socket buffer was full before our recv() drained it
                // -- the silent RX loss point that collapses TCP. Reading
                // PACKET_STATISTICS resets the counters, so this is per-interval.
                unsigned sock_pkts = 0, sock_drops = 0;
                if (raw_socket >= 0) {
                    struct tpacket_stats pst;
                    socklen_t pl = sizeof(pst);
                    if (getsockopt(raw_socket, SOL_PACKET, PACKET_STATISTICS, &pst, &pl) == 0) {
                        sock_pkts  = pst.tp_packets;
                        sock_drops = pst.tp_drops;
                    }
                }
                // Integrity-probe compare (count-tagged). The bg publishes a running
                // byte-sum of payload it wrote into the ring (slot 40, 0x110A) and a
                // count of frames delivered (slot 41, 0x110C); both are byte-swapped
                // by the mailbox. We hold the same running sum + count for frames we
                // enqueued. Compare the sums ONLY when the bg's count equals ours and
                // is STABLE across the read (re-read the count): that means the bg has
                // delivered exactly the frames we sent, so the sums cover the identical
                // frame set and an inequality is a genuine shm->ring (bg write)
                // corruption -- not the reset/origin offset that made the old idle-only
                // probe untrustworthy. This fires at the frequent drain points during a
                // download, so it reports DURING the loss, not only at full idle.
                {
                    uint16_t c1   = (uint16_t)0; uint16_t c2 = (uint16_t)0; uint16_t bgcs = (uint16_t)0;
                    { uint16_t r = eth_read_shared_u16(ETH_RTL8019_RX_FRAMES); c1   = (uint16_t)((r << 8) | (r >> 8)); }
                    { uint16_t r = eth_read_shared_u16(ETH_RTL8019_RX_CSUM);   bgcs = (uint16_t)((r << 8) | (r >> 8)); }
                    { uint16_t r = eth_read_shared_u16(ETH_RTL8019_RX_FRAMES); c2   = (uint16_t)((r << 8) | (r >> 8)); }
                    g_perf_csum_bg = bgcs; g_perf_cnt_bg = c1;
                    if (!g_csum_calibrated) {
                        // Origin-align once: adopt the bg's current count+sum so frames
                        // enqueued from here advance both sides in lockstep (covers a
                        // daemon that (re)started after the FPGA was already running).
                        g_sent_frame_count = c1; g_sent_csum_run = bgcs; g_csum_calibrated = 1;
                    } else if (c1 == c2 && c1 == g_sent_frame_count) {
                        // Caught up and stable: the sums must be equal if the FPGA
                        // delivered our bytes intact.
                        uint16_t delta = (uint16_t)(bgcs - (uint16_t)g_sent_csum_run);
                        static int prev_bad = 0; static uint16_t prev_delta = 0, counted_delta = 0;
                        if (delta != 0) {
                            // Debounce the <=1-sweep skew between the csum and count
                            // slots: only count a divergence still present (same delta)
                            // on a later caught-up sample, and only once per NEW delta.
                            if (prev_bad && delta == prev_delta && delta != counted_delta) {
                                g_perf_deliv_bad++;
                                counted_delta = delta;
                                if (g_perf_deliv_bad_frame == 0) g_perf_deliv_bad_frame = c1;
                            }
                            prev_bad = 1; prev_delta = delta;
                        } else {
                            prev_bad = 0;
                        }
                    } else if (c1 == c2 && c1 != g_sent_frame_count) {
                        // Counts diverged -> a frame was dropped (separately flagged by
                        // ovwDrop/sockDrop/defer). Re-baseline so the probe keeps working.
                        g_sent_frame_count = c1; g_sent_csum_run = bgcs;
                    }
                }
                // Read-side probe: ringWr (bytes the bg WROTE into the ring) vs dpRd
                // (bytes the 68k READ back via the data port). At RX idle the 68k has
                // read every written frame, so the two totals match iff it reads the
                // ring intact. A persistent (stable across two idle samples) nonzero
                // delta => the 68k pulls different bytes than the bg wrote = a data-
                // port READ corruption (RTL-fixable). Equal => 68k reads correctly =>
                // the loss is Amiga-side. (The raw ringWr/dpRd are printed so a benign
                // constant offset, e.g. a header re-read, can be told from corruption.)
                {
                    uint16_t rw = eth_read_shared_u16(ETH_RTL8019_RING_WR);
                    uint16_t rd = eth_read_shared_u16(ETH_RTL8019_DP_RD);
                    uint16_t rc = eth_read_shared_u16(ETH_RTL8019_RD_CORRUPT);
                    uint16_t rk = eth_read_shared_u16(ETH_RTL8019_RD_CHECKED);
                    uint16_t rb = eth_read_shared_u16(ETH_RTL8019_RB_BAD);
                    uint16_t rs = eth_read_shared_u16(ETH_RTL8019_RB_CSUM_RUN);
                    uint16_t re = eth_read_shared_u16(ETH_RTL8019_RD_BAD_EXP);
                    uint16_t ra = eth_read_shared_u16(ETH_RTL8019_RD_BAD_ACT);
                    uint16_t tm = eth_read_shared_u16(ETH_RTL8019_TX_MIRROR_CSUM);
                    uint16_t tf = eth_read_shared_u16(ETH_RTL8019_TX_MIRROR_FRAMES);
                    uint16_t td = eth_read_shared_u16(ETH_RTL8019_TX_DRAIN_CSUM);
                    uint16_t tn = eth_read_shared_u16(ETH_RTL8019_TX_DRAIN_FRAMES);
                    uint16_t tb = eth_read_shared_u16(ETH_RTL8019_TX_MIRROR_BYTES);
                    uint16_t ty = eth_read_shared_u16(ETH_RTL8019_TX_DRAIN_BYTES);
                    g_perf_ring_wr = (uint16_t)((rw << 8) | (rw >> 8));
                    g_perf_dp_rd   = (uint16_t)((rd << 8) | (rd >> 8));
                    g_perf_rd_corrupt = (uint16_t)((rc << 8) | (rc >> 8));
                    g_perf_rd_checked = (uint16_t)((rk << 8) | (rk >> 8));
                    // WRITE/storage read-back probe (slots 46/47, shm 0x1116/0x1118,
                    // byte-swapped like the other slot reads above).
                    g_perf_rb_bad      = (uint16_t)((rb << 8) | (rb >> 8));
                    g_perf_rb_csum_run = (uint16_t)((rs << 8) | (rs >> 8));
                    g_perf_rd_bad_exp  = (uint16_t)((re << 8) | (re >> 8));
                    g_perf_rd_bad_act  = (uint16_t)((ra << 8) | (ra >> 8));
                    g_perf_tx_mirror_csum   = (uint16_t)((tm << 8) | (tm >> 8));
                    g_perf_tx_mirror_frames = (uint16_t)((tf << 8) | (tf >> 8));
                    g_perf_tx_drain_csum    = (uint16_t)((td << 8) | (td >> 8));
                    g_perf_tx_drain_frames  = (uint16_t)((tn << 8) | (tn >> 8));
                    g_perf_tx_mirror_bytes  = (uint16_t)((tb << 8) | (tb >> 8));
                    g_perf_tx_drain_bytes   = (uint16_t)((ty << 8) | (ty >> 8));
                    static int rd_idle = 0; static uint16_t prev_d = 0; static int have_d = 0;
                    if (rxf < 1.0 && host_rx_queue_count == 0) {
                        rd_idle++;
                        uint16_t d = (uint16_t)(g_perf_ring_wr - g_perf_dp_rd);
                        if (rd_idle >= 2 && d != 0 && have_d && d == prev_d) g_perf_rd_bad++;
                        prev_d = d; have_d = 1;
                    } else {
                        rd_idle = 0;
                    }
                }
                static uint64_t p_tm = 0, p_retx = 0, p_da = 0, p_gap = 0, p_txd = 0;
                eth_perf("ETHPERF: RX %.0f fps %.1f KB/s | TX %.0f fps %.1f KB/s | "
                         "amigaWin min=%ld last=%u zeroWin=%llu/s txMiss=%llu/s txDrop=%llu/s "
                         "retx=%llu/s dupAck=%llu/s rxGap=%llu/s delivBad=%llu retxAck=%llu retxDat=%llu txBadCsum=%llu txCsumFix=%llu | "
                         "sockDrop %u sockPkts %u | "
                         "ovwDrop %u/s ringCURR=0x%02X BNRY=0x%02X | "
                         "bcastDrop %.0f/s defer %llu drop %llu hostQ %u | "
                         "recvMaxUs=%llu recvFrMax=%llu copyMaxUs=%llu winClamp=%llu rxOversz=%llu rxSeg=%llu rxCsumFix=%llu rxPad=%llu rxEcho=%llu rxDup=%llu | "
                         "csBG=0x%04X csTX=0x%04X cnBG=%u cnTX=%u badFrm=%u wrBad=%llu rbBad=%u rbCs=0x%04X | "
                         "ringWr=0x%04X dpRd=0x%04X rdBad=%llu rdCorrupt=%u/%u "
                         "rdLast exp=0x%04X got=0x%04X | "
                         "txPath M=%04X/%u/%u D=%04X/%u/%u H=%04X/%u/%u | poll %.0f/s\n",
                         rxf, rxk, txf, txk,
                         amiga_win_min, (unsigned)g_perf_tx_win_last,
                         (unsigned long long)(g_perf_tx_zerowin - p_zw),
                         (unsigned long long)(g_perf_tx_miss - p_tm),
                         (unsigned long long)(g_perf_tx_drop - p_txd),
                         (unsigned long long)(g_perf_rx_retx - p_retx),
                         (unsigned long long)(g_perf_dup_ack - p_da),
                         (unsigned long long)(g_perf_rx_gap - p_gap),
                         (unsigned long long)g_perf_deliv_bad,
                         (unsigned long long)g_perf_retx_ack,
                         (unsigned long long)g_perf_retx_dat,
                         (unsigned long long)g_perf_tx_bad_csum,
                         (unsigned long long)g_perf_tx_csum_fix,
                         sock_drops, sock_pkts,
                         (unsigned)ovw_delta, (unsigned)curr, (unsigned)bnry, bcd,
                         (unsigned long long)(g_perf_rx_defer - p_df),
                         (unsigned long long)(g_perf_rx_drop  - p_dr),
                         (unsigned)host_rx_queue_count,
                         (unsigned long long)g_perf_recv_us_max,
                         (unsigned long long)g_perf_recv_frames_max,
                         (unsigned long long)g_perf_rx_copy_us_max,
                         (unsigned long long)g_perf_tx_win_clamped,
                         (unsigned long long)g_perf_rx_oversize,
                         (unsigned long long)g_perf_rx_seg,
                         (unsigned long long)g_perf_rx_csum_fix,
                         (unsigned long long)g_perf_rx_padded,
                         (unsigned long long)g_perf_rx_echo_drop,
                         (unsigned long long)g_perf_rx_dup_drop,
                         (unsigned)g_perf_csum_bg, (unsigned)(g_sent_csum_run & 0xFFFF),
                         (unsigned)g_perf_cnt_bg, (unsigned)g_sent_frame_count,
                         (unsigned)g_perf_deliv_bad_frame,
                         (unsigned long long)g_perf_wr_bad,
                         (unsigned)g_perf_rb_bad, (unsigned)g_perf_rb_csum_run,
                         (unsigned)g_perf_ring_wr, (unsigned)g_perf_dp_rd,
                         (unsigned long long)g_perf_rd_bad,
                         (unsigned)g_perf_rd_corrupt, (unsigned)g_perf_rd_checked,
                         (unsigned)g_perf_rd_bad_exp,
                         (unsigned)g_perf_rd_bad_act,
                         (unsigned)g_perf_tx_mirror_csum,
                         (unsigned)g_perf_tx_mirror_frames,
                         (unsigned)g_perf_tx_mirror_bytes,
                         (unsigned)g_perf_tx_drain_csum,
                         (unsigned)g_perf_tx_drain_frames,
                         (unsigned)g_perf_tx_drain_bytes,
                         (unsigned)g_tx_hps_csum_run,
                         (unsigned)g_tx_hps_frame_count,
                         (unsigned)g_tx_hps_byte_count,
                         pls);
                p_rxf = g_perf_rx_frames; p_rxb = g_perf_rx_bytes;
                p_txf = g_perf_tx_frames; p_txb = g_perf_tx_bytes;
                p_pl  = g_perf_polls; p_df = g_perf_rx_defer; p_dr = g_perf_rx_drop;
                p_bc  = g_perf_bcast_drop; p_ovw = ovw; p_zw = g_perf_tx_zerowin;
                p_tm  = g_perf_tx_miss; p_retx = g_perf_rx_retx; p_da = g_perf_dup_ack;
                p_gap = g_perf_rx_gap;  p_txd = g_perf_tx_drop;
                g_perf_tx_win_min = 0xFFFFFFFF;   // reset per-interval min
                g_perf_recv_us_max = 0;           // reset per-interval HPS probes
                g_perf_recv_frames_max = 0;
                g_perf_rx_copy_us_max = 0;
                perf_last = perf_now;
            }
        }
        
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
            (void)cr_reg; (void)curr_reg; (void)bnry_reg; (void)rcr_reg;
            (void)isr_reg; (void)imr_reg; (void)raw_cr_word;
            (void)tx_complete_seq; (void)enabled; (void)rx_active;
            //minimig_eth_test();
        }
        
        // FPGA handles all register management directly via shared memory

        // Handle transmit request
        if ((flags & ETH_FLAG_TX_REQ) || tx_sequence_pending) {
            struct tx_request request = read_shared_tx_request();
            if ((request.seq != 0) && (request.seq != hps_last_tx_complete_seq)) {
                // Detect TX frames the FPGA staged but we never sent: the seq
                // should advance by exactly 1; a larger gap means the single shm
                // TX buffer was overwritten before we drained it (lost ACKs).
                if (hps_last_tx_complete_seq != 0) {
                    uint16_t tx_gap = (uint16_t)(request.seq - hps_last_tx_complete_seq);
                    if (tx_gap > 1) g_perf_tx_miss += (tx_gap - 1);
                }
                eth_update_shared_status(ETH_STATUS_TX_OK | ETH_STATUS_TX_ERR, 0);
                bool tx_ok = transmit_packet(&request);
                if (tx_ok) { g_perf_tx_frames++; g_perf_tx_bytes += request.len; }
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
        
        // Check for incoming packets (timed: HPS-bottleneck probe -- worst-case
        // receive_packet() duration and frames-drained-per-call per interval).
        {
            uint64_t recv_t0 = eth_mono_us();
            uint64_t recv_f0 = g_perf_rx_frames;
            receive_packet();
            uint64_t recv_us = eth_mono_us() - recv_t0;
            uint64_t recv_df = g_perf_rx_frames - recv_f0;
            if (recv_us > g_perf_recv_us_max)       g_perf_recv_us_max = recv_us;
            if (recv_df > g_perf_recv_frames_max)   g_perf_recv_frames_max = recv_df;
        }
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
        (void)shared_mac; (void)flags; (void)state;
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
    (void)cr_reg; (void)isr_reg;
    
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
    (void)flags;
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
