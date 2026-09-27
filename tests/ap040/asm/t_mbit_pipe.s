; t_mbit_pipe.s - plan M9.T step 3: the M bit, the master stack and the
; format $1 throwaway frame.  Runs under tb_ap040_pipe_compat.v.
; Protocol: $F100 word = failing check, $F102 = $600D / $BAD0.
;
; M68040UM 8.2.9 and 8.4.2: an INTERRUPT taken while S = 1 and M = 1 stacks
; TWO frames.  The normal one goes on the MASTER stack -- the stack the SR
; selects at the time -- and then the processor CLEARS M and stacks a
; four-word format $1 THROWAWAY frame on the INTERRUPT stack, which is where
; the handler runs.  The throwaway's SR image keeps M SET (only S is forced),
; so the RTE that pops it switches back to the master stack and continues
; with the real frame there.
;
;   1  the handler runs with M CLEAR ...
;   2  ... on the INTERRUPT stack, eight bytes below where it was
;   3  the frame it stands on is format $1 with the interrupt's own vector
;   4  its SR image has M and S SET -- that is what sends the RTE back
;   5  the MASTER stack holds the real frame, eight bytes below $3800
;   6  which is format $0 with the same vector ...
;   7  ... and carries the SR the interrupt interrupted
;   8  after the RTE both stack pointers are back where they started ...
;   9  ... M is set again, and the interrupt was taken exactly once
;  10  an exception that is NOT an interrupt stacks ONE frame on the
;      master stack and leaves M alone (a TRAP with M set)

FAILREG		equ	$F100
DONEREG		equ	$F102
IPLREG		equ	$F110
cnt_int		equ	$3600
cnt_trap	equ	$3604
h_sr		equ	$3608		; the handler's own SR
h_a7		equ	$360C		; ... and its A7
h_fv		equ	$3610		; the throwaway frame's format/vector
h_fsr		equ	$3614		; ... and its SR image
h_msp		equ	$3618		; MSP inside the handler
h_mfv		equ	$361C		; the master frame's format/vector
h_mfsr		equ	$3620		; ... and its SR
t_msp		equ	$3624		; MSP inside the TRAP handler
t_fv		equ	$3628		; the TRAP frame's format/vector

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
chkw	macro
	cmp.w	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

	org	0
	dc.l	$3400
	dc.l	start
	rept	24
	dc.l	unexp		; 2-25
	endr
	dc.l	h_int2		; 26: autovector, level 2
	rept	5
	dc.l	unexp		; 27-31
	endr
	dc.l	h_trap		; 32: TRAP #0
	rept	223
	dc.l	unexp		; 33-255
	endr

	org	$400
start:
	move.w	#$2700,sr
	clr.l	(cnt_int).l
	clr.l	(cnt_trap).l
	move.l	#$3800,d0
	movec	d0,msp
	movec	isp,d5			; the interrupt stack, untouched throughout
	ori.w	#$1000,sr		; M: from here A7 is the MASTER stack
	move.l	sp,d6			; ... and this is where it stands

;------------------------------------- 1-9: the interrupt
	move.w	#2,(IPLREG).l
	move.w	#$3000,sr		; mask 0, M set: taken at the next boundary
	moveq	#40,d1
mwait:	dbra	d1,mwait

	move.w	sr,d0			; 9: M is set again after the RTE
	andi.w	#$1000,d0
	bne.s	m_back
	failt	9
m_back:
	movec	msp,d0
	chkl	d0,$3800,8		; 8: the master stack is unwound
	movec	isp,d0
	cmp.l	d0,d5
	beq.s	isp_ok
	failt	8
isp_ok:
	move.l	(cnt_int).l,d0
	chkl	d0,1,9			; exactly one interrupt

	move.l	(h_sr).l,d0		; 1: the handler ran with M clear
	andi.l	#$1000,d0
	chkl	d0,0,1
	move.l	(h_a7).l,d0		; 2: ... on the interrupt stack
	move.l	d5,d1
	subq.l	#8,d1
	cmp.l	d1,d0
	beq.s	a7_ok
	failt	2
a7_ok:
	move.l	(h_fv).l,d0		; 3: format $1, vector offset $68
	chkl	d0,$1068,3
	move.l	(h_fsr).l,d0		; 4: the image keeps M and S
	andi.l	#$3000,d0
	chkl	d0,$3000,4
	move.l	(h_msp).l,d0		; 5: the real frame is on the master stack
	chkl	d0,$37F8,5
	move.l	(h_mfv).l,d0		; 6: format $0, the same vector
	chkl	d0,$0068,6
	move.l	(h_mfsr).l,d0		; 7: the interrupted SR, M set, mask 0
	chkl	d0,$3000,7

;------------------------------------- 10: a TRAP with M set stacks ONE frame
	trap	#0
	move.l	(t_msp).l,d0		; the frame went on the MASTER stack
	chkl	d0,$37F8,10
	move.l	(t_fv).l,d0		; format $0, vector offset $80
	chkl	d0,$0080,10
	move.w	sr,d0			; ... and M is still set
	andi.w	#$1000,d0
	chkw	d0,$1000,10
	movec	msp,d0
	chkl	d0,$3800,10
	move.l	(cnt_trap).l,d0
	chkl	d0,1,10

	move.w	#$600D,(DONEREG).l
halt:	bra.s	halt

;--------------------------------------------------------------- handlers
h_int2:
	addq.l	#1,(cnt_int).l
	move.w	#0,(IPLREG).l		; drop the line before returning
	move.w	sr,d0
	andi.l	#$FFFF,d0
	move.l	d0,(h_sr).l
	move.l	sp,(h_a7).l
	moveq	#0,d0
	move.w	6(sp),d0
	move.l	d0,(h_fv).l
	moveq	#0,d0
	move.w	(sp),d0
	move.l	d0,(h_fsr).l
	movec	msp,d0
	move.l	d0,(h_msp).l
	movea.l	d0,a0
	moveq	#0,d0
	move.w	6(a0),d0
	move.l	d0,(h_mfv).l
	moveq	#0,d0
	move.w	(a0),d0
	move.l	d0,(h_mfsr).l
	rte

h_trap:
	addq.l	#1,(cnt_trap).l
	move.l	sp,(t_msp).l
	moveq	#0,d0
	move.w	6(sp),d0
	move.l	d0,(t_fv).l
	rte

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h1:	bra.s	h1
; an unexpected vector reports the frame's own vector OFFSET as the failing
; check, which names it: $008 privilege, $00C illegal, $020 TRAP #0, ...
unexp:
	move.w	4(sp),d7
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h2:	bra.s	h2
