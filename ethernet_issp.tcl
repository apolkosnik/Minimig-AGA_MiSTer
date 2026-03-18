proc parse_probe_value {raw} {
    set raw [string trim $raw]
    if {$raw eq ""} {
        error "empty probe value"
    }
    if {[string match "0x*" $raw] || [string match "0X*" $raw]} {
        return [expr {$raw}]
    }
    if {[regexp {[A-Fa-f]} $raw]} {
        return [expr {0x$raw}]
    }
    if {[regexp {^[01]+$} $raw] && [string length $raw] > 32} {
        return [expr {0b$raw}]
    }
    return [expr {$raw}]
}

proc bits {value msb {lsb {}}} {
    if {$lsb eq {}} {
        set lsb $msb
    }
    set width [expr {$msb - $lsb + 1}]
    return [expr {($value >> $lsb) & ((1 << $width) - 1)}]
}

proc decode_sticky_flags {sticky} {
    set names {
        {0 local_wait}
        {1 dma_wait}
        {2 sel_overlap}
        {3 reg_write}
        {4 dataport_access}
        {5 dataport_dma_overlap}
        {6 rx_flag_poll}
        {7 shm_sync}
        {8 tx_request}
        {9 irq_seen}
        {10 isr_rdc}
        {11 isr_ovw}
        {12 isr_prx}
        {13 isr_ptx}
        {14 bg_disable}
        {15 dma_timeout}
    }
    set out {}
    foreach entry $names {
        set bit [lindex $entry 0]
        set name [lindex $entry 1]
        if {$sticky & (1 << $bit)} {
            lappend out $name
        }
    }
    if {[llength $out] == 0} {
        return "none"
    }
    return [join $out ","]
}

set bg_disable 0
set do_clear 0
foreach arg $::argv {
    switch -- $arg {
        bg_off { set bg_disable 1 }
        bg_on  { set bg_disable 0 }
        clear  { set do_clear 1 }
        default {
            error "usage: quartus_stp -t ethernet_issp.tcl ?bg_off|bg_on? ?clear?"
        }
    }
}

set hardware_name [lindex [get_hardware_names] 0]
if {$hardware_name eq ""} {
    error "no JTAG hardware found"
}

set device_names [get_device_names -hardware_name $hardware_name]
if {[llength $device_names] == 0} {
    error "no JTAG device found on $hardware_name"
}

set device_name ""
set eth_index -1
set eth_source_width -1
set eth_probe_width -1
foreach candidate_device $device_names {
    if {[catch {start_insystem_source_probe -hardware_name $hardware_name -device_name $candidate_device}]} {
        continue
    }
    if {[catch {get_insystem_source_probe_instance_info -hardware_name $hardware_name -device_name $candidate_device} candidate_insts]} {
        catch {end_insystem_source_probe}
        continue
    }
    foreach inst $candidate_insts {
        set index [lindex $inst 0]
        set source_width [lindex $inst 1]
        set probe_width [lindex $inst 2]
        set name [lindex $inst 3]
        if {[string equal $name "ETHDBG"]} {
            set device_name $candidate_device
            set eth_index $index
            set eth_source_width $source_width
            set eth_probe_width $probe_width
            break
        }
    }
    if {$eth_index >= 0} {
        catch {end_insystem_source_probe}
        break
    }
    catch {end_insystem_source_probe}
}

if {$eth_index < 0} {
    error "ETHDBG ISSP instance not found on any device in $hardware_name"
}

puts "hardware: $hardware_name"
puts "device:   $device_name"
puts "instance: ETHDBG index=$eth_index probe_width=$eth_probe_width source_width=$eth_source_width"

start_insystem_source_probe -hardware_name $hardware_name -device_name $device_name

set source_value [expr {$bg_disable ? 1 : 0}]
if {$do_clear} {
    write_source_data -instance_index $eth_index -value [expr {$source_value | 2}]
    after 50
}
write_source_data -instance_index $eth_index -value $source_value

set raw_probe [read_probe_data -instance_index $eth_index]
end_insystem_source_probe

set probe_value [parse_probe_value $raw_probe]

set remote_dma_addr   [bits $probe_value 127 112]
set remote_byte_count [bits $probe_value 111 96]
set sticky_flags      [bits $probe_value 95 80]
set eth_dma_addr      [bits $probe_value 79 65]
set cpu_word_addr     [bits $probe_value 64 50]
set cpu_byte_addr     [expr {$cpu_word_addr << 1}]
set cr_register       [bits $probe_value 49 42]
set isr_register      [bits $probe_value 41 34]
set imr_register      [bits $probe_value 33 26]
set curr_register     [bits $probe_value 25 18]
set bg_state          [bits $probe_value 17 13]

puts [format "raw:                %s" $raw_probe]
puts [format "remote_dma_addr:    0x%04X" $remote_dma_addr]
puts [format "remote_byte_count:  0x%04X" $remote_byte_count]
puts [format "sticky_flags:       0x%04X (%s)" $sticky_flags [decode_sticky_flags $sticky_flags]]
puts [format "eth_dma_addr:       0x%04X" $eth_dma_addr]
puts [format "cpu_byte_addr:      0x%04X" $cpu_byte_addr]
puts [format "bg_state:           0x%02X" $bg_state]
puts [format "cr/isr/imr/curr:    0x%02X / 0x%02X / 0x%02X / 0x%02X" $cr_register $isr_register $imr_register $curr_register]
puts [format "controls:           bg_disable=%d clear_pulsed=%d" $bg_disable $do_clear]
puts [format "live:               rd=%d wr=%d sel=%d shm=%d data=%d dtack=%d irq=%d dma_req=%d dma_ready=%d dma_wr=%d bg_inflight=%d rd_pend=%d wr_pend=%d" \
    [bits $probe_value 12] \
    [bits $probe_value 11] \
    [bits $probe_value 10] \
    [bits $probe_value 9] \
    [bits $probe_value 8] \
    [bits $probe_value 7] \
    [bits $probe_value 6] \
    [bits $probe_value 5] \
    [bits $probe_value 4] \
    [bits $probe_value 3] \
    [bits $probe_value 2] \
    [bits $probe_value 1] \
    [bits $probe_value 0]]
