#!/bin/bash

echo "Starting build..."
/opt/intelFPGA_lite/17.0/quartus/bin/quartus_sh --flow compile Minimig > build_$(date +%Y%m%d_%H%M%S).log 2>&1

