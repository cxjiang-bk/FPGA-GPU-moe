"""Rebuild and run native-program/AXI/control regressions; retain every log and command."""
from __future__ import annotations

import argparse
from datetime import datetime
from zoneinfo import ZoneInfo
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def main(output: Path):
    output.mkdir(parents=True, exist_ok=False)
    commands = output / "commands.sh"
    commands.write_text("#!/usr/bin/env bash\nset -euo pipefail\ncd " + shlex.quote(str(ROOT)) +
                        "\nsource hardware/scripts/build/env.sh\n")
    steps = []

    def execute(name, command, timeout=300):
        with commands.open("a") as f:
            f.write(shlex.join(list(map(str, command))) + "\n")
        start = time.monotonic()
        with (output / f"{name}.log").open("w") as log:
            result = subprocess.run(list(map(str, command)), cwd=ROOT, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        steps.append(dict(name=name, argv=list(map(str, command)), exit_code=result.returncode,
                          wall_seconds=time.monotonic()-start))
        (output / "steps.json").write_text(json.dumps(steps, indent=2) + "\n")
        if result.returncode:
            print((output / f"{name}.log").read_text()[-5000:])
            raise RuntimeError(f"{name} failed: {result.returncode}")
        print(name + ": passed", flush=True)

    try:
        execute("configuration", [sys.executable, "software/tools/configure.py"])
        execute("contracts", [sys.executable, "software/tools/generate_contracts.py"])
        execute("platform", [sys.executable, "software/tools/freeze_platform.py"])
        execute("board-wrapper", [sys.executable, "software/tools/prepare_board.py"])
        cases_root = output / "cases"
        execute("generate-cases", [sys.executable, "software/tools/generate_cases.py", "--output", cases_root])
        common = ["verilator", "--binary", "--timing", "--assert", "-j", "8", "-Wno-fatal",
                  "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-O1", "--output-split", "20000"]
        execute("bridge-build", common + ["--top-module", "tb_mem_axi", "-Mdir", ROOT / "build/sim/bridge",
                "hardware/rtl/adapters/otpu_mem_axi.sv", "hardware/sim/axi_memory_model.sv", "hardware/sim/tb_mem_axi.sv"])
        for seed in [23, 117, 2026]:
            execute(f"bridge-seed-{seed}", [ROOT / "build/sim/bridge/Vtb_mem_axi", f"+seed={seed}"])
            if "BRIDGE_PASS" not in (output / f"bridge-seed-{seed}.log").read_text():
                raise AssertionError("bridge success marker missing")
        execute("core-build", common + ["--top-module", "tb_v80_core", "-Mdir", ROOT / "build/sim/core",
            "-f", "build/generated/opentpu_core.f", "build/generated/v80_config_pkg.sv",
            "build/generated/v80_regs_pkg.sv", "hardware/rtl/adapters/otpu_mem_axi.sv",
            "hardware/rtl/adapters/v80_control.sv", "hardware/rtl/top/v80_opentpu_core.sv",
            "hardware/sim/axi_memory_model.sv", "hardware/sim/tb_v80_core.sv"])
        summaries = []
        for folder in sorted(cases_root.iterdir()):
            info = json.loads((folder / "case.json").read_text())
            dump = folder / "rtl-memory.bin"
            cmd = [ROOT / "build/sim/core/Vtb_v80_core", f"+image={folder}/initial.bin",
                   f"+golden={folder}/expected-output.bin", f"+dump={dump}", "+seed=23"]
            cmd += [f"+{k}={info[k]}" for k in ["program_address", "output_address", "output_bytes", "image_bytes"]]
            cmd.append(f"+program_count={info['program_instructions']}")
            execute(info["name"], cmd, timeout=180)
            actual, golden = dump.read_bytes(), (folder / "expected-memory.bin").read_bytes()
            if actual != golden:
                mismatch = next((i for i, (a,b) in enumerate(zip(actual,golden)) if a != b), min(len(actual),len(golden)))
                raise AssertionError(f"{info['name']}: full initialized memory mismatch at byte {mismatch}")
            log = (output / f"{info['name']}.log").read_text()
            if "CORE_PASS" not in log:
                raise AssertionError("core success marker missing")
            summaries.append(info | dict(rtl_bit_exact=True, initialized_memory_bit_exact=True,
                rtl_memory_sha256=hashlib.sha256(actual).hexdigest(),
                repeated_exec_cycles=list(map(int, re.findall(r"exec_cycles=(\d+)", log)))))
        manifest = dict(schema_version=1, status="passed", scope="offline simulation; no board performance claim",
                        target=json.loads((ROOT/"build/generated/config.json").read_text()),
                        environment={k: os.environ.get(k) for k in ["OTPU_TARGET", "LC_ALL", "PYTHONPATH"]},
                        tool_python=sys.version, tool_verilator=subprocess.check_output(["verilator","--version"],text=True).strip(),
                        cases=summaries)
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print("OFFLINE_PASS " + str(output), flush=True)
    except Exception as exc:
        (output / "failure.json").write_text(json.dumps(dict(status="failed", error=str(exc)), indent=2)+"\n")
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "results" / (
        "offline-" + datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m%d-%H%M%S")))
    main(parser.parse_args().output.resolve())
