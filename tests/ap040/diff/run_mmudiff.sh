#!/bin/sh
# Differential test: AP040 (verilator) vs qemu-system-m68k (68040).
# Usage: run_diff.sh <first_seed> <last_seed> [instr_count]

set -e
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
SIM=${SIM:?path to verilated Vtb_ap040_program}
FIRST=${1:-1}
LAST=${2:-20}
COUNT=${3:-32}
mkdir -p work

fails=0
for seed in $(seq "$FIRST" "$LAST"); do
	python3 gen_mmudiff.py "$seed" "$COUNT" > work/p.s
	$VASM -Fbin -m68040 -no-opt -o work/p.bin work/p.s > /dev/null 2>&1
	python3 ../bin2hex.py work/p.bin work/p.hex

	( cd work && "$SIM" +prog=p.hex +dump=ap040.hex > sim.log 2>&1 ) || true
	if ! grep -q "ALL TESTS PASSED" work/sim.log; then
		echo "seed $seed: AP040 run failed"
		grep -E "FAIL" work/sim.log | head -3
		fails=$((fails+1))
		continue
	fi

	( cd work && { sleep 1; echo "pmemsave 0x3000 0x1000 qemu.dump"; sleep 0.3; echo q; } | \
	  timeout 20 qemu-system-m68k -M virt -cpu m68040 -display none -serial none \
	    -monitor stdio -device loader,file=p.bin,addr=0 \
	    -device loader,addr=0x400,cpu-num=0 > /dev/null 2>&1 )

	if python3 cmp_diff.py work/ap040.hex work/qemu.dump --strict; then
		echo "seed $seed: MATCH"
	else
		echo "seed $seed: MISMATCH (artifacts in diff/work)"
		fails=$((fails+1))
	fi
done

if [ "$fails" -eq 0 ]; then
	echo "DIFFERENTIAL: all seeds match"
else
	echo "DIFFERENTIAL: $fails seed(s) diverged"
	exit 1
fi
