# sdram_io.tcl -- put numbers on the SDRAM interface, which the project
# constrains nowhere.  Run on a finished fit from the project root:
#
#   SPDIR=<dir> quartus_sta -t tests/ap040/sta/sdram_io.tcl
#
# SDRAM_CLK is not a PLL output: sdram_ctrl drives it from sdram_state[0]
# through an I/O register, so it is a clock forwarded from clk_114 with one
# toggle per cycle (17.616 ns period), and the address and command pins are
# source-synchronous to it.  The setup numbers this prints are NOT absolute
# margin -- the design deliberately centres the data in the SDRAM's window
# and this model does not encode that phase -- but the SPREAD across the
# pins is exact, and that is what matters: every address bit is sampled on
# the same edge, so any bit that arrives materially later than its peers is
# latched stale.  With all thirteen packed into their I/O registers they
# land within 0.5 ns of each other; unpacking A[11] and A[12] put them
# 3.9 ns and 12.7 ns late, which is what this script was written to catch.

project_open Minimig -revision Minimig
create_timing_netlist -model slow
read_sdc
# Model the source-synchronous SDRAM interface that the project never
# constrained: SDRAM_CLK is forwarded from a register on clk_114, one
# toggle per cycle, so its period is two clk_114 cycles.
set src [get_pins -compatibility_mode {*ram1|sd_clk|clk}]
puts "sd_clk clock pin matches: [get_collection_size $src]"
create_generated_clock -name sdram_clk_fwd -source $src -divide_by 2 [get_ports {SDRAM_CLK}]
# IS42S16320D-7 class part: tSU 1.5 ns, tHD 0.8 ns for command/address.
set_output_delay -clock sdram_clk_fwd -max  1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_DQM*}]
set_output_delay -clock sdram_clk_fwd -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_DQM*}]
update_timing_netlist
report_timing -setup -to [get_ports {SDRAM_A[*]}] -npaths 14 -detail summary -file $::env(SPDIR)/sd_io_setup.txt
report_timing -hold  -to [get_ports {SDRAM_A[*]}] -npaths 14 -detail summary -file $::env(SPDIR)/sd_io_hold.txt
project_close
