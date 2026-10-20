#!/usr/bin/env python3
#
# Generate tests/timing.s: instruction and exception execution times, checked
# against the M68000 User's Manual, Section 8 (68000) and Section 9 (68010),
# with the corrections listed in timing68k.py.
#
# Every form runs once between two reads of the TB clock counter (FF001A),
# MOVEA so that the CCR is not changed:
#
#     movea.w CLK,a4        mark 1
#     <instruction>
#     movea.w CLK,a5        mark 2 (or the landing routine of an exception)
#
# The clock difference minus the time of a mark (measured at the start) is the
# execution time of the instruction, from its first clock to the first clock
# of the next instruction, including the stacking and vector fetch of an
# exception. a4-a7 are reserved, d0-d7/a0-a3 are loaded for each form.
#
# The expected times are computed from the assembled program with
# timing68k.decode (two passes: the program is assembled once to find the
# address of every form) and stored in a table, one word for each CPU. A
# zero is not checked. The program checks itself: status = failed checks,
# check 1 of test <form number + 1>. The measured times are stored at TIMES.
#
#   gen_timing.py                       write tests/timing.s
#   gen_timing.py -r <dump> <000|010>   list the forms whose time differs

import os, re, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import timing68k as tm

VASM = os.environ.get('VASM', 'vasmm68k_mot')

XTAB = 0x1000           # address of every form, long words
EXPT = 0x3000           # expected times: 68000, 68010
TIMES = 0xc000          # measured times
MAXF = 2048
CODE = 0x20000
BUF = 0x10000           # a0 / absolute long data area
ABSW = 0x6000           # absolute short data area

# registers: d0-d7, a0-a3
REGS = [0x00000003, 0x12345678, 0x00000004, 0x00000005, 0x87654321, 0x0000ffff, 0x00000020, 0x00000000,
        BUF + 0x100, BUF + 0x300, ABSW + 0x100, BUF + 0x500]

# effective addresses
EA = {
    tm.DN: 'd1', tm.AN: 'a1', tm.AI: '(a0)', tm.AIP: '(a0)+', tm.AID: '-(a0)', tm.AD16: '8(a0)',
    tm.AD8: '4(a0,d2.w)', tm.AW: '($%x).w' % ABSW, tm.AL: '($%x).l' % (BUF + 0x800),
    # the immediate word of the MOVE #$2700,SR before mark 1
    tm.PC16: '*-8(pc)', tm.PC8: '*-12(pc,d2.w)',
}
IMM = {1: '#$5a', 2: '#$1234', 4: '#$12345678'}
ALL = [tm.DN, tm.AN, tm.AI, tm.AIP, tm.AID, tm.AD16, tm.AD8, tm.AW, tm.AL, tm.PC16, tm.PC8, tm.IMM]
MEMALT = [tm.AI, tm.AIP, tm.AID, tm.AD16, tm.AD8, tm.AW, tm.AL]
DATALT = [tm.DN] + MEMALT
DATA = [m for m in ALL if m != tm.AN]
CONTROL = [tm.AI, tm.AD16, tm.AD8, tm.AW, tm.AL, tm.PC16, tm.PC8]


def ea(m, size=2):
    return IMM[size] if m == tm.IMM else EA[m]


class F:
    """A form: the instruction (several lines allowed), how it ends and the setup."""
    def __init__(self, ins, end='next', ccr=0, regs=None, pre='', only010=False, exp=None,
                 user=False, sr=None):
        self.ins = ins
        self.end = end          # next: mark 2 follows, land: the exception / jump landing routine
        self.ccr = ccr
        self.regs = dict(regs or {})
        self.pre = pre          # code before mark 1 (after the registers are loaded)
        self.only010 = only010
        self.exp = exp          # (68000, 68010) instead of timing68k
        self.user = user        # user mode at mark 1
        self.sr = sr
        self.fill = ',sr' in ins or 'chk' in ins or exp is not None


forms = []


def add(*a, **k):
    forms.append(F(*a, **k))

SZ = {1: 'b', 2: 'w', 4: 'l'}

