#!/bin/bash
set -u

ITERATIONS="${1:-180}"
SCRIPT="/home/adam/030_mmu2/Minimig-AGA_MiSTer/tools/read_mmu_hang_issp.tcl"
QUARTUS_STP="/opt/intelFPGA_lite/17.0/quartus/bin/quartus_stp"
PATTERN='^(== CPUS ==|live: pc=|== PMMU ==|TC=|CRP_H=|fault: latched=|== PMM2 ==|fault_latched=|walk:|      flags:|== EXCF ==|latched=|      trap_vec=|ERROR: The specified hardware is not found\.)'

i=1
while [ "$i" -le "$ITERATIONS" ]; do
  echo "=== poll $i ==="
  "$QUARTUS_STP" -t "$SCRIPT" 2>&1 | grep -E "$PATTERN" || true
  i=$((i + 1))
done
