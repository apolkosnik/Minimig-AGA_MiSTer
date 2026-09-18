#!/usr/bin/env python3
"""Require multi-write instructions to survive repaired MMU write faults.

Checks memory at handler entry, final data/CCR, fault count and frame metadata,
and preservation of MMUSR/DFC. Runs both cache/posting settings, 4K/8K pages,
and user/supervisor contexts through the real core/MMU/cache/bus bench.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
AP = ROOT / "rtl/ap040"


def run(command, log):
    with log.open("w") as stream:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=stream,
                       stderr=subprocess.STDOUT, check=True, timeout=300)


def checks(values):
    return "\n ".join(f"cmpi.{size} #${value:x},(${addr:x}).l\n bne fail"
                       for size, addr, value in values)


def program(case, fault, page8k, user, cached):
    cas = case.startswith("cas")
    ttr = case == "cas_ttr"
    size = "w" if case == "cas_word" else "l"
    first = 0x6000 if cas else 0x7fff if case in ("add", "moves", "bf2") else 0x7ffc if case == "bf5" else 0x7ffe
    second = first if case == "cas_alias" else 0x01008000 if ttr else 0x7fff if case == "cas_cross" else 0x8000
    mismatch = case == "cas_mismatch"
    if cas:
        initial = [(size, first, 1), (size, second, 2)]
        final = initial if mismatch else [(size, first, 17), (size, second, 34)]
        setup = (f"moveq #{3 if mismatch else 1},d0\n moveq #2,d1\n"
                 f" moveq #17,d2\n moveq #34,d3\n lea (${first:x}).l,a0\n lea (${second:x}).l,a1")
        operation = f"cas2.{size} d0:d1,d2:d3,(a0):(a1)"
        expected_ccr = 9 if mismatch else 4
        if case == "cas_alias":
            initial, final = [(size, first, 1)], [(size, first, 34)]
            setup = setup.replace("moveq #2,d1", "moveq #1,d1")
    elif case == "moves":
        initial, final = [("l", first, 0)], [("l", first, 0x11223344)]
        setup, operation, expected_ccr = "move.l #$11223344,d0", f"moves.l d0,(${first:x}).l", 0
    elif case == "add":
        initial, final = [("l", first, 0)], [("l", first, 0x01000000)]
        setup, operation, expected_ccr = "", f"add.l #$01000000,(${first:x}).l", 0
    else:
        span = int(case[-1])
        initial = [("w" if span < 4 else "l", first, 0)]
        if span in (3, 5):
            initial.append(("b", first + span - 1, 0))
        final = {2: [("w", first, 0xffff)],
                 3: [("w", first, 0xffff), ("b", first + 2, 0xff)],
                 4: [("l", first, 0xffffffff)],
                 5: [("l", first, 0x0fffffff), ("b", first + 4, 0xf0)]}[span]
        setup, expected_ccr = "", 4
        operation = f"bfchg (${first:x}).l{{{4 if span == 5 else 0}:{min(span * 8, 32)}}}"
    pg = 8192 if page8k else 4096
    first_page = first // pg * pg
    # Distinct roots make an accidental DFC-based supervisor probe miss a
    # user-only write protection. Both roots otherwise map the same RAM.
    ptes = 0x4c00 if user else 0x4400
    protected = ([first_page] if fault == "first" else [0x8000] if fault == "last"
                 else [first_page, 0x8000] if fault == "both" else [])
    protection = (f"move.l #${0x0100c004 if fault == 'last' else 0x0200c004:x},d7\n movec d7,dtt0" if ttr else
                  "\n ".join(f"move.l #${p | 7:x},(${ptes + p // pg * 4:x}).l" for p in protected))
    repair = ("moveq #0,d7\n movec d7,dtt0" if ttr else
              "\n ".join(f"move.l #${p | 3:x},(${ptes + p // pg * 4:x}).l" for p in protected))
    # Split first transfers report their original FA/size. A field's
    # independent trailing byte reports its own byte address instead.
    trailing_fault = case in ("bf3", "bf5") and fault in ("last", "both")
    second_fault = cas and fault == "last"
    fa = (first + int(case[-1]) - 1) if trailing_fault else second if second_fault else first
    sz = 0x20 if trailing_fault else 0x40 if case in ("cas_word", "bf2") or (case == "bf3") else 0
    ma = (not cas and not trailing_fault and fault == "last") or (case == "cas_cross" and second_fault)
    ssw = 0x400 | (0x200 if cas else 0) | (0x800 if ma else 0) | sz | (1 if user else 5)
    init = "\n ".join(f"move.{s} #${v:x},(${a:x}).l" for s, a, v in initial)
    dfc = (1 if user else 5) if case == "moves" else (5 if user else 1)
    entry = ("lea ($3c00).l,a6\n move a6,usp\n clr.w -(sp)\n pea exercise(pc)\n"
             " move.w #0,-(sp)\n rte" if user and case != "moves" else "move.w #0,ccr")
    return f""" org 0
 dc.l $3400,start,handler
 rept 29
 dc.l fail
 endr
 dc.l supervisor
 org $400
start:
 clr.w ($3500).l
 lea ($4400).l,a0
 lea ($4c00).l,a1
 moveq #0,d0
 moveq #{65536 // pg - 1},d1
