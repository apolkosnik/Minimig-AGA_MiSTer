#!/usr/bin/env python3
"""Build one 68040 page table and a PTEST probe list, emitted twice: as an
assembly program for AP040 and as a memory image plus probe file for
mmu_oracle (WinUAE's own cpummu.cpp).

Both sides therefore walk byte-identical tables with identical probes, so a
difference names a translation rule rather than a program difference.  Only
PTEST is compared: it reports the full MMUSR -- resident, write-protect,
supervisor, modified, global, U bits, cache mode and the physical address --
without needing the access itself to succeed.
"""
import random
import struct
import sys

# The testbench models 64K, so the tables live inside it.  With 4K pages the
# root index is addr[31:25] and the pointer index addr[24:18], so logical
# addresses below $40000 use root[0] and pointer[0] only.
TBL_ROOT = 0x00004000      # root table
TBL_PTR  = 0x00004200      # pointer table
TBL_PAGE = 0x00004400      # page table, 64 entries
MMUSR_A  = 0x00003000      # PTEST results, inside the tb dump window
NPROBE   = 48

# Logical pages 0-63 of 4K.  Pages 0-15 back the program itself and stay
# identity mapped; the rest carry randomised attributes.
IDENT_MAX = 16


def build(seed):
    r = random.Random(seed)
    attr = {}
    for p in range(64):
        if p < IDENT_MAX:
            attr[p] = (p, 0, 0, 0, 0)          # phys, wp, super, cm, global
        else:
            attr[p] = (r.randint(16, 63),
                       r.randrange(2),          # write protected
                       r.randrange(2),          # supervisor only
                       r.randrange(4),          # cache mode
                       r.randrange(2))          # global
    resident = {p: (p < IDENT_MAX or r.randrange(8) != 0) for p in range(64)}
    # Pages the PROGRAM itself writes while translation is enabled would
    # have their M bit set by those writes, which the oracle -- which only
    # probes -- never sees.  Page 3 holds the result array; skip it so the
    # comparison stays about translation rules rather than about the
    # harness's own footprint.
    RESULT_PAGE = MMUSR_A >> 12
    probes = []
    for _ in range(NPROBE):
        page = r.randrange(64)
        while page == RESULT_PAGE:
            page = r.randrange(64)
        off = r.randrange(0, 0x1000, 4)
        probes.append((page * 0x1000 + off, r.randrange(2), r.randrange(2)))
    return attr, resident, probes


def page_desc(attr, resident, p):
    phys, wp, sup, cm, g = attr[p]
    if not resident[p]:
        return 0
    return ((phys << 12) | (g << 10) | (sup << 7) | (cm << 5)
            | (wp << 2) | 0x1)                  # PDT = 01 resident


def main():
    seed = int(sys.argv[1])
    attr, resident, probes = build(seed)

    # ---- memory image for the oracle -------------------------------------
    mem = bytearray(0x200000)

    def putl(a, v):
        struct.pack_into(">I", mem, a, v & 0xFFFFFFFF)

    # one root entry -> one pointer entry -> the 64-entry page table
    putl(TBL_ROOT, TBL_PTR | 0x3)               # UDT = 11 resident
    putl(TBL_PTR,  TBL_PAGE | 0x3)
    for p in range(64):
        putl(TBL_PAGE + p * 4, page_desc(attr, resident, p))

    with open(sys.argv[2], "wb") as f:
        f.write(mem)

    with open(sys.argv[3], "w") as f:
        f.write("cfg %08x %08x %08x\n" % (TBL_ROOT, TBL_ROOT, 0x8000))
        for la, sup, wr in probes:
            f.write("probe %08x %d 1 %d\n" % (la, sup, wr))

    # ---- assembly program for AP040 --------------------------------------
    out = ["\torg\t0", "\tdc.l\t$2F00", "\tdc.l\tstart", "\trept\t254",
           "\tdc.l\tunexp", "\tendr", "", "\torg\t$400", "start:",
           "\tmove.w\t#$2700,sr", "\tmovea.l\t#$2F00,sp"]
    # build the same tables in RAM
    out.append("\tmove.l\t#$%X,($%X).l" % (TBL_PTR | 0x3, TBL_ROOT))
    out.append("\tmove.l\t#$%X,($%X).l" % (TBL_PAGE | 0x3, TBL_PTR))
    for p in range(64):
        out.append("\tmove.l\t#$%X,($%X).l"
                   % (page_desc(attr, resident, p), TBL_PAGE + p * 4))
    out.append("\tmove.l\t#$%X,d0" % TBL_ROOT)
    out.append("\tmovec\td0,urp")
    out.append("\tmovec\td0,srp")
    out.append("\tmove.l\t#$8000,d0")
    out.append("\tmovec\td0,tc")
    out.append("\tpflusha")
    out.append("\tlea\t($%X).l,a1" % MMUSR_A)
    for la, sup, wr in probes:
        out.append("\tmove.l\t#$%X,a0" % la)
        out.append("\tmoveq\t#%d,d0" % (1 | (4 if sup else 0)))   # DFC: data space
        out.append("\tmovec\td0,dfc")
        out.append("\tptest%s\t(a0)" % ("w" if wr else "r"))
        out.append("\tmovec\tmmusr,d0")
        out.append("\tmove.l\td0,(a1)+")
    out.append("\tmoveq\t#0,d0")
    out.append("\tmovec\td0,tc")
    out.append("\tpflusha")
    out.append("\tmove.w\t#$600D,($F102).l")
    out.append("stop1:")
    out.append("\tbra\tstop1")
    out.append("unexp:")
    out.append("\tmove.w\t#$BAD0,($3FFE).l")
    out.append("\tmove.w\t#$BAD0,($F102).l")
    out.append("stop2:")
    out.append("\tbra\tstop2")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
