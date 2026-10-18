; coh_nmi_warm: HRTMon's freeze with the level 7 vector cached: Z3 fast RAM at
; $10000000 (autoconfig), VBR at $10004000, the vector line read into the
; data cache first, then the cartridge's freeze ($F170).  The cartridge
; overlays the vector read with its monitor entry ($00A1000C, here code at
; $6000): the core reads the level 7 vector past its cache, so the
; override is seen and the monitor entered.
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
 move.w #$1000,($E80044).l
 move.l #$10004000,d0
 movec d0,vbr
 move.l #fail,($1000407C).l
 move.l #$80000000,d0
 movec d0,cacr
 move.l ($1000407C).l,d1
 move.w #1,($F170).l
 move.l #10000,d2
wait_nmi:
 dbra d2,wait_nmi
 bra fail
pass:
 move.w #$600D,($F102).l
 stop #$2700
fail:
 move.w #99,($F100).l
 move.w #$BAD0,($F102).l
 stop #$2700
 org $6000
 move.w #$600D,($F102).l
 stop #$2700
