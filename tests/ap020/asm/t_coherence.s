; AP020 on Minimig: coherence of the instruction cache, the optional data
; cache and the Fast RAM line buffers with other bus masters, and routing of
; the NMI vector
; assembled with vasmm68k_mot -Fbin -m68020
;
; bench (tb_ap020_wrapchip.sv, FASTRAM=1) control ports:
;   $F100 failing test number, $F102 $600D/$BAD0
;   $F110 interrupt level
;   $F180 DMA model: 1 chipset write of $F184.l at chip $3100 with snoops,
;                    3 the same without snoops, 2 external write to Fast RAM
;                    $200100 (DDR3)
;   $F184 long: the value the DMA model writes
;
;  1-2  chip RAM with the caches on: CIIN keeps it out of the caches and
;       the MC68020 CACR has no write allocation, so a chipset write is seen
;       with or without a snoop
;  3-5  Fast RAM line buffers and data cache: an external write is not seen
;       from a buffered line (control), is seen after a CACR clear (C); with
;       the caches on (E) a cached copy is stale until C clears it
;  6    VBR in Fast RAM: the NMI vector (VBR+$7C) is read on the Minimig
;       bus (where the cartridge overlays it), not from Fast RAM
;  7-8  the NMI vector's line held in the data cache (filled by a read of
;       the same line): the level 7 exception still reads the bus

FAILREG	equ	$F100
DONEREG	equ	$F102
IPLREG	equ	$F110
DMAGO	equ	$F180
DMADAT	equ	$F184
FAST	equ	$200000

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

	org	0
	dc.l	$3400
	dc.l	start
	rept	29			; 2-30
	dc.l	unexp
	endr
	dc.l	nmi_good		; 31: level 7 autovector
	rept	224
	dc.l	unexp
	endr

	org	$400
start:
	move.b	#$20,$E80048		; Zorro II memory card at $200000

;---------------------------------------------------------------- 1-2 chip RAM and the snoop
	move.l	#$0009,d0		; E, C
	movec	d0,cacr
	move.l	#$11223344,$3100
	move.l	$3100,d0
	move.l	#$55667788,DMADAT
	move.w	#3,DMAGO		; chipset write, no snoop
	bsr	settle
	move.l	$3100,d0
	chkl	d0,$55667788,1		; not cached: the new value
	move.l	#$11223344,$3100
	move.l	$3100,d0
	move.l	#$99AABBCC,DMADAT
	move.w	#1,DMAGO		; chipset write with its snoops
	bsr	settle
	move.l	$3100,d0
	chkl	d0,$99AABBCC,2
	moveq	#0,d0
	movec	d0,cacr
	move.l	#$55667788,DMADAT

;---------------------------------------------------------------- 3-5 Fast RAM line buffers
	move.l	#$11223344,FAST+$100
	move.l	FAST+$100,d0		; the line is buffered
	move.l	#$55667788,DMADAT
	move.w	#2,DMAGO		; external write to Fast RAM
	bsr	settle
	move.l	FAST+$100,d0
	chkl	d0,$11223344,3		; buffered (the control)
	move.l	#$0008,d0		; C: a cache clear empties the buffers
	movec	d0,cacr
	moveq	#0,d0
	movec	d0,cacr
	move.l	FAST+$100,d0
	chkl	d0,$55667788,4
	move.l	#$0009,d0		; E, C
	movec	d0,cacr
	move.l	#$11223344,FAST+$100	; written through
	move.l	FAST+$100,d0		; cached (with DATA_CACHE) and buffered
	move.w	#2,DMAGO
	bsr	settle
	move.l	FAST+$100,d0
	chkl	d0,$11223344,9		; stale (the control)
	move.l	#$0009,d0		; C
	movec	d0,cacr
	move.l	FAST+$100,d0
	chkl	d0,$55667788,5
	moveq	#0,d0
	movec	d0,cacr

;---------------------------------------------------------------- 6 VBR in Fast RAM
	move.l	#nmi_bad,FAST+$7C	; Fast RAM's copy of the vector
	move.l	#FAST,d0
	movec	d0,vbr
	moveq	#0,d0
	move.w	#7,IPLREG
	bsr	settle
	chkl	d0,2,6			; nmi_good: read on the Minimig bus
	moveq	#0,d0
	movec	d0,vbr

;---------------------------------------------------------------- 7-8 the NMI vector's line in the data cache
	move.l	#$0009,d0		; E, C
	movec	d0,cacr
	move.l	#$01020304,FAST+$70
	move.l	#nmi_bad,FAST+$7C	; Fast RAM's copy of the vector
	move.l	#FAST,d0
	movec	d0,vbr
	move.l	FAST+$70,d1		; a burst fill: the line, with VBR+$7C
	chkl	d1,$01020304,7
	moveq	#0,d0
	move.w	#7,IPLREG
	bsr	settle
	chkl	d0,2,8			; the exception read the bus
	moveq	#0,d0
	movec	d0,cacr
	movec	d0,vbr

	move.w	#$600D,DONEREG
	stop	#$2700

; wait for the DMA model or an interrupt (the 7 MHz bus is slow)
settle:
	move.w	#200,d6
st1:	nop
	dbf	d6,st1
	rts

nmi_good:
	moveq	#2,d0
	move.w	#0,IPLREG
	rte
nmi_bad:
	moveq	#1,d0
	move.w	#0,IPLREG
	rte

fail_all:
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
halt1:	bra.s	halt1

unexp:
	move.w	#$00FF,FAILREG
	move.w	#$BAD0,DONEREG
halt2:	bra.s	halt2

