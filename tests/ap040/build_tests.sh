#!/bin/sh
# Assemble the AP040 self-test programs into $readmemh images.
# Requires vasmm68k_mot (vbcc toolchain).

set -e
cd "$(dirname "$0")"

VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
mkdir -p build

for t in t_integer t_exceptions t_mmu t_cache t_fpu; do
	$VASM -Fbin -m68040 -no-opt -o build/$t.bin asm/$t.s
	python3 bin2hex.py build/$t.bin build/$t.hex
	echo "built build/$t.hex"
done
