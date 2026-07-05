#!/usr/bin/env python3
"""Build a sparse word-memory image from cputest lmem+tmem payloads.

Usage example:
  python3 build_cputest_sparse_mem.py \
      --mnemonic-dir /home/adam/Downloads/data_030/68030_Basic/DIVU.W \
      --out /tmp/basic_divuw_sparse.mem
"""

from __future__ import annotations

import argparse
import gzip
from pathlib import Path

from decode_cputest_dat import parse_header


def emit_word_mem(data: bytes, base_addr: int, out_f) -> None:
    for offs in range(0, len(data), 2):
        hi = data[offs]
        lo = data[offs + 1] if offs + 1 < len(data) else 0
        out_f.write(f"{base_addr + offs:08X} {hi:02X}{lo:02X}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mnemonic_dir", type=Path, help="Directory like .../68030_Basic/DIVU.W")
    ap.add_argument("--out", type=Path, required=True, help="Output sparse .mem path")
    args = ap.parse_args()

    mnemonic_dir = args.mnemonic_dir
    header = parse_header(mnemonic_dir / "0000.dat")
    suite_root = mnemonic_dir.parent

    lmem = gzip.open(suite_root / "lmem.dat.gz", "rb").read()
    tmem = gzip.open(suite_root / "tmem.dat.gz", "rb").read()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="ascii") as f:
        emit_word_mem(lmem, 0, f)
        emit_word_mem(tmem, header.test_memory_addr, f)


if __name__ == "__main__":
    main()
