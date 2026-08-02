; AP040 milestone C exception, interrupt and control register self test
; assembled with vasmm68k_mot -Fbin -m68040
;
; testbench protocol:
;   word write to $F100 = failing test number
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed
;   word write to $F110 = request interrupt level (0 releases)
;   byte write to $F120 must carry FC=1 (MOVES with DFC=1 check in the TB)
;
; frame layout under test (MC68040):
;   format $0: SR@0, PC@2, fmt/vec@6            (8 bytes)
;   format $1: same, throwaway                  (8 bytes)
;   format $2: + address@8                      (12 bytes)

FAILREG	equ	$F100
DONEREG	equ	$F102
IPLREG	equ	$F110
FCREG	equ	$F120

cnt_trap0	equ	$3600
cnt_ill		equ	$3602
cnt_aline	equ	$3604
cnt_fline	equ	$3606
cnt_chk		equ	$3608
cnt_divz	equ	$360A
cnt_trapv	equ	$360C
cnt_trapcc	equ	$360E
cnt_int2	equ	$3610
cnt_int5	equ	$3612
cnt_nmi		equ	$3614
cnt_mflag	equ	$3616
cnt_priv	equ	$3618
cnt_trapu	equ	$361A
cnt_fmt		equ	$361C
cnt_addr	equ	$361E
resume		equ	$3630

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

chkcnt	macro			; \1 = counter address, \2 = expected, \3 = test
	move.w	(\1).l,d6
	cmp.w	#\2,d6
	beq.s	ok\@
	failt	\3
ok\@:
	endm

	org	0
	dc.l	$3400		; ISP
	dc.l	start
	dc.l	unexp		; 2 bus error
	dc.l	h_addr		; 3 address error
	dc.l	h_ill		; 4 illegal
	dc.l	h_divz		; 5 divide by zero
	dc.l	h_chk		; 6 CHK
	dc.l	h_trapv		; 7 TRAPV/TRAPcc
	dc.l	h_priv		; 8 privilege violation
	dc.l	unexp		; 9 trace
	dc.l	h_aline		; 10 A-line
	dc.l	h_fline		; 11 F-line
	dc.l	unexp,unexp	; 12,13
	dc.l	h_fmt		; 14 format error
	dc.l	unexp		; 15
	rept	8
	dc.l	unexp		; 16-23
	endr
	dc.l	unexp,unexp	; 24 spurious, 25 level 1
	dc.l	h_int2		; 26 level 2 autovector
	dc.l	unexp,unexp	; 27,28
	dc.l	h_int5		; 29 level 5 autovector
	dc.l	unexp		; 30
	dc.l	h_nmi		; 31 level 7 autovector
	dc.l	h_trap0		; 32 TRAP #0
	dc.l	h_trap1		; 33 TRAP #1
	rept	14
	dc.l	unexp		; 34-47
	endr
	rept	208
	dc.l	unexp		; 48-255
	endr

	org	$400
start:
	lea	(cnt_trap0).l,a0
	moveq	#15,d0
clrloop:
	clr.w	(a0)+
	dbra	d0,clrloop

;----------------------------------------------------------------- TRAP #0
	trap	#0
	chkcnt	cnt_trap0,1,1

;----------------------------------------------------------------- illegal / BKPT
	dc.w	$4AFC		; ILLEGAL
	chkcnt	cnt_ill,1,2
	dc.w	$4848		; BKPT #0: illegal on this implementation
	chkcnt	cnt_ill,2,3

;----------------------------------------------------------------- A/F-line
	dc.w	$A123
	chkcnt	cnt_aline,1,4
	dc.w	$F0FF		; 030 PMMU opcode: F-line on 040
	chkcnt	cnt_fline,1,5

;----------------------------------------------------------------- CHK
	move.l	#5,d0
	chk.w	#3,d0		; out of bounds high
	chkcnt	cnt_chk,1,6
	move.l	#-1,d0
	chk.w	#100,d0		; negative
	chkcnt	cnt_chk,2,7
	move.l	#50,d0
	chk.w	#100,d0		; in bounds: no trap
	chkcnt	cnt_chk,2,8

