#!/usr/bin/env python3
# Generate tests/random.s: a deterministic random stream of 68000 instructions
# that never takes an exception. Its bus cycles must be identical on the
# original fx68k, the new fx68k in 68000 mode and in 68010 mode.
#
# Registers: D0-D5 data, D6/D7 small even index values (read only),
# A0-A2 word/long pointers, A3/A4 byte pointers, A5 address destination,
# A6 LINK frame, A7 stack. Pointers are reloaded after every block.
#
# Results: registers and SR after every block at $9000, the data buffer
# $C000-$EFFF and the absolute short buffer $6000-$7FFF (copied to $F000)
# are inside the dumped area $8000-$FFFF.

import random, os, sys

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 68010
nblocks = int(sys.argv[2]) if len(sys.argv) > 2 else 100
blocklen = 30
rnd = random.Random(seed)

SZ = ['b', 'w', 'l']
DREG = ['d0', 'd1', 'd2', 'd3', 'd4', 'd5']
SRCD = DREG + ['d6', 'd7']
PTR = {'b': ['a0', 'a1', 'a2', 'a3', 'a4'], 'w': ['a0', 'a1', 'a2'], 'l': ['a0', 'a1', 'a2']}
INC = {'b': ['a3', 'a4'], 'w': ['a0', 'a1', 'a2'], 'l': ['a0', 'a1', 'a2']}
CC = ['t', 'f', 'hi', 'ls', 'cc', 'cs', 'ne', 'eq', 'vc', 'vs', 'pl', 'mi', 'ge', 'lt', 'gt', 'le']

label_n = [0]


def lbl():
    label_n[0] += 1
    return '.l%d' % label_n[0]


def imm(sz):
    v = rnd.choice([0, 1, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff, 0x7fffffff, 0x80000000,
                    rnd.getrandbits(32)])
    return '#$%x' % (v & {'b': 0xff, 'w': 0xffff, 'l': 0xffffffff}[sz])


def even(v, sz):
    return v & ~1 if sz != 'b' else v


def mem(sz, alterable=True, allow_pc=True):
    kinds = ['ind', 'postinc', 'predec', 'd16', 'd8x', 'absw', 'absl']
    if not alterable and allow_pc:
        kinds += ['pcd16', 'pcd8x']
    k = rnd.choice(kinds)
    if k == 'ind':
        return '(%s)' % rnd.choice(PTR[sz])
    if k == 'postinc':
        return '(%s)+' % rnd.choice(INC[sz])
    if k == 'predec':
        return '-(%s)' % rnd.choice(INC[sz])
    if k == 'd16':
        return '%d(%s)' % (even(rnd.randint(-0x300, 0x300), sz), rnd.choice(PTR[sz]))
    if k == 'd8x':
        return '%d(%s,%s.%s)' % (even(rnd.randint(-120, 120), sz), rnd.choice(PTR[sz]),
                                 rnd.choice(['d6', 'd7']), rnd.choice(['w', 'l']))
    if k == 'absw':
        return '($%x).w' % even(rnd.randint(0x6000, 0x7ff8), sz)
    if k == 'absl':
        return '($%x).l' % even(rnd.randint(0xc000, 0xeff8), sz)
    if k == 'pcd16':
        return 'pcdata+%d(pc)' % even(rnd.randint(0, 200), sz)
    if k == 'pcd8x':
        # data island emitted just before the instruction (8 bit displacement)
        return '@ISLAND+%d(pc,%s.w)' % (rnd.choice([4, 6, 8]), rnd.choice(['d6', 'd7']))


def src(sz, allow_an=True):
    c = rnd.random()
    if c < 0.3:
        return rnd.choice(SRCD)
    if c < 0.4 and allow_an and sz != 'b':
        return rnd.choice(['a0', 'a1', 'a2', 'a5'])
    if c < 0.55:
        return imm(sz)
    return mem(sz, alterable=False)


def dst(sz):
    return rnd.choice(DREG) if rnd.random() < 0.4 else mem(sz)


