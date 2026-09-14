#!/usr/bin/env python3
"""Make sdram_ctrl's synthesizable inout-reg idiom legal for simulation.

The original writes 16'hZZZZ into the sd_data register to release the
bus.  A 4-state simulator honours that; Verilator (2-state) cannot -- the
register silently keeps its last value and ORs stale write data onto
every read burst, which once manufactured a convincing but entirely
fictional data-corruption bug.  Emit the canonical enable idiom
instead: both simulators lower `en ? data : 'Z` correctly."""

import sys

source = open(sys.argv[1]).read()
source = source.replace(
    "inout  reg [15:0] sd_data,",
    "inout      [15:0] sd_data,",
)
port_end = source.index(");", source.index("module sdram_ctrl")) + 2
driver = ("\n\nreg [15:0] sd_data_r;\nreg sd_data_en;\n"
          "assign sd_data = sd_data_en ? sd_data_r : 16'hZZZZ;")
source = source[:port_end] + driver + source[port_end:]
# One conditional assignment drives the bus now, so one substitution splits it
# into the enable idiom.  Its two data sources are the walker write's second
# beat and the ordinary write CAS; everything else releases.
old_driver = """		sd_data <= walker_cas2_go            ? walker_wdata_latch[15:0] :
		           (init_done && cas_go && !cas_sd_we) ? datawr
		                                              : 16'hZZZZ;"""
new_driver = """		begin
			sd_data_en <= walker_cas2_go ||
			              (init_done && cas_go && !cas_sd_we);
			sd_data_r  <= walker_cas2_go ? walker_wdata_latch[15:0] : datawr;
		end"""
if old_driver not in source:
    sys.stderr.write("prepare_sdram_sim: sd_data's driver is not the shape "
                     "this script knows how to split; update both together.\n")
    sys.exit(1)
source = source.replace(old_driver, new_driver)
leftovers = [l for l in source.split("\n")
             if "sd_data " in l and "<=" in l
             and "sd_data_r" not in l and "sd_data_en" not in l
             and "sdata_reg" not in l]
if leftovers:
    sys.stderr.write("prepare_sdram_sim: unconverted drivers:\n"
                     + "\n".join(leftovers) + "\n")
    sys.exit(1)
open(sys.argv[2], "w").write(source)
