#!/bin/bash
# AP68040 Minimig regression under Verilator.
#
# The CPU benches run the self-checking programs (asm/) through the real
# cpu_wrapper with the AP68040 behind it: over the 7 MHz chip bus with the
# fast-chip block (tb_cpu_wrapper_chip, at three RAM-port latencies and in
# turbo-chipram mode), through sdram_ctrl and cpu_cache_new at the board's
# phase-locked 28/113 MHz ratio (tb_sdram_turbo, at the hardware's clock
# alignment and at the guard-hostile one), and through both RAM controllers
# at once (tb_dualram_turbo).  The infrastructure benches cover the parts
# around the CPU.  The core itself is regressed in its own repository.
#
# Usage: run_verilator_tests.sh [workdir]      JOBS=<n> parallel builds/legs
# Both phases run concurrently: every bench build is independent once the
# programs are assembled, and every simulation leg is independent.
set -u
cd "$(dirname "$0")"
WORK=${1:-$PWD/build/vl}
JOBS=${JOBS:-$(( $(nproc) / 2 ))}
mkdir -p "$WORK/gen"

./build_tests.sh > "$WORK/asm.log" 2>&1 || { cat "$WORK/asm.log"; exit 1; }

RTL=../../rtl
AP=$RTL/ap68040
CORE="$AP/ap68040_pkg.sv $AP/gen/ap68040_upkg.sv $AP/ap68040_alu.sv $AP/ap68040_alu_slow.sv
      $AP/ap68040_muldiv.sv $AP/ap68040_biu.sv $AP/ap68040_ram.sv $AP/ap68040_atc.sv
      $AP/ap68040_dmu.sv $AP/ap68040_predec.sv $AP/ap68040_fetch.sv $AP/ap68040_decode.sv
      $AP/ap68040_useq.sv $AP/fpu/ap040_fpu.v $AP/ap68040_fpif.sv $AP/ap68040_backend.sv
      $AP/ap68040_snoop.sv $AP/ap68040.sv $AP/ap040_bus16_adapter.v $AP/ap040_bus_timeout.v
      $AP/ap68040_minimig.sv"
CPU="$RTL/cpu_wrapper.v $RTL/ram_cs_guard.v sim_dpram.v $CORE"
CHIP="$RTL/fastchip.v $RTL/rtg.v $RTL/akiko.v $RTL/gayle.v $RTL/ide.v"
# sdram_ctrl's inout-reg idiom made legal for a two-state simulator
python3 prepare_sdram_sim.py $RTL/sdram_ctrl.v "$WORK/gen/sdram_ctrl_sim.v"
SDRAM="$WORK/gen/sdram_ctrl_sim.v $RTL/cpu_cache_new.v"

VFLAGS="--binary --timing -j 2 --build-jobs 2 -O3 -Wno-fatal
        -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY
        -Wno-TIMESCALEMOD -Wno-DECLFILENAME -I$AP -I$AP/fpu"
CF="-O2 -march=native"

rm -f "$WORK"/.status.*

# build <name> <top> <timescale> <sources and -G parameters>
build() {
	name=$1; top=$2; ts=$3; shift 3
	# shellcheck disable=SC2086
	if ! verilator $VFLAGS --timescale "$ts" --top-module "$top" \
	     --Mdir "$WORK/obj_$name" -o tb -CFLAGS "$CF" "$@" > "$WORK/build_$name.log" 2>&1; then
		echo "compile $name" > "$WORK/.status.compile_$name"
		grep -E '%Error' "$WORK/build_$name.log" | head -20 >&2
	fi
}

