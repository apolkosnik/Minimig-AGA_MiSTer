#!/usr/bin/env bash
# pipe_mutate.sh <file-under-rtl/ap040_pipe> <old> <new> <bench>[,<bench>...]
#
# Applies ONE exact-string substitution to an RTL file, runs the named
# pipelined-core benches, prints their pass/fail lines, and restores the
# file from HEAD. It is how a bench proves it can see a bug: break the RTL
# on purpose and watch the bench notice.
#
# Rules it enforces:
#   1. The file must be clean against HEAD, so "restore" means "checkout
#      HEAD" and nothing else -- commit first.
#   2. <old> must occur exactly once. A mutation that lands twice or not at
#      all is not the mutation you meant.
#   3. Restore is a trap: it runs even if the build or the bench dies.
#
# PIPE_HARNESS_ARGS in the environment is passed to the harness, e.g.
# PIPE_HARNESS_ARGS=--slow-l1 for the slow-L1 build (milestone 80).
#
# The point of having it as a tool: a mutation should be run BEFORE the
# claim it supports is written down. Three times in seven milestones the
# claim was written first and the mutation then contradicted it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ $# -ne 4 ]; then echo "usage: $0 <file> <old> <new> <bench>[,<bench>...]" >&2; exit 2; fi
f="rtl/ap040_pipe/$1"
[ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }
if [ -n "$(git status --porcelain -- "$f")" ]; then
	echo "refusing: $f has uncommitted changes -- commit first" >&2; exit 2
fi
work="/home/adam/ap040-audit4/pipe-mut-$$"
restore() { git checkout -q HEAD -- "$f"; rm -rf "$work"; }
trap restore EXIT
OLD="$2" NEW="$3" F="$f" python3 - <<'PY'
import os, pathlib
p = pathlib.Path(os.environ["F"]); t = p.read_text(); o = os.environ["OLD"]; n = os.environ["NEW"]
c = t.count(o)
if c != 1:
    raise SystemExit(f"refusing: <old> occurs {c} times in {p} (must be exactly 1)")
p.write_text(t.replace(o, n, 1))
PY
echo "mutation applied to $f"
python3 tests/ap040/run_pipe_verilator.py ${PIPE_HARNESS_ARGS:-} --work "$work" --only "$4" >/dev/null 2>&1 || true
for b in ${4//,/ }; do
	echo "--- $b ---"
	if [ -f "$work/$b.log" ]; then grep -E "FAIL|PASSED|FAILED|%Error" "$work/$b.log" | head -8
	else echo "(no log -- did the bench build?)"; fi
done
