#!/bin/sh
# Build and run all AP040 tests with Icarus Verilog.
# Usage: run_tests.sh [workdir]
#
# Both phases run concurrently: the bench compiles are independent of each
# other once the two generated sources exist, and every simulation leg is
# independent of every other.  Each leg writes its own log and its own
# status file, so a parallel run reports exactly what a serial one did.

set -e
cd "$(dirname "$0")"
RTL=../../rtl/ap040
WORK=${1:-build}
mkdir -p "$WORK"

./build_tests.sh

SRC="$RTL/ap040_tg68k_compat.v $RTL/ap040_core.v $RTL/ap040_bus16_adapter.v $RTL/ap040_bus_timeout.v \
     $RTL/ap040_regfile.v $RTL/ap040_alu.v $RTL/ap040_muldiv.v $RTL/ap040_mmu.v $RTL/ap040_ucache.v $RTL/ap040_fpu.v $RTL/ap040_fill_cdc.v"

# generated sources: every bench below reads them, so they come first
python3 hoist_decls.py ../../rtl/cpu_wrapper.v "$WORK/cpu_wrapper_sim.v"
# the chip bench carries the real chipset block so the RTG register
# handshake is exercised; all five need the same iverilog fixups
for m in fastchip rtg akiko gayle ide; do
	python3 hoist_decls.py "../../rtl/$m.v" "$WORK/${m}_sim.v"
done
python3 prepare_sdram_sim.py ../../rtl/sdram_ctrl.v "$WORK/sdram_ctrl_sim.v"

rm -f "$WORK"/.status.*

# compile: name is only used to report which compile failed
compile() {
	name=$1
	shift
	if "$@" 2> "$WORK/compile_$name.log"; then
		:
	else
		echo "compile $name" > "$WORK/.status.compile_$name"
		cat "$WORK/compile_$name.log" >&2
	fi
}

# The heavy co-simulation legs dominate the wall clock under vvp; verilate
# them when verilator is installed (~30x), keeping the iverilog build as the
# fallback.  Both simulators stay buildable on purpose: they have caught
# DIFFERENT bug classes (2-state tristate vs function/array sensitivity).
HAVE_VL=0
command -v verilator >/dev/null 2>&1 && HAVE_VL=1

compile reset iverilog -g2012 -I "$RTL" -o "$WORK/tb_reset.vvp" \
	tb_ap040_reset.v sim_dpram.v $SRC &
# The program bench carries five programs x three phases and dominates the
# wall clock.  Verilator runs it ~30x faster than vvp with identical
# results, so use it when installed; the vvp build stays as the fallback
# (and the two have caught different bug classes before -- see the
# sdram-turbo tristate history -- so keeping both buildable is deliberate).
if command -v verilator >/dev/null 2>&1; then
	compile prog verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_ap040_program -I"$RTL" \
		-Mdir "$WORK/vl_prog" -o Vtb_ap040_program \
		tb_ap040_program.v sim_dpram.v $SRC &
	PROG_SIM="$WORK/vl_prog/Vtb_ap040_program"
else
	compile prog iverilog -g2012 -I "$RTL" -o "$WORK/tb_prog.vvp" \
		tb_ap040_program.v sim_dpram.v $SRC &
	PROG_SIM="$WORK/tb_prog.vvp"
fi
compile double_fault iverilog -g2012 -I "$RTL" -o "$WORK/tb_double_fault.vvp" \
	tb_ap040_double_fault.v sim_dpram.v $SRC &
compile walker_cdc iverilog -g2012 -I "$RTL" -o "$WORK/tb_walker_cdc.vvp" \
	tb_ap040_walker_cdc.v $RTL/ap040_walker_cdc.v &
compile bus16_gap iverilog -g2012 -I "$RTL" -o "$WORK/tb_bus16_gap.vvp" \
	tb_ap040_bus16_gap.v $RTL/ap040_bus16_adapter.v &
compile cpu_cache_new iverilog -g2012 -s tb_cpu_cache_new \
	-o "$WORK/tb_cpu_cache_new.vvp" \
	tb_cpu_cache_new.v ../../rtl/cpu_cache_new.v &
compile ddram_walker_snoop iverilog -g2012 -s tb_ddram_walker_snoop \
	-o "$WORK/tb_ddram_walker_snoop.vvp" \
	tb_ddram_walker_snoop.v ../../rtl/ddram_ctrl.v \
	../../rtl/cpu_cache_new.v ../../rtl/A2065/a2065_ddram_arbiter.v sim_dpram.v &
