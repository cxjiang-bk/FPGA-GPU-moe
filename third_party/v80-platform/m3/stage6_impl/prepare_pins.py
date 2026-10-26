#!/usr/bin/env python3
"""Preserve AMR pin constraints except for its four reversed HBM P/N entries."""
from pathlib import Path
import re
import sys

MAPPING = (
    ("hbm_ref_clk_0_clk_p", "N18", "N19"),
    ("hbm_ref_clk_0_clk_n", "N19", "N18"),
    ("hbm_ref_clk_1_clk_p", "N38", "N37"),
    ("hbm_ref_clk_1_clk_n", "N37", "N38"),
)


def prepare(source: Path, output: Path):
    if source.resolve() == output.resolve():
        raise ValueError("Keep the original AMR XDC intact")
    lines = source.read_text().splitlines(keepends=True)
    for port, old, new in MAPPING:
        indices = [i for i, line in enumerate(lines) if f'[get_ports "{port}"]' in line]
        if len(indices) != 1:
            raise ValueError(f"Expected exactly one original constraint for {port}")
        i = indices[0]
        replacement, count = re.subn(r"(PACKAGE_PIN\s+)" + old + r"\b",
                                     lambda m: m[1] + new, lines[i])
        if count != 1:
            raise ValueError(f"Original pin assignment changed for {port}; review required")
        lines[i] = replacement
    output.write_text("".join(lines))
    return [{"port": p, "original": old, "corrected": new} for p, old, new in MAPPING]


if __name__ == "__main__":
    for change in prepare(Path(sys.argv[1]), Path(sys.argv[2])):
        print(change)
