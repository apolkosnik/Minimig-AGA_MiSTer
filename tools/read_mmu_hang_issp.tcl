load_package jtag
load_package insystem_source_probe

proc find_instance {hw_name dev_name wanted_name} {
    set insts [get_insystem_source_probe_instance_info -hardware_name $hw_name -device_name $dev_name]
    foreach inst $insts {
        if {[lindex $inst 3] eq $wanted_name} {
            return $inst
        }
    }
    error "ISSP instance $wanted_name not found"
}

proc find_instance_optional {hw_name dev_name wanted_name} {
    set insts [get_insystem_source_probe_instance_info -hardware_name $hw_name -device_name $dev_name]
    foreach inst $insts {
        if {[lindex $inst 3] eq $wanted_name} {
            return $inst
        }
    }
    return {}
}

proc get_hw {} {
    set hw_names [get_hardware_names]
    if {[llength $hw_names] == 0} {
        error "no JTAG hardware found"
    }
    foreach hw_name $hw_names {
        set dev_names [get_device_names -hardware_name $hw_name]
        foreach dev_name $dev_names {
            if {[string match *@2:* $dev_name]} {
                return [list $hw_name $dev_name]
            }
        }
    }
    error "FPGA device not found"
}

proc bit_slice {bin msb lsb} {
    set start [expr {[string length $bin] - 1 - $msb}]
    set end   [expr {[string length $bin] - 1 - $lsb}]
    return [string range $bin $start $end]
}

proc bin_to_hex {bin} {
    set bin [string trim $bin]
    if {$bin eq ""} {
        return ""
    }
    set padlen [expr {(4 - ([string length $bin] % 4)) % 4}]
    if {$padlen != 0} {
        set bin [string repeat "0" $padlen]$bin
    }
    set out ""
    for {set i 0} {$i < [string length $bin]} {incr i 4} {
        scan [string range $bin $i [expr {$i + 3}]] %b val
        append out [format "%X" $val]
    }
    return $out
}

proc bin_to_uint {bin} {
    if {$bin eq ""} {
        return 0
    }
    scan $bin %b val
    return $val
}

proc decode_cpustate {v} {
    switch $v {
        0 { return "fetch" }
        1 { return "idle" }
        2 { return "read" }
        3 { return "write" }
        default { return "unk" }
    }
}

proc decode_fc {v} {
    switch $v {
        0 { return "ud0" }
        1 { return "ud1" }
        2 { return "up0" }
        3 { return "up1" }
        4 { return "sd0" }
        5 { return "sd1" }
        6 { return "sp" }
        7 { return "cpu" }
        default { return "unk" }
    }
}