;----------------------------------------------------------------- divide by zero
	move.l	#7,d0
	divu.w	#0,d0
	chkcnt	cnt_divz,1,9

;----------------------------------------------------------------- TRAPV / TRAPcc
	move.w	#$02,ccr
	trapv
	chkcnt	cnt_trapv,1,10
	move.w	#$00,ccr
	trapv
	chkcnt	cnt_trapv,1,11
	move.w	#$04,ccr	; Z=1
	trapeq
	chkcnt	cnt_trapv,2,12
	trapne
	chkcnt	cnt_trapv,2,13
	trapeq.w #$1234		; with operand word
	chkcnt	cnt_trapv,3,14

;----------------------------------------------------------------- MOVEC matrix
	moveq	#0,d0
	move.l	#$100,d0
	movec	d0,vbr
	movec	vbr,d1
	chkl	d1,$100,15
	moveq	#0,d0
	movec	d0,vbr		; vectors back at zero

	move.l	#$FFFFFFFF,d0
	movec	d0,sfc
	movec	sfc,d1
	chkl	d1,7,16
	movec	d0,dfc
	movec	dfc,d1
	chkl	d1,7,17

	movec	d0,cacr
	movec	cacr,d1
	chkl	d1,$80008000,18
	moveq	#0,d0
	movec	d0,cacr

	move.l	#$FFFFFFFF,d0
	movec	d0,tc
	movec	tc,d1
	chkl	d1,$0000C000,19
	moveq	#0,d0
	movec	d0,tc

	move.l	#$FFFFFFFF,d0
	movec	d0,itt0
	movec	itt0,d1
	chkl	d1,$FFFFE364,20
	movec	d0,dtt1
	movec	dtt1,d1
	chkl	d1,$FFFFE364,21
	moveq	#0,d0
	movec	d0,itt0
	movec	d0,dtt1

	move.l	#$FFFFFFFF,d0
	movec	d0,urp
	movec	urp,d1
	chkl	d1,$FFFFFE00,22
	movec	d0,srp
	movec	srp,d1
	chkl	d1,$FFFFFE00,23

	move.l	#$12345678,d0
	movec	d0,mmusr
	movec	mmusr,d1
	chkl	d1,$12345678,24

	move.l	#$3C00,d0
	movec	d0,usp
	movec	usp,d1
	chkl	d1,$3C00,25

	move.l	#$3800,d0
	movec	d0,msp
	movec	msp,d1
	chkl	d1,$3800,26

	movec	isp,d0		; active stack: must equal SP
	cmp.l	sp,d0
	beq.s	t27ok
	failt	27
t27ok:

;----------------------------------------------------------------- MOVE USP
	movea.l	#$3C00,a0
	move	a0,usp
	move	usp,a1
	cmpa.l	#$3C00,a1
	beq.s	t28ok
	failt	28
t28ok:

;----------------------------------------------------------------- MOVES
	moveq	#1,d0
	movec	d0,sfc
	movec	d0,dfc
	lea	(FCREG).l,a0
	move.b	#$5A,d1
	moves.b	d1,(a0)		; TB verifies FC=1 on this write
	moves.b	(a0),d2
	and.l	#$FF,d2
	chkl	d2,$5A,29

;----------------------------------------------------------------- PTEST/PFLUSH/CINV/CPUSH decode
	lea	($5000).l,a0
	ptestr	(a0)
	movec	mmusr,d0
	chkl	d0,$5001,30	; transparent + resident while MMU is off
	pflusha
	cinva	bc
	cpushl	dc,(a0)

;----------------------------------------------------------------- user mode round trip
	movea.l	#$3C00,a0
	movec	a0,usp
	move.w	#$0000,-(sp)	; format/vector
	pea	user_code(pc)
	move.w	#$0000,-(sp)	; user SR
	rte

