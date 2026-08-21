#!/usr/bin/env python3
# mmap-based physical memory reader for the MiSTer's core DDR3 window
import mmap, os, sys, struct
base = int(sys.argv[1], 16)
length = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x100000
out = sys.argv[3] if len(sys.argv) > 3 else None
PAGE = 4096
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
off = base & ~(PAGE - 1)
delta = base - off
m = mmap.mmap(fd, length + delta, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
data = m[delta:delta + length]
if out:
    with open(out, "wb") as f: f.write(data)
    print("wrote %d bytes from %08x to %s" % (len(data), base, out))
else:
    sys.stdout.buffer.write(data)
