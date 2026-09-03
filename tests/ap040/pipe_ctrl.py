#!/usr/bin/env python3
"""Summarise tb_ap040_decode's dump: the ground truth for the pipeline's
classifier and control store (AP040_PIPELINE_B0.md section 4).

    pipe_ctrl.py build_vl/decode.txt [--classes out.txt]

Groups the 65,536 opcodes by the DECISION S_DECODE took -- the state it
went to and every operand/execution register it set -- and reports how
many distinct decisions there are (the class count the control store
must hold), how the opcode space splits across them, and the exception
classes.  The classifier of B1 must reproduce exactly this map; this
script is what its equivalence test will compare against.
"""
import sys
from collections import Counter, defaultdict

FIELDS = ["state", "p_src", "p_dst", "p_sreg", "p_dreg", "alu_op", "op_size",
          "exec_kind", "p_rmw", "p_wbsup", "imm_n", "r_imm_ret", "ea_mode",
          "ea_rn", "r_ea_ret", "exc_vec"]

STATE_NAMES = {3: "S_FETCH", 4: "S_DECODE", 5: "S_NEXT", 8: "S_IMMF",
               11: "S_EA_DISP", 20: "S_PIPE_START", 28: "S_EXEC",
               29: "S_SHIFT", 34: "S_EXC0", 51: "S_BCC_EXT", 53: "S_DBCC1",
               55: "S_JMP1", 56: "S_JSR1", 58: "S_LEA1", 59: "S_PEA1",
               61: "S_LINK1", 65: "S_UNLK1", 68: "S_MOVEM_SET",
               74: "S_MOVEP1", 78: "S_EXG1", 80: "S_USP1", 81: "S_MOVEC1",
               83: "S_MOVES1", 87: "S_PTEST1", 89: "S_M16_SRC", 98: "S_SROP",
               100: "S_TRAPCC", 101: "S_STOP_LD", 102: "S_MOVEM_EA",
               104: "S_MDL_EXT", 105: "S_PFLUSH1", 112: "S_BF0", 123: "S_CAS1",
               133: "S_CINV2", 134: "S_CHK2_A", 138: "S_BTSTI", 140: "S_CAS2_0",
               190: "S_PIPE_REGS"}

