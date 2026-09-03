#!/bin/sh
# Build and run all AP040 tests with Verilator (--binary --timing).
# Usage: run_tests_vl.sh [workdir]
#
# Leg-for-leg mirror of run_tests.sh for a host without Icarus Verilog:
# same generated sources, same +prog images, same pass/fail criteria.
# Module parameters that run_tests.sh passes with iverilog's -P are passed
# with Verilator's -G.  The two runners must agree; a leg that passes on
# one and not the other is a bug in the leg (plan X3.1).
#
# The assembled program images are read from tests/ap040/build/*.hex, so
# build_tests.sh (which needs vasm) is NOT run here.  Rebuild the images
# on a host with vasm when a .s file changes.

set -e
cd "$(dirname "$0")"
RTL=../../rtl/ap040
WORK=${1:-build_vl}
IMG=build
mkdir -p "$WORK"

if ! ls "$IMG"/t_integer.hex "$IMG"/t_exceptions.hex "$IMG"/t_mmu.hex \
        "$IMG"/t_cache.hex "$IMG"/t_fpu.hex >/dev/null 2>&1; then
	echo "run_tests_vl: program images missing under $IMG/ (run build_tests.sh on a host with vasm)" >&2
	exit 1
fi

SRC="$RTL/ap040_tg68k_compat.v $RTL/ap040_core.v $RTL/ap040_bus16_adapter.v $RTL/ap040_bus_timeout.v \
     $RTL/ap040_regfile.v $RTL/ap040_alu.v $RTL/ap040_muldiv.v $RTL/ap040_mmu.v $RTL/ap040_cache.v $RTL/ap040_fpu.v \
     $RTL/ap040_fill_cdc.v"

# generated sources: every bench below reads them, so they come first
python3 hoist_decls.py ../../rtl/cpu_wrapper.v "$WORK/cpu_wrapper_sim.v"
for m in fastchip rtg akiko gayle ide; do
	python3 hoist_decls.py "../../rtl/$m.v" "$WORK/${m}_sim.v"
done
python3 prepare_sdram_sim.py ../../rtl/sdram_ctrl.v "$WORK/sdram_ctrl_sim.v"

rm -f "$WORK"/.status.* "$WORK"/.divergent.*

VL="verilator --binary --timing -j 2 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -I$RTL"

# compile: name is only used to report which compile failed; the binary
# lands at $WORK/vl_<name>/tb_<name>
compile() {
	name=$1
	top=$2
	shift 2
	if $VL --top-module "$top" -Mdir "$WORK/vl_$name" -o "tb_$name" "$@" \
	   > "$WORK/compile_$name.log" 2>&1; then
		:
	else
		echo "compile $name" > "$WORK/.status.compile_$name"
		cat "$WORK/compile_$name.log" >&2
	fi
}

WRAPCHIP="tb_cpu_wrapper_chip.v $WORK/cpu_wrapper_sim.v \
	$WORK/fastchip_sim.v $WORK/rtg_sim.v $WORK/akiko_sim.v \
	$WORK/gayle_sim.v $WORK/ide_sim.v ../../rtl/ram_cs_guard.v \
	sim_dpram.v $SRC"
SDTURBO="tb_sdram_turbo.v $WORK/cpu_wrapper_sim.v $WORK/sdram_ctrl_sim.v \
	../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_walker_cdc.v $SRC"

compile reset tb_ap040_reset tb_ap040_reset.v sim_dpram.v $SRC &
compile prog tb_ap040_program tb_ap040_program.v sim_dpram.v $SRC &
compile double_fault tb_ap040_double_fault tb_ap040_double_fault.v sim_dpram.v $SRC &
compile walker_cdc tb_ap040_walker_cdc tb_ap040_walker_cdc.v $RTL/ap040_walker_cdc.v &
compile bus16_gap tb_ap040_bus16_gap tb_ap040_bus16_gap.v $RTL/ap040_bus16_adapter.v &
compile cpu_cache_new tb_cpu_cache_new tb_cpu_cache_new.v ../../rtl/cpu_cache_new.v &
compile ddram_walker_snoop tb_ddram_walker_snoop \
	tb_ddram_walker_snoop.v ../../rtl/ddram_ctrl.v \
	../../rtl/cpu_cache_new.v ../../rtl/A2065/a2065_ddram_arbiter.v sim_dpram.v &