# --- MOVE, MOVEA, MOVEQ ----------------------------------------------------
for s in (1, 2, 4):
    for sm in ALL:
        if s == 1 and sm == tm.AN:
            continue
        for dm in tm.MOVE_DST:
            if s == 1 and dm == tm.AN:
                continue
            nm = 'movea' if dm == tm.AN else 'move'
            add('%s.%s %s,%s' % (nm, SZ[s], ea(sm, s), EA[dm]))
add('moveq #-1,d1')

# --- arithmetic and logic ---------------------------------------------------
for op in ('add', 'sub', 'and', 'or', 'cmp'):
    for s in (1, 2, 4):
        for sm in ALL:
            if sm == tm.AN and (s == 1 or op in ('and', 'or')):
                continue
            add('%s.%s %s,d4' % (op, SZ[s], ea(sm, s)))
        if op != 'cmp':
            for dm in MEMALT:
                add('%s.%s d4,%s' % (op, SZ[s], EA[dm]))
for s in (1, 2, 4):
    for dm in DATALT:
        add('eor.%s d4,%s' % (SZ[s], EA[dm]))
for op in ('adda', 'suba', 'cmpa'):
    for s in (2, 4):
        for sm in ALL:
            add('%s.%s %s,a2' % (op, SZ[s], ea(sm, s)))
for op in ('ori', 'andi', 'subi', 'addi', 'eori', 'cmpi'):
    for s in (1, 2, 4):
        for dm in DATALT:
            add('%s.%s %s,%s' % (op, SZ[s], IMM[s], EA[dm]))
for op in ('ori', 'andi', 'eori'):
    add('%s.b #$00,ccr' % op)
    add('%s.w #$%s,sr' % (op, '2700' if op == 'andi' else '0700'), sr=0x2700)
for op in ('addq', 'subq'):
    for s in (1, 2, 4):
        for dm in [tm.DN, tm.AN] + MEMALT:
            if s == 1 and dm == tm.AN:
                continue
            add('%s.%s #3,%s' % (op, SZ[s], EA[dm]))
for op in ('addx', 'subx'):
    for s in (1, 2, 4):
        add('%s.%s d1,d4' % (op, SZ[s]))
        add('%s.%s -(a0),-(a1)' % (op, SZ[s]))
for op in ('abcd', 'sbcd'):
    add('%s d1,d4' % op)
    add('%s -(a0),-(a1)' % op)
for s in (1, 2, 4):
    add('cmpm.%s (a0)+,(a1)+' % SZ[s])
for op in ('neg', 'negx', 'not', 'clr', 'tst'):
    for s in (1, 2, 4):
        for dm in DATALT:
            add('%s.%s %s' % (op, SZ[s], EA[dm]))
for dm in DATALT:
    add('nbcd %s' % EA[dm])
    add('tas %s' % EA[dm])
add('ext.w d1')
add('ext.l d1')
add('swap d1')
add('exg d1,d4')
add('exg a1,a2')
add('exg d1,a2')

def memop(op, dst, sm, src=0x2700):
    # MUL / DIV with the memory operand $2700 written by fill
    f = {'mulu': (lambda: tm.mulu_000(src), lambda: 40), 'muls': (lambda: tm.muls_000(src), lambda: 40),
         'divu': (lambda: tm.divu_000(dst, src), lambda: tm.divu_010(dst, src)),
         'divs': (lambda: tm.divs_000(dst, src), lambda: tm.divs_010(dst, src))}[op]
    return (f[0]() + tm.ea_time(sm, 2), f[1]() + tm.ea_time(sm, 2))

# --- MUL / DIV -------------------------------------------------------------
for op in ('mulu', 'muls'):
    for v in (0x0000, 0x0001, 0x5555, 0xaaaa, 0x7fff, 0x8000, 0xffff, 0x00ff):
        add('%s.w d5,d6' % op, regs={5: v, 6: 0x1234})
    add('%s.w #$5a5a,d6' % op, regs={6: 0x1234})
    for sm in DATA:
        if sm not in (tm.DN, tm.IMM):
            add('%s.w %s,d6' % (op, ea(sm)), regs={6: 0x1234}, exp=memop(op, 0x1234, sm))
