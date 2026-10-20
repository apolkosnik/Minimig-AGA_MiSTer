#!/usr/bin/env python3
#
# 68000 / 68010 instruction timing check.
#
#   timing68k.py <000|010> <program.hex> <itime log> [-v]
#
# The itime log is written by tb_fx68k (+itime=): one line per instruction
# start with the CPU clock, PC, opcode, exception flag, SR and D0-D7. The time
# of an instruction is the clock difference to the next line. It is compared
# with the M68000 User's Manual: Section 8 (68000) or Section 9 (68010), with
# zero wait states. The DIVU/DIVS and MULS times are data dependent, they
# follow the analysis by Jorge Cwik (68000) and the WinUAE 68010 tables.
#
# Instructions are grouped by form; forms whose time does not match are listed.

import sys
from collections import defaultdict

# effective address modes
DN, AN, AI, AIP, AID, AD16, AD8, AW, AL, PC16, PC8, IMM = range(12)
EA_NAMES = ['Dn', 'An', '(An)', '(An)+', '-(An)', 'd16(An)', 'd8(An,Xn)', 'xxx.W', 'xxx.L', 'd16(PC)', 'd8(PC,Xn)', '#']
EA_BW = [0, 0, 4, 4, 6, 8, 10, 8, 12, 8, 10, 4]
EA_L = [0, 0, 8, 8, 10, 12, 14, 12, 16, 12, 14, 8]
EA_EXT = [0, 0, 0, 0, 0, 1, 1, 1, 2, 1, 1, None]       # extension words (immediate: by size)
# address calculation without the operand read (68000 TAS)
EA_CALC = [0, 0, 0, 0, 2, 4, 6, 4, 8, None, None, None]
# 68010 non fetching EA (Scc, TAS, MOVE from SR/CCR, CLR)
EA_NF_010 = [0, 0, 2, 4, 4, 4, 8, 4, 8, None, None, None]

def ea_mode(mode, reg):
    if mode < 7:
        return mode
    return [AW, AL, PC16, PC8, IMM, None, None, None][reg]

def ea_time(m, size):
    return EA_L[m] if size == 4 else EA_BW[m]

def ea_words(m, size):
    if m == IMM:
        return 2 if size == 4 else 1
    return EA_EXT[m]

# MOVE tables, destination column order: Dn An (An) (An)+ -(An) d16 d8 W L
MOVE_DST = [DN, AN, AI, AIP, AID, AD16, AD8, AW, AL]
def move_table(text):
    t = {}
    rows = [DN, AN, AI, AIP, AID, AD16, AD8, AW, AL, PC16, PC8, IMM]
    for m, line in zip(rows, text.strip().split('\n')):
        v = [int(x) for x in line.split()]
        for d, x in zip(MOVE_DST, v):
            t[(m, d)] = x
    return t

MOVE_BW = move_table("""
4 4 8 8 8 12 14 12 16
4 4 8 8 8 12 14 12 16
8 8 12 12 12 16 18 16 20
8 8 12 12 12 16 18 16 20
10 10 14 14 14 18 20 18 22
12 12 16 16 16 20 22 20 24
14 14 18 18 18 22 24 22 26
12 12 16 16 16 20 22 20 24
16 16 20 20 20 24 26 24 28
12 12 16 16 16 20 22 20 24
14 14 18 18 18 22 24 22 26
8 8 12 12 12 16 18 16 20""")
MOVE_L_000 = move_table("""
4 4 12 12 12 16 18 16 20
4 4 12 12 12 16 18 16 20
12 12 20 20 20 24 26 24 28
12 12 20 20 20 24 26 24 28
14 14 22 22 22 26 28 26 30
16 16 24 24 24 28 30 28 32
18 18 26 26 26 30 32 30 34
16 16 24 24 24 28 30 28 32
20 20 28 28 28 32 34 32 36
16 16 24 24 24 28 30 28 32
18 18 26 26 26 30 32 30 34
12 12 20 20 20 24 26 24 28""")
MOVE_L_010 = move_table("""
4 4 12 12 14 16 18 16 20
4 4 12 12 14 16 18 16 20
12 12 20 20 20 24 26 24 28
12 12 20 20 20 24 26 24 28
14 14 22 22 22 26 28 26 30
16 16 24 24 24 28 30 28 32
18 18 26 26 26 30 32 30 34
16 16 24 24 24 28 30 28 32
20 20 28 28 28 32 34 32 36
16 16 24 24 24 28 30 28 32
18 18 26 26 26 30 32 30 34
12 12 20 20 20 24 26 24 28""")

