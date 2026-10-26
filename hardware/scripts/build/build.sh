#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/env.sh"
cd "$V80_PROJECT_ROOT"
if [[ -f configs/dependencies.lock.json ]]; then python3 software/tools/dependencies.py; fi
exec python3 software/tools/build_fpga.py "$@"
