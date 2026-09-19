#!/usr/bin/env python3
"""Does an aborted bitfield instruction still stack its own flags?

afb93236f deferred an instruction's condition codes into fl_pend so that a
memory write's fault stacks the PRE-instruction CCR, and b3da46b6a made
aerr_start discard the pending flags. Both act on fl_pend.

S_BF_M3 (ap040_core.v:5200) assigns sr[3:0] directly instead, so a bitfield
instruction's flags are architectural before its write is attempted. A
BFCHG whose write faults therefore stacks flags it computed but never
committed, which is the defect those two commits fixed for the ALU and
shift paths.

add.l to the same protected page is the positive control: it goes through
fl_pend and must stack the pre-instruction CCR.
"""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VASM = os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot")

# name: (instruction, initial memory at $8000, flags a SUCCESSFUL run leaves)
CASES = {
    "bfchg": ("bfchg ($8000).l{0:32}", 0x00000000, "Z set from the original field"),
    "bfclr": ("bfclr ($8000).l{0:32}", 0x00000000, "Z set from the original field"),
    "bfset": ("bfset ($8000).l{0:32}", 0x80000000, "N set from the original field"),
    "add":   ("add.l #1,($8000).l",    0xFFFFFFFF, "control: goes through fl_pend"),
}


def program(case, fault):
    instruction, initial, _ = CASES[case]
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
 move.l #${initial:08x},($8000).l
 move.l #${'8007' if fault else '8003'},($4420).l
 move.l #$4000,d0
 movec d0,srp
 movec d0,urp
 move.l #$8000,d0
 movec d0,tc
 pflusha
 move.w #0,ccr
 {instruction}
 move.w ccr,($3552).l
report:
 move.w #$2700,sr
 move.w #$600d,($f102).l
 bra.s *
handler:
 move.w ccr,($3550).l
 addq.w #1,($3500).l
 move.w (sp),($3554).l
 move.l ($8000).l,($3558).l
 lea ($3400).l,sp
 bra report
"""


def run(command, log):
    with log.open("w") as out:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=out,
                       stderr=subprocess.STDOUT, check=True, timeout=600)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-audit4-bffl"))
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
 $display("BFFL handler_ccr=%h nofault_ccr=%h stacked_sr=%h mem=%h%h faults=%0d", mem[16'h3550>>1], mem[16'h3552>>1], mem[16'h3554>>1], mem[16'h3558>>1], mem[16'h355a>>1], mem[16'h3500>>1]);
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
        for fault in (False, True):
            name = f"{args.tag}-{case}-fault{int(fault)}"
            asm, binary, image = [work / f"{name}{e}" for e in (".s", ".bin", ".hex")]
            asm.write_text(program(case, fault))
            run([VASM, "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm],
                work / f"{name}.assemble.log")
            d = binary.read_bytes()
            image.write_text("".join(d[i:i+2].hex() + "\n" for i in range(0, len(d), 2)))
            log = work / f"{name}.log"
            run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
            out = log.read_text()
            s = re.findall(r"BFFL handler_ccr=(\w+) nofault_ccr=(\w+) stacked_sr=(\w+) mem=(\w+) faults=(\d+)", out)
            assert len(s) == 3 and len(set(s)) == 1, f"phases disagree or missing: {log}"
            hc, nc, sr, mem, f = s[0]
            results.append(dict(tag=args.tag, case=case, fault=fault,
                                handler_ccr=hc, nofault_ccr=nc, stacked_sr=sr,
                                mem=mem, faults=int(f)))
            print(f"{args.tag:9s} {case:6s} fault={int(fault)} handler_ccr={hc} "
                  f"nofault_ccr={nc} stacked_sr={sr} mem={mem} faults={f}", flush=True)
    (work / f"results-{args.tag}.json").write_text(json.dumps(results, indent=2) + "\n")

    bad = []
    for r in results:
        if r["faults"] != int(r["fault"]):
            bad.append(f"{r['case']} fault={int(r['fault'])}: fault count {r['faults']}")
        if r["fault"] and int(r["stacked_sr"], 16) & 0x1F:
            bad.append(f"{r['case']}: aborted instruction stacked CCR "
                       f"{int(r['stacked_sr'], 16) & 0x1F:#04x}, expected 0")
    if args.expect_defects:
        assert all("add" not in b for b in bad) and len(bad) == 3, f"matrix changed: {bad}"
        print("\nObserved: all three writing bitfield forms stack their own flags; "
              "the ALU control does not.")
    elif bad:
        print("\nBITFIELD FLAG DEFECTS:", flush=True)
        for line in bad:
            print("  " + line, flush=True)
        raise SystemExit(1)
    else:
        print("\nbitfield-flag gate OK.")


if __name__ == "__main__":
    main()
