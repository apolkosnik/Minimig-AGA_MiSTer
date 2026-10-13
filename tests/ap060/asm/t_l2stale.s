; The AP68060 in Minimig: the Fast RAM controller's cache (cpu_cache_new
; in ddram_ctrl) stays coherent with the processor whatever the 68060's
; CACR says.  exec and 68060.library turn the data cache off and on again
; (CacheControl, CachePreDMA/PostDMA); stores made while it is off must not
; leave stale lines behind for when it is back on.
;   1  a line read with the data cache on (both caches fill it)
;   2  EDC off; the location rewritten; EDC on; the 68060's own cache
;      invalidated (CINVA, as the OS does) -- the next read must see the
;      new value from below, not the line filled in step 1
;   3  the same with EDC and EIC both off
;   4  through the instruction side: code written to Fast RAM, run, then
;      rewritten with the caches off, and run again

FAST    equ     $200000

ck      macro                   ; \1 operand, \2 expected (with #), \3 test
        cmp.l   \2,\1
        beq.s   ok\@
        move.w  #\3,($f100).l
        jmp     fail
ok\@:
        endm

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

start:
        move.w  #$2700,sr
        move.b  #$20,($e80048).l
        lea     (FAST+$3000).l,a0
        move.l  #$11111111,(a0)
        move.l  #$80008000,d0           ; EDC, EIC
        movec   d0,cacr
        move.l  (a0),d0                 ; fills both caches' lines
        ck      d0,#$11111111,1

        move.l  #$00008000,d0           ; EDC off (EIC stays)
        movec   d0,cacr
        move.l  #$22222222,(a0)
        move.l  #$80008000,d0
        movec   d0,cacr
        cinva   dc
        move.l  (a0),d0
        ck      d0,#$22222222,2

        moveq   #0,d0                   ; both off
        movec   d0,cacr
        move.l  #$33333333,(a0)
        move.l  #$80008000,d0
        movec   d0,cacr
        cinva   dc
        move.l  (a0),d0
        ck      d0,#$33333333,3

        ; code: moveq #1,d0; rts in Fast RAM, run with the caches on
        lea     (FAST+$3100).l,a1
        move.l  #$70014e75,(a1)
        cpusha  bc
        jsr     (a1)
        ck      d0,#1,4
        moveq   #0,d0                   ; caches off, rewrite: moveq #2,d0
        movec   d0,cacr
        move.l  #$70024e75,(a1)
        move.l  #$80008000,d0
        movec   d0,cacr
        cinva   bc
        jsr     (a1)
        ck      d0,#2,5

        move.w  #$600d,($f102).l
        bra.s   *

fail:   move.w  #$bad0,($f102).l
        bra.s   *
