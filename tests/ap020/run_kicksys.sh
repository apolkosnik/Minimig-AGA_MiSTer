#!/bin/sh
# Boot a Kickstart ROM through the Minimig CPU path (tb_ap020_kicksys.sv):
# cpu_wrapper with the AP020 and its compat layer, ram_cs_guard and
# sdram_ctrl with cpu_cache_new on a behavioural SDRAM.
# Usage: sh run_kicksys.sh <512K kickstart.rom> [workdir] [plusargs...]
#   NODCACHE=1  build without the AP020 data cache (AP020_NO_DCACHE)
#   plusargs:   +dcache (OSD data cache option), +cycles=<clk_114 cycles>
set -eu
cd "$(dirname "$0")"
ROM=$1; WORK=${2:-build/kick}; shift; [ $# -gt 0 ] && shift
mkdir -p "$WORK"
R=../../rtl
A=$R/ap020
python3 - "$ROM" "$WORK/kick.hex" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
assert len(b) == 524288, "a 512K ROM is needed"
open(sys.argv[2], 'w').write('\n'.join('%04x' % ((b[i] << 8) | b[i+1]) for i in range(0, len(b), 2)) + '\n')
PY
DEF=""
[ "${NODCACHE:-0}" = 1 ] && DEF="-DAP020_NO_DCACHE"
# shellcheck disable=SC2086
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-PINMISSING -O1 -I$A -I$A/core -I$R $DEF \
    --top-module tb_ap020_kicksys --Mdir "$WORK/obj" -o tb tb_ap020_kicksys.sv \
    $R/cpu_wrapper.v $R/memory_router.v $R/ram_cs_guard.v $R/sdram_ctrl.v $R/cpu_cache_new.v \
    $R/ap040/ap040_bus_timeout.v ../ap040/sim_dpram.v \
    $A/ap020_tg68k_compat.v $A/ap020_async_fifo.v $A/ap020_l2ram.sv $A/ap020_fastram_fe.v $A/ap020_fastram_be.v \
    $A/ap020_top.v $A/ap020_core.v $A/ap020_memsys.v $A/ap020_cache.v $A/ap020_bus.v $A/ap020_alu.v \
    $A/ap020_muldiv.v $A/ap020_regfile.v > "$WORK/build.log" 2>&1 || { grep -E "%Error" "$WORK/build.log" | head; exit 1; }
"$WORK/obj/tb" "+rom=$WORK/kick.hex" "$@"
