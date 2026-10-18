#!/bin/sh
# The CPU is the AP68040 (rtl/ap68040, from github.com/apolkosnik/AP68040
# branch faster).  Its SystemVerilog is beyond Icarus, so the regression
# runs under Verilator: see run_verilator_tests.sh.  The Icarus runner for
# the previous core (rtl/ap040) is in git history before this change.
exec "$(dirname "$0")/run_verilator_tests.sh" "$@"
