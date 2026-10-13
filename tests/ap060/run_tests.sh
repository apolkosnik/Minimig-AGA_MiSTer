#!/bin/sh
# The AP68060 in Minimig: tb_ap060_wrapchip.sv (the real cpu_wrapper,
# ap060_tg68k_compat, the AP68060 core) under Verilator, every program in
# two configurations: no wait states, and random wait states on the chip
# bus and the RAM port.
#   asm/t_ap060_sys.s   the integration: 16-bit splitting, autoconfig, Fast
#                       RAM with the caches on, TCI on chip RAM, code in
#                       Fast RAM, autovectored interrupts, the LC060 FPU trap
#   asm/t_irqstore.s    exec-style list moves in Fast RAM against interrupts
#                       taken at random points, the stack in Fast RAM
#   asm/t_l2stale.s     the memory controllers' caches stay coherent while
#                       the 68060 turns its own caches off and on
#   asm/t_nmi.s         the cartridge's NMI (HRTmon): the acknowledge read on
#                       the chip bus arms it and drops its request
#   asm/t_clrloop.s     exec's AllocMem clear loop: chip RAM stores from cached
#                       code while interrupts arrive (the -006 freeze: a
#                       store's answer lost while WB waited on the store buffer)
#   asm/t_dmacoh.s      DMA into Fast RAM (ddram_ctrl's DMA port, as Akiko and
#                       CDTV): the Fast RAM port's own cache never serves
#                       data older than it, around exec's cache maintenance
#   asm/t_iplglitch.s   no interrupt at a level never raised: STOP waits for
#                       level 3 while one IPL bit crosses late (ddr_iplskew)
#   asm/core/t_bsrfault.s  fetch faults that must not wedge the decoder
#                       (run with its pages in Fast RAM: t_bsrfault_f)
#   asm/core/*.s        AP68060's own programs (tb/asm at the vendored
#                       commit) that need no bench MMIO beyond $F100-$F110
# Configurations: ddr / ddr_wait run the Fast RAM through the real ddram_ctrl
# on a DDR3 model (random waitrequest in ddr_wait), ddr_throttle with the
# stock speed option, ddr_1x with the processor on clk itself, ddr_cpu20 with
# it at 20 MHz (below the bus side), ddr_lc060 with no FPU (MC68LC060),
# ddr_iplskew with IPL0 reaching the adapter's synchroniser late,
# simple through a plain RAM port model;
# the others run it at 55 MHz, unrelated to the Minimig clocks.  Every run
# with the DDR3 model checks that each Fast RAM write reached it.
# Usage: run_tests.sh [work dir]   (default: build; not /tmp, a small tmpfs)
set -eu
cd "$(dirname "$0")"
WORK=${1:-build}
mkdir -p "$WORK"
R=../../rtl
A=$R/ap060
VASM=${VASM:-vasmm68k_mot}

PROGS="t_ap060_sys t_irqstore t_l2stale t_nmi t_iplglitch t_clrloop t_dmacoh"
CORE="smoke t_integer t_stld t_bitfield_cache t_fpu_dis t_movem_restart"
for t in $PROGS; do
	$VASM -quiet -Fbin -m68040 -no-opt -L "$WORK/$t.lst" -o "$WORK/$t.bin" "asm/$t.s"
	python3 bin2hex.py "$WORK/$t.bin" "$WORK/$t.hex"
done
for t in $CORE; do
	$VASM -quiet -Fbin -m68040 -no-opt -o "$WORK/$t.bin" "asm/core/$t.s"
	python3 bin2hex.py "$WORK/$t.bin" "$WORK/$t.hex"
done
# t_bsrfault with its pages in Zorro II Fast RAM (cacheable, as NetBSD's):
# fetch faults at a word-aligned target and in a long instruction's tail,
# the NetBSD wedge of AP060 -005
$VASM -quiet -Fbin -m68040 -no-opt -DFASTOFS='$200000' -o "$WORK/t_bsrfault_f.bin" asm/core/t_bsrfault.s
python3 bin2hex.py "$WORK/t_bsrfault_f.bin" "$WORK/t_bsrfault_f.hex"
CORE="$CORE t_bsrfault_f"
# Dhrystone (c/, from the AP030 bench): dhry from chip RAM, dhry_fast from
# Fast RAM with both caches on -- a long run of ordinary compiled code that
# writes Fast RAM continuously; the bench checks every write reached DDR3
VBCC=${VBCC:-/opt/amiga-cc/vbcc}
if [ -x "$VBCC/bin/vc" ]; then
	export VBCC
	$VASM -quiet -Fhunk -m68040 -o "$WORK/start.o" c/start.s
	for f in dhry_1 dhry_2; do
		$VBCC/bin/vc +aos68k -c -O2 -speed -cpu=68060 -DTIME -DIO_BASE=0xF100 -DNUMBER_OF_RUNS=100 \
		    -o "$WORK/$f.o" "c/$f.c" > "$WORK/$f.compile.log" 2>&1
	done
	$VBCC/bin/vlink -brawbin1 -o "$WORK/dhry.bin" "$WORK/start.o" "$WORK/dhry_1.o" "$WORK/dhry_2.o"
	python3 bin2hex.py "$WORK/dhry.bin" "$WORK/dhry.hex"
	$VASM -quiet -Fhunk -m68040 -o "$WORK/start_fast.o" c/start_fast.s
	for f in dhry_1 dhry_2; do
		$VBCC/bin/vc +aos68k -c -O2 -speed -cpu=68060 -DTIME -DIO_BASE=0xF100 -DNUMBER_OF_RUNS=500 \
		    -o "$WORK/f_$f.o" "c/$f.c" > "$WORK/f_$f.compile.log" 2>&1
	done
	$VBCC/bin/vlink -brawbin1 -Ttext 0x200000 -o "$WORK/dhry_fast_img.bin" "$WORK/start_fast.o" "$WORK/f_dhry_1.o" "$WORK/f_dhry_2.o"
	$VASM -quiet -Fbin -m68040 -no-opt -I"$WORK" -o "$WORK/dhry_fast.bin" asm/fast_loader.s
	python3 bin2hex.py "$WORK/dhry_fast.bin" "$WORK/dhry_fast.hex"
	CORE="$CORE dhry dhry_fast"
