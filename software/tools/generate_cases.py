"""Generate frozen synthetic cases, native programs and exact ISA golden data."""
from __future__ import annotations

import argparse
from dataclasses import replace
import hashlib
import json
from pathlib import Path

import numpy as np
from opentpu import isa, target
from opentpu.isasim import Machine
from opentpu.runtime import Input, Output, Weight, compile_kernel

from software.operators.common.reference import expert, projection
from software.operators.gemv.kernel import gemv
from software.operators.swiglu.kernel import swiglu

ROOT = Path(__file__).resolve().parents[2]


def generate(output: Path, name: str, n: int, k: int, seed: int, is_expert=False) -> dict:
    cfg = target.config(str(ROOT / "configs/v80_smoke.toml"))
    # Only the external memory model is bounded in simulation. All core parameters are exact.
    sim_cfg = replace(cfg, DRAM_BYTES=8 << 20)
    rng = np.random.default_rng(seed)
    x = rng.normal(size=(1, k)).astype(np.float32)
    w = (rng.normal(size=(n, k)) / np.sqrt(k)).astype(np.float32)
    args = dict(x=Input(x))
    arrays = dict(x=x)
    if is_expert:
        up = (rng.normal(size=(n, k)) / np.sqrt(k)).astype(np.float32)
        down = (rng.normal(size=(k, n)) / np.sqrt(n)).astype(np.float32)
        args.update(w_gate=Weight(w), w_up=Weight(up), w_down=Weight(down), out=Output((1, k)))
        arrays.update(gate=w, up=up, down=down)
        mathematical = expert(x, w, up, down, cfg.D)
        float_reference = ((x.astype(np.float64) @ w.T) /
                           (1 + np.exp(-(x.astype(np.float64) @ w.T))) *
                           (x.astype(np.float64) @ up.T)) @ down.T
    else:
        args.update(weight=Weight(w), out=Output((1, n)))
        arrays["weight"] = w
        mathematical = projection(x, w, cfg.D)
        float_reference = x.astype(np.float64) @ w.T
    compiled, images = compile_kernel(swiglu if is_expert else gemv, sim_cfg, **args)
    program = compiled.programs[0]
    words = np.asarray(isa.assemble(program), dtype="<u4")
    output_arg, output_address = compiled.layout.params["out"]
    out_bytes = int(np.prod(output_arg.shape)) * 4
    used = (output_address + out_bytes + 127) // 128 * 128
    program_address = (used + 4095) // 4096 * 4096
    padded = words.tobytes() + bytes(-words.nbytes % cfg.D)
    if program_address + len(padded) > sim_cfg.DRAM_BYTES:
        raise MemoryError("case does not fit bounded simulation memory")
    image = images[0]
    image[output_address:output_address + out_bytes] = 0xA5
    image[program_address:program_address + len(padded)] = np.frombuffer(padded, dtype=np.uint8)
    machine = Machine(sim_cfg, compiled.programs, [image]).run()
    result = machine.slices[0].dram[output_address:output_address + out_bytes].view("<f4")
    result = result.reshape(output_arg.shape).copy()
    exact = mathematical.astype(np.float64)
    difference = np.abs(result - exact)
    relative_l2 = float(np.linalg.norm(result - exact) / np.linalg.norm(exact))
    if not np.isfinite(result).all() or relative_l2 > 0.02:
        raise AssertionError(f"{name}: math reference mismatch {relative_l2}")
    output.mkdir(parents=True, exist_ok=True)
    total = program_address + len(padded)
    image[:total].tofile(output / "initial.bin")
    machine.slices[0].dram[:total].tofile(output / "expected-memory.bin")
    result.astype("<f4").tofile(output / "expected-output.bin")
    np.savez(output / "input-arrays.npz", **arrays)
    (output / "program.bin").write_bytes(padded)
    (output / "program.asm").write_text("\n".join(f"{i:04d} {ins}" for i, ins in enumerate(program)) + "\n")
    # The upstream behavioural model reads big endian words with $fread; AXI BFM uses bytes.
    (output / "initial.hex").write_text("\n".join(f"{v:02x}" for v in image[:total]) + "\n")
    info = dict(name=name, seed=seed, operation="swiglu" if is_expert else "gemv",
                shape=dict(M=1, N=n, K=k), numerics="openTPU native int8 MX",
                cfg_hash=f"{target.arch_hash(cfg):08x}", simulation_memory_bytes=sim_cfg.DRAM_BYTES,
                core_parameters_identical_to_device=True, program_address=program_address,
                program_instructions=len(program), program_bytes=words.nbytes,
                program_padded_bytes=len(padded), image_bytes=total,
                output_address=output_address, output_bytes=out_bytes,
                math_max_abs=float(difference.max()), math_relative_l2=relative_l2,
                math_max_rel=float((difference / np.maximum(np.abs(exact), 1e-12)).max()),
                unquantized_relative_l2=float(np.linalg.norm(result - float_reference) /
                                             np.linalg.norm(float_reference)),
                reference="ISA exact golden; separate high-level MX math comparison",
                files_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in output.iterdir() if p.is_file() and p.name != "case.json"})
    (output / "case.json").write_text(json.dumps(info, indent=2) + "\n")
    print(json.dumps({k: info[k] for k in ["name", "cfg_hash", "program_instructions", "math_relative_l2"]}))
    return info


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/cases")
    args = parser.parse_args()
    for name, n, k, seed, expert_case in [("gemv-256", 256, 256, 20261026, False),
                                         ("projection-512x2048", 512, 2048, 20261027, False),
                                         ("swiglu-2048-512", 512, 2048, 20261028, True)]:
        generate(args.output / name, name, n, k, seed, expert_case)
