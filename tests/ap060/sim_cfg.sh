#!/bin/sh
# Build one configuration of tb_ap060_wrapchip and run one program:
#   sim_cfg.sh <name> "<-G params>" <prog> [plusargs...]
set -eu
cd "$(dirname "$0")"
name=$1; params=$2; prog=$3; shift 3
R=../../rtl; A=$R/ap060
SRC="$R/cpu_wrapper.v $R/memory_router.v $R/fastchip.v $R/rtg.v $R/akiko.v $R/akiko_hps_bridge.v $R/akiko_nvram.v $R/gayle.v $R/ide.v
     $R/ddram_ctrl.v $R/cpu_cache_new.v $R/A2065/a2065_ddram_arbiter.v $R/A2065/a2065_ddr3_mailbox.v sim_dpram.v
     $A/ap68060_pkg.sv $A/gen/ap68060_upkg.sv $A/ap68060_alu.sv $A/ap68060_alu_slow.sv $A/ap68060_muldiv.sv
     $A/ap68060_biu.sv $A/ap68060_ram.sv $A/ap68060_atc.sv $A/ap68060_dmu.sv $A/ap68060_predec.sv
     $A/ap68060_fetch.sv $A/ap68060_decode.sv $A/ap68060_useq.sv $A/fpu/ap040_fpu.v $A/ap68060_fpif.sv
     $A/ap68060_backend.sv $A/ap68060_snoop.sv $A/ap68060.sv $A/fastram/ap030_async_fifo.v $A/fastram/ap030_l2ram.sv $A/fastram/ap030_fastram_fe.v $A/fastram/ap030_fastram_be.v $A/fastram/ap060_fastram_bus.sv $A/fastram/ap060_fastram.sv $A/ap060_tg68k_compat.v"
VFLAGS="--binary --timing -j 16 --build-jobs 16 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH
        -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-UNOPTFLAT
        -Werror-PINMISSING -I$A -I$A/fpu"
mkdir -p build
# shellcheck disable=SC2086
verilator $VFLAGS $params --top-module tb_ap060_wrapchip --Mdir "build/obj_$name" -o tb \
    tb_ap060_wrapchip.sv $SRC > "build/build_$name.log" 2>&1 || { grep -E '%Error' "build/build_$name.log" | head; exit 1; }
cd build && exec "./obj_$name/tb" "+prog=$prog.hex" "$@"