CLR_010_BW = {DN: 4, AI: 8, AIP: 8, AID: 10, AD16: 12, AD8: 16, AW: 12, AL: 16}
CLR_010_L = {DN: 6, AI: 12, AIP: 12, AID: 14, AD16: 16, AD8: 20, AW: 16, AL: 20}

JMP = {AI: 8, AD16: 10, AD8: 14, AW: 10, AL: 12, PC16: 10, PC8: 14}
JSR = {AI: 16, AD16: 18, AD8: 22, AW: 18, AL: 20, PC16: 18, PC8: 22}
LEA = {AI: 4, AD16: 8, AD8: 12, AW: 8, AL: 12, PC16: 8, PC8: 12}
PEA = {AI: 12, AD16: 16, AD8: 20, AW: 16, AL: 20, PC16: 16, PC8: 20}
MOVEM_MR = {AI: 12, AIP: 12, AD16: 16, AD8: 18, AW: 16, AL: 20, PC16: 16, PC8: 18}
MOVEM_RM = {AI: 8, AID: 8, AD16: 12, AD8: 14, AW: 12, AL: 16}
MOVES_MR = {AI: 18, AIP: 20, AID: 20, AD16: 20, AD8: 24, AW: 20, AL: 24}
MOVES_RM = {AI: 18, AIP: 20, AID: 20, AD16: 20, AD8: 24, AW: 20, AL: 24}

def popcount(x):
    return bin(x).count('1')

def mulu_000(src):
    return 38 + 2 * popcount(src & 0xffff)

def muls_000(src):
    s = (src & 0xffff) << 1
    n = 0
    for i in range(16):
        if (s & 3) in (1, 2):
            n += 1
        s >>= 1
    return 38 + 2 * n

def divu_000(dividend, divisor):
    if (dividend >> 16) >= divisor:
        return 10
    mc = 38
    hd = divisor << 16
    for i in range(15):
        t = dividend
        dividend = (dividend << 1) & 0xffffffff
        if t & 0x80000000:
            dividend = (dividend - hd) & 0xffffffff
        else:
            mc += 2
            if dividend >= hd:
                dividend = (dividend - hd) & 0xffffffff
                mc -= 1
    return mc * 2

def s32(x):
    return x - (1 << 32) if x & 0x80000000 else x

def s16(x):
    x &= 0xffff
    return x - 0x10000 if x & 0x8000 else x

def divs_000(dividend, divisor):
    dividend, divisor = s32(dividend), s16(divisor)
    mc = 6
    if dividend < 0:
        mc += 1
    if (abs(dividend) >> 16) >= abs(divisor):
        return (mc + 2) * 2
    aquot = abs(dividend) // abs(divisor)
    mc += 55
    if divisor >= 0:
        mc += -1 if dividend >= 0 else 1
    for i in range(15):
        if not (aquot & 0x8000):
            mc += 1
        aquot = (aquot << 1) & 0xffff
    return mc * 2

def divu_010(dividend, divisor):
    if (dividend >> 16) >= divisor:
        return 8
    mc = 74
    hd = divisor << 16
    for i in range(15):
        t = dividend
        dividend = (dividend << 1) & 0xffffffff
        if t & 0x80000000:
            dividend = (dividend - hd) & 0xffffffff
        else:
            mc += 2
            if dividend >= hd:
                dividend = (dividend - hd) & 0xffffffff
    return mc + 4

def divs_010(dividend, divisor):
    dividend, divisor = s32(dividend), s16(divisor)
    if (abs(dividend) >> 16) >= abs(divisor):
        return 16
    return 120 + (2 if dividend < 0 else 0)

def cc_true(cc, sr):
    c, v, z, n = sr & 1, (sr >> 1) & 1, (sr >> 2) & 1, (sr >> 3) & 1
    return [1, 0, not c and not z, c or z, not c, c, not z, z, not v, v, not n, n,
            n == v, n != v, n == v and not z, z or n != v][cc]


