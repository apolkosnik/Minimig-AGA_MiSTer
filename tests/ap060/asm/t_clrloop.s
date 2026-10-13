; The AP68060 in Minimig: exec's AllocMem(MEMF_CLEAR) loop -- the -006
; hardware freeze (JTAG ring: PC $F8200C, a run of long word writes to chip
; RAM, then no transfer and nothing retired, level 6 pending).  Kickstart
; 3.1 at $F81FFE:
;       movea.l d0,a0 / addq.l #7,d3 / lsr.l #3,d3 / move.w d3,d2 /
;       swap d3 / bra.s 2f
;   1:  move.l  d1,(a0)+
;       move.l  d1,(a0)+
;   2:  dbra    d2,1b
;       dbra    d3,1b
; run here from cachable Fast RAM (exec runs from cachable ROM, out of the
; instruction cache) with the store buffer and the branch cache on, writing
; chip RAM (TCI, the slow bus) while random level 2 interrupts arrive; the
; handler, also in Fast RAM, clears the request.  Each round clears with a
; new pattern and reads the block back.

FAST    equ     $200000
SSP     equ     FAST+$8000
CNT     equ     FAST+$1000      ; interrupts taken
CHIP    equ     $10000          ; the block cleared, in chip RAM
BYTES   equ     $1800
ROUNDS  equ     12

CODE    equ     FAST+$10000

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

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
        lea     irq2(pc),a0
        move.l  a0,($68).w
        clr.l   (CNT).l
        move.l  #$A0808000,d0           ; EDC, ESB, EBC, EIC (68060.library)
        movec   d0,cacr
        move.w  #2000,($f114).l         ; random level 2, 1..2000 clocks apart
        move.w  #2,($f112).l
        move.w  #$2000,sr

        moveq   #ROUNDS-1,d7
round:
        move.l  d7,d1
        mulu.w  #$1357,d1
        swap    d1
        move.w  d7,d1
        eor.l   #$A5C3,d1               ; this round's pattern
        move.w  d7,($f10a).l            ; progress
        move.l  #CHIP,d0
        move.l  #BYTES,d3
        movea.l d0,a0                   ; the ROM's sequence from here
        addq.l  #7,d3
        lsr.l   #3,d3
        move.w  d3,d2
        swap    d3
        bra.s   clr2
clr1:   move.l  d1,(a0)+
        move.l  d1,(a0)+
clr2:   dbra    d2,clr1
        dbra    d3,clr1

        lea     (CHIP).l,a0             ; every long word written
        move.w  #BYTES/4-1,d2
chk:    cmp.l   (a0)+,d1
        bne.s   bad
        dbra    d2,chk
        cmpa.l  #CHIP+BYTES,a0
        bne.s   bad
        dbra    d7,round

        move.w  #$2700,sr
        clr.w   ($f112).l
        tst.l   (CNT).l                 ; the interrupts did arrive
        beq.s   noirq
        move.w  #$600D,($f102).l
done:   bra.s   done
bad:    move.w  #1,($f100).l
        bra.s   fail
noirq:  move.w  #2,($f100).l
fail:   move.w  #$BAD0,($f102).l
halt:   bra.s   halt

irq2:   addq.l  #1,(CNT).l
        move.w  #0,($f110).l
        rte
body_end:
