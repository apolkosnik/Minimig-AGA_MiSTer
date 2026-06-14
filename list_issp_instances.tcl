set hardware_names [get_hardware_names]
if {[llength $hardware_names] == 0} {
    error "no JTAG hardware found"
}

foreach hardware_name $hardware_names {
    puts "hardware: $hardware_name"
    set device_names [get_device_names -hardware_name $hardware_name]
    if {[llength $device_names] == 0} {
        puts "  no devices"
        continue
    }

    foreach device_name $device_names {
        puts "  device: $device_name"
        if {[catch {get_insystem_source_probe_instance_info -hardware_name $hardware_name -device_name $device_name} insts err]} {
            puts "    get_insystem_source_probe_instance_info failed: $err"
            continue
        }

        if {[llength $insts] == 0} {
            puts "    no source/probe instances"
            continue
        }

        if {[catch {start_insystem_source_probe -hardware_name $hardware_name -device_name $device_name} err]} {
            puts "    start_insystem_source_probe failed: $err"
            continue
        }

        if {[llength $insts] != 0} {
            foreach inst $insts {
                puts "    instance: $inst"
            }
        }

        catch {end_insystem_source_probe}
    }
}
