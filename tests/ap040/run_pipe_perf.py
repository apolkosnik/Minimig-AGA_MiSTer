#!/usr/bin/env python3
"""Instruction throughput of the pipelined core (restructuring plan, phase 0).

Each case is one block of instructions, repeated 128 times; the bench
(tests/ap040/perf/tb_ap040_pipe_perf.v) measures the 96 steady intervals
between the 16th and the 112th block, on the local behavioural L1 and on the
32-bit bus (membus, zero added waits unless --wait says otherwise).

A case fails -- and the run exits non-zero -- if its image is missing or
does not assemble, if the bench did not see all 97 block boundaries, if any
exception was taken, or if fewer or more instructions retired in the window
than 96 blocks hold. With --baseline, every case is compared against a
stored result, and --check also fails on a case that got slower -- or
that had fewer of its instructions' addresses formed by EA-calculate (the
agu count): EA-fetch still forms any it is not given, correctly, so a
classification that loses an instruction shows nowhere else.

  python3 tests/ap040/run_pipe_perf.py --work /home/adam/ap040-audit4/perf
  python3 tests/ap040/run_pipe_perf.py --work W --baseline tests/ap040/perf/baseline.json --check
  python3 tests/ap040/run_pipe_perf.py --work W --write-baseline tests/ap040/perf/baseline.json
"""
import argparse, json, os, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
RTL = ROOT / "rtl/ap040_pipe"
VASM = Path(os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"))
BENCH = HERE / "perf/tb_ap040_pipe_perf.v"
CORE = [RTL / n for n in (
    "ap040_pipe_core.v", "ap040_pipe_cpu.v", "ap040_pipe_sys.v",
    "ap040_pipe_membus.v", "ap040_inst_fetch.v", "ap040_decode.v",
    "ap040_ea_calc.v", "ap040_ea_fetch.v", "ap040_execute.v",
    "ap040_writeback.v", "ap040_pipe_alu.v", "ap040_pipe_regfile.v",
    "ap040_pipe_l1.v", "ap040_pipe_fpu.v", "ap040_pipe_irq.v")] + [ROOT / "rtl/ap040/ap040_fpu.v"]

# (name, block). Registers at the start: D1 27, D2 3, D3 8, A0 $1000,
# A1 $1800, A4 $1800, A5 $2000. The review's 60 primary sequences, its
# dependency probes, and the plan's phase-1/2 cases.
CASES = [
    ("nop", "nop"), ("add_reg", "add.l d2,d1"), ("move_imm", "move.l #$12345678,d1"),
    ("lea_disp", "lea 4(a0),a1"), ("lea_index", "lea 0(a0,d4.l),a1"),
    ("load", "move.l (a0),d1"), ("load_postinc", "move.l (a0)+,d1"), ("store", "move.l d1,(a0)"),
    ("alu_load", "add.l (a0),d1"), ("rmw_add", "add.l d2,(a0)"), ("rmw_add_alu", "add.l d2,(a0)\n add.l d2,d1"),
    ("move_mem_mem", "move.l (a0),(a1)"), ("cmpm", "cmpm.l (a0)+,(a1)+"), ("addx_mem", "addx.l -(a4),-(a5)"),
    ("exg", "exg d0,d4"), ("shift_imm", "lsl.l #3,d1"), ("shift_reg", "lsl.l d2,d1"),
    ("mul_word", "mulu.w d2,d1"), ("mul_long", "mulu.l d2,d1"), ("div_word", "divu.w d2,d1"), ("div_long", "divu.l d2,d1"),
    ("mul_independent", "mulu.l d2,d1\n add.l d3,d4"), ("div_independent", "divu.l d2,d1\n add.l d3,d4"),
    ("movem_load2", "movem.l (a0),d0-d1"), ("movem_load8", "movem.l (a0),d0-d7"),
    ("movem_store2", "movem.l d0-d1,(a0)"), ("movem_store8", "movem.l d0-d7,(a0)"),
    ("movep_load", "movep.l 0(a0),d1"), ("movep_store", "movep.l d1,0(a0)"), ("move16", "move16 (a0)+,(a1)+"),
    ("cmp2", "cmp2.l (a0),d0"), ("chk2", "chk2.l (a0),d0"), ("chk_pass", "chk.w d2,d4"), ("trapcc_false", "trapmi"),
    ("cas", "cas.l d0,d4,(a0)"), ("cas2", "cas2.l d0:d4,d5:d6,(a0):(a1)"),
    ("fmove_reg", "fmove.x fp0,fp1"), ("fadd_reg", "fadd.x fp0,fp1"), ("fmove_load", "fmove.l (a0),fp1"),
    ("fmove_store", "fmove.l fp0,(a0)"), ("fmove_alu", "fmove.x fp0,fp1\n add.l d2,d1"),
    ("fmovem_load", "fmovem.x (a0),fp0-fp1"), ("fmovem_store", "fmovem.x fp0-fp1,(a0)"),
]
for _op in ["bftst", "bfextu", "bfexts", "bfffo", "bfchg", "bfclr", "bfset", "bfins"]:
    for _m in ["reg", "mem"]:
        _o = "d2{0:8}" if _m == "reg" else "(a0){0:8}"
        CASES.append((_op + "_" + _m, _op + " " + ("d1," + _o if _op == "bfins" else
                                                  _o + ",d1" if _op in ("bfextu", "bfexts", "bfffo") else _o)))
CASES += [
    ("bfextu_dynamic", "bfextu d2{d4:d3},d1"),
    # dependency probes
    ("load_alternate", "move.l (a0),d1\n move.l (a0),d3"),
    ("load_alu_independent", "move.l (a0),d1\n add.l d3,d4"),
    ("data_to_store", "add.l d2,d1\n move.l d1,(a0)"),
    ("address_to_store", "addq.l #4,a0\n move.l d1,(a0)"),
    ("address_to_load", "adda.l d4,a0\n move.l (a0),d1"),
    ("mul_four_alu", "mulu.l d2,d1\n add.l d3,d4\n add.l d3,d5\n add.l d3,d6\n add.l d3,d7"),
    ("div_four_alu", "divu.l d2,d1\n add.l d3,d4\n add.l d3,d5\n add.l d3,d6\n add.l d3,d7"),
    ("movec_vbr", "movec vbr,d1"),
    ("chk_alternate", "chk.w d2,d4\n chk.w d2,d5"),
    # write-only candidates (phase 2)
    ("clr_mem", "clr.l (a0)"), ("st_mem", "st (a0)"), ("clr_reg", "clr.l d1"),
    ("clr_disp", "clr.l 4(a0)"), ("clr_postinc", "clr.w (a0)+"), ("clr_abs", "clr.l ($1000).l"),
    ("scc_disp", "seq 4(a0)"), ("move_imm_mem", "move.l #$12345678,(a0)"),
]


def assemble(name, block, work):
    s = work / (name + ".s")
    b = work / (name + ".bin")
    s.write_text(" " + block + "\n")
    r = subprocess.run([str(VASM), "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", str(b), str(s)],
                       capture_output=True, text=True)
    if r.returncode or not b.exists():
        return None, "assembly failed: " + r.stdout + r.stderr
    data = b.read_bytes()
    words = [data[i:i + 2].hex() for i in range(0, len(data), 2)]
    (work / (name + ".hex")).write_text("\n".join(words * 128 + ["60fe"]) + "\n")
    return words, None


def build(work, bus, jobs):
    obj = work / ("obj-" + ("bus" if bus else "local"))
    log = work / ("build-" + ("bus" if bus else "local") + ".log")
    cmd = ["verilator", "--binary", "--timing", "--top-module", "tb_ap040_pipe_perf", "--Mdir", str(obj),
           "-j", str(jobs), "-Wno-fatal", "-I" + str(RTL), "-I" + str(ROOT / "rtl/ap040")]
    cmd += (["-DAP040_PERF_BUS"] if bus else []) + [str(BENCH)] + [str(x) for x in CORE]
    with log.open("w") as f:
        rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=dict(os.environ, TMPDIR=str(work))).returncode
    if rc:
        sys.exit("build failed, see %s" % log)
    return obj / "Vtb_ap040_pipe_perf"


