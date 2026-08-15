#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${VOICEOPS_INSTALL_DIR:-${HOME}/Applications}"
OLLAMA_MODEL="${VOICEOPS_OLLAMA_MODEL:-qwen2.5-coder:7b-instruct-q5_1}"
ISSUES=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/doctor.sh

Runs read-only checks for the inVoice app, sidecar environments, local models,
services, and install configuration. Exits non-zero when setup is incomplete.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 ]]; then
  printf 'Unknown option: %s\n' "$1" >&2
  usage >&2
  exit 2
fi

ok() {
  printf '  [OK]   %s\n' "$*"
}

warn() {
  printf '  [WARN] %s\n' "$*"
  WARNINGS=$((WARNINGS + 1))
}

issue() {
  printf '  [FIX]  %s\n' "$*"
  ISSUES=$((ISSUES + 1))
}

check_environment() {
  printf '\nSystem\n'
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ok "macOS detected"
  else
    issue "inVoice requires macOS"
  fi
  if [[ "$(uname -m)" == "arm64" ]]; then
    ok "Apple Silicon detected"
  else
    warn "MLX ASR is designed for Apple Silicon; current architecture is $(uname -m)"
  fi
  if command -v xcodebuild >/dev/null 2>&1; then
    ok "Xcode command-line tools are available"
  else
    issue "Install Xcode before building inVoice"
  fi
  if command -v python3 >/dev/null 2>&1; then
    ok "$(python3 --version 2>&1) is available"
  else
    issue "Install Python 3.9 or newer"
  fi
}

check_sidecars() {
  local directory
  local name

  printf '\nSidecars\n'
  for name in asr_mlx fast_asr; do
    directory="$ROOT_DIR/sidecars/$name"
    if [[ -x "$directory/.venv/bin/python" || -x "$directory/.venv/bin/python3" ]]; then
      ok "$name virtual environment is ready"
    else
      issue "$name environment is missing; run ./scripts/install.sh"
    fi
  done

  if curl --silent --fail --max-time 2 http://127.0.0.1:8765/health >/dev/null 2>&1; then
    ok "Final ASR is listening on 127.0.0.1:8765"
  else
    issue "Final ASR is offline; launch inVoice and inspect ~/Library/Logs/VoiceOps/sidecar_asr_mlx.log"
  fi
  if curl --silent --fail --max-time 2 http://127.0.0.1:8790/health >/dev/null 2>&1; then
    ok "Streaming ASR is listening on 127.0.0.1:8790"
  else
    issue "Streaming ASR is offline; launch inVoice and inspect ~/Library/Logs/VoiceOps/sidecar_fast_asr.log"
  fi
}

check_models() {
  local model_dir="$ROOT_DIR/models/zipformer"
  local hf_cache
  local final_model_cache
  local filename
  local missing=0

  printf '\nModels\n'
  for filename in encoder.onnx decoder.onnx joiner.onnx tokens.txt bpe.model; do
    if [[ ! -e "$model_dir/$filename" ]]; then
      missing=1
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    ok "Compact bilingual streaming model is ready"
  else
    issue "Streaming model is incomplete; run ./scripts/install.sh"
  fi

  if [[ -n "${HF_HUB_CACHE:-}" ]]; then
    hf_cache="$HF_HUB_CACHE"
  elif [[ -n "${HF_HOME:-}" ]]; then
    hf_cache="$HF_HOME/hub"
  else
    hf_cache="${HOME}/.cache/huggingface/hub"
  fi
  final_model_cache="$hf_cache/models--mlx-community--GLM-ASR-Nano-2512-8bit"
  if [[ -d "$final_model_cache/snapshots" ]] && find "$final_model_cache/snapshots" -mindepth 2 -print -quit 2>/dev/null | grep -q .; then
    ok "Final MLX ASR model is cached"
  else
    issue "Final MLX ASR model is missing; run ./scripts/install.sh"
  fi

  if command -v ollama >/dev/null 2>&1; then
    ok "Ollama CLI is installed"
  else
    issue "Install Ollama from https://ollama.com/download/mac"
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    issue "curl is required for local service checks"
    return
  fi
  local tags
  if tags="$(curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags 2>/dev/null)"; then
    ok "Ollama is listening on 127.0.0.1:11434"
    if printf '%s' "$tags" | grep -Fq "$OLLAMA_MODEL"; then
      ok "Ollama model $OLLAMA_MODEL is installed"
    else
      issue "Run: ollama pull $OLLAMA_MODEL"
    fi
  else
    issue "Start Ollama, then rerun this check"
  fi
}

check_installation() {
  local app="$INSTALL_DIR/inVoice.app"
  local config="${HOME}/Library/Application Support/VoiceOps/sidecar-root"

  printf '\nApplication\n'
  if [[ -d "$app" ]]; then
    ok "inVoice is installed at $app"
    if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
      ok "App signature is valid"
    else
      issue "App signature is invalid; rerun ./scripts/install.sh"
    fi
  else
    issue "inVoice.app is not installed; run ./scripts/install.sh"
  fi
  if [[ -f "$config" ]] && [[ "$(<"$config")" == "$ROOT_DIR/sidecars" ]]; then
    ok "Installed app can locate this checkout's sidecars"
  else
    issue "Sidecar path is not configured; rerun ./scripts/install.sh"
  fi
}

check_environment
check_sidecars
check_models
check_installation

printf '\nSummary\n'
if [[ "$ISSUES" -eq 0 ]]; then
  printf '  inVoice is ready. Warnings: %d\n' "$WARNINGS"
  exit 0
fi
printf '  Found %d item(s) to fix and %d warning(s).\n' "$ISSUES" "$WARNINGS"
exit 1
