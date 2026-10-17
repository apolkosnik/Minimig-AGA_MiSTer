; AP020 Fast RAM cache (ap020_fastram_fe: 8 KiB, 512 lines of 16 bytes,
; direct mapped on the DDR3 line, write through, behind the two line buffers)
; assembled with vasmm68k_mot -Fbin -m68020
;
; Runs from chip RAM; the bench (tb_ap020_wrapchip.sv, FASTRAM=1) offers a
; 2 MB Zorro II memory card at $200000.
;
;   - a write followed at once by a read of the same line, the line held by
;     the cache and not by a line buffer (the cache's write update and the
;     lookup meet in consecutive clocks)
;   - two lines 8 KiB apart (the same cache index) evicting each other, with
;     writes to the one not held
;   - code in Fast RAM changed by a byte write and run again: with the
;     on-chip caches off (only the buffers and this cache hold it) and on
;     (after a CACR clear, which also sweeps this cache)
;   - reads straight after a CACR clear, while the sweep runs
;   - random byte/word/longword reads and writes at any alignment in a
;     16 KiB window (twice the cache) checked against a copy in chip RAM,
;     which is never cached; caches off, then on with bursts and periodic
;     CACR clears; then a full compare of the window
;
; protocol with the bench:
;   word write to $F100 = failing test number
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed

FAILREG	equ	$F100
DONEREG	equ	$F102
FAST	equ	$200000
WIN	equ	FAST+$10000	; the random test window (16 KiB)
SHADOW	equ	$8000		; its copy in chip RAM
WINSZ	equ	$4000

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
	dc.l	$3400		; initial ISP
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	moveq	#0,d0
	movec	d0,cacr
	move.b	#$20,$E80048		; Zorro II memory card: configure (base $200000)

;---------------------------------------------------------------- write then read, line in the cache only
	lea	FAST+$20000,a0		; line A
	lea	FAST+$20040,a1		; line B: another index
	move.l	#$11111111,(a0)
	move.l	#$12121212,4(a0)
	move.l	(a0),d0			; A into the data buffer and the cache
	move.l	(a1),d0			; B into the buffer: A only in the cache
	move.l	#$22222222,(a0)		; write update of the cached A
	move.l	(a0),d0			; at once: buffer miss, cache lookup
	chkl	d0,$22222222,1
	move.l	4(a0),d0
	chkl	d0,$12121212,2
	move.l	(a1),d0			; B again
	move.b	#$33,5(a0)		; byte into the cached A
	move.l	4(a0),d0
	chkl	d0,$12331212,3
	move.l	(a1),d0
	move.w	#$4444,2(a0)		; word, then the other longword of the line
	move.l	12(a0),d1
	move.l	(a0),d0
	chkl	d0,$22224444,4
	move.l	(a1),d0
	move.l	#$55667788,1(a0)	; misaligned: two portions
	move.l	(a0),d0
	chkl	d0,$22556677,5
	move.l	4(a0),d0
	chkl	d0,$88331212,6

;---------------------------------------------------------------- two lines on one index
	lea	FAST+$30000,a0		; X
	lea	FAST+$32000,a1		; Y = X + 8 KiB: the same index
	move.l	#$AAAA0000,(a0)
	move.l	#$BBBB0000,(a1)
	move.l	(a0),d0			; X cached
	move.l	(a1),d0			; Y replaces it
	move.l	(a0),d0			; X again, from DDR3
	chkl	d0,$AAAA0000,10
	move.l	#$CCCC0000,(a1)		; Y not cached: DDR3 only
	move.l	(a1),d0
	chkl	d0,$CCCC0000,11
	move.l	(a0),d0
	chkl	d0,$AAAA0000,12
	move.l	#$DDDD0000,(a0)		; X write, then Y read, then X read
	move.l	(a1),d0
	chkl	d0,$CCCC0000,13
	move.l	(a0),d0
	chkl	d0,$DDDD0000,14

;---------------------------------------------------------------- code changed in Fast RAM
	lea	sub(pc),a0
	lea	FAST+$31000,a1
	move.l	(a0)+,(a1)+		; moveq #1,d0 ; rts
	move.w	#$4E75,FAST+$31200	; an rts in another line
	moveq	#0,d0
	jsr	FAST+$31000
	chkl	d0,1,20
	moveq	#0,d0
	jsr	FAST+$31000		; from the program buffer
	lea	FAST+$31100,a2
	tst.l	(a2)			; data buffer elsewhere
	jsr	FAST+$31200		; program buffer elsewhere (rts only)
	move.b	#2,FAST+$31001		; moveq #2: write through to the cache
	moveq	#0,d0
	jsr	FAST+$31000		; caches off: from this cache
	chkl	d0,2,21
	; on-chip caches on, then the code changes again: CACR clear
	move.l	#$0009,d0		; E, C: on, cleared
	movec	d0,cacr
	moveq	#0,d0
	jsr	FAST+$31000
	jsr	FAST+$31000
	chkl	d0,2,22
	move.b	#3,FAST+$31001
	movec	cacr,d1
	or.w	#$0008,d1		; C: clear the caches (and sweep this one)
	movec	d1,cacr
	moveq	#0,d0
	jsr	FAST+$31000		; during the sweep: from DDR3
	chkl	d0,3,23
	moveq	#0,d0
	movec	d0,cacr

