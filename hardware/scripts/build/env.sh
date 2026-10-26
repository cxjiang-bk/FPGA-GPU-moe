#!/usr/bin/env bash
# Source this file; it does not modify system settings or access the board.
V80_PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
export V80_PROJECT_ROOT
export PYTHONPATH="$V80_PROJECT_ROOT:$V80_PROJECT_ROOT/third_party/openTPU${PYTHONPATH:+:$PYTHONPATH}"
export OTPU_TARGET="$V80_PROJECT_ROOT/configs/v80_smoke.toml"
export PATH="$V80_PROJECT_ROOT/.venv/bin:$V80_PROJECT_ROOT/hardware/scripts/build:$PATH"
export OTPU_IMAGE_CACHE=0 OTPU_IMG_CACHE=0 OTPU_PROG_CACHE=0
export LC_ALL=C
