#!/usr/bin/env python3
"""Compare the AP040 $writememh dump with the QEMU pmemsave dump.

By default the CCR log region ($3800-$3EFF) is excluded: qemu 11's m68k
lazy flag evaluation produces PRM-inconsistent X-op and MUL.L flags in
certain instruction contexts (see README); AP040 flag correctness is
covered by the directed suites and the hand-truth programs instead.
Pass --strict to compare the flag log too."""
import sys

def load_ap040(path):
    words = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("@"):
            continue
        words.append(int(line, 16))
    data = bytearray()
    for w in words:
        data += bytes([(w >> 8) & 0xFF, w & 0xFF])
    return bytes(data)

def main():
    a = load_ap040(sys.argv[1])
    q = open(sys.argv[2], "rb").read()
    strict = "--strict" in sys.argv
    masked = set()
    if not strict:
        for i in range(0x800, 0xF00):
            masked.add(i)
        masked.add(0xF38)      # final CCR store: same qemu flag caveat
        masked.add(0xF39)
    if len(sys.argv) > 3 and sys.argv[3] != "--strict":
        for line in open(sys.argv[3]):
            e = int(line)
            masked.add(0x800 + 2 * e)
            masked.add(0x800 + 2 * e + 1)
    n = min(len(a), len(q), 0x1000)
    bad = 0
    for i in range(n):
        if i in masked:
            continue
        if a[i] != q[i]:
            if bad < 8:
                print("  mismatch at $%04X: ap040=%02X qemu=%02X"
                      % (0x3000 + i, a[i], q[i]))
            bad += 1
    if bad:
        print("  %d differing byte(s)" % bad)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
