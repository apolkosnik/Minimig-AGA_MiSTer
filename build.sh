#!/bin/bash
# Full Quartus compile.  Never a SOF->RBF conversion: both come from source.
#
# WHY THIS IS MORE THAN ONE LINE
#
# Quartus always writes output_files/Minimig.rbf, and that is the file a
# person copies to the SD card.  Building an experimental branch therefore
# leaves an untested -- possibly non-booting -- bitstream sitting in the path
# someone picks up, and a copy taken mid-build is truncated, which presents
# as the FPGA failing to configure at all: power LED never driven, black
# screen, nothing to debug.  That happened.
#
# So: every build is also saved under a name that says what it is, and the
# shared path is only left holding a build from the mainline branch.  An
# experimental branch gets its bitstream, and Minimig.rbf goes back to
# whatever it was.
#
# AND IT MUST ALSO MEET TIMING.  Quartus reports timing violations as
# WARNINGS: "Full Compilation was successful" is printed for a bitstream that
# cannot run.  On 2026-08-28 five such builds (setup -1.35..-2.04 on the CPU
# clock) reached the SD card through this path and none of them booted, which
# cost a long debugging session before anyone checked what the board was
# actually running.  So the shared path is now gated on the CPU clock domains
# closing.  A negative path in pll_hdmi is reported but tolerated -- it is the
# video scaler, a display artefact at worst -- while a negative emu|pll domain
# means the CPU itself does not meet setup, and that bitstream never lands in
# the file someone copies without reading.
set -u

MAIN_BRANCH=ap040x2
QUARTUS=/opt/intelFPGA_lite/17.0/quartus/bin/quartus_sh

branch=$(git rev-parse --abbrev-ref HEAD)
sha=$(git rev-parse --short HEAD)
stamp=$(date +%Y%m%d_%H%M%S)
log=build_${branch//\//-}_${stamp}.log
shared=output_files/Minimig.rbf
named=output_files/Minimig-${branch//\//-}-${sha}-${stamp}.rbf

keep=
if [ "$branch" != "$MAIN_BRANCH" ] && [ -f "$shared" ]; then
	keep=$(mktemp /tmp/minimig-rbf-keep.XXXXXX)
	cp "$shared" "$keep"
	echo "branch '$branch' is not $MAIN_BRANCH: preserving the current $shared"
fi

echo "Building $branch ($sha) -> $log"
"$QUARTUS" --flow compile Minimig > "$log" 2>&1
rc=$?

# Per-clock setup slack, from the table Quartus prints under the headline.
# Prints every domain; sets cpu_bad if an emu|pll domain is negative.
timing_report() {
	awk '/Worst-case setup slack is/ {inblk=1; next}
	     inblk && /Info \(332119\)/ {
	         if ($0 ~ /Slack|=====/) next
	         slack=$3; clk=$5
	         if (clk == "") next
	         short=clk
	         sub(/\|.*/, "", short)
	         printf "    %-12s %s\n", short, slack
	         if (short ~ /^emu$/ && slack ~ /^-/) bad=1
	         n++
	         if (n > 8) inblk=0
	     }
	     END { exit (bad ? 1 : 0) }' "$1"
}

if grep -q "Full Compilation was successful" "$log"; then
	cp "$shared" "$named"
	echo "built: $named"
	echo "setup slack by clock:"
	if timing_report "$log"; then
		timing_ok=1
	else
		timing_ok=0
		echo "TIMING: a CPU clock domain does NOT meet setup."
		echo "        This bitstream will not run reliably; $named is kept"
		echo "        for analysis but must not be flashed."
	fi
	if [ -n "$keep" ]; then
		cp "$keep" "$shared"
		echo "restored $shared (this build is experimental; flash $named deliberately)"
	elif [ "$timing_ok" = 0 ]; then
		# mainline build that misses CPU timing: do not leave it in the
		# path people copy from
		if [ -f "$shared.lastgood" ]; then
			cp "$shared.lastgood" "$shared"
			echo "restored $shared from .lastgood (this build misses timing)"
		else
			rm -f "$shared"
			echo "REMOVED $shared: it held a bitstream that misses CPU timing"
			echo "        (no .lastgood to fall back to; flash a known-good named build)"
		fi
	else
		cp "$shared" "$shared.lastgood"
	fi
else
	echo "BUILD FAILED -- see $log"
	[ -n "$keep" ] && cp "$keep" "$shared" && echo "restored $shared"
	rc=1
fi

[ -n "$keep" ] && rm -f "$keep"
exit $rc
