# Poll PMMU debug state via ISSP v7 - adds PMM2 per-level descriptor probe
# Usage: quartus_stp -t issp_poll.tcl
#
# 505-bit probe layout (MSB first, string index in parens):
#   [504:473] (0-31)    TC[31:0]
#   [472:441] (32-63)   TT0[31:0]
#   [440:409] (64-95)   TT1[31:0]
#   [408:377] (96-127)  CRP_HI[31:0]
#   [376:345] (128-159) CRP_LO[31:0]
#   [344:313] (160-191) SRP_HI[31:0]
#   [312:281] (192-223) SRP_LO[31:0]
#   [280:276] (224-228) WSTATE[4:0]
#   [275]     (229)     FAULT
#   [274]     (230)     BUSY
#   [273:252] (231-252) ATC_BUSERR[21:0]
#   [251:230] (253-274) ATC_VALID[21:0]
#   [229]     (275)     FAULT_LATCHED (sticky)
#   [228]     (276)     WALKER_TIMEOUT_LATCHED (sticky)
#   [227:196] (277-308) FAULT_TC[31:0]
#   [195:164] (309-340) FAULT_ADDR[31:0]
#   [163:159] (341-345) FAULT_WSTATE[4:0]
#   [158:137] (346-367) FAULT_ATC_BUSERR[21:0]
#   [136:115] (368-389) FAULT_ATC_VALID[21:0]
#   [114:99]  (390-405) FAULT_MMUSR[15:0]
#   [98:67]   (406-437) FAULT_SAVED_ADDR[31:0]
#   [66:35]   (438-469) FAULT_DESC_ADDR[31:0]
#   [34:3]    (470-501) FAULT_DESC_DATA[31:0]
#   [2:0]     (502-504) FAULT_FC[2:0]

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

# Decode FC value to human-readable name
proc fc_name {val} {
    switch $val {
        0 { return "USR_DATA(0)" }
        1 { return "USR_DATA(1)" }
        2 { return "USR_PROG(2)" }
        3 { return "USR_PROG(3)" }
        4 { return "SV_DATA(4)" }
        5 { return "SV_DATA(5)" }
        6 { return "SV_PROG(6)" }
        7 { return "CPU_SPACE(7)" }
        default { return "UNK($val)" }
    }
}

# Decode MMUSR bits per MC68030 spec (section 9.2.7)
proc decode_mmusr {val} {
    set b    [expr {($val >> 15) & 1}]
    set l    [expr {($val >> 14) & 1}]
    set s    [expr {($val >> 13) & 1}]
    set wp   [expr {($val >> 11) & 1}]
    set inv  [expr {($val >> 10) & 1}]
    set m    [expr {($val >> 9) & 1}]
    set t    [expr {($val >> 6) & 1}]
    set lvl  [expr {$val & 7}]
    set parts {}
    if {$b}   {lappend parts "B"}
    if {$l}   {lappend parts "L"}
    if {$s}   {lappend parts "S"}
    if {$wp}  {lappend parts "WP"}
    if {$inv} {lappend parts "I"}
    if {$t}   {lappend parts "T"}
    lappend parts "LVL=$lvl"
    return [join $parts ","]
}

# Decode TC register fields
proc decode_tc {hex} {
    scan $hex %x val
    set e   [expr {($val >> 31) & 1}]
    set sre [expr {($val >> 25) & 1}]
    set fcl [expr {($val >> 24) & 1}]
    set ps  [expr {($val >> 20) & 0xF}]
    set is  [expr {($val >> 16) & 0xF}]
    set tia [expr {($val >> 12) & 0xF}]
    set tib [expr {($val >> 8) & 0xF}]
    set tic [expr {($val >> 4) & 0xF}]
    set tid [expr {$val & 0xF}]
    return "E=$e,SRE=$sre,FCL=$fcl,PS=$ps,IS=$is,TIA=$tia,TIB=$tib,TIC=$tic,TID=$tid"
}

proc decode_desc {hex} {
    scan $hex %x val
    set dt [expr {$val & 0x3}]
    set u  [expr {($val >> 3) & 1}]
    set m  [expr {($val >> 4) & 1}]
    set ci [expr {($val >> 6) & 1}]
    set wp [expr {($val >> 2) & 1}]
    switch $dt {
        0 { set dt_name "INVALID(00)" }
        1 { set dt_name "PAGE(01)" }
        2 { set dt_name "SHORT(10)" }
        3 { set dt_name "LONG(11)" }
        default { set dt_name "UNK" }
    }
    return "DT=$dt_name,U=$u,M=$m,CI=$ci,WP=$wp"
}

puts "=== PMMU Debug Poller v7 (CRP+SRP+descriptor+FC+PMM2) ==="
puts "Polling every 500ms. Ctrl+C to stop."
puts ""

start_insystem_source_probe -hardware_name $hw_name -device_name $dev_name

set prev_bin ""
set prev2_bin ""
set poll_count 0
set log_file [open "issp_log.txt" w]
puts $log_file "# PMMU ISSP Poll Log v7 - [clock format [clock seconds]]"
flush $log_file

