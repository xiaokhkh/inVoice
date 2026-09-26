#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
qa_bundle=$(mktemp -d /tmp/invoice-clipboard-preview.XXXXXX)/inVoiceClipboardQA.app
mkdir -p "$qa_bundle/Contents/MacOS"
cat > "$qa_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.voiceops.clipboard-qa</string><key>CFBundleName</key><string>inVoice Clipboard QA</string><key>CFBundleExecutable</key><string>ClipboardQA</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -O -o "$qa_bundle/Contents/MacOS/ClipboardQA" \
  tests/e2e/clipboard_preview.swift tests/e2e/clipboard_test_support.swift \
  apps/macos/VoiceOpsCore/*.swift \
  apps/macos/VoiceOps/Services/{FocusInjector,Permissions}.swift \
  apps/macos/VoiceOps/Clipboard/{ClipboardItem,ClipboardStore,ClipboardHistoryViewModel,ClipboardItemRowView,HistoryWorkspaceView,ClipboardHistoryPanel,ClipboardHistoryPanelController,ClipboardHistoryView}.swift
codesign --force --sign - "$qa_bundle"
printf '%s\n' "$qa_bundle"