class Decoded:
    def __init__(self, name, words, key=None):
        self.name = name
        self.words = words          # instruction length in words
        self.key = key or name      # grouping key
        self.time = None            # expected time
        self.note = ''


def decode(cpu, mem, pc, sr, d, nextpc, exc_next):
    """Return Decoded with the expected time (None if not modelled)."""
    op = mem(pc)
    line = op >> 12
    mode, reg = (op >> 3) & 7, op & 7
    ea = ea_mode(mode, reg)
    szf = (op >> 6) & 3
    size = {0: 1, 1: 2, 2: 4}.get(szf)
    is010 = cpu == '010'

    def D(n, w, k=None):
        return Decoded(n, w, k)

    # MOVE
    if line in (1, 2, 3):
        size = {1: 1, 3: 2, 2: 4}[line]
        dm = ea_mode((op >> 6) & 7, (op >> 9) & 7)
        if ea is None or dm is None:
            return None
        w = 1 + ea_words(ea, size) + EA_EXT[dm]
        r = D('MOVE.%s %s,%s' % ('BWL'[[1, 2, 4].index(size)], EA_NAMES[ea], EA_NAMES[dm]), w)
        t = MOVE_BW if size < 4 else (MOVE_L_010 if is010 else MOVE_L_000)
        r.time = t.get((ea, dm))
        return r
    if line == 7:
        r = D('MOVEQ', 1)
        r.time = 4
        return r
    # Bcc / BRA / BSR
    if line == 6:
        cc = (op >> 8) & 15
        disp8 = op & 0xff
        w = 2 if disp8 == 0 else 1
        if cc == 1:
            r = D('BSR', w)
            r.time = 18
            return r
        if cc == 0:
            r = D('BRA', w)
            r.time = 10
            return r
        taken = nextpc != pc + 2 * w
        r = D('Bcc.%s %s' % ('W' if w == 2 else 'B', 'taken' if taken else 'not taken'), w)
        if taken:
            r.time = 10
        elif w == 1:
            r.time = 6 if is010 else 8
        else:
            r.time = 12                         # WinUAE, the 68010 table has 10
        return r
    if line == 5:
        if szf == 3:
            cc = (op >> 8) & 15
            if mode == 1:       # DBcc
                taken = nextpc != pc + 4
                ct = cc_true(cc, sr)
                if ct:
                    k, t = 'DBcc cc true', (10 if is010 else 12)
                elif taken:
                    k, t = 'DBcc loop', 10
                else:
                    k, t = 'DBcc expired', (16 if is010 else 14)
                r = D(k, 2)
                r.time = t
                return r
            # Scc
            if ea is None:
                return None
            ct = cc_true(cc, sr)
            if ea == DN:
                r = D('Scc Dn %s' % ('true' if ct else 'false'), 1)
                r.time = 6 if ct else 4             # WinUAE, the 68010 table has 4 for true
            else:
                r = D('Scc %s' % EA_NAMES[ea], 1 + ea_words(ea, 1))
                r.time = 8 + (EA_NF_010[ea] if is010 else ea_time(ea, 1))
            return r
        # ADDQ / SUBQ
        if ea is None:
            return None
        nm = 'SUBQ' if op & 0x100 else 'ADDQ'
        r = D('%s.%s %s' % (nm, 'BWL'[szf], EA_NAMES[ea]), 1 + ea_words(ea, size))
        if ea == DN:
            r.time = 8 if size == 4 else 4
        elif ea == AN:
            r.time = 8                          # WinUAE, the 68010 table has 4 for SUBQ.W
        else:
            r.time = (12 if size == 4 else 8) + ea_time(ea, size)
        return r
    # arithmetic and logic lines
    if line in (8, 9, 0xb, 0xc, 0xd):
        opm = (op >> 6) & 7
        if ea is None:
            return None
        nm = {8: 'OR', 9: 'SUB', 0xb: 'CMP', 0xc: 'AND', 0xd: 'ADD'}[line]
        if line in (8, 0xc) and opm in (3, 7):
            if line == 8:
                nm = 'DIVS' if opm == 7 else 'DIVU'
            else:
                nm = 'MULS' if opm == 7 else 'MULU'
            r = D('%s %s' % (nm, EA_NAMES[ea]), 1 + ea_words(ea, 2))
            if ea in (DN, IMM):
                src = d[reg] & 0xffff if ea == DN else mem(pc + 2)
                dst = d[(op >> 9) & 7]
                if nm == 'MULU':
                    r.time = (40 if is010 else mulu_000(src)) + ea_time(ea, 2)
                elif nm == 'MULS':
                    r.time = ((42 if src & 0x8000 else 40) if is010 else muls_000(src)) + ea_time(ea, 2)
                elif nm == 'DIVU':
                    if src == 0:
                        return None
                    r.time = (divu_010 if is010 else divu_000)(dst, src) + ea_time(ea, 2)
                    r.key = 'DIVU %s' % EA_NAMES[ea]
                else:
                    if src == 0:
                        return None
                    r.time = (divs_010 if is010 else divs_000)(dst, src) + ea_time(ea, 2)
            return r
        if opm in (3, 7) and line in (9, 0xb, 0xd):           # ADDA SUBA CMPA
            sz = 2 if opm == 3 else 4
            r = D('%sA.%s %s' % (nm, 'WL'[sz == 4], EA_NAMES[ea]), 1 + ea_words(ea, sz))
            if nm == 'CMP':
                r.time = 6 + ea_time(ea, sz)
            elif sz == 2:
                r.time = 8 + ea_time(ea, sz)
            else:
                # WinUAE: same as the 68000, the 68010 table has 6 for register and immediate
                r.time = (6 if ea not in (DN, AN, IMM) else 8) + ea_time(ea, sz)
            return r
        if opm >= 4 and mode in (0, 1) and line != 0xb or (line == 0xb and opm >= 4 and mode == 1):
            # ABCD SBCD ADDX SUBX CMPM
            if line in (8, 0xc):
                if opm != 4:
                    if line == 0xc and opm in (5, 6):
                        r = D('EXG', 1)
                        r.time = 6
                        return r
                    return None
                nm2 = 'SBCD' if line == 8 else 'ABCD'
                r = D('%s %s' % (nm2, 'Dn' if mode == 0 else '-(An)'), 1)
                r.time = 6 if mode == 0 else 18
                return r
            sz = {4: 1, 5: 2, 6: 4}[opm]
            if line == 0xb:
                r = D('CMPM.%s' % 'BWL'[opm - 4], 1)
                r.time = 20 if sz == 4 else 12
                return r
            nm2 = 'SUBX' if line == 9 else 'ADDX'
            r = D('%s.%s %s' % (nm2, 'BWL'[opm - 4], 'Dn' if mode == 0 else '-(An)'), 1)
            if mode == 0:
                r.time = (6 if is010 else 8) if sz == 4 else 4
            else:
                r.time = 30 if sz == 4 else 18
            return r
        if line == 0xb and opm >= 4:                            # EOR Dn,<ea>
            sz = {4: 1, 5: 2, 6: 4}[opm]
            r = D('EOR.%s Dn,%s' % ('BWL'[opm - 4], EA_NAMES[ea]), 1 + ea_words(ea, sz))
            if ea == DN:
                r.time = (6 if is010 else 8) if sz == 4 else 4
            else:
                r.time = (12 if sz == 4 else 8) + ea_time(ea, sz)
            return r
        sz = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2, 6: 4}[opm]
        if opm < 4:                                             # <ea>,Dn
            r = D('%s.%s %s,Dn' % (nm, 'BWL'[opm], EA_NAMES[ea]), 1 + ea_words(ea, sz))
            if sz == 4:
                if nm == 'CMP':
                    r.time = 6 + ea_time(ea, sz)
                elif ea in (DN, AN):
                    r.time = 6 if is010 else 8
                elif ea == IMM:
                    # WinUAE: ADD/SUB #imm 2 clocks faster on the 68010, AND/OR as on the 68000
                    r.time = 14 if (is010 and nm in ('ADD', 'SUB')) else 16
                else:
                    r.time = 6 + ea_time(ea, sz)
            else:
                r.time = 4 + ea_time(ea, sz)
        else:                                                   # Dn,<ea>
            r = D('%s.%s Dn,%s' % (nm, 'BWL'[opm - 4], EA_NAMES[ea]), 1 + ea_words(ea, sz))
            r.time = (12 if sz == 4 else 8) + ea_time(ea, sz)
        return r
    # shifts
    if line == 0xe:
        if szf == 3:
            r = D('shift mem %s' % EA_NAMES[ea], 1 + ea_words(ea, 2))
            r.time = 8 + ea_time(ea, 2)
            return r
        cnt = (op >> 9) & 7
        if op & 0x20:
            n = d[cnt] & 63
        else:
            n = cnt or 8
        r = D('shift.%s %s' % ('BWL'[szf], 'reg' if op & 0x20 else 'imm'), 1)
        r.time = (8 if size == 4 else 6) + 2 * n
        return r
    # line 0: immediate, bit, MOVEP, MOVES
    if line == 0:
        if op & 0x100:
            if mode == 1:                                       # MOVEP
                lng = op & 0x40
                r = D('MOVEP.%s' % ('L' if lng else 'W'), 2)
                r.time = 24 if lng else 16
                return r
            bop = (op >> 6) & 3
            nm = ['BTST', 'BCHG', 'BCLR', 'BSET'][bop]
            r = D('%s Dn,%s' % (nm, EA_NAMES[ea]), 1 + ea_words(ea, 1))
            if ea == DN:
                n = d[(op >> 9) & 7] & 31
                r.time = {0: 6, 1: 8, 2: 10, 3: 8}[bop]
                if bop and n < 16:
                    r.time -= 2
                r.key += ' max'
                r.note = 'register time is the maximum'
            elif ea == IMM:
                r.time = 10
            else:
                r.time = [4, 8, 8, 8][bop] + ea_time(ea, 1)
                if bop == 2 and is010:
                    r.time += 2
            return r
        sub = (op >> 9) & 7
        if sub == 4:                                            # static bit
            bop = (op >> 6) & 3
            nm = ['BTST', 'BCHG', 'BCLR', 'BSET'][bop]
            r = D('%s #,%s' % (nm, EA_NAMES[ea]), 2 + ea_words(ea, 1))
            if ea == DN:
                n = mem(pc + 2) & 31
                r.time = {0: 10, 1: 12, 2: 14, 3: 12}[bop]
                if bop and n < 16:
                    r.time -= 2
            else:
                r.time = [8, 12, 12, 12][bop] + ea_time(ea, 1)
                if bop == 2 and is010:
                    r.time += 2
            return r
        if sub == 7 and is010 and szf != 3:                     # MOVES
            ext = mem(pc + 2)
            r = D('MOVES.%s %s %s' % ('BWL'[szf], 'R->M' if ext & 0x800 else 'M->R', EA_NAMES[ea]), 2 + EA_EXT[ea])
            t = (MOVES_RM if ext & 0x800 else MOVES_MR).get(ea)
            if t is not None and szf == 2:
                t += 4
            r.time = t
            return r
        if szf == 3:
            return None
        nm = ['ORI', 'ANDI', 'SUBI', 'ADDI', None, 'EORI', 'CMPI', None][sub]
        if nm is None:
            return None
        if ea == IMM:                                           # to CCR / SR
            r = D('%s to %s' % (nm, 'SR' if szf == 1 else 'CCR'), 2)
            r.time = 16 if is010 else 20
            return r
        r = D('%s.%s %s' % (nm, 'BWL'[szf], EA_NAMES[ea]), 1 + (2 if size == 4 else 1) + ea_words(ea, size))
        if ea == DN:
            if size == 4:
                # WinUAE: ADDI/SUBI 14 on the 68010, ORI/ANDI/EORI 16 (the 68010 table has 14)
                r.time = 14 if (nm == 'CMPI' or (is010 and nm in ('ADDI', 'SUBI'))) else 16
            else:
                r.time = 8
        else:
            if nm == 'CMPI':
                r.time = (12 if size == 4 else 8) + ea_time(ea, size)
            else:
                r.time = (20 if size == 4 else 12) + ea_time(ea, size)
        return r
    # line 4
    if line == 4:
        if op == 0x4e71:
            r = D('NOP', 1); r.time = 4; return r
        if op == 0x4e75:
            r = D('RTS', 1); r.time = 16; return r
        if op == 0x4e77:
            r = D('RTR', 1); r.time = 20; return r
        if op == 0x4e73:
            r = D('RTE', 1); r.time = 24 if is010 else 20; return r
        if op == 0x4e74 and is010:
            r = D('RTD', 2); r.time = 16; return r
        if op == 0x4e76:
            r = D('TRAPV', 1)
            r.time = 4 if not (sr & 2) else (38 if is010 else 34)
            if sr & 2:
                r.key = 'TRAPV trap'
            return r
        if op == 0x4e70:
            r = D('RESET', 1); r.time = 130 if is010 else 132; return r
        if (op & 0xfff0) == 0x4e40:
            r = D('TRAP', 1); r.time = 38 if is010 else 34; return r
        if (op & 0xfff8) == 0x4e50:
            r = D('LINK', 2); r.time = 16; return r
        if (op & 0xfff8) == 0x4e58:
            r = D('UNLK', 1); r.time = 12; return r
        if (op & 0xfff0) == 0x4e60:
            r = D('MOVE USP', 1); r.time = 6 if is010 else 4; return r
        if (op & 0xfffe) == 0x4e7a and is010:
            r = D('MOVEC %s' % ('Rn->Rc' if op & 1 else 'Rc->Rn'), 2); r.time = 10 if op & 1 else 12; return r
        if (op & 0xffc0) == 0x4ec0:
            r = D('JMP %s' % EA_NAMES[ea], 1 + EA_EXT[ea]); r.time = JMP.get(ea); return r
        if (op & 0xffc0) == 0x4e80:
            r = D('JSR %s' % EA_NAMES[ea], 1 + EA_EXT[ea]); r.time = JSR.get(ea); return r
        if (op & 0xf1c0) == 0x41c0:
            r = D('LEA %s' % EA_NAMES[ea], 1 + EA_EXT[ea]); r.time = LEA.get(ea); return r
        if (op & 0xf1c0) == 0x4180:
            r = D('CHK %s' % EA_NAMES[ea], 1 + ea_words(ea, 2))
            dn = s16(d[(op >> 9) & 7])
            if ea == DN:
                bound = s16(d[reg])
            elif ea == IMM:
                bound = s16(mem(pc + 2))
            elif dn == 0:
                bound = 0                                       # no trap for any bound >= 0
            else:
                return r
            if dn < 0 or dn > bound:
                r.key += ' trap'
                # WinUAE: the 68000 time plus 4 for the 68010 frame (the 68010 table has 44)
                r.time = (40 if dn < 0 else 38) + (4 if is010 else 0) + ea_time(ea, 2)
            else:
                r.time = 10 + ea_time(ea, 2)            # WinUAE, the 68010 table has 8
            return r
        if (op & 0xffc0) == 0x4840:
            if mode == 0:
                r = D('SWAP', 1); r.time = 4; return r
            if mode == 1 and is010:
                return None                                     # BKPT
            r = D('PEA %s' % EA_NAMES[ea], 1 + EA_EXT[ea]); r.time = PEA.get(ea); return r
        if (op & 0xfb80) == 0x4880:
            if mode == 0:
                r = D('EXT', 1); r.time = 4; return r
            lng = op & 0x40
            mask = mem(pc + 2)
            n = popcount(mask)
            if op & 0x400:
                r = D('MOVEM.%s M->R %s' % ('L' if lng else 'W', EA_NAMES[ea]), 2 + EA_EXT[ea])
                b = MOVEM_MR.get(ea)
            else:
                r = D('MOVEM.%s R->M %s' % ('L' if lng else 'W', EA_NAMES[ea]), 2 + EA_EXT[ea])
                b = MOVEM_RM.get(ea)
            r.time = None if b is None else b + n * (8 if lng else 4)
            return r
        if (op & 0xffc0) == 0x40c0:
            r = D('MOVE from SR %s' % EA_NAMES[ea], 1 + ea_words(ea, 2))
            if ea == DN:
                r.time = 4 if is010 else 6
            else:
                r.time = 8 + (EA_NF_010[ea] if is010 else ea_time(ea, 2))
            return r
        if (op & 0xffc0) == 0x42c0 and is010:
            r = D('MOVE from CCR %s' % EA_NAMES[ea], 1 + ea_words(ea, 2))
            r.time = 4 if ea == DN else 8 + EA_NF_010[ea]
            return r
        if (op & 0xffc0) == 0x44c0:
            r = D('MOVE to CCR %s' % EA_NAMES[ea], 1 + ea_words(ea, 2)); r.time = 12 + ea_time(ea, 2); return r
        if (op & 0xffc0) == 0x46c0:
            r = D('MOVE to SR %s' % EA_NAMES[ea], 1 + ea_words(ea, 2)); r.time = 12 + ea_time(ea, 2); return r
        if (op & 0xffc0) == 0x4800:
            r = D('NBCD %s' % EA_NAMES[ea], 1 + ea_words(ea, 1))
            r.time = 6 if ea == DN else 8 + ea_time(ea, 1)
            return r
        if (op & 0xffc0) == 0x4ac0:
            r = D('TAS %s' % EA_NAMES[ea], 1 + ea_words(ea, 1))
            # the read-modify-write cycle reads the operand: address calculation only
            r.time = 4 if ea == DN else 14 + (EA_NF_010 if is010 else EA_CALC)[ea]
            return r
        sub = (op >> 8) & 15
        if sub in (0, 2, 4, 6, 10) and szf != 3:
            nm = {0: 'NEGX', 2: 'CLR', 4: 'NEG', 6: 'NOT', 10: 'TST'}[sub]
            r = D('%s.%s %s' % (nm, 'BWL'[szf], EA_NAMES[ea]), 1 + ea_words(ea, size))
            if nm == 'TST':
                r.time = 4 + ea_time(ea, size)
            elif nm == 'CLR' and is010:
                r.time = (CLR_010_L if size == 4 else CLR_010_BW).get(ea)
            elif ea == DN:
                r.time = 6 if size == 4 else 4
            else:
                r.time = (12 if size == 4 else 8) + ea_time(ea, size)
            return r
        return None
    return None