DIVS = [(0x00012345, 0x0002), (0x00000000, 0x1234), (0x7fffffff, 0x7fff), (0x0000ffff, 0x0001),
        (0x12345678, 0x1234), (0x00100000, 0x0010), (0xfffffff0, 0x0004), (0x00001000, 0xfff0),
        (0xffffff00, 0xfff0), (0x80000000, 0x0001), (0x00000001, 0xffff), (0x3fffffff, 0x8000)]
for op in ('divu', 'divs'):
    for dd, dv in DIVS:
        add('%s.w d5,d6' % op, regs={5: dv, 6: dd})
    add('%s.w #$1234,d6' % op, regs={6: 0x00123456})
    for sm in DATA:
        if sm not in (tm.DN, tm.IMM):
            add('%s.w %s,d6' % (op, ea(sm)), regs={6: 0x00123456}, exp=memop(op, 0x00123456, sm))
    # divide by zero
    add('%s.w d5,d6' % op, regs={5: 0, 6: 0x1234}, end='land', exp=(38, 42))
    add('%s.w #0,d6' % op, regs={6: 0x1234}, end='land', exp=(42, 46))

# --- shifts and rotates ----------------------------------------------------
for op in ('asl', 'asr', 'lsl', 'lsr', 'rol', 'ror', 'roxl', 'roxr'):
    for s in (1, 2, 4):
        add('%s.%s #1,d1' % (op, SZ[s]))
        add('%s.%s #8,d1' % (op, SZ[s]))
        for n in (0, 5, 33):
            add('%s.%s d3,d1' % (op, SZ[s]), regs={3: n})
    for dm in MEMALT:
        add('%s.w %s' % (op, EA[dm]))

# --- bit operations -------------------------------------------------------
for op in ('btst', 'bchg', 'bclr', 'bset'):
    add('%s d2,d4' % op)                     # bit 4
    add('%s d1,d4' % op)                     # bit 24
    add('%s #4,d4' % op)
    add('%s #20,d4' % op)
    for dm in MEMALT + ([tm.PC16, tm.PC8] if op == 'btst' else []):
        add('%s d2,%s' % (op, EA[dm]))
        add('%s #3,%s' % (op, EA[dm]))
    if op == 'btst':
        add('btst d2,#$12')

# --- MOVEP, MOVEM, LEA, PEA, CHK, Scc -----------------------------------------
add('movep.w d1,8(a0)')
add('movep.l d1,8(a0)')
add('movep.w 8(a0),d1')
add('movep.l 8(a0),d1')
for s in ('w', 'l'):
    for lst in ('d1', 'd1-d3', 'd1-d4/a1-a3'):
        for dm in (tm.AI, tm.AID, tm.AD16, tm.AD8, tm.AW, tm.AL):
            add('movem.%s %s,%s' % (s, lst, EA[dm]))
        for sm in (tm.AI, tm.AIP, tm.AD16, tm.AD8, tm.AW, tm.AL, tm.PC16, tm.PC8):
            add('movem.%s %s,%s' % (s, EA[sm], lst))
for sm in CONTROL:
    add('lea %s,a2' % EA[sm])
    add('pea %s' % EA[sm])
for sm in DATA:
    add('chk.w %s,d7' % ea(sm))               # d7 = 0: no trap
add('chk.w d5,d4', end='land')               # d4.w > bound: trap
add('chk.w d5,d4', regs={4: 0x8000}, end='land')  # d4.w negative: trap
add('chk.w d4,d1', regs={4: 0x100}, end='land')   # d1.w > bound: trap
add('chk.w #$100,d1', end='land')
for cc, ccr in (('t', 0), ('f', 0), ('eq', 4), ('eq', 0)):
    for dm in DATALT:
        add('s%s %s' % (cc, EA[dm]), ccr=ccr)

# --- status register, USP ---------------------------------------------------
for sm in DATA:
    add('move.w %s,ccr' % ea(sm))
    add('move.w %s,sr' % ('#$2700' if sm == tm.IMM else ea(sm)), regs={1: 0x2700})
for dm in DATALT:
    add('move.w sr,%s' % EA[dm])
    add('move.w ccr,%s' % EA[dm], only010=True)
