#!/bin/sh
# The full-system simulation of the AP060 Minimig (Verilator): emu
# (Minimig.sv) with all its real RTL -- the AP68060 through
# ap060_tg68k_compat, the chipset, sdram_ctrl, ddram_ctrl and the Fast RAM
# port -- on upstream's models of the SDRAM chip and the DDR3 port
# (rtl/sim/system), booting a real Kickstart.  The processor's PLL is
# replaced by pll_cpu_sim.sv, clocked by the driver at its own frequency.
# OBJ=<dir> picks the object directory (default obj_dir).
set -e
cd "$(dirname "$0")"
R=$(cd ../../.. && pwd)
U=$R/rtl/sim/system
mkdir -p gen
SRC=$(python3 - "$R" <<'PY'
import os, re, sys
R = sys.argv[1]
out = []
def qip(path):
	d = os.path.dirname(path)
	for l in open(path):
		m = re.search(r'-name (\w+) (?:\[file join \$::quartus\(qip_path\) )?"?([^"\]\s]+)', l)
		if not m: continue
		kind, f = m.groups()
		p = os.path.normpath(os.path.join(d if 'qip_path' in l else R, f))
		if kind == 'QIP_FILE': qip(p)
		elif kind in ('VERILOG_FILE', 'SYSTEMVERILOG_FILE') and os.path.exists(p) \
		     and not p.endswith('/pll_cpu.v'):
			out.append(p)
qip(os.path.join(R, 'files.qip'))
print(' '.join(out))
PY
)
echo '`define BUILD_DATE "sim"' > gen/build_id.v
SYS="$R/sys/hps_io.sv $R/sys/video_mixer.sv $R/sys/scandoubler.v $R/sys/hq2x.sv $R/sys/gamma_corr.sv
 $R/sys/video_freak.sv $R/sys/math.sv $R/sys/mt32pi.sv $R/sys/iir_filter.v"
verilator --cc --exe --build --no-timing -j 24 -O3 --x-assign fast --x-initial fast \
	-Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
	-Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-LATCH -Wno-COMBDLY -Wno-IMPLICIT -Wno-PINCONNECTEMPTY -Wno-PROCASSWIRE \
	-DMISTER_FB=1 -DMISTER_FB_PALETTE=1 \
	--top-module tb_top -Mdir ${OBJ:-obj_dir} \
	-CFLAGS "-O2 -march=native" \
	-Igen -I$R -I$R/rtl -I$R/rtl/ap060 -I$R/rtl/ap060/fpu -I$R/sys \
	$U/sim_lib/dpram.sv $U/sim_lib/altsyncram.v $U/sim_lib/pll_sim.sv pll_cpu_sim.sv $SRC $SYS \
	$U/sdram_model.sv $U/ddr3_model.sv tb_top.sv sim_main.cpp "$@"
echo "built ${OBJ:-obj_dir}/Vtb_top"