else
	echo "  (vbcc not found: dhry skipped)"
fi

SRC="$R/cpu_wrapper.v $R/memory_router.v $R/fastchip.v $R/rtg.v $R/akiko.v $R/akiko_hps_bridge.v $R/akiko_nvram.v $R/gayle.v $R/ide.v
     $R/ddram_ctrl.v $R/cpu_cache_new.v $R/A2065/a2065_ddram_arbiter.v $R/A2065/a2065_ddr3_mailbox.v sim_dpram.v
     $A/ap68060_pkg.sv $A/gen/ap68060_upkg.sv $A/ap68060_alu.sv $A/ap68060_alu_slow.sv $A/ap68060_muldiv.sv
     $A/ap68060_biu.sv $A/ap68060_ram.sv $A/ap68060_atc.sv $A/ap68060_dmu.sv $A/ap68060_predec.sv
     $A/ap68060_fetch.sv $A/ap68060_decode.sv $A/ap68060_useq.sv $A/fpu/ap040_fpu.v $A/ap68060_fpif.sv
     $A/ap68060_backend.sv $A/ap68060_snoop.sv $A/ap68060.sv $A/fastram/ap030_async_fifo.v $A/fastram/ap030_l2ram.sv $A/fastram/ap030_fastram_fe.v $A/fastram/ap030_fastram_be.v $A/fastram/ap060_fastram_bus.sv $A/fastram/ap060_fastram.sv $A/ap060_tg68k_compat.v"
VFLAGS="--binary --timing -j 16 --build-jobs 16 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH
        -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Werror-PINMISSING -I$A -I$A/fpu"
CONFIGS="ddr:-GWAIT=0
ddr_wait:-GWAIT=1
ddr_throttle:-GWAIT=1,-GTHROTTLE=1
ddr_1x:-GWAIT=1,-GCPU_1X=1
ddr_cpu20:-GWAIT=1,-GCPU_HALF=25.0
ddr_lc060:-GWAIT=1,-GFPU=0
ddr_iplskew:-GWAIT=1,+define+AP060_SIM_IPL_SKEW=5
simple:-GREAL_DDR=0"
for c in $CONFIGS; do
	name=${c%%:*}; params=$(echo "${c#*:}" | tr ',' ' ')
	rm -f "$WORK/obj_$name/tb"
	# shellcheck disable=SC2086
	verilator $VFLAGS $params --top-module tb_ap060_wrapchip --Mdir "$WORK/obj_$name" -o tb \
	    tb_ap060_wrapchip.sv $SRC > "$WORK/build_$name.log" 2>&1 ||
	    { echo "BUILD FAIL $name (see $WORK/build_$name.log)"; tail -20 "$WORK/build_$name.log"; exit 1; }
done

fail=0
# module benches: the DDR3 arbiter keeps a stalled command presented
# (Avalon), ddram_ctrl takes read data that comes with waitrequest
for u in "arb_stall:$R/A2065/a2065_ddram_arbiter.v" \
         "ddram_rdbusy:$R/ddram_ctrl.v $R/cpu_cache_new.v $R/A2065/a2065_ddram_arbiter.v sim_dpram.v"; do
	n=${u%%:*}
	# shellcheck disable=SC2086
	if verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD \
	       --top-module tb_$n --Mdir "$WORK/obj_u_$n" -o tb unit/tb_$n.sv ${u#*:} > "$WORK/build_u_$n.log" 2>&1 &&
	   "$WORK/obj_u_$n/tb" > "$WORK/unit_$n.log" 2>&1 && grep -q "^PASS" "$WORK/unit_$n.log"; then
		printf "  pass  %-8s %s\n" unit "tb_$n"
	else
		printf "  FAIL  %-8s %s (%s)\n" unit "tb_$n" "$(grep -m1 FAIL "$WORK/unit_$n.log")"
		fail=1
	fi
done
for c in $CONFIGS; do
	name=${c%%:*}
	for t in $PROGS $CORE; do
		# t_dmacoh drives ddram_ctrl's DMA port: the DDR3 configurations only
		[ "$t" = t_dmacoh ] && [ "$name" = simple ] && continue
		log="$WORK/${name}_$t.log"
		if (cd "$WORK" && "./obj_$name/tb" "+prog=$t.hex" +timeout=80000000) > "$log" 2>&1 &&
		   grep -q "^PASS" "$log" && ! grep -q "LOST WRITE" "$log"; then
			printf "  pass  %-8s %-18s %s\n" "$name" "$t" "$(grep -o 'cycles=[0-9]*' "$log")"
		else
			printf "  FAIL  %-8s %-18s (%s)\n" "$name" "$t" "$(grep -m1 FAIL "$log")"
			fail=1
		fi
	done
done
if [ $fail -eq 0 ]; then echo "AP060 Minimig: ALL TESTS PASSED"; else echo "AP060 Minimig: FAILURES"; exit 1; fi