;---------------------------------------------------------------- reads during the sweep
	lea	FAST+$34000,a0
	moveq	#63,d1
	move.l	#$01020304,d0
sw1:	move.l	d0,(a0)+
	add.l	#$01010101,d0
	dbf	d1,sw1
	lea	FAST+$34000,a0
	moveq	#63,d1
sw2:	tst.l	(a0)+			; cache the block
	dbf	d1,sw2
	move.l	#$0008,d0		; C: the sweep starts
	movec	d0,cacr
	lea	FAST+$34000,a0
	moveq	#63,d1
	move.l	#$01020304,d0
sw3:	cmp.l	(a0)+,d0
	bne	sw_bad
	add.l	#$01010101,d0
	dbf	d1,sw3
	bra.s	sw_ok
sw_bad:	failt	30
sw_ok:

;---------------------------------------------------------------- random reads and writes
	; the window and its copy start equal
	lea	WIN,a0
	lea	SHADOW,a1
	move.w	#WINSZ/4-1,d1
	move.l	#$9E3779B9,d0
ri:	move.l	d0,(a0)+
	move.l	d0,(a1)+
	rol.l	#5,d0
	add.l	#$7F4A7C15,d0
	dbf	d1,ri
	moveq	#0,d0
	movec	d0,cacr
	move.l	#$C0FFEE01,d6		; LFSR
	moveq	#40,d4			; failure numbers 40 (mismatch), 41 (window)
	move.w	#2999,d5
	bsr	rnd_test
	move.l	#$0009,d0		; caches on (bursts), cleared
	movec	d0,cacr
	moveq	#50,d4
	move.w	#2999,d5
	bsr	rnd_test
	moveq	#0,d0
	movec	d0,cacr

	move.w	#$600D,DONEREG
	stop	#$2700

; d5+1 operations; d6 the LFSR; d4 the failure number base
rnd_test:
	lea	WIN,a2
	lea	SHADOW,a3
rt_loop:
	lsr.l	#1,d6			; Galois LFSR
	bcc.s	rt_n1
	eor.l	#$80200003,d6
rt_n1:	move.l	d6,d0
	and.l	#WINSZ-8,d0		; a multiple of 8 below the end
	move.l	d6,d1
	swap	d1
	and.w	#3,d1
	add.w	d1,d0			; any alignment, 4 bytes stay inside
	move.l	d6,d1
	rol.l	#7,d1
	eor.l	#$5A5AC3C3,d1		; data
	move.l	d6,d2
	lsr.l	#8,d2
	lsr.l	#8,d2
	lsr.l	#4,d2
	and.w	#7,d2			; operation
	add.w	d2,d2
	move.w	rt_tab(pc,d2.w),d2
	jmp	rt_tab(pc,d2.w)
rt_tab:	dc.w	rt_wb-rt_tab,rt_ww-rt_tab,rt_wl-rt_tab,rt_rb-rt_tab
	dc.w	rt_rw-rt_tab,rt_rl-rt_tab,rt_wl-rt_tab,rt_x-rt_tab
rt_wb:	move.b	d1,(a2,d0.l)
	move.b	d1,(a3,d0.l)
	bra.s	rt_next
rt_ww:	move.w	d1,(a2,d0.l)
	move.w	d1,(a3,d0.l)
	bra.s	rt_next
rt_wl:	move.l	d1,(a2,d0.l)
	move.l	d1,(a3,d0.l)
	bra.s	rt_next
rt_rb:	move.b	(a2,d0.l),d2
	cmp.b	(a3,d0.l),d2
	bne.s	rt_bad
	bra.s	rt_next
rt_rw:	move.w	(a2,d0.l),d2
	cmp.w	(a3,d0.l),d2
	bne.s	rt_bad
	bra.s	rt_next
rt_x:	move.l	d6,d2			; now and then a CACR clear, else a read
	and.w	#$0F00,d2
	bne.s	rt_rl
	movec	cacr,d2
	or.w	#$0008,d2
	movec	d2,cacr
rt_rl:	move.l	(a2,d0.l),d2
	cmp.l	(a3,d0.l),d2
	bne.s	rt_bad
rt_next:
	dbf	d5,rt_loop
	; the whole window against the copy
	lea	WIN,a2
	lea	SHADOW,a3
	move.w	#WINSZ/4-1,d5
rt_cmp:	cmpm.l	(a2)+,(a3)+
	bne.s	rt_badw
	dbf	d5,rt_cmp
	rts
rt_bad:	move.w	d4,d7
	bra	fail_all
rt_badw:
	move.w	d4,d7
	addq.w	#1,d7
	bra	fail_all

	cnop	0,4
sub:	moveq	#1,d0
	rts

fail_all:
	moveq	#0,d0
	movec	d0,cacr
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
fa:	bra.s	fa

unexp:
	move.w	#$FF,d7
	bra	fail_all
