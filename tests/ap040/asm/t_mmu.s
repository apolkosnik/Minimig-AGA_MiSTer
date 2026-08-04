; AP040 milestone E MMU self test
; assembled with vasmm68k_mot -Fbin -m68040
;
; testbench protocol: $F100 fail number, $F102 result magic
;
; memory map (all physical = logical except where noted):
;   $0000 vectors, $0400 code, $3400 ISP top, $3C00 USP top
;   $4000 root table, $4200 pointer table, $4400 page table (64 x 4K pages)
;   page  8 ($8000) write protected
;   page  9 ($9000) supervisor only
;   page 10 ($A000) invalid, fixed by the access error handler
;   page 11 ($B000) remapped to physical $C000
;   page 13 ($D000) invalid, fixed on an instruction fetch fault

FAILREG		equ	$F100
DONEREG		equ	$F102

cnt_aerr	equ	$3600
expect_fa	equ	$3604
fix_addr	equ	$3608
fix_val		equ	$360C
cnt_stub	equ	$3614
uret		equ	$3618

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
	dc.l	h_aerr		; 2 access error
	rept	30
	dc.l	unexp		; 3-32
	endr
	dc.l	h_utrap		; 33 TRAP #1
	rept	222
	dc.l	unexp		; 34-255
	endr

	org	$400
start:
	clr.w	(cnt_aerr).l
	clr.w	(cnt_stub).l

;----------------------------------------------------------------- tables
	lea	($4400).l,a0
	moveq	#0,d0
	moveq	#63,d1
tloop:
	move.l	d0,d2
	lsl.l	#8,d2
	lsl.l	#4,d2		; i << 12
	addq.l	#3,d2		; resident
	move.l	d2,(a0)+
	addq.l	#1,d0
	dbra	d1,tloop

	move.l	#$00008007,($4420).l	; page 8: write protected
	move.l	#$00009083,($4424).l	; page 9: supervisor only
	move.l	#0,($4428).l		; page 10: invalid
	move.l	#$0000C003,($442C).l	; page 11 -> physical $C000
	move.l	#0,($4434).l		; page 13: invalid

	move.l	#$00004203,($4000).l	; root entry 0 -> pointer table
	move.l	#$00004403,($4200).l	; pointer entry 0 -> page table

;----------------------------------------------- pre-place physical data
	move.l	#$11112222,($3000).l
	move.l	#$0A0A0A0A,($A000).l
	move.l	#$09090909,($9000).l
	move.l	#$AAAA1111,($5000).l
	move.l	#$BBBB2222,($E000).l
	move.w	#$5279,($D000).l	; addq.w #1,(cnt_stub).l
	move.l	#cnt_stub,($D002).l
	move.w	#$4E75,($D006).l	; rts

;----------------------------------------------------------------- enable
	move.l	#$4000,d0
	movec	d0,urp
	movec	d0,srp
	move.l	#$8000,d0	; E=1, 4K pages
	movec	d0,tc

;----------------------------------------------------------- translation
	move.l	($3000).l,d0
	chkl	d0,$11112222,1

	move.l	#$DEAD1234,($B000).l	; lands at physical $C000
	move.l	($C000).l,d0
	chkl	d0,$DEAD1234,2
	move.l	($B000).l,d0
	chkl	d0,$DEAD1234,3

;----------------------------------------------------------- history bits
	move.l	($4000).l,d0
	and.l	#8,d0
	chkl	d0,8,4			; root descriptor U set

	move.l	#$CAFE0505,($5000).l
	move.l	($4414).l,d0
	and.l	#$10,d0
	chkl	d0,$10,5		; page 5 modified

	tst.l	($6000).l
	move.l	($4418).l,d0
	and.l	#$10,d0
	chkl	d0,0,6			; page 6 read only: M clear
	move.l	($4418).l,d0
	and.l	#8,d0
	chkl	d0,8,7			; but U set

;----------------------------------------------------------------- PTEST
	moveq	#5,d0
	movec	d0,dfc
	lea	($5000).l,a0
	ptestr	(a0)
	movec	mmusr,d0
	chkl	d0,$00005011,8		; PA $5000, M, resident

	; PTEST installs its successful search in the selected ATC.  Changing
	; the descriptor alone therefore leaves the probed mapping cached.
	pflusha
	lea	($E000).l,a0
	ptestr	(a0)
	move.l	#$00005003,($4438).l	; page 14 now points at physical $5000
	move.l	($E000).l,d0
	chkl	d0,$BBBB2222,36		; PTEST-installed identity mapping is stale

	; every write to TC flushes both ATCs, even if its value is unchanged
	move.l	#$8000,d0
	movec	d0,tc
	move.l	($E000).l,d0
	chkl	d0,$CAFE0505,37		; descriptor remap visible without PFLUSH
	move.l	#$0000E003,($4438).l
	pflusha

;----------------------------------------------- write protection fault
	move.l	#$8000,(expect_fa).l
	move.l	#$4420,(fix_addr).l
	move.l	#$8003,(fix_val).l
	move.l	#$FEED0808,($8000).l	; faults, handler unprotects, restarts
	move.l	($8000).l,d0
	chkl	d0,$FEED0808,9
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,1,10

