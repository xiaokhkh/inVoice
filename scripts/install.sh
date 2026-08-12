#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${VOICEOPS_SETUP_PYTHON:-python3}"
INSTALL_DIR="${VOICEOPS_INSTALL_DIR:-${HOME}/Applications}"
ASR_MODEL_ID="${ASR_MODEL_ID:-mlx-community/GLM-ASR-Nano-2512-8bit}"
OLLAMA_MODEL="${VOICEOPS_OLLAMA_MODEL:-qwen2.5-coder:7b-instruct-q5_1}"
FAST_MODEL_NAME="sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
FAST_MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${FAST_MODEL_NAME}.tar.bz2"
SKIP_MODELS=0
SKIP_OLLAMA=0
NO_LAUNCH=0
TEMP_DIR=""

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [options]

Creates both Python environments, downloads the local ASR models, prepares
Ollama, builds VoiceOps, installs it for the current user, and launches it.

Options:
  --skip-models       Do not download either ASR model.
  --skip-ollama       Do not check Ollama or pull the default LLM.
  --no-launch         Install the app without launching it.
  --install-dir PATH  Install under PATH instead of ~/Applications.
  --python PATH       Python 3.9+ executable used to create virtual environments.
  -h, --help          Show this help.

Environment overrides:
  ASR_MODEL_ID, VOICEOPS_OLLAMA_MODEL, VOICEOPS_INSTALL_DIR,
  VOICEOPS_SETUP_PYTHON
EOF
}

log() {
  printf '[VoiceOps] %s\n' "$*"
}

