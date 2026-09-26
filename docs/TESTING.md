# Testing checklist

## Automated core tests

Run from the repository root:

```bash
swift test
```

The `VoiceOpsCore` package covers the Fn/board Session state machine, early
key-up during startup, stale Session rejection, one-time insertion ownership,
cooldown, the two-event Cmd+V plan, clipboard deep snapshots, conditional
restore, copy-only fallback, consecutive injections, and delivery-slot
serialization.

It also covers Accurate/Fast/Adaptive selection, clean-frame requirements,
adaptive stability gates, little-endian stream framing, and all three
post-processing routes.

Run sidecar protocol and single-flight tests:

```bash
python3 -m unittest discover -s sidecars/tests -v
```

These tests include 500 deterministic simulated sessions with a short tail
chunk, sequence-gap rejection, finish integrity, duplicate finish caching,
TTL boundaries, handshake validation, and concurrent GLM queue serialization.

## Sidecars

- Start ASR and LLM servers without errors.
- Run `scripts/smoke_llm.sh` and verify JSON response.
- Run `scripts/smoke_asr.sh` and verify JSON response (likely empty text for silence).
- POST a short wav to `/v1/asr/transcribe` and verify JSON response.
- POST a sample request to `/v1/llm/generate` and verify JSON response.
- Verify `/health` with the per-launch Bearer token reports the expected
  service identity, protocol v1, model identity/hash, and runtime version.
- Verify stop order is tap removal, audio-queue drain, short-tail send,
  `finish`, then an 800 ms maximum wait for `done`.

## Dictation modes and metrics

- The shipping default is `accurate + translateAndPolish`.
- `direct` must neither warm nor call Ollama; an unavailable Ollama must return
  the ASR text in the other two modes.
- Fast and Adaptive stay hidden until the fixed corpus passes. For dogfood only:

```bash
defaults write com.voiceops.VoiceOps streamingFinalsApproved -bool true
defaults write com.voiceops.VoiceOps dictationASRMode -string fast
defaults write com.voiceops.VoiceOps approvedAdaptiveScriptClasses -array cjk latin mixed
```

- Metrics are written to `~/Library/Logs/VoiceOps/session_metrics.jsonl`, capped
  at 50 MB with 14-day retention. Inspect them for timings, counts, modes,
  model versions, and failure reasons; audio and transcript text must be absent.
- See `benchmarks/dictation/README.md` for the 200-item model gate and evaluator.

## macOS app

- Launch app and confirm menu bar icon appears.
- With no selection, press Command+Option+T and verify one compact dialog opens, the composer is focused, and a general prompt can be sent.
- Select English text, press Command+Option+T, and verify Simplified Chinese translation starts automatically.
- Resize the dialog and verify the compact source preview, rich Markdown headings/lists/quotes, fenced-code copy action, and composer remain usable.
- Enter a follow-up and press Command+Return; verify it streams one response and Stop cancels generation cleanly.
- Focus a text field in another app (Slack/Chrome/VSCode).
- Hold Fn, the display, or PWR to start streaming; verify preview feedback updates but the focused field is not mutated yet.
- Release Fn, the display, or PWR; verify exactly one final result is pasted.
- Press BOOT after normal startup; verify it toggles clipboard history once without starting recording or showing the green level ring.
- Tap the display once and release quickly; verify it neither records nor submits.
- Short-tap the display; verify exactly one Return is delivered to the frontmost application.
- Repeat the short tap in Codex, a browser, a terminal, and a chat input; verify each receives its normal Return behavior.
- Hold PWR while pressing BOOT; verify the clipboard toggle does not release the active F13 recording gesture.

## Dock and hot-plug regression

- Connect the board through the dock without touching it; verify no recording starts.
- Hold screen or PWR, then unplug the dock; verify inVoice ends the recording once and returns to idle.
- Reconnect the dock without pressing a control; verify no stale F13/F14/Return state is replayed.
- Hold and release screen/PWR through the dock; verify exactly one recording Session is created and ended.
- Suspend and resume the dock while idle; verify inVoice remains idle.
- Send F13/F14 from a different keyboard; verify it cannot create a board action while direct VID/PID HID monitoring is active.
- Inject or observe a touch pulse shorter than 40 ms; verify it does not emit Return or create a Session.
- Confirm no overlay or focus change occurs during Fn hold.
- If Accessibility is disabled, verify text is copied to clipboard and no injection occurs.
- Release immediately during startup and confirm recording does not remain stuck.
- Switch applications during final ASR and confirm the result is copied rather than pasted into the new app.
- Copy new clipboard content during injection and confirm it is not overwritten by delayed restoration.
- Repeat in Codex, a browser contenteditable, Feishu, TextEdit, Terminal/iTerm2, and a non-QWERTY keyboard layout.

## Local product smoke test (shipping clients)

Use a synthetic fixture, then run the actual Swift clients against the installed local services:

```bash
say -v Tingting -o /tmp/invoice-product-qa.aiff '请在周五之前完成产品体验的优化，并且保留中文输出。'
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/invoice-product-qa.aiff /tmp/invoice-product-qa.wav
swiftc -parse-as-library -O -o /tmp/invoice-local-product-smoke \
  tests/e2e/local_product_smoke.swift \
  apps/macos/VoiceOps/Services/{OfflineLLMClient,LLMRouter,ASRClient,SidecarLauncher}.swift \
  apps/macos/VoiceOps/Models/Mode.swift \
  apps/macos/VoiceOpsCore/{TranslationPromptDefaults,DictationPolicy}.swift
/tmp/invoice-local-product-smoke /tmp/invoice-product-qa.wav
```

The probe checks transcription, the English dictation prompt, streamed completion,
missing-model fallback, and direct mode. It uses the installed token without printing
it. The synthetic speech does not read the microphone or modify the clipboard.