proc show_cpustate {bin} {
    puts "== CPUS =="
    set live_pc         [bin_to_hex [bit_slice $bin 457 426]]
    set live_opcode     [bin_to_hex [bit_slice $bin 425 410]]
    set live_state      [bin_to_uint [bit_slice $bin 409 408]]
    set live_micro      [bin_to_uint [bit_slice $bin 407 400]]
    set live_next_micro [bin_to_uint [bit_slice $bin 399 392]]
    set live_memmask    [bin_to_hex [bit_slice $bin 391 386]]
    set live_flags      [bin_to_hex [bit_slice $bin 385 378]]
    set live_svmode     [bin_to_uint [bit_slice $bin 377 377]]
    set live_memaddr    [bin_to_hex [bit_slice $bin 376 345]]
    set live_exe_pc     [bin_to_hex [bit_slice $bin 344 313]]
    set live_last_opc   [bin_to_hex [bit_slice $bin 312 297]]
    set live_brief      [bin_to_hex [bit_slice $bin 296 281]]
    set live_trap_vec   [bin_to_hex [bit_slice $bin 280 249]]
    set live_trap_illegal [bin_to_uint [bit_slice $bin 248 248]]
    set live_trap_priv    [bin_to_uint [bit_slice $bin 247 247]]
    set live_trap_addr    [bin_to_uint [bit_slice $bin 246 246]]
    set live_trap_berr    [bin_to_uint [bit_slice $bin 245 245]]
    set live_trap_mmu     [bin_to_uint [bit_slice $bin 244 244]]
    set live_make_berr    [bin_to_uint [bit_slice $bin 243 243]]
    set live_trap_1111    [bin_to_uint [bit_slice $bin 242 242]]
    set live_trapmake     [bin_to_uint [bit_slice $bin 241 241]]
    set live_decodeopc    [bin_to_uint [bit_slice $bin 240 240]]
    set live_setnextpass  [bin_to_uint [bit_slice $bin 239 239]]
    set live_setendopc    [bin_to_uint [bit_slice $bin 238 238]]
    set live_stop         [bin_to_uint [bit_slice $bin 237 237]]
    set live_clkena_lw    [bin_to_uint [bit_slice $bin 236 236]]
    set live_cpu_halted   [bin_to_uint [bit_slice $bin 235 235]]
    set hang_latched      [bin_to_uint [bit_slice $bin 234 234]]
    set hang_overflow     [bin_to_uint [bit_slice $bin 233 233]]
    set hang_pc           [bin_to_hex [bit_slice $bin 232 201]]
    set hang_opcode       [bin_to_hex [bit_slice $bin 200 185]]
    set hang_state        [bin_to_uint [bit_slice $bin 184 183]]
    set hang_micro        [bin_to_uint [bit_slice $bin 182 175]]
    set hang_next_micro   [bin_to_uint [bit_slice $bin 174 167]]
    set hang_memmask      [bin_to_hex [bit_slice $bin 166 161]]
    set hang_flags        [bin_to_hex [bit_slice $bin 160 153]]
    set hang_svmode       [bin_to_uint [bit_slice $bin 152 152]]
    set hang_memaddr      [bin_to_hex [bit_slice $bin 151 120]]
    set hang_exe_pc       [bin_to_hex [bit_slice $bin 119 88]]
    set hang_trap_vec     [bin_to_hex [bit_slice $bin 87 56]]
    set hang_trapmake     [bin_to_uint [bit_slice $bin 55 55]]
    set hang_pmmu_fault   [bin_to_uint [bit_slice $bin 54 54]]
    set hang_cpu_halted   [bin_to_uint [bit_slice $bin 53 53]]
    set live_pmmu_fault   [bin_to_uint [bit_slice $bin 52 52]]
    set live_interrupt    [bin_to_uint [bit_slice $bin 51 51]]
    set t0_latched        [bin_to_uint [bit_slice $bin 50 50]]
    set t0_directsr       [bin_to_uint [bit_slice $bin 49 49]]
    set t0_tosr           [bin_to_uint [bit_slice $bin 48 48]]
    set t0_pc             [bin_to_hex [bit_slice $bin 47 16]]
    set t0_opcode         [bin_to_hex [bit_slice $bin 15 0]]

    puts [format "live: pc=%08s opcode=%04s state=%s(%u) micro=%u next=%u memmask=%02s flags=%02s sv=%u" \
        $live_pc $live_opcode [decode_cpustate $live_state] $live_state $live_micro $live_next_micro $live_memmask $live_flags $live_svmode]
    puts [format "      memaddr=%08s exe_pc=%08s last_opc=%04s brief=%04s trap_vec=%08s" \
        $live_memaddr $live_exe_pc $live_last_opc $live_brief $live_trap_vec]
    puts [format "      traps: ill=%u priv=%u addr=%u berr=%u mmu_berr=%u make_berr=%u 1111=%u trapmake=%u" \
        $live_trap_illegal $live_trap_priv $live_trap_addr $live_trap_berr $live_trap_mmu $live_make_berr $live_trap_1111 $live_trapmake]
    puts [format "      flow: decodeOPC=%u setnextpass=%u setendOPC=%u stop=%u clkena_lw=%u cpu_halted=%u pmmu_fault=%u interrupt=%u" \
        $live_decodeopc $live_setnextpass $live_setendopc $live_stop $live_clkena_lw $live_cpu_halted $live_pmmu_fault $live_interrupt]

    puts [format "hang: latched=%u overflow=%u pc=%08s opcode=%04s state=%s(%u) micro=%u next=%u memmask=%02s flags=%02s sv=%u" \
        $hang_latched $hang_overflow $hang_pc $hang_opcode [decode_cpustate $hang_state] $hang_state $hang_micro $hang_next_micro $hang_memmask $hang_flags $hang_svmode]
    puts [format "      memaddr=%08s exe_pc=%08s trap_vec=%08s trapmake=%u pmmu_fault=%u cpu_halted=%u" \
        $hang_memaddr $hang_exe_pc $hang_trap_vec $hang_trapmake $hang_pmmu_fault $hang_cpu_halted]

    puts [format "t0: latched=%u directSR=%u toSR=%u pc=%08s opcode=%04s" \
        $t0_latched $t0_directsr $t0_tosr $t0_pc $t0_opcode]
}

proc show_regs {bin} {
    puts "== REGS =="
    set names {D0 D1 D2 D3 D4 D5 D6 D7 A0 A1 A2 A3 A4 A5 A6}
    set msb 510
    foreach name $names {
        set lsb [expr {$msb - 31}]
        puts [format "%s=%08s" $name [bin_to_hex [bit_slice $bin $msb $lsb]]]
        set msb [expr {$lsb - 1}]
    }
    set a7_hi [bit_slice $bin 30 0]
    puts [format "A7=%08s" [bin_to_hex ${a7_hi}0]]
}