fail() {
  printf '[VoiceOps] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    find "$TEMP_DIR" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-models)
      SKIP_MODELS=1
      shift
      ;;
    --skip-ollama)
      SKIP_OLLAMA=1
      shift
      ;;
    --no-launch)
      NO_LAUNCH=1
      shift
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || fail "--install-dir requires a path"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --python)
      [[ $# -ge 2 ]] || fail "--python requires an executable"
      PYTHON_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "VoiceOps requires macOS"
if [[ "$(uname -m)" != "arm64" ]]; then
  log "Warning: Apple Silicon is recommended; MLX ASR may not run on $(uname -m)."
fi

for tool in codesign curl ditto install open shasum tar xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required command: $tool"
done
command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "Python executable not found: $PYTHON_BIN"

if [[ "$SKIP_OLLAMA" -eq 0 ]] && ! command -v ollama >/dev/null 2>&1; then
  fail "Ollama is not installed. Install it from https://ollama.com/download/mac, or rerun with --skip-ollama."
fi

"$PYTHON_BIN" - <<'PY' || fail "Python 3.9 or newer is required"
import sys
raise SystemExit(0 if sys.version_info >= (3, 9) else 1)
PY

setup_environment() {
  local name="$1"
  local directory="$2"
  local no_deps_package="${3:-}"
  local requirements="$directory/requirements.txt"
  local python="$directory/.venv/bin/python"
  local stamp="$directory/.venv/.voiceops-requirements.sha256"
  local checksum

  if [[ ! -x "$python" ]]; then
    log "Creating $name environment"
    "$PYTHON_BIN" -m venv "$directory/.venv"
  fi

  checksum="$(
    {
      shasum -a 256 "$requirements"
      printf '%s\n' "$no_deps_package"
    } | shasum -a 256 | awk '{print $1}'
  )"
  if [[ -f "$stamp" ]] && [[ "$(<"$stamp")" == "$checksum" ]]; then
    log "$name dependencies are already current"
    return
  fi

  log "Installing $name dependencies"
  "$python" -m pip install --disable-pip-version-check --upgrade pip setuptools wheel
  if [[ -n "$no_deps_package" ]]; then
    "$python" -m pip install --disable-pip-version-check --no-deps "$no_deps_package"
  fi
  "$python" -m pip install --disable-pip-version-check -r "$requirements"
  printf '%s\n' "$checksum" > "$stamp"
}

fast_model_ready() {
  local directory="$ROOT_DIR/models/zipformer"
  local filename
  for filename in encoder.onnx decoder.onnx joiner.onnx tokens.txt bpe.model; do
    [[ -e "$directory/$filename" ]] || return 1
  done
}

download_fast_model() {
  local target="$ROOT_DIR/models/zipformer"
  local archive
  local source

  if fast_model_ready; then
    log "Streaming ASR model is already available"
    return
  fi

  log "Downloading the compact bilingual streaming ASR model"
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voiceops-fast-asr.XXXXXX")"
  archive="$TEMP_DIR/${FAST_MODEL_NAME}.tar.bz2"
  curl --fail --location --retry 3 --output "$archive" "$FAST_MODEL_URL"
  tar -xjf "$archive" -C "$TEMP_DIR"
  source="$TEMP_DIR/$FAST_MODEL_NAME"
  [[ -d "$source" ]] || fail "Streaming ASR archive has an unexpected layout"

  mkdir -p "$target"
  install -m 0644 "$source/encoder-epoch-99-avg-1.int8.onnx" "$target/encoder-epoch-99-avg-1.int8.onnx"
  install -m 0644 "$source/decoder-epoch-99-avg-1.onnx" "$target/decoder-epoch-99-avg-1.onnx"
  install -m 0644 "$source/joiner-epoch-99-avg-1.int8.onnx" "$target/joiner-epoch-99-avg-1.int8.onnx"
  install -m 0644 "$source/tokens.txt" "$target/tokens.txt"
  install -m 0644 "$source/bpe.model" "$target/bpe.model"
  ln -sfn encoder-epoch-99-avg-1.int8.onnx "$target/encoder.onnx"
  ln -sfn decoder-epoch-99-avg-1.onnx "$target/decoder.onnx"
  ln -sfn joiner-epoch-99-avg-1.int8.onnx "$target/joiner.onnx"
  fast_model_ready || fail "Streaming ASR model setup did not complete"
}

download_final_asr_model() {
  local python="$ROOT_DIR/sidecars/asr_mlx/.venv/bin/python"

  if "$python" - "$ASR_MODEL_ID" <<'PY'
import sys
from huggingface_hub import snapshot_download

try:
    snapshot_download(repo_id=sys.argv[1], local_files_only=True)
except Exception:
    raise SystemExit(1)
PY
  then
    log "Final ASR model is already cached"
    return
  fi

  log "Downloading final ASR model: $ASR_MODEL_ID"
  "$python" - "$ASR_MODEL_ID" <<'PY'
import sys
from huggingface_hub import snapshot_download

snapshot_download(repo_id=sys.argv[1])
PY
}

prepare_ollama() {
  local logs="${HOME}/Library/Logs/VoiceOps"
  local ready=0
  local attempt

  if ! curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null; then
    log "Starting Ollama"
    mkdir -p "$logs"
    nohup ollama serve >> "$logs/ollama.log" 2>&1 &
    for attempt in {1..30}; do
      if curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null; then
        ready=1
        break
      fi
      sleep 0.5
    done
    [[ "$ready" -eq 1 ]] || fail "Ollama did not start; inspect $logs/ollama.log"
  fi

  log "Preparing Ollama model: $OLLAMA_MODEL"
  ollama pull "$OLLAMA_MODEL"
}

install_app() {
  local project="$ROOT_DIR/apps/macos/VoiceOps.xcodeproj"
  local source="$ROOT_DIR/apps/macos/Build/Release/VoiceOps.app"
  local target="$INSTALL_DIR/VoiceOps.app"
  local support="${HOME}/Library/Application Support/VoiceOps"

  log "Building the Release app"
  xcodebuild -project "$project" -scheme VoiceOps -configuration Release build -quiet
  [[ -d "$source" ]] || fail "Build completed without producing $source"

  log "Installing VoiceOps at $target"
  mkdir -p "$INSTALL_DIR"
  ditto "$source" "$target"
  codesign --verify --deep --strict "$target"

  mkdir -p "$support"
  printf '%s\n' "$ROOT_DIR/sidecars" > "$support/sidecar-root"

  if [[ "$NO_LAUNCH" -eq 0 ]]; then
    open "$target"
  fi
}

setup_environment "Final ASR" "$ROOT_DIR/sidecars/asr_mlx" "mlx-audio==0.2.10"
setup_environment "Streaming ASR" "$ROOT_DIR/sidecars/fast_asr"

if [[ "$SKIP_MODELS" -eq 0 ]]; then
  download_fast_model
  download_final_asr_model
else
  log "Skipping ASR model downloads"
fi

if [[ "$SKIP_OLLAMA" -eq 0 ]]; then
  prepare_ollama
else
  log "Skipping Ollama setup"
fi

install_app

log "Installation complete. Open Preferences with Command+Option+P to grant permissions."
log "Run ./scripts/doctor.sh for a full readiness check."
