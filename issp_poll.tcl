# Poll all ISSP debug probes v8 - comprehensive 68030 debugging
# Usage: quartus_stp -t issp_poll.tcl
#
# ISSP Instances:
#   0: PMMU (511 bits) - TC, TT0, TT1, CRP, SRP, walker, ATC, sticky fault
#   1: PMM2 (194 bits) - Per-level descriptor snapshots
#   2: EXCF (128 bits) - CHK/Group2 exception frame latch
#   3: CPUS (458 bits) - CPU core state (live + sticky hang capture + T0 edge)
#   4: REGS (512 bits) - Register file D0-D7, A0-A7
#
# Instance 3 (CPUS) probe layout (458 bits, MSB first):
#   Live state (223 bits):
#     PC[31:0] opcode[15:0] state[1:0] micro_state[7:0] next_micro_state[7:0]
#     memmask[5:0] FlagsSR[7:0] SVmode memaddr[31:0] exe_PC[31:0]
#     last_opc_read[15:0] brief[15:0] trap_vector[31:0]
#     trap_illegal trap_priv trap_addr_error trap_berr trap_mmu_berr
#     make_berr trap_1111 trapmake decodeOPC setnextpass
#     setendOPC stop clkena_lw cpu_halted
#   Sticky hang capture (184 bits):
#     hang_latched hang_overflow hang_PC[31:0] hang_opcode[15:0]
#     hang_state[1:0] hang_micro[7:0] hang_nmicro[7:0]
#     hang_memmask[5:0] hang_FlagsSR[7:0] hang_SVmode
#     hang_memaddr[31:0] hang_exe_PC[31:0] hang_trap_vector[31:0]
#     hang_trapmake hang_pmmu_fault hang_cpu_halted live_pmmu_fault live_interrupt
#   T0 edge capture (51 bits):
#     t0_latched t0_cause_directSR t0_cause_to_SR t0_pc[31:0] t0_opcode[15:0]
#
# Instance 4 (REGS) probe layout (512 bits, MSB first):
#     [511:480] D0  [479:448] D1  [447:416] D2  [415:384] D3
#     [383:352] D4  [351:320] D5  [319:288] D6  [287:256] D7
#     [255:224] A0  [223:192] A1  [191:160] A2  [159:128] A3
#     [127:96]  A4  [95:64]   A5  [63:32]   A6  [31:0]    A7

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

# Micro-state names (from TG68K_Pack.vhd enum order)
set micro_names {
    idle init nop
    exg1
    ld_nn ld_dAn1 ld_AnXn1 ld_AnXn2 st_nn st_dAn1 st_AnXn1 st_AnXn2
    bra1 bsr1 bsr2
    dbcc1
    movem1 movem2 movem3
    andi
    op_AxAy
    cmpm
    link1 link2 unlink1 unlink2
    trap0 trap1 trap2 trap3
    cas1 cas2
    chk1 chk2
    mul1 mul2
    div1 div2 div3
    rte1 rte2 rte3 rte4 rte5
    bf1
    pack1
    rtd1
    movec1 movec2
    movep1 movep2 movep3 movep4 movep5
    lea1
    bits1
    pea1
    move2mem_addr
    pmove_decode pmove_mem_to_mmu_hi pmove_mem_to_mmu_lo
    pmove_mmu_to_mem_hi pmove_mmu_to_mem_lo
    pmove_dn_hi pmove_dn_read_wait
    ptest1 pflush1 pload1
    moves0 moves1
    trace_stk_grp2
    berr1 berr2 berr3 berr4 berr5 berr6 berr7 berr8
}

proc micro_name {val} {
    global micro_names
    if {$val < [llength $micro_names]} {
        set name [lindex $micro_names $val]
        return [format "%s(%d)" $name $val]
    }
    return [format "UNK(%d)" $val]
}

set state_names {"idle(0)" "exec(1)" "addr(2)" "data(3)"}
proc state_name {val} {
    global state_names
    if {$val < 4} { return [lindex $state_names $val] }
    return "UNK($val)"
}

