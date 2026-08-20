#!/bin/sh
# MMU differential against WinUAE's own cpummu.cpp, not qemu.
# Usage: SIM=/path/to/Vtb_ap040_program ORACLE=/path/to/mmu_oracle \
#        ./run_mmuops.sh <first_seed> <last_seed>
set -e
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
SIM=${SIM:?path to verilated Vtb_ap040_program}
ORACLE=${ORACLE:?path to mmu_oracle built against WinUAE cpummu.cpp}
FIRST=${1:-1}
LAST=${2:-20}
mkdir -p work

fails=0
for seed in $(seq "$FIRST" "$LAST"); do
	python3 gen_mmuops.py "$seed" work/mmu_mem.bin work/mmu_probes.txt > work/mmu.s
	$VASM -Fbin -m68040 -no-opt -o work/mmu.bin work/mmu.s > /dev/null 2>&1
	python3 ../bin2hex.py work/mmu.bin work/mmu.hex
	( cd work && "$SIM" +prog=mmu.hex +dump=mmu_ap.hex > mmu_sim.log 2>&1 ) || true
	"$ORACLE" work/mmu_mem.bin work/mmu_probes.txt work/mmu_ref.txt
	if python3 cmp_mmuops.py work/mmu_ap.hex work/mmu_ref.txt; then
		echo "seed $seed: MATCH"
	else
		echo "seed $seed: MISMATCH"
		fails=$((fails+1))
	fi
done
if [ "$fails" -eq 0 ]; then
	echo "MMU vs WinUAE cpummu: all seeds match"
else
	echo "MMU vs WinUAE cpummu: $fails seed(s) diverged"
	exit 1
fi
