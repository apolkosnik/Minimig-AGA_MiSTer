#!/usr/bin/env python3
#
# FX68K 68010 microcode generator
#
# Builds the micro and nano ROMs used by fx68k.sv from the original 68000
# ROM images kept in this directory:
#
#   microrom.mem  2048 x 17   bank 0 (addresses 0x000-0x3FF) is the original
#                             68000 microcode, bank 1 (0x400-0x7FF) is the
#                             68010 microcode: a copy of bank 0 with
#                             next-address patches plus the new routines
#                             placed in microaddresses unused by the 68000.
#   nanorom.mem   2048 x W    two banks of 1024 rows. Bank 0 is the original
#                             336 nanowords (zero extended to the new width).
#                             Bank 1 is a copy, followed by the nanowords of the
#                             new routines and by the groups of 68000 microwords
#                             with replaced nanowords (NREPL).
#
# It also rewrites the micro to nano address tables in fx68k.sv (between the
# "68010 nanomap" and "68010 remap" markers) and writes a listing, ucode010.lst.
#
# Run from anywhere:  python3 gen_ucode010.py
#
# unames.txt holds the names of the 68000 microwords, as used by the microcode
# based m68000 core of MAME (m68000gen.py), only for the listing and comments.

import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FX = os.path.dirname(HERE)

UROM_WIDTH = 17
NANO_WIDTH_ORG = 68
NANO_WIDTH = 100
NADDR_LIMIT = 1024                  # rows per bank

# ---------------------------------------------------------------------------
# Nanoword fields, fx68k bit numbering (see nDecoder3 in fx68k.sv)
# ---------------------------------------------------------------------------

BITS = dict(
    IR2IRD=67, TOIRC=66, TODBIN=60, LOWBYTE=55, HIGHBYTE=54, DBD2ALUB=49,
    ABD2ALUB=48, DBIN2DBD=47, DBIN2ABD=46, ALU2ABD=45, ALU2DBD=44, RZ=43,
    BUSBYTE=42, PCLABL=41, RXL_DBL=40, PCLDBL=39, ABDISBYTE=38, REG2ABL=37,
    ABL2REG=36, ABLABD=35, DBLDBD=34, DBL2REG=33, REG2DBL=32, SSP=24,
    RXH_DBH=22, AUCLKEN=19, DBLDBH=15, ABLABH=14, EXT_ABH=13, EXT_DBH=12,
    REG2ABH=8, ABH2REG=7, REG2DBH=6, DBH2REG=5, ALU_ACTRL=50,
    # 68010 additions
    EXTLATCH=68,    # extension word latch <= IRC
    IRSYNTH=69,     # IR <= synthesized opcode (MOVEC/MOVES)
    AUVBR=72,       # AU <= VBR + DBL[9:0]
    SSW010=73,      # FTU <= 68010 special status word
    CCRONLY=74,     # SR to FTU reads the CCR only (MOVE from CCR)
    IRLOOP=75,      # IR <= IRC loads the looped instruction instead (loop mode)
    IRCLOOP=76,     # IRC <= first word of the DBcc (loop mode)
    FMTCCR=79,      # RTE: invalid format word sets N from bit 15, clears Z and V
    AOBZERO=83,     # AOB <= 0 (breakpoint acknowledge)
    TPEND=84,       # Tpend <= T, the trace pending update of FTU updTpend
    HILATCH=85,     # latch the high words of RX and RY (long ALU ops)
    HISEL=86,       # ... RX high is the data operand, RY high the address operand
    HIOP=87,        # the ALU works on the latched high words
    FTUABL=88,      # ABL <= FTU, the FTU control field stays free
    SHW=96,         # bus error frame internal state word SHIDX <= DBIN (RTE)
    RESUME=97,      # RTE format 8: restore the internal state, rerun the faulted cycle
    AOBPC=99,       # AOB <= PC (with AOBCTRL AB)
    AUK2=98,        # AU constant, with AUK: 1 +16, 2 -14, 3 ALU output (sign extended) +2
)
FIELDS = dict(
    AUCTRL=(16, 3), AUOUT=(20, 2), ATLCTRL=(29, 3), ATHCTRL=(9, 3),
    AOBCTRL=(3, 2), PCH=(0, 2), ALU_DCTRL=(51, 2), ALU_FI=(61, 2), DCR=(57, 3),
    TVNFORCE=(70, 2),
    AUK=(77, 2),    # AU constant instead of AUCTRL: 1 +6, 2 +22, 3 +30
    DOBX=(80, 3),   # DOB source: 1 zero, 2 saved DOB, 3 SSW, 4 IRC, 5 DIB, 6 internal state
                    # word SHIDX, 7 data output of the frame (rerun of a write, no DOB source)
    AUCC=(89, 2),   # AU input on the IRD condition: 1 cc ? AB : 2, 2 cc ? 2 : AB
    SHIDX=(91, 5),  # bus error frame internal state word (1-24, see fx68k.sv excUnit)
)

# AU control (input added to DB)
AU_0, AU_INC, AU_M4, AU_AB, AU_P2, AU_P4, AU_M2, AU_DEC = range(8)
# AU output
AUO_DB, AUO_AB, AUO_PC = 1, 2, 3
# AOB source
AOB_AB, AOB_DB, AOB_AU = 1, 2, 3
# DOB source (bits 56,53)
DOB_DBD, DOB_ADB, DOB_ALU = 1, 2, 3
# FTU control
FTU_CONST, FTU_2SR, FTU_DBL, FTU_PSWI, FTU_INL, FTU_RDSR, FTU_2ABL, FTU_IRD, \
    FTU_SSW, FTU_ABL2PREN, FTU_TVN = 1, 2, 4, 5, 6, 7, 8, 9, 11, 12, 13
# ATL / ATH control
ATL_DBL2ATL, ATL_ATL2DBL, ATL_ABL2ATL, ATL_ATL2ABL = 2, 3, 4, 5
ATH_ABH2ATH, ATH_DBH2ATH, ATH_ATH2DBH, ATH_ATH2ABH = 1, 4, 6, 3
# ALU data control
ALUD_DB, ALUD_ZERO, ALUD_FFFF = 0, 1, 3
# Forced TVN
TVN_ILLEGAL, TVN_FORMAT = 1, 2
# AU constants
AUK_6, AUK_22, AUK_30 = 1, 2, 3
# DOB sources
DOBX_ZERO, DOBX_SAVED, DOBX_SSW, DOBX_IRC, DOBX_DIB, DOBX_SH, DOBX_RERUN = 1, 2, 3, 4, 5, 6, 7


def nget(nw, f):
    if f in BITS:
        return (nw >> BITS[f]) & 1
    if f == 'FTU':
        return (((nw >> 25) & 1) << 3) | (((nw >> 26) & 1) << 2) | (((nw >> 27) & 1) << 1) | ((nw >> 28) & 1)
    if f == 'DOB':
        return (((nw >> 56) & 1) << 1) | ((nw >> 53) & 1)
    if f == 'ALU_COL':
        return (((nw >> 63) & 1) << 2) | (((nw >> 64) & 1) << 1) | ((nw >> 65) & 1)
    lo, w = FIELDS[f]
    return (nw >> lo) & ((1 << w) - 1)