def gen():
    sz = rnd.choice(SZ)
    t = rnd.randint(0, 46)
    d = rnd.choice(DREG)
    if t == 0:
        return '%s.%s %s,%s' % (rnd.choice(['add', 'sub', 'cmp']), sz, src(sz), d)
    if t == 1:
        return '%s.%s %s,%s' % (rnd.choice(['and', 'or']), sz, src(sz, False), d)
    if t == 2:
        return '%s.%s %s,%s' % (rnd.choice(['add', 'sub', 'and', 'or', 'eor']), sz, d, mem(sz))
    if t == 3:
        s = rnd.choice(['w', 'l'])
        return '%s.%s %s,a5' % (rnd.choice(['adda', 'suba', 'cmpa']), s, src(s))
    if t == 4:
        s = rnd.choice(['w', 'l'])
        return '%s.%s #%d,%s' % (rnd.choice(['addq', 'subq']), sz, rnd.randint(1, 8),
                                 rnd.choice([d, mem(sz), 'a5' if sz != 'b' else d]))
    if t == 5:
        return '%s.%s %s,%s' % (rnd.choice(['addi', 'subi', 'andi', 'ori', 'eori', 'cmpi']), sz,
                                imm(sz), dst(sz))
    if t == 6:
        return '%s.%s %s' % (rnd.choice(['neg', 'negx', 'not', 'clr', 'tst']), sz, dst(sz))
    if t == 7:
        if rnd.random() < 0.5:
            return '%s.%s %s,%s' % (rnd.choice(['addx', 'subx']), sz, rnd.choice(DREG), d)
        r = INC[sz]
        return '%s.%s -(%s),-(%s)' % (rnd.choice(['addx', 'subx']), sz, rnd.choice(r), rnd.choice(r))
    if t == 8:
        if rnd.random() < 0.5:
            return '%s %s,%s' % (rnd.choice(['abcd', 'sbcd']), rnd.choice(DREG), d)
        return '%s -(%s),-(%s)' % (rnd.choice(['abcd', 'sbcd']), rnd.choice(['a3', 'a4']), rnd.choice(['a3', 'a4']))
    if t == 9:
        return 'nbcd %s' % dst('b')
    if t == 10:
        op = rnd.choice(['asl', 'asr', 'lsl', 'lsr', 'rol', 'ror', 'roxl', 'roxr'])
        c = rnd.random()
        if c < 0.4:
            return '%s.%s #%d,%s' % (op, sz, rnd.randint(1, 8), d)
        if c < 0.8:
            return '%s.%s %s,%s' % (op, sz, rnd.choice(SRCD), d)
        return '%s.w %s' % (op, mem('w'))
    if t == 11:
        op = rnd.choice(['btst', 'bchg', 'bclr', 'bset'])
        if rnd.random() < 0.5:
            return '%s %s,%s' % (op, rnd.choice(SRCD), rnd.choice([d, mem('b')]))
        return '%s #%d,%s' % (op, rnd.randint(0, 31), rnd.choice([d, mem('b')]))
    if t == 12:
        return '%s.w %s,%s' % (rnd.choice(['mulu', 'muls']), src('w', False), d)
    if t == 13:
        # divisor never zero
        v = rnd.choice([1, 2, 3, 7, 0x10, 0xff, 0x7fff, 0x8000, 0xffff, rnd.randint(1, 0xffff)])
        return '%s.w #$%x,%s' % (rnd.choice(['divu', 'divs']), v, d)
    if t == 14:
        return 'move.%s %s,%s' % (sz, src(sz), dst(sz))
    if t == 15:
        s = rnd.choice(['w', 'l'])
        return 'movea.%s %s,a5' % (s, src(s))
    if t == 16:
        return 'moveq #%d,%s' % (rnd.randint(-128, 127), d)
    if t == 17:
        ea = rnd.choice(['(a0)', '%d(a1)' % rnd.randint(-500, 500), '%d(a2,d6.w)' % rnd.randint(-100, 100),
                         '($1234).w', '($123456).l', 'pcdata(pc)', '@ISLAND+8(pc,d7.l)'])
        if rnd.random() < 0.5:
            return 'lea %s,a5' % ea
        return 'pea %s\n\taddq.l #4,sp' % ea
    if t == 18:
        return rnd.choice(['exg %s,%s' % (d, rnd.choice(DREG)), 'exg %s,a5' % d, 'exg a5,a6'])
    if t == 19:
        return rnd.choice(['ext.w %s' % d, 'ext.l %s' % d, 'swap %s' % d])
    if t == 20:
        return 's%s %s' % (rnd.choice(CC), dst('b'))
    if t == 21:
        return 'tas %s' % dst('b')
    if t == 22:
        s = rnd.choice(['w', 'l'])
        regs = '/'.join(sorted(rnd.sample(DREG + ['a5'], rnd.randint(1, 5))))
        c = rnd.random()
        if c < 0.33:
            return 'movem.%s %s,-(%s)' % (s, regs, rnd.choice(['a0', 'a1', 'a2']))
        if c < 0.66:
            return 'movem.%s %s,%s' % (s, regs, rnd.choice(['(a0)', '%d(a1)' % even(rnd.randint(-200, 200), 'w'),
                                                                '($6100).w', '($c400).l']))
        return 'movem.%s %s,%s' % (s, rnd.choice(['(a0)+', '(a1)', '%d(a2)' % even(rnd.randint(-200, 200), 'w'),
                                                  'pcdata(pc)', '($6200).w']), regs)
    if t == 23:
        s = rnd.choice(['w', 'l'])
        a = rnd.choice(['a0', 'a1', 'a2', 'a3', 'a4'])
        if rnd.random() < 0.5:
            return 'movep.%s %s,%d(%s)' % (s, d, rnd.randint(-100, 100), a)
        return 'movep.%s %d(%s),%s' % (s, rnd.randint(-100, 100), a, d)
    if t == 24:
        return rnd.choice(['move.w %s,ccr' % src('w', False), 'andi.b %s,ccr' % imm('b'),
                           'ori.b %s,ccr' % imm('b'), 'eori.b %s,ccr' % imm('b')])
    if t == 25:
        return 'move.w sr,%s' % dst('w')
    if t == 26:
        return 'move.w #$%x,sr' % (0x2700 | rnd.getrandbits(5))
    if t == 27:
        return 'link a6,#%d\n\t%s\n\tunlk a6' % (-even(rnd.randint(0, 64), 'w'), 'move.l d0,-4(a6)')
    if t == 28:
        l = lbl()
        return 'b%s.%s %s\n\tmoveq #%d,%s\n%s:' % (rnd.choice(CC[2:]), rnd.choice(['s', 'w']), l,
                                                   rnd.randint(-128, 127), d, l)
    if t == 29:
        l = lbl()
        c = rnd.choice(DREG)
        return 'moveq #%d,%s\n%s:\taddq.w #1,%s\n\tdb%s %s,%s' % (rnd.randint(0, 5), c, l,
                                                                  rnd.choice([x for x in DREG if x != c]),
                                                                  rnd.choice(CC), c, l)
    if t == 30:
        return rnd.choice(['bsr sub%d' % rnd.randint(0, 7), 'jsr sub%d(pc)' % rnd.randint(0, 7),
                           'jsr sub%d' % rnd.randint(0, 7)])
    if t == 31:
        l = lbl()
        return 'jmp %s(pc)\n\tmoveq #1,%s\n%s:' % (l, d, l)
    if t == 32:
        r = INC[sz]
        return 'cmpm.%s (%s)+,(%s)+' % (sz, rnd.choice(r), rnd.choice(r))
    if t == 33:
        return 'nop'
    if t == 34:
        return 'bra.w *+4'
    if t == 35:
        return 'move.l usp,a5\n\tmove.l a5,usp'
    if t == 36:
        return '%s.%s %s,%s' % (rnd.choice(['add', 'sub']), sz, d, rnd.choice(DREG))
    if t == 37:
        return 'move.%s %s,%s' % (sz, mem(sz, False), mem(sz))
    if t == 38:
        return '%s.l %s,%s' % (rnd.choice(['add', 'sub', 'cmp']), rnd.choice(['a0', 'a1', 'a5']), d)
    if t == 39:
        return 'eor.%s %s,%s' % (sz, rnd.choice(DREG), d)
    if t == 40:
        return 'rtr_test'
    if t == 41:
        return 'move.%s %s,%s' % (sz, src(sz), d)
    if t == 42:
        return '%s.%s %s' % (rnd.choice(['asl', 'lsr', 'roxl', 'ror']), 'w', mem('w'))
    if t == 43:
        return 'chk.w #$7fff,%s' % 'd6'          # D6 is a small positive value
    if t == 44:
        return 'move.b %s,%s' % (mem('b', False), mem('b'))
    if t == 45:
        return 'mulu.w %s,%s\n\tdivu.w #$%x,%s' % (rnd.choice(SRCD), d, rnd.randint(1, 0xffff), d)
    return 'cmp.%s %s,%s' % (sz, src(sz), d)


