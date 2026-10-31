; The AP68060 in Minimig: an interrupt handler's acknowledge (INTREQ) is
; posted by the adapter; the RTE that follows must not find the request it
; acknowledged still raised and take the interrupt again.  The Player 6.1A
; (Nexus 7, Andromeda) times its audio DMA restart with two CIA-B level 6
; interrupts 826 us apart: a second entry right after the first runs the
; second stage at once, and the looped samples start at the wrong place.
; Its stage-1 handler, from Fast RAM with its stack there: a DMACON write,
; INTREQ acknowledge, a CIA write, RTE.  Here: the bench raises level 6
; ($F110), the handler writes DMACON, acknowledges at $DFF09C (the bench
; drops the request when that write is done) and writes chip RAM, then
; RTE; each request must be taken exactly once, 50 times.  As in the demo
; (hires, six bitplanes, the blitter busy) the chip bus is slow then: the
; bench holds the acknowledge's chip-bus cycle 400 clocks ($F12C), so it
; lands well after RTE.

FAST    equ     $200000
SSP     equ     FAST+$8000
CNT     equ     FAST+$1000
CODE    equ     FAST+$10000
ROUNDS  equ     50

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

        org     $400
start:
        move.w  #$2700,sr
        move.b  #$20,($e80048).l        ; Zorro II RAM at $200000
        lea     body(pc),a0
        lea     (CODE).l,a1
        move.w  #(body_end-body)/2-1,d0
copy:   move.w  (a0)+,(a1)+
        dbra    d0,copy
        jmp     (CODE).l

body:
        lea     (SSP).l,sp
        lea     lev6(pc),a0
        move.l  a0,($78).w              ; level 6 autovector
        move.l  #$8000,d0               ; instruction cache
        movec   d0,cacr
        moveq   #ROUNDS-1,d7
round:
        clr.l   (CNT).l
        move.w  #$2000,sr
        move.w  #6,($f110).l            ; raise level 6
        move.w  #3000,d1                ; well past the handler
dly:    dbra    d1,dly
        move.w  #$2700,sr
        move.l  (CNT).l,d0
        cmp.l   #1,d0
        bne.s   bad
        dbra    d7,round
        move.w  #$600D,($f102).l
done:   bra.s   done
bad:    move.w  #1,($f100).l
        move.w  #$BAD0,($f102).l
        bra.s   done

lev6:   addq.l  #1,(CNT).l
        move.w  #$8201,($dff096).l      ; DMACON (posted)
        move.w  #400,($f12c).l          ; the chip bus busy (bitplanes, blitter):
        move.w  #$2000,($dff09c).l      ; INTREQ acknowledge (posted) waits 400
        move.w  #$0019,($8200).l        ; (in place of the CIA timer write)
        rte
body_end:

fail:   move.w  #$BAD0,($f102).l
        bra.s   fail
