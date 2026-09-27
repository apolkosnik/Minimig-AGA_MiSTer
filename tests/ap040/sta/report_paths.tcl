# Detailed paths for every device timing corner from an existing full fit.
# Run from the project root:
# quartus_sta -t tests/ap040/sta/report_paths.tcl <report-directory>
if {[llength $quartus(args)] != 1} {
    error "usage: quartus_sta -t tests/ap040/sta/report_paths.tcl <report-directory>"
}
set outdir [file normalize [lindex $quartus(args) 0]]
file mkdir $outdir
project_open Minimig -revision Minimig
create_timing_netlist
foreach_in_collection op [get_available_operating_conditions -all] {
    set_operating_conditions $op
    read_sdc
    update_timing_netlist
    set corner "[get_operating_conditions_info $op -model]_[get_operating_conditions_info $op -voltage]mV_[get_operating_conditions_info $op -temperature]C"
    report_timing -setup -npaths 40 -detail full_path -file $outdir/${corner}_setup.rpt
    report_timing -hold -npaths 5 -detail full_path -file $outdir/${corner}_hold.rpt
    foreach domain {emu sdram hdmi} {
        if {$domain eq "emu"} {
            set clocks [get_clocks {emu|pll|*}]
        } elseif {$domain eq "sdram"} {
            set clocks [get_clocks {emu|pll|*counter\[0\]*}]
        } else {
            set clocks [get_clocks {*pll_hdmi*}]
        }
        report_timing -setup -to_clock $clocks -npaths 10 -detail full_path -file $outdir/${corner}_${domain}_setup.rpt
    }
    # Keep the repaired paths visible even when another path becomes worst.
    foreach {name from to} {
        fpu_enable {emu|ram1|write_ena} {emu|cpu_wrapper|cpu_inst_p|core|g_fpu.fpu|fstate_et*}
        cache_enable {emu|ram1|write_ena} {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|r_*}
        ram_response_capture {emu|ram1|*} {emu|cpu_wrapper|g_ram_response*}
        ram_response_use {emu|cpu_wrapper|g_ram_response*} {emu|cpu_wrapper|cpu_inst_p|*}
        poly_sum {ascal|o_v_poly_t*} {ascal|o_v_poly_sum*}
        poly_lum {ascal|o_vpix_inner*} {ascal|o_poly_lum*}
        hdmi_output {*d_pipe*} {hdmi_out_d*}
    } {
        set sources [get_registers -nowarn $from]
        set targets [get_registers -nowarn $to]
        if {[get_collection_size $sources] > 0 && [get_collection_size $targets] > 0} {
            report_timing -setup -from $sources -to $targets -npaths 3 -detail full_path -file $outdir/${corner}_${name}.rpt
        }
    }
}
project_close
