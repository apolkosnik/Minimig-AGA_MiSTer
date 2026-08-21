#!/usr/bin/env python3
"""Compare AP040 PTEST MMUSR results against WinUAE cpummu.cpp reference."""
import sys

MMUSR_A = 0x3000
DUMP_BASE = 0x3000


def main():
    words = [int(w, 16) for w in open(sys.argv[1]).read().split()]
    ref = [l.split() for l in open(sys.argv[2]) if l.strip()]
    # 8K page mode: MMUSR bit 12 is inside the page offset.  AP040 reports
    # the true translated PA (PA[12] = VA[12], which is what WinUAE's own
    # mmu_translate produces); WinUAE's PTEST path reports the frame with
    # bit 12 masked.  Compare modulo that reporting difference.
    mask = 0xFFFFFFFF
    try:
        import os.path
        pf = os.path.join(os.path.dirname(sys.argv[1]) or ".", "mmu_probes.txt")
        cfg = open(pf).readline().split()
        if len(cfg) == 4 and int(cfg[3], 16) & 0x4000:
            mask = 0xFFFFEFFF
    except OSError:
        pass
    base = (MMUSR_A - DUMP_BASE) // 2
    bad = 0
    for i, r in enumerate(ref):
        la, rv = r[0], int(r[1], 16)
        ap = (words[base + 2 * i] << 16) | words[base + 2 * i + 1]
        if (ap & mask) != (rv & mask):
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
