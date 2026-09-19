#!/usr/bin/env python3
"""Does the internal write probe set page-descriptor history bits for writes
that never happen?

f86b3980f probes MMU write permission before committing a partial operand.
The probe reuses the PTEST port, and a PTESTW-style search sets U and M in
the page descriptor when the probed write is permitted (ap040_mmu.v
w_hist_m, line 332).  A CAS2 whose comparison FAILS performs no write at
all, so nothing should mark its operand pages modified.

Each case reports both operand page descriptors.  M is bit 4 ($10).
--rtl-dir selects a baseline checkout for the negative control.
"""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

HERE_F = Path(__file__).resolve().parent
ROOT = HERE_F.parents[1]
HERE = HERE_F
VASM = os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot")

# descriptor addresses for pages $7000 and $8000 in the 4K table below
D7, D8 = 0x441C, 0x4420

# cases whose page $8000 is write protected, and which therefore fault
WP = {"cross_fault"}

CASES = {
    # name: (setup, instruction, comment)
    "cross_fault": ("", """
 move.l #$11223344,($7ffe).l""",
     "longword straddling $8000; page 2 is write protected so it faults"),
    "cas2_match": ("""
 moveq #1,d0
 moveq #2,d1
 moveq #17,d2
 moveq #34,d3""", """
 lea ($7000).l,a0
 lea ($8000).l,a1
 cas2.l d0:d1,d2:d3,(a0):(a1)""",
     "compare succeeds: both pages really are written"),
    "cas2_fail": ("""
 moveq #99,d0
 moveq #98,d1
 moveq #17,d2
 moveq #34,d3""", """
 lea ($7000).l,a0
 lea ($8000).l,a1
 cas2.l d0:d1,d2:d3,(a0):(a1)""",
     "compare fails: NO write is performed on either page"),
    "cas1_fail": ("""
 moveq #99,d0
 moveq #17,d2""", """
 lea ($7000).l,a0
 cas.l d0,d2,(a0)""",
     "single CAS, compare fails: not probed, so the control for CAS2"),
    "cas1_match": ("""
 moveq #1,d0
 moveq #17,d2""", """
 lea ($7000).l,a0
 cas.l d0,d2,(a0)""",
     "single CAS, compare succeeds"),
    "read_only": ("", """
 move.l ($7000).l,d0
 move.l ($8000).l,d1""",
     "plain reads: control, M must stay clear"),
}


def program(case):
    setup, instruction, _ = CASES[case]
    wp = "8007" if case in WP else "8003"
    return f""" org 0
 dc.l $3400,start,handler
 org $400
start:
 clr.w ($3500).l
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
 move.l #${wp},($4420).l
 move.l #1,($7000).l
 move.l #2,($8000).l
 move.l #$4000,d0
 movec d0,srp
 movec d0,urp
 move.l #$8000,d0
 movec d0,tc
 pflusha
{setup}
{instruction}
report:
 move.l (${D7:04X}).l,d6
 move.l (${D8:04X}).l,d7
 move.l d6,($3540).l
 move.l d7,($3544).l
 move.l ($7000).l,d4
 move.l ($8000).l,d5
 move.l d4,($3548).l
 move.l d5,($354c).l
 move.w #$600d,($f102).l
 bra.s *
handler:
 addq.w #1,($3500).l
 lea ($3400).l,sp
 bra report
"""


def run(command, log):
    with log.open("w") as out:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=out,
                       stderr=subprocess.STDOUT, check=True, timeout=600)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-audit4-hist"))
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
 $display("HIST desc7=%h%h desc8=%h%h val7=%h%h val8=%h%h faults=%0d", mem[16'h3540>>1], mem[16'h3542>>1], mem[16'h3544>>1], mem[16'h3546>>1], mem[16'h3548>>1], mem[16'h354a>>1], mem[16'h354c>>1], mem[16'h354e>>1], mem[16'h3500>>1]);
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
    for case in CASES:
        asm, binary, image = [work / f"{args.tag}-{case}{e}" for e in (".s", ".bin", ".hex")]
        asm.write_text(program(case))
        run([VASM, "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm],
            work / f"{args.tag}-{case}.assemble.log")
        d = binary.read_bytes()
        image.write_text("".join(d[i:i+2].hex() + "\n" for i in range(0, len(d), 2)))
        log = work / f"{args.tag}-{case}.log"
        run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
        out = log.read_text()
        s = re.findall(r"HIST desc7=(\w+) desc8=(\w+) val7=(\w+) val8=(\w+) faults=(\d+)", out)
        assert len(s) == 3, f"missing handshake-phase result: {log}"
        d7, d8, v7, v8, f = s[0]
        row = dict(tag=args.tag, case=case, desc7=d7, desc8=d8, val7=v7, val8=v8,
                   faults=int(f), m7=bool(int(d7, 16) & 0x10), m8=bool(int(d8, 16) & 0x10),
                   u7=bool(int(d7, 16) & 8), u8=bool(int(d8, 16) & 8),
                   passed="ALL TESTS PASSED" in out)
        assert all(x[:4] == (d7, d8, v7, v8) for x in s), f"phases disagree: {log}"
        results.append(row)
        print(f"{args.tag:9s} {case:12s} desc7={d7} desc8={d8} M={int(row['m7'])}{int(row['m8'])} "
              f"U={int(row['u7'])}{int(row['u8'])} val7={v7} val8={v8} faults={f}", flush=True)
    (work / f"results-{args.tag}.json").write_text(json.dumps(results, indent=2) + "\n")

    # A write that never happens must not mark its page modified.  cas1_*
    # are the controls: single CAS is not probed, so it shows what the
    # probed CAS2 should look like.
    expect_m = {"cas2_match": (True, True), "cas2_fail": (False, False),
                "cas1_fail": (False, False), "cas1_match": (True, False),
                "read_only": (False, False), "cross_fault": (False, False)}
    # cross_fault expected (True, False) while the audit ran, because BOTH
    # versions reached it the wrong way: b3da46b6a by committing the partial
    # write the fix exists to prevent, and f86b3980f by letting the probe set
    # M.  With neither happening, the crossing write that faults on its second
    # page writes nothing at all, so its first page must be clean too -- the
    # same principle every other row here tests.
    bad = [f"{r['case']}: M=({int(r['m7'])},{int(r['m8'])}), expected "
           f"({int(expect_m[r['case']][0])},{int(expect_m[r['case']][1])})"
           for r in results if (r["m7"], r["m8"]) != expect_m[r["case"]]]
    for r in results:
        if r["case"] == "cas2_fail" and (r["val7"], r["val8"]) != ("00000001", "00000002"):
            bad.append("cas2_fail wrote memory; the comparison was supposed to fail")
    if args.expect_defects:
        assert bad == [f"cas2_fail: M=(1,1), expected (0,0)"], \
            f"audit matrix changed; inspect results: {bad}"
        print("\nObserved matrix confirmed: only cas2_fail marks unwritten pages modified.")
    elif bad:
        print("\nHISTORY-BIT DEFECTS:", flush=True)
        for line in bad:
            print("  " + line, flush=True)
        raise SystemExit(1)
    else:
        print("\nhistory-bit gate OK: no page is marked modified without a write.")


if __name__ == "__main__":
    main()
