#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SOURCE="$SOURCE_DIR/.runtime"
RUNTIME_TARGET="${HOME}/Library/Application Support/inVoice/runtime"
INSTALLER="$RUNTIME_TARGET/scripts/install.sh"

fail() {
  printf '\n[inVoice] Installation failed: %s\n' "$*" >&2
  if [[ -t 0 ]]; then
    read -r -p "Press Return to close this window... " _
  fi
  exit 1
}

[[ -d "$SOURCE_DIR/inVoice.app" ]] || fail "inVoice.app is missing from this disk image."
[[ -d "$RUNTIME_SOURCE/sidecars" ]] || fail "The local runtime payload is missing."

printf '[inVoice] Preparing the private local runtime\n'
mkdir -p "$RUNTIME_TARGET"
ditto "$RUNTIME_SOURCE" "$RUNTIME_TARGET"
chmod +x "$INSTALLER"

"$INSTALLER" --app-bundle "$SOURCE_DIR/inVoice.app" "$@" || fail "See the messages above for details."

printf '\n[inVoice] Ready. inVoice is installed in ~/Applications.\n'
if [[ -t 0 ]]; then
  read -r -p "Press Return to close this window... " _
fi