compile ddram_walker_read tb_ddram_walker_read \
	tb_ddram_walker_read.v ../../rtl/ddram_ctrl.v \
	../../rtl/cpu_cache_new.v ../../rtl/A2065/a2065_ddram_arbiter.v \
	$RTL/ap040_walker_cdc.v $RTL/ap040_fill_cdc.v $RTL/ap040_bus_timeout.v sim_dpram.v &
compile bus_timeout tb_ap040_bus_timeout tb_ap040_bus_timeout.v $RTL/ap040_bus_timeout.v &
compile cart_hrtmon tb_cart_hrtmon tb_cart_hrtmon.v ../../rtl/cart.v &
compile cache_snoop tb_ap040_cache_snoop tb_ap040_cache_snoop.v sim_dpram.v $RTL/ap040_cache.v &
compile sdram32 tb_sdram32 tb_sdram32.v ../../rtl/sdram32_ctrl.v \
	"$WORK/sdram_ctrl_sim.v" ../../rtl/cpu_cache_new.v sim_dpram.v &
wait
compile wrapchip tb_cpu_wrapper_chip $WRAPCHIP &
compile wrapchip_l0 tb_cpu_wrapper_chip -GRAM_LAT=0 $WRAPCHIP &
compile wrapchip_l7 tb_cpu_wrapper_chip -GRAM_LAT=7 $WRAPCHIP &
compile wrapchip_turbo tb_cpu_wrapper_chip -GTURBO_CHIP=1 $WRAPCHIP &
wait
compile sdram_turbo tb_sdram_turbo -GCYC_PHASE=1 -GCPU_PHASE=0 $SDTURBO &
compile sdram_turbo_ph3 tb_sdram_turbo -GCYC_PHASE=1 -GCPU_PHASE=3 $SDTURBO &
compile dualram_turbo tb_dualram_turbo -GCYC_PHASE=1 -GCPU_PHASE=3 \
	tb_dualram_turbo.v "$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v ../../rtl/ddram_ctrl.v \
	../../rtl/A2065/a2065_ddram_arbiter.v \
	sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_walker_cdc.v $SRC &
wait

if ls "$WORK"/.status.compile_* >/dev/null 2>&1; then
	echo "AP040 regression (verilator): COMPILE FAILURES, see $WORK/compile_*.log"
	exit 1
fi

# run: every leg is independent, so they all go at once
leg() {
	name=$1
	bin=$2
	shift 2
	if "$WORK/vl_$bin/tb_$bin" "$@" > "$WORK/$name.log" 2>&1 &&
	   grep -q "ALL TESTS PASSED" "$WORK/$name.log"; then
		:
	else
		echo "$name" > "$WORK/.status.$name"
	fi
}

# KNOWN DIVERGENCE (2026-09-02, unmodified X2 RTL): legs that pass under
# Icarus and fail under Verilator, where the failure is in the BENCH's
# own timing, not in the RTL under test:
#   sdram32       FIXED the same day: fill_line raised the request and
#                 then read beat counters that the monitor block reset
#                 one edge later; which of the two ran first was
#                 unspecified, and Verilator's order let the task return
#                 on the previous fill's counts.  The task now resets its
#                 own counters before the request.  Counted again.
#   fpu_sdram     tb_sdram_turbo at CPU_PHASE=0 derives clk28
#   mmu_sdram     combinationally from the clk113 counter, so the 28 MHz
#                 edge shares a time step with the 113 MHz one; at this
#                 alignment (the guard-hostile one -- see run_tests.sh)
#                 the two simulators order the cross-domain sampling
#                 differently and the boot wedges before the first test.
#                 The CPU_PHASE=3 instances of the same bench pass.
# These run and are REPORTED, but do not fail the regression, until each
# bench is made order-independent (plan X3.1).  A leg listed here that
# starts PASSING should be removed from the list in the same commit.
divleg() {
	name=$1
	bin=$2
	shift 2
	if "$WORK/vl_$bin/tb_$bin" "$@" > "$WORK/$name.log" 2>&1 &&
	   grep -q "ALL TESTS PASSED" "$WORK/$name.log"; then
		echo "$name: PASSES under verilator -- remove it from the divergent list" \
			> "$WORK/.divergent.$name"
	else
		echo "$name: known divergence, see $WORK/$name.log" \
			> "$WORK/.divergent.$name"
	fi
}

