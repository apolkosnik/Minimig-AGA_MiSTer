#!/usr/bin/env python3
"""Do a T0 change-of-flow trace and a simultaneous interrupt nest the same
way a T1 trace does?

This core states one ordering rule (ap040_core.v:1866): an interrupt
sampled at the completing instruction's boundary wins over a simultaneous
trace, and the trace is redelivered at the interrupt handler's entry
through texc_pend.  fetch_next and go_pc's T1 branch both implement it, so
the TRACE handler runs first and the interrupt handler is the outer frame.

go_pc's T0 branch never samples irq_pend.  It parks the trace in
flow_t0_pend and S_FETCH raises it unconditionally; only afterwards does
S_EXC_JMP notice the interrupt and stack it on top.  That nests the two the
other way round.

Each handler bumps a shared sequence counter and records the value it saw,
so the handler that ran first is the one holding 1.  The interrupt is armed
with the bench's delayed level-2 source and swept across the boundary.
"""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VASM = os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot")


def program(t0, delay):
    return f""" org 0
 dc.l $3400,start
 org $24
 dc.l h_trace
 org $68
 dc.l h_int2
 org $400
start:
 move.w #$2700,sr
 clr.w ($3500).l
 clr.w ($3502).l
 clr.w ($3504).l
 clr.w ($3506).l
 move.w #{delay},($f148).l
 lea back(pc),a0
 move.l a0,-(sp)
 move.w #${'6000' if t0 else 'a000'},sr
 rts
back:
 move.w #$2700,sr
 move.w #1000,d0
pause:
 dbra d0,pause
 move.w #$2700,sr
 move.w #$600d,($f102).l
 bra.s *
h_trace:
 addq.w #1,($3506).l
 tst.w ($3502).l
 bne.s ht_done
 move.w ($3506).l,($3502).l
 move.l 2(sp),($3560).l
ht_done:
 andi.w #$3fff,(sp)
 rte
h_int2:
 addq.w #1,($3506).l
 tst.w ($3504).l
 bne.s hi_done
 move.w ($3506).l,($3504).l
 move.l 2(sp),($3570).l
hi_done:
 move.w #0,($f110).l
 rte
"""


def run(command, log):
    with log.open("w") as out:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=out,
                       stderr=subprocess.STDOUT, check=True, timeout=600)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-audit4-order"))
    ap.add_argument("--rtl-dir", type=Path, default=ROOT / "rtl/ap040")
    ap.add_argument("--tag", default="current")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--delays", type=int, nargs="*",
                    default=list(range(40, 105, 4)))
    args = ap.parse_args()
    work = args.work.resolve(); work.mkdir(parents=True, exist_ok=True)
    AP = args.rtl_dir.resolve()

    bench = (HERE / "tb_ap040_program.v").read_text()
    marker = "if (addr_out[15:0] == 16'hF102 && !nuds && !nlds) begin"
    assert bench.count(marker) == 1
    bench = bench.replace(marker, marker + """
 $display("ORDER trace_seq=%0d int2_seq=%0d trace_pc=%h%h int2_pc=%h%h", mem[16'h3502>>1], mem[16'h3504>>1], mem[16'h3560>>1], mem[16'h3562>>1], mem[16'h3570>>1], mem[16'h3572>>1]);
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
    for t0 in (False, True):
        mode = "T0" if t0 else "T1"
        for delay in args.delays:
            name = f"{args.tag}-{mode}-{delay}"
            asm, binary, image = [work / f"{name}{e}" for e in (".s", ".bin", ".hex")]
            asm.write_text(program(t0, delay))
            run([VASM, "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm],
                work / f"{name}.assemble.log")
            d = binary.read_bytes()
            image.write_text("".join(d[i:i+2].hex() + "\n" for i in range(0, len(d), 2)))
            log = work / f"{name}.log"
            run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
            out = log.read_text()
            s = re.findall(r"ORDER trace_seq=(\d+) int2_seq=(\d+) trace_pc=(\w+) int2_pc=(\w+)", out)
            assert len(s) == 3, f"missing phase result: {log}"
            ts, i2, tpc, ipc = s[0]
            results.append(dict(tag=args.tag, mode=mode, delay=delay,
                                trace_seq=int(ts), int2_seq=int(i2),
                                trace_pc=tpc, int2_pc=ipc))
    (work / f"results-{args.tag}.json").write_text(json.dumps(results, indent=2) + "\n")

    # Only the deliveries where BOTH fired are an ordering observation.
    for mode in ("T1", "T0"):
        both = [r for r in results if r["mode"] == mode
                and r["trace_seq"] and r["int2_seq"]]
        first = {("trace" if r["trace_seq"] < r["int2_seq"] else "interrupt")
                 for r in both}
        print(f"{args.tag} {mode}: {len(both)}/{len([r for r in results if r['mode']==mode])} "
              f"delays delivered both; handler that ran first: "
              f"{sorted(first) if first else 'n/a'}", flush=True)
        for r in both[:3]:
            print(f"    delay {r['delay']:4d} trace_seq={r['trace_seq']} "
                  f"int2_seq={r['int2_seq']} trace_pc={r['trace_pc']} "
                  f"int2_pc={r['int2_pc']}", flush=True)


if __name__ == "__main__":
    main()