compile ddram_walker_read iverilog -g2012 -s tb_ddram_walker_read \
	-o "$WORK/tb_ddram_walker_read.vvp" \
	tb_ddram_walker_read.v ../../rtl/ddram_ctrl.v \
	../../rtl/cpu_cache_new.v ../../rtl/A2065/a2065_ddram_arbiter.v \
	$RTL/ap040_walker_cdc.v $RTL/ap040_bus_timeout.v sim_dpram.v &
compile bus_timeout iverilog -g2012 -o "$WORK/tb_bus_timeout.vvp" \
	tb_ap040_bus_timeout.v $RTL/ap040_bus_timeout.v &
compile cart_hrtmon iverilog -g2012 -o "$WORK/tb_cart_hrtmon.vvp" \
	tb_cart_hrtmon.v ../../rtl/cart.v &
if [ "$HAVE_VL" = 1 ]; then
	compile wrapchip verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_cpu_wrapper_chip \
		-I"$RTL" -Mdir "$WORK/vl_wrapchip" -o Vwrapchip \
		tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
	"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
	"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
	sim_dpram.v $SRC &
	WRAPCHIP_SIM="$WORK/vl_wrapchip/Vwrapchip"
else
	compile wrapchip iverilog -g2012 -I "$RTL" -s tb_cpu_wrapper_chip \
		-o "$WRAPCHIP_SIM" tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
		"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
		"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
		sim_dpram.v $SRC &
	WRAPCHIP_SIM="$WRAPCHIP_SIM"
fi
# the RAM port's acknowledgement outlives its own access, so the latency at
# which a stale ready overlaps the next request is what decides whether
# bus_complete can cross targets -- one value proves nothing
if [ "$HAVE_VL" = 1 ]; then
	compile wrapchip_l0 verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_cpu_wrapper_chip -GRAM_LAT=0 \
		-I"$RTL" -Mdir "$WORK/vl_wrapchip_l0" -o Vwrapchip_l0 \
		tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
	"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
	"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
	sim_dpram.v $SRC &
	WRAPCHIP_L0_SIM="$WORK/vl_wrapchip_l0/Vwrapchip_l0"
else
	compile wrapchip_l0 iverilog -g2012 -I "$RTL" -s tb_cpu_wrapper_chip -P tb_cpu_wrapper_chip.RAM_LAT=0 \
		-o "$WRAPCHIP_L0_SIM" tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
		"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
		"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
		sim_dpram.v $SRC &
	WRAPCHIP_L0_SIM="$WRAPCHIP_L0_SIM"
fi
if [ "$HAVE_VL" = 1 ]; then
	compile wrapchip_l7 verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_cpu_wrapper_chip -GRAM_LAT=7 \
		-I"$RTL" -Mdir "$WORK/vl_wrapchip_l7" -o Vwrapchip_l7 \
		tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
	"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
	"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
	sim_dpram.v $SRC &
	WRAPCHIP_L7_SIM="$WORK/vl_wrapchip_l7/Vwrapchip_l7"
else
	compile wrapchip_l7 iverilog -g2012 -I "$RTL" -s tb_cpu_wrapper_chip -P tb_cpu_wrapper_chip.RAM_LAT=7 \
		-o "$WRAPCHIP_L7_SIM" tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
		"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
		"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
		sim_dpram.v $SRC &
	WRAPCHIP_L7_SIM="$WRAPCHIP_L7_SIM"
fi
# turbo chipram: cchip claims $000000-$1FFFFF, so fetches AND data leave the
# chip bus for the accelerated RAM port.  That is how an accelerated board
# runs, and it is the only configuration where a fastchip access follows a
# RAM access rather than a chip-bus one.
if [ "$HAVE_VL" = 1 ]; then
	compile wrapchip_turbo verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_cpu_wrapper_chip -GTURBO_CHIP=1 \
		-I"$RTL" -Mdir "$WORK/vl_wrapchip_turbo" -o Vwrapchip_turbo \
		tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
	"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
	"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
	sim_dpram.v $SRC &
	WRAPCHIP_TURBO_SIM="$WORK/vl_wrapchip_turbo/Vwrapchip_turbo"
else
	compile wrapchip_turbo iverilog -g2012 -I "$RTL" -s tb_cpu_wrapper_chip -P tb_cpu_wrapper_chip.TURBO_CHIP=1 \
		-o "$WRAPCHIP_TURBO_SIM" tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
		"$WORK/fastchip_sim.v" "$WORK/rtg_sim.v" "$WORK/akiko_sim.v" \
		"$WORK/gayle_sim.v" "$WORK/ide_sim.v" ../../rtl/ram_cs_guard.v \
		sim_dpram.v $SRC &
	WRAPCHIP_TURBO_SIM="$WRAPCHIP_TURBO_SIM"
