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

if grep -q "Full Compilation was successful" "$log"; then
	cp "$shared" "$named"
	echo "built: $named"
	if [ -n "$keep" ]; then
		cp "$keep" "$shared"
		echo "restored $shared (this build is experimental; flash $named deliberately)"
	fi
else
	echo "BUILD FAILED -- see $log"
	[ -n "$keep" ] && cp "$keep" "$shared" && echo "restored $shared"
	rc=1
fi

[ -n "$keep" ] && rm -f "$keep"
exit $rc
