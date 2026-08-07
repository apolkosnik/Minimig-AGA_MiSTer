#!/usr/bin/env python3
"""Generate a random floating-point program for AP040 vs qemu comparison.

The program builds a pool of constants in memory, loads FP0-FP7 from it,
runs a random stream of FPU instructions, then dumps FP0-FP7, FPCR and the
FPSR condition codes into the compared window ($3F40-$3FA7).

Value ranges are deliberately constrained so that both implementations stay
on their common ground:

  - all operands are normalized extended values with exponents within +/-20
    of 1.0, so no operation can overflow, underflow or denormalize.  AP040
    flushes underflow to zero and traps denormal operands to vector 55 (as
    040 silicon does); qemu computes them, so those inputs would compare
    unequal by design rather than by defect.
  - divisors are memory constants that are never zero, square roots are
    taken of absolute values, and no integer stores are generated, so no
    infinity, NaN or OPERR result is ever produced.  NaN payloads are
    implementation specific and would not compare.
  - only the FPSR condition codes are stored; the exception and accrued
    bytes are masked in the generator itself so both sides write the same
    value without needing comparator support.
"""
import os
import random
import sys

# FPDIFF_MODE: unset  extended precision, all rounding modes, all instructions
#              arith  all precisions/modes, arithmetic only (no register FMOVE)
#              all    everything; diverges on qemu's FMOVE precision bug
#              unfl   tiny operands at single/double precision: exercises
#                     gradual underflow (subnormal results)
MODE = os.environ.get("FPDIFF_MODE", "")

SANDBOX_LO = 0x3000
SANDBOX_HI = 0x37F0
POOL_BASE  = 0x3400          # constant pool, inside the compared window
FPDUMP     = 0x3F40          # 8 x 12 bytes
FPCR_OUT   = 0x3FA0
FPSR_OUT   = 0x3FA4

NPOOL = 8                    # extended constants
NSING = 4                    # single constants
NDOUB = 4                    # double constants