;----------------------------------------------------- invalid data page
	move.l	#$A000,(expect_fa).l
	move.l	#$4428,(fix_addr).l
	move.l	#$A003,(fix_val).l
	move.l	($A000).l,d0
	chkl	d0,$0A0A0A0A,11
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,2,12

;------------------------------------------------ instruction fetch fault
	move.l	#$D000,(expect_fa).l
	move.l	#$4434,(fix_addr).l
	move.l	#$D003,(fix_val).l
	jsr	($D000).l		; target page invalid: fetch fault
	move.w	(cnt_stub).l,d0
	and.l	#$FFFF,d0
	chkl	d0,1,13
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,3,14

;------------------------------------------- user access to a super page
	movea.l	#$3C00,a0
	movec	a0,usp
	move.l	#ucont,(uret).l
	move.l	#$9000,(expect_fa).l
	move.l	#$4424,(fix_addr).l
	move.l	#$9003,(fix_val).l
	move.w	#$0000,-(sp)
	pea	user_code(pc)
	move.w	#$0000,-(sp)
	rte

user_code:
	move.l	($9000).l,d0	; faults: S page from user mode
	trap	#1

ucont:
	chkl	d0,$09090909,15
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,4,16

;------------------------------- RTE to user: fetch uses the user root
; a separate user root maps VA $7000 -> PA $F000 (moveq/trap) while the
; supervisor root keeps identity, where $7000 holds ILLEGAL. The first
; fetch after RTE belongs to the restored user context, so it must
; translate through URP; with a supervisor-FC fetch this executes the
; ILLEGAL instead and the unexpected-exception handler fails the test.
	lea	($4C00).l,a0
	moveq	#0,d0
	moveq	#63,d1
utloop:
	move.l	d0,d2
	lsl.l	#8,d2
	lsl.l	#4,d2
	addq.l	#3,d2
	move.l	d2,(a0)+
	addq.l	#1,d0
	dbra	d1,utloop
	move.l	#$0000F003,($4C1C).l	; user VA page 7 -> PA $F000
	move.l	#$00004A03,($4800).l
	move.l	#$00004C03,($4A00).l
	move.w	#$702A,($F000).l	; moveq #42,d0
	move.w	#$4E41,($F002).l	; trap #1
	move.w	#$4AFC,($7000).l	; illegal via the supervisor map
	move.l	#$4800,d0
	movec	d0,urp
	pflusha
	move.l	#ucont2,(uret).l
	moveq	#0,d0
	move.w	#$0000,-(sp)
	pea	($7000).l
	move.w	#$0000,-(sp)
	rte

ucont2:
	chkl	d0,42,33		; ran the user-mapped code
	move.l	#$4000,d0
	movec	d0,urp			; restore the shared root
	pflusha

;---------------------------- high VA walk: nonzero root/pointer indexes
; VA $1E0C3000: root index 15, pointer index 3, page index 3. The page
; table sits at $4D00 (bit 8 set) to prove the 256-byte table base mask.
	move.l	#$00004E03,($403C).l	; root[15] -> pointer table $4E00
	move.l	#$00004D03,($4E0C).l	; pointer[3] -> page table $4D00
	move.l	#$0000E003,($4D0C).l	; page[3] -> PA $E000
	move.l	($1E0C3000).l,d0
	chkl	d0,$BBBB2222,34
	move.l	#$FEED5678,($1E0C3004).l
	move.l	($E004).l,d0
	chkl	d0,$FEED5678,35

;------------------------------------------------------------ TTR bypass
	move.l	#0,($4414).l	; page 5 invalid
	pflusha
	move.l	#$0000C000,d0	; DTT0: base $00, mask $00, both modes
	movec	d0,dtt0
	move.l	($5000).l,d0	; transparent: no fault, no walk
	chkl	d0,$CAFE0505,17
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,4,18
	lea	($5000).l,a0
	ptestr	(a0)
	movec	mmusr,d0
	chkl	d0,$00005003,19		; transparent + resident

	; PTESTW reports a write-protected transparent translation as B
	move.l	#$0000C004,d0
	movec	d0,dtt0
	ptestw	(a0)
	movec	mmusr,d0
	chkl	d0,$00000400,38

	; DFC program space selects ITT rather than DTT during PTEST
	moveq	#0,d0
	movec	d0,dtt0
	move.l	#$0000C000,d0
	movec	d0,itt0
	moveq	#6,d0
	movec	d0,dfc
	ptestr	(a0)
	movec	mmusr,d0
	chkl	d0,$00005003,39
	moveq	#0,d0
	movec	d0,itt0
	moveq	#5,d0
	movec	d0,dfc
	moveq	#0,d0
	movec	d0,dtt0
	move.l	#$00005003,($4414).l
	pflusha

