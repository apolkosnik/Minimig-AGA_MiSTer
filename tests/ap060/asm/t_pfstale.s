; The AP68060 in Minimig: the Fast RAM port's prefetch.  A cache miss in
; the port's 8K cache reads its line and the next three in one DDR3 burst
; and allocates all four; the bench ($F130) holds the three prefetched
; lines back so that something can happen while they are on their way.
; Data caches write through (TC = 0: the default cache mode), so a write
; reaches the port at once.
;   A  a line read starts a prefetch; a write to the third line of the
;      burst is posted while it is held back: after the burst, that line
;      must read back the write, not what DDR3 held when the burst was read
;   B  the same with a DMA write (ddram_ctrl's DMA port) to a prefetched
;      line: after it completes, the line reads the DMA's data (the DDR3
;      arbiter keeps the DMA out until the burst's data is all in, and
;      the DMA's cache clear drops what the port has not yet allocated)
;   C  sixteen lines of a pattern, read twice through the port (the second
;      time from its cache, prefetched lines among them): all as written

FAST    equ     $200000
BUF     equ     FAST+$19000             ; card word $C800
BUF2    equ     FAST+$19100             ; card word $C880
BUF3    equ     FAST+$19400
DMAOFF  equ     $f124
DMADAT  equ     $f126
DMACNT  equ     $f12a
PFGAP   equ     $f130

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

;---------------------------------------------------------------- A
        lea     (BUF).l,a0
        move.l  #$10101010,(a0)
        move.l  #$20202020,16(a0)
        move.l  #$11111111,32(a0)       ; the line the write will hit
        move.l  #$40404040,48(a0)
        nop                             ; (the writes are out)
        cinva   dc
        move.w  #3000,(PFGAP).l         ; the next burst's prefetched lines late
        tst.w   ($f100).l               ; (a chip read: the posted write is done)
        move.l  (a0),d0                 ; the miss: its line, then three held
        cmp.l   #$10101010,d0
        bne.w   fa1
        move.l  #$22222222,32(a0)       ; posted while they are held
        nop
        move.l  16(a0),d0               ; (waits for the burst) prefetched
        cmp.l   #$20202020,d0
        bne.w   fa2
        cinva   dc
        move.l  32(a0),d0
        cmp.l   #$22222222,d0
        bne.w   fa3
        move.l  48(a0),d0
        cmp.l   #$40404040,d0
        bne.w   fa4

;---------------------------------------------------------------- B
        lea     (BUF2).l,a1
        move.l  #$50505050,(a1)
        move.l  #$33333333,32(a1)       ; card word $C890: the DMA's target
        nop
        cinva   dc
        move.w  #40000,(PFGAP).l
        tst.w   ($f100).l
        move.l  (a1),d0                 ; the miss and its held prefetch
        cmp.l   #$50505050,d0
        bne.w   fb1
        move.w  (DMACNT).l,d7
        move.w  #$ABCD,(DMADAT).l
        move.w  #$C890,(DMAOFF).l       ; a DMA write of a prefetched line
wb:     cmp.w   (DMACNT).l,d7
        beq.s   wb
        cinva   dc
        move.l  32(a1),d0
        cmp.l   #$ABCD3333,d0
        bne.w   fb2

;---------------------------------------------------------------- C
        lea     (BUF3).l,a2
        move.l  a2,a0
        move.w  #63,d1
        move.l  #$01234567,d2
cfill:  move.l  d2,(a0)+
        add.l   #$11111111,d2
        dbra    d1,cfill
        nop
        moveq   #1,d5                   ; twice: DDR3, then the port's cache
cpass:  cinva   dc
        move.l  a2,a0
        move.w  #63,d1
        move.l  #$01234567,d2
cchk:   cmp.l   (a0)+,d2
        bne.w   fc
        add.l   #$11111111,d2
        dbra    d1,cchk
        dbra    d5,cpass

        move.w  #$600D,($f102).l
done:   bra.s   done

fa1:    move.w  #1,($f100).l
        bra.s   fail
fa2:    move.w  #2,($f100).l
        bra.s   fail
fa3:    move.w  #3,($f100).l
        bra.s   fail
fa4:    move.w  #4,($f100).l
        bra.s   fail
fb1:    move.w  #10,($f100).l
        bra.s   fail
fb2:    move.w  #11,($f100).l
        bra.s   fail
fc:     move.w  #20,($f100).l
fail:   move.w  #$BAD0,($f102).l
        bra.s   done