def nset(nw, f, v):
    def setbit(nw, n, b):
        return (nw & ~(1 << n)) | ((b & 1) << n)
    if f in BITS:
        return setbit(nw, BITS[f], v)
    if f == 'FTU':
        for i, n in enumerate((28, 27, 26, 25)):
            nw = setbit(nw, n, v >> i)
        return nw
    if f == 'DOB':
        return setbit(setbit(nw, 53, v), 56, v >> 1)
    if f == 'ALU_COL':
        return setbit(setbit(setbit(nw, 65, v), 64, v >> 1), 63, v >> 2)
    lo, w = FIELDS[f]
    m = ((1 << w) - 1) << lo
    return (nw & ~m) | ((v << lo) & m)


# AU clock enable is active low in the ROM
def au(nw, ctrl):
    return nset(nset(nw, 'AUCLKEN', 0), 'AUCTRL', ctrl)


def nano(base=0, **mods):
    nw = base
    for f, v in mods.items():
        if f == 'AU':
            nw = au(nw, v)
        elif f == 'AUOFF':
            nw = nset(nw, 'AUCLKEN', 1)
        else:
            nw = nset(nw, f, v)
    return nw


NANO_IDLE = nano(AUOFF=1)        # no transfers, AU not clocked

# ---------------------------------------------------------------------------
# Microword encoding (see sequencer in fx68k.sv)
# ---------------------------------------------------------------------------

def mw_next_bits(addr):
    return ((((addr >> 8) & 3) << 13) | (((addr >> 6) & 3) << 5) |
            (((addr >> 2) & 15) << 7) | ((addr & 3) << 11))

MW_NEXT_MASK = mw_next_bits(0x3ff)


def mw_jmp(addr, ir=0, fc=0, grp0=0):
    return mw_next_bits(addr) | ir | (grp0 << 4) | (fc << 15)


def mw_cond(cbc, base, ir=0, fc=0):
    assert (base & 0xc0) == 0
    return (mw_next_bits(base) & ~(3 << 5)) | ir | 2 | (cbc << 2) | (fc << 15)


def mw_retarget(mw, addr):
    """Same microword (IR, FC, latch bits) with a new direct next address."""
    assert (mw & 0xe) == 0, 'not a direct branch'
    return (mw & ~MW_NEXT_MASK) | mw_next_bits(addr)


def mw_rebase(mw, base):
    """Same conditional microword with a new branch base."""
    assert (mw & 2) and (base & 0xc0) == 0
    return (mw & ~(MW_NEXT_MASK & ~(3 << 5))) | (mw_next_bits(base) & ~(3 << 5))


# New condition codes (sequencer cbc), see fx68k.sv
CBC_MOVEC_OK = 0x10      # 11: control register valid, 00: illegal
CBC_RTE_FMT = 0x13       # 00: format 0, 01: format 8, 11: invalid format
CBC_LOOP_DB = 0x14       # 00: loop continues, 01: count expired, 11: condition true
CBC_RTE_VER = 0x16       # 00: format 8 version number valid, 11: invalid

# ---------------------------------------------------------------------------
# ROM images
# ---------------------------------------------------------------------------

def load_mem(fn):
    return [int(l, 2) for l in open(fn).read().split()]


micro68 = load_mem(os.path.join(HERE, 'microrom68000.mem'))
nano68 = load_mem(os.path.join(HERE, 'nanorom68000.mem'))
names = open(os.path.join(HERE, 'unames.txt')).read().split('\n')
assert len(micro68) == 1024 and len(nano68) == 336

svfile = os.path.join(FX, 'fx68k.sv')
sv = open(svfile, 'rb').read().decode()        # keep the line endings
nmap68 = {int(a, 16): int(b, 16) for a, b in
          re.findall(r"^'h([0-9A-Fa-f]+): orgBase = 7'h([0-9A-Fa-f]+) ;\s*$",
                     sv.split('// 68010 nanomap begin')[0], re.M)}
assert len(nmap68) == 136, len(nmap68)


def nano_of(ua):
    """68000 nanoword executed at microaddress ua."""
    return nano68[nmap68[ua >> 2] * 4 + (ua & 3)]


def free_addr(ua):
    return micro68[ua] == 0 and (ua >> 2) not in nmap68

# ---------------------------------------------------------------------------
# Labels of existing 68000 microwords used here
# ---------------------------------------------------------------------------

L = dict(bbci1=0x308, bbci2=0x045, bbci3=0x0c5, dbcc1=0x06c, dbcc2=0x046, dbcc3=0x175, dbcc4=0x0c7, lusp1=0x2f5, susp1=0x230,
         rmml1=0x2fc, bclm1=0x069, bclm2=0x067, bcsm2=0x082, stiw3=0x320, stiw4=0x321, strw2=0x340,
         rcal3=0x08d, rorl1=0x1c5, rorl2=0x3c0, rorl3=0x25e, roml3=0x25d, roal1=0x10c,
         roal2=0x259, roal3=0x25a, roal4=0x25b, adrw1=0x006, pinw1=0x21c, pinw2=0x21d,
         pdcw1=0x103, pdcw2=0x17b, adsw1=0x1c2, adsw2=0x02a, aixl0=0x1e3, aixl1=0x3e2,
         aixl2=0x120, aixl5=0x1e0, abwl1=0x00a, abll1=0x1e2, abll2=0x009, abll3=0x004,
         tasm1=0x343, rmmw1=0x2f8, rmxw0=0x1eb, rmxl0=0x1ef, mulm2=0x3c4, mulm4=0x0e0,
         mulm6=0x020, dvum3=0x023, dvum4=0x2d1, dvum5=0x291, dvum6=0x2d0, dvumb=0x3e9,
         dvs09=0x295, dvs0a=0x2d4, dvs0d=0x3ed, dvs01=0x0ac, dvs02=0x0ae, dvs03=0x0c9,
         dvs08=0x216, dvs17=0x04d, dvs1c=0x251, dvs1f=0x08a, dvs20=0x049, dvumz=0x2d5,
         dvumf=0x080, dvumd=0x0c0, dvum0=0x212, dvuma=0x0e6, leaa2=0x066, dvur1=0x0a6,
         dvum1=0x0a4, dvum2=0x213,
         bser1=0x003, trpv1=0x06d, trpv2=0x0e2, trpv3=0x022, dvur2=0x0e3,
         dvur3=0x217, trac1=0x1c0, trac2=0x3a3, trap1=0x1d0, trap2=0x347,
         trap3=0x3c2, trap4=0x360, trap5=0x0ef, trap6=0x367, trap7=0x11a,
         itlx2=0x234, itlx3=0x235, itlx4=0x0eb, b=0x363, mmrw3=0x34c,
         rtr1=0x12a, rtr2=0x12b, rtr3=0x3c5, rtr4=0x302, jmal2=0x2b3,
         rts1=0x126, rts2=0x116, rts3=0x303, bser2=0x3a7, trap4n=0x360,
         strw1=0x3a5, stmw1=0x3a1, dbcc5=0x007, dbcc6=0x0c6)