fi
if [ "$HAVE_VL" = 1 ]; then
	compile sdram_turbo verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_sdram_turbo -GCYC_PHASE=1 -GCPU_PHASE=0 \
		-I"$RTL" -Mdir "$WORK/vl_sdram_turbo" -o Vsdram_turbo \
		tb_sdram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_walker_cdc.v $SRC &
	SDRAM_TURBO_SIM="$WORK/vl_sdram_turbo/Vsdram_turbo"
else
	compile sdram_turbo iverilog -g2012 -I "$RTL" -s tb_sdram_turbo -P tb_sdram_turbo.CYC_PHASE=1 -P tb_sdram_turbo.CPU_PHASE=0 \
		-o "$SDRAM_TURBO_SIM" tb_sdram_turbo.v \
		"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
		../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
		$RTL/ap040_walker_cdc.v $SRC &
	SDRAM_TURBO_SIM="$SDRAM_TURBO_SIM"
fi
# second sdram-turbo instance at the real-hardware phase alignment
# (CPU_PHASE=3): the only alignment whose chip stage machine can sample
# the ph2 pulse and therefore deliver interrupts -- t_fpu's IRQ soak
# needs it, while the CPU_PHASE=0 instance keeps the guard-hostile
# alignment coverage
if [ "$HAVE_VL" = 1 ]; then
	compile sdram_turbo_ph3 verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_sdram_turbo -GCYC_PHASE=1 -GCPU_PHASE=3 \
		-I"$RTL" -Mdir "$WORK/vl_sdram_turbo_ph3" -o Vsdram_turbo_ph3 \
		tb_sdram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_walker_cdc.v $SRC &
	SDRAM_TURBO_PH3_SIM="$WORK/vl_sdram_turbo_ph3/Vsdram_turbo_ph3"
else
	compile sdram_turbo_ph3 iverilog -g2012 -I "$RTL" -s tb_sdram_turbo -P tb_sdram_turbo.CYC_PHASE=1 -P tb_sdram_turbo.CPU_PHASE=3 \
		-o "$SDRAM_TURBO_PH3_SIM" tb_sdram_turbo.v \
		"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
		../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
		$RTL/ap040_walker_cdc.v $SRC &
	SDRAM_TURBO_PH3_SIM="$SDRAM_TURBO_PH3_SIM"
fi
if [ "$HAVE_VL" = 1 ]; then
	compile dualram_turbo verilator --binary --timing -j 4 -Wno-fatal -Wno-lint \
		-Wno-style --top-module tb_dualram_turbo -GCYC_PHASE=1 -GCPU_PHASE=3 \
		-I"$RTL" -Mdir "$WORK/vl_dualram_turbo" -o Vdualram_turbo \
		tb_dualram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v ../../rtl/ddram_ctrl.v \
	../../rtl/A2065/a2065_ddram_arbiter.v \
	sim_dpram.v ../../rtl/ram_cs_guard.v $RTL/ap040_walker_cdc.v $SRC &
	DUALRAM_TURBO_SIM="$WORK/vl_dualram_turbo/Vdualram_turbo"
else
	compile dualram_turbo iverilog -g2012 -I "$RTL" -s tb_dualram_turbo -P tb_dualram_turbo.CYC_PHASE=1 -P tb_dualram_turbo.CPU_PHASE=3 \
		-o "$DUALRAM_TURBO_SIM" tb_dualram_turbo.v \
		"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
		../../rtl/cpu_cache_new.v ../../rtl/ddram_ctrl.v \
		../../rtl/A2065/a2065_ddram_arbiter.v \
		sim_dpram.v ../../rtl/ram_cs_guard.v $RTL/ap040_walker_cdc.v $SRC &
	DUALRAM_TURBO_SIM="$DUALRAM_TURBO_SIM"
fi
compile fillsnoop iverilog -g2012 -I "$RTL" -s tb_ap040_fillsnoop \
	-o "$WORK/tb_fillsnoop.vvp" tb_ap040_fillsnoop.v \
	$RTL/ap040_ucache.v sim_dpram.v &
compile cache_snoop iverilog -g2012 -I "$RTL" -s tb_ap040_cache_snoop \
	-o "$WORK/tb_cache_snoop.vvp" tb_ap040_cache_snoop.v \
	sim_dpram.v $RTL/ap040_cache.v &
compile sdram32 iverilog -g2012 -s tb_sdram32 \
	-o "$WORK/tb_sdram32.vvp" tb_sdram32.v \
	../../rtl/sdram32_ctrl.v "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v sim_dpram.v &
wait

if ls "$WORK"/.status.compile_* >/dev/null 2>&1; then
	echo "AP040 regression: COMPILE FAILURES, see $WORK/compile_*.log"
	exit 1
fi

