#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
qa_bin_dir=$(mktemp -d /tmp/invoice-clipboard-benchmark.XXXXXX)
trap 'rm -rf "$qa_bin_dir"' EXIT
case "${1:-current}" in
  current)
    swiftc -D OPTIMIZED -parse-as-library -O -o "$qa_bin_dir/benchmark" \
      tests/performance/clipboard_benchmark.swift \
      apps/macos/VoiceOps/Clipboard/{ClipboardStore,ClipboardItem,ClipboardImageProcessor}.swift
    ;;
  baseline)
    # Last shipped 0.3.0 implementation. Git reads only these source files.
    qa_ref=1130a0981503fd819fdf1b888cb353cf8a27fc43
    git show "$qa_ref:apps/macos/VoiceOps/Clipboard/ClipboardStore.swift" > "$qa_bin_dir/ClipboardStore.swift"
    git show "$qa_ref:apps/macos/VoiceOps/Clipboard/ClipboardItem.swift" > "$qa_bin_dir/ClipboardItem.swift"
    swiftc -parse-as-library -O -o "$qa_bin_dir/benchmark" \
      tests/performance/clipboard_benchmark.swift "$qa_bin_dir/ClipboardStore.swift" "$qa_bin_dir/ClipboardItem.swift"
    ;;
  *) printf 'Usage: %s [current|baseline]\n' "$0" >&2; exit 2 ;;
esac
"$qa_bin_dir/benchmark"
