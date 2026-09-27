; Pipelined AP68040, plan M7: MMU cases t_mmu.s does not tell apart.
; Runs under tb_ap040_pipe_compat.v (the wrapper with the lifted MMU and
; cache), all three bus phases.  Protocol: $F100 word = failing check,
; $F102 word = $600D (pass) or $BAD0 (fail).
;
;   1-3  PFLUSH (An) flushes that page's entry only (PFLUSHA all);
;        PFLUSH/PFLUSHA select the entries by DFC (M68040UM 3.7, p. 3-33)
;   4-7  PFLUSHN (An) / PFLUSHAN spare a global (G = 1) entry, PFLUSH (An)
;        and PFLUSHA do not
;   20-25 register-indirect MOVEM with CM: a stacked EA the handler edits is
;        not used (only mode 6 / PC relative restore it, 8.4.6.7); two MOVEMs
;        back to back report the first one's EA
;   26-27 a bitfield over two invalid pages faults on the word first
;        (WinUAE x_get_bitfield order, PLAN D14)
;   13-18 MOVEM -(An) faulting on its last store: SSW CM, restart, An
;        decremented once (M68040UM 8.4.6.2 p. 8-25, 8.4.6.7 p. 8-27)
;   8-12 a longword store crossing into an invalid page: one access error,
;        SSW MA (the fault is on the second page, M68040UM 8.4.6.2 p. 8-25),
;        FA = the first byte; the bytes on the first page are written, and
;        the handler completes the pending WB1 (PLAN D13) or the core
;        restarts -- either way both pages end up with the store

FAILREG		equ	$F100
DONEREG		equ	$F102
cnt_aerr	equ	$3600
last_ssw	equ	$3602
last_fa		equ	$3604
fix_addr	equ	$360C
fix_val		equ	$3610
fix2_addr	equ	$3614		; a second descriptor the handler repairs
fix2_val	equ	$3618
first_fa	equ	$361C		; FA of the first fault since cnt_aerr was cleared
edit_ea		equ	$3620		; nonzero: the handler overwrites the stacked EA
last_ea		equ	$3624
scratch		equ	$3628

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
	dc.l	h_aerr
	rept	253
	dc.l	unexp
	endr

	org	$400
start:
	move.w	#$2700,sr
	clr.w	(cnt_aerr).l
	clr.l	(edit_ea).l
	move.l	#scratch,(fix2_addr).l
	lea	($4400).l,a0		; 64 x 4K identity, resident
	moveq	#0,d0
	moveq	#63,d1
tl:	move.l	d0,d2
	lsl.l	#8,d2
	lsl.l	#4,d2
	addq.l	#3,d2
	move.l	d2,(a0)+
	addq.l	#1,d0
	dbra	d1,tl
	move.l	#$00004203,($4000).l
	move.l	#$00004403,($4200).l
	move.l	#$A1A1A1A1,($5000).l
	move.l	#$B2B2B2B2,($6000).l
	move.l	#$C3C3C3C3,($7000).l
	move.l	#$D4D4D4D4,($8000).l
	moveq	#5,d0			; PFLUSH selects by DFC: supervisor data
	movec	d0,dfc
	move.l	#$4000,d0
	movec	d0,urp
	movec	d0,srp
	move.l	#$8000,d0		; E, 4K pages
	movec	d0,tc
	pflusha

;------------------------------------------------ PFLUSH (An) is per page
	tst.l	($5000).l		; ATC entries for pages 5 and 6
	tst.l	($6000).l
	move.l	#$00007003,($4414).l	; page 5 -> PA $7000
	move.l	#$00008003,($4418).l	; page 6 -> PA $8000
	lea	($5000).l,a0
	pflush	(a0)
	move.l	($5000).l,d0
	chkl	d0,$C3C3C3C3,1		; page 5 walked again
	move.l	($6000).l,d0
	chkl	d0,$B2B2B2B2,2		; page 6: the old entry stands
	pflusha
	move.l	($6000).l,d0
	chkl	d0,$D4D4D4D4,3		; PFLUSHA: all of them
	move.l	#$00005003,($4414).l
	move.l	#$00006003,($4418).l
	pflusha

;------------------------------------- global entries and the N variants
	move.l	#$00005403,($4414).l	; page 5 identity, G = 1
	pflusha
	tst.l	($5000).l		; a global ATC entry
	move.l	#$00007003,($4414).l	; page 5 -> PA $7000
	lea	($5000).l,a0
	pflushn	(a0)
	move.l	($5000).l,d0
	chkl	d0,$A1A1A1A1,4		; PFLUSHN spared the global entry
	pflush	(a0)
	move.l	($5000).l,d0
	chkl	d0,$C3C3C3C3,5		; PFLUSH did not
	move.l	#$00005403,($4414).l
	pflusha
	tst.l	($5000).l
	move.l	#$00007003,($4414).l
	pflushan
	move.l	($5000).l,d0
	chkl	d0,$A1A1A1A1,6		; PFLUSHAN spared it
	pflusha
	move.l	($5000).l,d0
	chkl	d0,$C3C3C3C3,7		; PFLUSHA did not
	move.l	#$00005003,($4414).l
	pflusha

