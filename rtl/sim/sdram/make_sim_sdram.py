#!/usr/bin/env python3
# Generate sdram_ctrl_sim.v from the real rtl/sdram_ctrl.v for ModelSim ASE.
# Quartus elaborates module-scope signals order-independently; ModelSim -sv
# requires declaration-before-use.  We hoist exactly the forward-referenced
# declarations to just after the parameter block.  Behavior-identical -- this
# copy is ONLY for the tb_sdram_fwd sim; the real file is never reordered.
#
# Matching is by IDENTIFIER, not by the declaration's bytes.  The first
# version of this script anchored on exact strings including their CRLF
# line endings; sdram_ctrl.v was then reformatted (column-aligned regs) and
# converted to LF, and a third sd_data write site was added for the walker.
# Every anchor went stale and the flow was silently un-runnable until the
# next person tried it.  Each match below still asserts an exact count, so
# the next drift fails HERE, loudly, instead of in vlog.
import os
import re

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "sdram_ctrl.v")
DST = os.path.join(os.path.dirname(__file__), "sdram_ctrl_sim.v")

c = open(SRC, "r", newline="").read()
NL = "\r\n" if "\r\n" in c else "\n"

# --- hoist: the module-scope regs that are used before their declaration ---
HOIST = ["cache_fill", "init_done", "sdram_state", "slot_type",
         "sdata_reg", "chipWE"]
hoisted = []
for ident in HOIST:
    pat = re.compile(r"^[ \t]*reg\b[^;\r\n]*\b" + ident + r"\b[^;\r\n]*;[^\r\n]*" + NL, re.M)
    hits = pat.findall(c)
    assert len(hits) == 1, f"hoist {ident!r}: expected one declaration, found {len(hits)}"
    hoisted.append(hits[0].rstrip("\r\n"))
    c = pat.sub("", c, count=1)

# --- tristate pad -> net driven by an internal reg -------------------------
# ModelSim won't accept procedural assignment to an `inout reg`.  sd_data_o
# sits at Z for our read-only test, so the bench's read pattern always wins.
port = re.compile(r"^([ \t]*)inout[ \t]+reg[ \t]+(\[15:0\][ \t]+sd_data,)", re.M)
assert len(port.findall(c)) == 1, "sd_data port declaration not found exactly once"
c = port.sub(lambda m: m.group(1) + "inout      " + m.group(2), c, count=1)

# every PROCEDURAL write to the pad (LHS only; reads such as
# `sdata_reg <= sd_data` are untouched).  Three today: the reset to Z, the
# walker write, the CPU write.  A fourth means a new write path was added --
# confirm it belongs on the pad and bump the count.
lhs = re.compile(r"^([ \t]*)sd_data([ \t]*)<=", re.M)
n = len(lhs.findall(c))
assert n == 3, f"sd_data procedural writes: expected 3, found {n}"
c = lhs.sub(lambda m: m.group(1) + "sd_data_o" + m.group(2) + "<=", c)
assert not re.search(r"^[ \t]*sd_data[ \t]*<=", c, re.M), "an sd_data write survived"

# --- insert after the parameter block (slot_type's initializer names IDLE) --
term = re.compile(r"^[ \t]*WALKER_WRITE = 5;[^\r\n]*" + NL, re.M)
assert len(term.findall(c)) == 1, "localparam terminator 'WALKER_WRITE = 5;' not found exactly once"
block = (
    "// --- sim-only forward declarations (hoisted for ModelSim -sv) ---" + NL
    + "reg [15:0] sd_data_o = 16'hzzzz;" + NL
    + "assign sd_data = sd_data_o;" + NL
    + NL.join(hoisted) + NL
)
c = term.sub(lambda m: m.group(0) + NL + block, c, count=1)

open(DST, "w", newline="").write(c)
print(f"wrote {os.path.relpath(DST)}: hoisted {len(hoisted)}, sd_data writes {n}, NL={NL!r}")
