"""Validate a frozen case and run it on an already provisioned openTPU V80 image."""
from pathlib import Path
import argparse
import hashlib
import json
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", type=Path, required=True)
    parser.add_argument("--queue", required=True)
    parser.add_argument("--bar2", required=True)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--run", action="store_true", help="execute HBM writes and compute; default prints the command")
    args = parser.parse_args()
    info = json.loads((args.case / "case.json").read_text())
    for rel, digest in info["files_sha256"].items():
        path = args.case / rel
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"case changed: {path}")
    image = (args.case / "initial.bin").read_bytes()
    program = (args.case / "program.bin").read_bytes()
    count, address = info["program_instructions"], info["program_address"]
    if not (0 < count <= 1024) or address % 128 or len(program) != (count*32+127)//128*128:
        raise ValueError("invalid native program size/alignment")
    if len(image) != info["image_bytes"] or image[address:address+len(program)] != program:
        raise ValueError("program does not match initial memory image")
    if info["output_address"] < 0 or info["output_address"]+info["output_bytes"] > len(image):
        raise ValueError("output outside case image")
    cmd = [str(ROOT / "build/host/v80-smoke"), args.queue, args.bar2,
           str((args.case/"initial.bin").resolve()), str((args.case/"expected-output.bin").resolve()),
           str(info["program_address"]), str(info["program_instructions"]), str(info["output_address"]),
           str(info["output_bytes"]), str(args.repeat), info["cfg_hash"]]
    print(shlex.join(cmd), flush=True)
    if args.run:
        subprocess.run(cmd, check=True)
