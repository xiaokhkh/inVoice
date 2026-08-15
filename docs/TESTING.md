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

## Sidecars

- Start ASR and LLM servers without errors.
- Run `scripts/smoke_llm.sh` and verify JSON response.
- Run `scripts/smoke_asr.sh` and verify JSON response (likely empty text for silence).
- POST a short wav to `/v1/asr/transcribe` and verify JSON response.
- POST a sample request to `/v1/llm/generate` and verify JSON response.

## macOS app

- Launch app and confirm menu bar icon appears.
- Focus a text field in another app (Slack/Chrome/VSCode).
- Hold Fn, the display, or PWR to start streaming; verify preview feedback updates but the focused field is not mutated yet.
- Release Fn, the display, or PWR; verify exactly one final result is pasted.
- Press BOOT after normal startup; verify it toggles clipboard history once without starting recording or showing the green level ring.
- Tap the display once and release quickly; verify it neither records nor submits.
- With Codex frontmost and dictation idle, double-tap the display; verify exactly one Return is delivered.
- Double-tap the display while another app is frontmost or while dictation is busy; verify no Return is delivered.
- Hold PWR while pressing BOOT; verify the clipboard toggle does not release the active F13 recording gesture.

## Dock and hot-plug regression

- Connect the board through the dock without touching it; verify no recording starts.
- Hold screen or PWR, then unplug the dock; verify inVoice ends the recording once and returns to idle.
- Reconnect the dock without pressing a control; verify no stale F13/F14/F15 state is replayed.
- Hold and release screen/PWR through the dock; verify exactly one recording Session is created and ended.
- Suspend and resume the dock while idle; verify inVoice remains idle.
- Send F13/F14/F15 from a different keyboard; verify it cannot create a board action while direct VID/PID HID monitoring is active.
- Inject or observe an input pulse shorter than 100 ms; verify it does not emit F13/F14/F15 or create a Session.
- Confirm no overlay or focus change occurs during Fn hold.
- If Accessibility is disabled, verify text is copied to clipboard and no injection occurs.
- Release immediately during startup and confirm recording does not remain stuck.
- Switch applications during final ASR and confirm the result is copied rather than pasted into the new app.
- Copy new clipboard content during injection and confirm it is not overwritten by delayed restoration.
- Repeat in Codex, a browser contenteditable, Feishu, TextEdit, Terminal/iTerm2, and a non-QWERTY keyboard layout.
