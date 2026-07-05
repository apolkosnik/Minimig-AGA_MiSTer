#!/usr/bin/env python3
"""Audit packed 68030 DIV corpora and report real case counts/shapes.

This is a corpus audit, not a CPU replay harness. It answers:

- how many packed subcases exist for DIVL.L and DIVU.W
- how many actual execution groups they represent
- what exception classes appear
- what expected-value shapes dominate

It is useful for validating coverage claims before adding or changing RTL.
"""

from __future__ import annotations

import argparse
import collections
from pathlib import Path

from decode_cputest_dat import parse_case_file


def iter_corpus_dirs(root: Path) -> list[tuple[str, Path]]:
    return [
        ("68030_Default/DIVL.L", root / "68030_Default" / "DIVL.L"),
        ("68030_Basic/DIVL.L", root / "68030_Basic" / "DIVL.L"),
        ("68030_Default/DIVU.W", root / "68030_Default" / "DIVU.W"),
        ("68030_Basic/DIVU.W", root / "68030_Basic" / "DIVU.W"),
    ]


def audit_one(label: str, mnemonic_dir: Path) -> None:
    subcase_total = 0
    exec_groups = set()
    records = set()
    exceptions: collections.Counter[int] = collections.Counter()
    shapes: collections.Counter[tuple[str, ...]] = collections.Counter()

    packed_files = sorted(mnemonic_dir.glob("*.dat.gz"))
    for packed_path in packed_files:
        _header, parser = parse_case_file(packed_path)
        for subcase, _state in parser.iter_subcases():
            subcase_total += 1
            records.add((packed_path.name, subcase.record_index))
            exec_groups.add(
                (
                    packed_path.name,
                    subcase.record_index,
                    subcase.group_index,
                    subcase.extraccr,
                )
            )
            exceptions[subcase.exc] += 1
            shapes[tuple(sorted(subcase.expected_values.keys()))] += 1

    print(f"\n{label}")
    print(f"  packed files: {len(packed_files)}")
    print(f"  records: {len(records)}")
    print(f"  execution groups: {len(exec_groups)}")
    print(f"  subcases: {subcase_total}")
    print("  exceptions:")
    for exc, count in sorted(exceptions.items()):
        print(f"    exc={exc}: {count}")
    print("  top expected-value shapes:")
    for shape, count in shapes.most_common(12):
        shape_s = ",".join(shape) if shape else "<none>"
        print(f"    {count:6d}  {shape_s}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--root",
        type=Path,
        default=Path("/home/adam/Downloads/data_030"),
        help="Root containing 68030_Default and 68030_Basic",
    )
    args = ap.parse_args()

    for label, mnemonic_dir in iter_corpus_dirs(args.root):
        audit_one(label, mnemonic_dir)


if __name__ == "__main__":
    main()
