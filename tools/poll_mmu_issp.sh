#!/bin/bash
set -u

ITERATIONS="${1:-180}"
SCRIPT="/home/adam/030_mmu2/Minimig-AGA_MiSTer/tools/read_mmu_hang_issp.tcl"
QUARTUS_STP="/opt/intelFPGA_lite/17.0/quartus/bin/quartus_stp"
PATTERN='^(== CPUS ==|live: pc=|== PMMU ==|TC=|CRP_H=|fault: latched=|== PMM2 ==|fault_latched=|walk:|      flags:|== EXCF ==|latched=|      trap_vec=|== DPCW ==|frozen=|r[0-3]:|== WWAT ==|build=|freeze:|origin:|onfault:|record\[|           desc_addr=|== RTWR ==|root_page_writes:|exact_slot:|pflush:|last page writes:|== PMWR ==|timeout_detail:|timeout_flags:|seen=|w[0-3]:|hit_400a:|ERROR: The specified hardware is not found\.)'

i=1
while [ "$i" -le "$ITERATIONS" ]; do
  echo "=== poll $i ==="
  "$QUARTUS_STP" -t "$SCRIPT" 2>&1 | grep -E "$PATTERN" || true
  i=$((i + 1))
done
