#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTUS_BIN="${QUARTUS_BIN:-/opt/intelFPGA_lite/17.0/quartus/bin}"
QUARTUS_PGM="${QUARTUS_BIN}/quartus_pgm"
QUARTUS_STP="${QUARTUS_BIN}/quartus_stp"
JTAGCONFIG="${QUARTUS_BIN}/jtagconfig"

CABLE_NAME="${CABLE_NAME:-DE-SoC [3-1.3.4]}"
FPGA_INDEX="${FPGA_INDEX:-2}"
DEFAULT_SOF="${DEFAULT_SOF:-${SCRIPT_DIR}/output_files/Minimig.sof}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  status
      Show available programming cables and the live JTAG chain.

  program [sof]
      Program the FPGA at chain position @${FPGA_INDEX}.
      Default SOF: ${DEFAULT_SOF}

  snapshot [--clear-hang] [--clear-excf] [--clear-pmwr]
      Run a one-shot ISSP read using issp_read_once.tcl.

  poll
      Run the 5-sample ISSP poll using issp_read_multi.tcl.

  check [sof] [--clear-hang] [--clear-excf] [--clear-pmwr]
      Program the FPGA, then take a one-shot ISSP snapshot, then a short poll.

Environment overrides:
  QUARTUS_BIN   Quartus bin directory
  CABLE_NAME    Programming cable name
  FPGA_INDEX    FPGA position in JTAG chain
  DEFAULT_SOF   Default SOF file to program
EOF
}

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "Missing file: $path" >&2
        exit 1
    fi
}

require_tool() {
    local path="$1"
    if [[ ! -x "$path" ]]; then
        echo "Missing executable: $path" >&2
        exit 1
    fi
}

run_status() {
    require_tool "$QUARTUS_PGM"
    require_tool "$JTAGCONFIG"

    echo "== quartus_pgm -l =="
    "$QUARTUS_PGM" -l
    echo
    echo "== jtagconfig =="
    "$JTAGCONFIG"
}

run_program() {
    local sof="${1:-$DEFAULT_SOF}"

    require_tool "$QUARTUS_PGM"
    require_file "$sof"

    echo "Programming ${sof} on ${CABLE_NAME} @${FPGA_INDEX}"
    "$QUARTUS_PGM" -c "$CABLE_NAME" -m JTAG -o "p;${sof}@${FPGA_INDEX}"
}

run_snapshot() {
    require_tool "$QUARTUS_STP"
    require_file "${SCRIPT_DIR}/issp_read_once.tcl"

    "$QUARTUS_STP" -t "${SCRIPT_DIR}/issp_read_once.tcl" "$@"
}

run_poll() {
    require_tool "$QUARTUS_STP"
    require_file "${SCRIPT_DIR}/issp_read_multi.tcl"

    "$QUARTUS_STP" -t "${SCRIPT_DIR}/issp_read_multi.tcl"
}

run_check() {
    local sof="$DEFAULT_SOF"
    local snapshot_args=()

    if [[ $# -gt 0 && "$1" != --* ]]; then
        sof="$1"
        shift
    fi
    snapshot_args=("$@")

    run_program "$sof"
    echo
    echo "== One-shot ISSP snapshot =="
    run_snapshot "${snapshot_args[@]}"
    echo
    echo "== Short ISSP poll =="
    run_poll
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

cmd="$1"
shift

case "$cmd" in
    status)
        run_status
        ;;
    program)
        run_program "$@"
        ;;
    snapshot)
        run_snapshot "$@"
        ;;
    poll)
        run_poll
        ;;
    check)
        run_check "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
esac