set wstate_names {W_IDLE W_ROOT W_ROOT_LOW W_PTR1 W_PTR1_LOW W_PTR2 W_PTR2_LOW W_PTR3 W_PTR3_LOW W_PTR4 W_PTR4_LOW W_INDIRECT W_INDIRECT_LOW W_PAGE W_TABLE_UPDATE W_UPDATE_DESC W_PLOAD_FLUSH W_FILL W_COMPLETE W_FAULT}
proc wstate_name {val} {
    global wstate_names
    if {$val < [llength $wstate_names]} { return [lindex $wstate_names $val] }
    return "UNK($val)"
}

proc fc_name {val} {
    set names {"USR_D(0)" "USR_D(1)" "USR_P(2)" "USR_P(3)" "SV_D(4)" "SV_D(5)" "SV_P(6)" "CPU(7)"}
    return [lindex $names $val]
}

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
    set wp [expr {($val >> 2) & 1}]
    set u  [expr {($val >> 3) & 1}]
    set m  [expr {($val >> 4) & 1}]
    set ci [expr {($val >> 6) & 1}]
    switch $dt {
        0 { set dt_name "INV" }
        1 { set dt_name "PAGE" }
        2 { set dt_name "SHORT" }
        3 { set dt_name "LONG" }
    }
    return "DT=$dt_name,WP=$wp,U=$u,M=$m,CI=$ci"
}

proc decode_flagsSR {val} {
    set t1 [expr {($val >> 7) & 1}]
    set t0 [expr {($val >> 6) & 1}]
    set s  [expr {($val >> 5) & 1}]
    set m  [expr {($val >> 4) & 1}]
    set ipl [expr {$val & 7}]
    set parts {}
    if {$t1} {lappend parts "T1"}
    if {$t0} {lappend parts "T0"}
    if {$s}  {lappend parts "S"}
    if {$m}  {lappend parts "M"}
    lappend parts "IPM=$ipl"
    return [join $parts ","]
}

# Decode trap vector to exception name
proc trap_name {hex} {
    scan $hex %x val
    set vec [expr {$val / 4}]
    switch $vec {
        2  { return "BUS_ERR" }
        3  { return "ADDR_ERR" }
        4  { return "ILLEGAL" }
        5  { return "DIV0" }
        6  { return "CHK" }
        7  { return "TRAPV" }
        8  { return "PRIV" }
        9  { return "TRACE" }
        10 { return "LINE_A" }
        11 { return "LINE_F" }
        14 { return "FMT_ERR" }
        56 { return "MMU_CFG" }
        61 { return "MMU_BERR" }
        default {
            if {$vec >= 24 && $vec <= 31} {
                return [format "INT%d" [expr {$vec - 24}]]
            }
            if {$vec >= 32 && $vec <= 47} {
                return [format "TRAP#%d" [expr {$vec - 32}]]
            }
            return [format "VEC%d" $vec]
        }
    }
}

puts "=== Comprehensive 68030 ISSP Debug Poller v8 ==="
puts "Instances: PMMU(0) PMM2(1) EXCF(2) CPUS(3) REGS(4)"
puts "Polling every 500ms. Ctrl+C to stop."
puts ""

start_insystem_source_probe -hardware_name $hw_name -device_name $dev_name

set prev_bins [dict create]
set poll_count 0
set log_file [open "issp_log.txt" w]
puts $log_file "# 68030 ISSP Poll Log v8 - [clock format [clock seconds]]"
flush $log_file

