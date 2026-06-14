# Read and decode the NE2000 ethernet ISSP probes over JTAG.
#
# Usage:
#   quartus_stp -t read_eth_issp.tcl [poll_count] [delay_ms]
#
# Two probes (rtl/ethernet.v + Minimig.sv, via module ethernet_issp):
#   HDBG (probe_width 128): mailbox round-trip view from rtl/ethernet.v
#       sig==CAFEBABE -> FPGA reads HPS signature; hb advancing -> reads live.
#   MBOX (probe_width 64): mailbox Avalon write/read handshake (clk_audio)
#       wr_accept advancing -> f2sdram2 WRITES are being accepted.
#       wr_stall  advancing while wr_accept stuck -> writes never accepted
#       (avl_waitrequest stuck high on writes).
#
# read_probe_data returns a binary string, MSB (bit width-1) leftmost.

set poll_count 8
set delay_ms   500
if {$argc >= 1} { set poll_count [lindex $argv 0] }
if {$argc >= 2} { set delay_ms   [lindex $argv 1] }

proc field {data width hi lo} {
    set start [expr {$width - 1 - $hi}]
    set len   [expr {$hi - $lo + 1}]
    return [string range $data $start [expr {$start + $len - 1}]]
}
proc b2u {bits} {
    if {$bits eq ""} { return 0 }
    return [expr "0b$bits"]
}

set hardware_names [get_hardware_names]
if {[llength $hardware_names] == 0} { error "no JTAG hardware found" }
set hw [lindex $hardware_names 0]
puts "hardware: $hw"

set device_names [get_device_names -hardware_name $hw]
if {[llength $device_names] == 0} { error "no devices on $hw" }

# ISSP lives in the FPGA fabric, not the HPS (SOCVHPS) TAP. Find the device
# that actually exposes ISSP instances.
set dev ""
set insts {}
foreach d $device_names {
    if {[catch {get_insystem_source_probe_instance_info -hardware_name $hw -device_name $d} got]} { continue }
    if {[llength $got] == 0} { continue }
    set dev $d
    set insts $got
    break
}
if {$dev eq ""} { error "no ISSP instances (is the ISSP RBF flashed and FPGA configured?)" }
puts "device:   $dev"
foreach inst $insts { puts "  instance: $inst" }

# Map probe_width -> index (HDBG=128, MBOX=64). instance = {index sw pw name}
set idx_hdbg -1; set w_hdbg 128
set idx_mbox -1; set w_mbox 64
foreach inst $insts {
    set ix [lindex $inst 0]; set pw [lindex $inst 2]; set nm [lindex $inst 3]
    if {$pw == 128} { set idx_hdbg $ix; set w_hdbg $pw }
    if {$pw == 64}  { set idx_mbox $ix; set w_mbox $pw }
}
puts ""

start_insystem_source_probe -hardware_name $hw -device_name $dev

set prev_hb -1
for {set i 0} {$i < $poll_count} {incr i} {
    if {$idx_hdbg >= 0} {
        set d [read_probe_data -instance_index $idx_hdbg]
        set sig    [b2u [field $d $w_hdbg 31  0]]
        set hb     [b2u [field $d $w_hdbg 63 32]]
        set status [b2u [field $d $w_hdbg 79 64]]
        set bgst   [b2u [field $d $w_hdbg 119 114]]
        set dstat  [b2u [field $d $w_hdbg 127 120]]
        set mv ""; if {$prev_hb >= 0 && $hb != $prev_hb} { set mv " (adv)" }
        set prev_hb $hb
        puts [format "\[%d\] HDBG sig=%08X hb=%08X%s status=%04X bg=%2d dstat=%02X" \
            $i $sig $hb $mv $status $bgst $dstat]
    }
    if {$idx_mbox >= 0} {
        set m [read_probe_data -instance_index $idx_mbox]
        set wacc [b2u [field $m $w_mbox 7   0]]
        set racc [b2u [field $m $w_mbox 15  8]]
        set rdv  [b2u [field $m $w_mbox 23 16]]
        set wstl [b2u [field $m $w_mbox 31 24]]
        set mst  [b2u [field $m $w_mbox 35 34]]
        set awr  [b2u [field $m $w_mbox 36 36]]
        set ard  [b2u [field $m $w_mbox 37 37]]
        set awt  [b2u [field $m $w_mbox 38 38]]
        set ardv [b2u [field $m $w_mbox 39 39]]
        puts [format "      MBOX wr_acc=%3d rd_acc=%3d rdvalid=%3d wr_stall=%3d state=%d avl(w=%d r=%d wait=%d rdv=%d)" \
            $wacc $racc $rdv $wstl $mst $awr $ard $awt $ardv]
    }
    if {$i < [expr {$poll_count - 1}]} { after $delay_ms }
}

puts ""
puts "Verdict:"
puts "  MBOX wr_acc advancing  -> f2sdram2 writes ARE accepted (good)."
puts "  MBOX wr_acc==0 & wr_stall climbing -> writes never accepted (avl_waitrequest"
puts "       stuck high on writes) -> f2sdram2 write path / port config issue."
puts "  rd_acc/rdvalid advancing confirms the read path works (as already seen)."

end_insystem_source_probe