add('move.l a1,usp')
add('move.l usp,a1')

# --- branches, jumps, returns -----------------------------------------------
add('bra.s .y\n\tnop')
add('bra.w .y\n\tnop')
add('bsr.s .y\n\tnop')
add('bsr.w .y\n\tnop')
add('beq.s .y\n\tnop', ccr=4)
add('beq.w .y\n\tnop', ccr=4)
add('.x:\tbeq.s .x', ccr=0)
add('.x:\tbeq.w .x', ccr=0)
add('dbf d0,.y\n\tnop')                      # d0 = 3: branch
add('.x:\tdbf d0,.x', regs={0: 0})           # count expired
add('.x:\tdbeq d0,.x', ccr=4)                # condition true
for op in ('jmp', 'jsr'):
    add('%s (a3)' % op, pre='\tlea\t.y(pc),a3')
    add('%s 0(a3)' % op, pre='\tlea\t.y(pc),a3')
    add('%s 0(a3,d7.w)' % op, pre='\tlea\t.y(pc),a3')
    add('%s (land).w' % op, end='land')
    add('%s (.y).l' % op)
    add('%s .y(pc)' % op)
    add('%s .y(pc,d7.w)' % op)
add('rts', pre='\tpea\t.y(pc)')
add('rtr', pre='\tpea\t.y(pc)\n\tmove.w\t#$0000,-(sp)')
add('rtd #8', pre='\tpea\t.y(pc)', only010=True)
# RTE: format 0 frame on the 68010
RTEPRE = '\ttst.w\tis010\n\tbeq.s\t.p\n\tclr.w\t-(sp)\n.p:\tpea\t.y(pc)\n\tmove.w\t#$2700,-(sp)'
add('rte', pre=RTEPRE)
# RTE format errors (68010)
add('rte', pre='\tmove.w\t#$f000,-(sp)\n\tpea\t.y(pc)\n\tmove.w\t#$2700,-(sp)', only010=True,
    end='land', exp=(0, 50))
add('rte', pre='\tlea\t-58(sp),sp\n\tmove.w\t#$2700,(sp)\n\tlea\t.y(pc),a3\n\tmove.l\ta3,2(sp)\n'
    '\tmove.w\t#$8008,6(sp)\n\tmove.w\t#$0400,26(sp)', only010=True, end='land', exp=(0, 70))
add('link a2,#-8')
add('unlk a2', regs={10: BUF + 0x900})
add('nop')

# --- 68010 control instructions ---------------------------------------------
add('movec vbr,d1', only010=True)
add('movec d7,vbr', only010=True)            # d7 = 0
add('movec sfc,d1', only010=True)
add('movec d1,dfc', only010=True)
add('movec usp,d1', only010=True)
add('dc.w $4e7a,$1003', only010=True, end='land', exp=(0, 46))        # illegal control register
for s in (1, 2, 4):
    for dm in MEMALT:
        add('moves.%s %s,d1' % (SZ[s], EA[dm]), only010=True)
        add('moves.%s d1,%s' % (SZ[s], EA[dm]), only010=True)

# --- exceptions ---------------------------------------------------------------
add('trap #1', end='land')
add('trapv', ccr=2, end='land')
add('trapv', ccr=0)
add('illegal', end='land', exp=(34, 38))
add('dc.w $a000', end='land', exp=(34, 38))
add('dc.w $f000', end='land', exp=(34, 38))
add('move.w #$2700,sr', user=True, end='land', exp=(34, 38))
add('bkpt #0', end='land', exp=(34, 0))
# Address and bus error. The manual gives the exception processing only (50 on
# the 68000, 126 on the 68010), the times here include the instruction up to the
# fault (the 68000 times of the original fx68k, BERR as the testbench asserts it),
# the 68010 takes the 76 clocks of the 19 more frame words longer.
add('move.w (a3),d1', regs={11: BUF + 1}, end='land', exp=(58, 58 + 76))
add('move.w d1,(a3)', regs={11: BUF + 1}, end='land', exp=(58, 58 + 76))
add('jmp (a3)', regs={11: BUF + 1}, end='land', exp=(58, 58 + 76))
add('move.w (a3),d1', regs={11: 0xfe0000}, end='land', exp=(61, 61 + 76))
add('move.w d1,(a3)', regs={11: 0xfe0000}, end='land', exp=(61, 61 + 76))

