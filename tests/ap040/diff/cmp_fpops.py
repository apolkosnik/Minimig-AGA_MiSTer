#!/usr/bin/env python3
"""Compare an AP040 fpops dump against WinUAE softfloat reference results."""
import struct
import sys

OPNAME = ["fadd", "fsub", "fmul", "fdiv", "fsqrt", "fabs", "fneg", "fcmp"]
RESULT = 0x3000
DUMP_BASE = 0x3000          # tb dump window starts here

# FPSR bits that both sides model identically for these operations.
FPSR_MASK = 0x0000FF00


def load_dump(path):
    words = [int(w, 16) for w in open(path).read().split()]
    return words


def main():
    ap_path, ref_path, ops_path = sys.argv[1], sys.argv[2], sys.argv[3]
    words = load_dump(ap_path)
    ops = open(ops_path, "rb").read()
    n = struct.unpack("<I", ops[:4])[0]
    slots = []
    off = 4
    for _ in range(n):
        op, prec, rmode, _pad = struct.unpack("<BBBB", ops[off:off + 4])
        a = struct.unpack("<HII", ops[off + 4:off + 14])
        b = struct.unpack("<HII", ops[off + 14:off + 24])
        slots.append((op, prec, rmode, a, b))
        off += 24

    ref = {}
    for line in open(ref_path):
        f = line.split()
        ref[int(f[0])] = (int(f[1], 16), int(f[2], 16), int(f[3], 16), int(f[4], 16))

    bad = 0
    classes = {}
    for i, (op, prec, rmode, a, b) in enumerate(slots):
        base = RESULT + i * 16
        w = (base - DUMP_BASE) // 2
        if w + 8 > len(words):
            print("dump too short at slot %d" % i)
            return 1
        se = words[w]
        hi = (words[w + 2] << 16) | words[w + 3]
        lo = (words[w + 4] << 16) | words[w + 5]
        fpsr = (words[w + 6] << 16) | words[w + 7]
        rse, rhi, rlo, rfpsr = ref[i]
        if se == 0xDEAD and hi == 0xDEADDEAD:
            # AP040 trapped storing this result: an unsupported data type
            # in the register, i.e. a denormal/unnormal the FPSP handles.
            ref_unnormal = (rse & 0x7FFF) != 0 and (rhi >> 31) == 0
            classes["store-trapped-denormal" if ref_unnormal
                    else "store-trapped-OTHER"] = classes.get(
                "store-trapped-denormal" if ref_unnormal
                else "store-trapped-OTHER", 0) + 1
            if not ref_unnormal:
                # Also legitimate: the reference is a true denormal
                # (exponent field 0, nonzero mantissa).  Storing either
                # shape from a register is an unsupported data type.
                if (rse & 0x7FFF) == 0 and (rhi or rlo):
                    classes["store-trapped-OTHER"] -= 1
                    classes["store-trapped-denormal"] = classes.get(
                        "store-trapped-denormal", 0) + 1
                else:
                    bad += 1
            continue
        same = (se == rse and hi == rhi and lo == rlo and
                (fpsr & FPSR_MASK) == (rfpsr & FPSR_MASK))
        if not same:
            # Classify rather than dump: AP040 flushes an underflowing
            # result to zero where softfloat produces the denormal the
            # FPSP would build, and both sides flag UNFL.  That is one
            # known architectural class; anything else is a finding.
            ap_zero = (se & 0x7FFF) == 0 and hi == 0 and lo == 0
            # The reference underflow result is either an unnormal (nonzero
            # exponent, integer bit clear) or a true denormal (exponent 0,
            # nonzero mantissa -- what directed rounding produces).
            ref_tiny = (((rse & 0x7FFF) != 0 and (rse & 0x7FFF) < 0x4000
                         and (rhi >> 31) == 0)
                        or ((rse & 0x7FFF) == 0 and (rhi or rlo)))
            both_unfl = (fpsr & 0x0800) and (rfpsr & 0x0800)
            # Flushing a deeply underflowing result to zero is only
            # defensible when the active rounding mode actually points
            # TOWARD zero for that sign.  Under directed rounding away
            # from zero the architecture requires the smallest
            # representable value, not zero: rounding toward -inf must
            # not turn a negative tiny into -0, and toward +inf must not
            # turn a positive tiny into +0.  Waiving those hid a real
            # numerical mismatch (and a wrong Z condition code) behind
            # the same label as the legitimate cases.
            #   rmode 0 = RN, 1 = RZ, 2 = RM (-inf), 3 = RP (+inf)
            ap_sign = (se >> 15) & 1
            away_from_zero = (rmode == 2 and ap_sign) or \
                             (rmode == 3 and not ap_sign)
            if ap_zero and ref_tiny and both_unfl and not away_from_zero:
                classes["underflow-flush"] = classes.get("underflow-flush", 0) + 1
                continue
            if ap_zero and ref_tiny and away_from_zero:
                classes["underflow-WRONG-DIRECTION"] = classes.get(
                    "underflow-WRONG-DIRECTION", 0) + 1
                bad += 1
                if bad <= 12:
                    print("slot %3d %-6s prec=%d rmode=%d  DIRECTED ROUNDING AWAY FROM ZERO"
                          % (i, OPNAME[op], prec, rmode))
                    print("   ap  = %04X %08X %08X  fpsr=%08X" % (se, hi, lo, fpsr))
                    print("   ref = %04X %08X %08X  fpsr=%08X" % (rse, rhi, rlo, rfpsr))
                continue
            classes["OTHER"] = classes.get("OTHER", 0) + 1
            bad += 1
            if bad <= 12:
                print("slot %3d %-6s prec=%d rmode=%d" % (i, OPNAME[op], prec, rmode))
                print("   a   = %04X %08X %08X" % a)
                print("   b   = %04X %08X %08X" % b)
                print("   ap  = %04X %08X %08X  fpsr=%08X" % (se, hi, lo, fpsr))
                print("   ref = %04X %08X %08X  fpsr=%08X" % (rse, rhi, rlo, rfpsr))
    if classes:
        print("classes: " + ", ".join("%s=%d" % kv for kv in sorted(classes.items())))
    if bad:
        print("%d/%d slots differ beyond the known class" % (bad, len(slots)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
