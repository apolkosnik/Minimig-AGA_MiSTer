# Read the AP030 on-board debug capture (ap030_dbgcap.v) over JTAG.
#   quartus_stp -t ap030_dbgread.tcl [clear]
# Prints the freeze state, the last 32 non-interrupt exceptions and the
# last 256 instruction addresses (oldest first).  "clear" rearms it.
set hw [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSE*" $d]} { set dev $d } }
set inst 0
foreach i [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw] {
	puts "ISSP instance: $i"
	if {[lindex $i 3] == "A030"} { set inst [lindex $i 0] }
}
start_insystem_source_probe -device_name $dev -hardware_name $hw
proc rd {inst sel addr} {
	global clrbit
	set v [expr {($clrbit << 15) | ((($sel >> 2) & 1) << 10) | (($sel & 1) << 9) | ((($sel >> 1) & 1) << 8) | $addr}]
	write_source_data -instance_index $inst -value [format %04X $v] -value_in_hex
	# a few JTAG round trips let the processor-domain read settle
	read_probe_data -instance_index $inst -value_in_hex
	read_probe_data -instance_index $inst -value_in_hex
	# probe: 42 hex digits = 168 bits; the top byte is the clock ring's
	# write pointer, the rest is laid out as before
	global trwp
	set p [read_probe_data -instance_index $inst -value_in_hex]
	set trwp [scan [string range $p 0 1] %x]
	return [string range $p 2 end]
}
set clrbit 0
set p [rd $inst 0 0]
set cur [expr {[scan [string range $p 0 1] %x] >> 7 & 1}]
if {[llength $argv] > 0 && [lindex $argv 0] == "clear"} {
	# the clear toggle is source bit 15: invert its current value
	set src [read_source_data -instance_index $inst -value_in_hex]
	set clrbit [expr {(([scan [string range $src 0 1] %x] >> 7) & 1) ^ 1}]
	rd $inst 0 0
	puts "cleared"
	end_insystem_source_probe
	exit
}
set src [read_source_data -instance_index $inst -value_in_hex]
set clrbit [expr {([scan [string range $src 0 1] %x] >> 7) & 1}]
set p [rd $inst 0 0]
# header in the top 32 bits (after the clock ring pointer)
set hdr [scan [string range $p 0 7] %x]
set pcf [expr {($hdr >> 31) & 1}]; set exf [expr {($hdr >> 30) & 1}]
set cause [expr {($hdr >> 24) & 63}]; set resets [expr {($hdr >> 16) & 255}]
set pcwp [expr {($hdr >> 8) & 255}]; set exwp [expr {($hdr >> 3) & 31}]
set trf [expr {($hdr >> 2) & 1}]; set trt [expr {($hdr >> 1) & 1}]
puts [format "pc_frozen=%d exc_frozen=%d cause=%d resets=%d pc_wp=%d exc_wp=%d tr_trig=%d tr_frozen=%d tr_wp=%d" $pcf $exf $cause $resets $pcwp $exwp $trt $trf $trwp]
if {$trf} {
	set w0 $trwp
	puts "clock ring (oldest first): inst irq pq_v ra_a S M wact waddr we state isp rf_a ea"
	for {set k 0} {$k < 256} {incr k} {
		set a [expr {($w0 + $k) & 255}]
		set x [string range [rd $inst 4 $a] 8 39]
		set hi [scan [string range $x 0 7] %x]
		puts [format "  %3d: i%d q%d v%d ra%2d S%d M%d wact%d wa%2d we%d st%3d isp=%s rfa=%s ea=%s" $k \
		      [expr {($hi >> 24) & 1}] [expr {($hi >> 23) & 1}] [expr {($hi >> 21) & 3}] [expr {($hi >> 17) & 15}] \
		      [expr {($hi >> 16) & 1}] [expr {($hi >> 15) & 1}] [expr {($hi >> 13) & 3}] [expr {($hi >> 9) & 15}] \
		      [expr {($hi >> 8) & 1}] [expr {$hi & 255}] [string range $x 8 15] [string range $x 16 23] [string range $x 24 31]]
	}
}
puts "exceptions (oldest first): vec esr epc pc ir"
for {set k 0} {$k < 32} {incr k} {
	set a [expr {($exwp + $k) & 31}]
	set e [rd $inst 1 $a]
	# entry is the low 128 bits (32 hex digits): 24'd0, vec, esr, epc, pc, ir
	set x [string range $e 8 39]
	puts [format "  %2d: vec=%3d esr=%s epc=%s pc=%s ir=%s" $k [scan [string range $x 6 7] %x] \
	      [string range $x 8 11] [string range $x 12 19] [string range $x 20 27] [string range $x 28 31]]
}
puts "instruction sr:pc (oldest first):"
set line ""
for {set k 0} {$k < 256} {incr k} {
	set a [expr {($pcwp + $k) & 255}]
	set e [rd $inst 0 $a]
	append line " [string range $e 28 31]:[string range $e 32 39] ea=[string range $e 20 27] isp=[string range $e 12 19]"
	if {($k & 1) == 1} { puts $line; set line "" }
}
set e [rd $inst 2 0]
set bwp [scan [string range $e 20 21] %x]
puts "processor writes (oldest first): fast fc rw siz address data"
for {set k 0} {$k < 256} {incr k} {
	set a [expr {($bwp + $k) & 255}]
	set e [rd $inst 2 $a]
	set fl [scan [string range $e 22 23] %x]
	set fast [expr {($fl >> 6) & 1}]; set fc [expr {($fl >> 3) & 7}]
	set rw [expr {($fl >> 2) & 1}]; set sz [expr {$fl & 3}]
	puts [format "  %s fc%d %s siz%d %s %s" [expr {$fast ? "F" : "s"}] $fc [expr {$rw ? "R" : "W"}] $sz \
	      [string range $e 24 31] [string range $e 32 39]]
}
set e [rd $inst 3 0]
set fwp [scan [string range $e 8 9] %x]
puts "Fast RAM posted writes (oldest first): ddr word address, byte enables, data (64-bit, DDR byte order)"
for {set k 0} {$k < 256} {incr k} {
	set a [expr {($fwp + $k) & 255}]
	set x [string range [rd $inst 3 $a] 8 39]
	set da [expr {[scan [string range $x 6 13] %x] & 0x1FFFFFFF}]
	puts [format "  ddr %08X (byte %08X) be %s d %s" $da [expr {$da * 8}] [string range $x 14 15] [string range $x 16 31]]
}
end_insystem_source_probe
