#!/usr/bin/env python3
# Generate an iverilog-compatible copy of a Verilog file whose top-level
# declarations appear after first use (legal for synthesis, rejected by
# iverilog): hoist every column-0 wire/reg declaration to just after the
# port list, turning initialized declarations into plain assigns.
import re, sys
src = open(sys.argv[1]).read()
lines = src.split("\n")
port_end = next(i for i, l in enumerate(lines) if l.strip() == ");")
decls, out = [], []
for i, l in enumerate(lines):
    if i <= port_end:
        out.append(l)
        continue
    m = re.match(r"^(wire|reg)\b([^;=]*?)\s*=\s*(.+?);\s*(//.*)?$", l)
    if m and not l.startswith(("\t", " ")):
        kind, head, expr, cmt = m.groups()
        name = head.strip().split()[-1]
        # A reg initializer is a power-up value, not a driver: the same reg
        # is usually assigned in an always block, and turning it into a
        # continuous assign makes iverilog reject every procedural write to
        # it.  Hoist those verbatim; only wires carry a real driver here.
        if kind == "reg":
            decls.append(re.sub(r"\s*//.*$", "", l))
            out.append("// hoisted: " + l)
        else:
            decls.append("%s%s;" % (kind, head.rstrip()))
            out.append("assign %s = %s; %s" % (name, expr, cmt or ""))
    elif re.match(r"^(wire|reg)\b[^=]*;\s*(//.*)?$", l) and not l.startswith(("\t", " ")):
        decls.append(re.sub(r"\s*//.*$", "", l))
        out.append("// hoisted: " + l)
    elif re.match(r"^always\s+begin\s*(//.*)?$", l):
        # "always begin" with no sensitivity list: Quartus infers a
        # combinational process, iverilog sees a zero-delay infinite loop.
        # always @(*) is what the synthesizer builds anyway.
        out.append(re.sub(r"^always\s+begin", "always @(*) begin", l))
    else:
        out.append(l)
body = out[:port_end+1] + ["", "// --- declarations hoisted for iverilog ---"] + decls + [""] + out[port_end+1:]
open(sys.argv[2], "w").write("\n".join(body))
