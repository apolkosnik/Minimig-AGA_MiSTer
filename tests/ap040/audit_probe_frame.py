#!/usr/bin/env python3
"""What does a probe-detected write fault report in its format-7 frame?

f86b3980f raises the access error from the MMU probe rather than from the
failed write. The two CAS2 probes are issued before the update operands
have been read out of the register file, so they pass a placeholder of zero
as the write data (ap040_core.v S_CAS2_P1/P2). That placeholder reaches
aer_wd and lands in the frame's WB3D slot, which ap040_core.v documents as
kept "for diagnostics" while WB3S valid stays clear.

This also checks the fix itself: the first CAS2 operand must be UNCHANGED
at handler entry, which is the partial write f86b3980f exists to prevent.

--rtl-dir selects a baseline checkout for comparison.
"""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VASM = os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot")

PROGRAM = """ org 0
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
 move.l #1,($7000).l
 move.l #2,($8000).l
 move.l #$8007,($4420).l
 move.l #$4000,d0
 movec d0,srp
 movec d0,urp
 move.l #$8000,d0
 movec d0,tc
 pflusha
 moveq #1,d0
 moveq #2,d1
 moveq #17,d2
 moveq #34,d3
 lea ($7000).l,a0
 lea ($8000).l,a1
 cas2.l d0:d1,d2:d3,(a0):(a1)
report:
 move.w #$600d,($f102).l
 bra.s *
handler:
 addq.w #1,($3500).l
 move.l 20(sp),($3560).l
 move.l 24(sp),($3564).l
 move.l 28(sp),($3568).l
 move.w 14(sp),($356c).l
 move.w 12(sp),($356e).l
 move.l ($7000).l,($3570).l
 lea ($3400).l,sp
 bra report
"""


def run(command, log):
    with log.open("w") as out:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=out,
                       stderr=subprocess.STDOUT, check=True, timeout=600)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-audit4-frame"))
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
 $display("FRAME fa=%h%h wb3a=%h%h wb3d=%h%h wb3s=%h ssw=%h opA=%h%h faults=%0d", mem[16'h3560>>1], mem[16'h3562>>1], mem[16'h3564>>1], mem[16'h3566>>1], mem[16'h3568>>1], mem[16'h356a>>1], mem[16'h356c>>1], mem[16'h356e>>1], mem[16'h3570>>1], mem[16'h3572>>1], mem[16'h3500>>1]);
""", 1)
    bench_path = work / f"tb_{args.tag}.v"
    bench_path.write_text(bench)

    sources = [HERE / "sim_dpram.v", *sorted(AP.glob("*.v")), ROOT / "rtl/memory_router.v"]
    (work / f"source_sha256_{args.tag}.json").write_text(json.dumps(
        {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, indent=2) + "\n")

    asm, binary, image = [work / f"{args.tag}-cas2{e}" for e in (".s", ".bin", ".hex")]
    asm.write_text(PROGRAM)
    run([VASM, "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm],
        work / f"{args.tag}.assemble.log")
    d = binary.read_bytes()
    image.write_text("".join(d[i:i+2].hex() + "\n" for i in range(0, len(d), 2)))

    obj = work / f"obj-{args.tag}"
    run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
         "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(AP),
         "-GPOST_STORES=1", bench_path, *sources], work / f"compile-{args.tag}.log")
    log = work / f"{args.tag}.log"
    run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
    out = log.read_text()
    s = re.findall(r"FRAME fa=(\w+) wb3a=(\w+) wb3d=(\w+) wb3s=(\w+) ssw=(\w+) opA=(\w+) faults=(\d+)", out)
    assert len(s) == 3 and len(set(s)) == 1, f"phases disagree or missing: {log}"
    fa, wb3a, wb3d, wb3s, ssw, opa, faults = s[0]
    row = dict(tag=args.tag, fa=fa, wb3a=wb3a, wb3d=wb3d, wb3s=wb3s, ssw=ssw,
               opA=opa, faults=int(faults))
    (work / f"results-{args.tag}.json").write_text(json.dumps(row, indent=2) + "\n")
    print(f"{args.tag:9s} fa={fa} wb3a={wb3a} wb3d={wb3d} wb3s={wb3s} ssw={ssw} "
          f"opA={opa} faults={faults}", flush=True)

    bad = []
    if int(faults) != 1:
        bad.append(f"expected exactly one access error, got {faults}")
    if fa != "00008000":
        bad.append(f"fault address {fa}, expected 00008000")
    if opa != "00000001":
        bad.append(f"first CAS2 operand is {opa}: a partial write was committed "
                   f"before the fault (f86b3980f is supposed to prevent this)")
    if wb3d != "00000022":
        bad.append(f"WB3D is {wb3d}, expected 00000022 (the data the faulting "
                   f"write would have stored)")
    if args.expect_defects:
        assert bad == ["WB3D is 00000000, expected 00000022 (the data the faulting "
                       "write would have stored)"], f"matrix changed: {bad}"
        print("\nObserved: the partial write is correctly prevented; only WB3D is wrong.")
    elif bad:
        print("\nFRAME DEFECTS:", flush=True)
        for line in bad:
            print("  " + line, flush=True)
        raise SystemExit(1)
    else:
        print("\nframe gate OK.")


if __name__ == "__main__":
    main()
