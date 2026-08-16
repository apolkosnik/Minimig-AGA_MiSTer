#!/usr/bin/env python3
# Decode WinUAE cputest .dat test streams (DATA_VERSION 24) far enough to
# reconstruct the exact setup, memory writes, rounds and expected results
# of chosen tests.  Grammar transcribed from WinUAE cputest/main.c
# (restore_data / restore_value / restore_rel / restore_fpvalue /
# get_memory_addr / restore_memory / restore_bytes / process_test /
# validate_test / validate_exception).
#
# Usage: decode_cputest_dat.py <dir-with-000N.dat[.gz]> <testcnt> [context]
#   Prints every round whose global testcnt is within +-context (default 3)
#   of the requested number, plus the owning setup blocks in full.

import gzip
import sys
import os

CT_DREG = 0
CT_AREG = 8
CT_SSP = 16
CT_MSP = 17
CT_SR = 18
CT_PC = 19
CT_FPIAR = 20
CT_FPSR = 21
CT_FPCR = 22
CT_EDATA = 23
CT_CYCLES = 25
CT_ENDPC = 26
CT_BRANCHTARGET = 27
CT_SRCADDR = 28
CT_DSTADDR = 29
CT_MEMWRITE = 30
CT_MEMWRITES = 31
CT_DATA_MASK = 31
CT_EXCEPTION_MASK = 63

CT_SIZE_BYTE = 0 << 5
CT_SIZE_WORD = 1 << 5
CT_SIZE_LONG = 2 << 5
CT_SIZE_FPU = 3 << 5
CT_SIZE_MASK = 3 << 5

CT_RELATIVE_START_WORD = 0 << 5
CT_ABSOLUTE_WORD = 1 << 5
CT_ABSOLUTE_LONG = 2 << 5
CT_PC_BYTES = 3 << 5
CT_RELATIVE_START_BYTE = 3 << 5

CT_END = 0x80
CT_END_FINISH = 0xFF
CT_END_INIT = 0x80 | 0x40
CT_END_SKIP = 0x80 | 0x40 | 0x01
CT_OVERRIDE_REG = 0x80 | 0x40 | 0x10
CT_BRANCHED = 0x40

DATA_VERSION = 20   # this data set predates the v21 bump (Jul 2020)

# board facts (from the cputest banner of this data set)
OPCODE_MEMORY_ADDR = 0x42050000
TEST_MEMORY_ADDR = 0x42000000
TEST_MEMORY_SIZE = 0x000A0000
LOW_MEMORY_SIZE = 0x8000


class Stream:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def peek(self):
        return self.d[self.p]

    def u16(self):
        return (self.u8() << 8) | self.u8()

    def u32(self):
        return (self.u16() << 16) | self.u16()


def restore_value(s, prev):
    v = s.u8()
    sz = v & CT_SIZE_MASK
    if sz == CT_SIZE_BYTE:
        return (prev & 0xFFFFFF00) | s.u8(), 0
    if sz == CT_SIZE_WORD:
        return (prev & 0xFFFF0000) | s.u16(), 1
    if sz == CT_SIZE_LONG:
        return s.u32(), 2
    raise ValueError("CT_SIZE_FPU in restore_value at %d" % (s.p - 1))


def restore_rel(s, prev):
    v = s.u8()
    sz = v & CT_SIZE_MASK
    if sz == CT_RELATIVE_START_BYTE:
        b = s.u8()
        if b >= 128:
            b -= 256
        return (prev + b) & 0xFFFFFFFF
    if sz == CT_RELATIVE_START_WORD:
        w = s.u16()
        if w >= 32768:
            w -= 65536
        return (prev + w) & 0xFFFFFFFF
    if sz == CT_ABSOLUTE_WORD:
        w = s.u16()
        if w >= 32768:
            w -= 65536
        return w & 0xFFFFFFFF
    if sz == CT_ABSOLUTE_LONG:
        return s.u32()
    raise ValueError("bad rel")


def restore_fpvalue(s, prev):
    v = s.u8()
    if (v & CT_SIZE_MASK) != CT_SIZE_FPU:
        raise ValueError("expected CT_SIZE_FPU, got %02x at %d" % (v, s.p - 1))
    size = s.u8()
    exp, m0, m1 = prev
    if size == 0x00:
        return (0, 0, 0)
    if size == 0xFF:
        return (s.u16(), s.u32(), s.u32())
    f = bytearray(10)
    f[0] = exp >> 8
    f[1] = exp & 0xFF
    f[2:6] = m0.to_bytes(4, "big")
    f[6:10] = m1.to_bytes(4, "big")
    size1 = (size >> 4) & 15
    for i in range(size1):
        f[i] = s.u8()
    size2 = size & 15
    for i in range(size2):
        f[9 - i] = s.u8()
    return (int.from_bytes(f[0:2], "big"),
            int.from_bytes(f[2:6], "big"),
            int.from_bytes(f[6:10], "big"))


