#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
qa_bin_dir=$(mktemp -d /tmp/invoice-assistant-smoke.XXXXXX)
trap 'rm -rf "$qa_bin_dir"' EXIT
swiftc -parse-as-library -O -o "$qa_bin_dir/assistant" \
  tests/e2e/assistant_experience_smoke.swift tests/e2e/clipboard_test_support.swift \
  apps/macos/VoiceOpsCore/{TranslationPromptDefaults,DictationPolicy}.swift \
  apps/macos/VoiceOps/Models/Mode.swift \
  apps/macos/VoiceOps/Services/{AssistantConversation,OfflineLLMClient,SelectionCaptureService,Permissions}.swift
"$qa_bin_dir/assistant"