# Fixed microaddresses. Entry points are referenced by fx68k.sv (uaddrDecode).
# Conditional branch targets share all address bits except 7:6.
FIXED = dict(
    RTE1=0x010, RTD1=0x011, MVC1=0x012, MVS1=0x013,
    CCRW1=0x3f0, CCMW1=0x3f1,
    LDB1=0x3f2,                                     # loop mode DBcc
    BK1=0x3f3,                                      # BKPT
    USPI=0x3f4, USPO=0x3f5, MLPD=0x3f6,             # timing: MOVE USP, MOVE.L Rn,-(An)
    RL1S=0x3f7, RA1S=0x3f8,                         # long ALU ops with the 68000 time
    NAI=0x3f9, NAIP=0x3fa, NAID=0x3fb, NAD=0x3fc,   # EA without the operand read
    NAX=0x3fd, NAW=0x3fe, NAL=0x3ff,
    NX2=0x209, NX5=0x2c9,                           # NX1 cond base 0x209
    TASI1=0x0f0, TASI2=0x0f1, CPDW=0x0f2, CXW=0x0f3, CXL=0x0f4,
    MVSK1=0x0f5, MVSK2=0x0f6, MVSK3=0x0f7, MVSKD=0x0f8,
    MVD0=0x20f, MVD3=0x2cf,                         # MVSKD cond base 0x20f
    MULI=0x20a, MULJ=0x2ca,                         # mulm2 cond base 0x20a
    MUL6=0x24b, MSN=0x2cb,                          # MS1/MSN cond base 0x20b
    DV5R=0x28c, DV6C=0x2cc,                         # dvumb cond base 0x20c
    DVI=0x28d, DVUA=0x2cd,                          # dvum3 cond base 0x20d
    DS9R=0x28e, DSAC=0x2ce,                         # dvs0d cond base 0x20e
    DBX=0x206, DB4C=0x2c6,                          # dbcc3 cond base 0x206
    BNT=0x247, BTK=0x2c7,                           # bbci1 cond base 0x207
    DC2=0x248, DTK=0x2c8,                           # dbcc1 cond base 0x208
    LCONT=0x203, LEXP=0x243, LCC=0x2c3,             # LDB1 cond base 0x203
    MVCILL=0x200, PRO2=0x2c0,                       # MVC1 cond base 0x200
    RTE4=0x201, R8A=0x241, FE1=0x2c1,               # RTE3 cond base 0x201
    R8G=0x204, FE1B=0x2c4,                          # R8E cond base 0x204
    E_TRPV3=0x202, E_TRPV2=0x2c2,                   # trpv1 cond base 0x202
)

words = []        # [name, micro (may hold label refs), nano]
NREPL = {}        # bank 1 nanoword of a 68000 microaddress: the group gets its own rows


def W(name, nanow, nxt=None, cond=None, ir=0, fc=0, grp0=0, micro=None, dispatch=None):
    words.append(dict(name=name, nano=nanow, nxt=nxt, cond=cond, ir=ir, fc=fc,
                      grp0=grp0, micro=micro, dispatch=dispatch))


# ---------------------------------------------------------------------------
# Group 1/2 exceptions: format 0 stack frame and VBR
#
#   68000:  SSP-2 PCL, SSP-6 SR, SSP-4 PCH            (3 words)
#   68010:  SSP-4 PCL, SSP-8 SR, SSP-6 PCH, SSP-2 format/vector offset
#
# The frame entries compute SSP-4 instead of SSP-2. trap3/itlx4 and trap4 are
# reused unchanged, trap5 is replaced by a copy that leaves the AU pointing at
# the format word, which T5B writes while it also computes VBR+offset.
# ---------------------------------------------------------------------------

for e in ('trac2', 'trap2', 'dvur3', 'itlx3'):
    W('E_' + e.upper(), nano(nano_of(L[e]), AU=AU_M4), micro=('copy', L[e]))

# TRAPV: trpv1 is a conditional branch to trpv3 (exception) / trpv2 (no trap)
W('E_TRPV3', nano(nano_of(L['trpv3']), AU=AU_M4), micro=('copy', L['trpv3']))
W('E_TRPV2', nano_of(L['trpv2']), micro=('copy', L['trpv2']))

# trap5 leaving AU at the format word (SSP-6 + 4)
W('T5A', nano(nano_of(L['trap5']), AU=AU_P4), micro=('retarget', L['trap5'], 'T5B'))
# write the format word (FTU = vector offset), AU <= VBR + offset
W('T5B', nano(NANO_IDLE, AOBCTRL=AOB_AU, DOB=DOB_ADB, FTU=FTU_2ABL, AU=AU_0, AUVBR=1),
  nxt='T6P', fc=1)
# trap6 reading the vector at AU instead of AT
W('T6P', nano(nano_of(L['trap6']), ATLCTRL=0, ATHCTRL=0, AUOUT=AUO_DB),
  micro=('copy', L['trap6']))

# ---------------------------------------------------------------------------
# RTE reads SR, the format word, PC high and PC low, 24 clocks for format 0.
# The format is tested while PC high is read: any format but 0 and 8 is a
# format error (vector 14) with SR and SP unchanged, and N set from bit 15
# of the format word, Z and V cleared.
#
# Format 8 reads all 26 words of the frame: PC low, SSW, fault address and the
# first internal word (SP+26), whose version number (bits 13:10) must be 0 (a
# format error otherwise, after 12 reads as the manual has it), then the data
# output, data input and instruction input buffers and the other 15 internal
# words. They are kept in the internal state words of excUnit (SHIDX). RES1
# restores the internal state of the faulted microcycle, reruns the faulted bus
# cycle (the handler did it if SSW RR is set: a read then takes the data input
# buffer of the frame, a write is skipped) and continues the instruction with
# the next microinstruction.
# ---------------------------------------------------------------------------

# SR at SP, AU <= SP+6
W('RTE1', nano(nano_of(L['rtr1']), AUK=AUK_6), micro=('retarget', L['rtr1'], 'RTE2'))
# format at SP+6, FTU <= SR, AU <= SP+2
W('RTE2', nano(nano_of(L['rtr2']), AU=AU_M4, TOIRC=0), micro=('retarget', L['rtr2'], 'RTE3'))
# PC high at SP+2, AU <= SP+4, branch on the format
W('RTE3', nano(NANO_IDLE, AOBCTRL=AOB_DB, AUOUT=AUO_DB, AU=AU_P2, TODBIN=1, FMTCCR=1),
  cond=(CBC_RTE_FMT, 'RTE4'), fc=1)
# format 0: start PC low at SP+4, AT <= PC high, AU <= SP+8
W('RTE4', nano(nano_of(L['rtr3']), AU=AU_P4), micro=('copy', L['rtr3']))
words[-1]['micro'] = ('retarget', L['rtr3'], 'RTE5')
# rtr4: wait for PC low, SR <= FTU, SP <= AU, then jmal2
W('RTE5', nano_of(L['rtr4']), micro=('copy', L['rtr4']))