# the builds, JOBS at a time
sem() { while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done; }
# shellcheck disable=SC2086
{
sem; build wrapchip       tb_cpu_wrapper_chip 1ns/1ns   tb_cpu_wrapper_chip.v $RTL/cart.v $CHIP $CPU &
sem; build wrapchip_l0    tb_cpu_wrapper_chip 1ns/1ns   -GRAM_LAT=0 tb_cpu_wrapper_chip.v $RTL/cart.v $CHIP $CPU &
sem; build wrapchip_l7    tb_cpu_wrapper_chip 1ns/1ns   -GRAM_LAT=7 tb_cpu_wrapper_chip.v $RTL/cart.v $CHIP $CPU &
# turbo chipram: cchip claims $000000-$1FFFFF, so fetches AND data leave the
# chip bus for the accelerated RAM port.  That is how an accelerated board
# runs, and it is the only configuration where a fastchip access follows a
# RAM access rather than a chip-bus one.
sem; build wrapchip_turbo tb_cpu_wrapper_chip 1ns/1ns   -GTURBO_CHIP=1 tb_cpu_wrapper_chip.v $RTL/cart.v $CHIP $CPU &
# the coherence programs: a Zorro III board to configure, the cartridge
sem; build wrapchip_z3    tb_cpu_wrapper_chip 1ns/1ns   -GFASTRAM_CFG=4 tb_cpu_wrapper_chip.v $RTL/cart.v $CHIP $CPU &
# CPU_PHASE=0 is a guard-hostile clock alignment; CPU_PHASE=3 is the
# board's, the only one whose chip stage machine samples ph2 and so the
# only one that delivers interrupts (t_fpu's IRQ soak needs it)
sem; build sdram_ph0      tb_sdram_turbo      100ps/100ps -GCPU_PHASE=0 -GCYC_PHASE=1 tb_sdram_turbo.v $SDRAM $CPU &
sem; build sdram_ph3      tb_sdram_turbo      100ps/100ps -GCPU_PHASE=3 -GCYC_PHASE=1 tb_sdram_turbo.v $SDRAM $CPU &
sem; build dualram        tb_dualram_turbo    100ps/100ps -GCPU_PHASE=3 -GCYC_PHASE=1 tb_dualram_turbo.v $SDRAM $RTL/ddram_ctrl.v $RTL/A2065/a2065_ddram_arbiter.v $CPU &
# the parts around the CPU
sem; build cpu_cache_new  tb_cpu_cache_new    1ns/1ns   tb_cpu_cache_new.v $RTL/cpu_cache_new.v &
sem; build bus_timeout    tb_ap040_bus_timeout 1ns/1ns  tb_ap040_bus_timeout.v $AP/ap040_bus_timeout.v &
sem; build bus16_gap      tb_ap040_bus16_gap  1ns/1ns   tb_ap040_bus16_gap.v $AP/ap040_bus16_adapter.v &
sem; build cart_hrtmon    tb_cart_hrtmon      1ns/1ns   tb_cart_hrtmon.v $RTL/cart.v &
# tb_sdram32 drives its break modes with procedural continuous assignments,
# which only Icarus evaluates as the bench means them: it stays on Icarus
sem; { iverilog -g2012 -s tb_sdram32 -o "$WORK/tb_sdram32.vvp" tb_sdram32.v \
	$RTL/sdram32_ctrl.v $SDRAM sim_dpram.v > "$WORK/build_sdram32.log" 2>&1 ||
	echo "compile sdram32" > "$WORK/.status.compile_sdram32"; } &
sem; build ddram_walker_snoop tb_ddram_walker_snoop 1ns/1ns tb_ddram_walker_snoop.v $RTL/ddram_ctrl.v $RTL/cpu_cache_new.v $RTL/A2065/a2065_ddram_arbiter.v sim_dpram.v &
wait
}

if ls "$WORK"/.status.compile_* >/dev/null 2>&1; then
	echo "AP68040 Minimig regression: COMPILE FAILURES, see $WORK/build_*.log"
	exit 1
fi

