; The AP68060 in Minimig: DMA after the processor's posted Fast RAM writes.
; Fast RAM writes go through the Fast RAM port's own queue to DDR3, not
; through ddram_ctrl, so a DMA (ddram_ctrl's DMA port: Akiko, CDTV) must
; wait for the writes the processor queued before it.  The bench holds the
; port's DDR3 writes ($F11E) until a DMA request is pending, as a busy DDR3
; would.  (The arming write goes over the chip bus, posted, while Fast RAM
; writes have their own port: a chip read after it waits until it is
; done.)  From the bus audit:
;   A  the processor writes a line and pushes it (CPUSHA): a DMA read of
;      it must see the new data, not what DDR3 held before
;   B  the processor writes a line (four long words queued), then a DMA
;      writes a word of the last: the DMA's data must stay (the older
;      processor write must not land after it)
; Each DMA is waited for ($F12A counts them); a read's data is at $F128.

FAST    equ     $200000
BUF     equ     FAST+$18000             ; card word $C000
DMACNT  equ     $f12a

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
        ifd     ONLYB
        lea     (BUF).l,a0
        bra.w   part_b
        endif
        move.w  #1,($f11e).l            ; hold the port's writes
        tst.w   ($f100).l               ; (a chip read: the posted write is done)
        lea     (BUF).l,a0
        move.l  #$11111111,(a0)
        move.l  #$22222222,4(a0)
        move.l  #$33333333,8(a0)
        move.l  #$44444444,12(a0)
        cpusha  dc                      ; CachePreDMA: pushed (queued, held)
        move.w  (DMACNT).l,d7
        move.w  #1,($f11c).l            ; a DMA read ...
        move.w  #$c006,($f124).l        ; ... of card word $C006 (BUF+12)
wa:     cmp.w   (DMACNT).l,d7
        beq.s   wa
        cmp.w   #$4444,($f128).l
        beq.s   a_ok
        move.w  #1,($f100).l
        bra.w   fail
a_ok:

;---------------------------------------------------------------- B
part_b:
        move.w  #1,($f11e).l            ; (the hold is once: arm it again)
        tst.w   ($f100).l
        move.l  #$55555555,16(a0)       ; a line: four long words queued
        move.l  #$66666666,20(a0)
        move.l  #$77777777,24(a0)
        move.l  #$88888888,28(a0)       ; card words $C00E/$C00F last
        cpusha  dc                      ; pushed (queued, held)
        move.w  (DMACNT).l,d7
        move.w  #$AAAA,($f126).l
        move.w  #$c00e,($f124).l        ; then a DMA write of word $C00E
wb:     cmp.w   (DMACNT).l,d7
        beq.s   wb
        cinva   dc                      ; CachePostDMA
        move.l  28(a0),d0
        cmp.l   #$AAAA8888,d0
        beq.s   b_ok
        move.w  #2,($f100).l
        bra.w   fail
b_ok:
        move.w  #$600D,($f102).l
done:   bra.s   done
fail:   move.w  #$BAD0,($f102).l
        bra.s   done