VEC_NAMES = {4: "illegal", 8: "privilege", 10: "A-line", 11: "F-line",
             5: "divide-by-zero", 6: "CHK", 7: "TRAPcc", 9: "trace"}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    path = sys.argv[1]
    classes_out = None
    if "--classes" in sys.argv:
        classes_out = sys.argv[sys.argv.index("--classes") + 1]

    rows = {}
    missing = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            op = int(parts[0], 16)
            if len(parts) < 2 or parts[1] == "-1":
                missing.append(op)
                continue
            vals = tuple(int(x) for x in parts[1:])
            rows[op] = vals

    # A "decision" is everything but the register NUMBERS, which the
    # classifier derives from the opcode's own fields (d_rn, d_reg9): the
    # control word says WHICH field, not which register.  So p_sreg,
    # p_dreg and ea_rn are folded into "which field of ir they came from".
    def field_src(op, reg):
        d_rn = op & 7
        d_reg9 = (op >> 9) & 7
        an_rn = 8 | d_rn
        an_reg9 = 8 | d_reg9
        if reg == d_rn:
            return "rn"
        if reg == d_reg9:
            return "reg9"
        if reg == an_rn:
            return "An_rn"
        if reg == an_reg9:
            return "An_reg9"
        if reg == 15:
            return "A7"
        if reg == 0:
            return "0"
        return "r%d" % reg

    decisions = Counter()
    members = defaultdict(list)
    for op, v in sorted(rows.items()):
        d = dict(zip(FIELDS, v))
        key = (
            d["state"], d["p_src"], d["p_dst"],
            field_src(op, d["p_sreg"]), field_src(op, d["p_dreg"]),
            d["alu_op"], d["op_size"], d["exec_kind"], d["p_rmw"], d["p_wbsup"],
            d["imm_n"], d["r_imm_ret"], d["ea_mode"] if d["state"] == 11 else -1,
            field_src(op, d["ea_rn"]) if d["state"] == 11 else "-",
            d["r_ea_ret"], d["exc_vec"] if d["state"] == 34 else -1,
        )
        decisions[key] += 1
        members[key].append(op)

    total = len(rows)
    print("opcodes decoded: %d  (missing: %d)" % (total, len(missing)))
    print("distinct decisions, raw: %d" % len(decisions))

    # Folded: what a CONTROL WORD must distinguish.  An exception raised
    # at decode is one class per vector whatever operand registers were
    # left behind; TRAP #n is one class (the vector is ir[3:0]); a branch
    # whose odd target raised the address error at decode is the branch
    # class (the check belongs to EX in the pipeline, where the target
    # is computed); register-number sources that are ambiguous for the
    # opcode at hand (rn == reg9, or a register 0/A7 that could be either
    # a field or a constant) fold to the field.
    def fold(key, op):
        st, vec = key[0], key[15]
        if st == 34:
            if 32 <= vec <= 47:
                return ("EXC", "TRAP")
            if vec == 3:
                return ("EXC", "branch-odd")
            return ("EXC", vec)
        k = list(key)
        for i in (3, 4):
            if k[i] in ("0", "A7"):
                k[i] = "rn" if k[i] == "0" else "A7"
        return tuple(k)

    folded = Counter()
    for key, n in decisions.items():
        folded[fold(key, members[key][0])] += n
    print("distinct decisions, folded (control-store classes): %d" % len(folded))
    big = sum(1 for k, n in folded.items() if n >= 8)
    print("  of which with 8 or more opcodes: %d  (the rest: %d singletons or near)"
          % (big, len(folded) - big))

    by_state = Counter()
    for key, n in decisions.items():
        by_state[key[0]] += n
    print("\nopcode space by first state after decode:")
    for st, n in sorted(by_state.items(), key=lambda kv: -kv[1]):
        print("  %-14s %6d  (%.1f%%)" % (STATE_NAMES.get(st, "state %d" % st), n, 100.0 * n / total))

    exc = Counter()
    for key, n in decisions.items():
        if key[0] == 34:
            exc[key[15]] += n
    if exc:
        print("\nexceptions raised at decode:")
        for vec, n in sorted(exc.items(), key=lambda kv: -kv[1]):
            print("  vector %2d %-14s %6d" % (vec, VEC_NAMES.get(vec, ""), n))

    print("\nlargest classes:")
    for key, n in decisions.most_common(24):
        st = STATE_NAMES.get(key[0], "state %d" % key[0])
        print("  %6d  %-14s src=%d dst=%d sreg=%-7s dreg=%-7s alu=%2d sz=%d ek=%d rmw=%d wbs=%d imm=%d/%d ea=%d/%s/%d vec=%d  e.g. %04x"
              % (n, st, key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8],
                 key[9], key[10], key[11], key[12], key[13], key[14], key[15], members[key][0]))

    # --user <dump>: the same opcodes decoded in user mode.  An opcode that
    # decodes identically in both modes carries no privilege check; one
    # that raises vector 8 in user mode is privileged -- the control
    # word's priv bit -- and its class is the SUPERVISOR decision.
    if "--user" in sys.argv:
        upath = sys.argv[sys.argv.index("--user") + 1]
        urows = {}
        with open(upath) as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[1] != "-1":
                    urows[int(parts[0], 16)] = tuple(int(x) for x in parts[1:])
        priv = []
        differ = []
        for op, v in rows.items():
            u = urows.get(op)
            if u is None:
                continue
            if u == v:
                continue
            ud = dict(zip(FIELDS, u))
            if ud["state"] == 34 and ud["exc_vec"] == 8:
                priv.append(op)
            else:
                differ.append((op, v, u))
        priv_classes = set()
        for op in priv:
            v = rows[op]
            d = dict(zip(FIELDS, v))
            priv_classes.add((d["state"], d["exc_vec"] if d["state"] == 34 else -1))
        print("\nuser-mode pass: %d privileged opcodes (vector 8 in user mode), in %d supervisor-decision states"
              % (len(priv), len(priv_classes)))

        # Every other difference is a field S_DECODE did NOT set for that
        # opcode: in the supervisor pass it holds its reset value, in the
        # user pass whatever the preceding "move.w #0,sr" left behind.
        # Those are the control word's DON'T-CARES.  Rebuild the classes
        # with them masked, and report which fields are don't-care how
        # often -- what the classifier need not produce.
        dc_count = Counter()
        masked = Counter()
        masked_members = defaultdict(list)
        for op, v in sorted(rows.items()):
            u = urows.get(op)
            m = list(v)
            if u is not None and op not in priv:
                for i, name in enumerate(FIELDS):
                    if v[i] != u[i]:
                        m[i] = "x"
                        dc_count[name] += 1
            dm = dict(zip(FIELDS, m))
            st = dm["state"]
            if st == 34:
                vec = dm["exc_vec"]
                key = ("EXC", "TRAP" if isinstance(vec, int) and 32 <= vec <= 47
                       else ("branch-odd" if vec == 3 else vec))
            else:
                def fs(x):
                    return "x" if x == "x" else field_src(op, x)
                key = (st, dm["p_src"], dm["p_dst"], fs(dm["p_sreg"]), fs(dm["p_dreg"]),
                       dm["alu_op"], dm["op_size"], dm["exec_kind"], dm["p_rmw"],
                       dm["p_wbsup"], dm["imm_n"], dm["r_imm_ret"],
                       dm["ea_mode"] if st == 11 else -1,
                       fs(dm["ea_rn"]) if st == 11 else "-",
                       dm["r_ea_ret"], -1)
            if op in priv:
                key = key + ("priv",)
            masked[key] += 1
            masked_members[key].append(op)
        print("distinct decisions with don't-cares masked (both passes): %d" % len(masked))
        big = sum(1 for k, n in masked.items() if n >= 8)
        print("  of which with 8 or more opcodes: %d" % big)
        print("  fields the decode leaves unset (don't-care), opcodes each:")
        for name, n in dc_count.most_common():
            print("    %-10s %6d" % (name, n))
        print("  (masking per opcode splits a class whose members set a field\n"
              "   unevenly; whether that is one class with the field derived from\n"
              "   ir, or two, is the control-word design of B1)")

    if classes_out:
        with open(classes_out, "w") as f:
            f.write("# class  count  state p_src p_dst sreg dreg alu_op op_size exec_kind rmw wbsup imm_n imm_ret ea_mode ea_rn ea_ret exc_vec  first-opcode\n")
            for i, (key, n) in enumerate(sorted(decisions.items(), key=lambda kv: (-kv[1], kv[0]))):
                f.write("%d %d %s %04x\n" % (i, n, " ".join(str(k) for k in key), members[key][0]))
        print("\nclass table written: %s" % classes_out)


if __name__ == "__main__":
    main()
