#!/bin/sh
# Build and run all AP040 tests with Icarus Verilog.
# Usage: run_tests.sh [workdir]

set -e
cd "$(dirname "$0")"
RTL=../../rtl/ap040
WORK=${1:-build}
mkdir -p "$WORK"

./build_tests.sh

SRC="$RTL/ap040_tg68k_compat.v $RTL/ap040_core.v $RTL/ap040_bus16_adapter.v \
     $RTL/ap040_regfile.v $RTL/ap040_alu.v $RTL/ap040_muldiv.v $RTL/ap040_mmu.v $RTL/ap040_cache.v $RTL/ap040_fpu.v"

iverilog -g2012 -I "$RTL" -o "$WORK/tb_reset.vvp" tb_ap040_reset.v $SRC
	iverilog -g2012 -I "$RTL" -o "$WORK/tb_prog.vvp" tb_ap040_program.v $SRC
	iverilog -g2012 -I "$RTL" -o "$WORK/tb_double_fault.vvp" \
		tb_ap040_double_fault.v $SRC
iverilog -g2012 -I "$RTL" -o "$WORK/tb_walker_cdc.vvp" \
	tb_ap040_walker_cdc.v $RTL/ap040_walker_cdc.v
iverilog -g2012 -I "$RTL" -o "$WORK/tb_bus16_gap.vvp" \
	tb_ap040_bus16_gap.v $RTL/ap040_bus16_adapter.v
iverilog -g2012 -s tb_cpu_cache_new -o "$WORK/tb_cpu_cache_new.vvp" \
	tb_cpu_cache_new.v ../../rtl/cpu_cache_new.v
iverilog -g2012 -s tb_ddram_walker_snoop -o "$WORK/tb_ddram_walker_snoop.vvp" \
	tb_ddram_walker_snoop.v ../../rtl/ddram_ctrl.v \
	../../rtl/cpu_cache_new.v ../../rtl/A2065/a2065_ddram_arbiter.v sim_dpram.v
iverilog -g2012 -o "$WORK/tb_bus_timeout.vvp" \
	tb_ap040_bus_timeout.v $RTL/ap040_bus_timeout.v
iverilog -g2012 -o "$WORK/tb_cart_hrtmon.vvp" \
	tb_cart_hrtmon.v ../../rtl/cart.v
python3 hoist_decls.py ../../rtl/cpu_wrapper.v "$WORK/cpu_wrapper_sim.v"
iverilog -g2012 -I "$RTL" -o "$WORK/tb_wrapchip.vvp" tb_cpu_wrapper_chip.v \
	"$WORK/cpu_wrapper_sim.v" $RTL/ap040_bus_timeout.v $SRC
python3 prepare_sdram_sim.py ../../rtl/sdram_ctrl.v "$WORK/sdram_ctrl_sim.v"
iverilog -g2012 -I "$RTL" -s tb_sdram_turbo \
	-P tb_sdram_turbo.CYC_PHASE=1 -P tb_sdram_turbo.CPU_PHASE=0 \
	-o "$WORK/tb_sdram_turbo.vvp" tb_sdram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_bus_timeout.v $RTL/ap040_walker_cdc.v $SRC
iverilog -g2012 -I "$RTL" -s tb_dualram_turbo \
	-P tb_dualram_turbo.CYC_PHASE=1 -P tb_dualram_turbo.CPU_PHASE=3 \
	-o "$WORK/tb_dualram_turbo.vvp" tb_dualram_turbo.v \
	"$WORK/cpu_wrapper_sim.v" "$WORK/sdram_ctrl_sim.v" \
	../../rtl/cpu_cache_new.v ../../rtl/ddram_ctrl.v \
	../../rtl/A2065/a2065_ddram_arbiter.v \
	sim_dpram.v ../../rtl/ram_cs_guard.v \
	$RTL/ap040_bus_timeout.v $RTL/ap040_walker_cdc.v $SRC

fail=0
vvp "$WORK/tb_reset.vvp" | tee "$WORK/reset.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_double_fault.vvp" | tee "$WORK/double_fault.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_walker_cdc.vvp" | tee "$WORK/walker_cdc.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_bus16_gap.vvp" | tee "$WORK/bus16_gap.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_cpu_cache_new.vvp" | tee "$WORK/cpu_cache_new.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_ddram_walker_snoop.vvp" | tee "$WORK/ddram_walker_snoop.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_bus_timeout.vvp" | tee "$WORK/bus_timeout.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_cart_hrtmon.vvp" | tee "$WORK/cart_hrtmon.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_prog.vvp" +prog=build/t_integer.hex | tee "$WORK/integer.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_prog.vvp" +prog=build/t_exceptions.hex | tee "$WORK/exceptions.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_prog.vvp" +prog=build/t_mmu.hex | tee "$WORK/mmu.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_prog.vvp" +prog=build/t_cache.hex | tee "$WORK/cache.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_prog.vvp" +prog=build/t_fpu.hex | tee "$WORK/fpu.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_wrapchip.vvp" +prog=build/t_fpu.hex | tee "$WORK/fpu_chip.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_sdram_turbo.vvp" +prog=build/t_fpu.hex | tee "$WORK/fpu_turbo.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_dualram_turbo.vvp" +prog=build/t_fpu.hex | tee "$WORK/fpu_dualram.log" | grep -q "ALL TESTS PASSED" || fail=1

if [ $fail -eq 0 ]; then
	echo "AP040 regression: ALL TESTS PASSED"
else
	echo "AP040 regression: FAILURES, see $WORK/*.log"
	exit 1
fi