# run: every leg is independent, so they all go at once
leg() {
	name=$1
	shift
	# a verilated bench is a native executable; everything else is a .vvp
	sim=$1
	case "$sim" in
		*.vvp) sim="vvp $sim" ;;
	esac
	shift
	if $sim "$@" > "$WORK/$name.log" 2>&1 &&
	   grep -q "ALL TESTS PASSED" "$WORK/$name.log"; then
		:
	else
		echo "$name" > "$WORK/.status.$name"
	fi
}

# a negative leg passes only when the bench FAILS: the deliberate-break
# modes must stay capable of failing, or the positive checks prove nothing
negleg() {
	name=$1
	shift
	if vvp "$@" > "$WORK/$name.log" 2>&1 &&
	   grep -q "TEST FAILED" "$WORK/$name.log"; then
		:
	else
		echo "$name" > "$WORK/.status.$name"
	fi
}

leg reset              "$WORK/tb_reset.vvp" &
leg double_fault       "$WORK/tb_double_fault.vvp" &
leg walker_cdc         "$WORK/tb_walker_cdc.vvp" &
leg bus16_gap          "$WORK/tb_bus16_gap.vvp" &
leg cpu_cache_new      "$WORK/tb_cpu_cache_new.vvp" &
leg ddram_walker_snoop "$WORK/tb_ddram_walker_snoop.vvp" &
leg ddram_walker_read  "$WORK/tb_ddram_walker_read.vvp" &
leg bus_timeout        "$WORK/tb_bus_timeout.vvp" &
leg cart_hrtmon        "$WORK/tb_cart_hrtmon.vvp" &
leg sdram32            "$WORK/tb_sdram32.vvp" &
leg cache_snoop        "$WORK/tb_cache_snoop.vvp" &
leg fillsnoop          "$WORK/tb_fillsnoop.vvp" &
negleg sdram32_brk_lock "$WORK/tb_sdram32.vvp" +break_lockstep &
negleg sdram32_brk_lane "$WORK/tb_sdram32.vvp" +break_laneswap &
negleg sdram32_brk_wr   "$WORK/tb_sdram32.vvp" +break_chipwr &
leg sdram32_nomod      "$WORK/tb_sdram32.vvp" +no_module &
leg integer            "$PROG_SIM" +prog=build/t_integer.hex &
leg exceptions         "$PROG_SIM" +prog=build/t_exceptions.hex &
leg mmu                "$PROG_SIM" +prog=build/t_mmu.hex &
leg cache              "$PROG_SIM" +prog=build/t_cache.hex &
leg fpu                "$PROG_SIM" +prog=build/t_fpu.hex &
leg fpu_chip           "$WRAPCHIP_SIM" +prog=build/t_fpu.hex &
leg exceptions_chip    "$WRAPCHIP_SIM" +prog=build/t_exceptions.hex &
leg exceptions_chip_l0 "$WRAPCHIP_L0_SIM" +prog=build/t_exceptions.hex &
leg exceptions_chip_l7 "$WRAPCHIP_L7_SIM" +prog=build/t_exceptions.hex &
# t_cache is deliberately absent: it asserts that a stale I-cache line is
# still served, which the chip-window I-fetch bypass prevents whenever
# cache_allow_all is 0 as it is here and in production.  That program
# belongs to tb_prog, which runs everything-cacheable.
leg exceptions_turbo   "$WRAPCHIP_TURBO_SIM" +prog=build/t_exceptions.hex &
leg mmu_turbo          "$WRAPCHIP_TURBO_SIM" +prog=build/t_mmu.hex &
leg fpu_turbo          "$WRAPCHIP_TURBO_SIM" +prog=build/t_fpu.hex &
leg integer_turbo      "$WRAPCHIP_TURBO_SIM" +prog=build/t_integer.hex &
leg mmu_chip           "$WRAPCHIP_SIM" +prog=build/t_mmu.hex &
leg fpu_turbo          "$SDRAM_TURBO_SIM" +prog=build/t_fpu.hex &
leg mmu_turbo          "$SDRAM_TURBO_SIM" +prog=build/t_mmu.hex &
leg mmu_turbo_ph3      "$SDRAM_TURBO_PH3_SIM" +prog=build/t_mmu.hex &
leg fpu_dualram        "$DUALRAM_TURBO_SIM" +prog=build/t_fpu.hex &
leg fpu_turbo_ph3      "$SDRAM_TURBO_PH3_SIM" +prog=build/t_fpu.hex &
wait

if ls "$WORK"/.status.* >/dev/null 2>&1; then
	echo "AP040 regression: FAILURES in:"
	for f in "$WORK"/.status.*; do
		name=$(cat "$f")
		echo "  $name  ($WORK/$name.log)"
	done
	exit 1
fi

echo "AP040 regression: ALL TESTS PASSED"
