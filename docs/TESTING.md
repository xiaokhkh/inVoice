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

## Clipboard history (0.2.1)

`swift test` includes isolated SQLite tests for literal search, source/type/pin filters,
exact whitespace preservation, deduplication, capacity-based retention (since 0.3.2), image deletion and
undo, cleanup protection, migration, persistence across relaunch, and failed-transaction rollback.
The pasteboard tests also cover image ownership and cancellation of pending text restoration.

```bash
./tests/e2e/clipboard_smoke.sh
```

This compiles the shipping view model and injector. It uses temporary databases,
named test pasteboards, injected permission checks and a fake event poster; it never
reads the user's clipboard or posts real keyboard events. It checks stale search
rejection, success/failure feedback, undo with filters, missing images, focus changes,
permission fallback, one-time image pasting, and newer clipboard writes.

For native UI verification with synthetic clips:

```bash
./tests/e2e/clipboard_preview.sh
```

The script prints a separate app bundle path. Open that bundle to inspect the shipping
history workspace and quick panel. The preview creates a temporary SQLite store and
sample image; it does not run sidecars or clipboard capture. Quit the ordinary inVoice
app first if testing Copy, so it does not capture the synthetic clips. The preview
restores the original clipboard on exit only if its own fixture still occupies it.

Check: Chinese text/filename search, literal `%` and `_`, clear query, all five filters,
long-text scrolling, image preview, pin/unpin, per-item delete/undo, cleanup/undo,
copy feedback, native search editing, arrow navigation, Escape, and fallback messaging.
Verify the installed app's quick-panel paste against a disposable editor field, including
image paste and switching applications before delivery. The temporary preview app may
lack Accessibility permission, in which case it should copy with recovery guidance.

## Focused workspace and assistant (0.3.0)

```bash
./tests/e2e/assistant_smoke.sh
```

This compiles the shipping assistant conversation model with an injected stream.
It verifies draft/conversation preservation on reopen, selected-text translation,
coalesced token bursts, exact final output, partial-output cancellation, rejection of
late output after reset, error recovery, and retry without duplicating turns.
It does not call a model, read the user's clipboard, or post keyboard events.

Native UI checks:

- `⌘1`, `⌘2`, `⌘3`, and `⌘,` navigate to the expected workspace or window.
- Output mode and existing preferences survive upgrades; opening settings changes no preference.
- The clipboard search, More menu, paused banner, and quick-panel entry remain discoverable.
- Assistant native close and Escape preserve conversation/draft within the current process;
  `⌘ Return` sends, New conversation resets, and Escape in another window is unaffected.
- Check neutral colors in light/dark appearances and motion with Reduce Motion enabled.
- Confirm model failures display recovery guidance without a permanent loading indicator.

Release 0.3.0 verification: Release build, 66 core tests, clipboard smoke, assistant smoke,
installed signature and doctor checks; native dark-mode home, settings, output mode, and
assistant navigation inspected. Hardware pairing/OTA was not exercised in this UI iteration.

## Clipboard performance and LRU (0.3.1)

`swift test` adds retention tests for successful reuse without reordering, preview-only
eviction, usage persistence across relaunch, and migration of capture dates and undo batches.
`./tests/e2e/clipboard_smoke.sh` additionally checks background image capture and copy,
byte-for-byte PNG preservation, JPEG conversion, file capture/deduplication, RTF fallback,
capture cancellation, sensitive types, newer clipboard writes, cancelled paste events,
success/failure LRU updates, copy-only delivery, and dormant hidden panels.
These tests use generated data and named pasteboards; no real input events are posted.

Reproduce the synthetic 4K PNG and 200-long-text benchmark sequentially:

```bash
./tests/performance/clipboard_benchmark.sh baseline
./tests/performance/clipboard_benchmark.sh current
```

The baseline compiles clipboard storage from the last shipped 0.3.0 commit. Each run uses
a temporary database and a deterministic image. Results report stage latency and caller
time, not end-to-end clipboard latency. The image caller measurement excludes the worker's
hashing and disk I/O; the benchmark drains each write before taking another sample.

Manual acceptance: open and dismiss the quick panel, copy a large image, copy newer content
while a history image is loading, and confirm that reopening refreshes history. Migration
must preserve existing IDs, capture dates, pins, deletion state, and original image files.

## Capacity-based clipboard history (0.3.2)

`swift test` verifies more than 500 ordinary records survive below budget, UTF-8/context/image
byte accounting, LRU eviction at an injected small budget, pin/undo protection, rejection of
oversized captures and duplicates, rollback before image-file removal, and migration without
startup eviction. Oversized pinned records remain pinned if unpinning would immediately erase them.
Pagination tests check stable boundaries and whole-database filtering before LIMIT/OFFSET.

`./tests/e2e/clipboard_smoke.sh` additionally exercises a 264-record view-model fixture:
100-record first page, repeated load requests, keyboard navigation across pages, search for an
old clip, stale-page cancellation after a new query, and live capture during pagination.

Manual acceptance: the workspace footer shows total and loaded records, ordinary usage and
“no count limit”; its help explains separate pinned/undo storage and estimated disk usage.
Scroll to load more in both workspace and quick panel. Upgrade must preserve IDs, timestamps,
pins, deleted states, content hashes and image files. The actual SQLite file may include free
pages and metadata beyond the content budget.

Reproduce the generated 5,000-record storage benchmark:
`./tests/performance/clipboard_benchmark.sh history`. It reports first/deep page, common/rare
search, and capture including the worker and capacity check. See the dated performance report
for measured results and their scope.

Release 0.3.2 verification: 75 core tests, all three clipboard smoke suites, Release universal
build and signature passed. Native isolated UI checked 246 records across pages. The installed
0.3.2 (6) preserves all 202 existing rows and 17 image files; SQLite integrity and doctor passed.
