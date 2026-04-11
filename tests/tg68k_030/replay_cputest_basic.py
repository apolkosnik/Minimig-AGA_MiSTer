#!/usr/bin/env python3
"""Replay cumulative WinUAE cputest BASIC memory state for a chosen subcase.

This helper models the parts of cputest state lifetime that matter for the
current 68030 BASIC investigation:

- `CT_MEMWRITES` init byte patches persist across records.
- init `CT_MEMWRITE` changes are rolled back at end-of-record.
- runtime expected memwrites persist only if cputest does not restore the
  backing region before the next record.
- target subcases can be viewed with their own `CT_MEMWRITE.old` values
  preloaded, to mirror the validate/restore behavior the exact bench now
  depends on.
- `tmem.dat` always persists across records inside one mnemonic directory.

It does not emulate the CPU. It only reconstructs the live memory image that a
later packed record sees after earlier records have run successfully in WinUAE.
"""

from __future__ import annotations

import argparse
import gzip
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

from decode_cputest_dat import Header, MemWrite, Parser, Subcase, parse_header


@dataclass
class FullHeader:
    test_memory_addr: int
    test_memory_size: int
    opcode_memory_addr: int
    interrupttest: int
    low_start: int
    low_end: int
    high_start: int
    high_end: int


def parse_full_header(header_path: Path) -> FullHeader:
    data = header_path.read_bytes()
    vals = struct.unpack(">" + "I" * 20, data[:80])
    (
        _version,
        _starttimeid,
        _hmem_lmem,
        test_memory_addr,
        test_memory_size,
        opcode_memory_addr,
        flags,
        _initial,
        _res1,
        _res2,
        _fpu_model,
        low_start,
        low_end,
        high_start,
        high_end,
        _safe_start,
        _safe_end,
        _usp,
        _ssp,
        _excvec,
    ) = vals
    interrupttest = (flags >> 26) & 3
    return FullHeader(
        test_memory_addr=test_memory_addr,
        test_memory_size=test_memory_size,
        opcode_memory_addr=opcode_memory_addr,
        interrupttest=interrupttest,
        low_start=low_start,
        low_end=low_end,
        high_start=high_start,
        high_end=high_end,
    )