user_code:
	move.l	#$CAFEBABE,-(sp)	; goes to the user stack
	trap	#1
	move.w	#$2700,sr	; privilege violation in user mode
	failt	31		; never reached

super_cont:
	chkcnt	cnt_trapu,1,32
	chkcnt	cnt_priv,1,33

;----------------------------------------------------------------- format error
	lea	fmt_cont(pc),a0
	move.l	a0,(resume).l
	move.w	#$B010,-(sp)	; format $B frame: invalid
	pea	fmt_cont(pc)
	move.w	#$2700,-(sp)
	rte			; must take a format error
fmt_cont:
	addq.l	#8,sp		; discard the fake frame
	chkcnt	cnt_fmt,1,34

;----------------------------------------------------------------- address error
	lea	addr_cont(pc),a0
	move.l	a0,(resume).l
	jmp	($0401).l	; odd target
addr_cont:
	chkcnt	cnt_addr,1,35

;----------------------------------------------------------------- interrupts
	move.w	#$2000,sr	; supervisor, mask 0
	move.w	#2,(IPLREG).l
	bsr	wait_int2_1
	chkcnt	cnt_int2,1,36

	; masked interrupt stays pending
	move.w	#$2700,sr
	move.w	#5,(IPLREG).l
	move.w	#100,d0
mdelay:
	dbra	d0,mdelay
	chkcnt	cnt_int5,0,37	; must not have fired
	move.w	#$2400,sr	; open mask to 4: level 5 fires
	bsr	wait_int5_1
	chkcnt	cnt_int5,1,38

	; STOP wakes on pending interrupt after mask drop
	move.w	#$2700,sr
	move.w	#2,(IPLREG).l
	stop	#$2000
	chkcnt	cnt_int2,2,39

	; NMI is edge sensitive and pierces the mask
	move.w	#$2700,sr
	move.w	#7,(IPLREG).l
	bsr	wait_nmi_1
	chkcnt	cnt_nmi,1,40
	move.w	#7,(IPLREG).l
	bsr	wait_nmi_2
	chkcnt	cnt_nmi,2,41

;----------------------------------------------------------------- M bit throwaway
	move.w	#$2000,sr
	move.l	#$3800,d0
	movec	d0,msp
	movec	isp,d5		; remember ISP
	ori.w	#$1000,sr	; switch to master stack
	move.w	#2,(IPLREG).l
	bsr	wait_int2_3
	; back here with M restored from the master stack frame
	move.w	sr,d0
	andi.w	#$1000,d0
	beq	mfail
	chkcnt	cnt_mflag,1,42	; exactly one throwaway frame seen
	movec	msp,d0
	chkl	d0,$3800,43	; master stack fully unwound
	andi.w	#$EFFF,sr	; back to interrupt stack
	movec	isp,d0
	cmp.l	d0,d5
	beq.s	t44ok
	failt	44
t44ok:

;----------------------------------------------------------------- all done
	move.w	#$600D,(DONEREG).l
	stop	#$2700

mfail:
	failt	45

;----------------------------------------------------------------- wait loops
wait_int2_1:
	move.l	#20000,d0
wi21:
	move.w	(cnt_int2).l,d1
	cmp.w	#1,d1
	beq.s	wi2done
	subq.l	#1,d0
	bne.s	wi21
	failt	50
wi2done:
	rts

wait_int2_3:
	move.l	#20000,d0
wi23:
	move.w	(cnt_int2).l,d1
	cmp.w	#3,d1
	beq.s	wi2done
	subq.l	#1,d0
	bne.s	wi23
	failt	51

wait_int5_1:
	move.l	#20000,d0
wi51:
	move.w	(cnt_int5).l,d1
	cmp.w	#1,d1
	beq.s	wi5done
	subq.l	#1,d0
	bne.s	wi51
	failt	52
wi5done:
	rts

wait_nmi_1:
	move.l	#20000,d0