while {1} {
    set probe_bin [read_probe_data -instance_index 0]
    set probe2_bin [read_probe_data -instance_index 1]
    incr poll_count

    if {$probe_bin ne $prev_bin || $probe2_bin ne $prev2_bin} {
        set len [string length $probe_bin]
        set len2 [string length $probe2_bin]
        set ts [clock format [clock seconds] -format "%H:%M:%S"]

        if {$len < 505} {
            set line [format "%5d  %s  ERROR: probe too short (%d bits, need 505)" $poll_count $ts $len]
            puts $line
            puts $log_file $line
            flush $log_file
            set prev_bin $probe_bin
            after 500
            continue
        }
        if {$len2 < 194} {
            set line [format "%5d  %s  ERROR: probe2 too short (%d bits, need 194)" $poll_count $ts $len2]
            puts $line
            puts $log_file $line
            flush $log_file
            set prev_bin $probe_bin
            set prev2_bin $probe2_bin
            after 500
            continue
        }

        # Parse live state
        set tc_hex    [bin2hex [string range $probe_bin 0 31]]
        set tt0_hex   [bin2hex [string range $probe_bin 32 63]]
        set tt1_hex   [bin2hex [string range $probe_bin 64 95]]
        set crphi_hex [bin2hex [string range $probe_bin 96 127]]
        set crplo_hex [bin2hex [string range $probe_bin 128 159]]
        set srphi_hex [bin2hex [string range $probe_bin 160 191]]
        set srplo_hex [bin2hex [string range $probe_bin 192 223]]
        set wstate    [wstate_name [bin2dec [string range $probe_bin 224 228]]]
        set fault     [string index $probe_bin 229]
        set busy      [string index $probe_bin 230]
        set atc_buserr [string range $probe_bin 231 252]
        set atc_valid  [string range $probe_bin 253 274]

        # Parse sticky state
        set fl  [string index $probe_bin 275]
        set wtl [string index $probe_bin 276]
        set fault_tc_hex     [bin2hex [string range $probe_bin 277 308]]
        set fault_addr_hex   [bin2hex [string range $probe_bin 309 340]]
        set fault_wstate     [wstate_name [bin2dec [string range $probe_bin 341 345]]]
        set fault_atc_buserr [string range $probe_bin 346 367]
        set fault_atc_valid  [string range $probe_bin 368 389]
        set fault_mmusr_bin  [string range $probe_bin 390 405]
        set fault_mmusr_val  [bin2dec $fault_mmusr_bin]
        set fault_mmusr_hex  [bin2hex $fault_mmusr_bin]
        set fault_saved_addr [bin2hex [string range $probe_bin 406 437]]
        set fault_desc_addr  [bin2hex [string range $probe_bin 438 469]]
        set fault_desc_data  [bin2hex [string range $probe_bin 470 501]]
        set fault_fc_val     [bin2dec [string range $probe_bin 502 504]]

        # Parse PMM2 sticky per-level descriptors (194 bits)
        set pm2_fl           [string index $probe2_bin 0]
        set pm2_wtl          [string index $probe2_bin 1]
        set ptr1_addr_hex    [bin2hex [string range $probe2_bin 2 33]]
        set ptr1_data_hex    [bin2hex [string range $probe2_bin 34 65]]
        set ptr2_addr_hex    [bin2hex [string range $probe2_bin 66 97]]
        set ptr2_data_hex    [bin2hex [string range $probe2_bin 98 129]]
        set ptr3_addr_hex    [bin2hex [string range $probe2_bin 130 161]]
        set ptr3_data_hex    [bin2hex [string range $probe2_bin 162 193]]

        # Count buserr entries
        set be_count 0
        for {set i 0} {$i < 22} {incr i} {
            if {[string index $atc_buserr $i] eq "1"} { incr be_count }
        }

        set line [format "%5d  %s  TC=%s TT0=%s TT1=%s CRP=%s:%s SRP=%s:%s W=%-12s F=%s B=%s BE=%d/%s V=%s FL=%s WTL=%s PM2_FL=%s PM2_WTL=%s" \
            $poll_count $ts $tc_hex $tt0_hex $tt1_hex \
            $crphi_hex $crplo_hex $srphi_hex $srplo_hex \
            $wstate $fault $busy \
            $be_count $atc_buserr $atc_valid $fl $wtl $pm2_fl $pm2_wtl]

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
            set tc_decode [decode_tc $fault_tc_hex]
            set fc_decode [fc_name $fault_fc_val]
            set alert [format "*** FAULT *** ADDR=%s SAVED_ADDR=%s FC=%s TC=%s(%s) W=%s MMUSR=%s(%s) DESC_ADDR=%s DESC_DATA=%s ATC_BUSERR=%d/%s ATC_VALID=%s" \
                $fault_addr_hex $fault_saved_addr \
                $fc_decode \
                $fault_tc_hex $tc_decode $fault_wstate \
                $fault_mmusr_hex $mmusr_decode \
                $fault_desc_addr $fault_desc_data \
                $fbe_count $fault_atc_buserr $fault_atc_valid]
            puts $alert
            puts $log_file $alert
            flush $log_file
        }
        if {$pm2_fl eq "1" || $pm2_wtl eq "1"} {
            set ptr_line [format "*** PMM2 *** PTR1=%s:%s(%s) PTR2=%s:%s(%s) PTR3=%s:%s(%s)" \
                $ptr1_addr_hex $ptr1_data_hex [decode_desc $ptr1_data_hex] \
                $ptr2_addr_hex $ptr2_data_hex [decode_desc $ptr2_data_hex] \
                $ptr3_addr_hex $ptr3_data_hex [decode_desc $ptr3_data_hex]]
            puts $ptr_line
            puts $log_file $ptr_line
            flush $log_file
        }
        if {$wtl eq "1"} {
            set alert "*** WALKER TIMEOUT ***"
            puts $alert
            puts $log_file $alert
            flush $log_file
        }

        set prev_bin $probe_bin
        set prev2_bin $probe2_bin
    }

    after 500
}

close $log_file
end_insystem_source_probe