def load_sparse_mem(path: Path) -> Dict[int, int]:
    mem: Dict[int, int] = {}
    with path.open("r", encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            addr_s, word_s = line.split()
            addr = int(addr_s, 16)
            word = int(word_s, 16)
            mem[addr] = (word >> 8) & 0xFF
            mem[addr + 1] = word & 0xFF
    return mem


def apply_memwrite(mem: Dict[int, int], mw: MemWrite, use_new: bool = True) -> None:
    value = mw.new if use_new else mw.old
    if mw.size == 0:
        mem[mw.addr] = value & 0xFF
    elif mw.size == 1:
        mem[mw.addr] = (value >> 8) & 0xFF
        mem[mw.addr + 1] = value & 0xFF
    elif mw.size == 2:
        mem[mw.addr] = (value >> 24) & 0xFF
        mem[mw.addr + 1] = (value >> 16) & 0xFF
        mem[mw.addr + 2] = (value >> 8) & 0xFF
        mem[mw.addr + 3] = value & 0xFF
    else:
        raise ValueError(f"unsupported memwrite size {mw.size}")


def apply_memwrites(mem: Dict[int, int], memwrites: Iterable[MemWrite], use_new: bool = True) -> None:
    for mw in memwrites:
        apply_memwrite(mem, mw, use_new=use_new)


def persistent_runtime_write(addr: int, hdr: FullHeader) -> bool:
    if hdr.test_memory_addr <= addr < hdr.test_memory_addr + hdr.test_memory_size:
        return True
    if hdr.low_start != 0xFFFFFFFF and hdr.low_start <= addr < hdr.low_end:
        return False
    if hdr.high_start != 0xFFFFFFFF and hdr.high_start <= addr < hdr.high_end:
        return False
    return True


def grouped_subcases(parser: Parser) -> List[Tuple[int, List[Tuple[Subcase, Dict[str, int]]]]]:
    grouped: List[Tuple[int, List[Tuple[Subcase, Dict[str, int]]]]] = []
    cur_record = None
    cur_items: List[Tuple[Subcase, Dict[str, int]]] = []
    for sub, state in parser.iter_subcases():
        if cur_record is None:
            cur_record = sub.record_index
        if sub.record_index != cur_record:
            grouped.append((cur_record, cur_items))
            cur_record = sub.record_index
            cur_items = []
        cur_items.append((sub, state))
    if cur_items:
        assert cur_record is not None
        grouped.append((cur_record, cur_items))
    return grouped


def mem_window(mem: Dict[int, int], addr: int, length: int) -> str:
    return " ".join(f"{mem.get(addr + i, 0):02X}" for i in range(length))


def mem_diff(base: Dict[int, int], cur: Dict[int, int], addrs: Iterable[int]) -> List[str]:
    out: List[str] = []
    for addr in addrs:
        b = base.get(addr, 0)
        c = cur.get(addr, 0)
        if b != c:
            out.append(f"{addr:08X}:{b:02X}->{c:02X}")
    return out


def expand_windows(windows: List[Tuple[int, int]]) -> List[int]:
    addrs: List[int] = []
    for addr, length in windows:
        addrs.extend(addr + i for i in range(length))
    return addrs


def build_target_view_mem(
    record_mem: Dict[int, int],
    subcase: Subcase,
    hdr: FullHeader,
    stage: str,
    prime_target_old_values: bool,
) -> Dict[int, int]:
    view_mem = dict(record_mem)
    if prime_target_old_values:
        apply_memwrites(view_mem, subcase.memwrites, use_new=False)
    if stage == "after":
        for mw in subcase.memwrites:
            if persistent_runtime_write(mw.addr, hdr):
                apply_memwrite(view_mem, mw, use_new=True)
    return view_mem


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mnemonic_dir", type=Path, help="Directory like .../68030_Basic/JMP")
    ap.add_argument("--file", default="0002.dat.gz", help="Packed testcase file inside the mnemonic dir")
    ap.add_argument("--record", type=int, required=True, help="Record index inside the packed file")
    ap.add_argument("--group", type=int, default=0, help="Group index inside the record")
    ap.add_argument("--subcase", type=int, default=0, help="Subcase index inside the group")
    ap.add_argument(
        "--stage",
        choices=("before", "after"),
        default="before",
        help="Dump state before or after the chosen subcase's expected runtime memwrites",
    )
    ap.add_argument(
        "--sparse-mem",
        type=Path,
        default=Path("tests/tg68k_030/data/cputest_basic_sparse.mem"),
        help="Sparse .mem file that seeds the initial BASIC memory image",
    )
    ap.add_argument(
        "--window",
        action="append",
        default=[],
        help="Memory window addr:length to dump, for example 0x42050000:16",
    )
    ap.add_argument(
        "--prime-target-old-values",
        action="store_true",
        help="Preload the chosen subcase's CT_MEMWRITE old values before dumping it",
    )
    args = ap.parse_args()

    header = parse_header(args.mnemonic_dir / "0000.dat")
    full_header = parse_full_header(args.mnemonic_dir / "0000.dat")
    cur_mem = load_sparse_mem(args.sparse_mem)
    base_mem = dict(cur_mem)

    default_windows = [(full_header.opcode_memory_addr, 16)]
    for extra in ("0x8A:6", "0x4204FEF8:8"):
        default_windows.append(tuple(int(part, 0) for part in extra.split(":", 1)))
    for spec in args.window:
        addr_s, length_s = spec.split(":", 1)
        default_windows.append((int(addr_s, 0), int(length_s, 0)))

    packed_files = sorted(args.mnemonic_dir.glob("*.dat.gz"))
    for packed_path in packed_files:
        parser = Parser(header, gzip.open(packed_path, "rb").read())
        for record_index, items in grouped_subcases(parser):
            first_sub, _ = items[0]

            for bp in first_sub.init_bytepatches:
                for i, byte in enumerate(bp.data):
                    cur_mem[bp.addr + i] = byte
            record_mem = dict(cur_mem)
            apply_memwrites(record_mem, first_sub.init_memwrites, use_new=True)

            if packed_path.name == args.file and record_index == args.record and args.stage == "before":
                break_out = False
                for sub, _state in items:
                    if sub.group_index == args.group and sub.subcase_index == args.subcase:
                        view_mem = build_target_view_mem(
                            record_mem,
                            sub,
                            full_header,
                            "before",
                            args.prime_target_old_values,
                        )
                        print(
                            f"TARGET {packed_path.name} record={record_index} "
                            f"group={sub.group_index} subcase={sub.subcase_index} stage=before"
                        )
                        print(f"  extraccr={sub.extraccr} exc={sub.exc} extra_trace={sub.extra_trace} standalone={sub.extra_trace_standalone}")
                        print(f"  prime_target_old_values={args.prime_target_old_values}")
                        for addr, length in default_windows:
                            print(f"  window {addr:08X}:{length}  {mem_window(view_mem, addr, length)}")
                        diff = mem_diff(base_mem, view_mem, expand_windows(default_windows))
                        if diff:
                            print("  diff  " + " ".join(diff))
                        else:
                            print("  diff  <none in requested windows>")
                        break_out = True
                        break
                if break_out:
                    return

            for sub, _state in items:
                if packed_path.name == args.file and record_index == args.record and args.stage == "after" and sub.group_index == args.group and sub.subcase_index == args.subcase:
                    view_mem = build_target_view_mem(
                        record_mem,
                        sub,
                        full_header,
                        "after",
                        args.prime_target_old_values,
                    )
                    print(
                        f"TARGET {packed_path.name} record={record_index} "
                        f"group={sub.group_index} subcase={sub.subcase_index} stage=after"
                    )
                    print(f"  extraccr={sub.extraccr} exc={sub.exc} extra_trace={sub.extra_trace} standalone={sub.extra_trace_standalone}")
                    print(f"  prime_target_old_values={args.prime_target_old_values}")
                    for addr, length in default_windows:
                        print(f"  window {addr:08X}:{length}  {mem_window(view_mem, addr, length)}")
                    diff = mem_diff(base_mem, view_mem, expand_windows(default_windows))
                    if diff:
                        print("  diff  " + " ".join(diff))
                    else:
                        print("  diff  <none in requested windows>")
                    return

                for mw in sub.memwrites:
                    if persistent_runtime_write(mw.addr, full_header):
                        apply_memwrite(record_mem, mw, use_new=True)
                        apply_memwrite(cur_mem, mw, use_new=True)

    raise SystemExit("target subcase not found")


if __name__ == "__main__":
    main()
