#!/usr/bin/env python3
"""Make sdram_ctrl's synthesizable inout-reg idiom legal for Icarus."""

import sys

source = open(sys.argv[1]).read()
source = source.replace(
    "inout  reg [15:0] sd_data,",
    "inout      [15:0] sd_data,",
)
port_end = source.index(");", source.index("module sdram_ctrl")) + 2
driver = "\n\nreg [15:0] sd_data_r;\nassign sd_data = sd_data_r;"
source = source[:port_end] + driver + source[port_end:]
source = source.replace("sd_data               <=", "sd_data_r             <=")
source = source.replace("sd_data      <=", "sd_data_r    <=")
source = source.replace("sd_data <=", "sd_data_r <=")
open(sys.argv[2], "w").write(source)