assert len(forms) <= MAXF, len(forms)

# ---------------------------------------------------------------------------

HEAD = """; generated by gen_timing.py
FAILCNT		equ	$8000
NCHECKS		equ	$8004
FAILPTR		equ	$8008
FAILLOG		equ	$8100
TIMES		equ	$%x
XTAB		equ	$%x
EXPT		equ	$%x
tid		equ	$5000
cnum		equ	$5002
is010		equ	$5004
markt		equ	$5006
savesp		equ	$5008
cont		equ	$500c
BUF		equ	$%x
END		equ	$ff0000
CLK		equ	$ff001a
STACK		equ	$f0000
USTACK		equ	$e0000

	org	0
	dc.l	STACK
	dc.l	start
	dcb.l	254,land

	org	$400
detect:	clr.w	is010			; illegal instruction: 68000
	addq.l	#4,2(sp)		; skip the MOVEC
	rte

check:	addq.l	#1,NCHECKS
	addq.w	#1,cnum
	cmp.l	d5,d6
	beq.s	.ok
	addq.l	#1,FAILCNT
	movea.l	FAILPTR,a6
	move.w	tid,(a6)+
	move.w	cnum,(a6)+
	move.l	d5,(a6)+
	move.l	d6,(a6)+
	move.l	a6,FAILPTR
.ok:	rts

; landing of exceptions and absolute short jumps: mark 2, back to the form
	org	$600
land:	movea.w	CLK,a5
	movea.l	savesp,sp
	move.l	cont,-(sp)
	rts

; time of the form in d6 (mark 2 - mark 1 - mark time), d5 = expected
result:	move.l	a5,d6
	sub.l	a4,d6
	andi.l	#$ffff,d6
	sub.w	markt,d6
	move.w	tid,d5
	subq.w	#1,d5
	add.w	d5,d5
	lea	TIMES,a6
	move.w	d6,(a6,d5.w)
	add.w	d5,d5
	lea	EXPT,a6
	tst.w	is010
	beq.s	.c
	addq.w	#2,d5
.c:	move.w	(a6,d5.w),d5
	andi.l	#$ffff,d5
	beq.s	.n
	bsr	check
.n:	rts

; data areas: words $2700 (a valid SR for MOVE to SR)
fill:	lea	BUF,a0
	move.w	#$a00/4-1,d0
.f:	move.l	#$27002700,(a0)+
	dbf	d0,.f
	lea	$%x,a0
	move.w	#$400/4-1,d0
.g:	move.l	#$27002700,(a0)+
	dbf	d0,.g
	rts

	org	$%x
start:	clr.l	FAILCNT
	clr.l	NCHECKS
	move.l	#FAILLOG,FAILPTR
	move.w	#1,is010
	move.l	#detect,$10
	dc.w	$4e7a,$0801		; movec vbr,d0: illegal on a 68000
	move.l	#land,$10
	move.l	#USTACK,a0
	move.l	a0,usp
	jsr	fill
; mark time
	movea.w	CLK,a4
	movea.w	CLK,a5
	move.l	a5,d5
	sub.l	a4,d5
	move.w	d5,markt
""" % (TIMES, XTAB, EXPT, BUF, ABSW, CODE)

REGTAB = 'regtab'


