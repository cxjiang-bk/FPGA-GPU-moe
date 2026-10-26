"""Derive the software/RTL configuration and core file list from the same target."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from opentpu import target

ROOT = Path(__file__).resolve().parents[2]


def generate(output: Path) -> dict:
    t = target.load(str(ROOT / "configs/v80_smoke.toml"))
    cfg = target.config(t)
    p = target.rtl_params(t)
    assert cfg.S == 1 and cfg.D == 128 and not cfg.SEQ_WC
    assert t.uarch["TMEM_IMPL"] == 0 and t.uarch["TMEM_PMP"] == 0
    output.mkdir(parents=True, exist_ok=True)
    # The board shell is implemented locally. Reuse only the fixed upstream core/tech list.
    core = target.sources(t)[:len(target.CORE) + len(target.TECH[t.family])]
    sources = [ROOT / "third_party/openTPU/rtl" / f for f in core]
    for path in sources:
        if not path.is_file():
            raise FileNotFoundError(path)
    document = t.to_dict() | {"rtl_params": p, "sources": [str(s) for s in sources]}
    (output / "config.json").write_text(json.dumps(document, indent=2) + "\n")
    (output / "opentpu_core.f").write_text("\n".join(map(str, sources)) + "\n")
    # Wrapper parameters are derived here; platform-only parameters stay in config.json.
    keys = ["D", "MCOLS", "ACT_ROWS", "ACT_BLOCKS", "TMEM_WORDS", "IMEM_WORDS", "LANES",
            "MXU_IMPL", "MXU_CL", "MXU_E", "VPU_CL", "ULANES", "TMEM_IMPL", "RPB", "WPB",
            "WIN", "FIFO_DEPTH", "PQ_WIN", "ARCH_HASH", "PLATFORM"]
    (output / "params.tcl").write_text("set v80_params [dict create " + " ".join(
        f"{k} {p[k]}" for k in keys) + f"]\nset v80_core_hz {t.core_khz*1000}\n")
    (output / "v80_config_pkg.sv").write_text("// Generated from configs/v80_smoke.toml\npackage v80_config_pkg;\n" +
        "".join(f"  localparam logic [31:0] CFG_{k} = 32'h{p[k]:08x};\n" for k in keys) + "endpackage\n")
    (output / "v80_config.h").write_text("/* Generated from configs/v80_smoke.toml */\n#pragma once\n" +
        "".join(f"#define V80_CFG_{k} 0x{p[k]:08x}u\n" for k in keys))
    return document


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/generated")
    args = parser.parse_args()
    d = generate(args.output)
    print(f"v80_smoke CFG_HASH={d['arch_hash']} core_sources={len(d['sources'])}")