def measure(binary, name, words, instructions, work, wait):
    r = subprocess.run([str(binary), "+prog=" + str(work / (name + ".hex")), "+stride=%d" % len(words),
                        "+wait=%d" % wait], capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    row = {}
    for line in out.splitlines():
        if line.startswith(("RESULT", "COUNT", "STALL")):
            row[line.split()[0].lower()] = {k: int(v) for k, v in (x.split("=") for x in line.split()[1:])}
        elif line.startswith("EXC "):
            row["exceptions"] = int(line.split()[1])
    errs = []
    if r.returncode or "result" not in row:
        errs.append("no measurement: " + " | ".join(l for l in out.splitlines() if "FAIL" in l or "fatal" in l.lower())[:300])
    if row.get("exceptions", 1) != 0:
        errs.append("%s exception(s) taken" % row.get("exceptions", "?"))
    if "count" in row and row["count"]["retired"] != 96 * instructions:
        errs.append("%d instructions retired in the window, want %d" % (row["count"]["retired"], 96 * instructions))
    if errs:
        return {"error": "; ".join(errs)}
    cyc = row["result"]["cycles"]
    return {"cycles_per_block": cyc / 96.0, "cpi": cyc / 96.0 / instructions,
            "counts": row["count"], "stalls": row["stall"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--jobs", type=int, default=12)
    ap.add_argument("--wait", type=int, default=0, help="bus wait states before each acknowledge")
    ap.add_argument("--only", help="comma-separated case names")
    ap.add_argument("--baseline", type=Path)
    ap.add_argument("--check", action="store_true", help="fail on any case slower than --baseline")
    ap.add_argument("--write-baseline", type=Path)
    args = ap.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    cases = [c for c in CASES if not args.only or c[0] in args.only.split(",")]
    local = build(args.work, False, args.jobs)
    bus = build(args.work, True, args.jobs)
    rows, bad = [], 0
    for name, block in cases:
        instructions = len(block.splitlines())
        words, err = assemble(name, block, args.work)
        row = {"name": name, "block": block, "instructions": instructions}
        if err:
            row["error"] = err
        else:
            row["words"] = len(words)
            row["local"] = measure(local, name, words, instructions, args.work, 0)
            row["bus"] = measure(bus, name, words, instructions, args.work, args.wait)
        rows.append(row)
        errs = [row.get("error")] + [row.get(m, {}).get("error") for m in ("local", "bus")]
        errs = [e for e in errs if e]
        bad += bool(errs)
        print("%-22s %s" % (name, "FAIL " + "; ".join(errs) if errs else
                            "local %5.2f  bus %5.2f  cycles/block" % (row["local"]["cycles_per_block"],
                                                                       row["bus"]["cycles_per_block"])), flush=True)
    result = {"wait": args.wait, "rtl": subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                                                       capture_output=True, text=True).stdout.strip(),
              "dirty": bool(subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--", "rtl"],
                                           capture_output=True, text=True).stdout.strip()),
              "cases": rows}
    (args.work / "results.json").write_text(json.dumps(result, indent=1))
    worse = 0
    if args.baseline:
        base = {r["name"]: r for r in json.loads(args.baseline.read_text())["cases"]}
        print("\n%-22s %13s %13s" % ("vs baseline", "local", "bus"))
        for row in rows:
            b = base.get(row["name"])
            if not b or "error" in row or any("error" in row.get(m, {}) or "error" in b.get(m, {}) for m in ("local", "bus")):
                continue
            d = [row[m]["cycles_per_block"] - b[m]["cycles_per_block"] for m in ("local", "bus")]
            lost = [m for m in ("local", "bus") if row[m]["counts"].get("agu", 0) < b[m]["counts"].get("agu", 0)]
            if any(abs(x) > 1e-9 for x in d) or lost:
                print("%-22s %+13.2f %+13.2f%s" % (row["name"], d[0], d[1],
                      "  fewer addresses from EA-calculate: " + ", ".join(lost) if lost else ""))
            worse += any(x > 1e-9 for x in d) or bool(lost)
    print("\n%d cases, %d failed%s" % (len(rows), bad, (", %d slower than the baseline or losing addresses" % worse) if args.baseline else ""))
    # After the comparison: --baseline and --write-baseline are usually the
    # same file, and writing first compared the run with itself.
    if args.write_baseline:
        args.write_baseline.write_text(json.dumps(result, indent=1) + "\n")
    sys.exit(1 if bad or (args.check and worse) else 0)


if __name__ == "__main__":
    main()
