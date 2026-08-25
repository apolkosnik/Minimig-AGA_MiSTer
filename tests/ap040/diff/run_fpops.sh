#!/bin/sh
# FPU differential against WinUAE's own softfloat, not qemu.
# Usage: SIM=/path/to/Vtb_ap040_program ORACLE=/path/to/fp_oracle \
#        ./run_fpops.sh <first_seed> <last_seed> [slots]
set -e
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
SIM=${SIM:?path to verilated Vtb_ap040_program}
ORACLE=${ORACLE:?path to fp_oracle built against WinUAE softfloat}
FIRST=${1:-1}
LAST=${2:-20}
SLOTS=${3:-96}
mkdir -p work

fails=0
for seed in $(seq "$FIRST" "$LAST"); do
	python3 gen_fpops.py "$seed" "$SLOTS" work/ops.bin > work/fpops.s
	$VASM -Fbin -m68040 -no-opt -o work/fpops.bin work/fpops.s > /dev/null 2>&1
	python3 ../bin2hex.py work/fpops.bin work/fpops.hex
	( cd work && "$SIM" +prog=fpops.hex +dump=fpops_ap.hex > fpops_sim.log 2>&1 ) || true
	"$ORACLE" work/ops.bin work/fpops_ref.txt
	if python3 cmp_fpops.py work/fpops_ap.hex work/fpops_ref.txt work/ops.bin; then
		echo "seed $seed: MATCH ($SLOTS ops)"
	else
		echo "seed $seed: MISMATCH"
		fails=$((fails+1))
	fi
done
if [ "$fails" -eq 0 ]; then
	echo "FP vs WinUAE softfloat: all seeds match"
else
	echo "FP vs WinUAE softfloat: $fails seed(s) diverged"
	exit 1
fi
