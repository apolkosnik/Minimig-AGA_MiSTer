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
# Marker for the staleness check below: anything the compile regenerates is
# newer than this.
started=$(mktemp /tmp/minimig-build-started.XXXXXX)
"$QUARTUS" --flow compile Minimig > "$log" 2>&1
rc=$?

# Slack by clock, from the tables Quartus prints under each headline.
# Sets bad if an emu|pll domain is negative anywhere.
#
# SCANS EVERY TABLE -- setup, hold, minimum, recovery, removal, in every
# corner.  The original of this function counted rows and stopped after 8,
# without resetting the count per table, so it read the first corner and
# then at most one row of each table after it: a CPU violation showing up
# only in a later corner passed the gate.  Verified against a real log with
# -1.762 injected into a late-corner emu row -- the counting version reported
# "timing OK", this one blocks.  A row is "Info (332119): <slack> <tns>
# <clock>" and anything else ends the table, so no counting is needed.
#
# It scans everything but REPORTS a summary: the tightest emu figure per
# analysis, plus every negative row whatever the domain.  Printing all ~160
# rows buried the two numbers anyone reads.  Nothing about what is CHECKED
# changed with that -- only what is echoed.
#
# pll_hdmi is reported and ignored, deliberately: it is the video scaler, a
# display artefact at worst, and it is not what this gate is for.  Only emu
# domains -- the CPU -- decide whether the bitstream may be published.
timing_report() {
	awk '/Worst-case .* slack is/ { inblk=1; kind=$4; next }
	     inblk {
	         if ($0 !~ /Info \(332119\)/) { inblk=0; next }
	         if ($0 ~ /Slack|====/) next
	         slack=$3; clk=$5
	         if (clk == "") { inblk=0; next }
	         short=clk
	         sub(/\|.*/, "", short)
	         if (short == "emu") {
	             if (!(kind in emumin) || slack+0 < emumin[kind]+0) {
	                 emumin[kind]=slack
	                 if (!(kind in seen)) { order[++nk]=kind; seen[kind]=1 }
	             }
	             if (slack ~ /^-/) bad=1
	         }
	         if (slack ~ /^-/) neg[++nn]=sprintf("    %-9s %-13s %8s   <-- negative", kind, short, slack)
	     }
	     END {
	         for (i=1; i<=nk; i++) printf "    %-9s %-13s %8s\n", order[i], "emu (CPU)", emumin[order[i]]
	         for (i=1; i<=nn; i++) print neg[i]
	         # No emu row at all is NOT a pass.  A compilation can finish
	         # without the timing analyzer having run -- a smart recompile
	         # that reuses everything, an edition that dropped an assignment
	         # and changed nothing -- and the scan then sees no rows, reports
	         # an empty table and, before this, exited 0.  That published a
	         # bitstream whose timing was never analysed under a name that
	         # promised it had been.  Silence is a failure.
	         if (nk == 0) { print "    NO TIMING DATA: the analyzer produced no emu rows"; exit 1 }
	         exit (bad ? 1 : 0)
	     }' "$1"
}

if grep -q "Full Compilation was successful" "$log"; then
	# A successful compilation does not mean a bitstream was produced.  When
	# nothing has changed -- an assignment this edition ignores, a smart
	# recompile that reuses every stage -- Quartus reports success, the
	# assembler never runs, and $shared is still whatever was there before.
	# On this branch that is the PRESERVED older core, so the copy below
	# would publish it under today's name and sha, and it would behave like
	# the old core because it IS the old core.  That happened on
	# 2026-09-13: a build labelled 8e71cf51 was byte-identical to the
	# a48b5c30-era bitstream and measured its 3537 Dhrystones.
	if [ ! "$shared" -nt "$started" ]; then
		echo "STALE: $shared was not regenerated by this compile."
		echo "       The assembler did not run, so there is no bitstream for"
		echo "       this source.  Nothing published."
		[ -n "$keep" ] && rm -f "$keep"
		rm -f "$started"
		exit 1
	fi
	cp "$shared" "$named"
	echo "built: $named"
	echo "slack by clock (emu = CPU; only it gates):"
	if timing_report "$log"; then
		timing_ok=1
	else
		timing_ok=0
		# The verdict goes INTO THE FILENAME.  Two gate-blocked bitstreams
		# were picked up from output_files and flashed on 2026-09-12; neither
		# booted DiagROM, exactly as this message had said.  A message is read
		# once; a filename is read every time the file is chosen.
		blocked="${named%.rbf}-TIMING-FAIL-DO-NOT-FLASH.rbf"
		mv "$named" "$blocked" && named="$blocked"
		echo "TIMING: a CPU clock domain does NOT meet setup, or was never analysed."
		echo "        This bitstream will not run reliably; it is kept for"
		echo "        analysis as $named"
		echo "        and must not be flashed."
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

[ -n "$keep" ] && rm -f "$keep" "$started"
exit $rc
