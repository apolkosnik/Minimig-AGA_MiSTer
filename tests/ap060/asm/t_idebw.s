; Gayle IDE transfer time on the Minimig CPU bus (fastchip's Gayle, IDE in
; its fast mode), for the AP68060 (tests/ap060) and the AP68030
; (tests/ap030) alike: NSEC sectors, each loaded by the bench's IDE
; management side ($F1D0, done at $F1D2) and read into Fast RAM as
; scsi.device does, 256 MOVE.W (WIDTH=2) or 128 MOVE.L (WIDTH=4) from the
; data register.  The loop runs from Fast RAM (the instruction cache).
; Run with NSEC=1 and NSEC=9: the difference / 8 is one sector.
;   -DCPU=60 / -DCPU=30, -DNSEC=n, -DWIDTH=2|4, -DCM=m (68060 only):
;   CM=0 data cache off (as before 68060.library), CM=1 DTT0 noncachable
;   precise for $00xxxxxx, CM=2 imprecise -- in both the destination is
;   then noncachable too, as the I/O space it shares 16 MB with; CM=3 the
;   MMU as 68060.library sets it: 8K pages mapping the first 16 MB as they
;   are, Fast RAM copyback, the rest noncachable precise; CM=4 the rest
;   imprecise
;
; protocol: $F100 test number, $F102 $600D pass / $BAD0 fail

FAILREG	equ	$F100
DONEREG	equ	$F102
IDELOAD	equ	$F1D0
IDEDONE	equ	$F1D2
IDEDATA	equ	$DA0000
IDESTAT	equ	$DA001C
FAST	equ	$200000
CODE	equ	FAST+$1000
TABLES	equ	$10000			; root $10000, pointer $10200, pages $10400..
BUF	equ	FAST+$8000

	org	0
	dc.l	$3400
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	move.b	#$20,($e80048).l	; Zorro II RAM at $200000
	lea	body(pc),a0
	lea	(CODE).l,a1
	move.w	#(body_end-body)/2-1,d0
copy:	move.w	(a0)+,(a1)+
	dbra	d0,copy
	jmp	(CODE).l

body:
	if	CPU=60
	if	CM>=3
	; root[0] -> pointer table; pointer[0..63] -> 64 page tables of 32
	; pages of 8K (16 MB), each page mapped to itself
	lea	(TABLES).l,a0
	move.w	#255,d0
mclr:	clr.l	(a0)+
	dbra	d0,mclr
	move.l	#TABLES+$203,(TABLES).l
	lea	(TABLES+$200).l,a0
	move.l	#TABLES+$400+3,d1
	moveq	#63,d0
mptr:	move.l	d1,(a0)+
	add.l	#$80,d1
	dbra	d0,mptr
	lea	(TABLES+$400).l,a0
	moveq	#0,d1			; physical address
	move.w	#2047,d0
mpg:	move.l	d1,d2
	cmp.l	#$200000,d1		; Fast RAM: copyback
	blo.s	mio
	cmp.l	#$400000,d1
	bhs.s	mio
	or.w	#$21,d2
	bra.s	mput
mio:
	if	CM=3
	or.w	#$41,d2			; noncachable, precise
	else
	or.w	#$61,d2			; noncachable, imprecise
	endif
mput:	move.l	d2,(a0)+
	add.l	#$2000,d1
	dbra	d0,mpg
	move.l	#TABLES,d0
	movec	d0,urp
	movec	d0,srp
	pflusha
	move.l	#$C000,d0		; E, 8K pages
	movec	d0,tc
	move.l	#$A0808000,d0
	else
	if	CM=0
	move.l	#$00008000,d0		; instruction cache only
	else
	if	CM=1
	move.l	#$0000C040,d0		; noncachable, precise
	else
	move.l	#$0000C060,d0		; noncachable, imprecise
	endif
	movec	d0,dtt0
	move.l	#$A0808000,d0		; EDC, ESB, EBC, EIC
	endif
	endif
	movec	d0,cacr
	else
	move.l	#$0000111,d0		; 68030: instruction and data caches, IBE
	movec	d0,cacr
	endif

	moveq	#NSEC-1,d6
sector:
	clr.w	IDEDONE
	move.w	#1,IDELOAD
ls_w:	tst.w	IDEDONE
	beq.s	ls_w
	lea	(BUF).l,a1
	lea	IDEDATA,a0
	if	WIDTH=2
	move.w	#255,d1
rd:	move.w	(a0),(a1)+
	dbf	d1,rd
	else
	moveq	#127,d1
rd:	move.l	(a0),(a1)+
	dbf	d1,rd
	endif
	move.b	IDESTAT,d0
	btst	#3,d0			; DRQ gone: exactly 256 words read
	bne.s	bad
	dbf	d6,sector

	if	CPU=60
	cpusha	dc			; the buffer to memory for the check below
	moveq	#0,d0
	movec	d0,cacr
	endif
	move.w	(BUF+10).l,d0		; word 5 of the pattern
	cmp.w	#$5F05,d0
	beq.s	ok
	cmp.w	#$055F,d0
	bne.s	bad2
ok:	move.w	#$600D,DONEREG
fa:	bra.s	fa
bad:	move.w	#1,FAILREG
	move.w	#$BAD0,DONEREG
	bra.s	fa
bad2:	move.w	#2,FAILREG
	move.w	#$BAD0,DONEREG
	bra.s	fa
body_end:

unexp:	move.w	#$FF,FAILREG
	move.w	#$BAD0,DONEREG
un:	bra.s	un