proc show_pmmu {bin} {
    puts "== PMMU =="
    puts [format "TC=%08s TT0=%08s TT1=%08s" \
        [bin_to_hex [bit_slice $bin 510 479]] \
        [bin_to_hex [bit_slice $bin 478 447]] \
        [bin_to_hex [bit_slice $bin 446 415]]]
    puts [format "CRP_H=%08s CRP_L=%08s SRP_H=%08s SRP_L=%08s" \
        [bin_to_hex [bit_slice $bin 414 383]] \
        [bin_to_hex [bit_slice $bin 382 351]] \
        [bin_to_hex [bit_slice $bin 350 319]] \
        [bin_to_hex [bit_slice $bin 318 287]]]
    puts [format "live: wstate=%u fault=%u busy=%u atc_buserr=%06s atc_valid=%06s" \
        [bin_to_uint [bit_slice $bin 286 282]] \
        [bin_to_uint [bit_slice $bin 281 281]] \
        [bin_to_uint [bit_slice $bin 280 280]] \
        [bin_to_hex [bit_slice $bin 279 258]] \
        [bin_to_hex [bit_slice $bin 257 236]]]
    puts [format "fault: latched=%u timeout=%u tc=%08s addr=%08s wstate=%u" \
        [bin_to_uint [bit_slice $bin 235 235]] \
        [bin_to_uint [bit_slice $bin 234 234]] \
        [bin_to_hex [bit_slice $bin 233 202]] \
        [bin_to_hex [bit_slice $bin 201 170]] \
        [bin_to_uint [bit_slice $bin 169 165]]]
    puts [format "       atc_buserr=%06s atc_valid=%06s mmusr=%04s saved_addr=%08s" \
        [bin_to_hex [bit_slice $bin 164 143]] \
        [bin_to_hex [bit_slice $bin 142 121]] \
        [bin_to_hex [bit_slice $bin 120 105]] \
        [bin_to_hex [bit_slice $bin 104 73]]]
    puts [format "       desc_addr=%08s desc_data=%08s fc=%s(%u) ipl=%u setendOPC=%u stop=%u cpu_halted=%u" \
        [bin_to_hex [bit_slice $bin 72 41]] \
        [bin_to_hex [bit_slice $bin 40 9]] \
        [decode_fc [bin_to_uint [bit_slice $bin 8 6]]] \
        [bin_to_uint [bit_slice $bin 8 6]] \
        [bin_to_uint [bit_slice $bin 5 3]] \
        [bin_to_uint [bit_slice $bin 2 2]] \
        [bin_to_uint [bit_slice $bin 1 1]] \
        [bin_to_uint [bit_slice $bin 0 0]]]
}

proc show_pmm2 {bin} {
    puts "== PMM2 =="
    set first_pc [bin_to_hex [bit_slice $bin 432 401]]
    set first_exe_pc [bin_to_hex [bit_slice $bin 400 369]]
    set first_opcode [bin_to_hex [bit_slice $bin 368 353]]
    set first_state [bin_to_uint [bit_slice $bin 352 351]]
    set first_micro [bin_to_uint [bit_slice $bin 350 343]]
    set first_next [bin_to_uint [bit_slice $bin 342 335]]
    set first_memaddr [bin_to_hex [bit_slice $bin 334 303]]
    set first_log_addr [bin_to_hex [bit_slice $bin 302 271]]
    set first_phys_addr [bin_to_hex [bit_slice $bin 270 239]]
    set first_flags [bin_to_hex [bit_slice $bin 238 231]]
    set first_rw [bin_to_uint [bit_slice $bin 230 230]]
    set first_is_insn [bin_to_uint [bit_slice $bin 229 229]]
    set first_fc [bin_to_uint [bit_slice $bin 228 226]]
    set first_a7 [bin_to_hex [bit_slice $bin 225 194]]
    set fault_latched [bin_to_uint [bit_slice $bin 193 193]]
    set timeout_latched [bin_to_uint [bit_slice $bin 192 192]]
    set ptr1_addr [bin_to_hex [bit_slice $bin 191 160]]
    set ptr1_data [bin_to_hex [bit_slice $bin 159 128]]
    set ptr2_addr [bin_to_hex [bit_slice $bin 127 96]]
    set ptr2_data [bin_to_hex [bit_slice $bin 95 64]]
    set ptr3_addr [bin_to_hex [bit_slice $bin 63 32]]
    set ptr3_data [bin_to_hex [bit_slice $bin 31 0]]

    puts [format "fault_latched=%u timeout=%u" $fault_latched $timeout_latched]
    puts [format "first: pc=%08s exe_pc=%08s opcode=%04s state=%s(%u) micro=%u next=%u flags=%02s" \
        $first_pc $first_exe_pc $first_opcode [decode_cpustate $first_state] $first_state \
        $first_micro $first_next $first_flags]
    puts [format "       memaddr=%08s log=%08s phys=%08s a7=%08s rw=%u insn=%u fc=%s(%u)" \
        $first_memaddr $first_log_addr $first_phys_addr $first_a7 $first_rw $first_is_insn \
        [decode_fc $first_fc] $first_fc]
    puts [format "ptr1: addr=%08s data=%08s" $ptr1_addr $ptr1_data]
    puts [format "ptr2: addr=%08s data=%08s" $ptr2_addr $ptr2_data]
    puts [format "ptr3: addr=%08s data=%08s" $ptr3_addr $ptr3_data]
}

