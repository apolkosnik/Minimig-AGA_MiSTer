# Dump the X-Surf board-EEPROM access trace captured by the ETRACE ISSP probe.
#
# Usage:
#   quartus_stp -t read_eth_trace.tcl [arm]
#     arm  -> re-arm the trace (clear + start a fresh capture) before dumping.
#
# The FPGA logs every CPU access to the board-level EEPROM region
# (0xF0xx clock/ctrl, 0x04xx index/DO, 0x007E strobe) into a 256-entry buffer.
# Each entry: {rw[32], addr[31:16], data[15:0]}.  Capture freezes at 256 entries;
# pass "arm" to restart it (then reproduce the driver's MAC read before dumping).

proc field {data width hi lo} {
    set start [expr {$width - 1 - $hi}]
    set len   [expr {$hi - $lo + 1}]
    return [string range $data $start [expr {$start + $len - 1}]]
}
proc b2u {bits} {
    if {$bits eq ""} { return 0 }
    return [expr "0b$bits"]
}

set do_arm 0
if {$argc >= 1 && [lindex $argv 0] eq "arm"} { set do_arm 1 }

set hw [lindex [get_hardware_names] 0]
puts "hardware: $hw"
set dev ""; set insts {}
foreach d [get_device_names -hardware_name $hw] {
    if {[catch {get_insystem_source_probe_instance_info -hardware_name $hw -device_name $d} got]} { continue }
    if {[llength $got] == 0} { continue }
    set dev $d; set insts $got; break
}
if {$dev eq ""} { error "no ISSP instances (is the RBF flashed?)" }
puts "device:   $dev"

# Find the ETRACE instance by name.
set idx -1; set w 128
foreach inst $insts {
    puts "  instance: $inst"
    if {[lindex $inst 3] eq "RACE" || [lindex $inst 3] eq "ETRACE"} { set idx [lindex $inst 0]; set w [lindex $inst 2] }
}
if {$idx < 0} { error "ETRACE instance not found (old RBF without the trace probe?)" }
puts ""

start_insystem_source_probe -hardware_name $hw -device_name $dev

proc read_entry {idx_inst w index} {
    # source: [8]=arm, [7:0]=index
    write_source_data -instance_index $idx_inst -value $index
    after 5
    return [read_probe_data -instance_index $idx_inst]
}

if {$do_arm} {
    puts "Arming trace (clear + restart capture)..."
    write_source_data -instance_index $idx -value [expr {0x100}]
    after 20
    write_source_data -instance_index $idx -value 0
    after 20
    puts "Armed. Reproduce the driver's MAC read, then run without 'arm' to dump."
    end_insystem_source_probe
    return
}

set d [read_entry $idx $w 0]
set wptr [b2u [field $d $w 49 41]]
set full [b2u [field $d $w 50 50]]
set n $wptr
if {$full} { set n 256 }
puts [format "trace entries: %d (full=%d)" $n $full]
puts "  idx  rw addr     data   decode"
for {set i 0} {$i < $n} {incr i} {
    set d [read_entry $idx $w $i]
    set data [b2u [field $d $w 15 0]]
    set addr [b2u [field $d $w 31 16]]
    set rw   [b2u [field $d $w 32 32]]
    set rws  "RD"; if {$rw} { set rws "WR" }
    set name "?"
    if {$addr == 0xF000} { set name "EE_CLK/CTRL(0xF000)" }
    if {($addr & 0xFF00) == 0x0400} { set name [format "IDX/DATA/DO(0x%04X)" $addr] }
    if {$addr == 0x007E} { set name "STROBE(0x007E)" }
    puts [format "  %3d  %s 0x%04X  0x%04X  %s" $i $rws $addr $data $name]
}

end_insystem_source_probe
