#!/bin/sh
# Assemble the standalone AP68040 core tree from this repository.
#
#   tools/export-ap68040.sh <path-to-AP68040-checkout>
#
# The CPU is developed here, inside Minimig-AGA_MiSTer, and published at
# https://github.com/apolkosnik/AP68040 so other projects can consume it as a
# submodule.  That publication is a COPY, so without something like this it
# drifts the moment rtl/ap040 changes and nobody notices until the two
# disagree.  Run this instead of copying by hand; it is idempotent, so
# `git status` in the target says exactly what a release would change.
#
# What is NOT exported, and why: the benches that co-simulate the core with a
# real Amiga chipset, sdram_ctrl, ddram_ctrl or fastchip stay here, because
# they need those modules and would not build standalone.  The suite that
# does go is CPU-only by construction, which is what makes a failure there
# the CPU's rather than an integration artifact.
set -eu

if [ $# -ne 1 ]; then
	echo "usage: $0 <path-to-AP68040-checkout>" >&2
	exit 2
fi
DST=$1
SRC=$(cd "$(dirname "$0")/.." && pwd)

[ -d "$DST/.git" ] || { echo "$DST is not a git checkout" >&2; exit 1; }
[ -f "$DST/LICENSE" ] || { echo "$DST has no LICENSE -- wrong directory?" >&2; exit 1; }

echo "exporting $SRC -> $DST"

# --- the core itself -------------------------------------------------------
mkdir -p "$DST/rtl/primitives"
rm -f "$DST"/rtl/*.v "$DST"/rtl/*.svh "$DST"/rtl/*.qip
cp "$SRC"/rtl/ap040/*.v "$SRC"/rtl/ap040/*.svh "$SRC"/rtl/ap040/ap040.qip "$DST/rtl/"
# ap040_defs.svh is included by every module, so it must land beside them.

# The cache and MMU instantiate `dpram`.  In this tree that resolves to the
# project's bram.vhd/altsyncram; the export ships the portable inferred
# version the benches use, which any flow can synthesise and any vendor macro
# can replace.
cp "$SRC/tests/ap040/sim_dpram.v" "$DST/rtl/primitives/dpram.v"

# --- CPU-only test suite ---------------------------------------------------
mkdir -p "$DST/tb/asm"
rm -f "$DST"/tb/*.v "$DST"/tb/asm/*.s
for f in tb_ap040_program tb_ap040_reset tb_ap040_double_fault \
         tb_ap040_walker_cdc tb_ap040_bus16_gap tb_ap040_bus_timeout \
         tb_ap040_cache_snoop; do
	cp "$SRC/tests/ap040/$f.v" "$DST/tb/"
done
cp "$SRC"/tests/ap040/asm/*.s "$DST/tb/asm/"
cp "$SRC/tests/ap040/bin2hex.py" "$SRC/tests/ap040/build_tests.sh" "$DST/tb/"

# --- files that belong to the export, versioned here so they cannot rot ----
cp "$SRC/extra/ap68040/README.md"       "$DST/README.md"
cp "$SRC/extra/ap68040/gitignore"       "$DST/.gitignore"
cp "$SRC/extra/ap68040/tb/run_tests.sh" "$DST/tb/run_tests.sh"
chmod +x "$DST/tb/run_tests.sh"

# --- documentation ---------------------------------------------------------
mkdir -p "$DST/doc"
cp "$SRC/CPUTEST_UPSTREAM_REPORT.md" "$DST/doc/"
cp "$SRC/tests/ap040/README"         "$DST/doc/tests-README"

echo "done.  Source commit: $(cd "$SRC" && git rev-parse --short HEAD)"
echo
echo "Next: cd $DST && ./tb/run_tests.sh && git status"