proc show_excf {bin} {
    puts "== EXCF =="
    puts [format "latched=%u priv=%u ill=%u addr=%u berr=%u mmu_berr=%u make_berr=%u 1111=%u" \
        [bin_to_uint [bit_slice $bin 127 127]] \
        [bin_to_uint [bit_slice $bin 126 126]] \
        [bin_to_uint [bit_slice $bin 125 125]] \
        [bin_to_uint [bit_slice $bin 124 124]] \
        [bin_to_uint [bit_slice $bin 123 123]] \
        [bin_to_uint [bit_slice $bin 122 122]] \
        [bin_to_uint [bit_slice $bin 121 121]] \
        [bin_to_uint [bit_slice $bin 120 120]]]
    puts [format "      trap_vec=%08s pc=%08s exe_pc=%08s opcode=%04s flags=%02s" \
        [bin_to_hex [bit_slice $bin 119 88]] \
        [bin_to_hex [bit_slice $bin 87 56]] \
        [bin_to_hex [bit_slice $bin 55 24]] \
        [bin_to_hex [bit_slice $bin 23 8]] \
        [bin_to_hex [bit_slice $bin 7 0]]]
}

proc decode_pmmu_reg {sel} {
    switch -- $sel {
        16 { return "TC" }
        17 { return "DRP" }
        18 { return "SRP" }
        19 { return "CRP" }
        24 { return "MMUSR" }
        25 { return "URP" }
        26 { return "SRP_ALT" }
        default { return "reg" }
    }
}

proc show_tcwr_old {bin} {
    set seen [bin_to_uint [bit_slice $bin 411 411]]
    set count [bin_to_uint [bit_slice $bin 410 403]]
    set last_value [bin_to_hex [bit_slice $bin 402 371]]
    set last_pc [bin_to_hex [bit_slice $bin 370 339]]
    set last_exe_pc [bin_to_hex [bit_slice $bin 338 307]]
    set last_opcode [bin_to_hex [bit_slice $bin 306 291]]
    set last_brief [bin_to_hex [bit_slice $bin 290 275]]
    set last_flags [bin_to_hex [bit_slice $bin 274 267]]
    set last_micro [bin_to_uint [bit_slice $bin 266 259]]
    set last_next [bin_to_uint [bit_slice $bin 258 251]]
    set last_part [bin_to_uint [bit_slice $bin 250 250]]
    set enable_seen [bin_to_uint [bit_slice $bin 249 249]]
    set enable_value [bin_to_hex [bit_slice $bin 248 217]]
    set enable_pc [bin_to_hex [bit_slice $bin 216 185]]
    set enable_opcode [bin_to_hex [bit_slice $bin 184 169]]
    set enable_brief [bin_to_hex [bit_slice $bin 168 153]]
    set disable_seen [bin_to_uint [bit_slice $bin 152 152]]
    set disable_value [bin_to_hex [bit_slice $bin 151 120]]
    set disable_pc [bin_to_hex [bit_slice $bin 119 88]]
    set disable_opcode [bin_to_hex [bit_slice $bin 87 72]]
    set disable_brief [bin_to_hex [bit_slice $bin 71 56]]
    set disable_flags [bin_to_hex [bit_slice $bin 55 48]]
    set live_tc [bin_to_hex [bit_slice $bin 47 16]]
    set pending [bin_to_hex [bit_slice $bin 15 0]]

    puts [format "seen=%u count=%u live_tc=%08s pending=%04s" $seen $count $live_tc $pending]
    puts [format "last: value=%08s pc=%08s exe_pc=%08s opcode=%04s brief=%04s flags=%02s micro=%u next=%u part=%u" \
        $last_value $last_pc $last_exe_pc $last_opcode $last_brief $last_flags $last_micro $last_next $last_part]
    puts [format "first_enable: seen=%u value=%08s pc=%08s opcode=%04s brief=%04s" \
        $enable_seen $enable_value $enable_pc $enable_opcode $enable_brief]
    puts [format "first_disable_after_enable: seen=%u value=%08s pc=%08s opcode=%04s brief=%04s flags=%02s" \
        $disable_seen $disable_value $disable_pc $disable_opcode $disable_brief $disable_flags]
}

