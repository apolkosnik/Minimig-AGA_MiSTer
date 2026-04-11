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
    puts [format "       desc_addr=%08s desc_data=%08s fc=%s(%u) ipl=%u setendOPC=%u stop=%u cpu_bus_berr=%u" \
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
    set fault_latched [bin_to_uint [bit_slice $bin 193 193]]
    set timeout_latched [bin_to_uint [bit_slice $bin 192 192]]
    set walkcap_latched [bin_to_uint [bit_slice $bin 191 191]]
    set walkcap_phase_high [bin_to_uint [bit_slice $bin 190 190]]
    set walkcap_write [bin_to_uint [bit_slice $bin 189 189]]
    set walkcap_addr_word [bin_to_hex [bit_slice $bin 188 157]]
    set walkcap_cpu_din [bin_to_hex [bit_slice $bin 156 141]]
    set walkcap_pmmu_addr [bin_to_hex [bit_slice $bin 140 109]]
    set walkcap_cpu_addr [bin_to_hex [bit_slice $bin 108 77]]
    set walkcap_phys_addr [bin_to_hex [bit_slice $bin 76 45]]
    set walkcap_flags [bit_slice $bin 44 32]
    set walkcap_chip_stage [bin_to_uint [bit_slice $bin 31 30]]
    set walkcap_cpustate [bin_to_uint [bit_slice $bin 29 28]]
    set walkcap_ramaddr [bin_to_hex [bit_slice $bin 27 0]]

    puts [format "fault_latched=%u timeout=%u walkcap=%u phase_high=%u write=%u" \
        $fault_latched $timeout_latched $walkcap_latched $walkcap_phase_high $walkcap_write]
    puts [format "walk: addr_word=%08s pmmu_addr=%08s cpu_addr=%08s phys_addr=%08s cpu_din=%04s" \
        $walkcap_addr_word $walkcap_pmmu_addr $walkcap_cpu_addr $walkcap_phys_addr $walkcap_cpu_din]
    puts [format {      cpustate=%s(%u) chip_stage=%u ramaddr[28:1]=%07s} \
        [decode_cpustate $walkcap_cpustate] $walkcap_cpustate $walkcap_chip_stage $walkcap_ramaddr]
    puts [format "      flags: req=%u active=%u fast=%u chip=%u dfill=%u ifill=%u fill_active=%u cache_ack=%u cache_req=%u ramready=%u chipready=%u fastsel=%u ramsel=%u" \
        [bin_to_uint [string index $walkcap_flags 0]] \
        [bin_to_uint [string index $walkcap_flags 1]] \
        [bin_to_uint [string index $walkcap_flags 2]] \
        [bin_to_uint [string index $walkcap_flags 3]] \
        [bin_to_uint [string index $walkcap_flags 4]] \
        [bin_to_uint [string index $walkcap_flags 5]] \
        [bin_to_uint [string index $walkcap_flags 6]] \
        [bin_to_uint [string index $walkcap_flags 7]] \
        [bin_to_uint [string index $walkcap_flags 8]] \
        [bin_to_uint [string index $walkcap_flags 9]] \
        [bin_to_uint [string index $walkcap_flags 10]] \
        [bin_to_uint [string index $walkcap_flags 11]] \
        [bin_to_uint [string index $walkcap_flags 12]]]
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

puts "hardware: $hw_name"
puts "device:   $dev_name"
puts "instances: PMMU=$pmmu_idx PMM2=$pmm2_idx EXCF=$excf_idx CPUS=$cpus_idx REGS=$regs_idx"

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
}
set cpus_bin [read_probe_data -instance_index $cpus_idx]
set pmmu_bin [read_probe_data -instance_index $pmmu_idx]
set pmm2_bin [read_probe_data -instance_index $pmm2_idx]
set excf_bin [read_probe_data -instance_index $excf_idx]
set regs_bin [read_probe_data -instance_index $regs_idx]
end_insystem_source_probe

show_cpustate $cpus_bin
show_regs $regs_bin
show_pmmu $pmmu_bin
show_pmm2 $pmm2_bin
show_excf $excf_bin
