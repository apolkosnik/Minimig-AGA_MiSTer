#!/usr/bin/env python3
# Assemble the fx68k test programs (tests/*.s) into $readmemh images (tests/*.hex).
# Needs vasmm68k_mot (set VASM to override).
import os, subprocess, sys, glob

here = os.path.dirname(os.path.abspath(__file__))
vasm = os.environ.get('VASM', 'vasmm68k_mot')
files = sys.argv[1:] or sorted(glob.glob(os.path.join(here, 'tests', '*.s')))
for src in files:
    base = os.path.splitext(src)[0]
    subprocess.run([vasm, '-quiet', '-Fbin', '-m68010', '-no-opt', '-o', base + '.bin', src], check=True)
    data = open(base + '.bin', 'rb').read()
    if len(data) & 1:
        data += b'\0'
    with open(base + '.hex', 'w') as f:
        for i in range(0, len(data), 2):
            f.write('%02x%02x\n' % (data[i], data[i + 1]))
    os.remove(base + '.bin')
    print('%s: %d bytes' % (os.path.relpath(base + '.hex', here), len(data)))
