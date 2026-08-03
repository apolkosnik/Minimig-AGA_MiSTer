#!/usr/bin/env python3
"""Differential test program generator: AP040 vs QEMU 68040.

Emits a self-contained vasm program: randomized integer instructions with
fully defined condition codes, a CCR trace after every instruction and a
final register dump. The same flat binary runs on the AP040 testbench and
on qemu-system-m68k; the memory window $3000-$3FFF must match exactly.
"""
import random
import sys

SANDBOX_LO = 0x3000
SANDBOX_HI = 0x37F0
LOG_BASE   = 0x3800
REGS_BASE  = 0x3F00

class Gen:
    def __init__(self, seed, count):
        self.r = random.Random(seed)
        self.count = count
        self.an = {}
        self.lines = []
        self.mask = []        # log entries whose flags are not compared
        self.log_idx = 0
        self.resync = None
        self.trunc = count    # emit only the first trunc ops (same RNG draws)

    def gen_one_discard(self):
        keep = len(self.lines)
        self.gen_one()
        del self.lines[keep:]

    def emit(self, s):
        self.lines.append("\t" + s)

    def dreg(self):
        return "d%d" % self.r.randrange(8)

    def areg(self):
        return "a%d" % self.r.randrange(6)

    def imm32(self):
        return self.r.choice([
            0, 1, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF,
            0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
            self.r.getrandbits(32), self.r.getrandbits(32),
            self.r.getrandbits(16), self.r.getrandbits(8)])

    def sandbox_addr(self, align):
        a = self.r.randrange(SANDBOX_LO, SANDBOX_HI)
        return a & ~(align - 1)

    def mem_ea(self, align, writable=True):
        c = self.r.randrange(8)
        if c == 0:
            return "($%X).l" % self.sandbox_addr(align)
        if c == 1:
            return "($%X).w" % self.sandbox_addr(align)
        if c == 2:
            # deliberately misaligned: both sides must split identically
            return "($%X).l" % (self.sandbox_addr(1) | 1)
        n = self.r.randrange(6)
        base = self.an[n]
        if c == 3:
            tgt = self.sandbox_addr(align)
            d = tgt - base
            if -0x8000 <= d <= 0x7FFF:
                return "%d(a%d)" % (d, n)
        if c == 4 and SANDBOX_LO <= base < SANDBOX_HI - 8:
            self.an[n] = base + {1: 1, 2: 2, 4: 4}.get(align, align)
            return "(a%d)+" % n
        if c == 5 and SANDBOX_LO + 8 < base <= SANDBOX_HI:
            self.an[n] = base - {1: 1, 2: 2, 4: 4}.get(align, align)
            return "-(a%d)" % n
        if c == 6:
            # brief indexed with a controlled index register
            dn = self.r.randrange(8)
            idx = self.r.randrange(0, 64) & ~1
            self.emit("moveq #%d,d%d" % (idx, dn))
            tgt = self.sandbox_addr(align)
            d = tgt - base - idx
            if -128 <= d <= 127:
                return "(%d,a%d,d%d.l)" % (d, n, dn)
        return "($%X).l" % self.sandbox_addr(align)

    def size(self):
        return self.r.choice(["b", "w", "l"])

    def imm_sz(self, sz):
        m = {"b": 0xFF, "w": 0xFFFF, "l": 0xFFFFFFFF}[sz]
        return self.imm32() & m

    def gen_one(self):
        r = self.r
        c = r.randrange(100)
        if c < 14:
            sz = self.size()
            align = {"b": 1, "w": 2, "l": 2}[sz]
            k = r.randrange(4)
            if k == 0:
                self.emit("move.%s #$%X,%s" % (sz, self.imm_sz(sz), self.dreg()))
            elif k == 1:
                self.emit("move.%s %s,%s" % (sz, self.dreg(), self.dreg()))
            elif k == 2:
                self.emit("move.%s %s,%s" % (sz, self.dreg(), self.mem_ea(align)))
            else:
                self.emit("move.%s %s,%s" % (sz, self.mem_ea(align), self.dreg()))
        elif c < 30:
            op = r.choice(["add", "sub", "and", "or", "eor", "cmp"])
            sz = self.size()
            align = {"b": 1, "w": 2, "l": 2}[sz]
            k = r.randrange(4)
            if op == "eor" and k >= 2:
                k = 1
            if k == 0:
                self.emit("%s.%s #$%X,%s" % ("cmpi" if op == "cmp" else op + "i",
                                             sz, self.imm_sz(sz), self.dreg()))
            elif k == 1 or op == "cmp":
                self.emit("%s.%s %s,%s" % (op, sz, self.dreg(), self.dreg()))
            elif k == 2 and op != "eor":
                self.emit("%s.%s %s,%s" % (op, sz, self.mem_ea(align), self.dreg()))
            else:
                self.emit("%s.%s %s,%s" % (op, sz, self.dreg(), self.mem_ea(align)))
        elif c < 36:
            op = r.choice(["not", "neg", "negx", "tst", "clr"])
            sz = self.size()
            if r.randrange(2):
                self.emit("%s.%s %s" % (op, sz, self.dreg()))
            else:
                self.emit("%s.%s %s" % (op, sz, self.mem_ea({"b":1,"w":2,"l":2}[sz])))
            if op == "negx":
                self.mask.append(self.log_idx)
                self.resync = r.randrange(32)
        elif c < 44:
            op = r.choice(["lsl", "lsr", "asl", "asr", "rol", "ror", "roxl", "roxr"])
            sz = self.size()
            if r.randrange(2):
                self.emit("%s.%s #%d,%s" % (op, sz, r.randrange(1, 9), self.dreg()))
            else:
                self.emit("%s.%s %s,%s" % (op, sz, self.dreg(), self.dreg()))
        elif c < 50:
            op = r.choice(["btst", "bset", "bclr", "bchg"])
            if r.randrange(2):
                self.emit("%s #%d,%s" % (op, r.randrange(32), self.dreg()))
            else:
                self.emit("%s %s,%s" % (op, self.dreg(), self.dreg()))
        elif c < 56:
            k = r.randrange(5)
            if k == 0: self.emit("ext.w %s" % self.dreg())
            elif k == 1: self.emit("ext.l %s" % self.dreg())
            elif k == 2: self.emit("extb.l %s" % self.dreg())
            elif k == 3: self.emit("swap %s" % self.dreg())
            else: self.emit("exg %s,%s" % (self.dreg(), self.dreg()))
        elif c < 62:
            k = r.randrange(4)
            if k == 0:
                self.emit("mulu.w %s,%s" % (self.dreg(), self.dreg()))
            elif k == 1:
                self.emit("muls.w #$%X,%s" % (self.imm32() & 0xFFFF, self.dreg()))
            elif k == 2:
                self.emit("mulu.l %s,%s" % (self.dreg(), self.dreg()))
            else:
                self.emit("muls.l #$%X,%s" % (self.imm32(), self.dreg()))
        elif c < 70:
            k = r.randrange(4)
            if k == 0:
                self.emit("moveq #%d,%s" % (r.randrange(-128, 128), self.dreg()))
            elif k == 1:
                n = r.randrange(6)
                v = self.sandbox_addr(2)
                self.an[n] = v
                self.emit("movea.l #$%X,a%d" % (v, n))
            elif k == 2:
                n = r.randrange(6)
                v = self.sandbox_addr(2)
                self.an[n] = v
                self.emit("lea ($%X).l,a%d" % (v, n))
            else:
                self.emit("cmpa.%s %s,%s" %
                          (r.choice(["w", "l"]), self.dreg(), self.areg()))
        elif c < 76:
            op = r.choice(["addq", "subq"])
            sz = self.size()
            q = r.randrange(1, 9)
            if r.randrange(2):
                self.emit("%s.%s #%d,%s" % (op, sz, q, self.dreg()))
            else:
                self.emit("%s.%s #%d,%s" % (op, sz, q, self.mem_ea({"b":1,"w":2,"l":2}[sz])))
        elif c < 82:
            # X-group ops: qemu 11 mis-evaluates Z after lazily generated
            # flags (see README); mask this log entry and resync CCR after
            op = r.choice(["addx", "subx"])
            self.emit("%s.%s %s,%s" % (op, self.size(), self.dreg(), self.dreg()))
            self.mask.append(self.log_idx)
            self.resync = r.randrange(32)
        elif c < 96:
            op = r.choice(["bftst", "bfset", "bfclr", "bfchg",
                           "bfextu", "bfexts", "bfffo", "bfins"])
            off = r.randrange(0, 32)
            wid = r.randrange(1, 33)
            if r.randrange(2):
                tgt = self.dreg()
                offs = "%d" % off
            else:
                tgt = "($%X).l" % self.sandbox_addr(1)
                off = r.randrange(-32, 64)
                if 0 <= off <= 31 and r.randrange(2):
                    offs = "%d" % off
                else:
                    # out-of-range offsets must come from a register
                    dn = self.dreg()
                    self.emit("move.l #%d,%s" % (off, dn))
                    offs = dn
            fld = "%s{%s:%d}" % (tgt, offs, wid)
            if op in ("bfextu", "bfexts", "bfffo"):
                self.emit("%s %s,%s" % (op, fld, self.dreg()))
            elif op == "bfins":
                self.emit("bfins %s,%s" % (self.dreg(), fld))
            else:
                self.emit("%s %s" % (op, fld))
        elif c < 97:
            sz = r.choice(["w", "l"])
            self.emit("cas.%s %s,%s,%s" %
                      (sz, self.dreg(), self.dreg(),
                       "($%X).l" % self.sandbox_addr(2)))
        elif c < 98:
            # divide with a known nonzero immediate divisor; overflow
            # leaves the registers unchanged on both sides
            d = r.randrange(1, 0xFFFF)
            k = r.randrange(4)
            if k == 0:
                self.emit("divu.w #%d,%s" % (d, self.dreg()))
            elif k == 1:
                self.emit("divs.w #%d,%s" % (d, self.dreg()))
            elif k == 2:
                self.emit("divu.l #%d,%s" % (d, self.dreg()))
            else:
                self.emit("divs.l #%d,%s" % (d, self.dreg()))
            # overflow makes N/Z undefined: mask this entry's flags
            self.mask.append(self.log_idx)
            self.resync = r.randrange(32)
        elif c < 99:
            base = self.sandbox_addr(4)
            regs = "d%d-d%d" % tuple(sorted(self.r.sample(range(8), 2)))
            if r.randrange(2):
                self.emit("movem.l %s,($%X).l" % (regs, base))
            else:
                self.emit("movem.l ($%X).l,%s" % (base, regs))
        else:
            n1, n2 = r.randrange(6), r.randrange(6)
            self.emit("cas2.l d0:d1,d2:d3,(a%d):(a%d)" % (n1, n2))

    def generate(self):
        out = []
        out.append("\torg\t0")
        out.append("\tdc.l\t$4000")
        out.append("\tdc.l\tstart")
        out.append("\trept\t254")
        out.append("\tdc.l\tunexp")
        out.append("\tendr")
        out.append("")
        out.append("\torg\t$400")
        out.append("start:")
        out.append("\tmove.w\t#$2700,sr")
        out.append("\tmovea.l\t#$4000,sp")
        out.append("\tlea\t($%X).l,a6" % LOG_BASE)
        for i in range(8):
            out.append("\tmove.l\t#$%X,d%d" % (self.r.getrandbits(32), i))
        for i in range(6):
            v = self.sandbox_addr(2)
            self.an[i] = v
            out.append("\tmovea.l\t#$%X,a%d" % (v, i))
        out.append("\tmove.w\t#0,ccr")
        for _ in range(self.count):
            self.resync = None
            if self.log_idx < self.trunc:
                self.gen_one()
                self.emit("move.w ccr,(a6)+")
            else:
                self.gen_one_discard()
            self.log_idx += 1
            if self.resync is not None and self.log_idx <= self.trunc:
                self.emit("move.w #%d,ccr" % self.resync)
        out.extend(self.lines)
        out.append("\tmovem.l\td0-d7/a0-a5,($%X).l" % REGS_BASE)
        out.append("\tmove.w\tccr,($%X).l" % (REGS_BASE + 0x38))
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
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 150
    g = Gen(seed, count)
    if len(sys.argv) > 4:
        g.trunc = int(sys.argv[4])
    sys.stdout.write(g.generate())
    if len(sys.argv) > 3:
        with open(sys.argv[3], "w") as f:
            for i in g.mask:
                f.write("%d\n" % i)