;--------------------------------------- ATC caching and page PFLUSH
	move.l	($5000).l,d0	; walk and cache the mapping
	chkl	d0,$CAFE0505,20
	move.l	#$0000E003,($4414).l	; remap page 5 without a flush
	move.l	($5000).l,d0
	chkl	d0,$CAFE0505,21		; stale ATC entry still used
	lea	($5000).l,a0
	pflush	(a0)
	move.l	($5000).l,d0
	chkl	d0,$BBBB2222,22		; new mapping after the flush
	move.l	#$00005003,($4414).l
	pflusha

;----------------------------------------- MOVEM restart across a fault
	; registers to memory into a page that faults mid-transfer: the
	; 68040 restart model re-executes the whole MOVEM after the fix
	move.l	#$00007000,(expect_fa).l
	move.l	#$441C,(fix_addr).l	; page 7 descriptor
	move.l	#$7003,(fix_val).l
	move.l	#0,($441C).l		; make page 7 invalid
	pflusha
	move.l	#$AAAA0001,d1
	move.l	#$BBBB0002,d2
	move.l	#$CCCC0003,d3
	lea	($6FFC).l,a0		; last longword of valid page 6
	movem.l	d1-d3,(a0)		; d1 at $6FFC, d2/d3 fault into page 7
	move.l	($6FFC).l,d0
	chkl	d0,$AAAA0001,24
	move.l	($7000).l,d0
	chkl	d0,$BBBB0002,25
	move.l	($7004).l,d0
	chkl	d0,$CCCC0003,26
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,5,27

	; memory to registers with a fault on the second page
	move.l	#0,($441C).l
	pflusha
	moveq	#0,d1
	moveq	#0,d2
	moveq	#0,d3
	movem.l	(a0),d1-d3
	chkl	d1,$AAAA0001,28
	chkl	d2,$BBBB0002,29
	chkl	d3,$CCCC0003,30
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,6,31

;----------------------------------------------------------------- 8K pages
	moveq	#0,d0
	movec	d0,tc		; MMU off while rebuilding tables
	pflusha

	; page table: 32 entries of 8K covering LA 0-$3FFFF, identity
	lea	($4400).l,a0
	moveq	#0,d0
	moveq	#31,d1
t8loop:
	move.l	d0,d2
	lsl.l	#8,d2
	lsl.l	#5,d2		; i << 13
	addq.l	#3,d2
	move.l	d2,(a0)+
	addq.l	#1,d0
	dbra	d1,t8loop

	; entry 5 (LA $A000-$BFFF) remapped to PA $C000-$DFFF
	move.l	#$0000C003,($4414).l
	; pre-place physical data through the identity map (MMU off)
	move.l	#$08081111,($C120).l	; seen through LA $A120 (LA12=0)
	move.l	#$08082222,($D120).l	; seen through LA $B120 (LA12=1)

	move.l	#$C000,d0	; E=1, P=1: 8K pages
	movec	d0,tc

	move.l	($3000).l,d0	; identity page, LA12=1 within its 8K page
	chkl	d0,$11112222,24
	move.l	($A120).l,d0
	chkl	d0,$08081111,25
	move.l	($B120).l,d0	; same 8K page, LA bit 12 set
	chkl	d0,$08082222,26

	lea	($A000).l,a0	; PTEST under 8K paging
	ptestr	(a0)
	movec	mmusr,d0
	and.l	#$FFFFF001,d0
	chkl	d0,$0000C001,27
	lea	($B000).l,a0
	ptestr	(a0)
	movec	mmusr,d0
	and.l	#$FFFFF001,d0
	chkl	d0,$0000D001,28

	; fault and restart under 8K paging
	move.l	#$0000E000,(expect_fa).l
	move.l	#$441C,(fix_addr).l	; entry 7: LA $E000-$FFFF
	move.l	#$0000E003,(fix_val).l
	move.l	#0,($441C).l
	pflusha
	move.l	#$0E0E0E0E,d1
	move.l	d1,($E000).l	; faults, handler fixes, restart writes
	move.l	($E000).l,d0
	chkl	d0,$0E0E0E0E,29
	move.w	(cnt_aerr).l,d0
	and.l	#$FFFF,d0
	chkl	d0,7,30

;----------------------------------------------------------------- disable
	moveq	#0,d0
	movec	d0,tc
	move.l	($3000).l,d0
	chkl	d0,$11112222,23

	move.w	#$600D,(DONEREG).l
	stop	#$2700

;----------------------------------------------------------------- handlers
h_aerr:
	cmpi.w	#$7008,6(sp)	; format $7, vector 2
	bne	hfail
	movem.l	d0/a0,-(sp)
	move.l	$1C(sp),d0	; fault address (frame offset $14)
	cmp.l	(expect_fa).l,d0
	bne	hfail
	move.w	$14(sp),d0	; SSW (frame offset $C)
	and.w	#$0400,d0	; ATC fault bit
	beq	hfail
	movea.l	(fix_addr).l,a0
	move.l	(fix_val).l,(a0)
	pflusha
	addq.w	#1,(cnt_aerr).l
	movem.l	(sp)+,d0/a0
	rte

h_utrap:
	ori.w	#$2000,(sp)	; back to supervisor
	move.l	(uret).l,2(sp)
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