def gen(expt):
    out = [HEAD]
    tabs = []
    for k, f in enumerate(forms):
        r = list(REGS)
        for i, v in f.regs.items():
            r[i] = v
        tabs.append('rg%d:\tdc.l\t%s' % (k, ','.join('$%x' % (x & 0xffffffff) for x in r)))
        loc = lambda t: re.sub(r'\.([xyp])\b', lambda m: {'x': 'q', 'y': 'y', 'p': 'p'}[m.group(1)] + str(k), t)
        ins, pre = loc(f.ins), loc(f.pre)
        lines = ['; %d: %s' % (k, f.ins.replace('\n\t', ' / ')),
                 'f%d:\tmove.w\t#%d,tid\n\tclr.w\tcnum' % (k, k + 1)]
        if f.only010:
            lines.append('\ttst.w\tis010\n\tbeq\ts%d' % k)
        if f.fill:
            lines.append('\tjsr\tfill')
        lines.append('\tmove.l\tsp,savesp\n\tmove.l\t#w%d,cont\n\tmovem.l\trg%d,d0-d7/a0-a3' % (k, k))
        if pre:
            lines.append(pre)
        sr = f.sr if f.sr is not None else (0x0000 if f.user else 0x2700)
        lines.append('\tmove.w\t#$%04x,sr' % (sr | f.ccr))
        lines.append('\tmovea.w\tCLK,a4\nx%d:\n\t%s' % (k, ins))
        if f.end == 'next':
            lines.append('y%d:\tmovea.w\tCLK,a5\n\tmovea.l\tsavesp,sp' % k)
        else:
            lines.append('y%d:' % k)
        lines.append('w%d:\tjsr\tresult\ns%d:' % (k, k))
        out.append('\n'.join(lines))
    out.append('\n\tmove.l\tFAILCNT,d0\n\tmove.w\td0,END\n\tbra.s\t*\n')
    out.append('\teven\n' + '\n'.join(tabs))
    out.append('\n\torg\tXTAB\n' + '\n'.join('\tdc.l\tx%d' % k for k in range(len(forms))))
    out.append('\n\torg\tEXPT\n' + '\n'.join('\tdc.w\t%d,%d' % e for e in expt))
    return '\n'.join(out) + '\n'


def assemble(src):
    with tempfile.TemporaryDirectory() as d:
        s, b = os.path.join(d, 't.s'), os.path.join(d, 't.bin')
        open(s, 'w').write(src)
        subprocess.run([VASM, '-quiet', '-Fbin', '-m68010', '-no-opt', '-o', b, s], check=True)
        return open(b, 'rb').read()


def expected(img):
    words = [(img[i] << 8) | img[i + 1] for i in range(0, len(img) - 1, 2)]
    def mem(a):
        i = (a & 0xffffff) >> 1
        return words[i] if i < len(words) else 0
    res = []
    for k, f in enumerate(forms):
        pc = (mem(XTAB + 4 * k) << 16) | mem(XTAB + 4 * k + 2)
        r = list(REGS)
        for i, v in f.regs.items():
            r[i] = v
        e = []
        for cpu in ('000', '010'):
            if f.exp is not None:
                e.append(f.exp[cpu == '010'])
                continue
            if f.only010 and cpu == '000':
                e.append(0)
                continue
            sr = (f.sr if f.sr is not None else 0x2700) | f.ccr
            # next PC: falls through unless the form ends somewhere else
            d = tm.decode(cpu, mem, pc, sr, r[:8], pc + 0x100, 0)
            if d is not None and not ('.y' in f.ins or f.end == 'land'):
                d = tm.decode(cpu, mem, pc, sr, r[:8], pc + 2 * d.words, 0)
            e.append(d.time if d is not None and d.time is not None else 0)
        res.append(tuple(e))
    return res


def report(dump, cpu):
    img = assemble(gen([(0, 0)] * len(forms)))
    exp = expected(img)
    w = [int(x, 16) for l in open(dump) if not l.startswith('//') for x in l.split()]
    bad = 0
    for k, f in enumerate(forms):
        t = w[(TIMES - 0x8000) // 2 + k]
        e = exp[k][cpu == '010']
        if f.only010 and cpu == '000':
            continue
        if e != t:
            bad += 1
            print('%4d  %-40s exp %3s got %3d' % (k + 1, f.ins.replace('\n\t', ' / '), e or '-', t))
    print('%d forms, %d differ' % (len(forms), bad))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '-r':
        report(sys.argv[2], sys.argv[3])
        sys.exit(0)
    img = assemble(gen([(0, 0)] * len(forms)))
    src = gen(expected(img))
    open(os.path.join(here, 'tests', 'timing.s'), 'w').write(src)
    print('tests/timing.s: %d forms' % len(forms))
