#!/bin/sh
# Boot a Kickstart ROM through the Minimig CPU path (tb_ap020_kicksys.sv):
# cpu_wrapper with the AP020 and its compat layer, Minimig.sv's ram_cs and
# sdram_ctrl with cpu_cache_new on a behavioural SDRAM.
# Usage: sh run_kicksys.sh <512K kickstart.rom> [workdir] [plusargs...]
#   NODCACHE=1  build without the AP020 data cache (AP020_NO_DCACHE)
#   CPUCFG=...  cpu_wrapper's cpucfg (default 5'b00011, the 68020)
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
python3 -I mif2hex.py $R/cycles/m68k_cyc_idx.mif "$WORK/m68k_cyc_idx.hex"
python3 -I mif2hex.py $R/cycles/m68k_ea_idx.mif "$WORK/m68k_ea_idx.hex"
cp $R/fx68k/microrom.mem $R/fx68k/nanorom.mem "$WORK/"
DEF=""
[ "${NODCACHE:-0}" = 1 ] && DEF="-DAP020_NO_DCACHE"
# shellcheck disable=SC2086
verilator --binary --timing --no-assert -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-BLKANDNBLK -O1 -I$A -I$A/core -I$R -I$R/fx68k $DEF -DCPU_CYCLES_HEX \
    "-GCPUCFG=${CPUCFG:-5'b00011}" \
    --top-module tb_ap020_kicksys --Mdir "$WORK/obj" -o tb tb_ap020_kicksys.sv \
    $R/cpu_wrapper.v $R/memory_router.v $R/cpu_cycles.v $R/sdram_ctrl.v $R/cpu_cache_new.v sim_dpram.v \
    $R/fx68k/fx68k.sv $R/fx68k/fx68kAlu.sv $R/fx68k/uaddrPla.sv \
    $A/ap020_tg68k_compat.v $A/ap020_async_fifo.v $A/ap020_l2ram.sv $A/ap020_fastram_fe.v $A/ap020_fastram_be.v \
    $A/ap020_top.v $A/ap020_core.v $A/ap020_memsys.v $A/ap020_cache.v $A/ap020_bus.v $A/ap020_alu.v \
    $A/ap020_muldiv.v $A/ap020_regfile.v > "$WORK/build.log" 2>&1 || { grep -E "%Error" "$WORK/build.log" | head; exit 1; }
cd "$WORK" && ./obj/tb "+rom=kick.hex" "+cyc_rom=m68k_cyc_idx.hex" "+ea_rom=m68k_ea_idx.hex" "$@"
