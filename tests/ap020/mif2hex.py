#!/usr/bin/env python3
# mif2hex.py in.mif out.hex: a Quartus memory initialisation file (DEPTH,
# hexadecimal radices, single addresses and [a..b] ranges) as $readmemh input
import re, sys
text = open(sys.argv[1]).read()
depth = int(re.search(r'DEPTH\s*=\s*(\d+)', text).group(1))
mem = [0] * depth
body = text[text.index('BEGIN') + 5:text.rindex('END')]
for line in body.split(';'):
    line = line.split('--')[0].strip()
    if not line:
        continue
    addr, val = [x.strip() for x in line.split(':')]
    v = int(val, 16)
    m = re.match(r'\[([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\]', addr)
    lo, hi = (int(m.group(1), 16), int(m.group(2), 16)) if m else (int(addr, 16), int(addr, 16))
    for a in range(lo, hi + 1):
        mem[a] = v
open(sys.argv[2], 'w').write('\n'.join('%x' % v for v in mem) + '\n')
