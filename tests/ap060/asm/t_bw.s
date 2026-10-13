; The AP68060 in Minimig: memory throughput, measured by the bench's time
; stamps ($F108: it prints the ns since the previous stamp, labelled with
; the value written).  Each section moves 16K, more than the 8K data cache,
; so a cached section is all line fills (and pushes); its caches are
; pushed and invalidated first.  The code runs from Fast RAM with both
; caches on, as exec does from ROM; the loops are unrolled sixteen times.
;   $0001 chip RAM long word reads        $0002 chip RAM long word writes
;   (both with DTT0 making chip RAM cache-inhibited, as 68060.library does)
;   $0003 Kickstart ROM reads (cachable)  $0004 Fast RAM reads (cachable)
;   $0005 Fast RAM writes (copyback)      $0006 Fast RAM copy, 8K to 8K
;   $0007 Fast RAM reads, 4K: cache hits (the processor's own speed)
; MB/s = 16384 / ns * 1000 (8192 for $0006, 65536 for $0007: 16 passes)

FAST    equ     $200000
STAMP   equ     $f108
CODE    equ     FAST+$10000
FBUF    equ     FAST+$20000
CBUF    equ     $40000
ROM     equ     $F80000

rd16    macro
        rept    16
        move.l  (a0)+,d0
        endr
        endm
wr16    macro
        rept    16
        move.l  d0,(a0)+
        endr
        endm

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
        lea     (FAST+$8000).l,sp
        move.l  #$A0808000,d0           ; EDC, ESB, EBC, EIC
        movec   d0,cacr
        moveq   #0,d0
        bsr     warm                    ; the loops into the instruction cache

        cpusha  bc
        move.l  #$0000C040,d0           ; DTT0: $00xxxxxx not cachable,
        movec   d0,dtt0                 ; as 68060.library maps chip RAM
        move.w  #0,(STAMP).l
        lea     (CBUF).l,a0             ; $0001 chip reads
        move.w  #16384/64-1,d1
c_rd:   rd16
        dbra    d1,c_rd
        move.w  #1,(STAMP).l

        lea     (CBUF).l,a0             ; $0002 chip writes
        move.w  #16384/64-1,d1
c_wr:   wr16
        dbra    d1,c_wr
        move.w  #2,(STAMP).l
        moveq   #0,d0
        movec   d0,dtt0

        cpusha  bc
        move.w  #0,(STAMP).l
        lea     (ROM).l,a0              ; $0003 ROM reads
        move.w  #16384/64-1,d1
r_rd:   rd16
        dbra    d1,r_rd
        move.w  #3,(STAMP).l

        cpusha  bc
        move.w  #0,(STAMP).l
        lea     (FBUF).l,a0             ; $0004 Fast RAM reads
        move.w  #16384/64-1,d1
f_rd:   rd16
        dbra    d1,f_rd
        move.w  #4,(STAMP).l

        cpusha  bc
        move.w  #0,(STAMP).l
        lea     (FBUF).l,a0             ; $0005 Fast RAM writes
        move.w  #16384/64-1,d1
f_wr:   wr16
        dbra    d1,f_wr
        cpusha  dc                      ; (the pushes count)
        move.w  #5,(STAMP).l

        cpusha  bc
        move.w  #0,(STAMP).l
        lea     (FBUF).l,a0             ; $0006 Fast RAM copy
        lea     (FBUF+$8000).l,a1
        move.w  #8192/16-1,d1
f_cp:   move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        dbra    d1,f_cp
        cpusha  dc
        move.w  #6,(STAMP).l

        lea     (FBUF).l,a0             ; the 4K into the data cache
        move.w  #4096/64-1,d1
f_w:    rd16
        dbra    d1,f_w
        move.w  #0,(STAMP).l
        moveq   #15,d2                  ; $0007 Fast RAM hits
f_hp:   lea     (FBUF).l,a0
        move.w  #4096/64-1,d1
f_h:    rd16
        dbra    d1,f_h
        dbra    d2,f_hp
        move.w  #7,(STAMP).l

        move.w  #$600D,($f102).l
done:   bra.s   done

warm:   rts

fail:   move.w  #$BAD0,($f102).l
halt:   bra.s   halt
body_end:
