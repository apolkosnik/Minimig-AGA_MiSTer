; coh_dma_ci: Control for coh_dma: the same with DTT0 marking $00xxxxxx cache-
; inhibited.
; Passes with $600D at $F102; fails with 99.  Bench: tb_cpu_wrapper_chip
; (FASTRAM_CFG=4).  Assembled with vasmm68k_mot -Fbin -m68040.

 org 0
 dc.l $3400,start
 rept 254
 dc.l fail
 endr
 org $400
start:
 move.l #$0000C040,d0
 movec d0,dtt0
 move.l #$11223344,($3500).l
 move.l #$80000000,d0
 movec d0,cacr
 move.l ($3500).l,d1
 move.w #$BEEF,($F130).l
 move.w #100,d2
wait_dma:
 dbra d2,wait_dma
 move.l ($3500).l,d1
 swap d1
 move.w d1,($F174).l
 swap d1
 cmp.l #$BEEF0000,d1
 bne fail
pass:
 move.w #$600D,($F102).l
 stop #$2700
fail:
 move.w #99,($F100).l
 move.w #$BAD0,($F102).l
 stop #$2700