wn1:
	move.w	(cnt_nmi).l,d1
	cmp.w	#1,d1
	beq.s	wndone
	subq.l	#1,d0
	bne.s	wn1
	failt	53
wndone:
	rts

wait_nmi_2:
	move.l	#20000,d0
wn2:
	move.w	(cnt_nmi).l,d1
	cmp.w	#2,d1
	beq.s	wndone
	subq.l	#1,d0
	bne.s	wn2
	failt	54

;----------------------------------------------------------------- handlers
h_trap0:
	cmpi.w	#$0080,6(sp)
	bne	hfail
	addq.w	#1,(cnt_trap0).l
	rte

h_trap1:
	; arrived from user mode: check stacked SR, USP and user stack data
	move.l	d0,-(sp)
	move.w	4(sp),d0	; stacked SR
	andi.w	#$2000,d0
	bne	hfail
	movec	usp,d0
	cmp.l	#$3BFC,d0
	bne	hfail
	move.l	($3BFC).l,d0
	cmp.l	#$CAFEBABE,d0
	bne	hfail
	addq.w	#1,(cnt_trapu).l
	move.l	(sp)+,d0
	rte

h_ill:
	cmpi.w	#$0010,6(sp)
	bne	hfail
	addq.l	#2,2(sp)	; skip the 2-byte opcode
	addq.w	#1,(cnt_ill).l
	rte

h_aline:
	cmpi.w	#$0028,6(sp)
	bne	hfail
	addq.l	#2,2(sp)
	addq.w	#1,(cnt_aline).l
	rte

h_fline:
	cmpi.w	#$002C,6(sp)
	bne	hfail
	addq.l	#2,2(sp)
	addq.w	#1,(cnt_fline).l
	rte

h_chk:
	cmpi.w	#$2018,6(sp)
	bne	hfail
	addq.w	#1,(cnt_chk).l
	rte

h_divz:
	cmpi.w	#$2014,6(sp)
	bne	hfail
	addq.w	#1,(cnt_divz).l
	rte

h_trapv:
	cmpi.w	#$201C,6(sp)
	bne	hfail
	addq.w	#1,(cnt_trapv).l
	rte

h_priv:
	cmpi.w	#$0020,6(sp)
	bne	hfail
	ori.w	#$2000,(sp)	; return in supervisor mode
	move.l	#super_cont,2(sp)
	addq.w	#1,(cnt_priv).l
	rte

h_fmt:
	cmpi.w	#$0038,6(sp)
	bne	hfail
	move.l	(resume).l,2(sp)
	addq.w	#1,(cnt_fmt).l
	rte

h_addr:
	cmpi.w	#$200C,6(sp)
	bne	hfail
	move.l	(resume).l,2(sp)
	addq.w	#1,(cnt_addr).l
	rte

h_int2:
	move.l	d0,-(sp)
	move.w	10(sp),d0	; frame format/vector
	andi.w	#$0FFF,d0
	cmpi.w	#$0068,d0
	bne	hfail
	move.w	10(sp),d0
	andi.w	#$F000,d0
	beq.s	hi2f0
	cmpi.w	#$1000,d0
	bne	hfail
	addq.w	#1,(cnt_mflag).l
	move.w	sr,d0		; M must already be clear on a throwaway
	andi.w	#$1000,d0
	bne	hfail
hi2f0:
	addq.w	#1,(cnt_int2).l
	move.w	#0,(IPLREG).l
	move.l	(sp)+,d0
	rte

h_int5:
	cmpi.w	#$0074,6(sp)
	bne	hfail
	addq.w	#1,(cnt_int5).l
	move.w	#0,(IPLREG).l
	rte

h_nmi:
	cmpi.w	#$007C,6(sp)
	bne	hfail
	addq.w	#1,(cnt_nmi).l
	move.w	#0,(IPLREG).l
	rte

hfail:
	failt	98

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt1:
	bra.s	halt1

unexp:
	move.w	#$0099,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt2:
	bra.s	halt2