# format 8: read the word at AU (it waits for it), AU += step, the previous word
# (in DBIN) to the internal state word idx
def frame_read(step, idx):
    n = nano(NANO_IDLE, AOBCTRL=AOB_DB, AUOUT=AUO_DB, TODBIN=1)
    if step == 16:
        n = nano(n, AUCLKEN=0, AUK=1, AUK2=1)
    elif step == -14:
        n = nano(n, AUCLKEN=0, AUK=2, AUK2=1)
    else:
        n = au(n, STEP[step])
    if idx:
        n = nano(n, SHW=1, SHIDX=idx)
    return n
STEP = {-4: AU_M4, -2: AU_M2, 2: AU_P2, 4: AU_P4}
W('R8A', frame_read(4, 17), nxt='R8B', fc=1)          # PC low (SP+4), PC high
W('R8B', frame_read(2, 18), nxt='R8C', fc=1)          # SSW (SP+8), PC low
# The version number is read before the fault address low, so that the word
# reading the latter can branch on it (RTE with a wrong version: 70 clocks).
W('R8C', frame_read(16, 19), nxt='R8D', fc=1)         # fault address high (SP+10), SSW
W('R8D', frame_read(-14, 20), nxt='R8E', fc=1)        # internal word 0 (SP+26), fault address high
W('R8E', frame_read(4, 16), cond=(CBC_RTE_VER, 'R8G'), fc=1)  # fault address low (SP+12), version
W('R8G', frame_read(4, 21), nxt='R8H', fc=1)          # data output buffer (SP+16), fault address low
W('R8H', frame_read(4, 22), nxt='R8I', fc=1)          # data input buffer (SP+20)
W('R8I', frame_read(4, 23), nxt='R8J', fc=1)          # instruction input buffer (SP+24)
W('R8J', frame_read(2, 24), nxt='R8K1', fc=1)         # internal word 1 (SP+28)
for i in range(1, 15):                                # internal words 2-15 (SP+30 to SP+56)
    W('R8K%d' % i, frame_read(2, i), nxt='R8K%d' % (i + 1) if i < 14 else 'R8L', fc=1)
# internal word 15, SR <= FTU, SP <= AU (SP+58)
W('R8L', nano(nano_of(L['rtr4']), TODBIN=0, ATHCTRL=0, DBIN2ABD=0, ABLABD=0, ABLABH=0, SHW=1, SHIDX=15),
  nxt='RES1')
# restore, rerun, continue (fx68k.sv takes the next microaddress from the frame)
W('RES1', nano(NANO_IDLE, RESUME=1, DOBX=DOBX_RERUN), nxt=L['b'])
# format error: trac1 with TVN 14, the trace pending is kept
FE1N = nano(nano_of(L['trac1']), TVNFORCE=TVN_FORMAT)
W('FE1', FE1N, micro=('retarget', L['trac1'], 'FE2'))
W('FE1B', FE1N, micro=('retarget', L['trac1'], 'FE2'))
W('FE2', nano(nano_of(L['trac2']), AU=AU_M4, FTU=15), micro=('copy', L['trac2']))

# ---------------------------------------------------------------------------
# RTD #d16: RTS with SP += d16. rts1 leaves the displacement (DBIN at the
# start of the instruction) in the ALU output latch.
# ---------------------------------------------------------------------------

# RTD2 adds the displacement + 2 instead of 2: 16 clocks, as RTS.
W('RTD1', nano_of(L['rts1']), micro=('retarget', L['rts1'], 'RTD2'))
W('RTD2', nano(nano_of(L['rts2']), AUK=3, AUK2=1), micro=('copy', L['rts2']))

# ---------------------------------------------------------------------------
# MOVEC / MOVES prologue. Latch the extension word, load IR with an
# equivalent MOVE USP (MOVEC) or MOVE (MOVES) opcode, prefetch the next word
# (like b + mmrw3) and dispatch on the synthesized opcode.
# ---------------------------------------------------------------------------

W('MVC1', nano(NANO_IDLE, EXTLATCH=1, IRSYNTH=1), cond=(CBC_MOVEC_OK, 'MVCILL'))
W('MVCILL', nano(NANO_IDLE, TVNFORCE=TVN_ILLEGAL), nxt='MVCI2')

# BKPT: breakpoint acknowledge cycle (CPU space, address 0, data ignored), then
# the illegal instruction exception
W('BK1', nano(NANO_IDLE, AOBCTRL=AOB_AB, AOBZERO=1, TODBIN=1, TVNFORCE=TVN_ILLEGAL),
  nxt=L['trac1'], fc=3)
W('MVS1', nano(NANO_IDLE, EXTLATCH=1, IRSYNTH=1), nxt='PRO2')
# b without IR <= IRC
W('PRO2', nano_of(L['b']), micro=('copy_noir', L['b']))

# ---------------------------------------------------------------------------
# MOVE from CCR: the MOVE from SR microcode reading the CCR only.
# strw1 is the Dn entry, stmw1 the operation entry after the EA microcode.
# ---------------------------------------------------------------------------

W('CCRW1', nano(nano_of(L['strw1']), CCRONLY=1), micro=('retarget', L['strw1'], 'STR2'))
W('CCMW1', nano(nano_of(L['stmw1']), CCRONLY=1), micro=('copy', L['stmw1']))

# ---------------------------------------------------------------------------
# Loop mode DBcc. The looped instruction X is at L, the DBcc at L+2, its
# displacement (-4) at L+4. At the start of the DBcc PC = L+4.
# LDB1 decrements Dn.w into the ALU latch, computes AU = PC-2 and branches on
# the condition and on Dn.w == 0 at once. Continuing loads IR and IRC from the
# loop buffer and dispatches X without fetching. Termination joins the
# regular DBcc microcode, which fetches from L+6.
# ---------------------------------------------------------------------------

DB_PC = dict(REG2DBL=1, REG2DBH=1, PCLDBL=1, PCH=1)       # PC on DB
W('LDB1', nano(NANO_IDLE, AU=AU_M2, RXL_DBL=1, REG2ABL=1, ALU_COL=3, ALU_DCTRL=ALUD_FFFF, **DB_PC),
  cond=(CBC_LOOP_DB, 'LCONT'))
# IR <= X, IRC <= DBcc, Dn.w <= ALU (as roaw2), PC <= AU (L+2), AU <= L+4
W('LCONT', nano(NANO_IDLE, IRLOOP=1, IRCLOOP=1, AUOUT=AUO_DB, AU=AU_P2, DBL2REG=1, DBH2REG=1,
                PCLDBL=1, PCH=1, RXL_DBL=1, ABL2REG=1, ABLABD=1, ABDISBYTE=1, ALU2ABD=1),
  nxt='LDISP', ir=1)
# mmrw3 without the prefetch
W('LDISP', nano(nano_of(L['mmrw3']), TOIRC=0, TODBIN=0), micro=('copy', L['mmrw3']))
# count expired: PC <= L+6, then the regular DBcc exit (dbcc5 writes Dn)
W('LEXP', nano(NANO_IDLE, AU=AU_P2, **DB_PC), nxt='LEXP2')
W('LEXP2', nano(NANO_IDLE, AUOUT=AUO_PC), nxt=L['dbcc5'])
# condition true: regular DBcc exit
W('LCC', nano_of(L['dbcc6']), micro=('copy', L['dbcc6']))