proc show_tcwr {bin} {
    puts "== TCWR =="
    if {[string length $bin] < 511} {
        show_tcwr_old $bin
        return
    }

    set seen [bin_to_uint [bit_slice $bin 510 510]]
    set count [bin_to_uint [bit_slice $bin 509 502]]
    set last_sel [bin_to_uint [bit_slice $bin 501 497]]
    set last_part [bin_to_uint [bit_slice $bin 496 496]]
    set last_value [bin_to_hex [bit_slice $bin 495 464]]
    set last_pc [bin_to_hex [bit_slice $bin 463 432]]
    set last_exe_pc [bin_to_hex [bit_slice $bin 431 400]]
    set last_opcode [bin_to_hex [bit_slice $bin 399 384]]
    set last_brief [bin_to_hex [bit_slice $bin 383 368]]
    set last_flags [bin_to_hex [bit_slice $bin 367 360]]
    set last_micro [bin_to_uint [bit_slice $bin 359 352]]
    set last_next [bin_to_uint [bit_slice $bin 351 344]]
    set last_memaddr [bin_to_hex [bit_slice $bin 343 312]]
    set last_a7 [bin_to_hex [bit_slice $bin 311 280]]
    set enable_seen [bin_to_uint [bit_slice $bin 279 279]]
    set enable_value [bin_to_hex [bit_slice $bin 278 247]]
    set enable_pc [bin_to_hex [bit_slice $bin 246 215]]
    set enable_opcode [bin_to_hex [bit_slice $bin 214 199]]
    set enable_brief [bin_to_hex [bit_slice $bin 198 183]]
    set disable_seen [bin_to_uint [bit_slice $bin 182 182]]
    set disable_value [bin_to_hex [bit_slice $bin 181 150]]
    set disable_flags [bin_to_hex [bit_slice $bin 149 142]]
    set crp_hi_seen [bin_to_uint [bit_slice $bin 141 141]]
    set crp_lo_seen [bin_to_uint [bit_slice $bin 140 140]]
    set srp_hi_seen [bin_to_uint [bit_slice $bin 139 139]]
    set srp_lo_seen [bin_to_uint [bit_slice $bin 138 138]]
    set crp_hi_value [bin_to_hex [bit_slice $bin 137 106]]
    set crp_lo_value [bin_to_hex [bit_slice $bin 105 74]]
    set srp_hi_value [bin_to_hex [bit_slice $bin 73 42]]
    set srp_lo_value [bin_to_hex [bit_slice $bin 41 10]]

    puts [format "seen=%u count=%u last=%s(%u) part=%u value=%08s pc=%08s exe_pc=%08s opcode=%04s brief=%04s flags=%02s" \
        $seen $count [decode_pmmu_reg $last_sel] $last_sel $last_part $last_value \
        $last_pc $last_exe_pc $last_opcode $last_brief $last_flags]
    puts [format "      micro=%u next=%u memaddr=%08s a7=%08s" \
        $last_micro $last_next $last_memaddr $last_a7]
    puts [format "tc_enable: seen=%u value=%08s pc=%08s opcode=%04s brief=%04s" \
        $enable_seen $enable_value $enable_pc $enable_opcode $enable_brief]
    puts [format "tc_disable_after_enable: seen=%u value=%08s flags=%02s" \
        $disable_seen $disable_value $disable_flags]
    puts [format "root_writes: CRP_H seen=%u value=%08s CRP_L seen=%u value=%08s" \
        $crp_hi_seen $crp_hi_value $crp_lo_seen $crp_lo_value]
    puts [format "             SRP_H seen=%u value=%08s SRP_L seen=%u value=%08s" \
        $srp_hi_seen $srp_hi_value $srp_lo_seen $srp_lo_value]
}

proc show_pmwr_write {idx addr data} {
    puts [format "w%u: addr=%08s data=%08s" $idx $addr $data]
}

