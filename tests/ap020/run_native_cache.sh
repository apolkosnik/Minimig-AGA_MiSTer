#!/bin/sh
set -eu
cd "$(dirname "$0")"
WORK=${1:-build/native-cache}
mkdir -p "$WORK"
iverilog -g2012 -s tb_native_cache -o "$WORK/tb_native_cache" tb_native_cache.sv \
    ../../rtl/ap020/ap020_fastram_fe.v ../../rtl/ap020/ap020_l2ram.sv
vvp "$WORK/tb_native_cache"
