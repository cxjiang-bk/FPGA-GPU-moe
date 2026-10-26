"""Generate C, Python and SystemVerilog register definitions from one YAML contract."""
from pathlib import Path
import argparse
import json
import yaml

ROOT = Path(__file__).resolve().parents[2]


def generate(output: Path):
    doc = yaml.safe_load((ROOT / "contracts/registers.yaml").read_text())
    values = doc["constants"] | {"REG_" + k: v["offset"] for k, v in doc["registers"].items()}
    offsets = [r["offset"] for r in doc["registers"].values()]
    if len(set(offsets)) != len(offsets) or any(x % 4 for x in offsets):
        raise ValueError("register offsets must be aligned and unique")
    output.mkdir(parents=True, exist_ok=True)
    (output / "v80_regs_pkg.sv").write_text("// Generated from contracts/registers.yaml\npackage v80_regs_pkg;\n" +
        "".join(f"  localparam logic [31:0] {k} = 32'h{v:08x};\n" for k, v in values.items()) + "endpackage\n")
    (output / "v80_regs.h").write_text("/* Generated from contracts/registers.yaml */\n#pragma once\n" +
        "".join(f"#define V80_{k} 0x{v:08x}u\n" for k, v in values.items()))
    (output / "v80_regs.py").write_text("# Generated from contracts/registers.yaml\n" +
        "".join(f"{k} = 0x{v:08x}\n" for k, v in values.items()))
    (output / "registers.json").write_text(json.dumps(doc, indent=2) + "\n")
    (output / "registers.tcl").write_text(f"set v80_control_offset {doc['window_offset']}\nset v80_control_bytes {doc['window_bytes']}\n")
    print(f"contracts: {len(offsets)} registers, C/Python/SV bindings")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/generated")
    generate(parser.parse_args().output)