proc walker_state_name {state} {
    switch -- $state {
        0 { return "IDLE" }
        1 { return "START" }
        2 { return "READ_LOW" }
        3 { return "WAIT_LOW" }
        4 { return "READ_HIGH" }
        5 { return "WAIT_HIGH" }
        6 { return "DONE" }
        7 { return "WRITE_LOW" }
        8 { return "WAIT_WR_LOW" }
        9 { return "WRITE_HIGH" }
        10 { return "WAIT_WR_HIGH" }
        11 { return "RAM_GAP" }
        12 { return "WRITE_RAM_GAP" }
        13 { return "READ_PRE_GAP" }
        14 { return "WRITE_PRE_GAP" }
        default { return "UNKNOWN" }
    }
}

proc show_pmwr {bin} {
    puts "== PMWR =="
    if {[string length $bin] >= 509} {
        set timeout_seen [bin_to_uint [bit_slice $bin 508 508]]
        set timeout_state [bin_to_uint [bit_slice $bin 507 504]]
        set timeout_cnt [bin_to_uint [bit_slice $bin 503 492]]
        set timeout_addr [bin_to_hex [bit_slice $bin 491 460]]
        set timeout_ramaddr [bin_to_hex [bit_slice $bin 459 432]]
        set timeout_flags [bin_to_hex [bit_slice $bin 431 416]]
        set write_ack_count [bin_to_uint [bit_slice $bin 415 408]]
        set write_berr_count [bin_to_uint [bit_slice $bin 407 404]]
        set t_mem_ready [bin_to_uint [bit_slice $bin 431 431]]
        set t_ramready [bin_to_uint [bit_slice $bin 430 430]]
        set t_chipready [bin_to_uint [bit_slice $bin 429 429]]
        set t_fastchip_ready [bin_to_uint [bit_slice $bin 428 428]]
        set t_stale_ram [bin_to_uint [bit_slice $bin 427 427]]
        set t_walker_fast [bin_to_uint [bit_slice $bin 426 426]]
        set t_walker_chip [bin_to_uint [bit_slice $bin 425 425]]
        set t_z3ram0 [bin_to_uint [bit_slice $bin 424 424]]
        set t_z3ram1 [bin_to_uint [bit_slice $bin 423 423]]
        set t_z2ram [bin_to_uint [bit_slice $bin 422 422]]
        set t_zram [bin_to_uint [bit_slice $bin 421 421]]
        set t_read_arm [bin_to_uint [bit_slice $bin 420 420]]
        set t_write_arm [bin_to_uint [bit_slice $bin 419 419]]
        set t_req [bin_to_uint [bit_slice $bin 418 418]]
        set t_we [bin_to_uint [bit_slice $bin 417 417]]
        set t_ramsel [bin_to_uint [bit_slice $bin 416 416]]

        puts [format "timeout_detail: seen=%u state=%u(%s) cnt=%u addr=%08s ramaddr=%07s flags=%04s write_ack_count=%u write_berr_count=%u" \
            $timeout_seen $timeout_state [walker_state_name $timeout_state] $timeout_cnt \
            $timeout_addr $timeout_ramaddr $timeout_flags $write_ack_count $write_berr_count]
        puts [format "timeout_flags: mem_ready=%u ramready=%u chipready=%u fastchip_ready=%u stale_ram=%u walker_fast=%u walker_chip=%u z3ram0=%u z3ram1=%u z2ram=%u zram=%u read_arm=%u write_arm=%u req=%u we=%u ramsel=%u" \
            $t_mem_ready $t_ramready $t_chipready $t_fastchip_ready $t_stale_ram \
            $t_walker_fast $t_walker_chip $t_z3ram0 $t_z3ram1 $t_z2ram $t_zram \
            $t_read_arm $t_write_arm $t_req $t_we $t_ramsel]
    } else {
        puts [format "timeout_detail: unavailable, PMWR probe width is %u bits" [string length $bin]]
    }
    set seen [bin_to_uint [bit_slice $bin 403 403]]
    set count [bin_to_uint [bit_slice $bin 402 387]]
    set last_addr [bin_to_hex [bit_slice $bin 386 355]]
    set last_data [bin_to_hex [bit_slice $bin 354 323]]
    set w0_addr [bin_to_hex [bit_slice $bin 322 291]]
    set w0_data [bin_to_hex [bit_slice $bin 290 259]]
    set w1_addr [bin_to_hex [bit_slice $bin 258 227]]
    set w1_data [bin_to_hex [bit_slice $bin 226 195]]
    set w2_addr [bin_to_hex [bit_slice $bin 194 163]]
    set w2_data [bin_to_hex [bit_slice $bin 162 131]]
    set w3_addr [bin_to_hex [bit_slice $bin 130 99]]
    set w3_data [bin_to_hex [bit_slice $bin 98 67]]
    set hit_400a [bin_to_uint [bit_slice $bin 66 66]]
    set hit_400a_addr [bin_to_hex [bit_slice $bin 65 34]]
    set hit_400a_data [bin_to_hex [bit_slice $bin 33 2]]
    set fault_latched [bin_to_uint [bit_slice $bin 1 1]]
    set timeout_latched [bin_to_uint [bit_slice $bin 0 0]]

    puts [format "seen=%u count=%u last_addr=%08s last_data=%08s fault_latched=%u timeout=%u" \
        $seen $count $last_addr $last_data $fault_latched $timeout_latched]
    show_pmwr_write 0 $w0_addr $w0_data
    show_pmwr_write 1 $w1_addr $w1_data
    show_pmwr_write 2 $w2_addr $w2_data
    show_pmwr_write 3 $w3_addr $w3_data
    puts [format "hit_400a: seen=%u addr=%08s data=%08s" \
        $hit_400a $hit_400a_addr $hit_400a_data]
}

