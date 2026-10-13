# Read the AP060 on-board debug capture (ap060_tg68k_compat.v, DEBUG_CAPTURE)
# over JTAG:   quartus_stp -t ap060_dbgread.tcl
# Prints two live snapshots a second apart (is anything moving?) and the last
# 64 transfers on the 68060 bus, oldest first.
#
# probe[255:0] (MSB first; ap060_tg68k_compat.v, DEBUG_CAPTURE = 1):
#   [255:176] ring[source[5:0]]    [175:144] dbg_pc    [143:128] retired
#   [127:112] transfers  [111:80] xa (the transfer on the bus)
#   [79:48] addr_out (the 16-bit access presented)  [47:42] ring wp
#   [41] halted [40] nrst_c [39] ts_n [38] ta_n (both TA sources)
#   [37:34] cst [33:32] kst  [31:30] p_tgl [29:28] k_tgl@cpu [27:26] p_tgl@clk
#   [25:24] k_tgl  [23] ws [22] rp [21:19] kw  [18:17] xsiz [16] xrd [15] xiack
#   [14] clkena_in  [13:12] busstate [11:9] ipl_n  [1] nresetout
# ring entry[79:0]: [72] Fast RAM port [71] iack [70] avec [69] tbi [68] tci
#   [67] rd [66] code [65:64] siz [63:32] address [31:0] data (read: returned,
#   write: written)

set hw [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSE*" $d]} { set dev $d } }
set inst -1
foreach i [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw] {
	if {[lindex $i 3] == "A060"} { set inst [lindex $i 0] }
}
if {$inst < 0} { puts "no A060 probe in the loaded core"; exit 1 }
start_insystem_source_probe -device_name $dev -hardware_name $hw

proc probe {inst addr} {
	write_source_data -instance_index $inst -value [format %04X $addr] -value_in_hex
	# a few JTAG round trips let the clk_cpu ring read settle
	read_probe_data -instance_index $inst -value_in_hex
	read_probe_data -instance_index $inst -value_in_hex
	return [read_probe_data -instance_index $inst -value_in_hex]
}
proc bits {hex hi lo} {
	set v [expr {"0x$hex"}]
	return [expr {($v >> $lo) & ((1 << ($hi - $lo + 1)) - 1)}]
}
set sizn {L B W LINE}
set cstn {IDLE ALLOC WBEAT WAIT RBEAT ACK ? ? ? ? ? ? ? ? ? ?}
set kstn {IDLE ACC GAP ?}
proc snapshot {inst} {
	global sizn cstn kstn
	set p [probe $inst 0]
	puts [format "  pc=%08X  halted=%d  retired=%d  transfers=%d  nrst_c=%d  rsto=%d" \
	    [bits $p 175 144] [bits $p 41 41] [bits $p 143 128] [bits $p 127 112] [bits $p 40 40] [bits $p 1 1]]
	puts [format "  clk_cpu half: cst=%s  TS=%d TA=%d  xa=%08X siz=%s %s%s  slot ws=%d  requests %d%d answers seen %d%d" \
	    [lindex $cstn [bits $p 37 34]] [expr {![bits $p 39 39]}] [expr {![bits $p 38 38]}] \
	    [bits $p 111 80] [lindex $sizn [bits $p 18 17]] [expr {[bits $p 16 16] ? "RD" : "WR"}] \
	    [expr {[bits $p 15 15] ? " IACK" : ""}] [bits $p 23 23] [bits $p 31 31] [bits $p 30 30] \
	    [bits $p 29 29] [bits $p 28 28]]
	puts [format "  clk half:     kst=%s  slot rp=%d word %d  requests seen %d%d answers %d%d  addr_out=%08X busstate=%d clkena=%d" \
	    [lindex $kstn [bits $p 33 32]] [bits $p 22 22] [bits $p 21 19] [bits $p 27 27] [bits $p 26 26] \
	    [bits $p 25 25] [bits $p 24 24] [bits $p 79 48] [bits $p 13 12] [bits $p 14 14]]
	puts [format "  IPL level seen=%d" [expr {7 - [bits $p 11 9]}]]
	return $p
}
puts "snapshot 1:"; set p1 [snapshot $inst]
after 1000
puts "snapshot 2 (1 s later):"; set p2 [snapshot $inst]
if {[bits $p1 143 112] == [bits $p2 143 112]} { puts "  -> FROZEN: no instruction retired and no transfer in a second" } else { puts "  -> running" }

set wp [bits $p2 47 42]
puts "last 64 transfers (oldest first): siz rw address data flags"
for {set k 0} {$k < 64} {incr k} {
	set a [expr {($wp + $k) & 63}]
	set p [probe $inst $a]
	set e [string range $p 0 19]
	set fl ""
	if {[bits $e 72 72]} { append fl " FAST" }
	if {[bits $e 71 71]} { append fl " IACK" }
	if {[bits $e 70 70]} { append fl " AVEC" }
	if {[bits $e 69 69]} { append fl " TBI" }
	if {[bits $e 68 68]} { append fl " TCI" }
	if {[bits $e 66 66]} { append fl " code" }
	puts [format "  %2d: %-4s %s %08X %08X%s" $k [lindex $sizn [bits $e 65 64]] \
	    [expr {[bits $e 67 67] ? "RD" : "WR"}] [bits $e 63 32] [bits $e 31 0] $fl]
}
end_insystem_source_probe
