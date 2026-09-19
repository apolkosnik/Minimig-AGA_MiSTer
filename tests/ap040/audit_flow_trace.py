#!/usr/bin/env python3
"""Does an access error leave a T0 change-of-flow trace pending?

A taken branch under T0 does not raise its trace immediately: go_pc parks
it in flow_t0_pend and S_FETCH raises it once the target word arrives.
Every exception that runs through the e_go carrier clears flow_t0_pend
(ap040_core.v:6537), because, as the comment at ap040_core.v:2296 puts it,
no exception leaves a T0 trace pending on the 040.

aerr_start does not run through e_go. It clears fl_pend but not
flow_t0_pend, so a fault on the branch TARGET's own instruction fetch
carries the pending trace through exception entry, and S_FETCH then raises
vector 9 in place of the fault handler's first instruction.

Cases:
  t0_fault     T0 on, branch target page not resident  -- the defect
  t0_resident  T0 on, target resident                  -- ordinary T0 trace
  not0_fault   T0 off, target page not resident        -- ordinary fault
"""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VASM = os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot")

CASES = {"t0_fault": (True, False), "t0_resident": (True, True),
         "not0_fault": (False, False)}


def program(t0, resident):
    return f""" org 0
 dc.l $3400,start
 dc.l h_aerr
 org $24
 dc.l h_trace
 org $400
start:
 move.w #$2700,sr
 clr.w ($3500).l
 clr.w ($3502).l
 lea ($4400).l,a0
 moveq #0,d0
 moveq #15,d1
tables:
 move.l d0,d2
 lsl.l #8,d2
 lsl.l #4,d2
 addq.l #3,d2
 move.l d2,(a0)+
 addq.l #1,d0
 dbra d1,tables
 move.l #$4203,($4000).l
 move.l #$4403,($4200).l
 {'move.l #$5003,($4414).l' if resident else 'clr.l ($4414).l'}
 move.l #$4000,d0
 movec d0,srp
 movec d0,urp
 move.l #$8000,d0
 movec d0,tc
 pflusha
 move.w #${'6000' if t0 else '2000'},sr
 bra target
report:
 move.w #$2700,sr
 move.w ($3500).l,d0
 move.w ($3502).l,d1
 move.w #$600d,($f102).l
 bra.s *
h_aerr:
 addq.w #1,($3500).l
 move.l 2(sp),($3550).l
 lea ($3400).l,sp
 bra report
h_trace:
 addq.w #1,($3502).l
 move.l 2(sp),($3560).l
 move.l 8(sp),($3564).l
 lea ($3400).l,sp
 bra report
 org $5000
target:
 nop
 bra report
"""


def run(command, log):
    with log.open("w") as out:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=out,
                       stderr=subprocess.STDOUT, check=True, timeout=600)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-audit4-flowtrace"))
    ap.add_argument("--rtl-dir", type=Path, default=ROOT / "rtl/ap040")
    ap.add_argument("--tag", default="current")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--expect-defects", action="store_true")
    args = ap.parse_args()
    work = args.work.resolve(); work.mkdir(parents=True, exist_ok=True)
    AP = args.rtl_dir.resolve()

    bench = (HERE / "tb_ap040_program.v").read_text()
    marker = "if (addr_out[15:0] == 16'hF102 && !nuds && !nlds) begin"
    assert bench.count(marker) == 1
    bench = bench.replace(marker, marker + """
 $display("FLOW aerr=%0d trace=%0d aerr_pc=%h%h trace_pc=%h%h trace_addr=%h%h", mem[16'h3500>>1], mem[16'h3502>>1], mem[16'h3550>>1], mem[16'h3552>>1], mem[16'h3560>>1], mem[16'h3562>>1], mem[16'h3564>>1], mem[16'h3566>>1]);
""", 1)
    bench_path = work / f"tb_{args.tag}.v"
    bench_path.write_text(bench)
    sources = [HERE / "sim_dpram.v", *sorted(AP.glob("*.v")), ROOT / "rtl/memory_router.v"]
    (work / f"source_sha256_{args.tag}.json").write_text(json.dumps(
        {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, indent=2) + "\n")

    obj = work / f"obj-{args.tag}"
    run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
         "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(AP),
         "-GPOST_STORES=1", bench_path, *sources], work / f"compile-{args.tag}.log")

    results = []
    for case, (t0, resident) in CASES.items():
        asm, binary, image = [work / f"{args.tag}-{case}{e}" for e in (".s", ".bin", ".hex")]
        asm.write_text(program(t0, resident))
        run([VASM, "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm],
            work / f"{args.tag}-{case}.assemble.log")
        d = binary.read_bytes()
        image.write_text("".join(d[i:i+2].hex() + "\n" for i in range(0, len(d), 2)))
        log = work / f"{args.tag}-{case}.log"
        run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
        out = log.read_text()
        s = re.findall(r"FLOW aerr=(\d+) trace=(\d+) aerr_pc=(\w+) trace_pc=(\w+) trace_addr=(\w+)", out)
        assert len(s) == 3 and len(set(s)) == 1, f"phases disagree or missing: {log}"
        a, t, apc, tpc, tad = s[0]
        row = dict(tag=args.tag, case=case, aerr=int(a), trace=int(t),
                   aerr_pc=apc, trace_pc=tpc, trace_addr=tad)
        results.append(row)
        print(f"{args.tag:9s} {case:12s} aerr={a} trace={t} aerr_pc={apc} "
              f"trace_pc={tpc} trace_addr={tad}", flush=True)
    (work / f"results-{args.tag}.json").write_text(json.dumps(results, indent=2) + "\n")

    by = {r["case"]: r for r in results}
    bad = []
    if (by["not0_fault"]["aerr"], by["not0_fault"]["trace"]) != (1, 0):
        bad.append("not0_fault: the plain fault control did not take exactly one access error")
    if (by["t0_resident"]["aerr"], by["t0_resident"]["trace"]) != (0, 1):
        bad.append("t0_resident: an ordinary T0 branch trace did not fire")
    if by["t0_resident"]["trace_pc"] != "00005000":
        bad.append(f"t0_resident: trace stacked PC {by['t0_resident']['trace_pc']}, expected the branch target 00005000")
    if (by["t0_fault"]["aerr"], by["t0_fault"]["trace"]) != (1, 0):
        bad.append(f"t0_fault: aerr={by['t0_fault']['aerr']} trace={by['t0_fault']['trace']}, "
                   f"expected exactly one access error and NO trace; the fault "
                   f"handler must run its own first instruction "
                   f"(trace stacked PC was {by['t0_fault']['trace_pc']})")
    if args.expect_defects:
        assert len(bad) == 1 and bad[0].startswith("t0_fault:"), f"matrix changed: {bad}"
        print("\nObserved: the access error leaves the T0 trace pending and vector 9 "
              "preempts the handler's first instruction.")
    elif bad:
        print("\nFLOW-TRACE DEFECTS:", flush=True)
        for line in bad:
            print("  " + line, flush=True)
        raise SystemExit(1)
    else:
        print("\nflow-trace gate OK.")


if __name__ == "__main__":
    main()
