#!/usr/bin/env python3
"""Generate a random MMU program for AP040 vs qemu comparison.

Layout (all of it identity mapped so the program can run with the MMU on):

  page 0   $0000  vectors and code
  page 3   $3000  evidence window that both sides dump and compare
  page 4   $4000  stack and translation tables
  pages 8-31      randomly attributed data pages: some identity, some
                  remapped into pages 32-63, some write protected
  pages 32-63     physical backing for the remapped pages

The program enables the MMU, performs a random stream of translated reads,
writes and PTEST probes, then disables the MMU and copies the evidence into
the compared window:

  $3800  values read back through the translations
  $3A00  the page table itself, which carries the U and M history bits the
         hardware updates during the walks
  $3B00  root and pointer descriptors (their U bits)
  $3B10  MMUSR results from the PTEST probes

Writes are never generated against a write-protected page and every mapping
is resident, so no access error is taken: fault frames are format $7 on
AP040 and a different shape on qemu, and are covered by t_mmu.s instead.
A PFLUSHA follows every TC write because neither real 040 hardware nor AP040
implicitly flushes the ATCs on an MMU-register write; software must request
the flush when translations may have changed.  The M history bit is cleared
in the evidence copies because qemu does not maintain it at all (AP040 does,
as 040 hardware must; t_mmu.s asserts it).
"""
import random
import sys

TBL_PAGE = 0x4400          # page table, 64 entries
TBL_PTR  = 0x4200          # pointer table
TBL_ROOT = 0x4000          # root table
RESULTS  = 0x5000          # read-back values, copied into the window later
MMUSR_A  = 0x5400          # PTEST results
EV_READ  = 0x3800
EV_TABLE = 0x3A00
EV_ROOT  = 0x3B00
EV_MMUSR = 0x3B10

# The testbench models 64K of memory, so everything lives in pages 0-15.
#   0-2 code   3 evidence window   4 stack+tables   5 result arrays
FIXED = {0, 1, 2, 3, 4, 5}
DATA_LO, DATA_HI = 6, 11       # randomly attributed logical pages
PHYS_LO, PHYS_HI = 12, 14      # backing pages for remapped entries
# Page 15 ($F000-$FFFF) is never mapped or filled: it holds the testbench's
# memory-mapped protocol registers ($F100 fail number, $F102 result).