def get_memory_addr(s):
    v = s.u8()
    sz = v & CT_SIZE_MASK
    if sz == CT_ABSOLUTE_WORD:
        w = s.u16()
        if w >= 32768:
            w -= 65536
        if w < 0:
            return (0x100000000 + w) & 0xFFFFFFFF   # high memory (disabled here)
        return w                                    # low memory offset
    if sz == CT_ABSOLUTE_LONG:
        return s.u32()
    if sz == CT_RELATIVE_START_WORD:
        w = s.u16()
        if w >= 32768:
            w -= 65536
        return (OPCODE_MEMORY_ADDR + w) & 0xFFFFFFFF
    raise ValueError("get_memory_addr size %02x at %d" % (v, s.p - 1))


def restore_memory(s):
    addr = get_memory_addr(s)
    old, size = restore_value(s, 0)
    new, size = restore_value(s, 0)
    return addr, old, new, size


def restore_bytes(s):
    # v20 encoding: offset in top 3 bits, length in low 5; 31 escapes to a
    # full byte (0 -> 256)
    v = s.u8()
    offset = v >> 5
    length = v & 31
    if length == 31:
        length = s.u8()
        if length == 0:
            length = 256
    data = bytes(s.d[s.p:s.p + length])
    s.p += length
    return offset, data


REGNAMES = ["D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
            "A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7"]


class Regs:
    def __init__(self):
        self.regs = [0] * 16
        self.fpu = [(0, 0, 0)] * 8
        self.sr = 0
        self.pc = 0
        self.endpc = 0
        self.fpiar = 0
        self.fpcr = 0
        self.fpsr = 0
        self.cycles = 0
        self.srcaddr = 0xFFFFFFFF
        self.dstaddr = 0xFFFFFFFF
        self.branchtarget = 0xFFFFFFFF


def parse_setup_item(s, r, log):
    v = s.peek()
    mode = v & CT_DATA_MASK
    if mode < CT_AREG + 8:
        if (v & CT_SIZE_MASK) == CT_SIZE_FPU:
            r.fpu[mode] = restore_fpvalue(s, r.fpu[mode])
            log.append("  FP%d := %04x-%08x%08x" % (mode, *r.fpu[mode]))
        else:
            r.regs[mode], _ = restore_value(s, r.regs[mode])
            log.append("  %s := %08x" % (REGNAMES[mode], r.regs[mode]))
    elif mode == CT_SR:
        r.sr, _ = restore_value(s, r.sr)
        log.append("  SR := %08x" % r.sr)
    elif mode == CT_PC:
        r.pc, _ = restore_value(s, r.pc)
        log.append("  PC := %08x" % r.pc)
    elif mode == CT_CYCLES:
        r.cycles, _ = restore_value(s, r.cycles)
    elif mode == CT_FPIAR:
        r.fpiar, _ = restore_value(s, r.fpiar)
        log.append("  FPIAR := %08x" % r.fpiar)
    elif mode == CT_FPCR:
        r.fpcr, _ = restore_value(s, r.fpcr)
        log.append("  FPCR := %08x" % r.fpcr)
    elif mode == CT_FPSR:
        r.fpsr, _ = restore_value(s, r.fpsr)
        log.append("  FPSR := %08x" % r.fpsr)
    elif mode == CT_ENDPC:
        r.endpc, _ = restore_value(s, r.endpc)
        log.append("  ENDPC := %08x" % r.endpc)
    elif mode == CT_SRCADDR:
        r.srcaddr, _ = restore_value(s, r.srcaddr)
        log.append("  SRCADDR := %08x" % r.srcaddr)
    elif mode == CT_DSTADDR:
        r.dstaddr, _ = restore_value(s, r.dstaddr)
        log.append("  DSTADDR := %08x" % r.dstaddr)
    elif mode == CT_BRANCHTARGET:
        r.branchtarget, _ = restore_value(s, r.branchtarget)
        btmode = s.u8()
        log.append("  BRANCHTARGET := %08x mode %d" % (r.branchtarget, btmode))
    elif mode == CT_MEMWRITE:
        addr, old, new, size = restore_memory(s)
        log.append("  MEMWRITE.%s [%08x] old=%0*x NEW=%0*x"
                   % ("bwl"[size], addr, 2 << size, old, 2 << size, new))
    elif mode == CT_MEMWRITES:
        if (v & CT_SIZE_MASK) == CT_PC_BYTES:
            s.u8()
            offset, data = restore_bytes(s)
            log.append("  OPCODE bytes @pc+%d: %s" % (offset, data.hex()))
        else:
            raise ValueError("MEMWRITES variant %02x" % v)
    elif mode == CT_EDATA:
        s.u8()
        t = s.u8()
        if t == 1:
            d = s.u8()
            log.append("  EDATA irq_cycles=%d" % d)
        else:
            raise ValueError("EDATA type %02x" % t)
    else:
        raise ValueError("setup mode %02x at offset %d" % (v, s.p))


