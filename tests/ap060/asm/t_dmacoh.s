; The AP68060 in Minimig: DMA into Fast RAM against the Fast RAM port's own
; cache.  Akiko and CDTV DMA write Zorro RAM through chipdma_arb and
; ddram_ctrl's DMA port; the Fast RAM port (ap060_fastram) keeps line
; buffers and an 8K cache of that DDR3 below the 68060, which the 68060's
; cache instructions cannot reach.  The bench's DMA master ($F124/$F126)
; writes words of the card; $F12A counts the writes that reached DDR3.
; As exec does around DMA (CachePreDMA/CachePostDMA), the program pushes
; the 68060's data cache before and invalidates it after; then it must
; read what the DMA wrote.
;   1  a line read (cached in the 68060 and in the port), then DMA over
;      both its first long words: the new data
;   2  sixteen DMA writes in a row over two lines read before: all new
;      (a clear per write, none missed when they come close together)
;   3  the port's cache refills afterwards: the same lines read twice more
;      return the DMA data, and a CPU write over them reads back

FAST    equ     $200000
BUF     equ     FAST+$18000     ; card word offset $C000
BUFW    equ     $C000
DMAOFF  equ     $f124
DMADAT  equ     $f126
DMACNT  equ     $f12a

ck      macro                   ; \1 operand, \2 expected (with #), \3 test
        cmp.l   \2,\1
        beq.s   ok\@
        move.w  #\3,($f100).l
        bra.w   fail
ok\@:
        endm

; a DMA write of the word \2 at card word \1, waited for
dmaw    macro
        move.w  (DMACNT).l,d7
        move.w  #\2,(DMADAT).l
        move.w  #\1,(DMAOFF).l
wt\@:   cmp.w   (DMACNT).l,d7
        beq.s   wt\@
        endm

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

        org     $400
start:
        move.w  #$2700,sr
        move.b  #$20,($e80048).l        ; Zorro II RAM at $200000
        move.l  #$A0808000,d0           ; EDC, ESB, EBC, EIC
        movec   d0,cacr

;---------------------------------------------------------------- test 1
        lea     (BUF).l,a0
        move.l  #$11223344,(a0)
        move.l  #$55667788,4(a0)
        cpusha  dc                      ; CachePreDMA: pushed to memory
        move.l  (a0),d0                 ; cached in the 68060 and in the port
        ck      d0,#$11223344,1
        move.l  4(a0),d0
        ck      d0,#$55667788,2
        dmaw    BUFW,$AABB
        dmaw    BUFW+1,$CCDD
        dmaw    BUFW+2,$EEFF
        dmaw    BUFW+3,$0102
        cinva   dc                      ; CachePostDMA
        move.l  (a0),d0
        ck      d0,#$AABBCCDD,3
        move.l  4(a0),d0
        ck      d0,#$EEFF0102,4

;---------------------------------------------------------------- test 2
        lea     (BUF+$100).l,a0
        moveq   #7,d1
fill:   move.l  #$CAFEF00D,(a0)+
        dbra    d1,fill
        cpusha  dc
        lea     (BUF+$100).l,a0
        moveq   #7,d1
rd1:    move.l  (a0)+,d0                ; both lines into the caches
        ck      d0,#$CAFEF00D,10
        dbra    d1,rd1
        moveq   #0,d2                   ; sixteen DMA writes, back to back
dmal:   move.w  #BUFW+$80,d3
        add.w   d2,d3
        move.w  d2,d4
        or.w    #$5A00,d4
        move.w  d4,(DMADAT).l
        move.w  d3,(DMAOFF).l
        addq.w  #1,d2
        cmp.w   #16,d2
        bne.s   dmal
wt16:   move.w  (DMACNT).l,d0           ; all of them in DDR3
        cmp.w   #4+16,d0
        bne.s   wt16
        cinva   dc
        lea     (BUF+$100).l,a0
        moveq   #0,d2
rd2:    move.w  (a0)+,d0
        move.w  d2,d4
        or.w    #$5A00,d4
        cmp.w   d4,d0
        beq.s   rd2ok
        move.w  #11,($f100).l
        bra.w   fail
rd2ok:  addq.w  #1,d2
        cmp.w   #16,d2
        bne.s   rd2

;---------------------------------------------------------------- test 3
        moveq   #1,d5
again:  cinva   dc
        lea     (BUF).l,a0
        move.l  (a0),d0
        ck      d0,#$AABBCCDD,20
        move.l  (BUF+$100).l,d0
        ck      d0,#$5A005A01,21
        dbra    d5,again
        move.l  #$13579BDF,(a0)
        cpusha  dc
        move.l  (a0),d0
        ck      d0,#$13579BDF,22

        move.w  #$600D,($f102).l
done:   bra.s   done

fail:   move.w  #$BAD0,($f102).l
halt:   bra.s   halt