proc show_rtwr {bin} {
    puts "== RTWR =="
    if {[string length $bin] < 511} {
        puts [format "root-table write detail unavailable, RTWR probe width is %u bits" [string length $bin]]
        return
    }

    set page_seen [bin_to_uint [bit_slice $bin 510 510]]
    set page_count [bin_to_uint [bit_slice $bin 509 494]]
    set exact_seen [bin_to_uint [bit_slice $bin 493 493]]
    set exact_hits [bin_to_uint [bit_slice $bin 492 489]]
    set exact_hi [bin_to_hex [bit_slice $bin 488 473]]
    set exact_lo [bin_to_hex [bit_slice $bin 472 457]]
    set exact_addr [bin_to_hex [bit_slice $bin 456 425]]
    set exact_pc [bin_to_hex [bit_slice $bin 424 393]]
    set exact_micro [bin_to_uint [bit_slice $bin 392 385]]
    set fc6_seen [bin_to_uint [bit_slice $bin 384 384]]
    set fc6_hits [bin_to_uint [bit_slice $bin 383 380]]
    set fc6_hi [bin_to_hex [bit_slice $bin 379 364]]
    set fc6_lo [bin_to_hex [bit_slice $bin 363 348]]
    set fc6_addr_last [bin_to_hex [bit_slice $bin 347 316]]
    set fc6_pc [bin_to_hex [bit_slice $bin 315 284]]
    set fc6_micro [bin_to_uint [bit_slice $bin 283 276]]
    set srp_l [bin_to_hex [bit_slice $bin 275 244]]
    set srp40_addr [bin_to_hex [bit_slice $bin 243 212]]
    set last0_addr [bin_to_hex [bit_slice $bin 211 180]]
    set last0_data [bin_to_hex [bit_slice $bin 179 164]]
    set last1_addr [bin_to_hex [bit_slice $bin 163 132]]
    set last1_data [bin_to_hex [bit_slice $bin 131 116]]
    set last2_addr [bin_to_hex [bit_slice $bin 115 84]]
    set last2_data [bin_to_hex [bit_slice $bin 83 68]]
    set last3_addr [bin_to_hex [bit_slice $bin 67 36]]
    set last3_data [bin_to_hex [bit_slice $bin 35 20]]
    set last_flags [bin_to_hex [bit_slice $bin 19 12]]
    set last_micro [bin_to_uint [bit_slice $bin 11 4]]
    set last_uds [bin_to_uint [bit_slice $bin 3 3]]
    set last_lds [bin_to_uint [bit_slice $bin 2 2]]
    set last_ready [bin_to_uint [bit_slice $bin 1 1]]
    set last_mmu [bin_to_uint [bit_slice $bin 0 0]]

    puts [format "root_page_writes: seen=%u count=%u newest_flags=%02s newest_micro=%u uds=%u lds=%u ramready=%u mmu_e=%u" \
        $page_seen $page_count $last_flags $last_micro $last_uds $last_lds $last_ready $last_mmu]
    puts [format "srp_slot_000: seen=%u hits=%u data=%04s%04s last_addr=%08s pc=%08s micro=%u" \
        $exact_seen $exact_hits $exact_hi $exact_lo $exact_addr $exact_pc $exact_micro]
    puts [format "srp_slot_0f8: srp_l=%08s slot=%08s seen=%u hits=%u data=%04s%04s last_addr=%08s pc=%08s micro=%u" \
        $srp_l $srp40_addr $fc6_seen $fc6_hits $fc6_hi $fc6_lo $fc6_addr_last $fc6_pc $fc6_micro]
    puts [format "last page writes: 0=%08s:%04s 1=%08s:%04s 2=%08s:%04s 3=%08s:%04s" \
        $last0_addr $last0_data $last1_addr $last1_data $last2_addr $last2_data $last3_addr $last3_data]
}

