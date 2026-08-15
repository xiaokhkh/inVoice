#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/apps/macos/VoiceOps.xcodeproj"
APP="$ROOT_DIR/apps/macos/Build/Release/inVoice.app"
OUTPUT_DIR="$ROOT_DIR/dist"
SKIP_BUILD=0

usage() {
  cat <<'EOF'
Usage: ./scripts/package_macos_release.sh [options]

Builds the ad-hoc-signed macOS app and creates a distributable DMG containing
inVoice plus a one-click local-runtime installer.

Options:
  --skip-build       Package the existing Release build.
  --output-dir PATH  Write the DMG and checksum under PATH (default: dist).
  -h, --help         Show this help.
EOF
}

fail() {
  printf '[inVoice release] ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a path"
      OUTPUT_DIR="$2"
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

[[ "$(uname -s)" == "Darwin" ]] || fail "DMG packaging requires macOS"
for tool in codesign ditto git hdiutil lipo shasum xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required command: $tool"
done

VERSION="$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/apps/macos/project.yml")"
[[ -n "$VERSION" ]] || fail "Could not read MARKETING_VERSION"
ARCH="arm64"
ARTIFACT_BASENAME="inVoice_${VERSION}_${ARCH}"
DMG="$OUTPUT_DIR/${ARTIFACT_BASENAME}.dmg"
CHECKSUM="$DMG.sha256"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/invoice-release.XXXXXX")"
STAGE="$TEMP_DIR/inVoice"

cleanup() {
  if [[ -d "$TEMP_DIR" ]]; then
    find "$TEMP_DIR" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  printf '[inVoice release] Building Release app\n'
  xcodebuild \
    -project "$PROJECT" \
    -scheme VoiceOps \
    -configuration Release \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    build \
    -quiet
fi

[[ -d "$APP" ]] || fail "Release app not found: $APP"
codesign --verify --deep --strict "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/inVoice")" == "arm64" ]] \
  || fail "Release app must contain exactly the arm64 architecture"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || fail "App version $BUILT_VERSION does not match project version $VERSION"

mkdir -p "$STAGE/.runtime/scripts" "$STAGE/.runtime/sidecars" "$OUTPUT_DIR"
ditto "$APP" "$STAGE/inVoice.app"
install -m 0755 "$ROOT_DIR/scripts/install_release.command" "$STAGE/Install inVoice.command"
install -m 0755 "$ROOT_DIR/scripts/install.sh" "$STAGE/.runtime/scripts/install.sh"

while IFS= read -r -d '' tracked_file; do
  target="$STAGE/.runtime/$tracked_file"
  mkdir -p "$(dirname "$target")"
  ditto "$ROOT_DIR/$tracked_file" "$target"
done < <(cd "$ROOT_DIR" && git ls-files -z 'sidecars/asr_mlx/**' 'sidecars/fast_asr/**')

ditto "$ROOT_DIR/docs/RELEASE_INSTALL.txt" "$STAGE/READ ME FIRST.txt"
ditto "$ROOT_DIR/LICENSE" "$STAGE/LICENSE"

printf '[inVoice release] Creating %s\n' "$DMG"
hdiutil create \
  -volname "inVoice $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

shasum -a 256 "$DMG" > "$CHECKSUM"
printf '[inVoice release] Created %s\n' "$DMG"
printf '[inVoice release] Checksum %s\n' "$CHECKSUM"