class MmuGen:
    def __init__(self, seed, count):
        self.r = random.Random(seed)
        self.count = count
        self.lines = []
        self.attr = {}          # logical page -> (phys page, write protected)
        for p in range(64):
            self.attr[p] = (p, False)
        used = list(range(PHYS_LO, PHYS_HI + 1))
        self.r.shuffle(used)
        for p in range(DATA_LO, DATA_HI + 1):
            roll = self.r.randrange(3)
            if roll == 0 and used:
                self.attr[p] = (used.pop(), False)        # remapped
            elif roll == 1:
                self.attr[p] = (p, True)                  # write protected
            else:
                self.attr[p] = (p, False)                 # plain identity

    def emit(self, s):
        self.lines.append("\t" + s)

    def descriptor(self, page):
        phys, wp = self.attr[page]
        return (phys << 12) | (0x4 if wp else 0) | 0x3   # resident, U/M clear

    def gen_one(self, i):
        page = self.r.randint(DATA_LO, DATA_HI)
        off = self.r.randrange(0, 0x1000, 4)
        la = page * 0x1000 + off
        _, wp = self.attr[page]
        k = self.r.randrange(4)

        if k == 0 and not wp:
            # write then read back through the same translation
            self.emit("move.l\t#$%08X,($%X).l" % (self.r.getrandbits(32), la))
            self.emit("move.l\t($%X).l,($%X).l" % (la, RESULTS + i * 4))
        elif k == 1:
            self.emit("move.l\t($%X).l,($%X).l" % (la, RESULTS + i * 4))
        elif k == 2 and not wp:
            # byte and word accesses exercise the same translation path
            self.emit("move.b\t#$%02X,($%X).l" % (self.r.getrandbits(8), la + 1))
            self.emit("move.w\t#$%04X,($%X).l" % (self.r.getrandbits(16), la + 2))
            self.emit("move.l\t($%X).l,($%X).l" % (la, RESULTS + i * 4))
        else:
            # PTEST records the translation the hardware would use
            self.emit("lea\t($%X).l,a1" % la)
            self.emit("moveq\t#5,d0")
            self.emit("movec\td0,dfc")
            self.emit("ptestr\t(a1)")
            self.emit("movec\tmmusr,d0")
            self.emit("move.l\td0,($%X).l" % (MMUSR_A + i * 4))

    def clear_m_bits(self, dst, longs):
        """qemu does not maintain the M (modified) history bit, so clear it
        in the copies: translation, protection and the U bit still compare."""
        self.emit("lea\t($%X).l,a0" % dst)
        self.emit("move.w\t#%d,d0" % (longs - 1))
        lbl = "mm%X" % dst
        self.lines.append("%s:" % lbl)
        self.emit("move.l\t(a0),d1")
        self.emit("and.l\t#$FFFFFFEF,d1")
        self.emit("move.l\td1,(a0)+")
        self.emit("dbra\td0,%s" % lbl)

    def copy_block(self, src, dst, longs):
        self.emit("lea\t($%X).l,a0" % src)
        self.emit("lea\t($%X).l,a1" % dst)
        self.emit("move.w\t#%d,d0" % (longs - 1))
        lbl = "cp%X" % dst
        self.lines.append("%s:" % lbl)
        self.emit("move.l\t(a0)+,(a1)+")
        self.emit("dbra\td0,%s" % lbl)

    def generate(self):
        out = ["\torg\t0", "\tdc.l\t$4000", "\tdc.l\tstart",
               "\trept\t254", "\tdc.l\tunexp", "\tendr", "",
               "\torg\t$400", "start:",
               "\tmove.w\t#$2700,sr", "\tmovea.l\t#$4000,sp"]

        # translation tables
        for p in range(64):
            self.emit("move.l\t#$%08X,($%X).l"
                      % (self.descriptor(p), TBL_PAGE + p * 4))
        self.emit("move.l\t#$%08X,($%X).l" % (TBL_PAGE | 3, TBL_PTR))
        self.emit("move.l\t#$%08X,($%X).l" % (TBL_PTR | 3, TBL_ROOT))

        # deterministic starting contents for every page that can be read
        self.emit("lea\t($6000).l,a0")
        self.emit("move.l\t#$%08X,d1" % self.r.getrandbits(32))
        self.emit("move.w\t#%d,d0" % (0x2400 - 1))     # $6000..$EFFF
        self.lines.append("fill:")
        self.emit("move.l\td1,(a0)+")
        self.emit("addq.l\t#1,d1")
        self.emit("dbra\td0,fill")
        self.emit("lea\t($%X).l,a0" % RESULTS)
        self.emit("moveq\t#0,d1")
        self.emit("move.w\t#%d,d0" % (0x100 - 1))
        self.lines.append("clr1:")
        self.emit("move.l\td1,(a0)+")
        self.emit("dbra\td0,clr1")

        # enable translation
        self.emit("move.l\t#$%X,d0" % TBL_ROOT)
        self.emit("movec\td0,urp")
        self.emit("movec\td0,srp")
        self.emit("move.l\t#$8000,d0")
        self.emit("movec\td0,tc")
        self.emit("pflusha")

        for i in range(self.count):
            self.gen_one(i)

        # disable translation, then gather the evidence physically
        self.emit("moveq\t#0,d0")
        self.emit("movec\td0,tc")
        self.emit("pflusha")
        self.copy_block(RESULTS, EV_READ, self.count)
        self.copy_block(TBL_PAGE, EV_TABLE, 64)
        self.copy_block(TBL_ROOT, EV_ROOT, 1)
        self.copy_block(TBL_PTR, EV_ROOT + 4, 1)
        self.copy_block(MMUSR_A, EV_MMUSR, self.count)
        self.clear_m_bits(EV_TABLE, 64)
        self.clear_m_bits(EV_MMUSR, self.count)

        out.extend(self.lines)
        out.append("\tmove.w\t#$600D,($F102).l")
        out.append("stop1:")
        out.append("\tbra\tstop1")
        out.append("unexp:")
        out.append("\tmove.w\t#$BAD0,($3FFE).l")
        out.append("\tmove.w\t#$BAD0,($F102).l")
        out.append("stop2:")
        out.append("\tbra\tstop2")
        return "\n".join(out) + "\n"


if __name__ == "__main__":
    seed = int(sys.argv[1])
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    sys.stdout.write(MmuGen(seed, count).generate())
