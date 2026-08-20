#!/usr/bin/env python3
"""Compare AP040 PTEST MMUSR results against WinUAE cpummu.cpp reference."""
import sys

MMUSR_A = 0x3000
DUMP_BASE = 0x3000


def main():
    words = [int(w, 16) for w in open(sys.argv[1]).read().split()]
    ref = [l.split() for l in open(sys.argv[2]) if l.strip()]
    base = (MMUSR_A - DUMP_BASE) // 2
    bad = 0
    for i, r in enumerate(ref):
        la, rv = r[0], int(r[1], 16)
        ap = (words[base + 2 * i] << 16) | words[base + 2 * i + 1]
        if ap != rv:
            bad += 1
            if bad <= 10:
                d = ap ^ rv
                bits = [n for n, b in ((("R", 0), ("T", 1), ("W", 2), ("M", 4),
                                        ("CM", 5), ("CM", 6), ("S", 7),
                                        ("U0", 8), ("U1", 9), ("G", 10),
                                        ("B", 11)))
                        if d & (1 << b)]
                if d & 0xFFFFF000:
                    bits.append("PHYS")
                print("  probe %2d %s  AP=%08X  WinUAE=%08X  differs in %s"
                      % (i, la, ap, rv, ",".join(bits) or "?"))
    if bad:
        print("%d/%d probes differ" % (bad, len(ref)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
