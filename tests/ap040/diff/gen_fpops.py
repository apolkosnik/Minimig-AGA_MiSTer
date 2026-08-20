#!/usr/bin/env python3
"""Generate a fixed list of FP operations and an assembly program that runs
them, for comparison against WinUAE's own softfloat (fp_oracle.cpp).

Unlike gen_fpdiff.py, which compares a random instruction STREAM against
qemu, this emits one independent operation per slot: both sides see the
same operands, the same rounding mode and the same precision, so a
mismatch names a single operation instead of a stream position.  qemu is
not involved -- the reference is the code WinUAE's 68040 actually runs.

Operand classes are deliberately wide (normals across the exponent range,
zeros, infinities, NaNs) but exclude denormals, which are an unsupported
data type on a 68040 and trap to the FPSP on both sides by design.
"""
import random
import struct
import sys

OPS = [("fadd", 0), ("fsub", 1), ("fmul", 2), ("fdiv", 3),
       ("fsqrt", 4), ("fabs", 5), ("fneg", 6)]
MONADIC = {"fsqrt", "fabs", "fneg"}

BASE     = 0x4000      # operand pool, outside the compared window
RESULT   = 0x3000      # 16 bytes per slot, inside the tb's $3000-$3FFF dump
NSLOT    = 96          # 96 * 16 = $600 bytes, well inside the window


def rnd_ext(r):
    """A random extended value from a class mix, as (sign_exp, hi, lo)."""
    k = r.randrange(16)
    if k == 0:                                  # zero
        return (r.getrandbits(1) << 15, 0, 0)
    if k == 1:                                  # infinity
        return ((r.getrandbits(1) << 15) | 0x7FFF, 0, 0)
    if k == 2:                                  # NaN
        return ((r.getrandbits(1) << 15) | 0x7FFF,
                0xC0000000 | r.getrandbits(30), r.getrandbits(32))
    if k == 3:                                  # small integer value
        e = 16383 + r.randrange(0, 8)
    elif k == 4:                                # near the exponent limits
        e = r.choice([1, 2, 0x7FFD, 0x7FFE])
    else:                                       # general normal
        e = 16383 + r.randrange(-4000, 4000)
    s = r.getrandbits(1)
    m = (1 << 63) | r.getrandbits(63)
    return ((s << 15) | e, m >> 32, m & 0xFFFFFFFF)


def main():
    seed = int(sys.argv[1])
    n = int(sys.argv[2]) if len(sys.argv) > 2 else NSLOT
    r = random.Random(seed)

    slots = []
    for i in range(n):
        name, code = OPS[r.randrange(len(OPS))]
        a = rnd_ext(r)
        b = rnd_ext(r)
        if name == "fsqrt":
            a = (a[0] & 0x7FFF, a[1], a[2])     # keep sqrt operands positive
        prec = r.randrange(3)                   # 0 ext, 1 single, 2 double
        rmode = r.randrange(4)
        slots.append((name, code, a, b, prec, rmode))

    # binary side-file for the oracle: op, prec, rmode, a[3], b[3]
    with open(sys.argv[3], "wb") as f:
        f.write(struct.pack("<I", len(slots)))
        for name, code, a, b, prec, rmode in slots:
            f.write(struct.pack("<BBBB", code, prec, rmode, 0))
            f.write(struct.pack("<HII", a[0], a[1], a[2]))
            f.write(struct.pack("<HII", b[0], b[1], b[2]))

    out = []
    out.append("\torg\t0")
    out.append("\tdc.l\t$2F00")
    out.append("\tdc.l\tstart")
    out.append("\trept\t53")
    out.append("\tdc.l\tunexp")          # vectors 2-54
    out.append("\tendr")
    out.append("\tdc.l\th_unsupp")        # 55 unsupported data type
    out.append("\trept\t200")
    out.append("\tdc.l\tunexp")
    out.append("\tendr")
    out.append("")
    out.append("\torg\t$400")
    out.append("start:")
    out.append("\tmove.w\t#$2700,sr")
    out.append("\tmovea.l\t#$2F00,sp")
    # Pre-fill the result window with a sentinel.  Storing a denormal or
    # unnormal from a register is an unsupported data type on a 68040 and
    # traps to the FPSP, so those slots keep the sentinel and the
    # comparator reports them as trapped rather than as wrong values.
    out.append("\tlea\t($%X).l,a0" % RESULT)
    out.append("\tmove.w\t#%d,d1" % (n * 4 - 1))
    out.append("prefill:")
    out.append("\tmove.l\t#$DEADDEAD,(a0)+")
    out.append("\tdbra\td1,prefill")

    for i, (name, code, a, b, prec, rmode) in enumerate(slots):
        pa = BASE + i * 24
        pb = pa + 12
        res = RESULT + i * 16
        # FPCR: precision in bits 7:6, rounding mode in bits 5:4
        if name in MONADIC:
            out.append("\tfmove.l\t#$%02X,fpcr" % ((prec << 6) | (rmode << 4)))
            # clear FPSR last: loading FP0 is itself an FP instruction and
            # would leave its own accrued bits behind
            out.append("\tfmove.l\t#0,fpsr")
            out.append("\t%s.x\t($%X).l,fp0" % (name, pa))
        else:
            # Load the destination at EXTENDED precision first.  FMOVE
            # itself rounds to the FPCR precision -- and overflows a large
            # exponent to infinity, exactly as floatx80_move does -- so
            # loading under the test precision would silently change the
            # operand instead of testing the operation.
            out.append("\tfmove.l\t#0,fpcr")
            out.append("\tfmove.x\t($%X).l,fp0" % pb)
            out.append("\tfmove.l\t#$%02X,fpcr" % ((prec << 6) | (rmode << 4)))
            out.append("\tfmove.l\t#0,fpsr")
            out.append("\t%s.x\t($%X).l,fp0" % (name, pa))
        # FPSR first: an FMOVE store would clear the exception status byte
        out.append("\tfmove.l\tfpsr,d0")
        out.append("\tmove.l\td0,($%X).l" % (res + 12))
        out.append("\tfmove.l\t#0,fpcr")        # store unrounded extended
        out.append("\tfmove.x\tfp0,($%X).l" % res)

    out.append("\tmove.w\t#$600D,($F102).l")
    out.append("stop1:")
    out.append("\tbra\tstop1")
    out.append("h_unsupp:")
    out.append("\trte")                    # skip the trapping store
    out.append("unexp:")
    out.append("\tmove.w\t#$BAD0,($3FFE).l")
    out.append("\tmove.w\t#$BAD0,($F102).l")
    out.append("stop2:")
    out.append("\tbra\tstop2")
    # Operand pool as DATA at BASE: emitting it as code cost ~60 bytes per
    # slot and let the program grow into the compared window.
    out.append("")
    out.append("\torg\t$%X" % BASE)
    for name, code, a, b, prec, rmode in slots:
        out.append("\tdc.l\t$%08X,$%08X,$%08X" % (a[0] << 16, a[1], a[2]))
        out.append("\tdc.l\t$%08X,$%08X,$%08X" % (b[0] << 16, b[1], b[2]))
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