def rtr():
    # push a CCR/PC pair and RTR to the next instruction
    l = lbl()
    return 'pea %s(pc)\n\tmove.w #$%x,-(sp)\n\trtr\n%s:' % (l, rnd.getrandbits(5), l)


out = []
out.append("""; generated by gen_random.py %d %d
	org	0
	dc.l	$000f0000
	dc.l	start
	dcb.l	254,fault

	org	$1000
fault:	move.w	#$8000,$ff0000
	bra.s	fault

pcdata:""" % (seed, nblocks))
for i in range(64):
    out.append('\tdc.w\t$%04x' % rnd.getrandbits(16))
for i in range(8):
    out.append('sub%d:\tadd.l\td%d,d%d\n\trts' % (i, i % 6, (i + 1) % 6))
out.append("""
start:	lea	$c000,a0		; fill the buffers
	move.l	#$%08x,d0
	move.w	#($f000-$c000)/4-1,d1
.f1:	move.l	d0,(a0)+
	rol.l	#5,d0
	eor.l	#$9e3779b9,d0
	dbf	d1,.f1
	lea	$6000,a0
	move.w	#$2000/4-1,d1
.f2:	move.l	d0,(a0)+
	ror.l	#3,d0
	add.l	#$7f4a7c15,d0
	dbf	d1,.f2
	lea	$e0000,a0
	move.l	a0,usp
	movem.l	pcdata,d0-d5
	moveq	#6,d6
	moveq	#-4,d7
	movea.l	#$11111111,a5
	movea.l	#$e8000,a6
""" % rnd.getrandbits(32))

