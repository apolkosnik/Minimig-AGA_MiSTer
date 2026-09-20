#!/usr/bin/env bash
# Standalone Quartus fit of the pipelined core, for area and Fmax tracking.
#   tests/ap040/pipe_synth/run.sh [workdir]
# Copies the project to <workdir> (default /home/adam/ap040-audit4/pipe-synth)
# so no build products land in the repo, runs map/fit/sta in the FOREGROUND
# with its PID printed, and prints the four numbers the plan tracks.
#
# TOP_LEVEL_ENTITY is ap040_pipe_core: the CPU plus the L1 array, which is
# what the milestone benches run and what every fit in the plan has measured.
# ap040_pipe_sys.v (the CPU plus ap040_pipe_membus.v, no array) is in the
# file list too, so a fit of the bus-side top needs only the entity changed.
#
# L1_AW=4 on purpose: ap040_pipe_l1.v is a behavioural array with a
# combinational forward, so in synthesis it becomes flops, not RAM. At the
# default AW=12 that is 64 kbit of registers and swamps the core; at 4 it is
# ~600 ALMs and the same basis every fit in the plan has used. All ports are
# virtual (510 debug bits would exceed the pin count). 25 ns = the 40 MHz
# target; the real Minimig CPU clock is 35.234 ns.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; rtl="$(cd "$here/../../../rtl/ap040_pipe" && pwd)"
work="${1:-/home/adam/ap040-audit4/pipe-synth}"; rm -rf "$work"; mkdir -p "$work"
sed "s#\.\./\.\./\.\./rtl/ap040_pipe#$rtl#g" "$here/pipe.qsf" > "$work/pipe.qsf"
cp "$here/pipe.sdc" "$here/pipe.qpf" "$here/paths40.tcl" "$work/"; cd "$work"
Q=/opt/intelFPGA_lite/17.0/quartus/bin; echo "quartus pid $$ in $work"
# Temporaries go in the work directory, not the shared tmpfs: a full one
# fails tools with no diagnostic, which reads as a result rather than an
# error. Same reason run_pipe_verilator.py does it.
export TMPDIR="$work"
$Q/quartus_map pipe -c pipe > map.log 2>&1; $Q/quartus_fit pipe -c pipe > fit.log 2>&1; $Q/quartus_sta pipe -c pipe > sta.log 2>&1
echo "ALMs needed (top): $(awk -F': ' '/^ALMs needed/{a=$2; sub(/ \(.*/,"",a); print a; exit}' output_files/pipe.fit.rpt)"
echo "ALU ALMs:          $(awk -F': ' '/^Compilation Hierarchy Node/{n=$2} /^ALMs needed/{a=$2; sub(/ \(.*/,"",a); if (n ~ /ap040_pipe_alu/) {print a; exit}}' output_files/pipe.fit.rpt)"
echo "Fmax (slow 100C):  $(awk '/Slow 1100mV 100C Model Fmax Summary/{f=1} f&&/^Fmax/{print $3, $4; exit}' output_files/pipe.sta.rpt)"
echo "Setup slack @25ns: $(awk '/Slow 1100mV 100C Model Setup Summary/{f=1} f&&/^Slack/{print $3; exit}' output_files/pipe.sta.rpt)"
$Q/quartus_sta -t paths40.tcl > paths40.log 2>&1 || true
echo "Worst path delay:   $(awk -F': *' '/^Data Delay/{print $2; exit}' paths40.txt) ns  (40 worst paths in $work/paths40.txt)"
