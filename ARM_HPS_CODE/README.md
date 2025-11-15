# ARM/HPS Ethernet Code for Minimig NE2000

This directory contains the ARM-side Linux code for the NE2000 Ethernet implementation.

## Files

- **minimig_eth.h** - Header file with API definitions
- **minimig_eth.cpp** - Implementation of TAP device and FPGA communication
- **minimig_eth_integration.txt** - Instructions for integrating into Main_MiSTer

## How It Works

### Architecture

```
Amiga (FPGA)           ARM Linux (HPS)          Linux Network
    |                        |                       |
    | TX packet             |                       |
    |--------------------->|                       |
    |  (0x64 status poll)   | Read from NE2000     |
    |  (0x61 + 0xF400)      | TX buffer            |
    |                       |--------------------->|
    |                       | write() to TAP       |
    |                       |                       |
    |                       | Packet from network  |
    |  RX packet           |<---------------------|
    |<---------------------|  read() from TAP      |
    |  (0x61 + 0xF401)      | Write to NE2000      |
    |                       | RX buffer            |
```

### Protocol

**Status Query (Command 0x64):**
- ARM polls FPGA status register
- Returns 32-bit status word
- Checks for TX_PENDING (0xA5)

**TX Read (Command 0x61 + 0xF400):**
- ARM reads packet from FPGA when TX_PENDING
- Forwards to TAP device
- TAP device sends to Linux network stack

**RX Write (Command 0x61 + 0xF401):**
- ARM reads from TAP device (select/poll)
- Writes packet to FPGA RX buffer
- FPGA generates interrupt to Amiga

**MAC Config (Command 0x61 + 0xF402):**
- ARM writes 6-byte MAC address to FPGA
- Done once at initialization

## Integration Steps

### 1. Add to Main_MiSTer Build

Copy files to Main_MiSTer repository:
```bash
cp minimig_eth.h minimig_eth.cpp /path/to/Main_MiSTer/support/minimig/
```

Update Main_MiSTer Makefile:
```makefile
SOURCES += support/minimig/minimig_eth.cpp
```

### 2. Initialize in Minimig Core

In `support/minimig/minimig_boot.cpp` or main loop:

```cpp
#include "support/minimig/minimig_eth.h"

// During Minimig initialization:
uint8_t mac_addr[6] = {0x00, 0x80, 0x10, 0x12, 0x34, 0x56};  // Or from config
if (minimig_eth_init("tap0", mac_addr) == 0) {
    printf("Minimig ethernet enabled\n");
}
```

### 3. Add to Main Loop

In the main event loop (probably in `minimig.cpp` or main loop):

```cpp
void minimig_poll() {
    // ... existing code ...

    // Poll ethernet (call frequently, 100-1000 Hz recommended)
    minimig_eth_poll();
}
```

### 4. Shutdown on Exit

In cleanup code:

```cpp
void minimig_shutdown() {
    minimig_eth_shutdown();
    // ... other cleanup ...
}
```

### 5. Configure TAP Device on Linux

On MiSTer Linux, create TAP device and bridge to network:

```bash
# Create TAP device
sudo ip tuntap add dev tap0 mode tap user root

# Bring it up
sudo ip link set tap0 up

# Option A: Bridge to eth0 for direct network access
sudo brctl addbr br0
sudo brctl addif br0 eth0
sudo brctl addif br0 tap0
sudo ip link set br0 up

# Option B: NAT for internet access
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i tap0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tap0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo sysctl -w net.ipv4.ip_forward=1
```

## Configuration Options

### MAC Address

Default: Randomly generated locally-administered MAC (02:xx:xx:xx:xx:xx)

To specify custom MAC:
```cpp
uint8_t mac[6] = {0x00, 0x80, 0x10, 0xAA, 0xBB, 0xCC};
minimig_eth_init("tap0", mac);
```

### TAP Device Name

Default: "tap0"

To use different device:
```cpp
minimig_eth_init("tap1", NULL);  // Uses tap1
```

### Poll Frequency

Call `minimig_eth_poll()` from your main loop. Recommended frequency:
- 100 Hz minimum (every 10ms)
- 1000 Hz optimal (every 1ms)

## Amiga Side Setup

### 1. Install NE2000 Driver

The Amiga needs an NE2000-compatible driver. Options:

**For Workbench:**
- Use `a2065.device` driver (NE2000 compatible)
- Configure for base address $EA0000
- IRQ level 2

**For AmiTCP:**
```
; In AmiTCP configuration
Device=a2065.device
Unit=0
IPAddress=192.168.1.100
Netmask=255.255.255.0
Gateway=192.168.1.1
```

**For Miami:**
Use Miami's built-in NE2000 support, configure for $EA0000, INT2.

### 2. Test Connectivity

On Amiga:
```
ping 192.168.1.1
```

On MiSTer Linux:
```bash
ping 192.168.1.100  # Amiga's IP
tcpdump -i tap0     # Watch traffic
```

## Debugging

### Enable Debug Prints

Modify minimig_eth.cpp to add verbose logging:

```cpp
#define ETH_DEBUG 1

#if ETH_DEBUG
#define eth_debug(fmt, ...) printf("[ETH DEBUG] " fmt "\n", ##__VA_ARGS__)
#else
#define eth_debug(fmt, ...)
#endif
```

### Check Status

Add to poll function:
```cpp
if (tx_packets % 100 == 0) {
    printf("[ETH] Stats: TX=%u RX=%u\n", tx_packets, rx_packets);
}
```

### TAP Device Troubleshooting

```bash
# Check if TAP exists
ip link show tap0

# Check traffic
tcpdump -i tap0 -n

# Check bridging
brctl show

# Check routing
route -n
ip route show
```

## Performance

Expected performance on MiSTer:
- Throughput: 500-800 KB/s (NE2000 is 10 Mbps)
- Latency: 1-5 ms (depends on poll frequency)
- CPU usage: <5% on ARM

## Known Limitations

1. **No Autoconfig**: NE2000 is at fixed address $EA0000 (no Zorro autoconfig yet)
2. **Single Instance**: Only one ethernet device supported
3. **No Promiscuous Mode**: Standard NE2000 filtering only
4. **10 Mbps**: NE2000 spec limitation (not 100 Mbps)

## Future Enhancements

- [ ] Zorro II autoconfig support for dynamic addressing
- [ ] Configurable base address
- [ ] Multiple TAP devices for multiple instances
- [ ] Packet filtering/firewall integration
- [ ] Performance statistics/monitoring
- [ ] DHCP server integration for Amiga

## License

GPLv3 (matching Main_MiSTer and Minimig licenses)

## References

- NE2000 Datasheet: National Semiconductor DP8390D
- Linux TAP: https://www.kernel.org/doc/Documentation/networking/tuntap.txt
- MiSTer Main: https://github.com/MiSTer-devel/Main_MiSTer
- Minimig-AGA: https://github.com/apolkosnik/Minimig-AGA_MiSTer