# run <bench> [plusargs]: the Verilator binary, or the Icarus image
run() {
	bench=$1; shift
	if [ -x "$WORK/obj_$bench/tb" ]; then timeout 3600 "$WORK/obj_$bench/tb" "$@"
	else timeout 3600 vvp "$WORK/tb_$bench.vvp" "$@"; fi
}
# leg <name> <bench> [plusargs]: passes on "ALL TESTS PASSED"
leg() {
	name=$1; bench=$2; shift 2
	if run "$bench" "$@" > "$WORK/$name.log" 2>&1 &&
	   grep -q "ALL TESTS PASSED" "$WORK/$name.log"; then
		:
	else
		echo "$name" > "$WORK/.status.$name"
	fi
}
# a negative leg passes only when the bench FAILS: the deliberate-break
# modes must stay capable of failing, or the positive checks prove nothing
negleg() {
	name=$1; bench=$2; shift 2
	if run "$bench" "$@" > "$WORK/$name.log" 2>&1 &&
	   grep -q "TEST FAILED" "$WORK/$name.log"; then
		:
	else
		echo "$name" > "$WORK/.status.$name"
	fi
}

{
sem; leg integer_chip       wrapchip       +prog=build/t_integer.hex &
sem; leg exceptions_chip    wrapchip       +prog=build/t_exceptions.hex &
sem; leg mmu_chip           wrapchip       +prog=build/t_mmu.hex &
sem; leg fpu_chip           wrapchip       +prog=build/t_fpu.hex &
# the RAM port's acknowledgement outlives its own access, so the latency at
# which a stale ready overlaps the next request is what decides whether
# bus_complete can cross targets -- one value proves nothing
sem; leg exceptions_chip_l0 wrapchip_l0    +prog=build/t_exceptions.hex &
sem; leg exceptions_chip_l7 wrapchip_l7    +prog=build/t_exceptions.hex &
sem; leg integer_turbo      wrapchip_turbo +prog=build/t_integer.hex &
sem; leg exceptions_turbo   wrapchip_turbo +prog=build/t_exceptions.hex &
sem; leg mmu_turbo          wrapchip_turbo +prog=build/t_mmu.hex &
sem; leg fpu_turbo          wrapchip_turbo +prog=build/t_fpu.hex &
# caches and the platform (only fast RAM is cacheable; the level 7 vector
# is read past the cache): each with its TTR-inhibited control
for c in io io_ci dma dma_ci smc smc_ci nmi_warm nmi_cold; do
	sem; leg coh_$c wrapchip_z3 +prog=build/coh_$c.hex &
done
sem; leg sdram_mmu_ph0      sdram_ph0      +prog=build/t_mmu.hex &
sem; leg sdram_fpu_ph0      sdram_ph0      +prog=build/t_fpu.hex &
sem; leg sdram_mmu_ph3      sdram_ph3      +prog=build/t_mmu.hex &
sem; leg sdram_fpu_ph3      sdram_ph3      +prog=build/t_fpu.hex &
sem; leg dualram_fpu        dualram        +prog=build/t_fpu.hex &
sem; leg cpu_cache_new      cpu_cache_new &
sem; leg bus_timeout        bus_timeout &
sem; leg bus16_gap          bus16_gap &
sem; leg cart_hrtmon        cart_hrtmon &
sem; leg sdram32            sdram32 &
sem; negleg sdram32_brk_lock sdram32 +break_lockstep &
sem; negleg sdram32_brk_lane sdram32 +break_laneswap &
sem; negleg sdram32_brk_wr   sdram32 +break_chipwr &
sem; leg sdram32_nomod      sdram32 +no_module &
sem; leg ddram_walker_snoop ddram_walker_snoop &
wait
}

if ls "$WORK"/.status.* >/dev/null 2>&1; then
	echo "AP68040 Minimig regression: FAILURES in:"
	for f in "$WORK"/.status.*; do
		name=$(cat "$f")
		echo "  $name  ($WORK/$name.log)"
	done
	exit 1
fi
echo "AP68040 Minimig regression: ALL TESTS PASSED"