set clear_cpus 0
foreach arg $::argv {
    switch -- $arg {
        clear { set clear_cpus 1 }
        default {
            error "usage: quartus_stp -t tools/read_mmu_hang_issp.tcl ?clear?"
        }
    }
}

lassign [get_hw] hw_name dev_name
lassign [find_instance $hw_name $dev_name "CPUS"] cpus_idx _ _ _
lassign [find_instance $hw_name $dev_name "PMMU"] pmmu_idx _ _ _
lassign [find_instance $hw_name $dev_name "PMM2"] pmm2_idx _ _ _
lassign [find_instance $hw_name $dev_name "EXCF"] excf_idx _ _ _
lassign [find_instance $hw_name $dev_name "REGS"] regs_idx _ _ _
set tcwr_inst [find_instance_optional $hw_name $dev_name "TCWR"]
set tcwr_idx -1
if {[llength $tcwr_inst] != 0} {
    set tcwr_idx [lindex $tcwr_inst 0]
}
set pmwr_inst [find_instance_optional $hw_name $dev_name "PMWR"]
set pmwr_idx -1
if {[llength $pmwr_inst] != 0} {
    set pmwr_idx [lindex $pmwr_inst 0]
}
set rtwr_inst [find_instance_optional $hw_name $dev_name "RTWR"]
set rtwr_idx -1
if {[llength $rtwr_inst] != 0} {
    set rtwr_idx [lindex $rtwr_inst 0]
}

puts "hardware: $hw_name"
puts "device:   $dev_name"
puts "instances: PMMU=$pmmu_idx PMM2=$pmm2_idx EXCF=$excf_idx CPUS=$cpus_idx REGS=$regs_idx TCWR=$tcwr_idx PMWR=$pmwr_idx RTWR=$rtwr_idx"

start_insystem_source_probe -hardware_name $hw_name -device_name $dev_name
if {$clear_cpus} {
    write_source_data -instance_index $cpus_idx -value 1 -value_in_hex
    after 20
    write_source_data -instance_index $cpus_idx -value 0 -value_in_hex
    after 20
    write_source_data -instance_index $pmm2_idx -value 1 -value_in_hex
    after 20
    write_source_data -instance_index $pmm2_idx -value 0 -value_in_hex
    after 20
    write_source_data -instance_index $excf_idx -value 1 -value_in_hex
    after 20
    write_source_data -instance_index $excf_idx -value 0 -value_in_hex
    after 20
    if {$tcwr_idx >= 0} {
        write_source_data -instance_index $tcwr_idx -value 1 -value_in_hex
        after 20
        write_source_data -instance_index $tcwr_idx -value 0 -value_in_hex
        after 20
    }
    if {$pmwr_idx >= 0} {
        write_source_data -instance_index $pmwr_idx -value 1 -value_in_hex
        after 20
        write_source_data -instance_index $pmwr_idx -value 0 -value_in_hex
        after 20
    }
    if {$rtwr_idx >= 0} {
        write_source_data -instance_index $rtwr_idx -value 1 -value_in_hex
        after 20
        write_source_data -instance_index $rtwr_idx -value 0 -value_in_hex
        after 20
    }
}
set cpus_bin [read_probe_data -instance_index $cpus_idx]
set pmmu_bin [read_probe_data -instance_index $pmmu_idx]
set pmm2_bin [read_probe_data -instance_index $pmm2_idx]
set excf_bin [read_probe_data -instance_index $excf_idx]
set regs_bin [read_probe_data -instance_index $regs_idx]
if {$tcwr_idx >= 0} {
    set tcwr_bin [read_probe_data -instance_index $tcwr_idx]
}
if {$pmwr_idx >= 0} {
    set pmwr_bin [read_probe_data -instance_index $pmwr_idx]
}
if {$rtwr_idx >= 0} {
    set rtwr_bin [read_probe_data -instance_index $rtwr_idx]
}
end_insystem_source_probe

show_cpustate $cpus_bin
show_regs $regs_bin
show_pmmu $pmmu_bin
show_pmm2 $pmm2_bin
show_excf $excf_bin
if {$tcwr_idx >= 0} {
    show_tcwr $tcwr_bin
}
if {$pmwr_idx >= 0} {
    show_pmwr $pmwr_bin
}
if {$rtwr_idx >= 0} {
    show_rtwr $rtwr_bin
}