# a negative leg passes only when the bench FAILS: the deliberate-break
# modes must stay capable of failing, or the positive checks prove nothing
negleg() {
	name=$1
	bin=$2
	shift 2
	if "$WORK/vl_$bin/tb_$bin" "$@" > "$WORK/$name.log" 2>&1 &&
	   grep -q "TEST FAILED" "$WORK/$name.log"; then
		:
	else
		echo "$name" > "$WORK/.status.$name"
	fi
}

leg reset              reset &
leg double_fault       double_fault &
leg walker_cdc         walker_cdc &
leg bus16_gap          bus16_gap &
leg cpu_cache_new      cpu_cache_new &
leg ddram_walker_snoop ddram_walker_snoop &
leg ddram_walker_read  ddram_walker_read &
leg bus_timeout        bus_timeout &
leg cart_hrtmon        cart_hrtmon &
leg sdram32            sdram32 &
leg cache_snoop        cache_snoop &
negleg sdram32_brk_lock sdram32 +break_lockstep &
negleg sdram32_brk_lane sdram32 +break_laneswap &
negleg sdram32_brk_wr   sdram32 +break_chipwr &
leg sdram32_nomod      sdram32 +no_module &
leg integer            prog +prog=$IMG/t_integer.hex &
leg exceptions         prog +prog=$IMG/t_exceptions.hex &
leg mmu                prog +prog=$IMG/t_mmu.hex &
leg cache              prog +prog=$IMG/t_cache.hex &
leg fpu                prog +prog=$IMG/t_fpu.hex &
leg fpu_chip           wrapchip +prog=$IMG/t_fpu.hex &
leg exceptions_chip    wrapchip +prog=$IMG/t_exceptions.hex &
leg exceptions_chip_l0 wrapchip_l0 +prog=$IMG/t_exceptions.hex &
leg exceptions_chip_l7 wrapchip_l7 +prog=$IMG/t_exceptions.hex &
# t_cache is deliberately absent from the chip benches: see run_tests.sh
leg exceptions_turbo   wrapchip_turbo +prog=$IMG/t_exceptions.hex &
leg mmu_turbo          wrapchip_turbo +prog=$IMG/t_mmu.hex &
leg fpu_turbo          wrapchip_turbo +prog=$IMG/t_fpu.hex &
leg integer_turbo      wrapchip_turbo +prog=$IMG/t_integer.hex &
leg mmu_chip           wrapchip +prog=$IMG/t_mmu.hex &
divleg fpu_sdram       sdram_turbo +prog=$IMG/t_fpu.hex &
divleg mmu_sdram       sdram_turbo +prog=$IMG/t_mmu.hex &
leg mmu_sdram_ph3      sdram_turbo_ph3 +prog=$IMG/t_mmu.hex &
leg fpu_dualram        dualram_turbo +prog=$IMG/t_fpu.hex &
leg fpu_sdram_ph3      sdram_turbo_ph3 +prog=$IMG/t_fpu.hex &
wait

if ls "$WORK"/.divergent.* >/dev/null 2>&1; then
	echo "AP040 regression (verilator): known-divergent legs (not counted):"
	for f in "$WORK"/.divergent.*; do
		echo "  $(cat "$f")"
	done
fi

if ls "$WORK"/.status.* >/dev/null 2>&1; then
	echo "AP040 regression (verilator): FAILURES in:"
	for f in "$WORK"/.status.*; do
		name=$(cat "$f")
		echo "  $name  ($WORK/$name.log)"
	done
	exit 1
fi

echo "AP040 regression: ALL TESTS PASSED"
