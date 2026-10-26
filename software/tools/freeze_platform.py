"""Copy a bounded, hash-verified M3 platform source snapshot into this project."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def freeze(source: Path, output: Path):
    if output.exists():
        manifest = json.loads((output / "manifest.json").read_text())
        for rel, digest in manifest["files_sha256"].items():
            if hashlib.sha256((output / rel).read_bytes()).hexdigest() != digest:
                raise ValueError(f"frozen platform changed: {rel}")
        print(f"verified existing platform snapshot: {len(manifest['files_sha256'])} files")
        return manifest
    m3 = source / "fpga/v80/m3_lpumem"
    platform = source / ("fpga/v80/amr-alveo_v80_gen5x8_26.1_20260609/"
                         "build_v80_pld_20261010/amr_vivado_designs/alveo_v80/platforms/v80_base")
    selected = ["README.md", "dependencies.json", "source_manifest.json", "evidence/acceptance.json",
                "stage2/m3_lpu_wrapper.sv", "stage3/m3_lpumem_export.tcl",
                "stage3/lpu_completion_status.sv", "stage3/audit_bd.tcl", "axi_hbm_addr_remap.sv",
                "clock_split/audit_clocks.tcl", "clock_split/configure_clocks.tcl",
                "stage6_impl/prepare_pins.py", "stage6_impl/hbm_refclk_pins.xdc",
                "stage6_impl/configure_bar2.tcl", "stage6_impl/reports.tcl",
                "stage6_impl/export_images.tcl", "stage6_impl/verify_images.py",
                "stage6_impl/adopt_xsa_pair.py", "stage6_impl/unpack_xsa_boot.py"]
    sources = [(m3 / p, Path("m3") / p) for p in selected]
    sources += [(p, Path("amr/v80_base/ip") / p.relative_to(platform / "ip"))
                for p in sorted((platform / "ip").rglob("*")) if p.is_file()]
    sources += [(platform / p, Path("amr/v80_base") / p)
                for p in ["xdc/impl.xdc", "xdc/impl.pins.xdc", "scripts/main.tcl"]]
    # Read every selected source before creating a snapshot, so permission failures are explicit.
    contents = [(p, rel, p.read_bytes()) for p, rel in sources]
    output.mkdir(parents=True)
    hashes = {}
    for source_path, rel, content in contents:
        destination = output / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        hashes[str(rel)] = hashlib.sha256(content).hexdigest()
        if hashlib.sha256(source_path.read_bytes()).hexdigest() != hashes[str(rel)]:
            raise RuntimeError(f"source changed during freeze: {source_path}")
    git = ["git", "-c", f"safe.directory={source}", "-C", str(source)]
    head = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
    manifest = dict(schema_version=1, source_repository=str(source), source_head=head,
                    scope="Selected M3 integration and AMR platform sources; original project untouched",
                    omitted=["LPU/RVCore implementation", "M2", "license credentials", "private fixtures",
                             "historical generated projects/images", "AMC firmware (needed at packaging stage)"],
                    files_sha256=hashes)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"froze platform snapshot: {len(hashes)} files")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/mnt/data/jiangcx/v80_bringup/rtl"))
    parser.add_argument("--output", type=Path, default=ROOT / "third_party/v80-platform")
    args = parser.parse_args()
    freeze(args.source.resolve(), args.output.resolve())