# ---------------------------------------------------------------------------
# Bus / address error: format 8 frame, 29 words, 26 of them written.
#
#   SP+0  SR            SP+14 unused          SP+26..56 internal (16 words,
#   SP+2  PC high       SP+16 data output                 SP+26 version 0)
#   SP+4  PC low        SP+18 unused
#   SP+6  $8 / vector   SP+20 data input
#   SP+8  SSW           SP+22 unused
#   SP+10 fault address SP+24 instruction input
#
# Write order as measured on a 68010 (WinUAE): internal words 28 26 27 25 23 24
# 22 21 20 19 18 17 16 15 13 14, instruction input, data input, data output,
# fault address low and high, SSW, PC low, SR, PC high, format. The unused
# words are skipped. The internal words hold the internal state of the faulted
# microcycle (snapshot in fx68k.sv), for the continuation by RTE.
# bser1 (unchanged) latched AT <= fault address, FTU <= SR, AU <= PC, the SSW
# and the data output buffer. B2 (bser2) sets S, PC <= AU, AU <= SSP-2.
# ---------------------------------------------------------------------------

W('B2', nano_of(L['bser2']), micro=('retarget', L['bser2'], 'FW0'))
FWN = nano(NANO_IDLE, AOBCTRL=AOB_AU, DOB=DOB_ADB, AUOUT=AUO_DB)
STEP = {-4: AU_M4, -2: AU_M2, 2: AU_P2, 4: AU_P4}
# (frame word, data, AU step to the next word)
FRAME = [(28, 'z', -4), (26, 'z', 2), (27, 'z', -4), (25, 'z', -4), (23, 'z', 2), (24, 'z', -4),
         (22, 'z', -2), (21, 'z', -2), (20, 'z', -2), (19, 'z', -2), (18, 'z', -2), (17, 'z', -2),
         (16, 'z', -2), (15, 'z', -4), (13, 'z', 2), (14, 'z', -4),
         (12, 'iib', -4), (10, 'dib', -4), (8, 'dob', -4), (6, 'fal', -2), (5, 'fah', -2),
         (4, 'ssw', -4), (2, 'pcl', -4), (0, 'sr', 2), (1, 'pch', 4), (3, 'fmt', None)]
for i, (fw, data, step) in enumerate(FRAME):
    n = FWN
    if step is not None:
        n = au(n, STEP[step])
    if i == 0:
        # latch the TVN of the bus or address error, ALUB <= SR
        n = nano(n, IR2IRD=1, FTU=FTU_2ABL, ABD2ALUB=1, DOBX=DOBX_SH, SHIDX=fw - 13)
    elif data == 'z':
        # internal state words: SP+26 is word 16 (version 0), SP+28 to SP+56 words 1-15
        n = nano(n, DOBX=DOBX_SH, SHIDX=16 if fw == 13 else fw - 13)
    elif data == 'iib':
        n = nano(n, DOBX=DOBX_IRC)
    elif data == 'dib':
        n = nano(n, DOBX=DOBX_DIB)
    elif data == 'dob':
        n = nano(n, DOBX=DOBX_SAVED)
    elif data == 'fal':
        n = nano(n, ATLCTRL=ATL_ATL2ABL)
    elif data == 'fah':
        n = nano(n, ATHCTRL=ATH_ATH2ABH)
    elif data == 'ssw':
        n = nano(n, DOBX=DOBX_SSW)
    elif data == 'pcl':
        # PC low; ALU <= ALUB (SR) for the next word
        n = nano(n, REG2ABL=1, PCLABL=1, ABLABD=1, ALU_COL=1, ALU_ACTRL=1, ALU_DCTRL=ALUD_FFFF)
    elif data == 'sr':
        # SR from the ALU, SSP <= AU, FTU <= format / vector offset
        n = nano(n, DOB=DOB_ALU, SSP=1, DBL2REG=1, DBH2REG=1, RXL_DBL=1, RXH_DBH=1, FTU=FTU_TVN)
    elif data == 'pch':
        n = nano(n, PCH=2, REG2ABH=1, ABLABD=1, ABLABH=1)
    elif data == 'fmt':
        n = nano(NANO_IDLE, AOBCTRL=AOB_AU, DOB=DOB_ADB, FTU=FTU_2ABL, AU=AU_0, AUVBR=1)
    W('FW%d' % i, n, nxt='FW%d' % (i + 1) if i + 1 < len(FRAME) else 'T6P', fc=1)

# ---------------------------------------------------------------------------
# Instruction timing (Section 9 of the M68000 User's Manual, with the
# corrections of WinUAE, which were measured on a 68010)
# ---------------------------------------------------------------------------

# MOVE USP and MOVEC Rc,Rn: 2 clocks more (fx68k.sv enters these instead of
# lusp1 / susp1). MOVEC Rn,Rc keeps the 68000 time of MOVE An,USP.
W('USPI', NANO_IDLE, nxt=L['lusp1'])
W('USPO', NANO_IDLE, nxt=L['susp1'])
# MOVE.L Dn/An,-(An): 2 clocks more
W('MLPD', NANO_IDLE, nxt=L['rmml1'])
# BCLR to memory: 2 clocks more, before the write
W('BCLI', NANO_IDLE, nxt=L['bcsm2'])
# Bcc.B not taken: 6 clocks. bbci1 computes PC+2 instead of the branch address
# when the condition is false and continues with b directly (instead of bbci2).
NREPL[L['bbci1']] = nano(nano_of(L['bbci1']), AUCC=1)
W('BNT', nano_of(L['b']), micro=('copy', L['b']))
W('BTK', nano_of(L['bbci3']), micro=('copy', L['bbci3']))
# DBcc condition true: 10 clocks. dbcc1 computes PC+2 (condition true) or the
# branch address, with PC on DB and the displacement on AB, and continues with
# bbci3 (fetch, then b) when the condition is true (instead of dbcc6).
NREPL[L['dbcc1']] = nano(nano_of(L['dbcc1']), AUCC=2, PCH=1, PCLDBL=1, PCLABL=0, REG2DBL=1, REG2DBH=1,
                         REG2ABL=0, REG2ABH=0, DBLDBD=0, EXT_DBH=0, DBIN2DBD=0, DBIN2ABD=1, ABLABD=1,
                         EXT_ABH=1)
W('DC2', nano_of(L['dbcc2']), micro=('copy', L['dbcc2']))
W('DTK', nano_of(L['bbci3']), micro=('copy', L['bbci3']))
# DBcc, counter expired: 2 clocks more. dbcc3 branches to DBX (expired) or DB4C.
W('DBX', NANO_IDLE, nxt=L['dbcc5'])
W('DB4C', nano_of(L['dbcc4']), micro=('copy', L['dbcc4']))
# ANDI/ORI/EORI to CCR/SR: no refill of the prefetch queue. IRC holds the next
# opcode already, stiw3 points the AU to the word after it and continues with a
# copy of stiw4 (shared with MOVE to SR) that jumps to b.
NREPL[L['stiw3']] = nano(nano_of(L['stiw3']), AU=AU_P4)
W('STW4', nano_of(L['stiw4']), micro=('retarget', L['stiw4'], L['b']))
# MOVE from SR/CCR to Dn: 4 clocks, strw2 and rcal3 in one microcycle. The FTU
# goes to ABL with FTUABL, the FTU control loads the constant of the next
# instruction and updates the trace pending flag as in rcal3.
STR2 = nano(nano_of(L['strw2']), FTU=FTU_CONST, FTUABL=1, IR2IRD=1, AU=AU_P2, PCH=1, PCLDBL=1,
            REG2DBL=1, REG2DBH=1)