while {1} {
    # Read all instances
    set p0 [read_probe_data -instance_index 0]
    set p3 [read_probe_data -instance_index 3]
    set p4 [read_probe_data -instance_index 4]

    incr poll_count

    set changed 0
    if {![dict exists $prev_bins p0] || $p0 ne [dict get $prev_bins p0]} { set changed 1 }
    if {![dict exists $prev_bins p3] || $p3 ne [dict get $prev_bins p3]} { set changed 1 }
    if {![dict exists $prev_bins p4] || $p4 ne [dict get $prev_bins p4]} { set changed 1 }

    if {$changed} {
        set ts [clock format [clock seconds] -format "%H:%M:%S"]

        # ---- Parse CPUS (Instance 3, 458 bits) ----
        if {[string length $p3] >= 458} {
            set off 0
            # Live state (223 bits)
            set cpu_pc       [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
            set cpu_opcode   [bin2hex [string range $p3 $off [expr {$off+15}]]]; incr off 16
            set cpu_state    [bin2dec [string range $p3 $off [expr {$off+1}]]];  incr off 2
            set cpu_micro    [bin2dec [string range $p3 $off [expr {$off+7}]]];  incr off 8
            set cpu_nmicro   [bin2dec [string range $p3 $off [expr {$off+7}]]];  incr off 8
            set cpu_memmask  [bin2hex [string range $p3 $off [expr {$off+5}]]];  incr off 6
            set cpu_flagsSR  [bin2dec [string range $p3 $off [expr {$off+7}]]];  incr off 8
            set cpu_svmode   [string index $p3 $off]; incr off 1
            set cpu_memaddr  [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
            set cpu_exe_pc   [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
            set cpu_lastopc  [bin2hex [string range $p3 $off [expr {$off+15}]]]; incr off 16
            set cpu_brief    [bin2hex [string range $p3 $off [expr {$off+15}]]]; incr off 16
            set cpu_trapvec  [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
            set trp_ill      [string index $p3 $off]; incr off 1
            set trp_priv     [string index $p3 $off]; incr off 1
            set trp_addr     [string index $p3 $off]; incr off 1
            set trp_berr     [string index $p3 $off]; incr off 1
            set trp_mmuberr  [string index $p3 $off]; incr off 1
            set trp_mkberr   [string index $p3 $off]; incr off 1
            set trp_1111     [string index $p3 $off]; incr off 1
            set trp_make     [string index $p3 $off]; incr off 1
            set cpu_decode   [string index $p3 $off]; incr off 1
            set cpu_snp      [string index $p3 $off]; incr off 1
            set cpu_seopc    [string index $p3 $off]; incr off 1
            set cpu_stop_f   [string index $p3 $off]; incr off 1
            set cpu_clkena   [string index $p3 $off]; incr off 1
            set cpu_halted   [string index $p3 $off]; incr off 1
            # off=223 (live section complete)

            # Build trap flags string
            set traps ""
            if {$trp_ill eq "1"}     { append traps "ILL " }
            if {$trp_priv eq "1"}    { append traps "PRIV " }
            if {$trp_addr eq "1"}    { append traps "ADDR " }
            if {$trp_berr eq "1"}    { append traps "BERR " }
            if {$trp_mmuberr eq "1"} { append traps "MMU_BERR " }
            if {$trp_mkberr eq "1"}  { append traps "MK_BERR " }
            if {$trp_1111 eq "1"}    { append traps "F-LINE " }
            if {$trp_make eq "1"}    { append traps "TRAPMAKE " }
            if {$traps eq ""}        { set traps "none" }

            set status_flags ""
            if {$cpu_decode eq "1"}  { append status_flags "DEC " }
            if {$cpu_snp eq "1"}     { append status_flags "SNP " }
            if {$cpu_seopc eq "1"}   { append status_flags "SEOPC " }
            if {$cpu_stop_f eq "1"}  { append status_flags "STOP " }
            if {$cpu_clkena eq "0"}  { append status_flags "STALL " }
            if {$cpu_halted eq "1"}  { append status_flags "HALTED " }

            set line [format "%5d %s CPU: PC=%s OPC=$%s ST=%s US=%s NS=%s MM=$%s SR=%02X(%s) SV=%s ADDR=%s" \
                $poll_count $ts $cpu_pc $cpu_opcode \
                [state_name $cpu_state] [micro_name $cpu_micro] [micro_name $cpu_nmicro] \
                $cpu_memmask $cpu_flagsSR [decode_flagsSR $cpu_flagsSR] $cpu_svmode $cpu_memaddr]
            puts $line
            puts $log_file $line

            set line2 [format "            EXE_PC=%s LOPC=$%s BRIEF=$%s TVEC=%s(%s) TRAPS: %s FLAGS: %s" \
                $cpu_exe_pc $cpu_lastopc $cpu_brief \
                $cpu_trapvec [trap_name $cpu_trapvec] \
                [string trim $traps] [string trim $status_flags]]
            puts $line2
            puts $log_file $line2

            # Sticky hang capture (184 bits starting at off=223)
            set hang_latched  [string index $p3 $off]; incr off 1
            set hang_overflow [string index $p3 $off]; incr off 1
            if {$hang_latched eq "1"} {
                set h_pc      [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
                set h_opcode  [bin2hex [string range $p3 $off [expr {$off+15}]]]; incr off 16
                set h_state   [bin2dec [string range $p3 $off [expr {$off+1}]]];  incr off 2
                set h_micro   [bin2dec [string range $p3 $off [expr {$off+7}]]];  incr off 8
                set h_nmicro  [bin2dec [string range $p3 $off [expr {$off+7}]]];  incr off 8
                set h_memmask [bin2hex [string range $p3 $off [expr {$off+5}]]];  incr off 6
                set h_flagsSR [bin2dec [string range $p3 $off [expr {$off+7}]]];  incr off 8
                set h_svmode  [string index $p3 $off]; incr off 1
                set h_memaddr [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
                set h_exepc   [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
                set h_trapvec [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
                set h_tmake   [string index $p3 $off]; incr off 1
                set h_pfault  [string index $p3 $off]; incr off 1
                set h_halted  [string index $p3 $off]; incr off 1
                # Live signals embedded in hang section
                set live_pfault [string index $p3 $off]; incr off 1
                set live_int    [string index $p3 $off]; incr off 1

                set hang_line [format "*** HANG *** PC=%s OPC=$%s ST=%s US=%s NS=%s MM=$%s SR=%02X(%s) SV=%s ADDR=%s EXEPC=%s TVEC=%s(%s) TM=%s PF=%s HALT=%s" \
                    $h_pc $h_opcode \
                    [state_name $h_state] [micro_name $h_micro] [micro_name $h_nmicro] \
                    $h_memmask $h_flagsSR [decode_flagsSR $h_flagsSR] $h_svmode \
                    $h_memaddr $h_exepc \
                    $h_trapvec [trap_name $h_trapvec] \
                    $h_tmake $h_pfault $h_halted]
                puts $hang_line
                puts $log_file $hang_line
            } else {
                # Skip hang fields to reach T0 section
                incr off 182  ;# 184 - 2 (latched+overflow already consumed)
            }

            # T0 edge capture (51 bits at end of probe)
            # off should now be at 223+184=407
            set t0_latched   [string index $p3 $off]; incr off 1
            set t0_directSR  [string index $p3 $off]; incr off 1
            set t0_to_SR     [string index $p3 $off]; incr off 1
            set t0_pc        [bin2hex [string range $p3 $off [expr {$off+31}]]]; incr off 32
            set t0_opcode    [bin2hex [string range $p3 $off [expr {$off+15}]]]; incr off 16
            if {$t0_latched eq "1"} {
                set t0_cause "UNKNOWN"
                if {$t0_directSR eq "1"} { set t0_cause "directSR(RTE)" }
                if {$t0_to_SR eq "1"}    { set t0_cause "to_SR(MOVE/ORI/EORI)" }
                if {$t0_directSR eq "1" && $t0_to_SR eq "1"} { set t0_cause "BOTH!?" }
                set t0_line [format "*** T0 SET *** PC=%s OPC=$%s CAUSE=%s" \
                    $t0_pc $t0_opcode $t0_cause]
                puts $t0_line
                puts $log_file $t0_line
            }
        } else {
            set line [format "%5d %s CPUS: probe too short (%d bits, need 458)" $poll_count $ts [string length $p3]]
            puts $line
            puts $log_file $line
        }

        # ---- Parse REGS (Instance 4, 511 bits: 15 regs x 32 + A7[31:1]) ----
        if {[string length $p4] >= 511} {
            set roff 0
            set regs {}
            foreach rname {D0 D1 D2 D3 D4 D5 D6 D7 A0 A1 A2 A3 A4 A5 A6} {
                lappend regs [format "%s=%s" $rname [bin2hex [string range $p4 $roff [expr {$roff+31}]]]]
                incr roff 32
            }
            # A7: 31 bits [31:1], append a '0' for bit 0
            lappend regs [format "A7=%s" [bin2hex "[string range $p4 $roff [expr {$roff+30}]]0"]]
            set line [format "     REGS: %s" [join $regs " "]]
            puts $line
            puts $log_file $line
        }

        # ---- Parse PMMU (Instance 0, 511 bits) ----
        if {[string length $p0] >= 505} {
            set tc_hex    [bin2hex [string range $p0 0 31]]
            set tt0_hex   [bin2hex [string range $p0 32 63]]
            set tt1_hex   [bin2hex [string range $p0 64 95]]
            set crphi_hex [bin2hex [string range $p0 96 127]]
            set crplo_hex [bin2hex [string range $p0 128 159]]
            set srphi_hex [bin2hex [string range $p0 160 191]]
            set srplo_hex [bin2hex [string range $p0 192 223]]
            set wstate    [wstate_name [bin2dec [string range $p0 224 228]]]
            set fault     [string index $p0 229]
            set busy      [string index $p0 230]
            set atc_buserr [string range $p0 231 252]
            set atc_valid  [string range $p0 253 274]
            set fl  [string index $p0 275]
            set wtl [string index $p0 276]

            set be_count 0
            for {set i 0} {$i < 22} {incr i} {
                if {[string index $atc_buserr $i] eq "1"} { incr be_count }
            }

            set line [format "     PMMU: TC=%s TT0=%s TT1=%s CRP=%s:%s SRP=%s:%s W=%-12s F=%s B=%s BE=%d V=%s FL=%s WTL=%s" \
                $tc_hex $tt0_hex $tt1_hex \
                $crphi_hex $crplo_hex $srphi_hex $srplo_hex \
                $wstate $fault $busy $be_count $atc_valid $fl $wtl]
            puts $line
            puts $log_file $line

            # PMMU sticky fault
            if {$fl eq "1"} {
                set fault_addr_hex   [bin2hex [string range $p0 309 340]]
                set fault_wstate     [wstate_name [bin2dec [string range $p0 341 345]]]
                set fault_mmusr_val  [bin2dec [string range $p0 390 405]]
                set fault_mmusr_hex  [bin2hex [string range $p0 390 405]]
                set fault_saved_addr [bin2hex [string range $p0 406 437]]
                set fault_desc_addr  [bin2hex [string range $p0 438 469]]
                set fault_desc_data  [bin2hex [string range $p0 470 501]]
                set fault_fc_val     [bin2dec [string range $p0 502 504]]

                set alert [format "*** PMMU FAULT *** ADDR=%s SAVED=%s FC=%s W=%s MMUSR=%s(%s) DESC=%s:%s" \
                    $fault_addr_hex $fault_saved_addr \
                    [fc_name $fault_fc_val] $fault_wstate \
                    $fault_mmusr_hex [decode_mmusr $fault_mmusr_val] \
                    $fault_desc_addr $fault_desc_data]
                puts $alert
                puts $log_file $alert
            }
            if {$wtl eq "1"} {
                puts "*** WALKER TIMEOUT ***"
                puts $log_file "*** WALKER TIMEOUT ***"
            }
        }

        # ---- Parse PMM2 (Instance 1, 194 bits) - only on fault ----
        if {[string length $p0] >= 505} {
            set fl [string index $p0 275]
            if {$fl eq "1"} {
                set p1 [read_probe_data -instance_index 1]
                if {[string length $p1] >= 194} {
                    set ptr1_addr [bin2hex [string range $p1 2 33]]
                    set ptr1_data [bin2hex [string range $p1 34 65]]
                    set ptr2_addr [bin2hex [string range $p1 66 97]]
                    set ptr2_data [bin2hex [string range $p1 98 129]]
                    set ptr3_addr [bin2hex [string range $p1 130 161]]
                    set ptr3_data [bin2hex [string range $p1 162 193]]
                    set ptr_line [format "*** PMM2 *** PTR1=%s:%s(%s) PTR2=%s:%s(%s) PTR3=%s:%s(%s)" \
                        $ptr1_addr $ptr1_data [decode_desc $ptr1_data] \
                        $ptr2_addr $ptr2_data [decode_desc $ptr2_data] \
                        $ptr3_addr $ptr3_data [decode_desc $ptr3_data]]
                    puts $ptr_line
                    puts $log_file $ptr_line
                }
            }
        }

        puts ""
        puts $log_file ""
        flush $log_file
        flush stdout

        dict set prev_bins p0 $p0
        dict set prev_bins p3 $p3
        dict set prev_bins p4 $p4
    }

    after 500
}

close $log_file
end_insystem_source_probe