for b in range(nblocks):
    out.append("""	lea	$c800,a0
	lea	$d000,a1
	lea	$d800,a2
	lea	$e000,a3
	lea	$e800,a4""")
    for i in range(blocklen):
        g = gen()
        if g == 'rtr_test':
            g = rtr()
        if '@ISLAND' in g:
            e, d = lbl(), lbl()
            g = 'bra.s %s\n%s:\tdc.w %s\n%s:\t%s' % (e, d, ','.join('$%04x' % rnd.getrandbits(16) for _ in range(8)),
                                                   e, g.replace('@ISLAND', d))
        out.append('\t' + g.replace('\n', '\n\t'))
    base = 0x9000 + b * 64
    out.append('\tmovem.l\td0-d7/a0-a6,($%x).l\n\tmove.w\tsr,($%x).l' % (base, base + 60))

out.append("""	lea	$6000,a0		; absolute short buffer into the dump
	lea	$f000,a1
	move.w	#$2000/4-1,d1
.c1:	move.l	(a0)+,(a1)+
	dbf	d1,.c1
	move.w	#0,$ff0000
	bra.s	*
""")

src_text = '\n'.join(out) + '\n'
# labels of the form "\t.lN:" must start at column 0
src_text = src_text.replace('\n\t.l', '\n.l')
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, 'tests', 'random.s'), 'w').write(src_text)
print('tests/random.s: %d blocks of %d instructions, seed %d' % (nblocks, blocklen, seed))