W('STR2', STR2, micro=('retarget', L['rcal3'], None))
# Long register ALU ops (rorl: ADD/SUB/AND/OR.L Rn/#,Dn, ADDX/SUBX.L, ADDA/SUBA.L;
# roal: EOR.L, ADDI/SUBI/ANDI/ORI/EORI.L): 6 clocks instead of 8. The first
# microcycle latches the high words of the operands, the second one works on them
# while it writes the low result back, the third one writes the high result.
# The slow entries keep the 68000 time with an idle microcycle at the end.
def hi_first(ua, sel):
    return nano(nano_of(ua), HILATCH=1, HISEL=sel)
def hi_second(ua, hi):
    n = nano_of(ua)
    for f in ('ALU_COL', 'ALU_DCTRL', 'ALU_ACTRL', 'ALU_FI'):
        n = nset(n, f, nget(nano_of(hi), f))
    return nano(n, HIOP=1)
# rorl3 has RX high on DBH (data), RY high on ABH; roal3 the other way round
RL1 = hi_first(L['rorl1'], 1)
RA1 = hi_first(L['roal1'], 0)
NREPL[L['rorl1']] = RL1
NREPL[L['roal1']] = RA1
W('RL2F', hi_second(L['rorl2'], L['rorl3']), nxt=L['roml3'])
W('RA2F', hi_second(L['roal2'], L['roal3']), nxt=L['roal4'])
W('RL1S', RL1, micro=('retarget', L['rorl1'], 'RL2S'))
W('RL2S', hi_second(L['rorl2'], L['rorl3']), nxt='RLI')
W('RLI', NANO_IDLE, nxt=L['roml3'])
W('RA1S', RA1, micro=('retarget', L['roal1'], 'RA2S'))
W('RA2S', hi_second(L['roal2'], L['roal3']), nxt='RAI')
W('RAI', NANO_IDLE, nxt=L['roal4'])

# Scc, MOVE from SR/CCR to memory: the 68010 doesn't read the operand. Copies of
# the effective address routines without the read, ending with the a3 dispatch.
# The address is in AT as in the 68000 routines.
MW_A3 = 0x0000c
def noread(ua, todbin=True):
    n = nano(nano_of(ua), AOBCTRL=0, BUSBYTE=0)
    return n if todbin else nano(n, TODBIN=0)
W('NAI', noread(L['adrw1']), micro=MW_A3)
W('NAIP', noread(L['pinw1']), nxt='NAIP2')
W('NAIP2', noread(L['pinw2'], False), micro=MW_A3)
W('NAID', nano_of(L['pdcw1']), micro=('retarget', L['pdcw1'], 'NAID2'))
W('NAID2', noread(L['pdcw2'], False), micro=MW_A3)
# The prefetch that replaces the extension word: in the 68000 routines the
# microcycle that starts it also waits for it (toIrc), the read follows. Without
# the read the wait moves to the next microcycle, which then takes no extra clocks.
def nowait(ua):
    return nano(nano_of(ua), TOIRC=0, TODBIN=0)
W('NAD', nowait(L['adsw1']), micro=('retarget', L['adsw1'], 'NAD2'))
W('NAD2', nano(noread(L['adsw2']), TOIRC=1, TODBIN=1), micro=MW_A3)
W('NAX', nano_of(L['aixl0']), micro=('retarget', L['aixl0'], 'NX1'))
W('NX1', nano_of(L['aixl1']), micro=('rebase', L['aixl1'], 'NX2'))
W('NX2', nano_of(L['aixl2']), micro=('retarget', L['aixl2'], 'NAX3'))
W('NX5', nano_of(L['aixl5']), micro=('retarget', L['aixl5'], 'NAX3'))
W('NAX3', noread(L['adsw2']), micro=MW_A3)
W('NAW', nowait(L['abwl1']), micro=('retarget', L['abwl1'], 'NAW2'))
W('NAW2', nano(noread(L['abll3'], False), TOIRC=1, TODBIN=1), micro=MW_A3)
W('NAL', nano_of(L['abll1']), micro=('retarget', L['abll1'], 'NAL2'))
W('NAL2', nowait(L['abll2']), micro=('retarget', L['abll2'], 'NAW2'))

# TAS: the 68010 calculates the address before the read-modify-write cycle,
# (An), -(An), (d8,An,Xn) take 2 clocks more, (An)+ 4 clocks more. The idle
# microcycles go after the read.
W('TASI1', NANO_IDLE, nxt=L['tasm1'])
W('TASI2', NANO_IDLE, nxt='TASI1')

# CLR to memory executes as MOVE D0,<ea> with a zero register (fx68k.sv).
# CLR.B/W -(An) and CLR (d8,An,Xn) take 2 clocks more than the MOVE.
W('CPDW', NANO_IDLE, nxt=L['rmmw1'])
W('CXW', NANO_IDLE, nxt=L['rmxw0'])
W('CXL', NANO_IDLE, nxt=L['rmxl0'])

# MOVES: 4 clocks after the extension word, and the non fetching address
# calculation. MVSK1-3 are MVS1 with 1-3 idle microcycles before PRO2.
W('MVSK1', nano(NANO_IDLE, EXTLATCH=1, IRSYNTH=1), nxt='MVI1')
W('MVSK2', nano(NANO_IDLE, EXTLATCH=1, IRSYNTH=1), nxt='MVI2')
W('MVSK3', nano(NANO_IDLE, EXTLATCH=1, IRSYNTH=1), nxt='MVI3')
# -(An): 2 idle microcycles to a register, 3 to memory (IRC bit 11, the direction)
W('MVSKD', nano(NANO_IDLE, EXTLATCH=1, IRSYNTH=1), cond=(0x00, 'MVD0'))
W('MVD0', NANO_IDLE, nxt='MVI1')
W('MVD3', NANO_IDLE, nxt='MVI2')
W('MVI3', NANO_IDLE, nxt='MVI2')
W('MVI2', NANO_IDLE, nxt='MVI1')
W('MVI1', NANO_IDLE, nxt='PRO2')

# MULU 40 clocks, MULS 40 or 42 (negative source). The 68000 shifts in one
# microcycle (mulm4) and adds or subtracts the multiplicand in another one (mulm3,
# mulm5) depending on the multiplier bits. MS1/MSN do both at once (ALU columns 6
# and 7 of the MUL row, 68010 only). mulm2 branches on the source sign of MULS.
CBC_MULS_NEG = 0x17
CBC_DIVU_ATL15 = 0x18
W('MULI', NANO_IDLE, nxt='MS1')
W('MULJ', NANO_IDLE, nxt='MULI')
W('MS1', nano(nano_of(L['mulm4']), ALU_COL=6), cond=(0x01, 0x20b))
W('MSN', nano(nano_of(L['mulm4']), ALU_COL=7), cond=(0x01, 0x20b))
W('MUL6', nano_of(L['mulm6']), micro=('copy', L['mulm6']))

