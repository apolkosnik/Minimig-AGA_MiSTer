#!/usr/bin/env python3
"""Build text memory images for the BASIC exact cputest benches."""

from __future__ import annotations

import argparse
import gzip
from pathlib import Path


def emit_word_mem(data: bytes, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="ascii") as f:
        for addr in range(0, len(data), 2):
            hi = data[addr]
            lo = data[addr + 1] if addr + 1 < len(data) else 0
            f.write(f"{addr:08X} {hi:02X}{lo:02X}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--lmem-gz",
        type=Path,
        default=Path("/home/adam/Downloads/data_030/68030_Basic/lmem.dat.gz"),
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("tests/tg68k_030/data/cputest_basic_lmem.mem"),
    )
    args = ap.parse_args()

    data = gzip.open(args.lmem_gz, "rb").read()
    emit_word_mem(data, args.out)


if __name__ == "__main__":
    main()