def restore_rel_ordered(s, default):
    if s.peek() == CT_END_INIT:
        s.u8()
        return default
    return restore_rel(s, default)


def parse_exception(s, exc, log):
    # v20 grammar, cpu_lvl >= 2 (68020+) branch of validate_exception
    excdatalen = s.u8()
    if excdatalen == 0 or excdatalen == 0xFF:
        return
    extra = s.u8()
    if extra & 0x40:
        group = s.u8()
        extra &= ~0x40
        log.append("      exc group2with1=%d" % group)
    if (extra & 0x3F) == 9:
        if extra & 0x80:
            tsr = s.u16()
            tpc = restore_rel_ordered(s, OPCODE_MEMORY_ADDR)
            log.append("      trace: SR=%04x PC=%08x" % (tsr, tpc))
        else:
            log.append("      trace stacked with group2")
    elif extra != 0:
        raise ValueError("exception extra %02x at %d" % (extra, s.p))
    if exc == 1:
        return
    t = s.u16()
    fmt = t >> 12
    if fmt == 0:
        log.append("      frame $0 vec %d (fv=%04x)" % (exc, t))
    elif fmt in (2, 3):
        ea = restore_rel_ordered(s, OPCODE_MEMORY_ADDR)
        fpeaset = None
        if fmt == 3 or exc in (11, 55):
            fpeaset = s.u8() & 1
        log.append("      frame $%x vec %d EA=%08x fpeaset=%s (fv=%04x)"
                   % (fmt, exc, ea, fpeaset, t))
    elif fmt == 4:
        ea1 = restore_rel_ordered(s, OPCODE_MEMORY_ADDR)
        ea2 = restore_rel_ordered(s, OPCODE_MEMORY_ADDR)
        fpeaset = s.u8() & 1
        log.append("      frame $4 vec %d EA=%08x/%08x fpeaset=%d (fv=%04x)"
                   % (exc, ea1, ea2, fpeaset, t))
    else:
        raise ValueError("frame format %x (vec %d) at offset %d" % (fmt, exc, s.p))


def parse_result_records(s, l, log):
    while True:
        v = s.peek()
        if v & CT_END:
            s.u8()
            exc = v & 0x3F
            branched = 1 if (v & CT_BRANCHED) else 0
            log.append("    END exc=%d branched=%d" % (exc, branched))
            if exc >= 2:
                parse_exception(s, exc, log)
            return
        mode = v & CT_DATA_MASK
        if mode < CT_AREG + 8 and (v & CT_SIZE_MASK) != CT_SIZE_FPU:
            l.regs[mode], _ = restore_value(s, l.regs[mode])
            log.append("    exp %s = %08x" % (REGNAMES[mode], l.regs[mode]))
        elif mode < CT_AREG and (v & CT_SIZE_MASK) == CT_SIZE_FPU:
            l.fpu[mode] = restore_fpvalue(s, l.fpu[mode])
            log.append("    exp FP%d = %04x-%08x%08x" % (mode, *l.fpu[mode]))
        elif mode == CT_SR:
            l.sr, _ = restore_value(s, l.sr)
            log.append("    exp SR = %08x (ignoremask %04x)"
                       % (l.sr & 0xFFFF, (~(l.sr >> 16)) & 0xFFFF))
        elif mode == CT_PC:
            l.pc = restore_rel(s, l.pc)
            log.append("    exp PC = %08x" % l.pc)
        elif mode == CT_CYCLES:
            l.cycles, _ = restore_value(s, l.cycles)
        elif mode == CT_FPIAR:
            l.fpiar, _ = restore_value(s, l.fpiar)
            log.append("    exp FPIAR = %08x" % l.fpiar)
        elif mode == CT_FPCR:
            l.fpcr, _ = restore_value(s, l.fpcr)
            log.append("    exp FPCR = %08x" % l.fpcr)
        elif mode == CT_FPSR:
            l.fpsr, _ = restore_value(s, l.fpsr)
            log.append("    exp FPSR = %08x" % l.fpsr)
        elif mode == CT_MEMWRITE:
            addr, old, new, size = restore_memory(s)
            log.append("    exp MEMWRITE.%s [%08x] old=%0*x new=%0*x"
                       % ("bwl"[size], addr, 2 << size, old, 2 << size, new))
        elif mode == CT_MEMWRITES:
            addr, old, new, size = restore_memory(s)
            log.append("    exp MEMWRITES [%08x]" % addr)
        else:
            raise ValueError("result mode %02x at %d" % (v, s.p))


