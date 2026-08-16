#!/usr/bin/env python3
# Replay a cputest .dat stream with the RUNTIME's memory semantics
# (cputest/main.c: setup CT_MEMWRITEs are recorded and REVERTED by
# restoreahist() at the end of every test; per-round test-instruction
# writes are restored to their stream old-values by the validator), then
# compute what a correct CPU must deliver for a chosen memory-indirect
# FABS.X round -- as opposed to the expected value the GENERATOR baked in
# with its no-revert memory model (cputest.cpp resets its access history
# per test without undoing it).
#
# Usage: replay_cputest_dat.py <dir> <testcnt>

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_cputest_dat as D


class Mem:
    def __init__(self):
        self.m = {}

    def write(self, addr, val, size):
        n = 1 << size
        for i in range(n):
            self.m[(addr + i) & 0xFFFFFFFF] = (val >> (8 * (n - 1 - i))) & 0xFF

    def seed(self, addr, val, size):
        n = 1 << size
        for i in range(n):
            a = (addr + i) & 0xFFFFFFFF
            if a not in self.m:
                self.m[a] = (val >> (8 * (n - 1 - i))) & 0xFF

    def read(self, addr, n):
        out = []
        for i in range(n):
            a = (addr + i) & 0xFFFFFFFF
            out.append(self.m.get(a, None))
        return out


def main():
    directory = sys.argv[1]
    target = int(sys.argv[2])

    mem = Mem()
    testcnt = 0
    filecnt = 0
    cur = D.Regs()

    while True:
        fn = None
        for cand in ("%04d.dat" % filecnt, "%04d.dat.gz" % filecnt):
            p = os.path.join(directory, cand)
            if os.path.exists(p):
                fn = p
                break
        if fn is None:
            break
        data = D.load(fn)
        s = D.Stream(data)
        if s.u32() != D.DATA_VERSION:
            print("bad version")
            return
        s.u32(); s.u32(); s.u32()
        end_at = len(data) - 2
        cur.pc = D.OPCODE_MEMORY_ADDR

        while s.p < end_at and s.peek() != D.CT_END_FINISH:
            # ---- setup
            setuplog = []
            hist = []
            p0 = s.p
            while s.peek() not in (D.CT_END_INIT, D.CT_END_FINISH):
                before = s.p
                v = s.peek()
                mode = v & D.CT_DATA_MASK
                if mode == D.CT_MEMWRITE:
                    addr, old, new, size = D.restore_memory(s)
                    mem.seed(addr, old, size)   # backfill unknown initial bytes
                    mem.write(addr, new, size)
                    hist.append((addr, old, size))
                elif mode == D.CT_MEMWRITES and (v & D.CT_SIZE_MASK) == D.CT_PC_BYTES:
                    s.u8()
                    offset, dat = D.restore_bytes(s)
                    for i, b in enumerate(dat):
                        mem.m[D.OPCODE_MEMORY_ADDR + offset + i] = b
                else:
                    D.parse_setup_item(s, cur, setuplog)
            if s.peek() == D.CT_END_FINISH:
                break
            s.u8()

            import copy
            last = copy.deepcopy(cur)

            # ---- rounds
            while True:
                ccrmode = s.u8()
                maxccr = ccrmode & 0x3F
                for ccrcnt in range(maxccr):
                    roundlog = []
                    while s.peek() == D.CT_OVERRIDE_REG:
                        D.parse_override(s, roundlog)
                    if s.peek() == D.CT_END_SKIP:
                        s.u8()
                        continue
                    if testcnt == target:
                        ptr = mem.read(0, 4)
                        if None in ptr:
                            print("mem[0] unknown!")
                            return
                        pv = int.from_bytes(bytes(ptr), "big")
                        win = mem.read(pv, 12)
                        tail = mem.read(pv + 12, 2)
                        print("round testcnt=%d (ccr=%d):" % (testcnt, ccrcnt))
                        print("  runtime mem[0]      = %08x" % pv)
                        print("  operand window @%08x = %s" % (
                            pv, " ".join("%02x" % b if b is not None else "??"
                                         for b in win + tail)))
                        b0 = win[0] & 0x7F   # FABS clears the sign
                        se = (b0 << 8) | win[1]
                        mant = "".join("%02x" % b if b is not None else "??"
                                       for b in win[4:12])
                        print("  correct FABS.X result under runtime memory: "
                              "%04x-%s" % (se, mant))
                        print("  ('??' bytes = untouched lmem image; the")
                        print("   failure photo shows them as df 00)")
                        print("  hardware 'got' was:                         "
                              "401c-d82c00000000df00")
                    # consume expected records; apply expected memwrites as
                    # validator does (memory restored to stream old value)
                    p1 = s.p
                    D.parse_result_records(s, last, roundlog)
                    for line in roundlog:
                        if "exp MEMWRITE" in line:
                            parts = line.split()
                            sz = {"b": 0, "w": 1, "l": 2}[parts[1].split(".")[1]]
                            addr = int(parts[2].strip("[]"), 16)
                            old = int(parts[3].split("=")[1], 16)
                            mem.seed(addr, old, sz)
                            mem.write(addr, old, sz)
                    testcnt += 1
                b = s.u8()
                if b == D.CT_END:
                    break

            # ---- restoreahist: revert setup writes in reverse order
            for addr, old, size in reversed(hist):
                mem.write(addr, old, size)

            if testcnt > target:
                return
        filecnt += 1


if __name__ == "__main__":
    main()