;---------------------------- a store crossing into an invalid page
	move.l	#$11111111,($5FFC).l
	move.l	#$22222222,($6000).l
	move.l	#0,($4418).l		; page 6 invalid
	pflusha
	move.l	#$4418,(fix_addr).l
	move.l	#$00006003,(fix_val).l
	move.l	#$AABBCCDD,d0
	move.l	d0,($5FFE).l		; the fault is on page 6
	moveq	#0,d1
	move.w	(cnt_aerr).l,d1
	chkl	d1,1,8
	moveq	#0,d1
	move.w	(last_ssw).l,d1
	and.l	#$0800,d1
	chkl	d1,$0800,9		; MA
	move.l	(last_fa).l,d1
	chkl	d1,$5FFE,10		; FA: the transfer's first byte
	move.l	($5FFC).l,d1
	chkl	d1,$1111AABB,11
	move.l	($6000).l,d1
	chkl	d1,$CCDD2222,12

;------ CM with register-indirect MOVEMs: the stacked EA is not used
; (M68040UM 8.4.6.7: only mode 6 and PC relative restore it), and two
; MOVEMs back to back: the fault on the first one's last store reports the
; first one's EA although the second may have started (the EA slots)
	move.l	#0,($4420).l		; page 8 invalid
	move.l	#$4420,(fix_addr).l
	move.l	#$00008003,(fix_val).l
	pflusha
	clr.w	(cnt_aerr).l
	clr.l	($7FFC).l
	clr.l	($6F00).l
	clr.l	($6F04).l
	move.l	#$00006F00,(edit_ea).l	; the handler plants a wrong EA
	lea	($7FFC).l,a1		; $7FFC (page 7), then $8000 (page 8): the last store faults
	lea	($6100).l,a2
	moveq	#5,d0
	moveq	#6,d1
	moveq	#7,d2
	moveq	#8,d3
	movem.l	d0-d1,(a1)
	movem.l	d2-d3,(a2)
	clr.l	(edit_ea).l
	moveq	#0,d4
	move.w	(cnt_aerr).l,d4
	chkl	d4,1,20
	move.l	(last_ea).l,d4
	chkl	d4,$7FFC,21		; the first MOVEM's EA
	move.l	($7FFC).l,d4
	chkl	d4,5,22			; restarted at the recomputed EA, not $6F00
	move.l	($8000).l,d4
	chkl	d4,6,23
	move.l	($6100).l,d4
	chkl	d4,7,24
	move.l	($6F00).l,d4
	chkl	d4,0,25			; nothing went to the planted EA

;------ a bitfield spanning two invalid pages: the word first (FA $9FFE),
; then the byte (WinUAE x_get_bitfield order; PLAN D14)
	move.l	#0,($4424).l		; page 9 invalid
	move.l	#0,($4428).l		; page 10 invalid
	pflusha
	clr.w	(cnt_aerr).l
	move.l	#$4424,(fix_addr).l
	move.l	#$00009003,(fix_val).l
	move.l	#$4428,(fix2_addr).l
	move.l	#$0000A003,(fix2_val).l
	bfextu	($9FFE).l{0:24},d4
	move.l	#scratch,(fix2_addr).l
	moveq	#0,d5
	move.w	(cnt_aerr).l,d5
	chkl	d5,1,26			; both pages repaired by the first fault
	move.l	(first_fa).l,d5
	chkl	d5,$9FFE,27		; the word was read first

;------------- MOVEM -(An) whose last (lowest) store faults: CM, An kept
	move.l	#$4414,(fix_addr).l
	move.l	#$00005003,(fix_val).l
	move.l	#0,($4414).l		; page 5 invalid
	pflusha
	clr.w	(cnt_aerr).l
	lea	($6008).l,a1
	moveq	#1,d0
	moveq	#2,d1
	moveq	#3,d2
	movem.l	d0-d2,-(a1)		; d2 -> $6004, d1 -> $6000, d0 -> $5FFC faults
	moveq	#0,d3
	move.w	(cnt_aerr).l,d3
	chkl	d3,1,13
	moveq	#0,d3
	move.w	(last_ssw).l,d3
	and.l	#$1000,d3
	chkl	d3,$1000,14		; CM (M68040UM 8.4.6.2)
	move.l	a1,d3
	chkl	d3,$5FFC,15		; the restart decremented once
	move.l	($5FFC).l,d3
	chkl	d3,1,16
	move.l	($6000).l,d3
	chkl	d3,2,17
	move.l	($6004).l,d3
	chkl	d3,3,18

	moveq	#0,d0
	movec	d0,tc
	pflusha
	move.w	#$600D,(DONEREG).l
halt:	bra.s	halt

h_aerr:
	movem.l	d0-d1/a0,-(sp)
	cmpi.w	#$7008,$12(sp)		; format $7, vector 2
	bne	unexp
	move.w	$18(sp),(last_ssw).l	; SSW
	move.l	$20(sp),(last_fa).l	; FA
	move.l	$14(sp),(last_ea).l	; EA
	tst.w	(cnt_aerr).l
	bne.s	h_nfirst
	move.l	$20(sp),(first_fa).l
h_nfirst:
	tst.l	(edit_ea).l
	beq.s	h_nedit
	move.l	(edit_ea).l,$14(sp)	; a handler editing the stacked EA
h_nedit:
	movea.l	(fix_addr).l,a0
	move.l	(fix_val).l,(a0)
	movea.l	(fix2_addr).l,a0
	move.l	(fix2_val).l,(a0)
	pflusha
	move.w	$1E(sp),d0		; WB1S valid: the handler does the write
	btst	#7,d0
	beq.s	h_nowb
	movea.l	$34(sp),a0
	move.l	$38(sp),(a0)
h_nowb:
	addq.w	#1,(cnt_aerr).l
	movem.l	(sp)+,d0-d1/a0
	rte

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h1:	bra.s	h1
unexp:
	move.w	#$0099,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h2:	bra.s	h2
