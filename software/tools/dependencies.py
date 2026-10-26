"""Freeze or verify source/config/tool identities for the smoke target."""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "configs/dependencies.lock.json"


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def snapshot():
    reference = ROOT / "third_party/v80-platform"
    manifest = json.loads((reference / "manifest.json").read_text())
    for rel, expected in manifest["files_sha256"].items():
        if digest(reference / rel) != expected:
            raise ValueError(f"platform snapshot changed: {rel}")
    upstream = ROOT / "third_party/openTPU"
    head = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(upstream), "status", "--porcelain"], text=True)
    if dirty or head != "506e81b1d297e22739dab5ecaeee684493d5c720":
        raise ValueError("openTPU dependency changed")
    verilator = Path(sys.prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages/verilator/bin/verilator_bin"
    return dict(schema_version=1, opentpu=dict(url="https://github.com/FeSens/openTPU.git", commit=head, license="Apache-2.0"),
                platform=dict(source_commit=manifest["source_head"], snapshot_manifest_sha256=digest(reference/"manifest.json"), files=len(manifest["files_sha256"])),
                target_sha256=digest(ROOT/"configs/v80_smoke.toml"),
                contracts_sha256={str(p.relative_to(ROOT)):digest(p) for p in sorted((ROOT/"contracts").glob("*.yaml"))},
                python_version=sys.version.split()[0], packages={name:importlib.metadata.version(name) for name in ["numpy","pytest","PyYAML","verilator"]},
                verilator_binary_sha256=digest(verilator))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--freeze", action="store_true", help="explicitly update the dependency lock")
    args = parser.parse_args()
    current = snapshot()
    if args.freeze:
        LOCK.write_text(json.dumps(current, indent=2)+"\n")
        print("DEPENDENCIES_FROZEN " + str(LOCK))
    else:
        expected = json.loads(LOCK.read_text())
        if expected != current:
            raise SystemExit("dependency/config/tool identity changed; review before explicitly updating the lock")
        print("DEPENDENCIES_VERIFIED")
