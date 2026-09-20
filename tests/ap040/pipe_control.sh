#!/usr/bin/env bash
# pipe_control.sh <rev> <bench>[,<bench>...]
#
# Runs the named pipelined-core benches against rtl/ap040_pipe/ AS OF <rev>,
# then puts HEAD's RTL back. This is the "control" every milestone bench
# gets: proof that it fails on the RTL that predates the feature.
#
# It exists because the sequence was got wrong by hand twice in two
# milestones -- once by stashing a clean tree (which saves nothing, so the
# following pop took a stale entry from another worktree), and once by
# checking out HEAD *before* the run, discarding the uncommitted change.
# Hence the two rules this script enforces rather than documents:
#
#   1. It refuses to run if rtl/ap040_pipe/ has uncommitted changes.
#      Commit first. There is nothing to stash and nothing to lose.
#   2. Restoring HEAD is a trap, so it happens last and happens even if
#      the run dies. `stash` does not appear here at all.
#
# Untracked files elsewhere (a bench still being written) are fine.
# PIPE_HARNESS_ARGS in the environment is passed to the harness (e.g.
# PIPE_HARNESS_ARGS=--slow-l1, milestone 80).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ $# -ne 2 ]; then echo "usage: $0 <rev> <bench>[,<bench>...]" >&2; exit 2; fi
if [ -n "$(git status --porcelain -- rtl/ap040_pipe/)" ]; then
	echo "refusing: rtl/ap040_pipe/ has uncommitted changes -- commit first" >&2
	git status --short -- rtl/ap040_pipe/ >&2
	exit 2
fi
rev=$(git rev-parse --verify --quiet "$1^{commit}") || { echo "no such rev: $1" >&2; exit 2; }
short=$(git rev-parse --short "$rev")
work="/home/adam/ap040-audit4/pipe-ctl-$short"
restore() { git checkout -q HEAD -- rtl/ap040_pipe/; rm -rf "$work"; }
trap restore EXIT
git checkout -q "$rev" -- rtl/ap040_pipe/
echo "control: rtl/ap040_pipe/ at $(git log --oneline -1 "$rev")"
python3 tests/ap040/run_pipe_verilator.py $PIPE_HARNESS_ARGS --work "$work" --only "$2" >/dev/null 2>&1 || true
for b in ${2//,/ }; do
	echo "--- $b ---"
	if [ -f "$work/$b.log" ]; then grep -E "FAIL|PASSED|FAILED|%Error" "$work/$b.log" | head -8
	else echo "(no log -- did the bench build?)"; fi
done
