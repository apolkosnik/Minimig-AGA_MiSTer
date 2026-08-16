#!/usr/bin/env python3
"""Run the WinUAE 68040 cputest v20 corpus against AP040 RTL.

Examples:
  # Fast representative gate (integer, FPU, IRQ, trace, AE, odd vectors)
  ./run_cputest.py /path/to/data040.zip

  # Every one of the 1,911 data slices; split safely across four machines
  ./run_cputest.py /path/to/data040.zip --full --shard 0/4 --jobs 2

  # Cross-check a result under Icarus (the default backend is Verilator,
  # which is ~26x faster over the full corpus for identical results)
  ./run_cputest.py /path/to/data040.zip --simulator iverilog

  # Codec/envelope audit only (no RTL simulation)
  ./run_cputest.py /path/to/data040.zip --audit

  # Focus a hardware cputest failure
  ./run_cputest.py /path/to/data --full --group BasicFPU \
      --instruction 'FABS.*' --slice 0001 --round-limit 2000
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import zipfile
from xml.etree import ElementTree as ET

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DIFF = HERE / "diff"
sys.path.insert(0, str(DIFF))
from dat_parser import Header, DataFile, walk_stream  # noqa: E402
from replay_gen import generate  # noqa: E402

RTL = REPO / "rtl" / "ap040"
RTL_SOURCES = [
    RTL / "ap040_tg68k_compat.v",
    RTL / "ap040_core.v",
    RTL / "ap040_bus16_adapter.v",
    RTL / "ap040_regfile.v",
    RTL / "ap040_alu.v",
    RTL / "ap040_muldiv.v",
    RTL / "ap040_mmu.v",
    RTL / "ap040_cache.v",
    RTL / "ap040_fpu.v",
]

SMOKE = [
    ("Default", "DIVS.W", "0001"),
    ("Basic", "ABCD.B", "0001"),       # T0/T1 plus normal completion
    ("BasicFPU", "FABS.X", "0001"),
    ("IRQ", "NOP", "0001"),
    ("AE", "BSR.B", "0001"),
    ("ODD_EXC", "ANDSR.W", "0001"),
]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_extract(archive: Path, destination: Path) -> Path:
    marker = destination / ".source.json"
    identity = {"archive": str(archive.resolve()), "sha256": sha256(archive)}
    if marker.exists():
        try:
            if json.loads(marker.read_text()) == identity:
                return destination / "data"
        except (OSError, json.JSONDecodeError):
            pass
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with zipfile.ZipFile(archive) as zf:
        root = destination.resolve()
        for info in zf.infolist():
            target = (destination / info.filename).resolve()
            if root != target and root not in target.parents:
                raise ValueError("unsafe ZIP member %s" % info.filename)
        zf.extractall(destination)
    marker.write_text(json.dumps(identity, sort_keys=True))
    return destination / "data"


def corpus_root(source: Path, work: Path) -> Path:
    if source.is_file():
        if not zipfile.is_zipfile(source):
            raise ValueError("corpus file is not a ZIP archive: %s" % source)
        root = safe_extract(source, work / "corpus-v20")
    else:
        root = source / "data" if (source / "data").is_dir() else source
    if not any(root.glob("68040_*")):
        raise ValueError("no 68040_* groups below %s" % root)
    return root


def group_short(path: Path) -> str:
    name = path.name
    return name[6:] if name.startswith("68040_") else name


def matches_any(value: str, patterns: list[str]) -> bool:
    return not patterns or any(fnmatch.fnmatchcase(value, p) for p in patterns)


def discover(root: Path, args) -> list[dict]:
    slices = []
    smoke = set(SMOKE)
    for header_path in sorted(root.glob("68040_*/*/0000.dat")):
        instruction_dir = header_path.parent
        group_dir = instruction_dir.parent
        group = group_short(group_dir)
        instruction = instruction_dir.name
        if not matches_any(group, args.group):
            continue
        if not matches_any(instruction, args.instruction):
            continue
        for data_path in sorted(instruction_dir.iterdir()):
            number = data_path.name[:4]
            if (number == "0000" or not number.isdigit() or
                    not (data_path.name.endswith(".dat") or
                         data_path.name.endswith(".dat.gz"))):
                continue
            if args.slice and not matches_any(number, args.slice):
                continue
            if not args.full and not args.audit and (group, instruction, number) not in smoke:
                continue
            slices.append({
                "group": group,
                "instruction": instruction,
                "slice": number,
                "header": header_path,
                "data": data_path,
                "group_dir": group_dir,
            })
    unique = {(s["group"], s["instruction"], s["slice"]): s for s in slices}
    slices = [unique[k] for k in sorted(unique)]
    if args.shard:
        index, count = map(int, args.shard.split("/", 1))
        if count <= 0 or index < 0 or index >= count:
            raise ValueError("--shard must be INDEX/COUNT with 0 <= INDEX < COUNT")
        slices = [s for i, s in enumerate(slices) if i % count == index]
    return slices


def compile_rtl(work: Path, simulator: str, force=False, build_jobs=None) -> Path:
    sources = [HERE / "tb_dat_replay.v", *RTL_SOURCES]
    if simulator == "iverilog":
        sim = work / "tb_dat_replay.vvp"
    elif simulator == "verilator":
        sim = work / "obj_dir" / "tb_dat_replay"
    else:  # argparse prevents this, but keep the API defensive.
        raise ValueError("unknown simulator %s" % simulator)
    if (not force and sim.exists() and
            sim.stat().st_mtime >= max(p.stat().st_mtime for p in sources)):
        return sim
    sim.parent.mkdir(parents=True, exist_ok=True)
    if simulator == "iverilog":
        cmd = ["iverilog", "-g2012", "-I", str(RTL), "-o", str(sim)]
        cmd += [str(p) for p in sources]
    else:
        jobs = build_jobs or min(os.cpu_count() or 1, 16)
        cmd = [
            "verilator", "--binary", "--timing",
            "--top-module", "tb_dat_replay",
            "--Mdir", str(sim.parent), "-o", sim.name,
            "--build-jobs", str(jobs),
            "--output-split", "20000", "--output-split-cfuncs", "500",
            "-CFLAGS", "-O3 -march=native",
            "-Wno-fatal", "-Wno-PINMISSING",
            "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
            "-I" + str(RTL),
        ]
        cmd += [str(p) for p in sources]
    print("compile:", " ".join(cmd))
    subprocess.run(cmd, cwd=REPO, check=True)
    if not sim.is_file():
        raise FileNotFoundError("simulator build did not create %s" % sim)
    return sim


def inflate_image(group_dir: Path, basename: str, images: Path) -> Path:
    gz = group_dir / (basename + ".gz")
    plain = group_dir / basename
    source = gz if gz.exists() else plain
    if not source.exists():
        raise FileNotFoundError(source)
    # All supplied v20 groups share these images, but hash the compressed
    # source so a different corpus cannot accidentally reuse an old cache.
    key = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
    target = images / (basename + "." + key)
    if not target.exists():
        images.mkdir(parents=True, exist_ok=True)
        data = gzip.open(source, "rb").read() if source.suffix == ".gz" else source.read_bytes()
        tmp = target.with_suffix(target.suffix + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(target)
    return target


def audit_slice(item: dict, semantic=False) -> dict:
    started = time.monotonic()
    try:
        hdr = Header(item["header"].read_bytes())
        df = DataFile.load(str(item["data"]), hdr)
        walked = walk_stream(hdr, df, interrupttest=bool(hdr.interrupttest))
        walked["exceptions"] = {str(k): v for k, v in walked["exceptions"].items()}
        if walked["consumed"] != walked["size"] - 2:
            raise ValueError("stream consumed %d/%d" %
                             (walked["consumed"], walked["size"]))
        if semantic:
            deep = generate(str(item["header"]), str(item["data"]),
                            os.devnull, audit_only=True)
            walked["semantic_rounds"] = deep["rounds"]
        status, message = "pass", ""
    except Exception as exc:  # report the corpus path, then continue audit
        walked = {}
        status, message = "error", repr(exc)
    return {
        **{k: str(v) if isinstance(v, Path) else v for k, v in item.items()
           if k not in ("group_dir",)},
        "status": status,
        "message": message,
        "seconds": time.monotonic() - started,
        **walked,
    }


def safe_name(item: dict) -> str:
    raw = "%s--%s--%s" % (item["group"], item["instruction"], item["slice"])
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", raw)


def first_mismatch_context(output: str) -> dict:
    """Extract the first RTL diagnostic into machine-readable report fields."""
    match = re.search(
        r"^MISMATCH j(?P<record>\d+) t(?P<test>\d+) r(?P<round>\d+) "
        r"(?P<kind>.*?): expected [0-9a-fA-F]+ got [0-9a-fA-F]+ "
        r"\(pc=[0-9a-fA-F]+ op=(?P<opcode>[0-9a-fA-F]{12}) "
        r"ea=(?P<ea>[0-9a-fA-F]{8})\)$", output, re.MULTILINE)
    if not match:
        return {}
    context = {
        "first_mismatch_record": int(match.group("record")),
        "first_mismatch_test": int(match.group("test")),
        "first_mismatch_round": int(match.group("round")),
        "first_mismatch_kind": match.group("kind"),
        "first_mismatch_opcode": match.group("opcode").lower(),
        "first_mismatch_ea": "0x" + match.group("ea").lower(),
    }
    opcode = int(match.group("opcode")[:4], 16)
    extension = int(match.group("opcode")[4:8], 16)
    if opcode & 0xF000 == 0xF000:
        context["first_mismatch_fpu_opclass"] = (extension >> 13) & 7
        context["first_mismatch_memory_ea"] = ((opcode >> 3) & 7) != 0
    return context


def resume_identity(item: dict, args) -> dict:
    """Describe everything that can change a slice result.

    In particular, a passing 64-record smoke log is not a passing full-slice
    log.  Keeping this beside the text log also prevents stale results after
    an RTL, decoder, corpus, memory-image, or simulator change.
    """
    return {
        "version": 1,
        "simulator": args.simulator,
        "simulator_sha256": args.simulator_sha256,
        "generator_sha256": args.generator_sha256,
        "header_sha256": sha256(item["header"]),
        "data_sha256": sha256(item["data"]),
        "images_sha256": item["images_sha256"],
        "round_limit": args.round_limit,
    }


def run_slice(item: dict, args, sim: Path, work: Path) -> dict:
    started = time.monotonic()
    name = safe_name(item)
    jobs = work / "jobs"
    logs = work / "logs"
    jobs.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    job = jobs / (name + ".apr2")
    log = logs / (name + ".log")
    resume_file = logs / (name + ".resume.json")
    identity = resume_identity(item, args)
    resumable = False
    if args.resume and log.exists() and resume_file.exists():
        try:
            resumable = (json.loads(resume_file.read_text()) == identity and
                         "ALL TESTS PASSED" in log.read_text(errors="replace"))
        except (OSError, json.JSONDecodeError):
            resumable = False
    if resumable:
        return {**item, "status": "pass", "message": "resumed",
                "simulator": args.simulator, "seconds": 0.0,
                "log": str(log), "rounds": None}
    try:
        resume_file.unlink()
    except FileNotFoundError:
        pass
    try:
        limit = args.round_limit
        meta = generate(str(item["header"]), str(item["data"]), str(job), limit)
        lmem = inflate_image(item["group_dir"], "lmem.dat", work / "images")
        tmem = inflate_image(item["group_dir"], "tmem.dat", work / "images")
        cmd = (["vvp", str(sim)] if args.simulator == "iverilog" else [str(sim)])
        cmd += ["+job=" + str(job), "+lmem=" + str(lmem),
                "+tmem=" + str(tmem)]
        proc = subprocess.run(cmd, cwd=REPO, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=args.timeout)
        output = proc.stdout
        log.write_text(output)
        resume_file.write_text(json.dumps(identity, indent=2, sort_keys=True))
        passed = proc.returncode == 0 and "ALL TESTS PASSED" in output
        status = "pass" if passed else "fail"
        tail = "\n".join(output.rstrip().splitlines()[-12:])
        result = {**item, **meta, "simulator": args.simulator,
                  "status": status, "message": tail,
                  "seconds": time.monotonic() - started, "log": str(log),
                  **first_mismatch_context(output)}
    except subprocess.TimeoutExpired as exc:
        # TimeoutExpired may expose captured output as bytes even when the
        # original subprocess used text=True (notably on Python 3.11).  Keep
        # a timed-out RTL slice as a normal per-slice result instead of
        # aborting the complete corpus run with a str/bytes TypeError.
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        output += "\nTIMEOUT after %ss\n" % args.timeout
        log.write_text(output)
        resume_file.write_text(json.dumps(identity, indent=2, sort_keys=True))
        result = {**item, "status": "timeout", "message": output[-4000:],
                  "seconds": time.monotonic() - started, "log": str(log)}
    except Exception as exc:
        result = {**item, "status": "error", "message": repr(exc),
                  "simulator": args.simulator,
                  "seconds": time.monotonic() - started, "log": str(log)}
    if not args.keep_jobs:
        try:
            job.unlink()
        except FileNotFoundError:
            pass
    return result


def serializable(result: dict) -> dict:
    return {k: str(v) if isinstance(v, Path) else v
            for k, v in result.items() if k != "group_dir"}


def write_reports(results: list[dict], work: Path, elapsed: float):
    summary = {
        "elapsed_seconds": elapsed,
        "total": len(results),
        "pass": sum(r["status"] == "pass" for r in results),
        "fail": sum(r["status"] == "fail" for r in results),
        "timeout": sum(r["status"] == "timeout" for r in results),
        "error": sum(r["status"] == "error" for r in results),
        "results": [serializable(r) for r in results],
    }
    (work / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))

    suite = ET.Element("testsuite", name="ap040-cputest-v20",
                       tests=str(len(results)),
                       failures=str(summary["fail"]), errors=str(summary["error"] + summary["timeout"]),
                       time="%.6f" % elapsed)
    for r in results:
        case = ET.SubElement(suite, "testcase", classname="cputest." + r["group"],
                             name=r["instruction"] + "/" + r["slice"],
                             time="%.6f" % r.get("seconds", 0))
        if r["status"] == "fail":
            ET.SubElement(case, "failure", message="RTL mismatch").text = r.get("message", "")
        elif r["status"] != "pass":
            ET.SubElement(case, "error", message=r["status"]).text = r.get("message", "")
        if r.get("log"):
            ET.SubElement(case, "system-out").text = r["log"]
    ET.ElementTree(suite).write(work / "junit.xml", encoding="utf-8", xml_declaration=True)
    return summary


def parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("corpus", type=Path, help="data040.zip, its data/ directory, or extraction root")
    ap.add_argument("--work", type=Path, default=HERE / "build" / "cputest")
    ap.add_argument("--full", action="store_true", help="run every selected slice instead of smoke set")
    ap.add_argument("--audit", action="store_true", help="validate all selected envelopes/streams without RTL")
    ap.add_argument("--semantic-audit", action="store_true",
                    help="also fully materialize state/exception semantics during audit")
    ap.add_argument("--group", action="append", default=[], metavar="GLOB")
    ap.add_argument("--instruction", action="append", default=[], metavar="GLOB")
    ap.add_argument("--slice", action="append", default=[], metavar="GLOB")
    ap.add_argument("--shard", metavar="INDEX/COUNT")
    ap.add_argument("--jobs", type=int, default=min(os.cpu_count() or 1, 16),
                    help="parallel RTL processes (default: cores, capped at 16)")
    # Verilator compiles the design to native code: measured 26x faster over
    # the full 1911-slice corpus (7m09s vs 3h07m) for identical results --
    # same 1875/1911, same 36 failing slices.  Icarus stays available for
    # cross-checking a suspicious result against a second simulator.
    ap.add_argument("--simulator", choices=("iverilog", "verilator"),
                    default="verilator", help="RTL simulation backend")
    ap.add_argument("--build-jobs", type=int,
                    help="parallel C++ compiler jobs for a Verilator build")
    ap.add_argument("--compile-only", action="store_true",
                    help="build the selected RTL simulator and exit")
    ap.add_argument("--round-limit", type=int,
                    help="cap expanded records per slice (smoke defaults to 64)")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds per data slice")
    ap.add_argument("--resume", action="store_true", help="skip slices whose existing log passed")
    ap.add_argument("--keep-jobs", action="store_true")
    ap.add_argument("--rebuild", action="store_true")
    return ap


def main(argv=None):
    args = parser().parse_args(argv)
    args.work = args.work.resolve()
    args.work.mkdir(parents=True, exist_ok=True)
    if not args.full and not args.audit and args.round_limit is None:
        args.round_limit = 64
    started = time.monotonic()
    try:
        root = corpus_root(args.corpus.resolve(), args.work)
        selected = discover(root, args)
        if not selected:
            raise ValueError("selection contains no cputest slices")
        print("corpus:", root)
        print("selected slices:", len(selected))
        if args.audit:
            results = []
            for i, item in enumerate(selected, 1):
                result = audit_slice(item, semantic=args.semantic_audit)
                results.append(result)
                if result["status"] != "pass" or i % 100 == 0 or i == len(selected):
                    print("[%d/%d] %-7s %s/%s/%s" %
                          (i, len(selected), result["status"], item["group"],
                           item["instruction"], item["slice"]))
        else:
            # Keep native-code artifacts, logs and reports independent from
            # Icarus.  A passing vvp log must never make --resume skip a
            # Verilator execution (or vice versa).
            run_work = (args.work if args.simulator == "iverilog"
                        else args.work / "verilator")
            run_work.mkdir(parents=True, exist_ok=True)
            sim = compile_rtl(run_work, args.simulator, force=args.rebuild,
                              build_jobs=args.build_jobs)
            if args.compile_only:
                print("simulator:", sim)
                return 0
            # Populate the content-addressed image cache before workers start
            # so parallel slices never race on the same temporary file.
            image_ids = {}
            for group_dir in sorted({item["group_dir"] for item in selected}):
                lmem = inflate_image(group_dir, "lmem.dat", run_work / "images")
                tmem = inflate_image(group_dir, "tmem.dat", run_work / "images")
                image_ids[group_dir] = [sha256(lmem), sha256(tmem)]
            for item in selected:
                item["images_sha256"] = image_ids[item["group_dir"]]
            args.simulator_sha256 = sha256(sim)
            args.generator_sha256 = [sha256(DIFF / "replay_gen.py"),
                                     sha256(DIFF / "dat_parser.py")]
            results = []
            with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
                futures = {pool.submit(run_slice, item, args, sim, run_work): item
                           for item in selected}
                for i, future in enumerate(concurrent.futures.as_completed(futures), 1):
                    result = future.result()
                    results.append(result)
                    item = futures[future]
                    print("[%d/%d] %-7s %7.2fs %s/%s/%s" %
                          (i, len(selected), result["status"], result["seconds"],
                           item["group"], item["instruction"], item["slice"]), flush=True)
                    if result["status"] != "pass":
                        print(result.get("message", ""))
            results.sort(key=lambda r: (r["group"], r["instruction"], r["slice"]))
        report_work = args.work if args.audit else run_work
        summary = write_reports(results, report_work, time.monotonic() - started)
        print("summary: {pass}/{total} passed, {fail} failed, {timeout} timed out, "
              "{error} errors in {elapsed_seconds:.2f}s".format(**summary))
        print("reports:", report_work / "summary.json", report_work / "junit.xml")
        return 0 if summary["pass"] == summary["total"] else 1
    except Exception as exc:
        print("cputest harness error:", exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
