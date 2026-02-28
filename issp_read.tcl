# Read PMMU debug state via In-System Sources and Probes (ISSP)
# Usage: quartus_stp -t issp_read.tcl
#
# Probes 167-bit vector:
#   [166:135] = TC[31:0]
#   [134:103] = TT0[31:0]
#   [102:71]  = TT1[31:0]
#   [70:39]   = CRP_HI[31:0]
#   [38:7]    = CRP_LO[31:0]
#   [6:2]     = WSTATE[4:0]
#   [1]       = FAULT
#   [0]       = BUSY

package require ::quartus::stp

set hw_name "DE-SoC \[3-1.3.4\]"
set dev_name "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"

puts "=== PMMU Debug State Readback ==="

# Check for instances
set instances [get_insystem_source_probe_instance_info -hardware_name $hw_name -device_name $dev_name]
puts "ISSP instances: $instances"

start_insystem_source_probe -hardware_name $hw_name -device_name $dev_name

# Read probe data as binary string (MSB first)
set probe_bin [read_probe_data -instance_index 0]
set probe_hex [read_probe_data -instance_index 0 -value_in_hex]
puts ""
puts "Raw probe (hex): $probe_hex"
puts "Raw probe (bin): $probe_bin"
puts ""

# Parse the 167-bit binary string
# MSB is on the left: bit[166] is first character
set len [string length $probe_bin]
puts "Probe width: $len bits"

if {$len >= 167} {
    # Extract fields from MSB-first binary string
    set tc_bin    [string range $probe_bin 0 31]
    set tt0_bin   [string range $probe_bin 32 63]
    set tt1_bin   [string range $probe_bin 64 95]
    set crphi_bin [string range $probe_bin 96 127]
    set crplo_bin [string range $probe_bin 128 159]
    set wstate_bin [string range $probe_bin 160 164]
    set fault_bit [string index $probe_bin 165]
    set busy_bit  [string index $probe_bin 166]

    # Convert binary to hex
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
        scan $binstr %b val
        return $val
    }

    puts "=== PMMU Register State ==="
    puts "  TC       = 0x[bin2hex $tc_bin]  ($tc_bin)"
    puts "  TT0      = 0x[bin2hex $tt0_bin]  ($tt0_bin)"
    puts "  TT1      = 0x[bin2hex $tt1_bin]  ($tt1_bin)"
    puts "  CRP_HI   = 0x[bin2hex $crphi_bin]  ($crphi_bin)"
    puts "  CRP_LO   = 0x[bin2hex $crplo_bin]  ($crplo_bin)"
    puts "  WSTATE   = [bin2dec $wstate_bin]  ($wstate_bin)"
    puts "  FAULT    = $fault_bit"
    puts "  BUSY     = $busy_bit"
    puts ""

    # Decode TC register
    set tc_hex [bin2hex $tc_bin]
    scan $tc_hex %x tc_val
    set tc_e [expr {($tc_val >> 31) & 1}]
    set tc_sre [expr {($tc_val >> 25) & 1}]
    set tc_fcl [expr {($tc_val >> 24) & 1}]
    set tc_ps [expr {($tc_val >> 20) & 0xF}]
    set tc_is [expr {($tc_val >> 16) & 0xF}]
    set tc_tia [expr {($tc_val >> 12) & 0xF}]
    set tc_tib [expr {($tc_val >> 8) & 0xF}]
    set tc_tic [expr {($tc_val >> 4) & 0xF}]
    set tc_tid [expr {$tc_val & 0xF}]
    puts "  TC decode: E=$tc_e SRE=$tc_sre FCL=$tc_fcl PS=$tc_ps IS=$tc_is TIA=$tc_tia TIB=$tc_tib TIC=$tc_tic TID=$tc_tid"

    # Decode walker state
    set wstate_names {W_IDLE W_ROOT W_PTR1 W_PTR2 W_PTR3 W_PAGE W_PROT W_DONE W_WAIT
                      W_FAULT W_WAIT_ROOT W_WAIT_PTR1 W_WAIT_PTR2 W_WAIT_PTR3 W_WAIT_PAGE
                      W_ATC_FILL W_ATC_WAIT W_PTEST_DONE W_PTEST_WAIT W_FAULT_WAIT}
    set wstate_val [bin2dec $wstate_bin]
    if {$wstate_val < [llength $wstate_names]} {
        set wstate_name [lindex $wstate_names $wstate_val]
    } else {
        set wstate_name "UNKNOWN"
    }
    puts "  Walker state: $wstate_name ($wstate_val)"
} else {
    puts "ERROR: Expected 167 bits, got $len"
}

end_insystem_source_probe
puts ""
puts "Done."
