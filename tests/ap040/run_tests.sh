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
     $RTL/ap040_regfile.v $RTL/ap040_alu.v $RTL/ap040_muldiv.v"

iverilog -g2012 -I "$RTL" -o "$WORK/tb_reset.vvp" tb_ap040_reset.v $SRC
iverilog -g2012 -I "$RTL" -o "$WORK/tb_prog.vvp" tb_ap040_program.v $SRC

fail=0
vvp "$WORK/tb_reset.vvp" | tee "$WORK/reset.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_prog.vvp" +prog=build/t_integer.hex | tee "$WORK/integer.log" | grep -q "ALL TESTS PASSED" || fail=1
vvp "$WORK/tb_prog.vvp" +prog=build/t_exceptions.hex | tee "$WORK/exceptions.log" | grep -q "ALL TESTS PASSED" || fail=1

if [ $fail -eq 0 ]; then
	echo "AP040 regression: ALL TESTS PASSED"
else
	echo "AP040 regression: FAILURES, see $WORK/*.log"
	exit 1
fi