def exception_time(cpu, kind):
    t000 = {'illegal': 34, 'priv': 34, 'trace': 34, 'linea': 34, 'linef': 34, 'interrupt': 44}
    t010 = {'illegal': 38, 'priv': 38, 'trace': 38, 'linea': 38, 'linef': 38, 'interrupt': 46}
    return (t010 if cpu == '010' else t000).get(kind)


def main():
    cpu, hexfile, logfile = sys.argv[1:4]
    verbose = '-v' in sys.argv
    words = [int(l, 16) for l in open(hexfile) if l.strip()]
    def mem(a):
        i = (a & 0xffffff) >> 1
        return words[i] if i < len(words) else 0
    rows = []
    for l in open(logfile):
        p = l.split()
        rows.append((int(p[0]), int(p[1], 16), int(p[2], 16), int(p[3]), int(p[4], 16), [int(x, 16) for x in p[5:13]]))
    groups = defaultdict(lambda: defaultdict(int))
    unknown = defaultdict(int)
    for i in range(len(rows) - 1):
        clk, pc, op, exc, sr, d = rows[i]
        nclk, npc, nop, nexc = rows[i + 1][:4]
        meas = nclk - clk
        if exc:
            continue
        if nexc:
            # interrupt or trace after this instruction: the time includes the exception
            continue
        r = decode(cpu, mem, pc, sr, d, npc, nexc)
        if r is None or r.time is None:
            unknown['%04x' % (op & 0xffc0)] += 1
            continue
        groups[r.key][(r.time, meas)] += 1
    bad = 0
    for k in sorted(groups):
        g = groups[k]
        ok = all(e == m for (e, m) in g)
        if not ok:
            bad += 1
        if verbose or not ok:
            print('%-6s %-32s %s' % ('ok' if ok else 'DIFF', k,
                  ' '.join('exp %d got %d (x%d)' % (e, m, n) for (e, m), n in sorted(g.items()))))
    print('%d forms, %d differ, %d instructions not modelled' % (len(groups), bad, sum(unknown.values())))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