# DIVU: the 68000 restores the remainder (dvume) and shifts (dvum5) in two
# microcycles when the trial subtraction fails, the 68010 takes the same time as
# when it succeeds. DV5R shifts the remainder saved in AT, and branches on its bit 15
# (instead of N, set by dvume on the 68000). 2 clocks more before the loop.
W('DV5R', nano(nano_of(L['dvum5']), ALU2ABD=0, ATLCTRL=ATL_ATL2ABL, ABLABD=1),
  cond=(CBC_DIVU_ATL15, 0x212))
W('DV6C', nano_of(L['dvum6']), micro=('copy', L['dvum6']))
W('DVI', nano(NANO_IDLE, TOIRC=1, TODBIN=1), nxt=L['dvum5'])
# DIVS: the same for the restore (dvs0f) and shift (dvs09) microcycles
W('DS9R', nano(nano_of(L['dvs09']), ALU2ABD=0, ATLCTRL=ATL_ATL2ABL, ABLABD=1),
  micro=('copy', L['dvs09']))
W('DSAC', nano_of(L['dvs0a']), micro=('copy', L['dvs0a']))
# DIVU overflow: 8 clocks (10 with the 68000 microcode). dvum3, which branches
# on the overflow, starts the prefetch at the end of the instruction (AOB <= PC,
# IR <= IRC), so that an overflow can dispatch in the next microcycle (DVUA:
# dvuma, it takes the prefetched word, and AU <= PC + 2 as dvum4). Without an
# overflow DVI takes the prefetched word (IRC and DBIN), and the exits of the division (dvumf,
# dvumd) only compute PC + 2.
W('DVUA', nano(nano_of(L['dvuma']), PCLDBL=1, REG2DBL=1, REG2DBH=1, PCH=1,
               AUCLKEN=0, AUCTRL=nget(nano_of(L['dvum4']), 'AUCTRL')), micro=('copy', L['dvuma']))
NREPL[L['dvumf']] = nano(nano_of(L['dvumf']), AOBCTRL=0)
NREPL[L['dvumd']] = nano(nano_of(L['dvumd']), AOBCTRL=0)
NREPL[L['dvum3']] = nano(nano_of(L['dvum3']), AOBCTRL=AOB_AB, AOBPC=1)
W('DM0C', nano(nano_of(L['dvum0']), TOIRC=0, TODBIN=0), micro=('copy', L['dvum0']))

# MOVEC with an invalid control register: 4 clocks more
W('MVCI2', NANO_IDLE, nxt='MVCI3')
W('MVCI3', NANO_IDLE, nxt=L['trac1'])

# ---------------------------------------------------------------------------
# Bank 1 patches of existing microwords (micro bits only, nano unchanged)
# ---------------------------------------------------------------------------

PATCH = [
    (L['trac1'], 'E_TRAC2'),
    (L['trap1'], 'E_TRAP2'),
    (L['dvur2'], 'E_DVUR3'),
    (L['itlx2'], 'E_ITLX3'),
    (L['trap4'], 'T5A'),
    (L['bser1'], 'B2'),
    (L['bclm2'], 'BCLI'),
    (L['stiw3'], 'STW4'),
    (L['strw1'], 'STR2'),
    (L['rorl1'], 'RL2F'),
    (L['roal1'], 'RA2F'),
]
PATCH_COND = [
    (L['trpv1'], 'E_TRPV3'),         # new base, slot 0 = E_TRPV3, slot 3 = E_TRPV2
    (L['dbcc3'], 'DBX'),             # slot 0 = DBX (expired), slot 3 = DB4C
    (L['bbci1'], 0x207),             # slot 1 = BNT (not taken), slot 3 = BTK
    (L['dbcc1'], 0x208),             # slot 1 = DC2 (condition false), slot 3 = DTK
    (L['dvumb'], 0x20c),             # slot 2 = DV5R (restore), slot 3 = DV6C
    (L['dvum3'], 0x20d),             # slot 2 = DVI (no overflow), slot 3 = DVUA
    (L['dvs0d'], 0x20e),             # slot 2 = DS9R (restore), slot 3 = DSAC
]

# Bank 1 patches of existing nanowords: (microaddress, field changes). The
# nanoword may be shared by other microwords, all of them get the change.
NPATCH = []

# ---------------------------------------------------------------------------
# Allocation
# ---------------------------------------------------------------------------

byname = {}
for w in words:
    assert w['name'] not in byname, w['name']
    byname[w['name']] = w

used = set()
for n, a in FIXED.items():
    assert free_addr(a), 'fixed %s %03x not free' % (n, a)
    assert a not in used
    used.add(a)
    byname[n]['addr'] = a

pool = [a for a in range(1024) if free_addr(a) and a not in used]
# keep whole 4-groups touched by fixed words out of the pool to keep the
# nanomap simple: other words go to fresh groups in order
fixed_groups = set(a >> 2 for a in used)
pool = [a for a in pool if (a >> 2) not in fixed_groups]
for w in words:
    if 'addr' not in w:
        w['addr'] = pool.pop(0)
        used.add(w['addr'])


def addr_of(t):
    if isinstance(t, int):
        return t
    return byname[t]['addr']


# conditional target checks
def check_cond(base_name, slots):
    base = addr_of(base_name)
    assert (base & 0xc0) == 0, base_name
    for s, t in slots.items():
        assert addr_of(t) == base | (s << 6), '%s slot %d' % (t, s)
    return base

check_cond('MVCILL', {0: 'MVCILL', 3: 'PRO2'})
check_cond('E_TRPV3', {0: 'E_TRPV3', 3: 'E_TRPV2'})
check_cond('LCONT', {0: 'LCONT', 1: 'LEXP', 3: 'LCC'})
check_cond('RTE4', {0: 'RTE4', 1: 'R8A', 3: 'FE1'})
check_cond('R8G', {0: 'R8G', 3: 'FE1B'})
check_cond('DBX', {0: 'DBX', 3: 'DB4C'})
check_cond(0x207, {1: 'BNT', 3: 'BTK'})
check_cond(0x208, {1: 'DC2', 3: 'DTK'})
check_cond('NX2', {0: 'NX2', 3: 'NX5'})
check_cond('MULI', {0: 'MULI', 3: 'MULJ'})
check_cond(0x20b, {1: 'MUL6', 3: 'MSN'})
check_cond(0x20c, {2: 'DV5R', 3: 'DV6C'})
check_cond(0x20d, {2: 'DVI', 3: 'DVUA'})
check_cond(0x20e, {2: 'DS9R', 3: 'DSAC'})
check_cond('MVD0', {0: 'MVD0', 3: 'MVD3'})

