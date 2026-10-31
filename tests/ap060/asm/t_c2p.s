; The AP68060 in Minimig: Akiko's C2P port (fastchip) through cpu_wrapper,
; one access per transfer.  The port advances its pointer every clock it
; is selected with a read or a write, so an access held selected longer
; (the stock-speed throttle stretching it) is counted more than once.  From
; the bus audit: sixteen word writes (fifteen of 0, one of $FFFF) and
; sixteen reads, which must return 0 and 3 alternately.

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

        org     $400
start:
        move.w  #$2700,sr
        lea     ($b80038).l,a0
        moveq   #14,d1
fill:   move.w  #0,(a0)
        dbra    d1,fill
        move.w  #$ffff,(a0)
        moveq   #7,d1
check:  move.w  (a0),d0
        cmp.w   #0,d0
        bne.s   bad
        move.w  (a0),d0
        cmp.w   #3,d0
        bne.s   bad
        dbra    d1,check
        move.w  #$600d,($f102).l
done:   bra.s   done
bad:    move.w  #1,($f100).l
fail:   move.w  #$bad0,($f102).l
        bra.s   done
