#!/bin/sh
# AP030 on Minimig: cpu_wrapper + ap030_tg68k_compat co-simulation.
# Builds tb_ap030_wrapchip.sv with Verilator in several configurations and
# runs the programs through the real cpu_wrapper chip-bus stage machine,
# the RAM port (ram_cs_guard, level acknowledge) and the fastchip block,
# with the processor on its own 50 MHz clock; the FASTRAM configurations add
# a Zorro II card served by the 32-bit synchronous Fast RAM port and a DDR3
# model (latency, random waitrequest).
# Needs verilator 5.x, vasmm68k_mot, python3, and vbcc for the C program.
set -eu
cd "$(dirname "$0")"
WORK=${1:-build}
mkdir -p "$WORK"
R=../../rtl
A=$R/ap030
VASM=${VASM:-vasmm68k_mot}
VBCC=${VBCC:-/opt/amiga-cc/vbcc}
export VBCC

tohex() {   # 16-bit words for the bench's $readmemh
	python3 - "$1" "$2" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
if len(b) % 2: b += b'\0'
open(sys.argv[2], 'w').write('\n'.join('%04x' % ((b[i] << 8) | b[i+1]) for i in range(0, len(b), 2)) + '\n')
PY
}

echo "== programs =="
sed -e 's/^FAILREG	equ	\$F00100/FAILREG	equ	$F100/' -e 's/^DONEREG	equ	\$F00102/DONEREG	equ	$F102/' \
    -e 's/\$F001C\([04]\)/$F1C\1/g' \
    asm/t_integer.src > asm/t_integer.s
PROGS="t_integer t_minimig t_fastram t_coherence"
for t in $PROGS; do
	$VASM -quiet -Fbin -m68030 -m68881 -m68851 -no-opt -o "$WORK/$t.bin" "asm/$t.s"
	tohex "$WORK/$t.bin" "$WORK/$t.hex"
done
if [ -x "$VBCC/bin/vc" ]; then
	$VASM -quiet -Fhunk -m68030 -o "$WORK/start.o" c/start.s
	for f in dhry_1 dhry_2; do
		$VBCC/bin/vc +aos68k -c -O2 -speed -cpu=68030 -DTIME -DIO_BASE=0xF100 -DNUMBER_OF_RUNS=100 \
		    -o "$WORK/$f.o" "c/$f.c" > "$WORK/$f.compile.log" 2>&1
	done
	$VBCC/bin/vlink -brawbin1 -o "$WORK/dhry.bin" "$WORK/start.o" "$WORK/dhry_1.o" "$WORK/dhry_2.o"
	tohex "$WORK/dhry.bin" "$WORK/dhry.hex"
	# the same benchmark running from Fast RAM, behind a chip-RAM loader
	$VASM -quiet -Fhunk -m68030 -o "$WORK/start_fast.o" c/start_fast.s
	for f in dhry_1 dhry_2; do
		$VBCC/bin/vc +aos68k -c -O2 -speed -cpu=68030 -DTIME -DIO_BASE=0xF100 -DNUMBER_OF_RUNS=500 \
		    -o "$WORK/f_$f.o" "c/$f.c" > "$WORK/f_$f.compile.log" 2>&1
	done
	$VBCC/bin/vlink -brawbin1 -Ttext 0x200000 -o "$WORK/dhry_fast_img.bin" "$WORK/start_fast.o" "$WORK/f_dhry_1.o" "$WORK/f_dhry_2.o"
	$VASM -quiet -Fbin -m68030 -no-opt -I"$WORK" -o "$WORK/dhry_fast.bin" asm/fast_loader.s
	tohex "$WORK/dhry_fast.bin" "$WORK/dhry_fast.hex"
	PROGS="$PROGS dhry dhry_fast"
else
	echo "  (vbcc not found: dhry skipped)"
fi

echo "== compiling =="
VFLAGS="--binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
        -Wno-MULTIDRIVEN -Wno-PINMISSING -O1 -I$A -I$A/core -I$R"
SRC="$R/cpu_wrapper.v $R/fastchip.v $R/rtg.v $R/akiko.v $R/gayle.v $R/ide.v $R/ram_cs_guard.v \
     ../ap040/sim_dpram.v $R/ap040/ap040_bus_timeout.v $R/A2065/a2065_ddram_arbiter.v \
     $A/ap030_tg68k_compat.v $A/ap030_async_fifo.v $A/ap030_fastram_fe.v $A/ap030_fastram_be.v $A/ap030_top.v $A/ap030_core.v $A/ap030_memsys.v $A/ap030_mmu.v \
     $A/ap030_cache.v $A/ap030_bus.v $A/ap030_alu.v $A/ap030_muldiv.v $A/ap030_regfile.v"
# name:bench parameters (comma separated)
CONFIGS="chip:
chip_l0:-GRAM_LAT=0
chip_l7:-GRAM_LAT=7
chip_dtack:-GDTACK_MODE=1
chip_ph1:-GCPU_PHASE=1
chip_ph2:-GCPU_PHASE=2
chip_ph3:-GCPU_PHASE=3
turbo:-GTURBO_CHIP=1
turbo_l0:-GTURBO_CHIP=1,-GRAM_LAT=0
turbo_l7:-GTURBO_CHIP=1,-GRAM_LAT=7
turbo_dtack:-GTURBO_CHIP=1,-GDTACK_MODE=1
fast:-GFASTRAM=1
fast_wait:-GFASTRAM=1,-GDDR_WAIT=1
fast_slow:-GFASTRAM=1,-GDDR_LAT=40,-GDDR_WAIT=1
fast_turbo:-GFASTRAM=1,-GTURBO_CHIP=1"
pids=""
for c in $CONFIGS; do
	name=${c%%:*}; params=$(echo "${c#*:}" | tr ',' ' ')
	# shellcheck disable=SC2086
	( verilator $VFLAGS $params --top-module tb_ap030_wrapchip --Mdir "$WORK/obj_$name" -o tb \
	    tb_ap030_wrapchip.sv $SRC > "$WORK/build_$name.log" 2>&1 || echo "BUILD FAIL $name (see $WORK/build_$name.log)" ) &
	pids="$pids $!"
done
for p in $pids; do wait "$p"; done

echo "== running =="
fail=0
for c in $CONFIGS; do
	name=${c%%:*}
	for t in $PROGS; do
		# Fast RAM programs need the memory card (FASTRAM=1 configurations)
		case "$t" in t_fastram|t_coherence|dhry_fast) case "$c" in *FASTRAM=1*) ;; *) continue ;; esac ;; esac
		log="$WORK/${name}_$t.log"
		if [ -x "$WORK/obj_$name/tb" ] && "$WORK/obj_$name/tb" "+prog=$WORK/$t.hex" > "$log" 2>&1 && grep -q "ALL TESTS PASSED" "$log"; then
			printf "  pass  %-12s %-10s %s %s\n" "$name" "$t" "$(grep -o '([0-9]* cycles[^)]*)' "$log")" \
			       "$(grep -o 'clocks/run=[0-9.]*.*DMIPS' "$log" | head -1)"
		else
			printf "  FAIL  %-12s %-10s (see %s)\n" "$name" "$t" "$log"
			fail=1
		fi
	done
done
if [ $fail -eq 0 ]; then echo "AP030 Minimig: ALL TESTS PASSED"; else echo "AP030 Minimig: FAILURES"; exit 1; fi
