# Poll PMMU debug state via ISSP v4 - with fault MMUSR and saved_addr
# Usage: quartus_stp -t issp_poll.tcl
#
# 374-bit probe layout (MSB first):
#   [373:342] TC[31:0]
#   [341:310] TT0[31:0]
#   [309:278] TT1[31:0]
#   [277:246] CRP_HI[31:0]
#   [245:214] CRP_LO[31:0]
#   [213:209] WSTATE[4:0]
#   [208]     FAULT
#   [207]     BUSY
#   [206:185] ATC_BUSERR[21:0]
#   [184:163] ATC_VALID[21:0]
#   [162]     FAULT_LATCHED (sticky)
#   [161]     WALKER_TIMEOUT_LATCHED (sticky)
#   [160:129] FAULT_TC[31:0]
#   [128:97]  FAULT_ADDR[31:0]
#   [96:92]   FAULT_WSTATE[4:0]
#   [91:70]   FAULT_ATC_BUSERR[21:0]
#   [69:48]   FAULT_ATC_VALID[21:0]
#   [47:32]   FAULT_MMUSR[15:0]
#   [31:0]    FAULT_SAVED_ADDR[31:0]

package require ::quartus::stp

set hw_name "DE-SoC \[3-1.3.4\]"
set dev_name "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"

proc bin2hex {binstr} {
    set result ""
    set padlen [expr {(4 - [string length $binstr] % 4) % 4}]
    set binstr [string repeat "0" $padlen]$binstr
    for {set i 0} {$i < [string length $binstr]} {incr i 4} {
        set nibble [string range $binstr $i [expr {$i+3}]]
        scan $nibble %b val
        append result [format "%X" $val]
    }
    return $result
}

proc bin2dec {binstr} {
    set val 0
    foreach bit [split $binstr ""] {
        set val [expr {$val * 2 + $bit}]
    }
    return $val
}

set wstate_names {W_IDLE W_ROOT W_ROOT_LOW W_PTR1 W_PTR1_LOW W_PTR2 W_PTR2_LOW W_PTR3 W_PTR3_LOW W_PTR4 W_PTR4_LOW W_INDIRECT W_INDIRECT_LOW W_PAGE W_TABLE_UPDATE W_UPDATE_DESC W_PLOAD_FLUSH W_FILL W_COMPLETE W_FAULT}

proc wstate_name {val} {
    global wstate_names
    if {$val < [llength $wstate_names]} {
        return [lindex $wstate_names $val]
    }
    return "UNK($val)"
}

# Decode MMUSR bits per MC68030 spec
proc decode_mmusr {val} {
    set b    [expr {($val >> 15) & 1}]
    set l    [expr {($val >> 14) & 1}]
    set s    [expr {($val >> 13) & 1}]
    set wp   [expr {($val >> 12) & 1}]
    set inv  [expr {($val >> 11) & 1}]
    set m    [expr {($val >> 10) & 1}]
    set t    [expr {($val >> 6) & 1}]
    set lvl  [expr {$val & 7}]
    set parts {}
    if {$b}   {lappend parts "B"}
    if {$l}   {lappend parts "L"}
    if {$s}   {lappend parts "S"}
    if {$wp}  {lappend parts "WP"}
    if {$inv} {lappend parts "I"}
    if {$m}   {lappend parts "M"}
    if {$t}   {lappend parts "T"}
    lappend parts "LVL=$lvl"
    return [join $parts ","]
}

puts "=== PMMU Debug Poller v4 (fault MMUSR + saved_addr) ==="
puts "Polling every 500ms. Ctrl+C to stop."
puts ""

start_insystem_source_probe -hardware_name $hw_name -device_name $dev_name

set prev_bin ""
set poll_count 0
set log_file [open "issp_log.txt" w]
puts $log_file "# PMMU ISSP Poll Log v4 - [clock format [clock seconds]]"
flush $log_file

while {1} {
    set probe_bin [read_probe_data -instance_index 0]
    incr poll_count

    if {$probe_bin ne $prev_bin} {
        set len [string length $probe_bin]
        set ts [clock format [clock seconds] -format "%H:%M:%S"]

        if {$len < 374} {
            set line [format "%5d  %s  ERROR: probe too short (%d bits)" $poll_count $ts $len]
            puts $line
            puts $log_file $line
            flush $log_file
            set prev_bin $probe_bin
            after 500
            continue
        }

        # Parse live state (offsets from MSB-first 374-bit string)
        set tc_hex  [bin2hex [string range $probe_bin 0 31]]
        set tt0_hex [bin2hex [string range $probe_bin 32 63]]
        set tt1_hex [bin2hex [string range $probe_bin 64 95]]
        set crphi_hex [bin2hex [string range $probe_bin 96 127]]
        set crplo_hex [bin2hex [string range $probe_bin 128 159]]
        set wstate [wstate_name [bin2dec [string range $probe_bin 160 164]]]
        set fault [string index $probe_bin 165]
        set busy  [string index $probe_bin 166]
        set atc_buserr [string range $probe_bin 167 188]
        set atc_valid  [string range $probe_bin 189 210]

        # Parse sticky state
        set fl  [string index $probe_bin 211]
        set wtl [string index $probe_bin 212]
        set fault_tc_hex   [bin2hex [string range $probe_bin 213 244]]
        set fault_addr_hex [bin2hex [string range $probe_bin 245 276]]
        set fault_wstate   [wstate_name [bin2dec [string range $probe_bin 277 281]]]
        set fault_atc_buserr [string range $probe_bin 282 303]
        set fault_atc_valid  [string range $probe_bin 304 325]
        set fault_mmusr_bin  [string range $probe_bin 326 341]
        set fault_mmusr_val  [bin2dec $fault_mmusr_bin]
        set fault_mmusr_hex  [bin2hex $fault_mmusr_bin]
        set fault_saved_addr [bin2hex [string range $probe_bin 342 373]]

        # Count buserr entries
        set be_count 0
        for {set i 0} {$i < 22} {incr i} {
            if {[string index $atc_buserr $i] eq "1"} { incr be_count }
        }

        set line [format "%5d  %s  TC=%s TT0=%s CRP=%s:%s W=%-12s F=%s B=%s BE=%d/%s V=%s FL=%s WTL=%s" \
            $poll_count $ts $tc_hex $tt0_hex $crphi_hex $crplo_hex $wstate $fault $busy \
            $be_count $atc_buserr $atc_valid $fl $wtl]

        puts $line
        puts $log_file $line
        flush $log_file
        flush stdout

        # Alert on sticky latches
        if {$fl eq "1"} {
            set fbe_count 0
            for {set i 0} {$i < 22} {incr i} {
                if {[string index $fault_atc_buserr $i] eq "1"} { incr fbe_count }
            }
            set mmusr_decode [decode_mmusr $fault_mmusr_val]
            set alert [format "*** FAULT *** ADDR=%s SAVED_ADDR=%s TC=%s W=%s MMUSR=%s(%s) ATC_BUSERR=%d/%s ATC_VALID=%s" \
                $fault_addr_hex $fault_saved_addr $fault_tc_hex $fault_wstate \
                $fault_mmusr_hex $mmusr_decode \
                $fbe_count $fault_atc_buserr $fault_atc_valid]
            puts $alert
            puts $log_file $alert
            flush $log_file
        }
        if {$wtl eq "1"} {
            set alert "*** WALKER TIMEOUT ***"
            puts $alert
            puts $log_file $alert
            flush $log_file
        }

        set prev_bin $probe_bin
    }

    after 500
}

close $log_file
end_insystem_source_probe
