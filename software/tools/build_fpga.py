"""Snapshot build inputs and run Vivado 2026.1 without touching the reference or board."""
from __future__ import annotations

import argparse
from datetime import datetime
from zoneinfo import ZoneInfo
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

from software.tools.configure import generate as configure
from software.tools.generate_contracts import generate as contracts
from software.tools.freeze_platform import freeze

ROOT = Path(__file__).resolve().parents[2]


def build(mode: str, jobs: int):
    if not 1 <= jobs <= 16:
        raise ValueError("jobs must be in 1..16")
    vivado = Path(os.environ.get("V80_VIVADO", "/opt/Xilinx/Downloads/2026.1/Vivado/bin/vivado"))
    if not vivado.is_file():
        raise FileNotFoundError(vivado)
    pinned = "506e81b1d297e22739dab5ecaeee684493d5c720"
    upstream = ROOT / "third_party/openTPU"
    head = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
    if head != pinned or subprocess.check_output(["git", "-C", str(upstream), "status", "--porcelain"], text=True):
        raise RuntimeError("openTPU dependency differs from the frozen commit")
    freeze(Path("/mnt/data/jiangcx/v80_bringup/rtl"), ROOT / "third_party/v80-platform")
    run = ROOT / "hardware/vivado/projects/v80_smoke" / (
        mode + "-" + datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m%d-%H%M%S-%f"))
    (run / "inputs/rtl").mkdir(parents=True)
    (run / "reports").mkdir()
    generated = run / "inputs/generated"
    cfg = configure(generated)
    contracts(generated)
    sources = [Path(s) for s in cfg["sources"]] + [generated / "v80_config_pkg.sv", generated / "v80_regs_pkg.sv"]
    sources += [ROOT / rel.strip() for rel in (ROOT / "hardware/vivado/filelists/v80_local.f").read_text().splitlines()
                if rel.strip() and not rel.lstrip().startswith("#")]
    hashes, copied = {}, []
    for src in sources:
        dest = run / "inputs/rtl" / src.name
        if dest.exists():
            raise RuntimeError(f"duplicate RTL basename: {src.name}")
        shutil.copyfile(src, dest)
        copied.append(str(dest))
        hashes[str(src)] = hashlib.sha256(src.read_bytes()).hexdigest()
    (run / "inputs/sources.tcl").write_text("set v80_sources [list " + " ".join("{"+s+"}" for s in copied) + "]\n")
    script = ROOT / "hardware/vivado/tcl/build.tcl"
    shutil.copyfile(script, run / "inputs/build.tcl")
    reference = ROOT / "third_party/v80-platform/m3/stage3/m3_lpumem_export.tcl"
    bd = reference.read_text().replace("user.org:user:m3_lpu_wrapper:1.0", "user.org:user:v80_opentpu_wrapper:1.0")
    bd = bd.replace("m3_lpumem", "v80_platform")
    (run / "inputs/v80_opentpu_bd.tcl").write_text(bd)
    shutil.copyfile(ROOT / "hardware/vivado/ip/package_opentpu.tcl", run / "inputs/package_opentpu.tcl")
    manifest = dict(mode=mode, jobs=jobs, status="running", upstream_commit=head,
                    target=cfg, source_sha256=hashes, board_access=False,
                    reference_snapshot_sha256=hashlib.sha256((ROOT / "third_party/v80-platform/manifest.json").read_bytes()).hexdigest())
    (run / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    command = [str(vivado), "-mode", "batch", "-nojournal", "-log", str(run / "vivado.log"),
               "-source", str(run / "inputs/build.tcl"), "-tclargs", str(ROOT), str(run), mode, str(jobs)]
    (run / "commands.sh").write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + shlex.join(command) + "\n")
    print("VIVADO_RUN " + str(run), flush=True)
    with (run / "console.log").open("w") as log:
        result = subprocess.run(command, cwd=run, stdout=log, stderr=subprocess.STDOUT)
    marker = run / ("OOC_COMPLETE" if mode == "ooc" else "CHECK_COMPLETE" if mode == "check" else "ROUTE_COMPLETE")
    success = result.returncode == 0 and marker.exists()
    manifest.update(status=("route_complete_pending_review" if mode == "implement" else "passed") if success else "failed",
                    exit_code=result.returncode, board_signoff=False)
    (run / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print("VIVADO_" + manifest["status"].upper() + " " + str(run), flush=True)
    if not success:
        print((run / "console.log").read_text()[-6500:])
        return 1
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--ooc", action="store_true")
    group.add_argument("--check-only", action="store_true")
    group.add_argument("--implement", action="store_true")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    sys.exit(build("ooc" if args.ooc else "check" if args.check_only else "implement", args.jobs))
