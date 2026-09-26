#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
qa_bin_dir=$(mktemp -d /tmp/invoice-clipboard-smoke.XXXXXX)
trap 'rm -rf "$qa_bin_dir"' EXIT
common_sources=(
  tests/e2e/clipboard_test_support.swift
  apps/macos/VoiceOpsCore/PasteboardTransaction.swift
  apps/macos/VoiceOpsCore/PasteShortcutPlan.swift
  apps/macos/VoiceOps/Services/FocusInjector.swift
  apps/macos/VoiceOps/Services/Permissions.swift
)
swiftc -parse-as-library -O -o "$qa_bin_dir/delivery" \
  tests/e2e/clipboard_delivery_smoke.swift "${common_sources[@]}"
"$qa_bin_dir/delivery"
swiftc -parse-as-library -O -o "$qa_bin_dir/experience" \
  tests/e2e/clipboard_experience_smoke.swift "${common_sources[@]}" \
  apps/macos/VoiceOps/Clipboard/{ClipboardStore,ClipboardItem,ClipboardImageProcessor,ClipboardHistoryViewModel}.swift
"$qa_bin_dir/experience"
swiftc -parse-as-library -O -o "$qa_bin_dir/capture" \
  tests/e2e/clipboard_capture_smoke.swift \
  apps/macos/VoiceOps/Clipboard/{ClipboardObserver,ClipboardStore,ClipboardItem,ClipboardImageProcessor}.swift \
  apps/macos/VoiceOpsCore/{ProductExperience,SessionMetricV1,DictationPolicy}.swift
"$qa_bin_dir/capture"