class FpGen:
    def __init__(self, seed, count):
        self.r = random.Random(seed)
        self.count = count
        self.lines = []

    def emit(self, s):
        self.lines.append("\t" + s)

    # ---------------------------------------------------------------- values
    def ext_value(self):
        """A normalized extended value near 1.0: (sign, exp, mantissa)."""
        sign = self.r.getrandbits(1)
        if MODE == "unfl":
            # just above the single-precision minimum, so products and
            # quotients land in the subnormal range for that precision
            exp = 16383 - 120 + self.r.randint(-4, 4)
        else:
            exp = 16383 + self.r.randint(-20, 20)
        man = (1 << 63) | self.r.getrandbits(63)
        return sign, exp, man

    def sing_value(self):
        sign = self.r.getrandbits(1)
        exp = 127 + self.r.randint(-20, 20)
        frac = self.r.getrandbits(23)
        return (sign << 31) | (exp << 23) | frac

    def doub_value(self):
        sign = self.r.getrandbits(1)
        exp = 1023 + self.r.randint(-20, 20)
        frac = self.r.getrandbits(52)
        return (sign << 63) | (exp << 52) | frac

    def pool_addr(self, i):
        return POOL_BASE + i * 16

    def sing_addr(self, i):
        return POOL_BASE + NPOOL * 16 + i * 4

    def doub_addr(self, i):
        return POOL_BASE + NPOOL * 16 + NSING * 4 + i * 8

    # ------------------------------------------------------------- generation
    def build_pool(self):
        for i in range(NPOOL):
            s, e, m = self.ext_value()
            a = self.pool_addr(i)
            self.emit("move.l\t#$%08X,($%X).l" % ((s << 31) | (e << 16), a))
            self.emit("move.l\t#$%08X,($%X).l" % (m >> 32, a + 4))
            self.emit("move.l\t#$%08X,($%X).l" % (m & 0xFFFFFFFF, a + 8))
        for i in range(NSING):
            self.emit("move.l\t#$%08X,($%X).l"
                      % (self.sing_value(), self.sing_addr(i)))
        for i in range(NDOUB):
            v = self.doub_value()
            a = self.doub_addr(i)
            self.emit("move.l\t#$%08X,($%X).l" % (v >> 32, a))
            self.emit("move.l\t#$%08X,($%X).l" % (v & 0xFFFFFFFF, a + 4))

    def gen_one(self):
        if MODE in ("arith", "unfl"):
            # arithmetic and rounding control only: no FMOVE into a register,
            # which is where qemu diverges (it ignores the FPCR precision)
            k = self.r.choice([0, 1, 2, 3, 4, 5, 6, 13])
        else:
            k = self.r.randrange(14)
        d = self.r.randrange(8)
        s = self.r.randrange(8)
        p = self.r.randrange(NPOOL)

        if k == 0:
            self.emit("fadd.x\tfp%d,fp%d" % (s, d))
        elif k == 1:
            self.emit("fsub.x\tfp%d,fp%d" % (s, d))
        elif k == 2:
            self.emit("fmul.x\tfp%d,fp%d" % (s, d))
        elif k == 3:
            # divisor is always a nonzero constant, never a register
            self.emit("fdiv.x\t($%X).l,fp%d" % (self.pool_addr(p), d))
        elif k == 4:
            self.emit("fabs.x\tfp%d" % d)
            self.emit("fsqrt.x\tfp%d" % d)
        elif k == 5:
            self.emit("fabs.x\tfp%d" % d)
        elif k == 6:
            self.emit("fneg.x\tfp%d" % d)
        elif k == 7:
            self.emit("fmove.x\tfp%d,fp%d" % (s, d))
        elif k == 8:
            self.emit("fmove.x\t($%X).l,fp%d" % (self.pool_addr(p), d))
        elif k == 9:
            self.emit("fmove.s\t($%X).l,fp%d"
                      % (self.sing_addr(self.r.randrange(NSING)), d))
        elif k == 10:
            self.emit("fmove.d\t($%X).l,fp%d"
                      % (self.doub_addr(self.r.randrange(NDOUB)), d))
        elif k == 11:
            # integer sources exercise the conversion path
            self.emit("fmove.l\t#%d,fp%d" % (self.r.randint(-9999, 9999), d))
        elif k == 12:
            # store and reload: exercises the packing paths in both formats
            a = SANDBOX_LO + self.r.randrange(0, 0x300) * 4
            fmt = self.r.choice(["s", "d", "x"])
            self.emit("fmove.%s\tfp%d,($%X).l" % (fmt, d, a))
            self.emit("fmove.%s\t($%X).l,fp%d" % (fmt, a, s))
        else:
            # rounding mode and precision changes drive the rounder
            # Default: extended precision with every rounding mode.  Reduced
            # precision is only emitted in the modes that avoid qemu's FMOVE
            # bug, because qemu does not apply the FPCR rounding precision to
            # FMOVE into a register (WinUAE's fp_move does, and so does
            # AP040 -- covered by t_fpu.s instead of here).
            prec = (self.r.randrange(1, 3) if MODE == "unfl" else
                    self.r.randrange(3) if MODE in ("all", "arith") else 0)
            rnd = self.r.randrange(4)
            self.emit("fmove.l\t#$%02X,fpcr" % ((prec << 6) | (rnd << 4)))

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

        self.build_pool()
        self.emit("fmove.l\t#0,fpcr")
        for i in range(8):
            self.emit("fmove.x\t($%X).l,fp%d" % (self.pool_addr(i), i))
        for _ in range(self.count):
            self.gen_one()

        # deterministic final state: extended precision, round to nearest
        self.emit("fmove.l\t#0,fpcr")
        self.emit("fmovem.x\tfp0-fp7,($%X).l" % FPDUMP)
        self.emit("fmove.l\tfpcr,($%X).l" % FPCR_OUT)
        self.emit("fmove.l\tfpsr,d0")
        self.emit("and.l\t#$0F000000,d0")     # condition codes only
        self.emit("move.l\td0,($%X).l" % FPSR_OUT)

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
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    sys.stdout.write(FpGen(seed, count).generate())