def parse_override(s, log):
    s.u8()
    v = s.u8()
    r = v & CT_DATA_MASK
    size = v & CT_SIZE_MASK
    if r == CT_SR:
        if size == CT_SIZE_BYTE:
            val = s.u8()
        else:
            val = s.u16()
        log.append("    OVERRIDE SR=%04x" % val)
    elif r in (CT_FPSR, CT_FPCR, CT_FPIAR):
        val = s.u32()
        log.append("    OVERRIDE reg%d=%08x" % (r, val))
    elif r < 16:
        if size == CT_SIZE_FPU:
            e = s.u32()
            m0 = s.u32()
            m1 = s.u32()
            log.append("    OVERRIDE FP%d" % r)
        else:
            val = s.u32()
            log.append("    OVERRIDE %s=%08x" % (REGNAMES[r], val))
    else:
        raise ValueError("override reg %02x" % v)


def load(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rb").read()
    return open(path, "rb").read()


def main():
    directory = sys.argv[1]
    target = int(sys.argv[2])
    context = int(sys.argv[3]) if len(sys.argv) > 3 else 3

    testcnt = 0
    filecnt = 0
    cur = Regs()
    last = None

    while True:
        fn = None
        for cand in ("%04d.dat" % filecnt, "%04d.dat.gz" % filecnt):
            p = os.path.join(directory, cand)
            if os.path.exists(p):
                fn = p
                break
        if fn is None:
            break
        data = load(fn)
        s = Stream(data)
        ver = s.u32()
        if ver != DATA_VERSION:
            print("bad version %d in %s" % (ver, fn))
            return
        s.u32()  # starttimeid
        s.u32()  # flags
        s.u32()  # pad to 16
        end_at = len(data) - 2
        cur.pc = OPCODE_MEMORY_ADDR
        cur.endpc = OPCODE_MEMORY_ADDR

        setup_index = 0
        while s.p < end_at:
            if s.peek() == CT_END_FINISH:
                break
            # ---- setup block
            setuplog = []
            while s.peek() not in (CT_END_INIT, CT_END_FINISH):
                parse_setup_item(s, cur, setuplog)
            if s.peek() == CT_END_FINISH:
                break
            s.u8()
            last = None
            setup_index += 1
            first_round_cnt = testcnt

            show_any = False
            blocklog = ["%s setup #%d (first round testcnt=%d):"
                        % (os.path.basename(fn), setup_index, first_round_cnt)]
            blocklog += setuplog

            # ---- ccr blocks
            while True:
                ccrmode = s.u8()
                maxccr = ccrmode & 0x3F
                ccflag = ccrmode & 0x40
                blocklog.append("  ccr block: maxccr=%d %s"
                                % (maxccr,
                                   "FPSR-cc sweep" if ccflag else "FPCR prec/round sweep"))
                if last is None:
                    import copy
                    last = copy.deepcopy(cur)
                for ccrcnt in range(maxccr):
                    ccr = ccrcnt & (maxccr - 1)
                    roundlog = []
                    while s.peek() == CT_OVERRIDE_REG:
                        parse_override(s, roundlog)
                    if s.peek() == CT_END_SKIP:
                        s.u8()
                        roundlog.append("    (round skipped)")
                        skipped = True
                    else:
                        parse_result_records(s, last, roundlog)
                        skipped = False
                    if not skipped:
                        this_cnt = testcnt
                        testcnt += 1
                    else:
                        this_cnt = None
                    if this_cnt is not None and abs(this_cnt - target) <= context:
                        show_any = True
                        fpcr = ((ccr & 15) << 4) if (maxccr >= 16 and not ccflag) else None
                        blocklog.append("  round ccr=%d testcnt=%d fpcr=%s"
                                        % (ccr, this_cnt,
                                           ("%02x" % fpcr) if fpcr is not None else "-"))
                        blocklog += roundlog
                b = s.u8()
                if b == CT_END:
                    break
                blocklog.append("  extraccr=%02x" % b)
                # note: extraccr byte already consumed; next ccrmode follows
                s.p -= 0
            if show_any:
                print("\n".join(blocklog))
                print()
            if target + context < first_round_cnt:
                return
        filecnt += 1

    print("end, total rounds:", testcnt)


if __name__ == "__main__":
    main()
