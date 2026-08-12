#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_sidecar() {
  local name="$1"
  local dir="$2"
  local port="$3"

  if [[ ! -d "$dir/.venv" ]]; then
    echo "[$name] Missing venv at $dir/.venv. Create it first." >&2
    echo "[$name] cd $dir && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt" >&2
    return 1
  fi

  echo "[$name] starting on port $port"
  (cd "$dir" && source .venv/bin/activate && python server.py)
}

run_sidecar "asr" "$ROOT_DIR/sidecars/asr_mlx" 8765 &
run_sidecar "fast_asr" "$ROOT_DIR/sidecars/fast_asr" 8790 &

wait