tables:
 move.l d0,d2
 ori.l #3,d2
 move.l d2,(a0)+
 move.l d2,(a1)+
 addi.l #${pg:x},d0
 dbra d1,tables
 move.l #$4203,($4000).l
 move.l #$4403,($4200).l
 move.l #$4a03,($4800).l
 move.l #$4c03,($4a00).l
 {init}
 {protection}
 move.l #$4000,d0
 movec d0,srp
 move.l #$4800,d0
 movec d0,urp
 move.l #${'0' if ttr else 'c000' if page8k else '8000'},d0
 movec d0,tc
 pflusha
 move.l #${'80008000' if cached else '0'},d0
 movec d0,cacr
 moveq #5,d0
 movec d0,dfc
 lea ($6000).l,a0
 ptestr (a0)
 movec mmusr,d5
 moveq #{dfc},d0
 movec d0,dfc
 {setup}
 {entry}
exercise:
 {operation}
 move.w ccr,d4
 {'trap #0' if user and case != 'moves' else 'nop'}
completed:
 cmpi.w #{expected_ccr},d4
 bne fail
 movec mmusr,d6
 cmp.l d5,d6
 bne fail
 movec dfc,d6
 cmpi.l #{dfc},d6
 bne fail
 {checks(final)}
 cmpi.w #{int(bool(protected))},($3500).l
 bne fail
 move.w #$600d,($f102).l
 bra.s *
supervisor:
 ori.w #$2000,(sp)
 rte
handler:
 {checks(initial)}
 cmpi.w #$7008,6(sp)
 bne fail
 cmpi.l #${fa:x},20(sp)
 bne fail
 move.w 12(sp),d7
 andi.w #$0f67,d7
 cmpi.w #${ssw:x},d7
 bne fail
 {repair}
 pflusha
 addq.w #1,($3500).l
 rte
fail:
 move.w #1,($f100).l
 move.w #$bad0,($f102).l
 bra.s *
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-partial-restart"))
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--rtl-dir", type=Path, default=AP, help="RTL source directory (also permits a baseline control)")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    ap = args.rtl_dir.resolve()
    bench = (HERE / "tb_ap040_program.v").read_text()
    # Two TTR regions need different top address bytes. Give only the
    # second operand's cache line an explicit alias into the flat memory model.
    guard = "if (addr_out[31:16] != 0) begin"
    assert bench.count(guard) == 1
    bench = bench.replace(guard, "if (addr_out[31:16] != 0 && !(addr_out[31:16] == 16'h0100 && addr_out[15:4] == 12'h800)) begin")
    bench_path = work / "tb_ap040_program.v"
    bench_path.write_text(bench)
    sources = [*sorted(ap.glob("*.v")), *sorted(ap.glob("*.svh")),
               HERE / "sim_dpram.v", ROOT / "rtl/memory_router.v", bench_path]
    (work / "source_sha256.json").write_text(json.dumps(
        {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, indent=2) + "\n")
    images = []
    for case in ("cas_long", "cas_word", "cas_cross", "cas_mismatch", "cas_alias", "cas_ttr", "add", "moves", "bf2", "bf3", "bf4", "bf5"):
        faults = ("none", "last") if case == "cas_ttr" else ("none", "first") if case == "cas_alias" else ("none", "first", "last", "both")
        for fault in faults:
            for page8k in ((False,) if case == "cas_ttr" else (False, True)):
                for user in (False, True):
                    for cached in (False, True):
                        name = f"{case}-{fault}-pg{8 if page8k else 4}-u{int(user)}-c{int(cached)}"
                        asm, binary, image = [work / (name + ext) for ext in (".s", ".bin", ".hex")]
                        asm.write_text(program(case, fault, page8k, user, cached))
                        run([os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"),
                             "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm], work / (name + ".assemble.log"))
                        data = binary.read_bytes()
                        assert len(data) < 0x3400 and len(data) % 2 == 0
                        image.write_text("".join(data[i:i+2].hex() + "\n" for i in range(0, len(data), 2)))
                        images.append((name, image))
    results = []
    for posted in (False, True):
        obj = work / f"obj-post{int(posted)}"
        run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
             "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(ap),
             f"-GPOST_STORES={int(posted)}", bench_path, HERE / "sim_dpram.v",
             *sorted(ap.glob("*.v")), ROOT / "rtl/memory_router.v"], work / f"compile-post{int(posted)}.log")
        for name, image in images:
            log = work / f"post{int(posted)}-{name}.log"
            run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
            output = log.read_text()
            passed = "ALL TESTS PASSED" in output and not re.search(r"FAIL:|TEST FAILED|%Error", output)
            results.append(dict(name=name, posted=posted, passed=passed, log=str(log)))
            if not passed:
                print(f"FAIL post{int(posted)} {name}: {log}", flush=True)
        (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        rows = [r for r in results if r["posted"] == posted]
        print(f"post{int(posted)}: {sum(r['passed'] for r in rows)}/{len(rows)} cases pass (three phases each)", flush=True)
    if not all(r["passed"] for r in results):
        raise SystemExit("Partial restart regression failed: see results.json")


if __name__ == "__main__":
    main()
