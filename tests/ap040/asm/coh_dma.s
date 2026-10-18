; coh_dma: Chip RAM under chipset DMA: $3500 is read with the data cache on (so
; it would be cached), then a DMA write ($F130) changes it behind the CPU;
; the CPU must read the new $BEEF0000.  Chip RAM is outside the TCI window.
; Passes with $600D at $F102; fails with 99.  Bench: tb_cpu_wrapper_chip
; (FASTRAM_CFG=4).  Assembled with vasmm68k_mot -Fbin -m68040.

 org 0
 dc.l $3400,start
 rept 254
 dc.l fail
 endr
 org $400
start:
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
