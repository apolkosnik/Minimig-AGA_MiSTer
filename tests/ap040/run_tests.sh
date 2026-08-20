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

SRC="$RTL/ap040_tg68k_compat.v $RTL/ap040_core.v $RTL/ap040_bus16_adapter.v \
     $RTL/ap040_regfile.v $RTL/ap040_alu.v $RTL/ap040_muldiv.v $RTL/ap040_mmu.v $RTL/ap040_cache.v $RTL/ap040_fpu.v"

# generated sources: every bench below reads them, so they come first
python3 hoist_decls.py ../../rtl/cpu_wrapper.v "$WORK/cpu_wrapper_sim.v"
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

compile reset iverilog -g2012 -I "$RTL" -o "$WORK/tb_reset.vvp" \
	tb_ap040_reset.v sim_dpram.v $SRC &
compile prog iverilog -g2012 -I "$RTL" -o "$WORK/tb_prog.vvp" \
	tb_ap040_program.v sim_dpram.v $SRC &
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
compile bus_timeout iverilog -g2012 -o "$WORK/tb_bus_timeout.vvp" \
	tb_ap040_bus_timeout.v $RTL/ap040_bus_timeout.v &
compile cart_hrtmon iverilog -g2012 -o "$WORK/tb_cart_hrtmon.vvp" \
	tb_cart_hrtmon.v ../../rtl/cart.v &
compile wrapchip iverilog -g2012 -I "$RTL" -o "$WORK/tb_wrapchip.vvp" \
	tb_cpu_wrapper_chip.v "$WORK/cpu_wrapper_sim.v" \
	sim_dpram.v $RTL/ap040_bus_timeout.v $SRC &
compile sdram_turbo iverilog -g2012 -I "$RTL" -s tb_sdram_turbo \
	-P tb_sdram_turbo.CYC_PHASE=1 -P tb_sdram_turbo.CPU_PHASE=0 \
	-o "$WORK/tb_sdram_turbo.vvp" tb_sdram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_bus_timeout.v $RTL/ap040_walker_cdc.v $SRC &
# second sdram-turbo instance at the real-hardware phase alignment
# (CPU_PHASE=3): the only alignment whose chip stage machine can sample
# the ph2 pulse and therefore deliver interrupts -- t_fpu's IRQ soak
# needs it, while the CPU_PHASE=0 instance keeps the guard-hostile
# alignment coverage
compile sdram_turbo_ph3 iverilog -g2012 -I "$RTL" -s tb_sdram_turbo \
	-P tb_sdram_turbo.CYC_PHASE=1 -P tb_sdram_turbo.CPU_PHASE=3 \
	-o "$WORK/tb_sdram_turbo_ph3.vvp" tb_sdram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_bus_timeout.v $RTL/ap040_walker_cdc.v $SRC &
compile dualram_turbo iverilog -g2012 -I "$RTL" -s tb_dualram_turbo \
	-P tb_dualram_turbo.CYC_PHASE=1 -P tb_dualram_turbo.CPU_PHASE=3 \
	-o "$WORK/tb_dualram_turbo.vvp" tb_dualram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v ../../rtl/ddram_ctrl.v \
	../../rtl/A2065/a2065_ddram_arbiter.v \
	sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_bus_timeout.v $RTL/ap040_walker_cdc.v $SRC &
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
	if vvp "$@" > "$WORK/$name.log" 2>&1 &&
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
leg bus_timeout        "$WORK/tb_bus_timeout.vvp" &
leg cart_hrtmon        "$WORK/tb_cart_hrtmon.vvp" &
leg sdram32            "$WORK/tb_sdram32.vvp" &
leg cache_snoop        "$WORK/tb_cache_snoop.vvp" &
negleg sdram32_brk_lock "$WORK/tb_sdram32.vvp" +break_lockstep &
negleg sdram32_brk_lane "$WORK/tb_sdram32.vvp" +break_laneswap &
negleg sdram32_brk_wr   "$WORK/tb_sdram32.vvp" +break_chipwr &
leg sdram32_nomod      "$WORK/tb_sdram32.vvp" +no_module &
leg integer            "$WORK/tb_prog.vvp" +prog=build/t_integer.hex &
leg exceptions         "$WORK/tb_prog.vvp" +prog=build/t_exceptions.hex &
leg mmu                "$WORK/tb_prog.vvp" +prog=build/t_mmu.hex &
leg cache              "$WORK/tb_prog.vvp" +prog=build/t_cache.hex &
leg fpu                "$WORK/tb_prog.vvp" +prog=build/t_fpu.hex &
leg fpu_chip           "$WORK/tb_wrapchip.vvp" +prog=build/t_fpu.hex &
leg fpu_turbo          "$WORK/tb_sdram_turbo.vvp" +prog=build/t_fpu.hex &
leg fpu_dualram        "$WORK/tb_dualram_turbo.vvp" +prog=build/t_fpu.hex &
leg fpu_turbo_ph3      "$WORK/tb_sdram_turbo_ph3.vvp" +prog=build/t_fpu.hex &
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