# microwords
micro = list(micro68) + list(micro68)
for w in words:
    a = w['addr']
    if isinstance(w['micro'], int):
        mw = w['micro']
    elif w['micro'] is not None:
        kind = w['micro'][0]
        if kind == 'rebase':
            mw = mw_rebase(micro68[w['micro'][1]], addr_of(w['micro'][2]))
        elif kind == 'copy':
            mw = micro68[w['micro'][1]]
        elif kind == 'copy_noir':
            mw = micro68[w['micro'][1]] & ~1
        else:
            org, tgt = w['micro'][1], w['micro'][2]
            mw = micro68[org]
            if tgt is not None:
                mw = mw_retarget(mw, addr_of(tgt))
    elif w['cond'] is not None:
        mw = mw_cond(w['cond'][0], addr_of(w['cond'][1]), w['ir'], w['fc'])
    else:
        mw = mw_jmp(addr_of(w['nxt']), w['ir'], w['fc'], w['grp0'])
    w['mw'] = mw
    micro[1024 + a] = mw

for a, t in PATCH:
    micro[1024 + a] = mw_retarget(micro68[a], addr_of(t))
for a, t in PATCH_COND:
    micro[1024 + a] = mw_rebase(micro68[a], addr_of(t))
# conditional microwords with a new condition
noir = lambda ua: micro68[ua] & ~1
MPATCH = [
    (L['mulm2'], mw_cond(CBC_MULS_NEG, 0x20a)),     # slot 0 = MULI, slot 3 = MULJ (MULS, negative)
    # DIVU: IR <= IRC and the prefetch in dvum3, not at the end
    (L['dvum3'], mw_rebase(micro68[L['dvum3']], 0x20d) | 1 | (2 << 15)),
    (L['dvumf'], mw_retarget(noir(L['dvumf']), addr_of('DM0C')) & ~(3 << 15)),
    (L['dvumd'], mw_retarget(noir(L['dvumd']), addr_of('DM0C')) & ~(3 << 15)),
]
for a, mw in MPATCH:
    micro[1024 + a] = mw

# nanowords: one nano group per used micro group, identical groups shared
groups = {}
for w in words:
    groups.setdefault(w['addr'] >> 2, [0, 0, 0, 0])[w['addr'] & 3] = w['nano']
nano_rows = [n for n in nano68]
nmap = dict(nmap68)
seen = {}
for g in sorted(groups):
    key = tuple(groups[g])
    if key not in seen:
        seen[key] = len(nano_rows) // 4
        nano_rows.extend(key)
    nmap[g] = seen[key]
# 68000 groups with bank 1 nanoword replacements: own rows, selected in 68010
# mode only (fx68k.sv "68010 remap")
bank0 = list(nano68) + [0] * (len(nano_rows) - len(nano68))
remap = {}
for g in sorted(set(ua >> 2 for ua in NREPL)):
    assert g in nmap68, '%03x is not a 68000 microaddress' % (g * 4)
    org = [nano68[nmap68[g] * 4 + i] for i in range(4)]
    mod = [NREPL.get(g * 4 + i, org[i]) for i in range(4)]
    remap[g] = len(nano_rows) // 4
    nano_rows.extend(mod)
    bank0.extend([0] * 4)
assert len(nano_rows) <= NADDR_LIMIT, len(nano_rows)
assert max(list(nmap.values()) + list(remap.values())) < NADDR_LIMIT // 4

# bank 1 nanoword patches
users = {}
for ua in range(1024):
    if (ua >> 2) in nmap68 and micro68[ua] != 0:
        users.setdefault(nmap68[ua >> 2] * 4 + (ua & 3), []).append(ua)
npatch_log = []
for ua, mods in NPATCH:
    row = nmap68[ua >> 2] * 4 + (ua & 3)
    nano_rows[row] = nano(nano_rows[row], **mods)
    npatch_log.append((ua, row, users.get(row, [])))
bank0 = bank0 + [0] * (NADDR_LIMIT - len(bank0))
bank1 = nano_rows + [0] * (NADDR_LIMIT - len(nano_rows))

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

# ROM images use CRLF like the original ones
with open(os.path.join(FX, 'microrom.mem'), 'wb') as f:
    for mw in micro:
        f.write((format(mw, '0%db' % UROM_WIDTH) + '\r\n').encode())
with open(os.path.join(FX, 'nanorom.mem'), 'wb') as f:
    for nw in bank0 + bank1:
        assert nw >> NANO_WIDTH == 0
        f.write((format(nw, '0%db' % NANO_WIDTH) + '\r\n').encode())

eol = '\r\n'


def section(text, name, body):
    """Replace the lines between the "// <name> begin" and "// <name> end" markers."""
    m = re.search(r'// %s begin\r?\n(.*?)// %s end\r?\n' % (name, name), text, re.S)
    assert m, name
    return text[:m.start()] + '// %s begin%s%s// %s end%s' % (name, eol, body, name, eol) + text[m.end():]


new_cases = ''.join("'h%02X: orgBase = 8'h%X ;%s" % (g, nmap[g], eol) for g in sorted(groups))
sv_new = section(sv, '68010 nanomap', new_cases)
remap_cases = ''.join("'h%02X: orgBase = 8'h%X ;%s" % (g, remap[g], eol) for g in sorted(remap))
sv_new = section(sv_new, '68010 remap', remap_cases)
sv_new = re.sub(r'localparam NANO_DEPTH = \d+;', 'localparam NANO_DEPTH = %d;' % (2 * NADDR_LIMIT), sv_new)
if sv_new != sv:
    open(svfile, 'wb').write(sv_new.encode())

# entry points for uaddrDecode
for n in ('RTE1', 'RTD1', 'MVC1', 'MVS1', 'CCRW1', 'CCMW1', 'LDB1', 'BK1', 'USPI', 'USPO', 'MLPD',
          'RL1S', 'RA1S', 'NAI', 'NAIP', 'NAID', 'NAD', 'NAX', 'NAW', 'NAL', 'TASI1', 'TASI2',
          'CPDW', 'CXW', 'CXL', 'MVSK1', 'MVSK2', 'MVSK3', 'MVSKD'):
    m = re.search(r"localparam %s_NMA = 'h([0-9A-Fa-f]+);" % n, sv_new)
    assert m and int(m.group(1), 16) == addr_of(n), 'fx68k.sv %s_NMA must be %03x' % (n, addr_of(n))

with open(os.path.join(HERE, 'ucode010.lst'), 'w') as f:
    f.write('; generated by gen_ucode010.py\n')
    f.write('; nanorom rows: %d (68000: %d)\n\n' % (len(nano_rows), len(nano68)))
    for w in words:
        f.write('%03x %-8s micro=%05x nano=%022x\n' % (w['addr'], w['name'], w['mw'], w['nano']))
    f.write('\n; bank 1 patches\n')
    for a, t in PATCH + PATCH_COND:
        f.write('%03x %-8s -> %s (%03x)\n' % (a, names[a], names[t] if isinstance(t, int) else t, addr_of(t)))
    f.write('\n; bank 1 nanoword replacements (own rows)\n')
    for ua in sorted(NREPL):
        f.write('%03x %-8s nano=%022x\n' % (ua, names[ua], NREPL[ua]))
    f.write('\n; bank 1 nanoword patches\n')
    for ua, row, us in npatch_log:
        f.write('%03x %-8s row %03x, used by %s\n' % (ua, names[ua], row, ' '.join('%03x %s' % (u, names[u]) for u in us)))

print('microrom: %d words, nanorom: %d rows, new words: %d' % (len(micro), len(nano_rows), len(words)))
