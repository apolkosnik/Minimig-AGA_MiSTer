# The 40 worst setup paths, in full, for the plan's per-milestone path
# classification. run.sh runs this after the fit; it is kept here rather
# than typed out each time because it has been lost with a workdir twice.
project_open pipe -revision pipe
create_timing_netlist -model slow
read_sdc pipe.sdc
update_timing_netlist
report_timing -setup -npaths 40 -detail full_path -file paths40.txt
project_close
