# sta_precheck.tcl -- census pre-check for the P2 multicycle model in
# Minimig.sdc.  Run on a finished fit, from the project root:
#
#   SPDIR=/some/dir quartus_sta -t tests/ap040/sta/sta_precheck.tcl
#   python3 tests/ap040/sta/precheck.py /some/dir
#
# It re-derives the register classes from the NETLIST (which ena pins
# core_phase reaches) and compares them with the SDC's sets, then reports
# the worst path of every exception class.  precheck.py prints PRECHECK
# PASS/FAIL: a free-running register inside TICK, a RAM-to-RAM chain
# outside the write ports, or a negative class is a FAIL, and the gate's
# CPU slack must not be trusted until it is understood.
project_open Minimig
create_timing_netlist
read_sdc
update_timing_netlist
set P {emu|cpu_wrapper|cpu_inst_p}
set SRC [get_registers {emu|cpu_wrapper|core_phase*}]
set fh [open $::env(SPDIR)/pc_all.txt w]
foreach_in_collection r $ALL { puts $fh [get_node_info -name $r] }
close $fh
foreach {n c} [list fr1 $FR1 asyn $ASYN tick $TICK] {
    set fh [open $::env(SPDIR)/pc_$n.txt w]
    foreach_in_collection r $c { puts $fh [get_node_info -name $r] }
    close $fh
}
report_timing -setup -from $SRC -to [get_pins -compatibility_mode "$P|*|ena"] -npaths 40000 -nworst 1 -detail path_only -file $::env(SPDIR)/pc_ena.rpt
report_timing -setup -from $SRC -to $ALL -npaths 40000 -nworst 1 -detail path_only -file $::env(SPDIR)/pc_any.rpt
set DIN   [get_registers "$P|*ram_block*datain_reg*"]
set RDPORTS [remove_from_collection [remove_from_collection [remove_from_collection $RAMP $CTAGB] $ATCB] $DIN]
report_timing -setup -from $FR1 -to $RDPORTS -npaths 20 -detail summary -file $::env(SPDIR)/pc_fr1_rdports.rpt
set C0 {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set NOLOOK [remove_from_collection $ASYN $LOOKS]
foreach {name from to} [list tick_tick $TICK $TICK  fr1_tick $FR1 $TICK  tick_ctagb $TICK $CTAGB  fr1_ctagb $FR1 $CTAGB \
        tick_atcb $TICK $ATCB  fr1_atcb $FR1 $ATCB  fr1mmu_looks $FR1_MMU $LOOKS  tickcm_looks $TICK_CM $LOOKS \
        tick_pipe $TICK $PIPE  tick_rdports $TICK $RDPORTS  asyn_tick $ASYN $TICK  tick_asyn $TICK $NOLOOK  asyn_asyn $ASYN $ASYN \
        cpu_ci $ALL [get_registers {emu|cpu_wrapper|cache_inhibit_r}]  cpu_req $ALL [remove_from_collection [get_registers {emu|cpu_wrapper|ram*_r*}] [get_registers {emu|cpu_wrapper|cache_inhibit_r}]]] {
    report_timing -setup -npaths 4 -detail summary -from $from -to $to -file $::env(SPDIR)/pc_$name.rpt
}
report_timing -setup -npaths 4 -detail summary -from $SRC -to [get_pins -compatibility_mode "$P|*|ena"] -file $::env(SPDIR)/pc_ena_worst.rpt
report_timing -setup -npaths 60 -detail summary -to_clock $C0 -file $::env(SPDIR)/pc_c0_wide.rpt
